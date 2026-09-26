import Foundation
@testable import DesksetCore

func runGraphMeterTests(_ t: TestRunner) {
    func line(_ skin: Skin, _ name: String) -> LineMeter? { skin.meter(named: name) as? LineMeter }
    func histogram(_ skin: Skin, _ name: String) -> HistogramMeter? { skin.meter(named: name) as? HistogramMeter }
    func updates(_ skin: Skin, _ n: Int) { for _ in 0..<n { skin.update() } }

    t.suite("GraphMeter: history ring buffer") {
        var h = GraphHistory(capacity: 3)
        t.equal(h.capacity, 3)
        t.equal(h.count, 0)
        t.close(h.value(age: 0), 0)
        h.append(1)
        h.append(2)
        t.equal(h.count, 2)
        t.close(h.value(age: 0), 2)
        t.close(h.value(age: 1), 1)
        t.close(h.value(age: 2), 0, "unfilled slot reads 0")
        t.close(h.value(age: -1), 0)
        t.close(h.value(age: 99), 0)
        h.append(3)
        h.append(4)
        t.equal(h.samples, [2, 3, 4], "wraps around, newest last")
        h.append(.nan)
        h.append(.infinity)
        t.equal(h.samples, [4, 0, 0], "non-finite samples are stored as 0")
        t.equal(h.extremes?.min, 0)
        t.equal(h.extremes?.max, 4)

        h.resize(to: 5)
        t.equal(h.capacity, 5)
        t.equal(h.samples, [4, 0, 0], "growing keeps every sample")
        h.append(7)
        h.append(8)
        h.append(9)
        t.equal(h.samples, [0, 0, 7, 8, 9])
        h.resize(to: 2)
        t.equal(h.samples, [8, 9], "shrinking keeps the newest samples")
        h.append(10)
        t.equal(h.samples, [9, 10])
        h.resize(to: 0)
        t.equal(h.count, 0)
        h.append(1)
        t.equal(h.count, 0, "capacity 0 records nothing")
        t.check(h.extremes == nil)
        t.close(h.value(age: 0), 0)

        var cleared = GraphHistory(capacity: 2)
        cleared.append(5)
        cleared.removeAll()
        t.equal(cleared.count, 0)
        t.equal(cleared.capacity, 2)

        t.equal(GraphHistory(capacity: -5).capacity, 0)
        t.equal(GraphHistory(capacity: Int.max).capacity, GraphHistory.maxCapacity)
        t.equal(GraphHistory.capacity(forLength: 99.7), 99, "whole pixels")
        t.equal(GraphHistory.capacity(forLength: nil), 0)
        t.equal(GraphHistory.capacity(forLength: .nan), 0)
        t.equal(GraphHistory.capacity(forLength: -.infinity), 0)
        t.equal(GraphHistory.capacity(forLength: 0.5), 0)
        t.equal(GraphHistory.capacity(forLength: 1e300), GraphHistory.maxCapacity)
    }

    t.suite("GraphMeter: geometry for GraphStart / GraphOrientation / Flip") {
        let frame = SkinRect(x: 10, y: 20, width: 100, height: 50)
        var g = GraphGeometry(frame: frame, direction: GraphDirection())
        t.close(g.timeLength, 100)
        t.close(g.valueLength, 50)
        // Default: newest sample at the right edge, values grow upwards; vertices on pixel centers.
        t.close(g.slotStart(age: 0), 109)
        t.close(g.slotStart(age: 99), 10)
        t.check(g.point(age: 0, fraction: 0) == (109.5, 69.5))
        t.check(g.point(age: 0, fraction: 1) == (109.5, 20.5))
        t.check(g.point(age: 99, fraction: 0.5) == (10.5, 45))
        t.check(g.point(age: 0, fraction: 7) == (109.5, 20.5), "fractions are clamped")
        t.check(g.point(age: 0, fraction: .nan) == (109.5, 69.5))
        t.equal(g.column(age: 0, from: 0, to: 25), SkinRect(x: 109, y: 45, width: 1, height: 25))
        t.equal(g.column(age: 1, from: 10, to: 25), SkinRect(x: 108, y: 45, width: 1, height: 15))

        g.direction.startRight = false
        t.close(g.slotStart(age: 0), 10, "GraphStart=Left: newest at the left edge")
        t.check(g.point(age: 0, fraction: 0) == (10.5, 69.5))

        g.direction.flip = true
        t.check(g.point(age: 0, fraction: 0) == (10.5, 20.5), "Flip: values grow from the top")
        t.check(g.point(age: 0, fraction: 1) == (10.5, 69.5))
        t.equal(g.column(age: 0, from: 0, to: 25), SkinRect(x: 10, y: 20, width: 1, height: 25))

        // Horizontal: the vertical graph turned 90° clockwise.
        g = GraphGeometry(frame: frame, direction: GraphDirection(vertical: false))
        t.close(g.timeLength, 50)
        t.close(g.valueLength, 100)
        t.close(g.slotStart(age: 0), 69, "newest sample at the bottom")
        t.check(g.point(age: 0, fraction: 0) == (10.5, 69.5))
        t.check(g.point(age: 0, fraction: 1) == (109.5, 69.5), "values grow to the right")
        t.equal(g.column(age: 0, from: 0, to: 25), SkinRect(x: 10, y: 69, width: 25, height: 1))
        g.direction.startRight = false
        t.close(g.slotStart(age: 0), 20, "GraphStart=Left: newest at the top")
        g.direction.flip = true
        t.check(g.point(age: 0, fraction: 0) == (109.5, 20.5), "Flip: values grow from the right")
        t.equal(g.column(age: 0, from: 0, to: 25), SkinRect(x: 85, y: 20, width: 25, height: 1))

        // Degenerate sizes do not produce NaN.
        let tiny = GraphGeometry(frame: SkinRect(x: 0, y: 0, width: 0, height: 0), direction: GraphDirection())
        let p = tiny.point(age: 3, fraction: 1)
        t.check(p.x.isFinite && p.y.isFinite)
    }

    t.suite("GraphMeter: Line options and defaults") {
        let (skin, _) = try makeSkin(t, """
        [M]
        Measure=Calc
        Formula=1

        [Graph]
        Meter=Line
        MeasureName=M
        W=5
        H=11

        [Custom]
        Meter=Line
        MeasureName=M
        LineCount=2
        LineColor=10,20,30
        LineColor2=40,50,60,70
        LineWidth=2.5
        HorizontalLines=1
        HorizontalLineColor=255,255,255,60
        AutoScale=1
        GraphStart=left
        GraphOrientation= HORIZONTAL
        Flip=1
        TransformStroke=Fixed
        W=20
        H=7
        """)
        skin.update()
        let g = try t.graphUnwrap(line(skin, "Graph"))
        t.equal(g.lines.count, 1)
        t.equal(g.lines[0].color, RGBA.white)
        t.close(g.lines[0].scale, 1)
        t.close(g.lineWidth, 1)
        t.check(!g.horizontalLines)
        t.equal(g.horizontalLineColor, RGBA(r: 0, g: 0, b: 0, a: 255))
        t.check(!g.autoScale)
        t.equal(g.direction, GraphDirection(startRight: true, vertical: true, flip: false))
        t.check(!g.transformStrokeFixed)
        t.equal(g.historyLength, 5, "one sample per pixel of W")

        let c = try t.graphUnwrap(line(skin, "Custom"))
        t.equal(c.lines.map(\.color), [RGBA(r: 10, g: 20, b: 30), RGBA(r: 40, g: 50, b: 60, a: 70)])
        t.check(c.lines[1].measure == nil, "MeasureName2 missing: the second line has no data")
        t.close(c.lineWidth, 2.5)
        t.check(c.horizontalLines)
        t.equal(c.horizontalLineColor, RGBA(r: 255, g: 255, b: 255, a: 60))
        t.check(c.autoScale)
        t.equal(c.direction, GraphDirection(startRight: false, vertical: false, flip: true))
        t.check(c.transformStrokeFixed)
        t.equal(c.historyLength, 7, "horizontal graphs keep one sample per pixel of H")
    }

    t.suite("GraphMeter: Line sampling maps MinValue…MaxValue to the value axis") {
        let (skin, _) = try makeSkin(t, """
        [Saw]
        Measure=Loop
        StartValue=0
        EndValue=100
        Increment=10

        [Graph]
        Meter=Line
        MeasureName=Saw
        X=0
        Y=0
        W=5
        H=11
        """)
        updates(skin, 3)
        let g = try t.graphUnwrap(line(skin, "Graph"))
        t.equal(g.lines[0].history.samples, [0, 10, 20])
        t.close(g.rangeMin, 0)
        t.close(g.rangeMax, 100)
        t.close(g.fraction(line: 0, age: 0), 0.2)
        t.close(g.fraction(line: 0, age: 1), 0.1)
        t.close(g.fraction(line: 0, age: 4), 0, "unfilled slots read 0")
        t.close(g.fraction(line: 5, age: 0), 0, "unknown line")
        let p = g.point(line: 0, age: 0)
        t.close(p.x, 4.5)
        t.close(p.y, 11 - 0.5 - 0.2 * 10)
        t.close(g.point(line: 0, age: 4).x, 0.5)
        updates(skin, 5)
        t.equal(g.lines[0].history.samples, [30, 40, 50, 60, 70], "history length = W, oldest dropped")
    }

    t.suite("GraphMeter: Line scale is the largest MaxValue; ScaleN; AutoScale ignores Scale") {
        let (skin, _) = try makeSkin(t, """
        [A]
        Measure=Calc
        Formula=50
        MaxValue=100

        [B]
        Measure=Calc
        Formula=25
        MaxValue=200

        [Signed]
        Measure=Calc
        Formula=0
        MinValue=-1
        MaxValue=1

        [Graph]
        Meter=Line
        LineCount=2
        MeasureName=A
        MeasureName2=B
        Scale2=2
        W=10
        H=10

        [SignedGraph]
        Meter=Line
        MeasureName=Signed
        W=10
        H=10
        """)
        skin.update()
        let g = try t.graphUnwrap(line(skin, "Graph"))
        t.close(g.rangeMax, 200, "largest MaxValue of the measures used")
        t.close(g.fraction(line: 0, age: 0), 0.25)
        t.close(g.fraction(line: 1, age: 0), 0.25, "25 × Scale2 2 of 200")
        t.close(try t.graphUnwrap(line(skin, "SignedGraph")).fraction(line: 0, age: 0), 0.5, "MinValue is applied")

        skin.execute("[!SetOption Graph AutoScale 1]", from: nil)
        skin.update()
        t.check(g.autoScale)
        t.close(g.rangeMax, 50, "AutoScale: largest recorded value")
        t.close(g.fraction(line: 0, age: 0), 1)
        t.close(g.fraction(line: 1, age: 0), 0.5, "Scale is ignored with AutoScale")
    }

    t.suite("GraphMeter: Line AutoScale follows the visible history") {
        let (skin, _) = try makeSkin(t, """
        [Saw]
        Measure=Loop
        StartValue=0
        EndValue=100
        Increment=10

        [Zero]
        Measure=Calc
        Formula=0

        [Graph]
        Meter=Line
        MeasureName=Saw
        AutoScale=1
        W=4
        H=10

        [Flat]
        Meter=Line
        MeasureName=Zero
        AutoScale=1
        W=4
        H=10
        """)
        updates(skin, 5)  // 0 10 20 30 40 → visible 10 20 30 40
        let g = try t.graphUnwrap(line(skin, "Graph"))
        t.close(g.rangeMin, 0)
        t.close(g.rangeMax, 40)
        t.close(g.fraction(line: 0, age: 0), 1)
        t.close(g.fraction(line: 0, age: 3), 0.25)
        updates(skin, 7)  // … 110 wraps: 80 90 100 0
        t.equal(g.lines[0].history.samples, [80, 90, 100, 0])
        t.close(g.rangeMax, 100)
        let flat = try t.graphUnwrap(line(skin, "Flat"))
        t.close(flat.rangeMax - flat.rangeMin, 1, "all-zero history keeps a valid range")
        t.close(flat.fraction(line: 0, age: 0), 0)
    }

    t.suite("GraphMeter: Line bindings per line, LineCount limits") {
        let (skin, _) = try makeSkin(t, """
        [M1]
        Measure=Calc
        Formula=1

        [Gaps]
        Meter=Line
        LineCount=3
        MeasureName=M1
        MeasureName2=Missing
        MeasureName3=M1
        W=5
        H=5

        [Many]
        Meter=Line
        LineCount=1000000000000
        MeasureName=M1
        W=2
        H=2

        [None]
        Meter=Line
        LineCount=-3
        MeasureName=M1
        W=2
        H=2

        [Bad]
        Meter=Line
        LineCount=abc
        MeasureName=M1
        W=2
        H=2
        """)
        skin.update()
        let gaps = try t.graphUnwrap(line(skin, "Gaps"))
        t.equal(gaps.lines.count, 3)
        t.check(gaps.lines[0].measure === skin.measure(named: "M1"))
        t.check(gaps.lines[1].measure == nil)
        t.check(gaps.lines[2].measure === skin.measure(named: "M1"), "MeasureName3 is read across the gap")
        t.equal(try t.graphUnwrap(line(skin, "Many")).lines.count, LineMeter.maxLineCount)
        t.equal(try t.graphUnwrap(line(skin, "None")).lines.count, 0)
        t.equal(try t.graphUnwrap(line(skin, "Bad")).lines.count, 1)
    }

    t.suite("GraphMeter: Line history follows W changes and keeps the newest samples") {
        let (skin, _) = try makeSkin(t, """
        [Saw]
        Measure=Loop
        StartValue=0
        EndValue=100
        Increment=10

        [Graph]
        Meter=Line
        MeasureName=Saw
        LineCount=2
        MeasureName2=Saw
        W=5
        H=10
        """)
        updates(skin, 6)
        let g = try t.graphUnwrap(line(skin, "Graph"))
        t.equal(g.lines[0].history.samples, [10, 20, 30, 40, 50])
        skin.execute("[!SetOption Graph W 3]", from: nil)
        skin.update()
        t.equal(g.historyLength, 3)
        t.equal(g.lines[0].history.samples, [40, 50, 60])
        t.equal(g.lines[1].history.samples, [40, 50, 60])
        skin.execute("[!SetOption Graph W 6][!SetOption Graph LineCount 3][!SetOption Graph MeasureName3 Saw]",
                     from: nil)
        skin.update()
        t.equal(g.lines[0].history.samples, [40, 50, 60, 70], "growing keeps the old samples")
        t.equal(g.lines[2].history.samples, [70], "a new line starts empty")
        t.equal(g.lines[2].history.capacity, 6)
        t.close(g.frame.width, 6)
    }

    t.suite("GraphMeter: Line markers, UpdateDivider, hidden meters") {
        let (skin, _) = try makeSkin(t, """
        [Saw]
        Measure=Loop
        StartValue=0
        EndValue=100
        Increment=10

        [Graph]
        Meter=Line
        MeasureName=Saw
        HorizontalLines=1
        X=0
        Y=0
        W=10
        H=40

        [Slow]
        Meter=Line
        MeasureName=Saw
        UpdateDivider=2
        W=10
        H=10

        [HiddenGraph]
        Meter=Line
        MeasureName=Saw
        Hidden=1
        W=10
        H=10
        """)
        updates(skin, 4)
        let g = try t.graphUnwrap(line(skin, "Graph"))
        t.equal(g.markerCoordinates, [29.5, 19.5, 9.5], "quarters of the value axis, on pixel centers")
        skin.execute("[!SetOption Graph H 10]", from: nil)
        skin.update()
        t.equal(g.markerCoordinates, [4.5], "short graphs get one marker")
        skin.execute("[!SetOption Graph H 3]", from: nil)
        skin.update()
        t.equal(g.markerCoordinates, [])
        t.equal(try t.graphUnwrap(line(skin, "Slow")).lines[0].history.samples, [0, 20, 40],
                "a sample per meter update (UpdateDivider=2)")
        t.equal(try t.graphUnwrap(line(skin, "HiddenGraph")).lines[0].history.count, 6, "hidden meters keep sampling")
    }

    t.suite("GraphMeter: Line hostile input does not crash") {
        let (skin, _) = try makeSkin(t, """
        [Inf]
        Measure=Calc
        Formula=1e308 * 10
        MinValue=5
        MaxValue=5

        [Huge]
        Meter=Line
        MeasureName=Inf
        W=1000000000000
        H=(0/0)
        LineWidth=(0/0)
        Scale=1e308
        LineCount=(1/0)

        [Empty]
        Meter=Line
        MeasureName=Inf
        W=0
        H=0
        """)
        updates(skin, 3)
        let huge = try t.graphUnwrap(line(skin, "Huge"))
        t.equal(huge.historyLength, GraphHistory.maxCapacity)
        t.check(huge.lineWidth >= 0 && huge.lineWidth.isFinite)
        t.check(huge.lines.count <= LineMeter.maxLineCount)
        for age in [0, 1, 5000, 9000] {
            let f = huge.fraction(line: 0, age: age)
            t.check(f >= 0 && f <= 1, "fraction \(f)")
            let p = huge.point(line: 0, age: age)
            t.check(p.x.isFinite && p.y.isFinite)
        }
        let empty = try t.graphUnwrap(line(skin, "Empty"))
        t.equal(empty.historyLength, 0)
        t.equal(empty.lines[0].history.count, 0)
    }

    t.suite("GraphMeter: Histogram colors, parts and overlap") {
        let (skin, _) = try makeSkin(t, """
        [P]
        Measure=Calc
        Formula=Counter * 25
        MaxValue=100

        [S]
        Measure=Calc
        Formula=50
        MaxValue=100

        [Hist]
        Meter=Histogram
        MeasureName=P
        MeasureName2=S
        X=0
        Y=0
        W=10
        H=20

        [Single]
        Meter=Histogram
        MeasureName=P
        PrimaryColor=1,2,3
        SecondaryColor=4,5,6,7
        BothColor=8,9,10
        X=0
        Y=0
        W=10
        H=20
        """)
        updates(skin, 3)  // P: 0 25 50, S: 50 50 50
        let h = try t.graphUnwrap(histogram(skin, "Hist"))
        t.equal(h.primaryColor, RGBA(r: 0, g: 128, b: 0))
        t.equal(h.secondaryColor, RGBA(r: 255, g: 0, b: 0))
        t.equal(h.bothColor, RGBA(r: 255, g: 255, b: 0))
        t.check(h.hasSecondary)
        t.equal(h.historyLength, 10)
        t.equal(h.primaryHistory.samples, [0, 25, 50])
        t.equal(h.secondaryHistory.samples, [50, 50, 50])

        var c = h.columnRects(age: 0)  // 50 / 50 → all overlap
        t.equal(c.both, SkinRect(x: 9, y: 10, width: 1, height: 10))
        t.close(c.primary.height, 0)
        t.close(c.secondary.height, 0)
        c = h.columnRects(age: 1)  // 25 / 50
        t.equal(c.both, SkinRect(x: 8, y: 15, width: 1, height: 5))
        t.equal(c.secondary, SkinRect(x: 8, y: 10, width: 1, height: 5))
        t.close(c.primary.height, 0)
        c = h.columnRects(age: 2)  // 0 / 50
        t.close(c.both.height, 0)
        t.equal(c.secondary, SkinRect(x: 7, y: 10, width: 1, height: 10))
        skin.update()  // P = 75
        c = h.columnRects(age: 0)
        t.equal(c.both, SkinRect(x: 9, y: 10, width: 1, height: 10))
        t.equal(c.primary, SkinRect(x: 9, y: 5, width: 1, height: 5))
        t.close(c.secondary.height, 0)

        let single = try t.graphUnwrap(histogram(skin, "Single"))
        t.check(!single.hasSecondary)
        t.equal(single.primaryColor, RGBA(r: 1, g: 2, b: 3))
        t.equal(single.secondaryColor, RGBA(r: 4, g: 5, b: 6, a: 7))
        t.equal(single.bothColor, RGBA(r: 8, g: 9, b: 10))
        c = single.columnRects(age: 0)
        t.equal(c.primary, SkinRect(x: 9, y: 5, width: 1, height: 15), "one measure: primary only")
        t.close(c.both.height, 0)
    }

    t.suite("GraphMeter: Histogram scaling (percentual, AutoScale, rounding)") {
        let (skin, _) = try makeSkin(t, """
        [Small]
        Measure=Calc
        Formula=Counter + 1
        MaxValue=1000

        [Big]
        Measure=Calc
        Formula=8
        MaxValue=16

        [Auto]
        Meter=Histogram
        MeasureName=Small
        AutoScale=1
        W=4
        H=10

        [AutoSmooth]
        Meter=Histogram
        MeasureName=Small
        AutoScale=1
        AntiAlias=1
        W=4
        H=10

        [Fixed]
        Meter=Histogram
        MeasureName=Small
        MeasureName2=Big
        W=4
        H=10

        [Common]
        Meter=Histogram
        MeasureName=Small
        MeasureName2=Big
        AutoScale=1
        W=4
        H=10
        """)
        updates(skin, 4)  // Small: 1 2 3 4
        let auto = try t.graphUnwrap(histogram(skin, "Auto"))
        t.close(auto.autoRangeMax, 4)
        t.close(auto.fraction(age: 0), 1)
        t.close(auto.fraction(age: 3), 0.25)
        t.close(auto.columnLengths(age: 3).primary, 3, "2.5 px rounds to whole pixels")
        t.close(try t.graphUnwrap(histogram(skin, "AutoSmooth")).columnLengths(age: 3).primary, 2.5,
                "AntiAlias=1 keeps fractional lengths")
        let fixed = try t.graphUnwrap(histogram(skin, "Fixed"))
        t.close(fixed.fraction(age: 0), 0.004, "each measure is its own percentage")
        t.close(fixed.fraction(secondary: true, age: 0), 0.5)
        t.close(fixed.columnLengths(age: 0).primary, 0)
        t.close(fixed.columnLengths(age: 0).secondary, 5)
        let common = try t.graphUnwrap(histogram(skin, "Common"))
        t.close(common.autoRangeMax, 8, "one AutoScale range for both measures")
        t.close(common.fraction(age: 0), 0.5)
        t.close(common.fraction(secondary: true, age: 0), 1)
    }

    t.suite("GraphMeter: Histogram direction and SecondaryMeasureName") {
        let (skin, _) = try makeSkin(t, """
        [P]
        Measure=Calc
        Formula=50
        MaxValue=100

        [S]
        Measure=Calc
        Formula=100
        MaxValue=100

        [Hist]
        Meter=Histogram
        MeasureName=P
        SecondaryMeasureName=S
        GraphOrientation=Horizontal
        GraphStart=Left
        Flip=1
        X=0
        Y=0
        W=20
        H=6
        """)
        skin.update()
        let h = try t.graphUnwrap(histogram(skin, "Hist"))
        t.check(h.secondaryMeasure === skin.measure(named: "S"), "deprecated SecondaryMeasureName")
        t.equal(h.historyLength, 6, "horizontal: one sample per pixel of H")
        let c = h.columnRects(age: 0)
        t.equal(c.both, SkinRect(x: 10, y: 0, width: 10, height: 1), "newest at the top, growing from the right")
        t.equal(c.secondary, SkinRect(x: 0, y: 0, width: 10, height: 1))
    }

    t.suite("GraphMeter: Histogram images size the meter") {
        let host = FakeHost()
        let (skin, _) = try makeSkin(t, """
        [P]
        Measure=Calc
        Formula=50
        MaxValue=100

        [Img]
        Meter=Histogram
        MeasureName=P
        PrimaryImage=Graph100x50
        PrimaryImagePath=#@#Images
        PrimaryImageTint=255,0,0,128
        PrimaryImageFlip=Both
        SecondaryImage=Other100x50.png
        SecondaryImageAlpha=200
        SecondaryImageTint=255,255,255
        SecondaryGreyScale=1
        BothImage=Both100x50.png
        BothImageFlip=Vertical
        W=10
        H=10

        [Cropped]
        Meter=Histogram
        MeasureName=P
        PrimaryImage=Graph100x50.png
        PrimaryImageCrop=5,5,40,20
        GraphOrientation=Horizontal
        W=10
        H=10

        [NoImage]
        Meter=Histogram
        MeasureName=P
        PrimaryImage=Missing.png
        W=12
        H=8

        [Rotated]
        Meter=Histogram
        MeasureName=P
        PrimaryImage=Graph100x50.png
        PrimaryImageRotate=90
        """, host: host)
        skin.update()
        let img = try t.graphUnwrap(histogram(skin, "Img"))
        t.close(img.frame.width, 100, "W/H cannot change the image size")
        t.close(img.frame.height, 50)
        t.equal(img.historyLength, 100)
        let primary = try t.graphUnwrap(img.primaryImage)
        t.check(primary.path.hasSuffix("/Root/@Resources/Images/Graph100x50.png"), primary.path)
        t.equal(primary.tint, RGBA(r: 255, g: 0, b: 0))
        t.close(primary.alpha, 128, "ImageTint alpha")
        t.check(primary.flipHorizontal && primary.flipVertical)
        let secondary = try t.graphUnwrap(img.secondaryImage)
        t.check(secondary.tint == nil, "a white tint is no tint")
        t.close(secondary.alpha, 200)
        t.check(secondary.greyscale)
        t.check(secondary.path.hasSuffix("/Root/Sub/Other100x50.png"), secondary.path)
        let both = try t.graphUnwrap(img.bothImage)
        t.check(!both.flipHorizontal && both.flipVertical)

        let cropped = try t.graphUnwrap(histogram(skin, "Cropped"))
        t.close(cropped.frame.width, 40, "ImageCrop W,H define the size")
        t.close(cropped.frame.height, 20)
        t.equal(cropped.historyLength, 20)

        let noImage = try t.graphUnwrap(histogram(skin, "NoImage"))
        t.close(noImage.frame.width, 12, "an image that cannot be loaded leaves W/H in effect")
        t.equal(noImage.historyLength, 12)
        t.check(skin.issues.contains { $0.contains("ImageRotate") }, "\(skin.issues)")
    }

    t.suite("GraphMeter: Histogram ImageCrop origins") {
        func crop(_ values: [Double]) -> SkinRect? {
            HistogramMeter.HistogramImage(path: "", crop: values, tint: nil, alpha: 255, greyscale: false,
                                          flipHorizontal: false, flipVertical: false)
                .cropRect(imageWidth: 200, imageHeight: 100)
        }
        t.equal(crop([10, 5, 20, 30]), SkinRect(x: 10, y: 5, width: 20, height: 30))
        t.equal(crop([-10, 5, 10, 10, 2]), SkinRect(x: 190, y: 5, width: 10, height: 10))
        t.equal(crop([-10, -10, 10, 10, 3]), SkinRect(x: 190, y: 90, width: 10, height: 10))
        t.equal(crop([0, -10, 10, 10, 4]), SkinRect(x: 0, y: 90, width: 10, height: 10))
        t.equal(crop([-50, -30, 100, 60, 5]), SkinRect(x: 50, y: 20, width: 100, height: 60), "manual example")
        t.equal(crop([0, 0, 0, 10]), nil)
        t.equal(crop([0, 0, 10]), nil)
        t.equal(crop([.nan, 0, 10, 10]), nil)
        t.equal(crop([0, 0, .infinity, 10]), nil)
    }

    // Regression fixtures: the committed test skins and the bundled Network example.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    t.suite("GraphMeter: TestSkins/Graphs fixtures") {
        let skins = repo.appendingPathComponent("TestSkins")
        let host = FakeHost()
        func load(_ name: String) throws -> Skin {
            let skin = Skin(config: "Graphs\\\(name)",
                            fileURL: skins.appendingPathComponent("Graphs/\(name)/\(name).ini"),
                            skinsDirectory: skins, system: FakeSystem(), host: host)
            try skin.load()
            updates(skin, 60)
            return skin
        }
        let lines = try load("Line")
        t.equal(lines.issues, [])
        let sine = { (counter: Double) in 50 + 50 * sin(counter * Double.pi / 15) }
        let graph = try t.graphUnwrap(line(lines, "GraphDefault"))
        t.equal(graph.historyLength, 120)
        t.equal(graph.lines[0].history.count, 60)
        t.close(graph.fraction(line: 0, age: 0), sine(59) / 100, accuracy: 1e-9)
        t.close(graph.fraction(line: 0, age: 10), sine(49) / 100, accuracy: 1e-9)
        t.close(graph.fraction(line: 1, age: 0), Double((59 % 21) * 5) / 100, "saw")
        t.close(try t.graphUnwrap(line(lines, "GraphAuto")).rangeMax, 5, accuracy: 1e-6)
        t.equal(try t.graphUnwrap(line(lines, "GraphHorizontal")).historyLength, 60)
        t.check(try t.graphUnwrap(line(lines, "GraphStrokeFixed")).transformStrokeFixed)
        t.check(try t.graphUnwrap(line(lines, "GraphStrokeNormal")).transformationMatrix != nil)

        let hist = try load("Histogram")
        t.equal(hist.issues, [])
        let images = try t.graphUnwrap(histogram(hist, "HistImages"))
        t.check(images.primaryImage != nil && images.secondaryImage != nil && images.bothImage != nil)
        t.check(images.secondaryImage?.path.hasSuffix("@Resources/Secondary.png") == true)
        t.equal(try t.graphUnwrap(histogram(hist, "HistHorizontal")).historyLength, 60)
        t.check(try t.graphUnwrap(histogram(hist, "HistHorizontal")).hasSecondary)
    }

    t.suite("GraphMeter: DefaultSkins Network line graph") {
        let skins = repo.appendingPathComponent("DefaultSkins")
        let host = FakeHost()
        let system = FakeSystem()
        let skin = Skin(config: "Deskset\\Network",
                        fileURL: skins.appendingPathComponent("Deskset/Network/Network.ini"),
                        skinsDirectory: skins, system: system, host: host)
        try skin.load()
        updates(skin, 3)
        let graph = try t.graphUnwrap(line(skin, "MeterGraph"))
        t.equal(graph.lines.count, 2)
        t.check(graph.lines.allSatisfy { $0.measure != nil })
        t.check(graph.autoScale)
        t.equal(graph.historyLength, 224)
        t.equal(graph.lines[0].history.count, 3)
        t.check(graph.frame.width == 224 && graph.frame.height == 56)
    }

    // MARK: Review regressions

    t.suite("GraphMeter: AntiAlias=0 line vertices sit on whole pixels") {
        // H=10: 50 % is 4.5 px above the lowest pixel center, i.e. exactly between two pixel rows — an aliased
        // 1-px line there is rasterized two rows thick. Whole-pixel vertices round to a pixel center instead.
        let frame = SkinRect(x: 10, y: 20, width: 100, height: 10)
        var g = GraphGeometry(frame: frame, direction: GraphDirection())
        t.check(g.point(age: 0, fraction: 0.5) == (109.5, 25), "smooth vertex between rows 24 and 25")
        t.check(g.point(age: 0, fraction: 0.5, wholePixels: true) == (109.5, 24.5))
        t.check(g.point(age: 0, fraction: 0, wholePixels: true) == (109.5, 29.5))
        t.check(g.point(age: 0, fraction: 1, wholePixels: true) == (109.5, 20.5))
        t.check(g.point(age: 3, fraction: .nan, wholePixels: true) == (106.5, 29.5))
        t.check(g.point(age: 0, fraction: 7, wholePixels: true) == (109.5, 20.5))
        for f in stride(from: 0.0, through: 1.0, by: 0.01) {
            let y = g.point(age: 0, fraction: f, wholePixels: true).y
            t.check(y - y.rounded(.down) == 0.5, "pixel center for \(f): \(y)")
            t.check(y >= 20.5 && y <= 29.5)
            let smooth = g.point(age: 0, fraction: f, wholePixels: false)
            t.check(smooth == g.point(age: 0, fraction: f), "wholePixels: false is the smooth vertex")
        }
        g.direction = GraphDirection(startRight: false, vertical: false, flip: true)
        t.check(g.point(age: 0, fraction: 0.5, wholePixels: true) == (59.5, 20.5),
                "horizontal + flip: values from the right edge, on a pixel center")
        let tiny = GraphGeometry(frame: SkinRect(x: 0, y: 0, width: 0.5, height: 0.5), direction: GraphDirection())
        let p = tiny.point(age: 0, fraction: 1, wholePixels: true)
        t.check(p.x.isFinite && p.y.isFinite)
    }

    t.suite("GraphMeter: Line range survives extreme MinValue/MaxValue") {
        let (skin, _) = try makeSkin(t, """
        [Zero]
        Measure=Calc
        Formula=0
        MinValue=-1e308
        MaxValue=1e308

        [Graph]
        Meter=Line
        MeasureName=Zero
        W=4
        H=10

        [Hist]
        Meter=Histogram
        MeasureName=Zero
        W=4
        H=10
        """)
        skin.update()
        let g = try t.graphUnwrap(line(skin, "Graph"))
        t.close(g.fraction(line: 0, age: 0), 0.5, "the span overflows to infinity; 0 is still the middle")
        t.close(try t.graphUnwrap(histogram(skin, "Hist")).fraction(age: 0), 0.5)
        t.close(GraphRange.fraction(1e308, -1e308, 1e308), 1)
        t.close(GraphRange.fraction(-.infinity, 0, 1), 0)
        t.close(GraphRange.fraction(.infinity, 0, 1), 1)
        t.close(GraphRange.fraction(5, .nan, 1), 0)
        t.close(GraphRange.fraction(5, 0, .infinity), 0)
        t.close(GraphRange.fraction(5, 3, 3), 0)
    }

    t.suite("GraphMeter: Histogram image size needs a loadable image") {
        let (skin, _) = try makeSkin(t, """
        [P]
        Measure=Calc
        Formula=50
        MaxValue=100

        [MissingCrop]
        Meter=Histogram
        MeasureName=P
        PrimaryImage=Missing.png
        PrimaryImageCrop=0,0,40,20
        W=12
        H=8

        [WindowsPath]
        Meter=Histogram
        MeasureName=P
        PrimaryImage=Images.v2\\Graph100x50
        W=12
        H=8

        [Matrix]
        Meter=Histogram
        MeasureName=P
        PrimaryImage=Graph100x50.png
        BothImage=Graph100x50.png
        BothImageColorMatrix5=0.5;0;0;0;1
        """)
        skin.update()
        let missing = try t.graphUnwrap(histogram(skin, "MissingCrop"))
        t.close(missing.frame.width, 12, "the crop of a missing image does not size the meter")
        t.close(missing.frame.height, 8)
        t.equal(missing.historyLength, 12)
        let windows = try t.graphUnwrap(histogram(skin, "WindowsPath"))
        let path = try t.graphUnwrap(windows.primaryImage).path
        t.check(path.hasSuffix("/Root/Sub/Images.v2/Graph100x50.png"), "\\ separators, default .png: \(path)")
        t.close(windows.frame.width, 100)
        t.check(skin.issues.contains { $0.contains("Both") && $0.contains("ColorMatrix") },
                "any ColorMatrixN row is reported: \(skin.issues)")
    }

    t.suite("GraphMeter: TestSkins/Graphs/Aliased fixture") {
        let skins = repo.appendingPathComponent("TestSkins")
        let skin = Skin(config: "Graphs\\Aliased",
                        fileURL: skins.appendingPathComponent("Graphs/Aliased/Aliased.ini"),
                        skinsDirectory: skins, system: FakeSystem(), host: FakeHost())
        try skin.load()
        updates(skin, 60)
        t.equal(skin.issues, [])
        let missing = try t.graphUnwrap(histogram(skin, "HistMissingCrop"))
        t.equal(missing.frame, SkinRect(x: 150, y: 58, width: 60, height: 20), "missing image: W/H stay")
        t.equal(missing.historyLength, 60)
        t.check(!missing.antiAlias)
        let flat = try t.graphUnwrap(line(skin, "LineFlat"))
        t.check(!flat.antiAlias, "AntiAlias defaults to 0")
        t.close(flat.fraction(line: 0, age: 0), 0.5)
        let smooth = flat.point(line: 0, age: 0)
        t.close(smooth.y, 18 + 20 - 0.5 - 0.5 * 19, "the smooth vertex is between two pixel rows")
        let crisp = flat.geometry.point(age: 0, fraction: flat.fraction(line: 0, age: 0), wholePixels: true)
        t.close(crisp.y - crisp.y.rounded(.down), 0.5, "whole-pixel vertex: a pixel center")
        let half = try t.graphUnwrap(histogram(skin, "HistHalf"))
        t.equal(half.contentFrame, SkinRect(x: 10.5, y: 58.5, width: 60, height: 20))
        for age in 0..<half.historyLength {
            let c = half.columnRects(age: age).primary
            t.check(c.height == c.height.rounded(), "whole-pixel column lengths (age \(age): \(c.height))")
        }
        t.equal(try t.graphUnwrap(histogram(skin, "HistHalfSize")).historyLength, 60, "W=60.5: 60 whole pixels")
        t.equal(try t.graphUnwrap(line(skin, "LineHalfSize")).historyLength, 60)
    }
}

private extension TestRunner {
    struct MissingGraphValue: Error {}

    func graphUnwrap<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
        guard let value else {
            check(false, "unexpected nil", file: file, line: line)
            throw MissingGraphValue()
        }
        return value
    }
}
