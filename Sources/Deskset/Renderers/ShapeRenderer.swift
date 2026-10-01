import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Shape

    /// Shapes are drawn relative to the meter's content origin and are not clipped to the meter (manual: shapes
    /// may extend outside the meter container). Always anti-aliased.
    static func drawShape(_ meter: ShapeMeter, _ ctx: CGContext) {
        drawShape(meter.lower(), ctx, SkinRenderContext.of(meter.skin))
    }

    static func drawShape(_ draw: ShapeDraw, _ ctx: CGContext, _ context: SkinRenderContext) {
        let shapes = ShapeCG.built(for: draw, in: context)
        guard !shapes.isEmpty else { return }
        let origin = draw.contentFrame
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        for shape in shapes { ShapeCG.draw(shape, ctx) }
        ctx.restoreGState()
    }
}
