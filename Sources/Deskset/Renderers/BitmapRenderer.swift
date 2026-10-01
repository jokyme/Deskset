import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Bitmap

    /// Draws every cell (`BitmapMeter.cells`: frame source rect → destination) from the prepared BitmapImage.
    static func drawBitmap(_ meter: BitmapMeter, _ ctx: CGContext) {
        drawSprite(meter.lower(), ctx)
    }

    static func drawSprite(_ draw: SpriteDraw, _ ctx: CGContext) {
        guard !draw.cells.isEmpty, let path = draw.path,
              let prepared = PreparedImage(path: path, options: draw.options, drawn: nil, in: ctx) else { return }
        for cell in draw.cells {
            drawImageFrame(prepared, source: cell.source, in: cell.destination.cgRect, ctx,
                           opacity: CGFloat(draw.opacity))
        }
    }
}
