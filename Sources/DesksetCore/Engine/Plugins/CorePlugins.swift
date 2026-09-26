import Darwin
import Foundation

// Rainmeter's bundled plugins that need no Apple UI / media frameworks (manual: /manual/plugins/ and the
// deprecated plugins, plus the RecycleManager measure), and third-party plugins that need nothing from the app
// (Mouse, and Slider, its version 2). Clean-room implementations from the public manual and the plugins' public
// documentation only; every Mac-vs-Windows difference is listed in docs/compat/plugins.md.

/// Registration entry point for the core plugins. The app calls `CorePlugins.register()` once at startup, before
/// skins load; `Skin.makeMeasure` then finds the types through `MeasureRegistry`.
public enum CorePlugins {
    /// `Plugin=` names (with every legacy alias skins use) → measure types. `MeasureRegistry` strips folders and
    /// `.dll`, and ignores case, so `Plugins\PingPlugin.dll` finds `PingPlugin`.
    public static let pluginTypes: [(name: String, type: Measure.Type)] = [
        ("ActionTimer", ActionTimerMeasure.self),
        ("CoreTemp", CoreTempMeasure.self),
        ("AdvancedCPU", AdvancedCPUMeasure.self),
        ("PingPlugin", PingMeasure.self),
        ("Ping", PingMeasure.self),
        ("RunCommand", RunCommandMeasure.self),
        ("QuotePlugin", QuoteMeasure.self),
        ("Quote", QuoteMeasure.self),
        ("FileView", FileViewMeasure.self),
        ("FolderInfo", FolderInfoMeasure.self),
        ("RecycleManager", RecycleManagerMeasure.self),
        ("UsageMonitor", UsageMonitorMeasure.self),
        ("PerfMon", PerfMonMeasure.self),
        ("PerfMonPlugin", PerfMonMeasure.self),
        ("ResMon", ResMonMeasure.self),
        ("SpeedFanPlugin", SpeedFanMeasure.self),
        ("SpeedFan", SpeedFanMeasure.self),
        ("WindowMessagePlugin", WindowMessageMeasure.self),
        ("WindowMessage", WindowMessageMeasure.self),
        ("VirtualDesktops", VirtualDesktopsMeasure.self),
        ("Mouse", MouseMeasure.self),
        ("Slider", SliderMeasure.self),
    ]

    /// `Measure=` types provided here (RecycleManager "was previously a plugin measure").
    public static let measureTypes: [(name: String, type: Measure.Type)] = [
        ("RecycleManager", RecycleManagerMeasure.self),
    ]

    /// Registers every core plugin with `MeasureRegistry`. Safe to call more than once.
    public static func register() {
        for entry in pluginTypes { MeasureRegistry.registerPlugin(entry.name, entry.type) }
        for entry in measureTypes { MeasureRegistry.registerMeasure(entry.name, entry.type) }
    }
}

// MARK: - Lifecycle

/// Measures that own timers, background work or child processes. Their `deinit` stops everything once the skin object
/// is released; `skinWillClose()` lets the engine stop them as soon as the skin is unloaded or refreshed (call it from
/// `Skin.close()`, after OnCloseAction). After it, the measure starts no new work and runs no more actions.
public protocol PluginLifecycle: AnyObject {
    func skinWillClose()
}

// MARK: - Hardware sensors

/// Temperatures, fans, voltages and GPU load. macOS has no public API for these (SMC keys change with every Apple
/// chip and need privileges), so nothing implements this protocol yet: CoreTemp / SpeedFan / thermal counters report 0
/// until the app provides a source (`skin.system` conforming to it, or `HardwareSensors.source`).
/// Every requirement has a default (nil / empty), so a source implements only what it can read.
public protocol HardwareSensorSource: AnyObject {
    /// °C per CPU core (index 0 = first core).
    func cpuCoreTemperatures() -> [Double]?
    /// °C of the hottest core / the CPU package.
    func cpuPackageTemperature() -> Double?
    /// °C, maximum junction temperature.
    func cpuTjMax() -> Double?
    /// MHz per core.
    func cpuCoreFrequencies() -> [Double]?
    /// Watts drawn by the CPU.
    func cpuPower() -> Double?
    /// Thermal design power in watts.
    func cpuTDP() -> Double?
    /// Core voltage (VID) in volts.
    func cpuVoltage() -> Double?
    /// All temperature sensors in °C (SpeedFan `SpeedFanNumber` indexes this list).
    func temperatures() -> [Double]
    /// All fans in RPM.
    func fanSpeeds() -> [Double]
    /// All voltage sensors in volts.
    func voltages() -> [Double]
    /// GPU utilisation 0…100.
    func gpuUtilization() -> Double?
}

extension HardwareSensorSource {
    public func cpuCoreTemperatures() -> [Double]? { nil }
    public func cpuPackageTemperature() -> Double? { cpuCoreTemperatures()?.max() }
    public func cpuTjMax() -> Double? { nil }
    public func cpuCoreFrequencies() -> [Double]? { nil }
    public func cpuPower() -> Double? { nil }
    public func cpuTDP() -> Double? { nil }
    public func cpuVoltage() -> Double? { nil }
    public func temperatures() -> [Double] { cpuCoreTemperatures() ?? [] }
    public func fanSpeeds() -> [Double] { [] }
    public func voltages() -> [Double] { [] }
    public func gpuUtilization() -> Double? { nil }
}

/// Where plugins look for hardware sensors: `skin.system` when it conforms to `HardwareSensorSource`, else `source`.
public enum HardwareSensors {
    /// Set by the app when it can read sensors (e.g. a Pro sensor helper). Main thread only.
    public static var source: HardwareSensorSource?

    static func source(for skin: Skin) -> HardwareSensorSource? {
        (skin.system as? HardwareSensorSource) ?? source
    }
}

// MARK: - Paths

/// Folder and file paths as written in Windows skins, mapped onto the Mac.
///
/// Judgment calls (the manual only says paths may be absolute or relative to the skin folder):
/// - surrounding quotes are removed and `\` becomes `/`;
/// - Windows environment variables that plugins expand (`%USERPROFILE%`, `%HOMEDRIVE%%HOMEPATH%`, `%APPDATA%`,
///   `%TEMP%`, …) map to their Mac counterparts; other `%NAME%` use the process environment or stay as written;
/// - `C:\Users\<anyone>\…` becomes the home folder (with `Videos` → `Movies` and the old `My Pictures` style names),
///   `C:\Program Files…\` becomes `/Applications/`, any other drive letter path becomes the same path under `/`;
/// - `~` is the home folder; a relative path is relative to the skin's folder.
enum PluginPaths {
    static func resolve(_ raw: String, skin: Skin) -> String {
        resolve(raw, relativeTo: skin.directory.path)
    }

    static func resolve(_ raw: String, relativeTo base: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count >= 2, p.hasPrefix("\""), p.hasSuffix("\"") { p = String(p.dropFirst().dropLast()) }
        p = expandEnvironment(p).replacingOccurrences(of: "\\", with: "/")
        if p.isEmpty { return base }
        let home = NSHomeDirectory()
        if p == "~" || p.hasPrefix("~/") { return standardize(home + p.dropFirst()) }
        let u = Array(p.utf8.prefix(3))
        let hasDrive = u.count >= 2 && u[1] == UInt8(ascii: ":")
            && (u[0] | 0x20) >= UInt8(ascii: "a") && (u[0] | 0x20) <= UInt8(ascii: "z")
        if hasDrive {
            var rest = String(p.dropFirst(2))
            if !rest.hasPrefix("/") { rest = "/" + rest }
            p = mapWindowsRoot(rest)
        }
        if !p.hasPrefix("/") {
            p = (base.hasSuffix("/") ? base : base + "/") + p
        }
        return standardize(p)
    }

    /// `/Users/Name/Pictures/x` (from `C:\Users\Name\Pictures\x`) → `~/Pictures/x`, etc.
    private static func mapWindowsRoot(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first?.lowercased() else { return "/" }
        if first == "users" || first == "documents and settings", parts.count >= 2 {
            var rest = Array(parts.dropFirst(2))
            if let known = rest.first.flatMap(knownFolder) { rest[0] = known }
            if rest.count >= 2, rest[0].lowercased() == "appdata" {
                rest = ["Library", "Application Support"] + rest.dropFirst(2)
            }
            return ([NSHomeDirectory()] + rest).joined(separator: "/")
        }
        if first.hasPrefix("program files") {
            return "/Applications/" + parts.dropFirst().joined(separator: "/")
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func knownFolder(_ name: String) -> String? {
        switch name.lowercased() {
        case "videos", "my videos": return "Movies"
        case "my pictures": return "Pictures"
        case "my music": return "Music"
        case "my documents": return "Documents"
        default: return nil
        }
    }

    /// `%NAME%` → Mac value.
    static func expandEnvironment(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "%") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "%") else {
                out += rest[open...]
                return out
            }
            let name = String(rest[afterOpen..<close])
            if let value = environmentValue(name) {
                out += value
                rest = rest[rest.index(after: close)...]
            } else {
                out += "%"
                rest = rest[afterOpen...]
            }
        }
        return out + rest
    }

    static func environmentValue(_ name: String) -> String? {
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_()".unicodeScalars.contains($0) })
        else { return nil }
        let home = NSHomeDirectory()
        switch name.uppercased() {
        case "USERPROFILE", "HOMEPATH", "HOME": return home
        case "HOMEDRIVE", "SYSTEMDRIVE": return ""
        case "APPDATA", "LOCALAPPDATA": return home + "/Library/Application Support"
        case "TEMP", "TMP":
            let t = NSTemporaryDirectory()
            return t.hasSuffix("/") ? String(t.dropLast()) : t
        case "PUBLIC": return "/Users/Shared"
        case "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432": return "/Applications"
        case "PROGRAMDATA", "ALLUSERSPROFILE": return "/Library/Application Support"
        case "WINDIR", "SYSTEMROOT": return "/System"
        case "USERNAME": return NSUserName()
        default: return ProcessInfo.processInfo.environment[name]
        }
    }

    private static func standardize<S: StringProtocol>(_ p: S) -> String {
        let s = String(p)
        let trailing = s.count > 1 && s.hasSuffix("/")
        let standardized = (s as NSString).standardizingPath
        return trailing && !standardized.hasSuffix("/") ? standardized + "/" : standardized
    }
}

// MARK: - Shared helpers

/// Wildcard filters (`*.jpg;*.png`, `*`), matched case-insensitively like Windows file names.
struct WildcardFilter {
    let patterns: [String]

    /// `list` separated by `;` (blank entries ignored). An empty list matches everything.
    init(_ list: String, separator: Character = ";") {
        patterns = list.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool { patterns.isEmpty }

    func matches(_ name: String) -> Bool {
        if patterns.isEmpty { return true }
        return patterns.contains { WildcardFilter.match($0, name) }
    }

    /// `*` and `?` (Windows semantics: `*.*` matches every name, even without a dot).
    static func match(_ pattern: String, _ name: String) -> Bool {
        if pattern == "*" || pattern == "*.*" { return true }
        return fnmatch(pattern, name, FNM_CASEFOLD | FNM_NOESCAPE) == 0
    }
}

/// Names of Finder / file system bookkeeping files: the macOS counterpart of Windows "system" files
/// (`IncludeSystemFiles`, `ShowSystem`). They are hidden files as well.
enum MacSystemFiles {
    static let names: Set<String> = [
        ".ds_store", ".localized", ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems",
        ".documentrevisions-v100", ".volumeicon.icns", ".com.apple.timemachine.donotpresent", ".apdisk",
        ".pkinstallsandboxmanager", ".pkinstallsandboxmanager-systemsoftware", ".file", ".vol", ".hotfiles.btree",
        "icon\r",
    ]

    static func isSystem(_ name: String) -> Bool {
        names.contains(name.lowercased()) || name.hasPrefix("._")
    }
}

/// Reads the leading number of a text (`"12.5 ms"` → 12.5), 0 when there is none.
func leadingNumber(_ text: String) -> Double {
    var s = Substring(text).drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    var end = s.startIndex
    var seenDigit = false, seenDot = false
    if end < s.endIndex, s[end] == "-" || s[end] == "+" { end = s.index(after: end) }
    while end < s.endIndex {
        let c = s[end]
        if c.isASCII && c.isNumber {
            seenDigit = true
        } else if c == "." && !seenDot {
            seenDot = true
        } else {
            break
        }
        end = s.index(after: end)
    }
    guard seenDigit else { return 0 }
    s = s[..<end]
    return Double(s) ?? 0
}

/// Thread-safe cancellation flag shared with background work.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
}

extension Measure {
    /// Sets the measure's values between updates (asynchronous results), applying InvertMeasure like an update
    /// would, so that the actions run right after (FinishAction…) already see them. Disabled / paused measures keep
    /// what they have until their next update.
    func publishAsyncResult(number: Double, string: String?) {
        guard !disabled && !paused else { return }
        rawString = string
        let v = number.isFinite ? number : 0
        value = invert ? maxValue - (v - minValue) : v
    }
}
