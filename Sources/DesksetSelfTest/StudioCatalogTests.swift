import Foundation
@testable import DesksetCore

// The Studio's catalog of settings and its alias index (`StudioCatalog`, `StudioAliasIndex`), and what the widget page
// says about a widget (`StudioWidgetFacts`).

func runStudioCatalogTests(_ t: TestRunner) {
    t.suite("Studio catalog: entries") {
        guard let fontColor = StudioCatalog.field("fontcolor") else { return t.check(false, "FontColor has an entry") }
        t.equal(fontColor.section, .text)
        t.equal(fontColor.control, .color)
        t.equal(fontColor.en, "Color")
        t.equal(fontColor.zh, "颜色")
        t.equal(fontColor.rainmeter, ["FontColor"])
        t.equal(fontColor.level, .essential)
        t.equal(StudioCatalog.field("MeasureName2")?.key, "MeasureName", "a numbered option finds its base")
        t.equal(StudioCatalog.field("FontSize")?.unit?.en, "pt")
        t.equal(StudioCatalog.field("@Text")?.rainmeter, ["FontColor"], "the widget page's Text maps to FontColor")
        t.equal(StudioCatalog.field("@Look")?.presets.map(\.value), ["Auto", "Light", "Dark", "Clear"])
        t.check(StudioCatalog.field("NoSuchOption") == nil)
        // Every entry has words in both languages; widget page keys start with @ and map to no single option.
        var keys: Set<String> = []
        for f in StudioCatalog.all {
            t.check(!f.en.isEmpty && !f.zh.isEmpty, "\(f.key) in both languages")
            t.check(keys.insert(f.key.lowercased()).inserted, "\(f.key) once")
            if f.key.hasPrefix("@") { t.check(!f.rainmeter.contains(f.key), "\(f.key)") }
            else { t.equal(f.rainmeter.first, f.key, "\(f.key) writes itself") }
        }
        // Segmented controls have at most four choices (design: ≤ 4 segments).
        for f in StudioCatalog.all where f.control == .segmented {
            t.check(f.presets.count <= 4, "\(f.key): \(f.presets.count) segments")
        }
    }

    t.suite("Studio catalog: EditorSchema properties by key") {
        let items = StudioCatalog.items(forMeterType: "String")
        t.check(!items.isEmpty)
        t.equal(Set(items.map { $0.property.key.lowercased() }).count, items.count, "each property once")
        // In the order of the box: what it shows, its text, …, the pointer.
        let order = StudioCatalog.Section.allCases
        let positions = items.map { order.firstIndex(of: $0.field.section) ?? 0 }
        t.equal(positions, positions.sorted(), "sections in box order")
        t.check(items.contains { $0.property.key == "FontColor" && $0.field.section == .text })
        t.check(items.contains { $0.property.key == "MeasureName" && $0.field.section == .shows })
        // A property the catalog does not list still has an entry made from the schema.
        let bar = StudioCatalog.items(forMeterType: "Bar")
        t.check(bar.contains { $0.property.key == "BarColor" && $0.field.control == .color })
        t.check(bar.allSatisfy { !$0.field.en.isEmpty })
    }

    t.suite("Studio catalog: alias index") {
        let index = StudioAliasIndex.shared
        t.equal(StudioAliasIndex.normalized("Font-Color "), "fontcolor")
        t.equal(StudioAliasIndex.normalized("ＦｏｎｔＣｏｌｏｒ"), "fontcolor", "full-width letters")
        // A Rainmeter name finds the row and says so.
        let fc = index.match("FontColor", key: "FontColor")
        t.equal(fc?.via, .rainmeter("FontColor"))
        t.check(index.matches("FontColor").first.map { $0.field.key == "FontColor" } == true, "FontColor first")
        t.check(index.match("FontColor", key: "@Text") != nil, "the widget page's Text answers to FontColor too")
        // Everyday words, in both languages.
        t.equal(index.matches("text color").first?.field.key, "FontColor")
        t.check(index.match("字色", key: "FontColor") != nil)
        t.check(index.match("颜色", key: "FontColor")?.via == .label, "a label beats an alias")
        t.check(index.match("bigger", key: "@TextSize") != nil)
        t.check(index.match("放大", key: "@TextSize") != nil)
        t.check(index.match("theme", key: "@Look") != nil)
        t.equal(index.matches(""), [], "nothing for nothing")
        t.equal(index.matches("   "), [])
        // Exact words rank before the start of a word, which ranks before a word inside.
        let size = index.matches("size")
        t.check(size.first?.field.key == "FontSize" || size.first?.field.key == "@Size", "an exact label first")
    }

    t.suite("Studio facts: colors, options, shows, fonts") {
        let resources = """
            [Variables]
            AccentColor=72,212,232
            TextColor=255,255,255
            PanelColor=22,20,34
            PanelAlpha=214
            FontName=Helvetica
            ClockFormat=%H:%M
            ShowNet=1
            Ready=0
            RingPick=CPU
            RingHideCPU=0
            RingHideRAM=1
            """
        let ini = """
            [Rainmeter]
            Update=1000
            SkinWidth=200
            SkinHeight=120

            [Metadata]
            Name=Panel
            Information=Root · A panel of numbers. It has more.

            [Variables]
            @Include=#@#Settings.inc
            RingHide=[#RingHide[#RingPick]]

            [MeasureTime]
            Measure=Time
            Format=#ClockFormat#

            [MeasureCPU]
            Measure=CPU

            [MeasureRAM]
            Measure=PhysicalMemory

            [MeasureRAMTotal]
            Measure=PhysicalMemory
            Total=1

            [MeterPanel]
            Meter=Shape
            Shape=Rectangle 0,0,200,120,8 | Fill Color #PanelColor#,#PanelAlpha# | StrokeWidth 0

            [MeterTitle]
            Meter=String
            Text=PANEL
            FontFace=#FontName#
            FontColor=#AccentColor#
            FontSize=11
            X=10
            Y=10

            [MeterClock]
            Meter=String
            MeasureName=MeasureTime
            FontFace=#FontName#
            FontColor=#TextColor#
            FontSize=13
            X=10
            Y=30

            [MeterCPUBar]
            Meter=Bar
            MeasureName=MeasureCPU
            BarColor=#AccentColor#
            X=10
            Y=60
            W=100
            H=4
            Hidden=#RingHide#

            [MeterCPU]
            Meter=String
            MeasureName=MeasureCPU
            FontFace=#FontName#
            FontColor=#TextColor#
            FontSize=13
            X=120
            Y=55
            Hidden=#RingHide#

            [MeterRAMBar]
            Meter=Bar
            MeasureName=MeasureRAM
            BarColor=200,100,0
            X=10
            Y=60
            W=100
            H=4
            Hidden=(1 - #RingHide#)

            [MeterNetLabel]
            Meter=String
            Text=NET
            FontFace=#FontName#
            FontColor=#TextColor#
            FontSize=11
            X=10
            Y=90
            Hidden=(1 - #ShowNet#)

            [MeterFlag]
            Meter=String
            Text=Ready #Ready#
            FontFace=#FontName#
            FontSize=11
            X=10
            Y=100
            Hidden=#Ready#
            """
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Settings.inc": resources])
        skin.update()
        let f = StudioWidgetFacts(skin: skin)
        t.equal(f.name, "Panel")
        t.equal(f.information, "A panel of numbers.", "the first sentence, without the suite's name")
        t.equal(f.background, "MeterPanel")
        t.equal(f.colors.text?.variable, "TextColor", "Text: the color most text is written in")
        t.equal(f.colors.card?.variable, "PanelColor", "Card: the background's fill")
        t.equal(f.colors.card?.acceptsAlpha, false, "the card's color takes its alpha from PanelAlpha")
        t.equal(f.colors.accents.map(\.variable), ["AccentColor"], "used for words and a bar: an accent")
        t.equal(f.colors.parts.map { ValueUsageIndex.colorKey($0.color) }, [], "the RAM bar is hidden: no part color")
        t.check(f.colors.others.contains { ValueUsageIndex.colorKey($0.color) == "200,100,0,255" }, "it is under More…")
        let options = f.options.map { "\($0.label):\($0.kind)" }
        t.check(options.contains("Accent:color"), "\(options)")
        t.check(options.contains("Panel:alpha"), "the card's opacity: \(options)")
        t.check(options.contains("Clock:hours(twentyFour: true)"), "a %H format: \(options)")
        t.check(options.contains("Show net:toggle"), "a 0/1 that hides a part: \(options)")
        t.check(!options.contains { $0.hasPrefix("Ready") }, "a state word is not an option: \(options)")
        t.check(!options.contains { $0.hasPrefix("Ring pick") }, "a switch between data parts is in Shows: \(options)")
        // Shows: the bar and what it can show instead (the switch writes RingPick).
        guard let row = f.shows.first else { return t.check(false, "a Shows row") }
        t.equal(row.kind, "bar")
        t.equal(row.measure, "MeasureCPU")
        t.equal(row.meters.first, "MeterCPUBar")
        t.equal(row.choices.map(\.measure), ["MeasureCPU", "MeasureRAM"])
        t.equal(row.choices.last?.write, .variable("RingPick", "RAM"))
        t.check(!f.shows.contains { $0.measure == "MeasureRAMTotal" }, "a total is no row")
        // One font for all words; every text size, each place once.
        t.equal(f.fonts.map(\.role), [.words])
        t.equal(f.fonts.first?.source, .variable("FontName"))
        t.equal(f.textSizes.count, 5, "each meter's own size")
        t.equal(f.look, nil)
        t.equal(f.variants, nil)
    }

    t.suite("Studio facts: writing a color") {
        let ini = """
            [Rainmeter]
            Update=1000
            SkinWidth=200
            SkinHeight=100

            [Variables]
            @Include=#@#Theme.inc
            Ring=0,136,255

            [MeterCard]
            Meter=Shape
            Shape=Rectangle 0,0,200,100,8 | Fill Color #Card# | StrokeWidth 0

            [MeterBar]
            Meter=Bar
            MeasureName=MeasureCPU
            BarColor=C86400
            X=10
            Y=10
            W=100
            H=4

            [MeterRing]
            Meter=Shape
            Shape=Ellipse 50,50,20 | Fill Color 0,0,0,0 | StrokeWidth 4 | Stroke Color #Ring#,80
            Shape2=Arc 50,30,70,50,20,20 | StrokeWidth 4 | Stroke Color #Ring#

            [MeterLabel]
            Meter=String
            Text=CPU
            FontColor=#Ink#
            X=10
            Y=60

            [MeasureCPU]
            Measure=CPU
            """
        let (skin, _) = try makeSkin(t, ini, files: ["Root/@Resources/Theme.inc": "[Variables]\nCard=250,250,250,200\nInk=20,20,20\n"])
        skin.update()
        let f = StudioWidgetFacts(skin: skin)
        let mint = RGBA(r: 0, g: 199, b: 190)
        // A variable the widget adds an alpha to stays R,G,B, written for this widget after its includes.
        guard let ring = f.colors.all.first(where: { $0.variable == "Ring" }) else { return t.check(false, "the ring") }
        t.equal(ring.acceptsAlpha, false)
        t.equal(StudioColorWriting.ops(ring, RGBA(r: 0, g: 199, b: 190, a: 128), skin: skin),
                [.setValue(file: skin.fileURL, section: "Variables", key: "Ring", value: "0,199,190", afterIncludes: true)])
        // A shared file's color is overridden in the widget's own file.
        guard let card = f.colors.card else { return t.check(false, "the card") }
        t.equal(card.variable, "Card")
        t.equal(StudioColorWriting.currentText(card, skin: skin), "250,250,250,200")
        t.equal(StudioColorWriting.ops(card, RGBA(r: 10, g: 20, b: 60, a: 200), skin: skin),
                [.setValue(file: skin.fileURL, section: "Variables", key: "Card", value: "10,20,60,200", afterIncludes: true)])
        // A literal color is replaced where it is written, in its notation (hex stays hex).
        guard let bar = f.colors.all.first(where: { $0.variable == nil && ValueUsageIndex.colorKey($0.color) == "200,100,0,255" })
        else { return t.check(false, "the bar's color") }
        t.equal(StudioColorWriting.ops(bar, mint, skin: skin),
                [.setValue(file: skin.fileURL, section: "MeterBar", key: "BarColor", value: "00C7BE", afterIncludes: false)])
        let preview = StudioColorWriting.preview(bar, mint, skin: skin)
        t.equal(preview.sections.first?.0, "MeterBar")
        t.equal(preview.sections.first?.1["BarColor"], "00C7BE")
        t.equal(StudioColorWriting.preview(ring, mint, skin: skin).variables, ["Ring": "0,199,190"])
        // Sample readings pinned by name, whatever the measure is.
        let sample = MeasureValueOverride()
        sample.pinned = ["measurecpu": (21, nil)]
        skin.measureValues = sample
        skin.update()
        t.equal(skin.measure(named: "MeasureCPU")?.value, 21)
    }
}
