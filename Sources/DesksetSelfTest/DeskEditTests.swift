import Foundation
@testable import DeskLanguage

/// Nodes of a kind, in document order, with positions.
private func nodes(_ tree: SyntaxTree, _ kind: SyntaxKind) -> [PositionedNode] {
    var out: [PositionedNode] = []
    var stack: [PositionedNode] = [tree.rootNode]
    while let node = stack.popLast() {
        if node.kind == kind { out.append(node) }
        stack.append(contentsOf: node.childNodes.reversed())
    }
    return out
}

private func statementNamed(_ tree: SyntaxTree, _ prefix: String) -> PositionedNode? {
    var stack: [PositionedNode] = [tree.rootNode]
    while let node = stack.popLast() {
        if node.kind.isStatement, node.node.trimmedText.hasPrefix(prefix) { return node }
        stack.append(contentsOf: node.childNodes.reversed())
    }
    return nil
}

/// Checks what every edit must keep: bytes outside the edits unchanged (rule 1), the result tree is the edited
/// text, and no new syntax error.
private func checkResult(_ t: TestRunner, _ result: EditResult, from tree: SyntaxTree, _ label: String) {
    t.check(result.failure == nil, "\(label): \(String(describing: result.failure))")
    t.equal(result.tree.text, TextEdit.apply(result.edits, to: tree.text), "\(label): the new tree is the edited text")
    t.equal(deskErrorIDs(result.tree), [], "\(label): no syntax error")
    t.check(result.tree.version > tree.version, "\(label): a new tree version")
    // Outside the edited ranges nothing changed.
    let old = Array(tree.text.utf8)
    let new = Array(result.tree.text.utf8)
    var oldCursor = 0
    var newCursor = 0
    for edit in result.edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
        let length = edit.range.lowerBound - oldCursor
        t.check(Array(old[oldCursor..<edit.range.lowerBound]) == Array(new[newCursor..<(newCursor + length)]),
                "\(label): bytes before an edit changed")
        newCursor += length + edit.replacement.utf8.count
        oldCursor = edit.range.upperBound
    }
    t.check(Array(old[oldCursor...]) == Array(new[newCursor...]), "\(label): bytes after the edits changed")
}

func runDeskEditTests(_ t: TestRunner) {
    let source = """
    info { name: "CPU", size: .small }

    widget {
        // The label
        Text("CPU").font(.caption).padding(12pt)
        Text("{cpu.usage}%")
            .font(.largeNumber)
            .color(.dim)
        Row { Text("A"); Text("B") }
        Column {
            Text("C")
        }
    }

    """

    t.suite("Desk: edits — arguments, modifiers, fields") {
        let tree = deskParse(source)
        t.equal(deskIDs(tree), [])
        // A number keeps its unit (rule 5).
        let padding = nodes(tree, .modifierApp).first { $0.node.trimmedText.hasPrefix(".padding") }!
        let argument = ArgumentClauseSyntax(padding.firstChild(.argumentClause)!)!.arguments[0]
        let set = Desk.apply(.setArgument(tree.id(of: argument.node), newText: "14"), to: tree)
        checkResult(t, set, from: tree, "setArgument")
        t.check(set.tree.text.contains(".padding(14pt)"), "the unit stays")
        t.equal(set.edits.count, 1)
        // A string argument.
        let text = nodes(tree, .argument).first { $0.node.trimmedText == "\"CPU\"" }!
        let renamed = Desk.apply(.setArgument(tree.id(of: text), newText: "\"Processor\""), to: tree)
        checkResult(t, renamed, from: tree, "setArgument text")
        t.check(renamed.tree.text.contains("Text(\"Processor\").font(.caption)"))
        // Removing a modifier on its own line removes the line; one in a chain on one line, only itself.
        let color = nodes(tree, .modifierApp).first { $0.node.trimmedText == ".color(.dim)" }!
        let removedLine = Desk.apply(.removeModifier(tree.id(of: color)), to: tree)
        checkResult(t, removedLine, from: tree, "removeModifier line")
        t.check(removedLine.tree.text.contains("        .font(.largeNumber)\n    Row"), removedLine.tree.text)
        let font = nodes(tree, .modifierApp).first { $0.node.trimmedText == ".font(.caption)" }!
        let removedInline = Desk.apply(.removeModifier(tree.id(of: font)), to: tree)
        checkResult(t, removedInline, from: tree, "removeModifier inline")
        t.check(removedInline.tree.text.contains("Text(\"CPU\").padding(12pt)"))
        // A field's value.
        let field = nodes(tree, .field).first!
        let named = Desk.apply(.setField(tree.id(of: field), newText: "\"Processor\""), to: tree)
        checkResult(t, named, from: tree, "setField")
        t.check(named.tree.text.hasPrefix("info { name: \"Processor\", size: .small }"))
        // A reference from another version, or to a node of another kind, is refused.
        let stale = Desk.apply(.removeModifier(tree.id(of: color)), to: set.tree)
        t.equal(stale.failure, .staleReference)
        t.equal(stale.edits, [])
        var wrongKind = tree.id(of: color)
        wrongKind.kind = .field
        t.equal(Desk.apply(.removeModifier(wrongKind), to: tree).failure, .notFound)
    }

    t.suite("Desk: edits — statements") {
        let tree = deskParse(source)
        let widgetBlock = nodes(tree, .block)[1]
        let widgetRef = tree.id(of: widgetBlock)
        // Insert at the top: before the first statement and its comment, at the block's indentation.
        let first = Desk.apply(.insertStatement(widgetRef, index: 0, text: "Text(\"New\")"), to: tree)
        checkResult(t, first, from: tree, "insert first")
        t.check(first.tree.text.contains("widget {\n    Text(\"New\")\n    // The label\n"), first.tree.text)
        // Insert a multi-line statement at the end; its lines keep their shape.
        let last = Desk.apply(.insertStatement(widgetRef, index: 4, text: "Row {\n    Spacer()\n}"), to: tree)
        checkResult(t, last, from: tree, "insert last")
        t.check(last.tree.text.contains("        Text(\"C\")\n    }\n    Row {\n        Spacer()\n    }\n}"), last.tree.text)
        // Into a block written on one line: it becomes a multi-line block.
        let row = nodes(tree, .block).first { $0.node.trimmedText == "{ Text(\"A\"); Text(\"B\") }" }!
        let intoRow = Desk.apply(.insertStatement(tree.id(of: row), index: 1, text: "Spacer()"), to: tree)
        checkResult(t, intoRow, from: tree, "insert into a one-line block")
        t.check(intoRow.tree.text.contains("    Row {\n        Text(\"A\")\n        Spacer()\n        Text(\"B\")\n    }\n"),
                intoRow.tree.text)
        // An index out of range is refused.
        t.equal(Desk.apply(.insertStatement(widgetRef, index: 9, text: "Spacer()"), to: tree).failure,
                .notApplicable("index out of range"))
        // A top-level item, separated by a blank line.
        let fileRef = NodeID(kind: .sourceFile, utf8Start: 0, treeVersion: tree.version)
        let style = Desk.apply(.insertStatement(fileRef, index: 2, text: "style big { .font(20) }"), to: tree)
        checkResult(t, style, from: tree, "insert a style")
        t.check(style.tree.text.hasSuffix("}\n\nstyle big { .font(20) }\n"), style.tree.text)
        // Removing a statement takes the comment above it.
        let labelled = statementNamed(tree, "Text(\"CPU\")")!
        let removed = Desk.apply(.removeStatement(tree.id(of: labelled)), to: tree)
        checkResult(t, removed, from: tree, "remove")
        t.check(removed.tree.text.contains("widget {\n    Text(\"{cpu.usage}%\")"), removed.tree.text)
        t.check(!removed.tree.text.contains("The label"))
        // No two blank lines are left behind.
        let spaced = deskParse("widget {\n    Text(\"A\")\n\n    Text(\"B\")\n\n    Text(\"C\")\n}\n")
        let middle = statementNamed(spaced, "Text(\"B\")")!
        let closed = Desk.apply(.removeStatement(spaced.id(of: middle)), to: spaced)
        checkResult(t, closed, from: spaced, "remove between blank lines")
        t.equal(closed.tree.text, "widget {\n    Text(\"A\")\n\n    Text(\"C\")\n}\n")
    }

    t.suite("Desk: edits — moves, wrap and unwrap") {
        let tree = deskParse(source)
        // Move a multi-line statement into the Column: reindented, the move reported.
        let value = statementNamed(tree, "Text(\"{cpu.usage}%\")")!
        let column = nodes(tree, .block).last!
        let moved = Desk.apply(.moveStatement(tree.id(of: value), to: tree.id(of: column), index: 0), to: tree)
        checkResult(t, moved, from: tree, "move")
        t.check(moved.tree.text.contains("""
            Column {
                Text("{cpu.usage}%")
                    .font(.largeNumber)
                    .color(.dim)
                Text("C")
            }
        """), moved.tree.text)
        t.equal(moved.moves.count, 1)
        if let move = moved.moves.first {
            t.equal(move.from, value.textRange)
            let movedText = String(decoding: Array(moved.tree.text.utf8)[move.to], as: UTF8.self)
            t.check(movedText.hasPrefix("Text(\"{cpu.usage}%\")") && movedText.hasSuffix(".color(.dim)"), movedText)
        }
        // Comments move with the statement (rule 3).
        let labelled = statementNamed(tree, "Text(\"CPU\")")!
        let withComment = Desk.apply(.moveStatement(tree.id(of: labelled), to: tree.id(of: column), index: 1), to: tree)
        checkResult(t, withComment, from: tree, "move with comment")
        t.check(withComment.tree.text.contains("        Text(\"C\")\n        // The label\n        Text(\"CPU\")"), withComment.tree.text)
        // A statement cannot move into itself.
        let outer = statementNamed(tree, "Column")!
        t.check(Desk.apply(.moveStatement(tree.id(of: outer), to: tree.id(of: column), index: 0), to: tree).failure != nil)
        // Wrap two statements in a Column, then unwrap it: the text comes back as it was.
        let a = statementNamed(tree, "Text(\"{cpu.usage}%\")")!
        let b = statementNamed(tree, "Row")!
        let wrapped = Desk.apply(.wrap([tree.id(of: a), tree.id(of: b)], container: "Column"), to: tree)
        checkResult(t, wrapped, from: tree, "wrap")
        t.check(wrapped.tree.text.contains("""
            Column {
                Text("{cpu.usage}%")
                    .font(.largeNumber)
                    .color(.dim)
                Row { Text("A"); Text("B") }
            }
        """), wrapped.tree.text)
        t.equal(wrapped.moves.count, 2)
        for move in wrapped.moves {
            let before = String(decoding: Array(tree.text.utf8)[move.from], as: UTF8.self)
            let after = String(decoding: Array(wrapped.tree.text.utf8)[move.to], as: UTF8.self)
            t.equal(after.replacingOccurrences(of: "    ", with: ""), before.replacingOccurrences(of: "    ", with: ""),
                    "the moved statement is the same text, indented")
        }
        let container = statementNamed(wrapped.tree, "Column {\n        Text")!
        let unwrapped = Desk.apply(.unwrap(wrapped.tree.id(of: container)), to: wrapped.tree)
        checkResult(t, unwrapped, from: wrapped.tree, "unwrap")
        t.equal(unwrapped.tree.text, source)
        t.equal(unwrapped.moves.count, 2)
        // Statements that are not consecutive siblings cannot be wrapped together.
        let c = statementNamed(tree, "Text(\"C\")")!
        t.check(Desk.apply(.wrap([tree.id(of: a), tree.id(of: c)], container: "Row"), to: tree).failure != nil)
        // Unwrap a container written on one line.
        let row = statementNamed(tree, "Row")!
        let flat = Desk.apply(.unwrap(tree.id(of: row)), to: tree)
        checkResult(t, flat, from: tree, "unwrap one line")
        t.check(flat.tree.text.contains("    Text(\"A\")\n    Text(\"B\")\n"), flat.tree.text)
    }
}
