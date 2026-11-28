import AppKit
import DesksetCore
import SwiftUI

/// Observable state bridging `NewSkinWindowController` and `NewSkinRootView`.
final class NewSkinViewModel: ObservableObject {
    enum Section: Int, CaseIterable {
        case skin = 0
        case template = 1

        var title: String {
            switch self {
            case .skin: return L("New skin")
            case .template: return L("Template")
            }
        }

        var symbol: String {
            switch self {
            case .skin: return "folder.fill"
            case .template: return "doc.text.fill"
            }
        }

        var tint: Color {
            switch self {
            case .skin: return DeskProPalette.discoverBlue
            case .template: return DeskProPalette.indigoTint
            }
        }
    }

    struct TreeRow: Identifiable {
        let id: UUID
        let name: String
        let kind: NewSkinModel.Kind
        let depth: Int
        let isRoot: Bool
        let isResources: Bool
        let hasChildren: Bool
        let isExpanded: Bool
        let canMutate: Bool
    }

    struct TemplateChoiceItem: Identifiable {
        let id: String
        let title: String
        let template: NewSkinModel.TemplateID
    }

    struct PromptState: Identifiable {
        let id: UUID
        let kind: NewSkinWindowController.NameKind
        let title: String
        var text: String

        var confirmTitle: String {
            kind == .rename ? L("Rename") : L("Create")
        }

        var symbol: String {
            switch kind {
            case .root, .folder: return "folder.badge.plus"
            case .skin: return "doc.badge.plus"
            case .rename: return "pencil"
            }
        }

        var tint: Color {
            switch kind {
            case .root, .folder: return DeskProPalette.discoverBlue
            case .skin: return DeskProPalette.indigoTint
            case .rename: return DeskProPalette.signalOrange
            }
        }
    }

    @Published var section: Section = .skin
    @Published var fullPath: String = ""
    @Published var displayPath: String = ""
    @Published var rows: [TreeRow] = []
    @Published var selectedID: UUID? = nil
    @Published var expandedIDs: Set<UUID> = []

    @Published var canAddFolder: Bool = false
    @Published var canAddResources: Bool = false
    @Published var canAddSkin: Bool = false
    @Published var isAvailable: Bool = true

    @Published var templateChoices: [TemplateChoiceItem] = []
    @Published var chosenTemplate: NewSkinModel.TemplateID = .standard
    @Published var chosenTemplateTitle: String = ""

    @Published var templateDraftName: String = ""
    @Published var canSaveTemplate: Bool = false
    @Published var templateNames: [String] = []
    @Published var selectedTemplateName: String? = nil
    @Published var canMutateSelectedTemplate: Bool = false

    @Published var activePrompt: PromptState? = nil
}

/// Creates skin files within one folder and manages the templates used for new files,
/// styled with Deskset's full-height sidebar, grouped cards, and inline naming sheet.
final class NewSkinWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate, NSTabViewDelegate,
    NSTextFieldDelegate {
    enum NameKind: Equatable { case root, folder, skin, rename }
    struct NameRequest {
        let kind: NameKind
        let title: String
        let initialValue: String
    }

    static let defaultSize = NSSize(width: 760, height: 540)
    static let minimumSize = NSSize(width: 660, height: 460)

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
    let viewModel = NewSkinViewModel()
    private var hostingView: NSHostingView<NewSkinRootView>?

    private var roots: [NewSkinModel.Item] = []
    private var templateNames: [String] = []
    private var chosenTemplate = NewSkinModel.TemplateID.standard
    private var selectedID: UUID?
    private var selectedNamedTemplateStorage: String?
    private var busy = false
    private var finished = false
    private var nameRequestID: UUID?
    private var promptAnswerHandler: ((String?) -> Void)?

    // Backing controls preserved for programmatic self-test hooks.
    private let tabs = NSTabView()
    private let pathField = NSTextField(string: "")
    private let itemMenu = NSMenu()
    private let addFolderButton = NSButton(title: L("Add Folder"), target: nil, action: nil)
    private let resourcesButton = NSButton(title: "@Resources", target: nil, action: nil)
    private let addSkinButton = NSButton(title: L("Add skin"), target: nil, action: nil)
    private let templatePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let templateNameField = NSTextField()
    private let saveTemplateButton = NSButton(title: L("Save"), target: nil, action: nil)
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
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        DeskProWindowStyle.apply(to: window)
        window.title = L("Create new skin")
        window.minSize = Self.minimumSize
        window.backgroundColor = .windowBackgroundColor
        window.center()
        super.init(window: window)
        window.delegate = self
        AppTheme.register(window, app: app)

        configureBackingControls()
        try reload()

        let rootView = NewSkinRootView(model: viewModel, controller: self)
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: Self.defaultSize)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        hostingView = host
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
        promptAnswerHandler = nil
        viewModel.activePrompt = nil
        if Self.currentController === self { Self.currentController = nil }
        guard !app.isTerminating else { return }
        if let refreshForTesting { refreshForTesting() }
        else { app.refreshAll(rescan: true) }
    }

    private var available: Bool { !finished && !busy && !app.isTerminating }

    private func configureBackingControls() {
        tabs.delegate = self
        for (identifier, title) in [("skin", L("New skin")), ("template", L("Template"))] {
            let tab = NSTabViewItem(identifier: identifier)
            tab.label = title
            tabs.addTabViewItem(tab)
        }
        pathField.isEditable = false
        pathField.isSelectable = true
        pathField.setAccessibilityLabel(L("Selected skin folder"))

        itemMenu.delegate = self
        itemMenu.autoenablesItems = false

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

        templateNameField.delegate = self
        templateNameField.target = self
        templateNameField.action = #selector(saveTemplateClicked)
        templateNameField.setAccessibilityLabel(L("Template name"))

        saveTemplateButton.target = self
        saveTemplateButton.action = #selector(saveTemplateClicked)
        editTemplateButton.target = self
        editTemplateButton.action = #selector(editTemplateClicked)
        deleteTemplateButton.target = self
        deleteTemplateButton.action = #selector(deleteTemplateClicked)
    }

    private func allItems(_ items: [NewSkinModel.Item]) -> [NewSkinModel.Item] {
        items.flatMap { [$0] + allItems($0.children) }
    }

    private func reload(selecting id: UUID? = nil, template: String? = nil) throws {
        let wantedTemplate = template ?? selectedNamedTemplateStorage
        let selectedItemID = id ?? selectedID
        roots = try model.reload()
        templateNames = try model.templates()
        if case .named(let name) = chosenTemplate, !templateNames.contains(name) {
            chosenTemplate = .standard
        }

        // Expand newly discovered folders automatically so new items are visible immediately.
        let allFolderIDs = Set(allItems(roots).filter { $0.kind == .folder }.map(\.id))
        if viewModel.expandedIDs.isEmpty {
            viewModel.expandedIDs = allFolderIDs
        } else {
            viewModel.expandedIDs.formUnion(allFolderIDs)
        }

        if let candidate = selectedItemID, model.item(id: candidate) != nil {
            selectedID = candidate
        } else {
            selectedID = roots.first?.id
        }

        if let wantedTemplate, templateNames.contains(wantedTemplate) {
            selectedNamedTemplateStorage = wantedTemplate
        } else {
            selectedNamedTemplateStorage = nil
        }

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
        guard let name = selectedNamedTemplateStorage, templateNames.contains(name) else { return nil }
        return name
    }

    private func updateTemplateMenu() {
        templatePopup.removeAllItems()
        templatePopup.addItem(withTitle: L("Template…"))
        var choices: [NewSkinViewModel.TemplateChoiceItem] = []
        for (title, template) in [(L("Use default template"), NewSkinModel.TemplateID.standard)]
            + templateNames.map({ ($0, NewSkinModel.TemplateID.named($0)) }) {
            let item = NSMenuItem(title: title, action: #selector(templateChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template
            item.state = template == chosenTemplate ? .on : .off
            templatePopup.menu?.addItem(item)
            let key: String = {
                switch template {
                case .standard: return "__default__"
                case .named(let n): return "named:\(n)"
                }
            }()
            choices.append(.init(id: key, title: title, template: template))
        }
        viewModel.templateChoices = choices
        viewModel.chosenTemplate = chosenTemplate
        switch chosenTemplate {
        case .standard:
            viewModel.chosenTemplateTitle = L("Use default template")
        case .named(let name):
            viewModel.chosenTemplateTitle = name
        }
    }

    private func buildVisibleRows() -> [NewSkinViewModel.TreeRow] {
        var result: [NewSkinViewModel.TreeRow] = []
        func walk(_ items: [NewSkinModel.Item], depth: Int) {
            for item in items {
                let isRoot = depth == 0 && roots.first === item
                let isExpanded = viewModel.expandedIDs.contains(item.id)
                let isResources = item.kind == .folder
                    && item.url.lastPathComponent.caseInsensitiveCompare("@Resources") == .orderedSame
                result.append(NewSkinViewModel.TreeRow(
                    id: item.id,
                    name: item.url.lastPathComponent,
                    kind: item.kind,
                    depth: depth,
                    isRoot: isRoot,
                    isResources: isResources,
                    hasChildren: !item.children.isEmpty,
                    isExpanded: isExpanded,
                    canMutate: model.canRenameOrDelete(item: item.id)
                ))
                if item.kind == .folder && isExpanded {
                    walk(item.children, depth: depth + 1)
                }
            }
        }
        walk(roots, depth: 0)
        return result
    }

    private func updateControls() {
        let parent = selectedFolder
        let full = (parent?.url ?? roots.first?.url)?.path ?? app.skinsDirectory.path
        pathField.stringValue = full
        pathField.toolTip = full

        addFolderButton.isEnabled = available && (parent != nil || roots.isEmpty)
        addSkinButton.isEnabled = available && parent != nil
        resourcesButton.isEnabled = available && model.canAddResources
        templatePopup.isEnabled = available
        templateNameField.isEnabled = available

        let draft = templateNameField.stringValue
        saveTemplateButton.isEnabled = available && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        editTemplateButton.isEnabled = available && selectedNamedTemplate != nil
        deleteTemplateButton.isEnabled = available && selectedNamedTemplate != nil

        viewModel.fullPath = full
        viewModel.displayPath = (full as NSString).abbreviatingWithTildeInPath
        viewModel.selectedID = selectedID
        viewModel.rows = buildVisibleRows()
        viewModel.isAvailable = available
        viewModel.canAddFolder = addFolderButton.isEnabled
        viewModel.canAddResources = resourcesButton.isEnabled
        viewModel.canAddSkin = addSkinButton.isEnabled

        if viewModel.templateDraftName != draft {
            viewModel.templateDraftName = draft
        }
        viewModel.canSaveTemplate = saveTemplateButton.isEnabled
        viewModel.templateNames = templateNames
        viewModel.selectedTemplateName = selectedNamedTemplate
        viewModel.canMutateSelectedTemplate = editTemplateButton.isEnabled
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
            self.promptAnswerHandler = nil
            self.viewModel.activePrompt = nil
            self.busy = false
            self.updateControls()
            guard let name else { return }
            self.perform { try action(name) }
        }
        if let namePromptForTesting { namePromptForTesting(request, answer); return }
        guard app.presentsWindows else { answer(nil); return }
        promptAnswerHandler = answer
        viewModel.activePrompt = .init(id: id, kind: kind, title: title, text: initial)
    }

    func completePromptFromUI(_ submittedName: String?) {
        promptAnswerHandler?(submittedName)
    }

    private func requestRootName() {
        guard roots.isEmpty else { return }
        askName(.root, title: L("New Root Folder")) { [weak self] name in
            guard let self else { return }
            let id = try self.model.createRoot(named: name)
            try self.reload(selecting: id)
        }
    }

    // MARK: - UI Actions

    func selectSectionFromUI(_ section: NewSkinViewModel.Section) {
        guard available else { return }
        viewModel.section = section
        tabs.selectTabViewItem(at: section.rawValue)
    }

    func selectItemFromUI(_ id: UUID) {
        guard model.item(id: id) != nil else { return }
        selectedID = id
        updateControls()
    }

    func toggleExpandedFromUI(_ id: UUID) {
        if viewModel.expandedIDs.contains(id) {
            viewModel.expandedIDs.remove(id)
        } else {
            viewModel.expandedIDs.insert(id)
        }
        viewModel.rows = buildVisibleRows()
    }

    func chooseTemplateFromUI(_ template: NewSkinModel.TemplateID) {
        guard available else { return }
        chosenTemplate = template
        updateTemplateMenu()
    }

    func setTemplateDraftFromUI(_ text: String) {
        templateNameField.stringValue = text
        updateControls()
    }

    func selectSavedTemplateFromUI(_ name: String?) {
        selectedNamedTemplateStorage = name
        updateControls()
    }

    func editNamedTemplateFromUI(_ name: String) {
        selectedNamedTemplateStorage = name
        updateControls()
        editTemplateClicked()
    }

    func deleteNamedTemplateFromUI(_ name: String) {
        selectedNamedTemplateStorage = name
        updateControls()
        deleteTemplateClicked()
    }

    @objc func closeClicked() { close() }

    @objc func addFolderClicked() {
        if roots.isEmpty { requestRootName(); return }
        guard let parent = selectedFolder?.id else { return }
        askName(.folder, title: L("New Folder")) { [weak self] name in
            guard let self else { return }
            let id = try self.model.addFolder(named: name, in: parent)
            try self.reload(selecting: id)
        }
    }

    @objc func addSkinClicked() {
        guard let parent = selectedFolder?.id else { return }
        let template = chosenTemplate
        askName(.skin, title: L("New Skin")) { [weak self] name in
            guard let self else { return }
            let id = try self.model.addSkin(named: name, in: parent, template: template)
            try self.reload(selecting: id)
        }
    }

    @objc func addResourcesClicked() {
        perform { let id = try model.addResources(); try reload(selecting: id) }
    }

    @objc private func templateChosen(_ sender: Any) {
        guard available else { return }
        let item = sender as? NSMenuItem ?? templatePopup.selectedItem
        guard let template = item?.representedObject as? NewSkinModel.TemplateID else { return }
        chosenTemplate = template
        updateTemplateMenu()
    }

    @objc func saveTemplateClicked() {
        let name = templateNameField.stringValue
        perform {
            let saved = try model.saveTemplate(named: name, from: chosenTemplate)
            chosenTemplate = saved
            templateNameField.stringValue = ""
            viewModel.templateDraftName = ""
            if case .named(let name) = saved { try reload(template: name) }
        }
    }

    @objc func editTemplateClicked() {
        guard let name = selectedNamedTemplate else { return }
        perform { CodeEditorRouter.open(file: try model.templateURL(.named(name)), app: app, loadUnloadedSkin: false) }
    }

    @objc func deleteTemplateClicked() {
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

    func editSkinFromUI(_ id: UUID) { editSkin(id) }
    func renameItemFromUI(_ id: UUID) { rename(id) }
    func deleteItemFromUI(_ id: UUID) { delete(id) }

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
        let index = tabViewItem.map { tabView.indexOfTabViewItem($0) } ?? 0
        viewModel.section = NewSkinViewModel.Section(rawValue: index) ?? .skin
        guard available else { return }
        perform { try reload() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === itemMenu else { return }
        menu.removeAllItems()
        guard available, let id = contextIDForTesting ?? selectedID,
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

    // MARK: - Snapshot & Self-tests

    func snapshot() -> NSBitmapImageRep? {
        guard let view = window?.contentView else { return nil }
        updateControls()
        view.layoutSubtreeIfNeeded()
        hostingView?.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int(bounds.width * 2),
                  pixelsHigh: Int(bounds.height * 2),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    func showRootPromptForSnapshot() {
        viewModel.activePrompt = .init(id: UUID(), kind: .root, title: L("New Root Folder"), text: "")
    }

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
    func testSelect(_ id: UUID) { selectItemFromUI(id) }
    func testSelectTemplate(_ name: String) { selectSavedTemplateFromUI(name) }
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

// MARK: - SwiftUI Root View

struct NewSkinRootView: View {
    @ObservedObject var model: NewSkinViewModel
    weak var controller: NewSkinWindowController?

    private static let topHeight: CGFloat = 56
    @FocusState private var promptFocused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detailPane
            }
            .disabled(model.activePrompt != nil)

            if let prompt = model.activePrompt {
                promptOverlay(prompt)
            }
        }
        .font(.system(size: 13))
        .frame(minWidth: NewSkinWindowController.minimumSize.width,
               minHeight: NewSkinWindowController.minimumSize.height)
        .background(DeskProPalette.page)
        .ignoresSafeArea()
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                DeskAppMark(size: 28)
                    .frame(width: 28)
                Text(L("Create new skin"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .padding(.top, 26)
            .frame(maxWidth: .infinity, minHeight: Self.topHeight + 26, maxHeight: Self.topHeight + 26, alignment: .leading)
            .background(WindowDragArea())

            ForEach(NewSkinViewModel.Section.allCases, id: \.rawValue) { item in
                let selected = model.section == item
                Button {
                    controller?.selectSectionFromUI(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(item.tint)
                            )
                        Text(item.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? .white : .primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            Divider()
                .padding(.horizontal, 6)
                .padding(.bottom, 6)

            Button {
                controller?.closeClicked()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    Text(L("Close"))
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .background(DeskProPalette.utilitySidebar)
    }

    // MARK: - Detail Area

    private var detailPane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.section.title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 28)
            .frame(height: Self.topHeight)
            .background(WindowDragArea())

            switch model.section {
            case .skin:
                skinSectionView
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .template:
                ScrollView {
                    templateSectionView
                        .padding(.horizontal, 28)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 1. New Skin Section

    private var skinSectionView: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup {
                DeskProSettingsRow(
                    title: L("Selected skin folder"),
                    detail: model.displayPath,
                    symbol: "folder.fill",
                    symbolTint: DeskProPalette.discoverBlue
                ) {
                    HStack(spacing: 6) {
                        Text(L("Template"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Picker("", selection: Binding(
                            get: { model.chosenTemplate },
                            set: { controller?.chooseTemplateFromUI($0) }
                        )) {
                            ForEach(model.templateChoices) { choice in
                                Text(choice.title).tag(choice.template)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!model.isAvailable)
                    }
                }
                .help(model.fullPath)

                HStack(spacing: 8) {
                    Button {
                        controller?.addFolderClicked()
                    } label: {
                        Label(L("Add Folder"), systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.canAddFolder)

                    Button {
                        controller?.addResourcesClicked()
                    } label: {
                        Label("@Resources", systemImage: "shippingbox")
                    }
                    .disabled(!model.canAddResources)

                    Spacer()

                    Button {
                        controller?.addSkinClicked()
                    } label: {
                        Label(L("Add skin"), systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAddSkin)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("New skin folders and files"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)

                Group {
                    if model.rows.isEmpty {
                        emptyTreeState
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(model.rows) { row in
                                    treeRowView(row)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DeskProPalette.box))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
        }
    }

    private var emptyTreeState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(DeskProPalette.discoverBlue)
                .frame(width: 52, height: 52)
                .background(Circle().fill(DeskProPalette.discoverBlue.opacity(0.12)))

            Text(L("No root folder yet."))
                .font(.system(size: 14, weight: .semibold))

            Text(L("Create a root folder in Skins to start adding subfolders and skin files."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button {
                controller?.addFolderClicked()
            } label: {
                Label(L("New Root Folder"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            .disabled(!model.canAddFolder)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func treeRowView(_ row: NewSkinViewModel.TreeRow) -> some View {
        let selected = model.selectedID == row.id
        let rowIcon: String = {
            if row.kind == .skin { return "doc.text.fill" }
            if row.isResources { return "shippingbox.fill" }
            return "folder.fill"
        }()
        let iconTint: Color = {
            if selected { return .white }
            if row.kind == .skin { return DeskProPalette.indigoTint }
            if row.isResources { return DeskProPalette.signalOrange }
            return DeskProPalette.discoverBlue
        }()

        return HStack(spacing: 8) {
            if row.kind == .folder && row.hasChildren {
                Button {
                    controller?.toggleExpandedFromUI(row.id)
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(selected ? .white.opacity(0.9) : .secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }

            Image(systemName: rowIcon)
                .font(.system(size: 13))
                .foregroundColor(iconTint)

            Text(row.name)
                .font(.system(size: 13, weight: row.isRoot ? .semibold : .regular))
                .foregroundColor(selected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if selected && model.isAvailable {
                HStack(spacing: 6) {
                    if row.kind == .skin {
                        Button(L("Edit")) {
                            controller?.editSkinFromUI(row.id)
                        }
                        .controlSize(.small)
                    }
                    if row.canMutate {
                        Button(L("Rename")) {
                            controller?.renameItemFromUI(row.id)
                        }
                        .controlSize(.small)

                        Button(L("Delete")) {
                            controller?.deleteItemFromUI(row.id)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 18)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            controller?.selectItemFromUI(row.id)
            if row.kind == .skin {
                controller?.editSkinFromUI(row.id)
            } else if row.hasChildren {
                controller?.toggleExpandedFromUI(row.id)
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                controller?.selectItemFromUI(row.id)
            }
        )
        .contextMenu {
            if row.kind == .skin {
                Button(L("Edit skin")) {
                    controller?.editSkinFromUI(row.id)
                }
            }
            if row.canMutate {
                Button(L("Rename")) {
                    controller?.renameItemFromUI(row.id)
                }
                Button(L("Delete")) {
                    controller?.deleteItemFromUI(row.id)
                }
            }
        }
    }

    // MARK: - 2. Template Section

    private var templateSectionView: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup(title: L("Save new template")) {
                DeskProSettingsRow(title: L("Name:"), divider: false) {
                    HStack(spacing: 8) {
                        TextField(
                            L("Template name"),
                            text: Binding(
                                get: { model.templateDraftName },
                                set: { controller?.setTemplateDraftFromUI($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(!model.isAvailable)
                        .onSubmit {
                            if model.canSaveTemplate {
                                controller?.saveTemplateClicked()
                            }
                        }

                        Button(L("Save")) {
                            controller?.saveTemplateClicked()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSaveTemplate)
                    }
                }
            }

            DeskProSettingsGroup(title: L("Saved templates")) {
                if model.templateNames.isEmpty {
                    DeskProSettingsRow(title: L("No saved templates."), divider: false) {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(model.templateNames.enumerated()), id: \.element) { idx, name in
                        let selected = model.selectedTemplateName == name
                        DeskProSettingsRow(
                            title: name,
                            symbol: "doc.text.fill",
                            symbolTint: selected ? .accentColor : DeskProPalette.indigoTint,
                            divider: idx < model.templateNames.count - 1
                        ) {
                            HStack(spacing: 8) {
                                Button(L("Edit")) {
                                    controller?.editNamedTemplateFromUI(name)
                                }
                                .controlSize(.small)
                                .disabled(!model.isAvailable)

                                Button(L("Delete")) {
                                    controller?.deleteNamedTemplateFromUI(name)
                                }
                                .controlSize(.small)
                                .disabled(!model.isAvailable)
                            }
                        }
                        .background(selected ? Color.accentColor.opacity(0.07) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller?.selectSavedTemplateFromUI(name)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Naming Modal Card

    private func promptOverlay(_ prompt: NewSkinViewModel.PromptState) -> some View {
        let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: prompt.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(prompt.tint)
                        )

                    Text(prompt.title)
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()
                }

                TextField(
                    L("Name"),
                    text: Binding(
                        get: { model.activePrompt?.text ?? "" },
                        set: { model.activePrompt?.text = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .focused($promptFocused)
                .onSubmit {
                    guard !trimmed.isEmpty else { return }
                    controller?.completePromptFromUI(prompt.text)
                }

                HStack(spacing: 8) {
                    Spacer()

                    Button(L("Cancel")) {
                        controller?.completePromptFromUI(nil)
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(prompt.confirmTitle) {
                        controller?.completePromptFromUI(prompt.text)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DeskProPalette.box)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .onAppear {
                DispatchQueue.main.async {
                    promptFocused = true
                }
            }
        }
    }
}
