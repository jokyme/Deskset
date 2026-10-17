import Foundation

// Results kept per top-level block from one snapshot to the next. After an edit the service shares the unchanged
// subtrees of the previous tree (`SubtreeReuse`), so a top-level block the edit did not touch is the same object in
// the new tree. What was worked out for it is stored with offsets relative to the block's first byte and used again
// at the block's new place:
//
// - folding ranges, which depend on the block's text alone;
// - semantic runs, when the facts they were classified from (the names in the block with their kinds, roles and
//   catalog entries; its unused names, element calls and translation keys) are the same, relative to the block;
// - outline items, when the element names in the block and the message language are the same.
//
// The checker is not incremental (option types settle by uses anywhere in the file), so the facts are always those
// of the new check; only the work done from them is saved. Each check of a kept result compares the facts it
// depended on, so a reused result is always the one a fresh snapshot would build.

/// The per-block results of one snapshot, and those it inherited from the snapshots before it.
final class DeskBlockMemo: @unchecked Sendable {
    struct Semantic {
        let node: SyntaxNode
        let facts: DeskSemanticBlockFacts
        let runs: [DeskSemanticBlock.Run]
    }

    struct Folding {
        let node: SyntaxNode
        /// Relative to the block.
        let ranges: [(kind: DeskFoldingKind, range: Range<Int>)]
    }

    struct Outline {
        let node: SyntaxNode
        let key: DeskOutlineBlockKey
        /// Relative to the block; nil for a block the outline does not show.
        let item: DeskOutlineItem?
    }

    struct Store {
        var semantic: [ObjectIdentifier: Semantic] = [:]
        var folding: [ObjectIdentifier: Folding] = [:]
        var outline: [ObjectIdentifier: Outline] = [:]

        /// Only the entries of these nodes.
        func keeping(_ nodes: Set<ObjectIdentifier>) -> Store {
            Store(semantic: semantic.filter { nodes.contains($0.key) }, folding: folding.filter { nodes.contains($0.key) },
                  outline: outline.filter { nodes.contains($0.key) })
        }

        mutating func merge(_ other: Store) {
            semantic.merge(other.semantic) { _, new in new }
            folding.merge(other.folding) { _, new in new }
            outline.merge(other.outline) { _, new in new }
        }
    }

    /// How often a kept result was found and used, and how often it had to be worked out (tests read them).
    struct Counts: Sendable, Hashable {
        var semanticReused = 0, semanticBuilt = 0
        var foldingReused = 0, foldingBuilt = 0
        var outlineReused = 0, outlineBuilt = 0
    }

    private let lock = NSLock()
    /// What the snapshots before this one kept, for the blocks of this snapshot's tree.
    private let inherited: Store
    /// What this snapshot worked out.
    private var own = Store()
    private var counts = Counts()

    /// An empty memo.
    init() { inherited = Store() }

    /// A memo for `tree` that can use what `previous` (and the memos before it) kept for its top-level blocks.
    init(carrying previous: DeskBlockMemo?, into tree: SyntaxTree) {
        guard let previous else {
            inherited = Store()
            return
        }
        var nodes = Set<ObjectIdentifier>()
        for child in tree.root.children {
            if case .node(let node) = child { nodes.insert(ObjectIdentifier(node)) }
        }
        var store = previous.inherited
        previous.lock.lock()
        store.merge(previous.own)
        previous.lock.unlock()
        inherited = store.keeping(nodes)
    }

    // The node in each entry keeps the object alive, so an `ObjectIdentifier` is never reused for another node
    // while its entry exists; the node is compared again anyway.

    func semantic(_ node: SyntaxNode, facts: DeskSemanticBlockFacts) -> [DeskSemanticBlock.Run]? {
        lock.lock()
        defer { lock.unlock() }
        if let kept = inherited.semantic[ObjectIdentifier(node)], kept.node === node, kept.facts == facts {
            counts.semanticReused += 1
            return kept.runs
        }
        return nil
    }

    func storeSemantic(_ node: SyntaxNode, facts: DeskSemanticBlockFacts, runs: [DeskSemanticBlock.Run]) {
        lock.lock()
        defer { lock.unlock() }
        own.semantic[ObjectIdentifier(node)] = Semantic(node: node, facts: facts, runs: runs)
        counts.semanticBuilt += 1
    }

    func folding(_ node: SyntaxNode) -> [(kind: DeskFoldingKind, range: Range<Int>)]? {
        lock.lock()
        defer { lock.unlock() }
        if let kept = inherited.folding[ObjectIdentifier(node)], kept.node === node {
            counts.foldingReused += 1
            return kept.ranges
        }
        return nil
    }

    func storeFolding(_ node: SyntaxNode, ranges: [(kind: DeskFoldingKind, range: Range<Int>)]) {
        lock.lock()
        defer { lock.unlock() }
        own.folding[ObjectIdentifier(node)] = Folding(node: node, ranges: ranges)
        counts.foldingBuilt += 1
    }

    func outline(_ node: SyntaxNode, key: DeskOutlineBlockKey) -> DeskOutlineItem?? {
        lock.lock()
        defer { lock.unlock() }
        if let kept = inherited.outline[ObjectIdentifier(node)], kept.node === node, kept.key == key {
            counts.outlineReused += 1
            return .some(kept.item)
        }
        return nil
    }

    func storeOutline(_ node: SyntaxNode, key: DeskOutlineBlockKey, item: DeskOutlineItem?) {
        lock.lock()
        defer { lock.unlock() }
        own.outline[ObjectIdentifier(node)] = Outline(node: node, key: key, item: item)
        counts.outlineBuilt += 1
    }

    var reuseCounts: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

/// What a top-level block's semantic runs were classified from, relative to the block's first byte.
struct DeskSemanticBlockFacts: Sendable, Hashable {
    struct Name: Sendable, Hashable {
        var start: Int
        var end: Int
        var kind: DeskNameKind
        var role: DeskOccurrenceRole
        var path: CatalogPath?
    }
    var names: [Name] = []
    var unused: [Int] = []
    var elementCalls: [Int] = []
    var translationKeys: [Int] = []
}

/// What a top-level block's outline item was built from besides its text: the element names in it (relative to
/// the block) and the language of its words.
struct DeskOutlineBlockKey: Sendable, Hashable {
    var elements: [Int] = []
    var names: [String?] = []
    var language: DiagnosticLanguage
}

/// An outline item in UTF-8 offsets (absolute while built, relative to its block while kept).
struct DeskOutlineItem: Sendable {
    var name: String
    var detail: String?
    var kind: DeskOutlineKind
    var range: Range<Int>
    var selection: Range<Int>
    var children: [DeskOutlineItem]
    /// The text start of the element's call, when the item is an element the checker made.
    var element: Int?

    func shifted(by delta: Int) -> DeskOutlineItem {
        var copy = self
        copy.range = (range.lowerBound + delta)..<(range.upperBound + delta)
        copy.selection = (selection.lowerBound + delta)..<(selection.upperBound + delta)
        copy.element = element.map { $0 + delta }
        copy.children = children.map { $0.shifted(by: delta) }
        return copy
    }

    /// Every offset of the item and its children, in the order `symbol(positions:)` reads them.
    func collectOffsets(into out: inout [Int]) {
        out += [range.lowerBound, range.upperBound, selection.lowerBound, selection.upperBound]
        for child in children { child.collectOffsets(into: &out) }
    }
}
