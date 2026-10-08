import AppKit
import DeskLanguage
import DesksetCore

/// One checked element's property page. The window validates this snapshot before applying an operation.
/// This adapter only plans edits; it owns neither the editor nor files on disk.
struct DeskElementInspector {
    enum Operation {
        case showInCode(DeskRange)
        case edit(DeskWorkspaceEdit, actionName: String)
        case rejected(String)
    }

    let snapshot: DeskSnapshot
    let element: ElementRef
    private let hit: DeskElementHit
    private let facts: ElementFacts
    private let call: CallStmtSyntax
    private let radius: Radius

    private enum Target {
        case argument(ArgumentRef)
        case square(ModifierRef, axis: String)
        case modifier(String, label: String?)
        case addArgument(ModifierRef, label: String)
    }

    private enum Scalar {
        case number(Double, Target)
        case choice(String, Target)
        case readOnly(String, reason: StudioText.Key, source: StudioValueSource?)
    }

    private enum Radius {
        /// Nil argument means the element has no rounding modifier yet.
        case number(Double, argument: ArgumentRef?)
        case readOnly(String, reason: StudioText.Key, source: StudioValueSource?)
    }

    init?(snapshot: DeskSnapshot, element: ElementRef) {
        guard snapshot.isChecked, snapshot.checked.tree.version == snapshot.tree.version,
              let hit = snapshot.range(of: element), hit.callRange.length > 0,
              let facts = snapshot.checked.elements[element], let node = snapshot.tree.resolve(element),
              let call = CallStmtSyntax(node), !call.textRange.isEmpty else { return nil }
        self.snapshot = snapshot
        self.element = element
        self.hit = hit
        self.facts = facts
        self.call = call
        radius = Self.radius(snapshot: snapshot, facts: facts, call: call)
    }

    var page: StudioPage {
        let language: DiagnosticLanguage = StudioText.language == .chinese ? .simplifiedChinese : .english
        let component = snapshot.options.catalog.component(named: facts.component)?.title.text(in: language)
            ?? facts.component
        let subtitle = facts.component == "Rectangle" ? StudioText.format(.subtitleKind, StudioText[.kindShape]) : component
        var page = StudioPage(id: "desk-element:\(element)", title: facts.name ?? component, subtitle: subtitle)
        var items: [StudioPage.Item] = []
        var sections: [StudioPage.Section] = []
        if facts.component == "Text" {
            var textItems = contentItems()
            textItems += scalarItems(fontSize(), id: "desk.text.size", label: StudioText[.rowTextSize], minimum: 0)
            sections.append(.init(id: "desk.text", title: StudioText[.sectionText], items: textItems))
        }
        if facts.component == "Rectangle" {
            switch radius {
            case .number(let value, _):
                let row = StudioPage.Row(label: StudioText[.rowCorners], control: .number(.init(
                    text: StudioNumberInput.text(value), value: value,
                    unit: StudioText.language == .chinese ? "点" : "pt", defaultText: "0", width: 64, minimum: 0)))
                items.append(.init(id: "desk.corners", kind: .row(row)))
            case .readOnly(let written, let reason, let source):
                let row = StudioPage.Row(label: StudioText[.rowCorners], control: .text(written), source: source,
                                         detail: StudioText[reason], tooltip: written)
                items.append(.init(id: "desk.corners", kind: .row(row)))
                let reasonText = StudioText[reason]
                let text = reason == .deskInspectorReadOnly ? reasonText
                    : reasonText + " · " + StudioText[.deskInspectorReadOnly]
                items.append(.init(id: "desk.corners.source", kind: .note(.init(
                    text: text, link: StudioText[.showInCode], symbol: source?.symbol ?? "chevron.left.forwardslash.chevron.right"))))
            }
            sections.append(.init(id: "desk.shape", title: StudioText[.sectionShape], items: items))
        }
        var layoutItems: [StudioPage.Item] = []
        for axis in ["width", "height"] {
            let label = axis == "width" ? StudioText[.deskInspectorWidth] : StudioText[.deskInspectorHeight]
            layoutItems += scalarItems(dimension(axis), id: "desk.\(axis)", label: label, minimum: 0, sizing: true)
        }
        if isFreeformChild {
            for axis in ["x", "y"] {
                layoutItems += scalarItems(position(axis), id: "desk.position.\(axis)",
                                           label: StudioText[axis == "x" ? .rowX : .rowY], minimum: nil)
            }
        }
        sections.append(.init(id: "desk.layout", title: StudioText[.sectionLayout], items: layoutItems))
        page.sections = sections
        if page.controlCount > 0 {
            let noun: StudioText.Key = facts.component == "Text" ? .nounText
                : ["Rectangle", "Circle", "Ellipse", "Capsule"].contains(facts.component) ? .nounShape : .nounPart
            page.scope = .init(text: StudioText.format(.scopeOnly, StudioText[noun]), link: nil)
        }
        page.footer = [.init(id: "show-in-code", title: StudioText[.showInCode],
                             symbol: "chevron.left.forwardslash.chevron.right")]
        return page
    }

    func operation(for event: StudioPageEvent) -> Operation? {
        switch event {
        case .link("show-in-code"):
            return .showInCode(hit.callRange)
        case .noteLink(let item) where page.item(item) != nil && item.hasSuffix(".source"):
            return .showInCode(hit.callRange)
        case .number(let item, let part, let change) where item == "desk.corners" && part == 0:
            guard case .number(let current, let argument) = radius else {
                return .rejected(StudioText[.deskInspectorReadOnly])
            }
            let target: Double?
            switch change {
            case .drag(let delta, let done):
                guard done else { return nil }
                target = current + delta
            case .typed(let text): target = StudioNumberInput.evaluate(text)
            case .step(let delta): target = current + delta
            case .reset: target = 0
            case .textStep: return nil
            }
            guard let target, target.isFinite, target >= 0 else {
                return .rejected(StudioText[.deskInspectorInvalidRadius])
            }
            guard target != current else { return nil }
            let text = StudioNumberInput.text(target)
            let edit: DeskEdit = argument.map { .syntax(.setArgument($0, newText: text)) }
                ?? .setModifier(element, name: "rounded", argumentsText: text, condition: nil)
            return planned(edit, actionName: StudioText[.rowCorners])
        case .number("desk.text.content", 0, .typed(let text)):
            guard let argument = textArgument, let literal = StringLiteralSyntax(argument.value.node),
                  let current = literal.literalValue, !literal.isRaw, !literal.isTripleQuoted, propertyIsSafe([]) else {
                return .rejected(StudioText[.deskInspectorReadOnly])
            }
            guard text.utf16.count <= ProgramLimits.maximumTextLength else {
                return .rejected(StudioText[.deskInspectorInvalidText])
            }
            guard text != current else { return nil }
            let encoded = Self.stringLiteral(text)
            // Read the encoded value back through the real parser before proposing an edit.
            let tree = Desk.parse("widget { Text(\(encoded)) }", file: snapshot.file)
            guard !tree.diagnostics.contains(where: { $0.severity == .error }),
                  let widget = tree.rootNode.firstChild(.widgetBlock), let block = widget.firstChild(.block),
                  let node = block.children(.callStmt).first, let testCall = CallStmtSyntax(node),
                  let value = testCall.arguments?.arguments.first?.value.node,
                  StringLiteralSyntax(value)?.literalValue == text else {
                return .rejected(StudioText[.deskInspectorInvalidText])
            }
            return planned(.syntax(.setArgument(snapshot.tree.id(of: argument.node), newText: encoded)),
                           actionName: StudioText[.sectionText])
        case .number(let item, 0, let change):
            let scalar: Scalar
            let label: String
            let minimum: Double?
            let positive: Bool
            switch item {
            case "desk.width", "desk.height":
                let axis = item == "desk.width" ? "width" : "height"
                scalar = dimension(axis); label = StudioText[axis == "width" ? .deskInspectorWidth : .deskInspectorHeight]
                minimum = 0; positive = false
            case "desk.position.x", "desk.position.y":
                let axis = item == "desk.position.x" ? "x" : "y"
                guard isFreeformChild else { return nil }
                scalar = position(axis); label = StudioText[.undoPosition]; minimum = nil; positive = false
            case "desk.text.size":
                guard facts.component == "Text" else { return nil }
                scalar = fontSize(); label = StudioText[.rowTextSize]; minimum = 0; positive = true
            default: return nil
            }
            return numberOperation(scalar, change: change, minimum: minimum, positive: positive, actionName: label)
        case .choose(let item, let index) where item == "desk.width.mode" || item == "desk.height.mode":
            let axis = item == "desk.width.mode" ? "width" : "height"
            let value = dimension(axis)
            let target: Target
            switch value {
            case .number(_, let edit), .choice(_, let edit): target = edit
            case .readOnly: return .rejected(StudioText[.deskInspectorReadOnly])
            }
            // A fixed value is entered in the adjacent number field, never guessed from a fit/fill scene.
            guard index == 1 || index == 2 else { return nil }
            let choice = index == 1 ? "fit" : "fill"
            if case .choice(let currentChoice, _) = value, currentChoice == choice { return nil }
            return planned(target, text: "." + choice,
                           actionName: StudioText[axis == "width" ? .deskInspectorWidth : .deskInspectorHeight])
        default:
            return nil
        }
    }

    private var isFreeformChild: Bool {
        guard let parent = facts.parent, snapshot.checked.elements[parent]?.component == "Freeform",
              let node = snapshot.tree.resolve(parent), let parentCall = CallStmtSyntax(node) else { return false }
        return parentCall.block?.items.contains(where: { snapshot.tree.id(of: $0) == element }) == true
    }

    private var textArgument: ArgumentSyntax? {
        guard facts.component == "Text", call.block == nil, let arguments = call.arguments?.arguments,
              arguments.count == 1, arguments[0].label == nil, !arguments[0].value.isMissing,
              !arguments[0].value.textRange.isEmpty else { return nil }
        return arguments[0]
    }

    private func propertyIsSafe(_ candidates: [Candidate]) -> Bool {
        guard ["Text", "Column", "Row", "Freeform", "Rectangle", "Circle", "Ellipse", "Capsule", "Image"].contains(facts.component),
              !facts.insideIf, !facts.insideFor, facts.dropped.isEmpty,
              !candidates.contains(where: { $0.condition != nil }) else { return false }
        return !snapshot.checked.diagnostics.contains { diagnostic in
            diagnostic.file == snapshot.file && diagnostic.severity == .error
                && (diagnostic.range.overlaps(call.textRange)
                    || diagnostic.range.isEmpty && call.textRange.lowerBound <= diagnostic.range.lowerBound
                        && diagnostic.range.lowerBound <= call.textRange.upperBound)
        }
    }

    private func source(_ candidates: [Candidate], value: NodeID? = nil) -> StudioValueSource? {
        if candidates.contains(where: { if case .style = $0.origin { return true }; return false }) { return .style }
        if facts.insideIf || facts.insideFor || candidates.contains(where: { $0.condition != nil }) { return .rule }
        var dependencies = candidates.reduce(into: Set<DepKey>()) { $0.formUnion(snapshot.checked.dependencies[$1.value] ?? []) }
        if let value { dependencies.formUnion(snapshot.checked.dependencies[value] ?? []) }
        if dependencies.contains(where: { if case .option = $0 { return true }; return false }) { return .option }
        return dependencies.isEmpty ? nil : .live
    }

    private func readOnly(_ candidates: [Candidate], written: String? = nil,
                          reason: StudioText.Key = .deskInspectorReadOnly) -> Scalar {
        let actualReason = facts.insideIf || facts.insideFor || candidates.contains(where: { $0.condition != nil })
            ? StudioText.Key.deskInspectorConditional : reason
        return .readOnly(written ?? candidates.first.flatMap { Self.candidateText($0, snapshot: snapshot) }
                         ?? StudioText[.deskInspectorUnavailable], reason: actualReason, source: source(candidates))
    }

    private func dimension(_ axis: String) -> Scalar {
        let candidates = facts.facets[FacetID(axis)] ?? []
        guard propertyIsSafe(candidates) else { return readOnly(candidates, reason: .deskInspectorUnavailable) }
        if facts.isRoot,
           let info = snapshot.tree.rootNode.children(.infoBlock).first.flatMap(TopLevelBlockSyntax.init),
           let size = info.block.items.compactMap(FieldSyntax.init).first(where: { $0.label.name == "size" }),
           let preset = ImplicitMemberExprSyntax(size.value.node), preset.name.token.text != "fit" {
            return readOnly(candidates, written: size.node.node.trimmedText, reason: .deskInspectorPresetSize)
        }
        if candidates.isEmpty {
            let defaults = snapshot.options.catalog.component(named: facts.component)?.sizing
            let written = axis == "width" ? defaults?.width : defaults?.height
            guard let written else { return readOnly(candidates, reason: .deskInspectorUnsupported) }
            let target = Target.modifier(axis, label: nil)
            if written == ".fit" || written == ".fill" { return .choice(String(written.dropFirst()), target) }
            if let number = Double(written), number.isFinite, number >= 0 { return .number(number, target) }
            return readOnly(candidates, written: written)
        }
        guard candidates.count == 1, let candidate = candidates.first,
              let binding = ownArgument(candidate) else { return readOnly(candidates) }
        let target: Target
        if binding.modifier.name.token.text == "size", binding.modifier.arguments?.arguments.count == 1 {
            target = .square(snapshot.tree.id(of: binding.modifier.node), axis: axis)
        } else { target = .argument(snapshot.tree.id(of: binding.argument.node)) }
        if let choice = ImplicitMemberExprSyntax(binding.argument.value.node), choice.arguments == nil,
           ["fit", "fill"].contains(choice.name.token.text) { return .choice(choice.name.token.text, target) }
        guard let number = checkedNumber(binding.argument.value.node), number >= 0 else {
            return readOnly(candidates, reason: .deskInspectorExpression)
        }
        return .number(number, target)
    }

    private func fontSize() -> Scalar {
        let candidates = facts.facets["font.size"] ?? []
        guard facts.component == "Text", propertyIsSafe(candidates) else { return readOnly(candidates, reason: .deskInspectorUnavailable) }
        guard !candidates.isEmpty else {
            return readOnly(candidates, written: StudioText[.deskInspectorInherited], reason: .deskInspectorReadOnly)
        }
        if candidates.contains(where: { $0.fixedValue != nil }) { return readOnly(candidates, reason: .deskInspectorFontPreset) }
        guard candidates.count == 1, let candidate = candidates.first, let binding = ownArgument(candidate),
              binding.modifier.name.token.text == "font", let number = checkedNumber(binding.argument.value.node), number > 0 else {
            return readOnly(candidates, reason: .deskInspectorExpression)
        }
        return .number(number, .argument(snapshot.tree.id(of: binding.argument.node)))
    }

    private func position(_ axis: String) -> Scalar {
        let candidates = facts.facets[FacetID("position." + axis)] ?? []
        let modifiers = call.modifiers.filter { $0.name.token.text == "position" }
        guard isFreeformChild, propertyIsSafe(candidates) else { return readOnly(candidates, reason: .deskInspectorUnavailable) }
        guard modifiers.count == 1, let modifier = modifiers.first, modifier.block == nil else {
            return readOnly(candidates, written: StudioText[.deskInspectorContainerAligned], reason: .deskInspectorReadOnly)
        }
        if candidates.isEmpty, !(modifier.arguments?.arguments ?? []).contains(where: { $0.label?.name == axis }) {
            return .number(0, .addArgument(snapshot.tree.id(of: modifier.node), label: axis))
        }
        guard candidates.count == 1, let candidate = candidates.first, let binding = ownArgument(candidate),
              binding.modifier.name.token.text == "position", binding.argument.label?.name == axis,
              let number = checkedNumber(binding.argument.value.node) else {
            return readOnly(candidates, reason: .deskInspectorExpression)
        }
        return .number(number, .argument(snapshot.tree.id(of: binding.argument.node)))
    }

    private func ownArgument(_ candidate: Candidate) -> (modifier: ModifierAppSyntax, argument: ArgumentSyntax)? {
        guard candidate.condition == nil, candidate.fixedValue == nil, case .own(let id) = candidate.origin,
              let modifier = call.modifiers.first(where: { snapshot.tree.id(of: $0.node) == id }), modifier.block == nil,
              let argument = modifier.arguments?.arguments.first(where: { snapshot.tree.id(of: $0.value.node) == candidate.value }),
              !argument.value.isMissing, !argument.value.textRange.isEmpty else { return nil }
        return (modifier, argument)
    }

    private func checkedNumber(_ node: PositionedNode) -> Double? {
        let literal: NumberLiteralSyntax?
        if let prefix = PrefixExprSyntax(node), prefix.operator.kind == .minus { literal = NumberLiteralSyntax(prefix.operand.node) }
        else { literal = NumberLiteralSyntax(node) }
        let type = snapshot.checked.types[snapshot.tree.id(of: node)]?.type
        guard let literal, literal.value?.isFinite == true, literal.unitAfterSpace == nil,
              literal.unit == nil || literal.unit?.text == "pt" && literal.unit?.status == .known,
              literal.unit == nil ? type == .plainNumber || type == .length : type == .length,
              let number = snapshot.checked.canonicalNumericValues[snapshot.tree.id(of: node)], number.isFinite else { return nil }
        return number
    }

    private func scalarItems(_ value: Scalar, id: String, label: String, minimum: Double?, sizing: Bool = false) -> [StudioPage.Item] {
        switch value {
        case .readOnly(let written, let reason, let source):
            return [.init(id: id, kind: .row(.init(label: label, control: .text(written), source: source,
                                                  detail: StudioText[reason], tooltip: written))),
                    .init(id: id + ".source", kind: .note(.init(text: StudioText[reason], link: StudioText[.showInCode],
                                                              symbol: source?.symbol ?? "chevron.left.forwardslash.chevron.right")))]
        case .number, .choice:
            let number: Double?
            let choice: String?
            if case .number(let n, _) = value { number = n; choice = nil }
            else if case .choice(let name, _) = value { number = nil; choice = name }
            else { return [] }
            var items: [StudioPage.Item] = [.init(id: id, kind: .row(.init(label: label, control: .number(.init(
                text: number.map(StudioNumberInput.text) ?? "", value: number, unit: StudioText.language == .chinese ? "点" : "pt",
                placeholder: choice == "fit" ? StudioText[.fit] : choice == "fill" ? StudioText[.deskInspectorFill] : "",
                width: 72, minimum: minimum)))))]
            if sizing {
                let popup = StudioPage.Popup(
                    items: [.init(title: StudioText[.deskInspectorFixed], enabled: number != nil),
                            .init(title: StudioText[.fit]), .init(title: StudioText[.deskInspectorFill])],
                    selected: choice == "fit" ? 1 : choice == "fill" ? 2 : 0)
                items.append(.init(id: id + ".mode", kind: .row(.init(
                    label: StudioText[.deskInspectorSizing], control: .popup(popup)))))
            }
            return items
        }
    }

    private func contentItems() -> [StudioPage.Item] {
        if let argument = textArgument, propertyIsSafe([]), let literal = StringLiteralSyntax(argument.value.node),
           !literal.isRaw, !literal.isTripleQuoted, let text = literal.literalValue {
            return [.init(id: "desk.text.content", kind: .row(.init(label: StudioText[.sectionText],
                control: .number(.init(text: text, value: nil, isText: true)))))]
        }
        let value = textArgument?.value.node
        let written = value?.node.trimmedText ?? call.node.node.trimmedText
        let key: StudioText.Key = facts.insideIf || facts.insideFor ? .deskInspectorConditional : .deskInspectorExpression
        let origin = source([], value: value.map { snapshot.tree.id(of: $0) })
        return [.init(id: "desk.text.content", kind: .row(.init(label: StudioText[.sectionText], control: .text(written),
                                                              source: origin, detail: StudioText[key], tooltip: written))),
                .init(id: "desk.text.content.source", kind: .note(.init(text: StudioText[key], link: StudioText[.showInCode],
                                                                      symbol: origin?.symbol ?? "chevron.left.forwardslash.chevron.right")))]
    }

    private func numberOperation(_ value: Scalar, change: StudioNumberChange, minimum: Double?, positive: Bool,
                                 actionName: String) -> Operation? {
        let current: Double?
        let target: Target
        switch value {
        case .number(let n, let edit): current = n; target = edit
        case .choice(_, let edit): current = nil; target = edit
        case .readOnly: return .rejected(StudioText[.deskInspectorReadOnly])
        }
        let number: Double?
        switch change {
        case .typed(let text): number = StudioNumberInput.evaluate(text)
        case .step(let delta): number = current.map { $0 + delta }
        case .drag(let delta, let done):
            guard done else { return nil }; number = current.map { $0 + delta }
        case .reset, .textStep: return nil
        }
        guard let number, number.isFinite, minimum.map({ number >= $0 }) ?? true, !positive || number > 0 else {
            return .rejected(StudioText[positive ? .deskInspectorInvalidFontSize : minimum == nil ? .deskInspectorInvalidPosition : .deskInspectorInvalidSize])
        }
        guard number != current else { return nil }
        var text = StudioNumberInput.text(number)
        let argument: ArgumentSyntax?
        switch target {
        case .argument(let id): argument = snapshot.tree.resolve(id).flatMap(ArgumentSyntax.init)
        case .square(let id, _): argument = snapshot.tree.resolve(id).flatMap(ModifierAppSyntax.init)?.arguments?.arguments.first
        default: argument = nil
        }
        if let argument {
            let value = argument.value.node
            let literal = NumberLiteralSyntax(value) ?? PrefixExprSyntax(value).flatMap { NumberLiteralSyntax($0.operand.node) }
            if literal?.unit?.text == "pt" { text += "pt" }
        }
        return planned(target, text: text, actionName: actionName)
    }

    private func planned(_ target: Target, text: String, actionName: String) -> Operation {
        switch target {
        case .argument(let ref): return planned(.syntax(.setArgument(ref, newText: text)), actionName: actionName)
        case .modifier(let name, let label):
            return planned(.setModifier(element, name: name, argumentsText: label.map { $0 + ": " + text } ?? text, condition: nil), actionName: actionName)
        case .addArgument(let ref, let label):
            guard let node = snapshot.tree.resolve(ref), let modifier = ModifierAppSyntax(node), let clause = modifier.arguments,
                  !clause.lParen.token.isMissing, !clause.rParen.token.isMissing,
                  let inner = sourceText(clause.lParen.textRange.upperBound..<clause.rParen.textRange.lowerBound) else {
                return .rejected(StudioText[.deskInspectorEditRejected])
            }
            // Prefixing preserves even a final line comment and a trailing comma in the old clause.
            let arguments = label + ": " + text + (clause.arguments.isEmpty ? "" : ", ") + inner
            return planned(.setModifier(element, name: modifier.name.token.text, argumentsText: arguments, condition: nil), actionName: actionName)
        case .square(let ref, let axis):
            guard let node = snapshot.tree.resolve(ref), let modifier = ModifierAppSyntax(node), let clause = modifier.arguments,
                  clause.arguments.count == 1, clause.arguments[0].label == nil,
                  !clause.lParen.token.isMissing, !clause.rParen.token.isMissing,
                  let inner = sourceText(clause.lParen.textRange.upperBound..<clause.rParen.textRange.lowerBound) else {
                return .rejected(StudioText[.deskInspectorEditRejected])
            }
            let arguments: String
            if axis == "width" { arguments = text + ", " + inner }
            else if let comma = clause.node.childTokens.last(where: { $0.kind == .comma }) {
                guard let before = sourceText(clause.lParen.textRange.upperBound..<comma.textRange.upperBound),
                      let after = sourceText(comma.textRange.upperBound..<clause.rParen.textRange.lowerBound) else {
                    return .rejected(StudioText[.deskInspectorEditRejected])
                }
                arguments = before + " " + text + "," + after
            } else { arguments = inner + ", " + text }
            return planned(.setModifier(element, name: "size", argumentsText: arguments, condition: nil), actionName: actionName)
        }
    }

    private func sourceText(_ range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= snapshot.text.utf8.count,
              let lower = snapshot.text.utf8.index(snapshot.text.utf8.startIndex, offsetBy: range.lowerBound, limitedBy: snapshot.text.utf8.endIndex),
              let upper = snapshot.text.utf8.index(snapshot.text.utf8.startIndex, offsetBy: range.upperBound, limitedBy: snapshot.text.utf8.endIndex),
              let start = lower.samePosition(in: snapshot.text), let end = upper.samePosition(in: snapshot.text) else { return nil }
        return String(snapshot.text[start..<end])
    }

    private func planned(_ edit: DeskEdit, actionName: String) -> Operation {
        let result = Desk.apply(edit, to: snapshot.checked, catalog: snapshot.options.catalog)
        guard result.failure == nil, !result.edits.isEmpty, !result.diagnostics.contains(where: { $0.severity == .error }),
              result.edits.allSatisfy({ $0.file == snapshot.file }),
              let workspace = snapshot.workspaceEdit(result.edits), !workspace.isEmpty else {
            return .rejected(StudioText[.deskInspectorEditRejected])
        }
        return .edit(workspace, actionName: actionName)
    }

    private static func stringLiteral(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\u{D}"
            case "\t": result += "\\t"
            case "{": result += "{{"
            case "}": result += "}}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static let cornerFacets: [FacetID] = ["rounded.topLeft", "rounded.topRight", "rounded.bottomLeft", "rounded.bottomRight"]

    private static func radius(snapshot: DeskSnapshot, facts: ElementFacts, call: CallStmtSyntax) -> Radius {
        let lists = cornerFacets.map { facts.facets[$0] ?? [] }
        let candidates = lists.flatMap { $0 }
        let rounded = call.modifiers.filter { $0.name.token.text == "rounded" }
        let written = rounded.first?.node.node.trimmedText
            ?? candidates.first.flatMap { candidateText($0, snapshot: snapshot) } ?? facts.component
        let source: StudioValueSource? = {
            if candidates.contains(where: { if case .style = $0.origin { return true }; return false }) { return .style }
            if facts.insideIf || facts.insideFor || candidates.contains(where: { $0.condition != nil }) { return .rule }
            let dependencies = candidates.reduce(into: Set<DepKey>()) { $0.formUnion(snapshot.checked.dependencies[$1.value] ?? []) }
            if dependencies.contains(where: { if case .option = $0 { return true }; return false }) { return .option }
            return dependencies.isEmpty ? nil : .live
        }()
        func readOnly(_ reason: StudioText.Key) -> Radius { .readOnly(written, reason: reason, source: source) }
        guard facts.component == "Rectangle" else { return readOnly(.deskInspectorUnsupported) }
        guard !facts.insideIf, !facts.insideFor, !candidates.contains(where: { $0.condition != nil }) else {
            return readOnly(.deskInspectorConditional)
        }
        if candidates.contains(where: { if case .style = $0.origin { return true }; return false }) {
            return readOnly(.deskInspectorReadOnly)
        }
        let hasError = snapshot.checked.diagnostics.contains { diagnostic in
            guard diagnostic.file == snapshot.file, diagnostic.severity == .error else { return false }
            return diagnostic.range.overlaps(call.textRange)
                || (diagnostic.range.isEmpty && call.textRange.lowerBound <= diagnostic.range.lowerBound
                    && diagnostic.range.lowerBound <= call.textRange.upperBound)
        }
        guard !hasError, facts.dropped.isEmpty, call.block == nil, (call.arguments?.arguments ?? []).isEmpty else {
            return readOnly(.deskInspectorUnavailable)
        }
        if rounded.isEmpty, candidates.isEmpty { return .number(0, argument: nil) }
        guard rounded.count == 1, let modifier = rounded.first,
              let arguments = modifier.arguments?.arguments, !arguments.isEmpty else {
            return readOnly(.deskInspectorUnavailable)
        }
        guard arguments.count == 1, let argument = arguments.first, argument.label == nil,
              lists.allSatisfy({ $0.count == 1 }), let candidate = lists.first?.first else {
            return readOnly(.deskInspectorMixedCorners)
        }
        let origin = CandidateOrigin.own(snapshot.tree.id(of: modifier.node))
        let valueID = snapshot.tree.id(of: argument.value.node)
        guard lists.allSatisfy({ $0.first?.origin == origin && $0.first?.value == valueID
            && $0.first?.fixedValue == nil }) else { return readOnly(.deskInspectorMixedCorners) }
        if let choice = ImplicitMemberExprSyntax(argument.value.node), choice.name.token.text == "full" {
            return readOnly(.deskInspectorFullRadius)
        }
        guard let number = NumberLiteralSyntax(argument.value.node) else { return readOnly(.deskInspectorExpression) }
        let type = snapshot.checked.types[candidate.value]?.type
        // The radius parameter is Length | RadiusKeyword: an unadorned literal may remain Plain.
        // Written points must still carry the checker's confirmed Length type.
        let numericType = number.unit == nil ? type == .plainNumber || type == .length : type == .length
        guard number.unitAfterSpace == nil, number.unit == nil || (number.unit?.text == "pt" && number.unit?.status == .known),
              numericType,
              let value = snapshot.checked.canonicalNumericValues[candidate.value], value.isFinite, value >= 0 else {
            return readOnly(.deskInspectorUnavailable)
        }
        return .number(value, argument: snapshot.tree.id(of: argument.node))
    }

    private static func candidateText(_ candidate: Candidate, snapshot: DeskSnapshot) -> String? {
        if case .style(let name, _, let file) = candidate.origin { return name + " · " + file.path }
        if case .own(let modifier) = candidate.origin, let node = snapshot.tree.resolve(modifier) { return node.node.trimmedText }
        return candidate.fixedValue ?? snapshot.tree.resolve(candidate.value)?.node.trimmedText
    }
}
