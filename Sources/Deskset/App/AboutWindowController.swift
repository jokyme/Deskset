import AppKit
import DesksetCore

/// Custom row view for the `Measures` table in `About > Skins` that draws a subtle yellow background when the
/// measure is paused, matching Rainmeter 4.5's visual distinction for paused measures across light and dark modes.
final class AboutMeasureRowView: NSTableRowView {
    var isPausedMeasure = false {
        didSet {
            if oldValue != isPausedMeasure {
                needsDisplay = true
            }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isPausedMeasure, !isSelected else { return }
        NSColor.systemYellow.withAlphaComponent(0.22).setFill()
        bounds.fill()
    }
}

/// `NSTableView` subclass for the `About > Log` table that responds to standard `copy:` (`⌘C` / Edit > Copy) actions
/// when the context menu is closed.
final class AboutLogTableView: NSTableView, NSMenuItemValidation {
    var onCopy: (() -> Void)?
    var canCopy: (() -> Bool)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return canCopy?() ?? !selectedRowIndexes.isEmpty
        }
        return true
    }
}

/// Rainmeter 4.5-compatible `About` dialog with four tabs (`Log`, `Skins`, `Plugins`, `Version`).
final class AboutWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Tab: String, CaseIterable, Equatable {
        case log = "Log"
        case skins = "Skins"
        case plugins = "Plugins"
        case version = "Version"

        /// Parses a `!About [TabName]` or CLI argument.
        /// Empty or `"Log"` -> `.log`, `"Skins"` or legacy `"Measures"` -> `.skins`,
        /// `"Plugins"` -> `.plugins`, `"Version"` -> `.version`, unrecognized -> `.log`.
        static func parse(_ raw: String?) -> Tab {
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch trimmed {
            case "", "log":
                return .log
            case "skins", "measures":
                return .skins
            case "plugins":
                return .plugins
            case "version":
                return .version
            default:
                return .log
            }
        }
    }

    struct PluginInfo: Equatable {
        let name: String
        let version: String
        let author: String
    }

    static let initialLogLimit = 20

    static var buildArchitecture: String {
        #if arch(arm64)
        return "64-bit (arm64)"
        #elseif arch(x86_64)
        return "64-bit (x86_64)"
        #else
        return "64-bit"
        #endif
    }

    static func versionHeadline(bundle: Bundle = .main) -> String {
        let version = AppVersion.current
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Deskset \(version) (build \(build)) - \(buildArchitecture)"
        }
        return "Deskset \(version) - \(buildArchitecture)"
    }

    private static var currentController: AboutWindowController?

    static var openWindow: NSWindow? {
        guard let window = currentController?.window, window.isVisible || window.isMiniaturized else { return nil }
        return window
    }

    static func window(for app: AppController) -> AboutWindowController? {
        guard let controller = currentController, controller.app === app else { return nil }
        return controller
    }

    @discardableResult
    static func show(app: AppController, tab: Tab = .log) -> AboutWindowController {
        let controller: AboutWindowController
        if let existing = currentController, existing.app === app {
            controller = existing
            if !existing.isSessionOpen {
                controller.resetLogPanelToRecent20()
                controller.isSessionOpen = true
            }
        } else {
            currentController?.close()
            controller = AboutWindowController(app: app)
            currentController = controller
            controller.resetLogPanelToRecent20()
            controller.isSessionOpen = true
        }
        controller.selectTab(tab)
        app.bringToFront(controller)
        controller.updatePollingTimers()
        return controller
    }

    private unowned let app: AppController
    private var isSessionOpen = false
    private(set) var selectedTab: Tab = .log

    // Top tab selector & container
    private let tabBar = NSSegmentedControl(labels: Tab.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let tabContainer = NSView()
    private var tabViews: [Tab: NSView] = [:]

    // Log tab state & views
    private(set) var displayedLogs: [Log.Line] = []
    private(set) var lastSeenLogID: UInt64 = 0
    private(set) var filterError = true
    private(set) var filterWarning = true
    private(set) var filterNotice = true
    private(set) var filterDebug = true
    private let logTable = AboutLogTableView()
    private let logMenu = NSMenu()
    private let errorCheck = NSButton(checkboxWithTitle: "Error", target: nil, action: nil)
    private let warningCheck = NSButton(checkboxWithTitle: "Warning", target: nil, action: nil)
    private let noticeCheck = NSButton(checkboxWithTitle: "Notice", target: nil, action: nil)
    private let debugCheck = NSButton(checkboxWithTitle: "Debug", target: nil, action: nil)
    private let clearLogButton = NSButton(title: "Clear", target: nil, action: nil)
    private var logTimer: Timer?

    // Skins tab state & views
    private(set) var activeSkinConfigs: [String] = []
    private(set) var selectedSkinConfig: String?
    private var selectedSkinRuntimeID: ObjectIdentifier?
    private(set) var currentSkinState: SkinDebugState?
    private var activeSkinTicket: SkinDebugRequestTicket?
    private let skinsTable = NSTableView()
    private let measuresTable = NSTableView()
    private let variablesTable = NSTableView()
    private let measuresMenu = NSMenu()
    private let variablesMenu = NSMenu()
    private var skinTimer: Timer?
    private var skinsChangedObserver: NSObjectProtocol?

    // Plugins tab state & views
    private(set) var plugins: [PluginInfo] = []
    private let pluginsTable = NSTableView()

    // Version tab state & views
    private let versionHeadlineField = NSTextField(labelWithString: "")
    private let pathValueFields: [String: NSTextField]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(app: AppController) {
        self.app = app
        var fields: [String: NSTextField] = [:]
        for key in ["ProgramPath", "IniFile", "SkinPath", "SettingsPath", "LogFile"] {
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingMiddle
            field.isSelectable = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fields[key] = field
        }
        self.pathValueFields = fields

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Deskset"
        window.minSize = NSSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        plugins = Self.loadRegisteredPlugins()
        buildUI()
        observeAppChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopTimersAndTickets()
        if let skinsChangedObserver {
            NotificationCenter.default.removeObserver(skinsChangedObserver)
        }
    }

    override func close() {
        handleSessionClose()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        handleSessionClose()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        stopTimersAndTickets()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        selectTab(selectedTab)
    }

    private func handleSessionClose() {
        isSessionOpen = false
        stopTimersAndTickets()
        if Self.currentController === self { Self.currentController = nil }
    }

    private func stopTimersAndTickets() {
        logTimer?.invalidate()
        logTimer = nil
        skinTimer?.invalidate()
        skinTimer = nil
        activeSkinTicket?.cancel()
        activeSkinTicket = nil
    }

    private func observeAppChanges() {
        skinsChangedObserver = NotificationCenter.default.addObserver(
            forName: .desksetSkinsChanged,
            object: app,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isSessionOpen else { return }
            self.reloadActiveSkinsList()
        }
    }

    // MARK: UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        tabBar.target = self
        tabBar.action = #selector(tabSegmentChanged(_:))
        tabBar.segmentStyle = .automatic
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        tabContainer.translatesAutoresizingMaskIntoConstraints = false

        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeButtonClicked))
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(closeButton)

        content.addSubview(tabBar)
        content.addSubview(tabContainer)
        content.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            tabContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 12),
            tabContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabContainer.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            bottomBar.heightAnchor.constraint(equalToConstant: 28),

            closeButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        tabViews[.log] = buildLogTab()
        tabViews[.skins] = buildSkinsTab()
        tabViews[.plugins] = buildPluginsTab()
        tabViews[.version] = buildVersionTab()

        for (_, view) in tabViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            tabContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
                view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
            ])
        }
    }

    private func buildLogTab() -> NSView {
        let container = NSView()

        configureTable(
            logTable,
            columns: [
                ("type", "Type", 72, 60, 100),
                ("time", "Time", 104, 90, 140),
                ("source", "Source", 160, 100, 280),
                ("message", "Message", 400, 180, 2000),
            ],
            allowsMultipleSelection: true
        )
        logMenu.autoenablesItems = false
        logMenu.delegate = self
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMenuValue(_:)), keyEquivalent: "c")
        copyItem.target = self
        logMenu.addItem(copyItem)
        logTable.menu = logMenu
        logTable.onCopy = { [weak self] in self?.copySelectedLogs() }
        logTable.canCopy = { [weak self] in self?.resolveLogMessagesForCopy() != nil }

        let scroll = wrapInScrollView(logTable)

        for (button, state) in [
            (errorCheck, filterError),
            (warningCheck, filterWarning),
            (noticeCheck, filterNotice),
            (debugCheck, filterDebug),
        ] {
            button.state = state ? .on : .off
            button.target = self
            button.action = #selector(logFilterToggled(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        clearLogButton.target = self
        clearLogButton.action = #selector(clearLogPanel)
        clearLogButton.translatesAutoresizingMaskIntoConstraints = false

        let controlsStack = NSStackView(views: [errorCheck, warningCheck, noticeCheck, debugCheck])
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 16
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(controlsStack)
        container.addSubview(clearLogButton)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: clearLogButton.topAnchor, constant: -10),

            controlsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controlsStack.centerYAnchor.constraint(equalTo: clearLogButton.centerYAnchor),

            clearLogButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            clearLogButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            clearLogButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])

        return container
    }

    private func buildSkinsTab() -> NSView {
        let container = NSView()

        configureTable(
            skinsTable,
            columns: [("config", "Skins", 180, 130, 320)],
            allowsEmptySelection: true
        )
        let skinsScroll = wrapInScrollView(skinsTable)

        let measuresHeader = sectionHeaderLabel("Measures")
        configureTable(
            measuresTable,
            columns: [
                ("name", "Name", 130, 80, 260),
                ("range", "Range", 96, 70, 200),
                ("number", "Number", 90, 65, 200),
                ("string", "String", 210, 120, 1200),
            ],
            allowsEmptySelection: true
        )
        measuresMenu.autoenablesItems = false
        measuresMenu.delegate = self
        for title in ["Copy Name", "Copy Range", "Copy Number", "Copy String"] {
            let item = NSMenuItem(title: title, action: #selector(copyMenuValue(_:)), keyEquivalent: "")
            item.target = self
            measuresMenu.addItem(item)
        }
        measuresTable.menu = measuresMenu
        let measuresScroll = wrapInScrollView(measuresTable)

        let variablesHeader = sectionHeaderLabel("Variables")
        configureTable(
            variablesTable,
            columns: [
                ("name", "Name", 160, 90, 300),
                ("value", "Value", 360, 140, 1200),
            ],
            allowsEmptySelection: true
        )
        variablesMenu.autoenablesItems = false
        variablesMenu.delegate = self
        let copyVarValueItem = NSMenuItem(title: "Copy Value", action: #selector(copyMenuValue(_:)), keyEquivalent: "")
        copyVarValueItem.target = self
        variablesMenu.addItem(copyVarValueItem)
        variablesTable.menu = variablesMenu
        let variablesScroll = wrapInScrollView(variablesTable)

        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(measuresHeader)
        rightPane.addSubview(measuresScroll)
        rightPane.addSubview(variablesHeader)
        rightPane.addSubview(variablesScroll)

        container.addSubview(skinsScroll)
        container.addSubview(rightPane)

        NSLayoutConstraint.activate([
            skinsScroll.topAnchor.constraint(equalTo: container.topAnchor),
            skinsScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            skinsScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            skinsScroll.widthAnchor.constraint(equalToConstant: 200),

            rightPane.topAnchor.constraint(equalTo: container.topAnchor),
            rightPane.leadingAnchor.constraint(equalTo: skinsScroll.trailingAnchor, constant: 12),
            rightPane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            measuresHeader.topAnchor.constraint(equalTo: rightPane.topAnchor),
            measuresHeader.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            measuresHeader.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),

            measuresScroll.topAnchor.constraint(equalTo: measuresHeader.bottomAnchor, constant: 4),
            measuresScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            measuresScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            measuresScroll.heightAnchor.constraint(equalTo: rightPane.heightAnchor, multiplier: 0.5, constant: -20),

            variablesHeader.topAnchor.constraint(equalTo: measuresScroll.bottomAnchor, constant: 8),
            variablesHeader.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            variablesHeader.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),

            variablesScroll.topAnchor.constraint(equalTo: variablesHeader.bottomAnchor, constant: 4),
            variablesScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            variablesScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            variablesScroll.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        return container
    }

    private func buildPluginsTab() -> NSView {
        let container = NSView()

        configureTable(
            pluginsTable,
            columns: [
                ("name", "Name", 240, 140, 380),
                ("version", "Version", 140, 90, 220),
                ("author", "Author", 320, 140, 500),
            ],
            allowsEmptySelection: true
        )
        let scroll = wrapInScrollView(pluginsTable)

        let note = NSTextField(
            wrappingLabelWithString: "All listed plugins are built into Deskset and updated with the app. Versions match Deskset; external plugins are not currently supported."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(note)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),

            note.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func buildVersionTab() -> NSView {
        let container = NSView()

        let iconView = NSImageView(image: AppIcon.image(size: 64))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])

        let titleField = NSTextField(labelWithString: "Deskset")
        titleField.font = .systemFont(ofSize: 20, weight: .bold)

        versionHeadlineField.font = .systemFont(ofSize: 13, weight: .medium)
        versionHeadlineField.isSelectable = true

        let copyButton = NSButton(title: "Copy to Clipboard", target: self, action: #selector(copyVersionDetailsToClipboard))
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let headerTextStack = NSStackView(views: [titleField, versionHeadlineField])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 4

        let headerRow = NSStackView(views: [iconView, headerTextStack])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 14
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let pathsGrid = NSGridView(numberOfColumns: 2, rows: 0)
        pathsGrid.rowSpacing = 6
        pathsGrid.columnSpacing = 12
        pathsGrid.translatesAutoresizingMaskIntoConstraints = false

        let pathLabels: [(String, String)] = [
            ("ProgramPath", "Path:"),
            ("IniFile", "IniFile:"),
            ("SkinPath", "SkinPath:"),
            ("SettingsPath", "SettingsPath:"),
            ("LogFile", "LogFile:"),
        ]
        for (key, title) in pathLabels {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.alignment = .right
            let valueField = pathValueFields[key] ?? NSTextField(labelWithString: "")
            pathsGrid.addRow(with: [label, valueField])
        }
        pathsGrid.column(at: 0).xPlacement = .trailing
        pathsGrid.column(at: 0).width = 90
        pathsGrid.column(at: 1).xPlacement = .fill

        let creditsBox = NSBox()
        creditsBox.boxType = .custom
        creditsBox.borderWidth = 1
        creditsBox.cornerRadius = 6
        creditsBox.borderColor = .separatorColor
        creditsBox.fillColor = .controlBackgroundColor
        creditsBox.contentViewMargins = NSSize(width: 12, height: 10)
        creditsBox.translatesAutoresizingMaskIntoConstraints = false

        let creditsText = NSTextField(wrappingLabelWithString:
            "Desktop widgets for your Mac, compatible with Rainmeter skins.\n"
            + "Rainmeter is a trademark of its respective owners; Deskset is not affiliated with it.\n"
            + WeatherWiring.credits)
        creditsText.font = .systemFont(ofSize: 11)
        creditsText.textColor = .secondaryLabelColor
        creditsText.isSelectable = true
        creditsBox.contentView = creditsText

        container.addSubview(headerRow)
        container.addSubview(copyButton)
        container.addSubview(pathsGrid)
        container.addSubview(creditsBox)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            headerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),

            copyButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            pathsGrid.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 18),
            pathsGrid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pathsGrid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            creditsBox.topAnchor.constraint(greaterThanOrEqualTo: pathsGrid.bottomAnchor, constant: 18),
            creditsBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            creditsBox.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            creditsBox.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        refreshVersionDetails()
        return container
    }

    private func configureTable(
        _ table: NSTableView,
        columns: [(id: String, title: String, width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat)],
        allowsMultipleSelection: Bool = false,
        allowsEmptySelection: Bool = true
    ) {
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.allowsMultipleSelection = allowsMultipleSelection
        table.allowsEmptySelection = allowsEmptySelection
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for col in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            column.minWidth = col.minWidth
            column.maxWidth = col.maxWidth
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
    }

    private func wrapInScrollView(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func sectionHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: Tab Switching & Lifecycle

    func selectTab(_ tab: Tab) {
        selectedTab = tab
        if let index = Tab.allCases.firstIndex(of: tab) {
            tabBar.selectedSegment = index
        }
        for (candidate, view) in tabViews {
            view.isHidden = (candidate != tab)
        }
        if tab != .skins {
            activeSkinTicket?.cancel()
            activeSkinTicket = nil
        }
        switch tab {
        case .log:
            pollLogNow()
        case .skins:
            reloadActiveSkinsList()
        case .plugins:
            pluginsTable.reloadData()
        case .version:
            refreshVersionDetails()
        }
        updatePollingTimers()
    }

    @objc private func tabSegmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard Tab.allCases.indices.contains(index) else { return }
        selectTab(Tab.allCases[index])
    }

    @objc private func closeButtonClicked() {
        close()
    }

    private func updatePollingTimers() {
        logTimer?.invalidate()
        logTimer = nil
        skinTimer?.invalidate()
        skinTimer = nil

        guard isSessionOpen, window?.isMiniaturized != true else { return }
        switch selectedTab {
        case .log:
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.pollLogNow()
            }
            RunLoop.main.add(timer, forMode: .common)
            logTimer = timer
        case .skins:
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.refreshSelectedSkinDebugState()
            }
            RunLoop.main.add(timer, forMode: .common)
            skinTimer = timer
        case .plugins, .version:
            break
        }
    }

    // MARK: Log Tab Logic

    func resetLogPanelToRecent20() {
        let recent = Log.recent
        let tail = recent.suffix(Self.initialLogLimit)
        lastSeenLogID = recent.last?.id ?? lastSeenLogID
        displayedLogs = Array(tail.reversed())
        logTable.reloadData()
    }

    func pollLogNow() {
        let recent = Log.recent
        let newLines = recent.filter { $0.id > lastSeenLogID }
        guard !newLines.isEmpty else { return }
        if let maxID = newLines.last?.id {
            lastSeenLogID = maxID
        }
        let accepted = newLines.filter { isLogLevelEnabled($0.level) }
        guard !accepted.isEmpty else { return }

        let selectedIDs = Set(logTable.selectedRowIndexes.compactMap { row -> UInt64? in
            displayedLogs.indices.contains(row) ? displayedLogs[row].id : nil
        })

        // Prepend newest entries at top (descending chronological order) and bound to Log.recentLimit.
        displayedLogs.insert(contentsOf: accepted.reversed(), at: 0)
        if displayedLogs.count > Log.recentLimit {
            displayedLogs.removeLast(displayedLogs.count - Log.recentLimit)
        }
        logTable.reloadData()

        if !selectedIDs.isEmpty {
            var restored = IndexSet()
            for (index, line) in displayedLogs.enumerated() where selectedIDs.contains(line.id) {
                restored.insert(index)
            }
            if !restored.isEmpty {
                logTable.selectRowIndexes(restored, byExtendingSelection: false)
            } else {
                logTable.deselectAll(nil)
            }
        }
    }

    private func isLogLevelEnabled(_ level: SkinLogLevel) -> Bool {
        switch level {
        case .error: return filterError
        case .warning: return filterWarning
        case .notice: return filterNotice
        case .debug: return filterDebug
        }
    }

    @objc private func logFilterToggled(_ sender: NSButton) {
        // Drain pending log lines under the previous filter before updating filter state.
        pollLogNow()
        filterError = (errorCheck.state == .on)
        filterWarning = (warningCheck.state == .on)
        filterNotice = (noticeCheck.state == .on)
        filterDebug = (debugCheck.state == .on)
    }

    func setLogFilter(error: Bool? = nil, warning: Bool? = nil, notice: Bool? = nil, debug: Bool? = nil) {
        pollLogNow()
        if let error {
            filterError = error
            errorCheck.state = error ? .on : .off
        }
        if let warning {
            filterWarning = warning
            warningCheck.state = warning ? .on : .off
        }
        if let notice {
            filterNotice = notice
            noticeCheck.state = notice ? .on : .off
        }
        if let debug {
            filterDebug = debug
            debugCheck.state = debug ? .on : .off
        }
    }

    @objc func clearLogPanel() {
        let maxRecentID = Log.recent.last?.id ?? 0
        lastSeenLogID = max(lastSeenLogID, maxRecentID)
        displayedLogs.removeAll()
        logTable.reloadData()
    }

    private func resolveLogMessagesForCopy(contextMenu: Bool = false) -> String? {
        var rows = logTable.selectedRowIndexes
        let clicked = logTable.clickedRow
        if contextMenu && clicked >= 0 && !rows.contains(clicked) {
            rows = IndexSet(integer: clicked)
        }
        let messages = rows.compactMap { row -> String? in
            guard displayedLogs.indices.contains(row) else { return nil }
            return displayedLogs[row].message
        }
        guard !messages.isEmpty else { return nil }
        return messages.joined(separator: "\n")
    }

    @objc func copySelectedLogs() {
        guard let messages = resolveLogMessagesForCopy() else { return }
        writeToPasteboard(messages)
    }

    @objc private func copyMenuValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        writeToPasteboard(value)
    }

    static func formatLogType(_ level: SkinLogLevel) -> String {
        switch level {
        case .error: return "Error"
        case .warning: return "Warning"
        case .notice: return "Notice"
        case .debug: return "Debug"
        }
    }

    static func formatLogTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // MARK: Skins Tab Logic

    func reloadActiveSkinsList() {
        let configs = app.sortedControllers
            .filter { !$0.isStopped }
            .map(\.config)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let previousSelection = selectedSkinConfig
        let previousRuntimeID = selectedSkinRuntimeID
        activeSkinConfigs = configs
        skinsTable.reloadData()

        if let prev = previousSelection,
           let idx = configs.firstIndex(where: { $0.caseInsensitiveCompare(prev) == .orderedSame }) {
            let canonical = configs[idx]
            let newRuntimeID = app.controller(for: canonical).map { ObjectIdentifier($0.runtime) }
            selectedSkinConfig = canonical
            selectedSkinRuntimeID = newRuntimeID
            if skinsTable.selectedRow != idx {
                skinsTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
            if previousRuntimeID != newRuntimeID {
                activeSkinTicket?.cancel()
                activeSkinTicket = nil
                currentSkinState = nil
                measuresTable.reloadData()
                variablesTable.reloadData()
            }
            refreshSelectedSkinDebugState()
        } else if let first = configs.first {
            selectedSkinConfig = first
            selectedSkinRuntimeID = app.controller(for: first).map { ObjectIdentifier($0.runtime) }
            skinsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            activeSkinTicket?.cancel()
            activeSkinTicket = nil
            currentSkinState = nil
            measuresTable.reloadData()
            variablesTable.reloadData()
            refreshSelectedSkinDebugState()
        } else {
            selectedSkinConfig = nil
            selectedSkinRuntimeID = nil
            activeSkinTicket?.cancel()
            activeSkinTicket = nil
            currentSkinState = nil
            measuresTable.reloadData()
            variablesTable.reloadData()
        }
    }

    func selectSkin(config: String?) {
        guard let config,
              let idx = activeSkinConfigs.firstIndex(where: { $0.caseInsensitiveCompare(config) == .orderedSame }) else {
            selectedSkinConfig = nil
            selectedSkinRuntimeID = nil
            activeSkinTicket?.cancel()
            activeSkinTicket = nil
            currentSkinState = nil
            skinsTable.deselectAll(nil)
            measuresTable.reloadData()
            variablesTable.reloadData()
            return
        }
        let canonical = activeSkinConfigs[idx]
        let newRuntimeID = app.controller(for: canonical).map { ObjectIdentifier($0.runtime) }
        let changed = (selectedSkinConfig?.caseInsensitiveCompare(canonical) != .orderedSame) || (selectedSkinRuntimeID != newRuntimeID)
        selectedSkinConfig = canonical
        selectedSkinRuntimeID = newRuntimeID
        if skinsTable.selectedRow != idx {
            skinsTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        if changed {
            activeSkinTicket?.cancel()
            activeSkinTicket = nil
            currentSkinState = nil
            measuresTable.reloadData()
            variablesTable.reloadData()
        }
        refreshSelectedSkinDebugState()
    }

    func refreshSelectedSkinDebugState() {
        guard isSessionOpen, selectedTab == .skins,
              let selectedConfig = selectedSkinConfig,
              let controller = app.controller(for: selectedConfig),
              !controller.isStopped else {
            activeSkinTicket?.cancel()
            activeSkinTicket = nil
            return
        }
        let runtime = controller.runtime
        let runtimeID = ObjectIdentifier(runtime)
        if selectedSkinRuntimeID != runtimeID {
            selectedSkinRuntimeID = runtimeID
            activeSkinTicket?.cancel()
            activeSkinTicket = nil
            currentSkinState = nil
            measuresTable.reloadData()
            variablesTable.reloadData()
        }
        activeSkinTicket = runtime.requestDebugState { [weak self, weak runtime] state in
            guard let self, self.isSessionOpen, self.selectedTab == .skins,
                  let selected = self.selectedSkinConfig,
                  selected.caseInsensitiveCompare(state.config) == .orderedSame,
                  let currentController = self.app.controller(for: selected),
                  currentController.runtime === runtime else {
                return
            }
            self.applySkinDebugState(state)
        }
    }

    private func applySkinDebugState(_ state: SkinDebugState) {
        guard currentSkinState != state else { return }
        let selectedMeasureName = selectedMeasureItem()?.name
        let selectedVariableName = selectedVariableItem()?.name
        currentSkinState = state
        measuresTable.reloadData()
        variablesTable.reloadData()

        if let selectedMeasureName,
           let idx = state.measures.firstIndex(where: { $0.name.caseInsensitiveCompare(selectedMeasureName) == .orderedSame }) {
            measuresTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        if let selectedVariableName,
           let idx = state.variables.firstIndex(where: { $0.name.caseInsensitiveCompare(selectedVariableName) == .orderedSame }) {
            variablesTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    private func targetMeasureItem() -> MeasureDebugItem? {
        guard let measures = currentSkinState?.measures else { return nil }
        let row = measuresTable.clickedRow >= 0 ? measuresTable.clickedRow : measuresTable.selectedRow
        guard measures.indices.contains(row) else { return nil }
        return measures[row]
    }

    private func selectedMeasureItem() -> MeasureDebugItem? {
        guard let measures = currentSkinState?.measures else { return nil }
        let row = measuresTable.selectedRow
        guard measures.indices.contains(row) else { return nil }
        return measures[row]
    }

    private func targetVariableItem() -> VariableDebugItem? {
        guard let variables = currentSkinState?.variables else { return nil }
        let row = variablesTable.clickedRow >= 0 ? variablesTable.clickedRow : variablesTable.selectedRow
        guard variables.indices.contains(row) else { return nil }
        return variables[row]
    }

    private func selectedVariableItem() -> VariableDebugItem? {
        guard let variables = currentSkinState?.variables else { return nil }
        let row = variablesTable.selectedRow
        guard variables.indices.contains(row) else { return nil }
        return variables[row]
    }

    // MARK: Plugins Tab Logic

    /// Lists registered built-in compatibility implementations with Deskset's bundled version and author.
    static func loadRegisteredPlugins() -> [PluginInfo] {
        CorePlugins.register()
        let canonicalNames: [String: String] = [
            "actiontimer": "ActionTimer",
            "advancedcpu": "AdvancedCPU",
            "appvolume": "AppVolume",
            "audio": "Audio",
            "audiolevel": "AudioLevel",
            "bluetooth": "Bluetooth",
            "brightness": "Brightness",
            "chameleon": "Chameleon",
            "colorpicker": "ColorPicker",
            "coretemp": "CoreTemp",
            "cursorcolor": "CursorColor",
            "drag&drop": "Drag&Drop",
            "dragdrop": "Drag&Drop",
            "fileview": "FileView",
            "folderinfo": "FolderInfo",
            "frostedglass": "FrostedGlass",
            "getactivetitle": "GetActiveTitle",
            "hotkey": "HotKey",
            "inputtext": "InputText",
            "isfullscreen": "IsFullScreen",
            "itunes": "iTunes",
            "itunesplugin": "iTunes",
            "macsensors": "MacSensors",
            "macsun": "MacSun",
            "macweather": "MacWeather",
            "media": "Media",
            "mediakey": "MediaKey",
            "mouse": "Mouse",
            "msiafterburner": "MSIAfterburner",
            "nowplaying": "NowPlaying",
            "perfmon": "PerfMon",
            "perfmonplugin": "PerfMon",
            "ping": "PingPlugin",
            "pingplugin": "PingPlugin",
            "power": "PowerPlugin",
            "powerplugin": "PowerPlugin",
            "process": "Process",
            "quote": "QuotePlugin",
            "quoteplugin": "QuotePlugin",
            "recyclemanager": "RecycleManager",
            "registry": "Registry",
            "resmon": "ResMon",
            "runcommand": "RunCommand",
            "slider": "Slider",
            "speedfan": "SpeedFanPlugin",
            "speedfanplugin": "SpeedFanPlugin",
            "syscolor": "SysColor",
            "sysinfo": "SysInfo",
            "usagemonitor": "UsageMonitor",
            "virtualdesktops": "VirtualDesktops",
            "webnowplaying": "WebNowPlaying",
            "webparser": "WebParser",
            "wifistatus": "WiFiStatus",
            "win7audio": "Win7Audio",
            "win7audioplugin": "Win7Audio",
            "windowmessage": "WindowMessagePlugin",
            "windowmessageplugin": "WindowMessagePlugin",
        ]
        var uniqueNames = Set<String>()
        for key in MeasureRegistry.registeredPlugins.keys {
            let display = canonicalNames[key.lowercased()] ?? key
            uniqueNames.insert(display)
        }
        return uniqueNames
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { PluginInfo(name: $0, version: "\(AppVersion.current) (bundled)", author: "jokyme") }
    }

    // MARK: Version Tab Logic

    func versionReportText() -> String {
        let details = currentVersionDetails()
        return [
            details.headline,
            "Path: \(details.programPath)",
            "IniFile: \(details.iniFile)",
            "SkinPath: \(details.skinPath)",
            "SettingsPath: \(details.settingsPath)",
            "LogFile: \(details.logFile)",
        ].joined(separator: "\n")
    }

    func currentVersionDetails() -> (
        headline: String,
        programPath: String,
        iniFile: String,
        skinPath: String,
        settingsPath: String,
        logFile: String
    ) {
        let headline = Self.versionHeadline()
        let programURL = Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
        let programPath = Self.trailingSlashPath(programURL)
        let settingsDirURL = app.settingsDirectory
        let settingsPath = Self.trailingSlashPath(settingsDirURL)
        let iniFile = app.state.fileURL.path
        let skinPath = Self.trailingSlashPath(app.skinsDirectory)
        let logFile = Log.fileURL.path
        return (headline, programPath, iniFile, skinPath, settingsPath, logFile)
    }

    private static func trailingSlashPath(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func refreshVersionDetails() {
        let details = currentVersionDetails()
        versionHeadlineField.stringValue = details.headline
        pathValueFields["ProgramPath"]?.stringValue = details.programPath
        pathValueFields["IniFile"]?.stringValue = details.iniFile
        pathValueFields["SkinPath"]?.stringValue = details.skinPath
        pathValueFields["SettingsPath"]?.stringValue = details.settingsPath
        pathValueFields["LogFile"]?.stringValue = details.logFile
    }

    @objc func copyVersionDetailsToClipboard() {
        writeToPasteboard(versionReportText())
    }

    private func writeToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    // MARK: Menu Validation

    func menuNeedsUpdate(_ menu: NSMenu) {
        let values: [String?]
        if menu === logMenu {
            values = [resolveLogMessagesForCopy(contextMenu: true)]
        } else if menu === measuresMenu {
            let target = targetMeasureItem()
            values = [target?.name, target?.range, target?.number, target?.string]
        } else if menu === variablesMenu {
            values = [targetVariableItem()?.value]
        } else {
            return
        }
        // AppKit may close the menu before dispatching its action. Each item owns its snapshot until the next
        // opening, independent of live table updates and keyboard Copy's current selection.
        for (item, value) in zip(menu.items, values) {
            item.representedObject = value
            item.isEnabled = value != nil
        }
    }

    // MARK: NSTableViewDataSource & NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === logTable {
            return displayedLogs.count
        } else if tableView === skinsTable {
            return activeSkinConfigs.count
        } else if tableView === measuresTable {
            return currentSkinState?.measures.count ?? 0
        } else if tableView === variablesTable {
            return currentSkinState?.variables.count ?? 0
        } else if tableView === pluginsTable {
            return plugins.count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if tableView === measuresTable {
            let identifier = NSUserInterfaceItemIdentifier("AboutMeasureRowView")
            let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? AboutMeasureRowView)
                ?? AboutMeasureRowView()
            rowView.identifier = identifier
            if let measures = currentSkinState?.measures, measures.indices.contains(row) {
                rowView.isPausedMeasure = measures[row].isPaused
            } else {
                rowView.isPausedMeasure = false
            }
            return rowView
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        if tableView === measuresTable,
           let measureRow = rowView as? AboutMeasureRowView,
           let measures = currentSkinState?.measures,
           measures.indices.contains(row) {
            measureRow.isPausedMeasure = measures[row].isPaused
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("AboutCell.\(colID)")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = cellID
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
        }

        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.toolTip = nil

        if tableView === logTable {
            guard displayedLogs.indices.contains(row) else { return nil }
            let line = displayedLogs[row]
            switch colID {
            case "type":
                label.stringValue = Self.formatLogType(line.level)
                switch line.level {
                case .error: label.textColor = .systemRed
                case .warning: label.textColor = .systemOrange
                case .notice: label.textColor = .labelColor
                case .debug: label.textColor = .secondaryLabelColor
                }
            case "time":
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.stringValue = Self.formatLogTime(line.date)
                label.textColor = .secondaryLabelColor
            case "source":
                let src = line.source ?? ""
                label.stringValue = src.isEmpty ? "\u{2014}" : src
            case "message":
                label.stringValue = line.message
                label.toolTip = line.message
            default:
                break
            }
        } else if tableView === skinsTable {
            guard activeSkinConfigs.indices.contains(row) else { return nil }
            label.stringValue = activeSkinConfigs[row]
        } else if tableView === measuresTable {
            guard let measures = currentSkinState?.measures, measures.indices.contains(row) else { return nil }
            let item = measures[row]
            switch colID {
            case "name":
                label.stringValue = item.name
            case "range":
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.stringValue = item.range
            case "number":
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.stringValue = item.displayNumber
            case "string":
                label.stringValue = item.displayString
                label.toolTip = item.displayString
            default:
                break
            }
            if item.isDisabled {
                label.textColor = .tertiaryLabelColor
            }
        } else if tableView === variablesTable {
            guard let variables = currentSkinState?.variables, variables.indices.contains(row) else { return nil }
            let item = variables[row]
            switch colID {
            case "name":
                label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                label.stringValue = item.name
            case "value":
                label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                label.stringValue = item.displayValue
                label.toolTip = item.displayValue
            default:
                break
            }
        } else if tableView === pluginsTable {
            guard plugins.indices.contains(row) else { return nil }
            let plugin = plugins[row]
            switch colID {
            case "name":
                label.stringValue = plugin.name
            case "version":
                label.stringValue = plugin.version
                label.textColor = .secondaryLabelColor
            case "author":
                label.stringValue = plugin.author
                label.textColor = .secondaryLabelColor
            default:
                break
            }
        }

        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === skinsTable {
            let row = skinsTable.selectedRow
            selectSkin(config: activeSkinConfigs.indices.contains(row) ? activeSkinConfigs[row] : nil)
        }
    }

    // MARK: Snapshot & Test Helpers

    var testMeasuresTable: NSTableView { measuresTable }
    var testVariablesTable: NSTableView { variablesTable }
    var testSkinsTable: NSTableView { skinsTable }
    var testLogTable: NSTableView { logTable }
    var testPluginsTable: NSTableView { pluginsTable }
    var testMeasuresMenu: NSMenu { measuresMenu }
    var testVariablesMenu: NSMenu { variablesMenu }
    var testLogMenu: NSMenu { logMenu }

    func snapshot() -> NSBitmapImageRep? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // As in Manage, the window frame supplies the background in normal display, outside the content view.
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
}
