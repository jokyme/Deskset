import Foundation

// Semantic highlighting: what every word, number and text of a file is, from the symbol index (own names, built-in
// names the checker resolved), the checker's element facts (the component a call makes), and the catalog (fields,
// labels, format options); foreign syntax and what recovery could not place have kinds of their own. Punctuation
// and operators outside those are left to the editor's plain text color.
//
// Two encodings of one result: the Language Server Protocol's relative integers (UTF-16 lines and characters, a token
// that spans lines split at each line break) and plain runs for TextKit. Runs are built per top-level block and kept
// in the snapshot, so a range request only classifies the blocks it touches, and reuse between parses can keep the
// runs of an unchanged block (their offsets are relative to the block).

/// What a highlighted piece of text is.
public enum DeskSemanticTokenType: Int, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    /// `if`, `for`, `and`, `true`, `variable`…
    case keyword
    /// `info`, `options`, `widget`, `style`, `translations`, `package` at the start of a top-level item.
    case blockWord
    case component, control, modifier, enumCase, namespace
    /// A field of data (`cpu.usage`, `day.isToday`, `name.count`).
    case dataMember
    /// A function or a data call (`round`, `calendar.month`).
    case function
    /// An action (`open`, `show`, `music.play`).
    case action
    case variable, saved, computed, loopVariable, elementName, style, option
    /// A field of `info { }` or `package { }`.
    case field
    /// An argument label (`total:`).
    case label
    case number, unit, string
    /// `{` and `}` around data in text.
    case interpolation
    /// `digits:` inside `{value, digits: 1}`.
    case formatOption
    case comment
    /// Syntax of another language (`&&`, `#Name#`, `[Meter]`, `<div>`).
    case foreign
    /// `event` in an event block.
    case event
    /// The text a translation replaces, where `translations { }` keys it.
    case translationKey
    /// What cannot be read: a character or name Desk does not allow, code recovery could not place, a unit
    /// Desk does not know.
    case invalid

    /// The name in the legend.
    public var name: String { DeskSemanticTokenType.names[rawValue] }
    public var description: String { name }

    static let names = ["keyword", "blockWord", "component", "control", "modifier", "enumCase", "namespace",
                        "dataMember", "function", "action", "variable", "saved", "computed", "loopVariable",
                        "elementName", "style", "option", "field", "label", "number", "unit", "string",
                        "interpolation", "formatOption", "comment", "foreign", "event", "translationKey", "invalid"]
}

/// What else is true of a highlighted piece.
public struct DeskSemanticTokenModifiers: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Where an own name is given.
    public static let declaration = DeskSemanticTokenModifiers(rawValue: 1 << 0)
    /// Assigned in an action.
    public static let write = DeskSemanticTokenModifiers(rawValue: 1 << 1)
    /// A built-in name that is being replaced.
    public static let deprecated = DeskSemanticTokenModifiers(rawValue: 1 << 2)
    /// Declared and never used.
    public static let unused = DeskSemanticTokenModifiers(rawValue: 1 << 3)
    /// A built-in name that exists only on the Mac.
    public static let macOnly = DeskSemanticTokenModifiers(rawValue: 1 << 4)

    static let names = ["declaration", "write", "deprecated", "unused", "macOnly"]

    public var description: String {
        DeskSemanticTokenModifiers.names.enumerated().filter { rawValue & (1 << UInt32($0.offset)) != 0 }.map(\.element)
            .joined(separator: ",")
    }
}

/// The legend a Language Server Protocol client is given: the index of a type or modifier in these lists is what
/// the encoded integers say.
public enum DeskSemanticTokenLegend {
    public static let tokenTypes: [String] = DeskSemanticTokenType.names
    public static let tokenModifiers: [String] = DeskSemanticTokenModifiers.names
}

/// One highlighted piece of the open text.
public struct DeskSemanticToken: Sendable, Hashable, CustomStringConvertible {
    public var range: DeskRange
    public var type: DeskSemanticTokenType
    public var modifiers: DeskSemanticTokenModifiers

    public init(range: DeskRange, type: DeskSemanticTokenType, modifiers: DeskSemanticTokenModifiers = []) {
        self.range = range
        self.type = type
        self.modifiers = modifiers
    }

    public var description: String {
        "\(range.start) \(type)" + (modifiers.isEmpty ? "" : "[\(modifiers)]")
    }
}

/// A highlighted piece as TextKit applies it: a UTF-16 range of the text storage.
public struct DeskSemanticRun: Sendable, Hashable {
    public var range: NSRange
    public var type: DeskSemanticTokenType
    public var modifiers: DeskSemanticTokenModifiers

    public init(range: NSRange, type: DeskSemanticTokenType, modifiers: DeskSemanticTokenModifiers) {
        self.range = range
        self.type = type
        self.modifiers = modifiers
    }
}

/// Semantic tokens of the open text (or of a part of it), sorted and not overlapping.
public struct DeskSemanticTokens: Sendable, Hashable {
    public let tokens: [DeskSemanticToken]
    /// The Language Server Protocol encoding: five integers per token (line delta, start delta, length, type index,
    /// modifier bits), in UTF-16 units; a token that spans lines is split at each line break, which is left out.
    public let data: [UInt32]

    init(tokens: [DeskSemanticToken], index: DeskTextIndex) {
        self.tokens = tokens
        var data: [UInt32] = []
        data.reserveCapacity(tokens.count * 5)
        var line = 0
        var column = 0
        func emit(_ start: DeskPosition, _ length: Int, _ token: DeskSemanticToken) {
            guard length > 0 else { return }
            let deltaLine = start.line - line
            let deltaStart = deltaLine == 0 ? start.column - column : start.column
            data += [UInt32(deltaLine), UInt32(deltaStart), UInt32(length), UInt32(token.type.rawValue), token.modifiers.rawValue]
            line = start.line
            column = start.column
        }
        for token in tokens {
            let r = token.range
            if r.start.line == r.end.line {
                emit(r.start, r.length, token)
                continue
            }
            for l in r.start.line...r.end.line {
                let content = index.utf16ContentRange(ofLine: l)
                let from = max(content.lowerBound, r.start.offset)
                let to = min(content.upperBound, r.end.offset)
                guard from < to else { continue }
                emit(index.position(utf16: from), to - from, token)
            }
        }
        self.data = data
    }

    /// The tokens as TextKit runs.
    public var runs: [DeskSemanticRun] {
        tokens.map { DeskSemanticRun(range: $0.range.nsRange, type: $0.type, modifiers: $0.modifiers) }
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

/// The runs of one top-level block (or of the comments after the last one), with UTF-8 offsets relative to the
/// block's first byte (its leading trivia included). Built once per snapshot; a later parse that keeps the block's
/// node and the names it refers to can reuse them at the block's new offset.
struct DeskSemanticBlock: Sendable {
    struct Run: Sendable, Hashable {
        var start: Int
        var end: Int
        var type: DeskSemanticTokenType
        var modifiers: DeskSemanticTokenModifiers
    }

    /// The block's node; nil for the end of the file.
    let node: SyntaxNode?
    let offset: Int
    let length: Int
    /// Sorted, not overlapping.
    let runs: [Run]

    var range: Range<Int> { offset..<(offset + length) }
}

extension DeskSnapshot {
    // MARK: Requests

    /// Every semantic token of the open text, sorted.
    public func semanticTokens() -> DeskSemanticTokens {
        caches.semanticTokens.value {
            var tokens: [DeskSemanticToken] = []
            for k in semanticBlockRanges.indices { tokens += semanticTokens(ofBlock: k) }
            return DeskSemanticTokens(tokens: tokens, index: index)
        }
    }

    /// The semantic tokens that overlap a range of the open text (an empty range: those holding its position):
    /// the same tokens as `semanticTokens()` has there, classifying only the blocks the range touches.
    public func semanticTokens(in range: DeskRange) -> DeskSemanticTokens {
        let lower = range.start.offset
        let upper = max(range.end.offset, lower + 1)
        func overlaps(_ token: DeskSemanticToken) -> Bool {
            token.range.end.offset > lower && token.range.start.offset < upper
        }
        if let all = caches.semanticTokens.peek() {
            return DeskSemanticTokens(tokens: all.tokens.filter(overlaps), index: index)
        }
        let lower8 = index.utf8Offset(ofUTF16: lower)
        let upper8 = index.utf8Offset(ofUTF16: min(upper, index.utf16Count))
        var tokens: [DeskSemanticToken] = []
        for (k, block) in semanticBlockRanges.enumerated() where block.upperBound >= lower8 && block.lowerBound <= upper8 {
            tokens += semanticTokens(ofBlock: k).filter(overlaps)
        }
        return DeskSemanticTokens(tokens: tokens, index: index)
    }

    // MARK: Blocks

    /// The UTF-8 ranges of the top-level blocks, then the end of the file (the comments after the last block).
    var semanticBlockRanges: [Range<Int>] {
        var out: [Range<Int>] = []
        var at = 0
        for child in tree.root.children {
            let length = child.byteLength
            out.append(at..<(at + length))
            at += length
        }
        return out
    }

    /// The runs of the `k`-th top-level child of the file (the last is the end of the file), built once. A block
    /// the previous snapshot classified from the same facts is not classified again (`DeskBlockMemo`).
    func semanticBlock(_ k: Int) -> DeskSemanticBlock {
        caches.semanticBlocks.value(for: k) {
            let children = tree.root.children
            guard case .node(let node) = children[k] else { return DeskSemanticClassifier(snapshot: self).block(k) }
            var offset = 0
            for child in children.prefix(k) { offset += child.byteLength }
            let facts = semanticBlockFacts(offset..<(offset + node.byteLength))
            if let runs = memo.semantic(node, facts: facts) {
                return DeskSemanticBlock(node: node, offset: offset, length: node.byteLength, runs: runs)
            }
            let block = DeskSemanticClassifier(snapshot: self).block(k)
            memo.storeSemantic(node, facts: facts, runs: block.runs)
            return block
        }
    }

    /// The facts classification reads inside a range of the file, relative to its start.
    func semanticBlockFacts(_ range: Range<Int>) -> DeskSemanticBlockFacts {
        let facts = semanticFacts
        let names = symbolIndex.names
        var out = DeskSemanticBlockFacts()
        // The first name at or after the range's start (names are sorted and never overlap).
        var low = 0, high = names.count
        while low < high {
            let mid = (low + high) / 2
            if names[mid].range.lowerBound < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        let base = range.lowerBound
        var k = low
        while k < names.count, names[k].range.lowerBound < range.upperBound {
            let o = names[k]
            out.names.append(.init(start: o.range.lowerBound - base, end: o.range.upperBound - base, kind: o.kind,
                                   role: o.role, path: o.path))
            k += 1
        }
        for r in facts.unused where range.contains(r.lowerBound) { out.unused += [r.lowerBound - base, r.upperBound - base] }
        for start in facts.elementCalls where range.contains(start) { out.elementCalls.append(start - base) }
        for start in facts.translationKeys where range.contains(start) { out.translationKeys.append(start - base) }
        out.elementCalls.sort()
        out.translationKeys.sort()
        // Pairs of (start, end), sorted by start.
        var pairs: [(Int, Int)] = []
        for i in stride(from: 0, to: out.unused.count, by: 2) { pairs.append((out.unused[i], out.unused[i + 1])) }
        out.unused = pairs.sorted { $0 < $1 }.flatMap { [$0.0, $0.1] }
        return out
    }

    private func semanticTokens(ofBlock k: Int) -> [DeskSemanticToken] {
        let block = semanticBlock(k)
        var offsets: [Int] = []
        offsets.reserveCapacity(block.runs.count * 2)
        for run in block.runs {
            offsets.append(block.offset + run.start)
            offsets.append(block.offset + run.end)
        }
        let positions = index.positions(ofAscendingUTF8: offsets)
        return block.runs.indices.map { r in
            let (s, e) = (positions[2 * r], positions[2 * r + 1])
            return DeskSemanticToken(range: DeskRange(start: DeskPosition(offset: s.utf16, line: s.line, column: s.column),
                                                      end: DeskPosition(offset: e.utf16, line: e.line, column: e.column)),
                                     type: block.runs[r].type, modifiers: block.runs[r].modifiers)
        }
    }

    /// What classification reads besides the tree: built once per snapshot.
    var semanticFacts: DeskSemanticFacts {
        caches.semanticFacts.value { DeskSemanticFacts(snapshot: self) }
    }
}

/// The facts classification reads, gathered once per snapshot.
final class DeskSemanticFacts: Sendable {
    /// The index's names by where they start.
    let names: [Int: DeskOccurrence]
    /// String literals (by node start) that are keys of `translations { }`.
    let translationKeys: Set<Int>
    /// Ranges of the "never used" diagnostics of the file.
    let unused: Set<Range<Int>>
    /// Calls that make an element (by the call's text start).
    let elementCalls: Set<Int>

    init(snapshot: DeskSnapshot) {
        let index = snapshot.symbolIndex
        var names: [Int: DeskOccurrence] = [:]
        names.reserveCapacity(index.names.count)
        for occurrence in index.names { names[occurrence.range.lowerBound] = occurrence }
        self.names = names
        var keys = Set<Int>()
        let table = snapshot.nodeTable
        for span in index.spans where span.kind == .translationKey && span.role == .declaration {
            if let i = table.innermost(at: span.range.lowerBound, where: { $0.kind == .stringLiteral }) {
                keys.insert(table.entries[i].textStart)
            }
        }
        translationKeys = keys
        let unusedIDs: Set<DiagnosticID> = [.unusedDeclaration, .unusedStyle, .unusedOption, .unusedTranslation,
                                            .unusedPermission, .unusedHost, .unusedAsset]
        unused = Set(snapshot.checked.diagnostics.filter { unusedIDs.contains($0.id) && $0.file == snapshot.file }.map(\.range))
        var calls = Set<Int>()
        for id in snapshot.checked.elements.keys where id.treeVersion == snapshot.tree.version { calls.insert(id.utf8Start) }
        elementCalls = calls
    }
}

/// Classifies the tokens of one snapshot's blocks.
struct DeskSemanticClassifier {
    let snapshot: DeskSnapshot
    let table: DeskNodeTable
    let facts: DeskSemanticFacts
    let catalog: DeskCatalog

    /// What the catalog says of each built-in name met so far.
    final class Memo {
        var flags: [CatalogPath: DeskSemanticTokenModifiers] = [:]
        var kinds: [CatalogPath: MemberSpec.Kind?] = [:]
    }
    let memo = Memo()

    init(snapshot: DeskSnapshot) {
        self.snapshot = snapshot
        table = snapshot.nodeTable
        facts = snapshot.semanticFacts
        catalog = snapshot.options.catalog
    }

    /// `deprecated` and `macOnly` of a built-in name.
    func flags(_ path: CatalogPath) -> DeskSemanticTokenModifiers {
        if let known = memo.flags[path] { return known }
        let docs = catalog.serviceDocs(for: path)
        var modifiers: DeskSemanticTokenModifiers = []
        if docs.first?.deprecated != nil { modifiers.insert(.deprecated) }
        if docs.first?.macOnly == true { modifiers.insert(.macOnly) }
        memo.flags[path] = modifiers
        return modifiers
    }

    func memberKind(_ path: CatalogPath) -> MemberSpec.Kind? {
        if let known = memo.kinds[path] { return known }
        let kind = catalog.serviceMemberKind(for: path)
        memo.kinds[path] = kind
        return kind
    }

    typealias Run = DeskSemanticBlock.Run

    /// Where a node is: in foreign syntax, in code recovery could not place, or neither.
    enum Region { case plain, foreign, invalid }

    func block(_ k: Int) -> DeskSemanticBlock {
        let root = snapshot.tree.root
        var offset = 0
        for child in root.children.prefix(k) { offset += child.byteLength }
        let child = root.children[k]
        var runs: [Run] = []
        switch child {
        case .token(let token):
            // The end of the file: only its leading comments.
            addComments(of: token, at: offset, into: &runs)
            return DeskSemanticBlock(node: nil, offset: offset, length: token.utf8Length, runs: shifted(runs, by: offset))
        case .node(let node):
            // The table entry of this top-level node.
            let entry = table.children(of: 0).first { table.entries[$0].offset == offset && table.entries[$0].node === node }
            if let entry { classifyEntries(from: entry, into: &runs) }
            return DeskSemanticBlock(node: node, offset: offset, length: node.byteLength, runs: shifted(runs, by: offset))
        }
    }

    private func shifted(_ runs: [Run], by offset: Int) -> [Run] {
        var sorted = runs.sorted { $0.start < $1.start }
        var kept: [Run] = []
        kept.reserveCapacity(sorted.count)
        var reached = Int.min
        for i in sorted.indices {
            sorted[i].start -= offset
            sorted[i].end -= offset
            guard sorted[i].end > sorted[i].start, sorted[i].start >= reached else { continue }
            kept.append(sorted[i])
            reached = sorted[i].end
        }
        return kept
    }

    private func addComments(of token: Token, at offset: Int, into runs: inout [Run]) {
        var at = offset
        for piece in token.leadingTrivia {
            if piece.isComment { runs.append(Run(start: at, end: at + piece.utf8Length, type: .comment, modifiers: [])) }
            at += piece.utf8Length
        }
        at += token.text.utf8.count
        for piece in token.trailingTrivia {
            if piece.isComment { runs.append(Run(start: at, end: at + piece.utf8Length, type: .comment, modifiers: [])) }
            at += piece.utf8Length
        }
    }

    private func classifyEntries(from first: Int, into runs: inout [Run]) {
        let end = table.entries[first].end
        var regions = [Region](repeating: .plain, count: end - first)
        for e in first..<end {
            let entry = table.entries[e]
            let inherited: Region = e == first || entry.parent < first ? .plain : regions[entry.parent - first]
            switch entry.kind {
            case .foreignConstruct: regions[e - first] = inherited == .invalid ? .invalid : .foreign
            case .unexpected: regions[e - first] = inherited == .foreign ? .foreign : .invalid
            default: regions[e - first] = inherited
            }
        }
        for e in first..<end {
            let entry = table.entries[e]
            var at = entry.offset
            var k = 0
            var tokens: [(token: Token, offset: Int)] = []
            for child in entry.node.children {
                if case .token(let token) = child { tokens.append((token, at)) }
                at += child.byteLength
            }
            let siblings = tokens.map(\.token)
            for (token, offset) in tokens {
                defer { k += 1 }
                addComments(of: token, at: offset, into: &runs)
                guard !token.isMissing, !token.text.isEmpty, token.kind != .eof else { continue }
                let start = offset + token.leadingTrivia.utf8Length
                let range = start..<(start + token.text.utf8.count)
                switch regions[e - first] {
                case .foreign:
                    runs.append(Run(start: range.lowerBound, end: range.upperBound, type: .foreign, modifiers: []))
                    continue
                case .invalid:
                    runs.append(Run(start: range.lowerBound, end: range.upperBound, type: .invalid, modifiers: []))
                    continue
                case .plain:
                    break
                }
                classify(token, range: range, entry: e, position: k, siblings: siblings, into: &runs)
            }
        }
    }

    // MARK: Tokens

    private func classify(_ token: Token, range: Range<Int>, entry e: Int, position k: Int, siblings: [Token],
                          into runs: inout [Run]) {
        func add(_ type: DeskSemanticTokenType, _ modifiers: DeskSemanticTokenModifiers = [], _ r: Range<Int>? = nil) {
            let r = r ?? range
            var modifiers = modifiers
            if facts.unused.contains(r) { modifiers.insert(.unused) }
            runs.append(Run(start: r.lowerBound, end: r.upperBound, type: type, modifiers: modifiers))
        }
        var kind = token.kind
        // A reserved word written as a label or a member name (`if:`, `x.in`) is a name there.
        if kind.isKeyword, kind != .eventKeyword || table.entries[e].kind == .label {
            switch table.entries[e].kind {
            case .label, .memberExpr, .implicitMemberExpr, .modifierApp, .callee, .target: kind = .identifier
            default: break
            }
        }
        switch kind {
        case .identifier:
            if let occurrence = facts.names[range.lowerBound], occurrence.range == range {
                let (type, modifiers) = classify(occurrence)
                add(type, modifiers)
            } else {
                let (type, modifiers) = fallback(token, entry: e, position: k, siblings: siblings)
                add(type, modifiers)
            }
        case .eventKeyword:
            add(.event)
        case .ifKeyword, .elseKeyword, .forKeyword, .inKeyword, .andKeyword, .orKeyword, .notKeyword, .trueKeyword,
             .falseKeyword, .variableKeyword, .savedKeyword, .computedKeyword:
            add(.keyword)
        case .number:
            let digits = DeskSemanticClassifier.digitLength(token.text)
            if digits > 0 { add(.number, [], range.lowerBound..<(range.lowerBound + digits)) }
            if digits < token.text.utf8.count {
                let unitRange = (range.lowerBound + max(digits, 0))..<range.upperBound
                if case .known? = token.unit?.status { add(.unit, [], unitRange) } else { add(.invalid, [], unitRange) }
            }
        case .stringStart, .stringText, .stringEnd, .rawString:
            var literal: Int?
            switch table.entries[e].kind {
            case .stringLiteral: literal = e
            case .stringText where table.entries[e].parent >= 0 && table.entries[table.entries[e].parent].kind == .stringLiteral:
                literal = table.entries[e].parent
            default: break
            }
            if let literal, facts.translationKeys.contains(table.entries[literal].textStart) {
                add(.translationKey)
            } else {
                add(.string)
            }
        case .interpolationStart, .interpolationEnd:
            add(.interpolation)
        case .invalidIdentifier, .invalidCharacter, .unlexedText:
            add(.invalid)
        case .opaqueBlock:
            add(.comment)
        case .ampAmp, .pipePipe, .bang, .plusEqual, .minusEqual, .starEqual, .slashEqual, .plusPlus, .minusMinus,
             .starStar, .amp, .pipe, .caret, .tilde, .questionQuestion, .dotDot, .dotDotLess, .arrow, .fatArrow,
             .colonColon, .at, .dollar, .backslash, .backquote, .singleQuote, .hash, .lessSlash, .htmlComment,
             .rainmeterVariable, .hexColor, .hexNumber, .tripleQuoteString, .foreignInterpolation, .foreignHashComment,
             .foreignRainmeterComment:
            add(.foreign)
        default:
            // Punctuation and operators.
            break
        }
    }

    /// The UTF-8 length of a number token's digits (full-width digits and a leading dot included).
    static func digitLength(_ text: String) -> Int {
        var length = 0
        for scalar in text.unicodeScalars {
            let mapped = asciiEquivalent(of: scalar) ?? scalar
            guard ("0"..."9").contains(mapped) || mapped == "." else { break }
            length += String(scalar).utf8.count
        }
        return length
    }

    /// The type and modifiers of a name the index knows.
    func classify(_ o: DeskOccurrence) -> (DeskSemanticTokenType, DeskSemanticTokenModifiers) {
        var modifiers: DeskSemanticTokenModifiers = []
        if o.role == .declaration { modifiers.insert(.declaration) }
        if o.role == .write { modifiers.insert(.write) }
        if let path = o.path { modifiers.formUnion(flags(path)) }
        let type: DeskSemanticTokenType
        switch o.kind {
        case .variable: type = .variable
        case .saved: type = .saved
        case .computed: type = .computed
        case .loopVariable: type = .loopVariable
        case .element: type = .elementName
        case .style: type = .style
        case .option: type = .option
        case .translationKey: type = .translationKey
        case .asset: type = .string
        case .namespace, .type: type = .namespace
        case .member:
            switch o.path.flatMap({ memberKind($0) }) {
            case .function?: type = .function
            case .action?: type = .action
            default: type = .dataMember
            }
        case .function:
            type = o.path.flatMap({ memberKind($0) }) == .action ? .action : .function
        case .component: type = .component
        case .control: type = .control
        case .modifier: type = .modifier
        case .enumCase: type = .enumCase
        case .label: type = .label
        case .infoField, .packageField: type = .field
        case .formatOption: type = .formatOption
        case .unit: type = .unit
        case .event: type = .event
        }
        return (type, modifiers)
    }

    /// A name the index does not know (code the checker skipped or could not resolve): classified by where it is
    /// written and by the catalog.
    private func fallback(_ token: Token, entry e: Int, position k: Int, siblings: [Token])
        -> (DeskSemanticTokenType, DeskSemanticTokenModifiers) {
        let entry = table.entries[e]
        let name = token.name
        let parentKind: SyntaxKind = entry.parent >= 0 ? table.entries[entry.parent].kind : .sourceFile
        // Which present word of the node this is.
        let words = siblings.prefix(k).filter { !$0.isMissing && ($0.kind == .identifier || $0.kind.isKeyword) }.count
        func builtIn(_ path: CatalogPath, _ type: DeskSemanticTokenType) -> (DeskSemanticTokenType, DeskSemanticTokenModifiers) {
            (type, flags(path))
        }
        func member(_ parts: [String]) -> (DeskSemanticTokenType, DeskSemanticTokenModifiers) {
            if let found = catalog.serviceMember(dotted: parts) {
                switch found.spec.kind {
                case .function: return builtIn(found.path, .function)
                case .action: return builtIn(found.path, .action)
                case .field: return builtIn(found.path, .dataMember)
                }
            }
            return (.dataMember, [])
        }
        switch entry.kind {
        case .infoBlock, .packageBlock, .optionsBlock, .widgetBlock, .translationsBlock, .componentDecl, .scriptBlock,
             .styleDecl:
            if words == 0 { return (.blockWord, []) }
            if entry.kind == .styleDecl { return (.style, [.declaration]) }
            if entry.kind == .componentDecl { return (.component, [.declaration]) }
            return (.label, [])
        case .declaration:
            let keyword = siblings.first?.text.lowercased()
            return (keyword == "saved" ? .saved : keyword == "computed" ? .computed : .variable, [.declaration])
        case .forStmt, .parameter:
            return (entry.kind == .forStmt ? .loopVariable : .variable, [.declaration])
        case .callee:
            let path = siblings.filter { $0.kind == .identifier || $0.kind.isKeyword }.map(\.name)
            if words == 0 {
                if catalog.namespace(named: name) != nil, path.count > 1 { return builtIn(.namespace(name), .namespace) }
                if facts.elementCalls.contains(table.entries[entry.parent].textStart), catalog.component(named: name) != nil {
                    return builtIn(.component(name), .component)
                }
                if parentKind == .callStmt, isInOptions(e), catalog.control(named: name) != nil {
                    return builtIn(.control(name), .control)
                }
                if catalog.component(named: name) != nil { return builtIn(.component(name), .component) }
                if catalog.control(named: name) != nil { return builtIn(.control(name), .control) }
                if let f = catalog.function(named: name) { return builtIn(.function(name), f.kind == .action ? .action : .function) }
                return (token.isUpperName ? .component : .action, [])
            }
            return member(Array(path.prefix(words + 1)))
        case .target:
            let path = siblings.filter { $0.kind == .identifier || $0.kind.isKeyword }.map(\.name)
            if parentKind == .optionDecl { return words == 0 ? (.option, [.declaration]) : (.dataMember, []) }
            if words == 0 {
                if name == "options" || catalog.namespace(named: name) != nil { return (.namespace, []) }
                return (.variable, [.write])
            }
            if path.first == "options", words == 1 { return (.option, [.write]) }
            let (type, modifiers) = member(Array(path.prefix(words + 1)))
            return (type, modifiers.union(.write))
        case .modifierApp:
            if catalog.modifier(named: name) != nil { return builtIn(.modifier(name), .modifier) }
            return (.modifier, [])
        case .label:
            switch parentKind {
            case .field:
                return (.field, [])
            case .formatOption:
                return catalog.index.formatOptions[name] != nil ? builtIn(.formatOption(name), .formatOption) : (.formatOption, [])
            default:
                return (.label, [])
            }
        case .identifierExpr:
            if name == "options" { return (.namespace, []) }
            if catalog.namespace(named: name) != nil { return builtIn(.namespace(name), .namespace) }
            if let f = catalog.function(named: name) { return builtIn(.function(name), f.kind == .action ? .action : .function) }
            return (.variable, [])
        case .memberExpr:
            return (.dataMember, [])
        case .implicitMemberExpr:
            return (.enumCase, [])
        default:
            return (.label, [])
        }
    }

    /// Whether an entry is inside `options { }`.
    private func isInOptions(_ e: Int) -> Bool {
        var p = table.entries[e].parent
        while p >= 0 {
            if table.entries[p].kind == .optionsBlock { return true }
            p = table.entries[p].parent
        }
        return false
    }
}
