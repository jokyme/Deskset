import AppKit

private final class DebugInfoTableView: NSTableView, NSMenuItemValidation {
    var copyValue: (() -> Void)?
    var hasCopyValue: (() -> Bool)?

    @objc func copy(_ sender: Any?) { copyValue?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let window, window.firstResponder !== self { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            guard hasCopyValue?() == true else { return false }
            copyValue?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? hasCopyValue?() == true : true
    }
}

/// The Debug window's grouped Display and Network tables. AppKit and request state stay on main; network facts
/// are collected off main with one request in flight. Hidden or closed pages never publish a delayed result.
final class DebugInfoView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Kind: Equatable { case display, network }

    private struct Row {
        var group: String
        var field: DebugSystemInfo.Field?
        var identity: String { group + "\u{0}" + (field?.label ?? "") }
    }

    private let kind: Kind
    private let displayReader: () -> [DebugSystemInfo.Group]
    private let networkReader: (Bool) -> [DebugSystemInfo.Group]
    private let refreshInterval: TimeInterval?
    private let table = DebugInfoTableView()
    private let virtualCheck = NSButton(checkboxWithTitle: "Show virtual interfaces", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMenuValue(_:)), keyEquivalent: "")
    private let copyAllItem = NSMenuItem(title: "Copy all", action: #selector(copyMenuValue(_:)), keyEquivalent: "")
    private var rows: [Row] = []
    private(set) var groups: [DebugSystemInfo.Group] = []
    private var isActive = false
    private var generation: UInt64 = 0
    private(set) var isNetworkRequestInFlight = false
    private var refreshAfterCurrentRequest = false
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?

    init(kind: Kind,
         displayReader: @escaping () -> [DebugSystemInfo.Group] = { DebugSystemInfo.displayGroups() },
         networkReader: @escaping (Bool) -> [DebugSystemInfo.Group] = {
             DebugSystemInfo.networkGroups(showVirtualInterfaces: $0)
         }, refreshInterval: TimeInterval? = 2) {
        self.kind = kind
        self.displayReader = displayReader
        self.networkReader = networkReader
        self.refreshInterval = refreshInterval
        super.init(frame: .zero)
        buildView()
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func activate() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isActive else { return }
        isActive = true
        generation &+= 1
        if kind == .display {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() }
        } else if let refreshInterval, refreshInterval > 0 {
            let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }

    func deactivate() {
        dispatchPrecondition(condition: .onQueue(.main))
        isActive = false
        generation &+= 1
        refreshAfterCurrentRequest = false
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    func close() { deactivate() }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive else { return }
        switch kind {
        case .display:
            apply(displayReader())
        case .network:
            guard !isNetworkRequestInFlight else {
                refreshAfterCurrentRequest = true
                return
            }
            isNetworkRequestInFlight = true
            refreshAfterCurrentRequest = false
            let requestGeneration = generation
            let showVirtual = virtualCheck.state == .on
            let reader = networkReader
            status.stringValue = groups.isEmpty ? "Loading network interfaces…" : "Refreshing…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = reader(showVirtual)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isNetworkRequestInFlight = false
                    if self.isActive, self.generation == requestGeneration {
                        self.apply(result)
                    }
                    if self.isActive, self.refreshAfterCurrentRequest {
                        self.refreshAfterCurrentRequest = false
                        self.refresh()
                    }
                }
            }
        }
    }

    private func buildView() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 21
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(kind == .display ? "Display information" : "Network information")
        for (id, title, width, minimum): (String, String, CGFloat, CGFloat) in [
            ("property", "Property", 180, 140), ("value", "Value", 420, 220)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = minimum
            table.addTableColumn(column)
        }
        table.copyValue = { [weak self] in self?.copySelectedValue() }
        table.hasCopyValue = { [weak self] in self?.selectedValue != nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for item in [copyItem, copyAllItem] {
            item.target = self
            menu.addItem(item)
        }
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        if kind == .network {
            virtualCheck.target = self
            virtualCheck.action = #selector(virtualInterfacesChanged(_:))
            footer.addArrangedSubview(virtualCheck)
        }
        footer.addArrangedSubview(status)
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)
        ])
    }

    @objc private func virtualInterfacesChanged(_ sender: NSButton) {
        generation &+= 1
        refresh()
    }

    private func apply(_ newGroups: [DebugSystemInfo.Group]) {
        status.stringValue = newGroups.isEmpty
            ? (kind == .network ? "No network interfaces to display." : "No displays available.") : ""
        guard newGroups != groups else { return }
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].identity : nil
        groups = newGroups
        rows = groups.flatMap { group in
            [Row(group: group.title, field: nil)] + group.fields.map { Row(group: group.title, field: $0) }
        }
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.identity == selected && $0.field != nil }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    private var selectedValue: String? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].field?.value : nil
    }

    var copyAllText: String {
        groups.map { group in
            ([group.title] + group.fields.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    @objc func copySelectedValue() {
        guard let selectedValue else { return }
        writeToPasteboard(selectedValue)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = table.clickedRow
        let value = rows.indices.contains(row) ? rows[row].field?.value : selectedValue
        copyItem.representedObject = value
        copyItem.isEnabled = value != nil
        copyAllItem.representedObject = copyAllText
        copyAllItem.isEnabled = !groups.isEmpty
    }

    @objc private func copyMenuValue(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        writeToPasteboard(text)
    }

    private func writeToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].field == nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].field != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        guard tableColumn != nil || item.field == nil else { return nil }
        let column = tableColumn?.identifier.rawValue ?? "property"
        let identifier = NSUserInterfaceItemIdentifier("DebugInfo.\(column).\(item.field == nil ? "group" : "field")")
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.font = item.field == nil ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        if let field = item.field {
            label.stringValue = column == "property" ? field.label : field.value
        } else {
            label.stringValue = column == "property" ? item.group : ""
        }
        label.toolTip = label.stringValue.isEmpty ? nil : label.stringValue
        return label
    }

    // Narrow accessors for lifecycle, selection and clipboard checks without showing a desktop window.
    var testTable: NSTableView { table }
    var testVirtualCheckbox: NSButton { virtualCheck }
    var testStatusText: String { status.stringValue }
}
