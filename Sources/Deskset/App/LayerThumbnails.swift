import AppKit
import DesksetCore

/// The small pictures of the layer list (docs/editor-friendly.md §5.2 "Row anatomy"): each layer's real pixels, drawn
/// by the real renderer (`SkinRenderer.drawMeter`), cropped to the layer and scaled to fit a 36 × 26 point tile at 2x,
/// on the widget's own panel color (the Background's fill, else the canvas backdrop) so light text on a dark widget
/// reads as it does on the desktop. A layer thinner or flatter than 6 points (a 2-point marker, a hairline) would be a
/// speck: it gets a symbol of its kind in its own color instead.
///
/// Thumbnails are cached per layer with a signature of what they show (frame, visibility, values, text, colors, the
/// loaded skin): a row asks again on every refresh, and only a layer that changed is drawn again — at most once per
/// pass (`beginPass`), which the sidebar starts once per live tick, and only for rows on screen. The whole widget's
/// picture follows each update of the widget (still at most once per pass).
///
/// A hidden layer has no size (Hidden sets W and H to 0), so it has nothing to draw: its row keeps the picture the
/// layer had while it was shown (the row dims it), else shows its kind's symbol in its own color.
final class LayerThumbnails {
    /// Tile size in points (the row's picture).
    static let size = NSSize(width: 36, height: 26)
    /// Layers thinner or flatter than this (points) show a symbol.
    static let minimumSide = 6.0

    struct Entry {
        var image: NSImage
        var signature: String
    }

    private var cache: [String: Entry] = [:]
    /// The last picture of each layer (or run) while it was shown, kept across reloads of the widget.
    private var shown: [String: NSImage] = [:]
    /// Keys drawn since `beginPass` (each is drawn at most once per pass).
    private var drawnThisPass: Set<String> = []
    /// How many tiles were drawn (self-tests).
    private(set) var renderCount = 0
    /// How many tiles were drawn in the current pass (self-tests).
    var rendersThisPass: Int { drawnThisPass.count }

    /// Starts a pass: every tile may be drawn once more if what it shows changed.
    func beginPass() {
        drawnThisPass = []
    }

    /// Forgets every picture of the loaded skin (another skin was loaded).
    func removeAll() {
        cache = [:]
        drawnThisPass = []
    }

    /// Forgets the pictures kept for hidden layers (another widget).
    func forgetShown() {
        shown = [:]
    }

    /// The tile for `meters` (one layer, or the members of a run) under `key`: cached while their signature holds.
    /// In a pass, a tile drawn once is not drawn again (the cached one is answered even if it is stale).
    func thumbnail(key: String, meters: [Meter], in skin: Skin, panel: NSColor, dark: Bool) -> NSImage? {
        let visible = meters.filter { !$0.hidden }
        if visible.isEmpty, let last = shown[key] { return last }
        let signature = Self.signature(of: meters, in: skin, panel: panel, dark: dark)
        if let entry = cache[key], entry.signature == signature || drawnThisPass.contains(key) { return entry.image }
        let image = visible.isEmpty ? Self.glyph(for: meters.first, panel: panel) : Self.render(visible, panel: panel)
        guard let image else { return nil }
        cache[key] = Entry(image: image, signature: signature)
        if !visible.isEmpty, visible.count == meters.count { shown[key] = image }
        drawnThisPass.insert(key)
        renderCount += 1
        return image
    }

    /// The whole widget, scaled to fit the tile.
    func widgetThumbnail(of skin: Skin, panel: NSColor, dark: Bool) -> NSImage? {
        let key = "\u{1F}widget"
        let signature = "\(ObjectIdentifier(skin).hashValue)|\(skin.width)x\(skin.height)|\(skin.updateCount)|\(dark)|\(panel)"
        if let entry = cache[key], entry.signature == signature || drawnThisPass.contains(key) { return entry.image }
        let area = SkinRect(x: 0, y: 0, width: skin.width, height: skin.height)
        guard let image = Self.draw(area: area, panel: panel, { cg in SkinRenderer.draw(skin, in: cg) }) else { return nil }
        cache[key] = Entry(image: image, signature: signature)
        drawnThisPass.insert(key)
        renderCount += 1
        return image
    }

    /// Whether a layer is too thin or flat to show as pixels.
    static func usesGlyph(_ meters: [Meter]) -> Bool {
        guard let area = bounds(of: meters.filter { !$0.hidden }) else { return true }
        return area.width < minimumSide || area.height < minimumSide
    }

    /// Options that color a layer (`!SetOption` often changes them from an `IfTrueAction`).
    static let colorKeys = ["SolidColor", "SolidColor2", "GradientAngle", "BarColor", "FontColor", "FontEffectColor",
                            "StringEffect", "LineColor", "PrimaryColor", "SecondaryColor", "BothColor", "ImageTint",
                            "ImageAlpha", "Greyscale", "ImageName"]

    /// What a tile shows: the skin loaded now, the frames, values, texts and colors of the layers, and the colors
    /// around them.
    static func signature(of meters: [Meter], in skin: Skin, panel: NSColor, dark: Bool) -> String {
        var parts = ["\(ObjectIdentifier(skin).hashValue)", panel.description, dark ? "dark" : "light"]
        for m in meters {
            let f = m.frame
            var part = "\(m.name)|\(m.hidden)|\(f.x),\(f.y),\(f.width),\(f.height)"
            for measure in m.measures { part += "|\(measure.value)|\(measure.rawString ?? "")" }
            // The picture drawn, which follows a measure read on demand (a NowPlaying cover) at the meter's update.
            if let image = m as? ImageMeter { part += "|\(image.imagePath ?? "")" }
            // Colors as written (a `!SetOption`) and as resolved (a `!SetVariable` behind a `#Variable#`).
            for key in colorKeys { if let value = m.rawOption(key) { part += "|\(key)=\(value)" } }
            part += "|\(m.solidColor)|\(m.solidColor2.map { "\($0)" } ?? "")"
            if let bar = m as? BarMeter { part += "|\(bar.barColor)" }
            if let text = m as? StringMeter { part += "|" + text.text + "|\(text.style.color)" }
            if let shape = m as? ShapeMeter { part += "|\(shape.revision)" }
            parts.append(part)
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// Union of the frames of visible meters with an area.
    static func bounds(of meters: [Meter]) -> SkinRect? {
        let frames = meters.map(\.frame).filter { $0.width > 0 && $0.height > 0 && $0.x.isFinite && $0.y.isFinite }
        guard let first = frames.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for f in frames.dropFirst() {
            minX = min(minX, f.x)
            minY = min(minY, f.y)
            maxX = max(maxX, f.maxX)
            maxY = max(maxY, f.maxY)
        }
        return SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The layers' pixels on the panel color, or their kind's symbol when they are too small to see.
    static func render(_ meters: [Meter], panel: NSColor) -> NSImage? {
        guard let area = bounds(of: meters), area.width >= minimumSide, area.height >= minimumSide else {
            return glyph(for: meters.first, panel: panel)
        }
        return draw(area: area, panel: panel) { cg in
            for m in meters { SkinRenderer.drawMeter(m, cg) }
        }
    }

    /// A tile with `area` of the skin scaled to fit (never enlarged more than 4 times), centered on the panel color.
    static func draw(area: SkinRect, panel: NSColor, _ body: (CGContext) -> Void) -> NSImage? {
        let scale: CGFloat = 2, inset: CGFloat = 3
        let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)
        guard area.width > 0, area.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let cg = context.cgContext
        cg.setFillColor(panel.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        let fit = min((size.width - 2 * inset) / CGFloat(area.width), (size.height - 2 * inset) / CGFloat(area.height), 4)
        let drawn = CGSize(width: CGFloat(area.width) * fit, height: CGFloat(area.height) * fit)
        // Rainmeter's top-left origin, the backing scale, then the area centered in the tile.
        cg.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
        cg.scaleBy(x: fit, y: fit)
        cg.translateBy(x: -CGFloat(area.x), y: -CGFloat(area.y))
        cg.clip(to: area.cgRect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        body(cg)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The kind's symbol in the layer's own color (its fill, bar or text color), on the panel color.
    static func glyph(for meter: Meter?, panel: NSColor) -> NSImage? {
        var symbol = meter.map { LayerNaming.symbol(forMeterType: $0.type) } ?? "square.dashed"
        if let meter, LayerNaming.kindNoun(meter) == "Color block" { symbol = "rectangle.portrait.fill" }
        return symbolTile(symbol, color: meter.flatMap(ownColor) ?? .secondaryLabelColor, background: panel)
    }

    /// A tile with a symbol in `color` on `background`.
    static func symbolTile(_ symbol: String, color: NSColor, background: NSColor, size: NSSize = size) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            background.setFill()
            rect.fill()
            let s = base.size
            base.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            return true
        }
    }

    /// The color a layer is drawn in, as far as one color says it (opaque, so the symbol is visible).
    static func ownColor(_ m: Meter) -> NSColor? {
        var c: RGBA?
        switch m {
        case let bar as BarMeter: c = bar.barColor
        case let text as StringMeter: c = text.style.color
        case let shape as ShapeMeter: c = shape.shapes.lazy.compactMap { paintColor($0.fill) ?? paintColor($0.stroke) }.first
        default: c = m.solidColor.a > 0 ? m.solidColor : nil
        }
        guard let c else { return nil }
        return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
    }

    /// One color for a shape's paint: the color, or the average of a gradient's stops; nil when nothing is painted.
    static func paintColor(_ paint: ShapePaint) -> RGBA? {
        func average(_ stops: [ShapeGradientStop]) -> RGBA? {
            guard !stops.isEmpty else { return nil }
            let n = Double(stops.count)
            return RGBA(r: stops.map(\.color.r).reduce(0, +) / n, g: stops.map(\.color.g).reduce(0, +) / n,
                        b: stops.map(\.color.b).reduce(0, +) / n, a: stops.map(\.color.a).reduce(0, +) / n)
        }
        guard paint.isVisible else { return nil }
        switch paint {
        case .none: return nil
        case .color(let c): return c
        case .linearGradient(let g): return average(g.stops)
        case .radialGradient(let g): return average(g.stops)
        }
    }

    /// The canvas backdrop's color (what shows through a transparent widget).
    static func backdropColor(_ backdrop: SkinCanvasView.Backdrop, dark: Bool) -> NSColor {
        switch backdrop {
        case .dark: return NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
        case .light: return NSColor(srgbRed: 0.98, green: 0.975, blue: 0.965, alpha: 1)
        case .checkerboard: return NSColor(white: dark ? 0.19 : 1, alpha: 1)
        }
    }

    /// The widget's panel color: the Background layer's fill (over the backdrop when it lets it through), else the
    /// canvas backdrop.
    static func panelColor(of skin: Skin, background: String?, backdrop: SkinCanvasView.Backdrop, dark: Bool) -> NSColor {
        let base = backdropColor(backdrop, dark: dark)
        guard let c = ownPanelColor(of: skin, background: background), let b = base.usingColorSpace(.sRGB) else { return base }
        let a = c.a / 255
        return NSColor(srgbRed: c.r / 255 * a + b.redComponent * (1 - a), green: c.g / 255 * a + b.greenComponent * (1 - a),
                       blue: c.b / 255 * a + b.blueComponent * (1 - a), alpha: 1)
    }

    /// The widget's own panel color, as written (it may let the backdrop through): its Background layer's fill, else
    /// its whole-widget background (`widgetBackgroundColor`); nil for a see-through widget.
    static func ownPanelColor(of skin: Skin, background: String?) -> RGBA? {
        var fill: RGBA?
        if let name = background, let m = skin.meter(named: name) {
            if let shape = m as? ShapeMeter { fill = shape.shapes.lazy.compactMap { paintColor($0.fill) }.first }
            if fill == nil, m.solidColor.a > 0 { fill = m.solidColor }
        }
        // No Background layer: the widget's own background (a whole-widget color or picture) is its panel.
        return fill ?? widgetBackgroundColor(skin)
    }

    /// Whether most of what a widget draws is light (white words, pale bars): such a widget needs a dark ground to be
    /// seen where nothing of its own is behind it.
    static func contentIsLight(_ skin: Skin, except background: String?) -> Bool {
        var total = 0.0, count = 0.0
        for m in skin.meters where !m.hidden && !m.isContainer && m.name.caseInsensitiveCompare(background ?? "") != .orderedSame {
            guard let c = ownColor(m)?.usingColorSpace(.sRGB) else { continue }
            total += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            count += 1
        }
        return count > 0 && total / count > 0.6
    }

    /// The color of the widget's own background (`[Rainmeter] BackgroundMode`): 2's SolidColor (halfway to SolidColor2
    /// when it fades), the average color of 0, 3 and 4's picture; nil for none (1, transparent).
    static func widgetBackgroundColor(_ skin: Skin) -> RGBA? {
        let s = skin.settings
        switch s.backgroundMode {
        case 2:
            guard let c2 = s.solidColor2 else { return s.solidColor.a > 0 ? s.solidColor : nil }
            let c = s.solidColor
            let mixed = RGBA(r: (c.r + c2.r) / 2, g: (c.g + c2.g) / 2, b: (c.b + c2.b) / 2, a: (c.a + c2.a) / 2)
            return mixed.a > 0 ? mixed : nil
        case 0, 3, 4:
            guard let path = s.backgroundImage else { return nil }
            if let cached = averageCache.object(forKey: path as NSString) { return cached.color }
            guard let image = PreparedImage(path: path, options: s.backgroundImageOptions)?.flattened(),
                  let color = averageColor(image) else { return nil }
            averageCache.setObject(AverageColor(color), forKey: path as NSString)
            return color
        default:
            return nil
        }
    }

    private final class AverageColor {
        let color: RGBA
        init(_ color: RGBA) { self.color = color }
    }

    private static let averageCache = NSCache<NSString, AverageColor>()

    /// A picture's average color (drawn into one pixel).
    static func averageColor(_ image: CGImage) -> RGBA? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let a = Double(pixel[3])
        guard a > 0 else { return nil }
        // Premultiplied: undo it for the color.
        return RGBA(r: Double(pixel[0]) * 255 / a, g: Double(pixel[1]) * 255 / a, b: Double(pixel[2]) * 255 / a, a: a)
    }
}
