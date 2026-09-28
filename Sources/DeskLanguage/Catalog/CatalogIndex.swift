import Foundation

/// Lookups over one catalog, built once: by name, by path, by keyword. Everything the checker asks per name is a
/// dictionary lookup.
public final class CatalogIndex: Sendable {
    public let components: [String: ComponentSpec]
    public let modifiers: [String: ModifierSpec]
    public let facets: [FacetID: FacetSpec]
    /// By full name, nested ones with a dot (`"audio.microphone"`).
    public let namespaces: [String: NamespaceSpec]
    /// By path: `"cpu.usage"`, `"audio.microphone.level"`, `"weather.at"`.
    public let members: [String: MemberSpec]
    public let functions: [String: FunctionSpec]
    public let records: [String: RecordSpec]
    /// Fields by `"String.length"`, calls by `"List.first()"`: a list's `.first` is its first item and `.first(5)`
    /// its first five.
    public let typeMembers: [String: MemberSpec]
    public let enums: [String: EnumSpec]
    /// `"Color.red"`, `"Paint.glass"`.
    public let namedValues: [String: NamedValueSpec]
    public let controls: [String: ControlSpec]
    public let infoFields: [String: FieldSpec]
    public let packageFields: [String: FieldSpec]
    public let units: [String: UnitSpec]
    public let unitMisspellings: [String: UnitMisspellingSpec]
    /// A label may have several rows (`unit:` applies to bytes, temperatures and frequencies).
    public let formatOptions: [String: [FormatOptionSpec]]
    public let permissions: [String: PermissionSpec]
    public let features: [String: FeatureSpec]
    /// By `ForeignPattern.key`.
    public let foreign: [String: [ForeignSpec]]
    public let displayNames: [String: DisplayNameSpec]
    public let diagnostics: [DiagnosticID: DiagnosticSpec]
    public let fixItTitles: [String: FixItTitleSpec]
    public let notes: [String: NoteSpec]
    public let compatDetails: [String: [CompatDetailSpec]]
    public let rereadingCommands: [String: RereadSpec]
    /// Implicit member name → the types that have a case or named value of that name, with its `since`.
    public let implicitMembers: [String: [(type: String, since: AppVersion)]]
    /// Normalized keyword (lowercased, without `-`, `_` and spaces) → the items that list it.
    public let keywords: [String: [CatalogPath]]
    /// `DeskCatalog.newestSince`, worked out once: every check context without an App version asks for it.
    public let newestSince: AppVersion

    init(_ c: DeskCatalog) {
        newestSince = c.computeNewestSince()
        func unique<T>(_ items: [T], _ key: (T) -> String) -> [String: T] {
            var d: [String: T] = [:]
            for item in items where d[key(item)] == nil { d[key(item)] = item }
            return d
        }
        components = unique(c.components, \.name)
        modifiers = unique(c.modifiers, \.name)
        var facetTable: [FacetID: FacetSpec] = [:]
        for f in c.facets where facetTable[f.id] == nil { facetTable[f.id] = f }
        facets = facetTable
        namespaces = unique(c.namespaces, \.name)
        var memberTable: [String: MemberSpec] = [:]
        for ns in c.namespaces {
            for m in ns.members where memberTable["\(ns.name).\(m.name)"] == nil { memberTable["\(ns.name).\(m.name)"] = m }
        }
        members = memberTable
        functions = unique(c.functions, \.name)
        records = unique(c.records, \.id)
        var typeMemberTable: [String: MemberSpec] = [:]
        for t in c.typeMembers {
            for m in t.members {
                let key = CatalogIndex.typeMemberKey(t.type, m.name, call: m.kind != .field)
                if typeMemberTable[key] == nil { typeMemberTable[key] = m }
            }
        }
        typeMembers = typeMemberTable
        enums = unique(c.enums, \.id)
        namedValues = unique(c.namedValues) { "\($0.type).\($0.name)" }
        controls = unique(c.controls, \.name)
        infoFields = unique(c.infoFields, \.name)
        packageFields = unique(c.packageFields, \.name)
        units = unique(c.units, \.spelling)
        unitMisspellings = unique(c.unitMisspellings, \.spelling)
        formatOptions = Dictionary(grouping: c.formatOptions, by: \.label)
        permissions = unique(c.permissions, \.id)
        features = unique(c.features, \.id)
        foreign = Dictionary(grouping: c.foreign, by: \.pattern.key)
        displayNames = unique(c.displayNames, \.id)
        var diagnosticTable: [DiagnosticID: DiagnosticSpec] = [:]
        for d in c.diagnostics where diagnosticTable[d.id] == nil { diagnosticTable[d.id] = d }
        diagnostics = diagnosticTable
        fixItTitles = unique(c.fixItTitles, \.key)
        notes = unique(c.notes, \.key)
        compatDetails = Dictionary(grouping: c.compatDetails) { $0.key.lowercased() }
        rereadingCommands = unique(c.rereadingCommands, \.command)

        var implicit: [String: [(type: String, since: AppVersion)]] = [:]
        for e in c.enums {
            for k in e.cases { implicit[k.name, default: []].append((e.id, k.since)) }
        }
        for v in c.namedValues { implicit[v.name, default: []].append((v.type, v.doc.since)) }
        implicitMembers = implicit

        var words: [String: [CatalogPath]] = [:]
        func add(_ list: [String], _ path: CatalogPath) {
            for w in list {
                let key = DeskCatalog.normalizedKeyword(w)
                guard !key.isEmpty else { continue }
                if !(words[key]?.contains(path) ?? false) { words[key, default: []].append(path) }
            }
        }
        for x in c.components { add(x.doc.keywords, .component(x.name)) }
        for x in c.modifiers { add(x.doc.keywords, .modifier(x.name)) }
        for ns in c.namespaces {
            add(ns.doc.keywords, .namespace(ns.name))
            for m in ns.members { add(m.doc.keywords, .member(namespace: ns.name, name: m.name)) }
        }
        for r in c.records {
            for f in r.fields { add(f.doc.keywords, .recordField(record: r.id, name: f.name)) }
        }
        for x in c.functions { add(x.doc.keywords, .function(x.name)) }
        for t in c.typeMembers {
            for m in t.members { add(m.doc.keywords, .typeMember(type: t.type, name: m.name)) }
        }
        for x in c.controls { add(x.doc.keywords, .control(x.name)) }
        for e in c.enums {
            for k in e.cases { add(k.keywords, .enumCase(type: e.id, name: k.name)) }
        }
        for v in c.namedValues { add(v.keywords, .namedValue(type: v.type, name: v.name)) }
        for f in c.infoFields { add(f.doc.keywords, .infoField(f.name)) }
        keywords = words
    }

    static func typeMemberKey(_ type: String, _ name: String, call: Bool) -> String {
        call ? "\(type).\(name)()" : "\(type).\(name)"
    }

    /// A member of a built-in value type: a field (`call` false) or a call.
    public func typeMember(_ type: String, _ name: String, call: Bool) -> MemberSpec? {
        typeMembers[CatalogIndex.typeMemberKey(type, name, call: call)]
    }

    /// A member by its namespace and name; nested namespaces are found by their dotted name.
    public func member(_ namespace: String, _ name: String) -> MemberSpec? { members["\(namespace).\(name)"] }

    /// The items whose keywords include `word`, compared ignoring case, `-`, `_` and spaces.
    public func keywordMatches(_ word: String) -> [CatalogPath] { keywords[DeskCatalog.normalizedKeyword(word)] ?? [] }

    /// The foreign rows for a name, modifier (`".foregroundColor"`), token or key.
    public func foreignRows(_ key: String) -> [ForeignSpec] { foreign[key] ?? [] }
}

extension DeskCatalog {
    /// Lowercased, without `-`, `_` and spaces: how keywords are compared.
    public static func normalizedKeyword(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { $0 != "-" && $0 != "_" && $0 != " " })
    }

    public func component(named name: String) -> ComponentSpec? { index.components[name] }
    public func modifier(named name: String) -> ModifierSpec? { index.modifiers[name] }
    public func facet(_ id: FacetID) -> FacetSpec? { index.facets[id] }
    public func namespace(named name: String) -> NamespaceSpec? { index.namespaces[name] }
    /// `"cpu.usage"`, `"audio.microphone.level"`.
    public func member(path: String) -> MemberSpec? { index.members[path] }
    public func function(named name: String) -> FunctionSpec? { index.functions[name] }
    public func record(_ id: String) -> RecordSpec? { index.records[id] }
    public func enumeration(_ id: String) -> EnumSpec? { index.enums[id] }
    public func control(named name: String) -> ControlSpec? { index.controls[name] }
    public func unit(spelling: String) -> UnitSpec? { index.units[spelling] }
    public func diagnostic(_ id: DiagnosticID) -> DiagnosticSpec? { index.diagnostics[id] }
    public func displayName(_ id: String) -> DisplayNameSpec? { index.displayNames[id] }

    /// The display name of a type as messages show it: "a number", "a list of days of a month", "a text size, a
    /// text style or a font name". Types without a row read "a value".
    public func displayName(for type: DeskType, plural: Bool = false) -> LocalizedText {
        func row(_ id: String) -> LocalizedText? {
            guard let spec = index.displayNames[id] else { return nil }
            return plural ? (spec.plural ?? spec.name) : spec.name
        }
        switch type {
        case .list(let element):
            let inner = displayName(for: element, plural: true)
            let template = index.displayNames["type:list"]?.name ?? LocalizedText("a list of {element}", "一组{element}")
            return LocalizedText(template.en.replacingOccurrences(of: "{element}", with: inner.en),
                                 template.zh.replacingOccurrences(of: "{element}", with: inner.zh))
        case .binding(let inner):
            return displayName(for: inner, plural: plural)
        case .oneOf(let members):
            let names = members.map { displayName(for: $0, plural: plural) }
            return LocalizedText(Self.joined(names.map(\.en), last: " or "), Self.joined(names.map(\.zh), separator: "、", last: "或"))
        default:
            return row(type.displayNameID) ?? row("type:any") ?? LocalizedText("a value", "一个值")
        }
    }

    /// "a, b or c".
    static func joined(_ items: [String], separator: String = ", ", last: String) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: separator) + last + items[items.count - 1]
    }

    /// The types that have a case or named value `name`, keeping only those with the earliest `since` (so a type
    /// added later never changes what existing code means). Colors are also paints; only the narrower type counts.
    public func implicitMemberTypes(_ name: String) -> [String] {
        guard let all = index.implicitMembers[name], let earliest = all.map(\.since).min() else { return [] }
        return all.filter { $0.since == earliest }.map(\.type)
    }
}
