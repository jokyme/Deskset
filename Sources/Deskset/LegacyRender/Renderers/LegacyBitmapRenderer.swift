#if DEBUG
// A frozen copy of BitmapRenderer.swift: see LegacySkinRenderer.swift. Debug builds only.

import AppKit
import DesksetCore

extension LegacySkinRenderer {
    // MARK: Bitmap

    /// Draws every cell (`BitmapMeter.cells`: frame source rect → destination) from the prepared BitmapImage.
    static func drawBitmap(_ meter: BitmapMeter, _ ctx: CGContext) {
        guard let path = meter.bitmapImagePath,
              let prepared = LegacyPreparedImage(path: path, options: meter.imageOptions) else { return }
        for cell in meter.cells() {
            drawImageFrame(prepared, source: cell.source, in: cell.destination.legacyCGRect, ctx)
        }
    }
}
#endif
