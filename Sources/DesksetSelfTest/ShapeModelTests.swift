import Foundation
@testable import DesksetCore

func runShapeModelTests(_ t: TestRunner) {
    /// The engine's shapes for a meter's shape options (`lookup` answers named options such as gradients / paths).
    func engineItems(_ options: [(Int, String)], lookup: [String: String] = [:]) -> [ShapeItem] {
        var parser = ShapeParser(lookup: { key in lookup.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value })
        return parser.items(from: options.map { (index: $0.0, value: $0.1) })
    }
    func engineItem(_ value: String, lookup: [String: String] = [:]) -> ShapeItem? {
        engineItems([(1, value)], lookup: lookup).first
    }
    func pathPoints(_ item: ShapeItem?) -> [ShapePoint] {
        guard case .path(let p)? = item?.geometry, let sub = p.subpaths.first else { return [] }
        return [sub.start] + sub.segments.map(\.kind.end)
    }

    t.suite("ShapeModel: parsing keeps every parameter as written") {
        guard let s = ShapeSpec.parse("Rectangle 0.5,0.5,(#PanelWidth# - 1),(#PanelHeight# - 1),#PanelRadius# | Fill LinearGradient PanelFill | StrokeWidth 1 | Stroke Color #PanelBorder#")
        else { return t.check(false, "parses") }
        t.equal(s.kind, .rectangle)
        t.equal(s.params, ["0.5", "0.5", "(#PanelWidth# - 1)", "(#PanelHeight# - 1)", "#PanelRadius#"])
        t.equal(s.modifiers, [.fill(.linearGradient("PanelFill", linearLight: false)), .strokeWidth("1"),
                              .stroke(.color("#PanelBorder#"))])
        t.equal(s.rectangle, ShapeSpec.RectangleGeometry(x: "0.5", y: "0.5", width: "(#PanelWidth# - 1)",
                                                         height: "(#PanelHeight# - 1)", radiusX: "#PanelRadius#"))
        t.equal(s.fill, .linearGradient("PanelFill", linearLight: false))
        t.equal(s.strokeWidth, "1")

        let empty = ShapeSpec.parse("Rectangle ,,288,110,8 | Fill Color 40,48,64")
        t.equal(empty?.params, ["", "", "288", "110", "8"], "empty required items stay")
        t.equal(empty?.param(0), nil)
        t.equal(empty?.problem, nil, "the engine draws empty required parameters as 0")

        let arc = ShapeSpec.parse("Arc 120,40,160,0,*,*,*,1 | StrokeWidth 3")
        t.equal(arc?.arc?.radiusX, nil, "* is the default")
        t.equal(arc?.arc?.isCounterClockwise, true)
        t.equal(arc?.arc?.isLarge, false)
        t.equal(arc?.isClosed, false)

        let quad = ShapeSpec.parse("Curve 0,40,60,40,30,-10,0")?.curve
        t.equal(quad?.isCubic, false)
        t.equal(quad?.shapeEnding, "0")
        let cubic = ShapeSpec.parse("Curve 70,40,130,0,70,0,130,40,1")?.curve
        t.equal(cubic?.isCubic, true)
        t.equal(cubic?.controlX2, "130")
        t.equal(cubic?.isClosed, true)

        let combine = ShapeSpec.parse("Combine Shape | Exclude Shape2 | Rotate 10 | Consume 0")
        t.equal(combine?.combineParent, "Shape")
        t.equal(combine?.combineSteps, [ShapeSpec.CombineStep(.exclude, "Shape2")])
        t.equal(combine?.modifiers.last, .consume("0"))
        t.equal(ShapeSpec.parse("Rectangle 0,0,10,10 | Union Shape2")?.modifiers, [.unknown("Union Shape2")],
                "Combine steps only on a Combine shape")

        t.equal(ShapeSpec.parse("Path Star | Fill Color #Accent#")?.pathOption, "Star")
        t.equal(ShapeSpec.parse("Path1 Star")?.kind, .path1)
        t.equal(ShapeSpec.parse("aaaa 1,2,3"), nil, "unknown type")
        // An unknown type word, read anyway for the editor: the rest parses as usual, the word is written back.
        if let typo = ShapeSpec.parse("aaaa 0,0 , 40,20 | Fill Color 255,0,0,255 | StrokeWidth 2", allowingUnknownType: true) {
            t.equal(typo.unknownType, "aaaa")
            t.equal(typo.params, ["0", "0", "40", "20"])
            t.equal(typo.fill, .color("255,0,0,255"), "modifiers read as usual")
            t.equal(typo.text, "aaaa 0,0,40,20 | Fill Color 255,0,0,255 | StrokeWidth 2", "the word is kept as written")
            t.equal(typo.problem, "“aaaa” is not a shape type — nothing is drawn")
            var edited = typo
            edited.setStrokeWidth("0")
            t.equal(edited.text, "aaaa 0,0,40,20 | Fill Color 255,0,0,255 | StrokeWidth 0", "a modifier edit keeps the word")
            let fixed = typo.withType(.rectangle)
            t.equal(fixed.unknownType, nil)
            t.equal(fixed.kind, .rectangle)
            t.equal(fixed.text, "Rectangle 0,0,40,20 | Fill Color 255,0,0,255 | StrokeWidth 2",
                    "choosing a type rewrites only the word: parameters and modifiers stay")
            t.equal(fixed.problem, nil)
            t.equal(typo.converted(to: .ellipse).text, "Ellipse 0,0,40,20 | Fill Color 255,0,0,255 | StrokeWidth 2",
                    "no geometry conversion from a type that never was")
            t.equal(ShapeSpec.parse("Oops Shape2 | Union Shape3", allowingUnknownType: true)?.withType(.combine).combineSteps,
                    [ShapeSpec.CombineStep(.union, "Shape3")], "reread as the new type (Combine steps)")
        } else {
            t.check(false, "an unknown type word is read with allowingUnknownType")
        }
        t.equal(ShapeSpec.parse("(1,2) | Fill Color 1,2,3", allowingUnknownType: true), nil, "not a word: still unreadable")
        t.equal(ShapeSpec.parse("12 0,0", allowingUnknownType: true), nil, "a number is not a type word")
        t.equal(ShapeSpec.parse("Rectangle 1,2,3,4", allowingUnknownType: true)?.unknownType, nil)
        t.equal(ShapeSpec.parse("   "), nil)
        t.equal(ShapeSpec.parse("rectangle 1,2,3,4")?.kind, .rectangle, "keywords are case-insensitive")
    }

    t.suite("ShapeModel: every modifier") {
        let raw = "Ellipse 20,20,10 | Fill Color 255,0,0,128 | Stroke RadialGradient1 R | StrokeWidth 2 | StrokeDashes 2,1,3 | StrokeDashOffset 0.5 | StrokeDashCap Round | StrokeStartCap Square | StrokeEndCap Triangle | StrokeLineJoin MiterOrBevel, 4 | StrokeType Outer | Rotate 45,10,10 | Scale 1.5 | Skew 10,0,5,5 | Offset 3,4 | TransformOrder Offset, Rotate | Extend A, B | Wobble 3"
        guard let s = ShapeSpec.parse(raw) else { return t.check(false, "parses") }
        t.equal(s.modifiers, [
            .fill(.color("255,0,0,128")), .stroke(.radialGradient("R", linearLight: true)), .strokeWidth("2"),
            .strokeDashes(["2", "1", "3"]), .strokeDashOffset("0.5"), .strokeDashCap(.round), .strokeStartCap(.square),
            .strokeEndCap(.triangle), .strokeLineJoin(.miterOrBevel, miterLimit: "4"), .strokeType(.outer),
            .rotate(angle: "45", anchorX: "10", anchorY: "10"), .scale(x: "1.5", y: nil, anchorX: nil, anchorY: nil),
            .skew(x: "10", y: "0", anchorX: "5", anchorY: "5"), .offset(x: "3", y: "4"),
            .transformOrder([.offset, .rotate]), .extend(["A", "B"]), .unknown("Wobble 3"),
        ])
        t.equal(s.text, "Ellipse 20,20,10 | Fill Color 255,0,0,128 | Stroke RadialGradient1 R | StrokeWidth 2 | StrokeDashes 2,1,3 | StrokeDashOffset 0.5 | StrokeDashCap Round | StrokeStartCap Square | StrokeEndCap Triangle | StrokeLineJoin MiterOrBevel,4 | StrokeType Outer | Rotate 45,10,10 | Scale 1.5 | Skew 10,0,5,5 | Offset 3,4 | TransformOrder Offset,Rotate | Extend A,B | Wobble 3")
        // Canonical text of each modifier, when written fresh.
        for m in s.modifiers { t.equal(ShapeSpec.Modifier.parse(m.text, combine: false), m, m.text) }

        // Other spellings the engine reads.
        let spellings: [(String, ShapeSpec.Modifier)] = [
            ("Fill 255,0,0", .fill(.color("255,0,0"))),
            ("FillColor 1,2,3", .fill(.color("1,2,3"))),
            ("StrokeColor 0,200,0,255", .stroke(.color("0,200,0,255"))),
            ("fill color #Warm#", .fill(.color("#Warm#"))),
            ("StrokeLineJoin MeterOrBevel", .strokeLineJoin(.miterOrBevel, miterLimit: nil)),
            ("StrokeType Centre", .strokeType(.center)),
            ("StrokeType inside", .strokeType(.inner)),
            ("strokestartcap ROUND", .strokeStartCap(.round)),
            ("StrokeStartCap Pointy", .unknown("StrokeStartCap Pointy")),
            ("Rotate 1,2,3,4", .unknown("Rotate 1,2,3,4")),
            ("Fill", .unknown("Fill")),
        ]
        for (text, expected) in spellings {
            let spec = ShapeSpec.parse("Line 0,0,1,1 | " + text)
            t.equal(spec?.modifiers, [expected], text)
            t.equal(spec?.text, "Line 0,0,1,1 | " + text, "kept as written: \(text)")
        }
        t.equal(ShapeSpec.Paint.color("0,0,255").rgba, RGBA(r: 0, g: 0, b: 255))
        t.equal(ShapeSpec.Paint.color("#C#").rgba, nil)
    }

    t.suite("ShapeModel: whitespace normalisation") {
        let cases: [(String, String)] = [
            ("Rectangle  0 , 0 ,100, 40 |Fill   Color 255, 0,0|  StrokeWidth 2", "Rectangle 0,0,100,40 | Fill Color 255,0,0 | StrokeWidth 2"),
            ("Ellipse (#A#  +  1),2,3 ||", "Ellipse (#A#  +  1),2,3"),
            ("Line 0,0,1,1 | | Stroke Color 1,2,3 |", "Line 0,0,1,1 | Stroke Color 1,2,3"),
            ("\tRectangle 0,0,10,10\t", "Rectangle 0,0,10,10"),
            ("Rectangle (Max(3, 4)),0,10,10", "Rectangle (Max(3, 4)),0,10,10"),
            // The space after the keyword stays before an empty first parameter (the canonical spelling).
            ("Rectangle  , ,100,50,8", "Rectangle ,,100,50,8"),
            ("Rectangle,,100,50,8 | Offset ,5", "Rectangle,,100,50,8 | Offset ,5"),
        ]
        for (raw, normalized) in cases {
            t.equal(ShapeSpec.normalized(raw), normalized, raw)
            t.equal(ShapeSpec.parse(raw)?.text, normalized, raw)
            t.equal(ShapeSpec.parse(normalized), ShapeSpec.parse(raw), raw)
        }
        t.equal(GradientSpec.normalized("180 |255,0,0;0.0|   0,0,255 ; 1 "), "180 | 255,0,0 ; 0.0 | 0,0,255 ; 1")
        t.equal(PathSpec.normalized("0, 0 |LineTo 10 , 0|ClosePath"), "0,0 | LineTo 10,0 | ClosePath")
    }

    t.suite("ShapeModel: round trip of the bundled and test skins") {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var files: [URL] = []
        for folder in ["DefaultSkins", "TestSkins"] {
            let root = repo.appendingPathComponent(folder)
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = e?.nextObject() as? URL {
                if ["ini", "inc"].contains(url.pathExtension.lowercased()) { files.append(url) }
            }
        }
        var shapes = 0, gradients = 0, paths = 0, meters = 0
        for url in files {
            guard let decoded = try? TextDecoding.readFileDetectingEncoding(at: url) else { continue }
            let doc = IniDocument.parse(decoded.0)
            // Gradient and path options may be defined in the meter or in a style of the same file.
            var gradientNames: Set<String> = [], pathNames: Set<String> = []
            for section in doc.sections {
                let options = section.entries.compactMap { e -> (Int, String)? in
                    guard let i = ShapeSpec.index(ofOption: e.key), e.key.lowercased() != "shape1" else { return nil }
                    return (i, e.value)
                }
                guard !options.isEmpty else { continue }
                meters += 1
                var lookup: [String: String] = [:]
                for e in section.entries where lookup[e.key] == nil { lookup[e.key] = e.value }
                let place = "\(url.lastPathComponent) [\(section.name)]"
                var rewritten: [(Int, String)] = []
                for (index, value) in options {
                    guard let spec = ShapeSpec.parse(value) else {
                        // Only values the engine skips as well (a test of an unknown type).
                        t.check(ShapeSpec.problem(in: value) != nil, "\(place): \(value)")
                        rewritten.append((index, value))
                        continue
                    }
                    shapes += 1
                    t.equal(spec.text, ShapeSpec.normalized(value), "\(place): untouched text")
                    t.equal(ShapeSpec.parse(spec.text), spec, "\(place): parse → text → parse")
                    rewritten.append((index, spec.text))
                    for m in spec.modifiers {
                        switch m {
                        case .fill(let p), .stroke(let p): if let n = p.gradientOption { gradientNames.insert(n.lowercased()) }
                        default: break
                        }
                    }
                    if let n = spec.pathOption { pathNames.insert(n.lowercased()) }
                }
                // The engine draws exactly the same from the written-back values.
                t.equal(engineItems(rewritten, lookup: lookup), engineItems(options, lookup: lookup), "\(place): engine")
            }
            for section in doc.sections {
                for e in section.entries {
                    let place = "\(url.lastPathComponent) [\(section.name)] \(e.key)"
                    if gradientNames.contains(e.key.lowercased()), let g = GradientSpec.parse(e.value) {
                        gradients += 1
                        t.equal(g.text, GradientSpec.normalized(e.value), "\(place): gradient text")
                        t.equal(GradientSpec.parse(g.text), g, "\(place): gradient round trip")
                        var lookup = ["G": e.value]
                        let before = engineItem("Rectangle 0,0,10,10 | Fill LinearGradient G", lookup: lookup)
                        lookup["G"] = g.text
                        t.equal(engineItem("Rectangle 0,0,10,10 | Fill LinearGradient G", lookup: lookup), before, place)
                    }
                    if pathNames.contains(e.key.lowercased()), let p = PathSpec.parse(e.value) {
                        paths += 1
                        t.equal(p.text, PathSpec.normalized(e.value), "\(place): path text")
                        t.equal(PathSpec.parse(p.text), p, "\(place): path round trip")
                        t.equal(engineItem("Path P", lookup: ["P": p.text]), engineItem("Path P", lookup: ["P": e.value]), place)
                    }
                }
            }
        }
        print("    (\(shapes) shapes, \(gradients) gradients and \(paths) paths of \(meters) meters round-tripped)")
        t.check(meters >= 20, "shape meters found: \(meters)")
        t.check(shapes >= 150, "shapes checked: \(shapes)")
        t.check(gradients >= 20, "gradients checked: \(gradients)")
        t.check(paths >= 10, "paths checked: \(paths)")
    }

    t.suite("ShapeModel: edits keep the rest as written") {
        guard var s = ShapeSpec.parse("rectangle 0,0,60,40,12 | fill color #Warm# | StrokeWidth  2 | Offset 5,0")
        else { return t.check(false, "parses") }
        s.setStrokeWidth("3")
        t.equal(s.text, "rectangle 0,0,60,40,12 | fill color #Warm# | StrokeWidth 3 | Offset 5,0")
        s.rectangle?.width = "80"
        t.equal(s.text, "Rectangle 0,0,80,40,12 | fill color #Warm# | StrokeWidth 3 | Offset 5,0")
        s.setFill(.color("255,0,0"))
        t.equal(s.text, "Rectangle 0,0,80,40,12 | Fill Color 255,0,0 | StrokeWidth 3 | Offset 5,0")
        s.setStroke(.color("0,0,0,128"))
        t.equal(s.text, "Rectangle 0,0,80,40,12 | Fill Color 255,0,0 | StrokeWidth 3 | Offset 5,0 | Stroke Color 0,0,0,128")
        s.setStrokeWidth(nil)
        s.setOffset(nil)
        t.equal(s.text, "Rectangle 0,0,80,40,12 | Fill Color 255,0,0 | Stroke Color 0,0,0,128")
        // Reordering untouched modifiers keeps their spelling.
        s = ShapeSpec.parse("Line 0,0,1,1 | stroke color 1,2,3 | strokewidth 4")!
        s.modifiers.reverse()
        t.equal(s.text, "Line 0,0,1,1 | strokewidth 4 | stroke color 1,2,3")

        // The last modifier of a slot wins; setting one replaces it and drops the earlier ones.
        s = ShapeSpec.parse("Rectangle 0,0,10,10 | Fill Color 1,1,1 | StrokeWidth 2 | Fill Color 2,2,2")!
        t.equal(s.fill, .color("2,2,2"))
        s.setFill(.linearGradient("G", linearLight: false))
        t.equal(s.text, "Rectangle 0,0,10,10 | StrokeWidth 2 | Fill LinearGradient G")

        // Radius Y without radius X: the gap is written as the engine's "default".
        s = ShapeSpec.parse("Rectangle 0,0,10,10")!
        s.rectangle?.radiusY = "3"
        t.equal(s.text, "Rectangle 0,0,10,10,*,3")
        s.rectangle?.radiusY = nil
        t.equal(s.text, "Rectangle 0,0,10,10", "trailing defaults are dropped")
        s.setParam(4, "5")
        t.equal(s.params, ["0", "0", "10", "10", "5"])

        var arc = ShapeSpec.parse("Arc 120,40,160,0,*,*,*,1")!
        arc.arc?.isLarge = true
        t.equal(arc.text, "Arc 120,40,160,0,*,*,*,1,1")
        arc.arc?.isCounterClockwise = false
        arc.arc?.isLarge = false
        t.equal(arc.text, "Arc 120,40,160,0")

        var curve = ShapeSpec.parse("Curve 0,40,60,40,30,-10")!
        curve.curve?.controlX2 = "40"
        curve.curve?.controlY2 = "50"
        curve.curve?.isClosed = true
        t.equal(curve.text, "Curve 0,40,60,40,30,-10,40,50,1")
    }

    t.suite("ShapeModel: edits give the intended geometry in the engine") {
        var s = ShapeSpec.parse("Rectangle 10,20,100,40 | StrokeWidth 0")!
        s.rectangle?.height = "60"
        t.equal(engineItem(s.text)?.bounds, ShapeRect(minX: 10, minY: 20, maxX: 110, maxY: 80))

        let ellipse = s.converted(to: .ellipse)
        t.equal(ellipse.text, "Ellipse 60,50,50,30 | StrokeWidth 0")
        t.equal(engineItem(ellipse.text)?.bounds, ShapeRect(minX: 10, minY: 20, maxX: 110, maxY: 80), "same box")
        let line = s.converted(to: .line)
        t.equal(line.text, "Line 10,20,110,80 | StrokeWidth 0")
        t.equal(pathPoints(engineItem(line.text)), [ShapePoint(10, 20), ShapePoint(110, 80)])
        t.equal(engineItem(line.text)?.fill, ShapePaint.none, "open: no fill")
        t.equal(line.converted(to: .rectangle).text, "Rectangle 10,20,100,60 | StrokeWidth 0", "back again")
        t.equal(ShapeSpec.parse("Line 110,80,10,20")!.converted(to: .rectangle).params, ["10", "20", "100", "60"],
                "the box is normalised")
        t.equal(ellipse.converted(to: .rectangle).params, ["10", "20", "100", "60"])
        t.equal(ShapeSpec.parse("Ellipse 50,50,40")!.converted(to: .rectangle).params, ["10", "10", "80", "80"])
        t.equal(ShapeSpec.parse("Rectangle 0,0,80,80")!.converted(to: .ellipse).params, ["40", "40", "40"], "a circle")
        let curve = line.converted(to: .curve)
        t.equal(curve.params, ["10", "20", "110", "80", "60", "50"])
        t.equal(pathPoints(engineItem(curve.text)).last, ShapePoint(110, 80))
        t.equal(line.converted(to: .arc).params, ["10", "20", "110", "80"])

        // Formulas and variables are combined into formulas.
        let v = ShapeSpec.parse("Rectangle #X#,0,(#W# * 2),40")!.converted(to: .ellipse)
        t.equal(v.params, ["(#X# + ((#W# * 2) / 2))", "20", "((#W# * 2) / 2)", "20"])
        var withVars = v.text.replacingOccurrences(of: "#X#", with: "10")
        withVars = withVars.replacingOccurrences(of: "#W#", with: "50")
        t.equal(engineItem(withVars)?.bounds, ShapeRect(minX: 10, minY: 0, maxX: 110, maxY: 40))

        // Paths and Combines: the option / parent is chosen afterwards; Combine steps go when leaving Combine.
        let c = ShapeSpec.parse("Combine Shape | Union Shape2 | Offset 5,5")!
        t.equal(c.converted(to: .rectangle).text, "Rectangle 0,0,100,100 | Offset 5,5")
        t.equal(ShapeSpec.parse("Path Star | StrokeWidth 1")!.converted(to: .path1).text, "Path1 Star | StrokeWidth 1")
        t.equal(s.converted(to: .path).text, "Path | StrokeWidth 0")

        // Paint and stroke modifiers reach the engine.
        var m = ShapeSpec.parse("Rectangle 0,0,40,40")!
        m.setFill(.color("255,0,0"))
        m.setStroke(.color("0,0,255,128"))
        m.setStrokeWidth("4")
        m.setStrokeLineJoin(.miter, miterLimit: "4")
        m.setStrokeDashes(["2", "1"])
        m.setStrokeStartCap(.round)
        m.setStrokeType(.inner)
        guard let item = engineItem(m.text) else { return t.check(false, "draws: \(m.text)") }
        t.equal(item.fill, .color(RGBA(r: 255, g: 0, b: 0)))
        t.equal(item.stroke, .color(RGBA(r: 0, g: 0, b: 255, a: 128)))
        t.equal(item.strokeStyle.width, 4)
        t.equal(item.strokeStyle.join, .miter)
        t.equal(item.strokeStyle.miterLimit, 4)
        t.equal(item.strokeStyle.dashes, [2, 1])
        t.equal(item.strokeStyle.startCap, .round)
        t.equal(item.strokeStyle.placement, .inner)
        m.setRotate("90", anchorX: "0", anchorY: "0")
        t.close(engineItem(m.text)?.bounds.minX ?? 0, -40, accuracy: 1e-9, "rotated around the top-left")
        m.setRotate(nil)
        m.setScale("2", "1")
        t.close(engineItem(m.text)?.bounds.width ?? 0, 80, accuracy: 1e-9, "scaled around the center")
        m.setScale(nil)
        m.setOffset("10", "5")
        t.equal(engineItem(m.text)?.bounds, ShapeRect(minX: 10, minY: 5, maxX: 50, maxY: 45))

        // "No fill": transparent for closed shapes, removed for open ones.
        var closed = ShapeSpec.parse("Ellipse 5,5,5")!
        closed.removeFill()
        t.equal(engineItem(closed.text)?.fill.isVisible, false)
        var open = ShapeSpec.parse("Line 0,0,10,10 | Fill Color 1,2,3")!
        open.removeFill()
        t.equal(open.text, "Line 0,0,10,10")

        // Gradients edited in their option.
        var g = GradientSpec.parse("180 | 255,0,0,255 ; 0.0 | 0,0,255,255 ; 1.0")!
        g.angle = "90"
        g.stops[1].color = "0,255,0"
        g.stops.append(GradientSpec.Stop(color: "255,255,255", position: "0.5"))
        t.equal(g.text, "90 | 255,0,0,255 ; 0.0 | 0,255,0 ; 1.0 | 255,255,255 ; 0.5")
        guard case .linearGradient(let lg)? = engineItem("Rectangle 0,0,10,10 | Fill LinearGradient G", lookup: ["G": g.text])?.fill
        else { return t.check(false, "linear gradient") }
        t.equal(lg.stops.map(\.color), [RGBA(r: 255, g: 0, b: 0), RGBA(r: 255, g: 255, b: 255), RGBA(r: 0, g: 255, b: 0)])
        t.close(lg.start.y, 10, accuracy: 1e-9, "90° runs bottom to top")
        var r = GradientSpec.parse("0,0 | 255,255,255 ; 0 | 0,0,0 ; 1")!
        r.setRadial(4, "20")
        t.equal(r.head, ["0", "0", "*", "*", "20"])
        guard case .radialGradient(let rg)? = engineItem("Ellipse 50,50,50 | Fill RadialGradient R", lookup: ["R": r.text])?.fill
        else { return t.check(false, "radial gradient") }
        t.equal(rg.radiusX, 20)
        t.equal(rg.radiusY, 20, "RadiusY follows RadiusX")
        r.setRadial(4, nil)
        t.equal(r.head, ["0", "0"])
        t.equal(GradientSpec.parse("0 | 1,2,3 ; 0 ; extra")?.stops.first?.extraFields, ["extra"])
        t.equal(GradientSpec.parse("0 | 1,2,3 ; 0 ; extra")?.text, "0 | 1,2,3 ; 0 ; extra")

        // Paths edited segment by segment.
        var p = PathSpec.parse("0,0 | lineto 50,0 | LineTo 50,60 | ClosePath 1")!
        t.equal(p.isClosed, true)
        p.segments[1] = .lineTo(["50", "80"])
        t.equal(p.text, "0,0 | lineto 50,0 | LineTo 50,80 | ClosePath 1")
        let drawn = engineItem("Path P | StrokeWidth 0", lookup: ["P": p.text])
        t.equal(drawn?.bounds, ShapeRect(minX: 0, minY: 0, maxX: 50, maxY: 80))
        t.equal(PathSpec.parse("0,0 | LineTo 1,1 | ClosePath")?.isClosed, true, "a bare ClosePath counts as 1")
        t.equal(PathSpec.parse("0,0 | SetNoStroke | Bogus 1")?.segments, [.setNoStroke(nil), .unknown("Bogus 1")])

        // Required parameters are never written as `*` (the engine skips such a shape): clearing one writes 0,
        // filling a gap writes 0 for required positions and `*` for optional ones.
        var cleared = ShapeSpec.parse("Rectangle 5,0,10,10")!
        cleared.setParam(0, nil)
        t.equal(cleared.text, "Rectangle 0,0,10,10")
        t.equal(engineItem(cleared.text)?.bounds, ShapeRect(minX: 0, minY: 0, maxX: 10, maxY: 10))
        var gap = ShapeSpec.parse("Line 0,0")!
        gap.setParam(3, "5")
        t.equal(gap.text, "Line 0,0,0,5")
        t.equal(pathPoints(engineItem(gap.text)), [ShapePoint(0, 0), ShapePoint(0, 5)])
        var bare = ShapeSpec.parse("Rectangle")!
        bare.setParam(4, "5")
        t.equal(bare.text, "Rectangle 0,0,0,0,5", "an all-empty required list would be skipped")
        t.check(engineItem(bare.text) != nil, "draws: \(bare.text)")
        var starred = ShapeSpec.parse("Ellipse *,20,10")!
        t.equal(engineItem(starred.text), nil, "the author's `*` in a required place is skipped by the engine")
        starred.setParam(0, nil)
        t.equal(starred.text, "Ellipse 0,20,10")
        t.equal(engineItem(starred.text)?.bounds, ShapeRect(minX: -10, minY: 10, maxX: 10, maxY: 30))
        var empty = ShapeSpec.parse("Rectangle ,,100,50,8")!
        empty.setParam(1, nil)
        t.equal(empty.text, "Rectangle ,,100,50,8", "an empty required item the author wrote stays")
        empty.setParam(5, "2")
        t.equal(empty.text, "Rectangle ,,100,50,8,2")
        var arcGap = ShapeSpec.parse("Arc 0,0,10,0")!
        arcGap.setParam(6, "45")
        t.equal(arcGap.text, "Arc 0,0,10,0,*,*,45", "optional gaps stay `*`")
        t.check(engineItem(arcGap.text) != nil, "draws: \(arcGap.text)")
    }

    t.suite("ShapeModel: renumbering rewrites Combine references") {
        let options = [ShapeOption("Shape", "Rectangle 0,0,40,40"), ShapeOption("Shape2", "Ellipse 40,40,20"),
                       ShapeOption("Shape3", "Combine  Shape |Exclude Shape2 | Rotate 10"),
                       ShapeOption("Shape4", "Line 0,0,10,10")]
        func items(_ list: [ShapeOption]) -> [ShapeItem] {
            engineItems(list.compactMap { o in ShapeSpec.index(ofOption: o.key).map { ($0, o.value) } })
        }

        // Moving the ellipse to the front of the list: the Combine follows its shapes.
        var r = ShapeSpec.renumber(options, newOrder: ["Shape2", "Shape", "Shape3", "Shape4"])
        t.equal(r.options, [ShapeOption("Shape", "Ellipse 40,40,20"), ShapeOption("Shape2", "Rectangle 0,0,40,40"),
                            ShapeOption("Shape3", "Combine Shape2 | Exclude Shape | Rotate 10"),
                            ShapeOption("Shape4", "Line 0,0,10,10")])
        t.equal(r.removedKeys, [])
        t.equal(r.notes, [])
        t.equal(items(r.options).map(\.geometry), items(options).map(\.geometry), "the engine draws the same")

        // Nothing changes: values are kept byte for byte.
        r = ShapeSpec.renumber(options, newOrder: ["Shape", "Shape2", "Shape3", "Shape4"])
        t.equal(r.options.map(\.value), options.map(\.value))

        // Removing a step's shape drops the step.
        r = ShapeSpec.renumber(options, newOrder: ["Shape", "Shape3", "Shape4"])
        t.equal(r.options, [ShapeOption("Shape", "Rectangle 0,0,40,40"), ShapeOption("Shape2", "Combine Shape | Rotate 10"),
                            ShapeOption("Shape3", "Line 0,0,10,10")])
        t.equal(r.removedKeys, ["Shape4"])
        t.equal(r.notes.count, 1)

        // Removing the parent: the first remaining step's shape becomes the parent.
        r = ShapeSpec.renumber(options, newOrder: ["Shape2", "Shape3"])
        t.equal(r.options, [ShapeOption("Shape", "Ellipse 40,40,20"), ShapeOption("Shape2", "Combine Shape | Rotate 10")])
        t.equal(r.removedKeys, ["Shape3", "Shape4"])
        t.check(r.notes.first?.contains("parent") == true, "\(r.notes)")

        // Removing every shape of a Combine removes it too.
        r = ShapeSpec.renumber(options, newOrder: ["Shape3", "Shape4"])
        t.equal(r.options, [ShapeOption("Shape", "Line 0,0,10,10")])
        t.equal(r.removedKeys, ["Shape2", "Shape3", "Shape4"])
        t.check(r.notes.contains { $0.contains("Combine removed") }, "\(r.notes)")

        // Chains of Combines and references to shapes that are not in the list.
        let chain = [ShapeOption("Shape", "Ellipse 5,5,5"), ShapeOption("Shape2", "Combine Shape | Union Shape"),
                     ShapeOption("Shape3", "Combine Shape2 | Union Shape9")]
        r = ShapeSpec.renumber(chain, newOrder: ["Shape3", "Shape", "Shape2"])
        t.equal(r.options.map(\.value), ["Combine Shape3 | Union Shape9", "Ellipse 5,5,5", "Combine Shape2 | Union Shape2"])
        t.equal(items(r.options).map(\.geometry), items(chain).map(\.geometry))
        r = ShapeSpec.renumber(chain, newOrder: ["Shape2", "Shape3"])
        t.equal(r.options, [], "the chain goes with its only shape")
    }

    t.suite("ShapeModel: problems in plain words") {
        t.equal(ShapeSpec.problem(in: "aaaa 1,2,3"), "“aaaa” is not a shape type — nothing is drawn")
        t.equal(ShapeSpec.problem(in: "Rectangle 0,0,10"), "Rectangle needs x, y, width and height — nothing is drawn")
        t.equal(ShapeSpec.problem(in: "Rectangle a,0,10,10"), "“a” is not a number (x) — nothing is drawn")
        t.equal(ShapeSpec.problem(in: "Rectangle ,,,"), "Rectangle needs numbers — nothing is drawn")
        t.equal(ShapeSpec.problem(in: "Rectangle #Box# | Fill Color 1,2,3"), nil, "a variable may hold the parameters")
        t.equal(ShapeSpec.problem(in: "Ellipse 1,2,(3 * 2)"), nil)
        t.equal(ShapeSpec.problem(in: "Path"), "A path needs the name of its path option — nothing is drawn")
        t.equal(ShapeSpec.problem(in: "Combine"), "Combine needs a parent shape — nothing is drawn")
        t.equal(ShapeSpec.problem(in: "| Fill Color 1,2,3"), "“Fill” is not a shape type — nothing is drawn",
                "empty parts are dropped, like the engine does")
        t.equal(ShapeSpec.problem(in: "(1,2)"), "“(1,2)” is not a shape — nothing is drawn")
        // The engine agrees with each verdict.
        for raw in ["aaaa 1,2,3", "Rectangle 0,0,10", "Rectangle a,0,10,10", "Rectangle ,,,", "Path", "Combine"] {
            t.equal(engineItem(raw), nil, raw)
        }
        t.check(engineItem("Ellipse 1,2,(3 * 2)") != nil)
        t.equal(ShapeSpec.index(ofOption: "shape12"), 12)
        t.equal(ShapeSpec.index(ofOption: "Shapes"), nil)
        t.equal(ShapeSpec.optionKey(1), "Shape")
        t.equal(ShapeSpec.optionKey(3), "Shape3")
    }
}
