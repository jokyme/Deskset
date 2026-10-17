import AppKit
import DesksetCore

/// The Studio's preview canvas: draws the skin using `SkinRenderer` inside a magnifying scroll view.
final class SkinCanvasView: NSView {
    enum Backdrop: Int, CaseIterable {
        case checkerboard, dark, light
    }

    static let margin: CGFloat = 64
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 16
    static let gridZoom: CGFloat = 8
    static let ghostAlpha: CGFloat = 0.35
    static let emptyCardSize = CGSize(width: 240, height: 150)
    static let overflowReach: Double = 2000

    /// The skin to draw (looked up on every draw).
    var skinProvider: () -> Skin? = { nil }
    private(set) var selectedNames: [String] = []
    var backdrop = Backdrop.checkerboard { didSet { needsDisplay = true } }
    var paintsSurface = true { didSet { needsDisplay = true } }
    var glassDrawing: SkinRenderer.GlassDrawing? { didSet { needsDisplay = true } }
    var isEditable = false
    var drawsPartFocusRing = false
    var showsContentOutside = true {
        didSet {
            guard showsContentOutside != oldValue else { return }
            updateSize()
            needsDisplay = true
        }
    }

    var onZoom: ((CGFloat) -> Void)?
    var onUserZoom: (() -> Void)?
    var onLayoutChange: (() -> Void)?

    private(set) var origin = NSPoint(x: margin, y: margin)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var skin: Skin? { skinProvider() }

    var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    var cardSize: CGSize {
        guard let skin else { return .zero }
        var width = skin.width, height = skin.height
        if skin.meters.isEmpty {
            width = max(width, Double(Self.emptyCardSize.width))
            height = max(height, Double(Self.emptyCardSize.height))
        }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    var skinRect: CGRect {
        guard skin != nil else { return .zero }
        return CGRect(origin: origin, size: cardSize)
    }

    private var extent: CGRect {
        let card = cardSize
        var r = CGRect(origin: .zero, size: card)
        if showsContentOutside, let skin, !skin.meters.isEmpty {
            let b = skin.contentBounds()
            let reach = Self.overflowReach
            let minX = max(b.x, -reach), minY = max(b.y, -reach)
            let maxX = min(b.maxX, Double(card.width) + reach), maxY = min(b.maxY, Double(card.height) + reach)
            r = r.union(CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0)))
        }
        return r
    }

    func updateSize() {
        let e = extent
        let old = origin
        origin = NSPoint(x: Self.margin - min(e.minX, 0), y: Self.margin - min(e.minY, 0))
        let size = NSSize(width: ceil(origin.x + max(e.maxX, 1) + Self.margin),
                          height: ceil(origin.y + max(e.maxY, 1) + Self.margin))
        let resized = frame.size != size
        if resized { setFrameSize(size) }
        if origin != old, let clip = enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: clip.bounds.minX + origin.x - old.x, y: clip.bounds.minY + origin.y - old.y))
            enclosingScrollView?.reflectScrolledClipView(clip)
            needsDisplay = true
        }
        if resized || origin != old { onLayoutChange?() }
    }

    func setSelection(_ name: String?, reveal: Bool = false) {
        selectedNames = name.map { [$0] } ?? []
    }

    func setSelection(names: [String], reveal: Bool = false) {
        selectedNames = names
    }

    func viewRect(_ f: SkinRect) -> CGRect {
        let r = CGRect(x: f.x + origin.x, y: f.y + origin.y, width: f.width, height: f.height)
        return r.width > 0 && r.height > 0 ? r : r.insetBy(dx: -2, dy: -2)
    }

    // MARK: Zoom

    func setZoom(_ value: CGFloat, centeredAt point: NSPoint? = nil) {
        guard let scroll = enclosingScrollView else { return }
        let z = min(max(value, Self.minZoom), Self.maxZoom)
        let center = point ?? NSPoint(x: visibleRect.midX, y: visibleRect.midY)
        scroll.setMagnification(z, centeredAt: center)
        onZoom?(scroll.magnification)
        needsDisplay = true
    }

    func zoomIn() { setZoom(Self.steps.first { $0 > zoom + 0.001 } ?? Self.maxZoom) }
    func zoomOut() { setZoom(Self.steps.last { $0 < zoom - 0.001 } ?? Self.minZoom) }
    static let steps: [CGFloat] = [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16]

    func fitZoom(limit: CGFloat = 4) -> CGFloat {
        guard let scroll = enclosingScrollView else { return 1 }
        let available = scroll.contentSize
        let e = extent
        let needed = NSSize(width: e.width + 2 * Self.margin, height: e.height + 2 * Self.margin)
        guard needed.width > 0, needed.height > 0 else { return 1 }
        let z = min(available.width / needed.width, available.height / needed.height, limit)
        return min(max(z, Self.minZoom), Self.maxZoom)
    }

    func zoomToFit() {
        let z = fitZoom()
        if abs(z - zoom) < 0.000_1, let clip = enclosingScrollView?.contentView,
           clip.bounds.width >= frame.width - 0.5, clip.bounds.height >= frame.height - 0.5 {
            let placed = clip.constrainBoundsRect(clip.bounds).origin, at = clip.bounds.origin
            let pixels = max(zoom, 0.01) * (window?.backingScaleFactor ?? 2)
            func whole(_ v: CGFloat) -> Bool { abs(v * pixels - (v * pixels).rounded()) < 0.01 }
            if abs(placed.x - at.x) * pixels <= 0.51, abs(placed.y - at.y) * pixels <= 0.51, whole(at.x), whole(at.y) {
                return
            }
        }
        setZoom(z, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad]) == .command,
              window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "=", "+": onUserZoom?(); zoomIn()
        case "-": onUserZoom?(); zoomOut()
        case "0": onUserZoom?(); setZoom(1)
        case "9": zoomToFit()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        onUserZoom?()
        setZoom(zoom * (1 + delta), centeredAt: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onUserZoom?()
        onZoom?(zoom)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let z = max(zoom, 0.01)
        if paintsSurface { drawSurface(dirtyRect, zoom: z, ctx) }
        guard let skin else { return }
        let rect = skinRect
        if paintsSurface { drawBackdrop(rect, zoom: z, ctx) }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: origin.x, y: origin.y)
        SkinRenderer.draw(skin, in: ctx, glass: glassDrawing ?? .placeholder(dark: backdropIsDark))
        ctx.restoreGState()
        drawOutside(skin, card: rect, ctx)
        if z >= Self.gridZoom { drawGrid(rect, dirty: dirtyRect, zoom: z, ctx) }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func drawSurface(_ dirty: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        ctx.setFillColor(isDark ? CGColor(red: 0.105, green: 0.105, blue: 0.115, alpha: 1)
                                : CGColor(red: 0.953, green: 0.949, blue: 0.941, alpha: 1))
        ctx.fill(dirty)
    }

    private var backdropIsDark: Bool {
        switch backdrop {
        case .dark: return true
        case .light: return false
        case .checkerboard: return isDark
        }
    }

    private func drawBackdrop(_ rect: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8 / zoom), blur: 28 / zoom,
                      color: CGColor(gray: 0, alpha: isDark ? 0.55 : 0.18))
        ctx.setFillColor(CGColor(gray: isDark ? 0.16 : 1, alpha: 1))
        ctx.fill(rect)
        ctx.restoreGState()
    }

    private func hasContentOutside(_ skin: Skin, card: CGSize) -> Bool {
        guard !skin.meters.isEmpty else { return false }
        let b = skin.contentBounds()
        return b.x < 0 || b.y < 0 || b.maxX > Double(card.width) || b.maxY > Double(card.height)
    }

    private func drawOutside(_ skin: Skin, card: CGRect, _ ctx: CGContext) {
        guard showsContentOutside, hasContentOutside(skin, card: card.size) else { return }
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addRect(card)
        ctx.clip(using: .evenOdd)
        ctx.setAlpha(Self.ghostAlpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.translateBy(x: origin.x, y: origin.y)
        SkinRenderer.draw(skin, in: ctx, glass: .placeholder(dark: backdropIsDark))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawGrid(_ rect: CGRect, dirty: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        let clip = rect.intersection(dirty)
        guard !clip.isNull else { return }
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.22))
        ctx.setLineWidth(1 / zoom)
        var x = ceil(clip.minX - origin.x) + origin.x
        while x <= clip.maxX {
            ctx.move(to: CGPoint(x: x, y: clip.minY))
            ctx.addLine(to: CGPoint(x: x, y: clip.maxY))
            x += 1
        }
        var y = ceil(clip.minY - origin.y) + origin.y
        while y <= clip.maxY {
            ctx.move(to: CGPoint(x: clip.minX, y: y))
            ctx.addLine(to: CGPoint(x: clip.maxX, y: y))
            y += 1
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// Keeps a document smaller than the visible area centered (NSClipView pins it to the top-left otherwise).
final class CenteringClipView: NSClipView {
    var holdsDocument = false {
        didSet {
            guard oldValue, !holdsDocument else { return }
            scroll(to: bounds.origin)
            enclosingScrollView?.reflectScrolledClipView(self)
        }
    }

    var verticalBias: CGFloat = 0

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let size = document.frame.size
        if rect.width > size.width { rect.origin.x = holdsDocument ? proposedBounds.minX : (size.width - rect.width) / 2 }
        if rect.height > size.height {
            rect.origin.y = holdsDocument ? proposedBounds.minY
                : (size.height - rect.height) / 2 + (isFlipped ? verticalBias : -verticalBias)
        }
        return rect
    }
}
