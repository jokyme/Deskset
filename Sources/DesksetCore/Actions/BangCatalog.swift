import Foundation

// Every bang documented at https://docs.rainmeter.net/manual/bangs/ (clean-room: names and parameter lists are
// taken from the public manual only), so the engine can validate / dispatch parsed `Bang`s and report the ones it
// does not support.

/// One documented parameter of a bang.
public struct BangParameter: Equatable {
    /// The name used in the manual (`Meter`, `Config`, `milliseconds`, …).
    public let name: String
    public let isOptional: Bool

    public init(_ name: String, optional: Bool = false) {
        self.name = name
        self.isOptional = optional
    }
}

/// A documented bang and its parameter list.
public struct BangDefinition: Equatable {
    /// The manual's sections.
    public enum Category: String, Equatable, CaseIterable {
        case operatingSystem, application, optionsAndVariables
        case skin, skinGroup, meter, meterGroup, measure, measureGroup
        case mouseAction, mouseActionGroup, mouseActionSkinGroup
        /// `Play` / `PlayLoop` / `PlayStop`: listed with the application bangs but written without `!`.
        case command
        case deprecated
    }

    /// Canonical name as produced by `ActionParser` (`setoption`, `play`).
    public let name: String
    /// Spelling used in the manual (`!SetOption`, `Play`).
    public let displayName: String
    public let parameters: [BangParameter]
    public let category: Category
    public let isDeprecated: Bool
    /// Index (in `parameters`) of the `Config` parameter that selects which skin the bang acts on
    /// (a config name or `*`; when optional and omitted, the current skin). Nil when the bang has none.
    public let configParameterIndex: Int?

    public init(name: String, displayName: String, parameters: [BangParameter], category: Category,
                isDeprecated: Bool = false, configParameterIndex: Int? = nil) {
        self.name = name
        self.displayName = displayName
        self.parameters = parameters
        self.category = category
        self.isDeprecated = isDeprecated
        self.configParameterIndex = configParameterIndex
    }

    /// Number of leading non-optional parameters.
    public var requiredArgumentCount: Int { parameters.prefix { !$0.isOptional }.count }
    public var maximumArgumentCount: Int { parameters.count }

    /// Whether `count` arguments fit the documented parameter list.
    public func acceptsArgumentCount(_ count: Int) -> Bool {
        count >= requiredArgumentCount && count <= maximumArgumentCount
    }

    /// The `Config` argument actually supplied in `args`, or nil when omitted / empty (→ the current skin).
    /// Leading / trailing whitespace and path separators are removed (`"illustro\Clock\"` → `illustro\Clock`).
    /// `!SetWindowPosition X Y [AnchorX AnchorY] [Config]`: the manual requires AnchorY whenever AnchorX is given,
    /// so three arguments mean `X Y Config` and five mean `X Y AnchorX AnchorY Config`.
    public func configArgument(in args: [String]) -> String? {
        guard let index = configParameterIndex else { return nil }
        let value: String?
        if name == "setwindowposition" {
            switch args.count {
            case 3: value = args[2]
            case 5...: value = args[4]
            default: value = nil
            }
        } else {
            value = index < args.count ? args[index] : nil
        }
        // History: "Fixed an issue when the config parameter of a bang contained a leading or trailing slash", i.e.
        // `"illustro\Clock\"` names the config `illustro\Clock`.
        guard let config = value?.trimmingCharacters(in: Self.configEdgeCharacters), !config.isEmpty else { return nil }
        return config
    }

    private static let configEdgeCharacters = CharacterSet(charactersIn: "\\/").union(.whitespaces)
}

public enum BangCatalog {
    /// Canonical bang name: lowercased, leading `!` removed, legacy `Rainmeter` prefix removed
    /// (`!RainmeterShowMeter` → `showmeter`, `!SetOption` → `setoption`).
    public static func canonicalName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("!") { name.removeFirst() }
        let legacyPrefix = "rainmeter"
        if name.count > legacyPrefix.count && name.hasPrefix(legacyPrefix) {
            name.removeFirst(legacyPrefix.count)
        }
        return name
    }

    /// The definition for a raw (`!RainmeterRefresh`) or canonical (`refresh`) bang name.
    public static func definition(for name: String) -> BangDefinition? {
        byName[canonicalName(name)]
    }

    public static func isKnown(_ name: String) -> Bool {
        definition(for: name) != nil
    }

    /// Mouse action option names accepted by the `MouseAction(s)` parameter of the mouse action state bangs
    /// (`!DisableMouseAction MyMeter "MouseOverAction|MouseLeaveAction"`; `*` means all).
    public static let mouseActionNames: [String] = [
        "LeftMouseUpAction", "LeftMouseDownAction", "LeftMouseDoubleClickAction",
        "RightMouseUpAction", "RightMouseDownAction", "RightMouseDoubleClickAction",
        "MiddleMouseUpAction", "MiddleMouseDownAction", "MiddleMouseDoubleClickAction",
        "X1MouseUpAction", "X1MouseDownAction", "X1MouseDoubleClickAction",
        "X2MouseUpAction", "X2MouseDownAction", "X2MouseDoubleClickAction",
        "MouseScrollUpAction", "MouseScrollDownAction", "MouseScrollLeftAction", "MouseScrollRightAction",
        "MouseOverAction", "MouseLeaveAction",
    ]

    /// Splits the `MouseAction(s)` argument of the mouse action state bangs into documented option names:
    /// names are separated by `|` and matched case-insensitively (returned in the manual's spelling); `*` means all.
    /// Unknown names are dropped. `"MouseOverAction|mouseleaveaction"` → `["MouseOverAction", "MouseLeaveAction"]`.
    public static func mouseActions(in argument: String) -> [String] {
        var result: [String] = []
        for part in argument.split(separator: "|") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name == "*" { return mouseActionNames }
            if let known = mouseActionNames.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
               !result.contains(known) {
                result.append(known)
            }
        }
        return result
    }

    /// Every documented bang, in manual order.
    public static let all: [BangDefinition] = makeCatalog()

    private static let byName: [String: BangDefinition] = {
        var map: [String: BangDefinition] = [:]
        for definition in all where map[definition.name] == nil { map[definition.name] = definition }
        return map
    }()

    // MARK: - Table

    private static func makeCatalog() -> [BangDefinition] {
        var list: [BangDefinition] = []

        /// `params`: names; a trailing `?` marks an optional parameter. A parameter named exactly `Config?`/`Config`
        /// is recorded as the target-skin parameter unless `config: false`.
        func add(_ displayNames: [String], _ params: [String], _ category: BangDefinition.Category,
                 deprecated: Bool = false, config: Bool = true) {
            let parameters = params.map { p -> BangParameter in
                p.hasSuffix("?") ? BangParameter(String(p.dropLast()), optional: true) : BangParameter(p)
            }
            let configIndex = config ? parameters.firstIndex { $0.name == "Config" } : nil
            for display in displayNames {
                list.append(BangDefinition(name: canonicalName(display), displayName: display, parameters: parameters,
                                           category: category, isDeprecated: deprecated,
                                           configParameterIndex: configIndex))
            }
        }

        // Operating System bangs
        add(["!SetClip"], ["String"], .operatingSystem)
        add(["!SetWallpaper"], ["File", "Position?"], .operatingSystem)

        // Application bangs
        add(["!About"], ["TabName?"], .application)
        // `Config` here only selects an entry in the Manage window; it does not target a skin.
        add(["!Manage"], ["TabName?", "Config?", "File?"], .application, config: false)
        add(["!TrayMenu"], [], .application)
        add(["!Log"], ["String", "ErrorType?"], .application)
        add(["!ResetStats"], [], .application)
        add(["!LoadLayout"], ["LayoutName"], .application)
        add(["!RefreshApp"], [], .application)
        add(["!Quit"], [], .application)
        add(["Play"], ["SoundFile"], .command)
        add(["PlayLoop"], ["SoundFile"], .command)
        add(["PlayStop"], [], .command)

        // Option and Variable bangs
        add(["!SetOption"], ["Meter/Measure", "Option", "Value", "Config?"], .optionsAndVariables)
        add(["!SetVariable"], ["Variable", "Value", "Config?"], .optionsAndVariables)
        add(["!WriteKeyValue"], ["Section", "Key", "Value", "FilePath?"], .optionsAndVariables)
        add(["!SetOptionGroup"], ["Group", "Option", "Value", "Config?"], .optionsAndVariables)
        add(["!SetVariableGroup"], ["Variable", "Value", "Group"], .optionsAndVariables)

        // Skin bangs
        add(["!Show", "!Hide", "!Toggle"], ["Config?"], .skin)
        add(["!ShowFade", "!HideFade", "!ToggleFade"], ["Config?"], .skin)
        add(["!FadeDuration"], ["milliseconds", "Config?"], .skin)
        add(["!ShowBlur", "!HideBlur", "!ToggleBlur"], ["Config?"], .skin)
        add(["!AddBlur", "!RemoveBlur"], ["Region", "Config?"], .skin)
        add(["!Move"], ["X", "Y", "Config?"], .skin)
        add(["!SetWindowPosition"], ["WindowX", "WindowY", "AnchorX?", "AnchorY?", "Config?"], .skin)
        add(["!SetAnchor"], ["AnchorX", "AnchorY", "Config?"], .skin)
        add(["!ActivateConfig"], ["Config", "File?"], .skin)
        add(["!DeactivateConfig"], ["Config?"], .skin)
        add(["!ToggleConfig"], ["Config", "File?"], .skin)
        add(["!Update"], ["Config?"], .skin)
        add(["!Redraw"], ["Config?"], .skin)
        add(["!Refresh"], ["Config?"], .skin)
        add(["!Delay"], ["milliseconds"], .skin)
        add(["!SkinMenu"], ["Config?"], .skin)
        add(["!SkinCustomMenu"], ["Config?"], .skin)
        add(["!SetTransparency"], ["Alpha", "Config?"], .skin)
        add(["!ZPos"], ["Position", "Config?"], .skin)
        add(["!Draggable"], ["Setting", "Config?"], .skin)
        add(["!KeepOnScreen"], ["Setting", "Config?"], .skin)
        add(["!ClickThrough"], ["Setting", "Config?"], .skin)
        add(["!SnapEdges"], ["Setting", "Config?"], .skin)
        add(["!AutoSelectScreen"], ["Setting", "Config?"], .skin)
        add(["!EditSkin"], ["Config?", "File?"], .skin)

        // Skin group bangs
        add(["!ShowGroup", "!HideGroup", "!ToggleGroup"], ["Group"], .skinGroup)
        add(["!ShowFadeGroup", "!HideFadeGroup", "!ToggleFadeGroup"], ["Group"], .skinGroup)
        add(["!FadeDurationGroup"], ["milliseconds", "Group"], .skinGroup)
        add(["!DeactivateConfigGroup"], ["Group"], .skinGroup)
        add(["!UpdateGroup"], ["Group"], .skinGroup)
        add(["!RedrawGroup"], ["Group"], .skinGroup)
        add(["!RefreshGroup"], ["Group"], .skinGroup)
        add(["!SetTransparencyGroup"], ["Alpha", "Group"], .skinGroup)
        add(["!DraggableGroup"], ["Setting", "Group"], .skinGroup)
        add(["!ZPosGroup"], ["Position", "Group"], .skinGroup)
        add(["!KeepOnScreenGroup"], ["Setting", "Group"], .skinGroup)
        add(["!ClickThroughGroup"], ["Setting", "Group"], .skinGroup)
        add(["!SnapEdgesGroup"], ["Setting", "Group"], .skinGroup)
        add(["!AutoSelectScreenGroup"], ["Setting", "Group"], .skinGroup)

        // Meter bangs
        add(["!ShowMeter", "!HideMeter", "!ToggleMeter"], ["Meter", "Config?"], .meter)
        add(["!UpdateMeter"], ["Meter", "Config?"], .meter)
        add(["!MoveMeter"], ["X", "Y", "Meter", "Config?"], .meter)

        // Meter group bangs
        add(["!ShowMeterGroup", "!HideMeterGroup", "!ToggleMeterGroup"], ["Group", "Config?"], .meterGroup)
        add(["!UpdateMeterGroup"], ["Group", "Config?"], .meterGroup)

        // Measure bangs
        add(["!EnableMeasure", "!DisableMeasure", "!ToggleMeasure"], ["Measure", "Config?"], .measure)
        add(["!PauseMeasure", "!UnpauseMeasure", "!TogglePauseMeasure"], ["Measure", "Config?"], .measure)
        add(["!UpdateMeasure"], ["Measure", "Config?"], .measure)
        add(["!CommandMeasure"], ["Measure", "Arguments", "Config?"], .measure)

        // Measure group bangs
        add(["!EnableMeasureGroup", "!DisableMeasureGroup", "!ToggleMeasureGroup"], ["Group", "Config?"],
            .measureGroup)
        add(["!PauseMeasureGroup", "!UnpauseMeasureGroup", "!TogglePauseMeasureGroup"], ["Group", "Config?"],
            .measureGroup)
        add(["!UpdateMeasureGroup"], ["Group", "Config?"], .measureGroup)

        // Mouse Action state bangs
        add(["!DisableMouseAction", "!ClearMouseAction", "!EnableMouseAction", "!ToggleMouseAction"],
            ["Meter", "MouseAction(s)", "Config?"], .mouseAction)
        add(["!DisableMouseActionGroup", "!ClearMouseActionGroup", "!EnableMouseActionGroup",
             "!ToggleMouseActionGroup"], ["MouseAction(s)", "Group", "Config?"], .mouseActionGroup)
        add(["!DisableMouseActionSkinGroup", "!ClearMouseActionSkinGroup", "!EnableMouseActionSkinGroup",
             "!ToggleMouseActionSkinGroup"], ["MouseAction(s)", "Group"], .mouseActionSkinGroup)

        // Deprecated bangs. `!Execute` is unwrapped by `ActionParser`, so it never reaches the engine.
        add(["!Execute"], ["Actions?"], .deprecated, deprecated: true)
        add(["!PluginBang"], ["Measure", "Arguments", "Config?"], .deprecated, deprecated: true)

        return list
    }
}
