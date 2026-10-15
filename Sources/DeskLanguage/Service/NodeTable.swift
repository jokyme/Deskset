import Foundation

// Every node of a tree with its position, found in one walk. Navigation looks nodes up by `NodeID` (the checker's
// keys) and by position many times per request; `SyntaxTree.resolve` and `PositionedNode.textRange` walk whole
// subtrees each time, which costs a whole file for the widget's root element.

/// The nodes of one tree in document order (pre-order), each with its offsets and the range of its subtree.
struct DeskNodeTable: Sendable {
    struct Entry: Sendable {
        let node: SyntaxNode
        /// Where the node's leading trivia starts.
        let offset: Int
        /// From the first present token's text to the last one's; `offset..<offset` when it has none.
        var textStart: Int
        var textEnd: Int
        /// The enclosing node's index; -1 for the file.
        let parent: Int
        /// The index after the node's last descendant.
        var end: Int

        var kind: SyntaxKind { node.kind }
        var textRange: Range<Int> { textStart..<max(textStart, textEnd) }
        var positioned: PositionedNode { PositionedNode(node: node, offset: offset) }
    }

    let version: Int
    let entries: [Entry]
    /// The indexes of the file's top-level nodes, in order (a file of stray braces has thousands).
    let topLevel: [Int]
    /// Node indexes by the checker's key. Canonical expression keys include their text ends; recovery nodes with
    /// identical spans or non-expression start-only keys may still name several nodes, outermost first.
    let byID: [NodeID: [Int]]

    init(tree: SyntaxTree) {
        version = tree.version
        var entries: [Entry] = []
        var tokensBefore: [Int] = []          // present tokens seen when each node was entered
        var stack: [(entry: Int, child: Int, offset: Int)] = []
        var pending: [Int] = []               // entered nodes that have not met a present token yet
        var presentTokens = 0
        var lastEnd = 0

        entries.append(Entry(node: tree.root, offset: 0, textStart: 0, textEnd: 0, parent: -1, end: 0))
        tokensBefore.append(0)
        pending.append(0)
        stack.append((0, 0, 0))
        while let top = stack.last {
            let node = entries[top.entry].node
            if top.child >= node.children.count {
                stack.removeLast()
                let e = top.entry
                if pending.last == e {
                    pending.removeLast()
                    entries[e].textStart = entries[e].offset
                    entries[e].textEnd = entries[e].offset
                } else {
                    entries[e].textEnd = tokensBefore[e] < presentTokens ? lastEnd : entries[e].textStart
                }
                entries[e].end = entries.count
                continue
            }
            let child = node.children[top.child]
            stack[stack.count - 1].child += 1
            stack[stack.count - 1].offset += child.byteLength
            switch child {
            case .token(let token):
                guard !token.isMissing else { continue }
                let start = top.offset + token.leadingTrivia.utf8Length
                for p in pending { entries[p].textStart = start }
                pending.removeAll(keepingCapacity: true)
                lastEnd = start + token.text.utf8.count
                presentTokens += 1
            case .node(let n):
                let index = entries.count
                entries.append(Entry(node: n, offset: top.offset, textStart: top.offset, textEnd: top.offset,
                                     parent: top.entry, end: index + 1))
                tokensBefore.append(presentTokens)
                pending.append(index)
                stack.append((index, 0, top.offset))
            }
        }
        var byID: [NodeID: [Int]] = [:]
        byID.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() {
            let id: NodeID
            if entry.kind.isExpression {
                id = NodeID(kind: entry.kind, utf8Start: entry.textStart, treeVersion: tree.version,
                            utf8End: entry.textRange.upperBound)
            } else {
                id = NodeID(kind: entry.kind, utf8Start: entry.textStart, treeVersion: tree.version)
            }
            byID[id, default: []].append(i)
        }
        self.entries = entries
        self.byID = byID
        var top: [Int] = []
        var i = 1
        while i < entries.count {
            top.append(i)
            i = entries[i].end
        }
        topLevel = top
    }

    /// The top-level node `node` that starts (with its leading trivia) at `offset`.
    func topLevelEntry(at offset: Int, node: SyntaxNode) -> Int? {
        var low = 0, high = topLevel.count
        while low < high {
            let mid = (low + high) / 2
            if entries[topLevel[mid]].offset < offset { low = mid + 1 } else { high = mid }
        }
        // Nodes of no length share an offset with the next one.
        while low < topLevel.count, entries[topLevel[low]].offset == offset {
            if entries[topLevel[low]].node === node { return topLevel[low] }
            low += 1
        }
        return nil
    }

    /// The nodes a checker key may name, outermost first (empty for a key of another tree).
    func indexes(of id: NodeID) -> [Int] {
        guard id.treeVersion == version else { return [] }
        return byID[id] ?? []
    }

    /// The outermost node a key names.
    func entry(_ id: NodeID) -> Entry? {
        indexes(of: id).first.map { entries[$0] }
    }

    func id(_ index: Int) -> NodeID {
        let entry = entries[index]
        if entry.kind.isExpression {
            return NodeID(kind: entry.kind, utf8Start: entry.textStart, treeVersion: version,
                          utf8End: entry.textRange.upperBound)
        }
        return NodeID(kind: entry.kind, utf8Start: entry.textStart, treeVersion: version)
    }

    /// The indexes of the node's enclosing nodes, innermost first.
    func ancestors(of index: Int) -> [Int] {
        var out: [Int] = []
        var p = entries[index].parent
        while p >= 0 {
            out.append(p)
            p = entries[p].parent
        }
        return out
    }

    /// The direct child nodes of a node.
    func children(of index: Int) -> [Int] {
        var out: [Int] = []
        var i = index + 1
        while i < entries[index].end {
            out.append(i)
            i = entries[i].end
        }
        return out
    }

    /// The direct child nodes of `index` whose full range (trivia included) holds `offset` or ends at it, in order.
    /// The file's top-level nodes are found by binary search (a file of stray braces has thousands of them).
    func children(of index: Int, near offset: Int) -> [Int] {
        guard index == 0 else { return children(of: index) }
        var low = 0, high = topLevel.count
        while low < high {
            let mid = (low + high) / 2
            if entries[topLevel[mid]].offset <= offset { low = mid + 1 } else { high = mid }
        }
        // `low` is the first top-level node that starts after `offset`; the ones before it that reach `offset` are
        // the candidates (nodes never overlap, so they are the last few).
        var first = low
        while first > 0, entries[topLevel[first - 1]].offset + entries[topLevel[first - 1]].node.byteLength >= offset { first -= 1 }
        return Array(topLevel[first..<low])
    }

    /// The innermost node whose text (trivia excluded) holds `offset` or ends at it, walking down from the file.
    /// A node whose text ends at `offset` counts only when no node's text holds it (a cursor right after a name).
    func innermost(at offset: Int, where accept: (Entry) -> Bool = { _ in true }) -> Int? {
        var found: Int?
        var current = 0
        while true {
            var next: Int?
            var touching: Int?
            for child in children(of: current, near: offset) {
                let e = entries[child]
                if e.textStart <= offset && offset < e.textEnd { next = child; break }
                if e.textEnd == offset && e.textStart < e.textEnd { touching = child }
                if e.offset > offset { break }
            }
            guard let chosen = next ?? touching else { return found }
            if accept(entries[chosen]) { found = chosen }
            current = chosen
        }
    }
}
