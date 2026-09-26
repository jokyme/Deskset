import Foundation

// Internal machinery behind `VariableResolver`. Clean-room, from the public manual only:
//   https://docs.rainmeter.net/manual/variables/                       (#Var#, escapes, DynamicVariables)
//   https://docs.rainmeter.net/manual/variables/nesting-variables/     ([#Var] [&Measure] [$Mouse], inside-out)
//   https://docs.rainmeter.net/manual/variables/section-variables/     ([Name] [Name:params], priority rule)
//   https://docs.rainmeter.net/manual/variables/character-variables/   ([\x263A] [\9731])
//   https://docs.rainmeter.net/manual/variables/mouse-variables/       ($MouseX$ $MouseX:%$)
//   https://docs.rainmeter.net/tips/setoption-guide/                   (escapes protect references in bangs)
//
// Resolution happens in three stages over UTF-8 bytes (every delimiter is ASCII, so a split never cuts a
// multi-byte character):
//
//   1. Standard syntax, left to right: `#Var#`, the `#*Var*#` escape and — when an event lookup is set —
//      `$Event$`. The manual: "Normal or built-in variables take priority over section variables", so
//      `[#Foo#:#Bar#]` works (the variables build the section variable) while `#[Foo][Bar]#` does not.
//   2. Nesting syntax `[#Var]`, `[&Measure(:param)]`, `[\char]`, `[$Event]` and the escapes `[#*Var*]`,
//      `[&*Measure*]`, resolved inside-out (`[#Color[#Index]]`, `[&MeasureString[&MeasureNum3]]`).
//   3. Classic section variables `[Name]`, `[Name:param]` and the `[*Name*]` escape — only when a section
//      lookup is present (DynamicVariables=1 options and bangs).
//
// Every byte carries a "frozen" flag. Output that must be taken literally — escapes, character variables,
// measure/meter values, event values and built-in variable values — is frozen: later stages never treat its
// bytes as syntax, but frozen bytes may still be part of a name (`[&Measure#CURRENTSECTION#]`). Values of
// ordinary variables are *not* frozen: a variable is plain text substitution, so `Var=[MeasureCPU]` used as
// `#Var#` in a dynamic option shows the measure, and `#*X*#` stored in a variable becomes `#X#` when used.
//
// Judgment calls where the manual is silent (all documented on `VariableResolver`):
//   - A variable's value is re-scanned for further variables (recursively). A name that is already being
//     expanded is left as written, which makes `A=#A#` and `A=#B#`/`B=#A#` terminate.
//   - Hard limits keep hostile skins harmless: 32 variables deep, 32 bracket levels, 20 000 substitutions,
//     1 MiB of substituted text, 50 000 lookups and 4 MiB (+ 4× the input) of scanned text per call; beyond them
//     references are left as written.

/// ASCII bytes of the variable syntax.
enum VarByte {
    static let hash = UInt8(ascii: "#")
    static let dollar = UInt8(ascii: "$")
    static let ampersand = UInt8(ascii: "&")
    static let star = UInt8(ascii: "*")
    static let colon = UInt8(ascii: ":")
    static let open = UInt8(ascii: "[")
    static let close = UInt8(ascii: "]")
    static let backslash = UInt8(ascii: "\\")
    static let bang = UInt8(ascii: "!")
}

/// UTF-8 bytes plus a per-byte "frozen" flag (see the file comment).
struct VarMarkedText {
    private(set) var bytes: [UInt8] = []
    private(set) var frozen: [Bool] = []

    init() {}

    var count: Int { bytes.count }

    @inline(__always)
    func isLive(_ i: Int, _ byte: UInt8) -> Bool { bytes[i] == byte && !frozen[i] }

    mutating func appendLive(_ byte: UInt8) {
        bytes.append(byte)
        frozen.append(false)
    }

    mutating func appendLive<C: Collection>(_ source: C) where C.Element == UInt8 {
        let before = bytes.count
        bytes.append(contentsOf: source)
        frozen.append(contentsOf: repeatElement(false, count: bytes.count - before))
    }

    mutating func appendFrozen<C: Collection>(_ source: C) where C.Element == UInt8 {
        let before = bytes.count
        bytes.append(contentsOf: source)
        frozen.append(contentsOf: repeatElement(true, count: bytes.count - before))
    }

    mutating func append(_ other: VarMarkedText) {
        bytes.append(contentsOf: other.bytes)
        frozen.append(contentsOf: other.frozen)
    }

    mutating func append(_ other: VarMarkedText, _ range: Range<Int>) {
        guard !range.isEmpty else { return }
        bytes.append(contentsOf: other.bytes[range])
        frozen.append(contentsOf: other.frozen[range])
    }

    var string: String { String(decoding: bytes, as: UTF8.self) }

    static func literal<C: Collection>(_ source: C) -> VarMarkedText where C.Element == UInt8 {
        var m = VarMarkedText()
        m.appendFrozen(source)
        return m
    }
}

/// A byte budget shared by several `VarExpansion` runs (all definitions of one `resolveDefinitions` call), so the
/// total amount of substituted text stays bounded, not just the amount per run.
final class VarBudget {
    var remainingBytes: Int
    init(bytes: Int) { remainingBytes = bytes }
}

/// One resolution run (one call of `VariableResolver.resolve` & co.). Not thread-safe; create one per call.
final class VarExpansion {
    static let maxVariableDepth = 32
    static let maxBracketDepth = 32
    static let maxSubstitutions = 20_000
    static let maxSubstitutedBytes = 1 << 20
    /// Lookups per run (variable, section and event; found or not). Failed lookups are not substitutions, and
    /// without this cap an unresolved reference inside a variable value is looked up again at every nesting level
    /// of every copy of that value (review: 0.8 s for one resolve() in a release build).
    static let maxLookups = 50_000
    /// Bytes scanned by all stages per run, on top of 4× the input. Each nesting level re-scans the expanded value
    /// of the level below, so without a cap the work is (substituted text) × (depth).
    static let maxScannedBytes = 4 << 20

    private let variableLookup: (String) -> String?
    private let sectionLookup: ((String, SectionVariableParameter) -> String?)?
    private let eventLookup: ((String) -> String?)?
    /// false: only `#Var#` is resolved and every escape is kept verbatim (definitions / standard-only mode).
    private let fullSyntax: Bool
    /// Re-scan variable values for more `#Var#` (false when the lookup already returns final values).
    private let rescanValues: Bool
    /// With `fullSyntax == false`: also resolve the nested variable form `[#Var]` (including `[#Color[#Index]]`),
    /// keeping every other nesting form (`[&M]`, `[\x…]`, `[$…]`) and every escape as written. Used for `[Variables]`
    /// definitions, where `[#Var]` must behave exactly like `#Var#` (see `VarDefinitionTable`).
    private let nestedVariables: Bool
    /// Optional budget shared with other runs (see `VarBudget`).
    private let budget: VarBudget?

    /// Lower-cased names of the variables currently being expanded (cycle guard).
    private var stack: [String] = []
    private var bracketDepth = 0
    private var substitutions = 0
    private var substitutedBytes = 0
    private var lookups = 0
    private var scanned = 0
    private var scanLimit = VarExpansion.maxScannedBytes
    /// Set as soon as any output differs from the input.
    private var changed = false

    init(variableLookup: @escaping (String) -> String?,
         sectionLookup: ((String, SectionVariableParameter) -> String?)?,
         eventLookup: ((String) -> String?)?,
         fullSyntax: Bool,
         rescanValues: Bool,
         nestedVariables: Bool = false,
         budget: VarBudget? = nil) {
        self.variableLookup = variableLookup
        self.sectionLookup = fullSyntax ? sectionLookup : nil
        self.eventLookup = fullSyntax ? eventLookup : nil
        self.fullSyntax = fullSyntax
        self.rescanValues = rescanValues
        self.nestedVariables = nestedVariables
        self.budget = budget
    }

    /// Resolves `text`; returns `text` itself (no copy) when nothing was substituted.
    func run(_ text: String) -> String {
        let bytes = Array(text.utf8)
        scanLimit = Self.maxScannedBytes + 4 * bytes.count
        var marked = VarMarkedText()
        expandStandard(bytes, into: &marked)
        if fullSyntax {
            marked = expandNested(marked)
            marked = expandSections(marked)
        } else if nestedVariables {
            marked = expandNested(marked)
        }
        return changed ? marked.string : text
    }

    // MARK: Stage 1 — #Var#, #*Var*#, $Event$

    private func expandStandard(_ b: [UInt8], into out: inout VarMarkedText) {
        let n = b.count
        guard scan(n) else {
            // Over the scan budget: the text stays as written.
            out.appendLive(b)
            return
        }
        let events = eventLookup != nil
        var i = 0
        var run = 0
        while i < n {
            let c = b[i]
            guard c == VarByte.hash || (events && c == VarByte.dollar) else { i += 1; continue }
            var j = i + 1
            while j < n && b[j] != c { j += 1 }
            guard j < n else { i += 1; continue }   // no closing delimiter: literal

            out.appendLive(b[run..<i])
            run = i
            let content = b[(i + 1)..<j]
            let handled = c == VarByte.hash
                ? expandHash(content, original: b[i...j], into: &out)
                : expandEvent(content, into: &out)
            if handled {
                i = j + 1
                run = i
            } else {
                // Literal delimiter; the closing one may open the next reference ("#1 and #Var#").
                i += 1
            }
        }
        out.appendLive(b[run..<n])
    }

    private func expandHash(_ content: ArraySlice<UInt8>, original: ArraySlice<UInt8>,
                            into out: inout VarMarkedText) -> Bool {
        if Self.isEscape(content) {
            if fullSyntax {
                // "#*VarName*#" is "replaced with the literal string without the *".
                out.appendFrozen(CollectionOfOne(VarByte.hash))
                out.appendFrozen(content.dropFirst().dropLast())
                out.appendFrozen(CollectionOfOne(VarByte.hash))
                changed = true
            } else {
                out.appendFrozen(original)   // kept for the final resolution
            }
            return true
        }
        guard !content.isEmpty, canLookUp else { return false }
        switch lookupVariable(String(decoding: content, as: UTF8.self)) {
        case .undefined:
            return false
        case .blocked:
            // Already being expanded (cycle) or over a limit: left as written, and frozen so an outer stage
            // does not expand it again.
            out.appendFrozen(original)
            return true
        case .found(let key, let value, let builtIn):
            if builtIn {
                out.appendFrozen(value.utf8)
            } else if !rescanValues {
                out.appendLive(value.utf8)
            } else {
                stack.append(key)
                if fullSyntax || nestedVariables {
                    // The value's own nesting forms are resolved while its name is still on the stack, so a
                    // self-reference such as A=#A#[#A] stays as written instead of expanding once more.
                    var expanded = VarMarkedText()
                    expandStandard(Array(value.utf8), into: &expanded)
                    out.append(expandNested(expanded))
                } else {
                    expandStandard(Array(value.utf8), into: &out)
                }
                stack.removeLast()
            }
            return true
        }
    }

    private func expandEvent(_ content: ArraySlice<UInt8>, into out: inout VarMarkedText) -> Bool {
        guard !content.isEmpty, canLookUp, let value = lookupEvent(String(decoding: content, as: UTF8.self)) else {
            return false
        }
        out.appendFrozen(value.utf8)
        return true
    }

    // MARK: Stage 2 — nesting syntax, inside-out

    private func expandNested(_ m: VarMarkedText) -> VarMarkedText {
        // Re-entered for variable values found inside constructs; the shared depth keeps recursion bounded.
        guard bracketDepth < Self.maxBracketDepth, scan(m.count) else { return m }
        let n = m.count
        var first = -1
        for i in 0..<n where isNestedOpener(m, i) { first = i; break }
        guard first >= 0 else { return m }

        var out = VarMarkedText()
        var i = first
        var run = 0
        while i < n {
            guard isNestedOpener(m, i) else { i += 1; continue }
            out.append(m, run..<i)
            let (piece, end) = parseConstruct(m, at: i)
            out.append(piece)
            i = end
            run = end
        }
        out.append(m, run..<n)
        return out
    }

    @inline(__always)
    private func isNestedOpener(_ m: VarMarkedText, _ i: Int) -> Bool {
        guard i + 1 < m.count, m.isLive(i, VarByte.open), !m.frozen[i + 1] else { return false }
        switch m.bytes[i + 1] {
        case VarByte.hash, VarByte.ampersand, VarByte.backslash, VarByte.dollar: return true
        default: return false
        }
    }

    /// Parses the construct opening at `start` (`[` + prefix). Returns its output and the index after it.
    /// Inner constructs are resolved first; the content ends at the first live `]` not used by an inner one.
    /// An unresolvable construct is returned as written (with its inner parts resolved); an unterminated one
    /// consumes the rest of the text the same way.
    private func parseConstruct(_ m: VarMarkedText, at start: Int) -> (VarMarkedText, Int) {
        let n = m.count
        let prefix = m.bytes[start + 1]
        bracketDepth += 1
        defer { bracketDepth -= 1 }

        var content = VarMarkedText()
        var j = start + 2
        var run = j
        while j < n {
            if m.isLive(j, VarByte.close) { break }
            if bracketDepth < Self.maxBracketDepth && isNestedOpener(m, j) {
                content.append(m, run..<j)
                let (inner, end) = parseConstruct(m, at: j)
                content.append(inner)
                j = end
                run = end
                continue
            }
            j += 1
        }
        content.append(m, run..<j)

        if j < n, let resolved = resolveConstruct(prefix: prefix, content: content) {
            return (resolved, j + 1)
        }
        var literal = VarMarkedText()
        literal.append(m, start..<(start + 2))
        literal.append(content)
        guard j < n else { return (literal, n) }
        literal.append(m, j..<(j + 1))
        return (literal, j + 1)
    }

    private func resolveConstruct(prefix: UInt8, content: VarMarkedText) -> VarMarkedText? {
        let body = content.bytes
        switch prefix {
        case VarByte.hash:
            if Self.isEscape(body[...]) {
                // Definitions keep escapes for the place of use (they must be consumed exactly once).
                return fullSyntax ? escaped(prefix: prefix, body) : nil
            }
            guard !body.isEmpty, canLookUp else { return nil }
            switch lookupVariable(String(decoding: body, as: UTF8.self)) {
            case .undefined:
                return nil
            case .blocked:
                var m = VarMarkedText()
                m.appendFrozen([VarByte.open, VarByte.hash])
                m.appendFrozen(body)
                m.appendFrozen(CollectionOfOne(VarByte.close))
                return m
            case .found(let key, let value, let builtIn):
                if builtIn { return .literal(value.utf8) }
                if !rescanValues {
                    // The lookup already returns final values (definitions).
                    var m = VarMarkedText()
                    m.appendLive(value.utf8)
                    return m
                }
                // "[#VarName]" functions exactly as "#VarName#": its value is text that is resolved further.
                stack.append(key)
                defer { stack.removeLast() }
                var expanded = VarMarkedText()
                expandStandard(Array(value.utf8), into: &expanded)
                return expandNested(expanded)
            }

        case VarByte.ampersand:
            // Nested section variables are section variables: only resolved when section lookup is enabled.
            guard sectionLookup != nil else { return nil }
            if Self.isEscape(body[...]) { return escaped(prefix: prefix, body) }
            return sectionValue(body[...])

        case VarByte.backslash:
            // Definitions keep character variables as written, so a produced "[" or "#" stays literal where the
            // variable is used (the manual's own example stores fa-Raindrop=[\xf043] in [Variables]).
            guard fullSyntax, let scalar = Self.characterScalar(body) else { return nil }
            changed = true
            return .literal(String(Character(scalar)).utf8)

        case VarByte.dollar:
            guard !body.isEmpty, canLookUp, let value = lookupEvent(String(decoding: body, as: UTF8.self)) else {
                return nil
            }
            return .literal(value.utf8)

        default:
            return nil
        }
    }

    /// `[#*Var*]` → `[#Var]`, `[&*Measure*]` → `[&Measure]` (frozen).
    private func escaped(prefix: UInt8, _ body: [UInt8]) -> VarMarkedText {
        changed = true
        var m = VarMarkedText()
        m.appendFrozen([VarByte.open, prefix])
        m.appendFrozen(body.dropFirst().dropLast())
        m.appendFrozen(CollectionOfOne(VarByte.close))
        return m
    }

    // MARK: Stage 3 — classic section variables

    private func expandSections(_ m: VarMarkedText) -> VarMarkedText {
        guard sectionLookup != nil, scan(m.count) else { return m }
        let n = m.count
        var out = VarMarkedText()
        var i = 0
        var run = 0
        var any = false
        while i < n {
            guard m.isLive(i, VarByte.open) else { i += 1; continue }
            // Candidate: up to the next live `]`; a live `[` before it starts a new (inner) candidate, so in
            // "[!SetOption Meter Text [Measure]]" only "[Measure]" is a candidate.
            var j = i + 1
            while j < n && !m.isLive(j, VarByte.close) && !m.isLive(j, VarByte.open) { j += 1 }
            guard j < n else { break }
            if m.bytes[j] == VarByte.open { i = j; continue }
            if let value = classicValue(m.bytes[(i + 1)..<j]) {
                out.append(m, run..<i)
                out.append(value)
                run = j + 1
                any = true
            }
            i = j + 1
        }
        guard any else { return m }
        out.append(m, run..<n)
        return out
    }

    private func classicValue(_ body: ArraySlice<UInt8>) -> VarMarkedText? {
        guard let first = body.first else { return nil }
        if Self.isEscape(body) {
            // "[*MeasureName*]" → "[MeasureName]"
            changed = true
            var m = VarMarkedText()
            m.appendFrozen(CollectionOfOne(VarByte.open))
            m.appendFrozen(body.dropFirst().dropLast())
            m.appendFrozen(CollectionOfOne(VarByte.close))
            return m
        }
        switch first {
        case VarByte.hash, VarByte.ampersand, VarByte.backslash, VarByte.dollar, VarByte.bang:
            // Leftover nesting syntax that did not resolve, or a bang such as "[!Refresh]": never a section.
            return nil
        default:
            return sectionValue(body)
        }
    }

    /// `Name` or `Name:param` → the section lookup's value (frozen), or nil to leave the text as written.
    private func sectionValue(_ body: ArraySlice<UInt8>) -> VarMarkedText? {
        guard let lookup = sectionLookup, !body.isEmpty, substitutions < Self.maxSubstitutions, canLookUp else {
            return nil
        }
        let name: String
        let param: String?
        if let colon = body.firstIndex(of: VarByte.colon) {
            name = String(decoding: body[body.startIndex..<colon], as: UTF8.self)
            param = String(decoding: body[(colon + 1)...], as: UTF8.self)
        } else {
            name = String(decoding: body, as: UTF8.self)
            param = nil
        }
        guard !name.isEmpty else { return nil }
        lookups += 1
        guard let value = lookup(name, SectionVariableParameter.parse(param)) else { return nil }
        guard record(value) else { return nil }
        return .literal(value.utf8)
    }

    // MARK: Lookups and limits

    private enum VariableLookup {
        /// `key` is the lower-cased name.
        case found(key: String, value: String, builtIn: Bool)
        /// The lookup does not know the name: left as written (still live text).
        case undefined
        /// Known, but already being expanded or over a limit: left as written and frozen.
        case blocked
    }

    private func lookupVariable(_ name: String) -> VariableLookup {
        lookups += 1
        let key = name.lowercased()
        let blocked = stack.count >= Self.maxVariableDepth || stack.contains(key)
            || substitutions >= Self.maxSubstitutions
        guard let value = variableLookup(name) else { return .undefined }
        guard !blocked, record(value) else { return .blocked }
        return .found(key: key, value: value, builtIn: BuiltInVariables.isBuiltInKey(key))
    }

    private func lookupEvent(_ name: String) -> String? {
        guard let lookup = eventLookup, substitutions < Self.maxSubstitutions else { return nil }
        lookups += 1
        guard let value = lookup(name), record(value) else { return nil }
        return value
    }

    /// True while the run may still ask a lookup (see `maxLookups`, `maxScannedBytes`); past that, references
    /// stay as written.
    private var canLookUp: Bool { lookups < Self.maxLookups && scanned <= scanLimit }

    /// Counts `count` scanned bytes; false once the run is over its scan budget.
    private func scan(_ count: Int) -> Bool {
        scanned += count
        return scanned <= scanLimit
    }

    /// Counts one substitution against the limits; false when it would exceed them.
    private func record(_ value: String) -> Bool {
        let size = value.utf8.count
        guard substitutedBytes + size <= Self.maxSubstitutedBytes else { return false }
        if let budget {
            guard size <= budget.remainingBytes else { return false }
            budget.remainingBytes -= size
        }
        substitutions += 1
        substitutedBytes += size
        changed = true
        return true
    }

    // MARK: Helpers

    /// `*Name*` with a non-empty name.
    @inline(__always)
    static func isEscape(_ content: ArraySlice<UInt8>) -> Bool {
        content.count >= 3 && content.first == VarByte.star && content.last == VarByte.star
    }

    /// Character reference body: `x263A` / `X263a` (hex) or `9731` (decimal).
    ///
    /// The manual allows x0–xFFFE / 0–65536 because Windows Rainmeter is limited to the Basic Multilingual
    /// Plane. macOS renders every plane, so any Unicode scalar value up to U+10FFFF is accepted (a strict
    /// superset). Surrogates, larger values, empty or non-digit bodies are not character variables and stay as
    /// written.
    static func characterScalar(_ body: [UInt8]) -> Unicode.Scalar? {
        guard let first = body.first else { return nil }
        var value: UInt64 = 0
        if first == UInt8(ascii: "x") || first == UInt8(ascii: "X") {
            let digits = body.dropFirst()
            guard !digits.isEmpty, digits.count <= 8 else { return nil }
            for d in digits {
                let v: UInt8
                switch d {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): v = d - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): v = d - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): v = d - UInt8(ascii: "A") + 10
                default: return nil
                }
                value = value * 16 + UInt64(v)
            }
        } else {
            guard body.count <= 10 else { return nil }
            for d in body {
                guard d >= UInt8(ascii: "0") && d <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + UInt64(d - UInt8(ascii: "0"))
            }
        }
        guard value <= 0x10FFFF else { return nil }
        return Unicode.Scalar(UInt32(value))
    }
}

/// Resolves the `[Variables]` definitions of a skin (see `VariableResolver.resolveDefinitions`).
///
/// Values are resolved on demand with memoization, so a reference to an earlier entry is a table hit and a
/// forward reference recurses. Recursion is capped at `maxChain` links; a longer forward chain is handled by a
/// worklist: the key where the cap was hit is resolved first (from depth zero), then the attempt is retried and
/// finds it memoized. Only results of attempts that did not hit the cap are memoized, and an attempt stops
/// exploring as soon as it hits the cap — otherwise a value with two references (`W1=#W2##W2#`, …, 65 lines deep)
/// re-explores both unmemoized branches at every level, which is exponential (the pre-review code hung there).
/// Cycles are cut at the key that is already in progress, which is left as written.
///
/// Both reference forms are resolved here: `#Var#` and the nested `[#Var]` / `[#Color[#Index]]`. The nesting page
/// says the nested forms "function exactly as their normal counterparts do" and that the one difference ("always
/// dynamically resolved when they are used") "only applies to use in bangs"; `[Variables]` cannot be dynamic, so
/// `B=[#A]` takes A's value at load time exactly like `B=#A#`. Escapes, `[&Measure]`, section variables,
/// character variables and event variables are kept as written for the place of use.
///
/// All definitions share one byte budget (`maxTotalSubstitutedBytes`): without it a few hundred lines such as
/// `E2=#E1##E1#` … would build hundreds of megabytes (each value is only capped at 1 MiB per run). Past the budget
/// references are left as written, like any other limit.
final class VarDefinitionTable {
    static let maxChain = 64
    static let maxTotalSubstitutedBytes = 4 << 20

    private var order: [String] = []
    private var raw: [String: String] = [:]
    private let builtins: [String: String]
    private let budget = VarBudget(bytes: VarDefinitionTable.maxTotalSubstitutedBytes)
    private var resolved: [String: String] = [:]
    private var inProgress: Set<String> = []
    /// Set when the current attempt hit `maxChain`: its results are incomplete, so nothing more is explored or
    /// memoized until `resolveFully` starts the next attempt. `firstBlockedKey` is the key where the cap was hit.
    private var attemptAborted = false
    private var firstBlockedKey: String?

    init(entries: [IniEntry], builtins: [String: String]) {
        var b: [String: String] = [:]
        for (k, v) in builtins { b[k.lowercased()] = v }
        self.builtins = b
        for e in entries {
            let key = e.key.trimmingCharacters(in: .whitespaces).lowercased()
            // @Include lines are directives, not variables (they may still be present in the entry list).
            guard !key.isEmpty, !key.hasPrefix("@include") else { continue }
            if raw[key] == nil { order.append(key) }
            raw[key] = e.value   // "Later" wins, as with sections merged by @Include
        }
    }

    func table() -> [String: String] {
        var table: [String: String] = [:]
        table.reserveCapacity(order.count + builtins.count)
        for key in order where builtins[key] == nil {
            resolveFully(key)
            table[key] = resolved[key] ?? raw[key]
        }
        for (k, v) in builtins { table[k] = v }
        return table
    }

    private func resolveFully(_ start: String) {
        guard resolved[start] == nil else { return }
        var work = [start]
        var queued: Set<String> = [start]
        while let key = work.last {
            if resolved[key] != nil { work.removeLast(); continue }
            attemptAborted = false
            firstBlockedKey = nil
            let value = self.value(of: key)
            let aborted = attemptAborted
            attemptAborted = false
            if aborted, let blocked = firstBlockedKey, resolved[blocked] == nil, !queued.contains(blocked) {
                work.append(blocked)
                queued.insert(blocked)
                continue
            }
            // Complete — or no further progress is possible (a cycle longer than maxChain): keep what we have.
            if resolved[key] == nil { resolved[key] = value ?? raw[key] }
            work.removeLast()
        }
    }

    private func value(of name: String) -> String? {
        let key = name.lowercased()
        if let v = builtins[key] { return v }
        if let v = resolved[key] { return v }
        guard let text = raw[key], !inProgress.contains(key), !attemptAborted else { return nil }
        guard inProgress.count < Self.maxChain else {
            attemptAborted = true
            firstBlockedKey = key
            return nil
        }
        inProgress.insert(key)
        let expansion = VarExpansion(variableLookup: { self.value(of: $0) }, sectionLookup: nil, eventLookup: nil,
                                     fullSyntax: false, rescanValues: false, nestedVariables: true,
                                     budget: budget)
        let v = expansion.run(text)
        inProgress.remove(key)
        if !attemptAborted { resolved[key] = v }
        return v
    }
}
