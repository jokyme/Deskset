import Foundation

/// Rewrites position / size options for the editor's direct manipulation (drag, resize, nudge) while keeping the
/// way the skin author wrote them:
///
/// | written            | moved by +20          |
/// |--------------------|-----------------------|
/// | `100`              | `120`                 |
/// | `10R` / `r`        | `30R` / `20r`         |
/// | `(#A# + 5)`        | `(#A# + 25)`          |
/// | `(#A# * 2)`        | `(#A# * 2 + 20)`      |
/// | `(a > 1 ? 5 : 9)`  | `((a > 1 ? 5 : 9) + 20)` |
/// | `#Margin#`         | `(#Margin# + 20)`     |
/// | missing            | `20`                  |
///
/// Relative suffixes (`r` / `R`, manual: Meters → General Options → X/Y) stay relative, so meters placed after the
/// moved one keep following it. Variables are never replaced by their values: a shared `#Margin#` keeps working for
/// every other meter that uses it.
public enum GeometryEdit {
    /// The option text moved by `delta` (points). Returns `raw` unchanged for a zero delta.
    public static func offset(_ raw: String?, by delta: Double) -> String {
        let text = raw.map(IniSyntax.trim) ?? ""
        guard delta != 0, delta.isFinite else { return raw ?? "" }
        if text.isEmpty { return format(delta) }

        var body = Substring(text)
        var suffix = ""
        if let last = body.last, last == "r" || last == "R" {
            suffix = String(last)
            body = Substring(IniSyntax.trim(body.dropLast()))
        }
        if body.isEmpty { return format(delta) + suffix }
        if let n = plainNumber(body) { return format(n + delta) + suffix }
        if let inner = outerParenthesized(body) {
            if let adjusted = adjustTrailingConstant(inner, by: delta) { return "(" + adjusted + ")" + suffix }
            if isAdditive(inner) { return "(" + IniSyntax.trim(String(inner)) + signed(delta) + ")" + suffix }
            return "((" + IniSyntax.trim(String(inner)) + ")" + signed(delta) + ")" + suffix
        }
        return "(" + String(body) + signed(delta) + ")" + suffix
    }

    /// A number as the editor writes it: integers without decimals, otherwise at most 2 decimals.
    public static func format(_ v: Double) -> String {
        let rounded = (v * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    private static func signed(_ delta: Double) -> String {
        delta < 0 ? " - " + format(-delta) : " + " + format(delta)
    }

    /// `12`, `-3.5`, `+4`, `.5` — nothing else.
    static func plainNumber(_ s: Substring) -> Double? {
        let t = IniSyntax.trim(s)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy({ "0123456789.+-".unicodeScalars.contains($0) }) else { return nil }
        guard let v = Double(t.hasPrefix(".") ? "0" + t : t.hasPrefix("-.") ? "-0" + t.dropFirst() : String(t)),
              v.isFinite else { return nil }
        return v
    }

    /// The inside of `( … )` when one pair of parentheses wraps the whole text.
    static func outerParenthesized(_ s: Substring) -> Substring? {
        guard s.first == "(", s.last == ")" else { return nil }
        var depth = 0
        for (i, c) in zip(s.indices, s) {
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 && i != s.index(before: s.endIndex) { return nil } // `(a) + (b)`
            }
        }
        guard depth == 0 else { return nil }
        return s.dropFirst().dropLast()
    }

    /// True when the top level only combines terms with `+` / `-` (and `*` `/` inside terms), so ` + d` can be
    /// appended without changing what the rest means. `?:`, comparisons and logic operators bind looser than `+`.
    static func isAdditive(_ s: Substring) -> Bool {
        var depth = 0
        for c in s {
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            if depth == 0, "?:<>=&|^~".contains(c) { return false }
        }
        return true
    }

    /// `expr + 5` → `expr + (5 + delta)` when the expression ends with a top-level `+ number` / `- number` term and
    /// is additive; the term disappears when it becomes 0. A lone number inside parentheses is changed too.
    static func adjustTrailingConstant(_ s: Substring, by delta: Double) -> String? {
        let text = IniSyntax.trim(String(s))
        if let n = plainNumber(Substring(text)) { return format(n + delta) }
        guard isAdditive(Substring(text)) else { return nil }
        // Find the last top-level binary + or -.
        let chars = Array(text)
        var depth = 0
        var opIndex: Int?
        for i in chars.indices {
            let c = chars[i]
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            guard depth == 0, c == "+" || c == "-", i > 0 else { continue }
            // Binary only: the previous non-blank character ends an operand.
            var j = i - 1
            while j >= 0, chars[j] == " " || chars[j] == "\t" { j -= 1 }
            guard j >= 0 else { continue }
            let prev = chars[j]
            if prev.isLetter || prev.isNumber || prev == ")" || prev == "#" || prev == "]" || prev == "_" || prev == "." {
                // Not an exponent sign like 1e+5.
                if (prev == "e" || prev == "E"), j > 0, chars[j - 1].isNumber { continue }
                opIndex = i
            }
        }
        guard let op = opIndex else { return nil }
        let tail = String(chars[(op + 1)...])
        guard let constant = plainNumber(Substring(tail)) else { return nil }
        let head = IniSyntax.trim(String(chars[..<op]))
        let value = (chars[op] == "+" ? constant : -constant) + delta
        if value == 0 { return head }
        return head + signed(value)
    }
}
