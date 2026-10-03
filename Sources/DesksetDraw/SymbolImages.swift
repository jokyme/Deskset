import CoreGraphics
import DesksetCore

/// Symbol paths at the density of their target, using the shared image cache for natural sizes.
package enum SymbolImages {
    /// The path to draw `path` with into `ctx`, covering `drawn` points (nil: its own size): a file's path as it is; for
    /// a symbol, the symbol rendered at the pixels it covers there — the context's device scale times how much it is
    /// scaled up (`fit`: scaled uniformly to fit inside `drawn`, else the larger of the two scales), in steps of 1/8 so
    /// a meter whose size animates reuses renders. ImageCrop and ImageRotate count: `drawn` covers the cropped, rotated
    /// symbol.
    package static func drawingPath(_ path: String, options: ImageOptions, drawn: CGSize?, fit: Bool = false,
                            in ctx: CGContext) -> String {
        drawingPath(path, options: options, drawn: drawn, fit: fit,
                    target: DrawTarget.capture(ctx))
    }

    package static func drawingPath(_ path: String, options: ImageOptions, drawn: CGSize?, fit: Bool = false,
                            target: DrawTarget) -> String {
        guard let symbol = MacSymbol(path: path) else { return path }
        let device = Double(target.maximumPixelsPerPoint)
        var density = device.isFinite && device > 0 ? device : 1
        guard let natural = Images.size(atPath: symbol.measuringPath), natural.width > 0, natural.height > 0
        else { return symbol.withDensity(density).path }
        if let drawn, drawn.width > 0, drawn.height > 0, drawn.width.isFinite, drawn.height.isFinite {
            let shown = options.displaySize(imageWidth: natural.width, imageHeight: natural.height)
            if shown.width > 0, shown.height > 0 {
                let sx = Double(drawn.width) / shown.width, sy = Double(drawn.height) / shown.height
                density *= fit ? min(sx, sy) : max(sx, sy)
            }
        }
        // Within the bitmap budget.
        let budget = (Double(Images.maxDerivedPixels) / (natural.width * natural.height)).squareRoot()
        density = min((density * 8).rounded(.up) / 8, budget)
        return symbol.withDensity(density).path
    }
}
