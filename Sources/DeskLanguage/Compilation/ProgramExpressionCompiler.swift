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
            guard supportedType(type) else {
                throw issue(.unsupported, declaration.node, "Only String, Bool, Date and dimensionless Number declarations are implemented")
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
        guard type == .string || type == .date || type == .plainNumber else {
            throw issue(.unsupported, node, "Text requires String, Date or dimensionless Number; other value formatting is not implemented")
        }
        let value = try lower(node, depth: 1)
        if type == .plainNumber { return .formatNumber(value, try numberFormat(at: node, options: [])) }
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
        guard supportedType(type) else {
            throw issue(.unsupported, node, "Only String, Bool, Date and dimensionless Number expressions are implemented")
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
                    if type == .plainNumber {
                        parts.append(.formatNumber(expression, try numberFormat(at: interpolation.node, options: interpolation.formatOptions)))
                    } else if type == .date {
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
        if let literal = NumberLiteralSyntax(node) {
            guard type == .plainNumber, literal.unit == nil, let number = literal.value, number.isFinite else {
                throw issue(.unsupported, node, "Only finite dimensionless numeric literals are implemented")
            }
            return .number(number)
        }
        if let value = ParenExprSyntax(node) { return try lower(value.value.node, depth: depth + 1) }
        if IdentifierExprSyntax(node) != nil {
            guard case .declaration(let identity)? = checked.symbols[checked.tree.id(of: node)], let slot = slots[identity] else {
                throw issue(.unsupported, node, "Only checked widget declarations can be read by this program slice")
            }
            return .declaration(slot)
        }
        if let value = MemberExprSyntax(node) {
            let identity = checked.tree.id(of: node)
            if value.name.token.name == "isMissing" {
                guard type == .bool, let receiver = checked.types[checked.tree.id(of: value.base.node)]?.type,
                      supportedType(receiver), let spec = catalog.member("isMissing", of: receiver, call: false),
                      spec.kind == .field, spec.type == .bool, spec.signatures.isEmpty,
                      spec.lowering == .derived("Any.isMissing"), spec.cadence == .ofRecord,
                      spec.readsSynchronously, spec.permission == nil, !spec.settable, !spec.userInitiatedOnly else {
                    throw issue(.unsupported, node, "Unsupported checked isMissing member contract")
                }
                return .isMissing(try lower(value.base.node, depth: depth + 1))
            }
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
            if member.name.token.name == "ifMissing" {
                guard let receiver = checked.types[checked.tree.id(of: member.base.node)]?.type, supportedType(receiver), type == receiver,
                      arguments.count == 1, arguments[0].label == nil,
                      checked.types[checked.tree.id(of: arguments[0].value.node)]?.type == receiver,
                      let spec = catalog.member("ifMissing", of: receiver, call: true), spec.kind == .function,
                      spec.type == .typeVar(0), spec.cadence == .ofRecord, spec.readsSynchronously,
                      spec.permission == nil, !spec.settable, !spec.userInitiatedOnly,
                      spec.lowering == .derived("Any.ifMissing()"), spec.signatures.count == 1,
                      spec.signatures[0].result == .receiver, spec.signatures[0].params.count == 1,
                      spec.signatures[0].params[0].label == nil, spec.signatures[0].params[0].type == .typeVar(0),
                      spec.signatures[0].params[0].required, !spec.signatures[0].params[0].variadic,
                      spec.signatures[0].params[0].defaultValue == nil else {
                    throw issue(.unsupported, node, "Unsupported checked ifMissing member contract")
                }
                return .ifMissing(try lower(member.base.node, depth: depth + 1), try lower(arguments[0].value.node, depth: depth + 1))
            }
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
        if let value = PrefixExprSyntax(node) {
            let child = try lower(value.operand.node, depth: depth + 1)
            if value.operator.token.text == "not" { return .not(child) }
            if value.operator.token.text == "-" { return .negate(child) }
            throw issue(.unsupported, node, "Unsupported scalar prefix operator")
        }
        if let value = BinaryExprSyntax(node) {
            if ["+", "-", "*", "/", "%", "<", "<=", ">", ">="].contains(value.operator.token.text) {
                guard checked.types[checked.tree.id(of: value.left.node)]?.type == .plainNumber,
                      checked.types[checked.tree.id(of: value.right.node)]?.type == .plainNumber else {
                    throw issue(.unsupported, node, "Arithmetic and ordering require checked dimensionless Number operands")
                }
            }
            let left = try lower(value.left.node, depth: depth + 1), right = try lower(value.right.node, depth: depth + 1)
            switch value.operator.token.text {
            case "and": return .and(left, right)
            case "or": return .or(left, right)
            case "==": return .equal(left, right)
            case "!=": return .notEqual(left, right)
            case "+": return .add(left, right)
            case "-": return .subtract(left, right)
            case "*": return .multiply(left, right)
            case "/": return .divide(left, right)
            case "%": return .remainder(left, right)
            case "<": return .less(left, right)
            case "<=": return .lessOrEqual(left, right)
            case ">": return .greater(left, right)
            case ">=": return .greaterOrEqual(left, right)
            default: throw issue(.unsupported, node, "Unsupported scalar operator: \(value.operator.token.text)")
            }
        }
        if let value = TernaryExprSyntax(node) {
            return .conditional(try lower(value.condition.node, depth: depth + 1),
                                then: try lower(value.then.node, depth: depth + 1),
                                otherwise: try lower(value.otherwise.node, depth: depth + 1))
        }
        throw issue(.unsupported, node, "Unsupported scalar expression: \(node.kind.rawValue)")
    }

    private func supportedType(_ type: DeskType) -> Bool {
        type == .string || type == .bool || type == .date || type == .plainNumber
    }

    private func numberFormat(at node: PositionedNode, options: [FormatOptionSyntax]) throws -> ProgramNumberFormat {
        guard let rule = catalog.typeFormats.first(where: { $0.type == .plainNumber }), rule.decimals == nil, rule.style == nil,
              catalog.typeFormats.contains(where: { $0.type == .any && $0.decimals == nil && $0.style == nil }) else {
            throw issue(.unsupported, node, "Unsupported catalog plain-number or missing default format")
        }
        var decimals: Int?, missing = "–", labels = Set<String>()
        for option in options {
            let label = option.label.name
            guard labels.insert(label).inserted else { throw issue(.unsupported, option.node, "Duplicate number format option") }
            switch label {
            case "decimals":
                guard let spec = catalog.formatOptions.first(where: { $0.label == label && $0.appliesTo == [.anyNumber] }),
                      spec.type == .plainNumber, spec.range == 0...10,
                      checked.types[checked.tree.id(of: option.value.node)]?.type == .plainNumber,
                      let literal = NumberLiteralSyntax(option.value.node), literal.unit == nil,
                      let n = literal.value, n.isFinite, (0...10).contains(n), n.rounded(.towardZero) == n else {
                    throw issue(.unsupported, option.node, "decimals requires the catalog's literal integer 0...10 contract")
                }
                decimals = Int(n)
            case "missing":
                guard let spec = catalog.formatOptions.first(where: { $0.label == label && $0.appliesTo == [.any] }),
                      spec.type == .string, spec.range == nil,
                      checked.types[checked.tree.id(of: option.value.node)]?.type == .string,
                      let text = StringLiteralSyntax(option.value.node)?.literalValue,
                      text.utf16.count <= min(ProgramLimits.maximumTextLength, catalog.limits.maximumTextLength) else {
                    throw issue(.unsupported, option.node, "missing requires the catalog's literal String contract")
                }
                missing = text
            default: throw issue(.unsupported, option.node, "Unsupported plain-number format option: \(label)")
            }
        }
        return ProgramNumberFormat(decimals: decimals, missing: missing)
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
