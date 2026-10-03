import Foundation

/// Numeric display in the shared program. Locale is an immutable projection input, never global state.
/// Plain-number defaults and the original init(decimals:missing:) call remain unchanged.
public struct ProgramNumberFormat: Equatable, Sendable {
    public enum ByteUnit: String, CaseIterable, Equatable, Sendable { case auto, bytes, kb, mb, gb, tb, kib, mib, gib, tib }
    public enum UnitStyle: String, CaseIterable, Equatable, Sendable { case none, short, full }
    public enum DurationStyle: String, CaseIterable, Equatable, Sendable { case full, short, clock }
    public let decimals: Int?
    public let missing: String
    public let unit: ByteUnit?
    public let unitStyle: UnitStyle?
    public let durationStyle: DurationStyle?

    public init(decimals: Int? = nil, missing: String = "–", unit: ByteUnit? = nil,
                unitStyle: UnitStyle? = nil, durationStyle: DurationStyle? = nil) {
        self.decimals = decimals
        self.missing = missing
        self.unit = unit; self.unitStyle = unitStyle; self.durationStyle = durationStyle
    }

    func validate() throws {
        guard decimals.map({ (0...10).contains($0) }) ?? true,
              missing.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
    }

    func validate(for dimension: ProgramNumberDimension) throws {
        try validate()
        switch dimension {
        case .plain, .percent:
            guard unit == nil, unitStyle == nil, durationStyle == nil else { throw ProgramRuntimeError.invalidExpression }
        case .bytes:
            guard durationStyle == nil else { throw ProgramRuntimeError.invalidExpression }
        case .duration:
            // The catalog permits decimals for any Number, but defines no placement in multi-unit/clock text.
            guard decimals == nil, unit == nil, unitStyle == nil else { throw ProgramRuntimeError.invalidExpression }
        }
    }

    func string(from number: Double?, locale: Locale) throws -> ProgramTextValue {
        try string(from: number.map { ProgramNumber($0, dimension: .plain) }, dimension: .plain, locale: locale)
    }

    func string(from number: ProgramNumber?, dimension: ProgramNumberDimension, locale: Locale) throws -> ProgramTextValue {
        try validate(for: dimension)
        guard let number else { return ProgramTextValue(text: missing) }
        try number.validate()
        guard number.dimension == dimension else { throw ProgramRuntimeError.invalidExpression }
        switch dimension {
        case .plain: return try decimal(number.value, places: decimals, locale: locale)
        case .percent: return try decimal(number.value, places: decimals ?? 0, locale: locale)
        case .bytes: return try bytes(number, locale: locale)
        case .duration: return try duration(number.value, locale: locale)
        }
    }

    private func decimal(_ number: Double, places: Int?, locale: Locale) throws -> ProgramTextValue {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        // Double's largest finite value needs 309 integer digits. Do not truncate or cast it to Int.
        formatter.maximumIntegerDigits = 309
        formatter.minimumFractionDigits = places ?? 0
        formatter.maximumFractionDigits = places ?? 2
        formatter.roundingMode = .halfEven
        guard let text = formatter.string(from: NSNumber(value: number)), !text.isEmpty,
              text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
        return ProgramTextValue(text: text, numberRanges: [0..<text.utf16.count])
    }

    private func bytes(_ number: ProgramNumber, locale: Locale) throws -> ProgramTextValue {
        let chosen = unit ?? .auto
        let base = chosen == .kib || chosen == .mib || chosen == .gib || chosen == .tib ? 1024 : number.displayBase ?? 1000
        let power: Int
        switch chosen {
        case .bytes: power = 0
        case .kb, .kib: power = 1
        case .mb, .mib: power = 2
        case .gb, .gib: power = 3
        case .tb, .tib: power = 4
        case .auto:
            var selected = 0, magnitude = abs(number.value)
            while selected < 4 && magnitude >= Double(base) { magnitude /= Double(base); selected += 1 }
            power = selected
        }
        let scaled = number.value / pow(Double(base), Double(power))
        let places = decimals ?? (abs(scaled) < 100 ? 1 : 0)
        if unitStyle == .some(.none) { return try decimal(scaled, places: places, locale: locale) }
        let binary = chosen == .kib || chosen == .mib || chosen == .gib || chosen == .tib
        // Scale ourselves according to the checked value's base; providedUnit must not convert again by region.
        let units: [UnitInformationStorage] = binary
            ? [.bytes, .kibibytes, .mebibytes, .gibibytes, .tebibytes] : [.bytes, .kilobytes, .megabytes, .gigabytes, .terabytes]
        let style = Measurement<UnitInformationStorage>.FormatStyle(width: unitStyle == .full ? .wide : .abbreviated,
            locale: locale, usage: .asProvided, numberFormatStyle: .number.locale(locale).precision(.fractionLength(places)))
        let attributed = style.attributed.format(Measurement(value: scaled, unit: units[power]))
        // The catalog's Mac symbols are fixed (KB), whereas Foundation Measurement uses SI casing (kB).
        // Replace only its unit field, keeping locale punctuation, order and directionality.
        let symbols = binary ? ["B", "KiB", "MiB", "GiB", "TiB"] : ["B", "KB", "MB", "GB", "TB"]
        return try text(attributed, unitSymbol: unitStyle == .full ? nil : symbols[power], durationClock: false)
    }

    private func duration(_ seconds: Double, locale: Locale) throws -> ProgramTextValue {
        // Swift.Duration's seconds storage is Int64. Reject an unrepresentable finite value before conversion.
        guard seconds >= Double(Int64.min), seconds < Double(Int64.max) else { throw ProgramRuntimeError.invalidExpression }
        let value = Duration.seconds(seconds)
        let attributed: AttributedString
        switch durationStyle ?? .full {
        case .full, .short:
            let style = Duration.UnitsFormatStyle(allowedUnits: [.days, .hours, .minutes, .seconds],
                width: durationStyle == .short ? .narrow : .wide, maximumUnitCount: 2).locale(locale)
            attributed = style.attributed.format(value)
        case .clock:
            let pattern: Duration.TimeFormatStyle.Pattern = abs(seconds) >= 3600 ? .hourMinuteSecond : .minuteSecond
            attributed = Duration.TimeFormatStyle(pattern: pattern, locale: locale).attributed.format(value)
        }
        return try text(attributed, unitSymbol: nil, durationClock: durationStyle == .clock)
    }

    private func text(_ value: AttributedString, unitSymbol: String?, durationClock: Bool) throws -> ProgramTextValue {
        var text = "", ranges: [Range<Int>] = [], length = 0, replacedUnit = false
        for run in value.runs {
            let part: String
            if run.measurement == .unit, let unitSymbol {
                if replacedUnit { continue }
                part = unitSymbol; replacedUnit = true
            } else { part = String(value[run.range].characters) }
            let count = part.utf16.count
            guard count <= ProgramLimits.maximumTextLength - length else { throw ProgramRuntimeError.invalidExpression }
            if count > 0 && (run.measurement == .value || durationClock && run.durationField != nil) {
                if let last = ranges.last, last.upperBound == length {
                    ranges[ranges.count - 1] = last.lowerBound..<(length + count)
                } else { ranges.append(length..<(length + count)) }
            }
            text += part; length += count
        }
        guard !text.isEmpty, unitSymbol == nil || replacedUnit else { throw ProgramRuntimeError.invalidExpression }
        return ProgramTextValue(text: text, numberRanges: ranges)
    }
}

/// Frozen text carries only numeric interpolation ranges, in UTF-16, rather than guessing from its characters.
/// Literal digits and missing placeholders have no ranges. This value survives a String variable assignment.
struct ProgramTextValue: Equatable, Sendable {
    let text: String
    var numberRanges: [Range<Int>] = []
}
