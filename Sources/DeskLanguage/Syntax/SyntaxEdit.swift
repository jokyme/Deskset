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
        newline = DeskFormatter.dominantNewline(tree.root)
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

    /// Only blanks and a comment between `offset` and the end of its line.
    func endsLine(_ offset: Int) -> Bool {
        var k = offset
        while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x09 { k += 1 }
        if k >= bytes.count || bytes[k] == 0x0A || bytes[k] == 0x0D { return true }
        return k + 1 < bytes.count && bytes[k] == 0x2F && (bytes[k + 1] == 0x2F || bytes[k + 1] == 0x2A)
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
        if startsLine(first.textStart) && endsLine(last.textRange.upperBound) {
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
            for isComment in rows.dropFirst().reversed() {
                if isComment { commentRows += 1 } else { break }
            }
            var start = lineStart(of: first.textStart)
            for _ in 0..<commentRows where start > 0 { start = lineStart(of: start - 1) }
            let end = nextLineStart(after: last.textRange.upperBound)
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
            + leadingWidth(piece.lines.isEmpty ? "" : piece.lines[piece.statementLine])
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
            guard let result = insertion(of: newStatementLines(statementText, indent: indent), into: block, index: index) else {
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
