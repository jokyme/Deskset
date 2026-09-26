import Foundation

/// Syntax highlighting for the built-in code editor (docs/editor-design.md §5): splits one line of a skin file into
/// colored tokens. Every construct of the dialect is line-local, so after an edit only the touched lines need to be
/// tokenized again.
///
/// The line itself is classified by `IniSyntax.classify` — the same function the reader uses — so a line is
/// colored as a header, an option or a comment exactly when the parser treats it as one:
/// - `;` starts a comment only as the first non-blank character (the manual has no inline comments), so a `;` in a
///   value is plain text.
/// - A header ends at the first `]`; anything after it is ignored by the reader and colored as a comment. An
///   unterminated `[Name` is still a header.
/// - Keys before the first `=` are trimmed with the reader's ASCII-blank rule; `@Include…` keys get their own kind.
/// - A line without `=` (or with an empty key) is ignored by the reader and gets no tokens.
///
/// Inside a value (docs.rainmeter.net/manual/variables/, …/nesting-variables/, …/section-variables/,
/// …/character-variables/, …/mouse-variables/, …/bangs/, …/formulas/):
/// - `#Var#`, the escape `#*Var*#`, nested `[#Var]` / `[#Color[#Index]]` / `[#*Var*]`, character variables
///   `[\x263A]` / `[\9731]` and mouse variables `$MouseX$` / `$MouseX:%$` are `variable`.
/// - `[Name]`, `[Name:]`, `[Name:X]`, `[Name:%]`, `[Name:/1024,1]`, the escape `[*Name*]` and nested `[&Name…]` are
///   `sectionVariable`. The reader only resolves them with DynamicVariables=1 (and always in bangs); the highlighter
///   cannot know that and colors them wherever they are written.
/// - `[!Bang` and its closing `]` are `bang` (in any value: skins keep actions in variables too); the arguments in
///   between keep their own colors. A bare `!Bang` at the start of an action option (`…Action=`) is a bang as well.
/// - `"double quoted"` and `"""magic quoted"""` strings are `quote`; a pair of single quotes around the whole value
///   (which the reader strips) has its two quote characters colored.
/// - Decimal numbers and whole-value hex colors (`RRGGBB[AA]`) are `number`; the value of `Meter=`, `Measure=` and
///   `Plugin=` is `typeName`; the parentheses of formulas are `paren`.
/// - Everything else in the value is `value`.
///
/// Where constructs overlap, the more specific one wins (in increasing order: value, paren, number, quote,
/// typeName, bang, sectionVariable, variable), so a variable inside a string or a bang keeps its variable color.
/// Tokens never overlap and are sorted; adjacent tokens of the same kind are merged. Ranges are UTF-16 offsets
/// (`NSRange`), ready for NSTextView.
public enum IniHighlighter {
    public enum Kind: String, CaseIterable, Equatable {
        case sectionHeader
        case key
        case includeKey
        case equals
        case value
        /// The value of `Meter=`, `Measure=` and `Plugin=`.
        case typeName
        case variable
        case sectionVariable
        case bang
        case comment
        case number
        case quote
        /// A parenthesis of a formula.
        case paren
    }

    public struct Token: Equatable, CustomStringConvertible {
        public var range: NSRange
        public var kind: Kind

        public init(range: NSRange, kind: Kind) {
            self.range = range
            self.kind = kind
        }

        public init(_ location: Int, _ length: Int, _ kind: Kind) {
            self.init(range: NSRange(location: location, length: length), kind: kind)
        }

        public var description: String { "\(kind.rawValue)(\(range.location),\(range.length))" }
    }

    // MARK: - Entry points

    /// Tokens of one line (without its terminator). Ranges are UTF-16 offsets into `line`.
    public static func tokens(inLine line: String) -> [Token] {
        let units = Array(line.utf16)
        guard !units.isEmpty else { return [] }
        var painter = Painter(count: units.count)
        let content = trimmedRange(units, 0..<units.count)

        switch IniSyntax.classify(Substring(line)) {
        case .blank, .other:
            return []
        case .comment:
            painter.paint(content, .comment)
        case .section:
            let open = content.lowerBound
            let close = units[(open + 1)..<content.upperBound].firstIndex(of: Unit.closeBracket)
            let headerEnd = close.map { $0 + 1 } ?? content.upperBound
            painter.paint(open..<headerEnd, .sectionHeader)
            // "anything after it on the line is ignored" (IniSyntax.classify)
            let rest = trimmedRange(units, headerEnd..<content.upperBound)
            if !rest.isEmpty { painter.paint(rest, .comment) }
        case .entry(let key, let value):
            let keyStart = key.startIndex.utf16Offset(in: line)
            let keyEnd = key.endIndex.utf16Offset(in: line)
            painter.paint(keyStart..<keyEnd, IniSyntax.isIncludeKey(key) ? .includeKey : .key)
            if let equals = units[keyEnd...].firstIndex(of: Unit.equals) {
                painter.paint(equals..<(equals + 1), .equals)
            }
            let valueStart = value.startIndex.utf16Offset(in: line)
            let valueEnd = value.endIndex.utf16Offset(in: line)
            if valueStart < valueEnd {
                paintValue(units, valueStart..<valueEnd, key: key, into: &painter)
            }
        }
        return painter.tokens()
    }

    /// Tokens of every line in `range` of `text`, with ranges relative to `text`. `range` is first widened to whole
    /// lines (see `lineRange(in:containing:)`).
    public static func tokens(in text: NSString, range: NSRange) -> [Token] {
        let lines = lineRange(in: text, containing: range)
        var result: [Token] = []
        forEachLine(in: text, range: lines) { content in
            guard content.length > 0 else { return }
            for token in tokens(inLine: text.substring(with: content)) {
                result.append(Token(content.location + token.range.location, token.range.length, token.kind))
            }
        }
        return result
    }

    /// `range` widened to whole lines, including the last line's terminator. The line that contains the end of
    /// `range` is always included — also when the range ends right after a line break — because an edit that inserts
    /// or removes a break changes the line after it too. Lines end at CR, LF or CRLF only, like
    /// `IniSyntax.forEachLine` (so U+2028 is part of a line, as the reader sees it).
    public static func lineRange(in text: NSString, containing range: NSRange) -> NSRange {
        let length = text.length
        var start = min(max(range.location, 0), length)
        var end = min(start + max(range.length, 0), length)
        func isCRLF(at i: Int) -> Bool {
            i >= 0 && i + 1 < length && text.character(at: i) == Unit.cr && text.character(at: i + 1) == Unit.lf
        }
        // A position between the CR and LF of one terminator belongs to the line the CR ends.
        if isCRLF(at: start - 1) { start -= 1 }
        while start > 0, !isLineBreak(text.character(at: start - 1)) { start -= 1 }
        if isCRLF(at: end - 1) { end += 1 }
        while end < length, !isLineBreak(text.character(at: end)) { end += 1 }
        if end < length { end += isCRLF(at: end) ? 2 : 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Calls `body` with the content range (without terminator) of every line that starts inside `range`.
    static func forEachLine(in text: NSString, range: NSRange, _ body: (NSRange) -> Void) {
        let end = min(range.location + range.length, text.length)
        var start = range.location
        while start < end {
            var i = start
            while i < end, !isLineBreak(text.character(at: i)) { i += 1 }
            body(NSRange(location: start, length: i - start))
            guard i < end else { break }
            let isCRLF = text.character(at: i) == Unit.cr && i + 1 < text.length && text.character(at: i + 1) == Unit.lf
            start = i + (isCRLF ? 2 : 1)
        }
    }

    // MARK: - Values

    private static func paintValue(_ u: [UInt16], _ r: Range<Int>, key: Substring, into painter: inout Painter) {
        painter.paint(r, .value)
        let lowerKey = key.lowercased()
        let inner = unquotedRange(u, r)

        // Parentheses of formulas: the manual requires a formula in an ordinary option to be wrapped in parentheses;
        // Calc's Formula and IfCondition… take one without.
        let isFormulaKey = lowerKey == "formula" || baseName(lowerKey) == "ifcondition"
        if isFormulaKey || (!inner.isEmpty && u[inner.lowerBound] == Unit.openParen) {
            for i in r where u[i] == Unit.openParen || u[i] == Unit.closeParen { painter.paint(i..<(i + 1), .paren) }
        }

        paintNumbers(u, r, into: &painter)
        if isHexColor(u, inner) { painter.paint(inner, .number) }

        if inner != r, u[r.lowerBound] == Unit.singleQuote {
            painter.paint(r.lowerBound..<(r.lowerBound + 1), .quote)
            painter.paint((r.upperBound - 1)..<r.upperBound, .quote)
        }
        paintStrings(u, r, into: &painter)

        if lowerKey == "meter" || lowerKey == "measure" || lowerKey == "plugin" {
            let name = trimmedRange(u, inner)
            if !name.isEmpty { painter.paint(name, .typeName) }
        }

        paintBangs(u, r, into: &painter)
        if baseName(lowerKey).hasSuffix("action"), !inner.isEmpty, u[inner.lowerBound] == Unit.exclamation {
            // A single bare bang: "!HideMeter SomeMeter".
            var end = inner.lowerBound + 1
            while end < inner.upperBound, !isSpace(u[end]) { end += 1 }
            if end > inner.lowerBound + 1 { painter.paint(inner.lowerBound..<end, .bang) }
        }

        paintSectionVariables(u, r, into: &painter)
        paintNestedVariables(u, r, into: &painter)
        paintStandardVariables(u, r, into: &painter)
    }

    /// Decimal numbers not glued to a name (`Meter2`, `x263A` are not numbers). A minus sign right before the digits
    /// is part of the number at the start of the value or after `(`, `,`, `:` or a blank.
    private static func paintNumbers(_ u: [UInt16], _ r: Range<Int>, into painter: inout Painter) {
        var i = r.lowerBound
        while i < r.upperBound {
            let c = u[i]
            let startsNumber = isDigit(c) || (c == Unit.dot && i + 1 < r.upperBound && isDigit(u[i + 1]))
            guard startsNumber, i == r.lowerBound || !isWordUnit(u[i - 1]) else {
                i += 1
                continue
            }
            var start = i
            if start > r.lowerBound, u[start - 1] == Unit.minus {
                let before = start - 1
                if before == r.lowerBound || [Unit.openParen, Unit.comma, Unit.colon].contains(u[before - 1])
                    || isSpace(u[before - 1]) {
                    start = before
                }
            }
            var end = i
            while end < r.upperBound, isDigit(u[end]) { end += 1 }
            if end + 1 < r.upperBound, u[end] == Unit.dot, isDigit(u[end + 1]) {
                end += 1
                while end < r.upperBound, isDigit(u[end]) { end += 1 }
            }
            if end == i, u[i] == Unit.dot { // ".5"
                end = i + 1
                while end < r.upperBound, isDigit(u[end]) { end += 1 }
            }
            painter.paint(start..<end, .number)
            i = end
        }
    }

    /// `"…"` and `"""…"""`. A lone `"` without a partner stays plain (`Text=5" tall`); an unterminated magic quote
    /// runs to the end of the value. As in the action parser, a run of more than three closing quotes ends with its
    /// last three.
    private static func paintStrings(_ u: [UInt16], _ r: Range<Int>, into painter: inout Painter) {
        var i = r.lowerBound
        while i < r.upperBound {
            guard u[i] == Unit.doubleQuote else { i += 1; continue }
            if let end = stringEnd(u, from: i, limit: r.upperBound) {
                painter.paint(i..<end, .quote)
                i = end
            } else {
                i += 1
            }
        }
    }

    /// The index after the string starting at `start` (a `"`), or nil when a plain string has no closing quote.
    private static func stringEnd(_ u: [UInt16], from start: Int, limit: Int) -> Int? {
        let isMagic = start + 2 < limit && u[start + 1] == Unit.doubleQuote && u[start + 2] == Unit.doubleQuote
        if isMagic {
            var k = start + 3
            while k + 2 < limit {
                if u[k] == Unit.doubleQuote, u[k + 1] == Unit.doubleQuote, u[k + 2] == Unit.doubleQuote {
                    var end = k + 3
                    while end < limit, u[end] == Unit.doubleQuote { end += 1 }
                    return end
                }
                k += 1
            }
            return limit
        }
        var k = start + 1
        while k < limit, u[k] != Unit.doubleQuote { k += 1 }
        return k < limit ? k + 1 : nil
    }

    /// `[!Name` … `]`: the closing bracket is found like the action parser does — brackets inside quoted arguments
    /// do not count, nested `[…]` (section variables) are skipped.
    private static func paintBangs(_ u: [UInt16], _ r: Range<Int>, into painter: inout Painter) {
        var i = r.lowerBound
        while i + 1 < r.upperBound {
            guard u[i] == Unit.openBracket, u[i + 1] == Unit.exclamation else { i += 1; continue }
            var nameEnd = i + 2
            while nameEnd < r.upperBound, !isSpace(u[nameEnd]), u[nameEnd] != Unit.closeBracket,
                  u[nameEnd] != Unit.openBracket, u[nameEnd] != Unit.doubleQuote {
                nameEnd += 1
            }
            painter.paint(i..<nameEnd, .bang)
            var j = nameEnd
            var depth = 0
            var close: Int?
            while j < r.upperBound {
                let c = u[j]
                if c == Unit.doubleQuote {
                    j = stringEnd(u, from: j, limit: r.upperBound) ?? (j + 1)
                    continue
                }
                if c == Unit.openBracket {
                    depth += 1
                } else if c == Unit.closeBracket {
                    if depth == 0 { close = j; break }
                    depth -= 1
                }
                j += 1
            }
            guard let close else { break } // unterminated: the rest of the value belongs to this bang
            painter.paint(close..<(close + 1), .bang)
            i = close + 1
        }
    }

    /// Classic section variables: from a `[` to the next `]` with no `[` in between (as the resolver scans them),
    /// whose body is a plain section name (no blanks, not a nesting prefix, a bang or a quoted command), optionally
    /// followed by `:parameter`. `[*Name*]` (the escape) is included.
    private static func paintSectionVariables(_ u: [UInt16], _ r: Range<Int>, into painter: inout Painter) {
        var i = r.lowerBound
        while i < r.upperBound {
            guard u[i] == Unit.openBracket else { i += 1; continue }
            var j = i + 1
            while j < r.upperBound, u[j] != Unit.closeBracket, u[j] != Unit.openBracket { j += 1 }
            guard j < r.upperBound else { break }
            if u[j] == Unit.openBracket { i = j; continue }
            let body = (i + 1)..<j
            if let first = body.first.map({ u[$0] }), !notSectionStart.contains(first) {
                let nameEnd = u[body].firstIndex(of: Unit.colon) ?? j
                let name = body.lowerBound..<nameEnd
                if !name.isEmpty, !u[name].contains(where: { isSpace($0) || $0 == Unit.doubleQuote }) {
                    painter.paint(i..<(j + 1), .sectionVariable)
                }
            }
            i = j + 1
        }
    }

    /// First characters that make `[…]` something other than a classic section variable.
    private static let notSectionStart: Set<UInt16> = [
        Unit.hash, Unit.ampersand, Unit.backslash, Unit.dollar, Unit.exclamation, Unit.doubleQuote, Unit.singleQuote,
        Unit.space, Unit.tab,
    ]

    /// Nesting syntax `[#…]`, `[&…]`, `[\…]`, `[$…]`: the whole construct up to its matching `]`, inner constructs
    /// included (`[#Color[#Index]]` is one token).
    private static func paintNestedVariables(_ u: [UInt16], _ r: Range<Int>, into painter: inout Painter) {
        // Matching brackets in one pass (a stack), so an unterminated construct does not make the scan quadratic.
        var match = [Int](repeating: -1, count: r.count)
        var stack: [Int] = []
        for i in r {
            if u[i] == Unit.openBracket {
                stack.append(i)
            } else if u[i] == Unit.closeBracket, let open = stack.popLast() {
                match[open - r.lowerBound] = i
            }
        }
        var i = r.lowerBound
        while i + 1 < r.upperBound {
            guard u[i] == Unit.openBracket else { i += 1; continue }
            let kind: Kind
            switch u[i + 1] {
            case Unit.hash, Unit.backslash, Unit.dollar: kind = .variable
            case Unit.ampersand: kind = .sectionVariable
            default: i += 1; continue
            }
            let close = match[i - r.lowerBound]
            guard close > i + 2 else { i += 2; continue } // unterminated or empty: inner constructs may still count
            painter.paint(i..<(close + 1), kind)
            i = close + 1
        }
    }

    /// `#Var#` (and `#*Var*#`, `#@#`): a name without blanks, quotes or brackets between two `#`. As in the resolver,
    /// when the text between two `#` is not a name, the second `#` may open the next reference (`#1 and #Var#`).
    /// `$Mouse…$` mouse variables likewise.
    private static func paintStandardVariables(_ u: [UInt16], _ r: Range<Int>, into painter: inout Painter) {
        for delimiter in [Unit.hash, Unit.dollar] {
            var i = r.lowerBound
            while i < r.upperBound {
                guard u[i] == delimiter else { i += 1; continue }
                var j = i + 1
                while j < r.upperBound, u[j] != delimiter { j += 1 }
                guard j < r.upperBound else { break }
                let body = (i + 1)..<j
                var isName = !body.isEmpty && !u[body].contains {
                    isSpace($0) || $0 == Unit.doubleQuote || $0 == Unit.openBracket || $0 == Unit.closeBracket
                }
                if isName, delimiter == Unit.dollar {
                    isName = String(decoding: u[body], as: UTF16.self).lowercased().hasPrefix("mouse")
                }
                if isName {
                    painter.paint(i..<(j + 1), .variable)
                    i = j + 1
                } else {
                    i = j
                }
            }
        }
    }

    // MARK: - Helpers

    /// The range inside one pair of identical quotes wrapping the whole value (`IniSyntax.unquote`'s rule).
    private static func unquotedRange(_ u: [UInt16], _ r: Range<Int>) -> Range<Int> {
        guard r.count >= 2 else { return r }
        let first = u[r.lowerBound], last = u[r.upperBound - 1]
        guard first == last, first == Unit.doubleQuote || first == Unit.singleQuote else { return r }
        return (r.lowerBound + 1)..<(r.upperBound - 1)
    }

    /// `RRGGBB` or `RRGGBBAA` as the whole value.
    private static func isHexColor(_ u: [UInt16], _ r: Range<Int>) -> Bool {
        guard r.count == 6 || r.count == 8 else { return false }
        return u[r].allSatisfy { isDigit($0) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) }
    }

    /// `IfCondition2` → `ifcondition` (numbered options share their base name).
    private static func baseName(_ lowerKey: String) -> String {
        String(lowerKey.reversed().drop(while: { $0.isASCII && $0.isNumber }).reversed())
    }

    /// `range` without leading and trailing ASCII blanks (the reader's trimming rule).
    private static func trimmedRange(_ u: [UInt16], _ r: Range<Int>) -> Range<Int> {
        var start = r.lowerBound, end = r.upperBound
        while start < end, isBlank(u[start]) { start += 1 }
        while end > start, isBlank(u[end - 1]) { end -= 1 }
        return start..<end
    }

    /// `IniSyntax.isBlank` on UTF-16 (all of its blanks are single units).
    private static func isBlank(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return IniSyntax.isBlank(scalar)
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == Unit.space || c == Unit.tab }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isLineBreak(_ c: UInt16) -> Bool { c == Unit.lf || c == Unit.cr }

    /// Letters, digits, `_` and `.` glue a digit to a name (`Meter2`, `v1.2`); non-ASCII letters count too.
    private static func isWordUnit(_ c: UInt16) -> Bool {
        if isDigit(c) || c == 0x5F || c == Unit.dot { return true }
        let lower = c | 0x20
        if lower >= 0x61 && lower <= 0x7A { return true }
        return c >= 0x80
    }

    private enum Unit {
        static let tab: UInt16 = 0x09
        static let lf: UInt16 = 0x0A
        static let cr: UInt16 = 0x0D
        static let space: UInt16 = 0x20
        static let exclamation: UInt16 = 0x21
        static let doubleQuote: UInt16 = 0x22
        static let hash: UInt16 = 0x23
        static let dollar: UInt16 = 0x24
        static let ampersand: UInt16 = 0x26
        static let singleQuote: UInt16 = 0x27
        static let openParen: UInt16 = 0x28
        static let closeParen: UInt16 = 0x29
        static let comma: UInt16 = 0x2C
        static let minus: UInt16 = 0x2D
        static let dot: UInt16 = 0x2E
        static let colon: UInt16 = 0x3A
        static let equals: UInt16 = 0x3D
        static let openBracket: UInt16 = 0x5B
        static let backslash: UInt16 = 0x5C
        static let closeBracket: UInt16 = 0x5D
    }

    /// One kind per UTF-16 unit; later paints win. Turned into merged, sorted tokens at the end.
    private struct Painter {
        var kinds: [Kind?]

        init(count: Int) { kinds = Array(repeating: nil, count: count) }

        mutating func paint(_ r: Range<Int>, _ kind: Kind) {
            let lower = max(r.lowerBound, 0), upper = min(r.upperBound, kinds.count)
            guard lower < upper else { return }
            for i in lower..<upper { kinds[i] = kind }
        }

        func tokens() -> [Token] {
            var result: [Token] = []
            var i = 0
            while i < kinds.count {
                guard let kind = kinds[i] else { i += 1; continue }
                var j = i + 1
                while j < kinds.count, kinds[j] == kind { j += 1 }
                result.append(Token(i, j - i, kind))
                i = j
            }
            return result
        }
    }
}
