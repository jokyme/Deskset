import Foundation

public enum ProgramRuntimeError: Error, Equatable {
    case elementLimit, depthLimit, emptyProgram, duplicateIdentity(ElementID)
    case invalidGeometry(ElementID), invalidText(ElementID), invalidMeasurement(ElementID)
    case invalidPaint(ElementID), invalidImage(ElementID), invalidIcon(ElementID), missingIconMeasurement(ElementID)
    case layoutOverflow(ElementID), invalidEnvironment, generationOverflow
    case expressionLimit, expressionDepth, invalidExpression
    case invalidDeclaration(Int), cyclicDeclaration(Int), uninitializedDeclaration(Int)
    case invalidAssignment(Int)
    case ambiguousClickHandler(ElementID), unhandledClickEffects, missingActionString
    case invalidDateInput
    case invalidColorInput, missingColorInput(ProgramPaletteColor)
    case invalidOption(String), optionsRevisionOverflow
}

/// The executable part of the shared runtime. It owns a program value, session variables and scene generations,
/// not a Skin, host, timer or service. A failed measurement/layout never publishes a partial scene.
public struct ProgramRuntime: Sendable {
    public let program: WidgetProgram
    /// The host selects the widget's translation tag at load time. Nil uses source patterns.
    public let language: String?
    public var displayName: String { program.displayName(language: language) }
    public private(set) var generation: UInt64 = 0
    public private(set) var clockPrecision: ProgramClockPrecision?
    public private(set) var optionValues: ProgramOptionsInput
    public private(set) var optionsRevision: UInt64 = 0
    private let optionSchema: ProgramOptionsSchema
    private var variables: [ProgramScalar?]?
    private struct ClickHandler: Sendable {
        let actions: [MouseEventKind: [ProgramAction]]
        let radius: ProgramCornerRadius?
        let isContainer: Bool
    }
    private let clickHandlers: [ElementID: ClickHandler]
    private struct MenuTemplate: Sendable {
        let items: [ProgramMenuNode]
        let radius: ProgramCornerRadius?
    }
    private let menus: [ElementID: MenuTemplate]
    /// Unlike pointer hits, root menu fallback must survive a zero-area root with visible overflowing children.
    private var visibleMenuOwners: Set<ElementID> = []
    private var currentHitMap = SkinHitMap()

    public init(program: WidgetProgram, language: String? = nil, options: ProgramOptionsInput? = nil) throws {
        if case .preset(_, let size) = program.size {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw ProgramRuntimeError.invalidGeometry(program.root.id)
            }
        }
        let optionSchema = try ProgramOptionsSchema(structure: program.options, translations: program.translations)
        var expressions = try ProgramExpressionValidation(declarations: program.declarations, translations: program.translations,
                                                           options: optionSchema.definitions)
        try optionSchema.validateExpressions(using: &expressions)
        if let key = program.nameKey {
            guard program.translations.source[key]?.allSatisfy({
                if case .text = $0 { return true }; return false
            }) == true else { throw ProgramRuntimeError.invalidExpression }
        }
        guard program.onLoad.count <= ProgramLimits.maximumExpressions else { throw ProgramRuntimeError.expressionLimit }
        for assignment in program.onLoad { try expressions.validateAssignment(assignment) }
        var actionCount = program.onLoad.count
        var clickHandlers: [ElementID: ClickHandler] = [:]
        var menus: [ElementID: MenuTemplate] = [:]
        var pending = [(program.root, 1, false)], count = optionSchema.nodeCount, contentCount = 0
        var identities = Set<ElementID>()
        func validateMenu(_ items: [ProgramMenuNode], depth: Int) throws {
            guard items.count <= ProgramLimits.maximumElements - count - pending.count else { throw ProgramRuntimeError.elementLimit }
            var menuPending = items.reversed().map { ($0, depth) }
            while let (item, depth) = menuPending.popLast() {
                count += 1
                guard count <= ProgramLimits.maximumElements else { throw ProgramRuntimeError.elementLimit }
                guard depth <= ProgramLimits.maximumDepth else { throw ProgramRuntimeError.depthLimit }
                let bodies: [[ProgramMenuNode]]
                switch item {
                case .item(let item):
                    try expressions.validateText(item.title)
                    try expressions.validateCondition(item.checked)
                    try expressions.validateCondition(item.enabled)
                    guard item.actions.count <= ProgramLimits.maximumExpressions - actionCount else { throw ProgramRuntimeError.expressionLimit }
                    actionCount += item.actions.count
                    for action in item.actions { try expressions.validateAction(action) }
                    bodies = []
                case .submenu(let title, let items):
                    try expressions.validateText(title)
                    bodies = [items]
                case .divider: bodies = []
                case .conditional(let conditional):
                    guard !conditional.branches.isEmpty else { throw ProgramRuntimeError.invalidExpression }
                    for branch in conditional.branches { try expressions.validateCondition(branch.condition) }
                    bodies = [conditional.otherwise] + conditional.branches.reversed().map(\.body)
                }
                for body in bodies {
                    guard body.count <= ProgramLimits.maximumElements - count - pending.count - menuPending.count else {
                        throw ProgramRuntimeError.elementLimit
                    }
                    menuPending.append(contentsOf: body.reversed().map { ($0, depth + 1) })
                }
            }
        }
        while let (node, depth, mayPosition) = pending.popLast() {
            count += 1
            guard count <= ProgramLimits.maximumElements else { throw ProgramRuntimeError.elementLimit }
            guard depth <= ProgramLimits.maximumDepth else { throw ProgramRuntimeError.depthLimit }
            guard identities.insert(node.id).inserted else { throw ProgramRuntimeError.duplicateIdentity(node.id) }
            if case .conditional(let conditional) = node.content {
                // This is a child-list item, never an invisible box. Reject decorations rather than dropping
                // them, and validate every possible arm before any condition can select a smaller tree.
                guard depth > 1, !conditional.branches.isEmpty,
                      node.width == .fit, node.height == .fit, node.minWidth == 0, node.minHeight == 0,
                      node.maxWidth == nil, node.maxHeight == nil, node.idealSize == nil,
                      node.padding == .zero, !node.hidden, node.hiddenIf == nil,
                      node.stroke == nil, node.cornerRadius == nil, node.background == nil,
                      node.onClick == nil, node.onClickActions == nil, node.onRightClickActions == nil,
                      node.position == nil, node.voiceOver == nil, node.tooltip == nil, node.menu == nil else {
                    throw ProgramRuntimeError.invalidGeometry(node.id)
                }
                for branch in conditional.branches { try expressions.validateCondition(branch.condition) }
                for body in [conditional.otherwise] + conditional.branches.reversed().map(\.body) {
                    guard body.count <= ProgramLimits.maximumElements - count - pending.count else {
                        throw ProgramRuntimeError.elementLimit
                    }
                    // A transparent item preserves the enclosing real parent's Freeform placement contract.
                    pending.append(contentsOf: body.reversed().map { ($0, depth + 1, mayPosition) })
                }
                continue
            }
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
                let isContainer: Bool
                switch node.content {
                case .row, .column, .freeform: isContainer = true
                default: isContainer = false
                }
                clickHandlers[node.id] = ClickHandler(actions: actionsByEvent, radius: node.cornerRadius, isContainer: isContainer)
                // An empty container can still provide an interactive box, including a handler that only catches.
                if isContainer { contentCount += 1 }
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
                try expressions.validateColor(stroke.color, invalid: .invalidPaint(node.id))
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
                if try expressions.validateBackground(background, invalid: .invalidPaint(node.id)) { contentCount += 1 }
            }
            if let label = node.voiceOver { try expressions.validateText(label) }
            if let condition = node.hiddenIf { try expressions.validateCondition(condition) }
            if let tooltip = node.tooltip {
                try expressions.validateText(tooltip.text)
                if let title = tooltip.title { try expressions.validateText(title) }
                // A tooltip gives an otherwise empty real container meaningful hover content, even if empty.
                switch node.content {
                case .row, .column, .freeform: contentCount += 1
                default: break
                }
            }
            if let items = node.menu {
                try validateMenu(items, depth: depth + 1)
                menus[node.id] = MenuTemplate(items: items, radius: node.cornerRadius)
                switch node.content {
                case .row, .column, .freeform: contentCount += 1
                default: break
                }
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
                try expressions.validateColor(text.color, invalid: .invalidText(node.id))
            case .icon(let icon):
                contentCount += 1
                guard node.idealSize == nil, !icon.fontFamily.isEmpty,
                      icon.fontSize.isFinite, icon.fontSize > 0,
                      icon.fontWeight.map({ (1...999).contains($0) }) ?? true else {
                    throw ProgramRuntimeError.invalidIcon(node.id)
                }
                try expressions.validateText(icon.name)
                if case .string(let name) = icon.name, name.contains("\0") { throw ProgramRuntimeError.invalidIcon(node.id) }
                if let fontSize = icon.fontSizeExpression { try expressions.validateFontSize(fontSize) }
                try expressions.validateColor(icon.color, invalid: .invalidIcon(node.id))
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
                    try expressions.validateColor(color, invalid: .invalidPaint(node.id))
                }
            case .gauge(let gauge):
                contentCount += 1
                if node.idealSize == nil {
                    guard case .fixed = node.width, case .fixed = node.height else {
                        throw ProgramRuntimeError.invalidGeometry(node.id)
                    }
                }
                try expressions.validateGauge(gauge)
                switch gauge.thickness {
                case .number(let value)?:
                    guard value >= 0 else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                case .quantity(let value)?:
                    guard value.value >= 0 else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                default: break
                }
                for color in [gauge.color, gauge.track] {
                    try expressions.validateColor(color, invalid: .invalidPaint(node.id))
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
                try expressions.validateColor(fill, invalid: .invalidPaint(node.id))
            case .column(let spacing, _, let children), .row(let spacing, _, let children):
                guard node.idealSize == nil else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                guard spacing.isFinite, spacing >= 0 else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                guard children.count <= ProgramLimits.maximumElements - count - pending.count else { throw ProgramRuntimeError.elementLimit }
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1, false) })
            case .freeform(_, let children):
                guard node.idealSize == nil else { throw ProgramRuntimeError.invalidGeometry(node.id) }
                guard children.count <= ProgramLimits.maximumElements - count - pending.count else { throw ProgramRuntimeError.elementLimit }
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1, true) })
            case .conditional:
                throw ProgramRuntimeError.invalidGeometry(node.id) // Handled above, before box validation.
            }
        }
        guard contentCount > 0 else { throw ProgramRuntimeError.emptyProgram }
        self.program = program
        self.language = language
        self.optionSchema = optionSchema
        self.optionValues = try options.map { try optionSchema.validate($0) } ?? optionSchema.defaults
        self.clickHandlers = clickHandlers
        self.menus = menus
    }

    /// A read-only panel snapshot. Metadata never initializes variables, projects a scene or arms a clock.
    public func resolveOptions(dateInput: ProgramDateInput? = nil) throws -> ProgramOptionsSnapshot {
        try optionSchema.resolve(optionValues, revision: optionsRevision, language: language, dateInput: dateInput)
    }

    /// Replace the entire option input in the same transaction as layout, retaining session variables and onLoad state.
    /// The independent revision permits ordinary clock projections while rejecting an outdated panel write.
    public mutating func updateOptions(_ input: ProgramOptionsInput, expectedRevision: UInt64,
                                       environment: EnvironmentStamp, images: [String: ProgramImageResource] = [:],
                                       dateInput: ProgramDateInput? = nil, colorInput: ProgramColorInput? = nil,
                                       systemInput: ProgramSystemInput? = nil,
                                       measureIcon: ((IconRequest) throws -> SkinSize?)? = nil,
                                       measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> WidgetScene? {
        guard expectedRevision == optionsRevision else { return nil }
        var candidate = self
        try candidate.acceptOptionValues(optionSchema.validate(input))
        let scene = try candidate.project(environment: environment, images: images, dateInput: dateInput,
            colorInput: colorInput, systemInput: systemInput, measureIcon: measureIcon, measure: measure)
        self = candidate
        return scene
    }

    private mutating func acceptOptionValues(_ input: ProgramOptionsInput) throws {
        guard input != optionValues else { return }
        let next = optionsRevision.addingReportingOverflow(1)
        guard !next.overflow else { throw ProgramRuntimeError.optionsRevisionOverflow }
        optionValues = input
        optionsRevision = next.partialValue
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
    ///   Static hiding excludes pure display sources. Dynamic hiding conservatively includes potential display
    ///   sources: the next snapshot may show a previously hidden box. It never uses the previous frame's visibility.
    ///   Text/Icon colors, names and font sizes are part of their native measurement and remain layout dependencies.
    ///   View-if predicates and all potential arms are also collected conservatively before sampling. Selecting an
    ///   arm later limits evaluation, measurement and clocks; it does not implement inactive-arm zero sampling.
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

    /// Properties for explicitly activating a current container's primary handler, plus the resulting projection.
    /// A child covering its parent does not replace this identity target. Invalid targets require no sampling.
    public func neededSystemProperties(activatingContainer id: ElementID) -> Set<ProgramSystemProperty> {
        guard let actions = primaryContainerActions(id) else { return [] }
        var activeExpressions = actions.map(\.expression)
        return collectProperties(active: &activeExpressions, includeLayoutText: true)
    }

    /// Committed membership only: no expression evaluation. Hosts retire an opening when an owner disappears,
    /// including a zero-area root that supplies the widget's fallback menu.
    public func isMenuOwnerVisible(_ id: ElementID) -> Bool {
        variables != nil && visibleMenuOwners.contains(id)
    }

    /// Only this owner's menu display bindings, conservatively across possible arms. Closed menus never add
    /// subscriptions to the normal projection, and action arguments are sampled only when an item is selected.
    public func neededSystemProperties(openingMenu id: ElementID) -> Set<ProgramSystemProperty> {
        guard variables != nil, visibleMenuOwners.contains(id), let menu = menus[id] else { return [] }
        var active: [ProgramExpression] = [], pending = menu.items
        while let node = pending.popLast() {
            switch node {
            case .item(let item): active.append(contentsOf: [item.title, item.checked, item.enabled])
            case .submenu(let title, let items): active.append(title); pending.append(contentsOf: items)
            case .divider: break
            case .conditional(let conditional):
                active.append(contentsOf: conditional.branches.map(\.condition))
                pending.append(contentsOf: conditional.otherwise)
                for branch in conditional.branches { pending.append(contentsOf: branch.body) }
            }
        }
        return collectProperties(active: &active, includeLayoutText: false)
    }

    /// Opening reads initialized slots without changing variables, generation, the hit map or display clocks.
    /// The host owns the lifetime of this immutable opening and supplies current inputs again upon activation.
    public func resolveMenu(_ id: ElementID, expectedGeneration: UInt64, environment: EnvironmentStamp,
                            dateInput: ProgramDateInput? = nil, systemInput: ProgramSystemInput? = nil) throws -> ProgramMenuSnapshot? {
        guard variables != nil, expectedGeneration == generation, visibleMenuOwners.contains(id), let menu = menus[id] else { return nil }
        let appearance = environment.appearance.value
        guard environment.scale.isFinite, environment.scale > 0,
              [appearance.labelColor, appearance.secondaryLabelColor, appearance.tertiaryLabelColor,
               appearance.accentColor, appearance.separatorColor].allSatisfy(Self.valid) else { throw ProgramRuntimeError.invalidEnvironment }
        if let dateInput, !dateInput.instant.timeIntervalSince1970.isFinite { throw ProgramRuntimeError.invalidDateInput }
        var evaluation = ProgramExpressionEvaluation(declarations: program.declarations, dark: appearance.isDark,
                                                     variables: variables, dateInput: dateInput, systemInput: systemInput,
                                                     translations: program.translations, language: language,
                                                     options: optionSchema.definitions, optionValues: optionValues.values)
        func resolve(_ nodes: [ProgramMenuNode], path: [Int]) throws -> [ProgramMenuSnapshot.Node] {
            var result: [ProgramMenuSnapshot.Node] = []
            for (index, node) in nodes.enumerated() {
                let path = path + [index]
                switch node {
                case .item(let item):
                    let title = try evaluation.text(item.title, displayed: false).text
                    let checked = try evaluation.condition(item.checked, displayed: false)
                    let enabled = try evaluation.condition(item.enabled, displayed: false)
                    result.append(.item(id: ProgramMenuItemID(owner: id, path: path), title: title, checked: checked, enabled: enabled))
                case .submenu(let title, let items):
                    let title = try evaluation.text(title, displayed: false).text
                    result.append(.submenu(title: title, items: try resolve(items, path: path)))
                case .divider: result.append(.divider)
                case .conditional(let conditional):
                    var selected = conditional.branches.count
                    for (index, branch) in conditional.branches.enumerated() {
                        if try evaluation.condition(branch.condition, displayed: false) { selected = index; break }
                    }
                    let body = selected == conditional.branches.count ? conditional.otherwise : conditional.branches[selected].body
                    result.append(contentsOf: try resolve(body, path: path + [selected]))
                }
            }
            return result
        }
        return ProgramMenuSnapshot(owner: id, sourceGeneration: generation, items: try resolve(menu.items, path: []))
    }

    /// Sampling for one command includes only its path's branch guards, its enabled value, its actions, and the
    /// normal resulting projection. Unrelated menu titles, checked values and other commands are not activated.
    public func neededSystemProperties(activatingMenuItem id: ProgramMenuItemID) -> Set<ProgramSystemProperty> {
        guard let selection = menuSelection(id) else { return [] }
        var active = selection.item.actions.map(\.expression) + [selection.item.enabled]
        for branch in selection.branches {
            active.append(contentsOf: branch.conditional.branches.prefix(branch.index + 1).map(\.condition))
        }
        return collectProperties(active: &active, includeLayoutText: true)
    }

    private struct MenuSelection {
        let item: ProgramMenuItem
        let branches: [(conditional: ProgramMenuConditional, index: Int)]
    }

    private func menuSelection(_ id: ProgramMenuItemID) -> MenuSelection? {
        guard variables != nil, visibleMenuOwners.contains(id.owner), let menu = menus[id.owner] else { return nil }
        var nodes = menu.items, offset = 0
        var branches: [(conditional: ProgramMenuConditional, index: Int)] = []
        while offset < id.path.count {
            let index = id.path[offset]
            guard nodes.indices.contains(index) else { return nil }
            offset += 1
            switch nodes[index] {
            case .item(let item):
                guard offset == id.path.count else { return nil }
                return MenuSelection(item: item, branches: branches)
            case .submenu(_, let items): nodes = items
            case .divider: return nil
            case .conditional(let conditional):
                guard offset < id.path.count else { return nil }
                let branch = id.path[offset]
                guard branch >= 0, branch <= conditional.branches.count else { return nil }
                offset += 1
                branches.append((conditional, branch))
                nodes = branch == conditional.branches.count ? conditional.otherwise : conditional.branches[branch].body
            }
        }
        return nil
    }

    private func isSelected(_ selection: MenuSelection, evaluation: inout ProgramExpressionEvaluation) throws -> Bool {
        for branch in selection.branches {
            for earlier in branch.conditional.branches.prefix(branch.index) {
                if try evaluation.condition(earlier.condition, displayed: false) { return false }
            }
            if branch.index < branch.conditional.branches.count,
               try !evaluation.condition(branch.conditional.branches[branch.index].condition, displayed: false) { return false }
        }
        return try evaluation.condition(selection.item.enabled, displayed: false)
    }

    private func primaryContainerActions(_ id: ElementID) -> [ProgramAction]? {
        guard variables != nil, let handler = clickHandlers[id], handler.isContainer,
              let actions = handler.actions[.leftUp],
              currentHitMap.entries.contains(where: {
                  $0.elementID == id && $0.frame.width > 0 && $0.frame.height > 0 && $0.action(.leftUp) != .absent
              }) else { return nil }
        return actions
    }

    private func collectProperties(active: inout [ProgramExpression], includeLayoutText: Bool) -> Set<ProgramSystemProperty> {
        func collectColor(_ color: ProgramColor) {
            var pending = [color]
            while let color = pending.popLast() {
                if case .conditional(let condition, let yes, let no) = color {
                    active.append(condition)
                    pending.append(contentsOf: [yes, no])
                }
            }
        }
        func collectBackground(_ background: ProgramBackground) {
            var pending = [background]
            while let background = pending.popLast() {
                switch background {
                case .color(let color): collectColor(color)
                case .glass(_, let tint): if let tint { collectColor(tint) }
                case .conditional(let condition, let yes, let no):
                    active.append(condition)
                    if let no { pending.append(no) }
                    if let yes { pending.append(yes) }
                }
            }
        }
        if includeLayoutText {
            var pending = [(program.root, false)]
            while let (node, parentHidden) = pending.popLast() {
                if case .conditional(let conditional) = node.content {
                    // Even under a hidden box, the selected arm determines that box's retained layout space.
                    active.append(contentsOf: conditional.branches.map(\.condition))
                    pending.append(contentsOf: conditional.otherwise.map { ($0, parentHidden) })
                    for branch in conditional.branches { pending.append(contentsOf: branch.body.map { ($0, parentHidden) }) }
                    continue
                }
                let hidden = parentHidden || node.hidden
                if !hidden, let condition = node.hiddenIf { active.append(condition) }
                if !hidden, let label = node.voiceOver { active.append(label) }
                if !hidden, let tooltip = node.tooltip {
                    active.append(tooltip.text)
                    if let title = tooltip.title { active.append(title) }
                }
                if case .text(let text) = node.content {
                    active.append(text.value)
                    collectColor(text.color)
                    if let fontExpr = text.fontSizeExpression {
                        active.append(fontExpr)
                    }
                }
                if case .icon(let icon) = node.content {
                    active.append(icon.name)
                    collectColor(icon.color)
                    if let fontSize = icon.fontSizeExpression { active.append(fontSize) }
                }
                if case .progress(let progress) = node.content, !hidden {
                    active.append(progress.value)
                    if let total = progress.total { active.append(total) }
                    collectColor(progress.color); collectColor(progress.track)
                }
                if case .gauge(let gauge) = node.content, !hidden {
                    active.append(gauge.value)
                    active.append(contentsOf: [gauge.total, gauge.start, gauge.sweep, gauge.thickness].compactMap { $0 })
                    collectColor(gauge.color); collectColor(gauge.track)
                }
                if !hidden {
                    if let stroke = node.stroke { collectColor(stroke.color) }
                    if let background = node.background { collectBackground(background) }
                    switch node.content {
                    case .rectangle(let color), .shape(_, let color): collectColor(color)
                    default: break
                    }
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
            case .concatenate(let parts), .localized(_, let parts):
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
            case .string, .number, .quantity, .boolean, .timeNow, .appearanceDark, .option, .localCase:
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
    /// Icons require measureIcon; its nil result means an unknown symbol, while invalid measurements fail the transaction.
    public mutating func project(environment: EnvironmentStamp, images: [String: ProgramImageResource] = [:],
                                 dateInput: ProgramDateInput? = nil,
                                 colorInput: ProgramColorInput? = nil,
                                 systemInput: ProgramSystemInput? = nil,
                                 measureIcon: ((IconRequest) throws -> SkinSize?)? = nil,
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
                                                     variables: variables, dateInput: dateInput, systemInput: systemInput,
                                                     translations: program.translations, language: language,
                                                     options: optionSchema.definitions, optionValues: optionValues.values)
        if variables == nil {
            try evaluation.initialize()
            // Root startup is part of the first successful scene transaction. These local-only assignments
            // may be retried after failed measurement/layout; no external action is admitted here.
            for assignment in program.onLoad { try ActionExecutor.perform(assignment, on: &evaluation) }
        }
        let preset: SkinSize?
        if case .preset(_, let size) = program.size { preset = size } else { preset = nil }
        var layoutState = LayoutState(images: images, preset: preset)
        var visibleContent: Set<ElementID> = [], pending = [(program.root, false)]
        var accessibilityLabels: [ElementID: String] = [:]
        var toolTips: [ElementID: (info: ToolTipInfo, radius: ProgramCornerRadius?)] = [:]
        while let (node, parentHidden) = pending.popLast() {
            var hidden = parentHidden || node.hidden
            // A condition that currently hides its own box still drives its eventual recovery. A hidden ancestor
            // already owns that recovery, so descendant visibility conditions cannot keep an unrelated timer alive.
            if !hidden, let condition = node.hiddenIf { hidden = try evaluation.condition(condition) }
            layoutState.hidden[node.id] = hidden
            if !hidden, let label = node.voiceOver {
                accessibilityLabels[node.id] = try evaluation.text(label).text
            }
            if !hidden, let tooltip = node.tooltip {
                let text = try evaluation.text(tooltip.text).text
                let title = try tooltip.title.map { try evaluation.text($0).text } ?? ""
                toolTips[node.id] = (ToolTipInfo(text: text, title: title), node.cornerRadius)
            }
            if !hidden {
                layoutState.backgrounds[node.id] = try resolveBackground(node.background, evaluation: &evaluation,
                                                                         appearance: appearance, colorInput: colorInput)
            }
            switch node.content {
            case .text, .icon, .progress, .gauge: if !hidden { visibleContent.insert(node.id) }
            case .column(_, _, let children), .row(_, _, let children), .freeform(_, let children):
                let selected = try selectedChildren(children, evaluation: &evaluation, displayed: !hidden)
                layoutState.activeChildren[node.id] = selected
                pending.append(contentsOf: selected.reversed().map { ($0, hidden) })
            case .conditional: throw ProgramRuntimeError.invalidGeometry(node.id)
            default: break
            }
        }
        _ = try flexibility(program.root, into: &layoutState)
        let resolvedHidden = layoutState.hidden
        let box = try layout(program.root, proposedWidth: preset?.width, proposedHeight: preset?.height, appearance: appearance,
                             resolve: { id, text in
                                 let displayed = visibleContent.contains(id)
                                 let value = try evaluation.text(text.value, displayed: displayed)
                                 let fontSize = try text.fontSizeExpression.map { try evaluation.fontSize($0, element: id, displayed: displayed) }
                                 return TextInput(value: value.text, style: try text.drawingStyle(in: appearance, colorInput: colorInput,
                                     wrap: false, text: value, resolvedFontSize: fontSize,
                                     resolvedColor: evaluation.color(text.color, in: appearance, colorInput: colorInput, displayed: displayed)))
                             }, resolveIcon: { id, icon in
                                 guard let measureIcon else { throw ProgramRuntimeError.missingIconMeasurement(id) }
                                 let displayed = visibleContent.contains(id)
                                 let name = try evaluation.iconName(icon.name, displayed: displayed)
                                 guard name?.contains("\0") != true else { throw ProgramRuntimeError.invalidIcon(id) }
                                 let fontSize = try icon.fontSizeExpression.map { try evaluation.fontSize($0, element: id, displayed: displayed) }
                                 let request = IconRequest(name: name ?? "", style: try icon.drawingStyle(in: appearance,
                                     colorInput: colorInput, resolvedFontSize: fontSize,
                                     resolvedColor: evaluation.color(icon.color, in: appearance, colorInput: colorInput, displayed: displayed)), colors: icon.colors,
                                     appearance: environment.appearance, scale: environment.scale)
                                 let size = try name?.isEmpty == false ? measureIcon(request) : nil
                                 if let size {
                                     guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                                         throw ProgramRuntimeError.invalidMeasurement(id)
                                     }
                                 }
                                 return IconInput(request: request, naturalSize: size)
                             }, resolveProgress: { id, progress in
                                 try evaluation.progress(progress, displayed: visibleContent.contains(id))
                             }, resolveGauge: { id, gauge in
                                 try evaluation.gauge(gauge, element: id, displayed: visibleContent.contains(id))
                             }, resolveColor: { id, color in
                                 // These paints do not participate in measurement. Hidden Text/Icon colors resolve above.
                                 guard resolvedHidden[id] == false else { return .clear }
                                 return try evaluation.color(color, in: appearance, colorInput: colorInput, displayed: true)
                             }, measure: measure, state: &layoutState)
        var elements: [SceneElement] = []
        try append(box, at: SkinPoint(), accessibilityLabels: accessibilityLabels, into: &elements)
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
            let handler = clickHandlers[element.id], tooltip = toolTips[element.id]
            let menu = menus[element.id]
            guard handler != nil || tooltip != nil || menu != nil, element.frame.width > 0, element.frame.height > 0 else { continue }
            let radius = handler?.radius ?? tooltip?.radius ?? menu?.radius
            hitMap.entries.append(SkinHitMap.Entry(name: element.id.name, frame: element.frame,
                                                   shape: Self.clickShape(element.frame, radius: radius.map {
                                                       if case .points(let radius) = $0 { return .points(radius * transform.a) }
                                                       return $0
                                                   }),
                                                   container: nil, glass: nil, isButton: false,
                                                   actions: handler?.actions.mapValues { $0.isEmpty ? .caught : .runs } ?? [:],
                                                   cursor: true, cursorName: "", toolTip: tooltip?.info, elementID: element.id,
                                                   hasMenu: menu != nil))
        }
        let scene = WidgetScene(generation: next.partialValue, size: sceneSize, background: [],
                                backgroundImageDependencies: [], glass: [], elements: elements,
                                hitMap: hitMap, environment: environment)
        generation = next.partialValue
        variables = evaluation.variables
        clockPrecision = evaluation.clockPrecision
        currentHitMap = hitMap
        visibleMenuOwners = Set(elements.filter { $0.visibility == .visible && menus[$0.id] != nil }.map(\.id))
        return scene
    }

    /// Compatibility dispatch for local assignments. A handler producing external requests throws before this
    /// runtime commits; callers handling those requests must use clickWithEffects instead.
    public mutating func click(at point: SkinPoint, expectedGeneration: UInt64, environment: EnvironmentStamp,
                               images: [String: ProgramImageResource] = [:], dateInput: ProgramDateInput? = nil,
                               colorInput: ProgramColorInput? = nil,
                               systemInput: ProgramSystemInput? = nil,
                               measureIcon: ((IconRequest) throws -> SkinSize?)? = nil,
                               measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> WidgetScene? {
        var candidate = self
        guard let result = try candidate.clickWithEffects(at: point, expectedGeneration: expectedGeneration,
            environment: environment, images: images, dateInput: dateInput, colorInput: colorInput,
            systemInput: systemInput, measureIcon: measureIcon, measure: measure) else { return nil }
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
                                          measureIcon: ((IconRequest) throws -> SkinSize?)? = nil,
                                          measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> ProgramClickResult? {
        guard event == .leftUp || event == .rightUp,
              point.x.isFinite, point.y.isFinite, variables != nil, expectedGeneration == generation,
              let entry = currentHitMap.entry(at: point.x, point.y, handling: event, images: nil),
              let id = entry.elementID, let actions = clickHandlers[id]?.actions[event] else { return nil }
        return try performActions(actions, environment: environment, images: images, dateInput: dateInput,
                                  colorInput: colorInput, systemInput: systemInput, measureIcon: measureIcon, measure: measure)
    }

    /// Activate an explicitly targeted real container's primary handler, independent of child pointer hits.
    /// The current positive-area hit entry qualifies visibility and branch membership; leaves and stale scenes fail.
    public mutating func activateContainerWithEffects(_ id: ElementID, expectedGeneration: UInt64,
                                                     environment: EnvironmentStamp,
                                                     images: [String: ProgramImageResource] = [:], dateInput: ProgramDateInput? = nil,
                                                     colorInput: ProgramColorInput? = nil,
                                                     systemInput: ProgramSystemInput? = nil,
                                                     measureIcon: ((IconRequest) throws -> SkinSize?)? = nil,
                                                     measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> ProgramClickResult? {
        guard expectedGeneration == generation, let actions = primaryContainerActions(id) else { return nil }
        return try performActions(actions, environment: environment, images: images, dateInput: dateInput,
                                  colorInput: colorInput, systemInput: systemInput, measureIcon: measureIcon, measure: measure)
    }

    /// A menu selection is qualified against the current owner, current conditional branch and enabled value.
    /// The native opening's session/epoch and one-shot token are the host's responsibility, not scene generation.
    public mutating func activateMenuItemWithEffects(_ id: ProgramMenuItemID, expectedGeneration: UInt64,
                                                    environment: EnvironmentStamp,
                                                    images: [String: ProgramImageResource] = [:], dateInput: ProgramDateInput? = nil,
                                                    colorInput: ProgramColorInput? = nil, systemInput: ProgramSystemInput? = nil,
                                                    measureIcon: ((IconRequest) throws -> SkinSize?)? = nil,
                                                    measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> ProgramClickResult? {
        guard expectedGeneration == generation, let selection = menuSelection(id) else { return nil }
        return try performActions(selection.item.actions, menuSelection: selection, environment: environment,
            images: images, dateInput: dateInput, colorInput: colorInput, systemInput: systemInput,
            measureIcon: measureIcon, measure: measure)
    }

    private mutating func performActions(_ actions: [ProgramAction], menuSelection: MenuSelection? = nil, environment: EnvironmentStamp,
                                         images: [String: ProgramImageResource], dateInput: ProgramDateInput?,
                                         colorInput: ProgramColorInput?, systemInput: ProgramSystemInput?,
                                         measureIcon: ((IconRequest) throws -> SkinSize?)?,
                                         measure: (String, TextStyle, Double?) throws -> SkinSize) throws -> ProgramClickResult? {
        var candidate = self
        try colorInput?.validate()
        var evaluation = ProgramExpressionEvaluation(declarations: program.declarations, dark: environment.appearance.value.isDark,
                                                      variables: variables, dateInput: dateInput, systemInput: systemInput,
                                                      translations: program.translations, language: language,
                                                      options: optionSchema.definitions, optionValues: optionValues.values)
        if let menuSelection, try !isSelected(menuSelection, evaluation: &evaluation) { return nil }
        var effects: [ProgramEffect] = []
        for action in actions {
            if let effect = try ActionExecutor.perform(action, on: &evaluation) { effects.append(effect) }
        }
        candidate.variables = evaluation.variables
        try candidate.acceptOptionValues(ProgramOptionsInput(values: evaluation.optionValues))
        let scene = try candidate.project(environment: environment, images: images, dateInput: dateInput, colorInput: colorInput,
                                          systemInput: systemInput, measureIcon: measureIcon, measure: measure)
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

    /// A selected, resolved value for this projection only. Layout proposals and scene emission never revisit
    /// the selector tree, and a missing background is distinct from an explicitly transparent solid color.
    private enum ResolvedBackground {
        case color(RGBA)
        case glass(style: GlassStyle, tint: RGBA?)
    }

    private func resolveBackground(_ input: ProgramBackground?, evaluation: inout ProgramExpressionEvaluation,
                                   appearance: SkinAppearance, colorInput: ProgramColorInput?) throws -> ResolvedBackground? {
        var selected = input
        for _ in 0..<ProgramLimits.maximumExpressionDepth {
            guard let background = selected else { return nil }
            switch background {
            case .color(let color):
                return .color(try evaluation.color(color, in: appearance, colorInput: colorInput, displayed: true))
            case .glass(let style, let tint):
                return .glass(style: style, tint: try tint.map {
                    try evaluation.color($0, in: appearance, colorInput: colorInput, displayed: true)
                })
            case .conditional(let condition, let yes, let no):
                selected = try evaluation.condition(condition) ? yes : no
            }
        }
        throw ProgramRuntimeError.expressionDepth
    }

    private struct Box {
        let node: ProgramElement
        let hidden: Bool
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
        let gauge: ProgramGaugeValues?
        let stroke: RGBA?
        let background: ResolvedBackground?
        let image: ProgramImageResource?
        let icon: IconInput?
        let children: [(Box, SkinPoint)]
    }

    private struct Flexibility { let width: Bool; let height: Bool }
    private struct ProposalKey: Hashable { let id: ElementID; let width: Double?; let height: Double? }
    private struct TextKey: Hashable { let id: ElementID; let width: Double? }
    private struct TextInput { let value: String; let style: TextStyle }
    private struct IconInput { let request: IconRequest; let naturalSize: SkinSize? }
    /// Only this projection's pure results. Repeating a proposal uses the same measured style/size;
    /// no font or graphics resource, closure, cache or partial scene survives publication or failure.
    private struct LayoutState {
        let images: [String: ProgramImageResource]
        let preset: SkinSize?
        var hidden: [ElementID: Bool] = [:]
        var backgrounds: [ElementID: ResolvedBackground] = [:]
        /// Selected real children, in source order. Structural items never reach measurement or scene emission.
        var activeChildren: [ElementID: [ProgramElement]] = [:]
        var flex: [ElementID: Flexibility] = [:]
        var spacerAxes: [ElementID: Bool] = [:]
        var boxes: [ProposalKey: Box] = [:]
        var text: [ElementID: TextInput] = [:]
        var icons: [ElementID: IconInput] = [:]
        var measures: [TextKey: SkinSize] = [:]
        var progress: [ElementID: Double] = [:]
        var gauges: [ElementID: ProgramGaugeValues] = [:]
    }

    private func selectedChildren(_ nodes: [ProgramElement], evaluation: inout ProgramExpressionEvaluation,
                                  displayed: Bool) throws -> [ProgramElement] {
        var pending = Array(nodes.reversed()), selected: [ProgramElement] = []
        while let node = pending.popLast() {
            if case .conditional(let conditional) = node.content {
                var body = conditional.otherwise
                for branch in conditional.branches {
                    if try evaluation.condition(branch.condition, displayed: displayed) {
                        body = branch.body
                        break
                    }
                }
                pending.append(contentsOf: body.reversed())
            } else { selected.append(node) }
        }
        return selected
    }

    private func flexibility(_ node: ProgramElement, parentVertical: Bool? = nil, into state: inout LayoutState) throws -> Flexibility {
        if case .spacer = node.content {
            if let parentVertical { state.spacerAxes[node.id] = parentVertical }
            let value = Flexibility(width: parentVertical == false, height: parentVertical == true)
            state.flex[node.id] = value
            return value
        }
        let children: [ProgramElement]
        switch node.content {
        case .column, .row, .freeform:
            guard let nodes = state.activeChildren[node.id] else { throw ProgramRuntimeError.invalidGeometry(node.id) }
            children = nodes
        case .text, .image, .icon, .rectangle, .shape, .progress, .gauge, .spacer: children = []
        case .conditional: throw ProgramRuntimeError.invalidGeometry(node.id)
        }
        let childAxis: Bool?
        switch node.content { case .column: childAxis = true; case .row: childAxis = false; default: childAxis = nil }
        let descendants = try children.map { try flexibility($0, parentVertical: childAxis, into: &state) }
        let value = Flexibility(width: node.width == .fill || (node.width == .fit && descendants.contains { $0.width }),
                                height: node.height == .fill || (node.height == .fit && descendants.contains { $0.height }))
        state.flex[node.id] = value
        return value
    }

    private func layout(_ node: ProgramElement, proposedWidth: Double?, proposedHeight: Double?, appearance: SkinAppearance,
                        resolve: (ElementID, ProgramText) throws -> TextInput,
                        resolveIcon: (ElementID, ProgramIcon) throws -> IconInput,
                        resolveProgress: (ElementID, ProgramProgress) throws -> Double,
                        resolveGauge: (ElementID, ProgramGauge) throws -> ProgramGaugeValues,
                        resolveColor: (ElementID, ProgramColor) throws -> RGBA,
                        measure: (String, TextStyle, Double?) throws -> SkinSize, state: inout LayoutState) throws -> Box {
        let key = ProposalKey(id: node.id, width: proposedWidth, height: proposedHeight)
        if let old = state.boxes[key] { return old }
        guard let flexible = state.flex[node.id], let hidden = state.hidden[node.id] else { throw ProgramRuntimeError.invalidGeometry(node.id) }
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
            fill: RGBA?, track: RGBA?, fraction: Double?, gaugeValues: ProgramGaugeValues?, image: ProgramImageResource?, iconInput: IconInput?
        var children: [(Box, SkinPoint)] = []
        var minimumContent = SkinSize()
        switch node.content {
        case .conditional: throw ProgramRuntimeError.invalidGeometry(node.id)
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
        case .icon(let icon):
            let input: IconInput
            if let old = state.icons[node.id] { input = old }
            else { input = try resolveIcon(node.id, icon); state.icons[node.id] = input }
            iconInput = input
            let natural = input.naturalSize ?? SkinSize()
            width = try requestedWidth ?? clamp(sum([natural.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([natural.height, vertical]), minimum: minHeight, maximum: maxHeight)
            minimumContent = SkinSize(width: max(0, width - horizontal), height: max(0, height - vertical))
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
            fill = try resolveColor(node.id, color)
            minimumContent = SkinSize(width: max(0, width - horizontal), height: max(0, height - vertical))
        case .progress(let progress):
            let ideal = node.idealSize ?? SkinSize()
            width = try requestedWidth ?? clamp(sum([ideal.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([ideal.height, vertical]), minimum: minHeight, maximum: maxHeight)
            fill = try resolveColor(node.id, progress.color)
            track = try resolveColor(node.id, progress.track)
            if let cached = state.progress[node.id] { fraction = cached }
            else {
                let value = try resolveProgress(node.id, progress)
                state.progress[node.id] = value; fraction = value
            }
            minimumContent = SkinSize(width: max(0, width - horizontal), height: max(0, height - vertical))
        case .gauge(let gauge):
            let ideal = node.idealSize ?? SkinSize()
            width = try requestedWidth ?? clamp(sum([ideal.width, horizontal]), minimum: minWidth, maximum: maxWidth)
            height = try requestedHeight ?? clamp(sum([ideal.height, vertical]), minimum: minHeight, maximum: maxHeight)
            fill = try resolveColor(node.id, gauge.color)
            track = try resolveColor(node.id, gauge.track)
            if let cached = state.gauges[node.id] { gaugeValues = cached }
            else {
                let value = try resolveGauge(node.id, gauge)
                state.gauges[node.id] = value; gaugeValues = value
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
        case .column(let spacing, _, _), .row(let spacing, _, _):
            guard let nodes = state.activeChildren[node.id] else { throw ProgramRuntimeError.invalidGeometry(node.id) }
            let column: Bool
            if case .column = node.content { column = true } else { column = false }
            let gap = try sum([spacing * Double(max(0, nodes.count - 1))])
            let crossPadding = column ? horizontal : vertical
            let mainPadding = column ? vertical : horizontal
            let offeredCross = column ? offeredWidth : offeredHeight
            let initialCross = offeredCross.map { max(0, $0 - crossPadding) }
            var boxes = try nodes.map {
                try layout($0, proposedWidth: column ? initialCross : nil, proposedHeight: column ? nil : initialCross,
                           appearance: appearance, resolve: resolve, resolveIcon: resolveIcon, resolveProgress: resolveProgress, resolveGauge: resolveGauge, resolveColor: resolveColor,
                           measure: measure, state: &state)
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
                               appearance: appearance, resolve: resolve, resolveIcon: resolveIcon, resolveProgress: resolveProgress, resolveGauge: resolveGauge, resolveColor: resolveColor,
                               measure: measure, state: &state)
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
                                              appearance: appearance, resolve: resolve, resolveIcon: resolveIcon, resolveProgress: resolveProgress, resolveGauge: resolveGauge, resolveColor: resolveColor,
                                              measure: measure, state: &state)
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
                                   appearance: appearance, resolve: resolve, resolveIcon: resolveIcon, resolveProgress: resolveProgress, resolveGauge: resolveGauge, resolveColor: resolveColor,
                                   measure: measure, state: &state)
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
        case .freeform(let align, _):
            guard let nodes = state.activeChildren[node.id] else { throw ProgramRuntimeError.invalidGeometry(node.id) }
            let initialWidth = offeredWidth.map { max(0, $0 - horizontal) }
            let initialHeight = offeredHeight.map { max(0, $0 - vertical) }
            let knownWidth = requestedWidth.map { max(0, $0 - horizontal) }
            let knownHeight = requestedHeight.map { max(0, $0 - vertical) }
            var boxes = try nodes.map { child in
                let positioned = child.position != nil
                return try layout(child,
                    proposedWidth: positioned ? (child.width == .fill ? knownWidth : nil) : initialWidth,
                    proposedHeight: positioned ? (child.height == .fill ? knownHeight : nil) : initialHeight,
                    appearance: appearance, resolve: resolve, resolveIcon: resolveIcon, resolveProgress: resolveProgress, resolveGauge: resolveGauge, resolveColor: resolveColor,
                    measure: measure, state: &state)
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
                                          appearance: appearance, resolve: resolve, resolveIcon: resolveIcon, resolveProgress: resolveProgress, resolveGauge: resolveGauge, resolveColor: resolveColor,
                                          measure: measure, state: &state)
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
            case .text, .image, .icon, .rectangle, .shape, .freeform, .progress, .gauge, .spacer, .conditional: break
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
        let box = Box(node: node, hidden: hidden, size: SkinSize(width: width, height: height), minimum: minimumSize,
                      layoutBounds: layoutBounds,
                      content: SkinRect(x: p.left, y: p.top, width: innerWidth,
                                        height: max(innerHeight, textSize?.height ?? 0)),
                      style: style, text: resolvedText, textSize: textSize, fill: fill, track: track, progress: fraction, gauge: gaugeValues,
                      stroke: try node.stroke.map { try resolveColor(node.id, $0.color) },
                      background: state.backgrounds[node.id], image: image, icon: iconInput, children: children)
        state.boxes[key] = box
        return box
    }

    private func append(_ box: Box, at point: SkinPoint,
                        accessibilityLabels: [ElementID: String], into elements: inout [SceneElement]) throws {
        let hidden = box.hidden
        let frame = SkinRect(x: point.x, y: point.y, width: box.size.width, height: box.size.height)
        guard [frame.x, frame.y, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
            throw ProgramRuntimeError.layoutOverflow(box.node.id)
        }
        var items: [DrawItem] = []
        let kind: ElementKind
        var imageDependencies: [ImageDependency] = []
        switch box.node.content {
        case .conditional: throw ProgramRuntimeError.invalidGeometry(box.node.id)
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
        case .icon(let icon):
            kind = .image
            guard let input = box.icon else { throw ProgramRuntimeError.invalidIcon(box.node.id) }
            if !hidden {
                let content = SkinRect(x: point.x + box.content.x, y: point.y + box.content.y,
                                       width: box.content.width, height: box.content.height)
                if let drawing = try iconDrawing(icon, input: input, in: content, node: box.node) { items = [.icon(drawing)] }
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
        case .gauge(let gauge):
            kind = .roundline
            guard let fill = box.fill, let track = box.track, let values = box.gauge else {
                throw ProgramRuntimeError.invalidPaint(box.node.id)
            }
            if !hidden {
                let content = SkinRect(x: point.x + box.content.x, y: point.y + box.content.y,
                                       width: box.content.width, height: box.content.height)
                guard [content.x, content.y, content.width, content.height, content.maxX, content.maxY].allSatisfy(\.isFinite) else {
                    throw ProgramRuntimeError.layoutOverflow(box.node.id)
                }
                if content.width > 0, content.height > 0 {
                    items = try gaugeDrawing(gauge, values: values, color: fill, track: track, in: content, element: box.node.id)
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
            switch box.background {
            case .color(let color):
                if radius == 0 { items.insert(.fill(frame, Paint(color: color)), at: 0) }
                else {
                    let geometry = ShapeGeometry.path(ShapePath(subpaths: [ShapeGeometryBuilder.rectangle(
                        x: 0, y: 0, width: frame.width, height: frame.height, radiusX: radius)], fillRule: .nonZero))
                    let bounds = ShapeRect(minX: 0, minY: 0, maxX: frame.width, maxY: frame.height)
                    let shape = ShapeItem(index: 0, geometry: geometry, closed: true, fill: .color(color), stroke: .none,
                        strokeStyle: ShapeStrokeStyle(), strokePlan: nil, paintTransform: .identity, bounds: bounds, visualBounds: bounds)
                    items.insert(.shape(ShapeDraw(shapes: [shape], contentFrame: frame)), at: 0)
                }
            case .glass(let style, let tint):
                glass = GlassRegion(id: "desk-background:\(box.node.id.index):\(box.node.id.name)", rect: frame,
                                    cornerRadius: radius, style: style, tint: tint)
            case nil: break
            }
        }
        elements.append(SceneElement(id: box.node.id, kind: kind, frame: frame, anchor: point,
                                     visibility: hidden ? .hiddenKeepsSpace : .visible, container: nil, isContainer: false,
                                     items: items, glass: glass, imageDependencies: imageDependencies,
                                     backing: glass == nil ? .content : .native(.glass),
                                     accessibilityLabel: accessibilityLabels[box.node.id]))
        for (child, offset) in box.children {
            try append(child, at: SkinPoint(x: point.x + offset.x, y: point.y + offset.y),
                       accessibilityLabels: accessibilityLabels, into: &elements)
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
                if case .icon(let draw) = item { try include(draw.contentFrame, element: element.id) }
                if case .shape(let draw) = item {
                    for shape in draw.shapes where shape.fill.isVisible || (shape.stroke.isVisible && shape.strokePlan?.isEmpty == false) {
                        let bounds = shape.visualBounds
                        try include(SkinRect(x: draw.contentFrame.x + bounds.minX, y: draw.contentFrame.y + bounds.minY,
                                             width: bounds.width, height: bounds.height), element: element.id)
                    }
                }
            }
        }
        var pending = [(box, SkinPoint())]
        while let (current, point) = pending.popLast() {
            if current.hidden { continue }
            try include(SkinRect(x: point.x + current.layoutBounds.x, y: point.y + current.layoutBounds.y,
                                 width: current.layoutBounds.width, height: current.layoutBounds.height), element: current.node.id)
            if let text = current.textSize {
                try include(SkinRect(x: point.x + current.content.x, y: point.y + current.content.y,
                                     width: text.width, height: text.height), element: current.node.id)
            }
            pending.append(contentsOf: current.children.map {
                ($0.0, SkinPoint(x: point.x + $0.1.x, y: point.y + $0.1.y))
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

    private func iconDrawing(_ icon: ProgramIcon, input: IconInput, in content: SkinRect,
                             node: ProgramElement) throws -> IconDraw? {
        guard let natural = input.naturalSize else { return nil }
        var size = natural
        if case .fixed = node.width, case .fixed = node.height, !icon.hasOwnFont {
            guard content.width > 0, content.height > 0 else { return nil }
            // Normalize first so fitting a finite box cannot overflow a scale when the measured symbol is tiny.
            let longest = max(natural.width, natural.height)
            let width = natural.width / longest, height = natural.height / longest
            let scale = min(content.width / width, content.height / height)
            size = SkinSize(width: width * scale, height: height * scale)
        }
        let x: Double
        switch icon.align {
        case .left: x = content.x
        case .center: x = content.x + (content.width - size.width) / 2
        case .right: x = content.x + content.width - size.width
        }
        let rect = SkinRect(x: x, y: content.y + (content.height - size.height) / 2, width: size.width, height: size.height)
        guard [rect.x, rect.y, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
              rect.width >= 0, rect.height >= 0 else { throw ProgramRuntimeError.layoutOverflow(node.id) }
        guard rect.width > 0, rect.height > 0 else { return nil }
        return IconDraw(request: input.request, naturalSize: natural, contentFrame: rect)
    }

    /// Gauge ink stays inside the content box, so box layout, viewport, background and hit geometry share the
    /// same final preset transform. This deliberately does not apply INI option clamps or minimum arc patches.
    private func gaugeDrawing(_ gauge: ProgramGauge, values: ProgramGaugeValues, color: RGBA, track: RGBA,
                              in content: SkinRect, element: ElementID) throws -> [DrawItem] {
        let radius = min(content.width, content.height) / 2
        let thickness = min(values.thickness, radius)
        let cx = content.x + content.width / 2, cy = content.y + content.height / 2
        guard [cx, cy, radius, cx - radius, cx + radius, cy - radius, cy + radius].allSatisfy(\.isFinite) else {
            throw ProgramRuntimeError.layoutOverflow(element)
        }
        guard radius > 0 else { return [] }
        let startDegrees = values.start.truncatingRemainder(dividingBy: 360)
        let radians = Double.pi / 180
        let start = (startDegrees - 90) * radians
        var items: [DrawItem] = []
        func sector(_ travel: Double, color: RGBA) {
            let inner = gauge.shape == .pie ? 0 : radius - thickness
            guard travel != 0, radius > inner else { return }
            // Preserve multi-turn progress: e.g. 720 degrees at one quarter is a half circle.
            let sweep = min(max(travel, -360), 360) * radians
            guard sweep != 0 else { return }
            items.append(.roundline(RoundlineDraw(shape: .sector(centerX: cx, centerY: cy,
                innerRadius: inner, outerRadius: radius, startAngle: start, sweep: sweep), color: color,
                antiAlias: true, roundCaps: gauge.shape != .pie)))
        }
        sector(values.sweep, color: track)
        guard let fraction = values.fraction else { return items }
        let travel = values.sweep * fraction
        if gauge.shape == .needle {
            guard thickness > 0 else { return items }
            // Reduce both finite terms before adding; enormous authored angles never overflow this sum.
            let angle = (startDegrees + travel.truncatingRemainder(dividingBy: 360) - 90) * radians
            let tip = RoundMeterMath.point(centerX: cx, centerY: cy, radius: radius - thickness / 2, angle: angle)
            guard tip.x.isFinite, tip.y.isFinite else { throw ProgramRuntimeError.layoutOverflow(element) }
            items.append(.roundline(RoundlineDraw(shape: .line(x1: cx, y1: cy, x2: tip.x, y2: tip.y,
                                                              width: thickness), color: color, antiAlias: true)))
        } else if fraction > 0 { sector(travel, color: color) }
        return items
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
