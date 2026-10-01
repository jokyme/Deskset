import Foundation

/// The numerical and action state of one measure, confined to the skin's owner. Synchronous hooks or actions may
/// reenter this measure; each call uses the same state at the original read/write points. The measure and the
/// non-escaping action callback are call arguments only; the pipeline keeps neither of them.
final class MeasurePipeline {
    // MARK: - Numerical values

    private var history: [Double] = []
    private var historyNext = 0
    /// MinValue / MaxValue as written (nil = not set), already scaled by `rangeOptionScale`.
    private var minValueOption: Double?
    private var maxValueOption: Double?
    private var observedMin: Double?
    private var observedMax: Double?
    private var warnedAboutRange = false

    func readValueOptions(for measure: Measure) {
        let scale = measure.rangeOptionScale
        minValueOption = measure.allowsMinValueOption ? measure.optionalDouble("MinValue").map { $0 * scale } : nil
        maxValueOption = measure.allowsMaxValueOption ? measure.optionalDouble("MaxValue").map { $0 * scale } : nil
        measure.refreshRange()
        measure.invert = measure.allowsInvert && measure.bool("InvertMeasure", false)
        let size = measure.allowsAverage ? measure.int("AverageSize", 1) : 1
        measure.averageSize = min(max(size, 0), Measure.maxAverageSize)
        if measure.averageSize <= 1 || history.count > measure.averageSize {
            history = []
            historyNext = 0
        }
    }

    func refreshRange(for measure: Measure) {
        if let minValueOption {
            measure.minValue = minValueOption
        } else if measure.tracksValueRange, let observedMin {
            measure.minValue = Swift.min(measure.automaticMinValue, observedMin)
        } else {
            measure.minValue = measure.automaticMinValue
        }
        if let maxValueOption {
            measure.maxValue = maxValueOption
        } else if measure.tracksValueRange, let observedMax {
            measure.maxValue = Swift.max(measure.automaticMaxValue, observedMax)
        } else {
            measure.maxValue = measure.automaticMaxValue
        }
        if measure.maxValue < measure.minValue && !warnedAboutRange {
            warnedAboutRange = true
            measure.skin.log("[\(measure.name)] MaxValue is less than MinValue", level: .debug)
        }
    }

    func finishValue(_ rawValue: Double, for measure: Measure) {
        var v = rawValue
        if !v.isFinite { v = 0 }
        let placeholder = measure.computedPlaceholder
        if measure.averageSize > 1 && !placeholder {
            if history.count < measure.averageSize {
                history.append(v)
            } else {
                history[historyNext % history.count] = v
            }
            historyNext = (historyNext + 1) % measure.averageSize
            v = history.reduce(0, +) / Double(history.count)
        }
        if measure.tracksValueRange && !placeholder {
            observedMin = Swift.min(observedMin ?? v, v)
            observedMax = Swift.max(observedMax ?? v, v)
        }
        measure.refreshRange()
        if measure.invert && !placeholder { v = measure.maxValue - (v - measure.minValue) }
        measure.value = v.isFinite ? v : 0
    }

    func runtimeSnapshot(for measure: Measure) -> SkinRuntimeState.MeasureState {
        SkinRuntimeState.MeasureState(
            type: measure.type, kind: String(describing: Swift.type(of: measure)), own: measure.own, value: measure.value, rawString: measure.rawString,
            average: measure.averageSize > 1 && !history.isEmpty
                ? SkinRuntimeState.Average(samples: history, next: historyNext) : nil,
            observedMin: observedMin, observedMax: observedMax, webParser: nil)
    }

    func seed(_ state: SkinRuntimeState.MeasureState, for measure: Measure) {
        measure.value = state.value.isFinite ? state.value : 0
        measure.rawString = state.rawString
        if let average = state.average, measure.averageSize > 1, !average.samples.isEmpty,
           average.samples.count <= measure.averageSize {
            history = average.samples
            historyNext = min(max(average.next, 0), measure.averageSize - 1)
        }
        if measure.tracksValueRange {
            observedMin = state.observedMin
            observedMax = state.observedMax
            measure.refreshRange()
        }
    }

    // MARK: - Actions

    private struct Condition {
        /// N of `IfConditionN` (1 for `IfCondition`): the "became true/false" state belongs to the option, so a
        /// dynamic formula whose text changes keeps its state.
        var index: Int
        var formula: CompiledFormula?
        var source: String
        var trueAction: String
        var falseAction: String
        var lastResult: Bool?
        var loggedError = false
    }
    private var conditions: [Condition] = []
    private var ifConditionMode = false

    private struct Threshold {
        var value: Double
        var action: String
        var active = false
    }
    private var ifAbove: Threshold?
    private var ifBelow: Threshold?
    private var ifEqual: Threshold?

    private struct Match {
        /// N of `IfMatchN` (state kept when a dynamic pattern changes).
        var index: Int
        var pattern: String
        var matchAction: String
        var notMatchAction: String
        var lastResult: Bool?
        var loggedError = false
    }
    private var matches: [Match] = []
    private var ifMatchMode = false

    private var onUpdateAction = ""
    private var onChangeAction = ""
    private var lastValue: Double?
    private var lastString: String?

    func readOptions(for measure: Measure) {
        readConditions(for: measure)
        readThresholds(for: measure)
        readMatches(for: measure)
        onUpdateAction = measure.actionOption("OnUpdateAction")
        onChangeAction = measure.actionOption("OnChangeAction")
    }

    private func readConditions(for measure: Measure) {
        ifConditionMode = measure.bool("IfConditionMode", false)
        let sources = measure.numberedOptions("IfCondition")
        var result: [Condition] = []
        for (index, source) in sources {
            let suffix = index == 1 ? "" : String(index)
            let existing = conditions.first { $0.index == index }
            var condition = existing
                ?? Condition(index: index, formula: nil, source: source, trueAction: "", falseAction: "", lastResult: nil)
            let blank = source.trimmingCharacters(in: .whitespaces).isEmpty
            if existing == nil || condition.source != source {
                condition.source = source
                condition.formula = blank ? nil : try? Formula.compile(source)
            }
            // Logged once per condition: a dynamic condition whose text changes on every update would otherwise
            // log on every update. An empty IfCondition is simply ignored; one whose section variables are not
            // resolved yet (read at load) is checked at the first update.
            if condition.formula == nil && !blank && !condition.loggedError
                && !measure.awaitsSectionVariables("IfCondition\(suffix)") {
                condition.loggedError = true
                measure.skin.log("[\(measure.name)] invalid IfCondition\(suffix): \(source)", level: .error)
            }
            condition.trueAction = measure.actionOption("IfTrueAction\(suffix)")
            condition.falseAction = measure.actionOption("IfFalseAction\(suffix)")
            result.append(condition)
        }
        conditions = result
    }

    private func readThresholds(for measure: Measure) {
        func threshold(_ valueKey: String, _ actionKey: String, _ previous: Threshold?) -> Threshold? {
            let action = measure.actionOption(actionKey)
            guard !action.isEmpty, let v = measure.optionalDouble(valueKey) else { return nil }
            // Judgment: the armed state survives a (dynamic) change of the threshold value.
            var t = Threshold(value: v, action: action)
            if let previous { t.active = previous.active }
            return t
        }
        ifAbove = threshold("IfAboveValue", "IfAboveAction", ifAbove)
        ifBelow = threshold("IfBelowValue", "IfBelowAction", ifBelow)
        ifEqual = threshold("IfEqualValue", "IfEqualAction", ifEqual)
    }

    private func readMatches(for measure: Measure) {
        ifMatchMode = measure.bool("IfMatchMode", false)
        var result: [Match] = []
        for (index, pattern) in measure.numberedOptions("IfMatch") {
            let suffix = index == 1 ? "" : String(index)
            var match = matches.first { $0.index == index }
                ?? Match(index: index, pattern: pattern, matchAction: "", notMatchAction: "", lastResult: nil)
            match.pattern = pattern   // an invalid pattern is logged once per IfMatchN, even when it changes
            match.matchAction = measure.actionOption("IfMatchAction\(suffix)")
            match.notMatchAction = measure.actionOption("IfNotMatchAction\(suffix)")
            result.append(match)
        }
        matches = result
    }

    func run(for measure: Measure, execute: (String) -> Void) {
        for i in conditions.indices {
            guard let formula = conditions[i].formula else { continue }
            guard let number = try? formula.evaluate({ measure.skin.formulaValue(of: $0, from: measure) }) else {
                if !conditions[i].loggedError {
                    conditions[i].loggedError = true
                    measure.skin.log("[\(measure.name)] cannot evaluate IfCondition: \(conditions[i].source)", level: .error)
                }
                continue
            }
            let result = number != 0
            if ifConditionMode || conditions[i].lastResult != result {
                conditions[i].lastResult = result
                let action = result ? conditions[i].trueAction : conditions[i].falseAction
                if !action.isEmpty { execute(action) }
            }
        }

        func check(_ t: inout Threshold?, _ holds: (Double) -> Bool) {
            guard var th = t else { return }
            if holds(th.value) {
                if !th.active {
                    th.active = true
                    t = th
                    execute(th.action)
                    return
                }
            } else {
                th.active = false
            }
            t = th
        }
        let current = measure.value
        check(&ifAbove) { current > $0 }
        check(&ifBelow) { current < $0 }
        check(&ifEqual) { roundedInt(current) == roundedInt($0) }

        let needsText = !matches.isEmpty || !onChangeAction.isEmpty
        let text = needsText ? measure.stringValue : ""
        for i in matches.indices {
            guard let result = PCRE.matches(matches[i].pattern, in: text) else {
                if !matches[i].loggedError {
                    matches[i].loggedError = true
                    measure.skin.log("[\(measure.name)] invalid IfMatch pattern: \(matches[i].pattern)", level: .error)
                }
                continue
            }
            if ifMatchMode || matches[i].lastResult != result {
                matches[i].lastResult = result
                let action = result ? matches[i].matchAction : matches[i].notMatchAction
                if !action.isEmpty { execute(action) }
            }
        }

        if !onChangeAction.isEmpty {
            if let lastValue, lastValue != measure.value || lastString != text {
                execute(onChangeAction)
            }
            lastValue = measure.value
            lastString = text
        } else {
            // Not tracked while there is no action; a later !SetOption starts from a fresh "initial" value.
            lastValue = nil
            lastString = nil
        }

        if !onUpdateAction.isEmpty { execute(onUpdateAction) }
    }

    /// Rounded to the nearest integer (IfEqualValue: "The compared value is rounded to an integer").
    private func roundedInt(_ v: Double) -> Int64 {
        guard v.isFinite else { return 0 }
        return Int64(v.rounded().clamped(-9e18, 9e18))
    }

    func forgetChangeBaseline() {
        lastValue = nil
        lastString = nil
    }
}
