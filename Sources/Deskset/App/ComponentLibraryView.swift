import AppKit
import DesksetCore

extension NSPasteboard.PasteboardType {
    /// A component dragged out of the component library; the string is its `EditorComponents` id.
    static let desksetComponent = NSPasteboard.PasteboardType("com.deskset.editor.component")
}

// MARK: - Thumbnails

/// Previews of library components drawn by the real renderer. The component's sections are written into a temporary
/// skin, loaded with a `RenderHost` (no window, and app plugins treat such skins as not running in the app, so no
/// permission prompts and no Apple Events), updated with steady sample readings and drawn off-screen. Rendering is
/// cheap but not free (a skin load and a few dozen updates), so results are cached per component and appearance.
enum ComponentThumbnails {
    /// Space around the component inside a thumbnail (points).
    static let padding: CGFloat = 12
    /// Updates before drawing (the first lays the skin out); graphs get one per point of history so they are full.
    static let updates = 3
    /// Largest side of a preview, in points (a component is never that big; this only bounds the bitmap).
    static let maxSide: Double = 1024

    private static var thumbnails: [String: NSImage] = [:]
    private static var previews: [String: NSImage] = [:]
    /// Keys that could not be rendered (not retried until the cache is cleared).
    private static var failed: Set<String> = []

    /// Backdrop of thumbnails: a neutral dark tone in both appearances, since components are light on dark like
    /// most desktop widgets; a touch lighter in the light appearance so the tiles don't look like holes in a light
    /// sidebar.
    static func backdrop(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.133, alpha: 1)
            : NSColor(srgbRed: 0.196, green: 0.204, blue: 0.231, alpha: 1)
    }

    private static func key(_ id: String, dark: Bool) -> String { "\(id)|\(dark ? "dark" : "light")" }

    /// The component on the backdrop with `padding` around it, at its real size (2x bitmap). Cached.
    static func thumbnail(for id: String, dark: Bool) -> NSImage? {
        let k = key(id, dark: dark)
        if let image = thumbnails[k] { return image }
        if failed.contains(k) { return nil }
        guard let loaded = loadSkin(id) else {
            failed.insert(k)
            return nil
        }
        defer { loaded.close() }
        guard let area = bounds(of: loaded.skin),
              let image = render(loaded.skin, area: area, padding: padding, backdrop: backdrop(dark: dark)) else {
            failed.insert(k)
            return nil
        }
        thumbnails[k] = image
        return image
    }

    /// The cached thumbnail, without rendering one.
    static func cachedThumbnail(for id: String, dark: Bool) -> NSImage? { thumbnails[key(id, dark: dark)] }

    /// True when `thumbnail(for:dark:)` answers at once (rendered, or known not to render).
    static func isResolved(_ id: String, dark: Bool) -> Bool {
        let k = key(id, dark: dark)
        return thumbnails[k] != nil || failed.contains(k)
    }

    /// The component alone on a transparent background, at its real size with its top-left corner at the image's
    /// (0, 0) — what the canvas draws inside the drop ghost. Cached.
    static func preview(for id: String) -> NSImage? {
        let k = key(id, dark: false) + "|preview"
        if let image = previews[k] { return image }
        if failed.contains(k) { return nil }
        guard let loaded = loadSkin(id) else {
            failed.insert(k)
            return nil
        }
        defer { loaded.close() }
        // From the corner (0, 0): parts of the component start there even when its first pixels don't.
        guard let area = bounds(of: loaded.skin),
              let image = render(loaded.skin, area: SkinRect(x: 0, y: 0, width: area.maxX, height: area.maxY),
                                 padding: 0, backdrop: nil, scale: 3) else {
            failed.insert(k)
            return nil
        }
        previews[k] = image
        return image
    }

    /// A drag image for the card: the thumbnail with rounded corners, slightly translucent.
    static func dragImage(for id: String, dark: Bool) -> NSImage? {
        guard let thumbnail = thumbnail(for: id, dark: dark) else { return nil }
        let size = thumbnail.size
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
            thumbnail.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.9)
            return true
        }
    }

    /// `dragImage`, or the component's symbol when it has no thumbnail: a drag always shows something. Used by the
    /// card that starts the drag and by the canvas when it gives the drag its image back.
    static func dragImageOrSymbol(for id: String, dark: Bool) -> NSImage {
        dragImage(for: id, dark: dark)
            ?? EditorComponents.component(id).flatMap { EditorStyle.image($0.symbol, size: 28) }
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    static func clearCache() {
        thumbnails = [:]
        previews = [:]
        failed = []
    }

    /// A component loaded into its own temporary skin; `close()` stops the skin and removes the folder.
    struct Loaded {
        let skin: Skin
        let host: RenderHost
        let folder: URL

        func close() {
            skin.close()
            withExtendedLifetime(host) {}
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Loads component `id` into a temporary skin with its corner at (x, y) and runs `updates` updates (nil: enough
    /// to fill its graphs).
    static func loadSkin(_ id: String, x: Double = 0, y: Double = 0, updates: Int? = nil,
                         system: SystemDataSource = ComponentSampleSystem()) -> Loaded? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesksetComponent-\(UUID().uuidString)", isDirectory: true)
        let skins = folder.appendingPathComponent("Skins", isDirectory: true)
        let dir = skins.appendingPathComponent("Library", isDirectory: true)
        let file = dir.appendingPathComponent("Component.ini")
        var ini = "[Rainmeter]\nUpdate=1000\n"
        for s in EditorComponents.sections(for: id, x: x, y: y, existing: [], variables: []) {
            ini += "\n[\(s.name)]\n" + s.options.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
        }
        let host = RenderHost()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ini.write(to: file, atomically: true, encoding: .utf8)
            let skin = Skin(config: "Library", fileURL: file, skinsDirectory: skins, system: system, host: host)
            let sample = system as? ComponentSampleSystem
            // The sample readings' own clock: network speeds come out exact without waiting between updates.
            if let sample { skin.clock = { sample.clock } }
            try skin.load()
            let graphs = skin.meters.filter { $0 is LineMeter || $0 is HistogramMeter }
            var count = max(updates ?? Self.updates, 1)
            var i = 0
            while i < count {
                sample?.step = i
                skin.update()
                if i == 0, updates == nil, !graphs.isEmpty {
                    // The first update laid the graphs out: one more update per point of their width.
                    count = max(count, Int(min(graphs.map(\.frame.width).max() ?? 0, 2000)) + 1)
                }
                i += 1
            }
            return Loaded(skin: skin, host: host, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Union of the skin's visible meter frames (nil when nothing has an area).
    static func bounds(of skin: Skin) -> SkinRect? {
        let frames = skin.meters.filter { !$0.hidden && !$0.isContainer && $0.frame.width > 0 && $0.frame.height > 0 }
            .map(\.frame)
        guard let first = frames.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for f in frames.dropFirst() {
            minX = min(minX, f.x)
            minY = min(minY, f.y)
            maxX = max(maxX, f.maxX)
            maxY = max(maxY, f.maxY)
        }
        guard maxX - minX <= maxSide, maxY - minY <= maxSide else { return nil }
        return SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Draws `area` of the skin (plus `padding`) into a bitmap-backed image, the way `--render` does.
    private static func render(_ skin: Skin, area: SkinRect, padding: CGFloat, backdrop: NSColor?,
                               scale: CGFloat = 2) -> NSImage? {
        let size = NSSize(width: ceil(CGFloat(area.width) + 2 * padding), height: ceil(CGFloat(area.height) + 2 * padding))
        let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let cg = context.cgContext
        let full = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
        cg.clear(full)
        if let backdrop {
            cg.setFillColor(backdrop.cgColor)
            cg.fill(full)
        }
        // Rainmeter's top-left origin, the backing scale, then the area's corner at (padding, padding).
        cg.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: padding - CGFloat(area.x), y: padding - CGFloat(area.y))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        SkinRenderer.draw(skin, in: cg)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// Steady, plausible readings for thumbnails, so every card looks the same on every Mac (and a CPU graph has a
/// history to show) while measures, meters and the renderer are the real ones. `step` moves the CPU curve along, and
/// the clock the network speeds are measured on.
final class ComponentSampleSystem: SystemDataSource {
    var step = 0
    private static let gib = 1_073_741_824.0

    var processorCount: Int { 8 }

    func cpuUsage(processor: Int) -> Double {
        let t = Double(step)
        return min(max(38 + 14 * sin(t * 0.11) + 7 * sin(t * 0.37 + 1) + 3 * sin(t * 1.3), 0), 100)
    }

    func memoryStatus() -> MemoryStatus {
        MemoryStatus(physicalTotal: 16 * Self.gib, physicalUsed: 10.4 * Self.gib, swapTotal: 2 * Self.gib,
                     swapUsed: 0.5 * Self.gib)
    }

    func networkInterfaces() -> [String] { ["en0"] }

    /// Seconds on the clock of the skins these readings are for (`ComponentThumbnails.loadSkin` gives it to them): one
    /// per step.
    var clock: TimeInterval { Double(step) }

    /// Counters that grow at a constant rate on `clock` (2.4 MB/s down, 310 kB/s up), so the speed is exact however
    /// quickly the updates run.
    func networkCounters(interface: String?) -> NetworkCounters {
        NetworkCounters(received: UInt64(clock * 2_400_000), sent: UInt64(clock * 310_000))
    }

    func diskSpace(path: String) -> (total: Double, free: Double)? { (460 * Self.gib, 188 * Self.gib) }
    /// 3 days, 4 hours, 5 minutes.
    func uptime() -> TimeInterval { 273_912 }
    func battery() -> BatteryStatus? {
        BatteryStatus(percent: 76, isCharging: false, isPluggedIn: false, minutesRemaining: 312)
    }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
}

// MARK: - Library view

/// The Library tab of the skin editor's sidebar: a search field, category chips and a grid of component cards.
/// Each card shows a live thumbnail (drawn by the real renderer), a plain name, a one-line description and the data
/// it shows. Clicking a card (or Return on a focused card, or Return in the search field for the best match) calls
/// `onInsert`; dragging a card onto the canvas drops it where the ghost shows (`SkinCanvasView`).
///
/// Layout is frame-based (the view is flipped): search on top, chips wrapping below, the grid filling the rest with
/// as many columns as fit. The view draws no background of its own, so it sits on the sidebar material.
final class ComponentLibraryView: NSView, NSSearchFieldDelegate {
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8
    /// Two columns fit from the sidebar's minimum width (220 points) on.
    static let minCardWidth: CGFloat = 92

    let searchField = NSSearchField()
    private var chips: [ChipButton] = []
    private let scroll = NSScrollView()
    private let grid = LibraryGridView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// What to do with the cards, always shown under the search field (docs/editor-friendly.md §5.1).
    let hint = NSTextField(wrappingLabelWithString: "Drag onto your widget, or click to add it below what's there.")
    private(set) var cards: [ComponentCardView] = []
    private let onInsert: (String) -> Void
    /// The category chip that is on (nil = All).
    private(set) var category: EditorComponents.Category?
    /// Ids of the cards shown, in display order (best search matches first).
    private(set) var visibleIDs: [String] = []
    private(set) var columns = 1
    private var thumbnailsScheduled = false

    init(onInsert: @escaping (String) -> Void) {
        self.onInsert = onInsert
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Things to add")

        searchField.placeholderString = "Search things to add"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.controlSize = .regular
        searchField.setAccessibilityLabel("Search things to add")
        addSubview(searchField)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        addSubview(hint)

        let all = ChipButton(title: "All", target: self, action: #selector(chipClicked(_:)))
        all.tag = -1
        chips = [all] + EditorComponents.Category.allCases.enumerated().map { i, c in
            let chip = ChipButton(title: c.title, target: self, action: #selector(chipClicked(_:)))
            chip.tag = i
            return chip
        }
        chips.forEach(addSubview)

        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        grid.addSubview(emptyLabel)

        cards = EditorComponents.all.map { c in
            let card = ComponentCardView(component: c)
            card.onInsert = { [weak self] id in self?.onInsert(id) }
            card.onArrowKey = { [weak self] card, key in self?.moveFocus(from: card, key) ?? false }
            grid.addSubview(card)
            return card
        }
        applyFilter()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Public API

    /// Puts the cursor in the search field with its text selected (toolbar "+ Library", ⇧⌘L).
    func focusSearch() {
        guard let window else { return }
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Filters the grid as typing in the search field and clicking a chip would (also used by the self-tests).
    func setFilter(query: String, category: EditorComponents.Category?) {
        searchField.stringValue = query
        self.category = category
        applyFilter()
    }

    var query: String { searchField.stringValue }

    /// The card showing component `id`.
    func card(for id: String) -> ComponentCardView? { cards.first { $0.component.id == id } }

    /// Renders every missing thumbnail now (snapshots and self-tests; the window renders them one per run-loop
    /// turn so it opens at once).
    func loadThumbnails() {
        let dark = isDark
        for card in cards { card.setThumbnail(ComponentThumbnails.thumbnail(for: card.component.id, dark: dark), dark: dark) }
    }

    // MARK: Filtering

    @objc private func searchChanged() { applyFilter() }

    @objc private func chipClicked(_ sender: ChipButton) {
        let all = EditorComponents.Category.allCases
        category = sender.tag >= 0 && sender.tag < all.count ? all[sender.tag] : nil
        applyFilter()
    }

    private func applyFilter() {
        let results = EditorComponents.search(query, category: category)
        visibleIDs = results.map(\.id)
        let allCategories = EditorComponents.Category.allCases
        for chip in chips {
            let on = chip.tag < 0 ? category == nil : allCategories[chip.tag] == category
            chip.state = on ? .on : .off
        }
        let shown = Set(visibleIDs)
        for card in cards { card.isHidden = !shown.contains(card.component.id) }
        if results.isEmpty {
            let q = query.trimmingCharacters(in: .whitespaces)
            emptyLabel.stringValue = q.isEmpty ? "Nothing in this category." : "Nothing matches “\(q)”."
        }
        emptyLabel.isHidden = !results.isEmpty
        // Tab order: search field, then the cards as shown.
        let visible = visibleCards
        searchField.nextKeyView = visible.first
        for (i, card) in visible.enumerated() { card.nextKeyView = i + 1 < visible.count ? visible[i + 1] : nil }
        layoutGrid()
        grid.scroll(.zero)
    }

    private var visibleCards: [ComponentCardView] { visibleIDs.compactMap { card(for: $0) } }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Quick insert: type a name, press Return.
            guard let first = visibleIDs.first else { NSSound.beep(); return true }
            onInsert(first)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard let first = visibleCards.first else { return false }
            window?.makeFirstResponder(first)
            first.scrollToVisible(first.bounds)
            return true
        default:
            return false
        }
    }

    /// Arrow keys move the focus through the grid; up from the first row goes back to the search field.
    private func moveFocus(from card: ComponentCardView, _ key: NSEvent.SpecialKey) -> Bool {
        let visible = visibleCards
        guard let i = visible.firstIndex(where: { $0 === card }) else { return false }
        let j: Int
        switch key {
        case .leftArrow: j = i - 1
        case .rightArrow: j = i + 1
        case .upArrow: j = i - columns
        case .downArrow: j = i + columns
        default: return false
        }
        if j < 0 {
            if key == .upArrow || i == 0 { focusSearch() }
            return true
        }
        guard j < visible.count else { return true }
        window?.makeFirstResponder(visible[j])
        visible[j].scrollToVisible(visible[j].bounds)
        return true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let inset = Self.inset
        let width = bounds.width
        let fieldHeight = max(searchField.intrinsicContentSize.height, 22)
        searchField.frame = NSRect(x: inset, y: 10, width: max(width - 2 * inset, 40), height: fieldHeight)
        let hintWidth = max(width - 2 * inset, 40)
        let hintHeight = ceil(hint.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: hintWidth, height: 200)).height ?? 14)
        hint.frame = NSRect(x: inset, y: searchField.frame.maxY + 6, width: hintWidth, height: hintHeight)
        var x = inset, y = hint.frame.maxY + 8
        let chipHeight = ChipButton.height
        for chip in chips {
            let w = chip.intrinsicContentSize.width
            if x + w > width - inset, x > inset {
                x = inset
                y += chipHeight + 6
            }
            chip.frame = NSRect(x: x, y: y, width: w, height: chipHeight)
            x += w + 6
        }
        y += chipHeight + 10
        scroll.frame = NSRect(x: 0, y: y, width: width, height: max(bounds.height - y, 0))
        layoutGrid()
    }

    private func layoutGrid() {
        let inset = Self.inset, gap = Self.gap
        let width = max(scroll.contentSize.width, 1)
        columns = max(1, Int((width - 2 * inset + gap) / (Self.minCardWidth + gap)))
        let cardWidth = max(floor((width - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns)), 1)
        let cardHeight = ComponentCardView.height
        let visible = visibleCards
        for (i, card) in visible.enumerated() {
            let column = i % columns, row = i / columns
            card.frame = NSRect(x: inset + CGFloat(column) * (cardWidth + gap), y: 2 + CGFloat(row) * (cardHeight + gap),
                                width: cardWidth, height: cardHeight)
        }
        let rows = (visible.count + columns - 1) / columns
        let content = 2 + CGFloat(rows) * (cardHeight + gap) + inset
        grid.frame = NSRect(x: 0, y: 0, width: width, height: max(content, scroll.contentSize.height))
        emptyLabel.frame = NSRect(x: inset, y: 24, width: max(width - 2 * inset, 1), height: 18)
    }

    // MARK: Thumbnails

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleThumbnails() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scheduleThumbnails()
    }

    /// Shows cached thumbnails for the current appearance and renders the missing ones one per run-loop turn
    /// (cards in view first), so opening the library never waits for all of them.
    private func scheduleThumbnails() {
        let dark = isDark
        for card in cards where card.thumbnailDark != dark {
            if ComponentThumbnails.isResolved(card.component.id, dark: dark) {
                card.setThumbnail(ComponentThumbnails.thumbnail(for: card.component.id, dark: dark), dark: dark)
            } else {
                card.setThumbnail(nil, dark: nil)
            }
        }
        guard !thumbnailsScheduled, window != nil else { return }
        let pending = visibleCards.filter { $0.thumbnailDark != dark } + cards.filter { $0.isHidden && $0.thumbnailDark != dark }
        guard let next = pending.first else { return }
        thumbnailsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.thumbnailsScheduled = false
            let dark = self.isDark
            next.setThumbnail(ComponentThumbnails.thumbnail(for: next.component.id, dark: dark), dark: dark)
            self.scheduleThumbnails()
        }
    }

    // MARK: Snapshot

    /// `Deskset --snapshot-ui library`: the library in an off-screen window with every thumbnail rendered.
    static func snapshot(query: String?, category: String?, size: NSSize = NSSize(width: 280, height: 760)) -> NSBitmapImageRep? {
        let library = ComponentLibraryView(onInsert: { _ in })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = library
        library.loadThumbnails()
        library.setFilter(query: query ?? "", category: category.flatMap { EditorComponents.Category(rawValue: $0.lowercased()) })
        library.layoutSubtreeIfNeeded()
        guard let rep = library.bitmapImageRepForCachingDisplay(in: library.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let dark = library.isDark
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // A stand-in for the sidebar material, which does not draw off-screen.
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(srgbRed: 0.925, green: 0.922, blue: 0.918, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        NSGraphicsContext.restoreGraphicsState()
        library.displayIgnoringOpacity(library.bounds, in: context)
        return rep
    }
}

/// The grid's document view (flipped, so cards fill from the top).
final class LibraryGridView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Chip

/// A category filter: a small capsule, filled with the accent color while it is on.
final class ChipButton: NSButton {
    static let height: CGFloat = 22
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.pushOnPushOff)
        isBordered = false
        font = Self.font
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(width) + 20, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07)).setFill()
        path.fill()
        let text = NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: on ? NSColor.white : NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

// MARK: - Card

/// One component in the library grid: thumbnail with the data badge, name and a short description. A click inserts
/// it, a drag carries its id to the canvas (pasteboard type `com.deskset.editor.component`; the drag image is the
/// thumbnail), Return or Space inserts it while it has the keyboard focus.
final class ComponentCardView: NSView, NSDraggingSource {
    static let height: CGFloat = 130
    static let thumbnailHeight: CGFloat = 70
    static let padding: CGFloat = 5

    let component: EditorComponents.Component
    private(set) var thumbnail: NSImage?
    /// The appearance the thumbnail was rendered for (nil = none yet).
    private(set) var thumbnailDark: Bool?
    var onInsert: ((String) -> Void)?
    var onArrowKey: ((ComponentCardView, NSEvent.SpecialKey) -> Bool)?

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var downPoint: NSPoint?
    private var dragging = false
    private var trackingArea: NSTrackingArea?

    init(component: EditorComponents.Component) {
        self.component = component
        super.init(frame: .zero)
        // The whole title and summary (the card cuts them to its width).
        toolTip = "\(component.title) — " + (component.badge.map { "\(component.summary) · \($0)" } ?? component.summary)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(component.title)
        setAccessibilityHelp(component.summary)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHidden }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setThumbnail(_ image: NSImage?, dark: Bool?) {
        thumbnail = image
        thumbnailDark = dark
        needsDisplay = true
    }

    func insert() { onInsert?(component.id) }

    override func accessibilityPerformPress() -> Bool {
        insert()
        return true
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49:  // Return, Enter, Space
            insert()
        default:
            if let key = event.specialKey, onArrowKey?(self, key) == true { return }
            super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        dragging = false
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = downPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) >= 3 else { return }
        dragging = true
        pressed = false
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let click = pressed && !dragging && bounds.contains(p)
        pressed = false
        downPoint = nil
        if click { insert() }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The pasteboard item a drag carries: the component id under `.desksetComponent`.
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(component.id, forType: .desksetComponent)
        return item
    }

    private func beginDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem())
        let image = ComponentThumbnails.dragImageOrSymbol(for: component.id, dark: isDark)
        let p = convert(event.locationInWindow, from: nil)
        // Centred on the pointer, like the ghost the canvas shows.
        item.setDraggingFrame(NSRect(x: p.x - image.size.width / 2, y: p.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // ⌘ during a drag asks for the generic operation (it turns snapping off on the canvas).
        context == .withinApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        downPoint = nil
    }

    // MARK: Drawing

    var thumbnailRect: NSRect {
        NSRect(x: Self.padding, y: Self.padding, width: max(bounds.width - 2 * Self.padding, 1), height: Self.thumbnailHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDark
        if hovering || pressed {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.1 : 0.055).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        let thumb = thumbnailRect
        let tile = NSBezierPath(roundedRect: thumb, xRadius: 8, yRadius: 8)
        ComponentThumbnails.backdrop(dark: dark).setFill()
        tile.fill()
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        if let thumbnail {
            // The component (most of the image's padding left out) at its real size when it fits, scaled down
            // otherwise, centred — or below the badge when it would run into it. The image's backdrop matches the
            // tile's.
            let margin = max(ComponentThumbnails.padding - 4, 0)
            let source = NSRect(origin: .zero, size: thumbnail.size).insetBy(dx: margin, dy: margin)
            let area = thumb.insetBy(dx: 6, dy: 6)
            var r = Self.fit(source.size, in: area)
            if let badge = badgeRect(in: thumb), r.intersects(badge.insetBy(dx: -2, dy: -2)) {
                var below = area
                below.origin.y = badge.maxY + 3
                below.size.height = max(area.maxY - below.minY, 1)
                r = Self.fit(source.size, in: below)
            }
            thumbnail.draw(in: r, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high])
        } else if let symbol = EditorStyle.image(component.symbol, size: 20, weight: .light) {
            // Until the thumbnail is rendered.
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor(white: 1, alpha: 0.35).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: thumb.midX - symbol.size.width / 2, y: thumb.midY - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: dark ? 0.07 : 0.0).setStroke()
        tile.lineWidth = 1
        tile.stroke()
        drawBadge(in: thumb)

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: component.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titleStyle,
        ])
        let textX = Self.padding + 1, textWidth = max(bounds.width - 2 * textX, 1)
        title.draw(with: NSRect(x: textX, y: thumb.maxY + 6, width: textWidth, height: 16),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.lineBreakMode = .byWordWrapping
        let summary = NSAttributedString(string: component.summary, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: summaryStyle,
        ])
        summary.draw(with: NSRect(x: textX, y: thumb.maxY + 23, width: textWidth, height: 28),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// `size` scaled down to fit `area` (never up), centred in it.
    static func fit(_ size: NSSize, in area: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return NSRect(x: area.midX, y: area.midY, width: 0, height: 0) }
        let s = min(1, area.width / size.width, area.height / size.height)
        let w = size.width * s, h = size.height * s
        return NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    private var badgeText: NSAttributedString? {
        component.badge.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.85),
            ])
        }
    }

    /// Where the badge goes: a small capsule in the thumbnail's top-right corner.
    private func badgeRect(in thumb: NSRect) -> NSRect? {
        guard let text = badgeText else { return nil }
        let width = ceil(text.size().width) + 12
        return NSRect(x: thumb.maxX - width - 4, y: thumb.minY + 4, width: width, height: 15)
    }

    private func drawBadge(in thumb: NSRect) {
        guard let text = badgeText, let pill = badgeRect(in: thumb) else { return }
        NSColor(white: 1, alpha: 0.13).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
        text.draw(at: NSPoint(x: pill.minX + 6, y: pill.midY - text.size().height / 2))
    }
}
