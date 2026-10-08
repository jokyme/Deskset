import DesksetCore
import DeskLanguage
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
    /// Keys this version does not know (written by a newer one), kept as they were and written back, so that going
    /// back to an older version and forward again loses nothing.
    var unknownKeys: [String: JSONValue] = [:]

    init(file: String) {
        self.file = file
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case file, active, x, y, alwaysOnTop, draggable, clickThrough, keepOnScreen, snapEdges, alphaValue,
             savePosition, loadOrder, fadeDuration, onHover, startHidden, autoSelectScreen
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

    /// The keys this version knows, then the ones it kept (`unknownKeys`).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encode(active, forKey: .active)
        try c.encodeIfPresent(x, forKey: .x)
        try c.encodeIfPresent(y, forKey: .y)
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

/// Desk sources and instances have separate opaque identities. Installing a source does not activate a window.
struct DeskWidgetSourceState: Codable, Equatable {
    let id: UUID
    let entry: String
    let packageID: UUID?
    var directoryID: UUID { packageID ?? id }
    var unknownKeys: [String: JSONValue] = [:]

    init(id: UUID, entry: String, packageID: UUID? = nil) {
        self.id = id; self.entry = entry; self.packageID = packageID
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, entry, packageID }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        entry = try c.decode(String.self, forKey: .entry)
        // A damaged optional field must not make the enclosing sources dictionary lose its other members.
        packageID = (try? c.decodeIfPresent(UUID.self, forKey: .packageID)) ?? nil
        unknownKeys = (try? decoder.container(keyedBy: AnyCodingKey.self))?.unknownValues(besides: Self.knownKeys) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(entry, forKey: .entry)
        try c.encodeIfPresent(packageID, forKey: .packageID)
        var other = encoder.container(keyedBy: AnyCodingKey.self)
        try other.encodeUnknown(unknownKeys, besides: Self.knownKeys)
    }
}

struct DeskWidgetInstanceState: Codable, Equatable {
    let id: UUID
    let sourceID: UUID
    var active = false
    var x: Double?
    var y: Double?
    /// Typed option records are interpreted against the currently checked program when it is loaded.
    var optionValues: [String: JSONValue] = [:]
    var unknownKeys: [String: JSONValue] = [:]

    init(id: UUID, sourceID: UUID, active: Bool = false, x: Double? = nil, y: Double? = nil) {
        self.id = id; self.sourceID = sourceID; self.active = active
        self.x = x.flatMap(SkinState.position); self.y = y.flatMap(SkinState.position)
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, sourceID, active, x, y, optionValues }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); sourceID = try c.decode(UUID.self, forKey: .sourceID)
        active = ((try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? nil) ?? false
        x = ((try? c.decodeIfPresent(Double.self, forKey: .x)) ?? nil).flatMap(SkinState.position)
        y = ((try? c.decodeIfPresent(Double.self, forKey: .y)) ?? nil).flatMap(SkinState.position)
        optionValues = (try? c.decode([String: JSONValue].self, forKey: .optionValues)) ?? [:]
        unknownKeys = (try? decoder.container(keyedBy: AnyCodingKey.self))?.unknownValues(besides: Self.knownKeys) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(sourceID, forKey: .sourceID); try c.encode(active, forKey: .active)
        try c.encodeIfPresent(x, forKey: .x); try c.encodeIfPresent(y, forKey: .y)
        if !optionValues.isEmpty { try c.encode(optionValues, forKey: .optionValues) }
        var other = encoder.container(keyedBy: AnyCodingKey.self)
        try other.encodeUnknown(unknownKeys, besides: Self.knownKeys)
    }
}

struct DeskWidgetState: Codable, Equatable {
    var sources: [String: DeskWidgetSourceState] = [:]
    var instances: [String: DeskWidgetInstanceState] = [:]
    var unknownKeys: [String: JSONValue] = [:]
    var isEmpty: Bool { sources.isEmpty && instances.isEmpty && unknownKeys.isEmpty }

    init() {}
    private enum CodingKeys: String, CodingKey, CaseIterable { case sources, instances }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = ((try? c.decodeIfPresent([String: DeskWidgetSourceState].self, forKey: .sources)) ?? nil) ?? [:]
        instances = ((try? c.decodeIfPresent([String: DeskWidgetInstanceState].self, forKey: .instances)) ?? nil) ?? [:]
        unknownKeys = (try? decoder.container(keyedBy: AnyCodingKey.self))?.unknownValues(besides: Self.knownKeys) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sources, forKey: .sources); try c.encode(instances, forKey: .instances)
        var other = encoder.container(keyedBy: AnyCodingKey.self)
        try other.encodeUnknown(unknownKeys, besides: Self.knownKeys)
    }
}

struct AppStateData: Codable {
    /// Keyed by config name (`Root\Sub`).
    var skins: [String: SkinState] = [:]
    var deskWidgets = DeskWidgetState()
    var defaultSkinsInstalled: Int = 0
    /// The `[Variables]` of each bundled root config's `@Resources/Variables.inc` as the installed default skins
    /// shipped them (root config → lower-case key → value): an upgrade carries over only the values the user changed
    /// from these (`DefaultSkins.carryOverVariables`).
    var shippedVariables: [String: [String: String]] = [:]
    /// Settings ▸ Editor.
    var editor = EditorPreferences()
    /// The Settings pane shown last (the window reopens on it).
    var settingsPane: String?
    /// False until the file has held editor preferences: the one moment the old UserDefaults live-reload switch is
    /// carried over (see `AppState.migrateLegacyEditorPreferences`). Not stored.
    var hasEditorPreferences = false
    /// Top-level keys this version does not know (written by a newer one), kept and written back as they were.
    var unknownKeys: [String: JSONValue] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case skins, deskWidgets, defaultSkinsInstalled, shippedVariables, editor, settingsPane
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        unknownKeys = (try? decoder.container(keyedBy: AnyCodingKey.self))?
            .unknownValues(besides: AppStateData.knownKeys) ?? [:]
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skins = ((try? c.decodeIfPresent([String: SkinState].self, forKey: .skins)) ?? nil) ?? [:]
        deskWidgets = ((try? c.decodeIfPresent(DeskWidgetState.self, forKey: .deskWidgets)) ?? nil) ?? DeskWidgetState()
        defaultSkinsInstalled = ((try? c.decodeIfPresent(Int.self, forKey: .defaultSkinsInstalled)) ?? nil) ?? 0
        shippedVariables = ((try? c.decodeIfPresent([String: [String: String]].self, forKey: .shippedVariables)) ?? nil) ?? [:]
        let storedEditor = (try? c.decodeIfPresent(EditorPreferences.self, forKey: .editor)) ?? nil
        editor = storedEditor ?? EditorPreferences()
        hasEditorPreferences = storedEditor != nil
        settingsPane = (try? c.decodeIfPresent(String.self, forKey: .settingsPane)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(skins, forKey: .skins)
        if !deskWidgets.isEmpty { try c.encode(deskWidgets, forKey: .deskWidgets) }
        try c.encode(defaultSkinsInstalled, forKey: .defaultSkinsInstalled)
        if !shippedVariables.isEmpty { try c.encode(shippedVariables, forKey: .shippedVariables) }
        try c.encode(editor, forKey: .editor)
        try c.encodeIfPresent(settingsPane, forKey: .settingsPane)
        var other = encoder.container(keyedBy: AnyCodingKey.self)
        try other.encodeUnknown(unknownKeys, besides: AppStateData.knownKeys)
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

    enum DeskInstallationFailure: Error { case duplicateIdentity, invalidRelation }

    /// The disk state is committed before memory changes. A failed save cannot leave an active or half-registered
    /// Desk source, and this path does not change the legacy debounced writes or INI directory.
    func registerDeskInstallation(source: DeskWidgetSourceState, instance: DeskWidgetInstanceState) throws {
        try registerDeskInstallation(sources: [source], instances: [instance])
    }

    /// One new package directory and all of its initial inactive instances are registered together. A standalone
    /// source keeps the existing single-source contract; an installed directory cannot be extended in place.
    func registerDeskInstallation(sources: [DeskWidgetSourceState], instances: [DeskWidgetInstanceState]) throws {
        precondition(Thread.isMainThread)
        guard let first = sources.first, !instances.isEmpty,
              first.packageID != nil || sources.count == 1 else {
            throw DeskInstallationFailure.invalidRelation
        }
        let directoryID = first.directoryID, directory = directoryID.uuidString.lowercased()
        let sourceIDs = Set(sources.map(\.id)), instanceIDs = Set(instances.map(\.id))
        guard sourceIDs.count == sources.count, instanceIDs.count == instances.count,
              sourceIDs.allSatisfy({ data.deskWidgets.sources[$0.uuidString.lowercased()] == nil }),
              instanceIDs.allSatisfy({ data.deskWidgets.instances[$0.uuidString.lowercased()] == nil }),
              !data.deskWidgets.sources.values.contains(where: { $0.directoryID == directoryID }) else {
            throw DeskInstallationFailure.duplicateIdentity
        }
        var members = Set<String>()
        for source in sources {
            let parts = source.entry.split(separator: "/", omittingEmptySubsequences: false)
            guard source.packageID == first.packageID, source.directoryID == directoryID,
                  parts.count == 2, parts[0] == directory,
                  !parts[1].isEmpty, parts[1] != ".", parts[1] != "..", !parts[1].contains("\\"),
                  !source.entry.contains("\0"), parts[1].lowercased().hasSuffix(".desk") else {
                throw DeskInstallationFailure.invalidRelation
            }
            let name = String(parts[1])
            if source.packageID != nil {
                guard !DeskPackagePath.isPackageFile(name), !DeskPackagePath.isIgnoredName(name) else {
                    throw DeskInstallationFailure.invalidRelation
                }
            }
            guard members.insert(DeskPackagePath.foldedKey(name)).inserted else {
                throw DeskInstallationFailure.duplicateIdentity
            }
        }
        guard instances.allSatisfy({ !$0.active && sourceIDs.contains($0.sourceID) }),
              Set(instances.map(\.sourceID)) == sourceIDs else {
            throw DeskInstallationFailure.invalidRelation
        }
        var next = data
        for source in sources { next.deskWidgets.sources[source.id.uuidString.lowercased()] = source }
        for instance in instances { next.deskWidgets.instances[instance.id.uuidString.lowercased()] = instance }
        try write(next)
        data = next
    }

    func deskInstance(_ id: UUID) -> DeskWidgetInstanceState? {
        data.deskWidgets.instances[id.uuidString.lowercased()]
    }

    enum DeskOptionsSaveFailure: Error { case instanceChanged, valueLimit, totalLimit }

    /// Only a successfully written snapshot becomes durable state. Position/activation changes and unknown
    /// fields come from the latest instance, rather than from the panel's older copy.
    func saveDeskOptions(_ id: UUID, sourceID: UUID, values: [String: JSONValue]) throws {
        precondition(Thread.isMainThread)
        let key = id.uuidString.lowercased()
        guard var instance = data.deskWidgets.instances[key], instance.sourceID == sourceID else {
            throw DeskOptionsSaveFailure.instanceChanged
        }
        try DeskProgramOptionStore.validateSize(values)
        guard instance.optionValues != values else { return }
        instance.optionValues = values
        var next = data
        next.deskWidgets.instances[key] = instance
        try write(next)
        data = next
    }

    func deskSource(_ id: UUID) -> DeskWidgetSourceState? {
        data.deskWidgets.sources[id.uuidString.lowercased()]
    }

    var activeDeskWidgets: [(instance: DeskWidgetInstanceState, source: DeskWidgetSourceState)] {
        data.deskWidgets.instances.values
            .filter { $0.active }
            .compactMap { instance in
                guard let source = data.deskWidgets.sources[instance.sourceID.uuidString.lowercased()] else { return nil }
                return (instance: instance, source: source)
            }
            .sorted { $0.instance.id.uuidString < $1.instance.id.uuidString }
    }

    func updateDeskInstance(_ id: UUID, _ change: (inout DeskWidgetInstanceState) -> Void) {
        precondition(Thread.isMainThread)
        let key = id.uuidString.lowercased()
        guard var instance = data.deskWidgets.instances[key] else { return }
        change(&instance)
        instance.x = instance.x.flatMap(SkinState.position)
        instance.y = instance.y.flatMap(SkinState.position)
        guard data.deskWidgets.instances[key] != instance else { return }
        data.deskWidgets.instances[key] = instance
        scheduleSave()
    }

    func saveNow() {
        saveScheduled = false
        try? write(data)
    }

    private func write(_ value: AppStateData) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let raw = try encoder.encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try raw.write(to: fileURL, options: .atomic)
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
