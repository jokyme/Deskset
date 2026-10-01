import CoreGraphics
import DesksetCore
import DesksetDraw

extension SkinRenderer {
    // MARK: Roundline

    /// Draws the geometry computed by `RoundlineMeter.shape` (all math lives in DesksetCore). Nothing is clipped to
    /// the meter box: without W/H the box is empty and the skin window does the cutting (manual note).
    static func drawRoundline(_ meter: RoundlineMeter, _ ctx: CGContext) {
        drawRoundline(meter.lower(), ctx)
    }

    static func drawRoundline(_ draw: RoundlineDraw, _ ctx: CGContext) {
        DesksetDraw.RoundlineRenderer.draw(draw, in: ctx)
    }
}
