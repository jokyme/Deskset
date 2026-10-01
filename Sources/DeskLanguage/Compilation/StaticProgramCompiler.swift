import Foundation
import DesksetCore

struct StaticProgramCompiler {
    let checked: CheckedFile
    let catalog: DeskCatalog
    private var nextIndex = 0
    private var expressions: ProgramExpressionCompiler
    private var onLoad: [ProgramAssignment] = []

    init(checked: CheckedFile, catalog: DeskCatalog) {
        self.checked = checked
        self.catalog = catalog
        expressions = ProgramExpressionCompiler(checked: checked, catalog: catalog)
    }

    private enum Value {
        case number(Double), string(String), choice(String), boolean(Bool)
    }

    private struct Appearance {
        var family = "System"
        var size = 13.0
        var weight = 400
        var italic = false
        var design = "standard"
        var color = ProgramColor.text
        var align = HorizontalTextAlign.center
    }

    mutating func compile() throws -> WidgetProgram {
        var name = URL(fileURLWithPath: checked.tree.file.path).deletingPathExtension().lastPathComponent
        var widget: BlockSyntax?
        for item in checked.tree.rootNode.childNodes {
            switch item.kind {
            case .infoBlock:
                guard let block = TopLevelBlockSyntax(item) else { throw issue(.invalidCheckedModel, item, "Missing info block") }
                for node in block.block.items {
                    guard let field = FieldSyntax(node) else { throw issue(.unsupported, node, "Unsupported info statement") }
                    switch field.label.name {
                    case "name":
                        guard case .string(let value) = try constant(field.value.node) else {
                            throw issue(.unsupported, field.value.node, "info.name must be literal text")
                        }
                        name = value
                    case "size":
                        guard case .choice("fit") = try constant(field.value.node) else {
                            throw issue(.unsupported, field.value.node, "Preset windows and their proportional overflow scaling are not implemented")
                        }
                    default: throw issue(.unsupported, node, "Unsupported info field: \(field.label.name)")
                    }
                }
            case .widgetBlock:
                guard widget == nil, let block = TopLevelBlockSyntax(item) else {
                    throw issue(.invalidCheckedModel, item, "Expected one widget block")
                }
                widget = block.block
            default: throw issue(.unsupported, item, "Unsupported top-level construct: \(item.kind.rawValue)")
            }
        }
        guard let widget else { throw issue(.invalidCheckedModel, checked.tree.rootNode, "No checked widget") }
        let declarations = try expressions.declarations(widget.items.compactMap(DeclarationSyntax.init))
        let statements = widget.items.filter { $0.kind != .declaration }
        guard !statements.isEmpty else { throw issue(.unsupported, widget.node, "Widget has no supported element content") }
        let appearance = try defaultAppearance(at: widget.node)
        let root: ProgramElement
        if statements.count == 1 {
            root = try element(statements[0], inherited: appearance, depth: 1)
        } else {
            let index = try reserveIndex(at: widget.node, depth: 1)
            let children = try statements.map { try element($0, inherited: appearance, depth: 2) }
            let spacing = try defaultNumber(component: "Column", parameter: "spacing", at: widget.node)
            let align = try defaultChoice(component: "Column", parameter: "align", at: widget.node)
            root = ProgramElement(id: ElementID(name: "widget", index: index),
                                  content: .column(spacing: spacing, align: try horizontal(align, at: widget.node), children: children))
        }
        let program = WidgetProgram(name: name, root: root, declarations: declarations, onLoad: onLoad)
        do { _ = try ProgramRuntime(program: program) } // Validate the same contract as every other Core producer.
        catch ProgramRuntimeError.expressionLimit { throw issue(.resourceLimit, widget.node, "Shared program expression limit exceeded") }
        catch ProgramRuntimeError.expressionDepth { throw issue(.resourceLimit, widget.node, "Shared program reference depth exceeded") }
        return program
    }

    private mutating func reserveIndex(at node: PositionedNode, depth: Int) throws -> Int {
        guard depth <= min(ProgramLimits.maximumDepth, catalog.limits.maximumBlockNesting) else {
            throw issue(.resourceLimit, node, "Shared program nesting limit exceeded")
        }
        guard nextIndex < min(ProgramLimits.maximumElements, catalog.limits.maximumElementInstances) else {
            throw issue(.resourceLimit, node, "Shared program element limit exceeded")
        }
        let value = nextIndex
        nextIndex += 1
        return value
    }

    private mutating func element(_ node: PositionedNode, inherited: Appearance, depth: Int) throws -> ProgramElement {
        guard let call = CallStmtSyntax(node), call.callee.path.count == 1,
              let facts = checked.elements[checked.tree.id(of: node)], facts.component == call.callee.path[0],
              let spec = catalog.component(named: facts.component), spec.kind == facts.kind else {
            throw issue(.unsupported, node, "Expected a checked, built-in element")
        }
        guard ["Text", "Column", "Row"].contains(facts.component) else {
            throw issue(.unsupported, node, "Unsupported component: \(facts.component)")
        }
        guard facts.dropped.isEmpty else { throw issue(.invalidCheckedModel, node, "Dropped element semantics cannot be compiled") }
        let allowedModifiers: Set<String> = ["width", "height", "size", "padding", "font", "bold", "italic", "color", "align", "name", "hidden", "digits"]
        for modifier in call.modifiers {
            if modifier.name.token.text == "onLoad" {
                try rootOnLoad(modifier, element: node)
                continue
            }
            guard allowedModifiers.contains(modifier.name.token.text), modifier.block == nil else {
                throw issue(.unsupported, modifier.node, "Unsupported modifier: \(modifier.name.token.text)")
            }
        }
        let allowedFacets: Set<String> = ["width", "height", "padding.left", "padding.right", "padding.top", "padding.bottom",
                                         "font.family", "font.size", "font.weight", "font.design", "font.italic", "digits",
                                         "color", "align", "hidden", "name"]
        for (facet, candidates) in facts.facets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard allowedFacets.contains(facet.rawValue) else {
                throw issue(.unsupported, node, "Unsupported effective facet: \(facet.rawValue)")
            }
            guard candidates.allSatisfy({ $0.condition == nil }) else {
                throw issue(.unsupported, node, "Conditional facet is not implemented: \(facet.rawValue)")
            }
        }
        let index = try reserveIndex(at: node, depth: depth)
        let appearance = try resolvedAppearance(facts, inherited: inherited, at: node)
        let width = try length(facts, "width", at: node), height = try length(facts, "height", at: node)
        let padding = try SkinInsets(left: number(facts, "padding.left", default: 0, at: node),
                                     top: number(facts, "padding.top", default: 0, at: node),
                                     right: number(facts, "padding.right", default: 0, at: node),
                                     bottom: number(facts, "padding.bottom", default: 0, at: node))
        let hidden: Bool
        if let value = try facet(facts, "hidden", at: node) {
            guard case .boolean(let n) = value else { throw issue(.unsupported, node, "Hidden requires a constant boolean") }
            hidden = n
        } else { hidden = false }
        let content: ProgramElement.Content
        switch facts.component {
        case "Text":
            guard call.block == nil, let arguments = call.arguments?.arguments, arguments.count == 1 else {
                throw issue(.unsupported, node, "Text requires one String expression")
            }
            let text = try expressions.text(arguments[0].value.node)
            let family: String
            switch appearance.design {
            case "standard": family = appearance.family
            case "rounded" where appearance.family == "System": family = "System Rounded"
            case "mono" where appearance.family == "System": family = "System Mono"
            case "serif" where appearance.family == "System": family = "System Serif"
            default: throw issue(.unsupported, node, "Unsupported font design/family combination")
            }
            content = .text(ProgramText(value: text, fontFamily: family, fontSize: appearance.size,
                                        fontWeight: appearance.weight, italic: appearance.italic,
                                        color: appearance.color, align: appearance.align))
        default:
            let arguments = call.arguments?.arguments ?? []
            guard arguments.allSatisfy({ ["spacing", "align"].contains($0.label?.name ?? "") }) else {
                throw issue(.unsupported, node, "Unsupported stack argument")
            }
            let spacingNode = arguments.first { $0.label?.name == "spacing" }?.value.node
            let spacing: Double
            if let value = spacingNode {
                guard case .number(let n) = try constant(value), n >= 0 else { throw issue(.unsupported, value, "Static spacing must be nonnegative") }
                spacing = n
            } else { spacing = try defaultNumber(component: facts.component, parameter: "spacing", at: node) }
            let alignNode = arguments.first { $0.label?.name == "align" }?.value.node
            let align: String
            if let value = alignNode {
                guard case .choice(let n) = try constant(value) else { throw issue(.unsupported, value, "Stack alignment must be constant") }
                align = n
            } else { align = try defaultChoice(component: facts.component, parameter: "align", at: node) }
            let children = try (call.block?.items ?? []).map { try element($0, inherited: appearance, depth: depth + 1) }
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
        return ProgramElement(id: ElementID(name: facts.name ?? "\(facts.component)#\(index)", index: index),
                              content: content, width: width, height: height, padding: padding, hidden: hidden)
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
        guard onLoad.count <= limit, block.items.count <= limit - onLoad.count else {
            throw issue(.resourceLimit, block.node, "Shared program assignment limit exceeded")
        }
        for statement in block.items {
            guard let assignment = AssignmentSyntax(statement) else {
                throw issue(.unsupported, statement, "Only session variable assignments are implemented in root onLoad")
            }
            onLoad.append(try expressions.assignment(assignment))
        }
    }

    private func resolvedAppearance(_ facts: ElementFacts, inherited: Appearance, at node: PositionedNode) throws -> Appearance {
        var result = try defaultAppearance(at: node)
        for key in ["font.family", "font.size", "font.weight", "font.italic", "font.design", "color", "align"] {
            let value = try facet(facts, key, at: node)
            if value == nil, facts.inherits.contains(FacetID(key)) {
                switch key {
                case "font.family": result.family = inherited.family
                case "font.size": result.size = inherited.size
                case "font.weight": result.weight = inherited.weight
                case "font.italic": result.italic = inherited.italic
                case "font.design": result.design = inherited.design
                case "color": result.color = inherited.color
                case "align": result.align = inherited.align
                default: break
                }
            } else if let value {
                try assign(value, to: key, appearance: &result, at: node)
            }
        }
        if let digits = try facet(facts, "digits", at: node) {
            guard case .choice("normal") = digits else { throw issue(.unsupported, node, "Equal-width digits are not implemented") }
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

    private func assign(_ value: Value, to key: String, appearance: inout Appearance, at node: PositionedNode) throws {
        switch (key, value) {
        case ("font.family", .string(let n)): appearance.family = n
        case ("font.size", .number(let n)) where n > 0: appearance.size = n
        case ("font.weight", .choice(let n)):
            let weights = ["ultralight": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500,
                           "semibold": 600, "bold": 700, "heavy": 800, "black": 900]
            guard let value = weights[n] else { throw issue(.unsupported, node, "Unsupported font weight") }
            appearance.weight = value
        case ("font.italic", .boolean(let n)): appearance.italic = n
        case ("font.design", .choice(let n)): appearance.design = n
        case ("align", .choice(let n)): appearance.align = try horizontal(n, at: node)
        case ("color", .choice(let n)):
            switch n {
            case "text": appearance.color = .text
            case "dim": appearance.color = .dim
            case "faint": appearance.color = .faint
            case "accent": appearance.color = .accent
            case "separator": appearance.color = .separator
            case "black": appearance.color = .literal(.black)
            case "white": appearance.color = .literal(.white)
            case "clear": appearance.color = .literal(.clear)
            default: throw issue(.unsupported, node, "System palette color \(n) requires a platform color provider")
            }
        case ("color", .string(let hex)):
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
            appearance.color = .literal(rgba)
        default: throw issue(.unsupported, node, "Unsupported constant for facet \(key)")
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

    private func length(_ facts: ElementFacts, _ key: String, at node: PositionedNode) throws -> ProgramLength {
        guard let value = try facet(facts, key, at: node) else { return .fit }
        switch value {
        case .choice("fit"): return .fit
        case .number(let n) where n >= 0: return .fixed(n)
        default: throw issue(.unsupported, node, "Static \(key) must be nonnegative or .fit; .fill/min/max are not implemented")
        }
    }

    private func number(_ facts: ElementFacts, _ key: String, default fallback: Double, at node: PositionedNode) throws -> Double {
        guard let value = try facet(facts, key, at: node) else { return fallback }
        guard case .number(let n) = value, n >= 0 else { throw issue(.unsupported, node, "Static \(key) must be nonnegative") }
        return n
    }

    private func facet(_ facts: ElementFacts, _ key: String, at node: PositionedNode) throws -> Value? {
        guard let best = facts.facets[FacetID(key)]?.first else { return nil }
        if let value = best.fixedValue { return try fixed(value, at: node) }
        guard let value = checked.tree.resolve(best.value) else { throw issue(.invalidCheckedModel, node, "Facet refers to a different syntax tree") }
        return try constant(value)
    }

    private func constant(_ node: PositionedNode) throws -> Value {
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
