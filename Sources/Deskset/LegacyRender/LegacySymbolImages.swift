#if DEBUG
// A frozen copy of SymbolImages.swift (the drawing part): see LegacySkinRenderer.swift. Debug builds only.

import AppKit
import DesksetCore

/// SF Symbols as images (`ImageName=sf:cpu.fill`, Deskset extension; the engine side is `MacSymbol`).
///
/// A symbol image is rendered into a bitmap like a decoded file, and `LegacyImages` keeps it under its path (the symbol, its
/// size, weight and rendering, and the pixels per point it is rendered at). Its size in points is the symbol's own at
/// `MacSymbolSize`, rounded up to whole points with the symbol centered. It is drawn white — the whole symbol, with
/// the parts a template symbol knocks out left transparent (Monochrome), the layers in their hierarchy's opacities
/// (Hierarchical), or the parts without colors of their own (Multicolor, drawn as in Dark Mode) — so the general image
/// options (ImageTint, ColorMatrix, Greyscale, ImageAlpha) color it as they color a white picture.
///
/// Any thread: each render makes its own `NSImage` and graphics context (`LegacyImages` renders a path once at a time).
enum LegacySymbolImages {
    /// The symbol drawn at its density: the bitmap, and its size in points. Nil when macOS has no symbol of that name
    /// or the bitmap would be too large.
    static func render(_ symbol: MacSymbol) -> (image: CGImage, pointSize: CGSize)? {
        guard !symbol.name.isEmpty, let image = configuredImage(symbol) else { return nil }
        let natural = image.size
        guard natural.width > 0, natural.height > 0, natural.width.isFinite, natural.height.isFinite else { return nil }
        let points = CGSize(width: natural.width.rounded(.up), height: natural.height.rounded(.up))
        let density = CGFloat(symbol.density)
        let w = max(Int((points.width * density).rounded()), 1), h = max(Int((points.height * density).rounded()), 1)
        guard w <= LegacyImages.maxDecodeSide * 2, h <= LegacyImages.maxDecodeSide * 2, w * h <= LegacyImages.maxDerivedPixels,
              let ctx = LegacyImages.bitmapContext(width: w, height: h) else { return nil }
        let draw = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ctx.scaleBy(x: CGFloat(w) / points.width, y: CGFloat(h) / points.height)
            image.draw(in: NSRect(x: (points.width - natural.width) / 2, y: (points.height - natural.height) / 2,
                                  width: natural.width, height: natural.height))
            NSGraphicsContext.restoreGraphicsState()
            if symbol.style.rendering == .monochrome {
                // The template drawing (black, with the knocked-out parts of `.circle.fill`-style symbols) made white.
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        // Multicolor draws the layers without colors of their own in the label color: white in Dark Mode. The other
        // renderings are white in any appearance, and Dark Mode keeps them the same.
        if let dark = NSAppearance(named: .darkAqua) { dark.performAsCurrentDrawingAppearance(draw) } else { draw() }
        guard let cg = ctx.makeImage() else { return nil }
        return (cg, points)
    }

    private static func configuredImage(_ symbol: MacSymbol) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil) else { return nil }
        var configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(symbol.style.pointSize),
                                                        weight: weight(symbol.style.weight))
        switch symbol.style.rendering {
        case .monochrome: break  // drawn as a template, then made white (`render`)
        case .hierarchical:
            configuration = configuration.applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
        case .multicolor: configuration = configuration.applying(.preferringMulticolor())
        }
        return base.withSymbolConfiguration(configuration)
    }

    static func weight(_ weight: MacSymbol.Weight) -> NSFont.Weight {
        switch weight {
        case .ultralight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    // MARK: Drawing

    /// The path to draw `path` with into `ctx`, covering `drawn` points (nil: its own size): a file's path as it is; for
    /// a symbol, the symbol rendered at the pixels it covers there — the context's device scale times how much it is
    /// scaled up (`fit`: scaled uniformly to fit inside `drawn`, else the larger of the two scales), in steps of 1/8 so
    /// a meter whose size animates reuses renders. ImageCrop and ImageRotate count: `drawn` covers the cropped, rotated
    /// symbol.
    static func drawingPath(_ path: String, options: ImageOptions, drawn: CGSize?, fit: Bool = false,
                            in ctx: CGContext) -> String {
        guard let symbol = MacSymbol(path: path) else { return path }
        let t = ctx.userSpaceToDeviceSpaceTransform
        let device = Double(max(hypot(t.a, t.b), hypot(t.c, t.d)))
        var density = device.isFinite && device > 0 ? device : 1
        guard let natural = LegacyImages.size(atPath: symbol.measuringPath), natural.width > 0, natural.height > 0
        else { return symbol.withDensity(density).path }
        if let drawn, drawn.width > 0, drawn.height > 0, drawn.width.isFinite, drawn.height.isFinite {
            let shown = options.displaySize(imageWidth: natural.width, imageHeight: natural.height)
            if shown.width > 0, shown.height > 0 {
                let sx = Double(drawn.width) / shown.width, sy = Double(drawn.height) / shown.height
                density *= fit ? min(sx, sy) : max(sx, sy)
            }
        }
        // Within the bitmap budget.
        let budget = (Double(LegacyImages.maxDerivedPixels) / (natural.width * natural.height)).squareRoot()
        density = min((density * 8).rounded(.up) / 8, budget)
        return symbol.withDensity(density).path
    }
}

extension LegacyPreparedImage {
    /// `path` prepared with `options` for drawing into `ctx` over `drawn` points (see `LegacySymbolImages.drawingPath`); a
    /// file is prepared as by `init(path:options:)`.
    init?(path: String, options: ImageOptions, drawn: CGSize?, fit: Bool = false, in ctx: CGContext) {
        self.init(path: LegacySymbolImages.drawingPath(path, options: options, drawn: drawn, fit: fit, in: ctx),
                  options: options)
    }
}
#endif
