import Foundation

/// Scanning of numeric literals, shared by the formula lexer and plain-number option reading.
///
/// Accepted forms (clean-room, from docs.rainmeter.net/manual/formulas and /manual/measures/calc):
/// - Decimal: `42`, `2.5`, `0.25`. The manual says `.5` "will cause an error"; we accept it (and `5.`)
///   leniently because rejecting it only breaks skins, never fixes them.
/// - Exponent: `1e3`, `2.5E-4`. Not mentioned by the manual; accepted leniently (numbers produced by other
///   tools/variables may use it). `2e` alone is not a number.
/// - Other bases (Calc page, "Other Bases"): `0b110110` (binary), `0o123` (octal), `0xF1` (hex). The prefix
///   letter is lower-case only, as the manual (and the version history) state; hex digits are case-insensitive.
///   The manual lists these for Calc; we accept them in every formula and plain number (harmless superset).
enum NumericLiteral {
    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    @inline(__always) static func digitValue(_ b: UInt8, base: Int) -> Int? {
        let v: Int
        switch b {
        case 0x30...0x39: v = Int(b) - 0x30
        case 0x61...0x66: v = Int(b) - 0x61 + 10 // a-f
        case 0x41...0x46: v = Int(b) - 0x41 + 10 // A-F
        default: return nil
        }
        return v < base ? v : nil
    }

    /// Scans the longest unsigned literal starting at `start`. Returns its value and the index just past it,
    /// or nil when no digits are found.
    static func scanUnsigned<C: Collection>(_ b: C, from start: C.Index) -> (value: Double, end: C.Index)?
    where C.Element == UInt8 {
        var i = start
        let end = b.endIndex
        guard i < end else { return nil }

        // Based literal: 0x.. / 0b.. / 0o.. (prefix letter must be lower-case).
        if b[i] == 0x30 {
            let p = b.index(after: i)
            if p < end {
                let base: Int
                switch b[p] {
                case 0x78: base = 16 // x
                case 0x62: base = 2  // b
                case 0x6F: base = 8  // o
                default: base = 0
                }
                if base != 0 {
                    var j = b.index(after: p)
                    var value = 0.0
                    var digits = 0
                    while j < end, let d = digitValue(b[j], base: base) {
                        value = value * Double(base) + Double(d)
                        digits += 1
                        j = b.index(after: j)
                    }
                    if digits > 0 { return (value, j) }
                    // "0x" without digits: fall through and read just the "0".
                }
            }
        }

        // Decimal: int digits, optional '.', frac digits, optional exponent.
        var intDigits = 0
        let intStart = i
        while i < end, isDigit(b[i]) { i = b.index(after: i); intDigits += 1 }
        let intEnd = i
        var fracStart = i
        var fracDigits = 0
        if i < end, b[i] == 0x2E { // '.'
            var j = b.index(after: i)
            fracStart = j
            while j < end, isDigit(b[j]) { j = b.index(after: j); fracDigits += 1 }
            if intDigits + fracDigits > 0 { i = j }
        }
        guard intDigits + fracDigits > 0 else { return nil }
        let fracEnd = i

        var expNegative = false
        var expDigitsStart: C.Index?
        var expEnd = i
        if i < end, b[i] == 0x65 || b[i] == 0x45 { // e / E
            var j = b.index(after: i)
            if j < end, b[j] == 0x2B || b[j] == 0x2D { expNegative = b[j] == 0x2D; j = b.index(after: j) }
            let ds = j
            while j < end, isDigit(b[j]) { j = b.index(after: j) }
            if j > ds { expDigitsStart = ds; expEnd = j }
        }

        // Build a canonical string for Double(): "<int>[.<frac>][e[-]<exp>]".
        var s = ""
        if intDigits == 0 { s.append("0") } else { s.append(String(decoding: b[intStart..<intEnd], as: UTF8.self)) }
        if fracDigits > 0 {
            s.append(".")
            s.append(String(decoding: b[fracStart..<fracEnd], as: UTF8.self))
        }
        if let ds = expDigitsStart {
            s.append(expNegative ? "e-" : "e")
            s.append(String(decoding: b[ds..<expEnd], as: UTF8.self))
        }
        guard let value = Double(s) else { return nil }
        return (value, expDigitsStart == nil ? fracEnd : expEnd)
    }

    /// The whole collection must be exactly one unsigned literal.
    static func exact<C: Collection>(_ b: C) -> Double? where C.Element == UInt8 {
        guard let r = scanUnsigned(b, from: b.startIndex), r.end == b.endIndex else { return nil }
        return r.value
    }

    /// strtod-like: optional sign then the longest literal prefix; the rest is ignored.
    /// Returns the value and the index just past the literal.
    static func signedPrefix<C: Collection>(_ b: C) -> (value: Double, end: C.Index)?
    where C.Element == UInt8 {
        var i = b.startIndex
        guard i < b.endIndex else { return nil }
        var negative = false
        if b[i] == 0x2B || b[i] == 0x2D { negative = b[i] == 0x2D; i = b.index(after: i) }
        guard let r = scanUnsigned(b, from: i) else { return nil }
        return (negative ? -r.value : r.value, r.end)
    }
}

/// Small helpers for reading option strings without Character-level (grapheme) iteration.
enum OptionText {
    /// ASCII controls/space, Unicode whitespace (NBSP, U+3000, …) and the invisible zero-width characters
    /// U+200B (zero width space), U+2060 (word joiner) and U+FEFF (BOM / zero width no-break space). The latter
    /// are not Unicode whitespace, but they slip into skins copied from web pages and forum posts (and a BOM
    /// can survive at the start of an @Include'd file's value); they are never meaningful inside a number or a
    /// measure name, so they must not turn `MeasureA<ZWSP>` into an unknown name or `<BOM>5` into "not a number".
    /// (U+200C/U+200D are deliberately not included: they are meaningful inside words of some scripts.)
    @inline(__always) static func isSpace(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x80 { return v < 0x21 || v == 0x7F } // fast path: no Unicode property lookup for ASCII
        if v == 0x200B || v == 0x2060 || v == 0xFEFF { return true }
        return s.properties.isWhitespace
    }

    /// Trims whitespace (including newlines, NBSP and control characters) from both ends.
    static func trim(_ s: Substring) -> Substring {
        let scalars = s.unicodeScalars
        var lo = scalars.startIndex
        var hi = scalars.endIndex
        while lo < hi, isSpace(scalars[lo]) { lo = scalars.index(after: lo) }
        while hi > lo {
            let p = scalars.index(before: hi)
            if isSpace(scalars[p]) { hi = p } else { break }
        }
        return s[lo..<hi]
    }

    static func trim(_ s: String) -> Substring { trim(Substring(s)) }

    /// Splits `s` at every ASCII `separator` that is not inside parentheses, so a formula such as
    /// `(Clamp(x,0,255))` stays one item of a comma list and `(a) || (b)` stays one item of a pipe list
    /// (both are fixes listed in the Rainmeter version history). Unbalanced `)` never makes the depth negative.
    static func splitTopLevel(_ str: Substring, separator: UInt8) -> [Substring] {
        var parts: [Substring] = []
        var depth = 0
        var start = str.startIndex
        let utf8 = str.utf8
        var i = utf8.startIndex
        while i < utf8.endIndex {
            let c = utf8[i]
            if c == 0x28 { depth += 1 } else if c == 0x29 { if depth > 0 { depth -= 1 } } else if c == separator && depth == 0 {
                parts.append(str[start..<i])
                start = utf8.index(after: i)
            }
            i = utf8.index(after: i)
        }
        parts.append(str[start..<str.endIndex])
        return parts
    }

    /// Index just past the `)` matching the `(` at `open`, or nil when unbalanced.
    static func matchingParenEnd(_ s: Substring, open: Substring.Index) -> Substring.Index? {
        var depth = 0
        let utf8 = s.utf8
        var i = open
        while i < utf8.endIndex {
            let c = utf8[i]
            if c == 0x28 {
                depth += 1
            } else if c == 0x29 {
                depth -= 1
                if depth == 0 { return utf8.index(after: i) }
            }
            i = utf8.index(after: i)
        }
        return nil
    }
}
