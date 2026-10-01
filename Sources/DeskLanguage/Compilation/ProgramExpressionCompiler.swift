import Foundation
import DesksetCore

/// Lower the existing checked identities and scalar types. No runtime name lookup or source evaluation is used.
struct ProgramExpressionCompiler {
    let checked: CheckedFile
    let catalog: DeskCatalog
    private var slots: [NodeID: Int] = [:]
    private var assignmentTypes: [Int: DeskType] = [:]
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
        assignmentTypes.removeAll(keepingCapacity: true)
        return try declarations.enumerated().map { index, declaration in
            let kind: ProgramDeclaration.Kind
            switch declaration.keyword.token.text {
            case "variable": kind = .variable
            case "computed": kind = .computed
            default: throw issue(.unsupported, declaration.node, "Saved declarations require the shared persistence runtime")
            }
            guard let type = checked.declarationTypes[checked.tree.id(of: declaration.node)]?.type else {
                throw issue(.invalidCheckedModel, declaration.node, "Missing checked declaration type")
            }
            guard type == .string || type == .bool || type == .date else {
                throw issue(.unsupported, declaration.node, "Only String, Bool and Date declarations are implemented")
            }
            if kind == .variable { assignmentTypes[index] = type }
            return ProgramDeclaration(name: declaration.name.token.name, kind: kind,
                                      initial: try lower(declaration.initializer.node, depth: 1))
        }
    }

    mutating func assignment(_ syntax: AssignmentSyntax) throws -> ProgramAssignment {
        guard syntax.isPlainAssignment, syntax.target.path.count == 1,
              case .declaration(let identity)? = checked.symbols[checked.tree.id(of: syntax.target.node)],
              let index = slots[identity], let expected = assignmentTypes[index] else {
            throw issue(.unsupported, syntax.target.node, "Only plain assignments to checked session variables are implemented")
        }
        guard let actual = checked.types[checked.tree.id(of: syntax.value.node)]?.type, actual == expected else {
            throw issue(.invalidCheckedModel, syntax.value.node, "Checked assignment type does not match its declaration")
        }
        return ProgramAssignment(declaration: index, value: try lower(syntax.value.node, depth: 1))
    }

    mutating func text(_ node: PositionedNode) throws -> ProgramExpression {
        let type = checked.types[checked.tree.id(of: node)]?.type
        guard type == .string || type == .date else {
            throw issue(.unsupported, node, "Text requires String or Date; other value formatting is not implemented")
        }
        let value = try lower(node, depth: 1)
        return type == .date ? .formatDate(value, try defaultDateFormat(at: node)) : value
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
        guard type == .string || type == .bool || type == .date else {
            throw issue(.unsupported, node, "Only String, Bool and Date expressions are implemented")
        }
        if let value = StringLiteralSyntax(node) {
            if let text = value.literalValue {
                guard text.utf16.count <= min(ProgramLimits.maximumTextLength, catalog.limits.maximumTextLength) else {
                    throw issue(.resourceLimit, node, "Shared program text limit exceeded")
                }
                return .string(text)
            }
            var parts: [ProgramExpression] = []
            for segment in value.segments {
                switch segment {
                case .text(_, let cooked): parts.append(.string(cooked))
                case .foreign(let foreign): throw issue(.unsupported, foreign, "Foreign string interpolation is not implemented")
                case .interpolation(let interpolation):
                    let expression = try lower(interpolation.value.node, depth: depth + 1)
                    let type = checked.types[checked.tree.id(of: interpolation.value.node)]?.type
                    if type == .date {
                        guard interpolation.formatOptions.count <= 1 else {
                            throw issue(.unsupported, interpolation.node, "Only the Date format option is implemented")
                        }
                        let format: ProgramDateFormat
                        if let option = interpolation.formatOptions.first {
                            guard option.label.name == "format",
                                  let spec = catalog.formatOptions.first(where: { $0.label == "format" && $0.appliesTo.contains(.date) }),
                                  spec.type == .oneOf([.string, .enumeration("DatePreset")]), spec.range == nil else {
                                throw issue(.unsupported, option.node, "Unsupported Date format option or catalog lowering")
                            }
                            format = try dateFormat(option.value.node)
                        } else { format = try defaultDateFormat(at: interpolation.value.node) }
                        parts.append(.formatDate(expression, format))
                    } else {
                        guard interpolation.formatOptions.isEmpty, type == .string || type == .bool else {
                            throw issue(.unsupported, interpolation.node, "Only unformatted String/Bool and formatted Date interpolation are implemented")
                        }
                        parts.append(expression)
                    }
                }
            }
            return .concatenate(parts)
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
            if checked.symbols[identity] == .builtIn(.member(namespace: "time", name: "now")) {
                guard checked.dataUses.contains(where: { $0.reference == identity && $0.nodePath == "time" && $0.memberPath == "time.now" && $0.arguments.isEmpty && $0.instanceScope.isEmpty }),
                      let member = catalog.member(path: "time.now"), member.kind == .field, member.type == .date,
                      member.cadence == .clock, member.readsSynchronously, member.permission == nil,
                      catalog.namespace(named: "time")?.permission == nil, !member.settable,
                      case .native(let kernel, let options, let field) = member.lowering,
                      kernel == "clock", options.isEmpty, field == nil else {
                    throw issue(.unsupported, node, "Unsupported time.now catalog or checked data identity")
                }
                return .timeNow
            }
            guard checked.symbols[identity] == .builtIn(.member(namespace: "system", name: "dark")),
                  checked.dataUses.contains(where: { $0.reference == identity && $0.nodePath == "system" && $0.memberPath == "system.dark" && $0.arguments.isEmpty && $0.instanceScope.isEmpty }),
                  let member = catalog.member(path: "system.dark"), member.kind == .field, member.type == .bool,
                  member.cadence == .event, member.readsSynchronously, member.permission == nil,
                  catalog.namespace(named: "system")?.permission == nil, !member.settable,
                  case .native(let kernel, let options, let field) = member.lowering,
                  kernel == "appearance", options.isEmpty, field == "dark" else {
                throw issue(.unsupported, node, "Only checked system.dark and time.now inputs are implemented")
            }
            return .appearanceDark
        }
        if let call = CallExprSyntax(node), let member = MemberExprSyntax(call.callee.node) {
            // The current checker records type-member calls by checked receiver/result types, not Symbol.
            let arguments = call.arguments.arguments
            guard member.name.token.name == "in", type == .date,
                  checked.types[checked.tree.id(of: member.base.node)]?.type == .date,
                  arguments.count == 1, arguments[0].label == nil,
                  checked.types[checked.tree.id(of: arguments[0].value.node)]?.type == .string,
                  let zone = StringLiteralSyntax(arguments[0].value.node)?.literalValue,
                  TimeZone(identifier: zone) != nil,
                  let spec = catalog.member("in", of: .date, call: true), spec.kind == .function,
                  spec.type == .date, spec.cadence == .ofRecord, spec.readsSynchronously,
                  spec.permission == nil, !spec.settable, !spec.userInitiatedOnly,
                  spec.lowering == .derived("Date.in()"), spec.signatures.count == 1,
                  spec.signatures[0].result == .fixed(.date), spec.signatures[0].params.count == 1,
                  spec.signatures[0].params[0].label == nil, spec.signatures[0].params[0].type == .string,
                  spec.signatures[0].params[0].required, !spec.signatures[0].params[0].variadic,
                  spec.signatures[0].params[0].defaultValue == nil else {
                throw issue(.unsupported, node, "Only the checked Date.in(literal time zone) member is implemented")
            }
            return .dateIn(try lower(member.base.node, depth: depth + 1), timeZone: zone)
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

    private func defaultDateFormat(at node: PositionedNode) throws -> ProgramDateFormat {
        guard let value = catalog.member(path: "time.now")?.defaultFormat ?? catalog.typeFormats.first(where: { $0.type == .date })?.style else {
            throw issue(.unsupported, node, "Missing catalog default Date format")
        }
        let format: ProgramDateFormat
        switch value {
        case .style(let name):
            guard name.hasPrefix("."), let preset = ProgramDateFormat.Preset(rawValue: String(name.dropFirst())),
                  catalog.enumeration("DatePreset")?.enumCase(named: preset.rawValue) != nil else {
                throw issue(.unsupported, node, "Unsupported catalog default Date preset")
            }
            format = .preset(preset)
        case .pattern(let pattern): format = .pattern(pattern)
        }
        return try supported(format, at: node)
    }

    private func dateFormat(_ node: PositionedNode) throws -> ProgramDateFormat {
        if let literal = StringLiteralSyntax(node)?.literalValue { return try supported(.pattern(literal), at: node) }
        if case .enumCase(let type, let name)? = checked.symbols[checked.tree.id(of: node)], type == "DatePreset",
           let preset = ProgramDateFormat.Preset(rawValue: name), catalog.enumeration(type)?.enumCase(named: name) != nil {
            return .preset(preset)
        }
        throw issue(.unsupported, node, "Date format must be a supported literal Unicode pattern or checked preset")
    }

    private func supported(_ format: ProgramDateFormat, at node: PositionedNode) throws -> ProgramDateFormat {
        do { _ = try format.precision; return format }
        catch { throw issue(.unsupported, node, "Unsupported date pattern or subsecond display precision") }
    }

    private func issue(_ kind: DeskCompilationIssue.Kind, _ node: PositionedNode, _ message: String) -> DeskCompilationIssue {
        DeskCompilationIssue(kind: kind, file: checked.tree.file, range: node.textRange, message: message)
    }
}
