import Foundation

// What every name of a file is, and where each own name is declared and read: the index go-to-definition, find
// references, highlights and rename work from. Built from the checker's resolved names (`CheckedFile.symbols`) and
// the places the checker does not record as uses: the names declarations, loops, `.name(…)`, styles and options
// declare, the texts translations are keyed by, the pictures a file names, and the built-in names it writes
// (components, controls, labels, `info` fields, units). The checker's model is not extended: names are classified
// here.

/// What a name is.
public enum DeskNameKind: String, Sendable, Hashable, CaseIterable {
    // Own names (§0.2).
    case variable, saved, computed, loopVariable, element, style, option
    /// A text people read, as translations key it (§8.6).
    case translationKey
    /// A picture of the folder, named by its path.
    case asset
    // Built-in names.
    case namespace, member, function, component, control, modifier, enumCase, type, label, infoField, packageField,
         formatOption, unit, event

    /// A name the author gives: it can be renamed.
    public var isOwnName: Bool {
        switch self {
        case .variable, .saved, .computed, .loopVariable, .element, .style, .option: return true
        default: return false
        }
    }
}

/// What an occurrence does with its name.
public enum DeskOccurrenceRole: String, Sendable, Hashable {
    /// Where the name is given (`variable page`, `style card`, `.name(title)`, a translation's key).
    case declaration
    case read
    /// Assigned in an action (`page = 0`, `options.theme = .dark`).
    case write
}

/// A name at a place, as the editor shows it.
public struct DeskSymbolInfo: Sendable, Hashable {
    public var name: String
    public var kind: DeskNameKind
    public var role: DeskOccurrenceRole
    public var range: DeskRange
    /// The catalog entry of a built-in name, when known.
    public var catalogPath: CatalogPath?

    public init(name: String, kind: DeskNameKind, role: DeskOccurrenceRole, range: DeskRange, catalogPath: CatalogPath?) {
        self.name = name
        self.kind = kind
        self.role = role
        self.range = range
        self.catalogPath = catalogPath
    }
}

/// What occurrences name the same thing, across the files of a folder.
enum DeskSymbolKey: Sendable, Hashable {
    /// A declaration, loop variable or element name: its file and where its declaring name starts.
    case local(DeskFileID, Int)
    /// A style or option, by name and the file it belongs to: `package.desk` for the package's (a widget's
    /// declaration of the same name replaces it and is grouped with it, D99), else the widget.
    case style(String, DeskFileID)
    case option(String, DeskFileID)
    case translation(String)
    case asset(String)
    case builtIn(CatalogPath)
    case event
}

/// One name, text or path at a place of a file.
struct DeskOccurrence: Sendable {
    /// UTF-8, trivia excluded; for a quoted own name the text between the quotes.
    var range: Range<Int>
    var name: String
    var kind: DeskNameKind
    var role: DeskOccurrenceRole
    var key: DeskSymbolKey?
    var path: CatalogPath?
    /// Found by the service where the checker resolved nothing (a read in a style, in a `computed` cycle, an
    /// assignment outside an event): the only own name of that spelling that could be meant.
    var inferred = false
}

/// The index of one checked file.
final class DeskSymbolIndex: Sendable {
    let file: DeskFileID
    let table: DeskNodeTable
    /// Names, sorted by position; they never overlap.
    let names: [DeskOccurrence]
    /// Strings that are a translation key or a picture's path, sorted by position (a name inside an interpolation
    /// is looked up first).
    let spans: [DeskOccurrence]
    /// Occurrence indexes by key: `names` as `n`, `spans` as `-1 - s`.
    let byKey: [DeskSymbolKey: [Int]]
    /// The node that declares each local key (a declaration, `for`, element, style or option), for `Desk.apply`.
    let declaringNodes: [DeskSymbolKey: NodeID]
    /// Picker options whose choices form a local enum, and its type name (`look` → `Look`).
    let localEnums: [String: String]
    /// The type of each expression along a member chain, by node index (worked out from the catalog where nested
    /// members share the checker's key); completion reads the base of `x.`.
    let valueTypes: [Int: DeskType]
    /// The namespace each name or member chain stands for (`cpu`, `audio.microphone`, `options`), by node index.
    let namespaceOf: [Int: String]

    /// - Parameters:
    ///   - packageFile: the folder's `package.desk`.
    ///   - packageStyles, packageOptions: what `package.desk` declares; a widget's style or option of one of these
    ///     names replaces it (D99) and is keyed with it.
    init(checked: CheckedFile, table: DeskNodeTable? = nil, packageFile: DeskFileID?, packageStyles: Set<String>,
         packageOptions: Set<String>, catalog: DeskCatalog) {
        let tree = checked.tree
        let file = tree.file
        let table = table ?? DeskNodeTable(tree: tree)
        self.file = file
        self.table = table
        let isPackage = file == packageFile
        func styleKey(_ name: String, declaredIn: DeskFileID) -> DeskSymbolKey {
            if let packageFile, declaredIn == packageFile || (!isPackage && packageStyles.contains(name)) {
                return .style(name, packageFile)
            }
            return .style(name, declaredIn)
        }
        func optionKey(_ name: String, declaredIn: DeskFileID) -> DeskSymbolKey {
            if let packageFile, declaredIn == packageFile || (!isPackage && packageOptions.contains(name)) {
                return .option(name, packageFile)
            }
            return .option(name, declaredIn)
        }

        var byStart: [Int: DeskOccurrence] = [:]
        func add(_ occurrence: DeskOccurrence, replacing: Bool = true) {
            guard !occurrence.range.isEmpty || occurrence.role == .declaration else { return }
            if !replacing, byStart[occurrence.range.lowerBound] != nil { return }
            byStart[occurrence.range.lowerBound] = occurrence
        }
        var declaring: [DeskSymbolKey: NodeID] = [:]

        // 1. What declarations, loops, element names, styles and options declare, by the node that declares them.
        var declarationNames: [Int: (range: Range<Int>, name: String, kind: DeskNameKind)] = [:]   // declaration start
        var foreignNames: [Int: (range: Range<Int>, name: String)] = [:]                          // foreign node start
        var loopNames: [Int: (range: Range<Int>, name: String)] = [:]                             // `for` start
        var elementNames: [Int: (range: Range<Int>, name: String)] = [:]                          // call start
        var localEnums: [String: String] = [:]
        for (name, facts) in checked.options { if let local = facts.localEnum { localEnums[name] = local } }
        self.localEnums = localEnums

        for (i, entry) in table.entries.enumerated() {
            let node = entry.positioned
            switch entry.kind {
            case .declaration:
                let tokens = node.childTokens
                guard tokens.count >= 2, !tokens[1].token.isMissing else { continue }
                let keyword = tokens[0].token.text.lowercased()
                let kind: DeskNameKind = keyword == "saved" ? .saved : keyword == "computed" ? .computed : .variable
                declarationNames[entry.textStart] = (tokens[1].textRange, tokens[1].token.name, kind)
            case .forStmt:
                let tokens = node.childTokens
                guard tokens.count >= 2, tokens[0].kind == .forKeyword, !tokens[1].token.isMissing,
                      tokens[1].kind != .inKeyword else { continue }
                loopNames[entry.textStart] = (tokens[1].textRange, tokens[1].token.name)
            case .callStmt:
                for modifier in node.children(.modifierApp) {
                    let tokens = modifier.childTokens
                    guard tokens.count >= 2, tokens[1].token.text == "name",
                          let clause = modifier.firstChild(.argumentClause),
                          let argument = clause.firstChild(.argument), argument.firstChild(.label) == nil,
                          let value = argument.childNodes.last,
                          let (range, name) = DeskSymbolIndex.ownName(in: value) else { continue }
                    if elementNames[entry.textStart] == nil { elementNames[entry.textStart] = (range, name) }
                }
            case .styleDecl:
                let tokens = node.childTokens
                guard tokens.count >= 2, !tokens[1].token.isMissing, tokens[1].kind != .lBrace else { continue }
                let name = tokens[1].token.name
                let key = styleKey(name, declaredIn: file)
                add(DeskOccurrence(range: tokens[1].textRange, name: name, kind: .style, role: .declaration, key: key))
                if declaring[key] == nil { declaring[key] = table.id(i) }
            case .optionDecl:
                guard let target = node.firstChild(.target) else { continue }
                let token = TargetSyntax(unchecked: target).name
                guard !token.token.isMissing else { continue }
                let name = token.token.name
                let key = optionKey(name, declaredIn: file)
                add(DeskOccurrence(range: token.textRange, name: name, kind: .option, role: .declaration, key: key))
                if declaring[key] == nil { declaring[key] = table.id(i) }
            case .foreignConstruct:
                // `let x = 1`, `@State var page = 0`: the checker still declares the name (DK9104, DK9103).
                guard let kind = entry.node.foreignKind, kind == .swiftDeclaration || kind == .swiftPropertyWrapper else { continue }
                let tokens = node.tokens.filter { !$0.token.isMissing }
                guard let k = tokens.firstIndex(where: { ["let", "var", "const", "state"].contains($0.token.text) }),
                      k + 1 < tokens.count, tokens[k + 1].kind == .identifier else { continue }
                foreignNames[entry.textStart] = (tokens[k + 1].textRange, tokens[k + 1].token.name)
            default:
                break
            }
        }
        for (start, d) in declarationNames {
            let key = DeskSymbolKey.local(file, d.range.lowerBound)
            add(DeskOccurrence(range: d.range, name: d.name, kind: d.kind, role: .declaration, key: key))
            declaring[key] = NodeID(kind: .declaration, utf8Start: start, treeVersion: tree.version)
        }
        for (start, d) in loopNames {
            let key = DeskSymbolKey.local(file, d.range.lowerBound)
            add(DeskOccurrence(range: d.range, name: d.name, kind: .loopVariable, role: .declaration, key: key))
            declaring[key] = NodeID(kind: .forStmt, utf8Start: start, treeVersion: tree.version)
        }
        for (start, d) in elementNames {
            let key = DeskSymbolKey.local(file, d.range.lowerBound)
            add(DeskOccurrence(range: d.range, name: d.name, kind: .element, role: .declaration, key: key))
            declaring[key] = NodeID(kind: .callStmt, utf8Start: start, treeVersion: tree.version)
        }
        for (_, d) in foreignNames {
            add(DeskOccurrence(range: d.range, name: d.name, kind: .variable, role: .declaration,
                               key: .local(file, d.range.lowerBound)))
        }

        // 2. The uses the checker resolved.
        for (id, symbol) in checked.symbols where id.treeVersion == tree.version {
            let candidates = table.indexes(of: id)
            guard !candidates.isEmpty else { continue }   // the checker's own markers at declaring names
            var key: DeskSymbolKey?
            var kind: DeskNameKind
            var path: CatalogPath?
            var expectedName: String?
            switch symbol {
            case .declaration(let decl):
                if decl.kind == .foreignConstruct, let d = foreignNames[decl.utf8Start] {
                    key = .local(file, d.range.lowerBound)
                    kind = .variable
                } else if let d = declarationNames[decl.utf8Start] {
                    key = .local(file, d.range.lowerBound)
                    kind = d.kind
                } else { continue }
            case .loopVariable(let loop):
                guard let d = loopNames[loop.utf8Start] else { continue }
                key = .local(file, d.range.lowerBound)
                kind = .loopVariable
            case .element(let call):
                guard let d = elementNames[call.utf8Start] else { continue }
                key = .local(file, d.range.lowerBound)
                kind = .element
            case .style(_, let declaredIn):
                kind = .style
                // Keyed below, by the name written at the use.
                _ = declaredIn
            case .option:
                kind = .option
            case .builtIn(let p):
                path = p
                kind = DeskSymbolIndex.kind(of: p)
                key = .builtIn(p)
                switch p {
                case .member(_, let name), .recordField(_, let name), .typeMember(_, let name): expectedName = name
                default: break
                }
            case .enumCase(let type, let name):
                kind = .enumCase
                path = .enumCase(type: type, name: name)
                key = .builtIn(path!)
                expectedName = name
            case .event:
                kind = .event
                key = .event
            }
            if case .option = symbol { expectedName = nil }
            // Of nested nodes starting at one place, the one whose name is the resolved one (`weather.now` in
            // `weather.now.temperature`); an option is read by the innermost `options.x`.
            var chosen = candidates.last!
            if let expectedName {
                chosen = candidates.first { DeskSymbolIndex.useSite(table.entries[$0], symbol: symbol)?.name == expectedName } ?? chosen
            }
            guard let site = DeskSymbolIndex.useSite(table.entries[chosen], symbol: symbol) else { continue }
            switch symbol {
            case .style(_, let declaredIn): key = styleKey(site.name, declaredIn: declaredIn)
            case .option(_, let declaredIn): key = optionKey(site.name, declaredIn: declaredIn)
            default: break
            }
            let role: DeskOccurrenceRole = site.isTarget ? .write : .read
            add(DeskOccurrence(range: site.range, name: site.name, kind: kind, role: role, key: key, path: path),
                replacing: false)
            // The type a choice is written with (`HAlign` in `HAlign.left`, `Look` in `Look.calm`).
            if case .enumCase(let type, _) = symbol, table.entries[chosen].kind == .memberExpr,
               let base = table.children(of: chosen).first, table.entries[base].kind == .identifierExpr {
                let token = IdentifierExprSyntax(unchecked: table.entries[base].positioned).token
                if !token.token.isMissing, token.token.name == type {
                    let typePath: CatalogPath? = catalog.enumeration(type) != nil ? .enumeration(type) : nil
                    add(DeskOccurrence(range: token.textRange, name: type, kind: .type, role: .read,
                                       key: typePath.map { .builtIn($0) }, path: typePath), replacing: false)
                }
            }
        }

        // 2b. Own names the checker left unresolved because the code around them is wrong (a variable read in a
        // style, a `computed` cycle, an assignment outside an event, `.style(a | b)`): the one own name of that
        // spelling that could be meant, so navigation and renames still find them.
        var valueByName: [String: (key: DeskSymbolKey, kind: DeskNameKind)] = [:]
        for d in declarationNames.values.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            valueByName[d.name] = (.local(file, d.range.lowerBound), d.kind)
        }
        var elementByName: [String: DeskSymbolKey] = [:]
        for d in elementNames.values.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            elementByName[d.name] = .local(file, d.range.lowerBound)
        }
        var styleNames = packageStyles
        styleNames.formUnion(checked.styles.keys)
        var optionNames = packageOptions
        optionNames.formUnion(checked.options.keys)
        func inferred(_ i: Int, name: String) -> (key: DeskSymbolKey, kind: DeskNameKind)? {
            // A loop variable of an enclosing `for` whose body holds the name.
            var previous = i
            var inStyleArgument = false
            var sawModifier = false
            for a in table.ancestors(of: i) {
                let ancestor = table.entries[a]
                if ancestor.kind == .forStmt, table.entries[previous].kind == .block,
                   let loop = loopNames[ancestor.textStart], loop.name == name {
                    return (.local(file, loop.range.lowerBound), .loopVariable)
                }
                if ancestor.kind == .modifierApp, !sawModifier {
                    sawModifier = true
                    let tokens = ancestor.positioned.childTokens
                    inStyleArgument = tokens.count >= 2 && tokens[1].token.text == "style"
                        && table.entries[previous].kind == .argumentClause
                }
                previous = a
            }
            if inStyleArgument, styleNames.contains(name) { return (styleKey(name, declaredIn: file), .style) }
            if let value = valueByName[name] { return value }
            if let element = elementByName[name] { return (element, .element) }
            // `Text(weekStart)` for `options.weekStart` (DK3011).
            if optionNames.contains(name) { return (optionKey(name, declaredIn: file), .option) }
            return nil
        }
        for (i, entry) in table.entries.enumerated() {
            switch entry.kind {
            case .identifierExpr:
                let token = IdentifierExprSyntax(unchecked: entry.positioned).token
                guard !token.token.isMissing, token.kind == .identifier, byStart[token.textRange.lowerBound] == nil,
                      checked.symbols[table.id(i)] == nil else { continue }
                // Own names are never called.
                if entry.parent >= 0, table.entries[entry.parent].kind == .callExpr, table.children(of: entry.parent).first == i { continue }
                guard let found = inferred(i, name: token.token.name) else { continue }
                var occurrence = DeskOccurrence(range: token.textRange, name: token.token.name, kind: found.kind, role: .read,
                                                key: found.key)
                occurrence.inferred = true
                add(occurrence, replacing: false)
            case .implicitMemberExpr:
                // `.style(.todayCell)` for `.style(todayCell)` (DK3012).
                let tokens = entry.positioned.childTokens
                guard tokens.count >= 2, !tokens[1].token.isMissing, byStart[tokens[1].textRange.lowerBound] == nil,
                      checked.symbols[table.id(i)] == nil, let found = inferred(i, name: tokens[1].token.name),
                      found.kind == .style else { continue }
                var occurrence = DeskOccurrence(range: tokens[1].textRange, name: tokens[1].token.name, kind: .style,
                                                role: .read, key: found.key)
                occurrence.inferred = true
                add(occurrence, replacing: false)
            case .target:
                guard entry.parent >= 0, table.entries[entry.parent].kind == .assignment,
                      checked.symbols[table.id(i)] == nil else { continue }
                let target = TargetSyntax(unchecked: entry.positioned)
                guard target.members.isEmpty, !target.name.token.isMissing, target.name.kind == .identifier,
                      byStart[target.name.textRange.lowerBound] == nil,
                      let found = inferred(i, name: target.name.token.name), found.kind != .element else { continue }
                var occurrence = DeskOccurrence(range: target.name.textRange, name: target.name.token.name, kind: found.kind,
                                                role: .write, key: found.key)
                occurrence.inferred = true
                add(occurrence, replacing: false)
            default:
                break
            }
        }

        // 3a. Members of values and nested namespaces, from types worked out along each chain (the innermost first).
        // Nested members start at the same place and share the checker's key, so a key's recorded type is the
        // outermost node's; the rest come from the catalog: a namespace's members, a record's fields, a list's
        // projected fields, the members of text, lists, dates and colors.
        var valueTypes: [Int: DeskType] = [:]
        var namespaceOf: [Int: String] = [:]
        func recorded(_ i: Int) -> DeskType? {
            let id = table.id(i)
            guard table.indexes(of: id).first == i else { return nil }
            return checked.types[id]?.type
        }
        func eventRecord(_ i: Int) -> String? {
            for a in table.ancestors(of: i) where table.entries[a].kind == .modifierApp {
                let tokens = table.entries[a].positioned.childTokens
                if tokens.count >= 2, let spec = catalog.modifier(named: tokens[1].token.name), let event = spec.event {
                    return event.eventRecord ?? "Event"
                }
            }
            return "Event"
        }
        for i in table.entries.indices.reversed() {
            let entry = table.entries[i]
            switch entry.kind {
            case .identifierExpr:
                let token = IdentifierExprSyntax(unchecked: entry.positioned).token
                guard !token.token.isMissing else { continue }
                switch checked.symbols[table.id(i)] {
                case .builtIn(.namespace(let n))?:
                    namespaceOf[i] = n
                    if let ns = catalog.namespace(named: n) { valueTypes[i] = ns.value?.type ?? ns.instanceOf.map { .record($0) } }
                case .declaration(let d)?:
                    valueTypes[i] = checked.declarationTypes[d]?.type ?? recorded(i)
                case .event?:
                    valueTypes[i] = eventRecord(i).map { .record($0) }
                default:
                    valueTypes[i] = recorded(i)
                }
            case .callExpr:
                guard let callee = table.children(of: i).first else { continue }
                var result: DeskType?
                if table.entries[callee].kind == .identifierExpr {
                    let name = IdentifierExprSyntax(unchecked: table.entries[callee].positioned).token.token.name
                    if let f = catalog.function(named: name) {
                        if let data = f.data { result = data.type }
                        else if case .fixed(let t)? = f.signatures.first?.result { result = t }
                    }
                } else if let t = valueTypes[callee] {
                    result = t
                }
                valueTypes[i] = recorded(i) ?? result
            case .memberExpr:
                let tokens = entry.positioned.childTokens
                guard let token = tokens.last(where: { $0.kind != .dot }), !token.token.isMissing,
                      let base = table.children(of: i).first else { continue }
                let name = token.token.name
                let isCall = entry.parent >= 0 && table.entries[entry.parent].kind == .callExpr
                    && table.children(of: entry.parent).first == i
                var path: CatalogPath?
                var kind = DeskNameKind.member
                var type: DeskType?
                if let ns = namespaceOf[base] {
                    let nested = ns + "." + name
                    if ns == "options" {
                        type = checked.options[name]?.type ?? recorded(i)
                    } else if let inner = catalog.namespace(named: nested) {
                        namespaceOf[i] = nested
                        path = .namespace(nested)
                        kind = .namespace
                        type = inner.value?.type ?? inner.instanceOf.map { .record($0) }
                    } else if let member = catalog.index.member(ns, name) {
                        path = .member(namespace: ns, name: name)
                        type = member.type
                    }
                } else if let baseType = valueTypes[base] ?? recorded(base) {
                    switch baseType {
                    case .record(let record) where catalog.record(record)?.field(named: name) != nil:
                        path = .recordField(record: record, name: name)
                        type = catalog.record(record)?.field(named: name)?.type
                    case .list(.record(let record)) where !isCall && catalog.record(record)?.field(named: name) != nil
                                                           && catalog.index.typeMember("List", name, call: false) == nil:
                        path = .recordField(record: record, name: name)
                        type = catalog.record(record)?.field(named: name).map { .list($0.type) }
                    default:
                        if let valueType = DeskCatalog.valueTypeName(of: baseType),
                           let member = catalog.index.typeMember(valueType, name, call: isCall) {
                            path = .typeMember(type: valueType, name: name)
                            type = member.type
                            if case .list(let element) = baseType, ["first", "last", "item"].contains(name), !isCall { type = element }
                        } else if let member = catalog.index.typeMember("Any", name, call: isCall) {
                            path = .typeMember(type: "Any", name: name)
                            type = member.type
                        } else if baseType == .json {
                            type = .json
                        }
                    }
                }
                valueTypes[i] = type ?? recorded(i)
                if let path {
                    add(DeskOccurrence(range: token.textRange, name: name, kind: kind, role: .read, key: .builtIn(path), path: path),
                        replacing: false)
                }
            default:
                break
            }
        }

        // 3. Built-in names the checker does not record: components, controls, modifiers, labels, fields, units.
        for (i, entry) in table.entries.enumerated() {
            let node = entry.positioned
            switch entry.kind {
            case .callStmt:
                guard let callee = node.firstChild(.callee) else { continue }
                let target = TargetSyntax(unchecked: callee)
                guard target.members.isEmpty, !target.name.token.isMissing else { continue }
                let name = target.name.token.name
                let parentKind = entry.parent >= 0 ? table.entries[entry.parent].kind : .sourceFile
                if parentKind == .optionDecl, catalog.control(named: name) != nil {
                    add(DeskOccurrence(range: target.name.textRange, name: name, kind: .control, role: .read,
                                       key: .builtIn(.control(name)), path: .control(name)), replacing: false)
                } else if catalog.component(named: name) != nil {
                    add(DeskOccurrence(range: target.name.textRange, name: name, kind: .component, role: .read,
                                       key: .builtIn(.component(name)), path: .component(name)), replacing: false)
                } else if catalog.control(named: name) != nil {
                    add(DeskOccurrence(range: target.name.textRange, name: name, kind: .control, role: .read,
                                       key: .builtIn(.control(name)), path: .control(name)), replacing: false)
                }
            case .modifierApp:
                let tokens = node.childTokens
                guard tokens.count >= 2, !tokens[1].token.isMissing else { continue }
                let name = tokens[1].token.name
                guard catalog.modifier(named: name) != nil else { continue }
                add(DeskOccurrence(range: tokens[1].textRange, name: name, kind: .modifier, role: .read,
                                   key: .builtIn(.modifier(name)), path: .modifier(name)), replacing: false)
            case .label:
                guard let token = node.childTokens.first, !token.token.isMissing else { continue }
                let name = token.token.name
                let owner = entry.parent >= 0 ? table.entries[entry.parent] : entry
                var kind = DeskNameKind.label
                var path: CatalogPath?
                if owner.kind == .field {
                    // A field of `info { }` or `package { }` (block → top-level block).
                    let block = owner.parent >= 0 ? table.entries[owner.parent] : owner
                    let top = block.parent >= 0 ? table.entries[block.parent].kind : .sourceFile
                    if top == .infoBlock { kind = .infoField; path = .infoField(name) }
                    if top == .packageBlock { kind = .packageField; path = .packageField(name) }
                } else if owner.kind == .formatOption {
                    kind = .formatOption
                    path = .formatOption(name)
                }
                add(DeskOccurrence(range: token.textRange, name: name, kind: kind, role: .read,
                                   key: path.map { .builtIn($0) }, path: path), replacing: false)
            case .callExpr:
                // A control or component written as a value (`Choice(.mono, "One color")` in a Picker's choices).
                guard let callee = table.children(of: i).first, table.entries[callee].kind == .identifierExpr else { continue }
                let token = IdentifierExprSyntax(unchecked: table.entries[callee].positioned).token
                guard !token.token.isMissing, checked.symbols[table.id(callee)] == nil else { continue }
                let name = token.token.name
                if catalog.control(named: name) != nil {
                    add(DeskOccurrence(range: token.textRange, name: name, kind: .control, role: .read,
                                       key: .builtIn(.control(name)), path: .control(name)), replacing: false)
                } else if catalog.component(named: name) != nil {
                    add(DeskOccurrence(range: token.textRange, name: name, kind: .component, role: .read,
                                       key: .builtIn(.component(name)), path: .component(name)), replacing: false)
                }
            case .numberLiteral:
                guard let token = node.childTokens.first, let unit = token.token.unit, !unit.text.isEmpty else { continue }
                let written = token.token.text.utf8.count - token.token.numberText.utf8.count
                guard written > 0 else { continue }
                let end = token.textRange.upperBound
                add(DeskOccurrence(range: (end - written)..<end, name: unit.text, kind: .unit, role: .read, key: nil),
                    replacing: false)
            default:
                break
            }
            _ = i
        }

        // 4. Texts keyed by translations, and pictures named by their path.
        var spans: [DeskOccurrence] = []
        for entry in checked.stringTable {
            spans.append(DeskOccurrence(range: entry.range, name: entry.key, kind: .translationKey, role: .read,
                                        key: .translation(entry.key)))
        }
        for entry in DeskTranslationKeys.entries(in: tree) {
            spans.append(DeskOccurrence(range: entry.keyRange, name: entry.key, kind: .translationKey, role: .declaration,
                                        key: .translation(entry.key)))
        }
        for site in checked.assets.images where site.file == file {
            spans.append(DeskOccurrence(range: site.range, name: site.path, kind: .asset, role: .read, key: .asset(site.path)))
        }
        // A picture wins over a text at the same place.
        var spanByStart: [Int: DeskOccurrence] = [:]
        for span in spans {
            if let existing = spanByStart[span.range.lowerBound], existing.kind == .asset { continue }
            spanByStart[span.range.lowerBound] = span
        }

        let names = byStart.values.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let sortedSpans = spanByStart.values.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var byKey: [DeskSymbolKey: [Int]] = [:]
        for (i, occurrence) in names.enumerated() { if let key = occurrence.key { byKey[key, default: []].append(i) } }
        for (s, occurrence) in sortedSpans.enumerated() { if let key = occurrence.key { byKey[key, default: []].append(-1 - s) } }
        self.names = names
        self.spans = sortedSpans
        self.byKey = byKey
        self.declaringNodes = declaring
        self.valueTypes = valueTypes
        self.namespaceOf = namespaceOf
    }

    // MARK: Lookups

    /// The occurrence at a UTF-8 offset: a name whose text holds it, else one that ends at it (the cursor right
    /// after a name), else the innermost text or path.
    func occurrence(at offset: Int) -> DeskOccurrence? {
        if let i = DeskSymbolIndex.lastStarting(atOrBefore: offset, in: names) {
            let o = names[i]
            if o.range.contains(offset) { return o }
            if o.range.upperBound == offset, !o.range.isEmpty {
                // Unless the next name starts right here.
                if i + 1 < names.count, names[i + 1].range.lowerBound == offset { return names[i + 1] }
                return o
            }
        }
        var best: DeskOccurrence?
        for span in spans where span.range.lowerBound <= offset && offset <= span.range.upperBound {
            if best == nil || span.range.count < best!.range.count { best = span }
        }
        return best
    }

    /// Every occurrence of a key, in document order.
    func occurrences(of key: DeskSymbolKey) -> [DeskOccurrence] {
        (byKey[key] ?? []).map { $0 >= 0 ? names[$0] : spans[-1 - $0] }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func lastStarting(atOrBefore offset: Int, in list: [DeskOccurrence]) -> Int? {
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].range.lowerBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    // MARK: Classification

    static func kind(of path: CatalogPath) -> DeskNameKind {
        switch path {
        case .component: return .component
        case .modifier: return .modifier
        case .namespace: return .namespace
        case .member, .recordField, .typeMember: return .member
        case .record, .enumeration: return .type
        case .function: return .function
        case .control: return .control
        case .enumCase, .namedValue, .permission, .feature: return .enumCase
        case .infoField: return .infoField
        case .packageField: return .packageField
        case .formatOption: return .formatOption
        }
    }

    /// The own name an argument writes: a bare name, or a quoted one (the text between the quotes).
    static func ownName(in value: PositionedNode) -> (Range<Int>, String)? {
        switch value.kind {
        case .identifierExpr:
            let token = IdentifierExprSyntax(unchecked: value).token
            guard !token.token.isMissing else { return nil }
            return (token.textRange, token.token.name)
        case .stringLiteral:
            guard let inner = quotedContent(value), let text = StringLiteralSyntax(unchecked: value).literalValue,
                  !text.isEmpty else { return nil }
            return (inner, text)
        default:
            return nil
        }
    }

    /// The text between the quotes of a one-line string that is only text.
    static func quotedContent(_ value: PositionedNode) -> Range<Int>? { RenamePlan.quotedName(value) }

    struct UseSite {
        var range: Range<Int>
        var name: String
        var isTarget: Bool
    }

    /// Where the name of a resolved node is written.
    static func useSite(_ entry: DeskNodeTable.Entry, symbol: Symbol) -> UseSite? {
        let node = entry.positioned
        switch entry.kind {
        case .identifierExpr:
            let token = IdentifierExprSyntax(unchecked: node).token
            guard !token.token.isMissing else { return nil }
            return UseSite(range: token.textRange, name: token.token.name, isTarget: false)
        case .memberExpr, .implicitMemberExpr:
            let tokens = node.childTokens
            guard let token = tokens.last(where: { $0.kind != .dot }), !token.token.isMissing else { return nil }
            return UseSite(range: token.textRange, name: token.token.name, isTarget: false)
        case .target, .callee:
            let target = TargetSyntax(unchecked: node)
            let token: PositionedToken
            switch symbol {
            case .declaration, .loopVariable, .element, .event: token = target.name
            default: token = target.members.last ?? target.name
            }
            guard !token.token.isMissing else { return nil }
            return UseSite(range: token.textRange, name: token.token.name, isTarget: entry.kind == .target)
        case .modifierApp:
            let tokens = node.childTokens
            guard tokens.count >= 2, !tokens[1].token.isMissing else { return nil }
            return UseSite(range: tokens[1].textRange, name: tokens[1].token.name, isTarget: false)
        case .stringLiteral:
            guard let (range, name) = ownName(in: node) else { return nil }
            return UseSite(range: range, name: name, isTarget: false)
        case .label:
            guard let token = node.childTokens.first, !token.token.isMissing else { return nil }
            return UseSite(range: token.textRange, name: token.token.name, isTarget: false)
        default:
            return nil
        }
    }
}
