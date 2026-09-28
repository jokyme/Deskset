#if DEBUG
// A frozen copy of the renderer (see LegacySkinRenderer.swift), made from SkinDrawing.swift: how a skin window's
// picture is drawn in full (the window's bitmap, with the glass as the window's hit areas), without the pictures a
// window keeps from frame to frame. Debug builds only.

import AppKit
import DesksetCore

enum LegacySkinBitmapDrawing {
    /// The window's bitmap: 8-bit premultiplied BGRA (little-endian ARGB) in `space`.
    static func makeContext(_ w: Int, _ h: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Draws items `range` (0 is the base, n the meter n − 1) in skin coordinates: top-left origin, points.
    static func draw(items range: Range<Int>, _ meters: [Meter], _ skin: Skin, into ctx: CGContext, height: Int,
                     scale: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let context = LegacySkinRenderContext.of(skin)
        for i in range {
            // The glass itself is behind the view (`SkinGlassViews`): here it only catches the mouse.
            if i == 0 {
                LegacySkinRenderer.drawBase(skin, in: ctx, glass: .window)
            } else {
                LegacySkinRenderer.drawTopLevel(meters[i - 1], of: skin, in: ctx, context)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// The skin drawn in full into a new bitmap of `w`×`h` pixels, as a skin window's picture draws it (glass as the
    /// window's hit areas); nil when the bitmap cannot be made.
    static func fullDrawing(of skin: Skin, _ w: Int, _ h: Int, scale: CGFloat, space: CGColorSpace) -> CGContext? {
        guard let ctx = makeContext(w, h, space) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let meters = LegacySkinRenderer.topLevelMeters(skin)
        draw(items: 0..<(meters.count + 1), meters, skin, into: ctx, height: h, scale: scale)
        return ctx
    }
}
#endif
