import AppKit
import DesksetCore
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

/// Skin Packager (manual: "To launch the Skin Packager, open the Manage window and click the button labeled Create
/// .rmskin package..."): step 1 asks for the information and components, step 2 for the options and, on its Advanced
/// tab, the header image, variables files and Merge skins. `RmskinPackager` checks and writes the package.
final class SkinPackagerWindowController: NSWindowController, NSWindowDelegate {
    enum Choice: Equatable { case skin, layoutFolder, plugin, output, header }

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
    private(set) var spec = RmskinPackageSpec()
    private(set) var step = 1
    private(set) var busy = false
    var history: SkinPackagerHistory { SkinPackagerHistory(storage: SkinPackagerWindowController.historyStorage) }

    /// Tests answer the open panels, the confirmation and the messages, and build on the main thread.
    var chooseForTesting: ((Choice) -> URL?)?
    var confirmReplaceForTesting: ((URL) -> Bool)?
    var messageForTesting: ((String, String) -> Void)?
    private(set) var lastMessage: (title: String, text: String)?

    // Step 1
    private let nameField = NSTextField()
    private let authorField = NSTextField()
    private let versionField = NSTextField()
    private let skinLabel = NSTextField(labelWithString: "")
    private let layoutsList = NSStackView()
    private let pluginsList = NSStackView()
    private let addLayoutButton = NSPopUpButton(frame: .zero, pullsDown: true)
    // Step 2
    private let tabs = NSSegmentedControl(labels: [L("Options"), L("Advanced")], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let outputLabel = NSTextField(labelWithString: "")
    private let loadKindPopup = NSPopUpButton()
    private let loadItemPopup = NSPopUpButton()
    private let minimumField = NSTextField()
    private let headerLabel = NSTextField(labelWithString: "")
    private let removeHeaderButton = NSButton(title: L("Remove"), target: nil, action: nil)
    private let variablesField = NSTextField()
    private let mergeBox = NSButton(checkboxWithTitle: L("Merge skins"), target: nil, action: nil)
    private let optionsPage = NSGridView()
    private let advancedPage = NSGridView()
    // Both steps
    private let stepOne = NSStackView()
    private let stepTwo = NSStackView()
    private let previousPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let backButton = NSButton(title: L("Back"), target: nil, action: nil)
    private let nextButton = NSButton(title: L("Next"), target: nil, action: nil)
    private let createButton = NSButton(title: L("Create Package"), target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Create .rmskin Package")
        window.minSize = NSSize(width: 540, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
        spec.outputDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        build(in: window)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if SkinPackagerWindowController.current === self { SkinPackagerWindowController.current = nil }
    }

    // MARK: Layout

    private func build(in window: NSWindow) {
        let content = WindowBackgroundView()
        window.contentView = content
        // Long paths are cut in the middle instead of widening the window.
        for path in [skinLabel, outputLabel, headerLabel] {
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        // Step 1: information and components.
        for field in [nameField, authorField, versionField, minimumField, variablesField] {
            field.target = self
            field.action = #selector(fieldsChanged)
            field.delegate = self
        }
        let addSkin = NSButton(title: L("Add Skin…"), target: self, action: #selector(chooseSkin))
        skinLabel.lineBreakMode = .byTruncatingMiddle
        addLayoutButton.addItem(withTitle: L("Add Layout"))
        addLayoutButton.menu?.delegate = self
        let addPlugin = NSButton(title: L("Add Plugin…"), target: self, action: #selector(choosePlugin))
        for list in [layoutsList, pluginsList] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 4
        }
        let info = NSGridView(views: [
            [label(L("Name:")), nameField],
            [label(L("Author:")), authorField],
            [label(L("Version:")), versionField],
            [label(L("Skin:")), row([skinLabel, addSkin])],
            [label(L("Layouts:")), layoutsList],
            [NSGridCell.emptyContentView, addLayoutButton],
            [label(L("Plugins:")), pluginsList],
            [NSGridCell.emptyContentView, addPlugin],
        ])
        styleForm(info)
        stepOne.orientation = .vertical
        stepOne.alignment = .leading
        stepOne.addArrangedSubview(heading(L("Information and Components")))
        stepOne.addArrangedSubview(info)

        // Step 2: options, and the Advanced tab.
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        outputLabel.lineBreakMode = .byTruncatingMiddle
        let chooseOutput = NSButton(title: L("Choose…"), target: self, action: #selector(chooseOutput))
        loadKindPopup.addItems(withTitles: [L("Do nothing"), L("Load skin"), L("Load layout")])
        loadKindPopup.target = self
        loadKindPopup.action = #selector(loadKindChanged)
        loadItemPopup.target = self
        loadItemPopup.action = #selector(fieldsChanged)
        minimumField.placeholderString = RmskinPackager.defaultMinimumRainmeter
        optionsPage.addRow(with: [label(L("Save package to:")), row([outputLabel, chooseOutput])])
        optionsPage.addRow(with: [label(L("After installation:")), row([loadKindPopup, loadItemPopup])])
        optionsPage.addRow(with: [label(L("Minimum Rainmeter version:")), minimumField])
        styleForm(optionsPage)
        headerLabel.lineBreakMode = .byTruncatingMiddle
        let chooseHeader = NSButton(title: L("Choose…"), target: self, action: #selector(chooseHeader))
        removeHeaderButton.target = self
        removeHeaderButton.action = #selector(removeHeader)
        variablesField.placeholderString = "Skin\\Folder\\Variables.inc | …"
        mergeBox.target = self
        mergeBox.action = #selector(fieldsChanged)
        advancedPage.addRow(with: [label(L("Header image:")), row([headerLabel, chooseHeader, removeHeaderButton])])
        advancedPage.addRow(with: [label(L("Variables files:")), variablesField])
        advancedPage.addRow(with: [NSGridCell.emptyContentView, mergeBox])
        styleForm(advancedPage)
        // Text fields and path rows reach the form's right edge; buttons and menus keep their size.
        for (grid, views) in [(info, [nameField, authorField, versionField, skinLabel.superview]),
                              (optionsPage, [minimumField, outputLabel.superview]),
                              (advancedPage, [variablesField, headerLabel.superview])] as [(NSGridView, [NSView?])] {
            for view in views.compactMap({ $0 }) {
                view.trailingAnchor.constraint(equalTo: grid.trailingAnchor).isActive = true
            }
        }
        stepTwo.orientation = .vertical
        stepTwo.alignment = .leading
        stepTwo.addArrangedSubview(tabs)
        stepTwo.addArrangedSubview(optionsPage)
        stepTwo.addArrangedSubview(advancedPage)

        // Buttons.
        previousPopup.addItem(withTitle: L("Load Previous"))
        previousPopup.menu?.delegate = self
        previousPopup.toolTip = L("Hold Shift to delete an entry.")
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        backButton.target = self
        backButton.action = #selector(back)
        nextButton.target = self
        nextButton.action = #selector(next)
        nextButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(create)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = row([previousPopup, spacer, spinner, cancel, backButton, nextButton, createButton])

        for view in [stepOne, stepTwo, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stepOne.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stepOne.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stepOne.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stepTwo.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stepTwo.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stepTwo.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stepOne.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -12),
            stepTwo.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -12),
            info.widthAnchor.constraint(equalTo: stepOne.widthAnchor),
            optionsPage.widthAnchor.constraint(equalTo: stepTwo.widthAnchor),
            advancedPage.widthAnchor.constraint(equalTo: stepTwo.widthAnchor),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func styleForm(_ grid: NSGridView) {
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
    }

    // MARK: State → views

    /// Shows `spec` and the step; also after every change.
    func refresh() {
        stepOne.isHidden = step != 1
        stepTwo.isHidden = step != 2
        optionsPage.isHidden = tabs.selectedSegment != 0
        advancedPage.isHidden = tabs.selectedSegment != 1
        backButton.isHidden = step == 1
        nextButton.isHidden = step != 1
        createButton.isHidden = step != 2
        if step == 2 { createButton.keyEquivalent = "\r" } else { createButton.keyEquivalent = "" }
        nextButton.keyEquivalent = step == 1 ? "\r" : ""
        for control in [nextButton, createButton, backButton] { control.isEnabled = !busy }
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)

        setIfNeeded(nameField, spec.name)
        setIfNeeded(authorField, spec.author)
        setIfNeeded(versionField, spec.version)
        setIfNeeded(minimumField, spec.minimumRainmeter)
        setIfNeeded(variablesField, spec.variableFiles.joined(separator: " | "))
        skinLabel.stringValue = spec.rootConfig.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            ?? L("No skin chosen")
        skinLabel.toolTip = spec.rootConfig?.path
        skinLabel.textColor = spec.rootConfig == nil ? .secondaryLabelColor : .labelColor
        rebuild(layoutsList, items: spec.layouts.map { $0.lastPathComponent }, remove: #selector(removeLayout(_:)))
        rebuild(pluginsList, items: spec.plugins.map(pluginDescription), remove: #selector(removePlugin(_:)))
        outputLabel.stringValue = spec.outputDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        outputLabel.toolTip = spec.outputDirectory?.path
        headerLabel.stringValue = spec.headerImage?.lastPathComponent ?? L("None")
        headerLabel.textColor = spec.headerImage == nil ? .secondaryLabelColor : .labelColor
        removeHeaderButton.isHidden = spec.headerImage == nil
        mergeBox.state = spec.mergeSkins ? .on : .off
        // "This option is not compatible with the Variables files option" (and the other way round).
        mergeBox.isEnabled = spec.variableFiles.isEmpty
        variablesField.isEnabled = !spec.mergeSkins

        let choices = loadChoices()
        switch spec.load {
        case .none: loadKindPopup.selectItem(at: 0)
        case .skin: loadKindPopup.selectItem(at: 1)
        case .layout: loadKindPopup.selectItem(at: 2)
        }
        loadKindPopup.item(at: 2)?.isEnabled = !spec.layouts.isEmpty
        loadKindPopup.autoenablesItems = false
        loadItemPopup.removeAllItems()
        loadItemPopup.addItems(withTitles: choices)
        loadItemPopup.isHidden = spec.load == .none
        switch spec.load {
        case .skin(let path), .layout(let path): loadItemPopup.selectItem(withTitle: path)
        case .none: break
        }
    }

    private func setIfNeeded(_ field: NSTextField, _ value: String) {
        if field.stringValue != value && field.currentEditor() == nil { field.stringValue = value }
    }

    private func rebuild(_ list: NSStackView, items: [String], remove: Selector) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if items.isEmpty {
            let none = NSTextField(labelWithString: L("None"))
            none.textColor = .secondaryLabelColor
            list.addArrangedSubview(none)
        }
        for (index, item) in items.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L("Remove"))
                                  ?? NSImage(), target: self, action: remove)
            button.isBordered = false
            button.tag = index
            button.toolTip = L("Remove")
            list.addArrangedSubview(row([button, NSTextField(labelWithString: item)]))
        }
    }

    private func pluginDescription(_ plugin: RmskinPackageSpec.Plugin) -> String {
        switch (plugin.x86 != nil, plugin.x64 != nil) {
        case (true, true): return L("%@ (32-bit and 64-bit)", plugin.fileName)
        case (true, false): return L("%@ (64-bit version missing)", plugin.fileName)
        default: return L("%@ (32-bit version missing)", plugin.fileName)
        }
    }

    /// The skins of the package, or its layouts, for "After installation".
    private func loadChoices() -> [String] {
        switch spec.load {
        case .none: return []
        case .skin: return spec.rootConfig.map(RmskinPackager.skinFiles(inRootConfig:)) ?? []
        case .layout: return spec.layouts.map { $0.lastPathComponent }
        }
    }

    // MARK: Views → state

    /// Changes the settings as typing into the window would (self-tests).
    func edit(_ change: (inout RmskinPackageSpec) -> Void) {
        readFields()
        change(&spec)
        refresh()
    }

    @objc private func fieldsChanged() {
        readFields()
        refresh()
    }

    private func readFields() {
        spec.name = nameField.stringValue
        spec.author = authorField.stringValue
        spec.version = versionField.stringValue
        spec.minimumRainmeter = minimumField.stringValue
        spec.variableFiles = variablesField.stringValue.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        spec.mergeSkins = mergeBox.state == .on && spec.variableFiles.isEmpty
        if let title = loadItemPopup.titleOfSelectedItem {
            switch spec.load {
            case .skin: spec.load = .skin(title)
            case .layout: spec.load = .layout(title)
            case .none: break
            }
        }
    }

    @objc private func loadKindChanged() {
        readFields()
        switch loadKindPopup.indexOfSelectedItem {
        case 1: spec.load = .skin(spec.rootConfig.flatMap { RmskinPackager.skinFiles(inRootConfig: $0).first } ?? "")
        case 2: spec.load = .layout(spec.layouts.first?.lastPathComponent ?? "")
        default: spec.load = .none
        }
        refresh()
    }

    @objc private func tabChanged() { refresh() }

    /// Step 2 on its Options or Advanced tab, without step 1's checks (snapshots and self-tests).
    func showStepTwo(advanced: Bool) {
        readFields()
        step = 2
        tabs.selectedSegment = advanced ? 1 : 0
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

    @objc private func removeLayout(_ sender: NSButton) {
        readFields()
        guard spec.layouts.indices.contains(sender.tag) else { return }
        let name = spec.layouts.remove(at: sender.tag).lastPathComponent
        if case .layout(let loaded) = spec.load, loaded == name { spec.load = .none }
        refresh()
    }

    @objc private func removePlugin(_ sender: NSButton) {
        readFields()
        if spec.plugins.indices.contains(sender.tag) { spec.plugins.remove(at: sender.tag) }
        refresh()
    }

    @objc private func removeHeader() {
        readFields()
        spec.headerImage = nil
        refresh()
    }

    // MARK: Choosing files

    @objc private func chooseSkin() {
        choose(.skin) { [weak self] url in self?.setSkin(url) }
    }

    @objc private func choosePlugin() {
        choose(.plugin) { [weak self] url in self?.addPlugin(url) }
    }

    @objc private func chooseOutput() {
        choose(.output) { [weak self] url in
            self?.readFields()
            self?.spec.outputDirectory = url
            self?.refresh()
        }
    }

    @objc private func chooseHeader() {
        choose(.header) { [weak self] url in
            self?.readFields()
            self?.spec.headerImage = url
            self?.refresh()
        }
    }

    @objc private func chooseLayoutFolder() {
        choose(.layoutFolder) { [weak self] url in self?.addLayout(url) }
    }

    @objc private func addSavedLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let file = try? app.layoutStore.iniURL(named: name) else { return }
        addLayout(file.deletingLastPathComponent())
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
        switch choice {
        case .skin: panel.directoryURL = app.skinsDirectory; panel.message = L("Choose the skin's root config folder.")
        case .layoutFolder: panel.directoryURL = app.layoutsDirectory
        case .plugin:
            panel.allowedContentTypes = [.init(filenameExtension: "dll") ?? .data]
            panel.directoryURL = app.skinsDirectory.appendingPathComponent("@Vault/Plugins", isDirectory: true)
        case .output: panel.directoryURL = spec.outputDirectory
        case .header: panel.allowedContentTypes = [.bmp]
        }
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { use(url) }
        }
    }

    // MARK: Load previous

    func loadPrevious(at index: Int) {
        // "Entries in the Load previous menu can be deleted by holding Shift."
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            history.forget(at: index)
            return
        }
        let entries = history.entries
        guard entries.indices.contains(index) else { return }
        spec = entries[index]
        if spec.outputDirectory == nil || !FileManager.default.fileExists(atPath: spec.outputDirectory!.path) {
            spec.outputDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        refresh()
    }

    @objc private func previousChosen(_ sender: NSMenuItem) {
        loadPrevious(at: sender.tag)
    }

    // MARK: Steps

    @objc private func cancel() { window?.close() }

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
        refresh()
        switch result {
        case .success(let built):
            history.remember(made)
            var text = built.url.path
            if !built.skippedLinks.isEmpty {
                text += "\n\n" + L("Links were left out of the package: %@", built.skippedLinks.joined(separator: ", "))
            }
            reportCreated(built.url, text)
        case .failure(let error):
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

    // MARK: Problems in words

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
        case .minimumVersionInvalid(let text): return L("“%@” is not a version number such as 5.0 or 5.0.0.4657.", text)
        case .outputMissing: return L("Choose where to save the package.")
        }
    }
}

extension SkinPackagerWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        readFields()
        // Keep the typing field as it is; only the dependent controls follow.
        mergeBox.isEnabled = spec.variableFiles.isEmpty
        variablesField.isEnabled = !spec.mergeSkins
    }
}

extension SkinPackagerWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Pull-down menus keep their first item as the button's title.
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        if menu === previousPopup.menu {
            let entries = history.entries
            for (index, entry) in entries.enumerated() {
                let title = entry.version.isEmpty ? entry.name : "\(entry.name) \(entry.version)"
                let item = NSMenuItem(title: title, action: #selector(previousChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            if entries.isEmpty {
                let item = NSMenuItem(title: L("None"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else if menu === addLayoutButton.menu {
            for name in (try? app.layoutStore.list()) ?? [] {
                let item = NSMenuItem(title: name, action: #selector(addSavedLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                menu.addItem(item)
            }
            if menu.items.count > 1 { menu.addItem(.separator()) }
            let other = NSMenuItem(title: L("Other…"), action: #selector(chooseLayoutFolder), keyEquivalent: "")
            other.target = self
            menu.addItem(other)
        }
    }
}

/// Fills itself with the window background color, so offscreen snapshots (`--snapshot-ui packager`) look like the window.
private final class WindowBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
