import DesksetCore
import Foundation

/// Names a skin that holds its worker for more than two seconds, even while that worker cannot answer messages.
/// One shared timer checks all active skins once a second. Short work only changes a small locked record: ending
/// it leaves the timer for the next check to stop, so animated skins do not create a timer for every frame.
final class SkinWorkWatchdog {
    static let shared = SkinWorkWatchdog()
    static let threshold: TimeInterval = 2

    enum Kind: String {
        case work
        case drawing
    }

    struct Report: Equatable {
        let config: String
        let kind: Kind
        let duration: TimeInterval

        var message: String {
            "Skin worker busy for \(String(format: "%.0f", duration * 1000)) ms (\(kind.rawValue))"
        }
    }

    /// Owned by one skin's executor. The runtime, its Core entry points and its drawing share this nesting depth.
    /// The watchdog retains only the config and start time, never the activity, runtime or skin.
    final class Activity {
        private let watchdog: SkinWorkWatchdog
        private let config: String
        private var depth = 0

        init(watchdog: SkinWorkWatchdog, config: String) {
            self.watchdog = watchdog
            self.config = config
        }

        deinit { watchdog.abandon(ObjectIdentifier(self)) }

        func begin(_ kind: Kind = .work) {
            depth += 1
            if depth == 1 { watchdog.begin(ObjectIdentifier(self), config: config, kind: kind) }
        }

        func end() {
            precondition(depth > 0, "Skin work must end after it begins")
            depth -= 1
            if depth == 0 { watchdog.end(ObjectIdentifier(self)) }
        }
    }

    private struct Work {
        let config: String
        let kind: Kind
        let start: TimeInterval
        var reported = false
    }

    private struct State {
        var active: [ObjectIdentifier: Work] = [:]
        var timer: DispatchSourceTimer?
        var timerStarts = 0
    }

    private let state = Guarded(State())
    private let queue = DispatchQueue(label: "app.deskset.skin-watchdog", qos: .utility)
    private let clock: SkinClock
    private let automaticChecks: Bool
    private let report: (Report) -> Void

    /// A test can supply a thread-safe clock and call `check` itself, without waiting for real time.
    init(clock: SkinClock = .live, automaticChecks: Bool = true,
         report: @escaping (Report) -> Void = { Log.write($0.message, level: .warning, source: $0.config) }) {
        self.clock = clock
        self.automaticChecks = automaticChecks
        self.report = report
    }

    deinit { state.current.timer?.cancel() }

    private func begin(_ id: ObjectIdentifier, config: String, kind: Kind) {
        let now = clock.uptime()
        state.access { state in
            state.active[id] = Work(config: config, kind: kind, start: now)
            guard automaticChecks, state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.threshold, repeating: .seconds(1), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.check() }
            state.timer = timer
            state.timerStarts += 1
            timer.resume()
        }
    }

    private func end(_ id: ObjectIdentifier) {
        let now = clock.uptime()
        let ended = state.access { $0.active.removeValue(forKey: id) }
        // Work may end between checks. It still deserves one report if it crossed the limit, never a second one.
        if let ended, let report = Self.overdue(ended, at: now) { self.report(report) }
    }

    private func abandon(_ id: ObjectIdentifier) {
        _ = state.access { $0.active.removeValue(forKey: id) }
    }

    /// Checks immutable diagnostic facts only. Never reads a skin or calls its executor or the main thread.
    func check() {
        let now = clock.uptime()
        let reports = state.access { state -> [Report] in
            guard !state.active.isEmpty else {
                state.timer?.cancel()
                state.timer = nil
                return []
            }
            var reports: [Report] = []
            for (id, work) in state.active {
                if let report = Self.overdue(work, at: now) {
                    state.active[id]?.reported = true
                    reports.append(report)
                }
            }
            return reports
        }
        // Logging takes no watchdog lock; a test's reporter may inspect or start another activity too.
        for report in reports { self.report(report) }
    }

    private static func overdue(_ work: Work, at now: TimeInterval) -> Report? {
        let duration = now - work.start
        guard !work.reported, duration.isFinite, duration > threshold else { return nil }
        return Report(config: work.config, kind: work.kind, duration: duration)
    }

    // MARK: Diagnostics for self-tests

    var activeCount: Int { state.access { $0.active.count } }
    var hasTimer: Bool { state.access { $0.timer != nil } }
    var timerStarts: Int { state.access { $0.timerStarts } }
}
