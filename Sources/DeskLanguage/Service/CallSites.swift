import Foundation

// The call a position is in: which component, modifier, function, action, option control or data call it is, the
// ways it can be called, and what is written between its parentheses. Signature help lists the signatures; hover
// cards read the parameter an argument label names; completion will offer the labels still missing.

/// A call and what is written in it.
struct DeskCallSite {
    enum Owner: Equatable {
        case component, control, modifier, function, action, dataCall, formatOptions
    }

    /// One argument as written.
    struct Argument {
        /// The label, when one is written.
        var label: String?
        /// From the argument's first byte to the comma after it (or the closing parenthesis), UTF-8.
        var span: Range<Int>
        /// The value's node index in the table.
        var value: Int?
    }

    var owner: Owner
    /// The catalog entry, when there is one.
    var path: CatalogPath?
    /// How it is shown: `Text`, `.padding`, `calendar.month`, `round`.
    var name: String
    var signatures: [Signature]
    var arguments: [Argument]
    /// Between the parentheses (after `(`, up to `)` or the end of what was written), UTF-8.
    var inside: Range<Int>
    /// The argument list's node index (an argument clause, or the interpolation of format options).
    var clause: Int

    /// The argument a position is in, counted by the commas before it; `arguments.count` after the last comma.
    func argumentIndex(at offset: Int) -> Int {
        for (k, argument) in arguments.enumerated() where offset <= argument.span.upperBound { return k }
        return arguments.count
    }
}

extension DeskSnapshot {
    /// The innermost call whose parentheses hold a UTF-8 offset (or the format options of an interpolation, after
    /// its first comma).
    func callSite(at offset: Int) -> DeskCallSite? {
        let table = nodeTable
        guard let start = table.innermost(at: offset) else { return nil }
        var i: Int? = start
        while let e = i {
            let entry = table.entries[e]
            switch entry.kind {
            case .argumentClause:
                let tokens = entry.positioned.childTokens
                if let open = tokens.first, open.kind == .lParen, !open.token.isMissing, offset >= open.textRange.upperBound {
                    let close = tokens.last.flatMap { $0.kind == .rParen && !$0.token.isMissing ? $0 : nil }
                    if close == nil || offset <= close!.textStart {
                        let inside = open.textRange.upperBound..<(close?.textStart ?? entry.textEnd)
                        if let site = argumentSite(clause: e, inside: inside) { return site }
                        return nil
                    }
                }
            case .interpolation:
                if let site = formatOptionSite(interpolation: e, offset: offset) { return site }
            case .block, .sourceFile:
                // A call does not reach into the blocks written after it.
                return nil
            default:
                break
            }
            i = entry.parent >= 0 ? entry.parent : nil
        }
        return nil
    }

    /// The arguments between the parentheses, one per comma-separated piece (an empty piece after a comma is an
    /// argument still to be written).
    private func arguments(of clause: Int, inside: Range<Int>) -> [DeskCallSite.Argument] {
        let table = nodeTable
        var commas: [Int] = []
        for token in table.entries[clause].positioned.childTokens where token.kind == .comma && !token.token.isMissing {
            commas.append(token.textStart)
        }
        let argumentEntries = table.children(of: clause).filter { table.entries[$0].kind == .argument }
        guard !commas.isEmpty || !argumentEntries.isEmpty else { return [] }
        var out: [DeskCallSite.Argument] = []
        var from = inside.lowerBound
        for end in commas + [max(inside.upperBound, commas.last ?? inside.upperBound)] {
            let span = from..<max(from, end)
            var argument = DeskCallSite.Argument(label: nil, span: span, value: nil)
            if let a = argumentEntries.first(where: { table.entries[$0].textStart >= span.lowerBound && table.entries[$0].textStart <= span.upperBound
                                                      && table.entries[$0].textEnd > table.entries[$0].textStart }) {
                let children = table.children(of: a)
                if let l = children.first(where: { table.entries[$0].kind == .label }),
                   let token = table.entries[l].positioned.childTokens.first, !token.token.isMissing {
                    argument.label = token.token.name
                }
                argument.value = children.last { table.entries[$0].kind != .label }
            }
            out.append(argument)
            from = end + 1
        }
        return out
    }

    private func argumentSite(clause: Int, inside: Range<Int>) -> DeskCallSite? {
        let table = nodeTable
        let entry = table.entries[clause]
        guard entry.parent >= 0 else { return nil }
        let parent = table.entries[entry.parent]
        let catalog = options.catalog
        var owner: DeskCallSite.Owner
        var path: CatalogPath?
        var name: String
        var signatures: [Signature]
        switch parent.kind {
        case .callStmt:
            guard let callee = table.children(of: entry.parent).first(where: { table.entries[$0].kind == .callee }) else { return nil }
            let target = TargetSyntax(unchecked: table.entries[callee].positioned)
            guard !target.name.token.isMissing else { return nil }
            let parts = [target.name.token.name] + target.members.map(\.token.name)
            name = parts.joined(separator: ".")
            if parts.count > 1 {
                guard let found = memberAt(target.members.last!.textRange.lowerBound) ?? catalog.serviceMember(dotted: parts)
                else { return nil }
                path = found.path
                signatures = found.spec.signatures
                owner = found.spec.kind == .action ? .action : .dataCall
            } else {
                let callName = parts[0]
                let facts = checked.elements[table.id(entry.parent)]
                let inOptions = table.ancestors(of: entry.parent).contains { table.entries[$0].kind == .optionsBlock }
                if let facts, let spec = catalog.component(named: facts.component) {
                    owner = .component
                    path = .component(spec.name)
                    signatures = spec.signatures
                } else if inOptions, let spec = catalog.control(named: callName) {
                    owner = .control
                    path = .control(spec.name)
                    signatures = spec.signatures
                } else if let spec = catalog.component(named: callName) {
                    owner = .component
                    path = .component(spec.name)
                    signatures = spec.signatures
                } else if let spec = catalog.control(named: callName) {
                    owner = .control
                    path = .control(spec.name)
                    signatures = spec.signatures
                } else if let spec = catalog.function(named: callName) {
                    owner = spec.kind == .action ? .action : .function
                    path = .function(spec.name)
                    signatures = spec.signatures
                } else {
                    return nil
                }
            }
        case .modifierApp:
            let tokens = parent.positioned.childTokens
            guard tokens.count >= 2, !tokens[1].token.isMissing, let spec = catalog.modifier(named: tokens[1].token.name) else { return nil }
            owner = .modifier
            path = .modifier(spec.name)
            name = "." + spec.name
            signatures = spec.signatures
        case .callExpr:
            guard let calleeIndex = table.children(of: entry.parent).first, calleeIndex != clause else { return nil }
            let callee = table.entries[calleeIndex]
            switch callee.kind {
            case .identifierExpr:
                let token = IdentifierExprSyntax(unchecked: callee.positioned).token
                guard !token.token.isMissing, let spec = catalog.function(named: token.token.name) else { return nil }
                owner = spec.kind == .action ? .action : .function
                path = .function(spec.name)
                name = spec.name
                signatures = spec.signatures
            case .memberExpr:
                guard let token = callee.positioned.childTokens.last(where: { $0.kind != .dot }), !token.token.isMissing,
                      let found = memberAt(token.textRange.lowerBound) else { return nil }
                path = found.path
                signatures = found.spec.signatures
                owner = found.spec.kind == .action ? .action : found.path.isData ? .dataCall : .function
                name = found.path.description
            default:
                return nil
            }
        case .implicitMemberExpr:
            // `.color(light: …, dark: …)`: an adaptive color.
            let tokens = parent.positioned.childTokens
            guard tokens.count >= 2, tokens[1].token.name == "color", let spec = catalog.modifier(named: "color") else { return nil }
            owner = .function
            path = .modifier("color")
            name = ".color"
            signatures = spec.signatures.filter { $0.params.contains { $0.label != nil } }
        default:
            return nil
        }
        guard !signatures.isEmpty else { return nil }
        return DeskCallSite(owner: owner, path: path, name: name, signatures: signatures,
                            arguments: arguments(of: clause, inside: inside), inside: inside, clause: clause)
    }

    /// The member the index resolved at a name's start, with its catalog entry.
    private func memberAt(_ offset: Int) -> (path: CatalogPath, spec: MemberSpec)? {
        guard let occurrence = symbolIndex.names[safe: DeskSymbolIndex.lastStarting(atOrBefore: offset, in: symbolIndex.names)],
              occurrence.range.lowerBound == offset, let path = occurrence.path,
              let spec = options.catalog.serviceMember(for: path) else { return nil }
        return (path, spec)
    }

    private func formatOptionSite(interpolation e: Int, offset: Int) -> DeskCallSite? {
        let table = nodeTable
        let entry = table.entries[e]
        let children = table.children(of: e)
        guard let valueIndex = children.first, table.entries[valueIndex].kind != .formatOption else { return nil }
        let options = children.filter { table.entries[$0].kind == .formatOption }
        // After the first comma, before the closing brace.
        guard let first = options.first, offset > table.entries[first].textStart else { return nil }
        let end = entry.positioned.childTokens.last.flatMap { $0.kind == .interpolationEnd && !$0.token.isMissing ? $0.textStart : nil }
        if let end, offset > end { return nil }
        let valueType = recordedType(valueIndex)?.type
        let catalog = self.options.catalog
        var params: [ParamSpec] = []
        for spec in catalog.formatOptions where DeskSnapshot.formatOption(spec, appliesTo: valueType) {
            guard !params.contains(where: { $0.label == spec.label }) else { continue }
            params.append(ParamSpec(label: spec.label, name: spec.label, type: spec.type, range: spec.range, doc: spec.doc.text))
        }
        guard !params.isEmpty else { return nil }
        let inside = table.entries[first].textStart..<(end ?? entry.textEnd)
        var arguments: [DeskCallSite.Argument] = []
        for (k, o) in options.enumerated() {
            let option = table.entries[o]
            let next = k + 1 < options.count ? table.entries[options[k + 1]].textStart : inside.upperBound
            let label = table.children(of: o).first { table.entries[$0].kind == .label }.flatMap { l -> String? in
                let token = table.entries[l].positioned.childTokens.first
                return token.flatMap { $0.token.isMissing ? nil : $0.token.name }
            }
            let value = table.children(of: o).last { table.entries[$0].kind != .label }
            // Each option's span starts after its comma.
            arguments.append(DeskCallSite.Argument(label: label, span: (option.textStart + 1)..<max(option.textStart + 1, next), value: value))
        }
        return DeskCallSite(owner: .formatOptions, path: nil, name: "{…}", signatures: [Signature(params: params)],
                            arguments: arguments, inside: inside, clause: e)
    }

    /// Whether a format option applies to a value of a type (nil: not known, so every option may).
    static func formatOption(_ spec: FormatOptionSpec, appliesTo type: DeskType?) -> Bool {
        guard let type else { return true }
        if type == .json || type == .any { return true }
        for t in spec.appliesTo {
            switch t {
            case .any: return true
            case .anyNumber: if type.isNumeric { return true }
            case .number(let d): if case .number(let own) = type, own == d { return true }
            default: if type.sameKind(as: t) { return true }
            }
        }
        return false
    }
}

extension CatalogPath {
    /// A member of data (a namespace's member), not of a value type.
    var isData: Bool {
        if case .member = self { return true }
        return false
    }
}

extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, index >= 0, index < count else { return nil }
        return self[index]
    }
}
