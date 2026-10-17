import CoreGraphics
import DesksetCore

package enum RoundlineRenderer {
    package static func draw(_ draw: RoundlineDraw, in ctx: CGContext) {
        let shape = draw.shape
        guard shape != .none, draw.color.a > 0 else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(draw.antiAlias)
        switch shape {
        case .none:
            break
        case let .line(x1, y1, x2, y2, width):
            ctx.setStrokeColor(draw.color.cgColor)
            ctx.setLineWidth(CGFloat(width))
            ctx.setLineCap(.butt)
            ctx.strokeLineSegments(between: [CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)])
        case let .sector(cx, cy, inner, outer, start, sweep):
            ctx.setFillColor(draw.color.cgColor)
            let center = CGPoint(x: cx, y: cy)
            let path = CGMutablePath()
            if abs(sweep) >= RoundMeterMath.fullCircle {
                path.addEllipse(in: CGRect(x: cx - outer, y: cy - outer, width: outer * 2, height: outer * 2))
                if inner > 0 {
                    path.addEllipse(in: CGRect(x: cx - inner, y: cy - inner, width: inner * 2, height: inner * 2))
                }
                ctx.addPath(path)
                ctx.fillPath(using: .evenOdd)
            } else {
                // CGPath angles grow from +x towards +y; `clockwise: false` walks towards larger angles, which in
                // skin coordinates (y down) is clockwise on screen — the direction of a positive sweep.
                let end = start + sweep
                path.addArc(center: center, radius: CGFloat(outer), startAngle: CGFloat(start),
                            endAngle: CGFloat(end), clockwise: sweep < 0)
                if inner > 0 {
                    path.addArc(center: center, radius: CGFloat(inner), startAngle: CGFloat(end),
                                endAngle: CGFloat(start), clockwise: sweep > 0)
                } else {
                    path.addLine(to: center)
                }
                path.closeSubpath()
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }
}
