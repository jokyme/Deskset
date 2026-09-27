import Foundation

/// A parsed expression and the tokens it spans (`start...end`; `end < start` when nothing was consumed), so fix-its
/// can quote and rewrite its text.
struct ParsedExpression {
    var node: SyntaxNode
    var start: Int
    var end: Int
    /// An unparenthesized `and` (for DK2033).
    var isAnd = false

    var isMissing: Bool { end < start }
}

extension Parser {
    // MARK: - Entry points

    /// An expression (§2.9). Nothing is reported when no expression starts here; callers decide what was expected.
    mutating func parseExpr(condition: Bool = false) -> ParsedExpression {
        if expressionDepth >= SyntaxLimits.maxExpressionDepth { return skipDeepExpression() }
        expressionDepth += 1
        defer {
            expressionDepth -= 1
            if expressionDepth == 0 { suppressMissing = false }
        }
        return parseTernary(condition: condition)
    }

    /// An expression that must be there; DK2005 names the slot when it is not.
    mutating func parseRequiredExpression(_ slot: SyntaxSlot) -> SyntaxNode {
        let value = parseExpr()
        if value.isMissing { expected(slot) }
        return value.node
    }

    /// Whether token `j` can start an expression.
    func startsExpression(_ j: Int) -> Bool {
        switch kind(j) {
        case .number, .stringStart, .rawString, .tripleQuoteString, .trueKeyword, .falseKeyword, .identifier,
             .invalidIdentifier, .eventKeyword, .dot, .lBracket, .lParen, .minus, .notKeyword, .bang, .tilde,
             .hexColor, .hexNumber, .rainmeterVariable, .plus:
            return true
        case .dollar:
            return isNameLike(j + 1) && tokens[j].trailingTrivia.isEmpty
        default:
            return false
        }
    }

    /// Past the nesting limit: the rest of this expression, up to its closing bracket, is one unexpected node.
    mutating func skipDeepExpression() -> ParsedExpression {
        let start = i
        suppressMissing = true
        if !depthReported, i < limit {
            depthReported = true
            report(.nestingTooDeep, .error, textRange(i), ["limit": .number(SyntaxLimits.maxExpressionDepth)])
        }
        var children: [SyntaxChild] = []
        var depth = 0
        while i < limit {
            let k = kind(i)
            if depth == 0 && (k == .rParen || k == .rBracket || k == .comma || k == .rBrace || k == .semicolon) { break }
            if depth == 0 && k == .lBrace { break }
            if nl(i) && depth == 0 && !children.isEmpty && canStartDeskStatement(i) { break }
            switch k {
            case .lParen, .lBracket: depth += 1
            case .rParen, .rBracket: depth -= 1
            case .lBrace:
                // A block inside a skipped expression (never valid) keeps its braces together.
                let close = braces.closes[i]
                children.append(take())
                let end: Int
                switch close {
                case .token(let j)?: end = min(j + 1, limit)
                case .virtual(let v)?: end = min(v, limit)
                case nil: end = limit
                }
                while i < end { children.append(take()) }
                continue
            default: break
            }
            children.append(take())
        }
        if children.isEmpty { return ParsedExpression(node: missingExpression(), start: start, end: start - 1) }
        return ParsedExpression(node: node(.unexpected, children), start: start, end: i - 1)
    }

    /// Whether one more chain link (a binary operator, a member access, a call) would pass the nesting limit. Each
    /// link nests the tree one level deeper on its left side, and the checker and the formatter recurse once per
    /// level, so links count toward the limit like brackets do (DK2028).
    var chainAtLimit: Bool { expressionDepth >= SyntaxLimits.maxExpressionDepth }

    /// Past the limit: `left` and the rest of the expression become one unexpected node.
    mutating func skipLongChain(_ left: ParsedExpression, from start: Int) -> ParsedExpression {
        let rest = skipDeepExpression()
        if rest.isMissing { return left }
        return ParsedExpression(node: node(.unexpected, [.node(left.node), .node(rest.node)]), start: start, end: i - 1)
    }

    // MARK: - Precedence levels

    mutating func parseTernary(condition: Bool) -> ParsedExpression {
        let start = i
        var value = parseOr(condition: condition)
        if value.isMissing { return value }
        switch kind(i) {
        case .question:
            let question = take()
            let then = parseNestedOperand(after: i - 1)
            var children: [SyntaxChild] = [.node(value.node), question, .node(then.node)]
            if kind(i) == .colon {
                children.append(take())
            } else {
                children.append(missing(.colon))
                if !then.isMissing { expected(.colon, insert: " :") }
            }
            let otherwise = parseNestedOperand(after: i - 1)
            children.append(.node(otherwise.node))
            value = ParsedExpression(node: node(.ternaryExpr, children), start: start, end: i - 1)
        case .questionQuestion:
            let opIndex = i
            let op = take()
            let right = parseNestedOperand(after: opIndex)
            let result = ParsedExpression(node: node(.binaryExpr, [.node(value.node), op, .node(right.node)]),
                                          start: start, end: i - 1)
            if !right.isMissing {
                let left = parenthesizedIfNeeded(value)
                let fixed = "\(left).ifMissing(\(text(right.start, right.end)))"
                report(.nilCoalescing, .error, textRange(opIndex), ["fixed": .code(fixed)],
                       fixIts: [FixIt(titleKey: "rewrite", edits: [edit(starts[start]..<textEnd(right.end), fixed)])])
            }
            value = result
        default:
            break
        }
        // Lambdas and return types (`x => x * 2`, `-> Int`): Desk has no functions (DK9012).
        if kind(i) == .fatArrow || kind(i) == .arrow {
            let opIndex = i
            report(.functionSyntax, .error, textRange(opIndex))
            var rest: [SyntaxChild] = [.node(value.node)]
            while i < limit && sameLine(i) && !isExpressionStop(i) { rest.append(take()) }
            value = ParsedExpression(node: node(.unexpected, rest), start: start, end: i - 1)
        }
        return value
    }

    /// Tokens that end an expression in any context: closers, separators, blocks.
    func isExpressionStop(_ j: Int) -> Bool {
        switch kind(j) {
        case .rParen, .rBracket, .rBrace, .comma, .semicolon, .lBrace, .eof, .interpolationEnd: return true
        default: return false
        }
    }

    /// The operand of a ternary branch or a `??`, one nesting level deeper.
    mutating func parseNestedOperand(after opIndex: Int) -> ParsedExpression {
        let value = parseExpr()
        if value.isMissing { reportMissingOperand(opIndex) }
        return value
    }

    mutating func reportMissingOperand(_ opIndex: Int) {
        if suppressMissing { return }
        report(.missingOperand, .error, textRange(opIndex), ["op": .code(tokens[opIndex].text)])
    }

    /// `or` level; also `||` (DK9002) and `|`, `^` (reported by the checker, DK9008 or DK5023).
    mutating func parseOr(condition: Bool) -> ParsedExpression {
        let start = i
        var left = parseAnd(condition: condition)
        if left.isMissing { return left }
        var andOperands: [ParsedExpression] = left.isAnd ? [left] : []
        var sawOr = false
        var links = 0
        defer { expressionDepth -= links }
        while let opKind = orOperator(at: i) {
            if chainAtLimit { left = skipLongChain(left, from: start); break }
            let opIndex = i
            if opKind == .identifier, let keyword = keywordVariant(i) { reportCaseVariant(i, keyword) }
            let op = take()
            var right = parseAnd(condition: condition)
            if right.isMissing {
                reportMissingOperand(opIndex)
                right = ParsedExpression(node: missingExpression(), start: i, end: i - 1)
            } else if right.isAnd {
                andOperands.append(right)
            }
            if kind(opIndex) == .pipePipe || tokens[opIndex].kind == .pipePipe {
                reportSymbolicOperator(opIndex, word: "or", id: .symbolicOr, left: left, right: right)
            }
            left = ParsedExpression(node: node(.binaryExpr, [.node(left.node), op, .node(right.node)]),
                                    start: start, end: i - 1)
            links += 1
            expressionDepth += 1
            if tokens[opIndex].kind != .pipe && tokens[opIndex].kind != .caret { sawOr = true }
        }
        if sawOr && !andOperands.isEmpty { reportMixedAndOr(whole: left, andOperands: andOperands) }
        return left
    }

    func orOperator(at j: Int) -> TokenKind? {
        switch kind(j) {
        case .orKeyword, .pipePipe, .pipe, .caret: return kind(j)
        case .identifier where keywordVariant(j) == .orKeyword: return .identifier
        default: return nil
        }
    }

    /// `and` level; also `&&` (DK9001) and `&` (reported by the checker).
    mutating func parseAnd(condition: Bool) -> ParsedExpression {
        let start = i
        var left = parseNot(condition: condition)
        if left.isMissing { return left }
        var isAnd = false
        var links = 0
        defer { expressionDepth -= links }
        while let opKind = andOperator(at: i) {
            if chainAtLimit { left = skipLongChain(left, from: start); break }
            let opIndex = i
            if opKind == .identifier, let keyword = keywordVariant(i) { reportCaseVariant(i, keyword) }
            let op = take()
            var right = parseNot(condition: condition)
            if right.isMissing {
                reportMissingOperand(opIndex)
                right = ParsedExpression(node: missingExpression(), start: i, end: i - 1)
            }
            if tokens[opIndex].kind == .ampAmp {
                reportSymbolicOperator(opIndex, word: "and", id: .symbolicAnd, left: left, right: right)
            }
            left = ParsedExpression(node: node(.binaryExpr, [.node(left.node), op, .node(right.node)]),
                                    start: start, end: i - 1)
            links += 1
            expressionDepth += 1
            if tokens[opIndex].kind != .amp { isAnd = true }
        }
        left.isAnd = isAnd
        return left
    }

    func andOperator(at j: Int) -> TokenKind? {
        switch kind(j) {
        case .andKeyword, .ampAmp, .amp: return kind(j)
        case .identifier where keywordVariant(j) == .andKeyword: return .identifier
        default: return nil
        }
    }

    /// DK9001 / DK9002: `&&` and `||` are written `and` and `or`.
    mutating func reportSymbolicOperator(_ opIndex: Int, word: String, id: DiagnosticID, left: ParsedExpression,
                                         right: ParsedExpression) {
        let fixed = right.isMissing ? "\(text(left.start, left.end)) \(word)"
            : "\(text(left.start, left.end)) \(word) \(text(right.start, right.end))"
        // Keep one space on each side of the word.
        let before = opIndex > 0 && tokens[opIndex - 1].trailingTrivia.isEmpty && tokens[opIndex].leadingTrivia.isEmpty
        let after = tokens[opIndex].trailingTrivia.isEmpty
        let replacement = (before ? " " : "") + word + (after ? " " : "")
        report(id, .error, textRange(opIndex), ["fixed": .code(fixed)],
               fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(word)],
                              edits: [edit(textRange(opIndex), replacement)], group: "symbolicOperators")])
    }

    /// DK2033: `and` binds tighter than `or`; the fix-it writes the parentheses Desk applies.
    mutating func reportMixedAndOr(whole: ParsedExpression, andOperands: [ParsedExpression]) {
        var edits: [TextEdit] = []
        var fixed = ""
        var cursor = starts[whole.start]
        let end = textEnd(whole.end)
        for operand in andOperands {
            let a = starts[operand.start]
            let b = textEnd(operand.end)
            fixed += text(cursor..<a) + "(" + text(a..<b) + ")"
            cursor = b
            edits.append(edit(a..<a, "("))
            edits.append(edit(b..<b, ")"))
        }
        fixed += text(cursor..<end)
        report(.mixedAndOr, .warning, starts[whole.start]..<end, ["fixed": .code(fixed)],
               fixIts: [FixIt(titleKey: "insertParentheses", edits: edits)])
    }

    func isNotOperator(_ j: Int) -> Bool {
        kind(j) == .notKeyword || kind(j) == .bang || kind(j) == .tilde || keywordVariant(j) == .notKeyword
    }

    /// `not` (prefix, looser than comparison); also `!` (DK9003) and `~` (reported by the checker). A chain of
    /// prefix operators is read without recursion; its length counts toward the nesting limit.
    mutating func parseNot(condition: Bool) -> ParsedExpression {
        guard isNotOperator(i) else { return parseCompare(condition: condition) }
        var operators: [Int] = []
        while isNotOperator(i) {
            if expressionDepth + operators.count >= SyntaxLimits.maxExpressionDepth { break }
            if let keyword = keywordVariant(i) { reportCaseVariant(i, keyword) }
            operators.append(i)
            i += 1
        }
        let operand = isNotOperator(i) ? skipDeepExpression() : parseCompare(condition: condition)
        return buildPrefixChain(operators, operand)
    }

    /// Nests prefix operators around their operand, innermost last, and reports the diagnosed ones.
    mutating func buildPrefixChain(_ operators: [Int], _ operand: ParsedExpression) -> ParsedExpression {
        var value = operand
        for opIndex in operators.reversed() {
            if value.isMissing {
                reportMissingOperand(opIndex)
            } else if tokens[opIndex].kind == .bang {
                let fixed = "not " + text(value.start, value.end)
                let replacement = tokens[opIndex].trailingTrivia.isEmpty ? "not " : "not"
                report(.symbolicNot, .error, textRange(opIndex), ["fixed": .code(fixed)],
                       fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("not")],
                                      edits: [edit(textRange(opIndex), replacement)], group: "symbolicOperators")])
            } else if tokens[opIndex].kind == .plus {
                report(.unexpected, .error, textRange(opIndex), ["text": .code("+")],
                       fixIts: [FixIt(titleKey: "remove", edits: [edit(starts[opIndex]..<starts[value.start], "")])])
            }
            let end = value.isMissing ? opIndex : value.end
            value = ParsedExpression(node: node(.prefixExpr, [.token(tokens[opIndex]), .node(value.node)]),
                                     start: opIndex, end: end)
        }
        return value
    }

    /// Comparisons are not chainable (DK2025); `=` where a comparison belongs is DK2026.
    mutating func parseCompare(condition: Bool) -> ParsedExpression {
        let start = i
        var left = parseRange()
        if left.isMissing { return left }
        var operands: [ParsedExpression] = [left]
        var operators: [Int] = []
        var links = 0
        defer { expressionDepth -= links }
        while isCompareOperator(i) {
            if chainAtLimit { left = skipLongChain(left, from: start); return left }
            let opIndex = i
            let op = take()
            let right = parseRange()
            if right.isMissing { reportMissingOperand(opIndex) }
            if tokens[opIndex].kind == .equal && !right.isMissing {
                let fixed = "\(text(left.start, left.end)) == \(text(right.start, right.end))"
                report(.assignmentInCondition, .error, textRange(opIndex), ["fixed": .code(fixed)],
                       fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("==")],
                                      edits: [edit(textRange(opIndex), "==")])])
            }
            operands.append(right)
            operators.append(opIndex)
            left = ParsedExpression(node: node(.binaryExpr, [.node(left.node), op, .node(right.node)]),
                                    start: start, end: i - 1)
            links += 1
            expressionDepth += 1
        }
        if operators.count >= 2 && !operands.contains(where: \.isMissing) {
            // `a < b < c` → `a < b and b < c`.
            var parts: [String] = []
            for k in 0..<operators.count {
                let a = text(operands[k].start, operands[k].end)
                let b = text(operands[k + 1].start, operands[k + 1].end)
                parts.append("\(a) \(tokens[operators[k]].text) \(b)")
            }
            let fixed = parts.joined(separator: " and ")
            report(.chainedComparison, .error, textRange(operators[1]),
                   ["a": .code(parts[0]), "b": .code(parts[1]), "fixed": .code(fixed)],
                   fixIts: [FixIt(titleKey: "rewrite", edits: [edit(starts[start]..<textEnd(left.end), fixed)])])
        }
        return left
    }

    func isCompareOperator(_ j: Int) -> Bool {
        switch kind(j) {
        case .equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual: return true
        case .equal: return sameLine(j)
        default: return false
        }
    }

    /// `a...b`; also `..<` (DK9009) and `..` (DK2006).
    mutating func parseRange() -> ParsedExpression {
        let start = i
        let low = parseSum()
        if low.isMissing { return low }
        let k = kind(i)
        guard k == .ellipsis || k == .dotDot || k == .dotDotLess else { return low }
        let opIndex = i
        let op = take()
        let high = parseSum()
        if high.isMissing {
            reportMissingOperand(opIndex)
        } else if k == .dotDotLess {
            let a = text(low.start, low.end)
            let b = text(high.start, high.end)
            let last: String
            if high.start == high.end, tokens[high.start].kind == .number, tokens[high.start].unit == nil,
               let value = Int(tokens[high.start].text) {
                last = String(value - 1)
            } else {
                last = "\(b) - 1"
            }
            let fixed = "\(a)...\(last)"
            report(.halfOpenRange, .error, textRange(opIndex), ["a": .code(a), "last": .code(last)],
                   fixIts: [FixIt(titleKey: "rewrite", edits: [edit(starts[start]..<textEnd(high.end), fixed)])])
        } else if k == .dotDot {
            report(.unexpected, .error, textRange(opIndex), ["text": .code("..")],
                   fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code("...")],
                                  edits: [edit(textRange(opIndex), "...")])])
        }
        return ParsedExpression(node: node(.rangeExpr, [.node(low.node), op, .node(high.node)]), start: start, end: i - 1)
    }

    mutating func parseSum() -> ParsedExpression {
        let start = i
        var left = parseProduct()
        if left.isMissing { return left }
        var links = 0
        defer { expressionDepth -= links }
        while kind(i) == .plus || kind(i) == .minus {
            if chainAtLimit { left = skipLongChain(left, from: start); break }
            let opIndex = i
            let op = take()
            let right = parseProduct()
            if right.isMissing { reportMissingOperand(opIndex) }
            left = ParsedExpression(node: node(.binaryExpr, [.node(left.node), op, .node(right.node)]),
                                    start: start, end: i - 1)
            links += 1
            expressionDepth += 1
        }
        return left
    }

    /// `* / %`; also `**` (DK9007).
    mutating func parseProduct() -> ParsedExpression {
        let start = i
        var left = parsePrefix()
        if left.isMissing { return left }
        var links = 0
        defer { expressionDepth -= links }
        while kind(i) == .star || kind(i) == .slash || kind(i) == .percent || kind(i) == .starStar {
            if chainAtLimit { left = skipLongChain(left, from: start); break }
            let opIndex = i
            let leftSide = left
            let op = take()
            let right = parsePrefix()
            if right.isMissing {
                reportMissingOperand(opIndex)
            } else if tokens[opIndex].kind == .starStar {
                let a = text(leftSide.start, leftSide.end)
                let b = text(right.start, right.end)
                let fixed = "math.power(\(a), \(b))"
                report(.powerOperator, .error, textRange(opIndex), ["a": .code(a), "b": .code(b)],
                       fixIts: [FixIt(titleKey: "rewrite",
                                      edits: [edit(starts[leftSide.start]..<textEnd(right.end), fixed)])])
            }
            left = ParsedExpression(node: node(.binaryExpr, [.node(left.node), op, .node(right.node)]),
                                    start: start, end: i - 1)
            links += 1
            expressionDepth += 1
        }
        return left
    }

    /// Prefix `-`; a prefix `+` is not Desk (DK2006, fix-it remove). Read without recursion, like `not`.
    mutating func parsePrefix() -> ParsedExpression {
        guard kind(i) == .minus || kind(i) == .plus else { return parsePostfix() }
        var operators: [Int] = []
        while kind(i) == .minus || kind(i) == .plus {
            if expressionDepth + operators.count >= SyntaxLimits.maxExpressionDepth { break }
            operators.append(i)
            i += 1
        }
        let operand = (kind(i) == .minus || kind(i) == .plus) ? skipDeepExpression() : parsePostfix()
        return buildPrefixChain(operators, operand)
    }

    /// Member access and calls (§2.9 level 10). A `.` continues across a line break (N3); a `(` does not (N7),
    /// except inside brackets, where it is reported (DK2012) and kept as the call it was meant to be.
    mutating func parsePostfix() -> ParsedExpression {
        let start = i
        var value = parsePrimary()
        if value.isMissing { return value }
        var links = 0
        defer { expressionDepth -= links }
        loop: while i < limit {
            if chainAtLimit, kind(i) == .dot || kind(i) == .lBracket || (kind(i) == .lParen && sameLine(i)) {
                value = skipLongChain(value, from: start)
                break loop
            }
            switch kind(i) {
            case .dot:
                let dot = take()
                var children: [SyntaxChild] = [.node(value.node), dot]
                if isNameLike(i) && sameLine(i) {
                    children.append(take())
                } else {
                    children.append(missing(.identifier))
                    expected(.memberName)
                }
                value = ParsedExpression(node: node(.memberExpr, children), start: start, end: i - 1)
            case .lParen:
                if sameLine(i) {
                    let clause = parseArgumentClause()
                    value = ParsedExpression(node: node(.callExpr, [.node(value.node), .node(clause.node)]),
                                             start: start, end: i - 1)
                } else if bracketDepth > 0, value.end >= value.start {
                    let open = i
                    let name = tokens[value.end].text
                    report(.callOnNextLine, .error, textRange(open), ["name": .code(name)],
                           fixIts: [FixIt(titleKey: "joinLines", edits: [edit(textEnd(open - 1)..<starts[open], "")])])
                    let clause = parseArgumentClause()
                    value = ParsedExpression(node: node(.callExpr, [.node(value.node), .node(clause.node)]),
                                             start: start, end: i - 1)
                } else {
                    break loop
                }
            case .lBracket where sameLine(i) && tokens[i].leadingTrivia.isEmpty && tokens[i - 1].trailingTrivia.isEmpty:
                value = parseIndexing(base: value)
            case .question where isOptionalChaining(at: i):
                // `music?.title` (DK9005): the `?` is dropped; the member access continues.
                let q = i
                report(.optionalChaining, .error, textRange(q),
                       fixIts: [FixIt(titleKey: "remove", edits: [edit(textRange(q), "")])])
                let questionNode = node(.unexpected, [take()])
                let dot = take()
                var children: [SyntaxChild] = [.node(value.node), .node(questionNode), dot]
                if isNameLike(i) && sameLine(i) {
                    children.append(take())
                } else {
                    children.append(missing(.identifier))
                    expected(.memberName)
                }
                value = ParsedExpression(node: node(.memberExpr, children), start: start, end: i - 1)
            case .bang where sameLine(i) && tokens[i].leadingTrivia.isEmpty && tokens[i - 1].trailingTrivia.isEmpty
                        && !startsExpression(i + 1):
                // Swift's force unwrap `x!`.
                let b = i
                report(.unexpected, .error, textRange(b), ["text": .code("!")],
                       fixIts: [FixIt(titleKey: "remove", edits: [edit(textRange(b), "")])])
                value = ParsedExpression(node: node(.unexpected, [.node(value.node), take()]), start: start, end: i - 1)
            default:
                break loop
            }
            links += 1
            expressionDepth += 1
        }
        return value
    }

    /// `?` directly followed by `.name`, with no `:` completing a ternary at the same bracket depth (D73).
    func isOptionalChaining(at q: Int) -> Bool {
        guard kind(q + 1) == .dot, tokens[q].trailingTrivia.isEmpty, tokens[q + 1].leadingTrivia.isEmpty,
              isNameLike(q + 2) else { return false }
        var depth = 0
        var j = q + 1
        while j < limit {
            let k = kind(j)
            switch k {
            case .lParen, .lBracket: depth += 1
            case .rParen, .rBracket:
                if depth == 0 { return true }
                depth -= 1
            case .colon where depth == 0: return false
            case .comma where depth == 0, .semicolon, .lBrace, .rBrace, .interpolationEnd: return true
            default:
                if depth == 0 && nl(j) && canStartDeskStatement(j) && k != .dot { return true }
            }
            j += 1
        }
        return true
    }

    /// `list[0]` (DK9006): Desk writes `.item(1)`.
    mutating func parseIndexing(base: ParsedExpression) -> ParsedExpression {
        let open = i
        var children: [SyntaxChild] = [.node(base.node), take()]
        bracketDepth += 1
        let index = parseExpr()
        bracketDepth -= 1
        children.append(.node(index.node))
        var closed = false
        if kind(i) == .rBracket {
            children.append(take())
            closed = true
        } else {
            children.append(missing(.rBracket))
        }
        if !index.isMissing {
            let n: String
            if index.start == index.end, tokens[index.start].kind == .number, tokens[index.start].unit == nil,
               let value = Int(tokens[index.start].text), case let (next, false) = value.addingReportingOverflow(1) {
                n = String(next)
            } else {
                n = "\(text(index.start, index.end)) + 1"
            }
            let fixIts = closed ? [FixIt(titleKey: "rewrite", edits: [edit(starts[open]..<textEnd(i - 1), ".item(\(n))")])] : []
            report(.indexBrackets, .error, starts[open]..<textEnd(i - 1), ["n": .code(n)], fixIts: fixIts)
        } else {
            report(.unexpected, .error, textRange(open), ["text": .code("[")])
        }
        return ParsedExpression(node: node(.unexpected, children), start: base.start, end: i - 1)
    }

    // MARK: - Primaries

    mutating func parsePrimary() -> ParsedExpression {
        let start = i
        func single(_ kind: SyntaxKind, _ children: [SyntaxChild]) -> ParsedExpression {
            ParsedExpression(node: node(kind, children), start: start, end: i - 1)
        }
        switch kind(i) {
        case .number:
            return parseNumber()
        case .stringStart:
            return parseStringLiteral()
        case .rawString, .tripleQuoteString:
            return single(.stringLiteral, [take()])
        case .trueKeyword, .falseKeyword:
            return single(.boolLiteral, [take()])
        case .identifier:
            if let keyword = keywordVariant(i), keyword == .trueKeyword || keyword == .falseKeyword {
                reportCaseVariant(i, keyword)
                return single(.boolLiteral, [take()])
            }
            return single(.identifierExpr, [take()])
        case .invalidIdentifier, .eventKeyword:
            return single(.identifierExpr, [take()])
        case .dot:
            return parseImplicitMember()
        case .lBracket:
            return parseListLiteral()
        case .lParen:
            return parseParenthesized()
        case .dollar where isNameLike(i + 1) && tokens[i].trailingTrivia.isEmpty:
            // Swift's `$binding` (DK9106): pass the variable itself.
            let dollarIndex = i
            report(.swiftBinding, .error, textRange(dollarIndex), ["name": .code(tokens[dollarIndex + 1].text)],
                   fixIts: [FixIt(titleKey: "removeText", titleArguments: ["text": .code("$")],
                                  edits: [edit(textRange(dollarIndex), "")])])
            let dollar = node(.unexpected, [take()])
            return single(.identifierExpr, [.node(dollar), take()])
        case .hexColor, .hexNumber:
            // Already reported by the lexer (DK1026).
            return single(.unexpected, [take()])
        case .rainmeterVariable:
            let j = i
            let name = String(tokens[j].text.dropFirst().dropLast())
            report(.rainmeterVariable, .error, textRange(j),
                   ["name": .code(name), "desk": .code("options." + lowerCamel(name))])
            return ParsedExpression(node: SyntaxNode(kind: .foreignConstruct, children: [take()],
                                                     foreignKind: .rainmeterVariable),
                                    start: start, end: i - 1)
        default:
            return ParsedExpression(node: missingExpression(), start: start, end: start - 1)
        }
    }

    /// A number literal. A unit written after a space (`2 s`, `18 px`) is two tokens; the unit joins the literal
    /// as an unexpected child so the value keeps its meaning, with DK1028 (DK1021 for `px`).
    mutating func parseNumber() -> ParsedExpression {
        let start = i
        var children: [SyntaxChild] = [take()]
        if tokens[start].unit == nil, kind(i) == .identifier, sameLine(i), !tokens[i].flags.contains(.fullWidth) {
            let spelling = UnitTable.spelling(tokens[i].text)
            let isUnit: Bool
            switch spelling.status {
            case .known, .diagnosed: isUnit = true
            case .relativePosition, .unknown: isUnit = false
            }
            if isUnit && !startsCallOrMember(i + 1) {
                let unitIndex = i
                let number = tokens[start].text
                let gap = textEnd(start)..<starts[unitIndex]
                if spelling.text == "px" {
                    report(.pxUnit, .error, starts[start]..<textEnd(unitIndex), ["number": .code(number)],
                           fixIts: [FixIt(titleKey: "removeText", titleArguments: ["text": .code("px")],
                                          edits: [edit(gap.lowerBound..<textEnd(unitIndex), "")])])
                } else {
                    let unit = spelling.suggestion ?? spelling.text
                    report(.spaceBeforeUnit, .error, starts[start]..<textEnd(unitIndex),
                           ["number": .code(number), "unit": .code(unit)],
                           fixIts: [FixIt(titleKey: "removeSpace", edits: [edit(gap, "")])])
                }
                children.append(.node(node(.unexpected, [take()])))
            }
        }
        return ParsedExpression(node: node(.numberLiteral, children), start: start, end: i - 1)
    }

    /// A name followed on its line by `(` or `.`: a call or a path, not a unit written after a space.
    func startsCallOrMember(_ j: Int) -> Bool {
        guard sameLine(j) else { return false }
        return kind(j) == .lParen || kind(j) == .dot
    }

    /// `.caption`, `.text.opacity(50%)`, `.color(light:dark:)`.
    mutating func parseImplicitMember() -> ParsedExpression {
        let start = i
        var children: [SyntaxChild] = [take()]
        if isNameLike(i) && sameLine(i) {
            children.append(take())
        } else {
            children.append(missing(.identifier))
            expected(.memberName)
        }
        if kind(i) == .lParen && sameLine(i) {
            children.append(.node(parseArgumentClause().node))
        }
        return ParsedExpression(node: node(.implicitMemberExpr, children), start: start, end: i - 1)
    }

    /// `[a, b, c]`; line breaks inside do not matter (N1).
    mutating func parseListLiteral() -> ParsedExpression {
        let start = i
        let open = i
        var children: [SyntaxChild] = [take()]
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var expectComma = false
        while true {
            let k = kind(i)
            if k == .rBracket { children.append(take()); break }
            if i >= limit || k == .rBrace || k == .lBrace || k == .rParen || k == .semicolon
                || (expectComma && nl(i) && looksLikeStatementStart(i)) {
                children.append(missing(.rBracket))
                if !followsUnterminatedString { report(.unclosedBracket, .error, textRange(open), ["line": .number(lineNumber(ofToken: open))],
                       fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code("]")],
                                      edits: [edit(insertionPoint..<insertionPoint, "]")])]) }
                break
            }
            if k == .comma {
                if expectComma { children.append(take()); expectComma = false } else { children.append(.node(strayToken())) }
                continue
            }
            if expectComma {
                guard startsExpression(i) else {
                    children.append(.node(unexpectedInBrackets()))
                    continue
                }
                children.append(missing(.comma))
                report(.missingComma, .error, textRange(i),
                       fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code(",")],
                                      edits: [edit(insertionPoint..<insertionPoint, ",")])])
            }
            guard startsExpression(i) else {
                children.append(.node(unexpectedInBrackets()))
                continue
            }
            let before = i
            let element = parseExpr()
            children.append(.node(element.node))
            expectComma = true
            if i == before && i < limit { children.append(.node(unexpectedInBrackets())) }
        }
        return ParsedExpression(node: node(.listLiteral, children), start: start, end: i - 1)
    }

    /// `( value )`.
    mutating func parseParenthesized() -> ParsedExpression {
        let start = i
        let open = i
        var children: [SyntaxChild] = [take()]
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        let value = parseExpr()
        if value.isMissing { expected(.expression) }
        children.append(.node(value.node))
        // `(a, b)` and anything else before the `)`.
        if kind(i) != .rParen && i < limit && !isGroupStop(i) {
            children.append(.node(unexpectedInBrackets(stopAtComma: false)))
        }
        if kind(i) == .rParen {
            children.append(take())
        } else {
            children.append(missing(.rParen))
            if !followsUnterminatedString {
                report(.unclosedParen, .error, textRange(open), ["line": .number(lineNumber(ofToken: open))],
                       fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code(")")],
                                      edits: [edit(insertionPoint..<insertionPoint, ")")])])
            }
        }
        return ParsedExpression(node: node(.parenExpr, children), start: start, end: i - 1)
    }

    /// Where a bracketed group gives up: a brace, a statement separator, or a line that starts a new statement.
    func isGroupStop(_ j: Int) -> Bool {
        switch kind(j) {
        case .rBrace, .lBrace, .semicolon, .eof: return true
        default: return nl(j) && looksLikeStatementStart(j)
        }
    }

    /// A line start that is almost certainly a new statement, not the next value of an unclosed `(` or `[`: a
    /// component or function call, a declaration, `if`, `for`, `else`, or a modifier line.
    func looksLikeStatementStart(_ j: Int) -> Bool {
        switch kind(j) {
        case .variableKeyword, .savedKeyword, .computedKeyword, .ifKeyword, .forKeyword, .elseKeyword:
            return true
        case .identifier:
            // `Text(`, `Row {`, `name =`
            let next = kind(j + 1)
            if next == .lBrace { return true }
            if next == .lParen && sameLine(j + 1) { return tokens[j].isUpperName }
            if next == .equal && sameLine(j + 1) { return true }
            return false
        default:
            return false
        }
    }

    /// Tokens inside brackets that fit nowhere, up to the next `,` or closer (DK2006).
    mutating func unexpectedInBrackets(stopAtComma: Bool = true) -> SyntaxNode {
        let first = i
        var children: [SyntaxChild] = []
        var depth = 0
        repeat {
            let k = kind(i)
            if k == .lBrace {
                children.append(.node(parseBlock(owner: BlockOwner(head: "{", statementStart: first))))
                continue
            }
            if k == .lParen || k == .lBracket { depth += 1 }
            if k == .rParen || k == .rBracket { depth -= 1 }
            children.append(take())
        } while i < limit && !(depth <= 0 && (kind(i) == .rParen || kind(i) == .rBracket
                                              || (stopAtComma && kind(i) == .comma)))
                && !isGroupStop(i) && kind(i) != .interpolationEnd
        report(.unexpected, .error, starts[first]..<textEnd(i - 1), ["text": .code(shortText(first))],
               fixIts: lineIndex(ofToken: first) == lineIndex(ofToken: i - 1)
                   ? [FixIt(titleKey: "remove", edits: [edit(starts[first]..<textEnd(i - 1), "")])] : [])
        return node(.unexpected, children)
    }

    /// The token before the current one closes a string that ran to the end of its line (DK1010): its missing
    /// quote likely swallowed the closing bracket too, and the string's fix-it puts the quote before it.
    var followsUnterminatedString: Bool {
        i > 0 && tokens[i - 1].kind == .stringEnd && tokens[i - 1].isMissing
    }

    // MARK: - Arguments

    /// `( label: value, value )`. Labels may be reserved words (`if:`); `label = value` is kept for the checker
    /// (DK2035, DK2037). The `labeled` map gives the token range of each labelled value.
    mutating func parseArgumentClause() -> (node: SyntaxNode, labeled: [String: ClosedRange<Int>]) {
        let open = i
        var children: [SyntaxChild] = [take()]
        var labeled: [String: ClosedRange<Int>] = [:]
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var expectComma = false
        while true {
            let k = kind(i)
            if k == .rParen { children.append(take()); break }
            if i >= limit || k == .rBrace || k == .lBrace || k == .rBracket || k == .semicolon
                || (nl(i) && looksLikeStatementStart(i) && (expectComma || children.count == 1)) {
                children.append(missing(.rParen))
                if !followsUnterminatedString {
                    report(.unclosedParen, .error, textRange(open), ["line": .number(lineNumber(ofToken: open))],
                           fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code(")")],
                                          edits: [edit(insertionPoint..<insertionPoint, ")")])])
                }
                break
            }
            if k == .comma {
                if expectComma { children.append(take()); expectComma = false } else { children.append(.node(strayToken())) }
                continue
            }
            if expectComma {
                guard startsArgument(i) else {
                    children.append(.node(unexpectedInBrackets()))
                    continue
                }
                children.append(missing(.comma))
                report(.missingComma, .error, textRange(i),
                       fixIts: [FixIt(titleKey: "insert", titleArguments: ["text": .code(",")],
                                      edits: [edit(insertionPoint..<insertionPoint, ",")])])
            }
            guard startsArgument(i) else {
                children.append(.node(unexpectedInBrackets()))
                continue
            }
            var argument: [SyntaxChild] = []
            var label: String?
            if isNameLike(i) && (kind(i + 1) == .colon || kind(i + 1) == .equal) {
                label = tokens[i].text
                argument.append(.node(node(.label, [take()])))
                argument.append(take())
            }
            let before = i
            let value = parseExpr()
            if value.isMissing { expected(.expression) } else if let label { labeled[label] = value.start...value.end }
            argument.append(.node(value.node))
            children.append(.node(node(.argument, argument)))
            expectComma = true
            if i == before && i < limit {
                // Nothing could be read here: keep going past the token (progress is guaranteed).
                children.append(.node(unexpectedInBrackets()))
            }
        }
        return (node(.argumentClause, children), labeled)
    }

    func startsArgument(_ j: Int) -> Bool {
        if startsExpression(j) { return true }
        return isNameLike(j) && (kind(j + 1) == .colon || kind(j + 1) == .equal)
    }

    // MARK: - Strings

    /// `"text {value, option: x} more"`: text segments and interpolations, as the lexer produced them.
    mutating func parseStringLiteral() -> ParsedExpression {
        let start = i
        var children: [SyntaxChild] = [take()]
        guard tokens[start].kind == .stringStart else {
            return ParsedExpression(node: node(.stringLiteral, children), start: start, end: i - 1)
        }
        loop: while i < limit {
            switch kind(i) {
            case .stringText:
                children.append(.node(node(.stringText, [take()])))
            case .foreignInterpolation:
                children.append(.node(SyntaxNode(kind: .foreignConstruct, children: [take()],
                                                 foreignKind: .swiftInterpolation)))
            case .interpolationStart:
                children.append(.node(parseInterpolation()))
            case .stringEnd:
                children.append(take())
                break loop
            default:
                children.append(missing(.stringEnd))
                break loop
            }
        }
        if children.last?.token?.kind != .stringEnd { children.append(missing(.stringEnd)) }
        return ParsedExpression(node: node(.stringLiteral, children), start: start, end: i - 1)
    }

    /// `{value, label: option, …}` inside a string.
    mutating func parseInterpolation() -> SyntaxNode {
        let open = i
        let end = interpolationEnds[open] ?? limit
        var children: [SyntaxChild] = [take()]
        let savedLimit = limit
        limit = min(end, savedLimit)
        let savedBrackets = bracketDepth
        bracketDepth = 0
        if i < limit {
            // One missing piece is reported per interpolation: `{,}` is one mistake, not four.
            var quiet = false
            let value = parseExpr()
            if value.isMissing && i < limit && kind(i) != .comma {
                // Something that is no value at all: reported once below as unexpected.
            } else if value.isMissing {
                expected(.expression)
                quiet = true
            }
            children.append(.node(value.node))
            while kind(i) == .comma {
                var option: [SyntaxChild] = [take()]
                var labelText = ""
                if isNameLike(i) {
                    labelText = tokens[i].text
                    option.append(.node(node(.label, [take()])))
                } else {
                    option.append(.node(node(.label, [missing(.identifier)])))
                    if !quiet { expected(.label); quiet = true }
                }
                if kind(i) == .colon {
                    option.append(take())
                } else if kind(i) == .equal {
                    let eq = i
                    option.append(take())
                    report(.equalsInField, .error, textRange(eq),
                           ["label": .code(labelText), "fixed": .code("\(labelText):")],
                           fixIts: [FixIt(titleKey: "replaceWith", titleArguments: ["text": .code(":")],
                                          edits: [edit(textRange(eq), ":")], group: "equalsInField")])
                } else {
                    option.append(missing(.colon))
                    if !quiet { expected(.colon, insert: ":"); quiet = true }
                }
                let optionValue = parseExpr()
                if optionValue.isMissing && !quiet { expected(.expression); quiet = true }
                option.append(.node(optionValue.node))
                children.append(.node(node(.formatOption, option)))
            }
            if i < limit {
                var rest: [SyntaxChild] = []
                let first = i
                while i < limit { rest.append(take()) }
                report(.unexpected, .error, starts[first]..<textEnd(i - 1), ["text": .code(shortText(first))])
                children.append(.node(node(.unexpected, rest)))
            }
        } else {
            // `{}`: already reported by the lexer (DK1015).
            children.append(.node(missingExpression()))
        }
        bracketDepth = savedBrackets
        limit = savedLimit
        if kind(i) == .interpolationEnd {
            children.append(take())
        } else {
            children.append(missing(.interpolationEnd))
        }
        return node(.interpolation, children)
    }

    // MARK: - Text helpers

    /// `a ?? b` → `a.ifMissing(b)`: an operand that is not a simple path or call keeps parentheses.
    func parenthesizedIfNeeded(_ e: ParsedExpression) -> String {
        let t = text(e.start, e.end)
        switch e.node.kind {
        case .identifierExpr, .memberExpr, .callExpr, .implicitMemberExpr, .parenExpr, .stringLiteral,
             .numberLiteral, .listLiteral:
            return t
        default:
            return "(" + t + ")"
        }
    }
}

/// `FontColor` → `fontColor`, `MACACCENTCOLOR` → `macaccentcolor`: the own-name form of a foreign name.
func lowerCamel(_ name: String) -> String {
    guard let first = name.first else { return name }
    if name == name.uppercased() { return name.lowercased() }
    return first.lowercased() + name.dropFirst()
}
