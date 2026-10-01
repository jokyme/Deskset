import CoreGraphics
import DesksetCore

/// Ideal geometry candidates only. These bounds do not establish native pixel coverage and must not be used
/// to partition, clip or skip rendering until an independent raster-escape check has established that contract.
package enum InkGeometry {
    private typealias Geometry = InkBounds.Geometry

    package static func of(_ item: DrawItem, context: DrawContext, target: DrawTarget) -> InkBounds.Geometry {
        switch item {
        case let .fill(rect, paint):
            if let second = paint.secondColor, second != paint.color {
                guard paint.angle.isFinite, (paint.angle * .pi / 180).isFinite else {
                    return .unknown(.invalidGeometry)
                }
            }
            // Fill has no transparent-color early return, and the inherited blend mode is not assumed here.
            return bounds(rect.cgRect)
        case let .bevel(rect, bevel):
            guard bevel.type == 1 || bevel.type == 2 else { return .empty }
            guard finite(rect.cgRect) else { return .unknown(.invalidGeometry) }
            guard rect.width > 1, rect.height > 1 else { return .empty }
            // The renderer sets width, but inherits cap/join/dash state. Do not invent a stroke envelope.
            return .unknown(.unresolvedRasterization)
        case let .bar(draw):
            guard !draw.visibleRects.isEmpty else { return .empty }
            if draw.path != nil {
                guard let rect = draw.imageRect else { return .empty }
                guard finite(rect.cgRect) else { return .unknown(.invalidGeometry) }
                // PreparedImage.draw requires positive destination dimensions; it is clipped to visibleRects.
                guard rect.width > 0, rect.height > 0 else { return .empty }
            } else if !(draw.color.a > 0) {
                return .empty
            }
            return draw.visibleRects.reduce(.empty) { union($0, bounds($1.cgRect)) }
        case let .shape(draw):
            guard !draw.shapes.isEmpty else { return .empty }
            guard draw.contentFrame.x.isFinite, draw.contentFrame.y.isFinite,
                  draw.shapes.allSatisfy({ item in
                      finite(item.geometry) && finite(item.visualBounds)
                          && item.strokeStyle.width.isFinite && item.strokeStyle.miterLimit.isFinite
                          && item.strokeStyle.dashOffset.isFinite && item.strokeStyle.dashes.allSatisfy(\.isFinite)
                          && (item.strokePlan.map(finite) ?? true)
                  }) else { return .unknown(.invalidGeometry) }
            if draw.shapes.allSatisfy({ !$0.fill.isVisible && !$0.stroke.isVisible }) { return .empty }
            // Reuse the region/stroke extent used by drawing, including its existing layer margin. This warms
            // only this owner's shape cache; it neither renders nor consults a live meter or image source.
            let rect = ShapeRenderer.geometryBounds(draw, context: context)
            return rect.isNull ? .empty : bounds(rect)
        case let .roundline(draw):
            return roundline(draw)
        case let .glass(region):
            return glass(region, paint: target.glassPaint)
        case let .transformed(transform, contents):
            guard !contents.isEmpty else { return .empty }
            let t = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c,
                                      d: transform.d, tx: transform.tx, ty: transform.ty)
            guard finite(t) else { return .unknown(.invalidMapping) }
            let determinant = t.a * t.d - t.b * t.c
            guard determinant.isFinite, determinant != 0 else { return .unknown(.invalidMapping) }
            return mapped(group(contents, context: context, target: target), by: t)
        case let .antialias(_, contents):
            return group(contents, context: context, target: target)
        case let .container(clip, mask, content):
            guard !content.isEmpty else { return .empty }
            let rect = clip.cgRect
            guard finite(rect) else { return .unknown(.invalidGeometry) }
            guard rect.width > 0, rect.height > 0 else { return .empty }
            let children = union(group(content, context: context, target: target),
                                 group(mask, context: context, target: target))
            if case let .unknown(reason) = children, reason != .unresolvedRasterization {
                return .unknown(reason)
            }
            // Both transparency layers and their destinationIn operation are inside this explicit clip.
            // Their compositing envelope remains the clip even when individual child geometry is empty or
            // rasterization is unresolved; no inherited blend mode or mask alpha is inferred to tighten it.
            return .bounds(rect)
        case let .image(draw):
            return image(draw)
        case let .graph(draw):
            return graph(draw)
        case .text, .rotator, .sprite:
            // A nil glyph outline is not an empty draw; unresolved image sizes and unclipped recipes remain
            // unknown. Image preparation must not run during this query.
            return .unknown(.unresolvedRasterization)
        }
    }

    private static func image(_ draw: ImageDraw) -> Geometry {
        switch draw.placement {
        case .backgroundNatural:
            // Its prepared natural size is not captured in ImageDraw, and it has no contentFrame clip.
            return .unknown(.unresolvedRasterization)
        case .meter:
            // The mask's composite has a destination quad, but no explicit destination clip in this path.
            guard draw.maskPath == nil else { return .unknown(.unresolvedRasterization) }
        case .backgroundTiled:
            break
        }
        let rect = draw.contentFrame.cgRect
        guard finite(rect) else { return .unknown(.invalidGeometry) }
        guard rect.width > 0, rect.height > 0, draw.path != nil else { return .empty }
        // drawImageFile clips the unmasked meter; tile clips the tiled background to a subset of this frame.
        // Source alpha, fit/fill, margins and image preparation are not needed to retain that ideal upper bound.
        return .bounds(rect)
    }

    private static func graph(_ draw: GraphDraw) -> Geometry {
        let rect: CGRect
        let antiAlias: Bool
        switch draw {
        case let .line(line):
            rect = line.contentFrame.cgRect
            antiAlias = line.antiAlias
            guard line.lineWidth.isFinite,
                  !line.horizontalLines || !(line.horizontalLineColor.a > 0)
                    || line.markerCoordinates.allSatisfy(\.isFinite) else {
                return .unknown(.invalidGeometry)
            }
            if line.historyLength > 0, line.lineWidth > 0, line.transformStrokeFixed,
               let matrix = line.transformationMatrix {
                // Match the fields actually indexed by the renderer; do not treat malformed input as empty.
                guard matrix.count >= 6, matrix.prefix(6).allSatisfy(\.isFinite) else {
                    return .unknown(.invalidMapping)
                }
            }
            // Markers precede the history/pen guards, so those guards cannot empty the whole Line recipe.
        case let .histogram(histogram):
            rect = histogram.contentFrame.cgRect
            antiAlias = histogram.antiAlias
            guard finite(rect) else { return .unknown(.invalidGeometry) }
            guard histogram.historyLength > 0 else { return .empty }
        }
        guard finite(rect) else { return .unknown(.invalidGeometry) }
        guard rect.width > 0, rect.height > 0 else { return .empty }
        guard !antiAlias else { return .bounds(rect) }
        // Native graph snap precedes clip(to:). Its accepted dx and dy are each strictly less than one user
        // unit in magnitude; rejected snap is zero. Their union fits this envelope without a native round trip.
        guard let x0 = exactlyShifted(rect.minX, by: -1), let y0 = exactlyShifted(rect.minY, by: -1),
              let x1 = exactlyShifted(rect.maxX, by: 1), let y1 = exactlyShifted(rect.maxY, by: 1) else {
            return .unknown(.invalidGeometry)
        }
        let expanded = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard finite(expanded), expanded.minX <= x0, expanded.minY <= y0,
              expanded.maxX >= x1, expanded.maxY >= y1 else { return .unknown(.invalidGeometry) }
        return .bounds(expanded)
    }

    /// Reject a rounded +/-1 instead of silently losing part of the graph-snap envelope at large coordinates.
    private static func exactlyShifted(_ edge: CGFloat, by delta: CGFloat) -> CGFloat? {
        let shifted = edge + delta
        guard shifted.isFinite else { return nil }
        // Error-free TwoSum recovers the residual of this finite addition without introducing extra padding.
        let virtualDelta = shifted - edge
        let residual = (edge - (shifted - virtualDelta)) + (delta - virtualDelta)
        return residual == 0 ? shifted : nil
    }

    private static func roundline(_ draw: RoundlineDraw) -> Geometry {
        guard draw.shape != .none, draw.color.a > 0 else { return .empty }
        switch draw.shape {
        case .none:
            return .empty
        case let .line(x1, y1, x2, y2, width):
            guard [x1, y1, x2, y2, width].allSatisfy(\.isFinite), width >= 0 else {
                return .unknown(.invalidGeometry)
            }
            // A zero-width native stroke is a device hairline, not proven empty user-space geometry.
            let half = CGFloat(width / 2)
            guard half > 0 else { return .unknown(.unresolvedRasterization) }
            // Explicit butt caps and a single segment require no inherited join assumption. Expanding both
            // axes is conservative for every segment direction, before any outer affine transformation.
            return bounds(CGRect(x: min(x1, x2) - half, y: min(y1, y2) - half,
                                 width: abs(x2 - x1) + width, height: abs(y2 - y1) + width))
        case let .sector(cx, cy, inner, outer, start, sweep):
            guard [cx, cy, inner, outer, start, sweep].allSatisfy(\.isFinite),
                  inner >= 0, outer >= inner else { return .unknown(.invalidGeometry) }
            // The renderer still sends degenerate sectors to native arc/fill APIs. Their raster behavior is
            // not established by a zero ideal area, so do not promote equal radii or zero sweep to empty.
            guard outer > inner, sweep != 0 else { return .unknown(.unresolvedRasterization) }
            if abs(sweep) < RoundMeterMath.fullCircle, !(start + sweep).isFinite {
                return .unknown(.invalidGeometry)
            }
            // Partial arcs and their closing edges are contained in the outer circle. This intentionally
            // includes unused quadrants instead of inventing tighter native arc/raster extrema.
            return bounds(CGRect(x: cx - outer, y: cy - outer, width: outer * 2, height: outer * 2))
        }
    }

    private static func glass(_ region: GlassRegion, paint: GlassPaint) -> Geometry {
        if case .none = paint { return .empty }
        let rect = region.rect.cgRect
        guard finite(rect), region.cornerRadius.isFinite else { return .unknown(.invalidGeometry) }
        guard rect.width > 0, rect.height > 0 else { return .empty }
        let geometry: Geometry
        switch paint {
        case .none:
            return .empty
        case .hitArea:
            geometry = .bounds(rect)
        case .placeholder:
            let inset = rect.insetBy(dx: 0.5, dy: 0.5)
            guard finite(inset) else { return .unknown(.invalidGeometry) }
            // The body is a finite fill; a nonempty edge additionally uses inherited stroke attributes.
            geometry = inset.width > 0 && inset.height > 0
                ? .unknown(.unresolvedRasterization) : .bounds(rect)
        }
        guard let clip = region.clip else { return geometry }
        return clipped(geometry, to: clip.cgRect)
    }

    private static func group(_ items: [DrawItem], context: DrawContext, target: DrawTarget) -> Geometry {
        items.reduce(.empty) { union($0, of($1, context: context, target: target)) }
    }

    private static func union(_ a: Geometry, _ b: Geometry) -> Geometry {
        switch (a, b) {
        case let (.unknown(first), .unknown(second)):
            // Preserve invalid input rather than allowing an earlier unresolved branch to hide it.
            return .unknown(first == .unresolvedRasterization ? second : first)
        case let (.unknown(reason), _), let (_, .unknown(reason)):
            return .unknown(reason)
        case (.empty, _): return b
        case (_, .empty): return a
        case let (.bounds(first), .bounds(second)): return bounds(first.union(second))
        }
    }

    private static func clipped(_ geometry: Geometry, to clip: CGRect) -> Geometry {
        guard finite(clip) else { return .unknown(.invalidGeometry) }
        let clip = clip.standardized
        guard !clip.isEmpty else { return .empty }
        switch geometry {
        case .empty: return .empty
        case .unknown(.unresolvedRasterization): return .bounds(clip)
        case .unknown: return geometry
        case let .bounds(rect):
            let intersection = rect.intersection(clip)
            return intersection.isNull ? .empty : bounds(intersection)
        }
    }

    private static func mapped(_ geometry: Geometry, by t: CGAffineTransform) -> Geometry {
        guard case let .bounds(rect) = geometry else { return geometry }
        // Child-local geometry is mapped to its parent's user space first; recursive wrappers then apply
        // their outer maps. The destination mapping is applied once later by InkBounds.deviceRectangle.
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map { $0.applying(t) }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let x0 = corners.map(\.x).min(), let x1 = corners.map(\.x).max(),
              let y0 = corners.map(\.y).min(), let y1 = corners.map(\.y).max() else {
            return .unknown(.invalidMapping)
        }
        let result = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard finite(result) else { return .unknown(.invalidMapping) }
        return result.isEmpty ? .empty : .bounds(result)
    }

    private static func bounds(_ rect: CGRect) -> Geometry {
        guard finite(rect) else { return .unknown(.invalidGeometry) }
        let rect = rect.standardized
        return rect.isEmpty ? .empty : .bounds(rect)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
         rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
    }

    private static func finite(_ t: CGAffineTransform) -> Bool {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite)
    }

    private static func finite(_ point: ShapePoint) -> Bool { point.x.isFinite && point.y.isFinite }

    private static func finite(_ rect: ShapeRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width >= 0 && rect.height >= 0
    }

    private static func finite(_ subpath: ShapeSubpath) -> Bool {
        finite(subpath.start) && subpath.segments.allSatisfy { segment in
            switch segment.kind {
            case let .line(point): return finite(point)
            case let .quadratic(control, point): return finite(control) && finite(point)
            case let .cubic(first, second, point): return finite(first) && finite(second) && finite(point)
            }
        }
    }

    private static func finite(_ geometry: ShapeGeometry) -> Bool {
        switch geometry {
        case let .path(path): return path.subpaths.allSatisfy(finite)
        case let .combined(base, steps): return finite(base) && steps.allSatisfy { finite($0.geometry) }
        }
    }

    private static func finite(_ plan: ShapeStrokePlan) -> Bool {
        plan.width.isFinite && plan.width > 0 && plan.miterLimit.isFinite
            && plan.runs.allSatisfy { finite($0.subpath) } && plan.patches.allSatisfy(finite)
    }
}
