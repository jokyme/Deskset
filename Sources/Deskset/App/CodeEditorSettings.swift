import AppKit
import UniformTypeIdentifiers

// MARK: - Preferences

/// Settings ▸ Editor (docs/editor-design.md §6). Stored in state.json (`AppStateData.editor`) rather than in
/// UserDefaults, so self-tests — which use temporary state files — never read or change the user's choices.
struct EditorPreferences: Equatable {
    /// Which app edits skin code.
    enum CodeEditor: Equatable {
        /// Deskset's own skin editor with the code next to the canvas. The default for new *and* existing users: with
        /// nothing stored, files never go to the Launch Services default for .ini, which on many Macs is whatever IDE
        /// last declared .ini a "Configuration file" (which is why this setting exists).
        case builtIn
        /// An app picked in Settings. The bundle identifier finds it again after it moves or updates; the path is the
        /// copy the user picked, preferred while it exists (people with two copies of an editor).
        case app(bundleID: String, lastKnownPath: String)
        /// Whatever macOS opens each file with, looked up every time (never implied: only when chosen).
        case systemDefault
    }

    /// The editor's centre when a skin is opened with the skin menu's `Edit Skin…`; code actions (`!EditSkin`, the
    /// Manage window's Edit, source links) switch to Split regardless.
    enum OpenSkinsIn: String, CaseIterable {
        case design, split, code

        var title: String {
            switch self {
            case .design: return "Design"
            case .split: return "Split"
            case .code: return "Code"
            }
        }

        var help: String {
            switch self {
            case .design: return "Open skins with the canvas only"
            case .split: return "Open skins with the canvas and the code side by side"
            case .code: return "Open skins with the code only"
            }
        }
    }

    /// An app picked with "Other…", remembered so it stays in the pop-up after the user switches to another choice.
    struct StoredApp: Codable, Equatable {
        var bundleID: String
        var path: String
    }

    var codeEditor = CodeEditor.builtIn
    var openSkinsIn = OpenSkinsIn.design
    /// View ▸ Show Rainmeter Details (Settings ▸ Editor): INI option names next to the inspector's plain labels
    /// (otherwise only in tooltips), section names, and every setting (docs/editor-friendly.md §4).
    var showIniNames = false
    /// Points, clamped to `fontSizes`.
    var codeFontSize: Double = 12
    /// "Refresh the skin when the file is saved elsewhere" (the editor's live reload).
    var liveReload = true
    var otherApp: StoredApp?
    /// The first-run tips already shown ("T1", "T2", "T3"; docs/editor-friendly.md §12). Help ▸ Show Tips Again
    /// empties it.
    var seenTips: Set<String> = []
    /// Layers locked in the editor, by widget: config (lowercased) → section names (lowercased). Editor state only,
    /// never written to the skin's files (§9.6).
    var editorLocks: [String: Set<String>] = [:]
    /// Widgets (configs, lowercased) whose detected Background the user unlocked, so it is not locked by itself (§9.6).
    var unlockedBackgrounds: Set<String> = []
    /// View ▸ Show Content Outside the Widget: layers past the widget's edges are drawn ghosted (§9.10).
    var showsContentOutside = true
    /// The canvas Backdrop chosen for a widget (config, lowercased → `SkinCanvasView.Backdrop` raw value): the user's
    /// pick, or Dark picked once for a see-through widget with light content.
    var backdrops: [String: Int] = [:]

    static let fontSizes: ClosedRange<Double> = 9...32
    /// Where the skin editor kept live reload before it moved into state.json (migrated once, then unused).
    static let legacyLiveReloadKey = "InspectorAutoRefresh"

    init() {}

    /// Out-of-range values (a hand-edited state file) are brought back into range.
    mutating func normalize() {
        codeFontSize = codeFontSize.isFinite
            ? min(max(codeFontSize.rounded(), Self.fontSizes.lowerBound), Self.fontSizes.upperBound) : 12
        if case .app(let id, let path) = codeEditor, id.isEmpty, path.isEmpty { codeEditor = .builtIn }
        if let other = otherApp, other.bundleID.isEmpty, other.path.isEmpty { otherApp = nil }
    }
}

extension EditorPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case codeEditor, openSkinsIn, showIniNames, codeFontSize, liveReload, otherApp, seenTips, editorLocks,
             unlockedBackgrounds, showsContentOutside, backdrops
    }

    /// Tolerant decoding (like `SkinState`): a missing, misspelt or mistyped key keeps its default instead of making
    /// the whole state file unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let d = EditorPreferences()
        codeEditor = value(.codeEditor, d.codeEditor)
        openSkinsIn = OpenSkinsIn(rawValue: value(.openSkinsIn, "").lowercased()) ?? d.openSkinsIn
        showIniNames = value(.showIniNames, d.showIniNames)
        codeFontSize = value(.codeFontSize, d.codeFontSize)
        liveReload = value(.liveReload, d.liveReload)
        otherApp = (try? c.decodeIfPresent(StoredApp.self, forKey: .otherApp)) ?? nil
        seenTips = value(.seenTips, d.seenTips)
        editorLocks = value(.editorLocks, d.editorLocks)
        unlockedBackgrounds = value(.unlockedBackgrounds, d.unlockedBackgrounds)
        showsContentOutside = value(.showsContentOutside, d.showsContentOutside)
        backdrops = value(.backdrops, d.backdrops)
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(codeEditor, forKey: .codeEditor)
        try c.encode(openSkinsIn.rawValue, forKey: .openSkinsIn)
        try c.encode(showIniNames, forKey: .showIniNames)
        try c.encode(codeFontSize, forKey: .codeFontSize)
        try c.encode(liveReload, forKey: .liveReload)
        try c.encodeIfPresent(otherApp, forKey: .otherApp)
        try c.encode(seenTips.sorted(), forKey: .seenTips)
        try c.encode(editorLocks.mapValues { $0.sorted() }, forKey: .editorLocks)
        try c.encode(unlockedBackgrounds.sorted(), forKey: .unlockedBackgrounds)
        try c.encode(showsContentOutside, forKey: .showsContentOutside)
        if !backdrops.isEmpty { try c.encode(backdrops, forKey: .backdrops) }
    }
}

/// Stored as `{"kind": "builtIn" | "app" | "systemDefault", "bundleID": …, "path": …}`; anything unreadable is the
/// built-in editor (the safe default).
extension EditorPreferences.CodeEditor: Codable {
    private enum CodingKeys: String, CodingKey { case kind, bundleID, path }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .builtIn
            return
        }
        let kind = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil)?.lowercased() ?? ""
        switch kind {
        case "app":
            let id = ((try? c.decodeIfPresent(String.self, forKey: .bundleID)) ?? nil) ?? ""
            let path = ((try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil) ?? ""
            self = id.isEmpty && path.isEmpty ? .builtIn : .app(bundleID: id, lastKnownPath: path)
        case "systemdefault":
            self = .systemDefault
        default:
            self = .builtIn
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn:
            try c.encode("builtIn", forKey: .kind)
        case .app(let id, let path):
            try c.encode("app", forKey: .kind)
            try c.encode(id, forKey: .bundleID)
            try c.encode(path, forKey: .path)
        case .systemDefault:
            try c.encode("systemDefault", forKey: .kind)
        }
    }
}

extension Notification.Name {
    /// Posted by `AppState.updateEditor` when Settings ▸ Editor changes (object: the `AppState`).
    static let desksetEditorPreferencesChanged = Notification.Name("DesksetEditorPreferencesChanged")
}

// MARK: - Editor families and the catalog

/// How an editor is asked to open a file at a line. Verified per editor in docs/research/editor-2026-09-24-code.json.
enum EditorFamily: Equatable {
    /// Visual Studio Code and its forks (Cursor, Windsurf, VSCodium, Antigravity IDE…), recognised by
    /// `Contents/Resources/app/product.json`: `<urlProtocol>://file/abs/path:LINE`, else the bundled CLI
    /// `bin/<applicationName> --goto path:LINE`.
    case vsCode(urlProtocol: String?, applicationName: String?)
    /// `zed://file/abs/path:LINE`.
    case zed
    /// `x-bbedit://open?url=file://…&line=LINE` (BBEdit 12.1.4+).
    case bbEdit
    /// `txmt://open?url=file://…&line=LINE`.
    case textMate
    /// `nova://open?path=/abs/path&line=LINE` (Nova 11+).
    case nova
    /// IntelliJ-platform IDEs and Android Studio: `idea://open?file=/abs/path&line=LINE`, sent to the chosen IDE
    /// (several IDEs may register `idea`).
    case jetBrains
    /// `mvim://open?url=file://…&line=LINE` (special characters double-encoded, as MacVim documents).
    case macVim
    /// Bundled CLI `Contents/SharedSupport/bin/subl "/abs/path:LINE"` (Sublime does not register `subl://` itself).
    case sublime
    /// Bundled CLI `Contents/SharedSupport/bin/cot --line LINE /abs/path`.
    case cotEditor
    /// The chosen Xcode's own `Contents/Developer/usr/bin/xed --line LINE /abs/path` (not `/usr/bin/xed`, which
    /// follows xcode-select and fails when only the Command Line Tools are selected).
    case xcode
    /// No line support: the file opens at the top.
    case textEdit
    /// Unknown app: the file is handed to it (no line).
    case plain

    /// Whether the editor can be asked to show a line.
    var jumpsToLine: Bool {
        switch self {
        case .textEdit, .plain: return false
        case .vsCode(let scheme, let cli): return scheme != nil || cli != nil
        default: return true
        }
    }

    /// Opening at a line through a URL scheme asks VS Code and its forks for confirmation the first time.
    var confirmsURLOpens: Bool {
        if case .vsCode(let scheme, _) = self { return scheme != nil }
        return false
    }
}

/// Curated editors (bundle identifiers from docs/research/editor-2026-09-24-code.json). Detection offers the ones
/// installed, together with the apps that claim .ini files and the user's "Other…" app.
enum CodeEditorCatalog {
    struct Entry {
        let name: String
        let bundleIDs: [String]
        let family: EditorFamily
    }

    static let entries: [Entry] = [
        Entry(name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode"],
              family: .vsCode(urlProtocol: "vscode", applicationName: "code")),
        Entry(name: "Visual Studio Code - Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"],
              family: .vsCode(urlProtocol: "vscode-insiders", applicationName: "code-insiders")),
        Entry(name: "VSCodium", bundleIDs: ["com.vscodium", "com.visualstudio.code.oss"],
              family: .vsCode(urlProtocol: "vscodium", applicationName: "codium")),
        Entry(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
              family: .vsCode(urlProtocol: "cursor", applicationName: "cursor")),
        Entry(name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"],
              family: .vsCode(urlProtocol: "windsurf", applicationName: "windsurf")),
        // The IDE, not the agent "hub" app com.google.antigravity (which registers antigravity:// but edits nothing).
        Entry(name: "Antigravity IDE", bundleIDs: ["com.google.antigravity-ide"],
              family: .vsCode(urlProtocol: "antigravity-ide", applicationName: "antigravity-ide")),
        Entry(name: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly", "dev.zed.Zed-Dev"],
              family: .zed),
        Entry(name: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"], family: .sublime),
        Entry(name: "BBEdit", bundleIDs: ["com.barebones.bbedit"], family: .bbEdit),
        Entry(name: "TextMate", bundleIDs: ["com.macromates.TextMate"], family: .textMate),
        Entry(name: "Nova", bundleIDs: ["com.panic.Nova"], family: .nova),
        Entry(name: "CotEditor", bundleIDs: ["com.coteditor.CotEditor"], family: .cotEditor),
        Entry(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], family: .xcode),
        Entry(name: "JetBrains IDE", bundleIDs: [
            "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.WebStorm", "com.jetbrains.PyCharm",
            "com.jetbrains.pycharm.ce", "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.PhpStorm",
            "com.jetbrains.RubyMine", "com.jetbrains.rider", "com.jetbrains.RustRover", "com.google.android.studio",
        ], family: .jetBrains),
        Entry(name: "MacVim", bundleIDs: ["org.vim.MacVim"], family: .macVim),
        Entry(name: "TextEdit", bundleIDs: ["com.apple.TextEdit"], family: .textEdit),
    ]

    /// Apps that register for .ini (or would match a prefix below) but are not text editors.
    static let excludedBundleIDs: Set<String> = [
        "com.google.antigravity", "com.jetbrains.toolbox", "com.jetbrains.fleet", "com.jetbrains.gateway",
    ]

    static func isExcluded(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return excludedBundleIDs.contains(id)
    }

    /// The family of an app: a VS Code fork by its product.json first (so an unlisted fork works too), then the
    /// catalog by bundle identifier, then known identifier prefixes.
    static func family(bundleID: String?, appURL: URL) -> EditorFamily {
        let entry = bundleID.flatMap { id in
            entries.first { $0.bundleIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }
        }
        if let product = VSCodeProduct.read(appURL: appURL) {
            // A product.json without a usable scheme or CLI name keeps the catalog's values for that app.
            var fallback: (String?, String?) = (nil, nil)
            if case .vsCode(let s, let a)? = entry?.family { fallback = (s, a) }
            return .vsCode(urlProtocol: product.urlProtocol ?? fallback.0,
                           applicationName: product.applicationName ?? fallback.1)
        }
        if let entry {
            // A listed VS Code fork without its product.json: the scheme it registers is still known, but its CLI
            // path is not (it lives next to product.json).
            if case .vsCode(let scheme, _) = entry.family { return .vsCode(urlProtocol: scheme, applicationName: nil) }
            return entry.family
        }
        guard let id = bundleID?.lowercased(), !isExcluded(id) else { return .plain }
        if id.hasPrefix("dev.zed.") { return .zed }
        if id.hasPrefix("com.jetbrains.") { return .jetBrains }
        return .plain
    }
}

/// The fields of a VS Code-family `Contents/Resources/app/product.json` that matter here.
struct VSCodeProduct: Equatable {
    /// URL scheme the app registers (`vscode`, `cursor`, `antigravity-ide`…).
    var urlProtocol: String?
    /// Name of the bundled CLI in `Contents/Resources/app/bin`.
    var applicationName: String?

    static func productURL(appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Resources/app/product.json")
    }

    /// nil when the app has no readable product.json (not a VS Code fork) or it names neither a scheme nor a CLI.
    static func read(appURL: URL) -> VSCodeProduct? {
        let url = productURL(appURL: appURL)
        guard let data = try? Data(contentsOf: url), data.count < 4_000_000,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            guard let s = (json[key] as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            return s
        }
        let scheme = text("urlProtocol").flatMap { isURLScheme($0) ? $0 : nil }
        // The CLI name is used as a path component: nothing that could leave the bin folder.
        let cli = text("applicationName").flatMap { $0.contains("/") || $0.hasPrefix(".") ? nil : $0 }
        guard scheme != nil || cli != nil else { return nil }
        return VSCodeProduct(urlProtocol: scheme, applicationName: cli)
    }

    /// RFC 3986 scheme: a letter, then letters, digits, `+`, `-` or `.`.
    static func isURLScheme(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) }
    }
}

// MARK: - Installed editors

/// One installed app that can edit code.
struct CodeEditorApp: Equatable {
    var url: URL
    var bundleID: String?
    /// The name Finder shows ("Visual Studio Code", "Antigravity IDE").
    var name: String
    var family: EditorFamily

    init(url: URL, bundleID: String?, name: String? = nil, family: EditorFamily? = nil) {
        self.url = url
        self.bundleID = bundleID
        self.name = name ?? CodeEditorApp.displayName(of: url)
        self.family = family ?? CodeEditorCatalog.family(bundleID: bundleID, appURL: url)
    }

    static func displayName(of appURL: URL) -> String {
        var name = FileManager.default.displayName(atPath: appURL.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name.isEmpty ? appURL.deletingPathExtension().lastPathComponent : name
    }

    /// The app's icon at 16 pt (pop-up menus).
    var icon: NSImage {
        let image = (CodeEditorRouter.locator.icon(ofApplicationAt: url).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// Launch Services lookups, behind a protocol so self-tests can answer with fixtures.
protocol ApplicationLocating {
    func applicationURL(bundleID: String) -> URL?
    /// Apps that declare they open files with this extension.
    func applicationURLs(toOpenExtension ext: String) -> [URL]
    /// The app macOS opens this file with (by the file, else by its extension's type).
    func defaultApplicationURL(toOpen file: URL) -> URL?
    func bundleIdentifier(ofApplicationAt url: URL) -> String?
    /// The app's icon (drawn by the icon service when it is shown).
    func icon(ofApplicationAt url: URL) -> NSImage
}

struct WorkspaceApplicationLocator: ApplicationLocating {
    func icon(ofApplicationAt url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    func applicationURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func applicationURLs(toOpenExtension ext: String) -> [URL] {
        // .ini has no system type (it resolves to a dyn.* type), which Launch Services still answers for.
        guard let type = UTType(filenameExtension: ext) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    func defaultApplicationURL(toOpen file: URL) -> URL? {
        if FileManager.default.fileExists(atPath: file.path), let app = NSWorkspace.shared.urlForApplication(toOpen: file) {
            return app
        }
        guard let type = UTType(filenameExtension: file.pathExtension) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    func bundleIdentifier(ofApplicationAt url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }
}

enum CodeEditorDetector {
    /// Installed editors for the pop-up, sorted by name: the curated catalog ∪ apps claiming .ini ∪ the "Other…"
    /// app ∪ the current choice (so it can be shown selected). Deskset itself and non-editors are left out; each
    /// bundle identifier appears once.
    static func detect(preferences: EditorPreferences, locator: ApplicationLocating,
                       ownBundleID: String? = Bundle.main.bundleIdentifier) -> [CodeEditorApp] {
        var result: [CodeEditorApp] = []
        var seenIDs: Set<String> = []
        var seenPaths: Set<String> = []
        func add(_ url: URL, _ knownID: String?) {
            let id = knownID ?? locator.bundleIdentifier(ofApplicationAt: url)
            if let id, let own = ownBundleID, id.caseInsensitiveCompare(own) == .orderedSame { return }
            if CodeEditorCatalog.isExcluded(id) { return }
            let path = url.standardizedFileURL.path.lowercased()
            guard !seenPaths.contains(path), id.map({ !seenIDs.contains($0.lowercased()) }) ?? true else { return }
            seenPaths.insert(path)
            if let id { seenIDs.insert(id.lowercased()) }
            result.append(CodeEditorApp(url: url, bundleID: id))
        }
        if case .app(let id, let path) = preferences.codeEditor,
           let url = resolve(bundleID: id, lastKnownPath: path, locator: locator) {
            add(url, id.isEmpty ? nil : id)
        }
        if let other = preferences.otherApp,
           let url = resolve(bundleID: other.bundleID, lastKnownPath: other.path, locator: locator) {
            add(url, other.bundleID.isEmpty ? nil : other.bundleID)
        }
        for entry in CodeEditorCatalog.entries {
            for id in entry.bundleIDs {
                if let url = locator.applicationURL(bundleID: id) { add(url, id) }
            }
        }
        for url in locator.applicationURLs(toOpenExtension: "ini") { add(url, nil) }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Where a stored app is now: the picked copy while it exists (and is still that app), else wherever Launch
    /// Services finds the bundle identifier; nil when it has been uninstalled.
    static func resolve(bundleID: String, lastKnownPath: String, locator: ApplicationLocating) -> URL? {
        if !lastKnownPath.isEmpty, FileManager.default.fileExists(atPath: lastKnownPath) {
            let url = URL(fileURLWithPath: lastKnownPath)
            let found = locator.bundleIdentifier(ofApplicationAt: url)
            if bundleID.isEmpty || found == nil || found?.caseInsensitiveCompare(bundleID) == .orderedSame { return url }
        }
        guard !bundleID.isEmpty else { return nil }
        return locator.applicationURL(bundleID: bundleID)
    }

    /// The app macOS uses for .ini files ("System default (<App>)"), nil when there is none.
    static func systemDefaultApp(locator: ApplicationLocating, sampleExtension: String = "ini") -> CodeEditorApp? {
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("Deskset-sample.\(sampleExtension)")
        guard let url = locator.defaultApplicationURL(toOpen: sample) else { return nil }
        return CodeEditorApp(url: url, bundleID: locator.bundleIdentifier(ofApplicationAt: url))
    }
}

// MARK: - Open-at-line commands (pure)

/// What opening a file in an external editor does. Built by `CodeEditorLaunch` without side effects; carried out by
/// `CodeEditorRouter` through its injectable opener.
enum CodeEditorCommand: Equatable {
    /// Hand these URLs to the app with `NSWorkspace.open(_:withApplicationAt:)`: the file itself, or a URL that makes
    /// the app jump to a line (sent to that app even when another one registers the same scheme).
    case open([URL], app: URL)
    /// Run a command-line tool bundled with the editor. When it cannot be started, the file is opened in the app.
    case run(executable: URL, arguments: [String])
}

enum CodeEditorLaunch {
    static func command(for editor: CodeEditorApp, file: URL, line: Int?) -> CodeEditorCommand {
        command(family: editor.family, appURL: editor.url, file: file, line: line)
    }

    /// The command opening `file` in the app at `appURL`, at `line` (1-based) when the editor supports it. Without a
    /// line, every editor simply gets the file (no URL scheme, so no confirmation prompt).
    static func command(family: EditorFamily, appURL: URL, file: URL, line: Int?) -> CodeEditorCommand {
        let file = file.standardizedFileURL
        let plain = CodeEditorCommand.open([file], app: appURL)
        guard let line, line > 0 else { return plain }
        let path = file.path
        let pathInURL = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let fileURLValue = queryValue(file.absoluteString)
        func link(_ text: String) -> CodeEditorCommand {
            URL(string: text).map { .open([$0], app: appURL) } ?? plain
        }
        switch family {
        case .vsCode(let scheme, let cli):
            if let scheme { return link("\(scheme)://file\(pathInURL):\(line)") }
            if let cli {
                return .run(executable: appURL.appendingPathComponent("Contents/Resources/app/bin/\(cli)"),
                            arguments: ["--goto", "\(path):\(line)"])
            }
            return plain
        case .zed:
            return link("zed://file\(pathInURL):\(line)")
        case .bbEdit:
            return link("x-bbedit://open?url=\(fileURLValue)&line=\(line)")
        case .textMate:
            return link("txmt://open?url=\(fileURLValue)&line=\(line)")
        case .nova:
            return link("nova://open?path=\(queryValue(path))&line=\(line)")
        case .jetBrains:
            return link("idea://open?file=\(queryValue(path))&line=\(line)")
        case .macVim:
            // The file URL already has %20 for a space; encoding it as a query value makes that %2520, the
            // double encoding MacVim's documentation asks for.
            return link("mvim://open?url=\(fileURLValue)&line=\(line)")
        case .sublime:
            return .run(executable: appURL.appendingPathComponent("Contents/SharedSupport/bin/subl"),
                        arguments: ["\(path):\(line)"])
        case .cotEditor:
            return .run(executable: appURL.appendingPathComponent("Contents/SharedSupport/bin/cot"),
                        arguments: ["--line", String(line), path])
        case .xcode:
            return .run(executable: appURL.appendingPathComponent("Contents/Developer/usr/bin/xed"),
                        arguments: ["--line", String(line), path])
        case .textEdit, .plain:
            return plain
        }
    }

    /// A query parameter value: everything a query allows except the characters that separate parameters.
    static func queryValue(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
