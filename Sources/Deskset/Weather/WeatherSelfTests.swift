import AppKit
import CoreLocation
import DesksetCore

/// `Deskset --self-test Weather`: the app side of the weather plugins (docs/compat/weather.md) — the wiring, Location
/// Services through `LocationCenter` (with a fake manager: nothing here asks macOS), the skin menu's credit, the SF
/// Symbols the plugins name, several threads reading one place, and the command-line reports. No test reaches the
/// network: forecasts come from the fixture in TestSkins/Plugins/@Resources/Weather through a fake transport.
enum WeatherSelfTests {
    static func run(_ t: AppTestRunner) {
        wiringTests(t)
        locationCenterTests(t)
        skinTests(t)
        symbolTests(t)
        threadTests(t)
        commandLineTests(t)
    }

    // MARK: Fixtures

    static var fixtures: URL? {
        Paths.repositoryFolder("TestSkins")?.appendingPathComponent("Plugins/@Resources/Weather")
    }

    /// When the fixture was fetched, and its response headers.
    static let fixtureClock = METNorway.parseISO8601("2026-09-26T11:59:31Z") ?? Date()
    static let fixtureHeaders = ["Date": "Sat, 26 Sep 2026 11:59:31 GMT", "Last-Modified": "Sat, 26 Sep 2026 11:49:25 GMT",
                                 "Expires": "Sat, 26 Sep 2026 12:20:14 GMT"]

    /// Answers every request with the fixture forecast; counts the requests; `hold` keeps the answers back.
    final class FixtureTransport: WeatherTransport {
        private let lock = NSLock()
        private var count = 0
        private var held: [() -> Void] = []
        var hold = false
        let body: Data

        init(body: Data) {
            self.body = body
        }

        var requests: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func get(_ request: WeatherHTTPRequest,
                 completion: @escaping (Result<WeatherHTTPResponse, WeatherTransportError>) -> Void) {
            let response = WeatherHTTPResponse(status: 200, headers: WeatherSelfTests.fixtureHeaders, body: body)
            lock.lock()
            count += 1
            if hold {
                held.append { completion(.success(response)) }
                lock.unlock()
                return
            }
            lock.unlock()
            completion(.success(response))
        }

        func release() {
            lock.lock()
            let pending = held
            held = []
            hold = false
            lock.unlock()
            for p in pending { p() }
        }
    }

    /// A transport that must never be used (the offline default and previews).
    final class ForbiddenTransport: WeatherTransport {
        private let calls = Guarded(0)
        var count: Int { calls.current }

        func get(_ request: WeatherHTTPRequest,
                 completion: @escaping (Result<WeatherHTTPResponse, WeatherTransportError>) -> Void) {
            calls.access { $0 += 1 }
            completion(.failure(.refused("no network in the self-tests")))
        }
    }

    final class FakeLocationManager: LocationManaging {
        var authorizationStatus: CLAuthorizationStatus = .notDetermined
        var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
        weak var delegate: CLLocationManagerDelegate?
        private(set) var questions = 0
        private(set) var requests = 0
        private(set) var stops = 0

        func requestWhenInUseAuthorization() { questions += 1 }
        func requestLocation() { requests += 1 }
        func stopUpdatingLocation() { stops += 1 }
    }

    /// A test environment: live for skin windows, the fixture forecast, the fixture place table, a fixed clock.
    static func environment(transport: WeatherTransport, location: DeviceLocationSource? = nil,
                            cache: URL? = nil) -> WeatherEnvironment? {
        guard let fixtures else { return nil }
        var env = WeatherEnvironment()
        env.isLive = WeatherWiring.isLive
        env.transport = transport
        env.placesTable = fixtures.appendingPathComponent("places-fixture.tsv")
        env.deviceLocation = location
        env.cacheDirectory = cache
        env.clock = VirtualWeatherClock(now: fixtureClock)
        env.uses24HourClock = { true }
        env.preferredUnits = { .metric }
        env.random = { 0 }
        return env
    }

    /// Updates the skin until `condition` holds (lookups and fetches finish on the service's queue, hops on main).
    static func update(_ skin: Skin, timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        AppSelfTest.spin(timeout: timeout) {
            WeatherService.shared.drain()
            skin.update()
            return condition()
        }
    }

    static let weatherSkin = """
        [Rainmeter]
        Update=1000
        ContextTitle=Refresh weather
        ContextAction=[!CommandMeasure MeasureWeather "Refresh"]
        [MeasureWeather]
        Measure=Plugin
        Plugin=MacWeather
        Location=Oslo, NO
        Type=Temperature
        Decimals=0
        [MeasureStatus]
        Measure=Plugin
        Plugin=MacWeather
        Parent=MeasureWeather
        Type=Status
        [MeasureRise]
        Measure=Plugin
        Plugin=MacSun
        Location=Oslo, NO
        Type=Sunrise
        Format=%H:%M
        [MeterTemperature]
        Meter=String
        MeasureName=MeasureWeather
        Text=%1°
        """

    // MARK: Wiring

    static func wiringTests(_ t: AppTestRunner) {
        t.suite("App: Weather: wiring") {
            let live = WeatherWiring.liveEnvironment()
            t.check(live.transport is URLSessionWeatherTransport, "the real transport")
            t.equal(live.userAgent, "Deskset/dev (+https://github.com/jokyme/Deskset)", "an unbundled build says dev")
            t.check(live.userAgent.range(of: #"^Deskset/\S+ \(\+https://github\.com/jokyme/Deskset\)$"#,
                                         options: .regularExpression) != nil)
            t.equal(live.cacheDirectory?.lastPathComponent, "Weather")
            t.check(live.deviceLocation === LocationCenter.shared, "this Mac's location through LocationCenter")
            t.check(live.placesTable.map { FileManager.default.fileExists(atPath: $0.path) } == true, "the place table")
            t.check(!live.demo)
            // Only skin windows are live; everything else (previews, --render) is not.
            let (preview, host) = try MediaUITests.bareSkin(t)
            t.check(!live.isLive(preview), "a render host is not live")
            _ = host
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("WeatherWiring")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "[Rainmeter]\n[M]\nMeasure=Calc\n".write(to: folder.appendingPathComponent("W.ini"), atomically: true,
                                                         encoding: .utf8)
            let c = try SkinController(config: "WeatherWiring", file: "W.ini", app: app)
            t.check(live.isLive(c.skin), "a skin window is live")
            c.stop()
            // The self-tests never run with the live environment (only AppController's launch installs it).
            t.check(!(WeatherService.shared.environment.transport is URLSessionWeatherTransport), "offline here")
            // Units=Auto: the Temperature setting first, then the region.
            let defaults = UserDefaults(suiteName: "deskset.weather.test.\(UUID().uuidString)")!
            t.equal(WeatherWiring.systemUnits(defaults: defaults, locale: Locale(identifier: "en_US")), .imperial)
            t.equal(WeatherWiring.systemUnits(defaults: defaults, locale: Locale(identifier: "nb_NO")), .metric)
            defaults.set("Celsius", forKey: "AppleTemperatureUnit")
            t.equal(WeatherWiring.systemUnits(defaults: defaults, locale: Locale(identifier: "en_US")).temperature, .celsius)
            t.equal(WeatherWiring.systemUnits(defaults: defaults, locale: Locale(identifier: "en_GB")).wind, .mph)
            // Previews: no network, no location; place names resolve, so sun times work.
            let previewEnv = WeatherWiring.previewEnvironment(demo: false, demoNow: nil)
            t.check(previewEnv.transport == nil && previewEnv.deviceLocation == nil)
            t.check(previewEnv.placesTable != nil)
            let demo = WeatherWiring.previewEnvironment(demo: true, demoNow: fixtureClock)
            t.check(demo.demo && demo.clock.now() == fixtureClock)
            t.check(WeatherWiring.credits.contains("MET Norway") && WeatherWiring.credits.contains("GeoNames"))
        }
    }

    // MARK: Location Services

    static func locationCenterTests(_ t: AppTestRunner) {
        t.suite("App: Weather: LocationCenter asks once and shares one request") {
            let fake = FakeLocationManager()
            let center = LocationCenter(makeManager: { fake }, fixTimeout: 0.3, authorizationTimeout: 0.4)
            let logs = SharedServiceThreadingSelfTests.Collected<String>()
            center.log = { logs.add($0) }
            let results = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            for _ in 0..<3 { center.requestFix { results.add($0) } }
            t.equal(fake.questions, 1, "asked once for three skins")
            t.equal(fake.requests, 0, "no request before the answer")
            t.equal(fake.desiredAccuracy, kCLLocationAccuracyReduced, "reduced accuracy")
            center.requestIfNeeded()
            t.equal(fake.questions, 1, "never asked twice")
            fake.authorizationStatus = .authorizedAlways
            center.authorizationChanged(.authorizedAlways)
            t.equal(fake.requests, 1, "one request for everyone")
            t.equal(center.authorization, .authorized)
            center.received([CLLocation(latitude: 59.913868, longitude: 10.752245)])
            t.equal(results.count, 3)
            let oslo = RoundedCoordinate(latitude: 59.91, longitude: 10.75)
            t.check(results.all.allSatisfy { if case .success(let c) = $0 { return c == oslo } else { return false } },
                    "every skin gets the rounded fix")
            t.equal(center.cachedFix(maxAge: 60), oslo)
            t.equal(ServiceThreadingSelfTests.offMain { center.cachedFix(maxAge: 60) }, Optional(oslo), "from any thread")
            t.check(logs.all.contains("Location: fix ok"), "\(logs.all)")
            t.check(!logs.all.contains { $0.contains("59.9") || $0.contains("10.75") }, "no coordinates in the log")

            // No fix within the time limit: unavailable, the request stopped.
            let late = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            center.requestFix { late.add($0) }
            t.equal(fake.requests, 2)
            t.check(AppSelfTest.spin(timeout: 5) { late.count == 1 }, "the time-out answers")
            t.equal(late.all.first.map { if case .failure(.unavailable) = $0 { return true } else { return false } }, true)
            t.check(fake.stops >= 1, "the request is stopped")
            // A failure from Location Services, and a request from another thread.
            let failed = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            DispatchQueue.global().async { center.requestFix { failed.add($0) } }
            t.check(AppSelfTest.spin(timeout: 5) { fake.requests == 3 }, "the request reached the main thread")
            center.failed(CLError(.locationUnknown))
            t.equal(failed.all.first.map { if case .failure(.unavailable) = $0 { return true } else { return false } }, true)
            // Refused: at once, without asking.
            fake.authorizationStatus = .denied
            let refused = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            center.requestFix { refused.add($0) }
            t.equal(refused.all.first.map { if case .failure(.denied) = $0 { return true } else { return false } }, true)
            t.equal(fake.requests, 3, "nothing asked when refused")
            t.equal(center.authorization, .denied)
            t.check(center.isDenied)
            // The user never answers: after the time limit, "unavailable" (asked again later by the service).
            let undecided = FakeLocationManager()
            let quiet = LocationCenter(makeManager: { undecided }, fixTimeout: 0.3, authorizationTimeout: 0.3)
            quiet.log = { _ in }
            let waited = SharedServiceThreadingSelfTests.Collected<Result<RoundedCoordinate, DeviceLocationError>>()
            quiet.requestFix { waited.add($0) }
            t.check(AppSelfTest.spin(timeout: 5) { waited.count == 1 }, "no answer is not a hang")
            t.equal(undecided.questions, 1)
        }
    }

    // MARK: Skins in skin windows

    static func skinTests(_ t: AppTestRunner) {
        t.suite("App: Weather: skin windows get forecasts, credit MET Norway and ask for the location") {
            guard let fixtures, let body = FileManager.default.contents(atPath:
                    fixtures.appendingPathComponent("metno-complete-oslo.json").path) else {
                print("    (skipped: fixtures not found; run from the repository)")
                return
            }
            let transport = FixtureTransport(body: body)
            let fake = FakeLocationManager()
            fake.authorizationStatus = .denied
            let center = LocationCenter(makeManager: { fake }, fixTimeout: 5, authorizationTimeout: 5)
            center.log = { _ in }
            guard let env = environment(transport: transport, location: center,
                                        cache: t.temporaryDirectory("weather-cache")) else { return }
            let previous = WeatherService.shared.environment
            WeatherService.install(env)
            t.atSuiteEnd { WeatherService.install(previous) }
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("Weather")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try weatherSkin.write(to: folder.appendingPathComponent("Weather.ini"), atomically: true, encoding: .utf8)
            let c = try SkinController(config: "Weather", file: "Weather.ini", app: app)
            defer { c.stop() }
            t.check(update(c.skin) { c.skin.measure(named: "MeasureStatus")?.value == 0 },
                    "ready: \(c.skin.measure(named: "MeasureStatus")?.stringValue ?? "")")
            t.equal(transport.requests, 1)
            t.equal(c.skin.measure(named: "MeasureWeather")?.value, 16)
            t.equal(c.skin.measure(named: "MeasureRise")?.stringValue.hasPrefix("07:"), true)
            // The skin menu credits the source, with the time of the data.
            let menu = app.skinMenu(for: c, includeCustomItems: true)
            let titles = menu.items.map(\.title)
            let credit = menu.items.first { $0.title == "Weather: Based on data from MET Norway ↗" }
            t.check(credit != nil, "\(titles)")
            t.equal(credit?.representedObject as? String, "https://api.met.no/")
            t.check(credit?.action == #selector(AppController.openWeatherSourceAction(_:)))
            t.check(titles.contains("Updated 11:59") || titles.contains { $0.hasPrefix("Updated ") }, "\(titles)")
            t.check(titles.firstIndex(of: "Refresh weather").map { $0 < (titles.firstIndex(of: credit?.title ?? "") ?? 0) }
                    == true, "after the skin's own items")
            // A skin without weather has no credit.
            try "[Rainmeter]\n[M]\nMeasure=Calc\n".write(to: folder.appendingPathComponent("Plain.ini"), atomically: true,
                                                         encoding: .utf8)
            let plain = try SkinController(config: "Weather", file: "Plain.ini", app: app)
            t.check(!app.skinMenu(for: plain, includeCustomItems: true).items.contains { $0.title.hasPrefix("Weather:") })
            plain.stop()

            // The same skin as a preview (not a skin window): no request, the Preview state, sun times still work.
            let preview = Skin(config: "Weather", fileURL: folder.appendingPathComponent("Weather.ini"),
                               skinsDirectory: app.skinsDirectory, system: SystemMonitor.shared, host: RenderHost())
            try preview.load()
            t.check(update(preview) { preview.measure(named: "MeasureRise")?.stringValue.hasPrefix("07:") == true })
            t.equal(preview.measure(named: "MeasureStatus")?.value, Double(WeatherStatus.preview.rawValue))
            t.equal(transport.requests, 1, "previews never fetch")
            preview.close()

            // Location=auto with Location Services refused: a note, removed once allowed; the fix is rounded.
            try weatherSkin.replacingOccurrences(of: "Location=Oslo, NO", with: "Location=auto")
                .write(to: folder.appendingPathComponent("Here.ini"), atomically: true, encoding: .utf8)
            let here = try SkinController(config: "Weather", file: "Here.ini", app: app)
            defer { here.stop() }
            t.check(update(here.skin) { here.skin.measure(named: "MeasureStatus")?.value == 5 }, "LocationDenied")
            t.check(here.skin.issues.contains { $0.contains("Location Services") }, "\(here.skin.issues)")
            t.equal(fake.questions, 0, "a refused permission is not asked again")
            fake.authorizationStatus = .authorizedAlways
            center.authorizationChanged(.authorizedAlways)
            t.check(update(here.skin) { fake.requests == 1 }, "asked for a fix once allowed")
            center.received([CLLocation(latitude: 59.9139, longitude: 10.7522)])
            t.check(update(here.skin) { here.skin.measure(named: "MeasureStatus")?.value == 0 },
                    "ready: \(here.skin.measure(named: "MeasureStatus")?.stringValue ?? "")")
            t.check(!here.skin.issues.contains { $0.contains("Location Services") }, "the note is gone")
            t.equal(transport.requests, 1, "Oslo's feed is shared with the typed place")
            t.equal(fake.requests, 1, "one fix for every measure")
        }
    }

    // MARK: SF Symbols

    static func symbolTests(_ t: AppTestRunner) {
        t.suite("App: Weather: every SF Symbol the plugins name exists and draws") {
            var names = Set(WeatherCondition.all.flatMap { [$0.daySymbol, $0.nightSymbol] })
            names.formUnion(names.map { $0.hasSuffix(".fill") ? String($0.dropLast(5)) : $0 })
            names.insert("cloud.fill")
            names.formUnion(WeatherSymbols.moon)
            names.formUnion(WeatherStatus.allCases.map(WeatherSymbols.status).filter { !$0.isEmpty })
            for name in names.sorted() {
                t.check(SymbolImages.exists(name), "\(name) exists")
                let symbol = MacSymbol(name: name, style: MacSymbol.Style(pointSize: 24, rendering: .multicolor),
                                       density: 2)
                t.check(SymbolImages.render(symbol) != nil, "\(name) renders")
            }
            // In a skin: `ImageName=sf:%1` of a Symbol measure, the demo forecast (no network).
            let previous = WeatherService.shared.environment
            WeatherService.install(WeatherWiring.previewEnvironment(demo: true, demoNow: fixtureClock))
            defer { WeatherService.install(previous) }
            let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                [MeasureSymbol]
                Measure=Plugin
                Plugin=MacWeather
                Location=59.91,10.75
                Type=Symbol
                [MeterIcon]
                Meter=Image
                MeasureName=MeasureSymbol
                ImageName=sf:%1
                MacSymbolRendering=Multicolor
                W=48
                H=48
                """)
            skin.update()
            skin.update()
            let name = skin.measure(named: "MeasureSymbol")?.stringValue ?? ""
            t.check(names.contains(name), "a weather symbol: \(name)")
            t.equal(skin.issues, [], "no unknown symbol")
            t.equal(skin.meter(named: "MeterIcon")?.frame.width, 48)
            _ = host
            skin.close()
        }
    }

    // MARK: Threads

    static func threadTests(_ t: AppTestRunner) {
        t.suite("App: Weather: six threads read one place, one request") {
            guard let fixtures, let body = FileManager.default.contents(atPath:
                    fixtures.appendingPathComponent("metno-complete-oslo.json").path) else { return }
            let transport = FixtureTransport(body: body)
            transport.hold = true
            var env = WeatherEnvironment()
            env.isLive = { _ in true }
            env.transport = transport
            env.clock = VirtualWeatherClock(now: fixtureClock)
            let service = WeatherService(environment: env)
            defer { service.shutDown() }
            let oslo = RoundedCoordinate(latitude: 59.91, longitude: 10.75)
            var skins: [Skin] = []
            var subscriptions: [WeatherSubscription] = []
            let told = SharedServiceThreadingSelfTests.Collected<Int>()
            for i in 0..<6 {
                let (skin, _) = try MediaUITests.bareSkin(t)
                skins.append(skin)
                let s = WeatherSubscription(hop: skin.hop()) { told.add(i) }
                subscriptions.append(s)
                t.check(service.attach(s, to: oslo, persistent: false))
            }
            let snapshots = SharedServiceThreadingSelfTests.Collected<Bool>()
            t.check(ServiceThreadingSelfTests.onThreads(6) { _ in
                for _ in 0..<50 { snapshots.add(service.read(oslo) != nil) }
            }, "the threads finish")
            service.drain()
            t.equal(snapshots.count, 300)
            t.equal(transport.requests, 1, "one request for six readers")
            transport.release()
            service.drain()
            t.check(AppSelfTest.spin(timeout: 5) { Set(told.all).count == 6 }, "every skin is told on its own hop")
            t.equal(service.peek(oslo)?.forecast?.steps.count, 86)
            for s in subscriptions { service.detach(s) }
            for skin in skins { skin.close() }
        }
    }

    // MARK: Command line

    static func commandLineTests(_ t: AppTestRunner) {
        t.suite("App: Weather: --weather-report and the system report") {
            typealias V = CommandLineTools.Validation
            t.equal(CommandLineTools.validate(["P", "--weather-report"]), V.mode)
            t.equal(CommandLineTools.validate(["P", "--weather-report", "--location", "Bergen", "--units", "metric"]), V.mode)
            t.equal(CommandLineTools.validate(["P", "--weather-report", "--offline", "a.json", "--now", "x"]), V.mode)
            t.equal(CommandLineTools.validate(["P", "--location", "Oslo"]),
                    V.invalid("--location needs one of --render, --snapshot-ui, --weather-report"))
            guard let fixtures, let binary = Bundle.main.executableURL else { return }
            func run(_ args: [String]) -> (status: Int32, out: String, err: String) {
                let p = Process()
                p.executableURL = binary
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { return (-1, "", "\(error)") }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
            }
            let refused = run(["--weather-report", "--location", "auto"])
            t.equal(refused.status, 2)
            t.check(refused.err.contains("never reads this Mac's location"), refused.err)
            let offline = run(["--weather-report", "--offline", fixtures.appendingPathComponent("metno-complete-oslo.json").path,
                               "--now", "2026-09-26T11:59:31Z", "--units", "metric", "--location", "59.91,10.75"])
            t.equal(offline.status, 0, offline.err)
            t.check(offline.out.contains("(no request)"), offline.out)
            t.check(offline.out.contains("Now (13:00): 16.3 °C"), offline.out)
            t.check(offline.out.contains("Based on data from MET Norway"), offline.out)
            t.equal(run(["--weather-report", "--units", "kelvin", "--offline", "x"]).status, 2)

            // The system report's Weather section: only when a place is set up (or Location Services allowed); it
            // never reads the location.
            let root = t.temporaryDirectory("weather-report")
            let skins = root.appendingPathComponent("Skins")
            let config = skins.appendingPathComponent("Home/Weather")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try weatherSkin.write(to: config.appendingPathComponent("W.ini"), atomically: true, encoding: .utf8)
            let state = root.appendingPathComponent("state.json")
            try #"{"skins":{"Home\\Weather":{"file":"W.ini","active":true}}}"#.write(to: state, atomically: true,
                                                                                    encoding: .utf8)
            let table = fixtures.appendingPathComponent("places-fixture.tsv")
            let lines = SystemReport.weatherLines(stateFile: state, skinsDirectory: skins, authorization: .notDetermined,
                                                  placesTable: table, now: fixtureClock)
            t.equal(lines.first, "Weather")
            t.check(lines.contains { $0.contains("Home\\Weather [MeasureWeather] MacWeather: Location=Oslo, NO") }, "\(lines)")
            t.check(lines.contains("    → Oslo, Oslo, Norway · 59.91, 10.75 · Europe/Oslo"), "\(lines)")
            t.check(lines.contains { $0.hasPrefix("    → sunrise 07:10, sunset 19:04") }, "\(lines)")
            t.check(lines.contains { $0.contains("Location Services:  not asked yet") }, "\(lines)")
            let none = SystemReport.weatherLines(stateFile: root.appendingPathComponent("missing.json"),
                                                 skinsDirectory: skins, authorization: .denied, placesTable: table)
            t.equal(none, ["Weather: not set up (no active skin sets a weather location; Location Services: denied)"])
            let allowed = SystemReport.weatherLines(stateFile: root.appendingPathComponent("missing.json"),
                                                    skinsDirectory: skins, authorization: .authorizedAlways,
                                                    placesTable: table)
            t.equal(allowed.first, "Weather", "Location Services allowed: the section shows")
        }
    }
}
