import AppKit

/// Creates skin files within one folder and manages the templates used for new files.
final class NewSkinWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTabViewDelegate,
    NSTextFieldDelegate {
    enum NameKind: Equatable { case root, folder, skin, rename }
    struct NameRequest {
        let kind: NameKind
        let title: String
        let initialValue: String
    }

    private static var currentController: NewSkinWindowController?
    static func window(for app: AppController) -> NewSkinWindowController? {
        guard let controller = currentController, controller.app === app, !controller.finished else { return nil }
        return controller
    }

    @discardableResult
    static func show(app: AppController, initialDirectory: URL? = nil) -> NewSkinWindowController? {
        guard !app.isTerminating else { return nil }
        if let existing = window(for: app) { app.bringToFront(existing); return existing }
        do {
            let model = try NewSkinModel(skinsDirectory: app.skinsDirectory, settingsDirectory: app.settingsDirectory,
                                         initialDirectory: initialDirectory)
            currentController?.close()
            let controller = try NewSkinWindowController(app: app, model: model)
            currentController = controller
            app.bringToFront(controller)
            if initialDirectory == nil { controller.requestRootName() }
            return controller
        } catch {
            app.alert(L("Could not create a skin"), error.localizedDescription)
            return nil
        }
    }

    private unowned let app: AppController
    private let model: NewSkinModel
    private var roots: [NewSkinModel.Item] = []
    private var templateNames: [String] = []
    private var chosenTemplate = NewSkinModel.TemplateID.standard
    private var selectedID: UUID?
    private var busy = false
    private var finished = false
    private var nameRequestID: UUID?
    private var nameSheet: NSAlert?
    private let tabs = NSTabView()
    private let pathField = NSTextField(string: "")
    private let outline = NSOutlineView()
    private let itemMenu = NSMenu()
    private let addFolderButton = NSButton(title: L("Add Folder"), target: nil, action: nil)
    private let resourcesButton = NSButton(title: "@Resources", target: nil, action: nil)
    private let addSkinButton = NSButton(title: L("Add skin"), target: nil, action: nil)
    private let templatePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let templateNameField = NSTextField()
    private let saveTemplateButton = NSButton(title: L("Save"), target: nil, action: nil)
    private let templateTable = NSTableView()
    private let editTemplateButton = NSButton(title: L("Edit"), target: nil, action: nil)
    private let deleteTemplateButton = NSButton(title: L("Delete"), target: nil, action: nil)
    private var contextIDForTesting: UUID?

    /// Tests supply responses without creating sheets or opening a modal run loop.
    var namePromptForTesting: ((NameRequest, @escaping (String?) -> Void) -> Void)?
    var errorForTesting: ((Error) -> Void)?
    var preflightForTesting: ((URL, Bool) -> Bool)?
    var refreshForTesting: (() -> Void)?

    init(app: AppController, model: NewSkinModel) throws {
        self.app = app
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Create new skin")
        window.minSize = NSSize(width: 580, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
        try reload()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func close() { finish(); super.close() }
    func windowWillClose(_ notification: Notification) { finish() }
    func windowDidBecomeKey(_ notification: Notification) {
        guard available else { return }
        perform { try reload() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        nameRequestID = nil
        let sheet = nameSheet
        nameSheet = nil
        if let sheet {
            sheet.window.sheetParent?.endSheet(sheet.window, returnCode: .cancel)
            sheet.window.orderOut(nil)
        }
        if Self.currentController === self { Self.currentController = nil }
        guard !app.isTerminating else { return }
        if let refreshForTesting { refreshForTesting() }
        else { app.refreshAll(rescan: true) }
    }

    private var available: Bool { !finished && !busy && !app.isTerminating }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        tabs.delegate = self
        for (identifier, title, view) in [("skin", L("New skin"), buildSkinTab()),
                                           ("template", L("Template"), buildTemplateTab())] {
            let tab = NSTabViewItem(identifier: identifier)
            tab.label = title
            tab.view = view
            tabs.addTabViewItem(tab)
        }
        let close = NSButton(title: L("Close"), target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        for view in [tabs, close] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabs.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    private func buildSkinTab() -> NSView {
        pathField.isEditable = false
        pathField.isSelectable = true
        pathField.setAccessibilityLabel(L("Selected skin folder"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = L("Name")
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.dataSource = self
        outline.delegate = self
        outline.allowsEmptySelection = false
        outline.target = self
        outline.doubleAction = #selector(editSelectedSkin)
        outline.setAccessibilityLabel(L("New skin folders and files"))
        itemMenu.delegate = self
        itemMenu.autoenablesItems = false
        outline.menu = itemMenu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        addFolderButton.target = self
        addFolderButton.action = #selector(addFolderClicked)
        resourcesButton.target = self
        resourcesButton.action = #selector(addResourcesClicked)
        addSkinButton.target = self
        addSkinButton.action = #selector(addSkinClicked)
        templatePopup.target = self
        templatePopup.action = #selector(templateChosen(_:))
        templatePopup.menu?.autoenablesItems = false
        templatePopup.setAccessibilityLabel(L("Template for new skins"))
        let buttons = NSStackView(views: [addFolderButton, resourcesButton, addSkinButton, templatePopup, NSView()])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 10
        for button in [addFolderButton, resourcesButton, addSkinButton, templatePopup] {
            button.widthAnchor.constraint(equalToConstant: 136).isActive = true
        }
        let row = NSStackView(views: [scroll, buttons])
        row.alignment = .top
        row.spacing = 12
        scroll.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        buttons.widthAnchor.constraint(equalToConstant: 136).isActive = true
        let stack = NSStackView(views: [pathField, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        pathField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return padded(stack)
    }

    private func buildTemplateTab() -> NSView {
        templateNameField.delegate = self
        templateNameField.target = self
        templateNameField.action = #selector(saveTemplateClicked)
        templateNameField.setAccessibilityLabel(L("Template name"))
        saveTemplateButton.target = self
        saveTemplateButton.action = #selector(saveTemplateClicked)
        let nameRow = NSStackView(views: [NSTextField(labelWithString: L("Name:")), templateNameField, saveTemplateButton])
        nameRow.spacing = 10
        nameRow.alignment = .centerY
        let saveBox = NSBox()
        saveBox.title = L("Save new template")
        saveBox.contentView = padded(nameRow)
        saveBox.heightAnchor.constraint(equalToConstant: 90).isActive = true
        templateNameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("template"))
        column.title = L("Saved templates")
        templateTable.addTableColumn(column)
        templateTable.headerView = nil
        templateTable.rowHeight = 24
        templateTable.dataSource = self
        templateTable.delegate = self
        templateTable.allowsEmptySelection = true
        templateTable.setAccessibilityLabel(L("Saved templates"))
        let scroll = NSScrollView()
        scroll.documentView = templateTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editTemplateButton.target = self
        editTemplateButton.action = #selector(editTemplateClicked)
        deleteTemplateButton.target = self
        deleteTemplateButton.action = #selector(deleteTemplateClicked)
        let buttons = NSStackView(views: [editTemplateButton, deleteTemplateButton, NSView()])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 10
        for button in [editTemplateButton, deleteTemplateButton] {
            button.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }
        let listRow = NSStackView(views: [scroll, buttons])
        listRow.alignment = .top
        listRow.spacing = 12
        scroll.heightAnchor.constraint(equalTo: listRow.heightAnchor).isActive = true
        let listBox = NSBox()
        listBox.title = L("Saved templates")
        listBox.contentView = padded(listRow)
        listBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let stack = NSStackView(views: [saveBox, listBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        saveBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        listBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        saveBox.setContentHuggingPriority(.required, for: .vertical)
        return padded(stack)
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func allItems(_ items: [NewSkinModel.Item]) -> [NewSkinModel.Item] {
        items.flatMap { [$0] + allItems($0.children) }
    }

    private func reload(selecting id: UUID? = nil, template: String? = nil) throws {
        let selectedTemplate = template ?? selectedNamedTemplate
        let selectedItemID = id ?? selectedID
        roots = try model.reload()
        templateNames = try model.templates()
        if case .named(let name) = chosenTemplate, !templateNames.contains(name) { chosenTemplate = .standard }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        selectedID = selectedItemID ?? roots.first?.id
        if let item = selectedID.flatMap({ model.item(id: $0) }), outline.row(forItem: item) >= 0 {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
        } else {
            selectedID = roots.first?.id
            if !roots.isEmpty { outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
        templateTable.reloadData()
        if let name = selectedTemplate, let row = templateNames.firstIndex(of: name) {
            templateTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { templateTable.deselectAll(nil) }
        updateTemplateMenu()
        updateControls()
    }

    private var selectedItem: NewSkinModel.Item? { selectedID.flatMap { model.item(id: $0) } }
    private var selectedFolder: NewSkinModel.Item? {
        guard let item = selectedItem else { return nil }
        if item.kind == .folder { return item }
        return allItems(roots).first {
            $0.kind == .folder && $0.url.path == item.url.deletingLastPathComponent().path
        }
    }
    private var selectedNamedTemplate: String? {
        let row = templateTable.selectedRow
        return templateNames.indices.contains(row) ? templateNames[row] : nil
    }

    private func updateTemplateMenu() {
        templatePopup.removeAllItems()
        templatePopup.addItem(withTitle: L("Template…"))
        for (title, template) in [(L("Use default template"), NewSkinModel.TemplateID.standard)]
            + templateNames.map({ ($0, NewSkinModel.TemplateID.named($0)) }) {
            let item = NSMenuItem(title: title, action: #selector(templateChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template
            item.state = template == chosenTemplate ? .on : .off
            templatePopup.menu?.addItem(item)
        }
    }

    private func updateControls() {
        let parent = selectedFolder
        pathField.stringValue = (parent?.url ?? roots.first?.url)?.path ?? app.skinsDirectory.path
        pathField.toolTip = pathField.stringValue
        addFolderButton.isEnabled = available && (parent != nil || roots.isEmpty)
        addSkinButton.isEnabled = available && parent != nil
        resourcesButton.isEnabled = available && model.canAddResources
        templatePopup.isEnabled = available
        templateNameField.isEnabled = available
        saveTemplateButton.isEnabled = available && !templateNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        editTemplateButton.isEnabled = available && selectedNamedTemplate != nil
        deleteTemplateButton.isEnabled = available && selectedNamedTemplate != nil
    }

    private func perform(_ body: () throws -> Void) {
        guard available else { return }
        busy = true
        updateControls()
        defer { busy = false; updateControls() }
        do { try body() }
        catch {
            guard !finished else { return }
            if let errorForTesting { errorForTesting(error) }
            else { app.alert(L("Could not complete the operation"), error.localizedDescription) }
        }
    }

    private func askName(_ kind: NameKind, title: String, initial: String = "",
                         then action: @escaping (String) throws -> Void) {
        guard available else { return }
        let request = NameRequest(kind: kind, title: title, initialValue: initial)
        let id = UUID()
        nameRequestID = id
        busy = true
        updateControls()
        let answer: (String?) -> Void = { [weak self] name in
            guard let self, self.nameRequestID == id, !self.finished else { return }
            self.nameRequestID = nil
            self.nameSheet = nil
            self.busy = false
            self.updateControls()
            guard let name else { return }
            self.perform { try action(name) }
        }
        if let namePromptForTesting { namePromptForTesting(request, answer); return }
        guard app.presentsWindows, let window else { answer(nil); return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel(L("Name"))
        alert.accessoryView = field
        alert.addButton(withTitle: kind == .rename ? L("Rename") : L("Create"))
        alert.addButton(withTitle: L("Cancel"))
        nameSheet = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.nameSheet === alert else { return }
            answer(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        alert.window.initialFirstResponder = field
        alert.window.makeFirstResponder(field)
    }

    private func requestRootName() {
        guard roots.isEmpty else { return }
        askName(.root, title: L("New Root Folder")) { [weak self] name in
            guard let self else { return }
            let id = try self.model.createRoot(named: name)
            try self.reload(selecting: id)
        }
    }

    @objc private func closeClicked() { close() }
    @objc private func addFolderClicked() {
        if roots.isEmpty { requestRootName(); return }
        guard let parent = selectedFolder?.id else { return }
        askName(.folder, title: L("New Folder")) { [weak self] name in
            guard let self else { return }
            let id = try self.model.addFolder(named: name, in: parent)
            try self.reload(selecting: id)
        }
    }
    @objc private func addSkinClicked() {
        guard let parent = selectedFolder?.id else { return }
        let template = chosenTemplate
        askName(.skin, title: L("New Skin")) { [weak self] name in
            guard let self else { return }
            let id = try self.model.addSkin(named: name, in: parent, template: template)
            try self.reload(selecting: id)
        }
    }
    @objc private func addResourcesClicked() {
        perform { let id = try model.addResources(); try reload(selecting: id) }
    }
    @objc private func templateChosen(_ sender: Any) {
        guard available else { return }
        let item = sender as? NSMenuItem ?? templatePopup.selectedItem
        guard let template = item?.representedObject as? NewSkinModel.TemplateID else { return }
        chosenTemplate = template
        updateTemplateMenu()
    }
    @objc private func saveTemplateClicked() {
        let name = templateNameField.stringValue
        perform {
            let saved = try model.saveTemplate(named: name, from: chosenTemplate)
            chosenTemplate = saved
            templateNameField.stringValue = ""
            if case .named(let name) = saved { try reload(template: name) }
        }
    }
    @objc private func editTemplateClicked() {
        guard let name = selectedNamedTemplate else { return }
        perform { CodeEditorRouter.open(file: try model.templateURL(.named(name)), app: app, loadUnloadedSkin: false) }
    }
    @objc private func deleteTemplateClicked() {
        guard let name = selectedNamedTemplate else { return }
        perform {
            let url = try model.templateURL(.named(name))
            guard closeEditors(url, directory: false), !finished, !app.isTerminating else { return }
            try model.deleteTemplate(.named(name))
            try reload()
        }
    }
    private func closeEditors(_ url: URL, directory: Bool) -> Bool {
        if let preflightForTesting { return preflightForTesting(url, directory) }
        return NewSkinEditorPreflight.closeEditors(affectedBy: url, isDirectory: directory, app: app)
    }
    @objc private func editSelectedSkin() { if let id = selectedID { editSkin(id) } }
    private func editSkin(_ id: UUID) {
        guard let item = model.item(id: id), item.kind == .skin else { return }
        perform { CodeEditorRouter.open(file: item.url, app: app, loadUnloadedSkin: false) }
    }
    private func rename(_ id: UUID) {
        guard let item = model.item(id: id), model.canRenameOrDelete(item: id) else { return }
        let url = item.url, directory = item.kind == .folder
        askName(.rename, title: L("Rename"), initial: url.lastPathComponent) { [weak self] name in
            guard let self, self.model.canRenameOrDelete(item: id) else { return }
            guard self.closeEditors(url, directory: directory), !self.finished, !self.app.isTerminating else { return }
            try self.model.rename(item: id, to: name)
            try self.reload(selecting: id)
        }
    }
    private func delete(_ id: UUID) {
        guard let item = model.item(id: id), model.canRenameOrDelete(item: id) else { return }
        let url = item.url, directory = item.kind == .folder
        perform {
            guard closeEditors(url, directory: directory), !finished, !app.isTerminating else { return }
            try model.delete(item: id)
            try reload()
        }
    }

    func controlTextDidChange(_ notification: Notification) { updateControls() }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard available else { return }
        perform { try reload() }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? NewSkinModel.Item)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? NewSkinModel.Item)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? NewSkinModel.Item)?.kind == .folder
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NewSkinModel.Item else { return nil }
        let field = NSTextField(labelWithString: item.url.lastPathComponent)
        field.lineBreakMode = .byTruncatingMiddle
        if roots.first === item { field.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return field
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectedID = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? NewSkinModel.Item)?.id : nil
        updateControls()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { templateNames.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard templateNames.indices.contains(row) else { return nil }
        return NSTextField(labelWithString: templateNames[row])
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === itemMenu else { return }
        menu.removeAllItems()
        let clicked = outline.clickedRow >= 0 ? (outline.item(atRow: outline.clickedRow) as? NewSkinModel.Item)?.id : nil
        guard available, let id = contextIDForTesting ?? clicked,
              let item = model.item(id: id) else { return }
        if item.kind == .skin { addContext(L("Edit skin"), #selector(contextEdit(_:)), id, to: menu) }
        if model.canRenameOrDelete(item: id) {
            addContext(L("Rename"), #selector(contextRename(_:)), id, to: menu)
            addContext(L("Delete"), #selector(contextDelete(_:)), id, to: menu)
        }
    }
    private func addContext(_ title: String, _ selector: Selector, _ id: UUID, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        menu.addItem(item)
    }
    @objc private func contextEdit(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { editSkin(id) } }
    @objc private func contextRename(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { rename(id) } }
    @objc private func contextDelete(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { delete(id) } }

    // MARK: Self-tests
    var testItems: [NewSkinModel.Item] { allItems(roots) }
    var testSelectedID: UUID? { selectedID }
    var testTabs: NSTabView { tabs }
    var testPath: String { pathField.stringValue }
    var testFolderButton: NSButton { addFolderButton }
    var testSkinButton: NSButton { addSkinButton }
    var testResourcesButton: NSButton { resourcesButton }
    var testTemplatePopup: NSPopUpButton { templatePopup }
    var testTemplateName: NSTextField { templateNameField }
    var testSaveTemplateButton: NSButton { saveTemplateButton }
    var testEditTemplateButton: NSButton { editTemplateButton }
    var testDeleteTemplateButton: NSButton { deleteTemplateButton }
    var testTemplateNames: [String] { templateNames }
    func testRequestRootName() { requestRootName() }
    func testSelect(_ id: UUID) {
        guard let item = model.item(id: id) else { return }
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
    }
    func testSelectTemplate(_ name: String) {
        if let row = templateNames.firstIndex(of: name) {
            templateTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
    func testChooseTemplate(_ title: String) {
        if let item = templatePopup.menu?.items.first(where: { $0.title == title }) { templateChosen(item) }
    }
    func testContextTitles(_ id: UUID) -> [String] {
        contextIDForTesting = id
        defer { contextIDForTesting = nil }
        menuNeedsUpdate(itemMenu)
        return itemMenu.items.map(\.title)
    }
    func testRename(_ id: UUID) { rename(id) }
    func testDelete(_ id: UUID) { delete(id) }
    func testEdit(_ id: UUID) { editSkin(id) }
}
