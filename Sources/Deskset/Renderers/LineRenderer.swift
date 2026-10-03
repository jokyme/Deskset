import CoreGraphics
import DesksetCore
import DesksetDraw

extension SkinRenderer {
    static func drawLine(_ meter: LineMeter, _ ctx: CGContext) {
        drawLine(meter.lower(), ctx)
    }

    static func drawLine(_ drawing: LineDraw, _ ctx: CGContext) {
        DesksetDraw.LineRenderer.draw(drawing, in: ctx)
    }
}
