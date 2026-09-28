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
}
