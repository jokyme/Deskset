import CoreGraphics
import DesksetCore
import DesksetDraw

typealias RotatorImageCache = DesksetDraw.RotatorImageCache

extension SkinRenderer {
    static func drawRotator(_ meter: RotatorMeter, _ ctx: CGContext, _ context: SkinRenderContext) {
        drawRotator(meter.lower(), ctx, context)
    }

    static func drawRotator(_ draw: RotatorDraw, _ ctx: CGContext, _ context: SkinRenderContext) {
        DesksetDraw.RotatorRenderer.draw(draw, in: ctx, cache: context.rotatorImages)
    }
}
