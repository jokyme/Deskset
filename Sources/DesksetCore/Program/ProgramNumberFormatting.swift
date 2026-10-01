import Foundation

/// Plain-number display in the shared program. Locale is an immutable projection input, never global state.
/// nil decimals uses at most two places without trailing zeroes; explicit decimals uses exactly 0...10 places.
public struct ProgramNumberFormat: Equatable, Sendable {
    public let decimals: Int?
    public let missing: String

    public init(decimals: Int? = nil, missing: String = "–") {
        self.decimals = decimals
        self.missing = missing
    }

    func validate() throws {
        guard decimals.map({ (0...10).contains($0) }) ?? true,
              missing.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
    }

    func string(from number: Double?, locale: Locale) throws -> ProgramTextValue {
        try validate()
        guard let number else { return ProgramTextValue(text: missing) }
        guard number.isFinite else { throw ProgramRuntimeError.invalidExpression }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        // Double's largest finite value needs 309 integer digits. Do not truncate or cast it to Int.
        formatter.maximumIntegerDigits = 309
        formatter.minimumFractionDigits = decimals ?? 0
        formatter.maximumFractionDigits = decimals ?? 2
        formatter.roundingMode = .halfEven
        guard let text = formatter.string(from: NSNumber(value: number)), !text.isEmpty,
              text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
        return ProgramTextValue(text: text, numberRanges: [0..<text.utf16.count])
    }
}

/// Frozen text carries only numeric interpolation ranges, in UTF-16, rather than guessing from its characters.
/// Literal digits and missing placeholders have no ranges. This value survives a String variable assignment.
struct ProgramTextValue: Equatable, Sendable {
    let text: String
    var numberRanges: [Range<Int>] = []
}
