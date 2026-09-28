import AppKit
import DesksetCore

/// The bundled default skins (`DefaultSkins/` in the repository, `Contents/Resources/DefaultSkins` in the app) and what
/// the app does with them (docs/compat/app.md "The default skins and the first launch"):
/// - every folder in it is a root config, copied into the Skins folder when the installed version is older than
///   `version` (the old copy moved to Backups, the user's changed settings carried over into the new
///   `@Resources/Variables.inc`); a root config the bundle no longer ships stays in the Skins folder as it is (the
///   example skins of Deskset 0.1, root config `Deskset`, which the Stationery suite replaced in version 3);
/// - `FirstRun.ini` in it, when there is one, says which skins a new user's desktop starts with, and where;
/// - `Stationery.inc` in the settings folder holds what people type into the Stationery widgets.
enum DefaultSkins {
    /// Bump when the bundled skins change so they are copied again. 3: the Stationery suite replaced the 0.1 examples;
    /// 4: Stationery's player and audio permission states, palette symbols and the strip staying on screen; 5: the
    /// Turntable follows one track straight after another (title, artist and cover), and the Spectrum strip shows its
    /// permission Notice instead of the row of dots.
    static let version = 5

    /// The first-run layout's file, next to the root configs.
    static let firstRunFileName = "FirstRun.ini"

    /// What a new user's desktop starts with when there is no first-run layout, or none of its configs exists: the
    /// Stationery Clock, small.
    static let firstClock = (config: "Stationery\\Clock", file: "Small.ini")

    /// `#SETTINGSPATH#Stationery.inc`: the Stationery widgets' user content (to-do items, cities, launcher items, the
    /// countdown, the timer, the photo folder), outside the skins, which upgrades replace. `!WriteKeyValue` writes only
    /// into a file that exists, so the app makes it (see `AppController.ensureStationeryFile`).
    static let stationeryFileName = "Stationery.inc"
    static let stationeryFileHeader = """
        ; Deskset keeps what you type into the Stationery widgets here: to-do items, cities, launcher items, the
        ; countdown, the timer and the photo folder. The widgets write it themselves; it must exist for them to save.

        """

    /// The root configs in `source`: its folders (not files such as `FirstRun.ini`, not hidden or `@` folders).
    static func rootConfigs(in source: URL) -> [URL]? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]) else { return nil }
        return items.filter { url in
            !url.lastPathComponent.hasPrefix("@")
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Carrying the user's settings over

    /// The `[Variables]` of a file, keys in lower case (`@Include…` left out); nil when it cannot be read.
    static func variables(in file: URL) -> [String: String]? {
        guard let text = try? TextDecoding.readFile(at: file) else { return nil }
        return variables(inText: text)
    }

    static func variables(inText text: String) -> [String: String]? {
        guard let section = IniDocument.parse(text).section(named: "Variables") else { return nil }
        var result: [String: String] = [:]
        for entry in section.entries where !entry.key.lowercased().hasPrefix("@include") {
            let key = entry.key.lowercased()
            if result[key] == nil { result[key] = entry.value }
        }
        return result
    }

    /// Copies `[Variables]` values of `old` (the user's copy of the previous version) into `new` for keys present in
    /// both (new keys and comments stay). With `shipped` (what the previous version shipped), a value the user never
    /// changed from it is left out: the new version's default wins (a 24-hour clock the old skins shipped does not hold
    /// the new "Automatic" back). Without it every value that differs is copied.
    static func carryOverVariables(from old: URL, to new: URL, shipped: [String: String]?) {
        guard let oldText = try? TextDecoding.readFile(at: old),
              let oldVars = IniDocument.parse(oldText).section(named: "Variables"),
              let newText = try? TextDecoding.readFile(at: new),
              let newVars = IniDocument.parse(newText).section(named: "Variables") else { return }
        for entry in newVars.entries where !entry.key.lowercased().hasPrefix("@include") {
            guard let value = oldVars.value(forKey: entry.key), value != entry.value else { continue }
            if let shipped, shipped[entry.key.lowercased()] == value { continue }
            try? IniWriter.writeValue(value, key: entry.key, section: "Variables", fileURL: new)
        }
    }

    /// What an earlier version shipped in a root config's `Variables.inc`, for installs made before the app recorded
    /// it (`AppStateData.shippedVariables`): the example skins of versions 1 and 2 (Deskset 0.1).
    static func shippedVariables(root: String, version: Int) -> [String: String]? {
        guard root == "Deskset", version == 1 || version == 2 else { return nil }
        return variables(inText: version2Variables)
    }

    /// The example skins' `Deskset/@Resources/Variables.inc` of version 2 (Deskset 0.1), as shipped (its
    /// `[Variables]`). The skins themselves are test skins now (TestSkins/Deskset).
    static let version2Variables = #"""
        [Variables]
        Theme=Dark
        @IncludeTheme=#@#Themes/#Theme#.inc
        FontFace=System Font
        Locale=
        DateFormat=%B %#d, %Y
        MonthFormat=%B %Y
        PanelWidth=260
        PanelRadius=16
        Padding=18
        ContentWidth=(#PanelWidth# - 2 * #Padding#)
        TrackHeight=6
        ClockHours=24
        WeekStart=0
        PanelBorderNow=#PanelBorder#
        HoverOn=[!SetVariable PanelBorderNow "#PanelBorderHover#"][!UpdateMeter MeterBackground][!Redraw]
        HoverOff=[!SetVariable PanelBorderNow "#PanelBorder#"][!UpdateMeter MeterBackground][!Redraw]
        ThemeMenuAction=[!WriteKeyValue Variables Theme #ThemeNext# "#@#Variables.inc"][!RefreshGroup Deskset]
        """#
}

/// The first-run layout (`DefaultSkins/FirstRun.ini`): which default skins a new user's desktop starts with, and where.
/// Each section is a config, loaded in the order written; `File` is its .ini (the config's usual one when left out);
/// `X` and `Y` are points from the top-left corner of the main display's visible area — below the menu bar, beside the
/// Dock — so the same file fits every screen. Without the file (or when none of its configs exists) a new user gets
/// the Clock alone.
struct FirstRunLayout: Equatable {
    struct Entry: Equatable {
        var config: String
        var file: String?
        var x: Double?
        var y: Double?

        /// The top-left corner in skin coordinates (the primary screen's top-left, y down), or nil without X and Y.
        func position(visibleFrame: CGRect, primaryHeight: CGFloat) -> (x: Double, y: Double)? {
            guard x != nil || y != nil else { return nil }
            return (Double(visibleFrame.minX) + (x ?? 0), Double(primaryHeight - visibleFrame.maxY) + (y ?? 0))
        }
    }

    var entries: [Entry]

    /// nil when the file is missing, unreadable or names no config.
    static func load(from url: URL) -> FirstRunLayout? {
        guard let text = try? TextDecoding.readFile(at: url) else { return nil }
        let layout = parse(text)
        return layout.entries.isEmpty ? nil : layout
    }

    static func parse(_ text: String) -> FirstRunLayout {
        var entries: [Entry] = []
        for section in IniDocument.parse(text).sections {
            let config = SkinLibrary.normalizedConfigName(section.name)
            guard !config.isEmpty, !entries.contains(where: { $0.config.caseInsensitiveCompare(config) == .orderedSame })
            else { continue }
            func number(_ key: String) -> Double? {
                section.value(forKey: key).flatMap { OptionValue.number($0) }.flatMap { $0.isFinite ? $0 : nil }
                    .map { min(max($0, -SkinState.maxPosition), SkinState.maxPosition) }
            }
            let file = section.value(forKey: "File")?.trimmingCharacters(in: .whitespaces)
            entries.append(Entry(config: config, file: file?.isEmpty == false ? file : nil, x: number("X"), y: number("Y")))
        }
        return FirstRunLayout(entries: entries)
    }
}

extension AppController {
    /// Copies the bundled default skins into the Skins folder when the installed ones are older (`DefaultSkins.version`):
    /// an existing copy is moved to Backups, and the settings the user changed in its `@Resources/Variables.inc` are
    /// carried into the new one. What this version ships there is recorded, so the next upgrade can tell the user's
    /// choices from the old defaults.
    func installDefaultSkinsIfNeeded() {
        guard state.data.defaultSkinsInstalled < DefaultSkins.version, let source = defaultSkinsSource,
              let roots = DefaultSkins.rootConfigs(in: source) else { return }
        let fm = FileManager.default
        let installed = state.data.defaultSkinsInstalled
        var shipped = state.data.shippedVariables
        let inc = "@Resources/Variables.inc"
        for root in roots {
            let name = root.lastPathComponent
            let target = skinsDirectory.appendingPathComponent(name)
            var previous: URL?
            if fm.fileExists(atPath: target.path) {
                // Keep the old copy (users may have edited it) next to the new one.
                let backup = backupsDirectory.appendingPathComponent("\(name)-examples-v\(installed)")
                try? fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
                try? fm.removeItem(at: backup)
                if (try? fm.moveItem(at: target, to: backup)) != nil { previous = backup } else { try? fm.removeItem(at: target) }
            }
            do {
                try fm.copyItem(at: root, to: target)
            } catch {
                Log.write("Could not install example skin \(name): \(error)", level: .error)
                continue
            }
            // Carry over the user's choices (Theme, ClockHours, Volume…) for keys that still exist.
            if let previous {
                DefaultSkins.carryOverVariables(from: previous.appendingPathComponent(inc),
                                                to: target.appendingPathComponent(inc),
                                                shipped: shipped[name] ?? DefaultSkins.shippedVariables(root: name,
                                                                                                        version: installed))
            }
            shipped[name] = DefaultSkins.variables(in: root.appendingPathComponent(inc))
        }
        state.setShippedVariables(shipped)
        state.setDefaultSkinsInstalled(DefaultSkins.version)
        rescanLibrary()
    }

    /// Makes `#SETTINGSPATH#Stationery.inc` when it is missing (never overwritten): the Stationery widgets save into it
    /// with `!WriteKeyValue`, which writes only into a file that exists. At every launch, so a deleted file comes back
    /// empty.
    func ensureStationeryFile() {
        let url = settingsDirectory.appendingPathComponent(DefaultSkins.stationeryFileName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        if !fm.createFile(atPath: url.path, contents: Data(DefaultSkins.stationeryFileHeader.utf8)) {
            Log.write("Could not create \(url.path)", level: .error)
        }
    }

    /// Loads the skins of the first-run layout (`DefaultSkins/FirstRun.ini`) at their places: the configs loaded, in
    /// order; none without the file or when none of its configs exists (the caller then loads the Clock alone).
    func loadFirstRunLayout() -> [String] {
        guard let source = defaultSkinsSource,
              let layout = FirstRunLayout.load(from: source.appendingPathComponent(DefaultSkins.firstRunFileName))
        else { return [] }
        let screens = WindowGeometry.currentScreens()
        let visible = screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let primaryHeight = WindowGeometry.primaryHeight(screens)
        var loaded: [String] = []
        for entry in layout.entries {
            guard let c = activate(config: entry.config, file: entry.file, fade: true, restack: false) else { continue }
            if let p = entry.position(visibleFrame: visible, primaryHeight: primaryHeight) { c.moveTo(x: p.x, y: p.y) }
            loaded.append(c.config)
        }
        if !loaded.isEmpty {
            Log.write("First launch: loaded \(loaded.joined(separator: ", ")) from \(DefaultSkins.firstRunFileName)")
        }
        return loaded
    }
}
