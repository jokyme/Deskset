import Foundation
@testable import DesksetCore

// The weather service's request policy (fake transport, virtual clock) and the real transport against the loopback
// test server.

// MARK: - Fakes and helpers

/// A transport answering from a closure; records the requests. `hold` keeps completions until `release()`.
final class FakeWeatherTransport: WeatherTransport {
    private let lock = NSLock()
    private var _requests: [WeatherHTTPRequest] = []
    private var held: [() -> Void] = []
    var hold = false
    var respond: (WeatherHTTPRequest) -> Result<WeatherHTTPResponse, WeatherTransportError>

    init(_ respond: @escaping (WeatherHTTPRequest) -> Result<WeatherHTTPResponse, WeatherTransportError>) {
        self.respond = respond
    }

    static func fixture(status: Int = 200, headers: [String: String] = WeatherFixtures.headers,
                        body: Data = WeatherFixtures.complete) -> FakeWeatherTransport {
        FakeWeatherTransport { _ in .success(WeatherHTTPResponse(status: status, headers: headers, body: body)) }
    }

    var requests: [WeatherHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func get(_ request: WeatherHTTPRequest, completion: @escaping (Result<WeatherHTTPResponse, WeatherTransportError>) -> Void) {
        lock.lock()
        _requests.append(request)
        let result = respond(request)
        if hold {
            held.append { completion(result) }
            lock.unlock()
            return
        }
        lock.unlock()
        completion(result)
    }

    func release() {
        lock.lock()
        let pending = held
        held = []
        lock.unlock()
        for p in pending { p() }
    }
}

final class FakeDeviceLocation: DeviceLocationSource {
    var authorization = DeviceLocationAuthorization.authorized
    var result: Result<RoundedCoordinate, DeviceLocationError> = .success(RoundedCoordinate(latitude: 59.91, longitude: 10.75))
    private(set) var requests = 0

    func cachedFix(maxAge: TimeInterval) -> RoundedCoordinate? { nil }

    func requestFix(_ completion: @escaping (Result<RoundedCoordinate, DeviceLocationError>) -> Void) {
        requests += 1
        completion(result)
    }
}

/// Spins the main run loop until `condition` holds (hops to skins arrive there).
@discardableResult
func weatherWait(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

/// A test environment: live, the fixture clock, a fake transport, the fixture place table.
func weatherTestEnvironment(_ t: TestRunner, transport: WeatherTransport? = FakeWeatherTransport.fixture(),
                            clock: VirtualWeatherClock = VirtualWeatherClock(now: WeatherFixtures.clock),
                            random: Double = 0, logs: WeatherLogBox? = nil) -> WeatherEnvironment {
    var env = WeatherEnvironment()
    env.isLive = { _ in true }
    env.transport = transport
    env.clock = clock
    env.random = { random }
    env.placesTable = WeatherFixtures.placesFixture
    env.cacheDirectory = t.temporaryDirectory("weather-cache")
    env.uses24HourClock = { true }
    env.preferredUnits = { .metric }
    if let logs { env.log = { logs.add($0) } }
    return env
}

final class WeatherLogBox {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private let oslo = WeatherFixtures.oslo

private func date(_ iso: String) -> Date { WeatherFixtures.date(iso) }

private func httpDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return f.string(from: d)
}

/// A service with a fake transport, the fixture clock and a subscription from a throwaway skin.
private final class ServiceHarness {
    let transport: FakeWeatherTransport
    let clock = VirtualWeatherClock(now: WeatherFixtures.clock)
    let logs = WeatherLogBox()
    let service: WeatherService
    let skin: Skin
    var notified = 0
    private(set) var subscription: WeatherSubscription!

    init(_ t: TestRunner, transport: FakeWeatherTransport = .fixture(), random: Double = 0,
         configure: (inout WeatherEnvironment) -> Void = { _ in }) throws {
        self.transport = transport
        var env = weatherTestEnvironment(t, transport: transport, clock: clock, random: random, logs: logs)
        configure(&env)
        service = WeatherService(environment: env)
        skin = try makeSkin(t, "[Rainmeter]\n[M]\nMeasure=Calc\n").0
        subscription = WeatherSubscription(hop: skin.hop()) { [weak self] in self?.notified += 1 }
    }

    /// Lets queued work run (the transport answers inline, the service handles it on its queue).
    func settle() {
        service.drain()
        service.drain()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }

    @discardableResult
    func read(_ c: RoundedCoordinate = oslo) -> WeatherSnapshot? {
        let s = service.read(c)
        settle()
        return s
    }

    /// Moves the clock to `target` in steps, reading the feed at each (a skin that shows it).
    func advanceReading(to target: Date, step: TimeInterval = 300, _ c: RoundedCoordinate = oslo) {
        while clock.now() < target {
            let next = min(clock.now().addingTimeInterval(step), target)
            clock.advance(to: next)
            settle()
            read(c)
        }
    }

    var snapshot: WeatherSnapshot? { service.peek(oslo) }
    var requests: Int { transport.requests.count }
}

func runWeatherFetchTests(_ t: TestRunner) {
    t.suite("Weather: fetch: first request, schedule, conditional requests") {
        var responses: [WeatherHTTPResponse] = []
        let transport = FakeWeatherTransport { _ in
            .success(responses.isEmpty ? WeatherHTTPResponse(status: 500) : responses.removeFirst())
        }
        responses.append(WeatherHTTPResponse(status: 200, headers: WeatherFixtures.headers, body: WeatherFixtures.complete))
        let h = try ServiceHarness(t, transport: transport)
        t.check(h.service.attach(h.subscription, to: oslo, persistent: true))
        t.equal(h.read()?.forecast == nil, true, "nothing yet")
        t.equal(h.requests, 1, "the first read fetches")
        let request = h.transport.requests[0]
        t.equal(request.url.absoluteString,
                "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=59.91&lon=10.75")
        t.equal(request.headers["User-Agent"], "Deskset/dev (+https://github.com/jokyme/Deskset)")
        t.equal(request.headers["Accept"], "application/json")
        t.equal(request.headers["If-Modified-Since"], nil, "nothing to validate yet")
        t.check(weatherWait { h.notified >= 1 }, "the measure is told")
        guard let s = h.snapshot else { return t.check(false, "snapshot") }
        t.equal(s.forecast?.steps.count, 86)
        t.equal(s.version, 1)
        t.equal(s.validatedAt, WeatherFixtures.clock)
        t.equal(s.expiresLocal, date("2026-09-26T12:20:14Z"))
        t.equal(WeatherService.status(of: s, now: WeatherFixtures.clock), .ready)
        t.equal(h.logs.all, ["Weather: fetched (200)"], "no coordinates in the log")
        // Next request: max(Expires, 30 minutes after the last request) + 1…10 minutes (random 0 → 1 minute).
        h.advanceReading(to: date("2026-09-26T12:30:30Z"))
        t.equal(h.requests, 1, "not before 12:30:31")
        responses.append(WeatherHTTPResponse(status: 304, headers: ["Date": "Sat, 26 Sep 2026 12:30:31 GMT",
                                                                    "Expires": "Sat, 26 Sep 2026 13:10:00 GMT"]))
        h.advanceReading(to: date("2026-09-26T12:30:31Z"))
        t.equal(h.requests, 2, "then it asks again")
        t.equal(h.transport.requests.last?.headers["If-Modified-Since"], "Sat, 26 Sep 2026 11:49:25 GMT",
                "the stored Last-Modified, byte for byte")
        t.equal(h.snapshot?.version, 1, "304 keeps the data")
        t.equal(h.snapshot?.validatedAt, date("2026-09-26T12:30:31Z"))
        t.equal(h.snapshot?.expiresLocal, date("2026-09-26T13:10:00Z"), "and takes the new Expires")
        // The same body again (200): a new validation, not new data.
        responses.append(WeatherHTTPResponse(status: 200, headers: WeatherFixtures.headers, body: WeatherFixtures.complete))
        h.advanceReading(to: date("2026-09-26T13:11:00Z"))
        t.equal(h.requests, 3)
        t.equal(h.snapshot?.version, 1, "an unchanged body is not new data")
    }

    t.suite("Weather: fetch: clock skew and jitter") {
        // The server's clock is an hour ahead: Expires is read in the server's time.
        let serverNow = WeatherFixtures.clock.addingTimeInterval(3600)
        let headers = ["Date": httpDate(serverNow), "Expires": httpDate(serverNow.addingTimeInterval(40 * 60)),
                       "Last-Modified": "Sat, 26 Sep 2026 12:49:25 GMT"]
        for (random, jitter) in [(0.0, 60.0), (0.999, 60 + 0.999 * 540)] {
            let h = try ServiceHarness(t, transport: .fixture(headers: headers), random: random)
            _ = h.service.attach(h.subscription, to: oslo, persistent: true)
            h.read()
            t.equal(h.snapshot?.expiresLocal, WeatherFixtures.clock.addingTimeInterval(40 * 60), "skew-corrected")
            let due = WeatherFixtures.clock.addingTimeInterval(40 * 60 + jitter)
            h.advanceReading(to: due.addingTimeInterval(-1), step: 60)
            t.equal(h.requests, 1, "random \(random): not yet")
            h.advanceReading(to: due.addingTimeInterval(1), step: 60)
            t.equal(h.requests, 2, "random \(random): due")
        }
        // Expires missing or not after Date: 30 minutes.
        let h = try ServiceHarness(t, transport: .fixture(headers: ["Date": httpDate(WeatherFixtures.clock)]))
        _ = h.service.attach(h.subscription, to: oslo, persistent: true)
        h.read()
        t.equal(h.snapshot?.expiresLocal, WeatherFixtures.clock.addingTimeInterval(1800))
    }

    t.suite("Weather: fetch: failures and backoff") {
        // 203: used, one warning per launch.
        let h203 = try ServiceHarness(t, transport: .fixture(status: 203))
        _ = h203.service.attach(h203.subscription, to: oslo, persistent: true)
        h203.read()
        t.check(h203.snapshot?.forecast != nil, "203 is a full body")
        h203.advanceReading(to: date("2026-09-26T12:31:00Z"))
        t.equal(h203.requests, 2)
        t.equal(h203.logs.all.filter { $0.contains("deprecated") }.count, 1, "\(h203.logs.all)")

        // 403: automatic requests stop until Refresh (or 24 hours).
        let h403 = try ServiceHarness(t, transport: .fixture(status: 403, headers: [:], body: Data()))
        _ = h403.service.attach(h403.subscription, to: oslo, persistent: true)
        h403.read()
        t.equal(h403.snapshot?.lastFailure, .refused)
        t.equal(WeatherService.status(of: h403.snapshot, now: h403.clock.now()), .refused)
        h403.advanceReading(to: date("2026-09-26T20:00:00Z"), step: 1800)
        t.equal(h403.requests, 1, "no automatic retry")
        h403.service.refresh(oslo)
        h403.settle()
        t.equal(h403.requests, 2, "Refresh asks again")
        h403.service.refresh(oslo)
        h403.settle()
        t.equal(h403.requests, 2, "at most one Refresh a minute")
        t.check(h403.logs.all.contains { $0.contains("refused") && $0.contains("User-Agent") }, "\(h403.logs.all)")

        // 404 / 422: no forecast here, retried after a day.
        let h404 = try ServiceHarness(t, transport: .fixture(status: 422, headers: [:], body: Data()))
        _ = h404.service.attach(h404.subscription, to: oslo, persistent: true)
        h404.read()
        t.equal(WeatherService.status(of: h404.snapshot, now: h404.clock.now()), .notCovered)
        h404.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(86_000), step: 1800)
        t.equal(h404.requests, 1)
        h404.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(86_500), step: 300)
        t.equal(h404.requests, 2)

        // 429: 10 minutes, doubling (× 0.8 with random 0); Retry-After when longer.
        var headers429: [String: String] = [:]
        let h429 = try ServiceHarness(t, transport: FakeWeatherTransport { _ in
            .success(WeatherHTTPResponse(status: 429, headers: headers429))
        })
        _ = h429.service.attach(h429.subscription, to: oslo, persistent: true)
        h429.read()
        t.equal(WeatherService.status(of: h429.snapshot, now: h429.clock.now()), .rateLimited)
        h429.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(479), step: 60)
        t.equal(h429.requests, 1)
        h429.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(481), step: 60)
        t.equal(h429.requests, 2, "after 8 minutes")
        headers429 = ["Retry-After": "3600"]
        let second = h429.clock.now()
        h429.advanceReading(to: second.addingTimeInterval(961), step: 60)
        t.equal(h429.requests, 3, "then 16 minutes")
        let third = h429.clock.now()
        h429.advanceReading(to: third.addingTimeInterval(3000), step: 60)
        t.equal(h429.requests, 3, "Retry-After: an hour")
        h429.advanceReading(to: third.addingTimeInterval(3700), step: 60)
        t.equal(h429.requests, 4)

        // 5xx and a body that is not a forecast: 5 minutes, doubling; logged once with the size.
        let hBad = try ServiceHarness(t, transport: .fixture(status: 200, body: Data("{".utf8)))
        _ = hBad.service.attach(hBad.subscription, to: oslo, persistent: true)
        hBad.read()
        t.equal(hBad.snapshot?.lastFailure, .busy)
        hBad.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(241), step: 60)
        t.equal(hBad.requests, 2, "after 4 minutes")
        hBad.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(241 + 481), step: 60)
        t.equal(hBad.requests, 3, "then 8")
        t.equal(hBad.logs.all.filter { $0.contains("1 bytes") }.count, 1, "\(hBad.logs.all)")

        // Offline: no data → Offline; with data → Stale; data older than 48 hours is no longer shown.
        var online = true
        let hNet = try ServiceHarness(t, transport: FakeWeatherTransport { _ in
            online ? .success(WeatherHTTPResponse(status: 200, headers: WeatherFixtures.headers, body: WeatherFixtures.complete))
                : .failure(.network("offline"))
        })
        _ = hNet.service.attach(hNet.subscription, to: oslo, persistent: true)
        online = false
        hNet.read()
        t.equal(WeatherService.status(of: hNet.snapshot, now: hNet.clock.now()), .offline)
        t.equal(hNet.snapshot?.failureStreak, 1)
        online = true
        hNet.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(61), step: 30)
        t.equal(WeatherService.status(of: hNet.snapshot, now: hNet.clock.now()), .ready)
        online = false
        hNet.advanceReading(to: date("2026-09-26T13:00:00Z"), step: 300)
        t.equal(WeatherService.status(of: hNet.snapshot, now: hNet.clock.now()), .stale, "data with a failure")
        t.equal(hNet.snapshot?.failureStreak, 2, "a new streak")
        let before = hNet.requests
        hNet.advanceReading(to: date("2026-09-26T13:30:00Z"), step: 60)
        t.check(hNet.requests - before <= 5, "network backoff grows: \(hNet.requests - before) requests in 30 minutes")
        hNet.advanceReading(to: date("2026-09-28T12:30:00Z"), step: 1800)
        t.equal(WeatherService.status(of: hNet.snapshot, now: hNet.clock.now()), .offline, "48 hours: dropped")
        // Stale without a failure: two hours past Expires.
        let old = WeatherSnapshot(forecast: WeatherFixtures.forecast(), validatedAt: WeatherFixtures.clock,
                                  expiresLocal: WeatherFixtures.clock)
        t.equal(WeatherService.status(of: old, now: WeatherFixtures.clock.addingTimeInterval(7199)), .ready)
        t.equal(WeatherService.status(of: old, now: WeatherFixtures.clock.addingTimeInterval(7200)), .stale)
    }

    t.suite("Weather: fetch: sleep, dormant feeds, one request at a time") {
        let h = try ServiceHarness(t)
        _ = h.service.attach(h.subscription, to: oslo, persistent: true)
        h.read()
        t.equal(h.requests, 1)
        // Asleep: nothing, however long.
        h.service.systemWillSleep()
        h.clock.advance(to: date("2026-09-26T18:00:00Z"))
        h.settle()
        _ = h.service.read(oslo)
        h.settle()
        t.equal(h.requests, 1, "no request while the Mac sleeps")
        // Awake: 10–60 s later (random 0 → 10 s).
        h.service.systemDidWake()
        h.settle()
        t.equal(h.requests, 1, "not at once")
        h.clock.advance(by: 11)
        h.settle()
        t.equal(h.requests, 2, "10 s after waking")
        // Dormant: nothing read for 30 minutes → no requests; the next read fetches at once (data expired).
        h.clock.advance(to: date("2026-09-26T23:00:00Z"))
        h.settle()
        t.equal(h.requests, 2, "a feed nobody reads sleeps")
        h.read()
        t.equal(h.requests, 3, "a read wakes it and fetches")

        // Six threads read a feed without data: one request.
        let slow = FakeWeatherTransport.fixture()
        slow.hold = true
        let h6 = try ServiceHarness(t, transport: slow)
        _ = h6.service.attach(h6.subscription, to: oslo, persistent: true)
        let group = DispatchGroup()
        for _ in 0..<6 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<50 { _ = h6.service.read(oslo) }
            }
        }
        group.wait()
        h6.settle()
        t.equal(slow.requests.count, 1, "single flight")
        slow.release()
        h6.settle()
        t.check(h6.snapshot?.forecast != nil)

        // At most 8 places per install.
        let h9 = try ServiceHarness(t)
        var subscriptions: [WeatherSubscription] = []
        for i in 0..<9 {
            let s = WeatherSubscription(hop: h9.skin.hop()) {}
            subscriptions.append(s)
            let ok = h9.service.attach(s, to: RoundedCoordinate(latitude: Double(i), longitude: 10), persistent: true)
            t.equal(ok, i < 8, "place \(i + 1)")
        }
        t.check(h9.service.attach(subscriptions[0], to: RoundedCoordinate(latitude: 50, longitude: 10), persistent: true),
                "a place can move")
        h9.service.detach(subscriptions[1])
        t.check(h9.service.attach(subscriptions[8], to: RoundedCoordinate(latitude: 8, longitude: 10), persistent: true),
                "a freed place can be used")
        t.equal(h9.service.livePlaces.count, 8)

        // Turned off: no request.
        let off = try ServiceHarness(t) { $0.isEnabled = { false } }
        _ = off.service.attach(off.subscription, to: oslo, persistent: true)
        off.read()
        t.equal(off.requests, 0)
        // No transport at all (the core default): nothing.
        let none = WeatherService(environment: .offline)
        _ = none.attach(off.subscription, to: oslo, persistent: true)
        _ = none.read(oslo)
        none.drain()
        t.equal(none.requestCount, 0)
    }

    t.suite("Weather: fetch: disk cache for places written in skins only") {
        let folder = t.temporaryDirectory("weather-disk")
        let h = try ServiceHarness(t) { $0.cacheDirectory = folder }
        _ = h.service.attach(h.subscription, to: oslo, persistent: true)
        h.read()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("v1").path)) ?? []
        t.equal(Set(files), ["59.91_10.75.json", "59.91_10.75.meta.json"])
        // A new launch: the data comes from disk; no request before it expires.
        let h2 = try ServiceHarness(t) { $0.cacheDirectory = folder }
        _ = h2.service.attach(h2.subscription, to: oslo, persistent: true)
        h2.read()
        t.equal(h2.requests, 0, "fresh data from disk")
        t.check(h2.snapshot?.forecast != nil)
        t.check(weatherWait { h2.notified >= 1 }, "measures are told")
        h2.advanceReading(to: date("2026-09-26T12:31:00Z"))
        t.equal(h2.requests, 1, "asked again once it expires")
        t.equal(h2.transport.requests.first?.headers["If-Modified-Since"], "Sat, 26 Sep 2026 11:49:25 GMT")
        // This Mac's location: nothing on disk.
        let auto = t.temporaryDirectory("weather-auto")
        let h3 = try ServiceHarness(t) { $0.cacheDirectory = auto }
        _ = h3.service.attach(h3.subscription, to: oslo, persistent: false)
        h3.read()
        t.check(h3.snapshot?.forecast != nil)
        let autoFiles = (try? FileManager.default.contentsOfDirectory(atPath: auto.path)) ?? []
        t.equal(autoFiles, [], "nothing written for auto")
        t.equal(h3.service.diskCacheSummary().places, 0)
        t.equal(h.service.diskCacheSummary().places, 1)
    }

    t.suite("Weather: device location and places through the service") {
        let device = FakeDeviceLocation()
        let h = try ServiceHarness(t) { $0.deviceLocation = device }
        t.equal(h.service.deviceLocation(for: h.subscription), .pending)
        h.settle()
        t.check(weatherWait { h.notified >= 1 })
        t.equal(h.service.deviceLocation(for: h.subscription), .fix(oslo))
        t.equal(device.requests, 1, "kept for an hour")
        _ = h.service.deviceLocation(for: h.subscription, locate: true)
        h.settle()
        t.equal(device.requests, 2, "Locate asks again")
        _ = h.service.deviceLocation(for: h.subscription, locate: true)
        h.settle()
        t.equal(device.requests, 2, "at most once a minute")
        // No fix: retried after 1, 5, 15 minutes.
        let lost = FakeDeviceLocation()
        lost.result = .failure(.unavailable)
        let h2 = try ServiceHarness(t) { $0.deviceLocation = lost }
        _ = h2.service.deviceLocation(for: h2.subscription)
        h2.settle()
        t.equal(h2.service.deviceLocation(for: h2.subscription), .unavailable)
        t.equal(lost.requests, 1)
        h2.clock.advance(by: 61)
        _ = h2.service.deviceLocation(for: h2.subscription)
        h2.settle()
        t.equal(lost.requests, 2, "after a minute")
        h2.clock.advance(by: 200)
        _ = h2.service.deviceLocation(for: h2.subscription)
        t.equal(lost.requests, 2, "then five")
        lost.authorization = .denied
        t.equal(h2.service.deviceLocation(for: h2.subscription), .denied)
        // Places: offline, memoized, the table released when unused.
        t.equal(h.service.lookUpPlace("Oslo, NO", for: h.subscription), .pending)
        h.settle()
        if case .found(let m) = h.service.lookUpPlace("Oslo, NO", for: nil) {
            t.equal(m.place.coordinate, oslo)
        } else {
            t.check(false, "Oslo found")
        }
        t.check(h.service.placeTableLoaded)
        h.clock.advance(by: 121)
        h.settle()
        t.check(!h.service.placeTableLoaded, "released after 2 minutes")
        t.equal(h.service.lookUpPlace("oslo, no", for: nil).isFound, true, "memoized")
        _ = h.service.nearby(RoundedCoordinate(latitude: 60.39, longitude: 5.32), for: nil)
        h.settle()
        if case .done(let n) = h.service.nearby(RoundedCoordinate(latitude: 60.39, longitude: 5.32), for: nil) {
            t.equal(n.match?.displayName, "Bergen")
            t.equal(n.timeZone, "Europe/Oslo")
        } else {
            t.check(false, "nearby")
        }
        let missing = try ServiceHarness(t) { $0.placesTable = URL(fileURLWithPath: "/nonexistent/places.tsv") }
        _ = missing.service.lookUpPlace("Oslo", for: nil)
        missing.settle()
        t.equal(missing.service.lookUpPlace("Oslo", for: nil), .unavailable)
    }
}

private extension PlaceLookup {
    var isFound: Bool {
        if case .found = self { return true }
        return false
    }
}

// MARK: - The real transport

func runWeatherTransportTests(_ t: TestRunner) {
    t.suite("Weather: transport: requests to the loopback server") {
        guard let server = WebParserTestServer() else { return t.check(false, "test server") }
        defer { server.stop() }
        server.handler = { r in
            if r.target.hasPrefix("/redirect") {
                return .init(status: 302, headers: ["Location": server.url("/other")], body: Data())
            }
            if r.target.hasPrefix("/big") {
                return .init(status: 200, headers: [:], body: Data(repeating: 65, count: 5000))
            }
            // MET refuses more than four decimals: so does this server.
            let lat = r.target.components(separatedBy: "lat=").last?.split(separator: "&").first ?? ""
            if (lat.split(separator: ".").last?.count ?? 0) > 4 { return .init(status: 403) }
            if r.headers["if-modified-since"] != nil {
                return .init(status: 304, headers: ["Date": WeatherFixtures.headers["Date"]!,
                                                    "Expires": WeatherFixtures.headers["Expires"]!])
            }
            return .init(status: 200, headers: WeatherFixtures.headers, body: WeatherFixtures.complete)
        }
        let transport = URLSessionWeatherTransport(allowsLoopbackHTTP: true, maxBytes: 4 * 1024 * 1024)
        let clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        var env = weatherTestEnvironment(t, transport: transport, clock: clock)
        env.endpoint = URL(string: server.url("/weatherapi/locationforecast/2.0/complete"))!
        env.userAgent = METNorway.userAgent(version: "1.2.3")
        let service = WeatherService(environment: env)
        let skin = try makeSkin(t, "[Rainmeter]\n[M]\nMeasure=Calc\n").0
        let subscription = WeatherSubscription(hop: skin.hop()) {}
        _ = service.attach(subscription, to: oslo, persistent: true)
        _ = service.read(oslo)
        t.check(weatherWait(20) { service.peek(oslo)?.forecast != nil }, "fetched from the server")
        guard let r = server.requests.first else { return t.check(false, "request") }
        t.equal(r.method, "GET")
        t.equal(r.target, "/weatherapi/locationforecast/2.0/complete?lat=59.91&lon=10.75")
        t.check(!r.target.contains("altitude"))
        let ua = r.headers["user-agent"] ?? ""
        t.check(ua.range(of: #"^Deskset/\S+ \(\+https://github\.com/jokyme/Deskset\)$"#, options: .regularExpression) != nil,
                ua)
        t.equal(ua, "Deskset/1.2.3 (+https://github.com/jokyme/Deskset)")
        t.equal(r.headers["accept"], "application/json")
        t.equal(server.requests.count, 1, "one GET, no HEAD")
        // A conditional request gets the 304 (no URL cache in between).
        service.refresh(oslo)   // fresh data: only re-read
        clock.advance(to: date("2026-09-26T12:40:00Z"))
        _ = service.read(oslo)
        t.check(weatherWait(20) { server.requests.count == 2 && service.peek(oslo)?.isFetching == false },
                "asked again")
        t.equal(server.requests.last?.headers["if-modified-since"], "Sat, 26 Sep 2026 11:49:25 GMT")
        t.equal(service.peek(oslo)?.validatedAt, date("2026-09-26T12:40:00Z"), "304 reached the service")

        func get(_ url: String, _ tr: URLSessionWeatherTransport = transport) -> Result<WeatherHTTPResponse, WeatherTransportError>? {
            var result: Result<WeatherHTTPResponse, WeatherTransportError>?
            let lock = NSLock()
            tr.get(WeatherHTTPRequest(url: URL(string: url)!, headers: [:])) { r in lock.lock(); result = r; lock.unlock() }
            _ = weatherWait(20) { lock.lock(); defer { lock.unlock() }; return result != nil }
            return result
        }
        if case .failure(.refused)? = get(server.url("/redirect")) {} else { t.check(false, "a redirect to HTTP is refused") }
        let small = URLSessionWeatherTransport(allowsLoopbackHTTP: true, maxBytes: 1000)
        if case .failure(.refused)? = get(server.url("/big"), small) {} else { t.check(false, "too large") }
        if case .success(let r)? = get(server.url("/weatherapi/x?lat=59.12345&lon=1")) {
            t.equal(r.status, 403, "five decimals are refused by MET")
        }
        let strict = URLSessionWeatherTransport()
        t.check(!strict.allows(URL(string: "http://api.met.no/x")!), "plain HTTP")
        t.check(!strict.allows(URL(string: server.url("/x"))!), "loopback HTTP only in tests")
        t.check(strict.allows(URL(string: "https://api.met.no/x")!))
        t.check(strict.allows(URL(string: "https://api.met.no/x")!, redirect: true))
        t.check(!strict.allows(URL(string: "https://example.com/x")!, redirect: true), "a redirect off met.no")
        t.check(!strict.allows(URL(string: "ftp://api.met.no/x")!))
        if case .failure(.refused)? = get("http://example.invalid/x", strict) {} else { t.check(false, "not HTTPS") }
    }
}
