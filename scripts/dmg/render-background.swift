#!/usr/bin/env swift
import AppKit

// Finder layout, in points from the top-left corner of the content area:
// - Window content: 720 × 460.
// - Deskset.app icon center: (190, 225); Applications icon center: (530, 225).
// - Native icon size: 112; labels belong below the icons, inside the cards.
// - Cards: (104, 151, 172, 176) and (444, 151, 172, 176).
// This image deliberately contains neither application icons nor their labels:
// Finder supplies the real draggable items. Keep its toolbar and status bar hidden.
// Usage: swift scripts/dmg/render-background.swift <background.tiff> [preview.png]

private let canvas = NSSize(width: 720, height: 460)
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red / 255, green / 255, blue / 255, alpha])
        ?? CGColor(gray: 1, alpha: alpha)
}

private func rectFromTop(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
    CGRect(x: x, y: canvas.height - y - height, width: width, height: height)
}

private func drawText(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight,
                      color textColor: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: textColor,
    ]
    let value = NSAttributedString(string: text, attributes: attributes)
    let size = value.size()
    value.draw(at: NSPoint(x: (canvas.width - size.width) / 2, y: canvas.height - top - size.height))
}

private func drawBackground(in context: CGContext) {
    let bounds = CGRect(origin: .zero, size: canvas)
    context.setFillColor(color(247, 250, 253))
    context.fill(bounds)

    // AppIcon.swift's blue (34, 92, 170) and teal (22, 170, 186), softened so
    // Finder's black filename labels remain readable in light and dark mode.
    let glows: [(center: CGPoint, radius: CGFloat, tint: CGColor)] = [
        (CGPoint(x: 56, y: 430), 510, color(34, 92, 170, 0.085)),
        (CGPoint(x: 694, y: 70), 460, color(22, 170, 186, 0.075)),
        (CGPoint(x: 360, y: 230), 340, color(255, 255, 255, 0.92)),
    ]
    for glow in glows {
        if let gradient = CGGradient(colorsSpace: colorSpace,
                                     colors: [glow.tint, glow.tint.copy(alpha: 0) ?? glow.tint] as CFArray,
                                     locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: glow.center, startRadius: 0,
                                       endCenter: glow.center, endRadius: glow.radius, options: [])
        }
    }

    // A small brand accent, intentionally quieter than the real app icon.
    let accent = CGPath(roundedRect: rectFromTop(x: 346, y: 29, width: 28, height: 4),
                        cornerWidth: 2, cornerHeight: 2, transform: nil)
    context.saveGState()
    context.addPath(accent)
    context.clip()
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                 colors: [color(34, 92, 170), color(22, 170, 186)] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 346, y: 429),
                                   end: CGPoint(x: 374, y: 429), options: [])
    }
    context.restoreGState()

    drawText("Deskset", top: 46, size: 32, weight: .semibold,
             color: NSColor(srgbRed: 28 / 255, green: 44 / 255, blue: 69 / 255, alpha: 1))
    drawText("Desktop widgets for your Mac", top: 91, size: 14, weight: .regular,
             color: NSColor(srgbRed: 98 / 255, green: 115 / 255, blue: 135 / 255, alpha: 1))

    for x: CGFloat in [104, 444] {
        let card = CGPath(roundedRect: rectFromTop(x: x, y: 151, width: 172, height: 176),
                          cornerWidth: 24, cornerHeight: 24, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -5), blur: 20, color: color(34, 92, 170, 0.035))
        context.setFillColor(color(255, 255, 255, 0.78))
        context.addPath(card)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(color(54, 93, 141, 0.055))
        context.setLineWidth(1)
        context.addPath(card)
        context.strokePath()
    }

    // One continuous right-pointing arrow, aligned to the native icon centers.
    context.saveGState()
    context.setStrokeColor(color(76, 119, 155, 0.65))
    context.setLineWidth(2.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 325, y: 235))
    context.addLine(to: CGPoint(x: 395, y: 235))
    context.move(to: CGPoint(x: 383, y: 247))
    context.addLine(to: CGPoint(x: 395, y: 235))
    context.addLine(to: CGPoint(x: 383, y: 223))
    context.strokePath()
    context.restoreGState()

    drawText("Drag Deskset to Applications.", top: 359, size: 18, weight: .medium,
             color: NSColor(srgbRed: 44 / 255, green: 62 / 255, blue: 83 / 255, alpha: 1))
    drawText("将 Deskset 拖入 Applications 文件夹即可安装", top: 388, size: 13, weight: .regular,
             color: NSColor(srgbRed: 107 / 255, green: 122 / 255, blue: 139 / 255, alpha: 1))
    drawText("Upgrading? Quit Deskset before replacing it.", top: 427, size: 11, weight: .regular,
             color: NSColor(srgbRed: 118 / 255, green: 132 / 255, blue: 149 / 255, alpha: 1))
}

private func render(scale: Int) throws -> NSBitmapImageRep {
    let pixelsWide = Int(canvas.width) * scale
    let pixelsHigh = Int(canvas.height) * scale
    guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Cannot create background context"])
    }
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    drawBackground(in: context)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Cannot render background"])
    }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = canvas
    return representation
}

private func write(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

let arguments = CommandLine.arguments
guard (2...3).contains(arguments.count) else {
    FileHandle.standardError.write(Data("Usage: swift render-background.swift <background.tiff> [preview.png]\n".utf8))
    exit(2)
}

do {
    let representations = try [1, 2].map { try render(scale: $0) }
    guard let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: representations, using: .lzw, factor: 1) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Cannot encode background TIFF"])
    }
    try write(tiff, to: arguments[1])
    if arguments.count == 3 {
        guard let png = representations[1].representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Cannot encode preview PNG"])
        }
        try write(png, to: arguments[2])
    }
    print("Rendered 720 × 460 pt background with 1x and 2x representations: \(arguments[1])")
} catch {
    FileHandle.standardError.write(Data("render-background: \(error.localizedDescription)\n".utf8))
    exit(1)
}
