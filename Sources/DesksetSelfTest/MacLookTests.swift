import Foundation
@testable import DesksetCore

// The Mac look extensions (docs/compat/engine.md): SF Symbols as images (`sf:`), the appearance variables and
// MacOnAppearanceChangeAction. Fonts and the drawing are checked in the app's self-tests.

/// A host that knows a few symbols (by name, at 1 point per `MacSymbolSize` point, 20 × 18 like cpu.fill at 16) and
/// reports an appearance of the test's choosing.
private final class MacLookHost: FakeHost {
    var appearance = SkinAppearance.light
    var knownSymbols: Set<String> = ["cpu.fill", "power", "battery.100percent"]
    var symbolQueries: [String] = []

    override func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        guard let symbol = MacSymbol(path: path) else { return super.imageSize(atPath: path) }
        symbolQueries.append(path)
        guard knownSymbols.contains(symbol.name) else { return nil }
        let scale = symbol.style.pointSize / 16
        return (20 * scale, 18 * scale)
    }

    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(appearance: appearance)
    }
}

func runMacLookTests(_ t: TestRunner) {
    t.suite("Mac look: sf: names and symbol paths") {
        t.equal(MacSymbol.symbolName(in: "sf:cpu.fill"), "cpu.fill")
        t.equal(MacSymbol.symbolName(in: "  SF:cpu.fill "), "cpu.fill", "any case, spaces around")
        t.equal(MacSymbol.symbolName(in: "\"sf: wifi\""), "wifi", "quoted, a space after the prefix")
        t.equal(MacSymbol.symbolName(in: "sf:"), "", "the empty symbol")
        t.equal(MacSymbol.symbolName(in: "cpu.fill"), nil)
        t.equal(MacSymbol.symbolName(in: "sfx.png"), nil)
        t.equal(MacSymbol.symbolName(in: "#@#sf:cpu.png"), nil, "only at the start")
        t.check(!MacSymbol.isSymbolName("Images\\sf.png"))

        let symbol = MacSymbol(name: "cpu.fill")
        t.equal(symbol.path, "sf:cpu.fill?size=16&weight=regular&rendering=monochrome")
        t.check(MacSymbol.isSymbolPath(symbol.path))
        t.check(!MacSymbol.isSymbolPath("/Volumes/Data/sf:cpu.png"), "a file path is never a symbol path")
        t.equal(MacSymbol(path: symbol.path), symbol, "round trip")
        let styled = MacSymbol(name: "gauge.with.needle",
                               style: MacSymbol.Style(pointSize: 22.5, weight: .semibold, rendering: .hierarchical),
                               density: 2.125)
        t.equal(styled.path, "sf:gauge.with.needle?size=22.5&weight=semibold&rendering=hierarchical&density=2.125")
        t.equal(MacSymbol(path: styled.path), styled)
        t.equal(styled.measuringPath, "sf:gauge.with.needle?size=22.5&weight=semibold&rendering=hierarchical")
        t.equal(styled.withDensity(1), MacSymbol(path: styled.measuringPath))
        // A name cannot reach into the options.
        let odd = MacSymbol(name: "a?size=99&weight=black")
        t.equal(MacSymbol(path: odd.path)?.name, "a?size=99&weight=black")
        t.equal(MacSymbol(path: odd.path)?.style, MacSymbol.Style())
        t.equal(MacSymbol(path: "/tmp/x.png"), nil)
        // Limits.
        t.equal(MacSymbol(name: "a", density: 1000).density, MacSymbol.maxDensity)
        t.equal(MacSymbol(name: "a", density: .nan).density, 1)
        t.equal(MacSymbol.Style(pointSize: -3).pointSize, MacSymbol.defaultPointSize)
        t.equal(MacSymbol.Style(pointSize: 1e9).pointSize, MacSymbol.maxPointSize)
        t.equal(MacSymbol(path: "sf:a?size=abc&weight=nope&rendering=Multicolor")?.style,
                MacSymbol.Style(pointSize: 16, weight: .regular, rendering: .multicolor))
        t.equal(MacSymbol.Weight(parsing: " SEMIBOLD "), .semibold)
        t.equal(MacSymbol.Weight(parsing: "700"), .regular, "names only")
        t.equal(MacSymbol.Weight.ultralight.optionValue, "Ultralight")
        t.equal(MacSymbol.Rendering(parsing: "hierarchical"), .hierarchical)
        t.equal(MacSymbol.Rendering(parsing: ""), .monochrome)
    }

    t.suite("Mac look: SF Symbols in Image, Button and Bar meters and the background") {
        let host = MacLookHost()
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Background=sf:power
        BackgroundMode=0
        MacSymbolSize=32
        [Variables]
        Size=(16 * 2)
        [MeasureName]
        Measure=String
        String=sf:battery.100percent
        [Symbol]
        Meter=Image
        ImageName=sf:cpu.fill
        ImagePath=#@#Images
        [Sized]
        Meter=Image
        ImageName=sf:cpu.fill
        W=40
        H=40
        [Stretched]
        Meter=Image
        ImageName=sf:cpu.fill
        W=40
        H=40
        PreserveAspectRatio=0
        [File]
        Meter=Image
        ImageName=Wide100x50.png
        W=40
        H=40
        [Styled]
        Meter=Image
        ImageName=sf:cpu.fill
        MacSymbolSize=#Size#
        MacSymbolWeight=bold
        MacSymbolRendering=Hierarchical
        [FromMeasure]
        Meter=Image
        MeasureName=MeasureName
        [Masked]
        Meter=Image
        ImageName=Wide100x50.png
        MaskImageName=sf:cpu.fill
        MacSymbolWeight=Light
        [Button]
        Meter=Button
        ButtonImage=sf:power
        [Bar]
        Meter=Bar
        BarImage=sf:battery.100percent
        MacSymbolSize=20
        [Meter1]
        Meter=Image
        ImageName=sf:cpu.fill
        """, host: host)
        skin.update()
        func image(_ name: String) -> ImageMeter { skin.meter(named: name) as! ImageMeter }
        t.equal(image("Symbol").imagePath, "sf:cpu.fill?size=16&weight=regular&rendering=monochrome", "ImagePath is ignored")
        t.equal(image("Symbol").frame, SkinRect(x: 0, y: 0, width: 20, height: 18), "natural size at 16 points")
        t.equal(image("Symbol").imageOptions.symbol, MacSymbol.Style())
        t.equal(image("Sized").preserveAspectRatio, 1, "a symbol with W and H keeps its shape by default")
        t.equal(image("Stretched").preserveAspectRatio, 0, "unless the skin says otherwise")
        t.equal(image("File").preserveAspectRatio, 0, "files keep Rainmeter's default")
        t.equal(image("Styled").imagePath, "sf:cpu.fill?size=32&weight=bold&rendering=hierarchical")
        t.equal(image("Styled").frame.width, 40, "MacSymbolSize (a formula) sets the natural size")
        t.equal(image("FromMeasure").imagePath, "sf:battery.100percent?size=16&weight=regular&rendering=monochrome",
                "a measure's value can name a symbol")
        t.equal(image("Masked").maskImagePath, "sf:cpu.fill?size=16&weight=light&rendering=monochrome")
        let button = skin.meter(named: "Button") as! ButtonMeter
        t.check(button.isSymbol)
        t.equal(button.frame.width, 20, "a symbol is one frame, not a strip of three")
        t.equal(button.sourceRect(for: .pressed), button.sourceRect(for: .normal))
        t.equal(button.sourceRect(for: .hover), SkinRect(x: 0, y: 0, width: 20, height: 18))
        let bar = skin.meter(named: "Bar") as! BarMeter
        t.equal(bar.barImagePath, "sf:battery.100percent?size=20&weight=regular&rendering=monochrome")
        t.equal(bar.frame.width, 25, "revealed at its own size")
        t.equal(skin.settings.backgroundImage, "sf:power?size=32&weight=regular&rendering=monochrome")
        t.equal(skin.width, 40, "BackgroundMode=0 draws the symbol at its size")
        t.check(skin.issues.isEmpty, "\(skin.issues)")
        t.check(host.logs.allSatisfy { !$0.contains("Unable to open image") }, "\(host.logs)")
        // The editor names a symbol layer after the symbol.
        let named = LayerNaming.layer(image("Meter1"), in: skin)
        t.check(named.title.hasPrefix("Cpu fill"), named.title)
        t.equal(named.subtitle, "Picture · symbol")
        // Changing the symbol by a bang works as for a file.
        skin.execute("[!SetOption Symbol ImageName sf:power][!SetOption Symbol MacSymbolSize 8]", from: nil)
        skin.update()
        t.equal(image("Symbol").imagePath, "sf:power?size=8&weight=regular&rendering=monochrome")
        t.equal(image("Symbol").frame.width, 10)
    }

    t.suite("Mac look: unknown symbols and meters without symbols are noted once") {
        let host = MacLookHost()
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Background=sf:no.such.background
        BackgroundMode=3
        [Missing]
        Meter=Image
        ImageName=sf:no.such.symbol
        [Empty]
        Meter=Image
        ImageName=sf:
        [Digits]
        Meter=Bitmap
        BitmapImage=sf:number
        [Needle]
        Meter=Rotator
        ImageName=sf:arrow.up
        [Graph]
        Meter=Histogram
        PrimaryImage=sf:chart.bar
        """, host: host)
        for _ in 0..<3 { skin.update() }
        let missing = skin.issues.filter { $0.contains("no.such.symbol") }
        t.equal(missing.count, 1, "\(skin.issues)")
        t.check(missing.first?.contains("[Missing]") == true && missing.first?.contains("SF Symbol") == true)
        t.check(skin.issues.contains { $0.contains("[Rainmeter]") && $0.contains("no.such.background") }, "\(skin.issues)")
        t.check(skin.issues.contains { $0.contains("[Empty]") }, "sf: alone names no symbol")
        t.equal(skin.meter(named: "Missing")?.frame.width, 0, "draws nothing")
        t.equal(host.logs.filter { $0.contains("no.such.symbol") }.count, 1, "logged once")
        t.check(host.logs.allSatisfy { !$0.contains("Unable to open image") }, "no missing-file message for a symbol")
        t.equal((skin.meter(named: "Digits") as? BitmapMeter)?.bitmapImagePath, nil)
        t.equal((skin.meter(named: "Needle") as? RotatorMeter)?.imagePath, nil)
        t.equal((skin.meter(named: "Graph") as? HistogramMeter)?.primaryImage == nil, true)
        for (section, option) in [("Digits", "BitmapImage"), ("Needle", "ImageName"), ("Graph", "PrimaryImage")] {
            t.check(skin.issues.contains { $0.hasPrefix("[\(section)] \(option)=sf:") && $0.contains("Image, Button and Bar") },
                    "\(section): \(skin.issues)")
        }
    }

    t.suite("Mac look: the editor knows the new options") {
        typealias S = EditorSchema
        for (type, key) in [("Image", "ImageName"), ("Bar", "BarImage"), ("Button", "ButtonImage")] {
            let groups = S.meterGroups(type)
            for option in ["MacSymbolSize", "MacSymbolWeight", "MacSymbolRendering"] {
                guard let p = S.property(option, in: groups) else {
                    t.check(false, "\(type): \(option)")
                    continue
                }
                t.check(!S.isVisible(p, in: groups, values: { $0 == key ? "Images\\clock.png" : nil }), "\(type): hidden for a file")
                t.check(S.isVisible(p, in: groups, values: { $0 == key ? "sf:cpu.fill" : nil }), "\(type): shown for a symbol")
            }
        }
        for type in ["Bitmap", "Rotator", "Histogram", "String"] {
            t.equal(S.property("MacSymbolSize", in: S.meterGroups(type)), nil, "\(type) draws no symbols")
        }
        let weights = S.property("MacSymbolWeight", in: S.meterGroups("Image"))?.kind.choices?.map(\.value)
        t.equal(weights, MacSymbol.Weight.allCases.map(\.optionValue))
        t.equal(S.property("MacSymbolRendering", in: S.meterGroups("Image"))?.kind.choices?.map(\.value),
                ["Monochrome", "Hierarchical", "Multicolor"])
        t.equal(S.property("MacSymbolSize", in: S.meterGroups("Image"))?.defaultValue, "16")
        let image = S.meterGroups("Image"), fit = S.property("PreserveAspectRatio", in: image)!
        t.equal(S.defaultValue(of: fit, in: image, values: { $0 == "ImageName" ? "sf:wifi" : nil }), "1",
                "a symbol fits inside by default, as the engine draws it")
        t.equal(S.defaultValue(of: fit, in: image, values: { $0 == "ImageName" ? "wifi.png" : nil }), "0")
        let skin = S.skinGroups
        t.equal(S.property("MacOnAppearanceChangeAction", in: skin)?.kind, .action)
        t.equal(S.property("MacOnAppearanceChangeAction", in: skin)?.defaultValue, Skin.defaultAppearanceChangeAction)
        t.check(S.property("MacSymbolSize", in: skin) != nil, "the background can be a symbol")
        // Every label reads as plain words.
        for key in ["MacSymbolSize", "MacSymbolWeight", "MacSymbolRendering"] {
            let p = S.property(key, in: S.meterGroups("Image"))
            t.equal(S.engineWord(in: (p?.label ?? "") + " " + (p?.help ?? "")), nil, key)
        }
        t.equal(S.engineWord(in: S.property("MacOnAppearanceChangeAction", in: skin)?.label ?? ""), nil)
    }

    t.suite("Mac look: appearance variables") {
        t.check(BuiltInVariables.isBuiltIn("MACDARKMODE"))
        t.check(BuiltInVariables.isBuiltIn("macAccentColor"))
        t.check(BuiltInVariables.isDynamic("MACAPPEARANCE"))
        t.check(!BuiltInVariables.isBuiltIn("MACSOMETHING"))
        t.check(!BuiltInVariables.names.contains("MACDARKMODE"), "the manual's list stays the manual's")
        t.equal(BuiltInVariables.macAppearanceNames.count, 7)
        t.equal(SkinAppearance.format(RGBA(r: 0.4, g: 254.6, b: 300, a: -2)), "0,255,255,0")
        t.equal(SkinAppearance.dark.variableValue("macappearance"), "Dark")
        t.equal(SkinAppearance.light.variableValue("macdarkmode"), "0")
        t.equal(SkinAppearance.light.variableValue("maclabelcolor"), "0,0,0,217")
        t.equal(SkinAppearance.light.variableValue("currentpath"), nil)
        t.equal(Set(SkinAppearance.light.variables.keys), Set(BuiltInVariables.macAppearanceNames.map { $0.lowercased() }))
        t.check(SkinAppearance.mentioned(in: "FontColor=[#MacLabelColor]"))
        t.check(!SkinAppearance.mentioned(in: "#MACHINE#"))

        let host = MacLookHost()
        var dark = SkinAppearance.dark
        dark.accentColor = RGBA(r: 255, g: 45, b: 85, a: 255)
        host.appearance = dark
        let (skin, _) = try makeSkin(t, """
        [Variables]
        @Include=#@#Theme-#MACAPPEARANCE#.inc
        MACDARKMODE=7
        Accent=#MACACCENTCOLOR#
        [Mode]
        Meter=String
        Text=#MACAPPEARANCE# #MACDARKMODE# #Panel#
        [Colors]
        Meter=String
        Text=#Accent# | [#MACSECONDARYLABELCOLOR]
        FontColor=#MACLABELCOLOR#
        """, files: ["Root/@Resources/Theme-Dark.inc": "[Variables]\nPanel=night\n",
                     "Root/@Resources/Theme-Light.inc": "[Variables]\nPanel=day\n"], host: host)
        skin.update()
        t.equal(text(skin, "Mode"), "Dark 1 night", "@Include by appearance; [Variables] cannot override a built-in")
        t.equal(text(skin, "Colors"), "255,45,85,255 | 255,255,255,140")
        t.equal((skin.meter(named: "Colors") as? StringMeter)?.style.color, RGBA(r: 255, g: 255, b: 255, a: 217))
        t.check(skin.usesMacAppearance)
        skin.execute("[!SetVariable MACDARKMODE 5]", from: nil)
        t.equal(skin.variable("MACDARKMODE"), "1", "!SetVariable cannot change it")
        t.equal(skin.variable("macseparatorcolor"), "255,255,255,26")
    }

    t.suite("Mac look: skins that use appearance variables run MacOnAppearanceChangeAction") {
        func load(_ ini: String, files: [String: String] = [:]) throws -> (Skin, MacLookHost) {
            let host = MacLookHost()
            let (skin, _) = try makeSkin(t, ini, files: files, host: host)
            skin.update()
            return (skin, host)
        }
        func refreshes(_ host: FakeHost) -> Int { host.handled.filter { $0.name == "refresh" }.count }

        // Not used: nothing happens.
        let (plain, plainHost) = try load("[M]\nMeter=String\nText=Hello\n")
        t.check(!plain.usesMacAppearance)
        plain.appearanceDidChange()
        t.equal(refreshes(plainHost), 0, "a skin without appearance variables is left alone")
        t.equal(plain.settings.macOnAppearanceChangeAction, "[!Refresh]")

        // Used in an option: refreshed by default.
        let (used, usedHost) = try load("[M]\nMeter=String\nFontColor=#MACLABELCOLOR#\nText=Hi\n")
        t.check(used.usesMacAppearance)
        used.appearanceDidChange()
        t.equal(refreshes(usedHost), 1, "default [!Refresh]")

        // Used only by an @Include path (resolved while the files load).
        let (included, _) = try load("[Variables]\n@Include=#@##MACAPPEARANCE#.inc\n[M]\nMeter=String\nText=#Word#\n",
                                     files: ["Root/@Resources/Light.inc": "[Variables]\nWord=bright\n"])
        t.check(included.usesMacAppearance)
        t.equal(text(included, "M"), "bright")

        // Used only by a bang when it runs (a mouse action, a script).
        let (late, _) = try load("[M]\nMeter=String\nText=x\n")
        t.check(!late.usesMacAppearance)
        _ = late.variable("MACDARKMODE")
        t.check(late.usesMacAppearance, "reading one at run time counts")

        // A custom action with DynamicVariables: the new values without a reload.
        let (custom, customHost) = try load("""
        [Rainmeter]
        MacOnAppearanceChangeAction=[!UpdateMeter *][!Redraw]
        [M]
        Meter=String
        DynamicVariables=1
        Text=#MACAPPEARANCE#
        """)
        t.equal(text(custom, "M"), "Light")
        customHost.appearance = .dark
        custom.appearanceDidChange()
        t.equal(text(custom, "M"), "Dark", "the action sees the new appearance")
        t.equal(refreshes(customHost), 0)

        // Written empty: nothing runs.
        let (off, offHost) = try load("[Rainmeter]\nMacOnAppearanceChangeAction=\n[M]\nMeter=String\nText=#MACDARKMODE#\n")
        t.equal(off.settings.macOnAppearanceChangeAction, "")
        off.appearanceDidChange()
        t.equal(refreshes(offHost), 0, "an empty action turns it off")
        t.equal(offHost.handled.count, 0)

        // A closed skin does nothing.
        let (closed, closedHost) = try load("[M]\nMeter=String\nText=#MACDARKMODE#\n")
        closed.close()
        closed.appearanceDidChange()
        t.equal(refreshes(closedHost), 0)
    }

    t.suite("Mac look: MacOnAppearanceChangeAction sees the new values") {
        // The action's own variables are resolved when it runs, and [Variables] built from the appearance variables
        // follow: a skin that recolors itself without a refresh gets the new colors, not the ones it loaded with.
        let host = MacLookHost()
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        MacOnAppearanceChangeAction=[!SetOption Title Text "#MACAPPEARANCE# [#MACDARKMODE]"][!SetOption Title FontColor #MACLABELCOLOR#][!UpdateMeter *][!Redraw]
        [Variables]
        Fg=#MACLABELCOLOR#
        Muted=#Fg#
        Other=#MACAPPEARANCE#
        Fixed=12
        [Title]
        Meter=String
        Text=start
        [Dyn]
        Meter=String
        DynamicVariables=1
        Text=#Fg# | #Muted#
        FontColor=#Fg#
        """, host: host)
        skin.update()
        t.check(skin.settings.macOnAppearanceChangeAction.contains("#MACAPPEARANCE#"), "kept as written")
        t.equal(text(skin, "Dyn"), "0,0,0,217 | 0,0,0,217")
        host.appearance = .dark
        skin.appearanceDidChange()
        t.equal(text(skin, "Title"), "Dark 1", "the new appearance, not the one the skin loaded with")
        t.equal((skin.meter(named: "Title") as? StringMeter)?.style.color, RGBA(r: 255, g: 255, b: 255, a: 217))
        t.equal(text(skin, "Dyn"), "255,255,255,217 | 255,255,255,217", "[Variables] built from them, through others too")
        t.equal((skin.meter(named: "Dyn") as? StringMeter)?.style.color, RGBA(r: 255, g: 255, b: 255, a: 217))
        t.equal(skin.variable("Fixed"), "12")
        // A value a bang set stays until the skin is refreshed; the others keep following.
        skin.execute("[!SetVariable Fg 1,2,3]", from: nil)
        host.appearance = .light
        skin.appearanceDidChange()
        t.equal(skin.variable("Fg"), "1,2,3", "!SetVariable wins")
        t.equal(skin.variable("Other"), "Light")
        t.equal(text(skin, "Title"), "Light 0", "every switch, not one behind")

        // The usual Rainmeter pattern: write the theme, then refresh.
        let themeHost = MacLookHost()
        let (theme, _) = try makeSkin(t, """
        [Rainmeter]
        MacOnAppearanceChangeAction=[!WriteKeyValue Variables Theme #MACAPPEARANCE#][!Refresh]
        [Variables]
        Theme=Light
        [M]
        Meter=String
        Text=#Theme#
        """, host: themeHost)
        themeHost.appearance = .dark
        theme.appearanceDidChange()
        let written = try String(contentsOf: theme.fileURL, encoding: .utf8)
        t.check(written.contains("Theme=Dark"), written)
        t.equal(themeHost.handled.filter { $0.name == "refresh" }.count, 1)
    }

    t.suite("Mac look: a MacOnAppearanceChangeAction of the skin's own runs in any skin") {
        // A skin can follow the appearance without the variables (SysColor, a script): what it writes itself runs.
        let host = MacLookHost()
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        MacOnAppearanceChangeAction=[!SetOption M Text changed][!UpdateMeter M]
        [M]
        Meter=String
        Text=start
        """, host: host)
        skin.update()
        t.check(skin.usesMacAppearance, "written: it opts in")
        skin.appearanceDidChange()
        t.equal(text(skin, "M"), "changed")
        let (refresh, refreshHost) = try makeSkin(t, "[Rainmeter]\nMacOnAppearanceChangeAction=[!Refresh]\n[M]\nMeter=String\n",
                                                  host: MacLookHost())
        refresh.appearanceDidChange()
        t.equal(refreshHost.handled.filter { $0.name == "refresh" }.count, 1, "[!Refresh] written out reloads it")
        // Written empty, or left to the default, in a skin without the variables: nothing.
        for ini in ["[Rainmeter]\nMacOnAppearanceChangeAction=\n[M]\nMeter=String\n", "[Rainmeter]\nUpdate=500\n[M]\nMeter=String\n"] {
            let (quiet, quietHost) = try makeSkin(t, ini, host: MacLookHost())
            t.check(!quiet.usesMacAppearance, ini)
            quiet.appearanceDidChange()
            t.equal(quietHost.handled.count, 0, ini)
        }
    }
}
