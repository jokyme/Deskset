import Foundation

// Arguments and overloads (§4.3 "argument matching and overloads", D94, D117, D132): values are matched to a
// signature's parameters (labels, positional values, optional positional values placed by type), each fitting
// signature gets a cost, the cheapest wins (ties: earliest `since`, then catalog order), and the chosen one is checked
// for real. When none fits, the diagnostics say what to write instead: a label to add, labels to remove, `else:`.

enum CallOwner {
    case component(ComponentSpec)
    case modifier(ModifierSpec)
    case function(FunctionSpec)
    case member(MemberSpec, path: String)
    case typeMember(MemberSpec)
    case control(ControlSpec)
}

struct BoundValue {
    let param: ParamSpec
    let node: PositionedNode
    let argument: ArgumentSyntax?
    var val: Val
}

struct BoundCall {
    var signature: Signature
    var index: Int
    var values: [BoundValue]
    var failed: Bool

    func value(_ name: String) -> BoundValue? { values.first { $0.param.name == name } }
    func values(of name: String) -> [BoundValue] { values.filter { $0.param.name == name } }
}

/// How a call's arguments map to one signature's parameters.
struct ArgumentPlan {
    /// Parameter index → argument indices (several for a variadic parameter).
    var assignments: [Int: [Int]] = [:]
    var unknownLabels: [Int] = []
    var extraPositional: [Int] = []
    var missing: [Int] = []
    var fits: Bool { unknownLabels.isEmpty && extraPositional.isEmpty && missing.isEmpty }
    /// How well the labels matched (for choosing the signature to report against).
    var score: Int { -(unknownLabels.count * 10 + extraPositional.count * 3 + missing.count) }
}

extension Checker {
    func bindCall(_ signatures: [Signature], arguments clause: ArgumentClauseSyntax?, calleeName: String,
                  what: DiagnosticArgument, callRange: Range<Int>, _ context: ExprContext, owner: CallOwner) -> BoundCall? {
        let arguments = clause?.arguments ?? []
        guard !signatures.isEmpty else { return nil }
        // Structure common to every signature: `=` for `:`, positional after labeled, a label given twice.
        var seenLabels: [String: Range<Int>] = [:]
        var sawLabel = false
        for argument in arguments {
            if let label = argument.label {
                sawLabel = true
                let name = label.name
                if let colon = argument.colon, colon.kind == .equal {
                    report(.equalsInField, range(colon), ["label": .code(name), "fixed": .code("\(name): \(text(argument.value.node))")],
                           fixIts: [fix("replaceWith", [edit(range(colon), ":")], ["text": .code(":")], group: "equalsInField")])
                }
                if let first = seenLabels[name] {
                    report(.duplicateLabel, range(label.node), ["label": .code(name)], notes: [note("otherCopy", first)],
                           fixIts: [fix("removeOne", [edit(argumentRemovalRange(argument, in: arguments), "")])])
                } else {
                    seenLabels[name] = range(label.node)
                }
            } else if sawLabel {
                report(.positionalAfterLabel, range(argument.node), fixIts: [reorderFix(arguments)])
                break
            }
        }
        let calleeLabel = calleeName
        // A built-in choice written in quotes where a signature takes that choice (`.font("headline")`), checked
        // before the text is taken as a font or a color.
        let positionalArguments = arguments.filter { $0.label == nil }
        for (k, argument) in positionalArguments.enumerated() {
            guard let s = StringLiteralSyntax(argument.value.node)?.literalValue, Checker.isIdentifier(s) else { continue }
            for signature in signatures {
                let positionalParams = signature.params.filter { $0.label == nil }
                guard k < positionalParams.count else { continue }
                if case .enumeration = positionalParams[k].type, reportQuotedChoice(argument.value.node, s, expected: positionalParams[k].type) {
                    return nil
                }
            }
        }

        // Plans.
        var plans: [(index: Int, plan: ArgumentPlan)] = []
        for (i, signature) in signatures.enumerated() {
            plans.append((i, planArguments(signature, arguments, context)))
        }
        let fitting = plans.filter { $0.plan.fits }
        var chosen: (index: Int, plan: ArgumentPlan)?
        if fitting.count == 1 {
            chosen = fitting[0]
        } else if fitting.count > 1 {
            var best: (index: Int, plan: ArgumentPlan, cost: Int, json: Bool)?
            var tieJson = false
            for candidate in fitting {
                let signature = signatures[candidate.index]
                var total = 0
                var usesJson = false
                var ok = true
                for (paramIndex, argIndices) in candidate.plan.assignments {
                    let param = signature.params[paramIndex]
                    for a in argIndices {
                        let val = speculate { infer(arguments[a].value.node, argumentContext(context, param, owner), expected: param.type) }
                        guard let c = cost(val, param) else { ok = false; break }
                        if val.isJson { usesJson = true }
                        total += c
                    }
                    if !ok { break }
                }
                guard ok else { continue }
                if let b = best {
                    let s1 = signatures[candidate.index].since, s0 = signatures[b.index].since
                    if total < b.cost || (total == b.cost && s1 < s0) {
                        best = (candidate.index, candidate.plan, total, usesJson)
                        tieJson = false
                    } else if total == b.cost && s1 == s0 && usesJson && b.json {
                        tieJson = true
                    }
                } else {
                    best = (candidate.index, candidate.plan, total, usesJson)
                }
            }
            if tieJson, let b = best {
                let r = arguments.first.map { range($0.value.node) } ?? callRange
                let t = arguments.first.map { text($0.value.node) } ?? ""
                report(.jsonTypeUnclear, r, fixIts: [fix("append", [edit(r.upperBound..<r.upperBound, ".asNumber()")], ["text": .code(".asNumber()")]),
                                                     fix("append", [edit(r.upperBound..<r.upperBound, ".asText()")], ["text": .code(".asText()")])])
                _ = t
                _ = b
                return nil
            }
            if let b = best { chosen = (b.index, b.plan) }
        }
        let reportPlan = chosen ?? plans.max { a, b in
            a.plan.score < b.plan.score || (a.plan.score == b.plan.score && a.index > b.index)
        }!
        let signature = signatures[reportPlan.index]
        let plan = reportPlan.plan
        var failed = false

        // Label mix-ups and missing values.
        if !plan.unknownLabels.isEmpty {
            failed = true
            reportUnknownLabels(plan.unknownLabels, arguments, signature: signature, calleeName: calleeLabel,
                                callRange: callRange, clause: clause, context)
        }
        if !plan.extraPositional.isEmpty {
            failed = true
            reportTooManyArguments(plan.extraPositional, arguments, signature: signature, plan: plan, calleeName: calleeLabel,
                                   callRange: callRange, clause: clause, context, owner: owner)
        }
        let callOnNextLine = clause == nil && tree.diagnostics.contains {
            $0.id == .callOnNextLine && $0.range.lowerBound >= callRange.upperBound && $0.range.lowerBound < callRange.upperBound + 400
        }
        if !plan.missing.isEmpty && plan.unknownLabels.isEmpty && !callOnNextLine {
            failed = true
            for p in plan.missing { reportMissingArgument(signature.params[p], calleeName: calleeLabel, clause: clause, callRange: callRange) }
        }
        // A call whose parameters are all optional with no default, called with none (D133).
        let settable = signature.params.filter { $0.role != .condition }
        if arguments.isEmpty, !settable.isEmpty,
           settable.allSatisfy({ !$0.required && $0.defaultValue == nil && !$0.variadic }),
           case .modifier = owner {
            failed = true
            reportMissingArgument(settable[0], calleeName: calleeLabel, clause: clause, callRange: callRange, emptyCall: true)
        }

        // Check each value against its parameter, for real.
        var values: [BoundValue] = []
        let assigned = Set(plan.assignments.values.flatMap { $0 })
        for (paramIndex, argIndices) in plan.assignments.sorted(by: { $0.key < $1.key }) {
            let param = signature.params[paramIndex]
            for a in argIndices {
                let argument = arguments[a]
                let inner = argumentContext(context, param, owner)
                let valueNode = argument.value.node
                var val = checkArgumentValue(valueNode, param: param, inner, owner: owner)
                if case .control = owner, param.name == "default" {
                    values.append(BoundValue(param: param, node: valueNode, argument: argument, val: val))
                    continue
                }
                checkValueSource(param, val, valueNode, callee: calleeLabel)
                if param.role == .command {
                    checkCommand(BoundValue(param: param, node: valueNode, argument: argument, val: val), statement: nil)
                }
                if !coerce(val, valueNode, to: param.type, what: whatName(param, owner: owner, callee: calleeLabel), inner,
                           range: param.range, param: param) {
                    failed = true
                    val.error = true
                }
                values.append(BoundValue(param: param, node: valueNode, argument: argument, val: val))
            }
        }
        // Values that fit nowhere are still checked, quietly.
        for (i, argument) in arguments.enumerated() where !assigned.contains(i) {
            _ = speculate { infer(argument.value.node, context, expected: nil) }
        }
        return BoundCall(signature: signature, index: reportPlan.index, values: values, failed: failed)
    }

    /// The context an argument is typed in: display positions, the parameter, geometry for position and size.
    func argumentContext(_ context: ExprContext, _ param: ParamSpec, _ owner: CallOwner) -> ExprContext {
        var inner = context
        inner.param = param
        inner.display = param.role == .display
        inner.geometry = false
        inner.positionAxis = nil
        switch owner {
        case .modifier(let m):
            inner.modifier = m.name
            if ["position"].contains(m.name), param.label == "x" || param.label == "y" {
                inner.geometry = true
                inner.positionAxis = param.label
            }
            if m.name == "offset", param.label == "x" || param.label == "y" { inner.positionAxis = param.label }
            if ["width", "height", "size"].contains(m.name) { inner.geometry = true }
            inner.callee = "." + m.name
        case .component(let c): inner.callee = c.name
        case .function(let f): inner.callee = f.name
        case .member(_, let path): inner.callee = path
        case .typeMember(let m): inner.callee = m.name
        case .control(let c): inner.callee = c.name
        }
        return inner
    }

    /// Types one argument with its parameter's type as the expected type; element names and styles are read here.
    func checkArgumentValue(_ node: PositionedNode, param: ParamSpec, _ context: ExprContext, owner: CallOwner) -> Val {
        switch param.role {
        case .elementName:
            return elementNameArgument(node, context)
        case .styleRef:
            return styleArgument(node, context)
        case .declaresElementName:
            var v = Val(.elementName)
            v.isConstant = true
            return v
        default:
            break
        }
        if case .binding = param.type { return infer(node, context, expected: param.type) }
        return inferValue(node, context, expected: param.type)
    }

    // MARK: - Plans

    func planArguments(_ signature: Signature, _ arguments: [ArgumentSyntax], _ context: ExprContext) -> ArgumentPlan {
        var plan = ArgumentPlan()
        let params = signature.params
        var positional: [Int] = []
        for (i, argument) in arguments.enumerated() {
            if let label = argument.label?.name {
                if let p = params.firstIndex(where: { $0.label == label }) {
                    if plan.assignments[p] == nil { plan.assignments[p] = [i] }
                    else if params[p].variadic { plan.assignments[p]!.append(i) }
                } else {
                    plan.unknownLabels.append(i)
                }
            } else {
                positional.append(i)
            }
        }
        let positionalParams = params.indices.filter { params[$0].label == nil }
        if let variadic = positionalParams.first(where: { params[$0].variadic }) {
            let before = positionalParams.filter { $0 < variadic }
            var k = 0
            for p in before where k < positional.count { plan.assignments[p] = [positional[k]]; k += 1 }
            if k < positional.count { plan.assignments[variadic] = Array(positional[k...]) }
            else if params[variadic].required { plan.missing.append(variadic) }
        } else {
            let required = positionalParams.filter { params[$0].required }
            let optional = positionalParams.filter { !params[$0].required }
            let firstRequired = required.first ?? Int.max
            let lastRequired = required.last ?? -1
            let leading = optional.filter { $0 < firstRequired }
            let trailing = optional.filter { $0 > lastRequired || required.isEmpty }
            let n = positional.count
            var k = n - required.count
            var next = 0
            if k < 0 {
                for (j, p) in required.enumerated() {
                    if j < n { plan.assignments[p] = [positional[j]] } else { plan.missing.append(p) }
                }
                next = n
            } else {
                let lf = min(k, leading.count)
                for j in 0..<lf { plan.assignments[leading[j]] = [positional[next]]; next += 1 }
                k -= lf
                for p in required { plan.assignments[p] = [positional[next]]; next += 1 }
                // The rest go to the trailing optional parameters, each by its type (D117).
                var free = trailing
                while next < n {
                    let argument = arguments[positional[next]]
                    guard !free.isEmpty else { plan.extraPositional.append(positional[next]); next += 1; continue }
                    var target = free[0]
                    if free.count > 1 {
                        for p in free {
                            let val = speculate { infer(argument.value.node, argumentContext(context, params[p], .function(Checker.dummyFunction)), expected: params[p].type) }
                            if cost(val, params[p]) != nil { target = p; break }
                        }
                    }
                    if plan.assignments[target] != nil {
                        plan.extraPositional.append(positional[next])
                    } else {
                        plan.assignments[target] = [positional[next]]
                    }
                    free.removeAll { $0 == target }
                    next += 1
                }
            }
        }
        for (p, param) in params.enumerated() where param.label != nil && param.required && plan.assignments[p] == nil {
            plan.missing.append(p)
        }
        return plan
    }

    static let dummyFunction = FunctionSpec(name: "", kind: .function, title: LocalizedText("", ""), signatures: [], pure: true,
                                            doc: Doc(en: "", zh: "", example: ""))

    // MARK: - Costs

    /// The cost of passing `v` to `param` (0 exact, 1 a catalog conversion, 2 a literal or base adoption, 3 a Json or
    /// missing value converted at run time), or nil when it does not fit.
    func cost(_ v: Val, _ param: ParamSpec) -> Int? {
        if param.role == .display {
            if case .list = v.type { return nil }
            return v.type == .string ? 0 : 1
        }
        if [.elementName, .styleRef, .declaresElementName].contains(param.role) { return 0 }
        return cost(v, param.type)
    }

    func cost(_ v: Val, _ t: DeskType) -> Int? {
        if v.error { return 0 }
        if let slot = v.open, slot < openSlots.count { return openFits(openSlots[slot].kind, t) ? 2 : nil }
        if v.namespace != nil || v.component != nil || v.qualifier != nil { return nil }
        if v.isJson && t != .json { return 3 }
        switch t {
        case .any, .typeVar: return 0
        case .oneOf(let ts): return ts.compactMap { cost(v, $0) }.min()
        case .binding(let inner):
            guard let bind = v.bind else { return nil }
            switch bind {
            case .variable, .saved, .option, .settableData: return cost(v, inner)
            default: return nil
            }
        case .number(let d):
            if v.type == .anyNumber { return 1 }
            guard let vd = v.dimension else { return nil }
            if vd == d { return v.adoptsBase ? 2 : 0 }
            if vd == .plain {
                if v.plainLiteral != nil { return 2 }
                if d == .length { return 1 }
                if d == .angle { return 2 }
                return nil
            }
            return nil
        case .anyNumber:
            return v.isNumber ? 0 : nil
        case .fraction:
            if v.dimension == .percent { return 1 }
            if v.dimension == .plain { return 1 }
            return nil
        case .string:
            return v.type.isStringLike ? (v.type == .string ? 0 : 1) : nil
        case .color:
            if v.type == .color { return 0 }
            if v.stringLiteral != nil { return 1 }
            return nil
        case .paint:
            if v.type == .paint { return 0 }
            if v.type == .color { return 1 }
            if v.stringLiteral != nil { return 1 }
            return nil
        case .symbolName, .imageSource, .fontFamily, .folderPath:
            if v.type == t { return 0 }
            if v.type == .string { return 1 }
            if t == .imageSource && v.type == .imageSource { return 0 }
            return nil
        case .bool, .date, .size, .json, .secret, .elementName, .styleRef:
            return v.type == t ? 0 : nil
        case .enumeration(let id):
            if case .enumeration(let vid) = v.type { return vid == id ? 0 : nil }
            return nil
        case .record(let id):
            if case .record(let vid) = v.type { return vid == id ? 0 : nil }
            return nil
        case .list(let e):
            guard case .list(let ve) = v.type else { return nil }
            if ve == .any { return 1 }
            var element = Val(ve)
            element.error = false
            if v.isConstant, case .number(.plain) = ve { element.plainLiteral = 0 }
            return cost(element, e)
        case .lengthSpec:
            if v.dimension == .length || v.dimension == .plain { return 0 }
            if v.type == .enumeration("LengthKeyword") { return 0 }
            return nil
        }
    }

    func isBindable(_ v: Val) -> Bool {
        switch v.bind {
        case .variable?, .saved?, .option?, .settableData?: return true
        default: return false
        }
    }

    func isComparisonOrLogic(_ node: PositionedNode) -> Bool {
        guard node.kind == .binaryExpr else { return false }
        let k = BinaryExprSyntax(unchecked: node).operator.kind
        return [.less, .lessEqual, .greater, .greaterEqual, .equalEqual, .bangEqual, .andKeyword, .orKeyword].contains(k)
    }

    /// Whether an open value (settled by use) can stand where `t` is expected.
    func openFits(_ kind: OpenSlot.Kind, _ t: DeskType) -> Bool {
        switch t {
        case .any, .typeVar: return true
        case .oneOf(let ts): return ts.contains { openFits(kind, $0) }
        case .binding(let inner): return openFits(kind, inner)
        case .number(let d): return kind == .dimension || (kind == .base && (d == .bytes || d == .bytesPerSecond))
        case .anyNumber, .fraction, .lengthSpec: return kind == .dimension || kind == .base
        case .enumeration, .color, .paint: return kind == .type
        default: return false
        }
    }

    // MARK: - Coercion

    /// Checks that `v` can stand where `type` is expected, reporting DK4001 (or a targeted diagnostic) when it cannot.
    @discardableResult
    func coerce(_ v: Val, _ node: PositionedNode, to type: DeskType, what: DiagnosticArgument, _ context: ExprContext,
                range allowed: ClosedRange<Double>? = nil, param: ParamSpec? = nil) -> Bool {
        if v.error { return true }
        let r = range(node)
        if let slot = v.open, slot < openSlots.count, openFits(openSlots[slot].kind, type) {
            recordUse(slot, expected: type, at: r, description: usedAs(param: param, type: type, what: what))
            return true
        }
        if v.secret, let role = param?.role, ![.command, .webAddress].contains(role) {
            report(.secretShown, r)
            return false
        }
        if param?.role == .display {
            if case .list = v.type {
                let t = text(node)
                report(.notDisplayable, r, ["text": .code(t), "type": .type(v.type), "hint": hintText(.notDisplayable, "joinList"),
                                           "fixed": .code(t + ".joined(\", \")")],
                       fixIts: [fix("append", [edit(r.upperBound..<r.upperBound, ".joined(\", \")")], ["text": .code(".joined(\", \")")])])
                return false
            }
            return true
        }
        if let param, [.elementName, .styleRef, .declaresElementName].contains(param.role) { return true }
        if v.isJson { return true }
        // Quoted choices: `.font("headline")`, `size: "small"` (checked before fonts and colors).
        if let s = v.stringLiteral, reportQuotedChoice(node, s, expected: type) { return false }
        // Colors from text.
        if let s = v.stringLiteral, type == .color || type == .paint || (type.components.contains(.color)) {
            if cost(v, type) != nil && (v.type == .string) { return checkColorLiteral(s, node) }
        }
        // Lengths written as text: `.padding("18px")`.
        if let s = v.stringLiteral, isLengthType(type), let number = Checker.lengthInText(s) {
            report(.lengthAsText, r, ["number": .code(number)], fixIts: [fix("replace", [edit(r, number)])])
            return false
        }
        if case .binding(let inner) = type, !isBindable(v) {
            let kind: String
            switch v.bind {
            case .computed?: kind = "kind:computed"
            case .loopVariable?: kind = "kind:loopVariable"
            case .readOnlyData?: kind = "kind:readOnlyData"
            case .event?: kind = "kind:event"
            default:
                if node.kind == .binaryExpr, isComparisonOrLogic(node) { kind = "kind:comparison" }
                else if v.isConstant { kind = "kind:literal" }
                else { kind = "kind:expression" }
            }
            _ = inner
            report(.notBindable, r, ["kind": .name(kind)])
            return false
        }
        guard let c = cost(v, type) else {
            reportTypeMismatch(v, node, expected: type, what: what, param: param, context)
            return false
        }
        _ = c
        if param?.role == .pathData { checkPathData(node, v) }
        if param?.role == .pattern, let pattern = v.stringLiteral {
            do { _ = try NSRegularExpression(pattern: pattern) } catch {
                report(.invalidPattern, range(node), ["reason": .text(Checker.regexReason(pattern))])
                return false
            }
        }
        // Plain literals where the unit must be written; plain values used as angles.
        if case .number(let d) = type, v.dimension == .plain {
            if v.plainLiteral != nil && d.needsWrittenUnit { reportUnitNeeded(node, dimension: d); return false }
            if d == .angle && v.plainLiteral == nil { reportUnitNeeded(node, dimension: .angle); return false }
        }
        if case .oneOf(let types) = type, v.dimension == .plain, v.plainLiteral != nil,
           let d = types.compactMap({ t -> Dimension? in if case .number(let x) = t { return x }; return nil }).first,
           d.needsWrittenUnit, !types.contains(.number(.plain)) {
            reportUnitNeeded(node, dimension: d)
            return false
        }
        // Fractions: a plain literal above 1 (DK4013).
        if type == .fraction, v.dimension == .plain, let value = v.plainLiteral ?? v.literalValue, value > 1 {
            reportFractionOver1(node, what: what, value: value)
            return true
        }
        // Bindings.
        if case .binding(let inner) = type {
            if case .option(let name) = v.bind, let option = options[name], option.userOnly {
                report(.userOnlyOption, r, ["name": .code("options.\(name)")])
                return false
            }
            _ = inner
        }
        // Ranges and whole numbers of literals.
        let literal = v.plainLiteral ?? v.literalValue
        let timingValue = v.dimension == .time && ["interval", "delay", "every", "refresh"].contains(param?.name ?? "")
        if let value = literal, let allowed, v.isConstant, !timingValue {
            var shown = value
            if v.dimension == .percent, param?.unit == "%" || type == .fraction { shown = value }
            if !allowed.contains(shown) {
                let clamped = min(max(shown, allowed.lowerBound), allowed.upperBound)
                report(.outOfRange, r, ["what": what, "min": .code(Checker.numberText(allowed.lowerBound)),
                                        "max": .code(Checker.numberText(allowed.upperBound))],
                       fixIts: [fix("clamp", [edit(r, Checker.numberText(clamped) + (v.literalUnit ?? ""))])])
                return false
            }
        }
        if param?.wholeNumber == true, let value = literal, value != value.rounded() {
            report(.notWholeNumber, r, ["what": what], fixIts: [fix("round", [edit(r, Checker.numberText(value.rounded()))])])
            return false
        }
        // Literal files, symbols and fonts.
        if let s = v.stringLiteral {
            switch type {
            case .symbolName: checkSymbol(s, node)
            case .imageSource: checkFile(s, node, kind: "image")
            case .fontFamily: checkFont(s, node)
            default: break
            }
        }
        return true
    }

    func isLengthType(_ t: DeskType) -> Bool {
        switch t {
        case .number(.length), .lengthSpec: return true
        case .oneOf(let ts): return ts.contains { isLengthType($0) }
        default: return false
        }
    }

    /// `"18px"`, `"18"`, `"18pt"` → `18`.
    static func lengthInText(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var digits = trimmed
        for suffix in ["px", "pt"] where digits.hasSuffix(suffix) { digits = String(digits.dropLast(suffix.count)) }
        digits = digits.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, Double(digits) != nil else { return nil }
        return digits
    }

    /// DK4045: a built-in choice in quotes.
    @discardableResult
    func reportQuotedChoice(_ node: PositionedNode, _ s: String, expected: DeskType) -> Bool {
        guard Checker.isIdentifier(s) else { return false }
        var candidates: [String] = []
        switch expected {
        case .enumeration(let id):
            if catalog.enumeration(id)?.enumCase(named: s) != nil { candidates.append(s) }
            if let lower = catalog.enumeration(id)?.cases.first(where: { $0.name.lowercased() == s.lowercased() }) {
                candidates.append(lower.name)
            }
        case .oneOf(let types):
            for t in types {
                if case .enumeration(let id) = t, let c = catalog.enumeration(id)?.cases.first(where: { $0.name.lowercased() == s.lowercased() }) {
                    candidates.append(c.name)
                }
            }
        default:
            return false
        }
        guard let name = candidates.first else { return false }
        let r = range(node)
        report(.quotedChoice, r, ["text": .code(name)], fixIts: [fix("replaceWith", [edit(r, "." + name)], ["text": .code("." + name)])])
        return true
    }

    /// DK4016: `"#FF6B0"`, `"255,255,255"`, `"FF6B00"`, `"red"`.
    func checkColorLiteral(_ s: String, _ node: PositionedNode) -> Bool {
        let r = range(node)
        let hex = Set("0123456789abcdefABCDEF")
        if s.hasPrefix("#") {
            let digits = s.dropFirst()
            if [3, 6, 8].contains(digits.count), digits.allSatisfy({ hex.contains($0) }) { return true }
        }
        var fixIts: [FixIt] = []
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 3 || parts.count == 4, let values = Optional(parts.compactMap { Int($0) }), values.count == parts.count,
           values.allSatisfy({ (0...255).contains($0) }) {
            var hexText = "#" + values.prefix(3).map { String(format: "%02X", $0) }.joined()
            if values.count == 4 { hexText += String(format: "%02X", values[3]) }
            fixIts.append(fix("convert", [edit(r, "\"\(hexText)\"")], ["text": .code("\"\(hexText)\"")]))
            let rgb = "rgb(\(values[0]), \(values[1]), \(values[2]))"
            fixIts.append(fix("convert", [edit(r, rgb)], ["text": .code(rgb)]))
        } else if [6, 8].contains(s.count), s.allSatisfy({ hex.contains($0) }) {
            fixIts.append(fix("convert", [edit(r, "\"#\(s)\"")], ["text": .code("\"#\(s)\"")]))
        } else {
            let names = catalog.namedValues.filter { $0.type == "Color" }.map(\.name)
            let suggestion = DidYouMean.suggest(s, candidates: names)
            if let best = suggestion.names.first {
                fixIts.append(fix("didYouMean", [edit(r, "." + best)], ["text": .code("." + best)]))
            }
        }
        report(.invalidColor, r, ["text": .code(s)], fixIts: fixIts)
        return false
    }

    /// DK4001 with the targeted mix-ups of §4.5 (D96).
    func reportTypeMismatch(_ v: Val, _ node: PositionedNode, expected type: DeskType, what: DiagnosticArgument,
                            param: ParamSpec?, _ context: ExprContext) {
        let r = range(node)
        var fixIts: [FixIt] = []
        // `.width(100%)`.
        if isLengthType(type), v.dimension == .percent, let value = v.literalValue {
            if value == 100, type == .lengthSpec || type.components.contains(.lengthSpec) {
                fixIts.append(fix("convert", [edit(r, ".fill")], ["text": .code(".fill")]))
            }
        }
        // A number where text is expected: add quotes.
        if type.isStringLike || type == .string, v.isNumber, v.isConstant {
            fixIts.append(fix("addQuotes", [edit(r, "\"\(text(node))\"")]))
        }
        // 1 or 0 where yes or no is expected.
        if type == .bool || type == .binding(.bool), let value = v.plainLiteral, value == 1 || value == 0 {
            let word = value == 1 ? "true" : "false"
            fixIts.append(fix("convert", [edit(r, word)], ["text": .code(word)]))
        }
        // A percentage where an angle is expected: x * 360°.
        if case .number(.angle) = type, v.dimension == .percent {
            let fixed = "\(text(node)) * 360°"
            fixIts.append(fix("convert", [edit(r, fixed)], ["text": .code(fixed)]))
        }
        report(.typeMismatch, r, ["what": what, "expected": .type(type), "actual": .type(v.type)], fixIts: fixIts)
    }

    /// The display name of what a parameter sets or means, for messages.
    func whatName(_ param: ParamSpec, owner: CallOwner, callee: String) -> DiagnosticArgument {
        if let facet = param.facets.first, catalog.facet(facet) != nil { return .name("facet:\(facet)") }
        switch owner {
        case .component(let c): return .name("component:\(c.name)")
        case .control(let c): return .code(c.name)
        case .modifier(let m): return .code("." + m.name)
        default: return .code(callee)
        }
    }

    /// How a use settles an open value ("used as a text size").
    func usedAs(param: ParamSpec?, type: DeskType, what: DiagnosticArgument) -> LocalizedText {
        let name = catalog.displayName(for: type)
        return LocalizedText("used as \(name.en)", "用作\(name.zh)")
    }

    // MARK: - Label mix-ups (D132)

    func reportUnknownLabels(_ indices: [Int], _ arguments: [ArgumentSyntax], signature: Signature, calleeName: String,
                             callRange: Range<Int>, clause: ArgumentClauseSyntax?, _ context: ExprContext) {
        let labels = signature.params.compactMap(\.label)
        let positionalNames = Set(signature.params.filter { $0.label == nil }.map(\.name))
        for i in indices {
            let argument = arguments[i]
            guard let label = argument.label else { continue }
            let name = label.name
            let labelRange = range(label.node)
            // Foreign labels: `alignment:` → `align:`, `isOn:` → the value itself.
            if let row = index.foreignRows(name + ":").first {
                reportForeignLabel(row, argument: argument, name: name)
                continue
            }
            if requiresNewer != nil {
                report(.newerName, labelRange, ["name": .code(name + ":"), "version": .code(requiresNewer!.description)])
                continue
            }
            var arguments: [String: DiagnosticArgument] = ["component": .code(calleeName), "label": .code(name)]
            var fixIts: [FixIt] = []
            if name == "else", let clauseNode = clause?.node {
                // `.color(.red, if: hot, else: .green)` → `.color(.green).color(.red, if: hot)`.
                let elseValue = text(argument.value.node)
                let others = (clause?.arguments ?? []).filter { $0.node.range != argument.node.range }.map { text($0.node) }
                let fixed = "\(calleeName)(\(elseValue))\(calleeName)(\(others.joined(separator: ", ")))"
                arguments["hint"] = hintText(.unknownLabel, "elseLabel")
                arguments["fixed"] = .code(fixed)
                let full = callRangeIncludingName(clauseNode, calleeName: calleeName)
                fixIts.append(fix("rewrite", [edit(full, fixed)]))
            } else if positionalNames.contains(name) || (labels.isEmpty && !signature.params.isEmpty) {
                // Labels on positional parameters: remove them.
                let all = clause?.arguments ?? []
                let fixed = calleeName + "(" + all.map { text($0.value.node) }.joined(separator: ", ") + ")"
                arguments["hint"] = hintText(.unknownLabel, "noLabelsNeeded")
                arguments["fixed"] = .code(fixed)
                var edits: [TextEdit] = []
                for a in all where a.label != nil && positionalNames.contains(a.label!.name) {
                    let start = textStart(a.node)
                    edits.append(edit(start..<textStart(a.value.node), ""))
                }
                fixIts.append(fix("removeLabels", edits))
            } else if labels.isEmpty {
                arguments["hint"] = hintText(.unknownLabel, "noLabels")
            } else {
                arguments["hint"] = hintText(.unknownLabel, "takes")
                arguments["labels"] = .list(labels.map { .code($0 + ":") }, joiner: .and)
                let suggestion = DidYouMean.suggest(name, candidates: labels)
                if let best = suggestion.names.first, suggestion.fixable {
                    fixIts.append(fix("didYouMean", [edit(labelRange, best)], ["text": .code(best + ":")]))
                }
            }
            report(.unknownLabel, labelRange, arguments, fixIts: fixIts)
        }
    }

    /// The range from the callee's dot or name to the closing parenthesis of `clause`.
    func callRangeIncludingName(_ clause: PositionedNode, calleeName: String) -> Range<Int> {
        let r = range(clause)
        let start = max(0, r.lowerBound - calleeName.utf8.count)
        return start..<r.upperBound
    }

    func reportTooManyArguments(_ extra: [Int], _ arguments: [ArgumentSyntax], signature: Signature, plan: ArgumentPlan,
                                calleeName: String, callRange: Range<Int>, clause: ArgumentClauseSyntax?,
                                _ context: ExprContext, owner: CallOwner) {
        let positionalCount = signature.params.filter { $0.label == nil }.count
        let firstExtra = arguments[extra[0]]
        let r = range(firstExtra.node)
        var args: [String: DiagnosticArgument] = ["name": .code(calleeName), "count": .number(positionalCount)]
        var fixIts: [FixIt] = []
        // `Line(cpu.usage)`: Rainmeter's Line meter is `Graph`.
        if calleeName == "Line", case .component = owner, let clauseNode = clause?.node {
            args["hint"] = hintText(.tooManyArguments, "lineMeter")
            let fixed = "Graph" + text(clauseNode)
            args["fixed"] = .code(fixed)
            fixIts.append(fix("replaceWith", [edit(callRangeIncludingName(clauseNode, calleeName: "Line"), fixed)], ["text": .code(fixed)]))
            report(.tooManyArguments, r, args, fixIts: fixIts)
            return
        }
        // Three or four numbers given to a color: `rgb(…)`.
        let colorParam = signature.params.first { $0.type == .color || $0.type == .paint }
        let allArgs = clause?.arguments ?? []
        if colorParam != nil, (3...4).contains(allArgs.count), allArgs.allSatisfy({ $0.label == nil && $0.value.node.kind == .numberLiteral }) {
            let inside = allArgs.map { text($0.value.node) }.joined(separator: ", ")
            let fixed = "rgb(\(inside))"
            args["hint"] = hintText(.tooManyArguments, "colorNumbers")
            args["fixed"] = .code(fixed)
            let start = textStart(allArgs.first!.node), end = range(allArgs.last!.node).upperBound
            fixIts.append(fix("replaceWith", [edit(start..<end, fixed)], ["text": .code(fixed)]))
            report(.tooManyArguments, r, args, fixIts: fixIts)
            return
        }
        // An extra value that fits exactly one unfilled labelled parameter: add the label.
        let unfilled = signature.params.indices.filter { signature.params[$0].label != nil && plan.assignments[$0] == nil }
        let valueNode = firstExtra.value.node
        // A range where min: and max: are expected.
        if valueNode.kind == .rangeExpr, unfilled.contains(where: { signature.params[$0].label == "min" }),
           unfilled.contains(where: { signature.params[$0].label == "max" }) {
            let rangeExpr = RangeExprSyntax(unchecked: valueNode)
            let fixed = "min: \(text(rangeExpr.low.node)), max: \(text(rangeExpr.high.node))"
            args["hint"] = hintText(.tooManyArguments, "addLabel")
            args["fixed"] = .code(fixed)
            fixIts.append(fix("insert", [edit(range(valueNode), fixed)], ["text": .code(fixed)]))
            report(.tooManyArguments, r, args, fixIts: fixIts)
            return
        }
        var fitting: [ParamSpec] = []
        for p in unfilled {
            let param = signature.params[p]
            let val = speculate { infer(valueNode, argumentContext(context, param, owner), expected: param.type) }
            if !val.error, cost(val, param) != nil, cost(val, param)! <= 1 || param.type == .bool { fitting.append(param) }
        }
        if fitting.count == 1, let label = fitting[0].label {
            let fixed = "\(label): \(text(valueNode))"
            args["hint"] = hintText(.tooManyArguments, "addLabel")
            args["fixed"] = .code(fixed)
            fixIts.append(fix("insert", [edit(textStart(valueNode)..<textStart(valueNode), label + ": ")], ["text": .code(label + ":")]))
        } else {
            args["hint"] = .text(LocalizedText("", ""))
            args["fixed"] = .code("")
            fixIts.append(fix("removeExtra", [edit(argumentRemovalRange(firstExtra, in: clause?.arguments ?? []), "")]))
        }
        report(.tooManyArguments, r, args, fixIts: fixIts)
    }

    func reportMissingArgument(_ param: ParamSpec, calleeName: String, clause: ArgumentClauseSyntax?,
                               callRange: Range<Int>, emptyCall: Bool = false) {
        let preview = param.previewValue ?? defaultInsertValue(param)
        let insertText = param.label.map { "\($0): \(preview)" } ?? preview
        var edits: [TextEdit] = []
        var r = callRange
        if let clause {
            let close = clause.rParen.textRange.lowerBound
            let hasArguments = !clause.arguments.isEmpty
            let insert = hasArguments ? ", " + insertText : insertText
            if clause.rParen.token.isMissing {
                edits.append(edit(close..<close, insert + ")"))
            } else {
                edits.append(edit(close..<close, insert))
            }
            r = range(clause.node)
        } else {
            edits.append(edit(callRange.upperBound..<callRange.upperBound, "(" + insertText + ")"))
        }
        let what: DiagnosticArgument = param.label.map { .code($0 + ":") } ?? .type(param.type)
        report(.missingArgument, emptyCall ? r : r, ["name": .code(calleeName), "what": what],
               fixIts: [fix("insert", edits, ["text": .code(insertText)])])
    }

    func defaultInsertValue(_ param: ParamSpec) -> String {
        switch param.type {
        case .string, .symbolName, .imageSource, .fontFamily, .folderPath: return "\"\""
        case .bool: return "true"
        case .enumeration(let id): return "." + (catalog.enumeration(id)?.cases.first?.name ?? "")
        case .color, .paint: return ".accent"
        default:
            if case .number(let d) = param.type, d.needsWrittenUnit, let unit = d.canonicalUnit { return "1" + unit }
            return "0"
        }
    }

    /// The range that removes one argument and one of its commas.
    func argumentRemovalRange(_ argument: ArgumentSyntax, in all: [ArgumentSyntax]) -> Range<Int> {
        let r = range(argument.node)
        guard let i = all.firstIndex(where: { $0.node.range == argument.node.range }) else { return r }
        if i > 0 { return range(all[i - 1].node).upperBound..<r.upperBound }
        if i + 1 < all.count { return r.lowerBound..<textStart(all[i + 1].node) }
        return r
    }

    func reorderFix(_ arguments: [ArgumentSyntax]) -> FixIt {
        let positional = arguments.filter { $0.label == nil }.map { text($0.node) }
        let labeled = arguments.filter { $0.label != nil }.map { text($0.node) }
        let start = textStart(arguments.first!.node), end = range(arguments.last!.node).upperBound
        return fix("reorder", [edit(start..<end, (positional + labeled).joined(separator: ", "))])
    }
}
