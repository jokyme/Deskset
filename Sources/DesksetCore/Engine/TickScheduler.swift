import Foundation

/// The live facts and operations of a single update clock. Called on the target's executor.
package protocol TickTarget: AnyObject {
    var executor: SkinExecutor { get }
    var isClosed: Bool { get }
    var updateMilliseconds: Int { get }
    func updateForTick()
    func notifySystemWake()
}

/// A single runtime's update clock. Owner confined; the timer holds its target weakly. Thread executors keep using
/// their shared deadline scheduler, while other executors keep their own timer backend.
package final class TickScheduler {
    private var timer: SkinScheduledWork?
    package var isPaused = false

    package init() {}

    deinit { timer?.cancel() }

    /// Negative Update means one update on load; a periodic update is at least 16 milliseconds.
    package static func updateInterval(_ milliseconds: Int) -> TimeInterval? {
        milliseconds < 0 ? nil : Double(max(milliseconds, 16)) / 1000
    }

    /// Ten percent slack, capped so slow skins still tick on time.
    package static func timerTolerance(_ interval: TimeInterval) -> TimeInterval {
        min(interval * 0.1, 0.5)
    }

    package func startTimer(for target: any TickTarget) {
        cancel()
        guard !target.isClosed, !isPaused, let interval = Self.updateInterval(target.updateMilliseconds) else { return }
        let update = { [weak target] in
            guard let target, !target.isClosed else { return }
            target.updateForTick()
        }
        let leeway = Self.timerTolerance(interval)
        if let executor = target.executor as? SkinThreadExecutor {
            timer = executor.updateScheduler.schedule(interval: interval, leeway: leeway, update)
        } else {
            timer = target.executor.timer(interval: interval, leeway: leeway, repeats: true, update)
        }
    }

    /// A reactive clock's next wall-clock boundary, computed from its immutable date input by the owner. It
    /// shares the cancellation lease with the legacy clock; a late callback samples once and rearms explicitly.
    package func startClockBoundary(after delay: TimeInterval, for target: any TickTarget) {
        cancel()
        guard !target.isClosed, !isPaused, delay.isFinite, delay > 0 else { return }
        timer = target.executor.timer(interval: delay, leeway: 0, repeats: false) { [weak target] in
            guard let target, !target.isClosed else { return }
            target.updateForTick()
        }
    }

    package func pause() {
        guard !isPaused else { return }
        isPaused = true
        cancel()
    }

    package func resume(updateNow: Bool, target: any TickTarget) {
        guard isPaused, !target.isClosed else { return }
        isPaused = false
        if updateNow && Self.updateInterval(target.updateMilliseconds) != nil { target.updateForTick() }
        // A synchronous update may pause, close or replace the executor. Read the target again when registering.
        startTimer(for: target)
    }

    package func wake(target: any TickTarget) {
        target.notifySystemWake()
        guard !target.isClosed else { return }
        if isPaused {
            resume(updateNow: true, target: target)
        } else if Self.updateInterval(target.updateMilliseconds) != nil {
            target.updateForTick()
        }
    }

    /// Cancellation does not introduce a terminal state: OnCloseAction keeps its existing synchronous reentry.
    package func cancel() {
        timer?.cancel()
        timer = nil
    }
}
