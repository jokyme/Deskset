import Foundation

public enum ProgramRuntimeError: Error, Equatable {
    case elementLimit, depthLimit, emptyProgram, duplicateIdentity(ElementID)
    case invalidGeometry(ElementID), invalidText(ElementID), invalidMeasurement(ElementID)
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
        var pending = [(program.root, 1)], count = 0, textCount = 0
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
            switch node.content {
            case .text(let text):
                textCount += 1
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
            case .column(let spacing, _, let children), .row(let spacing, _, let children):
                guard spacing.isFinite, spacing >= 0 else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                guard children.count <= ProgramLimits.maximumElements - count - pending.count else { throw ProgramRuntimeError.elementLimit }
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        guard textCount > 0 else { throw ProgramRuntimeError.emptyProgram }
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
        let box = try layout(program.root, proposedWidth: nil, appearance: appearance,
                             resolve: { try evaluation.text($0) }, measure: measure)
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
        let content: SkinRect
        let style: TextStyle?
        let text: String?
        let children: [(Box, SkinPoint)]
    }

    private func layout(_ node: ProgramElement, proposedWidth: Double?, appearance: SkinAppearance,
                        resolve: (ProgramExpression) throws -> String,
                        measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> Box {
        let p = node.padding
        func sum(_ values: [Double]) throws -> Double {
            let result = values.reduce(0, +)
            guard result.isFinite, result >= 0 else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            return result
        }
        let horizontal = try sum([p.left, p.right]), vertical = try sum([p.top, p.bottom])
        let fixedWidth: Double? = { if case .fixed(let n) = node.width { return n }; return nil }()
        let fixedHeight: Double? = { if case .fixed(let n) = node.height { return n }; return nil }()
        let availableWidth = (fixedWidth ?? proposedWidth).map { max(0, $0 - horizontal) }
        var contentSize: SkinSize, style: TextStyle?, resolvedText: String?, children: [(Box, SkinPoint)] = []
        switch node.content {
        case .text(let text):
            let value = try resolve(text.value)
            resolvedText = value
            func measured(_ style: TextStyle, width: Double?) throws -> SkinSize {
                let result = try measure(value, style, width)
                guard result.width.isFinite, result.height.isFinite, result.width >= 0, result.height >= 0,
                      value.isEmpty || result.height > 0 else { throw ProgramRuntimeError.invalidMeasurement(node.id) }
                return result
            }
            let unwrapped = text.drawingStyle(in: appearance, wrap: false)
            let ideal = try measured(unwrapped, width: nil)
            let wraps = availableWidth.map { $0 < ideal.width } ?? false
            let finalStyle = text.drawingStyle(in: appearance, wrap: wraps)
            let result = wraps ? try measured(finalStyle, width: availableWidth) : ideal
            let width = fixedWidth.map { max(0, $0 - horizontal) } ?? (wraps ? availableWidth! : result.width)
            guard !wraps || result.width <= width else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            contentSize = SkinSize(width: width, height: result.height)
            style = finalStyle
        case .column(let spacing, _, let nodes):
            let boxes = try nodes.map { try layout($0, proposedWidth: availableWidth, appearance: appearance, resolve: resolve, measure: measure) }
            let height = try sum(boxes.map { $0.size.height } + [spacing * Double(max(0, boxes.count - 1))])
            contentSize = SkinSize(width: boxes.map { $0.size.width }.max() ?? 0, height: height)
            children = boxes.map { ($0, SkinPoint()) }
        case .row(let spacing, _, let nodes):
            let boxes = try nodes.map { try layout($0, proposedWidth: nil, appearance: appearance, resolve: resolve, measure: measure) }
            let width = try sum(boxes.map { $0.size.width } + [spacing * Double(max(0, boxes.count - 1))])
            contentSize = SkinSize(width: width, height: boxes.map { $0.size.height }.max() ?? 0)
            children = boxes.map { ($0, SkinPoint()) }
        }
        let neededWidth = try sum([contentSize.width, horizontal]), neededHeight = try sum([contentSize.height, vertical])
        let width = fixedWidth ?? neededWidth, height = fixedHeight ?? neededHeight
        guard width >= neededWidth, height >= neededHeight else { throw ProgramRuntimeError.layoutOverflow(node.id) }
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
            case .text: break
            }
        }
        return Box(node: node, size: SkinSize(width: width, height: height),
                   content: SkinRect(x: p.left, y: p.top, width: innerWidth, height: innerHeight),
                   style: style, text: resolvedText, children: children)
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
        }
        elements.append(SceneElement(id: box.node.id, kind: kind, frame: frame, anchor: point,
                                     visibility: hidden ? .hiddenKeepsSpace : .visible, container: nil, isContainer: false,
                                     items: items, glass: nil, imageDependencies: []))
        for (child, offset) in box.children {
            try append(child, at: SkinPoint(x: point.x + offset.x, y: point.y + offset.y), inheritedHidden: hidden, into: &elements)
        }
    }
}
