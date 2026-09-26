import Foundation

/// Base class of all measures: MinValue/MaxValue, InvertMeasure, AverageSize, Disabled/Paused, Substitute,
/// IfCondition / IfAbove / IfBelow / IfEqual / IfMatch actions, OnUpdateAction and OnChangeAction.
///
/// Clean-room implementation of the public manual only: /manual/measures/, /manual/measures/general-options/ and
/// its sub-pages (ifactions, ifconditions, ifmatchactions, substitute), plus the version history notes.
///
/// Rules:
/// - `Disabled=1`: "the measure value is never updated", it is 0 in numerical contexts but keeps its previous
///   string value. `Paused=1`: never updated, keeps its last number and string. The bangs (`!DisableMeasure`,
///   `!PauseMeasure`…) set the same state; a bang state lasts until the option text itself changes.
///   While disabled or paused only DynamicVariables/UpdateDivider/Group/Disabled/Paused are re-read (history:
///   "Fixed issue where measure options were re-read even if disabled or paused"); an initially disabled measure
///   populates nothing until it is enabled (except WebParser, whose children must be known to their parent: see
///   `WebParserMeasure.readOptions`). No actions run for a measure that is not updated.
/// - MinValue (default 0) / MaxValue (default 1) define the range for percentages; they never change the value.
///   Measures that know their range set it automatically (`automaticMinValue` / `automaticMaxValue`).
///   Measures that cannot know it (Net, Calc, WebParser — /manual/measures/ "Percentage") set the range
///   "dynamically, to the smallest and largest values the measure has been since the skin was loaded or refreshed"
///   for each bound that is not given as an option. Judgment: the range starts from the documented defaults and is
///   only widened by the values seen (MinValue = min(0, smallest), MaxValue = max(1, largest)), so both manual
///   statements hold: a Calc that stays within 0…1 (the common `Formula=Used / Total` bound to a Bar) keeps the
///   default range 0…1 instead of collapsing to its own value (which would draw every constant Calc as 0 %), and
///   `MaxValue=100` alone gives 0…100.
/// - `AverageSize=N`: the value is the average of the last N values ("past actual values", current included).
/// - `InvertMeasure=1`: value = MaxValue − (value − MinValue) (FreeDiskSpace → used space, Memory → free memory).
/// - Order of one update (the manual gives none; judgment): compute → range tracking → average → invert →
///   IfCondition(s) → IfAbove/IfBelow/IfEqual → IfMatch(es) → OnChangeAction → OnUpdateAction.
/// - IfCondition: evaluated every update; the true/false action runs when the result *becomes* true/false (the
///   first evaluation counts as a change); `IfConditionMode=1` runs it on every update. A formula that cannot be
///   evaluated (syntax error, unknown measure name) runs no action and keeps its previous state.
/// - IfAboveAction / IfBelowAction run when the value becomes above / below the value and re-arm once it is no
///   longer above / below. IfEqualAction compares the values "rounded to an integer" and re-arms once they differ.
/// - IfMatch: PCRE matched against the string value (after Substitute); same "becomes" / `IfMatchMode` rules.
///   An invalid pattern runs no action.
/// - OnChangeAction: when the number or the string value changes; the initial change after load is ignored.
open class Measure: SkinSection {
    /// Lowercased `Measure=` value (or plugin name for `Measure=Plugin`).
    public let type: String

    public internal(set) var value: Double = 0
    /// The measure's own string value before Substitute (nil for number-only measures), as its last update set it.
    public var rawString: String?

    /// The string value meters and section variables read (before Substitute). Default: `rawString`. A measure whose
    /// string follows data that changes between its updates may answer with that data — Rainmeter calls a plugin's
    /// GetString on demand, whenever the string is needed: NowPlaying measures do, so a title updated only every 10–20 s
    /// (UpdateDivider=100) still shows the track that is playing. The number, IfConditions, IfMatch and OnChangeAction
    /// still follow the measure's updates.
    open var currentRawString: String? { rawString }
    public internal(set) var minValue: Double = 0
    public internal(set) var maxValue: Double = 1
    public internal(set) var disabled = false
    public internal(set) var paused = false
    public private(set) var updateCount = 0

    var invert = false
    var averageSize = 0
    private var history: [Double] = []
    private var historyNext = 0
    private var substitute: SubstituteRules? {
        didSet { stringCache = nil }
    }
    private var substituteSource: (String, Bool)?
    /// `stringValue` for the current raw string / number (Substitute may run regular expressions, and the value is
    /// read by every meter and section variable that shows it).
    private var stringCache: (raw: String?, value: Double, result: String)?
    /// Disabled / Paused option texts last applied (bang state lasts until they change or are set again).
    var lastDisabledOption: String?
    var lastPausedOption: String?
    /// MinValue / MaxValue as written (nil = not set), already scaled by `rangeOptionScale`.
    private var minValueOption: Double?
    private var maxValueOption: Double?
    private var observedMin: Double?
    private var observedMax: Double?
    private var warnedAboutRange = false

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

    /// Upper bound for `AverageSize` (a larger window is pointless and would cost memory).
    static let maxAverageSize = 10_000

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        self.type = type
        super.init(name: name, section: section, skin: skin)
    }

    // MARK: Subclass hooks

    /// MaxValue used when the option is absent (e.g. CPU → 100, Memory → total bytes).
    open var automaticMaxValue: Double { 1 }
    open var automaticMinValue: Double { 0 }

    /// True while the measure cannot provide its value on macOS (a Windows-only measure or plugin, a registry value
    /// that is not emulated…); its values are then 0 / "". String meters keep one line of height for the empty
    /// text this produces (see `StringMeter`), because on Windows the value would be there.
    open var valueUnavailable: Bool { false }

    /// Reads type-specific options. Called after the common options.
    open func readMeasureOptions() {}

    /// Computes the raw number value for this update; may set `rawString`.
    open func computeValue() -> Double { 0 }

    /// `!CommandMeasure` arguments.
    open func execute(command: String) {
        skin.log("!CommandMeasure is not supported by \(type) measure [\(name)]", level: .warning)
    }

    /// True for measures that cannot know their range and track the observed minimum / maximum instead
    /// (manual, Measures → Percentage: Net, Calc, WebParser…).
    var tracksValueRange: Bool {
        switch type {
        case "calc", "netin", "netout", "nettotal", "webparser": return true
        default: return false
        }
    }

    /// Whether the `MinValue` / `MaxValue` options are honoured (Memory and FreeDiskSpace: "all general measure
    /// options except MaxValue"; Loop: "may not be manually set").
    var allowsMinValueOption: Bool { true }
    var allowsMaxValueOption: Bool { true }
    /// `InvertMeasure` (String: "all general measure options except InvertMeasure").
    var allowsInvert: Bool { true }
    /// `AverageSize` (Loop: "all general measure options except AverageSize").
    var allowsAverage: Bool { true }
    /// Factor applied to the MinValue / MaxValue options (Net measures: written in bits, used in bytes).
    var rangeOptionScale: Double { 1 }

    // MARK: Options

    open override func readOptions() {
        super.readOptions()

        let disabledOption = string("Disabled", "0")
        if disabledOption != lastDisabledOption {
            lastDisabledOption = disabledOption
            setDisabled(OptionValue.bool(disabledOption) ?? false)
        }
        let pausedOption = string("Paused", "0")
        if pausedOption != lastPausedOption {
            lastPausedOption = pausedOption
            setPaused(OptionValue.bool(pausedOption) ?? false)
        }
        // The rest is read once the measure runs again (`setDisabled(false)` / `setPaused(false)` ask for a re-read).
        if disabled || paused { return }

        readMeasureOptions()
        let scale = rangeOptionScale
        minValueOption = allowsMinValueOption ? optionalDouble("MinValue").map { $0 * scale } : nil
        maxValueOption = allowsMaxValueOption ? optionalDouble("MaxValue").map { $0 * scale } : nil
        refreshRange()
        invert = allowsInvert && bool("InvertMeasure", false)
        let size = allowsAverage ? int("AverageSize", 1) : 1
        averageSize = min(max(size, 0), Measure.maxAverageSize)
        if averageSize <= 1 || history.count > averageSize {
            history = []
            historyNext = 0
        }

        let substituteOption = string("Substitute")
        let regex = bool("RegExpSubstitute", false)
        if substituteOption.isEmpty {
            substitute = nil
            substituteSource = nil
        } else if substituteSource.map({ $0 != (substituteOption, regex) }) ?? true {
            substitute = SubstituteRules(substituteOption, regex: regex)
            substituteSource = (substituteOption, regex)
        }

        readConditions()
        readThresholds()
        readMatches()
        onUpdateAction = actionOption("OnUpdateAction")
        onChangeAction = actionOption("OnChangeAction")
        needsOptionRead = false
    }

    /// Recomputes `minValue` / `maxValue` from the options, the automatic range and the tracked range.
    func refreshRange() {
        if let minValueOption {
            minValue = minValueOption
        } else if tracksValueRange, let observedMin {
            minValue = Swift.min(automaticMinValue, observedMin)
        } else {
            minValue = automaticMinValue
        }
        if let maxValueOption {
            maxValue = maxValueOption
        } else if tracksValueRange, let observedMax {
            maxValue = Swift.max(automaticMaxValue, observedMax)
        } else {
            maxValue = automaticMaxValue
        }
        if maxValue < minValue && !warnedAboutRange {
            warnedAboutRange = true
            skin.log("[\(name)] MaxValue is less than MinValue", level: .debug)
        }
    }

    private func readConditions() {
        ifConditionMode = bool("IfConditionMode", false)
        let sources = numberedOptions("IfCondition")
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
                && !awaitsSectionVariables("IfCondition\(suffix)") {
                condition.loggedError = true
                skin.log("[\(name)] invalid IfCondition\(suffix): \(source)", level: .error)
            }
            condition.trueAction = actionOption("IfTrueAction\(suffix)")
            condition.falseAction = actionOption("IfFalseAction\(suffix)")
            result.append(condition)
        }
        conditions = result
    }

    private func readThresholds() {
        func threshold(_ valueKey: String, _ actionKey: String, _ previous: Threshold?) -> Threshold? {
            let action = actionOption(actionKey)
            guard !action.isEmpty, let v = optionalDouble(valueKey) else { return nil }
            // Judgment: the armed state survives a (dynamic) change of the threshold value.
            var t = Threshold(value: v, action: action)
            if let previous { t.active = previous.active }
            return t
        }
        ifAbove = threshold("IfAboveValue", "IfAboveAction", ifAbove)
        ifBelow = threshold("IfBelowValue", "IfBelowAction", ifBelow)
        ifEqual = threshold("IfEqualValue", "IfEqualAction", ifEqual)
    }

    private func readMatches() {
        ifMatchMode = bool("IfMatchMode", false)
        var result: [Match] = []
        for (index, pattern) in numberedOptions("IfMatch") {
            let suffix = index == 1 ? "" : String(index)
            var match = matches.first { $0.index == index }
                ?? Match(index: index, pattern: pattern, matchAction: "", notMatchAction: "", lastResult: nil)
            match.pattern = pattern   // an invalid pattern is logged once per IfMatchN, even when it changes
            match.matchAction = actionOption("IfMatchAction\(suffix)")
            match.notMatchAction = actionOption("IfNotMatchAction\(suffix)")
            result.append(match)
        }
        matches = result
    }

    // MARK: Update

    /// One update of this measure (UpdateDivider already checked by the skin).
    func performUpdate() {
        if disabled {
            value = 0
            return
        }
        if paused { return }
        var v = computeValue()
        if !v.isFinite { v = 0 }
        if averageSize > 1 {
            if history.count < averageSize {
                history.append(v)
            } else {
                history[historyNext % history.count] = v
            }
            historyNext = (historyNext + 1) % averageSize
            v = history.reduce(0, +) / Double(history.count)
        }
        if tracksValueRange {
            observedMin = Swift.min(observedMin ?? v, v)
            observedMax = Swift.max(observedMax ?? v, v)
        }
        refreshRange()
        if invert { v = maxValue - (v - minValue) }
        value = v.isFinite ? v : 0
        updateCount += 1
        runActions()
    }

    private func runActions() {
        for i in conditions.indices {
            guard let formula = conditions[i].formula else { continue }
            guard let number = try? formula.evaluate({ skin.formulaValue(of: $0, from: self) }) else {
                if !conditions[i].loggedError {
                    conditions[i].loggedError = true
                    skin.log("[\(name)] cannot evaluate IfCondition: \(conditions[i].source)", level: .error)
                }
                continue
            }
            let result = number != 0
            if ifConditionMode || conditions[i].lastResult != result {
                conditions[i].lastResult = result
                let action = result ? conditions[i].trueAction : conditions[i].falseAction
                if !action.isEmpty { skin.execute(action, from: self) }
            }
        }

        func check(_ t: inout Threshold?, _ holds: (Double) -> Bool) {
            guard var th = t else { return }
            if holds(th.value) {
                if !th.active {
                    th.active = true
                    t = th
                    skin.execute(th.action, from: self)
                    return
                }
            } else {
                th.active = false
            }
            t = th
        }
        let current = value
        check(&ifAbove) { current > $0 }
        check(&ifBelow) { current < $0 }
        check(&ifEqual) { roundedInt(current) == roundedInt($0) }

        let needsText = !matches.isEmpty || !onChangeAction.isEmpty
        let text = needsText ? stringValue : ""
        for i in matches.indices {
            guard let result = PCRE.matches(matches[i].pattern, in: text) else {
                if !matches[i].loggedError {
                    matches[i].loggedError = true
                    skin.log("[\(name)] invalid IfMatch pattern: \(matches[i].pattern)", level: .error)
                }
                continue
            }
            if ifMatchMode || matches[i].lastResult != result {
                matches[i].lastResult = result
                let action = result ? matches[i].matchAction : matches[i].notMatchAction
                if !action.isEmpty { skin.execute(action, from: self) }
            }
        }

        if !onChangeAction.isEmpty {
            if let lastValue, lastValue != value || lastString != text {
                skin.execute(onChangeAction, from: self)
            }
            lastValue = value
            lastString = text
        } else {
            // Not tracked while there is no action; a later !SetOption starts from a fresh "initial" value.
            lastValue = nil
            lastString = nil
        }

        if !onUpdateAction.isEmpty { skin.execute(onUpdateAction, from: self) }
    }

    /// Rounded to the nearest integer (IfEqualValue: "The compared value is rounded to an integer").
    private func roundedInt(_ v: Double) -> Int64 {
        guard v.isFinite else { return 0 }
        return Int64(v.rounded().clamped(-9e18, 9e18))
    }

    // MARK: Values for meters and section variables

    /// String value with Substitute applied; number-only measures print their number.
    public var stringValue: String {
        let raw = currentRawString
        if let cache = stringCache, cache.raw == raw, cache.value.bitPattern == value.bitPattern {
            return cache.result
        }
        let result = applySubstitute(raw ?? NumberFormatting.plain(value))
        stringCache = (raw, value, result)
        return result
    }

    /// Text for a String meter: the string value when the measure has one, otherwise the number formatted with
    /// the meter's AutoScale/Scale/NumOfDecimals/Percentual; Substitute applies either way.
    public func text(numberFormat: NumberFormatOptions) -> String {
        if let raw = currentRawString { return applySubstitute(raw) }
        return applySubstitute(NumberFormatting.format(value, minValue: minValue, maxValue: maxValue,
                                                       options: numberFormat))
    }

    /// Value mapped to 0…1 within MinValue…MaxValue (bars, rotators, line graphs).
    public var relativeValue: Double {
        let range = maxValue - minValue
        guard range != 0, range.isFinite else { return 0 }
        let r = (value - minValue) / range
        return r.isFinite ? min(max(r, 0), 1) : 0
    }

    func applySubstitute(_ text: String) -> String {
        substitute?.apply(to: text) ?? text
    }

    // MARK: Bangs

    /// `!EnableMeasure` / `!DisableMeasure`: a disabled measure is 0 in numerical contexts right away.
    func setDisabled(_ flag: Bool) {
        if flag {
            value = 0
        } else if disabled {
            needsOptionRead = true
        }
        disabled = flag
    }

    /// `!PauseMeasure` / `!UnpauseMeasure`: a paused measure keeps its values.
    func setPaused(_ flag: Bool) {
        if !flag && paused { needsOptionRead = true }
        paused = flag
    }
}
