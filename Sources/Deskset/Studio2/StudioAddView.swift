import AppKit
import DesksetCore

/// What is done on the Add page, for the window to carry out.
enum StudioAddEvent: Equatable {
    /// A data item clicked: ask how to show it, then add it after the selection.
    case data(String)
    case part(StudioAddCatalog.Part)
    case symbol(String)
    /// Browse… the symbols.
    case browse
    /// One of the widget's colors or fonts: used on the selected part.
    case color(String)
    case font(String)
}

/// What a drag from the Add page carries, until the canvas takes it (the canvas's drop reports only the ghost's
/// component and frame).
enum StudioAddDrag: Equatable {
    case data(String)
    case part(StudioAddCatalog.Part)
    case symbol(String)
}

/// The Add page of the sidebar (⇧⌘L; named after the toolbar's Add). A search field for data, parts and symbols; then
/// "Show data" — this Mac's data with its live values, and chips for the other kinds (time, weather, music) — "Parts"
/// (text, symbol, picture, bar, ring, graph, shape, button), "Symbols" (a few, and Browse…), and what this widget
/// already uses: its colors and fonts. A click adds a thing after the selected part (data asks how to show it first);
/// a drag puts it on the canvas where the ghost shows, snapping as the canvas snaps.
final class StudioAddView: NSView, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let scroll = OverlayScrollView()
    let content = StudioAddContent()

    var onEvent: ((StudioAddEvent) -> Void)?
    /// The live value of a data item ("21%"; nil: none to show).
    var value: (StudioAddCatalog.DataItem) -> String? = { _ in nil }
    /// The widget's colors (id, color, name) and fonts (id, face), for "In this widget".
    var widgetColors: [(id: String, color: RGBA, name: String)] = []
    var widgetFonts: [(id: String, face: String)] = []

    /// The drag under way from this page (the window reads it when the canvas takes the drop).
    static var currentDrag: StudioAddDrag?

    private(set) var category: StudioAddCatalog.Category = .mac
    /// The symbols shown when nothing is searched: the last used first.
    static var recentSymbols: [String] = ["cpu", "umbrella.fill", "cloud.rain.fill"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = StudioText[.addSearch]
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel(StudioText[.addSearch])
        addSubview(searchField)
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        addSubview(scroll)
        content.page = self
        content.toolTip = StudioText[.addPageTip]
        setAccessibilityElement(false)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The views an off-screen snapshot draws.
    var snapshotViews: [NSView] { [searchField, content] }

    var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces) }

    @objc func searchChanged() { rebuild() }

    func setQuery(_ text: String) {
        searchField.stringValue = text
        rebuild()
    }

    func choose(_ c: StudioAddCatalog.Category) {
        category = category == c && c != .mac ? .mac : c
        rebuild()
    }

    /// Makes the page's pieces again (a search, a category, the widget's colors).
    func rebuild() {
        content.build()
        needsLayout = true
    }

    /// The live values again (the rows stay).
    func refreshValues() {
        for row in content.dataRows { row.value = value(row.item) ?? "" }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        searchField.frame = NSRect(x: 10, y: 0, width: max(w - 20, 40), height: 28)
        scroll.frame = NSRect(x: 0, y: 36, width: w, height: max(bounds.height - 36, 0))
        let width = scroll.contentSize.width
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(content.layoutAll(width: width),
                                                                      scroll.contentSize.height))
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        // Return: the first thing found.
        if let row = content.dataRows.first { onEvent?(.data(row.item.id)) } else if let tile = content.tiles.first {
            onEvent?(.part(tile.part))
        } else if let chip = content.symbolChips.first, case .symbol(let s) = chip.kind {
            onEvent?(.symbol(s))
        } else {
            NSSound.beep()
        }
        return true
    }
}

/// The page's pieces, laid out top to bottom.
final class StudioAddContent: NSView {
    weak var page: StudioAddView?
    private(set) var dataRows: [StudioAddDataRow] = []
    private(set) var categoryChips: [StudioAddChip] = []
    private(set) var tiles: [StudioAddTile] = []
    private(set) var symbolChips: [StudioAddChip] = []
    private(set) var colorChips: [StudioAddChip] = []
    private(set) var fontChips: [StudioAddChip] = []
    private var headers: [(NSTextField, NSTextField?)] = []
    private var headerFor: [String: (NSTextField, NSTextField?)] = [:]
    let emptyLabel = NSTextField(labelWithString: "")
    let browse = StudioAddChip(kind: .browse, title: StudioText[.addBrowse], symbol: nil)

    override var isFlipped: Bool { true }

    static func header(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11, weight: .semibold)
        f.textColor = StudioPageStyle.quietInk
        return f
    }

    static func trailing(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11)
        f.textColor = StudioPageStyle.quietInk
        f.alignment = .right
        return f
    }

    func build() {
        subviews.forEach { $0.removeFromSuperview() }
        headers = []
        headerFor = [:]
        guard let page else { return }
        let q = page.query
        let chinese = StudioText.language == .chinese
        func title(_ item: StudioAddCatalog.DataItem) -> String { StudioWords.data(item.title) }
        // Data.
        let items = q.isEmpty ? StudioAddCatalog.data.filter { $0.category == page.category }
            : StudioAddCatalog.search(q, titles: title)
        let categoryName: String = {
            switch page.category {
            case .mac: return StudioText[.addThisMac]
            case .time: return StudioText[.addTime]
            case .weather: return StudioText[.addWeather]
            case .music: return StudioText[.addMusic]
            }
        }()
        if !items.isEmpty { addHeader("data", StudioText[.addShowData], q.isEmpty ? categoryName : nil) }
        dataRows = items.map { item in
            let row = StudioAddDataRow(item: item, title: title(item))
            row.value = page.value(item) ?? ""
            row.onClick = { [weak page] in page?.onEvent?(.data(item.id)) }
            addSubview(row)
            return row
        }
        // Categories (only when nothing is searched).
        categoryChips = []
        if q.isEmpty {
            let kinds: [(StudioAddCatalog.Category, String, String)] = [
                (.time, StudioText[.addTime], "clock"), (.weather, StudioText[.addWeather], "cloud.sun"),
                (.music, StudioText[.addMusic], "music.note"),
            ]
            categoryChips = kinds.map { c, name, symbol in
                let chip = StudioAddChip(kind: .category(c), title: name, symbol: symbol)
                chip.isOn = page.category == c
                chip.onClick = { [weak page] in page?.choose(c) }
                addSubview(chip)
                return chip
            }
        }
        // Parts.
        let parts = StudioAddCatalog.Part.allCases.filter { p in
            q.isEmpty || StudioAddCatalog.fold(Self.partTitle(p)).contains(StudioAddCatalog.fold(q))
                || p.rawValue.contains(StudioAddCatalog.fold(q))
        }
        if !parts.isEmpty { addHeader("parts", StudioText[.addParts], nil) }
        tiles = parts.map { p in
            let tile = StudioAddTile(part: p, title: Self.partTitle(p))
            tile.onClick = { [weak page] in page?.onEvent?(.part(p)) }
            addSubview(tile)
            return tile
        }
        // Symbols.
        let symbols: [StudioSymbolIndex.Entry] = q.isEmpty
            ? StudioAddView.recentSymbols.compactMap { StudioSymbolIndex.entry(for: $0) }
            : Array(StudioSymbolIndex.search(q).prefix(8))
        if !symbols.isEmpty || q.isEmpty {
            addHeader("symbols", StudioText[.addSymbols], nil)
            addSubview(browse)
            browse.onClick = { [weak page] in page?.onEvent?(.browse) }
        }
        symbolChips = symbols.map { e in
            let chip = StudioAddChip(kind: .symbol(e.symbol), title: e.name(chinese: chinese), symbol: e.symbol)
            chip.toolTip = e.symbol
            chip.onClick = { [weak page] in page?.onEvent?(.symbol(e.symbol)) }
            addSubview(chip)
            return chip
        }
        // The widget's own colors and fonts.
        colorChips = []
        fontChips = []
        if q.isEmpty, !page.widgetColors.isEmpty || !page.widgetFonts.isEmpty {
            addHeader("widget", StudioText[.addThisWidget], nil)
            colorChips = page.widgetColors.map { c in
                let chip = StudioAddChip(kind: .color(c.id, c.color), title: c.name, symbol: nil)
                chip.toolTip = StudioText[.addColorTip]
                chip.onClick = { [weak page] in page?.onEvent?(.color(c.id)) }
                addSubview(chip)
                return chip
            }
            fontChips = page.widgetFonts.map { f in
                let chip = StudioAddChip(kind: .font(f.id), title: f.face, symbol: "textformat")
                chip.toolTip = StudioText[.addFontTip]
                chip.onClick = { [weak page] in page?.onEvent?(.font(f.id)) }
                addSubview(chip)
                return chip
            }
        }
        emptyLabel.font = .systemFont(ofSize: 11.5)
        emptyLabel.textColor = StudioPageStyle.quietInk
        emptyLabel.stringValue = StudioText.format(.addNothing, q)
        emptyLabel.isHidden = !(dataRows.isEmpty && tiles.isEmpty && symbolChips.isEmpty)
        addSubview(emptyLabel)
        needsLayout = true
    }

    static func partTitle(_ p: StudioAddCatalog.Part) -> String {
        switch p {
        case .text: return StudioText[.addText]
        case .symbol: return StudioText[.addSymbol]
        case .picture: return StudioText[.addPicture]
        case .bar: return StudioText[.showsBar]
        case .ring: return StudioText[.showsRing]
        case .graph: return StudioText[.showsGraph]
        case .shape: return StudioText[.showsShape]
        case .button: return StudioText[.addButton]
        }
    }

    private func addHeader(_ id: String, _ text: String, _ trailing: String?) {
        let h = Self.header(text)
        let t = trailing.map { Self.trailing($0) }
        addSubview(h)
        if let t { addSubview(t) }
        headers.append((h, t))
        headerFor[id] = (h, t)
    }

    /// Lays the pieces out at `width`; returns the height they take.
    @discardableResult
    func layoutAll(width: CGFloat) -> CGFloat {
        let inset: CGFloat = 16, gap: CGFloat = 6
        var y: CGFloat = 2
        func header(_ id: String) {
            guard let (h, t) = headerFor[id] else { return }
            h.frame = NSRect(x: inset, y: y + 4, width: width - 2 * inset, height: 14)
            t?.frame = NSRect(x: inset, y: y + 4, width: width - 2 * inset, height: 14)
            y += 24
        }
        func flow(_ chips: [StudioAddChip], extraLeading: CGFloat = 0) {
            guard !chips.isEmpty else { return }
            var x = inset - 2
            for chip in chips {
                let w = chip.fittingWidth
                if x + w > width - inset + 2, x > inset {
                    x = inset - 2
                    y += StudioAddChip.height + gap
                }
                chip.frame = NSRect(x: x, y: y, width: w, height: StudioAddChip.height)
                x += w + gap
            }
            y += StudioAddChip.height + 10
        }
        if !dataRows.isEmpty {
            header("data")
            for row in dataRows {
                row.frame = NSRect(x: 10, y: y, width: width - 20, height: StudioAddDataRow.height)
                y += StudioAddDataRow.height + 1
            }
            y += 8
        }
        flow(categoryChips)
        if !tiles.isEmpty {
            header("parts")
            let columns = 4
            let tileWidth = floor((width - 2 * inset + 8) / CGFloat(columns)) - 8
            for (i, tile) in tiles.enumerated() {
                let c = i % columns, r = i / columns
                tile.frame = NSRect(x: inset - 4 + CGFloat(c) * (tileWidth + 8), y: y + CGFloat(r) * (StudioAddTile.height + 8),
                                    width: tileWidth + 8, height: StudioAddTile.height)
            }
            y += CGFloat((tiles.count + columns - 1) / columns) * (StudioAddTile.height + 8) + 4
        }
        if headerFor["symbols"] != nil {
            header("symbols")
            let w = browse.fittingWidth
            browse.frame = NSRect(x: width - inset - w + 6, y: y - 24 + 1, width: w, height: 18)
            flow(symbolChips)
        }
        if headerFor["widget"] != nil {
            header("widget")
            flow(colorChips)
            flow(fontChips)
        }
        if !emptyLabel.isHidden {
            emptyLabel.frame = NSRect(x: inset, y: y + 4, width: width - 2 * inset, height: 16)
            y += 28
        }
        return y + 12
    }

    override func layout() {
        super.layout()
        layoutAll(width: bounds.width)
    }
}

/// A data item on the Add page: its symbol in its color, its name, its live value. Click: add it; drag: onto the
/// canvas.
final class StudioAddDataRow: NSView, NSDraggingSource {
    let item: StudioAddCatalog.DataItem
    let title: String
    var value = "" { didSet { if value != oldValue { needsDisplay = true; updateAccessibility() } } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?
    static let height: CGFloat = 30

    init(item: StudioAddCatalog.DataItem, title: String) {
        self.item = item
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private func updateAccessibility() {
        setAccessibilityLabel([title, value].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    static func tint(_ symbol: String) -> NSColor {
        switch symbol {
        case "cpu": return .systemBlue
        case "memorychip", "battery.75percent": return .systemGreen
        case "internaldrive": return .systemOrange
        case "cube.transparent": return .systemPurple
        case "arrow.down.circle", "arrow.up.circle": return .systemTeal
        default: return .controlAccentColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            StudioPageStyle.fieldFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let h = bounds.height
        if let image = StudioPageStyle.symbol(item.symbol, size: 12, weight: .semibold, color: Self.tint(item.symbol)) {
            image.draw(in: NSRect(x: 6 + (22 - image.size.width) / 2, y: (h - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        var right = bounds.width - 6
        if !value.isEmpty {
            let v = NSAttributedString(string: value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: StudioPageStyle.quietInk])
            let s = v.size()
            v.draw(at: NSPoint(x: right - s.width, y: (h - s.height) / 2))
            right -= s.width + 8
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                               .foregroundColor: NSColor.labelColor,
                                                               .paragraphStyle: para])
        let ts = t.size()
        t.draw(with: NSRect(x: 36, y: (h - ts.height) / 2, width: max(right - 36, 10), height: ceil(ts.height)),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downPoint = nil
        StudioAddView.currentDrag = .data(item.id)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(StudioAddCatalog.dataDragComponent, forType: .desksetComponent)
        let dragging = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragging.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if downPoint != nil { onClick?() }
        downPoint = nil
    }

    func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { StudioAddView.currentDrag = nil }
    }
}

/// A part on the Add page: its symbol in a rounded tile, its name under it. Click: add it; drag: onto the canvas.
final class StudioAddTile: NSView, NSDraggingSource {
    let part: StudioAddCatalog.Part
    let title: String
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private var downPoint: NSPoint?
    static let height: CGFloat = 60

    init(part: StudioAddCatalog.Part, title: String) {
        self.part = part
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSRect(x: (bounds.width - 48) / 2, y: 0, width: 48, height: 38)
        (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.18) : StudioPageStyle.fieldFill).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 9, yRadius: 9).fill()
        if let image = StudioPageStyle.symbol(part.symbol, size: 16, color: NSColor.labelColor.withAlphaComponent(0.75)) {
            image.draw(in: NSRect(x: tile.midX - image.size.width / 2, y: tile.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 10.5),
                                                               .foregroundColor: StudioPageStyle.quietInk,
                                                               .paragraphStyle: para])
        t.draw(with: NSRect(x: 0, y: 43, width: bounds.width, height: 14), options: [.usesLineFragmentOrigin])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downPoint = nil
        StudioAddView.currentDrag = .part(part)
        let item = NSPasteboardItem()
        item.setString(part.dragComponent, forType: .desksetComponent)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = ComponentThumbnails.dragImageOrSymbol(for: part.dragComponent,
                                                         dark: StudioPageStyle.isDark(effectiveAppearance))
        dragging.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if downPoint != nil { onClick?() }
        downPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { StudioAddView.currentDrag = nil }
    }
}

/// A capsule on the Add page: a category of data, a symbol, one of the widget's colors or fonts, or Browse….
final class StudioAddChip: NSView, NSDraggingSource {
    enum Kind: Equatable {
        case category(StudioAddCatalog.Category)
        case symbol(String)
        case color(String, RGBA)
        case font(String)
        case browse
    }

    let kind: Kind
    let title: String
    let symbol: String?
    var isOn = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var downPoint: NSPoint?
    static let height: CGFloat = 24
    static let font = NSFont.systemFont(ofSize: 11)

    init(kind: Kind, title: String, symbol: String?) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    var fittingWidth: CGFloat {
        let words = (title as NSString).size(withAttributes: [.font: Self.font]).width
        if kind == .browse { return ceil(words) + 4 }
        let lead: CGFloat = symbol != nil ? 16 : { if case .color = kind { return 16 } else { return 0 } }()
        return ceil(words) + 14 + lead
    }

    override func draw(_ dirtyRect: NSRect) {
        if kind == .browse {
            let t = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: NSColor.linkColor])
            t.draw(at: NSPoint(x: 2, y: (bounds.height - t.size().height) / 2))
            return
        }
        (isOn ? NSColor.controlAccentColor : StudioPageStyle.fieldFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        var x: CGFloat = 7
        let ink: NSColor = isOn ? .white : NSColor.labelColor.withAlphaComponent(0.82)
        if case .color(_, let c) = kind {
            let dot = NSRect(x: x, y: (bounds.height - 12) / 2, width: 12, height: 12)
            StudioPageStyle.color(c).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25)).stroke()
            x += 16
        } else if let symbol {
            let rendering: NSImage.SymbolConfiguration? = {
                if case .symbol = kind, !isOn { return .preferringMulticolor() }
                return nil
            }()
            var image = StudioPageStyle.symbol(symbol, size: 10.5, weight: .semibold, color: rendering == nil ? ink : nil)
            if let rendering, let base = image { image = base.withSymbolConfiguration(rendering) }
            if let image {
                image.draw(in: NSRect(x: x + (12 - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                                      width: image.size.width, height: image.size.height), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            x += 16
        }
        let t = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: ink])
        t.draw(at: NSPoint(x: x, y: (bounds.height - t.size().height) / 2))
    }

    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, case .symbol(let s) = kind else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downPoint = nil
        StudioAddView.currentDrag = .symbol(s)
        let item = NSPasteboardItem()
        item.setString(StudioAddCatalog.Part.symbol.dragComponent, forType: .desksetComponent)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if downPoint != nil { onClick?() }
        downPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { StudioAddView.currentDrag = nil }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
