import Foundation

// Number → text formatting for String meters and measure values.
//
// Clean-room implementation from the public manual only:
//   https://docs.rainmeter.net/manual/meters/string/        (NumOfDecimals, Scale, AutoScale, Percentual)
//   https://docs.rainmeter.net/manual/measures/general-options/ (MinValue / MaxValue defaults)
//   https://docs.rainmeter.net/manual/variables/section-variables/ ([Measure:], [Measure:n])
//   https://docs.rainmeter.net/history/ (release notes: consistent space before the k/M/G/T unit,
//   trailing zeros trimmed from calculated numbers)
// Every place where the manual is silent is marked "Judgment:".

/// String meter / measure `AutoScale=` setting.
public enum AutoScale: Equatable {
    case off
    /// `1` (1024-based: k, M, G, T) — `minimumPower` 0; `1k` → 1, `1m` → 2, `1g` → 3 … as the manual defines.
    case binary(minimumPower: Int)
    /// `2` (1000-based) and its `2k`/`2m`/… variants.
    case decimal(minimumPower: Int)

    /// Parses the raw option value (`0`, `1`, `2`, `1k`, `2k`, `1m`, …). Unknown → `.off`.
    ///
    /// The manual lists `0`, `1`, `1k`, `2`, `2k`. Judgment: `1m`/`2m`, `1g`/`2g`, `1t`/`2t` (lowest unit
    /// mega / giga / tera) are accepted as the natural extension of the `k` form; letters are case-insensitive
    /// and surrounding whitespace is ignored. Anything else (including `3`, negative numbers, text) is `.off`.
    public static func parse(_ raw: String) -> AutoScale {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return .off }
        var power = 0
        if let last = s.last, let idx = AutoScale.unitLetters.firstIndex(of: last) {
            power = idx + 1
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        let kind: Int?
        if let i = Int(s) {
            kind = i
        } else if power == 0, let d = Double(s), d.isFinite, d == d.rounded(.towardZero), abs(d) < 10 {
            kind = Int(d)          // "1.0" → 1
        } else {
            kind = nil
        }
        switch kind {
        case 1: return .binary(minimumPower: power)
        case 2: return .decimal(minimumPower: power)
        default: return .off
        }
    }

    /// `k`, `m`, `g`, `t` suffix letters accepted by `parse` (index + 1 = minimum power).
    private static let unitLetters: [Character] = ["k", "m", "g", "t"]

    /// The unit abbreviations appended to scaled values, by power (index 0 = unscaled).
    /// The manual: "The scaled result is appended with k, M, G, etc." Judgment: T (10¹² / 1024⁴) is the
    /// largest unit (the release notes speak of the "k/m/g/t" postfix); bigger values stay in T.
    static let units: [String] = ["", "k", "M", "G", "T"]

    var base: Double? {
        switch self {
        case .off: return nil
        case .binary: return 1024
        case .decimal: return 1000
        }
    }

    var minimumPower: Int {
        switch self {
        case .off: return 0
        case .binary(let p), .decimal(let p): return min(max(p, 0), AutoScale.units.count - 1)
        }
    }
}

public struct NumberFormatOptions: Equatable {
    public var autoScale: AutoScale
    /// `Scale=` divisor (default 1).
    public var scale: Double
    /// `NumOfDecimals=`; nil when not set (the manual's default then applies).
    public var numOfDecimals: Int?
    /// `Percentual=1`: show the value as a percentage of the measure's MinValue…MaxValue range.
    public var percentual: Bool
    /// True when the raw `Scale=` text contains a decimal point (e.g. `Scale=1000.0`). The manual: "If the
    /// specified value has a decimal point (e.g. 1000.0), the result will also display decimals."
    /// Use `NumberFormatOptions.scaleHasDecimalPoint(_:)` on the raw option text to set it.
    public var scaleHasDecimalPoint: Bool = false

    public init(autoScale: AutoScale = .off, scale: Double = 1, numOfDecimals: Int? = nil, percentual: Bool = false) {
        self.autoScale = autoScale
        self.scale = scale
        self.numOfDecimals = numOfDecimals
        self.percentual = percentual
    }

    /// Whether a raw `Scale=` value "has a decimal point" in the manual's sense (`1000.0`, `(1024*1.5)`).
    public static func scaleHasDecimalPoint(_ rawScale: String) -> Bool {
        rawScale.contains(".")
    }

    /// Builds options from raw (already variable-substituted) option texts; nil / empty = option not set.
    /// Plain numbers only — callers that support formulas should evaluate them first and set the fields
    /// directly (keeping `scaleHasDecimalPoint` from the raw text).
    /// - `NumOfDecimals` is truncated toward zero; negative values count as 0.
    /// - `Percentual` is on for any non-zero number.
    public static func parse(autoScale: String?, scale: String?, numOfDecimals: String?, percentual: String?) -> NumberFormatOptions {
        func number(_ raw: String?) -> Double? {
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  let d = Double(t), d.isFinite else { return nil }
            return d
        }
        var options = NumberFormatOptions()
        if let a = autoScale { options.autoScale = AutoScale.parse(a) }
        if let s = number(scale) { options.scale = s }
        if let raw = scale { options.scaleHasDecimalPoint = scaleHasDecimalPoint(raw) }
        if let n = number(numOfDecimals) { options.numOfDecimals = Int(max(0, min(n, 1_000)).rounded(.towardZero)) }
        if let p = number(percentual) { options.percentual = p != 0 }
        return options
    }
}

public enum NumberFormatting {
    /// Upper bound applied to any requested number of decimals (Judgment: the manual gives no limit; more than
    /// 30 decimals is meaningless for a Double and would only produce huge strings).
    public static let maximumDecimals = 30

    /// Decimals used by `plain` (see there).
    public static let plainDecimals = 5

    /// Formats a measure number for a String meter (Percentual → Scale → AutoScale suffix → decimals), matching the manual.
    ///
    /// Rules (String meter page):
    /// - `NumOfDecimals` default 0; with `AutoScale` enabled the default is one decimal; an explicit value
    ///   (including 0) always wins.
    /// - `Scale`: the value is divided by it; ignored when AutoScale is enabled. A Scale with a decimal point
    ///   (`scaleHasDecimalPoint`) "will also display decimals" — Judgment: one decimal when NumOfDecimals is not set.
    ///   Judgment: a Scale of 0 or a non-finite Scale is ignored (no division by zero).
    /// - `AutoScale`: `1` divides by 1024, `2` by 1000, while the magnitude is at least one unit, appending
    ///   " k", " M", " G", " T". The manual notes AutoScale "adds a space between the scaled number and the scale
    ///   unit abbreviation"; per the release notes that space is consistent, so an unscaled value gets a trailing
    ///   space too (`"512.0 "`, so `Text=%1B` → `512.0 B` / `2.0 kB`). `1k`/`2k` (…) use kilo (…) as the lowest unit.
    ///   Judgment: the unit is chosen from the magnitude (negative values scale like positive ones) using `>=`
    ///   (1024 → "1.0 k"); the unit is picked before rounding (1023.99 → "1024.0 ").
    /// - `Percentual`: value → 0…100 relative to MinValue…MaxValue. Judgment: clamped to 0…100 like other
    ///   percentual consumers, and 0 when the range is empty (MaxValue == MinValue) or not finite.
    /// - Rounding (Judgment): C `printf("%.Nf")` semantics — correctly rounded from the binary value, exact
    ///   ties to even (2.5 → "2", 0.125 → "0.12"). "-0" results are printed as "0".
    /// - NaN is shown as 0; ±infinity as "inf" / "-inf" (Judgment).
    public static func format(_ value: Double, minValue: Double, maxValue: Double, options: NumberFormatOptions) -> String {
        var v = value.isNaN ? 0 : value
        if options.percentual {
            v = percentage(v, minValue: minValue, maxValue: maxValue)
        }
        switch options.autoScale {
        case .off:
            let s = options.scale
            if s.isFinite, s != 0, s != 1 { v /= s }
            let decimals = options.numOfDecimals ?? (options.scaleHasDecimalPoint ? 1 : 0)
            return fixed(v, decimals: decimals)
        case .binary, .decimal:
            let decimals = options.numOfDecimals ?? 1
            guard v.isFinite else { return nonFiniteText(v) }
            let base = options.autoScale.base ?? 1024
            var power = options.autoScale.minimumPower
            let magnitude = abs(v)
            var divisor = pow(base, Double(power))
            while power < AutoScale.units.count - 1, magnitude >= divisor * base {
                divisor *= base
                power += 1
            }
            return fixed(v / divisor, decimals: decimals) + " " + AutoScale.units[power]
        }
    }

    /// `(value - min) / (max - min) * 100`, clamped to 0…100; 0 for an empty or invalid range.
    public static func percentage(_ value: Double, minValue: Double, maxValue: Double) -> Double {
        let range = maxValue - minValue
        guard value.isFinite, minValue.isFinite, maxValue.isFinite, range.isFinite, range != 0 else { return 0 }
        let p = (value - minValue) / range * 100
        guard p.isFinite else { return 0 }
        return min(max(p, 0), 100)
    }

    /// Default number → text conversion used when a measure that has no string value is shown as text
    /// (e.g. `[MeasureCalc]`, or `%1` for a Calc measure without number options).
    ///
    /// Judgment (the manual does not state the precision): the value is rounded to 5 decimals and trailing
    /// zeros (and a trailing ".") are removed — the release notes say trailing zeros are removed from calculated
    /// numbers. `1` → "1", `0.5` → "0.5", `1/3` → "0.33333", `1e20` → "100000000000000000000", `1e-7` → "0".
    /// Note: a String meter bound to a measure applies `format` instead (NumOfDecimals defaults to 0 there).
    public static func plain(_ value: Double) -> String {
        plain(value, maxDecimals: plainDecimals)
    }

    /// `value` with at most `maxDecimals` decimals, trailing zeros trimmed (e.g. `[Measure:]` uses 10:
    /// "the measure's number value … with up to ten decimal places of precision", trailing zeros trimmed).
    public static func plain(_ value: Double, maxDecimals: Int) -> String {
        let v = value.isNaN ? 0 : value
        guard v.isFinite else { return nonFiniteText(v) }
        var s = fixed(v, decimals: maxDecimals)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// `value` with exactly `decimals` decimals (printf `%.Nf` semantics, C locale, `-0` → `0`).
    /// E.g. `[Measure:4]`. `decimals` is clamped to 0…`maximumDecimals`.
    public static func fixed(_ value: Double, decimals: Int) -> String {
        let v = value.isNaN ? 0 : value
        guard v.isFinite else { return nonFiniteText(v) }
        let d = Int32(min(max(decimals, 0), maximumDecimals))
        var s = cFormatFixed(v, decimals: d)
        if s.first == "-", s.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) {
            s.removeFirst()
        }
        return s
    }

    static func nonFiniteText(_ v: Double) -> String {
        if v.isNaN { return "0" }
        return v < 0 ? "-inf" : "inf"
    }

    /// `%.Nf` formatting (printf semantics, correctly rounded). `String(format:)` without a locale always uses
    /// "." as the decimal separator, independent of the user's region settings.
    private static func cFormatFixed(_ v: Double, decimals: Int32) -> String {
        String(format: fixedFormats[Int(decimals)], v)
    }

    /// "%.0f" … "%.30f", built once.
    private static let fixedFormats: [String] = (0...maximumDecimals).map { "%.\($0)f" }
}
