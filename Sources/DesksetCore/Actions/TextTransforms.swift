import Foundation

// Measure `Substitute=` / `RegExpSubstitute=` and PCRE helpers.
//
// Clean-room implementation based only on the public manual:
//   https://docs.rainmeter.net/manual/measures/general-options/substitute/
//   https://docs.rainmeter.net/manual/skins/option-types/#RegExp
//   https://docs.rainmeter.net/manual/measures/general-options/ifmatchactions/
//   https://docs.rainmeter.net/manual/variables/section-variables/#EscapeRegExp
//   https://docs.rainmeter.net/tips/webparser-lookahead-assertions-in-regexp/ (`Substitute="":"No Moe!"`)
//   https://docs.rainmeter.net/history/ (Substitute quoting / empty-capture notes)
//
// Substitute rules (manual):
// - A comma-delimited list of `"pattern":"replacement"` pairs; every occurrence of pattern is replaced.
// - Pairs are applied in the order written, each on the result of the previous one (`"1":"One","10":"Ten"`
//   never produces "Ten").
// - Single quotes may be used around the pattern or the replacement (`'"':"double quote"`) so either can contain `"`.
// - RegExpSubstitute=1: patterns are PCRE; `\1`, `\2`, … in the replacement insert captures and `\0` the whole match.
// - An empty pattern `""` replaces an empty value (`Substitute="":"No Moe!"` shows "No Moe!" for an empty string);
//   with RegExpSubstitute `"^$"` does the same.
//
// Judgment calls where the manual is silent:
// - The INI reader strips one pair of matching quotes (double or single) around a whole value, so
//   `Substitute="a":"b"` usually arrives as `a":"b`. The option is parsed as written first and, if that is not a
//   valid pair list, again with outer double quotes restored, then with outer single quotes restored. Anything still
//   malformed is parsed leniently (unquoted `a:b`, missing quotes).
// - `'pattern':'replacement'` (both single-quoted) is documented as not working in Rainmeter; it is accepted here.
// - A trailing comma and whitespace around `:` and `,` are allowed. A pattern without `:replacement` is ignored.
// - Plain substitution is case-sensitive and literal.
// - An empty pattern (plain or regex) only matches a completely empty value; it never inserts text between
//   characters.
// - Regex replacement: `\` followed by digits is a group reference (as many digits as form an existing group
//   number, like ICU/Perl); a reference to a group that did not participate or does not exist inserts nothing
//   (the history notes that empty captures no longer break following replacements). Any other character,
//   including `$` and a `\` not followed by a digit, is literal.
// - An invalid regular expression leaves the value unchanged for that pair (the other pairs still apply).

/// A parsed measure `Substitute=` option.
public struct SubstituteRules: Equatable {
    public struct Pair: Equatable {
        public var pattern: String
        public var replacement: String
        public init(pattern: String, replacement: String) {
            self.pattern = pattern
            self.replacement = replacement
        }
    }

    public var pairs: [Pair]
    /// `RegExpSubstitute=1`: patterns are (PCRE-style) regular expressions and replacements may use `\1`…`\N`.
    public var isRegex: Bool

    /// Parses `"a":"b","c":"d"` (and the other forms the manual allows).
    public init(_ option: String, regex: Bool) {
        self.pairs = SubstituteRules.parsePairs(option)
        self.isRegex = regex
    }

    public init(pairs: [Pair], isRegex: Bool) {
        self.pairs = pairs
        self.isRegex = isRegex
    }

    public var isEmpty: Bool { pairs.isEmpty }

    /// Applies the rules to a string value exactly as the manual describes (order, one pass per pair, …).
    public func apply(to text: String) -> String {
        var result = text
        for pair in pairs {
            if pair.pattern.isEmpty {
                if result.isEmpty {
                    result = isRegex ? PCRE.expandTemplate(pair.replacement, groups: []) : pair.replacement
                }
                continue
            }
            if isRegex {
                guard let regex = PCRE.regex(pair.pattern) else { continue }
                result = PCRE.replaceAll(regex, in: result, template: pair.replacement)
            } else {
                result = result.replacingOccurrences(of: pair.pattern, with: pair.replacement, options: .literal)
            }
        }
        return result
    }

    // MARK: - Parsing

    static func parsePairs(_ option: String) -> [Pair] {
        guard !option.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        // Not trimmed: when the INI reader removed the outer quotes, edge whitespace belongs to the first pattern
        // or the last replacement (`"\s+":" "` arrives as `\s+":" `).
        let scalars = Array(option.unicodeScalars)
        if let pairs = strictPairs(scalars) { return pairs }
        if let pairs = strictPairs(["\""] + scalars + ["\""]) { return pairs }
        // The INI reader also strips a pair of *single* quotes around the whole value (like Windows'
        // GetPrivateProfileString), so `'"':"x","y":'"'` — single quotes on the outer ends of two different pairs,
        // which the manual allows — arrives as `"':"x","y":'"`.
        if let pairs = strictPairs(["'"] + scalars + ["'"]) { return pairs }
        return lenientPairs(scalars)
    }

    /// `q:q[,q:q]*[,]` where q is `"…"` or `'…'`, whitespace allowed between tokens.
    private static func strictPairs(_ s: [Unicode.Scalar]) -> [Pair]? {
        var i = 0
        var pairs: [Pair] = []
        func skipSpace() { while i < s.count && isSpace(s[i]) { i += 1 } }
        func quoted() -> String? {
            guard i < s.count, s[i] == "\"" || s[i] == "'" else { return nil }
            let quote = s[i]
            var j = i + 1
            while j < s.count && s[j] != quote { j += 1 }
            guard j < s.count else { return nil }
            let value = string(s[(i + 1) ..< j])
            i = j + 1
            return value
        }
        while true {
            skipSpace()
            guard let pattern = quoted() else { return nil }
            skipSpace()
            guard i < s.count, s[i] == ":" else { return nil }
            i += 1
            skipSpace()
            guard let replacement = quoted() else { return nil }
            pairs.append(Pair(pattern: pattern, replacement: replacement))
            skipSpace()
            if i == s.count { return pairs }
            guard s[i] == "," else { return nil }
            i += 1
            skipSpace()
            if i == s.count { return pairs }
        }
    }

    /// Best effort for malformed options: tokens may be unquoted (`a:b,c:d`) or have unbalanced quotes.
    private static func lenientPairs(_ s: [Unicode.Scalar]) -> [Pair] {
        var i = 0
        var pairs: [Pair] = []
        /// Reads a token ending at `stop` (or `,` / end); a leading quote protects everything up to its partner.
        func token(stop: Unicode.Scalar) -> String {
            while i < s.count && isSpace(s[i]) { i += 1 }
            if i < s.count, s[i] == "\"" || s[i] == "'" {
                let quote = s[i]
                var j = i + 1
                while j < s.count && s[j] != quote { j += 1 }
                if j < s.count {
                    let value = string(s[(i + 1) ..< j])
                    i = j + 1
                    while i < s.count && s[i] != stop && s[i] != "," { i += 1 }
                    return value
                }
            }
            let start = i
            while i < s.count && s[i] != stop && s[i] != "," { i += 1 }
            var value = string(s[start ..< i]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") || value.hasPrefix("'") { value.removeFirst() }
            if value.hasSuffix("\"") || value.hasSuffix("'") { value.removeLast() }
            return value
        }
        while i < s.count {
            let pattern = token(stop: ":")
            if i < s.count && s[i] == ":" {
                i += 1
                let replacement = token(stop: ",")
                pairs.append(Pair(pattern: pattern, replacement: replacement))
            }
            if i < s.count && s[i] == "," { i += 1 }
        }
        return pairs
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }

    private static func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }
}

/// Skins are written against PCRE; Foundation only offers ICU regular expressions (NSRegularExpression).
public enum PCRE {
    /// Converts a PCRE pattern as used in skins (inline flags like `(?siU)`, where ICU lacks `U`/ungreedy, etc.)
    /// into an equivalent ICU pattern.
    public static func toICU(_ pattern: String) -> String {
        PCREConverter.convert(pattern).pattern
    }

    /// Compiles (with caching) a PCRE-style pattern. `caseInsensitive` adds the i flag. Nil when invalid.
    public static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        PCRERegexCache.shared.regex(pattern, caseInsensitive: caseInsensitive)
    }

    /// `[Measure:EscapeRegExp]`: escapes the PCRE reserved characters `. ^ $ * + ? ( ) [ { \ |` with `\`
    /// (manual: section variables), so the text matches literally.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for c in text.unicodeScalars {
            switch c {
            case ".", "^", "$", "*", "+", "?", "(", ")", "[", "{", "\\", "|":
                out.unicodeScalars.append("\\")
            default:
                break
            }
            out.unicodeScalars.append(c)
        }
        return out
    }

    /// IfMatch semantics: true when the pattern matches anywhere in `text`. Nil when the pattern is invalid.
    public static func matches(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> Bool? {
        guard let regex = regex(pattern, caseInsensitive: caseInsensitive),
              let found = findMatches(regex, in: text, maxCount: 1) else { return nil }
        return !found.isEmpty
    }

    /// The first match: element 0 is the whole match, then one element per capture group (a group that did not
    /// participate yields ""). Nil when the pattern is invalid or does not match. (WebParser `StringIndex`.)
    public static func captures(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [String]? {
        guard let regex = regex(pattern, caseInsensitive: caseInsensitive),
              let match = findMatches(regex, in: text, maxCount: 1)?.first else { return nil }
        let ns = text as NSString
        return (0 ..< match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    /// Every match of `pattern` in `text` (e.g. for `InlinePattern`). Nil when the pattern is invalid or matching
    /// took too long (pathological backtracking).
    public static func allMatches(_ pattern: String, in text: String,
                                  caseInsensitive: Bool = false) -> [NSTextCheckingResult]? {
        guard let regex = regex(pattern, caseInsensitive: caseInsensitive) else { return nil }
        return findMatches(regex, in: text)
    }

    /// Replaces every match of `pattern` in `text` using a Substitute-style template (`\0`…`\N`).
    /// Nil when the pattern is invalid.
    public static func replaceAll(_ pattern: String, in text: String, template: String,
                                  caseInsensitive: Bool = false) -> String? {
        guard let regex = regex(pattern, caseInsensitive: caseInsensitive) else { return nil }
        return replaceAll(regex, in: text, template: template)
    }

    // MARK: - Replacement

    /// Pathological patterns (catastrophic backtracking such as `(a+)+$`) are abandoned after using this much CPU
    /// time, so a skin cannot hang the app. The operation then behaves as if nothing matched / the pattern were
    /// invalid. The budget is the matching thread's own CPU time, not wall-clock time: on a busy Mac a low-priority
    /// thread (WebParser matches on a utility queue) can wait a second or more for a core, and a valid pattern must
    /// not be abandoned for that.
    static let timeLimitNanoseconds: UInt64 = 1_000_000_000
    /// Wall-clock backstop, as a multiple of `timeLimitNanoseconds`: matching still ends on a thread that hardly
    /// gets any CPU.
    static let wallClockLimitFactor: UInt64 = 10

    /// All matches (at most `maxCount`), or nil when matching exceeded `timeLimitNanoseconds` of CPU time (or the
    /// wall-clock backstop).
    static func findMatches(_ regex: NSRegularExpression, in text: String,
                            maxCount: Int = .max) -> [NSTextCheckingResult]? {
        let length = (text as NSString).length
        // The progress block runs synchronously on this thread, so the thread's CPU clock measures the matching.
        let start = DispatchTime.now().uptimeNanoseconds
        let startCPU = threadCPUNanoseconds()
        var results: [NSTextCheckingResult] = []
        var timedOut = false
        regex.enumerateMatches(in: text, options: [.reportProgress],
                               range: NSRange(location: 0, length: length)) { result, _, stop in
            if let result {
                results.append(result)
                if results.count >= maxCount {
                    stop.pointee = true
                    return
                }
            }
            // A thread cannot use more CPU time than has passed on the wall clock, so the CPU clock (a system call)
            // is only read once the limit has passed in real time.
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            if elapsed > timeLimitNanoseconds,
               threadCPUNanoseconds() &- startCPU > timeLimitNanoseconds
                || elapsed > timeLimitNanoseconds &* wallClockLimitFactor {
                timedOut = true
                stop.pointee = true
            }
        }
        return timedOut ? nil : results
    }

    /// CPU time the calling thread has used, in nanoseconds (0 when it cannot be read). Read with `thread_info`:
    /// `clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)` is cheaper but reports native 24 MHz ticks as nanoseconds in
    /// an Intel build running under Rosetta.
    static func threadCPUNanoseconds() -> UInt64 {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func nanoseconds(_ t: time_value_t) -> UInt64 {
            UInt64(max(t.seconds, 0)) * 1_000_000_000 + UInt64(max(t.microseconds, 0)) * 1_000
        }
        return nanoseconds(info.user_time) + nanoseconds(info.system_time)
    }

    /// Replaces every match (Substitute semantics). Returns `text` unchanged when nothing matches or on time-out.
    static func replaceAll(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        let ns = text as NSString
        guard let matches = findMatches(regex, in: text), !matches.isEmpty else { return text }
        let parts = templateParts(template, groupCount: regex.numberOfCaptureGroups)
        var out = ""
        var last = 0
        for match in matches {
            let range = match.range
            if range.location > last {
                out += ns.substring(with: NSRange(location: last, length: range.location - last))
            }
            for part in parts {
                switch part {
                case .literal(let literal):
                    out += literal
                case .group(let index):
                    guard index < match.numberOfRanges else { continue }
                    let groupRange = match.range(at: index)
                    if groupRange.location != NSNotFound && groupRange.length > 0 {
                        out += ns.substring(with: groupRange)
                    }
                }
            }
            last = range.location + range.length
        }
        if last < ns.length { out += ns.substring(from: last) }
        return out
    }

    /// Expands a template when there is no match object (e.g. the empty-pattern rule): references insert nothing.
    static func expandTemplate(_ template: String, groups: [String]) -> String {
        var out = ""
        for part in templateParts(template, groupCount: max(groups.count - 1, 0)) {
            switch part {
            case .literal(let literal): out += literal
            case .group(let index): if index < groups.count { out += groups[index] }
            }
        }
        return out
    }

    enum TemplatePart: Equatable {
        case literal(String)
        case group(Int)
    }

    /// `\` + digits → group reference (longest digit prefix that is ≤ `groupCount`; `\0` is the whole match).
    /// A first digit above `groupCount` still consumes that digit and refers to a missing group (inserts nothing).
    static func templateParts(_ template: String, groupCount: Int) -> [TemplatePart] {
        let s = Array(template.unicodeScalars)
        var parts: [TemplatePart] = []
        var literal = String.UnicodeScalarView()
        var i = 0
        func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count, isDigit(s[i + 1]) {
                var number = Int(s[i + 1].value - 48)
                i += 2
                if number != 0 {
                    while i < s.count, isDigit(s[i]) {
                        let extended = number * 10 + Int(s[i].value - 48)
                        guard extended <= groupCount else { break }
                        number = extended
                        i += 1
                    }
                }
                if !literal.isEmpty {
                    parts.append(.literal(String(literal)))
                    literal = String.UnicodeScalarView()
                }
                parts.append(.group(number))
                continue
            }
            literal.append(c)
            i += 1
        }
        if !literal.isEmpty { parts.append(.literal(String(literal))) }
        return parts
    }
}

// MARK: - Cache

/// Thread-safe cache of compiled patterns (including failures, so an invalid pattern is not recompiled on every
/// update). Bounded: cleared when it grows past `limit` (patterns built from changing measure values).
final class PCRERegexCache {
    static let shared = PCRERegexCache()

    private struct Key: Hashable {
        let pattern: String
        let caseInsensitive: Bool
    }

    private enum Entry {
        case valid(NSRegularExpression)
        case invalid
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private let limit = 512

    func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = Key(pattern: pattern, caseInsensitive: caseInsensitive)
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached {
            switch cached {
            case .valid(let regex): return regex
            case .invalid: return nil
            }
        }
        let compiled = Self.compile(pattern, caseInsensitive: caseInsensitive)
        lock.lock()
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = compiled.map(Entry.valid) ?? .invalid
        lock.unlock()
        return compiled
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private static func compile(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let conversion = PCREConverter.convert(pattern)
        guard conversion.isSupported else { return nil }
        // PCRE accepts an empty pattern (matches the empty string everywhere); NSRegularExpression does not.
        let icu = conversion.pattern.isEmpty ? "(?:)" : conversion.pattern
        return try? NSRegularExpression(pattern: icu, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}
