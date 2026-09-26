import Foundation

// Geometry and paint model of the Shape meter (clean-room, from docs.rainmeter.net/manual/meters/shape/).
// Everything here is plain data in meter coordinates (origin = the meter's content origin, y grows downward,
// fractional "device independent pixels"). The host turns it into CGPaths; DesksetCore uses it for bounds,
// stroke planning and mouse hit testing.

public struct ShapePoint: Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = ShapePoint(0, 0)

    static func + (a: ShapePoint, b: ShapePoint) -> ShapePoint { ShapePoint(a.x + b.x, a.y + b.y) }
    static func - (a: ShapePoint, b: ShapePoint) -> ShapePoint { ShapePoint(a.x - b.x, a.y - b.y) }
    static func * (a: ShapePoint, k: Double) -> ShapePoint { ShapePoint(a.x * k, a.y * k) }

    var length: Double { (x * x + y * y).squareRoot() }
    func distance(to p: ShapePoint) -> Double { (self - p).length }
    /// Unit vector, or nil for a (near) zero vector.
    var normalized: ShapePoint? {
        let l = length
        return l > 1e-12 && l.isFinite ? ShapePoint(x / l, y / l) : nil
    }
    /// Perpendicular (rotated 90° counter-clockwise on screen).
    var perpendicular: ShapePoint { ShapePoint(-y, x) }
    var isFinite: Bool { x.isFinite && y.isFinite }
}

/// One drawing segment; its start is the end of the previous segment (or the subpath start).
public enum ShapeSegmentKind: Equatable {
    case line(to: ShapePoint)
    case quadratic(control: ShapePoint, to: ShapePoint)
    case cubic(control1: ShapePoint, control2: ShapePoint, to: ShapePoint)

    public var end: ShapePoint {
        switch self {
        case .line(let p): return p
        case .quadratic(_, let p): return p
        case .cubic(_, _, let p): return p
        }
    }

    func transformed(_ t: ShapeTransform) -> ShapeSegmentKind {
        switch self {
        case .line(let p): return .line(to: t.apply(p))
        case .quadratic(let c, let p): return .quadratic(control: t.apply(c), to: t.apply(p))
        case .cubic(let c1, let c2, let p): return .cubic(control1: t.apply(c1), control2: t.apply(c2), to: t.apply(p))
        }
    }
}

public struct ShapeSegment: Equatable {
    public var kind: ShapeSegmentKind
    /// False after `SetNoStroke 1` in a Path definition: the segment is part of the outline but not stroked.
    public var stroked: Bool
    /// `SetRoundJoin 1` in a Path definition: the join between this segment and the previous one is round.
    public var roundJoin: Bool

    public init(_ kind: ShapeSegmentKind, stroked: Bool = true, roundJoin: Bool = false) {
        self.kind = kind
        self.stroked = stroked
        self.roundJoin = roundJoin
    }
}

/// A figure: a start point followed by connected segments, optionally closed back to the start.
public struct ShapeSubpath: Equatable {
    public var start: ShapePoint
    public var segments: [ShapeSegment]
    public var closed: Bool

    public init(start: ShapePoint, segments: [ShapeSegment] = [], closed: Bool = false) {
        self.start = start
        self.segments = segments
        self.closed = closed
    }

    public var end: ShapePoint { segments.last?.kind.end ?? start }

    func transformed(_ t: ShapeTransform) -> ShapeSubpath {
        ShapeSubpath(start: t.apply(start),
                     segments: segments.map { ShapeSegment($0.kind.transformed(t), stroked: $0.stroked, roundJoin: $0.roundJoin) },
                     closed: closed)
    }
}

/// `Path` fills with the even-odd rule, `Path1` with the non-zero rule (manual, "Path1").
public enum ShapeFillRule: Equatable {
    case evenOdd, nonZero
}

public struct ShapePath: Equatable {
    public var subpaths: [ShapeSubpath]
    public var fillRule: ShapeFillRule

    public init(subpaths: [ShapeSubpath], fillRule: ShapeFillRule = .evenOdd) {
        self.subpaths = subpaths
        self.fillRule = fillRule
    }

    func transformed(_ t: ShapeTransform) -> ShapePath {
        t.isIdentity ? self : ShapePath(subpaths: subpaths.map { $0.transformed(t) }, fillRule: fillRule)
    }

    /// Every subpath closed (Combine closes open shapes before combining them).
    var closedCopy: ShapePath {
        ShapePath(subpaths: subpaths.map { ShapeSubpath(start: $0.start, segments: $0.segments, closed: true) },
                  fillRule: fillRule)
    }
}

/// `Combine` types.
public enum ShapeCombineMode: String, Equatable, CaseIterable {
    /// Parent and child merged.
    case union
    /// Only the overlap.
    case intersect
    /// Only the non-overlapping parts.
    case xor
    /// The parent minus the child.
    case exclude
}

public struct ShapeCombineStep: Equatable {
    public var mode: ShapeCombineMode
    public var geometry: ShapeGeometry

    public init(mode: ShapeCombineMode, geometry: ShapeGeometry) {
        self.mode = mode
        self.geometry = geometry
    }
}

/// Final geometry of a drawn shape, already transformed into meter coordinates.
public indirect enum ShapeGeometry: Equatable {
    case path(ShapePath)
    /// `Combine Parent | Mode Child | …`: applied left to right. Every operand is a closed region.
    case combined(ShapeGeometry, [ShapeCombineStep])

    func transformed(_ t: ShapeTransform) -> ShapeGeometry {
        if t.isIdentity { return self }
        switch self {
        case .path(let p):
            return .path(p.transformed(t))
        case .combined(let base, let steps):
            // Boolean operations commute with affine maps, so the combined shape's own transforms are pushed
            // down onto its operands.
            return .combined(base.transformed(t), steps.map { ShapeCombineStep(mode: $0.mode, geometry: $0.geometry.transformed(t)) })
        }
    }

    /// Nesting depth (1 for a plain path).
    var depth: Int {
        switch self {
        case .path: return 1
        case .combined(let base, let steps): return 1 + max(base.depth, steps.map(\.geometry.depth).max() ?? 0)
        }
    }
}

/// 2-D affine transform, same convention as CGAffineTransform: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
public struct ShapeTransform: Equatable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public var isIdentity: Bool { self == .identity }
    public var determinant: Double { a * d - b * c }

    public func apply(_ p: ShapePoint) -> ShapePoint {
        ShapePoint(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    /// `self` first, then `next`.
    public func then(_ next: ShapeTransform) -> ShapeTransform {
        ShapeTransform(a: a * next.a + b * next.c, b: a * next.b + b * next.d,
                       c: c * next.a + d * next.c, d: c * next.b + d * next.d,
                       tx: tx * next.a + ty * next.c + next.tx, ty: tx * next.b + ty * next.d + next.ty)
    }

    public var inverted: ShapeTransform? {
        let det = determinant
        guard abs(det) > 1e-12, det.isFinite else { return nil }
        return ShapeTransform(a: d / det, b: -b / det, c: -c / det, d: a / det,
                              tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det)
    }

    static func translation(_ dx: Double, _ dy: Double) -> ShapeTransform {
        ShapeTransform(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
    }

    /// Positive degrees rotate clockwise on screen (y down).
    static func rotation(degrees: Double, around p: ShapePoint) -> ShapeTransform {
        let r = degrees * .pi / 180
        let cs = cos(r), sn = sin(r)
        return translation(-p.x, -p.y)
            .then(ShapeTransform(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0))
            .then(translation(p.x, p.y))
    }

    static func scale(_ sx: Double, _ sy: Double, around p: ShapePoint) -> ShapeTransform {
        translation(-p.x, -p.y).then(ShapeTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)).then(translation(p.x, p.y))
    }

    /// x' = x + tan(ax)·(y − py), y' = y + tan(ay)·(x − px). Tangents are clamped so ±90° stays finite.
    static func skew(degreesX: Double, degreesY: Double, around p: ShapePoint) -> ShapeTransform {
        func t(_ deg: Double) -> Double { tan(deg * .pi / 180).clamped(-1000, 1000) }
        return translation(-p.x, -p.y).then(ShapeTransform(a: 1, b: t(degreesY), c: t(degreesX), d: 1, tx: 0, ty: 0))
            .then(translation(p.x, p.y))
    }
}

// MARK: Paint

public struct ShapeGradientStop: Equatable {
    public var color: RGBA
    /// 0…1 along the gradient.
    public var position: Double

    public init(color: RGBA, position: Double) {
        self.color = color
        self.position = position
    }
}

/// Linear gradient in the shape's own (untransformed) space: colors run from `start` (position 0) to `end`
/// (position 1) and are clamped beyond them. Map through `ShapeItem.paintTransform` to reach meter coordinates.
public struct ShapeLinearGradient: Equatable {
    public var start: ShapePoint
    public var end: ShapePoint
    /// Sorted, all positions in 0…1, at least one stop.
    public var stops: [ShapeGradientStop]
    /// `LinearGradient1`: interpolate in linear light instead of gamma-encoded sRGB.
    public var linearGamma: Bool
}

/// Radial (elliptical) gradient in the shape's own space: position 0 at `origin`, position 1 on the ellipse
/// around `center` with radii `radiusX` / `radiusY`.
public struct ShapeRadialGradient: Equatable {
    public var center: ShapePoint
    public var origin: ShapePoint
    public var radiusX: Double
    public var radiusY: Double
    public var stops: [ShapeGradientStop]
    public var linearGamma: Bool
}

public enum ShapePaint: Equatable {
    case none
    case color(RGBA)
    case linearGradient(ShapeLinearGradient)
    case radialGradient(ShapeRadialGradient)

    /// False when nothing would be painted (no paint, or every color fully transparent).
    public var isVisible: Bool {
        switch self {
        case .none: return false
        case .color(let c): return c.a > 0
        case .linearGradient(let g): return g.stops.contains { $0.color.a > 0 }
        case .radialGradient(let g): return g.stops.contains { $0.color.a > 0 } && g.radiusX > 0 && g.radiusY > 0
        }
    }
}

// MARK: Stroke

public enum ShapeLineCap: String, Equatable {
    case flat, round, square, triangle
}

public enum ShapeLineJoin: String, Equatable {
    /// Mitered up to the miter limit, then squared off (see `ShapeStroker.clippedMiter`).
    case miter
    case bevel
    case round
    /// Miter, or bevel when the miter limit would be exceeded.
    case miterOrBevel
}

/// Where the stroke sits relative to the outline. Not in the manual (see ShapeParser); default `center`.
public enum ShapeStrokePlacement: Equatable {
    case center, outer, inner
}

public struct ShapeStrokeStyle: Equatable {
    public var width: Double = 1
    public var startCap = ShapeLineCap.flat
    public var endCap = ShapeLineCap.flat
    public var dashCap = ShapeLineCap.flat
    public var join = ShapeLineJoin.miter
    public var miterLimit: Double = 10
    /// Dash, gap, dash, gap… as multiples of `width` (empty = solid).
    public var dashes: [Double] = []
    /// Multiple of `width`.
    public var dashOffset: Double = 0
    public var placement = ShapeStrokePlacement.center

    public init() {}
}

/// One piece of stroke to draw natively (CGPath stroking): the host strokes `subpath` with `ShapeStrokePlan.width`,
/// this join and this cap. `cap` is never `.triangle` (triangle caps are emitted as patches).
public struct ShapeStrokeRun: Equatable {
    public var subpath: ShapeSubpath
    public var join: ShapeLineJoin
    public var cap: ShapeLineCap
}

/// How to draw a stroke: native runs plus closed patches (caps, forced round joins) filled with the stroke paint.
/// Pieces may overlap; the host must paint their union once (not blend each piece separately).
public struct ShapeStrokePlan: Equatable {
    public var width: Double
    public var miterLimit: Double
    public var runs: [ShapeStrokeRun]
    public var patches: [ShapeSubpath]
    /// `.outer` / `.inner`: the pieces are twice the stroke width and must be clipped to the outside / inside of
    /// the shape's fill region.
    public var placement: ShapeStrokePlacement

    public var isEmpty: Bool { runs.isEmpty && patches.isEmpty }
}

// MARK: Items

/// Rectangle in meter coordinates.
public struct ShapeRect: Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: ShapePoint { ShapePoint((minX + maxX) / 2, (minY + maxY) / 2) }

    func union(_ o: ShapeRect) -> ShapeRect {
        ShapeRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    func intersection(_ o: ShapeRect) -> ShapeRect? {
        let r = ShapeRect(minX: max(minX, o.minX), minY: max(minY, o.minY), maxX: min(maxX, o.maxX), maxY: min(maxY, o.maxY))
        return r.minX <= r.maxX && r.minY <= r.maxY ? r : nil
    }

    func insetBy(_ d: Double) -> ShapeRect {
        ShapeRect(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }

    func contains(_ p: ShapePoint) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
}

/// Accumulates a bounding box.
struct ShapeBoundsAccumulator {
    private(set) var rect: ShapeRect?

    mutating func add(_ p: ShapePoint) {
        guard p.isFinite else { return }
        if let r = rect {
            rect = ShapeRect(minX: min(r.minX, p.x), minY: min(r.minY, p.y), maxX: max(r.maxX, p.x), maxY: max(r.maxY, p.y))
        } else {
            rect = ShapeRect(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)
        }
    }

    mutating func add(_ r: ShapeRect?) {
        guard let r else { return }
        rect = rect.map { $0.union(r) } ?? r
    }
}

/// One shape the meter draws (after Combine consumed its parts), in drawing order.
public struct ShapeItem: Equatable {
    /// N of the `ShapeN` option (1 for `Shape`).
    public var index: Int
    public var geometry: ShapeGeometry
    /// Open shapes get start/end caps and are not filled by default.
    public var closed: Bool
    public var fill: ShapePaint
    public var stroke: ShapePaint
    public var strokeStyle: ShapeStrokeStyle
    /// Stroke to draw for `.path` geometry (nil when there is no stroke, or for `.combined` geometry, whose
    /// outline is only known after the host has combined it; the host then calls `ShapeStroker.plan`).
    public var strokePlan: ShapeStrokePlan?
    /// Maps gradient coordinates (the shape's untransformed space) to meter coordinates.
    public var paintTransform: ShapeTransform
    /// Geometry bounds in meter coordinates (conservative for combined shapes).
    public var bounds: ShapeRect
    /// Bounds including the stroke.
    public var visualBounds: ShapeRect
}
