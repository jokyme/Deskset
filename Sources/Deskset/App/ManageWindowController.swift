import AppKit
import DesksetCore

/// The Manage window (https://docs.rainmeter.net/manual/user-interface/manage/): installed configs and their .ini
/// variants, load / unload, per-skin settings, [Metadata], compatibility notes; .rmskin files, ZIP archives and skin
/// folders can be dropped on it.
final class ManageWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate {
    private unowned let app: AppController
    private var roots: [ManageModel.Node] = []
    private var libraryNames: [String] = []
    /// Selected config and .ini (nil file: a folder that is not a config).
    private(set) var selection: (config: String, file: String?)?
    private var issueCache: [String: (modified: Date?, issues: [String])] = [:]

    private let outline = NSOutlineView()
    private let detailStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Select a skin to see its details.")

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadButton = NSButton(title: "Load", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let folderButton = NSButton(title: "Open Folder", target: nil, action: nil)

    private let metadataGrid = NSGridView()
    private let settingsGrid = NSGridView()
    private let settingsNote = NSTextField(labelWithString: "Load the skin to change its settings.")
    private let positionPopup = NSPopUpButton()
    private let transparencySlider = NSSlider(value: 0, minValue: 0, maxValue: 90, target: nil, action: nil)
    private let transparencyLabel = NSTextField(labelWithString: "0%")
    private let hoverPopup = NSPopUpButton()
    private let fadeField = NSTextField()
    private let loadOrderField = NSTextField()
    private let xField = NSTextField()
    private let yField = NSTextField()
    private let draggableBox = NSButton(checkboxWithTitle: "Draggable", target: nil, action: nil)
    private let clickThroughBox = NSButton(checkboxWithTitle: "Click through", target: nil, action: nil)
    private let keepOnScreenBox = NSButton(checkboxWithTitle: "Keep on screen", target: nil, action: nil)
    private let snapEdgesBox = NSButton(checkboxWithTitle: "Snap to edges", target: nil, action: nil)
    private let savePositionBox = NSButton(checkboxWithTitle: "Save position", target: nil, action: nil)
    private let issuesStack = NSStackView()
    /// A loaded skin that a skin action (or StartHidden) hid: says so, with a Show button.
    private let hiddenNotice = HiddenSkinNotice()
    /// Under the coordinates while the skin is hidden (typing coordinates moves it, out of sight).
    private let coordinatesHint = NSTextField(wrappingLabelWithString: "")
    private var coordinatesHintRow: NSGridRow?
    /// The config whose coordinates were typed while it was hidden (the hint says it moved but is still hidden).
    private var movedWhileHidden: String?
    /// Loaded configs that were hidden when the details were last drawn (lowercased), and the timer that looks for
    /// changes while the window is on screen: skins hide and show themselves without telling the app's windows.
    private var hiddenConfigs: [String] = []
    private var hiddenWatch: Timer?
    private let launchAtLoginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private var skinSections: [NSView] = []
    /// Width of the label column shared by the metadata and settings grids, so their labels line up.
    private static let labelColumnWidth: CGFloat = 104
    /// The window had no saved frame and was centered: `placeBeside` may still move it.
    private var placedByDefault = false

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Manage Skins"
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildInterface()
        window.setFrameAutosaveName("DesksetManageWindow")
        if !window.setFrameUsingName("DesksetManageWindow") {
            window.center()
            placedByDefault = true
        }
        keepMinimumSize()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(skinsChanged), name: .desksetSkinsChanged,
                                               object: app)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hiddenWatch?.invalidate()
    }

    /// First launch: moves the window, while it has no saved frame, beside the skins in `frames` (the first-run widget
    /// column, top left), so it does not cover them: to their right when it fits there at least at its minimum width,
    /// else to their left; otherwise it stays centered.
    func placeBeside(_ frames: [NSRect]) {
        guard placedByDefault, let window, let first = frames.first else { return }
        let column = frames.dropFirst().reduce(first) { $0.union($1) }
        let screen = NSScreen.screens.first { $0.frame.intersects(column) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame,
              let frame = ManageWindowController.frame(beside: column, size: window.frame.size,
                                                       minSize: window.minSize, visible: visible)
        else { return }
        window.setFrame(frame, display: false)
    }

    /// A window frame of `size` (narrowed, and shortened to fit, but never below `minSize`) beside `column` within
    /// `visible`, 20 points from the column and from the visible frame's edges, its top 20 points below the visible
    /// frame's top: to the column's right, else to its left; nil when neither side has room.
    static func frame(beside column: NSRect, size: NSSize, minSize: NSSize, visible: NSRect) -> NSRect? {
        let margin: CGFloat = 20, minWidth = minSize.width
        let height = max(min(size.height, visible.height - 2 * margin), minSize.height)
        let y = visible.maxY - margin - height
        let rightRoom = visible.maxX - margin - (column.maxX + margin)
        if rightRoom >= minWidth {
            return NSRect(x: column.maxX + margin, y: y, width: min(size.width, rightRoom), height: height)
        }
        let leftRoom = column.minX - margin - (visible.minX + margin)
        if leftRoom >= minWidth {
            let width = min(size.width, leftRoom)
            return NSRect(x: column.minX - margin - width, y: y, width: width, height: height)
        }
        return nil
    }

    /// The window never gets smaller than `minSize`, which AppKit only enforces while the user drags its edges: a
    /// saved frame from an older version, or anything else that resizes it, would squeeze the detail column until its
    /// controls are cut off. An unexpected shrink is logged with the call stack, to find its cause.
    private func keepMinimumSize() {
        guard let window, !window.inLiveResize else { return }
        let frame = window.frame
        let width = max(frame.width, window.minSize.width), height = max(frame.height, window.minSize.height)
        guard width != frame.width || height != frame.height else { return }
        Log.write("Manage window shrank to \(Int(frame.width)) × \(Int(frame.height)); restored to its minimum size. "
                  + Thread.callStackSymbols.prefix(12).joined(separator: " | "), level: .warning)
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        keepMinimumSize()
    }

    /// Watches for skins hiding and showing themselves only while some of the window can be seen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        watchHiddenSkins(window?.occlusionState.contains(.visible) == true)
    }

    func windowWillClose(_ notification: Notification) {
        watchHiddenSkins(false)
    }

    private func watchHiddenSkins(_ on: Bool) {
        if !on {
            hiddenWatch?.invalidate()
            hiddenWatch = nil
            return
        }
        guard hiddenWatch == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshHiddenState() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        hiddenWatch = timer
        refreshHiddenState()
    }

    /// Redraws what depends on whether loaded skins are hidden, when that changed (a skin ran `!Hide` / `!Show`).
    /// The text fields are left alone, so nothing typed into them is lost.
    func refreshHiddenState() {
        guard currentHiddenConfigs() != hiddenConfigs else { return }
        updateHiddenState()
    }

    private func currentHiddenConfigs() -> [String] {
        app.controllers.values.filter { !$0.isStopped && $0.isHiddenByBang }.map { $0.config.lowercased() }.sorted()
    }

    // MARK: Building

    private func buildInterface() {
        guard let window else { return }
        let content = DropView { [weak self] urls in self?.app.installer.open(urls) }
        window.contentView = content

        // Left: skins outline.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(outlineDoubleClicked)
        outline.autosaveExpandedItems = false
        let outlineMenu = NSMenu()
        outlineMenu.delegate = self
        outline.menu = outlineMenu
        outline.setAccessibilityLabel("Installed skins")
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false

        // Right: details.
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = document
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 14
        detailStack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detailStack)
        NSLayoutConstraint.activate([
            // Its place as well as its width: nothing else says where it is (ambiguous).
            document.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detailStack.topAnchor.constraint(equalTo: document.topAnchor),
            detailStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            detailStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        buildDetail()

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        let left = NSVisualEffectView()
        left.material = .sidebar
        left.blendingMode = .behindWindow
        left.addSubview(outlineScroll)
        NSLayoutConstraint.activate([
            outlineScroll.topAnchor.constraint(equalTo: left.topAnchor),
            outlineScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
        ])
        split.addArrangedSubview(left)
        split.addArrangedSubview(detailScroll)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        left.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        let preferred = left.widthAnchor.constraint(equalToConstant: 260)
        preferred.priority = .defaultLow
        preferred.isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.autosaveName = "DesksetManageSplit"

        // Bottom bar.
        let install = NSButton(title: "Install Skin…", target: app, action: #selector(AppController.installSkinAction))
        let openFolder = NSButton(title: "Open Skins Folder", target: app,
                                  action: #selector(AppController.openSkinsFolderAction))
        let refreshAll = NSButton(title: "Refresh All", target: app, action: #selector(AppController.refreshAllAction))
        launchAtLoginBox.target = self
        launchAtLoginBox.action = #selector(launchAtLoginChanged)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [install, openFolder, refreshAll, spacer, launchAtLoginBox])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 16)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(split)
        content.addSubview(separator)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: split.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        return label
    }

    private func numberField(_ field: NSTextField, width: CGFloat, action: Selector) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = -1_000_000
        formatter.maximum = 1_000_000
        field.formatter = formatter
        field.alignment = .right
        field.target = self
        field.action = action
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func buildDetail() {
        emptyLabel.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(emptyLabel)

        // Header
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isSelectable = true
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let header = NSStackView(views: [iconView, titles, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        for (button, action) in [(loadButton, #selector(loadClicked)), (refreshButton, #selector(refreshClicked)),
                                 (editButton, #selector(editClicked)), (folderButton, #selector(folderClicked))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        loadButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [loadButton, refreshButton, editButton, folderButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        // Metadata
        metadataGrid.rowSpacing = 6
        metadataGrid.columnSpacing = 12

        // Settings
        for (title, value) in ManageModel.positions {
            positionPopup.addItem(withTitle: title)
            positionPopup.lastItem?.tag = value
        }
        positionPopup.target = self
        positionPopup.action = #selector(settingsChanged(_:))
        for mode in SkinVisibility.HoverMode.allCases {
            hoverPopup.addItem(withTitle: mode.title)
            hoverPopup.lastItem?.tag = mode.rawValue
        }
        hoverPopup.target = self
        hoverPopup.action = #selector(settingsChanged(_:))
        transparencySlider.numberOfTickMarks = 10
        transparencySlider.allowsTickMarkValuesOnly = false
        transparencySlider.isContinuous = true
        transparencySlider.target = self
        transparencySlider.action = #selector(settingsChanged(_:))
        transparencySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        transparencyLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        transparencyLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        numberField(fadeField, width: 60, action: #selector(settingsChanged(_:)))
        numberField(loadOrderField, width: 60, action: #selector(settingsChanged(_:)))
        numberField(xField, width: 70, action: #selector(positionFieldChanged(_:)))
        numberField(yField, width: 70, action: #selector(positionFieldChanged(_:)))
        for box in [draggableBox, clickThroughBox, keepOnScreenBox, snapEdgesBox, savePositionBox] {
            box.target = self
            box.action = #selector(settingsChanged(_:))
        }
        draggableBox.toolTip = "Drag the skin with the mouse. Hold ⌘ to drag a skin that is not draggable."
        clickThroughBox.toolTip = "Clicks pass through the skin to whatever is below it."
        keepOnScreenBox.toolTip = "Keep the whole skin inside the screen it is on."
        snapEdgesBox.toolTip = "Snap to screen edges and other skins when dragged. Hold ⌘ while dragging to override."
        savePositionBox.toolTip = "Remember where the skin is when it is moved."
        hoverPopup.toolTip = "What the skin does while the pointer is over it."

        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            s.alignment = .centerY
            return s
        }
        let ms = NSTextField(labelWithString: "ms")
        ms.textColor = .secondaryLabelColor
        settingsGrid.rowSpacing = 10
        settingsGrid.columnSpacing = 12
        settingsGrid.addRow(with: [formLabel("Position:"), row([positionPopup])])
        settingsGrid.addRow(with: [formLabel("Transparency:"), row([transparencySlider, transparencyLabel])])
        settingsGrid.addRow(with: [formLabel("On hover:"), row([hoverPopup, formLabel("Fade duration:"), fadeField, ms])])
        settingsGrid.addRow(with: [formLabel("Coordinates:"), row([formLabel("X"), xField, formLabel("Y"), yField])])
        coordinatesHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        coordinatesHint.textColor = .secondaryLabelColor
        coordinatesHint.preferredMaxLayoutWidth = 340
        let hintSymbol = NSImageView(image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
                                        ?? NSImage())
        hintSymbol.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        hintSymbol.contentTintColor = .systemOrange
        hintSymbol.setContentHuggingPriority(.required, for: .horizontal)
        let hint = row([hintSymbol, coordinatesHint])
        hint.spacing = 5
        hint.alignment = .firstBaseline
        coordinatesHintRow = settingsGrid.addRow(with: [NSGridCell.emptyContentView, hint])
        coordinatesHintRow?.topPadding = -4
        coordinatesHintRow?.isHidden = true
        settingsGrid.addRow(with: [formLabel("Load order:"), row([loadOrderField])])
        let checks = NSGridView(views: [[draggableBox, clickThroughBox], [keepOnScreenBox, snapEdgesBox],
                                        [savePositionBox, NSGridCell.emptyContentView]])
        checks.rowSpacing = 6
        checks.columnSpacing = 24
        settingsGrid.addRow(with: [NSGridCell.emptyContentView, checks])
        settingsGrid.column(at: 0).xPlacement = .trailing
        settingsGrid.column(at: 0).width = ManageWindowController.labelColumnWidth
        // The grids are as wide as the detail column (constraints below). A hugging priority above the window's
        // stay-put priority would pull the whole window narrower whenever their content gets shorter.
        settingsGrid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metadataGrid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settingsGrid.rowAlignment = .firstBaseline
        settingsNote.textColor = .secondaryLabelColor
        settingsNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        issuesStack.orientation = .vertical
        issuesStack.alignment = .leading
        issuesStack.spacing = 6

        hiddenNotice.showButton.target = self
        hiddenNotice.showButton.action = #selector(showClicked)

        skinSections = [header, buttons, hiddenNotice, separatorLine(), metadataGrid, separatorLine(),
                        sectionTitle("Settings"), settingsGrid, settingsNote, separatorLine(), sectionTitle("Compatibility"),
                        issuesStack]
        for view in skinSections {
            detailStack.addArrangedSubview(view)
            if view is NSBox || view === hiddenNotice {
                view.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -48).isActive = true
            }
        }
        issuesStack.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -48).isActive = true
        metadataGrid.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -48).isActive = true
        header.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -48).isActive = true
    }

    // MARK: Data

    @objc private func skinsChanged() {
        reload()
    }

    /// Rebuilds the outline when the library changed and refreshes the details.
    func reload() {
        let library = app.library
        let names = library.map { "\($0.name)|\($0.files.joined(separator: "|"))" }
        if names != libraryNames {
            libraryNames = names
            let expanded = Set(roots.flatMap(allNodes).filter { outline.isItemExpanded($0) }.map { $0.path.lowercased() })
            roots = ManageModel.tree(library)
            outline.reloadData()
            for node in roots.flatMap(allNodes) where node.kind == .folder {
                let isActiveRoot = app.controllers.values.contains {
                    $0.config.lowercased().hasPrefix(node.path.lowercased())
                }
                if expanded.contains(node.path.lowercased()) || (expanded.isEmpty && isActiveRoot) {
                    outline.expandItem(node)
                }
            }
            if let selection { selectNode(config: selection.config, file: selection.file) }
        } else {
            outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                               columnIndexes: IndexSet(integer: 0))
        }
        updateDetail()
    }

    private func allNodes(_ node: ManageModel.Node) -> [ManageModel.Node] {
        [node] + node.children.flatMap(allNodes)
    }

    /// Selects a config (and file) in the outline.
    func select(config: String, file: String?) {
        let name = SkinLibrary.normalizedConfigName(config)
        let running = app.controller(for: name)
        selectNode(config: name, file: file ?? running?.file ?? app.config(named: name)?.files.first)
        if selection == nil || selection?.config.caseInsensitiveCompare(name) != .orderedSame {
            selection = (name, file)
        }
        updateDetail()
    }

    private func selectNode(config: String, file: String?) {
        let nodes: [ManageModel.Node] = roots.flatMap(allNodes)
        func same(_ a: String?, _ b: String) -> Bool { a?.caseInsensitiveCompare(b) == .orderedSame }
        func folderNode(_ path: String) -> ManageModel.Node? {
            nodes.first { (n: ManageModel.Node) -> Bool in n.kind == .folder && same(n.path, path) }
        }
        var match: ManageModel.Node?
        if let file {
            match = nodes.first { (n: ManageModel.Node) -> Bool in
                n.kind == .file && same(n.path, config) && same(n.file, file)
            }
        }
        if match == nil { match = folderNode(config) }
        guard let match else { return }
        // Expand every ancestor folder (and the config folder itself for a file).
        var components = match.path.split(separator: "\\").map(String.init)
        if match.kind == .folder { components.removeLast() }
        var ancestors: [ManageModel.Node] = []
        while !components.isEmpty {
            if let p = folderNode(components.joined(separator: "\\")) { ancestors.insert(p, at: 0) }
            components.removeLast()
        }
        for p in ancestors { outline.expandItem(p) }
        let row = outline.row(forItem: match)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        if match.kind == .file {
            selection = (match.path, match.file)
        } else {
            let running = match.config.flatMap { app.controller(for: $0.name)?.file }
            selection = (match.path, running ?? match.config?.files.first)
        }
    }

    private var selectedController: SkinController? {
        guard let selection else { return nil }
        return app.controller(for: selection.config)
    }

    private func updateDetail() {
        launchAtLoginBox.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginBox.isEnabled = LaunchAtLogin.isAvailable
        launchAtLoginBox.toolTip = LaunchAtLogin.isAvailable ? "Start Deskset when you log in."
            : "Available when Deskset runs as an installed app."

        guard let target = detailTarget() else {
            emptyLabel.isHidden = false
            skinSections.forEach { $0.isHidden = true }
            updateHiddenState()
            return
        }
        let (config, file, running, loaded) = target
        emptyLabel.isHidden = true
        skinSections.forEach { $0.isHidden = false }

        // Header
        let metadata: [String: String]
        if loaded, let running {
            metadata = running.skin.metadata
        } else if let file {
            metadata = ManageModel.readMetadata(config.directory.appendingPathComponent(file))
        } else {
            metadata = [:]
        }
        let fallbackTitle = file.map { ($0 as NSString).deletingPathExtension } ?? config.name
        titleLabel.stringValue = ManageModel.metadataValue(metadata, "Name") ?? fallbackTitle
        subtitleLabel.stringValue = config.name + (file.map { "\\" + $0 } ?? "")
        iconView.image = NSImage(systemSymbolName: file == nil ? "folder" : "square.grid.2x2",
                                 accessibilityDescription: nil)
        iconView.contentTintColor = loaded ? .controlAccentColor : .secondaryLabelColor

        loadButton.title = loaded ? "Unload" : "Load"
        loadButton.isEnabled = file != nil
        refreshButton.isEnabled = loaded
        editButton.isEnabled = file != nil
        folderButton.isEnabled = true

        // Metadata
        // NSGridView.removeRow leaves the cell views behind: remove them first.
        for row in 0..<metadataGrid.numberOfRows {
            for column in 0..<metadataGrid.numberOfColumns {
                metadataGrid.cell(atColumnIndex: column, rowIndex: row).contentView?.removeFromSuperview()
            }
        }
        while metadataGrid.numberOfRows > 0 { metadataGrid.removeRow(at: 0) }
        var rows = 0
        for key in ["Author", "Version", "License", "Information"] {
            guard var value = ManageModel.metadataValue(metadata, key) else { continue }
            if key == "Information" { value = ManageModel.informationText(value) }
            let label = NSTextField(wrappingLabelWithString: value)
            label.isSelectable = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            metadataGrid.addRow(with: [formLabel(key + ":"), label])
            rows += 1
        }
        if rows == 0 {
            let none = NSTextField(labelWithString: file == nil
                                   ? "Contains \(config.files.count) skin\(config.files.count == 1 ? "" : "s")."
                                   : "This skin has no [Metadata] section.")
            none.textColor = .secondaryLabelColor
            metadataGrid.addRow(with: [none])
        }
        if metadataGrid.numberOfColumns > 1 {
            metadataGrid.column(at: 0).xPlacement = .trailing
            metadataGrid.column(at: 0).width = ManageWindowController.labelColumnWidth
            metadataGrid.rowAlignment = .firstBaseline
        }

        // Settings: per config (like Rainmeter.ini), editable while the config is loaded with any variant.
        let s = running?.state ?? app.state.skin(config.name) ?? SkinState(file: file ?? "")
        let editable = running != nil && file != nil
        positionPopup.selectItem(withTag: s.alwaysOnTop)
        let percent = ManageModel.transparencyPercent(forAlpha: s.alphaValue)
        transparencySlider.integerValue = min(percent, 90)
        transparencyLabel.stringValue = "\(percent)%"
        hoverPopup.selectItem(withTag: s.onHover)
        fadeField.integerValue = s.fadeDuration
        loadOrderField.integerValue = s.loadOrder
        if let running {
            let p = running.topLeftPosition
            xField.stringValue = String(Int(p.x.rounded()))
            yField.stringValue = String(Int(p.y.rounded()))
        } else {
            xField.stringValue = s.x.map { String(Int($0.rounded())) } ?? ""
            yField.stringValue = s.y.map { String(Int($0.rounded())) } ?? ""
        }
        draggableBox.state = s.draggable ? .on : .off
        clickThroughBox.state = s.clickThrough ? .on : .off
        keepOnScreenBox.state = s.keepOnScreen ? .on : .off
        snapEdgesBox.state = s.snapEdges ? .on : .off
        savePositionBox.state = s.savePosition ? .on : .off
        for control in [positionPopup, transparencySlider, hoverPopup, fadeField, loadOrderField, xField, yField,
                        draggableBox, clickThroughBox, keepOnScreenBox, snapEdgesBox, savePositionBox] as [NSControl] {
            control.isEnabled = editable
        }
        settingsNote.isHidden = editable
        settingsNote.stringValue = file == nil ? "Select a skin file to see its settings."
            : "Load the skin to change its settings."

        // Compatibility
        issuesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let issues: [String]
        if loaded, let running {
            issues = running.skin.issues
        } else if let file {
            issues = cachedIssues(config: config, file: file)
        } else {
            issues = []
        }
        if file == nil {
            issuesStack.addArrangedSubview(note("Select a skin file to check it."))
        } else if issues.isEmpty {
            issuesStack.addArrangedSubview(issueRow("No compatibility problems found.", symbol: "checkmark.circle",
                                                    tint: .systemGreen))
        } else {
            for issue in issues.prefix(100) {
                issuesStack.addArrangedSubview(issueRow(issue, symbol: "exclamationmark.triangle", tint: .systemOrange))
            }
            if issues.count > 100 { issuesStack.addArrangedSubview(note("… and \(issues.count - 100) more.")) }
        }
        if !loaded && file != nil {
            issuesStack.addArrangedSubview(note("Checked without loading; some problems only show up while the skin runs."))
        }
        updateHiddenState()
    }

    /// The selected config, the selected file of it (nil for a folder), the config's running skin and whether the
    /// selected file is the one running.
    private func detailTarget() -> (config: SkinConfig, file: String?, running: SkinController?, loaded: Bool)? {
        guard let selection, let config = app.config(named: selection.config) ?? folderOnly(selection.config)
        else { return nil }
        let file = selection.file.flatMap { f in config.files.first { $0.caseInsensitiveCompare(f) == .orderedSame } }
        let running = app.controller(for: config.name)
        let loaded = running.map { r in file.map { $0.caseInsensitiveCompare(r.file) == .orderedSame } ?? false } ?? false
        return (config, file, running, loaded)
    }

    /// The status, the hidden notice and the coordinates' hint: what depends on whether the skin is hidden.
    private func updateHiddenState() {
        let hiddenNow = currentHiddenConfigs()
        if hiddenNow != hiddenConfigs {
            hiddenConfigs = hiddenNow
            // The rows' icons (a crossed-out eye for a hidden skin).
            if outline.numberOfRows > 0 {
                outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                                   columnIndexes: IndexSet(integer: 0))
            }
        }
        guard let target = detailTarget() else { return }
        let (_, file, running, loaded) = target
        let hidden = running.map { !$0.isStopped && $0.isHiddenByBang } ?? false
        if file == nil {
            statusLabel.stringValue = "Folder"
            statusLabel.textColor = .secondaryLabelColor
        } else if loaded {
            statusLabel.stringValue = hidden ? ManageModel.Hidden.status : "● Loaded"
            statusLabel.textColor = hidden ? .systemOrange : .systemGreen
        } else if let running {
            statusLabel.stringValue = "\(running.file) is loaded" + (hidden ? ", hidden" : "")
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "Not loaded"
            statusLabel.textColor = .secondaryLabelColor
        }
        // The notice for the file that runs; the settings (and so the coordinates) belong to the config, whichever
        // of its files runs.
        hiddenNotice.isHidden = !(loaded && hidden)
        if loaded && hidden, let running {
            hiddenNotice.set(title: ManageModel.Hidden.title,
                             text: ManageModel.Hidden.explanation(startHidden: running.state.startHidden))
        }
        // A skin that shows again forgets that it was moved while hidden.
        let movedHere = running.map { movedWhileHidden?.caseInsensitiveCompare($0.config) == .orderedSame } ?? false
        if movedHere && !hidden { movedWhileHidden = nil }
        coordinatesHint.stringValue = ManageModel.Hidden.coordinatesHint(moved: movedHere && hidden)
        coordinatesHintRow?.isHidden = !(file != nil && hidden)
    }

    /// A folder that is not a config (e.g. a root folder that only holds sub-configs).
    private func folderOnly(_ path: String) -> SkinConfig? {
        guard roots.flatMap(allNodes).contains(where: { $0.kind == .folder && $0.path.caseInsensitiveCompare(path) == .orderedSame })
        else { return nil }
        return SkinConfig(name: path, directory: SkinLibrary.directory(for: path, root: app.skinsDirectory), files: [])
    }

    private func cachedIssues(config: SkinConfig, file: String) -> [String] {
        let url = config.directory.appendingPathComponent(file)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = url.path
        if let hit = issueCache[key], hit.modified == modified { return hit.issues }
        let issues = ManageModel.dryRunIssues(config: config.name, fileURL: url, skinsDirectory: app.skinsDirectory)
        issueCache[key] = (modified, issues)
        return issues
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    private func issueRow(_ text: String, symbol: String, tint: NSColor) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = tint
        image.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 520
        let row = NSStackView(views: [image, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    // MARK: Actions

    private func selectedFileTarget() -> (config: SkinConfig, file: String)? {
        guard let selection, let config = app.config(named: selection.config),
              let file = selection.file.flatMap({ f in config.files.first { $0.caseInsensitiveCompare(f) == .orderedSame } })
        else { return nil }
        return (config, file)
    }

    @objc private func loadClicked() {
        guard let target = selectedFileTarget() else { return }
        toggleLoad(config: target.config.name, file: target.file)
    }

    private func toggleLoad(config: String, file: String) {
        if let running = app.controller(for: config), running.file.caseInsensitiveCompare(file) == .orderedSame {
            app.deactivate(config: config, fade: true)
        } else {
            app.activate(config: config, file: file, fade: true)
        }
        selection = (config, file)
        updateDetail()
    }

    @objc private func refreshClicked() {
        if let c = selectedController { app.refresh(c) }
    }

    @objc private func editClicked() {
        guard let target = selectedFileTarget() else { return }
        CodeEditorRouter.open(file: target.config.directory.appendingPathComponent(target.file), app: app)
    }

    @objc private func folderClicked() {
        guard let selection else { return }
        Workspace.reveal(SkinLibrary.directory(for: selection.config, root: app.skinsDirectory))
    }

    @objc private func outlineDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? ManageModel.Node else { return }
        if node.kind == .file, let file = node.file {
            toggleLoad(config: node.path, file: file)
        } else if outline.isItemExpanded(node) {
            outline.collapseItem(node)
        } else {
            outline.expandItem(node)
        }
    }

    /// Applies the one setting whose control changed. (Writing every control back would also rewrite settings the
    /// controls can only approximate: an AlphaValue of 0…25 — below the slider's 90% — or one between 10% steps
    /// would change whenever an unrelated checkbox is clicked.)
    @objc private func settingsChanged(_ sender: Any?) {
        guard let c = selectedController, let control = sender as? NSControl else { return }
        ManageWindowController.apply(control: control, of: self, to: c, app: app)
    }

    private static func apply(control: NSControl, of w: ManageWindowController, to c: SkinController,
                              app: AppController) {
        if control === w.transparencySlider {
            let percent = w.transparencySlider.integerValue
            w.transparencyLabel.stringValue = "\(percent)%"
            c.clearFadedAlpha()
            app.changeSettings(of: c) { $0.alphaValue = ManageModel.alpha(forTransparencyPercent: percent) }
            return
        }
        app.changeSettings(of: c) { s in
            switch control {
            case w.positionPopup: s.alwaysOnTop = w.positionPopup.selectedTag()
            case w.hoverPopup: s.onHover = w.hoverPopup.selectedTag()
            case w.fadeField:
                if let v = Int(w.fadeField.stringValue.trimmingCharacters(in: .whitespaces)) {
                    s.fadeDuration = min(max(v, 0), SkinState.maxFadeDuration)
                }
            case w.loadOrderField:
                if let v = Int(w.loadOrderField.stringValue.trimmingCharacters(in: .whitespaces)) { s.loadOrder = v }
            case w.draggableBox: s.draggable = w.draggableBox.state == .on
            case w.clickThroughBox: s.clickThrough = w.clickThroughBox.state == .on
            case w.keepOnScreenBox: s.keepOnScreen = w.keepOnScreenBox.state == .on
            case w.snapEdgesBox: s.snapEdges = w.snapEdgesBox.state == .on
            case w.savePositionBox: s.savePosition = w.savePositionBox.state == .on
            default: break
            }
        }
    }

    @objc private func positionFieldChanged(_ sender: Any?) {
        guard let c = selectedController,
              let x = Double(xField.stringValue), let y = Double(yField.stringValue) else { return }
        c.moveTo(x: x, y: y)
        // A hidden skin moves out of sight: the hint under the coordinates says it is still hidden.
        movedWhileHidden = c.isHiddenByBang ? c.config : nil
        updateDetail()
    }

    /// Shows a loaded skin that a skin action hid, fading in over its FadeDuration as `!ShowFade` does.
    @objc private func showClicked() {
        guard let c = selectedController else { return }
        show(c)
    }

    private func show(_ c: SkinController) {
        guard !c.isStopped, c.isHiddenByBang else { return }
        c.setHidden(false, fade: true)
        movedWhileHidden = nil
        updateHiddenState()
    }

    @objc private func launchAtLoginChanged() {
        app.toggleLaunchAtLoginAction()
        updateDetail()
    }

    // MARK: NSOutlineViewDataSource / Delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ManageModel.Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let list = (item as? ManageModel.Node)?.children ?? roots
        return list[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? ManageModel.Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ManageModel.Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("SkinCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node.name
        let running = app.controller(for: node.path)
        switch node.kind {
        case .folder:
            let hasLoaded = app.controllers.values.contains {
                let c = $0.config.lowercased(), p = node.path.lowercased()
                return c == p || c.hasPrefix(p + "\\")
            }
            cell.imageView?.image = NSImage(systemSymbolName: hasLoaded ? "folder.fill" : "folder",
                                            accessibilityDescription: nil)
            cell.imageView?.contentTintColor = hasLoaded ? .controlAccentColor : .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.setAccessibilityLabel(node.name + (hasLoaded ? ", has loaded skins" : ""))
        case .file:
            let loaded = running.map { $0.file.caseInsensitiveCompare(node.file ?? "") == .orderedSame } ?? false
            // Loaded but hidden by a skin action: an orange crossed-out eye instead of the green tick.
            let hidden = loaded && running.map { !$0.isStopped && $0.isHiddenByBang } ?? false
            cell.imageView?.image = NSImage(systemSymbolName: hidden ? "eye.slash.circle.fill"
                                                : loaded ? "checkmark.circle.fill" : "doc.text",
                                            accessibilityDescription: hidden ? "Loaded, hidden" : loaded ? "Loaded" : nil)
            cell.imageView?.contentTintColor = hidden ? .systemOrange : loaded ? .systemGreen : .secondaryLabelColor
            cell.textField?.font = loaded ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                : .systemFont(ofSize: NSFont.systemFontSize)
            cell.setAccessibilityLabel(ManageModel.Hidden.accessibilityLabel(name: node.name, loaded: loaded,
                                                                            hidden: hidden))
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? ManageModel.Node else { return }
        switch node.kind {
        case .file:
            selection = (node.path, node.file)
        case .folder:
            let file = node.config.flatMap { c in app.controller(for: c.name)?.file ?? c.files.first }
            selection = (node.path, file)
        }
        updateDetail()
    }

    // MARK: Outline context menu

    /// The row a self-test "right-clicks" (`testContextMenuTitles`).
    private var testContextNode: ManageModel.Node?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard let node = testContextNode ?? (row >= 0 ? outline.item(atRow: row) as? ManageModel.Node : nil)
        else { return }
        if node.kind == .file, let file = node.file {
            let loaded = app.controller(for: node.path)?.file.caseInsensitiveCompare(file) == .orderedSame
            let toggle = NSMenuItem(title: loaded ? "Unload" : "Load", action: #selector(contextToggle(_:)),
                                    keyEquivalent: "")
            toggle.representedObject = [node.path, file]
            toggle.target = self
            menu.addItem(toggle)
            if loaded, let running = app.controller(for: node.path), !running.isStopped, running.isHiddenByBang {
                let show = NSMenuItem(title: ManageModel.Hidden.showTitle, action: #selector(contextShow(_:)),
                                      keyEquivalent: "")
                show.representedObject = [node.path]
                show.target = self
                menu.addItem(show)
            }
            let edit = NSMenuItem(title: "Edit", action: #selector(contextEdit(_:)), keyEquivalent: "")
            edit.representedObject = [node.path, file]
            edit.target = self
            menu.addItem(edit)
        }
        let folder = NSMenuItem(title: "Show in Finder", action: #selector(contextFolder(_:)), keyEquivalent: "")
        folder.representedObject = [node.path]
        folder.target = self
        menu.addItem(folder)
    }

    @objc private func contextToggle(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], a.count == 2 else { return }
        toggleLoad(config: a[0], file: a[1])
    }

    @objc private func contextShow(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], let config = a.first,
              let c = app.controller(for: config) else { return }
        show(c)
    }

    @objc private func contextEdit(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], a.count == 2 else { return }
        CodeEditorRouter.open(file: SkinLibrary.directory(for: a[0], root: app.skinsDirectory).appendingPathComponent(a[1]),
                              app: app)
    }

    @objc private func contextFolder(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], let path = a.first else { return }
        Workspace.reveal(SkinLibrary.directory(for: path, root: app.skinsDirectory))
    }

    // MARK: Snapshot support

    /// Renders the window's content off-screen (for `--snapshot-ui` and self-tests).
    func snapshot() -> NSBitmapImageRep? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // The window background is drawn by the window frame, not the content view: paint it first.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.displayIgnoringOpacity(view.bounds, in: context)
        return rep
    }

    /// Loads or unloads a skin as a double-click in the outline does (self-tests).
    func testToggleLoad(config: String, file: String) { toggleLoad(config: config, file: file) }
    var testGridHugging: NSLayoutConstraint.Priority {
        max(settingsGrid.contentHuggingPriority(for: .horizontal), metadataGrid.contentHuggingPriority(for: .horizontal))
    }

    /// Controls exposed for self-tests.
    var testLoadButtonTitle: String { loadButton.title }
    var testTitle: String { titleLabel.stringValue }
    var testSettingsEnabled: Bool { positionPopup.isEnabled }
    var testIssueCount: Int { issuesStack.arrangedSubviews.count }
    var testOutlineRows: Int { outline.numberOfRows }
    /// The scrolled page of the details (the detail pane's document view).
    var testDetailDocument: NSView? { detailStack.superview }
    var testDraggableBox: NSButton { draggableBox }
    var testFadeField: NSTextField { fadeField }
    var testTransparencySlider: NSSlider { transparencySlider }
    var testStatus: String { statusLabel.stringValue }
    /// The hidden notice's title and text when it shows, nil when it does not.
    var testHiddenNotice: (title: String, text: String)? {
        hiddenNotice.isHidden ? nil : (hiddenNotice.titleLabel.stringValue, hiddenNotice.textLabel.stringValue)
    }
    /// The hint under the coordinates when it shows.
    var testCoordinatesHint: String? { coordinatesHintRow?.isHidden == false ? coordinatesHint.stringValue : nil }
    var testHiddenNoticeView: NSView { hiddenNotice }
    var testHiddenNoticeText: NSTextField { hiddenNotice.textLabel }
    var testXField: NSTextField { xField }
    /// Whether the window looks for skins hiding and showing themselves (only while it is on screen).
    var testWatchesHiddenSkins: Bool { hiddenWatch != nil }
    var testShowButton: NSButton { hiddenNotice.showButton }
    /// Types coordinates into the X and Y fields and ends editing, as Return does.
    func testTypeCoordinates(x: Int, y: Int) {
        xField.stringValue = String(x)
        yField.stringValue = String(y)
        positionFieldChanged(yField)
    }
    /// The outline row of a config's file: its accessibility label.
    func testRowLabel(config: String, file: String) -> String? {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? ManageModel.Node, node.kind == .file,
                  node.path.caseInsensitiveCompare(config) == .orderedSame,
                  node.file?.caseInsensitiveCompare(file) == .orderedSame else { continue }
            return outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityLabel()
        }
        return nil
    }
    /// The outline's context menu for a config's file (as right-clicking its row builds it).
    func testContextMenuTitles(config: String, file: String) -> [String] {
        guard let node = roots.flatMap(allNodes).first(where: {
            $0.kind == .file && $0.path.caseInsensitiveCompare(config) == .orderedSame
                && $0.file?.caseInsensitiveCompare(file) == .orderedSame
        }) else { return [] }
        let menu = NSMenu()
        testContextNode = node
        defer { testContextNode = nil }
        menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }
    /// Chooses Show in the outline's context menu of a config's file.
    func testContextShow(config: String) {
        let item = NSMenuItem()
        item.representedObject = [config]
        contextShow(item)
    }
}

/// The notice at the top of a hidden skin's details: a crossed-out eye, what happened, and a Show button.
final class HiddenSkinNotice: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let textLabel = NSTextField(wrappingLabelWithString: "")
    let showButton = NSButton(title: ManageModel.Hidden.showTitle, target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        let symbol = NSImageView(image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        symbol.contentTintColor = .systemOrange
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        textLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textLabel.textColor = .secondaryLabelColor
        textLabel.isSelectable = true
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        showButton.bezelStyle = .rounded
        showButton.setContentHuggingPriority(.required, for: .horizontal)
        showButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Crossed-out eye | title over text | Show, centred. The text is as wide as the room between the title's left
        // edge and the button, so it wraps there whatever its own size.
        for view in [symbol, titleLabel, textLabel, showButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            symbol.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: showButton.leadingAnchor, constant: -12),
            textLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: showButton.leadingAnchor, constant: -16),
            textLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            showButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            showButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(title: String, text: String) {
        titleLabel.stringValue = title
        textLabel.stringValue = text
        setAccessibilityLabel(title)
    }

    /// The text wraps at the width it is given (one more layout pass when that width changed).
    override func layout() {
        super.layout()
        let width = textLabel.frame.width
        if width > 0, abs(textLabel.preferredMaxLayoutWidth - width) > 0.5 {
            textLabel.preferredMaxLayoutWidth = width
            needsLayout = true
        }
    }

    /// Drawn rather than a layer's colours, so off-screen snapshots show it too.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.systemOrange.withAlphaComponent(0.09).setFill()
        path.fill()
        NSColor.systemOrange.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Top-left origin container for the scrolling detail pane.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Window content that accepts dropped skin packages: .rmskin files, ZIP archives and folders (the install flow sorts
/// out folders already in the Skins folder and archives without skins).
final class DropView: NSView {
    private let onDrop: ([URL]) -> Void
    /// Accent-colored frame shown while a package is dragged over the window (kept above every other subview).
    private let overlay = NSView()

    init(onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        overlay.wantsLayer = true
        overlay.layer?.borderWidth = 3
        overlay.layer?.cornerRadius = 8
        overlay.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setHighlighted(_ on: Bool) {
        if on {
            overlay.frame = bounds.insetBy(dx: 2, dy: 2)
            overlay.autoresizingMask = [.width, .height]
            overlay.layer?.borderColor = NSColor.controlAccentColor.cgColor
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.isHidden = !on
    }

    private func packages(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(RmskinPackage.canInspect)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !packages(sender).isEmpty
        setHighlighted(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let urls = packages(sender)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { self.onDrop(urls) }
        return true
    }
}
