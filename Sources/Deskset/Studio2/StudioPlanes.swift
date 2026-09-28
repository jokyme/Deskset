import AppKit
import DesksetCore

// The planes under the widget's drawing on the Studio's canvas, back to front: the backdrop (`StudioBackdropView`),
// the other widgets on the desktop (`StudioNeighboursView`), the widget's glass (`StudioGlassPlane`); the canvas
// (`SkinCanvasView`) draws the widget itself over them, and the capsules float on top.

/// The widget's glass on the canvas: real glass views on screen, sampling the backdrop under them (the same views as
/// on the desktop, `SkinGlassViews`), at the canvas's zoom; stand-ins where no window server draws them.
final class StudioGlassPlane: NSView {
    let usesStandIns: Bool
    private let glass = SkinGlassViews()
    /// A marker the glass views stay behind (`SkinGlassViews` keeps one view in front of them).
    private let front = NSView()

    /// The widget's glass (skin coordinates), as the preview shows it.
    var regions: [GlassRegion] = [] { didSet { if regions != oldValue { update() } } }
    /// Where the widget's card is in this view, and the zoom.
    var cardRect = CGRect.zero { didSet { if cardRect != oldValue { update() } } }
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { update() } } }
    /// The stand-ins' look: over a dark backdrop or a light one.
    var darkBackdrop = false { didSet { if darkBackdrop != oldValue { needsDisplay = true } } }

    init(standIns: Bool) {
        usesStandIns = standIns
        super.init(frame: .zero)
        wantsLayer = true
        if !standIns { addSubview(front) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The regions in this view's coordinates.
    var placedRegions: [GlassRegion] {
        regions.map { region in
            var r = region
            func place(_ rect: SkinRect) -> SkinRect {
                SkinRect(x: Double(cardRect.minX) + rect.x * Double(zoom), y: Double(cardRect.minY) + rect.y * Double(zoom),
                         width: rect.width * Double(zoom), height: rect.height * Double(zoom))
            }
            r.rect = place(region.rect)
            r.clip = region.clip.map(place)
            r.cornerRadius = region.cornerRadius * Double(zoom)
            return r
        }
    }

    private func update() {
        if usesStandIns {
            needsDisplay = true
        } else {
            glass.apply(placedRegions, in: self, below: front)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesStandIns, let ctx = NSGraphicsContext.current?.cgContext else { return }
        GlassPlaceholder.draw(placedRegions, in: ctx, dark: darkBackdrop)
    }
}

/// Another widget on the desktop, as the Studio draws it around this one: where it is, and its picture.
struct StudioNeighbour {
    /// Its window's frame (global coordinates, y up).
    var frame: CGRect
    /// What its window shows now (nil: the window's picture cannot be read without drawing it again; an outline
    /// stands in).
    var image: CGImage?
    /// Where its glass is (window coordinates from the top-left corner, points), drawn as stand-ins under the picture.
    var glass: [CGRect] = []
}

enum StudioNeighbourCapture {
    /// What `window` shows now, from its layers' contents: the pictures its layers hold (a skin's frames once they are
    /// drawn on the skin's own thread) — never by drawing the widget again (another widget's skin is not read or run
    /// from here). The glass pieces' places are taken from the window's glass views.
    static func capture(_ window: NSWindow) -> StudioNeighbour {
        var neighbour = StudioNeighbour(frame: window.frame, image: nil)
        guard let content = window.contentView else { return neighbour }
        neighbour.glass = content.subviews.filter { $0 is SkinGlassFrameView }.map { view in
            let r = view.convert(view.bounds, to: content)
            return content.isFlipped ? r : CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width,
                                                  height: r.height)
        }
        guard let root = content.layer else { return neighbour }
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
        let size = content.bounds.size
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, w < 20_000, h < 20_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return neighbour }
        ctx.scaleBy(x: scale, y: scale)
        var drew = false
        func walk(_ layer: CALayer) {
            if !layer.isHidden, let contents = layer.contents {
                let cf = contents as CFTypeRef
                if CFGetTypeID(cf) == CGImage.typeID {
                    let image = cf as! CGImage
                    // The layer's frame in the root layer, then from the bottom (the bitmap's y axis points up);
                    // the picture is drawn upright, as the window shows it.
                    var frame = layer.convert(layer.bounds, to: root)
                    if root.isGeometryFlipped || content.isFlipped {
                        frame.origin.y = root.bounds.height - frame.maxY
                    }
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(layer.opacity))
                    ctx.draw(image, in: frame)
                    ctx.restoreGState()
                    drew = true
                }
            }
            for sub in layer.sublayers ?? [] { walk(sub) }
        }
        walk(root)
        if drew { neighbour.image = ctx.makeImage() }
        return neighbour
    }
}

/// The other widgets on the desktop around this one: clear at 100 %, where the canvas lines up with the desktop;
/// faded and without color at any other zoom (they are not to scale with anything there).
final class StudioNeighboursView: NSView {
    var neighbours: [StudioNeighbour] = [] { didSet { grayCache = [:]; needsDisplay = true } }
    var mapping: DesktopMapping? { didSet { if mapping != oldValue { needsDisplay = true } } }
    var darkBackdrop = false
    private var grayCache: [Int: CGImage] = [:]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether they are drawn faded (not at 100 %).
    var isFaded: Bool { abs((mapping?.zoom ?? 1) - 1) > 0.001 }

    override func draw(_ dirtyRect: NSRect) {
        guard let mapping, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let faded = isFaded
        for (i, n) in neighbours.enumerated() {
            let rect = mapping.viewRect(forScreenRect: n.frame)
            guard rect.intersects(bounds) else { continue }
            ctx.saveGState()
            ctx.setAlpha(faded ? 0.42 : 1)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let z = mapping.zoom
            for g in n.glass {
                let r = CGRect(x: rect.minX + g.minX * z, y: rect.minY + g.minY * z, width: g.width * z,
                               height: g.height * z)
                let region = GlassRegion(id: "n\(i)", rect: SkinRect(x: r.minX, y: r.minY, width: r.width,
                                                                     height: r.height),
                                         cornerRadius: Double(min(r.width, r.height) * 0.12))
                GlassPlaceholder.draw(region, in: ctx, dark: darkBackdrop)
            }
            if let image = faded ? gray(i, n.image) : n.image {
                ctx.saveGState()
                ctx.interpolationQuality = faded ? .medium : .high
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            } else if n.glass.isEmpty {
                let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10 * z, cornerHeight: 10 * z,
                                  transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: darkBackdrop ? 1 : 1, alpha: darkBackdrop ? 0.10 : 0.30))
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(CGColor(gray: darkBackdrop ? 1 : 0, alpha: 0.25))
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    /// `image` without color (kept per neighbour).
    private func gray(_ index: Int, _ image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        if let cached = grayCache[index] { return cached }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: rect)
        // Keep the alpha, drop the color: the picture's luminosity over a mid gray.
        ctx.setBlendMode(.color)
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(rect)
        ctx.setBlendMode(.destinationIn)
        ctx.draw(image, in: rect)
        let result = ctx.makeImage() ?? image
        grayCache[index] = result
        return result
    }
}
