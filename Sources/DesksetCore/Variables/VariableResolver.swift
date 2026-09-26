import Foundation

// Variables module. Clean-room implementation from the public manual only
// (https://docs.rainmeter.net/manual/variables/ and its sub-pages; see VariableExpansion.swift for the list).

/// How a section variable `[Name:param]` asked for its value.
public enum SectionVariableParameter: Equatable {
    /// `[Name]` — the string value.
    case none
    /// `[Name:]`, `[Name:%]`, `[Name:/1024]`, `[Name:2]`, `[Name:/1024,2]`, `[Name:%,1]` — the number value.
    case number(SectionNumberFormat)
    /// Any other parameter, e.g. `MaxValue`, `MinValue`, `X`, `Y`, `W`, `H`, `XW`, `YH`, `EscapeRegExp`,
    /// `EncodeUrl`, `TimeStamp`. Original spelling kept; compare case-insensitively.
    case keyword(String)

    /// Parses the text after the colon (nil when there was no colon).
    ///
    /// Manual: parameters are separated by commas and the number modifiers combine in any order —
    /// `[M:/1024,4]`, `[M:%,4]`, `[M:/1024,%]`, `[M:/1024,4,%]`. So the text is `.number` when *every*
    /// comma-separated part is `%`, `/divisor` or a decimal count (digits); an empty text is the plain number
    /// (`[M:]`). Anything else is `.keyword` (surrounding whitespace trimmed, spelling kept).
    /// Judgment calls: whitespace around parts is ignored and empty parts are skipped (`[M:2,]`); a repeated
    /// modifier keeps the last one; the manual says the divisor "must be an integer", but any finite non-zero
    /// number is accepted (`/1000.5`); `/0`, `/abc`, negative or fractional decimal counts are not number forms,
    /// so they become keywords — which no engine lookup knows, leaving the variable as written.
    public static func parse(_ raw: String?) -> SectionVariableParameter {
        guard let raw else { return .none }
        if let format = SectionNumberFormat.parse(raw) { return .number(format) }
        return .keyword(raw.trimmingCharacters(in: .whitespaces))
    }

    /// The keyword as a known `SectionVariableKeyword` (case-insensitive), or nil for other parameters.
    public var knownKeyword: SectionVariableKeyword? {
        if case .keyword(let text) = self { return SectionVariableKeyword(text) }
        return nil
    }
}

/// Number formatting requested by a `[Name:…]` section variable.
public struct SectionNumberFormat: Equatable {
    /// `%` — value as a percentage of its MinValue…MaxValue range.
    public var percent: Bool
    /// `/N` — divide the value by N.
    public var divisor: Double?
    /// `,N` or a bare `N` — number of decimals.
    public var decimals: Int?

    public init(percent: Bool = false, divisor: Double? = nil, decimals: Int? = nil) {
        self.percent = percent
        self.divisor = divisor
        self.decimals = decimals
    }

    /// Formats a measure's number value as the manual specifies for this form.
    ///
    /// - No decimals given (`[M:]`, `[M:%]`, `[M:/1024]`): "up to ten decimal places of precision" — rounded to
    ///   10 decimals, trailing zeros and a trailing point removed (`42`, `0.3333333333`).
    /// - Decimals given (`[M:4]`): "with the number of decimal places given" — exactly that many, trailing zeros
    ///   kept (`[M:2]` of 2.5 → `2.50`).
    /// - Rounding is half away from zero on the value's shortest decimal form (2.5 → `3`, 1.005 → `1.01`); the
    ///   manual does not specify a mode. `-0` is never produced; NaN/∞ give `nan`/`inf`/`-inf`.
    /// - `%`: (value − MinValue) / (MaxValue − MinValue) × 100, clamped to 0…100 like the range used by meters.
    ///   A zero-width range gives 0. (Clamping and the zero range are judgment calls.)
    /// - `/N`: divides the (percentage or plain) value by N. When `%` and `/N` are combined the percentage is
    ///   computed first and then divided — the manual allows the combination but does not define it.
    public func format(value: Double, minValue: Double, maxValue: Double) -> String {
        var v = value
        if percent {
            let range = maxValue - minValue
            if !v.isFinite || !range.isFinite || range == 0 {
                v = 0
            } else {
                v = (v - minValue) / range * 100
                v = v < 0 ? 0 : (v > 100 ? 100 : v)
            }
        }
        if let d = divisor, d != 0, d.isFinite {
            v /= d
        }
        if let n = decimals {
            return VarNumberText.fixed(v, decimals: min(max(n, 0), Self.maxDecimals))
        }
        return VarNumberText.trimmed(v, maxDecimals: 10)
    }

    /// Upper bound applied to `decimals` when formatting (keeps absurd requests like `[M:999]` cheap).
    static let maxDecimals = 64

    /// Parses the parameter text of `[Name:text]` when it is a number form (see `SectionVariableParameter.parse`).
    static func parse(_ raw: String) -> SectionNumberFormat? {
        var format = SectionNumberFormat()
        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if p == "%" {
                format.percent = true
            } else if p.hasPrefix("/") {
                let number = p.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !number.isEmpty,
                      number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }),
                      let d = Double(number), d.isFinite, d != 0 else { return nil }
                format.divisor = d
            } else if p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) {
                format.decimals = n
            } else {
                return nil
            }
        }
        return format
    }
}

/// Resolves variables inside option values.
///
/// Syntax handled by `resolve(_:)` (manual pages: Variables, Nesting Variables, Section Variables, Character
/// Variables, Mouse Variables):
///
/// | Form | Meaning | Needs `sectionLookup` |
/// |---|---|---|
/// | `#Var#`, `[#Var]` | variable (names case-insensitive) | no |
/// | `[#Color[#Index]]`, `[#XPos[&Measure]]` | nesting, resolved inside-out | inner `&` only |
/// | `[Name]`, `[Name:param]` | section variable | yes |
/// | `[&Name]`, `[&Name:param]` | nested section variable | yes |
/// | `[\x263A]`, `[\9731]` | character reference | no |
/// | `$MouseX$`, `[$MouseX:%]` | event variable | `eventLookup` |
/// | `#*Var*#`, `[#*Var*]` | escape → `#Var#`, `[#Var]` | no |
/// | `[*Name*]`, `[&*Name*]` | escape → `[Name]`, `[&Name]` | yes |
///
/// Order (manual: "Normal or built-in variables take priority over section variables"): first `#Var#` (so
/// `[#Foo#:#Bar#]` builds a section variable, while `#[Foo][Bar]#` is — as the manual says — not valid and stays),
/// then the nesting forms inside-out, then classic `[Name]`.
///
/// Rules and judgment calls:
/// - Undefined names, unknown sections (the lookup returns nil) and malformed syntax stay exactly as written, so
///   bangs (`[!SetOption A B C]`), URLs and literal brackets survive. A lone `#`, `##` or `[]` is plain text.
/// - A variable's value is plain text substitution: it is resolved further (other variables, and — when
///   `sectionLookup` is set — section variables inside it). A variable that is already being expanded is left
///   as written, so `A=#A#` or `A=#B#`/`B=#A#` terminate.
/// - Values of built-in variables, section variables, character references, event variables and escapes are
///   literal: never re-interpreted, so a measure whose text contains `#X#` or `[Y]` is shown as is, and
///   `[\x5B]` yields a literal `[`. Escaped forms are therefore not resolved in the same pass.
/// - Escapes are unescaped only where their unescaped form would be resolved: `[*Name*]` / `[&*Name*]` only when
///   `sectionLookup` is set, `#*Var*#` / `[#*Var*]` always. This call consumes escapes — resolve a raw option
///   string exactly once (e.g. keep action strings raw until the bang executes), or an escaped reference would
///   be resolved by the second call. `#**Var**#` → `#*Var*#` gives two levels of protection.
/// - Character references accept any Unicode scalar up to U+10FFFF (manual: x0–xFFFE / 0–65536 on Windows); a
///   surrogate or larger value stays as written.
/// - Windows environment variables (`%APPDATA%`) are not handled here.
/// - Limits against hostile input: 32 variables deep, 32 bracket levels, 20 000 substitutions, 1 MiB of
///   substituted text, 50 000 lookups and 4 MiB (+ 4× the input) of scanned text per call; past them references
///   stay as written.
public struct VariableResolver {
    /// Variable name (without `#`, any case) → value, or nil when undefined. Built-in variables such as
    /// `CURRENTSECTION` are answered by this closure too.
    public var variableLookup: (String) -> String?
    /// Section name (any case) + parameter → value, or nil when `name` is not a measure/meter (the text is then
    /// left untouched). When this closure is nil, section variables are not resolved at all (non-dynamic options).
    public var sectionLookup: ((String, SectionVariableParameter) -> String?)?
    /// Event variable name as written between the `$` signs or after `[$` (e.g. `MouseX`, `MouseY:%`) → value, or
    /// nil when unknown. Set it only while executing an action that has event values (a mouse action); when nil,
    /// `$…$` and `[$…]` are left untouched.
    public var eventLookup: ((String) -> String?)?

    public init(variableLookup: @escaping (String) -> String?,
                sectionLookup: ((String, SectionVariableParameter) -> String?)? = nil) {
        self.variableLookup = variableLookup
        self.sectionLookup = sectionLookup
        self.eventLookup = nil
    }

    /// Same as `init(variableLookup:sectionLookup:)`, also resolving event variables such as `$MouseX$`.
    public init(variableLookup: @escaping (String) -> String?,
                sectionLookup: ((String, SectionVariableParameter) -> String?)? = nil,
                eventLookup: ((String) -> String?)?) {
        self.variableLookup = variableLookup
        self.sectionLookup = sectionLookup
        self.eventLookup = eventLookup
    }

    /// Resolves `#Var#`, nested `[#Var]` / `[#Color[#Index]]`, `[&Measure]`, section variables `[Name]` /
    /// `[Name:param]` (only when `sectionLookup` is set), character variables `[\x263A]` / `[\9731]`, and the
    /// escapes `#*Var*#` → `#Var#`, `[*Name*]` → `[Name]`, in the order the manual specifies.
    /// Undefined names are left as written. Never loops forever on self-referencing values.
    /// See the type documentation for the complete rules.
    public func resolve(_ text: String) -> String {
        guard Self.mayContainSyntax(text, events: eventLookup != nil) else { return text }
        return VarExpansion(variableLookup: variableLookup, sectionLookup: sectionLookup, eventLookup: eventLookup,
                            fullSyntax: true, rescanValues: true).run(text)
    }

    /// Resolves only the standard `#Var#` form (recursively through variable values), leaving the escape
    /// `#*Var*#`, the nesting forms (`[#Var]`, `[&Measure]`, `[\x…]`, `[$…]`), section variables and event
    /// variables exactly as written.
    ///
    /// The engine can use it to pre-resolve action strings when an option is read, which reproduces the manual's
    /// rule that in bangs `#Var#` takes the value from when the option was read while the nesting syntax is
    /// "always dynamically resolved when used"; the full `resolve(_:)` then runs when the bang executes (escapes
    /// survive the first call). Note that the returned text no longer knows which parts were built-in values, so
    /// a built-in path that itself contains `#…#` or `[…]` can be re-read as syntax by that second call.
    /// (`[Variables]` definitions are resolved differently — see `resolveDefinitions`.)
    public func resolveStandardVariables(_ text: String) -> String {
        guard text.utf8.contains(VarByte.hash) else { return text }
        return VarExpansion(variableLookup: variableLookup, sectionLookup: nil, eventLookup: nil,
                            fullSyntax: false, rescanValues: true).run(text)
    }

    /// Turns the ordered `[Variables]` entries (after @Include merging) into the final variable table
    /// (keys lowercased), resolving references between variables the way the manual describes.
    /// `builtins` (keys lowercased) are available to the definitions and are not overridden by them unless the manual says so.
    ///
    /// - "Variables can also be used to define other variables" (`MyVar2=https://www.#MyVar1#.net/`): `#Var#`
    ///   references are replaced when the skin loads. Forward references to a later entry work too (judgment
    ///   call: the manual does not restrict the order), and so do built-ins (`Dir=#@#Images/`).
    /// - Built-ins win over a `[Variables]` entry with the same name: the manual says names must "not conflict
    ///   with Rainmeter's built-in variables" and built-ins "cannot be directly modified by actions".
    /// - When a key occurs more than once, the later entry wins (as for sections merged by @Include).
    ///   Keys starting with `@Include` are directives and are skipped.
    /// - `#Var#` and the nested variable form `[#Var]` / `[#Color[#Index]]` are replaced: the nesting page says the
    ///   nested forms "function exactly as their normal counterparts do" and that their one difference (dynamic
    ///   resolution) "only applies to use in bangs", so `B=[#A]` is fixed at load time exactly like `B=#A#`.
    /// - Formulas are not evaluated ("the [Variables] section itself does not resolve the formula"); escapes
    ///   (`#*X*#`, `[#*X*]`), character variables (`[\x263A]`), `[&M]`, section and event variables are kept
    ///   verbatim — `[Variables]` cannot use dynamic variables — and are resolved where the variable is used
    ///   (inner `#X#` / `[#X]` parts of them are replaced: `[&M[#Idx]]` → `[&M2]`).
    /// - Undefined and circular references (`A=#B#`, `B=#A#`) stay as written; nothing loops. All definitions
    ///   together may substitute at most 4 MiB of text (hostile `E2=#E1##E1#`-style chains); past that,
    ///   references stay as written.
    public static func resolveDefinitions(_ entries: [IniEntry], builtins: [String: String]) -> [String: String] {
        VarDefinitionTable(entries: entries, builtins: builtins).table()
    }

    /// Quick reject: text without `#`, `[` (and `$` when event variables are on) has nothing to resolve.
    private static func mayContainSyntax(_ text: String, events: Bool) -> Bool {
        let scan: (UnsafeBufferPointer<UInt8>) -> Bool = { buffer in
            for b in buffer where b == VarByte.hash || b == VarByte.open || (events && b == VarByte.dollar) {
                return true
            }
            return false
        }
        if let result = text.utf8.withContiguousStorageIfAvailable(scan) { return result }
        return text.utf8.contains { $0 == VarByte.hash || $0 == VarByte.open || (events && $0 == VarByte.dollar) }
    }
}
