import Foundation

// Phase C1 (§4.2): own names and where they are declared, the checks every own name gets (reserved words, a capital
// first letter, clashes, hiding a built-in value), and the resolution of a bare name used as a value, with the
// diagnostics of the "finds nothing" table in its order.

extension Checker {
    // MARK: - Own names

    /// Built-in values an own name can hide (DK3029): data namespaces, `options`, `widget`, `math`.
    func builtInValue(named name: String) -> NamespaceSpec? {
        catalog.namespace(named: name)
    }

    /// Checks an own name where it is declared. Returns false when the name cannot be used at all.
    @discardableResult
    func checkOwnName(_ token: PositionedToken, kind: String, allowBlockWords: Bool = false, renameEverywhere: [Range<Int>] = []) -> Bool {
        let name = token.token.name
        let r = range(token)
        lastRefusedAsReserved = false
        if token.token.isMissing { return false }
        if token.kind == .invalidIdentifier { return false }
        if token.kind.isKeyword || (!allowBlockWords && Chars.blockWords.contains(name)) {
            let newName = token.kind == .eventKeyword ? "item" : name + "Value"
            let fixIts = [fix(token.kind == .eventKeyword ? "renameTo" : "rename", [edit(r, newName)], ["text": .code(newName)])]
            if report(.reservedName, r, ["name": .code(name)], fixIts: fixIts) {
                // The fix-it is completed with every use once they are known (`completeReservedRenames`).
                lastRefusedAsReserved = true
                pendingReservedName = (diagnostics.count - 1, r, newName)
            }
            return false
        }
        if token.token.isUpperName {
            reportUppercaseName(token, declared: true)
        }
        return true
    }

    /// DK3016: an own name with a capital first letter, renamed everywhere by the fix-it.
    func reportUppercaseName(_ token: PositionedToken, declared: Bool) {
        let name = token.token.name
        let lower = name.prefix(1).lowercased() + name.dropFirst()
        var edits = [edit(range(token), lower)]
        for other in usesOfName(name) where other != range(token) { edits.append(edit(other, lower)) }
        report(.nameStartsUppercase, range(token), ["suggestion": .code(lower)],
               fixIts: [fix("renameEverywhere", edits)])
    }

    /// Every identifier token spelled `name` in the widget (for rename fix-its).
    func usesOfName(_ name: String) -> [Range<Int>] {
        var result: [Range<Int>] = []
        tree.root.walkTokens { token, at in
            if token.kind == .identifier, token.text == name {
                let start = at + token.leadingTrivia.utf8Length
                result.append(start..<(start + token.text.utf8.count))
            }
            return true
        }
        return result
    }

    /// DK3014: `name` is already used by another own name that can be read in the same place.
    func reportNameClash(_ token: PositionedToken, other: LocalizedText, otherRange: Range<Int>?) {
        let name = token.token.name
        var edits = [edit(range(token), name + "2")]
        _ = edits
        edits = [edit(range(token), name + "2")]
        var notes: [Note] = []
        if let otherRange { notes.append(note("declaredHere", otherRange)) }
        report(.nameAlreadyUsed, range(token), ["name": .code(name), "other": .text(other)], notes: notes,
               fixIts: [fix("renameThisOneEverywhere", edits)])
    }

    /// DK3029 (info): an own name that hides a built-in value, with a clearer name.
    func reportHidesBuiltIn(_ token: PositionedToken) {
        let name = token.token.name
        guard let ns = builtInValue(named: name) else { return }
        if let requires = tree.header.requires, ns.doc.since > requires { return }
        let suggestion = Checker.clearerName(for: name)
        var edits: [TextEdit] = []
        for r in usesOfName(name) { edits.append(edit(r, suggestion)) }
        report(.hidesBuiltIn, range(token), ["name": .code(name), "suggestion": .code(suggestion)],
               fixIts: [fix("renameEverywhereTo", edits, ["text": .code(suggestion)])])
    }

    static func clearerName(for name: String) -> String {
        switch name {
        case "time": return "clockTime"
        case "disk": return "myDisk"
        case "music": return "song"
        case "widget": return "widgetValue"
        case "options": return "choices"
        case "system": return "mac"
        default: return "my" + name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    // MARK: - Declarations

    func collectDeclarations(_ block: PositionedNode?, strays: [PositionedNode]) {
        var statements: [PositionedNode] = []
        if let block {
            for statement in BlockSyntax(unchecked: block).statements where statement.kind == .declaration {
                statements.append(statement)
            }
        }
        statements = strays + statements
        // `let x = 1`, `@State var page = 0` (DK9104, DK9103): the name is still declared, silently, so its reads
        // are not also "there's no `x`".
        if let block {
            for node in block.childNodes where node.kind == .foreignConstruct {
                guard let kind = node.node.foreignKind, kind == .swiftDeclaration || kind == .swiftPropertyWrapper else { continue }
                let tokens = node.tokens.filter { !$0.token.isMissing }
                guard let keywordIndex = tokens.firstIndex(where: { ["let", "var", "const", "state"].contains($0.token.text) }),
                      keywordIndex + 1 < tokens.count, tokens[keywordIndex + 1].kind == .identifier else { continue }
                let token = tokens[keywordIndex + 1]
                let name = token.token.name
                guard decls[name] == nil else { continue }
                let d = Decl(name: name, keyword: "variable", node: node, nameRange: range(token), id: id(node), index: -1)
                d.val = .error
                d.poisoned = true
                d.used = true
                decls[name] = d
            }
        }
        for statement in statements {
            let decl = DeclarationSyntax(unchecked: statement)
            let token = decl.name
            guard !token.token.isMissing else { continue }
            let name = token.token.name
            if !checkOwnName(token, kind: "declaration") {
                // A reserved or block word is still declared, so its uses resolve to it and not to a built-in
                // (no cascade), and its rename fix-it renames them too.
                guard lastRefusedAsReserved, decls[name] == nil, let pending = pendingReservedName else { continue }
                let d = Decl(name: name, keyword: decl.keyword.token.text.lowercased(), node: statement, nameRange: range(token),
                             id: id(statement), index: declOrder.count)
                d.used = true   // one diagnostic for the name: no DK3020 besides DK3015
                decls[name] = d
                declOrder.append(d)
                symbols[NodeID(kind: .declaration, utf8Start: range(token).lowerBound, treeVersion: tree.version)] = .declaration(d.id)
                reservedRenames.append((pending.index, pending.declaration, pending.newName, .declaration(d.id)))
                continue
            }
            if let other = decls[name] {
                reportNameClash(token, other: LocalizedText("another declaration", "另一个声明"), otherRange: other.nameRange)
                continue
            }
            if let element = preName(named: name) {
                reportNameClash(token, other: LocalizedText("an element's name", "一个元素的名字"), otherRange: element.range)
            }
            let d = Decl(name: name, keyword: decl.keyword.token.text.lowercased(), node: statement, nameRange: range(token),
                         id: id(statement), index: declOrder.count)
            decls[name] = d
            declOrder.append(d)
            symbols[NodeID(kind: .declaration, utf8Start: range(token).lowerBound, treeVersion: tree.version)] = .declaration(d.id)
            reportHidesBuiltIn(token)
        }
    }

    /// Types every declaration's initializer in declaration order (§4.14), then finds cycles (DK4040).
    func checkDeclarations() {
        // Initializers are typed dependencies first, found without recursion, so a long chain of computed values
        // that read later ones (`computed c0 = c1 + 1`, `computed c1 = c2 + 1`, …) never nests one typing inside
        // the next (§2.11 rule 7). A cycle is left to `declarationValue`'s guard and DK4040.
        let graph = declarationGraph()
        // Values in a cycle through a computed value (DK4040) are not typed at all: typing one would type the whole
        // cycle inside it.
        for component in Checker.cyclicComponents(in: graph, order: declOrder.map(\.name))
        where component.contains(where: { decls[$0]?.keyword == "computed" }) {
            for name in component {
                decls[name]?.poisoned = true
                decls[name]?.val = .error
            }
        }
        var done = Set<String>()
        var onPath = Set<String>()
        for start in declOrder where !done.contains(start.name) {
            var work: [(name: String, next: Int)] = [(start.name, 0)]
            onPath.insert(start.name)
            while let (name, i) = work.last {
                let deps = graph[name] ?? []
                if i < deps.count {
                    work[work.count - 1].next += 1
                    let dep = deps[i]
                    if !done.contains(dep), !onPath.contains(dep), decls[dep] != nil {
                        onPath.insert(dep)
                        work.append((dep, 0))
                    }
                } else {
                    work.removeLast()
                    onPath.remove(name)
                    done.insert(name)
                    if let decl = decls[name], decl.index >= 0 { _ = declarationValue(decl) }
                }
            }
        }
        for decl in declOrder { _ = declarationValue(decl) }
        reportComputedCycles(graph)
    }

    /// The own names each declaration's initializer reads.
    func declarationGraph() -> [String: [String]] {
        var graph: [String: [String]] = [:]
        for decl in declOrder {
            var targets = Set<String>()
            let initializer = DeclarationSyntax(unchecked: decl.node).initializer.node
            var previous: TokenKind?
            initializer.node.walkTokens { token, _ in
                if token.kind == .identifier, previous != .dot, decls[token.text] != nil { targets.insert(token.text) }
                previous = token.kind
                return true
            }
            graph[decl.name] = targets.sorted()
        }
        return graph
    }

    /// The value of a declaration, typing its initializer on first use.
    func declarationValue(_ decl: Decl) -> Val {
        if let val = decl.val { return val }
        if decl.checking { return .error }
        decl.checking = true
        defer { decl.checking = false }
        let declaration = DeclarationSyntax(unchecked: decl.node)
        let initializer = declaration.initializer.node
        var context = ExprContext()
        context.place = .widget
        context.declaration = decl
        context.usage = decl.keyword == "computed" ? .logic : .onDemand
        if decl.keyword == "saved" { context.constantOnly = true }
        let before = diagnostics.filter { $0.severity == .error }.count
        var val = savedMute { inferValue(initializer, context, expected: nil) }
        let after = diagnostics.filter { $0.severity == .error }.count
        if after > before && mute == 0 { decl.poisoned = true }
        decl.initializerDeps = val.deps
        // Settling by use: a plain literal, byte literals, or an implicit member of several types leave it open.
        if val.error { decl.poisoned = true }
        if !val.error {
            if let slot = openSlot(for: initializer, val: val, owner: .declaration(decl)) {
                decl.open = slot
                val.open = slot
            }
        }
        if decl.keyword == "saved" && !val.error {
            checkSavable(decl, val, at: range(initializer))
            if !decl.poisoned && !val.isConstant {
                report(.savedNotConstant, range(initializer), ["text": .code(text(initializer))])
                decl.poisoned = true
            }
        }
        if decl.keyword == "variable" && !val.error {
            let readsData = val.deps.contains { if case .data = $0 { return true }; if case .option = $0 { return true }; return false }
            if readsData { pendingVariableFromData.append(decl) }
        }
        var stored = val
        stored.plainLiteral = nil
        stored.literalValue = nil
        stored.stringLiteral = nil
        stored.boolLiteral = nil
        stored.isTemplate = false
        stored.implicitName = nil
        stored.dataPath = nil
        stored.optionName = nil
        stored.bind = nil
        stored.namespace = nil
        stored.open = val.open
        if decl.poisoned { stored.error = true }
        decl.val = stored
        return stored
    }

    /// Runs body without changing the current mute (initializers may be typed on demand while speculating).
    func savedMute<T>(_ body: () -> T) -> T {
        let saved = mute
        mute = 0
        defer { mute = saved }
        return body()
    }

    /// DK4036: a `saved` value must be a number, text, yes/no, color, date, choice or a list of those.
    func checkSavable(_ decl: Decl, _ val: Val, at r: Range<Int>) {
        func savable(_ t: DeskType) -> Bool {
            switch t {
            case .number, .anyNumber, .fraction, .string, .bool, .color, .date, .enumeration: return true
            case .list(let e): return savable(e)
            case .any: return true
            default: return false
            }
        }
        if !savable(val.type) {
            report(.notSavable, r, ["name": .code(decl.name), "type": .type(val.type)])
            decl.poisoned = true
        }
    }

    /// DK4040: computed values (and variables' initializers) that depend on each other.
    func reportComputedCycles(_ graph: [String: [String]]) {
        let computedNames = Set(declOrder.filter { $0.keyword == "computed" }.map(\.name))
        for cycle in Checker.cycles(in: graph, order: declOrder.map(\.name), startingAt: { computedNames.contains($0) }) {
            let list = (cycle + [cycle[0]]).map { DiagnosticArgument.code($0) }
            report(.computedCycle, decls[cycle[0]]!.nameRange, ["cycle": .list(list, joiner: .arrow)])
            for n in cycle { decls[n]?.poisoned = true; decls[n]?.val?.error = true }
        }
    }

    /// The cycles of a graph, one per strongly connected component that holds one, found in a single iterative
    /// pass (Tarjan's algorithm: linear, and no recursion however long a chain of names is). Each cycle starts at
    /// the component's first node in `order` that `startingAt` accepts (components with none are left out) and is
    /// the shortest way back to it; the cycles come in the order of their starts.
    static func cycles(in graph: [String: [String]], order: [String], startingAt accepts: (String) -> Bool = { _ in true }) -> [[String]] {
        cycleSearch(graph, order: order, accepts: accepts).cycles
    }

    /// The members of every strongly connected component that holds a cycle, each in `order`.
    static func cyclicComponents(in graph: [String: [String]], order: [String]) -> [[String]] {
        cycleSearch(graph, order: order, accepts: { _ in true }).components
    }

    private static func cycleSearch(_ graph: [String: [String]], order: [String], accepts: (String) -> Bool)
        -> (cycles: [[String]], components: [[String]]) {
        var names = order
        var position: [String: Int] = [:]
        for (i, name) in names.enumerated() where position[name] == nil { position[name] = i }
        for name in graph.keys.sorted() where position[name] == nil {
            position[name] = names.count
            names.append(name)
        }
        let n = names.count
        let successors: [[Int]] = names.map { (graph[$0] ?? []).compactMap { position[$0] } }
        var index = [Int](repeating: -1, count: n), low = [Int](repeating: 0, count: n)
        var onStack = [Bool](repeating: false, count: n)
        var stack: [Int] = []
        var counter = 0
        var components: [[Int]] = []
        for root in 0..<n where index[root] == -1 {
            var work: [(node: Int, next: Int)] = [(root, 0)]
            index[root] = counter; low[root] = counter; counter += 1
            stack.append(root); onStack[root] = true
            while let (v, i) = work.last {
                if i < successors[v].count {
                    work[work.count - 1].next += 1
                    let w = successors[v][i]
                    if index[w] == -1 {
                        index[w] = counter; low[w] = counter; counter += 1
                        stack.append(w); onStack[w] = true
                        work.append((w, 0))
                    } else if onStack[w] {
                        low[v] = min(low[v], index[w])
                    }
                } else {
                    work.removeLast()
                    if let parent = work.last?.node { low[parent] = min(low[parent], low[v]) }
                    if low[v] == index[v] {
                        var component: [Int] = []
                        while let w = stack.popLast() {
                            onStack[w] = false
                            component.append(w)
                            if w == v { break }
                        }
                        components.append(component)
                    }
                }
            }
        }
        var result: [(start: Int, cycle: [String])] = []
        var cyclic: [[String]] = []
        for component in components {
            let members = Set(component)
            guard component.count > 1 || successors[component[0]].contains(component[0]) else { continue }
            cyclic.append(component.sorted().map { names[$0] })
            guard let start = component.sorted().first(where: { accepts(names[$0]) }) else { continue }
            // The shortest way from `start` back to itself inside the component (breadth first).
            var parent: [Int: Int] = [:]
            var queue = [start]
            var head = 0
            var last: Int?
            search: while head < queue.count {
                let v = queue[head]; head += 1
                for w in successors[v] where members.contains(w) {
                    if w == start { last = v; break search }
                    if parent[w] == nil { parent[w] = v; queue.append(w) }
                }
            }
            guard var node = last else { continue }
            var path: [Int] = []
            while node != start { path.append(node); node = parent[node]! }
            path.append(start)
            result.append((start, path.reversed().map { names[$0] }))
        }
        return (result.sorted { $0.start < $1.start }.map(\.cycle), cyclic)
    }

    // MARK: - Loop variables

    func pushLoop(_ variable: LoopVariable?, _ element: Val) {
        if let variable { loopStack.append(variable) }
    }

    func popLoop(_ variable: LoopVariable?) {
        if variable != nil { loopStack.removeLast() }
    }

    // MARK: - Resolving a bare name

    /// A bare name used as a value (§4.2): loop variables, declarations, element names (in geometry), built-in
    /// values; then the "finds nothing" table.
    func resolveIdentifier(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let identifier = IdentifierExprSyntax(unchecked: node)
        let token = identifier.token
        let name = token.token.name
        let r = range(token)
        let nodeID = id(node)
        if token.token.isMissing { return .error }
        if token.kind == .invalidIdentifier { return .error }
        // `event` is the pointer event's value, unless a loop variable or declaration took the word (DK3015).
        if token.kind == .eventKeyword, !loopStack.contains(where: { $0.name == "event" }), decls["event"] == nil {
            return resolveEvent(node, context)
        }
        if token.token.flags.contains(.keywordCaseVariant) {
            // `If`, `Event`, `True` used as a value (§1.5). The parser reports the spellings it reads as keywords;
            // the rest are reported here: DK3013 when the keyword is itself a value (`event`, `true`, `false`),
            // otherwise the ordinary "finds nothing" rules (`Text(Else)` → put the word in quotes).
            if tree.diagnostics.contains(where: { $0.id == .wrongCase && $0.range == r }) { return .error }
            let lower = name.lowercased()
            if ["true", "false"].contains(lower) || (lower == "event" && context.action?.eventAvailable == true) {
                report(.wrongCase, r, ["suggestion": .code(lower), "name": .code(name)],
                       fixIts: [fix("replaceWith", [edit(r, lower)], ["text": .code(lower)])])
                return .error
            }
        }

        // Loop variables, innermost first.
        if let loop = loopStack.last(where: { $0.name == name }) {
            if let style = context.styleName {
                reportStyleUsesVariable(name, at: r, style: style)
                return .error
            }
            symbols[nodeID] = .loopVariable(loop.id)
            var v = loop.val
            v.deps.insert(.loopVariable(name))
            v.bind = .loopVariable(name)
            return v
        }
        // Declarations.
        if let decl = decls[name] {
            if let style = context.styleName {
                reportStyleUsesVariable(name, at: r, style: style)
                return .error
            }
            symbols[nodeID] = .declaration(decl.id)
            decl.used = true   // also while muted: the name is read in the source (no DK3020 cascade)
            if let reader = context.declaration, reader.keyword != "computed", decl.keyword != "computed",
               decl.index > reader.index {
                let target = decl.node
                let targetRange = range(target)
                let readerRange = range(reader.node)
                report(.declaredLater, r, ["name": .code(name)],
                       fixIts: [fix("moveBelow", [edit(reader.node.range.lowerBound..<readerRange.upperBound, ""),
                                                  edit(targetRange.upperBound..<targetRange.upperBound,
                                                       lineBreak + indentation(at: targetRange.lowerBound) + text(readerRange))],
                                    ["text": .code(name)])])
                return .error
            }
            if let reader = context.declaration, reader.keyword == "saved" {
                report(.savedNotConstant, r, ["text": .code(name)])
                return .error
            }
            var v = declarationValue(decl)
            if decl.poisoned { return .error }
            switch decl.keyword {
            case "computed":
                v.deps.insert(.computed(name))
                v.bind = .computed(name)
                // What it reads, through every computed value it reads (§4.18: variables, options, data…); the
                // computed values themselves only one level down, so a chain of computed values stays linear.
                for dep in decl.initializerDeps {
                    if case .computed = dep { continue }
                    v.deps.insert(dep)
                }
            case "saved":
                v.deps.insert(.variable(name))
                v.bind = .saved(name)
            default:
                v.deps.insert(.variable(name))
                v.bind = .variable(name)
            }
            v.open = activeOpenSlot(v.open ?? decl.open)
            v.isConstant = false
            return v
        }
        // Element names, in the position and size arguments of a Freeform sibling.
        if let element = preName(named: name) {
            if context.styleName != nil {
                reportStyleUsesVariable(name, at: r, style: context.styleName!)
                return .error
            }
            symbols[nodeID] = .element(id(element.call))
            var v = Val(.elementName)
            v.elementName = name
            return v
        }
        // Built-in values.
        if let ns = catalog.namespace(named: name) {
            symbols[nodeID] = .builtIn(.namespace(name))
            noteSince(ns.doc.since, name: name, at: r)
            var v = Val(ns.value?.type ?? .any)
            v.namespace = name
            if let value = ns.value {
                v.range = value.range
                v.base = value.displayBase
                v.dataPath = name
                v.deps.insert(.data(name))
                recordDataUse(nodePath: name, memberPath: name, node: node, context: context)
                notePermission(namespace: ns, member: value, at: r)
            }
            return v
        }
        if name == "Color" || name == "Paint" || catalog.enumeration(name) != nil || localEnumNames.contains(name) {
            var v = Val(.any)
            v.qualifier = name
            return v
        }
        if catalog.component(named: name) != nil {
            var v = Val(.any)
            v.component = name
            return v
        }
        return reportUnknownName(node, token: token, context, expected: expected)
    }

    /// `event` (§4.16): only in the blocks of pointer events.
    func resolveEvent(_ node: PositionedNode, _ context: ExprContext) -> Val {
        if let style = context.styleName {
            reportStyleUsesVariable("event", at: range(node), style: style)
            return .error
        }
        guard let action = context.action, action.eventAvailable else {
            report(.eventOutsideEvent, range(node))
            return .error
        }
        symbols[id(node)] = .event
        var v = Val(.record(action.eventRecord ?? "Event"))
        v.deps.insert(.event)
        v.bind = .event
        return v
    }

    /// The "finds nothing" table of §4.2, in order.
    func reportUnknownName(_ node: PositionedNode, token: PositionedToken, _ context: ExprContext,
                           expected: DeskType?) -> Val {
        let name = token.token.name
        let r = range(token)
        if provisionalNames.contains(name) { return .error }
        if let requires = requiresNewer {
            report(.newerName, r, ["name": .code(name), "version": .code(requires.description)])
            return .error
        }
        if let row = foreignRows(forName: name).first {
            reportForeignName(row, at: r, name: name, call: nil)
            return .error
        }
        if let option = options[name] {
            option.used = true
            report(.missingOptionsPrefix, r, ["name": .code(name)],
                   fixIts: [fix("insert", [edit(r.lowerBound..<r.lowerBound, "options.")], ["text": .code("options.")])])
            return .error
        }
        // Text is expected: the content of `Text`, a title, an option label, `info.name` and the other translatable
        // fields (§4.2).
        if !context.isBase && (context.display && context.param?.role == .display && context.param?.translatable == true || context.translatableField) {
            var fixIts = [fix("addQuotes", [edit(r, "\"\(name)\"")])]
            if let caseFix = caseVariantSuggestion(name, context),
               catalog.namespace(named: caseFix) == nil || catalog.namespace(named: caseFix)?.value != nil {
                fixIts.append(fix("fix", [edit(r, caseFix)]))
            }
            report(.textWithoutQuotes, r, ["fixed": .code("\"\(name)\"")], fixIts: fixIts)
            return .error
        }
        if let expected, implicitCaseFits(name, expected: expected) {
            report(.missingDot, r, ["name": .code(name)],
                   fixIts: [fix("insert", [edit(r.lowerBound..<r.lowerBound, ".")], ["text": .code(".")])])
            return .error
        }
        if expected == nil, !context.isBase, catalog.implicitMemberTypes(name).count == 1, catalog.namespace(named: name) == nil {
            report(.missingDot, r, ["name": .code(name)],
                   fixIts: [fix("insert", [edit(r.lowerBound..<r.lowerBound, ".")], ["text": .code(".")])])
            return .error
        }
        if let caseFix = caseVariantSuggestion(name, context) {
            report(.wrongCase, r, ["suggestion": .code(caseFix)], fixIts: [fix("fix", [edit(r, caseFix)])])
            return .error
        }
        let candidates = visibleValueNames(context)
        let suggestion = DidYouMean.suggest(name, candidates: candidates, keywords: { word in
            index.keywordMatches(word).compactMap { path -> String? in
                if case .namespace(let n) = path { return n }
                return nil
            }
        }, rank: { catalog.namespace(named: $0)?.doc.rank ?? 40 })
        var arguments: [String: DiagnosticArgument] = ["name": .code(name)]
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first {
            arguments["suggestion"] = .code(best)
            if suggestion.fixable { fixIts.append(fix("fix", [edit(r, best)])) }
        }
        report(.unknownName, r, arguments, fixIts: fixIts)
        return .error
    }

    /// Own names and built-in values visible here, for did-you-mean.
    func visibleValueNames(_ context: ExprContext) -> [String] {
        var names = loopStack.map(\.name)
        names += declOrder.map(\.name)
        names += catalog.namespaces.map(\.name).filter { !$0.contains(".") }
        return names
    }

    /// A value name that differs only in case (`Cpu` → `cpu`).
    func caseVariantSuggestion(_ name: String, _ context: ExprContext) -> String? {
        let lowered = name.lowercased()
        return visibleValueNames(context).first { $0 != name && $0.lowercased() == lowered }
    }

    /// Whether `.name` is a case of the expected type.
    func implicitCaseFits(_ name: String, expected: DeskType) -> Bool {
        switch expected {
        case .enumeration(let id):
            if catalog.enumeration(id)?.enumCase(named: name) != nil { return true }
            return localEnums[id]?.contains(name) == true
        case .color: return index.namedValues["Color.\(name)"] != nil
        case .paint: return index.namedValues["Color.\(name)"] != nil || index.namedValues["Paint.\(name)"] != nil
        case .lengthSpec: return catalog.enumeration("LengthKeyword")?.enumCase(named: name) != nil
        case .oneOf(let types): return types.contains { implicitCaseFits(name, expected: $0) }
        case .binding(let inner): return implicitCaseFits(name, expected: inner)
        default: return false
        }
    }

    func reportStyleUsesVariable(_ name: String, at r: Range<Int>, style: String) {
        // The `if:` of a modifier in the style that reads it: the condition moves to where the style is used.
        var condition: (text: String, removal: Range<Int>)?
        if let info = styles[style], info.file == file {
            var stack = [info.node]
            while let node = stack.popLast(), condition == nil {
                if node.kind == .modifierApp, let clause = ModifierAppSyntax(unchecked: node).arguments {
                    let all = clause.arguments
                    if let argument = all.first(where: { $0.label?.name == "if" && range($0.value.node).contains(r.lowerBound) }) {
                        condition = (text(argument.value.node), argumentRemovalRange(argument, in: all))
                    }
                }
                stack += node.childNodes
            }
        }
        let fixed = ".style(\(style), if: \(condition?.text ?? "…"))"
        guard report(.styleUsesVariable, r, ["name": .code(name), "fixed": .code(fixed)]) else { return }
        if let condition {
            styleConditionMoves.append((diagnostics.count - 1, style, condition.text, condition.removal))
        }
    }

    /// Completes DK5007's fix-it once the style's uses are known: the condition leaves the style and goes on every
    /// `.style(s)` (none when a use already has a condition).
    func completeStyleConditionMoves() {
        for move in styleConditionMoves where move.index < diagnostics.count {
            guard let style = styles[move.style] else { continue }
            var edits = [edit(move.removal, "")]
            var ok = true
            for (use, symbol) in symbols {
                guard case .style(let id, let f) = symbol, id == style.id, f == file, use.kind == .identifierExpr else { continue }
                let end = use.utf8Start + move.style.utf8.count
                // Only a plain `.style(s)`: its `)` follows the name.
                guard text(end..<(end + 1)) == ")" else { ok = false; break }
                edits.append(edit(end..<end, ", if: \(move.condition)"))
            }
            guard ok, edits.count > 1 else { continue }
            diagnostics[move.index].fixIts = [fix("moveConditionToStyle", edits)]
        }
    }
}
