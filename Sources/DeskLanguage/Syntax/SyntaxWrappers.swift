import Foundation

// Typed views over the untyped tree (§3.1, §3.3 "Child slots"). Each wraps a `PositionedNode` of its kinds and
// exposes the node's named children; `unexpected` children that recovery left between slots are skipped. Slots
// marked "always" in §3.3 are always there (a missing token fills them), so their accessors are not optional.

/// A typed wrapper over one or more node kinds.
public protocol SyntaxWrapper: Sendable {
    static var kinds: Set<SyntaxKind> { get }
    var node: PositionedNode { get }
    init(unchecked node: PositionedNode)
}

extension SyntaxWrapper {
    public init?(_ node: PositionedNode) {
        guard Self.kinds.contains(node.kind) else { return nil }
        self.init(unchecked: node)
    }

    public var range: Range<Int> { node.range }
    public var textRange: Range<Int> { node.textRange }
    public var kind: SyntaxKind { node.kind }
}

extension PositionedNode {
    /// Child tokens (not inside child nodes), in order.
    public var childTokens: [PositionedToken] { children.compactMap(\.token) }

    /// Child nodes other than recovery (`unexpected`) nodes.
    public var significantChildNodes: [PositionedNode] { childNodes.filter { $0.kind != .unexpected } }

    /// The typed wrapper of this node, when it is of the wrapper's kinds.
    public func `as`<W: SyntaxWrapper>(_ type: W.Type) -> W? { W(self) }
}

/// Any expression node.
public struct ExpressionSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.ternaryExpr, .binaryExpr, .prefixExpr, .memberExpr, .callExpr,
                                                .implicitMemberExpr, .identifierExpr, .numberLiteral, .boolLiteral,
                                                .stringLiteral, .listLiteral, .parenExpr, .rangeExpr, .unexpected,
                                                .foreignConstruct]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    /// True for an expression inserted by recovery (no text).
    public var isMissing: Bool { node.kind == .identifierExpr && node.childTokens.first?.token.isMissing == true }
}

// MARK: - File and top level

public struct SourceFileSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.sourceFile]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    /// Top-level items: blocks, style declarations, stray statements, and recovery nodes.
    public var items: [PositionedNode] { node.childNodes }
    public var eof: PositionedToken { node.childTokens.last! }
}

/// `info`, `options`, `widget`, `translations` and `package` blocks.
public struct TopLevelBlockSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.infoBlock, .packageBlock, .optionsBlock, .widgetBlock,
                                                .translationsBlock]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var keyword: PositionedToken { node.childTokens[0] }
    public var block: BlockSyntax { BlockSyntax(unchecked: node.firstChild(.block)!) }
}

public struct StyleDeclSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.styleDecl]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var keyword: PositionedToken { node.childTokens[0] }
    public var name: PositionedToken { node.childTokens[1] }
    public var block: BlockSyntax { BlockSyntax(unchecked: node.firstChild(.block)!) }
}

public struct ComponentDeclSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.componentDecl]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var keyword: PositionedToken { node.childTokens[0] }
    public var name: PositionedToken { node.childTokens[1] }
    public var parameters: PositionedNode { node.firstChild(.parameterClause)! }
    public var block: BlockSyntax { BlockSyntax(unchecked: node.firstChild(.block)!) }
}

public struct ScriptBlockSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.scriptBlock]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var keyword: PositionedToken { node.childTokens[0] }
    /// The opaque body, from `{` to its matching `}`.
    public var body: PositionedToken { node.childTokens[1] }
}

public struct StrayStatementSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.strayStatement]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var statement: PositionedNode { node.childNodes[0] }
}

// MARK: - Blocks and statements

public struct BlockSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.block]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var lBrace: PositionedToken { node.childTokens.first! }
    public var rBrace: PositionedToken { node.childTokens.last! }
    /// The statements, in order; separators and recovery nodes are not included.
    public var statements: [PositionedNode] { node.significantChildNodes }
    /// Statements and recovery nodes, in order.
    public var items: [PositionedNode] { node.childNodes }
    /// Whether both braces were written.
    public var isClosed: Bool { !lBrace.token.isMissing && !rBrace.token.isMissing }
}

public struct DeclarationSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.declaration]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    /// `variable`, `saved` or `computed`.
    public var keyword: PositionedToken { node.childTokens[0] }
    public var name: PositionedToken { node.childTokens[1] }
    public var equal: PositionedToken { node.childTokens[2] }
    public var initializer: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes.last!) }
}

public struct IfStmtSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.ifStmt]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var ifKeyword: PositionedToken { node.childTokens[0] }
    public var condition: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var block: BlockSyntax { BlockSyntax(unchecked: node.firstChild(.block)!) }
    public var elseClause: ElseClauseSyntax? { node.firstChild(.elseClause).map(ElseClauseSyntax.init(unchecked:)) }
    /// Modifiers written after the `}` (always DK2032).
    public var modifiers: [ModifierAppSyntax] { node.children(.modifierApp).map(ModifierAppSyntax.init(unchecked:)) }
}

public struct ElseClauseSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.elseClause]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var elseKeyword: PositionedToken { node.childTokens[0] }
    /// An `ifStmt` (`else if`) or a `block`.
    public var body: PositionedNode { node.childNodes[0] }
}

public struct ForStmtSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.forStmt]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var forKeyword: PositionedToken { node.childTokens[0] }
    public var variable: PositionedToken { node.childTokens[1] }
    public var inKeyword: PositionedToken { node.childTokens[2] }
    public var source: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var block: BlockSyntax { BlockSyntax(unchecked: node.firstChild(.block)!) }
    public var modifiers: [ModifierAppSyntax] { node.children(.modifierApp).map(ModifierAppSyntax.init(unchecked:)) }
}

public struct LabelSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.label]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var token: PositionedToken { node.childTokens[0] }
    public var name: String { token.token.text }
}

/// `name: value` in `info` and `package`.
public struct FieldSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.field]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var label: LabelSyntax { LabelSyntax(unchecked: node.firstChild(.label)!) }
    public var colon: PositionedToken { node.childTokens[0] }
    public var value: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes.last!) }
}

/// `"source": "translation"` (or `=`, which the formatter writes as `:`).
public struct EntrySyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.entry]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var key: StringLiteralSyntax { StringLiteralSyntax(unchecked: node.childNodes[0]) }
    public var separator: PositionedToken { node.childTokens[0] }
    public var value: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes.last!) }
}

/// `"zh-Hans" { … }` (a `:` after the tag is accepted; the formatter removes it).
public struct GroupSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.group]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var tag: StringLiteralSyntax { StringLiteralSyntax(unchecked: node.childNodes[0]) }
    public var colon: PositionedToken? { node.childTokens.first }
    public var block: BlockSyntax { BlockSyntax(unchecked: node.firstChild(.block)!) }
}

/// `name = Control(…)` in `options`.
public struct OptionDeclSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.optionDecl]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var target: TargetSyntax { TargetSyntax(unchecked: node.firstChild(.target)!) }
    public var equal: PositionedToken { node.childTokens[0] }
    /// A `callStmt` (the control), or any other value for the checker to report.
    public var control: PositionedNode { node.childNodes.last! }
    public var controlCall: CallStmtSyntax? { CallStmtSyntax(control) }
}

/// `target = value`; a compound (`+=`) or increment (`++`) operator in the `equal` slot was reported
/// (DK7004, DK7005).
public struct AssignmentSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.assignment]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var target: TargetSyntax { TargetSyntax(unchecked: node.firstChild(.target)!) }
    public var equal: PositionedToken { node.childTokens[0] }
    public var value: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes.last!) }
    public var isPlainAssignment: Bool { equal.kind == .equal }
}

/// A name path: `x`, `options.x`, `volume.level`.
public struct TargetSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.target, .callee]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var name: PositionedToken { node.childTokens[0] }
    /// The names after the first, each after a `.`.
    public var members: [PositionedToken] {
        let tokens = node.childTokens
        return stride(from: 2, to: tokens.count, by: 2).map { tokens[$0] }
    }
    /// The path as written without trivia: `music.next`.
    public var path: [String] { [name.token.text] + members.map(\.token.text) }
}

public typealias CalleeSyntax = TargetSyntax

/// An element, control, `Section`, menu item or action call: callee, arguments, block, modifiers.
public struct CallStmtSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.callStmt]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var callee: CalleeSyntax { CalleeSyntax(unchecked: node.firstChild(.callee)!) }
    public var arguments: ArgumentClauseSyntax? {
        node.firstChild(.argumentClause).map(ArgumentClauseSyntax.init(unchecked:))
    }
    public var block: BlockSyntax? { node.firstChild(.block).map(BlockSyntax.init(unchecked:)) }
    public var modifiers: [ModifierAppSyntax] { node.children(.modifierApp).map(ModifierAppSyntax.init(unchecked:)) }
}

/// The spec's name for a call statement in view context.
public typealias ViewCallSyntax = CallStmtSyntax

/// A chain of modifiers with no element before it: a style body, a `.hover` body.
public struct ModifierStmtSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.modifierStmt]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var modifiers: [ModifierAppSyntax] { node.children(.modifierApp).map(ModifierAppSyntax.init(unchecked:)) }
}

/// `.name(arguments) { block }`.
public struct ModifierAppSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.modifierApp]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var dot: PositionedToken { node.childTokens[0] }
    public var name: PositionedToken { node.childTokens[1] }
    public var arguments: ArgumentClauseSyntax? {
        node.firstChild(.argumentClause).map(ArgumentClauseSyntax.init(unchecked:))
    }
    public var block: BlockSyntax? { node.firstChild(.block).map(BlockSyntax.init(unchecked:)) }
}

public struct ArgumentClauseSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.argumentClause]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var lParen: PositionedToken { node.childTokens.first! }
    public var rParen: PositionedToken { node.childTokens.last! }
    public var arguments: [ArgumentSyntax] { node.children(.argument).map(ArgumentSyntax.init(unchecked:)) }
}

/// `label: value` or `value`; `label = value` is kept for the checker (DK2035, DK2037).
public struct ArgumentSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.argument]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var label: LabelSyntax? { node.firstChild(.label).map(LabelSyntax.init(unchecked:)) }
    /// `:`, or a diagnosed `=`.
    public var colon: PositionedToken? { node.childTokens.first }
    public var value: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes.last!) }
}

// MARK: - Expressions

public struct TernaryExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.ternaryExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var condition: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var question: PositionedToken { node.childTokens[0] }
    public var then: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[1]) }
    public var colon: PositionedToken { node.childTokens[1] }
    public var otherwise: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[2]) }
}

/// `left op right`. Besides Desk's operators, the operator may be a diagnosed one: `&&`, `||`, `??`, `**` (reported
/// by the parser), `=` (DK2026), or `&`, `|`, `^` (reported by the checker).
public struct BinaryExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.binaryExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var left: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var `operator`: PositionedToken { node.childTokens[0] }
    public var right: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[1]) }
}

/// `-x`, `not x`; or a diagnosed `!x` (DK9003), `+x` (DK2006), `~x` (checker).
public struct PrefixExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.prefixExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var `operator`: PositionedToken { node.childTokens[0] }
    public var operand: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
}

public struct RangeExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.rangeExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var low: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    /// `...`, or a diagnosed `..<` (DK9009) or `..`.
    public var ellipsis: PositionedToken { node.childTokens[0] }
    public var high: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[1]) }
}

/// `base.name`; a diagnosed `?` (DK9005) may sit between the base and the dot.
public struct MemberExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.memberExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var base: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var dot: PositionedToken { node.childTokens[0] }
    public var name: PositionedToken { node.childTokens[1] }
}

public struct CallExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.callExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var callee: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var arguments: ArgumentClauseSyntax { ArgumentClauseSyntax(unchecked: node.childNodes[1]) }
}

/// `.caption`, `.color(light: …, dark: …)`.
public struct ImplicitMemberExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.implicitMemberExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var dot: PositionedToken { node.childTokens[0] }
    public var name: PositionedToken { node.childTokens[1] }
    public var arguments: ArgumentClauseSyntax? {
        node.firstChild(.argumentClause).map(ArgumentClauseSyntax.init(unchecked:))
    }
}

/// A name used as a value. The token may be an `invalidIdentifier` (already reported, DK1007) or `event`; a
/// diagnosed `$` (DK9106) may precede it.
public struct IdentifierExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.identifierExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var token: PositionedToken { node.childTokens.last! }
    public var name: String { token.token.name }
}

/// A number with its unit. A unit written after a space (`2 s`, DK1028) is kept as an `unexpected` child, and
/// `unitAfterSpace` gives it, so the value keeps its meaning.
public struct NumberLiteralSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.numberLiteral]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var token: PositionedToken { node.childTokens[0] }
    /// The value without its unit (`.5` reads as 0.5; not finite → nil).
    public var value: Double? { token.token.numberValue }
    public var unit: UnitSpelling? {
        if let unit = token.token.unit { return unit }
        return unitAfterSpace
    }
    /// The unit of `2 s` (reported DK1028 / DK1021), classified like a unit written right after the digits.
    public var unitAfterSpace: UnitSpelling? {
        guard let extra = node.firstChild(.unexpected)?.childTokens.first else { return nil }
        return UnitTable.spelling(extra.token.text)
    }
}

public struct BoolLiteralSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.boolLiteral]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var token: PositionedToken { node.childTokens[0] }
    public var value: Bool { token.token.name.lowercased() == "true" }
}

public struct ListLiteralSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.listLiteral]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var lBracket: PositionedToken { node.childTokens.first! }
    public var rBracket: PositionedToken { node.childTokens.last! }
    public var elements: [ExpressionSyntax] { node.significantChildNodes.map(ExpressionSyntax.init(unchecked:)) }
}

public struct ParenExprSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.parenExpr]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var lParen: PositionedToken { node.childTokens.first! }
    public var value: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var rParen: PositionedToken { node.childTokens.last! }
}

/// `{value, label: option}` inside a string.
public struct InterpolationSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.interpolation]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var start: PositionedToken { node.childTokens.first! }
    public var value: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes[0]) }
    public var formatOptions: [FormatOptionSyntax] {
        node.children(.formatOption).map(FormatOptionSyntax.init(unchecked:))
    }
    public var end: PositionedToken { node.childTokens.last! }
}

/// `, label: value` in an interpolation; a diagnosed `=` (DK2035) may stand for the colon.
public struct FormatOptionSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.formatOption]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var comma: PositionedToken { node.childTokens[0] }
    public var label: LabelSyntax { LabelSyntax(unchecked: node.firstChild(.label)!) }
    public var colon: PositionedToken { node.childTokens[1] }
    public var value: ExpressionSyntax { ExpressionSyntax(unchecked: node.childNodes.last!) }
}

/// Text in quotes: an ordinary string with text segments and interpolations, or one raw (`#"…"#`) or triple-quoted
/// (DK1017) token.
public struct StringLiteralSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.stringLiteral]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }

    public enum Segment: Sendable {
        /// Raw text as written (escapes included) and its cooked value.
        case text(PositionedToken, cooked: String)
        case interpolation(InterpolationSyntax)
        /// Swift's `\(…)` (DK9010).
        case foreign(PositionedNode)
    }

    /// `"`, a curly quote (DK1001), or the raw or triple-quoted token itself.
    public var start: PositionedToken { node.childTokens.first! }
    /// The closing quote; missing when the string is not closed (DK1010).
    public var end: PositionedToken? { node.childTokens.count > 1 ? node.childTokens.last : nil }
    public var isRaw: Bool { start.kind == .rawString }
    public var isTripleQuoted: Bool { start.kind == .tripleQuoteString }
    /// A string that looks like a Windows path; the checker reports it once (DK9307 or DK1012).
    public var isWindowsPath: Bool { start.token.flags.contains(.windowsPath) }

    public var segments: [Segment] {
        if isRaw || isTripleQuoted { return [] }
        return node.childNodes.compactMap { child in
            switch child.kind {
            case .stringText:
                guard let token = child.childTokens.first else { return nil }
                return .text(token, cooked: StringLiteralSyntax.cook(token.token.text))
            case .interpolation: return .interpolation(InterpolationSyntax(unchecked: child))
            case .foreignConstruct: return .foreign(child)
            default: return nil
            }
        }
    }

    /// The value when the string has no interpolation (nil otherwise).
    public var literalValue: String? { StringLiteralSyntax.literalValue(of: node.node) }

    /// The cooked value of a string literal node without interpolations.
    public static func literalValue(of node: SyntaxNode) -> String? {
        guard node.kind == .stringLiteral, let first = node.children.first?.token else { return nil }
        switch first.kind {
        case .rawString:
            var text = Substring(first.text)
            if text.hasPrefix("#\"") { text = text.dropFirst(2) }
            if text.hasSuffix("\"#") && !first.flags.contains(.unterminated) { text = text.dropLast(2) }
            return String(text)
        case .tripleQuoteString:
            var text = Substring(first.text)
            if text.hasPrefix("\"\"\"") { text = text.dropFirst(3) }
            if text.hasSuffix("\"\"\"") && !first.flags.contains(.unterminated) { text = text.dropLast(3) }
            return String(text)
        default:
            var value = ""
            for child in node.children {
                guard case .node(let segment) = child else { continue }
                guard segment.kind == .stringText, let token = segment.children.first?.token else { return nil }
                value += cook(token.text)
            }
            return value
        }
    }

    /// The value of a text segment written with escapes (§1.8): `\" \\ \n \t \u{…}`, `{{` and `}}`. An unknown
    /// escape (DK1012) stands for the character after the backslash, so `\{` is a literal `{`.
    public static func cook(_ raw: String) -> String {
        guard raw.contains("\\") || raw.contains("{{") || raw.contains("}}") else { return raw }
        var out = String.UnicodeScalarView()
        let scalars = Array(raw.unicodeScalars)
        var k = 0
        while k < scalars.count {
            let s = scalars[k]
            if s == "\\", k + 1 < scalars.count {
                let c = scalars[k + 1]
                switch c {
                case "n": out.append("\n"); k += 2
                case "t": out.append("\t"); k += 2
                case "u" where k + 2 < scalars.count && scalars[k + 2] == "{":
                    var m = k + 3
                    var hex = ""
                    while m < scalars.count, scalars[m] != "}", hex.count <= 6 { hex.unicodeScalars.append(scalars[m]); m += 1 }
                    if m < scalars.count, scalars[m] == "}", let value = UInt32(hex, radix: 16),
                       let scalar = Unicode.Scalar(value) {
                        out.append(scalar)
                        k = m + 1
                    } else {
                        out.append("u")
                        k += 2
                    }
                default:
                    out.append(c)
                    k += 2
                }
                continue
            }
            if (s == "{" || s == "}"), k + 1 < scalars.count, scalars[k + 1] == s {
                out.append(s)
                k += 2
                continue
            }
            out.append(s)
            k += 1
        }
        return String(out)
    }
}

public struct UnexpectedSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.unexpected]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var tokens: [PositionedToken] { node.tokens }
}

/// A recognised line, fragment or block from another language.
public struct ForeignConstructSyntax: SyntaxWrapper {
    public static let kinds: Set<SyntaxKind> = [.foreignConstruct]
    public let node: PositionedNode
    public init(unchecked node: PositionedNode) { self.node = node }
    public var foreignKind: ForeignKind? { node.node.foreignKind }
    public var tokens: [PositionedToken] { node.tokens }
}
