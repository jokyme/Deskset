import Foundation

// The Options panel of each widget (§4.13, §5.4, DESK-DESIGN §3.4): its `options { }` block, with the package's
// options merged in — a widget option of the same name replaces the package's for that widget (D99) — and where each
// value is stored when a widget is placed several times: widget options and `saved` values per placed widget,
// package options once per package, secrets in the Keychain.

/// A choice of a Picker.
public struct DeskOptionChoice: Sendable, Hashable {
    /// As written: `.sunday`, `"Mon"`, `7`.
    public var value: String
    /// The `Choice` label, else the catalog's title, else the name in words (`.darkBlue` → "Dark Blue").
    public var label: String
    public var displayLabel: String
    /// The key a translation of `label` uses; nil when the label is not written in the file.
    public var labelKey: String?

    public init(value: String, label: String, displayLabel: String, labelKey: String?) {
        self.value = value
        self.label = label
        self.displayLabel = displayLabel
        self.labelKey = labelKey
    }
}

/// The condition under which a control is hidden (`.hidden(if:)`, or the older `.visible(if:)`).
public struct DeskOptionCondition: Sendable, Hashable {
    /// As written.
    public var text: String
    /// The options it reads.
    public var options: [String]
    /// True for `.hidden(if:)`; false for `.visible(if:)`, which hides the control while the condition is false.
    public var hidesWhenTrue: Bool

    public init(text: String, options: [String], hidesWhenTrue: Bool) {
        self.text = text
        self.options = options
        self.hidesWhenTrue = hidesWhenTrue
    }
}

/// A titled group of the panel (`Section("Colors") { … }`).
public struct DeskOptionSection: Sendable, Hashable {
    public var title: String
    public var displayTitle: String
    public var scope: OptionFacts.Scope

    public init(title: String, displayTitle: String, scope: OptionFacts.Scope) {
        self.title = title
        self.displayTitle = displayTitle
        self.scope = scope
    }
}

/// One control of the panel.
public struct DeskOptionItem: Sendable, Hashable {
    public var name: String
    /// Its place in the panel, from 0.
    public var order: Int
    /// Its section in `DeskOptionsSchema.sections`, nil outside any.
    public var section: Int?
    public var label: String
    public var displayLabel: String
    public var help: String?
    public var displayHelp: String?
    /// `Picker`, `Toggle`, `Slider`…
    public var control: String
    public var panel: PanelControl
    /// What kind of value it holds, for people ("a color", "a number").
    public var typeName: LocalizedText
    /// The value it starts with, as Desk text: the written `default:` or the control's own; nil for a picture, a
    /// folder or a secret, which are missing until the user chooses.
    public var defaultValue: String?
    public var defaultIsWritten: Bool
    public var choices: [DeskOptionChoice]
    public var minimum: String?
    public var maximum: String?
    public var step: String?
    public var placeholder: String?
    /// Only the user can set it, in the panel: a secret, a folder, a picture, or a whole command (§4.13).
    public var userOnly: Bool
    /// A secret: kept in the Keychain.
    public var isSecret: Bool
    public var hiddenIf: DeskOptionCondition?
    public var scope: OptionFacts.Scope
    /// A widget option that replaces the package's option of the same name for this widget (D99).
    public var replacesPackageOption: Bool
    /// The option's name where it is declared.
    public var declaration: DeskSite

    /// A Picker with up to three choices shows a segmented control, else a pop-up menu.
    public var isSegmented: Bool { control == "Picker" && choices.count <= 3 }
}

/// Where the values of a widget placed several times are kept, and the limits (§8.4).
public struct DeskOptionStorage: Sendable, Hashable {
    /// Options kept for each placed widget.
    public var perInstance: [String]
    /// `saved` values, kept for each placed widget.
    public var savedValues: [String]
    /// Package options, kept once per installed package and shared by its widgets.
    public var perPackage: [String]
    /// Secret options, kept in the Keychain (per placed widget, or per package for a package option).
    public var keychain: [String]
    /// Bytes of one stored value.
    public var maximumValueBytes: Int
    /// Bytes of everything one placed widget stores.
    public var maximumInstanceBytes: Int

    public init(perInstance: [String] = [], savedValues: [String] = [], perPackage: [String] = [], keychain: [String] = [],
                maximumValueBytes: Int, maximumInstanceBytes: Int) {
        self.perInstance = perInstance
        self.savedValues = savedValues
        self.perPackage = perPackage
        self.keychain = keychain
        self.maximumValueBytes = maximumValueBytes
        self.maximumInstanceBytes = maximumInstanceBytes
    }
}

/// The Options panel of a widget, or the package's page (`widget == nil`).
public struct DeskOptionsSchema: Sendable, Hashable {
    public var widget: DeskFileID?
    /// The normalized language the labels are shown in; nil for the source text.
    public var language: String?
    public var sections: [DeskOptionSection]
    public var items: [DeskOptionItem]
    public var storage: DeskOptionStorage

    public func item(_ name: String) -> DeskOptionItem? { items.first { $0.name == name } }
}

extension CheckedDeskPackage {
    /// The Options panel of a widget in a language (nil: the source text): the widget's options in order, then the
    /// package's options it does not replace.
    public func optionsSchema(for widget: DeskFileID, language: String? = nil) -> DeskOptionsSchema {
        let locales = DeskPackageLocales(self)
        var builder = SchemaBuilder(checked: self, locales: locales, widget: widget, language: language)
        let own = files[widget]
        if let own { builder.addItems(from: own, scope: .widget, table: widget) }
        let replaced = Set(own?.options.keys.map { $0 } ?? [])
        if let packageFile, let package = files[packageFile] {
            builder.addItems(from: package, scope: .package, table: widget, skipping: replaced)
        }
        let limits = catalog.limits
        var storage = DeskOptionStorage(maximumValueBytes: limits.maximumSavedValueBytes,
                                        maximumInstanceBytes: limits.maximumSavedBytesPerInstance)
        storage.perInstance = builder.items.filter { $0.scope == .widget }.map(\.name)
        storage.perPackage = builder.items.filter { $0.scope == .package }.map(\.name)
        storage.keychain = builder.items.filter(\.isSecret).map(\.name)
        storage.savedValues = own.map(SchemaBuilder.savedNames) ?? []
        return DeskOptionsSchema(widget: widget, language: language, sections: builder.sections, items: builder.items,
                                 storage: storage)
    }

    /// The package's page of the manager window: the package's own options.
    public func packageOptionsSchema(language: String? = nil) -> DeskOptionsSchema {
        let locales = DeskPackageLocales(self)
        var builder = SchemaBuilder(checked: self, locales: locales, widget: nil, language: language)
        if let packageFile, let package = files[packageFile] {
            builder.addItems(from: package, scope: .package, table: nil)
        }
        let limits = catalog.limits
        var storage = DeskOptionStorage(maximumValueBytes: limits.maximumSavedValueBytes,
                                        maximumInstanceBytes: limits.maximumSavedBytesPerInstance)
        storage.perPackage = builder.items.map(\.name)
        storage.keychain = builder.items.filter(\.isSecret).map(\.name)
        return DeskOptionsSchema(widget: nil, language: language, sections: builder.sections, items: builder.items,
                                 storage: storage)
    }
}

/// Reads the options blocks in order.
struct SchemaBuilder {
    let checked: CheckedDeskPackage
    let locales: DeskPackageLocales
    let widget: DeskFileID?
    let language: String?
    var sections: [DeskOptionSection] = []
    var items: [DeskOptionItem] = []
    /// Options used as a whole command anywhere in the folder.
    let wholeCommands: Set<String>

    init(checked: CheckedDeskPackage, locales: DeskPackageLocales, widget: DeskFileID?, language: String?) {
        self.checked = checked
        self.locales = locales
        self.widget = widget
        self.language = language
        wholeCommands = Set(checked.files.values.flatMap { $0.requirements.commands.compactMap(\.scriptOption) })
    }

    var catalog: DeskCatalog { checked.catalog }

    mutating func addItems(from file: CheckedFile, scope: OptionFacts.Scope, table: DeskFileID?, skipping: Set<String> = []) {
        let tree = file.tree
        for block in tree.rootNode.childNodes where block.kind == .optionsBlock {
            guard let body = block.firstChild(.block) else { continue }
            addStatements(body, file: file, scope: scope, table: table, section: nil, skipping: skipping)
        }
    }

    private mutating func addStatements(_ body: PositionedNode, file: CheckedFile, scope: OptionFacts.Scope,
                                        table: DeskFileID?, section: Int?, skipping: Set<String>) {
        let tree = file.tree
        for statement in BlockSyntax(unchecked: body).statements {
            switch statement.kind {
            case .callStmt:
                let call = CallStmtSyntax(unchecked: statement)
                guard call.callee.name.token.name == "Section", let inner = call.block else { continue }
                let title = call.arguments?.arguments.first.flatMap { StringLiteralSyntax($0.value.node) }
                let source = title?.literalValue ?? ""
                let key = title.map { DeskTranslationKeys.key(of: $0, in: tree) }
                sections.append(DeskOptionSection(title: source,
                                                  displayTitle: locales.localized(source, key: key, in: table, language: language),
                                                  scope: scope))
                addStatements(inner.node, file: file, scope: scope, table: table, section: sections.count - 1, skipping: skipping)
            case .optionDecl:
                let decl = OptionDeclSyntax(unchecked: statement)
                let name = decl.target.name.token.name
                guard !skipping.contains(name), let facts = file.options[name], let call = decl.controlCall else { continue }
                // An option declared twice: only the one the checker kept.
                guard facts.node == tree.id(of: statement) || tree.quickResolve(facts.node)?.range == statement.range else { continue }
                items.append(item(name: name, facts: facts, call: call, file: file, scope: scope, table: table, section: section,
                                  declaration: DeskSite(file: tree.file, range: decl.target.name.textRange)))
            default:
                continue
            }
        }
    }

    private func item(name: String, facts: OptionFacts, call: CallStmtSyntax, file: CheckedFile, scope: OptionFacts.Scope,
                      table: DeskFileID?, section: Int?, declaration: DeskSite) -> DeskOptionItem {
        let tree = file.tree
        let arguments = call.arguments?.arguments ?? []
        let positional = arguments.filter { $0.label == nil }
        func labeled(_ label: String) -> PositionedNode? { arguments.first { $0.label?.name == label }?.value.node }
        func written(_ node: PositionedNode?) -> String? { node.map { DeskPackageReader.text(tree, $0) } }
        func localizedText(_ node: PositionedNode?) -> (source: String, display: String, key: String?)? {
            guard let node, let string = StringLiteralSyntax(node), let source = string.literalValue else { return nil }
            let key = DeskTranslationKeys.key(of: string, in: tree)
            return (source, locales.localized(source, key: key, in: table, language: language), key)
        }
        let control = facts.control
        let spec = catalog.control(named: control)
        let label = localizedText(positional.first?.value.node)
        var help: (source: String, display: String, key: String?)?
        var hidden: DeskOptionCondition?
        for modifier in call.modifiers {
            let modifierName = modifier.name.token.name
            let args = modifier.arguments?.arguments ?? []
            if modifierName == "help" { help = localizedText(args.first?.value.node) }
            if modifierName == "hidden" || modifierName == "visible",
               let condition = args.first(where: { $0.label?.name == "if" })?.value.node {
                hidden = DeskOptionCondition(text: DeskPackageReader.text(tree, condition), options: Self.optionsRead(condition),
                                             hidesWhenTrue: modifierName == "hidden")
            }
        }
        var choices: [DeskOptionChoice] = []
        if control == "Picker", positional.count >= 2, positional[1].value.node.kind == .listLiteral {
            for element in ListLiteralSyntax(unchecked: positional[1].value.node).elements {
                choices.append(choice(element.node, facts: facts, tree: tree, table: table))
            }
        }
        let defaultNode = labeled("default")
        let defaultValue = written(defaultNode) ?? implicitDefault(control, facts: facts, call: call, choices: choices, tree: tree)
        let isSecret = control == "Secret"
        let userOnly = ["Secret", "FolderPicker", "ImagePicker"].contains(control) || wholeCommands.contains(name)
        let typeName = facts.localEnum != nil
            ? LocalizedText("one of its choices", "其中一个选项") : catalog.displayName(for: facts.type)
        return DeskOptionItem(
            name: name, order: items.count, section: section, label: label?.source ?? "",
            displayLabel: label?.display ?? "", help: help?.source, displayHelp: help?.display, control: control,
            panel: spec?.panel ?? .textField, typeName: typeName, defaultValue: defaultValue,
            defaultIsWritten: defaultNode != nil, choices: choices, minimum: written(labeled("min")),
            maximum: written(labeled("max")),
            step: written(labeled("step")) ?? (control == "Stepper" ? "1" : nil), placeholder: localizedText(labeled("placeholder"))?.display,
            userOnly: userOnly, isSecret: isSecret, hiddenIf: hidden, scope: scope,
            replacesPackageOption: scope == .widget && checked.packageFile.flatMap { checked.files[$0]?.options[name] } != nil,
            declaration: declaration)
    }

    private func choice(_ node: PositionedNode, facts: OptionFacts, tree: SyntaxTree, table: DeskFileID?) -> DeskOptionChoice {
        // `Choice(value, "Label")`.
        if node.kind == .callExpr {
            let call = CallExprSyntax(unchecked: node)
            let args = call.arguments.arguments
            if DeskPackageReader.text(tree, call.callee.node) == "Choice", let value = args.first?.value.node {
                if args.count > 1, let string = StringLiteralSyntax(args[1].value.node), let source = string.literalValue {
                    let key = DeskTranslationKeys.key(of: string, in: tree)
                    return DeskOptionChoice(value: DeskPackageReader.text(tree, value), label: source,
                                            displayLabel: locales.localized(source, key: key, in: table, language: language),
                                            labelKey: key)
                }
                return choice(value, facts: facts, tree: tree, table: table)
            }
        }
        let value = DeskPackageReader.text(tree, node)
        if let string = StringLiteralSyntax(node)?.literalValue {
            return DeskOptionChoice(value: value, label: string, displayLabel: string, labelKey: nil)
        }
        if node.kind == .implicitMemberExpr {
            let name = ImplicitMemberExprSyntax(unchecked: node).name.token.name
            let title = catalogTitle(name, type: facts.type)
            let words = title?.en ?? Self.words(name)
            let display = title.map { (language ?? "").hasPrefix("zh") ? $0.zh : $0.en } ?? locales.localized(words, in: table, language: language)
            return DeskOptionChoice(value: value, label: words, displayLabel: display, labelKey: nil)
        }
        return DeskOptionChoice(value: value, label: value, displayLabel: value, labelKey: nil)
    }

    private func catalogTitle(_ name: String, type: DeskType) -> LocalizedText? {
        switch type {
        case .enumeration(let id):
            return catalog.enumeration(id)?.enumCase(named: name)?.title
        case .color, .paint:
            return catalog.namedValues.first { $0.name == name }?.title
        default:
            return nil
        }
    }

    /// The value a control starts with when no `default:` is written (§4.13).
    private func implicitDefault(_ control: String, facts: OptionFacts, call: CallStmtSyntax, choices: [DeskOptionChoice],
                                 tree: SyntaxTree) -> String? {
        switch control {
        case "Picker": return choices.first?.value
        case "Toggle": return "false"
        case "Slider", "Stepper":
            return (call.arguments?.arguments ?? []).first { $0.label?.name == "min" }.map { DeskPackageReader.text(tree, $0.value.node) }
        case "Input": return "\"\""
        case "ColorPicker": return ".accent"
        case "FontPicker": return "\"System\""
        case "DatePicker": return "today"
        default: return nil
        }
    }

    /// `options.x` names a condition reads.
    static func optionsRead(_ node: PositionedNode) -> [String] {
        var out: [String] = []
        var stack = [node]
        while let current = stack.popLast() {
            if current.kind == .memberExpr {
                let member = MemberExprSyntax(unchecked: current)
                if member.base.node.kind == .identifierExpr, IdentifierExprSyntax(unchecked: member.base.node).name == "options" {
                    let name = member.name.token.name
                    if !out.contains(name) { out.append(name) }
                    continue
                }
            }
            stack.append(contentsOf: current.childNodes.reversed())
        }
        return out
    }

    /// `darkBlue` → "Dark Blue".
    static func words(_ name: String) -> String {
        var out = ""
        for (k, c) in name.enumerated() {
            if k == 0 { out += c.uppercased(); continue }
            if c.isUppercase || (c.isNumber && !(out.last?.isNumber ?? false)) { out += " " }
            out.append(c)
        }
        return out
    }

    /// The `saved` declarations of a widget, in order.
    static func savedNames(_ file: CheckedFile) -> [String] {
        var out: [String] = []
        for block in file.tree.rootNode.childNodes where block.kind == .widgetBlock {
            var stack = [block]
            while let current = stack.popLast() {
                if current.kind == .declaration {
                    let decl = DeclarationSyntax(unchecked: current)
                    if decl.keyword.token.text == "saved", !decl.name.token.isMissing { out.append(decl.name.token.name) }
                    continue
                }
                stack.append(contentsOf: current.childNodes.reversed())
            }
        }
        return out
    }
}
