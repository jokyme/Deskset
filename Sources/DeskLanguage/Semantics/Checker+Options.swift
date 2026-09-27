import Foundation

// `info` and `package` fields (§4.19), options (§4.13) and translations (§8.6).

extension Checker {
    // MARK: - info and package

    func collectInfo(_ block: PositionedNode) {
        guard let body = block.firstChild(.block) else { return }
        let isPackageBlock = block.kind == .packageBlock
        for statement in BlockSyntax(unchecked: body).statements {
            if statement.kind == .assignment {
                // `info { name = "CPU" }`: the INI habit (DK2035); the field still counts.
                let assignment = AssignmentSyntax(unchecked: statement)
                let target = assignment.target
                guard target.path.count == 1, assignment.isPlainAssignment else { continue }
                let name = target.name.token.name
                let equal = range(assignment.equal)
                report(.equalsInField, equal, ["label": .code(name), "fixed": .code("\(name): \(text(assignment.value.node))")],
                       fixIts: [fix("replaceWith", [edit(equal, ":")], ["text": .code(":")], group: "equalsInField")])
                if infoFields[name] == nil, (isPackageBlock ? index.packageFields[name] : index.infoFields[name]) != nil {
                    infoFields[name] = (statement, assignment.value.node)
                    if name == "size", assignment.value.node.kind == .implicitMemberExpr {
                        preset = ImplicitMemberExprSyntax(unchecked: assignment.value.node).name.token.name
                    }
                }
                continue
            }
            guard statement.kind == .field else { continue }
            let field = FieldSyntax(unchecked: statement)
            let name = field.label.name
            let r = range(field.label.node)
            if infoFields[name] != nil {
                let fr = range(statement)
                report(.duplicateField, r, ["name": .code(name)], notes: [note("otherCopy", range(infoFields[name]!.node))],
                       fixIts: [fix("removeOne", [edit(statement.range.lowerBound..<fr.upperBound, "")])], dropped: .field(id(statement)))
                continue
            }
            let spec = isPackageBlock ? index.packageFields[name] : index.infoFields[name]
            guard spec != nil else {
                let block = isPackageBlock ? "package" : "info"
                let names = (isPackageBlock ? catalog.packageFields : catalog.infoFields).map(\.name)
                let suggestion = DidYouMean.suggest(name, candidates: names, keywords: { word in
                    index.keywordMatches(word).compactMap { path -> String? in
                        if case .infoField(let f) = path { return f }
                        return nil
                    }
                })
                var fixIts: [FixIt] = []
                if let best = suggestion.names.first { fixIts.append(fix("didYouMean", [edit(r, best)], ["text": .code(best)])) }
                report(.unknownField, r, ["block": .code(block), "name": .code(name),
                                          "list": .list(names.map { .code($0) }, joiner: .or)], fixIts: fixIts,
                       dropped: .field(id(statement)))
                continue
            }
            infoFields[name] = (statement, field.value.node)
            let value = field.value.node
            switch name {
            case "size":
                if value.kind == .implicitMemberExpr {
                    let preset = ImplicitMemberExprSyntax(unchecked: value).name.token.name
                    if ["small", "medium", "large", "fit"].contains(preset) { self.preset = preset }
                }
            case "convertedFrom":
                convertedFile = true
            default:
                break
            }
        }
    }

    func checkInfo(_ block: PositionedNode) {
        guard let body = block.firstChild(.block) else { return }
        let isPackageBlock = block.kind == .packageBlock
        for statement in BlockSyntax(unchecked: body).statements {
            switch statement.kind {
            case .field:
                break
            case .foreignConstruct, .unexpected, .assignment:
                continue
            default:
                report(.notAllowedHere, range(statement), ["what": .name(constructName(statement)),
                                                           "place": .name(isPackageBlock ? "place:package" : "place:info"),
                                                           "hint": .text(LocalizedText("", ""))])
                continue
            }
            let field = FieldSyntax(unchecked: statement)
            let name = field.label.name
            guard let spec = isPackageBlock ? index.packageFields[name] : index.infoFields[name],
                  infoFields[name]?.node.range == statement.range else { continue }
            noteSince(spec.doc.since, name: name, at: range(field.label.node))
            let value = field.value.node
            var context = ExprContext()
            context.place = .info
            context.constantOnly = true
            context.translatableField = spec.translatable
            context.param = ParamSpec(label: name, name: name, type: spec.type, role: spec.translatable ? .display : .plain,
                                      translatable: spec.translatable, doc: spec.doc.text)
            if name == "requires" || name == "deskVersion" {
                _ = infer(value, context, expected: spec.type)
                continue
            }
            let val = inferValue(value, context, expected: spec.type)
            if val.error { continue }
            if !val.isConstant && !val.error {
                report(.typeMismatch, range(value), ["what": .code(name), "expected": .type(spec.type), "actual": .type(val.type)])
                continue
            }
            if name == "size", val.isNumber {
                report(.typeMismatch, range(value), ["what": .code("size"), "expected": .type(spec.type), "actual": .type(val.type)])
                continue
            }
            var paramForCoerce = context.param!
            paramForCoerce.role = .plain
            _ = coerce(val, value, to: spec.type, what: .code(name), context, range: spec.range, param: paramForCoerce)
            switch name {
            case "refresh":
                if let seconds = val.literalValue, val.dimension == .time, !catalog.limits.refreshRange.contains(seconds) {
                    let clamped = seconds < catalog.limits.refreshRange.lowerBound ? "250ms" : "1h"
                    report(.refreshOutOfRange, range(value), fixIts: [fix("clamp", [edit(range(value), clamped)])])
                }
            case "network":
                checkNetworkList(value)
            case "permissions":
                if value.kind == .listLiteral {
                    for element in ListLiteralSyntax(unchecked: value).elements where element.node.kind == .implicitMemberExpr {
                        let permission = ImplicitMemberExprSyntax(unchecked: element.node).name.token.name
                        declaredPermissions.append((permission, range(element.node), element.node))
                    }
                }
            default:
                break
            }
        }
        if !isPackageBlock && infoFields["name"] == nil {
            reportMissingName(block)
        }
    }

    func reportMissingName(_ block: PositionedNode?) {
        guard !isPackage else { return }
        if let block, let body = block.firstChild(.block) {
            let open = BlockSyntax(unchecked: body).lBrace.textRange.upperBound
            report(.missingName, keyword(block), fixIts: [fix("insert", [edit(open..<open, " name: \"\(defaultWidgetName)\",")],
                                                              ["text": .code("name: \"\(defaultWidgetName)\"")])])
        } else {
            let insertText = "info { name: \"\(defaultWidgetName)\" }" + lineBreak + lineBreak
            let at = widgetBlock.map { $0.range.lowerBound } ?? 0
            let start = widgetBlock.map { textStart($0) } ?? 0
            report(.missingName, start..<start, fixIts: [fix("insert", [edit(start..<start, insertText)], ["text": .code("info { name: … }")])])
            _ = at
        }
    }

    var defaultWidgetName: String {
        ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// `network: […]`: host names only (DK8106).
    func checkNetworkList(_ value: PositionedNode) {
        guard value.kind == .listLiteral else { return }
        for element in ListLiteralSyntax(unchecked: value).elements {
            guard let host = StringLiteralSyntax(element.node)?.literalValue else { continue }
            let r = range(element.node)
            if let clean = Checker.hostProblem(host) {
                report(.invalidHost, r, fixIts: clean.isEmpty ? [] : [fix("replaceWithHost", [edit(r, "\"\(clean)\"")])])
                if !clean.isEmpty { declaredHosts.append((clean, r)) }
                continue
            }
            declaredHosts.append((host, r))
        }
    }

    /// Nil when `host` is a valid pattern; otherwise the host part to keep (possibly empty).
    static func hostProblem(_ host: String) -> String? {
        var h = host
        var changed = false
        if let schemeEnd = h.range(of: "://") { h = String(h[schemeEnd.upperBound...]); changed = true }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]); changed = true }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]); changed = true }
        let labelChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        var body = h
        if body.hasPrefix("*.") { body = String(body.dropFirst(2)) }
        let labels = body.split(separator: ".", omittingEmptySubsequences: false)
        let valid = !body.isEmpty && labels.count >= 1 && labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy { $0.isASCII && labelChars.contains($0) }
        }
        if valid && !changed { return nil }
        return valid ? h : ""
    }

    // MARK: - Options

    func importPackage(_ package: CheckedPackage) {
        let packageFile = package.file.tree.file
        for (name, facts) in package.options {
            let node = package.file.tree.resolve(facts.node) ?? package.file.tree.rootNode
            var val = Val(facts.type)
            val.base = facts.displayBase
            let option = OptionInfo(name: name, control: facts.control, node: node, id: facts.node, nameRange: 0..<0,
                                    file: packageFile, fromPackage: true, val: val)
            option.defaultText = facts.defaultText
            option.localEnum = facts.localEnum
            option.choices = facts.choices
            if let local = facts.localEnum { localEnums[local] = facts.choices }
            options[name] = option
            optionOrder.append(option)
        }
        for (name, styleID) in package.styles {
            guard let node = package.file.tree.resolve(styleID) else { continue }
            collectStyle(node, file: packageFile, fromPackage: true, id: styleID)
            _ = name
        }
        if let package = context.package {
            let packageChecker = Checker(tree: package.file.tree, context: CheckContext(catalog: catalog))
            packageChecker.mute = 1
            packageChecker.options = options
            for style in styleOrder where style.fromPackage {
                packageChecker.styles[style.name] = style
                packageChecker.styleOrder.append(style)
            }
            for style in packageChecker.styleOrder { packageChecker.checkStyleBody(style) }
        }
    }

    func collectOptions(_ block: PositionedNode) {
        guard let body = block.firstChild(.block) else { return }
        collectOptionItems(body)
        let widgetOptions = optionOrder.filter { !$0.fromPackage }
        if widgetOptions.count > catalog.limits.maximumOptions, let extra = widgetOptions.dropFirst(catalog.limits.maximumOptions).first {
            report(.tooManyOptions, extra.nameRange, ["limit": .number(catalog.limits.maximumOptions)])
        }
    }

    private func collectOptionItems(_ body: PositionedNode) {
        for statement in BlockSyntax(unchecked: body).statements {
            switch statement.kind {
            case .optionDecl:
                let decl = OptionDeclSyntax(unchecked: statement)
                let target = decl.target
                let token = target.name
                guard !token.token.isMissing else { continue }
                let name = token.token.name
                guard let call = decl.controlCall else { continue }
                let controlName = call.callee.name.token.name
                if !token.token.isUpperName {
                    guard checkOwnName(token, kind: "option", allowBlockWords: true) else { continue }
                } else if call.callee.path.count == 1 && catalog.control(named: controlName) != nil {
                    reportUppercaseName(token, declared: true)
                } else {
                    continue
                }
                if let existing = options[name] {
                    if existing.fromPackage {
                        // Replaces the package's option (DK3026); the value types must agree (DK3030, checked later).
                        packageReplaced[name] = existing
                    } else {
                        report(.duplicateOption, range(token), ["name": .code(name)], notes: [note("otherCopy", existing.nameRange)])
                        continue
                    }
                }
                let option = OptionInfo(name: name, control: controlName, node: statement, id: id(statement),
                                        nameRange: range(token), file: file, fromPackage: false, val: Val(.any))
                options[name] = option
                optionOrder.removeAll { $0.name == name }
                optionOrder.append(option)
            case .field:
                let field = FieldSyntax(unchecked: statement)
                let name = field.label.name
                let value = field.value.node
                guard value.kind == .callExpr, options[name] == nil else { continue }
                let control = text(CallExprSyntax(unchecked: value).callee.node)
                guard let spec = catalog.control(named: control) else { continue }
                var val = Val.error
                if case .fixed(let t) = spec.valueType { val = Val(t) }
                let option = OptionInfo(name: name, control: control, node: statement, id: id(statement),
                                        nameRange: range(field.label.node), file: file, fromPackage: false, val: val)
                options[name] = option
                optionOrder.append(option)
            case .callStmt:
                let call = CallStmtSyntax(unchecked: statement)
                let name = call.callee.name.token.name
                if name == "Section" {
                    if let inner = call.block { collectOptionItems(inner.node) }
                    continue
                }
                if catalog.control(named: name) != nil {
                    // A control with no name (DK8013).
                    let label = call.arguments?.arguments.first.flatMap { StringLiteralSyntax($0.value.node)?.literalValue } ?? name
                    let derived = DidYouMean.lowerCamel(from: label)
                    let start = textStart(statement)
                    report(.optionWithoutName, range(statement), ["fixed": .code("\(derived) = \(text(statement))")],
                           fixIts: [fix("insertName", [edit(start..<start, "\(derived) = ")], ["text": .code(derived)])])
                }
            default:
                break
            }
        }
    }

    func checkOptions(_ block: PositionedNode) {
        guard let body = block.firstChild(.block) else { return }
        checkOptionItems(body)
        for (name, packageOption) in packageReplaced {
            guard let option = options[name] else { continue }
            if !option.val.type.sameKind(as: packageOption.val.type) && !option.val.error && option.val.type != DeskType.any {
                report(.replacedOptionTypeDiffers, option.nameRange, ["name": .code(name), "expected": .type(packageOption.val.type),
                                                                      "actual": .type(option.val.type)],
                       notes: [Note(file: packageOption.file, range: 0..<0, messageKey: "packageDeclaration")])
            } else {
                report(.optionReplacesPackage, option.nameRange, ["name": .code(name)])
            }
        }
    }

    private func checkOptionItems(_ body: PositionedNode) {
        for statement in BlockSyntax(unchecked: body).statements {
            switch statement.kind {
            case .optionDecl:
                checkOptionDeclaration(statement)
            case .callStmt:
                let call = CallStmtSyntax(unchecked: statement)
                let name = call.callee.name.token.name
                if name == "Section" {
                    var context = ExprContext()
                    context.place = .options
                    if let spec = catalog.control(named: "Section") {
                        _ = bindCall(spec.signatures, arguments: call.arguments, calleeName: "Section", what: .code("Section"),
                                     callRange: range(call.callee.node), context, owner: .control(spec))
                    }
                    if let inner = call.block { checkOptionItems(inner.node) }
                    continue
                }
                if catalog.control(named: name) == nil {
                    reportUnknownControl(name, range: range(call.callee.node))
                }
            case .field:
                // `accent: ColorPicker(…)`: options are named with `=` (DK2036).
                let field = FieldSyntax(unchecked: statement)
                let colon = field.colon
                let fixed = "\(field.label.name) = \(text(field.value.node))"
                report(.colonInOption, range(colon), ["fixed": .code(fixed)],
                       fixIts: [fix("replaceWith", [edit(range(colon), " =")], ["text": .code("=")])])
            case .assignment:
                break
            case .foreignConstruct, .unexpected:
                break
            case .modifierStmt:
                report(.modifierWithoutElement, range(statement))
            default:
                report(.notAllowedHere, range(statement), ["what": .name(constructName(statement)), "place": .name("place:options"),
                                                           "hint": .text(LocalizedText("", ""))])
            }
        }
    }

    func reportUnknownControl(_ name: String, range r: Range<Int>) {
        let names = catalog.controls.filter { $0.name != "Choice" }.map(\.name)
        let suggestion = DidYouMean.suggest(name, candidates: names, keywords: { word in
            index.keywordMatches(word).compactMap { path -> String? in
                if case .control(let c) = path { return c }
                return nil
            }
        })
        var fixIts: [FixIt] = []
        if let best = suggestion.names.first { fixIts.append(fix("didYouMean", [edit(r, best)], ["text": .code(best)])) }
        report(.unknownControl, r, ["name": .code(name), "list": .list(names.map { .code($0) }, joiner: .or)], fixIts: fixIts)
    }

    /// One `name = Control(…)`.
    func checkOptionDeclaration(_ statement: PositionedNode) {
        let decl = OptionDeclSyntax(unchecked: statement)
        let name = decl.target.name.token.name
        guard let option = options[name], option.node.range == statement.range, let call = decl.controlCall else {
            if decl.controlCall == nil {
                report(.typeMismatch, range(decl.control), ["what": .code(name), "expected": .text(LocalizedText("a control such as `Toggle(\"…\")`", "一个控件，比如 `Toggle(\"…\")`")),
                                                           "actual": .text(LocalizedText("something else", "别的东西"))])
            }
            return
        }
        let controlName = call.callee.name.token.name
        guard call.callee.path.count == 1, let control = catalog.control(named: controlName), controlName != "Choice", controlName != "Section" else {
            reportUnknownControl(call.callee.path.joined(separator: "."), range: range(call.callee.node))
            option.val = .error
            return
        }
        noteSince(control.doc.since, name: controlName, at: range(call.callee.node))
        var context = ExprContext()
        context.place = .options
        let arguments = call.arguments?.arguments ?? []
        // Every control needs its label (DK8005).
        if arguments.first(where: { $0.label == nil }) == nil, controlName != "Section" {
            let at = call.arguments.map { $0.lParen.textRange.upperBound } ?? range(call.callee.node).upperBound
            let insert = call.arguments == nil ? "(\"\")" : (arguments.isEmpty ? "\"\"" : "\"\", ")
            report(.optionLabelMissing, range(call.callee.node), ["control": .code(controlName)],
                   fixIts: [fix("insert", [edit(at..<at, insert)], ["text": .code("\"\"")])])
            option.val = .error
            return
        }
        // A widget control written in options: a binding as its second value (DK5022).
        let positional = arguments.filter { $0.label == nil }
        if positional.count >= 2, ["Toggle", "Slider", "Input"].contains(controlName),
           positional[1].value.node.kind == .identifierExpr || positional[1].value.node.kind == .memberExpr,
           isBindableName(positional[1].value.node) {
            reportControlInWrongPlace(call, control: controlName)
            option.val = .error
            return
        }
        switch control.valueType {
        case .fromChoices:
            checkPicker(option, call: call, control: control, context)
        case .dimensionOf(let param):
            checkNumberControl(option, call: call, control: control, param: param, context)
        case .fixed(let t):
            let bound = bindCall(control.signatures, arguments: call.arguments, calleeName: controlName, what: .code(controlName),
                                 callRange: range(call.callee.node), context, owner: .control(control))
            option.val = Val(t)
            if let def = bound?.value("default") {
                option.defaultText = text(def.node)
                if !def.val.error, cost(def.val, t) == nil {
                    reportDefaultMismatch(option, def: def, expected: t)
                }
            }
        case .none:
            _ = bindCall(control.signatures, arguments: call.arguments, calleeName: controlName, what: .code(controlName),
                         callRange: range(call.callee.node), context, owner: .control(control))
            option.val = .error
        }
        checkOptionModifiers(call.modifiers, option: option)
    }

    func isBindableName(_ node: PositionedNode) -> Bool {
        if node.kind == .identifierExpr {
            let name = IdentifierExprSyntax(unchecked: node).name
            return decls[name] != nil
        }
        if node.kind == .memberExpr {
            let path = text(node)
            return catalog.member(path: path)?.settable == true
        }
        return false
    }

    func reportDefaultMismatch(_ option: OptionInfo, def: BoundValue, expected: DeskType) {
        var fixIts: [FixIt] = []
        let r = range(def.node)
        if expected == .bool, let value = def.val.plainLiteral, value == 0 || value == 1 {
            let word = value == 1 ? "true" : "false"
            fixIts.append(fix("convert", [edit(r, word)], ["text": .code(word)]))
        }
        report(.optionDefaultMismatch, r, ["name": .code(option.name), "expected": .type(expected)], fixIts: fixIts)
    }

    /// A Slider or Stepper: its dimension from `min:`, `max:` and `default:`, settled by use when they are plain.
    func checkNumberControl(_ option: OptionInfo, call: CallStmtSyntax, control: ControlSpec, param: String, _ context: ExprContext) {
        let bound = bindCall(control.signatures, arguments: call.arguments, calleeName: control.name, what: .code(control.name),
                             callRange: range(call.callee.node), context, owner: .control(control))
        guard let bound else { option.val = .error; return }
        let numbers = ["min", "max", "step", "default"].compactMap { bound.value($0) }
        let typed = numbers.first { $0.val.dimension != nil && $0.val.dimension != .plain && $0.val.plainLiteral == nil }
        if let typed {
            option.val = Val(typed.val.type)
            option.val.base = typed.val.base
            for n in numbers where n.val.dimension != typed.val.dimension && n.val.plainLiteral == nil && !n.val.error {
                if n.param.name == "default" { reportDefaultMismatch(option, def: n, expected: typed.val.type) }
                else {
                    report(.unitMismatch, range(n.node), ["op": .text(LocalizedText("compare", "比较")), "a": .type(typed.val.type),
                                                          "b": .type(n.val.type)])
                }
            }
            if let d = typed.val.dimension, d.needsWrittenUnit {
                for n in numbers where n.val.plainLiteral != nil { reportUnitNeeded(n.node, dimension: d) }
            }
        } else {
            option.val = Val(.number(.plain))
            // All plain: the dimension is settled by the option's uses.
            var literals: [(range: Range<Int>, value: Double)] = []
            for n in numbers { collectPlainLiterals(n.node, into: &literals) }
            openSlots.append(OpenSlot(kind: .dimension, owner: .option(option), literals: literals, candidates: [], memberName: nil,
                                      memberRange: nil))
            option.open = openSlots.count - 1
            option.val.open = option.open
        }
        if let def = bound.value("default") { option.defaultText = text(def.node) }
        else if let min = bound.value("min") { option.defaultText = text(min.node) }
    }

    /// A Picker (§4.13, D100): choices of one kind; a qualified case fixes the type; uses decide; else the one catalog
    /// type with every choice; else a local enum.
    func checkPicker(_ option: OptionInfo, call: CallStmtSyntax, control: ControlSpec, _ context: ExprContext) {
        let arguments = call.arguments?.arguments ?? []
        let positional = arguments.filter { $0.label == nil }
        if let firstLabel = arguments.firstIndex(where: { $0.label != nil }),
           let late = arguments.indices.first(where: { $0 > firstLabel && arguments[$0].label == nil }) {
            report(.positionalAfterLabel, range(arguments[late].node), fixIts: [reorderFix(arguments)])
        }
        guard positional.count >= 2 else {
            _ = bindCall(control.signatures, arguments: call.arguments, calleeName: control.name, what: .code(control.name),
                         callRange: range(call.callee.node), context, owner: .control(control))
            option.val = .error
            return
        }
        // Label.
        var labelContext = context
        labelContext.param = control.signatures[0].params[0]
        labelContext.display = true
        _ = inferValue(positional[0].value.node, labelContext, expected: .string)
        let choicesNode = positional[1].value.node
        guard choicesNode.kind == .listLiteral else {
            let v = inferValue(choicesNode, context, expected: nil)
            if !v.error { report(.typeMismatch, range(choicesNode), ["what": .code("Picker"), "expected": .type(.list(.any)), "actual": .type(v.type)]) }
            option.val = .error
            return
        }
        var kinds = Set<String>()
        var names: [(String, Range<Int>)] = []
        var qualified: String?
        var labels: [PositionedNode] = []
        for element in ListLiteralSyntax(unchecked: choicesNode).elements {
            var value = element.node
            if value.kind == .callExpr, text(CallExprSyntax(unchecked: value).callee.node) == "Choice" {
                let args = CallExprSyntax(unchecked: value).arguments.arguments
                if args.count > 1 { labels.append(args[1].value.node) }
                guard let first = args.first else { continue }
                value = first.value.node
            }
            switch value.kind {
            case .implicitMemberExpr:
                kinds.insert("case")
                names.append((ImplicitMemberExprSyntax(unchecked: value).name.token.name, range(value)))
            case .memberExpr:
                let member = MemberExprSyntax(unchecked: value)
                kinds.insert("case")
                if member.base.node.kind == .identifierExpr {
                    qualified = qualified ?? IdentifierExprSyntax(unchecked: member.base.node).name
                }
                names.append((member.name.token.name, range(value)))
            case .stringLiteral: kinds.insert("string")
            case .numberLiteral, .prefixExpr: kinds.insert("number")
            default: kinds.insert("other")
            }
        }
        var labelContext2 = context
        labelContext2.param = ParamSpec(label: nil, name: "label", type: .string, role: .display, translatable: true, doc: LocalizedText("", ""))
        labelContext2.display = true
        for label in labels { _ = inferValue(label, labelContext2, expected: .string) }
        if kinds.count > 1 {
            report(.pickerChoicesMixed, range(choicesNode))
            option.val = .error
            return
        }
        option.choices = names.map(\.0)
        pickerChoiceRanges[option.name] = names
        let kind = kinds.first ?? "case"
        let defaultArgument = arguments.first { $0.label?.name == "default" }
        if kind == "string" || kind == "number" {
            let list = inferValue(choicesNode, context, expected: nil)
            option.val = Val(list.type.listElement ?? .string)
            if kind == "number", list.type.listElement == .number(.plain) {
                var literals: [(range: Range<Int>, value: Double)] = []
                collectPlainLiterals(choicesNode, into: &literals)
                openSlots.append(OpenSlot(kind: .dimension, owner: .option(option), literals: literals, candidates: [], memberName: nil,
                                          memberRange: nil))
                option.open = openSlots.count - 1
                option.val.open = option.open
            }
            if let def = defaultArgument {
                let v = inferValue(def.value.node, context, expected: option.val.type)
                option.defaultText = text(def.value.node)
                if !v.error, cost(v, option.val.type) == nil {
                    reportDefaultMismatch(option, def: BoundValue(param: control.signatures[0].params[2], node: def.value.node, argument: def, val: v),
                                          expected: option.val.type)
                } else if let s = v.stringLiteral, kind == "string",
                          !ListLiteralSyntax(unchecked: choicesNode).elements.contains(where: { StringLiteralSyntax($0.node)?.literalValue == s }) {
                    reportDefaultNotAChoice(def.value.node, choicesNode: choicesNode)
                }
            }
            return
        }
        // Implicit members.
        if let qualified {
            let t: DeskType = qualified == "Color" ? .color : qualified == "Paint" ? .paint : .enumeration(qualified)
            for (name, r) in names where !implicitCaseFits(name, expected: t) {
                let cases = catalog.enumeration(qualified)?.cases.map(\.name) ?? []
                reportUnknownChoice(name, at: r, what: .type(t), candidates: cases)
            }
            option.val = Val(t)
        } else {
            var candidates: Set<String>?
            for (name, _) in names {
                var types = Set(index.implicitMembers[name]?.filter { $0.since <= (tree.header.requires ?? .deskFirstRelease) }.map(\.type) ?? [])
                if types.contains("Color") { types.remove("Paint") }
                candidates = candidates.map { $0.intersection(types) } ?? types
            }
            let list = Array(candidates ?? []).sorted()
            // Provisionally a local enum when no single catalog type has every choice.
            if list.count != 1 {
                let local = localEnumName(option)
                localEnums[local] = names.map(\.0)
                option.localEnum = local
                option.val = Val(.enumeration(local))
            } else {
                let t = list[0]
                option.val = Val(t == "Color" ? .color : t == "Paint" ? .paint : .enumeration(t))
            }
            openSlots.append(OpenSlot(kind: .type, owner: .option(option), literals: [], candidates: list, memberName: names.first?.0,
                                      memberRange: names.first?.1))
            option.open = openSlots.count - 1
            option.val.open = option.open
        }
        if let def = defaultArgument {
            option.defaultText = text(def.value.node)
            let node = def.value.node
            if node.kind == .implicitMemberExpr {
                let name = ImplicitMemberExprSyntax(unchecked: node).name.token.name
                if !option.choices.contains(name) {
                    reportDefaultNotAChoice(node, choicesNode: choicesNode)
                }
                symbols[id(node)] = .enumCase(type: option.val.type.enumID ?? "Color", case: name)
            } else {
                let v = inferValue(node, context, expected: option.val.type)
                if !v.error, let name = v.implicitName, !option.choices.contains(name) {
                    reportDefaultNotAChoice(node, choicesNode: choicesNode)
                } else if !v.error, v.implicitName == nil {
                    reportDefaultMismatch(option, def: BoundValue(param: control.signatures[0].params[2], node: node, argument: def, val: v),
                                          expected: option.val.type)
                }
            }
        }
        for argument in arguments where argument.label != nil && argument.label?.name != "default" {
            reportUnknownLabels([arguments.firstIndex { $0.node.range == argument.node.range }!], arguments,
                                signature: control.signatures[0], calleeName: control.name, callRange: range(call.node),
                                clause: call.arguments, context)
        }
    }

    func reportDefaultNotAChoice(_ node: PositionedNode, choicesNode: PositionedNode) {
        let r = range(node)
        var fixIts: [FixIt] = []
        if let first = ListLiteralSyntax(unchecked: choicesNode).elements.first {
            fixIts.append(fix("useFirstChoice", [edit(r, text(first.node))]))
        }
        report(.pickerDefaultNotAChoice, r, ["value": .code(text(node))], fixIts: fixIts)
    }

    /// `.help("…")`, `.hidden(if:)` (options only), `.visible(if:)` (DK9108) on an option control.
    func checkOptionModifiers(_ modifiers: [ModifierAppSyntax], option: OptionInfo) {
        for modifier in modifiers {
            let name = modifier.name.token.name
            let nameRange = range(modifier.name)
            var context = ExprContext()
            context.place = .options
            guard let spec = catalog.modifier(named: name), spec.context != .view else {
                if reportForeignModifier(modifier, element: nil) { continue }
                let names = catalog.modifiers.filter { $0.context != .view }.map(\.name)
                let suggestion = DidYouMean.suggest(name, candidates: names)
                var arguments: [String: DiagnosticArgument] = ["name": .code(name)]
                if let best = suggestion.names.first { arguments["suggestion"] = .code(best) }
                report(.unknownModifier, nameRange, arguments)
                continue
            }
            if name == "hidden" {
                context.optionsOnly = true
                guard let condition = modifier.arguments?.arguments.first(where: { $0.label?.name == "if" }) else { continue }
                let v = checkCondition(condition.value.node, context)
                let nonOptions = v.deps.filter { if case .option = $0 { return false }; return true }
                if !nonOptions.isEmpty { report(.optionConditionNotOption, range(condition.value.node)) }
                continue
            }
            _ = bindCall(spec.signatures, arguments: modifier.arguments, calleeName: "." + name, what: .code("." + name),
                         callRange: range(modifier.node), context, owner: .modifier(spec))
        }
    }

    // MARK: - Translations

    func checkTranslations(_ block: PositionedNode) {
        guard let body = block.firstChild(.block) else { return }
        var seenTags: [String: Range<Int>] = [:]
        let keys = Set(stringTable.map(\.key))
        for statement in BlockSyntax(unchecked: body).statements {
            guard statement.kind == .group else {
                if statement.kind != .foreignConstruct && statement.kind != .unexpected {
                    report(.notAllowedHere, range(statement), ["what": .name(constructName(statement)),
                                                               "place": .name("place:translations"), "hint": .text(LocalizedText("", ""))])
                }
                continue
            }
            let group = GroupSyntax(unchecked: statement)
            guard let tag = group.tag.literalValue else { continue }
            let tagRange = range(group.tag.node)
            let normalized = Checker.normalizeLanguageTag(tag)
            if !Checker.isKnownLanguageTag(normalized) {
                let suggestion = DidYouMean.suggest(tag, candidates: Checker.commonLanguageTags)
                var fixIts: [FixIt] = []
                if let best = suggestion.names.first { fixIts.append(fix("didYouMean", [edit(tagRange, "\"\(best)\"")], ["text": .code(best)])) }
                report(.unknownLanguage, tagRange, ["tag": .code(tag)], fixIts: fixIts)
            } else if normalized != tag, tag.contains("_") || Checker.chineseRegionTags[tag.replacingOccurrences(of: "_", with: "-")] != nil {
                let language = normalized.hasPrefix("zh-Hant") ? LocalizedText("Traditional Chinese", "繁体中文")
                    : normalized.hasPrefix("zh-Hans") ? LocalizedText("Simplified Chinese", "简体中文") : LocalizedText(normalized, normalized)
                report(.regionLanguageTag, tagRange, ["tag": .code(tag), "language": .text(language),
                                                      "macTag": .code(tag.replacingOccurrences(of: "_", with: "-")),
                                                      "canonical": .code(normalized)],
                       fixIts: [fix("replaceWith", [edit(tagRange, "\"\(normalized)\"")], ["text": .code(normalized)])])
            }
            if let first = seenTags[normalized] {
                report(.duplicateLanguage, tagRange, ["tag": .code(tag)], notes: [note("otherCopy", first)])
                continue
            }
            seenTags[normalized] = tagRange
            var seenKeys: [String: Range<Int>] = [:]
            var table: [String: String] = [:]
            for entryNode in group.block.statements {
                guard entryNode.kind == .entry else { continue }
                let entry = EntrySyntax(unchecked: entryNode)
                let keyNode = entry.key
                let key = translationKey(keyNode)
                let keyRange = range(keyNode.node)
                if let first = seenKeys[key] {
                    report(.duplicateTranslation, keyRange, ["key": .code(key), "language": .text(LocalizedText(tag, tag))],
                           notes: [note("otherCopy", first)],
                           fixIts: [fix("removeOne", [edit(entryNode.range.lowerBound..<range(entryNode).upperBound, "")])])
                    continue
                }
                seenKeys[key] = keyRange
                guard let valueString = StringLiteralSyntax(entry.value.node) else { continue }
                table[key] = text(valueString.node)
                if !keys.contains(key) {
                    let suggestion = DidYouMean.suggest(key, candidates: Array(keys))
                    var fixIts: [FixIt] = []
                    if let best = suggestion.names.first { fixIts.append(fix("didYouMean", [edit(keyRange, "\"\(best)\"")], ["text": .code(best)])) }
                    fixIts.append(fix("remove", [edit(entryNode.range.lowerBound..<range(entryNode).upperBound, "")]))
                    report(.unusedTranslation, keyRange, ["key": .code(key)], fixIts: fixIts)
                    continue
                }
                // The same interpolations, in any order, each once (DK8402).
                let original = interpolationKeys(keyNode)
                let translated = interpolationKeys(valueString)
                if original.sorted() != translated.sorted() {
                    let missing = original.filter { o in !translated.contains(o) }.map { DiagnosticArgument.code("{" + $0 + "}") }
                    let extra = translated.filter { t in !original.contains(t) }.map { DiagnosticArgument.code("{" + $0 + "}") }
                    report(.translationDataMismatch, range(valueString.node), ["missing": .list(missing.isEmpty ? extra : missing, joiner: .and)])
                }
            }
            translationTable.languages[normalized] = table
        }
    }

    func interpolationKeys(_ string: StringLiteralSyntax) -> [String] {
        string.segments.compactMap { segment in
            if case .interpolation(let i) = segment { return Checker.canonicalTokens(i.node.tokens.dropFirst().dropLast()) }
            return nil
        }
    }

    static let chineseRegionTags: [String: String] = ["zh-CN": "zh-Hans", "zh-SG": "zh-Hans", "zh-TW": "zh-Hant",
                                                       "zh-HK": "zh-Hant-HK", "zh-MO": "zh-Hant-MO"]

    /// `_` → `-`; Chinese region tags name their script; `zh` → `zh-Hans` (D128).
    static func normalizeLanguageTag(_ tag: String) -> String {
        var t = tag.replacingOccurrences(of: "_", with: "-")
        if let mapped = chineseRegionTags[t] { return mapped }
        if t == "zh" { t = "zh-Hans" }
        return t
    }

    static let commonLanguageTags = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "it", "pt", "pt-BR", "ru", "nl",
                                     "sv", "da", "fi", "nb", "pl", "tr", "cs", "hu", "uk", "ar", "he", "th", "vi", "id", "ms",
                                     "hi", "el", "ro", "sk", "hr", "ca", "en-GB", "en-US", "en-AU", "es-MX", "fr-CA", "zh-Hant-HK"]

    static func isKnownLanguageTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-").map(String.init)
        guard let language = parts.first, (2...3).contains(language.count), language.allSatisfy({ $0.isLowercase && $0.isASCII }) else {
            return false
        }
        let known = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
        guard known.contains(language) else { return false }
        var stage = 0   // 0: script may follow, 1: region may follow, 2: nothing
        let scripts: Set<String> = ["Hans", "Hant", "Latn", "Cyrl", "Arab", "Deva", "Grek", "Hebr", "Jpan", "Kore", "Thai"]
        for part in parts.dropFirst() {
            if stage == 0, part.count == 4, scripts.contains(part) { stage = 1; continue }
            if stage <= 1, part.count == 2, part.allSatisfy({ $0.isUppercase && $0.isASCII }) { stage = 2; continue }
            if stage <= 1, part.count == 3, part.allSatisfy({ $0.isNumber }) { stage = 2; continue }
            return false
        }
        return true
    }
}
