import Darwin
import Foundation
@testable import DesksetCore

// The skin thread (suite prefix "Executor: skin thread"; docs/skin-threading.md §5.3, §15 phase 2 step 7): a
// `SkinThreadExecutor` runs its work first in, first out on a thread of its own, never inline; its timers fire there
// and can be cancelled from any thread; exclusive access parks the thread between two pieces of work or gives up after
// its timeout; `stop()` ends the thread after the work queued before it. Nothing waits for a fixed time: a gate holds
// the thread where a test needs it busy, and the waits are for conditions (a minute only tells "late" from "never").

func runSkinThreadExecutorTests(_ t: TestRunner) {
    CorePlugins.register()
    runSkinThreadOrderTests(t)
    runSkinThreadTimerTests(t)
    runSkinThreadParkTests(t)
    runSkinThreadStopTests(t)
    runSkinThreadSkinTests(t)
}

// MARK: - Helpers

/// Values collected from several threads.
private final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func add(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var count: Int { all.count }
}

/// Holds a thread inside a piece of work until the test opens it (`hold` queues that piece of work).
private final class ThreadGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let opened = DispatchSemaphore(value: 0)

    /// Queues work on `executor` that waits for `open()`; returns once the thread is inside it.
    func hold(_ executor: SkinThreadExecutor) {
        executor.async { [self] in
            entered.signal()
            opened.wait()
        }
        entered.wait()
    }

    func open() { opened.signal() }
}

/// Waits (without running anything) until `condition` holds; false after a minute.
@discardableResult
private func waitFor(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(60)
    while !condition() {
        if Date() >= deadline { return false }
        usleep(1000)
    }
    return true
}

/// Runs `body` on the executor's thread and waits for it (a test's way of asking the thread something).
private func onThread<T>(_ executor: SkinThreadExecutor, _ body: @escaping () -> T) -> T? {
    let result = Collected<T>()
    executor.async { result.add(body()) }
    return waitFor { result.count == 1 } ? result.all.first : nil
}

// MARK: - Order

private func runSkinThreadOrderTests(_ t: TestRunner) {
    t.suite("Executor: skin thread: work runs in order on its thread, never inline, with an 8 MB stack") {
        let executor = SkinThreadExecutor(name: "Deskset core test skin thread")
        defer { executor.stop() }
        t.check(!executor.isCurrent && !executor.isOnThread, "the main thread is not the skin's thread")
        t.check(!SkinThreadExecutor.isSkinThread, "nor a skin thread")
        t.check(executor.runLoop != nil, "the run loop is there once init returns")

        // From the main thread: first in, first out, on the thread.
        let order = Collected<Int>()
        let places = Collected<Bool>()
        for i in 0..<500 {
            executor.async {
                order.add(i)
                places.add(executor.isCurrent && executor.isOnThread && SkinThreadExecutor.isSkinThread)
            }
        }
        t.check(waitFor { order.count == 500 }, "all of it ran")
        t.equal(order.all, Array(0..<500), "in order")
        t.check(places.all.allSatisfy { $0 }, "on the skin's thread, which is marked as one")

        // From several threads at once: each sender's work keeps its order.
        let mixed = Collected<(Int, Int)>()
        DispatchQueue.concurrentPerform(iterations: 4) { sender in
            for i in 0..<100 { executor.async { mixed.add((sender, i)) } }
        }
        t.check(waitFor { mixed.count == 400 }, "every sender's work ran")
        for sender in 0..<4 {
            t.equal(mixed.all.filter { $0.0 == sender }.map(\.1), Array(0..<100), "sender \(sender) in order")
        }

        // Work the thread hands itself runs after the current work, never inline.
        let events = Collected<String>()
        executor.async {
            events.add("stack \(pthread_get_stacksize_np(pthread_self()) >= SkinThreadExecutor.defaultStackSize)")
            events.add("qos \(Thread.current.qualityOfService == .userInitiated)")
            events.add("name \(Thread.current.name ?? "")")
            var current = true
            executor.async { events.add("async \(current)") }
            events.add("after queueing")
            current = false
        }
        t.check(waitFor { events.count == 5 }, "all of it ran: \(events.all)")
        t.equal(events.all, ["stack true", "qos true", "name Deskset core test skin thread", "after queueing",
                             "async false"], "an 8 MB stack at .userInitiated; nothing ran inline")
    }
}

// MARK: - Timers

private func runSkinThreadTimerTests(_ t: TestRunner) {
    t.suite("Executor: skin thread: delays and timers fire on its thread, never inline, and cancel from any thread") {
        let executor = SkinThreadExecutor(name: "Deskset core test skin timers")
        defer { executor.stop() }
        // Delayed work and timers asked for on the thread, even with 0 seconds, fire on a later turn.
        let events = Collected<String>()
        executor.async {
            var current = true
            executor.async(after: 0) { events.add("after \(current) \(executor.isCurrent)") }
            _ = executor.timer(interval: 0, leeway: 0, repeats: false) { events.add("timer \(current) \(executor.isCurrent)") }
            current = false
        }
        t.check(waitFor { events.count == 2 }, "both fired: \(events.all)")
        t.equal(Set(events.all), ["after false true", "timer false true"], "on the thread, not inline")

        // Asked for from the main thread: installed on the thread, fired there.
        let fromMain = Collected<Bool>()
        executor.async(after: 0.001) { fromMain.add(executor.isCurrent) }
        t.check(waitFor { fromMain.count == 1 }, "a delay asked for from the main thread fires")
        t.equal(fromMain.all, [true], "on the skin's thread")

        // Cancelled right after it was asked for, before the thread installed it: it never fires.
        let never = Collected<Int>()
        let gate = ThreadGate()
        gate.hold(executor)
        let early = executor.async(after: 0) { never.add(1) }
        early.cancel()
        gate.open()
        let turn = Collected<Int>()
        executor.async(after: 0.02) { turn.add(1) }
        t.check(waitFor { turn.count == 1 }, "the thread went on past it")
        t.equal(never.count, 0, "cancelled before it was installed: never fired")

        // A repeating timer, cancelled from the main thread, from a background thread and from the thread itself.
        for canceller in ["main", "background", "thread"] {
            let ticks = Collected<Bool>()
            let timer = executor.timer(interval: 0.002, leeway: 0, repeats: true) { ticks.add(executor.isCurrent) }
            t.check(waitFor { ticks.count >= 3 }, "\(canceller): the timer fires")
            switch canceller {
            case "main":
                timer.cancel()
            case "background":
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    timer.cancel()
                    done.signal()
                }
                done.wait()
            default:
                executor.async { timer.cancel() }
                t.check(waitFor { timer.isCancelled }, "cancelled on the thread")
            }
            // A tick under way when it was cancelled ends before this work runs; then two turns long enough for
            // several more ticks of a timer still installed.
            let counts = Collected<Int>()
            executor.async { counts.add(ticks.count) }
            t.check(waitFor { counts.count == 1 }, "\(canceller): the thread goes on")
            executor.async(after: 0.02) { executor.async(after: 0.02) { counts.add(ticks.count) } }
            t.check(waitFor { counts.count == 2 }, "\(canceller): and on")
            t.equal(counts.all.last, counts.all.first, "\(canceller): no tick after the cancel")
            t.check(ticks.all.allSatisfy { $0 }, "\(canceller): every tick on the skin's thread")
            t.check(!timer.isPending, "\(canceller): no longer pending")
        }

        // A one-shot runs once, and cancelling it afterwards does nothing.
        let once = Collected<Int>()
        let shot = executor.async(after: 0) { once.add(1) }
        t.check(waitFor { once.count == 1 }, "a one-shot fires")
        shot.cancel()
        t.check(!shot.isCancelled && !shot.isPending, "a cancel after it ran does nothing")
    }
}

// MARK: - Exclusive access

private func runSkinThreadParkTests(_ t: TestRunner) {
    t.suite("Executor: skin thread: exclusive access parks the thread between two pieces of work") {
        let executor = SkinThreadExecutor(name: "Deskset core test skin park")
        defer { executor.stop() }
        // The thread is inside a piece of work: the park waits behind it, and the work queued after the park waits for
        // the caller to let go.
        let events = Collected<String>()
        let gate = ThreadGate()
        gate.hold(executor)
        executor.async { events.add("before the park") }
        let result = Collected<Int>()
        let caller = Thread {
            let value = executor.exclusive(timeout: 60) { () -> Int in
                events.add("caller \(executor.isCurrent) thread \(SkinThreadExecutor.isSkinThread)")
                // Re-entrant for the thread that holds it.
                let inner = executor.exclusive(timeout: 0) { 2 }
                return 40 + (inner ?? 0)
            }
            result.add(value ?? -1)
        }
        caller.start()
        t.check(waitFor { executor.queuedParks == 1 }, "the park is queued behind the work under way")
        executor.async { events.add("after the park \(executor.isCurrent)") }
        gate.open()
        t.check(waitFor { result.count == 1 && events.count == 3 }, "the caller ran: \(events.all)")
        t.equal(result.all, [42], "what the body returned, re-entrant")
        t.equal(events.all, ["before the park", "caller true thread false", "after the park true"],
                "between two pieces of work; the caller counts as the owner while it holds it")
        t.equal(executor.queuedParks, 0)

        // From the main thread too; the parked thread does not count as current meanwhile.
        let seenOnThread = Collected<Bool>()
        let value = executor.exclusive(timeout: 60) { () -> Bool in
            executor.isCurrent
        }
        t.equal(value, true, "the main thread holds it")
        executor.async { seenOnThread.add(executor.isCurrent) }
        t.check(waitFor { seenOnThread.count == 1 }, "the thread goes on")
        t.equal(seenOnThread.all, [true], "and owns its work again")
    }

    t.suite("Executor: skin thread: exclusive access gives up after its timeout, and the late park returns at once") {
        let executor = SkinThreadExecutor(name: "Deskset core test skin stuck")
        defer { executor.stop() }
        let gate = ThreadGate()
        gate.hold(executor)
        var ran = false
        let start = Date()
        let value = executor.exclusive(timeout: 0.05) { () -> Int in
            ran = true
            return 1
        }
        t.equal(value, nil, "nil while the thread is stuck")
        t.check(!ran, "the body did not run")
        t.check(Date().timeIntervalSince(start) >= 0.05, "after the timeout")
        t.equal(executor.queuedParks, 1, "its park still waits in the queue")
        let after = Collected<Bool>()
        executor.async { after.add(executor.isCurrent) }
        gate.open()
        t.check(waitFor { after.count == 1 }, "the late park returned at once, and the work after it ran")
        t.equal(after.all, [true])
        t.equal(executor.queuedParks, 0)
    }

    t.suite("Executor: skin thread: debug builds stop a skin thread that waits for the main thread or another skin") {
        #if DEBUG
        let violations = Collected<String>()
        let saved = SkinThreadExecutor.waitViolation
        SkinThreadExecutor.waitViolation = { violations.add($0) }
        defer { SkinThreadExecutor.waitViolation = saved }
        let one = SkinThreadExecutor(name: "Deskset core test skin one")
        let two = SkinThreadExecutor(name: "Deskset core test skin two")
        defer {
            one.stop()
            two.stop()
        }
        // Off a skin thread: nothing to report.
        SkinThreadExecutor.assertNotWaiting(on: "the main thread")
        let background = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            SkinThreadExecutor.assertNotWaiting(on: "the main thread")
            background.signal()
        }
        background.wait()
        t.equal(violations.all, [], "the main thread and GCD's threads may wait")
        // On a skin thread.
        _ = onThread(one) { SkinThreadExecutor.assertNotWaiting(on: "the main thread") }
        t.equal(violations.all, ["the main thread"], "a skin thread may not")
        // Sideways: one skin thread asking another's exclusive access (it still gets it here: only the check fires).
        let sideways = onThread(one) { two.exclusive(timeout: 60) { 7 } }
        t.equal(sideways ?? nil, 7)
        t.equal(violations.all.last, "another skin thread's exclusive access", "asking another skin thread is caught")
        // Its own exclusive access is re-entrant, not a wait; the main executor's gives up at once.
        let count = violations.count
        let own = onThread(one) { one.exclusive(timeout: 0) { 1 } }
        t.equal(own ?? nil, 1)
        let main = onThread(one) { MainSkinExecutor.shared.exclusive(timeout: 60) { 1 } }
        t.equal(main ?? 0, nil, "the main executor's exclusive access gives up at once off the main thread")
        t.equal(violations.count, count, "neither is a wait")
        #else
        print("    (skipped: the checks exist in debug builds only)")
        #endif
    }
}

// MARK: - Stopping

private func runSkinThreadStopTests(_ t: TestRunner) {
    t.suite("Executor: skin thread: stop ends the thread after the work queued before it") {
        let executor = SkinThreadExecutor(name: "Deskset core test skin stop")
        let last = Collected<String>()
        let fired = Collected<String>()
        executor.async { last.add("before") }
        // A timer that would fire after the stop: the thread is gone by then.
        let late = executor.async(after: 0.05) { fired.add("late") }
        executor.stop()
        executor.async { last.add("after") }
        t.check(waitFor { executor.hasExited }, "the thread ends")
        t.equal(last.all, ["before"], "work queued after the stop never runs")
        // Cancelling what the ended thread had installed does not hang (the invalidation it queues never runs).
        late.cancel()
        t.check(late.isCancelled)
        t.equal(fired.all, [], "nor does a timer of the ended thread")
        // Stopping twice, and queueing work after it ended, does nothing.
        executor.stop()
        executor.async { last.add("much later") }
        t.equal(last.all, ["before"])
    }
}

// MARK: - A skin on the thread

private final class ThreadHost: FakeHost {
    let threads = Collected<Bool>()
    let lines = Collected<String>()
    let executor: SkinThreadExecutor

    init(executor: SkinThreadExecutor) {
        self.executor = executor
    }

    override func skinNeedsDisplay(_ skin: Skin) {
        threads.add(executor.isCurrent)
        super.skinNeedsDisplay(skin)
    }

    override func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        threads.add(executor.isCurrent)
        lines.add(message)
        super.skin(skin, log: message, level: level)
    }
}

private var retainedThreadHosts: [ThreadHost] = []

private func runSkinThreadSkinTests(_ t: TestRunner) {
    t.suite("Executor: skin thread: a skin lives its whole life on the thread, !Delay included") {
        #if DEBUG
        let violations = Collected<String>()
        let saved = Skin.ownershipViolation
        Skin.ownershipViolation = { _, entry in violations.add("\(entry)") }
        defer { Skin.ownershipViolation = saved }
        #endif
        let executor = SkinThreadExecutor(name: "Deskset core test skin life")
        defer { executor.stop() }
        let skins = t.temporaryDirectory("skin-thread").appendingPathComponent("Skins")
        let dir = skins.appendingPathComponent("Root/Sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [Rainmeter]
        Update=-1
        OnRefreshAction=[!Delay 1][!SetVariable Waited 1][!Log "delayed on the thread"][!Redraw]
        [Variables]
        Waited=0
        [C]
        Measure=Calc
        Formula=C + 1
        DynamicVariables=1
        [M]
        Meter=String
        MeasureName=C
        Text=%1 #Waited#
        DynamicVariables=1
        W=50
        H=20
        LeftMouseUpAction=[!SetVariable Clicked 1]
        """.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        let host = ThreadHost(executor: executor)
        retainedThreadHosts.append(host)  // Skin.host is weak.
        let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                        system: FakeSystem(), host: host)
        skin.executor = executor
        let loaded = onThread(executor) { () -> Bool in
            do {
                try skin.load()
                skin.update()
                return true
            } catch {
                return false
            }
        }
        t.equal(loaded, true, "loaded and updated on the thread")
        t.check(waitFor { host.lines.all.contains("delayed on the thread") }, "the delayed actions ran: \(host.lines.all)")
        let after = onThread(executor) { () -> (String, Bool) in
            skin.update()
            let text = skin.variable("Waited") ?? ""
            let clicked = skin.mouseEvent(.leftUp, x: 5, y: 5)
            skin.close()
            return (text, clicked)
        }
        t.equal(after?.0, "1", "!Delay waited on the thread")
        t.equal(after?.1, true, "a mouse action ran there")
        t.check(host.threads.count >= 2 && host.threads.all.allSatisfy { $0 }, "every host call came from the thread")
        #if DEBUG
        t.equal(violations.all, [], "no ownership check fired")
        #endif
    }
}
