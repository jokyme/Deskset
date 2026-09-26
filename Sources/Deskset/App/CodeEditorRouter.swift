import AppKit
import DesksetCore

/// Launching apps and tools, behind a protocol so self-tests record what would have been opened instead of
/// launching editors.
protocol CodeEditorOpening: AnyObject {
    /// `NSWorkspace.open(_:withApplicationAt:)`; `completion` runs on the main queue.
    func open(_ urls: [URL], withApplicationAt app: URL, completion: @escaping (Error?) -> Void)
    /// Starts a command-line tool without waiting for it.
    func run(_ executable: URL, arguments: [String]) throws
}

final class WorkspaceEditorOpener: CodeEditorOpening {
    func open(_ urls: [URL], withApplicationAt app: URL, completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func run(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// The single entry point for opening skin code (docs/editor-design.md §6): the skin menu's "Edit in <app>", the Manage
/// window's Edit, `!EditSkin`, the editor's source links, files Deskset is asked to open (a skin running
/// `["#CONFIGEDITOR#" "#@#Variables.inc"]` while the built-in editor is chosen) — all come here and follow
/// Settings ▸ Editor ▸ "Edit code with".
///
/// - Built-in: the skin editor opens on the skin that owns the file (its main file or an included one; an unloaded
///   skin file is loaded first) and reveals the line.
/// - An app: that app, at the line when it supports it (`CodeEditorLaunch`). An app that has been uninstalled falls
///   back to the built-in editor, with a one-time notice.
/// - System default: the app macOS uses for that file type, at the line when it is a known editor.
///
/// Never calls `NSWorkspace.setDefaultApplication`: the choice is Deskset's own and does not change the user's file
/// associations. The log file keeps opening in the system default app (`Workspace.edit`).
enum CodeEditorRouter {
    /// Swapped by self-tests for a recorder.
    static var opener: CodeEditorOpening = WorkspaceEditorOpener()
    static var locator: ApplicationLocating = WorkspaceApplicationLocator()
    /// The running app (set at launch): `#CONFIGEDITOR#` follows its preference. Headless tools leave it nil.
    static weak var primaryApp: AppController?
    /// Apps already reported as missing in this session (the notice is shown once).
    private static var reportedMissing: Set<String> = []
    private static var cachedConfigEditor: (preferences: EditorPreferences, path: String?, time: TimeInterval)?

    /// At launch: `#CONFIGEDITOR#` follows `app`, and the old UserDefaults live-reload switch moves into state.json.
    static func install(app: AppController) {
        primaryApp = app
        app.state.migrateLegacyEditorPreferences(from: UserDefaults.standard)
    }

    /// Where a file goes.
    enum Route: Equatable {
        case builtIn
        /// The chosen app is gone: the built-in editor instead.
        case builtInInstead(missingApp: String)
        case external(CodeEditorApp, CodeEditorCommand)
    }

    /// The decision for opening `file` at `line` with these preferences (no side effects).
    static func route(file: URL, line: Int?, preferences: EditorPreferences, locator: ApplicationLocating,
                      ownBundle: URL = Bundle.main.bundleURL,
                      ownBundleID: String? = Bundle.main.bundleIdentifier) -> Route {
        func external(_ url: URL, _ id: String?) -> Route {
            let editor = CodeEditorApp(url: url, bundleID: id ?? locator.bundleIdentifier(ofApplicationAt: url))
            if isOwnApp(editor, ownBundle: ownBundle, ownBundleID: ownBundleID) { return .builtIn }
            return .external(editor, CodeEditorLaunch.command(for: editor, file: file, line: line))
        }
        switch preferences.codeEditor {
        case .builtIn:
            return .builtIn
        case .app(let id, let path):
            guard let url = CodeEditorDetector.resolve(bundleID: id, lastKnownPath: path, locator: locator) else {
                let name = path.isEmpty ? id : CodeEditorApp.displayName(of: URL(fileURLWithPath: path))
                return .builtInInstead(missingApp: name)
            }
            return external(url, id.isEmpty ? nil : id)
        case .systemDefault:
            // Deskset as the default ("Always Open With" in Finder) means the built-in editor, never a loop.
            guard let url = locator.defaultApplicationURL(toOpen: file) else {
                return external(textEdit(locator), "com.apple.TextEdit")
            }
            return external(url, nil)
        }
    }

    static func isOwnApp(_ editor: CodeEditorApp, ownBundle: URL = Bundle.main.bundleURL,
                         ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if let id = editor.bundleID, let own = ownBundleID, id.caseInsensitiveCompare(own) == .orderedSame { return true }
        return editor.url.standardizedFileURL.path == ownBundle.standardizedFileURL.path
    }

    static func textEdit(_ locator: ApplicationLocating) -> URL {
        locator.applicationURL(bundleID: "com.apple.TextEdit") ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    }

    // MARK: Opening

    /// Opens `file` for editing, at `line` (1-based) when given, the way Settings ▸ Editor says.
    static func open(file: URL, line: Int? = nil, app: AppController) {
        let file = file.standardizedFileURL
        switch route(file: file, line: line, preferences: app.state.editor, locator: locator) {
        case .builtIn:
            if !openBuiltIn(file: file, line: line, app: app) { openOutsideSkins(file: file, line: line, app: app) }
        case .builtInInstead(let name):
            Log.write("\(name) is no longer installed; opening \(file.lastPathComponent) in the built-in editor",
                      level: .warning)
            let notice = reportedMissing.insert(name).inserted
                ? "\(name) is no longer installed — using the built-in editor" : nil
            if !openBuiltIn(file: file, line: line, app: app, notice: notice) {
                openOutsideSkins(file: file, line: line, app: app)
            }
        case .external(let editor, let command):
            execute(command, file: file, appURL: editor.url)
        }
    }

    /// Opens in `editor` regardless of the preference (the editor's "Open With" items).
    static func open(file: URL, line: Int?, in editor: CodeEditorApp) {
        execute(CodeEditorLaunch.command(for: editor, file: file, line: line), file: file.standardizedFileURL,
                appURL: editor.url)
    }

    /// The external app the preference names right now (nil for the built-in editor or a missing app): for
    /// "Open in <App>" titles.
    static func externalEditor(for preferences: EditorPreferences, file: URL? = nil) -> CodeEditorApp? {
        let sample = file ?? FileManager.default.temporaryDirectory.appendingPathComponent("Deskset-sample.ini")
        if case .external(let editor, _) = route(file: sample, line: nil, preferences: preferences, locator: locator) {
            return editor
        }
        return nil
    }

    /// The skin editor on the skin owning `file`, revealing `line` (and showing `notice` as a warning toast). False
    /// when no skin owns it (not a skin file, or an included file of a skin that is not loaded).
    @discardableResult
    static func openBuiltIn(file: URL, line: Int?, app: AppController, notice: String? = nil) -> Bool {
        func show(_ c: SkinController) {
            if let inspector = app.inspector, inspector.controller === c {
                // Already editing this skin (the editor is open: it forgets its skin when it closes): no re-attach (it
                // would rebuild the layers and the inspector), but the window comes in front of the other apps'
                // windows, out of the Dock if need be (the request may come from a menu of the menu bar icon or a
                // click on a skin, which do not activate the app).
                app.bringToFront(inspector)
            } else {
                app.showInspector(for: c)
            }
            // A new editor window is built in steps: the line is revealed once it is.
            guard let inspector = app.inspector else { return }
            inspector.afterOpening { [weak inspector] in
                inspector?.revealInCode(file: file, line: line)
                if let notice { inspector?.toast.show(notice, error: true) }
            }
        }
        if let c = owningController(of: file, in: app) {
            show(c)
            return true
        }
        guard let target = skinFile(for: file, in: app) else { return false }
        // The built-in editor edits running skins: a skin file of an unloaded config (or another variant of a loaded
        // one) is loaded first — on the next run loop turn, like every load a bang asks for (`!EditSkin` may come
        // from a skin's own action, and loading runs the new skin's OnRefreshAction).
        Log.write("Loading \(target.config)\\\(target.file) to edit it")
        app.later(loading: target.config) { app in
            if let c = app.activate(config: target.config, file: target.file) { show(c) }
        }
        return true
    }

    /// The running skin that reads `file`: the one being edited when it does (an include shared by several skins
    /// stays in the open editor), else one whose main file it is, else the first (in load order) including it.
    static func owningController(of file: URL, in app: AppController) -> SkinController? {
        let key = comparablePath(file)
        func owns(_ c: SkinController) -> Bool {
            !c.isStopped && c.skin.sourceFiles.contains { comparablePath($0) == key }
        }
        if let edited = app.inspector?.controller, owns(edited) { return edited }
        let running = app.sortedControllers
        if let main = running.first(where: { !$0.isStopped && comparablePath($0.skin.fileURL) == key }) { return main }
        return running.first(where: owns)
    }

    /// The config and file name when `file` is a skin (.ini directly in a config folder).
    static func skinFile(for file: URL, in app: AppController) -> (config: String, file: String)? {
        guard file.pathExtension.lowercased() == "ini" else { return nil }
        let folder = comparablePath(file.deletingLastPathComponent())
        func find() -> (String, String)? {
            for entry in app.library where comparablePath(entry.directory) == folder {
                if let name = entry.files.first(where: { $0.caseInsensitiveCompare(file.lastPathComponent) == .orderedSame }) {
                    return (entry.name, name)
                }
            }
            return nil
        }
        if let hit = find() { return hit }
        // A skin added in Finder since the last scan.
        guard comparablePath(file).hasPrefix(comparablePath(app.skinsDirectory) + "/") else { return nil }
        app.rescanLibrary()
        return find()
    }

    /// Paths compared the way the default (case-insensitive) Mac file system does, symlinks resolved.
    static func comparablePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    /// A file no running skin owns, with the built-in editor chosen: a text file opens in a code window of the
    /// built-in editor — never in the Launch Services default, which on many Macs is an IDE the user did not choose
    /// for this. Anything else (an image, a missing file) goes to the app macOS uses for it, or TextEdit when that
    /// would be Deskset itself.
    private static func openOutsideSkins(file: URL, line: Int?, app: AppController) {
        if FileManager.default.fileExists(atPath: file.path), CodeFileWindowController.isTextFile(file),
           app.showCodeFile(file, line: line) {
            return
        }
        var preferences = EditorPreferences()
        preferences.codeEditor = .systemDefault
        switch route(file: file, line: line, preferences: preferences, locator: locator) {
        case .external(let editor, let command):
            execute(command, file: file, appURL: editor.url)
        case .builtIn, .builtInInstead:
            execute(.open([file], app: textEdit(locator)), file: file, appURL: textEdit(locator))
        }
    }

    /// Carries out a command; a line-jump URL or tool that fails opens the file itself in the app.
    static func execute(_ command: CodeEditorCommand, file: URL, appURL: URL) {
        let opener = self.opener
        func openFile() {
            opener.open([file], withApplicationAt: appURL) { error in
                if let error {
                    Log.write("Could not open \(file.path) in \(appURL.lastPathComponent): \(error.localizedDescription)",
                              level: .error)
                }
            }
        }
        switch command {
        case .open(let urls, let app):
            opener.open(urls, withApplicationAt: app) { error in
                guard let error else { return }
                Log.write("\(app.lastPathComponent) did not open \(urls.first?.absoluteString ?? ""): "
                          + error.localizedDescription, level: .warning)
                if urls != [file] { openFile() }
            }
        case .run(let executable, let arguments):
            do {
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: executable.path])
                }
                try opener.run(executable, arguments: arguments)
            } catch {
                Log.write("Could not run \(executable.path): \(error.localizedDescription); opening the file instead",
                          level: .warning)
                openFile()
            }
        }
    }

    // MARK: Files opened with Deskset

    /// At most this many files are opened from one request, so a mistaken drop of a folder's worth of files does not
    /// open dozens of editor windows.
    static let maxOpenedFiles = 16

    /// Whether a file Deskset is asked to open goes to the code editor: every file except what the skin installer
    /// takes (`RmskinPackage.canInspect`: .rmskin packages, ZIP archives of skins — Deskset is an Open With choice for
    /// them — and folders, which the installer explains how to add). With the built-in editor chosen,
    /// `#CONFIGEDITOR#` is Deskset, so skins hand it whatever they edit — `.ini`/`.inc`/`.lua`, but just as often
    /// `#@#Settings.cfg`, `.json`, `.xml`, `.css`, `.md`, `.log` or a file with no extension — and each must still
    /// open somewhere: a text file no running skin owns opens in a code window of the built-in editor, anything else
    /// in its system default app (`openOutsideSkins`). A file that does not exist is passed on too; the editor that
    /// opens it reports that.
    static func isEditableFile(_ url: URL) -> Bool {
        guard url.isFileURL, !RmskinPackage.canInspect(url) else { return false }
        var isDirectory: ObjCBool = false
        return !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// Opens the editable files among `urls` (Finder, `open -a`, a skin's `["#CONFIGEDITOR#" …]`) and returns the
    /// rest — .rmskin packages, ZIP archives, folders, non-file URLs — for the skin installer.
    static func routeOpenedFiles(_ urls: [URL], app: AppController) -> [URL] {
        var files: [URL] = [], rest: [URL] = []
        for url in urls {
            if isEditableFile(url) { files.append(url) } else { rest.append(url) }
        }
        for url in files.prefix(maxOpenedFiles) { open(file: url, line: nil, app: app) }
        if files.count > maxOpenedFiles {
            Log.write("Opened the first \(maxOpenedFiles) of \(files.count) files; ignored the rest", level: .warning)
        }
        return rest
    }

    // MARK: #CONFIGEDITOR#

    /// `#CONFIGEDITOR#` for these preferences: the chosen app, or Deskset itself for the built-in editor (and for a
    /// chosen app that is gone, since the built-in editor stands in for it). nil for the system default, which keeps
    /// `Workspace.configEditorPath`'s lookup of the .ini default app.
    static func configEditorPath(for preferences: EditorPreferences, locator: ApplicationLocating,
                                 ownBundle: URL = Bundle.main.bundleURL,
                                 ownBundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        switch preferences.codeEditor {
        case .builtIn:
            return ownBundle.path
        case .app(let id, let path):
            guard let url = CodeEditorDetector.resolve(bundleID: id, lastKnownPath: path, locator: locator),
                  !isOwnApp(CodeEditorApp(url: url, bundleID: id.isEmpty ? nil : id, name: "", family: .plain),
                            ownBundle: ownBundle, ownBundleID: ownBundleID) else { return ownBundle.path }
            return url.path
        case .systemDefault:
            return nil
        }
    }

    /// Read by `Workspace.configEditorPath` (skins may read the variable on every update, so the app lookup is
    /// cached for a minute, or until the preference changes). nil without a running app or for the system default.
    static var configEditorPathOverride: String? {
        guard let app = primaryApp else { return nil }
        let preferences = app.state.editor
        let now = ProcessInfo.processInfo.systemUptime
        if let c = cachedConfigEditor, c.preferences == preferences, now - c.time < 60 { return c.path }
        let path = configEditorPath(for: preferences, locator: locator)
        cachedConfigEditor = (preferences, path, now)
        return path
    }
}
