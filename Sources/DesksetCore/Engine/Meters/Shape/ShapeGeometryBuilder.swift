import Foundation

/// Builds the outlines of the basic shape types as segment lists (arcs become cubic Béziers).
///
/// Where the manual is silent, figures follow SVG conventions: rectangles start at the top edge after the
/// top-left corner radius and run clockwise on screen, ellipses start at their rightmost point and run clockwise.
/// This only matters for where dash patterns begin.
public enum ShapeGeometryBuilder {
    /// Circle-quarter control-point factor for cubic arcs: 4/3·tan(π/8).
    static let kappa = 0.5522847498307936

    /// `Rectangle X, Y, Width, Height[, RadiusX[, RadiusY]]` — closed. A negative width/height extends left/up
    /// (judgment call); radii are made non-negative, RadiusY defaults to RadiusX and both are limited to half the
    /// width / height.
    public static func rectangle(x: Double, y: Double, width: Double, height: Double,
                                 radiusX: Double = 0, radiusY: Double? = nil) -> ShapeSubpath {
        let x0 = min(x, x + width), y0 = min(y, y + height)
        let w = abs(width), h = abs(height)
        let rx = min(max(radiusX, 0), w / 2)
        let ry = min(max(radiusY ?? radiusX, 0), h / 2)
        guard rx > 0, ry > 0 else {
            return ShapeSubpath(start: ShapePoint(x0, y0), segments: [
                ShapeSegment(.line(to: ShapePoint(x0 + w, y0))),
                ShapeSegment(.line(to: ShapePoint(x0 + w, y0 + h))),
                ShapeSegment(.line(to: ShapePoint(x0, y0 + h))),
            ], closed: true)
        }
        let kx = rx * kappa, ky = ry * kappa
        let x1 = x0 + w, y1 = y0 + h
        var segs: [ShapeSegment] = []
        func line(_ px: Double, _ py: Double) {
            let from = segs.last?.kind.end ?? ShapePoint(x0 + rx, y0)
            if from.distance(to: ShapePoint(px, py)) > 1e-9 { segs.append(ShapeSegment(.line(to: ShapePoint(px, py)))) }
        }
        func corner(_ c1: ShapePoint, _ c2: ShapePoint, _ to: ShapePoint) {
            segs.append(ShapeSegment(.cubic(control1: c1, control2: c2, to: to)))
        }
        line(x1 - rx, y0)
        corner(ShapePoint(x1 - rx + kx, y0), ShapePoint(x1, y0 + ry - ky), ShapePoint(x1, y0 + ry))
        line(x1, y1 - ry)
        corner(ShapePoint(x1, y1 - ry + ky), ShapePoint(x1 - rx + kx, y1), ShapePoint(x1 - rx, y1))
        line(x0 + rx, y1)
        corner(ShapePoint(x0 + rx - kx, y1), ShapePoint(x0, y1 - ry + ky), ShapePoint(x0, y1 - ry))
        line(x0, y0 + ry)
        corner(ShapePoint(x0, y0 + ry - ky), ShapePoint(x0 + rx - kx, y0), ShapePoint(x0 + rx, y0))
        return ShapeSubpath(start: ShapePoint(x0 + rx, y0), segments: segs, closed: true)
    }

    /// `Ellipse CenterX, CenterY, RadiusX[, RadiusY]` — closed; RadiusY defaults to RadiusX.
    public static func ellipse(centerX cx: Double, centerY cy: Double, radiusX: Double, radiusY: Double? = nil) -> ShapeSubpath {
        let rx = abs(radiusX), ry = abs(radiusY ?? radiusX)
        let kx = rx * kappa, ky = ry * kappa
        let right = ShapePoint(cx + rx, cy), bottom = ShapePoint(cx, cy + ry)
        let left = ShapePoint(cx - rx, cy), top = ShapePoint(cx, cy - ry)
        return ShapeSubpath(start: right, segments: [
            ShapeSegment(.cubic(control1: ShapePoint(cx + rx, cy + ky), control2: ShapePoint(cx + kx, cy + ry), to: bottom)),
            ShapeSegment(.cubic(control1: ShapePoint(cx - kx, cy + ry), control2: ShapePoint(cx - rx, cy + ky), to: left)),
            ShapeSegment(.cubic(control1: ShapePoint(cx - rx, cy - ky), control2: ShapePoint(cx - kx, cy - ry), to: top)),
            ShapeSegment(.cubic(control1: ShapePoint(cx + kx, cy - ry), control2: ShapePoint(cx + rx, cy - ky), to: right)),
        ], closed: true)
    }

    /// Elliptical arc from `from` to `to` as cubic Béziers (an empty list when the points coincide).
    ///
    /// Manual (Arc shape): "An arc describes two virtual ellipses intersecting the starting and ending points. One
    /// clockwise and one counter-clockwise"; SweepDirection 0 (default) is clockwise, 1 counter-clockwise; ArcSize
    /// 0 (default) small, 1 large; RotationAngle rotates the ellipses. The math is the standard endpoint → center
    /// conversion (as for SVG arcs). Judgment calls where the manual is silent:
    /// - "Clockwise" is as seen on screen (y down).
    /// - Missing radii: RadiusX defaults to half the distance between the points (a half circle); RadiusY defaults
    ///   to RadiusX. Radii too small to reach the end point are scaled up just enough (like SVG); a zero radius
    ///   draws a straight line.
    public static func arc(from: ShapePoint, to: ShapePoint, radiusX: Double?, radiusY: Double?,
                           rotation: Double = 0, clockwise: Bool = true, largeArc: Bool = false) -> [ShapeSegmentKind] {
        let dist = from.distance(to: to)
        guard dist > 1e-12, dist.isFinite else { return [] }
        var rx = abs(radiusX ?? dist / 2)
        var ry = abs(radiusY ?? rx)
        guard rx > 1e-12, ry > 1e-12 else { return [.line(to: to)] }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (from.x - to.x) / 2, dy2 = (from.y - to.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s
            ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den > 0 ? (max(num, 0) / den).squareRoot() : 0
        // SVG's sweep flag 1 is the positive-angle (clockwise on screen) direction.
        if largeArc == clockwise { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (from.x + to.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (from.y + to.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = atan2(uy, ux)
        var delta = angle(ux, uy, vx, vy)
        if clockwise && delta < 0 { delta += 2 * .pi }
        if !clockwise && delta > 0 { delta -= 2 * .pi }
        guard delta.isFinite, cx.isFinite, cy.isFinite else { return [.line(to: to)] }

        let pieces = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: Double) -> ShapePoint {
            let ex = rx * cos(t), ey = ry * sin(t)
            return ShapePoint(cx + ex * cosPhi - ey * sinPhi, cy + ex * sinPhi + ey * cosPhi)
        }
        func derivative(_ t: Double) -> ShapePoint {
            let ex = -rx * sin(t), ey = ry * cos(t)
            return ShapePoint(ex * cosPhi - ey * sinPhi, ex * sinPhi + ey * cosPhi)
        }
        var result: [ShapeSegmentKind] = []
        var t = theta1
        var p0 = from
        for i in 0..<pieces {
            let t2 = t + step
            let p3 = i == pieces - 1 ? to : point(t2)
            let c1 = p0 + derivative(t) * k
            let c2 = p3 - derivative(t2) * k
            result.append(.cubic(control1: c1, control2: c2, to: p3))
            p0 = p3
            t = t2
        }
        return result
    }
}

// MARK: Bounds, tangents, flattening

enum ShapeMath {
    /// Tight bounds of a subpath (Bézier extrema, not control points).
    static func bounds(of subpath: ShapeSubpath, into acc: inout ShapeBoundsAccumulator) {
        acc.add(subpath.start)
        var p0 = subpath.start
        for seg in subpath.segments {
            switch seg.kind {
            case .line(let p):
                acc.add(p)
            case .quadratic(let c, let p):
                acc.add(p)
                for t in quadraticExtrema(p0.x, c.x, p.x) + quadraticExtrema(p0.y, c.y, p.y) {
                    acc.add(quadraticPoint(p0, c, p, t))
                }
            case .cubic(let c1, let c2, let p):
                acc.add(p)
                for t in cubicExtrema(p0.x, c1.x, c2.x, p.x) + cubicExtrema(p0.y, c1.y, c2.y, p.y) {
                    acc.add(cubicPoint(p0, c1, c2, p, t))
                }
            }
            p0 = seg.kind.end
        }
    }

    static func bounds(of path: ShapePath) -> ShapeRect? {
        var acc = ShapeBoundsAccumulator()
        for s in path.subpaths { bounds(of: s, into: &acc) }
        return acc.rect
    }

    /// Interior points of a curve where its tangent is vertical (`vertical`) or horizontal.
    static func extrema(from p0: ShapePoint, _ kind: ShapeSegmentKind) -> [(point: ShapePoint, vertical: Bool)] {
        switch kind {
        case .line:
            return []
        case .quadratic(let c, let p):
            return quadraticExtrema(p0.x, c.x, p.x).map { (quadraticPoint(p0, c, p, $0), true) }
                + quadraticExtrema(p0.y, c.y, p.y).map { (quadraticPoint(p0, c, p, $0), false) }
        case .cubic(let c1, let c2, let p):
            return cubicExtrema(p0.x, c1.x, c2.x, p.x).map { (cubicPoint(p0, c1, c2, p, $0), true) }
                + cubicExtrema(p0.y, c1.y, c2.y, p.y).map { (cubicPoint(p0, c1, c2, p, $0), false) }
        }
    }

    private static func quadraticExtrema(_ a: Double, _ b: Double, _ c: Double) -> [Double] {
        let den = a - 2 * b + c
        guard abs(den) > 1e-12 else { return [] }
        let t = (a - b) / den
        return t > 0 && t < 1 ? [t] : []
    }

    private static func cubicExtrema(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> [Double] {
        // Derivative / 3: a·t² + b·t + c.
        let a = -p0 + 3 * p1 - 3 * p2 + p3
        let b = 2 * (p0 - 2 * p1 + p2)
        let c = p1 - p0
        var roots: [Double] = []
        if abs(a) < 1e-12 {
            if abs(b) > 1e-12 { roots.append(-c / b) }
        } else {
            let disc = b * b - 4 * a * c
            if disc >= 0 {
                let s = disc.squareRoot()
                roots.append((-b + s) / (2 * a))
                roots.append((-b - s) / (2 * a))
            }
        }
        return roots.filter { $0 > 0 && $0 < 1 }
    }

    static func quadraticPoint(_ p0: ShapePoint, _ c: ShapePoint, _ p: ShapePoint, _ t: Double) -> ShapePoint {
        let u = 1 - t
        return p0 * (u * u) + c * (2 * u * t) + p * (t * t)
    }

    static func cubicPoint(_ p0: ShapePoint, _ c1: ShapePoint, _ c2: ShapePoint, _ p: ShapePoint, _ t: Double) -> ShapePoint {
        let u = 1 - t
        return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p * (t * t * t)
    }

    /// Direction in which a segment leaves `start` (nil when the segment is a point).
    static func startTangent(_ start: ShapePoint, _ kind: ShapeSegmentKind) -> ShapePoint? {
        switch kind {
        case .line(let p):
            return (p - start).normalized
        case .quadratic(let c, let p):
            return (c - start).normalized ?? (p - start).normalized
        case .cubic(let c1, let c2, let p):
            return (c1 - start).normalized ?? (c2 - start).normalized ?? (p - start).normalized
        }
    }

    /// Direction in which a segment arrives at its end.
    static func endTangent(_ start: ShapePoint, _ kind: ShapeSegmentKind) -> ShapePoint? {
        switch kind {
        case .line(let p):
            return (p - start).normalized
        case .quadratic(let c, let p):
            return (p - c).normalized ?? (p - start).normalized
        case .cubic(let c1, let c2, let p):
            return (p - c2).normalized ?? (p - c1).normalized ?? (p - start).normalized
        }
    }

    /// Hard limit on points produced for one curve segment.
    static let maxStepsPerCurve = 256

    /// Appends the points of `kind` (excluding its start) to `out`, flattening curves so no point of the curve is
    /// farther than about `tolerance` from the polyline (Wang's formula).
    static func flatten(from p0: ShapePoint, _ kind: ShapeSegmentKind, tolerance: Double, into out: inout [ShapePoint]) {
        switch kind {
        case .line(let p):
            out.append(p)
        case .quadratic(let c, let p):
            let m = (p0 - c * 2 + p).length
            let n = steps(m * 0.25, tolerance)
            if n > 1 {
                for i in 1..<n { out.append(quadraticPoint(p0, c, p, Double(i) / Double(n))) }
            }
            out.append(p)
        case .cubic(let c1, let c2, let p):
            let m = max((p0 - c1 * 2 + c2).length, (c1 - c2 * 2 + p).length)
            let n = steps(m * 0.75, tolerance)
            if n > 1 {
                for i in 1..<n { out.append(cubicPoint(p0, c1, c2, p, Double(i) / Double(n))) }
            }
            out.append(p)
        }
    }

    private static func steps(_ scaled: Double, _ tolerance: Double) -> Int {
        let v = (scaled / max(tolerance, 1e-6)).squareRoot().rounded(.up)
        guard v.isFinite else { return maxStepsPerCurve }
        return Int(v.clamped(1, Double(maxStepsPerCurve)))
    }

    /// The subpath as a polyline (closing edge not repeated).
    static func polyline(_ subpath: ShapeSubpath, tolerance: Double) -> [ShapePoint] {
        var pts = [subpath.start]
        var p0 = subpath.start
        for seg in subpath.segments {
            flatten(from: p0, seg.kind, tolerance: tolerance, into: &pts)
            p0 = seg.kind.end
        }
        return pts
    }

    // MARK: Point tests

    /// Winding number and crossing count of the (implicitly closed) polygons at `p`.
    static func contains(_ polygons: [[ShapePoint]], _ p: ShapePoint, rule: ShapeFillRule) -> Bool {
        var winding = 0
        var crossings = 0
        for poly in polygons where poly.count >= 3 {
            var j = poly.count - 1
            for i in 0..<poly.count {
                let a = poly[j], b = poly[i]
                if (a.y <= p.y) != (b.y <= p.y) {
                    let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                    if x > p.x {
                        crossings += 1
                        winding += b.y > a.y ? 1 : -1
                    }
                }
                j = i
            }
        }
        return rule == .evenOdd ? crossings % 2 == 1 : winding != 0
    }

    static func distance(_ p: ShapePoint, segmentFrom a: ShapePoint, to b: ShapePoint) -> (distance: Double, closest: ShapePoint) {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        var t = len2 > 0 ? ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2 : 0
        t = min(max(t, 0), 1)
        let q = a + ab * t
        return (p.distance(to: q), q)
    }
}
