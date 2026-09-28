import AppKit
import DesksetCore

extension NSPasteboard.PasteboardType {
    /// A part dragged within the Studio's Layers list (the string is the meter's name).
    static let desksetStudioLayer = NSPasteboard.PasteboardType("app.deskset.studio.layer")
}

/// What is done in the Layers list, for the window to carry out.
enum StudioLayersEvent: Equatable {
    /// A part selected (nil: the widget's row).
    case selectPart(String?)
    case selectData(String)
    /// The pointer is on a data row (nil: off it).
    case hoverData(String?)
    case toggleHidden(String)
    case toggleLock(String)
    /// Parts moved right before `before` in the file (nil: after the last part, to the front).
    case move([String], before: String?)
    case delete(String)
    /// What is typed in "Find a layer".
    case filter(String)
}

/// A node of the lists (NSOutlineView keeps items by identity; nodes are kept by id across reloads).
final class StudioLayerNode: NSObject {
    var item: StudioLayerItem
    var children: [StudioLayerNode] = []

    init(_ item: StudioLayerItem) {
        self.item = item
    }
}

/// The Layers page of the sidebar: "Find a layer", the list — the widget's row, its parts in file order, each named by
/// what it shows with its live value, an amber dot when something needs attention, the eye and the lock — and the
/// data group at the bottom ("Measures" with Rainmeter details on, else "Data"), each with its live value. The parts
/// list takes the room it needs; when it is long, the data group keeps up to about two fifths of the page at the
/// bottom, each with a scroll of its own, so both stay in reach.
final class StudioLayersView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let partsScroll = OverlayScrollView()
    let partsOutline = SidebarOutlineView()
    let dataHeader = NSTextField(labelWithString: "")
    let dataScroll = OverlayScrollView()
    let dataOutline = SidebarOutlineView()
    let emptyLabel = NSTextField(labelWithString: "")

    var onEvent: ((StudioLayersEvent) -> Void)?

    private(set) var lists: StudioLayersModel.Lists?
    private let root = StudioLayerNode(StudioLayerItem(id: "widget", kind: .widget, name: "", title: "", glyph: "square.dashed",
                                                        accessibility: ""))
    private var partNodes: [String: StudioLayerNode] = [:]
    private var dataNodes: [StudioLayerNode] = []
    private var syncing = false
    /// The parts outlined because they use the pointed-at (or selected) data item.
    private(set) var outlinedParts: Set<String> = []
    /// The data row the pointer is on.
    private(set) var hoveredData: String?

    static let rowHeight: CGFloat = 26
    static let tallRowHeight: CGFloat = 34
    static let dataRowHeight: CGFloat = 32
    static let searchHeight: CGFloat = 28
    static let headerHeight: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = StudioText[.findLayer]
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.setAccessibilityLabel(StudioText[.findLayer])
        addSubview(searchField)

        for (outline, scroll) in [(partsOutline, partsScroll), (dataOutline, dataScroll)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
            column.resizingMask = .autoresizingMask
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.headerView = nil
            outline.style = .plain
            outline.backgroundColor = .clear
            outline.selectionHighlightStyle = .regular
            outline.rowSizeStyle = .custom
            outline.intercellSpacing = NSSize(width: 0, height: 1)
            outline.indentationPerLevel = 14
            outline.autoresizesOutlineColumn = false
            outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            outline.floatsGroupRows = false
            outline.dataSource = self
            outline.delegate = self
            outline.target = self
            outline.doubleAction = #selector(rowDoubleClicked(_:))
            scroll.documentView = outline
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsetsZero
            addSubview(scroll)
        }
        partsOutline.setAccessibilityLabel(StudioText[.tabLayers])
        partsOutline.registerForDraggedTypes([.desksetStudioLayer])
        partsOutline.setDraggingSourceOperationMask(.move, forLocal: true)
        partsOutline.draggingDestinationFeedbackStyle = .gap
        dataHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        dataHeader.textColor = StudioPageStyle.quietInk
        addSubview(dataHeader)
        emptyLabel.font = .systemFont(ofSize: 11.5)
        emptyLabel.textColor = StudioPageStyle.quietInk
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: Showing the lists

    /// Shows `lists`: rows that stay are updated in place (their selection, hover and scroll kept).
    func show(_ lists: StudioLayersModel.Lists, details: Bool) {
        let old = self.lists
        self.lists = lists
        dataHeader.stringValue = details ? StudioText[.measuresGroup] : StudioText[.dataGroup]
        let sameParts = old.map { $0.parts.map(\.id) == lists.parts.map(\.id) && $0.widget.id == lists.widget.id } ?? false
        let sameData = old.map { $0.data.map(\.id) == lists.data.map(\.id) } ?? false
        let heightsSame = old.map { o in
            zip(o.parts, lists.parts).allSatisfy { ($0.subtitle == nil) == ($1.subtitle == nil) }
                && zip(o.data, lists.data).allSatisfy { ($0.subtitle == nil) == ($1.subtitle == nil) }
        } ?? false
        root.item = lists.widget
        syncing = true
        defer { syncing = false }
        if sameParts && heightsSame {
            for (i, item) in lists.parts.enumerated() where partNodes[item.id]?.item != item {
                partNodes[item.id]?.item = item
                let row = partsOutline.row(forItem: root.children[i])
                if row >= 0 { refreshRow(partsOutline, row) }
            }
            let rootRow = partsOutline.row(forItem: root)
            if rootRow >= 0 { refreshRow(partsOutline, rootRow) }
        } else {
            let selected = selectedPartNames
            var nodes: [String: StudioLayerNode] = [:]
            root.children = lists.parts.map { item in
                let node = partNodes[item.id] ?? StudioLayerNode(item)
                node.item = item
                nodes[item.id] = node
                return node
            }
            partNodes = nodes
            partsOutline.reloadData()
            partsOutline.expandItem(root)
            select(parts: selected, notify: false)
        }
        if sameData && heightsSame {
            for (i, item) in lists.data.enumerated() where dataNodes[i].item != item {
                dataNodes[i].item = item
                refreshRow(dataOutline, i)
            }
        } else {
            let selected = dataOutline.selectedRow >= 0 ? dataNodes[dataOutline.selectedRow].item.name : nil
            dataNodes = lists.data.map { StudioLayerNode($0) }
            dataOutline.reloadData()
            if let selected { select(data: selected, notify: false) }
        }
        let filter = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        emptyLabel.stringValue = filter.isEmpty ? StudioText[.layersEmpty] : StudioText.format(.noLayersFound, filter)
        emptyLabel.isHidden = !(lists.parts.isEmpty && (lists.data.isEmpty || filter.isEmpty))
        dataHeader.isHidden = lists.data.isEmpty
        dataScroll.isHidden = lists.data.isEmpty
        needsLayout = true
    }

    private func refreshRow(_ outline: NSOutlineView, _ row: Int) {
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? StudioLayerCell,
              let node = outline.item(atRow: row) as? StudioLayerNode else { return }
        cell.item = node.item
        cell.outlined = outlinedParts.contains(node.item.name.lowercased()) && node.item.kind == .part
    }

    /// The node of the part `name`.
    func node(part name: String) -> StudioLayerNode? { partNodes["part:\(name)"] ?? partNodes.values.first {
        $0.item.name.caseInsensitiveCompare(name) == .orderedSame } }

    // MARK: Selection

    var selectedPartNames: [String] {
        partsOutline.selectedRowIndexes.compactMap { (partsOutline.item(atRow: $0) as? StudioLayerNode)?.item }
            .filter { $0.kind == .part }.map(\.name)
    }

    var selectedData: String? {
        let row = dataOutline.selectedRow
        return row >= 0 && row < dataNodes.count ? dataNodes[row].item.name : nil
    }

    /// Selects the rows of `parts` (the canvas's selection); none: the widget's row when `widget`, else nothing.
    func select(parts: [String], widget: Bool = false, notify: Bool = false) {
        syncing = !notify
        defer { syncing = false }
        var rows = IndexSet()
        for name in parts {
            if let n = node(part: name) {
                let row = partsOutline.row(forItem: n)
                if row >= 0 { rows.insert(row) }
            }
        }
        if rows.isEmpty, widget {
            let r = partsOutline.row(forItem: root)
            if r >= 0 { rows.insert(r) }
        }
        partsOutline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { partsOutline.scrollRowToVisible(first) }
        if !rows.isEmpty { dataOutline.deselectAll(nil) }
    }

    func select(data name: String?, notify: Bool = false) {
        syncing = !notify
        defer { syncing = false }
        guard let name, let i = dataNodes.firstIndex(where: { $0.item.name.caseInsensitiveCompare(name) == .orderedSame })
        else {
            dataOutline.deselectAll(nil)
            return
        }
        dataOutline.selectRowIndexes([i], byExtendingSelection: false)
        dataOutline.scrollRowToVisible(i)
        partsOutline.deselectAll(nil)
    }

    /// Outlines the rows of the parts that use a data item (nil: none).
    func outline(parts names: [String]) {
        let set = Set(names.map { $0.lowercased() })
        guard set != outlinedParts else { return }
        outlinedParts = set
        for row in 0..<partsOutline.numberOfRows { refreshRow(partsOutline, row) }
    }

    /// The pointer is on a data row (self-tests and snapshots set it as the pointer would).
    func setHoveredData(_ name: String?) {
        guard hoveredData != name else { return }
        hoveredData = name
        for (i, node) in dataNodes.enumerated() {
            (dataOutline.rowView(atRow: i, makeIfNecessary: false) as? StudioLayerRowView)?
                .setHovered(node.item.name == name, notify: false)
        }
        onEvent?(.hoverData(name))
    }

    // MARK: Filter

    @objc func filterChanged() {
        onEvent?(.filter(searchField.stringValue))
    }

    func setFilter(_ text: String) {
        searchField.stringValue = text
        filterChanged()
    }

    // MARK: Layout

    /// The height of an outline's rows.
    static func contentHeight(_ outline: NSOutlineView) -> CGFloat {
        let n = outline.numberOfRows
        guard n > 0 else { return 0 }
        return outline.rect(ofRow: n - 1).maxY
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        searchField.frame = NSRect(x: 10, y: 0, width: max(w - 20, 40), height: Self.searchHeight)
        var y = Self.searchHeight + 8
        let available = max(bounds.height - y, 0)
        let partsContent = Self.contentHeight(partsOutline)
        let dataContent = dataScroll.isHidden ? 0 : Self.contentHeight(dataOutline)
        let header = dataScroll.isHidden ? 0 : Self.headerHeight
        // The data group keeps up to two fifths of the page (at least three rows) when the parts are many.
        let dataCap = dataScroll.isHidden ? 0 : max(available * 0.42, min(dataContent, 3 * (Self.dataRowHeight + 1)))
        let dataHeight = min(dataContent, dataCap)
        var partsHeight = min(partsContent, max(available - header - dataHeight, 0))
        // A list cut short ends on a whole row.
        if partsHeight < partsContent {
            var whole: CGFloat = 0
            for row in 0..<partsOutline.numberOfRows {
                let maxY = partsOutline.rect(ofRow: row).maxY
                if maxY > partsHeight { break }
                whole = maxY
            }
            if whole > 0 { partsHeight = whole }
        }
        partsScroll.frame = NSRect(x: 0, y: y, width: w, height: partsHeight)
        y += partsHeight
        if !emptyLabel.isHidden {
            emptyLabel.frame = NSRect(x: 16, y: y + 6, width: max(w - 32, 0), height: 16)
            y += 28
        }
        dataHeader.frame = NSRect(x: 16, y: y + 8, width: max(w - 32, 0), height: 14)
        y += header
        let dataRoom = min(dataContent, max(bounds.height - y, 0))
        dataScroll.frame = NSRect(x: 0, y: y, width: w, height: dataRoom)
        for outline in [partsOutline, dataOutline] {
            outline.tableColumns.first?.width = max(w - 2, 10)
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // Delete (⌫ or ⌦) on a selected part.
        if [51, 117].contains(event.keyCode), window?.firstResponder === partsOutline,
           let name = selectedPartNames.first {
            onEvent?(.delete(name))
            return
        }
        super.keyDown(with: event)
    }

    @objc func rowDoubleClicked(_ sender: Any?) {}

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if outlineView === dataOutline { return item == nil ? dataNodes.count : 0 }
        if item == nil { return lists == nil ? 0 : 1 }
        return (item as? StudioLayerNode) === root ? root.children.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if outlineView === dataOutline { return dataNodes[index] }
        if item == nil { return root }
        return root.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        outlineView === partsOutline && (item as? StudioLayerNode) === root
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard outlineView === partsOutline, let node = item as? StudioLayerNode, node.item.kind == .part,
              searchField.stringValue.isEmpty else { return nil }
        let p = NSPasteboardItem()
        p.setString(node.item.name, forType: .desksetStudioLayer)
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard outlineView === partsOutline, info.draggingSource as? NSOutlineView === partsOutline else { return [] }
        if let node = item as? StudioLayerNode, node !== root {
            // On a part: between it and the next one.
            guard let i = root.children.firstIndex(of: node) else { return [] }
            outlineView.setDropItem(root, dropChildIndex: i + 1)
            return .move
        }
        guard (item as? StudioLayerNode) === root || item == nil else { return [] }
        if item == nil { outlineView.setDropItem(root, dropChildIndex: index < 0 ? root.children.count : 0) }
        else if index < 0 { outlineView.setDropItem(root, dropChildIndex: root.children.count) }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int)
        -> Bool {
        let names = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .desksetStudioLayer) }
        guard !names.isEmpty else { return false }
        return drop(names, at: index)
    }

    /// Moves `names` so they come right before the part at list index `index` (the parts' count: at the end).
    @discardableResult
    func drop(_ names: [String], at index: Int) -> Bool {
        let moving = Set(names.map { $0.lowercased() })
        let parts = root.children.map(\.item.name)
        let clamped = min(max(index, 0), parts.count)
        let before = parts[clamped...].first { !moving.contains($0.lowercased()) }
        let old = parts.map { $0.lowercased() }
        let new = LayerReorder.order(of: parts, moving: names, before: before).map { $0.lowercased() }
        guard new != old else { return false }
        onEvent?(.move(names, before: before))
        return true
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? StudioLayerNode else { return Self.rowHeight }
        if node.item.kind == .data { return node.item.subtitle == nil ? Self.rowHeight + 2 : Self.dataRowHeight }
        return node.item.subtitle == nil ? Self.rowHeight : Self.tallRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = StudioLayerRowView()
        if outlineView === dataOutline, let node = item as? StudioLayerNode {
            let name = node.item.name
            row.onHover = { [weak self] on in
                guard let self else { return }
                if on { self.setHoveredData(name) } else if self.hoveredData == name { self.setHoveredData(nil) }
            }
            row.setHovered(hoveredData == name, notify: false)
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? StudioLayerNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("StudioLayerCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? StudioLayerCell ?? StudioLayerCell()
        cell.identifier = id
        cell.item = node.item
        cell.outlined = node.item.kind == .part && outlinedParts.contains(node.item.name.lowercased())
        cell.onToggleHidden = { [weak self] name in self?.onEvent?(.toggleHidden(name)) }
        cell.onToggleLock = { [weak self] name in self?.onEvent?(.toggleLock(name)) }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let outline = notification.object as? NSOutlineView else { return }
        if outline === dataOutline {
            guard let name = selectedData else { return }
            syncing = true
            partsOutline.deselectAll(nil)
            syncing = false
            onEvent?(.selectData(name))
            return
        }
        let rows = partsOutline.selectedRowIndexes
        guard !rows.isEmpty else { return }
        syncing = true
        dataOutline.deselectAll(nil)
        syncing = false
        let names = selectedPartNames
        onEvent?(.selectPart(names.first))
    }
}

/// A row of the Layers list: selected, a rounded fill in the accent color (the words turn white); under the pointer, a
/// faint fill; a part that uses the pointed-at data, an accent outline.
final class StudioLayerRowView: NSTableRowView {
    private(set) var isHovered = false
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            for case let cell as StudioLayerCell in subviews { cell.selected = isSelected }
        }
    }

    var tintRect: NSRect { bounds.insetBy(dx: SidebarOutlineView.edge, dy: 0) }

    /// A part that uses the pointed-at data.
    var outlined = false { didSet { if outlined != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }
        if isHovered {
            StudioPageStyle.fieldFill.setFill()
            NSBezierPath(roundedRect: tintRect, xRadius: 8, yRadius: 8).fill()
        }
        if outlined {
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(roundedRect: tintRect.insetBy(dx: 0.6, dy: 0.6), xRadius: 8, yRadius: 8)
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: tintRect, xRadius: 8, yRadius: 8).fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let cell = subview as? StudioLayerCell {
            cell.selected = isSelected
            cell.hovered = isHovered
            outlined = cell.outlined
        }
    }

    func setHovered(_ hovered: Bool, notify: Bool = true) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        for case let cell as StudioLayerCell in subviews { cell.hovered = hovered }
        if notify { onHover?(hovered) }
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
        if isHovered { onHover?(false) }
        super.prepareForReuse()
        isHovered = false
        outlined = false
        onHover = nil
    }
}

/// The content of a row, drawn by hand: the kind's symbol, the name (the widget's in semibold), under it the meter's
/// or data's other name, and at the right an amber dot, the data chip with the live value, the eye and the lock (on
/// the pointer, or while hidden or locked), a data item's value, or the widget's "free layout".
final class StudioLayerCell: NSTableCellView {
    var item: StudioLayerItem? {
        didSet {
            guard item != oldValue else { return }
            refresh()
        }
    }
    var selected = false { didSet { if selected != oldValue { refresh() } } }
    var hovered = false { didSet { if hovered != oldValue { refresh() } } }
    /// It uses the pointed-at data: its row is outlined in the accent color.
    var outlined = false {
        didSet { (superview as? StudioLayerRowView)?.outlined = outlined }
    }
    var onToggleHidden: ((String) -> Void)?
    var onToggleLock: ((String) -> Void)?
    let eye = NSButton()
    let lock = NSButton()

    static let titleFont = NSFont.systemFont(ofSize: 12.5)
    static let widgetFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 10.5)
    static let chipFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    init() {
        super.init(frame: .zero)
        for b in [eye, lock] {
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.setButtonType(.momentaryChange)
            b.target = self
            addSubview(b)
        }
        eye.action = #selector(eyeClicked)
        lock.action = #selector(lockClicked)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = .normal }
    }

    @objc func eyeClicked() { if let item { onToggleHidden?(item.name) } }
    @objc func lockClicked() { if let item { onToggleLock?(item.name) } }

    private var ink: NSColor { selected ? .white : .labelColor }
    private var quiet: NSColor { selected ? NSColor.white.withAlphaComponent(0.82) : StudioPageStyle.quietInk }

    private func refresh() {
        guard let item else { return }
        let part = item.kind == .part
        eye.isHidden = !(part && (hovered || item.hidden))
        lock.isHidden = !(part && (hovered || item.locked))
        let tint = selected ? NSColor.white.withAlphaComponent(0.85) : StudioPageStyle.quietInk
        eye.image = StudioPageStyle.symbol(item.hidden ? "eye.slash" : "eye", size: 11, color: tint)
        lock.image = StudioPageStyle.symbol(item.locked ? "lock.fill" : "lock.open", size: 11, color: tint)
        eye.toolTip = item.hidden ? StudioText[.layerShow] : StudioText[.layerHide]
        eye.setAccessibilityLabel(eye.toolTip)
        lock.toolTip = item.locked ? StudioText[.layerUnlock] : StudioText[.layerLockTip]
        lock.setAccessibilityLabel(item.locked ? StudioText[.layerUnlock] : StudioText[.layerLock])
        setAccessibilityLabel(item.accessibility)
        toolTip = [item.title, item.subtitle, item.issue].compactMap { $0 }.joined(separator: "\n")
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 2
        for b in [lock, eye] where !b.isHidden {
            b.frame = NSRect(x: x - 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
            x -= 20
        }
    }

    /// Where the words at the right end (left of the eye and lock).
    private var trailingEdge: CGFloat {
        var x = bounds.width - 2
        for b in [lock, eye] where !b.isHidden { x -= 20 }
        return x
    }

    /// Where the row's words go: the name (and the line under it) from 24 points, and at the right the widget's word,
    /// a data value, the chip and the dot. The chip takes at most 45% of the row and its text ends with "…" beyond
    /// that; the name keeps at least `minimumTitle` points (a chip that would leave it less gets narrower).
    struct Layout {
        var title: NSRect
        var chip: NSRect?
        /// The chip's text does not fit its capsule (drawn ending in "…").
        var chipTruncated = false
        var dot: NSRect?
        var values: [(text: String, font: NSFont, origin: CGFloat)] = []
    }

    static let titleX: CGFloat = 24
    static let minimumTitle: CGFloat = 72

    func rowLayout() -> Layout? {
        guard let item else { return nil }
        let h = bounds.height
        var right = trailingEdge
        var layout = Layout(title: .zero)
        func take(_ text: String, font: NSFont) {
            let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
            layout.values.append((text, font, right - width))
            right -= width + 6
        }
        if let word = item.word { take(word, font: Self.subtitleFont) }
        if let value = item.value { take(value, font: Self.valueFont) }
        if let chip = item.chip {
            let icon = StudioPageStyle.symbol(chip.symbol, size: 9, weight: .semibold, color: .controlAccentColor)
            let textWidth = ceil(NSAttributedString(string: chip.text, attributes: [.font: Self.chipFont]).size().width)
            let wanted = textWidth + 10 + (icon.map { $0.size.width + 3 } ?? 0)
            let room = right - Self.titleX
            let most = max(min(room * 0.45, room - Self.minimumTitle - 6), 28)
            let width = min(wanted, most)
            layout.chip = NSRect(x: right - width, y: (h - 17) / 2, width: width, height: 17)
            layout.chipTruncated = width < wanted
            right -= width + 6
        }
        if item.issue != nil {
            layout.dot = NSRect(x: right - 7, y: (h - 7) / 2, width: 7, height: 7)
            right -= 13
        }
        layout.title = NSRect(x: Self.titleX, y: 0, width: max(right - Self.titleX, 10), height: h)
        return layout
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item, let layout = rowLayout() else { return }
        let h = bounds.height
        // The glyph.
        let glyphColor: NSColor = item.kind == .data ? (selected ? .white : .controlAccentColor)
            : (selected ? .white : NSColor.labelColor.withAlphaComponent(item.hidden ? 0.35 : 0.65))
        let glyphSize: CGFloat = item.kind == .data ? 10.5 : 12
        if let image = StudioPageStyle.symbol(item.glyph, size: glyphSize, weight: item.kind == .data ? .semibold : .medium,
                                              color: glyphColor) {
            let s = image.size
            image.draw(in: NSRect(x: (18 - s.width) / 2, y: (h - s.height) / 2, width: s.width, height: s.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        // At the right: the widget's word, a data value, the chip, the dot.
        for v in layout.values {
            let color = quiet
            let a = NSAttributedString(string: v.text, attributes: [.font: v.font, .foregroundColor: color])
            a.draw(at: NSPoint(x: v.origin, y: (h - a.size().height) / 2))
        }
        if let chip = item.chip, let capsule = layout.chip {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: chip.text, attributes: [
                .font: Self.chipFont, .foregroundColor: selected ? NSColor.white : NSColor.controlAccentColor,
                .paragraphStyle: para])
            let icon = StudioPageStyle.symbol(chip.symbol, size: 9, weight: .semibold,
                                              color: selected ? .white : .controlAccentColor)
            let ts = text.size()
            (selected ? NSColor.white.withAlphaComponent(0.2) : NSColor.controlAccentColor.withAlphaComponent(0.11)).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 8.5, yRadius: 8.5).fill()
            var cx = capsule.minX + 5
            if let icon {
                icon.draw(in: NSRect(x: cx, y: capsule.midY - icon.size.height / 2, width: icon.size.width,
                                     height: icon.size.height), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
                cx += icon.size.width + 3
            }
            let textHeight = ceil(ts.height)
            text.draw(with: NSRect(x: cx, y: capsule.midY - textHeight / 2, width: max(capsule.maxX - 5 - cx, 1),
                                   height: textHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let dot = layout.dot {
            StudioPageStyle.attention.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        // The name and the line under it.
        let x = layout.title.minX
        let width = layout.title.width
        let titleFont = item.kind == .widget ? Self.widgetFont : Self.titleFont
        let alpha: CGFloat = item.hidden && !selected ? 0.45 : 1
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: item.title, attributes: [
            .font: titleFont, .foregroundColor: ink.withAlphaComponent(alpha), .paragraphStyle: para])
        let titleHeight = ceil(title.size().height)
        if let subtitle = item.subtitle {
            let sub = NSAttributedString(string: subtitle, attributes: [
                .font: Self.subtitleFont, .foregroundColor: quiet.withAlphaComponent(alpha), .paragraphStyle: para])
            let subHeight = ceil(sub.size().height)
            let top = ((h - titleHeight - subHeight) / 2).rounded()
            title.draw(with: NSRect(x: x, y: top, width: width, height: titleHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            sub.draw(with: NSRect(x: x, y: top + titleHeight, width: width, height: subHeight),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            title.draw(with: NSRect(x: x, y: ((h - titleHeight) / 2).rounded(), width: width, height: titleHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The name is cut (it needs more room than the row leaves it): the audit's check.
    var titleIsCut: Bool {
        guard let item, let layout = rowLayout() else { return false }
        let font = item.kind == .widget ? Self.widgetFont : Self.titleFont
        return NSAttributedString(string: item.title, attributes: [.font: font]).size().width > layout.title.width + 1
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        selected = false
        hovered = false
        outlined = false
    }
}
