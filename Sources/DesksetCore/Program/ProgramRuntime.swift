import Foundation

public enum ProgramRuntimeError: Error, Equatable {
    case elementLimit, depthLimit, emptyProgram, duplicateIdentity(ElementID)
    case invalidGeometry(ElementID), invalidText(ElementID), invalidMeasurement(ElementID)
    case invalidPaint(ElementID), invalidImage(ElementID)
    case layoutOverflow(ElementID), invalidEnvironment, generationOverflow
    case expressionLimit, expressionDepth, invalidExpression
    case invalidDeclaration(Int), cyclicDeclaration(Int), uninitializedDeclaration(Int)
    case invalidAssignment(Int)
    case ambiguousClickHandler(ElementID), unhandledClickEffects, missingActionString
    case invalidDateInput
    case invalidColorInput, missingColorInput(ProgramPaletteColor)
}

/// The executable part of the shared runtime. It owns a program value, session variables and scene generations,
/// not a Skin, host, timer or service. A failed measurement/layout never publishes a partial scene.
public struct ProgramRuntime: Sendable {
    public let program: WidgetProgram
    public private(set) var generation: UInt64 = 0
    public private(set) var clockPrecision: ProgramClockPrecision?
    private var variables: [ProgramScalar?]?
    private struct ClickHandler: Sendable {
        let actions: [MouseEventKind: [ProgramAction]]
        let radius: ProgramCornerRadius?
    }
    private let clickHandlers: [ElementID: ClickHandler]
    private var currentHitMap = SkinHitMap()

    public init(program: WidgetProgram) throws {
        if case .preset(_, let size) = program.size {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw ProgramRuntimeError.invalidGeometry(program.root.id)
            }
        }
        var expressions = try ProgramExpressionValidation(declarations: program.declarations)
        guard program.onLoad.count <= ProgramLimits.maximumExpressions else { throw ProgramRuntimeError.expressionLimit }
        for assignment in program.onLoad { try expressions.validateAssignment(assignment) }
        var actionCount = program.onLoad.count
        var clickHandlers: [ElementID: ClickHandler] = [:]
        var pending = [(program.root, 1, false)], count = 0, contentCount = 0
        var identities = Set<ElementID>()
        while let (node, depth, mayPosition) = pending.popLast() {
            count += 1
            guard count <= ProgramLimits.maximumElements else { throw ProgramRuntimeError.elementLimit }
            guard depth <= ProgramLimits.maximumDepth else { throw ProgramRuntimeError.depthLimit }
            guard identities.insert(node.id).inserted else { throw ProgramRuntimeError.duplicateIdentity(node.id) }
            if let position = node.position {
                guard mayPosition, position.x.isFinite, position.y.isFinite else {
                    throw ProgramRuntimeError.invalidGeometry(node.id)
                }
            }
            guard node.onClick == nil || node.onClickActions == nil else {
                throw ProgramRuntimeError.ambiguousClickHandler(node.id)
            }
            let handlers: [(MouseEventKind, [ProgramAction]?)] = [
                (.leftUp, node.onClickActions ?? node.onClick?.map({ ProgramAction.assign($0) })),
                (.rightUp, node.onRightClickActions)
            ]
            var actionsByEvent: [MouseEventKind: [ProgramAction]] = [:]
            for (event, actions) in handlers {
                guard let actions else { continue }
                guard actions.count <= ProgramLimits.maximumExpressions - actionCount else { throw ProgramRuntimeError.expressionLimit }
                actionCount += actions.count
                for action in actions { try expressions.validateAction(action) }
                actionsByEvent[event] = actions
            }
            if !actionsByEvent.isEmpty {
                clickHandlers[node.id] = ClickHandler(actions: actionsByEvent, radius: node.cornerRadius)
            }
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
            if let stroke = node.stroke {
                guard stroke.width.isFinite, stroke.width >= 0 else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                if case .literal(let color) = stroke.color, !Self.valid(color) { throw ProgramRuntimeError.invalidPaint(node.id) }
                switch node.content {
                case .rectangle, .shape: break
                default: throw ProgramRuntimeError.invalidGeometry(node.id)
                }
            }
            if let radius = node.cornerRadius {
                if case .points(let value) = radius, !value.isFinite || value < 0 { throw ProgramRuntimeError.invalidGeometry(node.id) }
                if case .image = node.content, radius != .points(0) { throw ProgramRuntimeError.invalidGeometry(node.id) }
            }
            if let background = node.background {
                contentCount += 1
                let color: ProgramColor?
                switch background {
                case .color(let value): color = value
                case .glass(_, let tint): color = tint
                }
                if let color, case .literal(let value) = color, !Self.valid(value) { throw ProgramRuntimeError.invalidPaint(node.id) }
            }
            switch node.content {
            case .text(let text):
                guard node.idealSize == nil else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                contentCount += 1
                if case .string(let literal) = text.value, literal.utf16.count > ProgramLimits.maximumTextLength {
                    throw ProgramRuntimeError.invalidText(node.id)
                }
                try expressions.validateText(text.value)
                if let fontSize = text.fontSizeExpression { try expressions.validateFontSize(fontSize) }
                guard !text.fontFamily.isEmpty,
                      text.fontSize.isFinite, text.fontSize > 0,
                      text.fontWeight.map({ (1...999).contains($0) }) ?? true else {
                    throw ProgramRuntimeError.invalidText(node.id)
                }
                if case .literal(let color) = text.color, !Self.valid(color) { throw ProgramRuntimeError.invalidText(node.id) }
            case .image(let image):
                contentCount += 1
                guard node.idealSize == nil, !image.source.isEmpty,
                      image.source.utf16.count <= ProgramLimits.maximumTextLength, !image.source.contains("\0") else {
                    throw ProgramRuntimeError.invalidImage(node.id)
                }
            case .progress(let progress):
                contentCount += 1
                if node.idealSize == nil {
                    guard case .fixed = node.width, case .fixed = node.height else {
                        throw ProgramRuntimeError.invalidGeometry(node.id)
                    }
                }
                try expressions.validateProgress(progress)
                for color in [progress.color, progress.track] {
                    if case .literal(let rgba) = color, !Self.valid(rgba) { throw ProgramRuntimeError.invalidPaint(node.id) }
                }
            case .spacer(let minimum):
                contentCount += 1
                guard minimum.isFinite, minimum >= 0, node.padding == .zero,
                      node.idealSize == nil || node.idealSize == SkinSize() else {
                    throw ProgramRuntimeError.invalidGeometry(node.id)
                }
            case .rectangle(let fill), .shape(_, let fill):
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
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1, false) })
            case .freeform(_, let children):
                guard node.idealSize == nil else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                guard children.count <= ProgramLimits.maximumElements - count - pending.count else { throw ProgramRuntimeError.elementLimit }
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1, true) })
            }
        }
        guard contentCount > 0 else { throw ProgramRuntimeError.emptyProgram }
        self.program = program
        self.clickHandlers = clickHandlers
    }

    /// Properties needed for normal projection (or first initialization if variables == nil).
    public var neededSystemProperties: Set<ProgramSystemProperty> {
        neededSystemProperties(clickAt: nil)
    }

    /// Evaluates the set of system properties needed for a project or click operation.
    /// Only primary/secondary releases are supported; other event kinds return no dependencies.
    /// - For click (`point != nil`):
    ///   Checks hit map for a valid, non-hidden element with a handler for the selected event.
    ///   If hit: collects properties needed by the hit handler's action arguments PLUS subsequent scene projection.
    ///   If miss or unhandled: returns empty set (no hardware sampling performed).
    /// - For projection (`point == nil`):
    ///   If uninitialized (`variables == nil`): collects properties needed by all variable initial expressions,
    ///   `onLoad` assignments, and element text/font expressions.
    ///   If already initialized (`variables != nil`): variable values are frozen in memory, so variable initials
    ///   are NOT evaluated; only element text/font expressions and their transitively referenced `computed`
    ///   declarations are collected.
    ///   Note: AST dependency collection conservatively traverses Text values and fontSizeExpressions (including
    ///   elements marked hidden, because DESK-DESIGN §611 preserves layout space for hidden elements and layout
    ///   resolves/measures them). Conditional branches are conservatively unioned without dynamic evaluation,
    ///   so inactive branches may be sampled; complete zero-sampling for hidden layout branches is not yet implemented.
    public func neededSystemProperties(clickAt point: SkinPoint? = nil, event: MouseEventKind = .leftUp) -> Set<ProgramSystemProperty> {
        guard event == .leftUp || event == .rightUp else { return [] }
        if let point {
            guard point.x.isFinite, point.y.isFinite, variables != nil,
                  let entry = currentHitMap.entry(at: point.x, point.y, handling: event, images: nil),
                  let id = entry.elementID,
                  let actions = clickHandlers[id]?.actions[event] else {
                return []
            }
            var activeExpressions = actions.map(\.expression)
            return collectProperties(active: &activeExpressions, includeLayoutText: true)
        } else {
            var activeExpressions: [ProgramExpression] = []
            if variables == nil {
                for decl in program.declarations where decl.kind == .variable {
                    activeExpressions.append(decl.initial)
                }
                for assignment in program.onLoad {
                    activeExpressions.append(assignment.value)
                }
            }
            return collectProperties(active: &activeExpressions, includeLayoutText: true)
        }
    }

    private func collectProperties(active: inout [ProgramExpression], includeLayoutText: Bool) -> Set<ProgramSystemProperty> {
        if includeLayoutText {
            var pending = [(program.root, false)]
            while let (node, parentHidden) = pending.popLast() {
                let hidden = parentHidden || node.hidden
                if case .text(let text) = node.content {
                    active.append(text.value)
                    if let fontExpr = text.fontSizeExpression {
                        active.append(fontExpr)
                    }
                }
                if case .progress(let progress) = node.content, !hidden {
                    active.append(progress.value)
                    if let total = progress.total { active.append(total) }
                }
                switch node.content {
                case .column(_, _, let children), .row(_, _, let children), .freeform(_, let children):
                    pending.append(contentsOf: children.map { ($0, hidden) })
                default:
                    break
                }
            }
        }

        var needed = Set<ProgramSystemProperty>()
        var visitedComputed = Set<Int>()

        func visitExpression(_ expr: ProgramExpression) {
            switch expr {
            case .systemProperty(let prop):
                needed.insert(prop)
            case .declaration(let index):
                guard program.declarations.indices.contains(index) else { break }
                let decl = program.declarations[index]
                if decl.kind == .computed && visitedComputed.insert(index).inserted {
                    active.append(decl.initial)
                }
            case .dateIn(let child, _), .formatDate(let child, _), .formatNumber(let child, _),
                 .negate(let child), .not(let child), .isMissing(let child):
                active.append(child)
            case .concatenate(let parts):
                active.append(contentsOf: parts)
            case .and(let left, let right), .or(let left, let right),
                 .equal(let left, let right), .notEqual(let left, let right),
                 .less(let left, let right), .lessOrEqual(let left, let right),
                 .greater(let left, let right), .greaterOrEqual(let left, let right),
                 .add(let left, let right), .subtract(let left, let right),
                 .multiply(let left, let right), .divide(let left, let right), .remainder(let left, let right),
                 .ifMissing(let left, let right):
                active.append(left)
                active.append(right)
            case .conditional(let cond, let thenExpr, let otherwiseExpr):
                active.append(cond)
                active.append(thenExpr)
                active.append(otherwiseExpr)
            case .string, .number, .quantity, .boolean, .timeNow, .appearanceDark:
                break
            }
        }

        while let expr = active.popLast() {
            visitExpression(expr)
        }

        return needed
    }

    /// The closure must measure the supplied style exactly as it draws it, under the optional wrapping width.
    /// It is used synchronously and is not retained. Graphics/font resources stay outside Core.
    public mutating func project(environment: EnvironmentStamp, images: [String: ProgramImageResource] = [:],
                                 dateInput: ProgramDateInput? = nil,
                                 colorInput: ProgramColorInput? = nil,
                                 systemInput: ProgramSystemInput? = nil,
                                 measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> WidgetScene {
        let appearance = environment.appearance.value
        guard environment.scale.isFinite, environment.scale > 0,
              [appearance.labelColor, appearance.secondaryLabelColor, appearance.tertiaryLabelColor,
               appearance.accentColor, appearance.separatorColor].allSatisfy(Self.valid) else {
            throw ProgramRuntimeError.invalidEnvironment
        }
        if let dateInput, !dateInput.instant.timeIntervalSince1970.isFinite { throw ProgramRuntimeError.invalidDateInput }
        try colorInput?.validate()
        let next = generation.addingReportingOverflow(1)
        guard !next.overflow else { throw ProgramRuntimeError.generationOverflow }
        var evaluation = ProgramExpressionEvaluation(declarations: program.declarations, dark: appearance.isDark,
                                                     variables: variables, dateInput: dateInput, systemInput: systemInput)
        if variables == nil {
            try evaluation.initialize()
            // Root startup is part of the first successful scene transaction. These local-only assignments
            // may be retried after failed measurement/layout; no external action is admitted here.
            for assignment in program.onLoad { try ActionExecutor.perform(assignment, on: &evaluation) }
        }
        let preset: SkinSize?
        if case .preset(_, let size) = program.size { preset = size } else { preset = nil }
        var layoutState = LayoutState(images: images, colors: colorInput, preset: preset)
        _ = flexibility(program.root, into: &layoutState)
        var visibleContent: Set<ElementID> = [], pending = [(program.root, false)]
        while let (node, parentHidden) = pending.popLast() {
            let hidden = parentHidden || node.hidden
            switch node.content {
            case .text, .progress: if !hidden { visibleContent.insert(node.id) }
            case .column(_, _, let children), .row(_, _, let children), .freeform(_, let children): pending += children.map { ($0, hidden) }
            default: break
            }
        }
        let box = try layout(program.root, proposedWidth: preset?.width, proposedHeight: preset?.height, appearance: appearance,
                             resolve: { id, text in
                                 let displayed = visibleContent.contains(id)
                                 let value = try evaluation.text(text.value, displayed: displayed)
                                 let fontSize = try text.fontSizeExpression.map { try evaluation.fontSize($0, element: id, displayed: displayed) }
                                 return TextInput(value: value.text, style: try text.drawingStyle(in: appearance, colorInput: colorInput,
                                     wrap: false, text: value, resolvedFontSize: fontSize))
                             }, resolveProgress: { id, progress in
                                 try evaluation.progress(progress, displayed: visibleContent.contains(id))
                             }, measure: measure, state: &layoutState)
        var elements: [SceneElement] = []
        try append(box, at: SkinPoint(), inheritedHidden: false, into: &elements)
        let transform = try preset.map { try presetTransform(box, elements: elements, size: $0) } ?? .identity
        if !transform.isIdentity {
            for index in elements.indices {
                elements[index].frame = try transformed(elements[index].frame, by: transform, element: elements[index].id)
                let point = transform.apply(ShapePoint(elements[index].anchor.x, elements[index].anchor.y))
                guard point.x.isFinite, point.y.isFinite else { throw ProgramRuntimeError.layoutOverflow(elements[index].id) }
                elements[index].anchor = SkinPoint(x: point.x, y: point.y)
                if !elements[index].items.isEmpty { elements[index].items = [.transformed(transform, elements[index].items)] }
                if var glass = elements[index].glass {
                    glass.rect = try transformed(glass.rect, by: transform, element: elements[index].id)
                    glass.cornerRadius *= transform.a
                    guard glass.cornerRadius.isFinite else { throw ProgramRuntimeError.layoutOverflow(elements[index].id) }
                    if glass.rect.width > 0, glass.rect.height > 0 { elements[index].glass = glass }
                    else {
                        // A finite preset fit can underflow a tiny box to zero; it has no native surface or hit.
                        elements[index].glass = nil
                        elements[index].backing = .content
                    }
                }
            }
        }
        let sceneSize = preset ?? box.size
        var hitMap = SkinHitMap()
        hitMap.width = sceneSize.width
        hitMap.height = sceneSize.height
        // Reverse preorder puts each descendant before its ancestor and preserves topmost sibling draw order.
        // Desk hits the box, including its padding/rounded corners, independent of painted alpha or curve ink.
        for element in elements.reversed() where element.visibility == .visible {
            guard let handler = clickHandlers[element.id], element.frame.width > 0, element.frame.height > 0 else { continue }
            hitMap.entries.append(SkinHitMap.Entry(name: element.id.name, frame: element.frame,
                                                   shape: Self.clickShape(element.frame, radius: handler.radius.map {
                                                       if case .points(let radius) = $0 { return .points(radius * transform.a) }
                                                       return $0
                                                   }),
                                                   container: nil, glass: nil, isButton: false,
                                                   actions: handler.actions.mapValues { $0.isEmpty ? .caught : .runs },
                                                   cursor: true, cursorName: "", toolTip: nil, elementID: element.id))
        }
        let scene = WidgetScene(generation: next.partialValue, size: sceneSize, background: [],
                                backgroundImageDependencies: [], glass: [], elements: elements,
                                hitMap: hitMap, environment: environment)
        generation = next.partialValue
        variables = evaluation.variables
        clockPrecision = evaluation.clockPrecision
        currentHitMap = hitMap
        return scene
    }

    /// Compatibility dispatch for local assignments. A handler producing external requests throws before this
    /// runtime commits; callers handling those requests must use clickWithEffects instead.
    public mutating func click(at point: SkinPoint, expectedGeneration: UInt64, environment: EnvironmentStamp,
                               images: [String: ProgramImageResource] = [:], dateInput: ProgramDateInput? = nil,
                               colorInput: ProgramColorInput? = nil,
                               systemInput: ProgramSystemInput? = nil,
                               measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> WidgetScene? {
        var candidate = self
        guard let result = try candidate.clickWithEffects(at: point, expectedGeneration: expectedGeneration,
            environment: environment, images: images, dateInput: dateInput, colorInput: colorInput,
            systemInput: systemInput, measure: measure) else { return nil }
        guard result.effects.isEmpty else { throw ProgramRuntimeError.unhandledClickEffects }
        self = candidate
        return result.scene
    }

    /// Dispatch one current primary or secondary release without executing external services. The host qualifies its press
    /// and source session; Core rejects stale scenes and missed/hidden boxes. Each statement observes preceding
    /// writes. Variables and frozen, ordered effects commit only after the resulting projection succeeds.
    public mutating func clickWithEffects(at point: SkinPoint, expectedGeneration: UInt64, event: MouseEventKind = .leftUp,
                                          environment: EnvironmentStamp,
                                          images: [String: ProgramImageResource] = [:], dateInput: ProgramDateInput? = nil,
                                          colorInput: ProgramColorInput? = nil,
                                          systemInput: ProgramSystemInput? = nil,
                                          measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> ProgramClickResult? {
        guard event == .leftUp || event == .rightUp,
              point.x.isFinite, point.y.isFinite, variables != nil, expectedGeneration == generation,
              let entry = currentHitMap.entry(at: point.x, point.y, handling: event, images: nil),
              let id = entry.elementID, let actions = clickHandlers[id]?.actions[event] else { return nil }
        var candidate = self
        try colorInput?.validate()
        var evaluation = ProgramExpressionEvaluation(declarations: program.declarations, dark: environment.appearance.value.isDark,
                                                      variables: variables, dateInput: dateInput, systemInput: systemInput)
        var effects: [ProgramEffect] = []
        for action in actions {
            if let effect = try ActionExecutor.perform(action, on: &evaluation) { effects.append(effect) }
        }
        candidate.variables = evaluation.variables
        let scene = try candidate.project(environment: environment, images: images, dateInput: dateInput, colorInput: colorInput,
                                          systemInput: systemInput, measure: measure)
        self = candidate
        return ProgramClickResult(scene: scene, effects: effects)
    }

    private static func clickShape(_ frame: SkinRect, radius: ProgramCornerRadius?) -> MouseShape {
        let value = cornerRadius(radius, in: frame)
        guard value > 0 else { return .rect(frame) }
        let geometry = ShapeGeometry.path(ShapePath(subpaths: [ShapeGeometryBuilder.rectangle(x: 0, y: 0,
                                         width: frame.width, height: frame.height, radiusX: value)], fillRule: .nonZero))
        let bounds = ShapeRect(minX: 0, minY: 0, maxX: frame.width, maxY: frame.height)
        let item = ShapeItem(index: 0, geometry: geometry, closed: true, fill: .color(.black), stroke: .none,
                             strokeStyle: ShapeStrokeStyle(), strokePlan: nil, paintTransform: .identity, bounds: bounds, visualBounds: bounds)
        return .shapes(ShapeMouseShape(frame: frame, originX: frame.x, originY: frame.y, inverse: nil,
                                     solidBackground: false, items: [item], regions: [ShapeHitTester.FlatRegion(geometry)]))
    }

    private static func cornerRadius(_ radius: ProgramCornerRadius?, in frame: SkinRect) -> Double {
        switch radius {
        case .points(let value): return min(value, min(frame.width, frame.height) / 2)
        case .full: return min(frame.width, frame.height) / 2
        case nil: return 0
        }
    }

    private static func valid(_ color: RGBA) -> Bool {
        [color.r, color.g, color.b, color.a].allSatisfy { $0.isFinite && (0...255).contains($0) }
    }

    private struct Box {
        let node: ProgramElement
        let size: SkinSize
        let minimum: SkinSize
        let layoutBounds: SkinRect
        let content: SkinRect
        let style: TextStyle?
        let text: String?
        let textSize: SkinSize?
        let fill: RGBA?
        let track: RGBA?
        let progress: Double?
        let stroke: RGBA?
        let backgroundColor: RGBA?
        let backgroundTint: RGBA?
        let image: ProgramImageResource?
        let children: [(Box, SkinPoint)]
    }

    private struct Flexibility { let width: Bool; let height: Bool }
    private struct ProposalKey: Hashable { let id: ElementID; let width: Double?; let height: Double? }
    private struct TextKey: Hashable { let id: ElementID; let width: Double? }
    private struct TextInput { let value: String; let style: TextStyle }
    /// Only this projection's pure results. Repeating a proposal uses the same measured style/size;
    /// no font or graphics resource, closure, cache or partial scene survives publication or failure.
    private struct LayoutState {
        let images: [String: ProgramImageResource]
        let colors: ProgramColorInput?
        let preset: SkinSize?
        var flex: [ElementID: Flexibility] = [:]
        var spacerAxes: [ElementID: Bool] = [:]
        var boxes: [ProposalKey: Box] = [:]
        var text: [ElementID: TextInput] = [:]
        var measures: [TextKey: SkinSize] = [:]
        var progress: [ElementID: Double] = [:]
    }

    private func flexibility(_ node: ProgramElement, parentVertical: Bool? = nil, into state: inout LayoutState) -> Flexibility {
        if case .spacer = node.content {
            if let parentVertical { state.spacerAxes[node.id] = parentVertical }
            let value = Flexibility(width: parentVertical == false, height: parentVertical == true)
            state.flex[node.id] = value
            return value
        }
        let children: [ProgramElement]
        switch node.content {
        case .column(_, _, let nodes), .row(_, _, let nodes), .freeform(_, let nodes): children = nodes
        case .text, .image, .rectangle, .shape, .progress, .spacer: children = []
        }
        let childAxis: Bool?
        switch node.content { case .column: childAxis = true; case .row: childAxis = false; default: childAxis = nil }
        let descendants = children.map { flexibility($0, parentVertical: childAxis, into: &state) }
        let value = Flexibility(width: node.width == .fill || (node.width == .fit && descendants.contains { $0.width }),
                                height: node.height == .fill || (node.height == .fit && descendants.contains { $0.height }))
        state.flex[node.id] = value
        return value
    }

    private func layout(_ node: ProgramElement, proposedWidth: Double?, proposedHeight: Double?, appearance: SkinAppearance,
                        resolve: (ElementID, ProgramText) throws -> TextInput,
                        resolveProgress: (ElementID, ProgramProgress) throws -> Double,
                        measure: (String, TextStyle, Double?) throws -> SkinSize, state: inout LayoutState) throws -> Box {
        let key = ProposalKey(id: node.id, width: proposedWidth, height: proposedHeight)
        if let old = state.boxes[key] { return old }
        guard let flexible = state.flex[node.id] else { throw ProgramRuntimeError.invalidGeometry(node.id) }
        let presetRoot = state.preset != nil && node.id == program.root.id
        let widthSpec: ProgramLength = presetRoot ? .fill : node.width
        let heightSpec: ProgramLength = presetRoot ? .fill : node.height
        let minWidth = presetRoot ? 0 : node.minWidth, minHeight = presetRoot ? 0 : node.minHeight
        let maxWidth = presetRoot ? nil : node.maxWidth, maxHeight = presetRoot ? nil : node.maxHeight
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
        let requestedWidth = requested(widthSpec, proposal: proposedWidth, flex: flexible.width, minimum: minWidth, maximum: maxWidth)
        let requestedHeight = requested(heightSpec, proposal: proposedHeight, flex: flexible.height, minimum: minHeight, maximum: maxHeight)
        let offeredWidth = requestedWidth ?? proposedWidth.map { clamp($0, minimum: minWidth, maximum: maxWidth) } ?? maxWidth
        let offeredHeight = requestedHeight ?? proposedHeight.map { clamp($0, minimum: minHeight, maximum: maxHeight) } ?? maxHeight
        var width: Double, height: Double, style: TextStyle?, resolvedText: String?, textSize: SkinSize?,
            fill: RGBA?, track: RGBA?, fraction: Double?, image: ProgramImageResource?
        var children: [(Box, SkinPoint)] = []
        var minimumContent = SkinSize()
        switch node.content {
        case .text(let text):
            let input: TextInput
            if let old = state.text[node.id] { input = old }
            else {
                input = try resolve(node.id, text)
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
            width = requestedWidth ?? clamp(fittedWidth, minimum: minWidth, maximum: maxWidth)
            guard state.preset != nil || width >= horizontal else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            let innerWidth = max(0, width - horizontal)
            let wraps = innerWidth < ideal.width
            var finalStyle = input.style
            finalStyle.wrap = wraps
            let actual = wraps ? try measured(finalStyle, width: innerWidth) : ideal
            guard state.preset != nil || actual.width <= innerWidth else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            let naturalHeight = try sum([actual.height, vertical])
            height = requestedHeight ?? clamp(naturalHeight, minimum: minHeight, maximum: maxHeight)
            guard state.preset != nil || height >= naturalHeight else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            style = finalStyle
            textSize = actual
            minimumContent = SkinSize(width: actual.width, height: actual.height)
        case .image(let input):
            guard let resource = state.images[input.source], !resource.path.isEmpty, !resource.path.contains("\0"),
                  resource.naturalSize.width.isFinite, resource.naturalSize.height.isFinite,
                  resource.naturalSize.width > 0, resource.naturalSize.height > 0 else {
                throw ProgramRuntimeError.invalidImage(node.id)
            }
            image = resource
            width = try requestedWidth ?? clamp(sum([resource.naturalSize.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([resource.naturalSize.height, vertical]), minimum: minHeight, maximum: maxHeight)
            minimumContent = SkinSize(width: max(0, width - horizontal), height: max(0, height - vertical))
        case .rectangle(let color), .shape(_, let color):
            let ideal = node.idealSize ?? SkinSize()
            width = try requestedWidth ?? clamp(sum([ideal.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([ideal.height, vertical]), minimum: minHeight, maximum: maxHeight)
            fill = try color.resolved(in: appearance, colorInput: state.colors)
            minimumContent = SkinSize(width: max(0, width - horizontal), height: max(0, height - vertical))
        case .progress(let progress):
            let ideal = node.idealSize ?? SkinSize()
            width = try requestedWidth ?? clamp(sum([ideal.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([ideal.height, vertical]), minimum: minHeight, maximum: maxHeight)
            fill = try progress.color.resolved(in: appearance, colorInput: state.colors)
            track = try progress.track.resolved(in: appearance, colorInput: state.colors)
            if let cached = state.progress[node.id] { fraction = cached }
            else {
                let value = try resolveProgress(node.id, progress)
                state.progress[node.id] = value; fraction = value
            }
            minimumContent = SkinSize(width: max(0, width - horizontal), height: max(0, height - vertical))
        case .spacer(let minimum):
            if let vertical = state.spacerAxes[node.id] {
                let lower = max(minimum, vertical ? minHeight : minWidth)
                let upper = vertical ? maxHeight : maxWidth
                guard upper.map({ $0 >= lower }) ?? true else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                let proposed = vertical ? proposedHeight : proposedWidth
                let length = clamp(proposed ?? lower, minimum: lower, maximum: upper)
                width = vertical ? 0 : length; height = vertical ? length : 0
                minimumContent = vertical ? SkinSize(height: lower) : SkinSize(width: lower)
            } else { width = 0; height = 0 }
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
                           appearance: appearance, resolve: resolve, resolveProgress: resolveProgress, measure: measure, state: &state)
            }
            func main(_ size: SkinSize) -> Double { column ? size.height : size.width }
            func cross(_ size: SkinSize) -> Double { column ? size.width : size.height }
            let naturalCross = try sum([boxes.map { cross($0.size) }.max() ?? 0, crossPadding])
            let crossMinimum = column ? minWidth : minHeight
            let crossMaximum = column ? maxWidth : maxHeight
            let requestedCross = column ? requestedWidth : requestedHeight
            var crossSize = requestedCross ?? clamp(naturalCross, minimum: crossMinimum, maximum: crossMaximum)
            guard state.preset != nil || crossSize >= crossPadding else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            var finalCross = max(0, crossSize - crossPadding)
            // The final cross size can be discovered from an ideal sibling. Reflow every child with this
            // proposal, including nested fit containers; identical proposals reuse their earlier pure result.
            if initialCross != finalCross {
                boxes = try nodes.map {
                    try layout($0, proposedWidth: column ? finalCross : nil, proposedHeight: column ? nil : finalCross,
                               appearance: appearance, resolve: resolve, resolveProgress: resolveProgress, measure: measure, state: &state)
                }
            }
            let naturalMain = try sum(boxes.map { main($0.size) } + [gap, mainPadding])
            let mainMinimum = column ? minHeight : minWidth
            let mainMaximum = column ? maxHeight : maxWidth
            let requestedMain = column ? requestedHeight : requestedWidth
            let mainSize = requestedMain ?? clamp(naturalMain, minimum: mainMinimum, maximum: mainMaximum)
            guard state.preset != nil || mainSize >= mainPadding else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            let innerMain = max(0, mainSize - mainPadding)
            let childFlex = try nodes.map { child -> Flexibility in
                guard let value = state.flex[child.id] else { throw ProgramRuntimeError.invalidGeometry(child.id) }
                return value
            }
            let isFlexible = childFlex.map { column ? $0.height : $0.width }
            var proposedMain = Array<Double?>(repeating: nil, count: nodes.count)
            if requestedMain != nil || mainSize != naturalMain {
                let rigid = try sum(boxes.indices.filter { !isFlexible[$0] }.map { main(boxes[$0].size) } + [gap])
                guard state.preset != nil || innerMain >= rigid else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                let indices = boxes.indices.filter { isFlexible[$0] }
                var allocated = indices.map { main(boxes[$0].minimum) }
                let minimum = try sum(allocated)
                let remainder = max(0, innerMain - rigid)
                guard state.preset != nil || remainder >= minimum else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                let budget = max(remainder, minimum)
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
                    if state.preset != nil { return max(0, try sum(values) - budget) }
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
                                              appearance: appearance, resolve: resolve, resolveProgress: resolveProgress, measure: measure, state: &state)
                }
            }
            // A Row's assigned widths can wrap text and increase its fit height. Keep those assignments
            // while propagating the actual final cross size, rather than clipping to the unwrapped ideal.
            if requestedCross == nil {
                let actualCross = try sum([boxes.map { cross($0.size) }.max() ?? 0, crossPadding])
                let fittedCross = clamp(actualCross, minimum: crossMinimum, maximum: crossMaximum)
                if fittedCross != crossSize {
                    crossSize = fittedCross
                    guard state.preset != nil || crossSize >= crossPadding else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                    finalCross = max(0, crossSize - crossPadding)
                    boxes = try nodes.indices.map { index in
                        try layout(nodes[index], proposedWidth: column ? finalCross : proposedMain[index],
                                   proposedHeight: column ? proposedMain[index] : finalCross,
                                   appearance: appearance, resolve: resolve, resolveProgress: resolveProgress, measure: measure, state: &state)
                    }
                }
            }
            let minimumMain = try sum(boxes.indices.map { isFlexible[$0] ? main(boxes[$0].minimum) : main(boxes[$0].size) } + [gap])
            let minimumCross = boxes.indices.map { index in
                (column ? childFlex[index].width : childFlex[index].height) ? cross(boxes[index].minimum) : cross(boxes[index].size)
            }.max() ?? 0
            let usedMain = try sum(boxes.map { main($0.size) } + [gap])
            guard state.preset != nil || (usedMain <= innerMain && boxes.allSatisfy({ cross($0.size) <= finalCross })) else {
                throw ProgramRuntimeError.layoutOverflow(node.id)
            }
            width = column ? crossSize : mainSize
            height = column ? mainSize : crossSize
            minimumContent = column ? SkinSize(width: minimumCross, height: minimumMain) : SkinSize(width: minimumMain, height: minimumCross)
            children = boxes.map { ($0, SkinPoint()) }
        case .freeform(let align, let nodes):
            let initialWidth = offeredWidth.map { max(0, $0 - horizontal) }
            let initialHeight = offeredHeight.map { max(0, $0 - vertical) }
            let knownWidth = requestedWidth.map { max(0, $0 - horizontal) }
            let knownHeight = requestedHeight.map { max(0, $0 - vertical) }
            var boxes = try nodes.map { child in
                let positioned = child.position != nil
                return try layout(child,
                    proposedWidth: positioned ? (child.width == .fill ? knownWidth : nil) : initialWidth,
                    proposedHeight: positioned ? (child.height == .fill ? knownHeight : nil) : initialHeight,
                    appearance: appearance, resolve: resolve, resolveProgress: resolveProgress, measure: measure, state: &state)
            }
            func origin(_ size: SkinSize, position: ProgramPosition) throws -> SkinPoint {
                let factor = Self.alignmentFactors(position.anchor)
                let point = SkinPoint(x: position.x - factor.x * size.width, y: position.y - factor.y * size.height)
                guard point.x.isFinite, point.y.isFinite else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                return point
            }
            func extent(minimum: Bool = false) throws -> SkinSize {
                var result = SkinSize()
                for i in boxes.indices {
                    let box = boxes[i]
                    guard let flex = state.flex[nodes[i].id] else { throw ProgramRuntimeError.invalidGeometry(nodes[i].id) }
                    let size = minimum ? SkinSize(width: flex.width ? box.minimum.width : box.size.width,
                                                  height: flex.height ? box.minimum.height : box.size.height) : box.size
                    let point = try nodes[i].position.map { try origin(size, position: $0) } ?? SkinPoint()
                    let right = point.x + size.width, bottom = point.y + size.height
                    guard right.isFinite, bottom.isFinite else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                    result.width = max(result.width, right); result.height = max(result.height, bottom)
                }
                return result
            }
            let natural = try extent()
            width = try requestedWidth ?? clamp(sum([natural.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([natural.height, vertical]), minimum: minHeight, maximum: maxHeight)
            guard state.preset != nil || (width >= horizontal && height >= vertical) else { throw ProgramRuntimeError.layoutOverflow(node.id) }
            let finalWidth = max(0, width - horizontal), finalHeight = max(0, height - vertical)
            if initialWidth != finalWidth || initialHeight != finalHeight {
                for i in boxes.indices where nodes[i].position == nil {
                    boxes[i] = try layout(nodes[i], proposedWidth: finalWidth, proposedHeight: finalHeight,
                                          appearance: appearance, resolve: resolve, resolveProgress: resolveProgress, measure: measure, state: &state)
                }
            }
            // An unspecified fit proposal stays unspecified for positioned fill children: feeding the
            // computed extent back into them would make a positive-positioned fill grow on every pass.
            let reflowed = try extent()
            width = try requestedWidth ?? clamp(sum([reflowed.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([reflowed.height, vertical]), minimum: minHeight, maximum: maxHeight)
            let minimumExtent = try extent(minimum: true)
            // Unlike a stack, the container's own constraints may be smaller than its positioned contents.
            minimumContent = SkinSize(width: min(minimumExtent.width, max(0, width - horizontal)),
                                      height: min(minimumExtent.height, max(0, height - vertical)))
            let factor = Self.alignmentFactors(align)
            for i in boxes.indices {
                let point: SkinPoint
                if let position = nodes[i].position { point = try origin(boxes[i].size, position: position) }
                else {
                    point = SkinPoint(x: (max(0, width - horizontal) - boxes[i].size.width) * factor.x,
                                      y: (max(0, height - vertical) - boxes[i].size.height) * factor.y)
                }
                let offset = SkinPoint(x: p.left + point.x, y: p.top + point.y)
                guard offset.x.isFinite, offset.y.isFinite else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                children.append((boxes[i], offset))
            }
        }
        guard width.isFinite, height.isFinite, width >= 0, height >= 0,
              state.preset != nil || (width >= horizontal && height >= vertical) else {
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
                guard state.preset != nil || (upper.map({ value <= $0 }) ?? true) else { throw ProgramRuntimeError.layoutOverflow(node.id) }
                return value
            }
        }
        let minimumSize: SkinSize
        if case .spacer = node.content { minimumSize = minimumContent }
        else {
            minimumSize = try SkinSize(width: minimum(widthSpec, flexible: flexible.width, actual: width, content: minimumContent.width,
                                                     padding: horizontal, lower: minWidth, upper: maxWidth),
                                      height: minimum(heightSpec, flexible: flexible.height, actual: height, content: minimumContent.height,
                                                      padding: vertical, lower: minHeight, upper: maxHeight))
        }
        let innerWidth = max(0, width - horizontal), innerHeight = max(0, height - vertical)
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
            case .text, .image, .rectangle, .shape, .freeform, .progress, .spacer: break
            }
        }
        var layoutBounds = SkinRect(width: width, height: height)
        if state.preset != nil {
            layoutBounds = SkinRect(width: max(width, horizontal), height: max(height, vertical))
            for (child, point) in children {
                let slot: SkinRect
                if case .freeform = node.content, child.node.position != nil {
                    // Freeform fit extents start at the origin. Hidden negative positions add no paint extent.
                    slot = SkinRect(width: max(0, point.x + child.size.width + p.right),
                                    height: max(0, point.y + child.size.height + p.bottom))
                } else {
                    // Keep the final alignment offset: a centered 340 pt child in 170 pt is -85...255.
                    slot = SkinRect(x: point.x, y: point.y, width: child.size.width + p.right, height: child.size.height + p.bottom)
                }
                layoutBounds = layoutBounds.union(slot)
            }
        }
        let backgroundColor: RGBA?, backgroundTint: RGBA?
        switch node.background {
        case .color(let color):
            backgroundColor = try color.resolved(in: appearance, colorInput: state.colors)
            backgroundTint = nil
        case .glass(_, let tint):
            backgroundColor = nil
            backgroundTint = try tint.map { try $0.resolved(in: appearance, colorInput: state.colors) }
        case nil: backgroundColor = nil; backgroundTint = nil
        }
        let box = Box(node: node, size: SkinSize(width: width, height: height), minimum: minimumSize,
                      layoutBounds: layoutBounds,
                      content: SkinRect(x: p.left, y: p.top, width: innerWidth,
                                        height: max(innerHeight, textSize?.height ?? 0)),
                      style: style, text: resolvedText, textSize: textSize, fill: fill, track: track, progress: fraction,
                      stroke: try node.stroke.map { try $0.color.resolved(in: appearance, colorInput: state.colors) },
                      backgroundColor: backgroundColor, backgroundTint: backgroundTint, image: image, children: children)
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
        var imageDependencies: [ImageDependency] = []
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
        case .image(let input):
            kind = .image
            guard let resource = box.image else { throw ProgramRuntimeError.invalidImage(box.node.id) }
            if !hidden {
                let content = SkinRect(x: point.x + box.content.x, y: point.y + box.content.y,
                                       width: box.content.width, height: box.content.height)
                guard [content.x, content.y, content.width, content.height, content.maxX, content.maxY].allSatisfy(\.isFinite) else {
                    throw ProgramRuntimeError.layoutOverflow(box.node.id)
                }
                if content.width > 0, content.height > 0 {
                    var options = ImageOptions()
                    options.useExifOrientation = true
                    let aspect = input.mode == .fit ? 1 : (input.mode == .fill ? 2 : 0)
                    items = [.image(ImageDraw(contentFrame: content, path: resource.path, options: options,
                                              maskPath: nil, maskOptions: ImageOptions(), preserveAspectRatio: aspect,
                                              tile: input.mode == .tile, scaleMargins: nil, decodesAtDrawnSize: true,
                                              naturalSize: resource.naturalSize))]
                    imageDependencies = [ImageDependency(path: resource.path, stamp: resource.stamp)]
                }
            }
        case .column: kind = .unknown("Column")
        case .row: kind = .unknown("Row")
        case .freeform: kind = .unknown("Freeform")
        case .spacer: kind = .unknown("Spacer")
        case .progress(let progress):
            kind = .bar
            guard let fill = box.fill, let track = box.track, let fraction = box.progress else {
                throw ProgramRuntimeError.invalidPaint(box.node.id)
            }
            if !hidden {
                let content = SkinRect(x: point.x + box.content.x, y: point.y + box.content.y,
                                       width: box.content.width, height: box.content.height)
                guard [content.x, content.y, content.width, content.height, content.maxX, content.maxY].allSatisfy(\.isFinite) else {
                    throw ProgramRuntimeError.layoutOverflow(box.node.id)
                }
                if content.width > 0, content.height > 0 {
                    items = [.fill(content, Paint(color: track))]
                    if fraction > 0 {
                        let rect: SkinRect
                        switch progress.fills {
                        case .right: rect = SkinRect(x: content.x, y: content.y, width: content.width * fraction, height: content.height)
                        case .left: rect = SkinRect(x: content.maxX - content.width * fraction, y: content.y,
                                                  width: content.width * fraction, height: content.height)
                        case .up: rect = SkinRect(x: content.x, y: content.maxY - content.height * fraction,
                                                width: content.width, height: content.height * fraction)
                        case .down: rect = SkinRect(x: content.x, y: content.y, width: content.width, height: content.height * fraction)
                        }
                        items.append(.bar(BarDraw(visibleRects: [rect], imageRect: nil, path: nil, options: ImageOptions(), color: fill)))
                    }
                }
            }
        case .rectangle, .shape:
            kind = .shape
            guard let fill = box.fill else { throw ProgramRuntimeError.invalidPaint(box.node.id) }
            if !hidden {
                let content = SkinRect(x: point.x + box.content.x, y: point.y + box.content.y,
                                       width: box.content.width, height: box.content.height)
                guard [content.x, content.y, content.width, content.height, content.maxX, content.maxY].allSatisfy(\.isFinite) else {
                    throw ProgramRuntimeError.layoutOverflow(box.node.id)
                }
                if content.width > 0, content.height > 0 {
                    if case .rectangle = box.node.content, box.node.stroke == nil,
                       box.node.cornerRadius == nil || box.node.cornerRadius == .points(0) {
                        items = [.fill(content, Paint(color: fill))]
                    } else {
                        items = [.shape(try shapeDrawing(box.node, fill: fill, stroke: box.stroke, in: content))]
                    }
                }
            }
        }
        var glass: GlassRegion?
        if !hidden, frame.width > 0, frame.height > 0 {
            let radius = Self.cornerRadius(box.node.cornerRadius, in: frame)
            switch box.node.background {
            case .color:
                guard let color = box.backgroundColor else { throw ProgramRuntimeError.invalidPaint(box.node.id) }
                if radius == 0 { items.insert(.fill(frame, Paint(color: color)), at: 0) }
                else {
                    let geometry = ShapeGeometry.path(ShapePath(subpaths: [ShapeGeometryBuilder.rectangle(
                        x: 0, y: 0, width: frame.width, height: frame.height, radiusX: radius)], fillRule: .nonZero))
                    let bounds = ShapeRect(minX: 0, minY: 0, maxX: frame.width, maxY: frame.height)
                    let shape = ShapeItem(index: 0, geometry: geometry, closed: true, fill: .color(color), stroke: .none,
                        strokeStyle: ShapeStrokeStyle(), strokePlan: nil, paintTransform: .identity, bounds: bounds, visualBounds: bounds)
                    items.insert(.shape(ShapeDraw(shapes: [shape], contentFrame: frame)), at: 0)
                }
            case .glass(let style, _):
                glass = GlassRegion(id: "desk-background:\(box.node.id.index):\(box.node.id.name)", rect: frame,
                                    cornerRadius: radius, style: style, tint: box.backgroundTint)
            case nil: break
            }
        }
        elements.append(SceneElement(id: box.node.id, kind: kind, frame: frame, anchor: point,
                                     visibility: hidden ? .hiddenKeepsSpace : .visible, container: nil, isContainer: false,
                                     items: items, glass: glass, imageDependencies: imageDependencies,
                                     backing: glass == nil ? .content : .native(.glass)))
        for (child, offset) in box.children {
            try append(child, at: SkinPoint(x: point.x + offset.x, y: point.y + offset.y), inheritedHidden: hidden, into: &elements)
        }
    }

    /// Keep the preset proposal for measurement and allocation. Only the complete, finite result is fitted into
    /// the window. Parent layout bounds retain hidden children's slots; only visible content adds paint overflow.
    private func presetTransform(_ box: Box, elements: [SceneElement], size: SkinSize) throws -> ShapeTransform {
        var minX = 0.0, minY = 0.0, maxX = size.width, maxY = size.height
        func include(_ rect: SkinRect, element: ElementID) throws {
            guard [rect.x, rect.y, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
                  rect.width >= 0, rect.height >= 0 else { throw ProgramRuntimeError.layoutOverflow(element) }
            minX = min(minX, rect.x); minY = min(minY, rect.y)
            maxX = max(maxX, rect.maxX); maxY = max(maxY, rect.maxY)
        }
        for element in elements where element.visibility == .visible {
            try include(element.frame, element: element.id)
            for item in element.items {
                if case .shape(let draw) = item {
                    for shape in draw.shapes where shape.fill.isVisible || (shape.stroke.isVisible && shape.strokePlan?.isEmpty == false) {
                        let bounds = shape.visualBounds
                        try include(SkinRect(x: draw.contentFrame.x + bounds.minX, y: draw.contentFrame.y + bounds.minY,
                                             width: bounds.width, height: bounds.height), element: element.id)
                    }
                }
            }
        }
        var pending = [(box, SkinPoint(), false)]
        while let (current, point, parentHidden) = pending.popLast() {
            let hidden = parentHidden || current.node.hidden
            if hidden { continue }
            try include(SkinRect(x: point.x + current.layoutBounds.x, y: point.y + current.layoutBounds.y,
                                 width: current.layoutBounds.width, height: current.layoutBounds.height), element: current.node.id)
            if let text = current.textSize {
                try include(SkinRect(x: point.x + current.content.x, y: point.y + current.content.y,
                                     width: text.width, height: text.height), element: current.node.id)
            }
            pending.append(contentsOf: current.children.map {
                ($0.0, SkinPoint(x: point.x + $0.1.x, y: point.y + $0.1.y), hidden)
            })
        }
        let width = maxX - minX, height = maxY - minY
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw ProgramRuntimeError.layoutOverflow(box.node.id)
        }
        let scale = min(1, min(size.width / width, size.height / height))
        let transform = ShapeTransform(a: scale, b: 0, c: 0, d: scale, tx: -minX * scale, ty: -minY * scale)
        guard scale.isFinite, scale > 0, transform.tx.isFinite, transform.ty.isFinite else {
            throw ProgramRuntimeError.layoutOverflow(box.node.id)
        }
        return transform
    }

    private func transformed(_ rect: SkinRect, by transform: ShapeTransform, element: ElementID) throws -> SkinRect {
        let point = transform.apply(ShapePoint(rect.x, rect.y))
        let result = SkinRect(x: point.x, y: point.y, width: rect.width * transform.a, height: rect.height * transform.d)
        guard [result.x, result.y, result.width, result.height, result.maxX, result.maxY].allSatisfy(\.isFinite) else {
            throw ProgramRuntimeError.layoutOverflow(element)
        }
        return result
    }

    private static func alignmentFactors(_ align: ProgramAlignment) -> SkinPoint {
        switch align {
        case .topLeft: return SkinPoint(x: 0, y: 0)
        case .top: return SkinPoint(x: 0.5, y: 0)
        case .topRight: return SkinPoint(x: 1, y: 0)
        case .left: return SkinPoint(x: 0, y: 0.5)
        case .center: return SkinPoint(x: 0.5, y: 0.5)
        case .right: return SkinPoint(x: 1, y: 0.5)
        case .bottomLeft: return SkinPoint(x: 0, y: 1)
        case .bottom: return SkinPoint(x: 0.5, y: 1)
        case .bottomRight: return SkinPoint(x: 1, y: 1)
        }
    }

    /// Pure local geometry; each new immutable payload gets its own correct renderer cache identity.
    private func shapeDrawing(_ node: ProgramElement, fill: RGBA, stroke: RGBA?, in content: SkinRect) throws -> ShapeDraw {
        let w = content.width, h = content.height
        let path: ShapeSubpath
        let bounds: ShapeRect
        switch node.content {
        case .shape(.circle, _):
            let radius = min(w, h) / 2
            path = ShapeGeometryBuilder.ellipse(centerX: w / 2, centerY: h / 2, radiusX: radius)
            bounds = ShapeRect(minX: w / 2 - radius, minY: h / 2 - radius, maxX: w / 2 + radius, maxY: h / 2 + radius)
        case .shape(.ellipse, _):
            path = ShapeGeometryBuilder.ellipse(centerX: w / 2, centerY: h / 2, radiusX: w / 2, radiusY: h / 2)
            bounds = ShapeRect(minX: 0, minY: 0, maxX: w, maxY: h)
        case .shape(.capsule, _):
            path = ShapeGeometryBuilder.rectangle(x: 0, y: 0, width: w, height: h, radiusX: min(w, h) / 2)
            bounds = ShapeRect(minX: 0, minY: 0, maxX: w, maxY: h)
        case .rectangle:
            let radius = Self.cornerRadius(node.cornerRadius, in: content)
            path = ShapeGeometryBuilder.rectangle(x: 0, y: 0, width: w, height: h, radiusX: radius)
            bounds = ShapeRect(minX: 0, minY: 0, maxX: w, maxY: h)
        default: throw ProgramRuntimeError.invalidGeometry(node.id)
        }
        let outline = ShapePath(subpaths: [path], fillRule: .nonZero)
        var style = ShapeStrokeStyle()
        style.width = node.stroke?.width ?? 0
        let strokePaint: ShapePaint = stroke.map { .color($0) } ?? .none
        var visual = bounds
        var plan: ShapeStrokePlan?
        if style.width > 0, strokePaint.isVisible {
            visual = bounds.insetBy(-style.width / 2)
            guard [visual.minX, visual.minY, visual.maxX, visual.maxY, visual.width, visual.height,
                   content.x + visual.minX, content.y + visual.minY,
                   content.x + visual.maxX, content.y + visual.maxY].allSatisfy(\.isFinite) else {
                throw ProgramRuntimeError.layoutOverflow(node.id)
            }
            plan = ShapeStroker.plan(for: outline, style: style)
            if let plan, let widened = ShapeStroker.bounds(of: plan) { visual = visual.union(widened) }
            guard [visual.minX, visual.minY, visual.maxX, visual.maxY, visual.width, visual.height,
                   content.x + visual.minX, content.y + visual.minY,
                   content.x + visual.maxX, content.y + visual.maxY].allSatisfy(\.isFinite) else {
                throw ProgramRuntimeError.layoutOverflow(node.id)
            }
        }
        let item = ShapeItem(index: 1, geometry: .path(outline), closed: true,
                             fill: .color(fill), stroke: strokePaint, strokeStyle: style, strokePlan: plan,
                             paintTransform: .identity, bounds: bounds, visualBounds: visual)
        return ShapeDraw(shapes: [item], contentFrame: content)
    }
}
