#if DEBUG
// A frozen copy of BarRenderer.swift: see LegacySkinRenderer.swift. Debug builds only.

import AppKit
import DesksetCore

extension LegacySkinRenderer {
    // MARK: Bar

    /// BarColor fills the visible bar rect; a BarImage (with its image options) is drawn at its own size and
    /// clipped to the revealed part plus the BarBorder ends (geometry from `BarMeter.visibleBarRects`).
    static func drawBar(_ meter: BarMeter, _ ctx: CGContext) {
        let rects = meter.visibleBarRects().map(\.legacyCGRect)
        guard !rects.isEmpty else { return }
        if let path = meter.barImagePath {
            guard let imageRect = meter.barImageRect(),
                  let prepared = LegacyPreparedImage(path: path, options: meter.imageOptions, drawn: nil, in: ctx) else { return }
            ctx.saveGState()
            ctx.clip(to: rects)
            prepared.draw(in: imageRect.legacyCGRect, ctx)
            ctx.restoreGState()
        } else if meter.barColor.a > 0 {
            ctx.setFillColor(meter.barColor.legacyCGColor)
            ctx.fill(rects)
        }
    }
}
#endif
