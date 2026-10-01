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
    /// Set by `computeValue` for an update that has no reading yet and returns a placeholder instead (FreeDiskSpace
    /// `MacAvailable=1` gives −1 before its first reading): the number is kept as it is — not averaged, not inverted and
    /// not counted in the observed range — so a skin can tell "not read yet" from any value. Cleared before each update.
    var computedPlaceholder = false
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

    private let pipeline = MeasurePipeline()
    /// Whether `liveInputs` were noted (virtual time).
    private var notedInputs = false

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

    /// The shared services outside the skin this measure reads directly at its updates (the Mac's system data, its
    /// battery and sensors, a player, the audio…). In virtual time each is noted at the first update
    /// (`Skin.noteService`): the skin cannot be verified unless the service is faked. Empty for measures that read
    /// only the skin, its clock and random numbers, or their own background work (`Skin.startBackground`).
    open var liveInputs: [BackgroundWorkKind] { [] }

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
        pipeline.readValueOptions(for: self)

        let substituteOption = string("Substitute")
        let regex = bool("RegExpSubstitute", false)
        if substituteOption.isEmpty {
            substitute = nil
            substituteSource = nil
        } else if substituteSource.map({ $0 != (substituteOption, regex) }) ?? true {
            substitute = SubstituteRules(substituteOption, regex: regex)
            substituteSource = (substituteOption, regex)
        }

        pipeline.readOptions(for: self)
        needsOptionRead = false
    }

    /// Recomputes `minValue` / `maxValue` from the options, the automatic range and the tracked range.
    func refreshRange() {
        pipeline.refreshRange(for: self)
    }

    // MARK: Update

    /// One update of this measure (UpdateDivider already checked by the skin).
    func performUpdate() {
        if disabled {
            value = 0
            return
        }
        if paused { return }
        if !notedInputs {
            notedInputs = true
            if skin.runsInVirtualTime { for kind in liveInputs { skin.noteService(kind) } }
        }
        // The Studio's sample data (`MeasureValueOverride`): its value in place of the computed one; the rules still run.
        if let sample = skin.measureValues, sample.isActive, sample.takesOver(self) { return finishOverride() }
        computedPlaceholder = false
        let v = computeValue()
        pipeline.finishValue(v, for: self)
        updateCount += 1
        runActions()
    }

    private func finishOverride() {
        value = value.isFinite ? value : 0
        updateCount += 1
        runActions()
    }

    private func runActions() {
        pipeline.run(for: self) { skin.execute($0, from: self) }
    }

    /// Forgets the value OnChangeAction compares with: the next update counts as the first one after a load. A patch
    /// (`Skin.patch(sources:)`) updates a measure whose options changed this way — a reload would not report its new
    /// string as a change either.
    func forgetChangeBaseline() {
        pipeline.forgetChangeBaseline()
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
        let changed = flag != disabled
        disabled = flag
        if changed { disabledStateChanged() }
    }

    /// Called when the measure has just been disabled or enabled (a bang, or its `Disabled` option): a measure that
    /// holds something while it runs can let it go (AudioLevel releases its audio capture).
    open func disabledStateChanged() {}

    /// `!PauseMeasure` / `!UnpauseMeasure`: a paused measure keeps its values.
    func setPaused(_ flag: Bool) {
        if !flag && paused { needsOptionRead = true }
        paused = flag
    }
}

// MARK: - Seeding (Session/Seeding.swift)

extension Measure {
    /// What this measure has seen so far, for a new instance of the widget (`SkinRuntimeState.MeasureState`).
    var runtimeSnapshot: SkinRuntimeState.MeasureState {
        pipeline.runtimeSnapshot(for: self)
    }

    /// Takes what the same measure of another instance of the widget has seen (loaded, before the first update): its
    /// value and string, the samples it averages (when it averages as many) and the range it observed. The first update
    /// then computes the next value from there.
    func seed(_ state: SkinRuntimeState.MeasureState) {
        pipeline.seed(state, for: self)
    }
}
