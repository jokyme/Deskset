import AppKit
import DesksetCore

/// The stress suite on the engine thread (docs/skin-threading.md §15, phase 2): every skin of TestSkins (the Lua skins
/// among them) and every default skin (the Stationery suite) runs in an app with `SkinThreading=engine`, so the app's
/// own runtime is each skin's host and every skin shares the one engine thread, as on a user's desktop. Each config
/// loads each of its files in turn, twice (the second load a refresh), and each load is asked for a number of updates
/// (`.update`, as `!UpdateGroup` asks) and must draw a frame through its content provider. Meanwhile the main thread
/// does what the app does while skins run: it replaces photos under the slideshows, purges the images, removes and
/// restores a skin font (every skin hears of it), publishes the AppKit inputs, moves windows, hovers the pointer over
/// skins, opens their menus (exclusive access, else the snapshot), reads their tooltips, pauses and resumes every
/// skin, and tells skins that the appearance changed. The skins meanwhile send each other bangs, refresh, activate and
/// unload each other.
///
/// It checks that nothing hangs (the work is bounded: a number of loads and updates, so a slow machine only takes
/// longer), that every load started on the engine thread, updated as asked and drew, that no skin failed to load,
/// that the fixtures computed what they compute on a thread of their own (the deep nesting chain reaches the engine's
/// limit, slideshows show a version of their photo, the font-heavy skin measures with its own font, writers' keys reach
/// their file), that the default skins load without a note, a file warning or a warning in the log and at their
/// size, and that no weather request left. Debug builds also stop at any touch of a skin off its thread
/// (`Skin.assertOwned`) and fail the suite for any call to a runtime from another thread than the skin's
/// (`HostCallAudit`); under `scripts/check-main-thread.sh "App: threads"` AppKit called off the main thread shows.
///
/// `DESKSET_THREADS_SOAK=N` multiplies the loads and the main thread's churn (a local soak; CI does not set it).
enum EngineStressSelfTests {
    static func run(_ t: AppTestRunner) {
        stressTests(t, threading: .engine)
        stressTests(t, threading: .pool)
    }

    struct Plan {
        var loadsPerFile = 2
        var updatesPerLoad = 6
        var churn = Churn()
        /// Configs whose window stops counting as seen once a load drew its first frame. String\Review's Border
        /// around simulated-bold Chalkduster takes CoreGraphics about 4 s to draw, and every update redraws it (every
        /// meter updated counts as changed, so no picture of it is kept): drawn at every update, it alone would hold the
        /// engine thread, and every skin on it, for minutes.
        var drawnOnce: Set<String> = ["string\\review"]

        static func fromEnvironment() -> Plan {
            var plan = Plan()
            if let factor = ProcessInfo.processInfo.environment["DESKSET_THREADS_SOAK"].flatMap(Int.init), factor > 1 {
                plan.loadsPerFile *= factor
                plan.churn = plan.churn.scaled(by: factor)
            }
            return plan
        }
    }

    /// How often the main thread does each thing during the run, spread evenly over it by the skins' progress.
    struct Churn {
        var photos = 16
        var purges = 8
        var fontChanges = 6
        var publishes = 8
        var moves = 48
        var hovers = 96
        var menus = 24
        var toolTips = 24
        var pauses = 4
        var appearances = 8

        func scaled(by factor: Int) -> Churn {
            Churn(photos: photos * factor, purges: purges * factor, fontChanges: fontChanges * factor,
                  publishes: publishes * factor, moves: moves * factor, hovers: hovers * factor, menus: menus * factor,
                  toolTips: toolTips * factor, pauses: pauses * factor, appearances: appearances * factor)
        }
    }

    /// Configs the suite leaves out: MediaUI\WiFi reads the network's name, which a skin window asks Location
    /// Services for (a permission prompt; the self-tests never ask).
    static let leftOut: Set<String> = ["mediaui\\wifi"]

    static func stressTests(_ t: AppTestRunner, threading: SkinThreading) {
        let place = threading == .engine ? "the engine thread" : "the worker pool"
        t.suite("App: threads: on \(place), every test and default skin loads, refreshes, updates and draws "
                + "in the app while the main thread is busy") {
            guard let testSkins = Paths.repositoryFolder("TestSkins"), let defaultSkins = Paths.defaultSkins else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            // Earlier suites' skins stop first: the numbers are this suite's, and nothing of theirs polls the players.
            AppSelfTest.stopEarlierSkins()
            // This suite checks bounded progress and compatibility, independent of the runner's speed.
            // Watchdog timing is tested with advanced clocks in SkinWorkWatchdogSelfTests; live deadlines below remain.
            let diagnosticClock = SteppedSkinClock(start: Date(timeIntervalSince1970: 0),
                                                   timeZone: TimeZone(secondsFromGMT: 0)!)
            let watchdog = SkinWorkWatchdog(clock: diagnosticClock.clock, automaticChecks: false)
            guard let app = try AppSelfTest.makeApp(t, threading: threading, workWatchdog: watchdog) else { return }
            let skins = app.skinsDirectory.resolvingSymlinksInPath()
            let files = try mergeSkins(from: testSkins, into: skins)
                + mergeSkins(from: defaultSkins, into: skins).filter {
                    $0.url.lastPathComponent.caseInsensitiveCompare(DefaultSkins.firstRunFileName) != .orderedSame
                }
            app.rescanLibrary()

            // Fixtures of TestSkins/Threads: photos under the slideshows, two skin fonts.
            let resources = skins.appendingPathComponent("Threads/@Resources")
            let photos = try ThreadStressSelfTests.Photos(folder: resources.appendingPathComponent("Photos"))
            let fonts = resources.appendingPathComponent("Fonts")
            let fontA = fonts.appendingPathComponent("A.ttf"), fontB = fonts.appendingPathComponent("B.ttf")
            let hasFonts = AppSelfTest.makeTestFont(family: "DesksetThrA", at: fontA)
                && AppSelfTest.makeTestFont(family: "DesksetThrB", at: fontB)
            if !hasFonts { print("    (no skin fonts: Courier New not found)") }
            let fontB2 = try hasFonts ? Data(contentsOf: fontB) : Data()

            // What skins open is noted, not opened; the log goes to a file of the suite's, not to the terminal.
            let opened = SharedServiceThreadingSelfTests.Collected<String>()
            SkinWindowController.opensForTesting = { plan in opened.add("\(plan)") }
            let logs = t.temporaryDirectory("engine-stress-log")
            let savedLog = (Log.directory, Log.fileLoggingEnabled, Log.mirrorsToStandardError)
            Log.directory = logs
            Log.fileLoggingEnabled = true
            Log.mirrorsToStandardError = false
            // Weather: places resolve, nothing reaches the network.
            let forbidden = WeatherSelfTests.ForbiddenTransport()
            var weather = WeatherWiring.previewEnvironment(demo: false, demoNow: nil)
            weather.transport = forbidden
            let previousWeather = WeatherService.shared.environment
            WeatherService.install(weather)
            // NowPlaying: the demo player, never Apple Events to a real one, never an online cover lookup.
            let center = NowPlayingCenter.shared
            let players = (center.backend, center.coverLookup)
            let swapPlayers = AppSelfTest.spin(timeout: 30) { !center.isPolling }
            if swapPlayers {
                center.backend = DemoNowPlayingBackend()
                center.coverLookup = nil
            }
            let fontToken = NotificationCenter.default.addObserver(forName: Fonts.didChangeNotification, object: nil,
                                                                   queue: .main) { _ in app.fontsChanged() }
            t.atSuiteEnd {
                NotificationCenter.default.removeObserver(fontToken)
                SkinWindowController.opensForTesting = nil
                Log.flush()
                (Log.directory, Log.fileLoggingEnabled, Log.mirrorsToStandardError) = savedLog
                WeatherService.install(previousWeather)
                try? FileManager.default.removeItem(at: fonts)
                Fonts.rescanFolder(fonts.path)
                Images.purge()
                _ = SharedServiceThreadingSelfTests.drainMainQueue()
                // The players go back once polling stopped with the last NowPlaying skin (the worker reads them).
                if swapPlayers, AppSelfTest.spin(timeout: 30, until: { !center.isPolling }) {
                    (center.backend, center.coverLookup) = players
                }
            }
            t.check(swapPlayers, "the players were not polled when the suite began")

            // One driver per config, with its files in order.
            var byConfig: [String: (config: String, files: [String])] = [:]
            var order: [String] = []
            for file in files {
                let key = file.config.lowercased()
                guard !leftOut.contains(key) else { continue }
                if byConfig[key] == nil {
                    byConfig[key] = (file.config, [])
                    order.append(key)
                }
                byConfig[key]?.files.append(file.url.lastPathComponent)
            }
            let plan = Plan.fromEnvironment()
            let drivers = order.compactMap { byConfig[$0] }.map { Driver(config: $0.config, files: $0.files.sorted()) }
            t.equal(drivers.filter { app.config(named: $0.config) == nil }.map(\.config), [],
                    "every config is in the app's library")
            let fileCount = drivers.reduce(0) { $0 + $1.files.count }
            t.check(drivers.count >= 100 && fileCount >= 140, "configs: \(drivers.count), files: \(fileCount)")
            let planned = Double(fileCount * plan.loadsPerFile)
            DesktopInputs.publishAll()

            let start = ProcessInfo.processInfo.systemUptime
            var tracked: [() -> Skin?] = []
            var done = Churn(photos: 0, purges: 0, fontChanges: 0, publishes: 0, moves: 0, hovers: 0, menus: 0,
                             toolTips: 0, pauses: 0, appearances: 0)
            var fontBPresent = true
            var paused = false
            var liveMenus = 0
            let finished: Bool = autoreleasepool {
                for driver in drivers { driver.begin(app) }
                func due(_ count: Int, of total: Int, at progress: Double) -> Bool {
                    count < total && progress >= Double(count + 1) / Double(total + 1)
                }
                /// A started skin, picked by `n` (the same run picks the same ones).
                func pick(_ n: Int) -> SkinWindowController? {
                    let started = app.sortedControllers.filter { $0.isStarted && !$0.isStopped }
                    return started.isEmpty ? nil : started[(n &* 7919) % started.count]
                }
                return AppSelfTest.spin(timeout: 400) {
                    for driver in drivers { driver.step(app, plan: plan) }
                    let progress = Double(drivers.reduce(0) { $0 + $1.completedLoads }) / planned
                    let churn = plan.churn
                    if due(done.photos, of: churn.photos, at: progress) {
                        photos.replace(done.photos)
                        done.photos += 1
                    }
                    if due(done.publishes, of: churn.publishes, at: progress) {
                        DesktopInputs.publishAll()
                        done.publishes += 1
                    }
                    if due(done.purges, of: churn.purges, at: progress) {
                        Images.purge()
                        done.purges += 1
                    }
                    if hasFonts, due(done.fontChanges, of: churn.fontChanges, at: progress) {
                        if fontBPresent { try? FileManager.default.removeItem(at: fontB) } else { try? fontB2.write(to: fontB) }
                        fontBPresent.toggle()
                        if Fonts.rescanFolder(fonts.path) { done.fontChanges += 1 }
                    }
                    if due(done.moves, of: churn.moves, at: progress), let c = pick(done.moves) {
                        let n = done.moves
                        c.window.setFrameOrigin(NSPoint(x: 400 + (n * 37) % 600, y: 160 + (n * 53) % 400))
                        done.moves += 1
                    }
                    if due(done.hovers, of: churn.hovers, at: progress), let c = pick(done.hovers) {
                        // Over the middle of the skin, then off it.
                        let size = c.runtime.snapshot.size
                        c.runtime.send(.hover(x: Double(size.width) / 2, y: Double(size.height) / 2))
                        c.runtime.send(.exited)
                        done.hovers += 1
                    }
                    if due(done.menus, of: churn.menus, at: progress), let c = pick(done.menus + 1) {
                        if app.menuFacts(for: c).isLive { liveMenus += 1 }
                        _ = app.skinMenu(for: c, includeCustomItems: true)
                        done.menus += 1
                    }
                    if due(done.toolTips, of: churn.toolTips, at: progress), let c = pick(done.toolTips + 2) {
                        c.view.updateToolTips()
                        done.toolTips += 1
                    }
                    if paused {
                        // Asleep for one turn of the main thread.
                        app.simulatePause(systemAsleep: false)
                        paused = false
                    } else if due(done.pauses, of: churn.pauses, at: progress) {
                        app.simulatePause(systemAsleep: true)
                        paused = true
                        done.pauses += 1
                    }
                    if due(done.appearances, of: churn.appearances, at: progress), let c = pick(done.appearances + 3) {
                        c.runtime.send(.appearanceChanged)
                        done.appearances += 1
                    }
                    return drivers.allSatisfy(\.finished)
                }
            }
            if paused { app.simulatePause(systemAsleep: false) }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            tracked = drivers.flatMap(\.tracked)
            t.check(finished, "every config went through its loads (a hang otherwise): "
                    + "\(drivers.filter { !$0.finished }.map(\.stateDescription))")
            let loads = drivers.flatMap { d in d.loads.map { (d, $0) } }
            let replaced = loads.filter { $0.1.outcome == .replaced }.count
            print("    \(place): \(drivers.count) configs, \(fileCount) files, \(loads.count) loads (\(replaced) "
                  + "refreshed or unloaded by a skin first) in \(String(format: "%.1f", seconds)) s; meanwhile "
                  + "\(done.photos) photos, \(done.purges) purges, \(done.fontChanges) font changes, \(done.moves) moves, "
                  + "\(done.hovers) hovers, \(done.menus) menus (\(liveMenus) live), \(done.toolTips) tooltip reads, "
                  + "\(done.pauses) pauses, \(done.appearances) appearance changes")
            let slowest = loads.compactMap { d, load in load.ended.map { ("\(d.config)\\\(load.file)", $0 - load.began) } }
                .sorted { $0.1 > $1.1 }.prefix(12)
            let drawing = loads.compactMap { d, load in load.facts.map { ("\(d.config)\\\(load.file)", $0.drawing, $0.longestFrame) } }
            let totalDrawing = drawing.reduce(0) { $0 + $1.1 }
            print("    drawing: \(String(format: "%.1f", totalDrawing)) s in all; most: " + drawing.sorted { $0.1 > $1.1 }
                .prefix(8).map { "\($0.0) \(String(format: "%.2f", $0.1)) s (longest frame \(String(format: "%.2f", $0.2)))" }
                .joined(separator: ", "))
            print("    slowest loads: " + slowest.map { "\($0.0) \(String(format: "%.1f", $0.1)) s" }.joined(separator: ", "))
            if !opened.all.isEmpty { print("    opened (not really): \(opened.all.prefix(5))") }
            t.check(done.photos > 0 && done.purges > 0 && done.moves > 0 && done.hovers > 0 && done.menus > 0
                    && done.pauses > 0, "the main thread was busy meanwhile")
            if hasFonts { t.check(done.fontChanges > 0, "and changed the fonts") }

            // Every load started on the engine thread, updated as asked and drew.
            t.equal(loads.filter { $0.1.onEngine == false }.map { "\($0.0.config)\\\($0.1.file)" }, [],
                    "every skin ran on its selected worker")
            let failed = loads.compactMap { d, load -> String? in
                guard case .failed(let error) = load.outcome else { return nil }
                return "\(d.config)\\\(load.file): \(error)"
            }
            t.equal(failed, [], "no load failed")
            var problems: [String] = []
            for (d, load) in loads where load.outcome == .done {
                if load.updates < plan.updatesPerLoad { problems.append("\(d.config)\\\(load.file): \(load.updates) updates") }
                if load.frames < 1 && load.facts?.hidden != true { problems.append("\(d.config)\\\(load.file): no frame") }
                if load.facts == nil { problems.append("\(d.config)\\\(load.file): busy for 30 s") }
            }
            t.equal(problems, [], "every load updated as asked and drew")
            let completed = loads.filter { $0.1.outcome == .done }.count
            t.check(Double(completed) >= planned * 0.8, "most loads ran to the end: \(completed) of \(Int(planned))")

            Log.flush()
            let log = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
            checkDefaultSkins(t, loads, log: log)
            checkFixtures(t, loads, photos: photos, counts: resources.appendingPathComponent("Counts.inc"),
                          hasFonts: hasFonts, log: log)
            t.equal(forbidden.count, 0, "no weather request")

            // Every skin closes and is let go of on the engine thread, which then ends.
            EngineThreadSelfTests.finish(t, app, tracked)
            t.equal(watchdog.activeCount, 0, "every monitored activity ended with the skins and workers")
        }
    }

    // MARK: The default skins and the fixtures

    /// The bundled skins: no compatibility note, no file warning, no warning or error of theirs in the log, each at its
    /// card's size.
    private static func checkDefaultSkins(_ t: AppTestRunner, _ loads: [(Driver, Driver.Load)], log: String) {
        let stationery = loads.filter { $0.0.config.hasPrefix("Stationery\\") && $0.1.outcome == .done }
        t.check(stationery.count >= 60, "default skin loads: \(stationery.count)")
        var problems: [String] = []
        for (d, load) in stationery {
            let name = "\(d.config)\\\(load.file)"
            guard let facts = load.facts else { continue }
            if !facts.issues.isEmpty { problems.append("\(name): \(facts.issues)") }
            if !facts.loadWarnings.isEmpty { problems.append("\(name): \(facts.loadWarnings)") }
            if let size = ThreadStressSelfTests.defaultSkinSize(load.file) {
                if facts.width != size.0 || facts.height != size.1 { problems.append("\(name): \(facts.width) × \(facts.height)") }
            } else {
                problems.append("\(name): not a card size's name")
            }
        }
        let loud = log.split(separator: "\n").filter {
            $0.contains("(Stationery\\") && ($0.contains("[Warning]") || $0.contains("[Error]"))
        }
        problems += loud.prefix(10).map(String.init)
        t.equal(problems, [], "every default skin loads cleanly, at its size")
    }

    /// What the fixtures in TestSkins/Threads computed on the engine thread.
    private static func checkFixtures(_ t: AppTestRunner, _ loads: [(Driver, Driver.Load)],
                                      photos: ThreadStressSelfTests.Photos, counts: URL, hasFonts: Bool, log: String) {
        func done(_ config: String) -> [Driver.Load] {
            loads.filter { $0.0.config == config && $0.1.outcome == .done }.map(\.1)
        }
        // Deep nesting: the chain reached the engine's limit on the engine thread's 8 MB stack.
        t.check(!done("Threads\\DeepNesting").isEmpty, "the deep nesting skin ran")
        t.check(log.split(separator: "\n").contains { $0.contains("(Threads\\DeepNesting)") && $0.contains("nested too deeply") },
                "its actions reached the limit")
        t.check(done("Threads\\DeepNesting").allSatisfy { $0.facts?.values["X"]?.isEmpty == false },
                "and set the variable on the way")

        // Slideshow: its photo at the size of one of the photo's versions.
        let slides = done("Threads\\Slideshow")
        t.check(!slides.isEmpty, "the slideshow ran")
        for load in slides {
            guard let index = load.facts?.values["MeasureIndex"].flatMap(Double.init).map(Int.init),
                  let size = load.facts?.values["Native"] else { t.check(false, "slideshow facts"); continue }
            t.check(photos.sizes(of: index).contains(size), "photo \(index) shown at \(size)")
        }

        // Font-heavy: its own font measured, not the fallback.
        if hasFonts {
            var style = TextStyle()
            style.fontFace = "No Such Font Anywhere"
            style.fontSize = 20
            let fallback = Double(TextLayoutCache().layout("iiiiiiiiiiii", style: style, wrapWidth: nil, cycle: 0)
                .size.width)
            for load in done("Threads\\Fonts") {
                let width = load.facts?.values["Mono"].flatMap(Double.init) ?? 0
                t.check(width > fallback * 1.5, "monospaced i's (\(width)) are wider than the fallback's (\(fallback))")
            }
        }

        // Writers: the key each wrote at its last update before the suite read it is in the file.
        let written = (try? String(contentsOf: counts, encoding: .utf8)).map(IniDocument.parse)?
            .section(named: "Counts")?.entries ?? []
        let writers = done("Threads\\Writer")
        t.check(writers.count >= 4, "the four writers ran: \(writers.count)")
        for load in writers {
            guard let count = load.facts?.values["MeasureCount"] else { t.check(false, "\(load.file): its count"); continue }
            t.equal(written.first { $0.key == "\(load.file) 1-\(count)" }?.value, count, "\(load.file): key 1-\(count)")
        }
    }

    // MARK: Driving one config

    /// One config of the app: each of its files in turn, `plan.loadsPerFile` loads each (the later ones refreshes), and
    /// each load, once started, is made visible (in the window facts), asked for `plan.updatesPerLoad` updates one after
    /// the other, and must draw a frame. A load another skin or the app replaced or unloaded first (`!Refresh`,
    /// `!DeactivateConfig`, an appearance change) counts as such, and the next load follows. Main thread.
    final class Driver {
        enum Outcome: Equatable {
            case loading
            case done
            case failed(String)
            /// Refreshed or unloaded by someone else before it was through.
            case replaced
        }

        struct Facts {
            var issues: [String]
            var loadWarnings: [String]
            var width: Double
            var height: Double
            var hidden: Bool
            var values: [String: String]
            /// Seconds its frames took to draw, in all and the longest.
            var drawing: TimeInterval
            var longestFrame: TimeInterval
        }

        struct Load {
            var file: String
            var outcome = Outcome.loading
            var onEngine: Bool?
            var updates = 0
            var frames = 0
            var facts: Facts?
            /// When the load was asked for, and when it was through (system uptime).
            var began = ProcessInfo.processInfo.systemUptime
            var ended: TimeInterval?
        }

        let config: String
        let files: [String]
        private(set) var loads: [Load] = []
        private(set) var finished = false
        /// The skins of this config's loads, held weakly.
        private(set) var tracked: [() -> Skin?] = []
        private var fileIndex = 0
        private var loadsOfFile = 0
        private var current: SkinWindowController?
        private var base: (updates: Int, frames: Int)?
        private var asked = 0

        init(config: String, files: [String]) {
            self.config = config
            self.files = files
        }

        var completedLoads: Int { loads.filter { $0.outcome != .loading }.count }

        var stateDescription: String {
            let load = loads.last
            return "\(config)\\\(load?.file ?? "?"): load \(loads.count), \(load?.updates ?? 0) updates, "
                + "\(load?.frames ?? 0) frames, asked \(asked), started \(current?.isStarted ?? false)"
        }

        func begin(_ app: AppController) {
            load(app, refresh: false)
        }

        func step(_ app: AppController, plan: Plan) {
            guard !finished else { return }
            guard let c = current else { return next(app, plan) }
            let i = loads.count - 1
            if c.loadFailed {
                loads[i].outcome = .failed("could not be loaded")
                return next(app, plan)
            }
            if app.controller(for: config) !== c {
                loads[i].outcome = .replaced
                return next(app, plan)
            }
            guard c.isStarted else { return }
            if base == nil {
                loads[i].onEngine = c.runtime.executor === app.skinExecutor(config)
                c.visibilityForTesting = true
                base = (c.runtime.snapshot.updateCount, c.content.state.presented)
            }
            guard let base else { return }
            let updates = c.runtime.snapshot.updateCount - base.updates
            loads[i].updates = updates
            loads[i].frames = c.content.state.presented - base.frames
            if loads[i].frames >= 1, plan.drawnOnce.contains(config.lowercased()), c.visibilityForTesting == true {
                c.visibilityForTesting = false
            }
            if asked < plan.updatesPerLoad {
                // One at a time: the next once the last one ran (or the skin's own clock got there first).
                if updates >= asked {
                    c.runtime.send(.update(hops: 0))
                    asked += 1
                }
                return
            }
            guard updates >= plan.updatesPerLoad, loads[i].frames >= 1 || c.isHiddenByBang else { return }
            // What the skin computed, read from the live skin: the engine thread parks for it.
            loads[i].facts = c.runtime.exclusive(timeout: 30) { skin in
                var values: [String: String] = [:]
                for name in ["MeasureCount", "MeasureIndex"] {
                    if let m = skin.measure(named: name) { values[name] = m.stringValue }
                }
                if let m = skin.meter(named: "Native") { values["Native"] = "\(Int(m.frame.width))×\(Int(m.frame.height))" }
                if let m = skin.meter(named: "Mono") { values["Mono"] = "\(m.frame.width)" }
                if let x = skin.variable("X") { values["X"] = x }
                return Facts(issues: skin.issues, loadWarnings: skin.loadWarnings, width: skin.width, height: skin.height,
                             hidden: c.isHiddenByBang, values: values, drawing: c.runtime.frames.drawingTime,
                             longestFrame: c.runtime.frames.longestFrame)
            }
            loads[i].outcome = .done
            loads[i].ended = ProcessInfo.processInfo.systemUptime
            next(app, plan)
        }

        private func next(_ app: AppController, _ plan: Plan) {
            current = nil
            base = nil
            asked = 0
            loadsOfFile += 1
            if loadsOfFile < plan.loadsPerFile { return load(app, refresh: true) }
            loadsOfFile = 0
            fileIndex += 1
            if fileIndex < files.count { return load(app, refresh: false) }
            finished = true
            app.deactivate(config: config)
        }

        private func load(_ app: AppController, refresh: Bool) {
            let file = files[fileIndex]
            loads.append(Load(file: file))
            if refresh, let running = app.controller(for: config), running.file.caseInsensitiveCompare(file) == .orderedSame {
                app.refresh(running)
            } else {
                app.activate(config: config, file: file)
            }
            current = app.controller(for: config)
            if let c = current {
                tracked.append(EngineThreadSelfTests.track(c))
            } else {
                // `step` moves on at its next turn.
                loads[loads.count - 1].outcome = .failed("no window was made")
            }
        }
    }

    // MARK: One Skins folder

    /// Copies the root configs of the skins under `source` into `skins` (the app's one Skins folder), each root once:
    /// fixtures whose root config sits deeper (`TestSkins/Lua/LuaShowcase`, with its own `@Resources`) keep it as their
    /// root, so `#@#` still finds their resources. Roots already there (`makeApp` copies App and Deskset) are kept.
    /// The skins, as they are in `skins`.
    static func mergeSkins(from source: URL, into skins: URL) throws -> [ThreadStressSelfTests.SkinFile] {
        let fm = FileManager.default
        var merged: [ThreadStressSelfTests.SkinFile] = []
        var copied: [String: URL] = [:]
        for file in ThreadStressSelfTests.SkinFile.all(under: source) {
            guard let root = file.config.split(separator: "\\").first.map(String.init) else { continue }
            let from = file.skinsDirectory.appendingPathComponent(root)
            let to = skins.appendingPathComponent(root)
            if let earlier = copied[root.lowercased()] {
                guard earlier == from else { throw MergeError.clash(root) }
            } else {
                copied[root.lowercased()] = from
                if !fm.fileExists(atPath: to.path) { try fm.copyItem(at: from, to: to) }
            }
            let relative = file.url.pathComponents.dropFirst(file.skinsDirectory.pathComponents.count)
            let url = relative.reduce(skins) { $0.appendingPathComponent($1) }
            merged.append(ThreadStressSelfTests.SkinFile(url: url, skinsDirectory: skins, config: file.config))
        }
        return merged
    }

    enum MergeError: Error {
        /// Two root configs of the same name.
        case clash(String)
    }
}
