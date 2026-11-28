import AppKit
import DesksetCore
import SwiftUI

/// Deskset Settings window with a flat left sidebar (`General`, `Desktop & Skins`, `Editor`, `Debug & Log`,
/// plus `About Deskset` anchored at the bottom) and grouped card pages. Everything persists in `AppState` (`state.json`).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Pane: String, CaseIterable {
        case general, desktop, editor, debug, about

        static let mainPanes: [Pane] = [.general, .desktop, .editor, .debug]

        var title: String {
            switch self {
            case .general: return L("General")
            case .desktop: return L("Desktop & Skins")
            case .editor: return L("Editor")
            case .debug: return L("Debug & Log")
            case .about: return L("About Deskset")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .desktop: return "rectangle.3.group"
            case .editor: return "chevron.left.forwardslash.chevron.right"
            case .debug: return "ladybug"
            case .about: return "info.circle"
            }
        }

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("settings.\(rawValue)") }
    }

    unowned let app: AppController
    let settingsModel = DesksetSettingsViewModel()
    private var hostingView: NSHostingView<DesksetSettingsRootView>?
    private(set) var pane = Pane.general
    private var observer: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private var zoomObserver: NSObjectProtocol?
    private var globalSettingsObserver: NSObjectProtocol?

    // Backing controls preserved for existing programmatic hooks and self-tests.
    let editorPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let helperLabel = NSTextField(wrappingLabelWithString: "")
    let fontField = NSTextField()
    let fontStepper = NSStepper()
    let liveReloadBox = NSButton(checkboxWithTitle: L("Refresh the skin when the file is saved elsewhere"),
                                 target: nil, action: nil)
    let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    var languagePreference = LanguagePreference.standard
    let uiThemePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let loginBox = NSButton(checkboxWithTitle: L("Launch Deskset at login"), target: nil, action: nil)
    let automaticUpdatesBox = NSButton(checkboxWithTitle: L("Automatically check for updates"), target: nil, action: nil)
    let checkUpdatesButton = NSButton(title: L("Check for Updates…"), target: nil, action: nil)
    let viewUpdateButton = NSButton(title: L("Update…"), target: nil, action: nil)
    let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    let defaultZoomField = NSTextField()
    let defaultZoomStepper = SkinZoomStepper()
    let forceZoomBox = NSButton(checkboxWithTitle: L("Apply to all skins"), target: nil, action: nil)
    let disableDraggingBox = NSButton(checkboxWithTitle: L("Disable dragging"), target: nil, action: nil)

    /// Editors offered in the pop-up (installed only) and the macOS default for .ini files.
    private(set) var detectedEditors: [CodeEditorApp] = []
    private var systemDefault: CodeEditorApp?
    /// The choice behind each pop-up item, by index ("Other…" and separators have none).
    private var choices: [Int: EditorPreferences.CodeEditor] = [:]
    private var otherIndex = -1

    private static var current: SettingsWindowController?

    static var openWindow: NSWindow? {
        guard let window = current?.window, window.isVisible || window.isMiniaturized else { return nil }
        return window
    }

    static func window(for app: AppController) -> SettingsWindowController? {
        guard let c = current, c.app === app else { return nil }
        return c
    }

    static let contentWidth: CGFloat = 920
    static let defaultSize = NSSize(width: 920, height: 640)
    static let minimumSize = NSSize(width: 800, height: 540)

    @discardableResult
    static func show(app: AppController, pane: Pane? = nil) -> SettingsWindowController {
        let reused = current.flatMap { $0.app === app ? $0 : nil }
        let controller = reused ?? SettingsWindowController(app: app)
        current = controller
        if let pane { controller.select(pane) }
        if reused != nil {
            controller.refreshEditorPopUp()
            controller.updateControls()
        }
        if app.presentsWindows, controller.window?.isVisible != true {
            controller.window?.center()
        }
        app.bringToFront(controller)
        return controller
    }

    init(app: AppController) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        DeskProWindowStyle.apply(to: window)
        window.minSize = Self.minimumSize
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self
        AppTheme.register(window, app: app)

        configureControls()
        refreshEditorPopUp()
        updateControls()

        let rootView = DesksetSettingsRootView(model: settingsModel, controller: self, app: app)
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: Self.defaultSize)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        hostingView = host

        select(app.state.data.settingsPane.flatMap(Pane.init(rawValue:)) ?? .general)

        observer = NotificationCenter.default.addObserver(
            forName: .desksetEditorPreferencesChanged,
            object: app.state,
            queue: .main
        ) { [weak self] _ in self?.preferencesChanged() }
        updateObserver = NotificationCenter.default.addObserver(
            forName: .desksetUpdatesChanged,
            object: app.updates,
            queue: .main
        ) { [weak self] _ in self?.updateControls() }
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .desksetSkinsChanged,
            object: app,
            queue: .main
        ) { [weak self] _ in
            self?.updateZoomControls()
            self?.refreshDebugData()
        }
        globalSettingsObserver = NotificationCenter.default.addObserver(
            forName: .desksetGlobalSettingsChanged,
            object: app.state,
            queue: .main
        ) { [weak self] _ in self?.updateControls() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
        if let globalSettingsObserver { NotificationCenter.default.removeObserver(globalSettingsObserver) }
    }

    func select(_ pane: Pane) {
        self.pane = pane
        settingsModel.pane = pane
        window?.title = pane.title
        app.state.setSettingsPane(pane.rawValue)
        if pane == .debug {
            refreshDebugData()
        }
    }

    private func configureControls() {
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChosen)
        refreshLanguagePopUp()

        for theme in AppUITheme.allCases {
            uiThemePopUp.addItem(withTitle: theme.title)
            uiThemePopUp.lastItem?.tag = theme.rawValue
        }
        uiThemePopUp.target = self
        uiThemePopUp.action = #selector(uiThemeChosen)
        uiThemePopUp.setAccessibilityLabel(L("Theme"))

        editorPopUp.target = self
        editorPopUp.action = #selector(editorChosen)
        editorPopUp.setAccessibilityLabel(L("Edit code with"))

        helperLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helperLabel.textColor = .secondaryLabelColor
        helperLabel.preferredMaxLayoutWidth = 340

        liveReloadBox.target = self
        liveReloadBox.action = #selector(liveReloadToggled)

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: EditorPreferences.fontSizes.lowerBound)
        formatter.maximum = NSNumber(value: EditorPreferences.fontSizes.upperBound)
        formatter.allowsFloats = false
        fontField.formatter = formatter
        fontField.alignment = .right
        fontField.target = self
        fontField.action = #selector(fontFieldChanged)
        fontField.setAccessibilityLabel(L("Code font size"))

        fontStepper.minValue = EditorPreferences.fontSizes.lowerBound
        fontStepper.maxValue = EditorPreferences.fontSizes.upperBound
        fontStepper.increment = 1
        fontStepper.valueWraps = false
        fontStepper.target = self
        fontStepper.action = #selector(fontStepperChanged)

        SkinZoomStepper.configure(
            field: defaultZoomField,
            stepper: defaultZoomStepper,
            target: self,
            fieldAction: #selector(defaultZoomFieldChanged),
            stepperAction: #selector(defaultZoomStepperChanged),
            label: L("Default zoom")
        )
        forceZoomBox.target = self
        forceZoomBox.action = #selector(forceZoomChanged)
        forceZoomBox.toolTip = L("Apply the default zoom to every skin.")
        forceZoomBox.setAccessibilityLabel(L("Force default zoom"))

        disableDraggingBox.target = self
        disableDraggingBox.action = #selector(disableDraggingToggled)
        disableDraggingBox.toolTip = L("Prevent dragging skins with the mouse.")
        disableDraggingBox.setAccessibilityLabel(L("Disable dragging"))

        loginBox.target = self
        loginBox.action = #selector(loginToggled)

        automaticUpdatesBox.target = self
        automaticUpdatesBox.action = #selector(automaticUpdatesToggled)

        checkUpdatesButton.target = app
        checkUpdatesButton.action = #selector(AppController.checkForUpdatesAction)
        viewUpdateButton.target = app
        viewUpdateButton.action = #selector(AppController.showAvailableUpdateAction)
        updateStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateStatusLabel.textColor = .secondaryLabelColor
    }

    // MARK: - Editor List

    func refreshEditorPopUp() {
        let preferences = app.state.editor
        let locator = CodeEditorRouter.locator
        detectedEditors = CodeEditorDetector.detect(preferences: preferences, locator: locator)
        systemDefault = CodeEditorDetector.systemDefaultApp(locator: locator)
        let menu = NSMenu()
        choices = [:]
        func add(_ title: String, _ image: NSImage?, _ choice: EditorPreferences.CodeEditor?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = image
            if let choice { choices[menu.items.count] = choice }
            menu.addItem(item)
            return item
        }
        let icon = AppIcon.image(size: 32)
        icon.size = NSSize(width: 16, height: 16)
        _ = add(Self.builtInTitle, icon, .builtIn)
        menu.addItem(.separator())
        for editor in detectedEditors {
            _ = add(editor.name, editor.icon, .app(bundleID: editor.bundleID ?? "", lastKnownPath: editor.url.path))
        }
        if case .app(let id, let path) = preferences.codeEditor, selectedIndex(for: preferences.codeEditor) == nil {
            let name = path.isEmpty ? id : CodeEditorApp.displayName(of: URL(fileURLWithPath: path))
            _ = add(L("%@ (missing)", name), nil, .app(bundleID: id, lastKnownPath: path))
        }
        menu.addItem(.separator())
        _ = add(L("System default (%@)", systemDefault?.name ?? "TextEdit"), systemDefault?.icon, .systemDefault)
        otherIndex = menu.items.count
        _ = add(L("Other…"), nil, nil)
        editorPopUp.menu = menu
        editorPopUp.selectItem(at: selectedIndex(for: preferences.codeEditor) ?? 0)
        syncEditorModel()
    }

    static var builtInTitle: String { L("Deskset (built-in, side by side)") }

    private func selectedIndex(for choice: EditorPreferences.CodeEditor) -> Int? {
        switch choice {
        case .builtIn, .systemDefault:
            return choices.first { $0.value == choice }?.key
        case .app(let id, let path):
            let target = URL(fileURLWithPath: path).standardizedFileURL.path
            return choices.filter { entry in
                guard case .app(let otherID, let otherPath) = entry.value else { return false }
                return (!id.isEmpty && otherID.caseInsensitiveCompare(id) == .orderedSame)
                    || (!path.isEmpty && URL(fileURLWithPath: otherPath).standardizedFileURL.path == target)
            }.map(\.key).min()
        }
    }

    // MARK: - Syncing State & ViewModel

    func updateControls() {
        let e = app.state.editor
        if let index = selectedIndex(for: e.codeEditor), index != editorPopUp.indexOfSelectedItem {
            editorPopUp.selectItem(at: index)
        }
        helperLabel.stringValue = Self.helperText(
            for: e.codeEditor,
            locator: CodeEditorRouter.locator,
            systemDefault: systemDefault
        )
        fontField.integerValue = Int(e.codeFontSize)
        fontStepper.doubleValue = e.codeFontSize
        liveReloadBox.state = e.liveReload ? .on : .off

        uiThemePopUp.selectItem(withTag: app.state.uiTheme.rawValue)
        disableDraggingBox.state = app.state.disableDragging ? .on : .off
        loginBox.state = LaunchAtLogin.isEnabled ? .on : .off
        loginBox.isEnabled = LaunchAtLogin.isAvailable
        automaticUpdatesBox.state = app.updates.automaticallyChecks ? .on : .off
        checkUpdatesButton.title = app.updates.menuTitle
        checkUpdatesButton.isEnabled = !app.updates.isChecking
        viewUpdateButton.isHidden = app.updates.availableRelease == nil
        updateStatusLabel.stringValue = app.updates.statusText

        updateZoomControls()
        syncViewModel()
    }

    private func updateZoomControls() {
        defaultZoomField.integerValue = app.state.defaultZoomPercent
        defaultZoomStepper.integerValue = app.state.defaultZoomPercent
        forceZoomBox.state = app.state.forceDefaultZoom ? .on : .off
        settingsModel.defaultZoomPercent = app.state.defaultZoomPercent
        settingsModel.forceDefaultZoom = app.state.forceDefaultZoom
    }

    private func syncEditorModel() {
        settingsModel.editorItems = editorPopUp.itemArray.enumerated().map { idx, item in
            let smallIcon: NSImage? = item.image.map { img in
                let copy = (img.copy() as? NSImage) ?? img
                copy.size = NSSize(width: 16, height: 16)
                return copy
            }
            return DesksetSettingsViewModel.EditorItem(
                id: idx,
                title: item.title,
                icon: smallIcon,
                isSeparator: item.isSeparatorItem
            )
        }
        settingsModel.selectedEditorIndex = max(0, editorPopUp.indexOfSelectedItem)
    }

    private func syncLanguageModel() {
        settingsModel.languageItems = languagePopUp.itemArray.enumerated().map { idx, item in
            DesksetSettingsViewModel.LanguageItem(
                id: idx,
                title: item.title,
                isSeparator: item.isSeparatorItem
            )
        }
        settingsModel.selectedLanguageIndex = max(0, languagePopUp.indexOfSelectedItem)
    }

    private func syncViewModel() {
        syncEditorModel()
        syncLanguageModel()
        settingsModel.editorHelperText = helperLabel.stringValue
        settingsModel.codeFontSize = Int(app.state.editor.codeFontSize)
        settingsModel.liveReload = app.state.editor.liveReload
        settingsModel.uiTheme = app.state.uiTheme
        settingsModel.launchAtLogin = LaunchAtLogin.isEnabled
        settingsModel.launchAtLoginAvailable = LaunchAtLogin.isAvailable
        settingsModel.automaticallyChecksUpdates = app.updates.automaticallyChecks
        settingsModel.isCheckingUpdates = app.updates.isChecking
        settingsModel.checkUpdatesTitle = app.updates.menuTitle
        settingsModel.availableUpdateVersion = app.updates.availableRelease?.version.description
        settingsModel.updateStatusText = app.updates.statusText
        settingsModel.defaultZoomPercent = app.state.defaultZoomPercent
        settingsModel.forceDefaultZoom = app.state.forceDefaultZoom
        settingsModel.disableDragging = app.state.disableDragging
        settingsModel.skinsFolderDisplayPath = (app.skinsDirectory.path as NSString).abbreviatingWithTildeInPath
        settingsModel.settingsFolderDisplayPath = (app.settingsDirectory.path as NSString).abbreviatingWithTildeInPath
        settingsModel.fileLoggingEnabled = app.state.fileLoggingEnabled
        refreshDebugData()
    }

    func refreshDebugData() {
        settingsModel.fileLoggingEnabled = app.state.fileLoggingEnabled
        settingsModel.recentLogs = Array(Log.recent.reversed())
    }

    private func preferencesChanged() {
        if selectedIndex(for: app.state.editor.codeEditor) == nil { refreshEditorPopUp() }
        updateControls()
    }

    static func helperText(for choice: EditorPreferences.CodeEditor, locator: ApplicationLocating,
                           systemDefault: CodeEditorApp?) -> String {
        switch choice {
        case .builtIn:
            return L("Opens the skin editor with the code next to the canvas, at the selected section. Other text files a skin opens (settings, scripts) open in a Deskset code window.")
        case .app(let id, let path):
            guard let url = CodeEditorDetector.resolve(bundleID: id, lastKnownPath: path, locator: locator) else {
                let name = path.isEmpty ? id : CodeEditorApp.displayName(of: URL(fileURLWithPath: path))
                return L("%@ is no longer installed — the built-in editor is used instead.", name)
            }
            let editor = CodeEditorApp(url: url, bundleID: id.isEmpty ? nil : id)
            return lineText(editor)
        case .systemDefault:
            guard let app = systemDefault else { return L("Opens files in TextEdit, which can’t jump to a line.") }
            return L("Opens each file in the app macOS uses for its type (%@ for .ini files).", app.name) + " " + lineText(app)
        }
    }

    private static func lineText(_ editor: CodeEditorApp) -> String {
        guard editor.family.jumpsToLine else { return L("%@ can’t jump to a line; files open at the top.", editor.name) }
        return L("Opens %@ at the selected line.", editor.name)
            + (editor.family.confirmsURLOpens ? " " + L("The first time, %@ may ask to allow this.", editor.name) : "")
    }

    // MARK: - Actions (AppKit & SwiftUI Bridge)

    func chooseEditorIndexFromUI(_ index: Int) {
        editorPopUp.selectItem(at: index)
        editorChosen()
    }

    @objc func editorChosen() {
        let index = editorPopUp.indexOfSelectedItem
        if index == otherIndex { return chooseOtherApp() }
        guard let choice = choices[index] else { return }
        app.state.updateEditor { $0.codeEditor = choice }
        updateControls()
    }

    private func chooseOtherApp() {
        guard app.presentsWindows, let window else { return updateControls() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Choose")
        panel.message = L("Choose the app that edits skin code.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return self.updateControls() }
            self.useOtherApp(url)
        }
    }

    func useOtherApp(_ url: URL) {
        let id = CodeEditorRouter.locator.bundleIdentifier(ofApplicationAt: url) ?? ""
        let picked = CodeEditorApp(url: url, bundleID: id.isEmpty ? nil : id, name: "", family: .plain)
        app.state.updateEditor {
            if CodeEditorRouter.isOwnApp(picked) {
                $0.codeEditor = .builtIn
            } else {
                $0.codeEditor = .app(bundleID: id, lastKnownPath: url.path)
                $0.otherApp = .init(bundleID: id, path: url.path)
            }
        }
        refreshEditorPopUp()
        updateControls()
    }

    // MARK: - Language

    func refreshLanguagePopUp() {
        let menu = NSMenu()
        let system = LanguagePreference.systemLanguage(preferences: LanguagePreference.macLanguages)
        menu.addItem(NSMenuItem(title: L("System default (%@)", LanguagePreference.name(of: system)), action: nil,
                                keyEquivalent: ""))
        menu.addItem(.separator())
        for choice in LanguagePreference.choices {
            let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
            item.representedObject = choice.language
            menu.addItem(item)
        }
        languagePopUp.menu = menu
        let chosen = languagePreference.chosen
        let index = menu.items.firstIndex { ($0.representedObject as? String).map { Self.sameLanguage($0, chosen) } ?? false }
        languagePopUp.selectItem(at: chosen == nil ? 0 : index ?? 0)
        syncLanguageModel()
    }

    private static func sameLanguage(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        let normal = { (s: String) in s.replacingOccurrences(of: "_", with: "-").lowercased() }
        return normal(a) == normal(b)
    }

    func chooseLanguageIndexFromUI(_ index: Int) {
        languagePopUp.selectItem(at: index)
        languageChosen()
    }

    @objc func languageChosen() {
        let language = languagePopUp.selectedItem?.representedObject as? String
        let before = languagePreference.chosen
        syncLanguageModel()
        guard language != before, !(language.map { Self.sameLanguage($0, before) } ?? false) else { return }
        languagePreference.choose(language)
        Log.write("App language set to \(language ?? "the Mac's"); used after a restart")
        guard app.presentsWindows, let window else { return }
        let alert = NSAlert()
        alert.icon = AppIcon.image(size: 64)
        alert.messageText = L("Restart Deskset now?")
        alert.informativeText = L("The new language is used after Deskset restarts.")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.app.requestRestart() }
        }
    }

    func setLiveReloadFromUI(_ value: Bool) {
        liveReloadBox.state = value ? .on : .off
        liveReloadToggled()
    }

    @objc private func liveReloadToggled() {
        app.state.updateEditor { $0.liveReload = liveReloadBox.state == .on }
        updateControls()
    }

    func commitFontSizeTextFromUI(_ text: String) {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else {
            updateControls()
            return
        }
        fontField.doubleValue = v
        fontFieldChanged()
    }

    func stepFontSizeFromUI(_ value: Int) {
        fontStepper.doubleValue = Double(value)
        fontStepperChanged()
    }

    @objc private func fontFieldChanged() {
        app.state.updateEditor { $0.codeFontSize = fontField.doubleValue }
        updateControls()
    }

    @objc private func fontStepperChanged() {
        app.state.updateEditor { $0.codeFontSize = fontStepper.doubleValue }
        updateControls()
    }

    func commitDefaultZoomTextFromUI(_ text: String) {
        defaultZoomField.stringValue = text
        defaultZoomFieldChanged()
    }

    func stepDefaultZoomFromUI(_ value: Int) {
        defaultZoomStepper.integerValue = value
        defaultZoomStepperChanged()
    }

    @objc private func defaultZoomFieldChanged() {
        guard let percent = Int(defaultZoomField.stringValue.trimmingCharacters(in: .whitespaces)) else {
            updateZoomControls()
            return
        }
        app.setDefaultZoom(percent: min(max(percent, 10), 500), force: nil)
    }

    @objc private func defaultZoomStepperChanged() {
        app.setDefaultZoom(percent: defaultZoomStepper.integerValue, force: nil)
    }

    func setForceZoomFromUI(_ value: Bool) {
        forceZoomBox.state = value ? .on : .off
        forceZoomChanged()
    }

    @objc private func forceZoomChanged() {
        app.setDefaultZoom(percent: nil, force: forceZoomBox.state == .on)
    }

    func setDisableDraggingFromUI(_ value: Bool) {
        disableDraggingBox.state = value ? .on : .off
        disableDraggingToggled()
    }

    @objc private func disableDraggingToggled() {
        app.state.setDisableDragging(disableDraggingBox.state == .on)
        updateControls()
    }

    func chooseThemeFromUI(_ theme: AppUITheme) {
        uiThemePopUp.selectItem(withTag: theme.rawValue)
        uiThemeChosen()
    }

    @objc func uiThemeChosen() {
        guard let theme = AppUITheme(rawValue: uiThemePopUp.selectedTag()) else { return }
        app.state.setUITheme(theme)
        updateControls()
    }

    func toggleLoginFromUI() {
        loginToggled()
    }

    @objc private func loginToggled() {
        LaunchAtLogin.toggle(app: app)
        updateControls()
    }

    func setAutomaticUpdatesFromUI(_ value: Bool) {
        automaticUpdatesBox.state = value ? .on : .off
        automaticUpdatesToggled()
    }

    @objc private func automaticUpdatesToggled() {
        app.updates.setAutomaticallyChecks(automaticUpdatesBox.state == .on)
        updateControls()
    }

    // MARK: - Snapshot (UISnapshot & Self-Tests)

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

    var testEditorTitles: [String] { editorPopUp.itemArray.map { $0.isSeparatorItem ? "-" : $0.title } }

    func testChoose(_ title: String) {
        guard let index = editorPopUp.itemArray.firstIndex(where: { $0.title == title }) else { return }
        editorPopUp.selectItem(at: index)
        editorChosen()
    }
}

extension AppController {
    /// App menu and status menu "Settings…" (⌘,).
    @objc func settingsAction() {
        SettingsWindowController.show(app: self)
    }
}
