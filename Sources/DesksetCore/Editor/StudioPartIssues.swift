import Foundation

/// What in a part of an INI widget needs attention on a Mac — the amber dots of the Studio's Layers list and the
/// canvas's marks: the data it shows cannot be read on a Mac (a Windows plug-in or a Windows-only measure, also when a
/// formula or a text built from it is what the part shows), or a click opens a Windows program, file or folder.
public enum StudioPartIssue: Equatable {
    /// The part shows data that reads 0 here: `measure` is the data that cannot be read, `plugin` its plug-in's name
    /// when it is one ("HWiNFO").
    case windowsData(measure: String, plugin: String?)
    /// A mouse action of the part (`key`) opens `target`, a Windows path ("C:\…\steam.exe").
    case windowsProgram(key: String, target: String)

    /// The file name a Windows path ends in, without `.exe` ("steam"), or the folder's name.
    public var programName: String? {
        guard case .windowsProgram(_, let target) = self else { return nil }
        return StudioPartIssues.programName(target)
    }
}

public enum StudioPartIssues {
    /// The mouse actions of a meter, in the order the Studio reads them.
    public static let actionKeys = [
        "LeftMouseUpAction", "LeftMouseDownAction", "LeftMouseDoubleClickAction",
        "RightMouseUpAction", "RightMouseDownAction", "RightMouseDoubleClickAction",
        "MiddleMouseUpAction", "MiddleMouseDownAction", "MiddleMouseDoubleClickAction",
        "MouseOverAction", "MouseLeaveAction", "MouseScrollUpAction", "MouseScrollDownAction",
    ]

    /// Whether `m` cannot read its data on a Mac: a Windows plug-in (a DLL, or a plug-in the Studio knows only runs on
    /// Windows), or a Windows-only measure type.
    public static func isWindowsOnly(_ m: Measure) -> Bool {
        if let u = m as? UnsupportedMeasure, u.isMacDifference { return true }
        return EditorSchema.measureType(type: m.rawOption("Measure") ?? m.type, plugin: m.rawOption("Plugin"))?
            .supportedOnMac == false
    }

    /// The Windows-only data `m` shows: itself, or the data a formula or text built from it reads (a few steps deep).
    public static func windowsSource(of m: Measure, in skin: Skin) -> Measure? {
        var current: Measure? = m
        var seen: Set<ObjectIdentifier> = []
        while let c = current, seen.insert(ObjectIdentifier(c)).inserted, seen.count <= 6 {
            if isWindowsOnly(c) { return c }
            guard ["calc", "string", "script"].contains(c.type) else { return nil }
            current = LayerNaming.formulaSource(c, in: skin) ?? referencedData(c, in: skin)
        }
        return nil
    }

    /// The first measure a Calc's formula or a String measure's text names (`Formula=MeasureCPUTemp`,
    /// `String=[MeasureTemp]°`).
    static func referencedData(_ m: Measure, in skin: Skin) -> Measure? {
        for key in ["Formula", "String"] {
            guard let text = m.rawOption(key) else { continue }
            for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
                if let found = skin.measure(named: String(word)), found !== m { return found }
            }
        }
        return nil
    }

    /// Whether `target` (what an action opens) is a Windows path: a drive letter (`C:\`, `D:/`), a UNC path
    /// (`\\server\…`), a Windows program (`.exe`, `.bat`, `.cmd`, `.lnk`, `.msc`), or a path written with backslashes
    /// only.
    public static func isWindowsPath(_ target: String) -> Bool {
        let t = target.trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
        guard !t.isEmpty else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") { return false }
        let scalars = Array(t.unicodeScalars)
        if scalars.count >= 3, CharacterSet.letters.contains(scalars[0]), scalars[1] == ":",
           scalars[2] == "\\" || scalars[2] == "/" { return true }
        if t.hasPrefix("\\\\") { return true }
        let name = lower.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? lower
        for ext in [".exe", ".bat", ".cmd", ".lnk", ".msc", ".cpl"] where name.hasSuffix(ext) { return true }
        return t.contains("\\") && !t.contains("/")
    }

    /// The name of what a Windows path opens: its file without the extension, or its last folder ("steam",
    /// "Documents").
    public static func programName(_ target: String) -> String? {
        let t = target.trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
        let parts = t.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        guard var last = parts.last.map(String.init), !last.isEmpty else { return nil }
        if let dot = last.lastIndex(of: "."), last.distance(from: dot, to: last.endIndex) <= 5 {
            last = String(last[..<dot])
        }
        return last.isEmpty ? nil : last
    }

    /// What needs attention in `meter`: each Windows-only data it shows (once), then each action that opens a Windows
    /// path.
    public static func issues(of meter: Meter, in skin: Skin) -> [StudioPartIssue] {
        var result: [StudioPartIssue] = []
        for bound in meter.measures {
            guard let source = windowsSource(of: bound, in: skin) else { continue }
            let plugin = source.rawOption("Measure")?.trimmingCharacters(in: .whitespaces).lowercased() == "plugin"
                ? source.rawOption("Plugin").map(pluginName) : nil
            let issue = StudioPartIssue.windowsData(measure: source.name, plugin: plugin)
            if !result.contains(issue) { result.append(issue) }
        }
        for key in actionKeys {
            let action = meter.actionOption(key)
            guard !action.isEmpty else { continue }
            for a in ActionParser.parse(action) {
                if case .execute(let target, _) = a, isWindowsPath(target) {
                    result.append(.windowsProgram(key: key, target: target))
                    break
                }
            }
        }
        return result
    }

    /// What needs attention in a data item: it cannot be read on a Mac (or is built from data that cannot).
    public static func issue(of measure: Measure, in skin: Skin) -> StudioPartIssue? {
        guard let source = windowsSource(of: measure, in: skin) else { return nil }
        let plugin = source.rawOption("Measure")?.trimmingCharacters(in: .whitespaces).lowercased() == "plugin"
            ? source.rawOption("Plugin").map(pluginName) : nil
        return .windowsData(measure: source.name, plugin: plugin)
    }

    /// A plug-in's name as people know it: the file name without `.dll` ("HWiNFO").
    static func pluginName(_ raw: String) -> String {
        var n = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if let slash = n.lastIndex(of: "/") { n = String(n[n.index(after: slash)...]) }
        if n.lowercased().hasSuffix(".dll") { n.removeLast(4) }
        return n
    }
}
