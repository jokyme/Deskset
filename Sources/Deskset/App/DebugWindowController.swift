import AppKit
import DesksetCore

final class DebugLogTableView: NSTableView, NSMenuItemValidation {
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

/// Diagnostics for loaded skins and the current desktop environment.
final class DebugWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Tab: String, CaseIterable, Equatable {
        case log = "Log", skins = "Skins", display = "Display", network = "Network", plugins = "Plugins"
        static func parse(_ raw: String?) -> Tab {
            switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "skin", "skins": return .skins
            case "display": return .display
            case "network": return .network
            case "plugins": return .plugins
            default: return .log
            }
        }
    }
    struct PluginInfo: Equatable { let name: String; let version: String; let author: String }
    static let initialLogLimit = 50
    private static var currentController: DebugWindowController?
    static var openWindow: NSWindow? {
        guard let w = currentController?.window, w.isVisible || w.isMiniaturized else { return nil }
        return w
    }
    static func window(for app: AppController) -> DebugWindowController? {
        guard let c = currentController, c.app === app else { return nil }; return c
    }
    @discardableResult
    static func show(app: AppController, tab: Tab = .log, config: String? = nil) -> DebugWindowController {
        let c: DebugWindowController
        if let existing = window(for: app) { c = existing }
        else {
            currentController?.close()
            c = DebugWindowController(app: app)
            currentController = c
        }
        if !c.isSessionOpen { c.resetLogPanel(); c.isSessionOpen = true }
        app.bringToFront(c)
        c.selectTab(tab, config: config)
        return c
    }
    private unowned let app: AppController
    private var isSessionOpen = false
    private(set) var selectedTab: Tab = .log
    private let tabBar = NSSegmentedControl(labels: Tab.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
    private let tabContainer = NSView()
    private var tabViews: [Tab: NSView] = [:]
    let skinInspector: DebugSkinInspectorView
    let displayInfo = DebugInfoView(kind: .display)
    let networkInfo = DebugInfoView(kind: .network)
    private(set) var displayedLogs: [Log.Line] = []
    private(set) var lastSeenLogID: UInt64 = 0
    private(set) var filterError = true, filterWarning = true, filterNotice = true, filterDebug = true
    private let logTable = DebugLogTableView()
    private let logMenu = NSMenu()
    private let typeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let fileButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var logTimer: Timer?
    private(set) var plugins: [PluginInfo] = []
    private let pluginsTable = NSTableView()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    init(app: AppController) {
        self.app = app
        skinInspector = DebugSkinInspectorView(app: app)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 570),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Debug Deskset"
        w.minSize = NSSize(width: 680, height: 420)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.center()
        if app.presentsWindows { w.setFrameAutosaveName("Deskset.Debug") }
        super.init(window: w)
        w.delegate = self
        plugins = Self.loadRegisteredPlugins()
        buildUI()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit { logTimer?.invalidate() }
    override func close() { finish(); super.close() }
    func windowWillClose(_ notification: Notification) { finish() }
    private func finish() {
        isSessionOpen = false
        stopPolling()
        skinInspector.close(); displayInfo.close(); networkInfo.close()
        if Self.currentController === self { Self.currentController = nil }
    }
    private func stopPolling() {
        logTimer?.invalidate(); logTimer = nil
        skinInspector.deactivate(); displayInfo.deactivate(); networkInfo.deactivate()
    }
    func windowDidMiniaturize(_ notification: Notification) { stopPolling() }
    func windowDidDeminiaturize(_ notification: Notification) { selectTab(selectedTab) }
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
        let helpButton = NSButton(title: "Help", target: self, action: #selector(openHelp))
        helpButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(helpButton)

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

            helpButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            helpButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        tabViews[.log] = buildLogTab()
        tabViews[.skins] = skinInspector
        tabViews[.plugins] = buildPluginsTab()
        tabViews[.display] = displayInfo
        tabViews[.network] = networkInfo

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
        configureTable(logTable, columns: [("type", "Type", 72, 60, 100), ("time", "Time", 104, 90, 140),
                                          ("source", "Source", 160, 100, 280), ("message", "Message", 400, 180, 2000)],
                       allowsMultipleSelection: true)
        logMenu.autoenablesItems = false; logMenu.delegate = self
        for title in ["Copy", "Copy all"] {
            let item = NSMenuItem(title: title, action: #selector(copyMenuValue(_:)), keyEquivalent: "")
            item.target = self; logMenu.addItem(item)
        }
        logTable.menu = logMenu
        logTable.onCopy = { [weak self] in self?.copySelectedLogs() }
        logTable.canCopy = { [weak self] in self?.resolveLogMessagesForCopy() != nil }
        typeButton.addItems(withTitles: ["Type", "Error", "Warning", "Notice", "Debug"])
        typeButton.menu?.autoenablesItems = false
        for item in typeButton.itemArray.dropFirst() {
            item.target = self; item.action = #selector(toggleType(_:)); item.state = .on
        }
        fileButton.addItems(withTitles: ["Log file", "Start logging", "Stop logging", "Show log file", "Delete log file"])
        fileButton.menu?.autoenablesItems = false; fileButton.menu?.delegate = self
        for item in fileButton.itemArray.dropFirst() { item.target = self; item.action = #selector(logFileAction(_:)) }
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLogPanel))
        let bar = NSStackView(views: [typeButton, fileButton, NSView(), clear])
        bar.orientation = .horizontal; bar.spacing = 8
        let scroll = wrapInScrollView(logTable)
        for v in [bar, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor), bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
    @objc private func toggleType(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        switch sender.title {
        case "Error": setLogFilter(error: enabled)
        case "Warning": setLogFilter(warning: enabled)
        case "Notice": setLogFilter(notice: enabled)
        case "Debug": setLogFilter(debug: enabled)
        default: break
        }
    }
    @objc private func logFileAction(_ sender: NSMenuItem) {
        switch sender.title {
        case "Start logging": app.setFileLoggingEnabled(true)
        case "Stop logging": app.setFileLoggingEnabled(false)
        case "Show log file": Log.flush(); Workspace.edit(Log.fileURL)
        case "Delete log file":
            do { try app.deleteLogFile() }
            catch { Log.write("Could not delete log file: \(error.localizedDescription)", level: .error) }
        default: break
        }
        refreshLogFileMenu()
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

    func selectTab(_ tab: Tab, config: String? = nil) {
        stopPolling()
        selectedTab = tab
        tabBar.selectedSegment = Tab.allCases.firstIndex(of: tab) ?? 0
        for (candidate, view) in tabViews { view.isHidden = candidate != tab }
        if tab == .skins, let config { skinInspector.selectSkin(config: config) }
        guard isSessionOpen, window?.isMiniaturized != true else { return }
        switch tab {
        case .log:
            pollLogNow()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollLogNow() }
            logTimer = timer; RunLoop.main.add(timer, forMode: .common)
        case .skins: skinInspector.activate(config: config)
        case .display: displayInfo.activate()
        case .network: networkInfo.activate()
        case .plugins: pluginsTable.reloadData()
        }
    }
    @objc private func tabSegmentChanged(_ sender: NSSegmentedControl) {
        guard Tab.allCases.indices.contains(sender.selectedSegment) else { return }
        selectTab(Tab.allCases[sender.selectedSegment])
    }
    @objc private func closeButtonClicked() { close() }
    @objc private func openHelp() {
        if let url = URL(string: "https://docs-v5.rainmeter.net/manual/user-interface/debug/") { NSWorkspace.shared.open(url) }
    }
    func resetLogPanel() {
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

        // Keep the existing live-panel bound; the initial history is independently limited to 50.
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

    func setLogFilter(error: Bool? = nil, warning: Bool? = nil, notice: Bool? = nil, debug: Bool? = nil) {
        pollLogNow()
        if let error { filterError = error }
        if let warning { filterWarning = warning }
        if let notice { filterNotice = notice }
        if let debug { filterDebug = debug }
        for (item, enabled) in zip(typeButton.itemArray.dropFirst(), [filterError, filterWarning, filterNotice, filterDebug]) {
            item.state = enabled ? .on : .off
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

    private func writeToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === logMenu {
            let values: [String?] = [resolveLogMessagesForCopy(contextMenu: true), displayedLogs.isEmpty ? nil : displayedLogs.map(\.message).joined(separator: "\n")]
            for (item, value) in zip(menu.items, values) { item.representedObject = value; item.isEnabled = value != nil }
        } else if menu === fileButton.menu {
            let exists = FileManager.default.fileExists(atPath: Log.fileURL.path)
            menu.item(withTitle: "Start logging")?.isEnabled = !Log.fileLoggingEnabled
            menu.item(withTitle: "Stop logging")?.isEnabled = Log.fileLoggingEnabled
            menu.item(withTitle: "Show log file")?.isEnabled = exists
            menu.item(withTitle: "Delete log file")?.isEnabled = exists
        }
    }
    func refreshLogFileMenu() {
        if let menu = fileButton.menu { menuNeedsUpdate(menu) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === logTable ? displayedLogs.count : plugins.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue else { return nil }
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        if tableView === logTable {
            guard displayedLogs.indices.contains(row) else { return nil }
            let line = displayedLogs[row]
            switch key {
            case "type":
                label.stringValue = Self.formatLogType(line.level)
                label.textColor = line.level == .error ? .systemRed : line.level == .warning ? .systemOrange : .labelColor
            case "time": label.stringValue = Self.formatLogTime(line.date); label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            case "source": label.stringValue = line.source ?? "—"
            default: label.stringValue = line.message; label.toolTip = line.message
            }
        } else {
            guard plugins.indices.contains(row) else { return nil }
            let item = plugins[row]
            label.stringValue = key == "name" ? item.name : key == "version" ? item.version : item.author
        }
        return label
    }
    var testLogTable: NSTableView { logTable }
    var testLogMenu: NSMenu { logMenu }
    var testLogFileMenu: NSMenu? { fileButton.menu }
    var testPluginsTable: NSTableView { pluginsTable }
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
