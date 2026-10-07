import Foundation
import DesksetCore

struct StaticProgramCompiler {
    private(set) var checked: CheckedFile
    let catalog: DeskCatalog
    private var nextIndex = 0
    private var sourceFiles: [Int: CheckedFile] = [:]
    private var styles: [String: StyleDefinition] = [:]
    private var expandedModifiers: [NodeID: [SourcedModifier]] = [:]
    private var styleExpansionCount = 0
    private var allowsStyleParentheses = false
    private var expressions: ProgramExpressionCompiler
    private var onLoad: [ProgramAssignment] = []
    private var clickActionCount = 0
    private var widgetSize = ProgramWidgetSize.fit
    private var seenElements = Set<NodeID>()
    private var optionNodeCount = 0
    private(set) var elementRefs: [ElementID: ElementRef] = [:]

    init(checked: CheckedFile, catalog: DeskCatalog, package: CheckedFile? = nil) throws {
        self.checked = checked
        self.catalog = catalog
        expressions = ProgramExpressionCompiler(checked: checked, catalog: catalog,
            translations: try ProgramTranslationCompiler(checked: checked, package: package, catalog: catalog))
        sourceFiles[checked.tree.version] = checked
        if let package {
            guard package.options.isEmpty,
                  !package.tree.rootNode.childNodes.contains(where: { $0.kind == .optionsBlock }) else {
                throw sourceCompiler(package).issue(.unsupported, package.tree.rootNode, "Package options require package persistence")
            }
            guard sourceFiles[package.tree.version] == nil else {
                throw sourceCompiler(package).issue(.invalidCheckedModel, package.tree.rootNode, "Shared source tree versions must be distinct")
            }
            sourceFiles[package.tree.version] = package
            try collectStyles(package)
        }
        try collectStyles(checked)
    }

    private enum Value {
        case number(Double), string(String), choice(String), boolean(Bool)
    }

    private struct Appearance {
        var family = "System"
        var size = 13.0
        var sizeExpression: ProgramExpression?
        var weight = 400
        var italic = false
        var design = "standard"
        var color = ProgramColor.text
        var align = HorizontalTextAlign.center
        var digits = ProgramText.Digits.automatic
    }

    mutating func compile() throws -> WidgetProgram {
        var optionCompiler = try ProgramOptionsCompiler(checked: checked, catalog: catalog)
        let options = try optionCompiler.compile(expressions: &expressions)
        optionNodeCount = optionCompiler.nodeCount
        var name = URL(fileURLWithPath: checked.tree.file.path).deletingPathExtension().lastPathComponent
        var nameKey: String?
        guard let sizeField = catalog.infoFields.first(where: { $0.name == "size" }),
              sizeField.type == .enumeration("SizePreset"), sizeField.source == .literal,
              case .source(let sizeDefault)? = sizeField.defaultValue,
              case .choice(let defaultSize) = try fixed(sizeDefault, at: checked.tree.rootNode) else {
            throw issue(.unsupported, checked.tree.rootNode, "Unsupported info.size catalog contract")
        }
        widgetSize = try sizePolicy(defaultSize, at: checked.tree.rootNode)
        var widget: BlockSyntax?
        for item in checked.tree.rootNode.childNodes {
            switch item.kind {
            case .infoBlock:
                guard let block = TopLevelBlockSyntax(item) else { throw issue(.invalidCheckedModel, item, "Missing info block") }
                for node in block.block.items {
                    guard let field = FieldSyntax(node) else { throw issue(.unsupported, node, "Unsupported info statement") }
                    switch field.label.name {
                    case "name":
                        guard let spec = catalog.infoFields.first(where: { $0.name == "name" }),
                              spec.type == .string, spec.source == .literal, spec.translatable, spec.inInfo,
                              case .string(let value) = try constant(field.value.node) else {
                            throw issue(.unsupported, field.value.node, "info.name must be literal text")
                        }
                        name = value
                        nameKey = try expressions.nameKey(field.value.node)
                    case "size":
                        let value = field.value.node
                        guard case .choice(let choice) = try constant(value),
                              checked.types[checked.tree.id(of: value)]?.type == .enumeration("SizePreset"),
                              checked.symbols[checked.tree.id(of: value)] == .enumCase(type: "SizePreset", case: choice) else {
                            throw issue(.unsupported, value, "info.size requires a checked SizePreset case")
                        }
                        widgetSize = try sizePolicy(choice, at: value)
                    default: throw issue(.unsupported, node, "Unsupported info field: \(field.label.name)")
                    }
                }
            case .widgetBlock:
                guard widget == nil, let block = TopLevelBlockSyntax(item) else {
                    throw issue(.invalidCheckedModel, item, "Expected one widget block")
                }
                widget = block.block
            case .styleDecl: break // Definitions are version-qualified and expanded only at their checked applications.
            case .optionsBlock: break // Authored local controls and their receipts were lowered before runtime expressions.
            case .translationsBlock: break // The checked table and every authored pattern were validated at initialization.
            default: throw issue(.unsupported, item, "Unsupported top-level construct: \(item.kind.rawValue)")
            }
        }
        guard let widget else { throw issue(.invalidCheckedModel, checked.tree.rootNode, "No checked widget") }
        let declarations = try expressions.declarations(widget.items.compactMap(DeclarationSyntax.init))
        let statements = widget.items.filter { $0.kind != .declaration }
        guard !statements.isEmpty else { throw issue(.unsupported, widget.node, "Widget has no supported element content") }
        let appearance = try defaultAppearance(at: widget.node)
        let root: ProgramElement
        if statements.count == 1, statements[0].kind == .callStmt {
            root = try element(statements[0], inherited: appearance, depth: 1)
        } else {
            let index = try reserveIndex(at: widget.node, depth: 1)
            let children = try statements.map { try viewStatement($0, inherited: appearance, depth: 2) }
            let spacing = try defaultNumber(component: "Column", parameter: "spacing", at: widget.node)
            let align = try defaultChoice(component: "Column", parameter: "align", at: widget.node)
            root = ProgramElement(id: ElementID(name: "widget", index: index),
                                  content: .column(spacing: spacing, align: try horizontal(align, at: widget.node), children: children))
        }
        guard seenElements == Set(checked.elements.keys) else {
            throw issue(.invalidCheckedModel, widget.node, "Checked elements do not match the supported view and menu calls")
        }
        let program = WidgetProgram(name: name, root: root, declarations: declarations, onLoad: onLoad, size: widgetSize,
                                    translations: expressions.translations, nameKey: nameKey, options: options)
        do { _ = try ProgramRuntime(program: program) } // Validate the same contract as every other Core producer.
        catch ProgramRuntimeError.expressionLimit { throw issue(.resourceLimit, widget.node, "Shared program expression limit exceeded") }
        catch ProgramRuntimeError.expressionDepth { throw issue(.resourceLimit, widget.node, "Shared program reference depth exceeded") }
        return program
    }

    private struct StyleDefinition {
        let syntax: StyleDeclSyntax
        let source: CheckedFile
    }

    private struct SourcedModifier {
        let modifier: ModifierAppSyntax
        let source: CheckedFile
        let origin: CandidateOrigin
        var isStyle: Bool { if case .style = origin { return true }; return false }
    }

    private mutating func collectStyles(_ source: CheckedFile) throws {
        let compiler = sourceCompiler(source)
        let declarations = source.tree.rootNode.childNodes.compactMap(StyleDeclSyntax.init)
        guard Set(declarations.map { source.tree.id(of: $0.node) }) == Set(source.styles.values),
              declarations.count == source.styles.count else {
            throw compiler.issue(.invalidCheckedModel, source.tree.rootNode, "Style declarations do not match their checked identities")
        }
        for declaration in declarations {
            let name = declaration.name.token.name
            guard source.styles[name] == source.tree.id(of: declaration.node) else {
                throw compiler.issue(.invalidCheckedModel, declaration.node, "Style has no matching checked declaration")
            }
            styles[name] = StyleDefinition(syntax: declaration, source: source)
        }
    }

    private func styleName(_ modifier: ModifierAppSyntax, source: CheckedFile) throws -> String {
        let compiler = sourceCompiler(source)
        guard source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier("style")),
              let spec = catalog.modifier(named: "style"), spec.context == .view,
              spec.allowedInStyle, spec.allowedInState, !spec.inheritable, !spec.acceptsCondition,
              spec.repeatable == .yes, spec.block == .none, spec.facets.isEmpty, spec.fixedValues.isEmpty,
              spec.event == nil, spec.timing == nil, spec.boxLayer == .none, !spec.softFacets,
              spec.signatures.count == 1, spec.signatures[0].params.count == 2,
              let nameParameter = spec.signatures[0].params.first, nameParameter.name == "name",
              nameParameter.label == nil, nameParameter.type == .styleRef, nameParameter.role == .styleRef,
              nameParameter.required, nameParameter.facets.isEmpty, nameParameter.defaultValue == nil,
              !nameParameter.variadic, !nameParameter.translatable, nameParameter.source == .any,
              nameParameter.sameAs == nil, nameParameter.range == nil, nameParameter.unit == nil, !nameParameter.wholeNumber,
              let condition = spec.signatures[0].param(named: "condition"), condition.label == "if",
              condition.type == .bool, condition.role == .condition, !condition.required,
              condition.facets.isEmpty, condition.defaultValue == nil,
              !condition.variadic, !condition.translatable, condition.source == .any,
              condition.sameAs == nil, condition.range == nil, condition.unit == nil, !condition.wholeNumber,
              spec.appliesTo == ElementKindSet.all, modifier.block == nil else {
            throw compiler.issue(.unsupported, modifier.node, "Unsupported checked style application contract")
        }
        let arguments = modifier.arguments?.arguments ?? []
        guard arguments.count == 1, let argument = arguments.first, argument.label == nil else {
            throw compiler.issue(.unsupported, modifier.node, "Only unconditional, single-name style applications are implemented")
        }
        let value = argument.value.node
        guard let name = IdentifierExprSyntax(value)?.name ?? StringLiteralSyntax(value)?.literalValue,
              case .style(let identity, let file)? = source.symbols[source.tree.id(of: value)],
              let definitionSource = sourceFiles[identity.treeVersion], definitionSource.tree.file == file,
              let definition = definitionSource.tree.resolve(identity).flatMap(StyleDeclSyntax.init),
              definition.name.token.name == name, definitionSource.styles[name] == identity,
              styles[name] != nil else {
            throw compiler.issue(.invalidCheckedModel, value, "Style application has no matching checked definition")
        }
        // A widget's definition replaces the package definition everywhere, including package includes.
        return name
    }

    private func sourceCompiler(_ source: CheckedFile, style: Bool = false) -> StaticProgramCompiler {
        var copy = self
        copy.checked = source
        copy.allowsStyleParentheses = style
        return copy
    }

    private func source(_ candidate: Candidate, at node: PositionedNode) throws -> CheckedFile {
        let identity: NodeID
        let file: DeskFileID
        switch candidate.origin {
        case .own(let id): identity = id; file = checked.tree.file
        case .style(_, let id, let originFile): identity = id; file = originFile
        }
        guard let source = sourceFiles[identity.treeVersion], source.tree.file == file,
              source.tree.resolve(identity) != nil, candidate.value.treeVersion == identity.treeVersion else {
            throw issue(.invalidCheckedModel, node, "Facet origin and value do not belong to one supplied checked tree")
        }
        return source
    }

    private func facetCompiler(_ facts: ElementFacts, _ key: String, at node: PositionedNode) throws -> StaticProgramCompiler {
        guard let candidate = facts.facets[FacetID(key)]?.first else { return self }
        return sourceCompiler(try source(candidate, at: node), style: candidate.level == 2)
    }

    private func sourceModifiers(_ call: CallStmtSyntax, named name: String) -> [SourcedModifier] {
        (expandedModifiers[checked.tree.id(of: call.node)] ?? []).filter { $0.modifier.name.token.text == name }
    }

    private func modifier(_ candidate: Candidate, call: CallStmtSyntax) throws -> SourcedModifier {
        guard let result = expandedModifiers[checked.tree.id(of: call.node)]?.first(where: { $0.origin == candidate.origin }) else {
            throw issue(.invalidCheckedModel, call.node, "Facet has no modifier in the checked style expansion")
        }
        return result
    }

    private mutating func expandModifiers(_ call: CallStmtSyntax, kind: ElementKind,
                                         allowed: Set<String>) throws -> [SourcedModifier] {
        var result: [SourcedModifier] = []
        func expand(_ name: String, path: Set<String>, depth: Int) throws {
            guard depth <= min(ProgramLimits.maximumDepth, catalog.limits.maximumBlockNesting) else {
                throw issue(.resourceLimit, call.node, "Shared program style nesting limit exceeded")
            }
            styleExpansionCount += 1
            guard styleExpansionCount <= min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens) else {
                throw issue(.resourceLimit, call.node, "Shared program style expansion limit exceeded")
            }
            guard !path.contains(name), let definition = styles[name] else {
                throw issue(.invalidCheckedModel, call.node, "Style expansion is cyclic or has no checked definition")
            }
            let source = definition.source
            let compiler = sourceCompiler(source)
            var own: [SourcedModifier] = []
            for statement in definition.syntax.block.items {
                guard let chain = ModifierStmtSyntax(statement) else {
                    throw compiler.issue(.unsupported, statement, "Style bodies require supported constant modifier chains")
                }
                for modifier in chain.modifiers {
                    let modifierName = modifier.name.token.text
                    guard let spec = catalog.modifier(named: modifierName), spec.allowedInStyle,
                          source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier(modifierName)) else {
                        throw compiler.issue(.invalidCheckedModel, modifier.node, "Style modifier has no allowed checked catalog identity")
                    }
                    if modifierName == "style" {
                        try expand(styleName(modifier, source: source), path: path.union([name]), depth: depth + 1)
                        continue
                    }
                    // Inapplicable style modifiers have no candidate and no effect (§4.8.2).
                    guard spec.appliesTo.contains(kind) else { continue }
                    guard allowed.contains(modifierName), modifier.block == nil,
                          !(modifier.arguments?.arguments ?? []).contains(where: { $0.label?.name == "if" }) else {
                        throw compiler.issue(.unsupported, modifier.node, "Only supported unconditional constant style properties are implemented")
                    }
                    styleExpansionCount += 1
                    guard styleExpansionCount <= min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens) else {
                        throw compiler.issue(.resourceLimit, modifier.node, "Shared program style expansion limit exceeded")
                    }
                    own.append(SourcedModifier(modifier: modifier, source: source,
                        origin: .style(name, source.tree.id(of: modifier.node), file: source.tree.file)))
                }
            }
            result += own // Includes precede this style's own properties, irrespective of where an include was written.
        }
        for modifier in call.modifiers where modifier.name.token.text == "style" {
            try expand(styleName(modifier, source: checked), path: [], depth: 1)
        }
        result += call.modifiers.filter { $0.name.token.text != "style" }.map {
            SourcedModifier(modifier: $0, source: checked, origin: .own(checked.tree.id(of: $0.node)))
        }
        return result
    }

    /// Bind this finite constant subset from the final checked argument types; never infer or evaluate source again.
    private func styleFacets(_ item: SourcedModifier) throws -> [(FacetID, NodeID, String?, Bool)] {
        let source = item.source, modifier = item.modifier
        let compiler = sourceCompiler(source, style: true)
        guard let spec = catalog.modifier(named: modifier.name.token.text) else {
            throw compiler.issue(.invalidCheckedModel, modifier.node, "Missing checked style modifier catalog")
        }
        let arguments = modifier.arguments?.arguments ?? []
        func fits(_ argument: ArgumentSyntax, _ parameter: ParamSpec) -> Bool {
            let node = argument.value.node
            guard let actual = source.types[source.tree.id(of: node)]?.type else { return false }
            func accepts(_ expected: DeskType) -> Bool {
                if actual == expected { return true }
                if case .oneOf(let types) = expected { return types.contains(where: accepts) }
                if expected == .lengthSpec { return actual == .length || actual == .plainNumber || actual == .enumeration("LengthKeyword") }
                if expected == .length { return actual == .plainNumber && (NumberLiteralSyntax(node) != nil || ParenExprSyntax(node) != nil) }
                if expected == .fontFamily { return actual == .string && StringLiteralSyntax(compiler.styleLeaf(node))?.literalValue != nil }
                if expected == .paint { return actual == .color || actual == .string }
                if expected == .color { return actual == .string }
                if parameter.role == .display && expected == .string {
                    return [.plainNumber, .percent, .bytes, .duration, .length, .angle, .bool].contains(actual)
                }
                return false
            }
            return accepts(parameter.type)
        }
        var bindings: [(Int, ArgumentSyntax)]?
        var selected: Signature?
        for signature in spec.signatures {
            var assigned = Set<Int>(), candidate: [(Int, ArgumentSyntax)] = [], valid = true
            for argument in arguments {
                let matches = signature.params.indices.filter { index in
                    let parameter = signature.params[index]
                    return !assigned.contains(index) && parameter.label == argument.label?.name && fits(argument, parameter)
                }
                guard let index = matches.first else { valid = false; break }
                assigned.insert(index); candidate.append((index, argument))
            }
            if valid && signature.params.indices.allSatisfy({ !signature.params[$0].required || assigned.contains($0) }) {
                guard bindings == nil else {
                    throw compiler.issue(.unsupported, modifier.node, "Ambiguous constant style signature")
                }
                bindings = candidate.sorted { $0.0 < $1.0 }
                selected = signature
            }
        }
        guard let bindings, let signature = selected else {
            throw compiler.issue(.invalidCheckedModel, modifier.node, "Style arguments do not match their checked catalog parameters")
        }
        var result: [(FacetID, NodeID, String?, Bool)] = []
        var leaves: [NodeID: PositionedNode] = [:]
        for (index, argument) in bindings {
            let parameter = signature.params[index], node = argument.value.node, identity = source.tree.id(of: node)
            let leaf = try compiler.constantStyleValue(node, parameter: parameter)
            leaves[identity] = leaf
            if spec.softFacets, case .enumCase(let type, let name)? = source.symbols[source.tree.id(of: leaf)],
               let preset = catalog.enumeration(type)?.enumCase(named: name), !preset.facetValues.isEmpty {
                result += preset.facetValues.sorted { $0.key < $1.key }.map { ($0.key, identity, $0.value.value, !$0.value.soft) }
            } else {
                result += parameter.facets.map { ($0, identity, nil, true) }
            }
        }
        result += spec.fixedValues.sorted { $0.key < $1.key }.map { ($0.key, source.tree.id(of: modifier.node), $0.value, true) }
        if spec.name == "hidden", arguments.isEmpty { result.append(("hidden", source.tree.id(of: modifier.node), "true", true)) }
        var corners: [FacetID: ProgramCornerRadius] = [:]
        for (key, identity, fixedValue, _) in result {
            let node = source.tree.resolve(identity) ?? modifier.node
            if ["voiceOver", "tooltip", "tooltip.title", "hidden"].contains(key.rawValue) { continue }
            if ["color", "fill", "track", "stroke", "background.tint"].contains(key.rawValue) {
                _ = try compiler.checkedFacetColor(node); continue
            }
            if key == "background" {
                let leaf = leaves[identity] ?? node
                if case .enumCase(type: "Paint", case: let name)? = source.symbols[source.tree.id(of: leaf)],
                   ["glass", "clearGlass"].contains(name) { continue }
                _ = try compiler.checkedFacetColor(node)
                guard !arguments.contains(where: { $0.label?.name == "tint" }) else {
                    throw compiler.issue(.unsupported, node, "A background tint is implemented only for glass")
                }
                continue
            }
            let value: Value
            if let fixedValue { value = try compiler.fixed(fixedValue, at: node) }
            else if key == "font.size" || key.rawValue.hasPrefix("padding.") || key.rawValue.hasPrefix("width") ||
                    key.rawValue.hasPrefix("height") || key == "stroke.width" || key.rawValue.hasPrefix("rounded.") {
                value = try compiler.lengthConstant(node)
            } else { value = try compiler.constant(node) }
            if key.rawValue.hasPrefix("font.") || key == "align" || key == "digits" {
                var appearance = Appearance()
                try compiler.assign(value, to: key.rawValue, appearance: &appearance, at: node)
            } else if key.rawValue.hasPrefix("rounded.") {
                switch value {
                case .number(let number) where number >= 0: corners[key] = .points(number)
                case .choice("full"): corners[key] = .full
                default: throw compiler.issue(.unsupported, node, "Style corner radii require nonnegative constants or .full")
                }
            } else if key == "width" || key == "height" {
                switch value {
                case .number(let number) where number >= 0: break
                case .choice("fit"), .choice("fill"): break
                default: throw compiler.issue(.unsupported, node, "Style size requires a nonnegative constant, .fit or .fill")
                }
            } else if key.rawValue.hasPrefix("padding.") || key.rawValue.hasPrefix("width.") ||
                        key.rawValue.hasPrefix("height.") || key == "stroke.width" {
                guard case .number(let number) = value, number >= 0 else {
                    throw compiler.issue(.unsupported, node, "Style dimensions require nonnegative constants")
                }
            }
        }
        if !corners.isEmpty {
            let values = ["rounded.topLeft", "rounded.topRight", "rounded.bottomLeft", "rounded.bottomRight"].map {
                corners[FacetID($0)] ?? .points(0)
            }
            guard values.allSatisfy({ $0 == values[0] }) else {
                throw compiler.issue(.unsupported, modifier.node, "Different style corner radii are not implemented")
            }
        }
        return result
    }

    /// A candidate keeps the argument identity; only constant interpretation uses its transparent leaf.
    private func styleLeaf(_ node: PositionedNode) -> PositionedNode {
        var leaf = node
        while let paren = ParenExprSyntax(leaf) { leaf = paren.value.node }
        return leaf
    }

    private func constantStyleValue(_ node: PositionedNode, parameter: ParamSpec, depth: Int = 1) throws -> PositionedNode {
        guard depth <= min(ProgramLimits.maximumExpressionDepth, catalog.limits.maximumExpressionNesting) else {
            throw issue(.resourceLimit, node, "Shared program constant style expression depth exceeded")
        }
        let identity = checked.tree.id(of: node)
        guard checked.types[identity] != nil else { throw issue(.invalidCheckedModel, node, "Style value has no checked type") }
        if let paren = ParenExprSyntax(node) {
            let inner = checked.tree.id(of: paren.value.node)
            let leaf = try constantStyleValue(paren.value.node, parameter: parameter, depth: depth + 1)
            let adoptedLength = parameter.type == .length && checked.types[identity]?.type == .length &&
                checked.types[inner]?.type == .plainNumber && NumberLiteralSyntax(leaf)?.unit == nil &&
                NumberLiteralSyntax(leaf) != nil
            guard checked.types[identity]?.type == checked.types[inner]?.type || adoptedLength,
                  checked.symbols[identity] == nil, checked.numericCoercions[identity] == nil,
                  checked.canonicalNumericValues[identity] == checked.canonicalNumericValues[inner] else {
                throw issue(.invalidCheckedModel, node, "Style parentheses do not preserve their checked type")
            }
            return leaf
        }
        if parameter.role == .display, let prefix = PrefixExprSyntax(node),
           [.plus, .minus].contains(prefix.operator.token.kind), NumberLiteralSyntax(prefix.operand.node) != nil {
            _ = try constantStyleValue(prefix.operand.node, parameter: parameter, depth: depth + 1)
            let operand = checked.tree.id(of: prefix.operand.node)
            guard checked.types[identity]?.type == checked.types[operand]?.type,
                  let value = checked.canonicalNumericValues[operand],
                  checked.canonicalNumericValues[identity] == (prefix.operator.token.kind == .minus ? -value : value),
                  checked.numericCoercions[identity] == nil else {
                throw issue(.invalidCheckedModel, node, "Signed style display has an inconsistent numeric receipt")
            }
            return node
        }
        if let number = NumberLiteralSyntax(node) {
            guard number.unitAfterSpace == nil, let value = number.value, value.isFinite,
                  checked.numericCoercions[identity] == nil,
                  let canonical = checked.canonicalNumericValues[identity], canonical.isFinite else {
                throw issue(.unsupported, node, "Style numbers require their checked literal receipt")
            }
            if let spelling = number.unit?.text {
                guard number.unit?.status == .known, let unit = catalog.unit(spelling: spelling),
                      spelling == "pt" || parameter.role == .display,
                      [.plainNumber, .percent, .bytes, .duration, .length, .angle].contains(checked.types[identity]?.type ?? .any),
                      checked.types[identity]?.type == .number(unit.dimension),
                      unit.factor.isFinite, unit.factor > 0, unit.offset.isFinite,
                      canonical == value * unit.factor + unit.offset else {
                    throw issue(.unsupported, node, "Style units require a supported checked constant dimension")
                }
            } else {
                guard canonical == value,
                      checked.types[identity]?.type == .plainNumber || parameter.type == .length && checked.types[identity]?.type == .length else {
                    throw issue(.invalidCheckedModel, node, "Style literal has an inconsistent canonical value or adopted type")
                }
            }
            return node
        }
        guard checked.canonicalNumericValues[identity] == nil, checked.numericCoercions[identity] == nil else {
            throw issue(.invalidCheckedModel, node, "Nonnumeric style values cannot have numeric receipts")
        }
        if let literal = StringLiteralSyntax(node)?.literalValue {
            guard checked.types[identity]?.type == .string,
                  literal.utf16.count <= min(ProgramLimits.maximumTextLength, catalog.limits.maximumTextLength) else {
                throw issue(.resourceLimit, node, "Shared program style text limit exceeded")
            }
            return node
        }
        if BoolLiteralSyntax(node) != nil {
            guard checked.types[identity]?.type == .bool else { throw issue(.invalidCheckedModel, node, "Style Boolean has an invalid checked type") }
            return node
        }
        let implicit = ImplicitMemberExprSyntax(node)
        let member = MemberExprSyntax(node)
        if implicit?.arguments == nil, let name = implicit?.name.token.text ?? member?.name.token.text,
           case .enumCase(let type, let symbol)? = checked.symbols[identity], symbol == name,
           checked.types[identity]?.type == (type == "Color" ? .color : type == "Paint" ? .paint : .enumeration(type)),
           catalog.enumeration(type)?.enumCase(named: name) != nil || catalog.index.namedValues["\(type).\(name)"]?.type == type {
            if let member, IdentifierExprSyntax(member.base.node)?.name != type {
                throw issue(.invalidCheckedModel, node, "Style enum value has an inconsistent qualified type")
            }
            return node
        }
        throw issue(.unsupported, node, "Dynamic style values are not implemented")
    }

    private func sizePolicy(_ choice: String, at node: PositionedNode) throws -> ProgramWidgetSize {
        guard catalog.enumeration("SizePreset")?.enumCase(named: choice) != nil else {
            throw issue(.unsupported, node, "Unsupported SizePreset catalog case")
        }
        if choice == "fit" { return .fit }
        guard let preset = ProgramSizePreset(rawValue: choice) else {
            throw issue(.unsupported, node, "Unsupported widget size preset")
        }
        let size: IdealSize
        switch preset {
        case .small: size = catalog.limits.smallSize
        case .medium: size = catalog.limits.mediumSize
        case .large: size = catalog.limits.largeSize
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw issue(.unsupported, node, "Preset sizes require positive finite catalog dimensions")
        }
        return .preset(preset, size: SkinSize(width: size.width, height: size.height))
    }

    private mutating func reserveIndex(at node: PositionedNode, depth: Int) throws -> Int {
        guard depth <= min(ProgramLimits.maximumDepth, catalog.limits.maximumBlockNesting) else {
            throw issue(.resourceLimit, node, "Shared program nesting limit exceeded")
        }
        guard nextIndex < min(ProgramLimits.maximumElements, catalog.limits.maximumElementInstances) - optionNodeCount else {
            throw issue(.resourceLimit, node, "Shared program element limit exceeded")
        }
        let value = nextIndex
        nextIndex += 1
        return value
    }

    /// View control flow is a transparent structural item; its selected children keep their actual container.
    private mutating func viewStatement(_ node: PositionedNode, inherited: Appearance, depth: Int) throws -> ProgramElement {
        if node.kind == .callStmt { return try element(node, inherited: inherited, depth: depth) }
        guard node.kind == .ifStmt else {
            throw issue(.unsupported, node, "Only supported elements and view-level if statements are implemented")
        }
        let index = try reserveIndex(at: node, depth: depth)
        var branches: [ProgramConditionalBranch] = []
        var otherwise: [ProgramElement] = []
        var current: PositionedNode? = node
        while let statement = current {
            guard let syntax = IfStmtSyntax(statement), syntax.modifiers.isEmpty,
                  checked.elements[checked.tree.id(of: statement)] == nil else {
                throw issue(.invalidCheckedModel, statement, "A view if has no element facets or attached modifiers")
            }
            // Validate every branch, including an always-false or unreachable alternative.
            let condition = try expressions.condition(syntax.condition.node)
            let children = try syntax.block.items.map { try viewStatement($0, inherited: inherited, depth: depth + 1) }
            branches.append(ProgramConditionalBranch(condition: condition, body: children))
            current = nil
            if let clause = syntax.elseClause {
                switch clause.body.kind {
                case .ifStmt: current = clause.body
                case .block:
                    guard let block = BlockSyntax(clause.body) else {
                        throw issue(.invalidCheckedModel, clause.body, "Missing checked else block")
                    }
                    otherwise = try block.items.map { try viewStatement($0, inherited: inherited, depth: depth + 1) }
                default: throw issue(.invalidCheckedModel, clause.body, "Expected an else block or else if")
                }
            }
        }
        return ProgramElement(id: ElementID(name: "if#\(index)", index: index),
                              content: .conditional(ProgramConditional(branches: branches, otherwise: otherwise)))
    }

    private mutating func element(_ node: PositionedNode, inherited: Appearance, depth: Int) throws -> ProgramElement {
        guard let call = CallStmtSyntax(node), call.callee.path.count == 1,
              let facts = checked.elements[checked.tree.id(of: node)], facts.component == call.callee.path[0],
              let spec = catalog.component(named: facts.component), spec.kind == facts.kind else {
            throw issue(.unsupported, node, "Expected a checked, built-in element")
        }
        guard ["Text", "Icon", "Column", "Row", "Freeform", "Rectangle", "Circle", "Ellipse", "Capsule", "Image", "Progress", "Gauge", "Spacer"].contains(facts.component) else {
            throw issue(.unsupported, node, "Unsupported component: \(facts.component)")
        }
        guard facts.dropped.isEmpty else { throw issue(.invalidCheckedModel, node, "Dropped element semantics cannot be compiled") }
        guard seenElements.insert(checked.tree.id(of: node)).inserted else {
            throw issue(.invalidCheckedModel, node, "An element cannot be compiled twice")
        }
        let solidShape = ["Rectangle", "Circle", "Ellipse", "Capsule"].contains(facts.component)
        let image = facts.component == "Image"
        let icon = facts.component == "Icon"
        let progress = facts.component == "Progress"
        let gauge = facts.component == "Gauge"
        let rangedMeter = progress || gauge
        let spacer = facts.component == "Spacer"
        let clickableContainer = ["Row", "Column", "Freeform"].contains(facts.component)
        let ignoresRootSize = depth == 1 && widgetSize != .fit
        let sizeFacets: Set<String> = ["width", "height", "width.min", "width.max", "height.min", "height.max"]
        var allowedModifiers: Set<String> = spacer ? ["hidden"] : rangedMeter ? ["width", "height", "size", "padding", "color", "track", "name", "hidden"] : image ? ["width", "height", "size", "padding", "imageMode", "name", "hidden"] : solidShape
            ? Set(["width", "height", "size", "padding", "fill", "stroke", "name", "hidden"]).union(facts.component == "Rectangle" ? ["rounded"] : [])
            : ["width", "height", "size", "padding", "font", "bold", "italic", "color", "align", "name", "hidden", "digits"]
        allowedModifiers.formUnion(["background", "rounded", "voiceOver"])
        if icon {
            allowedModifiers.insert("iconColors")
            allowedModifiers.remove("digits")
        }
        if !spacer { allowedModifiers.formUnion(["position", "tooltip", "menu"]) }
        let expanded = try expandModifiers(call, kind: facts.kind, allowed: allowedModifiers)
        expandedModifiers[checked.tree.id(of: call.node)] = expanded
        var onClick: [ProgramAssignment]?
        var onClickActions: [ProgramAction]?
        var onRightClickActions: [ProgramAction]?
        for item in expanded {
            let modifier = item.modifier
            let source = item.source
            let compiler = sourceCompiler(source)
            let modifierName = modifier.name.token.text
            if ["background", "rounded"].contains(modifierName) {
                try compiler.boxModifierContract(modifier, kind: facts.kind)
            }
            if rangedMeter && ["color", "track"].contains(modifierName) {
                guard source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier(modifierName)),
                      let paint = catalog.modifier(named: modifierName), paint.appliesTo.contains(facts.kind),
                      paint.facets == [FacetID(modifierName)],
                      paint.signatures.contains(where: { signature in
                          signature.params.count == 1 && signature.params[0].label == nil &&
                          signature.params[0].type == .color && signature.params[0].facets == [FacetID(modifierName)]
                      }) else {
                    throw issue(.unsupported, modifier.node, "Unsupported checked \(facts.component) paint contract")
                }
            }
            if modifier.name.token.text == "font" {
                guard source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier("font")),
                      let font = catalog.modifier(named: "font"), font.inheritable, font.appliesTo.contains(facts.kind),
                      font.facets.contains(FacetID("font.size")),
                      font.signatures.compactMap({ $0.param(named: "size") }).count == 2,
                      font.signatures.compactMap({ $0.param(named: "size") }).allSatisfy({ $0.type == .length && $0.facets == [FacetID("font.size")] }) else {
                    throw issue(.unsupported, modifier.node, "Unsupported checked font-size catalog contract")
                }
            }
            if modifier.name.token.text == "digits" {
                guard source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier("digits")),
                      let digits = catalog.modifier(named: "digits"), digits.inheritable, digits.appliesTo.contains(facts.kind),
                      digits.facets == [FacetID("digits")], digits.signatures.count == 1,
                      digits.signatures[0].params.count == 1,
                      digits.signatures[0].params[0].type == .enumeration("Digits"),
                      digits.signatures[0].params[0].facets == [FacetID("digits")] else {
                    throw issue(.unsupported, modifier.node, "Unsupported checked digits catalog contract")
                }
            }
            if modifier.name.token.text == "onLoad" {
                try rootOnLoad(modifier, element: node)
                continue
            }
            if ["onClick", "onRightClick"].contains(modifier.name.token.text) {
                let primary = modifier.name.token.text == "onClick"
                guard (primary ? onClick == nil && onClickActions == nil : onRightClickActions == nil),
                      facts.component == "Text" || icon || solidShape || rangedMeter || clickableContainer else {
                    throw issue(.unsupported, modifier.node, "Only Text, Icon, Progress, Gauge, basic shapes and Row/Column/Freeform primary/secondary click actions are implemented")
                }
                let actions = try clickActions(modifier, kind: facts.kind)
                if !primary {
                    onRightClickActions = actions
                    continue
                }
                let assignments = actions.compactMap { action -> ProgramAssignment? in
                    if case .assign(let assignment) = action { return assignment }
                    return nil
                }
                // Preserve the existing producer contract for assignment-only and empty handlers.
                if assignments.count == actions.count { onClick = assignments }
                else { onClickActions = actions }
                continue
            }
            if modifierName == "menu" {
                guard !spacer else { throw issue(.unsupported, modifier.node, "Spacer menus are not supported") }
                continue // The menu's complete checked contract and body are validated below.
            }
            guard allowedModifiers.contains(modifier.name.token.text), modifier.block == nil else {
                throw issue(.unsupported, modifier.node, "Unsupported modifier: \(modifier.name.token.text)")
            }
            if modifier.name.token.text == "color",
               (modifier.arguments?.arguments ?? []).contains(where: { ["light", "dark"].contains($0.label?.name ?? "") }) {
                throw issue(.unsupported, modifier.node, "Separate light/dark colors are not implemented")
            }
        }
        var allowedFacets: Set<String> = spacer ? ["hidden"] : rangedMeter
            ? ["width", "height", "width.min", "width.max", "height.min", "height.max", "padding.left", "padding.right", "padding.top", "padding.bottom", "color", "track", "hidden", "name"]
            : image ? ["width", "height", "width.min", "width.max", "height.min", "height.max", "padding.left", "padding.right", "padding.top", "padding.bottom", "imageMode", "hidden", "name"] : solidShape
            ? Set(["width", "height", "width.min", "width.max", "height.min", "height.max", "padding.left", "padding.right", "padding.top", "padding.bottom", "fill", "stroke", "stroke.width", "hidden", "name"]).union(facts.component == "Rectangle" ? ["rounded.topLeft", "rounded.topRight", "rounded.bottomLeft", "rounded.bottomRight"] : [])
            : ["width", "height", "width.min", "width.max", "height.min", "height.max", "padding.left", "padding.right", "padding.top", "padding.bottom",
               "font.family", "font.size", "font.weight", "font.design", "font.italic", "digits", "color", "align", "hidden", "name"]
        if !spacer { allowedFacets.formUnion(["position.x", "position.y", "position.anchor", "tooltip", "tooltip.title"]) }
        if icon { allowedFacets.insert("iconColors") }
        allowedFacets.formUnion(["voiceOver", "background", "background.tint", "rounded.topLeft", "rounded.topRight",
                                 "rounded.bottomLeft", "rounded.bottomRight"])
        for (facet, candidates) in facts.facets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard allowedFacets.contains(facet.rawValue) else {
                throw issue(.unsupported, node, "Unsupported effective facet: \(facet.rawValue)")
            }
            guard ignoresRootSize && sizeFacets.contains(facet.rawValue) ||
                    ["hidden", "color", "fill", "track"].contains(facet.rawValue) ||
                    candidates.allSatisfy({ $0.condition == nil }) else {
                throw issue(.unsupported, node, "Conditional facet is not implemented: \(facet.rawValue)")
            }
        }
        try candidatePositions(facts, call: call)
        let index = try reserveIndex(at: node, depth: depth)
        // Text, icons and containers inherit text styles. Ranged meters own their fill and track colors.
        let appearance = solidShape || image || rangedMeter || spacer ? inherited : try resolvedAppearance(facts, inherited: inherited, call: call)
        // The checked preset owns the root proposal; retain DK5018 but do not evaluate ignored size facets.
        let width: ProgramLength = ignoresRootSize ? .fit : try length(facts, "width", default: spec.sizing.width, at: node)
        let height: ProgramLength = ignoresRootSize ? .fit : try length(facts, "height", default: spec.sizing.height, at: node)
        let minWidth = ignoresRootSize ? 0 : try number(facts, "width.min", default: 0, at: node)
        let minHeight = ignoresRootSize ? 0 : try number(facts, "height.min", default: 0, at: node)
        let maxWidth = ignoresRootSize ? nil : try optionalNumber(facts, "width.max", at: node)
        let maxHeight = ignoresRootSize ? nil : try optionalNumber(facts, "height.max", at: node)
        let padding = try SkinInsets(left: number(facts, "padding.left", default: 0, at: node),
                                     top: number(facts, "padding.top", default: 0, at: node),
                                     right: number(facts, "padding.right", default: 0, at: node),
                                     bottom: number(facts, "padding.bottom", default: 0, at: node))
        let position = try position(facts, call: call)
        let visibility = try hidden(facts, call: call)
        let background = try background(facts, call: call)
        let radius = try uniformRadius(facts, call: call)
        let label = try voiceOver(facts, call: call)
        let tip = try tooltip(facts, call: call)
        let menuItems = try menu(facts, call: call, depth: depth)
        if image, let radius, radius != .points(0) {
            throw issue(.unsupported, node, "Nonzero Image rounding requires picture clipping, which is not implemented")
        }
        let content: ProgramElement.Content
        var stroke: ProgramShapeStroke?
        switch facts.component {
        case "Spacer":
            let arguments = call.arguments?.arguments ?? []
            guard spec.kind == .spacer, spec.signatures.count == 1, spec.signatures[0].params.count == 1,
                  let minimum = spec.signatures[0].param(named: "min"), minimum.label == "min", minimum.type == .length,
                  call.block == nil, arguments.count <= 1, arguments.allSatisfy({ $0.label?.name == "min" }) else {
                throw issue(.unsupported, node, "Unsupported checked Spacer contract")
            }
            let value: Double
            if let argument = arguments.first {
                guard checked.types[checked.tree.id(of: argument.value.node)]?.type == .length,
                      case .number(let n) = try lengthConstant(argument.value.node), n >= 0 else {
                    throw issue(.unsupported, argument.value.node, "Spacer minimum requires a nonnegative constant Length")
                }
                value = n
            } else { value = try defaultNumber(component: "Spacer", parameter: "min", at: node) }
            content = .spacer(minimum: value)
        case "Progress":
            let arguments = call.arguments?.arguments ?? []
            guard spec.kind == .progress, spec.signatures.count == 1, spec.signatures[0].params.count == 3,
                  let valueParameter = spec.signatures[0].param(named: "value"), valueParameter.label == nil,
                  valueParameter.type == .anyNumber, valueParameter.required,
                  let totalParameter = spec.signatures[0].param(named: "total"), totalParameter.label == "total",
                  totalParameter.type == .anyNumber, totalParameter.sameAs == "value", totalParameter.defaultValue == nil,
                  let fillsParameter = spec.signatures[0].param(named: "fills"), fillsParameter.label == "fills",
                  fillsParameter.type == .enumeration("Direction"), call.block == nil,
                  arguments.filter({ $0.label == nil }).count == 1,
                  arguments.filter({ $0.label?.name == "total" }).count <= 1,
                  arguments.filter({ $0.label?.name == "fills" }).count <= 1,
                  arguments.allSatisfy({ $0.label == nil || ["total", "fills"].contains($0.label?.name ?? "") }),
                  let value = arguments.first(where: { $0.label == nil })?.value.node else {
                throw issue(.unsupported, node, "Unsupported checked Progress contract")
            }
            let operands = try expressions.rangedValue(value: value, total: arguments.first { $0.label?.name == "total" }?.value.node,
                                                      component: "Progress")
            let direction: String
            if let fills = arguments.first(where: { $0.label?.name == "fills" })?.value.node {
                guard case .choice(let choice) = try constant(fills),
                      checked.types[checked.tree.id(of: fills)]?.type == .enumeration("Direction"),
                      checked.symbols[checked.tree.id(of: fills)] == .enumCase(type: "Direction", case: choice) else {
                    throw issue(.unsupported, fills, "Progress fills requires a checked Direction case")
                }
                direction = choice
            } else { direction = try defaultChoice(component: "Progress", parameter: "fills", at: node) }
            guard catalog.enumeration("Direction")?.enumCase(named: direction) != nil,
                  let fills = ProgramDirection(rawValue: direction) else {
                throw issue(.unsupported, node, "Unsupported Progress direction")
            }
            content = .progress(ProgramProgress(value: operands.value, total: operands.total, fills: fills,
                                                color: try meterColor(facts, "color", spec: spec, call: call),
                                                track: try meterColor(facts, "track", spec: spec, call: call)))
        case "Gauge":
            let arguments = call.arguments?.arguments ?? []
            guard spec.kind == .gauge, spec.signatures.count == 1, spec.signatures[0].params.count == 6,
                  spec.signatures[0].params.allSatisfy({ !$0.variadic }),
                  let valueParameter = spec.signatures[0].param(named: "value"), valueParameter.label == nil,
                  valueParameter.type == .anyNumber, valueParameter.required, valueParameter.defaultValue == nil,
                  let totalParameter = spec.signatures[0].param(named: "total"), totalParameter.label == "total",
                  totalParameter.type == .anyNumber, !totalParameter.required,
                  totalParameter.sameAs == "value", totalParameter.defaultValue == nil,
                  let shapeParameter = spec.signatures[0].param(named: "shape"), shapeParameter.label == "shape",
                  shapeParameter.type == .enumeration("GaugeShape"), !shapeParameter.required, shapeParameter.sameAs == nil,
                  let startParameter = spec.signatures[0].param(named: "start"), startParameter.label == "start",
                  startParameter.type == .angle, !startParameter.required, startParameter.sameAs == nil, startParameter.defaultValue == nil,
                  let sweepParameter = spec.signatures[0].param(named: "sweep"), sweepParameter.label == "sweep",
                  sweepParameter.type == .angle, !sweepParameter.required, sweepParameter.sameAs == nil, sweepParameter.defaultValue == nil,
                  let thicknessParameter = spec.signatures[0].param(named: "thickness"), thicknessParameter.label == "thickness",
                  thicknessParameter.type == .length, !thicknessParameter.required, thicknessParameter.sameAs == nil, call.block == nil,
                  arguments.filter({ $0.label == nil }).count == 1,
                  ["total", "shape", "start", "sweep", "thickness"].allSatisfy({ label in
                      arguments.filter { $0.label?.name == label }.count <= 1
                  }),
                  arguments.allSatisfy({ $0.label == nil || ["total", "shape", "start", "sweep", "thickness"].contains($0.label?.name ?? "") }),
                  let value = arguments.first(where: { $0.label == nil })?.value.node else {
                throw issue(.unsupported, node, "Unsupported checked Gauge contract")
            }
            let operands = try expressions.rangedValue(value: value,
                total: arguments.first { $0.label?.name == "total" }?.value.node, component: "Gauge")
            let choice: String
            if let shape = arguments.first(where: { $0.label?.name == "shape" })?.value.node {
                guard case .choice(let name) = try constant(shape),
                      checked.types[checked.tree.id(of: shape)]?.type == .enumeration("GaugeShape"),
                      checked.symbols[checked.tree.id(of: shape)] == .enumCase(type: "GaugeShape", case: name) else {
                    throw issue(.unsupported, shape, "Gauge shape requires a checked constant GaugeShape case")
                }
                choice = name
            } else { choice = try defaultChoice(component: "Gauge", parameter: "shape", at: node) }
            guard catalog.enumeration("GaugeShape")?.enumCase(named: choice) != nil,
                  let shape = ProgramGaugeShape(rawValue: choice) else {
                throw issue(.unsupported, node, "Unsupported Gauge shape")
            }
            let start = try arguments.first { $0.label?.name == "start" }.map { try expressions.gaugeAngle($0.value.node) }
            let sweep = try arguments.first { $0.label?.name == "sweep" }.map { try expressions.gaugeAngle($0.value.node) }
            let defaultThickness = try defaultNumber(component: "Gauge", parameter: "thickness", at: node)
            let thickness: ProgramExpression?
            if let argument = arguments.first(where: { $0.label?.name == "thickness" }) {
                thickness = try expressions.gaugeThickness(argument.value.node)
            } else {
                // The standard default stays absent; a supported custom catalog still owns its written value.
                thickness = defaultThickness == 6 ? nil : .quantity(ProgramNumber(defaultThickness, dimension: .length))
            }
            content = .gauge(ProgramGauge(value: operands.value, total: operands.total, shape: shape,
                                         start: start, sweep: sweep, thickness: thickness,
                                         color: try meterColor(facts, "color", spec: spec, call: call),
                                         track: try meterColor(facts, "track", spec: spec, call: call)))
        case "Rectangle", "Circle", "Ellipse", "Capsule":
            guard call.block == nil, (call.arguments?.arguments ?? []).isEmpty else {
                throw issue(.unsupported, node, "\(facts.component) takes no arguments or block")
            }
            if let paint = try facet(facts, "stroke", at: node) {
                let width: Double
                if let explicit = try optionalNumber(facts, "stroke.width", at: node) { width = explicit }
                else {
                    guard case .source(let source)? = catalog.modifier(named: "stroke")?.signatures.first?.param(named: "width")?.defaultValue,
                          case .number(let n) = try fixed(source, at: node), n >= 0 else {
                        throw issue(.invalidCheckedModel, node, "The checking catalog has no static stroke.width default")
                    }
                    width = n
                }
                stroke = ProgramShapeStroke(color: try color(paint, at: node), width: width)
            }
            let defaultFill: ProgramColor
            // D115: the explicit outline suppresses the implicit fill, including transparent/zero strokes.
            if (facts.facets["fill"] ?? []).contains(where: { $0.condition == nil }) || stroke != nil {
                defaultFill = .literal(.clear) // An own base does not consume the catalog's unused fallback.
            }
            else {
                guard let source = spec.defaults[FacetID("fill")] else {
                    throw issue(.invalidCheckedModel, node, "The checking catalog has no \(facts.component) fill default")
                }
                defaultFill = try color(fixed(source, at: node), at: node)
            }
            let fill = try conditionalColor(facts, "fill", fallback: defaultFill, call: call)
            switch facts.component {
            case "Circle": content = .shape(kind: .circle, fill: fill)
            case "Ellipse": content = .shape(kind: .ellipse, fill: fill)
            case "Capsule": content = .shape(kind: .capsule, fill: fill)
            default: content = .rectangle(fill: fill)
            }
        case "Image":
            guard call.block == nil, let arguments = call.arguments?.arguments, arguments.count == 1,
                  case .string(let source) = try constant(arguments[0].value.node), !source.isEmpty,
                  !source.hasPrefix("/"), !source.hasPrefix("~"), !source.contains("://"),
                  !source.contains("\\"), !source.split(separator: "/").contains("..") else {
                throw issue(.unsupported, node, "Image requires a literal file inside the widget folder")
            }
            let value: Value
            if let own = try facet(facts, "imageMode", at: node) { value = own }
            else {
                guard case .source(let source)? = catalog.modifier(named: "imageMode")?.signatures.first?.param(named: "mode")?.defaultValue else {
                    throw issue(.invalidCheckedModel, node, "The checking catalog has no imageMode default")
                }
                value = try fixed(source, at: node)
            }
            let mode: ProgramImageMode
            switch value {
            case .choice("fit"): mode = .fit
            case .choice("fill"): mode = .fill
            case .choice("stretch"): mode = .stretch
            case .choice("tile"): mode = .tile
            default: throw issue(.unsupported, node, "Unsupported imageMode")
            }
            content = .image(ProgramImage(source: source, mode: mode))
        case "Icon":
            let arguments = call.arguments?.arguments ?? []
            guard spec.kind == .icon, spec.block == .none, spec.signatures.count == 1,
                  spec.signatures[0].params.count == 1, let parameter = spec.signatures[0].params.first,
                  parameter.name == "name", parameter.label == nil, parameter.type == .symbolName,
                  parameter.role == .plain, parameter.source == .any, !parameter.translatable,
                  parameter.required, !parameter.variadic, parameter.defaultValue == nil,
                  parameter.sameAs == nil, parameter.facets.isEmpty, parameter.range == nil, parameter.unit == nil,
                  call.block == nil, arguments.count == 1, let argument = arguments.first, argument.label == nil else {
                throw issue(.unsupported, node, "Unsupported checked Icon SymbolName parameter contract")
            }
            content = .icon(ProgramIcon(name: try expressions.symbolName(argument.value.node),
                fontFamily: try fontFamily(appearance, at: node), fontSize: appearance.size,
                fontWeight: appearance.weight, italic: appearance.italic, color: appearance.color, align: appearance.align,
                colors: try iconColors(facts, call: call),
                fontSizeExpression: appearance.sizeExpression,
                hasOwnFont: !sourceModifiers(call, named: "font").isEmpty))
        case "Text":
            guard spec.signatures.count == 1, spec.signatures[0].params.count == 1,
                  let parameter = spec.signatures[0].params.first,
                  parameter.name == "content", parameter.label == nil, parameter.type == .any,
                  parameter.role == .display, parameter.source == .any, parameter.translatable,
                  parameter.required, !parameter.variadic, parameter.defaultValue == nil,
                  call.block == nil, let arguments = call.arguments?.arguments, arguments.count == 1, arguments[0].label == nil else {
                throw issue(.unsupported, node, "Text requires one String expression")
            }
            let text = try expressions.text(arguments[0].value.node)
            content = .text(ProgramText(value: text, fontFamily: try fontFamily(appearance, at: node), fontSize: appearance.size,
                                        fontWeight: appearance.weight, italic: appearance.italic,
                                        color: appearance.color, align: appearance.align, digits: appearance.digits,
                                        fontSizeExpression: appearance.sizeExpression))
        case "Freeform":
            let arguments = call.arguments?.arguments ?? []
            guard arguments.allSatisfy({ $0.label?.name == "align" }) else {
                throw issue(.unsupported, node, "Unsupported Freeform argument")
            }
            let align: String
            if let value = arguments.first?.value.node {
                guard case .choice(let choice) = try constant(value) else {
                    throw issue(.unsupported, value, "Freeform alignment must be constant")
                }
                align = choice
            } else { align = try defaultChoice(component: "Freeform", parameter: "align", at: node) }
            let children = try (call.block?.items ?? []).map { try viewStatement($0, inherited: appearance, depth: depth + 1) }
            content = .freeform(align: try alignment(align, at: node), children: children)
        default:
            let arguments = call.arguments?.arguments ?? []
            guard arguments.allSatisfy({ ["spacing", "align"].contains($0.label?.name ?? "") }) else {
                throw issue(.unsupported, node, "Unsupported stack argument")
            }
            let spacingNode = arguments.first { $0.label?.name == "spacing" }?.value.node
            let spacing: Double
            if let value = spacingNode {
                guard case .number(let n) = try lengthConstant(value), n >= 0 else { throw issue(.unsupported, value, "Static spacing must be nonnegative") }
                spacing = n
            } else { spacing = try defaultNumber(component: facts.component, parameter: "spacing", at: node) }
            let alignNode = arguments.first { $0.label?.name == "align" }?.value.node
            let align: String
            if let value = alignNode {
                guard case .choice(let n) = try constant(value) else { throw issue(.unsupported, value, "Stack alignment must be constant") }
                align = n
            } else { align = try defaultChoice(component: facts.component, parameter: "align", at: node) }
            let children = try (call.block?.items ?? []).map { try viewStatement($0, inherited: appearance, depth: depth + 1) }
            if facts.component == "Column" {
                content = .column(spacing: spacing, align: try horizontal(align, at: node), children: children)
            } else {
                let vertical: VerticalTextAlign
                switch align {
                case "top": vertical = .top
                case "center": vertical = .center
                case "bottom": vertical = .bottom
                default: throw issue(.unsupported, node, "Baseline stack alignment is not implemented")
                }
                content = .row(spacing: spacing, align: vertical, children: children)
            }
        }
        let id = ElementID(name: facts.name ?? "\(facts.component)#\(index)", index: index)
        elementRefs[id] = checked.tree.id(of: node)
        return ProgramElement(id: id,
                              content: content, width: width, height: height, padding: padding, hidden: visibility.hidden,
                              minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight,
                              idealSize: solidShape || rangedMeter ? spec.sizing.idealWhenUnspecified.map { SkinSize(width: $0.width, height: $0.height) } : nil,
                              stroke: stroke, cornerRadius: radius, onClick: onClick, onClickActions: onClickActions,
                              onRightClickActions: onRightClickActions, position: position, background: background,
                              voiceOver: label, hiddenIf: visibility.condition, tooltip: tip, menu: menuItems)
    }

    private func iconColors(_ facts: ElementFacts, call: CallStmtSyntax) throws -> IconColors {
        guard let spec = catalog.modifier(named: "iconColors"), spec.appliesTo.contains(.icon),
              !spec.inheritable, spec.facets == [FacetID("iconColors")], spec.fixedValues.isEmpty,
              spec.context == .view, spec.boxLayer == .none, !spec.softFacets, spec.event == nil, spec.timing == nil,
              spec.block == .none, spec.signatures.count == 1, spec.signatures[0].params.count == 1,
              let parameter = spec.signatures[0].params.first, parameter.label == nil, parameter.name == "mode",
              parameter.type == .enumeration("IconColors"), parameter.facets == [FacetID("iconColors")],
              parameter.role == .plain, parameter.source == .any, parameter.defaultValue == nil,
              parameter.required, !parameter.variadic, !parameter.translatable,
              parameter.sameAs == nil, parameter.range == nil, !parameter.wholeNumber, parameter.unit == nil,
              let facet = catalog.facet("iconColors"), facet.valueType == .enumeration("IconColors"), !facet.inheritable else {
            throw issue(.unsupported, call.node, "Unsupported checked IconColors catalog contract")
        }
        let modifiers = sourceModifiers(call, named: "iconColors")
        let candidates = facts.facets["iconColors"] ?? []
        let choice: String
        if modifiers.isEmpty && candidates.isEmpty {
            guard let source = catalog.component(named: "Icon")?.defaults["iconColors"],
                  case .choice(let value) = try fixed(source, at: call.node) else {
                throw issue(.invalidCheckedModel, call.node, "The checking catalog has no Icon color mode default")
            }
            choice = value
        } else {
            guard !candidates.isEmpty, candidates.count == modifiers.count else {
                throw issue(.invalidCheckedModel, call.node, "Icon colors have no matching checked expanded modifier")
            }
            var choices: [String] = []
            for candidate in candidates {
                let item = try modifier(candidate, call: call), source = item.source
                guard item.modifier.name.token.text == "iconColors",
                      source.symbols[source.tree.id(of: item.modifier.node)] == .builtIn(.modifier("iconColors")),
                      candidate.fixedValue == nil, candidate.condition == nil, candidate.hard,
                      candidate.level == (item.isStyle ? 2 : 3),
                      let arguments = item.modifier.arguments?.arguments, arguments.count == 1,
                      let argument = arguments.first, argument.label == nil,
                      candidate.value == source.tree.id(of: argument.value.node),
                      source.types[candidate.value]?.type == .enumeration("IconColors"),
                      let value = source.tree.resolve(candidate.value) else {
                    throw issue(.invalidCheckedModel, call.node, "Icon colors require a checked literal IconColors argument")
                }
                let compiler = sourceCompiler(source, style: item.isStyle)
                let literal = item.isStyle ? compiler.styleLeaf(value) : value
                let name: String
                if let implicit = ImplicitMemberExprSyntax(literal), implicit.arguments == nil { name = implicit.name.token.text }
                else if let member = MemberExprSyntax(literal), IdentifierExprSyntax(member.base.node)?.name == "IconColors" { name = member.name.token.text }
                else { throw issue(.unsupported, literal, "Icon colors require a literal IconColors case") }
                guard
                      source.symbols[source.tree.id(of: literal)] == .enumCase(type: "IconColors", case: name) else {
                    throw issue(.invalidCheckedModel, call.node, "Icon colors require a checked literal IconColors argument")
                }
                choices.append(name)
            }
            choice = choices[0]
        }
        guard !facts.inherits.contains("iconColors"),
              catalog.enumeration("IconColors")?.enumCase(named: choice) != nil,
              let colors = IconColors(rawValue: choice) else {
            throw issue(.unsupported, call.node, "Unsupported IconColors case or inheritance")
        }
        return colors
    }

    private mutating func displayFacet(_ facts: ElementFacts, _ key: FacetID, modifier name: String,
                                      label: String?, call: CallStmtSyntax) throws -> ProgramExpression? {
        let items = sourceModifiers(call, named: name)
        let candidates = facts.facets[key] ?? []
        let arguments = items.compactMap { item in
            item.modifier.arguments?.arguments.first { $0.label?.name == label }
        }
        guard candidates.count == arguments.count else {
            throw issue(.invalidCheckedModel, call.node, "Display facet does not match its expanded modifier arguments")
        }
        var selected: ProgramExpression?
        for candidate in candidates {
            let item = try modifier(candidate, call: call), source = item.source
            guard item.modifier.name.token.text == name, candidate.condition == nil, candidate.fixedValue == nil,
                  candidate.level == (item.isStyle ? 2 : 3), candidate.hard,
                  let argument = item.modifier.arguments?.arguments.first(where: { $0.label?.name == label }),
                  candidate.value == source.tree.id(of: argument.value.node),
                  let value = source.tree.resolve(candidate.value), source.types[candidate.value] != nil else {
                throw issue(.invalidCheckedModel, call.node, "Display facet has no matching checked definition argument")
            }
            let expression = try expressions.text(value, source: source)
            if selected == nil { selected = expression }
        }
        return selected
    }

    private mutating func voiceOver(_ facts: ElementFacts, call: CallStmtSyntax) throws -> ProgramExpression? {
        let modifiers = sourceModifiers(call, named: "voiceOver")
        let candidates = facts.facets["voiceOver"] ?? []
        guard !facts.inherits.contains("voiceOver") else {
            throw issue(.invalidCheckedModel, call.node, "VoiceOver labels cannot inherit")
        }
        if modifiers.isEmpty && candidates.isEmpty { return nil }
        for item in modifiers {
            let modifier = item.modifier, source = item.source
            guard source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier("voiceOver")),
                  let spec = catalog.modifier(named: "voiceOver"), spec.appliesTo.contains(facts.kind),
                  spec.context == .view, spec.boxLayer == .none, !spec.inheritable, !spec.softFacets,
                  spec.facets == [FacetID("voiceOver")], spec.fixedValues.isEmpty,
                  let facet = catalog.facet("voiceOver"), facet.valueType == .string, !facet.inheritable,
                  spec.event == nil, spec.timing == nil, spec.block == .none,
                  spec.signatures.count == 1, spec.signatures[0].params.count == 1,
                  let parameter = spec.signatures[0].params.first, parameter.label == nil, parameter.name == "text",
                  parameter.type == .string, parameter.role == .display, parameter.source == .any,
                  parameter.translatable, parameter.required, !parameter.variadic, parameter.defaultValue == nil,
                  parameter.sameAs == nil, parameter.range == nil, !parameter.wholeNumber, parameter.unit == nil,
                  parameter.facets == [FacetID("voiceOver")],
                  modifier.block == nil, let arguments = modifier.arguments?.arguments,
                  arguments.count == 1, let argument = arguments.first, argument.label == nil else {
                throw issue(.unsupported, call.node, "Unsupported checked VoiceOver display modifier contract")
            }
        }
        return try displayFacet(facts, "voiceOver", modifier: "voiceOver", label: nil, call: call)
    }

    private mutating func tooltip(_ facts: ElementFacts, call: CallStmtSyntax) throws -> ProgramTooltip? {
        let modifiers = sourceModifiers(call, named: "tooltip")
        let keys: [FacetID] = ["tooltip", "tooltip.title"]
        guard keys.allSatisfy({ !facts.inherits.contains($0) }) else {
            throw issue(.invalidCheckedModel, call.node, "Tooltips cannot inherit")
        }
        if modifiers.isEmpty && keys.allSatisfy({ (facts.facets[$0] ?? []).isEmpty }) { return nil }
        for item in modifiers {
            let modifier = item.modifier, source = item.source
            guard source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier("tooltip")),
                  let spec = catalog.modifier(named: "tooltip"), spec.appliesTo.contains(facts.kind),
                  spec.context == .view, spec.boxLayer == .none, !spec.inheritable, !spec.softFacets,
                  spec.facets == keys, spec.fixedValues.isEmpty, spec.repeatable == .no,
                  spec.acceptsCondition, spec.allowedInStyle, spec.allowedInState,
                  spec.event == nil, spec.timing == nil, spec.block == .none,
                  spec.signatures.count == 1, spec.signatures[0].params.count == 2,
                  modifier.block == nil, let arguments = modifier.arguments?.arguments,
                  (1...2).contains(arguments.count), arguments.filter({ $0.label == nil }).count == 1,
                  arguments.filter({ $0.label?.name == "title" }).count == arguments.count - 1,
                  arguments.contains(where: { $0.label == nil }) else {
                throw issue(.unsupported, call.node, "Unsupported checked tooltip display modifier contract")
            }
            for (index, key) in keys.enumerated() {
                let parameter = spec.signatures[0].params[index]
                guard parameter.name == (index == 0 ? "text" : "title"),
                      parameter.label == (index == 0 ? nil : "title"), parameter.type == .string,
                      parameter.role == .display, parameter.source == .any, parameter.translatable,
                      parameter.required == (index == 0), !parameter.variadic, parameter.defaultValue == nil,
                      parameter.sameAs == nil, parameter.range == nil, !parameter.wholeNumber, parameter.unit == nil,
                      parameter.specificity == 0, parameter.facets == [key],
                      let facet = catalog.facet(key), facet.valueType == .string, !facet.inheritable else {
                    throw issue(.unsupported, call.node, "Unsupported checked tooltip display parameter or facet contract")
                }
            }
        }
        guard let text = try displayFacet(facts, "tooltip", modifier: "tooltip", label: nil, call: call) else {
            throw issue(.invalidCheckedModel, call.node, "Tooltip has no checked text facet")
        }
        let title = try displayFacet(facts, "tooltip.title", modifier: "tooltip", label: "title", call: call)
        return ProgramTooltip(text: text, title: title)
    }

    private mutating func menu(_ facts: ElementFacts, call: CallStmtSyntax, depth: Int) throws -> [ProgramMenuNode]? {
        let modifiers = call.modifiers.filter { $0.name.token.text == "menu" }
        guard !facts.inherits.contains("menu") else {
            throw issue(.invalidCheckedModel, call.node, "Menus cannot inherit")
        }
        if modifiers.isEmpty { return nil }
        guard modifiers.count == 1, let modifier = modifiers.first,
              checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier("menu")),
              let spec = catalog.modifier(named: "menu"), spec.appliesTo.contains(facts.kind),
              spec.context == .view, spec.boxLayer == .none, spec.facets.isEmpty, spec.fixedValues.isEmpty,
              !spec.softFacets, !spec.inheritable, !spec.allowedInStyle, !spec.allowedInState, !spec.acceptsCondition,
              spec.repeatable == .no, spec.event == nil, spec.timing == nil,
              spec.block == .menuItems(required: true), spec.signatures.count == 1,
              spec.signatures[0].params.isEmpty, spec.signatures[0].result == nil,
              (modifier.arguments?.arguments ?? []).isEmpty, let block = modifier.block else {
            throw issue(.invalidCheckedModel, call.node, "Unsupported checked menu modifier contract")
        }
        return try block.items.map { try menuStatement($0, parent: checked.tree.id(of: call.node), depth: depth + 1) }
    }

    /// Menu structure is not view geometry. All paths, including inactive branches, share the program limits.
    private mutating func menuStatement(_ node: PositionedNode, parent: NodeID, depth: Int) throws -> ProgramMenuNode {
        if node.kind == .ifStmt {
            _ = try reserveIndex(at: node, depth: depth)
            var branches: [ProgramMenuConditionalBranch] = [], otherwise: [ProgramMenuNode] = []
            var current: PositionedNode? = node
            while let statement = current {
                guard let syntax = IfStmtSyntax(statement), syntax.modifiers.isEmpty,
                      checked.elements[checked.tree.id(of: statement)] == nil else {
                    throw issue(.invalidCheckedModel, statement, "A menu if has no element facets or attached modifiers")
                }
                let condition = try expressions.condition(syntax.condition.node)
                let body = try syntax.block.items.map { try menuStatement($0, parent: parent, depth: depth + 1) }
                branches.append(ProgramMenuConditionalBranch(condition: condition, body: body))
                current = nil
                if let clause = syntax.elseClause {
                    switch clause.body.kind {
                    case .ifStmt: current = clause.body
                    case .block:
                        guard let block = BlockSyntax(clause.body) else {
                            throw issue(.invalidCheckedModel, clause.body, "Missing checked menu else block")
                        }
                        otherwise = try block.items.map { try menuStatement($0, parent: parent, depth: depth + 1) }
                    default: throw issue(.invalidCheckedModel, clause.body, "Expected a menu else block or else if")
                    }
                }
            }
            return .conditional(ProgramMenuConditional(branches: branches, otherwise: otherwise))
        }
        guard node.kind == .callStmt else {
            throw issue(.unsupported, node, "Only Item, Divider, Menu and menu-level if statements are implemented")
        }
        guard let call = CallStmtSyntax(node), call.callee.path.count == 1,
              let facts = checked.elements[checked.tree.id(of: node)], facts.component == call.callee.path[0],
              let spec = catalog.component(named: facts.component), spec.kind == facts.kind,
              facts.parent == parent, facts.facets.isEmpty, facts.inherits.isEmpty, facts.name == nil,
              !facts.isRoot, facts.dropped.isEmpty, seenElements.insert(checked.tree.id(of: node)).inserted else {
            throw issue(.invalidCheckedModel, node, "Expected a checked menu call with its real source parent")
        }
        _ = try reserveIndex(at: node, depth: depth)
        let arguments = call.arguments?.arguments ?? []
        switch facts.component {
        case "Divider":
            guard spec.kind == .divider, spec.block == .none, spec.backing == .content,
                  spec.signatures.count == 1, spec.signatures[0].params.isEmpty,
                  spec.signatures[0].result == nil, arguments.isEmpty, call.block == nil, call.modifiers.isEmpty else {
                throw issue(.unsupported, node, "A menu Divider requires the checked separator contract")
            }
            return .divider
        case "Item", "Menu":
            let item = facts.component == "Item"
            guard spec.kind == (item ? .item : .menu), spec.group == .menuEntries, spec.backing == .content,
                  spec.allowedParents == .of(.menu), spec.defaults.isEmpty,
                  spec.block == (item ? .none : .menuItems(required: true)),
                  spec.signatures.count == 1, spec.signatures[0].result == nil,
                  spec.signatures[0].params.count == (item ? 3 : 1),
                  arguments.filter({ $0.label == nil }).count == 1,
                  arguments.count <= (item ? 3 : 1),
                  arguments.filter({ $0.label != nil }).allSatisfy({ item && ["checked", "enabled"].contains($0.label!.name) }),
                  arguments.filter({ $0.label?.name == "checked" }).count <= 1,
                  arguments.filter({ $0.label?.name == "enabled" }).count <= 1,
                  let title = arguments.first(where: { $0.label == nil }) else {
                throw issue(.unsupported, node, "Unsupported checked Item or Menu contract")
            }
            let params = spec.signatures[0].params
            for (index, parameter) in params.enumerated() {
                let name = index == 0 ? "title" : index == 1 ? "checked" : "enabled"
                guard parameter.name == name, parameter.label == (index == 0 ? nil : name),
                      parameter.type == (index == 0 ? .string : .bool),
                      parameter.role == (index == 0 ? .display : .plain), parameter.source == .any,
                      parameter.translatable == (index == 0), parameter.required == (index == 0),
                      !parameter.variadic, parameter.facets.isEmpty, parameter.specificity == 0,
                      parameter.sameAs == nil, parameter.range == nil, !parameter.wholeNumber, parameter.unit == nil,
                      index != 0 || parameter.defaultValue == nil else {
                    throw issue(.unsupported, node, "Unsupported checked menu display or Bool parameter contract")
                }
            }
            let text = try expressions.text(title.value.node)
            if !item {
                guard call.modifiers.isEmpty, let block = call.block else {
                    throw issue(.unsupported, node, "Submenus require a menu body and no view modifiers")
                }
                let items = try block.items.map { try menuStatement($0, parent: checked.tree.id(of: node), depth: depth + 1) }
                return .submenu(title: text, items: items)
            }
            guard call.block == nil, call.modifiers.count <= 1,
                  call.modifiers.allSatisfy({ $0.name.token.text == "onClick" }) else {
                throw issue(.unsupported, node, "Menu Items support only their onClick action block")
            }
            var values: [ProgramExpression] = []
            for parameter in params.dropFirst() {
                guard case .source(let source)? = parameter.defaultValue,
                      case .boolean(let value) = try fixed(source, at: node) else {
                    throw issue(.unsupported, node, "Menu states require checked Bool catalog defaults")
                }
                if let argument = arguments.first(where: { $0.label?.name == parameter.name }) {
                    values.append(try expressions.condition(argument.value.node))
                } else { values.append(.boolean(value)) }
            }
            let actions = try call.modifiers.first.map { try clickActions($0, kind: .item) } ?? []
            return .item(ProgramMenuItem(title: text, checked: values[0], enabled: values[1], actions: actions))
        default:
            throw issue(.unsupported, node, "Only Item, Divider, Menu and menu-level if statements are implemented")
        }
    }

    private mutating func clickActions(_ modifier: ModifierAppSyntax, kind: ElementKind) throws -> [ProgramAction] {
        let identity = checked.tree.id(of: modifier.node)
        let name = modifier.name.token.text
        let runtimeEvent: String
        switch name {
        case "onClick": runtimeEvent = "leftMouseUp"
        case "onRightClick": runtimeEvent = "rightMouseUp"
        default: throw issue(.invalidCheckedModel, modifier.node, "Unsupported checked click event")
        }
        guard checked.symbols[identity] == .builtIn(.modifier(name)),
              let spec = catalog.modifier(named: name), spec.appliesTo.contains(kind),
              spec.event == EventSpec(runtimeEvent: runtimeEvent, userInitiated: true, eventRecord: "Event"),
              spec.timing == nil, case .actions(required: true) = spec.block,
              spec.signatures.count == 1, spec.signatures[0].params.isEmpty,
              (modifier.arguments?.arguments ?? []).isEmpty, let block = modifier.block else {
            throw issue(.invalidCheckedModel, modifier.node, "Missing checked built-in \(name) contract")
        }
        let limit = min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens)
        guard clickActionCount <= limit, onLoad.count <= limit - clickActionCount,
              block.items.count <= limit - clickActionCount - onLoad.count else {
            throw issue(.resourceLimit, block.node, "Shared program action limit exceeded")
        }
        let actions = try block.items.map { try clickAction($0) }
        clickActionCount += actions.count
        return actions
    }

    private mutating func clickAction(_ statement: PositionedNode) throws -> ProgramAction {
        if let assignment = AssignmentSyntax(statement) {
            return try expressions.clickAssignment(assignment)
        }
        guard let call = CallStmtSyntax(statement), call.callee.path.count == 1,
              let name = call.callee.path.first, name == "copy" || name == "open",
              call.block == nil, call.modifiers.isEmpty,
              let arguments = call.arguments?.arguments, arguments.count == 1,
              arguments[0].label == nil else {
            throw issue(.unsupported, statement, "Only local option or session variable assignments, copy and open are implemented in click events")
        }
        guard checked.symbols[checked.tree.id(of: call.callee.node)] == .builtIn(.function(name)) else {
            throw issue(.invalidCheckedModel, call.callee.node, "Missing checked built-in action identity")
        }
        guard let function = catalog.function(named: name), function.kind == .action,
              function.userInitiatedOnly, function.permission == nil, !function.pure, function.onlyInActions,
              !function.takesActionBlock, function.actionTwin == nil, function.data == nil,
              function.signatures.count == 1, function.signatures[0].result == nil,
              function.signatures[0].params.count == 1 else {
            throw issue(.unsupported, call.callee.node, "Unsupported checked \(name) action catalog contract")
        }
        let parameter = function.signatures[0].params[0]
        guard parameter.name == (name == "copy" ? "text" : "target"),
              parameter.label == nil, parameter.type == .string, parameter.required,
              parameter.defaultValue == nil, parameter.range == nil, !parameter.wholeNumber, !parameter.variadic,
              parameter.sameAs == nil, parameter.facets.isEmpty, parameter.specificity == 0,
              parameter.role == (name == "copy" ? .display : .plain), parameter.source == .any,
              !parameter.translatable, parameter.unit == nil else {
            throw issue(.unsupported, call.callee.node, "Unsupported checked \(name) action parameter contract")
        }
        if name == "copy" { return .copy(try expressions.copyText(arguments[0].value.node)) }
        return .open(try expressions.actionString(arguments[0].value.node))
    }

    private mutating func rootOnLoad(_ modifier: ModifierAppSyntax, element: PositionedNode) throws {
        let elementID = checked.tree.id(of: element), modifierID = checked.tree.id(of: modifier.node)
        guard checked.root == elementID else {
            throw issue(.unsupported, modifier.node, "Only the widget root's onLoad is implemented")
        }
        guard let spec = catalog.modifier(named: "onLoad"), spec.timing == .onLoad,
              case .actions(required: true) = spec.block, (modifier.arguments?.arguments ?? []).isEmpty,
              let block = modifier.block else {
            throw issue(.invalidCheckedModel, modifier.node, "Missing checked root onLoad contract")
        }
        let reactions = checked.reactions.filter { $0.modifier == modifierID }
        guard reactions.count == 1, let reaction = reactions.first, reaction.kind == .onLoad,
              reaction.element == elementID, reaction.dependencies.isEmpty, reaction.interval == nil else {
            throw issue(.invalidCheckedModel, modifier.node, "Root onLoad has inconsistent checked reaction identity")
        }
        let limit = min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens)
        guard clickActionCount <= limit, onLoad.count <= limit - clickActionCount,
              block.items.count <= limit - clickActionCount - onLoad.count else {
            throw issue(.resourceLimit, block.node, "Shared program action limit exceeded")
        }
        for statement in block.items {
            guard let assignment = AssignmentSyntax(statement) else {
                throw issue(.unsupported, statement, "Only session variable assignments are implemented in root onLoad")
            }
            onLoad.append(try expressions.assignment(assignment))
        }
    }

    private mutating func resolvedAppearance(_ facts: ElementFacts, inherited: Appearance, call: CallStmtSyntax) throws -> Appearance {
        let node = call.node
        var result = try defaultAppearance(at: node)
        for key in ["font.family", "font.size", "font.weight", "font.italic", "font.design", "color", "align", "digits"] {
            if key == "color" {
                var ancestor = facts.parent, seen = Set<NodeID>()
                var hasAncestorColor = false
                while let identity = ancestor {
                    guard seen.insert(identity).inserted, let parent = checked.elements[identity] else {
                        throw issue(.invalidCheckedModel, node, "Color inheritance refers to an invalid ancestor")
                    }
                    if !(parent.facets["color"] ?? []).isEmpty { hasAncestorColor = true; break }
                    ancestor = parent.parent
                }
                let hasBase = (facts.facets["color"] ?? []).contains { $0.condition == nil }
                guard facts.inherits.contains("color") == (!hasBase && hasAncestorColor) else {
                    throw issue(.invalidCheckedModel, node, "Color inheritance does not match its checked candidates")
                }
                let fallback = facts.inherits.contains("color") ? inherited.color : result.color
                result.color = try conditionalColor(facts, key, fallback: fallback, call: call)
                continue
            }
            if key == "font.size", let best = facts.facets[FacetID(key)]?.first {
                if let fixed = best.fixedValue {
                    try assign(try self.fixed(fixed, at: node), to: key, appearance: &result, at: node)
                } else {
                    let compiler = try facetCompiler(facts, key, at: node)
                    guard let value = compiler.checked.tree.resolve(best.value) else {
                        throw issue(.invalidCheckedModel, node, "Font size refers to a different syntax tree")
                    }
                    if NumberLiteralSyntax(value) != nil || best.level == 2 {
                        try assign(try compiler.lengthConstant(value), to: key, appearance: &result, at: value)
                    } else {
                        result.sizeExpression = try expressions.fontSize(value)
                    }
                }
                continue
            }
            let value = try facet(facts, key, at: node)
            if value == nil, facts.inherits.contains(FacetID(key)) {
                switch key {
                case "font.family": result.family = inherited.family
                case "font.size": result.size = inherited.size; result.sizeExpression = inherited.sizeExpression
                case "font.weight": result.weight = inherited.weight
                case "font.italic": result.italic = inherited.italic
                case "font.design": result.design = inherited.design
                case "color": result.color = inherited.color
                case "align": result.align = inherited.align
                case "digits": result.digits = inherited.digits
                default: break
                }
            } else if let value {
                try assign(value, to: key, appearance: &result, at: node)
            }
        }
        return result
    }

    private func defaultAppearance(at node: PositionedNode) throws -> Appearance {
        var result = Appearance()
        guard let body = catalog.enumeration("FontPreset")?.enumCase(named: "body") else {
            throw issue(.invalidCheckedModel, node, "The checking catalog has no body font")
        }
        for (facet, value) in body.facetValues.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try assign(try fixed(value.value, at: node), to: facet.rawValue, appearance: &result, at: node)
        }
        return result
    }

    private func fontFamily(_ appearance: Appearance, at node: PositionedNode) throws -> String {
        switch appearance.design {
        case "standard": return appearance.family
        case "rounded" where appearance.family == "System": return "System Rounded"
        case "mono" where appearance.family == "System": return "System Mono"
        case "serif" where appearance.family == "System": return "System Serif"
        default: throw issue(.unsupported, node, "Unsupported font design/family combination")
        }
    }

    private func assign(_ value: Value, to key: String, appearance: inout Appearance, at node: PositionedNode) throws {
        switch (key, value) {
        case ("font.family", .string(let n)): appearance.family = n
        case ("font.size", .number(let n)) where n > 0: appearance.size = n; appearance.sizeExpression = nil
        case ("font.weight", .choice(let n)):
            let weights = ["ultralight": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500,
                           "semibold": 600, "bold": 700, "heavy": 800, "black": 900]
            guard let value = weights[n] else { throw issue(.unsupported, node, "Unsupported font weight") }
            appearance.weight = value
        case ("font.italic", .boolean(let n)): appearance.italic = n
        case ("font.design", .choice(let n)): appearance.design = n
        case ("align", .choice(let n)): appearance.align = try horizontal(n, at: node)
        case ("digits", .choice(let n)):
            guard catalog.enumeration("Digits")?.enumCase(named: n) != nil else { throw issue(.unsupported, node, "Unsupported digits catalog case") }
            switch n {
            case "normal": appearance.digits = .normal
            case "equalWidth": appearance.digits = .equalWidth
            default: throw issue(.unsupported, node, "Unsupported digits policy")
            }
        case ("color", let value): appearance.color = try color(value, at: node)
        default: throw issue(.unsupported, node, "Unsupported constant for facet \(key)")
        }
    }

    /// Match every expansion occurrence, including repeated styles and losing facets, to its definition tree.
    private mutating func candidatePositions(_ facts: ElementFacts, call: CallStmtSyntax) throws {
        let all = facts.facets.values.flatMap { $0 }
        let positions = all.map(\.position)
        guard Set(positions).count == positions.count, Set(positions) == Set((0..<positions.count).map { $0 + 1 }) else {
            throw issue(.invalidCheckedModel, call.node, "Facet expansion positions are not the checked sequence")
        }
        var position = 0
        for item in expandedModifiers[checked.tree.id(of: call.node)] ?? [] {
            if item.isStyle {
                let expected = try styleFacets(item)
                styleExpansionCount += expected.count
                guard styleExpansionCount <= min(ProgramLimits.maximumExpressions, catalog.limits.maximumTokens) else {
                    throw issue(.resourceLimit, call.node, "Shared program style candidate limit exceeded")
                }
                for (key, value, fixed, hard) in expected {
                    position += 1
                    guard let candidate = facts.facets[key]?.first(where: { $0.position == position }),
                          candidate.origin == item.origin, candidate.value == value, candidate.fixedValue == fixed,
                          candidate.level == 2, candidate.hard == hard, candidate.condition == nil else {
                        throw issue(.invalidCheckedModel, call.node, "Style facet does not match its checked expansion and precedence")
                    }
                }
            } else {
                for candidate in all.filter({ $0.origin == item.origin }).sorted(by: { $0.position < $1.position }) {
                    position += 1
                    guard candidate.position == position, candidate.level == 3,
                          candidate.value.treeVersion == checked.tree.version else {
                        throw issue(.invalidCheckedModel, item.modifier.node, "Own facets do not follow their checked source modifiers")
                    }
                }
            }
        }
        guard position == all.count else {
            throw issue(.invalidCheckedModel, call.node, "Facet refers to a modifier outside the checked expansion")
        }
        for candidates in facts.facets.values {
            for index in candidates.indices where index > 0 {
                guard candidates[index - 1].sortKey > candidates[index].sortKey else {
                    throw issue(.invalidCheckedModel, call.node, "Facet candidates are not in checked precedence order")
                }
            }
        }
    }

    private struct OwnCandidate {
        let value: PositionedNode?
        let condition: PositionedNode?
        let source: CheckedFile
    }

    /// Consume every candidate, including an inactive branch, against the modifier that actually produced it.
    private func ownCandidates(_ facts: ElementFacts, _ key: String, call: CallStmtSyntax) throws -> [OwnCandidate] {
        let modifiers = sourceModifiers(call, named: key)
        let candidates = facts.facets[FacetID(key)] ?? []
        guard candidates.count == modifiers.count,
              key == "hidden" || candidates.filter({ $0.condition == nil && $0.level == 3 }).count <= 1 else {
            throw issue(.invalidCheckedModel, call.node, "\(key) candidates do not match their own modifiers")
        }
        guard !modifiers.isEmpty else { return [] }
        guard let spec = catalog.modifier(named: key), spec.appliesTo.contains(facts.kind),
              spec.facets == [FacetID(key)], spec.fixedValues.isEmpty, !spec.softFacets,
              spec.acceptsCondition, spec.block == .none, spec.event == nil, spec.timing == nil,
              spec.boxLayer == .none, spec.inheritable == (key == "color"),
              spec.context == (key == "hidden" ? .both : .view),
              spec.repeatable == (key == "hidden" ? .yes : .no),
              let signature = spec.signatures.first, signature.params.count == 1,
              let parameter = signature.params.first, parameter.facets == [FacetID(key)],
              parameter.type == (key == "hidden" ? .bool : key == "fill" ? .paint : .color),
              parameter.role == (key == "hidden" ? .condition : .plain),
              parameter.label == (key == "hidden" ? "if" : nil),
              parameter.name == (key == "hidden" ? "condition" : key == "fill" ? "paint" : "color"),
              parameter.source == .any, !parameter.variadic, !parameter.translatable,
              parameter.sameAs == nil, parameter.range == nil, parameter.unit == nil,
              !parameter.wholeNumber,
              parameter.defaultValue == (key == "hidden" ? .source("true") : nil),
              parameter.required == (key != "hidden"),
              spec.signatures.count == (key == "color" ? 2 : 1),
              let facet = catalog.facet(FacetID(key)), facet.inheritable == (key == "color"),
              facet.valueType == parameter.type else {
            throw issue(.unsupported, call.node, "Unsupported checked \(key) conditional catalog contract")
        }
        if key == "color" {
            guard spec.signatures[1].params.count == 2,
                  ["light", "dark"].allSatisfy({ label in
                      guard let parameter = spec.signatures[1].param(named: label) else { return false }
                      return parameter.label == label && parameter.type == .color && parameter.required &&
                          parameter.facets == [FacetID("color")]
                  }) else {
                throw issue(.unsupported, call.node, "Unsupported checked light/dark color catalog contract")
            }
        }
        var result: [OwnCandidate] = []
        var usedOwnModifiers = Set<NodeID>()
        for (index, candidate) in candidates.enumerated() {
            let item = try modifier(candidate, call: call)
            let modifier = item.modifier, source = item.source
            guard candidate.level == (item.isStyle ? 2 : 3), candidate.hard,
                  index == 0 || candidates[index - 1].sortKey > candidate.sortKey,
                  modifier.name.token.text == key,
                  item.isStyle || usedOwnModifiers.insert(source.tree.id(of: modifier.node)).inserted,
                  source.symbols[source.tree.id(of: modifier.node)] == .builtIn(.modifier(key)) else {
                throw issue(.invalidCheckedModel, call.node, "Paint/visibility has an invalid checked source or precedence receipt")
            }
            let arguments = modifier.arguments?.arguments ?? []
            let condition = arguments.first(where: { $0.label?.name == "if" })?.value.node
            let value = arguments.first(where: { $0.label == nil })?.value.node
            guard arguments.filter({ $0.label?.name == "if" }).count <= 1,
                  arguments.allSatisfy({ $0.label == nil || $0.label?.name == "if" }),
                  arguments.filter({ $0.label == nil }).count == (key == "hidden" ? 0 : 1),
                  candidate.condition == condition.map({ .expr(source.tree.id(of: $0)) }),
                  condition.map({ source.types[source.tree.id(of: $0)]?.type == .bool }) ?? true,
                  candidate.fixedValue == (key == "hidden" ? "true" : nil),
                  candidate.value == source.tree.id(of: key == "hidden" ? (condition ?? modifier.node) : (value ?? modifier.node)) else {
                throw issue(.invalidCheckedModel, modifier.node, "Paint/visibility does not match its checked arguments")
            }
            result.append(OwnCandidate(value: value, condition: condition, source: source))
        }
        return result
    }

    private mutating func hidden(_ facts: ElementFacts, call: CallStmtSyntax) throws -> (hidden: Bool, condition: ProgramExpression?) {
        let candidates = try ownCandidates(facts, "hidden", call: call)
        var conditions: [ProgramExpression] = []
        for candidate in candidates {
            if let condition = candidate.condition { conditions.append(try expressions.condition(condition)) }
        }
        return (candidates.contains { $0.condition == nil }, try expressions.hiddenConditions(conditions, at: call.node))
    }

    private mutating func conditionalColor(_ facts: ElementFacts, _ key: String, fallback: ProgramColor,
                                          call: CallStmtSyntax) throws -> ProgramColor {
        let candidates = try ownCandidates(facts, key, call: call)
        // All leaves are lowered, even after an unconditional winner or under an always-false condition.
        var values: [(color: ProgramColor, condition: ProgramExpression?)] = []
        for candidate in candidates {
            guard let value = candidate.value else {
                throw issue(.invalidCheckedModel, call.node, "A paint candidate has no checked argument")
            }
            values.append((try sourceCompiler(candidate.source).checkedFacetColor(value),
                           try candidate.condition.map { try expressions.condition($0) }))
        }
        var result = values.first(where: { $0.condition == nil })?.color ?? fallback
        // The checker gives best-first order; wrapping low-to-high retains that exact precedence.
        for value in values.reversed() {
            if let condition = value.condition { result = .conditional(condition, then: value.color, otherwise: result) }
        }
        return result
    }

    /// Parentheses preserve a static color's checked value; they do not introduce scalar Paint evaluation.
    private func checkedFacetColor(_ node: PositionedNode, depth: Int = 1) throws -> ProgramColor {
        guard depth <= min(ProgramLimits.maximumExpressionDepth, catalog.limits.maximumExpressionNesting) else {
            throw issue(.resourceLimit, node, "Shared program color expression depth exceeded")
        }
        let identity = checked.tree.id(of: node)
        guard checked.canonicalNumericValues[identity] == nil, checked.numericCoercions[identity] == nil else {
            throw issue(.invalidCheckedModel, node, "A static color cannot have a numeric conversion receipt")
        }
        if let paren = ParenExprSyntax(node) {
            guard checked.types[identity]?.type == checked.types[checked.tree.id(of: paren.value.node)]?.type else {
                throw issue(.invalidCheckedModel, node, "Color parentheses do not preserve their checked type")
            }
            return try checkedFacetColor(paren.value.node, depth: depth + 1)
        }
        return try checkedBoxColor(node)
    }

    private mutating func meterColor(_ facts: ElementFacts, _ key: String, spec: ComponentSpec,
                                    call: CallStmtSyntax) throws -> ProgramColor {
        if (facts.facets[FacetID(key)] ?? []).contains(where: { $0.condition == nil }) {
            return try conditionalColor(facts, key, fallback: .literal(.clear), call: call)
        }
        guard let source = spec.defaults[FacetID(key)] else {
            throw issue(.invalidCheckedModel, call.node, "The checking catalog has no \(spec.name).\(key) default")
        }
        return try conditionalColor(facts, key, fallback: color(fixed(source, at: call.node), at: call.node), call: call)
    }

    private func boxModifierContract(_ modifier: ModifierAppSyntax, kind: ElementKind) throws {
        let name = modifier.name.token.text
        guard checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier(name)),
              let spec = catalog.modifier(named: name), spec.appliesTo.contains(kind),
              spec.boxLayer == .background, !spec.inheritable, spec.block == .none else {
            throw issue(.unsupported, modifier.node, "Unsupported checked box modifier contract")
        }
        if name == "background" {
            guard spec.signatures.count == 2, spec.signatures[0].params.count == 2,
                  let paint = spec.signatures[0].param(named: "paint"), paint.label == nil,
                  paint.type == .paint, paint.facets == [FacetID("background")], paint.defaultValue == nil,
                  let tint = spec.signatures[0].param(named: "tint"), tint.label == "tint",
                  tint.type == .color, tint.facets == [FacetID("background.tint")], tint.defaultValue == nil else {
                throw issue(.unsupported, modifier.node, "Unsupported checked background paint/tint contract")
            }
        } else {
            let corners = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
            guard spec.signatures.count == 1, spec.signatures[0].params.count == 5,
                  let radius = spec.signatures[0].param(named: "radius"), radius.label == nil,
                  radius.type == .oneOf([.length, .enumeration("RadiusKeyword")]),
                  radius.facets == corners.map({ FacetID("rounded.\($0)") }),
                  radius.defaultValue == nil,
                  corners.allSatisfy({ name in
                      guard let param = spec.signatures[0].param(named: name) else { return false }
                      return param.label == name && param.type == .length && param.facets == [FacetID("rounded.\(name)")] && param.defaultValue == nil
                  }) else {
                throw issue(.unsupported, modifier.node, "Unsupported checked uniform rounding contract")
            }
        }
    }

    /// A new box property consumes an actual checked argument from this element, never a fabricated fixed value.
    private func boxArgument(_ facts: ElementFacts, _ key: String, modifier name: String,
                             call: CallStmtSyntax) throws -> PositionedNode? {
        guard let best = facts.facets[FacetID(key)]?.first else {
            let hasArgument = sourceModifiers(call, named: name).contains { item in
                (item.modifier.arguments?.arguments ?? []).contains { argument in
                    let parameter = argument.label?.name ?? (name == "background" ? "paint" : "radius")
                    return catalog.modifier(named: name)?.signatures.contains {
                        $0.param(named: parameter)?.facets.contains(FacetID(key)) == true
                    } == true
                }
            }
            guard !hasArgument else { throw issue(.invalidCheckedModel, call.node, "Box argument has no checked facet receipt") }
            return nil
        }
        let item = try modifier(best, call: call), source = item.source
        guard best.fixedValue == nil, item.modifier.name.token.text == name,
              let value = source.tree.resolve(best.value),
              let argument = item.modifier.arguments?.arguments.first(where: { source.tree.id(of: $0.value.node) == best.value }),
              let spec = catalog.modifier(named: name) else {
            throw issue(.invalidCheckedModel, call.node, "Box facet does not refer to its checked modifier argument")
        }
        let parameter = argument.label?.name ?? (name == "background" ? "paint" : "radius")
        guard spec.signatures.contains(where: { $0.param(named: parameter)?.facets.contains(FacetID(key)) == true }) else {
            throw issue(.invalidCheckedModel, value, "Box facet does not match its checked parameter")
        }
        return value
    }

    private func checkedBoxColor(_ node: PositionedNode) throws -> ProgramColor {
        if allowsStyleParentheses, let paren = ParenExprSyntax(node) { return try checkedBoxColor(paren.value.node) }
        let identity = checked.tree.id(of: node)
        if let string = StringLiteralSyntax(node)?.literalValue, checked.types[identity]?.type == .string {
            return try color(.string(string), at: node)
        }
        let implicit = ImplicitMemberExprSyntax(node)
        let name = implicit?.name.token.text ?? MemberExprSyntax(node)?.name.token.text
        guard implicit?.arguments == nil, let name, checked.types[identity]?.type == .color,
              checked.symbols[identity] == .enumCase(type: "Color", case: name),
              catalog.index.namedValues["Color.\(name)"]?.type == "Color" else {
            throw issue(.unsupported, node, "Solid colors require a checked literal or catalog Color value")
        }
        return try color(.choice(name), at: node)
    }

    private func background(_ facts: ElementFacts, call: CallStmtSyntax) throws -> ProgramBackground? {
        guard let paint = try boxArgument(facts, "background", modifier: "background", call: call) else {
            guard sourceModifiers(call, named: "background").isEmpty, facts.facets["background.tint"] == nil else {
                throw issue(.invalidCheckedModel, call.node, "Background has no checked paint argument")
            }
            return nil
        }
        let tint = try boxArgument(facts, "background.tint", modifier: "background", call: call)
        let compiler = try facetCompiler(facts, "background", at: call.node)
        let literal = compiler.allowsStyleParentheses ? compiler.styleLeaf(paint) : paint
        let identity = compiler.checked.tree.id(of: literal)
        if let implicit = ImplicitMemberExprSyntax(literal), implicit.arguments != nil {
            throw issue(.unsupported, paint, "Background catalog values cannot take arguments")
        }
        if case .enumCase(type: "Paint", case: let name)? = compiler.checked.symbols[identity],
           compiler.checked.types[identity]?.type == .paint, catalog.index.namedValues["Paint.\(name)"]?.type == "Paint",
           ImplicitMemberExprSyntax(literal)?.name.token.text == name || MemberExprSyntax(literal)?.name.token.text == name {
            let style: GlassStyle
            switch name {
            case "glass": style = .regular
            case "clearGlass": style = .clear
            default: throw issue(.unsupported, paint, "Unsupported catalog background Paint")
            }
            return .glass(style: style, tint: try tint.map { try facetCompiler(facts, "background.tint", at: call.node).checkedBoxColor($0) })
        }
        guard tint == nil else { throw issue(.unsupported, paint, "A background tint is implemented only for glass") }
        return .color(try compiler.checkedBoxColor(paint))
    }

    private func uniformRadius(_ facts: ElementFacts, call: CallStmtSyntax) throws -> ProgramCornerRadius? {
        let keys = ["rounded.topLeft", "rounded.topRight", "rounded.bottomLeft", "rounded.bottomRight"]
        guard keys.contains(where: { facts.facets[FacetID($0)] != nil }) else {
            guard sourceModifiers(call, named: "rounded").isEmpty else {
                throw issue(.invalidCheckedModel, call.node, "Rounded has no checked explicit radius")
            }
            return nil
        }
        var corners: [ProgramCornerRadius] = []
        for key in keys {
            guard let value = try boxArgument(facts, key, modifier: "rounded", call: call) else {
                corners.append(.points(0)); continue
            }
            let compiler = try facetCompiler(facts, key, at: call.node)
            let identity = compiler.checked.tree.id(of: value)
            let literal = compiler.allowsStyleParentheses ? compiler.styleLeaf(value) : value
            switch try roundedFacet(facts, key, at: call.node) {
            case .number(let n)? where n >= 0:
                guard compiler.checked.types[identity]?.type == .length || compiler.checked.types[identity]?.type == .plainNumber,
                      compiler.checked.canonicalNumericValues[identity] == n else {
                    throw issue(.unsupported, value, "Rounded requires a checked finite Length literal receipt")
                }
                corners.append(.points(n))
            case .choice("full")?:
                guard compiler.checked.types[identity]?.type == .enumeration("RadiusKeyword"),
                      compiler.checked.symbols[compiler.checked.tree.id(of: literal)] == .enumCase(type: "RadiusKeyword", case: "full"),
                      catalog.enumeration("RadiusKeyword")?.enumCase(named: "full") != nil else {
                    throw issue(.unsupported, value, "Full rounding requires the checked RadiusKeyword case")
                }
                corners.append(.full)
            default: throw issue(.unsupported, value, "Corner radii require nonnegative constants or .full")
            }
        }
        guard let first = corners.first, corners.allSatisfy({ $0 == first }) else {
            throw issue(.unsupported, call.node, "Different corner radii are not implemented")
        }
        return first
    }

    private func color(_ value: Value, at node: PositionedNode) throws -> ProgramColor {
        switch value {
        case .choice(let n):
            guard catalog.index.namedValues["Color.\(n)"] != nil,
                  let palette = ProgramPaletteColor(rawValue: n) else {
                throw issue(.unsupported, node, "Unsupported catalog color \(n)")
            }
            switch n {
            case "text": return .text
            case "dim": return .dim
            case "faint": return .faint
            case "accent": return .accent
            case "separator": return .separator
            default: return .palette(palette)
            }
        case .string(let hex):
            let bytes = Array(hex.utf8)
            guard bytes.first == 35, bytes.count == 7 || bytes.count == 9,
                  let value = UInt32(String(hex.dropFirst()), radix: 16) else {
                throw issue(.unsupported, node, "Static colors require #RRGGBB or #RRGGBBAA")
            }
            let rgba: RGBA
            if bytes.count == 7 {
                rgba = RGBA(r: Double((value >> 16) & 255), g: Double((value >> 8) & 255), b: Double(value & 255))
            } else {
                rgba = RGBA(r: Double((value >> 24) & 255), g: Double((value >> 16) & 255), b: Double((value >> 8) & 255), a: Double(value & 255))
            }
            return .literal(rgba)
        default: throw issue(.unsupported, node, "Unsupported constant for facet color")
        }
    }

    private func horizontal(_ value: String, at node: PositionedNode) throws -> HorizontalTextAlign {
        switch value {
        case "left": return .left
        case "center": return .center
        case "right": return .right
        default: throw issue(.unsupported, node, "Unsupported horizontal alignment: \(value)")
        }
    }

    private func alignment(_ value: String, at node: PositionedNode) throws -> ProgramAlignment {
        guard catalog.enumeration("Alignment")?.enumCase(named: value) != nil,
              let alignment = ProgramAlignment(rawValue: value) else {
            throw issue(.unsupported, node, "Unsupported box alignment: \(value)")
        }
        return alignment
    }

    private func position(_ facts: ElementFacts, call: CallStmtSyntax) throws -> ProgramPosition? {
        let modifiers = call.modifiers.filter { $0.name.token.text == "position" }
        guard !modifiers.isEmpty || facts.facets.keys.contains(where: { $0.rawValue.hasPrefix("position.") }) else { return nil }
        guard let parent = facts.parent, checked.elements[parent]?.component == "Freeform",
              modifiers.count == 1, let modifier = modifiers.first,
              checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier("position")),
              let spec = catalog.modifier(named: "position"), spec.appliesTo.contains(facts.kind),
              spec.signatures.count == 1, spec.signatures[0].params.count == 3 else {
            throw issue(.invalidCheckedModel, call.node, "Position requires a checked direct Freeform child")
        }
        func value(_ parameter: String, type: DeskType) throws -> Value {
            let key = "position.\(parameter)"
            guard let param = spec.signatures[0].param(named: parameter), param.type == type,
                  param.facets == [FacetID(key)], case .source(let source)? = param.defaultValue else {
                throw issue(.unsupported, modifier.node, "Unsupported position catalog contract")
            }
            return try facet(facts, key, at: modifier.node) ?? fixed(source, at: modifier.node)
        }
        guard case .number(let x) = try value("x", type: .length),
              case .number(let y) = try value("y", type: .length),
              case .choice(let anchor) = try value("anchor", type: .enumeration("Alignment")) else {
            throw issue(.unsupported, modifier.node, "Position requires constant coordinates and anchor")
        }
        return ProgramPosition(x: x, y: y, anchor: try alignment(anchor, at: modifier.node))
    }

    private func length(_ facts: ElementFacts, _ key: String, default source: String, at node: PositionedNode) throws -> ProgramLength {
        let value = try facet(facts, key, at: node) ?? fixed(source, at: node)
        switch value {
        case .choice("fit"): return .fit
        case .choice("fill"): return .fill
        case .number(let n) where n >= 0: return .fixed(n)
        default: throw issue(.unsupported, node, "Static \(key) must be nonnegative, .fit or .fill")
        }
    }

    private func number(_ facts: ElementFacts, _ key: String, default fallback: Double, at node: PositionedNode) throws -> Double {
        guard let value = try facet(facts, key, at: node) else { return fallback }
        guard case .number(let n) = value, n >= 0 else { throw issue(.unsupported, node, "Static \(key) must be nonnegative") }
        return n
    }

    private func optionalNumber(_ facts: ElementFacts, _ key: String, at node: PositionedNode) throws -> Double? {
        guard let value = try facet(facts, key, at: node) else { return nil }
        guard case .number(let n) = value, n >= 0 else { throw issue(.unsupported, node, "Static \(key) must be nonnegative") }
        return n
    }

    private func facet(_ facts: ElementFacts, _ key: String, at node: PositionedNode) throws -> Value? {
        guard let best = facts.facets[FacetID(key)]?.first else { return nil }
        let compiler = try facetCompiler(facts, key, at: node)
        if let value = best.fixedValue { return try compiler.fixed(value, at: node) }
        guard let value = compiler.checked.tree.resolve(best.value) else {
            throw issue(.invalidCheckedModel, node, "Facet refers to a different syntax tree")
        }
        if key == "position.x" || key == "position.y" { return try compiler.lengthConstant(value, signed: true) }
        if ["width", "height", "width.min", "width.max", "height.min", "height.max", "padding.left", "padding.right",
            "padding.top", "padding.bottom", "stroke.width", "font.size"].contains(key) { return try compiler.lengthConstant(value) }
        return try compiler.constant(value)
    }

    /// Length properties accept attached pt literals only after checking their dimension and canonical value.
    /// Signed coordinates are a literal spelling, not a constant-folding path for unsupported layout expressions.
    private func lengthConstant(_ node: PositionedNode, signed: Bool = false) throws -> Value {
        if allowsStyleParentheses, let paren = ParenExprSyntax(node) { return try lengthConstant(paren.value.node, signed: signed) }
        if signed, let prefix = PrefixExprSyntax(node), prefix.operator.token.kind == .minus,
           NumberLiteralSyntax(prefix.operand.node) != nil {
            guard case .number(let value) = try lengthConstant(prefix.operand.node),
                  checked.types[checked.tree.id(of: node)]?.type == .length,
                  let canonical = checked.canonicalNumericValues[checked.tree.id(of: node)],
                  canonical.isFinite, canonical == -value else {
                throw issue(.unsupported, node, "Signed position requires a checked finite Length literal")
            }
            return .number(canonical)
        }
        if let literal = NumberLiteralSyntax(node), literal.unit?.text == "pt" {
            let identity = checked.tree.id(of: node)
            guard literal.unit?.status == .known, literal.unitAfterSpace == nil, literal.value?.isFinite == true,
                  checked.types[identity]?.type == .length,
                  let canonical = checked.canonicalNumericValues[identity], canonical.isFinite,
                  let unit = catalog.unit(spelling: "pt"), unit.dimension == .length,
                  unit.factor.isFinite, unit.offset == 0 else {
                throw issue(.unsupported, node, "Point values require a checked finite Length literal")
            }
            return .number(canonical)
        }
        return try constant(node)
    }

    /// Explicit points are a checked Length spelling for box corners, not a general constant/unit extension.
    private func roundedFacet(_ facts: ElementFacts, _ key: String, at node: PositionedNode) throws -> Value? {
        let compiler = try facetCompiler(facts, key, at: node)
        guard let best = facts.facets[FacetID(key)]?.first, best.fixedValue == nil,
              let value = compiler.checked.tree.resolve(best.value), let literal = NumberLiteralSyntax(value),
              literal.unit?.text == "pt" else { return try facet(facts, key, at: node) }
        guard literal.unit?.status == .known, literal.unitAfterSpace == nil,
              literal.value?.isFinite == true,
              compiler.checked.types[best.value]?.type == .length,
              let canonical = compiler.checked.canonicalNumericValues[best.value], canonical.isFinite, canonical >= 0,
              let unit = catalog.unit(spelling: "pt"), unit.dimension == .length,
              unit.factor.isFinite, unit.offset == 0 else {
            throw issue(.unsupported, value, "Point radii require a checked finite nonnegative Length literal")
        }
        return .number(canonical)
    }

    private func constant(_ node: PositionedNode) throws -> Value {
        if allowsStyleParentheses, let paren = ParenExprSyntax(node) { return try constant(paren.value.node) }
        if allowsStyleParentheses, let number = NumberLiteralSyntax(node), number.unit?.text == "pt" { return try lengthConstant(node) }
        if allowsStyleParentheses, let member = MemberExprSyntax(node),
           case .enumCase(let type, let name)? = checked.symbols[checked.tree.id(of: node)],
           IdentifierExprSyntax(member.base.node)?.name == type, member.name.token.text == name { return .choice(name) }
        if let number = NumberLiteralSyntax(node), number.unit == nil, number.unitAfterSpace == nil,
           let value = number.value, value.isFinite { return .number(value) }
        if let string = StringLiteralSyntax(node)?.literalValue { return .string(string) }
        if let boolean = BoolLiteralSyntax(node) { return .boolean(boolean.value) }
        if let choice = ImplicitMemberExprSyntax(node), choice.arguments == nil { return .choice(choice.name.token.text) }
        throw issue(.unsupported, node, "Only literal constants are implemented; expressions/interpolation are not")
    }

    private func fixed(_ source: String, at node: PositionedNode) throws -> Value {
        if let number = Double(source), number.isFinite { return .number(number) }
        if source == "true" { return .boolean(true) }
        if source == "false" { return .boolean(false) }
        if source == #""System""# { return .string("System") }
        if source.first == ".", source.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) { return .choice(String(source.dropFirst())) }
        throw issue(.unsupported, node, "Unsupported catalog constant: \(source)")
    }

    private func defaultNumber(component: String, parameter: String, at node: PositionedNode) throws -> Double {
        guard case .source(let source)? = catalog.component(named: component)?.signatures.first?.param(named: parameter)?.defaultValue,
              case .number(let n) = try fixed(source, at: node), n >= 0 else {
            throw issue(.invalidCheckedModel, node, "No static catalog default for \(component).\(parameter)")
        }
        return n
    }

    private func defaultChoice(component: String, parameter: String, at node: PositionedNode) throws -> String {
        guard case .source(let source)? = catalog.component(named: component)?.signatures.first?.param(named: parameter)?.defaultValue,
              case .choice(let n) = try fixed(source, at: node) else {
            throw issue(.invalidCheckedModel, node, "No static catalog default for \(component).\(parameter)")
        }
        return n
    }

    private func issue(_ kind: DeskCompilationIssue.Kind, _ node: PositionedNode, _ message: String) -> DeskCompilationIssue {
        DeskCompilationIssue(kind: kind, file: checked.tree.file, range: node.textRange, message: message)
    }
}
