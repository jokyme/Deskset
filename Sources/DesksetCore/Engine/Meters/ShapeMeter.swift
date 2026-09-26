import Foundation

/// `Meter=Shape` — vector shapes (clean-room implementation of docs.rainmeter.net/manual/meters/shape/).
///
/// `Shape`, `Shape2`, `Shape3`… each define one shape (Rectangle, Ellipse, Line, Arc, Curve, Path, Path1, Combine)
/// plus attribute and transform modifiers; see `ShapeParser`. Shapes are drawn in numeric order, relative to the
/// meter's position (content origin, i.e. after Padding), and are not clipped to the meter: parts at negative
/// coordinates extend left of / above the meter (manual notes on Ellipse and StrokeWidth).
///
/// Size: without W/H the meter reaches from its origin to the right/bottom edge of its shapes, stroke included
/// (half the StrokeWidth outside the outline, plus miter tips and caps), rounded to the nearest whole pixel —
/// negative extents do not make it larger. The manual only says meter W/H are whole pixels; this rule reproduces
/// the spacing of the manual's example skin screenshot exactly (e.g. a 70×70 square rotated 45° with StrokeWidth 4
/// is 87 wide: 84.5 + miter tip 2.83 → 87; a 100×100 rectangle with StrokeWidth 4 is 102), including a shape
/// rotated so it sticks out left of its meter into the previous meter's `R` gap.
///
/// Shapes are always drawn anti-aliased (the manual's images are; `AntiAlias` is not needed for shapes).
public final class ShapeMeter: Meter {
    /// Drawable shapes in drawing order (shapes consumed by a Combine are not listed).
    public private(set) var shapes: [ShapeItem] = []
    /// Increases whenever `shapes` changes, so the host can cache what it builds from them.
    public private(set) var revision = 0
    /// Opaque storage for the host's renderer (e.g. built CGPaths for the current `revision`).
    public var renderCache: AnyObject?

    private var loggedWarnings: Set<String> = []
    /// Flattened geometry for hit testing, rebuilt when `revision` changes.
    private var hitRegions: [ShapeHitTester.FlatRegion] = []
    private var hitRegionsRevision = -1
    static let maxNaturalSize = 16_384.0

    public override func readMeterOptions() {
        var parser = ShapeParser(lookup: { [unowned self] in self.option($0) })
        let parsed = parser.items(from: numberedOptions("Shape"))
        for warning in parser.warnings where loggedWarnings.count < 200 && loggedWarnings.insert(warning).inserted {
            skin.log("[\(name)] \(warning)", level: .warning)
        }
        if parsed != shapes {
            shapes = parsed
            revision &+= 1
        }
    }

    public override func naturalSize() -> (width: Double, height: Double) {
        var w = 0.0, h = 0.0
        for s in shapes {
            w = max(w, s.visualBounds.maxX)
            h = max(h, s.visualBounds.maxY)
        }
        func pixels(_ v: Double) -> Double { v.rounded(.toNearestOrAwayFromZero).clamped(0, ShapeMeter.maxNaturalSize) }
        return (pixels(w), pixels(h))
    }

    /// Mouse detection (skin coordinates): true over any solid part of the shapes — even outside the meter's
    /// frame — or over the meter's own SolidColor background. The meter's TransformationMatrix is taken into
    /// account. Overrides `Meter.hitTest`, so every mouse lookup of the skin (`Meter.isHit`) uses it.
    public override func hitTest(x: Double, y: Double) -> Bool {
        guard !hidden else { return false }
        var p = ShapePoint(x, y)
        if let m = transformationMatrix {
            guard let inverse = ShapeTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).inverted else { return false }
            p = inverse.apply(p)
        }
        if (solidColor.a > 0 || (solidColor2?.a ?? 0) > 0) && frame.contains(x: p.x, y: p.y) { return true }
        let origin = contentFrame
        let local = ShapePoint(p.x - origin.x, p.y - origin.y)
        if hitRegionsRevision != revision {
            hitRegions = shapes.map { ShapeHitTester.FlatRegion($0.geometry) }
            hitRegionsRevision = revision
        }
        return zip(shapes, hitRegions).contains { ShapeHitTester.hit($0.0, local, region: $0.1) }
    }
}
