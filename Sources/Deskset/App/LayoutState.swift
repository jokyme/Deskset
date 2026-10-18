import DesksetCore
import Foundation

struct LayoutSaveOptions: Equatable {
    var empty = false
    var excludeUnloaded = false
    var includeWallpaper = false
}

struct LayoutState {
    var skins: [String: SkinState]
    var order: [String]
    var rainmeterOptions: [String: String] = [:]
    var trayMeasureOptions: [String: String]? = nil

    /// Ordinary layouts retain selected existing settings. Loading the automatic backup bypasses this merge.
    func preservingSettings(from previous: LayoutState) -> LayoutState {
        var result = self
        var target = LayoutStateCodec.section("Rainmeter", options: rainmeterOptions)
        let old = LayoutStateCodec.section("Rainmeter", options: previous.rainmeterOptions)
        for key in ["SkinPath", "ConfigEditor", "Logging", "DisableVersionCheck", "DisableAutoUpdate", "Language",
                    "NormalStayDesktop", "SelectedColor", "HardwareAcceleration"] {
            if let value = old[key], !value.isEmpty { target.setValue(value, forKey: key) }
        }
        for key in ["TrayExecuteM", "TrayExecuteR", "TrayExecuteDM", "TrayExecuteDR"] {
            if (target[key] ?? "").isEmpty, let value = old[key], !value.isEmpty {
                target.setValue(value, forKey: key)
            }
        }
        result.rainmeterOptions = LayoutStateCodec.options(in: target)
        return result
    }
}

/// The state.json representation stays private to the app; saved layouts use Rainmeter's documented INI keys.
/// https://docs.rainmeter.net/manual/settings/skin-sections/
enum LayoutStateCodec {
    /// Keep a stable alphabetical variant order for layout indices across scans.
    static func variants(in config: SkinConfig) -> [String] {
        config.files.sorted(by: alphabeticallyBefore)
    }

    static func capture(_ data: AppStateData, library: [SkinConfig], options: LayoutSaveOptions) -> IniDocument {
        guard !options.empty else { return IniDocument(sections: []) }
        var result = IniDocument(sections: [section("Rainmeter", options: data.rainmeterOptions)])
        if let options = data.trayMeasureOptions { result.sections.append(section("TrayMeasure", options: options)) }
        for (config, state) in data.orderedConfigs {
            var section = IniSection(name: config, entries: state.layoutOptions.keys.sorted(by: alphabeticallyBefore)
                .map { IniEntry(key: $0, value: state.layoutOptions[$0]!) })
            func set(_ key: String, _ value: String) { section.setValue(value, forKey: key) }
            func flag(_ key: String, _ value: Bool) { set(key, value ? "1" : "0") }
            let files = library.first { $0.name.caseInsensitiveCompare(config) == .orderedSame }.map(variants) ?? []
            let currentIndex = files.firstIndex { $0.caseInsensitiveCompare(state.file) == .orderedSame }.map { $0 + 1 }
            // Preserve imported text unless activation changed or the installed variant now has a different index.
            if state.activeVariant == nil || (state.active && currentIndex != nil && currentIndex != state.activeVariant) {
                var active = 0
                if state.active {
                    active = currentIndex ?? state.activeVariant ?? 1
                }
                set("Active", String(active))
            }
            if options.excludeUnloaded && section["Active"] == "0" { continue }
            set("WindowX", state.windowX ?? number(state.x ?? 0))
            set("WindowY", state.windowY ?? number(state.y ?? 0))
            set("AnchorX", state.anchorX ?? "0")
            set("AnchorY", state.anchorY ?? "0")
            set("AlwaysOnTop", String(state.alwaysOnTop))
            flag("Draggable", state.draggable)
            flag("ClickThrough", state.clickThrough)
            flag("KeepOnScreen", state.keepOnScreen)
            flag("SnapEdges", state.snapEdges)
            flag("SavePosition", state.savePosition)
            flag("StartHidden", state.startHidden)
            flag("AutoSelectScreen", state.autoSelectScreen)
            set("AlphaValue", String(state.alphaValue))
            set("LoadOrder", String(state.loadOrder))
            set("FadeDuration", String(state.fadeDuration))
            set("OnHover", String(state.onHover))
            if let group = state.group { set("Group", group) }
            if let group = state.dragGroup { set("DragGroup", group) }
            // Zoom is the native Rainmeter 5.0 percentage. Do not invent a ZoomFactor layout key.
            if state.zoomFactor != 1 || section["Zoom"] != nil { set("Zoom", number(state.zoomFactor * 100)) }
            result.sections.append(section)
        }
        return result
    }

    static func decode(_ document: IniDocument, library: [SkinConfig]) -> LayoutState {
        var result = LayoutState(skins: [:], order: [])
        if let section = document.section(named: "Rainmeter") { result.rainmeterOptions = options(in: section) }
        if let section = document.section(named: "TrayMeasure") { result.trayMeasureOptions = options(in: section) }
        for section in document.sections {
            guard section.name.caseInsensitiveCompare("Rainmeter") != .orderedSame,
                  section.name.caseInsensitiveCompare("TrayMeasure") != .orderedSame else { continue }
            let config = SkinLibrary.normalizedConfigName(section.name)
            // Config names are relative paths under Skins, never absolute paths or parent traversals.
            let parts = config.split(separator: "\\", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ LayoutStore.isValidName(String($0)) }),
                  !result.order.contains(where: { $0.caseInsensitiveCompare(config) == .orderedSame }) else { continue }
            func value(_ key: String) -> Double? {
                section[key].flatMap(OptionValue.number).flatMap { $0.isFinite ? $0 : nil }
            }
            func integer(_ key: String, _ fallback: Int, range: ClosedRange<Double>) -> Int {
                value(key).map { Int(min(max($0.rounded(.towardZero), range.lowerBound), range.upperBound)) } ?? fallback
            }
            func flag(_ key: String, _ fallback: Bool) -> Bool { value(key).map { $0 != 0 } ?? fallback }
            let active = max(0, configInteger(section["Active"]))
            let files = library.first { $0.name.caseInsensitiveCompare(config) == .orderedSame }.map(variants) ?? []
            var state = SkinState(file: active > 0 && active <= files.count ? files[active - 1] : "")
            state.active = active > 0
            state.activeVariant = active
            state.windowX = section["WindowX"] ?? "0"
            state.windowY = section["WindowY"] ?? "0"
            state.anchorX = section["AnchorX"] ?? "0"
            state.anchorY = section["AnchorY"] ?? "0"
            state.group = section["Group"]
            state.dragGroup = section["DragGroup"]
            for entry in section.entries { state.layoutOptions[entry.key] = entry.value }
            state.alwaysOnTop = integer("AlwaysOnTop", 0, range: -2...2)
            state.draggable = flag("Draggable", true)
            state.clickThrough = flag("ClickThrough", false)
            state.keepOnScreen = flag("KeepOnScreen", true)
            state.snapEdges = flag("SnapEdges", true)
            state.savePosition = flag("SavePosition", true)
            state.startHidden = flag("StartHidden", false)
            state.autoSelectScreen = flag("AutoSelectScreen", false)
            state.alphaValue = integer("AlphaValue", 255, range: 0...255)
            state.loadOrder = configInteger(section["LoadOrder"])
            state.fadeDuration = integer("FadeDuration", 250, range: 0...Double(SkinState.maxFadeDuration))
            state.onHover = integer("OnHover", 0, range: 0...3)
            state.zoomFactor = value("Zoom").map { min(max($0 / 100, 0.1), 5) } ?? 1
            result.skins[config] = state
            result.order.append(config)
        }
        return result
    }

    static func alphabeticallyBefore(_ a: String, _ b: String) -> Bool {
        let result = a.compare(b, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return result == .orderedSame ? a < b : result == .orderedAscending
    }

    fileprivate static func section(_ name: String, options: [String: String]) -> IniSection {
        IniSection(name: name, entries: options.keys.sorted(by: alphabeticallyBefore)
            .map { IniEntry(key: $0, value: options[$0]!) })
    }

    fileprivate static func options(in section: IniSection) -> [String: String] {
        section.entries.reduce(into: [:]) { $0[$1.key] = $1.value }
    }

    /// Active and LoadOrder use a decimal integer prefix, or a parenthesized formula truncated toward zero.
    private static func configInteger(_ value: String?) -> Int {
        guard let value else { return 0 }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let number: Double?
        if text.hasPrefix("(") {
            number = OptionValue.number(text)
        } else {
            let bytes = Array(text.utf8)
            var end = bytes.first == 0x2B || bytes.first == 0x2D ? 1 : 0
            let start = end
            while end < bytes.count, bytes[end] >= 0x30, bytes[end] <= 0x39 { end += 1 }
            guard end > start else { return 0 }
            number = Double(String(decoding: bytes[..<end], as: UTF8.self))
            if let number, number < Double(Int32.min) || number > Double(Int32.max) { return 0 }
        }
        guard let number, number.isFinite else { return 0 }
        return Int(min(max(number.rounded(.towardZero), Double(Int32.min)), Double(Int32.max)))
    }

    private static func number(_ value: Double) -> String {
        if value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max), value.rounded() == value {
            return String(Int(value))
        }
        return value.isFinite ? String(value) : "0"
    }
}

extension AppStateData {
    /// Old state files have no stored section order; append those configs in a deterministic order.
    var orderedConfigs: [(config: String, state: SkinState)] {
        var result: [(config: String, state: SkinState)] = []
        var seen = Set<String>()
        let keys = skins.keys.sorted(by: LayoutStateCodec.alphabeticallyBefore)
        for requested in skinOrder {
            guard let key = keys.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }),
                  seen.insert(key.lowercased()).inserted, let state = skins[key] else { continue }
            result.append((key, state))
        }
        for key in keys where seen.insert(key.lowercased()).inserted {
            if let state = skins[key] { result.append((key, state)) }
        }
        return result
    }
}
