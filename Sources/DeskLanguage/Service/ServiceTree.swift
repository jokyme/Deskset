import Foundation

// Tree lookups the service does on every request, without walking whole subtrees: `PositionedNode.textRange` and
// `SyntaxTree.resolve` visit every token of a node, which costs a whole file for the widget's root element.

extension SyntaxNode {
    /// Visits every token from the last to the first with the offset where its leading trivia starts (`end` is where
    /// the node ends), without recursion. Return false to stop.
    func walkTokensBackward(end: Int, _ visit: (Token, Int) -> Bool) {
        var stack: [(node: SyntaxNode, next: Int, end: Int)] = [(self, children.count - 1, end)]
        while !stack.isEmpty {
            let (node, index, childEnd) = stack[stack.count - 1]
            if index < 0 {
                stack.removeLast()
                continue
            }
            let child = node.children[index]
            let childStart = childEnd - child.byteLength
            stack[stack.count - 1] = (node, index - 1, childStart)
            switch child {
            case .token(let t):
                if !visit(t, childStart) { return }
            case .node(let n):
                stack.append((n, n.children.count - 1, childEnd))
            }
        }
    }
}

extension PositionedNode {
    /// Where the first present token's text starts; the node's offset when it has no present token.
    var quickTextStart: Int {
        var start = offset
        node.walkTokens(base: offset) { token, at in
            guard !token.isMissing else { return true }
            start = at + token.leadingTrivia.utf8Length
            return false
        }
        return start
    }

    /// `textRange`, visiting only the tokens up to the first and from the last present one.
    var quickTextRange: Range<Int> {
        var start: Int?
        node.walkTokens(base: offset) { token, at in
            guard !token.isMissing else { return true }
            start = at + token.leadingTrivia.utf8Length
            return false
        }
        guard let start else { return offset..<offset }
        var end = start
        node.walkTokensBackward(end: offset + node.byteLength) { token, at in
            guard !token.isMissing else { return true }
            end = at + token.leadingTrivia.utf8Length + token.text.utf8.count
            return false
        }
        return start..<max(start, end)
    }
}

extension SyntaxTree {
    /// `resolve`, descending only into the nodes that hold the reference's position.
    func quickResolve(_ id: NodeID) -> PositionedNode? {
        guard id.treeVersion == version else { return nil }
        var stack: [PositionedNode] = [rootNode]
        while let current = stack.popLast() {
            if current.kind == id.kind, current.quickTextStart == id.utf8Start,
               id.utf8End == nil || id.utf8End == current.quickTextRange.upperBound { return current }
            var holding: [PositionedNode] = []
            var at = current.offset
            for child in current.node.children {
                let length = child.byteLength
                if case .node(let n) = child, at <= id.utf8Start, id.utf8Start <= at + length {
                    holding.append(PositionedNode(node: n, offset: at))
                }
                at += length
                if at > id.utf8Start { break }
            }
            stack.append(contentsOf: holding.reversed())
        }
        return nil
    }
}
