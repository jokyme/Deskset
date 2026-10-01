import Foundation
@testable import DesksetCore

func runSkinUpdateSchedulerTests(_ t: TestRunner) {
    func virtual() -> VirtualTimeExecutor {
        VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    t.suite("Executor: update clocks: nearby deadlines share one wake-up, never early") {
        let executor = virtual()
        let scheduler = SkinUpdateScheduler(executor: executor, clock: executor.clock)
        var fired: [Int] = []
        var times: [TimeInterval] = []
        var work: [SkinScheduledWork] = []
        for index in 0..<10 {
            work.append(scheduler.schedule(interval: 1, leeway: 0.1) {
                fired.append(index)
                times.append(executor.uptime - executor.startUptime)
            })
            executor.advance(by: 0.01)
        }
        t.equal(fired, [], "registration never fires inline")
        executor.advance(until: 1)
        t.equal(fired, [], "the scheduler uses the slack of the first deadline")
        executor.advance(until: 1.1)
        t.equal(fired, Array(0..<10), "every due clock, in deadline order")
        t.equal(scheduler.wakeCount, 1, "ten nearby clocks wake the executor once")
        for (index, time) in times.enumerated() {
            t.check(time + 1e-9 >= 1 + Double(index) * 0.01, "clock \(index) did not fire early")
            t.check(time <= 1.1 + Double(index) * 0.01 + 1e-9, "clock \(index) stayed inside its leeway")
        }
        executor.advance(until: 100.1)
        t.equal(fired.count, 1_000, "none skipped at the ordinary rate")
        t.equal(scheduler.wakeCount, 100, "one wake per second, without accumulating slack")
        for item in work { item.cancel() }
        t.equal(scheduler.pendingCount, 0)
        t.equal(executor.pendingCount, 0, "no wake-up remains when the last clock leaves")
    }

    t.suite("Executor: update clocks: a tighter deadline interrupts the waiting batch") {
        let executor = virtual()
        let scheduler = SkinUpdateScheduler(executor: executor, clock: executor.clock)
        var fired: [String] = []
        let slow = scheduler.schedule(interval: 1, leeway: 0.1) { fired.append("slow") }
        executor.advance(by: 0.05)
        let fast = scheduler.schedule(interval: 0.25, leeway: 0) { fired.append("fast") }
        executor.advance(until: 0.299)
        t.equal(fired, [])
        executor.advance(until: 0.3)
        t.equal(fired, ["fast"])
        executor.advance(until: 1.05)
        t.equal(fired, ["fast", "fast", "fast", "slow", "fast"],
                "the one-second clock joins the fast clock's wake after its own deadline")
        t.equal(scheduler.wakeCount, 4)
        fast.cancel()
        executor.advance(until: 2.1)
        t.equal(fired.last, "slow")
        t.equal(fired.count, 6)
        slow.cancel()
    }

    t.suite("Executor: update clocks: a late or slow clock fires once and keeps its original phase") {
        let executor = ManualExecutor()
        var now = 0.0
        let clock = SkinClock(now: { Date(timeIntervalSince1970: now) }, uptime: { now },
                              timeZone: { TimeZone(secondsFromGMT: 0)! })
        let scheduler = SkinUpdateScheduler(executor: executor, clock: clock)
        var fired = 0
        let work = scheduler.schedule(interval: 1, leeway: 0.1) {
            fired += 1
            if fired == 1 { now = 8.4 } // Work itself takes time too.
        }
        now = 5.2
        t.equal(executor.runPending(), 1)
        t.equal(fired, 1, "missed periods are not replayed")
        t.equal(executor.pending.count, 1)
        if case .after(let delay)? = executor.pending.first?.kind {
            t.close(delay, 0.7, "the next deadline is 9.1, not 9.5")
        } else { t.check(false, "one delayed wake") }
        now = 9.1
        executor.runPending()
        t.equal(fired, 2)
        work.cancel()
        t.equal(executor.pending.count, 0)
    }

    t.suite("Executor: update clocks: cancellation and registration inside a batch keep their order") {
        let executor = virtual()
        let scheduler = SkinUpdateScheduler(executor: executor, clock: executor.clock)
        var fired: [String] = []
        var first: SkinScheduledWork?
        var second: SkinScheduledWork?
        var next: SkinScheduledWork?
        first = scheduler.schedule(interval: 1, leeway: 0) {
            fired.append("first")
            first?.cancel()
            second?.cancel()
            next = scheduler.schedule(interval: 1, leeway: 0) { fired.append("next") }
        }
        second = scheduler.schedule(interval: 1, leeway: 0) { fired.append("cancelled") }
        executor.advance(by: 1)
        t.equal(fired, ["first"], "the next item was cancelled before it ran")
        t.equal(scheduler.pendingCount, 1)
        executor.advance(by: 1)
        t.equal(fired, ["first", "next"], "new clocks start a full interval after registration")
        next?.cancel()
        t.equal(executor.pendingCount, 0)
    }

    t.suite("Executor: update clocks: invalid intervals, short periods and releasing the scheduler") {
        let executor = virtual()
        var scheduler: SkinUpdateScheduler? = SkinUpdateScheduler(executor: executor, clock: executor.clock)
        var fired = 0
        for interval in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            t.check(scheduler!.schedule(interval: interval, leeway: 0) { fired += 1 }.isCancelled)
        }
        let small = scheduler!.schedule(interval: 0.1, leeway: 0) { fired += 1 }
        executor.advance(by: 10)
        t.equal(fired, 100, "decimal deadlines agree with the virtual executor's nanosecond grid")
        small.cancel()
        let remaining = scheduler!.schedule(interval: 1, leeway: 0) { fired += 1 }
        scheduler = nil
        t.check(remaining.isCancelled, "the scheduler releases its clocks")
        t.equal(executor.pendingCount, 0)
        executor.advance(by: 10)
        t.equal(fired, 100)
    }

    t.suite("Executor: update clocks: cancellation from another thread removes the shared wake") {
        let executor = SkinThreadExecutor(name: "Deskset update clock test")
        defer { executor.stop() }
        let scheduler = SkinUpdateScheduler(executor: executor)
        let registered = DispatchSemaphore(value: 0)
        let access = NSLock()
        var scheduled: SkinScheduledWork?
        executor.async {
            let work = scheduler.schedule(interval: 3600, leeway: 0) {}
            access.lock()
            scheduled = work
            access.unlock()
            registered.signal()
        }
        t.equal(registered.wait(timeout: .now() + 30), .success)
        access.lock()
        let work = scheduled
        access.unlock()
        work?.cancel()
        t.equal(executor.exclusive(timeout: 30) { scheduler.pendingCount }, 0)
        t.equal(executor.exclusive(timeout: 30) { scheduler.wakeCount }, 0)
    }
}
