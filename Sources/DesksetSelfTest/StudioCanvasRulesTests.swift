import Foundation
@testable import DesksetCore

// The Studio canvas's rules in Core: how different two colors look (CIEDE2000), the ink of "what it draws" (the
// accent unless the widget has a color close to it), and which parts the first click passes over.

func runStudioCanvasRulesTests(_ t: TestRunner) {
    t.suite("Studio canvas: CIEDE2000") {
        typealias Lab = ColorDifference.Lab
        // Pairs from Sharma, Wu and Dalal's test data for the CIEDE2000 formula.
        let pairs: [(Lab, Lab, Double)] = [
            (Lab(50, 2.6772, -79.7751), Lab(50, 0, -82.7485), 2.0425),
            (Lab(50, 0, 0), Lab(50, -1, 2), 2.3669),
            (Lab(50, 2.5, 0), Lab(73, 25, -18), 27.1492),
            (Lab(60.2574, -34.0099, 36.2677), Lab(60.4626, -34.1751, 39.4387), 1.2644),
            (Lab(22.7233, 20.0904, -46.694), Lab(23.0331, 14.973, -42.5619), 2.0373),
            (Lab(2.0776, 0.0795, -1.135), Lab(0.9033, -0.0636, -0.5514), 0.9082),
        ]
        for (i, (a, b, expected)) in pairs.enumerated() {
            let d = ColorDifference.deltaE2000(a, b)
            t.check(abs(d - expected) < 0.0005, "pair \(i + 1): \(d) against \(expected)")
            t.check(abs(ColorDifference.deltaE2000(b, a) - d) < 1e-9, "pair \(i + 1): the same both ways")
        }
        let white = RGBA(r: 255, g: 255, b: 255)
        t.check(abs(ColorDifference.lab(white).l - 100) < 0.01, "white is L* 100")
        t.equal(ColorDifference.deltaE2000(white, white), 0)
        t.check(ColorDifference.deltaE2000(RGBA(r: 0, g: 0, b: 0), white) > 90)
    }

    t.suite("Studio canvas: the ink of what it draws") {
        let accent = RGBA(r: 0, g: 122, b: 255)
        // System's CPU ring is a blue of its own; the weather's rain is another.
        t.equal(StudioOutlineInk.choose(accent: accent, colors: [RGBA(r: 64, g: 130, b: 246), RGBA(r: 52, g: 199, b: 89)]),
                .graphite, "a blue close to the accent: graphite for the whole widget")
        t.equal(StudioOutlineInk.choose(accent: accent, colors: [RGBA(r: 52, g: 199, b: 89), RGBA(r: 255, g: 149, b: 0),
                                                                 RGBA(r: 250, g: 250, b: 250)]),
                .accent, "no color near the accent: the accent")
        t.equal(StudioOutlineInk.choose(accent: accent, colors: [RGBA(r: 0, g: 122, b: 255, a: 10)]), .accent,
                "a nearly transparent blue is not seen as blue")
        t.equal(StudioOutlineInk.choose(accent: accent, colors: []), .accent)
        // The threshold is ΔE₀₀ 20: just over it is accent, just under it graphite.
        let near = RGBA(r: 40, g: 110, b: 220)
        let d = ColorDifference.deltaE2000(near, accent)
        t.equal(StudioOutlineInk.choose(accent: accent, colors: [near], threshold: d + 0.01), .graphite)
        t.equal(StudioOutlineInk.choose(accent: accent, colors: [near], threshold: d - 0.01), .accent)
    }

    t.suite("Studio canvas: the first click passes over parts that draw nothing") {
        let ini = """
            [Rainmeter]
            Update=1000

            [MeterCard]
            Meter=Shape
            Shape=Rectangle 0,0,200,100,8 | Fill Color 250,250,250 | StrokeWidth 0

            [MeterValue]
            Meter=String
            Text=21%
            FontSize=20
            FontColor=20,20,20
            X=20
            Y=20

            [MeterHitArea]
            ; laid over the number to catch the pointer
            Meter=Image
            SolidColor=0,0,0,1
            X=0
            Y=0
            W=200
            H=100
            LeftMouseUpAction=[!Refresh]

            [MeterEmpty]
            Meter=String
            Text=
            X=0
            Y=0
            W=50
            H=50

            [MeterOutline]
            Meter=Shape
            Shape=Rectangle 150,70,40,20 | Fill Color 0,0,0,0 | StrokeWidth 0
            """
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        func meter(_ name: String) -> Meter { skin.meter(named: name)! }
        t.check(StudioHitRule.drawsSomething(meter("MeterCard")))
        t.check(StudioHitRule.drawsSomething(meter("MeterValue")))
        t.check(!StudioHitRule.drawsSomething(meter("MeterHitArea")), "a transparent hit area draws nothing")
        t.check(!StudioHitRule.drawsSomething(meter("MeterEmpty")), "an empty text draws nothing")
        t.check(!StudioHitRule.drawsSomething(meter("MeterOutline")), "a shape without paint draws nothing")
        // Over the number: front first, the hit area, the empty text, the number, the card.
        let atNumber = [meter("MeterEmpty"), meter("MeterHitArea"), meter("MeterValue"), meter("MeterCard")]
        t.equal(StudioHitRule.pick(atNumber)?.name, "MeterValue", "the number, not the area over it")
        // Only parts that draw nothing under the pointer: the innermost of them.
        t.equal(StudioHitRule.pick([meter("MeterHitArea"), meter("MeterEmpty")])?.name, "MeterEmpty")
        t.equal(StudioHitRule.pick([])?.name, nil)
    }
}

func runStudioEverySettingTests(_ t: TestRunner) {
    t.suite("Studio every setting: rows in the order of the box") {
        let ini = """
            [Rainmeter]
            Update=1000

            [MeasureCPU]
            Measure=CPU

            [MeterValue]
            Meter=String
            MeasureName=MeasureCPU
            Text=%1%
            FontSize=20
            FontColor=20,20,20
            StringEffect=Shadow
            FontEffectColor=0,0,0,90
            SolidColor=240,240,240
            BevelType=1
            Padding=2,3,4,5
            X=20
            Y=20
            LeftMouseUpAction=["https://example.com"]
            """
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        guard let m = skin.meter(named: "MeterValue") else { return t.check(false, "the meter") }
        let groups = StudioEverySetting.groups(meter: m)
        let sections = groups.map(\.section)
        t.equal(sections, StudioEverySetting.Section.allCases.filter { sections.contains($0) }, "in the order of the box")
        t.equal(sections.first, .content)
        t.check(sections.contains(.pointer), "the clicks are with the pointer")
        let keys = groups.flatMap(\.rows).map { $0.key.lowercased() }
        t.equal(Set(keys).count, keys.count, "each setting once")
        for key in ["measurename", "text", "fontsize", "fontcolor", "x", "y", "solidcolor", "padding", "leftmouseupaction"] {
            t.check(keys.contains(key), "\(key) is on the page")
        }
        let size = groups.flatMap(\.rows).first { $0.key == "FontSize" }
        t.equal(size?.written, "20")
        t.equal(size?.isSet, true)
        let weight = groups.flatMap(\.rows).first { $0.key == "FontWeight" }
        t.equal(weight?.isSet, false, "not written: its default")
        t.check(StudioEverySetting.count(groups) > 20, "\(StudioEverySetting.count(groups)) settings")
        // The box, from outside in.
        let box = StudioEverySetting.box(m)
        t.equal(box.margin, nil, "an INI part has no margin")
        t.equal(box.shadow, RGBA(r: 0, g: 0, b: 0, a: 90), "a text's shadow")
        t.equal(box.background, RGBA(r: 240, g: 240, b: 240))
        t.equal(box.border, 1)
        t.equal(box.padding, SkinInsets(left: 2, top: 3, right: 4, bottom: 5))
    }

    t.suite("Studio every setting: the filter answers to Rainmeter names") {
        let (skin, _) = try makeSkin(t, """
            [Rainmeter]
            Update=1000

            [MeterValue]
            Meter=String
            Text=Hello
            FontColor=20,20,20
            """)
        skin.update()
        guard let m = skin.meter(named: "MeterValue") else { return t.check(false, "the meter") }
        let found = StudioEverySetting.groups(meter: m, filter: "FontColor").flatMap(\.rows)
        let color = found.first { $0.key == "FontColor" }
        t.check(color != nil, "filtering FontColor keeps the Color row: \(found.map(\.key))")
        t.equal(color?.item.field.en, "Color")
        t.equal(color?.via, .rainmeter("FontColor"), "found by its Rainmeter name, which the row says")
        let byLabel = StudioEverySetting.groups(meter: m, filter: "color").flatMap(\.rows)
        t.check(byLabel.contains { $0.key == "FontColor" && $0.via == nil }, "found by its label: nothing to say")
        let byAlias = StudioEverySetting.groups(meter: m, filter: "字色").flatMap(\.rows)
        t.check(byAlias.contains { $0.key == "FontColor" }, "Chinese words find it too")
        t.equal(StudioEverySetting.groups(meter: m, filter: "zzzz").count, 0, "nothing matches: no sections")
        t.check(StudioEverySetting.groups(meter: m, filter: "  ").count > 3, "an empty filter keeps everything")
    }
}
