import CoreGraphics
import DesksetCore

package enum ShapeRenderer {
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
