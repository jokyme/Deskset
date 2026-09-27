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
        if token.token.isMissing { return false }
        if token.kind == .invalidIdentifier { return false }
        if token.kind.isKeyword || (!allowBlockWords && Chars.blockWords.contains(name)) {
            var fixIts: [FixIt] = []
            if token.kind == .eventKeyword {
                fixIts.append(fix("renameTo", [edit(r, "item")], ["text": .code("item")]))
            } else {
                fixIts.append(fix("rename", [edit(r, name + "Value")]))
            }
            report(.reservedName, r, ["name": .code(name)], fixIts: fixIts)
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
        for statement in statements {
            let decl = DeclarationSyntax(unchecked: statement)
            let token = decl.name
            guard !token.token.isMissing else { continue }
            let name = token.token.name
            guard checkOwnName(token, kind: "declaration") else { continue }
            if let other = decls[name] {
                reportNameClash(token, other: LocalizedText("another declaration", "另一个声明"), otherRange: other.nameRange)
                continue
            }
            if let element = preNames.first(where: { $0.name == name }) {
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
        for decl in declOrder { _ = declarationValue(decl) }
        reportComputedCycles()
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
    func reportComputedCycles() {
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
        var reported = Set<String>()
        for decl in declOrder {
            guard !reported.contains(decl.name) else { continue }
            if let cycle = Checker.findCycle(from: decl.name, graph: graph) {
                guard cycle.contains(where: { decls[$0]?.keyword == "computed" }) else { continue }
                for n in cycle { reported.insert(n) }
                let list = (cycle + [cycle[0]]).map { DiagnosticArgument.code($0) }
                report(.computedCycle, decls[cycle[0]]!.nameRange, ["cycle": .list(list, joiner: .and)])
                for n in cycle { decls[n]?.poisoned = true; decls[n]?.val?.error = true }
            }
        }
    }

    /// A cycle through `start`, in order, or nil.
    static func findCycle(from start: String, graph: [String: [String]]) -> [String]? {
        var path: [String] = []
        var onPath = Set<String>()
        var visited = Set<String>()
        func visit(_ n: String) -> [String]? {
            if onPath.contains(n) {
                if n == start, let i = path.firstIndex(of: n) { return Array(path[i...]) }
                return nil
            }
            if visited.contains(n) { return nil }
            visited.insert(n)
            onPath.insert(n)
            path.append(n)
            for m in graph[n] ?? [] {
                if let c = visit(m) { return c }
            }
            path.removeLast()
            onPath.remove(n)
            return nil
        }
        return visit(start)
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
        if token.kind == .eventKeyword { return resolveEvent(node, context) }
        if token.token.flags.contains(.keywordCaseVariant) { return .error }

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
            if mute == 0 { decl.used = true }
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
                v.deps.formUnion(decl.initializerDeps)
            case "saved":
                v.deps.insert(.variable(name))
                v.bind = .saved(name)
            default:
                v.deps.insert(.variable(name))
                v.bind = .variable(name)
            }
            v.open = decl.open
            v.isConstant = false
            return v
        }
        // Element names, in the position and size arguments of a Freeform sibling.
        if let element = preNames.first(where: { $0.name == name }) {
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
        if let requires = requiresNewer {
            report(.newerName, r, ["name": .code(name), "version": .code(requires.description)])
            return .error
        }
        if let row = foreignRows(forName: name).first {
            reportForeignName(row, at: r, name: name, call: nil)
            return .error
        }
        if let option = options[name] {
            if mute == 0 { option.used = true }
            report(.missingOptionsPrefix, r, ["name": .code(name)],
                   fixIts: [fix("insert", [edit(r.lowerBound..<r.lowerBound, "options.")], ["text": .code("options.")])])
            return .error
        }
        if context.display && context.param?.role == .display && context.param?.translatable == true {
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
        if expected == nil, catalog.implicitMemberTypes(name).count == 1, catalog.namespace(named: name) == nil {
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
        report(.styleUsesVariable, r, ["name": .code(name), "fixed": .code(".style(\(style), if: …)")])
    }
}
