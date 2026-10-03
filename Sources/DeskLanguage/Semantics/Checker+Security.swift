import Foundation

// Security, data uses and limits (§4.18, §8): permissions a widget needs (DK8101, DK8102), web hosts (DK8103–DK8106),
// the no-live-data rule for background requests (DK8201–DK8204), commands split with zsh's quoting rules so option
// values reach them as positional parameters (DK8208, DK8209), files, symbols and fonts, deprecations, versions, and
// the checks that run once the whole file has been seen.

extension Checker {
    // MARK: - Permissions and data uses

    func notePermission(namespace: NamespaceSpec, member: MemberSpec, at r: Range<Int>) {
        if let p = member.permission { notePermission(p, at: r) }
        else if let p = namespace.permission { notePermission(p, at: r) }
    }

    func notePermission(_ permission: String, at r: Range<Int>) {
        guard mute == 0 else { return }
        requirements.permissions.insert(permission)
        if neededPermissions[permission] == nil {
            neededPermissions[permission] = r
            neededPermissionOrder.append(permission)
        }
    }

    func recordDataUse(nodePath: String, memberPath: String, node: PositionedNode, context: ExprContext,
                       arguments: ArgumentClauseSyntax? = nil) {
        guard mute == 0 else { return }
        let usage: DataUsage = context.action != nil ? .onDemand : context.usage
        let argumentIDs = arguments?.arguments.map { id($0.value.node) } ?? []
        let scope = context.loopScope.filter { _ in arguments?.arguments.isEmpty == false }
        dataUses.append(DataUse(nodePath: nodePath, memberPath: memberPath, usage: usage, arguments: argumentIDs,
                                instanceScope: scope, reference: id(node)))
    }

    func noteDeprecated(_ doc: Doc, name: String, at r: Range<Int>) {
        guard let deprecation = doc.deprecated else { return }
        report(.deprecated, r, ["name": .code(name), "replacement": .code(deprecation.replacement)],
               fixIts: [fix("replace", [edit(r, deprecation.replacement.hasPrefix(".") ? String(deprecation.replacement.dropFirst()) : deprecation.replacement)])])
    }

    // MARK: - Background requests (§8.2)

    /// The no-live-data rule for a value that reaches a background address, command, folder or place.
    func checkValueSource(_ param: ParamSpec, _ val: Val, _ node: PositionedNode, callee: String?) {
        guard param.source == .literalOrOption, !val.error else { return }
        let r = range(node)
        var data = false, variables = false
        var options: [String] = []
        for dep in val.deps {
            switch dep {
            case .data, .appearance, .widgetSize, .elementGeometry: data = true
            case .variable, .computed, .loopVariable, .event: variables = true
            case .option(let name): options.append(name)
            default: break
            }
        }
        let role = param.role
        if data || variables {
            reportLiveData(role, variables: variables && !data, at: r)
        } else if !options.isEmpty {
            pendingOptionSources.append((role, options, r))
        }
        // Whole commands taken from an option.
        if role == .command, node.kind == .memberExpr, let name = val.optionName, let option = self.options[name] {
            option.wholeCommand = true
        }
        if role == .webAddress, let s = val.stringLiteral { checkWebAddress(s, at: r) }
        if role == .webAddress, val.isTemplate, let first = firstTextSegment(node) { checkWebAddress(first, at: r) }
    }

    func reportLiveData(_ role: ParamRole, variables: Bool, at r: Range<Int>) {
        switch role {
        case .command: report(.liveDataInCommand, r)
        case .folderPath: report(.liveFolder, r)
        default: report(variables ? .variableInWebAddress : .liveDataInWebAddress, r)
        }
    }

    func firstTextSegment(_ node: PositionedNode) -> String? {
        guard let string = StringLiteralSyntax(node) else { return nil }
        if case .text(_, let cooked)? = string.segments.first { return cooked }
        return nil
    }

    /// A literal web address: its host must be declared (DK8103); `http://` gets DK8105.
    func checkWebAddress(_ address: String, at r: Range<Int>) {
        let lower = address.lowercased()
        if lower.hasPrefix("http://") {
            report(.insecureHttp, r, fixIts: [fix("replaceWith", [edit(r.lowerBound + 1..<r.lowerBound + 8, "https://")], ["text": .code("https://")])])
        }
        guard let schemeEnd = address.range(of: "://") else { return }
        var host = String(address[schemeEnd.upperBound...])
        if let end = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ":" }) { host = String(host[..<end]) }
        guard !host.isEmpty else { return }
        if !usedHosts.contains(host) { usedHosts.append(host) }
        hostUses.append((host, r))
    }

    static func hostMatches(_ host: String, pattern: String) -> Bool {
        let h = host.lowercased(), p = pattern.lowercased()
        if p.hasPrefix("*.") { return h.hasSuffix(String(p.dropFirst(1))) && h.count > p.count - 1 }
        return h == p
    }

    // MARK: - Commands (§8.2, D103)

    /// Splits a command template with zsh's quoting rules; reports placeholders in single quotes (DK8208) and in the
    /// code argument of a command that runs its argument as code (DK8209); records the command for the install list.
    func checkCommand(_ value: BoundValue, statement: PositionedNode?) {
        let node = value.node
        guard let string = StringLiteralSyntax(node) else {
            if let name = value.val.optionName, let option = options[name] {
                option.wholeCommand = true
                if mute == 0 {
                    commandFacts.append(CommandFacts(node: id(node), template: "{options.\(name)}", script: "", placeholders: [],
                                                     scriptOption: name, knownValues: [name: [option.defaultText].compactMap { $0 }]))
                }
            }
            return
        }
        guard !string.isRaw, mute == 0 else { return }
        // The template: text with placeholders.
        var pieces: [CommandPiece] = []
        for segment in string.segments {
            switch segment {
            case .text(let token, let cooked): pieces.append(.text(cooked, token.textRange))
            case .interpolation(let i):
                let name = text(i.value.node)
                pieces.append(.placeholder(name.hasPrefix("options.") ? String(name.dropFirst(8)) : name, range(i.node)))
            case .foreign: break
            }
        }
        let split = CommandSplitter.split(pieces)
        var placeholders: [String] = []
        var known: [String: [String]] = [:]
        for placeholder in split.placeholders {
            placeholders.append(placeholder.name)
            if let option = options[placeholder.name] {
                known[placeholder.name] = [option.defaultText].compactMap { $0 } + option.assignedValues
            }
            if placeholder.quoting == .single {
                let raw = text(string.node)
                let fixed = CommandSplitter.closeSingleQuotes(around: text(placeholder.range), in: raw)
                report(.placeholderInSingleQuotes, placeholder.range, ["text": .code(text(placeholder.range)),
                                                                       "fixed": .code(String(fixed.dropFirst().dropLast()))],
                       fixIts: [fix("closeQuotes", [edit(range(string.node), fixed)])])
            }
        }
        // Commands that run their argument as code.
        for word in split.rereadingPlaceholders(catalog.rereadingCommands) {
            let command = word.command
            let placeholderText = text(word.placeholder.range)
            // The argument form of the command that was written (§8.2): the value goes after the code, which reads
            // it as its first argument.
            let program = command.split(separator: " ").first.map(String.init) ?? command
            let fixed: String
            switch program {
            case "osascript":
                fixed = "osascript -e 'on run argv' -e 'display dialog (item 1 of argv)' -e 'end run' \(placeholderText)"
            case "sh", "bash", "zsh", "dash", "fish":
                fixed = "\(program) -c '… \"$1\" …' _ \(placeholderText)"
            case "python", "python3":
                fixed = "\(program) -c 'import sys; … sys.argv[1] …' \(placeholderText)"
            case "perl":
                fixed = "perl -e '… $ARGV[0] …' \(placeholderText)"
            case "ruby":
                fixed = "ruby -e '… ARGV[0] …' \(placeholderText)"
            case "node":
                fixed = "node -e '… process.argv[1] …' \(placeholderText)"
            default:
                // `eval`, `source`, `ssh`, `su -c`: run the code through a shell that takes the value as `$1`.
                fixed = "sh -c '… \"$1\" …' _ \(placeholderText)"
            }
            report(.commandRereadsValue, word.placeholder.range, ["command": .code(command), "text": .code(placeholderText),
                                                                  "fixed": .code(fixed)])
        }
        commandFacts.append(CommandFacts(node: id(node), template: text(node), script: split.script, placeholders: placeholders,
                                         scriptOption: nil, knownValues: known))
    }

    // MARK: - Files, symbols, fonts

    /// Pictures and fonts come from the widget's folder (DK4030) and must exist (DK4029).
    func checkFile(_ path: String, _ node: PositionedNode, kind: String) {
        let r = range(node)
        if path.hasPrefix("/") || path.hasPrefix("~") || path.split(separator: "/").contains("..") {
            report(.fileOutsideWidget, r)
            return
        }
        if path.contains("://") { return }
        guard let resources = context.resources else { return }
        if resources.kind(of: path) == nil {
            let similar = resources.similarPaths(to: path)
            var fixIts: [FixIt] = []
            var suggestion = LocalizedText("", "")
            if let best = similar.first {
                suggestion = LocalizedText("Did you mean “\(best)”?", "是不是想写“\(best)”？")
                fixIts.append(fix("replaceWithSimilarFile", [edit(r, "\"\(best)\"")]))
            }
            report(.fileNotFound, r, ["path": .code(path), "suggestion": .text(suggestion)], fixIts: fixIts)
        }
    }

    func checkSymbol(_ name: String, _ node: PositionedNode) {
        guard let symbols = context.symbols, !name.isEmpty else { return }
        if !symbols.exists(name) {
            let r = range(node)
            let similar = symbols.similarSymbols(to: name)
            var fixIts: [FixIt] = []
            if let best = similar.first { fixIts.append(fix("fix", [edit(r, "\"\(best)\"")])) }
            report(.unknownSymbol, r, ["name": .code(name), "suggestion": .code(similar.first ?? "")], fixIts: fixIts)
        }
    }

    func checkFont(_ family: String, _ node: PositionedNode) {
        guard let fonts = context.fonts else { return }
        let r = range(node)
        if context.resources?.kind(of: family) != nil { return }
        if let substitute = fonts.macSubstitute(forWindowsFamily: family) {
            report(.windowsFont, r, ["name": .code(family), "substitute": .code(substitute)],
                   fixIts: [fix("replaceWith", [edit(r, "\"\(substitute)\"")], ["text": .code(substitute)])])
            return
        }
        if !fonts.isInstalled(family: family) {
            var fixIts: [FixIt] = []
            if let best = fonts.similarFamilies(to: family).first {
                fixIts.append(fix("didYouMean", [edit(r, "\"\(best)\"")], ["text": .code(best)]))
            }
            report(.fontNotInstalled, r, ["name": .code(family)], fixIts: fixIts)
        }
    }

    // MARK: - After the whole file

    func finish() {
        settleOpenSlots()
        checkCasesForOpenSlots()
        reportStyleCycles()
        computeInheritance()
        checkLayoutFit()
        checkFreeformOrders()
        completeNumericMetadata()
        // Unused declarations (DK3020); variables that keep their first value (DK4046).
        for decl in declOrder where !decl.used && !decl.poisoned {
            let r = range(decl.node)
            report(.unusedDeclaration, decl.nameRange, ["name": .code(decl.name)],
                   fixIts: [fix("remove", [edit(decl.node.range.lowerBound..<r.upperBound, "")])])
        }
        for decl in pendingVariableFromData where !decl.poisoned {
            let initializer = DeclarationSyntax(unchecked: decl.node).initializer.node
            let source = text(initializer)
            let keywordRange = range(DeclarationSyntax(unchecked: decl.node).keyword)
            report(.variableFromData, decl.nameRange, ["name": .code(decl.name), "source": .code(source)],
                   fixIts: [fix("changeTo", [edit(keywordRange, "computed")], ["text": .code("computed")])],
                   severity: decl.assigned ? .info : .warning)
        }
        // Unused styles and options (for package.desk these are folder checks). A style that a used style
        // includes is used, found by name: a widget's style that replaces a package style (D99) is what the package
        // style's `.style(base)` reaches.
        if !isPackage {
            var work = styleOrder.filter(\.used)
            while let style = work.popLast() {
                for include in style.includes {
                    guard let included = styles[include.style], !included.used else { continue }
                    if mute == 0 { included.used = true }
                    work.append(included)
                }
            }
            for style in styleOrder where !style.used && !style.fromPackage {
                let r = range(style.node)
                report(.unusedStyle, style.nameRange, ["name": .code(style.name)],
                       fixIts: [fix("remove", [edit(style.node.range.lowerBound..<r.upperBound, "")])])
            }
            for option in optionOrder where !option.used && !option.fromPackage {
                report(.unusedOption, option.nameRange, ["name": .code(option.name)])
            }
        }
        // Options assigned something that is not constant count as variables in background requests (D102).
        for (role, names, r) in pendingOptionSources where names.contains(where: { options[$0]?.assignedNonConstant == true }) {
            reportLiveData(role, variables: true, at: r)
        }
        checkPermissions()
        checkHosts()
        if estimatedElements > catalog.limits.maximumElementInstances, let root = widgetBlock {
            report(.tooManyElements, keyword(root), ["count": .number(estimatedElements),
                                                     "limit": .number(catalog.limits.maximumElementInstances)])
        }
        if infoBlock == nil && !isPackage && widgetBlock != nil { reportMissingName(nil) }
        for (style, state, node, _) in stateStyleCalls where styleHasState(style, visited: []) {
            report(.notAllowedInState, range(node), ["name": .code("style"), "state": .code(state == .pressed ? "pressed" : "hover"),
                                                     "hint": hintText(.notAllowedInState, "nestedState")])
        }
    }

    /// DK8101 / DK8102.
    func checkPermissions() {
        let declared = Set(declaredPermissions.map(\.0))
        for permission in neededPermissionOrder where !declared.contains(permission) {
            guard let r = neededPermissions[permission], let spec = index.permissions[permission] else { continue }
            report(.missingPermission, r, ["needs": .text(spec.needsPhrase), "permission": .code(permission)],
                   fixIts: [addPermissionFix(permission)])
        }
        for (permission, r, node) in declaredPermissions where requirements.permissions.contains(permission) == false {
            guard index.permissions[permission] != nil else { continue }
            report(.unusedPermission, r, ["permission": .code(permission)],
                   fixIts: [fix("remove", [edit(listElementRemovalRange(node), "")])])
        }
    }

    /// A field added to the `info` block in canonical style (§3.7 rule 2): after the last field on a one-line block
    /// (`info { name: "T", permissions: [.music] }`), on a line of its own in a multi-line one; first when `first`.
    func infoFieldInsertion(_ field: String, first: Bool = false) -> TextEdit? {
        guard let info = infoBlock ?? packageBlock, let body = info.firstChild(.block), BlockSyntax(unchecked: body).isClosed else { return nil }
        let block = BlockSyntax(unchecked: body)
        let fields = block.statements
        let editor = SyntaxEditor(tree: tree)
        if editor.isSingleLine(body) {
            if fields.isEmpty {
                let open = block.lBrace.textRange.upperBound, close = block.rBrace.textRange.lowerBound
                return edit(open..<close, " \(field) ")
            }
            if first {
                let at = textStart(fields[0])
                return edit(at..<at, field + ", ")
            }
            let at = range(fields[fields.count - 1]).upperBound
            return edit(at..<at, ", " + field)
        }
        let indent = fields.isEmpty ? editor.ownerIndent(of: body) + 4 : editor.contentIndent(of: body)
        let piece = SyntaxEditor.Lines(lines: [String(repeating: " ", count: indent) + field], statementLine: 0, kind: nil, from: nil)
        guard let insertion = editor.insertion(of: piece, into: body, index: first ? 0 : editor.statements(of: body).count) else { return nil }
        return edit(insertion.edit.range, insertion.edit.replacement)
    }

    /// The "Add" fix-it of DK8101: edits `info`, creating it when needed.
    func addPermissionFix(_ permission: String) -> FixIt {
        if let field = infoFields["permissions"], field.value.kind == .listLiteral,
           let edits = Checker.listAppend(".\(permission)", to: field.value, bytes: tree.lines.bytes) {
            return fix("add", edits.map { edit($0.range, $0.text) })
        }
        if let insertion = infoFieldInsertion("permissions: [.\(permission)]") {
            return fix("add", [insertion])
        }
        let start = widgetBlock.map { textStart($0) } ?? 0
        return fix("add", [edit(start..<start, "info { permissions: [.\(permission)] }" + lineBreak + lineBreak)])
    }

    /// The insertions that add an element at the end of a list literal the way it is written: after a trailing
    /// comma (`[.location,]`), and in a list written over several lines on a line of its own, with the last
    /// element's indent, after any comment ending the last element's line. Nil when the list is not closed.
    static func listAppend(_ element: String, to list: PositionedNode, bytes: [UInt8]) -> [(range: Range<Int>, text: String)]? {
        let tokens = list.childTokens
        guard let open = tokens.first, let close = tokens.last, close.kind == .rBracket, !close.token.isMissing,
              open.textRange.upperBound <= close.textStart else { return nil }
        guard let last = list.significantChildNodes.last(where: { !$0.textRange.isEmpty }) else {
            return [(close.textStart..<close.textStart, element)]
        }
        let lastEnd = last.textRange.upperBound
        let comma = tokens.last { $0.kind == .comma && !$0.token.isMissing && $0.textStart >= lastEnd && $0.textStart < close.textStart }
        func isBreak(_ b: UInt8) -> Bool { b == 0x0A || b == 0x0D }
        func lineStart(_ at: Int) -> Int {
            var k = min(at, bytes.count)
            while k > 0, !isBreak(bytes[k - 1]) { k -= 1 }
            return k
        }
        let lastLine = lineStart(last.textRange.lowerBound)
        let multiLine = bytes[open.textRange.upperBound..<close.textStart].contains(where: isBreak)
            && lineStart(open.textStart) != lastLine && lineStart(close.textStart) != lineStart(lastEnd)
        guard multiLine else {
            if let comma { return [(comma.textRange.upperBound..<comma.textRange.upperBound, " " + element + ",")] }
            return [(lastEnd..<lastEnd, ", " + element)]
        }
        var indentEnd = lastLine
        while indentEnd < bytes.count, bytes[indentEnd] == 0x20 || bytes[indentEnd] == 0x09 { indentEnd += 1 }
        let indent = String(decoding: bytes[lastLine..<indentEnd], as: UTF8.self)
        let newline = bytes.firstIndex(of: 0x0D).map { $0 + 1 < bytes.count && bytes[$0 + 1] == 0x0A ? "\r\n" : "\r" }
            ?? "\n"
        // The end of the line the element (and its comma) ends: the new element goes after a comment there.
        let after = comma?.textRange.upperBound ?? lastEnd
        var lineEnd = after
        while lineEnd < bytes.count, !isBreak(bytes[lineEnd]) { lineEnd += 1 }
        let rest = String(decoding: bytes[after..<lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let at = rest.isEmpty || rest.hasPrefix("//") ? (rest.isEmpty ? after : lineEnd) : after
        if comma != nil { return [(at..<at, newline + indent + element + ",")] }
        if at == after { return [(at..<at, "," + newline + indent + element)] }
        return [(lastEnd..<lastEnd, ","), (at..<at, newline + indent + element)]
    }

    /// DK8103 / DK8104.
    func checkHosts() {
        var usedPatterns = Set<String>()
        for (host, r) in hostUses {
            if let pattern = declaredHosts.first(where: { Checker.hostMatches(host, pattern: $0.0) }) {
                usedPatterns.insert(pattern.0)
                continue
            }
            var edits: [TextEdit] = []
            if let field = infoFields["network"], field.value.kind == .listLiteral,
               let added = Checker.listAppend("\"\(host)\"", to: field.value, bytes: tree.lines.bytes) {
                edits += added.map { edit($0.range, $0.text) }
            } else if let insertion = infoFieldInsertion("network: [\"\(host)\"]") {
                edits.append(insertion)
            } else {
                let start = widgetBlock.map { textStart($0) } ?? 0
                edits.append(edit(start..<start, "info { network: [\"\(host)\"] }" + lineBreak + lineBreak))
            }
            report(.hostNotDeclared, r, ["host": .code(host)], fixIts: [fix("add", edits)])
        }
        for (pattern, r) in declaredHosts where !usedPatterns.contains(pattern) && !usesOptionAddresses {
            report(.unusedHost, r, ["host": .code(pattern)])
        }
    }

    var usesOptionAddresses: Bool { pendingOptionSources.contains { $0.0 == .webAddress } }

    /// The range that removes one item of a list and one of its commas.
    func listElementRemovalRange(_ node: PositionedNode) -> Range<Int> {
        let r = range(node)
        guard let list = tree.positionedNode(at: r.lowerBound).flatMap({ findParentList(of: node, from: $0) }) else { return r }
        let elements = ListLiteralSyntax(unchecked: list).elements
        guard let i = elements.firstIndex(where: { $0.node.range == node.range }) else { return r }
        if i > 0 { return range(elements[i - 1].node).upperBound..<r.upperBound }
        if i + 1 < elements.count { return r.lowerBound..<textStart(elements[i + 1].node) }
        return r
    }

    private func findParentList(of node: PositionedNode, from start: PositionedNode) -> PositionedNode? {
        var result: PositionedNode?
        func search(_ n: PositionedNode) {
            guard result == nil, n.range.lowerBound <= node.range.lowerBound, node.range.upperBound <= n.range.upperBound else { return }
            if n.kind == .listLiteral, n.childNodes.contains(where: { $0.range == node.range }) { result = n; return }
            for c in n.childNodes { search(c) }
        }
        search(tree.rootNode)
        return result
    }

    // MARK: - Freeform references (§4.10)

    /// The evaluation order of every Freeform's named children (sizes, then positions), and reference cycles (DK6004).
    func checkFreeformOrders() {
        for freeform in freeforms {
            var graph: [String: [String]] = [:]
            var elementsByName: [String: ElementNode] = [:]
            for child in freeform.children {
                guard let name = child.name else { continue }
                elementsByName[name] = child
                graph[name] = Array(Set(child.geometryRefs.map(\.name).filter { $0 != name })).sorted()
            }
            for cycle in Checker.cycles(in: graph, order: graph.keys.sorted()) {
                let list = (cycle + [cycle[0]]).map { DiagnosticArgument.code($0) }
                let at = elementsByName[cycle[0]]?.geometryRefs.first?.range ?? range(freeform.node)
                report(.referenceCycle, at, ["cycle": .list(list, joiner: .arrow)])
            }
            // Order: named children in dependency order (depth first, without recursion; a reference back onto
            // the current path is skipped), then the others in file order.
            var order: [NodeID] = []
            var done = Set<String>()
            var onPath = Set<String>()
            func visit(_ start: String) {
                guard !done.contains(start), elementsByName[start] != nil else { return }
                var work: [(name: String, next: Int)] = [(start, 0)]
                onPath.insert(start)
                while let (name, i) = work.last {
                    let deps = graph[name] ?? []
                    if i < deps.count {
                        work[work.count - 1].next += 1
                        let dep = deps[i]
                        if !done.contains(dep), !onPath.contains(dep), elementsByName[dep] != nil {
                            onPath.insert(dep)
                            work.append((dep, 0))
                        }
                    } else {
                        work.removeLast()
                        onPath.remove(name)
                        done.insert(name)
                        if let element = elementsByName[name] { order.append(element.id) }
                    }
                }
            }
            for child in freeform.children {
                if let name = child.name { visit(name) } else { order.append(child.id) }
            }
            if mute == 0 { freeformOrders[freeform.id] = order }
        }
    }
}

/// A piece of a command template: text as cooked, or a placeholder (the option's name).
enum CommandPiece {
    case text(String, Range<Int>)
    case placeholder(String, Range<Int>)
}

/// Splits a command template with zsh's quoting rules (§8.2): blanks, `'…'`, `"…"`, `$'…'`, `\`, and the operators
/// `; & | < > ( )`. Each placeholder becomes a positional parameter: `"${1}"` in an unquoted word, `${1}` inside the
/// author's double quotes. Values never become command text.
enum CommandSplitter {
    enum Quoting { case none, single, double }

    struct Placeholder {
        var name: String
        var range: Range<Int>
        var quoting: Quoting
        /// The index of the word it is in.
        var word: Int
    }

    struct Result {
        var script: String
        var placeholders: [Placeholder]
        /// Words as written (placeholders as `{name}`), split at blanks and operators.
        var words: [String]

        /// Placeholders in the code argument of a command that runs its argument as code (`sh -c`, `eval`).
        func rereadingPlaceholders(_ commands: [RereadSpec]) -> [(command: String, placeholder: Placeholder)] {
            var result: [(String, Placeholder)] = []
            for placeholder in placeholders {
                // Find the command word of the simple command the placeholder is in.
                var start = placeholder.word
                while start > 0, !CommandSplitter.operators.contains(words[start - 1]) { start -= 1 }
                guard start < words.count else { continue }
                let name = (words[start] as NSString).lastPathComponent
                for spec in commands where spec.command == name || spec.command == words[start] {
                    if let flag = spec.codeFlag {
                        // The code argument is the word right after the flag.
                        if let flagIndex = words[start..<placeholder.word].lastIndex(of: flag), flagIndex + 1 == placeholder.word {
                            result.append(("\(spec.command) \(flag)", placeholder))
                        }
                    } else if placeholder.word > start {
                        result.append((spec.command, placeholder))
                    }
                }
            }
            return result
        }
    }

    static let operators: Set<String> = [";", "&", "|", "&&", "||", "<", ">", "(", ")"]

    static func split(_ pieces: [CommandPiece]) -> Result {
        var script = ""
        var placeholders: [Placeholder] = []
        var words: [String] = []
        var current = ""
        var quoting = Quoting.none
        var escape = false
        var counter = 0
        func endWord() {
            if !current.isEmpty { words.append(current); current = "" }
        }
        for piece in pieces {
            switch piece {
            case .placeholder(let name, let r):
                counter += 1
                placeholders.append(Placeholder(name: name, range: r, quoting: quoting, word: words.count))
                switch quoting {
                case .none: script += "\"${\(counter)}\""
                case .double: script += "${\(counter)}"
                case .single: script += "${\(counter)}"
                }
                current += "{\(name)}"
            case .text(let s, _):
                for c in s {
                    if escape { escape = false; current.append(c); script.append(c); continue }
                    switch quoting {
                    case .single:
                        script.append(c)
                        if c == "'" { quoting = .none } else { current.append(c) }
                    case .double:
                        script.append(c)
                        if c == "\\" { escape = true } else if c == "\"" { quoting = .none } else { current.append(c) }
                    case .none:
                        script.append(c)
                        if c == "\\" { escape = true }
                        else if c == "'" { quoting = .single }
                        else if c == "\"" { quoting = .double }
                        else if c == " " || c == "\t" || c == "\n" { endWord() }
                        else if ";&|<>()".contains(c) {
                            endWord()
                            if let last = words.last, last == String(c), c == "&" || c == "|" { words[words.count - 1] = last + String(c) }
                            else { words.append(String(c)) }
                        } else { current.append(c) }
                    }
                }
            }
        }
        endWord()
        return Result(script: script, placeholders: placeholders, words: words)
    }

    /// Ends the author's single quotes around a placeholder: `'~/Notes/{x}.txt'` → `'~/Notes/'{x}'.txt'`.
    static func closeSingleQuotes(around placeholder: String, in raw: String) -> String {
        guard let r = raw.range(of: placeholder) else { return raw }
        var result = raw
        // Before the placeholder: close the quote; after it: reopen.
        result.replaceSubrange(r, with: "'" + placeholder + "'")
        return result.replacingOccurrences(of: "''", with: "")
    }
}
