import Foundation
@testable import DesksetCore

// The weather service's request policy (fake transport, virtual clock), the real transport against the loopback test
// server, and the plugins in skins (TestSkins/Plugins/Weather/Weather.ini).

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

/// Location Services that answer when the test says so (the user answers the question, the fix comes later).
final class LateDeviceLocation: DeviceLocationSource {
    private let lock = NSLock()
    private var _authorization = DeviceLocationAuthorization.authorized
    private var waiting: [(Result<RoundedCoordinate, DeviceLocationError>) -> Void] = []
    private var _requests = 0

    var authorization: DeviceLocationAuthorization {
        get { lock.lock(); defer { lock.unlock() }; return _authorization }
        set { lock.lock(); _authorization = newValue; lock.unlock() }
    }

    var requests: Int { lock.lock(); defer { lock.unlock() }; return _requests }

    func cachedFix(maxAge: TimeInterval) -> RoundedCoordinate? { nil }

    func requestFix(_ completion: @escaping (Result<RoundedCoordinate, DeviceLocationError>) -> Void) {
        lock.lock()
        _requests += 1
        waiting.append(completion)
        lock.unlock()
    }

    /// Answers every request made so far.
    func answer(_ result: Result<RoundedCoordinate, DeviceLocationError>) {
        lock.lock()
        let pending = waiting
        waiting = []
        lock.unlock()
        for c in pending { c(result) }
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

        // 403: requests stop for a day (or until a relaunch); Refresh does not ask a server that refused.
        let h403 = try ServiceHarness(t, transport: .fixture(status: 403, headers: [:], body: Data()))
        _ = h403.service.attach(h403.subscription, to: oslo, persistent: true)
        h403.read()
        t.equal(h403.snapshot?.lastFailure, .refused)
        t.equal(WeatherService.status(of: h403.snapshot, now: h403.clock.now()), .refused)
        h403.advanceReading(to: date("2026-09-26T20:00:00Z"), step: 1800)
        t.equal(h403.requests, 1, "no automatic retry")
        h403.service.refresh(oslo)
        h403.settle()
        t.equal(h403.requests, 1, "not even with Refresh")
        h403.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(86_401), step: 1800)
        t.equal(h403.requests, 2, "a day later")
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

    t.suite("Weather: fetch: Refresh retries a network failure and nothing else") {
        // 429 with Retry-After: an hour, however often a skin runs Refresh.
        let busy = try ServiceHarness(t, transport: .fixture(status: 429, headers: ["Retry-After": "3600"], body: Data()))
        _ = busy.service.attach(busy.subscription, to: oslo, persistent: true)
        busy.read()
        for _ in 0..<10 {
            busy.clock.advance(by: 61)
            busy.service.refresh(oslo)
            busy.settle()
        }
        t.equal(busy.requests, 1, "Retry-After stands")
        t.check(busy.notified >= 1, "the measures read again")
        busy.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(3601), step: 60)
        t.equal(busy.requests, 2, "after the hour")
        // Server errors: their backoff stands too (5 minutes × 0.8 with random 0).
        let broken = try ServiceHarness(t, transport: .fixture(status: 503, headers: [:], body: Data()))
        _ = broken.service.attach(broken.subscription, to: oslo, persistent: true)
        broken.read()
        broken.clock.advance(by: 61)
        broken.service.refresh(oslo)
        broken.settle()
        t.equal(broken.requests, 1)
        broken.advanceReading(to: WeatherFixtures.clock.addingTimeInterval(241), step: 30)
        t.equal(broken.requests, 2)
        // A network failure: tried again at once (the network may be back), at most once a minute.
        var online = false
        let net = try ServiceHarness(t, transport: FakeWeatherTransport { _ in
            online ? .success(WeatherHTTPResponse(status: 200, headers: WeatherFixtures.headers, body: WeatherFixtures.complete))
                : .failure(.network("offline"))
        })
        _ = net.service.attach(net.subscription, to: oslo, persistent: true)
        net.read()
        t.equal(WeatherService.status(of: net.snapshot, now: net.clock.now()), .offline)
        net.clock.advance(by: 5)
        net.service.refresh(oslo)
        net.settle()
        t.equal(net.requests, 2, "at once")
        net.clock.advance(by: 5)
        online = true
        net.service.refresh(oslo)
        net.settle()
        t.equal(net.requests, 2, "once a minute")
        net.clock.advance(by: 60)
        net.service.refresh(oslo)
        net.settle()
        t.equal(net.requests, 3)
        t.equal(WeatherService.status(of: net.snapshot, now: net.clock.now()), .ready)
        // Data past Expires after a success: the schedule stands (30 minutes after the last request, plus the random
        // delay: 12:30:31), so Refresh loops do not line up on MET's expiry times.
        let expired = try ServiceHarness(t)
        _ = expired.service.attach(expired.subscription, to: oslo, persistent: true)
        expired.read()
        expired.advanceReading(to: date("2026-09-26T12:21:00Z"), step: 60)
        expired.service.refresh(oslo)
        expired.settle()
        t.equal(expired.requests, 1, "not before its time")
        expired.advanceReading(to: date("2026-09-26T12:30:31Z"), step: 30)
        t.equal(expired.requests, 2)
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

    t.suite("Weather: fetch: a place nobody shows stops; this Mac's location never reaches the disk or the log") {
        func files(_ folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("v1").path)) ?? []).sorted()
        }
        let bergen = RoundedCoordinate(latitude: 60.39, longitude: 5.32)
        // A skin with this Mac's location closes 10 minutes after the fetch: no further request, nothing on disk.
        let closed = t.temporaryDirectory("weather-closed")
        let h = try ServiceHarness(t) { $0.cacheDirectory = closed }
        _ = h.service.attach(h.subscription, to: oslo, persistent: false)
        h.read()
        h.advanceReading(to: date("2026-09-26T12:10:00Z"))
        h.service.detach(h.subscription)
        h.clock.advance(to: date("2026-09-26T13:00:00Z"))
        h.settle()
        t.equal(h.requests, 1, "a closed skin's place is not asked again")
        t.equal(h.clock.pendingCount, 0, "its timer is gone")
        t.equal(files(closed), [], "and nothing was written")
        // The same for a place written in a skin (its file stays from the first fetch).
        let typed = t.temporaryDirectory("weather-typed")
        let hTyped = try ServiceHarness(t) { $0.cacheDirectory = typed }
        _ = hTyped.service.attach(hTyped.subscription, to: oslo, persistent: true)
        hTyped.read()
        hTyped.advanceReading(to: date("2026-09-26T12:10:00Z"))
        hTyped.service.detach(hTyped.subscription)
        hTyped.clock.advance(to: date("2026-09-26T13:00:00Z"))
        hTyped.settle()
        t.equal(hTyped.requests, 1)
        t.equal(files(typed), ["59.91_10.75.json", "59.91_10.75.meta.json"])
        // Back within 10 minutes: the data is still there and the schedule goes on.
        let back = try ServiceHarness(t)
        _ = back.service.attach(back.subscription, to: oslo, persistent: true)
        back.read()
        back.advanceReading(to: date("2026-09-26T12:10:00Z"))
        back.service.detach(back.subscription)
        back.clock.advance(to: date("2026-09-26T12:15:00Z"))
        _ = back.service.attach(back.subscription, to: oslo, persistent: true)
        t.check(back.read()?.forecast != nil, "the data is kept")
        t.equal(back.requests, 1)
        back.advanceReading(to: date("2026-09-26T12:31:00Z"), step: 60)
        t.equal(back.requests, 2, "the next request at its time")

        // This Mac's location moves to another rounded point: the old one is not asked again nor written.
        let moved = t.temporaryDirectory("weather-moved")
        let hMove = try ServiceHarness(t) { $0.cacheDirectory = moved }
        _ = hMove.service.attach(hMove.subscription, to: oslo, persistent: false)
        hMove.read()
        hMove.advanceReading(to: date("2026-09-26T12:10:00Z"))
        _ = hMove.service.attach(hMove.subscription, to: bergen, persistent: false)
        hMove.read(bergen)
        hMove.advanceReading(to: date("2026-09-26T13:00:00Z"), bergen)
        let asked = hMove.transport.requests.map { $0.url.query ?? "" }
        t.equal(asked.filter { $0.contains("lat=59.91") }.count, 1, "\(asked)")
        t.equal(files(moved), [], "no file for either point")

        // A request under way when the skin closes: its answer is kept in memory only.
        let flight = t.temporaryDirectory("weather-flight")
        let held = FakeWeatherTransport.fixture()
        held.hold = true
        let hFlight = try ServiceHarness(t, transport: held) { $0.cacheDirectory = flight }
        _ = hFlight.service.attach(hFlight.subscription, to: oslo, persistent: false)
        hFlight.read()
        t.equal(held.requests.count, 1)
        hFlight.service.detach(hFlight.subscription)
        held.release()
        hFlight.settle()
        t.check(hFlight.snapshot?.forecast != nil, "the answer arrived")
        t.equal(files(flight), [], "not written")
        t.equal(hFlight.clock.pendingCount, 0, "and nothing scheduled")

        // Offline backoff stops with the skin too.
        let offline = try ServiceHarness(t, transport: FakeWeatherTransport { _ in .failure(.network("offline")) })
        _ = offline.service.attach(offline.subscription, to: oslo, persistent: true)
        offline.read()
        offline.service.detach(offline.subscription)
        offline.clock.advance(to: date("2026-09-26T12:30:00Z"))
        offline.settle()
        t.equal(offline.requests, 1, "no retries for a closed skin")

        // WeatherDebug names places written in skins, never this Mac's location.
        let debug = try ServiceHarness(t) { $0.debug = true }
        _ = debug.service.attach(debug.subscription, to: oslo, persistent: false)
        debug.read()
        t.equal(debug.logs.all, ["Weather: requesting this Mac's location", "Weather: fetched (200) this Mac's location"])
        let debugTyped = try ServiceHarness(t) { $0.debug = true }
        _ = debugTyped.service.attach(debugTyped.subscription, to: oslo, persistent: true)
        debugTyped.read()
        t.equal(debugTyped.logs.all, ["Weather: requesting 59.91, 10.75", "Weather: fetched (200) 59.91, 10.75"])
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
        // Failures before the permission was given do not hold the first fix back once it is.
        let asking = LateDeviceLocation()
        asking.authorization = .notDetermined
        let h4 = try ServiceHarness(t) { $0.deviceLocation = asking }
        _ = h4.service.deviceLocation(for: h4.subscription)
        asking.answer(.failure(.unavailable))
        h4.settle()
        h4.clock.advance(by: 61)
        _ = h4.service.deviceLocation(for: h4.subscription)
        asking.answer(.failure(.unavailable))
        h4.settle()
        t.equal(asking.requests, 2)
        t.equal(h4.service.deviceLocation(for: h4.subscription), .unavailable, "the next try in 5 minutes")
        t.equal(asking.requests, 2)
        h4.clock.advance(by: 30)
        asking.authorization = .authorized
        t.equal(h4.service.deviceLocation(for: h4.subscription), .pending, "allowed: asked at once")
        t.equal(asking.requests, 3)
        asking.answer(.success(oslo))
        h4.settle()
        t.equal(h4.service.deviceLocation(for: h4.subscription), .fix(oslo))
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

// MARK: - The plugins in skins

/// A host that knows the SF Symbols the weather plugins name (32 × 32 at any size), like the app does.
final class WeatherSymbolHost: FakeHost {
    static let known: Set<String> = {
        var names = Set(WeatherCondition.all.flatMap { [$0.daySymbol, $0.nightSymbol] })
        names.formUnion(names.map { $0.hasSuffix(".fill") ? String($0.dropLast(5)) : $0 })
        names.insert("cloud.fill")
        names.insert("cloud")
        names.formUnion(WeatherSymbols.moon)
        names.formUnion(WeatherStatus.allCases.map(WeatherSymbols.status).filter { !$0.isEmpty })
        return names
    }()

    override func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        guard let symbol = MacSymbol(path: path) else { return super.imageSize(atPath: path) }
        return WeatherSymbolHost.known.contains(symbol.name) ? (32, 32) : nil
    }
}

private func weatherSkin(_ t: TestRunner, file: URL? = nil, ini: String? = nil,
                         host: FakeHost = WeatherSymbolHost()) throws -> (Skin, FakeHost) {
    if let ini { return try makeSkin(t, ini, host: host) }
    let testSkins = WeatherFixtures.repository.appendingPathComponent("TestSkins")
    let url = file ?? testSkins.appendingPathComponent("Plugins/Weather/Weather.ini")
    let skin = Skin(config: "Plugins\\Weather", fileURL: url, skinsDirectory: testSkins, system: FakeSystem(), host: host)
    retainedWeatherHosts.append(host)
    try skin.load()
    return (skin, host)
}

private var retainedWeatherHosts: [FakeHost] = []

private func value(_ skin: Skin, _ name: String) -> Double { skin.measure(named: name)?.value ?? .nan }
private func string(_ skin: Skin, _ name: String) -> String { skin.measure(named: name)?.stringValue ?? "<none>" }

/// Updates the skin until its weather is ready (the lookups and the fetch run on the service's queue).
@discardableResult
private func updateUntilReady(_ skin: Skin, root: String = "MeasureWeather", timeout: TimeInterval = 10) -> Bool {
    let ok = weatherWait(timeout) {
        WeatherService.shared.drain()
        skin.update()
        return (skin.measure(named: root) as? MacWeatherMeasure)?.status.showsData == true
    }
    skin.update()
    return ok
}

func runWeatherMeasureTests(_ t: TestRunner) {
    defer { WeatherService.install(.offline) }

    t.suite("Weather: measure: the fixture skin with MET Norway's forecast") {
        let transport = FakeWeatherTransport.fixture()
        let clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        WeatherService.install(weatherTestEnvironment(t, transport: transport, clock: clock))
        let (skin, host) = try weatherSkin(t)
        skin.update()
        t.equal(value(skin, "MeasureStatus"), 1, "Loading while the place is looked up")
        t.equal(string(skin, "MeasureWeather"), "--", "UnavailableText")
        t.check(updateUntilReady(skin), "ready: \(string(skin, "MeasureStatus"))")
        t.equal(transport.requests.count, 1)
        t.equal(transport.requests.first?.url.query, "lat=59.91&lon=10.75", "Oslo, NO from the place table")
        t.equal(text(skin, "MeterPlace"), "Oslo")
        t.equal(text(skin, "MeterTemperature"), "16°")
        t.equal(text(skin, "MeterCondition"), "Mostly clear")
        t.equal(value(skin, "MeasureHigh"), 18, "Decimals=0 from the parent")
        t.equal(value(skin, "MeasureLow"), 13, "12.5: half away from zero")
        t.equal(string(skin, "MeasureSymbol"), "sun.max.fill")
        t.equal(value(skin, "MeasureSymbol"), 2, "legacy number")
        t.equal(value(skin, "MeasureHumidity"), 54)
        t.equal(value(skin, "MeasureWind"), 8, "2.2 m/s in km/h (Units=Metric)")
        t.equal(string(skin, "MeasureWindUnit"), "km/h")
        t.equal(string(skin, "MeasureWindFrom"), "W")
        t.equal(value(skin, "MeasureRainChance"), 0)
        t.equal(string(skin, "MeasureH1Time"), "14:00", "Oslo time")
        t.equal(value(skin, "MeasureH1Temp"), 17)
        t.equal(string(skin, "MeasureH3Symbol"), "sun.max.fill")
        t.equal(string(skin, "MeasureH6Time"), "19:00")
        t.equal(string(skin, "MeasureH6Symbol"), "moon.stars.fill")
        t.equal(string(skin, "MeasureD1Name"), "Sun")
        t.equal(value(skin, "MeasureD1High"), 17)
        t.equal(value(skin, "MeasureD1Low"), 10)
        t.equal(string(skin, "MeasureD1Symbol"), "cloud.sun.fill")
        t.equal(string(skin, "MeasureD2Name"), "Mon")
        t.equal(string(skin, "MeasureD2Symbol"), "cloud.drizzle.fill")
        t.equal(value(skin, "MeasureD2Rain"), 63)
        t.equal(string(skin, "MeasurePlace"), "Oslo")
        t.equal(string(skin, "MeasureAttribution"), "Based on data from MET Norway")
        t.equal(string(skin, "MeasureSourceURL"), "https://api.met.no/")
        let updated = TimeFormatting.format(WeatherFixtures.clock, format: "%H:%M", timeZone: .current)
        t.equal(string(skin, "MeasureStatus"), "Updated \(updated)")
        t.equal(string(skin, "MeasureUpdated"), updated)
        t.check(text(skin, "MeterAttribution").hasPrefix("Based on data from MET Norway  ·  Updated"))
        // Sun times (MacSun, offline): 05:10 UTC ± a minute, shown in Oslo time.
        let sunrise = TimeFormatting.date(fromWindowsTimestamp: value(skin, "MeasureSunrise"),
                                          timeZone: WeatherFixtures.zone("Europe/Oslo"))
        t.check(abs(sunrise.timeIntervalSince(date("2026-09-26T05:10:25Z"))) < 90, "sunrise \(sunrise)")
        t.check(string(skin, "MeasureSunrise").hasPrefix("07:"), string(skin, "MeasureSunrise"))
        t.check(value(skin, "MeasureDaylight") > 0.5 && value(skin, "MeasureDaylight") < 0.7)
        // Automatic ranges: High/Low over the week, so range bars line up.
        let high = skin.measure(named: "MeasureD1High")
        t.check((high?.maxValue ?? 0) >= 17.9 && (high?.minValue ?? 99) <= 10.2, "week range")
        t.equal(skin.measure(named: "MeasureHumidity")?.maxValue, 100)
        t.equal(skin.issues, [], "\(skin.issues)")
        t.check(skin.meter(named: "MeterSetLocation")?.hidden == true)
        // Refresh with fresh data: no request.
        skin.execute("[!CommandMeasure MeasureWeather \"Refresh\"]", from: nil)
        WeatherService.shared.drain()
        t.equal(transport.requests.count, 1, "fresh data is not fetched again")
        // Another place: the measure moves to another feed.
        skin.execute("[!SetOption MeasureWeather Location \"Bergen, NO\"][!UpdateMeasure MeasureWeather]", from: nil)
        t.check(weatherWait {
            WeatherService.shared.drain()
            skin.update()
            return transport.requests.count == 2 && string(skin, "MeasurePlace") == "Bergen"
        }, "moved to Bergen: \(transport.requests.map(\.url))")
        t.equal(transport.requests.last?.url.query, "lat=60.39&lon=5.32")
        t.equal(WeatherService.shared.livePlaces, [RoundedCoordinate(latitude: 60.39, longitude: 5.32)])
        _ = host
        skin.close()
    }

    t.suite("Weather: measure: actions, parents, units, curves and section variables") {
        let transport = FakeWeatherTransport.fixture()
        let clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        WeatherService.install(weatherTestEnvironment(t, transport: transport, clock: clock))
        let (skin, host) = try weatherSkin(t, ini: """
        [Rainmeter]
        Update=1000
        [Variables]
        Finished=0
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Location=59.91, 10.75
        Units=Imperial
        FinishAction=[!SetVariable Finished "(#Finished#+1)"][!Log "finish W"]
        OnConnectErrorAction=[!Log "connect error"]
        [F]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=Temperature
        Decimals=1
        [C]
        Measure=Plugin
        Plugin=MacWeather
        Parent=F
        Type=Temperature
        TemperatureUnit=C
        [Curve]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=TemperatureCurve
        Hours=6
        CurveWidth=100
        CurveHeight=20
        [Color]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=TemperatureColor
        Day=1
        [Place]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=PlaceDetail
        [Zone]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=TimeZone
        [Beaufort]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=Beaufort
        [Code]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=SymbolCode
        Hour=6
        [Bad]
        Measure=Plugin
        Plugin=MacWeather
        Parent=Nobody
        [T]
        Meter=String
        MeasureName=W
        """)
        t.check(updateUntilReady(skin, root: "W"), "ready")
        t.check(weatherWait { skin.update(); return host.logs.contains { $0.contains("finish W") } }, "FinishAction")
        for _ in 0..<3 { skin.update() }
        t.equal(host.logs.filter { $0.contains("finish W") }.count, 1, "once: \(host.logs)")
        t.equal(skin.variable("Finished"), "1")
        t.close(value(skin, "W"), 16.3 * 9 / 5 + 32, accuracy: 1e-9, "Imperial")
        t.equal(value(skin, "F"), 61.3, "Decimals=1, Imperial from the parent")
        t.equal(value(skin, "C"), 16.3, "own TemperatureUnit, Decimals from the grandparent chain")
        let curve = string(skin, "Curve")
        t.check(curve.hasPrefix("0, "), curve)
        t.equal(curve.components(separatedBy: "CurveTo").count, 6, "six hours → five curves")
        t.check((skin.measure(named: "Curve")?.maxValue ?? 0) > (skin.measure(named: "Curve")?.minValue ?? 0))
        t.equal(string(skin, "Color").split(separator: ",").count, 3)
        t.equal(string(skin, "Place"), "Oslo, Oslo, Norway", "nearest place within 50 km")
        t.equal(string(skin, "Zone"), "Europe/Oslo")
        t.equal(value(skin, "Zone"), 2)
        t.equal(string(skin, "Beaufort"), "Light breeze")
        t.equal(string(skin, "Code"), "clearsky_night")
        t.check(host.logs.contains { $0.contains("Parent=Nobody") }, "a broken parent is logged")
        t.equal(skin.resolve("[&W:Now(Humidity, 0)]", in: nil, sectionVariables: true), "54")
        t.equal(skin.resolve("[&W:Day(1, High, 1)]", in: nil, sectionVariables: true), "61.7")
        t.equal(skin.resolve("[&W:Hour(3, Symbol)]", in: nil, sectionVariables: true), "sun.max.fill")
        // The index and the decimals come from the skin: clamped as the options are, never used as they are.
        func call(_ f: String) -> String { skin.resolve("[&W:\(f)]", in: nil, sectionVariables: true) }
        t.equal(call("Day(-1, High, 1)"), call("Day(0, High, 1)"), "Day(-1): today")
        t.equal(call("Day(-1, Condition)"), call("Day(0, Condition)"))
        t.equal(call("Day(10, High, 1)"), call("Day(9, High, 1)"), "Day(10): day 9")
        t.check(!call("Day(9, High, 1)").isEmpty, "day 9 has a high")
        t.equal(call("Day(1e20, Symbol)"), call("Day(9, Symbol)"))
        t.equal(call("Hour(1e19, Temperature, 1)"), call("Hour(47, Temperature, 1)"), "Hour(1e19): hour 47")
        t.equal(call("Hour(-3, Temperature, 1)"), call("Hour(0, Temperature, 1)"))
        t.equal(call("Now(Temperature, 1e19)"), call("Now(Temperature, 6)"), "decimals 0–6")
        t.equal(call("Now(Temperature, -1e19)"), call("Now(Temperature, 0)"))
        skin.close()
    }

    t.suite("Weather: measure: automatic ranges of daily values") {
        WeatherService.install(weatherTestEnvironment(t, clock: VirtualWeatherClock(now: WeatherFixtures.clock)))
        let (skin, _) = try weatherSkin(t, ini: """
        [Rainmeter]
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Location=59.91, 10.75
        Units=Metric
        [Rain6]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=Precipitation
        Day=6
        [RainNow]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=Precipitation
        [Wind1]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=WindSpeed
        Day=1
        [Gust1]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=WindGust
        Day=1
        [WindNow]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=WindSpeed
        [High0]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=High
        Day=0
        [High9]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=High
        Day=9
        [Low8]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=Low
        Day=8
        [Length]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=DayLength
        """)
        t.check(updateUntilReady(skin, root: "W"), "ready")
        func range(_ name: String) -> (value: Double, min: Double, max: Double) {
            let m = skin.measure(named: name)
            return (m?.value ?? .nan, m?.minValue ?? .nan, m?.maxValue ?? .nan)
        }
        func inside(_ name: String, line: UInt = #line) {
            let r = range(name)
            t.check(r.min <= r.value && r.value <= r.max, "\(name): \(r.value) in \(r.min)…\(r.max)", line: line)
        }
        t.close(range("Rain6").value, 3.1, accuracy: 0.051, "day 6's rain")
        inside("Rain6")
        t.check(range("Rain6").max < 10, "the largest daily total: \(range("Rain6").max)")
        t.equal(range("RainNow").max, 1, "a dry day ahead: hourly amounts, at least 1 mm")
        inside("Wind1")
        inside("Gust1")
        t.check(range("Wind1").max > range("WindNow").max, "days against days, hours against hours")
        inside("WindNow")
        for name in ["High0", "High9", "Low8"] { inside(name) }
        t.equal(range("High9").min, range("High0").min, "the same range for every day")
        t.equal(range("High9").max, range("High0").max)
        t.equal(range("Length").max, 86_400)
        inside("Length")
        skin.close()
        // The demo forecast's warmest and coldest days are 7 and 8: High and Low span all ten days.
        var demo = weatherTestEnvironment(t)
        demo.isLive = { _ in false }
        demo.demo = true
        demo.demoNow = date("2026-09-26T12:00:00Z")
        WeatherService.install(demo)
        let (days, _) = try weatherSkin(t, ini: (0..<10).map { n in """
            [High\(n)]
            Measure=Plugin
            Plugin=MacWeather
            Location=59.91,10.75
            Type=High
            Day=\(n)
            [Low\(n)]
            Measure=Plugin
            Plugin=MacWeather
            Location=59.91,10.75
            Type=Low
            Day=\(n)
            """ }.joined(separator: "\n"))
        days.update()
        for n in 0..<10 {
            for name in ["High\(n)", "Low\(n)"] {
                let m = days.measure(named: name)
                let v = m?.value ?? .nan, lo = m?.minValue ?? .nan, hi = m?.maxValue ?? .nan
                t.check(lo <= v && v <= hi, "\(name): \(v) in \(lo)…\(hi)")
            }
        }
        days.close()
    }

    t.suite("Weather: measure: IsDaylight follows the sun, not the clouds") {
        // The demo forecast's icons take MET's day and night forms from Oslo's sun; in Tromsø's polar night
        // IsDaylight is 2 around noon and 0 in the evening, whatever the sky.
        var demo = weatherTestEnvironment(t)
        demo.isLive = { _ in false }
        demo.demo = true
        demo.demoNow = date("2026-12-21T11:00:00Z")
        WeatherService.install(demo)
        let (skin, _) = try weatherSkin(t, ini: """
        [Rainmeter]
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Location=69.65,18.96
        Type=IsDaylight
        """)
        for _ in 0..<3 {
            skin.update()
            WeatherService.shared.drain()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        t.equal(value(skin, "W"), 2, "now")
        func hour(_ n: Int) -> String { skin.resolve("[&W:Hour(\(n), IsDaylight)]", in: nil, sectionVariables: true) }
        t.equal((0...2).map(hour), ["2", "2", "0"], "11:30 and 12:30 UTC; at 13:30 the sun is 7.8° down")
        t.equal((6...9).map(hour), ["0", "0", "0", "0"], "the evening")
        t.check(skin.resolve("[&W:Hour(0, SymbolCode)]", in: nil, sectionVariables: true).hasSuffix("_day"),
                "the icon has its own (day) form")
        skin.close()
    }

    t.suite("Weather: measure: states without data") {
        func status(_ ini: String, env: (inout WeatherEnvironment) -> Void = { _ in }) throws -> (Skin, FakeHost) {
            var e = weatherTestEnvironment(t)
            env(&e)
            WeatherService.install(e)
            let (skin, host) = try weatherSkin(t, ini: """
            [Rainmeter]
            [W]
            Measure=Plugin
            Plugin=MacWeather
            \(ini)
            UnavailableText=--
            OnLocationErrorAction=[!Log "location error"]
            [S]
            Measure=Plugin
            Plugin=MacWeather
            Parent=W
            Type=Status
            [Sun]
            Measure=Plugin
            Plugin=MacWeather
            Parent=W
            Type=Sunrise
            """)
            for _ in 0..<20 {
                WeatherService.shared.drain()
                skin.update()
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            return (skin, host)
        }
        var (skin, host) = try status("Location=")
        t.equal(value(skin, "S"), 3)
        t.equal(string(skin, "S"), "Set a location")
        t.equal(string(skin, "W"), "--")
        t.equal(string(skin, "Sun"), "--", "no place, no sun: UnavailableText")
        (skin, host) = try status("Location=Atlantis")
        t.equal(value(skin, "S"), 4)
        t.equal(string(skin, "S"), "Can't find “Atlantis”")
        t.check(skin.issues.contains { $0.contains("Atlantis") }, "\(skin.issues)")
        t.equal(host.logs.filter { $0.contains("location error") }.count, 1)
        (skin, host) = try status("Location=Oslo") { $0.isEnabled = { false } }
        t.equal(value(skin, "S"), 11)
        t.check(!string(skin, "Sun").isEmpty, "sun times without the forecast")
        (skin, host) = try status("Location=Oslo") { $0.isLive = { _ in false } }
        t.equal(value(skin, "S"), 12)
        t.equal(string(skin, "S"), "Preview · live weather shows on the desktop")
        t.check(!string(skin, "Sun").isEmpty, "sun times in previews")
        let device = FakeDeviceLocation()
        (skin, host) = try status("Location=auto") { $0.deviceLocation = device }
        t.equal(value(skin, "S"), 0, "this Mac's location: \(string(skin, "S"))")
        device.authorization = .denied
        (skin, host) = try status("Location=auto") { $0.deviceLocation = device }
        t.equal(value(skin, "S"), 5)
        t.check(skin.issues.contains { $0.contains("Location Services") })
        let lost = FakeDeviceLocation()
        lost.result = .failure(.unavailable)
        (skin, host) = try status("Location=auto") { $0.deviceLocation = lost }
        t.equal(value(skin, "S"), 6)
        let untouched = FakeDeviceLocation()
        (skin, host) = try status("Location=auto") { $0.isLive = { _ in false }; $0.deviceLocation = untouched }
        t.equal(value(skin, "S"), 12, "previews never ask for the location")
        t.equal(untouched.requests, 0)
        (skin, host) = try status("Location=Oslo") { $0.transport = FakeWeatherTransport.fixture(status: 404, headers: [:], body: Data()) }
        t.equal(value(skin, "S"), 7)
        // Demo data for screenshots.
        (skin, host) = try status("Location=Oslo") { $0.isLive = { _ in false }; $0.demo = true }
        t.equal(value(skin, "S"), 0, "demo")
        t.check(!string(skin, "W").isEmpty && string(skin, "W") != "--")
        _ = host
    }

    t.suite("Weather: measure: OnConnectErrorAction once per run of failures; the measures following run theirs") {
        var online = false
        let transport = FakeWeatherTransport { _ in
            online ? .success(WeatherHTTPResponse(status: 200, headers: WeatherFixtures.headers, body: WeatherFixtures.complete))
                : .failure(.network("offline"))
        }
        let clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        WeatherService.install(weatherTestEnvironment(t, transport: transport, clock: clock))
        let ini = """
        [Rainmeter]
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Location=59.91, 10.75
        FinishAction=[!Log "finish W"]
        OnConnectErrorAction=[!Log "connect error W"]
        [C]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=High
        FinishAction=[!Log "finish C"]
        OnConnectErrorAction=[!Log "connect error C"]
        [Off]
        Measure=Plugin
        Plugin=MacWeather
        Parent=C
        Disabled=1
        FinishAction=[!Log "finish Off"]
        """
        func count(_ host: FakeHost, _ text: String) -> Int { host.logs.filter { $0.contains(text) }.count }
        func settle(_ skin: Skin) {
            for _ in 0..<3 {
                WeatherService.shared.drain()
                skin.update()
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }
        let (a, aHost) = try weatherSkin(t, ini: ini)
        settle(a)
        t.check(weatherWait { WeatherService.shared.drain(); return count(aHost, "connect error W") == 1 },
                "the failure: \(aHost.logs)")
        // Back online: the retry succeeds.
        online = true
        clock.advance(by: 61)
        t.check(updateUntilReady(a, root: "W"), "ready")
        settle(a)
        t.equal(count(aHost, "connect error W"), 1, "once for the run of failures")
        t.equal(count(aHost, "connect error C"), 1, "the measure following it too")
        t.equal(count(aHost, "finish W"), 1)
        t.equal(count(aHost, "finish C"), 1, "after it")
        t.equal(count(aHost, "finish Off"), 0, "not a disabled one")
        if let w = aHost.logs.firstIndex(where: { $0.contains("finish W") }),
           let c = aHost.logs.firstIndex(where: { $0.contains("finish C") }) {
            t.check(w < c, "the parent first: \(aHost.logs)")
        }
        // A refresh (a new skin from the same file) or a second skin with the place: the failure is over.
        a.close()
        let (b, bHost) = try weatherSkin(t, ini: ini)
        t.check(updateUntilReady(b, root: "W"), "ready")
        settle(b)
        t.equal(count(bHost, "connect error"), 0, "an old failure is not new: \(bHost.logs)")
        t.equal(count(bHost, "finish W"), 1)
        // Another place (a new feed, no failures): nothing either; its own failure later: once.
        b.execute("[!SetOption W Location \"60.39, 5.32\"][!UpdateMeasure W]", from: nil)
        t.check(weatherWait {
            WeatherService.shared.drain()
            b.update()
            return transport.requests.contains { $0.url.query == "lat=60.39&lon=5.32" }
                && (b.measure(named: "W") as? MacWeatherMeasure)?.status == .ready
        }, "moved to Bergen")
        settle(b)
        t.equal(count(bHost, "connect error"), 0, "\(bHost.logs)")
        online = false
        let limit = clock.now().addingTimeInterval(45 * 60)
        while count(bHost, "connect error W") == 0 && clock.now() < limit {
            clock.advance(by: 60)
            settle(b)
        }
        t.equal(count(bHost, "connect error W"), 1, "Bergen's own failure")
        t.equal(count(bHost, "connect error C"), 1)
        b.close()

        // OnLocationErrorAction of a measure following one whose place cannot be found.
        let (lost, lostHost) = try weatherSkin(t, ini: """
        [Rainmeter]
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Location=Atlantis
        [C]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        OnLocationErrorAction=[!Log "location error C"]
        """)
        t.check(weatherWait {
            WeatherService.shared.drain()
            lost.update()
            return (lost.measure(named: "W") as? MacWeatherMeasure)?.status == .placeNotFound
        }, "not found")
        settle(lost)
        t.equal(count(lostHost, "location error C"), 1)
        lost.close()
    }

    t.suite("Weather: measure: the place and the forecast arrive without another update") {
        let transport = FakeWeatherTransport.fixture()
        let clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        var env = weatherTestEnvironment(t, transport: transport, clock: clock)
        let late = LateDeviceLocation()
        env.deviceLocation = late
        WeatherService.install(env)
        func skin(_ location: String) throws -> (Skin, FakeHost) {
            try weatherSkin(t, ini: """
            [Rainmeter]
            Update=-1
            [W]
            Measure=Plugin
            Plugin=MacWeather
            Location=\(location)
            FinishAction=[!Log "finish W"]
            [Hi]
            Measure=Plugin
            Plugin=MacWeather
            Parent=W
            Type=High
            Decimals=1
            """)
        }
        func status(_ s: Skin) -> WeatherStatus? { (s.measure(named: "W") as? MacWeatherMeasure)?.status }
        // A place name is looked up on the service's queue after the only update the skin makes.
        let (named, namedHost) = try skin("Oslo, NO")
        named.update()
        t.equal(status(named), .loading)
        t.check(weatherWait { WeatherService.shared.drain(); return status(named) == .ready },
                "ready without another update: \(String(describing: status(named)))")
        t.check(weatherWait { namedHost.logs.contains { $0.contains("finish W") } }, "FinishAction")
        t.equal(named.measure(named: "W")?.value, 16.3)
        t.equal(named.measure(named: "Hi")?.value, 17.9, "the measures following it too")
        t.equal(transport.requests.count, 1)
        // This Mac's location: the fix comes after the update.
        let (here, hereHost) = try skin("auto")
        here.update()
        WeatherService.shared.drain()
        t.equal(status(here), .loading)
        t.equal(late.requests, 1)
        late.answer(.success(oslo))
        t.check(weatherWait { WeatherService.shared.drain(); return status(here) == .ready },
                "ready once the fix came: \(String(describing: status(here)))")
        t.check(weatherWait { hereHost.logs.contains { $0.contains("finish W") } }, "FinishAction")
        named.close()
        here.close()
    }

    t.suite("Weather: measure: a closed skin with this Mac's location leaves nothing behind") {
        let folder = t.temporaryDirectory("weather-auto-skin")
        let transport = FakeWeatherTransport.fixture()
        let clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        var env = weatherTestEnvironment(t, transport: transport, clock: clock)
        env.cacheDirectory = folder
        env.deviceLocation = FakeDeviceLocation()
        WeatherService.install(env)
        let (skin, _) = try weatherSkin(t, ini: """
        [Rainmeter]
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Location=auto
        """)
        t.check(updateUntilReady(skin, root: "W"), "ready")
        while clock.now() < date("2026-09-26T12:10:00Z") {
            clock.advance(by: 60)
            WeatherService.shared.drain()
            skin.update()
        }
        skin.close()
        clock.advance(to: date("2026-09-26T13:30:00Z"))
        WeatherService.shared.drain()
        t.equal(transport.requests.count, 1, "nothing asked after the skin closed")
        t.equal((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"], [], "nothing written")
    }

    t.suite("Weather: measure: the offline default in the fixture skin") {
        var env = WeatherEnvironment.offline
        env.placesTable = WeatherFixtures.placesFixture
        WeatherService.install(env)
        let (skin, _) = try weatherSkin(t)
        for _ in 0..<10 {
            WeatherService.shared.drain()
            skin.update()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        t.equal(value(skin, "MeasureStatus"), 12, "Preview")
        t.equal(WeatherService.shared.requestCount, 0, "no network")
        t.check(!string(skin, "MeasureSunrise").isEmpty, "sun times still work")
        t.equal(string(skin, "MeasurePlace"), "Oslo")
        skin.close()
    }

    t.suite("Weather: measure: previews that wait for lookups have the place after one update") {
        // `--render` (waitsForLookups): the image must not depend on how fast the place table loads.
        var env = WeatherEnvironment.offline
        env.placesTable = WeatherFixtures.placesFixture
        env.clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        env.uses24HourClock = { true }
        env.waitsForLookups = true
        WeatherService.install(env)
        let (skin, _) = try weatherSkin(t, ini: """
        [Rainmeter]
        [Rise]
        Measure=Plugin
        Plugin=MacSun
        Location=Oslo, NO
        Type=Sunrise
        [Near]
        Measure=Plugin
        Plugin=MacWeather
        Location=59.95,10.80
        Type=Place
        [Zone]
        Measure=Plugin
        Plugin=MacWeather
        Parent=Near
        Type=TimeZone
        [Set]
        Measure=Plugin
        Plugin=MacWeather
        Parent=Near
        Type=Sunset
        """)
        skin.update()
        t.equal(string(skin, "Rise"), "07:10", "Oslo's sunrise on the first update")
        t.equal(string(skin, "Near"), "Oslo", "the nearest place")
        t.equal(string(skin, "Zone"), "Europe/Oslo", "and its time zone")
        t.equal(string(skin, "Set"), "19:04")
        t.equal(value(skin, "Near"), 0)
        skin.close()
    }

    t.suite("Weather: MacSun") {
        var env = WeatherEnvironment.offline
        env.placesTable = WeatherFixtures.placesFixture
        env.clock = VirtualWeatherClock(now: WeatherFixtures.clock)
        env.uses24HourClock = { true }
        WeatherService.install(env)
        let (skin, _) = try weatherSkin(t, ini: """
        [Rainmeter]
        [Rise]
        Measure=Plugin
        Plugin=MacSun
        Location=Tromsø
        Type=Sunrise
        [Set]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=Sunset
        Format=%H.%M
        [RiseJune]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=Sunrise
        Day=30
        [Polar]
        Measure=Plugin
        Plugin=MacSun
        Location=78.22,15.65
        Type=Sunrise
        Day=-1
        NoEventText=none
        [UTC]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=Sunrise
        TimeZone=UTC
        [Place]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=Place
        [Moon]
        Measure=Plugin
        Plugin=MacSun
        Type=MoonPhaseName
        [Light]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=IsDaylight
        [Elevation]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=SunElevation
        [Length]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=DayLength
        [Nowhere]
        Measure=Plugin
        Plugin=MacSun
        Type=Sunrise
        UnavailableText=?
        [Tokyo]
        Measure=Plugin
        Plugin=MacSun
        Location=35.68,139.69
        Type=TimeZone
        TimeZone=9
        [TokyoRise]
        Measure=Plugin
        Plugin=MacSun
        Parent=Tokyo
        Type=Sunrise
        [TokyoSummer]
        Measure=Plugin
        Plugin=MacSun
        Parent=Tokyo
        Type=TimeZone
        DaylightSavingTime=1
        [TokyoWeather]
        Measure=Plugin
        Plugin=MacWeather
        Location=35.68,139.69
        Type=TimeZone
        TimeZone=9
        """)
        for _ in 0..<10 {
            WeatherService.shared.drain()
            skin.update()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        t.check(string(skin, "Rise").hasPrefix("06:"), "Tromsø sunrise \(string(skin, "Rise"))")
        t.check(string(skin, "Set").hasPrefix("18."), "Format \(string(skin, "Set"))")
        t.check(string(skin, "UTC").hasPrefix("04:"), "TimeZone=UTC \(string(skin, "UTC"))")
        t.equal(string(skin, "Place"), "Tromsø")
        t.check(string(skin, "RiseJune") != string(skin, "Rise"), "Day offsets")
        t.check(string(skin, "Polar").contains(":"), "Longyearbyen still has a sunrise on 25 September")
        t.equal(value(skin, "Light"), 1)
        t.check(value(skin, "Elevation") > 10 && value(skin, "Elevation") < 30)
        t.check(string(skin, "Length").contains(":"))
        t.check(MoonPhase.names.contains(string(skin, "Moon")))
        t.equal(string(skin, "Nowhere"), "?")
        // TimeZone=9 is UTC+9 whatever this Mac's zone does (Tokyo's sunrise on 26 September: 05:32 local).
        t.equal(value(skin, "Tokyo"), 9)
        t.equal(value(skin, "TokyoWeather"), 9)
        t.check(string(skin, "TokyoRise").hasPrefix("05:3"), "Tokyo sunrise \(string(skin, "TokyoRise"))")
        let summerTime = Double(TimeZone.current.daylightSavingTimeOffset(for: WeatherFixtures.clock)) / 3600
        t.equal(value(skin, "TokyoSummer"), 9 + summerTime, "DaylightSavingTime=1: this Mac's summer time added")
        // Polar night: no sunrise (and the place's own time zone once the nearest place is known).
        env.clock = VirtualWeatherClock(now: date("2026-12-21T11:00:00Z"))
        WeatherService.install(env)
        let (dark, _) = try weatherSkin(t, ini: """
        [Rainmeter]
        [Rise]
        Measure=Plugin
        Plugin=MacSun
        Location=69.65,18.96
        Type=Sunrise
        NoEventText=polar
        [Dawn]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=CivilDawn
        [State]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=SunState
        [Zone]
        Measure=Plugin
        Plugin=MacSun
        Parent=Rise
        Type=TimeZone
        [WeatherRise]
        Measure=Plugin
        Plugin=MacWeather
        Location=69.65,18.96
        Type=Sunrise
        UnavailableText=no data
        [WeatherSet]
        Measure=Plugin
        Plugin=MacWeather
        Parent=WeatherRise
        Type=Sunset
        NoEventText=polar night
        [NowhereRise]
        Measure=Plugin
        Plugin=MacWeather
        Type=Sunrise
        UnavailableText=no data
        """)
        for _ in 0..<10 {
            WeatherService.shared.drain()
            dark.update()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        t.equal(string(dark, "Rise"), "polar", "Tromsø on 21 December")
        t.equal(value(dark, "State"), 2)
        t.equal(string(dark, "Zone"), "Europe/Oslo")
        t.check(string(dark, "Dawn").hasPrefix("09:"), "civil dawn \(string(dark, "Dawn"))")
        // MacWeather's sunrise and sunset tell "no sunrise" from "no data" as MacSun does.
        t.equal(string(dark, "WeatherRise"), "--:--", "no sunrise today")
        t.equal(string(dark, "WeatherSet"), "polar night", "its own NoEventText")
        t.equal(string(dark, "NowhereRise"), "no data", "no place: UnavailableText")
        skin.close()
    }
}

// MARK: - Weather symbols in Image meters (core part)

func runWeatherSymbolImageTests(_ t: TestRunner) {
    t.suite("Weather: symbols reach Image meters as sf: names") {
        // MacWeather's Symbol type gives an SF Symbol name; `ImageName=sf:%1` (the Mac look extension) draws it.
        let previous = WeatherService.shared.environment
        defer { WeatherService.install(previous) }
        var env = weatherTestEnvironment(t)
        env.isLive = { _ in false }
        env.demo = true
        env.demoNow = WeatherFixtures.clock
        WeatherService.install(env)
        let (skin, host) = try makeSkin(t, """
        [Rainmeter]
        [Symbol]
        Measure=Plugin
        Plugin=MacWeather
        Location=59.91,10.75
        Type=Symbol
        [Outline]
        Measure=Plugin
        Plugin=MacWeather
        Parent=Symbol
        Type=Symbol
        SymbolStyle=Outline
        [Icon]
        Meter=Image
        MeasureName=Symbol
        ImageName=sf:%1
        ImagePath=#@#Images
        MacSymbolRendering=Multicolor
        W=48
        H=48
        [OutlineIcon]
        Meter=Image
        MeasureName=Outline
        ImageName=sf:%1
        """)
        skin.update()
        guard let icon = skin.meter(named: "Icon") as? ImageMeter,
              let outline = skin.meter(named: "OutlineIcon") as? ImageMeter else { return t.check(false, "meters") }
        let name = skin.measure(named: "Symbol")?.stringValue ?? ""
        t.check(name.hasSuffix(".fill"), "a filled symbol name: \(name)")
        let symbol = icon.imagePath.flatMap { MacSymbol(path: $0) }
        t.equal(symbol?.name, name, "no ImagePath, no .png")
        t.equal(symbol?.style.rendering, .multicolor)
        let plain = outline.imagePath.flatMap { MacSymbol(path: $0) }
        t.equal(plain?.name, String(name.dropLast(5)), "SymbolStyle=Outline drops .fill")
        t.check(!host.logs.contains { $0.contains("Unable to open image") }, "no missing-file warnings: \(host.logs)")
        skin.close()
    }
}
