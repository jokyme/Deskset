import Foundation

// Clean-room implementation from the public manual only: https://docs.rainmeter.net/manual/plugins/actiontimer/

/// `Plugin=ActionTimer`: runs `ActionListN` ("Action | Wait 10 | Repeat Action, 5, 20") outside the update cycle.
///
/// Model (manual, with the judgment calls marked):
/// - `!CommandMeasure M "Execute N"` starts ActionListN; a list that is still running ignores Execute (a warning is
///   logged unless `IgnoreWarnings=1`); `Stop N` ends it at once so it can run again. Several lists run in parallel.
/// - Components are separated by `|`: an action name (the option holding the bangs), `Wait ms`, or
///   `Repeat Action, ms, count` (count executions with ms between them, none after the last one).
/// - The actions are "defined and executed exactly the same as any other Action option": `#Variables#` are replaced
///   when the measure reads its options, `[SectionVariables]` when the action runs. Like the plugin, the measure uses
///   the option values of its last option read, so a skin that `!SetVariable`s between steps has to `!UpdateMeasure`
///   the ActionTimer measure (with `DynamicVariables=1`) to see the new value — exactly what the manual prescribes.
///   The list itself is parsed when Execute runs (from the same values); no formulas in lists.
/// - Rainmeter runs the lists in a thread that posts each action to the skin. Here the steps run on timers of the
///   skin's executor, without leeway (on the main thread they are in the common modes, so they also run while a menu
///   is open): the first step runs right after the action that sent Execute (never inside it), consecutive actions
///   without a Wait run back to back, and each Wait is measured from the previous step's *scheduled* time, so a long
///   animation does not drift. A step that is more than `maxLag` late (a busy thread) restarts the schedule from now
///   instead of firing the missed steps in a burst.
/// - Judgment: `Wait` values ≤ 0 are no wait; at most `maxStepsPerTurn` actions run in one run loop turn (a `Repeat X,
///   0, 100000` cannot freeze the app); commands work while the measure is disabled or paused (they only stop
///   updates). The measure's own value is 0.
/// - Refresh / unload (`skinWillClose`, or the measure being released) stops every list.
public final class ActionTimerMeasure: Measure, PluginLifecycle {
    enum Step: Equatable {
        case action(String)
        case wait(Double)
        case `repeat`(action: String, wait: Double, count: Int)
    }

    /// Option values as of the last option read, keyed by lowercased option name.
    private var snapshot: [String: String] = [:]
    private var snapshotTaken = false
    private var ignoreWarnings = false
    private var runs: [Int: Run] = [:]
    private var nextRunID = 0
    private var closed = false
    private var reported: Set<String> = []

    /// Late steps beyond this restart the schedule (seconds).
    static let maxLag: TimeInterval = 0.1
    static let maxStepsPerTurn = 64
    static let maxWait: Double = 86_400_000
    static let maxRepeat = 10_000_000

    /// Monotonic clock (seconds); tests may replace it.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private final class Run {
        let id: Int
        let list: Int
        let steps: [Step]
        var index = 0
        /// Executions of the current Repeat step already done.
        var repeatDone = 0
        /// Scheduled time of the next step.
        var deadline: TimeInterval
        var timer: SkinScheduledWork?

        init(id: Int, list: Int, steps: [Step], start: TimeInterval) {
            self.id = id
            self.list = list
            self.steps = steps
            deadline = start
        }
    }

    deinit {
        for run in runs.values { run.timer?.cancel() }
    }

    /// Numbers of the lists currently running (tests, diagnostics).
    public var runningLists: [Int] { runs.keys.sorted() }

    // MARK: Options

    public override func readMeasureOptions() {
        takeSnapshot()
    }

    /// Stores every option of the section: ActionListN resolved like any option (they may use section variables with
    /// DynamicVariables=1), everything else as an action option (`#Variables#` only).
    private func takeSnapshot() {
        ignoreWarnings = bool("IgnoreWarnings", false)
        var keys: [String] = own.entries.map { $0.key }
        keys += overrides.keys
        var values: [String: String] = [:]
        values.reserveCapacity(keys.count)
        for key in keys {
            let lower = key.lowercased()
            if values[lower] != nil { continue }
            if lower.hasPrefix("actionlist") {
                values[lower] = option(key) ?? ""
            } else {
                values[lower] = actionOption(key)
            }
        }
        snapshot = values
        snapshotTaken = true
    }

    // MARK: Parsing

    /// Parses an ActionList value. Component keywords are case-insensitive; `Wait`/`Repeat` followed by something that
    /// is not their syntax is read as an action name.
    static func parse(_ list: String) -> [Step] {
        var steps: [Step] = []
        for part in list.split(separator: "|", omittingEmptySubsequences: true) {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let lower = text.lowercased()
            if lower.hasPrefix("wait"), let ms = number(text.dropFirst(4)), text.dropFirst(4).first?.isWhitespace ?? false {
                steps.append(.wait(min(max(ms, 0), maxWait)))
                continue
            }
            if lower.hasPrefix("repeat"), text.dropFirst(6).first?.isWhitespace ?? false {
                let fields = text.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if let name = fields.first, !name.isEmpty {
                    let wait = fields.count > 1 ? (number(Substring(fields[1])) ?? 0) : 0
                    let count = fields.count > 2 ? (number(Substring(fields[2])) ?? 1) : 1
                    steps.append(.repeat(action: name, wait: min(max(wait, 0), maxWait),
                                         count: Int(min(max(count, 0), Double(maxRepeat)))))
                    continue
                }
            }
            steps.append(.action(text))
        }
        return steps
    }

    /// A plain number (no formulas in ActionLists); nil when the text is not one.
    private static func number(_ text: Substring) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    // MARK: Commands

    public override func execute(command: String) {
        let parts = command.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let verb = parts.first?.lowercased() else { return }
        let number = parts.count > 1 ? Int(parts[1]) : nil
        switch verb {
        case "execute":
            guard let number, number >= 1 else {
                skin.log("ActionTimer [\(name)]: \"\(command)\" needs an ActionList number", level: .warning)
                return
            }
            start(list: number)
        case "stop":
            guard let number else {
                skin.log("ActionTimer [\(name)]: \"\(command)\" needs an ActionList number", level: .warning)
                return
            }
            stop(list: number)
        default:
            super.execute(command: command)
        }
    }

    private func start(list: Int) {
        guard !closed else { return }
        if runs[list] != nil {
            if !ignoreWarnings {
                skin.log("ActionTimer [\(name)]: ActionList\(list) is still running; Execute \(list) ignored",
                         level: .warning)
            }
            return
        }
        if !snapshotTaken { takeSnapshot() }
        guard let text = snapshot["actionlist\(list)"], !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            skin.log("ActionTimer [\(name)]: ActionList\(list) is not defined", level: .warning)
            return
        }
        let steps = ActionTimerMeasure.parse(text)
        guard !steps.isEmpty else { return }
        nextRunID += 1
        let run = Run(id: nextRunID, list: list, steps: steps, start: clock())
        runs[list] = run
        // The first step runs after the action that sent Execute has finished (the plugin posts it to the skin).
        schedule(run, at: run.deadline)
    }

    private func stop(list: Int) {
        guard let run = runs.removeValue(forKey: list) else { return }
        run.timer?.cancel()
        run.timer = nil
    }

    public func skinWillClose() {
        closed = true
        for run in runs.values { run.timer?.cancel() }
        runs = [:]
    }

    // MARK: Running

    private func schedule(_ run: Run, at time: TimeInterval) {
        run.timer?.cancel()
        let delay = max(0, time - clock())
        let id = run.id, list = run.list
        run.timer = skin.executor.timer(interval: delay, leeway: 0, repeats: false) { [weak self] in
            guard let self, let current = self.runs[list], current.id == id else { return }
            current.timer = nil
            self.advance(current)
        }
    }

    /// True while `run` is still the live run of its list (an action may have stopped or restarted it).
    private func isLive(_ run: Run) -> Bool {
        !closed && runs[run.list] === run
    }

    private func advance(_ run: Run) {
        var executed = 0
        while isLive(run) {
            guard run.index < run.steps.count else {
                runs[run.list] = nil
                return
            }
            if executed >= ActionTimerMeasure.maxStepsPerTurn {
                schedule(run, at: clock())   // yield to the run loop, continue on the next turn
                return
            }
            switch run.steps[run.index] {
            case .action(let actionName):
                run.index += 1
                executed += 1
                finishIfDone(run)
                perform(actionName)
            case .wait(let ms):
                run.index += 1
                if ms > 0 {
                    wait(run, ms)
                    return
                }
            case .repeat(let actionName, let ms, let count):
                if run.repeatDone >= count {
                    run.index += 1
                    run.repeatDone = 0
                    continue
                }
                run.repeatDone += 1
                executed += 1
                let lastRepetition = run.repeatDone >= count
                if lastRepetition {
                    run.index += 1
                    run.repeatDone = 0
                    finishIfDone(run)
                }
                perform(actionName)
                if !lastRepetition, ms > 0, isLive(run) {
                    wait(run, ms)
                    return
                }
            }
        }
    }

    /// Ends `run` before its last action runs when nothing (or only zero waits) follows, so that the action can
    /// `Execute` the same list again — the usual way to loop an animation. (The plugin's thread has finished the
    /// list by the time the skin handles the last posted action.)
    private func finishIfDone(_ run: Run) {
        let rest = run.steps[run.index...]
        let done = rest.allSatisfy { step in
            switch step {
            case .wait(let ms): return ms <= 0
            case .repeat(_, _, let count): return count <= 0
            case .action: return false
            }
        }
        if done && runs[run.list] === run { runs[run.list] = nil }
    }

    /// Next step `ms` after the previous step's scheduled time (drift-free), unless that is already far behind.
    private func wait(_ run: Run, _ ms: Double) {
        let now = clock()
        var next = run.deadline + ms / 1000
        if next < now - ActionTimerMeasure.maxLag { next = now }
        run.deadline = next
        schedule(run, at: next)
    }

    private func perform(_ actionName: String) {
        guard let action = snapshot[actionName.lowercased()] else {
            if reported.insert(actionName.lowercased()).inserted {
                skin.log("ActionTimer [\(name)]: action option \(actionName) is not defined", level: .warning)
            }
            return
        }
        if action.trimmingCharacters(in: .whitespaces).isEmpty { return }
        skin.execute(action, from: self)
    }
}
