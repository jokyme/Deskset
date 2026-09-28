import AppKit
import DesksetCore

/// A skin's life as messages, its window companions and its menu (docs/skin-threading.md §15, phase 2 step 5): the
/// runtime loads and starts the skin and reports `.started` or `.failed`, `.close` reports `.closed`, FrostedGlass's
/// backdrop and InputText's box are companions of the window on the main thread, and the skin menu reads the live skin
/// only when it lets go within 50 ms. Every skin of the app still runs on the main executor, where all of it happens
/// inline (the existing suites check that nothing changed); here the desktop skin runs on a test thread
/// (`TestThreadExecutor`, through `AppController.skinExecutor`). Nothing waits for a fixed time: a gate holds a skin's
/// thread where a test needs the skin busy, and the tests wait for conditions.
enum SkinLifecycleSelfTests {
    static func run(_ t: AppTestRunner) {
        startTests(t)
        closeTests(t)
        companionTests(t)
        menuTests(t)
        weatherCreditTests(t)
    }

    // MARK: Starting

    static func startTests(_ t: AppTestRunner) {
        t.suite("App: skin lifecycle: a skin on a thread loads there, and its window is placed and shown after .started") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Placed": plainSkin])
            app.state.update("Life\\Placed") {
                $0.file = "Placed.ini"
                $0.x = 200
                $0.y = 150
                $0.savePosition = true
            }
            let executor = TestThreadExecutor(name: "Lifecycle placed")
            app.skinExecutor = { $0 == "Life\\Placed" ? executor as SkinExecutor : MainSkinExecutor.shared }
            var notices = 0
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: nil) { _ in notices += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            weak var skin: Skin?
            autoreleasepool {
                let gate = Gate()
                gate.hold(executor)
                guard let c = app.activate(config: "Life\\Placed", file: nil) else {
                    return t.check(false, "the window is made at once")
                }
                skin = c.runtime.skin
                let unplaced = c.window.frame
                t.check(app.controller(for: "Life\\Placed") === c, "and registered at once")
                t.check(!c.isStarted && c.showCount == 0, "neither placed nor shown while the skin waits to load")
                notices = 0
                gate.open()
                // The skin loads and makes its first update on its thread; the main thread has not turned since.
                t.equal(c.runtime.exclusive(timeout: 30) { $0.updateCount }, 1, "loaded and updated on its thread")
                t.check(!c.isStarted && c.showCount == 0 && c.window.frame == unplaced, "the window waits for .started")
                t.equal(notices, 0, "the app has not heard of it yet")
                t.check(AppSelfTest.spin(timeout: 30) { c.isStarted }, ".started arrives")
                t.equal(c.showCount, 1, "then the window is placed and shown, once")
                t.close(c.topLeftPosition.x, 200, accuracy: 0.5, "at its saved place")
                t.close(c.topLeftPosition.y, 150, accuracy: 0.5)
                t.equal(c.window.frame.size, c.runtime.snapshot.size, "at the size of its first update")
                t.check(notices >= 1, "and the app heard of it")
                t.equal(app.state.skin("Life\\Placed")?.active, true)
                app.deactivate(config: "Life\\Placed")
            }
            finish(t, skin: { skin }, executor)
        }

        t.suite("App: skin lifecycle: a first load on a thread seeds the window settings before its first update") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Seeded": """
                [Rainmeter]
                Update=-1
                DefaultAlwaysOnTop=1
                DefaultStartHidden=1

                [MeasureZ]
                Measure=String
                String=#CURRENTCONFIGZPOS#
                DynamicVariables=1

                """ + meter])
            let executor = TestThreadExecutor(name: "Lifecycle seeded")
            app.skinExecutor = { $0 == "Life\\Seeded" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "Life\\Seeded", file: nil) else { return t.check(false, "loads") }
                skin = c.runtime.skin
                t.check(AppSelfTest.spin(timeout: 30) { c.isStarted }, "started")
                t.equal(c.runtime.exclusive(timeout: 30) { $0.measure(named: "MeasureZ")?.stringValue }, "1",
                        "its first update read the seeded Z position")
                t.equal(app.state.skin("Life\\Seeded")?.alwaysOnTop, 1, "the app saved the seeded settings at the start")
                t.equal(app.state.skin("Life\\Seeded")?.startHidden, true)
                t.check(c.isHiddenByBang, "StartHidden: the window stays hidden")
                t.equal(c.window.level, WindowGeometry.level(forAlwaysOnTop: 1))
                app.deactivate(config: "Life\\Seeded")
            }
            finish(t, skin: { skin }, executor)
        }

        t.suite("App: skin lifecycle: a skin that cannot be loaded reports .failed, and its config is marked inactive") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Broken": plainSkin, "BrokenMain": plainSkin])
            t.equal(app.library.filter { $0.name.hasPrefix("Life\\Broken") }.count, 2, "in the library")
            // Deleted after the library found them: loading them fails.
            for name in ["Broken", "BrokenMain"] { try FileManager.default.removeItem(at: file(app, name)) }
            let executor = TestThreadExecutor(name: "Lifecycle broken")
            app.skinExecutor = { $0 == "Life\\Broken" ? executor as SkinExecutor : MainSkinExecutor.shared }
            // The main executor: all of it inside activate, which returns nil as it always did.
            t.check(app.activate(config: "Life\\BrokenMain", file: nil) == nil, "on the main executor: nil at once")
            t.check(app.controller(for: "Life\\BrokenMain") == nil)
            t.equal(app.state.skin("Life\\BrokenMain")?.active, false)
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "Life\\Broken", file: nil) else {
                    return t.check(false, "on a thread the window is made at once; the failure comes later")
                }
                skin = c.runtime.skin
                t.check(AppSelfTest.spin(timeout: 30) { c.loadFailed }, ".failed arrives")
                t.check(app.controller(for: "Life\\Broken") == nil, "the config is unloaded")
                t.equal(app.state.skin("Life\\Broken")?.active, false, "and marked inactive")
                t.check(!c.isStarted && c.showCount == 0, "the window was never shown")
                t.check(c.runtime.didClose && c.isStopped, "the skin counts as closed")
                t.equal(c.content.state.tornDown, true, "its content layer is torn down")
            }
            finish(t, skin: { skin }, executor)
        }

        t.suite("App: skin lifecycle: a refresh of a skin on a thread keeps the Calc counter") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Counter": """
                [Rainmeter]
                Update=-1

                [MeasureCounter]
                Measure=Calc
                Formula=Counter

                """ + meter])
            let executor = TestThreadExecutor(name: "Lifecycle counter")
            app.skinExecutor = { $0 == "Life\\Counter" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "Life\\Counter", file: nil) else { return t.check(false, "loads") }
                t.check(AppSelfTest.spin(timeout: 30) { c.isStarted }, "started")
                for _ in 0..<4 { c.runtime.send(.update(hops: 0)) }
                let before = c.runtime.exclusive(timeout: 30) { $0.counter } ?? -1
                t.equal(before, 5, "the first update and four more")
                app.refresh(c)
                guard let refreshed = app.controller(for: "Life\\Counter"), refreshed !== c else {
                    return t.check(false, "a new window at once")
                }
                skin = refreshed.runtime.skin
                t.check(AppSelfTest.spin(timeout: 30) { refreshed.isStarted }, "the new skin started")
                t.check(c.runtime.didClose, "the old one closed")
                t.equal(c.runtime.snapshot.counter, before, "its snapshot at the close has its counter")
                // Counter = the updates completed before this one: the old skin's last update showed 4.
                t.equal(refreshed.runtime.exclusive(timeout: 30) { $0.measure(named: "MeasureCounter")?.value },
                        Double(before), "the new skin's first update goes on from it")
                app.deactivate(config: "Life\\Counter")
            }
            finish(t, skin: { skin }, executor)
        }
    }

    // MARK: Closing

    static func closeTests(_ t: AppTestRunner) {
        t.suite("App: skin lifecycle: quitting runs every OnCloseAction on the skins' thread in reverse load order") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let closing = { (name: String) in """
                [Rainmeter]
                Update=-1
                OnCloseAction=[!CommandMeasure MeasureScript "Stall(0.1)"][!CommandMeasure MeasureScript "Append('\(name)')" "Life\\Collector"]

                [MeasureScript]
                Measure=Script
                ScriptFile=#@#Life.lua

                """ + meter
            }
            try write(app, ["Collector": collectorSkin, "A": closing("A"), "B": closing("B"), "C": closing("C")])
            let names = ["Collector", "A", "B", "C"]
            for (order, name) in names.enumerated() {
                app.state.update("Life\\\(name)") {
                    $0.file = "\(name).ini"
                    $0.loadOrder = order + 1
                }
            }
            let executor = TestThreadExecutor(name: "Lifecycle quitting")
            app.skinExecutor = { _ in executor }
            let started = names.compactMap { app.activate(config: "Life\\\($0)", file: nil) }
            t.equal(started.count, 4)
            t.check(AppSelfTest.spin(timeout: 30) { started.allSatisfy(\.isStarted) }, "all started")
            let start = Date()
            let late = app.stopAllForTermination()
            let waited = Date().timeIntervalSince(start)
            t.equal(late, [], "every skin closed in time")
            t.check(waited < AppController.terminationBudget, "within the budget: \(waited) s")
            t.check(started.allSatisfy { $0.runtime.didClose }, "all closed when quitting went on")
            t.equal(started[0].runtime.exclusive(timeout: 30) { $0.variable("Log") }, "C;B;A;",
                    "each OnCloseAction ran before the one of the skin loaded before it")
            executor.stop()
        }

        t.suite("App: skin lifecycle: quitting waits at most its budget for a skin that does not close") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Stuck": """
                [Rainmeter]
                Update=-1
                OnCloseAction=[!SetVariable Closed 1]

                [Variables]
                Closed=0

                """ + meter])
            let executor = TestThreadExecutor(name: "Lifecycle stuck")
            app.skinExecutor = { _ in executor }
            guard let c = app.activate(config: "Life\\Stuck", file: nil) else { return t.check(false, "loads") }
            t.check(AppSelfTest.spin(timeout: 30) { c.isStarted }, "started")
            let gate = Gate()
            gate.hold(executor)
            let start = Date()
            let late = app.stopAllForTermination(budget: 1)
            let waited = Date().timeIntervalSince(start)
            t.equal(late, ["Life\\Stuck"], "quitting went on without it")
            t.check(waited >= 0.95 && waited < 10, "after the budget: \(waited) s")
            t.check(!c.runtime.didClose)
            gate.open()
            t.check(AppSelfTest.spin(timeout: 30) { c.runtime.didClose }, "it closes once its thread goes on")
            t.equal(c.runtime.exclusive(timeout: 30) { $0.variable("Closed") }, "1", "and its OnCloseAction ran")
            executor.stop()
        }

        t.suite("App: skin lifecycle: the installer replaces a skin's files only once the skin on its thread has closed") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("LifePkg/Widget", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let installed = folder.appendingPathComponent("Widget.ini")
            // Its OnCloseAction writes to its own file, on its thread.
            try """
                [Rainmeter]
                Update=-1
                OnCloseAction=[!WriteKeyValue Variables Closed 1]

                [Variables]
                Closed=0

                """.appending(meter).write(to: installed, atomically: true, encoding: .utf8)
            app.rescanLibrary()
            let executor = TestThreadExecutor(name: "Lifecycle installer")
            app.skinExecutor = { $0 == "LifePkg\\Widget" ? executor as SkinExecutor : MainSkinExecutor.shared }
            let manifest = "[rmskin]\nName=Life\nAuthor=Deskset tests\nVersion=2\nLoadType=Skin\n"
                + "Load=LifePkg\\Widget\\Widget.ini\n"
            let package = try AppSelfTest.makePackage(t, name: "LifePkg.rmskin", files: [
                "RMSKIN.ini": Data(manifest.utf8),
                "Skins/LifePkg/Widget/Widget.ini": Data(("[Rainmeter]\nUpdate=-1\n\n[Variables]\nClosed=0\nVersion=2\n\n"
                                                         + meter).utf8),
            ])
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "LifePkg\\Widget", file: nil) else { return t.check(false, "loads") }
                t.check(AppSelfTest.spin(timeout: 30) { c.isStarted }, "started")
                // The skin's close waits behind the gate.
                let gate = Gate()
                gate.hold(executor)
                app.installer.open([package])
                t.check(AppSelfTest.spin(timeout: 30) { app.installer.waitsForSkinsToClose }, "it stopped the skin and waits")
                t.check(c.isStopped && !c.runtime.didClose, "the skin has not closed yet")
                t.check(((try? String(contentsOf: installed, encoding: .utf8)) ?? "").contains("Closed=0")
                        && !((try? String(contentsOf: installed, encoding: .utf8)) ?? "").contains("Version=2"),
                        "its files are not replaced yet")
                gate.open()
                t.check(AppSelfTest.spin(timeout: 30) {
                    app.installer.isIdle && app.controller(for: "LifePkg\\Widget").map { $0 !== c && $0.isStarted } == true
                }, "installed, and the new skin loaded")
                let now = (try? String(contentsOf: installed, encoding: .utf8)) ?? ""
                t.check(now.contains("Version=2"), "the package's file")
                t.check(!now.contains("Closed=1"), "the old skin's OnCloseAction did not write into the new file")
                let backup = app.backupsDirectory.appendingPathComponent("LifePkg/Widget/Widget.ini")
                t.check(((try? String(contentsOf: backup, encoding: .utf8)) ?? "").contains("Closed=1"),
                        "it wrote into the old one, which went to Backups")
                skin = app.controller(for: "LifePkg\\Widget")?.runtime.skin
                app.deactivate(config: "LifePkg\\Widget")
            }
            finish(t, skin: { skin }, executor)
        }
    }

    // MARK: Window companions

    static func companionTests(_ t: AppTestRunner) {
        t.suite("App: skin lifecycle: FrostedGlass on a skin's thread asks for its backdrop, which follows the window") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Glass": """
                [Rainmeter]
                Update=-1

                [MeasureGlass]
                Measure=Plugin
                Plugin=FrostedGlass
                Type=Acrylic
                Corner=Round

                """ + meter])
            let executor = TestThreadExecutor(name: "Lifecycle glass")
            app.skinExecutor = { $0 == "Life\\Glass" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "Life\\Glass", file: nil) else { return t.check(false, "loads") }
                skin = c.runtime.skin
                t.check(AppSelfTest.spin(timeout: 30) {
                    c.isStarted && FrostedGlassBackdrop.backdrop(for: c) != nil && c.contentView.layer?.cornerRadius == 8
                }, "the backdrop and the rounding come from the skin's request")
                let backdrop = FrostedGlassBackdrop.backdrop(for: c)
                t.check(backdrop?.followedWindow === c.window, "behind the skin's window")
                t.equal(backdrop?.effectView.material, .popover)
                t.check(backdrop?.effectWindow.isVisible == false, "headless: never shown")
                // A new panel (ClickThrough turned off again, on the skin's thread): the backdrop goes behind it.
                let first = c.window
                c.runtime.send(.execute("[!ClickThrough 1][!ClickThrough 0]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { c.window !== first && backdrop?.followedWindow === c.window },
                        "it follows the new window")
                // A command on the skin's thread: the new style reaches the window.
                c.runtime.send(.execute("[!CommandMeasure MeasureGlass DisableCorner]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { c.contentView.layer?.cornerRadius == 0 }, "no rounding")
                t.equal(c.runtime.exclusive(timeout: 30) { ($0.measure(named: "MeasureGlass") as? FrostedGlassMeasure)?
                    .sentStyle?.cornersEnabled }, false, "the style the measure sent")
                app.deactivate(config: "Life\\Glass")
                t.check(FrostedGlassBackdrop.backdrop(for: c) == nil, "the backdrop goes with the window")
            }
            finish(t, skin: { skin }, executor)
        }

        t.suite("App: skin lifecycle: InputText's box on the main thread answers the skin's thread, where its commands run") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Input": """
                [Rainmeter]
                Update=-1

                [Variables]
                Note=old

                [MeasureInput]
                Measure=Plugin
                Plugin=InputText
                X=8
                Y=8
                W=200
                H=22
                DefaultValue=#Note#
                Command1=[!SetVariable Note "$UserInput$"]

                """ + meter])
            let fake = MediaUITests.FakePrompt()
            var hosts: [ObjectIdentifier] = []
            SkinWindowCompanions.inputTextPromptFactory = { host in
                hosts.append(ObjectIdentifier(host))
                return fake
            }
            defer { SkinWindowCompanions.inputTextPromptFactory = nil }
            let executor = TestThreadExecutor(name: "Lifecycle input")
            app.skinExecutor = { $0 == "Life\\Input" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "Life\\Input", file: nil) else { return t.check(false, "loads") }
                skin = c.runtime.skin
                t.check(AppSelfTest.spin(timeout: 30) { c.isStarted }, "started")
                let answered = Guarded<[Bool]>([])
                _ = c.runtime.exclusive(timeout: 30) { _ in
                    c.runtime.messageObserver = { message in
                        if case .inputTextAnswered = message { answered.access { $0.append(executor.isCurrent) } }
                    }
                }
                c.runtime.send(.execute(#"[!CommandMeasure MeasureInput "ExecuteBatch 1"]"#, section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { fake.shown.count == 1 }, "the window shows the box")
                t.equal(fake.shown.first?.defaultValue, "old", "with the settings the skin worked out")
                t.equal(hosts, [ObjectIdentifier(c)], "over the skin's window")
                t.equal(c.companions.openInputTexts, 1)
                fake.answer("typed on main")
                t.check(AppSelfTest.spin(timeout: 30) {
                    c.runtime.exclusive(timeout: 30) { $0.variable("Note") } == "typed on main"
                }, "the command ran with what was typed")
                t.equal(answered.current, [true], "the answer came back to the skin's thread")
                t.equal(c.companions.openInputTexts, 0)
                t.equal(c.runtime.exclusive(timeout: 30) { ($0.measure(named: "MeasureInput") as? InputTextMeasure)?.lastInput },
                        "typed on main")

                // A box still open when the skin unloads closes without an answer.
                c.runtime.send(.execute(#"[!CommandMeasure MeasureInput "ExecuteBatch 1"]"#, section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { fake.shown.count == 2 }, "shown again")
                app.deactivate(config: "Life\\Input")
                t.equal(fake.cancelled, 1, "closed with the window")
                t.equal(answered.current, [true], "nothing more answered")
            }
            finish(t, skin: { skin }, executor)
        }
    }

    // MARK: The skin menu

    static func menuTests(_ t: AppTestRunner) {
        t.suite("App: skin lifecycle: the skin menu shows the snapshot's items while the skin is busy, the live ones otherwise") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Menu": """
                [Rainmeter]
                Update=-1
                ContextTitle=Count [MeasureCount]
                ContextAction=[!SetVariable Chosen yes]

                [Metadata]
                Name=Busy Widget

                [Variables]
                Chosen=no

                [MeasureCount]
                Measure=Calc
                Formula=Counter

                [MeasureScript]
                Measure=Script
                ScriptFile=#@#Life.lua

                """ + meter])
            // A call of two seconds: the limits of Lua calls let it run.
            let limits = (LuaSupport.secondsLimit, LuaSupport.instructionLimit)
            LuaSupport.secondsLimit = 30
            LuaSupport.instructionLimit = 50_000_000_000
            defer { (LuaSupport.secondsLimit, LuaSupport.instructionLimit) = limits }
            let executor = TestThreadExecutor(name: "Lifecycle menu")
            app.skinExecutor = { $0 == "Life\\Menu" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "Life\\Menu", file: nil) else { return t.check(false, "loads") }
                skin = c.runtime.skin
                t.check(AppSelfTest.spin(timeout: 30) { c.isStarted }, "started")
                for _ in 0..<3 { c.runtime.send(.update(hops: 0)) }
                let stalling = Guarded(false)
                let chosen = Guarded<[Bool]>([])
                _ = c.runtime.exclusive(timeout: 30) { _ in
                    c.runtime.messageObserver = { message in
                        guard case .execute(let action, _) = message else { return }
                        if action.contains("Stall") { stalling.access { $0 = true } }
                        if action.contains("Chosen") { chosen.access { $0.append(executor.isCurrent) } }
                    }
                }
                let stale = c.runtime.snapshot.contextItems.map(\.title)
                t.check(!stale.isEmpty, "the snapshot has the items: \(stale)")

                // Busy in a two-second Lua call: the menu does not wait for it.
                c.runtime.send(.execute(#"[!CommandMeasure MeasureScript "Stall(2)"]"#, section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { stalling.current }, "the call starts")
                let start = Date()
                let busy = app.menuFacts(for: c)
                let menu = app.skinMenu(for: c, includeCustomItems: true)
                let custom = app.customSkinMenu(for: c)
                let waited = Date().timeIntervalSince(start)
                t.check(!busy.isLive, "the skin is busy: its snapshot's items")
                t.equal(busy.items.map(\.title), stale)
                t.equal(busy.name, "Busy Widget", "the name from the snapshot")
                t.check(menu.items.contains { $0.title == stale.first }, "in the skin menu")
                t.equal(custom?.items.map(\.title), stale, "and in !SkinCustomMenu's")
                t.check(waited < 1.5, "three menus without waiting for the skin: \(waited) s")

                // The call is over: the live items, whose title shows the counter now.
                _ = c.runtime.exclusive(timeout: 30) { _ in true }
                let live = app.menuFacts(for: c)
                t.check(live.isLive, "read from the skin")
                t.equal(live.items.first?.title, "Count 3", "the title as it is now")
                t.check(live.items.first?.title != stale.first, "not the snapshot's")
                t.equal(live.name, "Busy Widget")

                // A chosen item runs on the skin's thread.
                guard let item = app.skinMenu(for: c, includeCustomItems: true).items.first(where: {
                    $0.title == "Count 3"
                }) else { return t.check(false, "the item") }
                app.customContextAction(item)
                t.check(AppSelfTest.spin(timeout: 30) {
                    c.runtime.exclusive(timeout: 30) { $0.variable("Chosen") } == "yes"
                }, "its action ran")
                t.equal(chosen.current, [true], "on the skin's thread")
                app.deactivate(config: "Life\\Menu")
            }
            finish(t, skin: { skin }, executor)
        }
    }

    // MARK: The weather credit of a busy skin

    static func weatherCreditTests(_ t: AppTestRunner) {
        t.suite("App: skin lifecycle: a busy skin's menu still credits the weather it shows, from its snapshot") {
            let (weather, _) = try MediaUITests.bareSkin(t, "[Rainmeter]\nUpdate=-1\n[MeasureWeather]\nMeasure=Plugin\n"
                                                         + "Plugin=MacWeather\nLocation=Oslo, NO\nDisabled=1\n")
            defer { weather.close() }
            var snapshot = SkinSnapshot()
            snapshot.rebuild(from: weather, generation: 0)
            t.check(snapshot.usesWeather, "the skin shows MET Norway's data")
            let target = NSObject()
            let items = WeatherWiring.menuItems(for: (snapshot.usesWeather, nil), target: target,
                                                action: #selector(AppController.openWeatherSourceAction(_:)))
            t.equal(items.map(\.title), ["Weather: \(METNorway.attribution) ↗"], "the credit, without the time of the data")
            let (plain, _) = try MediaUITests.bareSkin(t, "[Rainmeter]\nUpdate=-1\n[M]\nMeasure=Calc\n")
            defer { plain.close() }
            var none = SkinSnapshot()
            none.rebuild(from: plain, generation: 0)
            t.check(!none.usesWeather, "a skin without weather has no credit")
        }
    }

    // MARK: Helpers

    /// Holds a skin's thread where it is until the test opens it (a test's stand-in for a skin busy in a long piece of
    /// work). It gives up by itself after a minute, so a failed test does not keep the thread forever.
    final class Gate {
        private let semaphore = DispatchSemaphore(value: 0)

        func hold(_ executor: SkinExecutor) {
            let semaphore = self.semaphore
            executor.async { _ = semaphore.wait(timeout: .now() + 60) }
        }

        func open() {
            semaphore.signal()
        }
    }

    /// A box the skins draw, so their windows have a size.
    static let meter = """
        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,120,60 | Fill Color 30,30,40,255 | StrokeWidth 0

        """

    static let plainSkin = "[Rainmeter]\nUpdate=-1\n\n" + meter

    /// Collects the names the other skins' OnCloseActions append (`Append`), in `Log`.
    static let collectorSkin = """
        [Rainmeter]
        Update=-1

        [Variables]
        Log=

        [MeasureScript]
        Measure=Script
        ScriptFile=#@#Life.lua

        """ + meter

    /// `Life\@Resources\Life.lua`.
    static let script = """
        function Initialize()
            Log = ''
        end

        -- Keeps the skin busy for `seconds`.
        function Stall(seconds)
            local start = os.clock()
            while os.clock() - start < seconds do end
        end

        function Append(name)
            Log = Log .. name .. ';'
            SKIN:Bang('!SetVariable', 'Log', Log)
        end

        """

    /// Writes the skins (name → text) as `Life\Name\Name.ini`, with the script they share.
    static func write(_ app: AppController, _ skins: [String: String]) throws {
        let resources = app.skinsDirectory.appendingPathComponent("Life/@Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try script.write(to: resources.appendingPathComponent("Life.lua"), atomically: true, encoding: .utf8)
        for (name, text) in skins {
            let url = file(app, name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        app.rescanLibrary()
    }

    static func file(_ app: AppController, _ name: String) -> URL {
        app.skinsDirectory.appendingPathComponent("Life/\(name)/\(name).ini")
    }

    /// Waits for a skin on a test thread to be let go of (its runtime went with its window controller), then ends the
    /// thread.
    static func finish(_ t: AppTestRunner, skin: () -> Skin?, _ executor: TestThreadExecutor) {
        t.check(AppSelfTest.spin(timeout: 30) { skin() == nil }, "the skin on the thread is let go of")
        executor.stop()
    }
}
