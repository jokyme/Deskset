import Foundation

// Where the cursor is, for completion: which kind of thing may be written there (a block, a field, an element, an
// action, a modifier, a member, a value of some type, an argument label, a unit, a name, a path, a translation), what
// is already typed, and the range an accepted item replaces. Worked out from the token before the cursor and the
// nodes around it, so it works on code that does not parse: the parser's recovery may glue the lines after the
// cursor to the construct being typed, but never changes what came before it.

/// What may be written at the cursor.
public enum DeskCompletionPlace: String, Sendable, Hashable, CaseIterable {
    /// Nothing: inside a comment, a number's digits, ordinary text, or after a complete expression on the same line.
    case none
    /// A top-level block of a widget file or `package.desk`.
    case topLevel
    /// A field of `info { }` or `package { }` not yet written.
    case fields
    /// A line of `options { }` or of a `Section`.
    case optionItems
    /// The control after `name =` in `options { }`.
    case control
    /// A statement among elements (or menu entries).
    case views
    /// A statement in an event or timing block.
    case actions
    /// A modifier: after `.` on an element, in a style, or in a `.hover` or `.pressed` body.
    case modifiers
    /// A member after `x.`.
    case member
    /// An implicit member (`.caption`) of the type expected there.
    case implicitMember
    /// A value: own names, data, functions and choices of the expected type.
    case value
    /// The start of an argument: the labels still open, and values when a value without a label may go there.
    case argument
    /// A unit after a number.
    case unit
    /// One of the author's styles, in `.style(…)`.
    case styleName
    /// A named element: `show`, `hide` and `showOrHide`.
    case elementName
    /// A format option after `,` in an interpolation.
    case formatOption
    /// A picture of the widget's folder.
    case imagePath
    /// A font family.
    case fontFamily
    /// An SF Symbol name.
    case symbolName
    /// A text of the file not yet translated in a language block.
    case translationKey
    /// A language tag of `translations { }`.
    case languageTag
}

/// Where a modifier is written.
public enum DeskModifierSite: String, Sendable, Hashable {
    /// On an element (or, with no element before it, as a stray chain).
    case element
    /// In a `style` body.
    case style
    /// In a `.hover` or `.pressed` body.
    case state
    /// On an option control in `options { }`.
    case option
}

/// What a member access reads from.
public enum DeskMemberBase: Sendable, Hashable {
    /// A data or action namespace (`cpu`, `audio.microphone`), or `options`.
    case namespace(String)
    /// A value of a type (a record, a list, text, a date).
    case value(DeskType)
    /// A named element: its geometry in a Freeform.
    case element(String)
}

/// The completion context at a position.
public struct DeskCompletionContext: Sendable, Hashable, CustomStringConvertible {
    public var place: DeskCompletionPlace
    /// What is typed before the cursor that the items complete (the word, a unit, a string's text).
    public var prefix: String
    /// The range an accepted item replaces: the whole word, unit or string text around the cursor, or an empty range
    /// at the cursor.
    public var range: DeskRange
    /// The type a value written here should have, when known (a unit's dimension, a string's kind).
    public var expectedType: DeskType?
    /// For modifiers: where they are written, and the kind of the element they apply to (nil: any element).
    public var modifierSite: DeskModifierSite?
    public var elementKind: ElementKind?
    /// For members: what they are read from.
    public var memberBase: DeskMemberBase?
    /// The open file is `package.desk`.
    public var isPackage: Bool
    /// Among menu entries (`.menu { }`, `Menu { }`).
    public var inMenu: Bool
    /// Declarations may be written here (the widget body before its first element).
    public var allowsDeclarations: Bool
    /// Inside an action block (a statement or a value of one).
    public var inActions: Bool
    /// Inside the action block of the user's own event (a click, a menu item): actions that only the user may start
    /// are allowed.
    public var userInitiated: Bool
    /// For translation keys: the language block's tag.
    public var language: String?

    public init(place: DeskCompletionPlace, prefix: String, range: DeskRange, expectedType: DeskType? = nil,
                modifierSite: DeskModifierSite? = nil, elementKind: ElementKind? = nil, memberBase: DeskMemberBase? = nil,
                isPackage: Bool = false, inMenu: Bool = false, allowsDeclarations: Bool = false, inActions: Bool = false,
                userInitiated: Bool = false, language: String? = nil) {
        self.place = place
        self.prefix = prefix
        self.range = range
        self.expectedType = expectedType
        self.modifierSite = modifierSite
        self.elementKind = elementKind
        self.memberBase = memberBase
        self.isPackage = isPackage
        self.inMenu = inMenu
        self.allowsDeclarations = allowsDeclarations
        self.inActions = inActions
        self.userInitiated = userInitiated
        self.language = language
    }

    /// `modifiers(style) "fo" expected Length`, for tests and logs.
    public var description: String {
        var out = place.rawValue
        if let modifierSite { out += "(\(modifierSite.rawValue)\(elementKind.map { " " + $0.rawValue } ?? ""))" }
        if let memberBase {
            switch memberBase {
            case .namespace(let n): out += "(\(n))"
            case .value(let t): out += "(\(t))"
            case .element(let n): out += "(element \(n))"
            }
        }
        if let expectedType { out += " expected \(expectedType)" }
        if inActions { out += userInitiated ? " in user actions" : " in actions" }
        if inMenu { out += " in menu" }
        if allowsDeclarations { out += " declarations" }
        if let language { out += " language \(language)" }
        return out + " \"\(prefix)\""
    }
}

/// The tokens of a tree in document order (missing ones included), each with where it is and the node it belongs
/// to: completion looks at the token before the cursor.
struct DeskTokenTable: Sendable {
    struct Entry: Sendable {
        let token: Token
        /// Where its leading trivia starts.
        let offset: Int
        /// The index of the node it is a child of in the node table.
        let parent: Int
        /// Where its text starts and ends, measured once (the last token's trivia may hold thousands of comment lines).
        let textStart: Int
        let textEnd: Int

        init(token: Token, offset: Int, parent: Int) {
            self.token = token
            self.offset = offset
            self.parent = parent
            textStart = offset + token.leadingTrivia.utf8Length
            textEnd = textStart + token.text.utf8.count
        }

        var kind: TokenKind { token.kind }
        var isPresent: Bool { !token.isMissing && token.kind != .eof }
    }

    let entries: [Entry]

    init(table: DeskNodeTable) {
        var out: [Entry] = []
        guard !table.entries.isEmpty else {
            entries = []
            return
        }
        var stack: [(e: Int, k: Int, offset: Int, nextChild: Int)] = [(0, 0, table.entries[0].offset, 1)]
        while var top = stack.popLast() {
            let node = table.entries[top.e].node
            guard top.k < node.children.count else { continue }
            let child = node.children[top.k]
            top.k += 1
            switch child {
            case .token(let token):
                let entry = Entry(token: token, offset: top.offset, parent: top.e)
                out.append(entry)
                top.offset = entry.textEnd + token.trailingTrivia.utf8Length
                stack.append(top)
            case .node(let n):
                let childEntry = top.nextChild
                guard childEntry < table.entries.count else { continue }
                top.nextChild = table.entries[childEntry].end
                top.offset += n.byteLength
                stack.append(top)
                stack.append((childEntry, 0, table.entries[childEntry].offset, childEntry + 1))
            }
        }
        entries = out
    }

    /// The index of the last token whose text starts before `offset` (or at it, when `inclusive`).
    func lastStarting(before offset: Int, inclusive: Bool = false) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            let start = entries[mid].textStart
            if start < offset || (inclusive && start == offset) { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The last present token whose text ends at or before `offset`.
    func previousPresent(endingAtOrBefore offset: Int) -> Int? {
        guard var i = lastStarting(before: offset, inclusive: true) else { return nil }
        while i >= 0 {
            let e = entries[i]
            if e.isPresent, e.textEnd <= offset { return i }
            i -= 1
        }
        return nil
    }
}

/// What completion needs besides the public context: the call the cursor is in, the labels still open, the
/// element a modifier goes on, and how the item text is to be written.
struct DeskCompletionScan {
    var context: DeskCompletionContext
    /// UTF-8 range an item replaces.
    var utf8Range: Range<Int>
    /// The call whose parentheses hold the cursor (arguments, labels, format options).
    var callSite: DeskCallSite?
    var argumentIndex = 0
    /// Only labels may be written here (a label being edited, or a labelled argument came before).
    var labelsOnly = false
    /// A value without a label may be written here (a positional parameter is still open).
    var allowsPositionalValue = false
    /// The `.` is already written: modifiers and choices are inserted without it.
    var dotTyped = false
    /// The modifiers already written on the element (or in the body).
    var presentModifiers: [String] = []
    /// A `(` or `{` follows the word: insert the name only.
    var followedByCall = false
    /// Names of the siblings in the same Freeform, for `.position(x: …)` and sizes.
    var geometrySiblings: [String] = []
    /// A member written as a statement (`music.play()` in an action block, `options.x = …`): actions and settable
    /// data are offered.
    var memberStatement = false
    /// The node index of the element a modifier goes on.
    var modifierOwner: Int?
    /// The indentation of the cursor's line (block snippets are indented from it).
    var indentation = ""
    /// The type of the interpolated value, for format options.
    var formatValueType: DeskType?
    /// The block holding a statement context.
    var block: Int?
    /// The value is shown as text (a `Text`'s content, an interpolation): a list can't go there.
    var displaySlot = false
}

extension DeskSnapshot {
    /// Every token of the open file with its position, built once.
    var tokenTable: DeskTokenTable {
        caches.tokenTable.value { DeskTokenTable(table: nodeTable) }
    }

    /// The completion context at a position: what may be written there, what is typed, and what an item replaces.
    public func completionContext(at position: DeskPosition) -> DeskCompletionContext {
        guard hasStackRoom else { return onLargeStack { completionContext(at: position) } }
        if let closed = closingInterpolation(at: position) {
            var context = closed.snapshot.scanCompletion(at: position).context
            context.range = closed.back(context.range)
            return context
        }
        return scanCompletion(at: position).context
    }

    /// A copy of the snapshot with `}` written at the cursor, and how to bring its ranges back to this text.
    struct ClosedInterpolation {
        let snapshot: DeskSnapshot
        let index: DeskTextIndex
        /// The cursor, in UTF-16 units: the copy has one more unit after it.
        let cursor: Int

        func back(_ range: DeskRange) -> DeskRange {
            func map(_ p: DeskPosition) -> DeskPosition { index.position(utf16: p.offset > cursor ? p.offset - 1 : p.offset) }
            return DeskRange(start: map(range.start), end: map(range.end))
        }
    }

    /// The cursor is in an interpolation whose `}` is not typed yet (`Text("{cpu.|")`): the lexer made the rest of the
    /// string text, so completion asks a copy of the snapshot with the `}` written at the cursor, as the editor's
    /// text will have it once it is typed.
    func closingInterpolation(at position: DeskPosition) -> ClosedInterpolation? {
        let utf16 = index.clampedUTF16(position.offset)
        let offset = index.utf8Offset(ofUTF16: utf16)
        let tokens = tokenTable
        guard var i = tokens.lastStarting(before: offset) else { return nil }
        while i > 0, !tokens.entries[i].isPresent, tokens.entries[i].kind != .eof { i -= 1 }
        let e = tokens.entries[i]
        guard e.kind == .stringText, e.isPresent, e.textStart < offset,
              offset <= e.textEnd || e.token.flags.contains(.unterminated) else { return nil }
        let bytes = index.bytes
        let open = tree.diagnostics.last {
            $0.id == .unterminatedInterpolation && $0.range.lowerBound >= e.textStart && $0.range.lowerBound < offset
        }
        guard let open, open.range.lowerBound + 1 <= offset, offset <= bytes.count,
              !bytes[(open.range.lowerBound + 1)..<offset].contains(where: { $0 == 0x7D || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D })
        else { return nil }
        var closedBytes = bytes
        closedBytes.insert(0x7D, at: offset)
        let text = String(decoding: closedBytes, as: UTF8.self)
        let closedTree = Desk.parse(text, file: file)
        let packageContext = isPackage ? nil : package.map { CheckedPackage(file: $0) }
        let closedChecked = isChecked
            ? Desk.check(closedTree, context: options.checkContext(package: packageContext, resources: resources))
            : CheckedFile(syntaxOf: closedTree, context: options.checkContext(package: packageContext, resources: resources))
        let closedIndex = DeskTextIndex(tree: closedTree)
        var closedFolder = folder
        closedFolder[file] = text
        let copy = DeskSnapshot(version: version, generation: generation, file: file, tree: closedTree, checked: closedChecked,
                                index: closedIndex, options: options, packageFile: packageFile,
                                package: isPackage ? closedChecked : package, packageIndex: isPackage ? closedIndex : packageIndex,
                                folder: closedFolder, resources: resources, model: model, isChecked: isChecked)
        return ClosedInterpolation(snapshot: copy, index: index, cursor: utf16)
    }

    // MARK: Scanning

    func scanCompletion(at position: DeskPosition) -> DeskCompletionScan {
        let offset = index.utf8Offset(ofUTF16: index.clampedUTF16(position.offset))
        let tokens = tokenTable
        var scan = DeskCompletionScan(context: DeskCompletionContext(place: .none, prefix: "", range: range(offset..<offset),
                                                                     isPackage: isPackage),
                                      utf8Range: offset..<offset)
        scan.indentation = lineIndentation(at: offset)
        guard !tokens.entries.isEmpty else {
            scan.context.place = .topLevel
            return scan
        }
        if isInComment(offset, tokens) { return scan }

        // The token the cursor is in, or right after.
        var word: DeskTokenTable.Entry?
        var wordIndex: Int?
        if var i = tokens.lastStarting(before: offset) {
            // Missing tokens take no room: look past them.
            while i > 0, !tokens.entries[i].isPresent, tokens.entries[i].kind != .eof { i -= 1 }
            let e = tokens.entries[i]
            if e.isPresent, e.textStart < offset, offset <= e.textEnd || (e.kind == .stringText && e.token.flags.contains(.unterminated)) {
                word = e
                wordIndex = i
            }
        }
        if let w = word, let wi = wordIndex {
            switch w.kind {
            case .stringText:
                return scanString(offset: offset, tokenIndex: wi, scan)
            case .stringStart, .stringEnd, .rawString, .tripleQuoteString:
                if w.kind == .stringStart, offset == w.textEnd { return scanString(offset: offset, tokenIndex: wi, scan) }
                if w.kind == .stringEnd, offset == w.textEnd { break }
                if w.kind == .rawString { return scan }
                return scanString(offset: offset, tokenIndex: wi, scan)
            case .number:
                return scanUnit(offset: offset, token: w, scan)
            default:
                if w.kind.isWord || w.kind == .invalidIdentifier {
                    // A word being typed: it is replaced as a whole.
                    var s = scan
                    s.utf8Range = w.textStart..<w.textEnd
                    s.context.prefix = String(decoding: index.bytes[w.textStart..<offset], as: UTF8.self)
                    s.context.range = range(s.utf8Range)
                    s.followedByCall = followedByCall(after: w.textEnd)
                    return classify(before: w.textStart, offset: offset, word: wi, s)
                }
                if offset < w.textEnd { return scan }
            }
        }
        // Between tokens, or right after punctuation.
        if let i = tokens.lastStarting(before: offset), tokens.entries[i].kind == .stringStart,
           tokens.entries[i].textEnd == offset {
            return scanString(offset: offset, tokenIndex: i, scan)
        }
        return classify(before: offset, offset: offset, word: nil, scan)
    }

    /// The UTF-8 range as a service range.
    func range(_ r: Range<Int>) -> DeskRange { index.range(utf8: r) }

    private func lineIndentation(at offset: Int) -> String {
        let bytes = index.bytes
        var start = min(offset, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A, bytes[start - 1] != 0x0D { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func followedByCall(after end: Int) -> Bool {
        let bytes = index.bytes
        var i = end
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        guard i < bytes.count else { return false }
        return bytes[i] == 0x28 || (bytes[i] == 0x7B && i == end)
    }

    /// Whether the offset is inside a comment of the trivia around it (a line comment up to its end).
    private func isInComment(_ offset: Int, _ tokens: DeskTokenTable) -> Bool {
        guard let i = tokens.lastStarting(before: offset, inclusive: true) else {
            return triviaComment(tokens.entries[0].token.leadingTrivia, from: tokens.entries[0].offset, contains: offset)
        }
        let e = tokens.entries[i]
        if offset >= e.textStart, offset <= e.textEnd, e.textStart < e.textEnd || e.textStart == offset {
            // In the token's text; a comment may still start right at its end.
            if offset < e.textEnd { return false }
        }
        if triviaComment(e.token.leadingTrivia, from: e.offset, contains: offset) { return true }
        if triviaComment(e.token.trailingTrivia, from: e.textEnd, contains: offset) { return true }
        if i + 1 < tokens.entries.count {
            let next = tokens.entries[i + 1]
            if triviaComment(next.token.leadingTrivia, from: next.offset, contains: offset) { return true }
        }
        return false
    }

    private func triviaComment(_ trivia: [Trivia], from start: Int, contains offset: Int) -> Bool {
        var at = start
        for piece in trivia {
            let end = at + piece.utf8Length
            switch piece {
            case .lineComment:
                if offset > at, offset <= end { return true }
            case .blockComment(let text):
                let closed = text.hasSuffix("*/") && text.utf8.count >= 4
                if offset > at, offset < end || (!closed && offset == end) { return true }
            default:
                break
            }
            at = end
        }
        return false
    }

    // MARK: Strings and numbers

    private func scanString(offset: Int, tokenIndex: Int, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let tokens = tokenTable
        let table = nodeTable
        let e = tokens.entries[tokenIndex]
        // The string literal and the piece of text the cursor is in.
        var literal = e.parent
        while literal >= 0, table.entries[literal].kind != .stringLiteral { literal = table.entries[literal].parent }
        guard literal >= 0 else { return s }
        var text = offset..<offset
        if e.kind == .stringText {
            text = e.textStart..<max(e.textEnd, offset)
        } else if e.kind == .stringStart, tokenIndex + 1 < tokens.entries.count, tokens.entries[tokenIndex + 1].kind == .stringText {
            let next = tokens.entries[tokenIndex + 1]
            if next.textStart == offset { text = next.textStart..<next.textEnd }
        }
        // Only a string that is text alone names a path, a family, a key or a tag.
        let literalTokens = table.entries[literal].positioned.childTokens
        let hasInterpolation = table.children(of: literal).contains { table.entries[$0].kind == .interpolation }
        guard !hasInterpolation, literalTokens.first?.kind == .stringStart else { return s }
        s.utf8Range = text
        s.context.range = range(text)
        s.context.prefix = String(decoding: index.bytes[text.lowerBound..<offset], as: UTF8.self)
        let parent = table.entries[literal].parent
        guard parent >= 0 else { return s }
        switch table.entries[parent].kind {
        case .group:
            if table.children(of: parent).first == literal {
                s.context.place = .languageTag
            }
            return s
        case .entry:
            if table.children(of: parent).first == literal, let language = languageOfGroup(containing: parent) {
                s.context.place = .translationKey
                s.context.language = language
            }
            return s
        case .block:
            // A language tag being written as a group's start, or a key as an entry's start.
            let owner = table.entries[parent].parent
            if owner >= 0, table.entries[owner].kind == .translationsBlock { s.context.place = .languageTag }
            if owner >= 0, table.entries[owner].kind == .group, let language = languageOfGroup(containing: parent) {
                s.context.place = .translationKey
                s.context.language = language
            }
            return s
        case .unexpected:
            let owner = table.entries[parent].parent
            if owner >= 0, table.entries[owner].kind == .block {
                let top = table.entries[owner].parent
                if top >= 0, table.entries[top].kind == .translationsBlock { s.context.place = .languageTag }
                if top >= 0, table.entries[top].kind == .group, let language = languageOfGroup(containing: owner) {
                    s.context.place = .translationKey
                    s.context.language = language
                }
            }
            return s
        default:
            break
        }
        let expected = expectedType(forSlotOf: literal, offset: offset)
        guard let expected else { return s }
        let components = expected.components
        if components.contains(.imageSource) {
            s.context.place = .imagePath
        } else if components.contains(.fontFamily) {
            s.context.place = .fontFamily
        } else if components.contains(.symbolName) {
            s.context.place = .symbolName
        } else if components.contains(.elementName) {
            s.context.place = .elementName
        }
        s.context.expectedType = expected
        return s
    }

    /// The normalized tag of the language block holding a node.
    private func languageOfGroup(containing i: Int) -> String? {
        let table = nodeTable
        for a in [i] + table.ancestors(of: i) where table.entries[a].kind == .group {
            guard let tag = table.children(of: a).first, table.entries[tag].kind == .stringLiteral,
                  let value = StringLiteralSyntax(unchecked: table.entries[tag].positioned).literalValue else { return nil }
            return DeskLocalization.normalize(value)
        }
        return nil
    }

    private func scanUnit(offset: Int, token: DeskTokenTable.Entry, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let digits = token.token.numberText.utf8.count
        let unitStart = token.textStart + digits
        guard digits > 0, offset >= unitStart, !token.token.flags.contains(.leadingDot) || digits > 1 else { return s }
        // `10 %` is a remainder, `10%` a percentage: a unit follows the digits directly.
        s.utf8Range = unitStart..<token.textEnd
        s.context.range = range(s.utf8Range)
        s.context.prefix = String(decoding: index.bytes[unitStart..<offset], as: UTF8.self)
        s.context.place = .unit
        let table = nodeTable
        var node = token.parent
        while node >= 0, table.entries[node].kind != .numberLiteral { node = table.entries[node].parent }
        if node >= 0 {
            // A negative number's slot is the prefix expression's.
            var slot = node
            if table.entries[slot].parent >= 0, table.entries[table.entries[slot].parent].kind == .prefixExpr {
                slot = table.entries[slot].parent
            }
            s.context.expectedType = expectedType(forSlotOf: slot, offset: offset)
        }
        return s
    }

    // MARK: Classification

    /// Classifies a position from the token before `start` (the word's start, or the cursor).
    private func classify(before start: Int, offset: Int, word: Int?, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let tokens = tokenTable
        let table = nodeTable
        guard let p = tokens.previousPresent(endingAtOrBefore: start) else {
            s.context.place = .topLevel
            return s
        }
        let prev = tokens.entries[p]
        let parent = prev.parent
        let parentKind = parent >= 0 ? table.entries[parent].kind : .sourceFile
        let lineBreak = index.bytes[min(prev.textEnd, start)..<start].contains { $0 == 0x0A || $0 == 0x0D }

        switch prev.kind {
        case .dot:
            s.dotTyped = true
            return classifyAfterDot(dotIndex: p, offset: offset, s)
        case .lBrace:
            if parentKind == .block { return statementStart(block: parent, offset: offset, s) }
            return s
        case .semicolon:
            if parentKind == .block { return statementStart(block: parent, offset: offset, s) }
            return statementStartAfter(p, offset: offset, s)
        case .comma:
            switch parentKind {
            case .block:
                return statementStart(block: parent, offset: offset, s)
            case .argumentClause:
                return argumentStart(offset: offset, word: word, s)
            case .listLiteral:
                return valueSlot(parent: parent, offset: offset, s)
            case .formatOption, .interpolation:
                return formatOptionStart(offset: offset, word: word, s)
            default:
                return s
            }
        case .lParen:
            if parentKind == .argumentClause { return argumentStart(offset: offset, word: word, s) }
            if parentKind == .parenExpr { return valueSlot(parent: parent, offset: offset, s) }
            return s
        case .lBracket:
            if parentKind == .listLiteral { return valueSlot(parent: parent, offset: offset, s) }
            return s
        case .colon:
            switch parentKind {
            case .argument, .field, .formatOption, .ternaryExpr:
                return valueSlot(parent: parent, offset: offset, s)
            default:
                return s
            }
        case .equal:
            switch parentKind {
            case .optionDecl:
                s.context.place = .control
                return s
            case .assignment, .declaration:
                return valueSlot(parent: parent, offset: offset, s)
            default:
                return s
            }
        case .interpolationStart:
            return valueSlot(parent: parent, offset: offset, s)
        case .equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual, .andKeyword, .orKeyword, .notKeyword,
             .plus, .minus, .star, .slash, .percent, .ellipsis, .question, .ifKeyword, .inKeyword:
            return valueSlot(parent: parent, offset: offset, s)
        default:
            if lineBreak { return statementStartAfter(p, offset: offset, s) }
            return s
        }
    }

    /// A statement starts after token `p` and a line break: in the innermost block around `p` still open at the
    /// cursor, or at the top level.
    private func statementStartAfter(_ p: Int, offset: Int, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        let table = nodeTable
        let tokens = tokenTable
        var node = tokens.entries[p].parent
        while node >= 0 {
            let entry = table.entries[node]
            if entry.kind == .block {
                let close = entry.positioned.childTokens.last
                if let close, close.kind == .rBrace, !close.token.isMissing, close.textStart < offset {
                    // Closed before the cursor.
                } else if let close, close.kind == .rBrace, close.token.isMissing, close.textStart < offset,
                          close.textStart > tokens.entries[p].textStart,
                          let next = tokens.lastStarting(before: offset).map({ $0 }), tokens.entries[next].textStart > close.textStart,
                          tokens.entries[next].isPresent {
                    // Left open, and repaired before a statement that comes before the cursor.
                } else {
                    return statementStart(block: node, offset: offset, scan)
                }
            }
            node = entry.parent
        }
        var s = scan
        s.context.place = .topLevel
        return s
    }

    /// A statement starts in a block: its kind decides what may be written.
    private func statementStart(block: Int, offset: Int, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        s.block = block
        let table = nodeTable
        let catalog = options.catalog
        let owner = table.entries[block].parent
        guard owner >= 0 else {
            s.context.place = .topLevel
            return s
        }
        switch table.entries[owner].kind {
        case .widgetBlock:
            s.context.place = .views
            s.context.allowsDeclarations = !table.children(of: block).contains { c in
                let e = table.entries[c]
                return e.textEnd <= offset && e.kind != .declaration && e.kind != .unexpected && e.kind != .foreignConstruct
            }
        case .infoBlock, .packageBlock:
            s.context.place = .fields
        case .optionsBlock:
            s.context.place = .optionItems
        case .styleDecl:
            s.context.place = .modifiers
            s.context.modifierSite = .style
            s.presentModifiers = modifierNames(inBlock: block)
        case .translationsBlock:
            s.context.place = .languageTag
        case .group:
            s.context.place = .translationKey
            s.context.language = languageOfGroup(containing: block)
        case .componentDecl:
            s.context.place = .views
        case .ifStmt, .elseClause, .forStmt:
            // The same kind as the block the `if` or `for` is in.
            var statement = owner
            while statement >= 0, table.entries[statement].kind != .ifStmt, table.entries[statement].kind != .forStmt {
                statement = table.entries[statement].parent
            }
            var outer = statement >= 0 ? table.entries[statement].parent : -1
            while outer >= 0, table.entries[outer].kind != .block { outer = table.entries[outer].parent }
            guard outer >= 0 else {
                s.context.place = .views
                return s
            }
            var inner = statementStart(block: outer, offset: offset, s)
            inner.block = block
            inner.context.allowsDeclarations = false
            return inner
        case .callStmt:
            let name = table.entries[owner].positioned.firstChild(.callee)?.childTokens.first?.token.name ?? ""
            let inOptions = table.ancestors(of: owner).contains { table.entries[$0].kind == .optionsBlock }
            if inOptions, let control = catalog.control(named: name), control.block == .optionItems {
                s.context.place = .optionItems
            } else if let component = catalog.component(named: name) {
                switch component.block {
                case .menuItems:
                    s.context.place = .views
                    s.context.inMenu = true
                default:
                    s.context.place = .views
                    s.context.inMenu = inMenuBlock(owner)
                }
            } else if let function = catalog.function(named: name), function.takesActionBlock {
                s.context.place = .actions
                s.context.inActions = true
                s.context.userInitiated = enclosingActionIsUser(owner)
            } else {
                return guessedBlock(block: block, owner: owner, offset: offset, s)
            }
        case .modifierApp:
            let tokens = table.entries[owner].positioned.childTokens
            let name = tokens.count >= 2 ? tokens[1].token.name : ""
            guard let spec = catalog.modifier(named: name) else {
                return guessedBlock(block: block, owner: owner, offset: offset, s)
            }
            switch spec.block {
            case .actions:
                s.context.place = .actions
                s.context.inActions = true
                s.context.userInitiated = spec.event?.userInitiated ?? false
            case .modifiers:
                s.context.place = .modifiers
                s.context.modifierSite = .state
                s.presentModifiers = modifierNames(inBlock: block)
                if let element = elementOwning(modifier: owner) {
                    s.modifierOwner = element
                    s.context.elementKind = elementKind(of: element)
                }
            case .menuItems:
                s.context.place = .views
                s.context.inMenu = true
            default:
                return guessedBlock(block: block, owner: owner, offset: offset, s)
            }
        default:
            s.context.place = .views
        }
        return s
    }

    /// The block of an unknown component or modifier: guessed from what it holds, as the checker does.
    private func guessedBlock(block: Int, owner: Int, offset: Int, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let table = nodeTable
        let statements = table.children(of: block).filter { table.entries[$0].kind.isStatement }
        if statements.contains(where: { table.entries[$0].kind == .modifierStmt }) {
            s.context.place = .modifiers
            s.context.modifierSite = .state
        } else if statements.contains(where: { i in
            guard table.entries[i].kind == .callStmt else { return false }
            return table.entries[i].positioned.firstChild(.callee)?.childTokens.first?.token.isUpperName ?? false
        }) || statements.isEmpty {
            s.context.place = .views
        } else {
            s.context.place = .actions
            s.context.inActions = true
            s.context.userInitiated = enclosingActionIsUser(owner)
        }
        return s
    }

    private func inMenuBlock(_ node: Int) -> Bool {
        let table = nodeTable
        let catalog = options.catalog
        for a in table.ancestors(of: node) {
            let entry = table.entries[a]
            if entry.kind == .modifierApp {
                let tokens = entry.positioned.childTokens
                if tokens.count >= 2, let spec = catalog.modifier(named: tokens[1].token.name) {
                    if case .menuItems = spec.block { return true }
                    return false
                }
            }
            if entry.kind == .callStmt, let name = entry.positioned.firstChild(.callee)?.childTokens.first?.token.name,
               let component = catalog.component(named: name) {
                if case .menuItems = component.block { return true }
                if case .views = component.block { return false }
            }
        }
        return false
    }

    /// Whether the innermost event block around a node is the user's own (a click, a menu item).
    private func enclosingActionIsUser(_ node: Int) -> Bool {
        let table = nodeTable
        for a in [node] + table.ancestors(of: node) where table.entries[a].kind == .modifierApp {
            let tokens = table.entries[a].positioned.childTokens
            if tokens.count >= 2, let spec = options.catalog.modifier(named: tokens[1].token.name) {
                if let event = spec.event { return event.userInitiated }
                if spec.timing != nil { return false }
            }
        }
        return false
    }

    /// The names of the modifiers written in a style or state body.
    private func modifierNames(inBlock block: Int) -> [String] {
        let table = nodeTable
        var out: [String] = []
        for c in table.children(of: block) where table.entries[c].kind == .modifierStmt {
            for m in table.children(of: c) where table.entries[m].kind == .modifierApp {
                let tokens = table.entries[m].positioned.childTokens
                if tokens.count >= 2, !tokens[1].token.isMissing { out.append(tokens[1].token.name) }
            }
        }
        return out
    }

    /// The element (call statement) a modifier is written on, for `.hover { }` bodies and chains.
    private func elementOwning(modifier m: Int) -> Int? {
        let table = nodeTable
        var i = table.entries[m].parent
        while i >= 0 {
            if table.entries[i].kind == .callStmt { return i }
            if table.entries[i].kind == .block || table.entries[i].kind == .styleDecl { return nil }
            i = table.entries[i].parent
        }
        return nil
    }

    /// The kind of the element a call statement makes, from the checker's facts or its component's name.
    private func elementKind(of call: Int) -> ElementKind? {
        let table = nodeTable
        if let facts = checked.elements[table.id(call)] { return facts.kind }
        guard let name = table.entries[call].positioned.firstChild(.callee)?.childTokens.first?.token.name else { return nil }
        return options.catalog.component(named: name)?.kind
    }

    // MARK: After a dot

    private func classifyAfterDot(dotIndex: Int, offset: Int, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let tokens = tokenTable
        let table = nodeTable
        let dot = tokens.entries[dotIndex]
        let parent = dot.parent
        guard parent >= 0 else { return s }
        switch table.entries[parent].kind {
        case .modifierApp:
            let modifierParent = table.entries[parent].parent
            if modifierParent >= 0, table.entries[modifierParent].kind == .callStmt,
               let base = memberCallee(call: modifierParent, modifier: parent, dot: dot) {
                // `music.` in an action block: the parser reads a lone `.` after a name as a modifier.
                return memberOfCallee(parts: base, call: modifierParent, offset: offset, s)
            }
            s.context.place = .modifiers
            if modifierParent >= 0, table.entries[modifierParent].kind == .callStmt {
                let inOptions = table.ancestors(of: modifierParent).contains { table.entries[$0].kind == .optionsBlock }
                s.context.modifierSite = inOptions ? .option : .element
                s.modifierOwner = modifierParent
                s.context.elementKind = inOptions ? nil : elementKind(of: modifierParent)
                s.presentModifiers = CallStmtSyntax(unchecked: table.entries[modifierParent].positioned).modifiers
                    .filter { $0.node.offset != table.entries[parent].offset }
                    .compactMap { $0.name.token.isMissing ? nil : $0.name.token.name }
            } else if modifierParent >= 0, table.entries[modifierParent].kind == .modifierStmt {
                let block = table.entries[modifierParent].parent
                let owner = block >= 0 ? table.entries[block].parent : -1
                s.presentModifiers = block >= 0 ? modifierNames(inBlock: block).filter { _ in true } : []
                if let current = table.entries[parent].positioned.childTokens.dropFirst().first, !current.token.isMissing,
                   let k = s.presentModifiers.firstIndex(of: current.token.name) {
                    s.presentModifiers.remove(at: k)
                }
                if owner >= 0, table.entries[owner].kind == .styleDecl {
                    s.context.modifierSite = .style
                } else if owner >= 0, table.entries[owner].kind == .modifierApp {
                    s.context.modifierSite = .state
                    if let element = elementOwning(modifier: owner) {
                        s.modifierOwner = element
                        s.context.elementKind = elementKind(of: element)
                    }
                } else {
                    let inOptions = owner >= 0 && (table.entries[owner].kind == .optionsBlock
                        || table.ancestors(of: owner).contains { table.entries[$0].kind == .optionsBlock })
                    s.context.modifierSite = inOptions ? .option : .element
                }
            } else {
                // After the `}` of an `if` or `for` (DK2032): any element's modifiers.
                s.context.modifierSite = .element
            }
            return s
        case .memberExpr:
            guard let base = table.children(of: parent).first else { return s }
            s.context.place = .member
            s.context.memberBase = memberBase(ofExpression: base)
            s.displaySlot = isDisplaySlot(parent, offset: offset)
            s.context.inActions = inActionBlock(parent)
            s.context.userInitiated = s.context.inActions && enclosingActionIsUser(parent)
            if s.context.memberBase == nil { s.context.place = .none }
            return s
        case .implicitMemberExpr:
            s.context.place = .implicitMember
            s.context.expectedType = expectedType(forSlotOf: parent, offset: offset)
            s.context.inActions = inActionBlock(parent)
            s.context.userInitiated = s.context.inActions && enclosingActionIsUser(parent)
            return s
        case .callee, .target:
            let target = TargetSyntax(unchecked: table.entries[parent].positioned)
            var parts = [target.name.token.name]
            for member in target.members where member.textStart < dot.textStart { parts.append(member.token.name) }
            let statement = table.entries[parent].parent
            return memberOfCallee(parts: parts, call: statement, offset: offset, s)
        default:
            return s
        }
    }

    /// The name path before a lone `.` read as a modifier: `music` in `music.`, when the dot follows the name directly
    /// and the name is a namespace or an own name (not an element).
    private func memberCallee(call: Int, modifier: Int, dot: DeskTokenTable.Entry) -> [String]? {
        let table = nodeTable
        let children = table.children(of: call)
        guard let callee = children.first, table.entries[callee].kind == .callee, children.count >= 2, children[1] == modifier
        else { return nil }
        let target = TargetSyntax(unchecked: table.entries[callee].positioned)
        guard !target.name.token.isMissing, !target.name.token.isUpperName,
              table.entries[callee].textEnd == dot.textStart else { return nil }
        return [target.name.token.name] + target.members.map(\.token.name)
    }

    /// A member after a name path written as a statement or an assignment's target (`music.`, `options.`,
    /// `volume.level`).
    private func memberOfCallee(parts: [String], call: Int, offset: Int, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        s.context.place = .member
        s.memberStatement = true
        s.context.inActions = call >= 0 && inActionBlock(call)
        s.context.userInitiated = s.context.inActions && enclosingActionIsUser(call)
        s.context.memberBase = memberBase(ofPath: parts, at: offset)
        if s.context.memberBase == nil { s.context.place = .none }
        return s
    }

    /// Whether a node is inside an action block.
    func inActionBlock(_ node: Int) -> Bool {
        let table = nodeTable
        let catalog = options.catalog
        for a in table.ancestors(of: node) {
            let entry = table.entries[a]
            switch entry.kind {
            case .modifierApp:
                let tokens = entry.positioned.childTokens
                guard tokens.count >= 2, let spec = catalog.modifier(named: tokens[1].token.name) else { continue }
                if case .actions = spec.block {
                    // Inside its block, not its arguments.
                    if let block = entry.positioned.firstChild(.block), block.offset <= table.entries[node].offset { return true }
                    return false
                }
            case .callStmt:
                let name = entry.positioned.firstChild(.callee)?.childTokens.first?.token.name ?? ""
                if let f = catalog.function(named: name), f.takesActionBlock,
                   let block = entry.positioned.firstChild(.block), block.offset <= table.entries[node].offset { return true }
            case .widgetBlock, .styleDecl, .optionsBlock, .infoBlock, .packageBlock:
                return false
            default:
                continue
            }
        }
        return false
    }

    // MARK: Members

    /// What `x.` reads from, for an expression `x`.
    func memberBase(ofExpression e: Int) -> DeskMemberBase? {
        let table = nodeTable
        let index = symbolIndex
        if let ns = index.namespaceOf[e] { return .namespace(ns) }
        let entry = table.entries[e]
        if entry.kind == .identifierExpr {
            let token = IdentifierExprSyntax(unchecked: entry.positioned).token
            if case .element? = checked.symbols[table.id(e)] { return .element(token.token.name) }
            if let type = index.valueTypes[e] ?? recordedType(e)?.type { return .value(type) }
            return memberBase(ofPath: [token.token.name], at: entry.textStart)
        }
        if entry.kind == .memberExpr, index.valueTypes[e] == nil,
           let base = table.children(of: e).first, case .namespace(let ns)? = memberBase(ofExpression: base),
           let last = entry.positioned.childTokens.last(where: { $0.kind != .dot }), !last.token.isMissing {
            let nested = ns + "." + last.token.name
            if options.catalog.namespace(named: nested) != nil { return .namespace(nested) }
        }
        if entry.kind == .parenExpr, let inner = table.children(of: e).first { return memberBase(ofExpression: inner) }
        if let type = index.valueTypes[e] ?? recordedType(e)?.type { return .value(type) }
        // The checker typed nothing (the code around is broken): the names along the chain.
        if let parts = namePath(e) { return memberBase(ofPath: parts, at: entry.textStart) }
        if entry.kind == .callExpr, let callee = table.children(of: e).first, let parts = namePath(callee),
           let type = callResultType(parts, at: entry.textStart) {
            return .value(type)
        }
        return nil
    }

    /// What a call gives, from the names of its callee: a data function (`calendar.month(…)`), a global function, or
    /// a member function of a value (`note.split(…)`).
    func callResultType(_ parts: [String], at offset: Int) -> DeskType? {
        let catalog = options.catalog
        if parts.count == 1, let f = catalog.function(named: parts[0]) {
            if let data = f.data { return data.type }
            if case .fixed(let t)? = f.signatures.first?.result { return t }
            return nil
        }
        if parts.count >= 2, let found = catalog.serviceMember(dotted: parts) { return found.spec.type }
        guard parts.count >= 2, case .value(let base)? = memberBase(ofPath: Array(parts.dropLast()), at: offset),
              let member = catalog.member(parts[parts.count - 1], of: base, call: true) else { return nil }
        switch member.signatures.first?.result {
        case .receiver?: return base
        case .elementOf?: if case .list(let inner) = base { return inner }
        default: break
        }
        return member.type
    }

    /// `a.b.c` as names, for a chain of names and members without calls.
    func namePath(_ e: Int) -> [String]? {
        let table = nodeTable
        let entry = table.entries[e]
        switch entry.kind {
        case .identifierExpr:
            let token = IdentifierExprSyntax(unchecked: entry.positioned).token
            return token.token.isMissing ? nil : [token.token.name]
        case .memberExpr:
            guard let base = table.children(of: e).first, let head = namePath(base),
                  let last = entry.positioned.childTokens.last(where: { $0.kind != .dot }), !last.token.isMissing else { return nil }
            return head + [last.token.name]
        default:
            return nil
        }
    }

    /// What a name path reads from: a namespace (nested ones joined), `options`, `event`, an own name or a named
    /// element, then members along the path from the catalog.
    func memberBase(ofPath parts: [String], at offset: Int) -> DeskMemberBase? {
        guard let first = parts.first, !first.isEmpty else { return nil }
        let catalog = options.catalog
        var base: DeskMemberBase?
        var rest = parts.dropFirst()
        if catalog.namespace(named: first) != nil || first == "options" {
            var ns = first
            while let next = rest.first, catalog.namespace(named: ns + "." + next) != nil {
                ns += "." + next
                rest = rest.dropFirst()
            }
            if ns == "options", let name = rest.first {
                rest = rest.dropFirst()
                guard let type = optionFacts(named: name)?.type else { return nil }
                base = .value(type)
            } else if let name = rest.first, let member = catalog.index.member(ns, name) {
                rest = rest.dropFirst()
                base = .value(member.type)
            } else if rest.isEmpty {
                base = .namespace(ns)
            } else {
                return nil
            }
        } else if first == "event" {
            base = .value(.record(eventRecord(at: offset)))
        } else if let own = visibleOwnNames(at: offset).first(where: { $0.name == first }) {
            if own.kind == .element { base = .element(first) } else if let type = own.type { base = .value(type) } else { return nil }
        } else {
            return nil
        }
        for name in rest {
            guard case .value(let type)? = base, let member = catalog.member(name, of: type, call: false) else { return nil }
            base = .value(member.type)
        }
        return base
    }

    /// An option of the widget or the package.
    func optionFacts(named name: String) -> OptionFacts? {
        checked.options[name] ?? package?.options[name]
    }

    // MARK: Own names in scope

    /// An own name visible at a position: loop variables of the `for` loops around it (innermost first), the widget's
    /// declarations, and named elements.
    struct OwnName {
        var name: String
        var kind: DeskNameKind
        var type: DeskType?
        /// 0 for the innermost loop, growing outwards; declarations and elements after loops.
        var nearness: Int
    }

    func visibleOwnNames(at offset: Int) -> [OwnName] {
        let table = nodeTable
        var out: [OwnName] = []
        var near = 0
        // Loops whose block holds the offset.
        if let i = table.innermost(at: offset) ?? Optional(0) {
            for a in [i] + table.ancestors(of: i) where table.entries[a].kind == .forStmt {
                let loop = ForStmtSyntax(unchecked: table.entries[a].positioned)
                guard let block = table.entries[a].positioned.firstChild(.block), block.textRange.lowerBound < offset,
                      !loop.variable.token.isMissing, loop.variable.kind == .identifier else { continue }
                let name = loop.variable.token.name
                guard !out.contains(where: { $0.name == name }) else { continue }
                var type: DeskType?
                if let source = table.children(of: a).first(where: { table.entries[$0].kind.isExpression }),
                   case .list(let element)? = symbolIndex.valueTypes[source] ?? recordedType(source)?.type {
                    type = element
                }
                out.append(OwnName(name: name, kind: .loopVariable, type: type, nearness: near))
                near += 1
            }
        }
        // The widget's declarations and named elements.
        for top in table.topLevel where table.entries[top].kind == .widgetBlock {
            guard let block = table.children(of: top).first(where: { table.entries[$0].kind == .block }) else { continue }
            for statement in table.children(of: block) where table.entries[statement].kind == .declaration {
                let declaration = DeclarationSyntax(unchecked: table.entries[statement].positioned)
                let tokens = table.entries[statement].positioned.childTokens
                guard tokens.count >= 2, !declaration.name.token.isMissing, declaration.name.kind == .identifier else { continue }
                let name = declaration.name.token.name
                guard !out.contains(where: { $0.name == name }) else { continue }
                let kind: DeskNameKind
                switch declaration.keyword.kind {
                case .savedKeyword: kind = .saved
                case .computedKeyword: kind = .computed
                default: kind = .variable
                }
                let type = checked.declarationTypes[table.id(statement)]?.type
                    ?? table.children(of: statement).last.flatMap { symbolIndex.valueTypes[$0] ?? recordedType($0)?.type }
                out.append(OwnName(name: name, kind: kind, type: type, nearness: near))
            }
        }
        near += 1
        for facts in checked.elements.values {
            guard let name = facts.name, !out.contains(where: { $0.name == name }) else { continue }
            out.append(OwnName(name: name, kind: .element, type: nil, nearness: near))
        }
        return out
    }

    // MARK: Values and arguments

    /// A value is written after an operator, `=`, `:`, `(`, `[` or `{` of an interpolation.
    private func valueSlot(parent: Int, offset: Int, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let table = nodeTable
        s.context.place = .value
        s.context.inActions = inActionBlock(parent)
        s.context.userInitiated = s.context.inActions && enclosingActionIsUser(parent)
        // The slot's node: the expression holding the cursor under `parent`, if any.
        var slotNode: Int?
        for c in table.children(of: parent) where table.entries[c].kind.isExpression {
            let e = table.entries[c]
            if e.textStart <= offset, offset <= max(e.textEnd, e.textStart) { slotNode = c }
        }
        s.context.expectedType = slotNode.map { expectedType(forSlotOf: $0, offset: offset) }
            ?? expectedType(inside: parent, offset: offset)
        switch table.entries[parent].kind {
        case .interpolation:
            s.displaySlot = true
        case .formatOption:
            s.formatValueType = interpolationValueType(of: parent)
        case .argument:
            if let site = callSite(at: offset) {
                s.callSite = site
                s.argumentIndex = site.argumentIndex(at: offset)
                if let param = currentParameter(site, argument: s.argumentIndex) {
                    s.displaySlot = param.role == .display
                    specialize(&s, param: param, site: site)
                }
            }
        default:
            break
        }
        return s
    }

    /// The start of an argument: labels, and values when a positional parameter is open.
    private func argumentStart(offset: Int, word: Int?, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let table = nodeTable
        guard let site = callSite(at: offset) else { return s }
        s.callSite = site
        s.argumentIndex = site.argumentIndex(at: offset)
        s.context.place = .argument
        s.context.inActions = inActionBlock(site.clause)
        s.context.userInitiated = s.context.inActions && enclosingActionIsUser(site.clause)
        if let w = word, table.entries[tokenTable.entries[w].parent].kind == .label {
            s.labelsOnly = true
            return s
        }
        let before = site.arguments.prefix(s.argumentIndex)
        if before.contains(where: { $0.label != nil }) {
            s.labelsOnly = true
            return s
        }
        let signature = site.signatures[activeSignature(site, argument: s.argumentIndex)]
        let positional = signature.params.filter { $0.label == nil }
        let written = before.filter { $0.label == nil }.count
        if written < positional.count || positional.last?.variadic == true {
            s.allowsPositionalValue = true
            let param = positional[min(written, positional.count - 1)]
            s.context.expectedType = param.type
            s.displaySlot = param.role == .display
            specialize(&s, param: param, site: site)
            if s.context.place != .argument { return s }
        }
        return s
    }

    /// A parameter whose values are names or paths changes the place.
    private func specialize(_ s: inout DeskCompletionScan, param: ParamSpec, site: DeskCallSite) {
        if param.type == .styleRef { s.context.place = .styleName }
        if param.type == .elementName { s.context.place = .elementName }
        switch param.role {
        case .styleRef:
            s.context.place = .styleName
        case .elementName:
            s.context.place = .elementName
        case .declaresElementName:
            // A new name: nothing to offer.
            s.context.place = .none
        default:
            break
        }
        // Freeform geometry: a position or size may name a sibling.
        if site.owner == .modifier, case .modifier(let name)? = site.path,
           ["position", "width", "height", "size", "offset"].contains(name),
           param.type == .length || param.type == .lengthSpec || param.type.components.contains(.length) {
            s.geometrySiblings = freeformSiblingNames(ofModifierClause: site.clause)
        }
    }

    /// Whether the value a member chain makes is shown as text: the chain is an interpolation's value or the
    /// argument of a display parameter.
    func isDisplaySlot(_ node: Int, offset: Int) -> Bool {
        let table = nodeTable
        var i = node
        while table.entries[i].parent >= 0 {
            let p = table.entries[i].parent
            let kind = table.entries[p].kind
            if (kind == .memberExpr || kind == .callExpr), table.children(of: p).first == i {
                i = p
                continue
            }
            if kind == .interpolation { return table.children(of: p).first == i }
            if kind == .argument, let site = callSite(at: offset) {
                return currentParameter(site, argument: site.argumentIndex(at: offset))?.role == .display
            }
            return false
        }
        return false
    }

    /// The parameter an argument stands for.
    func currentParameter(_ site: DeskCallSite, argument k: Int) -> ParamSpec? {
        let signature = site.signatures[activeSignature(site, argument: k)]
        guard let p = activeParameter(signature, site: site, argument: k), signature.params.indices.contains(p) else { return nil }
        return signature.params[p]
    }

    /// Named siblings of the element a modifier is on, when its parent is a Freeform (the element's own name
    /// included: it may name its own width and height).
    private func freeformSiblingNames(ofModifierClause clause: Int) -> [String] {
        let table = nodeTable
        guard let element = table.ancestors(of: clause).first(where: { table.entries[$0].kind == .callStmt }),
              let facts = checked.elements[table.id(element)] else { return [] }
        guard let parent = facts.parent, let parentFacts = checked.elements[parent], parentFacts.kind == .freeform else {
            return []
        }
        var names: [String] = []
        for other in checked.elements.values where other.parent == parent && !other.insideIf && !other.insideFor {
            if let name = other.name { names.append(name) }
        }
        return names.sorted()
    }

    /// After `,` in an interpolation: a format option's label.
    private func formatOptionStart(offset: Int, word: Int?, _ scan: DeskCompletionScan) -> DeskCompletionScan {
        var s = scan
        let table = nodeTable
        guard let before = tokenTable.previousPresent(endingAtOrBefore: word.map { tokenTable.entries[$0].textStart } ?? offset) else { return s }
        var i = tokenTable.entries[before].parent
        while i >= 0, table.entries[i].kind != .interpolation { i = table.entries[i].parent }
        guard i >= 0 else { return s }
        s.context.place = .formatOption
        s.formatValueType = table.children(of: i).first.flatMap { table.entries[$0].kind == .formatOption ? nil : recordedType($0)?.type ?? symbolIndex.valueTypes[$0] }
        s.context.expectedType = s.formatValueType
        s.callSite = callSite(at: offset)
        s.argumentIndex = s.callSite?.argumentIndex(at: offset) ?? 0
        return s
    }

    /// The type of the value an interpolation shows, for a node inside its format options.
    private func interpolationValueType(of node: Int) -> DeskType? {
        let table = nodeTable
        var i = node
        while i >= 0, table.entries[i].kind != .interpolation { i = table.entries[i].parent }
        guard i >= 0, let value = table.children(of: i).first, table.entries[value].kind != .formatOption else { return nil }
        return recordedType(value)?.type ?? symbolIndex.valueTypes[value]
    }

    // MARK: Expected types

    /// The type expected of the expression at node `e`, from where it is written.
    func expectedType(forSlotOf e: Int, offset: Int) -> DeskType? {
        let table = nodeTable
        let parent = table.entries[e].parent
        guard parent >= 0 else { return nil }
        return expectedType(inside: parent, child: e, offset: offset)
    }

    /// The type expected at an offset among the children of `parent` (the slot `child` when known).
    func expectedType(inside parent: Int, child: Int? = nil, offset: Int) -> DeskType? {
        let table = nodeTable
        let catalog = options.catalog
        let entry = table.entries[parent]
        let children = table.children(of: parent)
        func typeOf(_ i: Int) -> DeskType? {
            if let ns = symbolIndex.namespaceOf[i], let spec = catalog.namespace(named: ns) {
                return spec.value?.type ?? spec.instanceOf.map { .record($0) }
            }
            return recordedType(i)?.type ?? symbolIndex.valueTypes[i]
        }
        switch entry.kind {
        case .argument, .argumentClause:
            let clause = entry.kind == .argument ? entry.parent : parent
            guard clause >= 0 else { return nil }
            // `.ifMissing(…)`: the receiver's type.
            let owner = table.entries[clause].parent
            if owner >= 0, table.entries[owner].kind == .callExpr, let callee = table.children(of: owner).first,
               table.entries[callee].kind == .memberExpr,
               table.entries[callee].positioned.childTokens.last?.token.name == "ifMissing",
               let base = table.children(of: callee).first {
                return typeOf(base)
            }
            guard let site = callSite(at: offset) else { return nil }
            return currentParameter(site, argument: site.argumentIndex(at: offset))?.type
        case .field:
            guard let label = children.first.flatMap({ table.entries[$0].positioned.childTokens.first }), !label.token.isMissing
            else { return nil }
            let name = label.token.name
            let inPackage = table.ancestors(of: parent).contains { table.entries[$0].kind == .packageBlock }
            return (inPackage ? catalog.index.packageFields[name] : catalog.index.infoFields[name])?.type
        case .formatOption:
            guard let label = children.first.flatMap({ table.entries[$0].positioned.childTokens.first }), !label.token.isMissing,
                  let rows = catalog.index.formatOptions[label.token.name] else { return nil }
            let valueType = interpolationValueType(of: parent)
            return (rows.first { DeskSnapshot.formatOption($0, appliesTo: valueType) } ?? rows.first)?.type
        case .binaryExpr:
            let op = entry.positioned.childTokens.first
            let operands = children.filter { table.entries[$0].kind.isExpression }
            guard let op else { return nil }
            switch op.kind {
            case .andKeyword, .orKeyword: return .bool
            case .equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual, .plus, .minus, .star, .slash, .percent:
                let other = offset > op.textStart ? operands.first : operands.dropFirst().first
                if let other, other != child { return typeOf(other) }
                if let other = operands.first(where: { $0 != child }) { return typeOf(other) }
                return nil
            default:
                return nil
            }
        case .prefixExpr:
            let op = entry.positioned.childTokens.first
            return op?.kind == .notKeyword ? .bool : nil
        case .ternaryExpr:
            let tokens = entry.positioned.childTokens
            if let question = tokens.first(where: { $0.kind == .question }), offset <= question.textStart { return .bool }
            if let outer = expectedType(forSlotOf: parent, offset: offset) { return outer }
            let branches = children.filter { table.entries[$0].kind.isExpression }.dropFirst()
            return branches.first { $0 != child }.flatMap(typeOf)
        case .listLiteral:
            let outer = expectedType(forSlotOf: parent, offset: offset)
            if case .list(let element)? = outer, element != .any { return element }
            if case .binding(.list(let element))? = outer, element != .any { return element }
            // The other items say what the list holds (`[.sunday, .|]`).
            for sibling in children where sibling != child && table.entries[sibling].kind.isExpression {
                if let type = typeOf(sibling) { return type }
                if table.entries[sibling].kind == .implicitMemberExpr,
                   let name = table.entries[sibling].positioned.childTokens.dropFirst().first, !name.token.isMissing,
                   let type = catalog.implicitMemberTypes(name.token.name).first {
                    if catalog.enumeration(type) != nil { return .enumeration(type) }
                    return type == "Color" ? .color : .paint
                }
            }
            if case .list(let element)? = outer { return element }
            return nil
        case .parenExpr:
            return expectedType(forSlotOf: parent, offset: offset)
        case .assignment:
            guard let target = children.first(where: { table.entries[$0].kind == .target }) else { return nil }
            let path = TargetSyntax(unchecked: table.entries[target].positioned)
            guard !path.name.token.isMissing else { return nil }
            if let type = typeOf(target) { return type }
            let parts = [path.name.token.name] + path.members.map(\.token.name)
            if parts.count == 2, parts[0] == "options" { return optionFacts(named: parts[1])?.type }
            if parts.count >= 2, let member = catalog.serviceMember(dotted: parts) { return member.spec.type }
            if parts.count == 1 { return visibleOwnNames(at: offset).first { $0.name == parts[0] }?.type }
            return nil
        case .ifStmt:
            return .bool
        case .forStmt:
            return .list(.any)
        case .interpolation, .declaration:
            return nil
        default:
            return nil
        }
    }
}
