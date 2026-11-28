import AppKit
import DesksetCore
import SwiftUI
import UniformTypeIdentifiers

/// The settings of recently made packages, newest first, for "Load previous" (manual: "This restores the settings used
/// when the skin was last packaged, including its name, author, layouts, plugins, header image, and output folder").
/// One entry per package name; kept in the app's preferences (self-tests keep it in memory).
struct SkinPackagerHistory {
    /// Where the entries are kept: the app's preferences, or memory.
    final class Storage {
        static let standard = Storage(defaults: .standard)
        private let defaults: UserDefaults?
        private var memory: Data?

        init(defaults: UserDefaults? = nil) { self.defaults = defaults }

        var data: Data? {
            get { defaults.map { $0.data(forKey: SkinPackagerHistory.key) } ?? memory }
            set { if let defaults { defaults.set(newValue, forKey: SkinPackagerHistory.key) } else { memory = newValue } }
        }
    }

    static let key = "SkinPackagerHistory"
    static let limit = 20
    let storage: Storage

    var entries: [RmskinPackageSpec] {
        guard let data = storage.data,
              let entries = try? JSONDecoder().decode([RmskinPackageSpec].self, from: data) else { return [] }
        return entries
    }

    func remember(_ spec: RmskinPackageSpec) {
        var list = entries.filter { $0.name.caseInsensitiveCompare(spec.name) != .orderedSame }
        list.insert(spec, at: 0)
        save(Array(list.prefix(SkinPackagerHistory.limit)))
    }

    func forget(at index: Int) {
        var list = entries
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        save(list)
    }

    private func save(_ list: [RmskinPackageSpec]) {
        storage.data = try? JSONEncoder().encode(list)
    }
}

/// Observable state bridging `SkinPackagerWindowController` and `SkinPackagerRootView`.
final class SkinPackagerViewModel: ObservableObject {
    enum Section: String, CaseIterable {
        case info
        case options
        case advanced

        var title: String {
            switch self {
            case .info: return L("Information and Components")
            case .options: return L("Options")
            case .advanced: return L("Advanced")
            }
        }

        var symbol: String {
            switch self {
            case .info: return "shippingbox.fill"
            case .options: return "slider.horizontal.3"
            case .advanced: return "gearshape.2.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: return DeskProPalette.discoverBlue
            case .options: return DeskProPalette.indigoTint
            case .advanced: return DeskProPalette.privacyGreen
            }
        }
    }

    struct LayoutItem: Identifiable {
        let id: Int
        let name: String
        let path: String
    }

    struct PluginItem: Identifiable {
        let id: Int
        let description: String
        let toolTip: String?
    }

    struct HistoryItem: Identifiable {
        let id: Int
        let title: String
    }

    @Published var section: Section = .info
    @Published var step: Int = 1
    @Published var busy: Bool = false

    // Step 1
    @Published var name: String = ""
    @Published var author: String = ""
    @Published var version: String = ""
    @Published var skinDisplayText: String = ""
    @Published var skinFullPath: String? = nil
    @Published var hasSkin: Bool = false
    @Published var layouts: [LayoutItem] = []
    @Published var savedLayoutNames: [String] = []
    @Published var plugins: [PluginItem] = []

    // Step 2 - Options
    @Published var outputDisplayText: String = ""
    @Published var outputFullPath: String? = nil
    @Published var loadKindIndex: Int = 0
    @Published var canChooseLoadLayout: Bool = false
    @Published var loadChoices: [String] = []
    @Published var selectedLoadChoice: String = ""
    @Published var minimumDeskset: String = RmskinPackager.defaultMinimumDeskset

    // Step 2 - Advanced
    @Published var headerDisplayText: String = ""
    @Published var headerFullPath: String? = nil
    @Published var hasHeader: Bool = false
    @Published var variablesText: String = ""
    @Published var variablesEnabled: Bool = true
    @Published var mergeSkins: Bool = false
    @Published var mergeEnabled: Bool = true

    // History
    @Published var historyItems: [HistoryItem] = []
}

/// Skin Packager (manual: "To launch the Skin Packager, open the Manage window and click the button labeled Create
/// .rmskin package..."): step 1 asks for the information and components, step 2 for the options and, on its Advanced
/// section, the header image, variables files and Merge skins. `RmskinPackager` checks and writes the package.
final class SkinPackagerWindowController: NSWindowController, NSWindowDelegate {
    enum Choice: Equatable { case skin, layoutFolder, plugin, output, header }

    static let defaultSize = NSSize(width: 780, height: 550)
    static let minimumSize = NSSize(width: 680, height: 470)

    private static var current: SkinPackagerWindowController?
    /// Where "Load previous" is kept (self-tests and snapshots use memory).
    static var historyStorage = SkinPackagerHistory.Storage.standard

    static func window(for app: AppController) -> SkinPackagerWindowController? {
        guard let current, current.app === app, current.window?.isVisible == true || !app.presentsWindows else {
            return nil
        }
        return current
    }

    /// Opens the packager; `rootConfig` (the skin selected in Manage) starts step 1 with that skin.
    @discardableResult
    static func show(app: AppController, rootConfig: URL? = nil) -> SkinPackagerWindowController? {
        guard !app.isTerminating else { return nil }
        if let existing = window(for: app) {
            app.bringToFront(existing)
            return existing
        }
        let controller = SkinPackagerWindowController(app: app)
        current = controller
        if let rootConfig { controller.setSkin(rootConfig) }
        app.bringToFront(controller)
        return controller
    }

    private unowned let app: AppController
    let viewModel = SkinPackagerViewModel()
    private var hostingView: NSHostingView<SkinPackagerRootView>?

    private(set) var spec = RmskinPackageSpec()
    private(set) var step = 1
    private var advancedSelected = false
    private(set) var busy = false
    private var syncing = false
    var history: SkinPackagerHistory { SkinPackagerHistory(storage: SkinPackagerWindowController.historyStorage) }

    /// Tests answer the open panels, the confirmation and the messages, and build on the main thread.
    var chooseForTesting: ((Choice) -> URL?)?
    var confirmReplaceForTesting: ((URL) -> Bool)?
    var messageForTesting: ((String, String) -> Void)?
    private(set) var lastMessage: (title: String, text: String)?

    init(app: AppController) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        DeskProWindowStyle.apply(to: window)
        window.title = L("Create .rmskin Package")
        window.minSize = Self.minimumSize
        window.backgroundColor = .windowBackgroundColor
        window.center()
        super.init(window: window)
        window.delegate = self
        AppTheme.register(window, app: app)

        spec.minimumDeskset = RmskinPackager.defaultMinimumDeskset
        spec.outputDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        refresh()

        let rootView = SkinPackagerRootView(model: viewModel, controller: self)
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: Self.defaultSize)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        hostingView = host
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if SkinPackagerWindowController.current === self { SkinPackagerWindowController.current = nil }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        syncMenus()
    }

    // MARK: - State ↔ ViewModel

    func syncMenus() {
        viewModel.savedLayoutNames = (try? app.layoutStore.list()) ?? []
        viewModel.historyItems = history.entries.enumerated().map { idx, entry in
            let title = entry.version.isEmpty ? entry.name : "\(entry.name) \(entry.version)"
            return .init(id: idx, title: title)
        }
    }

    /// Shows `spec` and the step; also after every change.
    func refresh() {
        syncing = true
        defer { syncing = false }

        viewModel.step = step
        viewModel.section = step == 1 ? .info : (advancedSelected ? .advanced : .options)
        viewModel.busy = busy

        if viewModel.name != spec.name { viewModel.name = spec.name }
        if viewModel.author != spec.author { viewModel.author = spec.author }
        if viewModel.version != spec.version { viewModel.version = spec.version }
        let effectiveMinimumDeskset = spec.minimumDeskset ?? RmskinPackager.defaultMinimumDeskset
        if viewModel.minimumDeskset != effectiveMinimumDeskset { viewModel.minimumDeskset = effectiveMinimumDeskset }

        let joinedVars = spec.variableFiles.joined(separator: " | ")
        if viewModel.variablesText != joinedVars { viewModel.variablesText = joinedVars }

        viewModel.hasSkin = spec.rootConfig != nil
        viewModel.skinFullPath = spec.rootConfig?.path
        viewModel.skinDisplayText = spec.rootConfig.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            ?? L("No skin chosen")

        viewModel.layouts = spec.layouts.enumerated().map { idx, url in
            .init(id: idx, name: url.lastPathComponent, path: url.path)
        }
        viewModel.plugins = spec.plugins.enumerated().map { idx, plugin in
            .init(id: idx, description: pluginDescription(plugin), toolTip: pluginToolTip(plugin))
        }

        viewModel.outputFullPath = spec.outputDirectory?.path
        viewModel.outputDisplayText = spec.outputDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""

        viewModel.hasHeader = spec.headerImage != nil
        viewModel.headerFullPath = spec.headerImage?.path
        viewModel.headerDisplayText = spec.headerImage?.lastPathComponent ?? L("None")

        viewModel.mergeSkins = spec.mergeSkins
        viewModel.mergeEnabled = spec.variableFiles.isEmpty
        viewModel.variablesEnabled = !spec.mergeSkins

        let choices = loadChoices()
        viewModel.loadChoices = choices
        viewModel.canChooseLoadLayout = !spec.layouts.isEmpty
        switch spec.load {
        case .none:
            viewModel.loadKindIndex = 0
            viewModel.selectedLoadChoice = ""
        case .skin(let path):
            viewModel.loadKindIndex = 1
            viewModel.selectedLoadChoice = choices.contains(path) ? path : (choices.first ?? "")
        case .layout(let path):
            viewModel.loadKindIndex = 2
            viewModel.selectedLoadChoice = choices.contains(path) ? path : (choices.first ?? "")
        }

        syncMenus()
    }

    func pluginDescription(_ plugin: RmskinPackageSpec.Plugin) -> String {
        let primaryPath = ((plugin.x64 ?? plugin.x86)?.path as NSString?)?.abbreviatingWithTildeInPath ?? plugin.fileName
        switch (plugin.x86 != nil, plugin.x64 != nil) {
        case (true, true): return L("%@ (32-bit and 64-bit)", primaryPath)
        case (true, false): return L("%@ (64-bit version missing)", primaryPath)
        default: return L("%@ (32-bit version missing)", primaryPath)
        }
    }

    func pluginToolTip(_ plugin: RmskinPackageSpec.Plugin) -> String? {
        var lines: [String] = []
        if let x86 = plugin.x86 { lines.append("32-bit: \(x86.path)") }
        if let x64 = plugin.x64 { lines.append("64-bit: \(x64.path)") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The skins of the package, or its layouts, for "After installation".
    private func loadChoices() -> [String] {
        switch spec.load {
        case .none: return []
        case .skin: return spec.rootConfig.map(RmskinPackager.skinFiles(inRootConfig:)) ?? []
        case .layout: return spec.layouts.map { $0.lastPathComponent }
        }
    }

    // MARK: - ViewModel → State

    private func readFields() {
        spec.name = viewModel.name
        spec.author = viewModel.author
        spec.version = viewModel.version
        spec.minimumDeskset = viewModel.minimumDeskset
        spec.variableFiles = viewModel.variablesText.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        spec.mergeSkins = viewModel.mergeSkins && spec.variableFiles.isEmpty
        if !viewModel.selectedLoadChoice.isEmpty {
            switch spec.load {
            case .skin: spec.load = .skin(viewModel.selectedLoadChoice)
            case .layout: spec.load = .layout(viewModel.selectedLoadChoice)
            case .none: break
            }
        }
    }

    func updateTextFieldsFromUI() {
        guard !syncing else { return }
        spec.name = viewModel.name
        spec.author = viewModel.author
        spec.version = viewModel.version
        spec.minimumDeskset = viewModel.minimumDeskset
        spec.variableFiles = viewModel.variablesText.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !spec.variableFiles.isEmpty && spec.mergeSkins {
            spec.mergeSkins = false
            viewModel.mergeSkins = false
        }
        viewModel.mergeEnabled = spec.variableFiles.isEmpty
        viewModel.variablesEnabled = !spec.mergeSkins
    }

    func setMergeSkinsFromUI(_ enabled: Bool) {
        readFields()
        spec.mergeSkins = enabled && spec.variableFiles.isEmpty
        refresh()
    }

    func selectLoadKindFromUI(_ index: Int) {
        readFields()
        switch index {
        case 1: spec.load = .skin(spec.rootConfig.flatMap { RmskinPackager.skinFiles(inRootConfig: $0).first } ?? "")
        case 2: spec.load = .layout(spec.layouts.first?.lastPathComponent ?? "")
        default: spec.load = .none
        }
        refresh()
    }

    func selectLoadItemFromUI(_ choice: String) {
        readFields()
        switch spec.load {
        case .skin: spec.load = .skin(choice)
        case .layout: spec.load = .layout(choice)
        case .none: break
        }
        refresh()
    }

    func selectSectionFromUI(_ target: SkinPackagerViewModel.Section) {
        guard !busy else { return }
        switch target {
        case .info:
            back()
        case .options:
            if step == 1 {
                advancedSelected = false
                next()
            } else {
                readFields()
                advancedSelected = false
                refresh()
            }
        case .advanced:
            if step == 1 {
                readFields()
                let first = RmskinPackager.problems(spec).filter(SkinPackagerWindowController.isStepOne)
                guard first.isEmpty else {
                    return message(L("The package can’t be created yet"), first.map(describe).joined(separator: "\n"))
                }
                step = 2
                advancedSelected = true
                refresh()
            } else {
                readFields()
                advancedSelected = true
                refresh()
            }
        }
    }

    /// Changes the settings as typing into the window would (self-tests).
    func edit(_ change: (inout RmskinPackageSpec) -> Void) {
        readFields()
        change(&spec)
        refresh()
    }

    /// Step 2 on its Options or Advanced tab, without step 1's checks (snapshots and self-tests).
    func showStepTwo(advanced: Bool) {
        readFields()
        step = 2
        advancedSelected = advanced
        refresh()
    }

    /// Uses `folder` as the root config; empty Name, Author and Version are filled from its first skin's [Metadata]
    /// (Name only from the folder).
    func setSkin(_ folder: URL) {
        readFields()
        spec.rootConfig = folder
        if spec.name.trimmingCharacters(in: .whitespaces).isEmpty { spec.name = folder.lastPathComponent }
        if let first = RmskinPackager.skinFiles(inRootConfig: folder).first {
            let file = first.split(separator: "\\").dropFirst().reduce(folder) { $0.appendingPathComponent(String($1)) }
            let metadata = (try? IniDocument.parse(TextDecoding.readFile(at: file)))?.section(named: "Metadata")
            if spec.author.trimmingCharacters(in: .whitespaces).isEmpty { spec.author = metadata?["Author"] ?? "" }
            if spec.version.trimmingCharacters(in: .whitespaces).isEmpty { spec.version = metadata?["Version"] ?? "" }
            if case .none = spec.load { spec.load = .skin(first) }
        }
        if case .skin(let path) = spec.load,
           !RmskinPackager.skinFiles(inRootConfig: folder).contains(path) {
            spec.load = .none
        }
        viewModel.name = spec.name
        viewModel.author = spec.author
        viewModel.version = spec.version
        refresh()
    }

    func addLayout(_ folder: URL) {
        readFields()
        if !spec.layouts.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
            spec.layouts.append(folder)
        }
        refresh()
    }

    func addPlugin(_ dll: URL) {
        readFields()
        let plugin = RmskinPackager.plugin(choosing: dll)
        if let index = spec.plugins.firstIndex(where: { $0.fileName.caseInsensitiveCompare(plugin.fileName) == .orderedSame }) {
            // Choosing the other version of a plugin already listed completes it.
            if spec.plugins[index].x86 == nil { spec.plugins[index].x86 = plugin.x86 }
            if spec.plugins[index].x64 == nil { spec.plugins[index].x64 = plugin.x64 }
        } else {
            spec.plugins.append(plugin)
        }
        refresh()
    }

    func removeLayoutFromUI(at index: Int) {
        readFields()
        guard spec.layouts.indices.contains(index) else { return }
        let name = spec.layouts.remove(at: index).lastPathComponent
        if case .layout(let loaded) = spec.load, loaded == name { spec.load = .none }
        refresh()
    }

    func removePluginFromUI(at index: Int) {
        readFields()
        if spec.plugins.indices.contains(index) { spec.plugins.remove(at: index) }
        refresh()
    }

    func removeHeaderFromUI() {
        readFields()
        spec.headerImage = nil
        refresh()
    }

    // MARK: - Choosing Files

    func chooseSkinFromUI() {
        choose(.skin) { [weak self] url in self?.setSkin(url) }
    }

    func choosePluginFromUI() {
        choose(.plugin) { [weak self] url in self?.addPlugin(url) }
    }

    func chooseOutputFromUI() {
        choose(.output) { [weak self] url in
            self?.readFields()
            self?.spec.outputDirectory = url
            self?.refresh()
        }
    }

    func chooseHeaderFromUI() {
        choose(.header) { [weak self] url in
            self?.readFields()
            self?.spec.headerImage = url
            self?.refresh()
        }
    }

    func chooseLayoutFolderFromUI() {
        choose(.layoutFolder) { [weak self] url in self?.addLayout(url) }
    }

    func addSavedLayoutFromUI(named name: String) {
        guard let file = try? app.layoutStore.iniURL(named: name) else { return }
        addLayout(file.deletingLastPathComponent())
    }

    func initialDirectory(for choice: Choice) -> URL? {
        func existingDirectoryOrParent(_ url: URL) -> URL {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? url : url.deletingLastPathComponent()
            }
            return url.deletingLastPathComponent()
        }
        switch choice {
        case .skin:
            return spec.rootConfig.map(existingDirectoryOrParent) ?? app.skinsDirectory
        case .layoutFolder:
            return spec.layouts.last.map(existingDirectoryOrParent) ?? app.layoutsDirectory
        case .plugin:
            if let last = spec.plugins.last, let url = last.x64 ?? last.x86 {
                return url.deletingLastPathComponent()
            }
            return app.skinsDirectory.appendingPathComponent("@Vault/Plugins", isDirectory: true)
        case .output:
            return spec.outputDirectory
        case .header:
            return spec.headerImage?.deletingLastPathComponent()
        }
    }

    private func choose(_ choice: Choice, then use: @escaping (URL) -> Void) {
        if let chooseForTesting {
            if let url = chooseForTesting(choice) { use(url) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = [.skin, .layoutFolder, .output].contains(choice)
        panel.canChooseFiles = !panel.canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory(for: choice)
        switch choice {
        case .skin: panel.message = L("Choose the skin's root config folder.")
        case .layoutFolder, .output: break
        case .plugin: panel.allowedContentTypes = [.init(filenameExtension: "dll") ?? .data]
        case .header: panel.allowedContentTypes = [.bmp]
        }
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { use(url) }
        }
    }

    // MARK: - Load Previous

    func popUpHistoryMenuFromUI() {
        guard let contentView = window?.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries = history.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: L("None"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, entry) in entries.enumerated() {
                let title = entry.version.isEmpty ? entry.name : "\(entry.name) \(entry.version)"
                let item = NSMenuItem(title: title, action: #selector(historyMenuItemChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }
        let y: CGFloat = contentView.isFlipped ? contentView.bounds.height - 46 : 46
        menu.popUp(positioning: nil, at: NSPoint(x: 18, y: y), in: contentView)
    }

    @objc private func historyMenuItemChosen(_ sender: NSMenuItem) {
        loadPrevious(at: sender.tag)
    }

    func loadPrevious(at index: Int) {
        // "Entries in the Load previous menu can be deleted by holding Shift."
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            history.forget(at: index)
            syncMenus()
            return
        }
        let entries = history.entries
        guard entries.indices.contains(index) else { return }
        spec = entries[index]
        if spec.minimumDeskset == nil {
            spec.minimumDeskset = RmskinPackager.defaultMinimumDeskset
        }
        if spec.outputDirectory == nil || !FileManager.default.fileExists(atPath: spec.outputDirectory!.path) {
            spec.outputDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        viewModel.name = spec.name
        viewModel.author = spec.author
        viewModel.version = spec.version
        viewModel.minimumDeskset = spec.minimumDeskset ?? RmskinPackager.defaultMinimumDeskset
        viewModel.variablesText = spec.variableFiles.joined(separator: " | ")
        refresh()
    }

    // MARK: - Steps

    func cancelFromUI() { window?.close() }

    @objc func back() {
        readFields()
        step = 1
        refresh()
    }

    /// Step 1's checks, then step 2.
    @objc func next() {
        readFields()
        let first = RmskinPackager.problems(spec).filter(SkinPackagerWindowController.isStepOne)
        guard first.isEmpty else {
            return message(L("The package can’t be created yet"), first.map(describe).joined(separator: "\n"))
        }
        step = 2
        refresh()
    }

    @objc func create() {
        readFields()
        guard !busy else { return }
        let problems = RmskinPackager.problems(spec)
        guard problems.isEmpty, let output = spec.outputDirectory else {
            return message(L("The package can’t be created yet"), problems.map(describe).joined(separator: "\n"))
        }
        let destination = output.appendingPathComponent(RmskinPackager.fileName(for: spec))
        if FileManager.default.fileExists(atPath: destination.path), !confirmReplace(destination) { return }
        busy = true
        refresh()
        let spec = self.spec
        let work = { () -> Result<RmskinPackager.Result, Error> in Result { try RmskinPackager.build(spec) } }
        guard app.presentsWindows, chooseForTesting == nil else { return finish(work(), spec) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async { [weak self] in self?.finish(result, spec) }
        }
    }

    private func finish(_ result: Result<RmskinPackager.Result, Error>, _ made: RmskinPackageSpec) {
        busy = false
        switch result {
        case .success(let built):
            history.remember(made)
            refresh()
            var text = built.url.path
            if !built.skippedLinks.isEmpty {
                text += "\n\n" + L("Links were left out of the package: %@", built.skippedLinks.joined(separator: ", "))
            }
            reportCreated(built.url, text)
        case .failure(let error):
            refresh()
            message(L("Could not create the package"), String(describing: error))
        }
    }

    private func reportCreated(_ url: URL, _ text: String) {
        lastMessage = (L("Package created"), text)
        if let messageForTesting { return messageForTesting(L("Package created"), text) }
        guard app.presentsWindows, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Package created")
        alert.informativeText = text
        alert.addButton(withTitle: L("Show in Finder"))
        alert.addButton(withTitle: L("OK"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            self?.window?.close()
        }
    }

    private func confirmReplace(_ url: URL) -> Bool {
        if let confirmReplaceForTesting { return confirmReplaceForTesting(url) }
        guard app.presentsWindows else { return false }
        let alert = NSAlert()
        alert.messageText = L("“%@” already exists. Replace it?", url.lastPathComponent)
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func message(_ title: String, _ text: String) {
        lastMessage = (title, text)
        if let messageForTesting { return messageForTesting(title, text) }
        guard app.presentsWindows, let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window)
    }

    // MARK: - Snapshot

    func snapshot() -> NSBitmapImageRep? {
        guard let view = window?.contentView else { return nil }
        refresh()
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

    // MARK: - Problems in Words

    static func isStepOne(_ problem: RmskinPackagerProblem) -> Bool {
        switch problem {
        case .nameMissing, .authorMissing, .skinMissing, .skinWithoutSkins, .layoutWithoutSettings, .pluginIncomplete:
            return true
        default:
            return false
        }
    }

    func describe(_ problem: RmskinPackagerProblem) -> String {
        switch problem {
        case .nameMissing: return L("Enter a name.")
        case .authorMissing: return L("Enter an author.")
        case .skinMissing: return L("Choose the skin's root config folder.")
        case .skinWithoutSkins(let name): return L("“%@” has no skin (.ini) files.", name)
        case .layoutWithoutSettings(let name): return L("The layout “%@” has no Rainmeter.ini.", name)
        case .pluginIncomplete(let name): return L("The plugin “%@” needs both its 32-bit and 64-bit versions.", name)
        case .loadSkinNotFound(let path): return L("The skin to load, “%@”, is not in the package.", path)
        case .loadLayoutNotIncluded(let name): return L("The layout to load, “%@”, is not in the package.", name)
        case .headerNotBitmap: return L("The header image must be a .bmp file.")
        case .headerWrongSize(let width, let height):
            return L("The header image must be 400 × 60 pixels; this one is %lld × %lld.", width, height)
        case .variableFileNotFound(let path): return L("The variables file “%@” is not in the skin.", path)
        case .mergeWithVariableFiles: return L("Variables files and Merge skins can’t be used together.")
        case .minimumVersionInvalid(let text): return L("“%@” is not a version number such as 1.0 or 1.1.1.", text)
        case .outputMissing: return L("Choose where to save the package.")
        }
    }
}

// MARK: - SwiftUI Root View

struct SkinPackagerRootView: View {
    @ObservedObject var model: SkinPackagerViewModel
    weak var controller: SkinPackagerWindowController?

    private static let topHeight: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .font(.system(size: 13))
        .frame(minWidth: SkinPackagerWindowController.minimumSize.width,
               minHeight: SkinPackagerWindowController.minimumSize.height)
        .background(DeskProPalette.page)
        .ignoresSafeArea()
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                DeskAppMark(size: 28)
                    .frame(width: 28)
                Text(L("Create .rmskin Package"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .padding(.top, 26)
            .frame(maxWidth: .infinity, minHeight: Self.topHeight + 26, maxHeight: Self.topHeight + 26, alignment: .leading)
            .background(WindowDragArea())

            ForEach(SkinPackagerViewModel.Section.allCases, id: \.rawValue) { item in
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
                .disabled(model.busy)
            }

            Spacer(minLength: 12)

            Divider()
                .padding(.horizontal, 6)
                .padding(.bottom, 4)

            Button {
                controller?.popUpHistoryMenuFromUI()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    Text(L("Load Previous"))
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Hold Shift to delete an entry."))
            .disabled(model.busy)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(width: 225)
        .background(DeskProPalette.utilitySidebar)
    }

    // MARK: - Right Detail Pane

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

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.section {
                    case .info:
                        infoPage
                    case .options:
                        optionsPage
                    case .advanced:
                        advancedPage
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            bottomBar
        }
    }

    // MARK: - Step 1: Information & Components

    private var infoPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup(title: L("Package Info")) {
                DeskProSettingsRow(title: L("Name:")) {
                    TextField("", text: Binding(
                        get: { model.name },
                        set: {
                            model.name = $0
                            controller?.updateTextFieldsFromUI()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .disabled(model.busy)
                }

                DeskProSettingsRow(title: L("Author:")) {
                    TextField("", text: Binding(
                        get: { model.author },
                        set: {
                            model.author = $0
                            controller?.updateTextFieldsFromUI()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .disabled(model.busy)
                }

                DeskProSettingsRow(title: L("Version:"), divider: false) {
                    TextField("", text: Binding(
                        get: { model.version },
                        set: {
                            model.version = $0
                            controller?.updateTextFieldsFromUI()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .disabled(model.busy)
                }
            }

            DeskProSettingsGroup(title: L("Package Contents")) {
                DeskProSettingsRow(
                    title: L("Skin:"),
                    detail: model.skinDisplayText
                ) {
                    Button(L("Add Skin…")) {
                        controller?.chooseSkinFromUI()
                    }
                    .disabled(model.busy)
                }
                .help(model.skinFullPath ?? "")

                DeskProSettingsRow(
                    title: L("Layouts:"),
                    detail: model.layouts.isEmpty ? L("None") : nil,
                    divider: model.layouts.isEmpty
                ) {
                    Menu(L("Add Layout")) {
                        ForEach(model.savedLayoutNames, id: \.self) { name in
                            Button(name) {
                                controller?.addSavedLayoutFromUI(named: name)
                            }
                        }
                        if !model.savedLayoutNames.isEmpty {
                            Divider()
                        }
                        Button(L("Other…")) {
                            controller?.chooseLayoutFolderFromUI()
                        }
                    }
                    .fixedSize()
                    .disabled(model.busy)
                }

                if !model.layouts.isEmpty {
                    ForEach(Array(model.layouts.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.3.group")
                                .font(.system(size: 11.5))
                                .foregroundColor(DeskProPalette.indigoTint)
                            Text(item.name)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(L("Remove")) {
                                controller?.removeLayoutFromUI(at: item.id)
                            }
                            .controlSize(.small)
                            .disabled(model.busy)
                        }
                        .help(item.path)
                        .padding(.leading, 28)
                        .padding(.trailing, 14)
                        .padding(.vertical, 6)

                        if idx == model.layouts.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }

                DeskProSettingsRow(
                    title: L("Plugins:"),
                    detail: model.plugins.isEmpty ? L("None") : nil,
                    divider: false
                ) {
                    Button(L("Add Plugin…")) {
                        controller?.choosePluginFromUI()
                    }
                    .disabled(model.busy)
                }

                if !model.plugins.isEmpty {
                    Divider().padding(.leading, 28)
                    ForEach(model.plugins) { plugin in
                        HStack(spacing: 8) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 11.5))
                                .foregroundColor(DeskProPalette.privacyGreen)
                            Text(plugin.description)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(L("Remove")) {
                                controller?.removePluginFromUI(at: plugin.id)
                            }
                            .controlSize(.small)
                            .disabled(model.busy)
                        }
                        .help(plugin.toolTip ?? "")
                        .padding(.leading, 28)
                        .padding(.trailing, 14)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    // MARK: - Step 2A: Options

    private var optionsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup {
                DeskProSettingsRow(
                    title: L("Save package to:"),
                    detail: model.outputDisplayText
                ) {
                    Button(L("Choose…")) {
                        controller?.chooseOutputFromUI()
                    }
                    .disabled(model.busy)
                }
                .help(model.outputFullPath ?? "")

                DeskProSettingsRow(title: L("After installation:")) {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { model.loadKindIndex },
                            set: { controller?.selectLoadKindFromUI($0) }
                        )) {
                            Text(L("Do nothing")).tag(0)
                            Text(L("Load skin")).tag(1)
                            if model.canChooseLoadLayout || model.loadKindIndex == 2 {
                                Text(L("Load layout")).tag(2)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.busy)

                        if model.loadKindIndex != 0 && !model.loadChoices.isEmpty {
                            Picker("", selection: Binding(
                                get: { model.selectedLoadChoice },
                                set: { controller?.selectLoadItemFromUI($0) }
                            )) {
                                ForEach(model.loadChoices, id: \.self) { choice in
                                    Text(choice)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .tag(choice)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(model.busy)
                        }
                    }
                }

                DeskProSettingsRow(
                    title: L("Minimum Deskset version:"),
                    divider: false
                ) {
                    TextField(RmskinPackager.defaultMinimumDeskset, text: Binding(
                        get: { model.minimumDeskset },
                        set: {
                            model.minimumDeskset = $0
                            controller?.updateTextFieldsFromUI()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
                    .disabled(model.busy)
                }
            }
        }
    }

    // MARK: - Step 2B: Advanced

    private var advancedPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskProSettingsGroup {
                DeskProSettingsRow(
                    title: L("Header image:"),
                    detail: model.headerDisplayText
                ) {
                    HStack(spacing: 8) {
                        if model.hasHeader {
                            Button(L("Remove")) {
                                controller?.removeHeaderFromUI()
                            }
                            .disabled(model.busy)
                        }
                        Button(L("Choose…")) {
                            controller?.chooseHeaderFromUI()
                        }
                        .disabled(model.busy)
                    }
                }
                .help(model.headerFullPath ?? "")

                DeskProSettingsRow(title: L("Variables files:")) {
                    TextField("Skin\\Folder\\Variables.inc | …", text: Binding(
                        get: { model.variablesText },
                        set: {
                            model.variablesText = $0
                            controller?.updateTextFieldsFromUI()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 270)
                    .disabled(model.busy || !model.variablesEnabled)
                }

                DeskProSettingsRow(
                    title: L("Merge skins"),
                    divider: false
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.mergeSkins },
                        set: { controller?.setMergeSkinsFromUI($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.busy || !model.mergeEnabled)
                }
            }
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if model.busy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()

            Button(L("Cancel")) {
                controller?.cancelFromUI()
            }
            .keyboardShortcut(.cancelAction)

            if model.step == 2 {
                Button(L("Back")) {
                    controller?.back()
                }
                .disabled(model.busy)

                Button(L("Create Package")) {
                    controller?.create()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
            } else {
                Button(L("Next")) {
                    controller?.next()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(DeskProPalette.page)
    }
}
