import CoreGraphics
import DesksetCore
import DesksetDraw

extension SkinRenderer {
    static func drawBitmap(_ meter: BitmapMeter, _ ctx: CGContext) {
        drawSprite(meter.lower(), ctx)
    }

    static func drawSprite(_ draw: SpriteDraw, _ ctx: CGContext) {
        DesksetDraw.SpriteRenderer.draw(draw, in: ctx)
    }
}
