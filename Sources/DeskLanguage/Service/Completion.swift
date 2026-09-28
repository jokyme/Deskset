import Foundation

// Completion: the items that may be written at the cursor, from the same catalog as the checker, hover cards and
// the formatter. Each item carries its label, what it is, its parameters in words, its documentation in both
// languages, a snippet (LSP syntax: `${1:…}` tab stops filled with the catalog's preview values, `$0` for the final
// cursor) with a plain-text fallback, the UTF-16 range it replaces, the words it is found by (the catalog's keywords
// and other languages' spellings, so typing `VStack` offers `Column`) and a sort key (how well it matches, whether it
// fits the expected type, how near its scope is, its popularity, and the earliest release first). Nothing newer than
// the file's `requires` or the target Deskset is offered (D89).

/// What a completion item is.
public enum DeskCompletionItemKind: String, Sendable, Hashable, CaseIterable {
    /// A top-level block: `info`, `options`, `widget`, `style`, `translations`, `package`.
    case block
    /// A field of `info` or `package`.
    case field
    case component
    /// An option control.
    case control
    case modifier
    case namespace
    /// A data field, a record's field or a member of text, lists and dates.
    case data
    case function
    case action
    /// A case of a choice or a named color.
    case choice
    /// `if`, `for`, `variable`, `true`…
    case keyword
    /// A `variable`, `saved` or `computed` value.
    case variable
    case loopVariable
    case option
    case style
    /// A named element.
    case element
    /// An argument label.
    case label
    case unit
    case formatOption
    /// A picture of the folder.
    case file
    case font
    case symbol
    /// A text to translate.
    case translation
    /// A language tag.
    case language
}

/// One completion item.
public struct DeskCompletionItem: Sendable, Hashable, CustomStringConvertible {
    /// What the list shows: `Column`, `font`, `.caption`, `columns:`, `ms`.
    public var label: String
    public var kind: DeskCompletionItemKind
    /// Its parameters (or its type) in words.
    public var detail: LocalizedText
    /// What it does, in both languages.
    public var documentation: LocalizedText?
    /// Its catalog example (Desk code), when it has one.
    public var example: String?
    /// The text inserted, in LSP snippet syntax (`${1:…}` tab stops, `$0` the final cursor).
    public var insertText: String
    /// The same text with the preview values filled in and no tab stops, for editors without snippets.
    public var plainText: String
    /// `insertText` has tab stops.
    public var isSnippet: Bool
    /// The range of the text it replaces.
    public var range: DeskRange
    /// The words it is found by: its label, the catalog's keywords and other languages' spellings.
    public var filterText: String
    /// The order of the list: how well it matches, whether it fits the expected type, how near its scope is, its
    /// popularity, then the earliest release.
    public var sortText: String
    public var isDeprecated: Bool
    /// A modifier that may be written once is already on the element (it may still be added with `if:`).
    public var isAlreadyPresent: Bool
    /// Typing one of these accepts the item and is then typed itself.
    public var commitCharacters: [String]
    /// The catalog entry, for a hover card of the item.
    public var catalogPath: CatalogPath?
    /// Other edits the item needs, outside its range: a permission it needs added to `info { permissions: […] }`.
    public var additionalEdits: [DeskTextEditU16]

    public init(label: String, kind: DeskCompletionItemKind, detail: LocalizedText, documentation: LocalizedText?,
                example: String? = nil, insertText: String, plainText: String, isSnippet: Bool, range: DeskRange,
                filterText: String, sortText: String, isDeprecated: Bool = false, isAlreadyPresent: Bool = false,
                commitCharacters: [String] = [], catalogPath: CatalogPath? = nil, additionalEdits: [DeskTextEditU16] = []) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.example = example
        self.insertText = insertText
        self.plainText = plainText
        self.isSnippet = isSnippet
        self.range = range
        self.filterText = filterText
        self.sortText = sortText
        self.isDeprecated = isDeprecated
        self.isAlreadyPresent = isAlreadyPresent
        self.commitCharacters = commitCharacters
        self.catalogPath = catalogPath
        self.additionalEdits = additionalEdits
    }

    public var description: String { "\(label) (\(kind.rawValue))" }
}

/// The items at a position, best first.
public struct DeskCompletionList: Sendable, Hashable {
    public var context: DeskCompletionContext
    public var items: [DeskCompletionItem]
    /// More items matched than the limit allowed: ask again as the person types.
    public var isIncomplete: Bool

    public init(context: DeskCompletionContext, items: [DeskCompletionItem], isIncomplete: Bool) {
        self.context = context
        self.items = items
        self.isIncomplete = isIncomplete
    }

    public var labels: [String] { items.map(\.label) }
}

extension DeskSnapshot {
    /// The completion items at a position, best first, at most `limit` of them.
    public func completions(at position: DeskPosition, limit: Int = 200) -> DeskCompletionList {
        let scan = scanCompletion(at: position)
        var builder = DeskCompletionBuilder(snapshot: self, scan: scan)
        builder.collect()
        let (items, truncated) = builder.finish(limit: limit)
        return DeskCompletionList(context: scan.context, items: items, isIncomplete: truncated)
    }

    /// The newest release an offered item may come from: the file's `requires` and the Deskset it is checked for,
    /// whichever is older (D89).
    var completionCeiling: AppVersion {
        let catalog = options.catalog
        let target = options.targetAppVersion ?? options.appVersion ?? catalog.newestSince
        if let requires = tree.header.requires { return min(requires, target) }
        return target
    }
}

// MARK: - Templates

/// An item made once per catalog, placed and ranked per request.
struct DeskCompletionTemplate: Sendable {
    var label: String
    var kind: DeskCompletionItemKind
    var detail: LocalizedText
    var documentation: LocalizedText?
    var example: String?
    /// Snippet text; `\n` starts a line at the cursor line's indentation and `\t` is one level of indentation.
    var snippet: String
    var plain: String
    /// Other words it is found by, normalized (lower case, no `-`, `_` or spaces).
    var words: [String]
    /// The same words as written, for the item's filter text.
    var spelledWords: [String]
    var rank: Int
    var since: AppVersion
    var deprecated: Bool
    var path: CatalogPath?
    var commit: [String]
    /// The type of the value it stands for, to rank it against the expected type.
    var valueType: DeskType?
    /// The snippet's parentheses or braces: left out when the name is followed by `(` already.
    var nameOnly: String?
    /// The call the snippet writes, when one of its values names something of the file (a variable a control
    /// changes, a style, an element): written again at the cursor with a name that exists there.
    var call: DeskSnippetCall?
    /// The permission it needs (`music` for `music.play()`).
    var permission: String?

    init(label: String, kind: DeskCompletionItemKind, detail: LocalizedText, documentation: LocalizedText? = nil,
         example: String? = nil, snippet: String? = nil, plain: String? = nil, words: [String] = [], rank: Int = 50,
         since: AppVersion = .deskFirstRelease, deprecated: Bool = false, path: CatalogPath? = nil, commit: [String] = [],
         valueType: DeskType? = nil, nameOnly: String? = nil, call: DeskSnippetCall? = nil, permission: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.example = example
        self.snippet = snippet ?? DeskSnippet.escapeLiteral(label)
        self.plain = plain ?? label
        self.words = words.map(DeskCatalog.normalizedKeyword).filter { !$0.isEmpty }
        var spelled: [String] = []
        for w in words where !w.isEmpty && w != label && !spelled.contains(w) { spelled.append(w) }
        self.spelledWords = spelled
        self.rank = rank
        self.since = since
        self.deprecated = deprecated
        self.path = path
        self.commit = commit
        self.valueType = valueType
        self.nameOnly = nameOnly
        self.call = call.flatMap { c in c.params.contains(where: DeskSnippetCall.namesSomething) ? c : nil }
        self.permission = permission
    }
}

/// A call a snippet writes: its name, the parameters written, and whether a block follows.
struct DeskSnippetCall: Sendable {
    var name: String
    var params: [ParamSpec]
    var block: Bool

    /// A value that names something of the file: a binding, a style, an element.
    static func namesSomething(_ p: ParamSpec) -> Bool {
        if case .binding = p.type { return true }
        if p.role == .styleRef || p.role == .elementName || p.role == .declaresElementName || p.type == .styleRef { return true }
        // A preview that reads data needing a permission (`.onChange(music.title)`): an own value may stand in.
        return p.type == .any && p.previewValue?.contains(".") == true
    }
}

/// Snippet text: tab stops filled with preview values, and the plain text beside it.
enum DeskSnippet {
    /// `\`, `$` and `}` escaped for a placeholder's text.
    static func escapePlaceholder(_ text: String) -> String {
        var out = ""
        for c in text {
            if c == "\\" || c == "$" || c == "}" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// `\` and `$` escaped for text outside placeholders.
    static func escapeLiteral(_ text: String) -> String {
        var out = ""
        for c in text {
            if c == "\\" || c == "$" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// A tab stop holding a value: a quoted value gets its tab stop inside the quotes.
    static func stop(_ n: Int, _ value: String) -> (snippet: String, plain: String) {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""), !value.dropFirst().dropLast().contains("\"") {
            let inner = String(value.dropFirst().dropLast())
            return ("\"${\(n):\(escapePlaceholder(inner))}\"", value)
        }
        return ("${\(n):\(escapePlaceholder(value))}", value)
    }

    /// Desk text standing for a value of a type, when the catalog gives no preview.
    static func placeholder(for type: DeskType, catalog: DeskCatalog) -> String {
        switch type {
        case .number(let d):
            switch d {
            case .length: return "8"
            case .time: return "1s"
            case .percent: return "50%"
            case .bytes: return "1GB"
            case .bytesPerSecond: return "1MB/s"
            case .angle: return "45°"
            case .temperature: return "50°C"
            default: return "1"
            }
        case .anyNumber, .fraction: return "1"
        case .string, .json, .secret, .folderPath: return "\"Hello\""
        case .symbolName: return "\"star\""
        case .imageSource: return "\"picture.png\""
        case .fontFamily: return "\"Helvetica Neue\""
        case .bool: return "true"
        case .color, .paint: return ".accent"
        case .lengthSpec: return ".fill"
        case .enumeration(let id):
            return catalog.enumeration(id)?.cases.first.map { "." + $0.name } ?? "nil"
        case .list: return "[]"
        case .binding(let inner): return placeholder(for: inner, catalog: catalog)
        case .oneOf(let types):
            let preferred = types.first { if case .enumeration = $0 { return true } else { return false } } ?? types.first
            return preferred.map { placeholder(for: $0, catalog: catalog) } ?? "1"
        default: return "1"
        }
    }

    /// The Desk text a parameter's tab stop starts with.
    static func value(of param: ParamSpec, catalog: DeskCatalog) -> String {
        if let preview = param.previewValue { return preview }
        if case .source(let text)? = param.defaultValue { return text }
        return placeholder(for: param.type, catalog: catalog)
    }

    /// The parameters a snippet writes: the required ones (positional first), or, when none is required, the first
    /// positional one that has a preview.
    static func params(of signature: Signature) -> [ParamSpec] {
        let required = signature.params.filter(\.required)
        if !required.isEmpty {
            return required.filter { $0.label == nil } + required.filter { $0.label != nil }
        }
        if let first = signature.params.first, first.label == nil, first.previewValue != nil, !first.variadic { return [first] }
        return []
    }

    /// `name(args)`, `name(args) {⏎\t$0⏎}` or `name {⏎\t$0⏎}`; tab stops numbered from `first`.
    static func call(_ name: String, params: [ParamSpec], block: Bool, first: Int = 1, forceParentheses: Bool = true,
                     catalog: DeskCatalog, values: ((ParamSpec) -> String?)? = nil) -> (snippet: String, plain: String) {
        var snippet = escapeLiteral(name)
        var plain = name
        var n = first
        if !params.isEmpty || !block || forceParentheses && !block {
            var s: [String] = []
            var p: [String] = []
            for param in params {
                let (stopText, plainText) = stop(n, values?(param) ?? value(of: param, catalog: catalog))
                n += 1
                if let label = param.label {
                    s.append("\(label): \(stopText)")
                    p.append("\(label): \(plainText)")
                } else {
                    s.append(stopText)
                    p.append(plainText)
                }
            }
            snippet += "(" + s.joined(separator: ", ") + ")"
            plain += "(" + p.joined(separator: ", ") + ")"
        }
        if block {
            snippet += " {\n\t$0\n}"
            plain += " {\n\t\n}"
        } else if n > first {
            snippet += "$0"
        }
        return (snippet, plain)
    }

    /// Lays a template's text out at the cursor: `\n` continues at the line's indentation, `\t` is one level.
    static func place(_ text: String, indentation: String, unit: String) -> String {
        guard text.contains("\n") || text.contains("\t") else { return text }
        return text.replacingOccurrences(of: "\t", with: unit).replacingOccurrences(of: "\n", with: "\n" + indentation)
    }
}

/// Every template of one catalog, made on first use.
final class DeskCompletionCatalog: @unchecked Sendable {
    let components: [DeskCompletionTemplate]
    let controls: [DeskCompletionTemplate]
    let modifiers: [(spec: ModifierSpec, template: DeskCompletionTemplate)]
    let namespaces: [String: DeskCompletionTemplate]
    /// By namespace name; nested namespaces are listed as members of their parent.
    let members: [String: [(member: MemberSpec?, template: DeskCompletionTemplate)]]
    let functions: [(spec: FunctionSpec, template: DeskCompletionTemplate)]
    let infoFields: [DeskCompletionTemplate]
    let packageFields: [DeskCompletionTemplate]
    /// Cases by enum id, named values by type (`Color`, `Paint`), without the dot.
    let cases: [String: [DeskCompletionTemplate]]
    let units: [(spec: UnitSpec, template: DeskCompletionTemplate)]
    let formatOptions: [(spec: FormatOptionSpec, template: DeskCompletionTemplate)]

    private static let lock = NSLock()
    private static var built: [(index: WeakIndex, value: DeskCompletionCatalog)] = []

    private struct WeakIndex {
        weak var index: CatalogIndex?
    }

    static func of(_ catalog: DeskCatalog) -> DeskCompletionCatalog {
        let index = catalog.index
        lock.lock()
        defer { lock.unlock() }
        built.removeAll { $0.index.index == nil }
        if let found = built.first(where: { $0.index.index === index }) { return found.value }
        let made = DeskCompletionCatalog(catalog)
        built.append((WeakIndex(index: index), made))
        return made
    }

    private init(_ catalog: DeskCatalog) {
        typealias L = LocalizedText
        // Other languages' spellings, by the Desk name they stand for.
        var synonyms: [String: [String]] = [:]
        for row in catalog.foreign {
            let target = DeskCompletionCatalog.leadingName(of: row.deskText)
            guard !target.isEmpty else { continue }
            switch row.pattern {
            case .name(let s): synonyms[target, default: []].append(s)
            case .modifier(let s), .modifierWithArgument(let s, _): synonyms["." + target, default: []].append(s)
            case .implicitMember(let s): synonyms["." + target, default: []].append(s)
            case .member(let s): synonyms[target, default: []].append(String(s.split(separator: ".").last ?? ""))
            case .call(let s, _): synonyms[target, default: []].append(s)
            default: break
            }
        }
        func words(_ doc: Doc, _ key: String) -> [String] { doc.keywords + (synonyms[key] ?? []) }
        func docText(_ doc: Doc) -> L { L(doc.en, doc.zh) }
        func shape(_ signature: Signature?) -> L {
            guard let signature else { return L("", "") }
            let shown = signature.params.filter { $0.required }
            var en: [String] = []
            var zh: [String] = []
            for p in shown {
                let words = catalog.displayName(for: p.type)
                if let label = p.label {
                    en.append("\(label) (\(words.en))")
                    zh.append("\(label)（\(words.zh)）")
                } else {
                    en.append(words.en)
                    zh.append(words.zh)
                }
            }
            if signature.params.count > shown.count {
                en.append("…")
                zh.append("…")
            }
            return L("(" + en.joined(separator: ", ") + ")", "（" + zh.joined(separator: "，") + "）")
        }
        func firstSignature(_ signatures: [Signature]) -> Signature? {
            signatures.min { $0.since < $1.since }
        }

        // Components.
        var components: [DeskCompletionTemplate] = []
        for c in catalog.components {
            let signature = firstSignature(c.signatures)
            let hasBlock: Bool
            switch c.block {
            case .none: hasBlock = false
            default: hasBlock = true
            }
            let text = DeskSnippet.call(c.name, params: signature.map(DeskSnippet.params) ?? [], block: hasBlock, catalog: catalog)
            components.append(DeskCompletionTemplate(
                label: c.name, kind: .component, detail: L(c.title.en + " " + shape(signature).en, c.title.zh + shape(signature).zh),
                documentation: docText(c.doc), example: c.doc.example, snippet: text.snippet, plain: text.plain,
                words: words(c.doc, c.name), rank: c.doc.rank, since: c.doc.since, deprecated: c.doc.deprecated != nil,
                path: .component(c.name), nameOnly: c.name,
                call: DeskSnippetCall(name: c.name, params: signature.map(DeskSnippet.params) ?? [], block: hasBlock)))
        }
        self.components = components

        // Option controls, as the value after `name =`.
        var controls: [DeskCompletionTemplate] = []
        for c in catalog.controls where c.panel != .choice {
            let signature = firstSignature(c.signatures)
            let block: Bool
            if case .optionItems = c.block { block = true } else { block = false }
            let text = DeskSnippet.call(c.name, params: signature.map(DeskSnippet.params) ?? [], block: block, catalog: catalog)
            controls.append(DeskCompletionTemplate(
                label: c.name, kind: .control, detail: L(c.title.en + " " + shape(signature).en, c.title.zh + shape(signature).zh),
                documentation: docText(c.doc), example: c.doc.example, snippet: text.snippet, plain: text.plain,
                words: words(c.doc, c.name), rank: c.doc.rank, since: c.doc.since, deprecated: c.doc.deprecated != nil,
                path: .control(c.name), nameOnly: c.name))
        }
        self.controls = controls

        // Modifiers, written without their dot.
        var modifiers: [(ModifierSpec, DeskCompletionTemplate)] = []
        for m in catalog.modifiers {
            let signature = firstSignature(m.signatures)
            let block: Bool
            switch m.block {
            case .none: block = false
            default: block = true
            }
            var params = signature.map(DeskSnippet.params) ?? []
            // A timing modifier's interval is written even when the catalog lets it be left out.
            if params.isEmpty, block, let first = signature?.params.first, first.label == nil, first.previewValue != nil {
                params = [first]
            }
            let text = DeskSnippet.call(m.name, params: params, block: block, catalog: catalog)
            modifiers.append((m, DeskCompletionTemplate(
                label: m.name, kind: .modifier, detail: L(m.title.en + " " + shape(signature).en, m.title.zh + shape(signature).zh),
                documentation: docText(m.doc), example: m.doc.example, snippet: text.snippet, plain: text.plain,
                words: words(m.doc, "." + m.name), rank: m.doc.rank, since: m.doc.since, deprecated: m.doc.deprecated != nil,
                path: .modifier(m.name), commit: [], nameOnly: m.name, call: DeskSnippetCall(name: m.name, params: params, block: block))))
        }
        self.modifiers = modifiers

        // Namespaces and their members.
        var namespaces: [String: DeskCompletionTemplate] = [:]
        var members: [String: [(MemberSpec?, DeskCompletionTemplate)]] = [:]
        func memberTemplate(_ m: MemberSpec, path: CatalogPath, key: String, permission: String?) -> DeskCompletionTemplate {
            let signature = firstSignature(m.signatures)
            let kind: DeskCompletionItemKind = m.kind == .action ? .action : m.kind == .function ? .function : .data
            var snippet = DeskSnippet.escapeLiteral(m.name)
            var plain = m.name
            var detail = catalog.displayName(for: m.type)
            if m.kind != .field {
                let text = DeskSnippet.call(m.name, params: signature.map(DeskSnippet.params) ?? [], block: false, catalog: catalog)
                snippet = text.snippet
                plain = text.plain
                detail = shape(signature)
            }
            return DeskCompletionTemplate(
                label: m.name, kind: kind, detail: L(m.title.en + " · " + detail.en, m.title.zh + " · " + detail.zh),
                documentation: docText(m.doc), example: m.doc.example, snippet: snippet, plain: plain,
                words: words(m.doc, key), rank: m.doc.rank, since: m.doc.since, deprecated: m.doc.deprecated != nil,
                path: path, commit: m.kind == .field ? ["."] : [], valueType: m.kind == .action ? nil : m.type,
                nameOnly: m.name, permission: permission)
        }
        for ns in catalog.namespaces {
            let parts = ns.name.split(separator: ".").map(String.init)
            let template = DeskCompletionTemplate(
                label: parts.last ?? ns.name, kind: .namespace, detail: ns.title, documentation: docText(ns.doc),
                example: ns.doc.example, words: words(ns.doc, ns.name), rank: ns.doc.rank, since: ns.doc.since,
                deprecated: ns.doc.deprecated != nil, path: .namespace(ns.name), commit: ["."],
                valueType: ns.value?.type ?? ns.instanceOf.map { .record($0) })
            namespaces[ns.name] = template
            if parts.count > 1 {
                members[parts.dropLast().joined(separator: "."), default: []].append((nil, template))
            }
            for m in ns.members {
                members[ns.name, default: []].append((m, memberTemplate(m, path: .member(namespace: ns.name, name: m.name),
                                                                        key: "\(ns.name).\(m.name)",
                                                                        permission: m.permission ?? ns.permission)))
            }
        }
        self.namespaces = namespaces
        self.members = members

        // Global functions and actions.
        var functions: [(FunctionSpec, DeskCompletionTemplate)] = []
        for f in catalog.functions {
            let signature = firstSignature(f.signatures)
            let text = DeskSnippet.call(f.name, params: signature.map(DeskSnippet.params) ?? [], block: f.takesActionBlock,
                                        catalog: catalog)
            var type: DeskType?
            if case .fixed(let t)? = signature?.result { type = t }
            if let data = f.data { type = data.type }
            functions.append((f, DeskCompletionTemplate(
                label: f.name, kind: f.kind == .action ? .action : .function,
                detail: L(f.title.en + " " + shape(signature).en, f.title.zh + shape(signature).zh),
                documentation: docText(f.doc), example: f.doc.example, snippet: text.snippet, plain: text.plain,
                words: words(f.doc, f.name), rank: f.doc.rank, since: f.doc.since, deprecated: f.doc.deprecated != nil,
                path: .function(f.name), valueType: type, nameOnly: f.name,
                call: DeskSnippetCall(name: f.name, params: signature.map(DeskSnippet.params) ?? [], block: f.takesActionBlock),
                permission: f.permission ?? f.data?.permission)))
        }
        self.functions = functions

        // `info` and `package` fields: `name: value`, the value from the field's example.
        func fieldTemplate(_ f: FieldSpec, package: Bool) -> DeskCompletionTemplate {
            var value = DeskSnippet.placeholder(for: f.type, catalog: catalog)
            let example = f.doc.example.trimmingCharacters(in: .whitespaces)
            if example.hasPrefix(f.name + ":") {
                value = String(example.dropFirst(f.name.count + 1)).trimmingCharacters(in: .whitespaces)
            } else if case .source(let text)? = f.defaultValue, text != "\"\"" {
                value = text
            }
            let stop = DeskSnippet.stop(1, value)
            return DeskCompletionTemplate(
                label: f.name, kind: .field, detail: catalog.displayName(for: f.type), documentation: docText(f.doc),
                example: f.doc.example, snippet: "\(f.name): \(stop.snippet)$0", plain: "\(f.name): \(stop.plain)",
                words: f.doc.keywords, rank: f.doc.rank, since: f.doc.since, deprecated: f.doc.deprecated != nil,
                path: package ? .packageField(f.name) : .infoField(f.name))
        }
        infoFields = catalog.infoFields.map { fieldTemplate($0, package: false) }
        packageFields = catalog.packageFields.map { fieldTemplate($0, package: true) }

        // Choices: enum cases and named values.
        var cases: [String: [DeskCompletionTemplate]] = [:]
        for e in catalog.enums {
            for k in e.cases {
                cases[e.id, default: []].append(DeskCompletionTemplate(
                    label: k.name, kind: .choice, detail: k.title ?? L(k.name, k.name), documentation: docText(e.doc),
                    words: k.keywords + k.foreignSpellings + (synonyms["." + k.name] ?? []), rank: k.rank, since: k.since,
                    path: .enumCase(type: e.id, name: k.name), commit: [",", ")"], valueType: .enumeration(e.id)))
            }
        }
        for v in catalog.namedValues {
            cases[v.type, default: []].append(DeskCompletionTemplate(
                label: v.name, kind: .choice, detail: v.title, documentation: docText(v.doc), example: v.doc.example,
                words: v.keywords + (synonyms["." + v.name] ?? []), rank: v.rank, since: v.doc.since,
                deprecated: v.doc.deprecated != nil, path: .namedValue(type: v.type, name: v.name), commit: [",", ")"],
                valueType: v.type == "Color" ? .color : .paint))
        }
        self.cases = cases

        // Units.
        // The units people write most come first in each dimension.
        let common = ["s", "ms", "min", "h", "d", "%", "pt", "°", "GB", "MB", "KB", "TB", "B", "MB/s", "KB/s", "GB/s", "B/s",
                      "°C", "°F", "GHz", "MHz", "W", "V", "A", "rpm", "km/h", "mph", "mm", "hPa"]
        units = catalog.units.map { u in
            let order = common.firstIndex(of: u.spelling) ?? common.count
            return (u, DeskCompletionTemplate(label: u.spelling, kind: .unit, detail: catalog.displayName(for: .number(u.dimension)),
                                              rank: max(1, 99 - order), commit: [",", ")"], valueType: .number(u.dimension)))
        }

        // Format options.
        formatOptions = catalog.formatOptions.map { f in
            let value = f.type == .string ? "\"–\"" : DeskSnippet.placeholder(for: f.type, catalog: catalog)
            let stop = DeskSnippet.stop(1, f.label == "decimals" ? "1" : value)
            return (f, DeskCompletionTemplate(
                label: f.label + ":", kind: .formatOption, detail: catalog.displayName(for: f.type), documentation: docText(f.doc),
                example: f.doc.example, snippet: "\(f.label): \(stop.snippet)$0", plain: "\(f.label): \(stop.plain)",
                words: [f.label] + f.doc.keywords, rank: f.doc.rank, since: f.doc.since, path: .formatOption(f.label)))
        }
    }

    /// `Column` of `Column(spacing: {0})`, `color` of `.color({0})`.
    static func leadingName(of text: String) -> String {
        var name = ""
        var started = false
        for c in text {
            if !started, c == "." { started = true; continue }
            if c.isLetter || c.isNumber || c == "_" {
                started = true
                name.append(c)
            } else {
                break
            }
        }
        return name
    }
}

// MARK: - Building a list

/// The items of one request: templates chosen for the context, matched against what is typed, placed at the cursor
/// and ranked.
struct DeskCompletionBuilder {
    typealias L = LocalizedText

    let snapshot: DeskSnapshot
    let scan: DeskCompletionScan
    let catalog: DeskCatalog
    let templates: DeskCompletionCatalog
    let ceiling: AppVersion
    let prefix: String
    let foldedPrefix: String
    let indentUnit: String

    /// A candidate with its sort key: (match, tier, nearness, 100 - rank, since, label).
    private var candidates: [(item: DeskCompletionItem, key: (Int, Int, Int, Int, AppVersion, String))] = []
    private var seen = Set<String>()

    init(snapshot: DeskSnapshot, scan: DeskCompletionScan) {
        self.snapshot = snapshot
        self.scan = scan
        catalog = snapshot.options.catalog
        templates = DeskCompletionCatalog.of(catalog)
        ceiling = snapshot.completionCeiling
        prefix = scan.context.prefix
        foldedPrefix = DeskCatalog.normalizedKeyword(scan.context.prefix)
        indentUnit = String(repeating: " ", count: max(1, snapshot.options.format.indentWidth))
    }

    // MARK: Adding

    /// How well an item matches what is typed: 0 its label starts with it as typed, 1 ignoring case, 2 one of its
    /// words starts with it, 3 its label holds the typed letters in order; nil: it does not match.
    func match(_ label: String, words: [String]) -> Int? {
        if prefix.isEmpty { return 0 }
        let bare = label.hasPrefix(".") ? String(label.dropFirst()) : label
        let typed = prefix.hasPrefix(".") ? String(prefix.dropFirst()) : prefix
        if typed.isEmpty { return 0 }
        if bare.hasPrefix(typed) { return 0 }
        let foldedLabel = DeskCatalog.normalizedKeyword(bare)
        let foldedTyped = DeskCatalog.normalizedKeyword(typed)
        if foldedTyped.isEmpty { return 0 }
        if foldedLabel.hasPrefix(foldedTyped) { return 1 }
        if words.contains(where: { $0.hasPrefix(foldedTyped) }) { return 2 }
        // The typed letters in order, the first one first.
        guard let first = foldedTyped.first, foldedLabel.first == first else { return nil }
        var rest = foldedTyped.dropFirst()[...]
        for c in foldedLabel.dropFirst() where c == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty ? 3 : nil
    }

    /// Adds a template, placed at the cursor.
    mutating func add(_ t: DeskCompletionTemplate, tier: Int = 5, nearness: Int = 9, label: String? = nil,
                      snippet: String? = nil, plain: String? = nil, alreadyPresent: Bool = false, kind: DeskCompletionItemKind? = nil,
                      rank: Int? = nil) {
        guard t.since <= ceiling else { return }
        let shown = label ?? t.label
        guard let m = match(shown, words: t.words) else { return }
        let key = "\((kind ?? t.kind).rawValue):\(shown)"
        guard seen.insert(key).inserted else { return }
        var snippetText = snippet ?? t.snippet
        var plainText = plain ?? t.plain
        if let call = t.call, snippet == nil || shown.hasPrefix(".") && !t.label.hasPrefix(".") {
            let me = self
            let text = DeskSnippet.call(call.name, params: call.params, block: call.block, catalog: catalog) { me.contextualValue($0) }
            let lead = snippet != nil ? "." : ""
            snippetText = lead + text.snippet
            plainText = lead + text.plain
        }
        if scan.followedByCall, let name = t.nameOnly {
            // `(` already follows: insert the name only.
            let lead = shown.hasPrefix(".") && !name.hasPrefix(".") ? "." : ""
            snippetText = DeskSnippet.escapeLiteral(lead + name)
            plainText = lead + name
        }
        let insert = DeskSnippet.place(snippetText, indentation: scan.indentation, unit: indentUnit)
        let plainPlaced = DeskSnippet.place(plainText, indentation: scan.indentation, unit: indentUnit)
        let fits = scan.context.expectedType.map { expected in t.valueType.map { DeskCompletionBuilder.fits($0, expected) } ?? false } ?? false
        var tierValue = tier
        if fits, tierValue > 1 { tierValue -= 1 }
        if t.deprecated { tierValue += 10 }
        if alreadyPresent { tierValue += 20 }
        let r = rank ?? t.rank
        let extra = t.permission.map { permissionEdits($0) } ?? []
        let item = DeskCompletionItem(
            label: shown, kind: kind ?? t.kind, detail: t.detail, documentation: t.documentation, example: t.example,
            insertText: insert, plainText: plainPlaced, isSnippet: insert.contains("$"), range: scan.context.range,
            filterText: ([shown] + t.spelledWords).joined(separator: " "), sortText: "", isDeprecated: t.deprecated,
            isAlreadyPresent: alreadyPresent, commitCharacters: t.commit, catalogPath: t.path, additionalEdits: extra)
        candidates.append((item, (m, tierValue, nearness, 200 - max(0, min(200, r)), t.since, shown)))
    }

    /// Ranks and cuts the list.
    func finish(limit: Int) -> ([DeskCompletionItem], Bool) {
        let sorted = candidates.sorted { a, b in
            let x = a.key, y = b.key
            if x.0 != y.0 { return x.0 < y.0 }
            if x.1 != y.1 { return x.1 < y.1 }
            if x.2 != y.2 { return x.2 < y.2 }
            if x.3 != y.3 { return x.3 < y.3 }
            if x.4 != y.4 { return x.4 < y.4 }
            return x.5 < y.5
        }
        let kept = sorted.prefix(max(0, limit))
        var items: [DeskCompletionItem] = []
        items.reserveCapacity(kept.count)
        for (k, candidate) in kept.enumerated() {
            var item = candidate.item
            let key = candidate.key
            item.sortText = String(format: "%d%02d%02d%03d%03d%03d%03d%05d", key.0, min(key.1, 99), min(key.2, 99), key.3,
                                   min(key.4.major, 999), min(key.4.minor, 999), min(key.4.patch, 999), k)
            items.append(item)
        }
        return (items, sorted.count > kept.count)
    }

    /// Whether a value of type `t` suits the expected type `e`.
    static func fits(_ t: DeskType, _ e: DeskType) -> Bool {
        switch e {
        case .binding(let inner): return fits(t, inner)
        case .oneOf(let types): return types.contains { fits(t, $0) }
        case .any, .typeVar: return false
        case .paint: return t == .color || t == .paint
        case .lengthSpec: return t == .enumeration("LengthKeyword") || fits(t, .length)
        case .number(let d):
            if case .number(let own) = t { return own == d }
            return false
        case .anyNumber, .fraction: return t.isNumeric
        case .list(let inner):
            if case .list(let own) = t { return own == inner || inner == .any }
            return false
        default: return t == e
        }
    }

    // MARK: Collecting

    mutating func collect() {
        let context = scan.context
        switch context.place {
        case .none: break
        case .topLevel: addTopLevel()
        case .fields: addFields()
        case .optionItems: addOptionItems()
        case .control: addControls()
        case .views: addViews()
        case .actions: addActions()
        case .modifiers: addModifiers()
        case .member: addMembers()
        case .implicitMember: addChoices(for: context.expectedType, withDot: false, tier: 1)
        case .value: addValues(expected: context.expectedType)
        case .argument: addArgument()
        case .unit: addUnits()
        case .styleName: addStyles()
        case .elementName: addElementNames(tier: 1)
        case .formatOption: addFormatOptions()
        case .imagePath: addImages()
        case .fontFamily: addFonts()
        case .symbolName: addSymbols()
        case .translationKey: addTranslationKeys()
        case .languageTag: addLanguageTags()
        }
    }

    private mutating func snippetItem(_ label: String, kind: DeskCompletionItemKind, detail: L, doc: L? = nil, snippet: String,
                                      plain: String, words: [String] = [], tier: Int = 3, rank: Int = 50) {
        add(DeskCompletionTemplate(label: label, kind: kind, detail: detail, documentation: doc, snippet: snippet, plain: plain,
                                   words: words, rank: rank), tier: tier)
    }

    private mutating func addTopLevel() {
        let table = snapshot.nodeTable
        let present = Set(table.children(of: 0).map { table.entries[$0].kind })
        let isPackage = snapshot.isPackage
        if isPackage {
            if !present.contains(.packageBlock) {
                snippetItem("package", kind: .block, detail: L("The package's name and version", "包的名字和版本"),
                            snippet: "package {\n\tname: \"${1:My widgets}\"\n}$0", plain: "package {\n\tname: \"My widgets\"\n}",
                            tier: 1, rank: 90)
            }
        } else {
            if !present.contains(.infoBlock) {
                snippetItem("info", kind: .block, detail: L("The widget's name, size and permissions", "组件的名字、尺寸和权限"),
                            snippet: "info {\n\tname: \"${1:My widget}\"\n}$0", plain: "info {\n\tname: \"My widget\"\n}",
                            words: ["metadata", "Metadata"], tier: 1, rank: 90)
            }
            if !present.contains(.widgetBlock) {
                snippetItem("widget", kind: .block, detail: L("What the widget shows", "组件显示的内容"),
                            snippet: "widget {\n\tText(\"${1:Hello}\")$0\n}", plain: "widget {\n\tText(\"Hello\")\n}",
                            tier: 1, rank: 100)
            }
        }
        if !present.contains(.optionsBlock) {
            snippetItem("options", kind: .block, detail: L("What people can change in the Options panel", "选项面板里能改的设置"),
                        snippet: "options {\n\t${1:showSeconds} = Toggle(\"${2:Show seconds}\")$0\n}",
                        plain: "options {\n\tshowSeconds = Toggle(\"Show seconds\")\n}", words: ["Variables", "settings"],
                        tier: 1, rank: 70)
        }
        let styleName = uniqueName("card", taken: Set(snapshot.checked.styles.keys).union(snapshot.package?.styles.keys ?? [:].keys))
        snippetItem("style", kind: .block, detail: L("A set of modifiers to reuse", "可以复用的一组修饰"),
                    snippet: "style ${1:\(styleName)} {\n\t.${2:padding(14)}$0\n}", plain: "style \(styleName) {\n\t.padding(14)\n}",
                    words: ["MeterStyle", "class", "css"], tier: 1, rank: 60)
        if !present.contains(.translationsBlock) {
            snippetItem("translations", kind: .block, detail: L("The widget's texts in other languages", "组件文字的其他语言版本"),
                        snippet: "translations {\n\t\"${1:zh-Hans}\" {\n\t\t$0\n\t}\n}",
                        plain: "translations {\n\t\"zh-Hans\" {\n\t\t\n\t}\n}", words: ["localization", "i18n", "language"],
                        tier: 1, rank: 40)
        }
    }

    private mutating func addFields() {
        let table = snapshot.nodeTable
        var written = Set<String>()
        var isPackageBlock = false
        if let block = scan.block {
            let owner = table.entries[block].parent
            isPackageBlock = owner >= 0 && table.entries[owner].kind == .packageBlock
            for c in table.children(of: block) where table.entries[c].kind == .field {
                if let label = table.children(of: c).first, let token = table.entries[label].positioned.childTokens.first,
                   !token.token.isMissing, token.textRange.upperBound < scan.utf8Range.lowerBound || token.textStart > scan.utf8Range.upperBound {
                    written.insert(token.token.name)
                }
            }
        }
        for t in isPackageBlock ? templates.packageFields : templates.infoFields where !written.contains(t.label) {
            add(t, tier: 1)
        }
    }

    private mutating func addOptionItems() {
        let taken = Set(snapshot.checked.options.keys).union(snapshot.package?.options.keys.map { $0 } ?? [])
        for t in templates.controls {
            let isSection = catalog.control(named: t.label)?.block == .optionItems
            if isSection {
                add(t, tier: 1, label: t.label)
                continue
            }
            let name = uniqueName(DeskCompletionBuilder.optionName(for: t.label), taken: taken)
            // `name = Control(…)`: the control's tab stops after the name's.
            let shifted = DeskCompletionBuilder.shiftStops(t.snippet, by: 1)
            add(t, tier: 1, snippet: "${1:\(name)} = " + shifted, plain: "\(name) = " + t.plain)
        }
    }

    private mutating func addControls() {
        for t in templates.controls where catalog.control(named: t.label)?.block != .optionItems { add(t, tier: 1) }
    }

    private mutating func addViews() {
        let context = scan.context
        for t in templates.components {
            guard let spec = catalog.component(named: t.label) else { continue }
            let menuEntry = spec.group == .menuEntries || spec.kind == .divider
            if context.inMenu {
                guard menuEntry else { continue }
                add(t, tier: spec.group == .menuEntries ? 2 : 3)
                continue
            } else if spec.group == .menuEntries {
                continue
            }
            add(t, tier: 3)
        }
        addControlFlow()
        if context.allowsDeclarations {
            let taken = Set(snapshot.visibleOwnNames(at: scan.utf8Range.lowerBound).map(\.name))
            let name = uniqueName("count", taken: taken)
            snippetItem("variable", kind: .keyword, detail: L("A value for this session", "这次运行期间的值"),
                        snippet: "variable ${1:\(name)} = ${2:0}$0", plain: "variable \(name) = 0", words: ["let", "var", "state"],
                        tier: 4, rank: 70)
            snippetItem("saved", kind: .keyword, detail: L("A value kept across launches", "重新打开后还在的值"),
                        snippet: "saved ${1:\(name)} = ${2:0}$0", plain: "saved \(name) = 0", words: ["AppStorage", "persist"],
                        tier: 4, rank: 50)
            snippetItem("computed", kind: .keyword, detail: L("A value worked out from others", "由其他值算出的值"),
                        snippet: "computed ${1:\(name)} = ${2:cpu.usage}$0", plain: "computed \(name) = cpu.usage",
                        words: ["let", "derived"], tier: 4, rank: 60)
        }
    }

    /// `if`, `if … else` and `for`, in view and action blocks alike.
    private mutating func addControlFlow() {
        snippetItem("if", kind: .keyword, detail: L("Only when a condition holds", "条件成立时才有"),
                    snippet: "if ${1:widget.size == .large} {\n\t$0\n}", plain: "if widget.size == .large {\n\t\n}",
                    words: ["when", "condition"], tier: 4, rank: 70)
        snippetItem("if else", kind: .keyword, detail: L("One thing or another", "二选一"),
                    snippet: "if ${1:widget.size == .large} {\n\t$2\n} else {\n\t$0\n}",
                    plain: "if widget.size == .large {\n\t\n} else {\n\t\n}", words: ["else"], tier: 4, rank: 55)
        snippetItem("for", kind: .keyword, detail: L("Once for each item of a list", "列表里每一项一次"),
                    snippet: "for ${1:item} in ${2:[1, 2, 3]} {\n\t$0\n}", plain: "for item in [1, 2, 3] {\n\t\n}",
                    words: ["ForEach", "map", "loop", "each"], tier: 4, rank: 65)
    }

    private mutating func addActions() {
        let context = scan.context
        let hasNamedElement = snapshot.checked.elements.values.contains { $0.name != nil }
        for (spec, t) in templates.functions where spec.kind == .action {
            if spec.userInitiatedOnly && !context.userInitiated { continue }
            // `show`, `hide` and `showOrHide` name an element: offered once one has a name.
            if !hasNamedElement, spec.signatures.contains(where: { $0.params.contains { $0.role == .elementName } }) { continue }
            add(t, tier: 2)
        }
        addControlFlow()
        // Values that may be assigned: variables and saved values, options, settable data.
        for own in snapshot.visibleOwnNames(at: scan.utf8Range.lowerBound) where own.kind == .variable || own.kind == .saved {
            add(DeskCompletionTemplate(label: own.name, kind: .variable, detail: ownDetail(own), commit: [" "], valueType: own.type),
                tier: 1, nearness: own.nearness)
        }
        if let options = templates.namespaces["options"], !allOptions().isEmpty { add(options, tier: 3) }
        for (name, t) in templates.namespaces where !name.contains(".") && name != "options" {
            let members = templates.members[name] ?? []
            let actionable = members.contains { entry in
                guard let m = entry.member else { return false }
                if m.kind == .action { return !m.userInitiatedOnly || context.userInitiated }
                return m.settable
            }
            if actionable { add(t, tier: 3) }
        }
    }

    private mutating func addModifiers() {
        let context = scan.context
        let site = context.modifierSite ?? .element
        for (spec, t) in templates.modifiers {
            switch site {
            case .option:
                guard spec.context == .option || spec.context == .both else { continue }
            case .style:
                guard spec.allowedInStyle, spec.context != .option else { continue }
            case .state:
                guard spec.allowedInState, spec.context != .option else { continue }
            case .element:
                guard spec.context != .option else { continue }
            }
            if let kind = context.elementKind, site != .option, !spec.appliesTo.contains(kind) { continue }
            // Modifiers made for this kind of element (a shape's fill, a picture's tint) come before general ones.
            let specific = context.elementKind != nil && spec.appliesTo.kinds.count <= 8
            if spec.name == "rainmeter", !isConvertedFile { continue }
            if spec.name == "style", !hasUsableStyle { continue }
            if spec.name == "position", site == .element, let parent = ownerParentKind, parent != .freeform { continue }
            let present = spec.repeatable == .no && scan.presentModifiers.contains(spec.name)
            let rank = t.rank + (specific ? 25 : 0)
            if scan.dotTyped {
                add(t, tier: 1, alreadyPresent: present, rank: rank)
            } else {
                add(t, tier: 1, label: "." + t.label, snippet: "." + t.snippet, plain: "." + t.plain, alreadyPresent: present, rank: rank)
            }
        }
    }

    private mutating func addMembers() {
        let context = scan.context
        guard let base = context.memberBase else { return }
        switch base {
        case .namespace(let ns) where ns == "options":
            for (name, facts) in allOptions() {
                add(DeskCompletionTemplate(label: name, kind: .option, detail: catalog.displayName(for: facts.type),
                                           documentation: nil, commit: ["."], valueType: facts.type),
                    tier: 1, nearness: facts.scope == .widget ? 0 : 1)
            }
        case .namespace(let ns):
            for (member, t) in templates.members[ns] ?? [] {
                guard let member else {
                    add(t, tier: 3)
                    continue
                }
                switch member.kind {
                case .action:
                    // An action is a statement of an action block, never a value.
                    guard context.inActions, scan.memberStatement else { continue }
                    if member.userInitiatedOnly && !context.userInitiated { continue }
                    add(t, tier: 1)
                case .function, .field:
                    if scan.memberStatement && context.inActions && !member.settable && member.kind == .field {
                        // Only settable data may start an action statement.
                        continue
                    }
                    if !suits(t.valueType, nil) { continue }
                    add(t, tier: 2)
                }
            }
        case .value(let type):
            addValueMembers(of: type)
        case .element(let name):
            for (k, (member, en, zh)) in DeskCompletionBuilder.geometry.enumerated() {
                add(DeskCompletionTemplate(label: member, kind: .data, detail: L(en, zh),
                                           documentation: L("Where \(name) is in its Freeform, in points", "\(name) 在自由摆放里的位置，单位是点"),
                                           rank: 90 - k, commit: [",", ")"], valueType: .length), tier: 1)
            }
        }
    }

    static let geometry: [(String, String, String)] = [
        ("left", "Left edge", "左边"), ("right", "Right edge", "右边"), ("top", "Top edge", "上边"),
        ("bottom", "Bottom edge", "下边"), ("width", "Width", "宽度"), ("height", "Height", "高度"),
        ("centerX", "Middle, across", "水平中点"), ("centerY", "Middle, up and down", "竖直中点"),
    ]

    private mutating func addValueMembers(of type: DeskType) {
        var seenNames = Set<String>()
        for m in catalog.members(of: type) {
            guard m.kind != .action || scan.context.inActions && scan.memberStatement else { continue }
            let key = m.name + (m.kind == .field ? "" : "()")
            guard seenNames.insert(key).inserted else { continue }
            let signature = m.signatures.min { $0.since < $1.since }
            // What the member gives, and what its type variable stands for: the value itself (`ifMissing`), or a
            // list's item (`contains`).
            var element: DeskType = type
            if case .list(let inner) = type, catalog.index.typeMember("List", m.name, call: m.kind != .field) != nil { element = inner }
            var result = m.type
            switch signature?.result {
            case .receiver?: result = type
            case .elementOf?: if case .list(let inner) = type { result = inner }
            case .fixed(let t)?: result = t
            default: break
            }
            if !suits(result, nil) { continue }
            let written = signature.map(DeskSnippet.params) ?? []
            let takesItem = written.contains { if case .typeVar = $0.type { return true } else { return false } }
            var unwritable = false
            if takesItem {
                switch element {
                case .record, .any, .json, .typeVar: unwritable = true
                default: break
                }
            }
            let catalog = self.catalog
            let itemValue: String? = {
                switch element {
                case .string, .symbolName, .imageSource, .fontFamily, .folderPath: return nil
                default: return DeskSnippet.placeholder(for: element, catalog: catalog)
                }
            }()
            let values: (ParamSpec) -> String? = { p in
                if case .typeVar = p.type { return itemValue }
                return nil
            }
            var path: CatalogPath?
            if case .record(let id) = type, catalog.record(id)?.field(named: m.name) != nil {
                path = .recordField(record: id, name: m.name)
            } else if case .list(.record(let id)) = type, catalog.record(id)?.field(named: m.name) != nil,
                      catalog.index.typeMember("List", m.name, call: m.kind != .field) == nil {
                path = .recordField(record: id, name: m.name)
            } else if let valueType = DeskCatalog.valueTypeName(of: type), catalog.index.typeMember(valueType, m.name, call: m.kind != .field) != nil {
                path = .typeMember(type: valueType, name: m.name)
            } else {
                path = .typeMember(type: "Any", name: m.name)
            }
            var snippet = DeskSnippet.escapeLiteral(m.name)
            var plain = m.name
            if m.kind != .field {
                let text = DeskSnippet.call(m.name, params: signature.map(DeskSnippet.params) ?? [], block: false, catalog: catalog,
                                            values: values)
                snippet = text.snippet
                plain = text.plain
            }
            // A value of the list's items can't be written out (records): the member is of no use here.
            if unwritable { continue }
            let kind: DeskCompletionItemKind = m.kind == .action ? .action : m.kind == .function ? .function : .data
            let tier = path.map { if case .typeMember("Any", _) = $0 { return 3 } else { return 1 } } ?? 2
            add(DeskCompletionTemplate(label: m.name, kind: kind, detail: L(m.title.en + " · " + catalog.displayName(for: m.type).en,
                                                                            m.title.zh + " · " + catalog.displayName(for: m.type).zh),
                                       documentation: L(m.doc.en, m.doc.zh), example: m.doc.example, snippet: snippet, plain: plain,
                                       words: m.doc.keywords, rank: m.doc.rank, since: m.doc.since,
                                       deprecated: m.doc.deprecated != nil, path: path, commit: m.kind == .field ? ["."] : [],
                                       valueType: result, nameOnly: m.name),
                tier: tier)
        }
    }

    /// Choices of a type: enum cases, named colors and paints, `.fit`/`.fill`; every choice when the type is not
    /// known. `withDot`: written where no dot is typed yet.
    private mutating func addChoices(for expected: DeskType?, withDot: Bool, tier: Int) {
        func addCases(_ key: String, typeFilter: ((DeskCompletionTemplate) -> Bool)? = nil) {
            for t in templates.cases[key] ?? [] where typeFilter?(t) ?? true {
                if withDot {
                    add(t, tier: tier, label: "." + t.label, snippet: "." + t.snippet, plain: "." + t.plain)
                } else {
                    add(t, tier: tier)
                }
            }
        }
        func addFor(_ type: DeskType) {
            switch type {
            case .enumeration(let id):
                if let local = localEnumChoices(id) {
                    for choice in local {
                        let t = DeskCompletionTemplate(label: choice, kind: .choice, detail: L(id, id), commit: [",", ")"],
                                                       valueType: type)
                        if withDot { add(t, tier: tier, label: "." + choice, snippet: "." + choice, plain: "." + choice) } else { add(t, tier: tier) }
                    }
                } else {
                    addCases(id)
                }
            case .color: addCases("Color")
            case .paint:
                addCases("Color")
                addCases("Paint")
            case .lengthSpec: addCases("LengthKeyword")
            case .size, .record("Size"):
                // A widget's size compares with its preset (`widget.size == .small`).
                addCases("SizePreset")
            case .oneOf(let types): types.forEach(addFor)
            case .binding(let inner): addFor(inner)
            case .list(let inner) where withDot == false: addFor(inner)
            default: break
            }
        }
        if let expected, expected != .any {
            addFor(expected)
        } else if !withDot {
            // Nothing is known: every choice, the most common first.
            for key in templates.cases.keys.sorted() { addCases(key) }
        }
    }

    /// A Picker's own choices, when `id` is the local enum it makes (`Theme`).
    private func localEnumChoices(_ id: String) -> [String]? {
        for facts in allOptions().values where facts.localEnum == id { return facts.choices }
        return nil
    }

    /// Values: choices of the expected type, own names in scope, `options`, data, functions and literals.
    private mutating func addValues(expected: DeskType?) {
        let context = scan.context
        let offset = scan.utf8Range.lowerBound
        if expected == .styleRef { addStyles(); return }
        if expected == .elementName { addElementNames(tier: 1); return }
        if let expected { addChoices(for: expected, withDot: true, tier: 1) }
        if !scan.geometrySiblings.isEmpty {
            for name in scan.geometrySiblings {
                add(DeskCompletionTemplate(label: name, kind: .element, detail: L("A sibling in the Freeform", "同一个自由摆放里的元素"),
                                           commit: ["."]), tier: 1, nearness: 0)
            }
        }
        if expected == .bool || expected == nil || expected == .any {
            for word in ["true", "false"] {
                add(DeskCompletionTemplate(label: word, kind: .keyword, detail: L("yes or no", "是或否"), valueType: .bool),
                    tier: expected == .bool ? 1 : 4)
            }
            add(DeskCompletionTemplate(label: "not", kind: .keyword, detail: L("The opposite", "取反"), snippet: "not ",
                                       plain: "not ", valueType: .bool), tier: expected == .bool ? 2 : 7)
        }
        let inStyle = snapshot.nodeTable.innermost(at: offset).map { i in
            snapshot.nodeTable.ancestors(of: i).contains { snapshot.nodeTable.entries[$0].kind == .styleDecl }
        } ?? false
        if !inStyle {
            let declaring = declarationBeingWritten
            for own in snapshot.visibleOwnNames(at: offset) where own.kind != .element && own.name != declaring {
                var tier = 2
                if let expected, expected != .any, let type = own.type {
                    tier = DeskCompletionBuilder.fits(type, expected) || DeskSnapshot.fits(type, expected) ? 2 : 6
                }
                add(DeskCompletionTemplate(label: own.name, kind: own.kind == .loopVariable ? .loopVariable : .variable,
                                           detail: ownDetail(own), commit: ["."], valueType: own.type),
                    tier: tier, nearness: own.nearness)
            }
        }
        if context.inActions, snapshot.eventRecord(at: offset) != "Event" || enclosingEvent(at: offset) {
            add(DeskCompletionTemplate(label: "event", kind: .keyword, detail: L("What happened", "刚发生的事件"), commit: ["."]),
                tier: 4)
        }
        if let options = templates.namespaces["options"], !allOptions().isEmpty { add(options, tier: 3, nearness: 3) }
        for (name, t) in templates.namespaces where !name.contains(".") && name != "options" {
            add(t, tier: 4, nearness: 5)
        }
        for (spec, t) in templates.functions where spec.kind == .function {
            if spec.onlyInActions && !context.inActions { continue }
            if !suits(t.valueType, expected) { continue }
            add(t, tier: 5, nearness: 5)
        }
    }

    /// Whether the offset is inside an event block (for `event`).
    private func enclosingEvent(at offset: Int) -> Bool {
        let table = snapshot.nodeTable
        guard let i = table.innermost(at: offset) else { return false }
        for a in [i] + table.ancestors(of: i) where table.entries[a].kind == .modifierApp {
            let tokens = table.entries[a].positioned.childTokens
            if tokens.count >= 2, catalog.modifier(named: tokens[1].token.name)?.event != nil { return true }
        }
        return false
    }

    private mutating func addArgument() {
        guard let site = scan.callSite else { return }
        let written = Set(site.arguments.compactMap(\.label))
        let current = scan.argumentIndex < site.arguments.count ? site.arguments[scan.argumentIndex].label : nil
        var labels: [(ParamSpec, Int)] = []
        var seenLabels = Set<String>()
        let active = snapshot.activeSignature(site, argument: scan.argumentIndex)
        let ordered = [active] + site.signatures.indices.filter { $0 != active }
        for s in ordered {
            let signature = site.signatures[s]
            guard signature.since <= ceiling else { continue }
            for p in signature.params {
                guard let label = p.label, !written.contains(label) || label == current, seenLabels.insert(label).inserted else { continue }
                labels.append((p, s == active ? 0 : 1))
            }
        }
        for (p, otherSignature) in labels {
            guard let label = p.label else { continue }
            let (stop, plain) = DeskSnippet.stop(1, DeskSnippet.value(of: p, catalog: catalog))
            let t = DeskCompletionTemplate(label: label + ":", kind: .label, detail: catalog.displayName(for: p.type),
                                           documentation: p.doc, snippet: "\(label): \(stop)$0", plain: "\(label): \(plain)",
                                           words: [label], rank: p.required ? 90 : 50, valueType: nil)
            add(t, tier: p.required ? 0 : 2 + otherSignature)
        }
        guard !scan.labelsOnly, scan.allowsPositionalValue else { return }
        addValues(expected: scan.context.expectedType)
    }

    private mutating func addUnits() {
        let dimension: Dimension? = {
            guard let expected = scan.context.expectedType else { return nil }
            for t in expected.components {
                if case .number(let d) = t, d != .plain { return d }
                if t == .lengthSpec { return .length }
                if t == .fraction { return .percent }
            }
            return nil
        }()
        for (spec, t) in templates.units {
            if let dimension, spec.dimension != dimension { continue }
            add(t, tier: dimension == nil && t.rank < 70 ? 3 : 1)
        }
    }

    private mutating func addStyles() {
        let current = enclosingStyleName
        var names: [(String, Int)] = snapshot.checked.styles.keys.filter { $0 != current }.map { ($0, 0) }
        if let package = snapshot.package, !snapshot.isPackage {
            names += package.styles.keys.filter { snapshot.checked.styles[$0] == nil }.map { ($0, 1) }
        }
        for (name, near) in names {
            add(DeskCompletionTemplate(label: name, kind: .style, detail: near == 0 ? L("A style of this widget", "这个组件的样式")
                                                                                  : L("A style of the package", "包里的样式"),
                                       commit: [",", ")"]), tier: 1, nearness: near)
        }
    }

    private mutating func addElementNames(tier: Int) {
        var names = Set<String>()
        for facts in snapshot.checked.elements.values { if let name = facts.name { names.insert(name) } }
        for name in names.sorted() {
            add(DeskCompletionTemplate(label: name, kind: .element, detail: L("A named element", "有名字的元素"), commit: [",", ")"]),
                tier: tier)
        }
    }

    private mutating func addFormatOptions() {
        let valueType = scan.formatValueType
        var written = Set<String>()
        if let site = scan.callSite, site.owner == .formatOptions {
            let current = scan.argumentIndex < site.arguments.count ? site.arguments[scan.argumentIndex].label : nil
            for a in site.arguments { if let l = a.label, l != current { written.insert(l) } }
        }
        for (spec, t) in templates.formatOptions where !written.contains(spec.label) {
            guard DeskSnapshot.formatOption(spec, appliesTo: valueType) else { continue }
            add(t, tier: 1)
        }
    }

    private mutating func addImages() {
        var paths: [String] = []
        let base = (snapshot.file.path as NSString).deletingLastPathComponent
        if let model = snapshot.model {
            for file in model.files(.image) where file.isAsset {
                var path = file.path
                if !base.isEmpty {
                    guard path.hasPrefix(base + "/") else { continue }
                    path = String(path.dropFirst(base.count + 1))
                }
                paths.append(path)
            }
        } else if let resources = snapshot.resources, !prefix.isEmpty {
            paths = resources.similarPaths(to: prefix)
        }
        for path in paths.sorted() {
            add(DeskCompletionTemplate(label: path, kind: .file, detail: L("A picture in the widget's folder", "组件文件夹里的图片"),
                                       snippet: DeskSnippet.escapeLiteral(path), plain: path,
                                       words: [(path as NSString).lastPathComponent]), tier: 1)
        }
    }

    private mutating func addFonts() {
        var families: [(String, Int)] = []
        if let model = snapshot.model {
            for file in model.files(.font) where file.isAsset {
                for family in file.fontFamilies ?? [] { families.append((family, 0)) }
            }
        }
        if let fonts = snapshot.options.fonts, !prefix.isEmpty {
            for family in fonts.similarFamilies(to: prefix) { families.append((family, 1)) }
        }
        for family in ["System", "System Rounded", "System Mono", "System Serif"] { families.append((family, 2)) }
        for (family, near) in families {
            add(DeskCompletionTemplate(label: family, kind: .font,
                                       detail: near == 0 ? L("A font in the widget's folder", "组件文件夹里的字体") : L("A font of this Mac", "这台 Mac 上的字体"),
                                       snippet: DeskSnippet.escapeLiteral(family), plain: family), tier: 1, nearness: near)
        }
    }

    private mutating func addSymbols() {
        guard let symbols = snapshot.options.symbols, !prefix.isEmpty else { return }
        for name in symbols.similarSymbols(to: prefix) {
            add(DeskCompletionTemplate(label: name, kind: .symbol, detail: L("An SF Symbol", "SF 符号"),
                                       snippet: DeskSnippet.escapeLiteral(name), plain: name), tier: 1)
        }
    }

    /// Texts of the file not yet translated in the language block.
    private mutating func addTranslationKeys() {
        guard let language = scan.context.language else { return }
        let tree = snapshot.tree
        var translated = Set<String>()
        for entry in DeskTranslationKeys.entries(in: tree) where entry.language == language {
            if entry.keyRange.lowerBound > scan.utf8Range.upperBound || entry.keyRange.upperBound < scan.utf8Range.lowerBound {
                translated.insert(entry.key)
            }
        }
        var keys: [String] = []
        var seenKeys = Set<String>()
        for entry in snapshot.checked.stringTable where entry.translatable && !translated.contains(entry.key) {
            if seenKeys.insert(entry.key).inserted { keys.append(entry.key) }
        }
        let inString = isInsideString
        for (k, key) in keys.enumerated() {
            let t: DeskCompletionTemplate
            if inString {
                t = DeskCompletionTemplate(label: key, kind: .translation, detail: L("Not translated yet", "还没有翻译"),
                                           snippet: DeskSnippet.escapeLiteral(key), plain: key, rank: 100 - min(k, 99))
            } else {
                let stop = DeskSnippet.stop(1, "\"" + key + "\"")
                t = DeskCompletionTemplate(label: key, kind: .translation, detail: L("Not translated yet", "还没有翻译"),
                                           snippet: "\"\(DeskSnippet.escapeLiteral(key))\": \(stop.snippet)$0",
                                           plain: "\"\(key)\": \"\(key)\"", rank: 100 - min(k, 99))
            }
            add(t, tier: 1)
        }
    }

    /// The cursor is inside a string's quotes.
    private var isInsideString: Bool {
        guard let i = snapshot.tokenTable.lastStarting(before: scan.utf8Range.lowerBound, inclusive: true) else { return false }
        var j = i
        while j >= 0 {
            let e = snapshot.tokenTable.entries[j]
            if e.kind == .stringStart { return e.textEnd <= scan.utf8Range.lowerBound }
            if e.kind != .stringText { return false }
            j -= 1
        }
        return false
    }

    static let languageTags: [(String, String, String)] = [
        ("zh-Hans", "Chinese, Simplified", "简体中文"), ("zh-Hant", "Chinese, Traditional", "繁体中文"),
        ("ja", "Japanese", "日语"), ("ko", "Korean", "韩语"), ("de", "German", "德语"), ("fr", "French", "法语"),
        ("es", "Spanish", "西班牙语"), ("it", "Italian", "意大利语"), ("pt-BR", "Portuguese (Brazil)", "葡萄牙语（巴西）"),
        ("pt-PT", "Portuguese (Portugal)", "葡萄牙语（葡萄牙）"), ("ru", "Russian", "俄语"), ("nl", "Dutch", "荷兰语"),
        ("sv", "Swedish", "瑞典语"), ("da", "Danish", "丹麦语"), ("nb", "Norwegian", "挪威语"), ("fi", "Finnish", "芬兰语"),
        ("pl", "Polish", "波兰语"), ("tr", "Turkish", "土耳其语"), ("uk", "Ukrainian", "乌克兰语"), ("cs", "Czech", "捷克语"),
        ("hu", "Hungarian", "匈牙利语"), ("el", "Greek", "希腊语"), ("he", "Hebrew", "希伯来语"), ("ar", "Arabic", "阿拉伯语"),
        ("th", "Thai", "泰语"), ("vi", "Vietnamese", "越南语"), ("id", "Indonesian", "印尼语"), ("hi", "Hindi", "印地语"),
        ("en-GB", "English (UK)", "英语（英国）"),
    ]

    private mutating func addLanguageTags() {
        var present = Set<String>()
        for entry in DeskTranslationKeys.entries(in: snapshot.tree) { present.insert(entry.language) }
        let table = snapshot.nodeTable
        for i in table.entries.indices where table.entries[i].kind == .group {
            guard let tag = table.children(of: i).first, table.entries[tag].kind == .stringLiteral,
                  !table.entries[tag].textRange.contains(scan.utf8Range.lowerBound),
                  table.entries[tag].textRange.upperBound != scan.utf8Range.lowerBound,
                  let value = StringLiteralSyntax(unchecked: table.entries[tag].positioned).literalValue else { continue }
            present.insert(DeskLocalization.normalize(value))
        }
        let inString = isInsideString
        for (k, (tag, en, zh)) in DeskCompletionBuilder.languageTags.enumerated() where !present.contains(DeskLocalization.normalize(tag)) {
            let t: DeskCompletionTemplate
            if inString {
                t = DeskCompletionTemplate(label: tag, kind: .language, detail: L(en, zh), words: [en, zh], rank: 100 - k)
            } else {
                t = DeskCompletionTemplate(label: tag, kind: .language, detail: L(en, zh),
                                           snippet: "\"\(tag)\" {\n\t$0\n}", plain: "\"\(tag)\" {\n\t\n}", words: [en, zh], rank: 100 - k)
            }
            add(t, tier: 1)
        }
    }

    /// A value naming something that exists at the cursor, for parameters that name one: a variable or option of
    /// the right type for a binding, a style, a named element.
    func contextualValue(_ p: ParamSpec) -> String? {
        if case .binding(let inner) = p.type {
            let offset = scan.utf8Range.lowerBound
            for own in snapshot.visibleOwnNames(at: offset) where own.kind == .variable || own.kind == .saved {
                if let type = own.type, DeskCompletionBuilder.fits(type, inner) || DeskSnapshot.fits(type, inner) { return own.name }
            }
            for (name, facts) in allOptions().sorted(by: { $0.key < $1.key }) where DeskSnapshot.fits(facts.type, inner) {
                return "options." + name
            }
            return nil
        }
        if p.role == .styleRef || p.type == .styleRef {
            let current = enclosingStyleName
            if let name = snapshot.checked.styles.keys.sorted().first(where: { $0 != current }) { return name }
            if !snapshot.isPackage, let name = snapshot.package?.styles.keys.sorted().first(where: { $0 != current }) { return name }
            return nil
        }
        if p.role == .elementName {
            return snapshot.checked.elements.values.compactMap(\.name).sorted().first
        }
        if p.role == .declaresElementName {
            let taken = Set(snapshot.checked.elements.values.compactMap(\.name))
                .union(snapshot.visibleOwnNames(at: scan.utf8Range.lowerBound).map(\.name))
            return uniqueName(p.previewValue ?? "title", taken: taken)
        }
        if p.type == .any, let preview = p.previewValue, let first = preview.split(separator: ".").first,
           let ns = catalog.namespace(named: String(first)), ns.permission != nil, !declaredPermissions.contains(ns.permission!) {
            // A value to watch that needs no permission: an own value of the widget.
            return snapshot.visibleOwnNames(at: scan.utf8Range.lowerBound).first { $0.kind != .element }?.name
        }
        return nil
    }

    // MARK: Helpers

    /// Whether a value of a known type may go where `expected` is wanted: a value that can't (a list in text, a
    /// color for a font size) is not offered when both are known.
    func suits(_ type: DeskType?, _ expected: DeskType?) -> Bool {
        if scan.displaySlot, case .list? = type { return false }
        guard let type, let expected else { return true }
        switch expected {
        case .any, .typeVar, .json, .string, .binding: return !scan.displaySlot || type.components.allSatisfy { if case .list = $0 { return false } else { return true } }
        default: break
        }
        return DeskCompletionBuilder.fits(type, expected) || DeskSnapshot.fits(type, expected)
    }

    /// A style other than the one being written exists (`.style(…)` has something to name).
    var hasUsableStyle: Bool {
        let current = enclosingStyleName
        if snapshot.checked.styles.keys.contains(where: { $0 != current }) { return true }
        return !snapshot.isPackage && (snapshot.package?.styles.keys.contains { $0 != current } ?? false)
    }

    /// The file keeps Rainmeter details (`info { convertedFrom: … }`): `.rainmeter(…)` may be written.
    var isConvertedFile: Bool {
        let table = snapshot.nodeTable
        for top in table.children(of: 0) where table.entries[top].kind == .infoBlock {
            for block in table.children(of: top) where table.entries[block].kind == .block {
                for field in table.children(of: block) where table.entries[field].kind == .field {
                    if table.entries[field].positioned.firstChild(.label)?.childTokens.first?.token.name == "convertedFrom" { return true }
                }
            }
        }
        return false
    }

    /// The kind of the container around the element a modifier goes on, when the checker knows it.
    var ownerParentKind: ElementKind? {
        guard let owner = scan.modifierOwner, let facts = snapshot.checked.elements[snapshot.nodeTable.id(owner)],
              let parent = facts.parent else { return nil }
        return snapshot.checked.elements[parent]?.kind
    }

    /// The name a `variable`, `saved` or `computed` declaration around the cursor declares (not offered in its own
    /// initializer).
    var declarationBeingWritten: String? {
        let table = snapshot.nodeTable
        guard let i = table.innermost(at: scan.utf8Range.lowerBound) ?? scan.block else { return nil }
        for a in [i] + table.ancestors(of: i) where table.entries[a].kind == .declaration {
            let tokens = table.entries[a].positioned.childTokens
            return tokens.count >= 2 && !tokens[1].token.isMissing ? tokens[1].token.name : nil
        }
        // The cursor right after `=`, before anything of the initializer.
        guard let p = snapshot.tokenTable.previousPresent(endingAtOrBefore: scan.utf8Range.lowerBound) else { return nil }
        let parent = snapshot.tokenTable.entries[p].parent
        guard parent >= 0, table.entries[parent].kind == .declaration else { return nil }
        let tokens = table.entries[parent].positioned.childTokens
        return tokens.count >= 2 && !tokens[1].token.isMissing ? tokens[1].token.name : nil
    }

    /// The name of the style whose body holds the cursor.
    var enclosingStyleName: String? {
        let table = snapshot.nodeTable
        guard let i = table.innermost(at: scan.utf8Range.lowerBound) ?? scan.block else { return nil }
        for a in [i] + table.ancestors(of: i) where table.entries[a].kind == .styleDecl {
            let tokens = table.entries[a].positioned.childTokens
            return tokens.count >= 2 ? tokens[1].token.name : nil
        }
        return nil
    }

    /// The permissions `info { permissions: […] }` lists.
    var declaredPermissions: Set<String> {
        guard let list = permissionsList else { return [] }
        let table = snapshot.nodeTable
        var out = Set<String>()
        for c in table.children(of: list) where table.entries[c].kind == .implicitMemberExpr {
            if let name = table.entries[c].positioned.childTokens.dropFirst().first, !name.token.isMissing { out.insert(name.token.name) }
        }
        return out
    }

    /// The list of `info { permissions: […] }`.
    var permissionsList: Int? {
        let table = snapshot.nodeTable
        guard let block = infoBody else { return nil }
        for field in table.children(of: block) where table.entries[field].kind == .field {
            guard table.entries[field].positioned.firstChild(.label)?.childTokens.first?.token.name == "permissions" else { continue }
            return table.children(of: field).first { table.entries[$0].kind == .listLiteral }
        }
        return nil
    }

    /// The block of `info { }`.
    var infoBody: Int? {
        let table = snapshot.nodeTable
        for top in table.children(of: 0) where table.entries[top].kind == .infoBlock {
            return table.children(of: top).first { table.entries[$0].kind == .block }
        }
        return nil
    }

    /// The edits that add a permission the file does not list yet: to the list, as a field of `info`, or as a new
    /// `info` block. None in `package.desk`, for a permission already listed, or when the edit would touch the
    /// item's own range.
    func permissionEdits(_ permission: String) -> [DeskTextEditU16] {
        guard !snapshot.isPackage, !declaredPermissions.contains(permission) else { return [] }
        let table = snapshot.nodeTable
        let bytes = snapshot.index.bytes
        var edit: (Range<Int>, String)?
        if let list = permissionsList {
            let tokens = table.entries[list].positioned.childTokens
            guard let close = tokens.last, close.kind == .rBracket, !close.token.isMissing else { return [] }
            let empty = !table.children(of: list).contains { table.entries[$0].kind.isExpression }
            edit = (close.textStart..<close.textStart, empty ? ".\(permission)" : ", .\(permission)")
        } else if let block = infoBody {
            let tokens = table.entries[block].positioned.childTokens
            guard let open = tokens.first, let close = tokens.last, close.kind == .rBrace, !close.token.isMissing else { return [] }
            let fields = table.children(of: block).filter { table.entries[$0].kind.isStatement }
            let multiLine = bytes[open.textRange.upperBound..<close.textStart].contains { $0 == 0x0A || $0 == 0x0D }
            if let last = fields.last {
                let end = table.entries[last].textEnd
                if multiLine {
                    var start = table.entries[last].textStart
                    while start > 0, bytes[start - 1] != 0x0A, bytes[start - 1] != 0x0D { start -= 1 }
                    var indentEnd = start
                    while indentEnd < bytes.count, bytes[indentEnd] == 0x20 || bytes[indentEnd] == 0x09 { indentEnd += 1 }
                    let indent = String(decoding: bytes[start..<indentEnd], as: UTF8.self)
                    edit = (end..<end, "\n" + indent + "permissions: [.\(permission)]")
                } else {
                    edit = (end..<end, ", permissions: [.\(permission)]")
                }
            } else {
                edit = (open.textRange.upperBound..<close.textStart, " permissions: [.\(permission)] ")
            }
        } else {
            let start = table.children(of: 0).first { table.entries[$0].kind.isTopLevelBlock }.map { table.entries[$0].textStart } ?? 0
            edit = (start..<start, "info { permissions: [.\(permission)] }\n\n")
        }
        guard let (r, text) = edit, r.upperBound <= scan.utf8Range.lowerBound || r.lowerBound >= scan.utf8Range.upperBound else { return [] }
        return [DeskTextEditU16(range: snapshot.index.range(utf8: r), newText: text)]
    }

    /// The widget's options and the package's, the widget's first.
    private func allOptions() -> [String: OptionFacts] {
        var out = snapshot.package?.options ?? [:]
        if snapshot.isPackage { out = [:] }
        for (name, facts) in snapshot.checked.options { out[name] = facts }
        return out
    }

    private func ownDetail(_ own: DeskSnapshot.OwnName) -> L {
        let kind = DeskHoverWords.kind(own.kind)
        guard let type = own.type else { return kind }
        let words = catalog.displayName(for: type)
        return L(kind.en + " · " + words.en, kind.zh + " · " + words.zh)
    }

    /// `name`, or `name2`, `name3`… when taken.
    func uniqueName(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    /// The name an option line starts with, by its control.
    static func optionName(for control: String) -> String {
        switch control {
        case "Toggle": return "showDetails"
        case "Picker": return "choice"
        case "Slider": return "amount"
        case "Stepper": return "count"
        case "ColorPicker": return "accent"
        case "FontPicker": return "font"
        default: return control.prefix(1).lowercased() + control.dropFirst()
        }
    }

    /// `${1:x}` → `${2:x}`, `$0` kept.
    static func shiftStops(_ snippet: String, by n: Int) -> String {
        var out = ""
        var chars = Array(snippet)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(c)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$" {
                var j = i + 1
                var brace = false
                if j < chars.count, chars[j] == "{" { brace = true; j += 1 }
                var digits = ""
                while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                if let value = Int(digits), value > 0 {
                    out += brace ? "${\(value + n)" : "$\(value + n)"
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        chars.removeAll()
        return out
    }
}
