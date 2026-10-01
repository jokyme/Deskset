import Foundation

public enum ProgramRuntimeError: Error, Equatable {
    case elementLimit, depthLimit, emptyProgram, duplicateIdentity(ElementID)
    case invalidGeometry(ElementID), invalidText(ElementID), invalidMeasurement(ElementID)
    case invalidPaint(ElementID)
    case layoutOverflow(ElementID), invalidEnvironment, generationOverflow
    case expressionLimit, expressionDepth, invalidExpression
    case invalidDeclaration(Int), cyclicDeclaration(Int), uninitializedDeclaration(Int)
    case invalidAssignment(Int)
}

/// The executable part of the shared runtime. It owns a program value, session variables and scene generations,
/// not a Skin, host, timer or service. A failed measurement/layout never publishes a partial scene.
public struct ProgramRuntime: Sendable {
    public let program: WidgetProgram
    public private(set) var generation: UInt64 = 0
    private var variables: [ProgramScalar?]?

    public init(program: WidgetProgram) throws {
        var expressions = try ProgramExpressionValidation(declarations: program.declarations)
        guard program.onLoad.count <= ProgramLimits.maximumExpressions else { throw ProgramRuntimeError.expressionLimit }
        for assignment in program.onLoad { try expressions.validateAssignment(assignment) }
        var pending = [(program.root, 1)], count = 0, contentCount = 0
        var identities = Set<ElementID>()
        while let (node, depth) = pending.popLast() {
            count += 1
            guard count <= ProgramLimits.maximumElements else { throw ProgramRuntimeError.elementLimit }
            guard depth <= ProgramLimits.maximumDepth else { throw ProgramRuntimeError.depthLimit }
            guard identities.insert(node.id).inserted else { throw ProgramRuntimeError.duplicateIdentity(node.id) }
            func valid(_ length: ProgramLength) -> Bool {
                if case .fixed(let n) = length { return n.isFinite && n >= 0 }
                return true
            }
            let p = node.padding
            guard valid(node.width), valid(node.height), [p.left, p.right, p.top, p.bottom].allSatisfy({ $0.isFinite && $0 >= 0 })
            else { throw ProgramRuntimeError.invalidGeometry(node.id) }
            guard [node.minWidth, node.minHeight].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  node.maxWidth.map({ $0.isFinite && $0 >= node.minWidth }) ?? true,
                  node.maxHeight.map({ $0.isFinite && $0 >= node.minHeight }) ?? true,
                  node.idealSize.map({ $0.width.isFinite && $0.height.isFinite && $0.width >= 0 && $0.height >= 0 }) ?? true else {
                throw ProgramRuntimeError.invalidGeometry(node.id)
            }
            switch node.content {
            case .text(let text):
                guard node.idealSize == nil else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                contentCount += 1
                if case .string(let literal) = text.value, literal.utf16.count > ProgramLimits.maximumTextLength {
                    throw ProgramRuntimeError.invalidText(node.id)
                }
                try expressions.validateText(text.value)
                guard !text.fontFamily.isEmpty,
                      text.fontSize.isFinite, text.fontSize > 0,
                      text.fontWeight.map({ (1...999).contains($0) }) ?? true else {
                    throw ProgramRuntimeError.invalidText(node.id)
                }
                if case .literal(let color) = text.color, !Self.valid(color) { throw ProgramRuntimeError.invalidText(node.id) }
            case .rectangle(let fill):
                contentCount += 1
                if node.idealSize == nil {
                    guard case .fixed = node.width, case .fixed = node.height else {
                        throw ProgramRuntimeError.invalidGeometry(node.id)
                    }
                }
                if case .literal(let color) = fill, !Self.valid(color) { throw ProgramRuntimeError.invalidPaint(node.id) }
            case .column(let spacing, _, let children), .row(let spacing, _, let children):
                guard node.idealSize == nil else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                guard spacing.isFinite, spacing >= 0 else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                guard children.count <= ProgramLimits.maximumElements - count - pending.count else { throw ProgramRuntimeError.elementLimit }
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        guard contentCount > 0 else { throw ProgramRuntimeError.emptyProgram }
        self.program = program
    }

    /// The closure must measure the supplied style exactly as it draws it, under the optional wrapping width.
    /// It is used synchronously and is not retained. Graphics/font resources stay outside Core.
    public mutating func project(environment: EnvironmentStamp,
                                 measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> WidgetScene {
        let appearance = environment.appearance.value
        guard environment.scale.isFinite, environment.scale > 0,
              [appearance.labelColor, appearance.secondaryLabelColor, appearance.tertiaryLabelColor,
               appearance.accentColor, appearance.separatorColor].allSatisfy(Self.valid) else {
            throw ProgramRuntimeError.invalidEnvironment
        }
        let next = generation.addingReportingOverflow(1)
        guard !next.overflow else { throw ProgramRuntimeError.generationOverflow }
        var evaluation = ProgramExpressionEvaluation(declarations: program.declarations, dark: appearance.isDark, variables: variables)
        if variables == nil {
            try evaluation.initialize()
            // Root startup is part of the first successful scene transaction. These local-only assignments
            // may be retried after failed measurement/layout; no external action is admitted here.
            for assignment in program.onLoad { try ActionExecutor.perform(assignment, on: &evaluation) }
        }
        var layoutState = LayoutState()
        _ = flexibility(program.root, into: &layoutState)
        let box = try layout(program.root, proposedWidth: nil, proposedHeight: nil, appearance: appearance,
                             resolve: { try evaluation.text($0) }, measure: measure, state: &layoutState)
        var elements: [SceneElement] = []
        try append(box, at: SkinPoint(), inheritedHidden: false, into: &elements)
        var hitMap = SkinHitMap()
        hitMap.width = box.size.width
        hitMap.height = box.size.height
        let scene = WidgetScene(generation: next.partialValue, size: box.size, background: [],
                                backgroundImageDependencies: [], glass: [], elements: elements,
                                hitMap: hitMap, environment: environment)
        generation = next.partialValue
        variables = evaluation.variables
        return scene
    }

    private static func valid(_ color: RGBA) -> Bool {
        [color.r, color.g, color.b, color.a].allSatisfy { $0.isFinite && (0...255).contains($0) }
    }

    private struct Box {
        let node: ProgramElement
        let size: SkinSize
        let minimum: SkinSize
        let content: SkinRect
        let style: TextStyle?
        let text: String?
        let fill: RGBA?
        let children: [(Box, SkinPoint)]
    }

    private struct Flexibility { let width: Bool; let height: Bool }
    private struct ProposalKey: Hashable { let id: ElementID; let width: Double?; let height: Double? }
    private struct TextKey: Hashable { let id: ElementID; let width: Double? }
    private struct TextInput { let value: String; let style: TextStyle }
    /// Only this projection's pure results. Repeating a proposal uses the same measured style/size;
    /// no font or graphics resource, closure, cache or partial scene survives publication or failure.
    private struct LayoutState {
        var flex: [ElementID: Flexibility] = [:]
        var boxes: [ProposalKey: Box] = [:]
        var text: [ElementID: TextInput] = [:]
        var measures: [TextKey: SkinSize] = [:]
    }

    private func flexibility(_ node: ProgramElement, into state: inout LayoutState) -> Flexibility {
        let children: [ProgramElement]
        switch node.content {
        case .column(_, _, let nodes), .row(_, _, let nodes): children = nodes
        case .text, .rectangle: children = []
        }
        let descendants = children.map { flexibility($0, into: &state) }
        let value = Flexibility(width: node.width == .fill || (node.width == .fit && descendants.contains { $0.width }),
                                height: node.height == .fill || (node.height == .fit && descendants.contains { $0.height }))
        state.flex[node.id] = value
        return value
    }

    private func layout(_ node: ProgramElement, proposedWidth: Double?, proposedHeight: Double?, appearance: SkinAppearance,
                        resolve: (ProgramExpression) throws -> String,
                        measure: (String, TextStyle, Double?) throws -> SkinSize, state: inout LayoutState) throws -> Box {
        let key = ProposalKey(id: node.id, width: proposedWidth, height: proposedHeight)
        if let old = state.boxes[key] { return old }
        guard let flexible = state.flex[node.id] else { throw ProgramRuntimeError.invalidGeometry(node.id) }
        let p = node.padding
        func sum(_ values: [Double]) throws -> Double {
            let value = values.reduce(0, +)
            guard value.isFinite, value >= 0 else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            return value
        }
        func clamp(_ value: Double, minimum: Double, maximum: Double?) -> Double {
            max(minimum, min(value, maximum ?? value))
        }
        func requested(_ length: ProgramLength, proposal: Double?, flex: Bool, minimum: Double, maximum: Double?) -> Double? {
            switch length {
            case .fixed(let value): return clamp(value, minimum: minimum, maximum: maximum)
            case .fill: return proposal.map { clamp($0, minimum: minimum, maximum: maximum) }
            case .fit: return flex ? proposal.map { clamp($0, minimum: minimum, maximum: maximum) } : nil
            }
        }
        let horizontal = try sum([p.left, p.right]), vertical = try sum([p.top, p.bottom])
        let requestedWidth = requested(node.width, proposal: proposedWidth, flex: flexible.width, minimum: node.minWidth, maximum: node.maxWidth)
        let requestedHeight = requested(node.height, proposal: proposedHeight, flex: flexible.height, minimum: node.minHeight, maximum: node.maxHeight)
        let offeredWidth = requestedWidth ?? proposedWidth.map { clamp($0, minimum: node.minWidth, maximum: node.maxWidth) } ?? node.maxWidth
        let offeredHeight = requestedHeight ?? proposedHeight.map { clamp($0, minimum: node.minHeight, maximum: node.maxHeight) } ?? node.maxHeight
        var width: Double, height: Double, style: TextStyle?, resolvedText: String?, fill: RGBA?
        var children: [(Box, SkinPoint)] = []
        var minimumContent = SkinSize()
        switch node.content {
        case .text(let text):
            let input: TextInput
            if let old = state.text[node.id] { input = old }
            else {
                input = TextInput(value: try resolve(text.value), style: text.drawingStyle(in: appearance, wrap: false))
                state.text[node.id] = input
            }
            resolvedText = input.value
            func measured(_ drawingStyle: TextStyle, width: Double?) throws -> SkinSize {
                let key = TextKey(id: node.id, width: width)
                if let old = state.measures[key] { return old }
                let result = try measure(input.value, drawingStyle, width)
                guard result.width.isFinite, result.height.isFinite, result.width >= 0, result.height >= 0,
                      input.value.isEmpty || result.height > 0 else { throw ProgramRuntimeError.invalidMeasurement(node.id) }
                state.measures[key] = result
                return result
            }
            let ideal = try measured(input.style, width: nil)
            let naturalWidth = try sum([ideal.width, horizontal])
            let fittedWidth = min(naturalWidth, offeredWidth ?? naturalWidth)
            width = requestedWidth ?? clamp(fittedWidth, minimum: node.minWidth, maximum: node.maxWidth)
            guard width >= horizontal else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            let innerWidth = width - horizontal
            let wraps = innerWidth < ideal.width
            let finalStyle = text.drawingStyle(in: appearance, wrap: wraps)
            let actual = wraps ? try measured(finalStyle, width: innerWidth) : ideal
            guard actual.width <= innerWidth else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            let naturalHeight = try sum([actual.height, vertical])
            height = requestedHeight ?? clamp(naturalHeight, minimum: node.minHeight, maximum: node.maxHeight)
            guard height >= naturalHeight else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            style = finalStyle
            minimumContent = SkinSize(width: actual.width, height: actual.height)
        case .rectangle(let color):
            let ideal = node.idealSize ?? SkinSize()
            width = try requestedWidth ?? clamp(sum([ideal.width, horizontal]), minimum: node.minWidth, maximum: node.maxWidth)
            height = try requestedHeight ?? clamp(sum([ideal.height, vertical]), minimum: node.minHeight, maximum: node.maxHeight)
            fill = color.resolved(in: appearance)
            minimumContent = SkinSize(width: max(0, width - horizontal), height: max(0, height - vertical))
        case .column(let spacing, _, let nodes), .row(let spacing, _, let nodes):
            let column: Bool
            if case .column = node.content { column = true } else { column = false }
            let gap = try sum([spacing * Double(max(0, nodes.count - 1))])
            let crossPadding = column ? horizontal : vertical
            let mainPadding = column ? vertical : horizontal
            let offeredCross = column ? offeredWidth : offeredHeight
            let initialCross = offeredCross.map { max(0, $0 - crossPadding) }
            var boxes = try nodes.map {
                try layout($0, proposedWidth: column ? initialCross : nil, proposedHeight: column ? nil : initialCross,
                           appearance: appearance, resolve: resolve, measure: measure, state: &state)
            }
            func main(_ size: SkinSize) -> Double { column ? size.height : size.width }
            func cross(_ size: SkinSize) -> Double { column ? size.width : size.height }
            let naturalCross = try sum([boxes.map { cross($0.size) }.max() ?? 0, crossPadding])
            let crossMinimum = column ? node.minWidth : node.minHeight
            let crossMaximum = column ? node.maxWidth : node.maxHeight
            let requestedCross = column ? requestedWidth : requestedHeight
            var crossSize = requestedCross ?? clamp(naturalCross, minimum: crossMinimum, maximum: crossMaximum)
            guard crossSize >= crossPadding else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            var finalCross = crossSize - crossPadding
            // The final cross size can be discovered from an ideal sibling. Reflow every child with this
            // proposal, including nested fit containers; identical proposals reuse their earlier pure result.
            if initialCross != finalCross {
                boxes = try nodes.map {
                    try layout($0, proposedWidth: column ? finalCross : nil, proposedHeight: column ? nil : finalCross,
                               appearance: appearance, resolve: resolve, measure: measure, state: &state)
                }
            }
            let naturalMain = try sum(boxes.map { main($0.size) } + [gap, mainPadding])
            let mainMinimum = column ? node.minHeight : node.minWidth
            let mainMaximum = column ? node.maxHeight : node.maxWidth
            let requestedMain = column ? requestedHeight : requestedWidth
            let mainSize = requestedMain ?? clamp(naturalMain, minimum: mainMinimum, maximum: mainMaximum)
            guard mainSize >= mainPadding else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            let innerMain = mainSize - mainPadding
            let childFlex = try nodes.map { child -> Flexibility in
                guard let value = state.flex[child.id] else { throw ProgramRuntimeError.invalidGeometry(child.id) }
                return value
            }
            let isFlexible = childFlex.map { column ? $0.height : $0.width }
            var proposedMain = Array<Double?>(repeating: nil, count: nodes.count)
            if requestedMain != nil || mainSize != naturalMain {
                let rigid = try sum(boxes.indices.filter { !isFlexible[$0] }.map { main(boxes[$0].size) } + [gap])
                guard innerMain >= rigid else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                let indices = boxes.indices.filter { isFlexible[$0] }
                var allocated = indices.map { main(boxes[$0].minimum) }
                let budget = innerMain - rigid
                let minimum = try sum(allocated)
                guard budget >= minimum else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                // Match both the final ordered size check and the actual placement accumulation. A
                // rounded flexible sub-budget can still exceed the parent after rigid siblings are restored.
                func allocationExcess(_ values: [Double]) throws -> Double {
                    var lengths = boxes.map { main($0.size) }
                    for offset in indices.indices { lengths[indices[offset]] = values[offset] }
                    let grouped = try sum(lengths + [gap])
                    var positioned = 0.0
                    for i in lengths.indices {
                        positioned = try sum([positioned, lengths[i], i + 1 < lengths.count ? spacing : 0])
                    }
                    return max(0, max(try sum(values) - budget, max(grouped - innerMain, positioned - innerMain)))
                }
                guard try allocationExcess(allocated) == 0 else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                var remaining = budget - minimum
                var open = allocated.indices.filter { offset in
                    let limit = column ? nodes[indices[offset]].maxHeight : nodes[indices[offset]].maxWidth
                    return limit.map { allocated[offset] < $0 } ?? true
                }
                while remaining > 0 && !open.isEmpty {
                    let share = remaining / Double(open.count)
                    var candidate = allocated
                    for offset in open {
                        let limit = column ? nodes[indices[offset]].maxHeight : nodes[indices[offset]].maxWidth
                        candidate[offset] = min(try sum([allocated[offset], share]), limit ?? Double.greatestFiniteMagnitude)
                    }
                    var excess = try allocationExcess(candidate)
                    // Individually rounded shares may exceed the budget by a representable step. Reduce
                    // only this round's additions, in stable reverse order, never the validated minima.
                    for offset in open.reversed() {
                        while excess > 0 && candidate[offset] > allocated[offset] {
                            let reduced = max(allocated[offset], candidate[offset] - excess)
                            candidate[offset] = reduced < candidate[offset] ? reduced : max(allocated[offset], candidate[offset].nextDown)
                            excess = try allocationExcess(candidate)
                        }
                    }
                    guard excess == 0 else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                    if candidate == allocated { break } // No remaining increment fits the exact representable budget.
                    allocated = candidate
                    remaining = budget - (try sum(allocated))
                    open = open.filter { offset in
                        let limit = column ? nodes[indices[offset]].maxHeight : nodes[indices[offset]].maxWidth
                        return limit.map { allocated[offset] < $0 } ?? true
                    }
                }
                for offset in indices.indices {
                    let index = indices[offset]
                    proposedMain[index] = allocated[offset]
                    boxes[index] = try layout(nodes[index], proposedWidth: column ? finalCross : allocated[offset],
                                              proposedHeight: column ? allocated[offset] : finalCross,
                                              appearance: appearance, resolve: resolve, measure: measure, state: &state)
                }
            }
            // A Row's assigned widths can wrap text and increase its fit height. Keep those assignments
            // while propagating the actual final cross size, rather than clipping to the unwrapped ideal.
            if requestedCross == nil {
                let actualCross = try sum([boxes.map { cross($0.size) }.max() ?? 0, crossPadding])
                let fittedCross = clamp(actualCross, minimum: crossMinimum, maximum: crossMaximum)
                if fittedCross != crossSize {
                    crossSize = fittedCross
                    guard crossSize >= crossPadding else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                    finalCross = crossSize - crossPadding
                    boxes = try nodes.indices.map { index in
                        try layout(nodes[index], proposedWidth: column ? finalCross : proposedMain[index],
                                   proposedHeight: column ? proposedMain[index] : finalCross,
                                   appearance: appearance, resolve: resolve, measure: measure, state: &state)
                    }
                }
            }
            let minimumMain = try sum(boxes.indices.map { isFlexible[$0] ? main(boxes[$0].minimum) : main(boxes[$0].size) } + [gap])
            let minimumCross = boxes.indices.map { index in
                (column ? childFlex[index].width : childFlex[index].height) ? cross(boxes[index].minimum) : cross(boxes[index].size)
            }.max() ?? 0
            guard try sum(boxes.map { main($0.size) } + [gap]) <= innerMain,
                  boxes.allSatisfy({ cross($0.size) <= finalCross }) else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            width = column ? crossSize : mainSize
            height = column ? mainSize : crossSize
            minimumContent = column ? SkinSize(width: minimumCross, height: minimumMain) : SkinSize(width: minimumMain, height: minimumCross)
            children = boxes.map { ($0, SkinPoint()) }
        }
        guard width.isFinite, height.isFinite, width >= horizontal, height >= vertical else {
            throw ProgramRuntimeError.layoutOverflow(node.id)
        }
        func minimum(_ length: ProgramLength, flexible: Bool, actual: Double, content: Double,
                     padding: Double, lower: Double, upper: Double?) throws -> Double {
            switch length {
            case .fixed: return actual
            case .fill: return max(lower, padding)
            case .fit:
                if !flexible { return actual }
                let value = max(lower, try sum([content, padding]))
                guard upper.map({ value <= $0 }) ?? true else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                return value
            }
        }
        let minimumSize = try SkinSize(width: minimum(node.width, flexible: flexible.width, actual: width, content: minimumContent.width,
                                                     padding: horizontal, lower: node.minWidth, upper: node.maxWidth),
                                       height: minimum(node.height, flexible: flexible.height, actual: height, content: minimumContent.height,
                                                       padding: vertical, lower: node.minHeight, upper: node.maxHeight))
        let innerWidth = width - horizontal, innerHeight = height - vertical
        var offset = 0.0
        for i in children.indices {
            let child = children[i].0
            switch node.content {
            case .column(let spacing, let align, _):
                let x: Double
                switch align { case .left: x = 0; case .center: x = (innerWidth - child.size.width) / 2; case .right: x = innerWidth - child.size.width }
                children[i].1 = SkinPoint(x: p.left + x, y: p.top + offset)
                offset = try sum([offset, child.size.height, i + 1 < children.count ? spacing : 0])
            case .row(let spacing, let align, _):
                let y: Double
                switch align { case .top: y = 0; case .center: y = (innerHeight - child.size.height) / 2; case .bottom: y = innerHeight - child.size.height }
                children[i].1 = SkinPoint(x: p.left + offset, y: p.top + y)
                offset = try sum([offset, child.size.width, i + 1 < children.count ? spacing : 0])
            case .text, .rectangle: break
            }
        }
        let box = Box(node: node, size: SkinSize(width: width, height: height), minimum: minimumSize,
                      content: SkinRect(x: p.left, y: p.top, width: innerWidth, height: innerHeight),
                      style: style, text: resolvedText, fill: fill, children: children)
        state.boxes[key] = box
        return box
    }

    private func append(_ box: Box, at point: SkinPoint, inheritedHidden: Bool, into elements: inout [SceneElement]) throws {
        let hidden = inheritedHidden || box.node.hidden
        let frame = SkinRect(x: point.x, y: point.y, width: box.size.width, height: box.size.height)
        guard [frame.x, frame.y, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
            throw ProgramRuntimeError.layoutOverflow(box.node.id)
        }
        var items: [DrawItem] = []
        let kind: ElementKind
        switch box.node.content {
        case .text:
            kind = .string
            guard let style = box.style, let text = box.text else { throw ProgramRuntimeError.invalidText(box.node.id) }
            if !hidden {
                let content = SkinRect(x: point.x + box.content.x, y: point.y + box.content.y,
                                       width: box.content.width, height: box.content.height)
                guard [content.x, content.y, content.width, content.height, content.maxX, content.maxY].allSatisfy(\.isFinite) else {
                    throw ProgramRuntimeError.layoutOverflow(box.node.id)
                }
                items = [.text(TextDraw(text: text, style: style, frame: frame, contentFrame: content, anchor: point))]
            }
        case .column: kind = .unknown("Column")
        case .row: kind = .unknown("Row")
        case .rectangle:
            kind = .shape
            guard let fill = box.fill else { throw ProgramRuntimeError.invalidPaint(box.node.id) }
            if !hidden {
                let content = SkinRect(x: point.x + box.content.x, y: point.y + box.content.y,
                                       width: box.content.width, height: box.content.height)
                guard [content.x, content.y, content.width, content.height, content.maxX, content.maxY].allSatisfy(\.isFinite) else {
                    throw ProgramRuntimeError.layoutOverflow(box.node.id)
                }
                if content.width > 0, content.height > 0 { items = [.fill(content, Paint(color: fill))] }
            }
        }
        elements.append(SceneElement(id: box.node.id, kind: kind, frame: frame, anchor: point,
                                     visibility: hidden ? .hiddenKeepsSpace : .visible, container: nil, isContainer: false,
                                     items: items, glass: nil, imageDependencies: []))
        for (child, offset) in box.children {
            try append(child, at: SkinPoint(x: point.x + offset.x, y: point.y + offset.y), inheritedHidden: hidden, into: &elements)
        }
    }
}
