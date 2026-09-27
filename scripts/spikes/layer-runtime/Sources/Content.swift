// Synthetic skin content drawn with CoreGraphics and CoreText the way Deskset's renderers draw meters: a StylePanel
// (rounded rectangle, 270° linear gradient, hairline border, highlight line), String meters (FontSize at 96 DPI,
// weights, right alignment, tracking, one with AntiAlias=0), an Image meter scaled with high-quality interpolation,
// shapes and bars at fractional coordinates, a Histogram and a Line graph, translucent tracks and pills.
//
// Every element draws in points with a top-left origin (y down), like SkinRenderer in a flipped view. What it draws
// depends only on its `state` at a tick, so the runtime knows exactly which elements changed.
import AppKit
import CoreText

struct RGBA {
    var r, g, b, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 255) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    var cg: CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 255) }
}

/// Deskset's dark theme (DefaultSkins/Deskset/@Resources/Themes/Dark.inc).
enum Theme {
    static let panelTop = RGBA(44, 46, 56, 222), panelBottom = RGBA(24, 25, 32, 228)
    static let panelBorder = RGBA(255, 255, 255, 34), panelHighlight = RGBA(255, 255, 255, 20)
    static let text = RGBA(246, 247, 250), subtle = RGBA(235, 237, 245, 150), faint = RGBA(235, 237, 245, 90)
    static let track = RGBA(255, 255, 255, 26), grid = RGBA(255, 255, 255, 14)
    static let cpu = RGBA(64, 156, 255), cpu2 = RGBA(110, 215, 255), cpuFill = RGBA(64, 156, 255, 70)
    static let memory = RGBA(175, 110, 255), memory2 = RGBA(230, 130, 255)
    static let swap = RGBA(255, 160, 50), swap2 = RGBA(255, 205, 90)
    static let faceTop = RGBA(50, 52, 62, 235), faceBottom = RGBA(26, 27, 34, 240)
    static let accent = RGBA(255, 140, 60)
}

/// One meter. `draw(ctx, state)` paints it; `period` says how often its state changes (0 = never).
final class Element {
    let name: String
    let frame: CGRect
    /// Antialiasing and stroke margin around `frame`, in points.
    var spill: CGFloat = 1.5
    /// A candidate for the base: large (≥ 50 % of the window) and drawn first.
    var big = false
    let period: Int
    let draw: (CGContext, Int) -> Void

    init(_ name: String, _ frame: CGRect, period: Int = 0, spill: CGFloat = 1.5, big: Bool = false,
         draw: @escaping (CGContext, Int) -> Void) {
        self.name = name
        self.frame = frame
        self.period = period
        self.spill = spill
        self.big = big
        self.draw = draw
    }

    var ink: CGRect { frame.insetBy(dx: -spill, dy: -spill) }
    func state(at tick: Int) -> Int { period > 0 ? tick / period : 0 }
    /// Whether its drawing at `tick` differs from the one at `tick - 1`.
    func changes(at tick: Int) -> Bool { period > 0 && tick % period == 0 }
}

final class Widget {
    let name: String
    let size: CGSize
    let elements: [Element]

    init(_ name: String, _ size: CGSize, _ elements: [Element]) {
        self.name = name
        self.size = size
        self.elements = elements
    }

    /// Draws `list` (default: every element) in file order into a top-left context in points.
    func draw(_ ctx: CGContext, tick: Int, _ list: [Element]? = nil) {
        for e in list ?? elements {
            ctx.saveGState()
            e.draw(ctx, e.state(at: tick))
            ctx.restoreGState()
        }
    }

    func changed(at tick: Int) -> Bool { elements.contains { $0.changes(at: tick) } }
}

// MARK: Drawing helpers

enum Fonts {
    /// Rainmeter's FontSize is in points at 96 DPI: FontSize × 96 / 72 Mac points.
    static func system(_ fontSize: Double, _ weight: NSFont.Weight = .regular) -> CTFont {
        NSFont.systemFont(ofSize: CGFloat(fontSize * 96 / 72), weight: weight) as CTFont
    }
}

enum Align { case left, right, center }

/// A String meter's text in `box`: aligned horizontally, the first line's top at the box's top.
func drawText(_ ctx: CGContext, _ text: String, _ font: CTFont, _ color: RGBA, in box: CGRect, align: Align = .left,
              antialias: Bool = true, kern: CGFloat = 0) {
    var attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color.cg]
    if kern != 0 { attributes[kCTKernAttributeName] = kern }
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString,
                                                                           attributes as CFDictionary))
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let x: CGFloat
    switch align {
    case .left: x = box.minX
    case .right: x = box.maxX - width
    case .center: x = box.midX - width / 2
    }
    ctx.saveGState()
    ctx.setShouldAntialias(antialias)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: box.minY + ascent)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// Shape's LinearGradient geometry (ShapeGradients.linearEndpoints): the line through the center, long enough for
/// the corners to reach 0 and 1; 270° runs top to bottom in a flipped context.
func gradientEndpoints(angle: Double, bounds: CGRect) -> (CGPoint, CGPoint) {
    let rad = angle * .pi / 180
    let dx = cos(rad), dy = sin(rad)
    let half = max((abs(bounds.width * dx) + abs(bounds.height * dy)) / 2, 1e-3)
    let c = CGPoint(x: bounds.midX, y: bounds.midY)
    return (CGPoint(x: c.x + dx * half, y: c.y + dy * half), CGPoint(x: c.x - dx * half, y: c.y - dy * half))
}

func linearGradient(_ c1: RGBA, _ c2: RGBA) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: [c1.cg, c2.cg] as CFArray, locations: [0, 1])!
}

/// Fills `path` with a Shape LinearGradient over `bounds` (clip, then draw, as ShapeCG does).
func fillGradient(_ ctx: CGContext, _ path: CGPath, bounds: CGRect, angle: Double, _ c1: RGBA, _ c2: RGBA,
                  evenOdd: Bool = false) {
    let (start, end) = gradientEndpoints(angle: angle, bounds: bounds)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip(using: evenOdd ? .evenOdd : .winding)
    ctx.drawLinearGradient(linearGradient(c1, c2), start: start, end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Strokes like ShapeCG: the stroke outline is filled.
func strokePath(_ ctx: CGContext, _ path: CGPath, width: CGFloat, _ color: RGBA) {
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    ctx.setFillColor(color.cg)
    ctx.fillPath(using: .winding)
    ctx.restoreGState()
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2),
           transform: nil)
}

/// Deskset's StylePanel: `Rectangle 0.5,0.5,(W-1),(H-1),R | Fill LinearGradient 270 | StrokeWidth 1` plus the
/// highlight line at y = 1.5.
func drawPanel(_ ctx: CGContext, size: CGSize, radius: CGFloat, top: RGBA, bottom: RGBA, angle: Double = 270,
               border: Bool = true) {
    let rect = CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)
    let path = roundedRect(rect, radius)
    fillGradient(ctx, path, bounds: rect, angle: angle, top, bottom)
    guard border else { return }
    strokePath(ctx, path, width: 1, Theme.panelBorder)
    let line = CGMutablePath()
    line.move(to: CGPoint(x: radius, y: 1.5))
    line.addLine(to: CGPoint(x: size.width - radius, y: 1.5))
    strokePath(ctx, line, width: 1, Theme.panelHighlight)
}

/// Draws a CGImage upright into a top-left context (SkinRenderer.drawCGImage).
func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, interpolation: CGInterpolationQuality = .high) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = interpolation
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

/// A deterministic, smooth-ish value in 0…1.
func wave(_ series: Int, _ i: Int) -> Double {
    let x = Double(i)
    let s = Double(series)
    let v = 0.5 + 0.28 * sin(x * 0.37 + s * 1.3) + 0.17 * sin(x * 1.13 + s * 0.7) + 0.05 * sin(x * 3.1 + s)
    return min(max(v, 0.02), 0.98)
}

/// A 32×32 px icon with transparency: an sRGB image like a PNG in @Resources.
let iconImage: CGImage = {
    let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: bgraInfo)!
    let g = CGGradient(colorsSpace: sRGB, colors: [RGBA(255, 196, 80).cg, RGBA(255, 110, 60).cg] as CFArray,
                       locations: [0, 1])!
    ctx.addEllipse(in: CGRect(x: 3, y: 3, width: 26, height: 26))
    ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 32), end: CGPoint(x: 32, y: 0), options: [])
    ctx.resetClip()
    ctx.setStrokeColor(RGBA(255, 255, 255, 120).cg)
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: CGRect(x: 8, y: 8, width: 16, height: 16))
    return ctx.makeImage()!
}()

// MARK: Frame code

/// Frame numbers drawn as cells (white marker, black marker, then `codeBits` bits, white = 1) so a sampler can read
/// back which frame is on screen.
enum FrameCode {
    static let bits = 14
    static let cell: CGFloat = 5

    static func size() -> CGSize { CGSize(width: CGFloat(bits + 2) * cell, height: cell) }

    static func draw(_ ctx: CGContext, _ value: Int, at origin: CGPoint) {
        let cells = [true, false] + (0..<bits).map { (value >> (bits - 1 - $0)) & 1 == 1 }
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        for (i, bit) in cells.enumerated() {
            ctx.setFillColor(CGColor(gray: bit ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: origin.x + CGFloat(i) * cell, y: origin.y, width: cell, height: cell))
        }
        ctx.restoreGState()
    }

    /// The value at `origin` (points) in pixels captured at `scale`, or nil when unreadable.
    static func read(_ p: Pixels, at origin: CGPoint, scale: CGFloat) -> Int? {
        let y = Int((origin.y + cell / 2) * scale)
        func bit(_ i: Int) -> Bool? {
            let x = Int((origin.x + (CGFloat(i) + 0.5) * cell) * scale)
            guard x < p.width, y < p.height else { return nil }
            let o = (y * p.width + x) * 4
            let lum = (Int(p.bytes[o]) + Int(p.bytes[o + 1]) + Int(p.bytes[o + 2])) / 3
            return lum > 170 ? true : lum < 85 ? false : nil
        }
        guard bit(0) == true, bit(1) == false else { return nil }
        var v = 0
        for i in 0..<bits {
            guard let b = bit(2 + i) else { return nil }
            v = v << 1 | (b ? 1 : 0)
        }
        return v
    }
}

// MARK: Widgets

enum Widgets {
    static let title = Fonts.system(11, .semibold)
    static let label = Fonts.system(8, .semibold)
    static let value = Fonts.system(11, .semibold)
    static let small = Fonts.system(9)
    static let tiny = Fonts.system(8)
    static let huge = Fonts.system(54, .light)
    static let big = Fonts.system(22, .medium)
    static let medium = Fonts.system(12)

    /// Like DefaultSkins/Deskset/System (260 × 196 pt), with the extras a real skin has: per-core bars at fractional
    /// x, a pill behind the CPU value, an icon, and a subtitle drawn with AntiAlias=0. About 21 groups.
    /// `frameCode`: two copies of the frame number in groups far apart (for reading frames back).
    static func system(frameCode: Bool = false) -> Widget {
        let W: CGFloat = 260, H: CGFloat = 196, pad: CGFloat = 18, content: CGFloat = 224
        var e: [Element] = []
        e.append(Element("MeterBackground", CGRect(x: 0, y: 0, width: W, height: H), spill: 0, big: true) { ctx, _ in
            drawPanel(ctx, size: CGSize(width: W, height: H), radius: 16, top: Theme.panelTop,
                      bottom: Theme.panelBottom)
        })
        e.append(Element("MeterTitle", CGRect(x: pad, y: 14, width: 56, height: 19)) { ctx, _ in
            drawText(ctx, "System", title, Theme.text, in: CGRect(x: pad, y: 14, width: 56, height: 19))
        })
        e.append(Element("MeterIcon", CGRect(x: 78.25, y: 15.5, width: 14, height: 14), spill: 1) { ctx, _ in
            drawImage(ctx, iconImage, in: CGRect(x: 78.25, y: 15.5, width: 14, height: 14))
        })
        e.append(Element("MeterUptime", CGRect(x: 160, y: 16, width: 82, height: 16), period: 60) { ctx, s in
            drawText(ctx, "Up 3d \(4 + s % 20)h \(12 + s % 48)m", small, Theme.subtle,
                     in: CGRect(x: 160, y: 16, width: 82, height: 16), align: .right)
        })
        e.append(Element("MeterSubtitle", CGRect(x: pad, y: 31.5, width: 110, height: 14), spill: 1) { ctx, _ in
            drawText(ctx, "M4 Pro · 14 cores", tiny, Theme.faint,
                     in: CGRect(x: pad, y: 31.5, width: 110, height: 14), antialias: false)
        })
        e.append(Element("MeterCPULabel", CGRect(x: pad, y: 48, width: 30, height: 14)) { ctx, _ in
            drawText(ctx, "CPU", label, Theme.subtle, in: CGRect(x: pad, y: 48, width: 30, height: 14), kern: 1.07)
        })
        for core in 0..<8 {
            let x = 60.25 + CGFloat(core) * 9.5
            e.append(Element("MeterCore\(core)", CGRect(x: x, y: 47.5, width: 4.3, height: 12), period: 1,
                             spill: 1) { ctx, s in
                let v = wave(10 + core, s)
                let h = 12 * CGFloat(v)
                ctx.setFillColor(Theme.track.cg)
                ctx.addPath(roundedRect(CGRect(x: x, y: 47.5, width: 4.3, height: 12), 1.2))
                ctx.fillPath()
                ctx.setFillColor(Theme.cpu.cg)
                ctx.addPath(roundedRect(CGRect(x: x, y: 59.5 - h, width: 4.3, height: h), 1.2))
                ctx.fillPath()
            })
        }
        e.append(Element("MeterCPUPill", CGRect(x: 196.5, y: 42.3, width: 48.25, height: 19.5), spill: 1) { ctx, _ in
            let path = roundedRect(CGRect(x: 196.5, y: 42.3, width: 48.25, height: 19.5), 9.75)
            ctx.addPath(path)
            ctx.setFillColor(RGBA(255, 255, 255, 20).cg)
            ctx.fillPath()
            strokePath(ctx, path, width: 0.75, RGBA(255, 255, 255, 40))
        })
        e.append(Element("MeterCPUValue", CGRect(x: 198, y: 43, width: 42, height: 19), period: 1) { ctx, s in
            drawText(ctx, "\(Int(wave(1, s) * 100))%", value, Theme.text,
                     in: CGRect(x: 198, y: 43, width: 40, height: 19), align: .right)
        })
        let graph = CGRect(x: pad, y: 66, width: content, height: 40)
        e.append(Element("MeterCPUFill", graph, period: 1, spill: 1) { ctx, s in
            ctx.setFillColor(Theme.cpuFill.cg)
            for i in 0..<112 {
                let v = wave(1, s - 111 + i)
                let h = graph.height * CGFloat(v)
                ctx.fill(CGRect(x: graph.minX + CGFloat(i) * 2, y: graph.maxY - h, width: 2, height: h))
            }
        })
        e.append(Element("MeterCPUGraph", graph, period: 1, spill: 2) { ctx, s in
            let grid = CGMutablePath()
            grid.move(to: CGPoint(x: graph.minX, y: graph.midY + 0.5))
            grid.addLine(to: CGPoint(x: graph.maxX, y: graph.midY + 0.5))
            strokePath(ctx, grid, width: 1, Theme.grid)
            let line = CGMutablePath()
            for i in 0..<112 {
                let p = CGPoint(x: graph.minX + CGFloat(i) * 2 + 1, y: graph.maxY - graph.height * CGFloat(wave(1, s - 111 + i)))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.addPath(line)
            ctx.setStrokeColor(Theme.cpu.cg)
            ctx.setLineWidth(1.5)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        })
        func trackRow(_ name: String, _ y: CGFloat, _ c1: RGBA, _ c2: RGBA, period: Int, series: Int,
                      text: @escaping (Int) -> String) {
            e.append(Element("Meter\(name)Label", CGRect(x: pad, y: y, width: 60, height: 14)) { ctx, _ in
                drawText(ctx, name.uppercased(), label, Theme.subtle, in: CGRect(x: pad, y: y, width: 60, height: 14),
                         kern: 1.07)
            })
            e.append(Element("Meter\(name)Value", CGRect(x: 96, y: y - 5, width: 146, height: 19), period: period) {
                ctx, s in
                drawText(ctx, text(s), value, Theme.text, in: CGRect(x: 96, y: y - 5, width: 146, height: 19),
                         align: .right)
            })
            e.append(Element("Meter\(name)Track", CGRect(x: pad, y: y + 18, width: content, height: 6),
                             period: period) { ctx, s in
                let track = CGRect(x: pad, y: y + 18, width: content, height: 6)
                ctx.addPath(roundedRect(track, 3))
                ctx.setFillColor(Theme.track.cg)
                ctx.fillPath()
                let fill = CGRect(x: pad, y: y + 18, width: max(6, content * CGFloat(wave(series, s))), height: 6)
                fillGradient(ctx, roundedRect(fill, 3), bounds: fill, angle: 180, c1, c2)
            })
        }
        trackRow("Memory", 122, Theme.memory, Theme.memory2, period: 1, series: 2) { s in
            String(format: "%.1f GB / 24.0 GB", 8 + 10 * wave(2, s))
        }
        trackRow("Swap", 156, Theme.swap, Theme.swap2, period: 5, series: 3) { s in
            String(format: "%.2f GB / 2.00 GB", 2 * wave(3, s))
        }
        if frameCode {
            // Two copies of the frame number in groups far apart: they must always agree on screen.
            e.append(Element("MeterCodeA", CGRect(origin: CGPoint(x: 150, y: 35), size: FrameCode.size()), period: 1,
                             spill: 0.5) { ctx, s in FrameCode.draw(ctx, s, at: CGPoint(x: 150, y: 35)) })
            e.append(Element("MeterCodeB", CGRect(origin: CGPoint(x: 150, y: 186), size: FrameCode.size()), period: 1,
                             spill: 0.5) { ctx, s in FrameCode.draw(ctx, s, at: CGPoint(x: 150, y: 186)) })
        }
        return Widget("system", CGSize(width: W, height: H), e)
    }

    /// A 360 pt design skin (clock, date, a day-progress ring, weather with an icon, a translucent card).
    static func design() -> Widget {
        let S: CGFloat = 360
        var e: [Element] = []
        e.append(Element("MeterBackground", CGRect(x: 0, y: 0, width: S, height: S), spill: 0, big: true) { ctx, _ in
            drawPanel(ctx, size: CGSize(width: S, height: S), radius: 28, top: Theme.faceTop, bottom: Theme.faceBottom)
        })
        e.append(Element("MeterTime", CGRect(x: 36, y: 40, width: 250, height: 76), period: 60) { ctx, s in
            drawText(ctx, String(format: "%d:%02d", 10 + s / 60 % 12, s % 60), huge, Theme.text,
                     in: CGRect(x: 36, y: 40, width: 250, height: 76))
        })
        e.append(Element("MeterSeconds", CGRect(x: 292, y: 52, width: 46, height: 38), period: 1) { ctx, s in
            drawText(ctx, String(format: "%02d", s % 60), big, Theme.accent,
                     in: CGRect(x: 292, y: 52, width: 46, height: 38))
        })
        e.append(Element("MeterDate", CGRect(x: 36, y: 126, width: 288, height: 20)) { ctx, _ in
            drawText(ctx, "Sunday, September 27", medium, Theme.subtle, in: CGRect(x: 36, y: 126, width: 288, height: 20))
        })
        let ringCenter = CGPoint(x: 239.4, y: 247.6), radius: CGFloat = 52.3
        e.append(Element("MeterRing", CGRect(x: ringCenter.x - radius - 6, y: ringCenter.y - radius - 6,
                                            width: 2 * radius + 12, height: 2 * radius + 12), period: 1) { ctx, s in
            let track = CGMutablePath()
            track.addArc(center: ringCenter, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            strokePath(ctx, track, width: 9, Theme.track)
            let arc = CGMutablePath()
            let sweep = 2 * Double.pi * (0.35 + 0.6 * wave(4, s))
            arc.addArc(center: ringCenter, radius: radius, startAngle: -.pi / 2, endAngle: CGFloat(-.pi / 2 + sweep),
                       clockwise: false)
            let outline = arc.copy(strokingWithWidth: 9, lineCap: .round, lineJoin: .round, miterLimit: 10)
            let box = outline.boundingBox
            fillGradient(ctx, outline, bounds: box, angle: 135, Theme.cpu, Theme.cpu2)
        })
        e.append(Element("MeterRingText", CGRect(x: ringCenter.x - 30, y: ringCenter.y - 11, width: 60, height: 22),
                         period: 1) { ctx, s in
            drawText(ctx, "\(Int((0.35 + 0.6 * wave(4, s)) * 100))%", value, Theme.text,
                     in: CGRect(x: ringCenter.x - 30, y: ringCenter.y - 11, width: 60, height: 22), align: .center)
        })
        e.append(Element("MeterWeatherIcon", CGRect(x: 40.5, y: 186.25, width: 44, height: 44), spill: 1) { ctx, _ in
            drawImage(ctx, iconImage, in: CGRect(x: 40.5, y: 186.25, width: 44, height: 44))
        })
        e.append(Element("MeterTemperature", CGRect(x: 94, y: 190, width: 80, height: 36), period: 30) { ctx, s in
            drawText(ctx, "\(12 + s % 9)°", big, Theme.text, in: CGRect(x: 94, y: 190, width: 80, height: 36))
        })
        e.append(Element("MeterHighLow", CGRect(x: 40, y: 240, width: 120, height: 16), spill: 1) { ctx, _ in
            drawText(ctx, "H 21°  L 12°", small, Theme.subtle, in: CGRect(x: 40, y: 240, width: 120, height: 16),
                     antialias: false)
        })
        e.append(Element("MeterCard", CGRect(x: 36.5, y: 272.25, width: 124.5, height: 54.5), period: 10) { ctx, s in
            let card = CGRect(x: 36.5, y: 272.25, width: 124.5, height: 54.5)
            ctx.addPath(roundedRect(card, 12))
            ctx.setFillColor(RGBA(255, 255, 255, 22).cg)
            ctx.fillPath()
            strokePath(ctx, roundedRect(card, 12), width: 0.75, RGBA(255, 255, 255, 36))
            drawText(ctx, "UV \(2 + s % 5)  ·  Wind \(8 + s % 7) km/h", tiny, Theme.subtle,
                     in: CGRect(x: 48, y: 283, width: 110, height: 14))
            drawText(ctx, "Rain later", small, Theme.text, in: CGRect(x: 48, y: 300, width: 110, height: 16))
        })
        return Widget("design", CGSize(width: S, height: S), e)
    }

    /// A 60 Hz audio visualizer: 32 bars at fractional x, a title, and the frame number (for reading back frames).
    static func visualizer() -> Widget {
        let W: CGFloat = 260, H: CGFloat = 120
        var e: [Element] = []
        e.append(Element("MeterBackground", CGRect(x: 0, y: 0, width: W, height: H), spill: 0, big: true) { ctx, _ in
            drawPanel(ctx, size: CGSize(width: W, height: H), radius: 16, top: Theme.panelTop,
                      bottom: Theme.panelBottom)
        })
        e.append(Element("MeterTitle", CGRect(x: 18, y: 12, width: 120, height: 19)) { ctx, _ in
            drawText(ctx, "Now Playing", title, Theme.text, in: CGRect(x: 18, y: 12, width: 120, height: 19))
        })
        for i in 0..<32 {
            let x = 14.5 + CGFloat(i) * 7.2
            e.append(Element("MeterBar\(i)", CGRect(x: x, y: 38, width: 4.6, height: 60), period: 1, spill: 1) {
                ctx, s in
                let h = 60 * CGFloat(wave(20 + i % 7, s + i * 3))
                let bar = CGRect(x: x, y: 98 - h, width: 4.6, height: h)
                fillGradient(ctx, roundedRect(bar, 2.3), bounds: bar, angle: 270, Theme.cpu2, Theme.cpu)
            })
        }
        e.append(Element("MeterCode", CGRect(origin: CGPoint(x: 18, y: 106), size: FrameCode.size()), period: 1,
                         spill: 0.5) { ctx, s in FrameCode.draw(ctx, s, at: CGPoint(x: 18, y: 106)) })
        return Widget("visualizer", CGSize(width: W, height: H), e)
    }
}

// MARK: Offline drawing (the `--render`-like reference: sRGB, 8-bit, premultiplied)

/// A BGRA premultiplied bitmap context `size` × `scale` pixels in `space`, set up for top-left drawing in points.
func bitmapContext(_ size: CGSize, scale: CGFloat, space: CGColorSpace = sRGB) -> CGContext {
    let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: bgraInfo)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    return ctx
}

func renderWidget(_ w: Widget, tick: Int, scale: CGFloat, _ list: [Element]? = nil) -> CGImage {
    let ctx = bitmapContext(w.size, scale: scale)
    w.draw(ctx, tick: tick, list)
    return ctx.makeImage()!
}
