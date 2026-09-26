// Regenerates the original test images of TestSkins/Round:
//     swift TestSkins/Round/make-images.swift TestSkins/Round
import AppKit

let root = CommandLine.arguments[1]

func canvas(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, y down.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: root + "/" + path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) \(image.width)x\(image.height)")
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Second hand: points right; pivot at (20, 6). Thin bar, round counterweight, pivot cap.
save(canvas(104, 12) { c in
    let red = rgb(235, 72, 60)
    c.setFillColor(red)
    c.fill(CGRect(x: 2, y: 5, width: 100, height: 2))
    c.fillEllipse(in: CGRect(x: 2, y: 2, width: 8, height: 8))      // counterweight
    c.fillEllipse(in: CGRect(x: 15, y: 1, width: 10, height: 10))   // pivot cap
    c.setFillColor(rgb(40, 40, 48))
    c.fillEllipse(in: CGRect(x: 18, y: 4, width: 4, height: 4))
}, "AnalogClock/Images/SecondHand.png")

// Gear: 64x64, 8 teeth, one tooth marked orange so the rotation is visible.
func gear(_ c: CGContext, size: CGFloat, teeth: Int) {
    let cx = size / 2, cy = size / 2
    let outer = size / 2 - 1, inner = size / 2 - 9
    let path = CGMutablePath()
    let steps = teeth * 4
    for i in 0...steps {
        let a = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let r = (i % 4 == 1 || i % 4 == 2) ? outer : inner
        let p = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    path.addEllipse(in: CGRect(x: cx - 9, y: cy - 9, width: 18, height: 18))
    c.addPath(path)
    c.setFillColor(rgb(170, 180, 195))
    c.fillPath(using: .evenOdd)
    // Marker on the tooth at angle ~ +x.
    let a0: CGFloat = 1.5 / CGFloat(steps) * 2 * .pi
    c.setFillColor(rgb(255, 150, 40))
    c.fillEllipse(in: CGRect(x: cx + (outer - 7) * cos(a0) - 4, y: cy + (outer - 7) * sin(a0) - 4, width: 8, height: 8))
}
save(canvas(64, 64) { gear($0, size: 64, teeth: 8) }, "Gauges/Images/Gear.png")

// Needle: points right, pivot at (8, 5); 70x10.
save(canvas(70, 10) { c in
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 3.5))
    path.addLine(to: CGPoint(x: 70, y: 5))
    path.addLine(to: CGPoint(x: 0, y: 6.5))
    path.closeSubpath()
    c.addPath(path)
    c.setFillColor(rgb(255, 255, 255))
    c.fillPath()
    c.fillEllipse(in: CGRect(x: 3, y: 0, width: 10, height: 10))
}, "Gauges/Images/Needle.png")

// Arrow: 40x20, points right, two colors (top half red, bottom half blue) so flips are visible.
save(canvas(40, 20) { c in
    c.setFillColor(rgb(230, 70, 70))
    c.fill(CGRect(x: 0, y: 7, width: 26, height: 3))
    c.setFillColor(rgb(70, 120, 230))
    c.fill(CGRect(x: 0, y: 10, width: 26, height: 3))
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 24, y: 1))
    head.addLine(to: CGPoint(x: 40, y: 10))
    head.addLine(to: CGPoint(x: 24, y: 10))
    head.closeSubpath()
    c.setFillColor(rgb(230, 70, 70))
    c.addPath(head)
    c.fillPath()
    let head2 = CGMutablePath()
    head2.move(to: CGPoint(x: 24, y: 10))
    head2.addLine(to: CGPoint(x: 40, y: 10))
    head2.addLine(to: CGPoint(x: 24, y: 19))
    head2.closeSubpath()
    c.setFillColor(rgb(70, 120, 230))
    c.addPath(head2)
    c.fillPath()
}, "Gauges/Images/Arrow.png")

// Rect: 80x40 (the "Rotate an Image Around its Center" tip): left half orange, right half blue, a white dot on
// the center, a dark notch at the top-left corner so the orientation is visible.
save(canvas(80, 40) { c in
    c.setFillColor(rgb(255, 160, 60))
    c.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    c.setFillColor(rgb(90, 180, 255))
    c.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
    c.setFillColor(rgb(30, 30, 36))
    c.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    c.setFillColor(rgb(255, 255, 255))
    c.fillEllipse(in: CGRect(x: 36, y: 16, width: 8, height: 8))
}, "Edges/Images/Rect.png")
