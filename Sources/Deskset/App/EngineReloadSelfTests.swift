import AppKit
import DesksetCore

/// Reloads on the engine thread (docs/skin-threading.md §15, phase 2 review): a skin's bangs never reach another skin
/// before that one has loaded, OnCloseAction's bangs for the app are carried out, skins reloaded together load one
/// after another as on the main thread, and the installer decides once its loads settled. Like the other engine thread
/// suites, these build their app with `.engine`, present no windows and wait for conditions, never for a fixed time; a
/// gate holds the engine thread where a test needs work queued in a given order.
enum EngineReloadSelfTests {
    static func run(_ t: AppTestRunner) {
        loadQueueTests(t)
        closeTests(t)
        orderTests(t)
        installTests(t)
        keptWindowTests(t)
    }

    typealias E = EngineThreadSelfTests

    // MARK: Bangs behind the load

    /// A skin that marks its OnRefreshAction and counts its updates, in a box of a fixed size (no DynamicWindowSize).
    static let marked = """
        [Rainmeter]
        Update=-1
        OnRefreshAction=[!SetVariable Mark 1]

        [Variables]
        Mark=0

        [MeasureCounter]
        Measure=Calc
        Formula=Counter

        """ + E.box

    static func loadQueueTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: a bang from another skin waits for a skin's load, which stays its first update") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try E.write(app, ["A": E.plain, "B": marked])
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let a = app.activate(config: "Engine\\A", file: nil),
                      let b = app.activate(config: "Engine\\B", file: nil), let engine = app.engineThread
                else { return t.check(false, "load") }
                tracked = [E.track(a), E.track(b)]
                t.check(AppSelfTest.spin(timeout: 60) { a.isStarted && b.isStarted }, "started")
                // A's bang for B waits on the thread behind a gate; meanwhile B is refreshed, so the directory lists
                // B's new copy, whose load is queued behind A's bang.
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(engine)
                a.runtime.send(.execute(#"[!Update "Engine\B"]"#, section: nil))
                app.refresh(b)
                guard let b2 = app.controller(for: "Engine\\B"), b2 !== b else {
                    gate.open()
                    return t.check(false, "a new copy")
                }
                tracked.append(E.track(b2))
                t.check(b2.runtime.isLoadQueued, "its load waits in the queue")
                t.check(app.skinDirectory.directory.runtime(for: "Engine\\B") === b2.runtime,
                        "the directory lists the new copy once its load is queued")
                gate.open()
                t.check(AppSelfTest.spin(timeout: 60) { b2.isStarted }, "the new copy started")
                let seen = b2.runtime.exclusive(timeout: 30) { skin in
                    (skin.variable("Mark"), skin.updateCount, skin.width, skin.height)
                }
                t.equal(seen?.0, "1", "its OnRefreshAction ran: its first update was the load's")
                t.equal(seen?.1, 2, "A's !Update came after the load")
                t.equal(seen?.2, 120, "at the skin's size")
                t.equal(seen?.3, 60)
                t.equal(b2.runtime.snapshot.size, CGSize(width: 120, height: 60))
                t.equal(b2.window.frame.size, NSSize(width: 120, height: 60), "and so is its window")
            }
            E.finish(t, app, tracked)
        }
    }

    // MARK: OnCloseAction's bangs for the app

    /// Asks the app for a load, an unload, a refresh and a web page as it closes.
    static let closer = """
        [Rainmeter]
        Update=-1
        OnCloseAction=[!ActivateConfig "Engine\\Target"][!DeactivateConfig "Engine\\Victim"][!Refresh "Engine\\Other"]["https://example.com/closed"]

        """ + E.box

    static func closeTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: OnCloseAction's config bangs and what it opens are carried out, on unload and on refresh") {
            let opened = Guarded<[String]>([])
            SkinWindowController.opensForTesting = { plan in opened.access { $0.append("\(plan)") } }
            defer { SkinWindowController.opensForTesting = nil }
            var outcomes: [SkinThreading: [String]] = [:]
            for threading in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return }
                try E.write(app, ["Closer": closer, "Target": E.plain, "Victim": E.plain, "Other": E.plain])
                var tracked: [() -> Skin?] = []
                var outcome: [String] = []
                autoreleasepool {
                    /// Loads `names`; the ones that failed.
                    func load(_ names: [String]) -> [String] {
                        let loaded = names.compactMap { app.activate(config: "Engine\\\($0)", file: nil) }
                        tracked += loaded.map(E.track)
                        _ = AppSelfTest.spin(timeout: 60) { loaded.allSatisfy { $0.isStarted || $0.loadFailed } }
                        return loaded.filter(\.loadFailed).map(\.config)
                    }
                    func running() -> [String] {
                        app.sortedControllers.filter { $0.isStarted }.map(\.config).sorted()
                    }
                    for step in ["unload", "refresh"] {
                        opened.access { $0 = [] }
                        if let target = app.controller(for: "Engine\\Target") { app.deactivate(target) }
                        let failed = load(["Victim", "Other"] + (app.controller(for: "Engine\\Closer") == nil ? ["Closer"] : []))
                        // Only the runtime is kept here: nothing but the app holds the closing skin's window half.
                        guard let closing = app.controller(for: "Engine\\Closer")?.runtime,
                              let other = app.controller(for: "Engine\\Other") else { return t.check(false, "loaded") }
                        t.equal(failed, [], "\(threading) \(step): loaded")
                        // In a pool of its own, drained at once as the run loop drains it after a turn: AppKit keeps the
                        // window's delegate in the pool while it closes the window.
                        autoreleasepool {
                            if step == "unload" {
                                app.deactivate(config: "Engine\\Closer")
                            } else {
                                if let c = app.controller(for: "Engine\\Closer") { app.refresh(c) }
                                if let now = app.controller(for: "Engine\\Closer") { tracked.append(E.track(now)) }
                            }
                        }
                        let done = AppSelfTest.spin(timeout: 60) {
                            closing.didClose && app.controller(for: "Engine\\Target")?.isStarted == true
                                && app.controller(for: "Engine\\Victim") == nil
                                && app.controller(for: "Engine\\Other").map { $0 !== other && $0.isStarted } == true
                                && !opened.current.isEmpty
                        }
                        t.check(done, "\(threading) \(step): Target loaded, Victim unloaded, Other refreshed, the page "
                                + "opened: \(running()), \(opened.current)")
                        for name in ["Target", "Other"] {
                            if let c = app.controller(for: "Engine\\\(name)") { tracked.append(E.track(c)) }
                        }
                        t.equal(opened.current, ["open(https://example.com/closed)"], "\(threading) \(step): opened once")
                        t.equal(app.state.skin("Engine\\Victim")?.active, false, "\(threading) \(step): Victim inactive")
                        outcome.append("\(step): \(running()) \(opened.current)")
                    }
                }
                outcomes[threading] = outcome
                if threading == .engine {
                    E.finish(t, app, tracked)
                } else {
                    app.stopAllForTermination()
                }
            }
            t.equal(outcomes[.engine], outcomes[.main], "the engine thread does what the main thread does")
        }
    }

    // MARK: Reloads together, one after another

    /// Enigma's Dock unloads its Menu when it loads; A updates B from its OnRefreshAction. Both use the appearance, so
    /// both refresh when it changes (`MacOnAppearanceChangeAction`'s default `[!Refresh]`).
    static func suite(_ app: AppController) throws {
        let dock = """
            [Rainmeter]
            Update=-1
            OnRefreshAction=[!DeactivateConfig "Engine\\Menu"]

            [Variables]
            Look=#MACAPPEARANCE#

            """ + E.box
        let menu = "[Rainmeter]\nUpdate=-1\n\n[Variables]\nLook=#MACAPPEARANCE#\n\n" + E.box
        let a = """
            [Rainmeter]
            Update=-1
            OnRefreshAction=[!Update "Engine\\B"]

            """ + E.box
        try E.write(app, ["Dock": dock, "Menu": menu, "A": a, "B": marked])
        for (order, name) in ["Dock", "Menu", "A", "B"].enumerated() {
            app.state.update("Engine\\\(name)") {
                $0.file = "\(name).ini"
                $0.loadOrder = order + 1
            }
        }
    }

    static func orderTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: Refresh All, !Refresh * and an appearance change reload the skins one after another, as on the main thread") {
            let saved = NSApp.appearance
            t.atSuiteEnd {
                NSApp.appearance = saved
                MacAppearance.current.refresh()
                DesktopInputs.appearance.refresh()
            }
            var outcomes: [SkinThreading: [String]] = [:]
            for threading in [SkinThreading.main, .engine] {
                NSApp.appearance = NSAppearance(named: .aqua)
                guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return }
                try suite(app)
                app.observeAppearance()
                var tracked: [() -> Skin?] = []
                var outcome: [String] = []
                autoreleasepool {
                    var finished = 0
                    app.loadActiveSkins { finished += 1 }
                    t.check(AppSelfTest.spin(timeout: 60) { finished == 1 }, "\(threading): loaded")
                    func state() -> String {
                        let running = app.sortedControllers.filter(\.isStarted).map(\.config)
                        let b = app.controller(for: "Engine\\B")
                        let seen = b?.runtime.exclusive(timeout: 30) { skin in
                            "Mark=\(skin.variable("Mark") ?? "?") \(Int(skin.width))x\(Int(skin.height))"
                        } ?? "no B"
                        return "\(running) \(seen)"
                    }
                    func settled(_ before: [String: SkinWindowController]) -> Bool {
                        app.sortedControllers.allSatisfy { c in c.isStarted && before[c.config] !== c }
                            && !app.sortedControllers.isEmpty
                    }
                    func controllers() -> [String: SkinWindowController] {
                        Dictionary(app.sortedControllers.map { ($0.config, $0) }, uniquingKeysWith: { a, _ in a })
                    }
                    outcome.append("launch: \(state())")
                    for step in ["Refresh All", "!Refresh *", "Dark Mode"] {
                        let before = controllers()
                        tracked += before.values.map(E.track)
                        switch step {
                        case "Refresh All":
                            app.refreshAll(rescan: false)
                        case "!Refresh *":
                            before["Engine\\A"]?.runtime.send(.execute("[!Refresh *]", section: nil))
                        default:
                            NSApp.appearance = NSAppearance(named: .darkAqua)
                        }
                        // Every skin reloads, or with the appearance the ones that use it (the Dock and the Menu).
                        let reloading = step == "Dark Mode" ? ["Engine\\Dock"] : ["Engine\\Dock", "Engine\\A", "Engine\\B"]
                        let done = AppSelfTest.spin(timeout: 60) {
                            let now = controllers()
                            return reloading.allSatisfy {
                                now[$0].map { $0.isStarted && before[$0.config] !== $0 } == true
                            } && (now["Engine\\Menu"].map { $0.isStarted && before["Engine\\Menu"] !== $0 } ?? true)
                        }
                        t.check(done, "\(threading) \(step): reloaded: \(state())")
                        let queued = Guarded(false)
                        app.later { _ in queued.access { $0 = true } }
                        t.check(AppSelfTest.spin(timeout: 60) { queued.current }, "and what they asked for ran")
                        t.check(app.controller(for: "Engine\\Menu")?.isStarted == true,
                                "\(threading) \(step): the Menu stays, as on the main thread: \(state())")
                        t.equal(app.state.skin("Engine\\Menu")?.active, true, "\(threading) \(step): and stays active")
                        outcome.append("\(step): \(state())")
                    }
                    tracked += app.sortedControllers.map(E.track)
                }
                t.equal(outcome.last?.contains("Mark=1 120x60"), true, "\(threading): B's OnRefreshAction ran: \(outcome)")
                outcomes[threading] = outcome
                if threading == .engine {
                    E.finish(t, app, tracked)
                } else {
                    app.stopAllForTermination()
                }
            }
            t.equal(outcomes[.engine], outcomes[.main], "the engine thread does what the main thread does")
        }
    }

    // MARK: The installer

    static func installTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: an installer reloads a suite's skins one after another, as on the main thread") {
            var outcomes: [SkinThreading: String] = [:]
            for threading in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return }
                let dock = "[Rainmeter]\nUpdate=-1\nOnRefreshAction=[!DeactivateConfig \"Suite\\Menu\"]\n\n" + E.box
                let menu = "[Rainmeter]\nUpdate=-1\n\n[Variables]\nVersion=1\n\n" + E.box
                for (name, text) in ["Dock": dock, "Menu": menu] {
                    let folder = app.skinsDirectory.appendingPathComponent("Suite/\(name)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try text.write(to: folder.appendingPathComponent("\(name).ini"), atomically: true, encoding: .utf8)
                }
                app.rescanLibrary()
                for (order, name) in ["Dock", "Menu"].enumerated() {
                    app.state.update("Suite\\\(name)") {
                        $0.file = "\(name).ini"
                        $0.loadOrder = order + 1
                    }
                }
                let package = try AppSelfTest.makePackage(t, name: "Suite.rmskin", files: [
                    "RMSKIN.ini": Data("[rmskin]\nName=Suite\nAuthor=Deskset tests\nVersion=2\nLoadType=Skin\n".utf8),
                    "Skins/Suite/Dock/Dock.ini": Data(dock.utf8),
                    "Skins/Suite/Menu/Menu.ini": Data(menu.replacingOccurrences(of: "Version=1", with: "Version=2").utf8),
                ])
                var tracked: [() -> Skin?] = []
                autoreleasepool {
                    var finished = 0
                    app.loadActiveSkins { finished += 1 }
                    t.check(AppSelfTest.spin(timeout: 60) { finished == 1 }, "\(threading): loaded")
                    t.equal(app.sortedControllers.filter(\.isStarted).map(\.config), ["Suite\\Dock", "Suite\\Menu"])
                    tracked += app.sortedControllers.map(E.track)
                    app.installer.open([package])
                    t.check(AppSelfTest.spin(timeout: 60) {
                        guard app.installer.isIdle, let menu = app.controller(for: "Suite\\Menu") else { return false }
                        return menu.isStarted && menu.runtime.snapshot.updateCount > 0
                    }, "\(threading): installed, and the Menu loaded again after the Dock")
                    let queued = Guarded(false)
                    app.later { _ in queued.access { $0 = true } }
                    t.check(AppSelfTest.spin(timeout: 60) { queued.current }, "and what they asked for ran")
                    let menu = app.controller(for: "Suite\\Menu")
                    t.equal(menu?.runtime.exclusive(timeout: 30) { $0.variable("Version") }, "2", "\(threading): the new Menu")
                    t.equal(app.state.skin("Suite\\Menu")?.active, true, "\(threading): still active")
                    outcomes[threading] = app.sortedControllers.filter(\.isStarted).map(\.config).joined(separator: ", ")
                    tracked += app.sortedControllers.map(E.track)
                }
                if threading == .engine {
                    E.finish(t, app, tracked)
                } else {
                    app.stopAllForTermination()
                }
            }
            t.equal(outcomes[.engine], outcomes[.main], "the engine thread does what the main thread does")
            t.equal(outcomes[.engine], "Suite\\Dock, Suite\\Menu")
        }

        t.suite("App: engine thread: an installer whose package skin cannot be loaded brings back what was running") {
            defer { SkinInstallFlow.beforeLoadingPackageSkin = nil }
            var outcomes: [SkinThreading: String] = [:]
            for threading in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return }
                let folder = app.skinsDirectory.appendingPathComponent("Pkg/Widget", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try E.plain.write(to: folder.appendingPathComponent("Old.ini"), atomically: true, encoding: .utf8)
                app.rescanLibrary()
                let package = try AppSelfTest.makePackage(t, name: "Pkg.rmskin", files: [
                    "RMSKIN.ini": Data("[rmskin]\nName=Pkg\nAuthor=Deskset tests\nVersion=2\nLoadType=Skin\nLoad=Pkg\\Widget\\New.ini\n".utf8),
                    "Skins/Pkg/Widget/New.ini": Data(E.plain.utf8),
                    "Skins/Pkg/Widget/Old.ini": Data(E.plain.utf8),
                ])
                // The package's skin is listed, then its file goes: its load fails, on whichever thread it runs.
                let newFile = folder.appendingPathComponent("New.ini")
                SkinInstallFlow.beforeLoadingPackageSkin = { app in
                    _ = app.library
                    try? FileManager.default.removeItem(at: newFile)
                }
                var tracked: [() -> Skin?] = []
                autoreleasepool {
                    guard let old = app.activate(config: "Pkg\\Widget", file: "Old.ini") else {
                        return t.check(false, "loads")
                    }
                    tracked.append(E.track(old))
                    t.check(AppSelfTest.spin(timeout: 60) { old.isStarted }, "\(threading): started")
                    app.installer.open([package])
                    t.check(AppSelfTest.spin(timeout: 60) {
                        app.installer.isIdle && app.controller(for: "Pkg\\Widget").map { $0 !== old && $0.isStarted } == true
                    }, "\(threading): installed, and a skin of the config runs")
                    let now = app.controller(for: "Pkg\\Widget")
                    if let now { tracked.append(E.track(now)) }
                    t.equal(now?.file, "Old.ini", "\(threading): the one that was running came back")
                    t.equal(app.state.skin("Pkg\\Widget")?.active, true, "\(threading): still active")
                    outcomes[threading] = "\(now?.file ?? "none") \(app.state.skin("Pkg\\Widget")?.active == true)"
                }
                if threading == .engine {
                    E.finish(t, app, tracked)
                } else {
                    app.stopAllForTermination()
                }
            }
            t.equal(outcomes[.engine], outcomes[.main], "the engine thread does what the main thread does")
        }
    }

    // MARK: The replaced window stays until the new copy starts

    static func keptWindowTests(_ t: AppTestRunner) {
        t.suite("App: engine thread: a reload keeps the old window with its last frame until the new copy started") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try E.write(app, ["Kept": E.ticker])
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let c = app.activate(config: "Engine\\Kept", file: nil), let engine = app.engineThread else {
                    return t.check(false, "load")
                }
                tracked.append(E.track(c))
                t.check(AppSelfTest.spin(timeout: 60) { c.isStarted }, "started")
                c.visibilityForTesting = true
                t.check(AppSelfTest.spin(timeout: 60) { c.content.state.presented >= 1 }, "it shows a frame")
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(engine)
                guard let c2 = app.refresh(c) else {
                    gate.open()
                    return t.check(false, "a new copy")
                }
                tracked.append(E.track(c2))
                t.check(c.isStopped && c.isKeptForReplacement, "the old copy is stopped, its window kept")
                t.check(!c.content.state.tornDown && c.content.shown.image != nil, "still showing its last frame")
                // Replaced again before it started: the new copy never showed anything, the old window waits on.
                guard let c3 = app.refresh(c2) else {
                    gate.open()
                    return t.check(false, "a third copy")
                }
                tracked.append(E.track(c3))
                t.check(c2.isStopped && !c2.isKeptForReplacement, "the copy that never started goes at once")
                t.check(c.isKeptForReplacement && !c.content.state.tornDown, "the first window still waits")
                gate.open()
                t.check(AppSelfTest.spin(timeout: 60) { c3.isStarted }, "the last copy started")
                t.check(!c.isKeptForReplacement && c.content.state.tornDown, "then the old window closed")
                t.check(c2.content.state.tornDown)
                app.deactivate(config: "Engine\\Kept")
            }
            E.finish(t, app, tracked)
        }

        t.suite("App: engine thread: a replaced window goes at once on the main thread, and when the new copy fails") {
            guard let main = try AppSelfTest.makeApp(t) else { return }
            try E.write(main, ["Kept": E.plain])
            autoreleasepool {
                guard let c = main.activate(config: "Engine\\Kept", file: nil), let c2 = main.refresh(c) else {
                    return t.check(false, "load")
                }
                t.check(c.isStopped && !c.isKeptForReplacement && c.content.state.tornDown, "main: closed at once")
                t.check(c2.isStarted)
                main.stopAllForTermination()
            }
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try E.write(app, ["Kept": E.plain])
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                guard let c = app.activate(config: "Engine\\Kept", file: nil), let engine = app.engineThread else {
                    return t.check(false, "load")
                }
                tracked.append(E.track(c))
                t.check(AppSelfTest.spin(timeout: 60) { c.isStarted }, "started")
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(engine)
                guard let c2 = app.refresh(c) else {
                    gate.open()
                    return t.check(false, "a new copy")
                }
                tracked.append(E.track(c2))
                try? FileManager.default.removeItem(at: app.skinsDirectory.appendingPathComponent("Engine/Kept/Kept.ini"))
                t.check(c.isKeptForReplacement, "kept while the new copy loads")
                gate.open()
                t.check(AppSelfTest.spin(timeout: 60) { c2.loadFailed }, "the new copy failed")
                t.check(!c.isKeptForReplacement && c.content.state.tornDown, "and the old window went with it")
                t.check(app.controller(for: "Engine\\Kept") == nil, "the config is unloaded")
            }
            E.finish(t, app, tracked)
        }
    }
}
