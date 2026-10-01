import AppKit
import DesksetCore
import DesksetDraw

/// The app's symbol rasterizer preserves AppKit's rendering and the image cache's sRGB bitmap format.
struct AppSymbolRasterizer: SymbolRasterizing {
    func render(_ symbol: MacSymbol) -> RasterizedSymbol? {
        SymbolImages.render(symbol).map { RasterizedSymbol(image: $0.image, pointSize: $0.pointSize) }
    }
}

/// SF Symbols as images (`ImageName=sf:cpu.fill`, Deskset extension; the engine side is `MacSymbol`).
///
/// A symbol image is rendered into a bitmap like a decoded file, and `Images` keeps it under its path (the symbol, its
/// size, weight and rendering, and the pixels per point it is rendered at). Its size in points is the symbol's own at
/// `MacSymbolSize`, rounded up to whole points with the symbol centered. It is drawn white — the whole symbol, with
/// the parts a template symbol knocks out left transparent (Monochrome), the layers in their hierarchy's opacities
/// (Hierarchical), or the parts without colors of their own (Multicolor, drawn as in Dark Mode) — so the general image
/// options (ImageTint, ColorMatrix, Greyscale, ImageAlpha) color it as they color a white picture. Palette draws each
/// layer in its color from `MacSymbolColors` (the general options then work on those colors, as on a colored file).
///
/// Any thread: each render makes its own `NSImage` and graphics context (`Images` renders a path once at a time).
enum SymbolImages {
    /// The symbol drawn at its density: the bitmap, and its size in points. Nil when macOS has no symbol of that name
    /// or the bitmap would be too large.
    static func render(_ symbol: MacSymbol) -> (image: CGImage, pointSize: CGSize)? {
        guard !symbol.name.isEmpty, let image = configuredImage(symbol) else { return nil }
        let natural = image.size
        guard natural.width > 0, natural.height > 0, natural.width.isFinite, natural.height.isFinite else { return nil }
        let points = CGSize(width: natural.width.rounded(.up), height: natural.height.rounded(.up))
        let density = CGFloat(symbol.density)
        let w = max(Int((points.width * density).rounded()), 1), h = max(Int((points.height * density).rounded()), 1)
        guard w <= Images.maxDecodeSide * 2, h <= Images.maxDecodeSide * 2, w * h <= Images.maxDerivedPixels,
              let ctx = Images.bitmapContext(width: w, height: h) else { return nil }
        let draw = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ctx.scaleBy(x: CGFloat(w) / points.width, y: CGFloat(h) / points.height)
            image.draw(in: NSRect(x: (points.width - natural.width) / 2, y: (points.height - natural.height) / 2,
                                  width: natural.width, height: natural.height))
            NSGraphicsContext.restoreGraphicsState()
            if drawsAsTemplate(symbol.style) {
                // The template drawing (black, with the knocked-out parts of `.circle.fill`-style symbols) made white.
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        // Multicolor draws the layers without colors of their own in the label color: white in Dark Mode. The other
        // renderings are white (or a palette's colors) in any appearance, and Dark Mode keeps them the same.
        if let dark = NSAppearance(named: .darkAqua) { dark.performAsCurrentDrawingAppearance(draw) } else { draw() }
        guard let cg = ctx.makeImage() else { return nil }
        return (cg, points)
    }

    /// The symbol for the editor's picture thumbnail: in the label color of the view it is shown in (its own colors for
    /// Multicolor), at 16 points. Main thread.
    static func preview(_ symbol: MacSymbol) -> NSImage? {
        guard !symbol.name.isEmpty, let base = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)
        else { return nil }
        var configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: weight(symbol.style.weight))
        switch symbol.style.rendering {
        case .monochrome:
            // The template in the label color, resolved when drawn (knocked-out parts stay transparent).
            guard let template = base.withSymbolConfiguration(configuration) else { return nil }
            return NSImage(size: template.size, flipped: false) { rect in
                template.draw(in: rect)
                NSColor.labelColor.set()
                rect.fill(using: .sourceIn)
                return true
            }
        case .hierarchical:
            configuration = configuration.applying(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))
        case .multicolor:
            configuration = configuration.applying(.preferringMulticolor())
        case .palette:
            configuration = configuration.applying(NSImage.SymbolConfiguration(
                paletteColors: symbol.style.colors.isEmpty ? [.labelColor, .labelColor]
                    : paletteColors(symbol.style.colors)))
        }
        return base.withSymbolConfiguration(configuration)
    }

    /// A palette's colors for AppKit, the last one repeated up to three: macOS gives the layers past the last color
    /// that color anyway, but a palette of one translucent color comes out with its alpha applied twice (0,0,0,153
    /// draws at alpha 92; measured on macOS 26), and two of it draw right.
    static func paletteColors(_ colors: [RGBA]) -> [NSColor] {
        guard let last = colors.last else { return [] }
        return (colors + Array(repeating: last, count: max(MacSymbol.maxColors - colors.count, 0))).map(\.nsColor)
    }

    /// Monochrome, and a palette without colors: the template drawing, made white.
    private static func drawsAsTemplate(_ style: MacSymbol.Style) -> Bool {
        style.rendering == .monochrome || (style.rendering == .palette && style.colors.isEmpty)
    }

    /// Whether macOS has a symbol of that name (the editor asks before it says a picture is missing).
    static func exists(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
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
        case .palette:
            // Without colors, drawn as a template like Monochrome (`render`).
            if !symbol.style.colors.isEmpty {
                configuration = configuration.applying(NSImage.SymbolConfiguration(
                    paletteColors: paletteColors(symbol.style.colors)))
            }
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
        drawingPath(path, options: options, drawn: drawn, fit: fit,
                    target: DrawTarget(userToDevice: ctx.userSpaceToDeviceSpaceTransform))
    }

    static func drawingPath(_ path: String, options: ImageOptions, drawn: CGSize?, fit: Bool = false,
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

extension PreparedImage {
    /// `path` prepared with `options` for drawing into `ctx` over `drawn` points (see `SymbolImages.drawingPath`); a
    /// file is prepared as by `init(path:options:)`.
    init?(path: String, options: ImageOptions, drawn: CGSize?, fit: Bool = false, in ctx: CGContext) {
        self.init(path: path, options: options, drawn: drawn, fit: fit,
                  target: DrawTarget(userToDevice: ctx.userSpaceToDeviceSpaceTransform))
    }

    init?(path: String, options: ImageOptions, drawn: CGSize?, fit: Bool = false, target: DrawTarget) {
        self.init(path: SymbolImages.drawingPath(path, options: options, drawn: drawn, fit: fit, target: target),
                  options: options)
    }
}
