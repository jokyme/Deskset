import AppKit

/// Deskset's brand icon aligned with Deskset Pro (套印 risograph double-D on warm paper) and its menu bar glyph.
/// `build-app.sh` renders the `.iconset` with `Deskset --make-icon <dir>`; the running app also uses it when unbundled.
enum AppIcon {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat((hex >> 16) & 0xFF) / 255,
                CGFloat((hex >> 8) & 0xFF) / 255,
                CGFloat(hex & 0xFF) / 255,
                alpha,
            ]
        ) ?? CGColor(gray: 0, alpha: alpha)
    }

    private static func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient? {
        CGGradient(
            colorsSpace: colorSpace,
            colors: stops.map { color($0.0, $0.1) } as CFArray,
            locations: stops.map(\.2)
        )
    }

    /// Deterministic hash in `0..<1` for the risograph paper grain.
    private static func noise(_ index: Int, _ seed: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: index &* 374_761_393 &+ seed &* 668_265_263)
        x = (x ^ (x >> 13)) &* 1_274_126_177
        return CGFloat((x ^ (x >> 16)) & 0xFFFF) / 65_535
    }

    /// A geometric `D` with its counter, left edge `x`, bottom `y`, `height` tall, in 1024-point canvas units.
    private static func letterD(x: CGFloat, y: CGFloat, height h: CGFloat, unit: CGFloat) -> CGPath {
        let r = h / 2
        let straight = h * 0.34
        let stroke = h * 0.27
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x * unit, y: y * unit))
        path.addLine(to: CGPoint(x: (x + straight) * unit, y: y * unit))
        path.addArc(
            center: CGPoint(x: (x + straight) * unit, y: (y + r) * unit),
            radius: r * unit,
            startAngle: -.pi / 2,
            endAngle: .pi / 2,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: x * unit, y: (y + h) * unit))
        path.closeSubpath()

        path.move(to: CGPoint(x: (x + stroke) * unit, y: (y + stroke) * unit))
        path.addLine(to: CGPoint(x: (x + straight) * unit, y: (y + stroke) * unit))
        path.addArc(
            center: CGPoint(x: (x + straight) * unit, y: (y + r) * unit),
            radius: (r - stroke) * unit,
            startAngle: -.pi / 2,
            endAngle: .pi / 2,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: (x + stroke) * unit, y: (y + h - stroke) * unit))
        path.closeSubpath()
        return path
    }

    /// Draws the icon into `ctx` (bottom-left origin) filling `size` × `size`.
    static func draw(in ctx: CGContext, size: CGFloat, pixelHint: Int? = nil) {
        let pixels = pixelHint ?? Int(max(16, size.rounded()))
        let unit = size / 1024
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        // macOS icon grid: 824-point rounded square on a 1024-point canvas, corners 22.5% of its side.
        let rect = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let shape = CGPath(
            roundedRect: rect,
            cornerWidth: rect.width * 0.225,
            cornerHeight: rect.width * 0.225,
            transform: nil
        )
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: color(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(color(0x000000))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let paper = gradient([(0xF8F4EC, 1, 0), (0xEEE7DA, 1, 1)]) {
            ctx.drawLinearGradient(
                paper,
                start: CGPoint(x: 0, y: rect.maxY),
                end: CGPoint(x: 0, y: rect.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Two risograph prints off-register by `offset` each way, multiplied where they overlap.
        let height: CGFloat = 470
        let offset: CGFloat = pixels <= 32 ? 48 : pixels < 128 ? 40 : 30
        let left = 512 - height * 0.84 / 2
        let bottom = 512 - height / 2
        let blue = letterD(x: left - offset, y: bottom + offset, height: height, unit: unit)
        let orange = letterD(x: left + offset, y: bottom - offset, height: height, unit: unit)

        ctx.addPath(blue)
        ctx.setFillColor(color(0x3D5BD9))
        ctx.fillPath(using: .evenOdd)

        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.addPath(orange)
        ctx.setFillColor(color(0xFF6B2C))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // Risograph grain: warm paper showing through the ink in fine specks at 256 px and up.
        if pixels >= 256 {
            ctx.saveGState()
            ctx.addPath(blue)
            ctx.addPath(orange)
            ctx.clip(using: .evenOdd)
            let step = 5 * unit
            var index = 0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    if noise(index, 11) > 0.72 {
                        ctx.setFillColor(color(0xFFF8EE, 0.08 + 0.22 * noise(index, 17)))
                        ctx.fill(CGRect(x: x, y: y, width: step * 0.6, height: step * 0.6))
                    }
                    x += step
                    index += 1
                }
                y += step
            }
            ctx.restoreGState()
        }

        ctx.restoreGState()
        ctx.restoreGState()
    }

    static func cgImage(pixels: Int) -> CGImage? {
        let px = min(max(pixels, 16), 2048)
        guard let ctx = CGContext(
            data: nil,
            width: px,
            height: px,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        draw(in: ctx, size: CGFloat(px), pixelHint: px)
        return ctx.makeImage()
    }

    /// PNG data of the icon at `pixels` × `pixels`.
    static func pngData(pixels: Int) -> Data? {
        guard let image = cgImage(pixels: pixels) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func image(size: CGFloat) -> NSImage {
        let pixels = min(max(Int((size * 2).rounded()), 32), 1024)
        if let cg = cgImage(pixels: pixels) {
            return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, size: rect.width)
            return true
        }
    }

    /// Standard `.iconset` sizes (`iconutil -c icns` turns the folder into `Deskset.icns`).
    static let iconsetEntries: [(name: String, pixels: Int)] = [16, 32, 128, 256, 512].flatMap { size in
        [("icon_\(size)x\(size).png", size), ("icon_\(size)x\(size)@2x.png", size * 2)]
    }

    /// `Deskset --make-icon <dir.iconset>`.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in iconsetEntries {
            guard let data = pngData(pixels: entry.pixels) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "cannot render \(entry.name)"])
            }
            try data.write(to: directory.appendingPathComponent(entry.name))
        }
    }

    /// Outer silhouette of a geometric `D` (without counter), used for crisp negative-space knockout in the menu bar glyph.
    private static func outerLetterD(x: CGFloat, y: CGFloat, height h: CGFloat) -> CGPath {
        let r = h / 2
        let straight = h * 0.34
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + straight, y: y))
        path.addArc(
            center: CGPoint(x: x + straight, y: y + r),
            radius: r,
            startAngle: -.pi / 2,
            endAngle: .pi / 2,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: x, y: y + h))
        path.closeSubpath()
        return path
    }

    /// Menu bar glyph matching Deskset's double-D brand mark: 100% solid pixel-aligned front `D` + negative-space
    /// knockout offset `D` (no semi-transparent fringes, so edges stay razor-sharp on translucent menu bars).
    static func statusBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let ink = CGColor(gray: 0, alpha: 1)
            let h: CGFloat = 11.5
            let backD = letterD(x: 5.5, y: 2.0, height: h, unit: 1)
            let frontOuter = outerLetterD(x: 3.0, y: 4.5, height: h)
            let frontD = letterD(x: 3.0, y: 4.5, height: h, unit: 1)

            ctx.saveGState()
            ctx.setAllowsAntialiasing(true)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)

            // 1. Back D (bottom-right) at full solid opacity.
            ctx.addPath(backD)
            ctx.setFillColor(ink)
            ctx.fillPath(using: .evenOdd)

            // 2. Clean 1.2pt negative-space gap around the front D so the two Ds read clearly without gray blur.
            ctx.setBlendMode(.clear)
            ctx.addPath(frontOuter)
            ctx.setLineWidth(2.4)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.addPath(frontOuter)
            ctx.fillPath()

            // 3. Pixel-aligned front D (top-left) at full solid opacity.
            ctx.setBlendMode(.normal)
            ctx.addPath(frontD)
            ctx.setFillColor(ink)
            ctx.fillPath(using: .evenOdd)

            ctx.endTransparencyLayer()
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Deskset"
        return image
    }
}
