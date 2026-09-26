import Foundation

/// Per-config window settings (Rainmeter keeps these in Rainmeter.ini; see
/// https://docs.rainmeter.net/manual/settings/skin-sections/).
struct SkinState: Codable, Equatable {
    var file: String
    var active: Bool = true
    /// Top-left corner in top-left-origin screen coordinates of the primary screen.
    var x: Double?
    var y: Double?
    /// -2 on desktop, -1 bottom, 0 normal, 1 topmost, 2 stay topmost.
    /// The manual's default is 0 (Normal); on the Mac, widgets are expected to live on the desktop, so new skins
    /// start "On Desktop" (a product decision; users can change it per skin).
    var alwaysOnTop: Int = -2
    var draggable: Bool = true
    var clickThrough: Bool = false
    var keepOnScreen: Bool = true
    var snapEdges: Bool = true
    /// 0…255.
    var alphaValue: Int = 255
    var savePosition: Bool = true
    var loadOrder: Int = 0
    /// `FadeDuration` in milliseconds (manual default 250): hover fades and !ShowFade / !HideFade / !ToggleFade.
    var fadeDuration: Int = 250
    /// `OnHover`: 0 nothing, 1 hide, 2 fade in, 3 fade out.
    var onHover: Int = 0
    /// `StartHidden`: "the skin will start hidden. The !Show bang must be used to show the skin."
    var startHidden: Bool = false
    /// `AutoSelectScreen`: the monitor of the skin's built-in variables (`#SCREENAREAX#`, `#WORKAREAX#`…) follows
    /// the window instead of being the primary one.
    var autoSelectScreen: Bool = false

    init(file: String) {
        self.file = file
    }

    private enum CodingKeys: String, CodingKey {
        case file, active, x, y, alwaysOnTop, draggable, clickThrough, keepOnScreen, snapEdges, alphaValue,
             savePosition, loadOrder, fadeDuration, onHover, startHidden, autoSelectScreen
    }

    /// Tolerant decoding: keys added in later versions (or removed by hand) fall back to their defaults instead of
    /// making the whole state file unreadable. Out-of-range values are clamped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SkinState(file: "")
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        file = value(.file, d.file)
        active = value(.active, d.active)
        // Positions far outside any desktop (a hand-edited file) are clamped like !Move values, so code that turns
        // them into integers or window frames never sees absurd magnitudes.
        x = ((try? c.decodeIfPresent(Double.self, forKey: .x)) ?? nil).flatMap(SkinState.position)
        y = ((try? c.decodeIfPresent(Double.self, forKey: .y)) ?? nil).flatMap(SkinState.position)
        alwaysOnTop = min(max(value(.alwaysOnTop, d.alwaysOnTop), -2), 2)
        draggable = value(.draggable, d.draggable)
        clickThrough = value(.clickThrough, d.clickThrough)
        keepOnScreen = value(.keepOnScreen, d.keepOnScreen)
        snapEdges = value(.snapEdges, d.snapEdges)
        alphaValue = min(max(value(.alphaValue, d.alphaValue), 0), 255)
        savePosition = value(.savePosition, d.savePosition)
        loadOrder = value(.loadOrder, d.loadOrder)
        fadeDuration = min(max(value(.fadeDuration, d.fadeDuration), 0), SkinState.maxFadeDuration)
        onHover = min(max(value(.onHover, d.onHover), 0), 3)
        startHidden = value(.startHidden, d.startHidden)
        autoSelectScreen = value(.autoSelectScreen, d.autoSelectScreen)
    }

    /// Fades longer than this are clamped (a typo like `!FadeDuration 250000` should not freeze a skin for minutes).
    static let maxFadeDuration = 10_000

    /// Largest stored coordinate magnitude (the same bound `!Move` uses).
    static let maxPosition = 1_000_000.0

    /// A finite position clamped to ±`maxPosition`; nil for NaN / infinity.
    static func position(_ v: Double) -> Double? {
        v.isFinite ? min(max(v, -maxPosition), maxPosition) : nil
    }
}

struct AppStateData: Codable {
    /// Keyed by config name (`Root\Sub`).
    var skins: [String: SkinState] = [:]
    var defaultSkinsInstalled: Int = 0
    /// Settings ▸ Editor.
    var editor = EditorPreferences()
    /// The Settings pane shown last (the window reopens on it).
    var settingsPane: String?
    /// False until the file has held editor preferences: the one moment the old UserDefaults live-reload switch is
    /// carried over (see `AppState.migrateLegacyEditorPreferences`). Not stored.
    var hasEditorPreferences = false

    init() {}

    private enum CodingKeys: String, CodingKey { case skins, defaultSkinsInstalled, editor, settingsPane }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skins = ((try? c.decodeIfPresent([String: SkinState].self, forKey: .skins)) ?? nil) ?? [:]
        defaultSkinsInstalled = ((try? c.decodeIfPresent(Int.self, forKey: .defaultSkinsInstalled)) ?? nil) ?? 0
        let storedEditor = (try? c.decodeIfPresent(EditorPreferences.self, forKey: .editor)) ?? nil
        editor = storedEditor ?? EditorPreferences()
        hasEditorPreferences = storedEditor != nil
        settingsPane = (try? c.decodeIfPresent(String.self, forKey: .settingsPane)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(skins, forKey: .skins)
        try c.encode(defaultSkinsInstalled, forKey: .defaultSkinsInstalled)
        try c.encode(editor, forKey: .editor)
        try c.encodeIfPresent(settingsPane, forKey: .settingsPane)
    }
}

/// Loads and saves `~/Library/Application Support/Deskset/state.json` (debounced).
final class AppState {
    private(set) var data = AppStateData()
    private var saveScheduled = false
    let fileURL: URL

    init(fileURL: URL = Paths.state) {
        self.fileURL = fileURL
        if let raw = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(AppStateData.self, from: raw) {
                data = decoded
            } else {
                // Keep the unreadable file for inspection instead of silently overwriting it on the next save.
                let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: fileURL, to: backup)
                Log.write("state.json could not be read; starting with default settings", level: .warning)
            }
        }
    }

    /// State of a config; the lookup is case-insensitive (Rainmeter config names are).
    func skin(_ config: String) -> SkinState? {
        if let s = data.skins[config] { return s }
        return data.skins.first { $0.key.caseInsensitiveCompare(config) == .orderedSame }?.value
    }

    func update(_ config: String, _ change: (inout SkinState) -> Void) {
        let key = storedKey(for: config)
        var s = data.skins[key] ?? SkinState(file: "")
        change(&s)
        s.x = s.x.flatMap(SkinState.position)
        s.y = s.y.flatMap(SkinState.position)
        s.alwaysOnTop = min(max(s.alwaysOnTop, -2), 2)
        s.alphaValue = min(max(s.alphaValue, 0), 255)
        s.fadeDuration = min(max(s.fadeDuration, 0), SkinState.maxFadeDuration)
        s.onHover = min(max(s.onHover, 0), 3)
        guard data.skins[key] != s else { return }
        data.skins[key] = s
        scheduleSave()
    }

    /// The existing key for `config` (any case), so one config never ends up with two entries.
    private func storedKey(for config: String) -> String {
        if data.skins[config] != nil { return config }
        return data.skins.keys.first { $0.caseInsensitiveCompare(config) == .orderedSame } ?? config
    }

    func setDefaultSkinsInstalled(_ version: Int) {
        data.defaultSkinsInstalled = version
        scheduleSave()
    }

    // MARK: Editor preferences

    var editor: EditorPreferences { data.editor }

    /// Changes Settings ▸ Editor; saves and posts `.desksetEditorPreferencesChanged` when something changed.
    func updateEditor(_ change: (inout EditorPreferences) -> Void) {
        var e = data.editor
        change(&e)
        e.normalize()
        data.hasEditorPreferences = true
        guard e != data.editor else { return }
        data.editor = e
        scheduleSave()
        NotificationCenter.default.post(name: .desksetEditorPreferencesChanged, object: self)
    }

    func setSettingsPane(_ pane: String) {
        guard data.settingsPane != pane else { return }
        data.settingsPane = pane
        scheduleSave()
    }

    /// Carries the skin editor's live-reload switch over from UserDefaults (`InspectorAutoRefresh`, where it lived
    /// before Settings existed) the first time — when state.json has never held editor preferences. Afterwards the
    /// preference lives only in state.json. Called at launch with `UserDefaults.standard`; self-tests pass a
    /// `MemoryKeyValueStore` (a UserDefaults suite would leave a file in ~/Library/Preferences).
    func migrateLegacyEditorPreferences(from defaults: KeyValueStore) {
        guard !data.hasEditorPreferences else { return }
        data.hasEditorPreferences = true
        guard let legacy = defaults.object(forKey: EditorPreferences.legacyLiveReloadKey) as? Bool else { return }
        data.editor.liveReload = legacy
        scheduleSave()
    }

    /// Active configs in load order ("Skins with the lowest load order are loaded first"), then by name.
    var activeConfigs: [(config: String, state: SkinState)] {
        data.skins.filter { $0.value.active }
            .sorted { ($0.value.loadOrder, $0.key) < ($1.value.loadOrder, $1.key) }
            .map { ($0.key, $0.value) }
    }

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        saveScheduled = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? encoder.encode(data) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? raw.write(to: fileURL, options: .atomic)
    }
}

/// A folder under Skins that contains .ini files.
struct SkinConfig: Equatable {
    /// `Root\Sub` style name.
    let name: String
    let directory: URL
    /// .ini file names, sorted.
    let files: [String]

    var rootName: String { String(name.split(separator: "\\").first ?? Substring(name)) }
}

/// Scans the Skins folder: every folder (except `@Resources`, `@Backup`… anything starting with `@`) holding .ini
/// files is a config.
enum SkinLibrary {
    /// Guards against pathological trees. Symlinked folders are followed (people link skin folders from elsewhere),
    /// but each real folder is visited once, so link loops end.
    static let maxDepth = 12
    static let maxConfigs = 5000
    /// Folders looked at in one scan: a symlink to a big tree (the home folder, `/`) holds few .ini files, so the
    /// config limit alone would let the scan walk hundreds of thousands of folders on the main thread.
    static let maxFolders = 20_000

    static func scan(_ root: URL = Paths.skins, folderLimit: Int = maxFolders) -> [SkinConfig] {
        var result: [SkinConfig] = []
        var visited: Set<String> = []
        func walk(_ dir: URL, _ components: [String], depth: Int) {
            guard depth < maxDepth, result.count < maxConfigs, visited.count < folderLimit,
                  visited.insert(dir.resolvingSymlinksInPath().path).inserted,
                  let items = try? FileManager.default.contentsOfDirectory(
                      at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            let inis = items.filter { $0.pathExtension.lowercased() == "ini" && !isDirectory($0) }
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if !components.isEmpty && !inis.isEmpty {
                result.append(SkinConfig(name: components.joined(separator: "\\"), directory: dir, files: inis))
            }
            let dirs = items.filter(isDirectory)
                .filter { !$0.lastPathComponent.hasPrefix("@") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for d in dirs { walk(d, components + [d.lastPathComponent], depth: depth + 1) }
        }
        walk(root, [], depth: 0)
        return result
    }

    /// Folder, or symlink to a folder.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func directory(for config: String, root: URL = Paths.skins) -> URL {
        config.split(separator: "\\").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    /// Normalizes a config argument (`illustro/Clock\`, ` illustro\Clock `) to `illustro\Clock`.
    static func normalizedConfigName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "\\")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\").union(.whitespaces))
    }
}
