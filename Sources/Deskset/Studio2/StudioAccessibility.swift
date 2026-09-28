import AppKit
import DesksetCore

/// What the Studio says to VoiceOver: opening, each change, each undo and redo by name, a change of scope. Posted as
/// announcements of high priority on screen; kept (the last few) so the self-tests can read them.
enum StudioAnnouncer {
    /// What was announced, newest last (the last 50).
    private(set) static var recorded: [String] = []

    static func announce(_ text: String, in window: NSWindow?, posts: Bool) {
        guard !text.isEmpty else { return }
        recorded.append(text)
        if recorded.count > 50 { recorded.removeFirst(recorded.count - 50) }
        guard posts, let element = window?.contentView ?? window else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    static func clear() { recorded = [] }
}

extension StudioWindowController {
    /// Says `text` to VoiceOver.
    func announce(_ text: String) {
        StudioAnnouncer.announce(text, in: window, posts: app.presentsWindows)
    }
}

/// A part of the widget on the canvas as VoiceOver sees it: named as the Studio names it everywhere ("CPU usage"), with
/// its kind, its live value and its place; pressing it selects it; its custom actions are Show in Code, Bring Forward,
/// Send Backward and Delete.
final class StudioPartElement: NSAccessibilityElement {
    let name: String
    weak var owner: StudioCanvasAccessibility?
    var label = ""
    var value: String?
    var kind = ""
    var problem: String?

    init(name: String, owner: StudioCanvasAccessibility) {
        self.name = name
        self.owner = owner
        super.init()
    }

    override func accessibilityFrame() -> NSRect {
        owner?.screenFrame(of: name) ?? .zero
    }

    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityRoleDescription() -> String? { kind }
    override func accessibilityHelp() -> String? { problem }
    override func accessibilityParent() -> Any? { owner?.widgetElement }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilitySelected() -> Bool {
        owner?.window?.canvasController.canvas.selectedNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            ?? false
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.window?.select(part: name)
        return true
    }
}

/// The widget itself on the canvas: a group named after it, holding its parts in drawing order (back to front), as
/// the Layers list does.
final class StudioWidgetElement: NSAccessibilityElement {
    weak var owner: StudioCanvasAccessibility?
    var label = ""
    var parts: [StudioPartElement] = []

    override func accessibilityFrame() -> NSRect { owner?.widgetScreenFrame() ?? .zero }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityChildren() -> [Any]? { parts }
    override func accessibilityParent() -> Any? { owner?.window?.canvasController.canvas }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        owner?.window?.select(part: nil)
        return true
    }
}

/// The canvas's accessibility: one element per part (made from the Studio's instance whenever the widget changes),
/// inside one for the widget; the Layers and Problems rotors; the parts' custom actions.
final class StudioCanvasAccessibility: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
    weak var window: StudioWindowController?
    let widgetElement = StudioWidgetElement()
    private(set) var parts: [StudioPartElement] = []
    private(set) var layersRotor: NSAccessibilityCustomRotor!
    private(set) var problemsRotor: NSAccessibilityCustomRotor!

    init(window: StudioWindowController) {
        self.window = window
        super.init()
        widgetElement.owner = self
        widgetElement.setAccessibilityRole(.group)
        layersRotor = NSAccessibilityCustomRotor(label: StudioText[.tabLayers], itemSearchDelegate: self)
        problemsRotor = NSAccessibilityCustomRotor(label: StudioText[.rotorProblems], itemSearchDelegate: self)
    }

    /// The elements again, from the Studio's instance of the widget.
    func rebuild() {
        guard let window, let skin = window.skin else {
            parts = []
            widgetElement.parts = []
            return
        }
        let canvas = window.canvasController.canvas
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.group)
        canvas.setAccessibilityLabel(StudioText[.canvas])
        widgetElement.label = StudioText.format(.axWidget, window.widgetName)
        let old = Dictionary(parts.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var elements: [StudioPartElement] = []
        LayerNaming.sharingWork(for: skin) {
            let names = LayerNaming.catalog(of: skin)
            for m in skin.meters where !m.hidden {
                let e = old[m.name.lowercased()] ?? StudioPartElement(name: m.name, owner: self)
                e.label = StudioPartNames.title(m, in: skin, names: names)
                e.kind = StudioPartNames.role(m)
                e.setAccessibilityRole(Self.role(m))
                let issues = StudioPartIssues.issues(of: m, in: skin)
                e.problem = StudioPartNames.issueSentence(issues, in: skin, names: names)
                if let data = StudioPartNames.shownData(m, in: skin),
                   !issues.contains(where: { if case .windowsData = $0 { return true } else { return false } }) {
                    e.value = StudioPartNames.value(m, data: data, in: skin)
                } else {
                    e.value = e.problem == nil ? nil : "0"
                }
                e.setAccessibilityCustomActions(actions(for: m.name))
                elements.append(e)
            }
        }
        parts = elements
        widgetElement.parts = elements
        canvas.setAccessibilityChildren([widgetElement])
        canvas.setAccessibilityCustomRotors([layersRotor, problemsRotor])
    }

    /// The live values again (the elements stay).
    func refreshValues() {
        guard let window, let skin = window.skin else { return }
        for e in parts {
            guard let m = skin.meter(named: e.name), e.problem == nil,
                  let data = StudioPartNames.shownData(m, in: skin) else { continue }
            e.value = StudioPartNames.value(m, data: data, in: skin)
        }
    }

    static func role(_ m: Meter) -> NSAccessibility.Role {
        if StudioPartNames.isButton(m) { return .button }
        switch StudioPartKind(m) {
        case .number, .text: return .staticText
        case .bar: return .progressIndicator
        case .ring: return .levelIndicator
        case .graph, .symbol, .picture, .shape, .part: return .image
        }
    }

    func actions(for name: String) -> [NSAccessibilityCustomAction] {
        [
            NSAccessibilityCustomAction(name: StudioText[.showInCode]) { [weak self] in
                self?.window?.select(part: name)
                self?.window?.showInCode(nil)
                return true
            },
            NSAccessibilityCustomAction(name: StudioText[.axBringForward]) { [weak self] in
                self?.window?.bringForward(name) ?? false
            },
            NSAccessibilityCustomAction(name: StudioText[.axSendBackward]) { [weak self] in
                self?.window?.sendBackward(name) ?? false
            },
            NSAccessibilityCustomAction(name: StudioText[.axDelete]) { [weak self] in
                self?.window?.delete(part: name) ?? false
            },
        ]
    }

    // MARK: Frames

    func screenFrame(of name: String) -> NSRect {
        guard let window, let m = window.skin?.meter(named: name) else { return .zero }
        let canvas = window.canvasController.canvas
        guard canvas.window != nil else { return canvas.viewRect(m.frame) }
        return NSAccessibility.screenRect(fromView: canvas, rect: canvas.viewRect(m.frame))
    }

    func widgetScreenFrame() -> NSRect {
        guard let window else { return .zero }
        let canvas = window.canvasController.canvas
        guard canvas.window != nil else { return canvas.skinRect }
        return NSAccessibility.screenRect(fromView: canvas, rect: canvas.skinRect)
    }

    // MARK: Rotors

    /// The elements a rotor goes through: every part (Layers), the parts that need attention (Problems).
    func items(of rotor: NSAccessibilityCustomRotor) -> [StudioPartElement] {
        rotor === problemsRotor ? parts.filter { $0.problem != nil } : parts
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters)
        -> NSAccessibilityCustomRotor.ItemResult? {
        let list = items(of: rotor)
        guard !list.isEmpty else { return nil }
        let current = searchParameters.currentItem?.targetElement as? StudioPartElement
        let i = current.flatMap { c in list.firstIndex { $0 === c } }
        let next: Int
        switch searchParameters.searchDirection {
        case .next: next = i.map { $0 + 1 } ?? 0
        case .previous: next = i.map { $0 - 1 } ?? list.count - 1
        @unknown default: next = 0
        }
        guard list.indices.contains(next) else { return nil }
        // The element answers every message of the protocol (frame, parent); Swift cannot declare it, because
        // NSAccessibilityElement's `accessibilityIdentifier()` has another optionality than the protocol's.
        let target = unsafeBitCast(list[next] as AnyObject, to: NSAccessibilityElementProtocol.self)
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: target)
        result.customLabel = list[next].label
        return result
    }

    // MARK: The tree, for the self-tests

    /// The canvas's accessibility tree as lines: two spaces of indent per level, then the role, the label, the value
    /// and the custom actions ("  AXStaticText “CPU usage” = 23% [Show in Code, Bring Forward, …]").
    static func export(_ element: Any, depth: Int = 0, limit: Int = 6) -> [String] {
        guard depth <= limit else { return [] }
        var line = String(repeating: "  ", count: depth)
        var role = "", label = "", value = "", actions: [String] = [], children: [Any] = []
        if let e = element as? NSAccessibilityElement {
            role = e.accessibilityRole()?.rawValue ?? ""
            label = e.accessibilityLabel() ?? ""
            value = (e.accessibilityValue() as? String) ?? ""
            actions = (e.accessibilityCustomActions() ?? []).map(\.name)
            children = e.accessibilityChildren() ?? []
        } else if let v = element as? NSView {
            role = v.accessibilityRole()?.rawValue ?? ""
            label = v.accessibilityLabel() ?? ""
            value = (v.accessibilityValue() as? String) ?? ""
            actions = (v.accessibilityCustomActions() ?? []).map(\.name)
            children = v.accessibilityChildren() ?? []
        }
        line += role
        if !label.isEmpty { line += " “\(label)”" }
        if !value.isEmpty { line += " = \(value)" }
        if !actions.isEmpty { line += " [\(actions.joined(separator: ", "))]" }
        return [line] + children.flatMap { export($0, depth: depth + 1, limit: limit) }
    }
}
