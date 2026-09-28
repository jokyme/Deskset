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
        [Sliced]
        Meter=Image
        ImageName=sf:cpu.fill
        W=40
        H=10
        ScaleMargins=6,3,6,3
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
        t.equal(image("Sliced").preserveAspectRatio, 0, "ScaleMargins nine-slices a symbol (only at 0)")
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

    t.suite("Mac look: palette symbols (MacSymbolRendering=Palette, MacSymbolColors)") {
        t.equal(MacSymbol.Rendering(parsing: " PALETTE "), .palette)
        t.equal(MacSymbol.Rendering.palette.optionValue, "Palette")
        // Parsing: `|` between colors, formulas and hex allowed, trailing empties dropped, a bad entry white.
        t.equal(MacSymbol.colors(parsing: "0,0,0,153 | 255,204,0"),
                [RGBA(r: 0, g: 0, b: 0, a: 153), RGBA(r: 255, g: 204, b: 0)])
        t.equal(MacSymbol.colors(parsing: "FFCC00|(Clamp(300,0,255)),(1|2),0,128"),
                [RGBA(r: 255, g: 204, b: 0), RGBA(r: 255, g: 3, b: 0, a: 128)], "a | inside parentheses is a formula's")
        t.equal(MacSymbol.colors(parsing: "red|0,0,255"), [.white, RGBA(r: 0, g: 0, b: 255)],
                "an entry that is not a color is white, so the next layer keeps its color")
        t.equal(MacSymbol.colors(parsing: "||1,2,3"), [.white, .white, RGBA(r: 1, g: 2, b: 3)])
        t.equal(MacSymbol.colors(parsing: "1,2,3||"), [RGBA(r: 1, g: 2, b: 3)], "trailing empties dropped")
        t.equal(MacSymbol.colors(parsing: "  "), [])
        t.equal(MacSymbol.colors(parsing: "1,1,1|2,2,2|3,3,3|4,4,4|5,5,5").count, MacSymbol.maxColors, "three layers")
        t.equal(MacSymbol.colors(parsing: "12.4,12.6,-4,999"), [RGBA(r: 12, g: 13, b: 0, a: 255)], "whole, 0…255")

        // Paths: the colors only with Palette, as rrggbbaa; a round trip keeps them.
        let palette = MacSymbol(name: "cloud.sun.fill",
                                style: MacSymbol.Style(pointSize: 20, rendering: .palette,
                                                       colors: [RGBA(r: 0, g: 0, b: 0, a: 153), RGBA(r: 255, g: 204, b: 0)]),
                                density: 2)
        t.equal(palette.path, "sf:cloud.sun.fill?size=20&weight=regular&rendering=palette&colors=00000099-ffcc00ff&density=2")
        t.equal(MacSymbol(path: palette.path), palette, "round trip")
        t.equal(palette.measuringPath, "sf:cloud.sun.fill?size=20&weight=regular&rendering=palette&colors=00000099-ffcc00ff")
        t.equal(MacSymbol.Style(rendering: .hierarchical, colors: [.black]).colors, [], "colors belong to Palette only")
        var style = MacSymbol.Style(rendering: .palette, colors: [.black])
        style.rendering = .multicolor
        t.equal(style.colors, [], "leaving Palette drops the colors")
        style.colors = [.white]
        t.equal(style.colors, [], "and a non-palette style takes none")
        t.equal(MacSymbol(path: "sf:a?rendering=multicolor&colors=ff0000ff")?.style.colors, [])
        t.equal(MacSymbol(path: "sf:a?colors=ff0000ff-zz&rendering=palette")?.style.colors,
                [RGBA(r: 255, g: 0, b: 0), .white], "any order; a bad entry is white")
        t.equal(MacSymbol(name: "a", style: MacSymbol.Style(rendering: .palette)).path,
                "sf:a?size=16&weight=regular&rendering=palette", "a palette without colors")

        // Read from a skin: the options (with prefixes) reach the path the host draws.
        let host = MacLookHost()
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        [Variables]
        Ink=0,0,0,153
        Sun=255,204,0
        [MeasureColors]
        Measure=String
        String=#Sun#|#Ink#
        [Sun]
        Meter=Image
        ImageName=sf:cpu.fill
        MacSymbolRendering=Palette
        MacSymbolColors=#Ink#|#Sun#
        [FromMeasure]
        Meter=Image
        ImageName=sf:cpu.fill
        MacSymbolRendering=palette
        MacSymbolColors=[MeasureColors]
        DynamicVariables=1
        [Ignored]
        Meter=Image
        ImageName=sf:cpu.fill
        MacSymbolRendering=Hierarchical
        MacSymbolColors=#Ink#
        [Bar]
        Meter=Bar
        BarImage=sf:battery.100percent
        MacSymbolRendering=Palette
        MacSymbolColors=#Sun#
        """, host: host)
        skin.update()
        skin.update()
        func path(_ name: String) -> String? { (skin.meter(named: name) as? ImageMeter)?.imagePath }
        t.equal(path("Sun"), "sf:cpu.fill?size=16&weight=regular&rendering=palette&colors=00000099-ffcc00ff")
        t.equal(path("FromMeasure"), "sf:cpu.fill?size=16&weight=regular&rendering=palette&colors=ffcc00ff-00000099",
                "a measure's value (a MacWeather SymbolPalette) sets them")
        t.equal(path("Ignored"), "sf:cpu.fill?size=16&weight=regular&rendering=hierarchical")
        t.equal((skin.meter(named: "Bar") as? BarMeter)?.barImagePath,
                "sf:battery.100percent?size=16&weight=regular&rendering=palette&colors=ffcc00ff")
        t.equal(skin.meter(named: "Sun")?.frame.width, 20, "the colors do not change the size")
        skin.execute("[!SetOption Sun MacSymbolColors \"1,2,3\"][!UpdateMeter Sun]", from: nil)
        t.equal(path("Sun"), "sf:cpu.fill?size=16&weight=regular&rendering=palette&colors=010203ff")
        t.check(skin.issues.isEmpty, "\(skin.issues)")
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
        t.check(!skin.issues.contains { $0.contains("[Empty]") }, "sf: alone is no image, as an empty name: \(skin.issues)")
        t.equal((skin.meter(named: "Empty") as? ImageMeter)?.imagePath, nil)
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

    t.suite("Mac look: a symbol named by a measure is noted only while it is missing") {
        // `sf:[MeasureIcon]` before the measure has a value is `sf:` — no image, no note — and a name that was missing
        // and is now found takes its note back: a widget that works has no compatibility note.
        let host = MacLookHost()
        let (skin, _) = try makeSkin(t, """
        [MeasureIcon]
        Measure=String
        String=
        [Icon]
        Meter=Image
        ImageName=sf:[MeasureIcon]
        DynamicVariables=1
        [Template]
        Meter=Image
        MeasureName=MeasureIcon
        ImageName=sf:%1
        [Masked]
        Meter=Image
        MeasureName=MeasureIcon
        ImageName=sf:%1
        MaskImageName=sf:not.there
        """, host: host)
        skin.update()
        t.equal(skin.issues.filter { !$0.contains("not.there") }, [], "empty: no note")
        t.equal((skin.meter(named: "Icon") as? ImageMeter)?.imagePath, nil)
        skin.execute("[!SetOption MeasureIcon String not.there]", from: nil)
        skin.update()
        t.equal(skin.issues.filter { $0.contains("not.there") }.count, 3, "a missing name: one note per meter \(skin.issues)")
        skin.execute("[!SetOption MeasureIcon String cpu.fill]", from: nil)
        skin.update()
        t.equal(skin.issues, [Skin.missingSymbolNote(MacSymbol(name: "not.there"), section: "Masked")],
                "found now: the notes go, but the mask still names the missing one")
        t.equal((skin.meter(named: "Icon") as? ImageMeter)?.imagePath, MacSymbol(name: "cpu.fill").path)
        t.equal((skin.meter(named: "Template") as? ImageMeter)?.imagePath, MacSymbol(name: "cpu.fill").path)
        skin.execute("[!SetOption MeasureIcon String no.longer]", from: nil)
        skin.update()
        t.check(skin.issues.contains { $0.hasPrefix("[Icon] sf:no.longer") }, "missing again: noted again \(skin.issues)")
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
                ["Monochrome", "Hierarchical", "Multicolor", "Palette"])
        // The layers' colors show only for a palette symbol.
        if let colors = S.property("MacSymbolColors", in: S.meterGroups("Image")) {
            let groups = S.meterGroups("Image")
            let palette: (String) -> String? = { ["ImageName": "sf:cloud.sun.fill", "MacSymbolRendering": "palette"][$0] }
            t.check(S.isVisible(colors, in: groups, values: palette), "shown for a palette")
            t.check(!S.isVisible(colors, in: groups, values: { $0 == "ImageName" ? "sf:cloud.sun.fill" : nil }),
                    "hidden for Monochrome")
            t.check(!S.isVisible(colors, in: groups, values: {
                ["ImageName": "clock.png", "MacSymbolRendering": "Palette"][$0] }), "hidden for a file")
        } else {
            t.check(false, "MacSymbolColors is in the editor")
        }
        t.equal(S.property("MacSymbolSize", in: S.meterGroups("Image"))?.defaultValue, "16")
        let image = S.meterGroups("Image"), fit = S.property("PreserveAspectRatio", in: image)!
        t.equal(S.defaultValue(of: fit, in: image, values: { $0 == "ImageName" ? "sf:wifi" : nil }), "1",
                "a symbol fits inside by default, as the engine draws it")
        t.equal(S.defaultValue(of: fit, in: image, values: { $0 == "ImageName" ? "wifi.png" : nil }), "0")
        let sliced: (String) -> String? = { ["ImageName": "sf:capsule.fill", "ScaleMargins": "10,4,10,4"][$0] }
        t.equal(S.defaultValue(of: fit, in: image, values: sliced), "0", "with ScaleMargins, as the engine")
        t.check(S.isVisible(S.property("ScaleMargins", in: image)!, in: image, values: sliced), "ScaleMargins is shown")
        let skin = S.skinGroups
        t.equal(S.property("MacOnAppearanceChangeAction", in: skin)?.kind, .action)
        t.equal(S.property("MacOnAppearanceChangeAction", in: skin)?.defaultValue, Skin.defaultAppearanceChangeAction)
        t.check(S.property("MacSymbolSize", in: skin) != nil, "the background can be a symbol")
        // Every label reads as plain words.
        for key in ["MacSymbolSize", "MacSymbolWeight", "MacSymbolRendering", "MacSymbolColors"] {
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
        t.equal(BuiltInVariables.macAppearanceNames.count, 10)
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

    t.suite("Mac look: clock, week and temperature variables") {
        for name in ["MACCLOCKHOURS", "MacFirstWeekday", "mactemperatureunit"] {
            t.check(BuiltInVariables.isBuiltIn(name) && BuiltInVariables.isDynamic(name), name)
            t.check(SkinAppearance.mentioned(in: "X=#\(name)#"), name)
        }
        let standard = MacRegionalSettings.standard
        t.equal([standard.variableValue("macclockhours"), standard.variableValue("macfirstweekday"),
                 standard.variableValue("mactemperatureunit")], ["24", "0", "C"], "a host that does not ask macOS")
        t.equal(SkinAppearance.dark.variableValue("macclockhours"), "24")
        t.equal(standard.variableValue("macappearance"), nil)
        t.equal(MacRegionalSettings(clockHours: 13, firstWeekday: 9).clockHours, 24, "only 12 is 12")
        t.equal(MacRegionalSettings(clockHours: 12, firstWeekday: 9).firstWeekday, 6, "clamped")
        t.equal(MacRegionalSettings(firstWeekday: -3).firstWeekday, 0)

        // From macOS: the locale's preferred hour (the 24-hour switch changes it), the calendar, the Temperature
        // setting or the region's unit for weather.
        func hours(_ id: String) -> Int { MacRegionalSettings.clockHours(locale: Locale(identifier: id)) }
        t.equal(hours("en_US"), 12)
        t.equal(hours("en_GB"), 24)
        t.equal(hours("de_DE"), 24)
        t.equal(hours("zh_CN"), 24)
        t.equal(hours("zh_TW"), 12, "ah時")
        t.equal(hours("ko_KR"), 12)
        t.equal(hours("fr_CA"), 24, "HH 'h': the quoted h is text")
        t.equal(hours("en_US@hours=h23"), 24, "the locale's own override")
        t.equal(hours("de_DE@hours=h12"), 12)
        t.equal(WeatherEnvironment.systemUses24HourClock(locale: Locale(identifier: "en_US")), false, "the weather's default formats agree")
        func weekday(_ id: String) -> Int {
            var c = Calendar(identifier: .gregorian)
            c.locale = Locale(identifier: id)
            return MacRegionalSettings.firstWeekday(calendar: c)
        }
        t.equal(weekday("en_US"), 0, "Sunday")
        t.equal(weekday("de_DE"), 1, "Monday")
        t.equal(weekday("ar_EG"), 6, "Saturday")
        var monday = Calendar(identifier: .gregorian)
        monday.firstWeekday = 2
        t.equal(MacRegionalSettings.firstWeekday(calendar: monday), 1, "the user's own choice")
        func unit(_ setting: String?, _ id: String) -> TemperatureUnit {
            MacRegionalSettings.temperatureUnit(setting: setting, locale: Locale(identifier: id))
        }
        t.equal(unit(nil, "en_US"), .fahrenheit)
        t.equal(unit(nil, "de_DE"), .celsius)
        t.equal(unit(nil, "zh_CN"), .celsius)
        t.equal(unit(nil, "en_BS"), .fahrenheit, "the region's unit for weather, not its measurement system")
        t.equal(unit(nil, "en_US@mu=celsius"), .celsius, "the locale's own override")
        t.equal(unit("Celsius", "en_US"), .celsius, "the Temperature setting wins")
        t.equal(unit("Fahrenheit", "de_DE"), .fahrenheit)
        t.equal(unit(" f ", "de_DE"), .fahrenheit)
        t.equal(unit("Kelvin", "en_US"), .fahrenheit, "an unknown setting is ignored")
        let mac = MacRegionalSettings.system(locale: Locale(identifier: "en_US"), calendar: monday,
                                             temperatureSetting: "Celsius")
        t.equal(mac, MacRegionalSettings(clockHours: 12, firstWeekday: 1, temperatureUnit: .celsius))

        // What skins see: dynamic, fixed for [Variables] and !SetVariable, and "Auto" settings built on them.
        let host = MacLookHost()
        host.appearance.regional = MacRegionalSettings(clockHours: 12, firstWeekday: 1, temperatureUnit: .fahrenheit)
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        MacOnAppearanceChangeAction=[!UpdateMeter *][!Redraw]
        [Variables]
        MACCLOCKHOURS=24
        ClockHours=Auto
        ClockHoursAuto=#MACCLOCKHOURS#
        ClockHours24=24
        ClockHours12=12
        WeekStart=Auto
        WeekStartAuto=#MACFIRSTWEEKDAY#
        TempUnit=Auto
        TempUnitAuto=#MACTEMPERATUREUNIT#
        [Plain]
        Meter=String
        Text=#MACCLOCKHOURS# #MACFIRSTWEEKDAY# #MACTEMPERATUREUNIT#
        [Auto]
        Meter=String
        DynamicVariables=1
        Text=[#ClockHours[#ClockHours]] [#WeekStart[#WeekStart]] [#TempUnit[#TempUnit]]
        """, host: host)
        skin.update()
        t.equal(text(skin, "Plain"), "12 1 F", "[Variables] cannot override a built-in")
        t.equal(text(skin, "Auto"), "12 1 F", "Auto resolves through the nested variables")
        t.check(skin.usesMacAppearance)
        skin.execute("[!SetVariable MACFIRSTWEEKDAY 3]", from: nil)
        t.equal(skin.variable("MACFIRSTWEEKDAY"), "1", "!SetVariable cannot change it")
        host.appearance.regional = MacRegionalSettings(clockHours: 24, firstWeekday: 0, temperatureUnit: .celsius)
        skin.appearanceDidChange()
        t.equal(text(skin, "Auto"), "24 0 C", "a change of the settings reaches [Variables] built from them")
        t.equal(skin.variable("ClockHoursAuto"), "24")

        // Used only through one of them: refreshed by default when a setting changes.
        let refreshHost = MacLookHost()
        let (week, _) = try makeSkin(t, "[M]\nMeter=String\nText=#MACFIRSTWEEKDAY#\n", host: refreshHost)
        week.update()
        t.check(week.usesMacAppearance)
        week.appearanceDidChange()
        t.equal(refreshHost.handled.filter { $0.name == "refresh" }.count, 1)
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

    t.suite("Mac look: @Include paths use the Mac's appearance, not a [Variables] fallback") {
        let files = ["Root/@Resources/Theme-Dark.inc": "[Variables]\nPanel=night\n",
                     "Root/@Resources/Theme-Light.inc": "[Variables]\nPanel=day\n"]
        for fallbackFirst in [true, false] {
            let host = MacLookHost()
            host.appearance = .dark
            let fallback = "MACAPPEARANCE=Light\nMACDARKMODE=0\n"
            let include = "@Include=#@#Theme-#MACAPPEARANCE#.inc\n"
            let (skin, _) = try makeSkin(t, "[Variables]\n" + (fallbackFirst ? fallback + include : include + fallback)
                                         + "[M]\nMeter=String\nText=#Panel# #MACDARKMODE# #MACAPPEARANCE#\n",
                                         files: files, host: host)
            skin.update()
            t.equal(text(skin, "M"), "night 1 Dark", "the theme of the Mac's appearance (fallback first: \(fallbackFirst))")
        }

        // The editor's map of who reads which file: both theme files, for every config including them this way.
        let (skin, _) = try makeSkin(t, "[Variables]\n@Include=#@#Theme-#MACAPPEARANCE#.inc\n[M]\nMeter=String\n",
                                     files: files.merging(["Root/Other/Other.ini":
                                        "[Variables]\n@Include=#@#Theme-#MACAPPEARANCE#.inc\n[M]\nMeter=String\n",
                                        "Root/Plain/Plain.ini": "[M]\nMeter=String\n"]) { a, _ in a },
                                     host: MacLookHost())
        for theme in ["Theme-Light.inc", "Theme-Dark.inc"] {
            t.equal(skin.configsIncluding(skin.resourcesDirectory.appendingPathComponent(theme)), ["root\\other", "root\\sub"],
                    theme)
        }
    }
}
