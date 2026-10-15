import CoreGraphics
import DesksetCore

package enum ShapeRenderer {
    /// Conservative geometry in skin coordinates, before outer DrawItem transforms and device-pixel coverage.
    /// Reuses the exact prepared region and stroke extent that drawing uses; this may warm the shape cache.
    /// The caller must validate the result and account for the destination's rasterization and graphics state.
    package static func geometryBounds(_ draw: ShapeDraw, context: DrawContext) -> CGRect {
        var bounds = CGRect.null
        for shape in ShapeCG.built(for: draw, in: context) {
            bounds = bounds.union(shape.region.boundingBoxOfPath).union(shape.extent)
        }
        guard !bounds.isNull else { return .null }
        return bounds.offsetBy(dx: draw.contentFrame.x, dy: draw.contentFrame.y)
    }

    package static func draw(_ draw: ShapeDraw, in ctx: CGContext, context: DrawContext) {
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
