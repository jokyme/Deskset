import Foundation

// PCRE → ICU (NSRegularExpression) pattern translation.
//
// Skins are written against PCRE (manual: "Option Types > Regular expression options", WebParser, Substitute,
// IfMatch). The WebParser tutorial explains the ubiquitous `(?siU)` prefix: s = dot matches newlines, i = case
// insensitive, U = "ungreedy". ICU has no U flag, so ungreedy mode is implemented by inverting the greediness of
// every quantifier while U is in effect. The WebParser lookahead tip uses conditionals `(?(?=…)…)`, which ICU also
// lacks; they are rewritten into equivalent alternations.
//
// The translation is a single recursive-descent pass that understands just enough PCRE syntax to know what is a
// quantifier (escapes, \Q…\E, character classes, groups, comments, extended mode). It never fails: anything it does
// not understand is copied through so that ICU reports the error, and constructs ICU cannot express at all
// (recursion / subroutine calls) mark the pattern as unsupported.
//
// Differences handled (PCRE → ICU):
// - Inline flags: `U` (ungreedy) → quantifiers inverted; `x` (extended) → whitespace / `#` comments removed here
//   (ICU would otherwise also ignore whitespace inside classes, PCRE does not); `X`, `J` dropped.
// - Literal `{` / `}` that are not a valid `{n}`, `{n,}`, `{n,m}` quantifier → escaped (ICU rejects them).
// - Possessive quantifiers `X*+` → atomic groups `(?>X*)` (same meaning; ICU's possessive loops never match when X
//   can match the empty string).
// - Character classes: `[`, `{`, `}`, `&`, `$`, `#`, `:` and whitespace escaped (ICU treats `[` as a nested set,
//   `[:` as the start of a `[:Property:]` set, `&&` and `--` as set operators, and ignores whitespace under x);
//   PCRE's hyphen rules (range only between two single characters, literal at the edges / after a range / next to a
//   set) are resolved here and every literal `-` is escaped; POSIX classes `[:alpha:]` / `[:^alpha:]` expanded to
//   their ASCII meaning; `\b` = backspace. (Checked against Perl on ~20 000 random classes.)
// - `\cX` → the exact code point (PCRE flips bit 6, ICU masks with 0x1F: they differ for `\c?`, `\c$`, …).
// - Conditionals: `(?(?=A)Y|N)` → `(?:(?=A)Y|(?!A)N)` (same for `?!`, `?<=`, `?<!`); a group-reference condition
//   `(?(1)Y|N)` / `(?(<name>)…)` has no ICU equivalent → best effort `(?:Y|N)`; `(?(DEFINE)…)` never matches its body.
// - Named groups `(?P<n>…)`, `(?'n'…)` → `(?<n>…)`; references `(?P=n)`, `\k'n'`, `\k{n}`, `\g{n}` → `\k<n>`;
//   names are made ICU-legal (ASCII letters/digits only).
// - `\g{N}`, `\gN`, `\g{-N}` → numbered back references; `\ddd` that PCRE reads as octal and `\0dd`, `\o{…}` → `\x{…}`.
// - `\pL` → `\p{L}`, `\p{^L}` → `\P{L}`, `\p{L&}` → `\p{LC}`, PCRE's `\p{Xan}` / `\p{Xwd}` / `\p{Xsp}` / `\p{Xps}`.
// - `\N` (not newline) → `[^\n]`, `\C` → any character, `\x` without digits → NUL, `\E` without `\Q` ignored,
//   escaped letters with no meaning in PCRE (`\y`, `\q`, …) → the literal letter.
// - `(?|…)` branch reset → `(?:…)` (best effort: later branches get new group numbers).
// - Verbs: `(*FAIL)` / `(*F)` → `(?!)`; start-of-pattern options such as `(*UTF8)`, `(*UCP)`, `(*CRLF)` dropped;
//   `(*SKIP)`, `(*PRUNE)`, `(*COMMIT)`, `(*THEN)`, `(*MARK)`, `(*ACCEPT)` dropped (best effort).
// - `\K` (reset match start) dropped (best effort: the overall match then also contains the text before `\K`).
// - Recursion / subroutines `(?R)`, `(?1)`, `(?-1)`, `(?&n)`, `(?P>n)`, `\g<n>` → unsupported.
// Not translated (ICU semantics are close enough): `\w`, `\d`, `\b` and `(?i)` are Unicode-aware in ICU (PCRE without
// UCP is ASCII-only); `.` and `$` also treat `\r`, U+2028 etc. as line ends in ICU.
// Known ICU engine bugs (found by differential testing against Perl, not fixable by translation): a *lazy* loop
// over a body that can match the empty string (`(?:\s*)+?b`, and so `(?U)(?:\s*)+b`) may miss a match or spin until
// the `PCRE.timeLimitNanoseconds` guard stops it; `\b` next to `\z` / `\B` at the very end can disagree with PCRE.
// Typical skin patterns (`(?siU)<tag>(.*)</tag>`, loops over non-empty bodies) are not affected.

struct PCREConversion: Equatable {
    var pattern: String
    /// False when the pattern uses a PCRE feature ICU cannot express (recursion, subroutine calls, …).
    var isSupported: Bool
}

struct PCREConverter {
    private let s: [Unicode.Scalar]
    private let n: Int
    private var i = 0
    /// Capturing groups opened so far (for relative references and octal-vs-backreference decisions).
    private var captureCount = 0
    private var isSupported = true
    /// Nesting of conditionals being translated (each one parses its assertion twice).
    private var conditionalDepth = 0

    /// Deep enough for any real pattern; keeps recursion shallow for background threads' small stacks.
    private static let maxDepth = 64
    private static let maxConditionalDepth = 6

    private struct Flags {
        var ungreedy = false
        var extended = false
    }

    static func convert(_ pattern: String) -> PCREConversion {
        var converter = PCREConverter(pattern)
        let result = converter.run()
        return PCREConversion(pattern: result, isSupported: converter.isSupported)
    }

    private init(_ pattern: String) {
        s = Array(pattern.unicodeScalars)
        n = s.count
    }

    private mutating func run() -> String {
        var out = ""
        var flags = Flags()
        while true {
            out += parseAlternation(&flags, depth: 0, noCapture: false).joined(separator: "|")
            guard i < n else { break }
            // Unbalanced ")" — PCRE rejects the pattern; keep it so that ICU rejects it too.
            out += ")"
            i += 1
        }
        return out
    }

    // MARK: - Sequences

    /// Parses alternatives up to (not including) the `)` that closes the current group, or the end of the pattern.
    /// Option settings like `(?U)` persist to the end of the group, across `|` (as in PCRE).
    private mutating func parseAlternation(_ flags: inout Flags, depth: Int, noCapture: Bool) -> [String] {
        var alternatives: [String] = []
        var current = ""
        while i < n {
            let c = s[i]
            if c == ")" { break }
            if c == "|" {
                alternatives.append(current)
                current = ""
                i += 1
                continue
            }
            if flags.extended {
                if Self.isSpace(c) { i += 1; continue }
                if c == "#" { skipLineComment(); continue }
            }
            let (atom, quantifiable) = parseAtom(&flags, depth: depth, noCapture: noCapture)
            guard quantifiable else {
                current += atom
                continue
            }
            let quantifier = parseQuantifier(flags)
            if quantifier.possessive {
                // `X*+` ≡ `(?>X*)` in PCRE. ICU's own possessive loops fail outright when X can match the empty
                // string (`(a|)*+x` never matches "x"), while its atomic groups behave correctly.
                current += "(?>" + atom + quantifier.text + ")"
            } else {
                current += atom + quantifier.text
            }
        }
        alternatives.append(current)
        return alternatives
    }

    private mutating func parseAtom(_ flags: inout Flags, depth: Int, noCapture: Bool) -> (String, Bool) {
        let c = s[i]
        switch c {
        case "\\":
            return parseEscape()
        case "[":
            return (parseClass(), true)
        case "(":
            return parseGroup(&flags, depth: depth, noCapture: noCapture)
        case "{", "}":
            // Not a valid quantifier here (those are consumed by `parseQuantifier`): a literal brace in PCRE.
            i += 1
            return ("\\" + String(c), true)
        case "^", "$":
            i += 1
            return (String(c), false)
        default:
            i += 1
            return (String(c), true)
        }
    }

    /// Reads an optional quantifier after an atom and applies ungreedy mode. A possessive quantifier is returned
    /// without its `+` and flagged, so the caller can emit it as an atomic group.
    private mutating func parseQuantifier(_ flags: Flags) -> (text: String, possessive: Bool) {
        if flags.extended { skipSpaceAndComments() }
        guard i < n else { return ("", false) }
        var quantifier: String
        var exact = false
        switch s[i] {
        case "*", "+", "?":
            quantifier = String(s[i])
            i += 1
        case "{":
            guard let interval = interval(at: i) else { return ("", false) }
            quantifier = interval.text
            exact = interval.exact
            i = interval.end
        default:
            return ("", false)
        }
        var lazy = false
        var possessive = false
        if i < n {
            if s[i] == "?" {
                lazy = true
                i += 1
            } else if s[i] == "+" {
                possessive = true
                i += 1
            }
        }
        // (?U): greedy ↔ lazy. Possessive quantifiers are unaffected; `{n}` means the same either way.
        if flags.ungreedy && !possessive && !exact { lazy.toggle() }
        if lazy && !possessive { quantifier += "?" }
        return (quantifier, possessive)
    }

    /// `{n}`, `{n,}`, `{n,m}` (PCRE: anything else starting with `{` is literal).
    private func interval(at start: Int) -> (text: String, end: Int, exact: Bool)? {
        var j = start + 1
        let minStart = j
        while j < n && Self.isDigit(s[j]) { j += 1 }
        guard j > minStart, j < n else { return nil }
        let minText = text(minStart ..< j)
        if s[j] == "}" { return ("{\(minText)}", j + 1, true) }
        guard s[j] == "," else { return nil }
        j += 1
        let maxStart = j
        while j < n && Self.isDigit(s[j]) { j += 1 }
        guard j < n, s[j] == "}" else { return nil }
        return ("{\(minText),\(text(maxStart ..< j))}", j + 1, false)
    }

    // MARK: - Escapes (outside classes)

    private mutating func parseEscape() -> (String, Bool) {
        guard i + 1 < n else {
            // Trailing backslash: an error in PCRE; keep it so ICU reports it.
            i = n
            return ("\\", true)
        }
        let e = s[i + 1]
        switch e {
        case "Q":
            i += 2
            let literal = readQuotedLiteral()
            return literal.isEmpty ? ("", false) : ("\\Q" + literal + "\\E", true)
        case "E":
            i += 2
            return ("", false)
        case "b", "B", "A", "z", "Z", "G":
            i += 2
            return ("\\" + String(e), false)
        case "K":
            i += 2
            return ("", false)
        case "N":
            if i + 2 < n && s[i + 2] == "{" { return (copyThrough("}"), true) }
            i += 2
            return ("[^\\n]", true)
        case "C":
            i += 2
            return ("[\\s\\S]", true)
        case "g":
            return parseGReference()
        case "k":
            return parseKReference()
        case "o":
            return (parseBracedOctal(), true)
        case "p", "P":
            return (parseProperty(), true)
        case "x":
            return (parseHex(), true)
        case "c":
            return (parseControlEscape(), true)
        case "0":
            i += 2
            return (octal(maxExtraDigits: 2, prefix: "0"), true)
        case "1" ... "9":
            return (parseDigitEscape(), true)
        default:
            i += 2
            if Self.isASCIILetter(e) {
                // Known escapes (\d, \w, \s, \h, \v, \R, \X, \n, \t, …) are shared; letters with no meaning in PCRE
                // stand for themselves.
                return (Self.pcreLiteralLetters.contains(e) ? String(e) : "\\" + String(e), true)
            }
            if e.value > 0x20 && e.value < 0x7F { return ("\\" + String(e), true) } // escaped punctuation
            return (Self.hexEscape(e.value), true) // escaped space, control or non-ASCII character: itself
        }
    }

    /// Letters PCRE treats as themselves when escaped (no special meaning); ICU might not.
    private static let pcreLiteralLetters: Set<Unicode.Scalar> = ["i", "j", "m", "q", "y", "F", "I", "J", "M", "O",
                                                                  "T", "Y"]

    /// Content of `\Q…\E` (the `\Q` already consumed); consumes the `\E` if present.
    private mutating func readQuotedLiteral() -> String {
        let start = i
        while i < n {
            if s[i] == "\\" && i + 1 < n && s[i + 1] == "E" {
                let literal = text(start ..< i)
                i += 2
                return literal
            }
            i += 1
        }
        return text(start ..< n)
    }

    /// `\1`…`\9` are back references; longer numbers are back references only when that many groups were opened
    /// before, otherwise PCRE reads up to three octal digits (`\101` = "A").
    private mutating func parseDigitEscape() -> String {
        var j = i + 1
        while j < n && Self.isDigit(s[j]) { j += 1 }
        let digits = text(i + 1 ..< j)
        let number = digits.count > 6 ? Int.max : (Int(digits) ?? Int.max)
        if number < 10 || number <= captureCount || s[i + 1] == "8" || s[i + 1] == "9" {
            i = j
            // Wrapped so that a following literal digit cannot extend the reference in ICU.
            return "(?:\\" + digits + ")"
        }
        i += 1
        return octal(maxExtraDigits: 2, prefix: "")
    }

    /// Reads up to `1 + maxExtraDigits` octal digits at `i` (after `prefix` digits already consumed) → `\x{…}`.
    private mutating func octal(maxExtraDigits: Int, prefix: String) -> String {
        var digits = prefix
        let limit = prefix.isEmpty ? maxExtraDigits + 1 : maxExtraDigits
        var count = 0
        while i < n && count < limit && Self.isOctal(s[i]) {
            digits.unicodeScalars.append(s[i])
            i += 1
            count += 1
        }
        let value = Int(digits, radix: 8) ?? 0
        return Self.hexEscape(UInt32(value))
    }

    /// `\cX`: PCRE upper-cases a letter and then flips bit 6 (`\cA` = 0x01, `\c?` = 0x7F, `\c$` = "d"); ICU masks
    /// with 0x1F instead, which differs for everything but letters and `@[\]^_`. Emitted as the exact code point.
    private mutating func parseControlEscape() -> String {
        guard i + 2 < n, s[i + 2].isASCII else {
            // `\c` at the end or before a non-ASCII character: an error in PCRE; keep it so ICU reports it too.
            isSupported = false
            let start = i
            i = min(i + 3, n)
            return text(start ..< i)
        }
        var value = s[i + 2].value
        if value >= 0x61 && value <= 0x7A { value -= 0x20 }
        i += 3
        return Self.hexEscape(value ^ 0x40)
    }

    /// `\o{ddd}`.
    private mutating func parseBracedOctal() -> String {
        guard i + 2 < n, s[i + 2] == "{", let close = index(of: "}", from: i + 3) else {
            i += 2
            return "o"
        }
        let digits = text(i + 3 ..< close)
        i = close + 1
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy(Self.isOctal),
              let value = UInt32(digits, radix: 8), value <= 0x10FFFF else {
            isSupported = false
            return "\\o{" + digits + "}"
        }
        return Self.hexEscape(value)
    }

    /// `\x{hhh}`, `\xhh`, bare `\x` (= NUL in PCRE).
    private mutating func parseHex() -> String {
        if i + 2 < n && s[i + 2] == "{" {
            guard let close = index(of: "}", from: i + 3) else { return copyThrough(nil) }
            let digits = text(i + 3 ..< close)
            i = close + 1
            guard !digits.isEmpty, digits.unicodeScalars.allSatisfy(Self.isHex),
                  let value = UInt32(digits, radix: 16), value <= 0x10FFFF else {
                isSupported = false
                return "\\x{" + digits + "}"
            }
            return Self.hexEscape(value)
        }
        i += 2
        var digits = ""
        while i < n && digits.unicodeScalars.count < 2 && Self.isHex(s[i]) {
            digits.unicodeScalars.append(s[i])
            i += 1
        }
        return Self.hexEscape(UInt32(digits, radix: 16) ?? 0)
    }

    /// `\pL`, `\p{L}`, `\p{^L}`, `\P{…}`.
    private mutating func parseProperty() -> String {
        var negated = s[i + 1] == "P"
        var name: String
        if i + 2 < n && s[i + 2] == "{" {
            guard let close = index(of: "}", from: i + 3) else { return copyThrough(nil) }
            name = text(i + 3 ..< close)
            i = close + 1
        } else if i + 2 < n {
            name = String(s[i + 2])
            i += 3
        } else {
            i = n
            return negated ? "\\P" : "\\p"
        }
        if name.hasPrefix("^") {
            negated.toggle()
            name.removeFirst()
        }
        switch name {
        case "L&": name = "LC"
        case "Xan": return negated ? "[^\\p{L}\\p{N}]" : "[\\p{L}\\p{N}]"
        case "Xwd": return negated ? "[^\\p{L}\\p{N}_]" : "[\\p{L}\\p{N}_]"
        case "Xsp", "Xps": return negated ? "\\S" : "\\s"
        default: break
        }
        return (negated ? "\\P{" : "\\p{") + name + "}"
    }

    /// `\g{N}`, `\gN`, `\g{-N}`, `\g-N`, `\g{name}`; `\g<…>` / `\g'…'` (subroutine calls) are unsupported.
    private mutating func parseGReference() -> (String, Bool) {
        let j = i + 2
        var reference: String
        if j < n && s[j] == "{" {
            guard let close = index(of: "}", from: j + 1) else { return (copyThrough(nil), true) }
            reference = text(j + 1 ..< close)
            i = close + 1
        } else if j < n && (s[j] == "-" || s[j] == "+" || Self.isDigit(s[j])) {
            var k = j + 1
            while k < n && Self.isDigit(s[k]) { k += 1 }
            reference = text(j ..< k)
            i = k
        } else if j < n && (s[j] == "<" || s[j] == "'") {
            let closer: Unicode.Scalar = s[j] == "<" ? ">" : "'"
            isSupported = false
            if let close = index(of: closer, from: j + 1) {
                let raw = text(i ..< close + 1)
                i = close + 1
                return (raw, true)
            }
            return (copyThrough(nil), true)
        } else {
            i = j
            return ("g", true)
        }
        if let number = Int(reference) {
            let absolute = number < 0 ? captureCount + 1 + number : number
            guard absolute > 0, !reference.hasPrefix("+") else {
                isSupported = false
                return ("\\g{" + reference + "}", true)
            }
            return ("(?:\\" + String(absolute) + ")", true)
        }
        return ("\\k<" + Self.icuGroupName(reference) + ">", true)
    }

    /// `\k<name>`, `\k'name'`, `\k{name}`.
    private mutating func parseKReference() -> (String, Bool) {
        let j = i + 2
        guard j < n else { i = n; return ("k", true) }
        let closer: Unicode.Scalar
        switch s[j] {
        case "<": closer = ">"
        case "'": closer = "'"
        case "{": closer = "}"
        default:
            i = j
            return ("k", true)
        }
        guard let close = index(of: closer, from: j + 1) else { return (copyThrough(nil), true) }
        let name = text(j + 1 ..< close)
        i = close + 1
        return ("\\k<" + Self.icuGroupName(name) + ">", true)
    }

    // MARK: - Groups

    private mutating func parseGroup(_ flags: inout Flags, depth: Int, noCapture: Bool) -> (String, Bool) {
        if depth >= Self.maxDepth {
            isSupported = false
            let rest = text(i ..< n)
            i = n
            return (rest, false)
        }
        if peek(1) == "*" { return parseVerb() }
        guard peek(1) == "?" else {
            i += 1
            let open: String
            if noCapture {
                open = "(?:"
            } else {
                captureCount += 1
                open = "("
            }
            return (open + parseBody(flags, depth: depth, noCapture: noCapture), true)
        }
        guard let kind = peek(2) else {
            i = n
            isSupported = false
            return ("(?", false)
        }
        switch kind {
        case "#":
            // (?# comment ) — ends at the first ")".
            i += 3
            while i < n && s[i] != ")" { i += 1 }
            if i < n { i += 1 }
            return ("", false)
        case ":":
            i += 3
            return ("(?:" + parseBody(flags, depth: depth, noCapture: noCapture), true)
        case ">":
            i += 3
            return ("(?>" + parseBody(flags, depth: depth, noCapture: noCapture), true)
        case "|":
            // Branch reset has no ICU equivalent; a plain group matches the same text.
            i += 3
            return ("(?:" + parseBody(flags, depth: depth, noCapture: noCapture), true)
        case "=", "!":
            i += 3
            return ("(?" + String(kind) + parseBody(flags, depth: depth, noCapture: noCapture), true)
        case "<":
            if let next = peek(3), next == "=" || next == "!" {
                i += 4
                return ("(?<" + String(next) + parseBody(flags, depth: depth, noCapture: noCapture), true)
            }
            return parseNamedGroup(nameStart: i + 3, closer: ">", flags, depth: depth, noCapture: noCapture)
        case "'":
            return parseNamedGroup(nameStart: i + 3, closer: "'", flags, depth: depth, noCapture: noCapture)
        case "P":
            if peek(3) == "<" {
                return parseNamedGroup(nameStart: i + 4, closer: ">", flags, depth: depth, noCapture: noCapture)
            }
            if peek(3) == "=" {
                guard let close = index(of: ")", from: i + 4) else { return (copyThrough(nil), false) }
                let name = text(i + 4 ..< close)
                i = close + 1
                return ("\\k<" + Self.icuGroupName(name) + ">", true)
            }
            return unsupportedGroup()
        case "(":
            return parseConditional(flags, depth: depth, noCapture: noCapture)
        case "R", "&", "+", "0" ... "9":
            return unsupportedGroup()
        case "-" where peek(3).map(Self.isDigit) == true:
            return unsupportedGroup()
        default:
            return parseOptionGroup(&flags, depth: depth, noCapture: noCapture)
        }
    }

    /// Parses the rest of a group (after its opening) including the closing `)`; option changes stay inside.
    private mutating func parseBody(_ outer: Flags, depth: Int, noCapture: Bool) -> String {
        var inner = outer
        var body = parseAlternation(&inner, depth: depth + 1, noCapture: noCapture).joined(separator: "|")
        if i < n && s[i] == ")" {
            i += 1
            body += ")"
        } else {
            isSupported = false // missing ")" — PCRE rejects this; ICU will too
        }
        return body
    }

    private mutating func parseNamedGroup(nameStart: Int, closer: Unicode.Scalar, _ flags: Flags, depth: Int,
                                          noCapture: Bool) -> (String, Bool) {
        guard let close = index(of: closer, from: nameStart) else { return unsupportedGroup() }
        let name = text(nameStart ..< close)
        guard Self.isValidPCREName(name) else { return unsupportedGroup() }
        i = close + 1
        let open: String
        if noCapture {
            open = "(?:"
        } else {
            captureCount += 1
            open = "(?<" + Self.icuGroupName(name) + ">"
        }
        return (open + parseBody(flags, depth: depth, noCapture: noCapture), true)
    }

    /// `(?imsxUXJ-imsxUXJ)` (applies to the rest of the enclosing group) or `(?flags:…)` (scoped group).
    private mutating func parseOptionGroup(_ flags: inout Flags, depth: Int, noCapture: Bool) -> (String, Bool) {
        var j = i + 2
        var enable = true
        var updated = flags
        var icuOn = ""
        var icuOff = ""
        while j < n {
            let c = s[j]
            if c == ")" || c == ":" { break }
            switch c {
            case "-":
                enable = false
            case "i", "m", "s":
                if enable { icuOn.unicodeScalars.append(c) } else { icuOff.unicodeScalars.append(c) }
            case "x":
                updated.extended = enable
            case "U":
                updated.ungreedy = enable
            case "X", "J":
                break // PCRE-only (extra / duplicate names): no ICU meaning
            case "^":
                // PCRE2 `(?^)`: reset i, m, n, s, x.
                icuOff += "ims"
                updated.extended = false
            default:
                return unsupportedGroup()
            }
            j += 1
        }
        guard j < n else { return unsupportedGroup() }
        let flagText = icuOn + (icuOff.isEmpty ? "" : "-" + icuOff)
        if s[j] == ")" {
            i = j + 1
            flags = updated
            return (flagText.isEmpty ? "" : "(?" + flagText + ")", false)
        }
        i = j + 1
        return ("(?" + flagText + ":" + parseBody(updated, depth: depth, noCapture: noCapture), true)
    }

    /// `(?(condition)yes|no)`.
    private mutating func parseConditional(_ flags: Flags, depth: Int, noCapture: Bool) -> (String, Bool) {
        let conditionStart = i + 3
        var assertion: (kind: String, negated: String, length: Int)?
        if peek(3) == "?" {
            let first = peek(4)
            let second = peek(5)
            if first == "=" {
                assertion = ("?=", "?!", 2)
            } else if first == "!" {
                assertion = ("?!", "?=", 2)
            } else if first == "<" && second == "=" {
                assertion = ("?<=", "?<!", 3)
            } else if first == "<" && second == "!" {
                assertion = ("?<!", "?<=", 3)
            }
        }

        guard let assertion else {
            // Group reference / name / recursion / DEFINE condition.
            guard let close = index(of: ")", from: conditionStart) else { return unsupportedGroup() }
            let condition = text(conditionStart ..< close)
            i = close + 1
            let branches = parseBranches(flags, depth: depth, noCapture: noCapture)
            if condition == "DEFINE" {
                // The body only defines groups for subroutine calls and never matches by itself.
                return ("(?:(?!)(?:" + branches.joined(separator: "|") + "))?", false)
            }
            // "Did group N match?" cannot be expressed in ICU: best effort, allow either branch.
            return ("(?:" + (branches.count == 1 ? branches[0] + "|" : branches.joined(separator: "|")) + ")", true)
        }

        guard conditionalDepth < Self.maxConditionalDepth else { return unsupportedGroup() }
        conditionalDepth += 1
        defer { conditionalDepth -= 1 }

        // The assertion body is emitted twice: as written, and negated for the "no" branch. The negated copy must
        // not add capture groups (numbering would shift), so it is re-parsed in no-capture mode.
        i = conditionStart + assertion.length
        let bodyStart = i
        let capturesBefore = captureCount
        let positive = parseBody(flags, depth: depth + 1, noCapture: noCapture)
        let bodyEnd = i
        let capturesAfter = captureCount
        i = bodyStart
        captureCount = capturesBefore
        let negative = parseBody(flags, depth: depth + 1, noCapture: true)
        i = bodyEnd
        captureCount = capturesAfter

        let branches = parseBranches(flags, depth: depth, noCapture: noCapture)
        let yes = branches[0]
        let no: String
        switch branches.count {
        case 1: no = ""
        case 2: no = branches[1]
        default: no = "(?:" + branches.dropFirst().joined(separator: "|") + ")" // PCRE: too many branches
        }
        return ("(?:(" + assertion.kind + positive + yes + "|(" + assertion.negated + negative + no + ")", true)
    }

    /// The `yes|no` part of a conditional, consuming the closing `)`.
    private mutating func parseBranches(_ flags: Flags, depth: Int, noCapture: Bool) -> [String] {
        var inner = flags
        let branches = parseAlternation(&inner, depth: depth + 1, noCapture: noCapture)
        if i < n && s[i] == ")" { i += 1 } else { isSupported = false }
        return branches
    }

    /// `(*VERB)`.
    private mutating func parseVerb() -> (String, Bool) {
        guard let close = index(of: ")", from: i + 2) else { return unsupportedGroup() }
        let verb = text(i + 2 ..< close)
        i = close + 1
        let startOptions: Set<String> = ["UTF", "UTF8", "UTF16", "UTF32", "UCP", "CR", "LF", "CRLF", "ANYCRLF", "ANY",
                                         "NUL", "BSR_ANYCRLF", "BSR_UNICODE", "NO_START_OPT", "NO_AUTO_POSSESS",
                                         "NO_DOTSTAR_ANCHOR", "NO_JIT", "NOTEMPTY", "NOTEMPTY_ATSTART"]
        let backtrackingVerbs: Set<String> = ["ACCEPT", "COMMIT", "PRUNE", "SKIP", "THEN"]
        if verb == "F" || verb == "FAIL" { return ("(?!)", false) }
        if startOptions.contains(verb) || verb.hasPrefix("LIMIT_") { return ("", false) }
        let base = verb.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        if let base, backtrackingVerbs.contains(base) || base == "MARK" || base.isEmpty { return ("", false) }
        isSupported = false
        return ("(*" + verb + ")", false)
    }

    /// Copies a group ICU cannot express through to its `)` and marks the pattern unsupported.
    private mutating func unsupportedGroup() -> (String, Bool) {
        isSupported = false
        let start = i
        if let close = index(of: ")", from: i + 1) {
            i = close + 1
        } else {
            i = n
        }
        return (text(start ..< i), false)
    }

    // MARK: - Character classes

    /// What the previous element of a character class was, for PCRE's hyphen rules.
    private enum ClassElement {
        case start          // nothing yet (just after `[` / `[^`)
        case character      // one character: a following `-x` makes a range
        case range          // a completed range `a-z`
        case set            // `\d`, `[:alpha:]`, `\p{…}`
        case hyphenAfterSet // a literal `-` next to a set: cannot start a range
    }

    private mutating func parseClass() -> String {
        var out = "["
        i += 1
        if i < n && s[i] == "^" {
            out += "^"
            i += 1
        }
        var previous = ClassElement.start
        if i < n && s[i] == "]" {
            out += "\\]"
            i += 1
            previous = .character
        }
        while i < n {
            if s[i] == "]" {
                i += 1
                return out + "]"
            }
            if s[i] == "-" {
                i += 1
                // PCRE: `-` is a range operator only between two single characters. At the start or end of the
                // class, after a completed range or next to a set it is a literal, and such a literal can itself start
                // a range (`[--/]` is "-" to "/", `[a-f--/]` is a-f plus "-" to "/") unless it follows a set
                // (`[\d--/]` is \d, "-", "-", "/"). The hyphen is always escaped for ICU, where `--` means set
                // difference.
                if previous == .character, i < n, s[i] != "]" {
                    let rangeEnd = i
                    let (piece, isSet) = parseClassElement()
                    if !isSet && !piece.isEmpty {
                        out += "-" + piece
                        previous = .range
                        continue
                    }
                    // `[a-\d]`: the hyphen is literal (PCRE 8.x) and the set is read next.
                    i = rangeEnd
                    out += "\\-"
                    previous = .character
                    continue
                }
                out += "\\-"
                previous = (previous == .set || previous == .hyphenAfterSet) ? .hyphenAfterSet : .character
                continue
            }
            let (piece, isSet) = parseClassElement()
            out += piece
            if isSet {
                previous = .set
            } else if !piece.isEmpty {
                previous = .character
            }
        }
        isSupported = false // missing "]" — PCRE rejects this; ICU will too
        return out
    }

    /// One element of a character class at `i` (not `]`): its ICU text and whether it is a set.
    private mutating func parseClassElement() -> (String, Bool) {
        let c = s[i]
        switch c {
        case "[":
            if let posix = parsePOSIXClass() { return (posix, true) }
            i += 1
            return ("\\[", false)
        case "\\":
            return parseClassEscape()
        case "-", "{", "}", "&", "$", "#", ":":
            // `:` too: ICU reads `[:` as the start of a `[:Property:]` set whenever a `:]` follows anywhere later,
            // so the ordinary PCRE class `[:=]\s*([^:]*)` would not even compile.
            i += 1
            return ("\\" + String(c), false)
        default:
            i += 1
            if Self.isSpace(c) || c.value < 0x20 || c.value == 0x7F { return (Self.hexEscape(c.value), false) }
            return (String(c), false)
        }
    }

    /// An escape inside `[…]`. Returns the ICU text and whether it denotes a set rather than one character.
    private mutating func parseClassEscape() -> (String, Bool) {
        guard i + 1 < n else {
            i = n
            return ("\\\\", false)
        }
        let e = s[i + 1]
        switch e {
        case "Q":
            i += 2
            let literal = readQuotedLiteral()
            return (literal.unicodeScalars.map(Self.classLiteral).joined(), false)
        case "E":
            i += 2
            return ("", false)
        case "b":
            i += 2
            return (Self.hexEscape(8), false)
        case "0" ... "7":
            i += 1
            return (octal(maxExtraDigits: 2, prefix: ""), false)
        case "8", "9":
            i += 2
            return (String(e), false)
        case "x":
            return (parseHex(), false)
        case "o":
            return (parseBracedOctal(), false)
        case "p", "P":
            return (parseProperty(), true)
        case "d", "D", "w", "W", "s", "S", "h", "H", "v", "V":
            i += 2
            return ("\\" + String(e), true)
        case "a", "e", "f", "n", "r", "t":
            i += 2
            return ("\\" + String(e), false)
        case "c":
            return (parseControlEscape(), false)
        default:
            i += 2
            if Self.isASCIILetter(e) || Self.isDigit(e) { return (String(e), false) }
            return (Self.classLiteral(e), false)
        }
    }

    /// `[:name:]` / `[:^name:]` at `i` (inside a class) → an ICU nested set with PCRE's ASCII meaning.
    private mutating func parsePOSIXClass() -> String? {
        guard peek(1) == ":" else { return nil }
        var j = i + 2
        var negated = false
        if j < n && s[j] == "^" {
            negated = true
            j += 1
        }
        let nameStart = j
        while j < n && Self.isASCIILetter(s[j]) && j - nameStart < 16 { j += 1 }
        guard j + 1 < n, s[j] == ":", s[j + 1] == "]",
              let members = Self.posixClasses[text(nameStart ..< j)] else { return nil }
        i = j + 2
        return (negated ? "[^" : "[") + members + "]"
    }

    private static let posixClasses: [String: String] = [
        "alnum": "a-zA-Z0-9",
        "alpha": "a-zA-Z",
        "ascii": "\\x{0}-\\x{7f}",
        "blank": "\\x{9}\\x{20}",
        "cntrl": "\\x{0}-\\x{1f}\\x{7f}",
        "digit": "0-9",
        "graph": "\\x{21}-\\x{7e}",
        "lower": "a-z",
        "print": "\\x{20}-\\x{7e}",
        "punct": "\\x{21}-\\x{2f}\\x{3a}-\\x{40}\\x{5b}-\\x{60}\\x{7b}-\\x{7e}",
        "space": "\\x{9}-\\x{d}\\x{20}",
        "upper": "A-Z",
        "word": "a-zA-Z0-9_",
        "xdigit": "0-9A-Fa-f",
    ]

    /// A character to be matched literally inside an ICU set.
    private static func classLiteral(_ c: Unicode.Scalar) -> String {
        if isASCIILetter(c) || isDigit(c) || c.value > 0x7F { return String(c) }
        return hexEscape(c.value)
    }

    // MARK: - Helpers

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        let j = i + offset
        return j < n ? s[j] : nil
    }

    private func index(of c: Unicode.Scalar, from start: Int) -> Int? {
        var j = start
        while j < n {
            if s[j] == c { return j }
            j += 1
        }
        return nil
    }

    /// Copies from `i` through the next `closer` (or to the end) unchanged.
    private mutating func copyThrough(_ closer: Unicode.Scalar?) -> String {
        let start = i
        if let closer, let close = index(of: closer, from: i + 1) {
            i = close + 1
        } else {
            i = n
            isSupported = false
        }
        return text(start ..< i)
    }

    private mutating func skipLineComment() {
        while i < n && s[i] != "\n" { i += 1 }
    }

    private mutating func skipSpaceAndComments() {
        while i < n {
            if Self.isSpace(s[i]) {
                i += 1
            } else if s[i] == "#" {
                skipLineComment()
            } else {
                break
            }
        }
    }

    private func text(_ range: Range<Int>) -> String {
        guard range.lowerBound < range.upperBound else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[range])
        return String(view)
    }

    private static func hexEscape(_ value: UInt32) -> String {
        "\\x{" + String(value, radix: 16) + "}"
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{0C}"
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
    private static func isOctal(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "7" }
    private static func isHex(_ c: Unicode.Scalar) -> Bool {
        isDigit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
    }

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    /// PCRE group names: a letter or underscore, then letters, digits, underscores.
    private static func isValidPCREName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isASCIILetter(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { isASCIILetter($0) || isDigit($0) || $0 == "_" }
    }

    /// ICU group names allow only ASCII letters and digits (starting with a letter). Other characters are encoded
    /// deterministically (`_` → `x5f`) so that definitions and references still agree.
    static func icuGroupName(_ name: String) -> String {
        var out = ""
        for c in name.unicodeScalars {
            if isASCIILetter(c) || isDigit(c) {
                out.unicodeScalars.append(c)
            } else {
                out += "x" + String(c.value, radix: 16)
            }
        }
        if let first = out.unicodeScalars.first, isASCIILetter(first) { return out }
        return "n" + out
    }
}
