import AppKit
import DesksetCore

/// The color popover (a real `NSPopover`): its title names what the color paints ("Memory ring", in the serif), with
/// the color's hex and how many parts it paints under it; the widget's own colors; the Mac's colors, the first being
/// the accent that follows the Mac; recent colors; the opacity; the eyedropper, a color field that takes `#RGB`,
/// `#RRGGBB`, `#RRGGBBAA`, what Figma copies and the skin's own `R,G,B[,A]` (and shows the color in the file's own
/// notation), and More Colors… (the system color panel). Every pick shows at once (`onPreview`); closing the popover —
/// Done, Esc or a click outside — hands the last pick over as one change (`onClose`).
final class StudioColorPopover: NSViewController, NSPopoverDelegate, NSTextFieldDelegate {
    struct Target {
        var title: String
        var color: RGBA
        /// The color as the file writes it ("52,199,89").
        var written: String
        var parts: Int
        var acceptsAlpha: Bool
        /// The field shows the file's own notation (a Rainmeter skin, or Rainmeter details on); else `#RRGGBB` (§3.3:
        /// no R,G,B text by default). What is written keeps the file's notation either way.
        var showsNotation = true
    }

    /// A Mac color: its name in English (for the confirmation) and the color.
    struct MacColor {
        var name: String
        var color: NSColor
    }

    let target: Target
    let widgetColors: [RGBA]
    let presentsWindows: Bool
    var onPreview: ((RGBA) -> Void)?
    /// The last pick (nil: nothing changed) and its name when it was a named Mac color.
    var onClose: ((RGBA?, String?) -> Void)?
    private(set) var picked: RGBA?
    private(set) var pickedName: String?
    let popover = NSPopover()
    /// The page item whose swatch it opened from ("colors", or an option's row).
    var anchorItem = "colors"
    private var closed = false
    private var usesColorPanel = false

    // The views (kept for the self-tests).
    let titleLabel = NSTextField(labelWithString: "")
    let hexLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(labelWithString: "")
    private(set) var widgetSwatches: [StudioColorDot] = []
    private(set) var macSwatches: [StudioColorDot] = []
    private(set) var recentSwatches: [StudioColorDot] = []
    let accentDot = StudioColorDot(color: .controlAccentColor, accent: true)
    let accentLabel = NSTextField(labelWithString: "")
    let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let opacityLabel = NSTextField(labelWithString: "")
    let field = NSTextField(string: "")
    let eyedropper = NSButton(title: "", target: nil, action: nil)
    let moreColors = NSButton(title: "", target: nil, action: nil)
    private var headings: [NSTextField] = []
    private let divider = NSBox()

    /// The Mac's colors, as the design lays them out: two rows of seven.
    static let macColors: [MacColor] = [
        MacColor(name: "red", color: .systemRed), MacColor(name: "orange", color: .systemOrange),
        MacColor(name: "yellow", color: .systemYellow), MacColor(name: "green", color: .systemGreen),
        MacColor(name: "mint", color: .systemMint), MacColor(name: "teal", color: .systemTeal),
        MacColor(name: "cyan", color: .systemCyan), MacColor(name: "blue", color: .systemBlue),
        MacColor(name: "indigo", color: .systemIndigo), MacColor(name: "purple", color: .systemPurple),
        MacColor(name: "pink", color: .systemPink), MacColor(name: "brown", color: .systemBrown),
        MacColor(name: "gray", color: .systemGray), MacColor(name: "black", color: .labelColor),
    ]

    /// Recent colors, newest first (the app's defaults; only in memory while headless).
    static var recentInMemory: [RGBA] = []
    static let recentKey = "StudioRecentColors"

    init(target: Target, widgetColors: [RGBA], presentsWindows: Bool) {
        self.target = target
        var seen: Set<String> = []
        self.widgetColors = widgetColors.filter { seen.insert(ValueUsageIndex.colorKey($0)).inserted }.prefix(7).map { $0 }
        self.presentsWindows = presentsWindows
        super.init(nibName: nil, bundle: nil)
        popover.contentViewController = self
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = presentsWindows
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let width: CGFloat = 272

    override func loadView() {
        let v = StudioPopoverContentView()
        titleLabel.font = StudioPageStyle.titleFont(15)
        hexLabel.font = StudioPageStyle.monospaced(11.5, weight: .medium)
        noteLabel.font = StudioPageStyle.noteFont
        noteLabel.textColor = StudioPageStyle.quietInk
        for l in [titleLabel, hexLabel, noteLabel] { v.addSubview(l) }
        func heading(_ key: StudioText.Key) -> NSTextField {
            let h = StudioPageStyle.label(StudioText[key], font: .systemFont(ofSize: 11, weight: .semibold))
            headings.append(h)
            v.addSubview(h)
            return h
        }
        _ = heading(.colorInWidget)
        for c in widgetColors {
            let dot = StudioColorDot(color: StudioPageStyle.color(c))
            dot.onClick = { [weak self] in self?.pick(c, name: nil) }
            widgetSwatches.append(dot)
            v.addSubview(dot)
        }
        _ = heading(.colorMac)
        accentDot.onClick = { [weak self] in self?.pickAccent() }
        accentDot.setAccessibilityLabel(StudioText[.colorAccent])
        v.addSubview(accentDot)
        accentLabel.stringValue = StudioText[.colorAccent]
        accentLabel.font = StudioPageStyle.noteFont
        accentLabel.textColor = StudioPageStyle.quietInk
        v.addSubview(accentLabel)
        for mac in Self.macColors {
            let dot = StudioColorDot(color: mac.color)
            dot.onClick = { [weak self, weak dot] in
                guard let self, let dot else { return }
                self.pick(Self.rgba(dot.resolvedColor), name: mac.name)
            }
            dot.setAccessibilityLabel(StudioWords.color(mac.name))
            macSwatches.append(dot)
            v.addSubview(dot)
        }
        let recent = Self.recent()
        if !recent.isEmpty {
            _ = heading(.colorRecent)
            for c in recent.prefix(7) {
                let dot = StudioColorDot(color: StudioPageStyle.color(c))
                dot.onClick = { [weak self] in self?.pick(c, name: nil) }
                recentSwatches.append(dot)
                v.addSubview(dot)
            }
        }
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = StudioPageStyle.hairline
        v.addSubview(divider)
        let opacity = StudioPageStyle.label(StudioText[.colorOpacity], font: StudioPageStyle.valueFont, color: .labelColor)
        opacity.identifier = NSUserInterfaceItemIdentifier("opacity-label")
        v.addSubview(opacity)
        opacitySlider.controlSize = .small
        opacitySlider.isContinuous = true
        opacitySlider.isEnabled = target.acceptsAlpha
        opacitySlider.onAction { [weak self] s in
            guard let self, let s = s as? NSSlider else { return }
            var c = self.picked ?? self.target.color
            c.a = (s.doubleValue / 100 * 255).rounded()
            self.pick(c, name: self.pickedName, fromSlider: true)
        }
        v.addSubview(opacitySlider)
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        opacityLabel.textColor = StudioPageStyle.quietInk
        opacityLabel.alignment = .right
        v.addSubview(opacityLabel)
        eyedropper.bezelStyle = .rounded
        eyedropper.image = StudioPageStyle.symbol("eyedropper", size: 12, weight: .medium)
        eyedropper.imagePosition = .imageOnly
        eyedropper.toolTip = StudioText[.colorEyedropper]
        eyedropper.setAccessibilityLabel(StudioText[.colorEyedropper])
        eyedropper.onAction { [weak self] _ in self?.sampleScreen() }
        v.addSubview(eyedropper)
        field.font = StudioPageStyle.monospaced(12)
        field.placeholderString = target.written
        field.setAccessibilityLabel(StudioText[.colorHex])
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted)
        v.addSubview(field)
        moreColors.title = StudioText[.colorMore]
        moreColors.bezelStyle = .rounded
        moreColors.controlSize = .small
        moreColors.font = .systemFont(ofSize: 11.5)
        moreColors.onAction { [weak self] _ in self?.showColorPanel() }
        v.addSubview(moreColors)
        v.onLayout = { [weak self] in self?.layoutContent() }
        view = v
        titleLabel.stringValue = target.title
        refreshValue()
        view.frame = NSRect(x: 0, y: 0, width: Self.width, height: contentHeight())
        preferredContentSize = view.frame.size
        layoutContent()
    }

    // MARK: Showing

    func show(relativeTo rect: NSRect, of view: NSView) {
        _ = self.view
        popover.show(relativeTo: rect, of: view, preferredEdge: .minX)
    }

    /// Closes it (the pick is handed over): after the close animation on screen.
    func close() {
        if popover.isShown { popover.performClose(nil) } else { finish() }
    }

    /// Closes it now and hands the pick over in this turn — Done, the window closing, another widget, an undo — with no
    /// animation to wait for (the session may be gone when it would end).
    func commitNow() {
        popover.animates = false
        if popover.isShown { popover.close() }
        finish()
    }

    func popoverDidClose(_ notification: Notification) { finish() }

    private func finish() {
        guard !closed else { return }
        closed = true
        if usesColorPanel {
            usesColorPanel = false
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
        if let picked { Self.remember(picked, presentsWindows: presentsWindows) }
        onClose?(picked, pickedName)
    }

    // MARK: Picking

    /// A color picked: shown at once; the swatches, the hex and the field follow.
    func pick(_ color: RGBA, name: String?, fromSlider: Bool = false) {
        var c = color
        if !target.acceptsAlpha { c.a = 255 }
        if !fromSlider, target.acceptsAlpha, name == nil, color.a >= 254.5, let old = picked { c.a = old.a }
        picked = c
        pickedName = name
        refreshValue()
        onPreview?(c)
    }

    /// The accent that follows the Mac.
    func pickAccent() {
        pick(Self.rgba(NSColor.controlAccentColor), name: "accent")
    }

    @objc private func fieldCommitted() {
        guard let c = StudioColorInput.parse(field.stringValue) else {
            field.toolTip = StudioText[.colorBadValue]
            if presentsWindows { NSSound.beep() }
            return
        }
        field.toolTip = nil
        pick(c, name: nil, fromSlider: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) { fieldCommitted() }

    /// The field's text as typed, taken (Return, or a paste): for the self-tests and the paste path.
    func takeFieldText(_ text: String) {
        field.stringValue = text
        fieldCommitted()
    }

    private func sampleScreen() {
        // The system's loupe: never asked for off screen (self-tests, snapshots).
        guard presentsWindows else { return }
        NSColorSampler().show { [weak self] color in
            guard let self, let color else { return }
            self.pick(Self.rgba(color), name: nil)
        }
    }

    private func showColorPanel() {
        guard presentsWindows else { return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = target.acceptsAlpha
        panel.color = StudioPageStyle.color(picked ?? target.color)
        panel.setTarget(self)
        usesColorPanel = true
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.isContinuous = true
        // The panel is another window: the popover stays while it is used.
        popover.behavior = .applicationDefined
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        pick(Self.rgba(sender.color), name: nil, fromSlider: true)
    }

    static func rgba(_ color: NSColor) -> RGBA {
        let c = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? .black
        return RGBA(r: (c.redComponent * 255).rounded(), g: (c.greenComponent * 255).rounded(),
                    b: (c.blueComponent * 255).rounded(), a: (c.alphaComponent * 255).rounded())
    }

    // MARK: Recent

    static func recent() -> [RGBA] {
        if NSApp?.activationPolicy() == .prohibited { return recentInMemory }
        let stored = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        return stored.compactMap(StudioColorInput.parse)
    }

    static func remember(_ c: RGBA, presentsWindows: Bool) {
        var list = (presentsWindows ? recent() : recentInMemory).filter {
            ValueUsageIndex.colorKey($0) != ValueUsageIndex.colorKey(c)
        }
        list.insert(c, at: 0)
        list = Array(list.prefix(7))
        if presentsWindows, NSApp?.activationPolicy() != .prohibited {
            UserDefaults.standard.set(list.map(StudioColorInput.hex), forKey: recentKey)
        } else {
            recentInMemory = list
        }
    }

    // MARK: Layout

    private func refreshValue() {
        let c = picked ?? target.color
        hexLabel.stringValue = StudioColorInput.hex(c)
        noteLabel.stringValue = "·  " + (target.parts == 1 ? StudioText[.colorPartsOne]
                                                            : StudioText.format(.colorPartsMany, target.parts))
        opacitySlider.doubleValue = c.a / 255 * 100
        opacityLabel.stringValue = "\(Int((c.a / 255 * 100).rounded())) %"
        field.stringValue = target.showsNotation
            ? StudioColorWriting.text(c, like: target.written, acceptsAlpha: target.acceptsAlpha)
            : StudioColorInput.hex(target.acceptsAlpha ? c : RGBA(r: c.r, g: c.g, b: c.b, a: 255))
        let key = ValueUsageIndex.colorKey(c)
        for (i, dot) in widgetSwatches.enumerated() {
            dot.selected = ValueUsageIndex.colorKey(widgetColors[i]) == key
        }
        for dot in macSwatches { dot.selected = ValueUsageIndex.colorKey(Self.rgba(dot.resolvedColor)) == key && picked != nil }
        view.needsLayout = true
    }

    func contentHeight() -> CGFloat { layoutContent(place: false) }

    @discardableResult
    private func layoutContent(place: Bool = true) -> CGFloat {
        let m: CGFloat = 16, w = Self.width
        var y: CGFloat = 14
        func put(_ v: NSView, _ r: NSRect) { if place { v.frame = r } }
        let th = ceil(titleLabel.intrinsicContentSize.height)
        put(titleLabel, NSRect(x: m, y: y, width: w - 2 * m, height: th))
        y += th + 3
        let hw = ceil(hexLabel.intrinsicContentSize.width) + 4
        put(hexLabel, NSRect(x: m, y: y, width: hw, height: 15))
        put(noteLabel, NSRect(x: m + hw + 6, y: y, width: w - m - hw - 6 - m, height: 15))
        y += 15 + 12
        var headingIndex = 0
        func headingRow() {
            guard headingIndex < headings.count else { return }
            put(headings[headingIndex], NSRect(x: m, y: y, width: w - 2 * m, height: 14))
            headingIndex += 1
            y += 14 + 7
        }
        func dots(_ list: [StudioColorDot]) {
            var x = m
            for d in list {
                put(d, NSRect(x: x, y: y, width: 22, height: 22))
                x += 22 + 9
            }
            y += 22
        }
        headingRow()
        dots(widgetSwatches)
        y += 12
        headingRow()
        put(accentDot, NSRect(x: m, y: y, width: 22, height: 22))
        put(accentLabel, NSRect(x: m + 22 + 9, y: y + 3, width: w - m - 31 - m, height: 16))
        y += 22 + 8
        dots(Array(macSwatches.prefix(7)))
        y += 8
        dots(Array(macSwatches.dropFirst(7)))
        y += 12
        if !recentSwatches.isEmpty {
            headingRow()
            dots(recentSwatches)
            y += 12
        }
        put(divider, NSRect(x: m, y: y + 4, width: w - 2 * m, height: 1))
        y += 9 + 5
        if place, let label = view.subviews.first(where: { $0.identifier?.rawValue == "opacity-label" }) {
            label.frame = NSRect(x: m, y: y + 2, width: 90, height: 16)
        }
        put(opacityLabel, NSRect(x: w - m - 40, y: y + 2, width: 40, height: 16))
        put(opacitySlider, NSRect(x: w - m - 40 - 8 - 96, y: y, width: 96, height: 20))
        y += 20 + 10 + 6
        put(eyedropper, NSRect(x: m, y: y, width: 30, height: 24))
        put(field, NSRect(x: m + 30 + 8, y: y + 1, width: 100, height: 22))
        let mw = ceil(moreColors.intrinsicContentSize.width)
        put(moreColors, NSRect(x: w - m - mw, y: y, width: mw, height: 24))
        y += 24 + 14
        return y
    }
}

/// The popover's content: flipped, laid out by its controller.
final class StudioPopoverContentView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// One color of the popover: an 18 pt dot, ringed in the accent color when it is the chosen one; the accent's dot is
/// drawn on a ring of every hue (it follows the Mac).
final class StudioColorDot: NSControl {
    let color: NSColor
    let accent: Bool
    var selected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    init(color: NSColor, accent: Bool = false) {
        self.color = color
        self.accent = accent
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The color as it is drawn now (dynamic system colors resolve in the view's appearance).
    var resolvedColor: NSColor {
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
        if selected {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = 2
            ring.stroke()
        }
        if accent {
            let hues: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            for (i, h) in hues.enumerated() {
                let p = NSBezierPath()
                let c = NSPoint(x: r.midX, y: r.midY)
                p.move(to: c)
                p.appendArc(withCenter: c, radius: r.width / 2, startAngle: CGFloat(i) * 60, endAngle: CGFloat(i + 1) * 60)
                p.close()
                h.setFill()
                p.fill()
            }
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)).fill()
        } else {
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            let o = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25))
            o.lineWidth = 0.5
            o.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
