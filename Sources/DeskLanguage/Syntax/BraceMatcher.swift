import Foundation

/// How every `{` of a file is closed, decided before parsing.
///
/// Braces are counted first: when every `{` has its `}`, the structure is exactly what was written, however the
/// file is indented. Only when counting fails does indentation decide, segment by segment (a segment starts at a
/// line that begins in column 0 with a block word and a block header), where a missing `}` goes and which `}` is the
/// extra one. The indentation result is kept only when it agrees with counting on how many are missing and extra
/// and nests properly; otherwise each missing `}` goes at the end of its segment.
struct BraceMatching {
    enum Close: Equatable {
        /// Closed by the `}` token at this index.
        case token(Int)
        /// Left open: a virtual `}` goes right before the token at this index (or the end of file).
        case virtual(before: Int)
    }

    /// For every `{` token index, how it is closed.
    var closes: [Int: Close] = [:]
    /// `}` tokens that close nothing.
    var extra: Set<Int> = []
    /// Indentation of the statement that owns each `{` (only computed for repaired segments).
    var openerIndent: [Int: Int] = [:]
    /// UTF-8 ranges of the segments that were repaired.
    var repairedSegments: [Range<Int>] = []

    static func match(_ lexed: LexedFile, lines: LineTable) -> BraceMatching {
        let tokens = lexed.tokens
        var result = BraceMatching()
        // 1. Counting.
        var stack: [Int] = []
        var unmatched: [Int] = []
        for i in tokens.indices {
            switch tokens[i].kind {
            case .lBrace: stack.append(i)
            case .rBrace:
                if let open = stack.popLast() { result.closes[open] = .token(i) } else { unmatched.append(i) }
            default: break
            }
        }
        if stack.isEmpty && unmatched.isEmpty { return result }

        // 2. Segment by segment.
        result.closes = [:]
        let context = Context(lexed: lexed, lines: lines)
        let headers = context.segmentHeaders()
        var bounds = [0] + headers.filter { $0 > 0 } + [tokens.count - 1]   // the eof token ends the last segment
        bounds = Array(Set(bounds)).sorted()
        for k in 0..<(bounds.count - 1) {
            let segment = bounds[k]..<bounds[k + 1]
            context.matchSegment(segment, into: &result)
        }
        return result
    }

    /// Everything the repair needs about lines and tokens.
    private struct Context {
        let lexed: LexedFile
        let lines: LineTable
        let tokens: [Token]
        /// Line index of each token's text.
        let lineOf: [Int]
        /// Whether each token is the first present token on its line.
        let firstOnLine: [Bool]

        init(lexed: LexedFile, lines: LineTable) {
            self.lexed = lexed
            self.lines = lines
            self.tokens = lexed.tokens
            var lineOf = [Int](repeating: 0, count: lexed.tokens.count)
            var first = [Bool](repeating: false, count: lexed.tokens.count)
            var previousLine = -1
            for i in lexed.tokens.indices {
                let line = lines.lineIndex(of: lexed.starts[i])
                lineOf[i] = line
                if !lexed.tokens[i].isMissing, line != previousLine {
                    first[i] = true
                    previousLine = line
                }
                if lexed.tokens[i].kind != .eof, !lexed.tokens[i].isMissing {
                    // A token spanning lines (a block string) puts the following text on its last line.
                    let endLine = lines.lineIndex(of: lexed.starts[i] + lexed.tokens[i].text.utf8.count)
                    previousLine = max(previousLine, endLine)
                }
            }
            self.lineOf = lineOf
            self.firstOnLine = first
        }

        /// Token indices of segment headers: a block word in column 0 followed by a block header.
        func segmentHeaders() -> [Int] {
            var headers: [Int] = []
            for i in tokens.indices where firstOnLine[i] {
                let t = tokens[i]
                guard t.kind == .identifier, Chars.blockWords.contains(t.name),
                      lexed.starts[i] == lines.starts[lineOf[i]] else { continue }
                let next = i + 1 < tokens.count ? tokens[i + 1].kind : .eof
                switch t.name {
                case "style":
                    if next == .identifier, i + 2 < tokens.count, tokens[i + 2].kind == .lBrace { headers.append(i) }
                case "component":
                    if next == .identifier { headers.append(i) }
                case "script":
                    if next == .opaqueBlock || next == .lBrace { headers.append(i) }
                default:
                    if next == .lBrace { headers.append(i) }
                }
            }
            return headers
        }

        func indent(ofLine line: Int) -> Int { lines.indentation(ofLine: line) }

        func isContinuation(line: Int, first: Int, parenDepthAtLineStart: [Int: Int],
                            lastTokenOfLine: [Int: Int]) -> Bool {
            if (parenDepthAtLineStart[line] ?? 0) > 0 { return true }
            switch tokens[first].kind {
            case .andKeyword, .orKeyword, .plus, .minus, .star, .slash, .percent, .equalEqual, .bangEqual, .less,
                 .lessEqual, .greater, .greaterEqual, .ellipsis, .question, .colon, .ampAmp, .pipePipe,
                 .questionQuestion, .rParen, .rBracket, .lBrace:
                return true
            default:
                break
            }
            var previous = line - 1
            while previous >= 0, lastTokenOfLine[previous] == nil { previous -= 1 }
            guard previous >= 0, let last = lastTokenOfLine[previous] else { return false }
            switch tokens[last].kind {
            case .andKeyword, .orKeyword, .plus, .minus, .star, .slash, .percent, .equalEqual, .bangEqual, .less,
                 .lessEqual, .greater, .greaterEqual, .ellipsis, .question, .colon, .equal, .lParen, .lBracket,
                 .comma, .ampAmp, .pipePipe, .questionQuestion:
                return true
            default:
                return false
            }
        }

        func matchSegment(_ segment: Range<Int>, into result: inout BraceMatching) {
            // Counting within the segment.
            var stack: [Int] = []
            var unmatched: [Int] = []
            var counted: [Int: Close] = [:]
            for i in segment {
                switch tokens[i].kind {
                case .lBrace: stack.append(i)
                case .rBrace:
                    if let open = stack.popLast() { counted[open] = .token(i) } else { unmatched.append(i) }
                default: break
                }
            }
            if stack.isEmpty && unmatched.isEmpty {
                result.closes.merge(counted) { a, _ in a }
                return
            }
            let segmentStart = lexed.starts[segment.lowerBound] - tokens[segment.lowerBound].leadingTrivia.utf8Length
            let endToken = segment.upperBound
            let segmentEnd = endToken < tokens.count
                ? lexed.starts[endToken] - tokens[endToken].leadingTrivia.utf8Length : lines.bytes.count
            result.repairedSegments.append(max(0, segmentStart)..<max(segmentStart, segmentEnd))

            // Line facts for the segment.
            var firstTokenOfLine: [Int: Int] = [:]
            var lastTokenOfLine: [Int: Int] = [:]
            var parenDepthAtLineStart: [Int: Int] = [:]
            var depth = 0
            for i in segment where !tokens[i].isMissing {
                let line = lineOf[i]
                if firstOnLine[i] {
                    firstTokenOfLine[line] = i
                    parenDepthAtLineStart[line] = depth
                }
                lastTokenOfLine[line] = i
                switch tokens[i].kind {
                case .lParen, .lBracket: depth += 1
                case .rParen, .rBracket: depth = max(0, depth - 1)
                case .lBrace, .rBrace: depth = 0
                default: break
                }
            }
            // The first line of the statement each line belongs to: a continuation line takes the base of the line
            // above, computed in one pass (walking back from every `{` would be quadratic).
            var baseLine: [Int: Int] = [:]
            var previousLine: Int?
            for line in firstTokenOfLine.keys.sorted() {
                if let previous = previousLine, let first = firstTokenOfLine[line],
                   isContinuation(line: line, first: first, parenDepthAtLineStart: parenDepthAtLineStart,
                                  lastTokenOfLine: lastTokenOfLine) {
                    baseLine[line] = baseLine[previous] ?? previous
                } else {
                    baseLine[line] = line
                }
                previousLine = line
            }
            var indents: [Int: Int] = [:]
            for i in segment where tokens[i].kind == .lBrace {
                indents[i] = indent(ofLine: baseLine[lineOf[i]] ?? lineOf[i])
            }
            result.openerIndent.merge(indents) { a, _ in a }

            // Matching with indentation.
            struct Opener { var index: Int; var indent: Int; var contentLine: Int?; var indented: Bool }
            var open: [Opener] = []
            var closes: [Int: Close] = [:]
            var extra: Set<Int> = []
            var virtualCount = 0
            let sortedLines = firstTokenOfLine.keys.sorted()
            // For each line with tokens: its indentation, or no candidate when it starts with `else`; a tree of
            // minimums finds the first later line indented no deeper than an opener in logarithmic time.
            let lineIndents = sortedLines.map { line -> Int in
                tokens[firstTokenOfLine[line]!].kind == .elseKeyword ? Int.max : indent(ofLine: line)
            }
            let minimums = MinimumTree(lineIndents)

            func virtualPosition(for opener: Opener, limitToken: Int) -> Int {
                let fromLine = opener.contentLine ?? lineOf[opener.index]
                // The first listed line after `fromLine`.
                var low = 0
                var high = sortedLines.count
                while low < high {
                    let mid = (low + high) / 2
                    if sortedLines[mid] <= fromLine { low = mid + 1 } else { high = mid }
                }
                if let found = minimums.firstIndex(from: low, atMost: opener.indent),
                   let first = firstTokenOfLine[sortedLines[found]], first <= limitToken {
                    return first
                }
                return min(limitToken, endToken)
            }

            for i in segment where !tokens[i].isMissing {
                let line = lineOf[i]
                if firstOnLine[i], tokens[i].kind != .rBrace, var top = open.last, top.contentLine == nil,
                   line > lineOf[top.index] {
                    top.contentLine = line
                    top.indented = indent(ofLine: line) > top.indent
                    open[open.count - 1] = top
                }
                switch tokens[i].kind {
                case .lBrace:
                    open.append(Opener(index: i, indent: indents[i] ?? 0, contentLine: nil, indented: false))
                case .rBrace:
                    if firstOnLine[i] {
                        let d = indent(ofLine: line)
                        while true {
                            guard let top = open.last else { extra.insert(i); break }
                            if top.contentLine != nil, top.indented {
                                if d < top.indent {
                                    closes[top.index] = .virtual(before: virtualPosition(for: top, limitToken: i))
                                    virtualCount += 1
                                    open.removeLast()
                                    continue
                                }
                                if d > top.indent { extra.insert(i); break }
                            }
                            open.removeLast()
                            closes[top.index] = .token(i)
                            break
                        }
                    } else if let top = open.popLast() {
                        closes[top.index] = .token(i)
                    } else {
                        extra.insert(i)
                    }
                default:
                    break
                }
            }
            while let top = open.popLast() {
                closes[top.index] = .virtual(before: virtualPosition(for: top, limitToken: endToken))
                virtualCount += 1
            }

            if virtualCount == stack.count, extra.count == unmatched.count, BraceMatching.nests(closes) {
                result.closes.merge(closes) { a, _ in a }
                result.extra.formUnion(extra)
                return
            }
            // Fall back to counting: missing `}` at the end of the segment, innermost first.
            for open in stack { counted[open] = .virtual(before: endToken) }
            result.closes.merge(counted) { a, _ in a }
            result.extra.formUnion(unmatched)
        }
    }

    /// Whether the blocks nest: each block ends no later than the block around it.
    static func nests(_ closes: [Int: Close]) -> Bool {
        // A block `{` at i closed by `}` at j spans [i, j + 1); one closed before token k spans [i, k).
        let spans = closes.map { (open, close) -> (Int, Int) in
            switch close {
            case .token(let j): return (open, j + 1)
            case .virtual(let k): return (open, k)
            }
        }.sorted { $0.0 < $1.0 }
        var stack: [(Int, Int)] = []
        for span in spans {
            while let top = stack.last, top.1 <= span.0 { stack.removeLast() }
            if let top = stack.last, span.1 > top.1 { return false }
            if span.1 < span.0 + 1 && span.1 != span.0 { return false }
            stack.append(span)
        }
        return true
    }
}

/// Minimums over an array, to find the first position at or after `from` whose value is at most a bound.
struct MinimumTree {
    private var tree: [Int]
    private let size: Int

    init(_ values: [Int]) {
        var size = 1
        while size < max(1, values.count) { size *= 2 }
        self.size = size
        tree = [Int](repeating: Int.max, count: 2 * size)
        for (k, value) in values.enumerated() { tree[size + k] = value }
        var k = size - 1
        while k >= 1 {
            tree[k] = min(tree[2 * k], tree[2 * k + 1])
            k -= 1
        }
    }

    /// The first index ≥ `from` whose value is ≤ `bound`.
    func firstIndex(from: Int, atMost bound: Int) -> Int? {
        guard from < size else { return nil }
        return search(node: 1, low: 0, high: size, from: from, bound: bound)
    }

    private func search(node: Int, low: Int, high: Int, from: Int, bound: Int) -> Int? {
        if high <= from || tree[node] > bound { return nil }
        if high - low == 1 { return low }
        let mid = (low + high) / 2
        if let left = search(node: 2 * node, low: low, high: mid, from: from, bound: bound) { return left }
        return search(node: 2 * node + 1, low: mid, high: high, from: from, bound: bound)
    }
}
