import AppKit
import DesksetCore

/// What lies behind the widget on the Studio's canvas (the preview bar's Backdrop menu). Only the Studio's view
/// changes; the choice is remembered for the user.
enum StudioBackdropKind: String, CaseIterable {
    /// The desktop picture of the screen the widget is on, where the widget really is.
    case desktop
    /// Samples: a bright, a busy and a dark picture.
    case bright, busy, dark
    /// A quiet surface with a dot grid.
    case workbench
    /// A checkerboard: what the widget leaves transparent shows.
    case transparent
    /// A plain color (offered while Reduce Transparency is on).
    case solid

    var title: String {
        switch self {
        case .desktop: return StudioText[.backdropDesktop]
        case .bright: return StudioText[.backdropBright]
        case .busy: return StudioText[.backdropBusy]
        case .dark: return StudioText[.backdropDark]
        case .workbench: return StudioText[.backdropWorkbench]
        case .transparent: return StudioText[.backdropTransparent]
        case .solid: return StudioText[.backdropSolid]
        }
    }

    /// The kinds the menu offers (Solid only while Reduce Transparency is on).
    static func offered(reduceTransparency: Bool) -> [StudioBackdropKind] {
        allCases.filter { $0 != .solid || reduceTransparency }
    }
}

/// The pictures the Studio draws itself: original, procedural and the same on every run (no photos, nothing read).
enum StudioSample: Equatable {
    /// Hills under a morning sky: the stand-in for the desktop picture in snapshots (light).
    case dawn
    /// The same hills at dusk (dark).
    case dusk
    /// A pale, warm wash.
    case bright
    /// City lights at night: busy and dark, for checking what stays readable.
    case busy

    /// Whether text over it should be light.
    var isDark: Bool { self == .dusk || self == .busy }
}

/// How the widget's screen lies on the canvas: the widget's real frame (global coordinates, y up) is drawn at the
/// canvas's card rect (a flipped view's coordinates), at the canvas zoom. Everything else on the desktop — the
/// picture, the other widgets — is placed around it the same way, so at 100 % it lines up with the real desktop.
struct DesktopMapping: Equatable {
    var widgetFrame: CGRect
    var cardRect: CGRect
    var zoom: CGFloat

    /// A rect of the desktop (global coordinates, y up) in the view's flipped coordinates.
    func viewRect(forScreenRect r: CGRect) -> CGRect {
        CGRect(x: cardRect.minX + (r.minX - widgetFrame.minX) * zoom,
               y: cardRect.minY + (widgetFrame.maxY - r.maxY) * zoom,
               width: r.width * zoom, height: r.height * zoom)
    }
}

// MARK: - Drawing the samples

enum StudioWallpapers {
    private struct CacheKey: Hashable {
        var sample: String
        var width: Int
        var height: Int
    }
    private static var cache: [CacheKey: CGImage] = [:]
    private static var cacheOrder: [CacheKey] = []

    /// `sample` drawn at `size` points and `scale` pixels per point (kept for the next draw of the same size).
    static func image(_ sample: StudioSample, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = max(Int((size.width * scale).rounded()), 1), h = max(Int((size.height * scale).rounded()), 1)
        let key = CacheKey(sample: "\(sample)", width: w, height: h)
        if let image = cache[key] { return image }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin, points.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(sample, in: CGRect(origin: .zero, size: size), ctx)
        guard let image = ctx.makeImage() else { return nil }
        cache[key] = image
        cacheOrder.append(key)
        if cacheOrder.count > 6 { cache[cacheOrder.removeFirst()] = nil }
        return image
    }

    /// Draws `sample` into `rect` of a context whose y axis points down.
    static func draw(_ sample: StudioSample, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: rect)
        switch sample {
        case .dawn: drawHills(dawn: true, in: rect, ctx)
        case .dusk: drawHills(dawn: false, in: rect, ctx)
        case .bright: drawMesh(brightColors, columns: 3, in: rect, ctx)
        case .busy: drawBusy(in: rect, ctx)
        }
        ctx.restoreGState()
    }

    typealias RGB = (Double, Double, Double)

    static let dawnSky: [RGB] = [
        (0.98, 0.62, 0.47), (0.97, 0.52, 0.50), (0.83, 0.52, 0.80), (0.56, 0.55, 0.97),
        (0.96, 0.45, 0.42), (0.93, 0.47, 0.55), (0.72, 0.52, 0.90), (0.50, 0.56, 0.99),
        (0.92, 0.40, 0.40), (0.85, 0.50, 0.66), (0.62, 0.58, 0.95), (0.55, 0.66, 0.97),
        (0.86, 0.40, 0.38), (0.80, 0.55, 0.62), (0.62, 0.66, 0.90), (0.70, 0.78, 0.86),
    ]
    static let duskSky: [RGB] = [
        (0.10, 0.09, 0.22), (0.16, 0.10, 0.30), (0.22, 0.12, 0.36), (0.10, 0.12, 0.30),
        (0.14, 0.10, 0.28), (0.36, 0.14, 0.40), (0.50, 0.18, 0.42), (0.16, 0.16, 0.40),
        (0.08, 0.12, 0.24), (0.30, 0.14, 0.36), (0.22, 0.16, 0.42), (0.08, 0.18, 0.34),
        (0.04, 0.08, 0.14), (0.08, 0.12, 0.20), (0.08, 0.14, 0.24), (0.06, 0.10, 0.18),
    ]
    static let brightColors: [RGB] = [
        (0.98, 0.96, 0.92), (0.97, 0.93, 0.86), (0.90, 0.94, 0.99),
        (0.99, 0.90, 0.84), (1.00, 0.98, 0.95), (0.86, 0.92, 0.99),
        (0.93, 0.95, 0.90), (0.96, 0.97, 0.95), (0.88, 0.90, 0.97),
    ]

    /// A soft wash through a grid of colors (`columns` × `columns`, row by row from the top): each pixel of a small
    /// picture blends its four nearest colors with eased weights, and the picture is drawn smoothly scaled up.
    static func drawMesh(_ colors: [RGB], columns n: Int, in rect: CGRect, _ ctx: CGContext) {
        let w = 96, h = 64
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        for y in 0..<h {
            let fy = Double(y) / Double(h - 1) * Double(n - 1)
            let row = min(Int(fy), n - 2), ty = ease(fy - Double(row))
            for x in 0..<w {
                let fx = Double(x) / Double(w - 1) * Double(n - 1)
                let col = min(Int(fx), n - 2), tx = ease(fx - Double(col))
                let a = colors[row * n + col], b = colors[row * n + col + 1]
                let c = colors[(row + 1) * n + col], d = colors[(row + 1) * n + col + 1]
                func mix(_ p: Double, _ q: Double, _ r: Double, _ s: Double) -> UInt8 {
                    let top = p + (q - p) * tx, bottom = r + (s - r) * tx
                    return UInt8(max(0, min(255, (top + (bottom - top) * ty) * 255)).rounded())
                }
                let i = (y * w + x) * 4
                pixels[i] = mix(a.0, b.0, c.0, d.0)
                pixels[i + 1] = mix(a.1, b.1, c.1, d.1)
                pixels[i + 2] = mix(a.2, b.2, c.2, d.2)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // The context's y axis points down: flip the picture back upright.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// A hill: a soft curve through `points` (unit coordinates, left to right), filled down to the bottom edge.
    private static func hill(_ points: [CGPoint], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func p(_ u: CGPoint) -> CGPoint { CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height) }
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: p(points[0]))
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            path.addQuadCurve(to: p(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)), control: p(a))
        }
        path.addLine(to: p(points[points.count - 1]))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private static func fill(_ path: CGPath, top: RGB, bottom: RGB, alpha: CGFloat = 1, in rect: CGRect,
                             _ ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: alpha),
                      CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: alpha)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                     locations: [0, 1]) {
            let box = path.boundingBox
            ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY),
                                   end: CGPoint(x: box.midX, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
    }

    static func drawHills(dawn: Bool, in rect: CGRect, _ ctx: CGContext) {
        drawMesh(dawn ? dawnSky : duskSky, columns: 4, in: rect, ctx)
        if dawn {
            fill(hill([CGPoint(x: 0, y: 0.62), CGPoint(x: 0.22, y: 0.70), CGPoint(x: 0.48, y: 0.80),
                       CGPoint(x: 0.75, y: 0.86), CGPoint(x: 1, y: 0.80)], in: rect),
                 top: (0.24, 0.52, 0.30), bottom: (0.12, 0.36, 0.20), in: rect, ctx)
            fill(hill([CGPoint(x: 0, y: 0.86), CGPoint(x: 0.30, y: 0.80), CGPoint(x: 0.62, y: 0.88),
                       CGPoint(x: 0.85, y: 0.83), CGPoint(x: 1, y: 0.74)], in: rect),
                 top: (0.55, 0.74, 0.36), bottom: (0.35, 0.60, 0.28), in: rect, ctx)
            fill(hill([CGPoint(x: 0, y: 0.95), CGPoint(x: 0.4, y: 0.93), CGPoint(x: 0.7, y: 0.97),
                       CGPoint(x: 1, y: 0.92)], in: rect),
                 top: (0.16, 0.40, 0.22), bottom: (0.16, 0.40, 0.22), alpha: 0.85, in: rect, ctx)
        } else {
            fill(hill([CGPoint(x: 0, y: 0.70), CGPoint(x: 0.25, y: 0.76), CGPoint(x: 0.50, y: 0.84),
                       CGPoint(x: 0.78, y: 0.88), CGPoint(x: 1, y: 0.80)], in: rect),
                 top: (0.07, 0.20, 0.24), bottom: (0.03, 0.10, 0.12), in: rect, ctx)
            fill(hill([CGPoint(x: 0, y: 0.88), CGPoint(x: 0.35, y: 0.84), CGPoint(x: 0.66, y: 0.92),
                       CGPoint(x: 1, y: 0.86)], in: rect),
                 top: (0.03, 0.07, 0.09), bottom: (0.03, 0.07, 0.09), in: rect, ctx)
        }
    }

    /// City lights at night, out of focus: a dark gradient, soft round lights and a few bright streaks.
    static func drawBusy(in rect: CGRect, _ ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let sky = [CGColor(srgbRed: 0.05, green: 0.07, blue: 0.16, alpha: 1),
                   CGColor(srgbRed: 0.14, green: 0.10, blue: 0.20, alpha: 1),
                   CGColor(srgbRed: 0.30, green: 0.16, blue: 0.14, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: sky, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        let palette: [RGB] = [(1.0, 0.78, 0.35), (1.0, 0.45, 0.40), (0.45, 0.80, 1.0), (1.0, 0.95, 0.85),
                              (0.95, 0.55, 0.95)]
        var seed: UInt64 = 0x2F6B_FF11
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10_000) / 10_000
        }
        for _ in 0..<70 {
            let x = next(), y = 0.15 + next() * 0.85, size = 0.02 + next() * 0.07
            let color = palette[Int(next() * 5) % 5]
            let centre = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
            let radius = size * rect.width / 2
            let stops = [CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0.75),
                         CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0.6),
                         CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 0)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: stops, locations: [0, 0.7, 1]) {
                ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                       endRadius: radius * 1.15, options: [])
            }
        }
        for i in 0..<6 {
            ctx.saveGState()
            let centre = CGPoint(x: rect.midX, y: rect.minY + rect.height * (0.72 + CGFloat(i) * 0.05))
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.rotate(by: CGFloat(-12 + i * 5) * .pi / 180)
            let line = CGRect(x: -rect.width * 0.45, y: -1.5, width: rect.width * 0.9, height: 3)
            ctx.addPath(CGPath(roundedRect: line, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 0.45))
            ctx.setShadow(offset: .zero, blur: 4, color: CGColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 0.6))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}

// MARK: - The backdrop view

/// The canvas's backdrop plane: the desktop picture (or a sample in its place), a sample, the workbench, the
/// checkerboard or a plain color. The desktop picture is placed by the desktop mapping (the widget where it really
/// is); the others fill the view.
final class StudioBackdropView: NSView {
    var kind = StudioBackdropKind.desktop { didSet { if kind != oldValue { needsDisplay = true } } }
    /// The desktop picture of the widget's screen (nil: not read yet, or no screen: the stand-in).
    var wallpaper: StudioWallpaper? { didSet { needsDisplay = true } }
    /// Draws the procedural hills for "Your Desktop" (snapshots and self-tests: the same picture on every Mac).
    var usesStandInDesktop = false { didSet { needsDisplay = true } }
    var mapping: DesktopMapping? { didSet { if mapping != oldValue, kind == .desktop { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The sample "Your Desktop" shows now (nil: the real picture).
    var desktopSample: StudioSample? {
        if usesStandInDesktop { return isDark ? .dusk : .dawn }
        guard let wallpaper else { return isDark ? .dusk : .bright }
        return wallpaper.image == nil ? wallpaper.sample : nil
    }

    /// Whether what shows behind the widget is dark (for glass stand-ins and the canvas's marks).
    var showsDarkBackdrop: Bool {
        switch kind {
        case .desktop: return desktopSample?.isDark ?? isDark
        case .bright: return false
        case .busy, .dark: return true
        case .workbench, .transparent, .solid: return isDark
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = isDark
        switch kind {
        case .desktop:
            if let sample = desktopSample {
                drawSample(sample, ctx)
            } else if let wallpaper {
                drawWallpaper(wallpaper, ctx)
            }
        case .bright: drawSample(.bright, ctx)
        case .busy: drawSample(.busy, ctx)
        case .dark: drawSample(.dusk, ctx)
        case .workbench: Self.drawWorkbench(bounds, dirty: dirtyRect, dark: dark, ctx)
        case .transparent: Self.drawCheckerboard(bounds, dirty: dirtyRect, dark: dark, ctx)
        case .solid:
            ctx.setFillColor(dark ? CGColor(gray: 0.17, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
            ctx.fill(dirtyRect)
        }
    }

    private func drawSample(_ sample: StudioSample, _ ctx: CGContext) {
        let scale = window?.backingScaleFactor ?? 2
        if let image = StudioWallpapers.image(sample, size: bounds.size, scale: scale) {
            // The picture's rows are top first; this view is flipped.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        } else {
            StudioWallpapers.draw(sample, in: bounds, ctx)
        }
    }

    /// The desktop picture laid out on its screen, the screen placed by the mapping; the fill color around it (and
    /// beyond the screen's edges).
    private func drawWallpaper(_ wallpaper: StudioWallpaper, _ ctx: CGContext) {
        ctx.setFillColor(wallpaper.fillColor)
        ctx.fill(bounds)
        guard let image = wallpaper.image, let local = wallpaper.pictureRect else { return }
        let screen = wallpaper.screenFrame
        let global = local.offsetBy(dx: screen.minX, dy: screen.minY)
        let mapping = self.mapping ?? DesktopMapping(widgetFrame: CGRect(x: screen.midX, y: screen.midY, width: 0,
                                                                         height: 0),
                                                     cardRect: CGRect(x: bounds.midX, y: bounds.midY, width: 0,
                                                                      height: 0),
                                                     zoom: min(bounds.width / screen.width,
                                                               bounds.height / screen.height))
        let target = mapping.viewRect(forScreenRect: global)
        let screenRect = mapping.viewRect(forScreenRect: screen)
        func draw(_ picture: CGImage, in rect: CGRect) {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(picture, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.clip(to: screenRect)
        ctx.interpolationQuality = .high
        draw(image, in: target)
        ctx.restoreGState()
        // Past the screen's edges (a widget near one) the picture goes on as its mirror image, rather than a blank —
        // when it covers the screen; around a picture that does not, the fill color is what macOS shows.
        guard target.minX <= screenRect.minX + 0.5, target.maxX >= screenRect.maxX - 0.5,
              target.minY <= screenRect.minY + 0.5, target.maxY >= screenRect.maxY - 0.5 else { return }
        let b = bounds
        let xs = [(b.minX, screenRect.minX), (screenRect.minX, screenRect.maxX), (screenRect.maxX, b.maxX)]
        let ys = [(b.minY, screenRect.minY), (screenRect.minY, screenRect.maxY), (screenRect.maxY, b.maxY)]
        for (i, x) in xs.enumerated() {
            for (j, y) in ys.enumerated() where !(i == 1 && j == 1) {
                let region = CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
                guard region.width > 0, region.height > 0 else { continue }
                ctx.saveGState()
                ctx.clip(to: region)
                ctx.interpolationQuality = .medium
                // Reflected across the screen edge the region lies beyond.
                if i != 1 {
                    let edge = i == 0 ? screenRect.minX : screenRect.maxX
                    ctx.translateBy(x: 2 * edge, y: 0)
                    ctx.scaleBy(x: -1, y: 1)
                }
                if j != 1 {
                    let edge = j == 0 ? screenRect.minY : screenRect.maxY
                    ctx.translateBy(x: 0, y: 2 * edge)
                    ctx.scaleBy(x: 1, y: -1)
                }
                ctx.clip(to: screenRect)
                draw(image, in: target)
                ctx.restoreGState()
            }
        }
    }

    /// A quiet surface with a faint dot grid (16 pt apart).
    static func drawWorkbench(_ bounds: CGRect, dirty: CGRect, dark: Bool, _ ctx: CGContext) {
        ctx.setFillColor(dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.955, alpha: 1))
        ctx.fill(dirty)
        ctx.setFillColor(dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.13))
        let step: CGFloat = 16
        var y = (floor((dirty.minY - 8) / step)) * step + 8
        while y <= dirty.maxY + 1 {
            var x = (floor((dirty.minX - 8) / step)) * step + 8
            while x <= dirty.maxX + 1 {
                ctx.fillEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                x += step
            }
            y += step
        }
    }

    /// A checkerboard of 8 pt squares.
    static func drawCheckerboard(_ bounds: CGRect, dirty: CGRect, dark: Bool, _ ctx: CGContext) {
        ctx.setFillColor(dark ? CGColor(gray: 0.22, alpha: 1) : CGColor(gray: 1, alpha: 1))
        ctx.fill(dirty)
        ctx.setFillColor(dark ? CGColor(gray: 0.28, alpha: 1) : CGColor(gray: 0.90, alpha: 1))
        let size: CGFloat = 8
        var row = Int(floor(dirty.minY / size))
        var y = CGFloat(row) * size
        while y < dirty.maxY {
            var x = floor(dirty.minX / (2 * size)) * 2 * size + (row % 2 == 0 ? 0 : size)
            while x < dirty.maxX {
                ctx.fill(CGRect(x: x, y: y, width: size, height: size))
                x += 2 * size
            }
            y += size
            row += 1
        }
    }
}
