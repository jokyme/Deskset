import AppKit
import DesksetCore

/// Real controllers and menu actions exercise ordering requests without presenting fixture windows.
enum FocusSelfTests {
    static func run(_ t: AppTestRunner) {
        for threading in [SkinThreading.main, .engine, .pool] {
            t.suite("App: Focus: same variant preserves the instance and settings, \(threading)") {
                guard let app = try fixture(t, threading: threading),
                      let c = load(t, app, "Focus\\A"), let peer = load(t, app, "Focus\\B") else { return }
                var focused: [String] = []
                app.willFocusSkin = { focused.append($0.config) }
                for level in -2...2 {
                    app.changeSettings(of: c) { $0.alwaysOnTop = level; $0.loadOrder = 17 }
                    let state = c.state, peerState = peer.state, frame = c.window.frame
                    let windowLevel = c.window.level, keyWindow = NSApp.keyWindow, active = NSApp.isActive
                    let order = app.sortedControllers.map(\.config)
                    let counter = c.runtime.exclusive { $0.updateCount }
                    let lastLog = Log.recent.last?.id ?? 0
                    app.activateFromBang(config: "focus/a", file: "a.INI", sender: "Focus\\B")
                    t.check(app.controller(for: "Focus\\A") === c && !c.isStopped)
                    t.equal(c.state, state)
                    t.equal(peer.state, peerState)
                    t.equal(c.window.frame, frame)
                    t.equal(c.window.level, windowLevel)
                    t.equal(c.window.level, WindowGeometry.level(forAlwaysOnTop: level))
                    t.equal(app.sortedControllers.map(\.config), order, "focus never changes LoadOrder")
                    t.equal(c.runtime.exclusive { $0.updateCount }, counter, "no reload or update")
                    t.check(NSApp.keyWindow === keyWindow && NSApp.isActive == active, "no app or keyboard activation")
                    t.check(!Log.recent.contains { $0.id > lastLog && $0.level == .warning }, "no already-active warning")
                }
                t.equal(focused, Array(repeating: "Focus\\A", count: 5))
            }

            t.suite("App: Focus: only the matching bang branch focuses, \(threading)") {
                guard let app = try fixture(t, threading: threading), let first = load(t, app, "Focus\\A") else { return }
                var focused: [String] = []
                app.willFocusSkin = { focused.append($0.config) }
                app.activateFromBang(config: "Focus\\A", file: nil, sender: "Focus\\B")
                t.check(AppSelfTest.spin { app.controller(for: "Focus\\A")?.isStarted == true })
                guard let next = app.controller(for: "Focus\\A") else { return t.check(false, "next variant") }
                t.equal(next.file, "Alt.ini")
                t.check(next !== first && first.isStopped, "omitting a file still selects the next variant")
                t.check(focused.isEmpty)
                guard let refreshed = app.refresh(next) else { return t.check(false, "refresh loads") }
                t.check(AppSelfTest.spin { refreshed.isStarted })
                t.check(refreshed !== next && next.isStopped, "Refresh still reloads")
                t.check(focused.isEmpty)
                guard let single = load(t, app, "Focus\\B") else { return }
                app.activateFromBang(config: "Focus\\B", file: nil, sender: "Focus\\A")
                t.check(app.controller(for: "Focus\\B") === single)
                t.equal(focused, ["Focus\\B"], "the sole next variant is focused")
            }

            t.suite("App: Focus: hidden and retired skins stay hidden, \(threading)") {
                guard let app = try fixture(t, threading: threading), let c = load(t, app, "Focus\\A") else { return }
                var requests = 0
                app.willFocusSkin = { _ in requests += 1 }
                c.runtime.send(.execute("[!Hide]", section: nil))
                t.check(AppSelfTest.spin { c.isHiddenByBang })
                let state = c.state, frame = c.window.frame
                app.focusSkin(c)
                app.activateFromBang(config: c.config, file: c.file, sender: "Focus\\B")
                t.equal(requests, 0)
                t.check(c.isHiddenByBang && !c.window.isVisible)
                t.equal(c.state, state)
                t.equal(c.window.frame, frame)
                c.runtime.send(.execute("[!Show]", section: nil))
                t.check(AppSelfTest.spin { !c.isHiddenByBang })
                app.focusSkin(c)
                t.equal(requests, 1, "headless windows use the real hidden flag, not isVisible")
                c.runtime.retireForLayout()
                app.focusSkin(c)
                t.equal(requests, 1, "a layout-retired instance cannot be focused")
            }
        }

        t.suite("App: Focus: pending restack is consumed before focus without losing settings notification") {
            guard let app = try fixture(t), let c = load(t, app, "Focus\\A") else { return }
            var actions: [String] = [], notifications = 0
            app.willRestackSkins = { actions.append("restack") }
            app.willFocusSkin = { _ in actions.append("focus") }
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: .main) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            c.restacksWhenStarted = false
            app.skinStarted(c)
            notifications = 0
            app.windowChangesNeed(restack: true, settingsChanged: true)
            app.focusSkin(c)
            t.equal(actions, ["restack", "focus"])
            drain(t, app)
            t.equal(actions, ["restack", "focus"], "neither deferred restack source undoes the focus")
            t.equal(notifications, 1, "the pending settings notification is preserved")
        }

        t.suite("App: Focus: stale restack A cannot consume a new reservation B") {
            guard let app = try fixture(t), let c = load(t, app, "Focus\\A") else { return }
            var actions: [String] = []
            app.willRestackSkins = { actions.append("restack") }
            app.willFocusSkin = { _ in actions.append("focus") }
            c.restacksWhenStarted = false
            app.skinStarted(c) // A
            app.focusSkin(c)   // consumes A
            app.skinStarted(c) // B, while A's callback still waits
            drain(t, app)
            t.equal(actions, ["restack", "focus", "restack"], "only the current B callback restacks")
            drain(t, app)
            t.equal(actions.count, 3)
        }

        t.suite("App: Focus: a batch consumes its restack but retains its settings change") {
            guard let app = try fixture(t), let c = load(t, app, "Focus\\A") else { return }
            var actions: [String] = [], notifications = 0
            app.willRestackSkins = { actions.append("restack") }
            app.willFocusSkin = { _ in actions.append("focus") }
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: .main) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            app.batchingWindowChanges {
                app.windowChangesNeed(restack: true, settingsChanged: true)
                app.focusSkin(c)
                t.equal(actions, ["restack", "focus"])
                t.equal(notifications, 0)
            }
            t.equal(actions, ["restack", "focus"])
            t.equal(notifications, 1)
        }

        for threading in [SkinThreading.engine, .pool] {
            t.suite("App: Focus: loading waits for the same instance to start, \(threading)") {
                guard let app = try fixture(t, threading: threading) else { return }
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(app.skinExecutor("Focus\\A"))
                defer { gate.open() }
                guard let c = app.activate(config: "Focus\\A", file: "A.ini") else { return t.check(false, "registered") }
                var focused: [SkinWindowController] = []
                app.willFocusSkin = { focused.append($0) }
                app.activateFromBang(config: c.config, file: "A.ini", sender: "Focus\\B")
                t.check(c.isStarting && !c.isStarted)
                t.check(focused.isEmpty)
                gate.open()
                t.check(AppSelfTest.spin { c.isStarted && focused.count == 1 })
                t.check(focused.first === c && app.controller(for: c.config) === c)
            }

            t.suite("App: Focus: an old loading instance cannot focus its replacement, \(threading)") {
                guard let app = try fixture(t, threading: threading) else { return }
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(app.skinExecutor("Focus\\A"))
                defer { gate.open() }
                guard let old = app.activate(config: "Focus\\A", file: "A.ini") else { return t.check(false, "registered") }
                var focused: [String] = []
                app.willFocusSkin = { focused.append($0.file) }
                app.focusSkin(old)
                guard let replacement = app.activate(config: "Focus\\A", file: "Alt.ini") else {
                    return t.check(false, "replacement registered")
                }
                app.focusSkin(old)
                gate.open()
                t.check(AppSelfTest.spin { replacement.isStarted })
                drain(t, app)
                t.check(focused.isEmpty)
                app.focusSkin(replacement)
                t.equal(focused, ["Alt.ini"])
            }

            t.suite("App: Focus: a failed loading instance never performs a deferred focus, \(threading)") {
                guard let app = try fixture(t, threading: threading) else { return }
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(app.skinExecutor("Focus\\A"))
                defer { gate.open() }
                guard let c = app.activate(config: "Focus\\A", file: "A.ini") else { return t.check(false, "registered") }
                var requests = 0
                app.willFocusSkin = { _ in requests += 1 }
                app.focusSkin(c)
                try FileManager.default.removeItem(at: c.fileURL)
                gate.open()
                t.check(AppSelfTest.spin { c.loadFailed })
                app.focusSkin(c)
                t.equal(requests, 0)
                t.check(app.controller(for: c.config) == nil)
            }
        }

        t.suite("App: Focus: native Shift alternate focuses only its current skin instance") {
            guard let app = try fixture(t), let c = load(t, app, "Focus\\A"), let peer = load(t, app, "Focus\\B") else { return }
            CodeEditorRoutingSelfTests.withFakes(CodeEditorRoutingSelfTests.FakeLocator(),
                                                 CodeEditorRoutingSelfTests.RecordingOpener()) {
                app.skinSelection.toggle(c)
                app.skinSelection.toggle(peer)
                var focused: [String] = []
                app.willFocusSkin = { focused.append($0.config) }
                let menu = app.skinMenu(for: c, includeCustomItems: false)
                guard let refreshIndex = menu.items.firstIndex(where: { $0.title == "Refresh Skin" }),
                      menu.items.indices.contains(refreshIndex + 1) else { return t.check(false, "Refresh/Focus pair") }
                let refresh = menu.items[refreshIndex], focus = menu.items[refreshIndex + 1]
                t.equal(focus.title, "Focus Skin")
                t.check(!refresh.isAlternate && focus.isAlternate)
                t.equal(refresh.keyEquivalent, "")
                t.equal(refresh.keyEquivalentModifierMask, [])
                t.equal(focus.keyEquivalent, "", "no Focus keyboard shortcut")
                t.equal(focus.keyEquivalentModifierMask, [.shift])
                t.check(focus.target === app && focus.isEnabled)
                let before = c.state, peerBefore = peer.state
                send(t, focus)
                t.equal(focused, [c.config], "Focus does not infer a new multi-selection operation")
                t.equal(c.state, before)
                t.equal(peer.state, peerBefore)
                t.check(app.controller(for: c.config) === c && app.controller(for: peer.config) === peer)
                app.skinSelection.clear()
                guard let replacement = app.activate(config: c.config, file: "Alt.ini") else {
                    return t.check(false, "replacement")
                }
                t.check(replacement.isStarted)
                send(t, focus)
                t.equal(focused, [c.config], "the old menu cannot focus a new variant")
                let newMenu = app.skinMenu(for: replacement, includeCustomItems: false)
                guard let currentFocus = newMenu.items.first(where: { $0.title == "Focus Skin" }) else {
                    return t.check(false, "new Focus item")
                }
                app.deactivate(config: replacement.config)
                send(t, currentFocus)
                t.equal(focused, [c.config], "an unloaded menu target is ignored")
            }
        }

        t.suite("App: Focus: ordinary native Refresh item still reloads") {
            guard let app = try fixture(t), let c = load(t, app, "Focus\\A") else { return }
            CodeEditorRoutingSelfTests.withFakes(CodeEditorRoutingSelfTests.FakeLocator(),
                                                 CodeEditorRoutingSelfTests.RecordingOpener()) {
                let menu = app.skinMenu(for: c, includeCustomItems: false)
                guard let refresh = menu.items.first(where: { $0.title == "Refresh Skin" }) else {
                    return t.check(false, "Refresh item")
                }
                var focused = 0
                app.willFocusSkin = { _ in focused += 1 }
                send(t, refresh)
                t.check(app.controller(for: c.config) !== c && c.isStopped)
                t.equal(focused, 0)
            }
        }

        t.suite("App: Focus: termination ignores an otherwise current skin") {
            guard let app = try fixture(t), let c = load(t, app, "Focus\\A") else { return }
            var focused = 0
            app.willFocusSkin = { _ in focused += 1 }
            app.stopAllForTermination()
            app.focusSkin(c)
            app.activateFromBang(config: c.config, file: c.file, sender: c.config)
            t.equal(focused, 0)
        }
    }

    private static func fixture(_ t: AppTestRunner, threading: SkinThreading = .main) throws -> AppController? {
        guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return nil }
        t.atSuiteEnd {
            app.willFocusSkin = nil
            app.willRestackSkins = nil
            app.stopAllForTermination()
            app.endEngineThread()
        }
        for (name, files) in [("A", ["A.ini", "Alt.ini"]), ("B", ["B.ini"])] {
            let folder = app.skinsDirectory.appendingPathComponent("Focus/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                try """
                [Rainmeter]
                Update=-1
                [Box]
                Meter=Image
                W=120
                H=60
                SolidColor=40,70,90,255
                """.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        }
        app.rescanLibrary()
        return app
    }

    private static func load(_ t: AppTestRunner, _ app: AppController, _ config: String) -> SkinWindowController? {
        guard let c = app.activate(config: config, file: nil) else { t.check(false, "fixture registered"); return nil }
        guard AppSelfTest.spin(until: { c.isStarted }) else { t.check(false, "fixture started"); return nil }
        return c
    }

    private static func drain(_ t: AppTestRunner, _ app: AppController) {
        var done = false
        app.later { _ in done = true }
        t.check(AppSelfTest.spin { done }, "queued main-thread work completes")
    }

    private static func send(_ t: AppTestRunner, _ item: NSMenuItem) {
        guard let action = item.action else { return t.check(false, "native menu action exists") }
        t.check(NSApp.sendAction(action, to: item.target, from: item), "native menu action is dispatched")
    }
}
