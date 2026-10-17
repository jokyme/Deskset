import Foundation
@testable import DeskLanguage

// Helpers shared by the "Desk: …" syntax suites.

/// The repository root (for fixtures under TestSkins/Desk and the source layering check).
let deskRepositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

let deskFixtures = deskRepositoryRoot.appendingPathComponent("TestSkins/Desk")

func deskParse(_ text: String, file: String = "Test.desk") -> SyntaxTree {
    Desk.parse(text, file: DeskFileID(path: file))
}

/// The ids of a tree's diagnostics, in order.
func deskIDs(_ tree: SyntaxTree) -> [String] { tree.diagnostics.map(\.id.rawValue) }

/// Only the errors' ids.
func deskErrorIDs(_ tree: SyntaxTree) -> [String] {
    tree.diagnostics.filter { $0.severity == .error }.map(\.id.rawValue)
}

/// Every fixture file under TestSkins/Desk with its text (sorted by path).
func deskFixtureFiles(_ subfolder: String? = nil) -> [(path: String, text: String)] {
    let root = subfolder.map { deskFixtures.appendingPathComponent($0) } ?? deskFixtures
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var files: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "desk" {
        guard let data = try? Data(contentsOf: url) else { continue }
        let relative = url.path.replacingOccurrences(of: deskFixtures.path + "/", with: "")
        files.append((relative, String(decoding: data, as: UTF8.self)))
    }
    return files.sorted { $0.0 < $1.0 }
}

/// The tree invariants of §9.2: the printed tree is the text; token lengths add up to the text length; every
/// missing token is empty and has no trivia; no trivia holds a non-trivia character; nodes' lengths add up.
func deskTreeProblems(_ tree: SyntaxTree) -> [String] {
    var problems: [String] = []
    if tree.description != tree.text { problems.append("round trip differs") }
    var total = 0
    var stack: [SyntaxNode] = [tree.root]
    while let node = stack.popLast() {
        var sum = 0
        for child in node.children {
            switch child {
            case .node(let n):
                sum += n.byteLength
                stack.append(n)
            case .token(let t):
                sum += t.utf8Length
                total += t.utf8Length
                if t.isMissing && (!t.text.isEmpty || !t.leadingTrivia.isEmpty || !t.trailingTrivia.isEmpty) {
                    problems.append("missing token \(t.kind) has text or trivia")
                }
                for piece in t.leadingTrivia + t.trailingTrivia {
                    if let bad = deskTriviaProblem(piece) { problems.append(bad) }
                }
            }
        }
        if sum != node.byteLength { problems.append("\(node.kind) length \(node.byteLength) != children \(sum)") }
    }
    if total != tree.text.utf8.count { problems.append("tokens \(total) bytes, text \(tree.text.utf8.count)") }
    if tree.root.children.last?.token?.kind != .eof { problems.append("the last child is not eof") }
    return problems
}

func deskTriviaProblem(_ piece: Trivia) -> String? {
    switch piece {
    case .spaces(let n): return n > 0 ? nil : "empty spaces"
    case .tabs(let n): return n > 0 ? nil : "empty tabs"
    case .newline: return nil
    case .lineComment(let s):
        if !s.utf8.starts(with: "//".utf8) || s.utf8.contains(0x0A) || s.utf8.contains(0x0D) {
            return "bad line comment \(s.debugDescription)"
        }
    case .blockComment(let s):
        if !s.utf8.starts(with: "/*".utf8) { return "bad block comment \(s.debugDescription)" }
    case .unusualSpace(let s):
        if s.isEmpty || !s.unicodeScalars.allSatisfy({ $0.value > 0x7F }) { return "bad unusual space" }
    case .invisible(let s):
        if s.isEmpty || !s.unicodeScalars.allSatisfy({ $0.value > 0x7F }) { return "bad invisible" }
    case .byteOrderMark: return nil
    }
    return nil
}

/// The shape of a tree's diagnostics: ranges inside the text on character boundaries; fix-it title and note keys the
/// catalog knows (`SyntaxMessageKeys`); edits in the same file, inside the text, on character boundaries and not
/// overlapping; the only fix-it without edits is "Jump to line", with its line.
func deskDiagnosticProblems(_ tree: SyntaxTree) -> [String] {
    let bytes = Array(tree.text.utf8)
    func boundary(_ offset: Int) -> Bool {
        offset >= 0 && offset <= bytes.count && (offset == bytes.count || bytes[offset] & 0xC0 != 0x80)
    }
    let titles = Set(SyntaxMessageKeys.fixItTitles)
    let notes = Set(SyntaxMessageKeys.notes)
    var problems: [String] = []
    for d in tree.diagnostics {
        let name = d.id.rawValue
        if d.file != tree.file { problems.append("\(name) in another file") }
        if !boundary(d.range.lowerBound) || !boundary(d.range.upperBound) { problems.append("\(name) range \(d.range)") }
        for note in d.notes where !notes.contains(note.messageKey) { problems.append("\(name) note \(note.messageKey)") }
        for fixIt in d.fixIts {
            if !titles.contains(fixIt.titleKey) { problems.append("\(name) fix-it title \(fixIt.titleKey)") }
            if fixIt.edits.isEmpty {
                if fixIt.titleKey != "jumpToLine" || fixIt.titleArguments["line"] == nil {
                    problems.append("\(name) \(fixIt.titleKey) has no edits")
                }
                continue
            }
            let edits = fixIt.edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var end = 0
            for edit in edits {
                if edit.file != tree.file { problems.append("\(name) edit in another file") }
                if !boundary(edit.range.lowerBound) || !boundary(edit.range.upperBound) {
                    problems.append("\(name) \(fixIt.titleKey) edit \(edit.range)")
                }
                if edit.range.lowerBound < end { problems.append("\(name) \(fixIt.titleKey) edits overlap") }
                end = max(end, edit.range.upperBound)
            }
        }
    }
    return problems
}

/// Reads every slot of the typed wrapper of every node (§3.3 "Child slots"), whatever recovery did to the tree: the
/// checker reads broken trees through these wrappers, so they must never trap, and each slot must hold what its type
/// says (an expression slot an expression, a block slot a block…).
func deskWrapperProblems(_ tree: SyntaxTree) -> [String] {
    var problems: [String] = []
    func expect(_ node: PositionedNode, _ kinds: Set<SyntaxKind>, _ slot: String) {
        if !kinds.contains(node.kind) { problems.append("\(slot) holds \(node.kind)") }
    }
    func expression(_ e: ExpressionSyntax, _ slot: String) { expect(e.node, ExpressionSyntax.kinds, slot) }
    func token(_ t: PositionedToken, _ kinds: Set<TokenKind>, _ slot: String) {
        if !kinds.contains(t.kind) { problems.append("\(slot) is a \(t.kind) token") }
    }
    func block(_ b: BlockSyntax, _ slot: String) {
        token(b.lBrace, [.lBrace], slot + ".lBrace")
        token(b.rBrace, [.rBrace], slot + ".rBrace")
        for statement in b.statements where !statement.kind.isStatement && statement.kind != .foreignConstruct {
            problems.append("\(slot) holds a \(statement.kind) statement")
        }
    }
    func arguments(_ clause: ArgumentClauseSyntax, _ slot: String) {
        token(clause.lParen, [.lParen], slot + ".lParen")
        token(clause.rParen, [.rParen], slot + ".rParen")
        for argument in clause.arguments {
            if let label = argument.label, !label.token.kind.isWord && label.token.kind != .invalidIdentifier {
                problems.append("\(slot) label is a \(label.token.kind)")
            }
            if argument.label != nil, argument.colon == nil { problems.append("\(slot) label without a colon") }
            expression(argument.value, slot + ".value")
        }
    }
    let names: Set<TokenKind> = Set(TokenKind.allCases.filter { $0.isWord }).union([.invalidIdentifier])
    var stack: [PositionedNode] = [tree.rootNode]
    while let node = stack.popLast() {
        stack.append(contentsOf: node.childNodes)
        switch node.kind {
        case .sourceFile:
            token(SourceFileSyntax(node)!.eof, [.eof], "sourceFile.eof")
        case .infoBlock, .packageBlock, .optionsBlock, .widgetBlock, .translationsBlock:
            let w = TopLevelBlockSyntax(node)!
            token(w.keyword, [.identifier], "\(node.kind).keyword")
            block(w.block, "\(node.kind).block")
        case .styleDecl:
            let w = StyleDeclSyntax(node)!
            token(w.keyword, [.identifier], "styleDecl.keyword")
            token(w.name, names, "styleDecl.name")
            block(w.block, "styleDecl.block")
        case .componentDecl:
            let w = ComponentDeclSyntax(node)!
            token(w.name, names, "componentDecl.name")
            expect(w.parameters, [.parameterClause], "componentDecl.parameters")
            block(w.block, "componentDecl.block")
        case .scriptBlock:
            token(ScriptBlockSyntax(node)!.body, [.opaqueBlock], "scriptBlock.body")
        case .strayStatement:
            let statement = StrayStatementSyntax(node)!.statement
            if !statement.kind.isStatement { problems.append("strayStatement holds \(statement.kind)") }
        case .block:
            block(BlockSyntax(node)!, "block")
        case .declaration:
            let w = DeclarationSyntax(node)!
            token(w.keyword, [.variableKeyword, .savedKeyword, .computedKeyword, .identifier], "declaration.keyword")
            token(w.name, names, "declaration.name")
            token(w.equal, [.equal], "declaration.equal")
            expression(w.initializer, "declaration.initializer")
        case .ifStmt:
            let w = IfStmtSyntax(node)!
            expression(w.condition, "ifStmt.condition")
            block(w.block, "ifStmt.block")
            if let e = w.elseClause {
                if ![.ifStmt, .block, .unexpected].contains(e.body.kind) { problems.append("else holds \(e.body.kind)") }
            }
            _ = w.modifiers.map(\.name)
        case .forStmt:
            let w = ForStmtSyntax(node)!
            token(w.variable, names, "forStmt.variable")
            token(w.inKeyword, [.inKeyword, .identifier], "forStmt.in")
            expression(w.source, "forStmt.source")
            block(w.block, "forStmt.block")
        case .field:
            let w = FieldSyntax(node)!
            token(w.colon, [.colon], "field.colon")
            expression(w.value, "field.value")
        case .entry:
            let w = EntrySyntax(node)!
            expect(w.key.node, [.stringLiteral], "entry.key")
            token(w.separator, [.colon, .equal], "entry.separator")
            expression(w.value, "entry.value")
        case .group:
            let w = GroupSyntax(node)!
            expect(w.tag.node, [.stringLiteral], "group.tag")
            block(w.block, "group.block")
        case .optionDecl:
            let w = OptionDeclSyntax(node)!
            _ = w.target.path
            token(w.equal, [.equal], "optionDecl.equal")
            if w.control.kind != .callStmt { expect(w.control, ExpressionSyntax.kinds, "optionDecl.control") }
        case .assignment:
            let w = AssignmentSyntax(node)!
            _ = w.target.path
            token(w.equal, [.equal, .plusEqual, .minusEqual, .starEqual, .slashEqual, .plusPlus, .minusMinus],
                  "assignment.equal")
            expression(w.value, "assignment.value")
        case .callStmt:
            let w = CallStmtSyntax(node)!
            _ = w.callee.path
            if let clause = w.arguments { arguments(clause, "callStmt.arguments") }
            if let b = w.block { block(b, "callStmt.block") }
            for m in w.modifiers { token(m.dot, [.dot], "callStmt.modifier.dot") }
        case .modifierStmt:
            if ModifierStmtSyntax(node)!.modifiers.isEmpty { problems.append("modifierStmt without modifiers") }
        case .modifierApp:
            let w = ModifierAppSyntax(node)!
            token(w.dot, [.dot], "modifierApp.dot")
            token(w.name, names, "modifierApp.name")
            if let clause = w.arguments { arguments(clause, "modifierApp.arguments") }
            if let b = w.block { block(b, "modifierApp.block") }
        case .ternaryExpr:
            let w = TernaryExprSyntax(node)!
            expression(w.condition, "ternary.condition")
            token(w.question, [.question], "ternary.question")
            expression(w.then, "ternary.then")
            token(w.colon, [.colon], "ternary.colon")
            expression(w.otherwise, "ternary.otherwise")
        case .binaryExpr:
            let w = BinaryExprSyntax(node)!
            expression(w.left, "binary.left")
            _ = w.operator
            expression(w.right, "binary.right")
        case .prefixExpr:
            let w = PrefixExprSyntax(node)!
            _ = w.operator
            expression(w.operand, "prefix.operand")
        case .rangeExpr:
            let w = RangeExprSyntax(node)!
            expression(w.low, "range.low")
            token(w.ellipsis, [.ellipsis, .dotDot, .dotDotLess], "range.ellipsis")
            expression(w.high, "range.high")
        case .memberExpr:
            let w = MemberExprSyntax(node)!
            expression(w.base, "member.base")
            token(w.dot, [.dot], "member.dot")
            token(w.name, names, "member.name")
        case .callExpr:
            let w = CallExprSyntax(node)!
            expression(w.callee, "call.callee")
            arguments(w.arguments, "call.arguments")
        case .implicitMemberExpr:
            let w = ImplicitMemberExprSyntax(node)!
            token(w.dot, [.dot], "implicitMember.dot")
            token(w.name, names, "implicitMember.name")
            if let clause = w.arguments { arguments(clause, "implicitMember.arguments") }
        case .identifierExpr:
            _ = IdentifierExprSyntax(node)!.name
        case .numberLiteral:
            let w = NumberLiteralSyntax(node)!
            token(w.token, [.number], "number.token")
            _ = w.value
            _ = w.unit
        case .boolLiteral:
            _ = BoolLiteralSyntax(node)!.value
        case .stringLiteral:
            let w = StringLiteralSyntax(node)!
            token(w.start, [.stringStart, .rawString, .tripleQuoteString], "string.start")
            if let end = w.end { token(end, [.stringEnd], "string.end") }
            for segment in w.segments {
                if case .interpolation(let i) = segment {
                    token(i.start, [.interpolationStart], "interpolation.start")
                    token(i.end, [.interpolationEnd], "interpolation.end")
                    expression(i.value, "interpolation.value")
                    for option in i.formatOptions {
                        token(option.comma, [.comma], "formatOption.comma")
                        token(option.colon, [.colon, .equal], "formatOption.colon")
                        expression(option.value, "formatOption.value")
                    }
                }
            }
            _ = w.literalValue
        case .listLiteral:
            let w = ListLiteralSyntax(node)!
            token(w.lBracket, [.lBracket], "list.lBracket")
            token(w.rBracket, [.rBracket], "list.rBracket")
            for element in w.elements { expression(element, "list.element") }
        case .parenExpr:
            let w = ParenExprSyntax(node)!
            token(w.lParen, [.lParen], "paren.lParen")
            expression(w.value, "paren.value")
            token(w.rParen, [.rParen], "paren.rParen")
        default:
            break
        }
    }
    return problems
}

/// Applies a fix-it's edits to a text.
func deskApply(_ fixIt: FixIt, to text: String) -> String { TextEdit.apply(fixIt.edits, to: text) }

/// A deterministic generator for fuzzing and generated corpora (seeded, printed on failure).
struct DeskRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
}

/// The tokens formatting must keep (F12), in order: every non-trivia token, except the `;` and `,` separators of
/// blocks (which may become line breaks) and a language group's `:` (removed); a translation entry's `=` reads as `:`.
func deskSignificantTokens(_ tree: SyntaxTree) -> [String] {
    var out: [String] = []
    var stack: [(node: SyntaxNode, next: Int)] = [(tree.root, 0)]
    while !stack.isEmpty {
        let (node, next) = stack[stack.count - 1]
        guard next < node.children.count else { stack.removeLast(); continue }
        stack[stack.count - 1].next += 1
        switch node.children[next] {
        case .node(let child):
            stack.append((child, 0))
        case .token(let t):
            if t.isMissing || t.kind == .eof { continue }
            if (node.kind == .block || node.kind == .sourceFile) && (t.kind == .semicolon || t.kind == .comma) { continue }
            if node.kind == .group && t.kind == .colon { continue }
            if node.kind == .entry && t.kind == .equal { out.append("colon::"); continue }
            out.append("\(t.kind.rawValue):\(t.text)")
        }
    }
    return out
}
