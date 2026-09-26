import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Line

    /// Draws the HorizontalLines markers, then each line (oldest sample to newest) clipped to the content area.
    /// Sample positions and scaling come from `LineMeter` (DesksetCore).
    ///
    /// AntiAlias=0 draws aliased and crisp: the graph's anchor corner (GraphStart edge, baseline) is moved onto a
    /// device pixel corner, vertices sit on whole-pixel values (pixel centers) and even line widths are shifted by
    /// half a pixel, so no stroke edge lies exactly between two device pixels (such an edge is rasterized on both
    /// sides: one pixel too thick).
    static func drawLine(_ meter: LineMeter, _ ctx: CGContext) {
        let area = meter.contentFrame.cgRect
        guard area.width > 0, area.height > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let aliased = !meter.antiAlias
        let snap = aliased ? alignGraphToDevicePixels(graphAnchor(area, meter.direction), ctx) : .zero
        ctx.setShouldAntialias(meter.antiAlias)  // before clipping: an aliased graph gets an aliased clip edge
        ctx.clip(to: area)

        if meter.horizontalLines, meter.horizontalLineColor.a > 0 {
            let vertical = meter.direction.vertical
            var segments: [CGPoint] = []
            for coordinate in meter.markerCoordinates {
                // Markers are on pixel centers of the skin; undo the alignment shift so they stay there.
                let c = coordinate - (vertical ? snap.y : snap.x)
                if vertical {
                    segments += [CGPoint(x: area.minX, y: c), CGPoint(x: area.maxX, y: c)]
                } else {
                    segments += [CGPoint(x: c, y: area.minY), CGPoint(x: c, y: area.maxY)]
                }
            }
            ctx.setLineWidth(1)
            ctx.setStrokeColor(meter.horizontalLineColor.cgColor)
            ctx.strokeLineSegments(between: segments)
        }

        let count = meter.historyLength
        guard count > 0, meter.lineWidth > 0 else { return }

        // TransformStroke=Fixed: map the vertices through the meter's TransformationMatrix ourselves and stroke
        // with that matrix undone, so the pen width is not scaled or skewed (the clip above stays transformed).
        var transform = CGAffineTransform.identity
        if meter.transformStrokeFixed, let m = meter.transformationMatrix {
            let t = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            let determinant = t.a * t.d - t.b * t.c
            if determinant.isFinite, abs(determinant) > 1e-9 {
                transform = t
                ctx.concatenate(t.inverted())
            }
        }
        let offset = aliased && transform.isIdentity ? aliasedStrokeOffset(lineWidth: meter.lineWidth, ctx) : .zero

        ctx.setLineWidth(meter.lineWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(count == 1 ? .round : .butt)
        let geometry = meter.geometry
        for (index, line) in meter.lines.enumerated() where line.measure != nil && line.color.a > 0 {
            let path = CGMutablePath()
            for age in stride(from: count - 1, through: 0, by: -1) {
                let p = geometry.point(age: age, fraction: meter.fraction(line: index, age: age), wholePixels: aliased)
                let mapped = CGPoint(x: p.x, y: p.y).applying(transform)
                let point = CGPoint(x: mapped.x + offset.x, y: mapped.y + offset.y)
                if age == count - 1 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            if count == 1 {
                // A single sample: a dot (zero-length segment with a round cap).
                path.addLine(to: path.currentPoint)
            }
            ctx.addPath(path)
            ctx.setStrokeColor(line.color.cgColor)
            ctx.strokePath()
        }
    }

    /// The corner the graph is laid out from: the GraphStart edge of the time axis and the baseline of the value
    /// axis (columns and pixel-center vertices are whole pixels away from it; the opposite edges may be fractional).
    static func graphAnchor(_ area: CGRect, _ d: GraphDirection) -> CGPoint {
        if d.vertical {
            return CGPoint(x: d.startRight ? area.maxX : area.minX, y: d.flip ? area.minY : area.maxY)
        }
        return CGPoint(x: d.flip ? area.maxX : area.minX, y: d.startRight ? area.maxY : area.minY)
    }

    /// AntiAlias=0 graphs (Line, Histogram): translates the context so `origin` (the `graphAnchor`) lands on a
    /// device pixel corner. Their 1-pixel columns and pixel-center lines then cover whole device pixels even when
    /// the meter's edges are at half pixels (X=10.5, W=50.5, or X=10.25 on a 2x display), instead of being
    /// rasterized two pixels wide. Returns the translation applied (zero when none was possible).
    @discardableResult
    static func alignGraphToDevicePixels(_ origin: CGPoint, _ ctx: CGContext) -> CGPoint {
        let device = ctx.convertToDeviceSpace(origin)
        guard device.x.isFinite, device.y.isFinite, abs(device.x) < 1e9, abs(device.y) < 1e9 else { return .zero }
        let aligned = ctx.convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y.rounded()))
        let dx = aligned.x - origin.x, dy = aligned.y - origin.y
        guard dx.isFinite, dy.isFinite, abs(dx) < 1, abs(dy) < 1 else { return .zero }
        ctx.translateBy(x: dx, y: dy)
        return CGPoint(x: dx, y: dy)
    }

    /// AntiAlias=0: user-space shift that puts both edges of a stroke centered on a pixel center onto device pixel
    /// boundaries (LineWidth=2 on a 1x display: half a pixel). Zero unless the context maps user space to device
    /// space with an axis-aligned whole-number scale (the only case where every vertex has the same sub-pixel
    /// phase).
    static func aliasedStrokeOffset(lineWidth: Double, _ ctx: CGContext) -> CGPoint {
        let t = ctx.userSpaceToDeviceSpaceTransform
        guard t.b == 0, t.c == 0 else { return .zero }
        func shift(_ scale: CGFloat) -> CGFloat {
            guard scale.isFinite, scale != 0, abs(scale) <= 16, scale == scale.rounded() else { return 0 }
            let edge = scale * (0.5 - CGFloat(lineWidth) / 2)  // leading edge, device pixels from a pixel corner
            guard edge.isFinite else { return 0 }
            return (edge.rounded() - edge) / scale
        }
        return CGPoint(x: shift(t.a), y: shift(t.d))
    }
}
