import AppKit

/// The layer and live data list. Rows use the sidebar's whole width: the disclosure chevron takes a 12-point column at
/// the left of each level (the system's column was more than twice as wide and cut the names short), and the row's
/// content runs to the tint's right edge.
final class SidebarOutlineView: NSOutlineView {
    /// Inset of the rows' tint (and of their content on the right).
    static let edge: CGFloat = 6
    /// The chevron's column, left of each level's content.
    static let chevronColumn: CGFloat = 12
    /// Called when the list's width changed, after it is laid out (rows whose names wrap change height).
    var onWidthChange: (() -> Void)?
    private var laidOutWidth: CGFloat = 0

    /// Where the content of a row at `level` starts.
    func contentX(level: Int) -> CGFloat {
        Self.edge + Self.chevronColumn + CGFloat(max(level, 0)) * indentationPerLevel
    }

    /// The width of a row's content (its cell) at `level`; nil before the list has a width.
    func contentWidth(level: Int) -> CGFloat? {
        guard bounds.width > 0 else { return nil }
        return max(bounds.width - contentX(level: level) - Self.edge, 0)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        let level = CGFloat(max(self.level(forRow: row), 0))
        frame.origin.x = Self.edge + level * indentationPerLevel + (Self.chevronColumn - frame.width) / 2
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard column == 0, row >= 0 else { return frame }
        let x = contentX(level: level(forRow: row))
        return NSRect(x: x, y: frame.minY, width: max(bounds.width - x - Self.edge, 0), height: frame.height)
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - laidOutWidth) >= 0.5 else { return }
        laidOutWidth = bounds.width
        onWidthChange?()
    }
}

/// A row of the layer and live data lists (docs/editor-friendly.md §5.2 "Row anatomy"). The selection is a rounded
/// accent tint at 18% and the pointer's row the same shape at 7%, drawn here rather than by the list: the source
/// list's own emphasized selection is a solid dark bar off-screen that hid the row's name. Text keeps its normal
/// colors whatever the state.
final class LayerRowView: NSTableRowView {
    /// The pointer is over the row.
    private(set) var isHovered = false
    /// The layer is under the pointer on the canvas (the row shows the hover tint too).
    var isLinkedHover = false {
        didSet { if isLinkedHover != oldValue { needsDisplay = true } }
    }
    /// A FRONT / BACK caption: no tint.
    var isCaption = false
    /// Called when the pointer enters (true) or leaves (false) the row.
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    static let selectionAlpha: CGFloat = 0.18
    static let hoverAlpha: CGFloat = 0.07

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    /// The rounded area the tints fill.
    var tintRect: NSRect { bounds.insetBy(dx: SidebarOutlineView.edge, dy: 1) }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isCaption else { return }
        let alpha = isSelected ? Self.selectionAlpha : (isHovered || isLinkedHover) ? Self.hoverAlpha : 0
        guard alpha > 0 else { return }
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: tintRect, xRadius: 6, yRadius: 6).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    /// Sets the hover state as the pointer would (also used by self-tests).
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        onHover?(hovered)
    }

    /// Forgets the hover without telling anyone (the list is about to reload and clears what the hover showed).
    func clearHover() {
        guard isHovered else { return }
        isHovered = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func prepareForReuse() {
        // A row reused while hovered never gets its mouse-exit: what its hover showed goes away now.
        if isHovered { onHover?(false) }
        super.prepareForReuse()
        isHovered = false
        isLinkedHover = false
        onHover = nil
    }
}

/// The content of a row: a picture of the layer (or a symbol) and, next to it, its name on the first line — never
/// shortened for anything else — with the state on its right (for layers an eye-slash when hidden, a lock when
/// locked, a warning when part of it is cut off, and on hover the eye and lock toggles). Under the name: a line of
/// its own for data that reads text (the text), a formula whose name doesn't say what it is calculated from, or data
/// that doesn't work on a Mac; then the second line (kind and data of a layer; who uses the data, as a link). A data
/// row's live value sits at the right of the first line under the name. Data names that don't fit wrap onto a second
/// line (the list gives the row its height, `rowHeight`); whatever is still cut shows whole in the tooltip.
///
/// Laid out by hand: the lines are few and fixed, and the tooltip needs to know exactly what is cut.
final class LayerCell: NSTableCellView {
    enum Style {
        case layer, data, widget, caption
    }

    let style: Style
    let thumbnail = LayerThumbnailView()
    /// A line between the name and the second line (data): the text the data reads, what a formula is calculated
    /// from, or that it doesn't work on a Mac. Hidden when empty.
    let info = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    /// The second line when it names users ("Used by 16 bars"): click selects them, hover outlines them.
    let link = LinkButton()
    /// A live value (data rows).
    let detail = NSTextField(labelWithString: "")
    /// Values of a run of data ("16 sound bands"), as tiny bars.
    let strip = MiniStripView()
    let warning = NSImageView()
    let lock = NSButton()
    let eye = NSButton()
    /// "Delete" for data nothing uses (on hover).
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    /// The row is under the pointer: toggles show.
    var isHovered = false { didSet { refreshAccessories() } }
    var isLayerHidden = false { didSet { refreshAccessories() } }
    var isLayerLocked = false { didSet { refreshAccessories() } }
    var isCutOff = false { didSet { refreshAccessories() } }
    /// Data nothing uses: dimmed, with Delete on hover.
    var isUnused = false { didSet { refreshAccessories() } }
    /// The row has the eye and lock (layers).
    var hasToggles = false { didSet { refreshAccessories() } }
    /// What the warning says (layers: cut off on the desktop; data: doesn't work on a Mac).
    var warningText = LayerCell.cutOffText { didSet { warning.toolTip = warningText } }
    /// Lines the name may take: data names wrap onto a second line rather than being cut.
    var titleLines = 1 {
        didSet {
            guard titleLines != oldValue else { return }
            configureTitle()
            needsLayout = true
        }
    }
    /// The row's tooltip when every line shows whole ("MeterTitle — double-click to type"). When a line is cut, the
    /// tooltip gives the lines whole first.
    var baseToolTip: String? { didSet { needsLayout = true } }
    /// The link's tooltip ("Select it"), after the link's text when that is cut.
    var linkToolTip: String? { didSet { needsLayout = true } }
    /// Shorter wordings of the link and of the line under the name, tried in order when the first doesn't fit
    /// ("Used by “17 GB / 24 GB” and Memory shape" → "Used by 2 layers").
    var shorterLinks: [NSAttributedString] = [] { didSet { needsLayout = true } }
    var shorterInfos: [String] = [] { didSet { needsLayout = true } }
    /// The wordings as set, before a shorter one was chosen.
    private var fullLink: NSAttributedString?
    private var fullInfo = ""

    static let cutOffText = "Part of this layer is outside the widget and won't show on the desktop."
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let lineFont = NSFont.systemFont(ofSize: 11)
    /// Heights of a line of the name and of the smaller lines.
    static let titleLineHeight = lineHeight(of: titleFont)
    static let lineHeight = lineHeight(of: lineFont)
    /// Space between a thumbnail and the words, and at the right of the row.
    static let gap: CGFloat = 8
    static let trailing: CGFloat = 6
    /// Picture sizes: layers show their pixels, data a symbol.
    static let dataTile = NSSize(width: 24, height: 24)

    init(identifier: NSUserInterfaceItemIdentifier, style: Style) {
        self.style = style
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        textField = label
        addSubview(label)
        link.isHidden = true
        info.isHidden = true
        if style == .caption {
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            return
        }
        label.font = style == .widget ? .systemFont(ofSize: 13, weight: .semibold) : Self.titleFont
        label.textColor = .labelColor
        configureTitle()
        for field in [info, subtitle, detail] {
            field.font = Self.lineFont
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.cell?.wraps = false
            field.maximumNumberOfLines = 1
        }
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.alignment = .right
        strip.isHidden = true
        warning.image = EditorStyle.image("exclamationmark.triangle.fill", size: 11)
        warning.contentTintColor = .systemYellow
        warning.toolTip = warningText
        warning.setAccessibilityLabel("Cut off on the desktop")
        for (button, name) in [(eye, "Hide"), (lock, "Lock")] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.setButtonType(.momentaryChange)
            button.setAccessibilityLabel(name)
        }
        deleteButton.bezelStyle = .inline
        deleteButton.controlSize = .small
        deleteButton.font = .systemFont(ofSize: 11)
        deleteButton.toolTip = "Delete this live data"
        for v in [thumbnail, info, subtitle, link, detail, strip, deleteButton, warning, lock, eye] as [NSView] {
            addSubview(v)
        }
        refreshAccessories()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    /// Words keep their normal colors in a selected row (the tint is light; see `LayerRowView`).
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = .normal }
    }

    private func configureTitle() {
        guard let label = textField else { return }
        label.maximumNumberOfLines = titleLines
        label.cell?.wraps = titleLines > 1
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = titleLines > 1 ? .byWordWrapping : .byTruncatingTail
        label.usesSingleLineMode = titleLines == 1
    }

    /// The second line as plain text (layers, the widget) or as a link (data users).
    func setSubtitle(_ text: String, link title: NSAttributedString? = nil) {
        subtitle.stringValue = text
        subtitle.isHidden = title != nil || text.isEmpty
        link.isHidden = title == nil
        fullLink = title
        shorterLinks = []
        if let title { link.attributedTitle = title }
        needsLayout = true
    }

    /// The line under the name (data); empty hides it.
    func setInfo(_ text: String) {
        guard fullInfo != text || info.isHidden != text.isEmpty else { return }
        fullInfo = text
        shorterInfos = []
        info.stringValue = text
        info.isHidden = text.isEmpty
        needsLayout = true
    }

    /// The first wording that fits `width` (the last one when none does).
    private static func fitting<T>(_ choices: [T], width: CGFloat, measure: (T) -> CGFloat) -> T? {
        choices.first { ceil(measure($0)) <= width + 0.5 } ?? choices.last
    }

    /// Opacity of the picture and words: hidden layers 45%, data nothing uses 55%.
    var contentAlpha: CGFloat = 1 {
        didSet {
            for v in [thumbnail, textField, info, subtitle, link, detail, strip] as [NSView?] { v?.alphaValue = contentAlpha }
        }
    }

    /// Shows the state icons and toggles for the row's state.
    func refreshAccessories() {
        guard style == .layer || style == .data else {
            for v in [warning, eye, lock, deleteButton, detail, strip] as [NSView] { v.isHidden = true }
            return
        }
        warning.isHidden = !isCutOff
        eye.isHidden = !(hasToggles && (isHovered || isLayerHidden))
        lock.isHidden = !(hasToggles && (isHovered || isLayerLocked))
        eye.image = EditorStyle.image(isLayerHidden ? "eye.slash" : "eye", size: 11)
        eye.contentTintColor = isLayerHidden && !isHovered ? .secondaryLabelColor : .tertiaryLabelColor
        eye.toolTip = isLayerHidden ? "Show this layer" : "Hide this layer"
        eye.setAccessibilityLabel(isLayerHidden ? "Show" : "Hide")
        lock.image = EditorStyle.image(isLayerLocked ? "lock.fill" : "lock.open", size: 11)
        lock.contentTintColor = isLayerLocked && !isHovered ? .secondaryLabelColor : .tertiaryLabelColor
        lock.toolTip = isLayerLocked ? "Unlock" : "Lock it so it can't be moved by accident"
        lock.setAccessibilityLabel(isLayerLocked ? "Unlock" : "Lock")
        deleteButton.isHidden = !(isUnused && isHovered)
        detail.isHidden = detail.stringValue.isEmpty || (isUnused && isHovered)
        needsLayout = true
    }

    // MARK: Layout

    /// The line under the name that shows users: the link or the plain line (nil: none).
    private var usersLine: NSView? {
        if !link.isHidden { return link }
        return subtitle.isHidden ? nil : subtitle
    }

    /// Places a label or button by the rectangle its words take (a label's frame reaches 2 points past its words on
    /// each side, as Auto Layout would place it).
    private static func place(_ view: NSView, _ rect: NSRect) {
        view.frame = view.frame(forAlignmentRect: rect)
    }

    /// The width a label or button has for its words.
    static func textWidth(of view: NSView) -> CGFloat {
        view.alignmentRect(forFrame: view.frame).width
    }

    override func layout() {
        super.layout()
        let b = bounds
        guard let title = textField else { return }
        if style == .caption {
            let h = title.intrinsicContentSize.height
            Self.place(title, NSRect(x: 1, y: b.height - h - 2, width: max(b.width - 1, 0), height: h))
            return
        }
        let tile = style == .data ? Self.dataTile : LayerThumbnails.size
        thumbnail.frame = NSRect(x: 0, y: ((b.height - tile.height) / 2).rounded(), width: tile.width, height: tile.height)
        let x = thumbnail.frame.maxX + Self.gap, right = b.width - Self.trailing
        let lines = [info.isHidden ? nil : info as NSView, usersLine].compactMap { $0 }
        let titleHeight = Self.titleLineHeight * CGFloat(titleLines)
        var y = ((b.height - titleHeight - CGFloat(lines.count) * (Self.lineHeight + 1)) / 2).rounded()

        // Line 1: the name, and at its right the state icons (right to left).
        var end = right
        for (view, width) in [(eye, 18), (lock, 18), (warning, 14)] as [(NSView, CGFloat)] where !view.isHidden {
            view.frame = NSRect(x: end - width, y: y + (Self.titleLineHeight - 16) / 2, width: width, height: 16)
            end -= width + 3
        }
        // The value sits at the right of the line under the name (on the name's line when there is none).
        let valueWidth = layoutValue(right: right, centerY: lines.isEmpty ? y + Self.titleLineHeight / 2
                                                                         : y + titleHeight + 1 + Self.lineHeight / 2,
                                     textWidth: right - x)
        if lines.isEmpty, valueWidth > 0 { end = min(end, right - valueWidth - 6) }
        Self.place(title, NSRect(x: x, y: y, width: max(end - x - (end < right ? 3 : 0), 0), height: titleHeight))
        y += titleHeight

        // The lines under it; the first one leaves room for the value.
        for (i, line) in lines.enumerated() {
            y += 1
            var width = right - x - (i == 0 && valueWidth > 0 ? valueWidth + 6 : 0)
            if line === info, !shorterInfos.isEmpty,
               let text = Self.fitting([fullInfo] + shorterInfos, width: width, measure: {
                   ($0 as NSString).size(withAttributes: [.font: Self.lineFont]).width
               }), info.stringValue != text {
                info.stringValue = text
            }
            if line === link, let full = fullLink, !shorterLinks.isEmpty,
               let title = Self.fitting([full] + shorterLinks, width: width, measure: { $0.size().width }),
               !link.attributedTitle.isEqual(to: title) {
                link.attributedTitle = title
            }
            // The link is as wide as its words, so only they are clickable.
            if line === link { width = min(ceil(link.intrinsicContentSize.width), width) }
            Self.place(line, NSRect(x: x, y: y, width: max(width, 0), height: Self.lineHeight))
            y += Self.lineHeight
        }
        updateToolTips()
    }

    /// Places the value, the strip and Delete right-aligned on the line centred at `centerY`; returns their width.
    private func layoutValue(right: CGFloat, centerY: CGFloat, textWidth: CGFloat) -> CGFloat {
        var end = right
        var used: CGFloat = 0
        func put(_ view: NSView, width: CGFloat, height: CGFloat, words: Bool) {
            let rect = NSRect(x: end - width, y: (centerY - height / 2).rounded(), width: width, height: height)
            if words { Self.place(view, rect) } else { view.frame = rect }
            end -= width + 4
            used += width + (used > 0 ? 4 : 0)
        }
        if !deleteButton.isHidden {
            let size = deleteButton.intrinsicContentSize
            put(deleteButton, width: size.width, height: size.height, words: true)
        }
        if !strip.isHidden { put(strip, width: 32, height: 12, words: false) }
        if !detail.isHidden {
            // A value never takes more than 45% of the words' width (text values have a line of their own).
            put(detail, width: min(ceil(detail.intrinsicContentSize.width), (textWidth * 0.45).rounded()),
                height: Self.lineHeight, words: true)
        }
        return used
    }

    /// Whether a label shows less than its text.
    static func isCut(_ field: NSTextField, lines: Int = 1) -> Bool {
        guard !field.isHidden, !field.stringValue.isEmpty else { return false }
        let width = textWidth(of: field)
        if lines <= 1 { return ceil(field.intrinsicContentSize.width) > width + 0.5 }
        return lineCount(field.stringValue, font: field.font ?? titleFont, width: width) > lines
    }

    /// Whether the link shows less than its text.
    var isLinkCut: Bool {
        !link.isHidden && ceil(link.intrinsicContentSize.width) > Self.textWidth(of: link) + 0.5
    }

    /// The tooltips: the row's lines whole when one is cut (then the section), the value whole when it is cut.
    private func updateToolTips() {
        guard let title = textField else { return }
        let cut = Self.isCut(title, lines: titleLines) || Self.isCut(info) || Self.isCut(subtitle) || isLinkCut
        let shortened = (!info.isHidden && info.stringValue != fullInfo)
            || (!link.isHidden && fullLink.map { !link.attributedTitle.isEqual(to: $0) } ?? false)
        if cut || shortened {
            var parts = [title.stringValue]
            if !info.isHidden { parts.append(fullInfo) }
            if !subtitle.isHidden { parts.append(subtitle.stringValue) }
            if !link.isHidden { parts.append((fullLink ?? link.attributedTitle).string) }
            if let base = baseToolTip, !base.isEmpty { parts.append(base) }
            toolTip = parts.joined(separator: "\n")
        } else {
            toolTip = baseToolTip
        }
        info.toolTip = Self.isCut(info) ? info.stringValue : nil
        detail.toolTip = Self.isCut(detail) ? detail.stringValue : nil
        link.toolTip = isLinkCut ? [link.attributedTitle.string, linkToolTip].compactMap { $0 }.joined(separator: "\n")
                                 : linkToolTip
    }

    // MARK: Metrics

    /// The height of a line of words in `font` (as a label sizes itself).
    static func lineHeight(of font: NSFont) -> CGFloat {
        let label = NSTextField(labelWithString: "Ag")
        label.font = font
        return ceil(label.intrinsicContentSize.height)
    }

    /// How many lines `text` takes in `width` (the width a label has for its words).
    static func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int {
        guard !text.isEmpty, width > 0 else { return 1 }
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return max(Int((rect.height / ceil(NSLayoutManager().defaultLineHeight(for: font))).rounded()), 1)
    }

    /// The height of a row: its name's lines and the lines under it.
    static func rowHeight(titleLines: Int, lines: Int) -> CGFloat {
        let text = titleLineHeight * CGFloat(titleLines) + CGFloat(lines) * (lineHeight + 1)
        return max(40, ceil(text + 9))
    }

    /// Where the words of a row start in its cell.
    static func textX(_ style: Style) -> CGFloat {
        (style == .data ? dataTile.width : LayerThumbnails.size.width) + gap
    }
}

/// A layer's picture in its row: the tile with rounded corners and a hairline edge.
final class LayerThumbnailView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternaryLabelColor.setFill()
            bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// The values of a run of data as a row of tiny bars (0…1 each), never shorter than a hairline.
final class MiniStripView: NSView {
    var values: [Double] = [] { didSet { if values != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let gap: CGFloat = 1
        let width = max((bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count), 0.5)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        for (i, v) in values.enumerated() {
            let h = max(CGFloat(min(max(v.isFinite ? v : 0, 0), 1)) * bounds.height, 1)
            NSRect(x: CGFloat(i) * (width + gap), y: bounds.minY, width: width, height: h).fill()
        }
    }
}

/// A borderless button that reads as a link and reports the pointer over it.
final class LinkButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        alignment = .left
        lineBreakMode = .byTruncatingTail
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
