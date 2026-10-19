import DesksetCore
import Foundation

extension Notification.Name {
    static let desksetGlobalSettingsChanged = Notification.Name("DesksetGlobalSettingsChanged")
}

/// Per-config window settings (Rainmeter keeps these in Rainmeter.ini; see
/// https://docs.rainmeter.net/manual/settings/skin-sections/).
struct SkinState: Codable, Equatable {
    var file: String
    var active: Bool = true
    /// Top-left corner in top-left-origin screen coordinates of the primary screen.
    var x: Double?
    var y: Double?
    /// Rainmeter's saved position expressions. Kept independently of the resolved desktop coordinates so a
    /// percentage, anchor or monitor suffix survives loading and saving a layout.
    var windowX: String?
    var windowY: String?
    var anchorX: String?
    var anchorY: String?
    /// Config-section group overrides; nil leaves the skin's own setting in effect.
    var group: String?
    var dragGroup: String?
    /// The imported Active index, retained with its raw option until activation or the variant changes.
    /// A non-nil index also preserves an imported section whose Active key was absent.
    var activeVariant: Int?
    /// Original config options, including options this version does not implement.
    var layoutOptions: [String: String] = [:]
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
    /// `Zoom` in Rainmeter.ini: an integer percentage; nil follows the application's DefaultZoom.
    var zoomOverridePercent: Int?
    /// The previous state.json multiplier remains the on-disk format. Explicit 100% differs from Default.
    var zoomFactor: Double {
        get { Double(zoomOverridePercent ?? 100) / 100 }
        set { zoomOverridePercent = Self.zoomPercent(factor: newValue) }
    }

    static func zoomPercent(factor: Double) -> Int {
        guard factor.isFinite else { return 100 }
        return Int((min(max(factor, 0.1), 5) * 100).rounded())
    }
    /// Keys this version does not know (written by a newer one), kept as they were and written back, so that going
    /// back to an older version and forward again loses nothing.
    var unknownKeys: [String: JSONValue] = [:]

    init(file: String) {
        self.file = file
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case file, active, x, y, windowX, windowY, anchorX, anchorY, group, dragGroup, activeVariant, layoutOptions,
             alwaysOnTop, draggable, clickThrough, keepOnScreen, snapEdges, alphaValue,
             savePosition, loadOrder, fadeDuration, onHover, startHidden, autoSelectScreen, zoomFactor
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// Tolerant decoding: keys added in later versions (or removed by hand) fall back to their defaults instead of
    /// making the whole state file unreadable, and keys this version does not know are kept (`unknownKeys`).
    /// Out-of-range values are clamped.
    init(from decoder: Decoder) throws {
        unknownKeys = (try? decoder.container(keyedBy: AnyCodingKey.self))?
            .unknownValues(besides: SkinState.knownKeys) ?? [:]
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
        windowX = try? c.decodeIfPresent(String.self, forKey: .windowX)
        windowY = try? c.decodeIfPresent(String.self, forKey: .windowY)
        anchorX = try? c.decodeIfPresent(String.self, forKey: .anchorX)
        anchorY = try? c.decodeIfPresent(String.self, forKey: .anchorY)
        group = try? c.decodeIfPresent(String.self, forKey: .group)
        dragGroup = try? c.decodeIfPresent(String.self, forKey: .dragGroup)
        activeVariant = try? c.decodeIfPresent(Int.self, forKey: .activeVariant)
        layoutOptions = value(.layoutOptions, [:])
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
        zoomOverridePercent = ((try? c.decodeIfPresent(Double.self, forKey: .zoomFactor)) ?? nil)
            .map(Self.zoomPercent(factor:))
    }

    /// The keys this version knows, then the ones it kept (`unknownKeys`).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encode(active, forKey: .active)
        try c.encodeIfPresent(x, forKey: .x)
        try c.encodeIfPresent(y, forKey: .y)
        try c.encodeIfPresent(windowX, forKey: .windowX)
        try c.encodeIfPresent(windowY, forKey: .windowY)
        try c.encodeIfPresent(anchorX, forKey: .anchorX)
        try c.encodeIfPresent(anchorY, forKey: .anchorY)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(dragGroup, forKey: .dragGroup)
        try c.encodeIfPresent(activeVariant, forKey: .activeVariant)
        if !layoutOptions.isEmpty { try c.encode(layoutOptions, forKey: .layoutOptions) }
        try c.encode(alwaysOnTop, forKey: .alwaysOnTop)
        try c.encode(draggable, forKey: .draggable)
        try c.encode(clickThrough, forKey: .clickThrough)
        try c.encode(keepOnScreen, forKey: .keepOnScreen)
        try c.encode(snapEdges, forKey: .snapEdges)
        try c.encode(alphaValue, forKey: .alphaValue)
        try c.encode(savePosition, forKey: .savePosition)
        try c.encode(loadOrder, forKey: .loadOrder)
        try c.encode(fadeDuration, forKey: .fadeDuration)
        try c.encode(onHover, forKey: .onHover)
        try c.encode(startHidden, forKey: .startHidden)
        try c.encode(autoSelectScreen, forKey: .autoSelectScreen)
        if zoomOverridePercent != nil { try c.encode(zoomFactor, forKey: .zoomFactor) }
        var other = encoder.container(keyedBy: AnyCodingKey.self)
        try other.encodeUnknown(unknownKeys, besides: SkinState.knownKeys)
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

/// Update checks and version choices, kept with the app's other preferences in state.json.
struct AppUpdatePreferences: Codable, Equatable {
    var automaticallyChecks = true
    var lastCheckAttempt: Date?
    var lastNotifiedVersion: String?
    var skippedVersion: String?
    /// Preferences from newer versions survive opening and saving the state with this version.
    var unknownKeys: [String: JSONValue] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case automaticallyChecks, lastCheckAttempt, lastNotifiedVersion, skippedVersion
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        unknownKeys = (try? decoder.container(keyedBy: AnyCodingKey.self))?
            .unknownValues(besides: Self.knownKeys) ?? [:]
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automaticallyChecks = ((try? c.decodeIfPresent(Bool.self, forKey: .automaticallyChecks)) ?? nil) ?? true
        lastCheckAttempt = (try? c.decodeIfPresent(Date.self, forKey: .lastCheckAttempt)) ?? nil
        lastNotifiedVersion = (try? c.decodeIfPresent(String.self, forKey: .lastNotifiedVersion)) ?? nil
        skippedVersion = (try? c.decodeIfPresent(String.self, forKey: .skippedVersion)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(automaticallyChecks, forKey: .automaticallyChecks)
        try c.encodeIfPresent(lastCheckAttempt, forKey: .lastCheckAttempt)
        try c.encodeIfPresent(lastNotifiedVersion, forKey: .lastNotifiedVersion)
        try c.encodeIfPresent(skippedVersion, forKey: .skippedVersion)
        var other = encoder.container(keyedBy: AnyCodingKey.self)
        try other.encodeUnknown(unknownKeys, besides: Self.knownKeys)
    }
}

/// A saved skin file shortcut, independent of its currently loaded variant and window settings.
struct SkinFavorite: Codable, Equatable {
    let config: String
    let file: String

    init?(config: String, file: String) {
        let name = SkinLibrary.normalizedConfigName(config)
        let parts = name.split(separator: "\\", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ LayoutStore.isValidName(String($0)) }),
              LayoutStore.isValidName(file), file.count > 4, file.lowercased().hasSuffix(".ini") else { return nil }
        self.config = name
        self.file = file
    }

    func matches(_ other: SkinFavorite) -> Bool {
        config.caseInsensitiveCompare(other.config) == .orderedSame
            && file.caseInsensitiveCompare(other.file) == .orderedSame
    }

    static func normalized(_ stored: [SkinFavorite]) -> [SkinFavorite] {
        var result: [SkinFavorite] = []
        for item in stored {
            guard let favorite = SkinFavorite(config: item.config, file: item.file),
                  !result.contains(where: { $0.matches(favorite) }) else { continue }
            result.append(favorite)
        }
        return result
    }
}

struct AppStateData: Codable {
    /// Keyed by config name (`Root\Sub`).
    var skins: [String: SkinState] = [:]
    /// Favorites remain available after unloading a skin and are saved with local application preferences.
    var favorites: [SkinFavorite] = []
    /// Rainmeter.ini section order breaks ties between equal LoadOrder values.
    var skinOrder: [String] = []
    /// Loading an empty layout is an intentional empty desktop, not a first launch.
    var hasLoadedLayout = false
    /// Native layout settings, including global zoom; unsupported settings are retained for INI round trips.
    var rainmeterOptions: [String: String] = [:]
    var trayMeasureOptions: [String: String]? = nil
    var defaultSkinsInstalled: Int = 0
    /// The `[Variables]` of each bundled root config's `@Resources/Variables.inc` as the installed default skins
    /// shipped them (root config → lower-case key → value): an upgrade carries over only the values the user changed
    /// from these (`DefaultSkins.carryOverVariables`).
    var shippedVariables: [String: [String: String]] = [:]
    /// Settings ▸ Editor.
    var editor = EditorPreferences()
    /// Settings ▸ General: update checks and notifications.
    var updates = AppUpdatePreferences()
    /// The Settings pane shown last (the window reopens on it).
    var settingsPane: String?
    /// False until the file has held editor preferences: the one moment the old UserDefaults live-reload switch is
    /// carried over (see `AppState.migrateLegacyEditorPreferences`). Not stored.
    var hasEditorPreferences = false
    /// Top-level keys this version does not know (written by a newer one), kept and written back as they were.
    var unknownKeys: [String: JSONValue] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case skins, favorites, skinOrder, hasLoadedLayout, rainmeterOptions, trayMeasureOptions,
             defaultSkinsInstalled, shippedVariables, editor, updates, settingsPane
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        unknownKeys = (try? decoder.container(keyedBy: AnyCodingKey.self))?
            .unknownValues(besides: AppStateData.knownKeys) ?? [:]
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skins = ((try? c.decodeIfPresent([String: SkinState].self, forKey: .skins)) ?? nil) ?? [:]
        favorites = SkinFavorite.normalized(((try? c.decodeIfPresent([SkinFavorite].self, forKey: .favorites)) ?? nil) ?? [])
        skinOrder = ((try? c.decodeIfPresent([String].self, forKey: .skinOrder)) ?? nil) ?? []
        hasLoadedLayout = ((try? c.decodeIfPresent(Bool.self, forKey: .hasLoadedLayout)) ?? nil) ?? false
        rainmeterOptions = ((try? c.decodeIfPresent([String: String].self, forKey: .rainmeterOptions)) ?? nil) ?? [:]
        trayMeasureOptions = (try? c.decodeIfPresent([String: String].self, forKey: .trayMeasureOptions)) ?? nil
        defaultSkinsInstalled = ((try? c.decodeIfPresent(Int.self, forKey: .defaultSkinsInstalled)) ?? nil) ?? 0
        shippedVariables = ((try? c.decodeIfPresent([String: [String: String]].self, forKey: .shippedVariables)) ?? nil) ?? [:]
        let storedEditor = (try? c.decodeIfPresent(EditorPreferences.self, forKey: .editor)) ?? nil
        editor = storedEditor ?? EditorPreferences()
        hasEditorPreferences = storedEditor != nil
        updates = ((try? c.decodeIfPresent(AppUpdatePreferences.self, forKey: .updates)) ?? nil) ?? AppUpdatePreferences()
        settingsPane = (try? c.decodeIfPresent(String.self, forKey: .settingsPane)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(skins, forKey: .skins)
        if !favorites.isEmpty { try c.encode(favorites, forKey: .favorites) }
        if !skinOrder.isEmpty { try c.encode(skinOrder, forKey: .skinOrder) }
        if hasLoadedLayout { try c.encode(hasLoadedLayout, forKey: .hasLoadedLayout) }
        if !rainmeterOptions.isEmpty { try c.encode(rainmeterOptions, forKey: .rainmeterOptions) }
        try c.encodeIfPresent(trayMeasureOptions, forKey: .trayMeasureOptions)
        try c.encode(defaultSkinsInstalled, forKey: .defaultSkinsInstalled)
        if !shippedVariables.isEmpty { try c.encode(shippedVariables, forKey: .shippedVariables) }
        try c.encode(editor, forKey: .editor)
        try c.encode(updates, forKey: .updates)
        try c.encodeIfPresent(settingsPane, forKey: .settingsPane)
        var other = encoder.container(keyedBy: AnyCodingKey.self)
        try other.encodeUnknown(unknownKeys, besides: AppStateData.knownKeys)
    }
}

/// Loads and saves `~/Library/Application Support/Deskset/state.json` (debounced).
final class AppState {
    private(set) var data = AppStateData()
    private var saveScheduled = false
    /// Selection edits remain live in memory, while the persisted settings wait for deselection.
    private var selectedSkinSnapshots: [String: SkinState] = [:]
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

    var favorites: [SkinFavorite] { data.favorites }

    func isFavorite(config: String, file: String) -> Bool {
        guard let favorite = SkinFavorite(config: config, file: file) else { return false }
        return data.favorites.contains { $0.matches(favorite) }
    }

    func setFavorite(config: String, file: String, favorite: Bool) {
        guard let item = SkinFavorite(config: config, file: file) else { return }
        let exists = data.favorites.contains { $0.matches(item) }
        guard exists != favorite else { return }
        if favorite { data.favorites.append(item) }
        else { data.favorites.removeAll { $0.matches(item) } }
        scheduleSave()
    }

    func update(_ config: String, _ change: (inout SkinState) -> Void) {
        let key = storedKey(for: config)
        var s = data.skins[key] ?? SkinState(file: "")
        let previousActive = s.active
        let previousFile = s.file
        change(&s)
        if s.active != previousActive || s.file != previousFile {
            s.activeVariant = nil
            s.layoutOptions = s.layoutOptions.filter { $0.key.caseInsensitiveCompare("Active") != .orderedSame }
        }
        s.x = s.x.flatMap(SkinState.position)
        s.y = s.y.flatMap(SkinState.position)
        s.alwaysOnTop = min(max(s.alwaysOnTop, -2), 2)
        s.alphaValue = min(max(s.alphaValue, 0), 255)
        s.fadeDuration = min(max(s.fadeDuration, 0), SkinState.maxFadeDuration)
        s.onHover = min(max(s.onHover, 0), 3)
        s.zoomOverridePercent = s.zoomOverridePercent.map { min(max($0, 10), 500) }
        guard data.skins[key] != s else { return }
        // Preserve the ordering of legacy state files before the first edit starts recording section order.
        if data.skinOrder.isEmpty { data.skinOrder = data.orderedConfigs.map(\.config) }
        data.skins[key] = s
        if !data.skinOrder.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            data.skinOrder.append(key)
        }
        scheduleSave()
    }

    /// The existing key for `config` (any case), so one config never ends up with two entries.
    private func storedKey(for config: String) -> String {
        if data.skins[config] != nil { return config }
        return data.skins.keys.first { $0.caseInsensitiveCompare(config) == .orderedSame } ?? config
    }

    var defaultZoomPercent: Int {
        let key = data.rainmeterOptions.keys.sorted().first { $0.caseInsensitiveCompare("DefaultZoom") == .orderedSame }
        let value = key.flatMap { data.rainmeterOptions[$0] }
        return min(max(LayoutStateCodec.configInteger(value, fallback: 100), 10), 500)
    }

    var forceDefaultZoom: Bool {
        let key = data.rainmeterOptions.keys.sorted().first { $0.caseInsensitiveCompare("ForceDefaultZoom") == .orderedSame }
        let value = key.flatMap { data.rainmeterOptions[$0] }
        return LayoutStateCodec.configInteger(value) != 0
    }

    var disableDragging: Bool { rainmeterFlag("DisableDragging") }
    var fileLoggingEnabled: Bool { rainmeterFlag("Logging") }

    func setDisableDragging(_ enabled: Bool) { setRainmeterFlag("DisableDragging", enabled: enabled) }
    func setFileLoggingEnabled(_ enabled: Bool) { setRainmeterFlag("Logging", enabled: enabled) }

    private func rainmeterFlag(_ name: String) -> Bool {
        let key = data.rainmeterOptions.keys.sorted().first { $0.caseInsensitiveCompare(name) == .orderedSame }
        return LayoutStateCodec.configInteger(key.flatMap { data.rainmeterOptions[$0] }) != 0
    }

    /// Uses the existing INI key, retaining its spelling and unrelated options.
    private func setRainmeterFlag(_ name: String, enabled: Bool) {
        let previous = data.rainmeterOptions
        let key = previous.keys.sorted().first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        data.rainmeterOptions = previous.filter { $0.key == key || $0.key.caseInsensitiveCompare(name) != .orderedSame }
        data.rainmeterOptions[key] = enabled ? "1" : "0"
        guard previous != data.rainmeterOptions else { return }
        scheduleSave()
        NotificationCenter.default.post(name: .desksetGlobalSettingsChanged, object: self)
    }

    /// Changes only supplied values, preserving the original key spelling and other Rainmeter settings.
    func setDefaultZoom(percent: Int?, force: Bool?) {
        let previous = data.rainmeterOptions
        func set(_ key: String, _ value: String) {
            let stored = data.rainmeterOptions.keys.sorted().first {
                $0.caseInsensitiveCompare(key) == .orderedSame
            } ?? key
            data.rainmeterOptions = data.rainmeterOptions.filter {
                $0.key == stored || $0.key.caseInsensitiveCompare(key) != .orderedSame
            }
            data.rainmeterOptions[stored] = value
        }
        if let percent { set("DefaultZoom", String(min(max(percent, 10), 500))) }
        if let force { set("ForceDefaultZoom", force ? "1" : "0") }
        if previous != data.rainmeterOptions { scheduleSave() }
    }

    func setDefaultSkinsInstalled(_ version: Int) {
        data.defaultSkinsInstalled = version
        scheduleSave()
    }

    func setShippedVariables(_ variables: [String: [String: String]]) {
        guard data.shippedVariables != variables else { return }
        data.shippedVariables = variables
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

    var updates: AppUpdatePreferences { data.updates }

    /// Saves only actual changes; the update controller publishes its own state changes to the UI.
    func updateUpdates(_ change: (inout AppUpdatePreferences) -> Void) {
        var preferences = data.updates
        change(&preferences)
        guard preferences != data.updates else { return }
        data.updates = preferences
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

    /// Replaces layout settings and passthrough INI data. Editor, update and installation preferences remain local.
    func replaceLayout(_ layout: LayoutState) {
        let previousFlags = (disableDragging, fileLoggingEnabled)
        data.skins = layout.skins
        data.skinOrder = layout.order
        data.rainmeterOptions = layout.rainmeterOptions
        data.trayMeasureOptions = layout.trayMeasureOptions
        data.hasLoadedLayout = true
        scheduleSave()
        if previousFlags != (disableDragging, fileLoggingEnabled) {
            NotificationCenter.default.post(name: .desksetGlobalSettingsChanged, object: self)
        }
    }

    var orderedConfigs: [(config: String, state: SkinState)] { data.orderedConfigs }

    /// Active configs in LoadOrder, breaking ties by Rainmeter.ini section order.
    var activeConfigs: [(config: String, state: SkinState)] {
        orderedConfigs.enumerated().filter { $0.element.state.active }
            .sorted { ($0.element.state.loadOrder, $0.offset) < ($1.element.state.loadOrder, $1.offset) }
            .map(\.element)
    }

    func beginSkinSelection(_ config: String) {
        let key = storedKey(for: config)
        guard selectedSkinSnapshots[key] == nil, let state = data.skins[key] else { return }
        selectedSkinSnapshots[key] = state
    }

    func endSkinSelection(_ config: String) {
        let key = selectedSkinSnapshots.keys.first { $0.caseInsensitiveCompare(config) == .orderedSame }
        guard let key else { return }
        selectedSkinSnapshots.removeValue(forKey: key)
        scheduleSave()
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
        var persisted = data
        for key in selectedSkinSnapshots.keys.sorted() {
            if persisted.skins[key] != nil { persisted.skins[key] = selectedSkinSnapshots[key] }
        }
        guard let raw = try? encoder.encode(persisted) else { return }
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
