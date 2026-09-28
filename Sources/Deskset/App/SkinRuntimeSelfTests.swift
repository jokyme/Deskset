import AppKit
import DesksetCore

/// A skin's two halves (docs/skin-threading.md §5.4, phase 2 step 1): `SkinRuntime` owns the skin on its executor,
/// `SkinWindowController` keeps the window on the main thread, and they talk through messages, requests and exclusive
/// access. Every skin of the app still runs on the main executor, where all of it happens inline; a skin on a test
/// thread (`TestThreadExecutor`) shows what happens once it runs elsewhere.
enum SkinRuntimeSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: skin runtime: the window half reaches its skin through the runtime") {
            guard let app = try AppSelfTest.makeApp(t),
                  let c = app.activate(config: "App\\Counter", file: nil) else { return }
            t.check(c.runtime.window === c, "the runtime's window side is its window controller")
            t.check(c.skin.host === c.runtime, "the runtime is the skin's host")
            t.check(c.skin === c.runtime.skin)
            t.equal(c.fileURL, c.skin.fileURL)
            t.check(c.skin.host is LiveSkinHost, "a skin window's skin runs on live data")
            t.check(c.runtime.executor === MainSkinExecutor.shared, "on the main executor")
            app.stopAllForTermination()
        }

        t.suite("App: skin runtime: messages run at once on the owner and answer") {
            let window = RecordingWindow()
            let runtime = try makeRuntime(t, testSkin, executor: MainSkinExecutor.shared, window: window)
            _ = try runtime.load()
            runtime.send(.start)
            var seen: [String] = []
            runtime.messageObserver = { seen.append(describe($0)) }
            let executed = runtime.send(.execute("[!SetVariable Log \"#Log#,a\"]", section: nil))
            t.equal(executed, true, "ran")
            t.equal(runtime.skin.variable("Log"), ",a", "before send returned")
            t.equal(runtime.send(.mouse(.leftUp, x: 10, y: 10)), true, "the meter's action handled the click")
            t.equal(runtime.skin.variable("Clicked"), ",up")
            t.equal(runtime.send(.mouse(.leftUp, x: 100, y: 100)), false, "nothing there to handle it")
            t.equal(seen, ["execute", "mouse 10 10", "mouse 100 100"])
            runtime.send(.close(fadeOut: false))
            t.check(runtime.isClosed, "closed at once")
            t.equal(runtime.skin.variable("Closed"), "1", "OnCloseAction ran")
            t.equal(runtime.send(.execute("[!SetVariable Log late]", section: nil)), false,
                    "a closed skin takes no more messages")
            t.equal(runtime.skin.variable("Log"), ",a")
        }

        t.suite("App: skin runtime: messages queue in order on a skin thread") {
            let executor = TestThreadExecutor(name: "Skin runtime test")
            let window = RecordingWindow()
            defer { withExtendedLifetime(window) {} }
            var runtime: SkinRuntime? = try makeRuntime(t, testSkin, executor: executor, window: window)
            defer { finish(t, &runtime, executor) }
            guard let r = runtime, load(t, r, on: executor) else { return }
            let seen = Guarded<[String]>([])
            let onThread = Guarded<[Bool]>([])
            r.messageObserver = { message in
                seen.access { $0.append(describe(message)) }
                onThread.access { $0.append(executor.isCurrent) }
            }
            var answers: [Bool?] = []
            for i in 1...50 {
                answers.append(r.send(.execute("[!SetVariable Log \"#Log#,\(i)\"]", section: nil)))
            }
            t.check(answers.allSatisfy { $0 == nil }, "queued from the main thread: no answer")
            let log = r.exclusive(timeout: 30) { $0.variable("Log") } ?? nil
            t.equal(log, (1...50).map { ",\($0)" }.joined(), "all of them, first in first out")
            t.equal(onThread.current.count, 50)
            t.check(onThread.current.allSatisfy { $0 }, "on the skin's thread")

            // Sent on the skin's own thread, a message runs at once and answers.
            let inline = Guarded<Bool??>(nil)
            executor.async { inline.access { $0 = r.send(.mouse(.leftUp, x: 10, y: 10)) } }
            t.check(AppSelfTest.spin(timeout: 30) { inline.current != nil }, "the thread's own send ran")
            t.equal(inline.current, .some(.some(true)), "and answered")

            // Hovers (and window facts) right behind one of their kind take its place; nothing else is merged.
            seen.access { $0 = [] }
            let gate = DispatchSemaphore(value: 0)
            executor.async { _ = gate.wait(timeout: .now() + 30) }
            for x in [1.0, 2, 3] { r.send(.hover(x: x, y: 5)) }
            r.send(.exited)
            for x in [4.0, 5] { r.send(.hover(x: x, y: 5)) }
            r.send(.windowFacts(facts(1)))
            r.send(.windowFacts(facts(2)))
            r.send(.focus(true))
            gate.signal()
            _ = r.exclusive(timeout: 30) { _ in true }
            t.equal(seen.current, ["hover 3 5", "exited", "hover 5 5", "facts 2", "focus true"])

            r.send(.close(fadeOut: false))
            t.equal(r.exclusive(timeout: 30) { _ in r.isClosed }, true, "closed on its thread")
        }

        t.suite("App: skin runtime: requests apply at once on the main thread and in order from a thread") {
            let window = RecordingWindow()
            let mainRuntime = try makeRuntime(t, testSkin, executor: MainSkinExecutor.shared, window: window)
            _ = try mainRuntime.load()
            mainRuntime.send(.start)
            window.log = []
            mainRuntime.request(.snapshotChanged)
            t.equal(window.log, ["snapshotChanged on main"], "applied before request returned")
            window.log = []
            mainRuntime.send(.execute("[!Move 10 20]", section: nil))
            t.equal(window.log, ["window move on main"], "a window bang is asked of the main thread at once")

            let executor = TestThreadExecutor(name: "Skin runtime requests")
            let threadWindow = RecordingWindow()
            var held: SkinRuntime? = try makeRuntime(t, testSkin, executor: executor, window: threadWindow)
            defer { finish(t, &held, executor) }
            guard let runtime = held, load(t, runtime, on: executor) else { return }
            // What its first update asked for has arrived: the requests after a marker queued behind it.
            executor.async { runtime.request(.snapshotChanged) }
            t.check(AppSelfTest.spin(timeout: 30) { threadWindow.log.last == "snapshotChanged on main" }, "marker")
            threadWindow.log = []
            executor.async {
                for i in 0..<20 { runtime.request(.fadeWindow(from: i, to: i)) }
            }
            let expected = (0..<20).map { "fade \($0) on main" }
            t.check(AppSelfTest.spin(timeout: 30) { threadWindow.log.count >= 20 }, "all arrive")
            t.equal(threadWindow.log, expected, "in order, on the main thread")

            // What the engine asks of the host is answered on the skin's thread: supported or not.
            threadWindow.log = []
            runtime.send(.execute("[!Move 30 40][!LoadLayout Other][!SetClip Hello]", section: nil))
            t.check(AppSelfTest.spin(timeout: 30) { threadWindow.log.count >= 2 }, "requests arrive")
            t.equal(threadWindow.log, ["window move on main", "system setclip on main"])
            let issues = runtime.exclusive(timeout: 30) { $0.issues } ?? []
            t.check(issues.contains { $0.localizedCaseInsensitiveContains("LoadLayout") },
                    "an unsupported bang is a compatibility note: \(issues)")
            t.check(!issues.contains { $0.localizedCaseInsensitiveContains("Move") }, "a supported one is not")
            runtime.send(.close(fadeOut: false))
            _ = runtime.exclusive(timeout: 30) { _ in true }
        }

        t.suite("App: skin runtime: exclusive access runs at once on the owner and is re-entrant") {
            let window = RecordingWindow()
            defer { withExtendedLifetime(window) {} }
            let runtime = try makeRuntime(t, testSkin, executor: MainSkinExecutor.shared, window: window)
            _ = try runtime.load()
            t.equal(runtime.exclusive { _ in Thread.isMainThread }, true, "on the main thread, at once")
            t.equal(runtime.exclusive { _ in runtime.exclusive { _ in 7 } }, .some(.some(7)), "re-entrant")
            let offMain = Guarded<Int??>(nil)
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                offMain.access { $0 = .some(MainSkinExecutor.shared.exclusive(timeout: 10) { 1 }) }
                done.signal()
            }
            t.check(done.wait(timeout: .now() + 30) == .success, "a thread asking for the main executor's skins")
            t.equal(offMain.current, .some(.none), "gives up at once: a skin thread never waits for the main thread")

            let executor = TestThreadExecutor(name: "Skin runtime re-entrant")
            defer { executor.stop() }
            t.equal(executor.exclusive(timeout: 30) { executor.exclusive(timeout: 0) { 2 } }, .some(.some(2)),
                    "held by the main thread, again from it")
            let own = Guarded<Int??>(nil)
            executor.async { own.access { $0 = .some(executor.exclusive(timeout: 0) { 3 }) } }
            t.check(AppSelfTest.spin(timeout: 30) { own.current != nil })
            t.equal(own.current, .some(.some(3)), "the thread's own, at once")
        }

        t.suite("App: skin runtime: exclusive access parks a busy thread between two pieces of work") {
            let executor = TestThreadExecutor(name: "Skin runtime park")
            let window = RecordingWindow()
            defer { withExtendedLifetime(window) {} }
            var held: SkinRuntime? = try makeRuntime(t, testSkin, executor: executor, window: window)
            defer { finish(t, &held, executor) }
            guard let runtime = held, load(t, runtime, on: executor) else { return }
            let started = Guarded(false), ended = Guarded(false), second = Guarded(false), busy = Guarded(0)
            let gate = DispatchSemaphore(value: 0)
            executor.async {
                busy.access { $0 += 1 }
                started.access { $0 = true }
                _ = gate.wait(timeout: .now() + 30)
                ended.access { $0 = true }
                busy.access { $0 -= 1 }
            }
            executor.async {
                busy.access { $0 += 1 }
                second.access { $0 = true }
                busy.access { $0 -= 1 }
            }
            t.check(AppSelfTest.spin(timeout: 30) { started.current }, "the thread is busy")
            // Lets the first piece of work finish only once the park is queued behind it.
            Thread.detachNewThread {
                let end = Date().addingTimeInterval(30)
                while executor.queuedParks.current == 0 && Date() < end { usleep(1000) }
                gate.signal()
            }
            let inside = executor.exclusive(timeout: 60) { () -> [String: Bool] in
                var seen: [String: Bool] = [:]
                seen["first ended"] = ended.current
                seen["second ran"] = second.current
                seen["nothing running"] = busy.current == 0
                seen["current here"] = executor.isCurrent
                seen["current elsewhere"] = onAnotherThread { executor.isCurrent }
                // The skin's entry points check that their caller owns it (debug builds stop otherwise).
                runtime.skin.update()
                seen["menu"] = runtime.skin.contextMenuItems().isEmpty
                seen["inline"] = runtime.send(.execute("[!SetVariable Log parked]", section: nil)) == true
                seen["read"] = runtime.skin.variable("Log") == "parked"
                return seen
            }
            t.equal(inside?["first ended"], true, "the work under way finished first, not cut in two")
            t.equal(inside?["second ran"], true, "and what was queued before the park")
            t.equal(inside?["nothing running"], true, "the thread is parked between two pieces of work")
            t.equal(inside?["current here"], true, "the holder owns the skin")
            t.equal(inside?["current elsewhere"], false, "nobody else does")
            t.equal(inside?["menu"], true)
            t.equal(inside?["inline"], true, "a message from the holder runs at once")
            t.equal(inside?["read"], true)
            let after = Guarded<Bool?>(nil)
            executor.async { after.access { $0 = executor.isCurrent } }
            t.check(AppSelfTest.spin(timeout: 30) { after.current != nil }, "the thread goes on")
            t.equal(after.current, true, "and owns its skin again")
            runtime.send(.close(fadeOut: false))
            _ = runtime.exclusive(timeout: 30) { _ in true }
        }

        t.suite("App: skin runtime: exclusive access gives up on a stuck thread, whose late park returns at once") {
            let executor = TestThreadExecutor(name: "Skin runtime stuck")
            defer { executor.stop() }
            let gate = DispatchSemaphore(value: 0)
            executor.async { _ = gate.wait(timeout: .now() + 30) }
            var ran = false
            let result = executor.exclusive(timeout: 0.05) { () -> Bool in
                ran = true
                return true
            }
            t.check(result == nil, "nil after the timeout")
            t.check(!ran, "the closure did not run")
            t.equal(executor.queuedParks.current, 1, "its park still waits in the queue")
            gate.signal()
            let next = Guarded(false)
            executor.async { next.access { $0 = true } }
            t.check(AppSelfTest.spin(timeout: 30) { next.current }, "the late park returned at once: the work after it ran")
            t.equal(executor.queuedParks.current, 0)
            t.check(!ran)
            t.equal(executor.exclusive(timeout: 30) { 4 }, .some(4), "a later request is served")
        }

        t.suite("App: skin runtime: after close the skin is let go of on its executor") {
            // On a thread of its own: the window half lets go of the runtime on the main thread.
            let executor = TestThreadExecutor(name: "Skin runtime release")
            defer { executor.stop() }
            let released = ReleaseProbe.Record()
            ReleaseProbe.record = released
            defer { ReleaseProbe.record = nil }
            let window = RecordingWindow()
            defer { withExtendedLifetime(window) {} }
            var runtime: SkinRuntime? = try makeRuntime(t, testSkin + probe, executor: executor, window: window)
            weak var skin: Skin?
            if let r = runtime {
                guard load(t, r, on: executor) else { return }
                skin = r.skin
                r.send(.close(fadeOut: false))
                t.equal(r.exclusive(timeout: 30) { $0.variable("Closed") }, .some("1"), "OnCloseAction ran")
            }
            t.check(skin != nil, "the closed skin stays while its runtime does")
            runtime = nil
            t.check(AppSelfTest.spin(timeout: 30) { skin == nil }, "then goes")
            t.equal(released.threads.current, [true], "released on the skin's thread")

            // On the main executor, through the app: unloaded, the skin goes with its window controller.
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("App/Runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (testSkin + probe).write(to: folder.appendingPathComponent("Test.ini"), atomically: true, encoding: .utf8)
            released.threads.access { $0 = [] }
            weak var appSkin: Skin?
            autoreleasepool {
                app.rescanLibrary()
                guard let c = app.activate(config: "App\\Runtime", file: "Test.ini") else { return }
                appSkin = c.skin
                app.deactivate(config: "App\\Runtime")
            }
            t.check(AppSelfTest.spin(timeout: 30) { appSkin == nil }, "an unloaded skin goes")
            t.equal(released.threads.current, [true], "on the main thread, its executor")
        }
    }

    // MARK: Helpers

    /// A skin with a clickable box, actions that leave marks and an OnCloseAction.
    static let testSkin = """
        [Rainmeter]
        Update=-1
        OnCloseAction=[!SetVariable Closed 1]

        [Variables]
        Log=
        Clicked=
        Closed=0

        [MeterBox]
        Meter=Shape
        Shape=Rectangle 0,0,40,40 | Fill Color 255,0,0,255
        LeftMouseUpAction=[!SetVariable Clicked "#Clicked#,up"]

        """

    /// A measure that tells where it was released (`ReleaseProbe`).
    static let probe = """
        [MeasureProbe]
        Measure=Plugin
        Plugin=DesksetRuntimeReleaseProbe

        """

    static func makeRuntime(_ t: AppTestRunner, _ text: String, executor: SkinExecutor,
                            window: RecordingWindow) throws -> SkinRuntime {
        ReleaseProbe.register()
        let root = t.temporaryDirectory("runtime")
        let folder = root.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("Test.ini"), atomically: true, encoding: .utf8)
        let runtime = SkinRuntime(config: "Runtime", file: "Test.ini", skinsDirectory: root, executor: executor)
        runtime.window = window
        return runtime
    }

    /// Loads the runtime's skin on its thread and starts it (first update).
    static func load(_ t: AppTestRunner, _ runtime: SkinRuntime, on executor: TestThreadExecutor) -> Bool {
        let loaded = Guarded<Bool?>(nil)
        executor.async {
            let ok = (try? runtime.load()) != nil
            if ok { runtime.send(.start) }
            loaded.access { $0 = ok }
        }
        let arrived = AppSelfTest.spin(timeout: 60) { loaded.current != nil }
        t.check(arrived && loaded.current == true, "the skin loads on its thread")
        return loaded.current == true
    }

    /// Lets go of a runtime on a test thread, waits for its skin to go (on the thread), then ends the thread.
    static func finish(_ t: AppTestRunner, _ runtime: inout SkinRuntime?, _ executor: TestThreadExecutor) {
        weak var skin: Skin?
        skin = runtime?.skin
        runtime = nil
        t.check(AppSelfTest.spin(timeout: 30) { skin == nil }, "the skin is let go of")
        executor.stop()
    }

    /// `body`'s answer on a thread of its own (a queue's `sync` would run it on the calling thread).
    static func onAnotherThread(_ body: @escaping () -> Bool) -> Bool? {
        let answer = Guarded<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            answer.access { $0 = body() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        return answer.current
    }

    static func facts(_ sequence: Int) -> SkinWindowFacts {
        SkinWindowFacts(frame: .zero, screen: nil, isVisible: true, scale: 2, takesPointer: true, sequence: sequence)
    }

    static func describe(_ message: SkinMessage) -> String {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        switch message {
        case .mouse(_, let x, let y): return "mouse \(n(x)) \(n(y))"
        case .hover(let x, let y): return "hover \(n(x)) \(n(y))"
        case .exited: return "exited"
        case .focus(let focused): return "focus \(focused)"
        case .execute: return "execute"
        case .windowFacts(let facts): return "facts \(facts.sequence)"
        case .close: return "close"
        case .start: return "start"
        default: return "other"
        }
    }
}

/// The main-thread side of a runtime in the tests: records the requests it gets, and where.
final class RecordingWindow: SkinRuntimeWindow {
    var log: [String] = []

    func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
        let place = Thread.isMainThread ? "on main" : "off main"
        switch request {
        case .display: return   // every redraw
        case .snapshotChanged: log.append("snapshotChanged \(place)")
        case .window(let host): log.append("window \(host.bang.name) \(place)")
        case .system(let host): log.append("system \(host.bang.name) \(place)")
        case .fadeWindow(let from, _): log.append("fade \(from) \(place)")
        default: log.append("other \(place)")
        }
    }

    func environment(for skin: Skin) -> SkinEnvironment { SkinEnvironment() }
    var takesPointer: Bool { true }
    var screen: NSScreen? { nil }
}

/// `Plugin=DesksetRuntimeReleaseProbe`: notes, when it is released with its skin, whether that happened on the skin's
/// executor.
final class ReleaseProbe: Measure {
    final class Record {
        let threads = Guarded<[Bool]>([])
    }

    /// Where releases are noted while a test runs.
    static var record: Record? {
        get { current.current }
        set { current.access { $0 = newValue } }
    }
    private static let current = Guarded<Record?>(nil)

    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        MeasureRegistry.registerPlugin("DesksetRuntimeReleaseProbe", ReleaseProbe.self)
    }

    deinit {
        let onExecutor = skinExecutor?.isCurrent ?? false
        ReleaseProbe.record?.threads.access { $0.append(onExecutor) }
    }

    /// The skin's executor, taken when the measure reads its options (the skin is going when the measure is).
    private var skinExecutor: SkinExecutor?

    override func readMeasureOptions() {
        if skinExecutor == nil { skinExecutor = skin.executor }
    }
}
