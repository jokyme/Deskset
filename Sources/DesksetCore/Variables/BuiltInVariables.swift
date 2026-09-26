import Foundation

// Clean-room, from the public manual only: https://docs.rainmeter.net/manual/variables/built-in-variables/

/// Names of the variables Rainmeter creates for every skin (written `#NAME#` or `[#NAME]`).
///
/// The engine supplies their values through `VariableResolver.variableLookup`; this type only knows the names.
/// Manual rules worth knowing:
/// - They need no `[Variables]` entry and "cannot be directly modified by actions in a skin" — a `[Variables]`
///   key or `!SetVariable` with one of these names must not override them (`VariableResolver.resolveDefinitions`
///   gives built-ins priority).
/// - "All path variables already contain a trailing slash" (on macOS: `/`).
/// - `CURRENTCONFIGX/Y/WIDTH/HEIGHT`, `CURRENTCONFIGZPOS`, `CONFIGEDITOR` and all monitor variables are dynamic:
///   options need `DynamicVariables=1` to see changes (see `isDynamic(_:)`).
/// - Monitor variables without `@N` describe the primary monitor unless the skin auto-selects its screen.
///
/// Values of built-in variables are inserted literally by `VariableResolver.resolve(_:)`: a path that happens to
/// contain `#` or `[` is never re-interpreted as variable syntax.
public enum BuiltInVariables {
    // MARK: Path variables

    /// `#PROGRAMDRIVE#` — drive (Windows `C:`) or server the program is located on. On macOS: the volume root
    /// the app runs from, e.g. `/`.
    public static let programDrive = "PROGRAMDRIVE"
    /// `#PROGRAMPATH#` — folder containing the program executable (with trailing separator).
    public static let programPath = "PROGRAMPATH"
    /// `#SETTINGSPATH#` — folder containing the settings file and other settings files/folders
    /// (Deskset: `~/Library/Application Support/Deskset/`).
    public static let settingsPath = "SETTINGSPATH"
    /// `#SKINSPATH#` — the skins folder (Deskset: `~/Library/Application Support/Deskset/Skins/`).
    public static let skinsPath = "SKINSPATH"
    /// `#PLUGINSPATH#` — folder of the built-in plugins.
    public static let pluginsPath = "PLUGINSPATH"
    /// `#ADDONSPATH#` — the addons folder under the settings path (manual: should be avoided by skins).
    public static let addonsPath = "ADDONSPATH"

    // MARK: Skin variables

    /// `#@#` — the `@Resources` folder of the current skin's root config (with trailing separator).
    public static let resources = "@"
    /// `#CURRENTPATH#` — folder containing the current skin file (with trailing separator).
    public static let currentPath = "CURRENTPATH"
    /// `#CURRENTFILE#` — file name of the current skin, e.g. `Clock.ini`.
    public static let currentFile = "CURRENTFILE"
    /// `#ROOTCONFIGPATH#` — path of the root config: the highest-level folder under the skins folder for the
    /// current skin (with trailing separator).
    public static let rootConfigPath = "ROOTCONFIGPATH"
    /// `#ROOTCONFIG#` — name of the root config, e.g. `illustro`.
    public static let rootConfig = "ROOTCONFIG"
    /// `#CURRENTCONFIG#` — config name of the current skin, e.g. `illustro\Clock` (the manual uses `\` as the
    /// config separator).
    public static let currentConfig = "CURRENTCONFIG"
    /// `#CURRENTCONFIGX#` — X position of the current skin window. Dynamic.
    public static let currentConfigX = "CURRENTCONFIGX"
    /// `#CURRENTCONFIGY#` — Y position of the current skin window. Dynamic.
    public static let currentConfigY = "CURRENTCONFIGY"
    /// `#CURRENTCONFIGWIDTH#` — width of the current skin window. Dynamic.
    public static let currentConfigWidth = "CURRENTCONFIGWIDTH"
    /// `#CURRENTCONFIGHEIGHT#` — height of the current skin window. Dynamic.
    public static let currentConfigHeight = "CURRENTCONFIGHEIGHT"
    /// `#CURRENTCONFIGZPOS#` — Z-position (front to back, the `AlwaysOnTop` level) of the current skin. Dynamic.
    public static let currentConfigZPos = "CURRENTCONFIGZPOS"

    // MARK: Miscellaneous variables

    /// `#CRLF#` — a newline (`\n`, see `crlfValue`). The manual notes `[\13][\10]` gives a real `\r\n`.
    public static let crlf = "CRLF"
    /// `#CURRENTSECTION#` — name of the section in which the variable is used (the engine answers it per section).
    public static let currentSection = "CURRENTSECTION"
    /// `#CONFIGEDITOR#` — path of the text editor used to edit skins. Dynamic.
    public static let configEditor = "CONFIGEDITOR"

    // MARK: Monitor variables (all dynamic)

    /// `#WORKAREAX#` — work area X of the current monitor (`@N` variant: monitor N).
    public static let workAreaX = "WORKAREAX"
    /// `#WORKAREAY#` — work area Y of the current monitor (`@N` variant: monitor N).
    public static let workAreaY = "WORKAREAY"
    /// `#WORKAREAWIDTH#` — work area width of the current monitor (`@N` variant: monitor N).
    public static let workAreaWidth = "WORKAREAWIDTH"
    /// `#WORKAREAHEIGHT#` — work area height of the current monitor (`@N` variant: monitor N).
    public static let workAreaHeight = "WORKAREAHEIGHT"
    /// `#SCREENAREAX#` — screen area X of the current monitor (`@N` variant: monitor N).
    public static let screenAreaX = "SCREENAREAX"
    /// `#SCREENAREAY#` — screen area Y of the current monitor (`@N` variant: monitor N).
    public static let screenAreaY = "SCREENAREAY"
    /// `#SCREENAREAWIDTH#` — screen area width of the current monitor (`@N` variant: monitor N).
    public static let screenAreaWidth = "SCREENAREAWIDTH"
    /// `#SCREENAREAHEIGHT#` — screen area height of the current monitor (`@N` variant: monitor N).
    public static let screenAreaHeight = "SCREENAREAHEIGHT"
    /// `#PWORKAREAX#` — work area X of the primary monitor.
    public static let primaryWorkAreaX = "PWORKAREAX"
    /// `#PWORKAREAY#` — work area Y of the primary monitor.
    public static let primaryWorkAreaY = "PWORKAREAY"
    /// `#PWORKAREAWIDTH#` — work area width of the primary monitor.
    public static let primaryWorkAreaWidth = "PWORKAREAWIDTH"
    /// `#PWORKAREAHEIGHT#` — work area height of the primary monitor.
    public static let primaryWorkAreaHeight = "PWORKAREAHEIGHT"
    /// `#PSCREENAREAX#` — screen area X of the primary monitor.
    public static let primaryScreenAreaX = "PSCREENAREAX"
    /// `#PSCREENAREAY#` — screen area Y of the primary monitor.
    public static let primaryScreenAreaY = "PSCREENAREAY"
    /// `#PSCREENAREAWIDTH#` — screen area width of the primary monitor.
    public static let primaryScreenAreaWidth = "PSCREENAREAWIDTH"
    /// `#PSCREENAREAHEIGHT#` — screen area height of the primary monitor.
    public static let primaryScreenAreaHeight = "PSCREENAREAHEIGHT"
    /// `#VSCREENAREAX#` — X of the virtual screen (bounding box of all monitors).
    public static let virtualScreenAreaX = "VSCREENAREAX"
    /// `#VSCREENAREAY#` — Y of the virtual screen.
    public static let virtualScreenAreaY = "VSCREENAREAY"
    /// `#VSCREENAREAWIDTH#` — width of the virtual screen.
    public static let virtualScreenAreaWidth = "VSCREENAREAWIDTH"
    /// `#VSCREENAREAHEIGHT#` — height of the virtual screen.
    public static let virtualScreenAreaHeight = "VSCREENAREAHEIGHT"

    /// The value of `#CRLF#` ("Creates a \n newline control character").
    public static let crlfValue = "\n"

    /// Every built-in variable name from the manual, upper case, without `#` and without the `@N` monitor suffix.
    public static let names: [String] = [
        programDrive, programPath, settingsPath, skinsPath, pluginsPath, addonsPath,
        resources, currentPath, currentFile, rootConfigPath, rootConfig, currentConfig,
        currentConfigX, currentConfigY, currentConfigWidth, currentConfigHeight, currentConfigZPos,
        crlf, currentSection, configEditor,
        workAreaX, workAreaY, workAreaWidth, workAreaHeight,
        screenAreaX, screenAreaY, screenAreaWidth, screenAreaHeight,
        primaryWorkAreaX, primaryWorkAreaY, primaryWorkAreaWidth, primaryWorkAreaHeight,
        primaryScreenAreaX, primaryScreenAreaY, primaryScreenAreaWidth, primaryScreenAreaHeight,
        virtualScreenAreaX, virtualScreenAreaY, virtualScreenAreaWidth, virtualScreenAreaHeight,
    ]

    /// The names that also exist as `NAME@N` for monitor N (manual: `#WORKAREAX@N#` … `#SCREENAREAHEIGHT@N#`).
    public static let monitorIndexedNames: [String] = [
        workAreaX, workAreaY, workAreaWidth, workAreaHeight,
        screenAreaX, screenAreaY, screenAreaWidth, screenAreaHeight,
    ]

    /// Names the manual calls dynamic (they need `DynamicVariables=1` to reflect changes). Monitor variables,
    /// including every `@N` variant, are dynamic too.
    public static let dynamicNames: [String] = [
        currentConfigX, currentConfigY, currentConfigWidth, currentConfigHeight, currentConfigZPos, configEditor,
    ]

    /// True when `name` (without `#`, any case) is a built-in variable, including `@N` monitor variants such as
    /// `WORKAREAWIDTH@2`.
    public static func isBuiltIn(_ name: String) -> Bool {
        isBuiltInKey(name.lowercased())
    }

    /// True when the built-in variable `name` is dynamic (see `dynamicNames`; all monitor variables).
    public static func isDynamic(_ name: String) -> Bool {
        let key = name.lowercased()
        if dynamicKeys.contains(key) || monitorKeys.contains(key) { return true }
        return monitorVariable(name) != nil
    }

    /// Splits a monitor variable with an `@N` suffix: `"ScreenAreaWidth@2"` → `("SCREENAREAWIDTH", 2)`.
    /// Nil when `name` is not one of `monitorIndexedNames` followed by `@` and a decimal monitor number.
    public static func monitorVariable(_ name: String) -> (base: String, monitor: Int)? {
        guard let at = name.lastIndex(of: "@"), at != name.startIndex else { return nil }
        let base = name[..<at].uppercased()
        let digits = name[name.index(after: at)...]
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits), monitorIndexedKeys.contains(base.lowercased()) else { return nil }
        return (base, n)
    }

    // MARK: Internal

    private static let keys: Set<String> = Set(names.map { $0.lowercased() })
    private static let monitorIndexedKeys: Set<String> = Set(monitorIndexedNames.map { $0.lowercased() })
    private static let dynamicKeys: Set<String> = Set(dynamicNames.map { $0.lowercased() })
    private static let monitorKeys: Set<String> = Set(names.filter {
        $0.hasSuffix("AREAX") || $0.hasSuffix("AREAY") || $0.hasSuffix("AREAWIDTH") || $0.hasSuffix("AREAHEIGHT")
    }.map { $0.lowercased() })

    /// `key` must already be lower case.
    static func isBuiltInKey(_ key: String) -> Bool {
        if keys.contains(key) { return true }
        // Cheap reject before the @N parse: every @N variant contains "area".
        guard key.contains("@"), key.contains("area") else { return false }
        return monitorVariable(key) != nil
    }
}
