import AppKit
import DesksetCore
import DesksetDraw

// MacGlass (a Deskset extension; DesksetCore/Engine/Glass.swift, docs/compat/engine.md): the glass lives inside the
// skin window, under the skin's own drawing. The window's content view is a `SkinContentView` holding the glass views
// (back to front) and, on top of them, the `SkinView`, whose drawing is transparent wherever the skin draws nothing.
// Being part of the window, the glass follows its alpha, fades, level, Spaces and moves by itself.
//
// - macOS 26 and later: `NSGlassEffectView` (Liquid Glass), with the region's style, corner radius and tint.
// - macOS 13–15: `NSVisualEffectView` blending with what is behind the window (Regular: the popover material, Clear:
//   the HUD material, the darker and more see-through one), rounded with a mask image, the tint drawn over it.
//
// Views are made, changed and removed on the main thread only, and only when the engine's list of regions changed.

/// The skin window's content view: the glass views, then the skin's drawing (`SkinView`) in front of them.
final class SkinContentView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}

/// Holds one piece of glass: its frame is the region, or the container that cuts the region off (then it clips).
/// It never takes the mouse; the `SkinView` in front of it does (see `SkinRenderer.GlassDrawing.window`).
final class SkinGlassFrameView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The glass behind one skin.
final class SkinGlassViews {
    /// Uses the macOS 13–15 glass on macOS 26 too: set by tests, and by `DESKSET_LEGACY_GLASS=1` to compare the two.
    static var forcesFallback = ProcessInfo.processInfo.environment["DESKSET_LEGACY_GLASS"] == "1"

    /// Whether new glass is Liquid Glass (`NSGlassEffectView`) rather than the fallback.
    static var usesSystemGlass: Bool {
        if #available(macOS 26.0, *) { return !forcesFallback }
        return false
    }

    /// One region's views.
    final class Piece {
        let frameView = SkinGlassFrameView()
        /// `NSGlassEffectView` or `NSVisualEffectView`.
        let glass: NSView
        /// The fallback's tint, over the effect view.
        let tint: NSView?
        let isSystemGlass: Bool
        fileprivate(set) var region: GlassRegion?

        init(system: Bool) {
            isSystemGlass = system
            if system, #available(macOS 26.0, *) {
                glass = NSGlassEffectView()
                tint = nil
            } else {
                let effect = NSVisualEffectView()
                effect.blendingMode = .behindWindow
                effect.state = .active
                let tint = NSView()
                tint.wantsLayer = true
                tint.layer?.masksToBounds = true
                tint.autoresizingMask = [.width, .height]
                effect.addSubview(tint)
                glass = effect
                self.tint = tint
            }
            frameView.wantsLayer = true
            frameView.addSubview(glass)
            frameView.setAccessibilityElement(false)
        }
    }

    /// The regions shown now, back to front.
    private(set) var regions: [GlassRegion] = []
    private var pieces: [String: Piece] = [:]

    /// The pieces in `regions` order (tests).
    var shownPieces: [Piece] { regions.compactMap { pieces[$0.id] } }

    /// Shows `regions` in `container`, behind `skinView` (which stays the frontmost subview). Only what changed is
    /// touched.
    func apply(_ regions: [GlassRegion], in container: NSView, below skinView: NSView) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard regions != self.regions || pieces.values.contains(where: { $0.frameView.superview !== container }) else {
            return
        }
        let system = SkinGlassViews.usesSystemGlass
        var kept: [String: Piece] = [:]
        var ordered: [NSView] = []
        for region in regions {
            let piece: Piece
            if let existing = pieces[region.id], existing.isSystemGlass == system {
                piece = existing
            } else {
                pieces[region.id]?.frameView.removeFromSuperview()
                piece = Piece(system: system)
            }
            configure(piece, region)
            kept[region.id] = piece
            ordered.append(piece.frameView)
        }
        for (id, piece) in pieces where kept[id] !== piece { piece.frameView.removeFromSuperview() }
        pieces = kept
        self.regions = regions
        // Glass back to front, then the skin's drawing; other subviews (none today) stay in front.
        let others = container.subviews.filter { !($0 is SkinGlassFrameView) && $0 !== skinView }
        let wanted = ordered + [skinView] + others
        if container.subviews != wanted { container.subviews = wanted }
    }

    private func configure(_ piece: Piece, _ region: GlassRegion) {
        guard piece.region != region else { return }
        piece.region = region
        let rect = region.rect.cgRect
        let frame = region.clip.map { $0.cgRect } ?? rect
        piece.frameView.frame = frame
        piece.frameView.layer?.masksToBounds = region.clip != nil
        piece.glass.frame = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let radius = CGFloat(region.cornerRadius)
        if piece.isSystemGlass, #available(macOS 26.0, *), let glass = piece.glass as? NSGlassEffectView {
            glass.style = region.style == .clear ? .clear : .regular
            glass.cornerRadius = radius
            glass.tintColor = region.tint?.nsColor
        } else if let effect = piece.glass as? NSVisualEffectView {
            effect.material = SkinGlassViews.fallbackMaterial(region.style)
            effect.maskImage = radius > 0 ? SkinGlassViews.roundedMask(radius) : nil
            if let tint = piece.tint {
                tint.frame = effect.bounds
                tint.isHidden = region.tint == nil
                tint.layer?.backgroundColor = region.tint.map(SkinGlassViews.fallbackTint)
                tint.layer?.cornerRadius = radius
            }
        }
    }

    /// The material standing in for each style before macOS 26 (judgment; docs/compat/engine.md).
    static func fallbackMaterial(_ style: GlassStyle) -> NSVisualEffectView.Material {
        style == .clear ? .hudWindow : .popover
    }

    /// The fallback's tint layer: the color at `fallbackTintStrength` of its alpha, so the glass leans toward it (as
    /// Liquid Glass does with `tintColor`) rather than being covered by it.
    static func fallbackTint(_ color: RGBA) -> CGColor {
        CGColor(srgbRed: color.r / 255, green: color.g / 255, blue: color.b / 255,
                alpha: min(max(color.a / 255, 0), 1) * fallbackTintStrength)
    }

    static let fallbackTintStrength: CGFloat = 0.4

    /// A stretchable rounded rectangle: the fallback's corners (`NSVisualEffectView.maskImage`).
    static func roundedMask(_ radius: CGFloat) -> NSImage {
        let side = 2 * radius + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// App entry points for the shared CoreGraphics glass placeholder.
enum GlassPlaceholder {
    static func draw(_ regions: [GlassRegion], in ctx: CGContext, dark: Bool?) {
        DesksetDraw.GlassPlaceholder.draw(regions, in: ctx, dark: dark)
    }

    static func draw(_ region: GlassRegion, in ctx: CGContext, dark: Bool?) {
        DesksetDraw.GlassPlaceholder.draw(region, in: ctx, dark: dark)
    }

    static func drawHitArea(_ regions: [GlassRegion], in ctx: CGContext) {
        DesksetDraw.GlassPlaceholder.drawHitArea(regions, in: ctx)
    }

    static func isDark(_ color: RGBA) -> Bool {
        DesksetDraw.GlassPlaceholder.isDark(color)
    }

    static func path(_ region: GlassRegion) -> CGPath? {
        DesksetDraw.GlassPlaceholder.path(region)
    }
}
