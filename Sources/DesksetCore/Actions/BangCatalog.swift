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

    /// Minimum payload count; the optional Config may precede required payloads in the Skin namespace.
    public var requiredArgumentCount: Int {
        name.hasPrefix("skin:") ? parameters.filter { !$0.isOptional }.count : parameters.prefix { !$0.isOptional }.count
    }
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
        let index: Int
        if name.hasPrefix("skin:"),
           let base = BangCatalog.definition(for: String(name.dropFirst(5))),
           let baseIndex = base.configParameterIndex, baseIndex > 0 {
            guard base.suppliedConfigParameterIndex(argumentCount: args.count) != nil else { return nil }
            index = 0
        } else {
            guard let supplied = suppliedConfigParameterIndex(argumentCount: args.count) else { return nil }
            index = supplied
        }
        // History: "Fixed an issue when the config parameter of a bang contained a leading or trailing slash", i.e.
        // `"illustro\Clock\"` names the config `illustro\Clock`.
        let config = args[index].trimmingCharacters(in: Self.configEdgeCharacters)
        guard !config.isEmpty else { return nil }
        return config
    }

    func suppliedConfigParameterIndex(argumentCount count: Int) -> Int? {
        guard let index = configParameterIndex else { return nil }
        if name == "setwindowposition" {
            switch count {
            case 3: return 2
            case 5...: return 4
            default: return nil
            }
        }
        return count > index ? index : nil
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
        let canonical = canonicalName(name)
        if let found = byName[canonical] { return found }
        if let found = namespacedByName[canonical] { return found }
        if canonical.hasPrefix("skin:") {
            let sub = String(canonical.dropFirst(5))
            if let base = byName[sub], base.configParameterIndex != nil || base.category == .skin || base.category == .skinGroup {
                var parameters = base.parameters
                if let index = base.configParameterIndex, index > 0 {
                    parameters.insert(parameters.remove(at: index), at: 0)
                }
                return BangDefinition(name: canonical, displayName: "!Skin:" + String(base.displayName.dropFirst()),
                                      parameters: parameters, category: base.category,
                                      isDeprecated: base.isDeprecated,
                                      configParameterIndex: base.configParameterIndex.map { _ in 0 })
            }
        }
        return nil
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

    /// Rainmeter 5.0 colon-namespaced bangs (`!Skin:Load`, `!Loop:Reset`, `!WebParser:Refetch`, `!TextEdit:Focus`…).
    private static let namespacedByName: [String: BangDefinition] = makeNamespacedCatalog()

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
        add(["!SendKey"], ["Key"], .operatingSystem)

        // Application bangs
        add(["!Launch"], [], .application)
        add(["!About"], ["TabName?"], .application)
        add(["!Debug"], ["TabName?", "Config?"], .application, config: false)
        // `Config` here only selects an entry in the Manage window; it does not target a skin.
        add(["!Manage"], ["TabName?", "Config?", "File?"], .application, config: false)
        add(["!TrayMenu"], [], .application)
        add(["!Log"], ["String", "ErrorType?"], .application)
        add(["!ResetStats"], [], .application)
        add(["!LoadLayout"], ["LayoutName"], .application)
        add(["!RefreshApp"], [], .application)
        add(["!Restart"], [], .application)
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
        add(["!SetZoomFactor"], ["Factor", "Config?"], .skin)
        add(["!ActivateConfig"], ["Config", "File?"], .skin)
        add(["!DeactivateConfig"], ["Config?"], .skin)
        add(["!ToggleConfig"], ["Config", "File?"], .skin)
        add(["!Update"], ["Config?"], .skin)
        add(["!SetUpdate"], ["Milliseconds", "Config?"], .skin)
        add(["!ForceEnableVisibleMode"], ["Setting?", "Config?"], .skin, config: false)
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
        add(["!SetZoomFactorGroup"], ["Factor", "Group"], .skinGroup)
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
        add(["!CommandMeasureGroup"], ["Group", "Arguments", "Config?"], .measureGroup)
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

    private static func makeNamespacedCatalog() -> [String: BangDefinition] {
        var map: [String: BangDefinition] = [:]
        func add(_ displayNames: [String], _ params: [String], _ category: BangDefinition.Category) {
            let parameters = params.map { p -> BangParameter in
                p.hasSuffix("?") ? BangParameter(String(p.dropLast()), optional: true) : BangParameter(p)
            }
            for display in displayNames {
                let name = canonicalName(display)
                map[name] = BangDefinition(name: name, displayName: display, parameters: parameters,
                                           category: category, configParameterIndex: name.hasPrefix("skin:") ? 0 : nil)
            }
        }

        // !Skin: aliases
        add(["!Skin:Load"], ["Config", "File?"], .skin)
        add(["!Skin:Unload"], ["Config?"], .skin)
        add(["!Skin:Toggle"], ["Config", "File?"], .skin)
        add(["!Skin:Edit"], ["Config?", "File?"], .skin)

        // !Loop:
        add(["!Loop:Reset"], ["Measure?", "Config?"], .measure)

        // !ActionTimer:
        add(["!ActionTimer:Execute", "!ActionTimer:Stop"], ["Measure?", "ActionList?", "Config?"], .measure)

        // !RunCommand:
        add(["!RunCommand:Run", "!RunCommand:Close", "!RunCommand:Kill"], ["Measure?", "Config?"], .measure)

        // !WebParser:
        add(["!WebParser:Refetch", "!WebParser:ClearResults", "!WebParser:ResetData"], ["Measure?", "Config?"], .measure)
        add(["!WebParser:UpdateData"], ["Measure?", "Data?", "Config?"], .measure)

        // !RecycleManager:
        add(["!RecycleManager:EmptyBin", "!RecycleManager:EmptyBinSilent", "!RecycleManager:OpenBin"],
            ["Measure?", "Config?"], .measure)

        // !Audio:
        add(["!Audio:SetVolume", "!Audio:ChangeVolume", "!Audio:SetOutputIndex"],
            ["Measure?", "Value?", "Config?"], .measure)
        add(["!Audio:Mute", "!Audio:Unmute", "!Audio:ToggleMute"], ["Measure?", "Config?"], .measure)

        // !NowPlaying:
        add(["!NowPlaying:Play", "!NowPlaying:Pause", "!NowPlaying:PlayPause", "!NowPlaying:Stop",
             "!NowPlaying:Next", "!NowPlaying:Previous", "!NowPlaying:OpenPlayer", "!NowPlaying:ClosePlayer",
             "!NowPlaying:TogglePlayer"], ["Measure?", "Config?"], .measure)
        add(["!NowPlaying:SetPosition", "!NowPlaying:SetRating", "!NowPlaying:SetShuffle",
             "!NowPlaying:SetRepeat", "!NowPlaying:SetVolume"], ["Measure?", "Value?", "Config?"], .measure)

        // !Mouse:
        add(["!Mouse:StartCapture", "!Mouse:StopCapture"], ["Measure?", "Config?"], .measure)

        // !WindowMessage:
        add(["!WindowMessage:Send"], ["Measure?", "Message?", "WParam?", "LParam?", "Config?"], .measure)

        // !TextEdit:
        add(["!TextEdit:Focus", "!TextEdit:Dismiss", "!TextEdit:Submit", "!TextEdit:SelectAll",
             "!TextEdit:Clear", "!TextEdit:Reset", "!TextEdit:ResetScroll"], ["Meter?", "Config?"], .meter)
        add(["!TextEdit:Select"], ["Meter?", "Start?", "Length?", "Config?"], .meter)
        add(["!TextEdit:SetText", "!TextEdit:ScrollByLine"], ["Meter?", "Value?", "Config?"], .meter)

        return map
    }
}
