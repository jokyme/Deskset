import Foundation

/// An editor operation that needs only the text (§3.7). Each becomes the smallest set of text edits; bytes outside
/// them never change. References are `NodeID`s of the tree the edit is applied to; a reference from another tree
/// version is refused, never guessed.
public enum SyntaxEdit: Sendable {
    /// Replaces one argument's value (its label stays). A plain number replacing a number with a unit keeps the
    /// unit (`12pt` → `14pt`).
    case setArgument(ArgumentRef, newText: String)
    case removeModifier(ModifierRef)
    /// Replaces the value of an `info` / `package` field.
    case setField(FieldRef, newText: String)
    /// Inserts a statement (one or more lines of Desk text) as the `index`-th statement of a block. The reference
    /// may also be the source file (kind `.sourceFile`), to insert a top-level item.
    case insertStatement(BlockRef, index: Int, text: String)
    case removeStatement(StatementRef)
    case moveStatement(StatementRef, to: BlockRef, index: Int)
    /// Wraps consecutive statements of one block in a container (`"Freeform"`, `"Column"`, `"Row"`).
    case wrap([StatementRef], container: String)
    /// Replaces a container with its children; the container's own modifiers go with it.
    case unwrap(StatementRef)
}

/// Why an edit was refused.
public enum EditFailure: Error, Sendable, Hashable {
    /// The reference belongs to another version of the tree.
    case staleReference
    /// No node of the reference's kind starts there.
    case notFound
    /// The edit does not apply: an index out of range, statements that are not consecutive siblings, a move into
    /// the moved statement, a container with no block…
    case notApplicable(String)
}

/// The result of one editor operation: one undo step.
public struct EditResult: Sendable {
    public var edits: [TextEdit]
    /// The tree of the edited text (the original tree when the edit was refused).
    public var tree: SyntaxTree
    public var diagnostics: [Diagnostic]
    /// Statements moved or wrapped: where their text was, and where it is in the new text (§7.8).
    public var moves: [TextMove]
    public var failure: EditFailure?

    public init(edits: [TextEdit], tree: SyntaxTree, diagnostics: [Diagnostic], moves: [TextMove],
                failure: EditFailure? = nil) {
        self.edits = edits
        self.tree = tree
        self.diagnostics = diagnostics
        self.moves = moves
        self.failure = failure
    }
}

extension Desk {
    /// Applies a text-only edit (§3.7) and parses the result.
    public static func apply(_ edit: SyntaxEdit, to tree: SyntaxTree) -> EditResult {
        let editor = SyntaxEditor(tree: tree)
        switch editor.plan(edit) {
        case .failure(let failure):
            return EditResult(edits: [], tree: tree, diagnostics: tree.diagnostics, moves: [], failure: failure)
        case .edits(let edits, let pending):
            let text = TextEdit.apply(edits, to: tree.text)
            let newTree = Desk.parse(text, file: tree.file)
            let moves = pending.map { move -> TextMove in
                if let node = newTree.statement(startingAt: move.newStart, kind: move.kind) {
                    return TextMove(from: move.from, to: node.textRange)
                }
                return TextMove(from: move.from, to: move.newStart..<(move.newStart + move.from.count))
            }
            return EditResult(edits: edits, tree: newTree, diagnostics: newTree.diagnostics, moves: moves)
        }
    }
}

extension Desk {
    /// The formatter's "Sort blocks" command (§2.1), never applied implicitly: the top-level blocks in the
    /// canonical order `info`/`package`, `options`, `widget`, `style`…, `translations` (reserved `component` and
    /// `script` blocks after the styles), each with the comments above it, one blank line between them. A file
    /// whose top level holds anything else (stray statements, code that failed to parse) is left alone.
    public static func sortBlocks(_ tree: SyntaxTree) -> [TextEdit] {
        let editor = SyntaxEditor(tree: tree)
        let items = tree.rootNode.childNodes
        func rank(_ kind: SyntaxKind) -> Int? {
            switch kind {
            case .infoBlock, .packageBlock: return 0
            case .optionsBlock: return 1
            case .widgetBlock: return 2
            case .styleDecl: return 3
            case .componentDecl: return 4
            case .scriptBlock: return 5
            case .translationsBlock: return 6
            default: return nil
            }
        }
        guard items.count > 1, items.allSatisfy({ rank($0.kind) != nil }) else { return [] }
        let extents = items.map(editor.extent(of:))
        guard extents.allSatisfy(\.ownsLines) else { return [] }
        let order = items.indices.sorted { (rank(items[$0].kind)!, $0) < (rank(items[$1].kind)!, $1) }
        guard order != Array(items.indices) else { return [] }
        // Each item takes what stands between the previous item and itself (blank lines, loose comments).
        var regions: [String] = []
        var from = extents[0].range.lowerBound
        for e in extents {
            // Trimmed scalar by scalar: "\r\n" is one Character, which `hasPrefix("\n")` never matches.
            var scalars = Substring(editor.text(from..<e.range.upperBound)).unicodeScalars
            while let f = scalars.first, f == "\n" || f == "\r" { scalars.removeFirst() }
            while let l = scalars.last, l == "\n" || l == "\r" { scalars.removeLast() }
            regions.append(String(scalars))
            from = e.range.upperBound
        }
        let nl = editor.newline
        let sorted = order.map { regions[$0] }.joined(separator: nl + nl) + nl
        let range = extents[0].range.lowerBound..<extents[extents.count - 1].range.upperBound
        return [TextEdit(file: tree.file, range: range, replacement: sorted)]
    }
}

extension Desk {
    /// The text of a number-valued expression moved by `delta`, written the way the author wrote it (§3.7 rule 5,
    /// like the INI editor's `GeometryEdit`): the editor passes it to `.setArgument` after a drag, a resize or a nudge.
    ///
    /// | written | moved by 8 |
    /// |---|---|
    /// | `12`, `12pt`, `-3` | `20`, `20pt`, `5` |
    /// | `title.right + 4`, `title.bottom - 4` | `title.right + 12`, `title.bottom + 4` |
    /// | `title.right - 8` | `title.right` (a constant that reaches 0 goes away) |
    /// | `title.right`, `x * 2` | `title.right + 8`, `x * 2 + 8` |
    /// | `a ? 4 : 8`, `a...b` | `(a ? 4 : 8) + 8`, `(a...b) + 8` |
    /// | missing | `8` |
    public static func offsetText(of expression: ExpressionSyntax, by delta: Double) -> String {
        let written = expression.node.node.trimmedText
        guard delta != 0, delta.isFinite else { return written }
        if expression.isMissing { return OffsetText.number(delta, unit: "") }
        let node = expression.node
        if let constant = OffsetText.constant(node) {
            return OffsetText.number(constant.value + delta, unit: constant.unit)
        }
        if let binary = BinaryExprSyntax(node) {
            let op = binary.operator.token.kind
            if op == .plus || op == .minus, let constant = OffsetText.constant(binary.right.node) {
                let value = (op == .plus ? constant.value : -constant.value) + delta
                let left = binary.left.node.node.trimmedText
                if value == 0 { return left }
                return left + (value < 0 ? " - " : " + ") + OffsetText.number(abs(value), unit: constant.unit)
            }
        }
        return (OffsetText.bindsAtLeastAsTightAsSum(node) ? written : "(" + written + ")")
            + (delta < 0 ? " - " : " + ") + OffsetText.number(abs(delta), unit: "")
    }
}

/// Helpers of `Desk.offsetText`.
enum OffsetText {
    /// A number literal, or `-` and a number literal: its value and its unit as written.
    static func constant(_ node: PositionedNode) -> (value: Double, unit: String)? {
        if let number = NumberLiteralSyntax(node), let value = number.value {
            return (value, number.unit?.text ?? "")
        }
        if let prefix = PrefixExprSyntax(node), prefix.operator.token.kind == .minus,
           let inner = constant(prefix.operand.node), inner.value >= 0,
           NumberLiteralSyntax(prefix.operand.node) != nil {
            return (-inner.value, inner.unit)
        }
        return nil
    }

    /// Whether ` + n` can follow the expression without parentheses: sums, products, prefix `-`, and everything
    /// that binds tighter (§2.9).
    static func bindsAtLeastAsTightAsSum(_ node: PositionedNode) -> Bool {
        switch node.kind {
        case .binaryExpr:
            guard let binary = BinaryExprSyntax(node) else { return false }
            switch binary.operator.token.kind {
            case .plus, .minus, .star, .slash, .percent: return true
            default: return false
            }
        case .prefixExpr:
            return PrefixExprSyntax(node)?.operator.token.kind == .minus
        case .memberExpr, .callExpr, .implicitMemberExpr, .identifierExpr, .numberLiteral, .parenExpr, .listLiteral,
             .stringLiteral, .boolLiteral:
            return true
        default:
            return false
        }
    }

    /// A number as the editor writes it: whole numbers without decimals, otherwise at most two decimals.
    static func number(_ value: Double, unit: String) -> String {
        let rounded = (value * 100).rounded() / 100
        var text: String
        if rounded == rounded.rounded(), abs(rounded) < 9e18 {
            text = String(Int64(rounded))
        } else {
            text = String(format: "%.2f", rounded)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
        }
        if text == "-0" { text = "0" }
        return text + unit
    }
}

extension SyntaxTree {
    /// The node of `kind` whose text starts at `offset`.
    func statement(startingAt offset: Int, kind: SyntaxKind) -> PositionedNode? {
        var stack: [PositionedNode] = [rootNode]
        while let current = stack.popLast() {
            for child in current.childNodes where child.range.lowerBound <= offset && offset <= child.range.upperBound {
                if child.kind == kind && child.textRange.lowerBound == offset { return child }
                stack.append(child)
            }
        }
        return nil
    }
}

/// Plans the text edits of a `SyntaxEdit`.
struct SyntaxEditor {
    /// A statement that moves: its old text range, and where its first token starts in the new text.
    struct PendingMove {
        var from: Range<Int>
        var newStart: Int
        var kind: SyntaxKind
    }

    enum Outcome {
        case edits([TextEdit], [PendingMove])
        case failure(EditFailure)
    }

    let tree: SyntaxTree
    let bytes: [UInt8]
    let newline: String

    init(tree: SyntaxTree) {
        self.tree = tree
        bytes = Array(tree.text.utf8)
        newline = tree.lines.newline
    }

    func edit(_ range: Range<Int>, _ replacement: String) -> TextEdit {
        TextEdit(file: tree.file, range: range, replacement: replacement)
    }

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

    func resolve(_ id: NodeID) -> Result<PositionedNode, EditFailure> {
        guard id.treeVersion == tree.version else { return .failure(.staleReference) }
        guard let node = tree.resolve(id) else { return .failure(.notFound) }
        return .success(node)
    }

    /// A block, or the source file for top-level items.
    func container(_ ref: BlockRef) -> Result<PositionedNode, EditFailure> {
        guard ref.treeVersion == tree.version else { return .failure(.staleReference) }
        if ref.kind == .sourceFile { return .success(tree.rootNode) }
        switch resolve(ref) {
        case .failure(let f): return .failure(f)
        case .success(let node): return node.kind == .block ? .success(node) : .failure(.notFound)
        }
    }

    func plan(_ edit: SyntaxEdit) -> Outcome {
        switch edit {
        case .setArgument(let ref, let newText): return setArgument(ref, newText)
        case .removeModifier(let ref): return removeModifier(ref)
        case .setField(let ref, let newText): return setField(ref, newText)
        case .insertStatement(let ref, let index, let text): return insertStatement(ref, index, text)
        case .removeStatement(let ref): return removeStatement(ref)
        case .moveStatement(let ref, let target, let index): return moveStatement(ref, target, index)
        case .wrap(let refs, let container): return wrap(refs, container)
        case .unwrap(let ref): return unwrap(ref)
        }
    }

    // MARK: - Lines

    func lineStart(of offset: Int) -> Int { tree.lines.starts[tree.lines.lineIndex(of: offset)] }

    /// The start of the line after the one containing `offset` (or the end of the text).
    func nextLineStart(after offset: Int) -> Int {
        let line = tree.lines.lineIndex(of: offset)
        return line + 1 < tree.lines.starts.count ? tree.lines.starts[line + 1] : bytes.count
    }

    func indentation(ofLineAt offset: Int) -> Int { tree.lines.indentation(ofLine: tree.lines.lineIndex(of: offset)) }

    /// Only blanks between the start of the line and `offset`.
    func startsLine(_ offset: Int) -> Bool {
        bytes[lineStart(of: offset)..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    /// Only blanks and comments between `offset` and the end of its line (a block comment may run over several
    /// lines; the line that ends is then the comment's last one).
    func endsLine(_ offset: Int) -> Bool { lineEnd(after: offset) != nil }

    /// When only blanks and comments follow `offset` up to a line break, the offset of that line break (or of the
    /// end of the text). A block comment is skipped, even over line breaks, and scanning goes on after it; nil
    /// when code follows (`Text("a") /* x */ ; Text("b")`, or `/* spans⏎ lines */ Text("b")`).
    func lineEnd(after offset: Int) -> Int? {
        var k = offset
        while true {
            while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x09 { k += 1 }
            if k >= bytes.count || bytes[k] == 0x0A || bytes[k] == 0x0D { return k }
            guard k + 1 < bytes.count, bytes[k] == 0x2F else { return nil }
            if bytes[k + 1] == 0x2F {
                while k < bytes.count, bytes[k] != 0x0A, bytes[k] != 0x0D { k += 1 }
                return k
            }
            guard bytes[k + 1] == 0x2A else { return nil }
            k += 2
            while k + 1 < bytes.count, !(bytes[k] == 0x2A && bytes[k + 1] == 0x2F) { k += 1 }
            k = min(bytes.count, k + 2)   // an unclosed comment runs to the end of the text
        }
    }

    func leadingWidth<S: StringProtocol>(_ line: S) -> Int {
        var width = 0
        for c in line {
            if c == " " { width += 1 } else if c == "\t" { width = (width / 4 + 1) * 4 } else { break }
        }
        return width
    }

    /// Splits text into lines (without their line breaks).
    func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousCR { lines.append(current); current = "" }
                previousCR = false
                continue
            }
            if previousCR { previousCR = false }
            if scalar == "\r" {
                lines.append(current)
                current = ""
                previousCR = true
                continue
            }
            current.unicodeScalars.append(scalar)
        }
        lines.append(current)
        return lines
    }

    /// Shifts every non-blank line's indentation by `delta` columns (tabs become spaces).
    func shift(_ lines: [String], by delta: Int) -> [String] {
        lines.map { line in
            guard !line.allSatisfy({ $0 == " " || $0 == "\t" }) else { return "" }
            let width = leadingWidth(line)
            return String(repeating: " ", count: max(0, width + delta)) + line.drop { $0 == " " || $0 == "\t" }
        }
    }

    // MARK: - Statement extents

    /// A statement with the lines it owns: the comment lines directly above it and the rest of its last line.
    struct Extent {
        /// From the first comment line to the start of the line after the statement (whole lines), or the
        /// statement's text and an adjacent separator when it shares its line.
        var range: Range<Int>
        var text: Range<Int>
        var ownsLines: Bool
        /// Lines of the range (without line breaks; the empty last element after the final break is dropped).
        var lines: [String]
        /// Index in `lines` of the statement's first line.
        var statementLine: Int
        var kind: SyntaxKind
    }

    func extent(of node: PositionedNode) -> Extent {
        let textRange = node.textRange
        let tokens = node.tokens.filter { !$0.token.isMissing }
        guard let first = tokens.first, let last = tokens.last else {
            return Extent(range: textRange, text: textRange, ownsLines: false, lines: [], statementLine: 0, kind: node.kind)
        }
        if startsLine(first.textStart), let lineBreak = lineEnd(after: last.textRange.upperBound) {
            // Comment lines directly above (no blank line between them and the statement) move with it.
            var rows: [Bool] = []   // true: a comment row
            var currentHasComment = false
            for piece in first.token.leadingTrivia {
                switch piece {
                case .newline:
                    rows.append(currentHasComment)
                    currentHasComment = false
                case .lineComment, .blockComment:
                    currentHasComment = true
                default:
                    break
                }
            }
            var commentRows = 0
            // The first row is the end of the previous token's line, except for the file's first token, whose
            // leading trivia starts the file.
            for isComment in (first.offset == 0 ? rows[...] : rows.dropFirst()).reversed() {
                if isComment { commentRows += 1 } else { break }
            }
            var start = lineStart(of: first.textStart)
            for _ in 0..<commentRows where start > 0 { start = lineStart(of: start - 1) }
            let end = nextLineStart(after: lineBreak)
            var lines = splitLines(text(start..<end))
            if lines.count > 1, lines.last == "" { lines.removeLast() }
            return Extent(range: start..<end, text: textRange, ownsLines: true, lines: lines,
                          statementLine: commentRows, kind: node.kind)
        }
        // Shares its line: the text and the `;` or `,` after it (or before it, when it is last).
        var end = last.textRange.upperBound + last.token.trailingTrivia.utf8Length
        var start = first.textStart
        if end < bytes.count, bytes[end] == 0x3B || bytes[end] == 0x2C {
            end += 1
            while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        } else {
            end = last.textRange.upperBound
            var k = start
            while k > 0, bytes[k - 1] == 0x20 || bytes[k - 1] == 0x09 { k -= 1 }
            if k > 0, bytes[k - 1] == 0x3B || bytes[k - 1] == 0x2C { start = k - 1 }
        }
        return Extent(range: start..<end, text: textRange, ownsLines: false, lines: [text(textRange)],
                      statementLine: 0, kind: node.kind)
    }

    /// The statements of a block, or the items of the source file.
    func statements(of container: PositionedNode) -> [PositionedNode] {
        container.childNodes.filter { $0.kind != .unexpected }
    }

    /// The leading blanks of a block's first statement standing on its own line, as written (tabs stay tabs;
    /// §3.7 rule 2 detects the indentation from the block's lines). Nil when no statement stands on its own line.
    func contentIndentText(of block: PositionedNode) -> String? {
        if block.kind == .sourceFile { return "" }
        for statement in statements(of: block) where startsLine(statement.textRange.lowerBound) {
            let start = lineStart(of: statement.textRange.lowerBound)
            return text(start..<statement.textRange.lowerBound)
        }
        return nil
    }

    /// Indentation of a block's statements: that of its first statement standing on its own line, else the
    /// owner's line plus four spaces (§3.7 rule 2).
    func contentIndent(of block: PositionedNode) -> Int {
        if block.kind == .sourceFile { return 0 }
        for statement in statements(of: block) where startsLine(statement.textRange.lowerBound) {
            return indentation(ofLineAt: statement.textRange.lowerBound)
        }
        return ownerIndent(of: block) + 4
    }

    /// Indentation of the line holding the block's `{`.
    func ownerIndent(of block: PositionedNode) -> Int {
        guard let open = block.childTokens.first else { return 0 }
        return indentation(ofLineAt: open.textStart)
    }

    /// A piece of text to insert as whole lines: its lines, and which line holds the statement itself.
    struct Lines {
        var lines: [String]
        var statementLine: Int
        var kind: SyntaxKind?
        var from: Range<Int>?
    }

    /// The lines of an extent shifted so that the statement's first line has `indent`.
    func shifted(_ e: Extent, to indent: Int) -> Lines {
        let own = e.lines.isEmpty ? 0 : leadingWidth(e.lines[e.statementLine])
        return Lines(lines: shift(e.lines, by: indent - own), statementLine: e.statementLine, kind: e.kind,
                     from: e.text)
    }

    /// New statement text given by the editor, with its first line at `indent` and the rest relative to it.
    func newStatementLines(_ statementText: String, indent: Int) -> Lines {
        var lines = splitLines(statementText)
        while let last = lines.last, last.allSatisfy({ $0 == " " || $0 == "\t" }), lines.count > 1 { lines.removeLast() }
        let own = leadingWidth(lines.first ?? "")
        return Lines(lines: shift(lines, by: indent - own), statementLine: 0, kind: nil, from: nil)
    }

    // MARK: - Arguments, modifiers, fields

    func setArgument(_ ref: ArgumentRef, _ newText: String) -> Outcome {
        switch resolve(ref) {
        case .failure(let f): return .failure(f)
        case .success(let node):
            guard let argument = ArgumentSyntax(node) else { return .failure(.notFound) }
            let value = argument.value
            var replacement = newText
            // A plain number replacing a number with a unit keeps the unit (rule 5).
            let trimmed = newText.trimmingCharacters(in: .whitespaces)
            if let number = NumberLiteralSyntax(value.node), let unit = number.token.token.unit,
               trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), Double(trimmed) != nil {
                replacement = trimmed + unit.text
            }
            guard SyntaxEditor.isLoneValue(replacement) else {
                return .failure(.notApplicable("the new text is not one value"))
            }
            let range = value.node.textRange
            if range.isEmpty {
                // A missing value: insert after the label's colon.
                let at = argument.colon.map { $0.textRange.upperBound } ?? range.lowerBound
                return .edits([edit(at..<at, (argument.colon == nil ? "" : " ") + replacement)], [])
            }
            return .edits([edit(range, replacement)], [])
        }
    }

    func setField(_ ref: FieldRef, _ newText: String) -> Outcome {
        switch resolve(ref) {
        case .failure(let f): return .failure(f)
        case .success(let node):
            guard let field = FieldSyntax(node) else { return .failure(.notFound) }
            guard SyntaxEditor.isLoneValue(newText) else { return .failure(.notApplicable("the new text is not one value")) }
            let range = field.value.node.textRange
            if range.isEmpty {
                let at = field.colon.token.isMissing ? field.label.token.textRange.upperBound : field.colon.textRange.upperBound
                return .edits([edit(at..<at, (field.colon.token.isMissing ? ": " : " ") + newText)], [])
            }
            return .edits([edit(range, newText)], [])
        }
    }

    func removeModifier(_ ref: ModifierRef) -> Outcome {
        switch resolve(ref) {
        case .failure(let f): return .failure(f)
        case .success(let node):
            guard node.kind == .modifierApp else { return .failure(.notFound) }
            let range = node.textRange
            if startsLine(range.lowerBound) && endsLine(range.upperBound) {
                return .edits([edit(lineStart(of: range.lowerBound)..<nextLineStart(after: range.upperBound), "")], [])
            }
            return .edits([edit(range, "")], [])
        }
    }

    // MARK: - Insertion

    /// Inserts whole lines as the `index`-th statement of a block (or top-level item). Returns the edit and the
    /// offset in the *old* text where the inserted text begins, plus the offset of the statement inside it.
    func insertion(of piece: Lines, into block: PositionedNode, index: Int) -> (edit: TextEdit, statementOffset: Int)? {
        let items = statements(of: block)
        let pieceText = piece.lines.joined(separator: newline)
        let statementOffsetInPiece = piece.lines.prefix(piece.statementLine).reduce(0) { $0 + $1.utf8.count + newline.utf8.count }
            + (piece.lines.isEmpty ? 0 : piece.lines[piece.statementLine].utf8.prefix { $0 == 0x20 || $0 == 0x09 }.count)
        if block.kind == .sourceFile {
            // Top-level items are separated by one blank line (F7).
            if index < items.count {
                let target = extent(of: items[index])
                let at = target.ownsLines ? target.range.lowerBound : lineStart(of: items[index].textRange.lowerBound)
                return (edit(at..<at, pieceText + newline + newline), at + statementOffsetInPiece)
            }
            if let last = items.last {
                let e = extent(of: last)
                let at = e.ownsLines ? e.range.upperBound : last.range.upperBound
                let atEndWithoutBreak = at == bytes.count && !(bytes.last == 0x0A || bytes.last == 0x0D)
                let prefix = atEndWithoutBreak ? newline + newline : newline
                return (edit(at..<at, prefix + pieceText + (atEndWithoutBreak ? "" : newline)),
                        at + prefix.utf8.count + statementOffsetInPiece)
            }
            let at = bytes.count
            let prefix = at == 0 || bytes.last == 0x0A || bytes.last == 0x0D ? "" : newline
            return (edit(at..<at, prefix + pieceText + newline), at + prefix.utf8.count + statementOffsetInPiece)
        }
        let tokens = block.childTokens
        guard let open = tokens.first, let close = tokens.last, !open.token.isMissing, !close.token.isMissing else {
            return nil
        }
        let singleLine = tree.lines.lineIndex(of: open.textStart) == tree.lines.lineIndex(of: close.textStart)
        if singleLine {
            // A block on one line becomes a multi-line block (canonical style, F3).
            let owner = ownerIndent(of: block)
            var pieces: [Lines] = items.map { item in
                let e = extent(of: item)
                return Lines(lines: [String(repeating: " ", count: owner + 4) + text(e.text)], statementLine: 0,
                             kind: item.kind, from: e.text)
            }
            pieces.insert(piece, at: index)
            var replacement = "{" + newline
            var statementOffset = 0
            for (n, p) in pieces.enumerated() {
                if n == index { statementOffset = open.textStart + replacement.utf8.count + statementOffsetInPiece }
                replacement += p.lines.joined(separator: newline) + newline
            }
            replacement += String(repeating: " ", count: owner) + "}"
            return (edit(open.textStart..<close.textRange.upperBound, replacement), statementOffset)
        }
        if index < items.count {
            let target = extent(of: items[index])
            if target.ownsLines {
                let at = target.range.lowerBound
                return (edit(at..<at, pieceText + newline), at + statementOffsetInPiece)
            }
            let at = items[index].textRange.lowerBound
            let inline = piece.lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return (edit(at..<at, inline + "; "), at)
        }
        // After the last statement's line, or after the `{` line of an empty block.
        if let last = items.last {
            let e = extent(of: last)
            if e.ownsLines {
                let at = e.range.upperBound
                let needsBreak = at == bytes.count || !(at > 0 && (bytes[at - 1] == 0x0A || bytes[at - 1] == 0x0D))
                let prefix = needsBreak ? newline : ""
                return (edit(at..<at, prefix + pieceText + newline), at + prefix.utf8.count + statementOffsetInPiece)
            }
            let lastToken = last.tokens.last { !$0.token.isMissing }!
            let at = lastToken.textRange.upperBound + lastToken.token.trailingTrivia.utf8Length
            return (edit(at..<at, newline + pieceText), at + newline.utf8.count + statementOffsetInPiece)
        }
        let at = nextLineStart(after: open.textStart)
        return (edit(at..<at, pieceText + newline), at + statementOffsetInPiece)
    }

    func insertStatement(_ ref: BlockRef, _ index: Int, _ statementText: String) -> Outcome {
        switch container(ref) {
        case .failure(let f): return .failure(f)
        case .success(let block):
            let items = statements(of: block)
            guard index >= 0 && index <= items.count else { return .failure(.notApplicable("index out of range")) }
            let indent = isSingleLine(block) ? ownerIndent(of: block) + 4 : contentIndent(of: block)
            var piece = newStatementLines(statementText, indent: indent)
            // Keep the block's own kind of indentation (tabs in a tab-indented block).
            if !isSingleLine(block), let written = contentIndentText(of: block), written.contains("\t") {
                piece.lines = piece.lines.map { line in
                    let width = leadingWidth(line)
                    return String(repeating: "\t", count: width / 4) + String(repeating: " ", count: width % 4)
                        + line.drop { $0 == " " || $0 == "\t" }
                }
            }
            guard let result = insertion(of: piece, into: block, index: index) else {
                return .failure(.notApplicable("the block has no braces"))
            }
            return .edits([result.edit], [])
        }
    }

    func isSingleLine(_ block: PositionedNode) -> Bool {
        guard block.kind == .block, let open = block.childTokens.first, let close = block.childTokens.last else { return false }
        return tree.lines.lineIndex(of: open.textStart) == tree.lines.lineIndex(of: close.textStart)
    }

    // MARK: - Removal and moves

    /// Removes a statement with the comments above it, without leaving two blank lines in a row (rule 3).
    func removal(of e: Extent) -> TextEdit {
        var range = e.range
        if e.ownsLines {
            let blankBefore = range.lowerBound > 0 && isBlankLine(before: range.lowerBound)
            let blankAfter = isBlankLine(at: range.upperBound)
            if blankBefore && blankAfter { range = range.lowerBound..<nextLineStart(after: range.upperBound) }
        }
        return edit(range, "")
    }

    /// Whether the line ending right before `offset` (a line start) is blank.
    func isBlankLine(before offset: Int) -> Bool {
        guard offset > 0 else { return false }
        let start = lineStart(of: offset - 1)
        return bytes[start..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    func isBlankLine(at offset: Int) -> Bool {
        var k = offset
        while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x09 { k += 1 }
        return k < bytes.count && (bytes[k] == 0x0A || bytes[k] == 0x0D)
    }

    func removeStatement(_ ref: StatementRef) -> Outcome {
        switch resolve(ref) {
        case .failure(let f): return .failure(f)
        case .success(let node): return .edits([removal(of: extent(of: node))], [])
        }
    }

    func moveStatement(_ ref: StatementRef, _ targetRef: BlockRef, _ index: Int) -> Outcome {
        let statement: PositionedNode
        switch resolve(ref) {
        case .failure(let f): return .failure(f)
        case .success(let node): statement = node
        }
        let target: PositionedNode
        switch container(targetRef) {
        case .failure(let f): return .failure(f)
        case .success(let node): target = node
        }
        let e = extent(of: statement)
        if target.kind == .block && e.text.lowerBound <= target.textRange.lowerBound
            && target.textRange.upperBound <= e.text.upperBound {
            return .failure(.notApplicable("a statement cannot move into itself"))
        }
        let items = statements(of: target)
        guard index >= 0 && index <= items.count else { return .failure(.notApplicable("index out of range")) }
        let indent = isSingleLine(target) ? ownerIndent(of: target) + 4 : contentIndent(of: target)
        var piece: Lines
        if e.ownsLines {
            piece = shifted(e, to: indent)
        } else {
            piece = Lines(lines: [String(repeating: " ", count: indent) + text(e.text)], statementLine: 0,
                          kind: e.kind, from: e.text)
        }
        piece.kind = e.kind
        let removal = removal(of: e)
        guard let insertion = insertion(of: piece, into: target, index: index) else {
            return .failure(.notApplicable("the block has no braces"))
        }
        let at = insertion.edit.range
        if at.lowerBound > removal.range.lowerBound && at.lowerBound < removal.range.upperBound {
            return .edits([], [])   // already there
        }
        if at.lowerBound < removal.range.upperBound && removal.range.lowerBound < at.upperBound {
            return .failure(.notApplicable("the target overlaps the moved statement"))
        }
        // Where the statement starts in the new text.
        var newStart = insertion.statementOffset
        if removal.range.upperBound <= at.lowerBound { newStart -= removal.range.count }
        let edits = [removal, insertion.edit].sorted { $0.range.lowerBound < $1.range.lowerBound }
        return .edits(edits, [PendingMove(from: e.text, newStart: newStart, kind: e.kind)])
    }

    // MARK: - Wrap and unwrap

    func wrap(_ refs: [StatementRef], _ containerName: String) -> Outcome {
        guard !refs.isEmpty else { return .failure(.notApplicable("nothing to wrap")) }
        var nodes: [PositionedNode] = []
        for ref in refs {
            switch resolve(ref) {
            case .failure(let f): return .failure(f)
            case .success(let node): nodes.append(node)
            }
        }
        nodes.sort { $0.textRange.lowerBound < $1.textRange.lowerBound }
        guard let parent = parentContainer(of: nodes[0]) else { return .failure(.notFound) }
        let siblings = statements(of: parent)
        guard let firstIndex = siblings.firstIndex(where: { $0.textRange == nodes[0].textRange }),
              firstIndex + nodes.count <= siblings.count,
              zip(siblings[firstIndex..<(firstIndex + nodes.count)], nodes).allSatisfy({ $0.textRange == $1.textRange })
        else {
            return .failure(.notApplicable("the statements are not consecutive statements of one block"))
        }
        let extents = nodes.map(extent(of:))
        if extents.allSatisfy(\.ownsLines) {
            let indent = indentation(ofLineAt: nodes[0].textRange.lowerBound)
            let pad = String(repeating: " ", count: indent)
            var replacement = pad + containerName + " {" + newline
            let start = extents[0].range.lowerBound
            var moves: [PendingMove] = []
            for e in extents {
                let piece = shifted(e, to: indent + 4)
                let offset = piece.lines.prefix(piece.statementLine).reduce(0) { $0 + $1.utf8.count + newline.utf8.count }
                    + leadingWidth(piece.lines[piece.statementLine])
                moves.append(PendingMove(from: e.text, newStart: start + replacement.utf8.count + offset, kind: e.kind))
                replacement += piece.lines.joined(separator: newline) + newline
            }
            replacement += pad + "}" + newline
            let range = start..<extents.last!.range.upperBound
            return .edits([edit(range, replacement)], moves)
        }
        // On one line: `Row { a; b }`.
        let start = extents[0].text.lowerBound
        var replacement = containerName + " { "
        var moves: [PendingMove] = []
        for (n, e) in extents.enumerated() {
            if n > 0 { replacement += "; " }
            moves.append(PendingMove(from: e.text, newStart: start + replacement.utf8.count, kind: e.kind))
            replacement += text(e.text)
        }
        replacement += " }"
        return .edits([edit(start..<extents.last!.text.upperBound, replacement)], moves)
    }

    func unwrap(_ ref: StatementRef) -> Outcome {
        switch resolve(ref) {
        case .failure(let f): return .failure(f)
        case .success(let node):
            guard let call = CallStmtSyntax(node), let block = call.block, block.isClosed else {
                return .failure(.notApplicable("only a container with a block can be unwrapped"))
            }
            let e = extent(of: node)
            let children = block.statements
            guard e.ownsLines else {
                let start = e.text.lowerBound
                var replacement = ""
                var moves: [PendingMove] = []
                for (n, child) in children.enumerated() {
                    if n > 0 { replacement += "; " }
                    moves.append(PendingMove(from: child.textRange, newStart: start + replacement.utf8.count, kind: child.kind))
                    replacement += text(child.textRange)
                }
                return .edits([edit(e.text, replacement)], moves)
            }
            let indent = indentation(ofLineAt: node.textRange.lowerBound)
            if let result = unwrapWholeLines(node, block: block, extent: e, indent: indent) { return result }
            // Comments above the container stay above its first child.
            var replacement = e.lines.prefix(e.statementLine).map { $0 + newline }.joined()
            var moves: [PendingMove] = []
            for child in children {
                let childExtent = extent(of: child)
                let piece: Lines
                if childExtent.ownsLines {
                    piece = shifted(childExtent, to: indent)
                } else {
                    piece = Lines(lines: [String(repeating: " ", count: indent) + text(childExtent.text)], statementLine: 0,
                                  kind: child.kind, from: childExtent.text)
                }
                let offset = piece.lines.prefix(piece.statementLine).reduce(0) { $0 + $1.utf8.count + newline.utf8.count }
                    + leadingWidth(piece.lines[piece.statementLine])
                moves.append(PendingMove(from: childExtent.text, newStart: e.range.lowerBound + replacement.utf8.count + offset,
                                         kind: child.kind))
                replacement += piece.lines.joined(separator: newline) + newline
            }
            return .edits([edit(e.range, replacement)], moves)
        }
    }

    /// Unwraps a container whose `{` ends its line and whose `}` starts one: the lines between the braces move
    /// out one level as they are, so every comment and blank line among the children stays; the comment after
    /// `{` goes above the first child and the comment after the container's last line below the last one.
    func unwrapWholeLines(_ node: PositionedNode, block: BlockSyntax, extent e: Extent, indent: Int) -> Outcome? {
        let braces = block.node.childTokens
        guard let open = braces.first, let close = braces.last, !open.token.isMissing, !close.token.isMissing,
              let openBreak = lineEnd(after: open.textRange.upperBound), startsLine(close.textStart),
              let last = node.tokens.last(where: { !$0.token.isMissing }),
              let lastBreak = lineEnd(after: last.textRange.upperBound) else { return nil }
        let pad = String(repeating: " ", count: indent)
        func comment(_ r: Range<Int>) -> String { text(r).trimmingCharacters(in: .whitespaces) }
        var replacement = e.lines.prefix(e.statementLine).map { $0 + newline }.joined()
        let openComment = comment(open.textRange.upperBound..<openBreak)
        if !openComment.isEmpty { replacement += pad + openComment + newline }
        let innerStart = nextLineStart(after: openBreak)
        let innerEnd = lineStart(of: close.textStart)
        var inner = innerStart < innerEnd ? splitLines(text(innerStart..<innerEnd)) : []
        if inner.last == "" { inner.removeLast() }
        let firstLine = tree.lines.lineIndex(of: innerStart)
        let blank: (String) -> Bool = { $0.allSatisfy { $0 == " " || $0 == "\t" } }
        let keptFrom = inner.firstIndex { !blank($0) } ?? inner.count
        let keptTo = inner.lastIndex { !blank($0) }.map { $0 + 1 } ?? keptFrom
        let delta = indent - contentIndent(of: block.node)
        var lineOffsets: [Int: (newStart: Int, oldLead: Int, newLead: Int)] = [:]
        var cursor = e.range.lowerBound + replacement.utf8.count
        for index in keptFrom..<max(keptFrom, keptTo) {
            let line = inner[index]
            let shiftedLine = shift([line], by: delta)[0]
            let oldLead = line.utf8.prefix { $0 == 0x20 || $0 == 0x09 }.count
            let newLead = shiftedLine.utf8.prefix { $0 == 0x20 }.count
            lineOffsets[firstLine + index] = (cursor, oldLead, newLead)
            replacement += shiftedLine + newline
            cursor += shiftedLine.utf8.count + newline.utf8.count
        }
        let tailComment = comment(last.textRange.upperBound..<lastBreak)
        if !tailComment.isEmpty { replacement += pad + tailComment + newline }
        var moves: [PendingMove] = []
        for child in block.statements {
            let start = child.textRange.lowerBound
            let line = tree.lines.lineIndex(of: start)
            guard let mapped = lineOffsets[line] else { continue }
            let column = start - tree.lines.starts[line]
            moves.append(PendingMove(from: child.textRange, newStart: mapped.newStart + column - mapped.oldLead + mapped.newLead,
                                     kind: child.kind))
        }
        return .edits([edit(e.range, replacement)], moves)
    }

    // MARK: - Validating new text

    /// The arguments `text` reads as when written between `Text(` and `)`, or nil when it does not read cleanly
    /// or does not stay inside the parentheses (`1) } widget { Text("evil"` would close the list, the block and
    /// start another widget). Values the editor passes are checked this way before they are spliced in.
    static func arguments(of text: String) -> [ArgumentSyntax]? {
        let head = "widget {\n    Text("
        let probe = head + text + ")\n}\n"
        let tree = Desk.parse(probe, fileName: "Probe.desk")
        guard !tree.diagnostics.contains(where: { $0.severity == .error }),
              let widget = tree.rootNode.childNodes.first(where: { $0.kind == .widgetBlock }),
              let statements = TopLevelBlockSyntax(widget)?.block.statements, statements.count == 1,
              let call = CallStmtSyntax(statements[0]), call.block == nil, call.modifiers.isEmpty,
              let clause = call.arguments,
              clause.node.textRange == (head.utf8.count - 1)..<(head.utf8.count + text.utf8.count + 1) else { return nil }
        return clause.arguments
    }

    /// Whether `text` is one value without a label.
    static func isLoneValue(_ text: String) -> Bool {
        guard let arguments = arguments(of: text), arguments.count == 1 else { return false }
        return arguments[0].label == nil
    }

    /// The block (or source file) a statement is directly in.
    func parentContainer(of statement: PositionedNode) -> PositionedNode? {
        var stack: [PositionedNode] = [tree.rootNode]
        while let current = stack.popLast() {
            for child in current.childNodes {
                if child.kind == statement.kind && child.textRange == statement.textRange
                    && (current.kind == .block || current.kind == .sourceFile) {
                    return current
                }
                if child.range.lowerBound <= statement.textRange.lowerBound
                    && statement.textRange.upperBound <= child.range.upperBound {
                    stack.append(child)
                }
            }
        }
        return nil
    }
}
