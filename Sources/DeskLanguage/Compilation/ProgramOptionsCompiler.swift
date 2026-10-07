import Foundation
import DesksetCore

/// Option definitions retain their declaration identities. Panel text never becomes a stored value.
struct ProgramOptionsCompiler {
    let checked: CheckedFile
    let catalog: DeskCatalog
    private(set) var nodeCount = 0
    private var declarations: [String: OptionDeclSyntax] = [:]

    init(checked: CheckedFile, catalog: DeskCatalog) throws {
        self.checked = checked
        self.catalog = catalog
        let blocks = checked.tree.rootNode.childNodes.filter { $0.kind == .optionsBlock }
        guard blocks.count <= 1 else { throw issue(.invalidCheckedModel, checked.tree.rootNode, "Duplicate options blocks") }
        for node in blocks {
            guard let block = TopLevelBlockSyntax(node) else { throw issue(.invalidCheckedModel, node, "Missing options block") }
            try collect(block.block, depth: 1)
        }
        guard Set(declarations.keys) == Set(checked.options.keys) else {
            throw issue(.invalidCheckedModel, checked.tree.rootNode, "Option facts do not match the authored local declarations")
        }
    }

    mutating func compile(expressions: inout ProgramExpressionCompiler) throws -> [ProgramOptionNode] {
        try expressions.registerOptions(checked.options)
        var result: [ProgramOptionNode] = []
        for node in checked.tree.rootNode.childNodes where node.kind == .optionsBlock {
            guard let block = TopLevelBlockSyntax(node) else { throw issue(.invalidCheckedModel, node, "Missing options block") }
            result.append(contentsOf: try items(block.block, expressions: &expressions))
        }
        return result
    }

    private mutating func collect(_ block: BlockSyntax, depth: Int) throws {
        guard depth <= min(ProgramLimits.maximumDepth, catalog.limits.maximumBlockNesting) else {
            throw issue(.resourceLimit, block.node, "Shared option nesting limit exceeded")
        }
        for node in block.items {
            nodeCount += 1
            guard nodeCount <= min(ProgramLimits.maximumElements, catalog.limits.maximumElementInstances) else {
                throw issue(.resourceLimit, node, "Shared option element limit exceeded")
            }
            if let declaration = OptionDeclSyntax(node) {
                let name = declaration.target.name.token.name
                guard declarations[name] == nil, let facts = checked.options[name],
                      facts.node == checked.tree.id(of: node), facts.name == name, facts.scope == .widget,
                      let call = declaration.controlCall, call.callee.path == [facts.control], call.block == nil else {
                    throw issue(.invalidCheckedModel, node, "Option has no matching local declaration and control")
                }
                guard ["Toggle", "Input", "Slider", "Stepper", "Picker"].contains(facts.control) else {
                    throw issue(.unsupported, call.node, "This option control requires additional persistent value support")
                }
                let spec = try control(facts.control, at: call.node)
                _ = try arguments(call, spec: spec)
                if let symbol = checked.symbols[checked.tree.id(of: call.callee.node)], symbol != .builtIn(.control(facts.control)) {
                    throw issue(.invalidCheckedModel, call.callee.node, "Option control has a different checked identity")
                }
                if facts.localEnum != nil {
                    guard facts.control == "Picker", facts.type == .enumeration(facts.localEnum!),
                          facts.displayBase == nil, facts.localEnum == localEnumName(name) else { throw issue(.invalidCheckedModel, node, "Invalid local Picker enum facts") }
                    let values = try choiceSources(call)
                    let names = try values.map { try caseName($0.value, facts: facts) }
                    guard !names.isEmpty, names == facts.choices else {
                        throw issue(.invalidCheckedModel, node, "Picker choices do not match their final nominal enum facts")
                    }
                } else {
                    guard facts.choices.isEmpty else { throw issue(.invalidCheckedModel, node, "Scalar option has enum choice facts") }
                    switch facts.control {
                    case "Toggle": guard facts.type == .bool, facts.displayBase == nil else { throw issue(.invalidCheckedModel, node, "Toggle requires final Bool facts") }
                    case "Input": guard facts.type == .string, facts.displayBase == nil else { throw issue(.invalidCheckedModel, node, "Input requires final String facts") }
                    case "Picker":
                        guard facts.type == .string || dimension(facts.type) != nil else {
                            throw issue(.unsupported, node, "Catalog enum and Color options are not implemented")
                        }
                    default: guard dimension(facts.type) != nil else { throw issue(.unsupported, node, "Unsupported numeric option dimension") }
                    }
                    guard facts.type == .bytes ? [1000, 1024].contains(facts.displayBase ?? 1000) : facts.displayBase == nil else {
                        throw issue(.invalidCheckedModel, node, "Invalid option display base")
                    }
                }
                let args = try arguments(call, spec: spec)
                let defaultSource = args["default"] ?? (["Slider", "Stepper"].contains(facts.control) ? args["min"] : nil)
                guard facts.defaultText == defaultSource?.node.trimmedText else {
                    throw issue(.invalidCheckedModel, node, "Option default source does not match its checked facts")
                }
                declarations[name] = declaration
            } else if let call = CallStmtSyntax(node), call.callee.path == ["Section"],
                      let inner = call.block, call.modifiers.isEmpty {
                if let symbol = checked.symbols[checked.tree.id(of: call.callee.node)], symbol != .builtIn(.control("Section")) {
                    throw issue(.invalidCheckedModel, call.callee.node, "Section has a different checked identity")
                }
                _ = try arguments(call, spec: control("Section", at: node))
                try collect(inner, depth: depth + 1)
            } else { throw issue(.unsupported, node, "Only local option declarations and Section blocks are implemented") }
        }
    }

    private mutating func items(_ block: BlockSyntax, expressions: inout ProgramExpressionCompiler) throws -> [ProgramOptionNode] {
        try block.items.map { node in
            try expressions.accountOptionNode(node)
            if let declaration = OptionDeclSyntax(node), let call = declaration.controlCall,
               let facts = checked.options[declaration.target.name.token.name] {
                return .option(try option(facts, call: call, expressions: &expressions))
            }
            guard let call = CallStmtSyntax(node), let inner = call.block else {
                throw issue(.invalidCheckedModel, node, "Missing checked Section body")
            }
            let args = try arguments(call, spec: control("Section", at: node))
            guard let title = args["title"] else { throw issue(.invalidCheckedModel, node, "Missing Section title") }
            let text = try titleExpression(title, expressions: &expressions)
            return .section(title: text, items: try items(inner, expressions: &expressions))
        }
    }

    private mutating func option(_ facts: OptionFacts, call: CallStmtSyntax,
                                 expressions: inout ProgramExpressionCompiler) throws -> ProgramOption {
        let args = try arguments(call, spec: control(facts.control, at: call.node))
        guard let label = args["label"] else { throw issue(.invalidCheckedModel, call.node, "Missing option label") }
        let title = try titleExpression(label, expressions: &expressions)
        let control: ProgramOptionControl
        let fallback: ProgramOptionValue
        switch facts.control {
        case "Toggle": control = .toggle; fallback = .boolean(false)
        case "Input":
            control = .input(placeholder: try args["placeholder"].map { try titleExpression($0, expressions: &expressions) })
            fallback = .string("")
        case "Slider", "Stepper":
            guard let minimum = args["min"], let maximum = args["max"] else {
                throw issue(.invalidCheckedModel, call.node, "Numeric option requires both bounds")
            }
            let min = try number(minimum, facts: facts, expressions: &expressions)
            let max = try number(maximum, facts: facts, expressions: &expressions)
            guard min.value <= max.value else { throw issue(.invalidProgram, call.node, "Option minimum exceeds its maximum") }
            let step = try args["step"].map { try number($0, facts: facts, expressions: &expressions) }
            guard step == nil || step!.value > 0 else { throw issue(.invalidProgram, call.node, "Option step must be positive") }
            if facts.control == "Slider" { control = .slider(min: min, max: max, step: step) }
            else { control = .stepper(min: min, max: max, step: step ?? ProgramNumber(1, dimension: min.dimension, displayBase: min.displayBase)) }
            fallback = .number(min)
        case "Picker":
            let sources = try choiceSources(call)
            guard !sources.isEmpty else { throw issue(.invalidProgram, call.node, "Picker requires a choice") }
            var choices: [ProgramOptionChoice] = []
            for source in sources {
                try expressions.accountOptionNode(source.value)
                let value = try constant(source.value, facts: facts, expressions: &expressions)
                let text: ProgramExpression
                if let label = source.label { text = try titleExpression(label, expressions: &expressions) }
                else {
                    switch value {
                    case .string(let string):
                        guard let literal = StringLiteralSyntax(source.value) else { throw issue(.invalidCheckedModel, source.value, "String Picker choice requires its source literal") }
                        text = try expressions.optionTitle(string, key: DeskTranslationKeys.key(of: literal, in: checked.tree), at: source.value)
                    case .number: text = try expressions.copyText(source.value)
                    case .localCase(_, let name):
                        let words = SchemaBuilder.words(name)
                        text = try expressions.optionTitle(words, key: words, at: source.value)
                    default: throw issue(.invalidCheckedModel, source.value, "Unsupported Picker choice")
                    }
                }
                choices.append(ProgramOptionChoice(value: value, title: text))
            }
            control = .picker(choices: choices); fallback = choices[0].value
        default: throw issue(.unsupported, call.node, "Unsupported option control")
        }
        let value = try args["default"].map { try constant($0, facts: facts, expressions: &expressions) } ?? fallback
        switch control {
        case .slider(let min, let max, _), .stepper(let min, let max, _):
            guard case .number(let number) = value, number.value >= min.value, number.value <= max.value else {
                throw issue(.invalidProgram, call.node, "Option default is outside its bounds")
            }
        case .picker(let choices):
            guard choices.contains(where: { $0.value == value }) else { throw issue(.invalidProgram, call.node, "Option default is not a choice") }
        default: break
        }
        var help: ProgramExpression?, hidden: [ProgramExpression] = []
        for modifier in call.modifiers {
            guard modifier.block == nil else { throw issue(.unsupported, modifier.node, "Option modifier blocks are not implemented") }
            let name = modifier.name.token.name
            let args = modifier.arguments?.arguments ?? []
            if let symbol = checked.symbols[checked.tree.id(of: modifier.node)], symbol != .builtIn(.modifier(name)) {
                throw issue(.invalidCheckedModel, modifier.node, "Option modifier has a different checked identity")
            }
            switch name {
            case "help":
                try modifierContract(name, at: modifier.node)
                guard help == nil, args.count == 1, args[0].label == nil else { throw issue(.invalidCheckedModel, modifier.node, "Help requires one own text argument") }
                help = try titleExpression(args[0].value.node, expressions: &expressions)
            case "hidden":
                try modifierContract(name, at: modifier.node)
                guard args.count <= 1, args.isEmpty || args.first?.label?.name == "if" && args.first?.colon?.kind == .colon else { throw issue(.invalidCheckedModel, modifier.node, "Hidden requires its optional if argument") }
                if let condition = args.first?.value.node {
                    try optionCondition(condition)
                    hidden.append(try expressions.condition(condition))
                } else { try expressions.accountOptionNode(modifier.node); hidden.append(.boolean(true)) }
            default: throw issue(.unsupported, modifier.node, "Only ordinary help and options-only hidden modifiers are implemented")
            }
        }
        return ProgramOption(name: facts.name, title: title, control: control, defaultValue: value, help: help,
                             hiddenIf: try expressions.hiddenConditions(hidden, at: call.node))
    }

    private func number(_ node: PositionedNode, facts: OptionFacts, expressions: inout ProgramExpressionCompiler) throws -> ProgramNumber {
        try constantSyntax(node)
        guard checked.types[checked.tree.id(of: node)]?.type == facts.type, let d = dimension(facts.type) else {
            throw issue(.invalidCheckedModel, node, "Numeric option parameter does not have its settled dimension")
        }
        let value = try expressions.optionNumber(node)
        guard value.dimension == d, value.value.isFinite else { throw issue(.invalidCheckedModel, node, "Invalid numeric option constant") }
        return ProgramNumber(value.value, dimension: d, displayBase: facts.displayBase)
    }

    private func constant(_ node: PositionedNode, facts: OptionFacts, expressions: inout ProgramExpressionCompiler) throws -> ProgramOptionValue {
        if facts.localEnum != nil {
            let name = try caseName(node, facts: facts)
            _ = try expressions.optionCase(node, facts: facts, allowsAbsentReceipt: true)
            return .localCase(option: facts.name, name: name)
        }
        if dimension(facts.type) != nil { return .number(try number(node, facts: facts, expressions: &expressions)) }
        try constantSyntax(node)
        guard checked.types[checked.tree.id(of: node)]?.type == facts.type else { throw issue(.invalidCheckedModel, node, "Option default has inconsistent checked type") }
        try expressions.accountOptionNode(node)
        if let paren = ParenExprSyntax(node) { return try constant(paren.value.node, facts: facts, expressions: &expressions) }
        if facts.type == .bool {
            _ = try expressions.condition(node)
            return .boolean(try boolean(node))
        }
        if let value = StringLiteralSyntax(node)?.literalValue, facts.type == .string {
            guard value.utf16.count <= min(ProgramLimits.maximumTextLength, catalog.limits.maximumTextLength),
                  value.utf8.count <= catalog.limits.maximumSavedValueBytes else { throw issue(.resourceLimit, node, "Stored option text exceeds its value limit") }
            return .string(value)
        }
        throw issue(.unsupported, node, "Option defaults require supported literal constants")
    }

    private func titleExpression(_ node: PositionedNode, expressions: inout ProgramExpressionCompiler) throws -> ProgramExpression {
        try constantSyntax(node, allowsInterpolation: true)
        guard checked.types[checked.tree.id(of: node)]?.type == .string else { throw issue(.invalidCheckedModel, node, "Option panel text requires its checked String type") }
        return try expressions.text(node)
    }

    private func constantSyntax(_ node: PositionedNode, allowsInterpolation: Bool = false, depth: Int = 1) throws {
        guard depth <= min(ProgramLimits.maximumExpressionDepth, catalog.limits.maximumExpressionNesting) else { throw issue(.resourceLimit, node, "Option constant depth exceeded") }
        let identity = checked.tree.id(of: node)
        if let paren = ParenExprSyntax(node) {
            try constantSyntax(paren.value.node, allowsInterpolation: allowsInterpolation, depth: depth + 1)
            let inner = checked.tree.id(of: paren.value.node)
            guard checked.types[identity] == checked.types[inner], checked.symbols[identity] == nil,
                  checked.canonicalNumericValues[identity] == checked.canonicalNumericValues[inner],
                  checked.numericCoercions[identity] == checked.numericCoercions[inner] else {
                throw issue(.invalidCheckedModel, node, "Option parentheses do not preserve their checked value")
            }
            return
        }
        if let literal = NumberLiteralSyntax(node) {
            guard let written = literal.value, written.isFinite, literal.unitAfterSpace == nil,
                  let type = checked.types[identity], let d = dimension(type.type),
                  let value = checked.canonicalNumericValues[identity], value.isFinite,
                  checked.numericCoercions[identity] == nil, checked.symbols[identity] == nil else {
                throw issue(.invalidCheckedModel, node, "Option number lacks its checked canonical receipt")
            }
            var expected = written
            if let spelling = literal.unit {
                guard spelling.status == .known, let unit = catalog.unit(spelling: spelling.text),
                      dimension(.number(unit.dimension)) == d, unit.offset == 0, unit.factor.isFinite, unit.factor > 0 else {
                    throw issue(.unsupported, node, "Unsupported option unit contract")
                }
                expected *= unit.factor(base: type.displayBase ?? 1000)
            }
            guard value == expected else { throw issue(.invalidCheckedModel, node, "Option number has a different canonical value") }
            return
        }
        if let prefix = PrefixExprSyntax(node), prefix.operator.token.text == "-" {
            try constantSyntax(prefix.operand.node, depth: depth + 1)
            let operand = checked.tree.id(of: prefix.operand.node)
            guard let child = checked.canonicalNumericValues[operand], checked.canonicalNumericValues[identity] == -child,
                  checked.types[identity] == checked.types[operand], checked.numericCoercions[identity] == nil else { throw issue(.invalidCheckedModel, node, "Signed option constant has inconsistent receipts") }
            return
        }
        if let prefix = PrefixExprSyntax(node), prefix.operator.token.text == "not" {
            try constantSyntax(prefix.operand.node, depth: depth + 1)
            guard checked.types[identity]?.type == .bool, checked.types[checked.tree.id(of: prefix.operand.node)]?.type == .bool,
                  checked.canonicalNumericValues[identity] == nil, checked.numericCoercions[identity] == nil else { throw issue(.invalidCheckedModel, node, "Invalid constant Bool option expression") }
            return
        }
        if let binary = BinaryExprSyntax(node), ["+", "-", "*", "/", "%"].contains(binary.operator.token.text) {
            try constantSyntax(binary.left.node, depth: depth + 1); try constantSyntax(binary.right.node, depth: depth + 1)
            guard checked.canonicalNumericValues[identity]?.isFinite == true else { throw issue(.unsupported, node, "Option arithmetic requires a checked canonical constant") }
            return
        }
        if let binary = BinaryExprSyntax(node), ["and", "or"].contains(binary.operator.token.text) {
            try constantSyntax(binary.left.node, depth: depth + 1); try constantSyntax(binary.right.node, depth: depth + 1)
            guard checked.types[identity]?.type == .bool, checked.types[checked.tree.id(of: binary.left.node)]?.type == .bool,
                  checked.types[checked.tree.id(of: binary.right.node)]?.type == .bool,
                  checked.canonicalNumericValues[identity] == nil, checked.numericCoercions[identity] == nil else { throw issue(.invalidCheckedModel, node, "Invalid constant Bool option expression") }
            return
        }
        guard checked.canonicalNumericValues[identity] == nil, checked.numericCoercions[identity] == nil else { throw issue(.invalidCheckedModel, node, "Nonnumeric option constant has numeric receipts") }
        if BoolLiteralSyntax(node) != nil {
            guard checked.types[identity]?.type == .bool, checked.symbols[identity] == nil else { throw issue(.invalidCheckedModel, node, "Invalid Bool option receipt") }; return
        }
        if let string = StringLiteralSyntax(node) {
            guard checked.types[identity]?.type == .string, checked.symbols[identity] == nil else { throw issue(.invalidCheckedModel, node, "Invalid String option receipt") }
            if string.literalValue != nil { return }
            guard allowsInterpolation else { throw issue(.unsupported, node, "Stored option defaults require literal text") }
            for segment in string.segments {
                if case .interpolation(let value) = segment { try constantSyntax(value.value.node, depth: depth + 1) }
                if case .foreign(let value) = segment { throw issue(.unsupported, value, "Foreign option interpolation is not implemented") }
            }
            return
        }
        throw issue(.unsupported, node, "Dynamic option defaults, constraints and panel text are not implemented")
    }

    private func optionCondition(_ node: PositionedNode) throws {
        guard let dependencies = checked.dependencies[checked.tree.id(of: node)], dependencies.allSatisfy({ if case .option = $0 { return true }; return false }) else {
            throw issue(.invalidCheckedModel, node, "Option hidden condition lacks its options-only dependencies")
        }
        var pending = [node]
        var reads = Set<String>()
        while let current = pending.popLast() {
            if let member = MemberExprSyntax(current), IdentifierExprSyntax(member.base.node)?.name == "options" {
                guard let facts = checked.options[member.name.token.name], facts.scope == .widget,
                      checked.symbols[checked.tree.id(of: current)] == .option(facts.node, file: checked.tree.file) else { throw issue(.invalidCheckedModel, current, "Option hidden condition reads a different declaration") }
                reads.insert(facts.name)
                continue
            }
            if case .enumCase(let type, let name)? = checked.symbols[checked.tree.id(of: current)],
               checked.options.values.contains(where: { $0.localEnum == type && $0.choices.contains(name) }),
               checked.types[checked.tree.id(of: current)]?.type == .enumeration(type) { continue }
            if IdentifierExprSyntax(current) != nil { throw issue(.unsupported, current, "Option hidden conditions may read only local options") }
            pending.append(contentsOf: current.childNodes)
        }
        guard dependencies == Set(reads.map { DepKey.option($0) }) else {
            throw issue(.invalidCheckedModel, node, "Option hidden dependencies do not match their source reads")
        }
    }

    private func choiceSources(_ call: CallStmtSyntax) throws -> [(value: PositionedNode, label: PositionedNode?)] {
        let args = try arguments(call, spec: control("Picker", at: call.node))
        guard let source = args["choices"], let list = ListLiteralSyntax(source) else { throw issue(.invalidCheckedModel, call.node, "Picker requires its source list") }
        return try list.elements.map { item in
            if let choice = CallExprSyntax(item.node) {
                _ = try control("Choice", at: choice.node)
                let args = choice.arguments.arguments
                guard IdentifierExprSyntax(choice.callee.node)?.name == "Choice", args.count == 2,
                      args.allSatisfy({ $0.label == nil }) else { throw issue(.invalidCheckedModel, choice.node, "Choice requires its exact value and label") }
                if let symbol = checked.symbols[checked.tree.id(of: choice.callee.node)], symbol != .builtIn(.control("Choice")) {
                    throw issue(.invalidCheckedModel, choice.callee.node, "Choice has a different checked identity")
                }
                return (args[0].value.node, args[1].value.node)
            }
            return (item.node, nil)
        }
    }

    private func caseName(_ node: PositionedNode, facts: OptionFacts) throws -> String {
        if let paren = ParenExprSyntax(node) {
            guard checked.types[checked.tree.id(of: node)]?.type == facts.type,
                  checked.canonicalNumericValues[checked.tree.id(of: node)] == nil,
                  checked.numericCoercions[checked.tree.id(of: node)] == nil else { throw issue(.invalidCheckedModel, node, "Invalid local case parentheses") }
            return try caseName(paren.value.node, facts: facts)
        }
        guard let type = facts.localEnum, let name = ImplicitMemberExprSyntax(node)?.name.token.name ?? MemberExprSyntax(node)?.name.token.name,
              ImplicitMemberExprSyntax(node)?.arguments == nil,
              MemberExprSyntax(node).map({ IdentifierExprSyntax($0.base.node)?.name == type }) ?? true,
              facts.choices.contains(name) else { throw issue(.invalidCheckedModel, node, "Choice does not belong to the final local enum") }
        return name
    }

    private func boolean(_ node: PositionedNode) throws -> Bool {
        if let value = BoolLiteralSyntax(node) { return value.value }
        if let paren = ParenExprSyntax(node) { return try boolean(paren.value.node) }
        if let prefix = PrefixExprSyntax(node), prefix.operator.token.text == "not" { return try !boolean(prefix.operand.node) }
        if let binary = BinaryExprSyntax(node) {
            let left = try boolean(binary.left.node), right = try boolean(binary.right.node)
            if binary.operator.token.text == "and" { return left && right }
            if binary.operator.token.text == "or" { return left || right }
        }
        throw issue(.unsupported, node, "Only statically proven Bool option defaults are implemented")
    }

    private func localEnumName(_ name: String) -> String {
        let base = name.prefix(1).uppercased() + name.dropFirst()
        if catalog.component(named: base) != nil || catalog.control(named: base) != nil || catalog.enumeration(base) != nil ||
            catalog.record(base) != nil || base == "Color" || base == "Paint" { return base + "Choice" }
        return base
    }

    private func arguments(_ call: CallStmtSyntax, spec: ControlSpec) throws -> [String: PositionedNode] {
        let parameters = spec.signatures[0].params
        var result: [String: PositionedNode] = [:], positional = 0, sawLabel = false
        for argument in call.arguments?.arguments ?? [] {
            let parameter: ParamSpec
            if let label = argument.label {
                sawLabel = true
                guard let found = parameters.first(where: { $0.label == label.name }), argument.colon?.kind == .colon else { throw issue(.invalidCheckedModel, argument.node, "Unknown option argument label") }
                parameter = found
            } else {
                let values = parameters.filter { $0.label == nil }
                guard !sawLabel, positional < values.count else { throw issue(.invalidCheckedModel, argument.node, "Unexpected option positional argument") }
                parameter = values[positional]; positional += 1
            }
            guard result[parameter.name] == nil else { throw issue(.invalidCheckedModel, argument.node, "Duplicate option argument") }
            result[parameter.name] = argument.value.node
        }
        guard parameters.filter(\.required).allSatisfy({ result[$0.name] != nil }) else { throw issue(.invalidCheckedModel, call.node, "Missing required option argument") }
        return result
    }

    private func control(_ name: String, at node: PositionedNode) throws -> ControlSpec {
        guard let actual = catalog.control(named: name), let standard = DeskCatalog.current.control(named: name),
              actual.valueType == standard.valueType, actual.panel == standard.panel, actual.block == standard.block,
              actual.signatures.count == 1, standard.signatures.count == 1,
              actual.signatures[0].result == standard.signatures[0].result,
              actual.signatures[0].since == standard.signatures[0].since,
              actual.signatures[0].params.count == standard.signatures[0].params.count,
              zip(actual.signatures[0].params, standard.signatures[0].params).allSatisfy({ sameParameter($0.0, $0.1) }) else {
            throw issue(.unsupported, node, "Unsupported option control catalog contract")
        }
        return actual
    }

    private func modifierContract(_ name: String, at node: PositionedNode) throws {
        guard let actual = catalog.modifier(named: name), let standard = DeskCatalog.current.modifier(named: name),
              actual.context == standard.context, actual.repeatable == standard.repeatable,
              actual.block == .none, actual.event == nil, actual.timing == nil,
              actual.inheritable == standard.inheritable, actual.acceptsCondition == standard.acceptsCondition,
              actual.facets == standard.facets, actual.fixedValues == standard.fixedValues,
              actual.signatures.count == 1, actual.signatures[0].params.count == standard.signatures[0].params.count,
              zip(actual.signatures[0].params, standard.signatures[0].params).allSatisfy({ sameParameter($0.0, $0.1) }) else { throw issue(.unsupported, node, "Unsupported option modifier catalog contract") }
    }

    private func sameParameter(_ a: ParamSpec, _ b: ParamSpec) -> Bool {
        a.name == b.name && a.label == b.label && a.type == b.type && a.defaultValue == b.defaultValue &&
        a.required == b.required && a.range == b.range && a.wholeNumber == b.wholeNumber && a.variadic == b.variadic &&
        a.sameAs == b.sameAs && a.facets == b.facets && a.specificity == b.specificity && a.role == b.role &&
        a.source == b.source && a.translatable == b.translatable && a.unit == b.unit
    }

    private func dimension(_ type: DeskType) -> ProgramNumberDimension? {
        switch type {
        case .plainNumber: return .plain
        case .percent: return .percent
        case .bytes: return .bytes
        case .duration: return .duration
        case .length: return .length
        case .angle: return .angle
        default: return nil
        }
    }

    private func issue(_ kind: DeskCompilationIssue.Kind, _ node: PositionedNode, _ message: String) -> DeskCompilationIssue {
        DeskCompilationIssue(kind: kind, file: checked.tree.file, range: node.textRange, message: message)
    }
}
