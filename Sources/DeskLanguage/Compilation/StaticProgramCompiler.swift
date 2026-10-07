import Foundation
import DesksetCore

struct StaticProgramCompiler {
    let checked: CheckedFile
    let catalog: DeskCatalog
    private var nextIndex = 0
    private var expressions: ProgramExpressionCompiler
    private var onLoad: [ProgramAssignment] = []
    private var clickActionCount = 0
    private var widgetSize = ProgramWidgetSize.fit
    private(set) var elementRefs: [ElementID: ElementRef] = [:]

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
        var sizeExpression: ProgramExpression?
        var weight = 400
        var italic = false
        var design = "standard"
        var color = ProgramColor.text
        var align = HorizontalTextAlign.center
        var digits = ProgramText.Digits.automatic
    }

    mutating func compile() throws -> WidgetProgram {
        var name = URL(fileURLWithPath: checked.tree.file.path).deletingPathExtension().lastPathComponent
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
                        guard case .string(let value) = try constant(field.value.node) else {
                            throw issue(.unsupported, field.value.node, "info.name must be literal text")
                        }
                        name = value
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
        let program = WidgetProgram(name: name, root: root, declarations: declarations, onLoad: onLoad, size: widgetSize)
        do { _ = try ProgramRuntime(program: program) } // Validate the same contract as every other Core producer.
        catch ProgramRuntimeError.expressionLimit { throw issue(.resourceLimit, widget.node, "Shared program expression limit exceeded") }
        catch ProgramRuntimeError.expressionDepth { throw issue(.resourceLimit, widget.node, "Shared program reference depth exceeded") }
        return program
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
        guard ["Text", "Icon", "Column", "Row", "Freeform", "Rectangle", "Circle", "Ellipse", "Capsule", "Image", "Progress", "Gauge", "Spacer"].contains(facts.component) else {
            throw issue(.unsupported, node, "Unsupported component: \(facts.component)")
        }
        guard facts.dropped.isEmpty else { throw issue(.invalidCheckedModel, node, "Dropped element semantics cannot be compiled") }
        let solidShape = ["Rectangle", "Circle", "Ellipse", "Capsule"].contains(facts.component)
        let image = facts.component == "Image"
        let icon = facts.component == "Icon"
        let progress = facts.component == "Progress"
        let gauge = facts.component == "Gauge"
        let rangedMeter = progress || gauge
        let spacer = facts.component == "Spacer"
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
        if !spacer { allowedModifiers.insert("position") }
        var onClick: [ProgramAssignment]?
        var onClickActions: [ProgramAction]?
        var onRightClickActions: [ProgramAction]?
        for modifier in call.modifiers {
            let modifierName = modifier.name.token.text
            if ["background", "rounded"].contains(modifierName) {
                try boxModifierContract(modifier, kind: facts.kind)
            }
            if rangedMeter && ["color", "track"].contains(modifierName) {
                guard checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier(modifierName)),
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
                guard checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier("font")),
                      let font = catalog.modifier(named: "font"), font.inheritable, font.appliesTo.contains(facts.kind),
                      font.facets.contains(FacetID("font.size")),
                      font.signatures.compactMap({ $0.param(named: "size") }).count == 2,
                      font.signatures.compactMap({ $0.param(named: "size") }).allSatisfy({ $0.type == .length && $0.facets == [FacetID("font.size")] }) else {
                    throw issue(.unsupported, modifier.node, "Unsupported checked font-size catalog contract")
                }
            }
            if modifier.name.token.text == "digits" {
                guard checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier("digits")),
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
                      facts.component == "Text" || icon || solidShape || rangedMeter else {
                    throw issue(.unsupported, modifier.node, "Only Text, Icon, Progress, Gauge and basic shape primary/secondary click actions are implemented")
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
        if !spacer { allowedFacets.formUnion(["position.x", "position.y", "position.anchor"]) }
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
                hasOwnFont: call.modifiers.contains { $0.name.token.text == "font" }))
        case "Text":
            guard call.block == nil, let arguments = call.arguments?.arguments, arguments.count == 1 else {
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
            let children = try (call.block?.items ?? []).map { try element($0, inherited: appearance, depth: depth + 1) }
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
        let id = ElementID(name: facts.name ?? "\(facts.component)#\(index)", index: index)
        elementRefs[id] = checked.tree.id(of: node)
        return ProgramElement(id: id,
                              content: content, width: width, height: height, padding: padding, hidden: visibility.hidden,
                              minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight,
                              idealSize: solidShape || rangedMeter ? spec.sizing.idealWhenUnspecified.map { SkinSize(width: $0.width, height: $0.height) } : nil,
                              stroke: stroke, cornerRadius: radius, onClick: onClick, onClickActions: onClickActions,
                              onRightClickActions: onRightClickActions, position: position, background: background,
                              voiceOver: label, hiddenIf: visibility.condition)
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
        let modifiers = call.modifiers.filter { $0.name.token.text == "iconColors" }
        let candidates = facts.facets["iconColors"] ?? []
        let choice: String
        if modifiers.isEmpty && candidates.isEmpty {
            guard let source = catalog.component(named: "Icon")?.defaults["iconColors"],
                  case .choice(let value) = try fixed(source, at: call.node) else {
                throw issue(.invalidCheckedModel, call.node, "The checking catalog has no Icon color mode default")
            }
            choice = value
        } else {
            guard modifiers.count == 1, let modifier = modifiers.first,
                  checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier("iconColors")),
                  candidates.count == 1, let candidate = candidates.first, candidate.fixedValue == nil,
                  candidate.condition == nil, candidate.origin == .own(checked.tree.id(of: modifier.node)),
                  candidate.level == 3, candidate.hard,
                  let arguments = modifier.arguments?.arguments, arguments.count == 1,
                  let argument = arguments.first, argument.label == nil,
                  candidate.value == checked.tree.id(of: argument.value.node),
                  checked.types[candidate.value]?.type == .enumeration("IconColors"),
                  let value = checked.tree.resolve(candidate.value) else {
                throw issue(.invalidCheckedModel, call.node, "Icon colors require a checked own IconColors argument")
            }
            let name: String
            if let implicit = ImplicitMemberExprSyntax(value), implicit.arguments == nil {
                name = implicit.name.token.text
            } else if let member = MemberExprSyntax(value),
                      IdentifierExprSyntax(member.base.node)?.name == "IconColors" {
                name = member.name.token.text
            } else { throw issue(.unsupported, value, "Icon colors require a literal IconColors case") }
            guard checked.symbols[candidate.value] == .enumCase(type: "IconColors", case: name) else {
                throw issue(.invalidCheckedModel, value, "Icon colors have inconsistent checked case identity")
            }
            choice = name
        }
        guard !facts.inherits.contains("iconColors"),
              catalog.enumeration("IconColors")?.enumCase(named: choice) != nil,
              let colors = IconColors(rawValue: choice) else {
            throw issue(.unsupported, call.node, "Unsupported IconColors case or inheritance")
        }
        return colors
    }

    private mutating func voiceOver(_ facts: ElementFacts, call: CallStmtSyntax) throws -> ProgramExpression? {
        let modifiers = call.modifiers.filter { $0.name.token.text == "voiceOver" }
        let candidates = facts.facets["voiceOver"] ?? []
        guard !facts.inherits.contains("voiceOver") else {
            throw issue(.invalidCheckedModel, call.node, "VoiceOver labels cannot inherit")
        }
        if modifiers.isEmpty && candidates.isEmpty { return nil }
        guard modifiers.count == 1, let modifier = modifiers.first,
              checked.symbols[checked.tree.id(of: modifier.node)] == .builtIn(.modifier("voiceOver")),
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
        guard candidates.count == 1, let candidate = candidates.first, candidate.condition == nil,
              candidate.fixedValue == nil, candidate.level == 3, candidate.hard,
              candidate.origin == .own(checked.tree.id(of: modifier.node)),
              candidate.value == checked.tree.id(of: argument.value.node),
              let value = checked.tree.resolve(candidate.value), checked.types[candidate.value] != nil else {
            throw issue(.invalidCheckedModel, modifier.node, "VoiceOver label has no matching checked own display argument")
        }
        return try expressions.text(value)
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
            return .assign(try expressions.assignment(assignment))
        }
        guard let call = CallStmtSyntax(statement), call.callee.path.count == 1,
              let name = call.callee.path.first, name == "copy" || name == "open",
              call.block == nil, call.modifiers.isEmpty,
              let arguments = call.arguments?.arguments, arguments.count == 1,
              arguments[0].label == nil else {
            throw issue(.unsupported, statement, "Only session variable assignments, copy and open are implemented in click events")
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
                    guard let value = checked.tree.resolve(best.value) else {
                        throw issue(.invalidCheckedModel, node, "Font size refers to a different syntax tree")
                    }
                    if NumberLiteralSyntax(value) != nil {
                        try assign(try lengthConstant(value), to: key, appearance: &result, at: value)
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

    /// Own candidates have one global expansion position, even when a call sets several facets.
    /// Checking both the receipt order and the actual source order prevents a forged position choosing a winner.
    private func candidatePositions(_ facts: ElementFacts, call: CallStmtSyntax) throws {
        let all = facts.facets.values.flatMap { $0 }
        guard !all.isEmpty else { return }
        let positions = all.map(\.position)
        guard Set(positions).count == positions.count, Set(positions) == Set(1...positions.count) else {
            throw issue(.invalidCheckedModel, call.node, "Facet expansion positions are not the checked sequence")
        }
        var previous = 0
        for modifier in call.modifiers {
            let identity = checked.tree.id(of: modifier.node)
            let own = all.filter { $0.origin == .own(identity) }.map(\.position)
            if let first = own.min(), let last = own.max() {
                guard first > previous else {
                    throw issue(.invalidCheckedModel, modifier.node, "Facet positions do not follow their own source modifiers")
                }
                previous = last
            }
        }
        guard all.allSatisfy({ candidate in
            guard case .own(let identity) = candidate.origin else { return false }
            return call.modifiers.contains { checked.tree.id(of: $0.node) == identity }
        }) else {
            throw issue(.invalidCheckedModel, call.node, "A supported facet must come from its own modifier")
        }
    }

    private struct OwnCandidate {
        let value: PositionedNode?
        let condition: PositionedNode?
    }

    /// Consume every candidate, including an inactive branch, against the modifier that actually produced it.
    private func ownCandidates(_ facts: ElementFacts, _ key: String, call: CallStmtSyntax) throws -> [OwnCandidate] {
        let modifiers = call.modifiers.filter { $0.name.token.text == key }
        let candidates = facts.facets[FacetID(key)] ?? []
        guard candidates.count == modifiers.count,
              key == "hidden" || candidates.filter({ $0.condition == nil }).count <= 1 else {
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
        var used = Set<NodeID>()
        var result: [OwnCandidate] = []
        for (index, candidate) in candidates.enumerated() {
            guard candidate.level == 3, candidate.hard,
                  index == 0 || candidates[index - 1].sortKey > candidate.sortKey,
                  case .own(let identity) = candidate.origin, used.insert(identity).inserted,
                  let modifier = modifiers.first(where: { checked.tree.id(of: $0.node) == identity }),
                  checked.symbols[identity] == .builtIn(.modifier(key)) else {
                throw issue(.invalidCheckedModel, call.node, "\(key) has an invalid own candidate or precedence receipt")
            }
            let arguments = modifier.arguments?.arguments ?? []
            let condition = arguments.first(where: { $0.label?.name == "if" })?.value.node
            let value = arguments.first(where: { $0.label == nil })?.value.node
            guard arguments.filter({ $0.label?.name == "if" }).count <= 1,
                  arguments.allSatisfy({ $0.label == nil || $0.label?.name == "if" }),
                  arguments.filter({ $0.label == nil }).count == (key == "hidden" ? 0 : 1),
                  candidate.condition == condition.map({ .expr(checked.tree.id(of: $0)) }),
                  condition.map({ checked.types[checked.tree.id(of: $0)]?.type == .bool }) ?? true,
                  candidate.fixedValue == (key == "hidden" ? "true" : nil),
                  candidate.value == checked.tree.id(of: key == "hidden" ? (condition ?? modifier.node) : (value ?? modifier.node)) else {
                throw issue(.invalidCheckedModel, modifier.node, "\(key) does not match its checked value and condition arguments")
            }
            result.append(OwnCandidate(value: value, condition: condition))
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
            values.append((try checkedFacetColor(value), try candidate.condition.map { try expressions.condition($0) }))
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
            let hasArgument = call.modifiers.filter { $0.name.token.text == name }.contains { modifier in
                (modifier.arguments?.arguments ?? []).contains { argument in
                    let parameter = argument.label?.name ?? (name == "background" ? "paint" : "radius")
                    return catalog.modifier(named: name)?.signatures.contains {
                        $0.param(named: parameter)?.facets.contains(FacetID(key)) == true
                    } == true
                }
            }
            guard !hasArgument else { throw issue(.invalidCheckedModel, call.node, "Box argument has no checked facet receipt") }
            return nil
        }
        guard best.fixedValue == nil, case .own(let owner) = best.origin,
              let modifier = call.modifiers.first(where: { checked.tree.id(of: $0.node) == owner && $0.name.token.text == name }),
              let value = checked.tree.resolve(best.value),
              let argument = modifier.arguments?.arguments.first(where: { checked.tree.id(of: $0.value.node) == best.value }),
              let spec = catalog.modifier(named: name) else {
            throw issue(.invalidCheckedModel, call.node, "Box facet does not refer to its checked own modifier argument")
        }
        let parameter = argument.label?.name ?? (name == "background" ? "paint" : "radius")
        guard spec.signatures.contains(where: { $0.param(named: parameter)?.facets.contains(FacetID(key)) == true }) else {
            throw issue(.invalidCheckedModel, value, "Box facet does not match its checked parameter")
        }
        return value
    }

    private func checkedBoxColor(_ node: PositionedNode) throws -> ProgramColor {
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
            guard !call.modifiers.contains(where: { $0.name.token.text == "background" }), facts.facets["background.tint"] == nil else {
                throw issue(.invalidCheckedModel, call.node, "Background has no checked paint argument")
            }
            return nil
        }
        let tint = try boxArgument(facts, "background.tint", modifier: "background", call: call)
        let identity = checked.tree.id(of: paint)
        if let implicit = ImplicitMemberExprSyntax(paint), implicit.arguments != nil {
            throw issue(.unsupported, paint, "Background catalog values cannot take arguments")
        }
        if case .enumCase(type: "Paint", case: let name)? = checked.symbols[identity],
           checked.types[identity]?.type == .paint, catalog.index.namedValues["Paint.\(name)"]?.type == "Paint",
           ImplicitMemberExprSyntax(paint)?.name.token.text == name || MemberExprSyntax(paint)?.name.token.text == name {
            let style: GlassStyle
            switch name {
            case "glass": style = .regular
            case "clearGlass": style = .clear
            default: throw issue(.unsupported, paint, "Unsupported catalog background Paint")
            }
            return .glass(style: style, tint: try tint.map(checkedBoxColor))
        }
        guard tint == nil else { throw issue(.unsupported, paint, "A background tint is implemented only for glass") }
        return .color(try checkedBoxColor(paint))
    }

    private func uniformRadius(_ facts: ElementFacts, call: CallStmtSyntax) throws -> ProgramCornerRadius? {
        let keys = ["rounded.topLeft", "rounded.topRight", "rounded.bottomLeft", "rounded.bottomRight"]
        guard keys.contains(where: { facts.facets[FacetID($0)] != nil }) else {
            guard !call.modifiers.contains(where: { $0.name.token.text == "rounded" }) else {
                throw issue(.invalidCheckedModel, call.node, "Rounded has no checked explicit radius")
            }
            return nil
        }
        var corners: [ProgramCornerRadius] = []
        for key in keys {
            guard let value = try boxArgument(facts, key, modifier: "rounded", call: call) else {
                corners.append(.points(0)); continue
            }
            let identity = checked.tree.id(of: value)
            switch try roundedFacet(facts, key, at: call.node) {
            case .number(let n)? where n >= 0:
                guard checked.types[identity]?.type == .length || checked.types[identity]?.type == .plainNumber,
                      checked.canonicalNumericValues[identity] == n else {
                    throw issue(.unsupported, value, "Rounded requires a checked finite Length literal receipt")
                }
                corners.append(.points(n))
            case .choice("full")?:
                guard checked.types[identity]?.type == .enumeration("RadiusKeyword"),
                      checked.symbols[identity] == .enumCase(type: "RadiusKeyword", case: "full"),
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
        if let value = best.fixedValue { return try fixed(value, at: node) }
        guard let value = checked.tree.resolve(best.value) else { throw issue(.invalidCheckedModel, node, "Facet refers to a different syntax tree") }
        if key == "position.x" || key == "position.y" { return try lengthConstant(value, signed: true) }
        if ["width", "height", "width.min", "width.max", "height.min", "height.max", "padding.left", "padding.right",
            "padding.top", "padding.bottom", "stroke.width", "font.size"].contains(key) { return try lengthConstant(value) }
        return try constant(value)
    }

    /// Length properties accept attached pt literals only after checking their dimension and canonical value.
    /// Signed coordinates are a literal spelling, not a constant-folding path for unsupported layout expressions.
    private func lengthConstant(_ node: PositionedNode, signed: Bool = false) throws -> Value {
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
        guard let best = facts.facets[FacetID(key)]?.first, best.fixedValue == nil,
              let value = checked.tree.resolve(best.value), let literal = NumberLiteralSyntax(value),
              literal.unit?.text == "pt" else { return try facet(facts, key, at: node) }
        guard literal.unit?.status == .known, literal.unitAfterSpace == nil,
              literal.value?.isFinite == true,
              checked.types[best.value]?.type == .length,
              let canonical = checked.canonicalNumericValues[best.value], canonical.isFinite, canonical >= 0,
              let unit = catalog.unit(spelling: "pt"), unit.dimension == .length,
              unit.factor.isFinite, unit.offset == 0 else {
            throw issue(.unsupported, value, "Point radii require a checked finite nonnegative Length literal")
        }
        return .number(canonical)
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
