import Foundation

/// A run loop's skin update clocks share one wake-up. Work is never early: the first deadline is one full interval
/// after registration, and a wake-up may be postponed only within every waiting clock's leeway. All clocks due at
/// that wake-up run in deadline order (registration order breaks ties), so their frames can be committed together.
///
/// Only periodic skin updates use this scheduler. Delays, plugin timers and background completions keep the executor's
/// usual ordering. A late clock fires once and skips missed periods; neither delays nor slow updates cause a burst.
/// Register work and read diagnostics on the executor. The returned work can be cancelled on any thread.
public final class SkinUpdateScheduler {
    private final class Entry {
        let order: UInt64
        let work: SkinScheduledWork
        let origin: TimeInterval
        let interval: TimeInterval
        let leeway: TimeInterval
        var tick = 1.0
        var deadline: TimeInterval { VirtualTimeExecutor.onGrid(origin + tick * interval) }

        init(order: UInt64, work: SkinScheduledWork, origin: TimeInterval,
             interval: TimeInterval, leeway: TimeInterval) {
            self.order = order
            self.work = work
            self.origin = origin
            self.interval = interval
            self.leeway = leeway
        }

        func advance(past now: TimeInterval) {
            tick = max(tick + 1, floor((now - origin) / interval) + 1)
            // Large uptimes can round a deadline down to now. Always leave it in the future.
            if deadline <= now { tick += 1 }
        }
    }

    private weak var executor: SkinExecutor?
    private let clock: SkinClock
    private var entries: [Entry] = []
    private var sequence: UInt64 = 0
    private var wake: SkinScheduledWork?
    private var wakeTime: TimeInterval?
    private var firing = false

    /// Actual wake-ups, for comparing separate and combined update clocks. Read on the executor.
    public private(set) var wakeCount = 0
    /// Live clocks, excluding cancellations that have not yet reached the executor.
    public var pendingCount: Int { entries.filter { $0.work.isPending }.count }

    public init(executor: SkinExecutor, clock: SkinClock = .live) {
        self.executor = executor
        self.clock = clock
    }

    deinit {
        wake?.cancel()
        for entry in entries { entry.work.cancel() }
    }

    /// Invalid intervals produce cancelled work. The owner must retain this scheduler for as long as its clocks run.
    public func schedule(interval: TimeInterval, leeway: TimeInterval,
                         _ fire: @escaping () -> Void) -> SkinScheduledWork {
        let work = SkinScheduledWork(repeats: true, fire)
        guard let executor, interval.isFinite, interval > 0 else {
            work.cancel()
            return work
        }
        assert(executor.isCurrent, "Register skin updates on their executor")
        let now = clock.uptime()
        guard now.isFinite, (now + interval).isFinite, now + interval > now else {
            work.cancel()
            return work
        }
        let interval = max(interval, 0.0001)
        let slack = leeway.isFinite ? max(0, min(leeway, interval)) : 0
        guard (now + interval + slack).isFinite else {
            work.cancel()
            return work
        }
        sequence &+= 1
        let order = sequence
        let entry = Entry(order: order, work: work, origin: now, interval: interval, leeway: slack)
        entries.append(entry)
        work.setCancelHandler { [weak self, weak executor] in
            guard let self, let executor else { return }
            if executor.isCurrent {
                self.remove(order)
            } else {
                executor.async { [weak self] in self?.remove(order) }
            }
        }
        reschedule()
        return work
    }

    private func remove(_ order: UInt64) {
        entries.removeAll { $0.order == order }
        reschedule()
    }

    private func reschedule() {
        guard !firing else { return }
        entries.removeAll { !$0.work.isPending }
        guard let executor, let next = entries.map({ $0.deadline + $0.leeway }).min() else {
            wake?.cancel()
            wake = nil
            wakeTime = nil
            return
        }
        if wakeTime == next, wake?.isPending == true { return }
        wake?.cancel()
        wakeTime = next
        wake = executor.async(after: max(0, next - clock.uptime())) { [weak self] in self?.fireDue() }
    }

    private func fireDue() {
        wake = nil
        wakeTime = nil
        wakeCount += 1
        firing = true
        let now = clock.uptime()
        let due = entries.filter { $0.work.isPending && $0.deadline <= now }.sorted {
            $0.deadline == $1.deadline ? $0.order < $1.order : $0.deadline < $1.deadline
        }
        for entry in due where entry.work.isPending {
            entry.work.fire()
            entry.advance(past: clock.uptime())
        }
        firing = false
        reschedule()
    }
}
