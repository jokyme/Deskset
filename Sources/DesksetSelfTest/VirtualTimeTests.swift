import Foundation
@testable import DesksetCore

// Virtual time (suite prefix "Executor: virtual time"; the runtime design, "VirtualTimeExecutor"): the executor that
// runs a skin's work only when its owner steps it, and the background-work seam that brings results back as ordinary
// work in its queue. Each rule of the design has a suite; the executor contract that the main executor keeps is checked
// on both executors with the same code. The waits are for real background work (a file read, a process lookup) to
// hand its result over, never for a fixed time.

func runVirtualTimeTests(_ t: TestRunner) {
    CorePlugins.register()
    runExecutorContractTests(t)
    runVirtualQueueTests(t)
    runVirtualClockTests(t)
    runVirtualEngineTests(t)
    runBackgroundWorkTests(t)
}

// MARK: - Helpers

/// 2026-09-28 09:00:00 UTC.
private let start = Date(timeIntervalSince1970: 1_790_586_000)
private let utc = TimeZone(identifier: "UTC")!

private func virtualExecutor() -> VirtualTimeExecutor { VirtualTimeExecutor(start: start, timeZone: utc) }

private var retainedVirtualHosts: [FakeHost] = []

/// Writes `ini` (and `files`, relative to the Skins folder) and loads `Root\Sub\Skin.ini` in `executor`'s virtual
/// time (the main executor when nil).
private func virtualSkin(_ t: TestRunner, _ ini: String, files: [String: String] = [:],
                         executor: VirtualTimeExecutor?) throws -> Skin {
    let skins = t.temporaryDirectory("virtual").appendingPathComponent("Skins")
    let dir = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = skins.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let host = FakeHost()
    retainedVirtualHosts.append(host)  // Skin.host is weak.
    let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: FakeSystem(), host: host)
    if let executor { skin.runInVirtualTime(executor) }
    try skin.load()
    return skin
}

/// Spins the main run loop until `condition` holds; false after a minute ("late" versus "never").
@discardableResult
private func spin(until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(60)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

/// Steps `executor` until `condition` holds: what is due now, then on to the next due time; false once nothing is left
/// (virtual time never waits).
@discardableResult
private func step(_ executor: VirtualTimeExecutor, until condition: () -> Bool) -> Bool {
    for _ in 0..<100_000 {
        if condition() { return true }
        executor.runUntilIdle()
        if condition() { return true }
        guard let next = executor.nextDue else { return condition() }
        executor.advance(until: next)
    }
    return condition()
}

private final class Token {}

/// Values recorded from any thread.
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func add(_ value: Value) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }
}

// MARK: - The contract both executors keep

/// The rules every `SkinExecutor` keeps (see its documentation), checked the same way on the main executor, driven by
/// the main run loop, and on a virtual one, driven by stepping it.
private func runExecutorContract(_ t: TestRunner, _ label: String, _ executor: SkinExecutor,
                                 drive: @escaping (() -> Bool) -> Bool) {
    t.suite("Executor: \(label) — async runs in order, never inline, after the current work") {
        t.check(executor.isCurrent, "the tests own it on the main thread")
        var order: [Int] = []
        executor.async { order.append(1) }
        executor.async {
            order.append(2)
            // Work handed over by work runs after it ("after the current action").
            executor.async { order.append(5) }
            order.append(3)
        }
        executor.async { order.append(4) }
        t.equal(order, [], "never inline")
        t.check(drive { order.count == 5 })
        t.equal(order, [1, 2, 3, 4, 5], "first in, first out; work queued by work comes after it")

        var ranOnExecutor = false
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            executor.async { ranOnExecutor = executor.isCurrent }
            posted.signal()
        }
        posted.wait()
        t.check(drive { ranOnExecutor }, "work handed over from another thread runs on the executor")
    }

    t.suite("Executor: \(label) — async(after:) and cancelling") {
        var ran = false
        let soon = executor.async(after: 0) { ran = true }
        t.check(!ran && soon.isPending, "async(after: 0) is not inline either")
        t.check(drive { ran })
        t.check(!soon.isPending && !soon.isCancelled, "done, not cancelled")

        weak var captured: Token?
        var late: SkinScheduledWork?
        var lateRan = false
        do {
            let token = Token()
            captured = token
            late = executor.async(after: 3600) {
                _ = token
                lateRan = true
            }
        }
        t.check(captured != nil, "pending work holds what it captured")
        late?.cancel()
        t.check(late?.isCancelled == true)
        t.check(captured == nil, "cancelling lets go of it at once, not an hour later")
        var flushed = false
        executor.async { flushed = true }
        t.check(drive { flushed })
        t.check(!lateRan, "cancelled work never runs")
    }

    t.suite("Executor: \(label) — timers") {
        var fired = 0
        let once = executor.timer(interval: 0, leeway: 0, repeats: false) { fired += 1 }
        t.equal(fired, 0, "a timer never fires inline, not even with interval 0")
        t.check(drive { fired == 1 })
        t.check(!once.isPending, "a one-shot is done once it fired")

        var ticks = 0
        let repeating = executor.timer(interval: 0.001, leeway: 0, repeats: true) { ticks += 1 }
        t.check(drive { ticks >= 3 }, "a repeating timer fires until it is cancelled")
        // Cancelled on another thread while the executor's thread waits (so no tick is under way): its work never
        // runs again.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            repeating.cancel()
            done.signal()
        }
        done.wait()
        let atCancel = ticks
        t.check(repeating.isCancelled)
        var later = false
        _ = executor.async(after: 0.01) { later = true }
        t.check(drive { later })
        t.equal(ticks, atCancel, "no tick after cancel() from another thread")

        var selfCancelled = 0
        var timer: SkinScheduledWork?
        timer = executor.timer(interval: 0.001, leeway: 0, repeats: true) {
            selfCancelled += 1
            if selfCancelled == 2 { timer?.cancel() }
        }
        t.check(drive { selfCancelled == 2 })
        var after = false
        _ = executor.async(after: 0.01) { after = true }
        t.check(drive { after })
        t.equal(selfCancelled, 2, "a timer cancelled from its own work stops")
    }
}

private func runExecutorContractTests(_ t: TestRunner) {
    runExecutorContract(t, "contract — main executor", MainSkinExecutor.shared) { condition in spin(until: condition) }
    let virtual = virtualExecutor()
    runExecutorContract(t, "virtual time — contract", virtual) { condition in step(virtual, until: condition) }
}

// MARK: - The queue

private func runVirtualQueueTests(_ t: TestRunner) {
    t.suite("Executor: virtual time — work runs only when stepped, due now at runUntilIdle") {
        let v = virtualExecutor()
        var ran: [String] = []
        v.async { ran.append("a") }
        v.async { ran.append("b") }
        _ = v.async(after: 1) { ran.append("later") }
        t.equal(ran, [], "nothing runs when it is handed over")
        t.equal(v.pendingCount, 3)
        t.equal(v.runUntilIdle(), 2)
        t.equal(ran, ["a", "b"])
        t.equal(v.now, 0, "runUntilIdle does not move time on")
        t.equal(v.runUntilIdle(), 0, "work due later waits")
        t.equal(v.nextDue, 1)
        v.advance(by: 1)
        t.equal(ran, ["a", "b", "later"])
        t.equal(v.pendingCount, 0)
        t.equal(v.nextDue, nil)
    }

    t.suite("Executor: virtual time — async(after:) is due at now + max(d, 0)") {
        let v = virtualExecutor()
        v.advance(by: 10)
        var at: [String: TimeInterval] = [:]
        _ = v.async(after: 2) { at["2"] = v.now }
        _ = v.async(after: -5) { at["-5"] = v.now }
        _ = v.async(after: .nan) { at["nan"] = v.now }
        _ = v.async(after: .infinity) { at["inf"] = v.now }
        v.runUntilIdle()
        t.equal(at["-5"], 10, "a negative delay is due now")
        t.equal(at["nan"], 10, "so is one that is not a number")
        t.equal(at["2"], nil)
        v.advance(by: 1.5)
        t.equal(at["2"], nil)
        v.advance(by: 0.5)
        t.equal(at["2"], 12, "due at 10 + 2, and run at that time")
        v.advance(by: 1e9)
        t.equal(at["inf"], nil, "an infinite delay never falls due")
        t.equal(v.pendingCount, 1)
    }

    t.suite("Executor: virtual time — timers fire at now + i, then every i; leeway ignored; stop when cancelled") {
        let v = virtualExecutor()
        v.advance(by: 0.25)
        var fires: [TimeInterval] = []
        let timer = v.timer(interval: 1, leeway: 5, repeats: true) { fires.append(v.now) }
        v.advance(by: 3.5)
        t.equal(fires, [1.25, 2.25, 3.25], "first at now + i, then every i, exactly (no leeway)")
        timer.cancel()
        v.advance(by: 10)
        t.equal(fires.count, 3, "not queued again once cancelled")

        var once: [TimeInterval] = []
        _ = v.timer(interval: 2, leeway: 0, repeats: false) { once.append(v.now) }
        v.advance(by: 5)
        t.equal(once, [15.75], "a one-shot fires once")

        // Foundation's shortest repeating interval (0.1 ms) for 0 or less: 10 ticks in a millisecond.
        var quick = 0
        let zero = v.timer(interval: 0, leeway: 0, repeats: true) { quick += 1 }
        v.runUntilIdle()
        t.equal(quick, 0, "a repeating timer with interval 0 is not due now")
        v.advance(by: 0.001)
        t.check((9...11).contains(quick), "0.1 ms apart: \(quick) ticks in 1 ms")
        zero.cancel()
    }

    t.suite("Executor: virtual time — a 0.1 s timer's k-th firing and an update at k × 100 ms / 1000 are one moment") {
        // Added up, 0.1 + 0.1 + 0.1 is 0.30000000000000004: the timer's 3rd firing would come after an update at
        // exactly 0.3 (how --render computes update i: Double(i) * interval / 1000), and the two ways of driving a skin
        // would order the same work differently. Due times are k intervals from the start, on a nanosecond grid.
        let v = virtualExecutor()
        var log: [String] = []
        var ticks = 0
        let timer = v.timer(interval: 0.1, leeway: 0, repeats: true) {
            ticks += 1
            log.append("tick \(ticks)")
        }
        for i in 1...10 {
            v.advance(until: Double(i) * 100 / 1000)
            log.append("update \(i)")
        }
        t.equal(log, (1...10).flatMap { ["tick \($0)", "update \($0)"] }, "each tick before the update at its moment")
        t.equal(v.now, 1, "time stands at exactly 1 s")
        // Many firings later there is no drift: the 1000th is at exactly 100 s, the time of update 1000.
        v.advance(until: 99.95)
        t.equal(ticks, 999)
        v.advance(until: 1000 * 100 / 1000)
        t.equal(ticks, 1000, "the 1000th firing is due at 100 s, not 99.9999999999986 or 100.00000000000142")
        timer.cancel()

        t.equal(VirtualTimeExecutor.onGrid(0.1 + 0.1 + 0.1), 0.3)
        t.equal(VirtualTimeExecutor.onGrid(0.3), 0.3, "on the grid already")
        t.equal(VirtualTimeExecutor.onGrid(2e6 + 0.1), 2e6 + 0.1, "far times as they are")
        t.check(VirtualTimeExecutor.onGrid(.infinity) == .infinity)
    }

    t.suite("Executor: virtual time — advance runs in (due, submission) order, setting the time before each") {
        let v = virtualExecutor()
        var log: [String] = []
        _ = v.async(after: 2) { log.append("b@\(v.now)") }
        _ = v.async(after: 1) {
            log.append("a@\(v.now)")
            // Queued meanwhile: due within the range, so it runs in this advance, in its place.
            _ = v.async(after: 0.5) { log.append("a2@\(v.now)") }
            v.async { log.append("a-now@\(v.now)") }
            // Due after the range: waits.
            _ = v.async(after: 5) { log.append("far@\(v.now)") }
        }
        _ = v.async(after: 2) { log.append("c@\(v.now)") }
        _ = v.timer(interval: 1.5, leeway: 0, repeats: false) { log.append("t@\(v.now)") }
        let ran = v.advance(by: 3)
        t.equal(log, ["a@1.0", "a-now@1.0", "t@1.5", "a2@1.5", "b@2.0", "c@2.0"])
        t.equal(ran, 6)
        t.equal(v.now, 3, "time stands at now + d")
        v.advance(by: 3)
        t.equal(log.last, "far@6.0")

        let before = v.now
        v.advance(by: -1)
        v.advance(by: .nan)
        v.advance(by: .infinity)
        t.equal(v.now, before, "a negative or non-finite step does not move time")
        v.advance(until: 1)
        t.equal(v.now, before, "nor does a time in the past")

        // Not re-entrant: stepping from inside its own work does nothing.
        var inner = -1
        v.async { inner = v.advance(by: 100) + v.runUntilIdle() }
        v.runUntilIdle()
        t.equal(inner, 0)
        t.equal(v.now, before)
    }

    t.suite("Executor: virtual time — work that queues itself without end stops the step") {
        let v = virtualExecutor()
        var count = 0
        func again() {
            count += 1
            v.async { again() }
        }
        v.async { again() }
        v.runUntilIdle()
        t.equal(count, VirtualTimeExecutor.maxWorkPerStep)
        t.check(v.overran, "the step says it stopped early")
    }

    t.suite("Executor: virtual time — hops from other threads queue in the order they were posted") {
        let v = virtualExecutor()
        let skin = try virtualSkin(t, "[M]\nMeter=Image\n", executor: v)
        let hop = skin.hop()
        var order: [Int] = []
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            hop.post { order.append(1) }
            first.signal()
        }
        first.wait()
        DispatchQueue.global().async {
            hop.post { order.append(2) }
            second.signal()
        }
        second.wait()
        v.async { order.append(3) }
        t.equal(order, [], "posted, not run")
        v.runUntilIdle()
        t.equal(order, [1, 2, 3], "due now, in the order they were posted")
        skin.close()
    }

    t.suite("Executor: virtual time — queued hops do not retain an abandoned executor") {
        weak var weakExecutor: VirtualTimeExecutor?
        weak var weakSkin: Skin?
        weak var captured: Token?
        let calls = Recorder<String>()
        func makeHop() throws -> SkinHop {
            let v = virtualExecutor()
            weakExecutor = v
            let skin = try virtualSkin(t, "[Rainmeter]\nUpdate=-1\n[M]\nMeter=Image\n", executor: v)
            weakSkin = skin
            let hop = skin.hop()
            skin.close()
            return hop
        }
        var hop: SkinHop? = try makeHop()
        t.check(weakSkin == nil, "the pending result does not own the unloaded skin")
        t.check(weakExecutor != nil, "the hop keeps its destination until it posts")
        func postResult() {
            let token = Token()
            captured = token
            hop?.post({ withExtendedLifetime(token) { calls.add("work") } },
                      orElse: { withExtendedLifetime(token) { calls.add("dropped") } })
        }
        postResult()
        t.equal(weakExecutor?.pendingCount, 1)
        t.check(captured != nil, "the queued result owns its captures")
        hop = nil
        t.check(weakExecutor == nil, "an executor without an owner is released without a virtual-time step")
        t.check(captured == nil, "its unstepped queue releases the result's captures too")
        t.equal(calls.values, [], "destroying an abandoned queue does not run either callback")
        // Release a regressed queue after recording the failure, so this canary itself does not leave a leak.
        weakExecutor?.runUntilIdle()
        t.check(weakExecutor == nil && captured == nil)
    }

    t.suite("Executor: virtual time — owned hops preserve FIFO and drop on the owner thread") {
        let v = virtualExecutor()
        let ownerThread = pthread_self()
        var skin: Skin? = try virtualSkin(t, "[Rainmeter]\nUpdate=-1\n[M]\nMeter=Image\n", executor: v)
        weak var weakSkin: Skin?
        weakSkin = skin
        let hop = skin!.hop()
        let order = Recorder<String>(), onOwner = Recorder<Bool>()
        func record(_ name: String) {
            order.add(name)
            onOwner.add(pthread_equal(ownerThread, pthread_self()) != 0)
        }
        func post(_ indices: ClosedRange<Int>) {
            let posted = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                for index in indices {
                    hop.post({ record("work \(index)") }, orElse: { record("dropped \(index)") })
                }
                posted.signal()
            }
            t.check(posted.wait(timeout: .now() + 60) == .success, "background results were handed over")
        }
        post(1...2)
        t.equal(order.values, [], "background posts never deliver inline")
        v.async { record("after work") }
        v.runUntilIdle()
        t.equal(order.values, ["work 1", "work 2", "after work"])
        skin?.close()
        skin = nil
        t.check(weakSkin == nil, "the remaining hop does not retain the skin")
        post(3...4)
        t.equal(order.values.count, 3, "dropped results wait for the owner too")
        v.async { record("after drops") }
        v.runUntilIdle()
        t.equal(order.values, ["work 1", "work 2", "after work", "dropped 3", "dropped 4", "after drops"])
        t.check(onOwner.values.count == 6 && onOwner.values.allSatisfy { $0 }, "every callback ran on the owner")
    }
}

// MARK: - The clock

private func runVirtualClockTests(_ t: TestRunner) {
    t.suite("Executor: virtual time — the clock: start + virtual time + offset") {
        let v = VirtualTimeExecutor(start: start, timeZone: utc, startUptime: 500)
        let clock = v.clock
        t.check(!clock.nowIsLive && !clock.uptimeIsLive && !clock.timeZoneIsLive)
        t.equal(clock.now(), start)
        t.equal(clock.uptime(), 500)
        v.advance(by: 90)
        t.equal(clock.now(), start.addingTimeInterval(90))
        t.equal(clock.uptime(), 590)
        v.setWallClock(start.addingTimeInterval(86_400))
        t.equal(clock.now(), start.addingTimeInterval(86_400), "a jump of the wall clock")
        t.equal(v.wallClockOffset, 86_310)
        t.equal(clock.uptime(), 590, "does not move the monotonic clock")
        t.equal(v.now, 90, "nor the queue's time")
        v.advance(by: 10)
        t.equal(clock.now(), start.addingTimeInterval(86_410), "the offset stays as time goes on")
        v.wallClockOffset = .nan
        t.equal(v.wallClockOffset, 86_310, "an offset that is not a number is ignored")
        v.wallClockOffset = 0
        t.equal(clock.now(), start.addingTimeInterval(100))
        v.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        t.equal(clock.timeZone().identifier, "Asia/Shanghai")
        t.equal(VirtualTimeExecutor(start: start, timeZone: utc).uptime, SteppedSkinClock.defaultUptime,
                "a Mac up for a day unless given")

        // What each piece of work sees is the time it was due.
        var seen: [Date] = []
        _ = v.async(after: 5) { seen.append(clock.now()) }
        _ = v.async(after: 2) { seen.append(clock.now()) }
        v.advance(by: 10)
        t.equal(seen, [start.addingTimeInterval(102), start.addingTimeInterval(105)])
    }

    t.suite("Executor: virtual time — a skin in virtual time reads the executor's clock") {
        let v = virtualExecutor()
        let skin = try virtualSkin(t, """
        [Rainmeter]
        Update=-1
        [Now]
        Measure=Time
        Format=%Y-%m-%d %H:%M:%S
        [M]
        Meter=Image
        """, executor: v)
        t.check(skin.executor === v)
        skin.update()
        t.equal(skin.measure(named: "Now")?.stringValue, "2026-09-28 09:00:00")
        t.equal(skin.clock(), SteppedSkinClock.defaultUptime)
        v.advance(by: 61)
        skin.update()
        t.equal(skin.measure(named: "Now")?.stringValue, "2026-09-28 09:01:01")
        t.equal(skin.clock(), SteppedSkinClock.defaultUptime + 61)
        skin.close()
    }
}

// MARK: - The engine in virtual time

private func runVirtualEngineTests(_ t: TestRunner) {
    t.suite("Executor: virtual time — !Delay waits in virtual time") {
        let v = virtualExecutor()
        let skin = try virtualSkin(t, "[M]\nMeter=Image\n", executor: v)
        skin.execute("[!SetVariable A 1][!Delay 1000][!SetVariable B 1][!Delay 0][!SetVariable C 1]", from: nil)
        t.equal(skin.variable("A"), "1")
        v.advance(by: 0.999)
        t.equal(skin.variable("B"), nil, "not before the second is over")
        v.advance(until: 1)
        t.equal(skin.variable("B"), "1", "a second later")
        t.equal(skin.variable("C"), nil)
        v.advance(by: 0.015)
        t.equal(skin.variable("C"), nil, "16 ms at least")
        v.advance(by: 0.005)
        t.equal(skin.variable("C"), "1")
        skin.execute("[!Delay 5000][!SetVariable D 1]", from: nil)
        skin.close()
        v.advance(by: 10)
        t.equal(skin.variable("D"), nil, "closing the skin cancels its delays")
    }

    t.suite("Executor: virtual time — ActionTimer steps at their own virtual times") {
        let v = virtualExecutor()
        let skin = try virtualSkin(t, """
        [Rainmeter]
        Update=-1
        [Timer]
        Measure=Plugin
        Plugin=ActionTimer
        ActionList1=A | Wait 100 | B | Wait 250 | C
        A=[!SetVariable A 1]
        B=[!SetVariable B 1]
        C=[!SetVariable C 1]
        IgnoreWarnings=1
        [M]
        Meter=Image
        """, executor: v)
        skin.execute("[!CommandMeasure Timer \"Execute 1\"]", from: nil)
        t.equal(skin.variable("A"), nil, "the first step runs after the action that started it")
        // The virtual time at which each step ran, stepping from one due time to the next.
        var at: [String: TimeInterval] = [:]
        func note() {
            for name in ["A", "B", "C"] where at[name] == nil && skin.variable(name) != nil { at[name] = v.now }
        }
        for _ in 0..<20 {
            v.runUntilIdle()
            note()
            guard let next = v.nextDue else { break }
            v.advance(until: next)
            note()
        }
        t.close(at["A"] ?? -1, 0, accuracy: 1e-9)
        t.close(at["B"] ?? -1, 0.1, accuracy: 1e-9, "Wait 100")
        t.close(at["C"] ?? -1, 0.35, accuracy: 1e-9, "then Wait 250")
        t.equal(v.pendingCount, 0, "and nothing is left")
        skin.close()
    }
}

// MARK: - Background work

private func runBackgroundWorkTests(_ t: TestRunner) {
    t.suite("Executor: virtual time — unfaked work defaults to real delivery and can be blocked") {
        for allowed in [true, false] {
            let v = virtualExecutor()
            t.check(v.background.allowsUnfakedWork, "a new executor keeps the existing live fallback")
            if !allowed { v.background.allowsUnfakedWork = false }
            t.equal(v.background.allowsUnfakedWork, allowed)
            let skin = try virtualSkin(t, "[Rainmeter]\nUpdate=-1\n[M]\nMeter=Image\n", executor: v)
            var starts = 0
            var deliver: ((Int) -> Void)?
            var results: [Int] = [], dropped: [Int] = []
            let job = BackgroundJob<Int>(.resMon, subject: "unfaked", start: {
                starts += 1
                deliver = $0
            })
            skin.startBackground(job, then: { results.append($0) }, orElse: { dropped.append($0) })
            t.equal(starts, allowed ? 1 : 0)
            t.equal(deliver != nil, allowed, "blocked work never enters the job's start closure")
            t.equal(v.background.outstanding, allowed ? 1 : 0)
            t.equal(v.background.settle(timeout: 0), !allowed, "only started work needs to settle")
            t.equal(results, [], "no typed result is invented")
            t.equal(dropped, [], "blocking has no result to hand to orElse either")
            deliver?(9)
            deliver = nil
            t.equal(results, [], "a real completion is still queued on the executor")
            v.runUntilIdle()
            t.equal(results, allowed ? [9] : [])
            t.equal(v.background.outstanding, 0)
            t.equal(v.background.unverifiable.map(\.kind), [.resMon])
            let reason = v.background.unverifiable.first?.reason ?? ""
            t.check(reason.contains(allowed ? "the real work ran" : "the job was not started"), reason)
            if !allowed { t.check(reason.contains("no completion is delivered"), reason) }
            t.check(v.background.reports.allSatisfy { !$0.faked }, "blocked work is never reported as a fake")
            skin.close()
            v.runUntilIdle()
            t.equal(dropped, [])
        }
    }

    t.suite("Executor: virtual time — strict verification blocks every unusable fake") {
        let v = virtualExecutor()
        v.background.allowsUnfakedWork = false
        let skin = try virtualSkin(t, "[Rainmeter]\nUpdate=-1\n[M]\nMeter=Image\n", executor: v)
        let elsewhere = t.temporaryDirectory("virtual-blocked-fixture").appendingPathComponent("data.txt")
        try "outside fixture".write(to: elsewhere, atomically: true, encoding: .utf8)
        let cases: [(kind: BackgroundWorkKind, fake: BackgroundFake?, inline: Bool, scripted: Bool,
                     reads: String?, reason: String)] = [
            (.resMon, nil, false, false, nil, "no fake"),
            (.ping, .script { _ in nil }, false, true, nil, "no scripted result for this request"),
            (.fileViewIcon, .value(.text("unused")), false, false, nil, "it cannot be scripted"),
            (.runCommandProcess, .script { _ in .text("unused") }, false, false, nil, "it cannot be scripted"),
            (.webParserPage, .fixture, false, true, nil, "no fixture"),
            (.quote, .fixture, true, false, elsewhere.path, "outside the skin's own"),
            (.folderInfo, .fixture, true, false, elsewhere.deletingLastPathComponent().path, "outside the skin's own"),
            (.fileViewListing, .fixture, true, false, elsewhere.deletingLastPathComponent().path, "outside the skin's own"),
        ]
        var started: [BackgroundWorkKind] = [], produced: [BackgroundWorkKind] = []
        var results: [String] = [], dropped: [String] = []
        for item in cases {
            v.background.setFake(item.fake, for: item.kind)
            let inline: (() -> String)? = item.inline ? { produced.append(item.kind); return "fixture" } : nil
            let scripted: ((BackgroundFakeValue) -> String)? = item.scripted
                ? { _ in produced.append(item.kind); return "scripted" } : nil
            let job = BackgroundJob<String>(item.kind, subject: item.kind.rawValue, start: {
                started.append(item.kind)
                $0("live")
            }, inline: inline, scripted: scripted, reads: item.reads)
            skin.startBackground(job, then: { results.append($0) }, orElse: { dropped.append($0) })
            t.equal(v.background.outstanding, 0, "\(item.kind) never starts real work")
            let report = v.background.unverifiable.first { $0.kind == item.kind }
            t.equal(report?.subject, item.kind.rawValue)
            t.check(report?.reason.contains(item.reason) == true, "\(String(describing: report))")
            t.check(report?.reason.contains("the job was not started and no completion is delivered") == true)
        }
        t.equal(started, [], "no live jobs ran; the closures only record calls")
        t.equal(produced, [], "unusable fakes do not produce a value either")
        t.equal(v.pendingCount, 0, "blocked requests schedule no invented completions")
        t.check(v.background.settle(timeout: 0))
        v.runUntilIdle()
        t.equal(results, [])
        t.equal(v.background.unverifiable.map(\.kind), cases.map(\.kind), "every missing input is reported in order")
        t.equal(v.background.reports.count, cases.count, "none of the blocked requests counts as faked")
        skin.close()
        v.runUntilIdle()
        t.equal(dropped, [])
    }

    t.suite("Executor: virtual time — strict verification delivers fixtures, scripts and fake services in order") {
        let v = virtualExecutor()
        v.background.allowsUnfakedWork = false
        v.background.setFake(.value(.text("value"), delay: 1), for: .ping)
        v.background.setFake(.script { $0.subject == "known" ? .text("script") : nil }, for: .runCommandProcess)
        v.background.setFake(.service, for: .weather)
        let skin = try virtualSkin(t, "[Rainmeter]\nUpdate=-1\n[M]\nMeter=Image\n",
                                   files: ["Root/Sub/input.txt": "fixture"], executor: v)
        let file = skin.directory.appendingPathComponent("input.txt")
        var unexpectedStarts = 0, fixtureRuns = 0, serviceStarts = 0
        var serviceResult: ((String) -> Void)?
        var results: [String] = []
        let fixture = BackgroundJob<String>(.quote, subject: file.path, start: { _ in unexpectedStarts += 1 },
                                            inline: {
                                                fixtureRuns += 1
                                                return (try? String(contentsOf: file, encoding: .utf8)) ?? "missing"
                                            }, reads: file.path)
        skin.startBackground(fixture) { results.append($0) }
        for (kind, subject) in [(BackgroundWorkKind.ping, "value"), (.runCommandProcess, "known")] {
            let job = BackgroundJob<String>(kind, subject: subject, start: { _ in unexpectedStarts += 1 },
                                            scripted: { $0.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "missing" })
            skin.startBackground(job) { results.append($0) }
        }
        let service = BackgroundJob<String>(.weather, subject: "injected service", start: {
            serviceStarts += 1
            serviceResult = $0
        })
        skin.startBackground(service) { results.append($0) }
        t.equal(unexpectedStarts, 0)
        t.equal(fixtureRuns, 0, "a fixture is still produced when the executor runs its completion")
        t.equal(serviceStarts, 1, "an explicitly injected service still starts")
        t.equal(v.background.outstanding, 1, "the fake service keeps its normal settle contract")
        serviceResult?("service")
        serviceResult = nil
        t.equal(results, [], "the service completion also waits for the executor")
        t.check(v.background.settle(timeout: 0))
        v.runUntilIdle()
        t.equal(results, ["fixture", "script", "service"], "completions due now retain their queue order")
        t.equal(fixtureRuns, 1)
        v.advance(until: 1)
        t.equal(results, ["fixture", "script", "service", "value"], "the scripted value retains its delay")
        t.equal(v.background.reports.map(\.kind), [.quote, .ping, .runCommandProcess, .weather])
        t.check(v.background.reports.allSatisfy(\.faked))
        t.equal(v.background.unverifiable, [])
        t.equal(v.background.outstanding, 0)
        skin.close()
    }

    t.suite("Executor: virtual time — a replacement icon service is independent of a held renderer") {
        let previous = virtualExecutor(), replacement = virtualExecutor()
        for executor in [previous, replacement] {
            executor.background.allowsUnfakedWork = false
            executor.background.setFake(.service, for: .fileViewIcon)
        }
        let ini = """
        [Rainmeter]
        Update=-1
        [Files]
        Measure=Plugin
        Plugin=FileView
        Path=#CURRENTPATH#Items
        ShowDotDot=0
        [Icon]
        Measure=Plugin
        Plugin=FileView
        Path=[Files]
        Type=Icon
        IconPath=#CURRENTPATH#icon.png
        Disabled=1
        """
        let first = try virtualSkin(t, ini, files: ["Root/Sub/Items/first.txt": "first"], executor: previous)
        let second = try virtualSkin(t, ini, files: ["Root/Sub/Items/second.txt": "second"], executor: replacement)
        let savedRenderer = FileViewIcons.renderer
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let firstBytes = Data("original icon bytes".utf8), secondBytes = Data("replacement icon bytes".utf8)
        var released = false
        defer {
            if !released { release.signal() }
            t.check(previous.background.settle(timeout: 5), "the held request drains after release")
            t.check(replacement.background.settle(timeout: 5), "the replacement request drains")
            previous.runUntilIdle()
            replacement.runUntilIdle()
            first.close()
            second.close()
            FileViewIcons.renderer = savedRenderer
        }
        func request(_ skin: Skin, _ executor: VirtualTimeExecutor) -> FileViewMeasure? {
            skin.update()
            executor.runUntilIdle()
            t.equal(skin.measure(named: "Files")?.value, 1, "the real fixture listing has one source")
            guard let icon = skin.measure(named: "Icon") as? FileViewMeasure else {
                t.check(false, "the actual FileView child is installed")
                return nil
            }
            icon.setDisabled(false)
            icon.readOptionsIfNeeded()
            icon.performUpdate()
            return icon
        }
        FileViewIcons.renderer = { _, _, _ in
            entered.signal()
            release.wait()
            return firstBytes
        }
        guard let firstIcon = request(first, previous) else { return }
        let firstEntered = entered.wait(timeout: .now() + 5) == .success
        t.check(firstEntered, "the previous renderer entered before replacement")
        guard firstEntered else { return }
        t.equal(previous.background.outstanding, 1, "one original request is held")
        t.equal(firstIcon.stringValue, "", "the held request has not published")

        FileViewIcons.renderer = { _, _, _ in secondBytes }
        guard let secondIcon = request(second, replacement) else { return }
        let finished = replacement.background.settle(timeout: 5)
        t.check(finished, "a replacement service completes while the previous renderer is still held")
        t.equal(previous.background.outstanding, 1, "finishing the replacement does not release the previous request")
        t.equal(secondIcon.stringValue, "", "completion still waits for the replacement owner")
        if finished {
            replacement.runUntilIdle()
            t.equal(try Data(contentsOf: URL(fileURLWithPath: secondIcon.stringValue)), secondBytes)
            t.equal(replacement.background.outstanding, 0)
            t.equal(replacement.background.unverifiable, [])
        }
        release.signal()
        released = true
        t.check(previous.background.settle(timeout: 5))
        t.check(replacement.background.settle(timeout: 5))
        previous.runUntilIdle()
        replacement.runUntilIdle()
        t.equal(try Data(contentsOf: URL(fileURLWithPath: firstIcon.stringValue)), firstBytes,
                "the earlier request retains its captured renderer")
        t.equal(try Data(contentsOf: URL(fileURLWithPath: secondIcon.stringValue)), secondBytes,
                "the replacement publishes its own bytes")
        t.equal(previous.background.unverifiable, [])
    }

    t.suite("Executor: virtual time — background work: fixtures, scripted results, work without a fake") {
        let v = virtualExecutor()
        let savedRenderer = FileViewIcons.renderer
        var iconWrites = 0
        FileViewIcons.renderer = { _, _, _ in
            iconWrites += 1
            return Data("icon".utf8)
        }
        defer { FileViewIcons.renderer = savedRenderer }
        v.background.setFake(.value(.number(42)), for: .ping)
        v.background.setFake(.value(.text("saved")), for: .fileViewIcon)
        let skin = try virtualSkin(t, """
        [Rainmeter]
        Update=-1
        [Quote]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=#CURRENTPATH#quotes.txt
        [Info]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=#CURRENTPATH#Folder
        InfoType=FileCount
        [View]
        Measure=Plugin
        Plugin=FileView
        Path=#CURRENTPATH#Folder
        ShowDotDot=0
        FinishAction=[!SetVariable Listed 1]
        [Icon]
        Measure=Plugin
        Plugin=FileView
        Path=[View]
        Type=Icon
        [Res]
        Measure=Plugin
        Plugin=ResMon
        ResCountType=Handle
        ProcessName=launchd
        [Ping]
        Measure=Plugin
        Plugin=PingPlugin
        DestAddress=192.0.2.1
        FinishAction=[!SetVariable Pinged 1]
        """, files: ["Root/Sub/quotes.txt": "alpha", "Root/Sub/Folder/a.txt": "a", "Root/Sub/Folder/b.txt": "b"],
            executor: v)
        skin.update()
        let quote = skin.measure(named: "Quote") as! QuoteMeasure
        let info = skin.measure(named: "Info") as! FolderInfoMeasure
        let view = skin.measure(named: "View") as! FileViewMeasure
        let res = skin.measure(named: "Res") as! ResMonMeasure
        let ping = skin.measure(named: "Ping") as! PingMeasure
        t.check(quote.isLoading && info.isScanning && ping.isPinging && res.knownProcessIDs == nil,
                "nothing is applied before the executor runs it")
        t.equal(v.background.outstanding, 1, "only ResMon, which has no fake, runs on a real thread")
        t.check(v.background.settle(timeout: 60), "settle waits for it (a condition, not a time)")
        t.equal(v.background.outstanding, 0)
        t.equal(quote.itemCount, 0, "handed back to the executor, still not applied")
        v.runUntilIdle()
        t.equal(quote.itemCount, 1, "Quote: a fixture, read from the files on disk")
        t.equal(info.latestResult.files, 2, "FolderInfo: a fixture")
        t.equal(skin.variable("Listed"), "1", "FileView: a fixture")
        t.equal(view.value, 2)
        t.check(res.knownProcessIDs != nil, "ResMon: the real work, back as ordinary work")
        t.check(!ping.isPinging)
        t.equal(ping.value, 42, "Ping: the scripted 42 ms (a documentation address, never reached)")
        t.equal(skin.variable("Pinged"), "1")
        let icon = skin.measure(named: "Icon") as! FileViewMeasure
        t.equal(icon.stringValue, skin.directory.appendingPathComponent("icon1.ico").path,
                "FileView's icon: scripted, in the same step (queued for now by the listing)")
        t.equal(iconWrites, 0, "the system's icons were never asked for")

        let reports = v.background.reports
        func report(_ kind: BackgroundWorkKind) -> BackgroundWorkReport? { reports.first { $0.kind == kind } }
        t.equal(report(.quote)?.faked, true)
        t.equal(report(.folderInfo)?.faked, true)
        t.equal(report(.fileViewListing)?.faked, true)
        t.equal(report(.ping)?.faked, true)
        t.equal(report(.fileViewIcon)?.faked, true)
        t.equal(report(.resMon)?.faked, false)
        t.equal(v.background.unverifiable.map(\.kind), [.resMon], "the skin cannot be verified because of ResMon")
        t.equal(v.background.unverifiable.first?.config, "Root\\Sub")
        t.check(v.background.unverifiable.first?.description.contains("ResMon") == true)
        skin.close()
    }

    t.suite("Executor: virtual time — fixtures read only the skin's own files and the folders the host brings") {
        // A launcher that lists the user's Downloads, a FolderInfo on it: live data that changes between runs, so it
        // is not a fixture (it runs for real and is reported); the skin's own files are.
        let elsewhere = t.temporaryDirectory("virtual-user-files")
        try Data("x".utf8).write(to: elsewhere.appendingPathComponent("a.txt"))
        try "one|two".write(to: elsewhere.appendingPathComponent("quotes.txt"), atomically: true, encoding: .utf8)
        let ini = """
        [Rainmeter]
        Update=-1
        [Own]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=#@#quotes.txt
        [User]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=\(elsewhere.path)/quotes.txt
        Separator=|
        [Info]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=\(elsewhere.path)
        InfoType=FileCount
        [M]
        Meter=Image
        """
        let v = virtualExecutor()
        let skin = try virtualSkin(t, ini, files: ["Root/@Resources/quotes.txt": "alpha"], executor: v)
        skin.update()
        t.check(v.background.settle(timeout: 60))
        v.runUntilIdle()
        t.equal(skin.measure(named: "Own")?.stringValue, "alpha", "the skin's @Resources: a fixture")
        t.check(["one", "two"].contains(skin.measure(named: "User")?.stringValue ?? ""), "the user's file is still read")
        t.equal((skin.measure(named: "Info") as? FolderInfoMeasure)?.latestResult.files, 2)
        let reports = v.background.reports
        t.equal(reports.filter { $0.kind == .quote }.map(\.faked), [true, false], "own file faked, the user's not")
        t.equal(v.background.unverifiable.map(\.kind), [.quote, .folderInfo])
        t.check(v.background.unverifiable.allSatisfy { $0.reason.contains("outside the skin's own") },
                "\(v.background.unverifiable)")
        skin.close()

        // A folder the host brings along (a render's data or settings folder) counts as the skin's own.
        let allowed = virtualExecutor()
        allowed.background.allowFixtureReads(under: elsewhere)
        let again = try virtualSkin(t, ini, files: ["Root/@Resources/quotes.txt": "alpha"], executor: allowed)
        again.update()
        allowed.runUntilIdle()
        t.equal(allowed.background.unverifiable.count, 0, "\(allowed.background.unverifiable)")
        t.equal((again.measure(named: "Info") as? FolderInfoMeasure)?.latestResult.files, 2)
        // Work that reads no file yet (Chameleon before its image has a path) is a fixture as before.
        var nothing: String?
        again.startBackground(BackgroundJob<String>(.desktopImage, subject: "", start: { _ in nothing = "real" },
                                                    inline: { "fixture" }, reads: "")) { nothing = $0 }
        allowed.runUntilIdle()
        t.equal(nothing, "fixture")
        t.equal(allowed.background.unverifiable.count, 0)
        again.close()
    }

    t.suite("Executor: virtual time — a fake's completion is due at the next runUntilIdle, or after its delay") {
        let v = virtualExecutor()
        let skin = try virtualSkin(t, "[M]\nMeter=Image\n", executor: v)
        var inlineRuns = 0
        var results: [String] = []
        let fixture = BackgroundJob<String>(.quote, subject: "a", start: { _ in results.append("real") },
                                            inline: {
                                                inlineRuns += 1
                                                return "fixture@\(v.now)"
                                            })
        skin.startBackground(fixture) { results.append($0) }
        t.equal(inlineRuns, 0, "a fixture does its work when its completion runs, not when it is asked for")
        v.runUntilIdle()
        t.equal(results, ["fixture@0.0"])
        t.equal(inlineRuns, 1)

        v.background.setFake(.value(.number(7), delay: 2.5), for: .ping)
        let scripted = BackgroundJob<Double>(.ping, subject: "host", start: { _ in results.append("real") },
                                             scripted: { $0.number ?? -1 })
        skin.startBackground(scripted) { results.append("ping \($0)@\(v.now)") }
        v.runUntilIdle()
        v.advance(by: 2.4)
        t.equal(results.count, 1, "not before its delay")
        v.advance(until: 2.5)
        t.equal(results.last, "ping 7.0@2.5", "the delay is virtual time")

        // A script decides per request; no value for one means no fake for it (the real work runs).
        v.background.setFake(.script { $0.subject == "known" ? .failure("down") : nil }, for: .ping)
        let known = BackgroundJob<Double>(.ping, subject: "known", start: { _ in results.append("real") },
                                          scripted: { $0.number ?? -1 })
        skin.startBackground(known) { results.append("known \($0)") }
        v.runUntilIdle()
        t.equal(results.last, "known -1.0", "a failure is what the kind makes of it")
        let unknown = BackgroundJob<Double>(.ping, subject: "unknown", start: { deliver in
            DispatchQueue.global().async { deliver(3) }
        }, scripted: { $0.number ?? -1 })
        skin.startBackground(unknown) { results.append("unknown \($0)") }
        t.check(v.background.settle(timeout: 60))
        v.runUntilIdle()
        t.equal(results.last, "unknown 3.0", "the real work's result, as ordinary work")
        t.equal(v.background.unverifiable.map(\.subject), ["unknown"])
        t.check(!results.contains("real"), "faked work never starts the real work")
        skin.close()
    }

    t.suite("Executor: virtual time — a result for a skin that is gone goes to orElse") {
        let v = virtualExecutor()
        var dropped: [Int] = []
        let release = DispatchSemaphore(value: 0)
        do {
            let skin = try virtualSkin(t, "[M]\nMeter=Image\n", executor: v)
            let job = BackgroundJob<Int>(.resMon, subject: "x", start: { deliver in
                DispatchQueue.global().async {
                    release.wait()
                    deliver(9)
                }
            })
            skin.startBackground(job, then: { _ in dropped.append(-1) }, orElse: { dropped.append($0) })
            skin.close()
        }
        release.signal()
        t.check(v.background.settle(timeout: 60))
        v.runUntilIdle()
        t.equal(dropped, [9], "the skin went first: the result is dropped, and orElse gets it")
    }

    t.suite("Executor: virtual time — services: a host's fake service, or not verifiable") {
        let v = virtualExecutor()
        v.background.setFake(.service, for: .weather)
        let skin = try virtualSkin(t, """
        [Rainmeter]
        Update=-1
        [Weather]
        Measure=Plugin
        Plugin=MacWeather
        Location=59.91,10.75
        [Sun]
        Measure=Plugin
        Plugin=MacSun
        Location=59.91,10.75
        [M]
        Meter=Image
        """, executor: v)
        skin.update()
        let reports = v.background.reports
        t.equal(reports.first { $0.kind == .weather }?.faked, true, "the weather service is the host's fake")
        t.equal(reports.first { $0.kind == .sun }?.faked, false, "MacSun's service was not declared a fake")
        skin.close()
    }

    t.suite("Executor: virtual time — RecycleManager's Trash reading is background work: scripted, faked or reported") {
        let trash = t.temporaryDirectory("virtual-trash")
        try Data("12345".utf8).write(to: trash.appendingPathComponent("a"))
        try Data("123".utf8).write(to: trash.appendingPathComponent("b"))
        let savedFolders = TrashMonitor.folders
        TrashMonitor.folders = { [trash.path] }
        defer { TrashMonitor.folders = savedFolders }
        TrashMonitor.shared.forget()
        let ini = """
        [Rainmeter]
        Update=-1
        [Count]
        Measure=RecycleManager
        [Size]
        Measure=RecycleManager
        RecycleType=Size
        [M]
        Meter=Image
        """

        // A scripted reading: it comes back as work due at the next runUntilIdle, never read from the Mac.
        let scripted = virtualExecutor()
        scripted.background.setFake(.value(.text("7 4096")), for: .trash)
        var skin = try virtualSkin(t, ini, executor: scripted)
        skin.update()
        t.equal(skin.measure(named: "Count")?.value, 0, "nothing yet: the reading comes back through the executor")
        scripted.runUntilIdle()
        t.equal(skin.measure(named: "Count")?.value, 7, "the first reading is shown as soon as it arrives")
        t.equal(skin.measure(named: "Size")?.value, 4096)
        t.equal(scripted.background.reports.first { $0.kind == .trash }?.faked, true)
        skin.close()

        // No fake: the real reading, reported as not verifiable; settle waits for it before the next update sees it.
        let live = virtualExecutor()
        skin = try virtualSkin(t, ini, executor: live)
        // Two updates: the count alone is read first, then the size (a reading without it is fresh for half a
        // second, as in live mode).
        for _ in 0..<2 {
            skin.update()
            t.check(live.background.settle(timeout: 60), "settle waits for the Trash reading")
            live.runUntilIdle()
        }
        skin.update()
        t.equal(skin.measure(named: "Count")?.value, 2, "the folder's two items")
        t.equal(skin.measure(named: "Size")?.value, 8)
        t.equal(live.background.unverifiable.first { $0.kind == .trash }?.config, "Root\\Sub", "reported")
        t.check(live.background.settle(timeout: 60))
        skin.close()

        // A Trash given as data (the host's fake service): no folder is read, and it counts as faked.
        TrashMonitor.folders = { t.check(false, "the Trash is not read"); return [] }
        RecycleManagerMeasure.useGivenTrash(.value(SkinInputData.Trash(count: 3, size: 100)))
        defer { RecycleManagerMeasure.useGivenTrash(nil) }
        let given = virtualExecutor()
        given.background.setFake(.service, for: .trash)
        skin = try virtualSkin(t, ini, executor: given)
        skin.update()
        t.check(given.background.settle(timeout: 60))
        given.runUntilIdle()
        t.equal(skin.measure(named: "Count")?.value, 3)
        t.equal(skin.measure(named: "Size")?.value, 100)
        t.equal(given.background.reports.first { $0.kind == .trash }?.faked, true, "the host's fake service")
        t.equal(given.background.unverifiable.count, 0)
        skin.close()
    }

    t.suite("Executor: virtual time — measures that read shared services are noted, faked only when scripted") {
        let ini = """
        [Rainmeter]
        Update=-1
        [CPU]
        Measure=CPU
        [Battery]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Percent
        [Disabled]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=cpu
        Disabled=1
        [Up]
        Measure=Uptime
        SecondsValue=100
        [M]
        Meter=Image
        """
        // The Mac's readings (a fake source here, but not scripted data): the skin cannot be verified.
        let live = virtualExecutor()
        var skin = try virtualSkin(t, ini, executor: live)
        skin.update()
        t.equal(live.background.unverifiable.map(\.kind), [.system, .battery],
                "the CPU and the battery; not a disabled measure, nor an Uptime given its seconds")
        t.check(live.background.unverifiable.allSatisfy { $0.reason == "the service is not faked" })
        skin.close()

        // Scripted system data that gives the frames: those reads are faked; the battery it does not give is not.
        let scripted = virtualExecutor()
        var data = SkinInputData()
        var frame = SkinInputData.SystemFrame()
        frame.cpu = [25]
        data.system = [frame]
        let skins = t.temporaryDirectory("virtual-services").appendingPathComponent("Skins")
        let dir = skins.appendingPathComponent("Root/Sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ini.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        let host = FakeHost()
        skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"), skinsDirectory: skins,
                    system: ScriptedSystemData(base: FakeSystem(), data: data), host: host)
        skin.runInVirtualTime(scripted)
        try skin.load()
        skin.update()
        t.equal(skin.measure(named: "CPU")?.value, 25)
        t.equal(scripted.background.reports.first { $0.kind == .system }?.faked, true, "the frames stand in for the Mac")
        t.equal(scripted.background.unverifiable.map(\.kind), [.battery])
        // A host's fake service counts too.
        scripted.background.setFake(.service, for: .battery)
        let again = try virtualSkin(t, ini, executor: scripted)
        again.update()
        t.equal(scripted.background.reports.filter { $0.kind == .battery && $0.config == again.config }.map(\.faked),
                [false, true], "the first skin's report stays; this one's is faked")
        withExtendedLifetime(host) { skin.close() }
        again.close()
    }

    t.suite("Executor: virtual time — live executors keep today's way back") {
        // The main executor: the real work on its queue, the result through the hop, nothing reported anywhere.
        let skin = try virtualSkin(t, "[M]\nMeter=Image\n", executor: nil)
        var result: String?
        var started = false
        let job = BackgroundJob<String>(.quote, subject: "a", start: { deliver in
            started = true
            DispatchQueue.global().async { deliver("live") }
        }, inline: { "fixture" })
        skin.startBackground(job) { result = $0 }
        t.check(started, "the real work starts at once")
        t.equal(result, nil, "never inline")
        t.check(spin { result != nil })
        t.equal(result, "live", "live mode never uses a fixture")
        skin.close()
    }
}
