import Foundation
@testable import DesksetCore

/// Where shared values are used (`Skin.valueUsages()`, docs/editor-friendly.md §8.1.1) and the widget page's presets
/// (update speed, stacking). Suites: "Editor: value usages …", "Editor: widget presets …" (WP-B).
func runValueUsagesTests(_ t: TestRunner) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    func load(_ folder: String, _ config: String) throws -> Skin {
        let skins = repo.appendingPathComponent(folder)
        let parts = config.split(separator: "\\").map(String.init)
        let skin = Skin(config: config, fileURL: skins.appendingPathComponent(parts.joined(separator: "/"))
                            .appendingPathComponent("\(parts.last ?? "").ini"),
                        skinsDirectory: skins, system: FakeSystem(), host: FakeHost())
        try skin.load()
        skin.update()
        return skin
    }

    t.suite("Editor: value usages — Visualizer's shared colors and sizes") {
        let skin = try load("TestSkins", "Audio\\Visualizer")
        let index = skin.valueUsages()
        func value(_ name: String) -> ValueUsageIndex.Value? { index.variable(name) }
        t.equal(value("Accent")?.sections.count, 18, "16 bands and 2 level bars")
        t.equal(value("Accent")?.role, "Bar color")
        t.equal(value("Accent")?.kind, .color)
        t.equal(value("Track")?.sections.count, 18)
        t.equal(value("Track")?.role, "Empty part of bars")
        t.equal(value("Subtle")?.sections.count, 5, "the texts using StyleSmall")
        t.equal(value("Subtle")?.role, "Small text")
        t.equal(value("Text")?.sections, ["MeterTitle"])
        t.equal(value("Text")?.role, "Title text")
        // A look's option counts for its users, never for the look; Band0's own X hides StyleBand's.
        t.equal(value("BarW")?.sections.count, 16)
        t.equal(value("BarGap")?.sections.count, 15)
        t.check(value("BarGap")?.sections.contains("MeterBand0") == false, "Band0 writes its own X")
        t.equal(value("BarH")?.sections.count, 17, "16 bars and the low frequency label's Y")
        t.check(value("BarH")?.sections.contains("MeterLowFreq") == true)
        t.equal(value("Left")?.sections.count, 10, "9 layers and the peak marker's formula")
        t.check(value("Left")?.sections.contains("MeasurePeakX") == true, "formulas count")
        t.equal(value("Width")?.sections.count, 6)
        t.check(value("Width")?.sections.contains("MeterBackground") == true, "a Shape string counts")
        t.equal(value("Width")?.isCalculated, true)
        t.equal(value("BarW")?.isCalculated, false)
        t.equal(value("BarW")?.kind, .size)
        t.equal(value("Width")?.kind, .size)
        t.equal(value("Accent")?.origin, .own)
        t.equal(value("BarW")?.uses.first { $0.section == "MeterBand5" }?.look, "StyleBand", "W comes from the look")
        t.equal(value("BarGap")?.uses.first { $0.section == "MeterBand5" }?.look, nil, "every band writes its own X")
        t.equal(index.sharedSizes().compactMap(\.variableName), ["BarW", "BarGap", "BarH", "Left", "Width"])
        // What a change reaches: the peak marker is placed by the formula that uses Left (X=[MeasurePeakX]).
        let reached = index.reach(value("Left")?.sections ?? []).filter { skin.meter(named: $0) != nil }
        t.equal(reached.count, 10, "9 layers using Left and the peak marker placed through its formula: \(reached)")
        t.check(reached.contains("MeterPeak"))
        t.equal(index.followers["measurepeakx"], ["MeterPeak"], "X=[MeasurePeakX]")
        t.check(index.followers["measurepeak"]?.contains("MeasurePeakX") == true, "a formula naming it")
        t.check(index.followers["measureband5"]?.contains("MeterBand5") == true, "MeasureName")
        t.equal(index.reach(["MeterTitle"]), ["MeterTitle"], "a layer alone reaches itself")

        // Literal colors, grouped by value.
        let panel = index.literal(RGBA(r: 16, g: 19, b: 28, a: 235))
        t.equal(panel?.sections, ["MeterBackground"])
        t.equal(panel?.role, "Background panel")
        let peak = index.literal(RGBA(r: 255, g: 255, b: 255, a: 200))
        t.equal(peak?.sections, ["MeterPeak"])
        if let meter = skin.meter(named: "MeterPeak") {
            t.equal(peak?.role, LayerNaming.layer(meter, in: skin).title, "a color block is named after the layer")
        }
        t.check(peak?.role.hasPrefix("Peak") == true, "\(peak?.role ?? "")")

        // The widget page's rows: six colors, most used first.
        let groups = index.colorGroups()
        t.equal(groups.map(\.role), ["Bar color", "Empty part of bars", "Small text", "Title text", "Background panel",
                                     peak?.role ?? ""])
        t.equal(groups.map(\.sections.count), [18, 18, 5, 1, 1, 1])
        t.equal(skin.detectedBackgroundLayer(), "MeterBackground")
    }

    t.suite("Editor: value usages — System's theme colors come from a shared include") {
        let skin = try load("DefaultSkins", "Deskset\\System")
        let index = skin.valueUsages()
        let groups = index.colorGroups()
        guard let blue = groups.first(where: { $0.variables.contains("CPUColor") }) else {
            return t.check(false, "a group for CPUColor")
        }
        t.equal(Set(blue.variables), ["CPUColor", "DownColor", "AccentColor"], "same value, one row")
        t.equal(blue.sharedFile?.lastPathComponent, "Dark.inc")
        t.equal(blue.role, "CPU graph line and 1 more", "what is drawn before what pointing does")
        t.check(blue.roles.contains { $0.name == "Title text when pointed at" }, "a bang argument of a look counts: \(blue.roles)")
        t.equal(index.variable("AccentColor")?.sections, ["MeterTitle"], "through StyleLink's MouseOverAction")
        t.equal(index.variable("DownColor")?.sections, [], "Network's color, same value")
        // Separately, each is its own row (the unused one has none).
        let apart = index.colorGroups(separate: ["cpucolor", "downcolor", "accentcolor"])
        t.check(apart.contains { $0.variables == ["CPUColor"] } && apart.contains { $0.variables == ["AccentColor"] })
        t.check(!apart.contains { $0.variables.contains("DownColor") })
        // Through other variables: ContentWidth names PanelWidth and Padding; PanelBorderNow names PanelBorder.
        t.check(index.variable("PanelWidth")?.uses.contains { $0.section == "MeterCPUGraph" && $0.via == "ContentWidth" } == true)
        t.check(index.variable("PanelBorder")?.sections.contains("MeterBackground") == true)
        t.equal(index.variable("ContentWidth")?.isCalculated, true)
        t.equal(index.variable("PanelBorderNow")?.isCalculated, true, "a variable naming another is not a color row")
        t.check(!groups.contains { $0.variables.contains("PanelBorderNow") })
        t.equal(index.variable("ThemeMenuAction")?.isInternal, true)
        t.equal(index.variable("Theme")?.isInternal, true)
        t.equal(index.variable("FontFace")?.kind, .font)
        t.equal(index.variable("PanelHeight")?.origin, .own)
        t.check(index.colorsOtherWidgetsUse().contains { $0.variableName == "BatteryColor" })
        t.check(!index.colorsOtherWidgetsUse().contains { $0.variableName == "DownColor" },
                "a same-value color is changed with its row, not listed apart")
        // The gradient stops of the memory bar.
        t.equal(index.variable("MemoryColor")?.sections, ["MeterRAMBar"])
        // Roles inside Shapes: the panel's fade and its outline (through PanelBorderNow).
        t.equal(index.variable("PanelTop")?.roles.first?.name, "Background panel (top)", "a fade from top to bottom")
        t.equal(index.variable("PanelBottom")?.roles.first?.name, "Background panel (bottom)")
        t.equal(index.variable("PanelBorder")?.roles.first?.name, "Background panel outline")
        t.equal(index.variable("TextColor")?.role, "Main text", "StyleText's color")
        // Who shares the theme: every Deskset widget reads Dark.inc through Variables.inc.
        if let dark = blue.sharedFile {
            let configs = skin.configsIncluding(dark)
            t.check(configs.contains("deskset\\system") && configs.contains("deskset\\network"), "\(configs)")
            t.equal(configs.count, 6, "one per config, variants counted once: \(configs)")
            // A theme: the file a variable chooses (@IncludeTheme=#@#Themes/#Theme#.inc); Variables.inc is always read.
            t.equal(skin.switchedInclude(dark), Skin.SwitchedInclude(variable: "Theme", name: "Dark", others: ["Light"]))
        }
        t.equal(skin.switchedInclude(skin.resourcesDirectory.appendingPathComponent("Variables.inc")), nil)
        t.equal(skin.switchedInclude(skin.resourcesDirectory.appendingPathComponent("Styles.inc")), nil,
                "next to Variables.inc, but no variable chooses it")
    }

    t.suite("Editor: widget presets — what doesn't work on a Mac, in plain words") {
        let skin = try load("TestSkins", "App\\Unsupported")
        let names = ["measureplugin": "Weather", "measureregistry": "Windows version", "measurescript": "Counter"]
        let plain = { (issue: String) in WidgetPresets.plainIssue(issue, in: skin, name: { names[$0.lowercased()] ?? $0 }) }
        t.check(skin.issues.count >= 3, "\(skin.issues)")
        for issue in skin.issues {
            let words = plain(issue)
            t.check(!WidgetPresets.isEngineText(words), "“\(words)” (from “\(issue)”)")
        }
        t.equal(plain(#"Plugin "ExampleWindowsPlugin.dll" is a Windows plugin and is not supported"#),
                "“Weather” uses a Windows add-on (ExampleWindowsPlugin.dll), so it stays empty on a Mac.")
        t.equal(plain("Registry value HKCU\\Software\\Example\\Value does not exist on macOS (only a few Windows version / "
                      + "hardware values are emulated)"),
                "“Windows version” reads a Windows setting, so it stays empty on a Mac.")
        t.equal(plain("Script file App/@Resources/Example.lua of [MeasureScript] not found"),
                "“Counter” runs a script file that is missing (Example.lua).")
        t.equal(plain("Measure=Registry is Windows-only and is not supported"),
                "“Windows version” reads something only Windows has (Registry), so it stays empty on a Mac.")
        t.equal(plain("Plugin=Nothing.dll is not supported yet"), "An add-on Deskset can't run yet (Nothing.dll) stays empty.",
                "nobody uses it: said in general")
        // Notes already written for people keep their words, without the add-on's prefix and option names.
        t.equal(plain("NowPlaying: PlayerName=Foobar has no Mac version; the skin shows Music (or Spotify while it plays) instead."),
                "Foobar has no Mac version; the widget shows Music (or Spotify while it plays) instead.")
        t.equal(plain("WiFiStatus: macOS shows Wi-Fi network names only to apps allowed to use Location Services."),
                "macOS shows Wi-Fi network names only to apps allowed to use Location Services.")
        t.equal(plain("[MeasureX] Formula=#A# is odd"), "Part of this widget doesn't work on a Mac.", "still technical")

        let (other, _) = try makeSkin(t, """
            [Rainmeter]
            [MeterA]
            Meter=String
            Text=A
            LeftMouseUpAction=[!SetWallpaper "x.png"]
            [MeterB]
            Meter=Histogram
            """)
        let words = { (issue: String) in WidgetPresets.plainIssue(issue, in: other, name: { $0 == "MeterA" ? "“A”" : "Bars" }) }
        t.equal(words("Bang !SetWallpaper is not supported"), "“A” has an action that does nothing on a Mac (SetWallpaper).")
        t.equal(words("Histogram ImageRotate is not supported"), "“Bars” uses picture rotation or color adjustment, which Deskset ignores.")
        t.check(WidgetPresets.isEngineText("Uses #Accent#") && WidgetPresets.isEngineText("a meter")
                && WidgetPresets.isEngineText("120,200,255,255") && !WidgetPresets.isEngineText("Fades in 0.25 seconds"))
    }

    t.suite("Editor: value usages — nested names, literals in shapes and inline settings") {
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            [Variables]
            Color1=255,0,0
            Color2=0,255,0
            Index=1
            Size=10
            Gap=(#Size# * 2)
            [MeterA]
            Meter=String
            Text=A
            FontColor=[#Color[#Index]]
            DynamicVariables=1
            [MeterB]
            Meter=String
            Text=B
            X=[#Gap]
            FontColor=10,20,30
            InlineSetting=Color | 10,20,30
            [MeterC]
            Meter=Shape
            Shape=Rectangle 0,0,10,10 | Fill Color 0A141E | Stroke Color 10,20,30,255
            """)
        let index = skin.valueUsages()
        t.equal(index.variable("Color1")?.isAtLeast, true, "a name built at run time could be Color1")
        t.equal(index.variable("Color2")?.isAtLeast, true)
        t.equal(index.variable("Size")?.isAtLeast, false)
        t.equal(index.variable("Gap")?.sections, ["MeterB"], "[#Gap] names Gap")
        t.equal(index.variable("Size")?.uses, [ValueUsageIndex.Use(section: "MeterB", key: "X", via: "Gap")])
        let literal = index.literal(RGBA(r: 10, g: 20, b: 30))
        t.equal(literal?.sections, ["MeterB", "MeterC"], "hex and decimal, font, inline and shape: one value")
        t.equal(literal?.uses.count, 3)
    }

    t.suite("Editor: value usages — rewriting a literal color keeps everything else") {
        let old = RGBA(r: 16, g: 19, b: 28, a: 235), new = RGBA(r: 1, g: 2, b: 3, a: 235)
        let replace = ValueUsageIndex.replacingColor
        t.equal(replace(old, new, "Rectangle 0,0,#Width#,196,10 | Fill Color 16,19,28,235 | StrokeWidth 0", "Shape"),
                "Rectangle 0,0,#Width#,196,10 | Fill Color 1,2,3,235 | StrokeWidth 0")
        t.equal(replace(old, new, "16,19,28,235", "SolidColor"), "1,2,3,235")
        t.equal(replace(old, new, "10131CEB", "FontColor"), "010203EB", "hex stays hex")
        t.equal(replace(old, new, "180 | 16,19,28,235 ; 0.0 | 9,9,9 ; 1.0", "PanelFill"), "180 | 1,2,3,235 ; 0.0 | 9,9,9 ; 1.0")
        t.equal(replace(old, new, "Color | 16,19,28,235", "InlineSetting2"), "Color | 1,2,3,235")
        t.equal(replace(old, new, "Rectangle 0,0,10,10 | Fill Color #Panel#", "Shape"), nil)
        t.equal(replace(old, new, "9,9,9", "SolidColor"), nil)
    }

    t.suite("Editor: value usages — a widget's own value is written after its includes") {
        let w = { (text: String) throws -> String in
            try IniWriter.writingAfterIncludes(text, value: "1,2,3", key: "CPUColor", section: "Variables")
        }
        t.equal(try w("[Variables]\n@Include=a.inc\n@Include2=b.inc\nPanelHeight=196\n\n[M]\nMeter=String\n"),
                "[Variables]\n@Include=a.inc\n@Include2=b.inc\nPanelHeight=196\nCPUColor=1,2,3\n\n[M]\nMeter=String\n")
        t.equal(try w("[Variables]\nCPUColor=9,9,9\n@Include=a.inc\nX=1\n"), "[Variables]\n@Include=a.inc\nX=1\nCPUColor=1,2,3\n",
                "a key before the include is moved after it")
        t.equal(try w("[Variables]\n@Include=a.inc\nCPUColor=9,9,9\nX=1\n"), "[Variables]\n@Include=a.inc\nCPUColor=1,2,3\nX=1\n",
                "after the include: updated in place")
        t.equal(try w("[Rainmeter]\n"), "[Rainmeter]\n\n[Variables]\nCPUColor=1,2,3\n", "no [Variables]: added")
    }

    t.suite("Editor: value usages — names in words") {
        t.equal(ValueUsageIndex.humanizedVariable("BarW"), "Bar width")
        t.equal(ValueUsageIndex.humanizedVariable("BarH"), "Bar height")
        t.equal(ValueUsageIndex.humanizedVariable("BarGap"), "Bar gap")
        t.equal(ValueUsageIndex.humanizedVariable("PanelHeight"), "Panel height")
        t.equal(ValueUsageIndex.humanizedVariable("CPUColor"), "CPU color")
        t.equal(ValueUsageIndex.humanizedLook("StyleSmall"), "Small")
        t.equal(ValueUsageIndex.humanizedLook("StyleValueRight"), "Value right")
        t.equal(ValueUsageIndex.humanizedLook("Stylish"), "Stylish")
    }

    t.suite("Editor: widget presets — update speed") {
        let W = WidgetPresets.self
        t.equal(W.updateTitle(for: 25), "Real-time — 40 times a second")
        t.equal(W.updateTitle(for: 1000), "Every second (standard)")
        t.equal(W.updateTitle(for: 250), "Custom — 4 times a second")
        t.equal(W.updateTitle(for: 2500), "Custom — every 2.5 seconds")
        t.equal(W.updateTitle(for: -1), "Only when it opens")
        t.equal(W.updateTitle(for: -5), "Only when it opens", "any negative value updates once")
        t.equal(W.updateTitle(for: 10), "Custom — 62.5 times a second", "the engine's minimum is 16 ms")
        t.equal(W.updateCaption(for: 25), "Smoothest animation. Uses the most battery.")
        t.equal(W.updateCaption(for: 250), "Smooth. Good for moving bars and graphs.", "the nearest preset's")
        t.equal(W.updateCaption(for: 2500), "Saves battery. Clocks with seconds will skip.", "nearer 5 s than 1 s")
        t.equal(W.updateCaption(for: 1500), "Right for clocks and system stats.")
        t.equal(W.updateWarnings(for: 25, showsSound: true, showsSeconds: false), [])
        t.equal(W.updateWarnings(for: 200, showsSound: true, showsSeconds: false), ["The sound bars will move in jumps."])
        t.equal(W.updateWarnings(for: 1000, showsSound: false, showsSeconds: true), [])
        t.equal(W.updateWarnings(for: 2000, showsSound: false, showsSeconds: true), ["The seconds will skip."])
        t.equal(W.milliseconds(fromSeconds: 0.25), 250)
        t.equal(W.milliseconds(fromSeconds: 0.001), 16)
        t.check(W.formatShowsSeconds("%H:%M:%S") && W.formatShowsSeconds("%#S") && !W.formatShowsSeconds("%H:%M"))
        for p in W.updateSpeeds { t.check(!p.title.contains("ms") && !p.caption.contains("ms"), p.title) }
    }

    t.suite("Editor: widget presets — stacking and the rest") {
        let W = WidgetPresets.self
        t.equal(W.stackingControl(for: -2), .segments)
        t.equal(W.stackingControl(for: 0), .segments)
        t.equal(W.stackingControl(for: 1), .segments)
        t.equal(W.stackingControl(for: -1), .popup, "an in-between level keeps its value in the pop-up")
        t.equal(W.stackingControl(for: 2), .popup)
        t.equal(W.stackingAll.count, 5)
        t.equal(W.stackingCaption(for: -2), "Sits on the desktop, behind all windows.")
        t.equal(W.stackingCaption(for: 1), "Stays in front of every window.")
        t.equal(W.stackingName(for: 1), "Always on Top")
        t.equal(W.redrawTitle(for: 1), "Every update")
        t.equal(W.redrawTitle(for: 3), "Every 3rd update")
        t.equal(W.redrawTitle(for: -1), "Only once")
        t.equal(W.transitionTitle(for: 100), "10 frames a second")
        t.equal(W.transitionTitle(for: 40), "25 frames a second")
        t.equal(W.fadeSeconds(250), "0.25")
        t.equal(W.ordinal(2), "2nd")
        t.equal(W.ordinal(11), "11th")
        t.equal(W.ordinal(23), "23rd")
    }
}
