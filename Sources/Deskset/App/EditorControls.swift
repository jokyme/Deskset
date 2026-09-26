import AppKit
import DesksetCore

// The inspector's controls, one per value kind (docs/editor-design.md §3, "Control per value kind"): checkbox,
// segmented control and pop-up for choices, two segmented controls for the nine text alignments, a number field with
// a stepper, slider + "%" field, degree field + circular slider, four inset fields with a link toggle, image picker,
// style tokens, format combo box with a live preview, text fields. The controls know nothing about skins: they report
// values through closures and the inspector (EditorInspector.swift) decides where they are written — except the color
// control and the linked value with its grey tag (docs/editor-friendly.md §7.3–7.4), which are built for the
// inspector and write through it, where the selection says (§7.5).

// MARK: - State kept between rebuilds

/// What the inspector remembers while it is rebuilt after every refresh: the pending live preview of a continuous
/// control, open disclosures, the expanded shape of a Shape meter, unlinked inset fields, and the labels that follow
/// live values. The window controller holds one (`inspectorState`).
final class InspectorState {
    /// The option a continuous control (slider, circular slider, held stepper) is previewing.
    struct PreviewTarget: Equatable {
        var section: String
        var key: String
        /// The value is one `#Var#`: the variable is previewed and written instead.
        var variable: String?
        /// Undo action name.
        var name: String
    }

    var preview: PreviewTarget?
    var previewValue: String?
    /// The value as written before the preview started (nothing is written when the preview ends there).
    var previewOriginal: String?
    var previewTimer: Timer?
    /// Writes a pending preview when the window closes.
    var closeObserver: NSObjectProtocol?
    /// True while the inspector is torn down and rebuilt: controls losing focus then must not write.
    var isRebuilding = false
    /// Counts the rebuilds: a part of the page still waiting to be built belongs to the rebuild that queued it
    /// (`addPart`), and is dropped when another rebuild came since.
    var generation = 0
    /// Where `addPart` queues the parts of a page built in steps (nil: parts are built at once).
    var partSteps: MainThreadSteps?
    /// The parts of the page that no longer widen the pane (`yieldWidthOnce`).
    var preparedParts: Set<ObjectIdentifier> = []
    /// Meter (lowercased) → the option key of its expanded shape.
    var expandedShapes: [String: String] = [:]
    /// Open disclosures ("Meter/Shape2/transform", "Meter/Shape2/caps").
    var disclosures: Set<String> = []
    /// Inset options ("Section/Key") the user linked (true) or unlinked (false); otherwise linked when all four
    /// values are equal.
    var insetLinks: [String: Bool] = [:]
    /// Labels that follow live values (formula results, format previews, pill values).
    var liveUpdates: [() -> Void] = []
    var liveTimer: Timer?
    /// Configs (lowercased) whose widget page writes shared-file values for every widget ("Apply to: All N Widgets");
    /// the others write them for this widget only (§8.1.1).
    var applyToAllWidgets: Set<String> = []
    /// Same-value colors the widget page shows as separate rows (lowercased variable names).
    var separateColors: Set<String> = []
    /// A color being picked in the color panel by a color control or a widget-page row, its last pick and the pause
    /// after which it is written.
    var colorEdit: ColorEdit?
    var colorEditValue: RGBA?
    var colorEditTimer: Timer?
    /// The writes of one session in the color panel (from opening it on a color to closing it), one undo step: the
    /// step so far, which later picks are folded into (`performEdit`).
    final class ColorSession {
        var step: ColorStep?
    }

    /// The bytes an undo step of the color panel puts back (the first pick's "before", the last pick's "after").
    final class ColorStep {
        private(set) var changes: [EditorFileChange]
        /// Undone once: a later pick is a new step (the redo holds its own copy of the changes).
        var isSealed = false

        init(_ changes: [EditorFileChange]) { self.changes = changes }

        /// Folds a later write into the step: only when it was not undone and the write starts from what the step
        /// left in its files (nothing else wrote them in between).
        func merge(_ later: [EditorFileChange]) -> Bool {
            guard !isSealed else { return false }
            for c in later {
                if let mine = changes.first(where: { $0.file == c.file }), mine.after != c.before { return false }
            }
            for c in later {
                if let i = changes.firstIndex(where: { $0.file == c.file }) {
                    changes[i].after = c.after
                } else {
                    changes.append(c)
                }
            }
            return true
        }
    }

    var colorSession: ColorSession?
    /// True while `commitColorEdit` writes: `performEdit` folds the write into the session's step.
    var colorCommitting = false
    /// Writes a pending pick when the window closes.
    var colorEditCloseObserver: NSObjectProtocol?
    /// The linked value whose shared value is being changed ("Change ‘Left’ for All 10 Layers…"), by the identifier of
    /// its tag; and the linked values whose calculation is shown.
    var variableEdit: String?
    var openCalculations: Set<String> = []
    /// `Skin.valueUsages()` of the skin as it is now, so one rebuild of the inspector scans the skin once.
    final class UsageCache {
        /// The skin it was made for (a refresh makes a new one).
        weak var skin: Skin?
        /// Its update count and preview state then (values the skin sets while it runs change what is in effect).
        var key: String
        var index: ValueUsageIndex

        init(skin: Skin, key: String, index: ValueUsageIndex) {
            self.skin = skin
            self.key = key
            self.index = index
        }
    }

    var usageCache: UsageCache?
    /// Which configs read which shared files (`Skin.includeMap`), walked once per editor.
    var includeMap: Skin.IncludeMap?
    /// What the layer list's eye replaced when it hid a layer ("config|section", lowercased): the layer's own Hidden as
    /// written when it followed a setting (`#HideSeconds#`, a formula), or nil when it had none — put back when the eye
    /// shows the layer again, so the widget's own setting keeps working (P11).
    var eyeSaved: [String: String?] = [:]
    /// Whether a shared file is a theme a variable chooses (`Skin.switchedInclude`), by the file's path.
    var themeCache: [String: Skin.SwitchedInclude?] = [:]
    /// The desktop settings the widget page shows (a change made elsewhere — the menu bar, the widget's own menu —
    /// rebuilds it).
    var desktopShown: SkinState?

    deinit {
        previewTimer?.invalidate()
        liveTimer?.invalidate()
        colorEditTimer?.invalidate()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let colorEditCloseObserver { NotificationCenter.default.removeObserver(colorEditCloseObserver) }
    }
}

// MARK: - Closures for controls and menu items

/// Runs `body` on the next turn of the main run loop in the default mode: not while a menu is open or a control is
/// tracking the mouse (a commit refreshes the skin and rebuilds the inspector — never under the pointer), but in a
/// self-test's run loop.
func onNextTurn(_ body: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.default], block: body)
}

/// Target of a control whose action is a closure (`NSControl.onAction`).
final class ControlAction: NSObject {
    let body: (NSControl) -> Void

    init(_ body: @escaping (NSControl) -> Void) { self.body = body }

    @objc func fire(_ sender: NSControl) { body(sender) }
}

private var controlActionKey: UInt8 = 0

extension NSControl {
    /// Sets the control's action to `body` (the closure is kept alive by the control).
    func onAction(_ body: @escaping (NSControl) -> Void) {
        let handler = ControlAction(body)
        objc_setAssociatedObject(self, &controlActionKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        target = handler
        action = #selector(ControlAction.fire(_:))
    }
}

/// A menu item whose action is a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let symbol { image = EditorStyle.image(symbol, size: 13) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

// MARK: - Text fields

/// A text field for one option value. It commits when editing ends (Return, Tab, clicking elsewhere) and the text
/// changed; Esc puts the written value back. `validate` can refuse a value (it returns the reason), so a typo never
/// reaches the file.
class ValueField: NSTextField, NSTextFieldDelegate {
    /// The value as written (what Esc restores, what "changed" compares with).
    var original: String
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Editing ended without a change (clicking away, Return on the same text).
    var onUnchanged: (() -> Void)?
    var validate: ((String) -> String?)?
    var onInvalid: ((String) -> Void)?
    /// True while the field's owner is being rebuilt (the inspector sets it): editing that ends then — the field is
    /// being taken out of the window, not left by the user — writes nothing. The typed text goes to the rebuilt field,
    /// which keeps editing it, so the value is written only to what the user sees it next to.
    var isSuspended: (() -> Bool)?

    /// `monospaced`: the code font, for what is code (a calculation, a command); otherwise the system font with
    /// even-width digits, so numbers line up without looking like code.
    init(_ value: String, placeholder: String = "", monospaced: Bool = false) {
        original = value
        super.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
        font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        bezelStyle = .roundedBezel
        isBezeled = true
        isEditable = true
        isSelectable = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        usesSingleLineMode = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The text as the user typed it (a formatter may return a number object).
    var text: String {
        if let s = objectValue as? String { return s }
        return stringValue
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishEditing(deferred: true) }

    /// Commits a changed value. From a real end of editing the write waits for the next turn of the run loop: the
    /// focus is still moving (Tab), and the write refreshes the skin and rebuilds the inspector.
    func finishEditing(deferred: Bool) {
        if deferred, isSuspended?() == true {
            formatFailure = nil
            return
        }
        if let failed = formatFailure {
            // Not a number (the formatter said so): the written value comes back, and the user is told why.
            formatFailure = nil
            NSSound.beep()
            stringValue = original
            onInvalid?(failed)
            return
        }
        let value = text
        guard value != original else { onUnchanged?(); return }
        if let problem = validate?(value) {
            NSSound.beep()
            stringValue = original
            onInvalid?(problem)
            return
        }
        original = value
        guard deferred else { onCommit?(value); return }
        let commit = onCommit
        onNextTurn { commit?(value) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            stringValue = original
            window?.makeFirstResponder(nil)
            onCancel?()
            return true
        }
        return false
    }

    /// Why the formatter refused the typed text (handled when editing ends, instead of AppKit's alert).
    private var formatFailure: String?

    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool {
        formatFailure = error ?? "“\(string)” is not a number"
        return true
    }

    /// Sets the text as if the user typed it and ended editing (self-tests).
    func type(_ value: String) {
        stringValue = value
        if formatter != nil, objectValue == nil, !value.isEmpty { formatFailure = "“\(value)” is not a number" }
        finishEditing(deferred: false)
    }
}

/// A number formatter that also lets formulas and variables through (`(#A# * 2)`, `#Size#`, `[M:W]`), clamps plain
/// numbers to the option's limits and writes them without grouping in the POSIX locale (skins are code).
final class LenientNumberFormatter: NumberFormatter, @unchecked Sendable {
    let lower: Double?
    let upper: Double?

    init(min: Double?, max: Double?) {
        lower = min
        upper = max
        super.init()
        locale = Locale(identifier: "en_US_POSIX")
        numberStyle = .decimal
        usesGroupingSeparator = false
        maximumFractionDigits = 6
        minimumFractionDigits = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func isExpression(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("(") || t.contains("#") || t.contains("[")
    }

    override func string(for obj: Any?) -> String? {
        if let s = obj as? String { return s }
        return super.string(for: obj)
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let t = string.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || Self.isExpression(t) {
            obj?.pointee = t as NSString
            return true
        }
        guard var n = Double(t), n.isFinite else {
            error?.pointee = "“\(t)” is not a number" as NSString
            return false
        }
        if let lower { n = Swift.max(n, lower) }
        if let upper { n = Swift.min(n, upper) }
        obj?.pointee = NSNumber(value: n)
        return true
    }

    override func isPartialStringValid(_ partialString: String, newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool { true }
}

/// A number field: its text is a plain number, a formula or empty.
final class NumberField: ValueField {
    init(_ value: String, placeholder: String, min: Double?, max: Double?) {
        super.init(value, placeholder: placeholder)
        formatter = LenientNumberFormatter(min: min, max: max)
        stringValue = value
        alignment = .right
        if let n = objectValue as? NSNumber { original = formatter?.string(for: n) ?? value } else { original = value }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Formatted text: numbers written plainly (`12`, `1.5`), other text as typed.
    override var text: String {
        if let n = objectValue as? NSNumber { return formatter?.string(for: n) ?? n.stringValue }
        return (objectValue as? String) ?? stringValue
    }

}

/// A slider that reports the end of a drag (mouse up), so a live preview can be written once.
final class TrackingSlider: NSSlider {
    var onTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)  // tracks until the mouse goes up
        onTrackingEnded?()
    }
}

/// A stepper that reports the end of a press (held presses repeat), so the steps become one write.
final class TrackingStepper: NSStepper {
    var onTrackingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onTrackingEnded?()
    }
}

/// A pop-up whose closed title can be shorter than its menu items, so the part that tells the items apart is what
/// stays visible in a narrow column: "Transparent" for "Transparent (default)", "MeasureSwap" for a data source
/// whose plain name another one shares. The menu keeps the full titles.
final class CompactPopUpButton: NSPopUpButton {
    /// The closed title for a menu item (nil: the item's own title).
    var closedTitle: ((NSMenuItem) -> NSAttributedString?)? {
        didSet { updateClosedTitle() }
    }
    /// Whether a short closed title keeps the item's icon (off: the room goes to the words).
    var closedTitleShowsImage = true {
        didSet { updateClosedTitle() }
    }

    /// The title shown while the menu is closed (self-tests).
    var shownTitle: String {
        guard let cell = cell as? NSPopUpButtonCell, !cell.usesItemFromMenu, let item = cell.menuItem else { return titleOfSelectedItem ?? "" }
        return item.title
    }

    func updateClosedTitle() {
        guard let cell = cell as? NSPopUpButtonCell else { return }
        guard let item = selectedItem, let title = closedTitle?(item) else {
            cell.usesItemFromMenu = true
            return
        }
        let shown = NSMenuItem(title: title.string, action: nil, keyEquivalent: "")
        shown.attributedTitle = title
        shown.image = closedTitleShowsImage ? item.image : nil
        cell.usesItemFromMenu = false
        cell.menuItem = shown
    }

    override func select(_ item: NSMenuItem?) {
        super.select(item)
        updateClosedTitle()
    }

    override func selectItem(at index: Int) {
        super.selectItem(at: index)
        updateClosedTitle()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        // A choice made in the menu (the cell selected it without `select`).
        updateClosedTitle()
        return super.sendAction(action, to: target)
    }
}

/// A checkbox whose title wraps (positive titles can be long for the narrow control column); clicking the title
/// toggles it too.
final class CheckboxRow: NSStackView {
    let box: NSButton
    let title: NSTextField

    init(title text: String, width: CGFloat) {
        box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        title = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 5
        box.setAccessibilityLabel(text)
        box.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.isSelectable = false
        title.maximumNumberOfLines = 3
        title.preferredMaxLayoutWidth = max(width - 24, 60)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(titleClicked)))
        addArrangedSubview(box)
        addArrangedSubview(title)
        addArrangedSubview(EditorStyle.spacer())
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func titleClicked() {
        guard box.isEnabled else { return }
        box.performClick(nil)
    }
}

/// A segmented control for a choice: `values[i]` is what segment i writes.
final class ChoiceSegmentedControl: NSSegmentedControl {
    var values: [String] = []
}

// MARK: - Composite controls

/// A compact number field with its unit and, where it helps, a stepper. Typing commits; the stepper previews each
/// step and commits when released. It ends in a spacer, so it is laid out as wide as its place and keeps to the left
/// by itself — never next to another spacer: the two would share the room left over, and nothing says how.
final class NumberControl: NSStackView {
    let field: NumberField
    let stepper: TrackingStepper?
    var onCommit: ((String) -> Void)?
    /// A step (value, finished: the press ended).
    var onStep: ((String, Bool) -> Void)?

    init(value: String, placeholder: String, min: Double?, max: Double?, step: Double?, unit: String?,
         fallback: Double, fieldWidth: CGFloat = 64) {
        field = NumberField(value, placeholder: placeholder, min: min, max: max)
        if let step, !LenientNumberFormatter.isExpression(value) {
            let s = TrackingStepper()
            s.minValue = min ?? -1_000_000
            s.maxValue = max ?? 1_000_000
            s.increment = step
            s.valueWraps = false
            s.autorepeat = true
            s.doubleValue = OptionValue.number(value) ?? fallback
            s.controlSize = .small
            stepper = s
        } else {
            stepper = nil
        }
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        alignment = .centerY
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        addArrangedSubview(field)
        if let stepper { addArrangedSubview(stepper) }
        if let unit, !unit.isEmpty {
            let l = EditorStyle.label(unit, size: 11, color: .secondaryLabelColor)
            // Whole, unless the column is too narrow for the field, the stepper and a long unit ("milliseconds" with
            // legacy scroll bars): then the unit is shortened, never the stepper (at one priority, either could be).
            l.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
            addArrangedSubview(l)
        }
        addArrangedSubview(EditorStyle.spacer())
        field.onCommit = { [weak self] v in self?.onCommit?(v) }
        stepper?.onAction { [weak self] c in
            guard let self, let s = c as? NSStepper else { return }
            let text = GeometryEdit.format(s.doubleValue)
            self.field.stringValue = text
            self.field.original = text
            self.onStep?(text, false)
        }
        stepper?.onTrackingEnded = { [weak self] in
            guard let self, let s = self.stepper else { return }
            self.onStep?(GeometryEdit.format(s.doubleValue), true)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Opacity-like values: a slider and a "%" field (0–100 % ↔ 0–255).
final class PercentControl: NSStackView {
    let slider = TrackingSlider()
    let field: NumberField
    /// The value to write (0–255), finished = the drag ended or the field was committed.
    var onChange: ((String, Bool) -> Void)?

    static func percent(of raw: Double) -> Double { (min(max(raw, 0), 255) / 255 * 100).rounded() }
    static func raw(ofPercent p: Double) -> String { GeometryEdit.format((min(max(p, 0), 100) * 255 / 100).rounded()) }

    init(value: Double) {
        let p = Self.percent(of: value)
        field = NumberField(GeometryEdit.format(p), placeholder: "100", min: 0, max: 100)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = p
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let unit = EditorStyle.label("%", size: 11, color: .secondaryLabelColor)
        unit.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [slider, field, unit] as [NSView] { addArrangedSubview(v) }
        slider.onAction { [weak self] _ in
            guard let self else { return }
            let pct = self.slider.doubleValue.rounded()
            self.field.stringValue = GeometryEdit.format(pct)
            self.onChange?(Self.raw(ofPercent: pct), false)
        }
        slider.onTrackingEnded = { [weak self] in
            guard let self else { return }
            self.onChange?(Self.raw(ofPercent: self.slider.doubleValue.rounded()), true)
        }
        field.onCommit = { [weak self] text in
            guard let self, let p = Double(text) else { return }
            self.slider.doubleValue = p
            self.onChange?(Self.raw(ofPercent: p), true)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// An angle in degrees: a field and, for directions, a circular slider. Radians are shown in degrees and written as
/// `(Rad(n))`.
final class AngleControl: NSStackView {
    let field: NumberField
    let dial: TrackingSlider?
    let unit: EditorSchema.AngleUnit
    /// The value to write, finished = the drag ended or the field was committed.
    var onChange: ((String, Bool) -> Void)?

    /// Degrees shown for a written value: a number (radians converted) or `(Rad(n))`; nil for other formulas.
    static func degrees(of raw: String, unit: EditorSchema.AngleUnit) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        if let n = Double(t) { return unit == .radians ? n * 180 / .pi : n }
        // Radians written by the editor: (Rad(n)), n a plain number of degrees.
        guard unit == .radians, t.hasPrefix("("), t.hasSuffix(")") else { return nil }
        let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard inner.lowercased().hasPrefix("rad("), inner.hasSuffix(")") else { return nil }
        return Double(inner.dropFirst(4).dropLast().trimmingCharacters(in: .whitespaces))
    }

    /// The text written for an angle in degrees.
    static func text(degrees: Double, unit: EditorSchema.AngleUnit) -> String {
        let d = GeometryEdit.format((degrees * 100).rounded() / 100)
        return unit == .radians ? (d == "0" ? "0" : "(Rad(\(d)))") : d
    }

    init(raw: String, unit: EditorSchema.AngleUnit, orientation isOrientation: Bool, placeholder: String) {
        self.unit = unit
        let degrees = raw.isEmpty ? nil : Self.degrees(of: raw, unit: unit)
        field = NumberField(degrees.map { GeometryEdit.format(($0 * 100).rounded() / 100) } ?? "",
                            placeholder: placeholder.isEmpty ? "0" : (Double(placeholder).map {
                                GeometryEdit.format(unit == .radians ? $0 * 180 / .pi : $0) } ?? placeholder),
                            min: nil, max: nil)
        if isOrientation {
            let s = TrackingSlider()
            s.sliderType = .circular
            s.minValue = 0
            s.maxValue = 360
            s.isContinuous = true
            s.controlSize = .regular
            let d = (degrees ?? 0).truncatingRemainder(dividingBy: 360)
            s.doubleValue = d < 0 ? d + 360 : d
            dial = s
        } else {
            dial = nil
        }
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        if let dial { addArrangedSubview(dial) }
        addArrangedSubview(field)
        let degreeSign = EditorStyle.label("°", size: 12, color: .secondaryLabelColor)
        degreeSign.setContentCompressionResistancePriority(.required, for: .horizontal)
        addArrangedSubview(degreeSign)
        addArrangedSubview(EditorStyle.spacer())
        dial?.onAction { [weak self] c in
            guard let self, let s = c as? NSSlider else { return }
            let d = s.doubleValue.rounded()
            self.field.stringValue = GeometryEdit.format(d)
            self.onChange?(Self.text(degrees: d, unit: unit), false)
        }
        dial?.onTrackingEnded = { [weak self] in
            guard let self, let s = self.dial else { return }
            self.onChange?(Self.text(degrees: s.doubleValue.rounded(), unit: unit), true)
        }
        field.onCommit = { [weak self] text in
            guard let self else { return }
            if text.isEmpty { self.onChange?("", true); return }
            // A formula typed on purpose is written as typed.
            guard let d = Double(text) else { self.onChange?(text, true); return }
            self.dial?.doubleValue = { let r = d.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }()
            self.onChange?(Self.text(degrees: d, unit: unit), true)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// `StringAlign`: horizontal Left / Center / Right and vertical Top / Middle / Bottom, mapped to the nine values.
final class AlignmentControl: NSStackView {
    let horizontal = NSSegmentedControl()
    let vertical = NSSegmentedControl()
    var onChange: ((String) -> Void)?

    static let horizontalNames = ["Left", "Center", "Right"]
    static let verticalSuffixes = ["", "Center", "Bottom"]

    /// The value for a position (h, v: 0…2).
    static func value(h: Int, v: Int) -> String { horizontalNames[h] + verticalSuffixes[v] }

    /// The position the engine uses for a written value.
    static func position(of raw: String) -> (h: Int, v: Int) {
        let c = EditorSchema.alignmentChoice(for: raw).value
        let h = horizontalNames.firstIndex { c.hasPrefix($0) } ?? 0
        let rest = String(c.dropFirst(horizontalNames[h].count))
        return (h, verticalSuffixes.firstIndex(of: rest) ?? 0)
    }

    /// Width of one segment: both controls (2 × 68 pt with 6 pt between) fit the narrowest control column (143 pt).
    static let segmentWidth: CGFloat = 22

    init(raw: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        func configure(_ c: NSSegmentedControl, _ items: [(String, String)]) {
            c.segmentCount = items.count
            c.trackingMode = .selectOne
            c.segmentStyle = .rounded
            c.controlSize = .small
            c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            for (i, item) in items.enumerated() {
                if let image = EditorStyle.image(item.0, size: 12) { c.setImage(image, forSegment: i) } else { c.setLabel(item.1, forSegment: i) }
                c.setToolTip(item.1, forSegment: i)
                c.setWidth(Self.segmentWidth, forSegment: i)
            }
            c.setAccessibilityLabel(items.map(\.1).joined(separator: ", "))
        }
        configure(horizontal, [("text.alignleft", "Left"), ("text.aligncenter", "Center"), ("text.alignright", "Right")])
        configure(vertical, [("align.vertical.top", "Top"), ("align.vertical.center", "Middle"),
                             ("align.vertical.bottom", "Bottom")])
        let p = Self.position(of: raw)
        horizontal.selectedSegment = p.h
        vertical.selectedSegment = p.v
        horizontal.identifier = NSUserInterfaceItemIdentifier("StringAlign.horizontal")
        vertical.identifier = NSUserInterfaceItemIdentifier("StringAlign.vertical")
        for c in [horizontal, vertical] {
            addArrangedSubview(c)
            c.onAction { [weak self] _ in
                guard let self else { return }
                self.onChange?(Self.value(h: max(self.horizontal.selectedSegment, 0), v: max(self.vertical.selectedSegment, 0)))
            }
        }
        setCustomSpacing(0, after: vertical)
        addArrangedSubview(EditorStyle.spacer())
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// `Left,Top,Right,Bottom`: four small fields and a link toggle (linked: one value for all four).
final class InsetsControl: NSStackView {
    let fields: [NumberField]
    let link = NSButton()
    /// One field was committed: its index, its value, whether the sides are linked. The owner builds the value to
    /// write from what the file holds then (`combined`), not from the other fields, which may be out of date.
    var onFieldChange: ((Int, String, Bool) -> Void)?
    var onLinkChange: ((Bool) -> Void)?

    /// The four values of a written insets value (missing ones 0); nil when one is not a plain number.
    static func values(of raw: String) -> [String]? {
        let parts = OptionValue.split(raw, separator: ",")
        guard parts.count <= 4 else { return nil }
        var out: [String] = []
        for i in 0..<4 {
            let p = i < parts.count ? parts[i] : ""
            if p.isEmpty { out.append("0"); continue }
            guard Double(p) != nil else { return nil }
            out.append(p)
        }
        return out
    }

    /// Four 28 pt fields, 3 pt apart, and the 16 pt link fit the narrowest control column (143 pt).
    static let fieldWidth: CGFloat = 28

    /// `spelledOut`: the sides are named in full under wider fields (a control given the card's whole width, such as
    /// the widget page's dragging edges); else by their initials, to fit the narrow control column.
    init(values: [String], linked: Bool, spelledOut: Bool = false) {
        fields = values.map { NumberField($0, placeholder: "0", min: nil, max: nil) }
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = spelledOut ? 8 : 3
        alignment = .top
        // In a row made taller by its label (Rainmeter Details) it is as tall as the row, and leaves the room under its
        // sides: pulling each down as hard as it hugs its field and caption (250), it could stretch it or not (ambiguous).
        setHuggingPriority(.defaultLow - 1, for: .vertical)
        let names = ["Left", "Top", "Right", "Bottom"]
        for (i, f) in fields.enumerated() {
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.toolTip = names[i]
            f.widthAnchor.constraint(equalToConstant: spelledOut ? 38 : Self.fieldWidth).isActive = true
            let caption = EditorStyle.label(spelledOut ? names[i] : String(names[i].prefix(1)), size: 9.5, weight: .medium,
                                            color: .tertiaryLabelColor)
            if spelledOut { caption.setContentCompressionResistancePriority(.required, for: .horizontal) }
            caption.alignment = .center
            let cell = EditorStyle.vstack([f, caption], spacing: 2)
            cell.alignment = .centerX
            addArrangedSubview(cell)
            f.onCommit = { [weak self] v in self?.fieldChanged(i, v) }
        }
        link.setButtonType(.pushOnPushOff)
        link.bezelStyle = .texturedRounded
        link.isBordered = false
        link.image = EditorStyle.image("link", size: 12, weight: .medium)
        link.state = linked ? .on : .off
        link.contentTintColor = linked ? .controlAccentColor : .tertiaryLabelColor
        link.toolTip = "Same value on all four sides"
        link.setAccessibilityLabel("Link sides")
        link.widthAnchor.constraint(equalToConstant: 16).isActive = true
        link.onAction { [weak self] _ in
            guard let self else { return }
            self.link.contentTintColor = self.link.state == .on ? .controlAccentColor : .tertiaryLabelColor
            self.onLinkChange?(self.link.state == .on)
        }
        addArrangedSubview(link)
        setCustomSpacing(0, after: link)
        addArrangedSubview(EditorStyle.spacer())
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isLinked: Bool { link.state == .on }

    func fieldChanged(_ i: Int, _ value: String) {
        let v = value.isEmpty ? "0" : value
        if isLinked { for f in fields { f.stringValue = v } }
        onFieldChange?(i, v, isLinked)
    }

    /// The value to write when side `index` becomes `value` in `current` (the four sides as the file holds them):
    /// linked, all four take it.
    static func combined(_ current: [String], index: Int, value: String, linked: Bool) -> String {
        let v = value.isEmpty ? "0" : value
        var all = (0..<4).map { $0 < current.count && !current[$0].isEmpty ? current[$0] : "0" }
        if linked { all = Array(repeating: v, count: 4) } else if index >= 0, index < 4 { all[index] = v }
        return all.joined(separator: ",")
    }
}

/// A format with presets (combo box) and a line previewing it.
final class FormatControl: NSStackView {
    let combo = ValueComboBox()
    let preview = EditorStyle.label("", size: 11, color: .secondaryLabelColor)
    let render: (String) -> String
    var onCommit: ((String) -> Void)?

    init(value: String, placeholder: String, presets: [String], render: @escaping (String) -> String) {
        self.render = render
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        combo.addItems(withObjectValues: presets)
        combo.stringValue = value
        combo.original = value
        combo.placeholderString = placeholder
        combo.completes = false
        combo.numberOfVisibleItems = min(max(presets.count, 1), 12)
        combo.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        combo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.font = .systemFont(ofSize: 11)
        addArrangedSubview(combo)
        addArrangedSubview(preview)
        combo.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        combo.onCommit = { [weak self] v in self?.onCommit?(v) }
        updatePreview()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updatePreview() {
        let text = combo.stringValue.isEmpty ? (combo.placeholderString ?? "") : combo.stringValue
        let shown = render(text)
        preview.stringValue = shown.isEmpty ? "" : "Shows “\(shown)”"
        preview.toolTip = shown
    }
}

/// A combo box that commits like `ValueField` (end of editing, or a preset picked from the list).
final class ValueComboBox: NSComboBox, NSComboBoxDelegate {
    var original = ""
    var onCommit: ((String) -> Void)?
    /// See `ValueField.isSuspended`.
    var isSuspended: (() -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isSuspended?() != true, stringValue != original else { return }
        let value = stringValue
        original = value
        let commit = onCommit
        onNextTurn { commit?(value) }
    }

    /// Writes the typed text now (the window closes, an edit needs it written first).
    func commitNow() {
        let value = currentEditor()?.string ?? stringValue
        guard value != original else { return }
        original = value
        onCommit?(value)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard indexOfSelectedItem >= 0, let value = itemObjectValue(at: indexOfSelectedItem) as? String else { return }
        stringValue = value
        (superview as? FormatControl)?.updatePreview()
        guard value != original else { return }
        original = value
        // After the list closed: the commit refreshes the skin and rebuilds the inspector.
        onNextTurn { [weak self] in self?.onCommit?(value) }
    }

    func controlTextDidChange(_ obj: Notification) { (superview as? FormatControl)?.updatePreview() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            stringValue = original
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    /// Picks or types a value as the user would (self-tests).
    func type(_ value: String) {
        stringValue = value
        guard value != original else { return }
        original = value
        onCommit?(value)
    }
}

/// An image option: a thumbnail of the file and a menu of the images in the skin folder and @Resources.
final class ImageControl: NSStackView {
    let thumbnail = NSImageView()
    let popup = NSPopUpButton()

    init(image: NSImage?) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        thumbnail.image = image ?? EditorStyle.image("photo", size: 14, weight: .light)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.contentTintColor = .tertiaryLabelColor
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 5
        thumbnail.layer?.borderWidth = 0.5
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbnail.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.widthAnchor.constraint(equalToConstant: 28).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 28).isActive = true
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(thumbnail)
        addArrangedSubview(popup)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// `MeterStyle`: the styles as tokens (click opens one, × removes it) and a menu to add another existing style.
final class StyleListControl: NSStackView {
    let flow = FlowView()
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// Sets the whole list.
    var onChange: (([String]) -> Void)?
    /// The menu added a style / a token's × removed one: the owner applies it to the list the file holds then (the
    /// tokens may be out of date). Without them, `onChange` gets the list the control shows.
    var onAdd: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    private(set) var styles: [String]

    init(styles: [String], available: [String], missing: Set<String>) {
        self.styles = styles
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        for (i, s) in styles.enumerated() {
            flow.addSubview(token(s, index: i, missing: missing.contains(s.lowercased())))
        }
        let others = available.filter { a in !styles.contains { $0.caseInsensitiveCompare(a) == .orderedSame } }
        addButton.bezelStyle = .inline
        addButton.controlSize = .small
        addButton.isBordered = false
        let menu = NSMenu()
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = EditorStyle.image("plus", size: 10, weight: .semibold)
        menu.addItem(title)
        if others.isEmpty {
            let none = NSMenuItem(title: available.isEmpty ? "This widget has no looks" : "Every look is used already", action: nil,
                                  keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for o in others {
            menu.addItem(ClosureMenuItem(o, symbol: "paintbrush") { [weak self] in
                guard let self else { return }
                if let onAdd = self.onAdd { onAdd(o) } else { self.onChange?(self.styles + [o]) }
            })
        }
        addButton.menu = menu
        addButton.toolTip = "Add a look"
        addButton.setAccessibilityLabel("Add a look")
        flow.addSubview(addButton)
        addArrangedSubview(flow)
        flow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func token(_ name: String, index: Int, missing: Bool) -> NSView {
        let open = NSButton(title: name, target: nil, action: nil)
        open.isBordered = false
        open.font = .systemFont(ofSize: 11.5, weight: .medium)
        // A token wider than the control is shortened in its name; its brush and × stay whole (at one priority, any
        // of the three could give way).
        open.lineBreakMode = .byTruncatingMiddle
        open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        open.contentTintColor = missing ? .systemOrange : .labelColor
        open.toolTip = missing ? "This widget has no look called “\(name)”" : "Open the look “\(name)”"
        open.onAction { [weak self] _ in self?.onOpen?(name) }
        let remove = NSButton(image: EditorStyle.image("xmark", size: 8, weight: .bold) ?? NSImage(), target: nil, action: nil)
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "Remove \(name) from this layer"
        remove.setAccessibilityLabel("Remove \(name)")
        remove.onAction { [weak self] _ in
            guard let self else { return }
            if let onRemove = self.onRemove { return onRemove(name) }
            var list = self.styles
            if index < list.count { list.remove(at: index) }
            self.onChange?(list)
        }
        let row = EditorStyle.hstack([EditorStyle.image("paintbrush", size: 9).map { NSImageView(image: $0) } ?? NSView(),
                                      open, remove], spacing: 3)
        row.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 5)
        row.wantsLayer = true
        row.layer?.cornerRadius = 9
        row.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        row.layer?.borderWidth = 0.5
        row.layer?.borderColor = (missing ? NSColor.systemOrange : NSColor.separatorColor).cgColor
        row.identifier = NSUserInterfaceItemIdentifier("style-token-\(name)")
        return row
    }
}

/// Lays out its subviews left to right, wrapping to new rows (tokens, links).
final class FlowView: NSView {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6
    private var height: CGFloat = 0

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: max(height, 18)) }

    override func addSubview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        super.addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(bounds.width, 40)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews where !v.isHidden {
            let size = v.fittingSize
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            v.frame = NSRect(x: x, y: y, width: min(size.width, width), height: size.height)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let total = y + rowHeight
        if abs(total - height) > 0.5 {
            height = total
            invalidateIntrinsicContentSize()
        }
    }
}

/// The quiet grey tag after a value that is linked to something else (docs/editor-friendly.md §7.3): the shared
/// value's name ("Left", "Bar width"), "calculated", "3 px after Bar 5", "moves with peak level". It is a pull-down:
/// click it for its menu. `valueLabel` shows a value when nothing beside the tag does (the Shape editor's tags).
final class PillView: NSView {
    let nameLabel: NSTextField
    let valueLabel: NSTextField
    private let chevron = NSImageView()
    var menuProvider: (() -> NSMenu)?
    /// Width with the name shown; narrower, a tag with a value shows only the value (the name is in the tooltip).
    private var fullWidth: CGFloat = 0

    /// `symbol` is accepted for older callers and not drawn: the tag says what it is in words (§3.3, no "f(x)").
    init(name: String?, value: String, symbol: String? = nil) {
        nameLabel = EditorStyle.label(name ?? "", size: 11, weight: .medium, color: .secondaryLabelColor)
        valueLabel = EditorStyle.label(value, size: 11, color: .tertiaryLabelColor)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        chevron.image = EditorStyle.image("chevron.down", size: 7.5, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        var parts: [NSView] = []
        if name != nil { parts.append(nameLabel) }
        if !value.isEmpty { parts.append(valueLabel) }
        parts.append(chevron)
        // Narrow: the words are shortened in the middle first, the value stays readable.
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        let row = EditorStyle.hstack(parts, spacing: 3)
        row.edgeInsets = NSEdgeInsets(top: 1, left: 7, bottom: 1, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        fullWidth = row.fittingSize.width
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel([name, value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
        layer?.borderWidth = 0.5
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        guard !nameLabel.stringValue.isEmpty, !valueLabel.stringValue.isEmpty, bounds.width > 0 else { return }
        let hide = bounds.width + 0.5 < fullWidth
        if nameLabel.isHidden != hide { nameLabel.isHidden = hide }
    }

    override func mouseDown(with event: NSEvent) { showMenu() }

    func showMenu() {
        guard let menu = menuProvider?() else { return }
        // Below the tag, like a pull-down.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }
}

// MARK: - Colors and linked values

/// A color being picked in the color panel from a color control or a widget-page row (docs/editor-friendly.md
/// §7.4–7.5, §8.1.1), previewed live and written once after a pause, where its target says.
struct ColorEdit {
    enum Target {
        /// A property of the selection, written where `ScopeResolver` says (`variable`: it is `#Var#` now).
        case property(section: String, key: String, raw: String, variable: String?, label: String, selection: [String])
        /// Shared colors changed together (a widget-page row, "Change ‘Bar color’ Everywhere").
        case variables([String], role: String, users: [String])
        /// A literal color (the one written now), everywhere this widget writes it.
        case literal(RGBA, role: String, users: [String])
    }

    var target: Target
    /// `.literal`: the options that wrote the color when the edit began (found by `startColorEdit`); they are the ones
    /// rewritten at every pick, whatever other options happen to hold the color picked.
    var literalUses: [ValueUsageIndex.Use] = []
    /// `.variables`: written where they are defined, for every widget sharing the file, whatever "Apply to" says
    /// (the widget page's "Colors Other Widgets Use").
    var everywhere = false
}

/// Every color of the inspector (docs/editor-friendly.md §7.4): `[■ Bar color ▾]  11%` — a swatch drawn on the
/// widget's own panel color, the color's name (the role of the shared color it uses, "Custom" for a color of its
/// own, "Default" or "None" when it is not set) and its opacity when below 100%. Clicking opens a menu: the widget's
/// theme colors (picking one writes `#Var#`), the other colors used in it, Custom Color… (the color panel, previewed
/// live, one undo step), "Change ‘Bar color’ Everywhere" and Copy Color Code. Every write goes where the selection
/// says (§7.5). With Rainmeter Details on, the color's code can be typed too.
final class ColorControl: NSStackView {
    let swatch = SwatchButton()
    /// The color's name and the menu's arrow.
    let nameButton = NSButton(title: "", target: nil, action: nil)
    let opacityLabel = EditorStyle.label("", size: 11, color: .secondaryLabelColor)
    private weak var controller: InspectorWindowController?
    private let ctx: InspectorWindowController.PropertyContext
    private let selection: [String]

    init(ctx: InspectorWindowController.PropertyContext, controller: InspectorWindowController, selection: [String]? = nil) {
        self.ctx = ctx
        self.controller = controller
        self.selection = selection ?? controller.scopeSelection(for: ctx.section)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        let p = ctx.property
        // Not set: the default is what the engine draws — shown (with a dashed rim) when it is a visible color.
        let fallback = ctx.isSet ? nil : InspectorWindowController.visibleDefaultColor(p)
        let color = ctx.isSet ? OptionValue.color(ctx.resolved) : fallback
        swatch.color = color
        swatch.isDefault = fallback != nil
        swatch.backdrop = controller.widgetPanelColor()
        swatch.cornerRadius = 5
        swatch.removeConstraints(swatch.constraints)
        swatch.widthAnchor.constraint(equalToConstant: 24).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
        swatch.identifier = NSUserInterfaceItemIdentifier(p.key)
        swatch.target = self
        swatch.action = #selector(openMenu(_:))
        // The self-tests (and older callers) open the color panel the way the swatch used to.
        controller.swatchEdits[ObjectIdentifier(swatch)] = (ctx.section, ctx.key, ctx.raw, ctx.variable)
        let name = controller.colorName(ctx)
        nameButton.isBordered = false
        nameButton.title = name
        nameButton.font = .systemFont(ofSize: 12)
        nameButton.image = EditorStyle.image("chevron.down", size: 8, weight: .semibold)
        nameButton.imagePosition = .imageTrailing
        nameButton.contentTintColor = .secondaryLabelColor
        nameButton.lineBreakMode = .byTruncatingTail
        nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameButton.identifier = NSUserInterfaceItemIdentifier("\(p.key).name")
        nameButton.target = self
        nameButton.action = #selector(openMenu(_:))
        nameButton.setAccessibilityLabel("\(ctx.label): \(name)")
        let tip = controller.colorTooltip(color, ctx: ctx)
        swatch.toolTip = tip
        // The whole name first (a long one is cut on the button).
        nameButton.toolTip = "\(name)\n\(tip)"
        if let color, color.a < 254.5, ctx.isSet || fallback != nil {
            opacityLabel.stringValue = "\(Int((color.a / 255 * 100).rounded()))%"
        }
        opacityLabel.isHidden = opacityLabel.stringValue.isEmpty
        opacityLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        identifier = NSUserInterfaceItemIdentifier("\(p.key).row")
        // The name reads whole (§5.2 G1): when it and the opacity don't fit beside the swatch, the opacity goes under
        // the name ("Empty part of bars" / "11% opacity").
        let room = controller.inspectorControlWidth - 24 - 6
        let fits = opacityLabel.isHidden || nameButton.intrinsicContentSize.width + 6 + opacityLabel.intrinsicContentSize.width <= room
        let line = EditorStyle.hstack([swatch, nameButton] + (fits ? [opacityLabel] : []) + [EditorStyle.spacer()], spacing: 6)
        addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        if !fits {
            opacityLabel.stringValue += " opacity"
            let under = EditorStyle.hstack([opacityLabel, EditorStyle.spacer()], spacing: 0)
            // (No negative top inset: a row keeps an inset across it only as weakly as it hugs its views, and this one
            // was dropped where the row's height followed, and left the height open elsewhere — ambiguous.)
            under.edgeInsets = NSEdgeInsets(top: 0, left: 30, bottom: 0, right: 0)
            addArrangedSubview(under)
            under.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        if let link = controller.matchTheOthersLink(section: ctx.section, key: ctx.key) { addArrangedSubview(link) }
        // Rainmeter Details: the color's code, typed (a variable's value is edited from its menu).
        if controller.app.state.editor.showIniNames, ctx.variable == nil {
            let field = controller.textField(ctx, value: ctx.raw, placeholder: ctx.isSet ? ""
                                             : fallback != nil ? "default (\(InspectorWindowController.shortColor(p.defaultValue)))"
                                             : "none")
            field.validate = { v in
                v.isEmpty || LenientNumberFormatter.isExpression(v) || OptionValue.color(v) != nil
                    ? nil : "“\(v)” is not a color — use R,G,B,A or a hex value like FF8800"
            }
            addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The color menu (§7.4), below the swatch.
    var colorMenu: NSMenu? { controller?.colorMenu(ctx, selection: selection) }

    @objc func openMenu(_ sender: Any?) {
        guard let colorMenu else { return }
        colorMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: swatch.isFlipped ? swatch.bounds.maxY + 4 : -4), in: swatch)
    }
}

/// A value linked to something else (docs/editor-friendly.md §7.3), shown as its value in effect in a normal field
/// with a quiet grey tag after it. Typing in the field, and ↑ ↓ (⇧: 10) in it, go through `GeometryEdit.offset`, so
/// the link is kept: `#Left#` + 6 is written `(#Left# + 6)`, nudging a calculation keeps the calculation. The tag's
/// menu:
///
/// | written             | tag                   | menu                                                              |
/// |---------------------|-----------------------|-------------------------------------------------------------------|
/// | `#Left#`            | Left                  | Change ‘Left’ for All 9 Layers… · Use a Fixed Number Here · Highlight the 9 Layers |
/// | `(36 + #BarH# + 4)` | calculated            | Use a Fixed Number Here · Show the Calculation… · Highlight What It Depends On |
/// | `#BarGap#R`         | 3 px after Bar 5      | Use a Fixed Position Here · Select “Bar 5”                        |
/// | `0r`                | Same top as “48 Hz”   | Use a Fixed Position Here · Select “48 Hz”                        |
/// | `[MeasurePeakX]`    | moves with peak level | Use a Fixed Position Here · Show the Live Data                    |
///
/// "Change ‘Left’ for All … Layers…" turns the field into an editor of the shared value itself (an accent ring and
/// "Changing Left for 9 layers."): Return writes it, Esc goes back. "Show the Calculation…" shows the formula under
/// the row. The written text is in the tag's tooltip, and under the row with Rainmeter Details on.
final class LinkedValueTag: NSStackView {
    /// The tag.
    let pill: PillView
    /// The field showing the value in effect (nil for a tag beside another control).
    private(set) var field: ValueField?
    /// The field and the tag.
    let line = EditorStyle.hstack([], spacing: 5)
    /// After the tag, so a field of a fixed width and the tag keep to the left.
    private let lineSpacer = EditorStyle.spacer()
    /// The field is for text: it takes the room the tag leaves (see `fieldFillsLine`).
    private var fieldFills = false
    private weak var controller: InspectorWindowController?

    /// An option's value. `asControl`: it stands for the option's control and shows the value; otherwise it sits next
    /// to a control that shows the value, and names the shared value only.
    init(ctx: InspectorWindowController.PropertyContext, controller: InspectorWindowController, asControl: Bool = true) {
        self.controller = controller
        let link = controller.valueLink(ctx.raw, key: ctx.key, section: ctx.section)
        let named = controller.linkWords(link, section: ctx.section, key: ctx.key)
        let words = Self.tagWords(named, label: ctx.property.label)
        let number = OptionValue.number(ctx.resolved.trimmingCharacters(in: .whitespaces))
        let numeric = ctx.property.kind.isNumeric
        let showsField = asControl && (numeric ? number != nil : ctx.property.kind == .text || ctx.property.kind == .formula)
        let shownValue = asControl && !showsField ? controller.pillValue(ctx) : ""
        pill = PillView(name: words, value: shownValue)
        super.init(frame: .zero)
        setUp()
        let id = "\(ctx.section)/\(ctx.key)/pill"
        pill.identifier = NSUserInterfaceItemIdentifier(id)
        pill.toolTip = controller.linkTooltip(ctx.raw, resolved: ctx.resolved, words: named)
        if asControl { identifier = NSUserInterfaceItemIdentifier(ctx.property.key) }
        if showsField {
            let text = numeric ? (number.map { EditorStyle.number(Self.displayed($0, ctx.property.kind)) } ?? "") : ctx.resolved
            let f = numeric ? LinkedNumberField(text, placeholder: ctx.property.placeholder) : ValueField(text, placeholder: "")
            f.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/\(ctx.key)")
            f.toolTip = link.isCalculated ? "Nudging keeps the calculation." : pill.toolTip
            f.onCommit = { [weak controller] typed in
                guard let controller, !controller.inspectorState.isRebuilding else { return }
                controller.commitLinkedValue(ctx, typed: typed, numeric: numeric)
            }
            (f as? LinkedNumberField)?.onStep = { [weak controller] delta in
                guard let controller, let current = OptionValue.number(ctx.resolved) else { return }
                controller.commitLinkedValue(ctx, typed: GeometryEdit.format(Self.displayed(current, ctx.property.kind) + delta),
                                             numeric: true)
            }
            if numeric {
                f.widthAnchor.constraint(equalToConstant: 52).isActive = true
                f.alignment = .right
            }
            field = f
            line.insertArrangedSubview(f, at: 0)
            if !numeric { fieldFillsLine(f) }
        }
        let location = ctx.variable.flatMap { controller.skin?.sources.location(section: "Variables", key: $0) } ?? ctx.row?.location
        pill.menuProvider = { [weak controller, weak self] in
            guard let controller, let self else { return NSMenu() }
            return controller.linkMenu(link, tag: self, section: ctx.section, key: ctx.key, location: location,
                                       fixed: controller.detachedValue(ctx), ctx: ctx, geometry: nil)
        }
        if asControl, !showsField {
            controller.inspectorState.liveUpdates.append { [weak controller, weak pill] in
                guard let controller, let pill,
                      let fresh = controller.rows.first(where: { $0.key.caseInsensitiveCompare(ctx.key) == .orderedSame })
                else { return }
                var updated = ctx
                updated.row = fresh
                let value = controller.pillValue(updated)
                if pill.valueLabel.stringValue != value { pill.valueLabel.stringValue = value }
            }
        }
        addDetails(raw: ctx.raw, id: id, controller: controller, link: link, section: ctx.section, key: ctx.key,
                   write: { [weak controller] formula in
                       controller?.writeProperty(section: ctx.section, key: ctx.key, value: formula, variable: nil, label: ctx.label)
                   })
        if controller.inspectorState.variableEdit == id, let variable = link.variable { beginVariableEdit(variable) }
    }

    /// A layer's position or size (X, Y, W, H) written as a variable, a formula, relative to the previous layer or
    /// following live data; `current` is the value in effect.
    init(geometry m: Meter, key: String, raw: String, variable: String?, current: Double,
         controller: InspectorWindowController) {
        self.controller = controller
        let link = controller.valueLink(raw, key: key, section: m.name)
        let label = ["x": "X", "y": "Y", "w": "Width", "h": "Height"][key.lowercased()] ?? key
        let named = controller.linkWords(link, section: m.name, key: key)
        let words = Self.tagWords(named, label: label)
        pill = PillView(name: words, value: "")
        super.init(frame: .zero)
        setUp()
        let id = "\(m.name)/\(key)/pill"
        pill.identifier = NSUserInterfaceItemIdentifier(id)
        pill.toolTip = controller.linkTooltip(raw, resolved: EditorStyle.number(current), words: named)
        let f = LinkedNumberField(EditorStyle.number(current), placeholder: "0")
        f.identifier = NSUserInterfaceItemIdentifier("\(m.name)/\(key)")
        f.toolTip = link.isCalculated ? "Nudging keeps the calculation." : pill.toolTip
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let name = m.name
        f.onCommit = { [weak controller] typed in
            guard let controller, let n = Double(typed.trimmingCharacters(in: .whitespaces)) else {
                // A formula typed on purpose is written as typed.
                controller?.commitGeometry(name, key: key, value: typed)
                return
            }
            controller.commitGeometry(name, key: key, value: GeometryEdit.offset(raw, by: n - current))
        }
        f.onStep = { [weak controller] delta in controller?.commitGeometry(name, key: key, value: GeometryEdit.offset(raw, by: delta)) }
        field = f
        line.insertArrangedSubview(f, at: 0)
        let location = controller.skin?.sources.location(section: m.name, key: key)
        pill.menuProvider = { [weak controller, weak self] in
            guard let controller, let self else { return NSMenu() }
            return controller.linkMenu(link, tag: self, section: name, key: key, location: location,
                                       fixed: GeometryEdit.format(current), ctx: nil, geometry: (name, current))
        }
        addDetails(raw: raw, id: id, controller: controller, link: link, section: name, key: key,
                   write: { [weak controller] formula in controller?.commitGeometry(name, key: key, value: formula) })
        if controller.inspectorState.variableEdit == id, let variable = link.variable { beginVariableEdit(variable) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The tag's words, unless they only repeat the row's label ("Width 217 Width"): then "Shared", the tooltip and
    /// menu naming the shared value.
    static func tagWords(_ words: String, label: String) -> String {
        words.caseInsensitiveCompare(label) == .orderedSame ? "Shared" : words
    }

    override func layout() {
        super.layout()
        // Next to a field, the tag needs room for a few letters and its arrow; with less, only the field shows (its
        // tooltip still says what it is linked to). A field for text leaves the tag what it doesn't need itself.
        guard let field, !field.isHidden, bounds.width > 0 else { return }
        let hide = bounds.width - (fieldFills ? Self.minimumTextWidth : field.frame.width) - line.spacing < 40
        if pill.isHidden != hide { pill.isHidden = hide }
    }

    /// The narrowest a field for text gets beside its tag.
    static let minimumTextWidth: CGFloat = 60

    /// A field for text (not a number) has no width of its own: it takes the room the tag leaves. Beside the line's
    /// spacer, the two would share that room, and nothing says how (ambiguous: the field had shrunk out of sight).
    private func fieldFillsLine(_ field: NSTextField) {
        line.removeArrangedSubview(lineSpacer)
        lineSpacer.removeFromSuperview()
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTextWidth).isActive = true
        fieldFills = true
    }

    /// Degrees for angle options stored in radians; everything else as it is.
    static func displayed(_ value: Double, _ kind: EditorSchema.Kind) -> Double {
        if case .angle(let unit, _) = kind, unit == .radians { return value * 180 / .pi }
        return value
    }

    private func setUp() {
        orientation = .vertical
        alignment = .leading
        spacing = 4
        line.alignment = .centerY
        // In a narrow column the tag gives way rather than widening it (the field comes first and stays whole): it
        // is hidden when there is no room for it (see `layout`).
        line.setClippingResistancePriority(.init(49), for: .horizontal)
        line.addArrangedSubview(pill)
        line.addArrangedSubview(lineSpacer)
        addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// Under the row: the calculation ("Show the Calculation…"), and the text as written with Rainmeter Details.
    private func addDetails(raw: String, id: String, controller: InspectorWindowController, link: InspectorWindowController.ValueLink,
                            section: String, key: String, write: @escaping (String) -> Void) {
        if controller.inspectorState.openCalculations.contains(id) {
            let formula = ValueField(raw, placeholder: "Calculation", monospaced: true)
            formula.identifier = NSUserInterfaceItemIdentifier("\(id)/calculation")
            formula.onCommit = { [weak controller] v in
                guard let controller, !controller.inspectorState.isRebuilding else { return }
                write(v)
            }
            let caption = EditorStyle.label("Math on other values. Numbers and names of shared sizes work here.", size: 11,
                                            color: .tertiaryLabelColor)
            caption.maximumNumberOfLines = 3
            caption.cell?.wraps = true
            caption.lineBreakMode = .byWordWrapping
            addArrangedSubview(formula)
            addArrangedSubview(caption)
            formula.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            caption.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        } else if controller.app.state.editor.showIniNames {
            let written = EditorStyle.mono(raw, size: 10.5)
            written.toolTip = raw
            addArrangedSubview(written)
            written.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
    }

    /// "Change ‘Left’ for All 9 Layers…": the field edits the shared value itself.
    func beginVariableEdit(_ variable: String) {
        guard let controller, let skin = controller.skin else { return }
        let value = skin.inspectedVariables().first { $0.name.caseInsensitiveCompare(variable) == .orderedSame }?.raw ?? ""
        let editor: ValueField
        if let field {
            editor = field
            editor.stringValue = value
            editor.original = value
            editor.formatter = nil
        } else {
            editor = ValueField(value, placeholder: "Value")
            line.insertArrangedSubview(editor, at: 0)
            fieldFillsLine(editor)
            field = editor
        }
        editor.identifier = NSUserInterfaceItemIdentifier((pill.identifier?.rawValue ?? "pill") + "/edit")
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 2
        editor.layer?.cornerRadius = 5
        let users = controller.valueUsages(skin).variable(variable)?.sections ?? []
        let caption = EditorStyle.label("Changing \(ValueUsageIndex.humanizedVariable(variable)) for \(controller.usersPhrase(users)).",
                                        size: 11, color: .controlAccentColor)
        caption.identifier = NSUserInterfaceItemIdentifier("variable-edit-caption")
        addArrangedSubview(caption)
        let id = pill.identifier?.rawValue
        editor.onCommit = { [weak controller] v in
            guard let controller, !controller.inspectorState.isRebuilding else { return }
            controller.inspectorState.variableEdit = nil
            controller.writeLinkedValue(variable, value: v)
        }
        // ↑ and ↓ step the shared value too (not the layer's own option the field showed before), and stay in this mode.
        (editor as? LinkedNumberField)?.onStep = { [weak controller] delta in
            guard let controller, let skin = controller.skin else { return }
            let raw = skin.inspectedVariables().first { $0.name.caseInsensitiveCompare(variable) == .orderedSame }?.raw ?? value
            controller.inspectorState.variableEdit = id
            controller.writeLinkedValue(variable, value: GeometryEdit.offset(raw, by: delta))
        }
        let restore = { [weak controller] in
            // Not when the field goes away with a rebuild (a step written): the mode carries over to the new field.
            guard let controller, !controller.inspectorState.isRebuilding, controller.inspectorState.variableEdit == id else { return }
            controller.inspectorState.variableEdit = nil
            onNextTurn { controller.rebuildKeepingScroll() }
        }
        editor.onCancel = restore
        editor.onUnchanged = restore
        controller.window?.makeFirstResponder(editor)
    }
}

/// A number field whose ↑ and ↓ keys step the value (⇧: by 10) as well as typing it.
final class LinkedNumberField: ValueField {
    var onStep: ((Double) -> Void)?

    init(_ value: String, placeholder: String) {
        super.init(value, placeholder: placeholder)
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let shift = NSEvent.modifierFlags.contains(.shift)
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
            onStep?(shift || commandSelector == #selector(NSResponder.moveUpAndModifySelection(_:)) ? 10 : 1)
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
            onStep?(shift || commandSelector == #selector(NSResponder.moveDownAndModifySelection(_:)) ? -10 : -1)
            return true
        default:
            return super.control(control, textView: textView, doCommandBy: commandSelector)
        }
    }
}

/// The color panel for color controls and widget-page rows (`ColorEdit`): it reports to the editor that opened it,
/// as long as that editor exists, and writes what was picked when it closes. Opening it takes the panel from the
/// other pickers (the Shape editor's, the swatches' own), and they take it back the same way.
final class ScopedColorPicker: NSObject {
    static let shared = ScopedColorPicker()
    private(set) weak var owner: InspectorWindowController?
    private var observing = false

    func open(for owner: InspectorWindowController, color: NSColor) {
        ShapeColorPicker.shared.relinquish()
        InspectorColorPanel.shared.release()
        self.owner = owner
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(nil)
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.isContinuous = true
        if owner.app.presentsWindows { panel.orderFront(nil) }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(panelClosed), name: NSWindow.willCloseNotification,
                                                   object: panel)
        }
    }

    func release(_ owner: InspectorWindowController? = nil) {
        guard owner == nil || self.owner === owner else { return }
        self.owner = nil
    }

    @objc func colorPicked(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        owner?.previewColorEdit(RGBA(r: Double(c.redComponent) * 255, g: Double(c.greenComponent) * 255,
                                     b: Double(c.blueComponent) * 255, a: Double(c.alphaComponent) * 255))
    }

    @objc func panelClosed() { owner?.finishColorEdit() }
}

/// Colors, linked values and their menus (the inspector's, for `ColorControl`, `LinkedValueTag`, the widget page and
/// the Shape editor).
extension InspectorWindowController {
    // MARK: Colors

    /// The color behind the widget's layers as the editor shows it: the fill of the layer called Background, else
    /// the widget's own background color, else nothing (the swatch then shows the canvas backdrop's neutral).
    func widgetPanelColor() -> RGBA? {
        guard let skin else { return nil }
        if let name = skin.detectedBackgroundLayer(), let m = skin.meter(named: name) {
            if m.type == "shape", let raw = m.rawOption("Shape") {
                let resolved = skin.resolve(raw, in: m, sectionVariables: false)
                for segment in resolved.split(separator: "|") {
                    let t = segment.trimmingCharacters(in: .whitespaces)
                    let lower = t.lowercased()
                    if lower.hasPrefix("fill color"), let c = OptionValue.color(String(t.dropFirst("fill color".count))) {
                        return c
                    }
                    if lower.hasPrefix("fill lineargradient") || lower.hasPrefix("fill radialgradient"),
                       let option = t.split(separator: " ").dropFirst(2).first,
                       let gradient = m.rawOption(String(option)) {
                        let stops = skin.resolve(gradient, in: m, sectionVariables: false).split(separator: "|").dropFirst()
                        if let first = stops.first?.split(separator: ";").first, let c = OptionValue.color(String(first)) {
                            return c
                        }
                    }
                }
            }
            if m.solidColor.a > 0 { return m.solidColor }
        }
        // The widget's own background: a whole-widget color (halfway along its fade) or its picture's average color.
        return LayerThumbnails.widgetBackgroundColor(skin)
    }

    /// The name a color control shows (§7.4): the role of the shared color it uses, "Custom", "Default" or "None".
    func colorName(_ ctx: PropertyContext) -> String {
        guard ctx.isSet else { return InspectorWindowController.visibleDefaultColor(ctx.property) != nil ? "Default" : "None" }
        return colorRoleName(variable: ctx.variable, color: OptionValue.color(ctx.resolved)) ?? "Custom"
    }

    /// A color by the name the widget page gives it (§8.1.1): a shared color by its role ("Bar color", else its name
    /// in words), a color written directly by the role of its uses when the page lists it ("Background panel");
    /// nil when the page has no name for it (the control says "Custom").
    func colorRoleName(variable: String?, color: RGBA?) -> String? {
        guard let skin else { return variable.map(ValueUsageIndex.humanizedVariable) }
        let groups = valueUsages(skin).colorGroups(separate: inspectorState.separateColors,
                                                    includeInternal: app.state.editor.showIniNames)
        // A color is named the same here as on the widget page (its row's name, §7.4 and §13 task 10): the user finds
        // the row by it. The variable's own name is for the tooltip and Rainmeter Details.
        if let variable {
            let group = groups.first(where: { $0.variables.contains { $0.caseInsensitiveCompare(variable) == .orderedSame } })
            return group?.name ?? "Shared color"
        }
        guard let color, let group = groups.first(where: { $0.variables.isEmpty && $0.color == color }) else { return nil }
        return group.name
    }

    /// "#78C8FF · 100% opacity"; with Rainmeter Details "Accent · 120,200,255,255".
    func colorTooltip(_ color: RGBA?, ctx: PropertyContext?) -> String {
        guard let color else { return "Not set — pick a color to set it" }
        if app.state.editor.showIniNames, let ctx {
            return "\(ctx.variable ?? ctx.key) · \(ctx.isSet ? ctx.resolved : ctx.property.defaultValue)"
        }
        return "\(Self.hex(color)) · \(Int((color.a / 255 * 100).rounded()))% opacity"
    }

    static func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int(c.r.rounded()), Int(c.g.rounded()), Int(c.b.rounded()))
    }

    /// A small swatch image for menus: the color over the widget's panel color.
    func swatchImage(_ color: RGBA, size: NSSize = NSSize(width: 18, height: 12)) -> NSImage {
        let panel = widgetPanelColor()
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            (panel?.nsColor ?? NSColor(white: 0.85, alpha: 1)).setFill()
            path.fill()
            color.nsColor.setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.2).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    /// The color menu of a color control (§7.4).
    func colorMenu(_ ctx: PropertyContext, selection: [String]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let skin else { return menu }
        let index = valueUsages(skin)
        let groups = index.colorGroups(separate: inspectorState.separateColors, includeInternal: app.state.editor.showIniNames)
        let current = ctx.variable.flatMap { v in groups.first { $0.variables.contains { $0.caseInsensitiveCompare(v) == .orderedSame } } }
        let header = NSMenuItem(title: current.map { "\($0.name) · \(usersPhrase($0.sections, atLeast: $0.isAtLeast))" } ?? ctx.label,
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        func sectionTitle(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
            item.isEnabled = false
            menu.addItem(item)
        }
        let themes = groups.filter { !$0.variables.isEmpty }
        let literals = groups.filter { $0.variables.isEmpty }
        let write = { [weak self] (value: String) in
            self?.writeProperty(section: ctx.section, key: ctx.key, value: value, variable: nil, label: ctx.label,
                                selection: selection)
        }
        if !themes.isEmpty {
            menu.addItem(.separator())
            sectionTitle("THEME COLORS")
            for g in themes {
                let variable = g.variables[0]
                let item = ClosureMenuItem(g.name) { write("#\(variable)#") }
                item.image = swatchImage(g.color)
                item.state = g == current ? .on : .off
                item.toolTip = app.state.editor.showIniNames ? g.variables.joined(separator: ", ") : nil
                item.identifier = NSUserInterfaceItemIdentifier("theme-color-\(variable)")
                menu.addItem(item)
            }
        }
        if !literals.isEmpty {
            menu.addItem(.separator())
            sectionTitle("USED IN THIS WIDGET")
            for g in literals {
                let text = ColorText.format(g.color, like: ctx.isSet ? ctx.resolved : nil)
                let item = ClosureMenuItem(g.name) { write(text) }
                item.image = swatchImage(g.color)
                item.state = ctx.variable == nil && ctx.isSet && OptionValue.color(ctx.resolved).map(ValueUsageIndex.colorKey)
                    == ValueUsageIndex.colorKey(g.color) ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let custom = ClosureMenuItem("Custom Color…") { [weak self] in
            self?.startColorEdit(ColorEdit(target: .property(section: ctx.section, key: ctx.key, raw: ctx.raw,
                                                             variable: ctx.variable, label: ctx.label, selection: selection)),
                                 current: ctx.isSet ? OptionValue.color(ctx.resolved) : nil)
        }
        custom.identifier = NSUserInterfaceItemIdentifier("custom-color")
        menu.addItem(custom)
        if let variable = ctx.variable {
            let variables = current?.variables ?? [variable]
            let role = current?.name ?? "Shared color"
            let users = current?.sections ?? index.users(ofVariable: variable)
            let everywhere = ClosureMenuItem("Change ‘\(role)’ Everywhere (\(usersPhrase(users)))…") { [weak self] in
                self?.startColorEdit(ColorEdit(target: .variables(variables, role: role, users: users)),
                                     current: OptionValue.color(ctx.resolved))
            }
            everywhere.identifier = NSUserInterfaceItemIdentifier("change-everywhere")
            menu.addItem(everywhere)
        }
        if let color = ctx.isSet ? OptionValue.color(ctx.resolved) : nil {
            let hex = Self.hex(color)
            menu.addItem(ClosureMenuItem("Copy Color Code  (\(hex))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
            })
        }
        if differsFromItsLook(section: ctx.section, key: ctx.key) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Match the Others") { [weak self] in
                self?.matchTheOthers(section: ctx.section, key: ctx.key)
            })
        }
        return menu
    }

    // MARK: Linked values

    /// What a written value is linked to (docs/editor-friendly.md §7.3).
    enum ValueLink: Equatable {
        /// Exactly `#Var#`.
        case variable(String)
        /// `(#Var# + n)` / `(#Var# - n)`.
        case offset(String, Double)
        /// Any other calculation (formula, several variables).
        case calculated
        /// `nr` / `nR`: `after` is `R` (after the previous layer's right or bottom edge), else its left or top.
        case relative(amount: Double, after: Bool)
        /// Follows a data item (`[MeasurePeakX]`).
        case data(String)
        /// A plain value.
        case none

        var variable: String? {
            switch self {
            case .variable(let v), .offset(let v, _): return v
            default: return nil
            }
        }

        var isCalculated: Bool {
            switch self {
            case .calculated, .offset: return true
            default: return false
            }
        }
    }

    /// How a written value is linked.
    func valueLink(_ raw: String, key: String, section: String) -> ValueLink {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let v = wholeVariable(t) { return .variable(v) }
        let lower = key.lowercased()
        if lower == "x" || lower == "y", let last = t.last, last == "r" || last == "R" {
            let body = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
            let resolved = body.isEmpty ? "0" : (skin?.resolve(body, in: skin?.section(named: section), sectionVariables: true) ?? body)
            if let n = OptionValue.number(resolved) { return .relative(amount: n, after: last == "R") }
        }
        if let skin, t.contains("[") {
            var rest = Substring(t)
            while let open = rest.firstIndex(of: "[") {
                let after = rest.index(after: open)
                guard let close = rest[after...].firstIndex(of: "]") else { break }
                var name = rest[after..<close]
                if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
                if let m = skin.measure(named: String(name).trimmingCharacters(in: .whitespaces)) { return .data(m.name) }
                rest = rest[rest.index(after: close)...]
            }
        }
        if t.hasPrefix("("), t.hasSuffix(")") {
            let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            for op in [" + ", " - "] {
                let parts = inner.components(separatedBy: op)
                if parts.count == 2, let v = wholeVariable(parts[0].trimmingCharacters(in: .whitespaces)),
                   let n = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    return .offset(v, op == " + " ? n : -n)
                }
            }
            return .calculated
        }
        if t.contains("#") || LenientNumberFormatter.isExpression(t) { return .calculated }
        return .none
    }

    /// The previous layer a relative position follows (nil at the first layer).
    func previousLayer(_ section: String) -> Meter? {
        guard let skin, let i = skin.meters.firstIndex(where: { $0.name.caseInsensitiveCompare(section) == .orderedSame }),
              i > 0 else { return nil }
        let me = skin.meters[i]
        return skin.meters[..<i].last { ($0.container == nil) == (me.container == nil) }
    }

    /// The tag's words for a link.
    func linkWords(_ link: ValueLink, section: String, key: String) -> String {
        let n = EditorStyle.number
        let isX = key.caseInsensitiveCompare("X") == .orderedSame
        switch link {
        case .variable(let v):
            return ValueUsageIndex.humanizedVariable(v)
        case .offset(let v, let d):
            return "\(ValueUsageIndex.humanizedVariable(v)) \(d < 0 ? "−" : "+") \(n(abs(d)))"
        case .calculated:
            return "calculated"
        case .relative(let amount, let after):
            let anchor = previousLayer(section).map { displayName(ofSection: $0.name) } ?? "the widget's corner"
            if after {
                if amount == 0 { return isX ? "Right after \(anchor)" : "Right below \(anchor)" }
                return isX ? (amount > 0 ? "\(n(amount)) px after \(anchor)" : "\(n(-amount)) px into \(anchor)")
                    : (amount > 0 ? "\(n(amount)) px below \(anchor)" : "\(n(-amount)) px up into \(anchor)")
            }
            if amount == 0 { return isX ? "Same left as \(anchor)" : "Same top as \(anchor)" }
            return isX ? "\(n(abs(amount))) px \(amount > 0 ? "right" : "left") of \(anchor)"
                : "\(n(abs(amount))) px \(amount > 0 ? "below" : "above") the top of \(anchor)"
        case .data(let measure):
            return "moves with \(dataWords(measure))"
        case .none:
            return ""
        }
    }

    /// A data item in words inside a sentence ("peak level"): a calculation used for a position is named after the
    /// data it is calculated from.
    func dataWords(_ measure: String) -> String {
        guard let skin, var m = skin.measure(named: measure) else { return LayerNaming.humanized(measure).lowercased() }
        if m.type == "calc", let formula = m.rawOption("Formula") {
            let words = formula.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            if let source = words.lazy.compactMap({ skin.measure(named: String($0)) }).first(where: { $0 !== m }) { m = source }
        }
        let name = LayerNaming.data(m, in: skin).name
        let first = name.prefix { $0 != " " }
        if first.count > 1, first.allSatisfy({ $0.isUppercase || $0.isNumber }) { return name }
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    /// The tag's tooltip: what it means and the text as written.
    func linkTooltip(_ raw: String, resolved: String, words: String) -> String {
        "\(words.isEmpty ? resolved : words)\n\(raw)"
    }

    /// The tag's menu (§7.3).
    func linkMenu(_ link: ValueLink, tag: LinkedValueTag, section: String, key: String, location: IniSourceLocation?,
                  fixed: String?, ctx: PropertyContext?, geometry: (meter: String, current: Double)?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let fixedTitle: String
        switch link {
        case .relative, .data: fixedTitle = "Use a Fixed Position Here"
        default: fixedTitle = "Use a Fixed Number Here"
        }
        let useFixed = ClosureMenuItem(fixed.map { "\(fixedTitle) (\($0))" } ?? fixedTitle, enabled: fixed != nil) { [weak self] in
            guard let self, let fixed else { return }
            if let geometry {
                self.commitGeometry(geometry.meter, key: key, value: fixed)
            } else if let ctx {
                self.writeProperty(section: ctx.section, key: ctx.key, value: fixed, variable: nil, label: ctx.label)
            }
        }
        useFixed.identifier = NSUserInterfaceItemIdentifier("use-fixed")
        let id = tag.pill.identifier?.rawValue ?? ""
        switch link {
        case .variable(let v), .offset(let v, _):
            let users = (skin.map { valueUsages($0) })?.variable(v)?.sections ?? []
            let layers = layersReached(users)
            let title = changeSharedTitle(v, users: usersPhrase(users), many: layers.count > 1)
            let change = ClosureMenuItem(title) { [weak self, weak tag] in
                guard let self, let tag else { return }
                self.inspectorState.variableEdit = id
                tag.beginVariableEdit(v)
            }
            change.identifier = NSUserInterfaceItemIdentifier("change-shared")
            menu.addItem(change)
            menu.addItem(useFixed)
            if layers.count > 1 {
                menu.addItem(ClosureMenuItem("Highlight the \(Self.titleCase(usersPhrase(users)))") { [weak self] in
                    self?.canvas.relatedNames = layers
                })
            }
        case .calculated:
            menu.addItem(useFixed)
            let open = inspectorState.openCalculations.contains(id)
            menu.addItem(ClosureMenuItem(open ? "Hide the Calculation" : "Show the Calculation…") { [weak self] in
                guard let self else { return }
                if open { self.inspectorState.openCalculations.remove(id) } else { self.inspectorState.openCalculations.insert(id) }
                self.rebuildKeepingScroll()
            })
            let raw = ctx?.raw ?? (geometry.flatMap { g in self.skin?.meter(named: g.meter)?.rawOption(key) } ?? "")
            let depends = dependencies(of: raw)
            menu.addItem(ClosureMenuItem("Highlight What It Depends On", enabled: !depends.isEmpty) { [weak self] in
                self?.canvas.relatedNames = depends
            })
        case .relative:
            menu.addItem(useFixed)
            if let anchor = previousLayer(section) {
                menu.addItem(ClosureMenuItem("Select “\(displayName(ofSection: anchor.name).trimmingCharacters(in: CharacterSet(charactersIn: "“”")))”") { [weak self] in
                    self?.select(section: anchor.name)
                })
            }
        case .data(let measure):
            menu.addItem(useFixed)
            menu.addItem(ClosureMenuItem("Show the Live Data") { [weak self] in self?.select(section: measure) })
        case .none:
            menu.addItem(useFixed)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show in Code", enabled: location != nil) { [weak self] in self?.showInCode(location) })
        return menu
    }

    /// The layers a calculation depends on: those it names (`[Meter:X]`) and the others using its shared values.
    func dependencies(of raw: String) -> [String] {
        guard let skin else { return [] }
        let index = valueUsages(skin)
        var names: [String] = []
        for v in SkinInspection.referencedVariables(in: raw) { names += index.users(ofVariable: v) }
        for m in skin.meters where raw.range(of: "[\(m.name)", options: .caseInsensitive) != nil { names.append(m.name) }
        var seen: Set<String> = []
        return names.filter { skin.meter(named: $0) != nil && seen.insert($0.lowercased()).inserted }
    }

    /// A value typed over a linked value (§7.3): a number keeps the link (`GeometryEdit.offset`), anything else is
    /// written as typed — each where the selection says.
    func commitLinkedValue(_ ctx: PropertyContext, typed: String, numeric: Bool) {
        guard let skin else { return }
        let text = typed.trimmingCharacters(in: .whitespaces)
        if numeric, var n = Double(text), let current = OptionValue.number(ctx.resolved) {
            if case .angle(let unit, _) = ctx.property.kind, unit == .radians { n = n * .pi / 180 }
            let value = GeometryEdit.offset(ctx.raw, by: n - current)
            // One shared value that covers exactly the selection: the value itself changes.
            if let variable = ctx.variable,
               ScopeResolver(skin: skin, usages: valueUsages(skin)).target(section: ctx.section, key: ctx.key, selection: scopeSelection(for: ctx.section),
                                                variable: variable).scope == .sharedValue(variable) {
                return writeProperty(section: ctx.section, key: ctx.key, value: GeometryEdit.format(n), variable: variable,
                                     label: ctx.label)
            }
            return writeProperty(section: ctx.section, key: ctx.key, value: value, variable: nil, label: ctx.label)
        }
        writeProperty(section: ctx.section, key: ctx.key, value: text, variable: ctx.variable, label: ctx.label)
    }

    /// The value a tag shows when nothing beside it does: a formula's number, a variable's current value.
    func pillValue(_ ctx: PropertyContext) -> String {
        let resolved = ctx.resolved.trimmingCharacters(in: .whitespaces)
        if case .angle(let unit, _) = ctx.property.kind, let n = OptionValue.number(resolved) {
            return EditorStyle.number(unit == .radians ? n * 180 / .pi : n) + "°"
        }
        if ctx.property.kind.isNumeric || ctx.property.kind.isBool || ctx.property.kind.choices != nil,
           let n = OptionValue.number(resolved) {
            return EditorStyle.number(n)
        }
        return resolved.count > 28 ? String(resolved.prefix(27)) + "…" : resolved
    }

    /// The fixed value "Use a Fixed Number Here" writes (nil when there is nothing to write).
    func detachedValue(_ ctx: PropertyContext) -> String? {
        let resolved = ctx.resolved.trimmingCharacters(in: .whitespaces)
        guard !resolved.isEmpty else { return nil }
        switch ctx.property.kind {
        case .number, .percent255, .bool:
            return OptionValue.number(resolved).map { GeometryEdit.format($0) }
        case .angle:
            return OptionValue.number(resolved).map { String(format: "%g", $0) }
        default:
            return resolved.contains("#") || resolved.contains("[") ? nil : resolved
        }
    }

    /// A tag's menu for the Shape editor's values: change the shared value / show the calculation, use a fixed
    /// number, show in code.
    func pillMenu(variable: String?, detach: String?, location: IniSourceLocation?, edit: @escaping () -> Void,
                  detachAction: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let variable {
            menu.addItem(ClosureMenuItem("Change ‘\(ValueUsageIndex.humanizedVariable(variable))’…", handler: edit))
        } else {
            menu.addItem(ClosureMenuItem("Show the Calculation…", handler: edit))
        }
        let detachItem = ClosureMenuItem(detach.map { "Use a Fixed Number Here (\($0.count > 24 ? String($0.prefix(23)) + "…" : $0))" }
                                            ?? "Use a Fixed Number Here", enabled: detach != nil, handler: detachAction)
        detachItem.toolTip = "Writes the current value itself instead of the \(variable == nil ? "calculation" : "shared value")"
        menu.addItem(detachItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show in Code", enabled: location != nil) { [weak self] in
            self?.showInCode(location)
        })
        return menu
    }

    /// Replaces a tag by a field for its shared value (or its calculation); Return writes, Esc goes back.
    func editPillInline(slot: NSStackView, pill: PillView, variable: String?, raw: String, write: @escaping (String) -> Void) {
        let field = ValueField(raw, placeholder: variable.map { "Value of \(ValueUsageIndex.humanizedVariable($0))" } ?? "Calculation",
                               monospaced: variable == nil)
        field.identifier = NSUserInterfaceItemIdentifier((pill.identifier?.rawValue ?? "pill") + "/edit")
        field.toolTip = variable.map { "Changes \(ValueUsageIndex.humanizedVariable($0)) everywhere it is used" } ?? "The calculation, as written"
        pill.isHidden = true
        slot.insertArrangedSubview(field, at: 0)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        func restore() {
            field.removeFromSuperview()
            pill.isHidden = false
        }
        field.onCommit = { [weak self] v in
            guard let self, !self.inspectorState.isRebuilding else { return }
            write(v)
        }
        field.onCancel = { onNextTurn { restore() } }
        field.onUnchanged = { onNextTurn { restore() } }
        window?.makeFirstResponder(field)
    }

    /// Starts editing a tag's shared value or calculation in place (self-tests: what the menu's first item does).
    @discardableResult
    func editPill(_ key: String) -> ValueField? {
        guard let pill = inspectorStack.findSubview(where: { ($0 as? PillView)?.identifier?.rawValue.hasSuffix("/\(key)/pill") == true })
                as? PillView,
              let item = pill.menuProvider?().items.first as? ClosureMenuItem else { return nil }
        _ = item.target?.perform(item.action)
        return inspectorStack.findSubview(where: { $0.identifier?.rawValue == (pill.identifier?.rawValue ?? "") + "/edit" }) as? ValueField
    }

    /// Runs a tag's menu item by title prefix (self-tests: "Use a Fixed Number Here", "Show in Code").
    @discardableResult
    func choosePillMenuItem(_ key: String, _ title: String) -> Bool {
        guard let pill = inspectorStack.findSubview(where: { ($0 as? PillView)?.identifier?.rawValue.hasSuffix("/\(key)/pill") == true })
                as? PillView,
              let item = pill.menuProvider?().items.first(where: { $0.title.hasPrefix(title) }), item.isEnabled else { return false }
        _ = item.target?.perform(item.action)
        return true
    }
}

// MARK: - Grid rows

/// One row of a card's label | control grid.
struct InspectorRow {
    /// Right-aligned secondary label (nil: the control stands alone, e.g. a checkbox).
    var label: NSView?
    var control: NSView
    /// Spans both columns (notes, lists, the Shape editor).
    var fullWidth = false

    init(label: NSView?, control: NSView, fullWidth: Bool = false) {
        self.label = label
        self.control = control
        self.fullWidth = fullWidth
    }
}

extension EditorStyle {
    /// Width of the label column of every card (so cards line up).
    static let labelColumnWidth: CGFloat = 86

    /// A card's label | control grid: right-aligned labels, controls filling the rest; each label is vertically
    /// centred on the first line of its control.
    static func grid(_ rows: [InspectorRow]) -> NSGridView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 10
        grid.rowSpacing = 9
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = labelColumnWidth
        grid.column(at: 1).xPlacement = .fill
        for r in rows {
            if r.fullWidth {
                let row = grid.addRow(with: [r.control, NSGridCell.emptyContentView])
                row.mergeCells(in: NSRange(location: 0, length: 2))
                row.yPlacement = .top
                row.cell(at: 0).xPlacement = .fill
                continue
            }
            let line = firstLineHeight(of: r.control)
            let label = r.label.map { labelCell($0, height: line) } ?? NSGridCell.emptyContentView
            let row = grid.addRow(with: [label, r.control])
            row.yPlacement = .top
            // A stack of lines in a row made taller by its label leaves the room under its last line: pulling that line
            // down as hard as the line hugs its own views (250), it could give it the room or not — an action's
            // "Edit in Code ›" beside a label of three lines was one height or another (ambiguous).
            if let stack = r.control as? NSStackView, stack.orientation == .vertical {
                stack.setHuggingPriority(.defaultLow - 1, for: .vertical)
            }
        }
        // Each row hugs its cells at this priority: a notch under the controls' own (750), so a control in a row made
        // taller by its label keeps its height at the top. At the same priority either could give way to the other —
        // the control stretched to the row or not, from one window to the next (ambiguous).
        grid.setContentHuggingPriority(.defaultHigh - 1, for: .vertical)
        return grid
    }

    /// The height of a control's first line (a vertical stack's first arranged view, the tallest view of a
    /// horizontal one), for aligning its label. Controls answer with their intrinsic height, which is cheap; only
    /// other views are laid out (`fittingSize`, a whole Auto Layout pass each).
    static func firstLineHeight(of view: NSView) -> CGFloat {
        func clamp(_ h: CGFloat) -> CGFloat { h > 0 ? min(h, 32) : 22 }
        if let stack = view as? NSStackView {
            let shown = stack.arrangedSubviews.filter { !$0.isHidden }
            if stack.orientation == .vertical, let first = shown.first { return firstLineHeight(of: first) }
            if stack.orientation == .horizontal, !shown.isEmpty {
                let tallest = shown.map { $0 is NSStackView || $0 is NSControl ? firstLineHeight(of: $0) : $0.fittingSize.height }.max() ?? 0
                return clamp(tallest + stack.edgeInsets.top + stack.edgeInsets.bottom)
            }
        }
        if view is NSControl {
            let intrinsic = view.intrinsicContentSize.height
            if intrinsic != NSView.noIntrinsicMetric, intrinsic > 0 { return clamp(intrinsic) }
        }
        return clamp(view.fittingSize.height)
    }

    /// A label centred in a box as tall as the control's first line.
    static func labelCell(_ label: NSView, height: CGFloat) -> NSView {
        let labelHeight = label.fittingSize.height
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: labelColumnWidth),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: max(height, labelHeight)),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: box.topAnchor, constant: height / 2).withPriority(.defaultHigh),
            label.topAnchor.constraint(greaterThanOrEqualTo: box.topAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor),
        ])
        return box
    }

    /// The right-aligned secondary label of a row; with `key` (Settings ▸ Show INI option names) the option name
    /// in small mono type under it.
    static func rowLabel(_ text: String, key: String?, tooltip: String?, identifier: Bool = false) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.maximumNumberOfLines = identifier ? 1 : 2
        if identifier {
            // A name (a variable): one line, shortened in the middle rather than broken inside a word.
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.wraps = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: labelColumnWidth).isActive = true
        }
        label.preferredMaxLayoutWidth = labelColumnWidth
        label.isSelectable = false
        label.toolTip = tooltip
        guard let key else { return label }
        // The words keep their width (at most the column, where they wrap); the option name under them is the one
        // shortened when it is longer.
        if !identifier { label.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let keyLabel = mono(key, size: 9.5, color: .tertiaryLabelColor)
        keyLabel.alignment = .right
        if keyLabel.intrinsicContentSize.width <= labelColumnWidth {
            keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        } else {
            // Longer than the column ("DefaultUpdateDivider"): broken between its words, never shortened.
            keyLabel.stringValue = wordBreakable(key)
            keyLabel.cell?.wraps = true
            keyLabel.lineBreakMode = .byWordWrapping
            keyLabel.maximumNumberOfLines = 3
            keyLabel.preferredMaxLayoutWidth = labelColumnWidth
            keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            keyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: labelColumnWidth).isActive = true
        }
        keyLabel.toolTip = tooltip
        let stack = vstack([label, keyLabel], spacing: 0)
        stack.alignment = .trailing
        stack.toolTip = tooltip
        return stack
    }

    /// An option name that may break between its words: a zero-width space before each capital that starts a word
    /// ("Default·Update·Divider", "Font·Effect·Color"; "SkinWidth" stays whole below the column's width).
    static func wordBreakable(_ key: String) -> String {
        var out = ""
        let chars = Array(key)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase || (i + 1 < chars.count && chars[i + 1].isLowercase && chars[i - 1].isUppercase) {
                out.append("\u{200B}")
            }
            out.append(c)
        }
        return out
    }

    /// An inline warning under a control (an invalid value, a missing file).
    static func issue(_ text: String, width: CGFloat) -> NSView {
        let icon = NSImageView(image: image("exclamationmark.triangle.fill", size: 10, weight: .semibold) ?? NSImage())
        icon.contentTintColor = .systemOrange
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = max(width - 16, 60)
        label.isSelectable = false
        let row = hstack([icon, label], spacing: 4, alignment: .top)
        row.identifier = NSUserInterfaceItemIdentifier("issue")
        row.setAccessibilityLabel("Warning: \(text)")
        return row
    }

    /// "from StyleX": where an inherited value is defined. Click for the row menu.
    static func originBadge(_ style: String) -> NSButton {
        let b = NSButton(title: "from \(style)", target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 10.5, weight: .medium)
        b.contentTintColor = NSColor.systemPurple.withAlphaComponent(0.85)
        b.image = image("arrow.turn.down.right", size: 8.5, weight: .semibold)
        b.imagePosition = .imageLeading
        b.toolTip = "Defined in the shared style \(style) — changes apply to every layer using it"
        b.identifier = NSUserInterfaceItemIdentifier("origin-badge")
        return b
    }

    /// A disclosure line ("Caps and join ›").
    static func disclosure(_ title: String, open: Bool) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 11.5, weight: .medium)
        b.contentTintColor = .secondaryLabelColor
        b.image = image(open ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
        b.imagePosition = .imageLeading
        return b
    }

    /// A small secondary caption ("X", "W") before a compact field.
    static func caption(_ text: String) -> NSTextField {
        let l = label(text, size: 10.5, weight: .semibold, color: .tertiaryLabelColor)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    /// Two controls side by side, equally wide (X Y, W H).
    static func pair(_ a: NSView, _ b: NSView) -> NSStackView {
        let row = hstack([a, b], spacing: 10, alignment: .top)
        row.distribution = .fillEqually
        return row
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}

extension NSView {
    /// Every descendant matching `predicate`, depth first.
    func subviewsMatching(_ predicate: (NSView) -> Bool) -> [NSView] {
        var result: [NSView] = []
        for v in subviews {
            if predicate(v) { result.append(v) }
            result += v.subviewsMatching(predicate)
        }
        return result
    }
}
