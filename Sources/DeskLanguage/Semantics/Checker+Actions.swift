import Foundation

// Actions, events and timing, phase C5 (§4.16, §4.17): what an action block holds, assignments (what can be
// changed), action calls, user-initiated actions (D106), `after`, `event`, and the mistakes people make in events
// (looks set in an event, `+=`, a value used as a statement).

extension Checker {
    func checkActionBlock(_ block: PositionedNode, _ action: ActionContext, loopIDs: [NodeID]) {
        // `{ newValue in … }` (DK9111): the parameters are read silently in the block, not "there's no `newValue`".
        var parameters: [LoopVariable] = []
        if let first = block.childNodes.first, first.kind == .foreignConstruct, first.node.foreignKind == .closureParameter {
            for token in first.tokens where token.kind == .identifier && !token.token.isMissing {
                let parameterID = NodeID(kind: .foreignConstruct, utf8Start: token.textStart, treeVersion: tree.version)
                parameters.append(LoopVariable(name: token.token.name, id: parameterID, forID: parameterID, val: .error,
                                               range: range(token), inAction: true))
            }
        }
        for parameter in parameters { pushLoop(parameter, .error) }
        for statement in BlockSyntax(unchecked: block).statements { checkAction(statement, action, loopIDs: loopIDs) }
        for parameter in parameters.reversed() { popLoop(parameter) }
    }

    func actionExprContext(_ action: ActionContext, loopIDs: [NodeID]) -> ExprContext {
        var context = ExprContext()
        context.place = .actions
        context.action = action
        context.element = action.element
        context.usage = .onDemand
        context.loopScope = loopIDs
        return context
    }

    func checkAction(_ statement: PositionedNode, _ action: ActionContext, loopIDs: [NodeID]) {
        let context = actionExprContext(action, loopIDs: loopIDs)
        switch statement.kind {
        case .assignment:
            checkActionAssignment(statement, action, context)
        case .callStmt:
            checkActionCall(statement, action, context, loopIDs: loopIDs)
        case .ifStmt:
            let ifStmt = IfStmtSyntax(unchecked: statement)
            var conditionContext = context
            conditionContext.usage = .onDemand
            checkCondition(ifStmt.condition.node, conditionContext)
            checkActionBlock(ifStmt.block.node, action, loopIDs: loopIDs)
            if let elseClause = ifStmt.elseClause {
                if elseClause.body.kind == .ifStmt { checkAction(elseClause.body, action, loopIDs: loopIDs) }
                else if elseClause.body.kind == .block { checkActionBlock(elseClause.body, action, loopIDs: loopIDs) }
            }
            reportModifiersAfterBlock(ifStmt.modifiers, construct: "if", statement: statement, inViews: false)
        case .forStmt:
            let forStmt = ForStmtSyntax(unchecked: statement)
            let (variable, element) = checkForHeader(forStmt, context, inAction: true, depth: 0)
            pushLoop(variable, element)
            checkActionBlock(forStmt.block.node, action, loopIDs: loopIDs + [id(statement)])
            popLoop(variable)
            reportModifiersAfterBlock(forStmt.modifiers, construct: "for", statement: statement, inViews: false)
        case .modifierStmt:
            reportLooksInEvent(statement, action: action)
        case .declaration:
            reportDeclarationAfterView(statement, widgetBlock: widgetBlock?.firstChild(.block))
        case .field, .entry, .group, .optionDecl:
            report(.notAllowedHere, range(statement), ["what": .name(constructName(statement)), "place": .name("place:actions"),
                                                       "hint": .text(LocalizedText("", ""))])
        case .styleDecl, .componentDecl:
            reportMoveOut(statement, what: statement.kind == .styleDecl ? "construct:style" : "construct:component")
        default:
            break
        }
    }

    // MARK: - Assignments

    func checkActionAssignment(_ statement: PositionedNode, _ action: ActionContext, _ context: ExprContext) {
        let assignment = AssignmentSyntax(unchecked: statement)
        let target = assignment.target
        let path = target.path
        let targetRange = range(target.node)
        let valueNode = assignment.value.node
        guard assignment.isPlainAssignment else {
            // `+=`, `++`: reported by the parser (DK7004, DK7005); the value is still checked.
            _ = speculate { infer(valueNode, context, expected: nil) }
            return
        }
        if foreignAssignment(statement, assignment) { return }
        // Looks written on the line after an assignment: `page = 1`↵`.color(.red)` (DK7016).
        if let looks = trailingModifierInValue(valueNode) {
            reportLooksInEvent(looks.node, action: action, modifierName: looks.name)
            return
        }
        var targetVal: Val?
        var assignable = true
        if path.count == 1 {
            let name = path[0]
            if target.name.kind == .eventKeyword {
                reportNotAssignable(targetRange, name: "event", reasonKey: "event")
                assignable = false
            } else if loopStack.contains(where: { $0.name == name }) {
                reportNotAssignable(targetRange, name: name, reasonKey: "loopVariable")
                assignable = false
            } else if let decl = decls[name] {
                symbols[id(target.node)] = .declaration(decl.id)
                if decl.keyword == "computed" {
                    reportNotAssignable(targetRange, name: name, reasonKey: "computed")
                    assignable = false
                } else {
                    decl.used = true   // a use even where diagnostics are muted (a dropped modifier's block): no DK3020 cascade
                    if mute == 0 { decl.assigned = true }
                    targetVal = declarationValue(decl)
                    targetVal?.open = decl.open
                }
            } else if target.name.token.isUpperName {
                reportUppercaseName(target.name, declared: false)
                assignable = false
            } else {
                reportUndeclaredAssignment(assignment, inAction: true)
                assignable = false
            }
        } else if path.count == 2 && path[0] == "options" {
            let name = path[1]
            if let option = options[name] {
                symbols[id(target.node)] = .option(option.id, file: option.file)
                option.used = true
                if option.userOnly {
                    report(.userOnlyOption, targetRange, ["name": .code("options.\(name)")])
                    assignable = false
                } else {
                    targetVal = option.val
                    targetVal?.open = option.open
                }
            } else {
                _ = optionValue(name, nameRange: range(target.members[0]), node: target.node, context)
                assignable = false
            }
        } else {
            let memberPath = path.joined(separator: ".")
            if let member = catalog.member(path: memberPath) {
                if member.settable {
                    targetVal = Val(member.type)
                    targetVal?.range = member.range
                    if let ns = catalog.namespace(named: path.dropLast().joined(separator: ".")) {
                        notePermission(namespace: ns, member: member, at: targetRange)
                    }
                } else {
                    if let ns = catalog.namespace(named: path.dropLast().joined(separator: ".")) {
                        notePermission(namespace: ns, member: member, at: targetRange)
                    }
                    reportNotAssignable(targetRange, name: memberPath, reasonKey: "readOnlyData", twin: member.settableTwin,
                                        statement: range(statement))
                    assignable = false
                }
            } else if let decl = decls[path[0]] {
                symbols[id(target.node)] = .declaration(decl.id)
                reportNotAssignable(targetRange, name: memberPath, reasonKey: decl.keyword == "computed" ? "computed" : "readOnlyData")
                assignable = false
            } else {
                // An unknown path: resolve it for its own diagnostic.
                mute += 0
                var node = target.node
                _ = node
                node = target.node
                _ = infer(targetAsExpression(target), context, expected: nil)
                assignable = false
            }
        }
        var valueContext = context
        valueContext.display = false
        // `side = .right` where `side`'s own type is still open: the case takes the type `side` settles to, and is
        // checked against it then — one DK3018 at the declaration when nothing settles it, not a second one here.
        if assignable, let slot = targetVal?.open, slot < openSlots.count, openSlots[slot].kind == .type,
           valueNode.kind == .implicitMemberExpr {
            let name = ImplicitMemberExprSyntax(unchecked: valueNode).name.token.name
            if mute == 0 { casesForOpenSlots.append((slot, name, range(valueNode))) }
            return
        }
        let value = inferValue(valueNode, valueContext, expected: targetVal?.type)
        guard assignable, let targetVal, !value.error else { return }
        if let slot = targetVal.open {
            recordUse(slot, of: value, valueNode, description: LocalizedText("assigned \(catalog.displayName(for: value.type).en)",
                                                                           "被赋值为\(catalog.displayName(for: value.type).zh)"))
        } else if let slot = value.open {
            recordUse(slot, expected: targetVal.type, at: range(valueNode), description: LocalizedText("assigned to \(text(target.node))", "赋给 \(text(target.node))"))
        } else {
            _ = coerce(value, valueNode, to: targetVal.type, what: .code(text(target.node)), valueContext)
        }
        // Options assigned something that is not a constant count as variables (D102).
        if path.count == 2 && path[0] == "options", let option = options[path[1]] {
            if value.isConstant { option.assignedValues.append(text(valueNode)) } else { option.assignedNonConstant = true }
            optionAssignmentDeps[path[1], default: []].formUnion(value.deps)
        }
        if path.count == 1, let decl = decls[path[0]] {
            decl.assignedValues.append(text(valueNode))
            variableAssignmentDeps[path[0], default: []].formUnion(value.deps)
        }
    }

    /// A dotted target that is not data (`foo.bar = 1`), as an expression for its diagnostics.
    func targetAsExpression(_ target: TargetSyntax) -> PositionedNode {
        target.node
    }

    func reportNotAssignable(_ r: Range<Int>, name: String, reasonKey: String, twin: String? = nil, statement: Range<Int>? = nil) {
        var arguments: [String: DiagnosticArgument] = ["name": .code(name), "reason": hintText(.notAssignable, reasonKey),
                                                       "hint": .text(LocalizedText("", ""))]
        var fixIts: [FixIt] = []
        if let twin {
            arguments["hint"] = hintText(.notAssignable, "useTwin")
            arguments["fixed"] = .code(twin)
            fixIts.append(fix("replaceWith", [edit(statement ?? r, twin)], ["text": .code(twin)]))
        } else {
            arguments["fixed"] = .code("")
        }
        report(.notAssignable, r, arguments, fixIts: fixIts)
    }

    /// `page = page + 1`↵`.color(.red)`: the modifier was read as a member of the value, at the end of its right
    /// spine (`1.color(.red)` inside the sum). Returns the member access (or its call) and the modifier's name.
    func trailingModifierInValue(_ node: PositionedNode) -> (node: PositionedNode, name: String)? {
        var current = node
        while true {
            switch current.kind {
            case .binaryExpr: current = BinaryExprSyntax(unchecked: current).right.node
            case .prefixExpr: current = PrefixExprSyntax(unchecked: current).operand.node
            case .ternaryExpr: current = TernaryExprSyntax(unchecked: current).otherwise.node
            default:
                var callee = current
                if current.kind == .callExpr { callee = CallExprSyntax(unchecked: current).callee.node }
                guard callee.kind == .memberExpr else { return nil }
                let member = MemberExprSyntax(unchecked: callee)
                let name = member.name.token.name
                guard catalog.modifier(named: name) != nil, member.dot.token.leadingTrivia.containsLineBreak
                      || member.base.node.node.lastToken?.trailingTrivia.containsLineBreak == true else { return nil }
                return (current, name)
            }
        }
    }

    /// A name for the yes/no variable of a DK7016 fix-it that nothing uses yet (`alert`, `alert2`…); each
    /// diagnostic's fix-it gets its own, so applying two does not declare one twice.
    func newLooksVariable() -> String {
        var n = 1
        while true {
            let candidate = n == 1 ? "alert" : "alert\(n)"
            if decls[candidate] == nil, preName(named: candidate) == nil, !loopStack.contains(where: { $0.name == candidate }),
               !looksVariables.contains(candidate), !tree.text.contains(candidate) || n > 50 {
                if mute == 0 { looksVariables.append(candidate) }
                return candidate
            }
            n += 1
        }
    }

    /// DK7016: looks set in an event, with the fix-it that keeps a variable and uses `if:` on the element. `node`
    /// is a modifier statement, a modifier attached to an action call (`open("x").color(.red)`), or the member
    /// access a trailing modifier became in an assignment's value.
    func reportLooksInEvent(_ node: PositionedNode, action: ActionContext, modifierName: String? = nil) {
        var name = modifierName ?? "color"
        var argumentsText: String?
        var looksRange = range(node)
        var replacement: (range: Range<Int>, text: String)?
        let variable = newLooksVariable()
        switch node.kind {
        case .modifierStmt:
            if let first = ModifierStmtSyntax(unchecked: node).modifiers.first {
                name = first.name.token.text
                argumentsText = first.arguments.map { text(range($0.node)).dropFirst().dropLast().description } ?? ""
            }
            replacement = (range(node), "\(variable) = true")
        case .modifierApp:
            let modifier = ModifierAppSyntax(unchecked: node)
            name = modifier.name.token.text
            argumentsText = modifier.arguments.map { text(range($0.node)).dropFirst().dropLast().description } ?? ""
            looksRange = range(node)
            // Taken off the call; the assignment follows the call.
            if let statement = action.statement {
                let end = range(statement).upperBound
                let rest = text(looksRange.upperBound..<end)
                replacement = (looksRange.lowerBound..<end, rest + "; \(variable) = true")
            }
        case .callExpr, .memberExpr:
            let callee = node.kind == .callExpr ? CallExprSyntax(unchecked: node).callee.node : node
            let member = MemberExprSyntax(unchecked: callee)
            if node.kind == .callExpr {
                argumentsText = text(range(CallExprSyntax(unchecked: node).arguments.node)).dropFirst().dropLast().description
            } else {
                argumentsText = ""
            }
            looksRange = range(member.dot).lowerBound..<range(node).upperBound
            replacement = (looksRange, "\(variable) = true")
        default:
            break
        }
        let conditional = (argumentsText ?? "").isEmpty ? ".\(name)(if: \(variable))" : ".\(name)(\(argumentsText!), if: \(variable))"
        let usage = (argumentsText ?? "x").isEmpty ? ".\(name)(if: \(variable))" : ".\(name)(…, if: \(variable))"
        var fixIts: [FixIt] = []
        if let element = action.element, argumentsText != nil, let replacement, let widget = widgetBlock?.firstChild(.block) {
            let body = BlockSyntax(unchecked: widget)
            let open = body.lBrace.textRange.upperBound
            let elementEnd = range(element.node).upperBound
            let firstStatement = body.statements.first.map { textStart($0) } ?? open
            let sameLine = !text(open..<firstStatement).contains("\n") && !text(open..<firstStatement).contains("\r")
            let indent = sameLine ? "    " : indentation(at: firstStatement)
            let declaration = lineBreak + indent + "variable \(variable) = false" + (sameLine ? lineBreak + indent : "")
            var edits = [edit(open..<(sameLine ? firstStatement : open), declaration), edit(replacement.range, replacement.text)]
            if elementEnd > replacement.range.upperBound || elementEnd <= replacement.range.lowerBound {
                edits.append(edit(elementEnd..<elementEnd, conditional))
            }
            fixIts.append(fix("rewrite", edits))
        }
        report(.looksInEvent, looksRange, ["name": .code(name), "variable": .code(variable), "usage": .code(usage)], fixIts: fixIts)
    }

    /// Modifiers written on an action call (`open("x").color(.red)`, `after(1s) { }.padding(3)`): looks are not set
    /// in events (DK7016), and a name that is no modifier is DK3001.
    func reportActionCallModifiers(_ call: CallStmtSyntax, _ action: ActionContext) {
        var inner = action
        inner.statement = call.node
        for modifier in call.modifiers {
            let name = modifier.name.token.name
            if modifier.name.token.isMissing { continue }
            if catalog.modifier(named: name) != nil {
                reportLooksInEvent(modifier.node, action: inner)
            } else {
                let suggestion = DidYouMean.suggest(name, candidates: catalog.modifiers.map(\.name))
                var arguments: [String: DiagnosticArgument] = ["name": .code(name)]
                if let best = suggestion.names.first { arguments["suggestion"] = .code(best) }
                report(.unknownModifier, range(modifier.name), arguments)
            }
        }
    }

    // MARK: - Calls

    func checkActionCall(_ statement: PositionedNode, _ action: ActionContext, _ context: ExprContext, loopIDs: [NodeID]) {
        let call = CallStmtSyntax(unchecked: statement)
        reportActionCallModifiers(call, action)
        let callee = call.callee
        let path = callee.path
        let calleeRange = range(callee.node)
        let name = path.joined(separator: ".")
        let first = callee.name.token
        // Elements are not made in events.
        if path.count == 1, first.isUpperName {
            if catalog.component(named: path[0]) != nil || catalog.control(named: path[0]) != nil {
                report(.viewInAction, range(statement))
                return
            }
            if reportForeignComponent(call) { return }
            reportUnknownComponent(path[0], range: calleeRange)
            return
        }
        // Looks set in an event: a modifier written without its dot.
        if path.count == 1, catalog.modifier(named: path[0]) != nil, catalog.function(named: path[0]) == nil {
            let variable = newLooksVariable()
            report(.looksInEvent, range(statement), ["name": .code(path[0]), "variable": .code(variable),
                                                     "usage": .code(".\(path[0])(…, if: \(variable))")])
            return
        }
        var calleeContext = context
        calleeContext.callee = name
        if path.count == 1, let function = catalog.function(named: path[0]) {
            symbols[id(callee.node)] = .builtIn(.function(path[0]))
            noteSince(function.doc.since, name: name, at: calleeRange)
            if function.kind != .action {
                if function.name == "random" { _ = speculate { infer(statement, context, expected: nil) } }
                reportValueAsStatement(statement, function: function)
                return
            }
            if function.userInitiatedOnly && !action.userInitiated {
                report(.userActionOnly, calleeRange, ["name": .code(name), "event": .code(action.owner.hasPrefix("after") ? "after" : "." + action.owner)])
            }
            if let permission = function.permission { notePermission(permission, at: calleeRange) }
            let bound = bindCall(function.signatures, arguments: call.arguments, calleeName: name, what: .code(name),
                                 callRange: range(statement), calleeContext, owner: .function(function))
            if let bound { checkActionValues(function.name, bound, statement: statement, context: calleeContext) }
            if function.takesActionBlock {
                let delay = bound?.value("delay")
                if let d = delay, let seconds = d.val.literalValue, d.val.dimension == .time,
                   !catalog.limits.afterRange.contains(seconds) {
                    report(.afterOutOfRange, range(d.node))
                }
                if let block = call.block {
                    var inner = action
                    let literal = delay?.val.literalValue
                    inner.userInitiated = action.userInitiated && literal != nil && literal! <= catalog.limits.maximumUserActionDelay
                        && delay?.node.kind == .numberLiteral
                    inner.owner = "after"
                    checkActionBlock(block.node, inner, loopIDs: loopIDs)
                } else {
                    report(.blockNeeded, calleeRange, ["name": .code(name), "what": .name("content:actions")],
                           fixIts: [fix("insert", [edit(range(statement).upperBound..<range(statement).upperBound, " { }")], ["text": .code(" { }")])])
                }
            } else if let block = call.block {
                report(.unexpectedBlock, range(block.node), ["name": .code(name)])
            }
            if let bound { for value in bound.values where mute == 0 { dependencies[id(value.node)] = value.val.deps } }
            return
        }
        if path.count >= 2 {
            let nsName = path.dropLast().joined(separator: ".")
            if let ns = catalog.namespace(named: nsName), let member = ns.member(named: path.last!) {
                symbols[id(callee.node)] = .builtIn(.member(namespace: nsName, name: member.name))
                noteSince(member.doc.since, name: name, at: calleeRange)
                if member.kind != .action {
                    reportValueAsStatement(statement, function: nil)
                    return
                }
                if member.userInitiatedOnly && !action.userInitiated {
                    report(.userActionOnly, calleeRange, ["name": .code(name), "event": .code("." + action.owner)])
                }
                if let permission = member.permission ?? ns.permission { notePermission(permission, at: calleeRange) }
                _ = bindCall(member.signatures, arguments: call.arguments, calleeName: name, what: .code(name),
                             callRange: range(statement), calleeContext, owner: .member(member, path: name))
                if let block = call.block { report(.unexpectedBlock, range(block.node), ["name": .code(name)]) }
                return
            }
        }
        // `toggle(x)` (D113): `showOrHide(x)` for an element, `x = not x` for a yes/no value (§4.16, DK4001).
        if path == ["toggle"], decls["toggle"] == nil, let argument = call.arguments?.arguments.first,
           call.arguments?.arguments.count == 1, argument.label == nil {
            let value = infer(argument.value.node, context, expected: nil)
            if value.type == .bool, argument.value.node.kind == .identifierExpr {
                let variable = text(argument.value.node)
                let fixed = "\(variable) = not \(variable)"
                report(.typeMismatch, range(argument.value.node), ["what": .code("toggle"), "expected": .type(.elementName),
                                                                   "actual": .type(.bool)],
                       fixIts: [fix("convert", [edit(range(statement), fixed)], ["text": .code(fixed)])])
                return
            }
        }
        // A value used as a statement, or something unknown.
        if path.count == 1, decls[path[0]] != nil || loopStack.contains(where: { $0.name == path[0] }) {
            reportValueAsStatement(statement, function: nil)
            return
        }
        if let row = foreignRows(forName: path.last ?? name).first(where: {
            if case .name = $0.pattern { return true }
            if case .member = $0.pattern { return true }
            return false
        }) {
            reportForeignName(row, at: calleeRange, name: path.last ?? name, call: call)
            return
        }
        if path.count >= 2, catalog.namespace(named: path[0]) != nil || decls[path[0]] != nil {
            let expr = speculate { () -> Val in
                var v = Val.error
                v.namespace = nil
                return v
            }
            _ = expr
            // Resolve the path for its diagnostic (unknown member).
            let base = Val(.any)
            var nsVal = base
            nsVal.namespace = catalog.namespace(named: path[0]) != nil ? path[0] : nil
            if nsVal.namespace != nil {
                _ = reportUnknownMember(nsVal, baseNode: callee.node, name: path.last!, nameRange: range(callee.members.last!),
                                        context, called: true)
                return
            }
        }
        if let requires = requiresNewer {
            report(.newerName, calleeRange, ["name": .code(name), "version": .code(requires.description)])
            return
        }
        let actions = catalog.functions.filter { $0.kind == .action }.map(\.name)
        let suggestion = DidYouMean.suggest(name, candidates: actions, keywords: { word in
            index.keywordMatches(word).compactMap { path -> String? in
                if case .function(let f) = path { return f }
                return nil
            }
        })
        var arguments: [String: DiagnosticArgument] = ["name": .code(name)]
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first {
            arguments["suggestion"] = .code(best)
            if suggestion.fixable { fixIts.append(fix("fix", [edit(calleeRange, best)])) }
        }
        report(.unknownName, calleeRange, arguments, fixIts: fixIts)
    }

    /// Checks of particular actions' values: show/hide with a yes/no value, commands, notifications.
    func checkActionValues(_ name: String, _ bound: BoundCall, statement: PositionedNode, context: ExprContext) {
        switch name {
        case "show", "hide", "showOrHide":
            if let target = bound.values.first, target.val.type == .bool, target.node.kind == .identifierExpr {
                let variable = text(target.node)
                let fixed = "\(variable) = not \(variable)"
                report(.typeMismatch, range(target.node), ["what": .code(name), "expected": .type(.elementName),
                                                           "actual": .type(.bool)],
                       fixIts: [fix("convert", [edit(range(statement), fixed)], ["text": .code(fixed)])])
            }
        default:
            break
        }
    }

    // MARK: - for

    /// `for x in list` (§4.15): the list, the loop variable, the element count and nesting limits.
    func checkForHeader(_ forStmt: ForStmtSyntax, _ context: ExprContext, inAction: Bool, depth: Int) -> (LoopVariable?, Val) {
        var listContext = context
        listContext.display = false
        listContext.param = nil
        let source = forStmt.source.node
        let list = inferValue(source, listContext, expected: nil)
        if mute == 0 { dependencies[id(source)] = list.deps }
        var element = Val.error
        if !list.error {
            if case .list(let e) = list.type {
                element = Val(e)
                element.deps = list.deps
                element.canBeMissing = list.canBeMissing
                var identity = "position"
                if case .record(let rid) = e, let field = catalog.record(rid)?.identityField { identity = field }
                if mute == 0 { loopIdentities[id(forStmt.node)] = identity }
            } else if list.isJson {
                element = Val(.json)
                element.deps = list.deps
            } else if list.open == nil {
                report(.typeMismatch, range(source), ["what": .text(LocalizedText("`for`", "`for`")),
                                                      "expected": .type(.list(.any)), "actual": .type(list.type)])
            }
        }
        // Limits.
        if !inAction, depth + 1 > catalog.limits.maximumForNesting {
            report(.forTooDeep, range(forStmt.forKeyword))
        }
        if let count = list.literalValue, count > Double(catalog.limits.maximumForInstances), source.kind != .identifierExpr {
            report(.forTooLong, range(source))
        }
        // The loop variable.
        let token = forStmt.variable
        guard !token.token.isMissing, token.kind == .identifier || token.kind.isKeyword || token.kind == .invalidIdentifier else {
            return (nil, element)
        }
        let name = token.token.name
        let loopID = NodeID(kind: .forStmt, utf8Start: textStart(forStmt.node), treeVersion: tree.version)
        guard checkOwnName(token, kind: "loop") else {
            // `for event in …`: still the loop variable, so `event.title` reads it; renamed with its uses (DK3015).
            guard lastRefusedAsReserved, let pending = pendingReservedName else { return (nil, element) }
            reservedRenames.append((pending.index, pending.declaration, pending.newName, .loopVariable(loopID)))
            var val = element
            val.bind = .loopVariable(name)
            return (LoopVariable(name: name, id: loopID, forID: loopID, val: val, range: range(token), inAction: inAction), element)
        }
        if let decl = decls[name] {
            reportNameClash(token, other: LocalizedText("a declaration", "一个声明"), otherRange: decl.nameRange)
        } else if let outer = loopStack.last(where: { $0.name == name }) {
            reportNameClash(token, other: LocalizedText("an enclosing loop variable", "外层的循环变量"), otherRange: outer.range)
        }
        if let pre = preName(named: name) {
            reportNameClash(token, other: LocalizedText("an element's name", "一个元素的名字"), otherRange: pre.range)
        }
        reportHidesBuiltIn(token)
        symbols[NodeID(kind: .forStmt, utf8Start: range(token).lowerBound, treeVersion: tree.version)] = .loopVariable(loopID)
        var val = element
        val.bind = .loopVariable(name)
        return (LoopVariable(name: name, id: loopID, forID: loopID, val: val, range: range(token), inAction: inAction), element)
    }
}
