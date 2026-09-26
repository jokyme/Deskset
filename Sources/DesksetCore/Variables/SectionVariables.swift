import Foundation

// Clean-room, from the public manual only: https://docs.rainmeter.net/manual/variables/section-variables/

/// The keyword parameters of section variables (`[Name:Keyword]`) listed in the manual.
public enum SectionVariableKeyword: String, CaseIterable {
    /// Measure: its `MinValue` number (`[MeasureName:MinValue]`).
    case minValue = "MinValue"
    /// Measure: its `MaxValue` number (`[MeasureName:MaxValue]`).
    case maxValue = "MaxValue"
    /// Meter: the "real" X of the meter's top-left corner, always an integer (`[MeterName:X]`).
    case x = "X"
    /// Meter: the "real" Y of the meter's top-left corner, always an integer.
    case y = "Y"
    /// Meter: the real width (including padding), always an integer.
    case w = "W"
    /// Meter: the real height (including padding), always an integer.
    case h = "H"
    /// Meter: X + W, the position of the meter's right end.
    case xw = "XW"
    /// Meter: Y + H, the position of the meter's bottom end.
    case yh = "YH"
    /// Measure: string value with the PCRE reserved characters `.^$*+?()[{\|` escaped with `\`
    /// (use `SectionVariables.escapeRegExp(_:)`).
    case escapeRegExp = "EscapeRegExp"
    /// Measure: string value percent-encoded (use `SectionVariables.encodeUrl(_:)`).
    case encodeUrl = "EncodeURL"
    /// Time measure only: its timestamp number (seconds since 1601-01-01), even when `Format` is set.
    /// Other measures give no value (the section variable is then left as written).
    case timestamp = "Timestamp"

    /// Case-insensitive match of a keyword parameter (surrounding whitespace ignored); nil when unknown.
    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame })
        else { return nil }
        self = match
    }
}

/// String transforms used by keyword section variables.
public enum SectionVariables {
    /// `[Measure:EscapeRegExp]`: every character the manual lists as a PCRE reserved character —
    /// `. ^ $ * + ? ( ) [ { \ |` — is prefixed with `\`. Nothing else changes (the manual's list does not include
    /// `]`, `}`, `-`, `/` or `#`, so neither do we).
    public static func escapeRegExp(_ text: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + 8)
        for b in text.utf8 {
            if regExpReserved(b) { out.append(0x5C) }
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `[Measure:EncodeURL]`: percent-encodes the UTF-8 bytes of every character except the URL-safe
    /// `A–Z a–z 0–9 - _ . ~` (manual: "I live in München" → `I%20live%20in%20M%C3%BCnchen`). Hex digits are
    /// upper case, as in the manual's example.
    public static func encodeUrl(_ text: String) -> String {
        let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 3)
        for b in text.utf8 {
            if urlUnreserved(b) {
                out.append(b)
            } else {
                out.append(0x25)
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always)
    private static func regExpReserved(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "$"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "?"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "{"),
             UInt8(ascii: "\\"), UInt8(ascii: "|"):
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private static func urlUnreserved(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }
}

/// Decimal text for section-variable numbers. Rounds the *shortest round-trip decimal* form of the double
/// (what `print(x)` shows) half away from zero, so `1.005` with 2 decimals gives `1.01` and `2.5` with 0 gives `3`
/// — what a skin author expects — instead of binary-floating-point or banker's rounding artefacts.
enum VarNumberText {
    /// Exactly `decimals` digits after the point (trailing zeros kept). Never produces `-0`.
    /// Non-finite values give `nan`, `inf`, `-inf` (C printf spelling).
    static func fixed(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let decimals = max(0, decimals)
        let (digits, point) = decimalDigits(of: abs(value))

        // `kept` = the digits of round(|value| * 10^decimals).
        let cut = point + decimals
        var kept: [UInt8]
        var roundUp = false
        if cut <= 0 {
            kept = []
            roundUp = cut == 0 && (digits.first ?? 0) >= 5
        } else if cut >= digits.count {
            kept = digits + [UInt8](repeating: 0, count: cut - digits.count)
        } else {
            kept = Array(digits[0..<cut])
            roundUp = digits[cut] >= 5
        }
        if roundUp {
            var k = kept.count - 1
            while k >= 0 {
                if kept[k] == 9 { kept[k] = 0; k -= 1 } else { kept[k] += 1; break }
            }
            if k < 0 { kept.insert(1, at: 0) }
        }

        var firstNonZero = 0
        while firstNonZero < kept.count && kept[firstNonZero] == 0 { firstNonZero += 1 }
        var significant = Array(kept[firstNonZero...])
        let isZero = significant.isEmpty
        if significant.count < decimals + 1 {
            significant = [UInt8](repeating: 0, count: decimals + 1 - significant.count) + significant
        }

        var out: [UInt8] = []
        out.reserveCapacity(significant.count + 2)
        if value < 0 && !isZero { out.append(UInt8(ascii: "-")) }
        let intCount = significant.count - decimals
        for d in significant[0..<intCount] { out.append(0x30 + d) }
        if decimals > 0 {
            out.append(UInt8(ascii: "."))
            for d in significant[intCount...] { out.append(0x30 + d) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Up to `maxDecimals` digits after the point, trailing zeros (and a trailing point) removed.
    static func trimmed(_ value: Double, maxDecimals: Int) -> String {
        let text = fixed(value, decimals: maxDecimals)
        guard value.isFinite, text.utf8.contains(UInt8(ascii: ".")) else { return text }
        var bytes = Array(text.utf8)
        while bytes.last == UInt8(ascii: "0") { bytes.removeLast() }
        if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Decimal digits (no leading zeros except for zero itself) and the position of the decimal point counted
    /// from the left of `digits` (may be negative or larger than the digit count). `value` must be finite, ≥ 0.
    private static func decimalDigits(of value: Double) -> (digits: [UInt8], point: Int) {
        let text = "\(value)"   // shortest round-trip form: "1.005", "100.0", "1e-05", "1.2345e+20"
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        var digits: [UInt8] = []
        var point = 0
        var seenPoint = false
        for u in mantissa.utf8 {
            if u == UInt8(ascii: ".") { seenPoint = true; continue }
            guard u >= 0x30 && u <= 0x39 else { continue }
            digits.append(u - 0x30)
            if !seenPoint { point += 1 }
        }
        point += exponent
        var lead = 0
        while lead < digits.count - 1 && digits[lead] == 0 { lead += 1 }
        if lead > 0 {
            digits.removeFirst(lead)
            point -= lead
        }
        if digits.isEmpty { return ([0], 1) }
        return (digits, point)
    }
}
