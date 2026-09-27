import Foundation

// Phase C2 (§4.3–§4.6): the type of every expression. `infer` types an expression with the type expected where it is
// written (a parameter, the other side of a comparison…), so literals adopt dimensions, implicit members resolve and
// literal branches of `?:` are checked. Diagnostics about the inside of the expression are reported here; whether the
// result fits where it is used is decided by `coerce` (Checker+Calls).

extension Checker {
    func infer(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        var val: Val
        switch node.kind {
        case .numberLiteral: val = inferNumber(node, context, expected: expected)
        case .stringLiteral: val = inferString(node, context, expected: expected)
        case .boolLiteral:
            val = Val(.bool)
            val.boolLiteral = BoolLiteralSyntax(unchecked: node).value
            val.isConstant = true
        case .identifierExpr: val = resolveIdentifier(node, context, expected: expected)
        case .memberExpr: val = inferMember(node, context, expected: expected)
        case .callExpr: val = inferCall(node, context, expected: expected)
        case .implicitMemberExpr: val = inferImplicitMember(node, context, expected: expected)
        case .binaryExpr: val = inferBinary(node, context, expected: expected)
        case .prefixExpr: val = inferPrefix(node, context, expected: expected)
        case .rangeExpr: val = inferRange(node, context)
        case .ternaryExpr: val = inferTernary(node, context, expected: expected)
        case .listLiteral: val = inferList(node, context, expected: expected)
        case .parenExpr:
            let inner = ParenExprSyntax(unchecked: node)
            val = infer(inner.value.node, context, expected: expected)
        default:
            // `unexpected`, `foreignConstruct`: reported by the parser.
            val = .error
        }
        if mute == 0 && !val.error && val.namespace == nil && val.qualifier == nil && val.component == nil {
            types[id(node)] = SemType(type: val.type, displayBase: val.base, range: val.range)
        }
        return val
    }

    /// Types `node` and reports DK3037 / DK3028 / DK6005 for names that are not values.
    func inferValue(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let val = infer(node, context, expected: expected)
        // A data namespace where the expected choice has a case of the same name (`info { category: time }`):
        // the dot is missing (DK3010), not a group of data used as a value (§4.2).
        if !val.error, let ns = val.namespace, node.kind == .identifierExpr, let expected,
           catalog.namespace(named: ns)?.value == nil, implicitCaseFits(ns, expected: expected) {
            let r = range(node)
            report(.missingDot, r, ["name": .code(ns)],
                   fixIts: [fix("insert", [edit(r.lowerBound..<r.lowerBound, ".")], ["text": .code(".")])])
            return .error
        }
        return requireValue(val, node, context)
    }

    /// A namespace, component, type qualifier or element name used where a value is needed.
    func requireValue(_ val: Val, _ node: PositionedNode, _ context: ExprContext) -> Val {
        if val.error { return val }
        if let ns = val.namespace, catalog.namespace(named: ns)?.value == nil {
            let spec = catalog.namespace(named: ns)
            let main = spec?.mainMember.map { "\(ns).\($0)" } ?? ns
            var fixIts: [FixIt] = []
            if spec?.mainMember != nil { fixIts.append(fix("replaceWith", [edit(range(node), main)], ["text": .code(main)])) }
            report(.namespaceAsValue, range(node), ["name": .code(ns), "suggestion": .code(main)], fixIts: fixIts)
            return .error
        }
        if let component = val.component {
            report(.componentAsValue, range(node), ["name": .code(component)])
            return .error
        }
        if let qualifier = val.qualifier {
            report(.choiceNeedsContext, range(node), ["name": .code(qualifier)])
            return .error
        }
        if let name = val.elementName, !context.geometry {
            report(.referenceNotAllowedHere, range(node))
            _ = name
            return .error
        }
        return val
    }

    // MARK: - Numbers

    func inferNumber(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let literal = NumberLiteralSyntax(unchecked: node)
        guard let value = literal.value else { return .error }
        guard let unit = literal.unit else {
            var v = Val(.number(.plain))
            v.plainLiteral = value
            v.literalValue = value
            v.isConstant = true
            return v
        }
        switch unit.status {
        case .known:
            guard let spec = catalog.unit(spelling: unit.text) else { return .error }
            var v = Val(.number(spec.dimension))
            v.literalValue = value * spec.factor + spec.offset
            v.literalUnit = unit.text
            v.isConstant = true
            if spec.adoptsBase { v.adoptsBase = true } else if spec.dimension == .bytes || spec.dimension == .bytesPerSecond {
                v.base = unit.text.contains("i") ? 1024 : nil
            }
            return v
        case .diagnosed(let id):
            if id == .rainmeterRelativePosition { return relativePosition(node, literal, context, unit: unit) }
            // Reported by the lexer; the value keeps the dimension recovery gives it.
            if let misspelling = index.unitMisspellings[unit.text], let d = misspelling.dimension {
                var v = Val(.number(d))
                v.isConstant = true
                return v
            }
            return .error
        case .relativePosition:
            return relativePosition(node, literal, context, unit: unit)
        case .unknown:
            return .error
        }
    }

    /// `4R`, `2r` (§4.10): Rainmeter's relative position; DK9309 in the x:/y: of `.position` or `.offset`,
    /// DK1024 elsewhere.
    func relativePosition(_ node: PositionedNode, _ literal: NumberLiteralSyntax, _ context: ExprContext,
                          unit: UnitSpelling) -> Val {
        let r = range(node)
        let n = literal.token.token.numberText
        if let axis = context.positionAxis {
            let edge: String
            if axis == "x" { edge = unit.text == "R" ? "right" : "left" } else { edge = unit.text == "R" ? "bottom" : "top" }
            var previousName = "previous"
            var fixIts: [FixIt] = []
            var hint = DiagnosticArgument.text(LocalizedText("", ""))
            if let element = context.element, let parent = element.parent,
               let i = parent.children.firstIndex(where: { $0 === element }), i > 0 {
                let previous = parent.children[i - 1]
                if let name = previous.name {
                    previousName = name
                } else {
                    previousName = "previous"
                }
            }
            if let parentKind = context.element?.parent?.kind, parentKind == .row || parentKind == .column {
                hint = hintText(.rainmeterRelativePosition, "inStack")
            }
            let fixed = "\(previousName).\(edge) + \(n)"
            fixIts.append(fix("rewrite", [edit(r, fixed)]))
            report(.rainmeterRelativePosition, r, ["text": .code(literal.token.token.text), "fixed": .code(fixed),
                                                   "hint": hint], fixIts: fixIts)
        } else {
            let units = catalog.units.map { DiagnosticArgument.code($0.spelling) }
            report(.unknownUnit, r, ["unit": .code(unit.text), "list": .list(units, joiner: .and)])
        }
        return .error
    }

    // MARK: - Member access

    /// `a.b` (§4.2 "member access").
    func inferMember(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let member = MemberExprSyntax(unchecked: node)
        let nameToken = member.name
        let name = nameToken.token.name
        guard !nameToken.token.isMissing else { return .error }
        let baseNode = member.base.node
        // `.text.opacity(50%)`: the base of a chain whose members return its own type takes the chain's type.
        let baseExpected: DeskType? = baseNode.kind == .implicitMemberExpr ? expected : nil
        var baseContext = context
        baseContext.isBase = true
        let base = infer(baseNode, baseContext, expected: baseExpected)
        if base.error { return .error }
        return memberOf(base, name: name, nameRange: range(nameToken), node: node, baseNode: baseNode, context,
                        called: false, expected: expected)
    }

    /// The member `name` of `base`; `called` when written with parentheses (a method).
    func memberOf(_ base: Val, name: String, nameRange: Range<Int>, node: PositionedNode, baseNode: PositionedNode,
                  _ context: ExprContext, called: Bool, expected: DeskType?) -> Val {
        let nodeID = id(node)
        // A type written as a qualifier: `Weekday.monday`, `Color.text`, `Theme.dark`.
        if let qualifier = base.qualifier {
            return qualifiedCase(qualifier, name: name, nameRange: nameRange, node: node)
        }
        // `options.x`.
        if base.namespace == "options" {
            return optionValue(name, nameRange: nameRange, node: node, context)
        }
        // A data namespace.
        if let ns = base.namespace, let spec = catalog.namespace(named: ns) {
            if let nested = catalog.namespace(named: "\(ns).\(name)") {
                symbols[nodeID] = .builtIn(.namespace(nested.name))
                var v = Val(nested.value?.type ?? .any)
                v.namespace = nested.name
                return v
            }
            if let m = spec.member(named: name) {
                if m.kind != .field && !called {
                    report(.missingParens, nameRange, ["name": .code("\(ns).\(name)")],
                           fixIts: [fix("insert", [edit(nameRange.upperBound..<nameRange.upperBound, "()")], ["text": .code("()")])])
                    return .error
                }
                if m.kind == .field && called {
                    return reportUnknownMember(base, baseNode: baseNode, name: name, nameRange: nameRange, context, called: true)
                }
                symbols[nodeID] = .builtIn(.member(namespace: ns, name: name))
                noteSince(m.doc.since, name: "\(ns).\(name)", at: nameRange)
                noteDeprecated(m.doc, name: "\(ns).\(name)", at: nameRange)
                if m.kind == .action { return actionValue(m, path: "\(ns).\(name)", at: nameRange, context) }
                if !called { return dataValue(m, namespace: spec, path: "\(ns).\(name)", node: node, nameRange: nameRange, context) }
                var v = Val(m.type)
                v.dataPath = "\(ns).\(name)"
                return v
            }
            if let record = spec.instanceOf.flatMap({ catalog.record($0) }), let field = record.field(named: name) {
                if field.kind != .field && !called {
                    report(.missingParens, nameRange, ["name": .code("\(ns).\(name)")],
                           fixIts: [fix("insert", [edit(nameRange.upperBound..<nameRange.upperBound, "()")], ["text": .code("()")])])
                    return .error
                }
                symbols[nodeID] = .builtIn(.recordField(record: record.id, name: name))
                noteSince(field.doc.since, name: "\(ns).\(name)", at: nameRange)
                if called { var v = Val(field.type); v.dataPath = "\(ns).\(name)"; return v }
                return dataValue(field, namespace: spec, path: "\(ns).\(name)", node: node, nameRange: nameRange, context)
            }
            if let value = spec.value {
                var asValue = Val(value.type)
                asValue.range = value.range
                asValue.base = value.displayBase
                asValue.deps = base.deps
                if let m = catalog.member(name, of: value.type, call: called) {
                    return typedMember(asValue, member: m, name: name, nameRange: nameRange, node: node)
                }
            }
            return reportUnknownMember(base, baseNode: baseNode, name: name, nameRange: nameRange, context, called: called,
                                       expected: expected)
        }
        // A named element's geometry.
        if let elementName = base.elementName {
            return elementGeometry(elementName, member: name, nameRange: nameRange, node: node, context)
        }
        if base.component != nil || base.namespace != nil {
            return .error
        }
        // Json: a member without parentheses is always a field.
        if base.isJson && !called {
            if name == "isMissing" {
                var v = Val(.bool)
                v.deps = base.deps
                return v
            }
            var v = Val(.json)
            v.deps = base.deps
            v.canBeMissing = true
            v.dataPath = base.dataPath
            return v
        }
        // `event` has the fields of the event it belongs to (§4.16): `dx` only in `.onDrag`, `files` only in `.onDrop`.
        if base.bind == .event, !called, let owner = context.action?.owner, let fields = Checker.eventFields(owner),
           !fields.contains(name), catalog.member(name, of: base.type, call: false) != nil {
            var arguments: [String: DiagnosticArgument] = ["base": .code("event"), "name": .code(name), "event": .code("." + owner)]
            if fields.isEmpty {
                arguments["hint"] = hintText(.unknownMember, "noEventFields")
            } else {
                arguments["hint"] = hintText(.unknownMember, "eventFields")
                arguments["fields"] = .list(fields.map { .code($0) }, joiner: .and)
            }
            report(.unknownMember, nameRange, arguments)
            return .error
        }
        if let m = catalog.member(name, of: base.type, call: called) {
            return typedMember(base, member: m, name: name, nameRange: nameRange, node: node)
        }
        return reportUnknownMember(base, baseNode: baseNode, name: name, nameRange: nameRange, context, called: called,
                                   expected: expected)
    }

    /// The `event` fields of a pointer event (§4.16), or nil for a block with no known event.
    static func eventFields(_ owner: String) -> [String]? {
        switch owner {
        case "onClick", "onDoubleClick", "onRightClick": return ["x", "y", "xPercent", "yPercent"]
        case "onDrag": return ["x", "y", "xPercent", "yPercent", "dx", "dy"]
        case "onScroll": return ["direction"]
        case "onDrop": return ["files", "text"]
        default: return nil
        }
    }

    /// A member of a value (a record's field, a list's member, a member of text, dates, colors or web data).
    func typedMember(_ base: Val, member m: MemberSpec, name: String, nameRange: Range<Int>, node: PositionedNode) -> Val {
        var v = Val(resolveTypeVars(m.type, base: base.type))
        v.deps = base.deps
        v.range = m.range == .none ? nil : m.range
        v.base = m.displayBase ?? (v.dimension == .bytes || v.dimension == .bytesPerSecond ? base.base : nil)
        v.canBeMissing = base.canBeMissing
        v.secret = base.secret
        if case .list(let e) = base.type, ["first", "last", "item", "sum", "average", "max", "min"].contains(name) {
            if name == "sum" || name == "average" || name == "max" || name == "min" { v.type = e }
            else if m.kind == .field { v.type = e }
        }
        if case .fixed = m.range {} else if name == "item" || name == "first" || name == "last" {
            v.range = base.range
        }
        noteSince(m.doc.since, name: name, at: nameRange)
        if let dataPath = base.dataPath { v.dataPath = dataPath + "." + name }
        return v
    }

    /// Replaces `T0` by the element type of a list receiver (or the receiver's type).
    func resolveTypeVars(_ type: DeskType, base: DeskType) -> DeskType {
        switch type {
        case .typeVar:
            if case .list(let e) = base { return e }
            return base
        case .list(let inner): return .list(resolveTypeVars(inner, base: base))
        default: return type
        }
    }

    /// A data member read as a value: its type, range and base, the dependency, the data use and the permission.
    func dataValue(_ m: MemberSpec, namespace: NamespaceSpec, path: String, node: PositionedNode, nameRange: Range<Int>,
                   _ context: ExprContext) -> Val {
        var v = Val(m.type)
        v.range = m.range == .none ? nil : m.range
        v.base = m.displayBase
        v.dataPath = path
        v.deps.insert(.data(path))
        v.canBeMissing = true
        if m.settable { v.bind = .settableData(path) } else { v.bind = .readOnlyData(path) }
        if m.type == .bool { v.canBeMissing = false }
        recordDataUse(nodePath: namespace.name, memberPath: path, node: node, context: context)
        notePermission(namespace: namespace, member: m, at: nameRange)
        return v
    }

    func actionValue(_ m: MemberSpec, path: String, at r: Range<Int>, _ context: ExprContext) -> Val {
        var v = Val(.any)
        v.dataPath = path
        return v
    }

    /// `Weekday.monday`, `Color.text`, `Paint.glass`, `Theme.dark`.
    func qualifiedCase(_ qualifier: String, name: String, nameRange: Range<Int>, node: PositionedNode) -> Val {
        if qualifier == "Color" || qualifier == "Paint" {
            if let value = index.namedValues["\(qualifier).\(name)"] ?? (qualifier == "Paint" ? index.namedValues["Color.\(name)"] : nil) {
                symbols[id(node)] = .enumCase(type: value.type, case: name)
                noteSince(value.doc.since, name: "\(qualifier).\(name)", at: nameRange)
                var v = Val(value.type == "Paint" ? .paint : .color)
                v.implicitName = name
                v.isConstant = true
                if name == "accent" || ["text", "dim", "faint", "separator"].contains(name) { v.deps.insert(.appearance) }
                return v
            }
            let names = catalog.namedValues.filter { $0.type == qualifier || (qualifier == "Paint") }.map(\.name)
            reportUnknownChoice(name, at: nameRange, what: .type(qualifier == "Color" ? .color : .paint), candidates: names)
            return .error
        }
        if let spec = catalog.enumeration(qualifier) {
            if let c = spec.enumCase(named: name) {
                symbols[id(node)] = .enumCase(type: qualifier, case: name)
                noteSince(c.since, name: "\(qualifier).\(name)", at: nameRange)
                var v = Val(.enumeration(qualifier))
                v.implicitName = name
                v.isConstant = true
                return v
            }
            reportUnknownChoice(name, at: nameRange, what: .type(.enumeration(qualifier)), candidates: spec.cases.map(\.name))
            return .error
        }
        if let cases = localEnums[qualifier] {
            if cases.contains(name) {
                symbols[id(node)] = .enumCase(type: qualifier, case: name)
                var v = Val(.enumeration(qualifier))
                v.implicitName = name
                v.isConstant = true
                return v
            }
            reportUnknownChoice(name, at: nameRange, what: .type(.enumeration(qualifier)), candidates: cases)
            return .error
        }
        return .error
    }

    /// DK3003 with did-you-mean among the type's members, their keywords and one level down.
    func reportUnknownMember(_ base: Val, baseNode: PositionedNode, name: String, nameRange: Range<Int>,
                             _ context: ExprContext, called: Bool, expected: DeskType? = nil) -> Val {
        let baseText = text(baseNode)
        if let requires = requiresNewer {
            report(.newerName, nameRange, ["name": .code(name), "version": .code(requires.description)])
            return .error
        }
        // Foreign members: `music.artwork`, `x.toggle()`.
        let fullPath = baseText + "." + name
        if let row = index.foreignRows(fullPath).first ?? index.foreignRows(name).first(where: {
            if case .member = $0.pattern { return true }
            return false
        }) {
            reportForeignMember(row, at: nameRange, base: baseText, name: name, node: nameRange)
            return .error
        }
        var candidates: [String] = []
        var deeper: [String: String] = [:]
        var keywordTargets: [String] = []
        if let ns = base.namespace, let spec = catalog.namespace(named: ns) {
            candidates = spec.members.map(\.name)
            if let record = spec.instanceOf.flatMap({ catalog.record($0) }) { candidates += record.fields.map(\.name) }
            candidates += catalog.namespaces.filter { $0.name.hasPrefix(ns + ".") }.map { String($0.name.dropFirst(ns.count + 1)) }
            // One level down: the fields of its members' records.
            for m in spec.members where m.kind == .field {
                if case .record(let rid) = m.type, let record = catalog.record(rid), record.field(named: name) != nil {
                    deeper[name] = "\(m.name).\(name)"
                }
            }
            if let record = spec.instanceOf.flatMap({ catalog.record($0) }) {
                for f in record.fields where f.kind == .field {
                    if case .record(let rid) = f.type, let inner = catalog.record(rid), inner.field(named: name) != nil,
                       deeper[name] == nil {
                        deeper[name] = "\(f.name).\(name)"
                    }
                    if case .date = f.type, let dateMember = index.typeMember("Date", name, call: false), deeper[name] == nil {
                        _ = dateMember
                        deeper[name] = "\(f.name).\(name)"
                    }
                }
            }
            for m in spec.members where m.kind == .field && deeper[name] == nil {
                if case .date = m.type, index.typeMember("Date", name, call: false) != nil { deeper[name] = "\(m.name).\(name)" }
            }
            for path in index.keywordMatches(name) {
                if case .member(let n, let member) = path, n == ns { keywordTargets.append(member) }
                if case .recordField(let rid, let field) = path, spec.instanceOf == rid { keywordTargets.append(field) }
            }
            // One level down, by synonym: `weather.temp` → `weather.now.temperature`.
            if deeper[name] == nil, keywordTargets.isEmpty {
                var fields: [(String, DeskType)] = spec.members.filter { $0.kind == .field }.map { ($0.name, $0.type) }
                if let record = spec.instanceOf.flatMap({ catalog.record($0) }) {
                    fields += record.fields.filter { $0.kind == .field }.map { ($0.name, $0.type) }
                }
                for path in index.keywordMatches(name) {
                    guard case .recordField(let rid, let field) = path else { continue }
                    if let owner = fields.first(where: { $0.1 == .record(rid) }) { deeper[name] = "\(owner.0).\(field)"; break }
                }
            }
        } else {
            candidates = catalog.members(of: base.type).map(\.name)
            for path in index.keywordMatches(name) {
                switch path {
                case .recordField(let rid, let field):
                    if case .record(let id) = base.type, id == rid { keywordTargets.append(field) }
                    if case .list(.record(let id)) = base.type, id == rid { keywordTargets.append(field) }
                case .typeMember(let t, let member):
                    if DeskCatalog.valueTypeName(of: base.type) == t || t == "Any" { keywordTargets.append(member) }
                default: break
                }
            }
        }
        var arguments: [String: DiagnosticArgument] = ["base": .code(baseText), "name": .code(name)]
        var fixIts: [FixIt] = []
        if let path = deeper[name] {
            arguments["suggestion"] = .code("\(baseText).\(path)")
            fixIts.append(fix("fix", [edit(nameRange, path)]))
        } else {
            let suggestion = DidYouMean.suggest(name, candidates: candidates, keywords: { _ in keywordTargets })
            if let best = suggestion.names.first {
                arguments["suggestion"] = .code("\(baseText).\(best)")
                // In a display position only distance 1 qualifies; elsewhere a farther name also qualifies when it
                // has the type the position expects (§6.2 step 5).
                var fits = false
                if !context.display, let expected, let type = memberType(of: base, named: best) {
                    fits = (cost(Val(type), expected) ?? 9) <= 1
                }
                let fixable = suggestion.via == .keyword ? suggestion.fixable
                    : (suggestion.fixable && (suggestion.distance ?? 9) <= 1) || (suggestion.unique && fits)
                if fixable { fixIts.append(fix("fix", [edit(nameRange, best)])) }
            }
        }
        // `for disk in disks { disk.at("/") }`: the own name hides the built-in that has this member (§4.2).
        if baseNode.kind == .identifierExpr, base.namespace == nil, let ns = catalog.namespace(named: baseText),
           ns.member(named: name) != nil || catalog.namespace(named: "\(baseText).\(name)") != nil {
            arguments["hint"] = hintText(.unknownMember, "hidesBuiltIn")
        }
        report(.unknownMember, nameRange, arguments, fixIts: fixIts)
        return .error
    }

    /// The type of a member of a value (a namespace's member or field, or a member of its type).
    func memberType(of base: Val, named name: String) -> DeskType? {
        if let ns = base.namespace, let spec = catalog.namespace(named: ns) {
            if let m = spec.member(named: name), m.kind == .field { return m.type }
            if let record = spec.instanceOf.flatMap({ catalog.record($0) }), let f = record.field(named: name) { return f.type }
            return nil
        }
        return catalog.members(of: base.type).first { $0.name == name }.map(\.type)
    }

    // MARK: - Options

    /// `options.x` (§4.13).
    func optionValue(_ name: String, nameRange: Range<Int>, node: PositionedNode, _ context: ExprContext) -> Val {
        guard let option = options[name] else {
            if let requires = requiresNewer {
                report(.newerName, nameRange, ["name": .code(name), "version": .code(requires.description)])
                return .error
            }
            let suggestion = DidYouMean.suggest(name, candidates: optionOrder.map(\.name))
            var fixIts: [FixIt] = []
            if let best = suggestion.names.first, suggestion.fixable || suggestion.via == .caseOnly {
                fixIts.append(fix("didYouMean", [edit(nameRange, best)], ["text": .code(best)]))
            }
            report(.unknownOption, nameRange, ["name": .code(name)], fixIts: fixIts)
            return .error
        }
        option.used = true
        symbols[id(node)] = .option(option.id, file: option.file)
        var v = option.val
        v.deps.insert(.option(name))
        v.bind = .option(name)
        v.optionName = name
        v.open = option.open
        v.isConstant = false
        v.secret = option.control == "Secret"
        return v
    }

    // MARK: - Element geometry

    static let geometryMembers: Set<String> = ["left", "right", "top", "bottom", "width", "height", "centerX", "centerY"]

    /// `title.right` (§4.10): only in position and size arguments, only siblings in the same Freeform, never an
    /// element inside `if` or `for`.
    func elementGeometry(_ name: String, member: String, nameRange: Range<Int>, node: PositionedNode,
                         _ context: ExprContext) -> Val {
        let r = range(node)
        guard context.geometry else {
            report(.referenceNotAllowedHere, r)
            return .error
        }
        guard Checker.geometryMembers.contains(member) else {
            let suggestion = DidYouMean.suggest(member, candidates: Array(Checker.geometryMembers))
            var arguments: [String: DiagnosticArgument] = ["base": .code(name), "name": .code(member)]
            if let best = suggestion.names.first { arguments["suggestion"] = .code("\(name).\(best)") }
            report(.unknownMember, nameRange, arguments)
            return .error
        }
        guard let target = preName(named: name) else { return .error }
        if target.quoted, !Checker.isIdentifier(name) {
            report(.nameNotReferable, r, ["name": .code(name)])
            return .error
        }
        if target.insideIf || target.insideFor {
            report(.referenceIntoIfOrFor, r, ["name": .code(name), "construct": .code(target.insideFor ? "for" : "if")])
            return .error
        }
        if let element = context.element {
            let sameElement = target.call.range == element.node.range
            let parentCall = element.parent?.node
            let sibling = parentCall != nil && target.container?.range == parentCall?.range
            if sameElement {
                if member != "width" && member != "height" {
                    element.geometryRefs.append((name, r, context.positionAxis != nil))
                }
            } else if !sibling || element.parent?.kind != .freeform {
                report(.referenceNotSibling, r, ["name": .code(name)])
                return .error
            } else {
                element.geometryRefs.append((name, r, context.positionAxis != nil))
            }
        }
        var v = Val(.number(.length))
        v.deps.insert(.elementGeometry(name))
        return v
    }

    static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    // MARK: - Implicit members

    /// `.caption`, `.color(light: …, dark: …)` (§4.2 "implicit members").
    func inferImplicitMember(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let implicit = ImplicitMemberExprSyntax(unchecked: node)
        let name = implicit.name.token.name
        let nameRange = range(implicit.name)
        let r = range(node)
        guard !implicit.name.token.isMissing else { return .error }
        if let arguments = implicit.arguments {
            // `.color(light:dark:)`: an adaptive color.
            if name == "color", expected == nil || expected == .color || expected == .paint || expected.map({ implicitCaseFits("red", expected: $0) }) == true {
                let args = arguments.arguments
                for arg in args { _ = inferValue(arg.value.node, context, expected: .color) }
                var v = Val(.color)
                v.deps.insert(.appearance)
                v.isConstant = true
                return v
            }
            // A foreign spelling such as `.system(size:)` is reported at the modifier; anything else is unknown.
            for arg in arguments.arguments { _ = speculate { infer(arg.value.node, context, expected: nil) } }
        }
        return resolveImplicit(name, nameRange: nameRange, fullRange: r, node: node, context, expected: expected)
    }

    func resolveImplicit(_ name: String, nameRange: Range<Int>, fullRange r: Range<Int>, node: PositionedNode,
                         _ context: ExprContext, expected: DeskType?) -> Val {
        let nodeID = id(node)
        func caseVal(_ type: String, isColor: Bool = false, isPaint: Bool = false) -> Val {
            symbols[nodeID] = .enumCase(type: type, case: name)
            var v: Val
            if isPaint { v = Val(.paint) } else if isColor { v = Val(.color) } else { v = Val(.enumeration(type)) }
            v.implicitName = name
            v.isConstant = true
            if isColor && ["accent", "text", "dim", "faint", "separator"].contains(name) { v.deps.insert(.appearance) }
            if !isColor && !isPaint, let spec = catalog.enumeration(type), let c = spec.enumCase(named: name) {
                noteSince(c.since, name: ".\(name)", at: nameRange)
                if let d = c.minimumMacOS { _ = d }
            }
            return v
        }
        switch expected {
        case .enumeration(let id)?:
            if catalog.enumeration(id)?.enumCase(named: name) != nil { return caseVal(id) }
            if localEnums[id]?.contains(name) == true { return caseVal(id) }
            if id == "Feature" {
                let features = catalog.features.map(\.id)
                let suggestion = DidYouMean.suggest(name, candidates: features)
                var fixIts: [FixIt] = []
                if let best = suggestion.names.first, suggestion.names.count == 1 || suggestion.fixable {
                    fixIts.append(fix("didYouMean", [edit(r, "." + best)], ["text": .code("." + best)]))
                }
                report(.unknownFeature, r, ["list": .list(features.map { .code("." + $0) }, joiner: .and)], fixIts: fixIts)
                return .error
            }
            if let row = foreignImplicitRow(name) { reportForeignImplicit(row, at: r, name: name); return .error }
            if requiresNewer != nil {
                report(.newerName, r, ["name": .code("." + name), "version": .code(requiresNewer!.description)])
                return .error
            }
            let cases = catalog.enumeration(id)?.cases.map(\.name) ?? localEnums[id] ?? []
            if context.param?.role == .styleRef || styles[name] != nil && context.modifier == "style" {
                return .error
            }
            reportUnknownChoice(name, at: r, what: .type(.enumeration(id)), candidates: cases, fullRange: r)
            return .error
        case .color?, .paint?:
            if index.namedValues["Color.\(name)"] != nil { return caseVal("Color", isColor: true) }
            if expected == .paint, index.namedValues["Paint.\(name)"] != nil { return caseVal("Paint", isPaint: true) }
            if let row = foreignImplicitRow(name) { reportForeignImplicit(row, at: r, name: name); return .error }
            let names = catalog.namedValues.filter { $0.type == "Color" || expected == .paint }.map(\.name)
            reportUnknownChoice(name, at: r, what: .type(expected!), candidates: names, fullRange: r)
            return .error
        case .lengthSpec?:
            if catalog.enumeration("LengthKeyword")?.enumCase(named: name) != nil { return caseVal("LengthKeyword") }
            if let row = foreignImplicitRow(name) { reportForeignImplicit(row, at: r, name: name); return .error }
            reportUnknownChoice(name, at: r, what: .type(.lengthSpec), candidates: catalog.enumeration("LengthKeyword")?.cases.map(\.name) ?? [],
                                fullRange: r)
            return .error
        case .oneOf(let types)?:
            for t in types where implicitCaseFits(name, expected: t) {
                return resolveImplicit(name, nameRange: nameRange, fullRange: r, node: node, context, expected: t)
            }
            if let row = foreignImplicitRow(name) { reportForeignImplicit(row, at: r, name: name); return .error }
            let cases = types.flatMap { t -> [String] in
                if case .enumeration(let id) = t { return catalog.enumeration(id)?.cases.map(\.name) ?? [] }
                return []
            }
            reportUnknownChoice(name, at: r, what: .type(types.first ?? .any), candidates: cases, fullRange: r)
            return .error
        case .binding(let inner)?:
            return resolveImplicit(name, nameRange: nameRange, fullRange: r, node: node, context, expected: inner)
        case .list(let inner)?:
            return resolveImplicit(name, nameRange: nameRange, fullRange: r, node: node, context, expected: inner)
        default:
            break
        }
        if case .enumeration? = expected {} else if let expected, expected != .any, !isTypeVar(expected) {
            // A type that has no cases: numbers, text…
            if let row = foreignImplicitRow(name) { reportForeignImplicit(row, at: r, name: name); return .error }
            report(.choiceNeedsContext, r, ["name": .code(name)])
            return .error
        }
        // No expected type (§4.2 rule 3): the catalog types that have the case (earliest since), and local enums.
        var candidates = catalog.implicitMemberTypes(name)
        if candidates.contains("Color") { candidates.removeAll { $0 == "Paint" } }
        for (enumName, cases) in localEnums where cases.contains(name) && !candidates.contains(enumName) {
            candidates.append(enumName)
        }
        if candidates.count == 1 {
            let t = candidates[0]
            return caseVal(t, isColor: t == "Color", isPaint: t == "Paint")
        }
        if candidates.isEmpty {
            if let row = foreignImplicitRow(name) { reportForeignImplicit(row, at: r, name: name); return .error }
            if requiresNewer != nil {
                report(.newerName, r, ["name": .code("." + name), "version": .code(requiresNewer!.description)])
                return .error
            }
            report(.choiceNeedsContext, r, ["name": .code(name)])
            return .error
        }
        // Several types: open (settled by use in a declaration or option), else ambiguous.
        var v = Val(.any)
        v.implicitName = name
        v.isConstant = true
        pendingAmbiguous = (name, candidates, r)
        if context.declaration != nil || context.place == .options {
            return v
        }
        reportAmbiguousChoice(name, candidates: candidates, at: r)
        return .error
    }

    func isTypeVar(_ t: DeskType) -> Bool {
        if case .typeVar = t { return true }
        return false
    }

    /// DK3018 with one fix-it per candidate type.
    func reportAmbiguousChoice(_ name: String, candidates: [String], at r: Range<Int>) {
        let names = candidates.map { c -> DiagnosticArgument in
            if c == "Color" { return .type(.color) }
            if c == "Paint" { return .type(.paint) }
            if localEnums[c] != nil { return .code(c) }
            return .type(.enumeration(c))
        }
        let fixIts = candidates.map { c in fix("qualifyChoice", [edit(r, "\(c).\(name)")], ["text": .code("\(c).\(name)")]) }
        report(.ambiguousChoice, r, ["name": .code(name), "candidates": .list(names, joiner: .or)], fixIts: fixIts)
    }

    /// DK3005 with did-you-mean among the choices.
    func reportUnknownChoice(_ name: String, at r: Range<Int>, what: DiagnosticArgument, candidates: [String],
                             fullRange: Range<Int>? = nil) {
        let suggestion = DidYouMean.suggest(name, candidates: candidates, keywords: { word in
            index.keywordMatches(word).compactMap { path -> String? in
                switch path {
                case .enumCase(_, let n), .namedValue(_, let n): return candidates.contains(n) ? n : nil
                default: return nil
                }
            }
        })
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first, suggestion.fixable || (suggestion.distance ?? 9) <= 2 {
            let target = fullRange ?? r
            fixIts.append(fix("didYouMean", [edit(target, "." + best)], ["text": .code("." + best)]))
        }
        let shown = candidates.prefix(12).map { DiagnosticArgument.code("." + $0) }
        report(.unknownChoice, fullRange ?? r, ["name": .code(name), "what": what, "choices": .list(Array(shown), joiner: .or)],
               fixIts: fixIts)
    }

    // MARK: - Calls in expressions

    func inferCall(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let call = CallExprSyntax(unchecked: node)
        let calleeNode = call.callee.node
        let arguments = call.arguments
        switch calleeNode.kind {
        case .identifierExpr:
            let identifier = IdentifierExprSyntax(unchecked: calleeNode)
            return callGlobal(identifier.name, calleeNode: calleeNode, arguments: arguments, node: node, context,
                              expected: expected)
        case .memberExpr:
            let member = MemberExprSyntax(unchecked: calleeNode)
            let baseNode = member.base.node
            let name = member.name.token.name
            let baseExpected: DeskType? = baseNode.kind == .implicitMemberExpr ? expected : nil
            var baseContext = context
            baseContext.isBase = true
            let base = infer(baseNode, baseContext, expected: baseExpected)
            if base.error {
                for arg in arguments.arguments { _ = speculate { infer(arg.value.node, context, expected: nil) } }
                return .error
            }
            return callMethod(base, name: name, nameRange: range(member.name), calleeNode: calleeNode, baseNode: baseNode,
                              arguments: arguments, node: node, context, expected: expected)
        case .implicitMemberExpr:
            return infer(calleeNode, context, expected: expected)
        default:
            for arg in arguments.arguments { _ = infer(arg.value.node, context, expected: nil) }
            return .error
        }
    }

    /// `round(x)`, `rgb(…)`, `files(…)`, `Choice(…)`.
    func callGlobal(_ name: String, calleeNode: PositionedNode, arguments: ArgumentClauseSyntax, node: PositionedNode,
                    _ context: ExprContext, expected: DeskType?) -> Val {
        let nameRange = range(calleeNode)
        if let function = catalog.function(named: name) {
            symbols[id(calleeNode)] = .builtIn(.function(name))
            noteSince(function.doc.since, name: name, at: nameRange)
            if function.kind == .action && context.action == nil {
                report(.actionOutsideEvent, range(node), ["name": .code(name)])
                return .error
            }
            if function.onlyInActions && function.kind == .function && context.action == nil
                && context.declaration?.keyword != "variable" {
                report(.randomOutsideAction, range(node))
                return .error
            }
            if let permission = function.permission { notePermission(permission, at: nameRange) }
            let bound = bindCall(function.signatures, arguments: arguments, calleeName: name, what: .code(name),
                                 callRange: range(node), context, owner: .function(function))
            var v = resultOf(bound, rule: bound?.signature.result, fallback: function.data?.type ?? .any)
            if name == "command" {
                checkRefreshMinimum(bound, source: "command", minimum: catalog.limits.minimumCommandEvery, minimumText: "1s")
            }
            if name == "supports", let feature = bound?.values.first?.val.implicitName {
                requirements.features.insert(feature)
            }
            if let data = function.data {
                v.range = data.range == .none ? nil : data.range
                v.base = data.displayBase
                v.dataPath = name
                v.deps.insert(.data(name))
                v.canBeMissing = true
                recordDataUse(nodePath: name, memberPath: name, node: node, context: context, arguments: arguments)
            }
            if name == "rgb" || name == "gradient" || name == "radialGradient" || name == "color" {
                v.isConstant = bound?.values.allSatisfy { $0.val.isConstant } ?? false
            }
            return v
        }
        if name == "Choice" {
            // A Picker choice with a label (checked by the Picker).
            var v = Val(.any)
            if let first = arguments.arguments.first { v = infer(first.value.node, context, expected: expected) }
            if arguments.arguments.count > 1 { _ = infer(arguments.arguments[1].value.node, context, expected: .string) }
            return v
        }
        if catalog.component(named: name) != nil {
            report(.componentAsValue, nameRange, ["name": .code(name)])
            return .error
        }
        for arg in arguments.arguments { _ = speculate { infer(arg.value.node, context, expected: nil) } }
        if let row = foreignRows(forName: name).first {
            reportForeignName(row, at: nameRange, name: name, call: nil, callArguments: arguments)
            return .error
        }
        if let requires = requiresNewer {
            report(.newerName, nameRange, ["name": .code(name), "version": .code(requires.description)])
            return .error
        }
        let functions = catalog.functions.map(\.name)
        let suggestion = DidYouMean.suggest(name, candidates: functions, keywords: { word in
            index.keywordMatches(word).compactMap { path -> String? in
                if case .function(let f) = path { return f }
                return nil
            }
        })
        var args: [String: DiagnosticArgument] = ["name": .code(name)]
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first {
            args["suggestion"] = .code(best)
            if suggestion.fixable { fixIts.append(fix("fix", [edit(nameRange, best)])) }
        }
        report(.unknownName, nameRange, args, fixIts: fixIts)
        return .error
    }

    /// `ns.fn(…)`, `list.item(n)`, `text.contains(…)`, `json.count()`, `color.opacity(…)`.
    func callMethod(_ base: Val, name: String, nameRange: Range<Int>, calleeNode: PositionedNode, baseNode: PositionedNode,
                    arguments: ArgumentClauseSyntax, node: PositionedNode, _ context: ExprContext,
                    expected: DeskType?) -> Val {
        if let ns = base.namespace, let spec = catalog.namespace(named: ns), ns != "options" {
            guard let m = spec.member(named: name), m.kind != .field else {
                for arg in arguments.arguments { _ = speculate { infer(arg.value.node, context, expected: nil) } }
                if spec.member(named: name) != nil || spec.instanceOf.flatMap({ catalog.record($0)?.field(named: name) }) != nil {
                    report(.unexpected, range(arguments.node), ["text": .code(text(arguments.node))],
                           fixIts: [fix("remove", [edit(range(arguments.node), "")])])
                    return .error
                }
                return reportUnknownMember(base, baseNode: baseNode, name: name, nameRange: nameRange, context, called: true)
            }
            let path = "\(ns).\(name)"
            symbols[id(calleeNode)] = .builtIn(.member(namespace: ns, name: name))
            noteSince(m.doc.since, name: path, at: nameRange)
            if m.kind == .action {
                if context.action == nil {
                    report(.actionOutsideEvent, range(node), ["name": .code(path)])
                    return .error
                }
                _ = bindCall(m.signatures, arguments: arguments, calleeName: path, what: .code(path), callRange: range(node),
                             context, owner: .member(m, path: path))
                if let p = m.permission ?? spec.permission { notePermission(p, at: nameRange) }
                var v = Val(.any)
                v.dataPath = path
                return v
            }
            let bound = bindCall(m.signatures, arguments: arguments, calleeName: path, what: .code(path),
                                 callRange: range(node), context, owner: .member(m, path: path))
            if ns == "web" { checkRefreshMinimum(bound, source: path, minimum: catalog.limits.minimumWebEvery, minimumText: "1min") }
            var v = Val(m.type)
            if let rule = bound?.signature.result { v = resultOf(bound, rule: rule, fallback: m.type) }
            v.range = m.range == .none ? nil : m.range
            v.base = m.displayBase
            v.dataPath = path
            v.canBeMissing = true
            if spec.name != "math" {
                v.deps.insert(.data(path))
                recordDataUse(nodePath: path, memberPath: path, node: node, context: context, arguments: arguments)
                // Records returned by a namespace's functions (weather.at) do not need the namespace's permission.
                if let p = m.permission { notePermission(p, at: nameRange) }
                else if let p = spec.permission, !(spec.instanceOf != nil && m.kind == .function && m.type == .record(spec.instanceOf!)) {
                    notePermission(p, at: nameRange)
                }
            } else {
                for value in bound?.values ?? [] { v.deps.formUnion(value.val.deps) }
            }
            if name == "read", ns == "sensors", let key = bound?.values.first?.val.stringLiteral,
               let (_, keySpec) = catalog.sensorKey(key) {
                v.type = keySpec.type
                v.base = keySpec.displayBase
            }
            return v
        }
        if base.isJson {
            // Json built-ins are calls.
            let jsonNames = ["count", "item", "value", "asNumber", "asText", "ifMissing"]
            if jsonNames.contains(name) {
                var v: Val
                switch name {
                case "count": v = Val(.number(.plain))
                case "asNumber": v = Val(.number(.plain))
                case "asText": v = Val(.string)
                case "ifMissing":
                    let fallback = arguments.arguments.first.map { infer($0.value.node, context, expected: nil) }
                    v = fallback ?? Val(.json)
                default:
                    for arg in arguments.arguments { _ = infer(arg.value.node, context, expected: nil) }
                    v = Val(.json)
                }
                if name == "count" || name == "asNumber" || name == "asText" {
                    for arg in arguments.arguments { _ = infer(arg.value.node, context, expected: nil) }
                }
                v.deps.formUnion(base.deps)
                v.canBeMissing = true
                return v
            }
        }
        guard let m = catalog.member(name, of: base.type, call: true) else {
            for arg in arguments.arguments { _ = speculate { infer(arg.value.node, context, expected: nil) } }
            if catalog.member(name, of: base.type, call: false) != nil {
                report(.unexpected, range(arguments.node), ["text": .code(text(arguments.node))],
                       fixIts: [fix("remove", [edit(range(arguments.node), "")])])
                return .error
            }
            return reportUnknownMember(base, baseNode: baseNode, name: name, nameRange: nameRange, context, called: true)
        }
        noteSince(m.doc.since, name: name, at: nameRange)
        // `.ifMissing(f)`: the fallback takes the receiver's type.
        var bound: BoundCall?
        if name == "ifMissing" {
            var inner = context
            inner.param = context.param
            let fallback = infer(arguments.arguments.first?.value.node ?? node, inner, expected: base.type)
            if let arg = arguments.arguments.first { _ = coerce(fallback, arg.value.node, to: base.type, what: .code(".ifMissing"), inner) }
            var v = base
            v.deps.formUnion(fallback.deps)
            v.canBeMissing = false
            v.open = nil
            v.bind = nil
            return v
        }
        let signatures = m.signatures.map { sig -> Signature in
            var s = sig
            s.params = sig.params.map { p in var q = p; q.type = resolveTypeVars(p.type, base: base.type); return q }
            return s
        }
        bound = bindCall(signatures, arguments: arguments, calleeName: name, what: .code("." + name), callRange: range(node),
                         context, owner: .typeMember(m))
        var v = Val(resolveTypeVars(m.type, base: base.type))
        if let rule = bound?.signature.result {
            switch rule {
            case .receiver: v = Val(base.type)
            case .elementOf: if case .list(let e) = base.type { v = Val(e) }
            case .fixed(let t): v = Val(resolveTypeVars(t, base: base.type))
            default: break
            }
        }
        if case .list = base.type, name == "first" || name == "last" { v = Val(base.type) }
        v.deps = base.deps
        for value in bound?.values ?? [] { v.deps.formUnion(value.val.deps) }
        v.canBeMissing = base.canBeMissing || name == "item"
        v.range = base.range
        v.base = base.base
        v.secret = base.secret
        if base.type == .color && name == "opacity" { v.isConstant = base.isConstant }
        return v
    }

    /// The result type of a call by its rule (§5.1).
    func resultOf(_ bound: BoundCall?, rule: ResultRule?, fallback: DeskType) -> Val {
        var v = Val(fallback)
        guard let bound else { v.error = fallback == .any; return fallback == .any ? .error : v }
        for value in bound.values { v.deps.formUnion(value.val.deps) }
        switch rule {
        case .fixed(let t)?:
            v.type = t
        case .sameAs(let param)?:
            if let value = bound.values.first(where: { $0.param.name == param }) {
                v.type = value.val.type
                v.base = value.val.base
                v.range = nil
                if value.val.plainLiteral != nil { v.plainLiteral = value.val.plainLiteral }
                v.open = value.val.open
            }
        case .commonOf(let params)?:
            let values = bound.values.filter { params.contains($0.param.name) }.map(\.val)
            if let typed = values.first(where: { $0.dimension != nil && $0.dimension != .plain && $0.plainLiteral == nil }) {
                v.type = typed.type
                v.base = values.compactMap(\.base).first
            } else if let first = values.first {
                v.type = first.type
                if values.allSatisfy({ $0.plainLiteral != nil }) { v.plainLiteral = values.first?.plainLiteral }
            }
        default:
            break
        }
        return v
    }

    /// DK7014: `every:` of a web request or a command below its minimum.
    func checkRefreshMinimum(_ bound: BoundCall?, source: String, minimum: Double, minimumText: String) {
        guard let every = bound?.value("every"), let seconds = every.val.literalValue, every.val.dimension == .time,
              seconds < minimum else { return }
        let r = range(every.node)
        report(.refreshTooFast, r, ["source": .code(source), "min": .code(minimumText)],
               fixIts: [fix("replaceWith", [edit(r, minimumText)], ["text": .code(minimumText)])])
    }

    // MARK: - Ranges, lists, ternaries

    /// `a...b`: a list of whole numbers.
    func inferRange(_ node: PositionedNode, _ context: ExprContext) -> Val {
        let rangeExpr = RangeExprSyntax(unchecked: node)
        let low = inferValue(rangeExpr.low.node, context, expected: .number(.plain))
        let high = inferValue(rangeExpr.high.node, context, expected: .number(.plain))
        var v = Val(.list(.number(.plain)))
        v.deps = low.deps.union(high.deps)
        v.isConstant = low.isConstant && high.isConstant
        for (side, val) in [(rangeExpr.low.node, low), (rangeExpr.high.node, high)] where !val.error {
            if let d = val.dimension, d != .plain, val.open == nil {
                report(.typeMismatch, range(side), ["what": .text(LocalizedText("A range", "范围")),
                                                    "expected": .type(.number(.plain)), "actual": .type(val.type)])
            } else if !val.isNumber && !val.isJson && val.open == nil {
                report(.typeMismatch, range(side), ["what": .text(LocalizedText("A range", "范围")),
                                                    "expected": .type(.number(.plain)), "actual": .type(val.type)])
            }
        }
        if let a = low.plainLiteral, let b = high.plainLiteral {
            if a > b {
                let lowText = text(rangeExpr.low.node), highText = text(rangeExpr.high.node)
                report(.emptyRange, range(node), ["a": .code(lowText), "b": .code(highText)],
                       fixIts: [fix("swap", [edit(range(rangeExpr.low.node), highText), edit(range(rangeExpr.high.node), lowText)])])
            } else if b - a + 1 > Double(catalog.limits.maximumRange) {
                v.literalValue = b - a + 1
            }
            v.literalValue = max(0, b - a + 1)
        }
        return v
    }

    func inferList(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let list = ListLiteralSyntax(unchecked: node)
        let elements = list.elements
        var elementExpected: DeskType?
        if case .list(let e)? = expected { elementExpected = e }
        // Implicit members with no expected type: the one type that has every one of them as a case.
        if elementExpected == nil, !elements.isEmpty, elements.allSatisfy({ $0.node.kind == .implicitMemberExpr }) {
            let names = elements.map { ImplicitMemberExprSyntax(unchecked: $0.node).name.token.name }
            var common: Set<String>?
            for name in names {
                var types = Set(catalog.implicitMemberTypes(name))
                for (enumName, cases) in localEnums where cases.contains(name) { types.insert(enumName) }
                common = common.map { $0.intersection(types) } ?? types
            }
            if let common, common.count == 1 { elementExpected = common.first == "Color" ? .color : (common.first == "Paint" ? .paint : .enumeration(common.first!)) }
            else if let common, common.contains("Color") && common.count == 2 && common.contains("Paint") { elementExpected = .color }
        }
        if elements.count > catalog.limits.maximumListLiteral {
            report(.listTooLong, range(node), ["count": .number(elements.count), "limit": .number(catalog.limits.maximumListLiteral)])
        }
        var first: Val?
        var deps = Set<DepKey>()
        var constant = true
        for element in elements {
            var val = inferValue(element.node, context, expected: elementExpected ?? first.map { $0.type })
            if val.error { continue }
            deps.formUnion(val.deps)
            constant = constant && val.isConstant
            if let f = first {
                if !compatible(val, f.type) && !compatible(f, val.type) {
                    // A missing comma in a multi-line list: `.sunday.monday`.
                    report(.typeMismatch, range(element.node), ["what": .text(LocalizedText("A list's items", "列表的每一项")),
                                                               "expected": .type(f.type), "actual": .type(val.type)])
                }
                if f.plainLiteral != nil, val.dimension != nil, val.plainLiteral == nil { first = val }
            } else {
                if val.plainLiteral != nil, let e = elementExpected, case .number = e { val.type = e }
                first = val
            }
        }
        var v = Val(.list(elementExpected ?? first?.type ?? .any))
        if let e = elementExpected, case .binding(let inner) = e { v.type = .list(inner) }
        v.deps = deps
        v.isConstant = constant
        v.literalValue = Double(elements.count)
        return v
    }

    /// Whether a value can stand where `type` is expected without a conversion diagnostic (a quick test used for list
    /// items and equality).
    func compatible(_ v: Val, _ type: DeskType) -> Bool {
        if v.error || v.open != nil || v.isJson || type == .json || type == .any { return true }
        switch (v.type, type) {
        case (.number(let a), .number(let b)): return a == b || v.plainLiteral != nil
        case (.color, .paint), (.paint, .color): return true
        case (.string, _) where type.isStringLike: return true
        case (_, .string) where v.type.isStringLike: return true
        case (.list(let a), .list(let b)): return a.sameKind(as: b) || a == .any || b == .any
        default: return v.type.sameKind(as: type)
        }
    }

    /// `c ? a : b` (§4.3, D92).
    func inferTernary(_ node: PositionedNode, _ context: ExprContext, expected: DeskType?) -> Val {
        let ternary = TernaryExprSyntax(unchecked: node)
        var conditionContext = context
        conditionContext.display = false
        conditionContext.param = nil
        let condition = inferValue(ternary.condition.node, conditionContext, expected: .bool)
        requireBool(condition, ternary.condition.node)
        let thenNode = ternary.then.node, elseNode = ternary.otherwise.node
        func isLiteralish(_ n: PositionedNode) -> Bool {
            [.numberLiteral, .stringLiteral, .boolLiteral, .implicitMemberExpr].contains(n.kind)
        }
        var a: Val, b: Val
        if let expected, expected != .any {
            a = inferValue(thenNode, context, expected: expected)
            b = inferValue(elseNode, context, expected: expected)
        } else if isLiteralish(thenNode) && !isLiteralish(elseNode) {
            b = inferValue(elseNode, context, expected: nil)
            a = inferValue(thenNode, context, expected: b.error ? nil : b.type)
        } else {
            a = inferValue(thenNode, context, expected: nil)
            b = inferValue(elseNode, context, expected: a.error || a.type == .any ? nil : a.type)
        }
        var v = a.error ? b : a
        v.deps = condition.deps.union(a.deps).union(b.deps)
        v.plainLiteral = nil
        v.stringLiteral = nil
        v.isConstant = a.isConstant && b.isConstant && condition.isConstant
        v.bind = nil
        v.open = a.open ?? b.open
        if a.error || b.error { return v }
        if context.display {
            // Each branch becomes text on its own.
            v.type = .string
            return v
        }
        if a.plainLiteral != nil, let d = b.dimension { v.type = .number(d) }
        else if b.plainLiteral != nil, let d = a.dimension { v.type = .number(d) }
        else if !compatible(a, b.type) && !compatible(b, a.type) {
            report(.typeMismatch, range(elseNode), ["what": .text(LocalizedText("Both results of `?:`", "`?:` 的两个结果")),
                                                    "expected": .type(a.type), "actual": .type(b.type)])
            return .error
        }
        return v
    }

    /// Reports DK4018 when a condition is not yes or no.
    func requireBool(_ v: Val, _ node: PositionedNode) {
        guard !v.error, !v.isJson else { return }
        if let slot = v.open, slot < openSlots.count, openSlots[slot].kind == .type { return }
        if v.type != .bool && v.type != .any {
            report(.conditionNotBool, range(node), ["text": .code(text(node))])
        }
    }

    /// A condition: `if`, `.when`, `if:` (§4.3 Bool contexts).
    @discardableResult
    func checkCondition(_ node: PositionedNode, _ context: ExprContext) -> Val {
        var inner = context
        inner.display = false
        inner.param = nil
        let v = inferValue(node, inner, expected: .bool)
        requireBool(v, node)
        if mute == 0 { dependencies[id(node)] = v.deps }
        checkNotWithMissing(node)
        return v
    }
}
