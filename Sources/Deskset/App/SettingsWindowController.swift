import AppKit

/// Settings (App menu "Settings…" ⌘,, and the status menu): a preferences-style toolbar of panes, General | Editor
/// (docs/editor-design.md §6). As the HIG asks for settings windows: the title names the pane, the window reopens on
/// the last pane used, minimize and zoom are dimmed, and every change applies at once (no OK button).
///
/// Everything is stored in `AppState` (state.json); the Editor pane edits `EditorPreferences`, which
/// `CodeEditorRouter` follows.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum Pane: String, CaseIterable {
        case general, editor

        var title: String {
            switch self {
            case .general: return "General"
            case .editor: return "Editor"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .editor: return "chevron.left.forwardslash.chevron.right"
            }
        }

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("settings.\(rawValue)") }
    }

    unowned let app: AppController
    private(set) var pane = Pane.general
    private var paneViews: [Pane: NSView] = [:]
    private var observer: NSObjectProtocol?

    // Editor pane.
    let editorPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let helperLabel = NSTextField(wrappingLabelWithString: "")
    let modeControl = NSSegmentedControl(labels: EditorPreferences.OpenSkinsIn.allCases.map(\.title),
                                         trackingMode: .selectOne, target: nil, action: nil)
    /// View ▸ Show Rainmeter Details in the skin editor (docs/editor-friendly.md §4).
    let iniNamesBox = NSButton(checkboxWithTitle: "Show Rainmeter details", target: nil, action: nil)
    let fontField = NSTextField()
    let fontStepper = NSStepper()
    let liveReloadBox = NSButton(checkboxWithTitle: "Refresh the skin when the file is saved elsewhere",
                                 target: nil, action: nil)
    // General pane.
    let loginBox = NSButton(checkboxWithTitle: "Launch Deskset at login", target: nil, action: nil)

    /// Editors offered in the pop-up (installed only) and the macOS default for .ini files.
    private(set) var detectedEditors: [CodeEditorApp] = []
    private var systemDefault: CodeEditorApp?
    /// The choice behind each pop-up item, by index ("Other…" and separators have none).
    private var choices: [Int: EditorPreferences.CodeEditor] = [:]
    private var otherIndex = -1

    /// The window (one per app run).
    private static var current: SettingsWindowController?

    /// The Settings window when it is open (shown or in the Dock).
    static var openWindow: NSWindow? {
        guard let window = current?.window, window.isVisible || window.isMiniaturized else { return nil }
        return window
    }

    static let contentWidth: CGFloat = 580

    /// Shows Settings, on `pane` when given (else the last pane used).
    @discardableResult
    static func show(app: AppController, pane: Pane? = nil) -> SettingsWindowController {
        let reused = current.flatMap { $0.app === app ? $0 : nil }
        let controller = reused ?? SettingsWindowController(app: app)
        current = controller
        if let pane { controller.select(pane) }
        if reused != nil {
            // Editors may have been installed or removed, Launch at Login changed in System Settings.
            controller.refreshEditorPopUp()
            controller.updateControls()
        }
        if app.presentsWindows {
            AppActivation.track(controller.window)
            NSApp.activate(ignoringOtherApps: true)
            if controller.window?.isVisible != true { controller.window?.center() }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    init(app: AppController) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "DesksetSettings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        configureControls()
        refreshEditorPopUp()
        updateControls()
        select(app.state.data.settingsPane.flatMap(Pane.init(rawValue:)) ?? .general)
        observer = NotificationCenter.default.addObserver(forName: .desksetEditorPreferencesChanged, object: app.state,
                                                          queue: .main) { [weak self] _ in self?.preferencesChanged() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.identifier) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.identifier) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.identifier) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: { $0.identifier == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(paneClicked(_:))
        return item
    }

    @objc private func paneClicked(_ sender: NSToolbarItem) {
        if let pane = Pane.allCases.first(where: { $0.identifier == sender.itemIdentifier }) { select(pane) }
    }

    /// Shows a pane: the window keeps its top edge and takes the pane's height.
    func select(_ pane: Pane) {
        guard let window else { return }
        self.pane = pane
        window.toolbar?.selectedItemIdentifier = pane.identifier
        window.title = pane.title
        let view = paneView(pane)
        if window.contentView !== view {
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let size = NSSize(width: Self.contentWidth, height: ceil(view.fittingSize.height))
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
        app.state.setSettingsPane(pane.rawValue)
    }

    private func paneView(_ pane: Pane) -> NSView {
        if let view = paneViews[pane] { return view }
        let view = pane == .editor ? makeEditorPane() : makeGeneralPane()
        paneViews[pane] = view
        return view
    }

    // MARK: Building

    private func configureControls() {
        editorPopUp.target = self
        editorPopUp.action = #selector(editorChosen)
        editorPopUp.setAccessibilityLabel("Edit code with")
        helperLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helperLabel.textColor = .secondaryLabelColor
        helperLabel.preferredMaxLayoutWidth = 340
        modeControl.target = self
        modeControl.action = #selector(modeChosen)
        for (i, mode) in EditorPreferences.OpenSkinsIn.allCases.enumerated() {
            modeControl.setToolTip(mode.help, forSegment: i)
        }
        iniNamesBox.target = self
        iniNamesBox.action = #selector(iniNamesToggled)
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
        fontField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fontField.setAccessibilityLabel("Code font size")
        fontStepper.minValue = EditorPreferences.fontSizes.lowerBound
        fontStepper.maxValue = EditorPreferences.fontSizes.upperBound
        fontStepper.increment = 1
        fontStepper.valueWraps = false
        fontStepper.target = self
        fontStepper.action = #selector(fontStepperChanged)
        loginBox.target = self
        loginBox.action = #selector(loginToggled)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 340
        return l
    }

    /// A pane: a label | control grid (labels right-aligned, as in System Settings' classic panes), centred.
    private func makePane(rows: [[NSView]], spacingAfter: [Int: CGFloat] = [:]) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        for (row, spacing) in spacingAfter { grid.row(at: row).bottomPadding = spacing }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        return view
    }

    private func makeEditorPane() -> NSView {
        let font = NSStackView(views: [fontField, fontStepper, NSTextField(labelWithString: "pt")])
        font.spacing = 4
        let empty = { NSGridCell.emptyContentView }
        return makePane(rows: [
            [label("Edit code with:"), editorPopUp],
            [empty(), helperLabel],
            [label("Open skins in:"), modeControl],
            [empty(), note("How Edit Skin… opens a skin. Source links and code actions always show the code.")],
            [label("Inspector:"), iniNamesBox],
            [empty(), note("Adds option names, section names and every setting to the editor.")],
            [label("Code font size:"), font],
            [label("Live reload:"), liveReloadBox],
        ], spacingAfter: [1: 8, 3: 8, 5: 8])
    }

    private func makeGeneralPane() -> NSView {
        let path = NSTextField(labelWithString: (app.skinsDirectory.path as NSString).abbreviatingWithTildeInPath)
        path.lineBreakMode = .byTruncatingMiddle
        path.textColor = .secondaryLabelColor
        path.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let reveal = NSButton(title: "Show in Finder", target: app, action: #selector(AppController.openSkinsFolderAction))
        reveal.controlSize = .small
        let folder = NSStackView(views: [path, reveal])
        folder.spacing = 8
        let loginNote = note(LaunchAtLogin.isAvailable ? "Your skins come back when you log in."
                                                       : "Available when Deskset runs from the Applications folder.")
        return makePane(rows: [
            [label("Startup:"), loginBox],
            [NSGridCell.emptyContentView, loginNote],
            [label("Skins folder:"), folder],
        ], spacingAfter: [1: 8])
    }

    // MARK: Editor list

    /// Rebuilds "Edit code with:": Deskset (built-in) ─ installed editors with icons ─ "System default (<App>)",
    /// "Other…". A chosen app that has been uninstalled stays listed, marked "(missing)".
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
            _ = add("\(name) (missing)", nil, .app(bundleID: id, lastKnownPath: path))
        }
        menu.addItem(.separator())
        _ = add("System default (\(systemDefault?.name ?? "TextEdit"))", systemDefault?.icon, .systemDefault)
        otherIndex = menu.items.count
        _ = add("Other…", nil, nil)
        editorPopUp.menu = menu
        editorPopUp.selectItem(at: selectedIndex(for: preferences.codeEditor) ?? 0)
    }

    static let builtInTitle = "Deskset (built-in, side by side)"

    /// The pop-up item of a choice.
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

    // MARK: Values

    /// Puts the stored preferences into the controls.
    func updateControls() {
        let e = app.state.editor
        if let index = selectedIndex(for: e.codeEditor), index != editorPopUp.indexOfSelectedItem {
            editorPopUp.selectItem(at: index)
        }
        helperLabel.stringValue = Self.helperText(for: e.codeEditor, locator: CodeEditorRouter.locator,
                                                  systemDefault: systemDefault)
        modeControl.selectedSegment = EditorPreferences.OpenSkinsIn.allCases.firstIndex(of: e.openSkinsIn) ?? 0
        modeControl.isEnabled = e.codeEditor == .builtIn
        iniNamesBox.state = e.showIniNames ? .on : .off
        fontField.integerValue = Int(e.codeFontSize)
        fontStepper.doubleValue = e.codeFontSize
        liveReloadBox.state = e.liveReload ? .on : .off
        loginBox.state = LaunchAtLogin.isEnabled ? .on : .off
        loginBox.isEnabled = LaunchAtLogin.isAvailable
    }

    private func preferencesChanged() {
        // A choice the list does not show (picked with Other…, or changed elsewhere) needs a new list.
        if selectedIndex(for: app.state.editor.codeEditor) == nil { refreshEditorPopUp() }
        updateControls()
    }

    /// What "Edit code with" will do, under the pop-up.
    static func helperText(for choice: EditorPreferences.CodeEditor, locator: ApplicationLocating,
                           systemDefault: CodeEditorApp?) -> String {
        switch choice {
        case .builtIn:
            return "Opens the skin editor with the code next to the canvas, at the selected section. Other text files "
                + "a skin opens (settings, scripts) open in a Deskset code window."
        case .app(let id, let path):
            guard let url = CodeEditorDetector.resolve(bundleID: id, lastKnownPath: path, locator: locator) else {
                let name = path.isEmpty ? id : CodeEditorApp.displayName(of: URL(fileURLWithPath: path))
                return "\(name) is no longer installed — the built-in editor is used instead."
            }
            let editor = CodeEditorApp(url: url, bundleID: id.isEmpty ? nil : id)
            return lineText(editor)
        case .systemDefault:
            guard let app = systemDefault else { return "Opens files in TextEdit, which can’t jump to a line." }
            return "Opens each file in the app macOS uses for its type (\(app.name) for .ini files). " + lineText(app)
        }
    }

    private static func lineText(_ editor: CodeEditorApp) -> String {
        guard editor.family.jumpsToLine else { return "\(editor.name) can’t jump to a line; files open at the top." }
        return "Opens \(editor.name) at the selected line."
            + (editor.family.confirmsURLOpens ? " The first time, \(editor.name) may ask to allow this." : "")
    }

    // MARK: Actions

    @objc func editorChosen() {
        let index = editorPopUp.indexOfSelectedItem
        if index == otherIndex { return chooseOtherApp() }
        guard let choice = choices[index] else { return }
        app.state.updateEditor { $0.codeEditor = choice }
        updateControls()
    }

    /// "Other…": any application; it is remembered in the list.
    private func chooseOtherApp() {
        guard app.presentsWindows, let window else { return updateControls() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose the app that edits skin code."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return self.updateControls() }
            self.useOtherApp(url)
        }
    }

    /// Makes an app picked with "Other…" the code editor (Deskset itself means the built-in editor).
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

    @objc private func modeChosen() {
        let modes = EditorPreferences.OpenSkinsIn.allCases
        guard modes.indices.contains(modeControl.selectedSegment) else { return }
        app.state.updateEditor { $0.openSkinsIn = modes[modeControl.selectedSegment] }
    }

    @objc private func iniNamesToggled() {
        app.state.updateEditor { $0.showIniNames = iniNamesBox.state == .on }
    }

    @objc private func liveReloadToggled() {
        app.state.updateEditor { $0.liveReload = liveReloadBox.state == .on }
    }

    @objc private func fontFieldChanged() {
        app.state.updateEditor { $0.codeFontSize = fontField.doubleValue }
        updateControls()
    }

    @objc private func fontStepperChanged() {
        app.state.updateEditor { $0.codeFontSize = fontStepper.doubleValue }
        updateControls()
    }

    @objc private func loginToggled() {
        LaunchAtLogin.toggle(app: app)
        updateControls()
    }

    // MARK: Snapshot (UISnapshot, self-tests)

    /// Renders the current pane off-screen, under a stand-in for the preferences toolbar.
    func snapshot() -> NSBitmapImageRep? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        let bar: CGFloat = 64
        let size = NSSize(width: view.bounds.width, height: view.bounds.height + bar)
        let scale: CGFloat = 2
        guard size.width > 0, size.height > bar,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: content)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: size.height - bar, width: size.width, height: 1).fill()
            // Pane buttons: icon over label, the selected one tinted.
            let panes = Pane.allCases
            let itemWidth: CGFloat = 72
            var x = (size.width - itemWidth * CGFloat(panes.count)) / 2
            for p in panes {
                let selected = p == pane
                let rect = NSRect(x: x + 6, y: size.height - bar + 6, width: itemWidth - 12, height: bar - 12)
                if selected {
                    NSColor.quaternaryLabelColor.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                }
                let tint: NSColor = selected ? .controlAccentColor : .secondaryLabelColor
                if let symbol = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) {
                    let tinted = NSImage(size: symbol.size, flipped: false) { r in
                        symbol.draw(in: r)
                        tint.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: rect.midX - symbol.size.width / 2, y: rect.maxY - 8 - symbol.size.height,
                                           width: symbol.size.width, height: symbol.size.height))
                }
                let text = NSAttributedString(string: p.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.labelColor])
                text.draw(at: NSPoint(x: rect.midX - text.size().width / 2, y: rect.minY + 4))
                x += itemWidth
            }
            content.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Pop-up titles (self-tests).
    var testEditorTitles: [String] { editorPopUp.itemArray.map { $0.isSeparatorItem ? "-" : $0.title } }

    /// Picks a pop-up item by title as a click would (self-tests).
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
