import Foundation

/// An editor operation that needs the catalog or resolved names (§3.7): text-only edits, adding or replacing a
/// modifier at the place the catalog's `sortKey` gives it, and renaming an own name everywhere it is read.
public enum DeskEdit: Sendable {
    case syntax(SyntaxEdit)
    /// Adds the modifier, or replaces the arguments of the one of the same name and condition. `condition` is the
    /// `if:` value as Desk text, or nil for the unconditional one.
    case setModifier(ElementRef, name: String, argumentsText: String, condition: String?)
    /// Renames a declaration, loop variable, element name, style or option: its declaration and every use that
    /// resolves to it (never a field of the same spelling, such as `item.title`, nor text in a string).
    case rename(SymbolRef, to: String)
}

extension Desk {
    /// Applies an edit to a checked file and parses the result.
    public static func apply(_ edit: DeskEdit, to file: CheckedFile, catalog: DeskCatalog = .current) -> EditResult {
        let tree = file.tree
        func refuse(_ failure: EditFailure) -> EditResult {
            EditResult(edits: [], tree: tree, diagnostics: tree.diagnostics, moves: [], failure: failure)
        }
        func finish(_ edits: [TextEdit]) -> EditResult {
            let text = TextEdit.apply(edits, to: tree.text)
            let newTree = Desk.parse(text, file: tree.file)
            return EditResult(edits: edits, tree: newTree, diagnostics: newTree.diagnostics, moves: [])
        }
        switch edit {
        case .syntax(let syntaxEdit):
            return apply(syntaxEdit, to: tree)
        case .setModifier(let ref, let name, let argumentsText, let condition):
            guard ref.treeVersion == tree.version else { return refuse(.staleReference) }
            guard let node = tree.resolve(ref), node.kind == .callStmt else { return refuse(.notFound) }
            guard let spec = catalog.modifier(named: name) else { return refuse(.notApplicable("unknown modifier .\(name)")) }
            // The pieces are spliced into the file: each must read as what it stands for, and stay inside the
            // parentheses.
            guard SyntaxEditor.arguments(of: argumentsText) != nil, condition.map(SyntaxEditor.isLoneValue) ?? true else {
                return refuse(.notApplicable("the arguments are not Desk arguments"))
            }
            return finish(ModifierPlacement(tree: tree, call: node, catalog: catalog)
                .edits(spec: spec, argumentsText: argumentsText, condition: condition))
        case .rename(let ref, let newName):
            guard ref.treeVersion == tree.version else { return refuse(.staleReference) }
            // The checker's rules for own names: no reserved or block word (DK3015), at most 128 bytes (DK1009),
            // and no name already in use where the renamed one is visible (DK3014, or a silent merge).
            guard Checker.isIdentifier(newName), let first = newName.unicodeScalars.first, !("A"..."Z").contains(first),
                  Chars.reservedWords[newName] == nil, !Chars.blockWords.contains(newName), newName.utf8.count <= 128 else {
                return refuse(.notApplicable("\(newName) is not an own name"))
            }
            let plan = RenamePlan(file: file)
            guard let edits = plan.edits(for: ref, to: newName), !edits.isEmpty else { return refuse(.notFound) }
            if let clash = plan.clash(renaming: ref, to: newName, editing: Set(edits.map(\.range.lowerBound))) {
                return refuse(.notApplicable("\(newName) is already \(clash)"))
            }
            return finish(edits)
        }
    }
}

/// Where a modifier goes among an element's modifiers (§3.7 rule 4).
struct ModifierPlacement {
    let tree: SyntaxTree
    let call: PositionedNode
    let catalog: DeskCatalog

    func text(_ r: Range<Int>) -> String {
        let utf8 = tree.text.utf8
        return String(tree.text[utf8.index(utf8.startIndex, offsetBy: r.lowerBound)..<utf8.index(utf8.startIndex, offsetBy: r.upperBound)])
    }

    func edits(spec: ModifierSpec, argumentsText: String, condition: String?) -> [TextEdit] {
        let modifiers = call.children(.modifierApp).map(ModifierAppSyntax.init(unchecked:))
        let arguments = condition.map { argumentsText.isEmpty ? "if: \($0)" : "\(argumentsText), if: \($0)" } ?? argumentsText
        // Replace the one of the same name and condition.
        for modifier in modifiers where modifier.name.token.text == spec.name {
            let conditionArgument = modifier.arguments?.arguments.first { $0.label?.name == "if" }
            let sameCondition: Bool
            if let condition { sameCondition = conditionArgument.map { $0.value.node.node.trimmedText == condition } ?? false }
            else { sameCondition = conditionArgument == nil }
            guard sameCondition else { continue }
            if let clause = modifier.arguments {
                return [TextEdit(file: tree.file, range: clause.node.textRange, replacement: "(\(arguments))")]
            }
            let end = modifier.name.textRange.upperBound
            return [TextEdit(file: tree.file, range: end..<end, replacement: "(\(arguments))")]
        }
        // Insert by sort key: before the first modifier that sorts after it, else after the last.
        let newText = ".\(spec.name)(\(arguments))"
        let multiLine = modifiers.contains { $0.dot.token.leadingTrivia.containsLineBreak }
        let indent: String
        if let lined = modifiers.first(where: { $0.dot.token.leadingTrivia.containsLineBreak }) {
            indent = lined.dot.token.leadingTrivia.filter { !$0.isNewline }.text
        } else {
            indent = ""
        }
        let newline = tree.lines.newline
        if let next = modifiers.first(where: { (catalog.modifier(named: $0.name.token.text)?.sortKey ?? Int.max) > spec.sortKey }) {
            let at = next.dot.textStart
            if multiLine && next.dot.token.leadingTrivia.containsLineBreak {
                return [TextEdit(file: tree.file, range: at..<at, replacement: newText + newline + indent)]
            }
            return [TextEdit(file: tree.file, range: at..<at, replacement: newText)]
        }
        let end = call.textRange.upperBound
        if multiLine { return [TextEdit(file: tree.file, range: end..<end, replacement: newline + indent + newText)] }
        return [TextEdit(file: tree.file, range: end..<end, replacement: newText)]
    }
}

/// Every place an own name is written: its declaration and the uses that resolve to it.
struct RenamePlan {
    let file: CheckedFile

    /// Why `newName` cannot be taken, or nil. Styles and options clash with their own kind; declarations, loop
    /// variables and element names with any name written in the file (a declaration, a loop variable, an
    /// element name, a read of a built-in value such as `cpu`) outside the places being renamed.
    func clash(renaming ref: NodeID, to newName: String, editing: Set<Int>) -> String? {
        let tree = file.tree
        guard let declaration = tree.resolve(ref) else { return nil }
        switch declaration.kind {
        case .styleDecl:
            return file.styles[newName] != nil ? "a style" : nil
        case .optionDecl:
            return file.options[newName] != nil ? "an option" : nil
        default:
            break
        }
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            var tokens: [PositionedToken] = []
            switch node.kind {
            case .identifierExpr: tokens = [IdentifierExprSyntax(unchecked: node).token]
            case .declaration: tokens = [DeclarationSyntax(unchecked: node).name]
            case .forStmt: tokens = [ForStmtSyntax(unchecked: node).variable]
            case .target: tokens = [TargetSyntax(unchecked: node).name]
            default: break
            }
            for token in tokens where token.token.name == newName && !editing.contains(token.textStart) {
                return "a name in this file"
            }
            stack += node.childNodes
        }
        return nil
    }

    func edits(for ref: NodeID, to newName: String) -> [TextEdit]? {
        let tree = file.tree
        guard let declaration = tree.resolve(ref) else { return nil }
        var ranges: [Range<Int>] = []
        // The declaration's own name.
        switch declaration.kind {
        case .declaration: ranges.append(DeclarationSyntax(unchecked: declaration).name.textRange)
        case .forStmt: ranges.append(ForStmtSyntax(unchecked: declaration).variable.textRange)
        case .styleDecl: ranges.append(StyleDeclSyntax(unchecked: declaration).name.textRange)
        case .optionDecl: ranges.append(OptionDeclSyntax(unchecked: declaration).target.name.textRange)
        case .callStmt:
            // An element named with `.name(x)`.
            for modifier in declaration.children(.modifierApp).map(ModifierAppSyntax.init(unchecked:))
            where modifier.name.token.text == "name" {
                if let value = modifier.arguments?.arguments.first?.value.node {
                    if value.kind == .identifierExpr { ranges.append(IdentifierExprSyntax(unchecked: value).token.textRange) }
                    if let inner = RenamePlan.quotedName(value) { ranges.append(inner) }
                }
            }
        default:
            return nil
        }
        // Every use that resolves to it.
        for (use, symbol) in file.symbols {
            let target: NodeID?
            switch symbol {
            case .declaration(let id), .loopVariable(let id), .element(let id): target = id
            case .style(let id, let f), .option(let id, let f): target = f == tree.file ? id : nil
            default: target = nil
            }
            guard target == ref, let node = tree.resolve(use) else { continue }
            switch node.kind {
            case .identifierExpr: ranges.append(IdentifierExprSyntax(unchecked: node).token.textRange)
            case .memberExpr:
                // `options.code.matches(…)`: nested member accesses start at one place, and the reference names the
                // outermost; the option is the innermost, `options.code`.
                var member = node
                while let base = member.childNodes.first, base.kind == .memberExpr { member = base }
                ranges.append(MemberExprSyntax(unchecked: member).name.textRange)
            case .target:
                let target = TargetSyntax(unchecked: node)
                ranges.append((target.members.last ?? target.name).textRange)
            case .stringLiteral:
                // A quoted own name (`.style("card")`, `show("details")`, DK3036): the text between the quotes.
                if let inner = RenamePlan.quotedName(node) { ranges.append(inner) }
            default: break
            }
        }
        let unique = Set(ranges.map { [$0.lowerBound, $0.upperBound] }).map { $0[0]..<$0[1] }
        return unique.sorted { $0.lowerBound < $1.lowerBound }.map { TextEdit(file: tree.file, range: $0, replacement: newName) }
    }

    /// The text between the quotes of a one-line string that is only text (`"card"`), or nil.
    static func quotedName(_ value: PositionedNode) -> Range<Int>? {
        guard value.kind == .stringLiteral else { return nil }
        let tokens = value.tokens.filter { !$0.token.isMissing }
        guard tokens.count == 3, tokens[0].kind == .stringStart, tokens[1].kind == .stringText, tokens[2].kind == .stringEnd,
              !tokens[1].token.text.contains("\\") else { return nil }
        return tokens[1].textRange
    }
}
