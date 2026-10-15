import Foundation
import DesksetCore

/// An address in one published program. Field names follow the public Core IR; array offsets are decimal
/// components. Expression children use "children", offset in operand order (condition/then/otherwise for
/// conditionals). Only the element root is stable across compilations; the rest of a path is snapshot-local.
public struct DeskIRNodePath: Hashable, Sendable {
    public let element: TemplateID?
    public let components: [String]
    public init(element: TemplateID? = nil, components: [String] = []) {
        self.element = element; self.components = components
    }
    public func appending(_ components: String...) -> Self {
        Self(element: element, components: self.components + components)
    }
    /// The runtime's actual menu command address, not its displayed row index or title.
    public static func menuItem(_ id: ProgramMenuItemID) -> Self {
        Self(element: TemplateID(id.owner.index), components: ["menuItem"] + id.path.map(String.init))
    }
}

public struct DeskIRSourceSite: Sendable {
    public let reference: NodeID
    public let source: DeskSourceRange
}

/// Index the validated lowering shape, not all AST nodes indiscriminately. Defaults and synthesized IR
/// descendants point at their enclosing authored expression/call; facet origins separately identify styles.
/// This does not execute, recheck, or infer identity from expression equality or displayed strings.
struct DeskIRSourceIndex {
    private(set) var sites: [DeskIRNodePath: DeskIRSourceSite] = [:]
    private let checked: CheckedFile
    private let sources: [Int: CheckedFile]
    private let references: [ElementID: NodeID]
    private let syntax: [NodeID: PositionedNode]

    init(program: WidgetProgram, checked: CheckedFile, sources: [Int: CheckedFile],
         references: [ElementID: NodeID]) throws {
        self.checked = checked; self.sources = sources; self.references = references
        var syntax: [NodeID: PositionedNode] = [:]
        for source in sources.values {
            var pending = [source.tree.rootNode]
            while let node = pending.popLast() {
                syntax[source.tree.id(of: node)] = node
                pending.append(contentsOf: node.childNodes)
            }
        }
        self.syntax = syntax
        let widget = checked.tree.rootNode.childNodes.compactMap(TopLevelBlockSyntax.init)
            .first { $0.node.kind == .widgetBlock }!.block
        let root = DeskIRNodePath()
        put(root, widget.node, checked)
        let declarations = widget.items.compactMap(DeclarationSyntax.init)
        try require(declarations.count == program.declarations.count, widget.node)
        for (i, value) in program.declarations.enumerated() {
            let path = root.appending("declarations", String(i)), syntax = declarations[i]
            put(path, syntax.node, checked)
            expression(value.initial, at: path.appending("initial"), source: syntax.initializer.node, checked)
        }
        try element(program.root)
        let rootSource = references[program.root.id].flatMap { syntax[$0] }
        let onLoad = rootSource.flatMap(CallStmtSyntax.init)?.modifiers.first { $0.name.token.text == "onLoad" }?.block?.items ?? []
        try require(onLoad.count == program.onLoad.count, widget.node)
        for (i, assignment) in program.onLoad.enumerated() {
            let path = root.appending("onLoad", String(i)), node = onLoad[i]
            put(path, node, checked)
            expression(assignment.value, at: path.appending("value"), source: AssignmentSyntax(node)!.value.node, checked)
        }
        // Effective option order is local declarations followed by unreplaced package declarations; Sections
        // (including empty Sections) remain in authored order. Keep the original definition file for each site.
        var optionSources: [(PositionedNode, CheckedFile)] = []
        let package = sources.values.first { DeskPackagePath.isPackageFile($0.tree.file.path) }
        for source in [checked] + (package.map { [$0] } ?? []) {
            for block in source.tree.rootNode.childNodes.compactMap(TopLevelBlockSyntax.init) where block.node.kind == .optionsBlock {
                optionSources += block.block.items.compactMap { node in
                    if source.tree.file != checked.tree.file, let option = OptionDeclSyntax(node), checked.options[option.target.name.token.name] != nil { return nil }
                    return (node, source)
                }
            }
        }
        try options(program.options, syntax: optionSources, at: root.appending("options"))
    }

    private mutating func put(_ path: DeskIRNodePath, _ node: PositionedNode, _ source: CheckedFile) {
        sites[path] = DeskIRSourceSite(reference: source.tree.id(of: node),
                                      source: DeskSourceRange(file: source.tree.file, range: node.textRange))
    }
    private func require(_ condition: Bool, _ node: PositionedNode) throws {
        guard condition else {
            throw DeskCompilationIssue(kind: .invalidCheckedModel, file: checked.tree.file, range: node.textRange,
                                       message: "Lowered IR does not match its source path")
        }
    }
    private func argument(_ node: PositionedNode, _ label: String? = nil) -> PositionedNode {
        CallStmtSyntax(node)?.arguments?.arguments.first { $0.label?.name == label }?.value.node ?? node
    }

    private mutating func expression(_ value: ProgramExpression, at path: DeskIRNodePath,
                                     source node: PositionedNode, _ source: CheckedFile) {
        put(path, node, source)
        let children: [ProgramExpression]
        switch value {
        case .dateIn(let v, _), .formatDate(let v, _), .formatNumber(let v, _), .not(let v), .negate(let v), .isMissing(let v): children = [v]
        case .concatenate(let values), .localized(_, let values): children = values
        case .add(let a, let b), .subtract(let a, let b), .multiply(let a, let b), .divide(let a, let b), .remainder(let a, let b),
             .and(let a, let b), .or(let a, let b), .equal(let a, let b), .notEqual(let a, let b), .less(let a, let b),
             .lessOrEqual(let a, let b), .greater(let a, let b), .greaterOrEqual(let a, let b), .ifMissing(let a, let b): children = [a, b]
        case .conditional(let condition, let yes, let no): children = [condition, yes, no]
        case .string, .boolean, .number, .quantity, .declaration, .option, .localCase, .appearanceDark, .timeNow, .systemProperty: children = []
        }
        // A generated formatting/coercion node need not correspond one-to-one with syntax. Its descendants
        // retain the defining expression's range rather than guessing a different source from equal values.
        for (i, child) in children.enumerated() { expression(child, at: path.appending("children", String(i)), source: node, source) }
    }
    private mutating func color(_ value: ProgramColor, at path: DeskIRNodePath, source node: PositionedNode) {
        put(path, node, checked)
        if case .conditional(let condition, let yes, let no) = value {
            expression(condition, at: path.appending("condition"), source: node, checked)
            color(yes, at: path.appending("then"), source: node)
            color(no, at: path.appending("otherwise"), source: node)
        }
    }
    private mutating func background(_ value: ProgramBackground, at path: DeskIRNodePath, source node: PositionedNode) {
        put(path, node, checked)
        switch value {
        case .color(let value): color(value, at: path.appending("color"), source: node)
        case .glass(_, let tint): if let tint { color(tint, at: path.appending("tint"), source: node) }
        case .conditional(let condition, let yes, let no):
            expression(condition, at: path.appending("condition"), source: node, checked)
            if let yes { background(yes, at: path.appending("then"), source: node) }
            if let no { background(no, at: path.appending("otherwise"), source: node) }
        }
    }

    private mutating func element(_ value: ProgramElement) throws {
        guard let ref = references[value.id], let node = syntax[ref] else {
            try require(false, checked.tree.rootNode); return
        }
        let path = DeskIRNodePath(element: TemplateID(value.id.index))
        put(path, node, checked); put(path.appending("content"), node, checked)
        let call = CallStmtSyntax(node)
        for (field, event, actions) in [("onClickActions", "onClick", value.onClickActions),
                                        ("onRightClickActions", "onRightClick", value.onRightClickActions)] {
            if let actions {
                let statements = call?.modifiers.first { $0.name.token.text == event }?.block?.items ?? []
                try actionList(actions, syntax: statements, at: path.appending(field))
            }
        }
        if let assignments = value.onClick {
            let statements = call?.modifiers.first { $0.name.token.text == "onClick" }?.block?.items ?? []
            try actionList(assignments.map(ProgramAction.assign), syntax: statements, at: path.appending("onClick"))
        }
        if let stroke = value.stroke {
            put(path.appending("stroke"), node, checked)
            color(stroke.color, at: path.appending("stroke", "color"), source: node)
        }
        if let menu = value.menu {
            let statements = call?.modifiers.first { $0.name.token.text == "menu" }?.block?.items ?? []
            try menuList(menu, syntax: statements, at: path.appending("menu"), owner: value.id, indices: [])
        }
        for (field, expression) in [("voiceOver", value.voiceOver), ("hiddenIf", value.hiddenIf)] {
            if let expression { self.expression(expression, at: path.appending(field), source: node, checked) }
        }
        if let tooltip = value.tooltip {
            put(path.appending("tooltip"), node, checked)
            expression(tooltip.text, at: path.appending("tooltip", "text"), source: node, checked)
            if let title = tooltip.title { expression(title, at: path.appending("tooltip", "title"), source: node, checked) }
        }
        if let background = value.background { self.background(background, at: path.appending("background"), source: node) }
        let content = path.appending("content")
        switch value.content {
        case .text(let text):
            expression(text.value, at: content.appending("value"), source: argument(node), checked)
            if let size = text.fontSizeExpression { expression(size, at: content.appending("fontSizeExpression"), source: node, checked) }
            color(text.color, at: content.appending("color"), source: node)
        case .icon(let icon):
            expression(icon.name, at: content.appending("name"), source: argument(node), checked)
            if let size = icon.fontSizeExpression { expression(size, at: content.appending("fontSizeExpression"), source: node, checked) }
            color(icon.color, at: content.appending("color"), source: node)
        case .progress(let progress):
            expression(progress.value, at: content.appending("value"), source: argument(node), checked)
            if let total = progress.total { expression(total, at: content.appending("total"), source: argument(node, "total"), checked) }
            color(progress.color, at: content.appending("color"), source: node); color(progress.track, at: content.appending("track"), source: node)
        case .gauge(let gauge):
            expression(gauge.value, at: content.appending("value"), source: argument(node), checked)
            for (field, value) in [("total", gauge.total), ("start", gauge.start), ("sweep", gauge.sweep), ("thickness", gauge.thickness)] {
                if let value { expression(value, at: content.appending(field), source: argument(node, field), checked) }
            }
            color(gauge.color, at: content.appending("color"), source: node); color(gauge.track, at: content.appending("track"), source: node)
        case .rectangle(let fill), .shape(_, let fill): color(fill, at: content.appending("fill"), source: node)
        case .column(_, _, let children), .row(_, _, let children), .freeform(_, let children):
            for child in children { try element(child) }
        case .conditional(let conditional):
            let (arms, otherwise) = conditionalSyntax(node)
            try require(arms.count == conditional.branches.count, node)
            for (i, branch) in conditional.branches.enumerated() {
                let branchPath = content.appending("branches", String(i))
                put(branchPath, arms[i].node, checked)
                expression(branch.condition, at: branchPath.appending("condition"), source: arms[i].condition.node, checked)
                for child in branch.body { try element(child) }
            }
            if let otherwise { put(content.appending("otherwise"), otherwise.node, checked) }
            for child in conditional.otherwise { try element(child) }
        case .image, .spacer: break
        }
    }

    private func conditionalSyntax(_ node: PositionedNode) -> ([IfStmtSyntax], BlockSyntax?) {
        var arms: [IfStmtSyntax] = [], current = IfStmtSyntax(node), otherwise: BlockSyntax?
        while let syntax = current {
            arms.append(syntax); current = nil
            if let clause = syntax.elseClause {
                current = IfStmtSyntax(clause.body)
                otherwise = BlockSyntax(clause.body)
            }
        }
        return (arms, otherwise)
    }
    private mutating func actionList(_ values: [ProgramAction], syntax: [PositionedNode], at path: DeskIRNodePath) throws {
        try require(values.count == syntax.count, checked.tree.rootNode)
        for (i, value) in values.enumerated() {
            let node = syntax[i], item = path.appending(String(i))
            put(item, node, checked)
            let expression: ProgramExpression
            switch value {
            case .assign(let assignment): expression = assignment.value
            case .assignOption(_, let value), .copy(let value), .open(let value): expression = value
            }
            self.expression(expression, at: item.appending("value"), source: AssignmentSyntax(node)?.value.node ?? argument(node), checked)
        }
    }
    private mutating func menuList(_ values: [ProgramMenuNode], syntax: [PositionedNode], at path: DeskIRNodePath,
                                   owner: ElementID, indices: [Int]) throws {
        try require(values.count == syntax.count, checked.tree.rootNode)
        for (i, value) in values.enumerated() {
            let node = syntax[i], item = path.appending(String(i)), index = indices + [i]
            put(item, node, checked)
            put(.menuItem(ProgramMenuItemID(owner: owner, path: index)), node, checked)
            switch value {
            case .divider: break
            case .item(let value):
                expression(value.title, at: item.appending("title"), source: argument(node), checked)
                expression(value.checked, at: item.appending("checked"), source: argument(node, "checked"), checked)
                expression(value.enabled, at: item.appending("enabled"), source: argument(node, "enabled"), checked)
                let actions = CallStmtSyntax(node)?.modifiers.first?.block?.items ?? []
                try actionList(value.actions, syntax: actions, at: item.appending("actions"))
            case .submenu(let title, let items):
                expression(title, at: item.appending("title"), source: argument(node), checked)
                try menuList(items, syntax: CallStmtSyntax(node)!.block!.items, at: item.appending("items"), owner: owner, indices: index)
            case .conditional(let value):
                let (arms, otherwise) = conditionalSyntax(node)
                try require(arms.count == value.branches.count, node)
                for (j, arm) in value.branches.enumerated() {
                    let branch = item.appending("branches", String(j))
                    put(branch, arms[j].node, checked)
                    expression(arm.condition, at: branch.appending("condition"), source: arms[j].condition.node, checked)
                    try menuList(arm.body, syntax: arms[j].block.items, at: branch.appending("body"), owner: owner, indices: index + [j])
                }
                try menuList(value.otherwise, syntax: otherwise?.items ?? [], at: item.appending("otherwise"), owner: owner, indices: index + [arms.count])
            }
        }
    }

    private mutating func options(_ values: [ProgramOptionNode], syntax: [(PositionedNode, CheckedFile)], at path: DeskIRNodePath) throws {
        try require(values.count == syntax.count, checked.tree.rootNode)
        for (i, value) in values.enumerated() {
            let (node, source) = syntax[i], item = path.appending(String(i))
            put(item, node, source)
            switch value {
            case .section(let title, let items):
                let call = CallStmtSyntax(node)!
                expression(title, at: item.appending("title"), source: argument(node), source)
                let children = call.block!.items.filter { child in
                    guard source.tree.file != checked.tree.file, let declaration = OptionDeclSyntax(child) else { return true }
                    return checked.options[declaration.target.name.token.name] == nil
                }.map { ($0, source) }
                try options(items, syntax: children, at: item.appending("items"))
            case .option(let option):
                let control = OptionDeclSyntax(node)!.controlCall!.node
                expression(option.title, at: item.appending("title"), source: argument(control), source)
                if let help = option.help { expression(help, at: item.appending("help"), source: node, source) }
                if let hidden = option.hiddenIf { expression(hidden, at: item.appending("hiddenIf"), source: node, source) }
                put(item.appending("control"), control, source)
                put(item.appending("defaultValue"), argument(control, "default"), source)
                switch option.control {
                case .input(let placeholder):
                    if let placeholder { expression(placeholder, at: item.appending("control", "placeholder"), source: argument(control, "placeholder"), source) }
                case .picker(let choices):
                    for (j, choice) in choices.enumerated() {
                        let choicePath = item.appending("control", "choices", String(j))
                        put(choicePath, control, source)
                        expression(choice.title, at: choicePath.appending("title"), source: argument(control, "choices"), source)
                    }
                case .toggle, .slider, .stepper: break
                }
            }
        }
    }
}
