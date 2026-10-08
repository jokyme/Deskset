import CoreGraphics
import DesksetCore
import DesksetDraw

typealias PreparedImage = DesksetDraw.PreparedImage

extension SkinRenderer {
    static func drawImage(_ meter: ImageMeter, _ ctx: CGContext) {
        drawImage(meter.lower(), ctx)
    }

    static func drawImage(_ draw: ImageDraw, _ ctx: CGContext) {
        DesksetDraw.ImageRenderer.draw(draw, in: ctx)
    }

    static func drawnDecodePath(_ path: String, options: ImageOptions, drawn: CGSize, fit: Bool,
                                in ctx: CGContext) -> String {
        DesksetDraw.ImageRenderer.drawnDecodePath(path, options: options, drawn: drawn, fit: fit, in: ctx)
    }

    static func drawnDecodePath(_ path: String, options: ImageOptions, drawn: CGSize, fit: Bool,
                                target: DrawTarget) -> String {
        DesksetDraw.ImageRenderer.drawnDecodePath(path, options: options, drawn: drawn, fit: fit, target: target)
    }

    static func drawImageFile(atPath path: String, options: ImageOptions, in rect: CGRect,
                              preserveAspectRatio: Int = 0, tile: Bool = false, scaleMargins: SkinInsets? = nil,
                              _ ctx: CGContext) {
        DesksetDraw.ImageRenderer.drawImageFile(atPath: path, options: options, in: rect,
                                                preserveAspectRatio: preserveAspectRatio, tile: tile,
                                                scaleMargins: scaleMargins, ctx)
    }

    static func drawMasked(_ prepared: PreparedImage, maskPath: String, maskOptions: ImageOptions, in area: CGRect,
                           _ ctx: CGContext) {
        DesksetDraw.ImageRenderer.drawMasked(prepared, maskPath: maskPath, maskOptions: maskOptions, in: area, ctx)
    }

    static func drawMasked(_ prepared: PreparedImage, maskPath: String, maskOptions: ImageOptions, in area: CGRect,
                           _ ctx: CGContext, target: DrawTarget) {
        DesksetDraw.ImageRenderer.drawMasked(prepared, maskPath: maskPath, maskOptions: maskOptions, in: area, ctx,
                                            target: target)
    }
}
