import Foundation
@testable import DesksetCore

// MacGlass (a Deskset extension): the options, where the glass goes, Shape rectangles, dynamic changes and when the
// host hears of them.

func runGlassTests(_ t: TestRunner) {
    func region(_ skin: Skin, _ id: String) -> GlassRegion? { skin.glassRegions.first { $0.id == id } }

    t.suite("Glass: options") {
        t.equal(GlassOptions.style("Regular").style, .regular)
        t.equal(GlassOptions.style(" clear ").style, .clear)
        t.equal(GlassOptions.style("REGULAR").style, .regular)
        t.equal(GlassOptions.style("None").style, nil)
        t.check(!GlassOptions.style("none").invalid)
        t.check(!GlassOptions.style("").invalid, "empty is no glass")
        t.check(GlassOptions.style("Frosted").invalid)
        t.check(GlassOptions.style("1").invalid, "only the words")

        let (skin, host) = try makeSkin(t, """
        [A]
        Meter=String
        Text=Hi
        MacGlass=Clear
        MacGlassCornerRadius=(4*3)
        MacGlassTint=FF000080
        [B]
        Meter=String
        Text=Hi
        MacGlass=Regular
        MacGlassCornerRadius=-5
        MacGlassTint=0,0,255
        [C]
        Meter=String
        Text=Hi
        MacGlass=Frosted
        [D]
        Meter=String
        Text=Hi
        MacGlass=None
        MacGlassCornerRadius=8
        [E]
        Meter=String
        Text=Hi
        MacGlass=Regular
        MacGlassCornerRadius=round
        MacGlassTint=blue
        """)
        skin.update()
        let a = skin.meter(named: "A")?.glass
        t.equal(a?.style, .clear)
        t.equal(a?.cornerRadius, 12, "a formula")
        t.equal(a?.tint, RGBA(r: 255, g: 0, b: 0, a: 128), "hex with alpha")
        let b = skin.meter(named: "B")?.glass
        t.equal(b?.style, .regular)
        t.equal(b?.cornerRadius, 0, "a negative radius is 0")
        t.equal(b?.tint, RGBA(r: 0, g: 0, b: 255, a: 255))
        t.equal(skin.meter(named: "C")?.glass, nil, "not a style: no glass")
        t.equal(skin.meter(named: "D")?.glass, nil)
        let e = skin.meter(named: "E")?.glass
        t.equal(e?.cornerRadius, nil, "unreadable radius: as if not given")
        t.equal(e?.tint, nil, "unreadable tint: none")
        t.equal(host.logs.filter { $0.contains("MacGlass=Frosted on [C]") }.count, 1, "logged")
        skin.update()
        t.equal(host.logs.filter { $0.contains("MacGlass=Frosted") }.count, 1, "once")
        t.equal(skin.issues, [], "a Deskset extension, not a compatibility issue")
    }

    t.suite("Glass: where the glass goes") {
        let (skin, host) = try makeSkin(t, """
        [Rainmeter]
        MacGlass=Regular
        MacGlassCornerRadius=500
        MacGlassTint=10,20,30,40
        [Back]
        Meter=Image
        W=200
        H=100
        MacGlass=Clear
        MacGlassCornerRadius=16
        [Label]
        Meter=String
        X=10
        Y=10
        Text=Glass
        MacGlass=Regular
        [Hidden]
        Meter=Image
        W=50
        H=50
        Hidden=1
        MacGlass=Regular
        [Empty]
        Meter=Image
        X=20
        MacGlass=Regular
        [Moved]
        Meter=Image
        W=40
        H=20
        TransformationMatrix=1;0;0;1;5;6
        MacGlass=Regular
        MacGlassCornerRadius=15
        [Turned]
        Meter=Image
        W=40
        H=20
        TransformationMatrix=0;1;-1;0;40;0
        MacGlass=Regular
        """)
        t.equal(skin.currentGlassRegions(), [], "nothing before the first update sized the skin")
        skin.update()
        t.equal(skin.glassRegions.map(\.id), ["Rainmeter", "Back", "Label", "Moved"],
                "the skin's own first, then the meters in file order")
        t.equal(region(skin, "Rainmeter"), GlassRegion(id: "Rainmeter", rect: SkinRect(x: 0, y: 0, width: 200, height: 100),
                                                        cornerRadius: 50, style: .regular,
                                                        tint: RGBA(r: 10, g: 20, b: 30, a: 40)),
                "the whole skin; the radius at most half the shorter side")
        t.equal(region(skin, "Back")?.rect, SkinRect(x: 0, y: 0, width: 200, height: 100))
        t.equal(region(skin, "Back")?.style, .clear)
        t.equal(region(skin, "Back")?.cornerRadius, 16)
        t.equal(region(skin, "Label")?.rect, SkinRect(x: 10, y: 10, width: 35, height: 14), "the meter's frame")
        t.equal(region(skin, "Label")?.cornerRadius, 0)
        t.equal(region(skin, "Label")?.tint, nil)
        t.equal(region(skin, "Moved")?.rect, SkinRect(x: 5, y: 6, width: 40, height: 20), "a matrix that only moves")
        t.equal(region(skin, "Moved")?.cornerRadius, 10, "at most half the shorter side")
        t.equal(host.glassChanges.count, 1, "told once")
        t.equal(host.glassChanges.last ?? [], skin.glassRegions)
        skin.update()
        skin.redraw()
        t.equal(host.glassChanges.count, 1, "nothing changed: not told again")
        let redraws = host.redraws
        skin.execute("[!HideMeter Label][!Redraw]", from: nil)
        t.equal(skin.glassRegions.map(\.id), ["Rainmeter", "Back", "Moved"], "hidden: no glass")
        t.equal(host.glassChanges.count, 2)
        t.check(host.redraws > redraws, "and the skin is redrawn")
        skin.execute("[!ShowMeter Label][!MoveMeter 30 40 Label]", from: nil)
        t.equal(region(skin, "Label")?.rect, SkinRect(x: 30, y: 40, width: 35, height: 14), "!MoveMeter moves the glass")
        t.equal(host.glassChanges.count, 3)
    }

    t.suite("Glass: containers") {
        let (skin, _) = try makeSkin(t, """
        [Box]
        Meter=Shape
        X=10
        Y=10
        Shape=Rectangle 0,0,100,50 | Fill Color 255,255,255
        [Inside]
        Meter=Image
        Container=Box
        X=10
        Y=10
        W=30
        H=20
        MacGlass=Regular
        [Across]
        Meter=Image
        Container=Box
        X=80
        Y=10
        W=40
        H=20
        MacGlass=Regular
        [Outside]
        Meter=Image
        Container=Box
        X=200
        Y=10
        W=40
        H=20
        MacGlass=Regular
        [Frame]
        Meter=Shape
        X=150
        Shape=Rectangle 0,0,40,40,6
        [Content]
        Meter=Image
        Container=Frame
        W=40
        H=40
        [GlassFrame]
        Meter=Shape
        X=150
        Y=60
        Shape=Rectangle 0,0,40,40,6
        MacGlass=Clear
        [GlassContent]
        Meter=Image
        Container=GlassFrame
        W=40
        H=40
        SolidColor=255,0,0
        """)
        skin.update()
        t.equal(region(skin, "Inside")?.rect, SkinRect(x: 20, y: 20, width: 30, height: 20))
        t.equal(region(skin, "Inside")?.clip, nil, "inside its container: nothing to cut off")
        t.equal(region(skin, "Across")?.rect, SkinRect(x: 90, y: 20, width: 40, height: 20))
        t.equal(region(skin, "Across")?.clip, skin.meter(named: "Box")?.frame, "cut off at the container's frame")
        t.equal(region(skin, "Outside"), nil, "entirely outside its container")
        t.equal(region(skin, "GlassFrame")?.rect, SkinRect(x: 150, y: 60, width: 40, height: 40),
                "a container's own glass: the container is not drawn, but its area shows its content")
        t.equal(region(skin, "GlassFrame")?.style, .clear)
        skin.execute("[!HideMeter Box][!Redraw]", from: nil)
        t.equal(region(skin, "Inside"), nil, "a hidden container hides its content's glass")
        t.equal(region(skin, "Across"), nil)
    }

    t.suite("Glass: Shape rectangles") {
        let (skin, _) = try makeSkin(t, """
        [S1]
        Meter=Shape
        X=10
        Y=20
        Padding=5,5,0,0
        Shape=Rectangle 2,3,60,40,8 | StrokeWidth 2
        Shape2=Ellipse 0,0,100
        MacGlass=Regular
        [S2]
        Meter=Shape
        X=10
        Y=100
        Shape=Rectangle 2,3,60,40,8
        MacGlass=Regular
        MacGlassCornerRadius=3
        [S3]
        Meter=Shape
        X=100
        Y=100
        Shape=Rectangle 0,0,60,40,10 | Rotate 45
        MacGlass=Regular
        [S4]
        Meter=Shape
        X=200
        Y=100
        Shape=Rectangle 0,0,60,40,10 | Offset 5,7
        MacGlass=Regular
        [S5]
        Meter=Shape
        X=300
        Y=100
        Shape=Ellipse 20,20,20
        MacGlass=Regular
        [S6]
        Meter=Shape
        X=400
        Y=100
        Shape=Rectangle 60,40,-60,-40,10,4
        MacGlass=Clear
        [S7]
        Meter=Shape
        X=500
        Y=100
        Shape=Rectangle 0,0,60,40 | Scale 2,1
        MacGlass=Regular
        [S8]
        Meter=Shape
        X=600
        Y=100
        Shape=Rectangle 0,0,60,40,10,0
        MacGlass=Regular
        """)
        skin.update()
        let s1 = skin.meter(named: "S1") as? ShapeMeter
        t.equal(s1?.shapes.first?.rectangle, ShapeRectangle(x: 2, y: 3, width: 60, height: 40, radiusX: 8))
        t.equal(s1?.shapes.last?.rectangle, nil, "only rectangles")
        t.equal(region(skin, "S1")?.rect, SkinRect(x: 17, y: 28, width: 60, height: 40),
                "the first shape's rectangle, from the content origin (after Padding)")
        t.equal(region(skin, "S1")?.cornerRadius, 8, "and its corners")
        t.equal(region(skin, "S2")?.rect, SkinRect(x: 12, y: 103, width: 60, height: 40))
        t.equal(region(skin, "S2")?.cornerRadius, 3, "MacGlassCornerRadius wins")
        let frame3 = skin.meter(named: "S3")?.frame
        t.equal(region(skin, "S3")?.rect, frame3, "a turned rectangle: the meter's frame")
        t.equal(region(skin, "S3")?.cornerRadius, 0)
        t.equal(region(skin, "S4")?.rect, SkinRect(x: 205, y: 107, width: 60, height: 40), "Offset moves it")
        t.equal(region(skin, "S4")?.cornerRadius, 10)
        t.equal(region(skin, "S5")?.rect, skin.meter(named: "S5")?.frame, "not a rectangle: the meter's frame")
        t.equal(region(skin, "S6")?.rect, SkinRect(x: 400, y: 100, width: 60, height: 40), "turned around")
        t.equal(region(skin, "S6")?.cornerRadius, 4, "the smaller radius")
        t.equal(region(skin, "S7")?.rect, skin.meter(named: "S7")?.frame, "scaled: the meter's frame")
        t.equal(region(skin, "S8")?.cornerRadius, 0, "square corners, as drawn")
        t.equal(ShapeRectangle(x: 0, y: 0, width: 10, height: 30, radiusX: 20).radiusX, 5, "limited like the drawing")
    }

    t.suite("Glass: follows DynamicVariables and !SetOption") {
        let (skin, host) = try makeSkin(t, """
        [Variables]
        Glass=Regular
        R=4
        Skin=None
        [Rainmeter]
        MacGlass=#Skin#
        [Card]
        Meter=Image
        W=100
        H=50
        MacGlass=#Glass#
        MacGlassCornerRadius=#R#
        DynamicVariables=1
        [Static]
        Meter=Image
        Y=60
        W=20
        H=20
        MacGlass=Regular
        """)
        skin.update()
        t.equal(skin.glassRegions.map(\.id), ["Card", "Static"])
        t.equal(region(skin, "Card")?.cornerRadius, 4)
        t.equal(host.glassChanges.count, 1)
        skin.execute("[!SetVariable R 10]", from: nil)
        skin.update()
        t.equal(region(skin, "Card")?.cornerRadius, 10, "DynamicVariables")
        t.equal(host.glassChanges.count, 2)
        skin.execute("[!SetVariable Glass None]", from: nil)
        skin.update()
        t.equal(skin.glassRegions.map(\.id), ["Static"], "turned off")
        skin.execute("[!SetVariable Glass Clear]", from: nil)
        skin.update()
        t.equal(region(skin, "Card")?.style, .clear, "turned on again")
        skin.execute("[!SetOption Static MacGlass Clear]", from: nil)
        skin.update()
        t.equal(region(skin, "Static")?.style, .clear, "!SetOption")
        skin.execute("[!SetOption Static MacGlass None][!SetOption Card MacGlass None]", from: nil)
        skin.update()
        t.equal(skin.glassRegions, [], "!SetOption turns it off")
        let changes = host.glassChanges.count
        t.equal(host.glassChanges.last ?? [GlassRegion(id: "x", rect: SkinRect())], [], "the host hears it is gone")
        skin.execute("[!SetOption Static MacGlass Regular]", from: nil)
        skin.update()
        t.equal(region(skin, "Static")?.style, .regular, "and on again")
        t.equal(host.glassChanges.count, changes + 1)
        skin.execute("[!SetOption Static MacGlass \"\"]", from: nil)
        skin.update()
        t.equal(region(skin, "Static"), nil, "an option removed with !SetOption is its default: None")

        // [Rainmeter]: read again at every redraw, like ContextTitle; !SetOption may change it.
        skin.execute("[!SetVariable Skin Clear][!Redraw]", from: nil)
        t.equal(region(skin, "Rainmeter")?.style, .clear, "variables in [Rainmeter] apply at the next redraw")
        t.equal(region(skin, "Rainmeter")?.rect, SkinRect(x: 0, y: 0, width: 100, height: 80))
        skin.execute("[!SetOption Rainmeter MacGlass Regular][!SetOption Rainmeter MacGlassCornerRadius 12]"
                     + "[!SetOption Rainmeter MacGlassTint 255,0,0][!Redraw]", from: nil)
        t.equal(region(skin, "Rainmeter"), GlassRegion(id: "Rainmeter", rect: SkinRect(x: 0, y: 0, width: 100, height: 80),
                                                        cornerRadius: 12, style: .regular,
                                                        tint: RGBA(r: 255, g: 0, b: 0, a: 255)))
        t.check(!host.logs.contains { $0.contains("!SetOption cannot change") }, "accepted in [Rainmeter]")
        skin.execute("[!SetOption Rainmeter MacGlass None][!Redraw]", from: nil)
        t.equal(region(skin, "Rainmeter"), nil)
        skin.execute("[!SetOption Rainmeter Update 50]", from: nil)
        t.check(host.logs.contains { $0.contains("!SetOption cannot change Update") }, "other [Rainmeter] options stay fixed")
    }

    t.suite("Glass: at most maxRegions") {
        var ini = "[Rainmeter]\nMacGlass=Regular\n"
        for i in 0..<(GlassRegion.maxRegions + 6) { ini += "[M\(i)]\nMeter=Image\nX=\(i * 2)\nW=10\nH=10\nMacGlass=Clear\n" }
        let (skin, host) = try makeSkin(t, ini)
        skin.update()
        t.equal(skin.glassRegions.count, GlassRegion.maxRegions)
        t.equal(skin.glassRegions.first?.id, "Rainmeter")
        t.equal(skin.glassRegions.last?.id, "M\(GlassRegion.maxRegions - 2)")
        skin.update()
        t.equal(host.logs.filter { $0.contains("meters with MacGlass") }.count, 1)
    }

    t.suite("Glass: the editor lists the options the engine reads") {
        typealias S = EditorSchema
        for type in S.meterTypes {
            let groups = S.meterGroups(type)
            guard let style = S.property("MacGlass", in: groups) else {
                t.check(false, "\(type): MacGlass")
                continue
            }
            t.equal(style.label, "Glass")
            t.equal(style.defaultValue, "None")
            if case .choice(let choices, let kind) = style.kind {
                t.equal(choices.map(\.value), ["None"] + GlassStyle.allCases.map(\.rawValue), "\(type): every style")
                t.equal(kind, .popup)
            } else {
                t.check(false, "\(type): a menu")
            }
            t.equal(S.property("MacGlassCornerRadius", in: groups)?.label, "Glass corner radius")
            t.equal(S.property("MacGlassTint", in: groups)?.kind, .color)
            t.equal(S.property("MacGlassTint", in: groups)?.label, "Glass tint")
            let radius = S.property("MacGlassCornerRadius", in: groups)!
            t.check(!S.isVisible(radius, in: groups, values: { _ in nil }), "\(type): the radius only with glass")
            t.check(S.isVisible(radius, in: groups, values: { $0 == "MacGlass" ? "clear" : nil }), "\(type): any case")
            // The engine reads what the editor writes.
            let (skin, _) = try makeSkin(t, "[M]\nMeter=\(type)\nW=40\nH=30\nMacGlass=Clear\nMacGlassCornerRadius=7\n"
                                        + "MacGlassTint=1,2,3,4\n")
            skin.update()
            t.equal(skin.meter(named: "M")?.glass, GlassOptions(style: .clear, cornerRadius: 7, tint: RGBA(r: 1, g: 2, b: 3, a: 4)),
                    "\(type): read by the engine")
        }
        t.equal(S.property("MacGlass", in: S.meterGroups("String"))?.level, .essential, "shown in Box Behind It")
        t.equal(S.property("MacGlassCornerRadius", in: S.meterGroups("Shape"))?.placeholder, "the rectangle's corners")
        let widget = S.skinGroups
        t.equal(S.property("MacGlass", in: widget)?.label, "Glass")
        t.check(S.keys(widget).isSuperset(of: ["macglass", "macglasscornerradius", "macglasstint"]))
        let (skin, _) = try makeSkin(t, "[Rainmeter]\nMacGlass=Regular\nMacGlassTint=10,20,30\n[M]\nMeter=Image\nW=10\nH=10\n")
        skin.update()
        t.equal(skin.glassRegions.first?.tint, RGBA(r: 10, g: 20, b: 30, a: 255), "read by the engine in [Rainmeter]")
        // The layer list calls a see-through block with glass what it is.
        let (named, _) = try makeSkin(t, "[T]\nMeter=String\nX=200\nText=Hi\n[G]\nMeter=Image\nX=10\nY=10\nW=130\nH=104\n"
                                     + "MacGlass=Clear\n[C]\nMeter=Image\nW=4\nH=4\nSolidColor=255,255,255\nMacGlass=Clear\n")
        named.update()
        t.equal(named.meter(named: "G").map { LayerNaming.layer($0, in: named).sentence }, "A 130 × 104 glass block.")
        t.equal(named.meter(named: "C").map { LayerNaming.layer($0, in: named).sentence }, "A 4 × 4 white block.",
                "a colored block keeps its color's name")
    }

    t.suite("Glass: skins without glass never tell the host") {
        let (skin, host) = try makeSkin(t, "[A]\nMeter=String\nText=Hi\n[B]\nMeter=Shape\nShape=Rectangle 0,0,10,10,2\n")
        skin.update()
        skin.redraw()
        skin.update()
        t.equal(host.glassChanges.count, 0)
        t.equal(skin.glassRegions, [])
    }
}
