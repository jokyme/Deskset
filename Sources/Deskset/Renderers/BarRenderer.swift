import CoreGraphics
import DesksetCore
import DesksetDraw

extension SkinRenderer {
    static func drawBar(_ meter: BarMeter, _ ctx: CGContext) {
        drawBar(meter.lower(), ctx)
    }

    static func drawBar(_ draw: BarDraw, _ ctx: CGContext) {
        DesksetDraw.BarRenderer.draw(draw, in: ctx)
    }
}
