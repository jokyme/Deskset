import AppKit
import DesksetCore
import UniformTypeIdentifiers

/// What the install confirmation shows for an inspected package (kept free of views so it can be tested).
struct InstallSummary: Equatable {
    struct Line: Equatable {
        var text: String
        var detail: String?
        /// Configs (folders with .ini files) inside the root config, relative to it.
        var configs: [String] = []
    }

    var title: String
    var subtitle: String
    var skins: [Line]
    var layouts: [String]
    var loadAfterInstall: String?
    var layoutToApply: String?
    var pluginWarning: String?
    var warnings: [String]
    /// Font files the installation adds to the skins' `@Resources/Fonts` folders.
    var fonts: [String]
    /// How the input was recognised when it is not a Skin Packager .rmskin (a plain archive or folder, a legacy
    /// Rainstaller package); nil for a .rmskin.
    var formatNote: String?

    /// Text of the package's own plugin warning (DesksetCore's, in English), replaced by `pluginWarning`.
    private static let pluginWarningPrefix = "The package includes Windows plugins"

    init(_ inspection: RmskinInspection, packageName: String, skinsDirectory: URL) {
        let m = inspection.manifest
        let isFolder = inspection.sourceFolder != nil
        let name = m.name.isEmpty ? (isFolder ? packageName : (packageName as NSString).deletingPathExtension) : m.name
        title = L("Install “%@”?", name)
        var parts: [String] = []
        if !m.author.isEmpty { parts.append(L("By %@", m.author)) }
        if !m.version.isEmpty { parts.append(L("Version %@", m.version)) }
        switch m.packageFormat {
        case .rmskin:
            formatNote = nil
            subtitle = parts.isEmpty ? L("The package does not say who made it.") : parts.joined(separator: " · ")
        case .rainstaller:
            formatNote = L("A package made for the installer of old Rainmeter versions (Rainstaller).")
            subtitle = parts.isEmpty ? L("The package does not say who made it.") : parts.joined(separator: " · ")
        case .plain:
            // No RMSKIN.ini: the root configs below were detected from the .ini files (see RmskinPlainArchive).
            formatNote = isFolder
                ? L("This folder is not a skin package made with Rainmeter’s Skin Packager, so Deskset found the skins in it by itself. Check the list below before installing. The folder is copied; the original stays where it is.")
                : L("This archive is not a skin package made with Rainmeter’s Skin Packager, so Deskset found the skins in it by itself. Check the list below before installing.")
            subtitle = parts.isEmpty
                ? (isFolder ? L("A plain folder: no author or version information.")
                    : L("A plain archive: no author or version information."))
                : parts.joined(separator: " · ")
        }
        fonts = inspection.fontNames

        let existing = Set(inspection.existingRootConfigs(in: skinsDirectory).map { $0.lowercased() })
        let packaged = InstallSummary.packagedConfigs(inspection)
        skins = inspection.rootConfigs.map { root in
            let configs = packaged.filter { $0.lowercased().hasPrefix(root.lowercased() + "\\") }
                .map { String($0.dropFirst(root.count + 1)) }
            guard existing.contains(root.lowercased()) else { return Line(text: root, detail: nil, configs: configs) }
            let detail = m.mergeSkins
                ? (m.packageFormat == .rmskin ? L("adds to the installed skins; no backup or variable preservation")
                    : L("adds to the installed skins"))
                : L("replaces the installed version")
            return Line(text: root, detail: detail, configs: configs)
        }
        layouts = inspection.layouts

        if m.loadType.caseInsensitiveCompare("Layout") == .orderedSame
            || (m.loadType.isEmpty && !m.load.isEmpty && (m.load as NSString).pathExtension.caseInsensitiveCompare("ini") != .orderedSame) {
            layoutToApply = m.load.isEmpty ? nil : m.load
            loadAfterInstall = m.load.isEmpty ? nil : L("Layout “%@”", m.load)
        } else if !m.load.isEmpty {
            loadAfterInstall = m.load.replacingOccurrences(of: "/", with: "\\")
        }

        if inspection.containsPlugins {
            pluginWarning = inspection.pluginNames.isEmpty
                ? L("This package includes Windows plugins. Plugins can’t run on macOS, so parts of these skins may show no data.")
                : L("This package includes Windows plugins (%@). Plugins can’t run on macOS, so parts of these skins may show no data.",
                    inspection.pluginNames.joined(separator: ", "))
        }
        warnings = inspection.warnings.filter { !$0.hasPrefix(InstallSummary.pluginWarningPrefix) }
    }
}

extension InstallSummary {
    /// Config names (`Root\\Sub`) in the extracted package's Skins folder.
    static func packagedConfigs(_ inspection: RmskinInspection) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(at: inspection.packageRoot,
                                                                     includingPropertiesForKeys: nil)) ?? []
        guard let skins = children.first(where: { $0.lastPathComponent.caseInsensitiveCompare("Skins") == .orderedSame })
        else { return [] }
        return SkinLibrary.scan(skins).map(\.name)
    }
}

/// Skin installation from .rmskin packages, ZIP archives and folders (anything `RmskinPackage.canInspect` accepts):
/// inspect → confirm (name, author, version, header image, configs, fonts, warnings) → install → load the skin the
/// package asks for. Packages are handled one at a time.
final class SkinInstallFlow {
    struct Options: Equatable {
        var loadIncludedSkins = true
        var applyIncludedLayout = true
        var backupSkins = true
    }

    /// The confirmation and its previews read the same live controls.
    final class OptionControls: NSStackView {
        let loadSkinsCheckbox: NSButton?
        let loadLayoutCheckbox: NSButton?
        let advancedButton = NSPopUpButton(frame: .zero, pullsDown: true)
        let backupSkinsItem = NSMenuItem(title: L("Backup skins"), action: nil, keyEquivalent: "")

        var options: Options {
            Options(loadIncludedSkins: loadSkinsCheckbox?.state != .off,
                    applyIncludedLayout: loadLayoutCheckbox?.state != .off,
                    backupSkins: backupSkinsItem.state == .on)
        }

        init(summary: InstallSummary, options: Options = Options()) {
            if summary.layoutToApply == nil, summary.loadAfterInstall != nil {
                let checkbox = NSButton(checkboxWithTitle: L("Load included skins"), target: nil, action: nil)
                checkbox.state = options.loadIncludedSkins ? .on : .off
                checkbox.toolTip = summary.loadAfterInstall
                loadSkinsCheckbox = checkbox
            } else { loadSkinsCheckbox = nil }
            loadLayoutCheckbox = summary.layoutToApply.map { name in
                let checkbox = NSButton(checkboxWithTitle: L("Apply included layout: %@", name), target: nil, action: nil)
                checkbox.state = options.applyIncludedLayout ? .on : .off
                return checkbox
            }
            super.init(frame: .zero)
            orientation = .vertical
            alignment = .leading
            spacing = 8
            if let loadSkinsCheckbox { addArrangedSubview(loadSkinsCheckbox) }
            if let loadLayoutCheckbox { addArrangedSubview(loadLayoutCheckbox) }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: L("Advanced"), action: nil, keyEquivalent: "")
            backupSkinsItem.target = self
            backupSkinsItem.action = #selector(toggleBackupSkins(_:))
            backupSkinsItem.state = options.backupSkins ? .on : .off
            backupSkinsItem.toolTip = L("Keep a backup when replacing installed skins.")
            menu.addItem(backupSkinsItem)
            advancedButton.menu = menu
            advancedButton.setAccessibilityLabel(L("Advanced installation options"))
            addArrangedSubview(advancedButton)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func toggleBackupSkins(_ sender: NSMenuItem) {
            sender.state = sender.state == .on ? .off : .on
        }
    }

    private unowned let app: AppController
    private var queue: [URL] = []
    private var busy = false
    private var applyInstalledLayout = true
    private var options = Options()
    private var layoutBackupBeforeInstall: LayoutDocument?
    private var layoutWaitObserver: NSObjectProtocol?

    init(app: AppController) {
        self.app = app
    }

    deinit {
        if let observer = layoutWaitObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// Nothing queued or in progress.
    var isIdle: Bool { !busy && queue.isEmpty }
    /// A package is being inspected, confirmed or installed. Queued packages may wait for a layout switch.
    var isInstalling: Bool { busy }
    /// The skins of the package's root configs were stopped, and the installer waits for them to close before it
    /// replaces their files.
    private(set) var waitsForSkinsToClose = false

    /// Open panel for "Install Skin…": .rmskin packages, ZIP archives and skin folders.
    func chooseAndInstall() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L("Install Skin")
        panel.message = L("Choose a skin package (.rmskin), a ZIP archive or a folder with skins to install.")
        panel.prompt = L("Install")
        panel.allowedContentTypes = SkinInstallFlow.openPanelTypes
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
        if let window = app.visibleManageWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// File types the open panel offers (folders are chosen with `canChooseDirectories`).
    static var openPanelTypes: [UTType] {
        RmskinPackage.supportedFileExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
    }

    /// What `open` does with a URL.
    enum Disposition: Equatable {
        /// A .rmskin, a ZIP archive or a folder: inspected and, once confirmed, installed.
        case install
        /// The Skins folder or a folder inside it: nothing to install.
        case alreadyInSkinsFolder
        /// A folder that holds the Skins folder (the home folder, Deskset's Application Support folder…): refused too
        /// (it would copy every installed skin), with a message saying so.
        case containsSkinsFolder
        /// Anything else.
        case unsupported
    }

    static func disposition(of url: URL, skinsDirectory: URL) -> Disposition {
        guard RmskinPackage.canInspect(url) else { return .unsupported }
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
           RmskinPackage.folder(url, overlaps: skinsDirectory) {
            // Same normalisation as `RmskinPackage.folder(_:overlaps:)`: links resolved, case-insensitive.
            func normalized(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
            let folder = normalized(url), skins = normalized(skinsDirectory)
            return folder != skins && skins.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
                ? .containsSkinsFolder : .alreadyInSkinsFolder
        }
        return .install
    }

    /// Text of the alert for a folder that holds the Skins folder.
    static var containsSkinsFolderMessage: String { L("Choose the folder of the skin you want to install, not a folder that holds Deskset’s Skins folder. Skins already in the Skins folder are installed; if one is missing from the list, choose Refresh All in the Manage window.") }

    /// Double-clicked / dropped / chosen files and folders. Folders already in the Skins folder are refused before
    /// anything is copied (inspecting the Skins folder would copy every installed skin).
    func open(_ urls: [URL]) {
        var packages: [URL] = []
        var others: [URL] = []
        var installed: [URL] = []
        var holders: [URL] = []
        for url in urls {
            switch SkinInstallFlow.disposition(of: url, skinsDirectory: app.skinsDirectory) {
            case .install: packages.append(url)
            case .alreadyInSkinsFolder: installed.append(url)
            case .containsSkinsFolder: holders.append(url)
            case .unsupported: others.append(url)
            }
        }
        if !others.isEmpty {
            app.alert(others.count == 1 ? L("Can’t open “%@”", others[0].lastPathComponent) : L("Can’t open these files"),
                      L("Deskset installs skin packages (.rmskin), ZIP archives with skins and folders with skins."))
        }
        if !installed.isEmpty {
            app.alert(installed.count == 1 ? L("“%@” is already in the Skins folder", installed[0].lastPathComponent)
                          : L("These folders are already in the Skins folder"),
                      SkinInstallFlow.message(for: .alreadyInSkinsFolder), style: .informational)
        }
        if !holders.isEmpty {
            app.alert(holders.count == 1 ? L("“%@” contains Deskset’s Skins folder", holders[0].lastPathComponent)
                          : L("These folders contain Deskset’s Skins folder"),
                      SkinInstallFlow.containsSkinsFolderMessage, style: .informational)
        }
        queue += packages
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        guard !app.isTerminating else { queue.removeAll(); return }
        if app.isLoadingLayout {
            if layoutWaitObserver == nil {
                layoutWaitObserver = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged,
                    object: app, queue: .main) { [weak self] _ in
                    guard let self, !self.app.isLoadingLayout else { return }
                    if let observer = self.layoutWaitObserver { NotificationCenter.default.removeObserver(observer) }
                    self.layoutWaitObserver = nil
                    self.next()
                }
            }
            return
        }
        busy = true
        options = Options()
        let url = queue.removeFirst()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RmskinPackage.inspect(url) }
            DispatchQueue.main.async { self.inspected(url, result) }
        }
    }

    private func finish() {
        busy = false
        layoutBackupBeforeInstall = nil
        app.layouts.installationFinished()
        next()
    }

    private func inspected(_ url: URL, _ result: Result<RmskinInspection, Error>) {
        switch result {
        case .failure(let error):
            showError(url, error)
            finish()
        case .success(let inspection):
            let summary = InstallSummary(inspection, packageName: url.lastPathComponent,
                                         skinsDirectory: app.skinsDirectory)
            confirm(summary, headerImage: inspection.headerImageURL.flatMap { NSImage(contentsOf: $0) }) { ok, options in
                if ok {
                    self.options = options
                    self.applyInstalledLayout = options.applyIncludedLayout && summary.layoutToApply != nil
                    self.install(inspection, packageURL: url)
                } else {
                    inspection.cleanup()
                    self.finish()
                }
            }
        }
    }

    /// Self-tests: runs right before the package's skin is loaded (a test makes that load fail).
    static var beforeLoadingPackageSkin: ((AppController) -> Void)?
    /// Self-tests exercise the same install path with the confirmation checkbox unchecked.
    static var applyLayoutAfterInstallForTesting: Bool?
    /// Self-tests choose each package independently, starting from the same defaults as the confirmation controls.
    static var optionsForTesting: ((InstallSummary, Options) -> Options)?
    static var confirmForTesting: ((InstallSummary, Options) -> Bool)?

    /// How long the installer waits for the skins it stopped to close before it replaces their files anyway.
    static let closeTimeout: TimeInterval = 10

    private func install(_ inspection: RmskinInspection, packageURL: URL) {
        let replacesDesktop = applyInstalledLayout && !inspection.layouts.isEmpty
        // Skins running from a root config that is about to be replaced are stopped first and reloaded afterwards. Their
        // files are replaced once they have closed: an OnCloseAction may still write to them (!WriteKeyValue), on the
        // skin's thread.
        let roots = Set(inspection.rootConfigs.map { $0.lowercased() })
        let affected = app.sortedControllers
            .filter { replacesDesktop || roots.contains(String($0.config.split(separator: "\\").first ?? "").lowercased()) }
            .map { ($0.config, $0.file) }
        waitsForSkinsToClose = true
        if replacesDesktop {
            // An included layout replaces the whole desktop. Finish its close actions before replacing package
            // files, then capture their settings while the old variant list is still available.
            app.layouts.prepareInstallation { [self] backup in
                waitsForSkinsToClose = false
                guard let backup, !app.isTerminating else {
                    inspection.cleanup()
                    if !app.isTerminating {
                        app.alert(L("Couldn’t install “%@”", packageURL.lastPathComponent),
                                  L("The current skins did not finish closing. No package files were replaced. Quit and reopen Deskset, then try again."), style: .warning)
                    }
                    finish()
                    return
                }
                layoutBackupBeforeInstall = backup
                replaceFiles(inspection, packageURL: packageURL, affected: affected)
            }
            return
        }
        let stopped = affected.compactMap { app.suspend(config: $0.0) }
        app.whenClosed(stopped, timeout: SkinInstallFlow.closeTimeout) { [self] in
            waitsForSkinsToClose = false
            replaceFiles(inspection, packageURL: packageURL, affected: affected)
        }
    }

    private func replaceFiles(_ inspection: RmskinInspection, packageURL: URL, affected: [(String, String)]) {
        let skins = app.skinsDirectory, layouts = app.layoutsDirectory, backups = app.backupsDirectory
        let backupSkins = options.backupSkins
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins, layoutsDirectory: layouts,
                                            backupDirectory: backups, backupSkins: backupSkins)
            }
            inspection.cleanup()
            DispatchQueue.main.async {
                self.installed(result, inspection: inspection, packageURL: packageURL, affected: affected)
            }
        }
    }

    private func installed(_ result: Result<RmskinInstallResult, Error>, inspection: RmskinInspection,
                           packageURL: URL, affected: [(String, String)]) {
        app.rescanLibrary()
        // Fonts of the installed root configs (new, replaced or removed with the old version) are read again before
        // any of their skins is loaded, and skins already laid out are measured again with them.
        if case .success(let r) = result {
            let folders = r.installedRootConfigs.map {
                app.skinsDirectory.appendingPathComponent($0, isDirectory: true)
                    .appendingPathComponent("@Resources/Fonts", isDirectory: true).path
            }
            if Fonts.rescanFolders(folders) { app.fontsChanged() }
        }
        if case .success(let result) = result, applyInstalledLayout, let layout = result.layoutToLoad {
            Log.write("Installed \(packageURL.lastPathComponent): \(result.installedRootConfigs.joined(separator: ", "))")
            app.layouts.load(named: layout, backup: layoutBackupBeforeInstall, fromInstaller: true) { [self] loaded in
                // A bad layout (or an unwritable @Backup) leaves the old desktop in place. The installer had already
                // suspended the replaced roots; restore those that have not been restored by the layout controller.
                if !loaded, !app.isTerminating {
                    for (config, file) in affected where app.controller(for: config) == nil {
                        if app.config(named: config)?.files.contains(where: {
                            $0.caseInsensitiveCompare(file) == .orderedSame
                        }) == true {
                            app.inTurn { $0.activate(config: config, file: file) }
                        }
                    }
                }
                app.inTurn { [self] app in
                    if !app.isTerminating {
                        app.showManageWindow(selecting: nil, file: nil, tab: .layouts)
                        let notes = result.warnings.filter { !inspection.warnings.contains($0) }
                        if !notes.isEmpty {
                            app.alert(L("“%@” was installed", result.manifest.name.isEmpty ? packageURL.lastPathComponent : result.manifest.name),
                                      notes.joined(separator: "\n\n"), style: .informational)
                        }
                    }
                    finish()
                    return nil
                }
            }
            return
        }
        // The skin the package loads is loaded once, below (reloading it here first would run its OnRefreshAction
        // and OnCloseAction for a skin that is replaced a moment later).
        let packageSkin: String? = {
            guard options.loadIncludedSkins, case .success(let r) = result,
                  let config = r.skinToLoadConfig else { return nil }
            return SkinLibrary.normalizedConfigName(config).lowercased()
        }()
        // The skins that were running load again one after another (`AppController.inTurn`), as on the main thread: a
        // suite's skin whose OnRefreshAction unloads another one finds that one's old copy, not its new one.
        for (config, file) in affected {
            if config.lowercased() == packageSkin { continue }
            if app.config(named: config)?.files.contains(where: { $0.caseInsensitiveCompare(file) == .orderedSame }) == true {
                app.inTurn { $0.activate(config: config, file: file) }
            } else {
                app.state.update(config) { $0.active = false }
            }
        }
        switch result {
        case .failure(let error):
            showError(packageURL, error)
            finish()
        case .success(let r):
            Log.write("Installed \(packageURL.lastPathComponent): \(r.installedRootConfigs.joined(separator: ", "))")
            if !r.installedFonts.isEmpty {
                Log.write("Installed fonts into @Resources/Fonts: \(r.installedFonts.joined(separator: ", "))")
            }
            // Whether the package's skin loaded is known once its load has settled: on another thread `activate`
            // returns before the skin loaded.
            var packageWindow: SkinWindowController?
            if options.loadIncludedSkins, let config = r.skinToLoadConfig {
                app.inTurn { app in
                    SkinInstallFlow.beforeLoadingPackageSkin?(app)
                    packageWindow = app.activate(config: config, file: r.skinToLoadFile, fade: true)
                    return packageWindow
                }
            }
            app.inTurn { [self] app in
                var loaded: String?
                var restored: SkinWindowController?
                if let config = r.skinToLoadConfig, let c = packageWindow, !c.loadFailed {
                    loaded = config
                } else if let key = packageSkin, let previous = affected.first(where: { $0.0.lowercased() == key }),
                          app.config(named: previous.0)?.files.contains(where: {
                              $0.caseInsensitiveCompare(previous.1) == .orderedSame }) == true {
                    // The package's skin could not be loaded: bring back what was running.
                    restored = app.activate(config: previous.0, file: previous.1)
                }
                let newWarnings = r.warnings.filter { !inspection.warnings.contains($0) }
                let notes = newWarnings
                let select = loaded ?? r.installedRootConfigs.first
                app.showManageWindow(selecting: select, file: loaded == nil ? nil : r.skinToLoadFile)
                if !notes.isEmpty {
                    let name = r.manifest.name.isEmpty ? packageURL.lastPathComponent : r.manifest.name
                    app.alert(L("“%@” was installed", name), notes.joined(separator: "\n\n"), style: .informational)
                }
                finish()
                return restored
            }
        }
    }

    private func showError(_ url: URL, _ error: Error) {
        if case RmskinError.alreadyInSkinsFolder? = error as? RmskinError {
            app.alert(L("“%@” is already in the Skins folder", url.lastPathComponent),
                      SkinInstallFlow.message(for: .alreadyInSkinsFolder), style: .informational)
            return
        }
        let reason = (error as? RmskinError).map(SkinInstallFlow.message(for:)) ?? error.localizedDescription
        app.alert(L("Couldn’t install “%@”", url.lastPathComponent), reason, style: .critical)
    }

    /// User-facing text for an installer error.
    static func message(for error: RmskinError) -> String {
        switch error {
        case .notAPackage: return L("The file is not a skin package. It may be damaged or incomplete.")
        case .missingManifest: return L("The package has no RMSKIN.ini, so it can’t be installed.")
        case .nothingToInstall: return L("This file or folder doesn’t contain any Rainmeter skins.")
        case .alreadyInSkinsFolder:
            return L("Skins in Deskset’s Skins folder are already installed, so there is nothing to copy. If a skin placed there is missing from the list, choose Refresh All in the Manage window.")
        case .severalPackages(let names):
            let list = names.prefix(6).map { "“\($0)”" }.joined(separator: ", ") + (names.count > 6 ? ", …" : "")
            return L("It contains several skin packages (%@). Open them one at a time (extract the archive first when it is one).", list)
        case .unreadable, .extractionFailed:
            return error.description
        }
    }

    // MARK: Confirmation

    private func confirm(_ summary: InstallSummary, headerImage: NSImage?,
                         completion: @escaping (Bool, Options) -> Void) {
        guard app.presentsWindows else {
            var options = Options()
            options.applyIncludedLayout = Self.applyLayoutAfterInstallForTesting ?? true
            options = Self.optionsForTesting?(summary, options) ?? options
            completion(Self.confirmForTesting?(summary, options) ?? true, options)
            return
        }
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.subtitle
        alert.alertStyle = summary.pluginWarning == nil ? .informational : .warning
        alert.addButton(withTitle: L("Install"))
        alert.addButton(withTitle: L("Cancel"))
        let controls = OptionControls(summary: summary)
        alert.accessoryView = SkinInstallFlow.accessoryView(summary, headerImage: headerImage,
                                                          optionControls: controls)
        if let window = app.visibleManageWindow {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn, controls.options) }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            completion(alert.runModal() == .alertFirstButtonReturn, controls.options)
        }
    }

    /// The body of the confirmation: header image, skins, layouts, what loads afterwards, warnings.
    static func accessoryView(_ summary: InstallSummary, headerImage: NSImage?,
                              optionControls: OptionControls? = nil) -> NSView {
        let width: CGFloat = 400
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        if let headerImage {
            let image = NSImageView(image: headerImage)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 4
            image.layer?.masksToBounds = true
            let aspect = headerImage.size.width > 0 ? headerImage.size.height / headerImage.size.width : 0.15
            image.widthAnchor.constraint(equalToConstant: width).isActive = true
            image.heightAnchor.constraint(equalToConstant: min(max(width * aspect, 20), 160)).isActive = true
            stack.addArrangedSubview(image)
        }

        func label(_ text: String, bold: Bool = false, secondary: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.preferredMaxLayoutWidth = width
            l.font = bold ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            if secondary { l.textColor = .secondaryLabelColor }
            return l
        }

        if let note = summary.formatNote {
            stack.addArrangedSubview(label(note, secondary: true))
        }
        stack.addArrangedSubview(label(L("Skins to install:"), bold: true))
        for line in summary.skins {
            var text = "•  " + line.text
            if !line.configs.isEmpty {
                let shown = line.configs.prefix(8).joined(separator: ", ")
                text += " (\(shown)\(line.configs.count > 8 ? ", and \(line.configs.count - 8) more" : ""))"
            }
            if let detail = line.detail { text += " — \(detail)" }
            stack.addArrangedSubview(label(text))
        }
        if !summary.layouts.isEmpty {
            stack.addArrangedSubview(label(L("Layouts: %@", summary.layouts.joined(separator: ", ")),
                                           secondary: true))
        }
        if !summary.fonts.isEmpty {
            let shown = summary.fonts.prefix(8).joined(separator: ", ")
            let more = summary.fonts.count > 8 ? " " + L("(+%lld more)", summary.fonts.count - 8) : ""
            let text = L("Fonts included for these skins (not installed system-wide): %@", shown + more)
            stack.addArrangedSubview(label(text, secondary: true))
        }
        stack.addArrangedSubview(optionControls ?? OptionControls(summary: summary))
        let warnings = (summary.pluginWarning.map { [$0] } ?? []) + summary.warnings
        for warning in warnings.prefix(12) {
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: L("Warning")) ?? NSImage())
            icon.contentTintColor = .systemOrange
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let text = label(warning)
            text.preferredMaxLayoutWidth = width - 24
            let row = NSStackView(views: [icon, text])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            stack.addArrangedSubview(row)
        }
        if warnings.count > 12 {
            stack.addArrangedSubview(label(L("… and %lld more notes.", warnings.count - 12), secondary: true))
        }
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = stack.fittingSize
        return stack
    }
}
