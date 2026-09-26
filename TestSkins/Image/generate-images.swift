// Generates the original test images used by the TestSkins/Image fixtures.
//
//     swift TestSkins/Image/generate-images.swift TestSkins/Image/ImageMeters/@Resources/Images
//
// Every image is drawn here from scratch (no third-party content).
import AppKit
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Draws with a top-left origin (y down) into a w×h RGBA bitmap.
func makeImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String, type: UTType = .png, properties: [CFString: Any] = [:]) {
    let url = outDir.appendingPathComponent(name) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    if !CGImageDestinationFinalize(dest) { print("failed: \(name)") } else { print("wrote \(name)") }
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func text(_ s: String, at p: CGPoint, size: CGFloat, _ c: NSColor, bold: Bool = true) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: c])
}

// Orientation test card: four colored quadrants, an "up" arrow and a label, 120×80.
let card = makeImage(120, 80) { ctx in
    ctx.setFillColor(color(0.85, 0.2, 0.2)); ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
    ctx.setFillColor(color(0.2, 0.7, 0.3)); ctx.fill(CGRect(x: 60, y: 0, width: 60, height: 40))
    ctx.setFillColor(color(0.2, 0.4, 0.9)); ctx.fill(CGRect(x: 0, y: 40, width: 60, height: 40))
    ctx.setFillColor(color(0.95, 0.8, 0.2)); ctx.fill(CGRect(x: 60, y: 40, width: 60, height: 40))
    ctx.setFillColor(color(1, 1, 1))
    ctx.move(to: CGPoint(x: 60, y: 8)); ctx.addLine(to: CGPoint(x: 76, y: 30)); ctx.addLine(to: CGPoint(x: 66, y: 30))
    ctx.addLine(to: CGPoint(x: 66, y: 60)); ctx.addLine(to: CGPoint(x: 54, y: 60)); ctx.addLine(to: CGPoint(x: 54, y: 30))
    ctx.addLine(to: CGPoint(x: 44, y: 30)); ctx.closePath(); ctx.fillPath()
    text("TL", at: CGPoint(x: 4, y: 2), size: 12, .white)
}
save(card, "Card.png")
save(card, "Card.jpg", type: .jpeg)
save(card, "Card.bmp", type: .bmp)
save(card, "Card.gif", type: .gif)
save(card, "Card.tif", type: .tiff)
// Same card stored rotated with EXIF orientation 6 ("rotate 90° clockwise to display"): the stored pixels are the
// card turned 90° counter-clockwise, 80×120.
let stored: CGImage = {
    // Plain y-up context: rotating by +90° turns the card counter-clockwise (its top edge goes to the left).
    let ctx = CGContext(data: nil, width: 80, height: 120, bitsPerComponent: 8, bytesPerRow: 320,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 80, y: 0)
    ctx.rotate(by: .pi / 2)
    ctx.draw(card, in: CGRect(x: 0, y: 0, width: 120, height: 80))
    return ctx.makeImage()!
}()
save(stored, "CardExif6.jpg", type: .jpeg, properties: [kCGImagePropertyOrientation: 6])

// Icon (.ico) with a 16 px and a 32 px image; the 32 px one must be picked.
do {
    let url = outDir.appendingPathComponent("Icon.ico") as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "com.microsoft.ico" as CFString, 2, nil)!
    for size in [16, 32] {
        let img = makeImage(size, size) { ctx in
            ctx.setFillColor(size == 32 ? color(0.3, 0.6, 1) : color(1, 0, 0))
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        CGImageDestinationAddImage(dest, img, nil)
    }
    print(CGImageDestinationFinalize(dest) ? "wrote Icon.ico" : "failed: Icon.ico")
}

// Nine-slice frame, 30×30: 8 px rounded border, distinct corner dots.
save(makeImage(30, 30) { ctx in
    ctx.setFillColor(color(0.15, 0.15, 0.2, 0.9))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 30, height: 30), cornerWidth: 8, cornerHeight: 8,
                       transform: nil)); ctx.fillPath()
    ctx.setStrokeColor(color(0.9, 0.6, 0.2)); ctx.setLineWidth(2)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: 28, height: 28), cornerWidth: 7, cornerHeight: 7,
                       transform: nil)); ctx.strokePath()
    ctx.setFillColor(color(1, 1, 1))
    for (x, y) in [(3, 3), (24, 3), (3, 24), (24, 24)] { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 3, height: 3)) }
}, "Frame9.png")

// Tile, 16×16 checker with a dot.
save(makeImage(16, 16) { ctx in
    ctx.setFillColor(color(0.3, 0.3, 0.35)); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    ctx.setFillColor(color(0.45, 0.45, 0.5)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    ctx.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
    ctx.setFillColor(color(0.9, 0.3, 0.3)); ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: 4, height: 4))
}, "Tile.png")

// Mask: a soft-edged star-ish circle, 64×64 (white, alpha carries the shape).
save(makeImage(64, 64) { ctx in
    ctx.setFillColor(color(1, 1, 1, 0.5)); ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 64, height: 64))
    ctx.setFillColor(color(1, 1, 1, 1)); ctx.fillEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
    ctx.clear(CGRect(x: 28, y: 0, width: 8, height: 30))
}, "Mask.png")

// Digits 0–9, horizontal strip of 10 frames of 12×18.
save(makeImage(120, 18) { ctx in
    for d in 0..<10 {
        ctx.setFillColor(color(0.1, 0.12, 0.2)); ctx.fill(CGRect(x: d * 12, y: 0, width: 11, height: 18))
        text("\(d)", at: CGPoint(x: CGFloat(d * 12) + 2, y: 0), size: 14, NSColor(srgbRed: 0.4, green: 1, blue: 0.6, alpha: 1))
    }
}, "Digits.png")

// Digits 0–9 with 2 transition frames each (30 frames of 12×18): transition frames are dimmed "d>".
save(makeImage(360, 18) { ctx in
    for f in 0..<30 {
        let d = f / 3, t = f % 3
        ctx.setFillColor(t == 0 ? color(0.1, 0.12, 0.2) : color(0.3, 0.1, 0.1))
        ctx.fill(CGRect(x: f * 12, y: 0, width: 11, height: 18))
        text(t == 0 ? "\(d)" : "·", at: CGPoint(x: CGFloat(f * 12) + 2, y: 0), size: 14, .white)
    }
}, "DigitsTransition.png")

// Level meter: 5 frames stacked vertically, 40×12 each (40×60); frame n lights n segments.
save(makeImage(40, 60) { ctx in
    for f in 0..<5 {
        for s in 0..<4 {
            ctx.setFillColor(s < f ? color(0.3, 0.9, 0.4) : color(0.25, 0.25, 0.3))
            ctx.fill(CGRect(x: s * 10 + 1, y: f * 12 + 2, width: 8, height: 8))
        }
    }
}, "Level.png")

// Button: 3 frames side by side, 48×24 each (144×24): normal / pressed / hover, round with transparent corners.
save(makeImage(144, 24) { ctx in
    let fills = [color(0.25, 0.45, 0.8), color(0.15, 0.25, 0.5), color(0.4, 0.65, 1)]
    for i in 0..<3 {
        let r = CGRect(x: CGFloat(i * 48) + 1, y: 1, width: 46, height: 22)
        ctx.setFillColor(fills[i])
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)); ctx.fillPath()
        text(["OK", "OK", "OK"][i], at: CGPoint(x: CGFloat(i * 48) + 15, y: i == 1 ? 4 : 3), size: 12, .white)
    }
}, "Button.png")

// Bar image, 100×12: gradient with 3 px dark end caps.
save(makeImage(100, 12) { ctx in
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0.2, 0.8, 0.4), color(0.95, 0.3, 0.2)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), options: [])
    ctx.setFillColor(color(0.1, 0.1, 0.1)); ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 12))
    ctx.fill(CGRect(x: 97, y: 0, width: 3, height: 12))
}, "BarH.png")

// Vertical bar image, 12×60: gradient bottom→top with 4 px caps.
save(makeImage(12, 60) { ctx in
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0.95, 0.3, 0.2), color(0.2, 0.6, 1)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 60), options: [])
    ctx.setFillColor(color(0.1, 0.1, 0.1)); ctx.fill(CGRect(x: 0, y: 0, width: 12, height: 4))
    ctx.fill(CGRect(x: 0, y: 56, width: 12, height: 4))
}, "BarV.png")
