import Foundation

// Walking the catalog: every documented item, every signature, every Rainmeter mapping and every type it mentions,
// in catalog order, each with a readable place ("modifier .padding", "cpu.usage"). The language reference, search,
// hover help and the catalog's own tests are built from these; member lookup by type is what name resolution uses
// for `a.b`.

/// One documented item of the catalog.
public struct DocumentedItem: Sendable, Hashable {
    public var path: CatalogPath
    /// How pickers, menus and the reference name it ("Progress bar" / "进度条"), when it has a title.
    public var title: LocalizedText?
    public var doc: Doc

    public init(path: CatalogPath, title: LocalizedText?, doc: Doc) {
        self.path = path
        self.title = title
        self.doc = doc
    }
}

/// Something the catalog lists, with where it is: a signature, a Rainmeter mapping, a type.
public struct CatalogPlaced<Value: Sendable & Hashable>: Sendable, Hashable {
    /// A readable place: `component Grid`, `modifier .padding`, `cpu.core`, `facet padding.top`.
    public var place: String
    public var value: Value

    public init(place: String, value: Value) {
        self.place = place
        self.value = value
    }
}

extension DeskCatalog {
    /// Every documented item, in catalog order: components, modifiers, namespaces with their own value and members,
    /// global functions (and the data they read), records and their fields, members of value types, enums, named
    /// values, option controls, `info` and `package` fields, format options, permissions and features.
    public func documentedItems() -> [DocumentedItem] {
        var items: [DocumentedItem] = []
        for x in components { items.append(DocumentedItem(path: .component(x.name), title: x.title, doc: x.doc)) }
        for x in modifiers { items.append(DocumentedItem(path: .modifier(x.name), title: x.title, doc: x.doc)) }
        for ns in namespaces {
            items.append(DocumentedItem(path: .namespace(ns.name), title: ns.title, doc: ns.doc))
            if let value = ns.value {
                items.append(DocumentedItem(path: .namespace(ns.name), title: value.title, doc: value.doc))
            }
            for m in ns.members {
                items.append(DocumentedItem(path: .member(namespace: ns.name, name: m.name), title: m.title, doc: m.doc))
            }
        }
        for x in functions {
            items.append(DocumentedItem(path: .function(x.name), title: x.title, doc: x.doc))
            if let data = x.data { items.append(DocumentedItem(path: .function(x.name), title: data.title, doc: data.doc)) }
        }
        for r in records {
            items.append(DocumentedItem(path: .record(r.id), title: nil, doc: r.doc))
            for f in r.fields {
                items.append(DocumentedItem(path: .recordField(record: r.id, name: f.name), title: f.title, doc: f.doc))
            }
        }
        for t in typeMembers {
            for m in t.members {
                items.append(DocumentedItem(path: .typeMember(type: t.type, name: m.name), title: m.title, doc: m.doc))
            }
        }
        for e in enums { items.append(DocumentedItem(path: .enumeration(e.id), title: nil, doc: e.doc)) }
        for v in namedValues {
            items.append(DocumentedItem(path: .namedValue(type: v.type, name: v.name), title: v.title, doc: v.doc))
        }
        for x in controls { items.append(DocumentedItem(path: .control(x.name), title: x.title, doc: x.doc)) }
        for f in infoFields { items.append(DocumentedItem(path: .infoField(f.name), title: nil, doc: f.doc)) }
        for f in packageFields where !f.inInfo {
            items.append(DocumentedItem(path: .packageField(f.name), title: nil, doc: f.doc))
        }
        for f in formatOptions { items.append(DocumentedItem(path: .formatOption(f.label), title: nil, doc: f.doc)) }
        for p in permissions { items.append(DocumentedItem(path: .permission(p.id), title: nil, doc: p.doc)) }
        for f in features { items.append(DocumentedItem(path: .feature(f.id), title: nil, doc: f.doc)) }
        return items
    }

    /// Every signature: of components, modifiers, namespace functions and actions, global functions, members of value
    /// types and option controls.
    public func allSignatures() -> [CatalogPlaced<Signature>] {
        var list: [CatalogPlaced<Signature>] = []
        func add(_ place: String, _ signatures: [Signature]) {
            for s in signatures { list.append(CatalogPlaced(place: place, value: s)) }
        }
        for x in components { add("component \(x.name)", x.signatures) }
        for x in modifiers { add("modifier .\(x.name)", x.signatures) }
        for ns in namespaces {
            for m in ns.members { add("\(ns.name).\(m.name)", m.signatures) }
        }
        for x in functions { add("function \(x.name)", x.signatures) }
        for r in records {
            for f in r.fields { add("\(r.id).\(f.name)", f.signatures) }
        }
        for t in typeMembers {
            for m in t.members { add("\(t.type).\(m.name)", m.signatures) }
        }
        for x in controls { add("control \(x.name)", x.signatures) }
        return list
    }

    /// Every parameter of every signature, with its place (`modifier .padding horizontal:`).
    public func allParameters() -> [CatalogPlaced<ParamSpec>] {
        allSignatures().flatMap { s in
            s.value.params.map { CatalogPlaced(place: "\(s.place) \($0.label.map { "\($0):" } ?? "_ \($0.name)")", value: $0) }
        }
    }

    /// Every Rainmeter mapping: of documented items, parameters, facets and the Rainmeter details `.rainmeter(…)`
    /// may keep.
    public func allRainmeterMappings() -> [CatalogPlaced<RainmeterMapping>] {
        var list: [CatalogPlaced<RainmeterMapping>] = []
        for item in documentedItems() {
            for m in item.doc.rainmeter { list.append(CatalogPlaced(place: item.path.description, value: m)) }
        }
        for p in allParameters() {
            for m in p.value.rainmeter { list.append(CatalogPlaced(place: p.place, value: m)) }
        }
        for f in facets {
            for m in f.rainmeter { list.append(CatalogPlaced(place: "facet \(f.id)", value: m)) }
        }
        for d in compatDetails {
            list.append(CatalogPlaced(place: "detail \(d.key)", value: RainmeterMapping(d.owner, key: d.key)))
        }
        return list
    }

    /// Every type the catalog mentions (parameters, results, data, fields, facets, format options, controls, `info`
    /// fields, Rainmeter details), each once, with the first place it appears.
    public func allTypes() -> [CatalogPlaced<DeskType>] {
        var seen = Set<DeskType>()
        var list: [CatalogPlaced<DeskType>] = []
        func add(_ place: String, _ type: DeskType) {
            for t in type.components where seen.insert(t).inserted { list.append(CatalogPlaced(place: place, value: t)) }
        }
        for p in allParameters() { add(p.place, p.value.type) }
        for s in allSignatures() {
            if case .fixed(let t)? = s.value.result { add(s.place, t) }
        }
        for ns in namespaces {
            if let value = ns.value { add(ns.name, value.type) }
            for m in ns.members { add("\(ns.name).\(m.name)", m.type) }
        }
        for x in functions { if let data = x.data { add("function \(x.name)", data.type) } }
        for r in records { for f in r.fields { add("\(r.id).\(f.name)", f.type) } }
        for t in typeMembers { for m in t.members { add("\(t.type).\(m.name)", m.type) } }
        for f in facets { add("facet \(f.id)", f.valueType) }
        for f in formatOptions {
            add("format option \(f.label):", f.type)
            for t in f.appliesTo { add("format option \(f.label):", t) }
        }
        for c in controls { if case .fixed(let t) = c.valueType { add("control \(c.name)", t) } }
        for f in infoFields + packageFields { add("info \(f.name)", f.type) }
        for d in compatDetails { add("detail \(d.key)", d.type) }
        return list
    }
}

// MARK: - Members by type

extension DeskCatalog {
    /// The built-in value type whose members a value of `type` has: `"String"` (also symbol names, pictures, fonts
    /// and folders written as text), `"List"`, `"Date"`, `"Color"`, `"Json"`; nil for other types. Every value also
    /// has the members of `"Any"`.
    public static func valueTypeName(of type: DeskType) -> String? {
        switch type {
        case .string, .symbolName, .imageSource, .fontFamily, .folderPath: return "String"
        case .list: return "List"
        case .date: return "Date"
        case .color: return "Color"
        case .json: return "Json"
        case .binding(let inner): return valueTypeName(of: inner)
        default: return nil
        }
    }

    /// A member of a value of `type` (§4.2 "member access"): a record's field; a list's member, or a field of its
    /// records as a list of that field (projection); a member of text, dates, colors or web data; or a member every
    /// value has (`ifMissing`, `isMissing`). `call`: written with parentheses. On web data a member without
    /// parentheses is always a field of the JSON, so it is nil here.
    public func member(_ name: String, of type: DeskType, call: Bool) -> MemberSpec? {
        if case .record(let id) = type, let record = record(id),
           let field = record.fields.first(where: { $0.name == name && ($0.kind == .field) != call }) {
            return field
        }
        if let valueType = DeskCatalog.valueTypeName(of: type), let m = index.typeMember(valueType, name, call: call) {
            return m
        }
        if case .list(.record(let id)) = type, !call, let record = record(id),
           let field = record.fields.first(where: { $0.name == name && $0.kind == .field }) {
            var projected = field
            projected.type = .list(field.type)
            return projected
        }
        return index.typeMember("Any", name, call: call)
    }

    /// The members a value of `type` offers, for completion and did-you-mean: its record's fields, its value type's
    /// members, a list's projected fields, then the members every value has.
    public func members(of type: DeskType) -> [MemberSpec] {
        var result: [MemberSpec] = []
        if case .record(let id) = type, let record = record(id) { result += record.fields }
        if let valueType = DeskCatalog.valueTypeName(of: type) {
            result += typeMembers.first { $0.type == valueType }?.members ?? []
        }
        if case .list(.record(let id)) = type, let record = record(id) {
            let listNames = Set(result.map(\.name))
            for field in record.fields where field.kind == .field && !listNames.contains(field.name) {
                var projected = field
                projected.type = .list(field.type)
                result.append(projected)
            }
        }
        result += typeMembers.first { $0.type == "Any" }?.members ?? []
        return result
    }
}
