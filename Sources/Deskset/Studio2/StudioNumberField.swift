import AppKit
import DesksetCore

/// What a number field reports: the label dragged (a live preview, then one step on release), a value typed
/// (arithmetic such as `15+2` is worked out by whoever writes it), an arrow key or A− / A+, the label ⌥-clicked.
enum StudioNumberChange: Equatable {
    /// The label is being dragged: `delta` steps from where the drag began; `done` when it is released.
    case drag(delta: Double, done: Bool)
    case typed(String)
    /// ±1 (an arrow key, A− / A+), ±10 with ⇧.
    case step(Double)
    case reset
}

/// The label of a number row, which can be dragged to change the number (the pointer becomes ↔): 2 points of drag
/// are one step, ⇧ makes a step ten. ⌥-clicking it puts the default back.
final class StudioScrubArea: NSView {
    var onChange: ((StudioNumberChange) -> Void)?
    /// While dragging (the row draws its label with ↔).
    var onScrubbing: ((Bool) -> Void)?
    private var start: NSPoint?
    private var lastDelta = 0.0
    static let pointsPerStep: CGFloat = 2

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            onChange?(.reset)
            return
        }
        start = convert(event.locationInWindow, from: nil)
        lastDelta = 0
        onScrubbing?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag(by: p.x - start.x, shift: event.modifierFlags.contains(.shift), done: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag(by: p.x - start.x, shift: event.modifierFlags.contains(.shift), done: true)
        self.start = nil
        onScrubbing?(false)
    }

    /// A drag of `distance` points (also used by the self-tests).
    func drag(by distance: CGFloat, shift: Bool = false, done: Bool) {
        let steps = (Double(distance / Self.pointsPerStep)).rounded(.towardZero) * (shift ? 10 : 1)
        guard done || steps != lastDelta else { return }
        lastDelta = steps
        onChange?(.drag(delta: steps, done: done))
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .incrementor }
    override func isAccessibilityElement() -> Bool { false }
}

/// A number's field: the value as written (its notation kept), a prefix and a unit inside a quiet rounded fill;
/// Return or leaving the field reports what was typed, the arrow keys step it (±1, ⇧ ±10).
final class StudioNumberBox: NSView, NSTextFieldDelegate {
    var onChange: ((StudioNumberChange) -> Void)?
    let field = NSTextField()
    private let prefixLabel = StudioPageStyle.label("", font: StudioPageStyle.valueFont, color: .labelColor)
    private let unitLabel = StudioPageStyle.label("", font: StudioPageStyle.smallFont)
    private(set) var number = StudioPage.Number(text: "")
    /// The text the field showed when editing began (so a field left unchanged reports nothing).
    private var shown = ""

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        for v in [prefixLabel, field, unitLabel] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() { layer?.backgroundColor = StudioPageStyle.fieldFill.cgColor }

    func show(_ n: StudioPage.Number) {
        number = n
        if n.isText { field.font = StudioPageStyle.valueFont }
        if field.currentEditor() == nil { field.stringValue = n.text }
        shown = n.text
        field.placeholderString = n.placeholder
        prefixLabel.stringValue = n.prefix ?? ""
        prefixLabel.isHidden = n.prefix == nil
        unitLabel.stringValue = n.unit ?? ""
        unitLabel.isHidden = n.unit == nil
        field.setAccessibilityValueDescription(n.text.isEmpty ? n.placeholder : n.text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 8
        if !prefixLabel.isHidden {
            let w = ceil((prefixLabel.stringValue as NSString).size(withAttributes: [.font: prefixLabel.font!]).width) + 3
            prefixLabel.frame = NSRect(x: x, y: (h - 16) / 2, width: w, height: 16)
            x += w + 5
        }
        var right = bounds.width - 7
        if !unitLabel.isHidden {
            let w = ceil((unitLabel.stringValue as NSString).size(withAttributes: [.font: unitLabel.font!]).width) + 4
            unitLabel.frame = NSRect(x: right - w, y: (h - 15) / 2, width: w, height: 15)
            right -= w + 4
        }
        field.frame = NSRect(x: x, y: (h - 17) / 2, width: max(right - x, 12), height: 17)
    }

    // MARK: Editing

    func controlTextDidEndEditing(_ obj: Notification) {
        let text = field.stringValue
        guard text != shown else { return }
        shown = text
        onChange?(.typed(text))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            if text != shown {
                shown = text
                onChange?(.typed(text))
            }
            return true
        case #selector(NSResponder.moveUp(_:)) where !number.isText,
             #selector(NSResponder.moveUpAndModifySelection(_:)) where !number.isText:
            onChange?(.step(shift || selector == #selector(NSResponder.moveUpAndModifySelection(_:)) ? 10 : 1))
            return true
        case #selector(NSResponder.moveDown(_:)) where !number.isText,
             #selector(NSResponder.moveDownAndModifySelection(_:)) where !number.isText:
            onChange?(.step(shift || selector == #selector(NSResponder.moveDownAndModifySelection(_:)) ? -10 : -1))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = shown
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// An arrow key pressed in the field (the self-tests; ⇧ for ten).
    func pressArrow(up: Bool, shift: Bool = false) {
        onChange?(.step((up ? 1 : -1) * (shift ? 10 : 1)))
    }

    /// Text typed and committed (the self-tests).
    func type(_ text: String) {
        field.stringValue = text
        shown = text
        onChange?(.typed(text))
    }
}

/// Works out what is typed into a number field: a number, or arithmetic (`15+2`, `46 / 2`, `(10 + 4) * 2`); nil when
/// it is neither (then it is written as it is: a variable, a formula of the skin's own).
enum StudioNumberInput {
    static func evaluate(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let v = Double(t), v.isFinite { return v }
        // Only digits, operators, points, brackets and spaces: a sum to work out. Anything else (a #Variable#, a
        // measure) is the skin's own formula.
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/%() ")
        guard t.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        guard let v = try? Formula.evaluate("(\(t))"), v.isFinite else { return nil }
        return v
    }

    /// A number as a field writes it: whole numbers without a point, else at most three decimals.
    static func text(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e12 { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
