import AppKit
import DeskLanguage

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
    private let radius: Radius

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
        radius = Self.radius(snapshot: snapshot, facts: facts, call: call)
    }

    var page: StudioPage {
        let language: DiagnosticLanguage = StudioText.language == .chinese ? .simplifiedChinese : .english
        let component = snapshot.options.catalog.component(named: facts.component)?.title.text(in: language)
            ?? facts.component
        let subtitle = facts.component == "Rectangle" ? StudioText.format(.subtitleKind, StudioText[.kindShape]) : component
        var page = StudioPage(id: "desk-element:\(element)", title: facts.name ?? component, subtitle: subtitle)
        var items: [StudioPage.Item] = []
        switch radius {
        case .number(let value, _):
            page.scope = .init(text: StudioText.format(.scopeOnly, StudioText[.nounShape]), link: nil)
            let row = StudioPage.Row(label: StudioText[.rowCorners], control: .number(.init(
                text: StudioNumberInput.text(value), value: value,
                unit: StudioText.language == .chinese ? "点" : "pt", defaultText: "0", width: 64, minimum: 0)))
            items.append(.init(id: "desk.corners", kind: .row(row)))
        case .readOnly(let written, let reason, let source):
            if facts.component == "Rectangle" {
                let row = StudioPage.Row(label: StudioText[.rowCorners], control: .text(written), source: source,
                                         detail: StudioText[reason], tooltip: written)
                items.append(.init(id: "desk.corners", kind: .row(row)))
            }
            let reasonText = StudioText[reason]
            let text = reason == .deskInspectorReadOnly ? reasonText
                : reasonText + " · " + StudioText[.deskInspectorReadOnly]
            items.append(.init(id: "desk.corners.source", kind: .note(.init(
                text: text, link: StudioText[.showInCode], symbol: source?.symbol ?? "chevron.left.forwardslash.chevron.right"))))
        }
        page.sections = [.init(id: "desk.shape", title: StudioText[.sectionShape], items: items)]
        page.footer = [.init(id: "show-in-code", title: StudioText[.showInCode],
                             symbol: "chevron.left.forwardslash.chevron.right")]
        return page
    }

    func operation(for event: StudioPageEvent) -> Operation? {
        switch event {
        case .link("show-in-code"), .noteLink(item: "desk.corners.source"):
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
            let result = Desk.apply(edit, to: snapshot.checked, catalog: snapshot.options.catalog)
            guard result.failure == nil, !result.edits.isEmpty,
                  !result.diagnostics.contains(where: { $0.severity == .error }),
                  result.edits.allSatisfy({ $0.file == snapshot.file }),
                  let workspace = snapshot.workspaceEdit(result.edits), !workspace.isEmpty else {
                return .rejected(StudioText[.deskInspectorEditRejected])
            }
            return .edit(workspace, actionName: StudioText[.rowCorners])
        default:
            return nil
        }
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
