import AppKit
import DesksetCore

private final class DebugInspectorTableView: NSTableView, NSMenuItemValidation {
    var onCopy: (() -> Void)?
    var canCopy: (() -> Bool)?
    @objc func copy(_ sender: Any?) { onCopy?() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? canCopy?() ?? false : true
    }
}

private final class DebugInspectorRowView: NSTableRowView {
    var isPausedMeasure = false
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isPausedMeasure && !isSelected {
            NSColor.systemYellow.withAlphaComponent(0.22).setFill()
            bounds.fill()
        }
    }
}

final class DebugSkinInspectorView: NSView, NSTableViewDataSource, NSTableViewDelegate,
                                    NSSearchFieldDelegate, NSMenuDelegate {
    enum Group: String, CaseIterable { case measures = "Measures", variables = "Variables", watch = "Watch" }
    private enum Row {
        case group(Group), measure(MeasureDebugItem), variable(VariableDebugItem), watch(DebugWatchResult)

        var identity: String {
            switch self {
            case .group(let group): return "group:\(group.rawValue)"
            case .measure(let value): return "measure:\(value.name.lowercased())"
            case .variable(let value): return "variable:\(value.name.lowercased())"
            case .watch(let value): return "watch:\(value.id)"
            }
        }
    }
    private enum Command {
        case copy(String), add(String), edit(DebugWatchExpression), delete(UUID), source(IniSourceLocation)
    }
    private struct MenuPayload {
        let command: Command
        let config: String
        let runtimeID: ObjectIdentifier
        let generation: UInt64
    }

    private unowned let app: AppController
    private let consumerID = UUID()
    private let editorConsumerID = UUID()
    private let configPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshCheck = NSButton(checkboxWithTitle: "Refresh on file change", target: nil, action: nil)
    private let skinButton = NSButton(title: "Skin", target: nil, action: nil)
    private let table = DebugInspectorTableView()
    private let filterField = NSSearchField()
    private let jumpPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let addWatchButton = NSButton(title: "Add watch…", target: nil, action: nil)
    private let contextMenu = NSMenu()
    private let fileRefresh = DebugFileRefresh()
    private var rows: [Row] = []
    private var watchesByConfig: [String: [DebugWatchExpression]] = [:]
    private var isActive = false
    private var generation: UInt64 = 0
    private var runtimeID: ObjectIdentifier?
    private var ticket: SkinDebugRequestTicket?
    private var editorTicket: SkinDebugRequestTicket?
    private var pollTimer: Timer?
    private var skinsObserver: NSObjectProtocol?
    private(set) var editor: DebugWatchEditorController?
    private(set) var activeSkinConfigs: [String] = []
    private(set) var selectedSkinConfig: String?
    private(set) var currentSkinState: SkinDebugState?

    init(app: AppController) {
        self.app = app
        super.init(frame: .zero)
        buildUI()
        skinsObserver = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                              queue: .main) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.reloadActiveSkinsList()
        }
        fileRefresh.onRefresh = { [weak self] in self?.refreshNow() }
        fileRefresh.onDisabled = { [weak self] reason in
            self?.refreshCheck.state = .off
            self?.refreshCheck.toolTip = reason
        }
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pollTimer?.invalidate()
        ticket?.cancel()
        editorTicket?.cancel()
        editor?.close()
        fileRefresh.stop()
        if let skinsObserver { NotificationCenter.default.removeObserver(skinsObserver) }
    }

    func activate(config: String? = nil) {
        isActive = true
        synchronizeSelection(preferred: config)
        if pollTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollNow() }
            pollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        updateControls()
        updateFileWatching()
        pollNow()
    }

    func deactivate() {
        isActive = false
        generation &+= 1
        pollTimer?.invalidate()
        pollTimer = nil
        ticket?.cancel()
        ticket = nil
        closeEditor()
        fileRefresh.stop()
        updateControls()
    }

    func close() {
        deactivate()
        watchesByConfig.removeAll()
        currentSkinState = nil
        rebuildRows()
    }

    func reloadActiveSkinsList() {
        synchronizeSelection(preferred: nil)
        pollNow()
    }

    func selectSkin(config: String?) {
        synchronizeSelection(preferred: config)
        pollNow()
    }

    private func synchronizeSelection(preferred: String?) {
        let configs = app.sortedControllers.filter { !$0.isStopped }.map(\.config)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let requested = preferred ?? selectedSkinConfig
        let selected = requested.flatMap { requested in
            configs.first { $0.caseInsensitiveCompare(requested) == .orderedSame }
        } ?? configs.first
        let selectedID = selected.flatMap { app.controller(for: $0) }.map { ObjectIdentifier($0.runtime) }
        let configChanged = selectedSkinConfig?.lowercased() != selected?.lowercased()
        let runtimeChanged = runtimeID != selectedID
        if configs != activeSkinConfigs {
            activeSkinConfigs = configs
            configPopup.removeAllItems()
            configPopup.addItems(withTitles: configs)
        }
        if configChanged || runtimeChanged {
            generation &+= 1
            ticket?.cancel()
            ticket = nil
            closeEditor()
            currentSkinState = nil
            if configChanged {
                refreshCheck.state = .off
                refreshCheck.toolTip = nil
                fileRefresh.stop()
            }
            selectedSkinConfig = selected
            runtimeID = selectedID
            rebuildRows()
        }
        if let selected { configPopup.selectItem(withTitle: selected) }
        updateControls()
    }

    func pollNow() {
        guard isActive else { return }
        synchronizeSelection(preferred: nil)
        guard let config = selectedSkinConfig, let controller = app.controller(for: config),
              !controller.isStopped else { return }
        let runtime = controller.runtime
        let requestedGeneration = generation
        let expressions = watchesByConfig[config.lowercased()] ?? []
        ticket = runtime.requestDebugState(consumerID: consumerID, expressions: expressions) { [weak self, weak runtime] state in
            guard let self, self.isActive, self.generation == requestedGeneration,
                  self.selectedSkinConfig?.caseInsensitiveCompare(config) == .orderedSame,
                  self.app.controller(for: config)?.runtime === runtime else { return }
            self.ticket = nil
            if self.currentSkinState != state {
                self.currentSkinState = state
                self.rebuildRows()
            }
            self.updateFileWatching()
        }
    }

    /// Refresh the selected loaded skin, keeping its watch expressions in this inspector session.
    func refreshNow() {
        guard isActive, let config = selectedSkinConfig,
              let controller = app.controller(for: config), !controller.isStopped else { return }
        generation &+= 1
        ticket?.cancel()
        ticket = nil
        closeEditor()
        currentSkinState = nil
        rebuildRows()
        app.refresh(controller)
        reloadActiveSkinsList()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive, window?.attachedSheet == nil else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 96 || (modifiers.contains(.control) && event.charactersIgnoringModifiers?.lowercased() == "r") {
            refreshNow()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func updateFileWatching() {
        guard isActive, refreshCheck.state == .on, let state = currentSkinState else {
            if !isActive || refreshCheck.state != .on { fileRefresh.stop() }
            return
        }
        let files = [state.fileURL] + state.dependencyFiles
        if fileRefresh.isEnabled { fileRefresh.update(files: files) } else { fileRefresh.start(files: files) }
    }

    @objc private func chooseConfig(_ sender: Any?) { selectSkin(config: configPopup.titleOfSelectedItem) }

    @objc private func toggleFileRefresh(_ sender: Any?) {
        refreshCheck.toolTip = nil
        updateFileWatching()
    }

    @objc private func showSkinMenu(_ sender: Any?) {
        guard let config = selectedSkinConfig, let controller = app.controller(for: config), !controller.isStopped else { return }
        let menu = app.skinMenu(for: controller, includeCustomItems: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: skinButton.bounds.maxY), in: skinButton)
    }

    private func updateControls() {
        let hasSkin = isActive && selectedSkinConfig != nil
        configPopup.isEnabled = isActive && !activeSkinConfigs.isEmpty
        refreshCheck.isEnabled = hasSkin
        skinButton.isEnabled = hasSkin
        addWatchButton.isEnabled = hasSkin
        filterField.isEnabled = hasSkin
    }

    private func rebuildRows() {
        let selection = table.selectedRow >= 0 && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].identity : nil
        let query = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: [String]) -> Bool {
            query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        rows = []
        if let state = currentSkinState {
            let measures = state.measures.filter { matches([$0.name, $0.number, $0.string]) }
            let variables = state.variables.filter { matches([$0.name, $0.value]) }
            if !measures.isEmpty { rows += [.group(.measures)] + measures.map { .measure($0) } }
            if !variables.isEmpty { rows += [.group(.variables)] + variables.map { .variable($0) } }
            if !state.watchResults.isEmpty { rows += [.group(.watch)] + state.watchResults.map { .watch($0) } }
        }
        table.reloadData()
        if let selection, let index = rows.firstIndex(where: { $0.identity == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        for group in Group.allCases {
            jumpPopup.item(withTitle: group.rawValue)?.isEnabled = rows.contains { row in
                if case .group(let value) = row { return value == group }; return false
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === filterField { rebuildRows() }
    }

    @objc private func jumpToGroup(_ sender: NSMenuItem) {
        guard let group = Group(rawValue: sender.title), let index = rows.firstIndex(where: {
            if case .group(let candidate) = $0 { return candidate == group }; return false
        }) else { return }
        table.scrollRowToVisible(index)
    }

    private func selectedRow(context: Bool = false) -> Row? {
        let index = context && table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(index) ? rows[index] : nil
    }

    private func copyValue(for row: Row?) -> String? {
        switch row {
        case .measure(let value): return value.string
        case .variable(let value): return value.value
        case .watch(let value): return value.error ?? value.value ?? ""
        default: return nil
        }
    }

    @objc private func doubleClickRow(_ sender: Any?) {
        switch selectedRow(context: true) {
        case .measure(let value): addWatch(DebugWatchExpression(kind: .string, text: "[\(value.name)]"))
        case .variable(let value): addWatch(DebugWatchExpression(kind: .string, text: "#\(value.name)#"))
        default: break
        }
    }

    func addWatch(_ expression: DebugWatchExpression) {
        guard isActive, let config = selectedSkinConfig else { return }
        watchesByConfig[config.lowercased(), default: []].append(expression)
        watchesChanged()
    }

    private func watchesChanged() {
        generation &+= 1
        ticket?.cancel()
        ticket = nil
        pollNow()
    }

    @objc private func addWatchClicked(_ sender: Any?) { showWatchEditor(initial: nil) }

    func showWatchEditor(initial: DebugWatchExpression?) {
        guard isActive, let config = selectedSkinConfig,
              let controller = app.controller(for: config), !controller.isStopped else { return }
        closeEditor()
        let runtime = controller.runtime
        let requestedGeneration = generation
        let editorID = UUID()
        currentEditorID = editorID
        let newEditor = DebugWatchEditorController(initial: initial, preview: { [weak self, weak runtime] expression, completion in
            guard let self, let runtime, self.isActive, self.currentEditorID == editorID,
                  self.generation == requestedGeneration,
                  self.selectedSkinConfig?.caseInsensitiveCompare(config) == .orderedSame,
                  self.app.controller(for: config)?.runtime === runtime else { completion(""); return }
            self.editorTicket = runtime.requestDebugState(consumerID: self.editorConsumerID, expressions: [expression]) { [weak self, weak runtime] state in
                guard let self, self.isActive, self.currentEditorID == editorID,
                      self.generation == requestedGeneration,
                      self.selectedSkinConfig?.caseInsensitiveCompare(config) == .orderedSame,
                      self.app.controller(for: config)?.runtime === runtime else { return }
                self.editorTicket = nil
                let result = state.watchResults.first
                completion(result?.error ?? result?.value ?? "")
            }
        }, execute: { [weak self, weak runtime] action in
            guard let self, let runtime, self.isActive, self.currentEditorID == editorID,
                  self.generation == requestedGeneration,
                  self.app.controller(for: config)?.runtime === runtime else { return }
            runtime.send(.execute(action, section: nil))
        }, save: { [weak self, weak runtime] expression in
            guard let self, self.isActive, self.currentEditorID == editorID,
                  self.generation == requestedGeneration,
                  self.app.controller(for: config)?.runtime === runtime else { return }
            let key = config.lowercased()
            if let index = self.watchesByConfig[key]?.firstIndex(where: { $0.id == expression.id }) {
                self.watchesByConfig[key]?[index] = expression
            } else { self.watchesByConfig[key, default: []].append(expression) }
            self.watchesChanged()
        }, onClose: { [weak self] in
            guard let self, self.currentEditorID == editorID else { return }
            self.editorTicket?.cancel()
            self.editorTicket = nil
            self.currentEditorID = nil
            self.editor = nil
        })
        editor = newEditor
        if app.presentsWindows { newEditor.show(relativeTo: window) } else { newEditor.startPreviewing() }
    }

    private var currentEditorID: UUID?

    private func closeEditor() {
        editorTicket?.cancel()
        editorTicket = nil
        let previous = editor
        editor = nil
        currentEditorID = nil
        previous?.close()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        menu.removeAllItems()
        guard let config = selectedSkinConfig, let runtimeID else { return }
        func item(_ title: String, _ command: Command) {
            let item = NSMenuItem(title: title, action: #selector(performContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuPayload(command: command, config: config, runtimeID: runtimeID, generation: generation)
            menu.addItem(item)
        }
        switch selectedRow(context: true) {
        case .measure(let value):
            item("Copy name", .copy(value.name))
            item("Copy range", .copy(value.range))
            item("Copy number", .copy(value.number))
            item("Copy string", .copy(value.string))
            menu.addItem(.separator())
            item("Add watch", .add("[\(value.name)]"))
            if let location = value.location { item("Edit measure", .source(location)) }
        case .variable(let value):
            item("Copy value", .copy(value.value))
            menu.addItem(.separator())
            item("Add watch", .add("#\(value.name)#"))
        case .watch(let value):
            item("Copy value", .copy(value.error ?? value.value ?? ""))
            menu.addItem(.separator())
            item("Edit watch", .edit(value.expression))
            item("Delete watch", .delete(value.id))
        default: break
        }
    }

    @objc private func performContextAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        if case .copy(let value) = payload.command { copyToClipboard(value); return }
        guard isActive, generation == payload.generation,
              selectedSkinConfig?.caseInsensitiveCompare(payload.config) == .orderedSame,
              let current = app.controller(for: payload.config), ObjectIdentifier(current.runtime) == payload.runtimeID else { return }
        switch payload.command {
        case .copy: break
        case .add(let text): addWatch(DebugWatchExpression(kind: .string, text: text))
        case .edit(let expression): showWatchEditor(initial: expression)
        case .delete(let id):
            watchesByConfig[payload.config.lowercased()]?.removeAll { $0.id == id }
            watchesChanged()
        case .source(let location): CodeEditorRouter.open(file: location.file, line: location.line, app: app)
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .group = rows[row] { return true }; return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = DebugInspectorRowView()
        if rows.indices.contains(row), case .measure(let measure) = rows[row] { view.isPausedMeasure = measure.isPaused }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard rows.indices.contains(index) else { return nil }
        let column: String
        if case .group = rows[index] { column = "name" }
        else if let identifier = tableColumn?.identifier.rawValue { column = identifier }
        else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DebugInspector.\(column)")
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.toolTip = nil
        label.stringValue = ""
        switch rows[index] {
        case .group(let group):
            if column == "name" { label.stringValue = group.rawValue; label.font = .boldSystemFont(ofSize: 12) }
        case .measure(let value):
            switch column {
            case "name": label.stringValue = value.name
            case "number": label.stringValue = value.displayNumber; label.toolTip = value.range
            case "string": label.stringValue = value.displayString
            default: break
            }
            if value.isDisabled { label.textColor = .tertiaryLabelColor }
        case .variable(let value):
            if column == "name" { label.stringValue = value.name }
            if column == "string" { label.stringValue = value.displayValue }
        case .watch(let result):
            if column == "name" { label.stringValue = SkinDebugState.truncateForDisplay(result.expression.text) }
            let valueColumn = result.expression.kind == .formula ? "number" : "string"
            if column == valueColumn { label.stringValue = SkinDebugState.truncateForDisplay(result.error ?? result.value ?? "") }
            if result.error != nil { label.textColor = .systemRed }
        }
        return label
    }

    private func buildUI() {
        configPopup.target = self
        configPopup.action = #selector(chooseConfig(_:))
        refreshCheck.target = self
        refreshCheck.action = #selector(toggleFileRefresh(_:))
        skinButton.target = self
        skinButton.action = #selector(showSkinMenu(_:))
        addWatchButton.target = self
        addWatchButton.action = #selector(addWatchClicked(_:))
        filterField.placeholderString = "Filter…"
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityLabel("Filter measures and variables")
        configPopup.setAccessibilityLabel("Active skin")
        jumpPopup.addItem(withTitle: "Jump to")
        jumpPopup.menu?.autoenablesItems = false
        for group in Group.allCases {
            let item = NSMenuItem(title: group.rawValue, action: #selector(jumpToGroup(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = false
            jumpPopup.menu?.addItem(item)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(doubleClickRow(_:))
        table.setAccessibilityLabel("Skin measures, variables and watches")
        table.onCopy = { [weak self] in
            guard let self, let value = self.copyValue(for: self.selectedRow()) else { return }
            self.copyToClipboard(value)
        }
        table.canCopy = { [weak self] in self?.copyValue(for: self?.selectedRow()) != nil }
        for (id, title, width) in [("name", "Name", 200.0), ("number", "Number", 120.0), ("string", "String", 360.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 80
            table.addTableColumn(column)
        }
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false
        table.menu = contextMenu
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        for view in [configPopup, refreshCheck, skinButton, scroll, filterField, jumpPopup, addWatchButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            configPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            configPopup.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            configPopup.widthAnchor.constraint(equalToConstant: 270),
            refreshCheck.leadingAnchor.constraint(equalTo: configPopup.trailingAnchor, constant: 12),
            refreshCheck.centerYAnchor.constraint(equalTo: configPopup.centerYAnchor),
            skinButton.leadingAnchor.constraint(greaterThanOrEqualTo: refreshCheck.trailingAnchor, constant: 12),
            skinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            skinButton.centerYAnchor.constraint(equalTo: configPopup.centerYAnchor),
            skinButton.widthAnchor.constraint(equalToConstant: 90),
            scroll.topAnchor.constraint(equalTo: configPopup.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: filterField.topAnchor, constant: -12),
            filterField.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            filterField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            jumpPopup.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 10),
            jumpPopup.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            jumpPopup.widthAnchor.constraint(equalToConstant: 110),
            addWatchButton.leadingAnchor.constraint(equalTo: jumpPopup.trailingAnchor, constant: 10),
            addWatchButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            addWatchButton.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            addWatchButton.widthAnchor.constraint(equalToConstant: 110),
        ])
    }

    var testTable: NSTableView { table }
    var testMenu: NSMenu { contextMenu }
    var testFilterField: NSSearchField { filterField }
    var testRefreshCheck: NSButton { refreshCheck }
    var testJumpPopup: NSPopUpButton { jumpPopup }
    var testAddWatchButton: NSButton { addWatchButton }
    var testFileRefresh: DebugFileRefresh { fileRefresh }
    var testWatchExpressions: [DebugWatchExpression] { selectedSkinConfig.flatMap { watchesByConfig[$0.lowercased()] } ?? [] }
}
