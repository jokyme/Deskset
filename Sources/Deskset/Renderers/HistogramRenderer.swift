import CoreGraphics
import DesksetCore
import DesksetDraw

extension SkinRenderer {
    static func drawHistogram(_ meter: HistogramMeter, _ ctx: CGContext, _ context: SkinRenderContext) {
        drawHistogram(meter.lower(), ctx, context)
    }

    static func drawHistogram(_ drawing: HistogramDraw, _ ctx: CGContext, _ context: SkinRenderContext) {
        DesksetDraw.HistogramRenderer.draw(drawing, in: ctx, cache: context.drawing.histogram)
    }
}
