import CoreGraphics
import DesksetCore
import DesksetDraw

extension SkinRenderer {
    // MARK: Shape

    /// Shapes are drawn relative to the meter's content origin and are not clipped to the meter (manual: shapes
    /// may extend outside the meter container). Always anti-aliased.
    static func drawShape(_ meter: ShapeMeter, _ ctx: CGContext) {
        drawShape(meter.lower(), ctx, SkinRenderContext.of(meter.skin))
    }

    static func drawShape(_ draw: ShapeDraw, _ ctx: CGContext, _ context: SkinRenderContext) {
        DesksetDraw.ShapeRenderer.draw(draw, in: ctx, context: context.drawing)
    }
}
