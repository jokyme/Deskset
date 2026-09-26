import Foundation

/// Inline Lua section variables: the text after the colon of `[&ScriptMeasure:…]`
/// (manual: /manual/lua-scripting/inline-lua/).
///
/// - `Function(args)` calls a global function with the arguments; `name` retrieves a global variable.
/// - Arguments (manual, "The types of parameters"): numbers ("any number literal, formula or variable that resolves
///   to a number"), `'strings'` / `"strings"`, `true`, `false`, `nil` (case-insensitive in the skin, history
///   notes), and formulas — "Numeric parameters starting with ( are now run through the Rainmeter math parser
///   before being sent to the lua script" (history). An unquoted word is "seen by the Lua as a Lua variable name".
///
/// Judgment calls (documented in docs/compat/lua.md):
/// - A quote only closes a string when it is followed by `,` or the end of the argument list, so values that
///   contain the other kind of quote or an apostrophe (`'[&MeasureTitle]'` with "It's…") still arrive whole.
/// - Inside strings `\\`, `\'`, `\"`, `\n`, `\r`, `\t` are escapes; any other backslash is kept (Windows paths).
/// - A formula the Rainmeter parser cannot evaluate, an unquoted word and any other argument are evaluated as a
///   Lua expression in the script (`myTable.field` works, although the manual does not promise it). Text that is
///   neither a name nor a single call (`t.x`, `f(1)(2)`) is evaluated as a Lua expression too.
enum InlineLuaCall: Equatable {
    case variable(String)
    case call(String, [LuaValue])
    case expression(String)

    /// Parses the text after the colon. `formula` evaluates Rainmeter formulas (measure names allowed).
    static func parse(_ text: String, formula: (String) -> Double? = { try? Formula.evaluate($0) }) -> InlineLuaCall? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if isName(Substring(t)) { return .variable(t) }
        if t.hasSuffix(")"), let open = t.firstIndex(of: "(") {
            let name = t[t.startIndex..<open].trimmingCharacters(in: .whitespaces)
            if isName(Substring(name)) {
                let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
                if let args = arguments(inner, formula: formula) { return .call(name, args) }
            }
        }
        return .expression(t)
    }

    /// A Lua name: letter or `_`, then letters, digits, `_`.
    static func isName(_ s: Substring) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic)
        else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

    /// The comma-separated arguments; nil when the text is not an argument list (unbalanced parentheses).
    static func arguments(_ text: Substring, formula: (String) -> Double?) -> [LuaValue]? {
        let chars = Array(text)
        if chars.allSatisfy({ $0.isWhitespace }) { return [] }
        var args: [LuaValue] = []
        var i = 0
        while i <= chars.count {
            // Skip leading blanks.
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            if i < chars.count, chars[i] == "'" || chars[i] == "\"" {
                guard let (value, next) = quoted(chars, from: i) else { return nil }
                args.append(.text(value))
                i = next
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                if i < chars.count {
                    guard chars[i] == "," else { return nil }
                    i += 1
                    continue
                }
                break
            }
            // Unquoted argument: up to the next comma outside parentheses.
            var depth = 0
            var j = i
            while j < chars.count {
                let c = chars[j]
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth < 0 { return nil } }
                else if c == "," && depth == 0 { break }
                j += 1
            }
            if depth != 0 { return nil }
            args.append(value(String(chars[i..<j]).trimmingCharacters(in: .whitespaces), formula: formula))
            if j >= chars.count { break }
            i = j + 1
        }
        return args
    }

    /// A quoted string starting at `start`: ends at the matching quote that is followed (after blanks) by `,` or
    /// the end of the text.
    private static func quoted(_ chars: [Character], from start: Int) -> (String, Int)? {
        let quote = chars[start]
        var out = ""
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "\\", "'", "\"": out.append(n)
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default:
                    out.append(c)
                    out.append(n)
                }
                i += 2
                continue
            }
            if c == quote {
                var k = i + 1
                while k < chars.count && chars[k].isWhitespace { k += 1 }
                if k >= chars.count || chars[k] == "," { return (out, i + 1) }
            }
            out.append(c)
            i += 1
        }
        return nil
    }

    private static func value(_ arg: String, formula: (String) -> Double?) -> LuaValue {
        if arg.isEmpty { return .none }
        switch arg.lowercased() {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "nil": return .none
        default: break
        }
        if arg.hasPrefix("(") {
            if let n = formula(arg), n.isFinite { return .number(n) }
            return .expression(arg)
        }
        if let n = number(arg) { return .number(n) }
        return .expression(arg)
    }

    /// A Lua number literal (optional sign): decimal with optional exponent, or hexadecimal `0x…`.
    static func number(_ s: String) -> Double? {
        var t = Substring(s)
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t = t.dropFirst() } else if t.hasPrefix("+") { t = t.dropFirst() }
        guard let first = t.first, first.isNumber || first == "." else { return nil }
        if t.lowercased().hasPrefix("0x") {
            let digits = t.dropFirst(2)
            guard !digits.isEmpty, digits.count <= 16, let v = UInt64(digits, radix: 16) else { return nil }
            return sign * Double(v)
        }
        guard t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "e" || $0 == "E" || $0 == "+" || $0 == "-") }),
              let v = Double(t), v.isFinite else { return nil }
        return sign * v
    }

    /// The text that replaces the section variable: strings as returned, numbers in Lua's `tostring` format,
    /// `true` → 1, `false` → 0 (manual), nil → empty. Other types (tables, functions) → nil.
    static func text(_ value: LuaValue) -> String? {
        switch value {
        case .none: return ""
        case .boolean(let b): return b ? "1" : "0"
        case .number(let n): return LuaState.format(n)
        case .string(let s, _): return s
        case .expression, .other: return nil
        }
    }
}
