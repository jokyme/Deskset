import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Bar

    /// BarColor fills the visible bar rect; a BarImage (with its image options) is drawn at its own size and
    /// clipped to the revealed part plus the BarBorder ends (geometry from `BarMeter.visibleBarRects`).
    static func drawBar(_ meter: BarMeter, _ ctx: CGContext) {
        let rects = meter.visibleBarRects().map(\.cgRect)
        guard !rects.isEmpty else { return }
        if let path = meter.barImagePath {
            guard let imageRect = meter.barImageRect(),
                  let prepared = PreparedImage(path: path, options: meter.imageOptions) else { return }
            ctx.saveGState()
            ctx.clip(to: rects)
            prepared.draw(in: imageRect.cgRect, ctx)
            ctx.restoreGState()
        } else if meter.barColor.a > 0 {
            ctx.setFillColor(meter.barColor.cgColor)
            ctx.fill(rects)
        }
    }
}
