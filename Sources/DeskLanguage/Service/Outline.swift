import Foundation

// The shape of the open file for the editor: the outline (info or package, options with their sections, the widget's
// declarations and element tree with `if`, `for` and events, styles, translations by language), folding ranges, and
// the element at a position and back, for the two-way selection between the canvas and the code.

/// What an outline item is.
public enum DeskOutlineKind: String, Sendable, Hashable {
    case info, package, field, options, section, option, widget, variable, saved, computed, element, ifBlock, elseBlock,
         forLoop, event, style, translations, language, component, script
}

/// An item of the outline: its full range (trivia excluded), the range to select when it is chosen (its name, or
/// its first word), and the items inside it.
public struct DeskDocumentSymbol: Sendable, Hashable, CustomStringConvertible {
    public var name: String
    public var detail: String?
    public var kind: DeskOutlineKind
    public var range: DeskRange
    public var selectionRange: DeskRange
    public var children: [DeskDocumentSymbol]
    /// For an element, its reference in this snapshot (`range(of:)` finds it again).
    public var element: ElementRef?

    public init(name: String, detail: String? = nil, kind: DeskOutlineKind, range: DeskRange, selectionRange: DeskRange,
                children: [DeskDocumentSymbol] = [], element: ElementRef? = nil) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
        self.element = element
    }

    /// `kind name — detail @line:col-line:col`, then the children indented, one per line.
    public var description: String { lines(indent: "").joined(separator: "\n") }

    func lines(indent: String) -> [String] {
        var line = "\(indent)\(kind.rawValue) \(name)"
        if let detail { line += " — \(detail)" }
        line += " @\(range)"
        return [line] + children.flatMap { $0.lines(indent: indent + "  ") }
    }
}

/// What a folding range folds.
public enum DeskFoldingKind: String, Sendable, Hashable {
    /// `{ … }`
    case block
    /// `( … )` over several lines.
    case arguments
    /// `[ … ]` over several lines.
    case list
    /// Consecutive comment lines, or a comment over several lines.
    case comment
    /// Modifiers written on the lines after their element.
    case modifiers
    /// A language's block in `translations`.
    case language
}

/// A part of the file that can be folded: from the line of its first character to the line of its last.
public struct DeskFoldingRange: Sendable, Hashable, CustomStringConvertible {
    public var kind: DeskFoldingKind
    public var range: DeskRange

    public init(kind: DeskFoldingKind, range: DeskRange) {
        self.kind = kind
        self.range = range
    }

    /// 0-based.
    public var startLine: Int { range.start.line }
    public var endLine: Int { range.end.line }

    public var description: String { "\(kind.rawValue) \(startLine + 1)-\(endLine + 1)" }
}

/// An element of the widget and where its code is.
public struct DeskElementHit: Sendable, Hashable {
    /// The element's reference in this snapshot (its call).
    public var element: ElementRef
    public var component: String
    /// Its own name, given with `.name(…)`.
    public var name: String?
    /// The whole element: its call, its children's block and its modifiers.
    public var range: DeskRange
    /// Its component and arguments (`Text("{day.number}")`).
    public var callRange: DeskRange
    /// The innermost `for` that repeats it, and that `for`'s range: every instance of the element comes from this
    /// code.
    public var loop: NodeID?
    public var loopRange: DeskRange?

    public init(element: ElementRef, component: String, name: String?, range: DeskRange, callRange: DeskRange,
                loop: NodeID?, loopRange: DeskRange?) {
        self.element = element
        self.component = component
        self.name = name
        self.range = range
        self.callRange = callRange
        self.loop = loop
        self.loopRange = loopRange
    }
}

extension DeskSnapshot {
    // MARK: Elements

    /// The innermost element whose code holds a position (its call, block or modifiers, their actions included).
    public func elementAt(_ position: DeskPosition) -> DeskElementHit? {
        let table = nodeTable
        let offset = index.utf8Offset(ofUTF16: index.clampedUTF16(position.offset))
        guard let i = table.innermost(at: offset, where: { $0.kind == .callStmt && checked.elements[self.nodeID($0)] != nil })
        else { return nil }
        return elementHit(i)
    }

    /// Where an element of this snapshot is (nil for a reference of another snapshot).
    public func range(of element: ElementRef) -> DeskElementHit? {
        let table = nodeTable
        guard let i = table.indexes(of: element).first(where: { table.entries[$0].kind == .callStmt }),
              checked.elements[element] != nil else { return nil }
        return elementHit(i)
    }

    /// Every element of the file, in document order.
    public func elements() -> [DeskElementHit] {
        let table = nodeTable
        return table.entries.indices.filter {
            table.entries[$0].kind == .callStmt && checked.elements[table.id($0)] != nil
        }.compactMap(elementHit)
    }

    private func nodeID(_ entry: DeskNodeTable.Entry) -> NodeID {
        NodeID(kind: entry.kind, utf8Start: entry.textStart, treeVersion: tree.version)
    }

    private func elementHit(_ i: Int) -> DeskElementHit? {
        let table = nodeTable
        let entry = table.entries[i]
        let id = table.id(i)
        guard let facts = checked.elements[id] else { return nil }
        // The call: from the callee to the end of its arguments.
        var callEnd = entry.textStart
        for child in table.children(of: i) {
            let kind = table.entries[child].kind
            guard kind == .callee || kind == .argumentClause else { break }
            callEnd = max(callEnd, table.entries[child].textEnd)
        }
        let loop = table.ancestors(of: i).first { table.entries[$0].kind == .forStmt }
        return DeskElementHit(element: id, component: facts.component, name: facts.name,
                              range: index.range(utf8: entry.textRange),
                              callRange: index.range(utf8: entry.textStart..<callEnd),
                              loop: loop.map { table.id($0) },
                              loopRange: loop.map { index.range(utf8: table.entries[$0].textRange) })
    }

    // MARK: Outline

    /// The outline of the open file.
    public func documentSymbols() -> [DeskDocumentSymbol] {
        caches.outline.value { OutlineBuilder(snapshot: self, table: nodeTable).build() }
    }

    // MARK: Folding

    /// Every part of the file that can be folded, sorted by position: blocks, arguments and lists over several
    /// lines, runs of comment lines, modifier chains on their own lines, and the languages of `translations`.
    public func foldingRanges() -> [DeskFoldingRange] {
        caches.folding.value { FoldingBuilder(snapshot: self, table: nodeTable).build() }
    }
}

/// Builds the outline from the node table.
private struct OutlineBuilder {
    let snapshot: DeskSnapshot
    let table: DeskNodeTable

    var index: DeskTextIndex { snapshot.index }
    var language: DiagnosticLanguage { snapshot.options.messageLanguage }

    func build() -> [DeskDocumentSymbol] {
        var out: [DeskDocumentSymbol] = []
        for i in table.children(of: 0) {
            let entry = table.entries[i]
            switch entry.kind {
            case .infoBlock, .packageBlock:
                let fields = statements(inBlockOf: i).compactMap { field($0) }
                out.append(symbol(i, name: entry.kind == .infoBlock ? "info" : "package",
                                  kind: entry.kind == .infoBlock ? .info : .package, children: fields))
            case .optionsBlock:
                out.append(symbol(i, name: "options", kind: .options, children: optionItems(statements(inBlockOf: i))))
            case .widgetBlock:
                out.append(symbol(i, name: "widget", kind: .widget, children: viewItems(statements(inBlockOf: i))))
            case .styleDecl:
                let tokens = entry.positioned.childTokens
                guard tokens.count >= 2, !tokens[1].token.isMissing, tokens[1].kind != .lBrace else {
                    out.append(symbol(i, name: "style", kind: .style))
                    continue
                }
                out.append(symbol(i, name: tokens[1].token.name, kind: .style, selection: tokens[1].textRange))
            case .translationsBlock:
                out.append(symbol(i, name: "translations", kind: .translations,
                                  children: statements(inBlockOf: i).compactMap { languageGroup($0) }))
            case .componentDecl, .scriptBlock:
                let tokens = entry.positioned.childTokens
                let named = tokens.count >= 2 && tokens[1].kind == .identifier && !tokens[1].token.isMissing
                out.append(symbol(i, name: named ? tokens[1].token.name : tokens.first?.token.text ?? "",
                                  kind: entry.kind == .componentDecl ? .component : .script,
                                  selection: named ? tokens[1].textRange : nil))
            default:
                break
            }
        }
        return out
    }

    // MARK: Pieces

    func range(_ r: Range<Int>) -> DeskRange { index.range(utf8: r) }

    func symbol(_ i: Int, name: String, detail: String? = nil, kind: DeskOutlineKind, selection: Range<Int>? = nil,
                children: [DeskDocumentSymbol] = [], element: ElementRef? = nil) -> DeskDocumentSymbol {
        let entry = table.entries[i]
        let full = entry.textRange
        var chosen = selection ?? firstTokenRange(i) ?? full
        if chosen.lowerBound < full.lowerBound || chosen.upperBound > full.upperBound { chosen = full }
        return DeskDocumentSymbol(name: name, detail: detail, kind: kind, range: range(full), selectionRange: range(chosen),
                                  children: children, element: element)
    }

    func firstTokenRange(_ i: Int) -> Range<Int>? {
        var found: Range<Int>?
        let entry = table.entries[i]
        entry.node.walkTokens(base: entry.offset) { token, at in
            guard !token.isMissing else { return true }
            let start = at + token.leadingTrivia.utf8Length
            found = start..<(start + token.text.utf8.count)
            return false
        }
        return found
    }

    /// The statements of the block that is a direct child of node `i`.
    func statements(inBlockOf i: Int) -> [Int] {
        guard let block = table.children(of: i).first(where: { table.entries[$0].kind == .block }) else { return [] }
        return table.children(of: block).filter { table.entries[$0].kind != .unexpected }
    }

    func text(_ r: Range<Int>) -> String {
        let bytes = index.bytes
        let lower = max(0, min(r.lowerBound, bytes.count))
        let upper = max(lower, min(r.upperBound, bytes.count))
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }

    /// A value as one short line.
    func short(_ r: Range<Int>, limit: Int = 40) -> String {
        let words = text(r).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        let line = words.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    func field(_ i: Int) -> DeskDocumentSymbol? {
        let entry = table.entries[i]
        guard entry.kind == .field else { return nil }
        let children = table.children(of: i)
        guard let label = children.first(where: { table.entries[$0].kind == .label }) else { return nil }
        let value = children.last.flatMap { $0 == label ? nil : $0 }
        return symbol(i, name: short(table.entries[label].textRange), detail: value.map { short(table.entries[$0].textRange) },
                      kind: .field, selection: table.entries[label].textRange)
    }

    func optionItems(_ items: [Int]) -> [DeskDocumentSymbol] {
        var out: [DeskDocumentSymbol] = []
        for i in items {
            let entry = table.entries[i]
            switch entry.kind {
            case .optionDecl:
                let node = entry.positioned
                guard let target = node.firstChild(.target) else { continue }
                let name = TargetSyntax(unchecked: target).name
                guard !name.token.isMissing else { continue }
                let control = OptionDeclSyntax(unchecked: node).controlCall?.callee.path.joined(separator: ".")
                out.append(symbol(i, name: name.token.name, detail: control, kind: .option, selection: name.textRange))
            case .field:
                // `name: Toggle(…)`: an option written like a field.
                if let item = field(i) { out.append(DeskDocumentSymbol(name: item.name, detail: item.detail, kind: .option,
                                                                        range: item.range, selectionRange: item.selectionRange)) }
            case .callStmt:
                let call = CallStmtSyntax(unchecked: entry.positioned)
                let callee = call.callee.path.joined(separator: ".")
                guard callee == "Section" else { continue }
                let title = call.arguments?.arguments.first.flatMap { StringLiteralSyntax($0.value.node)?.literalValue }
                out.append(symbol(i, name: title ?? callee, detail: title == nil ? nil : callee, kind: .section,
                                  children: optionItems(statements(inBlockOf: i))))
            default:
                break
            }
        }
        return out
    }

    func viewItems(_ items: [Int]) -> [DeskDocumentSymbol] {
        var out: [DeskDocumentSymbol] = []
        for i in items {
            let entry = table.entries[i]
            switch entry.kind {
            case .declaration:
                let tokens = entry.positioned.childTokens
                guard tokens.count >= 2, !tokens[1].token.isMissing else { continue }
                let keyword = tokens[0].token.text.lowercased()
                let kind: DeskOutlineKind = keyword == "saved" ? .saved : keyword == "computed" ? .computed : .variable
                let value = table.children(of: i).last.map { short(table.entries[$0].textRange) }
                out.append(symbol(i, name: tokens[1].token.name, detail: value, kind: kind, selection: tokens[1].textRange))
            case .callStmt:
                out.append(element(i))
            case .ifStmt:
                out += ifChain(i)
            case .forStmt:
                let node = ForStmtSyntax(unchecked: entry.positioned)
                let header = entry.textStart..<max(entry.textStart, node.source.node.quickTextRange.upperBound)
                out.append(symbol(i, name: short(header), kind: .forLoop,
                                  selection: node.variable.token.isMissing ? nil : node.variable.textRange,
                                  children: viewItems(statements(inBlockOf: i)) + events(of: i)))
            case .strayStatement:
                out += viewItems(table.children(of: i))
            default:
                break
            }
        }
        return out
    }

    /// `if` and its `else if` / `else` branches, as siblings.
    func ifChain(_ i: Int) -> [DeskDocumentSymbol] {
        var out: [DeskDocumentSymbol] = []
        var current: Int? = i
        var first = true
        while let ifIndex = current {
            current = nil
            let entry = table.entries[ifIndex]
            let children = table.children(of: ifIndex)
            let condition = children.first { table.entries[$0].kind.isExpression }
            let headerEnd = condition.map { table.entries[$0].textEnd } ?? entry.textStart
            let name = (first ? "" : "else ") + short(entry.textStart..<headerEnd)
            let block = children.first { table.entries[$0].kind == .block }
            let bodyEnd = block.map { table.entries[$0].textEnd } ?? entry.textEnd
            var item = symbol(ifIndex, name: name, kind: .ifBlock, children: viewItems(statements(inBlockOf: ifIndex)))
            item.range = range(entry.textStart..<max(entry.textStart, bodyEnd))
            out.append(item)
            first = false
            guard let elseClause = children.first(where: { table.entries[$0].kind == .elseClause }),
                  let body = table.children(of: elseClause).first else { continue }
            if table.entries[body].kind == .ifStmt {
                current = body
            } else {
                var elseItem = symbol(elseClause, name: "else", kind: .elseBlock,
                                      children: viewItems(table.children(of: body).filter { table.entries[$0].kind != .unexpected }))
                elseItem.range = range(table.entries[elseClause].textRange)
                out.append(elseItem)
            }
        }
        return out
    }

    func element(_ i: Int) -> DeskDocumentSymbol {
        let entry = table.entries[i]
        let id = table.id(i)
        let call = CallStmtSyntax(unchecked: entry.positioned)
        let callee = call.callee
        let component = callee.path.joined(separator: ".")
        let facts = snapshot.checked.elements[id]
        let firstArgument = call.arguments?.arguments.first { $0.label == nil }
        let firstText = firstArgument.map { short($0.value.node.quickTextRange) }
        let name = facts?.name ?? component
        let detail = facts?.name != nil ? component : firstText
        let children = viewItems(statements(inBlockOf: i)) + events(of: i)
        return symbol(i, name: name, detail: detail, kind: .element,
                      selection: callee.name.token.isMissing ? nil : callee.name.textRange, children: children,
                      element: facts == nil ? nil : id)
    }

    /// The modifiers of a statement whose block holds actions (`.onClick { }`, `.every(1s) { }`).
    func events(of i: Int) -> [DeskDocumentSymbol] {
        var out: [DeskDocumentSymbol] = []
        for m in table.children(of: i) where table.entries[m].kind == .modifierApp {
            let tokens = table.entries[m].positioned.childTokens
            guard tokens.count >= 2, !tokens[1].token.isMissing else { continue }
            let name = tokens[1].token.name
            guard let spec = snapshot.options.catalog.modifier(named: name), case .actions = spec.block else { continue }
            let arguments = table.children(of: m).first { table.entries[$0].kind == .argumentClause }
            out.append(symbol(m, name: "." + name, detail: arguments.map { short(table.entries[$0].textRange) },
                              kind: .event, selection: tokens[1].textRange))
        }
        return out
    }

    func languageGroup(_ i: Int) -> DeskDocumentSymbol? {
        let entry = table.entries[i]
        guard entry.kind == .group else { return nil }
        let group = GroupSyntax(unchecked: entry.positioned)
        let tag = group.tag.literalValue ?? short(group.tag.node.quickTextRange)
        let count = group.block.statements.filter { $0.kind == .entry }.count
        let detail = LocalizedText(count == 1 ? "1 entry" : "\(count) entries", "\(count) 条").text(in: language)
        return symbol(i, name: tag, detail: detail, kind: .language, selection: group.tag.node.quickTextRange)
    }
}

/// Builds the folding ranges from the node table and the comments.
private struct FoldingBuilder {
    let snapshot: DeskSnapshot
    let table: DeskNodeTable

    var index: DeskTextIndex { snapshot.index }

    func build() -> [DeskFoldingRange] {
        var out: [DeskFoldingRange] = []
        func add(_ kind: DeskFoldingKind, _ r: Range<Int>) {
            guard r.upperBound > r.lowerBound, index.line(ofUTF8: r.lowerBound) < index.line(ofUTF8: r.upperBound) else { return }
            out.append(DeskFoldingRange(kind: kind, range: index.range(utf8: r)))
        }
        for (i, entry) in table.entries.enumerated() {
            switch entry.kind {
            case .block:
                let parent = entry.parent >= 0 ? table.entries[entry.parent].kind : .sourceFile
                add(parent == .group ? .language : .block, entry.textRange)
            case .argumentClause, .parenExpr, .parameterClause:
                add(.arguments, entry.textRange)
            case .listLiteral:
                add(.list, entry.textRange)
            case .scriptBlock:
                add(.block, entry.textRange)
            case .callStmt, .forStmt, .ifStmt:
                // Modifiers written after the element, from the end of what they follow to the end of the last.
                let children = table.children(of: i)
                guard let firstModifier = children.firstIndex(where: { table.entries[$0].kind == .modifierApp }),
                      firstModifier > 0, let last = children.last, table.entries[last].kind == .modifierApp else { continue }
                let headEnd = table.entries[children[firstModifier - 1]].textEnd
                add(.modifiers, headEnd..<table.entries[last].textEnd)
            default:
                break
            }
        }
        out += comments()
        var seen = Set<DeskFoldingRange>()
        return out.filter { seen.insert($0).inserted }.sorted {
            ($0.range.start.offset, -$0.range.end.offset) < ($1.range.start.offset, -$1.range.end.offset)
        }
    }

    /// Runs of line comments on consecutive lines, and block comments over several lines.
    func comments() -> [DeskFoldingRange] {
        var out: [DeskFoldingRange] = []
        var run: (start: Int, end: Int, lastLine: Int, count: Int)?
        func close() {
            if let r = run, r.count >= 2 { out.append(DeskFoldingRange(kind: .comment, range: index.range(utf8: r.start..<r.end))) }
            run = nil
        }
        snapshot.tree.root.walkTokens { token, at in
            var offset = at
            func visit(_ pieces: [Trivia]) {
                for piece in pieces {
                    let length = piece.utf8Length
                    switch piece {
                    case .lineComment:
                        let line = index.line(ofUTF8: offset)
                        // Only comments alone on their line make a run.
                        let lineStart = index.utf8Range(ofLine: line).lowerBound
                        guard index.bytes[lineStart..<offset].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF }) else {
                            close()
                            break
                        }
                        if let r = run, r.lastLine + 1 == line {
                            run = (r.start, offset + length, line, r.count + 1)
                        } else {
                            close()
                            run = (offset, offset + length, line, 1)
                        }
                    case .blockComment:
                        close()
                        if index.line(ofUTF8: offset) < index.line(ofUTF8: offset + length) {
                            out.append(DeskFoldingRange(kind: .comment, range: index.range(utf8: offset..<(offset + length))))
                        }
                    case .spaces, .tabs, .newline, .byteOrderMark:
                        break
                    default:
                        close()
                    }
                    offset += length
                }
            }
            visit(token.leadingTrivia)
            if !token.text.isEmpty { close() }
            offset += token.text.utf8.count
            visit(token.trailingTrivia)
            return true
        }
        close()
        return out
    }
}
