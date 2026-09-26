import AppKit
import DesksetCore

/// The "threads" stress suite (docs/skin-threading.md §10, phase 1): every skin of TestSkins and DefaultSkins loads,
/// updates and draws on a thread of its own, all at once, as skins will once they leave the main thread (phases 2
/// and 3). Meanwhile the main thread does what the app does while skins run: it purges the image cache (Refresh All),
/// adds and removes a font and passes the change on to every skin, replaces photos under the slideshows, and publishes
/// what SysColor and Chameleon ask AppKit.
///
/// It shows that the shared services made thread-safe in phase 1 hold up under real skins: nothing crashes, no
/// ownership check fires (debug builds), nothing calls AppKit off the main thread (run it under
/// `scripts/check-main-thread.sh "App: threads"`), and what the skins compute stays right: the four copies of the
/// writer fixture lose none of the keys they write into one file (`!WriteKeyValue`), the slideshows show photos at the
/// size of one of their versions, the font-heavy skin measures with its own font, and the deep nesting fixture reaches
/// the engine's limit well within the 8 MB stack of a skin thread (§5.3, §7.4). Without the per-file lock of
/// `IniWriter` the writers lose keys; with one render context shared by all skins (as the static caches were before
/// phase 1) the run crashes.
///
/// The work is bounded — a number of loads and updates per skin, not a length of time — so a slow machine (CI's Intel
/// runner, `taskpolicy -b`) only takes longer. The only time limits tell "finishes" from "never" (a hang).
///
/// Skins run with a thread-safe test host (`StressHost`) instead of `SkinController`, whose window half stays on the
/// main thread until phase 2: window and app bangs, bangs for other skins and opened files are recorded, not carried
/// out, and the plugins that need a skin window stay idle, as in `--render` (FrostedGlass's backdrop, InputText's
/// prompt, AudioLevel's capture, NowPlaying's Apple Events).
enum ThreadStressSelfTests {
    static func run(_ t: AppTestRunner) {
        executorTests(t)
        stressTests(t)
    }

    // MARK: The test executor

    static func executorTests(_ t: AppTestRunner) {
        t.suite("App: threads: a skin thread runs its work in order, never inline, and its timers there") {
            let executor = TestThreadExecutor(name: "Deskset self-test skin thread")
            t.check(!executor.isCurrent, "the main thread is not the skin's thread")
            // Work handed over from the main thread: on the skin's thread, first in, first out.
            let order = SharedServiceThreadingSelfTests.Collected<Int>()
            let places = SharedServiceThreadingSelfTests.Collected<Bool>()
            for i in 0..<200 {
                executor.async {
                    order.add(i)
                    places.add(executor.isCurrent)
                }
            }
            t.check(AppSelfTest.spin(timeout: 60) { order.count == 200 }, "all of it ran")
            t.equal(order.all, Array(0..<200), "in order")
            t.check(places.all.allSatisfy { $0 }, "on the skin's thread")

            // Work the thread hands itself runs after the current work, never inline, and so do delayed work and
            // timers, even with 0 seconds.
            let events = SharedServiceThreadingSelfTests.Collected<String>()
            executor.async {
                events.add("stack \(pthread_get_stacksize_np(pthread_self()) >= 8 << 20)")
                var current = true
                executor.async { events.add("async \(current)") }
                executor.async(after: 0) { events.add("after \(current)") }
                _ = executor.timer(interval: 0, leeway: 0, repeats: false) { events.add("timer \(current)") }
                current = false
            }
            t.check(AppSelfTest.spin(timeout: 60) { events.count == 4 }, "all of it ran: \(events.all)")
            t.equal(Set(events.all), ["stack true", "async false", "after false", "timer false"],
                    "an 8 MB stack; nothing ran inline")

            // A repeating timer fires on the thread until it is cancelled, here from the main thread.
            let ticks = SharedServiceThreadingSelfTests.Collected<Bool>()
            let timer = executor.timer(interval: 0.005, leeway: 0, repeats: true) { ticks.add(executor.isCurrent) }
            t.check(AppSelfTest.spin(timeout: 60) { ticks.count >= 3 }, "the timer fires")
            timer.cancel()
            // A tick under way on the thread when the timer was cancelled ends before this work runs.
            let turns = SharedServiceThreadingSelfTests.Collected<Int>()
            executor.async { turns.add(ticks.count) }
            t.check(AppSelfTest.spin(timeout: 60) { turns.count == 1 }, "the thread goes on")
            // Two more turns of the thread, each long enough for several ticks of a timer still installed.
            executor.async(after: 0.05) { executor.async(after: 0.05) { turns.add(ticks.count) } }
            t.check(AppSelfTest.spin(timeout: 60) { turns.count == 2 }, "and on")
            t.equal(turns.all.last, turns.all.first, "no tick after the cancel")
            t.check(ticks.all.allSatisfy { $0 }, "every tick on the skin's thread")

            // Stopping ends the thread after the work queued before it; later work never runs.
            let last = SharedServiceThreadingSelfTests.Collected<String>()
            executor.async { last.add("before") }
            executor.stop()
            executor.async { last.add("after") }
            t.check(AppSelfTest.spin(timeout: 60) { executor.hasExited }, "the thread ends")
            t.equal(last.all, ["before"])
        }
    }

    // MARK: The stress run

    /// How much each skin does: `loads` loads (the later ones are refreshes: the old skin is closed and a new one
    /// loaded, as `!Refresh` does), each followed by `updatesPerLoad` updates, each update drawn. Updates are
    /// `interval` seconds apart on the skin's clock, far faster than any skin asks for, so that many of them run at
    /// the same time on different threads.
    struct Plan {
        var loads = 3
        var updatesPerLoad = 8
        var interval: TimeInterval = 0.002
        /// Configs drawn at their first update only. String\Review's Border around simulated-bold Chalkduster takes
        /// CoreGraphics seconds to rasterize into a bitmap (the stroked outlines have thousands of points; in the app
        /// the window server rasterizes what the skin records): drawn at every update, it alone would make the suite
        /// minutes long.
        var drawnOnce: Set<String> = ["String\\Review"]
        /// What the main thread does meanwhile, each spread evenly over the run by the skins' progress, so that a slow
        /// machine does no more of it: photos of the slideshows replaced, the image cache purged (Refresh All), a font
        /// removed or put back (every change goes to every skin), the AppKit inputs published again.
        var churn = Churn(photos: 32, purges: 12, fontChanges: 8, publishes: 16)

        /// `DESKSET_THREADS_SOAK=N` (a local soak; CI does not set it): N times the loads and the main thread's churn.
        static func fromEnvironment() -> Plan {
            var plan = Plan()
            if let factor = ProcessInfo.processInfo.environment["DESKSET_THREADS_SOAK"].flatMap(Int.init), factor > 1 {
                plan.loads *= factor
                plan.churn = Churn(photos: plan.churn.photos * factor, purges: plan.churn.purges * factor,
                                   fontChanges: plan.churn.fontChanges * factor,
                                   publishes: plan.churn.publishes * factor)
            }
            return plan
        }
    }

    struct Churn {
        var photos: Int
        var purges: Int
        var fontChanges: Int
        var publishes: Int
    }

    static func stressTests(_ t: AppTestRunner) {
        t.suite("App: threads: every test and default skin updates and draws on a thread of its own, all at once") {
            guard let testSkins = Paths.repositoryFolder("TestSkins"),
                  let defaultSkins = Paths.repositoryFolder("DefaultSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            // A copy: skins write their own files (!WriteKeyValue), and the suite adds photos and fonts.
            let root = t.temporaryDirectory("threads")
            let tests = root.appendingPathComponent("TestSkins")
            let defaults = root.appendingPathComponent("DefaultSkins")
            try FileManager.default.copyItem(at: testSkins, to: tests)
            try FileManager.default.copyItem(at: defaultSkins, to: defaults)
            let resources = tests.appendingPathComponent("Threads/@Resources")
            let photos = try Photos(folder: resources.appendingPathComponent("Photos"))
            let fonts = resources.appendingPathComponent("Fonts")
            let fontA = fonts.appendingPathComponent("A.ttf"), fontB = fonts.appendingPathComponent("B.ttf")
            let hasFonts = AppSelfTest.makeTestFont(family: "DesksetThrA", at: fontA)
                && AppSelfTest.makeTestFont(family: "DesksetThrB", at: fontB)
            if !hasFonts { print("    (no skin fonts: Courier New not found)") }
            let fontB2 = try hasFonts ? Data(contentsOf: fontB) : Data()
            t.atSuiteEnd {
                // The skin fonts go with the copy, and so do the photos; the suites that follow do not hear of it.
                try? FileManager.default.removeItem(at: fonts)
                Fonts.rescanFolder(fonts.path)
                Images.purge()
                _ = SharedServiceThreadingSelfTests.drainMainQueue()
            }

            var files = SkinFile.all(under: tests) + SkinFile.all(under: defaults)
            // More copies of the heavy fixtures (the same photos, fonts and Lua script from several threads at once)
            // and of the skins that read the shared services of §4.5–§4.8 (system monitor, process sampler, Wi-Fi,
            // focused window, SysColor and Chameleon inputs, NowPlaying, audio devices, ping, trash).
            for path in ["Threads/Slideshow/Slideshow.ini", "Threads/Slideshow/Slideshow.ini", "Threads/Fonts/Fonts.ini",
                         "Threads/Fonts/Fonts.ini", "Threads/DeepNesting/DeepNesting.ini", "App/SysInfo/SysInfo.ini",
                         "Engine/Compat/Legacy.ini", "MediaUI/WiFi/WiFi.ini", "MediaUI/Desktop/Desktop.ini",
                         "MediaUI/NowPlayingLive/NowPlayingLive.ini", "Audio/Volume/Volume.ini",
                         "Plugins/System/System.ini"] {
                guard let file = files.first(where: { $0.url.path.hasSuffix("/TestSkins/" + path) }) else {
                    t.check(false, "\(path) found")
                    continue
                }
                files.append(file)
            }
            t.check(files.count > 100, "skins found: \(files.count)")
            let plan = Plan.fromEnvironment()
            // What SkinController would compute on the main thread; the skins get it by value.
            let environment = SkinController.environment(windowFrame: nil)
            DesktopInputs.publishAll()
            let skins = files.enumerated().map { i, file in
                StressSkin(file: file, number: i, plan: plan, environment: environment)
            }

            // As the app does (`AppController.fontsChanged`): every change of the fonts goes to every skin, on its
            // own thread.
            let token = NotificationCenter.default.addObserver(forName: Fonts.didChangeNotification, object: nil,
                                                               queue: .main) { _ in
                for skin in skins { skin.fontsChanged() }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            for skin in skins { skin.start() }
            // The main thread's side, spread over the run by the skins' progress.
            let planned = Double(skins.count * plan.loads * plan.updatesPerLoad)
            var done = Churn(photos: 0, purges: 0, fontChanges: 0, publishes: 0)
            var fontBPresent = true
            /// Whether the next of `total` events is due: they happen at even steps of the progress.
            func due(_ count: Int, of total: Int, at progress: Double) -> Bool {
                count < total && progress >= Double(count + 1) / Double(total + 1)
            }
            let finished = AppSelfTest.spin(timeout: 480) {
                let progress = Double(skins.reduce(0) { $0 + $1.report.current.updates }) / planned
                if due(done.photos, of: plan.churn.photos, at: progress) {
                    photos.replace(done.photos)
                    done.photos += 1
                }
                if due(done.publishes, of: plan.churn.publishes, at: progress) {
                    DesktopInputs.publishAll()
                    done.publishes += 1
                }
                if due(done.purges, of: plan.churn.purges, at: progress) {
                    Images.purge()
                    done.purges += 1
                }
                if hasFonts, due(done.fontChanges, of: plan.churn.fontChanges, at: progress) {
                    // A skin author removing a font and putting it back, and a refresh reading the folder each time.
                    if fontBPresent {
                        try? FileManager.default.removeItem(at: fontB)
                    } else {
                        try? fontB2.write(to: fontB)
                    }
                    fontBPresent.toggle()
                    if Fonts.rescanFolder(fonts.path) { done.fontChanges += 1 }
                }
                return skins.allSatisfy { $0.report.current.finished }
            }
            t.check(finished, "every skin finished (a hang otherwise)")
            for skin in skins { skin.executor.stop() }
            t.check(AppSelfTest.spin(timeout: 60) { skins.allSatisfy { $0.executor.hasExited } },
                    "every skin thread ended")
            guard finished else { return }
            print("    \(skins.count) skins × \(plan.loads) loads × \(plan.updatesPerLoad) updates; meanwhile the main "
                  + "thread replaced \(done.photos) photos, purged the images \(done.purges) times, changed the fonts "
                  + "\(done.fontChanges) times")
            t.check(done.photos > 0 && done.purges > 0 && done.publishes > 0,
                    "the main thread replaced photos, purged the images and published its inputs meanwhile")
            if hasFonts { t.check(done.fontChanges > 0, "and changed the fonts") }

            // Every skin loaded, updated and drew as planned.
            var problems: [String] = []
            for skin in skins {
                let r = skin.report.current
                let name = skin.file.config + "\\" + skin.file.url.lastPathComponent
                if !r.loadErrors.isEmpty { problems.append("\(name): \(r.loadErrors)") }
                let draws = plan.drawnOnce.contains(skin.file.config) ? min(r.updates, 1) : r.updates
                if r.loads != plan.loads || r.updates != plan.loads * plan.updatesPerLoad || r.draws != draws {
                    problems.append("\(name): \(r.loads) loads, \(r.updates) updates, \(r.draws) draws")
                }
                if !(r.width.isFinite && r.height.isFinite && r.width > 0 && r.height > 0) {
                    problems.append("\(name): size \(r.width)×\(r.height)")
                }
            }
            t.equal(problems, [], "every skin loaded, updated and drew")
            if hasFonts {
                t.check(skins.contains { $0.report.current.fontsChanges > 0 }, "font changes reached the skins")
            }
            checkFixtures(t, skins, photos: photos, counts: resources.appendingPathComponent("Counts.inc"),
                          hasFonts: hasFonts)
        }
    }

    /// What the fixtures in TestSkins/Threads computed on their threads.
    private static func checkFixtures(_ t: AppTestRunner, _ skins: [StressSkin], photos: Photos, counts: URL,
                                      hasFonts: Bool) {
        func reports(_ config: String) -> [(file: SkinFile, report: StressSkin.Report, host: StressHost)] {
            skins.filter { $0.file.config == config }.map { ($0.file, $0.report.current, $0.host) }
        }

        // Deep nesting: the chain of actions reached the engine's limit, within the stack of a skin thread.
        let deep = reports("Threads\\DeepNesting")
        t.equal(deep.count, 2, "two deep nesting skins")
        for (_, report, host) in deep {
            t.check(host.logs.contains { $0.contains("nested too deeply") }, "the actions reached the limit")
            t.check(report.values["X"]?.isEmpty == false, "and set the variable on the way")
            let deepest = host.deepestStack
            print("    deep nesting: \(deepest / 1024) KB of the skin thread's 8192 KB stack")
            t.check(deepest > 0 && deepest < 4 << 20, "at most half of the stack: \(deepest / 1024) KB")
        }

        // Writers: four skins wrote a key of their own into one file at every update; every key is there.
        let writers = reports("Threads\\Writer")
        t.equal(writers.count, 4, "four writers")
        let written = (try? String(contentsOf: counts, encoding: .utf8)).map(IniDocument.parse)?
            .section(named: "Counts")?.entries ?? []
        for (file, report, _) in writers {
            let name = file.url.lastPathComponent
            guard let last = report.values["MeasureCount"] else { t.check(false, "\(name): its count"); continue }
            let keys = written.filter { $0.key.hasPrefix(name + " ") }
            t.equal(keys.count, report.updates, "\(name): a key for every update it wrote")
            t.equal(keys.first { $0.key == "\(name) \(report.loads)-\(last)" }?.value, last, "\(name): its last one too")
        }

        // Slideshows: each shows its current photo at the size of one of the photo's versions.
        let slides = reports("Threads\\Slideshow")
        t.equal(slides.count, 3, "three slideshows")
        for (_, report, _) in slides {
            guard let index = report.values["MeasureIndex"].flatMap(Double.init).map(Int.init),
                  let size = report.values["Native"] else { t.check(false, "slideshow facts"); continue }
            t.check(photos.sizes(of: index).contains(size), "photo \(index) shown at \(size)")
        }

        // Font-heavy: the skin's own font measured, not the fallback.
        let fonts = reports("Threads\\Fonts")
        t.equal(fonts.count, 3, "three font-heavy skins")
        if hasFonts {
            var style = TextStyle()
            style.fontFace = "No Such Font Anywhere"
            style.fontSize = 20
            let fallback = Double(TextLayoutCache().layout("iiiiiiiiiiii", style: style, wrapWidth: nil, cycle: 0)
                .size.width)
            for (_, report, _) in fonts {
                let width = report.values["Mono"].flatMap(Double.init) ?? 0
                t.check(width > fallback * 1.5, "monospaced i's (\(width)) are wider than the fallback's (\(fallback))")
            }
        }
    }

    // MARK: Skins on threads

    /// A skin file and where it belongs: its Skins folder is the parent of the nearest folder above it that has
    /// `@Resources` (its root config), else the fixture folder itself.
    struct SkinFile {
        let url: URL
        let skinsDirectory: URL
        let config: String

        /// Every .ini under `root`, outside `@Resources` folders, in a stable order.
        static func all(under root: URL) -> [SkinFile] {
            let fm = FileManager.default
            // The enumerator hands out paths with links resolved (/private/var/…, not /var/…).
            let root = root.resolvingSymlinksInPath()
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return [] }
            var files: [SkinFile] = []
            for case let found as URL in walker {
                let url = found.resolvingSymlinksInPath()
                if url.lastPathComponent == "@Resources" {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension.lowercased() == "ini" else { continue }
                let folder = url.deletingLastPathComponent()
                var skinsDirectory = root
                var cursor = folder
                while cursor.pathComponents.count > root.pathComponents.count {
                    if fm.fileExists(atPath: cursor.appendingPathComponent("@Resources").path) {
                        skinsDirectory = cursor.deletingLastPathComponent()
                        break
                    }
                    cursor.deleteLastPathComponent()
                }
                let config = folder.pathComponents.dropFirst(skinsDirectory.pathComponents.count).joined(separator: "\\")
                files.append(SkinFile(url: url, skinsDirectory: skinsDirectory, config: config))
            }
            return files.sorted { $0.url.path < $1.url.path }
        }
    }

    /// One skin on a thread of its own (`TestThreadExecutor`): loads it `plan.loads` times, updates and draws it
    /// `plan.updatesPerLoad` times after each load, then closes it and reports. Everything but `start`,
    /// `fontsChanged` and `report` runs on the skin's thread, the skin's owner.
    final class StressSkin {
        struct Report {
            var loads = 0
            var loadErrors: [String] = []
            var updates = 0
            var draws = 0
            var fontsChanges = 0
            var width = 0.0
            var height = 0.0
            /// Facts some fixtures compute (measure values, meter sizes, variables), as of the last update.
            var values: [String: String] = [:]
            var finished = false
        }

        let file: SkinFile
        let executor: TestThreadExecutor
        let host: StressHost
        let report = Guarded(Report())
        private let plan: Plan

        // The skin's thread only.
        private var skin: Skin?
        private var clock: SkinScheduledWork?
        private var canvas: CGContext?
        private var updatesThisLoad = 0

        init(file: SkinFile, number: Int, plan: Plan, environment: SkinEnvironment) {
            self.file = file
            self.plan = plan
            executor = TestThreadExecutor(name: "Deskset self-test skin \(number) \(file.config)")
            host = StressHost(environment: environment)
        }

        /// Main thread.
        func start() {
            executor.async { self.load() }
        }

        /// Main thread: the fonts changed; the skin lays out its text again, on its thread (as
        /// `AppController.fontsChanged` does for the app's skins). Its next update draws it.
        func fontsChanged() {
            executor.async {
                guard let skin = self.skin else { return }
                skin.fontsDidChange()
                self.report.access { $0.fontsChanges += 1 }
            }
        }

        /// Loads the skin as `SkinController` does (load, then its fonts), then runs its first update at once and the
        /// others on its clock.
        private func load() {
            let skin = Skin(config: file.config, fileURL: file.url, skinsDirectory: file.skinsDirectory,
                            system: SystemMonitor.shared, host: host)
            skin.executor = executor
            do {
                try skin.load()
            } catch {
                report.access {
                    $0.loadErrors.append("\(error)")
                    $0.finished = true
                }
                return
            }
            self.skin = skin
            let number = report.access { r -> Int in
                r.loads += 1
                return r.loads
            }
            // A fixture that declares StressLoad learns which load this is (the writer fixture names its keys with it).
            if skin.variable("StressLoad") != nil { skin.setVariable("StressLoad", "\(number)") }
            Fonts.registerFonts(for: skin)
            updatesThisLoad = 0
            clock = executor.timer(interval: plan.interval, leeway: 0, repeats: true) { [weak self] in self?.step() }
            step()
        }

        private func step() {
            guard let skin else { return }
            skin.update()
            draw(skin)
            updatesThisLoad += 1
            report.access { $0.updates += 1 }
            guard updatesThisLoad >= plan.updatesPerLoad else { return }
            clock?.cancel()
            clock = nil
            if report.current.loads < plan.loads {
                // A refresh: the old skin closes, a new one loads on a later turn (results of the old skin's
                // background work may still arrive meanwhile; they find it gone or closed).
                skin.close()
                self.skin = nil
                executor.async { self.load() }
            } else {
                // After what is queued already (plugin results, !Delay).
                executor.async { self.finish() }
            }
        }

        private func finish() {
            guard let skin else { return }
            var values: [String: String] = [:]
            for name in ["MeasureCount", "MeasureIndex"] {
                if let m = skin.measure(named: name) { values[name] = m.stringValue }
            }
            if let m = skin.meter(named: "Native") { values["Native"] = "\(Int(m.frame.width))×\(Int(m.frame.height))" }
            if let m = skin.meter(named: "Mono") { values["Mono"] = "\(m.frame.width)" }
            if let x = skin.variable("X") { values["X"] = x }
            let (width, height) = (skin.width, skin.height)
            skin.close()
            self.skin = nil
            canvas = nil
            report.access {
                $0.values = values
                $0.width = width
                $0.height = height
                $0.finished = true
            }
        }

        /// Draws the skin into a bitmap of its size, top-left origin, as its window would show it. No AppKit graphics
        /// context is set up: a skin thread draws a `CALayer` with a plain `CGContext` (§7.3).
        private func draw(_ skin: Skin) {
            if plan.drawnOnce.contains(file.config), report.current.draws > 0 { return }
            let w = Int(min(max(skin.width.rounded(.up), 1), 1024))
            let h = Int(min(max(skin.height.rounded(.up), 1), 1024))
            if canvas?.width != w || canvas?.height != h { canvas = Images.bitmapContext(width: w, height: h) }
            guard let ctx = canvas else { return }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            SkinRenderer.draw(skin, in: ctx)
            ctx.restoreGState()
            report.access { $0.draws += 1 }
        }
    }

    /// A `SkinHost` for skins on threads of their own: what the skin asks is answered on its thread, from values the
    /// main thread made beforehand (the environment) or from the thread-safe shared services (`SkinRenderer.textSize`
    /// with the skin's own layouts, `Images`); what it asks the app to do is recorded instead. It also notes how
    /// deep the skin thread's stack was whenever the engine called it.
    final class StressHost: SkinHost {
        private struct Records {
            var logs: [String] = []
            var deepestStack = 0
        }

        private let environment: SkinEnvironment
        private let records = Guarded(Records())

        init(environment: SkinEnvironment) {
            self.environment = environment
        }

        var logs: [String] { records.current.logs }
        /// Bytes of stack in use at the deepest call seen.
        var deepestStack: Int { records.current.deepestStack }

        func skinNeedsDisplay(_ skin: Skin) {}

        func skin(_ skin: Skin, handle bang: Bang) -> Bool {
            noteStack()
            return true
        }

        func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
        func skin(_ skin: Skin, execute target: String, arguments: [String]) {}

        func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
            noteStack()
            records.access { if $0.logs.count < 1000 { $0.logs.append("[\(level.rawValue)] \(message)") } }
        }

        func textSize(_ text: String, style: TextStyle, wrapWidth: Double?,
                      for skin: Skin) -> (width: Double, height: Double) {
            noteStack()
            return SkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
        }

        func imageSize(atPath path: String) -> (width: Double, height: Double)? {
            Images.size(atPath: path)
        }

        func environment(for skin: Skin) -> SkinEnvironment {
            noteStack()
            var env = environment
            env.windowFrame = SkinRect(width: skin.width, height: skin.height)
            return env
        }

        /// How much of the calling thread's stack is in use here (the stack grows down from its base address).
        private func noteStack() {
            let base = Int(bitPattern: pthread_get_stackaddr_np(pthread_self()))
            var marker = 0
            let here = withUnsafeMutablePointer(to: &marker) { Int(bitPattern: $0) }
            let depth = base - here
            records.access { $0.deepestStack = max($0.deepestStack, depth) }
        }
    }

    /// The slideshow fixture's photos (@Resources/Photos/1.png … 8.png), each in two versions of sizes of its own; the
    /// main thread replaces them while the skins show them, as a synced photo folder would.
    final class Photos {
        static let count = 8
        let folder: URL
        private var shown = Array(repeating: 0, count: Photos.count)

        init(folder: URL) throws {
            self.folder = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 1...Photos.count { try write(i, version: 0, replacing: false) }
        }

        /// "W×H" of each version of photo `index` (1-based).
        func sizes(of index: Int) -> Set<String> {
            Set((0...1).map { version in
                let (w, h) = Photos.size(index, version: version)
                return "\(w)×\(h)"
            })
        }

        /// Replaces photo `turn % count + 1` with its other version. Main thread.
        func replace(_ turn: Int) {
            let i = turn % Photos.count
            shown[i] = 1 - shown[i]
            try? write(i + 1, version: shown[i], replacing: true)
        }

        private func write(_ index: Int, version: Int, replacing: Bool) throws {
            let (w, h) = Photos.size(index, version: version)
            try SharedServiceThreadingSelfTests.writePNG(to: folder.appendingPathComponent("\(index).png").path,
                                                         width: w, height: h, replacing: replacing)
        }

        private static func size(_ index: Int, version: Int) -> (Int, Int) {
            (320 + 24 * index + 8 * version, 240 + 16 * index + 6 * version)
        }
    }
}

// MARK: - A skin thread

/// A skin executor on a dedicated thread with its own run loop and an 8 MB stack, as docs/skin-threading.md §5.3
/// recommends for desktop skins. A test executor for now: the stress suite runs skins on it; phase 3 turns it into the
/// app's `SkinThreadExecutor`.
///
/// - `async` queues a block on the thread's run loop (`CFRunLoopPerformBlock`): first in, first out, never inline.
/// - Delayed work and timers are Foundation timers on that run loop, installed and invalidated on the thread (a timer
///   belongs to the thread whose run loop it was added to); cancelling from another thread invalidates it there.
/// - `stop()` ends the thread once the work queued before it has run. Work queued later never runs: a skin's own
///   work cannot come later (the skin is closed and let go of first), and what background work hands over holds the
///   skin weakly (`SkinHop`), so nothing queued late keeps a skin.
final class TestThreadExecutor: SkinExecutor {
    /// Set up on the thread before `init` returns and read-only afterwards, except `stopped` (the thread's own).
    private final class Loop {
        var runLoop: CFRunLoop?
        var thread: pthread_t?
        var stopped = false
    }

    private let loop = Loop()
    private let exited = Guarded(false)

    init(name: String, stackSize: Int = 8 << 20) {
        let loop = self.loop, exited = self.exited
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            loop.runLoop = CFRunLoopGetCurrent()
            loop.thread = pthread_self()
            // A port keeps the run loop waiting when it has no timer, rather than returning at once.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while !loop.stopped {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
            }
            exited.access { $0 = true }
        }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        // Waits for a new thread to start, never for skin work.
        ready.wait()
    }

    var isCurrent: Bool {
        guard let thread = loop.thread else { return false }
        return pthread_equal(thread, pthread_self()) != 0
    }

    /// The thread has ended (after `stop()`).
    var hasExited: Bool { exited.current }

    func async(_ work: @escaping () -> Void) {
        guard let runLoop = loop.runLoop else { return }
        let loop = self.loop
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            // The run loop runs every block queued before it looked, also those queued after the one that stopped it.
            guard !loop.stopped else { return }
            autoreleasepool { work() }
        }
        CFRunLoopWakeUp(runLoop)
    }

    @discardableResult
    func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
        schedule(SkinScheduledWork(work), interval: delay, leeway: 0, repeats: false)
    }

    func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
               _ fire: @escaping () -> Void) -> SkinScheduledWork {
        schedule(SkinScheduledWork(repeats: repeats, fire), interval: interval, leeway: leeway, repeats: repeats)
    }

    /// Ends the thread once the work queued before this has run. Any thread.
    func stop() {
        let loop = self.loop
        async {
            loop.stopped = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    /// Installs a timer for `scheduled` on the thread: at once when called there (it still fires on a later turn,
    /// never inline), else on the thread's next turn.
    private func schedule(_ scheduled: SkinScheduledWork, interval: TimeInterval, leeway: TimeInterval,
                          repeats: Bool) -> SkinScheduledWork {
        let install = {
            // Cancelled before it was installed.
            guard scheduled.isPending else { return }
            let timer = Timer(timeInterval: max(interval, 0), repeats: repeats) { _ in scheduled.fire() }
            timer.tolerance = leeway
            RunLoop.current.add(timer, forMode: .common)
            // Weak: the run loop owns the timer until it is invalidated (a one-shot invalidates itself once it fired).
            scheduled.setCancelHandler { [weak timer] in
                if self.isCurrent {
                    timer?.invalidate()
                } else {
                    // Until then, `fire()` does nothing.
                    self.async { timer?.invalidate() }
                }
            }
        }
        if isCurrent { install() } else { async(install) }
        return scheduled
    }
}
