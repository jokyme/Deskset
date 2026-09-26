import Foundation

/// Measure types provided outside Engine/: `Measure=Plugin` plugins (`Plugin=AudioLevel`, `Plugin=Plugins\X.dll`,
/// matched by lowercased name without folder and `.dll`) and extra `Measure=` types such as `Script` (Lua).
///
/// DesksetCore plugins register from their own `register()` functions, app-side plugins (which need AppKit or other
/// system frameworks) register at app start. `Skin.makeMeasure` consults this registry before its built-in switch.
public enum MeasureRegistry {
    private static var plugins: [String: Measure.Type] = [:]
    private static var measures: [String: Measure.Type] = [:]
    private static let lock = NSLock()

    /// `name` as written in `Plugin=` (any case, with or without folder / `.dll`).
    public static func registerPlugin(_ name: String, _ type: Measure.Type) {
        lock.lock(); defer { lock.unlock() }
        plugins[normalizedPluginName(name)] = type
    }

    /// `name` as written in `Measure=` (any case).
    public static func registerMeasure(_ name: String, _ type: Measure.Type) {
        lock.lock(); defer { lock.unlock() }
        measures[name.trimmingCharacters(in: .whitespaces).lowercased()] = type
    }

    public static func plugin(named name: String) -> Measure.Type? {
        lock.lock(); defer { lock.unlock() }
        return plugins[normalizedPluginName(name)]
    }

    public static func measure(named name: String) -> Measure.Type? {
        lock.lock(); defer { lock.unlock() }
        return measures[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Every registered `Plugin=` name (normalized, see `normalizedPluginName`) with its type.
    public static var registeredPlugins: [String: Measure.Type] {
        lock.lock(); defer { lock.unlock() }
        return plugins
    }

    /// Every registered `Measure=` name (lowercased) with its type.
    public static var registeredMeasures: [String: Measure.Type] {
        lock.lock(); defer { lock.unlock() }
        return measures
    }

    /// `Plugins\WebParser.dll` → `webparser`.
    public static func normalizedPluginName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.lowercased().hasSuffix(".dll") { name = String(name.dropLast(4)) }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// Measures that answer function-style section variables: `[&Script:MyFunction('a', 2)]`,
/// `[&MeasurePlugin:SomeFunction(args)]`. `call` is the text after the colon, exactly as written
/// (e.g. `MyFunction('a', 2)`); return nil when the measure does not provide it (the text then stays unresolved).
public protocol SectionVariableFunctions: AnyObject {
    func sectionVariableFunction(_ call: String) -> String?
}
