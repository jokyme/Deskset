import Foundation
@testable import DesksetCore

// Shape meter: parsing, geometry, bounds / meter size, stroke plans, gradients, Combine, hit testing, robustness.

/// Loads a skin whose first meter `[M]` is a Shape meter with `body` as its options (plus `extra` sections).
private func loadShape(_ t: TestRunner, _ body: String, extra: String = "") throws -> (Skin, ShapeMeter, FakeHost) {
    let (skin, host) = try makeSkin(t, "[M]\nMeter=Shape\n" + body + "\n" + extra)
    skin.update()
    guard let m = skin.meter(named: "M") as? ShapeMeter else { throw FormulaError("no shape meter") }
    return (skin, m, host)
}

private func closeRect(_ t: TestRunner, _ r: ShapeRect?, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                       accuracy: Double = 1e-6, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    guard let r else {
        t.check(false, "nil rect \(message)", file: file, line: line)
        return
    }
    t.close(r.minX, minX, accuracy: accuracy, "minX \(message)", file: file, line: line)
    t.close(r.minY, minY, accuracy: accuracy, "minY \(message)", file: file, line: line)
    t.close(r.maxX, maxX, accuracy: accuracy, "maxX \(message)", file: file, line: line)
    t.close(r.maxY, maxY, accuracy: accuracy, "maxY \(message)", file: file, line: line)
}

private func path(_ item: ShapeItem?) -> ShapePath? {
    if case .path(let p)? = item?.geometry { return p }
    return nil
}

private func segmentKinds(_ item: ShapeItem?) -> String {
    guard let sub = path(item)?.subpaths.first else { return "" }
    return sub.segments.map {
        switch $0.kind {
        case .line: return "L"
        case .quadratic: return "Q"
        case .cubic: return "C"
        }
    }.joined()
}

func runShapeMeterTests(_ t: TestRunner) {
    t.suite("ShapeMeter: rectangle, defaults and meter size") {
        let (_, m, _) = try loadShape(t, "X=10\nY=20\nShape=Rectangle 0,0,100,50")
        t.equal(m.shapes.count, 1)
        let s = m.shapes[0]
        t.equal(s.index, 1)
        t.check(s.closed)
        // Manual: "a default white fill color and a default 1 pixel black drawing stroke".
        t.equal(s.fill, .color(.white))
        t.equal(s.stroke, .color(.black))
        t.close(s.strokeStyle.width, 1)
        closeRect(t, s.bounds, 0, 0, 100, 50)
        closeRect(t, s.visualBounds, -0.5, -0.5, 100.5, 50.5)
        t.equal(segmentKinds(s), "LLL")
        // Width/height reach to the stroke's outer edge, rounded to whole pixels; X/Y are not moved.
        t.equal(m.frame, SkinRect(x: 10, y: 20, width: 101, height: 51))

        let (_, rounded, _) = try loadShape(t, """
        Shape=Rectangle 0,0,100,50,10
        Shape2=Rectangle 0,0,100,50,20,5
        Shape3=Rectangle 0,0,100,50,80
        Shape4=Rectangle 0,0,858,2,
        Shape5=Rectangle 10,10,-10,-10
        """)
        t.equal(rounded.shapes.count, 5)
        t.equal(segmentKinds(rounded.shapes[0]), "LCLCLCLC")
        closeRect(t, rounded.shapes[0].bounds, 0, 0, 100, 50)
        // RadiusX larger than half the width is limited (and RadiusY, defaulting to RadiusX, to half the height):
        // no straight edges are left — an ellipse.
        t.equal(segmentKinds(rounded.shapes[2]), "CCCC")
        t.equal(segmentKinds(rounded.shapes[1]), "LCLCLCLC")
        closeRect(t, rounded.shapes[2].bounds, 0, 0, 100, 50)
        // A trailing comma (as in the manual's example skin) is fine.
        closeRect(t, rounded.shapes[3].bounds, 0, 0, 858, 2)
        // Negative width/height extend left/up.
        closeRect(t, rounded.shapes[4].bounds, 0, 0, 10, 10)
    }

    t.suite("ShapeMeter: ellipse, line, arc and curve geometry") {
        let (_, m, _) = try loadShape(t, """
        Shape=Ellipse 50,50,50
        Shape2=Ellipse 50,50,50,25
        Shape3=Line 10,20,110,70
        Shape4=Arc 0,0,100,0
        Shape5=Arc 0,0,100,0,*,*,*,1
        Shape6=Arc 0,0,100,0,100,100,0,0,1,1
        Shape7=Curve 0,0,100,0,50,100,0
        Shape8=Curve 0,0,100,0,0,100,100,100,1
        Shape9=Arc 0,0,100,0,10,10
        """)
        t.equal(m.shapes.count, 9)
        closeRect(t, m.shapes[0].bounds, 0, 0, 100, 100)
        closeRect(t, m.shapes[1].bounds, 0, 25, 100, 75)
        t.equal(segmentKinds(m.shapes[0]), "CCCC")
        // Line: open, and open shapes are not filled by default.
        let line = m.shapes[2]
        t.check(!line.closed)
        t.equal(line.fill, .none)
        closeRect(t, line.bounds, 10, 20, 110, 70)
        // Arc: default radius = half the distance (a half circle); SweepDirection 0 (default) is clockwise on screen,
        // i.e. over the top when going left → right; 1 is counter-clockwise.
        closeRect(t, m.shapes[3].bounds, 0, -50, 100, 0, accuracy: 1e-3)
        closeRect(t, m.shapes[4].bounds, 0, 0, 100, 50, accuracy: 1e-3)
        t.check(!m.shapes[3].closed)
        // Radius 100 between points 100 apart: the large clockwise arc bulges far above; ShapeEnding 1 closes it.
        t.check(m.shapes[5].closed)
        t.equal(m.shapes[5].fill, .color(.white))
        t.close(m.shapes[5].bounds.minY, -(100 + (100 * 100 - 50 * 50).squareRoot()), accuracy: 1e-3)
        closeRect(t, m.shapes[5].bounds, -50, -186.6025, 150, 0, accuracy: 0.05)  // cubic arc approximation
        // Radius too small to reach: scaled up to a half circle.
        closeRect(t, m.shapes[8].bounds, 0, -50, 100, 0, accuracy: 1e-3)
        // Curve: 6/7 parameters → quadratic (+ ShapeEnding), 8/9 → cubic (+ ShapeEnding).
        t.equal(segmentKinds(m.shapes[6]), "Q")
        t.check(!m.shapes[6].closed)
        closeRect(t, m.shapes[6].bounds, 0, 0, 100, 50, accuracy: 1e-9)
        t.equal(segmentKinds(m.shapes[7]), "C")
        t.check(m.shapes[7].closed)
        closeRect(t, m.shapes[7].bounds, 0, 0, 100, 75, accuracy: 1e-9)

        // Arc end point is exact and the arc runs through the expected points.
        let pieces = ShapeGeometryBuilder.arc(from: ShapePoint(0, 0), to: ShapePoint(100, 0), radiusX: nil, radiusY: nil)
        t.equal(pieces.count, 2)
        t.equal(pieces.last?.end, ShapePoint(100, 0))
        t.equal(pieces.first.map { $0.end.x.rounded() }, 50)
        t.equal(pieces.first.map { $0.end.y.rounded() }, -50)
        t.equal(ShapeGeometryBuilder.arc(from: ShapePoint(5, 5), to: ShapePoint(5, 5), radiusX: 10, radiusY: 10).count, 0)
        t.equal(ShapeGeometryBuilder.arc(from: ShapePoint(0, 0), to: ShapePoint(10, 0), radiusX: 0, radiusY: 5),
                [.line(to: ShapePoint(10, 0))])
        // Rotated ellipse arc still ends on the end point.
        let rotated = ShapeGeometryBuilder.arc(from: ShapePoint(0, 0), to: ShapePoint(60, 30), radiusX: 50, radiusY: 20,
                                               rotation: 30, clockwise: false, largeArc: true)
        t.check(rotated.count >= 2)
        t.equal(rotated.last?.end, ShapePoint(60, 30))
    }

    t.suite("ShapeMeter: path definitions") {
        let (_, m, host) = try loadShape(t, """
        Shape=Path Box | Fill Color 10,20,30
        Box=0,0 | LineTo 40,0 | ArcTo 40,40 | CurveTo 0,40,20,60 | CurveTo 0,0,-10,30,-10,10 | ClosePath 1
        Shape2=Path Open | StrokeWidth 2
        Open=5,5 | LineTo 50,5 | SetRoundJoin 1 | LineTo 50,50 | SetNoStroke 1 | LineTo 5,50 | SetNoStroke 0 | SetRoundJoin 0 | LineTo 5,20
        Shape3=Path1 Box
        Shape4=Path Missing
        Shape5=Path Bad
        Bad=x | LineTo 10,10
        Shape6=Path Star
        Star=30,0 | LineTo 48,57 | LineTo 0,21 | LineTo 60,21 | LineTo 12,57 | ClosePath 1
        Shape7=Path Bare
        Bare=0,0 | LineTo 10,0 | SetNoStroke | LineTo 10,10 | ClosePath
        Shape8=Path NotClosed
        NotClosed=0,0 | LineTo 10,0 | LineTo 10,10 | ClosePath 0
        """)
        t.equal(m.shapes.map(\.index), [1, 2, 3, 6, 7, 8])
        t.check(m.shapes[4].closed)
        // The closing line is explicit and carries the SetNoStroke state in effect at the end of the path.
        t.equal(path(m.shapes[4])?.subpaths.first?.segments.map(\.stroked), [true, false, false])
        t.check(!m.shapes[5].closed)
        let box = m.shapes[0]
        t.check(box.closed)
        t.equal(segmentKinds(box), "LCCQC")   // a half-circle ArcTo is two cubics
        t.equal(path(box)?.fillRule, .evenOdd)
        t.equal(box.fill, .color(RGBA(r: 10, g: 20, b: 30)))
        // ArcTo with the default radius bulges to the right (clockwise from top to bottom).
        closeRect(t, box.bounds, -7.5, 0, 60, 50, accuracy: 0.5)
        t.close(box.bounds.maxX, 60, accuracy: 1e-6)
        let open = m.shapes[1]
        t.check(!open.closed)
        t.equal(open.fill, .none)
        let segs = path(open)?.subpaths.first?.segments ?? []
        t.equal(segs.map(\.stroked), [true, true, false, true])
        // SetRoundJoin / SetNoStroke hold until changed again.
        t.equal(segs.map(\.roundJoin), [false, true, true, false])
        t.equal(path(m.shapes[2])?.fillRule, .nonZero)
        t.check(host.logs.contains { $0.contains("Missing") && $0.contains("not found") })
        t.check(host.logs.contains { $0.contains("Shape5") && $0.contains("start point") })

        // Hit testing honours the fill rule: the star's center is outside with even-odd.
        let star = m.shapes[3]
        t.check(!ShapeHitTester.hit(star, ShapePoint(30, 30)))
        var nonZero = star
        nonZero.geometry = .path(ShapePath(subpaths: path(star)?.subpaths ?? [], fillRule: .nonZero))
        t.check(ShapeHitTester.hit(nonZero, ShapePoint(30, 30)))
        t.check(ShapeHitTester.hit(star, ShapePoint(30, 10)))
    }

    t.suite("ShapeMeter: attribute modifiers and Extend") {
        let (_, m, host) = try loadShape(t, """
        Shape=Rectangle 0,0,10,10 | Fill Color 255,0,0,128 | StrokeWidth 4 | Stroke Color 0,255,0 | StrokeStartCap Round | StrokeEndCap Triangle | StrokeDashCap square | StrokeLineJoin MiterOrBevel, 3.5 | StrokeDashes 2,1.5 | StrokeDashOffset 0.5 | StrokeType Outer
        Shape2=Rectangle 0,0,10,10 | Extend A, B | StrokeWidth 7
        A=Fill Color 1,2,3 | StrokeWidth 2 | Rotate 90 | Extend C
        B=StrokeWidth 3 | Stroke Color 4,5,6
        C=Fill Color 9,9,9
        Shape3=Rectangle 0,0,10,10 | Extend A, B
        Shape4=Rectangle 0,0,10,10 | Fill 0,0,255 | Wobble 3 | StrokeLineJoin Round | StrokeWidth -5 | Fill Color nonsense
        Shape5=Rectangle 0,0,10,10 | StrokeLineJoin Miter,0.2 | StrokeDashes 1,-2,3
        """)
        let a = m.shapes[0]
        t.equal(a.fill, .color(RGBA(r: 255, g: 0, b: 0, a: 128)))
        t.equal(a.stroke, .color(RGBA(r: 0, g: 255, b: 0)))
        t.close(a.strokeStyle.width, 4)
        t.equal(a.strokeStyle.startCap, .round)
        t.equal(a.strokeStyle.endCap, .triangle)
        t.equal(a.strokeStyle.dashCap, .square)
        t.equal(a.strokeStyle.join, .miterOrBevel)
        t.close(a.strokeStyle.miterLimit, 3.5)
        t.equal(a.strokeStyle.dashes, [2, 1.5])
        t.close(a.strokeStyle.dashOffset, 0.5)
        t.equal(a.strokeStyle.placement, .outer)
        // Extend inserts the named modifiers in place; the last one wins; Extend does not cascade.
        let b = m.shapes[1]
        t.equal(b.fill, .color(RGBA(r: 1, g: 2, b: 3)))
        t.equal(b.stroke, .color(RGBA(r: 4, g: 5, b: 6)))
        t.close(b.strokeStyle.width, 7)
        closeRect(t, b.bounds, 0, 0, 10, 10, accuracy: 1e-9)
        t.close(m.shapes[2].strokeStyle.width, 3)
        // Leniency and bad values: `Fill r,g,b` works, unknown modifiers are ignored, a bad color keeps the paint,
        // negative widths become 0.
        let d = m.shapes[3]
        t.equal(d.fill, .color(RGBA(r: 0, g: 0, b: 255)))
        t.equal(d.strokeStyle.join, .round)
        t.close(d.strokeStyle.width, 0)
        t.equal(d.stroke, .none)
        t.check(d.strokePlan == nil)
        t.check(host.logs.contains { $0.contains("Wobble") })
        t.close(m.shapes[4].strokeStyle.miterLimit, 1)
        t.equal(m.shapes[4].strokeStyle.dashes, [1, 0, 3])
    }

    t.suite("ShapeMeter: transform modifiers") {
        let (_, m, _) = try loadShape(t, """
        Shape=Rectangle 0,0,100,50 | Rotate 90
        Shape2=Rectangle 0,0,100,50 | Rotate 90,0,0
        Shape3=Rectangle 0,0,100,50 | Scale 2,1
        Shape4=Rectangle 0,0,100,50 | Scale 2,3,0,0
        Shape5=Rectangle 0,0,100,50 | Skew 45,0
        Shape6=Rectangle 0,0,100,50 | Offset 10,-5
        Shape7=Rectangle 0,0,100,50 | Offset 100,0 | Rotate 180,0,0
        Shape8=Rectangle 0,0,100,50 | Offset 100,0 | Rotate 180,0,0 | TransformOrder Offset,Rotate
        Shape9=Rectangle 0,0,100,50 | Scale -1,1
        Shape10=Rectangle 20,10,100,50 | Rotate 90,0,0
        Shape11=Rectangle 0,0,100,50 | Skew 0,45,0,0
        """)
        let s = m.shapes
        // Rotation is clockwise on screen around the shape's center by default.
        closeRect(t, s[0].bounds, 25, -25, 75, 75, accuracy: 1e-9)
        // Anchors are relative to the shape's top-left corner.
        closeRect(t, s[1].bounds, -50, 0, 0, 100, accuracy: 1e-9)
        closeRect(t, s[9].bounds, -30, 10, 20, 110, accuracy: 1e-9)
        closeRect(t, s[2].bounds, -50, 0, 150, 50, accuracy: 1e-9)
        closeRect(t, s[3].bounds, 0, 0, 200, 150, accuracy: 1e-9)
        closeRect(t, s[4].bounds, -25, 0, 125, 50, accuracy: 1e-9)
        closeRect(t, s[10].bounds, 0, 0, 100, 150, accuracy: 1e-9)
        closeRect(t, s[5].bounds, 10, -5, 110, 45, accuracy: 1e-9)
        // Default order Rotate, Scale, Skew, Offset: rotate in place, then move.
        closeRect(t, s[6].bounds, 0, -50, 100, 0, accuracy: 1e-9)
        // Offset first, then rotate around the (untransformed) top-left anchor.
        closeRect(t, s[7].bounds, -200, -50, -100, 0, accuracy: 1e-9)
        closeRect(t, s[8].bounds, 0, 0, 100, 50, accuracy: 1e-9)
        // Scaling never scales the stroke: still half a pixel outside.
        closeRect(t, s[2].visualBounds, -50.5, -0.5, 150.5, 50.5, accuracy: 1e-9)
        // Gradients follow the shape: the paint transform is the shape's transform.
        t.equal(s[5].paintTransform, ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 10, ty: -5))

        // ShapeTransform algebra.
        let tr = ShapeTransform.rotation(degrees: 30, around: ShapePoint(3, 4)).then(.scale(2, 0.5, around: ShapePoint(1, 1)))
        let p = ShapePoint(7, -2)
        if let inv = tr.inverted {
            let back = inv.apply(tr.apply(p))
            t.close(back.x, p.x, accuracy: 1e-9)
            t.close(back.y, p.y, accuracy: 1e-9)
        } else {
            t.check(false, "invertible")
        }
        t.check(ShapeTransform.scale(0, 1, around: .zero).inverted == nil)
        // Skew near 90° stays finite.
        let skew = ShapeTransform.skew(degreesX: 90, degreesY: -90, around: .zero)
        t.check(skew.c.isFinite && skew.b.isFinite)
    }

    t.suite("ShapeMeter: gradients") {
        // Angle 0 runs right → left, 90 bottom → top, 180 left → right, 270 top → bottom.
        let box = ShapeRect(minX: 0, minY: 0, maxX: 100, maxY: 50)
        func endpoints(_ angle: Double) -> [Double] {
            let (s, e) = ShapeGradients.linearEndpoints(angle: angle, bounds: box)
            return [s.x, s.y, e.x, e.y].map { ($0 * 1000).rounded() / 1000 }
        }
        t.equal(endpoints(0), [100, 25, 0, 25])
        t.equal(endpoints(90), [50, 50, 50, 0])
        t.equal(endpoints(180), [0, 25, 100, 25])
        t.equal(endpoints(270), [50, 0, 50, 50])
        t.equal(endpoints(360), [100, 25, 0, 25])
        // 45°: the corners reach exactly 0 and 1.
        t.equal(endpoints(45), [87.5, 62.5, 12.5, -12.5])

        // Stops outside 0…1 are not shown but shape the interpolation.
        let red = RGBA(r: 255, g: 0, b: 0), blue = RGBA(r: 0, g: 0, b: 255)
        let n = ShapeGradients.normalizedStops([ShapeGradientStop(color: blue, position: 2),
                                                ShapeGradientStop(color: red, position: 0)], linearGamma: false)
        t.equal(n.map(\.position), [0, 1])
        t.equal(n.first?.color, red)
        t.equal(n.last?.color, RGBA(r: 127.5, g: 0, b: 127.5))
        let inside = ShapeGradients.normalizedStops([ShapeGradientStop(color: red, position: 0.25),
                                                     ShapeGradientStop(color: blue, position: 0.75)], linearGamma: false)
        t.equal(inside.map(\.position), [0, 0.25, 0.75, 1])
        t.equal(inside.first?.color, red)
        t.equal(inside.last?.color, blue)
        t.equal(ShapeGradients.normalizedStops([ShapeGradientStop(color: red, position: 5)], linearGamma: false),
                [ShapeGradientStop(color: red, position: 0)])
        t.equal(ShapeGradients.normalizedStops([], linearGamma: false), [])
        // Gamma-corrected interpolation is brighter in the middle.
        let mid = ShapeGradients.mix(RGBA(r: 0, g: 0, b: 0), RGBA(r: 255, g: 255, b: 255), 0.5, linearGamma: true)
        t.check(mid.r > 180 && mid.r < 190, "linear mid \(mid.r)")

        let (_, m, host) = try loadShape(t, """
        Shape=Rectangle 0,0,100,50 | Fill LinearGradient G | StrokeWidth 10 | Stroke LinearGradient1 G
        G=180 | 255,0,0,255 ; 0.0 | 0,255,0,255 ; 0.5 | 0,0,255,255 ; 1.0
        Shape2=Ellipse 50,50,50 | StrokeWidth 0 | Fill RadialGradient R
        R=0,0 | 155,200,232,255 ; 0.0 | 6,46,75,255 ; 1.0
        Shape3=Ellipse 50,50,50 | Fill RadialGradient1 R2
        R2=10,-5,20,20,30 | 255,255,255 ; 0 | 0,0,0
        Shape4=Rectangle 0,0,10,10 | Fill Color 1,2,3 | Fill LinearGradient Nope
        Shape5=Rectangle 0,0,10,10 | Fill RadialGradient Empty
        Empty=0,0
        Shape6=Rectangle 0,0,10,10 | Fill LinearGradient Guess
        Guess=90 | 255,0,0 | 0,255,0 | 0,0,255
        Shape7=Ellipse 0,0,10 | Fill RadialGradient Far
        Far=0,0,100,0 | 255,0,0 ; 0 | 0,0,255 ; 1
        """)
        guard case .linearGradient(let fill) = m.shapes[0].fill, case .linearGradient(let stroke) = m.shapes[0].stroke else {
            t.check(false, "linear gradients expected")
            return
        }
        func rounded(_ p: ShapePoint) -> ShapePoint { ShapePoint((p.x * 1e6).rounded() / 1e6, (p.y * 1e6).rounded() / 1e6) }
        t.equal(rounded(fill.start), ShapePoint(0, 25))
        t.equal(rounded(fill.end), ShapePoint(100, 25))
        t.equal(fill.stops.map(\.position), [0, 0.5, 1])
        t.check(!fill.linearGamma)
        t.check(stroke.linearGamma)
        // The stroke gradient spans the stroke too (bounds grown by half the stroke width).
        t.equal(rounded(stroke.start), ShapePoint(-5, 25))
        t.equal(rounded(stroke.end), ShapePoint(105, 25))
        guard case .radialGradient(let r) = m.shapes[1].fill, case .radialGradient(let r2) = m.shapes[2].fill else {
            t.check(false, "radial gradients expected")
            return
        }
        // Defaults: centered on the shape, radii = half the bounds.
        t.equal(r.center, ShapePoint(50, 50))
        t.equal(r.origin, ShapePoint(50, 50))
        t.close(r.radiusX, 50)
        t.close(r.radiusY, 50)
        // CenterX/Y offset the center from the shape's center, OffsetX/Y the origin from that; RadiusY = RadiusX.
        t.equal(r2.center, ShapePoint(60, 45))
        t.equal(r2.origin, ShapePoint(80, 65))
        t.close(r2.radiusX, 30)
        t.close(r2.radiusY, 30)
        t.check(r2.linearGamma)
        // Missing gradient option → paint unchanged; a gradient without stops → paint unchanged.
        t.equal(m.shapes[3].fill, .color(RGBA(r: 1, g: 2, b: 3)))
        t.equal(m.shapes[4].fill, .color(.white))
        t.check(host.logs.contains { $0.contains("Nope") })
        // Stops without positions spread evenly.
        if case .linearGradient(let g) = m.shapes[5].fill { t.equal(g.stops.map(\.position), [0, 0.5, 1]) } else { t.check(false) }
        // An origin outside the ellipse is pulled inside.
        if case .radialGradient(let g) = m.shapes[6].fill {
            t.check(g.origin.x - g.center.x < g.radiusX && g.origin.x - g.center.x > 9.9)
        } else {
            t.check(false)
        }
    }

    t.suite("ShapeMeter: Combine") {
        let (_, m, host) = try loadShape(t, """
        Shape=Rectangle 0,0,50,50 | Fill Color 255,0,0 | StrokeWidth 3
        Shape2=Rectangle 25,25,50,50 | Fill Color 0,255,0 | StrokeWidth 9
        Shape3=Combine Shape | Union Shape2 | Fill Color 0,0,255 | Offset 5,0
        Shape4=Ellipse 200,50,40 | Fill Color 1,1,1
        Shape5=Combine Shape6 | Intersect Shape4
        Shape6=Rectangle 200,0,100,100 | Rotate 0
        Shape7=Line 300,0,400,100 | StrokeWidth 2
        Shape8=Combine Shape7 | XOR Shape9 | Consume 0
        Shape9=Ellipse 350,50,10
        Shape10=Combine Shape5 | Exclude Shape11
        Shape11=Rectangle 190,40,100,20
        Shape12=Combine Nothing | Union Shape9
        Shape13=Combine Shape13 | Union Shape9
        """)
        // Combined shapes replace their parts; drawing order is by N.
        t.equal(m.shapes.map(\.index), [3, 7, 8, 9, 10])
        let union = m.shapes[0]
        t.check(union.closed)
        // Attributes come from the parent; the combined shape's own attribute modifiers are ignored, its transforms apply.
        t.equal(union.fill, .color(RGBA(r: 255, g: 0, b: 0)))
        t.close(union.strokeStyle.width, 3)
        t.check(union.strokePlan == nil)
        closeRect(t, union.bounds, 5, 0, 80, 75)
        closeRect(t, union.visualBounds, 3.5, -1.5, 81.5, 76.5)
        t.equal(union.paintTransform, ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 5, ty: 0))
        guard case .combined(let base, let steps) = union.geometry else {
            t.check(false, "combined geometry")
            return
        }
        t.equal(steps.map(\.mode), [.union])
        // The combined transform is pushed down onto the operands.
        if case .path(let p) = base { closeRect(t, ShapeMath.bounds(of: p), 5, 0, 55, 50) } else { t.check(false) }
        // Order of definition does not matter; nested Combine; Exclude keeps the parent's bounds, Intersect narrows.
        let nested = m.shapes[4]
        closeRect(t, nested.bounds, 200, 10, 240, 90)
        t.equal(nested.fill, .color(.white))
        // Open parents are closed before combining; `Consume 0` keeps the parts.
        if case .combined(let lineBase, _) = m.shapes[2].geometry, case .path(let lp) = lineBase {
            t.check(lp.subpaths.allSatisfy(\.closed))
        } else {
            t.check(false, "closed line operand")
        }
        t.equal(m.shapes[2].fill, .none)
        t.check(host.logs.contains { $0.contains("Shape12") })
        t.check(host.logs.contains { $0.contains("Shape13") })

        // Hit testing follows the boolean operation.
        func hit(_ i: Int, _ x: Double, _ y: Double) -> Bool { ShapeHitTester.hit(m.shapes[i], ShapePoint(x, y)) }
        t.check(hit(0, 20, 20))
        t.check(hit(0, 70, 70))
        t.check(!hit(0, 70, 10))
        t.check(hit(4, 215, 30))
        t.check(!hit(4, 215, 50))   // excluded band
        t.check(!hit(4, 250, 30))   // outside the intersection
        // XOR of a closed (zero-area) line and a circle: no fill (the open parent had none), stroke on the circle.
        t.check(!hit(2, 350, 50))
        t.check(hit(2, 340, 50))

        let xor = try loadShape(t, """
        Shape=Rectangle 0,0,60,60 | StrokeWidth 4
        Shape2=Rectangle 30,30,60,60
        Shape3=Combine Shape | XOR Shape2
        """).1
        t.equal(xor.shapes.count, 1)
        func xhit(_ x: Double, _ y: Double) -> Bool { ShapeHitTester.hit(xor.shapes[0], ShapePoint(x, y)) }
        t.check(xhit(10, 10))
        t.check(xhit(80, 80))
        t.check(xhit(45, 31))    // stroke along the internal edge (y = 30 inside the parent) is part of the XOR outline
        t.check(!xhit(45, 45))   // overlap: not filled, and away from every outline
        t.check(!xhit(80, 10))
    }

    t.suite("ShapeMeter: meter size, negative coordinates and positioning") {
        let (skin, _) = try makeSkin(t, """
        [A]
        Meter=Shape
        X=2
        Y=2
        Shape=Rectangle 0,0,100,100 | StrokeWidth 4
        [B]
        Meter=Shape
        X=25R
        Y=14r
        Shape=Rectangle 0,0,70,70 | StrokeWidth 4 | Rotate 45
        [C]
        Meter=Shape
        X=10R
        Y=2
        Shape=Rectangle 0,0,100,100,50 | StrokeWidth 4
        [D]
        Meter=Shape
        X=0
        Y=20R
        Shape=Rectangle 0,0,858,2, | StrokeWidth 0
        [E]
        Meter=Shape
        X=300
        Y=300
        Shape=Ellipse 0,0,20
        [F]
        Meter=Shape
        X=0
        Y=0
        W=30
        H=40
        Padding=1,2,3,4
        Shape=Rectangle 0,0,100,100
        [G]
        Meter=Shape
        X=0
        Y=0
        Shape=Rectangle -50,-50,10,10
        [H]
        Meter=Shape
        X=0
        Y=0
        Padding=5,6,7,8
        Shape=Rectangle 0,0,10,10 | StrokeWidth 0
        [LineFlat]
        Meter=Shape
        Shape=Line 0,10,100,10 | StrokeWidth 4
        [LineSquare]
        Meter=Shape
        Shape=Line 0,10,100,10 | StrokeWidth 4 | StrokeStartCap Square | StrokeEndCap Square
        [LineMixed]
        Meter=Shape
        Shape=Line 0,10,100,10 | StrokeWidth 4 | StrokeEndCap Triangle
        """)
        skin.update()
        func frame(_ name: String) -> SkinRect { skin.meter(named: name)?.frame ?? SkinRect(x: -1) }
        // Same spacing as the manual's example skin screenshot.
        t.equal(frame("A"), SkinRect(x: 2, y: 2, width: 102, height: 102))
        t.equal(frame("B"), SkinRect(x: 129, y: 16, width: 87, height: 87))
        t.equal(frame("C").x, 226)
        t.equal(frame("C").width, 102)
        t.equal(frame("D").y, 124)
        t.equal(frame("D").width, 858)
        // Negative extents do not grow the meter or move it.
        t.equal(frame("E"), SkinRect(x: 300, y: 300, width: 21, height: 21))
        t.equal(frame("F"), SkinRect(x: 0, y: 0, width: 34, height: 46))
        t.equal(frame("G").width, 0)
        t.equal(frame("H"), SkinRect(x: 0, y: 0, width: 22, height: 24))
        // Flat caps do not extend the line; square and triangle caps add half the width.
        t.equal(frame("LineFlat"), SkinRect(x: 0, y: 0, width: 100, height: 12))
        t.equal(frame("LineSquare").width, 102)
        t.equal(frame("LineMixed").width, 102)
        t.close(skin.width, 858)
    }

    t.suite("ShapeMeter: stroke plans (caps, joins, dashes)") {
        func plan(_ sub: ShapeSubpath, _ configure: (inout ShapeStrokeStyle) -> Void) -> ShapeStrokePlan? {
            var style = ShapeStrokeStyle()
            configure(&style)
            return ShapeStroker.plan(for: ShapePath(subpaths: [sub]), style: style)
        }
        let line = ShapeSubpath(start: ShapePoint(0, 0), segments: [ShapeSegment(.line(to: ShapePoint(100, 0)))])
        // Same supported cap at both ends: one native run.
        let p1 = plan(line) { $0.width = 4; $0.startCap = .round; $0.endCap = .round }
        t.equal(p1?.runs.count, 1)
        t.equal(p1?.runs.first?.cap, .round)
        t.equal(p1?.patches.count, 0)
        closeRect(t, p1.flatMap(ShapeStroker.bounds), -2, -2, 102, 2, accuracy: 1e-9)
        // Different or triangle caps become patches.
        let p2 = plan(line) { $0.width = 4; $0.startCap = .triangle; $0.endCap = .square }
        t.equal(p2?.runs.first?.cap, .flat)
        t.equal(p2?.patches.count, 2)
        closeRect(t, p2.flatMap(ShapeStroker.bounds), -2, -2, 102, 2, accuracy: 1e-9)
        // Caps are ignored on closed shapes.
        let square = ShapeGeometryBuilder.rectangle(x: 0, y: 0, width: 10, height: 10)
        let p3 = plan(square) { $0.startCap = .triangle; $0.endCap = .round }
        t.equal(p3?.runs.count, 1)
        t.equal(p3?.runs.first?.subpath.closed, true)
        t.equal(p3?.patches.count, 0)
        // Miter tips count toward the bounds (within the limit only).
        let zig = ShapeSubpath(start: ShapePoint(0, 0), segments: [ShapeSegment(.line(to: ShapePoint(10, 0))),
                                                                    ShapeSegment(.line(to: ShapePoint(10, 10)))])
        closeRect(t, plan(zig) { $0.width = 2 }.flatMap(ShapeStroker.bounds), 0, -1, 11, 10, accuracy: 1e-9)
        closeRect(t, plan(zig) { $0.width = 2; $0.join = .round }.flatMap(ShapeStroker.bounds), 0, -1, 11, 10, accuracy: 1e-9)

        // Dashes are multiples of the width: 5,5 × 2 → dashes at 0-10, 20-30, … 80-90.
        let p4 = plan(line) { $0.width = 2; $0.dashes = [5, 5] }
        t.equal(p4?.runs.count, 5)
        t.equal(p4?.runs.map { $0.subpath.start.x }, [0, 20, 40, 60, 80])
        t.equal(p4?.runs.map { $0.subpath.end.x }, [10, 30, 50, 70, 90])
        // Offset (× width) shifts the pattern forward.
        let p5 = plan(line) { $0.width = 2; $0.dashes = [5, 5]; $0.dashOffset = 2.5 }
        t.equal(p5?.runs.map { $0.subpath.start.x.rounded() }, [0, 15, 35, 55, 75, 95])
        t.equal(p5?.runs.first?.subpath.end.x, 5)
        // Dots: zero-length dashes draw only their round caps (the path start keeps the flat start cap).
        let p6 = plan(line) { $0.width = 4; $0.dashes = [0, 5]; $0.dashCap = .round }
        t.equal(p6?.runs.count, 0)
        // Dots at 0 (flat start cap + round dash cap), 20, 40, 60, 80 (two round caps), 100 (round + flat end cap).
        t.equal(p6?.patches.count, 10)
        // Odd dash lists repeat; a closed ellipse's dash across the start point is one piece.
        t.equal(ShapeStroker.dashPattern([1, 2, 3], strokeWidth: 2), [2, 4, 6, 2, 4, 6])
        t.check(ShapeStroker.dashPattern([0, 0], strokeWidth: 2) == nil)
        let circle = ShapeGeometryBuilder.ellipse(centerX: 0, centerY: 0, radiusX: 50)
        let whole = plan(circle) { $0.width = 1; $0.dashes = [10, 10] }
        let pieces = whole?.runs.count ?? 0
        t.check(pieces == 16 || pieces == 15, "dash pieces \(pieces)")
        // A dash longer than a closed outline: one closed run.
        let longDash = plan(square) { $0.width = 1; $0.dashes = [100, 1] }
        t.equal(longDash?.runs.count, 1)
        t.equal(longDash?.runs.first?.subpath.closed, true)
        t.equal(longDash?.patches.count, 0)
        // Too many dashes: solid instead.
        let long = ShapeSubpath(start: .zero, segments: [ShapeSegment(.line(to: ShapePoint(1_000_000, 0)))])
        t.equal(plan(long) { $0.width = 1; $0.dashes = [0.001, 0.001] }?.runs.count, 1)

        // SetRoundJoin adds a round join disc; SetNoStroke splits the stroke.
        let cmd = ShapeSubpath(start: .zero, segments: [
            ShapeSegment(.line(to: ShapePoint(10, 0))),
            ShapeSegment(.line(to: ShapePoint(10, 10)), roundJoin: true),
            ShapeSegment(.line(to: ShapePoint(20, 10)), stroked: false),
            ShapeSegment(.line(to: ShapePoint(20, 20))),
        ])
        let p7 = plan(cmd) { $0.width = 2 }
        t.equal(p7?.runs.count, 3)
        t.equal(p7?.patches.count, 1)
        t.equal(p7?.runs.map { $0.subpath.segments.count }, [1, 1, 1])
        // Closed figure with a forced round join: split there, disc at the vertex.
        var closedCmd = cmd
        closedCmd.closed = true
        closedCmd.segments[2].stroked = true
        let p8 = plan(closedCmd) { $0.width = 2 }
        t.equal(p8?.patches.count, 1)
        t.equal(p8?.runs.count, 1)
        t.equal(p8?.runs.first?.subpath.segments.count, 5)
        // Outer/inner strokes are twice as wide and clipped by the host.
        t.close(plan(square) { $0.width = 3; $0.placement = .outer }?.width ?? 0, 6)
        t.check(plan(square) { $0.width = 0 } == nil)
    }

    t.suite("ShapeMeter: mouse hit testing") {
        let (skin, _) = try makeSkin(t, """
        [A]
        Meter=Shape
        X=100
        Y=100
        Shape=Rectangle -50,0,40,40 | Fill Color 255,0,0
        Shape2=Line 0,60,100,60 | StrokeWidth 6
        Shape3=Rectangle 200,0,40,40 | Fill Color 0,0,0,0 | StrokeWidth 0
        Shape4=Rectangle 300,0,40,40 | Fill Color 0,0,0,1 | StrokeWidth 0
        Shape5=Ellipse 20,150,20 | Fill Color 0,0,0,0 | StrokeWidth 4 | StrokeType Inner
        [T]
        Meter=Shape
        X=0
        Y=0
        TransformationMatrix=1;0;0;1;500;0
        Shape=Rectangle 0,0,10,10
        [Hid]
        Meter=Shape
        Hidden=1
        Shape=Rectangle 0,0,10,10
        [Bg]
        Meter=Shape
        X=600
        Y=600
        W=50
        H=50
        SolidColor=0,0,0,128
        Shape=Rectangle 0,0,5,5
        """)
        skin.update()
        guard let a = skin.meter(named: "A") as? ShapeMeter, let tm = skin.meter(named: "T") as? ShapeMeter,
              let hid = skin.meter(named: "Hid") as? ShapeMeter, let bg = skin.meter(named: "Bg") as? ShapeMeter else {
            t.check(false, "meters")
            return
        }
        // Detected on the shapes, even left of the meter's frame; not in empty parts of the frame.
        t.check(a.hitTest(x: 70, y: 120))
        t.check(!a.hitTest(x: 120, y: 120))
        // Stroke of an open line (±3 px).
        t.check(a.hitTest(x: 150, y: 162))
        t.check(!a.hitTest(x: 150, y: 164))
        // A fully transparent fill is not solid; alpha 1 is.
        t.check(!a.hitTest(x: 320, y: 120))
        t.check(a.hitTest(x: 420, y: 120))
        // Inner stroke only inside the outline.
        t.check(a.hitTest(x: 120, y: 268))
        t.check(!a.hitTest(x: 120, y: 272))
        t.check(!a.hitTest(x: 120, y: 250))
        // TransformationMatrix moves the detection area with the drawing.
        t.check(tm.hitTest(x: 505, y: 5))
        t.check(!tm.hitTest(x: 5, y: 5))
        t.check(!hid.hitTest(x: 5, y: 5))
        // A SolidColor background is solid too.
        t.check(bg.hitTest(x: 640, y: 640))
        t.check(!bg.hitTest(x: 660, y: 640))
    }

    t.suite("ShapeMeter: dynamic options and revisions") {
        let (skin, m, _) = try loadShape(t, "Shape=Rectangle 0,0,[&Size],10\nDynamicVariables=1", extra: """
        [Size]
        Measure=Calc
        Formula=20
        """)
        skin.update()
        let r1 = m.revision
        closeRect(t, m.shapes.first?.bounds, 0, 0, 20, 10)
        skin.update()
        t.equal(m.revision, r1)     // unchanged geometry keeps the revision (host caches stay valid)
        skin.perform(Bang(name: "setoption", args: ["Size", "Formula", "35"]))
        skin.update()
        skin.update()
        closeRect(t, m.shapes.first?.bounds, 0, 0, 35, 10)
        t.check(m.revision != r1)
        skin.perform(Bang(name: "setoption", args: ["M", "Shape2", "Ellipse 0,0,5"]))
        skin.update()
        t.equal(m.shapes.count, 2)
    }

    t.suite("ShapeMeter: robustness") {
        let (skin, m, _) = try loadShape(t, """
        Shape=
        Shape2=Rectangle
        Shape3=Rectangle a,b,c,d
        Shape4=Arc 0,0,0,0
        Shape5=Combine
        Shape6=Combine Shape99 | Union Shape
        Shape7=Rectangle 1e300,-1e300,1e300,1e300,1e300 | StrokeWidth 1e300 | Rotate 1e300 | Skew 90,90 | Scale 1e300,1e300
        Shape8=Rectangle (1/0),(0/0),10,10 | Offset (1/0),5
        Shape9=Ellipse 0,0,0 | StrokeDashes 1,1 | StrokeDashCap Triangle
        Shape10=Line 0,0,0,0 | StrokeWidth 5 | StrokeStartCap Round | StrokeEndCap Triangle | StrokeDashes 0,1
        Shape11=Path P | Fill LinearGradient G | Stroke RadialGradient G
        P=0,0 | ArcTo 0,0 | CurveTo 0,0,0,0 | LineTo | ArcTo 5 | CurveTo 1,2,3 | SetNoStroke 1 | ClosePath 1
        G=| ; | ; ;
        Shape12=Combine Shape12 | Union Shape12
        Shape13=Combine Shape14 | Union Shape13
        Shape14=Combine Shape13 | Union Shape14
        Shape15=Rectangle 0,0,10,10 | Scale 0,0 | Fill LinearGradient G2 | StrokeDashes 0.00000001,0.00000001
        G2=45 | 255,0,0 ; 0 | 0,0,255 ; 1
        Shape16=Rectangle 0,0,10,10 | TransformOrder Offset,Offset,Bogus,, | Extend | Extend ,, | StrokeLineJoin | Fill | Stroke Color
        Shape17=Curve 0,0,1,1,*,*,*,*,*
        Shape18=Rectangle 0,0,10,10 | StrokeWidth 1 | StrokeType Outer | StrokeDashes 1000000,1
        """)
        // Nothing crashes; everything produced is finite; the meter size stays bounded.
        for s in m.shapes {
            for v in [s.bounds.minX, s.bounds.maxX, s.visualBounds.minY, s.visualBounds.maxY] {
                t.check(v.isFinite, "Shape\(s.index) bounds finite")
            }
            _ = ShapeHitTester.hit(s, ShapePoint(1, 1))
        }
        t.check(m.frame.width <= ShapeMeter.maxNaturalSize && m.frame.height <= ShapeMeter.maxNaturalSize)
        t.check(!m.shapes.contains { [1, 2, 3, 5, 6, 12, 13, 14, 17].contains($0.index) })
        _ = m.hitTest(x: 3, y: 3)

        // A long path definition is capped, not rejected.
        let segments = (0..<12_000).map { "LineTo \($0 % 100),\($0 % 37)" }.joined(separator: " | ")
        let (_, big, _) = try loadShape(t, "Shape=Path Long\nLong=0,0 | \(segments)")
        t.equal(path(big.shapes.first)?.subpaths.first?.segments.count, ShapeParser.maxPathSegments)
        skin.update()
    }

    runShapeMeterReviewTests(t)
}

/// Regression tests from the adversarial review of the Shape meter.
private func runShapeMeterReviewTests(_ t: TestRunner) {
    t.suite("ShapeMeter: review — Combine chains that reuse shapes stay bounded") {
        // Each level combines the previous level with itself, doubling the operands: 2^39 without a limit, which
        // hung parsing (every traversal of the tree is exponential) and grew memory without bound.
        var lines = ["Shape=Rectangle 0,0,50,50 | Fill Color 255,0,0"]
        for i in 2...40 {
            let previous = i == 2 ? "Shape" : "Shape\(i - 1)"
            lines.append("Shape\(i)=Combine \(previous) | Union \(previous)")
        }
        let started = Date()
        let (skin, m, host) = try loadShape(t, lines.joined(separator: "\n") + "\nDynamicVariables=1")
        skin.update()
        _ = m.hitTest(x: 10, y: 10)
        t.check(Date().timeIntervalSince(started) < 5, "chain parse took \(Date().timeIntervalSince(started)) s")
        // Shape9 holds 256 operands (the limit); Shape10 would hold 512 and is skipped, so is everything above it.
        t.equal(m.shapes.map(\.index), [9])
        t.check(host.logs.contains { $0.contains("Shape10") && $0.contains("256") })
        t.check(m.hitTest(x: 10, y: 10))
        // A wide but legitimate Combine (many distinct shapes) still works.
        var wide = (1...40).map { "Shape\($0 == 1 ? "" : String($0))=Ellipse \($0 * 10),10,6" }
        wide.append("Shape41=Combine Shape | " + (2...40).map { "Union Shape\($0)" }.joined(separator: " | "))
        let (_, w, _) = try loadShape(t, wide.joined(separator: "\n"))
        t.equal(w.shapes.map(\.index), [41])
    }

    t.suite("ShapeMeter: review — ClosePath uses the SetNoStroke / SetRoundJoin state at the end") {
        let (_, m, _) = try loadShape(t, """
        Shape=Path Round | StrokeWidth 10
        Round=10,10 | LineTo 90,10 | SetRoundJoin 1 | LineTo 50,80 | ClosePath 1
        Shape2=Path NoStroke | StrokeWidth 10
        NoStroke=10,10 | LineTo 90,10 | LineTo 50,80 | SetNoStroke 1 | ClosePath 1
        Shape3=Path Back | StrokeWidth 10
        Back=10,10 | LineTo 90,10 | SetNoStroke 1 | LineTo 10,10 | ClosePath 1
        """)
        let round = path(m.shapes[0])?.subpaths.first
        t.equal(round?.segments.count, 3)
        t.equal(round?.segments.map(\.roundJoin), [false, true, true])
        t.equal(round?.end, ShapePoint(10, 10))
        t.check(round?.closed == true)
        // Round joins at (90,10) and at (50,80), where the closing line starts; the start vertex keeps its miter.
        let plan = m.shapes[0].strokePlan
        let discs = plan?.patches.compactMap { ShapeMath.bounds(of: ShapePath(subpaths: [$0]))?.center } ?? []
        t.equal(discs.map { ShapePoint($0.x.rounded(), $0.y.rounded()) }, [ShapePoint(90, 10), ShapePoint(50, 80)])
        // The closing line after SetNoStroke 1 is not stroked: one open run 10,10 → 90,10 → 50,80 with flat ends.
        let noStroke = m.shapes[1]
        t.equal(path(noStroke)?.subpaths.first?.segments.map(\.stroked), [true, true, false])
        t.equal(noStroke.strokePlan?.runs.count, 1)
        t.equal(noStroke.strokePlan?.runs.first?.subpath.closed, false)
        t.equal(noStroke.strokePlan?.runs.first?.subpath.end, ShapePoint(50, 80))
        // 3 px outside the unstroked closing edge: nothing; 3 px outside the stroked right edge: the stroke.
        t.check(!ShapeHitTester.hit(noStroke, ShapePoint(30 - 3 * 0.868, 45 + 3 * 0.496)))
        t.check(ShapeHitTester.hit(noStroke, ShapePoint(70 + 3 * 0.868, 45 + 3 * 0.496)))
        t.check(ShapeHitTester.hit(noStroke, ShapePoint(50, 6)))     // stroke of the top edge
        // A path that already returns to its start gets no extra segment.
        t.equal(path(m.shapes[2])?.subpaths.first?.segments.count, 2)
    }

    t.suite("ShapeMeter: review — Miter joins beyond the limit are squared off") {
        func plan(_ join: ShapeLineJoin, limit: Double = 10) -> ShapeStrokePlan? {
            // A spike of about 5.7°: miter ratio ≈ 20, beyond the default limit of 10.
            let spike = ShapeSubpath(start: ShapePoint(0, 100), segments: [ShapeSegment(.line(to: ShapePoint(5, 0))),
                                                                            ShapeSegment(.line(to: ShapePoint(10, 100)))])
            var style = ShapeStrokeStyle()
            style.width = 6
            style.join = join
            style.miterLimit = limit
            return ShapeStroker.plan(for: ShapePath(subpaths: [spike]), style: style)
        }
        // Miter: squared off at limit × half width = 30 above the vertex; the patch covers the missing part.
        let miter = plan(.miter)
        t.equal(miter?.patches.count, 1)
        t.close(miter.flatMap(ShapeStroker.bounds)?.minY ?? 0, -30, accuracy: 1e-9)
        // (The flat ends of the slanted legs dip 3·sin(2.86°) ≈ 0.15 below y = 100.)
        t.close(miter.flatMap(ShapeStroker.bounds)?.maxY ?? 0, 100.15, accuracy: 0.01)
        t.close(plan(.miter, limit: 4).flatMap(ShapeStroker.bounds)?.minY ?? 0, -12, accuracy: 1e-9)
        // The cut edge is perpendicular to the miter direction (horizontal here) and centered on the spike.
        if let patch = miter?.patches.first, let r = ShapeMath.bounds(of: ShapePath(subpaths: [patch])) {
            t.close(r.center.x, 5, accuracy: 1e-9)
            let top = ([patch.start] + patch.segments.map(\.kind.end)).filter { abs($0.y + 30) < 1e-9 }
            t.equal(top.count, 2)
        } else {
            t.check(false, "clipped miter patch")
        }
        // MiterOrBevel bevels; Bevel and Round never need a patch; a miter within the limit is native.
        t.equal(plan(.miterOrBevel)?.patches.count, 0)
        // Beveled: the stroke ends just above the vertex (the bevel corners are ±3 along the legs' normals).
        t.close(plan(.miterOrBevel).flatMap(ShapeStroker.bounds)?.minY ?? 0, -0.15, accuracy: 0.01)
        t.equal(plan(.bevel)?.patches.count, 0)
        t.equal(plan(.miter, limit: 25)?.patches.count, 0)
        t.check((plan(.miter, limit: 25).flatMap(ShapeStroker.bounds)?.minY ?? 0) < -55)
        // Closed figures: every corner, the start vertex included (a thin triangle has three sharp-ish corners).
        let sliver = ShapeSubpath(start: ShapePoint(0, 0), segments: [ShapeSegment(.line(to: ShapePoint(200, 5))),
                                                                       ShapeSegment(.line(to: ShapePoint(0, 10)))],
                                  closed: true)
        var style = ShapeStrokeStyle()
        style.width = 2
        let closedPlan = ShapeStroker.plan(for: ShapePath(subpaths: [sliver]), style: style)
        t.equal(closedPlan?.patches.count, 1)   // only the 2.9° tip at (200,5); the start corners are ~92°
        t.close(closedPlan.flatMap(ShapeStroker.bounds)?.maxX ?? 0, 210, accuracy: 1e-6)
        // Hostile: reversing segments and zero-length segments make no patch and no NaN.
        let back = ShapeSubpath(start: .zero, segments: [ShapeSegment(.line(to: ShapePoint(10, 0))),
                                                         ShapeSegment(.line(to: ShapePoint(10, 0))),
                                                         ShapeSegment(.line(to: .zero))])
        let backPlan = ShapeStroker.plan(for: ShapePath(subpaths: [back]), style: style)
        t.equal(backPlan?.patches.count, 0)
        t.check(backPlan.flatMap(ShapeStroker.bounds).map { $0.minX.isFinite && $0.maxY.isFinite } ?? false)
        t.check(ShapeStroker.clippedMiter(at: .zero, incoming: ShapePoint(1, 0), outgoing: ShapePoint(1, 0),
                                          halfWidth: 1, limit: 10) == nil)

        // Through the parser: a graph-like path with default joins gets its spikes squared off.
        let (_, m, _) = try loadShape(t, "Shape=Path G | StrokeWidth 2\nG=0,100 | LineTo 2,0 | LineTo 4,100 | LineTo 6,0 | LineTo 8,100")
        t.equal(m.shapes.first?.strokePlan?.patches.count, 3)
    }

    t.suite("ShapeMeter: review — StrokeType only applies to closed shapes") {
        let (_, m, _) = try loadShape(t, """
        Shape=Line 0,10,100,10 | StrokeWidth 6 | StrokeType Outer
        Shape2=Arc 0,70,80,70 | StrokeWidth 6 | StrokeType Inner
        Shape3=Arc 0,70,80,70,*,*,*,*,*,1 | StrokeWidth 6 | StrokeType Inner
        Shape4=Combine Shape5 | Union Shape6
        Shape5=Line 0,0,10,10 | StrokeWidth 4 | StrokeType Outer
        Shape6=Rectangle 0,0,10,10
        """)
        let line = m.shapes[0]
        t.equal(line.strokeStyle.placement, .center)
        t.close(line.strokePlan?.width ?? 0, 6)
        closeRect(t, line.visualBounds, 0, 7, 100, 13, accuracy: 1e-9)
        t.check(ShapeHitTester.hit(line, ShapePoint(50, 12)))
        t.check(!ShapeHitTester.hit(line, ShapePoint(50, 15)))
        t.equal(m.shapes[1].strokeStyle.placement, .center)
        // Closed shapes keep it (an Arc closed by ShapeEnding, a combined shape).
        t.equal(m.shapes[2].strokeStyle.placement, .inner)
        t.equal(m.shapes[3].strokeStyle.placement, .outer)
    }

    t.suite("ShapeMeter: review — one-word StrokeColor / FillColor and MeterOrBevel from the manual") {
        let (_, m, _) = try loadShape(t, """
        Shape=Path MyPath | StrokeColor 0,255,0,255 | FillColor 1,2,3
        MyPath=0,0 | LineTo 10,0 | LineTo 10,10 | ClosePath 1
        Shape2=Rectangle 0,0,10,10 | StrokeColor nonsense | StrokeLineJoin MeterOrBevel, 3
        """)
        t.equal(m.shapes[0].stroke, .color(RGBA(r: 0, g: 255, b: 0)))
        t.equal(m.shapes[0].fill, .color(RGBA(r: 1, g: 2, b: 3)))
        t.equal(m.shapes[1].stroke, .color(.black))
        t.equal(m.shapes[1].strokeStyle.join, .miterOrBevel)
        t.close(m.shapes[1].strokeStyle.miterLimit, 3)
    }

    t.suite("ShapeMeter: review — hit testing combined shapes") {
        let (_, m, _) = try loadShape(t, """
        X=0
        Y=0
        Shape=Rectangle 0,0,60,60 | Fill Color 0,0,0,0 | StrokeWidth 4
        Shape2=Ellipse 60,60,20
        Shape3=Combine Shape | Exclude Shape2
        """)
        // Not filled (transparent): only the combined outline is solid, including the arc cut into the corner.
        t.check(m.hitTest(x: 30, y: 1))
        t.check(!m.hitTest(x: 30, y: 30))
        t.check(m.hitTest(x: 60 - 20 * 0.7071, y: 60 - 20 * 0.7071))
        t.check(!m.hitTest(x: 58, y: 58))
        // Repeated queries reuse the cached region (and agree).
        for _ in 0..<100 { t.check(m.hitTest(x: 30, y: 1)) }
    }

    t.suite("ShapeMeter: empty required parameters count as 0") {
        // FluentDash11's buttons: `Rectangle ,,100,50,8` (the author's screenshot shows them at the meter's X/Y).
        let (_, m, host) = try loadShape(t, "X=10\nY=20\nShape=Rectangle ,,100,50,8 | StrokeWidth 0\nShape2=Ellipse 5,,3")
        t.equal(m.shapes.count, 2, "\(host.logs)")
        closeRect(t, m.shapes.first?.bounds, 0, 0, 100, 50)
        closeRect(t, m.shapes.last?.bounds, 2, -3, 8, 3)
        let (_, bad, badHost) = try loadShape(t, "Shape=Rectangle ,,,\nShape2=Rectangle 1,2,3\nShape3=Rectangle *,0,5,5")
        t.equal(bad.shapes.count, 0, "no numbers at all, missing parameters and * are still errors")
        t.equal(badHost.logs.filter { $0.contains("needs 4 numeric parameters") }.count, 3)
    }
}
