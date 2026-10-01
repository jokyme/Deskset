import DesksetCore

/// Lower the existing checked identities and scalar types. No runtime name lookup or source evaluation is used.
struct ProgramExpressionCompiler {
    let checked: CheckedFile
    let catalog: DeskCatalog
    private var slots: [NodeID: Int] = [:]
    private var count = 0

    init(checked: CheckedFile, catalog: DeskCatalog) {
        self.checked = checked
        self.catalog = catalog
    }

    mutating func declarations(_ declarations: [DeclarationSyntax]) throws -> [ProgramDeclaration] {
        guard declarations.count <= ProgramLimits.maximumExpressions else {
            throw issue(.resourceLimit, checked.tree.rootNode, "Shared program declaration limit exceeded")
        }
        slots = Dictionary(uniqueKeysWithValues: declarations.enumerated().map { (checked.tree.id(of: $0.element.node), $0.offset) })
        return try declarations.map { declaration in
            let kind: ProgramDeclaration.Kind
            switch declaration.keyword.token.text {
            case "variable": kind = .variable
            case "computed": kind = .computed
            default: throw issue(.unsupported, declaration.node, "Saved declarations require the shared persistence runtime")
            }
            guard let type = checked.declarationTypes[checked.tree.id(of: declaration.node)]?.type else {
                throw issue(.invalidCheckedModel, declaration.node, "Missing checked declaration type")
            }
            guard type == .string || type == .bool else {
                throw issue(.unsupported, declaration.node, "Only String and Bool declarations are implemented")
            }
            return ProgramDeclaration(name: declaration.name.token.name, kind: kind,
                                      initial: try lower(declaration.initializer.node, depth: 1))
        }
    }

    mutating func text(_ node: PositionedNode) throws -> ProgramExpression {
        guard checked.types[checked.tree.id(of: node)]?.type == .string else {
            throw issue(.unsupported, node, "Text requires a String expression; other value formatting is not implemented")
        }
        return try lower(node, depth: 1)
    }

    private mutating func lower(_ node: PositionedNode, depth: Int) throws -> ProgramExpression {
        count += 1
        guard count <= min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens) else {
            throw issue(.resourceLimit, node, "Shared program expression limit exceeded")
        }
        guard depth <= min(ProgramLimits.maximumExpressionDepth, catalog.limits.maximumExpressionNesting) else {
            throw issue(.resourceLimit, node, "Shared program expression depth exceeded")
        }
        guard let type = checked.types[checked.tree.id(of: node)]?.type else {
            throw issue(.invalidCheckedModel, node, "Missing checked expression type")
        }
        guard type == .string || type == .bool else {
            throw issue(.unsupported, node, "Only String and Bool expressions are implemented")
        }
        if let value = StringLiteralSyntax(node) {
            guard let text = value.literalValue else {
                throw issue(.unsupported, node, "Text interpolation and its formatting are not implemented")
            }
            guard text.utf16.count <= min(ProgramLimits.maximumTextLength, catalog.limits.maximumTextLength) else {
                throw issue(.resourceLimit, node, "Shared program text limit exceeded")
            }
            return .string(text)
        }
        if let value = BoolLiteralSyntax(node) { return .boolean(value.value) }
        if let value = ParenExprSyntax(node) { return try lower(value.value.node, depth: depth + 1) }
        if IdentifierExprSyntax(node) != nil {
            guard case .declaration(let identity)? = checked.symbols[checked.tree.id(of: node)], let slot = slots[identity] else {
                throw issue(.unsupported, node, "Only checked widget declarations can be read by this program slice")
            }
            return .declaration(slot)
        }
        if MemberExprSyntax(node) != nil {
            let identity = checked.tree.id(of: node)
            guard checked.symbols[identity] == .builtIn(.member(namespace: "system", name: "dark")),
                  checked.dataUses.contains(where: { $0.reference == identity && $0.nodePath == "system" && $0.memberPath == "system.dark" && $0.arguments.isEmpty && $0.instanceScope.isEmpty }),
                  let member = catalog.member(path: "system.dark"), member.kind == .field, member.type == .bool,
                  member.cadence == .event, member.readsSynchronously, member.permission == nil,
                  catalog.namespace(named: "system")?.permission == nil, !member.settable,
                  case .native(let kernel, let options, let field) = member.lowering,
                  kernel == "appearance", options.isEmpty, field == "dark" else {
                throw issue(.unsupported, node, "Only the checked synchronous system.dark appearance input is implemented")
            }
            return .appearanceDark
        }
        if let value = PrefixExprSyntax(node), value.operator.token.text == "not" {
            return .not(try lower(value.operand.node, depth: depth + 1))
        }
        if let value = BinaryExprSyntax(node) {
            let left = try lower(value.left.node, depth: depth + 1), right = try lower(value.right.node, depth: depth + 1)
            switch value.operator.token.text {
            case "and": return .and(left, right)
            case "or": return .or(left, right)
            case "==": return .equal(left, right)
            case "!=": return .notEqual(left, right)
            default: throw issue(.unsupported, node, "Unsupported scalar operator: \(value.operator.token.text)")
            }
        }
        if let value = TernaryExprSyntax(node) {
            return .conditional(try lower(value.condition.node, depth: depth + 1),
                                then: try lower(value.then.node, depth: depth + 1),
                                otherwise: try lower(value.otherwise.node, depth: depth + 1))
        }
        throw issue(.unsupported, node, "Unsupported String/Bool expression: \(node.kind.rawValue)")
    }

    private func issue(_ kind: DeskCompilationIssue.Kind, _ node: PositionedNode, _ message: String) -> DeskCompilationIssue {
        DeskCompilationIssue(kind: kind, file: checked.tree.file, range: node.textRange, message: message)
    }
}
