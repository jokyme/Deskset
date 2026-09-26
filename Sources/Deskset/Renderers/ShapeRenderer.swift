import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Shape

    /// Shapes are drawn relative to the meter's content origin and are not clipped to the meter (manual: shapes
    /// may extend outside the meter container). Always anti-aliased.
    static func drawShape(_ meter: ShapeMeter, _ ctx: CGContext) {
        let shapes = ShapeCG.built(for: meter)
        guard !shapes.isEmpty else { return }
        let origin = meter.contentFrame
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        for shape in shapes { ShapeCG.draw(shape, ctx) }
        ctx.restoreGState()
    }
}
