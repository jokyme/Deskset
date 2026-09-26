import AppKit
import DesksetCore

/// CoreGraphics side of the Shape meter: turns `ShapeItem`s into CGPaths once per meter revision (Combine via
/// CGPath boolean operations, strokes via `ShapeStrokePlan`) and paints them.
enum ShapeCG {
    /// What `drawShape` needs for one item, built once per `ShapeMeter.revision`.
    struct BuiltShape {
        let item: ShapeItem
        /// Fill region (open figures implicitly closed).
        let region: CGPath
        let rule: CGPathFillRule
        /// Stroke outlines; each is filled with the non-zero rule, and they must be painted as one union.
        let strokePieces: [CGPath]
        /// Outer/inner strokes are clipped to this (the region's complement for outer strokes).
        let strokeClip: (path: CGPath, rule: CGPathFillRule)?
        let fillGradient: CGGradient?
        let strokeGradient: CGGradient?
        /// Area touched by the shape (for transparency layers).
        let extent: CGRect
    }

    final class Cache {
        let revision: Int
        let shapes: [BuiltShape]

        init(revision: Int, shapes: [BuiltShape]) {
            self.revision = revision
            self.shapes = shapes
        }
    }

    static func built(for meter: ShapeMeter) -> [BuiltShape] {
        let old = meter.renderCache as? Cache
        if let old, old.revision == meter.revision { return old.shapes }
        // A new revision usually changes one or two shapes (a gauge arc) while the rest (tracks, dashed rings) stay
        // the same: reuse what was built for identical items instead of stroking / combining them again.
        var previous: [Int: BuiltShape] = [:]
        for s in old?.shapes ?? [] { previous[s.item.index] = s }
        let shapes = meter.shapes.map { item -> BuiltShape in
            if let s = previous[item.index], s.item == item { return s }
            return build(item)
        }
        meter.renderCache = Cache(revision: meter.revision, shapes: shapes)
        return shapes
    }

    // MARK: Building

    static func build(_ item: ShapeItem) -> BuiltShape {
        let region: CGPath
        let rule: CGPathFillRule
        var plan = item.strokePlan
        switch item.geometry {
        case .path(let p):
            region = cgPath(p.subpaths)
            rule = p.fillRule == .evenOdd ? .evenOdd : .winding
        case .combined:
            region = combinedRegion(item.geometry)
            rule = .winding
            if item.strokeStyle.width > 0, item.stroke.isVisible {
                plan = ShapeStroker.plan(for: ShapePath(subpaths: subpaths(of: region), fillRule: .nonZero),
                                         style: item.strokeStyle)
            }
        }
        var pieces: [CGPath] = []
        var clip: (CGPath, CGPathFillRule)?
        if let plan, item.stroke.isVisible {
            for run in plan.runs {
                pieces.append(cgPath([run.subpath]).copy(strokingWithWidth: plan.width, lineCap: cgCap(run.cap),
                                                         lineJoin: cgJoin(run.join), miterLimit: plan.miterLimit))
            }
            pieces += plan.patches.map { cgPath([$0]) }
            switch plan.placement {
            case .inner:
                clip = (region, rule)
            case .outer where !region.isEmpty:
                let big = CGPath(rect: region.boundingBoxOfPath.insetBy(dx: -plan.width * 2 - 10, dy: -plan.width * 2 - 10),
                                 transform: nil)
                clip = (big.subtracting(region, using: rule), .winding)
            case .center, .outer:
                break
            }
        }
        // The transparency layers used for translucent / gradient strokes clip to `extent`, so it must hold every
        // stroke piece: `visualBounds` is only an estimate for combined shapes (whose miter tips it does not know).
        let v = item.visualBounds
        var extent = CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height)
        for piece in pieces { extent = extent.union(piece.boundingBoxOfPath) }
        extent = extent.insetBy(dx: -2, dy: -2)
        return BuiltShape(item: item, region: region, rule: rule, strokePieces: pieces,
                          strokeClip: clip.map { (path: $0.0, rule: $0.1) },
                          fillGradient: gradient(item.fill), strokeGradient: gradient(item.stroke), extent: extent)
    }

    static func cgPath(_ subpaths: [ShapeSubpath]) -> CGPath {
        let path = CGMutablePath()
        for sub in subpaths {
            path.move(to: cg(sub.start))
            for seg in sub.segments {
                switch seg.kind {
                case .line(let p): path.addLine(to: cg(p))
                case .quadratic(let c, let p): path.addQuadCurve(to: cg(p), control: cg(c))
                case .cubic(let c1, let c2, let p): path.addCurve(to: cg(p), control1: cg(c1), control2: cg(c2))
                }
            }
            if sub.closed { path.closeSubpath() }
        }
        return path
    }

    /// Region of a (possibly nested) Combine: every operand is a closed region interpreted with its own fill rule
    /// (even-odd operands are normalized first so all operations can use the non-zero rule).
    static func combinedRegion(_ g: ShapeGeometry) -> CGPath {
        switch g {
        case .path(let p):
            let path = cgPath(p.subpaths.map { ShapeSubpath(start: $0.start, segments: $0.segments, closed: true) })
            return p.fillRule == .evenOdd ? path.normalized(using: .evenOdd) : path
        case .combined(let base, let steps):
            var r = combinedRegion(base)
            for step in steps {
                let other = combinedRegion(step.geometry)
                switch step.mode {
                case .union: r = r.union(other, using: .winding)
                case .intersect: r = r.intersection(other, using: .winding)
                case .xor: r = r.symmetricDifference(other, using: .winding)
                case .exclude: r = r.subtracting(other, using: .winding)
                }
            }
            return r
        }
    }

    /// Back from CGPath to the engine's model (for stroking combined outlines).
    static func subpaths(of path: CGPath) -> [ShapeSubpath] {
        var result: [ShapeSubpath] = []
        var current: ShapeSubpath?
        func point(_ p: CGPoint) -> ShapePoint { ShapePoint(Double(p.x), Double(p.y)) }
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint:
                if let c = current { result.append(c) }
                current = ShapeSubpath(start: point(e.points[0]))
            case .addLineToPoint:
                current?.segments.append(ShapeSegment(.line(to: point(e.points[0]))))
            case .addQuadCurveToPoint:
                current?.segments.append(ShapeSegment(.quadratic(control: point(e.points[0]), to: point(e.points[1]))))
            case .addCurveToPoint:
                current?.segments.append(ShapeSegment(.cubic(control1: point(e.points[0]), control2: point(e.points[1]),
                                                             to: point(e.points[2]))))
            case .closeSubpath:
                if var c = current {
                    c.closed = true
                    result.append(c)
                    current = ShapeSubpath(start: c.start)
                }
            @unknown default:
                break
            }
        }
        if let c = current, !c.segments.isEmpty { result.append(c) }
        return result
    }

    static func cg(_ p: ShapePoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }

    static func cgCap(_ c: ShapeLineCap) -> CGLineCap {
        switch c {
        case .flat, .triangle: return .butt
        case .round: return .round
        case .square: return .square
        }
    }

    static func cgJoin(_ j: ShapeLineJoin) -> CGLineJoin {
        switch j {
        case .miter, .miterOrBevel: return .miter
        case .bevel: return .bevel
        case .round: return .round
        }
    }

    static func cgTransform(_ t: ShapeTransform) -> CGAffineTransform {
        CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
    }

    // MARK: Gradients

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)

    /// `LinearGradient1` / `RadialGradient1` interpolate in linear light; the plain forms in sRGB.
    static func gradient(_ paint: ShapePaint) -> CGGradient? {
        let stops: [ShapeGradientStop]
        let linear: Bool
        switch paint {
        case .linearGradient(let g): (stops, linear) = (g.stops, g.linearGamma)
        case .radialGradient(let g): (stops, linear) = (g.stops, g.linearGamma)
        default: return nil
        }
        guard let first = stops.first, let space = linear ? linearSRGB : srgb else { return nil }
        let list = stops.count == 1 ? [first, ShapeGradientStop(color: first.color, position: 1)] : stops
        return CGGradient(colorsSpace: space, colors: list.map(\.color.cgColor) as CFArray,
                          locations: list.map { CGFloat($0.position) })
    }

    // MARK: Drawing

    static func draw(_ s: BuiltShape, _ ctx: CGContext) {
        let item = s.item
        if item.fill.isVisible {
            ctx.saveGState()
            if case .color(let c) = item.fill {
                ctx.addPath(s.region)
                ctx.setFillColor(c.cgColor)
                ctx.fillPath(using: s.rule)
            } else {
                ctx.addPath(s.region)
                ctx.clip(using: s.rule)
                drawGradient(item.fill, s.fillGradient, transform: item.paintTransform, ctx)
            }
            ctx.restoreGState()
        }
        guard !s.strokePieces.isEmpty, item.stroke.isVisible else { return }
        ctx.saveGState()
        if let clip = s.strokeClip {
            ctx.addPath(clip.path)
            ctx.clip(using: clip.rule)
        }
        switch item.stroke {
        case .color(let c) where s.strokePieces.count == 1 || c.a >= 255:
            ctx.setFillColor(c.cgColor)
            for piece in s.strokePieces {
                ctx.addPath(piece)
                ctx.fillPath(using: .winding)
            }
        case .color(let c):
            // Overlapping pieces must not darken each other: paint their union opaquely in a layer.
            ctx.setAlpha(CGFloat(c.a / 255))
            ctx.beginTransparencyLayer(in: s.extent, auxiliaryInfo: nil)
            ctx.setFillColor(RGBA(r: c.r, g: c.g, b: c.b).cgColor)
            for piece in s.strokePieces {
                ctx.addPath(piece)
                ctx.fillPath(using: .winding)
            }
            ctx.endTransparencyLayer()
        default:
            if s.strokePieces.count == 1 {
                ctx.addPath(s.strokePieces[0])
                ctx.clip(using: .winding)
                drawGradient(item.stroke, s.strokeGradient, transform: item.paintTransform, ctx)
            } else {
                ctx.beginTransparencyLayer(in: s.extent, auxiliaryInfo: nil)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                for piece in s.strokePieces {
                    ctx.addPath(piece)
                    ctx.fillPath(using: .winding)
                }
                ctx.setBlendMode(.sourceIn)
                drawGradient(item.stroke, s.strokeGradient, transform: item.paintTransform, ctx)
                ctx.endTransparencyLayer()
            }
        }
        ctx.restoreGState()
    }

    /// Paints a gradient over the current clip. Gradients live in the shape's untransformed space.
    static func drawGradient(_ paint: ShapePaint, _ gradient: CGGradient?, transform: ShapeTransform, _ ctx: CGContext) {
        guard let gradient else { return }
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        guard abs(transform.determinant) > 1e-9 else {
            // A shape scaled to nothing: no gradient space left; show the end color.
            if case .linearGradient(let g) = paint, let c = g.stops.last?.color { fillClip(c, ctx) }
            if case .radialGradient(let g) = paint, let c = g.stops.last?.color { fillClip(c, ctx) }
            return
        }
        ctx.saveGState()
        ctx.concatenate(cgTransform(transform))
        switch paint {
        case .linearGradient(let g):
            ctx.drawLinearGradient(gradient, start: cg(g.start), end: cg(g.end), options: options)
        case .radialGradient(let g):
            if g.radiusX > 1e-9, g.radiusY > 1e-9 {
                ctx.translateBy(x: g.center.x, y: g.center.y)
                ctx.scaleBy(x: 1, y: g.radiusY / g.radiusX)
                let focus = CGPoint(x: g.origin.x - g.center.x, y: (g.origin.y - g.center.y) * g.radiusX / g.radiusY)
                ctx.drawRadialGradient(gradient, startCenter: focus, startRadius: 0, endCenter: .zero,
                                       endRadius: g.radiusX, options: options)
            } else if let c = g.stops.last?.color {
                ctx.restoreGState()
                fillClip(c, ctx)
                return
            }
        default:
            break
        }
        ctx.restoreGState()
    }

    private static func fillClip(_ c: RGBA, _ ctx: CGContext) {
        ctx.setFillColor(c.cgColor)
        ctx.fill(ctx.boundingBoxOfClipPath)
    }
}
