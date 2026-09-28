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
}
