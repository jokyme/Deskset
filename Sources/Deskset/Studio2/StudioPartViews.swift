import AppKit
import DesksetCore

// The pieces of a part's page and of Every Setting: the way back, the scope sentence, a data token, examples, a
// color with words beside it, a pair of controls, the dense rows of Every Setting and the box diagram.

/// "‹ System › CPU": the way back above a page's title; the first goes back to the widget page.
final class StudioCrumbsView: NSView {
    var onClick: ((Int) -> Void)?
    private(set) var crumbs: [String] = []
    private var buttons: [NSButton] = []
    private var chevrons: [NSImageView] = []
    private let back = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        back.image = StudioPageStyle.symbol("chevron.left", size: 9.5, weight: .semibold, color: StudioPageStyle.quietInk)
        addSubview(back)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ crumbs: [String]) {
        guard crumbs != self.crumbs else { return }
        self.crumbs = crumbs
        buttons.forEach { $0.removeFromSuperview() }
        chevrons.forEach { $0.removeFromSuperview() }
        buttons = []
        chevrons = []
        for (i, c) in crumbs.enumerated() {
            if i > 0 {
                let chevron = NSImageView()
                chevron.image = StudioPageStyle.symbol("chevron.right", size: 8, weight: .semibold,
                                                       color: StudioPageStyle.faintInk)
                chevrons.append(chevron)
                addSubview(chevron)
            }
            let b = NSButton(title: c, target: nil, action: nil)
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: c, attributes: [
                .font: StudioPageStyle.noteFont, .foregroundColor: StudioPageStyle.quietInk])
            b.setAccessibilityLabel(i == 0 ? StudioText.format(.backTo, c) : c)
            b.onAction { [weak self] _ in self?.onClick?(i) }
            buttons.append(b)
            addSubview(b)
        }
        needsLayout = true
    }

    func button(_ i: Int) -> NSButton? { buttons.indices.contains(i) ? buttons[i] : nil }

    override func layout() {
        super.layout()
        let h = bounds.height
        back.frame = NSRect(x: 0, y: (h - 12) / 2, width: 8, height: 12)
        var x: CGFloat = 13
        for (i, b) in buttons.enumerated() {
            if i > 0 {
                chevrons[i - 1].frame = NSRect(x: x, y: (h - 10) / 2, width: 7, height: 10)
                x += 12
            }
            let w = ceil(b.intrinsicContentSize.width)
            b.frame = NSRect(x: x, y: 0, width: w, height: h)
            x += w + 4
        }
    }
}

/// The scope sentence under a page's title: "⌖ This number only" at the left, the one-click wider (or narrower)
/// reach at the right; pointing at that link outlines on the canvas what it would reach.
final class StudioScopeView: NSView {
    var onLink: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private(set) var scope: StudioPage.Scope?
    private let icon = NSImageView()
    private let text = StudioPageStyle.label("", font: StudioPageStyle.noteFont)
    let linkButton = NSButton(title: "", target: nil, action: nil)
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = StudioPageStyle.symbol("scope", size: 10.5, color: StudioPageStyle.quietInk)
        linkButton.isBordered = false
        linkButton.onAction { [weak self] _ in self?.onLink?() }
        for v in [icon, text, linkButton] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ s: StudioPage.Scope) {
        scope = s
        text.stringValue = s.text
        text.toolTip = s.text
        linkButton.isHidden = s.link == nil
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.linkColor]
        if s.linkHovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        linkButton.attributedTitle = NSAttributedString(string: s.link ?? "", attributes: attributes)
        linkButton.setAccessibilityLabel(s.link)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 0, y: (h - 13) / 2, width: 12, height: 13)
        var right = bounds.width
        if !linkButton.isHidden {
            let w = ceil(linkButton.intrinsicContentSize.width)
            linkButton.frame = NSRect(x: right - w, y: (h - 17) / 2, width: w, height: 17)
            right -= w + 8
        }
        text.frame = NSRect(x: 17, y: (h - 15) / 2, width: max(right - 17, 20), height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: linkButton.frame, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Data and words in one field: the data as a chip (its symbol in the accent color), the words around it as text.
/// The chip is a button: what the part shows.
final class StudioTokenView: NSView, StudioPageItemView {
    var onData: (() -> Void)?
    private(set) var token: StudioPage.Token
    private var pieces: [NSView] = []

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(token: StudioPage.Token) {
        self.token = token
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        update(.token(token))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() { layer?.backgroundColor = StudioPageStyle.fieldFill.cgColor }

    func update(_ kind: StudioPage.Kind) {
        guard case .token(let t) = kind else { return }
        token = t
        pieces.forEach { $0.removeFromSuperview() }
        pieces = t.parts.map { part -> NSView in
            switch part {
            case .data(let name, let symbol):
                let chip = StudioDataChip(name: name, symbol: symbol, size: t.small ? 11 : 12)
                chip.onClick = { [weak self] in self?.onData?() }
                return chip
            case .text(let s):
                return StudioPageStyle.label(s, font: .systemFont(ofSize: t.small ? 12 : 12.5), color: .labelColor)
            }
        }
        pieces.forEach(addSubview)
        needsLayout = true
    }

    var dataChip: StudioDataChip? { pieces.first { $0 is StudioDataChip } as? StudioDataChip }

    func height(forWidth width: CGFloat) -> CGFloat { token.small ? 22 : 28 }

    override func layout() {
        super.layout()
        var x: CGFloat = token.small ? 5 : 7
        let h = bounds.height
        for p in pieces {
            let size = p.intrinsicContentSize
            let w = ceil(size.width)
            let ph: CGFloat = p is StudioDataChip ? (token.small ? 18 : 20) : 16
            p.frame = NSRect(x: x, y: (h - ph) / 2, width: min(w, bounds.width - x - 4), height: ph)
            x += w + 3
        }
    }
}

/// A data item as a chip: its symbol in the accent color and its name, on a pale accent capsule.
final class StudioDataChip: NSControl {
    var onClick: (() -> Void)?
    let name: String
    private let icon = NSImageView()
    private let title: NSTextField
    private let size: CGFloat

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(name: String, symbol: String, size: CGFloat) {
        self.name = name
        self.size = size
        title = StudioPageStyle.label(name, font: .systemFont(ofSize: size, weight: .medium), color: .labelColor)
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = StudioPageStyle.symbol(symbol, size: size - 2, weight: .semibold, color: .controlAccentColor)
        addSubview(icon)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 6 + size + 4 + ceil(title.intrinsicContentSize.width) + 6, height: size + 8)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 6, y: (h - size) / 2, width: size, height: size)
        title.frame = NSRect(x: 6 + size + 4, y: (h - size - 4) / 2, width: bounds.width - size - 16, height: size + 4)
        layer?.cornerRadius = h / 2
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

/// Examples rendered with the real value ("21% · 21.4% · 0.21"): the chosen one framed in the accent color.
final class StudioExamplesView: NSView, StudioPageItemView {
    var onClick: ((Int) -> Void)?
    private(set) var examples: StudioPage.Examples
    private(set) var chips: [StudioExampleChip] = []

    override var isFlipped: Bool { true }

    init(examples: StudioPage.Examples) {
        self.examples = examples
        super.init(frame: .zero)
        update(.examples(examples))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ kind: StudioPage.Kind) {
        guard case .examples(let e) = kind else { return }
        examples = e
        while chips.count > e.items.count { chips.removeLast().removeFromSuperview() }
        while chips.count < e.items.count {
            let i = chips.count
            let c = StudioExampleChip()
            c.onClick = { [weak self] in self?.onClick?(i) }
            chips.append(c)
            addSubview(c)
        }
        for (i, text) in e.items.enumerated() {
            chips[i].show(text, selected: e.selected == i, small: e.small)
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { examples.small ? 22 : 26 }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for c in chips {
            let w = c.intrinsicContentSize.width
            c.frame = NSRect(x: x, y: 0, width: min(w, max(bounds.width - x, 0)), height: bounds.height)
            x += w + 6
        }
    }
}

final class StudioExampleChip: NSControl {
    var onClick: (() -> Void)?
    private let title = StudioPageStyle.label("", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
    private var selected = false

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        title.alignment = .center
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, selected: Bool, small: Bool) {
        self.selected = selected
        let base = NSFont.systemFont(ofSize: small ? 12 : 13, weight: .semibold)
        title.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        title.stringValue = text
        setAccessibilityLabel(text)
        setAccessibilityValue(selected ? StudioText[.selected] : nil)
        needsDisplay = true
        needsLayout = true
    }

    var text: String { title.stringValue }
    var isChosen: Bool { selected }

    override func updateLayer() {
        layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                                           : StudioPageStyle.fieldFill).cgColor
        layer?.borderWidth = selected ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(title.intrinsicContentSize.width) + 18, height: 26) }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 4, y: (bounds.height - 17) / 2, width: bounds.width - 8, height: 17)
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

/// A swatch with words beside it: "◐ Text color  follows Light / Dark". The swatch opens the color popover; pointing
/// at the row outlines what the color paints.
final class StudioColorLabelView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    let swatch = StudioSwatchView(swatch: StudioPage.Swatch(id: "", kind: .color, label: ""), showsLabel: false)
    private let title = StudioPageStyle.label("", font: StudioPageStyle.valueFont, color: .labelColor)
    private let note = StudioPageStyle.label("", font: StudioPageStyle.noteFont)
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        swatch.onClick = { [weak self] in self?.onClick?() }
        for v in [swatch, title, note] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ c: StudioPage.ColorLabel) {
        swatch.swatch = c.swatch
        title.stringValue = c.title
        note.stringValue = c.note ?? ""
        note.isHidden = c.note == nil
        setAccessibilityLabel([c.title, c.note].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        swatch.frame = NSRect(x: 0, y: (h - 18) / 2, width: 18, height: 18)
        let tw = ceil(title.intrinsicContentSize.width) + 2
        title.frame = NSRect(x: 25, y: (h - 16) / 2, width: min(tw, bounds.width - 25), height: 16)
        let nx = 25 + tw + 6
        note.frame = NSRect(x: nx, y: (h - 15) / 2, width: max(bounds.width - nx, 0), height: 15)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The box diagram of Every Setting: margin → shadow → background → border → padding, drawn as boxes one inside the
/// other, each named with its value, the part's content in the middle.
final class StudioBoxDiagramView: NSView, StudioPageItemView {
    private(set) var box: StudioPage.Box

    override var isFlipped: Bool { true }

    init(box: StudioPage.Box) {
        self.box = box
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        update(.box(box))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ kind: StudioPage.Kind) {
        guard case .box(let b) = kind else { return }
        box = b
        setAccessibilityLabel([b.margin, b.shadow, b.background, b.border, b.padding].joined(separator: ", "))
        needsDisplay = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 100 }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let outer = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        outer.lineWidth = 1
        outer.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
        outer.stroke()
        let middle = r.insetBy(dx: 18, dy: 18)
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        NSBezierPath(roundedRect: middle, xRadius: 6, yRadius: 6).fill()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        let border = NSBezierPath(roundedRect: middle.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()
        let inner = r.insetBy(dx: 36, dy: 36)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4).fill()
        let base = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 13) } ?? base
        let content = NSAttributedString(string: box.content, attributes: [.font: rounded, .foregroundColor: NSColor.labelColor])
        let cs = content.size()
        content.draw(at: NSPoint(x: inner.midX - cs.width / 2, y: inner.midY - cs.height / 2))
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                    .foregroundColor: StudioPageStyle.quietInk]
        func put(_ s: String, x: CGFloat, y: CGFloat, right: Bool = false) {
            let a = NSAttributedString(string: s, attributes: small)
            let w = a.size().width
            a.draw(at: NSPoint(x: right ? x - w : x, y: y))
        }
        put(box.margin, x: r.minX + 7, y: r.minY + 3)
        put(box.shadow, x: r.maxX - 7, y: r.minY + 3, right: true)
        put("\(box.background) · \(box.border)", x: middle.minX + 6, y: middle.minY + 3)
        put(box.padding, x: middle.maxX - 6, y: middle.maxY - 16, right: true)
    }
}

/// A row of Every Setting: the label in a fixed column (it can be dragged to change a number: ↔ beside it while it is
/// being dragged), then a small control; under it, which word the filter found it by.
final class StudioDenseRowView: NSView, StudioPageItemView {
    var onEvent: ((StudioRowView.Event) -> Void)?
    private(set) var dense: StudioPage.Dense
    let row: StudioRowView
    private let note = StudioPageStyle.label("", font: StudioPageStyle.smallFont)

    override var isFlipped: Bool { true }

    init(dense: StudioPage.Dense) {
        self.dense = dense
        var r = StudioPage.Row(label: dense.label, control: dense.control)
        r.labelWidth = 80
        r.tooltip = dense.tooltip
        row = StudioRowView(row: r, dense: true)
        super.init(frame: .zero)
        row.onEvent = { [weak self] e in self?.onEvent?(e) }
        addSubview(row)
        addSubview(note)
        update(.dense(dense))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ kind: StudioPage.Kind) {
        guard case .dense(let d) = kind else { return }
        dense = d
        var r = StudioPage.Row(label: d.label, control: d.control)
        r.labelWidth = 80
        r.tooltip = d.tooltip
        row.scrubbing = d.scrubbing
        row.update(.row(r))
        note.stringValue = d.note ?? ""
        note.isHidden = d.note == nil
        needsLayout = true
    }

    func accepts(_ control: StudioPage.Control) -> Bool { row.accepts(control) }

    func height(forWidth width: CGFloat) -> CGFloat { 23.5 + (dense.note == nil ? 0 : 14) }

    override func layout() {
        super.layout()
        row.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 23.5)
        note.frame = NSRect(x: 88, y: 22, width: max(bounds.width - 88, 0), height: 14)
    }
}
