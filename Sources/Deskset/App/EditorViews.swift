import AppKit
import DesksetCore

/// Small building blocks of the skin editor's look: cards, color swatches, fields, captions, the toast.
enum EditorStyle {
    static let inspectorWidth: CGFloat = 316
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    /// Width of the control column of a card grid in the narrowest inspector: the pane's minimum width less the
    /// scroller (legacy scrollers take room, overlay ones do not), the inspector's margins, the card's padding, the
    /// label column and the column gap. Controls are laid out for it, so what a layer shows never widens the pane
    /// and wrapping text does not depend on which layers were shown before.
    static func inspectorControlWidth(scrollerStyle: NSScroller.Style = NSScroller.preferredScrollerStyle) -> CGFloat {
        let content = NSScrollView.contentSize(forFrameSize: NSSize(width: inspectorWidth, height: 400), horizontalScrollerClass: nil,
                                               verticalScrollerClass: NSScroller.self, borderType: .noBorder,
                                               controlSize: .regular, scrollerStyle: scrollerStyle).width
        return content - 32 - 2 * cardPadding - labelColumnWidth - 10
    }

    /// The narrowest control column there is (legacy scrollers): every control must fit it.
    static var minimumControlWidth: CGFloat { inspectorControlWidth(scrollerStyle: .legacy) }

    /// Lets content give way instead of widening the pane it is in. The split view holds the canvas's width at
    /// priority 249, so anything that resists compression more strongly (every control does, at 750) pushes the
    /// divider when it does not fit. This maps the horizontal compression resistance of every view under `root`
    /// linearly into 51…239 (in the same order, so what gave way first still does; above the fitting-size priority 50,
    /// so fitting sizes are unchanged) and lets stacks clip, at 239, what cannot shrink. Required priorities (fixed
    /// widths, captions) stay: controls are sized to fit `minimumControlWidth`.
    static func yieldWidth(_ root: NSView) {
        let floor: Float = 51, ceiling: Float = 239
        func lowered(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint.Priority? {
            guard p.rawValue > floor, p < .required else { return nil }
            return .init(floor + (p.rawValue - floor) * (ceiling - floor) / (NSLayoutConstraint.Priority.required.rawValue - floor))
        }
        func visit(_ view: NSView) {
            if let p = lowered(view.contentCompressionResistancePriority(for: .horizontal)) {
                view.setContentCompressionResistancePriority(p, for: .horizontal)
            }
            if let stack = view as? NSStackView, stack.clippingResistancePriority(for: .horizontal).rawValue > ceiling {
                stack.setClippingResistancePriority(.init(ceiling), for: .horizontal)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
    }

    /// Uppercase, slightly tracked section title.
    static func cardTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.8,
        ])
        return label
    }

    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func mono(_ text: String, size: CGFloat = 11, color: NSColor = .tertiaryLabelColor) -> NSTextField {
        let label = self.label(text, size: size, color: color)
        label.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        return label
    }

    /// An editable value field: rounded, quiet, monospaced (option values are code).
    static func field(_ value: String, placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = alignment
        return s
    }

    /// Makes a row's top and bottom insets hold. Across its orientation NSStackView keeps its insets only at its hugging
    /// priority (250), where every view pulls the row's edges to its own: in a row whose views differ in height, the
    /// shorter ones take the tallest one's inset away — all of it, or with two views any part of it, which AppKit
    /// settles one way or another from one window to the next (ambiguous). Call it once the row holds its views.
    static func holdVerticalInsets(_ row: NSStackView) {
        for view in row.arrangedSubviews {
            view.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: row.edgeInsets.top).isActive = true
            row.bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor, constant: row.edgeInsets.bottom).isActive = true
        }
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    /// SF Symbol for a section in the layer list and the inspector header.
    static func symbol(for kind: InspectedSectionKind?, type: String) -> String {
        switch kind {
        case .rainmeter?: return "gearshape"
        case .variables?: return "slider.horizontal.3"
        case .metadata?: return "info.circle"
        case .other?: return "paintbrush"
        case .measure?: return "waveform.path.ecg"
        case .meter?, nil:
            switch type {
            case "string": return "textformat"
            case "image", "bitmap": return "photo"
            case "button": return "hand.tap"
            case "bar": return "chart.bar.fill"
            case "histogram": return "chart.bar.xaxis"
            case "line": return "chart.xyaxis.line"
            case "roundline", "rotator": return "gauge.with.dots.needle.33percent"
            case "shape": return "square.on.circle"
            default: return "square.dashed"
            }
        }
    }

    static func image(_ symbol: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// Readable number for live values.
    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "\(v)" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        return abs(v) >= 100 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    }

    /// A section name without the customary `Meter` / `Measure` prefix: MeterCPUBar → CPUBar.
    static func displayName(_ name: String) -> String {
        for prefix in ["Measure", "Meter"] where name.count > prefix.count && name.hasPrefix(prefix) {
            let next = name[name.index(name.startIndex, offsetBy: prefix.count)]
            if next.isUppercase || next.isNumber || next == "_" {
                return String(name.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            }
        }
        return name
    }

    /// A measure described in plain words, with its Total / InvertMeasure taken into account.
    static func describe(_ m: Measure) -> (title: String, symbol: String) {
        EditorSchema.describeMeasure(type: m.type, plugin: m.rawOption("Plugin"),
                                     total: m.bool("Total", false), invert: m.bool("InvertMeasure", false))
    }

    /// Short live value for the layer list: 20779171840 → 20.8 G.
    static func compact(_ v: Double) -> String {
        guard v.isFinite else { return "\(v)" }
        let a = abs(v)
        for (limit, suffix) in [(1e12, "T"), (1e9, "G"), (1e6, "M"), (1e4, "K")] where a >= limit {
            return String(format: "%.1f %@", v / limit, suffix)
        }
        return number(v)
    }

    /// True for options whose value is a color (by name, as skins use them).
    static func isColorKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.hasSuffix("color") || k.contains("color2") || k == "solidcolor" || k == "solidcolor2"
            || k.hasPrefix("fontcolor") || k.hasPrefix("barcolor") || k.hasPrefix("linecolor")
    }
}

/// A rounded card: a quiet surface that groups related options.
final class EditorCard: NSView {
    let content: NSStackView

    init(title: String?, views: [NSView]) {
        var all = views
        if let title { all.insert(EditorStyle.cardTitle(title), at: 0) }
        content = EditorStyle.vstack(all, spacing: 10)
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: EditorStyle.cardPadding, left: EditorStyle.cardPadding,
                                          bottom: EditorStyle.cardPadding, right: EditorStyle.cardPadding)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in views { v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * EditorStyle.cardPadding).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Adds a view under the others (a card built in parts), as `init` places its views.
    func append(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * EditorStyle.cardPadding).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: EditorStyle.cardRadius,
                                yRadius: EditorStyle.cardRadius)
        (dark ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 1, alpha: 0.9)).setFill()
        path.fill()
        (dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.075)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// A color swatch (with a checkerboard under transparent colors). Click to pick a color.
final class SwatchButton: NSControl {
    var color: RGBA? { didSet { needsDisplay = true } }
    /// Drawn behind the color instead of the checkerboard: the widget's panel color, so the swatch shows the color
    /// as it looks on the widget (docs/editor-friendly.md §7.4).
    var backdrop: RGBA? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 7 { didSet { needsDisplay = true } }
    /// The color is the default in effect for an option that is not set: drawn with a dashed rim.
    var isDefault = false {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(isDefault ? "Color (default)" : "Color")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Color")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let backdrop {
            NSColor(white: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.2 : 0.9, alpha: 1).setFill()
            r.fill()
            backdrop.nsColor.setFill()
            r.fill()
        } else {
            NSColor.white.setFill()
            r.fill()
            NSColor(white: 0.82, alpha: 1).setFill()
            let s: CGFloat = 6
            var y = r.minY, row = 0
            while y < r.maxY {
                var x = r.minX + (row % 2 == 0 ? 0 : s)
                while x < r.maxX { NSRect(x: x, y: y, width: s, height: s).fill(); x += 2 * s }
                y += s
                row += 1
            }
        }
        if let color {
            color.nsColor.setFill()
            r.fill()
        } else {
            // Not set: a white well with a diagonal stroke.
            NSColor.white.setFill()
            r.fill()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: r.minX + 4, y: r.minY + 4))
            slash.line(to: NSPoint(x: r.maxX - 4, y: r.maxY - 4))
            slash.lineWidth = 1.5
            NSColor.systemRed.withAlphaComponent(0.7).setStroke()
            slash.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (backdrop != nil && dark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.18)).setStroke()
        path.lineWidth = 1
        if isDefault {
            // Not set: a dashed rim, inside a gap, around the default color.
            path.setLineDash([2.5, 2], count: 2, phase: 0)
            NSColor.secondaryLabelColor.setStroke()
            path.lineWidth = 1.5
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A button of a toast: "Undo", "Apply to All 16 Bars", "Stretch Background".
struct ToastAction {
    var title: String
    var handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.title = title
        self.handler = handler
    }
}

/// A capsule that fades in over the canvas to confirm a change (or report a problem), then fades out. Its buttons
/// ("[Apply to All 16 Bars] [Undo]", docs/editor-friendly.md §10) keep it up longer and hide it when clicked.
final class ToastView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let row: NSStackView
    private var generation = 0
    /// The buttons of the toast showing now, first to last.
    private(set) var buttons: [NSButton] = []
    private var handlers: [() -> Void] = []

    override init(frame: NSRect) {
        row = EditorStyle.hstack([], spacing: 6)
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        alphaValue = 0
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        // A picture from the start: without one the icon has no size, and nor has the toast before its first words.
        icon.image = Self.symbol(error: false)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
        // (The icon is shorter than the words.)
        EditorStyle.holdVerticalInsets(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func symbol(error: Bool) -> NSImage? {
        EditorStyle.image(error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", size: 12, weight: .semibold)
    }

    private(set) var text = ""

    /// A toast with buttons after its words: each runs its action and hides the toast.
    func show(_ text: String, actions: [ToastAction]) {
        present(text, error: false, actions: actions)
    }

    func show(_ text: String, error: Bool = false) {
        present(text, error: error, actions: [])
    }

    /// The buttons of the toast showing now (none once it is hidden).
    var shownActions: [ToastAction] { isShowing ? actions : [] }
    private var actions: [ToastAction] = []

    private func present(_ text: String, error: Bool, actions: [ToastAction]) {
        self.text = text
        self.actions = actions
        label.stringValue = text
        icon.image = Self.symbol(error: error)
        icon.contentTintColor = error ? .systemOrange : .systemGreen
        for b in buttons { b.removeFromSuperview() }
        handlers = actions.map(\.handler)
        buttons = actions.enumerated().map { i, action in
            let b = NSButton(title: action.title, target: self, action: #selector(buttonClicked(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(b)
            return b
        }
        row.edgeInsets.right = buttons.isEmpty ? 14 : 8
        generation += 1
        let current = generation
        isShowing = true
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        let seconds: Double = actions.isEmpty ? (error ? 4 : 2.2) : 6
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    /// Whether a toast is up (from `show` until `hide`): only then do its buttons take clicks.
    private(set) var isShowing = false

    /// Fades the toast out. Its buttons stop working at once — a fading or faded toast is not a trap of invisible
    /// buttons over the canvas — and it leaves the view hierarchy's clicks once the fade ends.
    func hide() {
        generation += 1
        let current = generation
        isShowing = false
        handlers = []
        actions = []
        for b in buttons { b.isEnabled = false }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; self.animator().alphaValue = 0 }, completionHandler: {
            [weak self] in
            // A toast shown again during the fade stays.
            guard let self, self.generation == current else { return }
            self.isHidden = true
        })
    }

    /// Clicks pass through a toast that is not showing (it may still be fading out).
    override func hitTest(_ point: NSPoint) -> NSView? {
        isShowing ? super.hitTest(point) : nil
    }

    /// The button titled `title` of the toast showing now (nil once it is hidden).
    func button(_ title: String) -> NSButton? { isShowing ? buttons.first { $0.title == title } : nil }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard isShowing, buttons.contains(where: { $0 === sender }), sender.tag >= 0, sender.tag < handlers.count
        else { return }
        let handler = handlers[sender.tag]
        hide()
        handler()
    }
}

/// The floating zoom control at the bottom of the canvas.
final class ZoomPill: NSVisualEffectView {
    let label = NSTextField(labelWithString: "100%")

    init(target: AnyObject, zoomOut: Selector, zoomIn: Selector, actual: Selector, fit: Selector) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        func button(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
            let b = NSButton(image: EditorStyle.image(symbol, size: 12, weight: .medium) ?? NSImage(), target: target,
                             action: action)
            b.isBordered = false
            b.toolTip = tip
            b.contentTintColor = .secondaryLabelColor
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            return b
        }
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let click = NSClickGestureRecognizer(target: target, action: actual)
        label.addGestureRecognizer(click)
        label.toolTip = "Actual size (⌘0)"
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 14).isActive = true
        // "Zoom to Fit" in words (§9.10): it shows the widget and whatever is drawn outside it.
        let fitButton = NSButton(title: "Zoom to Fit", target: target, action: fit)
        fitButton.isBordered = false
        fitButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        fitButton.contentTintColor = .secondaryLabelColor
        fitButton.toolTip = "Show the whole widget (⌘9)"
        let row = EditorStyle.hstack([button("minus", zoomOut, "Zoom out (⌘−)"), label, button("plus", zoomIn, "Zoom in (⌘+)"),
                                      divider, fitButton], spacing: 4)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A scroll view whose scrollers always float over its content (overlay), whatever the Mac's setting: the layer list,
/// whose rows are laid out to read whole at the sidebar's width, and the canvas. Legacy scrollers (a mouse connected,
/// or Show scroll bars set to Always) take room at the right. AppKit sets every scroll view's style again when that
/// setting changes, a mouse comes or goes, or a new process learns which it has, so the style is kept here rather
/// than set once.
final class OverlayScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}
