import AppKit
import DesksetCore

/// Main-only native presentation. Pixels and native glass are siblings in source order. The caller validates and
/// claims the immutable delivery, then applies it inside the same transaction as window geometry and the old
/// bitmap provider's clear. This view never starts/commits a transaction or acknowledges an owner itself.
final class SkinNativeCompositionView: NSView {
    private let systemGlass: Bool
    private let glass = SkinGlassViews()
    private var pixels: [PixelsView] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var shownPieces: [SkinGlassViews.Piece] { glass.shownPieces }
    var shownPixels: [CALayer] { pixels.map(\.content) }

    init(systemGlass: Bool) {
        precondition(Thread.isMainThread)
        self.systemGlass = systemGlass
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    func apply(_ composition: SkinBitmapComposition) {
        precondition(Thread.isMainThread)
        precondition(composition.systemGlass == systemGlass)
        var regions: [GlassRegion] = []
        for item in composition.items { if case .glass(let region) = item { regions.append(region) } }
        let pieces = glass.reconcile(regions, system: systemGlass)
        var nextPixels: [PixelsView] = []
        var ordered: [NSView] = []
        var glassIndex = 0
        for item in composition.items {
            switch item {
            case .glass:
                ordered.append(pieces[glassIndex].frameView)
                glassIndex += 1
            case .pixels(let slice):
                let index = nextPixels.count
                let view = index < pixels.count ? pixels[index] : PixelsView()
                view.apply(slice, scale: composition.scale)
                nextPixels.append(view); ordered.append(view)
            }
        }
        for view in pixels.dropFirst(nextPixels.count) { view.content.contents = nil; view.removeFromSuperview() }
        pixels = nextPixels
        frame.size = composition.size
        if subviews != ordered { subviews = ordered }
        isHidden = false
    }

    func clear() {
        precondition(Thread.isMainThread)
        _ = glass.reconcile([], system: systemGlass)
        for view in pixels { view.content.contents = nil; view.removeFromSuperview() }
        pixels = []
        isHidden = true
    }

    /// AppKit owns the hosting layer; the image lives in a private sublayer, as in LayerContentProvider.
    private final class PixelsView: NSView {
        let content = CALayer()
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            content.anchorPoint = .zero
            content.position = .zero
            content.isOpaque = false
            content.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                               "contentsScale": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
            if let layer {
                content.contentsGravity = layer.contentsAreFlipped() ? .bottomLeft : .topLeft
                layer.addSublayer(content)
            }
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { return nil }

        func apply(_ slice: SkinBitmapSlice, scale: CGFloat) {
            frame = slice.frame(at: scale)
            content.bounds = CGRect(origin: .zero, size: frame.size)
            content.contentsScale = scale
            content.contents = slice.image
        }
    }
}
