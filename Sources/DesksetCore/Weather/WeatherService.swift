import Foundation

// The shared weather service (docs/compat/weather.md, docs/skin-threading.md §6): one feed per rounded location,
// shared by every MacWeather measure of every skin; MET Norway's rules for requests; the disk cache; place lookups;
// this Mac's location.
//
// Threads: skins read from their own threads without waiting — `read` / `peek` take a lock for a moment and return
// the feed's immutable snapshot. Everything slow runs on the service's serial queue: timers, the transport's
// completions, parsing, disk access and loading the place table. Its work is small and a skin shows "Loading" while
// it waits for it, so the queue runs at user-initiated priority (at utility priority a busy Mac could starve a place
// lookup for many seconds). Measures hear of changes through their skin's hop (`WeatherSubscription`), one pending
// notification at a time.

/// A MacWeather measure's line to the service: taken on its skin's thread (the hop), told on that thread whenever
/// something it depends on changed (its feed's data or state, a place lookup, this Mac's location).
public final class WeatherSubscription {
    let hop: SkinHop
    let notify: () -> Void
    // Guarded by the service's lock.
    fileprivate var coordinate: RoundedCoordinate?
    fileprivate var notifyPending = false
    fileprivate var waitsForDevice = false

    public init(hop: SkinHop, notify: @escaping () -> Void) {
        self.hop = hop
        self.notify = notify
    }
}

/// The result of a place-name lookup.
public enum PlaceLookup: Equatable {
    case pending
    case found(PlaceMatch)
    case notFound
    /// The place table is missing or damaged: name search is unavailable.
    case unavailable
}

/// What is known near a coordinate (offline): the nearest place within 50 km (its name is shown) and the time zone
/// of the nearest place within 200 km.
public struct NearbyPlace: Equatable {
    public var match: PlaceMatch?
    public var timeZone: String?
}

public enum NearbyLookup: Equatable {
    case pending
    case done(NearbyPlace)
}

public enum DeviceLookup: Equatable {
    case pending
    case fix(RoundedCoordinate)
    case denied
    case unavailable
}

public final class WeatherService {
    // MARK: The shared service

    private static let sharedLock = NSLock()
    private static var current = WeatherService(environment: .offline)

    /// The service skins use. The core default is offline (no transport, nothing live).
    public static var shared: WeatherService {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return current
    }

    /// Replaces the shared service with one for `environment` (the app at launch, tests); the old one stops.
    @discardableResult
    public static func install(_ environment: WeatherEnvironment) -> WeatherService {
        let service = WeatherService(environment: environment)
        sharedLock.lock()
        let old = current
        current = service
        sharedLock.unlock()
        old.shutDown()
        return service
    }

    // MARK: Limits

    public static let maxPlaces = 8
    public static let minimumInterval: TimeInterval = 30 * 60
    public static let activeWindow: TimeInterval = 30 * 60
    public static let userRefreshInterval: TimeInterval = 60
    public static let staleAfterExpiry: TimeInterval = 2 * 3600
    public static let maximumAge: TimeInterval = 48 * 3600
    public static let feedDropAfter: TimeInterval = 10 * 60
    static let diskMaxAge: TimeInterval = 7 * 86_400
    static let diskMaxFiles = 32

    public let environment: WeatherEnvironment
    let queue = DispatchQueue(label: "app.deskset.weather", qos: .userInitiated)
    private let lock = NSLock()

    private final class Feed {
        let coordinate: RoundedCoordinate
        var snapshot = WeatherSnapshot()
        var subscribers: [ObjectIdentifier: WeatherSubscription] = [:]
        var unusedSince: Date?
        var lastRead: Date?
        var evaluationQueued = false
        var loadedDisk = false
        var inFlight = false
        var timer: WeatherCancellable?
        var nextFetch: Date?
        var lastRequestAt: Date?
        var lastModified: String?
        var serverSkew: TimeInterval = 0
        var backoffStep = 0
        var lastUserRefresh: Date?

        /// A measure showing this Mac's location has used this feed: from then on nothing about it is written to
        /// disk and its coordinate is never logged, even after that measure left (the feed keeps its data in memory
        /// until it is dropped).
        var fromDevice = false

        init(coordinate: RoundedCoordinate) {
            self.coordinate = coordinate
        }

        /// Whether the forecast may be cached on disk: a place written in a skin that a measure still shows.
        var persistent: Bool { !fromDevice && !subscribers.isEmpty }

        /// How the log names the place (`WeatherDebug`): never the coordinate of this Mac's location.
        var logName: String { fromDevice ? "this Mac's location" : coordinate.description }
    }

    private var feeds: [RoundedCoordinate: Feed] = [:]
    private var asleep = false
    private var stopped = false
    private var logged: Set<String> = []
    private var diskCleaned = false
    /// Requests sent (tests, the report).
    private var requests = 0

    // Places
    private enum DirectoryState { case unloaded, loading, loaded(PlaceDirectory), missing }
    private var directoryState = DirectoryState.unloaded
    private var directoryLastUse = Date.distantPast
    private var directoryReleaseTimer: WeatherCancellable?
    private var placeResults: [String: PlaceLookup] = [:]
    private var placeOrder: [String] = []
    private var nearbyResults: [RoundedCoordinate: NearbyPlace] = [:]
    private var placeWaiters: [String: [WeatherSubscription]] = [:]

    // This Mac's location (memory only: never written anywhere, never logged).
    private var deviceFix: (coordinate: RoundedCoordinate, at: Date)?
    private var deviceInFlight = false
    private var deviceFailures = 0
    private var deviceRetryAt: Date?
    private var deviceDenied = false
    /// The permission as the last call saw it (a new permission clears the waits of earlier failures).
    private var deviceAuthorization: DeviceLocationAuthorization?
    private var lastLocate: Date?
    private var deviceWaiters: [ObjectIdentifier: WeatherSubscription] = [:]

    public init(environment: WeatherEnvironment) {
        self.environment = environment
    }

    private var now: Date { environment.clock.now() }

    /// Stops every timer; nothing runs after this.
    public func shutDown() {
        lock.lock()
        stopped = true
        let timers = feeds.values.compactMap(\.timer) + [directoryReleaseTimer].compactMap { $0 }
        for f in feeds.values { f.timer = nil }
        directoryReleaseTimer = nil
        lock.unlock()
        for t in timers { t.cancel() }
    }

    /// Waits until the work queued so far has run (tests, the report).
    public func drain() {
        queue.sync {}
    }

    /// Requests sent so far.
    public var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Live feeds (places with at least one measure).
    public var livePlaces: [RoundedCoordinate] {
        lock.lock()
        defer { lock.unlock() }
        return feeds.values.filter { !$0.subscribers.isEmpty }.map(\.coordinate)
    }

    private func log(_ message: String, once key: String? = nil) {
        if let key {
            lock.lock()
            let first = logged.insert(key).inserted
            lock.unlock()
            guard first else { return }
        }
        environment.log(message)
    }

    // MARK: Subscriptions and reads

    /// Attaches the subscription to the feed of `coordinate` (made when needed) and detaches it from any other.
    /// `persistent`: false for this Mac's location (nothing about that feed is ever written to disk or logged, even
    /// after the measure left it). False when 8 other places are live (`TooManyPlaces`).
    public func attach(_ s: WeatherSubscription, to coordinate: RoundedCoordinate, persistent: Bool) -> Bool {
        let id = ObjectIdentifier(s)
        lock.lock()
        let t = now
        if s.coordinate == coordinate, let feed = feeds[coordinate], feed.subscribers[id] != nil {
            if !persistent { feed.fromDevice = true }
            lock.unlock()
            return true
        }
        let others = feeds.values.filter { f in f.coordinate != coordinate && !f.subscribers.isEmpty
            && !(f.subscribers.count == 1 && f.subscribers[id] != nil) }
        if feeds[coordinate].map({ $0.subscribers.isEmpty }) ?? true, others.count >= WeatherService.maxPlaces {
            if let old = s.coordinate, let f = feeds[old] { remove(id, from: f, at: t) }
            s.coordinate = nil
            lock.unlock()
            return false
        }
        if let old = s.coordinate, old != coordinate, let f = feeds[old] {
            remove(id, from: f, at: t)
        }
        let feed = feeds[coordinate] ?? Feed(coordinate: coordinate)
        feeds[coordinate] = feed
        feed.subscribers[id] = s
        feed.unusedSince = nil
        if !persistent { feed.fromDevice = true }
        s.coordinate = coordinate
        dropUnusedFeeds(now: t)
        lock.unlock()
        return true
    }

    /// Takes the subscription off its feed; it stays told about the place lookups and this Mac's location it waits
    /// for (a measure whose place is not known yet, or not shown now: it hears when the answer comes).
    public func leaveFeed(_ s: WeatherSubscription) {
        lock.lock()
        if let c = s.coordinate, let f = feeds[c] { remove(ObjectIdentifier(s), from: f, at: now) }
        s.coordinate = nil
        lock.unlock()
    }

    /// Detaches the subscription from its feed and from pending lookups (the measure closed).
    public func detach(_ s: WeatherSubscription) {
        let id = ObjectIdentifier(s)
        lock.lock()
        if let c = s.coordinate, let f = feeds[c] { remove(id, from: f, at: now) }
        s.coordinate = nil
        deviceWaiters[id] = nil
        s.waitsForDevice = false
        for key in placeWaiters.keys { placeWaiters[key]?.removeAll { $0 === s } }
        lock.unlock()
    }

    /// Takes a subscriber off a feed. The last one leaving stops the feed: its timer is cancelled and nothing is
    /// requested for it any more (a request under way still lands in memory, for a measure that comes back within
    /// 10 minutes). With the lock held.
    private func remove(_ id: ObjectIdentifier, from f: Feed, at t: Date) {
        f.subscribers[id] = nil
        guard f.subscribers.isEmpty else { return }
        f.unusedSince = t
        f.timer?.cancel()
        f.timer = nil
    }

    /// Feeds without a measure for 10 minutes are forgotten (their disk cache stays). With the lock held.
    private func dropUnusedFeeds(now t: Date) {
        for (c, f) in feeds where f.subscribers.isEmpty {
            guard let since = f.unusedSince, t.timeIntervalSince(since) >= WeatherService.feedDropAfter, !f.inFlight
            else { continue }
            f.timer?.cancel()
            feeds[c] = nil
        }
    }

    /// The feed's snapshot; counts as a read. A feed nothing read for 30 minutes sleeps (no requests); a read wakes it,
    /// and fetches at once when its data expired or it has none.
    public func read(_ coordinate: RoundedCoordinate) -> WeatherSnapshot? {
        lock.lock()
        guard let feed = feeds[coordinate] else {
            lock.unlock()
            return nil
        }
        feed.lastRead = now
        let wake = !stopped && !asleep && feed.timer == nil && !feed.inFlight && !feed.evaluationQueued
        if wake { feed.evaluationQueued = true }
        let snapshot = feed.snapshot
        lock.unlock()
        if wake { queue.async { self.evaluate(feed) } }
        return snapshot
    }

    /// The snapshot without counting as a read (the editor's inspector).
    public func peek(_ coordinate: RoundedCoordinate) -> WeatherSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return feeds[coordinate]?.snapshot
    }

    /// `!CommandMeasure … Refresh` (at most once a minute per place): after a network failure the request is tried
    /// again at once (the network may be back); otherwise the measures only read again. It never brings a request
    /// forward that the server put off or the schedule set: the backoff after 429 (and its `Retry-After`) and server
    /// errors, the day after 400 / 403 / 404 / 422, and `Expires`, 30 minutes and the random delay after a success.
    /// Skins can run it in a loop, and MET Norway blocks clients that ignore its answers.
    public func refresh(_ coordinate: RoundedCoordinate) {
        lock.lock()
        guard let feed = feeds[coordinate], !stopped else {
            lock.unlock()
            return
        }
        let t = now
        if let last = feed.lastUserRefresh, t.timeIntervalSince(last) < WeatherService.userRefreshInterval {
            lock.unlock()
            return
        }
        feed.lastUserRefresh = t
        feed.lastRead = t
        let retry = feed.snapshot.lastFailure == .offline && !feed.inFlight
        if retry {
            feed.nextFetch = t
            feed.backoffStep = 0
        }
        let subscribers = Array(feed.subscribers.values)
        lock.unlock()
        if retry {
            queue.async { self.evaluate(feed) }
        } else {
            notify(subscribers)
        }
    }

    // MARK: Sleep and wake

    /// The Mac goes to sleep: every timer stops.
    public func systemWillSleep() {
        lock.lock()
        asleep = true
        let timers = feeds.values.compactMap(\.timer)
        for f in feeds.values { f.timer = nil }
        lock.unlock()
        for t in timers { t.cancel() }
    }

    /// The Mac woke: every feed waits 10–60 s (spread) before its next request; network backoff starts over.
    public func systemDidWake() {
        lock.lock()
        asleep = false
        let t = now
        var woken: [Feed] = []
        for f in feeds.values {
            let delay = 10 + environment.random() * 50
            f.nextFetch = max(f.nextFetch ?? t, t.addingTimeInterval(delay))
            if f.snapshot.lastFailure == .offline { f.backoffStep = 0 }
            if !f.evaluationQueued {
                f.evaluationQueued = true
                woken.append(f)
            }
        }
        deviceRetryAt = nil
        lock.unlock()
        for f in woken { queue.async { self.evaluate(f) } }
    }

    // MARK: Scheduling (queue)

    private func evaluate(_ feed: Feed) {
        lock.lock()
        feed.evaluationQueued = false
        guard !stopped, !asleep, feeds[feed.coordinate] === feed, !feed.inFlight else {
            lock.unlock()
            return
        }
        let t = now
        // Only a place a measure shows and read in the last 30 minutes is fetched.
        let active = feed.lastRead.map { t.timeIntervalSince($0) < WeatherService.activeWindow } ?? false
        guard active, !feed.subscribers.isEmpty, environment.isEnabled(), environment.transport != nil else {
            feed.timer?.cancel()
            feed.timer = nil
            lock.unlock()
            return
        }
        let needsDisk = !feed.loadedDisk && feed.persistent && feed.snapshot.forecast == nil
        feed.loadedDisk = true
        lock.unlock()
        if needsDisk { loadFromDisk(feed) }

        lock.lock()
        let due = feed.nextFetch ?? t
        if due <= t {
            feed.timer?.cancel()
            feed.timer = nil
            lock.unlock()
            fetch(feed)
            return
        }
        feed.timer?.cancel()
        feed.timer = environment.clock.schedule(after: due.timeIntervalSince(t), on: queue) { [weak self, weak feed] in
            guard let self, let feed else { return }
            self.lock.lock()
            feed.timer = nil
            self.lock.unlock()
            self.evaluate(feed)
        }
        lock.unlock()
    }

    private func jitter() -> TimeInterval { 60 + environment.random() * 540 }

    private func fetch(_ feed: Feed) {
        lock.lock()
        let t = now
        feed.inFlight = true
        feed.lastRequestAt = t
        requests += 1
        let request = METNorway.request(endpoint: environment.endpoint, for: feed.coordinate,
                                        userAgent: environment.userAgent, lastModified: feed.lastModified)
        feed.snapshot = feed.snapshot.with(isFetching: true)
        let place = feed.logName
        lock.unlock()
        if environment.debug { environment.log("Weather: requesting \(place)") }
        guard let transport = environment.transport else {
            handle(.failure(.network("no transport")), feed: feed)
            return
        }
        transport.get(request) { [weak self] result in
            self?.queue.async { self?.handle(result, feed: feed) }
        }
    }

    private func handle(_ result: Result<WeatherHTTPResponse, WeatherTransportError>, feed: Feed) {
        let received = now
        var forecast: WeatherForecast?
        var parseFailed = false
        var status = 0
        if case .success(let r) = result {
            status = r.status
            if r.status == 200 || r.status == 203 {
                do {
                    forecast = try METNorway.parse(r.body)
                } catch {
                    parseFailed = true
                    log("Weather: MET Norway sent a forecast Deskset could not read (\(r.body.count) bytes)",
                        once: "parse")
                }
            }
            if r.status == 203 {
                log("Weather: MET Norway reports locationforecast/2.0 as deprecated or beta", once: "203")
            }
        }

        lock.lock()
        feed.inFlight = false
        var snapshot = feed.snapshot.with(isFetching: false)
        let previousFailure = snapshot.lastFailure
        func fail(_ kind: WeatherSnapshot.Failure, base: TimeInterval, cap: TimeInterval, retryAfter: TimeInterval? = nil) {
            feed.backoffStep += 1
            let step = min(feed.backoffStep - 1, 16)
            var wait = min(base * pow(2, Double(step)), cap) * (0.8 + 0.4 * environment.random())
            if let retryAfter, retryAfter > wait { wait = retryAfter }
            feed.nextFetch = received.addingTimeInterval(wait)
            let streak = previousFailure == nil ? snapshot.failureStreak + 1 : snapshot.failureStreak
            snapshot = snapshot.with(failure: .some(kind), failureStreak: streak)
        }
        func expiry(_ r: WeatherHTTPResponse) -> Date {
            let date = r.header("date").flatMap(METNorway.parseHTTPDate)
            feed.serverSkew = date.map { $0.timeIntervalSince(received) } ?? 0
            if let expires = r.header("expires").flatMap(METNorway.parseHTTPDate), date.map({ expires > $0 }) ?? true {
                return expires.addingTimeInterval(-feed.serverSkew)
            }
            return received.addingTimeInterval(WeatherService.minimumInterval)
        }
        var wroteBody: Data?
        var logLine: String?
        var refusal: String?
        var succeeded = false
        switch result {
        case .success(let r) where (r.status == 200 || r.status == 203) && forecast != nil:
            guard let forecast else { break }
            let expires = expiry(r)
            // The same forecast again (MET sent an unchanged body without a condition) is a validation, not new data.
            let changed = snapshot.forecast != forecast
            var past = snapshot.pastTemperatures
            if let old = snapshot.forecast, let first = forecast.steps.first?.time {
                for s in old.steps where s.time < first {
                    if let temperature = s.instant.temperature { past[s.time] = temperature }
                }
            }
            past = past.filter { received.timeIntervalSince($0.key) < 36 * 3600 }
            feed.lastModified = r.header("last-modified")
            feed.backoffStep = 0
            snapshot = WeatherSnapshot(forecast: changed ? forecast : snapshot.forecast ?? forecast,
                                       fetchedAt: received, validatedAt: received, expiresLocal: expires,
                                       lastFailure: nil, failureStreak: snapshot.failureStreak, isFetching: false,
                                       version: changed ? snapshot.version + 1 : snapshot.version, pastTemperatures: past)
            feed.nextFetch = max(expires, (feed.lastRequestAt ?? received).addingTimeInterval(WeatherService.minimumInterval))
                .addingTimeInterval(jitter())
            wroteBody = r.body
            succeeded = true
            logLine = "Weather: fetched (\(status))"
        case .success(let r) where r.status == 304 && snapshot.forecast != nil:
            let expires = expiry(r)
            feed.backoffStep = 0
            if let lm = r.header("last-modified") { feed.lastModified = lm }
            snapshot = snapshot.with(validatedAt: received, expiresLocal: expires, failure: .some(nil))
            feed.nextFetch = max(expires, (feed.lastRequestAt ?? received).addingTimeInterval(WeatherService.minimumInterval))
                .addingTimeInterval(jitter())
            succeeded = true
            logLine = "Weather: not modified (304)"
        case .success(let r) where r.status == 304:
            // A 304 without data to keep (the cache lost its body): ask again without a condition.
            feed.lastModified = nil
            fail(.busy, base: 60, cap: 60)
        case .success(let r) where r.status == 400 || r.status == 403:
            feed.nextFetch = received.addingTimeInterval(86_400)
            let streak = previousFailure == nil ? snapshot.failureStreak + 1 : snapshot.failureStreak
            snapshot = snapshot.with(failure: .some(.refused), failureStreak: streak)
            logLine = "Weather: MET Norway refused the request (\(status)); check the User-Agent and the coordinates"
        case .success(let r) where r.status == 404 || r.status == 422:
            feed.nextFetch = received.addingTimeInterval(86_400)
            let streak = previousFailure == nil ? snapshot.failureStreak + 1 : snapshot.failureStreak
            snapshot = snapshot.with(failure: .some(.notCovered), failureStreak: streak)
            logLine = "Weather: no forecast for this place (\(status))"
        case .success(let r) where r.status == 429:
            let retryAfter = r.header("retry-after").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            fail(.busy, base: 600, cap: 7200, retryAfter: retryAfter)
            logLine = "Weather: MET Norway is busy (429)"
        case .success:
            fail(.busy, base: 300, cap: 3600)
            logLine = parseFailed ? nil : "Weather: MET Norway answered \(status)"
        case .failure(.network):
            fail(.offline, base: 60, cap: 900)
            logLine = "Weather: offline"
        case .failure(.refused(let why)):
            fail(.busy, base: 300, cap: 3600)
            refusal = why
        }
        feed.snapshot = snapshot
        let subscribers = Array(feed.subscribers.values)
        // Only for a place written in a skin that a measure still shows (never this Mac's location).
        let meta = succeeded && feed.persistent ? diskMeta(feed) : nil
        let place = feed.logName
        lock.unlock()

        if let refusal { log("Weather: request refused by Deskset: \(refusal)", once: "refused " + refusal) }
        if let logLine {
            environment.log(environment.debug ? "\(logLine) \(place)" : logLine)
        }
        if let meta { writeToDisk(feed.coordinate, body: wroteBody, meta: meta) }
        notify(subscribers)
        evaluate(feed)
    }

    // MARK: Notifications

    private func notify(_ subscriptions: [WeatherSubscription]) {
        var posting: [WeatherSubscription] = []
        lock.lock()
        for s in subscriptions where !s.notifyPending {
            s.notifyPending = true
            posting.append(s)
        }
        lock.unlock()
        for s in posting {
            s.hop.post { [weak self] in
                self?.lock.lock()
                s.notifyPending = false
                self?.lock.unlock()
                s.notify()
            }
        }
    }

    // MARK: Disk cache (places written in skins only)

    private var diskFolder: URL? { environment.cacheDirectory?.appendingPathComponent("v1", isDirectory: true) }

    private func diskMeta(_ feed: Feed) -> [String: Any] {
        var meta: [String: Any] = ["serverSkew": feed.serverSkew]
        if let lm = feed.lastModified { meta["lastModified"] = lm }
        let s = feed.snapshot
        if let d = s.expiresLocal { meta["expiresLocal"] = d.timeIntervalSince1970 }
        if let d = s.fetchedAt { meta["fetchedAt"] = d.timeIntervalSince1970 }
        if let d = s.validatedAt { meta["validatedAt"] = d.timeIntervalSince1970 }
        meta["past"] = s.pastTemperatures.map { [$0.key.timeIntervalSince1970, $0.value] }
        return meta
    }

    private func writeToDisk(_ c: RoundedCoordinate, body: Data?, meta: [String: Any]) {
        guard let folder = diskFolder else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        cleanDiskOnce(folder)
        if let body { try? body.write(to: folder.appendingPathComponent("\(c.key).json"), options: .atomic) }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("\(c.key).meta.json"), options: .atomic)
        }
    }

    private func cleanDiskOnce(_ folder: URL) {
        lock.lock()
        let first = !diskCleaned
        diskCleaned = true
        lock.unlock()
        guard first else { return }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let t = now
        var dated: [(url: URL, date: Date)] = []
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if t.timeIntervalSince(date) > WeatherService.diskMaxAge {
                try? fm.removeItem(at: f)
            } else {
                dated.append((f, date))
            }
        }
        if dated.count > WeatherService.diskMaxFiles {
            for f in dated.sorted(by: { $0.date > $1.date }).dropFirst(WeatherService.diskMaxFiles) {
                try? fm.removeItem(at: f.url)
            }
        }
    }

    private func loadFromDisk(_ feed: Feed) {
        guard let folder = diskFolder else { return }
        let key = feed.coordinate.key
        guard let body = try? Data(contentsOf: folder.appendingPathComponent("\(key).json")),
              let metaData = try? Data(contentsOf: folder.appendingPathComponent("\(key).meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let forecast = try? METNorway.parse(body) else { return }
        func date(_ k: String) -> Date? { (meta[k] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        let t = now
        guard let validated = date("validatedAt"), t.timeIntervalSince(validated) < WeatherService.diskMaxAge else { return }
        var past: [Date: Double] = [:]
        for pair in meta["past"] as? [[Double]] ?? [] where pair.count == 2 {
            past[Date(timeIntervalSince1970: pair[0])] = pair[1]
        }
        lock.lock()
        defer { lock.unlock() }
        guard feed.snapshot.forecast == nil else { return }
        feed.lastModified = meta["lastModified"] as? String
        feed.serverSkew = (meta["serverSkew"] as? NSNumber)?.doubleValue ?? 0
        let expires = date("expiresLocal") ?? validated.addingTimeInterval(WeatherService.minimumInterval)
        feed.snapshot = WeatherSnapshot(forecast: forecast, fetchedAt: date("fetchedAt"), validatedAt: validated,
                                        expiresLocal: expires, lastFailure: nil,
                                        failureStreak: feed.snapshot.failureStreak, isFetching: false,
                                        version: feed.snapshot.version + 1, pastTemperatures: past)
        // Not expired: no request before MET's time (and 30 minutes after the last validation).
        if t < expires {
            feed.nextFetch = max(expires, validated.addingTimeInterval(WeatherService.minimumInterval))
                .addingTimeInterval(jitter())
        }
        let subscribers = Array(feed.subscribers.values)
        queue.async { self.notify(subscribers) }
    }

    // MARK: Places

    private func queryKey(_ query: String) -> String { PlaceDirectory.fold(query) }

    /// Looks a place name up in the offline table. `.pending` starts the lookup; the subscription is told when it
    /// is done. With `waitsForLookups` (`--render`) the answer is there at once (never call it on the service's queue).
    public func lookUpPlace(_ query: String, for s: WeatherSubscription?) -> PlaceLookup {
        lookUp(key: queryKey(query), for: s) { $0.search(query) }
    }

    /// The city of a time zone (`Location=timezone`, `PlaceDirectory.place(forTimeZone:)`), looked up as a place name
    /// is: `.notFound` for a zone without one (UTC, Etc/GMT-8).
    public func lookUpTimeZone(_ identifier: String, for s: WeatherSubscription?) -> PlaceLookup {
        let now = self.now
        return lookUp(key: "timezone\u{0}" + identifier, for: s) { $0.place(forTimeZone: identifier, near: now) }
    }

    private func lookUp(key: String, for s: WeatherSubscription?,
                        _ find: @escaping (PlaceDirectory) -> PlaceMatch?) -> PlaceLookup {
        lock.lock()
        if let result = placeResults[key] {
            lock.unlock()
            return result
        }
        if environment.waitsForLookups {
            lock.unlock()
            return queue.sync { findPlace(key: key, find) }
        }
        let start = placeWaiters[key] == nil
        var waiters = placeWaiters[key] ?? []
        if let s, !waiters.contains(where: { $0 === s }) { waiters.append(s) }
        placeWaiters[key] = waiters
        lock.unlock()
        if start { queue.async { _ = self.findPlace(key: key, find) } }
        return .pending
    }

    /// Searches the table once for `key`, keeps the result and tells the measures waiting for it (queue).
    private func findPlace(key: String, _ find: (PlaceDirectory) -> PlaceMatch?) -> PlaceLookup {
        lock.lock()
        let known = placeResults[key]
        lock.unlock()
        var result = known ?? .unavailable
        if known == nil, let directory = directory() {
            result = find(directory).map { .found($0) } ?? .notFound
        }
        lock.lock()
        if known == nil {
            placeResults[key] = result
            placeOrder.append(key)
            if placeOrder.count > 64 { placeResults[placeOrder.removeFirst()] = nil }
        }
        let waiting = placeWaiters.removeValue(forKey: key) ?? []
        lock.unlock()
        notify(waiting)
        return result
    }

    /// The nearest place to a coordinate (offline); with `waitsForLookups`, at once.
    public func nearby(_ c: RoundedCoordinate, for s: WeatherSubscription?) -> NearbyLookup {
        let key = "near:\(c.key)"
        lock.lock()
        if let result = nearbyResults[c] {
            lock.unlock()
            return .done(result)
        }
        if environment.waitsForLookups {
            lock.unlock()
            return .done(queue.sync { findNearby(c, key: key) })
        }
        let start = placeWaiters[key] == nil
        var waiters = placeWaiters[key] ?? []
        if let s, !waiters.contains(where: { $0 === s }) { waiters.append(s) }
        placeWaiters[key] = waiters
        lock.unlock()
        if start { queue.async { _ = self.findNearby(c, key: key) } }
        return .pending
    }

    /// Finds what is near `c` once, keeps it and tells the measures waiting for it (queue).
    private func findNearby(_ c: RoundedCoordinate, key: String) -> NearbyPlace {
        lock.lock()
        let known = nearbyResults[c]
        lock.unlock()
        var result = known ?? NearbyPlace()
        if known == nil, let directory = directory() {
            if let p = directory.nearest(to: c, within: 50) {
                result.match = PlaceMatch(place: p, displayName: p.name, detail: directory.detail(for: p),
                                          countryName: directory.countryName(p.country))
                result.timeZone = p.timeZone
            } else {
                result.timeZone = directory.nearest(to: c, within: 200)?.timeZone
            }
        }
        lock.lock()
        if known == nil {
            if nearbyResults.count >= 64 { nearbyResults.removeAll() }
            nearbyResults[c] = result
        }
        let waiting = placeWaiters.removeValue(forKey: key) ?? []
        lock.unlock()
        notify(waiting)
        return result
    }

    /// The loaded table (queue only): loaded on demand, released after 2 minutes without a lookup.
    private func directory() -> PlaceDirectory? {
        lock.lock()
        directoryLastUse = now
        let state = directoryState
        lock.unlock()
        switch state {
        case .loaded(let d): return d
        case .missing: return nil
        case .unloaded, .loading: break
        }
        let loaded = environment.placesTable.flatMap { PlaceDirectory(url: $0) }
        lock.lock()
        directoryState = loaded.map { .loaded($0) } ?? .missing
        if loaded == nil, environment.placesTable != nil {
            logged.insert("places")
        }
        scheduleDirectoryRelease()
        lock.unlock()
        if loaded == nil { environment.log("Weather: the place table is missing or damaged; place names cannot be found") }
        return loaded
    }

    /// With the lock held.
    private func scheduleDirectoryRelease() {
        guard directoryReleaseTimer == nil, !stopped else { return }
        directoryReleaseTimer = environment.clock.schedule(after: 120, on: queue) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.directoryReleaseTimer = nil
            if self.now.timeIntervalSince(self.directoryLastUse) >= 120 {
                self.directoryState = .unloaded
            } else {
                self.scheduleDirectoryRelease()
            }
            self.lock.unlock()
        }
    }

    /// Whether the place table is loaded now (tests).
    public var placeTableLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .loaded = directoryState { return true }
        return false
    }

    // MARK: This Mac's location

    /// A rounded fix of this Mac's location (reduced accuracy; kept in memory for an hour, never stored or logged).
    /// `.pending` asks Location Services (once at a time for every skin); the subscription is told when the answer
    /// comes. After a failure, asked again after 1, 5, 15 and then every 30 minutes, while a skin reads it.
    public func deviceLocation(for s: WeatherSubscription?, locate: Bool = false) -> DeviceLookup {
        guard let source = environment.deviceLocation else { return .unavailable }
        let authorization = source.authorization
        lock.lock()
        if authorization == .authorized, deviceAuthorization != .authorized {
            // Just allowed (the answer to the question, or System Settings): ask at once, whatever failed before.
            deviceFailures = 0
            deviceRetryAt = nil
        }
        deviceAuthorization = authorization
        lock.unlock()
        switch authorization {
        case .denied, .restricted: return .denied
        default: break
        }
        let cached = source.cachedFix(maxAge: 3600)
        lock.lock()
        let t = now
        if authorization == .authorized { deviceDenied = false }
        var force = false
        if locate, lastLocate.map({ t.timeIntervalSince($0) >= 60 }) ?? true {
            lastLocate = t
            force = true
            deviceRetryAt = nil
        }
        if !force, let fix = deviceFix, t.timeIntervalSince(fix.at) < 3600 {
            lock.unlock()
            return .fix(fix.coordinate)
        }
        if !force, let cached {
            deviceFix = (cached, t)
            lock.unlock()
            return .fix(cached)
        }
        if let s {
            deviceWaiters[ObjectIdentifier(s)] = s
            s.waitsForDevice = true
        }
        let failing = deviceFailures > 0
        let denied = deviceDenied
        let start = !deviceInFlight && !denied && (deviceRetryAt.map { t >= $0 } ?? true)
        if start { deviceInFlight = true }
        let previous = deviceFix?.coordinate
        lock.unlock()
        if denied { return .denied }
        if start {
            source.requestFix { [weak self] result in
                self?.queue.async { self?.deviceAnswered(result) }
            }
        }
        if let previous { return .fix(previous) }
        return failing ? .unavailable : .pending
    }

    private func deviceAnswered(_ result: Result<RoundedCoordinate, DeviceLocationError>) {
        lock.lock()
        let t = now
        deviceInFlight = false
        switch result {
        case .success(let c):
            deviceFix = (c, t)
            deviceFailures = 0
            deviceRetryAt = nil
            deviceDenied = false
        case .failure(.denied):
            deviceDenied = true
        case .failure(.unavailable):
            deviceFailures += 1
            let waits: [TimeInterval] = [60, 300, 900, 1800]
            deviceRetryAt = t.addingTimeInterval(waits[min(deviceFailures - 1, waits.count - 1)])
        }
        let waiting = Array(deviceWaiters.values)
        deviceWaiters.removeAll()
        for s in waiting { s.waitsForDevice = false }
        lock.unlock()
        environment.log(result.isSuccess ? "Location: fix ok" : "Location: failed")
        notify(waiting)
    }

    // MARK: States

    /// The state a feed's snapshot shows, for a known place (`Type=Status`): with data on screen, failures show as
    /// Stale; data 48 hours old is no longer shown.
    public static func status(of snapshot: WeatherSnapshot?, now: Date) -> WeatherStatus {
        guard let s = snapshot else { return .loading }
        let fresh = s.forecast != nil && (s.validatedAt.map { now.timeIntervalSince($0) < maximumAge } ?? false)
        if fresh {
            if s.lastFailure != nil { return .stale }
            if let e = s.expiresLocal, now.timeIntervalSince(e) >= staleAfterExpiry { return .stale }
            return .ready
        }
        switch s.lastFailure {
        case nil: return .loading
        case .offline?: return .offline
        case .busy?: return .rateLimited
        case .refused?: return .refused
        case .notCovered?: return .notCovered
        }
    }

    // MARK: Report

    /// What is cached on disk: number of places and the newest file's age.
    public func diskCacheSummary() -> (places: Int, newest: Date?) {
        guard let folder = diskFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                        includingPropertiesForKeys: [.contentModificationDateKey])
        else { return (0, nil) }
        let metas = files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }
        let newest = metas.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        return (metas.count, newest)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
