import Foundation

// Hover cards (the Studio's code pane shows them after the pointer rests on a word): what the item is and does, in
// English and Chinese. Built-in names read the catalog: the doc, an example of up to three lines, the Rainmeter
// counterpart, the release that added it, whether it is Mac-only or needs a newer macOS, the permission it needs and
// how often its data updates. Own names say what kind of name they are, the type they settled to (in words, never
// a type id) and what they hold: a literal initializer; an option's control, label and default; the modifiers a
// style sets; the component an element name names. Numbers with a unit show what they equal in other units (an
// amount of data in the base of the data it is compared with). Texts people read show their translations.

/// One line of a hover card's facts: "Type: a percentage, such as `50%`".
public struct DeskHoverFact: Sendable, Hashable {
    public var label: LocalizedText
    public var value: LocalizedText

    public init(_ label: LocalizedText, _ value: LocalizedText) {
        self.label = label
        self.value = value
    }
}

/// What the editor shows for the word under the pointer. Texts are in both languages; `markdown(_:)` writes one.
public struct DeskHover: Sendable, Hashable {
    /// The word (or number, or text) the card is about.
    public var range: DeskRange
    public var title: LocalizedText
    /// One line of Desk: the call shape of a built-in name, the declaration of an own name.
    public var codeLine: String?
    public var paragraphs: [LocalizedText]
    /// At most three lines of Desk.
    public var example: String?
    /// The Rainmeter counterpart, as Rainmeter writes it (`Measure=CPU Processor=0`), approximate ones marked.
    public var rainmeter: [LocalizedText]
    public var facts: [DeskHoverFact]
    /// The anchor of the language reference's entry (`modifier-padding`), for a "Reference" link.
    public var reference: String?
    /// The catalog entry of a built-in name.
    public var catalogPath: CatalogPath?

    public init(range: DeskRange, title: LocalizedText, codeLine: String? = nil, paragraphs: [LocalizedText] = [],
                example: String? = nil, rainmeter: [LocalizedText] = [], facts: [DeskHoverFact] = [],
                reference: String? = nil, catalogPath: CatalogPath? = nil) {
        self.range = range
        self.title = title
        self.codeLine = codeLine
        self.paragraphs = paragraphs
        self.example = example
        self.rainmeter = rainmeter
        self.facts = facts
        self.reference = reference
        self.catalogPath = catalogPath
    }

    /// The card as Markdown in one language: the title, the code line, the paragraphs, the facts, the example, the
    /// Rainmeter counterpart and a reference link.
    public func markdown(_ language: DiagnosticLanguage) -> String {
        let zh = language == .simplifiedChinese
        var out = "**\(title.text(in: language))**\n"
        if let codeLine { out += "\n```desk\n\(codeLine)\n```\n" }
        for paragraph in paragraphs where !paragraph.text(in: language).isEmpty {
            out += "\n" + paragraph.text(in: language) + "\n"
        }
        if !facts.isEmpty {
            out += "\n"
            for fact in facts {
                out += "- " + fact.label.text(in: language) + (zh ? "：" : ": ") + fact.value.text(in: language) + "\n"
            }
        }
        if let example, !example.isEmpty {
            out += "\n" + DeskServiceWords.example.text(in: language) + (zh ? "：" : ":") + "\n\n```desk\n\(example)\n```\n"
        }
        if !rainmeter.isEmpty {
            out += "\n" + DeskServiceWords.rainmeter.text(in: language) + (zh ? "：" : ": ")
                + rainmeter.map { $0.text(in: language) }.joined(separator: zh ? "、" : ", ") + "\n"
        }
        if let reference {
            out += "\n[\(DeskServiceWords.reference.text(in: language))](#\(reference))\n"
        }
        return out
    }

    /// Every text a person reads on the card (not the Desk code), in one language: for checks.
    public func prose(_ language: DiagnosticLanguage) -> [String] {
        [title.text(in: language)] + paragraphs.map { $0.text(in: language) }
            + facts.flatMap { [$0.label.text(in: language), $0.value.text(in: language)] }
            + rainmeter.map { $0.text(in: language) }
    }
}

/// Words of hover cards for own names.
enum DeskHoverWords {
    typealias L = LocalizedText

    static func kind(_ kind: DeskNameKind) -> L {
        switch kind {
        case .variable: return L("Variable", "变量")
        case .saved: return L("Saved value", "保存的值")
        case .computed: return L("Computed value", "计算值")
        case .loopVariable: return L("Loop variable", "循环变量")
        case .element: return L("Element name", "元素名")
        case .style: return L("Style", "样式")
        case .option: return L("Option", "选项")
        case .translationKey: return L("Text", "文字")
        case .asset: return L("Picture", "图片")
        default: return L("Name", "名字")
        }
    }

    static func explanation(_ kind: DeskNameKind) -> L {
        switch kind {
        case .variable: return L("A value the widget keeps while it runs; actions can change it.", "组件运行时保存的值，动作可以改变它。")
        case .saved: return L("A value the widget keeps even when it restarts; actions can change it.", "组件重新启动后仍然保留的值，动作可以改变它。")
        case .computed: return L("A value worked out from others; it changes when they do.", "由其他值算出来的值，它们变了它就跟着变。")
        case .loopVariable: return L("Each item of the list this `for` goes through, in turn.", "这个 `for` 依次经过的列表里的每一项。")
        case .element: return L("The name of an element: actions such as `show(…)` and positions refer to the element by it.",
                                "元素的名字：`show(…)` 这样的动作和位置用它指代这个元素。")
        case .style: return L("A style: modifiers that elements take with `.style(…)`.", "样式：元素通过 `.style(…)` 使用的一组修饰符。")
        case .option: return L("An option: a setting people change in the widget's Options panel.", "选项：用户在组件的“选项”面板里修改的设置。")
        case .translationKey: return L("Text people read; `translations { }` can replace it in other languages.",
                                       "给人看的文字；`translations { }` 可以把它换成别的语言。")
        case .asset: return L("A picture in the widget's folder.", "组件文件夹里的图片。")
        default: return L("", "")
        }
    }

    static let control = L("Control", "控件")
    static let label = L("Label", "标签")
    static let sharedByPackage = L("Shared", "共用")
    static let sharedValue = L("Set once for every widget of the package", "整个包的组件共用一个值")
    static let sets = L("Sets", "设置")
    static let component = L("Component", "组件")
    static let key = L("Key", "键")
    static let translations = L("Translations", "翻译")
    static let noTranslations = L("none yet", "还没有")
    static let size = L("Size", "尺寸")
    static let notFound = L("not in the widget's folder", "不在组件文件夹里")
    static let equals = L("Equals", "等于")
    static let countedIn = L("Counted in", "进位")
    static let parameterOf = L("Parameter of", "参数，属于")
    static let required = L("Required", "必填")
    static let each = L("Each item", "每一项")
    static let gives = L("Gives", "得到")
    static let fieldOf = L("In", "位于")
    static let settingIn = L("Written in", "写在")
    static let choiceOf = L("Choice of", "可选值，属于")
}

extension DeskSnapshot {
    /// The hover card for the position: a built-in or own name, an argument label, a number, a text people read,
    /// a picture's path. Nil elsewhere (punctuation, keywords, blanks).
    public func hover(at position: DeskPosition) -> DeskHover? {
        guard hasStackRoom else { return onLargeStack { hover(at: position) } }
        let offset = index.utf8Offset(ofUTF16: index.clampedUTF16(position.offset))
        let table = nodeTable
        // A number: its token holds the position.
        if let n = table.innermost(at: offset), table.entries[n].kind == .numberLiteral {
            return numberHover(entry: n)
        }
        guard let o = symbolIndex.occurrence(at: offset) else { return fallbackHover(at: offset) }
        let range = index.range(utf8: o.range)
        switch o.kind {
        case .variable, .saved, .computed, .loopVariable, .element, .style, .option:
            return ownNameHover(o, range: range)
        case .translationKey:
            return translationHover(o, range: range)
        case .asset:
            return assetHover(o, range: range)
        case .label:
            return labelHover(o, range: range)
        case .unit:
            if let n = table.innermost(at: o.range.lowerBound, where: { $0.kind == .numberLiteral }) { return numberHover(entry: n) }
            return nil
        case .type where o.path == nil:
            // A Picker option's own choices (§4.13).
            guard let option = localEnumOption(o.name) else { return nil }
            let choices = option.choices.map { "`.\($0)`" }.joined(separator: ", ")
            var hover = DeskHover(range: range, title: LocalizedText("`\(o.name)`", "`\(o.name)`"),
                                  paragraphs: [LocalizedText("The choices of the option `\(option.name)`: \(choices).",
                                                             "选项 `\(option.name)` 的可选值：\(choices)。")])
            hover.facts.append(DeskHoverFact(DeskServiceWords.type, LocalizedText("A Picker's own choices", "单选自己的可选值")))
            return hover
        case .event:
            var hover = DeskHover(range: range, title: LocalizedText("`event`", "`event`"),
                                  paragraphs: [LocalizedText("What happened: the event this block runs for, with its details.",
                                                             "发生了什么：这个块所响应的事件及其细节。")], reference: "events")
            let record = eventRecord(at: o.range.lowerBound)
            if let spec = options.catalog.record(record) {
                hover.paragraphs.append(spec.doc.text)
                hover.facts.append(DeskHoverFact(DeskServiceWords.type, options.catalog.displayName(for: .record(record))))
            }
            return hover
        default:
            guard let path = o.path else { return fallbackHover(at: offset) }
            let node = table.innermost(at: o.range.lowerBound)
            return builtInHover(path, range: range, written: o.name, node: node)
        }
    }

    // MARK: Built-in names

    func builtInHover(_ path: CatalogPath, range: DeskRange, written: String, node: Int?) -> DeskHover {
        let catalog = options.catalog
        // A member written as a call (`list.first(5)`) is the call, not the field of the same name.
        let isCall = node.map { n -> Bool in
            let parent = nodeTable.entries[n].parent
            return parent >= 0 && nodeTable.entries[parent].kind == .callExpr && nodeTable.children(of: parent).first == n
        }
        let docs = catalog.serviceDocs(for: path, call: isCall)
        let first = docs.first
        var hover = DeskHover(range: range, title: catalog.serviceTitle(for: path, call: isCall) ?? LocalizedText("`\(written)`", "`\(written)`"),
                              codeLine: writtenCallLine(node: node) ?? codeLine(for: path), paragraphs: docs.map(\.text),
                              example: first.map { DeskSnapshot.firstLines($0.example, 3) },
                              rainmeter: (first?.rainmeter ?? []).map(DeskSnapshot.rainmeterText),
                              reference: DeskCatalog.referenceAnchor(for: path), catalogPath: path)
        if let deprecated = first?.deprecated {
            hover.paragraphs.append(LocalizedText("Being replaced by `\(deprecated.replacement)` (since Deskset \(deprecated.since)).",
                                                  "正在被 `\(deprecated.replacement)` 取代（从 Deskset \(deprecated.since) 起）。"))
        }
        // What data gives, and how often.
        var data = catalog.serviceMember(for: path, call: isCall)
        if case .namespace(let name) = path, catalog.namespace(named: name)?.value == nil { data = nil }
        if let data, data.kind != .action {
            var semType = SemType(type: data.type, displayBase: data.displayBase)
            if data.kind == .field, let node, let recorded = recordedType(node), recorded.type != .any { semType = recorded }
            hover.facts.append(DeskHoverFact(DeskServiceWords.value, typeWords(semType)))
            hover.paragraphs += recordDocs(of: semType.type)
            switch path {
            case .member, .namespace, .function:
                hover.facts.append(DeskHoverFact(DeskServiceWords.updates, DeskServiceWords.cadence(data.cadence)))
            default:
                break
            }
        }
        // Presets: what a case sets.
        if case .enumCase(let type, let name) = path, let spec = catalog.enumeration(type)?.enumCase(named: name),
           !spec.facetValues.isEmpty {
            let parts = spec.facetValues.sorted { $0.key < $1.key }.map { facet, value -> LocalizedText in
                let facetName = catalog.facet(facet)?.displayName ?? LocalizedText(facet.rawValue, facet.rawValue)
                return LocalizedText("\(facetName.en) `\(value.value)`", "\(facetName.zh) `\(value.value)`")
            }
            hover.facts.append(DeskHoverFact(DeskHoverWords.sets, DeskSnapshot.joined(parts)))
        }
        if case .enumCase(let type, let name) = path, catalog.enumeration(type) == nil, let local = checkedOption(forLocalEnum: type) {
            // A choice of a Picker's own (`.mono` of `options.look`).
            let row = catalog.displayName("enum:local")?.name ?? LocalizedText("one of the choices of `options.{name}`", "`options.{name}` 的可选项之一")
            let sentence = LocalizedText(row.en.replacingOccurrences(of: "{name}", with: local),
                                         row.zh.replacingOccurrences(of: "{name}", with: local))
            hover.title = LocalizedText("`.\(name)`", "`.\(name)`")
            hover.paragraphs = [LocalizedText(sentence.en.prefix(1).uppercased() + sentence.en.dropFirst() + ".", sentence.zh + "。")]
            hover.reference = nil
            hover.facts.removeAll { $0.label == DeskServiceWords.since }
            hover.facts.append(DeskHoverFact(DeskHoverWords.choiceOf, LocalizedText("`options.\(local)`", "`options.\(local)`")))
        }
        // Fields of `info` and `package`.
        if case .infoField(let name) = path, let spec = catalog.index.infoFields[name] ?? catalog.index.packageFields[name] {
            hover.codeLine = "\(name): …"
            hover.facts.append(DeskHoverFact(DeskServiceWords.type, catalog.displayName(for: spec.type)))
            if let d = spec.defaultValue { hover.facts.append(DeskHoverFact(DeskServiceWords.defaultLabel, DeskServiceWords.defaultValue(d))) }
        }
        if case .packageField(let name) = path, let spec = catalog.index.packageFields[name] ?? catalog.index.infoFields[name] {
            hover.codeLine = "\(name): …"
            hover.facts.append(DeskHoverFact(DeskServiceWords.type, catalog.displayName(for: spec.type)))
        }
        // Permission, macOS, release.
        if let permission = permission(for: path), let spec = catalog.index.permissions[permission] {
            hover.facts.append(DeskHoverFact(DeskServiceWords.permission,
                                             LocalizedText("`.\(permission)` (\(spec.needsPhrase.en))", "`.\(permission)`（\(spec.needsPhrase.zh)）")))
        }
        if let first {
            if first.macOnly { hover.facts.append(DeskHoverFact(DeskServiceWords.macOnly, DeskServiceWords.yes)) }
            if let version = first.minimumMacOS {
                hover.facts.append(DeskHoverFact(DeskServiceWords.needsMacOS, DeskServiceWords.macOS(version)))
            }
            hover.facts.append(DeskHoverFact(DeskServiceWords.since, LocalizedText("Deskset \(first.since)", "Deskset \(first.since)")))
        }
        return hover
    }

    /// The signature a written call uses, as a code line: the call's own argument list read by signature help.
    private func writtenCallLine(node: Int?) -> String? {
        guard let node else { return nil }
        let table = nodeTable
        var owner = node
        // From the name to the node that holds the argument list: a callee's call, a modifier, a call expression.
        if table.entries[owner].kind == .callee || table.entries[owner].kind == .identifierExpr || table.entries[owner].kind == .memberExpr,
           table.entries[owner].parent >= 0 {
            let parent = table.entries[owner].parent
            if table.entries[parent].kind == .callStmt || table.entries[parent].kind == .callExpr { owner = parent }
        }
        guard [.callStmt, .callExpr, .modifierApp].contains(table.entries[owner].kind),
              let clause = table.children(of: owner).first(where: { table.entries[$0].kind == .argumentClause }),
              let open = table.entries[clause].positioned.childTokens.first, open.kind == .lParen, !open.token.isMissing,
              let site = callSite(at: open.textRange.upperBound), site.clause == clause, site.signatures.count > 1 else { return nil }
        return signatureItem(site.signatures[activeSignature(site, argument: 0)], site: site).label
    }

    /// The record `event` holds where an offset is: the one of the event modifier whose block holds it.
    func eventRecord(at offset: Int) -> String {
        let table = nodeTable
        guard let i = table.innermost(at: offset) else { return "Event" }
        for a in [i] + table.ancestors(of: i) where table.entries[a].kind == .modifierApp {
            let tokens = table.entries[a].positioned.childTokens
            if tokens.count >= 2, let event = options.catalog.modifier(named: tokens[1].token.name)?.event {
                return event.eventRecord ?? "Event"
            }
        }
        return "Event"
    }

    /// The type the checker recorded for a node of the open file, when the record is the node's own: nested nodes of
    /// one kind that start at one place share a key, and the record is the outermost one's.
    func recordedType(_ i: Int) -> SemType? {
        let id = nodeTable.id(i)
        guard nodeTable.indexes(of: id).first == i else { return nil }
        return checked.types[id]
    }

    /// The permission a built-in name needs to read or do what it does.
    private func permission(for path: CatalogPath) -> String? {
        let catalog = options.catalog
        switch path {
        case .namespace(let name): return catalog.namespace(named: name)?.permission
        case .member(let ns, let name):
            return catalog.index.member(ns, name)?.permission ?? catalog.namespace(named: ns)?.permission
        case .function(let name): return catalog.function(named: name)?.permission
        default: return catalog.serviceMember(for: path)?.permission
        }
    }

    /// The option whose Picker's choices form a local enum.
    private func checkedOption(forLocalEnum type: String) -> String? {
        for (name, facts) in checked.options where facts.localEnum == type { return name }
        if let package { for (name, facts) in package.options where facts.localEnum == type { return name } }
        return nil
    }

    /// The call shape of a built-in name: `Progress(value, total: …)`, `.padding(all)`, `cpu.usage`, `.headline`.
    func codeLine(for path: CatalogPath) -> String {
        let catalog = options.catalog
        func call(_ name: String, _ signatures: [Signature]) -> String {
            guard let signature = signatures.first else { return name }
            let parts = signature.params.map { p -> String in
                if let label = p.label { return "\(label): …" }
                return p.name + (p.variadic ? "…" : "")
            }
            return name + "(" + parts.joined(separator: ", ") + ")"
        }
        switch path {
        case .component(let n): return call(n, catalog.serviceSignatures(for: path))
        case .control(let n): return call(n, catalog.serviceSignatures(for: path))
        case .modifier(let n):
            let signatures = catalog.serviceSignatures(for: path)
            if signatures.first?.params.isEmpty == false { return call("." + n, signatures) }
            return catalog.modifier(named: n)?.block != BlockKind.none ? "." + n + " { … }" : "." + n + "()"
        case .function(let n): return call(n, catalog.serviceSignatures(for: path))
        case .member(let ns, let n):
            let member = catalog.index.member(ns, n)
            return member?.kind == .field ? "\(ns).\(n)" : call("\(ns).\(n)", member?.signatures ?? [])
        case .recordField(_, let n), .typeMember(_, let n):
            let member = catalog.serviceMember(for: path)
            return member?.kind == .field || member == nil ? ".\(n)" : call("." + n, member?.signatures ?? [])
        case .namespace(let n): return n
        case .enumCase(_, let n), .namedValue(_, let n): return "." + n
        case .permission(let n), .feature(let n): return "." + n
        case .infoField(let n), .packageField(let n): return "\(n): …"
        case .formatOption(let l): return "{value, \(l): …}"
        case .record(let id), .enumeration(let id): return id
        }
    }

    // MARK: Own names

    func ownNameHover(_ o: DeskOccurrence, range: DeskRange) -> DeskHover {
        let catalog = options.catalog
        var hover = DeskHover(range: range, title: LocalizedText("\(DeskHoverWords.kind(o.kind).en) `\(o.name)`",
                                                                  "\(DeskHoverWords.kind(o.kind).zh) `\(o.name)`"),
                              paragraphs: [DeskHoverWords.explanation(o.kind)])
        guard let key = o.key else { return hover }
        // The file and node that declare it.
        var declaring: (file: DeskFileID, tree: SyntaxTree, node: PositionedNode, table: DeskNodeTable?)?
        if let id = symbolIndex.declaringNodes[key], let node = tree.quickResolve(id) {
            declaring = (file, tree, node, nodeTable)
        } else if !isPackage, let packageIndex = symbolIndex(of: packageFile), let id = packageIndex.declaringNodes[key],
                  let package, let node = package.tree.quickResolve(id) {
            declaring = (packageFile, package.tree, node, nil)
        }
        if let declaring { hover.codeLine = DeskSnapshot.codeLine(of: declaring.node, in: declaring.tree) }
        switch o.kind {
        case .variable, .saved, .computed:
            guard let declaring, declaring.file == file else { break }
            let id = NodeID(kind: .declaration, utf8Start: declaring.node.quickTextStart, treeVersion: declaring.tree.version)
            if let type = checked.declarationTypes[id] {
                hover.facts.append(DeskHoverFact(DeskServiceWords.type, typeWords(type)))
                hover.paragraphs += recordDocs(of: type.type)
            }
            if let initializer = declaring.node.childNodes.last, initializer.kind.isExpression, DeskSnapshot.isLiteral(initializer) {
                let text = DeskSnapshot.text(of: initializer, in: declaring.tree)
                hover.facts.append(DeskHoverFact(o.kind == .computed ? DeskServiceWords.value : LocalizedText("Starts at", "初始值"),
                                                 LocalizedText("`\(text)`", "`\(text)`")))
            }
        case .loopVariable:
            // The list's element type.
            if let declaring, declaring.file == file, let list = declaring.node.childNodes.first(where: { $0.kind.isExpression }),
               let listEntry = nodeTable.innermost(at: list.quickTextStart, where: { $0.offset == list.offset && $0.node === list.node }),
               let type = recordedType(listEntry) {
                if case .list(let element) = type.type {
                    let semType = SemType(type: element, displayBase: type.displayBase)
                    hover.facts.append(DeskHoverFact(DeskHoverWords.each, typeWords(semType)))
                    hover.paragraphs += recordDocs(of: element)
                } else if case .number = type.type {
                    hover.facts.append(DeskHoverFact(DeskHoverWords.each, catalog.displayName(for: .plainNumber)))
                }
            }
        case .element:
            if let declaring, declaring.file == file, let facts = checked.elements[tree.id(of: declaring.node)] {
                let title = catalog.component(named: facts.component)?.title ?? LocalizedText(facts.component, facts.component)
                hover.facts.append(DeskHoverFact(DeskHoverWords.component, LocalizedText("\(title.en) (`\(facts.component)`)",
                                                                                          "\(title.zh)（`\(facts.component)`）")))
                hover.reference = DeskCatalog.referenceAnchor(for: .component(facts.component))
            }
        case .style:
            if let declaring {
                let modifiers = declaring.node.firstChild(.block).map { DeskSnapshot.modifierNames(in: $0) } ?? []
                let titles = modifiers.map { name -> LocalizedText in
                    let title = catalog.modifier(named: name)?.title ?? LocalizedText(name, name)
                    return LocalizedText("\(title.en.lowercasedFirst) (`.\(name)`)", "\(title.zh)（`.\(name)`）")
                }
                if !titles.isEmpty { hover.facts.append(DeskHoverFact(DeskHoverWords.sets, DeskSnapshot.joined(titles))) }
            }
            if !isPackage, declaring?.file == packageFile {
                hover.facts.append(DeskHoverFact(DeskHoverWords.settingIn, LocalizedText("`package.desk`", "`package.desk`")))
            }
        case .option:
            let facts = checked.options[o.name] ?? package?.options[o.name]
            if let facts {
                let control = catalog.control(named: facts.control)
                let controlTitle = control?.title ?? LocalizedText(facts.control, facts.control)
                hover.facts.append(DeskHoverFact(DeskHoverWords.control, LocalizedText("\(controlTitle.en) (`\(facts.control)`)",
                                                                                        "\(controlTitle.zh)（`\(facts.control)`）")))
                if let declaring, let label = DeskSnapshot.controlLabel(declaring.node) {
                    hover.facts.append(DeskHoverFact(DeskHoverWords.label, DeskServiceWords.quoted(label)))
                }
                if facts.type != .any {
                    let semType = SemType(type: facts.type, displayBase: facts.displayBase)
                    hover.facts.append(DeskHoverFact(DeskServiceWords.type, facts.localEnum != nil
                                                        ? LocalizedText("one of \(facts.choices.map { "`.\($0)`" }.joined(separator: ", "))",
                                                                        "\(facts.choices.map { "`.\($0)`" }.joined(separator: "、"))之一")
                                                        : typeWords(semType)))
                }
                if let text = facts.defaultText {
                    hover.facts.append(DeskHoverFact(DeskServiceWords.defaultLabel, LocalizedText("`\(text)`", "`\(text)`")))
                }
                if facts.scope == .package || (!isPackage && checked.options[o.name] == nil) {
                    hover.facts.append(DeskHoverFact(DeskHoverWords.sharedByPackage, DeskHoverWords.sharedValue))
                }
                hover.reference = DeskCatalog.referenceAnchor(for: .control(facts.control))
            }
        default:
            break
        }
        return hover
    }

    /// The docs of the record a value is (or holds a list of).
    private func recordDocs(of type: DeskType) -> [LocalizedText] {
        switch type {
        case .record(let id): return options.catalog.record(id).map { [$0.doc.text] } ?? []
        case .list(.record(let id)): return options.catalog.record(id).map { [$0.doc.text] } ?? []
        default: return []
        }
    }

    /// A type in words; an amount of data says how it counts.
    func typeWords(_ type: SemType) -> LocalizedText {
        let words = options.catalog.displayName(for: type.type)
        if let base = type.displayBase, base == 1024 || base == 1000 {
            return LocalizedText("\(words.en), counted in \(base)s", "\(words.zh)，按 \(base) 进位")
        }
        return words
    }

    // MARK: Labels, texts, pictures

    func labelHover(_ o: DeskOccurrence, range: DeskRange) -> DeskHover? {
        guard let site = callSite(at: o.range.lowerBound), !site.signatures.isEmpty else { return nil }
        let k = site.argumentIndex(at: o.range.lowerBound)
        let signature = site.signatures[activeSignature(site, argument: k)]
        guard let param = signature.params.first(where: { $0.label == o.name })
                ?? site.signatures.lazy.compactMap({ $0.params.first { $0.label == o.name } }).first else { return nil }
        let catalog = options.catalog
        let owner = site.path.flatMap { catalog.serviceTitle(for: $0) } ?? LocalizedText(site.name, site.name)
        var hover = DeskHover(range: range, title: LocalizedText("`\(o.name):`", "`\(o.name):`"),
                              codeLine: signatureItem(signature, site: site).label, paragraphs: [param.doc],
                              reference: site.path.map { DeskCatalog.referenceAnchor(for: $0) })
        hover.facts.append(DeskHoverFact(DeskHoverWords.parameterOf, LocalizedText("\(owner.en) (`\(site.name)`)", "\(owner.zh)（`\(site.name)`）")))
        hover.facts.append(DeskHoverFact(DeskServiceWords.type, catalog.displayName(for: param.type)))
        if let d = param.defaultValue {
            hover.facts.append(DeskHoverFact(DeskServiceWords.defaultLabel, DeskServiceWords.defaultValue(d)))
        } else if param.required {
            hover.facts.append(DeskHoverFact(DeskHoverWords.required, DeskServiceWords.yes))
        }
        return hover
    }

    func translationHover(_ o: DeskOccurrence, range: DeskRange) -> DeskHover {
        var hover = DeskHover(range: range, title: DeskHoverWords.kind(.translationKey),
                              paragraphs: [DeskHoverWords.explanation(.translationKey)])
        hover.facts.append(DeskHoverFact(DeskHoverWords.key, DeskServiceWords.quoted(o.name)))
        // The widget's translations win over the package's (§8.6).
        var languages: [String: String] = [:]
        if !isPackage, let package {
            for (tag, table) in package.translations.languages { if let text = table[o.name] { languages[tag] = text } }
        }
        for (tag, table) in checked.translations.languages { if let text = table[o.name] { languages[tag] = text } }
        for (tag, text) in languages where text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") {
            languages[tag] = String(text.dropFirst().dropLast())
        }
        if languages.isEmpty {
            hover.facts.append(DeskHoverFact(DeskHoverWords.translations, DeskHoverWords.noTranslations))
        }
        for tag in languages.keys.sorted() {
            hover.facts.append(DeskHoverFact(LocalizedText(tag, tag), DeskServiceWords.quoted(languages[tag]!)))
        }
        hover.reference = "translations"
        return hover
    }

    func assetHover(_ o: DeskOccurrence, range: DeskRange) -> DeskHover {
        var hover = DeskHover(range: range, title: LocalizedText("`\(o.name)`", "`\(o.name)`"),
                              paragraphs: [DeskHoverWords.explanation(.asset)])
        if let picture = assetFile(o.name) {
            if case .image(let width, let height)? = resources?.kind(of: picture.path) {
                hover.facts.append(DeskHoverFact(DeskHoverWords.size, LocalizedText("\(width) × \(height)", "\(width) × \(height)")))
            }
        } else if resources != nil {
            hover.facts.append(DeskHoverFact(DeskHoverWords.size, DeskHoverWords.notFound))
        }
        return hover
    }

    // MARK: Numbers

    func numberHover(entry n: Int) -> DeskHover? {
        let table = nodeTable
        let entry = table.entries[n]
        guard let token = entry.positioned.childTokens.first, !token.token.isMissing, let value = token.token.numberValue else { return nil }
        let catalog = options.catalog
        let range = index.range(utf8: token.textRange)
        let semType = recordedType(n)
        let written = token.token.unit.flatMap { unit -> UnitSpec? in
            guard case .known = unit.status else { return nil }
            return catalog.unit(spelling: unit.text)
        }
        let dimension: Dimension
        if let written { dimension = written.dimension } else if case .number(let d)? = semType?.type { dimension = d } else { return nil }
        let title = token.token.text
        var hover = DeskHover(range: range, title: LocalizedText("`\(title)`", "`\(title)`"),
                              paragraphs: [catalog.displayName(for: .number(dimension))])
        guard dimension != .plain else { return written == nil ? nil : hover }
        // The display base of an amount of data: settled for this literal, or the one of what it meets.
        var base = semType?.displayBase
        if base == nil, written?.adoptsBase == true { base = neighbourBase(of: n) }
        let unit = written ?? catalog.units.first { $0.dimension == dimension && $0.spelling == dimension.canonicalUnit }
        guard let unit else { return hover }
        let canonical = value * unit.factor(base: base ?? 1000) + unit.offset
        var conversions: [String] = []
        let others = catalog.units.filter { $0.dimension == dimension && $0.spelling != unit.spelling && !["deg", "mbar", "KiB", "MiB", "GiB", "TiB", "KiB/s", "MiB/s", "GiB/s"].contains($0.spelling) }
        for other in others {
            let converted = (canonical - other.offset) / other.factor(base: base ?? 1000)
            guard converted.isFinite, converted != 0 || value == 0 else { continue }
            let magnitude = abs(converted)
            // Amounts of data always say how many bytes they are.
            let exactBytes = other.spelling == "B" || other.spelling == "B/s"
            guard value == 0 || exactBytes || (magnitude >= 0.01 && magnitude < 1e7) else { continue }
            conversions.append("\(DeskServiceWords.number(converted)) \(other.spelling)")
            if conversions.count == 3 { break }
        }
        if dimension == .percent { conversions.append(DeskServiceWords.number(value / 100)) }
        if !conversions.isEmpty {
            hover.facts.append(DeskHoverFact(DeskHoverWords.equals, LocalizedText(conversions.joined(separator: " · "),
                                                                                   conversions.joined(separator: " · "))))
        }
        if unit.adoptsBase {
            let b = base ?? 1000
            let prefix = b == 1024 ? LocalizedText("1024, as the data it is compared with counts (like Activity Monitor)",
                                                   "1024，和它比较的数据一样（和“活动监视器”相同）")
                                   : LocalizedText("1000, as the data it is compared with counts (like Finder)",
                                                   "1000，和它比较的数据一样（和“访达”相同）")
            hover.facts.append(DeskHoverFact(DeskHoverWords.countedIn, base == nil
                                                ? LocalizedText("1000 (nothing it is compared with says otherwise)", "1000（没有和它比较的数据另作规定）")
                                                : prefix))
        }
        hover.reference = "units"
        return hover
    }

    /// The display base of the value a byte literal meets: the other side of its comparison or sum, or the
    /// expression around it.
    private func neighbourBase(of n: Int) -> Int? {
        let table = nodeTable
        var child = n
        var p = table.entries[n].parent
        while p >= 0 {
            let kind = table.entries[p].kind
            if kind == .argument, table.entries[p].parent >= 0 {
                // An argument: the other arguments of the call (`Progress(disk.used, total: 500GB)`).
                for sibling in table.children(of: table.entries[p].parent) where sibling != p && table.entries[sibling].kind == .argument {
                    for value in table.children(of: sibling) where table.entries[value].kind != .label {
                        if let base = recordedType(value)?.displayBase { return base }
                    }
                }
                return nil
            }
            guard kind == .binaryExpr || kind == .parenExpr || kind == .prefixExpr else { return nil }
            if let base = recordedType(p)?.displayBase { return base }
            for sibling in table.children(of: p) where sibling != child {
                if let base = recordedType(sibling)?.displayBase { return base }
            }
            child = p
            p = table.entries[p].parent
        }
        return nil
    }

    // MARK: Names the index does not hold

    /// A namespace or member written where the checker records no use (the `music` of `music.play()`).
    private func fallbackHover(at offset: Int) -> DeskHover? {
        let table = nodeTable
        guard let e = table.innermost(at: offset), table.entries[e].kind == .callee || table.entries[e].kind == .target else { return nil }
        let tokens = table.entries[e].positioned.childTokens.filter { !$0.token.isMissing && $0.kind != .dot }
        guard let k = tokens.firstIndex(where: { $0.textRange.lowerBound <= offset && offset <= $0.textRange.upperBound }) else { return nil }
        let parts = tokens.prefix(k + 1).map(\.token.name)
        let catalog = options.catalog
        let range = index.range(utf8: tokens[k].textRange)
        if k == 0 {
            guard catalog.namespace(named: parts[0]) != nil else { return nil }
            return builtInHover(.namespace(parts[0]), range: range, written: parts[0], node: nil)
        }
        guard let found = catalog.serviceMember(dotted: Array(parts)) else { return nil }
        return builtInHover(found.path, range: range, written: parts.last!, node: nil)
    }

    // MARK: Helpers

    /// The first line of a node's text (the rest of a multi-line node shown as `…`), at most 120 characters. Only
    /// the start of a long line is read: a hover on a 32k text costs no more than one on a short one.
    static func codeLine(of node: PositionedNode, in tree: SyntaxTree) -> String {
        let range = node.quickTextRange
        let bytes = tree.lines.bytes
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return "" }
        // The first line ends at a LF or a CR (of a CR LF too).
        var end = range.lowerBound
        while end < range.upperBound, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
        let multiLine = end < range.upperBound
        // 120 characters fit in far fewer bytes, unless they are long clusters.
        var cut = min(end, range.lowerBound + 4_096)
        while cut > range.lowerBound, cut < end, bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
        var line = String(decoding: bytes[range.lowerBound..<cut], as: UTF8.self)
        if line.count > 120 { line = String(line.prefix(119)) + "…" }
        else if cut < end { line += "…" }
        else if multiLine { line += line.hasSuffix("{") ? " … }" : " …" }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// A node's text without its outer trivia.
    static func text(of node: PositionedNode, in tree: SyntaxTree) -> String {
        let range = node.quickTextRange
        let bytes = tree.lines.bytes
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return "" }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    /// Only literals: a number, a text without data, `true`/`false`, a choice, a list of those.
    static func isLiteral(_ node: PositionedNode) -> Bool {
        switch node.kind {
        case .numberLiteral, .boolLiteral: return true
        case .stringLiteral: return !node.childNodes.contains { $0.kind == .interpolation }
        case .implicitMemberExpr: return node.firstChild(.argumentClause) == nil
        case .listLiteral: return node.childNodes.allSatisfy(isLiteral)
        case .prefixExpr: return node.childNodes.count == 1 && node.childNodes[0].kind == .numberLiteral
        default: return false
        }
    }

    /// The modifiers a style's body sets, in the order written, each once (states' insides included).
    static func modifierNames(in block: PositionedNode) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        var stack = [block]
        while let node = stack.popLast() {
            if node.kind == .modifierApp {
                let tokens = node.childTokens
                if tokens.count >= 2, !tokens[1].token.isMissing, seen.insert(tokens[1].token.name).inserted {
                    names.append(tokens[1].token.name)
                }
            }
            for child in node.childNodes.reversed() where [.modifierApp, .modifierStmt, .block].contains(child.kind) {
                stack.append(child)
            }
        }
        return names
    }

    /// The label a control shows (its first text argument): `Picker("Week starts on", …)` → "Week starts on".
    static func controlLabel(_ option: PositionedNode) -> String? {
        guard let call = option.firstChild(.callStmt), let clause = call.firstChild(.argumentClause),
              let first = clause.firstChild(.argument), first.firstChild(.label) == nil,
              let value = first.childNodes.last, value.kind == .stringLiteral else { return nil }
        return StringLiteralSyntax(unchecked: value).literalValue
    }

    static func firstLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(count).joined(separator: "\n")
    }

    static func rainmeterText(_ mapping: RainmeterMapping) -> LocalizedText {
        let spelling = "`\(mapping.qualifiedSpelling)`"
        if mapping.fidelity == .exact { return LocalizedText(spelling, spelling) }
        return LocalizedText(spelling + DeskServiceWords.approximate.en, spelling + DeskServiceWords.approximate.zh)
    }

    /// "a, b and c" / "a、b 和 c".
    static func joined(_ items: [LocalizedText]) -> LocalizedText {
        LocalizedText(DeskCatalog.joined(items.map(\.en), last: " and "), DeskCatalog.joined(items.map(\.zh), separator: "、", last: "和"))
    }
}

extension String {
    /// The first letter in lower case ("Padding" → "padding"), unless the second is upper case too ("SF Symbol").
    var lowercasedFirst: String {
        guard let first = first else { return self }
        let second = dropFirst().first
        if let second, second.isUppercase { return self }
        return first.lowercased() + dropFirst()
    }
}
