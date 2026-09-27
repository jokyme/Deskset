import Foundation

// Elements and modifiers, phase C3 (§4.7, §4.8, §4.10, §4.12): which components hold which children, applicability,
// conditions, duplicates within one source, facets and their candidates in precedence order, inheritance, styles
// (expansion, restrictions, cycles), and the modifiers with special rules (`.position`, `.name`, `.style`,
// `.rainmeter`, events and timing).

/// A modifier as applied: the facets it sets, with their values and whether each is hard or soft.
struct AppliedModifier {
    var name: String
    var node: PositionedNode
    var spec: ModifierSpec
    /// (facet, value node, fixed value text, hard)
    var facets: [(FacetID, NodeID, String?, Bool)]
    /// The `if:` condition, if any.
    var condition: NodeID?
    /// `.hover` / `.pressed` state it was written in.
    var state: CandidateCondition?
    /// The value of its first positional argument (for `.onScroll(.up)` duplicates).
    var firstArgument: String?
    var file: DeskFileID
}

extension Checker {
    // MARK: - Elements

    /// A component call among elements: its parent, arguments, block and modifiers.
    func checkElement(_ call: CallStmtSyntax, spec: ComponentSpec, _ context: ViewContext) {
        let node = call.node
        let element = ElementNode(id: id(node), node: node, component: spec, parent: context.parent,
                                  insideIf: context.insideIf, insideFor: context.forDepth > 0)
        context.parent?.children.append(element)
        allElements.append(element)
        estimatedElements = Checker.saturatingSum(estimatedElements, max(1, context.multiplier))
        if spec.kind == .freeform { freeforms.append(element) }
        let calleeRange = range(call.callee.node)

        // Where it may be.
        if let allowed = spec.allowedParents {
            if allowed == .stacks {
                let parentKind = context.parent?.kind
                if !(parentKind == .row || parentKind == .column || parentKind == .grid) && !(context.parent == nil && context.isWidgetBody) {
                    report(.spacerOutsideStack, range(node), fixIts: [fix("remove", [edit(node.range.lowerBound..<range(node).upperBound, "")])])
                }
            } else if context.place != .menu {
                let parentName: DiagnosticArgument = context.parent?.component.map { .name("component:\($0.name)") } ?? .name("place:widget")
                report(.childNotAllowed, calleeRange, ["parent": parentName, "child": .name("component:\(spec.name)")],
                       dropped: .element(element.id))
                element.facts.dropped.append(.element(element.id))
            }
        }

        // Controls written the options way: `Toggle("Show seconds")` with no binding.
        if spec.group == .controls, spec.kind != .button, let arguments = call.arguments?.arguments,
           isOptionsFormControl(spec, arguments) {
            reportControlInWrongPlace(call, control: spec.name)
            element.facts.dropped.append(.element(element.id))
            finishElement(element)
            return
        }

        // Arguments.
        var exprContext = ExprContext()
        exprContext.place = .views
        exprContext.element = element
        exprContext.loopScope = context.loopIDs
        exprContext.usage = .display
        let bound = bindCall(spec.signatures, arguments: call.arguments, calleeName: spec.name,
                             what: .name("component:\(spec.name)"), callRange: calleeRange, exprContext,
                             owner: .component(spec))
        if call.arguments == nil && call.block == nil && !spec.signatures.contains(where: { $0.params.contains { $0.required } }) {
            // `Spacer` without parentheses (DK2009) is reported by the parser.
        }
        if let bound, !bound.failed { checkComponentValues(spec, bound, call: call, element: element) }
        if let bound {
            for value in bound.values where mute == 0 {
                dependencies[id(value.node)] = value.val.deps
            }
        }

        // The block.
        if let block = call.block {
            switch spec.block {
            case .views:
                var inner = context
                inner.parent = element
                inner.parentComponent = spec.name
                inner.place = .views
                inner.insideIf = false
                inner.forDepth = context.forDepth
                inner.isWidgetBody = false
                checkViewStatements(block.node, inner)
            case .menuItems:
                var inner = context
                inner.parent = element
                inner.parentComponent = "menu"
                inner.place = .menu
                checkViewStatements(block.node, inner)
            default:
                reportUnexpectedComponentBlock(call, spec: spec, block: block, context)
            }
        } else if case .menuItems(required: true) = spec.block {
            report(.blockNeeded, calleeRange, ["name": .code(spec.name), "what": .name("content:menuItems")],
                   fixIts: [fix("insert", [edit(range(node).upperBound..<range(node).upperBound, " { }")], ["text": .code(" { }")])])
        }

        // Modifiers.
        checkElementModifiers(call.modifiers, element: element, context)
        finishElement(element)
    }

    func finishElement(_ element: ElementNode) {
        if mute == 0 { elementFacts[element.id] = element.facts }
    }

    /// `Toggle("Show seconds")`, `Toggle("Show seconds", default: true)`: the options form of a control.
    func isOptionsFormControl(_ spec: ComponentSpec, _ arguments: [ArgumentSyntax]) -> Bool {
        guard catalog.control(named: spec.name) != nil else { return false }
        if arguments.contains(where: { $0.label?.name == "default" }) { return true }
        let labels = arguments.compactMap { $0.label?.name }
        if labels.contains(where: { !["min", "max", "step"].contains($0) }) { return false }
        let positional = arguments.filter { $0.label == nil }
        switch spec.kind {
        case .toggle: return positional.count == 1 && positional[0].value.node.kind == .stringLiteral
        case .slider: return positional.count == 1 && positional[0].value.node.kind == .stringLiteral
                        && arguments.contains { $0.label?.name == "min" }
        case .input: return positional.count == 1 && positional[0].value.node.kind == .stringLiteral
                        && StringLiteralSyntax(unchecked: positional[0].value.node).literalValue != nil
                        && !arguments.contains { $0.label?.name == "placeholder" }
                        && false
        default: return false
        }
    }

    /// A block after a component that takes none: `Button` and `Item` get DK9109, others DK2010.
    func reportUnexpectedComponentBlock(_ call: CallStmtSyntax, spec: ComponentSpec, block: BlockSyntax, _ context: ViewContext) {
        let blockRange = range(block.node)
        if spec.kind == .button || spec.kind == .item {
            let body = text(blockRange)
            var edits: [TextEdit] = []
            var fixed: String
            if spec.kind == .button, context.place == .menu {
                let title = call.arguments.map { text($0.node) } ?? "(\"\")"
                fixed = "Item\(title).onClick \(body)"
                edits = [edit(textStart(call.node)..<blockRange.upperBound, fixed)]
            } else {
                let start = call.arguments.map { range($0.node).upperBound } ?? range(call.callee.node).upperBound
                edits = [edit(start..<blockRange.upperBound, ".onClick " + body)]
                fixed = "\(text(textStart(call.node)..<start)).onClick \(body)"
            }
            report(.trailingActionBlock, blockRange, ["fixed": .code(fixed)],
                   fixIts: [fix("moveInto", edits, ["text": .code(".onClick")])])
            let action = ActionContext(owner: "onClick", userInitiated: true, eventAvailable: true, eventRecord: "Event", element: nil)
            checkActionBlock(block.node, action, loopIDs: context.loopIDs)
            trailingActionBlocks.insert(call.node.range.lowerBound)
            return
        }
        let statements = block.statements
        var fixIts: [FixIt] = []
        if statements.isEmpty {
            let start = call.arguments.map { range($0.node).upperBound } ?? range(call.callee.node).upperBound
            fixIts.append(fix("removeBlock", [edit(start..<blockRange.upperBound, "")]))
        }
        report(.unexpectedBlock, blockRange, ["name": .code(spec.name)], fixIts: fixIts)
    }

    /// Component-specific checks of the bound values.
    func checkComponentValues(_ spec: ComponentSpec, _ bound: BoundCall, call: CallStmtSyntax, element: ElementNode) {
        switch spec.kind {
        case .progress, .gauge:
            guard let value = bound.value("value"), bound.value("total") == nil, !value.val.error, value.val.open == nil else { return }
            let v = value.val
            let known: Bool
            if v.isJson { known = false }
            else if v.dimension == .percent { known = true }
            else if v.dimension == .plain { known = v.range != nil || v.plainLiteral != nil || v.dataPath == nil }
            else if let range = v.range, range != .none { known = true }
            else { known = false }
            if !known {
                let r = range(value.node)
                report(.unknownRange, r, ["component": .name("component:\(spec.name)")],
                       fixIts: [fix("insert", [edit(r.upperBound..<r.upperBound, ", total: 100")], ["text": .code(", total: 100")])])
            }
        default:
            break
        }
    }

    // MARK: - Modifiers of an element

    func checkElementModifiers(_ modifiers: [ModifierAppSyntax], element: ElementNode, _ context: ViewContext) {
        var applied: [AppliedModifier] = []
        var stateSources: [[AppliedModifier]] = []
        var styleCalls: [(style: String, condition: NodeID?, node: PositionedNode)] = []
        for modifier in modifiers {
            let result = checkModifier(modifier, element: element, state: nil, styleName: nil, context)
            element.modifierNames.append(modifier.name.token.text)
            if let a = result.applied { applied.append(a) }
            stateSources += result.stateSources
            styleCalls += result.styleCalls
        }
        checkDuplicates(applied, element: element)
        for source in stateSources { checkDuplicates(source, element: element) }
        buildFacets(element: element, own: applied, states: stateSources, styleCalls: styleCalls)
        checkElementCombinations(element, modifiers: modifiers, applied: applied + stateSources.flatMap { $0 })
    }

    struct ModifierResult {
        var applied: AppliedModifier?
        var stateSources: [[AppliedModifier]] = []
        var styleCalls: [(style: String, condition: NodeID?, node: PositionedNode)] = []
    }

    /// One modifier on an element (or in a style when `element` is nil).
    func checkModifier(_ modifier: ModifierAppSyntax, element: ElementNode?, state: CandidateCondition?,
                       styleName: String?, _ context: ViewContext) -> ModifierResult {
        var result = ModifierResult()
        let nameToken = modifier.name
        let name = nameToken.token.name
        let nameRange = range(nameToken)
        let modifierRange = range(modifier.node)
        let nodeID = id(modifier.node)
        guard !nameToken.token.isMissing else { return result }
        guard let spec = catalog.modifier(named: name), spec.context != .option || element == nil && styleName == nil && context.place == .options else {
            reportUnknownModifier(modifier, element: element, context)
            quietlyCheckArguments(modifier, element: element, context)
            element?.facts.dropped.append(.modifier(nodeID))
            return result
        }
        symbols[nodeID] = .builtIn(.modifier(name))
        noteSince(spec.doc.since, name: "." + name, at: nameRange)
        noteDeprecated(spec.doc, name: "." + name, at: nameRange)

        var exprContext = ExprContext()
        exprContext.place = styleName != nil ? .style : .views
        exprContext.element = element
        exprContext.styleName = styleName
        exprContext.loopScope = context.loopIDs
        exprContext.usage = spec.timing != nil ? .logic : .display
        exprContext.modifier = name
        var dropped = false

        // Where it may be written.
        if styleName != nil && !spec.allowedInStyle {
            report(.notAllowedInStyle, nameRange, ["name": .code(name)], dropped: .modifier(nodeID))
            dropped = true
        }
        if let state, !spec.allowedInState {
            let stateName = state == .pressed ? "pressed" : "hover"
            var fixIts: [FixIt] = []
            var hint: DiagnosticArgument = .text(LocalizedText("", ""))
            if name == "hidden" {
                hint = hintText(.notAllowedInState, "forHidden")
            }
            if name == "hover" || name == "pressed" { hint = hintText(.notAllowedInState, "nestedState") }
            _ = fixIts
            fixIts = []
            report(.notAllowedInState, nameRange, ["name": .code(name), "state": .code(stateName), "hint": hint],
                   fixIts: fixIts, dropped: .modifier(nodeID))
            dropped = true
        }
        if let element, let kind = element.kind, !spec.appliesTo.contains(kind), !dropped {
            reportNotApplicable(modifier, spec: spec, element: element)
            element.facts.dropped.append(.modifier(nodeID))
            dropped = true
        }
        // `if:` where it cannot be.
        let arguments = modifier.arguments?.arguments ?? []
        if !spec.acceptsCondition, !spec.signatures.contains(where: { $0.param(labelled: "if") != nil }),
           let conditionArgument = arguments.first(where: { $0.label?.name == "if" }) {
            // The condition goes inside the block: `.onClick { if c { … } }` (DK5004).
            var edits = [edit(argumentRemovalRange(conditionArgument, in: arguments), "")]
            if let block = modifier.block, let clause = modifier.arguments {
                let condition = text(conditionArgument.value.node)
                let body = BlockSyntax(unchecked: block.node)
                let open = body.lBrace.textRange.upperBound, close = body.rBrace.textRange.lowerBound
                let inner = text(open..<close)
                let wrapped: String
                if inner.contains("\n") || inner.contains("\r") {
                    let indent = indentation(at: body.rBrace.textStart)
                    var lines = inner.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                        .components(separatedBy: "\n")
                    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
                    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
                    wrapped = "{" + lineBreak + indent + "    if \(condition) {" + lineBreak
                        + lines.map { $0.isEmpty ? $0 : "    " + $0 }.joined(separator: lineBreak)
                        + lineBreak + indent + "    }" + lineBreak + indent + "}"
                } else {
                    let trimmed = inner.trimmingCharacters(in: .whitespaces)
                    wrapped = trimmed.isEmpty ? "{ if \(condition) { } }" : "{ if \(condition) { \(trimmed) } }"
                }
                let clauseRange = range(clause.node)
                let keepsArguments = arguments.count > 1
                if keepsArguments {
                    edits.append(edit(range(body.node), wrapped))
                } else {
                    edits = [edit(clauseRange.lowerBound..<range(body.node).upperBound, " " + wrapped)]
                }
            }
            report(.conditionNotAllowed, range(conditionArgument.node), ["name": .code(name)],
                   fixIts: [fix("rewrite", edits)], dropped: .modifier(nodeID))
            dropped = true
        }
        // Actions or looks written in parentheses (DK2037).
        if spec.block != .none, case .modifiers = spec.block {
            if !arguments.isEmpty { reportBlockInParentheses(modifier, spec: spec); dropped = true }
        } else if case .actions = spec.block, let first = arguments.first, isActionLike(first) {
            reportBlockInParentheses(modifier, spec: spec)
            dropped = true
        }
        if dropped {
            quietlyCheckArguments(modifier, element: element, context)
            if let block = modifier.block, case .actions = spec.block {
                mute += 1
                checkActionBlock(block.node, ActionContext(owner: name, userInitiated: true, eventAvailable: true,
                                                           eventRecord: "Event", element: element), loopIDs: context.loopIDs)
                mute -= 1
            }
            return result
        }

        // Special modifiers.
        switch name {
        case "name":
            checkNameModifier(modifier, element: element, context)
        case "style":
            if let call = checkStyleModifier(modifier, element: element, state: state, styleName: styleName, context) {
                result.styleCalls.append(call)
            }
            return result
        case "rainmeter":
            checkRainmeterModifier(modifier, element: element)
            return result
        case "position":
            if let element {
                element.hasPosition = true
                element.positionRange = modifierRange
                if element.parent?.kind != .freeform {
                    reportPositionOutsideFreeform(modifier, element: element)
                    return result
                }
            }
        default:
            break
        }

        // Arguments.
        var bound: BoundCall?
        if case .actions = spec.block, spec.signatures.first?.params.isEmpty == true, arguments.isEmpty {
            bound = BoundCall(signature: spec.signatures[0], index: 0, values: [], failed: false)
        } else {
            bound = bindCall(signaturesWithCondition(spec), arguments: modifier.arguments, calleeName: "." + name,
                             what: .code("." + name), callRange: modifierRange, exprContext, owner: .modifier(spec))
        }
        if let bound {
            for value in bound.values where mute == 0 { dependencies[id(value.node)] = value.val.deps }
            checkModifierValues(spec, bound, modifier: modifier, element: element, context)
            checkTernaryOnModifier(spec, bound, modifier: modifier)
            checkWidgetSizeInLayout(spec, bound)
        }

        // The block.
        let blockNeeded: Bool
        switch spec.block {
        case .actions(let required), .modifiers(let required), .menuItems(let required), .views(let required):
            blockNeeded = required
        default: blockNeeded = false
        }
        if let block = modifier.block {
            switch spec.block {
            case .actions:
                let event = spec.event
                var action = ActionContext(owner: name, userInitiated: event?.userInitiated ?? false,
                                           eventAvailable: event?.eventRecord != nil, eventRecord: event?.eventRecord,
                                           element: element)
                if styleName != nil { action.element = nil }
                checkActionBlock(block.node, action, loopIDs: context.loopIDs)
                recordReaction(spec, modifier: modifier, bound: bound, element: element)
            case .modifiers:
                let stateCondition: CandidateCondition = name == "pressed" ? .pressed : .hover
                var source: [AppliedModifier] = []
                for statement in block.statements {
                    guard statement.kind == .modifierStmt else {
                        reportNotAModifier(statement, place: "place:state")
                        continue
                    }
                    for inner in ModifierStmtSyntax(unchecked: statement).modifiers {
                        let r = checkModifier(inner, element: element, state: stateCondition, styleName: styleName, context)
                        if var a = r.applied { a.state = stateCondition; source.append(a) }
                        result.styleCalls += r.styleCalls.map { ($0.style, $0.condition, $0.node) }
                        if !r.styleCalls.isEmpty, styleName == nil {
                            for call in r.styleCalls { stateStyleCalls.append((call.style, stateCondition, call.node, element)) }
                        }
                    }
                }
                result.stateSources.append(source)
            case .menuItems:
                var inner = context
                inner.place = .menu
                inner.parent = element
                inner.parentComponent = "menu"
                checkViewStatements(block.node, inner)
            default:
                let fixIts = block.statements.isEmpty
                    ? [fix("removeBlock", [edit((modifier.arguments.map { range($0.node) } ?? range(modifier.name)).upperBound..<range(block.node).upperBound, "")])]
                    : []
                report(.unexpectedBlock, range(block.node), ["name": .code("." + name)], fixIts: fixIts)
            }
        } else if blockNeeded {
            let what: String
            switch spec.block {
            case .actions: what = "content:actions"
            case .modifiers: what = "content:modifiers"
            default: what = "content:menuItems"
            }
            let end = modifierRange.upperBound
            for d in tree.diagnostics where d.id == .missingParens && modifierRange.contains(d.range.lowerBound) {
                droppedParserDiagnostics.insert(diagnosticKey(d))
            }
            report(.blockNeeded, modifierRange, ["name": .code("." + name), "what": .name(what)],
                   fixIts: [fix("insert", [edit(end..<end, " { }")], ["text": .code(" { }")])])
        }
        guard let bound, !bound.failed else {
            element?.facts.dropped.append(.modifier(nodeID))
            return result
        }
        result.applied = appliedModifier(spec, modifier: modifier, bound: bound, state: state)
        return result
    }

    /// A modifier's signatures with `if:` added when it accepts a condition and does not list one itself.
    func signaturesWithCondition(_ spec: ModifierSpec) -> [Signature] {
        guard spec.acceptsCondition else { return spec.signatures }
        return spec.signatures.map { signature in
            guard signature.param(labelled: "if") == nil else { return signature }
            var s = signature
            s.params.append(CatalogData.condition())
            return s
        }
    }

    /// The facets a modifier sets, with their values (§4.8.3).
    func appliedModifier(_ spec: ModifierSpec, modifier: ModifierAppSyntax, bound: BoundCall, state: CandidateCondition?) -> AppliedModifier {
        var facets: [(FacetID, NodeID, String?, Bool)] = []
        var condition: NodeID?
        let nodeID = id(modifier.node)
        for value in bound.values {
            if value.param.role == .condition && spec.name != "hidden" {
                condition = id(value.node)
                continue
            }
            if spec.name == "hidden" && value.param.role == .condition {
                condition = id(value.node)
                facets.append(("hidden", id(value.node), "true", true))
                continue
            }
            // A preset sets its facets softly: `.font(.headline)`.
            if spec.softFacets, let caseName = value.val.implicitName, case .enumeration(let enumID) = value.val.type,
               let c = catalog.enumeration(enumID)?.enumCase(named: caseName), !c.facetValues.isEmpty {
                for (facet, fv) in c.facetValues.sorted(by: { $0.key < $1.key }) {
                    facets.append((facet, id(value.node), fv.value, !fv.soft))
                }
                continue
            }
            for facet in value.param.facets { facets.append((facet, id(value.node), nil, true)) }
        }
        for (facet, fixedValue) in spec.fixedValues.sorted(by: { $0.key < $1.key }) {
            facets.append((facet, nodeID, fixedValue, true))
        }
        if spec.name == "hidden", bound.values.isEmpty { facets.append(("hidden", nodeID, "true", true)) }
        let first = bound.values.first { $0.param.label == nil }.map { text($0.node) }
        return AppliedModifier(name: spec.name, node: modifier.node, spec: spec, facets: facets, condition: condition,
                               state: state, firstArgument: first, file: file)
    }

    /// Checks a modifier's arguments without reporting (the modifier itself was reported), so names still resolve.
    func quietlyCheckArguments(_ modifier: ModifierAppSyntax, element: ElementNode?, _ context: ViewContext) {
        var exprContext = ExprContext()
        exprContext.element = element
        exprContext.loopScope = context.loopIDs
        mute += 1
        for argument in modifier.arguments?.arguments ?? [] { _ = infer(argument.value.node, exprContext, expected: nil) }
        mute -= 1
    }

    /// `.onClick(page = page + 1)`, `.onClick(open("Safari"))`, `.hover(.color(.accent))` (DK2037).
    func isActionLike(_ argument: ArgumentSyntax) -> Bool {
        if argument.colon?.kind == .equal { return true }
        let value = argument.value.node
        if value.kind == .callExpr {
            let callee = CallExprSyntax(unchecked: value).callee.node
            if callee.kind == .identifierExpr, let f = catalog.function(named: IdentifierExprSyntax(unchecked: callee).name),
               f.kind == .action { return true }
            if callee.kind == .memberExpr, let m = catalog.member(path: text(callee)), m.kind == .action { return true }
        }
        return false
    }

    func reportBlockInParentheses(_ modifier: ModifierAppSyntax, spec: ModifierSpec) {
        guard let clause = modifier.arguments else { return }
        let inside = clause.arguments.map { text($0.node) }.joined(separator: "; ")
        let fixed = ".\(spec.name) { \(inside) }"
        let what: String
        if case .modifiers = spec.block { what = "content:modifiers" } else { what = "content:actions" }
        report(.blockInParentheses, range(clause.node), ["name": .code(spec.name), "what": .name(what), "fixed": .code(fixed)],
               fixIts: [fix("useBraces", [edit(range(clause.node), " { \(inside) }")])])
    }

    func reportNotAModifier(_ statement: PositionedNode, place: String) {
        switch statement.kind {
        case .callStmt:
            let call = CallStmtSyntax(unchecked: statement)
            let name = call.callee.name.token.name
            if call.callee.path.count == 1, catalog.modifier(named: name) != nil {
                let r = range(call.callee.node)
                report(.missingModifierDot, r, ["name": .code(name)],
                       fixIts: [fix("insert", [edit(r.lowerBound..<r.lowerBound, ".")], ["text": .code(".")], group: "missingModifierDot")])
                return
            }
            report(.notAllowedHere, range(statement), ["what": .name("construct:element"), "place": .name(place),
                                                       "hint": .text(LocalizedText("", ""))])
        case .foreignConstruct, .unexpected:
            break
        default:
            report(.notAllowedHere, range(statement), ["what": .name(constructName(statement)), "place": .name(place),
                                                       "hint": .text(LocalizedText("", ""))])
        }
    }

    func constructName(_ statement: PositionedNode) -> String {
        switch statement.kind {
        case .declaration: return "construct:declaration"
        case .assignment: return "construct:action"
        case .field: return "construct:field"
        case .entry, .group: return "construct:translation"
        case .styleDecl: return "construct:style"
        case .optionDecl: return "construct:option"
        default: return "construct:element"
        }
    }

    /// DK5003 with the right modifier when there is one.
    func reportNotApplicable(_ modifier: ModifierAppSyntax, spec: ModifierSpec, element: ElementNode) {
        guard let kind = element.kind else { return }
        let name = spec.name
        let nameRange = range(modifier.name)
        var hint = LocalizedText("", "")
        var fixIts: [FixIt] = []
        if name == "tint", kind == .icon || kind == .label {
            hint = LocalizedText("Symbols are colored with `.color`.", "符号用 `.color` 上色。")
            fixIts.append(fix("replace", [edit(nameRange, "color")]))
        } else if name == "color", ElementKindSet.shapes.contains(kind) {
            hint = LocalizedText("Shapes are painted with `.fill` inside and `.stroke` along the outline.",
                                 "形状用 `.fill` 填充内部、用 `.stroke` 画轮廓。")
            fixIts.append(fix("replace", [edit(nameRange, "fill")]))
        } else if name == "fill", kind == .image {
            hint = LocalizedText("A picture fills its box the way `.imageMode` says.", "图片怎么填满框由 `.imageMode` 决定。")
            if let clause = modifier.arguments {
                fixIts.append(fix("replace", [edit(nameRange.lowerBound..<range(clause.node).upperBound, "imageMode(.fill)")]))
            }
        }
        report(.notApplicable, nameRange, ["name": .code(name), "component": .name("component:\(element.component?.name ?? "")"),
                                           "hint": .text(hint)], fixIts: fixIts, dropped: .modifier(id(modifier.node)))
    }

    /// DK3001 and the foreign spellings of modifiers (§6.2).
    func reportUnknownModifier(_ modifier: ModifierAppSyntax, element: ElementNode?, _ context: ViewContext) {
        let name = modifier.name.token.name
        let nameRange = range(modifier.name)
        if modifier.name.token.kind == .invalidIdentifier { return }
        if let requires = requiresNewer {
            report(.newerName, nameRange, ["name": .code("." + name), "version": .code(requires.description)])
            return
        }
        if reportForeignModifier(modifier, element: element) { return }
        // `.help` on an element (the Options panel's modifier) is SwiftUI's tooltip.
        if let spec = catalog.modifier(named: name), spec.context == .option {
            if let row = index.foreignRows("." + name).first(where: { $0.context == .onElement }) {
                reportForeignModifierRow(row, modifier: modifier)
                return
            }
        }
        if let caseMatch = catalog.modifiers.first(where: { $0.name.lowercased() == name.lowercased() }) {
            report(.wrongCase, nameRange, ["suggestion": .code("." + caseMatch.name)],
                   fixIts: [fix("fix", [edit(nameRange, caseMatch.name)])])
            return
        }
        var candidates = catalog.modifiers.filter { $0.context != .option }
        if let kind = element?.kind { candidates = candidates.filter { $0.appliesTo.contains(kind) } + candidates.filter { !$0.appliesTo.contains(kind) } }
        let names = candidates.map(\.name)
        let suggestion = DidYouMean.suggest(name, candidates: names, keywords: { word in
            index.keywordMatches(word).compactMap { path -> String? in
                if case .modifier(let m) = path { return m }
                return nil
            }
        }, rank: { catalog.modifier(named: $0)?.doc.rank ?? 0 })
        var arguments: [String: DiagnosticArgument] = ["name": .code(name)]
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first {
            arguments["suggestion"] = .code(best)
            if suggestion.fixable { fixIts.append(fix("fix", [edit(nameRange, best)])) }
        }
        report(.unknownModifier, nameRange, arguments, fixIts: fixIts, dropped: .modifier(id(modifier.node)))
    }

    // MARK: - Special modifiers

    /// `.name(title)` (§4.10).
    func checkNameModifier(_ modifier: ModifierAppSyntax, element: ElementNode?, _ context: ViewContext) {
        guard let argument = modifier.arguments?.arguments.first else { return }
        let value = argument.value.node
        let r = range(value)
        var name: String?
        var quoted = false
        if value.kind == .identifierExpr {
            let token = IdentifierExprSyntax(unchecked: value).token
            name = token.token.name
            guard checkOwnName(token, kind: "element") else { return }
        } else if value.kind == .stringLiteral, let s = StringLiteralSyntax(unchecked: value).literalValue {
            name = s
            quoted = true
            if Checker.isIdentifier(s) {
                report(.quotedOwnName, r, ["fixed": .code(".name(\(s))")],
                       fixIts: [fix("removeQuotes", [edit(r, s)], group: "quotedOwnName")])
            } else if element?.parent?.kind == .freeform {
                let renamed = DidYouMean.lowerCamel(from: s)
                report(.nameNotReferable, r, ["name": .code(s)], fixIts: [fix("rename", [edit(r, renamed)])])
            }
        } else if value.kind == .implicitMemberExpr {
            let n = ImplicitMemberExprSyntax(unchecked: value).name.token.name
            report(.dotOnOwnStyle, r, ["name": .code(n)], fixIts: [fix("removeDot", [edit(r, n)])])
            return
        }
        guard let n = name, let element else { return }
        if context.forDepth > 0 {
            report(.nameInFor, range(modifier.node), fixIts: [fix("remove", [edit(modifier.node.range.lowerBound..<range(modifier.node).upperBound, "")])])
            return
        }
        if let other = elementNames[n] {
            report(.duplicateElementName, r, ["name": .code(n)], notes: [note("otherCopy", other.range)],
                   fixIts: [fix("renameThisOne", [edit(r, n + "2")])])
            return
        }
        if let decl = decls[n] {
            reportNameClash(IdentifierExprSyntax(value)?.token ?? PositionedToken(token: Token(kind: .identifier, text: n), offset: r.lowerBound),
                            other: LocalizedText("a declaration", "一个声明"), otherRange: decl.nameRange)
            return
        }
        element.name = n
        element.facts.name = n
        element.named = id(modifier.node)
        elementNames[n] = ElementNameInfo(name: n, element: element, range: r, id: element.id, quoted: quoted)
    }

    /// `.style(name, if: c)` (§4.12). Returns the style to expand.
    func checkStyleModifier(_ modifier: ModifierAppSyntax, element: ElementNode?, state: CandidateCondition?,
                            styleName: String?, _ context: ViewContext) -> (style: String, condition: NodeID?, node: PositionedNode)? {
        let arguments = modifier.arguments?.arguments ?? []
        let r = range(modifier.node)
        let positional = arguments.filter { $0.label == nil }
        // `.style(a | b)`, `.style(a, b)`: one style per call.
        if positional.count > 1 || positional.first.map({ $0.value.node.kind == .binaryExpr && [.pipe, .amp].contains(BinaryExprSyntax(unchecked: $0.value.node).operator.kind) }) == true {
            var names: [String] = []
            for p in positional { names += styleNames(in: p.value.node) }
            if mute == 0 { for n in names { styles[n]?.used = true } }
            let fixed = names.map { ".style(\($0))" }.joined()
            report(.combinedStyles, r, ["fixed": .code(fixed)], fixIts: [fix("rewrite", [edit(r, fixed)])])
            return nil
        }
        guard let first = positional.first else {
            report(.missingArgument, r, ["name": .code(".style"), "what": .type(.styleRef)])
            return nil
        }
        var conditionNode: NodeID?
        var exprContext = ExprContext()
        exprContext.element = element
        exprContext.styleName = styleName
        exprContext.loopScope = context.loopIDs
        exprContext.usage = .display
        for argument in arguments where argument.label != nil {
            if argument.label?.name == "if" {
                let v = checkCondition(argument.value.node, exprContext)
                if !v.error { conditionNode = id(argument.value.node) }
            } else {
                reportUnknownLabels([arguments.firstIndex { $0.node.range == argument.node.range }!], arguments,
                                    signature: catalog.modifier(named: "style")!.signatures[0], calleeName: ".style",
                                    callRange: r, clause: modifier.arguments, exprContext)
            }
        }
        let v = styleArgument(first.value.node, exprContext)
        guard !v.error, let name = v.qualifier else { return nil }
        if let styleName, name == styleName {
            // A style using itself is a cycle, reported with the others.
        }
        // A style with `.hover`/`.pressed` inside `.hover`/`.pressed` (DK5009).
        if let state, styleHasState(name, visited: []) {
            report(.notAllowedInState, r, ["name": .code("style"), "state": .code(state == .pressed ? "pressed" : "hover"),
                                           "hint": hintText(.notAllowedInState, "nestedState")])
            return nil
        }
        return (name, conditionNode, modifier.node)
    }

    /// The style names written in `a | b | c`.
    func styleNames(in node: PositionedNode) -> [String] {
        switch node.kind {
        case .binaryExpr:
            let b = BinaryExprSyntax(unchecked: node)
            return styleNames(in: b.left.node) + styleNames(in: b.right.node)
        case .identifierExpr: return [IdentifierExprSyntax(unchecked: node).name]
        case .implicitMemberExpr: return [ImplicitMemberExprSyntax(unchecked: node).name.token.name]
        case .stringLiteral: return [StringLiteralSyntax(unchecked: node).literalValue ?? text(node)]
        default: return [text(node)]
        }
    }

    /// A style name argument: bare (correct), with a dot (DK3012), in quotes (DK3036), unknown (DK3007).
    func styleArgument(_ node: PositionedNode, _ context: ExprContext) -> Val {
        let r = range(node)
        var name: String
        switch node.kind {
        case .identifierExpr:
            name = IdentifierExprSyntax(unchecked: node).name
        case .implicitMemberExpr:
            let n = ImplicitMemberExprSyntax(unchecked: node).name.token.name
            if mute == 0 { styles[n]?.used = true }
            report(.dotOnOwnStyle, r, ["name": .code(n)], fixIts: [fix("removeDot", [edit(r, n)])])
            return .error
        case .stringLiteral:
            guard let s = StringLiteralSyntax(unchecked: node).literalValue else { return .error }
            name = s
            if styles[s] != nil {
                report(.quotedOwnName, r, ["fixed": .code(".style(\(s))")],
                       fixIts: [fix("removeQuotes", [edit(r, s)], group: "quotedOwnName")])
            }
        default:
            _ = infer(node, context, expected: nil)
            return .error
        }
        guard let style = styles[name] else {
            if let requires = requiresNewer {
                report(.newerName, r, ["name": .code(name), "version": .code(requires.description)])
                return .error
            }
            let suggestion = DidYouMean.suggest(name, candidates: styleOrder.map(\.name))
            var fixIts: [FixIt] = []
            if let best = suggestion.names.first, suggestion.fixable || suggestion.via == .caseOnly || (suggestion.distance ?? 9) <= 2 {
                fixIts.append(fix("didYouMean", [edit(r, best)], ["text": .code(best)]))
                if mute == 0 { styles[best]?.used = true }
            }
            let insertAt = tree.text.utf8.count
            fixIts.append(fix("createStyle", [edit(insertAt..<insertAt, lineBreak + "style \(name) { }" + lineBreak)]))
            report(.unknownStyle, r, ["name": .code(name)], fixIts: fixIts)
            return .error
        }
        if mute == 0 { style.used = true }
        symbols[id(node)] = .style(style.id, file: style.file)
        var v = Val(.styleRef)
        v.qualifier = name
        return v
    }

    /// A show/hide/showOrHide target: a bare element name, a quoted one (DK3036), or text naming one at run time.
    func elementNameArgument(_ node: PositionedNode, _ context: ExprContext) -> Val {
        let r = range(node)
        switch node.kind {
        case .identifierExpr:
            let name = IdentifierExprSyntax(unchecked: node).name
            if let loop = loopStack.last(where: { $0.name == name }) {
                var v = loop.val
                v.deps.insert(.loopVariable(name))
                return v
            }
            if let decl = decls[name] {
                let v = declarationValue(decl)
                if v.type == .bool {
                    // `showOrHide(isOpen)` with a yes/no value.
                    return v
                }
                decl.used = true
                return v
            }
            if preName(named: name) != nil {
                symbols[id(node)] = .element(id(preName(named: name)!.call))
                var v = Val(.elementName)
                v.elementName = name
                return v
            }
            if let requires = requiresNewer {
                report(.newerName, r, ["name": .code(name), "version": .code(requires.description)])
                return .error
            }
            let suggestion = DidYouMean.suggest(name, candidates: preNames.map(\.name))
            var fixIts: [FixIt] = []
            if let best = suggestion.names.first, suggestion.fixable || (suggestion.distance ?? 9) <= 2 {
                fixIts.append(fix("didYouMean", [edit(r, best)], ["text": .code(best)]))
            }
            report(.unknownElementName, r, ["name": .code(name)], fixIts: fixIts)
            return .error
        case .stringLiteral:
            let v = inferValue(node, context, expected: .string)
            if let s = v.stringLiteral, preName(named: s) != nil, Checker.isIdentifier(s) {
                let callee = context.callee ?? "show"
                report(.quotedOwnName, r, ["fixed": .code("\(callee)(\(s))")],
                       fixIts: [fix("removeQuotes", [edit(r, s)], group: "quotedOwnName")])
            }
            return v
        default:
            return inferValue(node, context, expected: .string)
        }
    }

    /// `.position(…)` outside a Freeform (DK6001).
    func reportPositionOutsideFreeform(_ modifier: ModifierAppSyntax, element: ElementNode) {
        let r = range(modifier.node)
        let nameRange = range(modifier.name)
        let container: DiagnosticArgument = element.parent?.component.map { .name("component:\($0.name)") } ?? .name("place:widget")
        var fixIts = [fix("useText", [edit(nameRange, "offset")], ["text": .code(".offset")])]
        if let parent = element.parent, let parentCallee = parent.node.firstChild(.callee) {
            fixIts.append(fix("wrapIn", [edit(range(parentCallee), "Freeform")], ["text": .code("Freeform")]))
        }
        report(.positionOutsideFreeform, r, ["container": container], fixIts: fixIts, dropped: .modifier(id(modifier.node)))
    }

    /// `.rainmeter(option, value)` (D127): only in converted widgets, only the details the renderer keeps.
    func checkRainmeterModifier(_ modifier: ModifierAppSyntax, element: ElementNode?) {
        let r = range(modifier.node)
        guard convertedFile else {
            report(.compatibilityOnly, r, dropped: .modifier(id(modifier.node)))
            return
        }
        guard let first = modifier.arguments?.arguments.first,
              let key = StringLiteralSyntax(first.value.node)?.literalValue else { return }
        let keyRange = range(first.value.node)
        if let rows = index.compatDetails[key.lowercased()] {
            if let kind = element?.kind, !rows.contains(where: { $0.appliesTo.contains(kind) }) {
                report(.rainmeterDetailNotKept, keyRange, ["name": .code(key)],
                       fixIts: [fix("remove", [edit(modifier.node.range.lowerBound..<r.upperBound, "")])])
            }
            return
        }
        let known = Checker.rainmeterMeterOptions.contains(key.lowercased())
            || catalog.allRainmeterMappings().contains { $0.value.key?.lowercased() == key.lowercased() }
        if known {
            report(.rainmeterDetailNotKept, keyRange, ["name": .code(key)],
                   fixIts: [fix("remove", [edit(modifier.node.range.lowerBound..<r.upperBound, "")])])
            return
        }
        let suggestion = DidYouMean.suggest(key, candidates: catalog.compatDetails.map(\.key))
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first { fixIts.append(fix("didYouMean", [edit(keyRange, "\"\(best)\"")], ["text": .code(best)])) }
        report(.unknownRainmeterOption, keyRange, ["name": .code(key)], fixIts: fixIts)
    }

    /// Checks of particular modifiers' values.
    func checkModifierValues(_ spec: ModifierSpec, _ bound: BoundCall, modifier: ModifierAppSyntax, element: ElementNode?,
                             _ context: ViewContext) {
        switch spec.name {
        case "every":
            if let interval = bound.value("interval"), let seconds = interval.val.literalValue, interval.val.dimension == .time {
                let r = range(interval.node)
                if seconds < catalog.limits.minimumEvery {
                    report(.everyTooFast, r, fixIts: [fix("replaceWith", [edit(r, "16ms")], ["text": .code("16ms")])])
                } else if seconds < catalog.limits.everyTipBelow {
                    report(.everyVeryOften, r, ["interval": .code(text(interval.node))])
                }
            }
        case "when":
            if let condition = bound.value("condition"), !condition.val.error {
                let reads = condition.val.deps.filter {
                    switch $0 {
                    case .option, .language, .appearance: return false
                    default: return true
                    }
                }
                if reads.isEmpty {
                    report(.whenRarelyChanges, range(condition.node))
                }
            }
        case "align":
            if let element, let kind = element.kind, ElementKindSet.containers.contains(kind),
               let value = bound.values.first {
                let container = element.component?.name ?? "Column"
                let v = text(value.node).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                report(.alignOnContainer, range(modifier.node), ["container": .code(container), "value": .code(v)])
            }
        case "size":
            if let element, element.kind == .text, bound.values.count == 1,
               !element.node.children(.modifierApp).contains(where: { ModifierAppSyntax(unchecked: $0).name.token.text == "font" }) {
                let n = text(bound.values[0].node)
                report(.textBoxSize, range(modifier.node), ["number": .code(n)],
                       fixIts: [fix("replaceWith", [edit(range(modifier.node), ".font(\(n))")], ["text": .code(".font(\(n))")])])
            }
        default:
            break
        }
    }

    /// Records a reaction or timer (§4.18) in document order.
    func recordReaction(_ spec: ModifierSpec, modifier: ModifierAppSyntax, bound: BoundCall?, element: ElementNode?) {
        guard mute == 0, let timing = spec.timing, let element else { return }
        let kind: ReactionFacts.Kind
        switch timing {
        case .every: kind = .every
        case .when: kind = .when
        case .onChange: kind = .onChange
        case .onLoad: kind = .onLoad
        case .onWake: kind = .onWake
        }
        var deps = Set<DepKey>()
        for value in bound?.values ?? [] { deps.formUnion(value.val.deps) }
        let interval = kind == .every ? bound?.values.first?.val.literalValue : nil
        reactions.append(ReactionFacts(kind: kind, modifier: id(modifier.node), element: element.id, dependencies: deps,
                                       interval: interval))
    }

    // MARK: - Duplicates and facets

    /// Duplicates within one source (§4.8.3): the same modifier twice (DK5001), one facet from two modifiers (DK5002).
    func checkDuplicates(_ applied: [AppliedModifier], element: ElementNode?) {
        var byName: [String: [AppliedModifier]] = [:]
        for a in applied { byName[a.name, default: []].append(a) }
        for (_, copies) in byName where copies.count > 1 {
            let spec = copies[0].spec
            switch spec.repeatable {
            case .yes: continue
            case .perArgument:
                var groups: [String: [AppliedModifier]] = [:]
                for c in copies { groups[c.firstArgument ?? "", default: []].append(c) }
                for (_, group) in groups where group.count > 1 { reportDuplicateCopies(group, element: element) }
            case .no:
                let unconditional = copies.filter { $0.condition == nil }
                if unconditional.count > 1 { reportDuplicateCopies(unconditional, element: element) }
            }
        }
        // One facet from two different modifiers, both unconditional and hard.
        var setters: [FacetID: [(String, AppliedModifier)]] = [:]
        for a in applied where a.condition == nil {
            for (facet, _, _, hard) in a.facets where hard {
                if setters[facet]?.contains(where: { $0.0 == a.name }) == true { continue }
                setters[facet, default: []].append((a.name, a))
            }
        }
        var reportedPairs = Set<String>()
        for (facet, list) in setters.sorted(by: { $0.key < $1.key }) where list.count > 1 {
            let first = list[0].1, second = list[1].1
            let pair = "\(first.name)|\(second.name)"
            guard reportedPairs.insert(pair).inserted else { continue }
            let r = range(second.node)
            report(.duplicateFacet, r, ["facet": .name("facet:\(facet)"), "a": .code(first.name), "b": .code(second.name)],
                   notes: [note("otherCopy", range(first.node))],
                   fixIts: [fix("removeOne", [edit(second.node.range.lowerBound..<r.upperBound, "")])],
                   dropped: .modifier(id(second.node)))
            element?.facts.dropped.append(.modifier(id(second.node)))
            element?.facts.dropped.append(.modifier(id(first.node)))
        }
    }

    func reportDuplicateCopies(_ copies: [AppliedModifier], element: ElementNode?) {
        for copy in copies.dropFirst() {
            let r = range(copy.node)
            report(.duplicateModifier, range(ModifierAppSyntax(unchecked: copy.node).name), ["name": .code(copy.name)],
                   notes: [note("otherCopy", range(copies[0].node))],
                   fixIts: [fix("removeThisOne", [edit(copy.node.range.lowerBound..<r.upperBound, "")])],
                   dropped: .modifier(id(copy.node)))
            element?.facts.dropped.append(.modifier(id(copy.node)))
        }
        element?.facts.dropped.append(.modifier(id(copies[0].node)))
        duplicateDropped.formUnion(copies.map { $0.node.range.lowerBound })
    }

    /// The candidates of every facet of an element, best first (§4.8.5).
    func buildFacets(element: ElementNode, own: [AppliedModifier], states: [[AppliedModifier]],
                     styleCalls: [(style: String, condition: NodeID?, node: PositionedNode)]) {
        var candidates: [FacetID: [Candidate]] = [:]
        var position = 0
        func add(_ a: AppliedModifier, level: Int, extra: CandidateCondition?, origin: CandidateOrigin) {
            guard !duplicateDropped.contains(a.node.range.lowerBound) else { return }
            if let kind = element.kind, !a.spec.appliesTo.contains(kind) { return }
            var conditions: [CandidateCondition] = []
            if let extra { conditions.append(extra) }
            if let s = a.state { conditions.append(s) }
            if let c = a.condition { conditions.append(.expr(c)) }
            let condition: CandidateCondition? = conditions.isEmpty ? nil : conditions.count == 1 ? conditions[0] : .all(conditions)
            for (facet, value, fixed, hard) in a.facets {
                position += 1
                candidates[facet, default: []].append(Candidate(value: value, fixedValue: fixed, condition: condition, level: level,
                                                                hard: hard, position: position, origin: origin))
            }
        }
        // Styles in the order written, each after the styles it includes (level 2), then the element's own (level 3).
        var anyApplied = false
        for call in styleCalls {
            let before = position
            let condition = call.condition.map { CandidateCondition.expr($0) }
            expandStyle(call.style, visited: []) { a, styleName in
                add(a, level: 2, extra: condition, origin: .style(styleName, id(a.node), file: a.file))
            }
            var expanded = 0
            expandStyle(call.style, visited: []) { _, _ in expanded += 1 }
            if position == before, styles[call.style] != nil, element.kind != nil, expanded > 0 {
                report(.styleHasNoEffect, range(call.node), ["style": .code(call.style),
                                                             "component": .name("component:\(element.component?.name ?? "")")])
            }
            anyApplied = anyApplied || position > before
        }
        for a in own { add(a, level: 3, extra: nil, origin: .own(id(a.node))) }
        for source in states { for a in source { add(a, level: 3, extra: nil, origin: .own(id(a.node))) } }
        for (facet, list) in candidates {
            candidates[facet] = list.sorted { $0.sortKey > $1.sortKey }
        }
        element.facts.facets = candidates
        element.ownFacetsAvailable = true
    }

    /// Calls `visit` for every applied modifier of a style, included styles first (D98).
    func expandStyle(_ name: String, visited: Set<String>, _ visit: (AppliedModifier, String) -> Void) {
        guard let style = styles[name], !visited.contains(name) else { return }
        var seen = visited
        seen.insert(name)
        for include in style.includes { expandStyle(include.style, visited: seen) { a, s in
            var copy = a
            if let c = include.condition {
                copy.condition = copy.condition ?? c
            }
            visit(copy, s)
        } }
        for a in style.applied { visit(a, name) }
    }

    func styleHasState(_ name: String, visited: Set<String>) -> Bool {
        guard let style = styles[name], !visited.contains(name) else { return false }
        if style.hasState { return true }
        return style.includes.contains { styleHasState($0.style, visited: visited.union([name])) }
    }

    /// Inheritance (§4.8.6): the inherited four pass from containers to `Text`, `Label` and `Icon`.
    func computeInheritance() {
        let inheritable = Set(catalog.facets.filter(\.inheritable).map(\.id))
        for element in allElements {
            guard let kind = element.kind,
                  [.text, .label, .icon].contains(kind) || ElementKindSet.containers.contains(kind) else { continue }
            var inherits = Set<FacetID>()
            for facet in inheritable {
                let own = element.facts.facets[facet] ?? []
                if own.contains(where: { $0.condition == nil }) { continue }
                var ancestor = element.parent
                while let a = ancestor {
                    if !(a.facts.facets[facet] ?? []).isEmpty { inherits.insert(facet); break }
                    ancestor = a.parent
                }
            }
            element.facts.inherits = inherits
            if mute == 0 { elementFacts[element.id] = element.facts }
        }
    }

    /// Checks that need all of an element's modifiers: DK5021, DK5024, DK6009, DK6011, DK5014.
    func checkElementCombinations(_ element: ElementNode, modifiers: [ModifierAppSyntax], applied: [AppliedModifier]) {
        let names = Set(modifiers.map { $0.name.token.text })
        if names.contains("onRightClick"), names.contains("menu"),
           let menu = modifiers.first(where: { $0.name.token.text == "menu" }) {
            report(.menuHiddenByRightClick, range(menu.name))
        }
        if let kind = element.kind, ElementKindSet.shapes.contains(kind), names.contains("background"), !names.contains("fill"),
           let background = modifiers.first(where: { $0.name.token.text == "background" }) {
            report(.backgroundOnShape, range(background.name),
                   fixIts: [fix("replaceWith", [edit(range(background.name), "fill")], ["text": .code(".fill")])])
        }
        if element.hasPosition, element.parent?.kind == .freeform {
            if let margin = modifiers.first(where: { $0.name.token.text == "margin" }) {
                let r = range(margin.node)
                report(.marginWithPosition, r, fixIts: [fix("remove", [edit(margin.node.range.lowerBound..<r.upperBound, "")])])
            }
            if let kind = element.kind, kind == .text || kind == .label, !names.contains("width") && !names.contains("size"),
               let align = modifiers.first(where: { $0.name.token.text == "align" }),
               let position = modifiers.first(where: { $0.name.token.text == "position" }) {
                let value = align.arguments?.arguments.first.map { text($0.value.node) } ?? ".right"
                let center = value == ".center"
                let args = position.arguments?.arguments ?? []
                let anchorArg = args.first { $0.label?.name == "anchor" }
                let bottom = anchorArg.map { text($0.value.node).lowercased().contains("bottom") } ?? false
                let anchor = center ? (bottom ? ".bottom" : ".top") : (bottom ? ".bottomRight" : ".topRight")
                let kept = args.filter { $0.label?.name != "anchor" }.map { text($0.node) }
                let fixed = ".position(\((kept + ["anchor: \(anchor)"]).joined(separator: ", ")))"
                let edge = center ? LocalizedText("middle", "中间") : LocalizedText("right edge", "右边")
                report(.alignOnPositionedText, range(align.node), ["edge": .text(edge), "fixed": .code(fixed)],
                       fixIts: [fix("useText", [edit(range(position.node), fixed),
                                                edit(align.node.range.lowerBound..<range(align.node).upperBound, "")], ["text": .code(fixed)])])
            }
        }
        if element.kind == .button, !names.contains("onClick"), !trailingActionBlocks.contains(element.node.range.lowerBound) {
            let end = range(element.node).upperBound
            report(.buttonWithoutAction, range(element.node.firstChild(.callee) ?? element.node),
                   fixIts: [fix("insert", [edit(end..<end, ".onClick { }")], ["text": .code(".onClick { }")])])
        }
        // DK6012 is about a vertical Scroll (its message offers `.height(200)`); a sideways one in a `.fit` widget is a
        // strip whose width follows the widget's.
        let horizontal = element.node.firstChild(.argumentClause).map { text($0).contains(".horizontal") } ?? false
        let side = "height"
        if element.kind == .scroll, !horizontal, preset == "fit", !names.contains(side) && !names.contains("size") {
            var ancestorSized = false
            var a = element.parent
            while let p = a {
                let pn = Set(p.modifierNames)
                if pn.contains(side) || pn.contains("size") { ancestorSized = true; break }
                a = p.parent
            }
            if !ancestorSized {
                let end = range(element.node).upperBound
                report(.scrollGrowsWithContent, range(element.node.firstChild(.callee) ?? element.node),
                       fixIts: [fix("insert", [edit(end..<end, ".\(side)(200)")], ["text": .code(".\(side)(200)")])])
            }
        }
    }

    // MARK: - Styles

    func collectStyle(_ node: PositionedNode, file: DeskFileID? = nil, fromPackage: Bool = false, id styleID: NodeID? = nil) {
        let decl = StyleDeclSyntax(unchecked: node)
        let token = decl.name
        guard !token.token.isMissing, token.kind == .identifier || token.kind.isKeyword else { return }
        let name = token.token.name
        if !fromPackage {
            guard checkOwnName(token, kind: "style", allowBlockWords: true) else { return }
        }
        if let existing = styles[name] {
            if existing.fromPackage && !fromPackage {
                report(.styleReplacesPackage, range(token), ["name": .code(name)])
            } else if !fromPackage {
                reportNameClash(token, other: LocalizedText("another style", "另一个样式"), otherRange: existing.nameRange)
                return
            }
        }
        let style = StyleInfo(name: name, node: node, id: styleID ?? id(node), nameRange: fromPackage ? 0..<0 : range(token),
                              file: file ?? self.file, fromPackage: fromPackage)
        styles[name] = style
        styleOrder.removeAll { $0.name == name }
        styleOrder.append(style)
    }

    /// A style's body: a modifier chain, with the restrictions of §4.12.
    func checkStyleBody(_ style: StyleInfo) {
        guard let block = style.node.firstChild(.block) else { return }
        var applied: [AppliedModifier] = []
        let context = ViewContext()
        for statement in BlockSyntax(unchecked: block).statements {
            guard statement.kind == .modifierStmt else {
                reportNotAModifier(statement, place: "place:style")
                continue
            }
            for modifier in ModifierStmtSyntax(unchecked: statement).modifiers {
                let result = checkModifier(modifier, element: nil, state: nil, styleName: style.name, context)
                if let a = result.applied { applied.append(a) }
                for source in result.stateSources {
                    applied += source
                    style.hasState = true
                }
                if modifier.name.token.text == "hover" || modifier.name.token.text == "pressed" { style.hasState = true }
                for call in result.styleCalls { style.includes.append(StyleInclude(style: call.style, condition: call.condition)) }
                style.modifiers.append(modifier.node)
            }
        }
        checkDuplicates(applied.filter { $0.state == nil }, element: nil)
        style.applied = applied
        if style.modifiers.isEmpty { style.modifiers = [] }
    }

    /// DK5006: styles that use each other.
    func reportStyleCycles() {
        var graph: [String: [String]] = [:]
        for style in styleOrder { graph[style.name] = style.includes.map(\.style) }
        let own = Set(styleOrder.filter { !$0.fromPackage }.map(\.name))
        for cycle in Checker.cycles(in: graph, order: styleOrder.map(\.name), startingAt: { own.contains($0) }) {
            guard let style = styleOrder.first(where: { $0.name == cycle[0] && !$0.fromPackage }) else { continue }
            let list = (cycle + [cycle[0]]).map { DiagnosticArgument.code($0) }
            report(.styleCycle, style.nameRange, ["cycle": .list(list, joiner: .arrow)])
        }
    }
}

extension Checker {
    /// Meter options of Rainmeter's public manual (lower-cased): known options that a Desk widget may not keep are
    /// DK5027 rather than "unknown" (DK5020).
    static let rainmeterMeterOptions: Set<String> = Set([
        "MeterStyle", "X", "Y", "W", "H", "Hidden", "UpdateDivider", "SolidColor", "SolidColor2", "GradientAngle",
        "BevelType", "Padding", "AntiAlias", "DynamicVariables", "TransformationMatrix", "ToolTipText", "ToolTipTitle",
        "ToolTipIcon", "ToolTipType", "ToolTipWidth", "ToolTipHidden", "Group", "Container", "MeasureName", "MeasureName2",
        "Text", "Prefix", "Postfix", "FontFace", "FontSize", "FontColor", "FontWeight", "StringStyle", "StringAlign",
        "StringCase", "StringEffect", "FontEffectColor", "ClipString", "ClipStringW", "ClipStringH", "Angle", "Percentual",
        "AutoScale", "Scale", "NumOfDecimals", "InlineSetting", "InlinePattern", "ImageName", "ImagePath", "ImageAlpha",
        "ImageTint", "ImageFlip", "ImageRotate", "ImageCrop", "Greyscale", "ColorMatrix", "UseExifOrientation",
        "PreserveAspectRatio", "ScaleMargins", "Tile", "MaskImageName", "BarImage", "BarColor", "BarOrientation", "BarBorder",
        "Flip", "LineCount", "LineColor", "LineWidth", "HorizontalLines", "HorizontalLineColor", "GraphStart",
        "GraphOrientation", "PrimaryColor", "SecondaryColor", "BothColor", "PrimaryImage", "SecondaryImage", "BothImage",
        "StartAngle", "RotationAngle", "LineStart", "LineLength", "Solid", "ControlAngle", "ControlLength", "ControlLineStart",
        "LengthShift", "Shape", "BitmapImage", "BitmapFrames", "BitmapZeroFrame", "BitmapExtend", "BitmapDigits",
        "BitmapAlign", "BitmapSeparation", "ButtonImage", "ButtonCommand", "OffsetX", "OffsetY", "ValueRemainder",
        "LeftMouseUpAction", "LeftMouseDownAction", "MouseOverAction", "MouseLeaveAction", "MouseActionCursor",
    ].map { $0.lowercased() })
}

/// A `.style(…)` inside a style body.
struct StyleInclude {
    var style: String
    var condition: NodeID?
}
