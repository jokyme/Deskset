import Foundation

/// How `Desk.format` lays a file out. `.canonical` is the style of §3.8 (F1–F13).
public struct FormatOptions: Sendable, Hashable {
    /// Spaces per block level (F1).
    public var indentWidth: Int = 4
    /// A single-line block or modifier chain stays on one line up to this many display columns (F3, F5, F11).
    public var maxWidth: Int = 120

    public init(indentWidth: Int = 4, maxWidth: Int = 120) {
        self.indentWidth = indentWidth
        self.maxWidth = maxWidth
    }

    public static let canonical = FormatOptions()
}

extension Desk {
    /// The edits that bring a file to the canonical style (§3.8). Only trivia change, plus the two token changes
    /// that keep the meaning: a `;` or `,` between statements becomes the line break where that keeps the reading,
    /// and accepted alternates are normalised (`=` in a translation entry becomes `:`, a `:` after a language tag
    /// is removed). Code inside `unexpected` and `foreignConstruct` nodes is left as written. The result is
    /// checked: if the formatted text would not lex to the same tokens, no edits are returned.
    public static func format(_ tree: SyntaxTree, options: FormatOptions = .canonical) -> [TextEdit] {
        let needed = StackGuard.bytesNeeded(toWalk: tree)
        return StackGuard.run(needing: needed) {
            let formatter = DeskFormatter(tree: tree, options: options)
            return formatter.edits()
        }
    }

    /// The formatted text of a tree (`format` applied).
    public static func formatted(_ tree: SyntaxTree, options: FormatOptions = .canonical) -> String {
        TextEdit.apply(format(tree, options: options), to: tree.text)
    }
}

/// The formatter: annotates every token with its role and place, decides where lines break (keeping the author's
/// line breaks, adding the canonical ones), and renders each gap between tokens.
final class DeskFormatter {
    enum Role: Equatable {
        case word, keyword, elseKeyword, binaryOp, prefixOp, notOp, postfixOp
        case comma, separator, labelColon
        case callOpen, parenOpen, listOpen, close
        case blockOpen, blockClose
        case memberDot, modifierDot, implicitDot
        case stringStart, stringInner, stringEnd, interpolationStart, interpolationEnd
        case ellipsis, eof, other
    }

    struct Tok {
        var token: Token
        var start: Int
        var end: Int
        var role: Role = .other
        var frozen = false
        /// A missing token lies between the previous present token and this one.
        var missingBefore = false
        /// Dropped by the formatter (a separator turned into a line break, a group's `:`).
        var remove = false
        var replacement: String?
        var block = -1
        var chain = -1
        /// First token of a statement of a block, or of a top-level item.
        var statementStart = false
        var topItem = -1
        /// The name of a top-level `style` declaration (F8).
        var styleName = false
    }

    struct BlockInfo {
        var open = -1
        var close = -1
        var singleLine = true
        var hasComment = false
        var frozen = false
        var depth = 0
        var empty = true
    }

    struct ChainInfo {
        var start = -1
        var dots: [Int] = []
        var acrossLines = false
        var depth = 0
        var elementHasBlock = false
        /// A chain with no element before it (a style body, a `.hover` body): its lines are at the statement's level.
        var bare = false
    }

    struct TopItem {
        var first = -1
        var isBlock = false
        var singleLineStyle = false
        var block = -1
    }

    let tree: SyntaxTree
    let options: FormatOptions
    let bytes: [UInt8]
    var toks: [Tok] = []
    var blocks: [BlockInfo] = []
    var chains: [ChainInfo] = []
    var topItems: [TopItem] = []
    /// Chain id by the index of its statement's first token.
    var chainByStart: [Int: Int] = [:]
    /// The line break the formatter writes (F10): the file's most frequent one, settled on the output (see
    /// `settleNewline`).
    var newline: String

    // Decisions.
    var brokenBlocks: Set<Int> = []
    var brokenChains: Set<Int> = []
    /// Keeps every line break as written and adds none (no block, chain or separator is split): the fallback
    /// when the full layout would change how a file with errors parses.
    var conservative = false

    /// Strings of 0, 1, 2 … spaces.
    var spaceStrings: [String] = [""]

    // Layout of one pass.
    var mustBreak: [Bool] = []
    var mustJoin: [Bool] = []
    var indentOf: [Int] = []
    /// Blank lines: `firstBlankRun` of the gap before a token (nil: at most one, as written).
    var exactBlankBefore: [Bool] = []

    init(tree: SyntaxTree, options: FormatOptions) {
        self.tree = tree
        self.options = options
        bytes = Array(tree.text.utf8)
        newline = tree.lines.newline
        annotate()
        // Where the parse used indentation to repair unbalanced braces, formatting would change what the repair
        // sees: those parts of the file are left as written.
        for segment in tree.repair.segments {
            for k in toks.indices where toks[k].start >= segment.lowerBound && toks[k].start < segment.upperBound
                && toks[k].role != .eof {
                toks[k].frozen = true
            }
        }
    }

    // MARK: - Newlines

    /// Code left as written keeps its line breaks, so formatting can tip which line break is the most frequent (a
    /// file ends with one line break instead of three): the output is then written with the line break that is the
    /// most frequent in it, so formatting it again changes nothing. One more rendering always settles it, since the
    /// number of line breaks the formatter writes does not depend on which it writes.
    func settleNewline(_ output: inout Output) {
        let settled = LineTable.dominantNewline(output.bytes)
        guard settled != newline else { return }
        newline = settled
        output = render()
    }

    // MARK: - Annotation

    private var cursor = 0
    private var offset = 0
    private var pendingMissing = false

    /// Walks the tree once: flattens its present tokens and records roles, blocks, chains and top-level items.
    func annotate() {
        cursor = 0
        offset = 0
        walkAnnotate(tree.root, parent: nil, frozen: false, depth: 0)
    }

    private func addToken(_ token: Token, role: Role, frozen: Bool) -> Int {
        let start = offset + token.leadingTrivia.utf8Length
        let end = start + token.text.utf8.count
        offset += token.utf8Length
        if token.isMissing {
            pendingMissing = true
            return -1
        }
        var tok = Tok(token: token, start: start, end: end, role: role, frozen: frozen)
        tok.missingBefore = pendingMissing
        pendingMissing = false
        toks.append(tok)
        return toks.count - 1
    }

    /// Adds every token of a node without looking inside (frozen or plain).
    private func addAll(_ node: SyntaxNode, frozen: Bool) -> (first: Int, last: Int) {
        var first = -1
        var last = -1
        node.walkTokens { token, _ in
            let k = addToken(token, role: .other, frozen: frozen)
            if k >= 0 {
                if first < 0 { first = k }
                last = k
            }
            return true
        }
        return (first, last)
    }

    /// The first present token index a node will get, when it has one (the next index to be assigned).
    private var nextIndex: Int { toks.count }

    private func walkAnnotate(_ node: SyntaxNode, parent: SyntaxKind?, frozen: Bool, depth: Int) {
        if frozen || node.kind == .unexpected || node.kind == .foreignConstruct {
            _ = addAll(node, frozen: true)
            return
        }
        switch node.kind {
        case .sourceFile:
            for child in node.children {
                switch child {
                case .token(let token):
                    let role: Role = token.kind == .eof ? .eof : (token.kind == .semicolon || token.kind == .comma) ? .separator : .other
                    _ = addToken(token, role: role, frozen: false)
                case .node(let item):
                    var info = TopItem()
                    info.first = nextIndex
                    switch item.kind {
                    case .infoBlock, .packageBlock, .optionsBlock, .widgetBlock, .translationsBlock, .styleDecl,
                         .componentDecl, .scriptBlock:
                        info.isBlock = true
                    default:
                        break
                    }
                    let before = nextIndex
                    walkAnnotate(item, parent: .sourceFile, frozen: false, depth: depth + 1)
                    if nextIndex > before {
                        toks[before].statementStart = true
                        toks[before].topItem = topItems.count
                        if item.kind == .styleDecl, let block = styleBlockId(from: before) {
                            info.block = block
                            info.singleLineStyle = true   // refined by the decisions (single-line block)
                        }
                        topItems.append(info)
                    }
                }
            }
        case .block:
            var info = BlockInfo()
            info.depth = depth
            let id = blocks.count
            blocks.append(info)
            var sawStatement = false
            for child in node.children {
                switch child {
                case .token(let token):
                    switch token.kind {
                    case .lBrace:
                        let k = addToken(token, role: .blockOpen, frozen: false)
                        if k >= 0 { toks[k].block = id; blocks[id].open = k } else { blocks[id].frozen = true }
                    case .rBrace:
                        let k = addToken(token, role: .blockClose, frozen: false)
                        if k >= 0 { toks[k].block = id; blocks[id].close = k } else { blocks[id].frozen = true }
                    case .semicolon, .comma:
                        _ = addToken(token, role: .separator, frozen: false)
                    default:
                        _ = addToken(token, role: .other, frozen: true)
                    }
                case .node(let statement):
                    let before = nextIndex
                    walkAnnotate(statement, parent: .block, frozen: false, depth: depth + 1)
                    if nextIndex > before {
                        toks[before].statementStart = true
                        sawStatement = true
                    }
                }
            }
            blocks[id].empty = !sawStatement
            if blocks[id].frozen {
                // A block with a missing brace keeps its layout: every token in it is left as written.
                let first = blocks[id].open >= 0 ? blocks[id].open : max(0, toks.count - 1)
                for k in first..<toks.count { toks[k].frozen = true }
            }
        case .callStmt, .modifierStmt, .ifStmt, .forStmt:
            let chainable = node.kind == .callStmt || node.kind == .modifierStmt
            var chainId = -1
            if chainable && node.children.contains(where: { $0.node?.kind == .modifierApp }) {
                chainId = chains.count
                var info = ChainInfo()
                info.start = nextIndex
                info.depth = depth
                info.bare = node.kind == .modifierStmt
                info.elementHasBlock = node.children.contains { $0.node?.kind == .block }
                chains.append(info)
                chainByStart[info.start] = chainId
            }
            for child in node.children {
                switch child {
                case .token(let token):
                    let role: Role
                    switch token.kind {
                    case .ifKeyword, .forKeyword, .inKeyword: role = .keyword
                    case .identifier where token.flags.contains(.keywordCaseVariant): role = .keyword
                    default: role = .word
                    }
                    _ = addToken(token, role: role, frozen: false)
                case .node(let sub):
                    if sub.kind == .modifierApp {
                        let dot = nextIndex
                        walkAnnotate(sub, parent: node.kind, frozen: false, depth: depth + 1)
                        if chainId >= 0, dot < toks.count, toks[dot].role == .modifierDot {
                            toks[dot].chain = chainId
                            chains[chainId].dots.append(dot)
                        }
                    } else {
                        walkAnnotate(sub, parent: node.kind, frozen: false, depth: depth + 1)
                    }
                }
            }
        case .modifierApp:
            var first = true
            for child in node.children {
                switch child {
                case .token(let token):
                    _ = addToken(token, role: first && token.kind == .dot ? .modifierDot : .word, frozen: false)
                    first = false
                case .node(let sub):
                    walkAnnotate(sub, parent: .modifierApp, frozen: false, depth: depth + 1)
                }
            }
        case .elseClause:
            for child in node.children {
                switch child {
                case .token(let token): _ = addToken(token, role: .elseKeyword, frozen: false)
                case .node(let sub): walkAnnotate(sub, parent: .elseClause, frozen: false, depth: depth + 1)
                }
            }
        case .argumentClause, .parameterClause:
            for child in node.children {
                switch child {
                case .token(let token):
                    let role: Role
                    switch token.kind {
                    case .lParen: role = .callOpen
                    case .rParen: role = .close
                    case .comma: role = .comma
                    default: role = .other
                    }
                    _ = addToken(token, role: role, frozen: false)
                case .node(let sub):
                    walkAnnotate(sub, parent: node.kind, frozen: false, depth: depth + 1)
                }
            }
        case .listLiteral, .parenExpr:
            for child in node.children {
                switch child {
                case .token(let token):
                    let role: Role
                    switch token.kind {
                    case .lBracket: role = .listOpen
                    case .lParen: role = .parenOpen
                    case .rParen, .rBracket: role = .close
                    case .comma: role = .comma
                    default: role = .other
                    }
                    _ = addToken(token, role: role, frozen: false)
                case .node(let sub):
                    walkAnnotate(sub, parent: node.kind, frozen: false, depth: depth + 1)
                }
            }
        case .stringLiteral:
            for child in node.children {
                switch child {
                case .token(let token):
                    let role: Role
                    switch token.kind {
                    case .stringStart: role = .stringStart
                    case .stringEnd: role = .stringEnd
                    default: role = .word    // raw and triple-quoted strings are one token
                    }
                    _ = addToken(token, role: role, frozen: false)
                case .node(let segment):
                    if segment.kind == .interpolation {
                        walkAnnotate(segment, parent: .stringLiteral, frozen: false, depth: depth + 1)
                    } else {
                        segment.walkTokens { token, _ in
                            _ = addToken(token, role: .stringInner, frozen: false)
                            return true
                        }
                    }
                }
            }
        case .interpolation:
            for child in node.children {
                switch child {
                case .token(let token):
                    _ = addToken(token, role: token.kind == .interpolationStart ? .interpolationStart : .interpolationEnd,
                                 frozen: false)
                case .node(let sub):
                    walkAnnotate(sub, parent: .interpolation, frozen: false, depth: depth + 1)
                }
            }
        default:
            annotateGeneric(node, depth: depth)
        }
    }

    /// Roles of the tokens of the other node kinds, by their kind and the node they are in.
    private func annotateGeneric(_ node: SyntaxNode, depth: Int) {
        for child in node.children {
            switch child {
            case .node(let sub):
                walkAnnotate(sub, parent: node.kind, frozen: false, depth: depth + 1)
            case .token(let token):
                let role = role(of: token, in: node.kind)
                let k = addToken(token, role: role, frozen: false)
                guard k >= 0 else { continue }
                if node.kind == .styleDecl, token.kind == .identifier || token.kind.isKeyword,
                   k > 0, toks[k - 1].role == .keyword, toks[k - 1].token.text == "style" {
                    toks[k].styleName = true
                }
                if node.kind == .group, token.kind == .colon {
                    toks[k].remove = true
                    toks[k].role = .labelColon
                }
                if node.kind == .entry, token.kind == .equal {
                    toks[k].replacement = ":"
                    toks[k].role = .labelColon
                }
            }
        }
    }

    private func role(of token: Token, in kind: SyntaxKind) -> Role {
        switch kind {
        case .infoBlock, .packageBlock, .optionsBlock, .widgetBlock, .translationsBlock, .styleDecl, .componentDecl,
             .scriptBlock:
            // The block word; a style's or component's name is a word.
            if token.kind == .identifier && ["info", "package", "options", "widget", "translations", "style",
                                              "component", "script"].contains(token.text) {
                return .keyword
            }
            return .word
        case .declaration:
            switch token.kind {
            case .equal: return .binaryOp
            case .variableKeyword, .savedKeyword, .computedKeyword: return .keyword
            case .identifier where token.flags.contains(.keywordCaseVariant): return .keyword
            default: return .word
            }
        case .field, .argument, .formatOption, .entry, .parameter:
            switch token.kind {
            case .colon: return .labelColon
            case .equal: return .binaryOp
            case .comma: return .comma
            default: return .word
            }
        case .optionDecl, .assignment:
            switch token.kind {
            case .equal, .plusEqual, .minusEqual, .starEqual, .slashEqual: return .binaryOp
            case .plusPlus, .minusMinus: return .postfixOp
            default: return .word
            }
        case .ternaryExpr, .binaryExpr:
            return token.kind == .question || token.kind == .colon || kind == .binaryExpr ? .binaryOp : .word
        case .rangeExpr:
            return .ellipsis
        case .prefixExpr:
            return token.kind == .notKeyword || (token.kind == .identifier && token.flags.contains(.keywordCaseVariant))
                ? .notOp : .prefixOp
        case .memberExpr, .target, .callee:
            return token.kind == .dot ? .memberDot : .word
        case .implicitMemberExpr:
            return token.kind == .dot ? .implicitDot : .word
        default:
            return .word
        }
    }

    private func styleBlockId(from first: Int) -> Int? {
        var k = first
        while k < toks.count {
            if toks[k].role == .blockOpen { return toks[k].block }
            k += 1
        }
        return nil
    }

    // MARK: - Original line structure

    /// Whether the original gap before token `k` (from the previous present token) holds a line break.
    func originalBreak(before k: Int) -> Bool {
        guard k > 0 else { return false }
        let p = k - 1
        if toks[p].token.trailingTrivia.containsLineBreak { return true }
        return toks[k].token.leadingTrivia.containsLineBreak
    }

    /// Initial decisions from the text as written (F3, F4, F5).
    func decideFromOriginal() {
        // Counts up to each token of line breaks (before it or inside it) and of comments next to it, so that each
        // block is decided in constant time however deeply blocks nest.
        var breaks = [Int](repeating: 0, count: toks.count + 1)
        var comments = [Int](repeating: 0, count: toks.count + 1)
        for k in toks.indices {
            var lineBreak = originalBreak(before: k)
            if !lineBreak {
                for b in bytes[toks[k].start..<toks[k].end] where b == 0x0A || b == 0x0D {
                    lineBreak = true
                    break
                }
            }
            let comment = toks[k].token.leadingTrivia.containsComment
                || (k > 0 && toks[k - 1].token.trailingTrivia.containsComment)
            breaks[k + 1] = breaks[k] + (lineBreak ? 1 : 0)
            comments[k + 1] = comments[k] + (comment ? 1 : 0)
        }
        for id in blocks.indices {
            let block = blocks[id]
            guard !block.frozen, block.open >= 0, block.close >= 0 else { continue }
            // Tokens open + 1 ... close.
            let singleLine = breaks[block.close + 1] == breaks[block.open + 1]
            let comment = comments[block.close + 1] != comments[block.open + 1]
            blocks[id].singleLine = singleLine
            blocks[id].hasComment = comment
            if !singleLine || comment { brokenBlocks.insert(id) }
        }
        for id in chains.indices {
            let chain = chains[id]
            guard !chain.dots.isEmpty else { continue }
            var across = false
            // A chain with no element starts the statement with its first modifier.
            for dot in (chain.bare ? Array(chain.dots.dropFirst()) : chain.dots) where originalBreak(before: dot) {
                across = true
            }
            chains[id].acrossLines = across
            if across { brokenChains.insert(id) }
        }
    }

    // MARK: - Layout

    /// Computes forced breaks, joins and indentation for the current decisions.
    func layout() {
        let n = toks.count
        mustBreak = [Bool](repeating: false, count: n)
        mustJoin = [Bool](repeating: false, count: n)
        indentOf = [Int](repeating: 0, count: n)
        exactBlankBefore = [Bool](repeating: false, count: n)
        cursor = 0
        layoutNode(tree.root, blockIndent: 0, unitIndent: 0)
        for item in topItems where item.first < n { indentOf[item.first] = 0 }
        if conservative {
            mustBreak = [Bool](repeating: false, count: n)
            mustJoin = [Bool](repeating: false, count: n)
            for k in toks.indices { toks[k].remove = false }
        }
        // Top-level items each start a line; between two blocks there is exactly one blank line (F7).
        for (index, item) in topItems.enumerated() where item.first < n && index > 0 {
            if !toks[item.first].frozen && !conservative { mustBreak[item.first] = true }
            let previous = topItems[index - 1]
            let bothStyles = isSingleLineStyle(previous) && isSingleLineStyle(item)
            if item.isBlock && previous.isBlock && !bothStyles { exactBlankBefore[item.first] = true }
        }
    }

    func isSingleLineStyle(_ item: TopItem) -> Bool {
        item.block >= 0 && blocks[item.block].singleLine && !brokenBlocks.contains(item.block)
            && !blocks[item.block].frozen
    }

    private var indentWidth: Int { options.indentWidth }

    /// Lays out a node's tokens in order. `blockIndent` is the indentation of statements in the current block;
    /// `unitIndent` that of the current line unit (a statement's first line or a modifier line).
    private func layoutNode(_ node: SyntaxNode, blockIndent: Int, unitIndent: Int) {
        if node.kind == .unexpected || node.kind == .foreignConstruct {
            skipTokens(node)
            return
        }
        switch node.kind {
        case .sourceFile:
            for child in node.children {
                switch child {
                case .token(let token): visit(token, indent: 0)
                case .node(let item): layoutNode(item, blockIndent: 0, unitIndent: 0)
                }
            }
        case .block:
            layoutBlock(node, ownerIndent: unitIndent)
        case .callStmt, .modifierStmt, .ifStmt, .forStmt:
            layoutStatementWithChain(node, statementIndent: unitIndent, blockIndent: blockIndent)
        case .elseClause:
            // `else` on its own line is at the `if`'s level; so is the block or `else if` it opens.
            for child in node.children {
                switch child {
                case .token(let token): visit(token, indent: unitIndent)
                case .node(let sub):
                    if sub.kind == .ifStmt {
                        layoutStatementWithChain(sub, statementIndent: unitIndent, blockIndent: blockIndent)
                    } else {
                        layoutNode(sub, blockIndent: blockIndent, unitIndent: unitIndent)
                    }
                }
            }
        default:
            for child in node.children {
                switch child {
                case .token(let token): visit(token, indent: unitIndent + indentWidth)
                case .node(let sub): layoutNode(sub, blockIndent: blockIndent, unitIndent: unitIndent)
                }
            }
        }
    }

    /// Tokens of a frozen node: nothing is decided for them.
    private func skipTokens(_ node: SyntaxNode) {
        node.walkTokens { token, _ in
            if !token.isMissing { cursor += 1 }
            return true
        }
    }

    /// Records a token's indentation (if it starts a line) and advances. Closing brackets alone on their line go
    /// back to the unit's level (F13); every other continuation line is one level deeper than its unit.
    private func visit(_ token: Token, indent: Int) {
        guard !token.isMissing else { return }
        let k = cursor
        cursor += 1
        guard k < toks.count else { return }
        switch toks[k].role {
        case .close:
            indentOf[k] = max(0, indent - indentWidth)
        default:
            indentOf[k] = indent
        }
    }

    private func layoutBlock(_ node: SyntaxNode, ownerIndent: Int) {
        let contentIndent = ownerIndent + indentWidth
        let open = cursor
        let id = (open < toks.count && toks[open].role == .blockOpen) ? toks[open].block : -1
        let broken = id >= 0 && brokenBlocks.contains(id) && !blocks[id].frozen
        var firstStatement = true
        var previousSeparator = -1
        for child in node.children {
            switch child {
            case .token(let token):
                guard !token.isMissing else { continue }
                let k = cursor
                switch toks[k].role {
                case .blockOpen:
                    visit(token, indent: ownerIndent)
                    // `{` on the next line moves up to its owner (N5), unless a comment is in the way.
                    if !toks[k].frozen && k > 0 && !toks[k - 1].token.trailingTrivia.containsComment
                        && !toks[k].token.leadingTrivia.containsComment {
                        mustJoin[k] = true
                    }
                case .blockClose:
                    visit(token, indent: ownerIndent)
                    if broken { mustBreak[k] = true }
                case .separator:
                    visit(token, indent: contentIndent)
                    previousSeparator = k
                default:
                    visit(token, indent: contentIndent)
                }
            case .node(let statement):
                let first = cursor
                if first < toks.count, broken, !toks[first].frozen {
                    if firstStatement {
                        mustBreak[first] = true
                    } else if previousSeparator >= 0 && previousSeparator == first - 1 {
                        // `a; b` on one line: the separator becomes the line break when that keeps the reading
                        // (N2–N6), else it stays and the line is not broken there.
                        if !originalBreak(before: first) && canTurnIntoLineBreak(previousSeparator, next: first) {
                            toks[previousSeparator].remove = true
                            mustBreak[first] = true
                        }
                    } else {
                        mustBreak[first] = true
                    }
                }
                firstStatement = false
                previousSeparator = -1
                layoutNode(statement, blockIndent: contentIndent, unitIndent: contentIndent)
                if first < toks.count { indentOf[first] = contentIndent }
            }
        }
    }

    /// A separator can become a line break only when the next token cannot continue the statement across a
    /// line break (N3–N6): not `.`, `else`, `{`, a binary operator, and the separator has no comment after it.
    private func canTurnIntoLineBreak(_ separator: Int, next: Int) -> Bool {
        guard !toks[separator].frozen, !toks[next].frozen, !toks[next].missingBefore,
              !toks[separator].missingBefore else { return false }
        if toks[separator].token.trailingTrivia.containsComment || toks[separator].token.leadingTrivia.containsComment {
            return false
        }
        switch toks[next].token.kind {
        case .dot, .elseKeyword, .lBrace, .andKeyword, .orKeyword, .plus, .minus, .star, .slash, .percent,
             .equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual, .ellipsis, .question, .colon,
             .ampAmp, .pipePipe, .questionQuestion, .lParen:
            return false
        case .identifier:
            if let keyword = Chars.reservedWords[toks[next].token.name.lowercased()],
               toks[next].token.flags.contains(.keywordCaseVariant),
               keyword == .elseKeyword || keyword == .andKeyword || keyword == .orKeyword {
                return false
            }
            return true
        default:
            return true
        }
    }

    /// A statement whose modifiers form a chain (F5): a broken chain puts every modifier on its own line, one
    /// level deeper than the element when it has no block, at its level after its closing `}` (F1).
    private func layoutStatementWithChain(_ node: SyntaxNode, statementIndent: Int, blockIndent: Int) {
        let chainStart = cursor
        let chainId = (node.kind == .callStmt || node.kind == .modifierStmt) ? (chainByStart[chainStart] ?? -1) : -1
        let broken = chainId >= 0 && brokenChains.contains(chainId)
        let hasBlock = node.children.contains { $0.node?.kind == .block }
        let modifierIndent = (node.kind == .modifierStmt || hasBlock || node.kind == .ifStmt || node.kind == .forStmt)
            ? statementIndent : statementIndent + indentWidth
        var unit = statementIndent
        for child in node.children {
            switch child {
            case .token(let token):
                visit(token, indent: unit + indentWidth)
            case .node(let sub):
                switch sub.kind {
                case .modifierApp:
                    let dot = cursor
                    let startsLine = dot < toks.count && !toks[dot].frozen
                        && (originalBreak(before: dot) || (broken && !(node.kind == .modifierStmt && dot == chainStart)))
                    if startsLine {
                        unit = modifierIndent
                        if broken && !(node.kind == .modifierStmt && dot == chainStart) { mustBreak[dot] = true }
                    }
                    layoutModifier(sub, unitIndent: unit, blockIndent: blockIndent)
                    if startsLine && dot < toks.count { indentOf[dot] = modifierIndent }
                case .block:
                    layoutBlock(sub, ownerIndent: unit)
                case .elseClause:
                    layoutNode(sub, blockIndent: blockIndent, unitIndent: statementIndent)
                default:
                    layoutNode(sub, blockIndent: blockIndent, unitIndent: unit)
                }
            }
        }
    }

    private func layoutModifier(_ node: SyntaxNode, unitIndent: Int, blockIndent: Int) {
        for child in node.children {
            switch child {
            case .token(let token): visit(token, indent: unitIndent + indentWidth)
            case .node(let sub):
                if sub.kind == .block {
                    layoutBlock(sub, ownerIndent: unitIndent)
                } else {
                    layoutNode(sub, blockIndent: blockIndent, unitIndent: unitIndent)
                }
            }
        }
    }

    // MARK: - Rendering

    struct Output {
        var bytes: [UInt8]
        /// Output offset of each token's text.
        var starts: [Int]
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    /// Whether a gap is left exactly as written: next to frozen code or a missing token, or before the end of a
    /// file that ends inside an unclosed block comment (anything added there would become part of the comment).
    func gapIsVerbatim(_ p: Int, _ k: Int) -> Bool {
        if p >= 0 && toks[p].frozen { return true }
        if toks[k].frozen || toks[k].missingBefore { return true }
        if toks[k].role == .eof && endsInUnclosedComment(p, k) { return true }
        return false
    }

    func endsInUnclosedComment(_ p: Int, _ k: Int) -> Bool {
        // The last block comment of the gap (nothing can follow an unclosed one).
        var last: String?
        forEachGapPiece(p, k) { piece in
            if case .blockComment(let s) = piece { last = s }
        }
        guard let last else { return false }
        return !(last.count >= 4 && last.hasSuffix("*/"))
    }

    /// Visits the trivia pieces between the previous kept token `p` and token `k` (including the trivia of removed
    /// tokens in between), in order.
    func forEachGapPiece(_ p: Int, _ k: Int, _ body: (Trivia) -> Void) {
        if p >= 0 { for piece in toks[p].token.trailingTrivia { body(piece) } }
        var r = p + 1
        while r < k {
            for piece in toks[r].token.leadingTrivia { body(piece) }
            for piece in toks[r].token.trailingTrivia { body(piece) }
            r += 1
        }
        for piece in toks[k].token.leadingTrivia { body(piece) }
    }

    func render() -> Output {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 4 + 64)
        var starts = [Int](repeating: 0, count: toks.count)
        var p = -1
        // Style runs (F8): widths of the names of consecutive single-line top-level styles.
        let styleColumn = styleAlignment()
        for k in 0..<toks.count {
            if toks[k].remove { continue }
            if p >= 0, toks[p].frozen, !toks[k].frozen, !toks[k].missingBefore, toks[p].end < toks[k].start,
               !(toks[k].role == .eof && endsInUnclosedComment(p, k)), let partial = renderAfterFrozen(p, k) {
                // After code left as written: its line stays as it is; the next line is indented as usual.
                out.append(contentsOf: partial.utf8)
            } else if gapIsVerbatim(p, k) {
                out.append(contentsOf: bytes[(p >= 0 ? toks[p].end : 0)..<toks[k].start])
            } else {
                appendGap(p, k, styleColumn: styleColumn, to: &out)
            }
            starts[k] = out.count
            if let replacement = toks[k].replacement {
                out.append(contentsOf: replacement.utf8)
            } else {
                out.append(contentsOf: bytes[toks[k].start..<toks[k].end])
            }
            p = k
        }
        return Output(bytes: out, starts: starts)
    }

    /// Style names in runs of single-line top-level styles: the column their `{` is aligned to (F8).
    func styleAlignment() -> [Int: Int] {
        var result: [Int: Int] = [:]
        var run: [Int] = []
        func flush() {
            guard run.count > 1 else { run = []; return }
            let widest = run.map { displayWidth(toks[$0].token.text) }.max() ?? 0
            for name in run { result[name] = widest }
            run = []
        }
        var previous: TopItem?
        for item in topItems {
            guard isSingleLineStyle(item), let name = (item.first..<min(item.first + 3, toks.count)).first(where: { toks[$0].styleName }) else {
                flush()
                previous = nil
                continue
            }
            if let previous, isSingleLineStyle(previous), blankRowsBefore(item.first) == 0 {
                run.append(name)
            } else {
                flush()
                run = [name]
            }
            previous = item
        }
        flush()
        return result
    }

    /// Blank lines written before token `k`, as the formatter keeps them (at most one).
    func blankRowsBefore(_ k: Int) -> Int {
        let layout = GapLayout { visit in forEachGapPiece(k - 1, k, visit) }
        return layout.rows.contains { $0.isEmpty } ? 1 : 0
    }

    struct GapLayout {
        /// Comments on the previous token's line, after it.
        var inline: [String] = []
        /// Lines between: each is a list of comments, empty for a blank line.
        var rows: [[String]] = []
        /// Comments on the token's own line, before it.
        var lastRow: [String] = []
        var newlines = 0
        var hasBreak = false

        init(pieces: [Trivia]) {
            self.init { visit in pieces.forEach(visit) }
        }

        /// From the pieces `visitPieces` passes to its argument, in order.
        init(_ visitPieces: ((Trivia) -> Void) -> Void) {
            var current: [String] = []
            var inline: [String] = []
            var rows: [[String]] = []
            var newlines = 0
            var hasBreak = false
            visitPieces { piece in
                switch piece {
                case .newline:
                    if newlines == 0 { inline = current } else { rows.append(current) }
                    current = []
                    newlines += 1
                    hasBreak = true
                case .lineComment(let s), .blockComment(let s):
                    current.append(s)
                    if s.utf8.contains(0x0A) || s.utf8.contains(0x0D) { hasBreak = true }
                default:
                    break
                }
            }
            if newlines == 0 { inline = current } else { lastRow = current }
            self.inline = inline
            self.rows = rows
            self.newlines = newlines
            self.hasBreak = hasBreak
        }
    }

    /// Appends the rendered gap before token `k` (after the kept token `p`).
    private func appendGap(_ p: Int, _ k: Int, styleColumn: [Int: Int], to out: inout [UInt8]) {
        // The common gaps — a single space or nothing between two tokens on a line, or one line break and the
        // indentation — are written directly.
        if p >= 0, !mustBreak[k], !mustJoin[k], toks[k].role != .eof, gapIsPlainSpaces(p, k) {
            out.append(contentsOf: spacing(p, k, styleColumn: styleColumn).utf8)
            return
        }
        out.append(contentsOf: renderGap(p, k, styleColumn: styleColumn).utf8)
    }

    /// Whether the gap holds only spaces and tabs (no line break, no comment), without removed tokens in between.
    private func gapIsPlainSpaces(_ p: Int, _ k: Int) -> Bool {
        guard k == p + 1 else { return false }
        for piece in toks[p].token.trailingTrivia {
            switch piece {
            case .spaces, .tabs: continue
            default: return false
            }
        }
        for piece in toks[k].token.leadingTrivia {
            switch piece {
            case .spaces, .tabs: continue
            default: return false
            }
        }
        return true
    }

    private func renderGap(_ p: Int, _ k: Int, styleColumn: [Int: Int]) -> String {
        var layout = GapLayout { visit in forEachGapPiece(p, k, visit) }
        let isEOF = toks[k].role == .eof
        var breaks = layout.hasBreak || mustBreak[k]
        if mustJoin[k] && layout.inline.isEmpty && layout.lastRow.isEmpty && layout.rows.allSatisfy(\.isEmpty) {
            breaks = false
            layout = GapLayout(pieces: [])
        }
        if p < 0 {
            // Start of the file: the byte order mark, then comments; no blank line first.
            var text = toks[k].token.leadingTrivia.contains(.byteOrderMark) ? "\u{FEFF}" : ""
            var rows = layout.rows
            if layout.newlines > 0 { rows.insert(layout.inline, at: 0) } else if !layout.inline.isEmpty {
                // Comments before the first token on its own line.
                return text + layout.inline.joined(separator: " ") + (isEOF ? newline : " ")
            }
            rows = trimBlankRows(rows, leading: true, trailing: isEOF)
            if isEOF {
                rows = trimBlankRows(rows, leading: true, trailing: true)
                if rows.isEmpty && layout.lastRow.isEmpty { return text }
                for row in rows { text += row.isEmpty ? newline : row.joined(separator: " ") + newline }
                if !layout.lastRow.isEmpty { text += layout.lastRow.joined(separator: " ") + newline }
                return text
            }
            rows = capBlankRows(rows)
            for row in rows { text += row.isEmpty ? newline : indent(k) + row.joined(separator: " ") + newline }
            text += indent(k)
            if !layout.lastRow.isEmpty { text += layout.lastRow.joined(separator: " ") + " " }
            return text
        }
        if isEOF {
            var text = ""
            if !layout.inline.isEmpty { text += " " + layout.inline.joined(separator: " ") }
            var rows = trimBlankRows(layout.rows, leading: false, trailing: true)
            if !layout.lastRow.isEmpty { rows.append(layout.lastRow) }
            rows = trimBlankRows(capBlankRows(rows), leading: false, trailing: true)
            text += newline
            for row in rows { text += row.isEmpty ? newline : row.joined(separator: " ") + newline }
            return text
        }
        if !breaks {
            var text = spacing(p, k, styleColumn: styleColumn)
            if !layout.inline.isEmpty {
                // Inline block comments: one space on each side.
                text = " " + layout.inline.joined(separator: " ") + " "
            }
            return text
        }
        var text = ""
        if !layout.inline.isEmpty { text += " " + layout.inline.joined(separator: " ") }
        text += newline
        var rows = layout.rows
        let afterOpen = toks[p].role == .blockOpen
        let beforeClose = toks[k].role == .blockClose
        rows = trimBlankRows(rows, leading: afterOpen, trailing: beforeClose)
        rows = capBlankRows(rows)
        if exactBlankBefore[k] {
            // Exactly one blank line between top-level blocks (before any comment above the next block).
            if let first = rows.first, first.isEmpty {
                // already one
            } else {
                rows.insert([], at: 0)
            }
            rows = capBlankRows(rows)
        }
        // Comments on their own lines take the indentation of the token after them; before a block's `}`, that of
        // the block's content, since they belong to it.
        let commentIndent = beforeClose ? spaces(indentOf[k] + indentWidth) : indent(k)
        for row in rows { text += row.isEmpty ? newline : commentIndent + row.joined(separator: " ") + newline }
        text += indent(k)
        if !layout.lastRow.isEmpty { text += layout.lastRow.joined(separator: " ") + " " }
        return text
    }

    /// The gap after a frozen token: everything up to the first line break as written, then the following
    /// lines normalised and the token indented. Nil when the gap has no line break of its own (kept as written).
    private func renderAfterFrozen(_ p: Int, _ k: Int) -> String? {
        var prefix = toks[p].token.trailingTrivia.text
        let leading = toks[k].token.leadingTrivia
        guard let firstBreak = leading.firstIndex(where: \.isNewline) else { return nil }
        prefix += Array(leading[..<firstBreak]).text + newline
        var layout = GapLayout(pieces: [.newline(.lf)] + Array(leading[(firstBreak + 1)...]))
        var rows = capBlankRows(trimBlankRows(layout.rows, leading: false, trailing: toks[k].role == .blockClose))
        if toks[k].role == .eof {
            rows = trimBlankRows(rows, leading: false, trailing: true)
            if !layout.lastRow.isEmpty { rows.append(layout.lastRow) }
            layout.lastRow = []
            return prefix + rows.map { $0.isEmpty ? newline : $0.joined(separator: " ") + newline }.joined()
        }
        var text = prefix
        for row in rows { text += row.isEmpty ? newline : indent(k) + row.joined(separator: " ") + newline }
        text += indent(k)
        if !layout.lastRow.isEmpty { text += layout.lastRow.joined(separator: " ") + " " }
        return text
    }

    private func indent(_ k: Int) -> String { spaces(indentOf[k]) }

    /// `n` spaces (cached: indentation is asked for at every line).
    private func spaces(_ n: Int) -> String {
        guard n > 0 else { return "" }
        while spaceStrings.count <= n { spaceStrings.append(String(repeating: " ", count: spaceStrings.count)) }
        return spaceStrings[n]
    }

    private func trimBlankRows(_ rows: [[String]], leading: Bool, trailing: Bool) -> [[String]] {
        var rows = rows
        if leading { while let first = rows.first, first.isEmpty { rows.removeFirst() } }
        if trailing { while let last = rows.last, last.isEmpty { rows.removeLast() } }
        return rows
    }

    /// At most one blank line in a row (F7).
    private func capBlankRows(_ rows: [[String]]) -> [[String]] {
        var out: [[String]] = []
        for row in rows {
            if row.isEmpty, let last = out.last, last.isEmpty { continue }
            out.append(row)
        }
        return out
    }

    // MARK: - Spacing (F6)

    private func spacing(_ p: Int, _ k: Int, styleColumn: [Int: Int]) -> String {
        let a = toks[p]
        let b = toks[k]
        let wanted = wantedSpacing(a, b, styleColumn: styleColumn, p: p)
        // Removing blanks must not make two tokens read as others; tokens written together stay together.
        if wanted.isEmpty && a.end < b.start
            && mustSeparate(a.replacement ?? a.token.text, b.replacement ?? b.token.text) {
            return " "
        }
        return wanted
    }

    private func wantedSpacing(_ a: Tok, _ b: Tok, styleColumn: [Int: Int], p: Int) -> String {
        // Inside strings nothing changes (there are no blanks there); none inside an interpolation's braces.
        switch (a.role, b.role) {
        case (.stringStart, _), (.stringInner, _), (_, .stringInner), (_, .stringEnd), (_, .interpolationStart),
             (.interpolationStart, _), (_, .interpolationEnd):
            return ""
        case (.interpolationEnd, _):
            return ""
        default:
            break
        }
        // A style run's names line their `{` up one space after the longest name (F8).
        if a.styleName, let column = styleColumn[p], b.role == .blockOpen {
            return String(repeating: " ", count: column - displayWidth(a.token.text) + 1)
        }
        // One space inside a single-line `{ … }`, and after a separator or comma that stays.
        if a.role == .blockOpen || b.role == .blockClose { return " " }
        if (a.role == .separator || a.role == .comma) && b.role != .close { return " " }
        // None inside `()` and `[]`.
        switch a.role {
        case .callOpen, .parenOpen, .listOpen: return ""
        default: break
        }
        switch b.role {
        case .close, .comma, .separator, .labelColon, .postfixOp, .ellipsis, .memberDot, .modifierDot:
            return ""
        case .callOpen:
            // None between a callee and `(`.
            return a.role == .binaryOp || a.role == .comma || a.role == .keyword || a.role == .elseKeyword
                || a.role == .labelColon || a.role == .separator ? " " : ""
        case .blockOpen:
            return " "
        default:
            break
        }
        switch a.role {
        case .comma, .separator, .labelColon, .binaryOp, .keyword, .elseKeyword, .notOp: return " "
        case .memberDot, .modifierDot, .implicitDot, .prefixOp, .ellipsis: return ""
        default: break
        }
        // Around binary operators and keywords, and between two words (a style's name, two statements on a line).
        return " "
    }

    /// Whether two tokens written next to each other would read as other tokens.
    private func mustSeparate(_ left: String, _ right: String) -> Bool {
        guard let l = left.unicodeScalars.last, let r = right.unicodeScalars.first else { return false }
        func isNameScalar(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) || s == "_"
                || s.value > 0x7F
        }
        if isNameScalar(l) && isNameScalar(r) { return true }
        let pair = String(l) + String(r)
        let joining: Set<String> = ["--", "-=", "->", "++", "+=", "**", "*=", "//", "/*", "/=", "==", "=>", "!=",
                                    "<=", "</", "<!", ">=", "..", "??", "&&", "||", "::", "?.", "%=", "*/"]
        if joining.contains(pair) { return true }
        // A digit before `.5` would read as one number; before `%` or `°` as a unit.
        if ("0"..."9").contains(l) {
            if r == "%" || r == "°" { return true }
            let rest = right.unicodeScalars.dropFirst()
            if r == "." && (rest.first.map { ("0"..."9").contains($0) } ?? false) { return true }
        }
        if l == "#" || r == "#" { return true }
        return false
    }

    // MARK: - Widths (F11)

    func displayWidth(_ text: String) -> Int {
        var width = 0
        for s in text.unicodeScalars {
            width += DeskFormatter.scalarWidth(s)
        }
        return width
    }

    /// The display width of UTF-8 bytes (ASCII counted directly).
    static func displayWidth(_ bytes: ArraySlice<UInt8>) -> Int {
        var width = 0
        var ascii = true
        for b in bytes {
            if b >= 0x80 { ascii = false; break }
            width += b >= 0x20 ? (b == 0x7F ? 1 : 1) : (b == 0x09 ? 4 : 0)
        }
        if ascii { return width }
        width = 0
        for s in String(decoding: bytes, as: UTF8.self).unicodeScalars { width += scalarWidth(s) }
        return width
    }

    static func scalarWidth(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v < 0x20 { return v == 0x09 ? 4 : 0 }
        if v < 0x7F { return 1 }
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v)
            || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v)
            || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v)
            || (0x1F900...0x1F9FF).contains(v) || (0x20000...0x3FFFD).contains(v) {
            return 2
        }
        return 1
    }

    // MARK: - Driver

    func edits() -> [TextEdit] {
        decideFromOriginal()
        var output = Output(bytes: bytes, starts: [])
        // Breaking the outermost construct first and measuring again gives the most natural result; a line that
        // still overflows after a few rounds (pathologically deep one-line code) has all its constructs broken.
        var rounds = 0
        while true {
            layout()
            output = render()
            rounds += 1
            if !breakOverflowingLines(output, all: rounds > 8) || rounds > 9 { break }
        }
        if rounds > 9 {
            layout()
            output = render()
        }
        settleNewline(&output)
        // Already in the canonical style.
        if output.bytes == bytes { return [] }
        if verify(output) { return minimalEdits(output) }
        // A file with errors can read differently once lines are split (a line that failed to parse may look like
        // another language's on its own): keep its line breaks as written and only normalise the rest.
        conservative = true
        brokenBlocks = []
        brokenChains = []
        for k in toks.indices { toks[k].remove = false }
        layout()
        newline = tree.lines.newline
        output = render()
        settleNewline(&output)
        if output.bytes == bytes { return [] }
        if verify(output) { return minimalEdits(output) }
        if ProcessInfo.processInfo.environment["DESK_FORMAT_DEBUG"] != nil {
            FileHandle.standardError.write(Data(("formatter: verification failed for:\n" + output.text + "\n").utf8))
        }
        return []
    }

    /// The shape of a parse, for checking that formatting kept it (F12): node kinds and token texts in order,
    /// without the separators a formatter may turn into line breaks and with the alternates it normalises.
    static func structure(_ tree: SyntaxTree) -> [String] {
        var out: [String] = []
        var walker = StructureWalker(tree.root)
        while let item = walker.next() {
            switch item {
            case .open(let node): out.append(node.kind.rawValue + (node.foreignKind.map { ":" + $0.rawValue } ?? "") + "(")
            case .close: out.append(")")
            case .token(let token, let alternate):
                out.append(alternate ?? (token.isMissing ? "<\(token.kind.rawValue)>" : token.text))
            }
        }
        return out
    }

    /// Whether two trees have the same shape in the sense of `structure`. The trees are compared pair of nodes by
    /// pair of nodes, each pair's children in place (the formatter runs this on every file it changes).
    static func sameStructure(_ a: SyntaxNode, _ b: SyntaxNode) -> Bool {
        guard a.kind == b.kind, a.foreignKind == b.foreignKind else { return false }
        var pairs: [(SyntaxNode, SyntaxNode)] = [(a, b)]
        while let (m, n) = pairs.popLast() {
            let kind = m.kind
            let left = m.children
            let right = n.children
            var i = 0
            var j = 0
            while true {
                while i < left.count, isSkipped(left[i], in: kind) { i += 1 }
                while j < right.count, isSkipped(right[j], in: kind) { j += 1 }
                if i == left.count || j == right.count {
                    if i != left.count || j != right.count { return false }
                    break
                }
                switch (left[i], right[j]) {
                case (.node(let x), .node(let y)):
                    guard x.kind == y.kind, x.foreignKind == y.foreignKind else { return false }
                    pairs.append((x, y))
                case (.token(let s), .token(let t)):
                    // A translation entry's `=` and `:` are the same token to the formatter.
                    let alternates = kind == .entry
                    let sAlternate = alternates && (s.kind == .equal || s.kind == .colon)
                    let tAlternate = alternates && (t.kind == .equal || t.kind == .colon)
                    if sAlternate || tAlternate {
                        if sAlternate != tAlternate { return false }
                    } else if s.isMissing != t.isMissing || (s.isMissing ? s.kind != t.kind : s.text != t.text) {
                        return false
                    }
                default:
                    return false
                }
                i += 1
                j += 1
            }
        }
        return true
    }

    /// Tokens `structure` leaves out: the end of the file, separators a formatter may turn into line breaks, and a
    /// language group's `:`.
    @inline(__always)
    private static func isSkipped(_ child: SyntaxChild, in kind: SyntaxKind) -> Bool {
        guard case .token(let t) = child else { return false }
        if t.kind == .eof { return true }
        if (kind == .block || kind == .sourceFile) && (t.kind == .semicolon || t.kind == .comma) { return true }
        return kind == .group && t.kind == .colon
    }

    /// Walks a tree for `structure` and `sameStructure`: nodes opened and closed, and the tokens that count.
    struct StructureWalker {
        enum Item {
            case open(SyntaxNode)
            case close
            /// A token, with the text it counts as when it is an accepted alternate.
            case token(Token, alternate: String?)
        }

        private var stack: [(node: SyntaxNode, next: Int)]

        init(_ root: SyntaxNode) { stack = [(root, 0)] }

        mutating func next() -> Item? {
            while !stack.isEmpty {
                let (node, next) = stack[stack.count - 1]
                guard next < node.children.count else {
                    stack.removeLast()
                    return .close
                }
                stack[stack.count - 1].next += 1
                switch node.children[next] {
                case .node(let child):
                    stack.append((child, 0))
                    return .open(child)
                case .token(let t):
                    if t.kind == .eof { continue }
                    if (node.kind == .block || node.kind == .sourceFile) && (t.kind == .semicolon || t.kind == .comma) {
                        continue
                    }
                    if node.kind == .group && t.kind == .colon { continue }
                    if node.kind == .entry && t.kind == .equal { return .token(t, alternate: ":") }
                    if node.kind == .entry && t.kind == .colon { return .token(t, alternate: ":") }
                    return .token(t, alternate: nil)
                }
            }
            return nil
        }
    }

    /// Breaks the outermost single-line block or modifier chain on each line wider than `maxWidth`. Returns
    /// whether a decision changed.
    func breakOverflowingLines(_ output: Output, all: Bool = false) -> Bool {
        let text = output.bytes
        // Line of each output offset.
        var lineStarts = [0]
        for (k, b) in text.enumerated() where b == 0x0A || (b == 0x0D && (k + 1 >= text.count || text[k + 1] != 0x0A)) {
            lineStarts.append(k + 1)
        }
        func line(of offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }
        // Width of each line up to the end of its last token (comments at the end of a line do not count).
        var lastTokenEnd = [Int](repeating: -1, count: lineStarts.count)
        var l = 0
        for k in toks.indices where !toks[k].remove && toks[k].role != .eof {
            let start = output.starts[k]
            let end = start + (toks[k].replacement?.utf8.count ?? (toks[k].end - toks[k].start))
            // Tokens come in order, so the line only moves forward.
            while l + 1 < lineStarts.count && lineStarts[l + 1] <= start { l += 1 }
            lastTokenEnd[l] = max(lastTokenEnd[l], end)
        }
        func width(ofLine l: Int) -> Int {
            let end = lastTokenEnd[l]
            guard end >= 0 else { return 0 }
            return DeskFormatter.displayWidth(text[lineStarts[l]..<end])
        }
        var candidates: [Int: [(depth: Double, isChain: Bool, id: Int)]] = [:]
        for (id, block) in blocks.enumerated() where !brokenBlocks.contains(id) && !block.frozen && block.open >= 0 {
            let l = line(of: output.starts[block.open])
            candidates[l, default: []].append((Double(block.depth), false, id))
        }
        for (id, chain) in chains.enumerated() where !brokenChains.contains(id) && chain.dots.count >= (chain.bare ? 2 : 1)
            && chain.start < toks.count && !toks[chain.start].frozen && !chain.dots.contains(where: { toks[$0].frozen }) {
            let l = line(of: output.starts[chain.dots[0]])
            candidates[l, default: []].append((Double(chain.depth) - 0.5, true, id))
        }
        var changed = false
        for (l, list) in candidates where width(ofLine: l) > options.maxWidth {
            if all {
                for candidate in list {
                    if candidate.isChain { brokenChains.insert(candidate.id) } else { brokenBlocks.insert(candidate.id) }
                }
                changed = changed || !list.isEmpty
                continue
            }
            guard let best = list.min(by: { ($0.depth, $0.isChain ? 0 : 1) < ($1.depth, $1.isChain ? 0 : 1) }) else { continue }
            if best.isChain { brokenChains.insert(best.id) } else { brokenBlocks.insert(best.id) }
            changed = true
        }
        return changed
    }

    /// The formatted text must parse to the same structure and tokens as the original, apart from separators
    /// turned into line breaks and normalised alternates (F12).
    func verify(_ output: Output) -> Bool {
        let reparsed = SyntaxParsing.parse(output.text, file: tree.file, version: 0)
        return DeskFormatter.sameStructure(tree.root, reparsed.root)
    }

    /// Edits that turn the original text into the rendered one, one per changed gap (bytes outside them never
    /// change). Tokens keep their text (or their replacement), so the gaps of both texts line up token by token.
    func minimalEdits(_ output: Output) -> [TextEdit] {
        let new = output.bytes
        if new == bytes { return [] }
        var edits: [TextEdit] = []
        var oldFrom = 0
        var newFrom = 0
        func flush(_ oldEnd: Int, _ newEnd: Int) {
            if bytes[oldFrom..<oldEnd].elementsEqual(new[newFrom..<newEnd]) { return }
            edits.append(TextEdit(file: tree.file, range: oldFrom..<oldEnd,
                                  replacement: String(decoding: new[newFrom..<newEnd], as: UTF8.self)))
        }
        for (k, tok) in toks.enumerated() where !tok.remove {
            let newStart = output.starts[k]
            let newLength = tok.replacement?.utf8.count ?? (tok.end - tok.start)
            if tok.replacement != nil {
                flush(tok.end, newStart + newLength)
            } else {
                flush(tok.start, newStart)
            }
            oldFrom = tok.end
            newFrom = newStart + newLength
        }
        flush(bytes.count, new.count)
        return mergeAdjacent(edits)
    }

    private func mergeAdjacent(_ edits: [TextEdit]) -> [TextEdit] {
        var out: [TextEdit] = []
        for edit in edits {
            if let last = out.last, last.range.upperBound == edit.range.lowerBound {
                out[out.count - 1] = TextEdit(file: last.file, range: last.range.lowerBound..<edit.range.upperBound,
                                              replacement: last.replacement + edit.replacement)
            } else {
                out.append(edit)
            }
        }
        return out
    }
}
