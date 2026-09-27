import Foundation

// Phase C0 (§4.1): the file's blocks, what each block holds (§2.4), declaration order, the root, and the statements
// that do not belong where they are written. View statements build the element tree; the other phases run on each
// element as it is reached.

/// Where view statements are being checked.
struct ViewContext {
    var parent: ElementNode?
    /// `nil` at the widget body; `"menu"` inside `.menu { }` and `Menu { }`.
    var parentComponent: String?
    var place: Place = .views
    var insideIf = false
    var forDepth = 0
    var loopIDs: [NodeID] = []
    /// Inside the block of an unknown component: statements that do not fit the guessed kind are not reported.
    var guessing = false
    var isWidgetBody = false
    /// How many instances each element here stands for (the product of the enclosing `for` bounds).
    var multiplier = 1
}

extension Checker {
    // MARK: - Top level

    func checkStructure() {
        let root = tree.rootNode
        var widgets: [PositionedNode] = [], infos: [PositionedNode] = [], optionBlocks: [PositionedNode] = []
        var translationBlocks: [PositionedNode] = [], packages: [PositionedNode] = []
        var strays: [PositionedNode] = []
        var styleDecls: [PositionedNode] = []
        for item in root.childNodes {
            switch item.kind {
            case .infoBlock: infos.append(item)
            case .packageBlock: packages.append(item)
            case .optionsBlock: optionBlocks.append(item)
            case .widgetBlock: widgets.append(item)
            case .translationsBlock: translationBlocks.append(item)
            case .styleDecl: styleDecls.append(item)
            case .componentDecl:
                let keyword = item.childTokens.first
                report(.reservedBlock, keyword.map(range) ?? range(item), ["block": .code("component")])
            case .scriptBlock:
                let keyword = item.childTokens.first
                report(.reservedBlock, keyword.map(range) ?? range(item), ["block": .code("script")])
            case .strayStatement:
                if let statement = item.childNodes.first { strays.append(statement) }
            default:
                break
            }
        }
        func duplicates(_ blocks: [PositionedNode], _ word: String) -> PositionedNode? {
            for extra in blocks.dropFirst() {
                let at = extra.childTokens.first.map(range) ?? range(extra)
                report(.duplicateBlock, at, ["block": .code(word)], notes: [note("otherCopy", keyword(blocks[0]))])
            }
            return blocks.first
        }
        infoBlock = duplicates(infos, "info")
        packageBlock = duplicates(packages, "package")
        optionsBlock = duplicates(optionBlocks, "options")
        widgetBlock = duplicates(widgets, "widget")
        translationsBlock = duplicates(translationBlocks, "translations")

        if isPackage {
            for widget in widgets { report(.widgetInPackage, keyword(widget)) }
            for info in infos { report(.notAllowedHere, keyword(info), ["what": .name("construct:infoBlock"),
                                                                           "place": .name("place:packageFile"),
                                                                           "hint": .text(LocalizedText("", ""))]) }
            widgetBlock = nil
        } else {
            for package in packages { report(.packageInWidget, keyword(package)) }
        }

        // Stray top-level statements (DK2034, DK2015, DK2014, DK2013).
        let strayItems = checkStrays(strays)

        // Declarations and names first: options, styles, the widget's declarations, element names.
        if let info = infoBlock ?? packageBlock { collectInfo(info) }
        if let package = context.package, !isPackage { importPackage(package) }
        if let options = optionsBlock { collectOptions(options) }
        for style in styleDecls { collectStyle(style) }
        if let widget = widgetBlock, let block = widget.firstChild(.block) { collectDeclarations(block, strays: strayItems.declarations) }
        else { collectDeclarations(nil, strays: strayItems.declarations) }
        prewalkElementNames()

        if let info = infoBlock ?? packageBlock { checkInfo(info) }
        if let options = optionsBlock { checkOptions(options) }
        checkDeclarations()
        for style in styleOrder where !style.fromPackage { checkStyleBody(style) }
        if let widget = widgetBlock, let block = widget.firstChild(.block) {
            checkWidgetBody(block)
        } else if !isPackage {
            if strayItems.elements.isEmpty && strayItems.declarations.isEmpty {
                let at = root.childNodes.first.map(range) ?? 0..<0
                let insertAt = tree.text.utf8.count
                let prefix = tree.text.isEmpty || tree.text.hasSuffix("\n") || tree.text.hasSuffix("\r") ? "" : lineBreak
                report(.missingWidget, at.isEmpty ? 0..<0 : at.lowerBound..<at.lowerBound,
                       fixIts: [fix("insert", [edit(insertAt..<insertAt, prefix + "widget {" + lineBreak + "}" + lineBreak)],
                                    ["text": .code("widget { }")])])
            }
        }
        // Stray elements are checked as views so their own mistakes show too; they are not part of the widget.
        var strayContext = ViewContext()
        strayContext.guessing = false
        for element in strayItems.elements { checkViewStatement(element, strayContext) }
        if let translations = translationsBlock { checkTranslations(translations) }
        for dropped in strayItems.declarations { _ = dropped }
    }

    func keyword(_ block: PositionedNode) -> Range<Int> {
        block.childTokens.first.map(range) ?? range(block)
    }

    /// Stray statements at the top level. Returns the elements and declarations the DK2034 fix-it moves.
    func checkStrays(_ strays: [PositionedNode]) -> (elements: [PositionedNode], declarations: [PositionedNode]) {
        var elements: [PositionedNode] = []
        var declarations: [PositionedNode] = []
        var movable: [PositionedNode] = []
        for statement in strays {
            switch statement.kind {
            case .callStmt:
                let call = CallStmtSyntax(unchecked: statement)
                let path = call.callee.path
                let first = call.callee.name.token
                // A block word with parentheses (`info ({ … }`): already at the top level; the parser reports
                // what is wrong with it, and it is neither an element to move into `widget` nor a block to move out.
                if path.count == 1, Chars.blockWords.contains(first.name), call.arguments != nil { continue }
                if path.count == 1, !first.isUpperName, call.arguments == nil, call.block != nil,
                   first.kind == .identifier {
                    // `settings { … }`: a name followed by a block is not a block of a Desk file.
                    let words = ["info", "options", "widget", "style", "translations"]
                    let suggestion = DidYouMean.closest(first.name, among: words)
                    var fixIts: [FixIt] = []
                    if let s = suggestion { fixIts.append(fix("didYouMean", [edit(range(call.callee.name), s)], ["text": .code(s)])) }
                    report(.unknownBlock, range(call.callee.name), ["word": .code(first.name)], fixIts: fixIts)
                    continue
                }
                elements.append(statement)
                movable.append(statement)
            case .ifStmt, .forStmt:
                elements.append(statement)
                movable.append(statement)
            case .declaration:
                declarations.append(statement)
                movable.append(statement)
            case .assignment:
                movable.append(statement)
                reportStrayTopLevel(statement, fixIt: nil)
            case .modifierStmt:
                let modifiers = ModifierStmtSyntax(unchecked: statement).modifiers
                if modifiers.count == 1, modifiers[0].arguments == nil, let block = modifiers[0].block,
                   block.statements.contains(where: { $0.kind == .field }) {
                    report(.cssSelector, range(statement), ["name": .code(modifiers[0].name.token.name)])
                } else {
                    report(.modifierWithoutElement, range(statement))
                }
            case .field:
                report(.notAllowedHere, range(statement), ["what": .name("construct:field"), "place": .name("place:topLevel"),
                                                           "hint": hintText(.notAllowedHere, "fieldOutsideInfo")])
            case .entry, .group:
                report(.notAllowedHere, range(statement), ["what": .name("construct:translation"),
                                                           "place": .name("place:topLevel"),
                                                           "hint": .text(LocalizedText("", ""))])
            default:
                break
            }
        }
        // One fix-it for all of them, built once and shared (its edits are one array, not one per diagnostic).
        let strayFix = strayFixIt(movable.filter { $0.kind != .assignment })
        for statement in movable where statement.kind != .assignment {
            reportStrayTopLevel(statement, fixIt: strayFix)
        }
        return (elements, declarations)
    }

    func reportStrayTopLevel(_ statement: PositionedNode, fixIt: FixIt?) {
        report(.strayTopLevel, range(statement), fixIts: fixIt.map { [$0] } ?? [])
    }

    /// DK2034's fix-it: the stray statements, each with the comment lines above it, wrapped in a new
    /// `widget { }` where the first one stands (no widget block), or moved into the widget (declarations to its
    /// top, elements to its end, on lines of their own). Styles, `info` and comments between them stay where they
    /// are. None when the widget's `}` is missing (DK2001 inserts it first).
    func strayFixIt(_ strays: [PositionedNode]) -> FixIt? {
        guard !strays.isEmpty else { return nil }
        let editor = SyntaxEditor(tree: tree)
        let extents = strays.map(editor.extent(of:))
        func pieceLines(_ e: SyntaxEditor.Extent, indent: Int) -> [String] {
            if e.ownsLines { return editor.shifted(e, to: indent).lines }
            return [String(repeating: " ", count: indent) + text(e.text)]
        }
        let widget = widgetBlock ?? tree.rootNode.childNodes.first(where: { $0.kind == .widgetBlock })
        guard let widget, let block = widget.firstChild(.block) else {
            // Wrap: the first stray's lines become the new widget holding all of them; the others are removed.
            var inner: [String] = []
            for e in extents { inner += pieceLines(e, indent: 4) }
            let first = extents[0]
            let wrapped = "widget {" + lineBreak + inner.joined(separator: lineBreak) + lineBreak + "}"
            var edits: [TextEdit] = []
            if first.ownsLines {
                edits.append(edit(first.range, wrapped + lineBreak))
            } else {
                edits.append(edit(first.text, wrapped))
            }
            for e in extents.dropFirst() { edits.append(stripFile(editor.removal(of: e), editor)) }
            return fix("wrapIn", edits, ["text": .code("widget { }")])
        }
        let body = BlockSyntax(unchecked: block)
        guard body.isClosed else { return nil }
        let singleLine = editor.isSingleLine(block)
        let indent = singleLine ? editor.ownerIndent(of: block) + 4 : editor.contentIndent(of: block)
        var declLines: [String] = [], viewLines: [String] = []
        var edits: [TextEdit] = []
        for (s, e) in zip(strays, extents) {
            edits.append(stripFile(editor.removal(of: e), editor))
            if s.kind == .declaration { declLines += pieceLines(e, indent: indent) } else { viewLines += pieceLines(e, indent: indent) }
        }
        if singleLine {
            let pad = String(repeating: " ", count: indent)
            let existing = editor.statements(of: block).map { pad + text(editor.extent(of: $0).text) }
            let all = declLines + existing + viewLines
            let replacement = "{" + lineBreak + all.joined(separator: lineBreak) + lineBreak
                + String(repeating: " ", count: editor.ownerIndent(of: block)) + "}"
            edits.append(edit(body.lBrace.textStart..<body.rBrace.textRange.upperBound, replacement))
        } else {
            let items = editor.statements(of: block)
            for (lines, index) in [(declLines, 0), (viewLines, items.count)] where !lines.isEmpty {
                let piece = SyntaxEditor.Lines(lines: lines, statementLine: 0, kind: nil, from: nil)
                guard let insertion = editor.insertion(of: piece, into: block, index: index) else { return nil }
                edits.append(stripFile(insertion.edit, editor))
            }
        }
        edits.sort { $0.range.lowerBound < $1.range.lowerBound }
        for (a, b) in zip(edits, edits.dropFirst()) where a.range.upperBound > b.range.lowerBound { return nil }
        return fix("moveInto", edits, ["text": .code("widget")])
    }

    /// An editor edit in this file.
    func stripFile(_ e: TextEdit, _ editor: SyntaxEditor) -> TextEdit { edit(e.range, e.replacement) }

    // MARK: - Element-name prewalk

    /// Records every `.name(…)` of the widget before checking, so show/hide and positions can refer to elements
    /// written later.
    func prewalkElementNames() {
        guard let widget = widgetBlock, let block = widget.firstChild(.block) else { return }
        prewalkNames(in: block, insideIf: false, insideFor: false, container: nil)
    }

    private func prewalkNames(in block: PositionedNode, insideIf: Bool, insideFor: Bool, container: PositionedNode?) {
        for statement in block.childNodes {
            switch statement.kind {
            case .callStmt:
                let call = CallStmtSyntax(unchecked: statement)
                for modifier in call.modifiers where modifier.name.token.text == "name" {
                    guard let argument = modifier.arguments?.arguments.first else { continue }
                    let value = argument.value.node
                    var name: String?
                    var quoted = false
                    if value.kind == .identifierExpr { name = IdentifierExprSyntax(unchecked: value).name }
                    else if value.kind == .stringLiteral, let s = StringLiteralSyntax(unchecked: value).literalValue {
                        name = s
                        quoted = true
                    }
                    guard let n = name else { continue }
                    preNames.append(PreName(name: n, call: statement, container: container, insideIf: insideIf,
                                            insideFor: insideFor, range: range(value), quoted: quoted))
                }
                if let inner = call.block {
                    prewalkNames(in: inner.node, insideIf: false, insideFor: false, container: statement)
                    _ = inner
                }
            case .ifStmt:
                var current: PositionedNode? = statement
                while let ifNode = current {
                    if let b = ifNode.firstChild(.block) { prewalkNames(in: b, insideIf: true, insideFor: insideFor, container: container) }
                    current = nil
                    if let elseClause = ifNode.firstChild(.elseClause), let body = elseClause.childNodes.first {
                        if body.kind == .ifStmt { current = body }
                        else if body.kind == .block { prewalkNames(in: body, insideIf: true, insideFor: insideFor, container: container) }
                    }
                }
            case .forStmt:
                if let b = statement.firstChild(.block) { prewalkNames(in: b, insideIf: insideIf, insideFor: true, container: container) }
            default:
                break
            }
        }
    }

    // MARK: - Widget body

    func checkWidgetBody(_ block: PositionedNode) {
        let body = BlockSyntax(unchecked: block)
        let statements = body.statements
        var sawView = false
        var views: [PositionedNode] = []
        for statement in statements {
            switch statement.kind {
            case .declaration:
                if sawView { reportDeclarationAfterView(statement, widgetBlock: block) }
            case .foreignConstruct, .unexpected:
                break
            default:
                if statement.kind == .callStmt, isMissingDotModifier(statement) { break }
                if statement.kind == .callStmt || statement.kind == .ifStmt || statement.kind == .forStmt {
                    sawView = true
                    views.append(statement)
                }
            }
        }
        if statements.filter({ $0.kind != .declaration }).isEmpty {
            report(.emptyWidget, keyword(widgetBlock!))
        }
        var context = ViewContext()
        context.isWidgetBody = true
        let topViews = views
        let callViews = topViews.filter { $0.kind == .callStmt }
        if topViews.count > 1 {
            // Several top-level statements: an implicit Column (DK2021, fix-it "wrap in Column").
            let first = topViews.first!, last = topViews.last!
            let start = first.range.lowerBound, end = range(last).upperBound
            let wrapped = text(textStart(first)..<end)
            let indent = indentation(at: textStart(first))
            let inner = wrapped.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? String($0) : "    " + $0 }.joined(separator: "\n")
            let replacement = "Column {" + lineBreak + indent + inner + lineBreak + indent + "}"
            _ = start
            report(.multipleRoots, range(first), ["count": .number(topViews.count)],
                   fixIts: [fix("wrapIn", [edit(textStart(first)..<end, replacement)], ["text": .code("Column { }")])])
        }
        for statement in statements {
            if statement.kind == .declaration { continue }
            let before = allElements.count
            checkViewStatement(statement, context)
            if statement.kind == .callStmt, topViews.count == 1, callViews.count == 1 {
                if let root = allElements[safe: before], root.node.range == statement.range {
                    root.isRoot = true
                    root.facts.isRoot = true
                    rootElements = [root]
                }
            } else if statement.kind == .callStmt, let element = allElements[safe: before],
                      element.node.range == statement.range {
                rootElements.append(element)
            }
        }
        for root in rootElements where root.isRoot { checkRootElement(root) }
    }

    /// `font(.caption)` on the line after an element: a modifier without its dot, not an element.
    func isMissingDotModifier(_ statement: PositionedNode) -> Bool {
        let call = CallStmtSyntax(unchecked: statement)
        let token = call.callee.name.token
        return call.callee.path.count == 1 && !token.isUpperName && catalog.modifier(named: token.name) != nil
            && catalog.function(named: token.name) == nil
    }

    func reportDeclarationAfterView(_ statement: PositionedNode, widgetBlock block: PositionedNode?) {
        let decl = DeclarationSyntax(unchecked: statement)
        var fixIts: [FixIt] = []
        if let block {
            let body = BlockSyntax(unchecked: block)
            let open = body.lBrace.textRange.upperBound
            let r = range(statement)
            let indent = indentation(at: r.lowerBound)
            fixIts.append(fix("moveToTop", [edit(statement.range.lowerBound..<r.upperBound, ""),
                                            edit(open..<open, lineBreak + indent + text(r))]))
        }
        report(.declarationAfterView, range(statement), ["keyword": .code(decl.keyword.token.text),
                                                         "name": .code(decl.name.token.text)], fixIts: fixIts)
    }

    // MARK: - View statements

    func checkViewStatements(_ block: PositionedNode, _ context: ViewContext) {
        for statement in BlockSyntax(unchecked: block).statements { checkViewStatement(statement, context) }
    }

    func checkViewStatement(_ statement: PositionedNode, _ context: ViewContext) {
        switch statement.kind {
        case .callStmt:
            if context.place == .menu { checkMenuCall(statement, context) } else { checkViewCall(statement, context) }
        case .ifStmt:
            checkViewIf(statement, context)
        case .forStmt:
            checkViewFor(statement, context)
        case .declaration:
            if !context.guessing { reportDeclarationAfterView(statement, widgetBlock: widgetBlock?.firstChild(.block)) }
        case .assignment:
            if !context.guessing { checkAssignmentInViews(statement) }
        case .modifierStmt:
            if !context.guessing { report(.modifierWithoutElement, range(statement)) }
        case .field where isCssField(statement):
            reportCssField(statement)
        case .field:
            if !context.guessing {
                report(.notAllowedHere, range(statement), ["what": .name("construct:field"),
                                                           "place": .name(context.place == .menu ? "place:menu" : "place:widget"),
                                                           "hint": hintText(.notAllowedHere, "fieldOutsideInfo")])
            }
        case .entry, .group:
            if !context.guessing {
                report(.notAllowedHere, range(statement), ["what": .name("construct:translation"),
                                                           "place": .name("place:widget"),
                                                           "hint": .text(LocalizedText("", ""))])
            }
        case .styleDecl, .componentDecl:
            reportMoveOut(statement, what: statement.kind == .styleDecl ? "construct:style" : "construct:component")
        case .optionDecl:
            break
        default:
            break
        }
    }

    static let cssProperties: Set<String> = ["color", "background", "padding", "margin", "width", "height", "opacity",
                                              "display", "border", "gap", "font", "position", "top", "left", "right", "bottom"]

    /// `color: red;` among elements: a CSS declaration (DK9202).
    func isCssField(_ statement: PositionedNode) -> Bool {
        let field = FieldSyntax(unchecked: statement)
        guard Checker.cssProperties.contains(field.label.name) else { return false }
        let line = lineText(at: textStart(statement))
        return line.trimmingCharacters(in: .whitespaces).hasSuffix(";") || field.value.node.kind == .identifierExpr
    }

    func reportCssField(_ statement: PositionedNode) {
        let synthetic = Diagnostic(id: .cssDeclaration, severity: .error, file: file, range: range(statement),
                                   arguments: ["property": .code(FieldSyntax(unchecked: statement).label.name)])
        if let enriched = enrichCss(synthetic) {
            report(enriched.id, enriched.range, enriched.arguments, fixIts: enriched.fixIts)
        }
    }

    /// A block or top-level declaration written inside `widget` (DK2014, fix-it "move out of `widget`").
    func reportMoveOut(_ statement: PositionedNode, what: String) {
        var fixIts: [FixIt] = []
        if let widget = widgetBlock {
            let r = range(statement)
            let end = tree.text.utf8.count
            let widgetEnd = range(widget).upperBound
            let insertAt = min(widgetEnd, end)
            fixIts.append(fix("moveOutOfWidget", [edit(statement.range.lowerBound..<r.upperBound, ""),
                                                  edit(insertAt..<insertAt, lineBreak + lineBreak + text(r))]))
        }
        report(.notAllowedHere, range(statement), ["what": .name(what), "place": .name("place:widget"),
                                                   "hint": hintText(.notAllowedHere, "moveOut")], fixIts: fixIts)
    }

    func checkViewIf(_ statement: PositionedNode, _ context: ViewContext) {
        let ifStmt = IfStmtSyntax(unchecked: statement)
        var inner = context
        inner.insideIf = true
        var exprContext = ExprContext()
        exprContext.place = .views
        exprContext.loopScope = context.loopIDs
        exprContext.usage = .logic
        exprContext.element = context.parent
        checkCondition(ifStmt.condition.node, exprContext)
        checkViewStatements(ifStmt.block.node, inner)
        if let elseClause = ifStmt.elseClause {
            let body = elseClause.body
            if body.kind == .ifStmt { checkViewIf(body, context) }
            else if body.kind == .block { checkViewStatements(body, inner) }
        }
        reportModifiersAfterBlock(ifStmt.modifiers, construct: "if", statement: statement, inViews: context.place != .menu)
    }

    func checkViewFor(_ statement: PositionedNode, _ context: ViewContext) {
        let forStmt = ForStmtSyntax(unchecked: statement)
        var exprContext = ExprContext()
        exprContext.place = .views
        exprContext.loopScope = context.loopIDs
        exprContext.usage = .display
        exprContext.element = context.parent
        let (variable, element) = checkForHeader(forStmt, exprContext, inAction: false, depth: context.forDepth)
        var inner = context
        inner.forDepth += 1
        inner.loopIDs.append(id(statement))
        inner.multiplier = Checker.saturatingProduct(context.multiplier, forBound(forStmt.source.node))
        pushLoop(variable, element)
        checkViewStatements(forStmt.block.node, inner)
        popLoop(variable)
        reportModifiersAfterBlock(forStmt.modifiers, construct: "for", statement: statement, inViews: context.place != .menu)
    }

    /// `a * b` capped well above every element limit: the estimate only needs to know it is over the limit.
    static func saturatingProduct(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? estimateCap : min(product, estimateCap)
    }

    /// `a + b` with the same cap.
    static func saturatingSum(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? estimateCap : min(sum, estimateCap)
    }

    static let estimateCap = 1_000_000_000

    /// How many instances a `for` makes at most: list literals and ranges exactly, data lists by their catalog
    /// maximum, at most 1,000.
    func forBound(_ source: PositionedNode) -> Int {
        let limit = catalog.limits.maximumForInstances
        switch source.kind {
        case .listLiteral:
            return min(limit, ListLiteralSyntax(unchecked: source).elements.count)
        case .rangeExpr:
            let r = RangeExprSyntax(unchecked: source)
            if let a = NumberLiteralSyntax(r.low.node)?.value, let b = NumberLiteralSyntax(r.high.node)?.value {
                // Clamped in Double: literals may be far outside Int's range.
                let span = b - a
                guard span.isFinite else { return span > 0 ? limit : 0 }
                if span < 0 { return 0 }
                return span < Double(limit) ? Int(span) + 1 : limit
            }
            return limit
        default:
            let path = text(source)
            if let m = catalog.member(path: path), case .fixed(let n)? = m.maxCount { return min(limit, n) }
            if let rid = memberPathRecordList(path), case .fixed(let n)? = rid { return min(limit, n) }
            return 1
        }
    }

    func memberPathRecordList(_ path: String) -> MaxCount?? {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        for record in catalog.records {
            if let f = record.field(named: parts.last!), case .list = f.type { return .some(f.maxCount) }
        }
        return nil
    }

    /// DK2032: a modifier after the `}` of an `if`, `else` or `for`.
    /// DK2032. The fix-its move the modifier into the branches or onto the loop's element, or wrap the construct
    /// in `Column { }`; only among elements (`inViews`), since in an action block or a menu they would make new
    /// errors (a look in an event, a Column in a menu).
    func reportModifiersAfterBlock(_ modifiers: [ModifierAppSyntax], construct: String, statement: PositionedNode, inViews: Bool) {
        for modifier in modifiers {
            guard inViews else {
                report(.modifierAfterIfOrFor, range(modifier.node), ["name": .code(modifier.name.token.text), "construct": .code(construct)])
                continue
            }
            let r = range(modifier.node)
            var fixIts: [FixIt] = []
            let modifierText = text(r)
            let start = textStart(statement)
            let end = r.upperBound
            let body = text(start..<modifier.node.range.lowerBound).trimmingCharacters(in: .whitespacesAndNewlines)
            if construct == "for", let forBlock = statement.firstChild(.block) {
                let inside = BlockSyntax(unchecked: forBlock).statements
                if inside.count == 1, inside[0].kind == .callStmt {
                    let elementEnd = range(inside[0]).upperBound
                    fixIts.append(fix("moveOntoElement", [edit(elementEnd..<elementEnd, modifierText),
                                                          edit(modifier.node.range.lowerBound..<r.upperBound, "")]))
                }
            }
            if construct == "if" {
                var edits: [TextEdit] = []
                var current: PositionedNode? = statement
                while let ifNode = current {
                    if let b = ifNode.firstChild(.block) {
                        for s in BlockSyntax(unchecked: b).statements where s.kind == .callStmt {
                            let e = range(s).upperBound
                            edits.append(edit(e..<e, modifierText))
                        }
                    }
                    current = nil
                    if let elseClause = ifNode.firstChild(.elseClause), let body = elseClause.childNodes.first {
                        if body.kind == .ifStmt { current = body }
                        else if body.kind == .block {
                            for s in BlockSyntax(unchecked: body).statements where s.kind == .callStmt {
                                let e = range(s).upperBound
                                edits.append(edit(e..<e, modifierText))
                            }
                        }
                    }
                }
                if !edits.isEmpty {
                    edits.append(edit(modifier.node.range.lowerBound..<r.upperBound, ""))
                    fixIts.append(fix("moveIntoEachBranch", edits))
                }
            }
            // Wrapped at the construct's own indentation, its lines one level deeper (§3.7 rule 2).
            let indent = indentation(at: start)
            let bodyLines = body.components(separatedBy: lineBreak).enumerated().map { n, line in
                line.isEmpty ? line : (n == 0 ? indent + "    " : "    ") + line
            }
            fixIts.append(fix("wrapIn", [edit(start..<end, "Column {" + lineBreak + bodyLines.joined(separator: lineBreak) + lineBreak
                                                                  + indent + "}" + modifierText)],
                              ["text": .code("Column { }")]))
            report(.modifierAfterIfOrFor, r, ["name": .code(modifier.name.token.text), "construct": .code(construct)],
                   fixIts: fixIts)
        }
    }

    /// An assignment written among elements.
    func checkAssignmentInViews(_ statement: PositionedNode) {
        let assignment = AssignmentSyntax(unchecked: statement)
        let target = assignment.target
        let path = target.path
        if foreignAssignment(statement, assignment) { return }
        if path.count == 1, decls[path[0]] == nil, loopStack.last(where: { $0.name == path[0] }) == nil,
           !target.name.token.isUpperName {
            reportUndeclaredAssignment(assignment)
            return
        }
        if target.name.token.isUpperName && path.count == 1 {
            reportUppercaseName(target.name, declared: false)
            return
        }
        report(.assignmentOutsideEvent, range(statement), ["text": .code(text(statement))])
    }

    func reportUndeclaredAssignment(_ assignment: AssignmentSyntax) {
        let name = assignment.target.name.token.text
        let start = textStart(assignment.node)
        let fixIts = ["variable", "saved", "computed"].map { keyword in
            fix("declareWith", [edit(start..<start, keyword + " ")], ["text": .code(keyword)])
        }
        report(.undeclaredAssignment, range(assignment.target.node), ["name": .code(name)], fixIts: fixIts)
    }

    // MARK: - Elements

    /// A call statement among elements (§2.6, D81).
    func checkViewCall(_ statement: PositionedNode, _ context: ViewContext) {
        let call = CallStmtSyntax(unchecked: statement)
        let callee = call.callee
        let path = callee.path
        let nameToken = callee.name.token
        let calleeRange = range(callee.node)

        if path.count == 1, nameToken.isUpperName, let spec = catalog.component(named: path[0]) {
            if requiresNewer != nil || true { noteSince(spec.doc.since, name: spec.name, at: calleeRange) }
            // `Image(systemName: "wifi")` → `Icon("wifi")` (§6.4), before the arguments are bound.
            if reportForeignCallLabel(call) {
                if let block = call.block { checkGuessedBlock(block.node, context) }
                return
            }
            checkElement(call, spec: spec, context)
            return
        }
        // Not a component: find out what it is, then check its children with a guessed block kind.
        reportNonComponentCall(call, context)
        if let block = call.block {
            // `ForEach(items) { item in … }`: the block reads `item` as a `for` body would.
            let loop = forEachLoopVariable(call)
            pushLoop(loop, loop?.val ?? .error)
            checkGuessedBlock(block.node, context)
            popLoop(loop)
        }
    }

    /// The block of something that is not a known component: checked with a kind guessed from its statements
    /// (modifiers → a chain, calls of capitalised names → views, otherwise actions); mismatches are not reported.
    func checkGuessedBlock(_ block: PositionedNode, _ context: ViewContext) {
        let statements = BlockSyntax(unchecked: block).statements
        let modifiers = statements.filter { $0.kind == .modifierStmt }.count
        let views = statements.filter {
            $0.kind == .callStmt && CallStmtSyntax(unchecked: $0).callee.name.token.isUpperName
        }.count + statements.filter { $0.kind == .ifStmt || $0.kind == .forStmt }.count
        if modifiers > 0 && modifiers >= views {
            // A modifier chain: nothing to check without an element.
            return
        }
        if views == 0 && !statements.isEmpty {
            var action = ActionContext(owner: "onClick", userInitiated: true, eventAvailable: true, eventRecord: "Event",
                                       element: context.parent)
            action.owner = "onClick"
            mute += 1
            checkActionBlock(block, action, loopIDs: context.loopIDs)
            mute -= 1
            return
        }
        var inner = context
        inner.guessing = true
        checkViewStatements(block, inner)
    }

    /// Reports a view call whose callee is not a component (D81 order).
    func reportNonComponentCall(_ call: CallStmtSyntax, _ context: ViewContext) {
        let callee = call.callee
        let path = callee.path
        let nameToken = callee.name.token
        let name = nameToken.name
        let calleeRange = range(callee.node)
        if requiresNewer != nil, path.count == 1, nameToken.isUpperName, !isForeignComponent(name) {
            report(.newerName, calleeRange, ["name": .code(name), "version": .code(requiresNewer!.description)])
            return
        }
        if nameToken.kind == .invalidIdentifier { return }
        if path.count == 1 && nameToken.isUpperName {
            // An options-only control among elements (DK5022).
            if let control = catalog.control(named: name), catalog.component(named: name) == nil, !["Choice"].contains(name) {
                if control.name == "Section" {
                    reportControlInWrongPlace(call, control: control.name)
                } else {
                    reportControlInWrongPlace(call, control: control.name)
                }
                return
            }
            if reportForeignComponent(call) { return }
            if let caseMatch = catalog.components.first(where: { $0.name.lowercased() == name.lowercased() }) {
                report(.wrongCase, calleeRange, ["suggestion": .code(caseMatch.name)],
                       fixIts: [fix("fix", [edit(calleeRange, caseMatch.name)])])
                return
            }
            reportUnknownComponent(name, range: calleeRange)
            return
        }
        if path.count == 1 {
            // A lower-case name among elements: block word, action, modifier without its dot, component in lower
            // case, a value, or unknown.
            if Chars.blockWords.contains(name), call.block != nil {
                let what: String
                switch name {
                case "info": what = "construct:infoBlock"
                case "options": what = "construct:optionsBlock"
                case "translations": what = "construct:translationsBlock"
                case "widget": what = "construct:widgetBlock"
                case "package": what = "construct:packageBlock"
                default: what = "construct:component"
                }
                reportMoveOut(call.node, what: what)
                return
            }
            if let function = catalog.function(named: name), function.kind == .action {
                report(.actionOutsideEvent, range(call.node), ["name": .code(name)])
                return
            }
            if catalog.modifier(named: name) != nil {
                report(.missingModifierDot, calleeRange, ["name": .code(name)],
                       fixIts: [fix("insert", [edit(calleeRange.lowerBound..<calleeRange.lowerBound, ".")], ["text": .code(".")],
                                    group: "missingModifierDot")])
                return
            }
            let capitalised = name.prefix(1).uppercased() + name.dropFirst()
            if catalog.component(named: capitalised) != nil {
                report(.componentLowercase, calleeRange, ["suggestion": .code(capitalised)],
                       fixIts: [fix("fix", [edit(calleeRange, capitalised)])])
                return
            }
            if let function = catalog.function(named: name) {
                reportValueAsStatement(call.node, function: function)
                return
            }
            if decls[name] != nil || catalog.namespace(named: name) != nil || loopStack.contains(where: { $0.name == name }) {
                reportValueAsStatement(call.node, function: nil)
                return
            }
            if let rows = foreignRows(forName: name).first {
                reportForeignName(rows, at: calleeRange, name: name, call: call)
                return
            }
            reportUnknownComponent(name, range: calleeRange)
            return
        }
        // A dotted callee among elements: an action (`music.next()`), or a value.
        let namespacePath = path.dropLast().joined(separator: ".")
        if let member = catalog.member(path: path.joined(separator: ".")) {
            if member.kind == .action {
                report(.actionOutsideEvent, range(call.node), ["name": .code(path.joined(separator: "."))])
            } else {
                reportValueAsStatement(call.node, function: nil)
            }
            return
        }
        if catalog.namespace(named: namespacePath) != nil || decls[path[0]] != nil {
            reportValueAsStatement(call.node, function: nil)
            return
        }
        reportUnknownComponent(path.joined(separator: "."), range: calleeRange)
    }

    func reportValueAsStatement(_ statement: PositionedNode, function: FunctionSpec?) {
        var arguments: [String: DiagnosticArgument] = ["text": .code(text(statement))]
        var fixIts: [FixIt] = []
        if let function, let twin = function.actionTwin {
            let call = CallStmtSyntax(unchecked: statement)
            let r = range(call.callee.node)
            let fixed = twin + text(range(statement)).dropFirst(function.name.count)
            arguments["hint"] = hintText(.valueAsAction, "actionTwin")
            arguments["fixed"] = .code(String(fixed))
            fixIts.append(fix("replaceWith", [edit(r, twin)], ["text": .code(String(fixed))]))
        } else {
            arguments["hint"] = .text(LocalizedText("", ""))
        }
        report(.valueAsAction, range(statement), arguments, fixIts: fixIts)
    }

    func reportUnknownComponent(_ name: String, range r: Range<Int>) {
        var candidates = catalog.components.map(\.name)
        var suggestion = DidYouMean.suggest(name, candidates: candidates, keywords: { word in
            index.keywordMatches(word).compactMap { path -> String? in
                if case .component(let c) = path { return c }
                return nil
            }
        }, rank: { catalog.component(named: $0)?.doc.rank ?? 0 })
        if suggestion.names.isEmpty {
            candidates = []
        }
        var arguments: [String: DiagnosticArgument] = ["name": .code(name)]
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first {
            arguments["suggestion"] = .code(best)
            if suggestion.fixable { fixIts.append(fix("fix", [edit(r, best)])) }
        } else {
            suggestion.names = []
        }
        report(.unknownComponent, r, arguments, fixIts: fixIts, dropped: .element(NodeID(kind: .callStmt, utf8Start: r.lowerBound, treeVersion: tree.version)))
    }

    /// DK5022: an options-only control among elements, or a widget control written the options way.
    /// A removal inside a line that would leave two blanks (`widget {  }`): one of them goes too.
    func tidyRemoval(_ removal: TextEdit) -> TextEdit {
        let r = removal.range
        guard r.lowerBound > 0, text((r.lowerBound - 1)..<r.lowerBound) == " ", text(r.upperBound..<(r.upperBound + 1)) == " " else { return removal }
        return edit((r.lowerBound - 1)..<r.upperBound, removal.replacement)
    }

    func reportControlInWrongPlace(_ call: CallStmtSyntax, control: String) {
        let arguments = call.arguments?.arguments ?? []
        let labelNode = arguments.first { $0.label == nil }?.value.node
        let labelText = labelNode.map { text($0) } ?? "\"…\""
        let labelValue = labelNode.flatMap { StringLiteralSyntax($0)?.literalValue } ?? control
        var name = DidYouMean.lowerCamel(from: labelValue)
        if name.isEmpty || !Checker.isIdentifier(name) || Chars.reservedWords[name] != nil || Chars.blockWords.contains(name) {
            name = control.prefix(1).lowercased() + control.dropFirst()
        }
        // The other values are read, so what they name counts as used (no DK3020 for `n` in `Stepper("N", n)`).
        for argument in arguments where argument.value.node.range != labelNode?.range {
            _ = infer(argument.value.node, ExprContext(), expected: nil)
        }
        // The options form keeps the values the control takes there (a Picker's choices), not a binding.
        let positional = catalog.control(named: control)?.signatures.first?.params.filter { $0.label == nil }.count ?? 1
        var kept: [String] = []
        var seenPositional = 0
        for argument in arguments {
            if argument.label == nil {
                seenPositional += 1
                if seenPositional > positional { continue }
            }
            kept.append(text(argument.node))
        }
        let optionForm = "\(name) = \(control)(\(kept.joined(separator: ", ")))"
        // The widget form exists for the controls that are also elements; it binds a value named like the option.
        let initial: String?
        var widgetForm: String?
        switch control {
        case "Toggle":
            initial = "false"
            widgetForm = "Toggle(\(labelText), \(name))"
        case "Slider":
            initial = "0"
            widgetForm = "Slider(\(labelText), \(name), min: 0, max: 100)"
        case "Input":
            initial = "\"\""
            widgetForm = "Input(\(labelText), \(name))"
        default:
            initial = nil
        }
        var fixIts: [FixIt] = []
        let callRange = range(call.node)
        // Move into `options` (a new block before `widget` when there is none).
        if let options = optionsBlock, let block = options.firstChild(.block), BlockSyntax(unchecked: block).isClosed {
            let piece = SyntaxEditor.Lines(lines: [optionForm], statementLine: 0, kind: nil, from: nil)
            let editor = SyntaxEditor(tree: tree)
            let indent = editor.isSingleLine(block) ? editor.ownerIndent(of: block) + 4 : editor.contentIndent(of: block)
            let indented = SyntaxEditor.Lines(lines: [String(repeating: " ", count: indent) + optionForm], statementLine: 0, kind: nil, from: nil)
            _ = piece
            if let insertion = editor.insertion(of: indented, into: block, index: editor.statements(of: block).count) {
                let removal = tidyRemoval(editor.removal(of: editor.extent(of: call.node)))
                if removal.range.upperBound <= insertion.edit.range.lowerBound || insertion.edit.range.upperBound <= removal.range.lowerBound {
                    fixIts.append(fix("moveInto", [edit(removal.range, removal.replacement), edit(insertion.edit.range, insertion.edit.replacement)],
                                      ["text": .code("options")]))
                }
            }
        } else if optionsBlock == nil, let widget = widgetBlock {
            let at = textStart(widget)
            let removal = tidyRemoval(SyntaxEditor(tree: tree).removal(of: SyntaxEditor(tree: tree).extent(of: call.node)))
            fixIts.append(fix("moveInto", [edit(at..<at, "options {" + lineBreak + "    " + optionForm + lineBreak + "}" + lineBreak + lineBreak),
                                            edit(removal.range, removal.replacement)], ["text": .code("options")]))
        }
        // Add a binding: a variable at the top of `widget`, changed by the control.
        if let initial, let widgetForm, decls[name] == nil, let widget = widgetBlock?.firstChild(.block) {
            let body = BlockSyntax(unchecked: widget)
            let open = body.lBrace.textRange.upperBound
            let firstStatement = body.statements.first.map { textStart($0) } ?? open
            let sameLine = !text(open..<firstStatement).contains("\n") && !text(open..<firstStatement).contains("\r")
            let indent = sameLine ? "    " : indentation(at: firstStatement)
            let declaration = lineBreak + indent + "variable \(name) = \(initial)" + (sameLine ? lineBreak + indent : "")
            let calleeEnd = call.arguments.map { range($0.node).upperBound } ?? range(call.callee.node).upperBound
            fixIts.append(fix("addBinding", [edit(open..<(sameLine ? firstStatement : open), declaration),
                                              edit(callRange.lowerBound..<calleeEnd, widgetForm)]))
        }
        var messageArguments: [String: DiagnosticArgument] = ["optionForm": .code(optionForm), "widget": .text(LocalizedText("", ""))]
        if let widgetForm {
            messageArguments["widgetForm"] = .code(widgetForm)
            messageArguments["widget"] = hintText(.controlInWrongPlace, "widgetForm")
        }
        report(.controlInWrongPlace, callRange, messageArguments, fixIts: fixIts)
    }

    // MARK: - Menus

    /// A statement inside `.menu { }` or `Menu { }`: `Item`, `Menu`, `Divider`, `if`, `for`.
    func checkMenuCall(_ statement: PositionedNode, _ context: ViewContext) {
        let call = CallStmtSyntax(unchecked: statement)
        let path = call.callee.path
        if path.count == 1, let spec = catalog.component(named: path[0]) {
            // `Button(t) { a }` in a menu is an item written the SwiftUI way: DK9109, `Item(t).onClick { a }` (§2.4).
            if spec.kind == .button, let block = call.block {
                reportUnexpectedComponentBlock(call, spec: spec, block: block, context)
                return
            }
            if !(spec.kind == .item || spec.kind == .menu || spec.kind == .divider) {
                report(.childNotAllowed, range(call.callee.node), ["parent": .name("place:menu"),
                                                                   "child": .name("component:\(spec.name)")],
                       dropped: .element(id(statement)))
                return
            }
            checkElement(call, spec: spec, context)
            return
        }
        reportNonComponentCall(call, context)
    }

    // MARK: - Root

    func checkRootElement(_ root: ElementNode) {
        if preset != "fit" {
            for name in ["width", "height", "size"] {
                for modifier in modifierApps(of: root.node) where modifier.name.token.text == name {
                    let r = range(modifier.node)
                    report(.rootSizeIgnored, r, ["preset": .code(preset), "name": .code(name)],
                           fixIts: [fix("remove", [edit(modifier.node.range.lowerBound..<r.upperBound, "")])])
                }
            }
        }
        for name in ["onRightClick", "onDrag"] {
            for modifier in modifierApps(of: root.node) where modifier.name.token.text == name {
                let rightClick = name == "onRightClick"
                report(.rootTakesOverPointer, range(modifier.name),
                       ["what": hintText(.rootTakesOverPointer, rightClick ? "rightClickWhat" : "dragWhat"),
                        "reason": hintText(.rootTakesOverPointer, rightClick ? "rightClickReason" : "dragReason")])
            }
        }
    }

    func modifierApps(of statement: PositionedNode) -> [ModifierAppSyntax] {
        statement.children(.modifierApp).map(ModifierAppSyntax.init(unchecked:))
    }

    /// The catalog hint text of a diagnostic, as a prose argument.
    func hintText(_ id: DiagnosticID, _ key: String) -> DiagnosticArgument {
        if let hint = catalog.diagnostic(id)?.hints.first(where: { $0.key == key }) { return .text(hint.text) }
        return .text(LocalizedText("", ""))
    }
}

/// A `.name(…)` found before checking.
struct PreName {
    let name: String
    let call: PositionedNode
    let container: PositionedNode?
    let insideIf: Bool
    let insideFor: Bool
    let range: Range<Int>
    let quoted: Bool
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
