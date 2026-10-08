import CoreGraphics
import DesksetCore

package enum BarRenderer {
    // MARK: Bar

    /// BarColor fills the visible bar rect; a BarImage (with its image options) is drawn at its own size and
    /// clipped to the revealed part plus the BarBorder ends (geometry from `BarMeter.visibleBarRects`).
    package static func draw(_ draw: BarDraw, in ctx: CGContext) {
        let rects = draw.visibleRects.map(\.cgRect)
        guard !rects.isEmpty else { return }
        if let path = draw.path {
            guard let imageRect = draw.imageRect,
                  let prepared = PreparedImage(path: path, options: draw.options, drawn: nil, in: ctx) else { return }
            ctx.saveGState()
            ctx.clip(to: rects)
            prepared.draw(in: imageRect.cgRect, ctx)
            ctx.restoreGState()
        } else if draw.color.a > 0 {
            ctx.setFillColor(draw.color.cgColor)
            ctx.fill(rects)
        }
    }
}
