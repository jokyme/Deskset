// Generates the original test images used by TestSkins/App (run: swift TestSkins/App/generate-images.swift).
import AppKit

func writePNG(_ name: String, width: Int, height: Int, _ draw: (CGContext) -> Void) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("bitmap") }
    draw(context.cgContext)
    let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("@Resources/Images/\(name)")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// 1×1 pixel: tiling it over a big skin must not take one draw call per pixel.
writePNG("Dot.png", width: 1, height: 1) { ctx in
    ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.55, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
}

// 16×16 checker tile with a marked top-left corner (shows orientation and tile origin).
writePNG("Checker.png", width: 16, height: 16) { ctx in
    ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.18, blue: 0.26, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.3, blue: 0.42, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    ctx.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
    // Top-left 4×4 in orange (CG origin is bottom-left: top rows are y 12…16).
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 12, width: 4, height: 4))
}

// Button strip, 3 frames of 20×20 side by side (normal red, pressed green, hover blue), each a disc on a transparent
// square: the corners are not part of the button.
writePNG("Button.png", width: 60, height: 20) { ctx in
    for (i, color) in [(1.0, 0.2, 0.2), (0.2, 0.8, 0.3), (0.2, 0.4, 1.0)].enumerated() {
        ctx.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: i * 20, y: 0, width: 20, height: 20))
    }
}

// 30×30 frame for BackgroundMode=3 with BackgroundMargins=10,10,10,10: a 10-pixel orange border around a blue center.
writePNG("Frame.png", width: 30, height: 30) { ctx in
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 10, y: 10, width: 10, height: 10))
}

// 40×20 stored pixels (left half red, right half blue) with EXIF orientation 6 ("rotate 90° clockwise to view"):
// UseExifOrientation=0 (the default) must show the stored 40×20 pixels, UseExifOrientation=1 a 20×40 image.
do {
    guard let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
    let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("@Resources/Images/Exif6.tif")
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)
    else { fatalError("tiff") }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("tiff write") }
}
