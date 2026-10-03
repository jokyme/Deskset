import Foundation

// Settling by use (§4.3, D93, D100, D134): a declaration or option whose initializer leaves its dimension, display
// base or type open takes it from how it is used. Uses that meet another open value link the two; they settle
// together. Uses that disagree are DK4041 (DK4042 for a display base only); a type no use decides is DK3018 for a
// declaration and a local enum (with DK3032) for a Picker.

extension Checker {
    func activeOpenSlot(_ slot: Int?) -> Int? { openSlotsSettled ? nil : slot }

    /// A base slot leaves the dimension known; only dimension/type slots defer the algebra.
    func hasOpenDimension(_ value: Val) -> Bool {
        guard let slot = value.open, slot < openSlots.count else { return false }
        return openSlots[slot].kind != .base
    }

    func recordNumericValue(_ value: Val, _ node: PositionedNode) {
        guard mute == 0, value.isNumber, !value.error else { return }
        let key = id(node)
        numericValues[key] = value
        numericNodes[key] = node
        if let slot = value.open { numericSlots[key] = slot }
        if value.dimension == .bytes || value.dimension == .bytesPerSecond {
            var inputs: [PositionedNode] = []
            switch node.kind {
            case .parenExpr: inputs = [ParenExprSyntax(unchecked: node).value.node]
            case .prefixExpr: inputs = [PrefixExprSyntax(unchecked: node).operand.node]
            case .binaryExpr:
                let binary = BinaryExprSyntax(unchecked: node)
                inputs = [binary.left.node, binary.right.node]
            case .ternaryExpr:
                let ternary = TernaryExprSyntax(unchecked: node)
                inputs = [ternary.then.node, ternary.otherwise.node]
            case .callExpr:
                let call = CallExprSyntax(unchecked: node)
                let name = text(call.callee.node).split(separator: ".").last.map(String.init)
                if let name, ["min", "max", "clamp", "ifMissing", "round", "floor", "ceil", "abs"].contains(name) {
                    inputs = Array(node.childNodes)
                }
            default: break
            }
            var sources: [NodeID] = []
            func collect(_ child: PositionedNode) {
                let childID = id(child)
                if let value = numericValues[childID] {
                    if value.dimension == .bytes || value.dimension == .bytesPerSecond { sources.append(childID) }
                    return
                }
                for nested in child.childNodes { collect(nested) }
            }
            for input in inputs { collect(input) }
            numericBaseSources[key] = sources
        }
    }

    /// Preserve the originally confirmed constant while recording the type/base chosen at this use.
    func recordNumericAdoption(_ value: Val, _ node: PositionedNode) {
        guard mute == 0, var original = numericValues[id(node)] else { return }
        original.type = value.type
        original.base = value.base
        original.error = value.error
        numericValues[id(node)] = original
    }

    func recordPercentAsFraction(_ value: Val, _ node: PositionedNode) {
        guard mute == 0, !value.error, value.dimension == .percent else { return }
        var converted = value
        converted.type = .number(.plain)
        recordNumericAdoption(converted, node)
        numericCoercions[id(node)] = .percentAsFraction
    }

    func recordNumericCoercion(_ value: Val, _ node: PositionedNode, to expected: DeskType) {
        guard mute == 0, !value.error else { return }
        if expected == .fraction, value.dimension == .percent {
            recordPercentAsFraction(value, node)
        } else if case .number(let dimension) = expected, dimension != .plain,
                  !dimension.needsWrittenUnit, value.plainLiteral != nil {
            var adopted = value
            adopted.type = .number(dimension)
            recordNumericAdoption(adopted, node)
        }
    }

    func bindNumericSlot(_ slot: Int, to node: PositionedNode) {
        guard mute == 0, slot < openSlots.count else { return }
        let key = id(node)
        var visited = Set<NodeID>()
        func link(_ key: NodeID) {
            guard visited.insert(key).inserted else { return }
            if let other = numericSlots[key], other != slot {
                openSlots[slot].links.append(other)
                openSlots[other].links.append(slot)
            }
            if openSlots[slot].kind == .base {
                for source in numericBaseSources[key] ?? [] { link(source) }
            }
        }
        link(key)
        if numericValues[key] != nil { numericSlots[key] = slot }
    }

    /// Finish only relations explicitly deferred by the original inference. Nested relations were recorded
    /// first, so their confirmed values/adoptions are available to the enclosing operation/assignment.
    private func completeDeferredNumericUses() {
        func resolved(_ original: Val, at node: PositionedNode? = nil) -> Val? {
            var value = node.flatMap { numericValues[id($0)] } ?? original
            if value.error { return nil }
            if let slot = value.open, slot < openSlots.count {
                let open = openSlots[slot]
                if case .declaration(let decl) = open.owner, decl.poisoned { return nil }
                if open.kind == .dimension, let type = open.settled { value.type = type }
                if let base = open.settledBase { value.base = base }
            }
            value.open = nil
            if let node, numericCoercions[id(node)] == .percentAsFraction { value.type = .number(.plain) }
            return value
        }
        func hasError(_ node: PositionedNode) -> Bool {
            diagnostics.contains { $0.severity == .error && $0.range.overlaps(range(node)) }
        }
        for use in deferredNumericUses {
            switch use {
            case .arithmetic(let op, let leftNode, let rightNode, let node, let left, let right):
                guard !hasError(node), let l = resolved(left, at: leftNode), let r = resolved(right, at: rightNode) else { continue }
                let value = arithmeticValues(op, leftNode, rightNode, node, left: l, right: r)
                let key = id(node)
                if value.error {
                    numericValues.removeValue(forKey: key)
                    types.removeValue(forKey: key)
                    numericCoercions.removeValue(forKey: key)
                } else { numericValues[key] = value }
            case .assignment(let node, let target, let original, let what, let context):
                guard !hasError(node), let target = resolved(target), let value = resolved(original, at: node) else { continue }
                _ = coerce(value, node, to: target.type, what: what, context)
            }
        }
    }

    /// Materialize only facts/relations recorded by inference. No names or expressions are inferred again.
    func completeNumericMetadata() {
        // Slider/Stepper slots are opened by the option checker after their arguments have been checked.
        for slot in openSlots.indices {
            guard case .option = openSlots[slot].owner, openSlots[slot].kind == .dimension else { continue }
            for literal in openSlots[slot].literals {
                for (key, node) in numericNodes where range(node) == literal.range { numericSlots[key] = slot }
            }
        }
        let originalValues = numericValues
        var values = originalValues
        for key in values.keys {
            guard var value = values[key] else { continue }
            if let slot = numericSlots[key], slot < openSlots.count {
                let open = openSlots[slot]
                if case .declaration(let decl) = open.owner, decl.poisoned { values.removeValue(forKey: key); continue }
                if open.kind == .dimension, let settled = open.settled { value.type = settled }
                if let base = open.settledBase { value.base = base }
            }
            if numericCoercions[key] == .percentAsFraction { value.type = .number(.plain) }
            if value.error { values.removeValue(forKey: key) } else { values[key] = value }
        }
        // A chosen expression/declaration base reaches only its still-open byte operands, not fixed KiB or data.
        func supplyBase(_ key: NodeID, _ base: Int, _ visited: inout Set<NodeID>) {
            guard visited.insert(key).inserted else { return }
            for child in numericBaseSources[key] ?? [] {
                guard var value = values[child], value.adoptsBase, value.base == nil else { continue }
                value.base = base
                values[child] = value
                supplyBase(child, base, &visited)
            }
        }
        for (key, value) in values {
            guard let base = value.base else { continue }
            var visited = Set<NodeID>()
            supplyBase(key, base, &visited)
        }
        var resolvedBases = Set<NodeID>(), resolvingBases = Set<NodeID>()
        func resolveBase(_ key: NodeID) -> Int? {
            guard var value = values[key] else { return nil }
            if resolvedBases.contains(key) { return value.base }
            guard resolvingBases.insert(key).inserted else { return nil }
            defer { resolvingBases.remove(key); resolvedBases.insert(key) }
            if value.base == nil, value.dimension == .bytes || value.dimension == .bytesPerSecond {
                for child in numericBaseSources[key] ?? [] {
                    if let base = resolveBase(child) { value.base = base; break }
                }
                if value.base == nil, value.adoptsBase || numericNodes[key]?.kind == .numberLiteral { value.base = 1000 }
            }
            values[key] = value
            return value.base
        }
        for key in values.keys { _ = resolveBase(key) }
        numericValues = values
        completeDeferredNumericUses()
        values = numericValues
        for (key, original) in originalValues {
            guard let value = values[key] else {
                types.removeValue(forKey: key)
                numericCoercions.removeValue(forKey: key)
                continue
            }
            types[key] = SemType(type: value.type, displayBase: value.base, range: original.range)
        }
        var resolvingConstants = Set<NodeID>()
        let poisonedInitializers = declOrder.filter(\.poisoned).map { range(DeclarationSyntax(unchecked: $0.node).initializer.node) }
        func constant(_ key: NodeID) -> Double? {
            if let found = canonicalNumericValues[key] { return found }
            guard let value = values[key], value.isConstant, let node = numericNodes[key],
                  resolvingConstants.insert(key).inserted else { return nil }
            defer { resolvingConstants.remove(key) }
            guard !poisonedInitializers.contains(where: { $0.overlaps(node.textRange) }),
                  !diagnostics.contains(where: { $0.severity == .error && $0.range.overlaps(node.textRange) }) else { return nil }
            var result: Double?
            if node.kind == .numberLiteral {
                result = value.literalValue ?? value.plainLiteral
                let literal = NumberLiteralSyntax(unchecked: node)
                if let written = literal.unit, let number = literal.value,
                   let unit = catalog.unit(spelling: value.literalUnit ?? written.text), result != nil {
                    result = number * unit.factor(base: value.base ?? 1000)
                        + (value.dimension == .temperatureDelta ? 0 : unit.offset)
                }
            } else if node.kind == .binaryExpr {
                // Only the existing plain arithmetic fold confirms a binary result. Other paths can
                // retain an operand's literalValue while deciding types (including temperature hints).
                result = value.plainLiteral
            } else if node.kind == .parenExpr {
                result = constant(id(ParenExprSyntax(unchecked: node).value.node))
            } else if node.kind == .prefixExpr {
                let prefix = PrefixExprSyntax(unchecked: node)
                guard prefix.operator.kind == .minus else { return nil }
                let operand = prefix.operand.node
                result = constant(id(operand)).map { -$0 }
                if let literal = NumberLiteralSyntax(operand), let written = literal.unit, let number = literal.value,
                   let unit = catalog.unit(spelling: written.text), result != nil {
                    result = -number * unit.factor(base: value.base ?? 1000)
                        + (value.dimension == .temperatureDelta ? 0 : unit.offset)
                }
            } else {
                // Inference can carry a branch or argument value without selecting/folding it.
                return nil
            }
            if numericCoercions[key] == .percentAsFraction { result = result.map { $0 / 100 } }
            guard let result, result.isFinite else { return nil }
            canonicalNumericValues[key] = result
            return result
        }
        for key in values.keys { _ = constant(key) }
        for decl in declOrder where !decl.poisoned {
            let key = id(DeclarationSyntax(unchecked: decl.node).initializer.node)
            if let value = values[key] {
                decl.val?.type = value.type
                decl.val?.base = value.base
                decl.val?.open = nil
            }
        }
    }

    /// Opens a slot when an initializer leaves part of its type open.
    func openSlot(for initializer: PositionedNode, val: Val, owner: OpenSlot.Owner) -> Int? {
        var kind: OpenSlot.Kind?
        var candidates: [String] = []
        var memberName: String?
        var memberRange: Range<Int>?
        if val.plainLiteral != nil, val.dimension == .plain {
            kind = .dimension
        } else if val.adoptsBase {
            kind = .base
        } else if val.type == .any, let name = val.implicitName, let ambiguous = pendingAmbiguous, ambiguous.name == name {
            kind = .type
            candidates = ambiguous.candidates
            memberName = name
            memberRange = ambiguous.range
        }
        pendingAmbiguous = nil
        guard let kind else { return nil }
        var literals: [(range: Range<Int>, value: Double)] = []
        collectPlainLiterals(initializer, into: &literals)
        openSlots.append(OpenSlot(kind: kind, owner: owner, literals: literals, candidates: candidates, memberName: memberName,
                                  memberRange: memberRange))
        let slot = openSlots.count - 1
        bindNumericSlot(slot, to: initializer)
        return slot
    }

    func collectPlainLiterals(_ node: PositionedNode, into literals: inout [(range: Range<Int>, value: Double)]) {
        if node.kind == .numberLiteral {
            let literal = NumberLiteralSyntax(unchecked: node)
            if literal.unit == nil, let value = literal.value { literals.append((range(node), value)) }
            return
        }
        for child in node.childNodes { collectPlainLiterals(child, into: &literals) }
    }

    /// A use that meets another value: its type (or, when it is open too, a link).
    func recordUse(_ slot: Int, of other: Val, _ otherNode: PositionedNode, description: LocalizedText) {
        guard mute == 0, slot < openSlots.count else { return }
        if let otherSlot = other.open {
            if otherSlot != slot {
                openSlots[slot].links.append(otherSlot)
                openSlots[otherSlot].links.append(slot)
            }
            // A base-open value already has a dimension. Linking must not hide that known constraint
            // from a dimension-open value (`a = 1; b = 1KB; a == b`).
            if openSlots[otherSlot].kind != .base { return }
        }
        if other.error || other.isJson { return }
        if other.plainLiteral != nil && openSlots[slot].kind == .dimension { return }
        let r = range(otherNode)
        openSlots[slot].uses.append(OpenSlot.Use(expected: other.type, base: other.base, range: r, description: description))
    }

    /// A use that expects a type (a parameter, an assignment target).
    func recordUse(_ slot: Int, expected: DeskType, at r: Range<Int>, description: LocalizedText) {
        guard mute == 0, slot < openSlots.count else { return }
        openSlots[slot].uses.append(OpenSlot.Use(expected: expected, base: nil, range: r, description: description))
    }

    /// Shown as text: decides nothing.
    func recordDisplayUse(_ slot: Int, _ r: Range<Int>) {}

    /// The cases assigned to declarations that were open: each must be a case of the type they settled to.
    func checkCasesForOpenSlots() {
        for (slot, name, r) in casesForOpenSlots where slot < openSlots.count {
            guard case .declaration(let decl) = openSlots[slot].owner, !decl.poisoned, let type = decl.val?.type else { continue }
            switch type {
            case .enumeration(let e):
                if !implicitCaseFits(name, expected: type) {
                    let cases = catalog.enumeration(e)?.cases.map(\.name) ?? localEnums[e] ?? []
                    reportUnknownChoice(name, at: r, what: .type(type), candidates: cases)
                }
            case .color, .paint:
                if !implicitCaseFits(name, expected: type) {
                    reportUnknownChoice(name, at: r, what: .type(type), candidates: catalog.namedValues.filter { $0.type == "Color" }.map(\.name))
                }
            default:
                break
            }
        }
    }

    /// Settles every open slot, group by group.
    func settleOpenSlots() {
        var visited = Set<Int>()
        for start in openSlots.indices where !visited.contains(start) {
            var group: [Int] = []
            var stack = [start]
            while let s = stack.popLast() {
                guard visited.insert(s).inserted else { continue }
                group.append(s)
                stack += openSlots[s].links
            }
            settleGroup(group.sorted())
        }
        openSlotsSettled = true
    }

    private func settleGroup(_ group: [Int]) {
        let uses = group.flatMap { openSlots[$0].uses }
        func isOption(_ s: Int) -> Bool { if case .option = openSlots[s].owner { return true }; return false }
        // Options first: a declaration linked with an option (`lastTheme == options.theme`,
        // `options.theme = lastTheme`) takes the type the option settles to when nothing else decides (§4.3).
        for s in group.filter(isOption) + group.filter({ !isOption($0) }) {
            let slot = openSlots[s]
            switch slot.kind {
            case .dimension: settleDimension(s, uses: uses)
            case .base: settleBase(s, uses: uses)
            case .type:
                guard case .declaration = slot.owner else {
                    // A Picker's local enum is its own provisional type: it decides nothing for a Picker.
                    settleType(s, uses: uses.filter { use in
                        if case .enumeration(let id) = use.expected, localEnums[id] != nil { return false }
                        return true
                    })
                    continue
                }
                // For a declaration, a local enum's case decides like any other (§4.13: `lastTheme = Theme.dark`).
                var own = uses
                let deciding = own.contains { use in
                    switch use.expected {
                    case .enumeration, .color, .paint, .binding(.enumeration): return true
                    default: return false
                    }
                }
                if !deciding {
                    for other in group where other != s && isOption(other) {
                        guard case .option(let option) = openSlots[other].owner else { continue }
                        let id: String?
                        switch option.val.type {
                        case .enumeration(let e): id = e
                        case .color: id = "Color"
                        case .paint: id = "Paint"
                        default: id = nil
                        }
                        guard let id, slot.candidates.contains(id) else { continue }
                        own.append(OpenSlot.Use(expected: option.val.type, base: nil, range: option.nameRange,
                                                description: LocalizedText("linked with options.\(option.name)", "与 options.\(option.name) 关联")))
                    }
                }
                settleType(s, uses: own)
            }
        }
    }

    private func dimension(of type: DeskType) -> Dimension? {
        switch type {
        case .number(let d): return d == .plain ? nil : d
        case .lengthSpec: return .length
        case .fraction: return .percent
        case .binding(let inner): return dimension(of: inner)
        case .oneOf(let ts): return ts.compactMap { dimension(of: $0) }.first
        default: return nil
        }
    }

    private func settleDimension(_ s: Int, uses: [OpenSlot.Use]) {
        let slot = openSlots[s]
        var seen: [Dimension] = []
        var firstUse: [Dimension: OpenSlot.Use] = [:]
        for use in uses {
            guard let d = dimension(of: use.expected) else { continue }
            if !seen.contains(d) { seen.append(d); firstUse[d] = use }
        }
        guard let d = seen.first else {
            openSlots[s].settled = .number(.plain)
            return
        }
        if seen.count > 1 {
            let list = seen.compactMap { firstUse[$0] }.map { use in
                DiagnosticArgument.text(LocalizedText("\(use.description.en) on line \(line(use.range.lowerBound))",
                                                      "\(use.description.zh)（第 \(line(use.range.lowerBound)) 行）"))
            }
            var fixIts: [FixIt] = []
            if let literal = slot.literals.first, let unit = seen.first?.canonicalUnit {
                let t = text(literal.range)
                fixIts.append(fix("writeUnit", [edit(literal.range, t + unit)], ["text": .code(t + unit)]))
            }
            report(.usesDisagree, ownerRange(slot), ["name": .code(slot.name), "uses": .list(list, joiner: .and)], fixIts: fixIts)
            poison(slot)
            return
        }
        openSlots[s].settled = .number(d)
        let bases = Array(Set(uses.compactMap(\.base)))
        let base: Int? = (d == .bytes || d == .bytesPerSecond) ? (bases.count == 1 ? bases[0] : 1000) : nil
        openSlots[s].settledBase = base
        if d.needsWrittenUnit {
            // D134: a declaration or option that settles to time, temperature… must write its unit.
            for literal in slot.literals {
                let node = PositionedNode(node: SyntaxNode(kind: .numberLiteral, children: []), offset: literal.range.lowerBound)
                _ = node
                reportUnitNeededAt(literal.range, dimension: d)
            }
        }
        applySettled(slot, type: .number(d), base: base)
    }

    /// DK4011 at a range (for literals of a settled declaration).
    func reportUnitNeededAt(_ r: Range<Int>, dimension d: Dimension) {
        // Find the literal node at the range and reuse the expression-level report.
        if let node = tree.positionedNode(at: r.lowerBound), node.kind == .numberLiteral {
            reportUnitNeeded(node, dimension: d)
        } else {
            var found: PositionedNode?
            func search(_ n: PositionedNode) {
                if found != nil { return }
                if n.kind == .numberLiteral && range(n) == r { found = n; return }
                guard n.range.lowerBound <= r.lowerBound && r.upperBound <= n.range.upperBound else { return }
                for c in n.childNodes { search(c) }
            }
            search(tree.rootNode)
            if let found { reportUnitNeeded(found, dimension: d) }
        }
    }

    private func settleBase(_ s: Int, uses: [OpenSlot.Use]) {
        let slot = openSlots[s]
        let bases = Array(Set(uses.compactMap(\.base))).sorted()
        if bases.count > 1 {
            let literal = slot.literals.first
            var fixIts: [FixIt] = []
            var fixed = "GiB"
            if let r = literal?.range ?? ownerValueRange(slot) {
                let t = text(r)
                let replaced = t.replacingOccurrences(of: "KB", with: "KiB").replacingOccurrences(of: "MB", with: "MiB")
                    .replacingOccurrences(of: "GB", with: "GiB").replacingOccurrences(of: "TB", with: "TiB")
                fixed = replaced
                fixIts.append(fix("replaceWith", [edit(r, replaced)], ["text": .code(replaced)]))
            }
            report(.byteBaseDisagrees, ownerRange(slot), ["name": .code(slot.name), "fixed": .code(fixed)], fixIts: fixIts)
            openSlots[s].settledBase = 1000
            applySettled(slot, type: nil, base: 1000)
            return
        }
        let base = bases.first ?? 1000
        openSlots[s].settledBase = base
        applySettled(slot, type: nil, base: base)
    }

    private func settleType(_ s: Int, uses: [OpenSlot.Use]) {
        let slot = openSlots[s]
        var types: [String] = []
        var firstUse: [String: OpenSlot.Use] = [:]
        for use in uses {
            var id: String?
            switch use.expected {
            case .enumeration(let e): id = e
            case .color: id = "Color"
            case .paint: id = "Paint"
            case .binding(.enumeration(let e)): id = e
            default: id = nil
            }
            if let id, !types.contains(id) { types.append(id); firstUse[id] = use }
        }
        if types.count > 1, types.contains("Color"), types.contains("Paint") { types.removeAll { $0 == "Paint" } }
        switch slot.owner {
        case .declaration(let decl):
            if types.count == 1 {
                let t = types[0]
                applySettled(slot, type: t == "Color" ? .color : t == "Paint" ? .paint : .enumeration(t), base: nil)
                _ = decl
            } else if types.count > 1 {
                reportUsesDisagreeType(slot, types: types, firstUse: firstUse)
            } else if let name = slot.memberName, let r = slot.memberRange {
                reportAmbiguousChoice(name, candidates: slot.candidates, at: r)
                poison(slot)
            }
        case .option(let option):
            settlePicker(option, slot: slot, types: types, firstUse: firstUse)
        }
    }

    private func reportUsesDisagreeType(_ slot: OpenSlot, types: [String], firstUse: [String: OpenSlot.Use]) {
        let list = types.compactMap { firstUse[$0] }.map { use in
            DiagnosticArgument.text(LocalizedText("\(use.description.en) on line \(line(use.range.lowerBound))",
                                                  "\(use.description.zh)（第 \(line(use.range.lowerBound)) 行）"))
        }
        var fixIts: [FixIt] = []
        if let r = slot.memberRange, let name = slot.memberName {
            for t in types { fixIts.append(fix("qualifyChoice", [edit(r, "\(t).\(name)")], ["text": .code("\(t).\(name)")])) }
        }
        report(.usesDisagree, ownerRange(slot), ["name": .code(slot.name), "uses": .list(list, joiner: .and)], fixIts: fixIts)
        poison(slot)
    }

    /// A Picker of implicit members (§4.13, D100): its uses decide; else the one catalog type with every choice;
    /// else a local enum.
    func settlePicker(_ option: OptionInfo, slot: OpenSlot, types: [String], firstUse: [String: OpenSlot.Use]) {
        if types.count > 1 {
            reportUsesDisagreeType(slot, types: types, firstUse: firstUse)
            return
        }
        if let t = types.first {
            // Every choice must be a case of the type the uses expect.
            for (choice, r) in pickerChoiceRanges[option.name] ?? [] where !implicitCaseFits(choice, expected: t == "Color" ? .color : t == "Paint" ? .paint : .enumeration(t)) {
                let cases = catalog.enumeration(t)?.cases.map(\.name) ?? catalog.namedValues.filter { $0.type == t }.map(\.name)
                reportUnknownChoice(choice, at: r, what: t == "Color" ? .type(.color) : .type(.enumeration(t)), candidates: cases)
            }
            localEnums[localEnumName(option)] = nil
            option.localEnum = nil
            applySettled(slot, type: t == "Color" ? .color : t == "Paint" ? .paint : .enumeration(t), base: nil)
            return
        }
        if slot.candidates.count == 1 {
            let t = slot.candidates[0]
            localEnums[localEnumName(option)] = nil
            option.localEnum = nil
            applySettled(slot, type: t == "Color" ? .color : t == "Paint" ? .paint : .enumeration(t), base: nil)
            return
        }
        // A local enum of its own choices.
        let name = localEnumName(option)
        option.localEnum = name
        if slot.candidates.count > 1, let first = pickerChoiceRanges[option.name]?.first {
            let names = slot.candidates.map { c -> DiagnosticArgument in
                c == "Color" ? .type(.color) : c == "Paint" ? .type(.paint) : .type(.enumeration(c))
            }
            let fixIts = slot.candidates.map { c in fix("qualifyChoice", [edit(first.1, "\(c).\(first.0)")], ["text": .code("\(c).\(first.0)")]) }
            report(.localChoices, range(option.node), ["candidates": .list(names, joiner: .or),
                                                       "fixed": .code("\(slot.candidates[0]).\(first.0)")], fixIts: fixIts)
        }
        applySettled(slot, type: .enumeration(name), base: nil)
    }

    /// The name of a Picker's local enum: the option's name with a capital first letter, `Choice` added on a clash.
    func localEnumName(_ option: OptionInfo) -> String {
        let base = option.name.prefix(1).uppercased() + option.name.dropFirst()
        if catalog.component(named: base) != nil || catalog.control(named: base) != nil || catalog.enumeration(base) != nil
            || catalog.record(base) != nil || base == "Color" || base == "Paint" {
            return base + "Choice"
        }
        return base
    }

    private func applySettled(_ slot: OpenSlot, type: DeskType?, base: Int?) {
        switch slot.owner {
        case .declaration(let decl):
            if let type { decl.val?.type = type }
            if let base { decl.val?.base = base }
            decl.val?.open = nil
        case .option(let option):
            if let type { option.val.type = type }
            if let base { option.val.base = base }
            option.val.open = nil
        }
    }

    private func poison(_ slot: OpenSlot) {
        switch slot.owner {
        case .declaration(let decl): decl.poisoned = true
        case .option: break
        }
    }

    private func ownerRange(_ slot: OpenSlot) -> Range<Int> {
        switch slot.owner {
        case .declaration(let decl): return decl.nameRange
        case .option(let option): return option.nameRange
        }
    }

    private func ownerValueRange(_ slot: OpenSlot) -> Range<Int>? {
        switch slot.owner {
        case .declaration(let decl): return range(DeclarationSyntax(unchecked: decl.node).initializer.node)
        case .option: return nil
        }
    }
}
