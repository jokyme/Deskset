import AppKit
import DesksetCore

/// The engine thread (docs/skin-threading.md §15, phase 2 step 7): with `SkinThreading=engine` every desktop skin of the
/// app runs on one shared `SkinThreadExecutor`, and the main thread reaches them only through messages, snapshots,
/// window facts and exclusive access. These suites build their app with `.engine` (the other suites keep `.main`), never
/// present windows, and force what the frame producer sees through the window facts (`visibilityForTesting`). Nothing
/// waits for a fixed time: the tests wait for conditions, and a gate holds the engine thread where a test needs it busy.
enum EngineThreadSelfTests {
    static func run(_ t: AppTestRunner) {
        keyTests(t)
        lifeTests(t)
        orderTests(t)
        frameTests(t)
        inputTests(t)
        windowTests(t)
        bangTests(t)
        companionTests(t)
        menuTests(t)
        studioTests(t)
        systemTests(t)
        defaultSuiteTests(t)
    }

    // MARK: The SkinThreading key

    static func keyTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: SkinThreading says main or engine; engine unless it says main, and says so") {
            func chosen(_ value: Any?) -> (mode: SkinThreading, note: String?) {
                // Registered values live in memory only: nothing is written to the user's preferences.
                guard let defaults = UserDefaults(suiteName: "app.deskset.selftest.threading.\(UUID().uuidString)")
                else { return (.main, "no defaults") }
                if let value { defaults.register(defaults: [SkinThreading.defaultsKey: value]) }
                return SkinThreading.chosen(in: defaults)
            }
            let unset = chosen(nil)
            t.check(unset.mode == .engine && unset.note == nil, "not set: the engine thread, the app's default")
            t.equal(SkinThreading.appDefault, .engine)
            let engine = chosen("engine")
            t.check(engine.mode == .engine && engine.note == nil, "engine")
            let main = chosen("main")
            t.check(main.mode == .main, "main, for debugging")
            t.check(main.note?.contains("main thread") == true, "and the log says so: \(main.note ?? "")")
            t.equal(chosen(" Main ").mode, .main, "in any case, with spaces around")
            let perSkin = chosen("perSkin")
            t.equal(perSkin.mode, .engine, "a mode of a later phase: the default")
            t.check(perSkin.note?.contains("\"perSkin\"") == true, "logged: \(perSkin.note ?? "")")
            let number = chosen(1)
            t.check(number.mode == .engine && number.note != nil, "not a word: the default, logged")
            t.check(CommandLineTools.usage.contains("SkinThreading"), "--help mentions it")
            t.check(CommandLineTools.usage.contains("engine (the default)"), "and the default")

            // An app made without saying (the self-tests', the headless modes') keeps every skin on the main thread;
            // only the menu bar app reads the key (`main.swift`).
            let root = t.temporaryDirectory("engine-key")
            let plain = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                      skinsDirectory: root.appendingPathComponent("Skins"),
                                      layoutsDirectory: root.appendingPathComponent("Layouts"),
                                      backupsDirectory: root.appendingPathComponent("Backups"), settingsDirectory: root,
                                      presentsWindows: false)
            keptApps.append(plain)
            t.equal(plain.threading, .main)
            t.check(plain.skinExecutor("Any\\Config") === MainSkinExecutor.shared, "main: the main executor")
            t.check(plain.engineThread == nil)
            guard let app = try AppSelfTest.makeApp(t) else { return }
            t.equal(app.threading, .main, "the self-tests' apps")
            guard let engineApp = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            t.check(engineApp.engineThread == nil, "the engine thread comes with the first skin")
            let first = engineApp.skinExecutor("Any\\Config")
            let second = engineApp.skinExecutor("Other\\Config")
            t.check(first === second && first === engineApp.engineThread, "one shared engine thread")
            t.check(first !== MainSkinExecutor.shared)
            let name = onEngine(engineApp) { Thread.current.name ?? "" }
            t.equal(name, "Deskset skin engine", "named for crash reports and samples")
            let qos = onEngine(engineApp) { Thread.current.qualityOfService }
            t.equal(qos, .userInitiated)
            t.equal(onEngine(engineApp) { SkinThreadExecutor.isSkinThread }, true, "marked as a skin thread")
            let thread = engineApp.engineThread
            engineApp.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { thread?.hasExited == true }, "and it ends when asked")
        }

        t.suite("App: engine thread: debug builds stop a skin thread that would wait for the main thread") {
            #if DEBUG
            let violations = Guarded<[String]>([])
            let saved = SkinThreadExecutor.waitViolation
            SkinThreadExecutor.waitViolation = { what in violations.access { $0.append(what) } }
            defer { SkinThreadExecutor.waitViolation = saved }
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            defer { app.endEngineThread() }
            _ = app.skinExecutor("Any\\Config")
            let published = MainPublished<Int>(maxAge: 60, initial: -1) { 7 }
            // A read on the skin thread takes what was published, without asking the main thread to wait.
            t.equal(onEngine(app) { published.value() }, -1, "nothing published yet: the initial value")
            t.equal(violations.current, [], "reading is fine")
            t.check(AppSelfTest.spin(timeout: 30) { published.lastPublished == 7 }, "the main thread worked it out later")
            t.equal(onEngine(app) { published.value() }, 7)
            // Working it out there, or running the media centres' main-thread work there, is not.
            _ = onEngine(app) { published.refresh() }
            t.equal(violations.current.count, 1, "refresh on a skin thread: \(violations.current)")
            let inline = MediaUIMainHop.runsInline
            MediaUIMainHop.runsInline = true
            _ = onEngine(app) { MediaUIMainHop.run {} }
            MediaUIMainHop.runsInline = inline
            t.equal(violations.current.count, 2, "a main-thread hop run inline on a skin thread: \(violations.current)")
            _ = onEngine(app) { MediaUIMainHop.run {} }
            t.equal(violations.current.count, 2, "queued to the main thread: fine")
            // The main thread may do all of it.
            published.refresh()
            MediaUIMainHop.run {}
            t.equal(violations.current.count, 2)
            #else
            print("    (skipped: the checks exist in debug builds only)")
            #endif
        }
    }

    // MARK: Load, refresh, unload, quit

    static func lifeTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: skins load, refresh, unload and quit on the one engine thread") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            let closing = { (name: String) in """
                [Rainmeter]
                Update=50
                OnRefreshAction=[!SetVariable Loaded 1]
                OnCloseAction=[!CommandMeasure MeasureScript "Append('\(name)')" "Engine\\Collector"]

                [Variables]
                Loaded=0

                [MeasureCounter]
                Measure=Calc
                Formula=Counter

                """ + box
            }
            try write(app, ["Collector": collector, "A": closing("A"), "B": closing("B")])
            for (order, name) in ["Collector", "A", "B"].enumerated() {
                app.state.update("Engine\\\(name)") {
                    $0.file = "\(name).ini"
                    $0.loadOrder = order + 1
                }
            }
            t.check(app.engineThread == nil, "no engine thread before the first skin")
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                let loaded = ["Collector", "A", "B"].compactMap { app.activate(config: "Engine\\\($0)", file: nil) }
                t.equal(loaded.count, 3, "each window is made at once")
                tracked += loaded.map(track)
                guard let engine = app.engineThread else { return t.check(false, "the engine thread") }
                t.check(loaded.allSatisfy { $0.runtime.executor === engine }, "every skin on the engine thread")
                t.check(AppSelfTest.spin(timeout: 60) { loaded.allSatisfy(\.isStarted) }, "all started")
                t.check(loaded.allSatisfy { app.controller(for: $0.config) === $0 })
                let (collector, a, b) = (loaded[0], loaded[1], loaded[2])
                t.equal(a.runtime.exclusive(timeout: 30) { $0.variable("Loaded") }, "1", "OnRefreshAction ran")
                // Exclusive access to one skin of the thread parks the thread: every skin on it is the caller's then.
                let both = a.runtime.exclusive(timeout: 30) { _ -> Bool in
                    engine.isCurrent && b.runtime.exclusive(timeout: 0) { _ in true } == true
                }
                t.equal(both, true, "one park holds every skin of the thread")

                // Refresh from the app (the menu), then from the skin itself ([!Refresh] on the thread).
                let before = a.runtime.exclusive(timeout: 30) { $0.counter } ?? -1
                app.refresh(a)
                guard let a2 = app.controller(for: "Engine\\A"), a2 !== a else { return t.check(false, "a new window") }
                tracked.append(track(a2))
                t.check(AppSelfTest.spin(timeout: 60) { a2.isStarted && a.runtime.didClose }, "refreshed")
                t.check(a2.runtime.executor === engine, "on the same thread")
                t.check((a2.runtime.exclusive(timeout: 30) { $0.counter } ?? 0) > before, "its counter went on")
                a2.runtime.send(.execute("[!Refresh]", section: nil))
                t.check(AppSelfTest.spin(timeout: 60) {
                    guard let a3 = app.controller(for: "Engine\\A") else { return false }
                    return a3 !== a2 && a3.isStarted
                }, "a skin's own !Refresh reloads it on the thread")
                if let a3 = app.controller(for: "Engine\\A") { tracked.append(track(a3)) }

                // Unload.
                app.deactivate(config: "Engine\\B")
                t.check(AppSelfTest.spin(timeout: 60) { b.runtime.didClose }, "unloaded")
                t.check(app.controller(for: "Engine\\B") == nil)
                t.equal(app.state.skin("Engine\\B")?.active, false)
                t.equal(collector.runtime.exclusive(timeout: 30) { $0.variable("Log") }, "A;A;B;",
                        "every OnCloseAction ran: two refreshes of A, then B")

                // Quit: the rest close in reverse load order, within the budget.
                let start = Date()
                let late = app.stopAllForTermination()
                t.equal(late, [], "every skin closed in time")
                t.check(Date().timeIntervalSince(start) < AppController.terminationBudget)
                t.check(app.sortedControllers.allSatisfy { $0.runtime.didClose }, "all closed")
                t.equal(collector.runtime.exclusive(timeout: 30) { $0.variable("Log") }, "A;A;B;A;",
                        "A closed before the collector it reports to")
                t.equal(app.state.skin("Engine\\A")?.active, true, "kept for the next launch")
            }
            let engine = app.engineThread
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { engine?.hasExited == true }, "the engine thread ends")
            _ = tracked
        }

        t.suite("App: engine thread: the first-run layout loads onto the engine thread at its places") {
            let source = t.temporaryDirectory("engine-first-run")
            let widget = "[Rainmeter]\nUpdate=-1\n\n[MeterBox]\nMeter=Shape\n"
                + "Shape=Rectangle 0,0,100,40 | Fill Color 30,30,40,255 | StrokeWidth 0\n"
            let files = [
                "Stationery/Clock/Small.ini": widget, "Stationery/Weather/Medium.ini": widget,
                "FirstRun.ini": "[Stationery\\Clock]\nFile=Small.ini\nX=20\nY=20\n"
                    + "[Stationery\\Weather]\nFile=Medium.ini\nX=20\nY=210\n",
            ]
            for (path, text) in files {
                let url = source.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let root = t.temporaryDirectory("engine-first-run-app")
            let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                    skinsDirectory: root.appendingPathComponent("Skins"),
                                    layoutsDirectory: root.appendingPathComponent("Layouts"),
                                    backupsDirectory: root.appendingPathComponent("Backups"),
                                    defaultSkinsSource: source, settingsDirectory: root, presentsWindows: false,
                                    threading: .engine)
            keptApps.append(app)
            try FileManager.default.createDirectory(at: app.skinsDirectory, withIntermediateDirectories: true)
            app.installDefaultSkinsIfNeeded()
            var loadedAll = 0
            app.loadActiveSkins { loadedAll += 1 }
            let clock = app.controller(for: "Stationery\\Clock")
            t.check(clock != nil && app.controller(for: "Stationery\\Weather") == nil,
                    "the first window is made at once, the next once it started (activateInOrder)")
            t.check(AppSelfTest.spin(timeout: 60) {
                clock?.isStarted == true && app.controller(for: "Stationery\\Weather")?.isStarted == true
            }, "both start on the engine thread")
            let weather = app.controller(for: "Stationery\\Weather")
            t.check(AppSelfTest.spin(timeout: 30) { loadedAll == 1 }, "then the launch goes on, once")
            let screens = WindowGeometry.currentScreens()
            let visible = screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
            let height = WindowGeometry.primaryHeight(screens)
            if let clock, let weather {
                t.check(clock.runtime.executor === app.engineThread)
                t.close(clock.topLeftPosition.x, Double(visible.minX) + 20, accuracy: 0.5, "the move made before the start")
                t.close(clock.topLeftPosition.y, Double(height - visible.maxY) + 20, accuracy: 0.5)
                t.close(weather.topLeftPosition.y, Double(height - visible.maxY) + 210, accuracy: 0.5)
                t.equal(clock.window.frame.size, NSSize(width: 100, height: 40), "at the skin's size")
                t.equal(app.state.skin("Stationery\\Weather")?.y, weather.topLeftPosition.y, "saved like a drag")
            }
            let engine = app.engineThread
            app.stopAllForTermination()
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { engine?.hasExited == true })
        }
    }

    // MARK: Loading one after another

    static func orderTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: the session's skins load one after another, as on the main thread") {
            // Dock unloads its Menu when it loads (Enigma's Dock does); the Menu comes after it in the load order, so
            // on the main thread it was not loaded yet and loads after. On the engine thread, a skin whose file went
            // missing fails and the loads go on; so do they after a skin that unloads itself before it started.
            let dock = """
                [Rainmeter]
                Update=-1
                OnRefreshAction=[!DeactivateConfig "Engine\\Menu"]

                """ + box
            let gone = "[Rainmeter]\nUpdate=-1\nOnRefreshAction=[!DeactivateConfig]\n\n" + box
            for threading in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return }
                try write(app, ["Dock": dock, "Menu": plain, "Broken": plain, "Gone": gone, "Last": plain])
                for (order, name) in ["Dock", "Broken", "Gone", "Menu", "Last"].enumerated() {
                    app.state.update("Engine\\\(name)") {
                        $0.file = "\(name).ini"
                        $0.loadOrder = order + 1
                    }
                }
                var tracked: [() -> Skin?] = []
                var finished = 0
                autoreleasepool {
                    let gate = SkinLifecycleSelfTests.Gate()
                    if let engine = threading == .engine ? app.skinExecutor("Engine\\Dock") : nil {
                        // Held until Broken's file is gone: its window is made (the file was there), its load fails.
                        gate.hold(engine)
                    }
                    app.loadActiveSkins { finished += 1 }
                    if threading == .engine {
                        t.equal(app.sortedControllers.map(\.config), ["Engine\\Dock"], "one window at a time")
                        try? FileManager.default.removeItem(at: app.skinsDirectory
                            .appendingPathComponent("Engine/Broken/Broken.ini"))
                        gate.open()
                    }
                    tracked = app.sortedControllers.map(track)
                    t.check(AppSelfTest.spin(timeout: 60) { finished == 1 }, "\(threading): every load settled")
                    // Gone's !DeactivateConfig of itself runs on a later turn (`AppController.later`), in both modes.
                    t.check(AppSelfTest.spin(timeout: 60) { app.controller(for: "Engine\\Gone") == nil },
                            "\(threading): the skin that unloads itself is gone")
                    t.equal(finished, 1)
                    let running = app.sortedControllers.filter(\.isStarted).map(\.config)
                    t.equal(running, threading == .engine ? ["Engine\\Dock", "Engine\\Menu", "Engine\\Last"]
                                                          : ["Engine\\Dock", "Engine\\Broken", "Engine\\Menu",
                                                             "Engine\\Last"],
                            "\(threading): the Menu loaded after the Dock, as on the main thread")
                    tracked += app.sortedControllers.map(track)
                }
                if threading == .engine {
                    finish(t, app, tracked)
                } else {
                    app.stopAllForTermination()
                }
            }
        }
    }

    // MARK: Frames

    static func frameTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: frames reach the content layer while the main thread is blocked") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try write(app, ["Ticker": ticker, "Other": ticker])
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let c = app.activate(config: "Engine\\Ticker", file: nil),
                      let other = app.activate(config: "Engine\\Other", file: nil) else { return t.check(false, "load") }
                tracked = [track(c), track(other)]
                t.check(AppSelfTest.spin(timeout: 60) { c.isStarted && other.isStarted }, "started")
                t.equal(c.content.state.presented, 0, "headless: never shown, never drawn")
                c.visibilityForTesting = true
                other.visibilityForTesting = true
                t.check(AppSelfTest.spin(timeout: 60) {
                    c.content.state.presented >= 1 && other.content.state.presented >= 1
                }, "shown (in the facts): frames arrive")
                let before = (c.content.state.presented, other.content.state.presented)
                let updates = c.runtime.snapshot.updateCount
                // The main thread does not turn its run loop: at least half a second, and until three more frames of
                // each skin have arrived (a minute at most, which only tells "late" from "never").
                let start = ProcessInfo.processInfo.systemUptime
                func elapsed() -> TimeInterval { ProcessInfo.processInfo.systemUptime - start }
                func enough() -> Bool {
                    c.content.state.presented >= before.0 + 3 && other.content.state.presented >= before.1 + 3
                }
                while (elapsed() < 0.5 || !enough()) && elapsed() < 60 { usleep(1000) }
                let blocked = elapsed()
                t.check(enough(), "frames kept arriving while the main thread was blocked for \(blocked) s: "
                        + "\(c.content.state.presented - before.0) and \(other.content.state.presented - before.1)")
                t.check(c.runtime.snapshot.updateCount > updates, "the skin updated meanwhile")
                let shown = c.content.shown
                t.check(shown.image != nil && shown.isAttached, "the layer shows a picture")
                t.equal(shown.bounds.size, c.runtime.snapshot.size, "at the skin's size")

                // Hidden (in the facts): nothing more is drawn; shown again: a frame.
                c.visibilityForTesting = false
                _ = c.runtime.exclusive(timeout: 30) { _ in true }
                let hidden = c.content.state.presented
                let updated = c.runtime.snapshot.updateCount
                t.check(AppSelfTest.spin(timeout: 60) { c.runtime.snapshot.updateCount >= updated + 3 }, "it updates")
                t.equal(c.content.state.presented, hidden, "a window that cannot be seen draws nothing")
                c.visibilityForTesting = true
                t.check(AppSelfTest.spin(timeout: 60) { c.content.state.presented > hidden }, "seen again: drawn")
                app.deactivate(config: "Engine\\Ticker")
                app.deactivate(config: "Engine\\Other")
                t.check(AppSelfTest.spin(timeout: 30) { c.content.state.tornDown }, "the layer goes with the window")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: Mouse, hover, wheel, focus, tooltips, cursor

    static func inputTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: the mouse, hover, the wheel and focus are messages; tooltips and the cursor come from the snapshot") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try write(app, ["Input": inputSkin])
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let c = app.activate(config: "Engine\\Input", file: nil), let engine = app.engineThread else {
                    return t.check(false, "loads")
                }
                tracked = [track(c)]
                t.check(AppSelfTest.spin(timeout: 60) { c.isStarted }, "started")
                // The window at the screen's origin: a wheel event without a window is where the view expects it.
                c.window.setFrameOrigin(.zero)
                let seen = Guarded<[String]>([])
                let places = Guarded<[Bool]>([])
                _ = c.runtime.exclusive(timeout: 30) { _ in
                    c.runtime.messageObserver = { message in
                        seen.access { $0.append(kind(message)) }
                        places.access { $0.append(engine.isCurrent) }
                    }
                }
                func variable(_ name: String, timeout: TimeInterval = 30) -> String? {
                    c.runtime.exclusive(timeout: timeout) { $0.variable(name) } ?? nil
                }
                t.equal(c.runtime.send(.redraw), nil, "a message from the main thread is queued, not run at once")

                // A click through the view: whether it may drag comes from the snapshot, the action runs on the thread.
                let view = c.view
                if let down = AppSelfTest.mouseEvent(.leftMouseDown, c, x: 20, y: 20),
                   let up = AppSelfTest.mouseEvent(.leftMouseUp, c, x: 20, y: 20) {
                    view.mouseDown(with: down)
                    t.check(!view.dragAllowed, "a meter with a LeftMouseDownAction does not drag (the snapshot says)")
                    view.mouseUp(with: up)
                }
                t.check(AppSelfTest.spin(timeout: 30) { variable("Down") == "1" && variable("Up") == "1" },
                        "both actions ran")

                // Hover and leave; the cursor over the actions at once.
                if let moved = AppSelfTest.mouseEvent(.mouseMoved, c, x: 20, y: 20) { view.mouseMoved(with: moved) }
                t.equal(view.cursorName, "TEXT", "the cursor, from the snapshot")
                t.check(AppSelfTest.spin(timeout: 30) { variable("Over") == "1" }, "MouseOverAction ran")
                // (AppKit makes enter and exit events itself; the view reads only where the pointer was.)
                if let exited = AppSelfTest.mouseEvent(.mouseMoved, c, x: 200, y: 200) { view.mouseExited(with: exited) }
                t.equal(view.cursorName, nil, "the arrow again")
                t.check(AppSelfTest.spin(timeout: 30) { variable("Over") == "0" }, "MouseLeaveAction ran")

                // The wheel.
                if let wheel = scrollEvent(c, x: 20, y: 20) {
                    view.scrollWheel(with: wheel)
                    t.check(AppSelfTest.spin(timeout: 30) { variable("Scrolled") == "1" }, "MouseScrollUpAction ran")
                } else {
                    t.check(false, "a wheel event")
                }

                // Focus.
                t.check(c.wantsFocus, "OnFocusAction: the panel may become key (the snapshot says)")
                t.check(view.needsPanelToBecomeKey)
                c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: c.window))
                t.check(AppSelfTest.spin(timeout: 30) { variable("Focus") == "1" }, "OnFocusAction ran")
                c.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: c.window))
                t.check(AppSelfTest.spin(timeout: 30) { variable("Focus") == "0" }, "OnUnfocusAction ran")

                // Tooltips: the areas and the text from the snapshot, following the skin.
                view.updateToolTips()
                t.equal(view.toolTipRects.count, 1, "one tooltip area")
                t.equal(view.toolTipText(x: 20, y: 20), "first")
                c.runtime.send(.execute("[!SetVariable Tip second][!UpdateMeter MeterBox]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { view.toolTipText(x: 20, y: 20) == "second" },
                        "the tooltip follows once the skin published its work")

                // While the thread is busy, the window still answers at once, and its events wait their turn.
                c.runtime.send(.execute("[!SetVariable Down 0][!SetVariable Up 0]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { variable("Down") == "0" && variable("Up") == "0" })
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(engine)
                let start = ProcessInfo.processInfo.systemUptime
                t.equal(SkinView.cursorName(c, x: 20, y: 20), "TEXT")
                t.equal(view.toolTipText(x: 20, y: 20), "second")
                t.check(SkinView.hasAction(c, .leftUp, x: 20, y: 20), "the click would be taken")
                if let down = AppSelfTest.mouseEvent(.leftMouseDown, c, x: 20, y: 20),
                   let up = AppSelfTest.mouseEvent(.leftMouseUp, c, x: 20, y: 20) {
                    view.mouseDown(with: down)
                    view.mouseUp(with: up)
                }
                let waited = ProcessInfo.processInfo.systemUptime - start
                t.check(waited < 5, "answered without waiting for the busy thread: \(waited) s")
                t.equal(variable("Down", timeout: 0.05), nil, "the thread is still busy: no answer within the timeout")
                gate.open()
                t.check(AppSelfTest.spin(timeout: 30) { variable("Down") == "1" && variable("Up") == "1" },
                        "the click ran once the thread went on")
                _ = c.runtime.exclusive(timeout: 30) { _ in c.runtime.messageObserver = nil }
                let kinds = Set(seen.current)
                for expected in ["mouse", "pointer", "hover", "exited", "scroll", "focus", "execute", "redraw"] {
                    t.check(kinds.contains(expected), "\(expected) arrived as a message: \(kinds.sorted())")
                }
                t.check(!places.current.isEmpty && places.current.allSatisfy { $0 }, "every one ran on the engine thread")
                app.deactivate(config: "Engine\\Input")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: Window bangs and the environment

    static func windowTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: window bangs change the skin's model at once, the window follows, the environment agrees") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            EnvironmentStore.shared.publish()
            try SkinWindowModelSelfTests.write(app, ["EngineMover": SkinWindowModelSelfTests.moverSkin])
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let c = app.activate(config: "Model\\EngineMover", file: nil) else { return t.check(false, "loads") }
                tracked = [track(c)]
                let r = c.runtime
                t.check(r.executor === app.engineThread, "on the engine thread")
                t.check(SkinWindowModelSelfTests.settled(c), "the window takes the skin's size, the model follows")
                let screens = EnvironmentStore.shared.currentScreens
                let ph = WindowGeometry.primaryHeight(screens)
                let size = c.window.frame.size
                let before = c.window.frame
                let expected = WindowGeometry.keptOnScreen(
                    WindowGeometry.frame(topLeftX: -5000, y: -5000, size: size, primaryHeight: ph), screens: screens)
                let p = WindowGeometry.topLeft(of: expected, primaryHeight: ph)
                r.send(.execute("[!Move -5000 -5000][!SetVariable Seen \"#CURRENTCONFIGX#,#CURRENTCONFIGY#\"]",
                                section: nil))
                let seen = r.exclusive(timeout: 30) { skin in (skin.variable("Seen"), r.model.frame) }
                t.equal(seen?.0, "\(Int(p.x)),\(Int(p.y))", "the skin read where its bang put the window")
                t.equal(seen?.1, expected, "its model has the clamped frame")
                t.equal(c.window.frame, before, "the window has not moved yet")
                t.check(AppSelfTest.spin(timeout: 30) { SkinWindowModelSelfTests.agrees(c) && c.window.frame == expected },
                        "then the window moves there and tells the model")

                r.send(.execute("[!ZPos 1][!SetTransparency 128][!Draggable 0][!Hide]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) {
                    SkinWindowModelSelfTests.agrees(c) && c.isHiddenByBang && app.state.skin("Model\\EngineMover")?.alwaysOnTop == 1
                }, "the main thread follows the window bangs")
                t.equal(c.window.level, .floating)
                t.equal(app.state.skin("Model\\EngineMover")?.alphaValue, 128)
                t.equal(app.state.skin("Model\\EngineMover")?.draggable, false)
                r.send(.execute("[!Show][!Draggable 1]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { !c.isHiddenByBang && SkinWindowModelSelfTests.agrees(c) }, "!Show")

                // The environment the skin reads on the thread is the one the main thread gives for its window.
                c.moveTo(x: 120, y: 140)
                t.check(AppSelfTest.spin(timeout: 30) { SkinWindowModelSelfTests.agrees(c) }, "the model follows a move")
                let onThread = onEngine(app) { r.environment(for: r.skin) }
                t.equal(onThread, c.environment, "the environment, as the main thread sees the window")
                r.send(.execute("[!SetVariable Seen \"#CURRENTCONFIGX#,#CURRENTCONFIGY#,#SCREENAREAWIDTH#\"]", section: nil))
                let width = Int(screens.first?.frame.width ?? 0)
                t.equal(r.exclusive(timeout: 30) { $0.variable("Seen") }, "120,140,\(width)")
                app.deactivate(config: "Model\\EngineMover")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: Bangs between skins

    static func bangTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: bangs between skins run at once on the shared thread, and the 17th hop is dropped") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            // A ring of nine skins, each updating the next after its own update while armed. Every skin of it updates
            // at most twice in the chain, within the engine's two nested updates, so the hop limit is what stops it.
            let names = (1...9).map { "Ring\($0)" }
            var skins: [String: String] = [:]
            for (i, name) in names.enumerated() {
                skins[name] = SkinWindowModelSelfTests.pingSkin("Engine\\\(names[(i + 1) % names.count])")
            }
            try write(app, skins)
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                let ring = names.compactMap { app.activate(config: "Engine\\\($0)", file: nil) }
                guard ring.count == names.count else { return t.check(false, "load") }
                tracked = ring.map(track)
                t.check(AppSelfTest.spin(timeout: 60) { ring.allSatisfy(\.isStarted) }, "started")
                let (a, b) = (ring[0], ring[1])
                // In one piece of the thread's work: B has the variable before A's action returns.
                let right = onEngine(app) { () -> String? in
                    a.runtime.send(.execute("[!SetVariable Log sync \"Engine\\Ring2\"]", section: nil))
                    return b.runtime.skin.variable("Log")
                }
                t.equal(right ?? nil, "sync", "delivered at once, not queued")
                let action = (1...50).map { "[!SetVariable Log \($0) \"Engine\\Ring2\"]" }.joined()
                let last = onEngine(app) { () -> String? in
                    a.runtime.send(.execute(action, section: nil))
                    return b.runtime.skin.variable("Log")
                }
                t.equal(last ?? nil, "50", "fifty, in order")

                for c in ring { c.runtime.send(.execute("[!SetVariable Armed 1]", section: nil)) }
                for round in 1...2 {
                    let counts = onEngine(app) { () -> ([Int], [Int], [Int]) in
                        let before = ring.map { $0.runtime.skin.updateCount }
                        a.runtime.send(.update(hops: 0))
                        return (zip(ring, before).map { $0.runtime.skin.updateCount - $1 },
                                ring.map(\.runtime.droppedHops), ring.map(\.runtime.hopLimitLogs))
                    }
                    t.equal(counts?.0, [2, 2, 2, 2, 2, 2, 2, 2, 1],
                            "round \(round): hops 0 … 16, all within the one piece of work")
                    t.equal(counts?.1, [0, 0, 0, 0, 0, 0, 0, round, 0], "the 17th hop (from Ring8) is dropped")
                    t.equal(counts?.2, [0, 0, 0, 0, 0, 0, 0, 1, 0], "and logged once")
                }
                for c in ring { c.runtime.send(.execute("[!SetVariable Armed 0]", section: nil)) }
                for name in names { app.deactivate(config: "Engine\\\(name)") }
            }
            finish(t, app, tracked)
        }
    }

    // MARK: FrostedGlass and InputText

    static func companionTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: FrostedGlass and InputText get their windows from the main thread") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try write(app, ["Glass": """
                [Rainmeter]
                Update=-1

                [MeasureGlass]
                Measure=Plugin
                Plugin=FrostedGlass
                Type=Acrylic
                Corner=Round

                """ + box, "Input": """
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

                """ + box])
            let fake = MediaUITests.FakePrompt()
            SkinWindowCompanions.inputTextPromptFactory = { _ in fake }
            defer { SkinWindowCompanions.inputTextPromptFactory = nil }
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let glass = app.activate(config: "Engine\\Glass", file: nil),
                      let input = app.activate(config: "Engine\\Input", file: nil), let engine = app.engineThread
                else { return t.check(false, "load") }
                tracked = [track(glass), track(input)]
                t.check(AppSelfTest.spin(timeout: 60) {
                    glass.isStarted && FrostedGlassBackdrop.backdrop(for: glass) != nil
                        && glass.contentView.layer?.cornerRadius == 8
                }, "the backdrop and the rounding come from the skin's request")
                t.check(FrostedGlassBackdrop.backdrop(for: glass)?.followedWindow === glass.window, "behind its window")
                glass.runtime.send(.execute("[!CommandMeasure MeasureGlass DisableCorner]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { glass.contentView.layer?.cornerRadius == 0 }, "a new style arrives")

                t.check(AppSelfTest.spin(timeout: 60) { input.isStarted }, "started")
                let answered = Guarded<[Bool]>([])
                _ = input.runtime.exclusive(timeout: 30) { _ in
                    input.runtime.messageObserver = { message in
                        if case .inputTextAnswered = message { answered.access { $0.append(engine.isCurrent) } }
                    }
                }
                input.runtime.send(.execute(#"[!CommandMeasure MeasureInput "ExecuteBatch 1"]"#, section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { fake.shown.count == 1 }, "the window shows the box")
                t.equal(fake.shown.first?.defaultValue, "old", "with the settings the skin worked out")
                fake.answer("typed on main")
                t.check(AppSelfTest.spin(timeout: 30) {
                    input.runtime.exclusive(timeout: 30) { $0.variable("Note") } == "typed on main"
                }, "the command ran with what was typed")
                t.equal(answered.current, [true], "the answer came back to the engine thread")
                _ = input.runtime.exclusive(timeout: 30) { _ in input.runtime.messageObserver = nil }
                app.deactivate(config: "Engine\\Glass")
                app.deactivate(config: "Engine\\Input")
                t.check(FrostedGlassBackdrop.backdrop(for: glass) == nil, "the backdrop goes with the window")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: The context menu

    static func menuTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: a skin's menu falls back on its snapshot while another skin keeps the thread busy") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try write(app, ["Busy": """
                [Rainmeter]
                Update=-1

                [MeasureScript]
                Measure=Script
                ScriptFile=#@#Engine.lua

                """ + box, "Menu": """
                [Rainmeter]
                Update=-1
                ContextTitle=Count [MeasureCount]
                ContextAction=[!SetVariable Chosen yes]

                [Metadata]
                Name=Quiet Widget

                [Variables]
                Chosen=no

                [MeasureCount]
                Measure=Calc
                Formula=Counter

                """ + box])
            let limits = (LuaSupport.secondsLimit, LuaSupport.instructionLimit)
            LuaSupport.secondsLimit = 30
            LuaSupport.instructionLimit = 50_000_000_000
            defer { (LuaSupport.secondsLimit, LuaSupport.instructionLimit) = limits }
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let busy = app.activate(config: "Engine\\Busy", file: nil),
                      let c = app.activate(config: "Engine\\Menu", file: nil), let engine = app.engineThread
                else { return t.check(false, "load") }
                tracked = [track(busy), track(c)]
                t.check(AppSelfTest.spin(timeout: 60) { busy.isStarted && c.isStarted }, "started")
                for _ in 0..<3 { c.runtime.send(.update(hops: 0)) }
                _ = c.runtime.exclusive(timeout: 30) { _ in true }
                let stale = c.runtime.snapshot.contextItems.map(\.title)
                t.check(stale.count == 1 && stale.first?.hasPrefix("Count ") == true, "the snapshot has the items: \(stale)")
                let stalling = Guarded(false)
                _ = busy.runtime.exclusive(timeout: 30) { _ in
                    busy.runtime.messageObserver = { message in
                        if case .execute(let action, _) = message, action.contains("Stall") { stalling.access { $0 = true } }
                    }
                }
                // The other skin's two-second Lua call holds the shared thread.
                c.runtime.send(.update(hops: 0))
                busy.runtime.send(.execute(#"[!CommandMeasure MeasureScript "Stall(2)"]"#, section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { stalling.current }, "the call starts")
                let start = Date()
                let facts = app.menuFacts(for: c)
                let menu = app.skinMenu(for: c, includeCustomItems: true)
                let waited = Date().timeIntervalSince(start)
                t.check(!facts.isLive, "the thread is busy: the snapshot's items")
                t.equal(facts.items.map(\.title), stale)
                t.equal(facts.name, "Quiet Widget")
                t.check(menu.items.contains { $0.title == stale.first }, "in the skin menu")
                t.check(waited < 1.5, "without waiting for the thread: \(waited) s")

                _ = c.runtime.exclusive(timeout: 30) { _ in true }
                let live = app.menuFacts(for: c)
                t.check(live.isLive, "read from the skin once the thread is free")
                t.equal(live.items.first?.title, "Count 4", "as it is now")
                guard let item = app.skinMenu(for: c, includeCustomItems: true).items.first(where: {
                    $0.title == "Count 4"
                }) else { return t.check(false, "the item") }
                let chosen = Guarded<[Bool]>([])
                _ = c.runtime.exclusive(timeout: 30) { _ in
                    c.runtime.messageObserver = { message in
                        if case .execute(let action, _) = message, action.contains("Chosen") {
                            chosen.access { $0.append(engine.isCurrent) }
                        }
                    }
                }
                app.customContextAction(item)
                t.check(AppSelfTest.spin(timeout: 30) {
                    c.runtime.exclusive(timeout: 30) { $0.variable("Chosen") } == "yes"
                }, "a chosen item runs")
                t.equal(chosen.current, [true], "on the engine thread")
                for r in [busy.runtime, c.runtime] { _ = r.exclusive(timeout: 30) { _ in r.messageObserver = nil } }
                app.deactivate(config: "Engine\\Busy")
                app.deactivate(config: "Engine\\Menu")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: The Studio

    static func studioTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: the Studio opens once a skin it loaded started, edits on main, and reloads with a ticket") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("Studio/EngineSeeded")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("EngineSeeded.ini")
            try StudioSessionSelfTests.seeded.write(to: url, atomically: true, encoding: .utf8)
            try write(app, ["Plain": plain])
            app.rescanLibrary()
            let config = "Studio\\EngineSeeded"
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let first = app.activate(config: "Engine\\Plain", file: nil), let engine = app.engineThread else {
                    return t.check(false, "the engine thread")
                }
                tracked.append(track(first))
                t.check(AppSelfTest.spin(timeout: 60) { first.isStarted })
                // The thread busy while the skin is loaded and the Studio asked for: it opens once the skin started.
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(engine)
                guard let c = app.activate(config: config, file: "EngineSeeded.ini") else {
                    gate.open()
                    return t.check(false, "the window is made at once")
                }
                tracked.append(track(c))
                t.check(c.isStarting, "the skin waits to load")
                t.check(CodeEditorRouter.openBuiltIn(file: url, line: 3, app: app), "the built-in editor takes the file")
                t.check(app.inspector == nil, "the Studio waits for the skin to start")
                gate.open()
                t.check(AppSelfTest.spin(timeout: 60) { app.inspector?.controller === c }, "then it opens on it")
                guard let editor = app.inspector, let session = editor.session else {
                    return t.check(false, "the editor and its session")
                }
                t.check(c.runtime.executor === engine, "the desktop copy stays on the engine thread")
                t.check(editor.skin?.executor === MainSkinExecutor.shared, "the Studio's own instance runs on main")

                // A step reloads the desktop copy with a ticket; what it writes as it reloads is its own.
                editor.select(section: "MeterTitle")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)],
                              name: "Change Font Size")
                t.check(StudioSessionSelfTests.read(url).contains("FontSize=20\n"), "written")
                t.check(AppSelfTest.spin(timeout: 60) {
                    guard !session.isAwaitingOwnReload, let now = app.controller(for: config) else { return false }
                    return now !== c && now.isStarted
                }, "the reload ends once the old copy closed and the new one started")
                if let now = app.controller(for: config) { tracked.append(track(now)) }
                t.check(app.controller(for: config)?.runtime.executor === engine, "the new copy on the engine thread")
                t.check(!StudioSessionSelfTests.read(url).contains("Seed=0\n"), "the old copy wrote as it closed")
                t.equal(session.buffers.buffer(url)?.text, StudioSessionSelfTests.read(url),
                        "the memory took the widget's own write")
                let toast = editor.toastText
                t.equal(StudioSessionSelfTests.reloads(app, config, during: 1.5), 0, "no reload follows")
                t.equal(editor.toastText, toast, "the step's toast stays")
                t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
                editor.window?.close()
                app.inspector?.window?.close()
                app.deactivate(config: config)
                app.deactivate(config: "Engine\\Plain")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: Pause, wake, fonts, appearance

    static func systemTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: pause, wake, fonts and appearance reach the skins on the thread") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine),
                  let testSkins = Paths.repositoryFolder("TestSkins") else { return }
            try FileManager.default.copyItem(at: testSkins.appendingPathComponent("Mac"),
                                             to: app.skinsDirectory.appendingPathComponent("Mac"))
            try write(app, ["Clock": """
                [Rainmeter]
                Update=20
                OnWakeAction=[!SetVariable Woke (#Woke#+1)]

                [Variables]
                Woke=0

                """ + box])
            app.audioEngine = AudioSelfTests.makeEngine { _ in nil }
            let saved = NSApp.appearance
            t.atSuiteEnd {
                NSApp.appearance = saved
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            NSApp.appearance = NSAppearance(named: .aqua)
            app.observeAppearance()
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let clock = app.activate(config: "Engine\\Clock", file: nil),
                      let look = app.activate(config: "Mac\\Look", file: nil), let engine = app.engineThread
                else { return t.check(false, "load") }
                tracked = [track(clock), track(look)]
                t.check(AppSelfTest.spin(timeout: 60) { clock.isStarted && look.isStarted }, "started")
                let seen = Guarded<[String]>([])
                _ = clock.runtime.exclusive(timeout: 30) { _ in
                    clock.runtime.messageObserver = { message in
                        seen.access { $0.append("\(kind(message)) \(engine.isCurrent)") }
                    }
                }
                func updates() -> Int { clock.runtime.snapshot.updateCount }
                t.check(AppSelfTest.spin(timeout: 30) { updates() >= 3 }, "the clock runs")

                // Asleep: the clock stops; awake: it updates at once and goes on.
                app.simulatePause(systemAsleep: true)
                t.check(AppSelfTest.spin(timeout: 30) {
                    clock.runtime.exclusive(timeout: 30) { _ in clock.runtime.areUpdatesPaused } == true
                }, "paused on the thread")
                let paused = updates()
                // Ten periods of the clock pass on the thread's own timer.
                let marker = Guarded(false)
                engine.async(after: 0.2) { marker.access { $0 = true } }
                t.check(AppSelfTest.spin(timeout: 30) { marker.current })
                _ = clock.runtime.exclusive(timeout: 30) { _ in true }
                t.equal(updates(), paused, "no update while paused")
                app.simulatePause(systemAsleep: false)
                t.check(AppSelfTest.spin(timeout: 30) { updates() >= paused + 2 }, "updating again")

                clock.systemDidWake()
                t.check(AppSelfTest.spin(timeout: 30) {
                    clock.runtime.exclusive(timeout: 30) { $0.variable("Woke") } == "1"
                }, "OnWakeAction ran")

                app.fontsChanged()
                t.check(AppSelfTest.spin(timeout: 30) { seen.current.contains("fonts true") },
                        "the fonts change reached the skin on the thread")
                _ = clock.runtime.exclusive(timeout: 30) { _ in clock.runtime.messageObserver = nil }
                t.check(seen.current.contains("pause true") && seen.current.contains("resume true")
                        && seen.current.contains("wake true"), "pause, resume and wake too: \(Set(seen.current).sorted())")
                t.check(seen.current.allSatisfy { $0.hasSuffix("true") }, "every message on the engine thread")

                // Dark Mode: the skin that uses the appearance variables refreshes itself on the thread.
                let lookSkin = look.runtime.skin
                NSApp.appearance = NSAppearance(named: .darkAqua)
                t.check(AppSelfTest.spin(timeout: 30) {
                    guard let now = app.controller(for: "Mac\\Look"), now.runtime.skin !== lookSkin else { return false }
                    return now.isStarted
                }, "refreshed")
                if let now = app.controller(for: "Mac\\Look") {
                    tracked.append(track(now))
                    t.check(now.runtime.executor === engine, "on the engine thread")
                    t.equal(now.runtime.exclusive(timeout: 30) { $0.variable("MACAPPEARANCE") }, "Dark")
                }
                t.check(app.controller(for: "Engine\\Clock") === clock, "a skin without them is left alone")
                NSApp.appearance = NSAppearance(named: .aqua)
                t.check(AppSelfTest.spin(timeout: 30) {
                    app.controller(for: "Mac\\Look")?.runtime.exclusive(timeout: 30) { $0.variable("MACAPPEARANCE") }
                        == "Light"
                }, "and back")
                if let now = app.controller(for: "Mac\\Look") { tracked.append(track(now)) }
                app.deactivate(config: "Engine\\Clock")
                app.deactivate(config: "Mac\\Look")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: The default suite

    static func defaultSuiteTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: every default widget loads, updates and draws on the engine thread") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine), let source = Paths.defaultSkins else { return }
            try FileManager.default.copyItem(at: source.appendingPathComponent("Stationery"),
                                             to: app.skinsDirectory.appendingPathComponent("Stationery"))
            app.rescanLibrary()
            let configs = app.library.filter { $0.name.hasPrefix("Stationery\\") }
            t.check(configs.count >= 20, "the default suite: \(configs.count) widgets")
            var tracked: [() -> Skin?] = []
            // A skin touched off the engine thread stops a debug build (`Skin.assertOwned`); AppKit called there shows
            // under Main Thread Checker.
            autoreleasepool {
                let loaded = configs.compactMap { app.activate(config: $0.name, file: nil) }
                t.equal(loaded.count, configs.count, "every window is made")
                tracked = loaded.map(track)
                t.check(AppSelfTest.spin(timeout: 120) { loaded.allSatisfy { $0.isStarted || $0.loadFailed } },
                        "every widget started")
                t.equal(loaded.filter(\.loadFailed).map(\.config), [], "none failed")
                t.check(loaded.allSatisfy { $0.runtime.executor === app.engineThread })
                for c in loaded { c.visibilityForTesting = true }
                t.check(AppSelfTest.spin(timeout: 120) { loaded.allSatisfy { $0.content.state.presented >= 1 } },
                        "every widget drew: \(loaded.filter { $0.content.state.presented == 0 }.map(\.config))")
                // A widget of every variant: each config's other files, one after the other, as the menus switch them.
                for entry in configs {
                    for file in entry.files.dropFirst() {
                        guard let c = app.activate(config: entry.name, file: file) else { continue }
                        tracked.append(track(c))
                        c.visibilityForTesting = true
                    }
                }
                let variants = configs.reduce(0) { $0 + $1.files.count }
                print("    default suite: \(configs.count) widgets, \(variants) files")
                t.check(AppSelfTest.spin(timeout: 240) {
                    app.sortedControllers.allSatisfy { ($0.isStarted && $0.content.state.presented >= 1) || $0.loadFailed }
                }, "every variant started and drew")
                t.equal(app.sortedControllers.filter(\.loadFailed).map { "\($0.config)\\\($0.file)" }, [], "none failed")
                let closing = app.sortedControllers
                for c in closing { app.deactivate(config: c.config) }
                t.check(AppSelfTest.spin(timeout: 60) { closing.allSatisfy(\.runtime.didClose) }, "every widget closed")
            }
            finish(t, app, tracked)
        }
    }

    // MARK: Helpers

    /// Apps the suites made themselves, kept as the self-tests keep theirs.
    private static var keptApps: [AppController] = []

    /// The skin of `c`, held weakly: a suite ends by waiting for every skin it made to be let go of on the thread.
    static func track(_ c: SkinWindowController) -> () -> Skin? {
        weak var skin = c.runtime.skin
        return { skin }
    }

    /// Unloads what is still loaded, waits for the suite's skins to be let go of (on the engine thread), and ends the
    /// engine thread.
    static func finish(_ t: AppTestRunner, _ app: AppController, _ skins: [() -> Skin?]) {
        let engine = app.engineThread
        autoreleasepool {
            for c in app.sortedControllers { app.deactivate(config: c.config) }
        }
        t.check(AppSelfTest.spin(timeout: 30) { skins.allSatisfy { $0() == nil } },
                "the skins are let go of: \(skins.filter { $0() != nil }.count) left")
        app.endEngineThread()
        if let engine { t.check(AppSelfTest.spin(timeout: 30) { engine.hasExited }, "the engine thread ends") }
    }

    /// Runs `body` on the app's engine thread as a piece of its work and waits for its answer (the main run loop turns
    /// meanwhile, so the thread's requests are served).
    static func onEngine<T>(_ app: AppController, _ body: @escaping () -> T) -> T? {
        guard let engine = app.engineThread else { return nil }
        let result = Guarded<[T]>([])
        engine.async {
            let value = body()
            result.access { $0.append(value) }
        }
        return AppSelfTest.spin(timeout: 60) { !result.current.isEmpty } ? result.current.first : nil
    }

    /// A wheel notch up at a skin point, for a window at the screen's origin: AppKit reports a wheel event that has no
    /// window in screen coordinates, which are then the window's.
    static func scrollEvent(_ c: SkinWindowController, x: Double, y: Double) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0,
                               wheel3: 0) else { return nil }
        let inWindow = c.view.convert(NSPoint(x: x, y: y), to: nil)
        let onScreen = c.window.convertPoint(toScreen: inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y)
        return NSEvent(cgEvent: cg)
    }

    /// A message's kind, as the tests name it.
    static func kind(_ message: SkinMessage) -> String {
        switch message {
        case .mouse: return "mouse"
        case .pressCancelled: return "pressCancelled"
        case .scroll: return "scroll"
        case .pointer: return "pointer"
        case .outsidePointer: return "outsidePointer"
        case .hover: return "hover"
        case .exited: return "exited"
        case .focus: return "focus"
        case .bang: return "bang"
        case .execute: return "execute"
        case .windowFacts: return "facts"
        case .update: return "update"
        case .redraw: return "redraw"
        case .pause: return "pause"
        case .resume: return "resume"
        case .wake: return "wake"
        case .fontsChanged: return "fonts"
        case .appearanceChanged: return "appearance"
        case .close: return "close"
        default: return "other"
        }
    }

    /// Writes the skins (name → text) as `Engine\Name\Name.ini`, with the script they share
    /// (`Engine\@Resources\Engine.lua`).
    static func write(_ app: AppController, _ skins: [String: String]) throws {
        let resources = app.skinsDirectory.appendingPathComponent("Engine/@Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try SkinLifecycleSelfTests.script.write(to: resources.appendingPathComponent("Engine.lua"), atomically: true,
                                                encoding: .utf8)
        for (name, text) in skins {
            let folder = app.skinsDirectory.appendingPathComponent("Engine/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("\(name).ini"), atomically: true, encoding: .utf8)
        }
        app.rescanLibrary()
    }

    /// A box the skins draw, so their windows have a size.
    static let box = """
        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,120,60 | Fill Color 30,30,40,255 | StrokeWidth 0

        """

    static let plain = "[Rainmeter]\nUpdate=-1\n\n" + box

    /// Collects the names the other skins' OnCloseActions append (`Append`), in `Log`.
    static let collector = """
        [Rainmeter]
        Update=-1

        [Variables]
        Log=

        [MeasureScript]
        Measure=Script
        ScriptFile=#@#Engine.lua

        """ + box

    /// Redraws every 16 ms: a counter in a fixed box.
    static let ticker = """
        [Rainmeter]
        Update=16

        [MeasureCount]
        Measure=Calc
        Formula=Counter

        """ + box + """
        [MeterCount]
        Meter=String
        MeasureName=MeasureCount
        X=4
        Y=4
        W=100
        H=20
        FontSize=10
        FontColor=255,255,255
        AntiAlias=1

        """

    /// A box that takes clicks, hover, the wheel and focus, with a tooltip and a cursor.
    static let inputSkin = """
        [Rainmeter]
        Update=-1
        OnFocusAction=[!SetVariable Focus 1]
        OnUnfocusAction=[!SetVariable Focus 0]

        [Variables]
        Down=0
        Up=0
        Over=0
        Scrolled=0
        Focus=-1
        Tip=first

        [MeterBox]
        Meter=Shape
        Shape=Rectangle 0,0,120,60 | Fill Color 30,30,40,255 | StrokeWidth 0
        LeftMouseDownAction=[!SetVariable Down 1]
        LeftMouseUpAction=[!SetVariable Up 1]
        MouseOverAction=[!SetVariable Over 1]
        MouseLeaveAction=[!SetVariable Over 0]
        MouseScrollUpAction=[!SetVariable Scrolled 1]
        MouseActionCursorName=TEXT
        ToolTipText=#Tip#
        DynamicVariables=1

        """
}
