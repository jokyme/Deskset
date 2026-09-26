import AppKit
import DesksetCore
import UniformTypeIdentifiers

/// Well-known folders.
enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Deskset", isDirectory: true)
    }()
    static let skins = appSupport.appendingPathComponent("Skins", isDirectory: true)
    static let layouts = appSupport.appendingPathComponent("Layouts", isDirectory: true)
    static let backups = appSupport.appendingPathComponent("Backups", isDirectory: true)
    static let state = appSupport.appendingPathComponent("state.json")
    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Deskset", isDirectory: true)
    }()
    static let logFile = logs.appendingPathComponent("Deskset.log")

    /// Bundled example skins: `Contents/Resources/DefaultSkins` in the .app; the repo folder during `swift run`.
    static var defaultSkins: URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("DefaultSkins"),
           fm.fileExists(atPath: res.path) { return res }
        return repositoryFolder("DefaultSkins")
    }

    /// `<repo>/<name>` when running from a SwiftPM build folder (`.build/debug/Deskset`), else nil.
    static func repositoryFolder(_ name: String) -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path),
               fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return candidate }
            dir.deleteLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(name)
        return fm.fileExists(atPath: cwd.path) ? cwd : nil
    }

    /// True inside a built `.app` bundle (false for `swift run` / `.build/debug/Deskset`).
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension.lowercased() == "app" }

    static func ensureDirectories() {
        for dir in [appSupport, skins, layouts, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Appends to ~/Library/Logs/Deskset/Deskset.log (also mirrored to stderr for `swift run`).
enum Log {
    private static let queue = DispatchQueue(label: "deskset.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static var handle: FileHandle?
    /// Size of the open log file (tracked on `queue`).
    private static var bytesWritten = 0
    /// The log is rotated to Deskset.old.log when it grows past this size — at launch and while running (a skin that
    /// logs on every update, e.g. an unsupported bang in OnUpdateAction at Update=16, writes dozens of lines per
    /// second for as long as the app runs), so the logs never take more than about twice this.
    static var maxLogSize = 4 * 1024 * 1024
    /// Folder of Deskset.log / Deskset.old.log (a temporary folder in self-tests).
    static var directory = Paths.logs {
        didSet { queue.sync { try? handle?.close(); handle = nil; bytesWritten = 0 } }
    }
    static var fileURL: URL { directory.appendingPathComponent("Deskset.log") }
    /// Lines longer than this are cut (a skin logging a huge string every update must not fill the disk quickly).
    static let maxLineLength = 4000
    /// Set by `--self-test` and other command-line modes that should not touch the user's log.
    static var fileLoggingEnabled = true
    static var mirrorsToStandardError = true

    static func write(_ message: String, level: SkinLogLevel = .notice, source: String? = nil) {
        var text = message
        if text.count > maxLineLength { text = String(text.prefix(maxLineLength)) + "…" }
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)]\(source.map { " (\($0))" } ?? "") \(text)\n"
        if mirrorsToStandardError { FileHandle.standardError.write(line.data(using: .utf8) ?? Data()) }
        guard fileLoggingEnabled else { return }
        queue.async {
            if handle == nil {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: fileURL)
                bytesWritten = Int((try? handle?.seekToEnd()) ?? 0)
            }
            let data = line.data(using: .utf8) ?? Data()
            handle?.write(data)
            bytesWritten += data.count
            if bytesWritten > maxLogSize { rotateLocked() }
        }
    }

    /// Waits until queued lines are written (self-tests).
    static func flush() { queue.sync {} }

    /// Moves a large log aside (called at launch, before the first write).
    static func rotateIfNeeded() {
        queue.sync {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int ?? 0
            if size > maxLogSize { rotateLocked() }
        }
    }

    /// Closes the log and moves it to Deskset.old.log; the next line starts a new file. Runs on `queue`.
    private static func rotateLocked() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        let fm = FileManager.default
        let old = directory.appendingPathComponent("Deskset.old.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: fileURL, to: old)
    }
}

/// Opening skin files and folders.
enum Workspace {
    /// Opens a skin file for editing: the user's default app for the file type, TextEdit when there is none
    /// (.ini / .inc usually have no default editor on a Mac).
    static func edit(_ url: URL) {
        let ws = NSWorkspace.shared
        if ws.urlForApplication(toOpen: url) != nil {
            ws.open(url)
            return
        }
        let textEdit = ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        ws.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.write("Could not open \(url.path): \(error.localizedDescription)", level: .error) }
        }
    }

    /// Opens a file at a line: editors with a URL scheme for that (VS Code, Cursor, Sublime Text, BBEdit, TextMate)
    /// jump to it when they are the file's default app; others just open the file.
    static func edit(_ url: URL, line: Int) {
        let ws = NSWorkspace.shared
        let path = url.standardizedFileURL.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let fileURL = url.standardizedFileURL.absoluteString
        let query = fileURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? fileURL
        let bundle = ws.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
        let link: String?
        switch bundle {
        case "com.microsoft.VSCode": link = "vscode://file\(encoded):\(line)"
        case "com.todesktop.230313mzl4w4u92": link = "cursor://file\(encoded):\(line)"
        case "com.sublimetext.4", "com.sublimetext.3": link = "subl://open?url=\(query)&line=\(line)"
        case "com.barebones.bbedit": link = "x-bbedit://open?url=\(query)&line=\(line)"
        case "com.macromates.TextMate": link = "txmt://open?url=\(query)&line=\(line)"
        default: link = nil
        }
        if let link, let target = URL(string: link), ws.open(target) { return }
        edit(url)
    }

    /// Shows a folder in Finder.
    static func reveal(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    private static var cachedEditor: (path: String, time: TimeInterval)?

    /// `#CONFIGEDITOR#`: the app `edit(_:)` opens skin files with — the default app for .ini files, else TextEdit.
    /// Looked up at most once a minute (skins may read the variable on every update).
    static var configEditorPath: String {
        if let chosen = CodeEditorRouter.configEditorPathOverride { return chosen } // Settings ▸ Editor
        let now = ProcessInfo.processInfo.systemUptime
        if let c = cachedEditor, now - c.time < 60 { return c.path }
        let ws = NSWorkspace.shared
        var app: URL?
        if let type = UTType(filenameExtension: "ini") { app = ws.urlForApplication(toOpen: type) }
        let path = (app ?? ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")).path
        cachedEditor = (path, now)
        return path
    }
}

extension RGBA {
    var nsColor: NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 255)
    }
    var cgColor: CGColor { nsColor.cgColor }
}

extension SkinRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension Notification.Name {
    /// Posted by `AppController` when skins are loaded, unloaded, refreshed or installed, or a skin's settings change.
    static let desksetSkinsChanged = Notification.Name("DesksetSkinsChanged")
}

/// The few user-defaults calls the app makes outside state.json (the editor window's pane sizes, a setting moved from
/// an older version), behind a protocol: self-tests pass an in-memory store, since even an emptied UserDefaults suite
/// leaves a file behind in the user's ~/Library/Preferences.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// A `KeyValueStore` in memory (self-tests).
final class MemoryKeyValueStore: KeyValueStore {
    private(set) var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}
