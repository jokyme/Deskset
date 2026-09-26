import AppKit
import DesksetCore

/// The left side of the skin editor (docs/editor-friendly.md §5): `[ Add | Layers | Live Data ]`.
///
/// - **Add**: the component library (`ComponentLibraryView`).
/// - **Layers**: a first row for the whole widget (it selects the widget itself), then what is drawn, front to back,
///   each row named after its content (`LayerNaming`) with a picture of it (`LayerThumbnails`). Repeated layers fold
///   into one row ("16 bars", `LayerSeries`) that opens to its members; the Background drawn first is locked in the
///   editor. Hovering a row outlines the layer on the canvas and the other way round; a search finds rows by name,
///   text, kind or section; dragging rows changes the drawing order, keeping every layer where it is
///   (`LayerReorder`).
/// - **Live Data**: where numbers and words come from, children under their `Parent=`, repeated data folded, values
///   formatted, "Used by" links to the layers, data nothing uses dimmed, and a banner when the widget is still
///   because nothing plays (or Deskset may not hear it).
///
/// Rows show their words whole at the sidebar's width (`LayerCell`, `SidebarOutlineView`); a reload under the pointer
/// keeps the hover where the pointer is and nothing else (`clearListHover`, `restoreListHover`).
///
/// Section names stay the identity (selection, code, pasteboards): `Item.title`; what rows show is `Item.display`.
extension InspectorWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let layerDragType = NSPasteboard.PasteboardType("com.deskset.editor.layer")

    /// The sidebar's own state (search, open groups, hover, thumbnails, its header views).
    var sidebar: SidebarState {
        if let state = objc_getAssociatedObject(self, &sidebarStateKey) as? SidebarState { return state }
        let state = SidebarState()
        objc_setAssociatedObject(self, &sidebarStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    func buildSidebar() -> NSView {
        let state = sidebar
        // Text only: three labels with icons would not fit the sidebar's minimum width.
        tabControl.segmentCount = 3
        for (i, title) in ["Add", "Layers", "Live Data"].enumerated() { tabControl.setLabel(title, forSegment: i) }
        tabControl.setToolTip("Things to add to your widget (⇧⌘L)", forSegment: SidebarTab.library.rawValue)
        tabControl.setToolTip("Everything drawn in your widget, front to back", forSegment: SidebarTab.layers.rawValue)
        tabControl.setToolTip("Where the numbers and words in your widget come from", forSegment: SidebarTab.data.rawValue)
        tabControl.segmentStyle = .automatic
        tabControl.segmentDistribution = .fillEqually
        tabControl.selectedSegment = sidebarTab.rawValue
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        tabControl.setAccessibilityLabel("Sidebar")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        // The rows draw their own selection (`LayerRowView`): the list's emphasized one is a dark bar off-screen.
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = 12
        // Opening a group must not widen the list past the sidebar (the rows' tint and words would be cut off).
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.floatsGroupRows = false
        outline.autosaveExpandedItems = false
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([Self.layerDragType])
        outline.draggingDestinationFeedbackStyle = .gap
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel("Layers")
        state.menuDelegate.editor = self
        let rowMenu = NSMenu()
        rowMenu.delegate = state.menuDelegate
        outline.menu = rowMenu
        // Names that wrap make their rows taller: a new width can change the heights.
        outline.onWidthChange = { [weak self] in self?.sidebarWidthChanged() }
        // The canvas tells which layer the pointer is over, for its row (docs/editor-friendly.md §5.2).
        canvas.onHoverChange = { [weak self] name in self?.layerHoverChanged(name) }
        // View ▸ Show Rainmeter Details adds section names to the rows and Windows-only kinds to the menus.
        state.shownDetails = showsRainmeterDetails
        state.preferencesObserver = NotificationCenter.default.addObserver(
            forName: .desksetEditorPreferencesChanged, object: app.state, queue: nil) { [weak self] _ in
            self?.sidebarPreferencesChanged()
        }
        // Overlay scrollers whatever the Mac has: a legacy one would take room the rows need to read whole.
        let scroll = OverlayScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(scroll)

        buildSidebarHeader()
        let header = state.header
        listPane.addSubview(header)
        let empty = state.emptyState
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true
        listPane.addSubview(empty)
        let listTop = scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4)
        self.listTop = listTop
        state.emptyTop = empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: listPane.topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -12),
            listTop,
            scroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            state.emptyTop!,
            empty.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -20),
        ])
        listPane.translatesAutoresizingMaskIntoConstraints = false

        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.addSubview(tabControl)
        side.addSubview(listPane)
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: side.safeAreaLayoutGuide.topAnchor, constant: 10),
            tabControl.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 12),
            tabControl.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -12),
            listPane.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            listPane.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            listPane.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            listPane.bottomAnchor.constraint(equalTo: side.bottomAnchor),
        ])
        listPane.isHidden = sidebarTab == .library
        // Only the first tab's part of the header shows (it is laid out with the window).
        updateSidebarHeader()
        return side
    }

    /// Puts the Add tab's library, just made, in the sidebar under the tabs, in front of the list (see
    /// `libraryView`): shown while Add is the tab.
    func installLibrary(_ library: ComponentLibraryView) {
        library.translatesAutoresizingMaskIntoConstraints = false
        library.isHidden = sidebarTab != .library
        sidebarPane.addSubview(library)
        NSLayoutConstraint.activate([
            library.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 2),
            library.leadingAnchor.constraint(equalTo: sidebarPane.leadingAnchor),
            library.trailingAnchor.constraint(equalTo: sidebarPane.trailingAnchor),
            library.bottomAnchor.constraint(equalTo: sidebarPane.bottomAnchor),
        ])
    }

    /// Above the lists: "Find a layer" on Layers; "+ Add Live Data", "Find live data", the explanation line and the
    /// status banner on Live Data.
    private func buildSidebarHeader() {
        let state = sidebar
        for (field, placeholder, label) in [(state.layerSearch, "Find a layer", "Find a layer"),
                                            (state.dataSearch, "Find live data", "Find live data")] {
            field.placeholderString = placeholder
            field.controlSize = .regular
            field.sendsSearchStringImmediately = true
            field.sendsWholeSearchString = false
            field.target = self
            field.action = #selector(sidebarSearchChanged(_:))
            field.setAccessibilityLabel(label)
            field.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        }
        let add = addDataSourceButton
        add.bezelStyle = .texturedRounded
        add.controlSize = .small
        add.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        add.identifier = NSUserInterfaceItemIdentifier("add-data-source")
        add.toolTip = "Add live data: a value your widget can show (CPU, memory, time, battery…)"
        add.setAccessibilityLabel("Add Live Data")
        add.setContentHuggingPriority(.required, for: .horizontal)
        add.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Built again each time it opens (it follows View ▸ Show Rainmeter Details); until the Live Data tab first
        // shows, only its title item is there (`updateSidebarHeader`).
        add.menu = liveDataMenu(title: "Add Live Data", titleOnly: true)
        state.liveDataMenuDelegate.editor = self
        add.menu?.delegate = state.liveDataMenuDelegate
        // The button on its own line: next to it the search field would be too narrow to read at the sidebar's
        // usual width.
        state.dataRow.setViews([add, EditorStyle.spacer()], in: .leading)
        state.dataRow.orientation = .horizontal
        state.dataRow.spacing = 6
        state.dataRow.alignment = .centerY
        state.explanation.stringValue = "Where the numbers and words in your widget come from."
        state.explanation.font = .systemFont(ofSize: 11)
        state.explanation.textColor = .secondaryLabelColor
        state.searchCaption.stringValue = "Clear the search to change the order."
        state.searchCaption.font = .systemFont(ofSize: 11)
        state.searchCaption.textColor = .secondaryLabelColor
        state.bannerView.onAction = { [weak self] in self?.bannerActionClicked() }
        let header = state.header
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.detachesHiddenViews = true
        header.translatesAutoresizingMaskIntoConstraints = false
        for v in [state.layerSearch, state.dataRow, state.dataSearch, state.explanation, state.searchCaption,
                  state.bannerView] as [NSView] {
            header.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }
        state.emptyState.onButton = { [weak self] in self?.emptyStateButtonClicked() }
    }

    /// What the snapshot draws of the sidebar: the tab control and the tab's content (the header, the list, the empty
    /// state; or the library).
    func sidebarSnapshotViews() -> [NSView] {
        guard sidebarTab != .library else { return [tabControl, libraryView] }
        return [tabControl, sidebar.header, outline, sidebar.emptyState]
    }

    // MARK: Contents

    func rebuildSidebar() {
        guard let skin else { return }
        // Pictures of another widget, or of a skin loaded before, are not kept (a new skin object could reuse the old
        // one's identity); the pictures of hidden layers are kept for the widget.
        if sidebar.thumbnailSkin !== skin {
            sidebar.thumbnails.removeAll()
            sidebar.thumbnailSkin = skin
        }
        if sidebar.thumbnailConfig != config.lowercased() {
            sidebar.thumbnails.forgetShown()
            sidebar.thumbnailConfig = config.lowercased()
        }
        let catalog = LayerNaming.catalog(of: skin)
        sidebar.catalog = catalog
        allItems = skin.inspectedSections().map { name, kind in
            let item = Item(title: name, detail: kind == .meter ? (skin.meter(named: name)?.type ?? "")
                                                                : kind == .measure ? (skin.measure(named: name)?.type ?? "") : "",
                            kind: kind)
            present(item, in: skin)
            return item
        }
        reloadList()
    }

    /// Whether View ▸ Show Rainmeter Details is on (section names join the rows).
    var showsRainmeterDetails: Bool { app.state.editor.showIniNames }

    /// How a row presents its section: title, second line, symbol, and whether it is locked or cut off.
    func present(_ item: Item, in skin: Skin) {
        let catalog = sidebar.catalog ?? LayerNaming.catalog(of: skin)
        switch item.kind {
        case .meter?:
            guard let name = catalog.layer(item.title) else { return }
            item.display = name.title
            item.subtitle = showsRainmeterDetails ? "\(name.subtitle) · \(item.title)" : name.subtitle
            item.symbol = name.symbol
            item.isLocked = isLayerLocked(item.title)
            item.isCutOff = isLayerCutOff(item.title)
        case .measure?:
            guard let m = skin.measure(named: item.title), let name = catalog.data(item.title) else { return }
            item.display = name.name
            item.subtitle = dataLine(for: [item.title], in: skin, catalog: catalog).text
            item.symbol = EditorStyle.describe(m).symbol
        default:
            break
        }
    }

    /// The name a section goes by in the editor (its row's title), for canvas tags, breadcrumbs, toasts and undo names.
    func displayName(ofSection name: String) -> String {
        allItems.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }?.display ?? EditorStyle.displayName(name)
    }

    /// Whether a layer is locked in the editor (docs/editor-friendly.md §9.6): editor state by widget, never written
    /// to the file. The Background drawn first is locked until the user unlocks it.
    func isLayerLocked(_ name: String) -> Bool {
        let key = config.lowercased()
        if app.state.editor.editorLocks[key]?.contains(name.lowercased()) ?? false { return true }
        guard let background = sidebar.catalog?.background ?? skin.flatMap(LayerNaming.background(in:)) else { return false }
        return background.caseInsensitiveCompare(name) == .orderedSame && !app.state.editor.unlockedBackgrounds.contains(key)
    }

    /// The first row of the layers: the widget itself (its colors, update speed, desktop settings).
    func skinRow() -> Item? {
        guard let c = controller else { return nil }
        let name = Self.skinName(c)
        let n = EditorStyle.number
        let item = Item(title: name.isEmpty ? c.config : name, detail: "\(n(c.skin.width)) × \(n(c.skin.height))",
                        kind: .rainmeter, isSkin: true)
        item.display = item.title
        item.subtitle = "Whole widget · \(item.detail)"
        item.symbol = "rectangle.on.rectangle"
        return item
    }

    /// The rows of the tab: the widget row, then the layers front to back with FRONT / BACK captions (runs folded);
    /// or the live data, children under their parents; or, while searching, the matching rows alone.
    func reloadList() {
        sidebar.rowLimit = sidebar.pendingRowLimit
        sidebar.pendingRowLimit = nil
        switch sidebarTab {
        case .layers: listItems = layerRows()
        case .data: listItems = dataRows()
        case .library: listItems = []
        }
        tabControl.selectedSegment = sidebarTab.rawValue
        if sidebarTab == .library { libraryView.isHidden = false } else { loadedLibraryView?.isHidden = true }
        listPane.isHidden = sidebarTab == .library
        updateSidebarHeader()
        outline.setAccessibilityLabel(sidebarTab == .layers ? "Layers" : "Live data")
        // The rows are made again: what their hover showed goes, and the row under the pointer gets it back.
        clearListHover()
        outline.reloadData()
        restoreExpansion()
        syncOutlineSelection()
        updateEmptyState()
        restoreListHover()
    }

    /// Rows of the Layers tab.
    func layerRows() -> [Item] {
        let meters = allItems.filter { $0.kind == .meter }
        let query = sidebar.layerQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return meters.reversed().filter { matches($0, query) } }
        var units: [Item] = []
        var i = 0
        while i < meters.count {
            if let series = sidebar.catalog?.series(containing: meters[i].title), series.kind == .layers,
               series.members.first?.caseInsensitiveCompare(meters[i].title) == .orderedSame,
               !isShownSeparately(series), i + series.members.count <= meters.count {
                let members = Array(meters[i..<(i + series.members.count)])
                units.append(groupItem(series, members: members))
                i += series.members.count
            } else {
                units.append(meters[i])
                i += 1
            }
        }
        let layers = Array(units.reversed())
        var rows = skinRow().map { [$0] } ?? []
        guard layers.count >= 2 else { return rows + layers }
        rows.append(captionItem("FRONT"))
        rows += layers.dropLast()
        rows.append(captionItem("BACK"))
        rows.append(layers[layers.count - 1])
        return rows
    }

    /// The row of a run of layers: "16 bars" over its members (first to last in file order).
    func groupItem(_ series: Series, members: [Item]) -> Item {
        let item = Item(title: series.members[0], kind: .meter)
        let name = sidebar.catalog?.name(of: series)
        item.display = name?.title ?? "\(members.count) layers"
        item.subtitle = name?.subtitle ?? ""
        if showsRainmeterDetails, let first = series.members.first, let last = series.members.last {
            item.subtitle += " · \(first)…\(last)"
        }
        item.symbol = name?.symbol
        item.seriesMembers = series.members
        item.children = members
        item.isLocked = !members.isEmpty && members.allSatisfy(\.isLocked)
        item.isCutOff = members.contains { $0.isCutOff }
        return item
    }

    /// A FRONT / BACK caption (not selectable).
    func captionItem(_ text: String) -> Item {
        let item = Item(title: text, kind: nil)
        item.display = text
        return item
    }

    /// Rows that are sections or runs (not the widget row, not captions).
    var layerItems: [Item] { listItems.filter { !$0.isSkin && !$0.isGroup } }

    /// Whether a row matches every word of a search: in its name, second line, section name or kind.
    func matches(_ item: Item, _ query: String) -> Bool {
        var words = [item.display, item.subtitle, item.title]
        if let m = skin?.meter(named: item.title) {
            words.append(LayerNaming.kindNoun(m))
            if let text = m as? StringMeter { words.append(text.text) }
        }
        if let m = skin?.measure(named: item.title), let name = sidebar.catalog?.data(item.title) {
            words += [name.short, EditorStyle.describe(m).title]
        }
        let haystack = words.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return query.split(separator: " ").allSatisfy {
            haystack.contains(String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
    }

    /// Whether the user chose "Show as Separate Rows" for a run.
    func isShownSeparately(_ series: Series) -> Bool {
        sidebar.separate[config.lowercased()]?.contains(series.members.first?.lowercased() ?? "") ?? false
    }

    /// Folds a run into one row again, or shows its members as separate rows (remembered per widget).
    func setShownSeparately(_ series: Series, _ separately: Bool) {
        let key = series.members.first?.lowercased() ?? ""
        if separately { sidebar.separate[config.lowercased(), default: []].insert(key) } else {
            sidebar.separate[config.lowercased()]?.remove(key)
        }
        reloadList()
    }

    /// The expansion key of a row with children ("l:" runs of layers, "d:" data parents and runs).
    func expansionKey(_ item: Item) -> String {
        (item.kind == .meter ? "l:" : "d:") + item.title.lowercased() + (item.seriesMembers == nil ? "" : "*")
    }

    /// Opens the rows the user left open: runs of layers and data are closed at first, data parents open.
    func restoreExpansion() {
        let key = config.lowercased()
        let opened = sidebar.expanded[key] ?? [], closed = sidebar.collapsed[key] ?? []
        sidebar.restoringExpansion = true
        defer { sidebar.restoringExpansion = false }
        func visit(_ items: [Item]) {
            for item in items where !item.children.isEmpty {
                let k = expansionKey(item)
                let open = item.seriesMembers == nil ? !closed.contains(k) : opened.contains(k)
                if open {
                    outline.expandItem(item)
                    visit(item.children)
                }
            }
        }
        visit(listItems)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !sidebar.restoringExpansion, let item = notification.userInfo?["NSObject"] as? Item else { return }
        let k = expansionKey(item), key = config.lowercased()
        sidebar.expanded[key, default: []].insert(k)
        sidebar.collapsed[key]?.remove(k)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !sidebar.restoringExpansion, let item = notification.userInfo?["NSObject"] as? Item else { return }
        let k = expansionKey(item), key = config.lowercased()
        sidebar.expanded[key]?.remove(k)
        sidebar.collapsed[key, default: []].insert(k)
    }

    @objc func tabChanged() {
        selectSidebarTab(SidebarTab(rawValue: tabControl.selectedSegment) ?? .layers)
    }

    /// Shows a sidebar tab (the tab control, "+ Add", and the selection moving between layers and data).
    func selectSidebarTab(_ tab: SidebarTab) {
        let wasLibrary = sidebarTab == .library
        sidebarTab = tab
        reloadList()
        if tab == .library, !wasLibrary { libraryView.needsLayout = true }
    }

    /// Shows the header parts of the tab.
    func updateSidebarHeader() {
        let state = sidebar
        let layers = sidebarTab == .layers, data = sidebarTab == .data
        state.layerSearch.isHidden = !layers
        state.dataRow.isHidden = !data
        state.dataSearch.isHidden = !data
        state.explanation.isHidden = !data
        state.searchCaption.isHidden = !(layers && !state.layerQuery.trimmingCharacters(in: .whitespaces).isEmpty)
        addDataSourceButton.isHidden = !data
        addDataSourceButton.isEnabled = skin != nil
        if data, let menu = addDataSourceButton.menu, menu.items.count <= 1 { state.liveDataMenuDelegate.menuNeedsUpdate(menu) }
        if state.layerSearch.stringValue != state.layerQuery { state.layerSearch.stringValue = state.layerQuery }
        if state.dataSearch.stringValue != state.dataQuery { state.dataSearch.stringValue = state.dataQuery }
        updateBanner(immediate: true)
    }

    /// "Nothing here yet" for a widget without layers or data, and "Nothing matches" for a search without results.
    func updateEmptyState() {
        let empty = sidebar.emptyState
        guard skin != nil, sidebarTab != .library else { empty.isHidden = true; return }
        let query = (sidebarTab == .layers ? sidebar.layerQuery : sidebar.dataQuery).trimmingCharacters(in: .whitespaces)
        let hasRows = sidebarTab == .layers ? !layerItems.isEmpty : !listItems.isEmpty
        // Below the rows the list still has (the Layers tab keeps the widget's own row), never over them.
        let rows = outline.numberOfRows
        sidebar.emptyTop?.constant = rows > 0 ? outline.rect(ofRow: rows - 1).maxY + 18 : 28
        if hasRows {
            empty.isHidden = true
        } else if !query.isEmpty {
            empty.show(text: "Nothing matches “\(query)”.", note: nil, button: nil)
        } else if sidebarTab == .layers {
            empty.show(text: "Nothing here yet. Drag something from Add onto your widget.", note: nil, button: "Open Add")
        } else {
            let menu = liveDataMenu(title: "Add Live Data")
            menu.delegate = sidebar.liveDataMenuDelegate
            empty.show(text: "Live data brings numbers into your widget — CPU, memory, network speed, battery, time and more.",
                       note: "Most things in Add already come with their live data.", button: "Add Live Data", menu: menu)
        }
    }

    func emptyStateButtonClicked() {
        if sidebarTab == .layers { selectSidebarTab(.library) }
    }

    @objc func sidebarSearchChanged(_ sender: NSSearchField) {
        if sender === sidebar.layerSearch { sidebar.layerQuery = sender.stringValue } else { sidebar.dataQuery = sender.stringValue }
        reloadList()
    }

    /// Filters the list as typing in its search field would (self-tests).
    func setSidebarSearch(_ query: String) {
        if sidebarTab == .data { sidebar.dataQuery = query } else { sidebar.layerQuery = query }
        reloadList()
    }

    // "CPU usage" → "CPU Usage" (undo names and menu commands are in title case): `titleCase(_:)` in
    // EditorPropertyWriting.swift.

    // MARK: Selection

    /// Selects a section by name (from the canvas, a link in the inspector or programmatically). The sidebar moves
    /// between Layers and Live Data to show it; Add stays open (people add several components in a row) unless the
    /// code's caret made the selection.
    func select(section name: String) {
        guard let item = allItems.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        let wasMulti = isMultiSelection
        selectedMeters = []
        let changed = selectedSection != item.title || wasMulti
        // A style opened from a layer remembers the layer, to go back.
        backSection = item.kind == .other && selectedKind == .meter ? selectedSection : (item.kind == .other ? backSection : nil)
        selectedSection = item.title
        let follows = sidebarTab != .library || selectionFromCode
        if item.kind == .meter, sidebarTab != .layers, follows { sidebarTab = .layers; reloadList() }
        if item.kind == .measure, sidebarTab != .data, follows { sidebarTab = .data; reloadList() }
        syncOutlineSelection()
        if changed {
            reloadDetail()
            revealSelectionInCode()
        }
    }

    /// Several meters selected (on the canvas or in the layer list).
    var isMultiSelection: Bool { selectedMeters.count > 1 }

    /// The canvas selection changed.
    func canvasSelectionChanged(_ names: [String]) {
        commitPendingNudge()
        if names.count > 1 {
            selectedMeters = names
            selectedSection = names.last
            if sidebarTab == .data { sidebarTab = .layers; reloadList() }
            syncOutlineSelection()
            reloadDetail()
        } else if let name = names.first {
            return select(section: name)
        } else {
            selectedMeters = []
            selectedSection = nil
            backSection = nil
            syncOutlineSelection()
            reloadDetail()
        }
        revealSelectionInCode()
    }

    /// Whether the selection is the widget itself (its settings, theme or details): the pinned row shows it.
    var isSkinSelected: Bool {
        guard !isMultiSelection else { return false }
        guard selectedSection != nil else { return true }
        return [.rainmeter, .metadata, .variables].contains(selectedKind)
    }

    /// The row of a section: a top-level row, or a member of a run (opened when `reveal`).
    func sidebarItem(forSection name: String, reveal: Bool = false) -> Item? {
        func find(_ items: [Item], parents: [Item]) -> (Item, [Item])? {
            for item in items {
                if item.seriesMembers == nil, !item.isGroup, !item.isSkin,
                   item.title.caseInsensitiveCompare(name) == .orderedSame { return (item, parents) }
                if let found = find(item.children, parents: parents + [item]) { return found }
            }
            return nil
        }
        guard let (item, parents) = find(listItems, parents: []) else { return nil }
        if reveal { for p in parents where !outline.isItemExpanded(p) { outline.expandItem(p) } }
        return item
    }

    /// Mirrors the selection in the list without reacting to it. A whole run selected shows as its row; a member
    /// selected on its own opens its run.
    func syncOutlineSelection() {
        syncingOutline = true
        defer { syncingOutline = false }
        let names = isMultiSelection ? selectedMeters : (selectedSection.map { [$0] } ?? [])
        var rows = IndexSet()
        if isSkinSelected, let skinRow = listItems.first(where: { $0.isSkin }), outline.row(forItem: skinRow) >= 0 {
            rows.insert(outline.row(forItem: skinRow))
        }
        var remaining = names.map { $0.lowercased() }
        let selected = Set(remaining)
        for item in listItems where item.kind == .meter {
            guard let members = item.seriesMembers, !members.isEmpty, outline.row(forItem: item) >= 0,
                  members.allSatisfy({ selected.contains($0.lowercased()) }) else { continue }
            rows.insert(outline.row(forItem: item))
            remaining.removeAll { name in members.contains { $0.lowercased() == name } }
        }
        for name in remaining {
            guard let item = sidebarItem(forSection: name, reveal: true) else { continue }
            let row = outline.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let last = rows.last { outline.scrollRowToVisible(last) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingOutline else { return }
        let picked = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Item }
        commitPendingNudge()
        // The widget row alone selects the widget; next to layers it is ignored.
        if picked.count == 1, picked[0].isSkin {
            guard !isSkinSelected || selectedSection != nil else { return }
            return canvasSelectionChanged([])
        }
        let items = picked.filter { !$0.isSkin && !$0.isGroup }
        var meters: [String] = []
        for item in items where item.kind == .meter {
            for name in item.seriesMembers ?? [item.title] where !meters.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                meters.append(name)
            }
        }
        if meters.count > 1 {
            selectedMeters = meters
            selectedSection = meters.last
            backSection = nil
            reloadDetail()
            revealSelectionInCode()
        } else if let item = items.last {
            let name = item.kind == .meter ? (meters.first ?? item.title) : (item.seriesMembers?.first ?? item.title)
            guard name != selectedSection || isMultiSelection else { return }
            selectedMeters = []
            backSection = nil
            selectedSection = name
            reloadDetail()
            revealSelectionInCode()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? Item)?.isGroup ?? true)
    }

    // MARK: Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return min(listItems.count, sidebar.rowLimit ?? .max) }
        return item.children.count
    }

    /// Rows added per step while the window is being built (each row's controls take a couple of milliseconds to lay
    /// out).
    static let listRowBatch = 4

    /// Shows the list's first rows only, then the others `listRowBatch` at a time in steps of `steps`.
    func loadListRowsInSteps(_ steps: MainThreadSteps) {
        sidebar.pendingRowLimit = Self.listRowBatch
        steps.add("layer rows") { [weak self] in self?.loadMoreListRows(then: steps) }
    }

    /// Adds the next rows, and queues the next batch. Past the rows that fit on screen (counted at the smallest row
    /// height) the others go in at once: no row view is made for a row off screen.
    func loadMoreListRows(then steps: MainThreadSteps) {
        guard let limit = sidebar.rowLimit else { return }
        let onScreen = Int((outline.enclosingScrollView?.contentSize.height ?? 900) / 20) + 1
        let next = limit + Self.listRowBatch
        let end = next >= onScreen ? listItems.count : min(next, listItems.count)
        sidebar.rowLimit = end >= listItems.count ? nil : end
        if end > limit { outline.insertItems(at: IndexSet(integersIn: limit..<end), inParent: nil, withAnimation: []) }
        guard sidebar.rowLimit == nil else {
            return steps.add("layer rows") { [weak self] in self?.loadMoreListRows(then: steps) }
        }
        // Every row is there: as a full reload leaves them.
        restoreExpansion()
        syncOutlineSelection()
        updateEmptyState()
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return listItems[index] }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? Item else { return 40 }
        if item.isSkin { return 44 }
        if item.isGroup { return 20 }
        if item.kind == .measure, let skin {
            let layout = dataRowLayout(item, skin: skin)
            return LayerCell.rowHeight(titleLines: layout.titleLines, lines: layout.info == nil ? 1 : 2)
        }
        return 40
    }

    /// The sidebar got wider or narrower: data names may wrap differently.
    func sidebarWidthChanged() {
        guard sidebarTab == .data, outline.numberOfRows > 0, !sidebar.notingHeights else { return }
        sidebar.notingHeights = true
        defer { sidebar.notingHeights = false }
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? Item, item.kind == .measure, let skin,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell else { continue }
            cell.titleLines = dataRowLayout(item, skin: skin).titleLines
        }
    }

    /// View ▸ Show Rainmeter Details changed: the rows gain or lose their section names.
    func sidebarPreferencesChanged() {
        guard sidebar.shownDetails != showsRainmeterDetails else { return }
        sidebar.shownDetails = showsRainmeterDetails
        rebuildSidebar()
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let row = outlineView.makeView(withIdentifier: id, owner: self) as? LayerRowView ?? LayerRowView()
        row.identifier = id
        guard let item = item as? Item else { return row }
        row.isCaption = item.isGroup
        row.isLinkedHover = isHoveredOnCanvas(item)
        row.onHover = { [weak self, weak item] inside in
            guard let self, let item else { return }
            self.sidebarRowHovered(item, inside: inside)
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item, let skin else { return nil }
        if item.isSkin { return widgetCell(item, skin: skin) }
        if item.isGroup {
            let id = NSUserInterfaceItemIdentifier("caption")
            let cell = listCell(id, style: .caption)
            cell.textField?.stringValue = item.display
            cell.setAccessibilityLabel(item.display == "FRONT" ? "Front" : "Back")
            return cell
        }
        if item.kind == .measure { return dataCell(item, skin: skin) }
        return layerCell(item, skin: skin)
    }

    /// A cell for a row of the list: one the list no longer shows, one made ahead (`prepareListCells`), or a new one.
    func listCell(_ id: NSUserInterfaceItemIdentifier, style: LayerCell.Style) -> LayerCell {
        if let cell = outline.makeView(withIdentifier: id, owner: self) as? LayerCell { return cell }
        if let cell = sidebar.cellPool[id]?.popLast() { return cell }
        return LayerCell(identifier: id, style: style)
    }

    /// Makes the cells of the rows the list will show first, `perStep` per step, before the list is filled (each takes
    /// a couple of milliseconds; the list makes all the rows on screen in one pass): the widget row, the FRONT and
    /// BACK captions, and a layer cell per layer — as many as fit on screen.
    func prepareListCells(in steps: MainThreadSteps, skin: Skin, perStep: Int = 3) {
        let fitting = Int((NSScreen.main?.visibleFrame.height ?? 900) / 40) + 1
        let cells: [(String, LayerCell.Style)] = [("widget", .widget), ("caption", .caption), ("caption", .caption)]
            + Array(repeating: ("layer", .layer), count: min(skin.meters.count, fitting))
        for start in stride(from: 0, to: cells.count, by: max(perStep, 1)) {
            let batch = cells[start..<min(start + perStep, cells.count)]
            steps.add("layer cells") { [weak self] in
                guard let self else { return }
                for (name, style) in batch {
                    let id = NSUserInterfaceItemIdentifier(name)
                    self.sidebar.cellPool[id, default: []].append(LayerCell(identifier: id, style: style))
                }
            }
        }
    }

    /// The pinned row: a picture of the whole widget, its name and size.
    func widgetCell(_ item: Item, skin: Skin) -> LayerCell {
        let id = NSUserInterfaceItemIdentifier("widget")
        let cell = listCell(id, style: .widget)
        cell.textField?.stringValue = item.display
        cell.setSubtitle(item.subtitle)
        cell.thumbnail.image = sidebar.thumbnails.widgetThumbnail(of: skin, panel: panelColor(for: skin), dark: isSidebarDark)
        cell.isHovered = false
        cell.baseToolTip = "The whole widget: its colors, update speed and how it sits on your desktop"
        cell.setAccessibilityLabel("Whole widget, \(item.display)")
        return cell
    }

    /// A layer or a run of layers.
    func layerCell(_ item: Item, skin: Skin) -> LayerCell {
        let id = NSUserInterfaceItemIdentifier("layer")
        let cell = listCell(id, style: .layer)
        let names = item.seriesMembers ?? [item.title]
        let meters = names.compactMap { skin.meter(named: $0) }
        let hidden = !meters.isEmpty && meters.allSatisfy(\.hidden)
        cell.textField?.stringValue = item.display
        cell.setSubtitle(item.subtitle)
        cell.setInfo("")
        cell.detail.stringValue = ""
        cell.strip.isHidden = true
        cell.isHovered = false
        cell.warningText = LayerCell.cutOffText
        cell.hasToggles = true
        cell.isLayerHidden = hidden
        cell.isLayerLocked = item.isLocked
        cell.isCutOff = item.isCutOff
        cell.isUnused = false
        cell.contentAlpha = hidden ? 0.45 : 1
        cell.thumbnail.image = thumbnail(for: item, meters: meters, skin: skin)
        for button in [cell.eye, cell.lock] {
            button.target = self
            button.identifier = NSUserInterfaceItemIdentifier(item.title)
        }
        cell.eye.action = #selector(eyeClicked(_:))
        cell.lock.action = #selector(lockClicked(_:))
        let kind = meters.first.map(LayerNaming.kindNoun) ?? "Layer"
        if item.seriesMembers != nil {
            cell.baseToolTip = "\(names.first ?? "")…\(names.last ?? "")"
        } else if let text = meters.first as? StringMeter, text.measures.isEmpty {
            cell.baseToolTip = "\(item.title) — double-click to type"
        } else {
            cell.baseToolTip = item.title
        }
        cell.setAccessibilityLabel("\(item.display), \(item.seriesMembers == nil ? kind : "\(names.count) \(LayerNaming.kindPlural(kind))")")
        return cell
    }

    /// The widget's panel color for thumbnails.
    func panelColor(for skin: Skin) -> NSColor {
        LayerThumbnails.panelColor(of: skin, background: sidebar.catalog?.background, backdrop: canvas.backdrop,
                                   dark: isSidebarDark)
    }

    /// The picture of a layer row.
    func thumbnail(for item: Item, meters: [Meter], skin: Skin) -> NSImage? {
        let key = (item.seriesMembers == nil ? "" : "*") + item.title.lowercased()
        // The Background itself shows on the canvas backdrop (on its own color it would vanish).
        let isBackground = item.seriesMembers == nil
            && sidebar.catalog?.background?.caseInsensitiveCompare(item.title) == .orderedSame
        let panel = isBackground ? LayerThumbnails.backdropColor(canvas.backdrop, dark: isSidebarDark) : panelColor(for: skin)
        return sidebar.thumbnails.thumbnail(key: key, meters: meters, in: skin, panel: panel, dark: isSidebarDark)
    }

    /// The live parts of the rows on screen (on every live tick, whatever is selected): data values, names that
    /// follow their text, pictures of layers that changed (each at most once per tick), and the Live Data banner.
    func refreshSidebarValues() {
        // The silence clock runs whatever the tab, so Live Data opens with its banner settled.
        updateBanner(immediate: false)
        guard let skin, sidebarTab != .library else { return }
        let state = sidebar
        state.thumbnails.beginPass()
        let catalog = LayerNaming.catalog(of: skin)
        state.catalog = catalog
        for item in allItems where item.kind == .meter {
            guard let name = catalog.layer(item.title) else { continue }
            item.display = name.title
            item.subtitle = showsRainmeterDetails ? "\(name.subtitle) · \(item.title)" : name.subtitle
        }
        let visible = outline.rows(in: outline.visibleRect)
        for row in visible.lowerBound..<visible.upperBound {
            guard let item = outline.item(atRow: row) as? Item,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell else { continue }
            if item.isSkin {
                cell.thumbnail.image = state.thumbnails.widgetThumbnail(of: skin, panel: panelColor(for: skin), dark: isSidebarDark)
            } else if item.kind == .measure {
                updateDataValue(cell, item: item, skin: skin)
            } else if item.kind == .meter {
                if item.seriesMembers == nil, cell.textField?.stringValue != item.display {
                    cell.textField?.stringValue = item.display
                    cell.setSubtitle(item.subtitle)
                }
                let meters = (item.seriesMembers ?? [item.title]).compactMap { skin.meter(named: $0) }
                cell.thumbnail.image = thumbnail(for: item, meters: meters, skin: skin)
            }
        }
    }

    // MARK: Hover links (docs/editor-friendly.md §5.2)

    /// The layers a row stands for on the canvas.
    func canvasNames(of item: Item) -> [String] {
        if item.isSkin || item.isGroup { return [] }
        if item.kind == .meter { return item.seriesMembers ?? [item.title] }
        guard let skin, let catalog = sidebar.catalog else { return [] }
        return dataLine(for: item.seriesMembers ?? [item.title], in: skin, catalog: catalog).layers
    }

    /// The pointer entered or left a row: its layers are outlined on the canvas (nothing else changes).
    func sidebarRowHovered(_ item: Item, inside: Bool) {
        let row = outline.row(forItem: item)
        if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCell {
            cell.isHovered = inside
        }
        if inside {
            sidebar.hoveredRow = item
        } else {
            // Leaving a row after entering the next one: the next one's outline stays.
            guard sidebar.hoveredRow === item else { return }
            sidebar.hoveredRow = nil
        }
        setListHoverHighlight(inside ? canvasNames(of: item) : [])
    }

    /// Outlines layers on the canvas from the list (a row or a "Used by" link under the pointer); [] clears.
    func setListHoverHighlight(_ names: [String]) {
        canvas.hoverHighlight = names
        canvas.needsDisplay = true
        sidebar.listHover = !names.isEmpty
    }

    /// Before the rows are made again: no row keeps its hover, and the outline it put on the canvas goes (a row
    /// removed from the list never hears the pointer leave).
    func clearListHover() {
        outline.enumerateAvailableRowViews { view, _ in (view as? LayerRowView)?.clearHover() }
        sidebar.hoveredRow = nil
        if sidebar.listHover { setListHoverHighlight([]) }
    }

    /// After the rows were made again: the row under the pointer gets its hover back (the pointer stays on the eye
    /// it just clicked). `point` (window coordinates) stands for the pointer in self-tests.
    func restoreListHover(at point: NSPoint? = nil) {
        let location: NSPoint
        if let point {
            location = point
        } else {
            guard let window, window.isVisible, !listPane.isHiddenOrHasHiddenAncestor,
                  NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return }
            location = window.mouseLocationOutsideOfEventStream
        }
        let p = outline.convert(location, from: nil)
        guard outline.visibleRect.contains(p) else { return }
        let row = outline.row(at: p)
        guard row >= 0, let view = outline.rowView(atRow: row, makeIfNecessary: true) as? LayerRowView,
              !view.isCaption else { return }
        view.setHovered(true)
    }

    /// Whether the layer the pointer is over on the canvas is this row's (a run's row while it is closed).
    func isHoveredOnCanvas(_ item: Item) -> Bool {
        guard let name = sidebar.canvasHover, item.kind == .meter, !item.isGroup else { return false }
        if let members = item.seriesMembers {
            return !outline.isItemExpanded(item) && members.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return item.title.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The pointer moved onto another layer on the canvas (nil: off every layer): its row gets the hover tint and
    /// scrolls into view (unless the pointer is over the sidebar, where the list must not move under it).
    func layerHoverChanged(_ name: String?) {
        sidebar.canvasHover = name
        guard sidebarTab == .layers else { return }
        var hovered: Int?
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? Item,
                  let view = outline.rowView(atRow: row, makeIfNecessary: false) as? LayerRowView else { continue }
            let on = isHoveredOnCanvas(item)
            view.isLinkedHover = on
            if on { hovered = row }
        }
        guard let hovered else { return }
        if let window = window, !listPane.isHiddenOrHasHiddenAncestor {
            let p = listPane.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if listPane.bounds.contains(p) { return }
        }
        outline.scrollRowToVisible(hovered)
    }

    /// The snapshot's sidebar options: `--expand NAME` opens the run (or parent) holding NAME; the live data banner
    /// shows as it would after the widget has been still for a while.
    func applySnapshotSidebarOptions(_ options: SnapshotOptions) {
        sidebar.silence.settled = true
        if let name = options.expand {
            if let item = sidebarItem(forSection: name, reveal: true) {
                if !item.children.isEmpty { outline.expandItem(item) }
            } else if let run = listItems.first(where: { $0.seriesMembers?.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false }) {
                outline.expandItem(run)
            }
        }
        refreshSidebarValues()
        if let name = sidebar.canvasHover { layerHoverChanged(name) }
    }

    // MARK: Hide and lock

    /// The eye of a row: hides or shows its layer (a run: all of them, as one step).
    @objc func eyeClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let item = outline.item(atRow: row) as? Item, let skin else { return }
        let names = item.seriesMembers ?? [item.title]
        let hide = names.contains { skin.meter(named: $0)?.hidden == false }
        setLayersHidden(names, hidden: hide)
    }

    /// The lock of a row: locks or unlocks its layer in the editor (a run: all of them, as one step).
    @objc func lockClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let item = outline.item(atRow: row) as? Item else { return }
        let names = item.seriesMembers ?? [item.title]
        setLayersLocked(names, locked: !names.allSatisfy(isLayerLocked))
    }

    // How toasts and undo names call some layers ("“Audio”", "16 bars", "3 texts"): `layersLabel(_:title:)` in
    // EditorEditing.swift.

    /// Hides or shows layers (`Hidden` in each one's own section) as one undo step: "Hide “Audio”", "Hide 16 Bars".
    /// A Hidden that follows a setting (`Hidden=#HideSeconds#`, a formula) is never lost: hiding keeps what was written
    /// (`InspectorState.eyeSaved`) and showing puts it back; a layer its own setting hides now is only shown with
    /// "Show It Anyway" (`force`), which says it stops following the setting.
    func setLayersHidden(_ names: [String], hidden: Bool, force: Bool = false) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.setLayersHidden(names, hidden: hidden, force: force) }) { return }
        guard let skin else { return }
        let layers = names.compactMap { skin.meter(named: $0)?.name }
        guard !layers.isEmpty else { return }
        func isFlag(_ raw: String) -> Bool { Double(raw.trimmingCharacters(in: .whitespaces)) != nil }
        var writes: [KeyWrite] = []
        var shared: [String] = []
        var following: [String] = []
        var saved = inspectorState.eyeSaved
        for name in layers {
            guard let m = skin.meter(named: name), let target = skin.localTarget(section: name, key: "Hidden") else {
                shared.append(name)
                continue
            }
            let key = "\(config)|\(name)".lowercased()
            var own: String?
            if case .own? = m.fileOrigin("Hidden"), skin.isOwnFile(skin.ownTarget(section: name, key: "Hidden").file) {
                own = m.fileOption("Hidden")
            }
            func write(_ value: String?) {
                writes.append(KeyWrite(file: target.file, section: target.section, key: "Hidden", value: value,
                                       afterIncludes: value != nil && !skin.isOwnFile(skin.ownTarget(section: name, key: "Hidden").file)))
            }
            if hidden {
                // What it had, kept for Show: a setting it followed, or nothing of its own (its look or the default
                // showed it).
                if let own, !isFlag(own) { saved[key] = .some(own) } else if own == nil, !m.hidden { saved[key] = .some(nil) }
                write("1")
            } else if let before = saved.removeValue(forKey: key), own.map(isFlag) ?? true {
                if let before { write(before) } else if own != nil { write(nil) } else { write("0") }
            } else if let own, !isFlag(own), !force {
                following.append(name)
            } else {
                write("0")
            }
        }
        if !following.isEmpty, writes.isEmpty {
            let what = following.count == 1 ? displayName(ofSection: following[0]) : "\(following.count) layers"
            toast.show("\(Self.capitalizedFirst(what)) \(following.count == 1 ? "follows" : "follow") the widget's own setting for when to show, which hides "
                + "\(following.count == 1 ? "it" : "them") now.",
                       actions: [ToastAction("Show It Anyway") { [weak self] in self?.setLayersHidden(following, hidden: false, force: true) }])
            return
        }
        guard !writes.isEmpty else {
            if !shared.isEmpty { toast.show(sharedNote(shared).trimmingCharacters(in: .whitespaces), error: true) }
            return
        }
        let changed = layers.filter { n in !shared.contains(n) && !following.contains(n) }
        let label = layersLabel(changed, title: true), sentence = layersLabel(changed, title: false)
        let done = perform("\(hidden ? "Hide" : "Show") \(label)", files: writes.map(\.file), message: nil) { try Self.apply(writes) }
        guard done else { return }
        inspectorState.eyeSaved = saved
        var text = "\(hidden ? "Hid" : "Showed") \(sentence)"
        if force { text += ". It no longer follows the widget's own setting." }
        toast.show(text + sharedNote(shared), actions: [undoToastAction()])
    }

    /// Locks or unlocks layers in the editor (never in the file), as one undo step "Lock “Audio”". Unlocking the
    /// Background is remembered for the widget.
    func setLayersLocked(_ names: [String], locked: Bool) {
        let key = config.lowercased()
        let before = (locks: app.state.editor.editorLocks[key] ?? [], unlocked: app.state.editor.unlockedBackgrounds.contains(key))
        let background = sidebar.catalog?.background?.lowercased()
        app.state.updateEditor { prefs in
            var locks = prefs.editorLocks[key] ?? []
            for name in names.map({ $0.lowercased() }) {
                if name == background {
                    if locked { prefs.unlockedBackgrounds.remove(key) } else { prefs.unlockedBackgrounds.insert(key) }
                    locks.remove(name)
                } else if locked {
                    locks.insert(name)
                } else {
                    locks.remove(name)
                }
            }
            prefs.editorLocks[key] = locks.isEmpty ? nil : locks
        }
        let label = layersLabel(names, title: true)
        let name = "\(locked ? "Lock" : "Unlock") \(label)"
        registerLockUndo(locks: before.locks, unlockedBackground: before.unlocked, name: name)
        locksChanged()
        toast.show("\(locked ? "Locked" : "Unlocked") \(layersLabel(names, title: false))", actions: [undoToastAction()])
    }

    /// One undo step that puts the locks back as they were (and its redo).
    func registerLockUndo(locks: Set<String>, unlockedBackground: Bool, name: String) {
        guard let manager = window?.undoManager else { return }
        let key = config.lowercased()
        manager.registerUndo(withTarget: self) { target in
            let current = (locks: target.app.state.editor.editorLocks[key] ?? [],
                           unlocked: target.app.state.editor.unlockedBackgrounds.contains(key))
            target.app.state.updateEditor { prefs in
                prefs.editorLocks[key] = locks.isEmpty ? nil : locks
                if unlockedBackground { prefs.unlockedBackgrounds.insert(key) } else { prefs.unlockedBackgrounds.remove(key) }
            }
            target.registerLockUndo(locks: current.locks, unlockedBackground: current.unlocked, name: name)
            target.locksChanged()
        }
        manager.setActionName(name)
    }

    /// The rows and the canvas follow a change of locks.
    func locksChanged() {
        for item in allItems where item.kind == .meter { item.isLocked = isLayerLocked(item.title) }
        reloadList()
        canvas.needsDisplay = true
        // The identity strip's [Lock] / [Unlock] and the Background's note follow.
        if selectedKind == .meter || isMultiSelection { rebuildInspector() }
    }

    // MARK: Reordering (drag in the layer list, Arrange)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard sidebarTab == .layers, sidebar.layerQuery.trimmingCharacters(in: .whitespaces).isEmpty,
              let item = item as? Item, !item.isSkin, !item.isGroup, item.kind == .meter,
              // Members of a run move with it, never alone.
              !listItems.contains(where: { $0.children.contains { $0 === item } }) else { return nil }
        let p = NSPasteboardItem()
        p.setString((item.seriesMembers ?? [item.title]).joined(separator: "\n"), forType: Self.layerDragType)
        return p
    }

    /// Whether dragged layers can drop at a place in the list: only between top-level rows, never while the list is
    /// filtered by a search (the order shown then is not the drawing order).
    func layerDropOperation(hasLayers: Bool, proposedItem item: Any?, index: Int) -> NSDragOperation {
        guard sidebarTab == .layers, hasLayers, sidebar.layerQuery.trimmingCharacters(in: .whitespaces).isEmpty,
              item == nil, index >= 0 else { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let operation = layerDropOperation(hasLayers: info.draggingPasteboard.string(forType: Self.layerDragType) != nil,
                                           proposedItem: item, index: index)
        guard operation == .move else { return [] }
        // Nothing goes above the pinned widget row.
        if index == 0, listItems.first?.isSkin == true { outlineView.setDropItem(nil, dropChildIndex: 1) }
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.layerDragType) else { return false }
        return moveLayers(text.split(separator: "\n").map(String.init), toListIndex: index)
    }

    /// Moves a layer to row `index` of the layer list (the pinned widget row and the captions count; anything at or
    /// above the first layer means in front of everything). Returns false when it cannot move there.
    @discardableResult
    func moveLayer(_ name: String, toListIndex index: Int) -> Bool {
        moveLayers([name], toListIndex: index)
    }

    /// Moves layers (a run, as one block) to row `index`: right behind the nearest layer row above that place.
    @discardableResult
    func moveLayers(_ names: [String], toListIndex index: Int) -> Bool {
        guard let skin else { return false }
        let moving = Set(names.map { $0.lowercased() })
        var before: String?
        var i = min(index, listItems.count) - 1
        while i >= 0 {
            let row = listItems[i]
            i -= 1
            if row.isSkin || row.isGroup { continue }
            let rowNames = row.seriesMembers ?? [row.title]
            if rowNames.allSatisfy({ moving.contains($0.lowercased()) }) { continue }
            before = rowNames.first
            break
        }
        let old = skin.meters.map { $0.name.lowercased() }
        let new = LayerReorder.order(of: skin.meters.map(\.name), moving: names, before: before).map { $0.lowercased() }
        guard new != old else { return false }
        return moveLayers(names, before: before)
    }

    /// Moves layers right before `before` in the file (behind it on screen; nil: to the front), keeping every layer
    /// where it is (the reorder guard), as one undo step.
    @discardableResult
    func moveLayers(_ names: [String], before: String?) -> Bool {
        if deferUntilEditsAreCommitted({ [weak self] in self?.moveLayers(names, before: before) }) { return true }
        guard let skin else { return false }
        let moving = Set(names.map { $0.lowercased() })
        let ordered = skin.meters.map(\.name).filter { moving.contains($0.lowercased()) }
        guard !ordered.isEmpty else { return false }
        let file = skin.sources.location(section: ordered[0])?.file ?? skin.fileURL
        guard (ordered + (before.map { [$0] } ?? [])).allSatisfy({ (skin.sources.location(section: $0)?.file ?? skin.fileURL) == file })
        else {
            toast.show("These layers are in different files, so their order can't change here", error: true)
            return false
        }
        let fixes = LayerReorder.fixups(skin: skin, moving: ordered, to: before)
        let files = [file] + fixes.map { skin.ownTarget(section: $0.section, key: $0.key).file }
        let label = layersLabel(ordered, title: true), sentence = layersLabel(ordered, title: false)
        let place: String
        let rest = skin.meters.map(\.name).filter { !moving.contains($0.lowercased()) }
        if before == nil {
            place = "to the front"
        } else if let before, rest.first?.caseInsensitiveCompare(before) == .orderedSame {
            place = "to the back"
        } else if let before, let run = sidebar.catalog?.series(containing: before), run.kind == .layers,
                  let title = sidebar.catalog?.name(of: run)?.title {
            place = "behind the \(title)"
        } else {
            place = "behind \(before.map(displayName(ofSection:)) ?? "")"
        }
        pendingSelection = ordered
        let done = perform("Move \(label)", files: files, message: nil) {
            for e in fixes { _ = try skin.writeOwnOption(section: e.section, key: e.key, value: e.value) }
            for name in ordered { _ = try skin.moveSection(name, before: before) }
        }
        guard done else { return false }
        var text = "Moved \(sentence) \(place)."
        let fixed = fixes.map(\.section).reduce(into: [String]()) { list, name in
            if !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { list.append(name) }
        }
        if !fixed.isEmpty {
            let names = fixed.map(displayName(ofSection:))
            text += fixed.count == 1 ? " \(names[0]) now uses a fixed position, so nothing moved."
                : fixed.count == 2 ? " \(names[0]) and \(names[1]) now use fixed positions, so nothing moved."
                : " \(fixed.count) layers now use fixed positions, so nothing moved."
        }
        toast.show(text, actions: [undoToastAction()])
        return true
    }

    /// Where Arrange ▸ puts layers: the section to move them in front of in the file (nil: the end); `.none` when
    /// they are there already. Runs of other layers are stepped over whole.
    enum ArrangeStep {
        case front, forward, backward, back
    }

    func arrangeTarget(_ names: [String], _ step: ArrangeStep) -> String?? {
        guard let skin else { return .none }
        let all = skin.meters.filter { $0.container == nil }.map(\.name)
        let moving = Set(names.map { $0.lowercased() })
        let indices = all.indices.filter { moving.contains(all[$0].lowercased()) }
        guard let first = indices.first, let last = indices.last else { return .none }
        let rest = all.filter { !moving.contains($0.lowercased()) }
        /// A whole run of another layer's, stepped over as one.
        func unitRange(at i: Int) -> ClosedRange<Int> {
            guard let run = sidebar.catalog?.series(containing: all[i]), run.kind == .layers, !isShownSeparately(run),
                  let a = all.firstIndex(where: { $0.caseInsensitiveCompare(run.members.first ?? "") == .orderedSame }),
                  let b = all.firstIndex(where: { $0.caseInsensitiveCompare(run.members.last ?? "") == .orderedSame }),
                  a <= i, i <= b else { return i...i }
            return a...b
        }
        switch step {
        case .front:
            return last == all.count - 1 && indices.count == last - first + 1 ? .none : .some(nil)
        case .back:
            guard let head = rest.first, first != 0 || indices.count != last + 1 else { return .none }
            return .some(head)
        case .forward:
            guard last + 1 < all.count else { return .none }
            let unit = unitRange(at: last + 1)
            return .some(unit.upperBound + 1 < all.count ? all[unit.upperBound + 1] : nil)
        case .backward:
            guard first > 0 else { return .none }
            return .some(all[unitRange(at: first - 1).lowerBound])
        }
    }

    /// Arrange ▸ Bring to Front / Bring Forward / Send Backward / Send to Back.
    func arrange(_ names: [String], _ step: ArrangeStep) {
        guard case .some(let before) = arrangeTarget(names, step) else { return }
        moveLayers(names, before: before)
    }

    // MARK: Click actions

    /// "Do Something When Clicked…": selects the layer and shows where its click actions are set in the inspector.
    func showClickActions(for names: [String]) {
        guard let name = names.first else { return }
        if names.count == 1 { select(section: name) } else { canvasSelectionChanged(names) }
        let card = inspectorStack.findSubview { view in
            guard let label = view as? NSTextField else { return false }
            let text = label.stringValue.lowercased()
            return text.contains("when clicked") || text.contains("interaction")
        }
        if let card { card.scrollToVisible(card.bounds) }
    }
}

// MARK: - State

private var sidebarStateKey: UInt8 = 0

/// What the sidebar keeps for its window: names, open groups (per widget), searches, hover, thumbnails, the silence
/// clock of the banner, and its header views.
final class SidebarState {
    var catalog: LayerNameCatalog?
    /// Rows with children the user opened (runs are closed at first), by widget (config lowercased).
    var expanded: [String: Set<String>] = [:]
    /// Data parents the user closed (open at first), by widget.
    var collapsed: [String: Set<String>] = [:]
    /// Runs shown as separate rows (first member lowercased), by widget.
    var separate: [String: Set<String>] = [:]
    var restoringExpansion = false
    var layerQuery = ""
    var dataQuery = ""
    /// The layer under the pointer on the canvas.
    var canvasHover: String?
    /// When the Live Data banner says nothing plays.
    var silence = SilenceClock()
    /// The banner shown.
    var banner: LiveDataBanner?
    let thumbnails = LayerThumbnails()
    /// The skin and widget the pictures are of.
    weak var thumbnailSkin: Skin?
    var thumbnailConfig = ""
    var glyphs: [String: NSImage] = [:]
    /// The row under the pointer.
    weak var hoveredRow: InspectorWindowController.Item?
    /// The canvas's hover outline comes from the list (a row or a link).
    var listHover = false
    /// Row heights are being noted (a new height can change the list's width).
    var notingHeights = false
    /// View ▸ Show Rainmeter Details as the rows show it.
    var shownDetails = false
    var preferencesObserver: NSObjectProtocol?
    let liveDataMenuDelegate = LiveDataMenuDelegate()
    /// Cells made ahead of the list's first rows (`prepareListCells`), by identifier.
    var cellPool: [NSUserInterfaceItemIdentifier: [LayerCell]] = [:]
    /// While the window is being built, the list shows its first rows only (`loadMoreListRows` adds the others); nil:
    /// every row. The next `reloadList` takes `pendingRowLimit`; any other shows every row.
    var rowLimit: Int?
    var pendingRowLimit: Int?

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    let header = NSStackView()
    let layerSearch = NSSearchField()
    let dataSearch = NSSearchField()
    let dataRow = NSStackView()
    let explanation = NSTextField(wrappingLabelWithString: "")
    let searchCaption = NSTextField(labelWithString: "")
    let bannerView = SidebarBannerView()
    let emptyState = SidebarEmptyStateView()
    /// The empty state's distance below the top of the list: under the rows still listed (the widget's own row).
    var emptyTop: NSLayoutConstraint?
    let menuDelegate = SidebarMenuDelegate()
}

// MARK: - Views

/// What an empty list says, with a button to go on.
final class SidebarEmptyStateView: NSStackView {
    let label = NSTextField(wrappingLabelWithString: "")
    let note = NSTextField(wrappingLabelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)
    let menuButton = NSPopUpButton(frame: .zero, pullsDown: true)
    var onButton: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8
        detachesHiddenViews = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(clicked)
        menuButton.bezelStyle = .texturedRounded
        menuButton.controlSize = .small
        menuButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for v in [label, button, menuButton, note] as [NSView] { addArrangedSubview(v) }
        label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(text: String, note noteText: String?, button title: String?, menu: NSMenu? = nil) {
        isHidden = false
        label.stringValue = text
        note.stringValue = noteText ?? ""
        note.isHidden = noteText == nil
        button.title = title ?? ""
        button.isHidden = title == nil || menu != nil
        menuButton.isHidden = menu == nil
        if let menu { menuButton.menu = menu }
    }

    @objc private func clicked() { onButton?() }
}

/// Builds the right-click menu of the row that was clicked (`LayerMenu`).
final class SidebarMenuDelegate: NSObject, NSMenuDelegate {
    weak var editor: InspectorWindowController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let editor else { return }
        let outline = editor.outline
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? InspectorWindowController.Item,
              !item.isSkin, !item.isGroup else { return }
        let built: NSMenu
        if item.kind == .measure {
            built = LayerMenu.makeData(for: item.seriesMembers ?? [item.title], in: editor)
        } else {
            // A right-click on a row that is part of the selection acts on the whole selection (like Finder).
            let selected = outline.selectedRowIndexes.contains(row)
                ? outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? InspectorWindowController.Item }
                    .filter { $0.kind == .meter && !$0.isSkin }
                : [item]
            let names = selected.flatMap { $0.seriesMembers ?? [$0.title] }
            // A run's row can show its members separately; a member shown separately can fold them back.
            let run = editor.sidebar.catalog?.series(containing: item.title).flatMap { run in
                item.seriesMembers != nil || editor.isShownSeparately(run) ? run : nil
            }
            built = LayerMenu.make(for: names, in: editor, run: run)
        }
        for i in built.items { built.removeItem(i); menu.addItem(i) }
        menu.autoenablesItems = false
    }
}
