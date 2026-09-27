import Foundation

/// The kind of top-level block the parser is in. The grammar is the same everywhere (§2.3); only two choices depend
/// on it: in `options`, `name = Control(…)` is an option declaration whose control is a call statement, and in
/// `info` / `package` a field written without its colon is reported as such (DK2008).
enum ParseContext: Equatable {
    case topLevel, info, package, options, widget, style, translations, component, other
}

/// What owns a block: its name for DK2001's message, the statement whose line gives the indentation of an inserted
/// `}`, and for a modifier's block the modifier and its `of:` argument (closure-parameter fix-its).
struct BlockOwner {
    /// `Row`, `.onClick`, `if`, `widget`, `style arrow`.
    var head: String
    /// Token index of the first token of the owning statement.
    var statementStart: Int
    var modifierName: String? = nil
    /// Token index range of the modifier's `of:` argument value (`.onChange(of: music.title)`).
    var ofArgument: ClosedRange<Int>? = nil
}

/// Recursive descent over the lexer's tokens (§2.3), with the recovery of §2.11: missing tokens are inserted, tokens
/// that fit nowhere are wrapped in `unexpected` nodes, braces were matched before parsing (counting first,
/// indentation only to repair), foreign lines become `foreignConstruct` nodes, and nesting is bounded. Every token
/// the lexer produced ends up in the tree exactly once, in order, so printing the tree gives back the text.
struct Parser {
    let tokens: [Token]
    let starts: [Int]
    let newlineBefore: [Bool]
    let braces: BraceMatching
    let file: DeskFileID
    let lines: LineTable
    let bytes: [UInt8]
    let eofIndex: Int
    /// `interpolationStart` token index → its `interpolationEnd` token index.
    let interpolationEnds: [Int: Int]

    var i = 0
    /// Tokens at and after this index are out of reach: the closing brace of the block being parsed, the end of an
    /// interpolation, or the end of the file.
    var limit: Int
    var diagnostics: [Diagnostic] = []
    var context: ParseContext = .topLevel
    var blockDepth = 0
    var expressionDepth = 0
    /// Open `(` and `[` around the current expression: N7 recovery differs inside brackets.
    var bracketDepth = 0
    var depthReported = false
    /// Set when an expression past the nesting limit was skipped: the expressions around it are incomplete, and
    /// what they miss is not reported again. Cleared when the outermost expression ends.
    var suppressMissing = false
    var foreignLineCount = 0
    var foreignFileReported = false
    /// Byte ranges of the foreign runs (line-level `foreignConstruct` nodes): the lexer's diagnostics inside them
    /// are dropped, since the run's one diagnostic stands for everything in it.
    var foreignRunRanges: [Range<Int>] = []
    /// Answers of `fileHasTopLevelBlock`, which scans the whole file.
    var topLevelBlockWords: [String: Bool] = [:]

    init(lexed: LexedFile, braces: BraceMatching, file: DeskFileID, lines: LineTable, bytes: [UInt8]) {
        tokens = lexed.tokens
        starts = lexed.starts
        newlineBefore = lexed.newlineBefore
        self.braces = braces
        self.file = file
        self.lines = lines
        self.bytes = bytes
        eofIndex = lexed.tokens.count - 1
        limit = eofIndex
        var ends: [Int: Int] = [:]
        var stack: [Int] = []
        for j in lexed.tokens.indices {
            switch lexed.tokens[j].kind {
            case .interpolationStart: stack.append(j)
            case .interpolationEnd: if let open = stack.popLast() { ends[open] = j }
            default: break
            }
        }
        interpolationEnds = ends
    }

    // MARK: - Tokens

    @inline(__always) func kind(_ j: Int) -> TokenKind { j < limit ? tokens[j].kind : .eof }
    @inline(__always) var current: TokenKind { kind(i) }
    /// NL(t): a line break between the previous token and token `j`.
    @inline(__always) func nl(_ j: Int) -> Bool { j < tokens.count ? newlineBefore[j] : true }
    /// Token `j` is within reach and on the same line as the token before it.
    @inline(__always) func sameLine(_ j: Int) -> Bool { j < limit && !newlineBefore[j] }

    @inline(__always) mutating func take() -> SyntaxChild {
        let token = tokens[i]
        i += 1
        return .token(token)
    }

    @inline(__always) func missing(_ kind: TokenKind) -> SyntaxChild { .token(.missing(kind)) }

    func textStart(_ j: Int) -> Int { starts[j] }
    func textEnd(_ j: Int) -> Int { starts[j] + tokens[j].text.utf8.count }
    func textRange(_ j: Int) -> Range<Int> { starts[j]..<textEnd(j) }
    /// The end of the token's trailing trivia (where the next token's leading trivia starts).
    func fullEnd(_ j: Int) -> Int { textEnd(j) + tokens[j].trailingTrivia.utf8Length }
    /// The text of tokens `a...b`, with the trivia between them.
    func text(_ a: Int, _ b: Int) -> String {
        guard a <= b, a < tokens.count else { return "" }
        return String(decoding: bytes[starts[a]..<textEnd(min(b, tokens.count - 1))], as: UTF8.self)
    }
    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
    /// Where a missing token before `i` goes: right after the text of the previous token.
    var insertionPoint: Int { i > 0 ? textEnd(i - 1) : 0 }
    func lineIndex(ofToken j: Int) -> Int { lines.lineIndex(of: starts[min(j, tokens.count - 1)]) }
    func lineNumber(ofToken j: Int) -> Int { lineIndex(ofToken: j) + 1 }
    func indentation(ofToken j: Int) -> Int { lines.indentation(ofLine: lineIndex(ofToken: j)) }

    /// A name: an identifier, a reserved word (usable as a member name and a label, D12) or a name with non-ASCII
    /// letters (already reported, DK1007).
    func isNameLike(_ j: Int) -> Bool {
        let k = kind(j)
        return k == .identifier || k == .invalidIdentifier || k.isKeyword
    }

    /// The reserved word an identifier stands for when it is written in another case (`If`, `AND`, `True`).
    func keywordVariant(_ j: Int) -> TokenKind? {
        guard kind(j) == .identifier, tokens[j].flags.contains(.keywordCaseVariant) else { return nil }
        return Chars.reservedWords[tokens[j].name.lowercased()]
    }

    /// Token `j` is the reserved word `keyword`, or a case variant of it.
    func isKeyword(_ j: Int, _ keyword: TokenKind) -> Bool {
        kind(j) == keyword || keywordVariant(j) == keyword
    }

    /// Takes a reserved word; a case variant is taken as the keyword and reported (DK3013).
    mutating func takeKeyword() -> SyntaxChild {
        if let keyword = keywordVariant(i) { reportCaseVariant(i, keyword) }
        return take()
    }

    mutating func reportCaseVariant(_ j: Int, _ keyword: TokenKind) {
        let spelling = tokens[j].name.lowercased()
        _ = keyword
        report(.wrongCase, .error, textRange(j), ["suggestion": .code(spelling), "name": .code(tokens[j].text)],
               fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(spelling)],
                              edits: [edit(textRange(j), spelling)])])
    }

    // MARK: - Diagnostics

    mutating func report(_ id: DiagnosticID, _ severity: Severity, _ range: Range<Int>,
                         _ arguments: [String: DiagnosticArgument] = [:], fixIts: [FixIt] = [],
                         notes: [Note] = []) {
        diagnostics.append(Diagnostic(id: id, severity: severity, file: file, range: range, arguments: arguments,
                                      notes: notes, fixIts: fixIts))
    }

    func edit(_ range: Range<Int>, _ replacement: String) -> TextEdit {
        TextEdit(file: file, range: range, replacement: replacement)
    }

    /// DK2005 at the current position: the token there when it is on the same line, else just after the previous
    /// token. `insert` gives the fix-it text when there is exactly one thing to insert.
    mutating func expected(_ slot: SyntaxSlot, insert: String? = nil) {
        if suppressMissing { return }
        let range: Range<Int> = (i < limit && !nl(i)) ? textRange(i) : insertionPoint..<insertionPoint
        var fixIts: [FixIt] = []
        if let insert {
            fixIts.append(FixIt(titleKey: "insert", titleArguments: ["text": .code(insert.trimmingCharacters(in: .whitespaces))],
                                edits: [edit(insertionPoint..<insertionPoint, insert)]))
        }
        report(.expected, .error, range, ["expected": .name(slot.rawValue)], fixIts: fixIts)
    }

    /// A range covering tokens `a...b`, or the whole lines they are alone on (for "remove" fix-its).
    func removalRange(_ a: Int, _ b: Int) -> Range<Int> {
        let start = starts[a]
        let end = textEnd(b)
        let firstLine = lines.lineIndex(of: start)
        let lastLine = lines.lineIndex(of: max(start, end - 1))
        let lineStart = lines.starts[firstLine]
        let lineContentEnd = lines.contentEnd(ofLine: lastLine)
        let before = bytes[lineStart..<start].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        let after = bytes[end..<lineContentEnd].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        if before && after {
            // The whole line, with its line break.
            var stop = lineContentEnd
            if stop < bytes.count, bytes[stop] == 0x0D { stop += 1 }
            if stop < bytes.count, bytes[stop] == 0x0A { stop += 1 }
            return lineStart..<stop
        }
        return start..<end
    }

    // MARK: - Nodes

    func node(_ kind: SyntaxKind, _ children: [SyntaxChild]) -> SyntaxNode {
        SyntaxNode(kind: kind, children: children)
    }

    func missingExpression() -> SyntaxNode {
        SyntaxNode(kind: .identifierExpr, children: [.token(.missing(.identifier))])
    }

    func missingBlock() -> SyntaxNode {
        SyntaxNode(kind: .block, children: [.token(.missing(.lBrace)), .token(.missing(.rBrace))])
    }

    // MARK: - Snapshots

    struct Snapshot {
        var i: Int
        var children: Int
        var diagnostics: Int
        var foreignLineCount: Int
        var foreignFileReported: Bool
        var depthReported: Bool
        var foreignRuns: Int
    }

    func snapshot(_ children: [SyntaxChild]) -> Snapshot {
        Snapshot(i: i, children: children.count, diagnostics: diagnostics.count, foreignLineCount: foreignLineCount,
                 foreignFileReported: foreignFileReported, depthReported: depthReported,
                 foreignRuns: foreignRunRanges.count)
    }

    mutating func restore(_ s: Snapshot, _ children: inout [SyntaxChild]) {
        i = s.i
        children.removeSubrange(s.children...)
        diagnostics.removeSubrange(s.diagnostics...)
        foreignLineCount = s.foreignLineCount
        foreignFileReported = s.foreignFileReported
        depthReported = s.depthReported
        foreignRunRanges.removeSubrange(s.foreignRuns...)
    }

    /// Whether a byte offset lies in a foreign run.
    func isInForeignRun(_ offset: Int) -> Bool {
        var low = 0
        var high = foreignRunRanges.count
        while low < high {
            let mid = (low + high) / 2
            if foreignRunRanges[mid].upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low < foreignRunRanges.count && foreignRunRanges[low].contains(offset)
    }

    /// Whether the parser reported an error on the line of token `s.i` since the snapshot.
    func lineHasParseError(since s: Snapshot) -> Bool {
        guard s.diagnostics < diagnostics.count else { return false }
        let line = lineIndex(ofToken: s.i)
        let lineStart = lines.starts[line]
        let lineEnd = lines.contentEnd(ofLine: line)
        for d in diagnostics[s.diagnostics...] where d.severity == .error {
            if d.range.lowerBound >= lineStart && d.range.lowerBound <= lineEnd { return true }
        }
        return false
    }

    // MARK: - File

    mutating func parseSourceFile() -> SyntaxNode {
        limit = eofIndex
        context = .topLevel
        var children: [SyntaxChild] = []
        parseBody(into: &children, owner: nil)
        // Anything the body left before the end of the file (it never does) goes into an unexpected node.
        if i < eofIndex {
            var rest: [SyntaxChild] = []
            while i < eofIndex { rest.append(take()) }
            children.append(.node(node(.unexpected, rest)))
        }
        i = eofIndex
        children.append(take())
        return node(.sourceFile, children)
    }

    // MARK: - Bodies

    /// The statements of a block (or of the file), with their separators, up to `limit`.
    mutating func parseBody(into children: inout [SyntaxChild], owner: BlockOwner?) {
        var expectSeparator = false
        var first = true
        var previous: (node: SyntaxNode, start: Int, end: Int)? = nil
        var pendingLine: (snapshot: Snapshot, expectSeparator: Bool, first: Bool)? = nil
        while true {
            let atEnd = i >= limit
            let lineStart = !atEnd && (first || nl(i))
            if atEnd || lineStart, let pending = pendingLine {
                pendingLine = nil
                if lineHasParseError(since: pending.snapshot),
                   let match = foreignMatch(at: pending.snapshot.i, firstInBlock: pending.first, owner: owner,
                                            afterFailure: true) {
                    restore(pending.snapshot, &children)
                    let run = consumeForeignRun(match)
                    children.append(.node(run))
                    expectSeparator = match.kind != .closureParameter
                    first = false
                    previous = nil
                    continue
                }
            }
            if atEnd { break }
            switch tokens[i].kind {
            case .semicolon, .comma:
                if expectSeparator {
                    children.append(take())
                    expectSeparator = false
                } else {
                    children.append(.node(strayToken()))
                }
                continue
            case .rBrace:
                children.append(.node(extraClosingBrace()))
                continue
            case .unlexedText:
                children.append(.node(node(.unexpected, [take()])))
                continue
            default:
                break
            }
            if lineStart {
                if let match = foreignMatch(at: i, firstInBlock: first, owner: owner, afterFailure: false) {
                    children.append(.node(consumeForeignRun(match)))
                    expectSeparator = match.kind != .closureParameter
                    first = false
                    previous = nil
                    continue
                }
                pendingLine = (snapshot(children), expectSeparator, first)
            } else if expectSeparator {
                // A second statement on the same line with no separator between them.
                guard canStartDeskStatement(i) else {
                    children.append(.node(unexpectedRun()))
                    continue
                }
                // A `{` there could not attach to the statement (N5): it is reported as a block that nothing takes
                // (DK2010), not as a second statement.
                if let previous, tokens[i].kind != .lBrace { reportMissingSeparator(after: previous.end, before: i) }
            }
            let start = i
            let statement = parseStatement(owner: owner, previous: previous)
            children.append(.node(statement))
            if i == start {
                // Nothing was consumed (cannot happen with the dispatch below, but progress is guaranteed).
                children.append(.node(node(.unexpected, [take()])))
            }
            previous = (statement, start, i - 1)
            expectSeparator = true
            first = false
        }
    }

    /// Tokens that can start a Desk statement (§2.3), used to tell DK2031 from DK2006.
    func canStartDeskStatement(_ j: Int) -> Bool {
        switch kind(j) {
        case .identifier, .invalidIdentifier, .variableKeyword, .savedKeyword, .computedKeyword, .ifKeyword,
             .forKeyword, .elseKeyword, .dot, .stringStart, .rawString, .eventKeyword, .lBrace:
            return true
        default:
            return false
        }
    }

    /// Where recovery resumes: a token that can start a statement or a foreign line.
    func isSynchronisationToken(_ j: Int) -> Bool {
        if canStartDeskStatement(j) { return true }
        switch kind(j) {
        case .lBracket, .less, .lessSlash, .at, .hash, .foreignHashComment, .foreignRainmeterComment, .htmlComment:
            return true
        default:
            return false
        }
    }

    /// A `;` or `,` with no statement before it.
    mutating func strayToken() -> SyntaxNode {
        let j = i
        report(.unexpected, .error, textRange(j), ["text": .code(tokens[j].text)],
               fixIts: [FixIt(titleKey: "remove", edits: [edit(textRange(j), "")])])
        return node(.unexpected, [take()])
    }

    /// A `}` that closes nothing (DK2002).
    mutating func extraClosingBrace() -> SyntaxNode {
        let j = i
        report(.extraClosingBrace, .error, textRange(j),
               fixIts: [FixIt(titleKey: "remove", edits: [edit(removalRange(j, j), "")])])
        return node(.unexpected, [take()])
    }

    /// Wraps tokens from here to the next synchronisation point (§2.11 rule 2) in an `unexpected` node: a line
    /// break before a token that can start a statement, a `;` or `,`, a `}`, or the end. Blocks inside are parsed,
    /// so their braces stay matched. Reports DK2006 once for the whole run.
    mutating func unexpectedRun(report shouldReport: Bool = true) -> SyntaxNode {
        let first = i
        var children: [SyntaxChild] = []
        repeat {
            if kind(i) == .lBrace {
                children.append(.node(parseBlock(owner: BlockOwner(head: "{", statementStart: first))))
            } else {
                children.append(take())
            }
        } while i < limit && !isRunStop(i)
        if shouldReport {
            let last = i - 1
            var fixIts: [FixIt] = []
            if lineIndex(ofToken: first) == lineIndex(ofToken: last) {
                fixIts.append(FixIt(titleKey: "remove", edits: [edit(removalRange(first, last), "")]))
            }
            report(.unexpected, .error, starts[first]..<textEnd(last), ["text": .code(shortText(first))],
                   fixIts: fixIts)
        }
        return node(.unexpected, children)
    }

    func isRunStop(_ j: Int) -> Bool {
        switch kind(j) {
        case .semicolon, .comma, .rBrace, .unlexedText, .eof: return true
        default: return nl(j) && isSynchronisationToken(j)
        }
    }

    /// The text of token `j` for a message, shortened.
    func shortText(_ j: Int) -> String {
        let t = tokens[j].text
        if t.count <= 24 { return t }
        return String(t.prefix(23)) + "…"
    }

    mutating func reportMissingSeparator(after a: Int, before b: Int) {
        let indent = String(repeating: " ", count: indentation(ofToken: b))
        let gap = textEnd(a)..<starts[b]
        report(.missingSeparator, .error, textRange(b),
               fixIts: [FixIt(titleKey: "newLine", edits: [edit(gap, lines.newline + indent)]),
                        FixIt(titleKey: "insert", titleArguments: ["text": .code(",")],
                              edits: [edit(textEnd(a)..<textEnd(a), ",")])])
    }

    // MARK: - Statements

    /// One statement (§2.3 "How the parser chooses a statement"). At the top level, block words start the file's
    /// blocks and anything else is a stray statement.
    mutating func parseStatement(owner: BlockOwner?, previous: (node: SyntaxNode, start: Int, end: Int)?) -> SyntaxNode {
        if context == .topLevel {
            if let item = parseTopLevelItem() { return item }
            let statement = parseInnerStatement(owner: owner, previous: previous)
            switch statement.kind {
            case .unexpected, .foreignConstruct: return statement
            default: return node(.strayStatement, [.node(statement)])
            }
        }
        return parseInnerStatement(owner: owner, previous: previous)
    }

    mutating func parseInnerStatement(owner: BlockOwner?, previous: (node: SyntaxNode, start: Int, end: Int)?) -> SyntaxNode {
        switch tokens[i].kind {
        case .variableKeyword, .savedKeyword, .computedKeyword:
            return parseDeclaration()
        case .ifKeyword:
            return parseIf(allowModifiers: true)
        case .forKeyword:
            return parseFor()
        case .elseKeyword:
            return parseStrayElse()
        case .dot:
            return parseModifierStatement()
        case .stringStart, .rawString, .tripleQuoteString:
            return parseStringStatement()
        case .lBrace:
            return parseStrayBlock(previous: previous)
        case .lParen:
            return parseStrayParentheses(previous: previous)
        case .identifier:
            if let keyword = keywordVariant(i) {
                switch keyword {
                case .ifKeyword: return parseIf(allowModifiers: true)
                case .forKeyword: return parseFor()
                case .variableKeyword, .savedKeyword, .computedKeyword:
                    if isNameLike(i + 1) && sameLine(i + 1) { return parseDeclaration() }
                case .elseKeyword: return parseStrayElse()
                default: break
                }
            }
            if isStyleDeclarationStart() { return parseStyleDeclaration() }
            if isComponentDeclarationStart() { return parseComponentDeclaration() }
            if kind(i + 1) == .colon && sameLine(i + 1) { return parseField(missingColon: false) }
            if (context == .info || context == .package) && startsFieldValue(i + 1) {
                return parseField(missingColon: true)
            }
            return parseCallOrAssignment()
        case .invalidIdentifier:
            if kind(i + 1) == .colon && sameLine(i + 1) { return parseField(missingColon: false) }
            return parseCallOrAssignment()
        case .eventKeyword:
            if kind(i + 1) == .colon && sameLine(i + 1) { return parseField(missingColon: false) }
            return parseCallOrAssignment()
        case .trueKeyword, .falseKeyword, .inKeyword, .andKeyword, .orKeyword, .notKeyword:
            if kind(i + 1) == .colon && sameLine(i + 1) { return parseField(missingColon: false) }
            return unexpectedRun()
        default:
            return unexpectedRun()
        }
    }

    /// In `info` and `package`: a name followed on the same line by a value, with no colon (DK2008).
    func startsFieldValue(_ j: Int) -> Bool {
        guard sameLine(j) else { return false }
        switch kind(j) {
        case .stringStart, .rawString, .number, .trueKeyword, .falseKeyword, .lBracket: return true
        case .dot: return isNameLike(j + 1) && sameLine(j + 1)
        case .minus: return kind(j + 1) == .number
        default: return false
        }
    }

    // MARK: Top level

    mutating func parseTopLevelItem() -> SyntaxNode? {
        guard kind(i) == .identifier else { return nil }
        let word = tokens[i].name
        switch word {
        case "info", "options", "widget", "translations", "package":
            if kind(i + 1) == .lBrace { return parseTopLevelBlock(word, named: false) }
            if isNameLike(i + 1) && sameLine(i + 1) && kind(i + 2) == .lBrace {
                return parseTopLevelBlock(word, named: true)
            }
            return nil
        case "style":
            return isStyleDeclarationStart() ? parseStyleDeclaration() : nil
        case "component":
            return isComponentDeclarationStart() ? parseComponentDeclaration() : nil
        case "script":
            guard kind(i + 1) == .opaqueBlock else { return nil }
            return node(.scriptBlock, [take(), take()])
        default:
            return nil
        }
    }

    mutating func parseTopLevelBlock(_ word: String, named: Bool) -> SyntaxNode {
        let start = i
        var children: [SyntaxChild] = [take()]
        if named {
            let nameIndex = i
            children.append(.node(node(.unexpected, [take()])))
            if word == "widget" {
                report(.namedWidget, .error, textRange(nameIndex), ["name": .code(tokens[nameIndex].text)],
                       fixIts: namedWidgetFixIts(keyword: start, name: nameIndex))
            } else {
                report(.unexpected, .error, textRange(nameIndex), ["text": .code(tokens[nameIndex].text)],
                       fixIts: [FixIt(titleKey: "remove", edits: [edit(fullEnd(start)..<textEnd(nameIndex), "")])])
            }
        }
        let kind: SyntaxKind
        let blockContext: ParseContext
        switch word {
        case "info": kind = .infoBlock; blockContext = .info
        case "options": kind = .optionsBlock; blockContext = .options
        case "widget": kind = .widgetBlock; blockContext = .widget
        case "translations": kind = .translationsBlock; blockContext = .translations
        default: kind = .packageBlock; blockContext = .package
        }
        let saved = context
        context = blockContext
        children.append(.node(parseBlock(owner: BlockOwner(head: word, statementStart: start))))
        context = saved
        return node(kind, children)
    }

    /// `widget CPU { … }`: the name moves to `info { name: "CPU" }` (created when the file has no `info` block).
    mutating func namedWidgetFixIts(keyword: Int, name: Int) -> [FixIt] {
        guard !fileHasTopLevelBlock("info") else { return [] }
        let removeName = edit(fullEnd(keyword)..<textEnd(name), "")
        let lineStart = lines.starts[lineIndex(ofToken: keyword)]
        let quoted = "\"" + tokens[name].text + "\""
        let insertInfo = edit(lineStart..<lineStart, "info { name: \(quoted) }" + lines.newline + lines.newline)
        return [FixIt(titleKey: "moveNameToInfo", edits: [insertInfo, removeName])]
    }

    /// Whether the file has a top-level block with this word (scans the tokens, counting braces).
    mutating func fileHasTopLevelBlock(_ word: String) -> Bool {
        if let known = topLevelBlockWords[word] { return known }
        let found = scanForTopLevelBlock(word)
        topLevelBlockWords[word] = found
        return found
    }

    func scanForTopLevelBlock(_ word: String) -> Bool {
        var depth = 0
        for j in 0..<eofIndex {
            switch tokens[j].kind {
            case .lBrace:
                depth += 1
            case .rBrace:
                depth = max(0, depth - 1)
            case .identifier where depth == 0 && tokens[j].name == word:
                if j + 1 < eofIndex, tokens[j + 1].kind == .lBrace { return true }
            default:
                break
            }
        }
        return false
    }

    func isStyleDeclarationStart() -> Bool {
        guard kind(i) == .identifier, tokens[i].name == "style" else { return false }
        if kind(i + 1) == .lBrace && sameLine(i + 1) { return true }
        guard isNameLike(i + 1) && sameLine(i + 1) else { return false }
        switch kind(i + 2) {
        case .equal, .colon, .dot, .lParen, .plusEqual, .minusEqual: return false
        default: return true
        }
    }

    func isComponentDeclarationStart() -> Bool {
        guard kind(i) == .identifier, tokens[i].name == "component" else { return false }
        return isNameLike(i + 1) && sameLine(i + 1) && kind(i + 2) != .equal && kind(i + 2) != .colon
    }

    mutating func parseStyleDeclaration() -> SyntaxNode {
        let start = i
        var children: [SyntaxChild] = [take()]
        var head = "style"
        if isNameLike(i) && sameLine(i) {
            head += " " + tokens[i].text
            children.append(take())
        } else {
            children.append(missing(.identifier))
            expected(.styleName)
        }
        let saved = context
        context = .style
        if kind(i) == .lBrace {
            children.append(.node(parseBlock(owner: BlockOwner(head: head, statementStart: start))))
        } else {
            if children[1].token?.isMissing == false { expected(.openingBrace, insert: " { }") }
            children.append(.node(missingBlock()))
        }
        context = saved
        return node(.styleDecl, children)
    }

    mutating func parseComponentDeclaration() -> SyntaxNode {
        let start = i
        var children: [SyntaxChild] = [take(), take()]  // `component` and its name
        // Parameters.
        if kind(i) == .lParen && sameLine(i) {
            children.append(.node(parseParameterClause()))
        } else {
            expected(.openingParen, insert: "()")
            children.append(.node(node(.parameterClause, [missing(.lParen), missing(.rParen)])))
        }
        let saved = context
        context = .component
        if kind(i) == .lBrace {
            children.append(.node(parseBlock(owner: BlockOwner(head: "component", statementStart: start))))
        } else {
            expected(.openingBrace, insert: " { }")
            children.append(.node(missingBlock()))
        }
        context = saved
        return node(.componentDecl, children)
    }

    /// `( name: Type = default, … )` of a reserved `component` declaration.
    mutating func parseParameterClause() -> SyntaxNode {
        let open = i
        var children: [SyntaxChild] = [take()]
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var expectComma = false
        while true {
            let k = kind(i)
            if k == .rParen { children.append(take()); break }
            if i >= limit || k == .lBrace || k == .rBrace {
                children.append(missing(.rParen))
                report(.unclosedParen, .error, textRange(open), ["line": .number(lineNumber(ofToken: open))],
                       fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code(")")],
                                      edits: [edit(insertionPoint..<insertionPoint, ")")])])
                break
            }
            if k == .comma {
                if expectComma { children.append(take()); expectComma = false } else { children.append(.node(strayToken())) }
                continue
            }
            guard isNameLike(i) else {
                children.append(.node(unexpectedInBrackets()))
                continue
            }
            if expectComma {
                children.append(missing(.comma))
                report(.missingComma, .error, textRange(i),
                       fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code(",")],
                                      edits: [edit(insertionPoint..<insertionPoint, ",")])])
            }
            var parameter: [SyntaxChild] = [take()]
            if kind(i) == .colon {
                parameter.append(take())
                if isNameLike(i) { parameter.append(take()) } else { parameter.append(missing(.identifier)); expected(.name) }
            }
            if kind(i) == .equal {
                parameter.append(take())
                parameter.append(.node(parseRequiredExpression(.expression)))
            }
            children.append(.node(node(.parameter, parameter)))
            expectComma = true
        }
        return node(.parameterClause, children)
    }

    // MARK: Declarations

    mutating func parseDeclaration() -> SyntaxNode {
        var children: [SyntaxChild] = [takeKeyword()]
        var reported = false
        if isNameLike(i) && sameLine(i) {
            children.append(take())
        } else {
            children.append(missing(.identifier))
            expected(.declarationName)
            reported = true
        }
        // A Swift or TypeScript type annotation (`variable x: Int = 0`): Desk has no type annotations.
        if kind(i) == .colon && sameLine(i) {
            let first = i
            var skipped: [SyntaxChild] = []
            while i < limit && sameLine(i) && kind(i) != .equal && kind(i) != .lBrace { skipped.append(take()) }
            children.append(.node(node(.unexpected, skipped)))
            if !reported {
                report(.unexpected, .error, starts[first]..<textEnd(i - 1), ["text": .code(text(first, i - 1))],
                       fixIts: [FixIt(titleKey: "remove", edits: [edit(textEnd(first - 1)..<textEnd(i - 1), "")])])
                reported = true
            }
        }
        if kind(i) == .equal && sameLine(i) {
            children.append(take())
            let value = parseExpr()
            if value.isMissing && !reported { expected(.expression) }
            children.append(.node(value.node))
        } else {
            children.append(missing(.equal))
            if !reported { expected(.equals, insert: " =") }
            // A value written without `=` (`variable page 0`) still belongs to the declaration.
            if sameLine(i) && startsExpression(i) {
                children.append(.node(parseExpr().node))
            } else {
                children.append(.node(missingExpression()))
            }
        }
        return node(.declaration, children)
    }

    // MARK: Control flow

    mutating func parseIf(allowModifiers: Bool) -> SyntaxNode {
        let start = i
        var children: [SyntaxChild] = [takeKeyword()]
        if kind(i) == .lBrace || !startsExpression(i) {
            children.append(.node(missingExpression()))
            expected(.condition)
        } else {
            children.append(.node(parseExpr(condition: true).node))
        }
        children.append(.node(parseRequiredBlock(head: "if", statementStart: start)))
        if isKeyword(i, .elseKeyword) {
            let elseIndex = i
            var elseChildren: [SyntaxChild] = [takeKeyword()]
            if isKeyword(i, .ifKeyword) && sameLine(i) {
                if blockDepth >= SyntaxLimits.maxBlockDepth {
                    reportDepth(at: i)
                    elseChildren.append(.node(skipIfChain()))
                } else {
                    blockDepth += 1
                    elseChildren.append(.node(parseIf(allowModifiers: false)))
                    blockDepth -= 1
                }
            } else {
                elseChildren.append(.node(parseRequiredBlock(head: "else", statementStart: elseIndex)))
            }
            children.append(.node(node(.elseClause, elseChildren)))
        }
        if allowModifiers { parseModifiers(into: &children) }
        return node(.ifStmt, children)
    }

    /// Past the depth limit, the rest of an `else if` chain is taken as tokens, without recursion.
    mutating func skipIfChain() -> SyntaxNode {
        var children: [SyntaxChild] = []
        while i < limit {
            let k = kind(i)
            if k == .lBrace {
                let close = braces.closes[i]
                children.append(take())
                let end: Int
                switch close {
                case .token(let j)?: end = min(j + 1, limit)
                case .virtual(let k)?: end = min(k, limit)
                case nil: end = limit
                }
                while i < end { children.append(take()) }
                if isKeyword(i, .elseKeyword) { children.append(take()); continue }
                break
            }
            if nl(i) && !children.isEmpty && k != .lBrace { break }
            children.append(take())
        }
        return node(.unexpected, children)
    }

    mutating func parseFor() -> SyntaxNode {
        let start = i
        var children: [SyntaxChild] = [takeKeyword()]
        var reported = false
        if isNameLike(i) && sameLine(i) && !isKeyword(i, .inKeyword) {
            children.append(take())
        } else {
            children.append(missing(.identifier))
            expected(.loopVariable)
            reported = true
        }
        if isKeyword(i, .inKeyword) {
            children.append(takeKeyword())
        } else {
            children.append(missing(.inKeyword))
            if !reported { expected(.inKeyword, insert: " in"); reported = true }
        }
        if kind(i) == .lBrace || !startsExpression(i) {
            children.append(.node(missingExpression()))
            if !reported { expected(.expression) }
        } else {
            children.append(.node(parseExpr().node))
        }
        children.append(.node(parseRequiredBlock(head: "for", statementStart: start)))
        parseModifiers(into: &children)
        return node(.forStmt, children)
    }

    /// An `else` with no `if` before it (DK2006); its block is parsed so its braces stay matched.
    mutating func parseStrayElse() -> SyntaxNode {
        let j = i
        report(.unexpected, .error, textRange(j), ["text": .code(tokens[j].text)])
        var children: [SyntaxChild] = [take()]
        if isKeyword(i, .ifKeyword) && sameLine(i) {
            children.append(.node(parseIf(allowModifiers: true)))
        } else if kind(i) == .lBrace {
            children.append(.node(parseBlock(owner: BlockOwner(head: "else", statementStart: j))))
        }
        return node(.unexpected, children)
    }

    mutating func parseRequiredBlock(head: String, statementStart: Int) -> SyntaxNode {
        if kind(i) == .lBrace {
            return parseBlock(owner: BlockOwner(head: head, statementStart: statementStart))
        }
        expected(.openingBrace, insert: " { }")
        return missingBlock()
    }

    // MARK: Blocks

    /// `{ body }`. The closing brace was found before parsing (counting first, indentation only to repair); a
    /// block left open ends where the repair put its virtual `}` (a missing token, DK2001 at the opener).
    mutating func parseBlock(owner: BlockOwner) -> SyntaxNode {
        let open = i
        var children: [SyntaxChild] = [take()]
        let close = braces.closes[open] ?? .virtual(before: limit)
        let savedLimit = limit
        var end: Int
        switch close {
        case .token(let j): end = j
        case .virtual(let k): end = k
        }
        end = max(i, min(end, savedLimit))
        if blockDepth >= SyntaxLimits.maxBlockDepth {
            reportDepth(at: open)
            var inner: [SyntaxChild] = []
            while i < end { inner.append(take()) }
            if !inner.isEmpty { children.append(.node(node(.unexpected, inner))) }
        } else {
            blockDepth += 1
            limit = end
            // The block of a stray top-level statement (`Row { … }` outside `widget`) holds ordinary statements:
            // only the file's own items are top-level items or stray.
            let savedContext = context
            if context == .topLevel { context = .other }
            parseBody(into: &children, owner: owner)
            context = savedContext
            limit = savedLimit
            blockDepth -= 1
        }
        if case .token(let j) = close, i == j, j < savedLimit {
            children.append(take())
        } else {
            children.append(missing(.rBrace))
            reportUnclosedBlock(open: open, owner: owner)
        }
        return node(.block, children)
    }

    mutating func reportUnclosedBlock(open: Int, owner: BlockOwner) {
        let indent = String(repeating: " ", count: indentation(ofToken: owner.statementStart))
        // The `}` goes on its own line after the last line of the block's content.
        let at = i > open + 1 ? fullEnd(i - 1) : fullEnd(open)
        let insertion = edit(at..<at, lines.newline + indent + "}")
        let line = lineNumber(ofToken: open)
        // "Jump to line {line}" has no edits: the editor moves to the opener, which is the diagnostic's range.
        report(.unclosedBlock, .error, textRange(open),
               ["opener": .code(owner.head + " {"), "line": .number(line)],
               fixIts: [FixIt(titleKey: "jumpToLine", titleArguments: ["line": .number(line)], edits: []),
                        FixIt(titleKey: "insert", titleArguments: ["text": .code("}")], edits: [insertion])])
    }

    mutating func reportDepth(at j: Int) {
        guard !depthReported else { return }
        depthReported = true
        report(.nestingTooDeep, .error, textRange(j), ["limit": .number(SyntaxLimits.maxBlockDepth)])
    }

    /// A `{` that nothing before it can take: after an assignment, a declaration, or a call that already has a
    /// block (DK2010), or at the start of a block (DK2006). The block is parsed so its content is not lost.
    mutating func parseStrayBlock(previous: (node: SyntaxNode, start: Int, end: Int)?) -> SyntaxNode {
        let open = i
        if let previous {
            report(.unexpectedBlock, .error, textRange(open), ["name": .code(head(of: previous.node))])
        } else {
            report(.unexpected, .error, textRange(open), ["text": .code("{")])
        }
        return node(.unexpected, [.node(parseBlock(owner: BlockOwner(head: "{", statementStart: open)))])
    }

    /// A `(` at the start of a statement: the arguments of a call on the previous line (DK2012, N7), or stray.
    mutating func parseStrayParentheses(previous: (node: SyntaxNode, start: Int, end: Int)?) -> SyntaxNode {
        let open = i
        if let previous, nl(open), let name = callableHead(of: previous.node) {
            report(.callOnNextLine, .error, textRange(open), ["name": .code(name)],
                   fixIts: [FixIt(titleKey: "joinLines", edits: [edit(textEnd(previous.end)..<starts[open], "")])])
        } else {
            report(.unexpected, .error, textRange(open), ["text": .code("(")])
        }
        return node(.unexpected, [.node(parseArgumentClause().node)])
    }

    /// The name a construct is known by in messages: the callee, the last modifier, the declared name…
    func head(of statement: SyntaxNode) -> String {
        switch statement.kind {
        case .callStmt, .modifierStmt:
            if let last = statement.children.last(where: { $0.node?.kind == .modifierApp })?.node {
                return "." + (last.children.dropFirst().first?.token?.text ?? "")
            }
            if let callee = statement.children.first?.node { return callee.trimmedText }
            return statement.firstToken?.text ?? ""
        case .declaration:
            return statement.children.dropFirst().first?.token?.text ?? ""
        case .assignment, .optionDecl:
            return statement.children.first?.node?.trimmedText ?? ""
        case .strayStatement:
            if let inner = statement.children.first?.node { return head(of: inner) }
            return ""
        default:
            return statement.firstToken?.text ?? ""
        }
    }

    /// For DK2012: the name of a call statement or modifier that could still take arguments.
    func callableHead(of statement: SyntaxNode) -> String? {
        var inner = statement
        if inner.kind == .strayStatement, let first = inner.children.first?.node { inner = first }
        switch inner.kind {
        case .callStmt, .modifierStmt:
            if let last = inner.children.last(where: { $0.node?.kind == .modifierApp })?.node {
                let hasArguments = last.children.contains { $0.node?.kind == .argumentClause || $0.node?.kind == .block }
                return hasArguments ? nil : "." + (last.children.dropFirst().first?.token?.text ?? "")
            }
            let hasArguments = inner.children.contains { $0.node?.kind == .argumentClause || $0.node?.kind == .block }
            guard !hasArguments, let callee = inner.children.first?.node else { return nil }
            return callee.trimmedText
        default:
            return nil
        }
    }

    // MARK: Calls, assignments, options

    /// A name path (`Text`, `music.next`, `options.accent`) followed by `=` (assignment or option declaration), a
    /// compound assignment (DK7004, DK7005), or the rest of a call statement.
    mutating func parseCallOrAssignment() -> SyntaxNode {
        let start = i
        var path: [SyntaxChild] = [take()]
        while kind(i) == .dot && sameLine(i) && isNameLike(i + 1) && sameLine(i + 1) {
            path.append(take())
            path.append(take())
        }
        let pathEnd = i - 1
        switch kind(i) {
        case .equal where sameLine(i):
            let target = node(.target, path)
            let equal = take()
            if context == .options {
                return node(.optionDecl, [.node(target), equal, .node(parseOptionControl())])
            }
            let value = parseExpr()
            if value.isMissing { expected(.expression) }
            return node(.assignment, [.node(target), equal, .node(value.node)])
        case .plusEqual, .minusEqual, .starEqual, .slashEqual:
            guard sameLine(i) else { break }
            let opIndex = i
            let target = node(.target, path)
            let op = take()
            let value = parseExpr()
            let name = text(start, pathEnd)
            let symbol = String(tokens[opIndex].text.dropLast())
            if value.isMissing {
                expected(.expression)
            } else {
                let valueText = text(value.start, value.end)
                let fixed = "\(name) = \(name) \(symbol) \(valueText)"
                report(.compoundAssignment, .error, textRange(opIndex),
                       ["name": .code(name), "op": .code(symbol), "value": .code(valueText)],
                       fixIts: [FixIt(titleKey: "rewrite", edits: [edit(starts[start]..<textEnd(value.end), fixed)])])
            }
            return node(.assignment, [.node(target), op, .node(value.node)])
        case .plusPlus, .minusMinus:
            guard sameLine(i) else { break }
            let opIndex = i
            let target = node(.target, path)
            let op = take()
            let name = text(start, pathEnd)
            let symbol = String(tokens[opIndex].text.prefix(1))
            report(.incrementOperator, .error, textRange(opIndex), ["name": .code(name), "op": .code(symbol)],
                   fixIts: [FixIt(titleKey: "rewrite",
                                  edits: [edit(starts[start]..<textEnd(opIndex), "\(name) = \(name) \(symbol) 1")])])
            return node(.assignment, [.node(target), op, .node(missingExpression())])
        default:
            break
        }
        return parseCallRest(callee: node(.callee, path), calleeStart: start)
    }

    /// Arguments, a block and modifiers after a callee (`CallStmt`).
    mutating func parseCallRest(callee: SyntaxNode, calleeStart: Int) -> SyntaxNode {
        var children: [SyntaxChild] = [.node(callee)]
        var hasArguments = false
        var hasBlock = false
        if kind(i) == .lParen && sameLine(i) {
            children.append(.node(parseArgumentClause().node))
            hasArguments = true
        }
        if kind(i) == .lBrace {
            children.append(.node(parseBlock(owner: BlockOwner(head: callee.trimmedText, statementStart: calleeStart))))
            hasBlock = true
        }
        let modifierCount = children.count
        parseModifiers(into: &children)
        // A bare component name (`Spacer`) needs its parentheses (DK2009) — unless they are on the next line, which
        // DK2012 reports.
        if !hasArguments && !hasBlock, callee.children.count == 1, let token = callee.children[0].token,
           token.kind == .identifier, token.isUpperName, !(kind(i) == .lParen && nl(i) && children.count == modifierCount) {
            let end = textEnd(calleeStart)
            report(.missingParens, .error, textRange(calleeStart), ["name": .code(token.text)],
                   fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("()")],
                                  edits: [edit(end..<end, "()")])])
        }
        return node(.callStmt, children)
    }

    /// The control of an option declaration: a call statement (`Toggle("Seconds").help("…")`), or any other value
    /// for the checker to report.
    mutating func parseOptionControl() -> SyntaxNode {
        if kind(i) == .identifier || kind(i) == .invalidIdentifier {
            let start = i
            var path: [SyntaxChild] = [take()]
            while kind(i) == .dot && sameLine(i) && isNameLike(i + 1) && sameLine(i + 1) {
                path.append(take())
                path.append(take())
            }
            return parseCallRest(callee: node(.callee, path), calleeStart: start)
        }
        let value = parseExpr()
        if value.isMissing { expected(.expression) }
        return value.node
    }

    // MARK: Modifiers

    mutating func parseModifierStatement() -> SyntaxNode {
        var children: [SyntaxChild] = []
        parseModifiers(into: &children)
        return node(.modifierStmt, children)
    }

    /// Modifiers after a call, a block or another modifier: on the same line or, after a line break, when the line
    /// starts with `.` (N3). Separators end a chain, since the body consumes them.
    mutating func parseModifiers(into children: inout [SyntaxChild]) {
        while kind(i) == .dot {
            children.append(.node(parseModifierApplication()))
        }
    }

    mutating func parseModifierApplication() -> SyntaxNode {
        let start = i
        var children: [SyntaxChild] = [take()]
        var name: String?
        if isNameLike(i) && sameLine(i) {
            name = tokens[i].text
            children.append(take())
        } else {
            children.append(missing(.identifier))
            expected(.memberName)
        }
        var hasArguments = false
        var ofArgument: ClosedRange<Int>?
        if kind(i) == .lParen && sameLine(i) {
            let clause = parseArgumentClause()
            children.append(.node(clause.node))
            ofArgument = clause.labeled["of"]
            hasArguments = true
        }
        var hasBlock = false
        if kind(i) == .lBrace {
            let owner = BlockOwner(head: "." + (name ?? ""), statementStart: start, modifierName: name,
                                   ofArgument: ofArgument)
            children.append(.node(parseBlock(owner: owner)))
            hasBlock = true
        }
        if let name, !hasArguments && !hasBlock && !(kind(i) == .lParen && nl(i)) {
            let end = textEnd(start + 1)
            report(.missingParens, .error, starts[start]..<end, ["name": .code("." + name)],
                   fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("()")],
                                  edits: [edit(end..<end, "()")])])
        }
        return node(.modifierApp, children)
    }

    // MARK: Fields, entries, groups

    mutating func parseField(missingColon: Bool) -> SyntaxNode {
        let labelIndex = i
        var children: [SyntaxChild] = [.node(node(.label, [take()]))]
        if missingColon {
            children.append(missing(.colon))
            let end = textEnd(labelIndex)
            report(.missingColon, .error, textRange(labelIndex), ["label": .code(tokens[labelIndex].text)],
                   fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code(":")],
                                  edits: [edit(end..<end, ":")])])
        } else {
            children.append(take())
        }
        let value = parseExpr()
        if value.isMissing && !missingColon { expected(.expression) }
        children.append(.node(value.node))
        return node(.field, children)
    }

    /// A statement that starts with text: a translation entry (`"CPU": "处理器"`), a language group
    /// (`"zh-Hans" { … }`), or text that belongs nowhere.
    mutating func parseStringStatement() -> SyntaxNode {
        let start = i
        let tag = parseStringLiteral()
        switch kind(i) {
        case .lBrace:
            return node(.group, [.node(tag.node), .node(parseBlock(owner: BlockOwner(head: text(start, tag.end), statementStart: start)))])
        case .colon where sameLine(i):
            if kind(i + 1) == .lBrace {
                let colon = take()
                let block = parseBlock(owner: BlockOwner(head: text(start, tag.end), statementStart: start))
                return node(.group, [.node(tag.node), colon, .node(block)])
            }
            let separator = take()
            let value = parseExpr()
            if value.isMissing { expected(.expression) }
            return node(.entry, [.node(tag.node), separator, .node(value.node)])
        case .equal where sameLine(i):
            let separator = take()
            let value = parseExpr()
            if value.isMissing { expected(.expression) }
            return node(.entry, [.node(tag.node), separator, .node(value.node)])
        default:
            report(.unexpected, .error, starts[start]..<textEnd(tag.end), ["text": .code(shortText(start))])
            return node(.unexpected, [.node(tag.node)])
        }
    }
}
