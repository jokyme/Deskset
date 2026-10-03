import Foundation

/// Every kind of node in the syntax tree. `block` carries no kind of its own: the checker decides what a block
/// holds (children, actions, modifiers, option items) from what it belongs to.
public enum SyntaxKind: String, Sendable, Hashable, CaseIterable {
    // File
    case sourceFile
    // Top level
    case infoBlock, packageBlock, optionsBlock, widgetBlock, styleDecl, translationsBlock, componentDecl,
         parameterClause, parameter, scriptBlock, strayStatement
    // Blocks and statements
    case block, declaration, ifStmt, elseClause, forStmt, field, entry, group, optionDecl, assignment, target,
         callStmt, callee, modifierStmt, modifierApp, argumentClause, argument, label
    // Expressions
    case ternaryExpr, binaryExpr, prefixExpr, memberExpr, callExpr, implicitMemberExpr, identifierExpr,
         numberLiteral, boolLiteral, stringLiteral, stringText, interpolation, formatOption, listLiteral, parenExpr,
         rangeExpr
    // Recovery
    case unexpected, foreignConstruct

    public var isExpression: Bool {
        switch self {
        case .ternaryExpr, .binaryExpr, .prefixExpr, .memberExpr, .callExpr, .implicitMemberExpr, .identifierExpr,
             .numberLiteral, .boolLiteral, .stringLiteral, .listLiteral, .parenExpr, .rangeExpr:
            return true
        default:
            return false
        }
    }

    public var isStatement: Bool {
        switch self {
        case .declaration, .ifStmt, .forStmt, .field, .entry, .group, .optionDecl, .assignment, .callStmt,
             .modifierStmt, .styleDecl, .componentDecl:
            return true
        default:
            return false
        }
    }

    public var isTopLevelBlock: Bool {
        switch self {
        case .infoBlock, .packageBlock, .optionsBlock, .widgetBlock, .styleDecl, .translationsBlock,
             .componentDecl, .scriptBlock:
            return true
        default:
            return false
        }
    }
}

/// What a `foreignConstruct` node holds: a recognised line, fragment or block from another language.
public enum ForeignKind: String, Sendable, Hashable, CaseIterable {
    /// `[MeterCPU]` (DK9302), `Key=Value` (DK9301), `[!Bang …]` (DK9304), `; note` (DK9013), `#Name#` in an
    /// expression (DK9303).
    case rainmeterSection, rainmeterOption, rainmeterBang, rainmeterComment, rainmeterVariable
    /// `# note` (DK9014).
    case hashComment
    /// `<div>` (DK9201), `<!-- note -->` (DK9014), `flex-direction: row;` (DK9202), `#clock {` (DK9203).
    case htmlTag, htmlComment, cssDeclaration, cssSelector
    /// `let x = 1` (DK9104), `struct X: View {`, `import SwiftUI`, `return` (DK9105), `@State var` (DK9103),
    /// `if let` (DK9110), `func f()`, `while … {` (DK9012), `\(…)` in text (DK9010), `{ value in` (DK9111).
    case swiftDeclaration, swiftStructure, swiftPropertyWrapper, swiftIfLet, functionSyntax, swiftInterpolation
    case closureParameter

    /// Consecutive foreign lines of one family merge into one node.
    public var family: ForeignFamily {
        switch self {
        case .rainmeterSection, .rainmeterOption, .rainmeterBang, .rainmeterComment, .rainmeterVariable: return .rainmeter
        case .htmlTag, .htmlComment: return .html
        case .cssDeclaration, .cssSelector: return .css
        case .swiftDeclaration, .swiftStructure, .swiftPropertyWrapper, .swiftIfLet, .functionSyntax,
             .swiftInterpolation, .closureParameter:
            return .swift
        case .hashComment: return .other
        }
    }
}

public enum ForeignFamily: String, Sendable, Hashable {
    case rainmeter, html, css, swift, other
}

// Node kinds compare and hash by their case, not their raw value (see `TokenKind`).

extension SyntaxKind {
    @inlinable public static func == (a: SyntaxKind, b: SyntaxKind) -> Bool {
        unsafeBitCast(a, to: UInt8.self) == unsafeBitCast(b, to: UInt8.self)
    }
    @inlinable public func hash(into hasher: inout Hasher) { hasher.combine(unsafeBitCast(self, to: UInt8.self)) }
}

extension ForeignKind {
    @inlinable public static func == (a: ForeignKind, b: ForeignKind) -> Bool {
        unsafeBitCast(a, to: UInt8.self) == unsafeBitCast(b, to: UInt8.self)
    }
    @inlinable public func hash(into hasher: inout Hasher) { hasher.combine(unsafeBitCast(self, to: UInt8.self)) }
}

/// A child of a node: a node or a token, in source order.
public enum SyntaxChild: Sendable {
    case node(SyntaxNode)
    case token(Token)

    public var byteLength: Int {
        switch self {
        case .node(let n): return n.byteLength
        case .token(let t): return t.utf8Length
        }
    }

    public var node: SyntaxNode? {
        if case .node(let n) = self { return n }
        return nil
    }

    public var token: Token? {
        if case .token(let t) = self { return t }
        return nil
    }
}

/// An immutable node of the lossless tree: its children in source order, with every byte of the file in exactly
/// one token's text or trivia.
public final class SyntaxNode: @unchecked Sendable {
    public let kind: SyntaxKind
    public private(set) var children: [SyntaxChild]
    /// UTF-8 length including all trivia.
    public let byteLength: Int
    /// For `foreignConstruct` nodes: what was recognised.
    public let foreignKind: ForeignKind?
    /// The number of nodes on the longest path from this node down to a leaf (1 for a node with no child nodes).
    /// Tree walkers that recurse budget their stack by it (StackGuard).
    public let depth: Int

    public init(kind: SyntaxKind, children: [SyntaxChild], foreignKind: ForeignKind? = nil) {
        self.kind = kind
        self.children = children
        self.foreignKind = foreignKind
        var length = 0
        var deepest = 0
        for child in children {
            length += child.byteLength
            if case .node(let n) = child, n.depth > deepest { deepest = n.depth }
        }
        self.byteLength = length
        self.depth = deepest + 1
    }

    // Deep trees (a long `else if` chain, a long sum) are released without recursion.
    deinit {
        var stack: [SyntaxNode] = []
        for child in children {
            if case .node(let n) = child { stack.append(n) }
        }
        guard !stack.isEmpty else { return }
        children = []
        while var node = stack.popLast() {
            if isKnownUniquelyReferenced(&node) {
                for child in node.children {
                    if case .node(let n) = child { stack.append(n) }
                }
                node.children = []
            }
        }
    }

    /// The child nodes, in order.
    public var childNodes: [SyntaxNode] { children.compactMap(\.node) }

    /// The first present token, depth first.
    public var firstToken: Token? { firstToken(present: true) }

    /// The last present token, depth first.
    public var lastToken: Token? { lastToken(present: true) }

    func firstToken(present: Bool) -> Token? {
        var result: Token?
        walkTokens { token, _ in
            if !present || !token.isMissing { result = token; return false }
            return true
        }
        return result
    }

    func lastToken(present: Bool) -> Token? {
        var result: Token?
        walkTokens { token, _ in
            if !present || !token.isMissing { result = token }
            return true
        }
        return result
    }

    /// Visits every token in source order with its offset (the start of its leading trivia, relative to `base`),
    /// without recursion. Return false to stop.
    public func walkTokens(base: Int = 0, _ visit: (Token, Int) -> Bool) {
        var stack: [(SyntaxNode, Int, Int)] = [(self, 0, base)]   // node, next child index, offset of that child
        while !stack.isEmpty {
            let (node, index, offset) = stack[stack.count - 1]
            if index >= node.children.count {
                stack.removeLast()
                continue
            }
            let child = node.children[index]
            stack[stack.count - 1] = (node, index + 1, offset + child.byteLength)
            switch child {
            case .token(let t):
                if !visit(t, offset) { return }
            case .node(let n):
                stack.append((n, 0, offset))
            }
        }
    }

    /// All tokens in source order.
    public var tokens: [Token] {
        var out: [Token] = []
        walkTokens { token, _ in out.append(token); return true }
        return out
    }

    /// The node's text, trivia included.
    public var fullText: String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteLength)
        walkTokens { token, _ in
            for piece in token.leadingTrivia { SyntaxNode.appendTrivia(piece, to: &bytes) }
            bytes.append(contentsOf: token.text.utf8)
            for piece in token.trailingTrivia { SyntaxNode.appendTrivia(piece, to: &bytes) }
            return true
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The node's text without the leading trivia of its first token and the trailing trivia of its last token.
    public var trimmedText: String {
        var bytes: [UInt8] = []
        var tokens: [Token] = []
        walkTokens { token, _ in tokens.append(token); return true }
        guard let first = tokens.firstIndex(where: { !$0.isMissing }),
              let last = tokens.lastIndex(where: { !$0.isMissing }) else { return "" }
        for i in first...last {
            let token = tokens[i]
            if i != first { for piece in token.leadingTrivia { SyntaxNode.appendTrivia(piece, to: &bytes) } }
            bytes.append(contentsOf: token.text.utf8)
            if i != last { for piece in token.trailingTrivia { SyntaxNode.appendTrivia(piece, to: &bytes) } }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func appendTrivia(_ piece: Trivia, to bytes: inout [UInt8]) {
        switch piece {
        case .spaces(let n): bytes.append(contentsOf: repeatElement(0x20, count: n))
        case .tabs(let n): bytes.append(contentsOf: repeatElement(0x09, count: n))
        case .newline(let kind):
            switch kind {
            case .lf: bytes.append(0x0A)
            case .crlf: bytes.append(0x0D); bytes.append(0x0A)
            case .cr: bytes.append(0x0D)
            }
        case .lineComment(let s), .blockComment(let s), .unusualSpace(let s), .invisible(let s):
            bytes.append(contentsOf: s.utf8)
        case .byteOrderMark:
            bytes.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
    }
}

/// `deskVersion` and `requires` as written in `info` or `package`, read from the tree alone (no catalog), so a
/// file of any version can be told what it needs before it is migrated or checked.
public struct FileHeader: Sendable, Hashable {
    public var deskVersion: Int?
    public var requires: AppVersion?

    public init(deskVersion: Int? = nil, requires: AppVersion? = nil) {
        self.deskVersion = deskVersion
        self.requires = requires
    }
}

/// Where the parse of a file used its indentation to repair unbalanced braces. The formatter leaves these parts
/// of the file alone, so formatting never builds on a guess.
struct BraceRepair: Sendable, Hashable {
    /// UTF-8 ranges of the segments whose braces did not balance.
    var segments: [Range<Int>]
}

/// The result of parsing one file: a lossless tree (printing it gives back the text byte for byte), the lexical
/// and syntax diagnostics, and the header.
public struct SyntaxTree: Sendable, CustomStringConvertible {
    public let file: DeskFileID
    /// Kind `.sourceFile`; its last child is the `eof` token.
    public let root: SyntaxNode
    /// The text it was parsed from.
    public let text: String
    /// Increases with every parse; part of every `NodeID`.
    public let version: Int
    /// DK1xxx, DK2xxx and syntax-level DK9xxx diagnostics, sorted by position.
    public let diagnostics: [Diagnostic]
    public let header: FileHeader
    let lines: LineTable
    let repair: BraceRepair

    init(file: DeskFileID, root: SyntaxNode, text: String, version: Int, diagnostics: [Diagnostic],
         header: FileHeader, lines: LineTable, repair: BraceRepair) {
        self.file = file
        self.root = root
        self.text = text
        self.version = version
        self.diagnostics = diagnostics
        self.header = header
        self.lines = lines
        self.repair = repair
    }

    /// The printed tree: equal to `text` for every input.
    public var description: String { root.fullText }

    public var rootNode: PositionedNode { PositionedNode(node: root, offset: 0) }

    /// The deepest node whose text (from its first to its last present token, trivia excluded) contains `offset`.
    public func node(at offset: Int) -> SyntaxNode? {
        positionedNode(at: offset)?.node
    }

    public func positionedNode(at offset: Int) -> PositionedNode? {
        var current = PositionedNode(node: root, offset: 0)
        guard offset >= 0, offset <= root.byteLength else { return nil }
        while true {
            var next: PositionedNode?
            for child in current.children {
                guard case .node(let n) = child else { continue }
                if n.textRange.contains(offset) { next = n; break }
            }
            guard let found = next else { return current }
            current = found
        }
    }

    public func location(of offset: Int) -> SourceLocation {
        lines.location(of: offset)
    }

    /// The node a reference points to, or nil when the reference belongs to another tree version or points at
    /// nothing of that kind. A canonical expression reference also checks its text end; a legacy start-only
    /// reference locates the outermost node of that kind at the start.
    public func resolve(_ id: NodeID) -> PositionedNode? {
        guard id.treeVersion == version else { return nil }
        var stack: [PositionedNode] = [rootNode]
        while let current = stack.popLast() {
            let range = current.range
            guard range.lowerBound <= id.utf8Start, id.utf8Start <= range.upperBound else { continue }
            if current.kind == id.kind {
                let textRange = current.textRange
                if textRange.lowerBound == id.utf8Start,
                   id.utf8End == nil || id.utf8End == textRange.upperBound { return current }
            }
            for child in current.children.reversed() {
                if case .node(let n) = child { stack.append(n) }
            }
        }
        return nil
    }

    /// The reference to a node of this tree.
    public func id(of node: PositionedNode) -> NodeID {
        if node.kind.isExpression {
            let range = node.quickTextRange
            return NodeID(kind: node.kind, utf8Start: range.lowerBound, treeVersion: version, utf8End: range.upperBound)
        }
        return NodeID(kind: node.kind, utf8Start: node.textRange.lowerBound, treeVersion: version)
    }
}

/// A token with its absolute position.
public struct PositionedToken: Sendable {
    public let token: Token
    /// Where its leading trivia starts.
    public let offset: Int

    public var kind: TokenKind { token.kind }
    /// Where its text starts.
    public var textStart: Int { offset + token.leadingTrivia.utf8Length }
    public var textRange: Range<Int> { textStart..<(textStart + token.text.utf8.count) }
    public var range: Range<Int> { offset..<(offset + token.utf8Length) }
}

public enum PositionedChild: Sendable {
    case node(PositionedNode)
    case token(PositionedToken)

    public var node: PositionedNode? {
        if case .node(let n) = self { return n }
        return nil
    }

    public var token: PositionedToken? {
        if case .token(let t) = self { return t }
        return nil
    }
}

/// A node with its absolute position in the file.
public struct PositionedNode: Sendable {
    public let node: SyntaxNode
    /// Where the node's first byte (the leading trivia of its first token) is.
    public let offset: Int

    public init(node: SyntaxNode, offset: Int) {
        self.node = node
        self.offset = offset
    }

    public var kind: SyntaxKind { node.kind }
    /// The full range, trivia included.
    public var range: Range<Int> { offset..<(offset + node.byteLength) }

    public var children: [PositionedChild] {
        var out: [PositionedChild] = []
        out.reserveCapacity(node.children.count)
        var at = offset
        for child in node.children {
            switch child {
            case .node(let n): out.append(.node(PositionedNode(node: n, offset: at)))
            case .token(let t): out.append(.token(PositionedToken(token: t, offset: at)))
            }
            at += child.byteLength
        }
        return out
    }

    public var childNodes: [PositionedNode] { children.compactMap(\.node) }

    /// Tokens in source order, with positions.
    public var tokens: [PositionedToken] {
        var out: [PositionedToken] = []
        node.walkTokens(base: offset) { token, at in
            out.append(PositionedToken(token: token, offset: at))
            return true
        }
        return out
    }

    /// From the first present token's text to the last present token's text; empty at the node's position when it
    /// has no present token.
    public var textRange: Range<Int> {
        var first: Int?
        var last = offset
        node.walkTokens(base: offset) { token, at in
            guard !token.isMissing else { return true }
            let start = at + token.leadingTrivia.utf8Length
            if first == nil { first = start }
            last = start + token.text.utf8.count
            return true
        }
        guard let start = first else {
            // Only missing tokens: the position where they were inserted.
            return offset..<offset
        }
        return start..<last
    }

    /// Range including the leading trivia of the first token but not the trailing trivia of the last.
    public var rangeWithLeadingTrivia: Range<Int> { offset..<textRange.upperBound }

    public func firstChild(_ kind: SyntaxKind) -> PositionedNode? {
        childNodes.first { $0.kind == kind }
    }

    public func children(_ kind: SyntaxKind) -> [PositionedNode] {
        childNodes.filter { $0.kind == kind }
    }

    public func firstToken(_ kind: TokenKind) -> PositionedToken? {
        for child in children {
            if case .token(let t) = child, t.kind == kind { return t }
        }
        return nil
    }
}

extension SyntaxNode {
    /// A one-line outline of the tree for tests and debugging: `kind[child child …]`, tokens by their text, missing
    /// tokens as `‹kind›`, the end of file left out. Trivia are not shown.
    public var outline: String {
        var out = ""
        var justOpened = true
        var stack: [(SyntaxChild, Bool)] = [(.node(self), false)]   // (child, closing marker)
        while let (child, closing) = stack.popLast() {
            if closing { out += "]"; justOpened = false; continue }
            switch child {
            case .token(let token):
                if token.kind == .eof { continue }
                if !justOpened { out += " " }
                out += token.isMissing ? "‹\(token.kind.rawValue)›" : token.text
                justOpened = false
            case .node(let node):
                if !justOpened { out += " " }
                out += node.kind.rawValue
                if let foreign = node.foreignKind { out += ":" + foreign.rawValue }
                out += "["
                justOpened = true
                stack.append((.node(node), true))
                for grandchild in node.children.reversed() { stack.append((grandchild, false)) }
            }
        }
        return out
    }
}
