import Foundation

// Settling by use (§4.3, D93, D100, D134): a declaration or option whose initializer leaves its dimension, display
// base or type open takes it from how it is used. Uses that meet another open value link the two; they settle
// together. Uses that disagree are DK4041 (DK4042 for a display base only); a type no use decides is DK3018 for a
// declaration and a local enum (with DK3032) for a Picker.

extension Checker {
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
        return openSlots.count - 1
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
            return
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
    }

    private func settleGroup(_ group: [Int]) {
        let uses = group.flatMap { openSlots[$0].uses }
        for s in group {
            let slot = openSlots[s]
            switch slot.kind {
            case .dimension: settleDimension(s, uses: uses)
            case .base: settleBase(s, uses: uses)
            case .type: settleType(s, uses: uses.filter { use in
                if case .enumeration(let id) = use.expected, localEnums[id] != nil { return false }
                return true
            })
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
        guard let d = seen.first else { return }
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
        if d.needsWrittenUnit {
            // D134: a declaration or option that settles to time, temperature… must write its unit.
            for literal in slot.literals {
                let node = PositionedNode(node: SyntaxNode(kind: .numberLiteral, children: []), offset: literal.range.lowerBound)
                _ = node
                reportUnitNeededAt(literal.range, dimension: d)
            }
        }
        applySettled(slot, type: .number(d), base: nil)
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
            applySettled(slot, type: nil, base: 1000)
            return
        }
        applySettled(slot, type: nil, base: bases.first ?? 1000)
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
