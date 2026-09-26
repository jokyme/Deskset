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
    var pluginWarning: String?
    var warnings: [String]
    /// Font files the installation adds to the skins' `@Resources/Fonts` folders.
    var fonts: [String]
    /// How the input was recognised when it is not a Skin Packager .rmskin (a plain archive or folder, a legacy
    /// Rainstaller package); nil for a .rmskin.
    var formatNote: String?

    /// Text of the package's own plugin warning, replaced by `pluginWarning`.
    private static let pluginWarningPrefix = "The package includes Windows plugins"

    init(_ inspection: RmskinInspection, packageName: String, skinsDirectory: URL) {
        let m = inspection.manifest
        let isFolder = inspection.sourceFolder != nil
        let name = m.name.isEmpty ? (isFolder ? packageName : (packageName as NSString).deletingPathExtension) : m.name
        title = "Install “\(name)”?"
        var parts: [String] = []
        if !m.author.isEmpty { parts.append("By \(m.author)") }
        if !m.version.isEmpty { parts.append("Version \(m.version)") }
        let kind = isFolder ? "folder" : "archive"
        switch m.packageFormat {
        case .rmskin:
            formatNote = nil
            subtitle = parts.isEmpty ? "The package does not say who made it." : parts.joined(separator: " · ")
        case .rainstaller:
            formatNote = "A package made for the installer of old Rainmeter versions (Rainstaller)."
            subtitle = parts.isEmpty ? "The package does not say who made it." : parts.joined(separator: " · ")
        case .plain:
            // No RMSKIN.ini: the root configs below were detected from the .ini files (see RmskinPlainArchive).
            formatNote = "This \(kind) is not a skin package made with Rainmeter’s Skin Packager, so Deskset found "
                + "the skins in it by itself. Check the list below before installing."
                + (isFolder ? " The folder is copied; the original stays where it is." : "")
            subtitle = parts.isEmpty ? "A plain \(kind): no author or version information." : parts.joined(separator: " · ")
        }
        fonts = inspection.fontNames

        let existing = Set(inspection.existingRootConfigs(in: skinsDirectory).map { $0.lowercased() })
        let packaged = InstallSummary.packagedConfigs(inspection)
        skins = inspection.rootConfigs.map { root in
            let configs = packaged.filter { $0.lowercased().hasPrefix(root.lowercased() + "\\") }
                .map { String($0.dropFirst(root.count + 1)) }
            guard existing.contains(root.lowercased()) else { return Line(text: root, detail: nil, configs: configs) }
            return Line(text: root, detail: m.mergeSkins ? "adds to the installed skins"
                        : "replaces the installed version; the old one is kept in Backups", configs: configs)
        }
        layouts = inspection.layouts

        if m.loadType.caseInsensitiveCompare("Layout") == .orderedSame {
            loadAfterInstall = m.load.isEmpty ? nil : "Layout “\(m.load)” (layouts can’t be applied yet)"
        } else if !m.load.isEmpty {
            loadAfterInstall = m.load.replacingOccurrences(of: "/", with: "\\")
        }

        if inspection.containsPlugins {
            let list = inspection.pluginNames.isEmpty ? "" : " (\(inspection.pluginNames.joined(separator: ", ")))"
            pluginWarning = "This package includes Windows plugins\(list). Plugins can’t run on macOS, "
                + "so parts of these skins may show no data."
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
    private unowned let app: AppController
    private var queue: [URL] = []
    private var busy = false

    init(app: AppController) {
        self.app = app
    }

    /// Nothing queued or in progress.
    var isIdle: Bool { !busy && queue.isEmpty }

    /// Open panel for "Install Skin…": .rmskin packages, ZIP archives and skin folders.
    func chooseAndInstall() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Install Skin"
        panel.message = "Choose a skin package (.rmskin), a ZIP archive or a folder with skins to install."
        panel.prompt = "Install"
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
    static let containsSkinsFolderMessage = "Choose the folder of the skin you want to install, not a folder that "
        + "holds Deskset’s Skins folder. Skins already in the Skins folder are installed; if one is missing from the "
        + "list, choose Refresh All in the Manage window."

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
            app.alert("Can’t open \(others.count == 1 ? "“\(others[0].lastPathComponent)”" : "these files")",
                      "Deskset installs skin packages (.rmskin), ZIP archives with skins and folders with skins.")
        }
        if !installed.isEmpty {
            app.alert(installed.count == 1 ? "“\(installed[0].lastPathComponent)” is already in the Skins folder"
                          : "These folders are already in the Skins folder",
                      SkinInstallFlow.message(for: .alreadyInSkinsFolder), style: .informational)
        }
        if !holders.isEmpty {
            app.alert(holders.count == 1 ? "“\(holders[0].lastPathComponent)” contains Deskset’s Skins folder"
                          : "These folders contain Deskset’s Skins folder",
                      SkinInstallFlow.containsSkinsFolderMessage, style: .informational)
        }
        queue += packages
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let url = queue.removeFirst()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RmskinPackage.inspect(url) }
            DispatchQueue.main.async { self.inspected(url, result) }
        }
    }

    private func finish() {
        busy = false
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
            confirm(summary, headerImage: inspection.headerImageURL.flatMap { NSImage(contentsOf: $0) }) { ok in
                if ok {
                    self.install(inspection, packageURL: url)
                } else {
                    inspection.cleanup()
                    self.finish()
                }
            }
        }
    }

    private func install(_ inspection: RmskinInspection, packageURL: URL) {
        // Skins running from a root config that is about to be replaced are stopped first and reloaded afterwards.
        let roots = Set(inspection.rootConfigs.map { $0.lowercased() })
        let affected = app.sortedControllers
            .filter { roots.contains(String($0.config.split(separator: "\\").first ?? "").lowercased()) }
            .map { ($0.config, $0.file) }
        for (config, _) in affected { app.suspend(config: config) }

        let skins = app.skinsDirectory, layouts = app.layoutsDirectory, backups = app.backupsDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try RmskinInstaller.install(inspection: inspection, skinsDirectory: skins, layoutsDirectory: layouts,
                                            backupDirectory: backups)
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
        // The skin the package loads is loaded once, below (reloading it here first would run its OnRefreshAction
        // and OnCloseAction for a skin that is replaced a moment later).
        let packageSkin: String? = {
            guard case .success(let r) = result, let config = r.skinToLoadConfig else { return nil }
            return SkinLibrary.normalizedConfigName(config).lowercased()
        }()
        for (config, file) in affected {
            if config.lowercased() == packageSkin { continue }
            if app.config(named: config)?.files.contains(where: { $0.caseInsensitiveCompare(file) == .orderedSame }) == true {
                app.activate(config: config, file: file)
            } else {
                app.state.update(config) { $0.active = false }
            }
        }
        switch result {
        case .failure(let error):
            showError(packageURL, error)
        case .success(let r):
            Log.write("Installed \(packageURL.lastPathComponent): \(r.installedRootConfigs.joined(separator: ", "))")
            if !r.installedFonts.isEmpty {
                Log.write("Installed fonts into @Resources/Fonts: \(r.installedFonts.joined(separator: ", "))")
            }
            var loaded: String?
            if let config = r.skinToLoadConfig, app.activate(config: config, file: r.skinToLoadFile, fade: true) != nil {
                loaded = config
            } else if let key = packageSkin, let previous = affected.first(where: { $0.0.lowercased() == key }),
                      app.config(named: previous.0)?.files.contains(where: {
                          $0.caseInsensitiveCompare(previous.1) == .orderedSame }) == true {
                // The package's skin could not be loaded: bring back what was running.
                app.activate(config: previous.0, file: previous.1)
            }
            let newWarnings = r.warnings.filter { !inspection.warnings.contains($0) }
            var notes = newWarnings
            if let layout = r.layoutToLoad {
                notes.append("The package asks to apply the layout “\(layout)”. Deskset can’t apply layouts yet; "
                             + "load its skins from the Manage window.")
            }
            let select = loaded ?? r.installedRootConfigs.first
            app.showManageWindow(selecting: select, file: loaded == nil ? nil : r.skinToLoadFile)
            if !notes.isEmpty {
                let name = r.manifest.name.isEmpty ? packageURL.lastPathComponent : r.manifest.name
                app.alert("“\(name)” was installed", notes.joined(separator: "\n\n"), style: .informational)
            }
        }
        finish()
    }

    private func showError(_ url: URL, _ error: Error) {
        if case RmskinError.alreadyInSkinsFolder? = error as? RmskinError {
            app.alert("“\(url.lastPathComponent)” is already in the Skins folder",
                      SkinInstallFlow.message(for: .alreadyInSkinsFolder), style: .informational)
            return
        }
        let reason = (error as? RmskinError).map(SkinInstallFlow.message(for:)) ?? error.localizedDescription
        app.alert("Couldn’t install “\(url.lastPathComponent)”", reason, style: .critical)
    }

    /// User-facing text for an installer error.
    static func message(for error: RmskinError) -> String {
        switch error {
        case .notAPackage: return "The file is not a skin package. It may be damaged or incomplete."
        case .missingManifest: return "The package has no RMSKIN.ini, so it can’t be installed."
        case .nothingToInstall: return "This file or folder doesn’t contain any Rainmeter skins."
        case .alreadyInSkinsFolder:
            return "Skins in Deskset’s Skins folder are already installed, so there is nothing to copy. "
                + "If a skin placed there is missing from the list, choose Refresh All in the Manage window."
        case .severalPackages(let names):
            let list = names.prefix(6).map { "“\($0)”" }.joined(separator: ", ") + (names.count > 6 ? ", …" : "")
            return "It contains several skin packages (\(list)). Open them one at a time (extract the archive "
                + "first when it is one)."
        case .unreadable, .extractionFailed:
            return error.description
        }
    }

    // MARK: Confirmation

    private func confirm(_ summary: InstallSummary, headerImage: NSImage?, completion: @escaping (Bool) -> Void) {
        guard app.presentsWindows else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.subtitle
        alert.alertStyle = summary.pluginWarning == nil ? .informational : .warning
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = SkinInstallFlow.accessoryView(summary, headerImage: headerImage)
        if let window = app.visibleManageWindow {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// The body of the confirmation: header image, skins, layouts, what loads afterwards, warnings.
    static func accessoryView(_ summary: InstallSummary, headerImage: NSImage?) -> NSView {
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
        stack.addArrangedSubview(label("Skins to install:", bold: true))
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
            stack.addArrangedSubview(label("Layouts (saved, not applied): " + summary.layouts.joined(separator: ", "),
                                           secondary: true))
        }
        if !summary.fonts.isEmpty {
            let shown = summary.fonts.prefix(8).joined(separator: ", ")
            let more = summary.fonts.count > 8 ? ", and \(summary.fonts.count - 8) more" : ""
            let text = "Fonts included for these skins: \(shown)\(more) (not installed system-wide)"
            stack.addArrangedSubview(label(text, secondary: true))
        }
        if let load = summary.loadAfterInstall {
            stack.addArrangedSubview(label("Loads after installing: \(load)", secondary: true))
        }
        let warnings = (summary.pluginWarning.map { [$0] } ?? []) + summary.warnings
        for warning in warnings.prefix(12) {
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: "Warning") ?? NSImage())
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
            stack.addArrangedSubview(label("… and \(warnings.count - 12) more notes.", secondary: true))
        }
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = stack.fittingSize
        return stack
    }
}
