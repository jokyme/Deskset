import AppKit
import DesksetCore

/// Uses the runtime's existing messages so the same fixtures exercise the clock before and after its extraction.
enum TickSchedulerSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: tick scheduler: paused load, resume and wake keep their update order") {
            let executor = clock()
            let window = RecordingWindow()
            let runtime = try makeRuntime(t, periodic, executor: executor, window: window)
            defer { runtime.send(.close(fadeOut: false)); withExtendedLifetime(window) {} }
            load(runtime, paused: true)
            t.check(!runtime.isClosed, "loaded")
            t.equal(runtime.skin.updateCount, 1, "a paused load still makes its first update")
            t.equal(runtime.skin.variable("ClockLog"), "U")
            t.check(runtime.areUpdatesPaused)
            executor.advance(until: 2)
            t.equal(runtime.skin.updateCount, 1, "no timer while paused")

            runtime.send(.resume(updateNow: false))
            executor.advance(until: 2.5)
            runtime.send(.resume(updateNow: true))
            t.equal(runtime.skin.updateCount, 1, "an already resumed clock neither catches up nor restarts")
            executor.advance(until: 2.999)
            t.equal(runtime.skin.updateCount, 1)
            executor.advance(until: 3)
            t.equal(runtime.skin.updateCount, 2, "the original full interval elapsed")
            runtime.send(.pause)
            runtime.send(.pause)
            executor.advance(until: 5)
            t.equal(runtime.skin.updateCount, 2, "repeated pause leaves no update clock")

            runtime.send(.resume(updateNow: true))
            t.equal(runtime.skin.updateCount, 3, "one immediate catch-up")
            executor.advance(until: 5.999)
            t.equal(runtime.skin.updateCount, 3)
            executor.advance(until: 6)
            t.equal(runtime.skin.updateCount, 4)
            runtime.send(.wake)
            t.equal(runtime.skin.variable("ClockLog"), "UUUUUW", "an active wake runs update before OnWakeAction")
            runtime.send(.pause)
            runtime.send(.wake)
            t.equal(runtime.skin.variable("ClockLog"), "UUUUUWUW", "a paused wake has the same action order")
            t.check(!runtime.areUpdatesPaused)
            executor.advance(until: 7)
            t.equal(runtime.skin.updateCount, 7, "the resumed clock is periodic again")

            runtime.send(.run("[!SetOption Rainmeter Update -1]"))
            t.equal(runtime.skin.settings.update, 1000, "Update remains the loaded setting")
            executor.advance(until: 8)
            t.equal(runtime.skin.updateCount, 8, "SetOption does not replace the running clock")
            runtime.send(.close(fadeOut: false))
            t.equal(runtime.skin.variable("Closed"), "yes")
            t.equal(executor.pendingCount, 0)
            executor.advance(until: 20)
            t.equal(runtime.skin.updateCount, 8, "close cancels the timer before OnCloseAction")
        }

        t.suite("App: tick scheduler: update-once resumes and wakes without another update") {
            let executor = clock()
            let window = RecordingWindow()
            let runtime = try makeRuntime(t, periodic.replacingOccurrences(of: "Update=1000", with: "Update=-1"),
                                          executor: executor, window: window)
            defer { runtime.send(.close(fadeOut: false)); withExtendedLifetime(window) {} }
            load(runtime, paused: true)
            runtime.send(.resume(updateNow: true))
            executor.advance(until: 2)
            t.equal(runtime.skin.updateCount, 1)
            t.equal(runtime.skin.variable("ClockLog"), "U")
            runtime.send(.wake)
            t.equal(runtime.skin.variable("ClockLog"), "UW", "OnWakeAction runs immediately for Update=-1")
            runtime.send(.pause)
            runtime.send(.wake)
            t.equal(runtime.skin.variable("ClockLog"), "UWW")
            t.check(!runtime.areUpdatesPaused)
            executor.advance(until: 10)
            t.equal(runtime.skin.updateCount, 1, "neither wake nor resume installs a periodic clock")
            t.equal(executor.pendingCount, 0)
        }

        t.suite("App: tick scheduler: synchronous update and wake callbacks can pause or close") {
            for reply in [Reply.pause, .close] {
                let executor = clock()
                let recording = RecordingWindow()
                let window = ReentrantWindow(recording: recording)
                let runtime = try makeRuntime(t, reentrant, executor: executor, window: recording)
                runtime.window = window
                defer { runtime.send(.close(fadeOut: false)); withExtendedLifetime(window) {} }
                load(runtime, paused: true)
                window.reply = reply
                runtime.send(.resume(updateNow: true))
                t.equal(window.updates, [1, 2], "the catch-up reaches the real host request synchronously")
                t.equal(runtime.isClosed, reply == .close)
                t.equal(runtime.areUpdatesPaused, reply == .pause)
                executor.advance(until: 3)
                t.equal(runtime.skin.updateCount, 2, "startTimer reads the state changed inside the catch-up")
                t.equal(executor.pendingCount, 0)
            }

            let executor = clock()
            let recording = RecordingWindow()
            let window = ReentrantWindow(recording: recording)
            let runtime = try makeRuntime(t, reentrant.replacingOccurrences(of: "Update=1000", with: "Update=-1"),
                                          executor: executor, window: recording)
            runtime.window = window
            defer { runtime.send(.close(fadeOut: false)); withExtendedLifetime(window) {} }
            load(runtime, paused: true)
            window.reply = .close
            runtime.send(.wake)
            t.equal(window.updates, [1, 1], "the wake action closes before any catch-up")
            t.check(runtime.isClosed)
            t.check(runtime.areUpdatesPaused, "wake rechecks closed before it can resume")
            executor.advance(until: 3)
            t.equal(runtime.skin.updateCount, 1)
            t.equal(executor.pendingCount, 0)
        }

        t.suite("App: tick scheduler: timers do not retain their runtime or closed skin") {
            for closeFirst in [false, true] {
                let executor = clock()
                let window = RecordingWindow()
                var runtime: SkinRuntime? = try makeRuntime(t, periodic, executor: executor, window: window)
                weak var owner = runtime
                weak var skin = runtime?.skin
                if let runtime { load(runtime, paused: false) }
                t.equal(executor.pendingCount, 1, "a real virtual timer is pending")
                if closeFirst { runtime?.send(.close(fadeOut: false)) }
                runtime = nil
                t.check(owner == nil, "the timer callback holds no runtime")
                t.check(skin == nil, "the skin goes with its owner")
                t.equal(executor.pendingCount, 0, "deinit or close cancels the pending work")
                t.equal(executor.advance(until: 3), 0, "no callback survives its target")
                withExtendedLifetime(window) {}
            }
        }
    }

    private static func clock() -> VirtualTimeExecutor {
        VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private static func makeRuntime(_ t: AppTestRunner, _ text: String, executor: VirtualTimeExecutor,
                                    window: RecordingWindow) throws -> SkinRuntime {
        let runtime = try SkinRuntimeSelfTests.makeRuntime(t, text, executor: executor, window: window)
        runtime.skin.runInVirtualTime(executor)
        return runtime
    }

    private static func load(_ runtime: SkinRuntime, paused: Bool) {
        runtime.send(.load(SkinLoadOrder(state: SkinState(file: "Test.ini"), firstLoad: true, continuing: nil,
                                         presentsWindows: false, paused: paused)))
    }

    private enum Reply { case pause, close }

    /// The request is only recorded; no clipboard, real window or other operating-system action runs.
    private final class ReentrantWindow: SkinRuntimeWindow {
        let recording: RecordingWindow
        var reply: Reply?
        var updates: [Int] = []

        init(recording: RecordingWindow) { self.recording = recording }

        func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
            recording.apply(request, from: runtime)
            guard case .system = request else { return }
            updates.append(runtime.skin.updateCount)
            guard let reply else { return }
            self.reply = nil
            switch reply {
            case .pause: runtime.send(.pause)
            case .close: runtime.send(.close(fadeOut: false))
            }
        }

        func batchingWindowChanges(_ body: () -> Void) { recording.batchingWindowChanges(body) }
        func liveEnvironment(for skin: Skin) -> SkinEnvironment? { nil }
        var liveTakesPointer: Bool? { nil }
    }

    private static let periodic = """
        [Rainmeter]
        Update=1000
        OnUpdateAction=[!SetVariable ClockLog "[#ClockLog]U"]
        OnWakeAction=[!SetVariable ClockLog "[#ClockLog]W"]
        OnCloseAction=[!SetVariable Closed yes]
        [Variables]
        ClockLog=
        """

    private static let reentrant = """
        [Rainmeter]
        Update=1000
        OnUpdateAction=[!SetClip tick]
        OnWakeAction=[!SetClip wake]
        """
}
