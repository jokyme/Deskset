import Foundation

/// Mouse detection on shapes. Manual ("Mouse Detection on Shapes"): "the mouse is only detected on any solid part
/// of the drawing created by any and all shapes in the meter", even outside the meter's W/H.
///
/// Judgment calls: a fill or stroke whose colors are all fully transparent is not "solid" (alpha 1 is, the usual
/// trick for invisible click areas); dashes, caps and miter tips are ignored (the stroke counts as solid along the
/// whole outline); curves are tested flattened to 0.25 px.
enum ShapeHitTester {
    static let tolerance = 0.25

    /// `region` is `FlatRegion(item.geometry)`, passed in when the caller caches it.
    static func hit(_ item: ShapeItem, _ p: ShapePoint, region prebuilt: FlatRegion? = nil) -> Bool {
        let fillVisible = item.fill.isVisible
        let strokeWidth = item.strokeStyle.width
        let strokeVisible = item.stroke.isVisible && strokeWidth > 0
        guard fillVisible || strokeVisible, item.visualBounds.insetBy(-1).contains(p) else { return false }
        let region = prebuilt ?? FlatRegion(item.geometry)
        let inside = region.contains(p)
        if fillVisible && inside { return true }
        guard strokeVisible else { return false }
        switch item.strokeStyle.placement {
        case .center: return region.isNearOutline(p, within: strokeWidth / 2)
        case .outer: return !inside && region.isNearOutline(p, within: strokeWidth)
        case .inner: return inside && region.isNearOutline(p, within: strokeWidth)
        }
    }

    /// Flattened geometry for point queries.
    indirect enum FlatRegion {
        case polygons([[ShapePoint]], ShapeFillRule, outline: [(ShapePoint, ShapePoint)])
        /// `edges`: every operand edge, collected once here rather than on every mouse move.
        case combined(FlatRegion, [(ShapeCombineMode, FlatRegion)], edges: [(ShapePoint, ShapePoint)])

        init(_ g: ShapeGeometry) {
            switch g {
            case .path(let path):
                var polys: [[ShapePoint]] = []
                var outline: [(ShapePoint, ShapePoint)] = []
                for sub in path.subpaths {
                    var pts = [sub.start]
                    var p0 = sub.start
                    for seg in sub.segments {
                        var chunk: [ShapePoint] = []
                        ShapeMath.flatten(from: p0, seg.kind, tolerance: ShapeHitTester.tolerance, into: &chunk)
                        if seg.stroked {
                            var a = p0
                            for b in chunk { outline.append((a, b)); a = b }
                        }
                        pts += chunk
                        p0 = seg.kind.end
                    }
                    if sub.closed, sub.segments.last?.stroked ?? true { outline.append((p0, sub.start)) }
                    polys.append(pts)
                }
                self = .polygons(polys, path.fillRule, outline: outline)
            case .combined(let base, let steps):
                let b = FlatRegion(base)
                let operands = steps.map { ($0.mode, FlatRegion($0.geometry)) }
                self = .combined(b, operands, edges: b.closedEdges + operands.flatMap { $0.1.closedEdges })
            }
        }

        func contains(_ p: ShapePoint) -> Bool {
            switch self {
            case .polygons(let polys, let rule, _):
                return ShapeMath.contains(polys, p, rule: rule)
            case .combined(let base, let steps, _):
                var inside = base.contains(p)
                for (mode, region) in steps {
                    let other = region.contains(p)
                    switch mode {
                    case .union: inside = inside || other
                    case .intersect: inside = inside && other
                    case .xor: inside = inside != other
                    case .exclude: inside = inside && !other
                    }
                }
                return inside
            }
        }

        /// Every edge that may be part of the outline (for combined regions: all operand edges, closed).
        var edges: [(ShapePoint, ShapePoint)] {
            switch self {
            case .polygons(_, _, let outline):
                return outline
            case .combined(_, _, let edges):
                return edges
            }
        }

        private var closedEdges: [(ShapePoint, ShapePoint)] {
            switch self {
            case .polygons(let polys, _, _):
                var result: [(ShapePoint, ShapePoint)] = []
                for poly in polys where poly.count >= 2 {
                    for i in 0..<poly.count { result.append((poly[i], poly[(i + 1) % poly.count])) }
                }
                return result
            case .combined:
                return edges
            }
        }

        func isNearOutline(_ p: ShapePoint, within r: Double) -> Bool {
            switch self {
            case .polygons:
                return edges.contains { ShapeMath.distance(p, segmentFrom: $0.0, to: $0.1).distance <= r }
            case .combined:
                // An operand edge belongs to the combined outline where the region changes from one side to the other.
                for (a, b) in edges {
                    let (d, q) = ShapeMath.distance(p, segmentFrom: a, to: b)
                    guard d <= r, let n = (b - a).normalized?.perpendicular else { continue }
                    if contains(q + n * 0.01) != contains(q - n * 0.01) { return true }
                }
                return false
            }
        }
    }
}
