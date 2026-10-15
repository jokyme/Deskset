import Foundation
import DesksetCore

/// Identity within one compilation lineage. Source references remain qualified by their checked tree version.
public struct TemplateID: Hashable, Sendable {
    public let rawValue: Int
    init(_ value: Int) { rawValue = value }
}

public struct DeskSourceRange: Hashable, Sendable {
    public let file: DeskFileID
    public let range: Range<Int>
}

/// Immutable source information for a published program, not authority to edit a different checked snapshot.
public struct DeskSourceMap: Sendable {
    public struct Element: Sendable {
        public let templateID: TemplateID
        /// Core identity; its legacy name is an identity label, not a mutable authored display name.
        public let elementID: ElementID
        public let parent: TemplateID?
        public let source: DeskSourceRange
        public let reference: NodeID
        public let component: String
        /// The current authored .name, independent of the retained Core identity label.
        public let name: String?
    }
    public let file: DeskFileID
    public let treeVersion: Int
    public let elements: [TemplateID: Element]
    /// Includes expression, declaration, action and modifier nodes, in their original checked source versions.
    public let nodes: [NodeID: DeskSourceRange]
    public let origins: [CandidateOrigin: DeskSourceRange]
    /// Actual lowered IR occurrences, including declarations, actions, menus and expression operands.
    /// Unlike nodes, this index is addressed from the program rather than from the syntax tree.
    public let irNodes: [DeskIRNodePath: DeskIRSourceSite]
    fileprivate let records: [TemplateRecord]
    fileprivate let allocator: TemplateAllocator
}

/// Shared by immutable previous results: branching undo histories must not rewind the allocation watermark.
/// Locking also makes concurrent compilations from the same previous result disjoint.
private final class TemplateAllocator: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int
    init(next: Int) { self.next = next }
    func allocate() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard next < Int.max else { throw TemplateAllocationFailure.exhausted }
        defer { next += 1 }
        return next
    }
}
private enum TemplateAllocationFailure: Error { case exhausted }

private struct TemplateRecord: Sendable {
    var id: ElementID
    let reference: NodeID
    let range: Range<Int>
    let component: String
    let name: String?
    let arguments: String
    let parent: Int?
    let group: Int
    let branches: [TemplateBranch]
}

private struct TemplateBranch: Sendable {
    let condition: String
    let body: String
}

/// Reconciles only the fully validated lowering product; it never manufactures checked receipts.
struct TemplateReconciliation {
    let program: WidgetProgram
    let sourceMap: DeskSourceMap
    let elementRefs: [ElementID: ElementRef]

    init(program: WidgetProgram, checked: CheckedFile, references: [ElementID: NodeID],
         sources: [Int: CheckedFile], origins: Set<CandidateOrigin>, previous: DeskSourceMap?, moves: [TextMove]) throws {
        var syntax: [NodeID: PositionedNode] = [:], pending = [checked.tree.rootNode]
        while let node = pending.popLast() {
            syntax[checked.tree.id(of: node)] = node
            pending.append(contentsOf: node.childNodes)
        }
        var records: [TemplateRecord] = []
        func collect(_ element: ProgramElement, parent: Int?, group: Int) throws {
            guard let ref = references[element.id], let node = syntax[ref] else {
                throw DeskCompilationIssue(kind: .invalidCheckedModel, file: checked.tree.file,
                    range: checked.tree.rootNode.textRange, message: "Lowered element has no current source reference")
            }
            let facts = checked.elements[ref]
            let call = CallStmtSyntax(node)
            let index = records.count
            var branches: [TemplateBranch] = [], current = IfStmtSyntax(node)
            while let statement = current {
                branches.append(TemplateBranch(condition: statement.condition.node.node.trimmedText,
                                               body: statement.block.node.node.trimmedText))
                current = statement.elseClause.flatMap { IfStmtSyntax($0.body) }
            }
            records.append(TemplateRecord(id: element.id, reference: ref, range: node.textRange,
                component: facts?.component ?? (node.kind == .ifStmt ? "@if" : "@widget"),
                name: facts?.name, arguments: call?.arguments?.node.node.trimmedText ?? "",
                parent: parent, group: group, branches: branches))
            switch element.content {
            case .column(_, _, let children), .row(_, _, let children), .freeform(_, let children):
                for child in children { try collect(child, parent: index, group: 0) }
            case .conditional(let conditional):
                for (branch, value) in conditional.branches.enumerated() {
                    for child in value.body { try collect(child, parent: index, group: branch) }
                }
                for child in conditional.otherwise { try collect(child, parent: index, group: -1) }
            default: break
            }
        }
        try collect(program.root, parent: nil, group: 0)
        let previous = previous?.file == checked.tree.file ? previous : nil
        let allocator = previous?.allocator ?? TemplateAllocator(next: (records.map { $0.id.index }.max() ?? -1) + 1)
        var matches: [Int: Int] = [:]
        if let previous {
            matches = TemplateMatcher(old: previous.records, new: records).match(moves: moves)
        }
        var replacements: [ElementID: ElementID] = [:]
        var elements: [TemplateID: DeskSourceMap.Element] = [:]
        var refs: [ElementID: NodeID] = [:]
        for i in records.indices {
            let original = records[i].id
            if let old = matches[i], let previous {
                records[i].id = previous.records[old].id
            } else if previous != nil {
                let index = try allocator.allocate()
                records[i].id = ElementID(name: records[i].name ?? "\(records[i].component)#\(index)", index: index)
            }
            replacements[original] = records[i].id
            if checked.elements[records[i].reference] != nil { refs[records[i].id] = records[i].reference }
        }
        for record in records {
            let id = TemplateID(record.id.index)
            elements[id] = DeskSourceMap.Element(templateID: id, elementID: record.id,
                parent: record.parent.map { TemplateID(records[$0].id.index) },
                source: DeskSourceRange(file: checked.tree.file, range: record.range), reference: record.reference,
                component: record.component, name: record.name)
        }
        var nodes: [NodeID: DeskSourceRange] = [:]
        for source in sources.values {
            var pending = [source.tree.rootNode]
            while let node = pending.popLast() {
                nodes[source.tree.id(of: node)] = DeskSourceRange(file: source.tree.file, range: node.textRange)
                pending.append(contentsOf: node.childNodes)
            }
        }
        var originRanges: [CandidateOrigin: DeskSourceRange] = [:]
        for origin in origins {
            switch origin {
            case .own(let ref): originRanges[origin] = nodes[ref]
            case .style(_, let ref, let file):
                if nodes[ref]?.file == file { originRanges[origin] = nodes[ref] }
            }
        }
        let reconciled = WidgetProgram(name: program.name, root: Self.remap(program.root, ids: replacements),
            declarations: program.declarations, onLoad: program.onLoad, size: program.size,
            translations: program.translations, nameKey: program.nameKey, options: program.options)
        let ir = try DeskIRSourceIndex(program: reconciled, checked: checked, sources: sources,
                                      references: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.reference) }))
        self.sourceMap = DeskSourceMap(file: checked.tree.file, treeVersion: checked.tree.version,
            elements: elements, nodes: nodes, origins: originRanges, irNodes: ir.sites, records: records, allocator: allocator)
        self.elementRefs = refs
        self.program = reconciled
    }

    private static func remap(_ element: ProgramElement, ids: [ElementID: ElementID]) -> ProgramElement {
        let content: ProgramElement.Content
        func children(_ values: [ProgramElement]) -> [ProgramElement] { values.map { remap($0, ids: ids) } }
        switch element.content {
        case .column(let spacing, let align, let values): content = .column(spacing: spacing, align: align, children: children(values))
        case .row(let spacing, let align, let values): content = .row(spacing: spacing, align: align, children: children(values))
        case .freeform(let align, let values): content = .freeform(align: align, children: children(values))
        case .conditional(let value):
            content = .conditional(ProgramConditional(branches: value.branches.map {
                ProgramConditionalBranch(condition: $0.condition, body: children($0.body))
            }, otherwise: children(value.otherwise)))
        default: content = element.content
        }
        return ProgramElement(id: ids[element.id] ?? element.id, content: content,
            width: element.width, height: element.height, padding: element.padding, hidden: element.hidden,
            minWidth: element.minWidth, maxWidth: element.maxWidth, minHeight: element.minHeight, maxHeight: element.maxHeight,
            idealSize: element.idealSize, stroke: element.stroke, cornerRadius: element.cornerRadius,
            onClick: element.onClick, onClickActions: element.onClickActions, onRightClickActions: element.onRightClickActions,
            position: element.position, background: element.background, voiceOver: element.voiceOver,
            hiddenIf: element.hiddenIf, tooltip: element.tooltip, menu: element.menu)
    }
}

private struct TemplateMatcher {
    let old: [TemplateRecord]
    let new: [TemplateRecord]

    func match(moves: [TextMove]) -> [Int: Int] {
        var result: [Int: Int] = [:], used = Set<Int>(), queue: [Int] = []
        func children(_ records: [TemplateRecord]) -> [Int: [Int: [Int]]] {
            var result: [Int: [Int: [Int]]] = [:]
            for i in records.indices {
                if let parent = records[i].parent { result[parent, default: [:]][records[i].group, default: []].append(i) }
            }
            return result
        }
        let oldChildren = children(old), newChildren = children(new)
        let oldRanges = Dictionary(grouping: old.indices, by: { old[$0].range })
        let newRanges = Dictionary(grouping: new.indices, by: { new[$0].range })
        func pair(_ o: Int, _ n: Int) {
            guard result[n] == nil, used.insert(o).inserted else { return }
            result[n] = o
            queue.append(n)
        }
        // Explicit editor moves outrank all structural guesses, including the root. Conflicting or invalid
        // ranges are ignored; they cannot duplicate an identity or turn one component into another.
        for move in moves {
            let os = oldRanges[move.from] ?? []
            let ns = newRanges[move.to] ?? []
            if os.count == 1, ns.count == 1, old[os[0]].component == new[ns[0]].component { pair(os[0], ns[0]) }
        }
        func siblings(_ oldIndices: [Int], _ newIndices: [Int]) {
            let os = oldIndices.filter { !used.contains($0) }
            let ns = newIndices.filter { result[$0] == nil }
            let anchors = lcs(os, ns)
            var oi = 0, ni = 0
            // Same-component fallback stays between LCS neighbours, never across anchors.
            for (a, b) in anchors + [(os.count, ns.count)] {
                var available = Array(os[oi..<a])
                for j in ns[ni..<b] {
                    if let k = available.firstIndex(where: { old[$0].component == new[j].component }) {
                        pair(available.remove(at: k), j)
                    }
                }
                if a < os.count { pair(os[a], ns[b]) }
                oi = a + 1; ni = b + 1
            }
        }
        if !old.isEmpty, !new.isEmpty {
            let oldImplicit = old[0].component == "@widget", newImplicit = new[0].component == "@widget"
            if oldImplicit == newImplicit {
                if result[0] == nil, !used.contains(0) { pair(0, 0) }
            } else {
                // The compiler elides an implicit Column for one view. Its appearance/disappearance must
                // not steal that view's ID when a sibling is inserted or deleted at widget scope.
                siblings(oldImplicit ? old.indices.filter { old[$0].parent == 0 } : [0],
                         newImplicit ? new.indices.filter { new[$0].parent == 0 } : [0])
            }
        }
        // A moved container's descendants are reconciled within it, not by byte deltas: wrap/indent changes
        // whitespace and may change every descendant offset.
        queue.sort()
        var cursor = 0
        while cursor < queue.count {
            let n = queue[cursor]
            cursor += 1
            let o = result[n]!
            let groups = newChildren[n] ?? [:]
            let branchPairs = matchBranches(old[o].branches, new[n].branches)
            for group in groups.keys.sorted() {
                let oldGroup: Int?
                if group == -1 || new[n].branches.isEmpty { oldGroup = group }
                else { oldGroup = branchPairs[group] }
                if let oldGroup { siblings(oldChildren[o]?[oldGroup] ?? [], groups[group] ?? []) }
            }
        }
        return result
    }

    /// Conditional blocks are structural parents too. Their condition keys identify inserted/deleted arms;
    /// equal keys use body text only as a tie-breaker. Remaining arms pair inside the same anchor interval.
    /// Otherwise is a separate -1 group, never a numerical alias of an inserted condition arm.
    private func matchBranches(_ old: [TemplateBranch], _ new: [TemplateBranch]) -> [Int: Int] {
        let anchors = sequenceLCS(oldCount: old.count, newCount: new.count,
            equal: { old[$0].condition == new[$1].condition }, tie: { old[$0].body == new[$1].body })
        var result: [Int: Int] = [:], oi = 0, ni = 0
        for (o, n) in anchors + [(old.count, new.count)] {
            for offset in 0..<min(o - oi, n - ni) { result[ni + offset] = oi + offset }
            if o < old.count { result[n] = o }
            oi = o + 1; ni = n + 1
        }
        return result
    }

    /// Maximum number of (component, name) matches first; argument equality only breaks equal-length ties.
    /// Two score rows and one byte per cell bound memory at the compiler's existing element limit.
    private func lcs(_ os: [Int], _ ns: [Int]) -> [(Int, Int)] {
        sequenceLCS(oldCount: os.count, newCount: ns.count,
            equal: { old[os[$0]].component == new[ns[$1]].component && old[os[$0]].name == new[ns[$1]].name },
            tie: { old[os[$0]].arguments == new[ns[$1]].arguments })
    }

    private func sequenceLCS(oldCount: Int, newCount: Int, equal: (Int, Int) -> Bool,
                             tie: (Int, Int) -> Bool) -> [(Int, Int)] {
        guard oldCount > 0, newCount > 0 else { return [] }
        let width = newCount, weight = min(oldCount, newCount) + 1
        var below = [Int](repeating: 0, count: width + 1)
        var directions = [UInt8](repeating: 0, count: oldCount * width)
        for i in (0..<oldCount).reversed() {
            var row = [Int](repeating: 0, count: width + 1)
            for j in (0..<newCount).reversed() {
                var score = below[j], direction: UInt8 = 1
                if row[j + 1] >= score { score = row[j + 1]; direction = 2 }
                if equal(i, j) {
                    let diagonal = below[j + 1] + weight + (tie(i, j) ? 1 : 0)
                    if diagonal >= score { score = diagonal; direction = 3 }
                }
                row[j] = score; directions[i * width + j] = direction
            }
            below = row
        }
        var pairs: [(Int, Int)] = [], i = 0, j = 0
        while i < oldCount && j < newCount {
            switch directions[i * width + j] {
            case 1: i += 1
            case 2: j += 1
            default: pairs.append((i, j)); i += 1; j += 1
            }
        }
        return pairs
    }
}
