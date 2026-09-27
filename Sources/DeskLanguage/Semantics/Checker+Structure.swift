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
                reportStrayTopLevel(statement, strays: [])
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
        for statement in movable where statement.kind != .assignment {
            reportStrayTopLevel(statement, strays: movable)
        }
        return (elements, declarations)
    }

    func reportStrayTopLevel(_ statement: PositionedNode, strays: [PositionedNode]) {
        var fixIts: [FixIt] = []
        if !strays.isEmpty {
            if let widget = widgetBlock ?? tree.rootNode.childNodes.first(where: { $0.kind == .widgetBlock }),
               let block = widget.firstChild(.block) {
                // Move into the existing widget: declarations to its top, elements to its end.
                let body = BlockSyntax(unchecked: block)
                var edits: [TextEdit] = []
                var declText = "", viewText = ""
                for s in strays {
                    let r = range(s)
                    edits.append(edit(s.range.lowerBound..<r.upperBound, ""))
                    let piece = "    " + text(r) + lineBreak
                    if s.kind == .declaration { declText += piece } else { viewText += piece }
                }
                let open = body.lBrace.textRange.upperBound
                let close = body.rBrace.textRange.lowerBound
                if !declText.isEmpty { edits.append(edit(open..<open, lineBreak + declText.dropLast(lineBreak.count))) }
                if !viewText.isEmpty { edits.append(edit(close..<close, viewText)) }
                fixIts.append(fix("moveInto", edits, ["text": .code("widget")]))
            } else {
                let first = strays.map { $0.range.lowerBound }.min() ?? 0
                let last = strays.map { range($0).upperBound }.max() ?? 0
                var inner = ""
                for s in strays { inner += "    " + text(range(s)) + lineBreak }
                let replaced = "widget {" + lineBreak + inner + "}"
                let start = strays.map { textStart($0) }.min() ?? first
                fixIts.append(fix("wrapIn", [edit(start..<last, replaced)], ["text": .code("widget { }")]))
            }
        }
        report(.strayTopLevel, range(statement), fixIts: fixIts)
    }

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
        reportModifiersAfterBlock(ifStmt.modifiers, construct: "if", statement: statement)
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
        inner.multiplier = context.multiplier * forBound(forStmt.source.node)
        pushLoop(variable, element)
        checkViewStatements(forStmt.block.node, inner)
        popLoop(variable)
        reportModifiersAfterBlock(forStmt.modifiers, construct: "for", statement: statement)
    }

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
                return min(limit, max(0, Int(b - a) + 1))
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
    func reportModifiersAfterBlock(_ modifiers: [ModifierAppSyntax], construct: String, statement: PositionedNode) {
        for modifier in modifiers {
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
            fixIts.append(fix("wrapIn", [edit(start..<end, "Column {" + lineBreak + "    " + body + lineBreak + "}" + modifierText)],
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
            checkElement(call, spec: spec, context)
            return
        }
        // Not a component: find out what it is, then check its children with a guessed block kind.
        reportNonComponentCall(call, context)
        if let block = call.block { checkGuessedBlock(block.node, context) }
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
    func reportControlInWrongPlace(_ call: CallStmtSyntax, control: String) {
        let label = call.arguments?.arguments.first.map { text($0.value.node) } ?? "\"…\""
        let optionName = DidYouMean.lowerCamel(from: StringLiteralSyntax(call.arguments?.arguments.first?.value.node ?? call.node)?.literalValue ?? control)
        let widgetForm: String
        switch control {
        case "Toggle": widgetForm = "Toggle(\(label), isOn)"
        case "Slider": widgetForm = "Slider(\(label), value)"
        case "Input": widgetForm = "Input(\(label), text)"
        default: widgetForm = "Toggle(\(label), isOn)"
        }
        let optionForm = "\(optionName) = \(text(call.node))"
        var fixIts: [FixIt] = []
        if let options = optionsBlock, let block = options.firstChild(.block) {
            let close = BlockSyntax(unchecked: block).rBrace.textRange.lowerBound
            fixIts.append(fix("moveInto", [edit(call.node.range.lowerBound..<range(call.node).upperBound, ""),
                                            edit(close..<close, "    " + optionForm + lineBreak)], ["text": .code("options")]))
        }
        report(.controlInWrongPlace, range(call.node), ["widgetForm": .code(widgetForm), "optionForm": .code(optionForm)],
               fixIts: fixIts)
    }

    // MARK: - Menus

    /// A statement inside `.menu { }` or `Menu { }`: `Item`, `Menu`, `Divider`, `if`, `for`.
    func checkMenuCall(_ statement: PositionedNode, _ context: ViewContext) {
        let call = CallStmtSyntax(unchecked: statement)
        let path = call.callee.path
        if path.count == 1, let spec = catalog.component(named: path[0]) {
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
