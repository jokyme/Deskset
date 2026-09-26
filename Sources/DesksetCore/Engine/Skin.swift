import Foundation

/// `[Rainmeter]` section settings (manual: /manual/skins/rainmeter-section/ and its "defaults" page).
///
/// The `[Rainmeter]` section "does not support Dynamic Variables or changes using the !SetOption bang, with the
/// exception of custom Context menu items", so these values are read once when the skin loads.
public struct SkinSettings {
    /// Milliseconds between updates; -1 = update once (on load / refresh). Values below the documented minimum
    /// of 16 are raised to 16 (judgment: `Update=0` too).
    public var update = 1000
    /// Negative: measures and meters update only once, when the skin is loaded.
    public var defaultUpdateDivider = 1
    public var dynamicWindowSize = false
    /// Fixed skin width / height; nil when missing or ≤ 0 ("If the setting is missing entirely (none) or set to 0
    /// it has no effect").
    public var skinWidth: Double?
    public var skinHeight: Double?
    /// `DragMargins=L,T,R,B`: non-draggable margins; negative values are measured from the opposite side
    /// (use `Skin.isInDragArea(x:y:)`).
    public var dragMargins = SkinInsets.zero
    /// 0 image, 1 transparent, 2 solid color, 3 scaled image, 4 tiled image.
    public var backgroundMode = 1
    /// Absolute path of `Background=` image.
    public var backgroundImage: String?
    /// General image options of `Background` ("All general image options are valid for Background": ImageCrop,
    /// ImageRotate, ImageFlip, Greyscale, ImageTint…), read from `[Rainmeter]` when the skin loads.
    public var backgroundImageOptions = ImageOptions()
    /// `BackgroundMargins=L,T,R,B`: unscaled edges of the background image for `BackgroundMode=3`.
    public var backgroundMargins = SkinInsets.zero
    public var solidColor = RGBA.clear
    public var solidColor2: RGBA?
    public var gradientAngle = 0.0
    public var bevelType = 0
    /// `BevelColor` / `BevelColor2` (nil = default light / dark).
    public var bevelColor: RGBA?
    public var bevelColor2: RGBA?
    public var accurateText = false
    public var onRefreshAction = ""
    public var onUpdateAction = ""
    public var onCloseAction = ""
    public var onFocusAction = ""
    public var onUnfocusAction = ""
    /// Run at the end of the first update after the system wakes (see `Skin.systemDidWake()`).
    public var onWakeAction = ""
    /// `TransitionUpdate` (ms, default 100): update rate while a meter transition runs (Bitmap meters).
    public var transitionUpdate = 100
    /// `ToolTipHidden=1` in `[Rainmeter]`: no tooltips in the whole skin.
    public var toolTipHidden = false
    /// `MouseActionCursor` (default 1) and `MouseActionCursorName`: skin-wide defaults for meters.
    public var mouseActionCursor = true
    public var mouseActionCursorName = ""
    /// `SelectedColor`: overlay color for skins selected in a drag group (nil = app default).
    public var selectedColor: RGBA?
    /// `DragGroup`: drag groups (lowercased).
    public var dragGroups: [String] = []
    /// `Blur` / `BlurRegion`, `BlurRegion2`…: `[Type, TopX, TopY, BottomX, BottomY, Radius?]` (Windows Aero blur).
    public var blur = false
    public var blurRegions: [[Double]] = []
    /// Starting values for the per-config window settings (`DefaultWindowX`, `DefaultAlwaysOnTop`, …), keyed by
    /// the setting name without the `Default` prefix (`WindowX`, `WindowY`, `AnchorX`, `AnchorY`, `SavePosition`,
    /// `AlwaysOnTop`, `Draggable`, `SnapEdges`, `StartHidden`, `AlphaValue`, `OnHover`, `FadeDuration`,
    /// `ClickThrough`, `KeepOnScreen`, `AutoSelectScreen`), values as written (variables resolved). The host uses
    /// them only the first time a config is loaded.
    public var windowDefaults: [String: String] = [:]
    /// `ContextTitle` / `ContextAction` pairs (numbered), separators excluded. See `Skin.contextMenuItems()` for the
    /// current values (they are "always dynamic").
    public var contextItems: [(title: String, action: String)] = []
    /// Absolute paths from `LocalFont`, `LocalFont2`… plus the `.ttf` / `.otf` / `.ttc` files of `@Resources/Fonts`
    /// ("automatically loaded").
    public var localFonts: [String] = []
    public var groups: [String] = []

    public init() {}
}

/// The `[Rainmeter]` section, read like any other section (for skin-level mouse actions and options).
public final class RainmeterSection: SkinSection {
    public internal(set) var mouseActions: [MouseEventKind: String] = [:]

    public override func readOptions() {
        super.readOptions()
        dynamicVariables = false   // not supported in [Rainmeter]
        var actions: [MouseEventKind: String] = [:]
        for kind in MouseEventKind.allCases {
            let a = actionOption(kind.rawValue)
            if !a.trimmingCharacters(in: .whitespaces).isEmpty { actions[kind] = a }
        }
        mouseActions = actions
    }

    /// Like `Meter.effectiveMouseAction(_:)`: nil when undefined or cleared, `""` when disabled.
    public func effectiveMouseAction(_ kind: MouseEventKind) -> String? {
        guard let action = mouseActions[kind] else { return nil }
        switch mouseActionState(kind) {
        case .enabled: return action
        case .disabled: return ""
        case .cleared: return nil
        }
    }
}

/// One loaded skin: sections, variables, the update cycle and bang execution. Drawing is done by the host.
///
/// Update cycle (manual: /manual/skins/ "Update", /manual/measures/ "Order", /manual/meters/ "Order",
/// /manual/skins/rainmeter-section/): measures update in file order (a measure referencing a later one sees its
/// previous value), then meters update and are positioned in file order, then the window size is computed (once,
/// or on every update with `DynamicWindowSize=1`), then `OnRefreshAction` (first update only) and `OnUpdateAction`
/// run "at the very end of the update cycle", then the host redraws. Measures and meters honour `UpdateDivider`
/// (default `DefaultUpdateDivider`); sections with `DynamicVariables=1` re-read their options whenever they update,
/// and `!SetOption` makes a section re-read its options once.
///
/// Bangs: `!UpdateMeter` recomputes the layout lazily (once per action, or as soon as a `[Meter:X]` variable is
/// read). Self-triggering actions are bounded by nesting depth and by a work budget per update / top-level action
/// (`maxBurstWork`), so no skin can hang the app; an action that unloads the skin ends the update.
public final class Skin {
    public let config: String
    public let fileURL: URL
    public let skinsDirectory: URL
    public weak var host: SkinHost?
    public let system: SystemDataSource
    /// Where this skin's work runs and what owns it: its update clock, `!Delay`, the timers of its plugins and meters,
    /// and the results of its background work (docs/skin-threading.md §5.3; see `SkinExecutor`). The main thread
    /// unless the host picks another executor before `load()`. Work already scheduled stays where it was scheduled.
    public var executor: SkinExecutor = MainSkinExecutor.shared
    /// What the host's renderer keeps for this skin from frame to frame (the app's `SkinRenderContext`: text layouts,
    /// processed Rotator images, Histogram scratch space). It belongs to the skin rather than to the app so that skins
    /// drawn on threads of their own never share a cache (docs/skin-threading.md §4.3): like everything reachable from
    /// the skin, only its owner touches it (checked in debug builds), and it is released with the skin. The engine never
    /// looks inside.
    public var renderContext: AnyObject? {
        get {
            assertOwned()
            return storedRenderContext
        }
        set {
            assertOwned()
            storedRenderContext = newValue
        }
    }
    private var storedRenderContext: AnyObject?

    public private(set) var measures: [Measure] = []
    public private(set) var meters: [Meter] = []
    public private(set) var rainmeterSection: RainmeterSection?
    public private(set) var settings = SkinSettings()
    public private(set) var metadata: [String: String] = [:]
    public private(set) var document = IniDocument()
    public private(set) var includedFiles: [URL] = []
    /// Where every section and option of `document` was written (for the inspector).
    public private(set) var sources = IniSourceMap()
    /// Number of `!WriteKeyValue` bangs this skin has run: the inspector does not treat such writes as edits.
    public private(set) var keyValueWrites = 0
    /// Editor previews: the `!SetOption` values (nil: none) and variable values replaced by `preview…`.
    var previewSaved: [String: [String: String?]] = [:]
    var previewSavedVariables: [String: String?] = [:]
    /// Skin size in points (window content size).
    public private(set) var width = 0.0
    public private(set) var height = 0.0
    /// Number of completed skin updates since this skin object was loaded.
    public private(set) var updateCount = 0
    /// Updates counted by the skin objects this one replaced on refresh (see `continueCounter(from:)`).
    public private(set) var counterBase = 0
    /// The Calc `Counter`: "The number of update cycles from the time the skin is loaded. This number only resets
    /// when the skin is unloaded and then loaded again - not when the skin is refreshed."
    public var counter: Int { counterBase.addingReportingOverflow(updateCount).partialValue }
    /// Human-readable compatibility notes, shown to users: only things that work differently on the Mac than in
    /// Rainmeter on Windows (Windows-only measures and plugins, unsupported bangs, registry values that do not exist
    /// here…). Mistakes in the skin itself that Rainmeter treats the same way (a missing MeterStyle, an invalid
    /// Container, an unknown bang, measure or meter type) are log lines, not issues.
    public private(set) var issues: [String] = []
    /// What loading the files ran into (a missing `@Include` file, an include cycle…): mistakes of the skin's files, not
    /// Mac differences (`SkinFileLoader`'s warnings); the editor says them in plain words.
    public private(set) var loadWarnings: [String] = []

    private var variables: [String: String] = [:]
    private var measureIndex: [String: Measure] = [:]
    private var meterIndex: [String: Meter] = [:]
    private var sectionIndex: [String: IniSection] = [:]
    private var styleValueIndex: [String: [String: String]] = [:]
    private var hoveredMeters: Set<String> = []
    /// The self-handling meter (Button) that took the last `.leftDown`; it gets the matching `.leftUp` wherever the
    /// button is released (see `mouseEvent`).
    private weak var pressedMeter: Meter?
    private var mouseInside = false
    /// Measures that follow the mouse themselves (`Plugin=Mouse`), in file order (see `pointerEvent`).
    private var pointerObservers: [SkinPointerObserver] = []
    /// Buttons pressed on the skin (reported to `pointerEvent`) and not released yet.
    private var pointerButtons: Set<MouseButton> = []
    /// Whether `pointerEvent` last saw the pointer over the skin.
    private var pointerInside = false
    /// Measures that also follow the mouse outside the skin window (`Plugin=Slider`), in file order (see
    /// `outsidePointerEvent`).
    private var outsideObservers: [SkinOutsidePointerObserver] = []
    /// Buttons pressed outside the skin window (reported to `outsidePointerEvent`) and not released yet.
    private var outsideButtons: Set<MouseButton> = []
    /// What the measures want from the mouse outside the skin window now; the host watches the mouse elsewhere while it
    /// is not empty. Recomputed after every update, every top-level action and when the skin closes; the host hears
    /// of every change (`SkinHost.skinOutsidePointerNeedsChanged`).
    public private(set) var outsidePointerNeeds = OutsidePointerNeeds()
    private var sizeComputed = false
    private var issueSet: Set<String> = []
    private var loggedOnce: Set<String> = []

    /// Monotonic clock in seconds (Net measures compute bytes per second from it). Tests and the editor's component
    /// thumbnails (sample readings on a clock of their own) replace it.
    public var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Host facts for the dynamic built-in variables; fetched lazily and invalidated at every update and every
    /// top-level action, so `#CURRENTCONFIGX#` etc. are current without querying the host on every lookup.
    private var environmentCache = SkinEnvironment()
    private var environmentValid = false

    private var updateDepth = 0
    private var actionDepth = 0
    /// Incremented by `close()`: pending `!Delay` continuations of an older generation are dropped.
    private var generation = 0
    private var closed = false
    private var pendingWakeAction = false
    /// Work done since the outermost update or action started: bangs run plus meters / measures updated by bangs.
    private var burstWork = 0
    /// `!UpdateMeter` / `!UpdateMeterGroup` ran: meter frames are recomputed once, lazily (see `layoutIfPending`).
    private var layoutPending = false
    /// `!Delay` continuations waiting to run, by number; `close()` cancels them.
    private var pendingDelays: [Int: SkinScheduledWork] = [:]
    private var lastDelayID = 0

    /// Maximum nesting of actions triggering actions (`!UpdateMeasure` → IfConditionMode action → …) and of
    /// `!Update` inside an update, so self-triggering skins cannot recurse forever.
    static let maxActionDepth = 16
    static let maxUpdateDepth = 2
    /// The depth limit alone does not bound fan-out: with N meters that each have
    /// `OnUpdateAction=[!UpdateMeter *]` the work grows like N^depth (3 meters: 43 million meter updates). Every
    /// burst of work started by one update or one top-level action gets this budget; once it is spent, further
    /// actions of that burst are skipped (logged once).
    static let maxBurstWork = 20_000
    /// `!Delay` continuations waiting to run.
    static let maxPendingDelays = 256
    /// Bound on distinct `logOnce` messages and on `issues`.
    static let maxDistinctMessages = 500

    /// Config name with `\` separators, e.g. `Deskset\Clock`.
    public init(config: String, fileURL: URL, skinsDirectory: URL, system: SystemDataSource, host: SkinHost?) {
        self.config = config
        self.fileURL = fileURL
        self.skinsDirectory = skinsDirectory
        self.system = system
        self.host = host
    }

    /// A skin dropped without `close()` (a dry run, a thumbnail): its pending `!Delay` continuations would find it gone
    /// anyway; cancelled, they let go of the section and actions they hold now instead of when they are due.
    deinit {
        for work in pendingDelays.values { work.cancel() }
    }

    /// The host calls this on a refresh (`!Refresh`, "Refresh skin"), before the first update of the new skin
    /// object, so the Calc `Counter` continues instead of starting again from 0.
    public func continueCounter(from previous: Skin) {
        counterBase = previous.counter
    }

    public var rootConfig: String {
        String(config.split(separator: "\\").first ?? Substring(config))
    }

    public var directory: URL { fileURL.deletingLastPathComponent() }
    public var rootConfigDirectory: URL { skinsDirectory.appendingPathComponent(rootConfig, isDirectory: true) }
    public var resourcesDirectory: URL { rootConfigDirectory.appendingPathComponent("@Resources", isDirectory: true) }

    // MARK: Loading

    public func load() throws {
        assertOwned()
        environmentValid = false
        let builtins = builtInVariables()
        let loaded = try SkinFileLoader.load(url: fileURL) { raw, readSoFar in
            let table = builtins.merging(readSoFar) { _, new in new }
            return VariableResolver(variableLookup: { table[$0.lowercased()] }).resolve(raw)
        }
        document = loaded.document
        includedFiles = loaded.includedFiles
        sources = loaded.sources
        loadWarnings = loaded.warnings
        for w in loaded.warnings { log(w, level: .warning) }

        sectionIndex = [:]
        styleValueIndex = [:]
        for section in document.sections {
            let key = section.name.lowercased()
            if sectionIndex[key] == nil { sectionIndex[key] = section }
        }

        variables = VariableResolver.resolveDefinitions(document.section(named: "Variables")?.entries ?? [],
                                                        builtins: builtins)
        metadata = [:]
        for e in document.section(named: "Metadata")?.entries ?? [] { metadata[e.key] = e.value }

        measures = []
        meters = []
        measureIndex = [:]
        meterIndex = [:]
        for section in document.sections {
            let lower = section.name.lowercased()
            if lower == "rainmeter" || lower == "metadata" || lower == "variables" { continue }
            if measureIndex[lower] != nil || meterIndex[lower] != nil { continue }
            if let measureType = section.value(forKey: "Measure") {
                let m = makeMeasure(section, type: resolve(measureType, in: nil, sectionVariables: false))
                measures.append(m)
                measureIndex[lower] = m
            } else if let meterType = section.value(forKey: "Meter") {
                let m = makeMeter(section, type: resolve(meterType, in: nil, sectionVariables: false))
                meters.append(m)
                meterIndex[lower] = m
            }
        }
        pointerObservers = measures.compactMap { $0 as? SkinPointerObserver }
        outsideObservers = measures.compactMap { $0 as? SkinOutsidePointerObserver }

        let root = RainmeterSection(name: "Rainmeter", section: document.section(named: "Rainmeter")
                                    ?? IniSection(name: "Rainmeter"), skin: self)
        rainmeterSection = root
        readSettings(root)
        optionsLoaded = false
        meterFramesReady = false
        root.readOptionsIfNeeded()
        for m in measures { m.readOptionsIfNeeded() }
        // A meter may already have been read by a provisional layout (`ensureMeterGeometry`, asked for by a script's
        // main chunk or a dynamic `[Meter:X]` while the options above were read): not read twice.
        for m in meters where m.needsOptionRead { m.readOptionsIfNeeded() }
        optionsLoaded = true
        // Section variables in sections without DynamicVariables are resolved when the first update reads them
        // again (see `SkinSection.readOptionsIfNeeded`); other sections keep their load-time read.
        for m in measures where m.mentionsSectionVariables && !m.dynamicVariables { m.needsOptionRead = true }
        for m in meters where m.mentionsSectionVariables && !m.dynamicVariables { m.needsOptionRead = true }
    }

    /// True once the load-time read of every section's options is done: later reads resolve section variables.
    private(set) var optionsLoaded = false

    /// Whether `text` contains a section variable naming one of this skin's measures or meters: `[Name]`,
    /// `[Name:…]` or `[&Name…]` (escapes such as `[*Name*]`, variables `[#Var]` and character references do not
    /// count). Only called for option values with a `[`, while options are read.
    func mentionsSectionVariable(_ text: String) -> Bool {
        var rest = Substring(text)
        var steps = 0
        while let open = rest.firstIndex(of: "["), steps < 256 {
            steps += 1
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(where: { $0 == "]" || $0 == "[" }) else { return false }
            if rest[close] == "]" {
                var name = rest[afterOpen..<close]
                if name.hasPrefix("&") { name = name.dropFirst() }
                if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
                let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                if !key.isEmpty, measureIndex[key] != nil || meterIndex[key] != nil { return true }
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest[close...]
            }
        }
        return false
    }

    private func readSettings(_ s: RainmeterSection) {
        var st = SkinSettings()
        let update = s.int("Update", 1000)
        st.update = update < 0 ? -1 : max(update, 16)
        st.defaultUpdateDivider = s.int("DefaultUpdateDivider", 1)
        settings.defaultUpdateDivider = st.defaultUpdateDivider
        st.dynamicWindowSize = s.bool("DynamicWindowSize", false)
        st.skinWidth = s.optionalDouble("SkinWidth").flatMap { $0.isFinite && $0 > 0 ? min($0, Skin.maxSide) : nil }
        st.skinHeight = s.optionalDouble("SkinHeight").flatMap { $0.isFinite && $0 > 0 ? min($0, Skin.maxSide) : nil }
        st.dragMargins = insets(s.string("DragMargins"))
        let background = s.string("Background").trimmingCharacters(in: .whitespaces)
        st.backgroundImage = background.isEmpty ? nil : imageFilePath(background, imagePath: "")
        // Manual default is 1 (transparent). Judgment: a skin that sets Background= without BackgroundMode shows the
        // image (mode 0) — otherwise the Background option would have no effect at all.
        st.backgroundMode = s.int("BackgroundMode", st.backgroundImage == nil ? 1 : 0)
        st.backgroundMargins = insets(s.string("BackgroundMargins"))
        st.backgroundImageOptions = ImageOptions.read(from: s)
        st.solidColor = s.color("SolidColor", RGBA(r: 128, g: 128, b: 128, a: 255))
        st.solidColor2 = s.option("SolidColor2").flatMap(OptionValue.color)
        st.gradientAngle = s.double("GradientAngle", 0)
        st.bevelType = s.int("BevelType", 0)
        st.bevelColor = s.option("BevelColor").flatMap(OptionValue.color)
        st.bevelColor2 = s.option("BevelColor2").flatMap(OptionValue.color)
        st.accurateText = s.bool("AccurateText", false)
        st.onRefreshAction = s.actionOption("OnRefreshAction")
        st.onUpdateAction = s.actionOption("OnUpdateAction")
        st.onCloseAction = s.actionOption("OnCloseAction")
        st.onFocusAction = s.actionOption("OnFocusAction")
        st.onUnfocusAction = s.actionOption("OnUnfocusAction")
        st.onWakeAction = s.actionOption("OnWakeAction")
        st.transitionUpdate = min(max(s.int("TransitionUpdate", 100), 16), 86_400_000)
        st.toolTipHidden = s.bool("ToolTipHidden", false)
        st.mouseActionCursor = s.bool("MouseActionCursor", true)
        st.mouseActionCursorName = s.string("MouseActionCursorName").trimmingCharacters(in: .whitespaces)
        st.selectedColor = s.option("SelectedColor").flatMap(OptionValue.color)
        st.dragGroups = OptionValue.list(s.string("DragGroup")).map { $0.lowercased() }
        st.blur = s.bool("Blur", false)
        st.blurRegions = s.numberedOptions("BlurRegion", limit: 100).map { OptionValue.numbers($0.value) }
            .filter { !$0.isEmpty }
        for name in ["WindowX", "WindowY", "AnchorX", "AnchorY", "SavePosition", "AlwaysOnTop", "Draggable",
                     "SnapEdges", "StartHidden", "AlphaValue", "OnHover", "FadeDuration", "ClickThrough",
                     "KeepOnScreen", "AutoSelectScreen"] {
            if let v = s.option("Default" + name)?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
                st.windowDefaults[name] = v
            }
        }
        st.localFonts = s.numberedOptions("LocalFont", limit: 100).map { absolutePath($0.value) }
        st.localFonts += resourceFonts().filter { !st.localFonts.contains($0) }
        st.groups = OptionValue.list(s.string("Group"))
        settings = st
        settings.contextItems = contextMenuItems().filter { !$0.isSeparator }.map { ($0.title, $0.action) }
    }

    /// `L,T,R,B` (missing values 0).
    private func insets(_ text: String) -> SkinInsets {
        let v = OptionValue.numbers(text).map { $0.clamped(-1e6, 1e6) }
        func at(_ i: Int) -> Double { i < v.count ? v[i] : 0 }
        return SkinInsets(left: at(0), top: at(1), right: at(2), bottom: at(3))
    }

    /// Fonts in `@Resources/Fonts` ("TrueType (.ttf) or OpenType (.otf) fonts … are automatically loaded"), and
    /// their collections (`.ttc`, `.otc`), which the installer copies there too. Hidden files are skipped (macOS
    /// AppleDouble `._Name.ttf` files next to fonts copied from FAT / exFAT or network volumes are not fonts), as the
    /// app's own folder scan (`Fonts.fontFiles`) does.
    private func resourceFonts() -> [String] {
        let folder = resourcesDirectory.appendingPathComponent("Fonts", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter {
            !$0.hasPrefix(".") && RmskinPlainArchive.fontExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
            .sorted()
            .prefix(256)
            .map { folder.appendingPathComponent($0).path }
    }

    /// Windows-only measure types (and plugins) that cannot work on macOS.
    /// Only reached when nothing registered the name in MeasureRegistry (app-side plugins are registered by the
    /// app; `--render` and the self-tests register them too).
    private static let windowsOnlyMeasures: Set<String> = []
    /// Built-in plugins / measures that are not tied to Windows but are not implemented yet: the compatibility
    /// hint must not call them "Windows-only" (ActionTimer, for instance, drives many skins' animations).
    private static let notYetSupportedMeasures: Set<String> = []

    /// Plugin and measure names (lowercased, without folder / `.dll`) that the Deskset app implements and registers
    /// with `MeasureRegistry` at startup (`AudioPlugins`, `MediaUIPlugins`): they need AppKit, Core Audio, CoreWLAN…,
    /// which DesksetCore does not link. In the app (and in `--render` / `--self-test`) they are always registered, so
    /// the fallback below never sees them; only a core-only context (DesksetSelfTest, a tool that loads skins without
    /// the app) reaches it. There the generic "is a Windows plugin" hint would be wrong: they work on the Mac.
    /// As `Measure=` types only the documented ones count (NowPlaying, MediaKey, WiFiStatus — the app registers only
    /// those as measures); `Measure=AudioLevel` stays an invalid measure type in every context.
    /// Keep in step with the app's registrations (the app self-test compares this list with them).
    public static let appProvidedMeasures: Set<String> = [
        "nowplaying", "wifistatus", "mediakey", "itunesplugin", "itunes", "webnowplaying", "inputtext",
        "frostedglass", "chameleon", "isfullscreen", "getactivetitle", "syscolor", "audiolevel", "win7audioplugin",
        "win7audio", "appvolume",
    ]

    /// Measures whose manual page says they were "previously a plugin measure" and that "still [work] with those
    /// forms" — `Measure=Plugin` with `Plugin=Name`, `Name.dll` or `Plugins\Name.dll` is the same as `Measure=Name`
    /// (SysInfo, Process, WebParser, RecycleManager, MediaKey, NowPlaying, WiFiStatus).
    static let formerPluginMeasures: Set<String> = [
        "sysinfo", "process", "webparser", "recyclemanager", "mediakey", "nowplaying", "wifistatus",
    ]

    /// Every `Measure=` type the manual documents (/manual/measures/), including the Memory / Net variants. A type
    /// outside this list is a mistake in the skin (Rainmeter cannot load it either): logged, not listed as a
    /// compatibility issue.
    public static let documentedMeasureTypes: Set<String> = [
        "calc", "cpu", "freediskspace", "loop", "mediakey", "memory", "physicalmemory", "swapmemory", "netin",
        "netout", "nettotal", "nowplaying", "plugin", "process", "recyclemanager", "registry", "script", "string",
        "sysinfo", "time", "uptime", "webparser", "wifistatus",
    ]

    /// Every `Meter=` type the manual documents (/manual/meters/).
    static let documentedMeterTypes: Set<String> = [
        "string", "image", "bar", "line", "histogram", "roundline", "rotator", "shape", "button", "bitmap",
    ]

    private func makeMeasure(_ section: IniSection, type rawType: String) -> Measure {
        let type = rawType.trimmingCharacters(in: .whitespaces).lowercased()
        let isPlugin = type == "plugin"
        let plugin = resolve(section.value(forKey: "Plugin") ?? "", in: nil, sectionVariables: false)
        // For `Measure=Plugin` the type is the plugin name (`Plugins\WebParser.dll` → `webparser`), so WebParser
        // child measures find a parent written in the plugin form.
        let effectiveType = isPlugin ? pluginName(plugin) : type
        let isFormerPlugin = Skin.formerPluginMeasures.contains(effectiveType)
        Skin.registerBuiltInExtensions()
        // Extensions registered outside Engine/ come first. A former plugin is found whichever way it was
        // registered (as `Plugin=` or as `Measure=`) and whichever form the skin uses.
        var registered = isPlugin ? MeasureRegistry.plugin(named: plugin) : MeasureRegistry.measure(named: type)
        if registered == nil, isFormerPlugin {
            registered = isPlugin ? MeasureRegistry.measure(named: effectiveType)
                : MeasureRegistry.plugin(named: effectiveType)
        }
        // Built-in measure classes: every `Measure=` type, but for `Measure=Plugin` only the former plugins and
        // the plugins the engine implements itself (so `Plugin=Calc` is not a Calc measure).
        let builtIn = !isPlugin || isFormerPlugin || effectiveType == "powerplugin" ? effectiveType : ""
        let cls: Measure.Type
        var invalidType = false
        switch builtIn {
        case _ where registered != nil: cls = registered ?? UnsupportedMeasure.self
        case "calc": cls = CalcMeasure.self
        case "time": cls = TimeMeasure.self
        case "uptime": cls = UptimeMeasure.self
        case "cpu": cls = CPUMeasure.self
        case "memory", "physicalmemory", "swapmemory": cls = MemoryMeasure.self
        case "netin", "netout", "nettotal": cls = NetMeasure.self
        case "freediskspace": cls = FreeDiskSpaceMeasure.self
        case "loop": cls = LoopMeasure.self
        case "string": cls = StringMeasure.self
        case "process": cls = ProcessMeasure.self
        case "sysinfo": cls = SysInfoMeasure.self
        case "webparser": cls = WebParserMeasure.self
        case "powerplugin": cls = PowerPluginMeasure.self
        case "registry": cls = RegistryMeasure.self
        case "script":
            cls = UnsupportedMeasure.self
            addIssue("Lua scripts (Measure=Script) are not supported yet")
        default:
            cls = UnsupportedMeasure.self
            if isPlugin {
                if effectiveType.isEmpty {
                    invalidType = true
                    log("[\(section.name)] Measure=Plugin without a Plugin option", level: .warning)
                } else if Skin.appProvidedMeasures.contains(effectiveType) {
                    addIssue("Plugin \"\(plugin)\" is provided by the Deskset app and is not available here")
                } else if Skin.windowsOnlyMeasures.contains(effectiveType) {
                    addIssue("Plugin=\(plugin) is Windows-only and is not supported")
                } else if Skin.notYetSupportedMeasures.contains(effectiveType) {
                    addIssue("Plugin=\(plugin) is not supported yet")
                } else {
                    addIssue("Plugin \"\(plugin)\" is a Windows plugin and is not supported")
                }
            } else if Skin.appProvidedMeasures.contains(type), Skin.documentedMeasureTypes.contains(type) {
                // Only the measure types the app registers as `Measure=` (NowPlaying, MediaKey, WiFiStatus). A plugin
                // name written as a measure type (`Measure=AudioLevel`) is not a Rainmeter measure type and the app
                // does not register it as one: it reaches this fallback in the app too, where "provided by the
                // Deskset app" would be wrong — it is a mistake in the skin (logged below), as on Windows.
                addIssue("Measure=\(rawType) is provided by the Deskset app and is not available here")
            } else if Skin.windowsOnlyMeasures.contains(type) {
                addIssue("Measure=\(rawType) is Windows-only and is not supported")
            } else if Skin.notYetSupportedMeasures.contains(type) {
                addIssue("Measure=\(rawType) is not supported yet")
            } else if Skin.documentedMeasureTypes.contains(type) {
                addIssue("Measure=\(rawType) is not supported")
            } else {
                // Not a Rainmeter measure type at all (a typo): the skin is broken on Windows too.
                invalidType = true
                log("[\(section.name)] Measure=\(rawType) is not a valid measure type", level: .warning)
            }
        }
        let measure = cls.init(name: section.name, section: section, skin: self, type: effectiveType)
        if invalidType { (measure as? UnsupportedMeasure)?.isMacDifference = false }
        return measure
    }

    private func pluginName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.lowercased().hasSuffix(".dll") { name = String(name.dropLast(4)) }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func makeMeter(_ section: IniSection, type rawType: String) -> Meter {
        let type = rawType.trimmingCharacters(in: .whitespaces).lowercased()
        let cls: Meter.Type
        switch type {
        case "string": cls = StringMeter.self
        case "image": cls = ImageMeter.self
        case "bar": cls = BarMeter.self
        case "line": cls = LineMeter.self
        case "histogram": cls = HistogramMeter.self
        case "roundline": cls = RoundlineMeter.self
        case "rotator": cls = RotatorMeter.self
        case "shape": cls = ShapeMeter.self
        case "button": cls = ButtonMeter.self
        case "bitmap": cls = BitmapMeter.self
        default:
            cls = UnsupportedMeter.self
            if Skin.documentedMeterTypes.contains(type) {
                addIssue("Meter=\(rawType) is not supported")
            } else {
                // Not a Rainmeter meter type (a typo): an authoring error, broken on Windows too.
                log("[\(section.name)] Meter=\(rawType) is not a valid meter type", level: .warning)
            }
        }
        return cls.init(name: section.name, section: section, skin: self, type: type)
    }

    // MARK: Update cycle

    /// One update: measures in order, then meters, then layout, OnRefreshAction (first time) / OnUpdateAction,
    /// then asks the host to redraw.
    public func update() {
        assertOwned()
        guard !closed else { return }
        guard updateDepth < Skin.maxUpdateDepth else {
            logOnce("!Update inside an update was ignored (would loop)", level: .warning)
            return
        }
        if updateDepth == 0 && actionDepth == 0 { burstWork = 0 }
        updateDepth += 1
        defer {
            updateDepth -= 1
            if updateDepth == 0 && actionDepth == 0 { refreshOutsidePointerNeeds() }
        }
        environmentValid = false

        // An action may unload the skin (`!Refresh`, `!DeactivateConfig` through the host): stop right there.
        for m in measures where m.consumeUpdateTick() {
            m.readOptionsIfNeeded()
            m.performUpdate()
            if closed { return }
        }
        // Meters update and lay out in file order, so `[PreviousMeter:X]` and `r`/`R` see fresh values.
        resolveContainers()
        var needsSecondPass = false
        var placement = LayoutState()
        for m in meters {
            if m.consumeUpdateTick() { updateMeterNow(m) }
            if closed { return }
            if placement.place(m) { needsSecondPass = true }
        }
        meterFramesReady = true
        if needsSecondPass { layoutMeters() }
        layoutPending = false
        updateCount += 1
        updateSize()
        if updateCount == 1, !settings.onRefreshAction.isEmpty {
            execute(settings.onRefreshAction, from: rainmeterSection)
        }
        if !settings.onUpdateAction.isEmpty {
            execute(settings.onUpdateAction, from: rainmeterSection)
        }
        if pendingWakeAction {
            pendingWakeAction = false
            if !settings.onWakeAction.isEmpty { execute(settings.onWakeAction, from: rainmeterSection) }
        }
        if closed { return }
        host?.skinNeedsDisplay(self)
    }

    /// Re-reads (when needed) and updates one meter, then runs its OnUpdateAction.
    private func updateMeterNow(_ m: Meter) {
        burstWork += 1
        m.readOptionsIfNeeded()
        m.updateMeter()
        if !m.onUpdateAction.isEmpty { execute(m.onUpdateAction, from: m) }
    }

    /// A measure updated by a bang (`!UpdateMeasure`, `!UpdateMeasureGroup`): options re-read when needed.
    private func updateMeasureNow(_ m: Measure) {
        burstWork += 1
        m.readOptionsIfNeeded()
        m.performUpdate()
    }

    /// Recomputes meter frames (relative positioning) and, when allowed, the skin size.
    public func layout() {
        assertOwned()
        layoutPending = false
        resolveContainers()
        layoutMeters()
        updateSize()
    }

    /// Meter positions and sizes for readers that come before the first update has laid the meters out.
    ///
    /// Frames are computed by the first update's meter pass (and then by every layout). Earlier readers — a Lua
    /// script's main chunk (it runs while the skin loads), its `Initialize()` and first `Update()` (`Meter:GetX()`,
    /// `GetW()`…), and `[Meter:X]` / `[Meter:W]` section variables read by measures in the first update or by dynamic
    /// options while the skin loads — would otherwise read 0. The first such read lays the meters out provisionally
    /// from their options: X / Y with `r` / `R`, W / H, Padding, Hidden, Container, image and shape sizes, and for
    /// String meters the text of Text / Prefix / Postfix with the bound measures' current (at load: initial) values.
    /// Meters whose options were not read yet (the main chunk runs while the measures are read) are read now, with
    /// the load-time rules. The skin size is not computed (`updateSize` waits for the end of the first update), so a
    /// skin without DynamicWindowSize still gets its size from its first real update. The first update replaces
    /// every provisional frame. Rainmeter does not document when meter geometry becomes available; this is a
    /// judgment call (docs/compat/engine.md, "Meter geometry before the first update").
    func ensureMeterGeometry() {
        guard !meterFramesReady, !closed else { return }
        // Set first: a meter option read below that asks for geometry again (`[OtherMeter:X]` in a dynamic meter)
        // gets the frames as they are instead of recursing.
        meterFramesReady = true
        if !optionsLoaded {
            for m in meters where m.needsOptionRead { m.readOptionsIfNeeded() }
        }
        for m in meters { m.prepareProvisionalLayout() }
        resolveContainers()
        layoutMeters()
    }

    /// Set once meter frames have been computed (by a layout, the first update's meter pass, or
    /// `ensureMeterGeometry`); before that every frame is zero.
    private var meterFramesReady = false

    /// `!UpdateMeter` only marks the layout as stale; it is recomputed once when a meter section variable
    /// (`[Meter:W]`) is read, at the end of the outermost action, or by the next `!Redraw` / update — instead of
    /// after every one of `[!UpdateMeter A][!UpdateMeter B]…` (each layout measures every String meter's text).
    private func layoutIfPending() {
        if layoutPending { layout() }
    }

    /// Relative positioning state while walking the meters in file order (see `Meter` for the Container rules).
    private struct LayoutState {
        var previous: Meter?
        var previousContent: [ObjectIdentifier: Meter] = [:]
        var placed: Set<ObjectIdentifier> = []

        /// Places `m`; returns true when it is content of a container that comes later in the file (so its
        /// position used the container's previous frame and needs a second pass).
        mutating func place(_ m: Meter) -> Bool {
            var stale = false
            if let c = m.container {
                let key = ObjectIdentifier(c)
                m.layout(after: previousContent[key], in: c)
                previousContent[key] = m
                stale = !placed.contains(key)
            } else {
                m.layout(after: previous)
                previous = m
            }
            placed.insert(ObjectIdentifier(m))
            return stale
        }
    }

    private func layoutMeters() {
        meterFramesReady = true
        var needsSecondPass = false
        var state = LayoutState()
        for m in meters where state.place(m) { needsSecondPass = true }
        if needsSecondPass {
            state = LayoutState()
            for m in meters { _ = state.place(m) }
        }
    }

    /// Validates `Container=` options (no self reference, no nesting) and marks the containers.
    private func resolveContainers() {
        var anyContainer = false
        for m in meters where !m.containerName.isEmpty {
            anyContainer = true
            break
        }
        guard anyContainer || meters.contains(where: { $0.container != nil || $0.isContainer }) else { return }
        for m in meters { m.isContainer = false }
        for m in meters {
            guard !m.containerName.isEmpty else {
                m.container = nil
                continue
            }
            if let target = meter(named: m.containerName), target !== m, target.containerName.isEmpty {
                m.container = target
                target.isContainer = true
            } else {
                m.container = nil
                // An authoring error (Rainmeter rejects it too): a log line, not a compatibility issue.
                logOnce("Container=\(m.containerName) on [\(m.name)] is invalid (missing, itself, or nested)",
                        level: .warning)
            }
        }
    }

    /// Computes the window size from the meters (and the background). Without `DynamicWindowSize` it is computed
    /// once, at the end of the first update — not earlier: a `!Redraw` / `!UpdateMeter` that an IfCondition,
    /// IfAboveAction… runs while the measures of the first update are still updating (EasyInfo's blinking clock)
    /// would otherwise size the window from meters that have not been updated yet (every String meter still empty),
    /// and the skin would stay cut off.
    private func updateSize(force: Bool = false) {
        guard force || !sizeComputed || settings.dynamicWindowSize else { return }
        // Also for `!MoveMeter` ("the size of the skin window is re-evaluated"): during the first update the end of
        // that update computes it.
        guard updateCount > 0 else { return }
        sizeComputed = true
        var w = 0.0, h = 0.0
        // Content meters are clipped to their container, so only the container counts.
        for meter in meters where !meter.hidden && meter.container == nil {
            w = max(w, meter.frame.maxX)
            h = max(h, meter.frame.maxY)
        }
        // BackgroundMode=0 draws the image at its own size — after ImageCrop / ImageRotate (and EXIF orientation when
        // asked for) — so the window is at least that big.
        if let size = backgroundImageSize() {
            w = max(w, size.width)
            h = max(h, size.height)
        }
        width = Skin.side(settings.skinWidth ?? w)
        height = Skin.side(settings.skinHeight ?? h)
    }

    /// The size a `BackgroundMode=0` image is drawn at (nil without one, or when the image cannot be read).
    private func backgroundImageSize() -> (width: Double, height: Double)? {
        guard let bg = settings.backgroundImage, settings.backgroundMode == 0,
              let raw = host?.imageSize(atPath: bg) else { return nil }
        let options = settings.backgroundImageOptions
        let orientation = options.useExifOrientation
            ? ((host as? SkinImageQueries)?.imageExifOrientation(atPath: bg) ?? 1) : 1
        return options.displaySize(imageWidth: raw.width, imageHeight: raw.height, exifOrientation: orientation)
    }

    /// What the window is sized from, as it is laid out now (the editor's overflow handling, docs/editor-friendly.md
    /// §9.10): the union of the visible meters that are not content of a container (with their current frames, so a
    /// live preview counts) and a `BackgroundMode=0` image at the origin. Unlike the window it is not clipped at the
    /// origin: a meter at a negative X or Y gives a negative `x` / `y` (the part the desktop cuts off). Empty content
    /// is the zero rectangle at the origin.
    public func contentBounds() -> SkinRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ x: Double, _ y: Double, _ right: Double, _ bottom: Double) {
            guard x.isFinite, y.isFinite, right.isFinite, bottom.isFinite else { return }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, right)
            maxY = max(maxY, bottom)
        }
        for meter in meters where !meter.hidden && meter.container == nil {
            add(meter.frame.x, meter.frame.y, meter.frame.maxX, meter.frame.maxY)
        }
        if let size = backgroundImageSize() { add(0, 0, size.width, size.height) }
        guard minX <= maxX, minY <= maxY else { return SkinRect() }
        return SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The window size the engine gives content with these bounds: from the origin to their right and bottom edges
    /// (whatever lies left of or above the origin is cut off), unless `SkinWidth` / `SkinHeight` fix it.
    public func size(for bounds: SkinRect) -> SkinSize {
        SkinSize(width: Skin.side(settings.skinWidth ?? max(bounds.maxX, 0)),
                 height: Skin.side(settings.skinHeight ?? max(bounds.maxY, 0)))
    }

    /// Largest skin width / height in points. Judgment (the manual gives no limit): larger than any screen, small
    /// enough that no window or backing store the host makes from it can explode.
    public static let maxSide = 16_384.0

    /// A skin side: non-finite → 1, otherwise within 1…`maxSide`.
    static func side(_ v: Double) -> Double {
        v.isFinite ? v.clamped(1, maxSide) : 1
    }

    public func redraw() {
        assertOwned()
        layout()
        host?.skinNeedsDisplay(self)
    }

    /// The host calls this when the fonts available to the skin changed after it was laid out — a font registered
    /// later (another skin's `@Resources/Fonts`, a font file added and picked up by a refresh): every String meter is
    /// measured again and the window size is computed again once, even without `DynamicWindowSize` (the size from
    /// the first update was measured with a fallback font). Mac-only: Rainmeter loads a skin's fonts before it
    /// measures anything. Nothing happens before the first update (that update measures everything anyway).
    public func fontsDidChange() {
        assertOwned()
        guard !closed, updateCount > 0 else { return }
        layout()
        updateSize(force: true)
        host?.skinNeedsDisplay(self)
    }

    /// Runs OnCloseAction; call before the skin is unloaded. Afterwards the skin no longer updates and pending
    /// `!Delay` actions are dropped.
    public func close() {
        assertOwned()
        guard !closed else { return }
        if !settings.onCloseAction.isEmpty { execute(settings.onCloseAction, from: rainmeterSection) }
        // Stop plugin timers, pings, samplers, child processes and web requests now, not when the measures are
        // released — and the meters' own timers (Bitmap transitions).
        for m in measures { (m as? PluginLifecycle)?.skinWillClose() }
        for m in meters { (m as? PluginLifecycle)?.skinWillClose() }
        closed = true
        generation += 1
        // Cancelled rather than left to find the skin closed: they let go of what they hold at once.
        for work in pendingDelays.values { work.cancel() }
        pendingDelays = [:]
        refreshOutsidePointerNeeds()
    }

    /// The host calls this when the skin window gains (`true`) or loses focus: runs OnFocusAction /
    /// OnUnfocusAction. Judgment: the manual says these run "at the very end of the update cycle"; since focus
    /// changes happen between updates (and `Update=-1` skins never update again), they run right away.
    public func focusChanged(_ focused: Bool) {
        assertOwned()
        let action = focused ? settings.onFocusAction : settings.onUnfocusAction
        if !action.isEmpty { execute(action, from: rainmeterSection) }
    }

    /// The host calls this when the system wakes from sleep: `settings.onWakeAction` (read like every action option:
    /// `#Variables#` when the skin loads, section variables when it runs) runs "at the very end of the first update
    /// cycle" after that — right away for `Update=-1` skins, which do not update again. Call it before the catch-up
    /// update, so that update runs it. Nothing happens once the skin is closed.
    public func systemDidWake() {
        assertOwned()
        guard !closed, !settings.onWakeAction.isEmpty else { return }
        if settings.update < 0 {
            execute(settings.onWakeAction, from: rainmeterSection)
        } else {
            pendingWakeAction = true
        }
    }

    /// Whether dragging may start at the point (skin coordinates): outside the `DragMargins` (a negative margin is
    /// measured from the opposite side, e.g. `DragMargins=0,-100,0,0` leaves only the bottom 100 points draggable).
    public func isInDragArea(x: Double, y: Double) -> Bool {
        let m = settings.dragMargins
        func edge(_ v: Double, _ size: Double) -> Double { v >= 0 ? v : size + v }
        let left = edge(m.left, width), top = edge(m.top, height)
        let right = width - edge(m.right, width), bottom = height - edge(m.bottom, height)
        return x >= left && x < right && y >= top && y < bottom
    }

    /// True when the skin belongs to a skin group (`Group=` in `[Rainmeter]`), for the skin group bangs and
    /// `!SetVariableGroup`, which the host dispatches.
    public func isInSkinGroup(_ group: String) -> Bool {
        let g = group.trimmingCharacters(in: .whitespaces)
        return settings.groups.contains { $0.caseInsensitiveCompare(g) == .orderedSame }
    }

    // MARK: Lookup

    public func measure(named name: String) -> Measure? { measureIndex[name.trimmingCharacters(in: .whitespaces).lowercased()] }
    public func meter(named name: String) -> Meter? { meterIndex[name.trimmingCharacters(in: .whitespaces).lowercased()] }
    public func section(named name: String) -> SkinSection? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "rainmeter" { return rainmeterSection }
        return measureIndex[key] ?? meterIndex[key]
    }

    /// A section usable as a MeterStyle: any section except `[Rainmeter]`, `[Variables]` and `[Metadata]`.
    func styleSection(named name: String) -> IniSection? {
        let key = name.lowercased()
        if key == "rainmeter" || key == "variables" || key == "metadata" { return nil }
        return sectionIndex[key]
    }

    /// The options of a MeterStyle section keyed by lowercased name (see `styleSection(named:)`), built once.
    func styleValues(named name: String) -> [String: String]? {
        let key = name.lowercased()
        if let cached = styleValueIndex[key] { return cached }
        guard let section = styleSection(named: key) else { return nil }
        let values = SkinSection.index(section)
        styleValueIndex[key] = values
        return values
    }

    /// Measure number for formulas (Calc `Formula`, `IfCondition`, formulas in bangs): measure names are
    /// identifiers. A disabled measure is 0.
    func formulaValue(of identifier: String, from section: SkinSection?) -> Double? {
        measureIndex[identifier.lowercased()]?.value
    }

    // MARK: Variables

    public func variable(_ name: String) -> String? {
        variableValue(name, section: nil)
    }

    /// `!SetVariable`: built-in variables "cannot be directly modified by actions in a skin".
    public func setVariable(_ name: String, _ value: String) {
        assertOwned()
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }
        if BuiltInVariables.isBuiltIn(key) || key == "currentsection" {
            log("!SetVariable: built-in variable #\(name)# cannot be changed", level: .warning)
            return
        }
        variables[key] = value
    }

    /// Resolves variables in `text`; section variables too when `sectionVariables` is true.
    public func resolve(_ text: String, in section: SkinSection?, sectionVariables: Bool) -> String {
        if !Skin.containsVariableSyntax(text, dollar: mouseContext != nil) { return text }
        return resolver(for: section, sectionVariables: sectionVariables).resolve(text)
    }

    /// Replaces only `#Var#` (used when action options are read).
    public func resolveStandardVariables(_ text: String, in section: SkinSection?) -> String {
        if !text.utf8.contains(UInt8(ascii: "#")) { return text }
        return resolver(for: section, sectionVariables: false).resolveStandardVariables(text)
    }

    /// Quick reject for `resolve`: `#`, `[` (or `$` while a mouse action runs). A byte scan: `String.contains("#")`
    /// resolves to Foundation's substring search, which was a large part of every dynamic option read.
    private static func containsVariableSyntax(_ text: String, dollar: Bool) -> Bool {
        let hash = UInt8(ascii: "#"), open = UInt8(ascii: "["), sign = UInt8(ascii: "$")
        return text.utf8.contains { $0 == hash || $0 == open || (dollar && $0 == sign) }
    }

    private func resolver(for section: SkinSection?, sectionVariables: Bool) -> VariableResolver {
        VariableResolver(
            variableLookup: { [unowned self] name in self.variableValue(name, section: section) },
            sectionLookup: sectionVariables ? { [unowned self] name, parameter in
                self.sectionVariableValue(name, parameter)
            } : nil,
            eventLookup: mouseContext.map { context in { name in Skin.mouseVariable(name, context) } })
    }

    /// Mouse position while a mouse action runs, for `$MouseX$`, `$MouseY$`, `$MouseX:%$`, `$MouseY:%$`
    /// (relative to the meter that defines the action, or to the skin for `[Rainmeter]` actions).
    private struct MouseContext {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        /// False for the actions of `Plugin=Mouse` measures, which replace only `$MouseX$` and `$MouseY$`.
        var percentForms = true
    }
    private var mouseContext: MouseContext?

    private static func mouseVariable(_ name: String, _ c: MouseContext) -> String? {
        func percent(_ v: Double, _ size: Double) -> String? {
            guard c.percentForms else { return nil }
            return size > 0 ? String(Int((v / size * 100).rounded(.down).clamped(0, 100))) : "0"
        }
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "mousex": return String(Int(c.x.rounded(.down).clamped(-1e9, 1e9)))
        case "mousey": return String(Int(c.y.rounded(.down).clamped(-1e9, 1e9)))
        case "mousex:%": return percent(c.x, c.width)
        case "mousey:%": return percent(c.y, c.height)
        default: return nil
        }
    }

    private func withMouse(x: Double, y: Double, in frame: SkinRect, _ body: () -> Void) {
        let saved = mouseContext
        mouseContext = MouseContext(x: x - frame.x, y: y - frame.y, width: frame.width, height: frame.height)
        body()
        mouseContext = saved
    }

    /// Runs an action of a measure that follows the mouse itself (`Plugin=Mouse`) for the pointer at skin point
    /// (x, y): `$MouseX$` / `$MouseY$` are that point, or with `relativeToSkin` false the same point in screen
    /// coordinates (top-left origin at the primary screen's top-left corner, as `!Move` and `#CURRENTCONFIGX#` use).
    func executePointerAction(_ action: String, from section: SkinSection, x: Double, y: Double,
                              relativeToSkin: Bool) {
        if actionDepth == 0 && updateDepth == 0 { environmentValid = false }
        var px = x, py = y
        if !relativeToSkin {
            let frame = currentEnvironment().windowFrame
            px += frame.x
            py += frame.y
        }
        let saved = mouseContext
        mouseContext = MouseContext(x: px, y: py, width: 0, height: 0, percentForms: false)
        execute(action, from: section)
        mouseContext = saved
    }

    private func variableValue(_ name: String, section: SkinSection?) -> String? {
        let key = name.lowercased()
        if key == "currentsection" { return section?.name ?? "" }
        if let dynamic = dynamicBuiltIn(key) { return dynamic }
        return variables[key]
    }

    /// The built-in variables the manual calls dynamic: `CURRENTCONFIGX/Y/WIDTH/HEIGHT`, `CURRENTCONFIGZPOS`,
    /// `CONFIGEDITOR` and all monitor variables. nil for every other name.
    private func dynamicBuiltIn(_ key: String) -> String? {
        let isConfigVariable = key.hasPrefix("currentconfig") && key.utf8.count > 13
        let isMonitorVariable = key.hasPrefix("workarea") || key.hasPrefix("screenarea") || key.hasPrefix("pworkarea")
            || key.hasPrefix("pscreenarea") || key.hasPrefix("vscreenarea")
        guard isConfigVariable || isMonitorVariable || key == "configeditor" else { return nil }
        let env = currentEnvironment()
        switch key {
        case "currentconfigx": return formatInt(env.windowFrame.x)
        case "currentconfigy": return formatInt(env.windowFrame.y)
        case "currentconfigwidth": return formatInt(env.windowFrame.width)
        case "currentconfigheight": return formatInt(env.windowFrame.height)
        case "currentconfigzpos": return String(env.zPosition)
        case "configeditor": return env.configEditor
        default: return monitorVariable(key, env)
        }
    }

    /// `#WORKAREAX#` (current monitor), `#PWORKAREAX#` (primary), `#VSCREENAREAX#` (virtual screen) and
    /// `#WORKAREAX@N#` (monitor N, 1-based) and the Y / WIDTH / HEIGHT and SCREENAREA forms.
    private func monitorVariable(_ key: String, _ env: SkinEnvironment) -> String? {
        var base = key
        var screen: Int?
        if key.utf8.contains(UInt8(ascii: "@")) {
            guard let parsed = BuiltInVariables.monitorVariable(key), parsed.monitor >= 1 else { return nil }
            base = parsed.base.lowercased()
            screen = parsed.monitor - 1
        }
        let rect: SkinRect
        let rest: Substring
        func pick(_ index: Int, work: Bool) -> SkinRect? {
            guard index >= 0, index < env.screens.count else { return nil }
            return work ? env.screens[index].workArea : env.screens[index].area
        }
        if base.hasPrefix("vscreenarea") {
            guard var virtual = env.screens.first?.area else { return nil }
            for s in env.screens.dropFirst() {
                let minX = min(virtual.x, s.area.x), minY = min(virtual.y, s.area.y)
                let maxX = max(virtual.maxX, s.area.maxX), maxY = max(virtual.maxY, s.area.maxY)
                virtual = SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            rect = virtual
            rest = base.dropFirst("vscreenarea".count)
        } else if base.hasPrefix("pscreenarea") || base.hasPrefix("pworkarea") {
            guard let r = pick(0, work: base.hasPrefix("pwork")) else { return nil }
            rect = r
            rest = base.dropFirst(base.hasPrefix("pwork") ? "pworkarea".count : "pscreenarea".count)
        } else if base.hasPrefix("screenarea") || base.hasPrefix("workarea") {
            let work = base.hasPrefix("work")
            let index = screen ?? env.currentScreen
            guard let r = pick(index, work: work) ?? (screen == nil ? pick(0, work: work) : nil) else { return nil }
            rect = r
            rest = base.dropFirst(work ? "workarea".count : "screenarea".count)
        } else {
            return nil
        }
        switch rest {
        case "x": return formatInt(rect.x)
        case "y": return formatInt(rect.y)
        case "width": return formatInt(rect.width)
        case "height": return formatInt(rect.height)
        default: return nil
        }
    }

    /// Host facts, fetched at most once per update / top-level action.
    func currentEnvironment() -> SkinEnvironment {
        if !environmentValid {
            environmentCache = host?.environment(for: self) ?? SkinEnvironment(windowFrame: SkinRect(width: width,
                                                                                                      height: height))
            if environmentCache.windowFrame == SkinRect() {
                environmentCache.windowFrame = SkinRect(width: width, height: height)
            }
            environmentValid = true
        }
        return environmentCache
    }

    private func sectionVariableValue(_ name: String, _ parameter: SectionVariableParameter) -> String? {
        let key = name.lowercased()
        if let m = measureIndex[key] {
            switch parameter {
            case .none:
                return m.stringValue
            case .number(let format):
                return format.format(value: m.value, minValue: m.minValue, maxValue: m.maxValue)
            case .keyword:
                switch parameter.knownKeyword {
                case .maxValue: return NumberFormatting.plain(m.maxValue)
                case .minValue: return NumberFormatting.plain(m.minValue)
                case .escapeRegExp: return SectionVariables.escapeRegExp(m.stringValue)
                case .encodeUrl: return SectionVariables.encodeUrl(m.stringValue)
                case .timestamp: return (m as? TimeMeasure).map { NumberFormatting.plain($0.timestamp) }
                default:
                    // [&Script:Function(args)], plugin functions.
                    if case .keyword(let call) = parameter, let f = m as? SectionVariableFunctions {
                        return f.sectionVariableFunction(call)
                    }
                    return nil
                }
            }
        }
        // "Section variables for meters have no value without a parameter."
        if let meter = meterIndex[key], case .keyword(let word) = parameter {
            ensureMeterGeometry()
            layoutIfPending()
            let f = meter.frame
            switch word.lowercased() {
            case "x": return formatInt(f.x)
            case "y": return formatInt(f.y)
            case "w": return formatInt(f.width)
            case "h": return formatInt(f.height)
            case "xw": return formatInt(f.maxX)
            case "yh": return formatInt(f.maxY)
            default: return nil
            }
        }
        return nil
    }

    private func formatInt(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        return String(Int(v.rounded(.towardZero).clamped(-9e18, 9e18)))
    }

    private func builtInVariables() -> [String: String] {
        let env = currentEnvironment()
        func dir(_ url: URL) -> String {
            let p = url.path
            return p.hasSuffix("/") ? p : p + "/"
        }
        var b: [String: String] = [
            "@": dir(resourcesDirectory),
            "currentpath": dir(directory),
            "currentfile": fileURL.lastPathComponent,
            "currentconfig": config,
            "rootconfig": rootConfig,
            "rootconfigpath": dir(rootConfigDirectory),
            "skinspath": dir(skinsDirectory),
            "settingspath": env.settingsPath,
            "programpath": env.programPath,
            "programdrive": "/",
            "addonspath": env.settingsPath + "Addons/",
            "pluginspath": env.settingsPath + "Plugins/",
            "crlf": BuiltInVariables.crlfValue,
            "configeditor": env.configEditor,
            "currentconfigzpos": String(env.zPosition),
        ]
        // Monitor values as of load time (for [Variables] and @Include); options resolve them dynamically.
        for name in BuiltInVariables.names where name.hasSuffix("AREAX") || name.hasSuffix("AREAY")
            || name.hasSuffix("AREAWIDTH") || name.hasSuffix("AREAHEIGHT") {
            let key = name.lowercased()
            if let v = monitorVariable(key, env) { b[key] = v }
        }
        for i in env.screens.indices {
            for name in BuiltInVariables.monitorIndexedNames {
                let key = "\(name.lowercased())@\(i + 1)"
                if let v = monitorVariable(key, env) { b[key] = v }
            }
        }
        return b
    }

    // MARK: Paths

    /// Absolute path for a skin-relative path (relative to the skin folder); `\` becomes `/`.
    public func absolutePath(_ raw: String, relativeTo base: URL? = nil) -> String {
        var p = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if p.hasPrefix("\""), p.hasSuffix("\""), p.count >= 2 { p = String(p.dropFirst().dropLast()) }
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        if p.hasPrefix("/") { return (p as NSString).standardizingPath }
        return ((base ?? directory).appendingPathComponent(p).path as NSString).standardizingPath
    }

    /// Image file path: `ImagePath` prefix + name, relative names resolved against the skin folder. Manual (Image
    /// meter, and every image option that refers to it): "If no file extension is included, .png is assumed" — `.png`
    /// is appended when the file name has no extension and no file of exactly that name exists (a name ending in
    /// `/` or `\` is left alone).
    public func imageFilePath(_ name: String, imagePath: String) -> String {
        let trimmedPath = imagePath.trimmingCharacters(in: .whitespaces)
        let path: String
        if trimmedPath.isEmpty {
            path = absolutePath(name)
        } else {
            let base = URL(fileURLWithPath: absolutePath(trimmedPath), isDirectory: true)
            path = absolutePath(name, relativeTo: base)
        }
        let written = name.trimmingCharacters(in: .whitespaces)
        guard !written.isEmpty, !written.hasSuffix("/"), !written.hasSuffix("\\") else { return path }
        let last = (path as NSString).lastPathComponent
        guard !last.isEmpty, last != "/", (last as NSString).pathExtension.isEmpty else { return path }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return path
        }
        return path + ".png"
    }

    // MARK: Actions & bangs

    /// Executes an action string (`[!Bang …][…]`). Section variables in bang arguments are resolved at execution.
    /// Arguments written in `"""magic quotes"""` are passed literally.
    public func execute(_ actionText: String, from section: SkinSection?) {
        assertOwned()
        if actionDepth == 0 && updateDepth == 0 { environmentValid = false }
        let actions = ActionParser.parseDetailed(actionText)
        run(actions[...], from: section)
    }

    private func run(_ actions: ArraySlice<ParsedAction>, from section: SkinSection?) {
        guard actionDepth < Skin.maxActionDepth else {
            logOnce("Actions nested too deeply (an action keeps triggering itself); stopped", level: .error)
            return
        }
        if actionDepth == 0 && updateDepth == 0 { burstWork = 0 }
        actionDepth += 1
        defer {
            actionDepth -= 1
            if actionDepth == 0 && !closed { layoutIfPending() }
            if actionDepth == 0 && updateDepth == 0 { refreshOutsidePointerNeeds() }
        }
        var index = actions.startIndex
        // A bang that unloads the skin (e.g. !Refresh through the host) ends the rest of the action.
        while index < actions.endIndex && !closed {
            burstWork += 1
            guard burstWork <= Skin.maxBurstWork else {
                logOnce("Actions keep triggering each other (e.g. OnUpdateAction=[!UpdateMeter *] on several meters); "
                        + "the rest was skipped", level: .error)
                return
            }
            let parsed = actions[index]
            index += 1
            func resolved(_ value: String, _ position: Int) -> String {
                position < parsed.quoting.count && parsed.quoting[position] == .magic
                    ? value : resolve(value, in: section, sectionVariables: true)
            }
            switch parsed.action {
            case .bang(let bang):
                let bang = Bang(name: bang.name, args: bang.args.enumerated().map { resolved($0.element, $0.offset) })
                if bang.name == "delay" {
                    // "The lowest possible value is 16 milliseconds." Judgment: the rest of the action runs later
                    // on the skin's executor instead of blocking the skin; a refresh / unload (`close()`) cancels it.
                    let ms = bang.args.first.flatMap { OptionValue.number($0) } ?? 0
                    let rest = Array(actions[index...])
                    let delay = min(max(ms, 16), 86_400_000) / 1000
                    let scheduled = generation
                    // Rainmeter blocks the skin during a delay, so it can never pile up delays; here e.g.
                    // `OnUpdateAction=[!Delay 60000]…` with Update=16 would queue thousands of pending actions.
                    guard pendingDelays.count < Skin.maxPendingDelays else {
                        logOnce("Too many pending !Delay actions; the rest of the action was skipped", level: .warning)
                        return
                    }
                    lastDelayID &+= 1
                    let id = lastDelayID
                    // `$MouseX$`… in the delayed part still refer to the event that started the action.
                    let mouse = mouseContext
                    // Weak: a delay of up to a day must not keep a skin alive that is dropped without being closed.
                    pendingDelays[id] = executor.async(after: delay) { [weak self] in
                        guard let self else { return }
                        self.pendingDelays[id] = nil
                        guard !self.closed, self.generation == scheduled else { return }
                        self.environmentValid = false
                        let saved = self.mouseContext
                        self.mouseContext = mouse
                        self.run(rest[...], from: section)
                        self.mouseContext = saved
                    }
                    return
                }
                let literal = Set(parsed.quoting.indices.filter { parsed.quoting[$0] == .magic })
                perform(bang, from: section, literalArguments: literal)
            case .execute(let target, let arguments):
                host?.skin(self, execute: resolved(target, 0),
                           arguments: arguments.enumerated().map { resolved($0.element, $0.offset + 1) })
            }
        }
    }

    /// Bangs the engine performs itself. Their `Config` argument (found with `BangCatalog`) routes them to another
    /// skin through the host, or to every skin for `*`.
    private static let localBangs: Set<String> = [
        "setoption", "setoptiongroup", "setvariable", "writekeyvalue",
        "update", "redraw",
        "updatemeter", "updatemetergroup", "updatemeasure", "updatemeasuregroup", "movemeter",
        "showmeter", "hidemeter", "togglemeter", "showmetergroup", "hidemetergroup", "togglemetergroup",
        "enablemeasure", "disablemeasure", "togglemeasure",
        "enablemeasuregroup", "disablemeasuregroup", "togglemeasuregroup",
        "pausemeasure", "unpausemeasure", "togglepausemeasure",
        "pausemeasuregroup", "unpausemeasuregroup", "togglepausemeasuregroup",
        "commandmeasure", "pluginbang",
        "disablemouseaction", "clearmouseaction", "enablemouseaction", "togglemouseaction",
        "disablemouseactiongroup", "clearmouseactiongroup", "enablemouseactiongroup", "togglemouseactiongroup",
        "log",
    ]

    /// Performs one bang (arguments already resolved).
    ///
    /// Config argument (manual: "valid values are the config name of a currently loaded skin to be acted upon or
    /// * (asterisk) to act on all currently loaded skins. When optional and not supplied, the parameter defaults to
    /// the current config"): for the bangs the engine performs itself, a Config naming another skin forwards the
    /// bang (without that argument) through `SkinHost.skin(_:forward:toConfig:)`; `*` performs it here and forwards
    /// it with `*` for the other skins. All other bangs go to `SkinHost.skin(_:handle:)` unchanged (the host reads
    /// their Config itself); unsupported ones are listed in `issues`.
    public func perform(_ bang: Bang, from section: SkinSection? = nil) {
        assertOwned()
        if actionDepth == 0 && updateDepth == 0 {
            // Called by the host (e.g. a bang forwarded from another skin): a burst of its own.
            burstWork = 0
            environmentValid = false
        }
        perform(bang, from: section, literalArguments: [])
        if actionDepth == 0 && !closed { layoutIfPending() }
        if actionDepth == 0 && updateDepth == 0 { refreshOutsidePointerNeeds() }
    }

    /// `literalArguments`: indices of arguments written in `"""magic quotes"""`, which are "treated strictly
    /// literal" — no `(formula)` evaluation for `!SetVariable` / `!WriteKeyValue` / `!SetOption` values.
    func perform(_ bang: Bang, from section: SkinSection?, literalArguments: Set<Int>) {
        guard Skin.localBangs.contains(bang.name) else {
            if bang.name != "delay" { forwardToHost(bang) }
            return
        }
        var args = bang.args
        if let definition = BangCatalog.definition(for: bang.name), let configIndex = definition.configParameterIndex {
            let target = definition.configArgument(in: args)
            if args.count > configIndex { args = Array(args.prefix(configIndex)) }
            if let target, !isOwnConfig(target) {
                let local = Bang(name: bang.name, args: args)
                if target == "*" {
                    performLocally(local, from: section, literal: literalArguments)
                    host?.skin(self, forward: local, toConfig: "*")
                } else {
                    host?.skin(self, forward: local, toConfig: target)
                }
                return
            }
        }
        performLocally(Bang(name: bang.name, args: args), from: section, literal: literalArguments)
    }

    private func isOwnConfig(_ name: String) -> Bool {
        let normalized = name.replacingOccurrences(of: "/", with: "\\")
        return normalized.caseInsensitiveCompare(config) == .orderedSame
    }

    private func performLocally(_ bang: Bang, from section: SkinSection?, literal: Set<Int> = []) {
        let a = bang.args
        func arg(_ i: Int) -> String { i < a.count ? a[i] : "" }
        /// Argument `i` as a value: formulas evaluated unless magic-quoted.
        func valueArg(_ i: Int, _ evaluate: (String) -> String) -> String {
            literal.contains(i) ? arg(i) : evaluate(arg(i))
        }

        switch bang.name {
        case "setoption":
            if let s = self.section(named: arg(0)) {
                setOption(s, key: arg(1), value: Skin.readsMeasureNames(arg(1)) ? arg(2) : valueArg(2, bangFormulaValue))
            } else {
                log("!SetOption: section [\(arg(0))] not found", level: .warning)
            }
        case "setoptiongroup":
            let v = Skin.readsMeasureNames(arg(1)) ? arg(2) : valueArg(2, bangFormulaValue)
            for s in sections(inGroup: arg(0)) { setOption(s, key: arg(1), value: v) }
        case "setvariable":
            setVariable(arg(0), valueArg(1, evaluatedValue))
        case "writekeyvalue":
            writeKeyValue(section: arg(0), key: arg(1), value: valueArg(2, evaluatedValue), file: arg(3))
        case "update":
            update()
        case "redraw":
            redraw()
        case "updatemeter":
            meters(matching: arg(0)).forEach(updateMeterNow)
            layoutPending = true
        case "updatemetergroup":
            meters.filter { $0.isInGroup(arg(0)) }.forEach(updateMeterNow)
            layoutPending = true
        case "updatemeasure":
            measures(matching: arg(0)).forEach(updateMeasureNow)
        case "updatemeasuregroup":
            measures.filter { $0.isInGroup(arg(0)) }.forEach(updateMeasureNow)
        case "movemeter":
            if let m = meter(named: arg(2)) {
                m.overrides["x"] = arg(0).trimmingCharacters(in: .whitespaces)
                m.overrides["y"] = arg(1).trimmingCharacters(in: .whitespaces)
                m.needsOptionRead = true
                m.readOptionsIfNeeded()
                layout()
                // "The size of the skin window is re-evaluated after the meter is moved."
                updateSize(force: true)
                host?.skinNeedsDisplay(self)
            } else {
                log("!MoveMeter: meter [\(arg(2))] not found", level: .warning)
            }
        case "showmeter": meters(matching: arg(0)).forEach { $0.setHidden(false) }
        case "hidemeter": meters(matching: arg(0)).forEach { $0.setHidden(true) }
        case "togglemeter": meters(matching: arg(0)).forEach { $0.setHidden(!$0.hidden) }
        case "showmetergroup": meters.filter { $0.isInGroup(arg(0)) }.forEach { $0.setHidden(false) }
        case "hidemetergroup": meters.filter { $0.isInGroup(arg(0)) }.forEach { $0.setHidden(true) }
        case "togglemetergroup": meters.filter { $0.isInGroup(arg(0)) }.forEach { $0.setHidden(!$0.hidden) }
        case "enablemeasure": measures(matching: arg(0)).forEach { $0.setDisabled(false) }
        case "disablemeasure": measures(matching: arg(0)).forEach { $0.setDisabled(true) }
        case "togglemeasure": measures(matching: arg(0)).forEach { $0.setDisabled(!$0.disabled) }
        case "enablemeasuregroup": measures.filter { $0.isInGroup(arg(0)) }.forEach { $0.setDisabled(false) }
        case "disablemeasuregroup": measures.filter { $0.isInGroup(arg(0)) }.forEach { $0.setDisabled(true) }
        case "togglemeasuregroup": measures.filter { $0.isInGroup(arg(0)) }.forEach { $0.setDisabled(!$0.disabled) }
        case "pausemeasure": measures(matching: arg(0)).forEach { $0.setPaused(true) }
        case "unpausemeasure": measures(matching: arg(0)).forEach { $0.setPaused(false) }
        case "togglepausemeasure": measures(matching: arg(0)).forEach { $0.setPaused(!$0.paused) }
        case "pausemeasuregroup": measures.filter { $0.isInGroup(arg(0)) }.forEach { $0.setPaused(true) }
        case "unpausemeasuregroup": measures.filter { $0.isInGroup(arg(0)) }.forEach { $0.setPaused(false) }
        case "togglepausemeasuregroup": measures.filter { $0.isInGroup(arg(0)) }.forEach { $0.setPaused(!$0.paused) }
        case "commandmeasure":
            commandMeasure(arg(0), arg(1))
        case "pluginbang":
            // Deprecated form of !CommandMeasure; also written as one argument "Measure Arguments".
            if a.count >= 2 {
                commandMeasure(arg(0), arg(1))
            } else {
                let parts = arg(0).trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                commandMeasure(parts.first.map(String.init) ?? "", parts.count > 1 ? String(parts[1]) : "")
            }
        case "disablemouseaction", "clearmouseaction", "enablemouseaction", "togglemouseaction":
            let targets: [SkinSection]
            let name = arg(0).trimmingCharacters(in: .whitespaces)
            if name == "*" {
                targets = meters
            } else if let s = self.section(named: name), s is Meter || s is RainmeterSection {
                targets = [s]
            } else {
                log("!\(bang.name): meter [\(name)] not found", level: .warning)
                targets = []
            }
            setMouseActions(bang.name, targets: targets, actions: arg(1))
        case "disablemouseactiongroup", "clearmouseactiongroup", "enablemouseactiongroup", "togglemouseactiongroup":
            setMouseActions(String(bang.name.dropLast("group".count)), targets: meters.filter { $0.isInGroup(arg(1)) },
                            actions: arg(0))
        case "log":
            let level: SkinLogLevel
            switch arg(1).trimmingCharacters(in: .whitespaces).lowercased() {
            case "warning": level = .warning
            case "error": level = .error
            case "debug": level = .debug
            default: level = .notice
            }
            log(arg(0), level: level)
        default:
            forwardToHost(bang)
        }
    }

    private func forwardToHost(_ bang: Bang) {
        if host?.skin(self, handle: bang) != true {
            // Once per bang name: an unsupported bang in OnUpdateAction would otherwise log on every update.
            if BangCatalog.isKnown(bang.name) {
                addIssue("Bang !\(bang.name) is not supported")
                logOnce("Unsupported bang: !\(bang.name)", level: .warning)
            } else {
                // Not a Rainmeter bang (a typo): Rainmeter cannot run it either, so it is only logged.
                logOnce("Unknown bang: !\(bang.name)", level: .warning)
            }
        }
    }

    private func commandMeasure(_ name: String, _ command: String) {
        if let m = measure(named: name) {
            m.execute(command: command)
        } else {
            log("!CommandMeasure: measure [\(name)] not found", level: .warning)
        }
    }

    /// `!SetOption`: stored raw (the section resolves it when reading options, once, or every update when
    /// dynamic); "" removes the option. The `[Rainmeter]` section only accepts the context menu options.
    private func setOption(_ section: SkinSection, key: String, value: String) {
        let lower = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty, lower != "meter", lower != "measure" else { return }
        if section is RainmeterSection {
            guard lower.hasPrefix("contexttitle") || lower.hasPrefix("contextaction") else {
                log("!SetOption cannot change \(key) in [Rainmeter] (only ContextTitle/ContextAction)", level: .warning)
                return
            }
            section.overrides[lower] = value
            settings.contextItems = contextMenuItems().filter { !$0.isSeparator }.map { ($0.title, $0.action) }
            return
        }
        section.overrides[lower] = value
        section.needsOptionRead = true
        // A !SetOption of Hidden / Disabled / Paused applies even when the text equals the previous one
        // (history: "!SetOption: Changed to work with X, Y, and Hidden on meters").
        switch lower {
        case "hidden": (section as? Meter)?.lastHiddenOption = nil
        case "disabled": (section as? Measure)?.lastDisabledOption = nil
        case "paused": (section as? Measure)?.lastPausedOption = nil
        default: break
        }
    }

    /// Options whose formulas use measure names themselves, "always dynamic" (Calc `Formula`, `IfCondition`N):
    /// `!SetOption` stores them as written — evaluating `(MeasureCPU * 2)` at bang time would freeze the Calc at
    /// the value the measure had when the bang ran.
    static func readsMeasureNames(_ option: String) -> Bool {
        let key = option.trimmingCharacters(in: .whitespaces).lowercased()
        if key == "formula" { return true }
        guard key.hasPrefix("ifcondition") else { return false }
        return key.dropFirst("ifcondition".count).allSatisfy(\.isNumber)
    }

    /// Manual (Dynamic cheat sheet): "Measures in a (formula) … used in any Bang do not require DynamicVariables".
    /// A `!SetOption` value that is one parenthesized formula naming measures is evaluated now, with the measures'
    /// current values; any other value is stored as written.
    private func bangFormulaValue(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), t.hasSuffix(")"), let compiled = try? Formula.compile(t),
              !compiled.identifiers.isEmpty,
              compiled.identifiers.allSatisfy({ measureIndex[$0.lowercased()] != nil }),
              let n = try? compiled.evaluate({ self.formulaValue(of: $0, from: nil) }) else { return value }
        return NumberFormatting.plain(n, maxDecimals: 10)
    }

    /// `!SetVariable` / `!WriteKeyValue` values: "Formulas must be enclosed in parentheses with the entire parameter
    /// enclosed in quotes if there are spaces" — a value that is one parenthesized formula is evaluated (measure
    /// names allowed) and stored as a number (up to 10 decimals, trailing zeros removed); anything else, including
    /// a formula that fails, is stored as written.
    private func evaluatedValue(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), t.hasSuffix(")"),
              let n = try? Formula.evaluate(t, lookup: { self.formulaValue(of: $0, from: nil) }) else { return value }
        return NumberFormatting.plain(n, maxDecimals: 10)
    }

    /// `!WriteKeyValue Section Key Value [FilePath]`: FilePath defaults to the current skin file; relative paths are
    /// relative to the skin folder; "The file must exist and must be located under either #SKINSPATH# or
    /// #SETTINGSPATH#."
    private func writeKeyValue(section: String, key: String, value: String, file: String) {
        let trimmed = file.trimmingCharacters(in: .whitespaces)
        let url = trimmed.isEmpty ? fileURL : URL(fileURLWithPath: absolutePath(trimmed))
        let roots = [skinsDirectory, URL(fileURLWithPath: currentEnvironment().settingsPath, isDirectory: true)]
        guard IniWriter.isPathAllowed(url, roots: roots) else {
            log("!WriteKeyValue: \(url.path) is not under #SKINSPATH# or #SETTINGSPATH#", level: .error)
            return
        }
        do {
            try IniWriter.writeValue(value, key: key, section: section, fileURL: url)
            keyValueWrites += 1
        } catch {
            log("!WriteKeyValue: \(error)", level: .error)
        }
    }

    private func setMouseActions(_ bangName: String, targets: [SkinSection], actions: String) {
        let kinds = BangCatalog.mouseActions(in: actions).compactMap(MouseEventKind.init(rawValue:))
        if kinds.isEmpty { log("!\(bangName): no valid mouse action in \"\(actions)\"", level: .warning) }
        for target in targets {
            for kind in kinds {
                switch bangName {
                case "disablemouseaction": target.setMouseActionState(kind, .disabled)
                case "clearmouseaction": target.setMouseActionState(kind, .cleared)
                case "enablemouseaction": target.setMouseActionState(kind, .enabled)
                default: target.toggleMouseActionState(kind)
                }
            }
        }
    }

    private func sections(inGroup group: String) -> [SkinSection] {
        (measures as [SkinSection] + meters as [SkinSection]).filter { $0.isInGroup(group) }
    }

    private func meters(matching name: String) -> [Meter] {
        name.trimmingCharacters(in: .whitespaces) == "*" ? meters : meter(named: name).map { [$0] } ?? []
    }

    private func measures(matching name: String) -> [Measure] {
        name.trimmingCharacters(in: .whitespaces) == "*" ? measures : measure(named: name).map { [$0] } ?? []
    }

    // MARK: Context menu

    /// Custom context menu items (`ContextTitle`, `ContextTitle2`… with `ContextAction`…), read now: "Variables in
    /// ContextTitleN are always dynamic. Variable values are read at the time the context menu is opened", and
    /// `!SetOption Rainmeter ContextTitle …` may change them. Rules: at most 25 items; a title over 30 characters is
    /// truncated with `...`; when more than 3 titles are given, a title of only dashes is a separator; a title
    /// without its action (or a blank title) is invalid and ends the list.
    public func contextMenuItems() -> [ContextMenuItem] {
        assertOwned()
        guard let root = rainmeterSection else { return [] }
        var titles: [String] = []
        for i in 1...25 {
            guard let raw = root.rawOption(i == 1 ? "ContextTitle" : "ContextTitle\(i)") else { break }
            let title = resolve(raw, in: root, sectionVariables: true).trimmingCharacters(in: .whitespaces)
            if title.isEmpty { break }
            titles.append(title)
        }
        var items: [ContextMenuItem] = []
        for (offset, title) in titles.enumerated() {
            let i = offset + 1
            let action = root.actionOption(i == 1 ? "ContextAction" : "ContextAction\(i)")
            if titles.count > 3, title.allSatisfy({ $0 == "-" }) {
                items.append(ContextMenuItem(title: "-", action: "", isSeparator: true))
                continue
            }
            if action.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let shown = title.count > 30 ? String(title.prefix(30)) + "..." : title
            items.append(ContextMenuItem(title: shown, action: action))
        }
        return items
    }

    // MARK: Mouse

    /// Topmost visible meter under the point that defines `kind` (nil → skin-level action). A disabled action
    /// still catches the event; a cleared one lets it through.
    public func meter(at x: Double, _ y: Double, handling kind: MouseEventKind) -> Meter? {
        meters.last { $0.effectiveMouseAction(kind) != nil && $0.isHit(x: x, y: y) }
    }

    /// Dispatches a mouse action at a point. Returns true when some action ran (or a disabled action caught it).
    /// "Actions defined for a meter will override actions defined in the [Rainmeter] section."
    ///
    /// Meters are tried top-down (last in the file first) where `Meter.isHit` holds, so the empty space around a
    /// Shape lets the meter underneath get the event. A meter that handles the mouse itself (Button) gets the event
    /// first (a Button ignores its transparent pixels); when it does not consume it, its own mouse action (if any)
    /// runs, otherwise the search goes on below it — so a transparent pixel of a Button without a mouse action for
    /// the event lets the Button underneath get the click.
    ///
    /// Mouse capture: the self-handling meter pressed by a `.leftDown` gets the matching `.leftUp` even when the
    /// button is released outside it. Released where it is not hit (`isHit(precise: true)`: outside its pixels, or
    /// it or its container was hidden meanwhile, or its container masks it there), it only returns to normal
    /// (`mouseHover(inside: false)`) and runs nothing; see also `cancelMousePress()`.
    @discardableResult
    public func mouseEvent(_ kind: MouseEventKind, x: Double, y: Double) -> Bool {
        assertOwned()
        environmentValid = false
        var alreadyNotified: Meter?
        if kind == .leftUp, let captured = pressedMeter {
            pressedMeter = nil
            alreadyNotified = captured
            if captured.isHit(x: x, y: y, precise: true) {
                if captured.handleMouse(.leftUp, x: x, y: y) { return true }
            } else {
                captured.mouseHover(inside: false, x: x, y: y)
            }
            if closed { return true }
        }
        for m in meters.reversed() where m.isHit(x: x, y: y) {
            let selfHandling = m.handlesMouseItself && m !== alreadyNotified
            if selfHandling {
                let consumed = m.handleMouse(kind, x: x, y: y)
                if closed { return true }
                if consumed {
                    if kind == .leftDown { pressedMeter = m }
                    return true
                }
            }
            if let action = m.effectiveMouseAction(kind) {
                // A Button with its own LeftMouseDownAction is pressed too (it leaves the event to the action) — when
                // the press is on its pixels, not only in its frame.
                if selfHandling && kind == .leftDown && m.isHit(x: x, y: y, precise: true) { pressedMeter = m }
                if !action.isEmpty { withMouse(x: x, y: y, in: m.frame) { execute(action, from: m) } }
                return true
            }
        }
        if let root = rainmeterSection, let action = root.effectiveMouseAction(kind) {
            if !action.isEmpty {
                withMouse(x: x, y: y, in: SkinRect(width: width, height: height)) { execute(action, from: root) }
            }
            return true
        }
        return false
    }

    /// The host calls this when a left-button press will not get its release through `mouseEvent(.leftUp…)` — e.g.
    /// the press started a window drag: a pressed Button returns to its normal state (the next mouse move shows the
    /// hover state again).
    public func cancelMousePress() {
        assertOwned()
        pressedMeter = nil
        for m in meters where m.handlesMouseItself {
            m.mouseHover(inside: false, x: -1, y: -1)
            if closed { return }
        }
    }

    /// True when a click at the point would trigger (or be caught by) an action (used to decide click vs drag).
    public func hasAction(_ kind: MouseEventKind, x: Double, y: Double) -> Bool {
        assertOwned()
        return meter(at: x, y, handling: kind) != nil || rainmeterSection?.effectiveMouseAction(kind) != nil
    }

    /// Tracks MouseOverAction / MouseLeaveAction for meters and the skin.
    public func mouseMoved(x: Double, y: Double) {
        assertOwned()
        environmentValid = false
        if !mouseInside {
            mouseInside = true
            if let root = rainmeterSection, let a = root.effectiveMouseAction(.over), !a.isEmpty {
                withMouse(x: x, y: y, in: SkinRect(width: width, height: height)) { execute(a, from: root) }
            }
        }
        // Judgment: only the topmost self-handling meter whose own area (a Button's opaque pixels) is under the mouse
        // — the one a click presses — is hovered, so overlapping Buttons do not light up together.
        let hoveredSelfHandling = meters.last { $0.handlesMouseItself && $0.isHit(x: x, y: y, precise: true) }
        for m in meters where m.handlesMouseItself {
            m.mouseHover(inside: m === hoveredSelfHandling, x: x, y: y)
        }
        var now: Set<String> = []
        for m in meters where (m.effectiveMouseAction(.over) != nil || m.effectiveMouseAction(.leave) != nil)
            && m.isHit(x: x, y: y) {
            now.insert(m.name.lowercased())
        }
        for key in now.subtracting(hoveredMeters) {
            if let m = meterIndex[key], let a = m.effectiveMouseAction(.over), !a.isEmpty {
                withMouse(x: x, y: y, in: m.frame) { execute(a, from: m) }
            }
        }
        for key in hoveredMeters.subtracting(now) {
            if let m = meterIndex[key], let a = m.effectiveMouseAction(.leave), !a.isEmpty {
                withMouse(x: x, y: y, in: m.frame) { execute(a, from: m) }
            }
        }
        hoveredMeters = now
    }

    /// Mouse input for the measures that follow the mouse themselves (`Plugin=Mouse`, whose actions are "not limited
    /// to a meter"). The host reports every press, release, wheel notch and pointer movement its skin window gets,
    /// in skin coordinates — also the drags and the release of a press that started on the skin while the pointer is
    /// outside the window — *before* it hands the event to the meters (`mouseEvent`, `mouseMoved`). Presses that
    /// the manual's CTRL override takes out of the skin's hands (⌘ on the Mac) and Control-clicks (the Mac's right
    /// click, which opens the skin menu) are not reported.
    ///
    /// The skin keeps the buttons pressed on it: a drag counts only for those (a press that started elsewhere is not
    /// a drag of this skin), a release only for them, and a move without buttons first releases the buttons whose
    /// release never arrived (a menu or another window took it). It also turns the pointer crossing the skin's
    /// border into enter / leave. Nothing happens when the skin has no such measure.
    public func pointerEvent(_ event: PointerEvent, x: Double, y: Double) {
        assertOwned()
        guard !closed, !pointerObservers.isEmpty else { return }
        environmentValid = false
        switch event {
        case .pressed(let button, let doubleClick):
            if !pointerInside {
                pointerInside = true
                notifyPointer(.enter, x: x, y: y)
                if closed { return }
            }
            pointerButtons.insert(button)
            notifyPointer(.down(button, doubleClick: doubleClick), x: x, y: y)
        case .released(let button):
            guard pointerButtons.remove(button) != nil else { return }
            notifyPointer(.up(button), x: x, y: y)
        case .moved:
            for button in MouseButton.allCases where pointerButtons.contains(button) {
                pointerButtons.remove(button)
                notifyPointer(.up(button), x: x, y: y)
                if closed { return }
            }
            pointerMoved(x: x, y: y)
        case .dragged:
            pointerMoved(x: x, y: y)
        case .scrolled(let kind):
            notifyPointer(.scroll(kind), x: x, y: y)
        case .exited:
            // During a press the drag positions tell where the pointer is.
            guard pointerButtons.isEmpty, pointerInside else { return }
            pointerInside = false
            notifyPointer(.leave, x: x, y: y)
        }
    }

    private func pointerMoved(x: Double, y: Double) {
        let inside = x >= 0 && y >= 0 && x < width && y < height
        if inside != pointerInside {
            pointerInside = inside
            notifyPointer(inside ? .enter : .leave, x: x, y: y)
            if closed { return }
        }
        notifyPointer(.move(dragging: MouseButton.allCases.filter { pointerButtons.contains($0) }), x: x, y: y)
    }

    private func notifyPointer(_ input: PointerInput, x: Double, y: Double) {
        for observer in pointerObservers {
            observer.pointerInput(input, x: x, y: y)
            if closed { return }
        }
    }

    /// Mouse input made outside the skin window — in other apps, on the desktop, in Deskset's other windows (another
    /// skin, the editor, the Manage window) — for the measures that follow the mouse anywhere on the screen
    /// (`Plugin=Slider`), in skin coordinates (so mostly outside 0…width × 0…height). The host reports only what
    /// `outsidePointerNeeds` asks for, and never an event its skin window got itself (that goes to `pointerEvent`).
    ///
    /// Like `pointerEvent`, the skin keeps the buttons pressed outside: a release counts only for those (a press made
    /// before the host watched, or on the skin, is not one), a drag drags only those, and a move without buttons first
    /// releases the ones whose release never arrived. A move without buttons over the skin is dropped while the skin
    /// window reports the pointer over itself (it last reported the pointer inside, `pointerEvent`, and still gets the
    /// mouse, `SkinHost.skinWindowTakesPointer`), so a move is not seen twice; over a hidden or click-through skin it
    /// counts. No wheel, no enter / leave, no double clicks: version 2 of the plugin has none.
    public func outsidePointerEvent(_ event: PointerEvent, x: Double, y: Double) {
        assertOwned()
        guard !closed, !outsidePointerNeeds.isEmpty else { return }
        let needs = outsidePointerNeeds
        switch event {
        case .pressed(let button, _):
            guard needs.buttons.contains(button) else { return }
            environmentValid = false
            // A new press of a button still held here: its release never arrived.
            if outsideButtons.contains(button) {
                notifyOutside(.up(button), x: x, y: y)
                if closed { return }
            }
            outsideButtons.insert(button)
            notifyOutside(.down(button, doubleClick: false), x: x, y: y)
        case .released(let button):
            guard outsideButtons.remove(button) != nil else { return }
            environmentValid = false
            notifyOutside(.up(button), x: x, y: y)
        case .dragged:
            guard needs.wantsDrag(pressed: outsideButtons) else { return }
            environmentValid = false
            notifyOutside(.move(dragging: MouseButton.allCases.filter { outsideButtons.contains($0) }), x: x, y: y)
        case .moved:
            environmentValid = false
            for button in MouseButton.allCases where outsideButtons.contains(button) {
                outsideButtons.remove(button)
                notifyOutside(.up(button), x: x, y: y)
                if closed { return }
            }
            guard outsidePointerNeeds.moves else { return }
            // Over the skin, the skin window reports the move itself — unless it is hidden or lets the mouse through
            // now (`pointerInside` is what the window said last, and a hidden window says nothing more).
            let overSkin = pointerInside && x >= 0 && y >= 0 && x < width && y < height
            if overSkin && (host?.skinWindowTakesPointer(self) ?? false) { return }
            notifyOutside(.move(dragging: []), x: x, y: y)
        case .scrolled, .exited:
            return
        }
    }

    private func notifyOutside(_ input: PointerInput, x: Double, y: Double) {
        for observer in outsideObservers {
            observer.pointerInput(input, x: x, y: y)
            if closed { return }
        }
    }

    /// Recomputes `outsidePointerNeeds` (after every update, every top-level action and when the skin closes) and tells
    /// the host when it changed. Buttons nobody wants any more are forgotten, so a release the host no longer watches
    /// for is never reported late.
    private func refreshOutsidePointerNeeds() {
        guard !outsideObservers.isEmpty || !outsidePointerNeeds.isEmpty else { return }
        var needs = OutsidePointerNeeds()
        // Not before the load-time read of the options is done (a script's Initialize may run bangs during it).
        if !closed && optionsLoaded {
            for observer in outsideObservers { needs.formUnion(observer.outsidePointerNeeds()) }
        }
        outsideButtons.formIntersection(needs.buttons)
        guard needs != outsidePointerNeeds else { return }
        outsidePointerNeeds = needs
        host?.skinOutsidePointerNeedsChanged(self)
    }

    public func mouseExited() {
        assertOwned()
        environmentValid = false
        for m in meters where m.handlesMouseItself { m.mouseHover(inside: false, x: -1, y: -1) }
        for key in hoveredMeters {
            if let m = meterIndex[key], let a = m.effectiveMouseAction(.leave), !a.isEmpty { execute(a, from: m) }
        }
        hoveredMeters = []
        if mouseInside {
            mouseInside = false
            if let root = rainmeterSection, let a = root.effectiveMouseAction(.leave), !a.isEmpty {
                execute(a, from: root)
            }
        }
    }

    /// Tooltip for the topmost meter under the point.
    public func toolTip(at x: Double, _ y: Double) -> (title: String, text: String)? {
        toolTipInfo(at: x, y).map { ($0.title, $0.text) }
    }

    /// Tooltip (with icon, type and width) for the topmost meter under the point that has one; nil when the skin
    /// sets `ToolTipHidden=1` in `[Rainmeter]`.
    public func toolTipInfo(at x: Double, _ y: Double) -> ToolTipInfo? {
        assertOwned()
        guard !settings.toolTipHidden else { return nil }
        for m in meters.reversed() where m.isHit(x: x, y: y) {
            if let info = m.toolTipInfo { return info }
        }
        return nil
    }

    /// Cursor to show at the point: nil for the normal arrow, otherwise `MouseActionCursorName` or `"HAND"`.
    /// Manual (Mouse Actions → MouseActionCursor): a pointer is shown over a meter with a mouse action unless the
    /// topmost meter there sets `MouseActionCursor=0`. A disabled action is "detected, but cause[s] no change to the
    /// cursor" and blocks the meters behind it, like an empty action `[]`; a cleared action lets them through.
    /// Judgment: hover actions (MouseOver/MouseLeave) do not count.
    public func mouseCursorName(at x: Double, _ y: Double) -> String? {
        assertOwned()
        enum Target { case pointer, blocked, none }
        func target(_ action: (MouseEventKind) -> String?) -> Target {
            var blocked = false
            for kind in MouseEventKind.allCases where kind != .over && kind != .leave {
                guard let a = action(kind) else { continue }
                if Skin.isEmptyAction(a) { blocked = true } else { return .pointer }
            }
            return blocked ? .blocked : .none
        }
        for m in meters.reversed() where m.isHit(x: x, y: y) {
            if !m.mouseActionCursor { return nil }
            switch target(m.effectiveMouseAction) {
            case .pointer: return m.mouseActionCursorName.isEmpty ? "HAND" : m.mouseActionCursorName
            case .blocked: return nil
            case .none: continue
            }
        }
        if let root = rainmeterSection, settings.mouseActionCursor, target(root.effectiveMouseAction) == .pointer {
            return settings.mouseActionCursorName.isEmpty ? "HAND" : settings.mouseActionCursorName
        }
        return nil
    }

    /// `""` (a disabled action) or only brackets and blanks, like `[]` or `[ ][]`: detected but does nothing.
    static func isEmptyAction(_ action: String) -> Bool {
        action.utf8.allSatisfy { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "]") || $0 == 0x20 || $0 == 0x09 }
    }

    // MARK: Logging & issues

    public func log(_ message: String, level: SkinLogLevel) {
        host?.skin(self, log: message, level: level)
    }

    /// Logs a message only the first time (for problems re-detected on every update, e.g. by dynamic sections).
    public func logOnce(_ message: String, level: SkinLogLevel) {
        // Messages may contain dynamic text (a MeasureName that changes on every update): keep the set bounded.
        guard loggedOnce.count < Skin.maxDistinctMessages else { return }
        if loggedOnce.insert(message).inserted { log(message, level: level) }
    }

    public func addIssue(_ issue: String) {
        guard issueSet.count < Skin.maxDistinctMessages else { return }
        if issueSet.insert(issue).inserted { issues.append(issue) }
    }

    /// Takes back a compatibility note that no longer applies — a transient one, such as a macOS permission the user
    /// granted after the note was added. Does nothing when the skin does not have that note; adding it again later
    /// works as for a new note.
    public func removeIssue(_ issue: String) {
        guard issueSet.remove(issue) != nil else { return }
        issues.removeAll { $0 == issue }
    }
}

extension Double {
    /// Clamps into `lo…hi` (NaN → `lo`), e.g. before converting to Int.
    func clamped(_ lo: Double, _ hi: Double) -> Double {
        isNaN ? lo : Swift.min(Swift.max(self, lo), hi)
    }
}

extension Skin {
    /// Registers the measure types that live outside Engine/ (Lua, bundled plugins) once per process.
    /// App-side plugins register themselves at app start.
    static func registerBuiltInExtensions() {
        _ = registerOnce
    }

    private static let registerOnce: Void = {
        LuaSupport.register()
        CorePlugins.register()
    }()
}

/// What `Skin.pointerEvent` passes on to the measures that follow the mouse themselves.
enum PointerInput: Equatable {
    case down(MouseButton, doubleClick: Bool)
    /// The release of a press made on the skin.
    case up(MouseButton)
    /// The pointer moved; `dragging`: the buttons pressed on the skin and still held, left to X2.
    case move(dragging: [MouseButton])
    case scroll(MouseEventKind)
    /// The pointer came over the skin / left it.
    case enter
    case leave
}

/// A measure that receives its skin's mouse input itself (`Plugin=Mouse`), in skin coordinates.
protocol SkinPointerObserver: AnyObject {
    func pointerInput(_ input: PointerInput, x: Double, y: Double)
}

/// A measure that also receives the mouse input made outside its skin window (`Plugin=Slider`), through the same
/// `pointerInput` (see `Skin.outsidePointerEvent`).
protocol SkinOutsidePointerObserver: SkinPointerObserver {
    /// What it wants from outside the skin window now: nothing while it is disabled, paused or closed, or has no
    /// action that such input could run.
    func outsidePointerNeeds() -> OutsidePointerNeeds
}
