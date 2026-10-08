import Foundation

/// One projection's temporal inputs. The host samples its injected clock once; Core owns no live clock.
public struct ProgramDateInput: Equatable, Sendable {
    public let instant: Date
    public let timeZone: TimeZone
    public let locale: Locale

    public init(instant: Date, timeZone: TimeZone, locale: Locale) {
        self.instant = instant; self.timeZone = timeZone; self.locale = locale
    }
}

/// The fastest precision actually needed by visible, nonfrozen date or system expressions in a successful projection.
public enum ProgramClockPrecision: Equatable, Sendable {
    case hour, minute, twoSeconds, second

    public func delayToNextBoundary(after instant: Date) throws -> TimeInterval {
        let value = instant.timeIntervalSince1970
        guard value.isFinite else { throw ProgramRuntimeError.invalidDateInput }
        let interval: Double
        switch self {
        case .hour: interval = 3_600.0
        case .minute: interval = 60.0
        case .twoSeconds: interval = 2.0
        case .second: interval = 1.0
        }
        let remainder = value.truncatingRemainder(dividingBy: interval)
        let delay = interval - (remainder < 0 ? remainder + interval : remainder)
        guard delay.isFinite, delay > 0, delay <= interval else { throw ProgramRuntimeError.invalidDateInput }
        return delay
    }

    static func combined(_ a: Self?, _ b: Self?) -> Self? {
        guard let a else { return b }
        guard let b else { return a }
        if a == .second || b == .second { return .second }
        if a == .twoSeconds || b == .twoSeconds { return .twoSeconds }
        if a == .minute || b == .minute { return .minute }
        return .hour
    }
}

/// Desk's checked Unicode date formats, distinct from Rainmeter's strftime formatting.
public enum ProgramDateFormat: Equatable, Sendable {
    public enum Preset: String, Equatable, Sendable {
        case time, date, dateTime, weekday, shortWeekday, month, shortMonth, year
    }
    case preset(Preset)
    case pattern(String)

    public var precision: ProgramClockPrecision {
        get throws {
            guard case .pattern(let text) = self else { return .minute }
            guard text.utf16.count <= ProgramLimits.maximumTextLength else { throw ProgramRuntimeError.invalidExpression }
            let letters = Set("GyYuUrQqMLlwWdDFgEecabBhHKkjJCmszZOvVXx")
            var quoted = false, seconds = false
            for c in text {
                if c == "'" { quoted.toggle(); continue }
                if quoted { continue }
                // Fractional/absolute milliseconds need a finer cadence than this minute/second slice.
                guard !(c.isASCII && c.isLetter) || letters.contains(c) else { throw ProgramRuntimeError.invalidExpression }
                if c == "s" { seconds = true }
            }
            guard !quoted else { throw ProgramRuntimeError.invalidExpression }
            return seconds ? .second : .minute
        }
    }

    func string(from value: ProgramDateValue, locale: Locale) throws -> String {
        _ = try precision
        guard value.instant.timeIntervalSince1970.isFinite else { throw ProgramRuntimeError.invalidDateInput }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = value.timeZone
        switch self {
        case .pattern(let text): formatter.dateFormat = text
        case .preset(.time): formatter.timeStyle = .short
        case .preset(.date): formatter.dateStyle = .short
        case .preset(.dateTime): formatter.dateStyle = .short; formatter.timeStyle = .short
        case .preset(.weekday): formatter.dateFormat = "EEEE"
        case .preset(.shortWeekday): formatter.dateFormat = "EEE"
        case .preset(.month): formatter.dateFormat = "LLLL"
        case .preset(.shortMonth): formatter.dateFormat = "LLL"
        case .preset(.year): formatter.dateFormat = "y"
        }
        let result = formatter.string(from: value.instant)
        // An explicitly empty pattern is empty text; other failed Foundation formats cannot masquerade as it.
        guard result.utf16.count <= ProgramLimits.maximumTextLength,
              !result.isEmpty || self == .pattern("") else { throw ProgramRuntimeError.invalidExpression }
        return result
    }
}

struct ProgramDateValue: Equatable, Sendable {
    let instant: Date
    let timeZone: TimeZone
}
