import Foundation

// Sharing the unchanged parts of the previous tree after a reparse. The new text is always parsed in full; then
// every subtree of the new tree that has a counterpart in the previous tree (the same kind at the same place, the
// place moved by the edit) with the same bytes and the same structure is replaced by the previous tree's node. The
// comparison is complete (kinds, foreign kinds, every token with its trivia, flags and unit), so the result prints
// and compares exactly like the fresh tree, and it carries the fresh parse's diagnostics, header and line table.
// What changes is identity: the nodes an edit did not touch are the same objects as before, so results kept per
// node (a top-level block's highlighting, folding and outline) can be used again.

/// How much of a tree came from the previous one.
public struct SubtreeReuseStats: Sendable, Hashable, CustomStringConvertible {
    /// Nodes of the new tree, the root included.
    public var nodes = 0
    /// Nodes of the new tree that are the previous tree's objects (a shared subtree counts all its nodes).
    public var sharedNodes = 0
    /// Shared subtrees (each counted once, at its top).
    public var sharedSubtrees = 0
    /// Bytes of the new text, and the bytes inside shared subtrees.
    public var bytes = 0
    public var sharedBytes = 0

    public init() {}

    /// The share of nodes that came from the previous tree, 0…1.
    public var nodeRate: Double { nodes == 0 ? 0 : Double(sharedNodes) / Double(nodes) }

    public mutating func add(_ other: SubtreeReuseStats) {
        nodes += other.nodes
        sharedNodes += other.sharedNodes
        sharedSubtrees += other.sharedSubtrees
        bytes += other.bytes
        sharedBytes += other.sharedBytes
    }

    public var description: String {
        String(format: "%d of %d nodes shared (%.1f%%) in %d subtrees, %d of %d bytes", sharedNodes, nodes,
               nodeRate * 100, sharedSubtrees, sharedBytes, bytes)
    }
}

/// Where two texts differ: bytes `start..<oldEnd` of the old text became bytes `start..<newEnd` of the new one.
public struct SyntaxTextEdit: Sendable, Hashable {
    public var start: Int
    public var oldEnd: Int
    public var newEnd: Int

    public init(start: Int, oldEnd: Int, newEnd: Int) {
        self.start = start
        self.oldEnd = oldEnd
        self.newEnd = newEnd
    }

    /// How far text after the edit moved.
    public var delta: Int { newEnd - oldEnd }

    /// The smallest edit that turns `old` into `new`: their common beginning and end are left out.
    public static func between(_ old: [UInt8], _ new: [UInt8]) -> SyntaxTextEdit {
        let shorter = min(old.count, new.count)
        let prefix: Int = old.withUnsafeBufferPointer { a in
            new.withUnsafeBufferPointer { b in
                var k = 0
                // Eight bytes at a time, then byte by byte.
                while k + 8 <= shorter, memcmp(a.baseAddress! + k, b.baseAddress! + k, 8) == 0 { k += 8 }
                while k < shorter, a[k] == b[k] { k += 1 }
                return k
            }
        }
        let suffix: Int = old.withUnsafeBufferPointer { a in
            new.withUnsafeBufferPointer { b in
                var k = 0
                let limit = shorter - prefix
                while k < limit, a[a.count - 1 - k] == b[b.count - 1 - k] { k += 1 }
                return k
            }
        }
        return SyntaxTextEdit(start: prefix, oldEnd: old.count - suffix, newEnd: new.count - suffix)
    }
}

enum SubtreeReuse {
    /// `fresh` (a full parse of the new text) with every subtree that is unchanged from `previous` taken from
    /// `previous`. `edit` says where the texts differ (`SyntaxTextEdit.between` of the two texts); `newBytes` and
    /// `oldBytes` are the two texts' UTF-8. The result is equal to `fresh` node for node and token for token; only
    /// the identity of unchanged nodes differs.
    static func share(_ fresh: SyntaxTree, previous: SyntaxTree, edit: SyntaxTextEdit, newBytes: [UInt8],
                      oldBytes: [UInt8]) -> (tree: SyntaxTree, stats: SubtreeReuseStats) {
        var stats = SubtreeReuseStats()
        stats.bytes = fresh.root.byteLength
        guard fresh.file == previous.file, newBytes.count == fresh.root.byteLength,
              oldBytes.count == previous.root.byteLength else {
            stats.nodes = countNodes(fresh.root)
            return (fresh, stats)
        }
        let texts = Texts(new: newBytes, old: oldBytes)
        let root = shareNodes(fresh.root, previous.root, edit: edit, texts: texts, stats: &stats)
        guard root !== fresh.root else { return (fresh, stats) }
        let tree = SyntaxTree(file: fresh.file, root: root, text: fresh.text, version: fresh.version,
                              diagnostics: fresh.diagnostics, header: fresh.header, lines: fresh.lines, repair: fresh.repair)
        return (tree, stats)
    }

    /// One node of the walk: a new node and its counterpart in the previous tree, with their children as far as
    /// they were matched.
    private struct Frame {
        let new: SyntaxNode
        let old: SyntaxNode
        /// Where `new` starts in the new text and `old` in the old text.
        let newOffset: Int
        let oldOffset: Int
        /// The new node's children, with shared ones put in; set on the first replacement.
        var children: [SyntaxChild]?
        /// The next child of `new` to look at, and where it starts.
        var next = 0
        var childOffset: Int
        /// The first child of `old` not yet passed, and where it starts.
        var oldNext = 0
        var oldChildOffset: Int
        /// This node's index among its parent's children.
        let indexInParent: Int

        init(new: SyntaxNode, old: SyntaxNode, newOffset: Int, oldOffset: Int, indexInParent: Int) {
            self.new = new
            self.old = old
            self.newOffset = newOffset
            self.oldOffset = oldOffset
            childOffset = newOffset
            oldChildOffset = oldOffset
            self.indexInParent = indexInParent
        }
    }

    /// The two texts, to compare a node's bytes with its counterpart's before comparing their structure.
    private struct Texts {
        let new: [UInt8]
        let old: [UInt8]

        func same(new newRange: Range<Int>, old oldRange: Range<Int>) -> Bool {
            guard newRange.count == oldRange.count else { return false }
            if newRange.isEmpty { return true }
            return new.withUnsafeBufferPointer { a in
                old.withUnsafeBufferPointer { b in
                    memcmp(a.baseAddress! + newRange.lowerBound, b.baseAddress! + oldRange.lowerBound, newRange.count) == 0
                }
            }
        }
    }

    /// Walks the new tree top-down without recursion (trees can be hundreds of levels deep): a node equal to its
    /// counterpart is replaced by it; a node that differs is walked into; a node without a counterpart is kept.
    private static func shareNodes(_ newRoot: SyntaxNode, _ oldRoot: SyntaxNode, edit: SyntaxTextEdit, texts: Texts,
                                   stats: inout SubtreeReuseStats) -> SyntaxNode {
        if texts.same(new: 0..<newRoot.byteLength, old: 0..<oldRoot.byteLength), let shared = equalCount(newRoot, oldRoot) {
            stats.nodes += shared
            stats.sharedNodes += shared
            stats.sharedSubtrees += 1
            stats.sharedBytes += oldRoot.byteLength
            return oldRoot
        }
        guard newRoot.kind == oldRoot.kind, newRoot.foreignKind == oldRoot.foreignKind else {
            stats.nodes += countNodes(newRoot)
            return newRoot
        }
        var stack = [Frame(new: newRoot, old: oldRoot, newOffset: 0, oldOffset: 0, indexInParent: 0)]
        stats.nodes += 1
        var result = newRoot
        while !stack.isEmpty {
            let top = stack.count - 1
            if stack[top].next >= stack[top].new.children.count {
                let frame = stack.removeLast()
                var made = frame.new
                if let children = frame.children {
                    made = SyntaxNode(kind: frame.new.kind, children: children, foreignKind: frame.new.foreignKind)
                }
                if stack.isEmpty {
                    result = made
                } else if made !== frame.new {
                    put(.node(made), at: frame.indexInParent, in: &stack[stack.count - 1])
                }
                continue
            }
            let index = stack[top].next
            let child = stack[top].new.children[index]
            let offset = stack[top].childOffset
            stack[top].next += 1
            stack[top].childOffset += child.byteLength
            guard case .node(let node) = child else { continue }
            guard let (counterpart, oldOffset) = counterpart(of: node, at: offset, in: &stack[top], edit: edit) else {
                stats.nodes += countNodes(node)
                continue
            }
            if texts.same(new: offset..<(offset + node.byteLength), old: oldOffset..<(oldOffset + counterpart.byteLength)),
               let shared = equalCount(node, counterpart) {
                stats.nodes += shared
                stats.sharedNodes += shared
                stats.sharedSubtrees += 1
                stats.sharedBytes += counterpart.byteLength
                put(.node(counterpart), at: index, in: &stack[top])
                continue
            }
            // Different: its children may still match.
            stats.nodes += 1
            stack.append(Frame(new: node, old: counterpart, newOffset: offset, oldOffset: oldOffset, indexInParent: index))
        }
        return result
    }

    private static func put(_ child: SyntaxChild, at index: Int, in frame: inout Frame) {
        if frame.children == nil { frame.children = frame.new.children }
        frame.children![index] = child
    }

    /// The child of the frame's old node that stands where `node` (at `offset` in the new text) stands, of the same
    /// kind: before the edit at the same offset, after it moved by the edit. A node that starts inside the inserted
    /// text has none.
    private static func counterpart(of node: SyntaxNode, at offset: Int, in frame: inout Frame,
                                    edit: SyntaxTextEdit) -> (SyntaxNode, Int)? {
        let wanted: Int
        if offset <= edit.start {
            wanted = offset
        } else if offset >= edit.newEnd {
            wanted = offset - edit.delta
        } else {
            return nil
        }
        let old = frame.old.children
        // Pass the old children that start before the wanted offset.
        while frame.oldNext < old.count, frame.oldChildOffset < wanted {
            frame.oldChildOffset += old[frame.oldNext].byteLength
            frame.oldNext += 1
        }
        // Of the children that start there (empty nodes share their start), the first of the same kind.
        var k = frame.oldNext
        var at = frame.oldChildOffset
        while k < old.count, at == wanted {
            if case .node(let candidate) = old[k], candidate.kind == node.kind, candidate.foreignKind == node.foreignKind {
                // Later children of the new node are looked for after this one.
                frame.oldNext = k + 1
                frame.oldChildOffset = at + candidate.byteLength
                return (candidate, at)
            }
            at += old[k].byteLength
            k += 1
        }
        return nil
    }

    /// The number of nodes of `a` when `a` and `b` are equal in kind, foreign kind and every token (text, trivia,
    /// presence, flags, unit) all the way down; nil otherwise.
    static func equalCount(_ a: SyntaxNode, _ b: SyntaxNode) -> Int? {
        if a === b { return countNodes(a) }
        var count = 0
        var stack: [(SyntaxNode, SyntaxNode)] = [(a, b)]
        while let (x, y) = stack.popLast() {
            count += 1
            if x === y {
                count += countNodes(x) - 1
                continue
            }
            guard x.kind == y.kind, x.byteLength == y.byteLength, x.foreignKind == y.foreignKind,
                  x.children.count == y.children.count else { return nil }
            for k in x.children.indices {
                switch (x.children[k], y.children[k]) {
                case (.token(let s), .token(let t)):
                    guard s == t else { return nil }
                case (.node(let m), .node(let n)):
                    stack.append((m, n))
                default:
                    return nil
                }
            }
        }
        return count
    }

    /// The nodes of a subtree, its root included.
    static func countNodes(_ node: SyntaxNode) -> Int {
        var count = 0
        var stack = [node]
        while let n = stack.popLast() {
            count += 1
            for child in n.children {
                if case .node(let c) = child { stack.append(c) }
            }
        }
        return count
    }

    /// Whether two trees are equal node for node and token for token (the check that sharing changed nothing).
    static func identical(_ a: SyntaxTree, _ b: SyntaxTree) -> Bool {
        equalCount(a.root, b.root) != nil
    }
}

extension Desk {
    /// Parses `text` as the next state of `previous`: a full parse whose unchanged subtrees are `previous`'s nodes
    /// (so their identity survives the edit). Equal to `parse(text, file:)` in every node and token.
    public static func reparse(_ text: String, previous: SyntaxTree) -> (tree: SyntaxTree, stats: SubtreeReuseStats) {
        let fresh = parse(text, file: previous.file)
        let old = Array(previous.text.utf8), new = Array(text.utf8)
        return SubtreeReuse.share(fresh, previous: previous, edit: SyntaxTextEdit.between(old, new), newBytes: new,
                                  oldBytes: old)
    }
}
