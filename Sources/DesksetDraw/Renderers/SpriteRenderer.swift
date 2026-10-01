import CoreGraphics
import DesksetCore

package enum SpriteRenderer {
    // MARK: Bitmap

    /// Draws every cell (`BitmapMeter.cells`: frame source rect → destination) from the prepared BitmapImage.
    package static func draw(_ draw: SpriteDraw, in ctx: CGContext) {
        guard !draw.cells.isEmpty, let path = draw.path,
              let prepared = PreparedImage(path: path, options: draw.options, drawn: nil, in: ctx) else { return }
        for cell in draw.cells {
            ImageRenderer.drawImageFrame(prepared, source: cell.source, in: cell.destination.cgRect, ctx,
                           opacity: CGFloat(draw.opacity))
        }
    }
}
