import AppKit

/// Deskset's original icon, drawn in code: a rounded tile with a night-to-teal gradient, a soft cloud and three
/// rain streaks of different lengths that double as a bar meter. `build-app.sh` renders the .iconset with
/// `Deskset --make-icon <dir>`; the running app also uses it when it is not bundled (`swift run`).
enum AppIcon {
    /// Draws the icon into `ctx` (bottom-left origin) filling `size` × `size`.
    static func draw(in ctx: CGContext, size: CGFloat) {
        let s = size / 1024
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a]) ?? CGColor(gray: 0, alpha: a)
        }
        func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
            CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
        }

        // Tile with drop shadow (macOS icon grid: 824 pt tile on a 1024 canvas).
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
        ctx.addPath(tilePath)
        ctx.setFillColor(color(30, 44, 110))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        if let g = gradient([color(38, 48, 128), color(34, 92, 170), color(22, 170, 186)], [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        }
        if let glow = gradient([color(255, 255, 255, 0.22), color(255, 255, 255, 0)], [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                                   endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])
        }
        // Rain streaks: rounded bars of different lengths falling from the cloud.
        let bars: [(x: CGFloat, length: CGFloat)] = [(398, 190), (512, 280), (626, 140)]
        for bar in bars {
            let rect = CGRect(x: bar.x - 34, y: 520 - bar.length, width: 68, height: bar.length)
            let path = CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let g = gradient([color(210, 248, 255), color(120, 220, 245, 0.85)], [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY),
                                       options: [])
            }
            ctx.restoreGState()
        }
        // Cloud: circles on a rounded base, painted as one layer so the soft shadow falls only below the union
        // (each shape is filled separately: path directions never punch holes).
        let cloudShapes: [CGPath] = [
            CGPath(roundedRect: CGRect(x: 290, y: 552, width: 450, height: 118), cornerWidth: 59, cornerHeight: 59,
                   transform: nil),
            CGPath(ellipseIn: CGRect(x: 272, y: 566, width: 200, height: 200), transform: nil),
            CGPath(ellipseIn: CGRect(x: 380, y: 592, width: 268, height: 268), transform: nil),
            CGPath(ellipseIn: CGRect(x: 556, y: 566, width: 200, height: 200), transform: nil),
        ]
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(10, 20, 60, 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let cloudGradient = gradient([color(255, 255, 255), color(222, 234, 250)], [0, 1])
        for shape in cloudShapes {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            if let cloudGradient {
                ctx.drawLinearGradient(cloudGradient, start: CGPoint(x: 512, y: 860), end: CGPoint(x: 512, y: 552),
                                       options: [])
            }
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        ctx.restoreGState()

        // Subtle rim.
        ctx.addPath(tilePath)
        ctx.setStrokeColor(color(255, 255, 255, 0.10))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// PNG data of the icon at `pixels` × `pixels`.
    static func pngData(pixels: Int) -> Data? {
        let px = min(max(pixels, 16), 2048)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        draw(in: ctx, size: CGFloat(px))
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, size: rect.width)
            return true
        }
    }

    /// Standard `.iconset` sizes (`iconutil -c icns` turns the folder into Deskset.icns).
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

    /// Menu bar glyph: the same cloud and streaks as a template image (adapts to light / dark menu bars).
    static func statusBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.2, y: 7.0, width: 13.6, height: 4.4), xRadius: 2.2, yRadius: 2.2).fill()
            NSBezierPath(ovalIn: NSRect(x: 1.8, y: 7.2, width: 6.2, height: 6.2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 5.0, y: 8.4, width: 8.6, height: 8.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.2, y: 7.3, width: 6.0, height: 6.0)).fill()
            for (x, length) in [(6.2, 3.6), (9.0, 5.4), (11.8, 2.6)] as [(CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: x - 1.0, y: 6.0 - length, width: 2.0, height: length),
                             xRadius: 1.0, yRadius: 1.0).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Deskset"
        return image
    }
}
