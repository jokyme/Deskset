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
                throw issue(.unsupported, declaration.node, "Only String, Bool, Date and plain/Percent/Bytes/Duration/Length declarations are implemented")
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
        guard type == .string || type == .date || type.flatMap(numberDimension) != nil else {
            throw issue(.unsupported, node, "Text requires String, Date or plain/Percent/Bytes/Duration/Length; other value formatting is not implemented")
        }
        let value = try lower(node, depth: 1)
        if let type, numberDimension(type) != nil { return .formatNumber(value, try numberFormat(at: node, type: type, options: [])) }
        return type == .date ? .formatDate(value, try defaultDateFormat(at: node)) : value
    }

    mutating func fontSize(_ node: PositionedNode) throws -> ProgramExpression {
        guard let type = checked.types[checked.tree.id(of: node)]?.type else {
            throw issue(.invalidCheckedModel, node, "Missing checked font-size type")
        }
        guard type == .plainNumber || type == .length else {
            throw issue(.unsupported, node, "Font size requires a checked Plain or Length expression")
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
        guard supportedType(type) else {
            throw issue(.unsupported, node, "Only String, Bool, Date and plain/Percent/Bytes/Duration/Length expressions are implemented")
        }
        let identity = checked.tree.id(of: node)
        let coercion = checked.numericCoercions[identity]
        if coercion != nil && type != .plainNumber {
            throw issue(.invalidCheckedModel, node, "A percent-as-fraction use must have final plain type")
        }
        // Validate the original supported subtree before folding the checker's actual constant. A constant
        // conditional must not hide an unsupported branch, and no variable initializer is inferred here.
        let raw = try lowerValue(node, type: coercion == .percentAsFraction ? .percent : type, depth: depth)
        if let canonical = checked.canonicalNumericValues[identity] {
            guard let dimension = numberDimension(type), canonical.isFinite else {
                throw issue(.invalidCheckedModel, node, "Invalid checked canonical numeric constant")
            }
            return try quantity(canonical, dimension: dimension, at: node)
        }
        if coercion == .percentAsFraction {
            // The receipt identifies one original Percent use. Existing Percent/Percent division yields Plain;
            // Percent-times-Bytes has no receipt and keeps the shared runtime's percentage algebra unchanged.
            return .divide(raw, .quantity(ProgramNumber(100, dimension: .percent)))
        }
        return raw
    }

    private mutating func lowerValue(_ node: PositionedNode, type: DeskType, depth: Int) throws -> ProgramExpression {
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
                    if let type, numberDimension(type) != nil {
                        parts.append(.formatNumber(expression, try numberFormat(at: interpolation.node, type: type, options: interpolation.formatOptions)))
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
            guard let recordedType = checked.types[checked.tree.id(of: node)]?.type, let dimension = numberDimension(recordedType),
                  literal.value?.isFinite == true,
                  let canonical = checked.canonicalNumericValues[checked.tree.id(of: node)], canonical.isFinite else {
                throw issue(.invalidCheckedModel, node, "Numeric literal requires a final checked canonical value")
            }
            if let spelling = literal.unit, let unit = catalog.units.first(where: { $0.spelling == spelling.text }) {
                let natural = numberDimension(.number(unit.dimension))
                guard spelling.status == .known, natural != nil, unit.factor.isFinite, unit.offset == 0,
                      natural == dimension || natural == .percent && dimension == .plain && checked.numericCoercions[checked.tree.id(of: node)] == .percentAsFraction else {
                    throw issue(.unsupported, node, "Unsupported numeric unit catalog contract")
                }
            } else if literal.unit != nil { throw issue(.unsupported, node, "Unknown numeric unit catalog contract") }
            return try quantity(canonical, dimension: dimension, at: node)
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
            if checked.symbols[identity] == .builtIn(.member(namespace: "system", name: "dark")) {
                guard checked.dataUses.contains(where: { $0.reference == identity && $0.nodePath == "system" && $0.memberPath == "system.dark" && $0.arguments.isEmpty && $0.instanceScope.isEmpty }),
                      let member = catalog.member(path: "system.dark"), member.kind == .field, member.type == .bool,
                      member.cadence == .event, member.readsSynchronously, member.permission == nil,
                      catalog.namespace(named: "system")?.permission == nil, !member.settable,
                      case .native(let kernel, let options, let field) = member.lowering,
                      kernel == "appearance", options.isEmpty, field == "dark" else {
                    throw issue(.unsupported, node, "Unsupported system.dark catalog or checked data identity")
                }
                return .appearanceDark
            }
            if let property = try systemProperty(for: checked.symbols[identity], identity: identity, at: node) {
                return .systemProperty(property)
            }
            throw issue(.unsupported, node, "Only checked system.dark, time.now and supported system data inputs are implemented")
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
                let left = checked.types[checked.tree.id(of: value.left.node)]?.type,
                    right = checked.types[checked.tree.id(of: value.right.node)]?.type
                guard let left, let right, supportedType(left), supportedType(right),
                      (numberDimension(left) != nil || left == .date), (numberDimension(right) != nil || right == .date),
                      !["<", "<=", ">", ">="].contains(value.operator.token.text) || numberDimension(left) != nil && numberDimension(right) != nil else {
                    throw issue(.unsupported, node, "Arithmetic requires supported checked numeric/Date operands; Date ordering is not implemented")
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
        type == .string || type == .bool || type == .date || numberDimension(type) != nil
    }

    private func numberDimension(_ type: DeskType) -> ProgramNumberDimension? {
        switch type {
        case .plainNumber: return .plain
        case .percent: return .percent
        case .bytes: return .bytes
        case .duration: return .duration
        case .length: return .length
        default: return nil
        }
    }

    private func quantity(_ value: Double, dimension: ProgramNumberDimension, at node: PositionedNode) throws -> ProgramExpression {
        let base = checked.types[checked.tree.id(of: node)]?.displayBase
        guard dimension == .bytes ? (base == nil || base == 1000 || base == 1024) : base == nil else {
            throw issue(.invalidCheckedModel, node, "Invalid checked numeric display base")
        }
        return dimension == .plain ? .number(value) : .quantity(ProgramNumber(value, dimension: dimension, displayBase: base))
    }

    private func numberFormat(at node: PositionedNode, type: DeskType, options: [FormatOptionSyntax]) throws -> ProgramNumberFormat {
        guard let dimension = numberDimension(type), let rule = catalog.typeFormats.first(where: { $0.type == type }),
              rule.decimals == (dimension == .percent ? 0 : nil),
              rule.style == (dimension == .duration ? .style(".full") : nil),
              catalog.typeFormats.contains(where: { $0.type == .any && $0.decimals == nil && $0.style == nil }) else {
            throw issue(.unsupported, node, "Unsupported catalog numeric or missing default format")
        }
        var decimals: Int?, missing = "–", labels = Set<String>()
        var unit: ProgramNumberFormat.ByteUnit?, unitStyle: ProgramNumberFormat.UnitStyle?, durationStyle: ProgramNumberFormat.DurationStyle?
        for option in options {
            let label = option.label.name
            guard labels.insert(label).inserted else { throw issue(.unsupported, option.node, "Duplicate number format option") }
            switch label {
            case "decimals":
                guard dimension != .duration else {
                    throw issue(.unsupported, option.node, "Duration decimals are not implemented")
                }
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
            case "unit", "unitStyle", "style":
                let enumName = label == "unit" ? "ByteUnit" : label == "unitStyle" ? "UnitStyle" : "DurationStyle"
                guard (label == "style" ? dimension == .duration : dimension == .bytes),
                      let spec = catalog.formatOptions.first(where: { $0.label == label && $0.type == .enumeration(enumName) }),
                      spec.appliesTo.contains(type), spec.range == nil,
                      checked.types[checked.tree.id(of: option.value.node)]?.type == .enumeration(enumName),
                      case .enumCase(let recordedEnum, let name)? = checked.symbols[checked.tree.id(of: option.value.node)],
                      recordedEnum == enumName, catalog.enumeration(enumName)?.enumCase(named: name) != nil else {
                    throw issue(.unsupported, option.node, "Unit/style option requires its checked catalog enum case")
                }
                if label == "unit" {
                    guard let value = ProgramNumberFormat.ByteUnit(rawValue: name) else { throw issue(.unsupported, option.node, "Unsupported ByteUnit case") }
                    unit = value
                } else if label == "unitStyle" {
                    guard let value = ProgramNumberFormat.UnitStyle(rawValue: name) else { throw issue(.unsupported, option.node, "Unsupported UnitStyle case") }
                    unitStyle = value
                } else {
                    guard let value = ProgramNumberFormat.DurationStyle(rawValue: name) else { throw issue(.unsupported, option.node, "Unsupported DurationStyle case") }
                    durationStyle = value
                }
            default: throw issue(.unsupported, option.node, "Unsupported numeric format option: \(label)")
            }
        }
        return ProgramNumberFormat(decimals: decimals, missing: missing, unit: unit, unitStyle: unitStyle, durationStyle: durationStyle)
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

    private func systemProperty(for symbol: Symbol?, identity: NodeID, at node: PositionedNode) throws -> ProgramSystemProperty? {
        guard case .builtIn(.member(let namespace, let name))? = symbol else { return nil }
        let fullPath = "\(namespace).\(name)"
        guard let property = ProgramSystemProperty(rawValue: fullPath) else { return nil }
        guard checked.dataUses.contains(where: {
            $0.reference == identity && $0.nodePath == namespace && $0.memberPath == fullPath && $0.arguments.isEmpty && $0.instanceScope.isEmpty
        }) else {
            throw issue(.unsupported, node, "Unsupported checked data use for \(fullPath)")
        }
        guard let member = catalog.member(path: fullPath),
              catalog.namespace(named: namespace)?.permission == nil,
              validateSystemPropertyContract(property: property, member: member) else {
            throw issue(.unsupported, node, "Unsupported \(fullPath) catalog contract")
        }
        return property
    }

    private func validateSystemPropertyContract(property: ProgramSystemProperty, member: MemberSpec) -> Bool {
        guard member.kind == .field, member.permission == nil, !member.settable else { return false }
        switch property {
        case .cpuUsage:
            return member.type == .percent && member.range == .fixed(0...100) && member.cadence == .periodic(seconds: 1) && !member.readsSynchronously &&
                member.lowering == CatalogData.measureKernel("CPU", ["Processor": "0"])
        case .cpuCoreCount:
            return member.type == .plainNumber && member.cadence == .once && member.readsSynchronously &&
                member.lowering == CatalogData.nativeKernel("cpuInfo", field: "coreCount")
        case .memoryUsed:
            return member.type == .bytes && member.displayBase == 1024 && member.cadence == .periodic(seconds: 2) && !member.readsSynchronously &&
                member.lowering == CatalogData.measureKernel("PhysicalMemory")
        case .memoryTotal:
            return member.type == .bytes && member.displayBase == 1024 && member.cadence == .once && member.readsSynchronously &&
                member.lowering == CatalogData.measureKernel("PhysicalMemory", ["Total": "1"])
        case .memoryFree:
            return member.type == .bytes && member.displayBase == 1024 && member.cadence == .periodic(seconds: 2) && !member.readsSynchronously &&
                member.lowering == CatalogData.measureKernel("PhysicalMemory", ["InvertMeasure": "1"])
        case .memoryUsage:
            return member.type == .percent && member.range == .fixed(0...100) && member.cadence == .periodic(seconds: 2) && !member.readsSynchronously &&
                member.lowering == .derived("memory.used / memory.total * 100%")
        case .batteryLevel:
            return member.type == .percent && member.range == .fixed(0...100) && member.cadence == .eventAndPeriodic(seconds: 60) && !member.readsSynchronously &&
                member.lowering == CatalogData.pluginKernel("PowerPlugin", ["PowerState": "Percent"])
        case .batteryCharging:
            return member.type == .bool && member.cadence == .event && !member.readsSynchronously &&
                member.lowering == CatalogData.pluginKernel("PowerPlugin", ["PowerState": "Status"])
        case .batteryPluggedIn:
            return member.type == .bool && member.cadence == .event && !member.readsSynchronously &&
                member.lowering == CatalogData.pluginKernel("PowerPlugin", ["PowerState": "ACLine"])
        }
    }

    private func issue(_ kind: DeskCompilationIssue.Kind, _ node: PositionedNode, _ message: String) -> DeskCompilationIssue {
        DeskCompilationIssue(kind: kind, file: checked.tree.file, range: node.textRange, message: message)
    }
}
