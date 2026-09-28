import AppKit
import DesksetCore

// Where a skin's frames go on screen (docs/skin-threading.md §7.3, §15 "Phase 2: plan"). The skin's runtime draws each
// frame on its executor (`SkinFrameProducer`) and hands it to its window's content provider, the seam between the two
// halves of a running skin. The first provider is `LayerContentProvider`, a layer of the skin's own inside `SkinView`;
// a later, layer-based runtime replaces it, so nothing outside a provider touches what it shows.

/// One finished picture of a skin.
struct SkinFrame {
    /// The picture, top row first, in the window's colour space: `size` × `scale` pixels.
    let image: CGImage
    /// The points the picture covers from the window's top-left corner: its pixels over `scale`, so that it is never
    /// stretched (a skin of 100.3 points at 2× is a picture of 201 pixels, 100.5 points).
    let size: CGSize
    /// Pixels per point: the window's backing scale factor when the frame was drawn.
    let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

/// What a skin's window shows of it. The frame producer calls `present`, `setVisible` and `setScale` on the skin's
/// executor, one at a time; `teardown` comes from the main thread once the window has closed, and may meet a frame
/// under way: a provider is safe for that.
protocol ContentProvider: AnyObject {
    /// Shows `frame` from the window's top-left corner, at once and without animation, in place of the one before.
    func present(_ frame: SkinFrame)
    /// Whether the window can be seen now: shown, not covered, not hidden by a bang. The producer draws no frames while
    /// it cannot, and one when it can again.
    func setVisible(_ visible: Bool)
    /// The window's backing scale factor changed (it moved to another display). The next frame is drawn at it.
    func setScale(_ scale: CGFloat)
    /// The window has closed: nothing more is shown, and what was shown is let go of. Later calls do nothing.
    func teardown()
}

/// Frame delivery E on bitmaps (docs/skin-threading.md §7.3): the frame becomes the contents of a layer the skin owns,
/// `contentLayer`, a sublayer of `SkinView`'s layer. The view's own layer is AppKit's and shows nothing itself.
///
/// - The layer is anchored at the view's top-left corner (the view is flipped) and has no implicit animations.
/// - Its bounds are always the size of the frame it shows, set in the same transaction as the frame, so a frame is
///   never stretched. For as long as the window has not followed a new size yet it clips the frame, or leaves a
///   transparent margin.
/// - Every change is an explicit transaction with actions disabled; off the main thread it is flushed at once (on the
///   main thread it goes with the run loop's own commit, as AppKit's drawing did).
/// - Nothing outside this class touches `contentLayer`.
final class LayerContentProvider: ContentProvider {
    /// Guards the layer and the state below: `teardown` comes from the main thread, frames from the skin's executor.
    private let lock = NSLock()
    private let contentLayer = CALayer()
    private var isTornDown = false
    private var visible = false
    private var scale: CGFloat = 0
    private var presented = 0

    /// Main thread: the content layer goes into `view`'s layer, which the view makes (and keeps: AppKit keeps a layer the
    /// view asked for when the view moves to another window, as when a skin's panel is replaced).
    init(in view: NSView) {
        view.wantsLayer = true
        let layer = contentLayer
        layer.name = "Deskset skin content"
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.bounds = .zero
        layer.isOpaque = false
        layer.actions = LayerContentProvider.noActions
        if let host = view.layer {
            // The bounds are always the frame's, so the gravity never scales anything; it only says which corner the
            // picture would stay in otherwise: the top-left one, which is `bottomLeft` in a flipped layer tree.
            layer.contentsGravity = host.contentsAreFlipped() ? .bottomLeft : .topLeft
            host.addSublayer(layer)
        }
    }

    /// Every property the provider changes, without an implicit animation (the transactions disable them too).
    private static let noActions: [String: CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull(),
        "hidden": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(),
    ]

    func present(_ frame: SkinFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown else { return }
        transaction {
            contentLayer.bounds = CGRect(origin: .zero, size: frame.size)
            contentLayer.contentsScale = frame.scale
            contentLayer.contents = frame.image
        }
        presented += 1
    }

    func setVisible(_ visible: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.visible = visible
    }

    /// The layer's `contentsScale` changes with the next frame, drawn at the new scale: changed now, it would show the
    /// frame on screen at another size until then.
    func setScale(_ scale: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        self.scale = scale
    }

    func teardown() {
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown else { return }
        isTornDown = true
        transaction {
            contentLayer.contents = nil
            contentLayer.removeFromSuperlayer()
        }
    }

    /// An explicit transaction with actions disabled, flushed at once off the main thread (docs/skin-threading.md §7.3,
    /// rule 2).
    private func transaction(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        if !Thread.isMainThread { CATransaction.flush() }
    }

    // MARK: What the self-tests read

    /// What the layer shows now: its picture, bounds, scale, where it sits in its superlayer and which layer that is.
    struct Shown {
        var image: CGImage?
        var bounds: CGRect
        var scale: CGFloat
        var position: CGPoint
        var anchorPoint: CGPoint
        weak var superlayer: CALayer?
        var isAttached: Bool
    }

    var shown: Shown {
        lock.lock()
        defer { lock.unlock() }
        let layer = contentLayer
        let contents = layer.contents
        let image = contents.flatMap { CFGetTypeID($0 as CFTypeRef) == CGImage.typeID ? ($0 as! CGImage) : nil }
        return Shown(image: image, bounds: layer.bounds, scale: layer.contentsScale, position: layer.position,
                     anchorPoint: layer.anchorPoint, superlayer: layer.superlayer, isAttached: layer.superlayer != nil)
    }

    /// Frames presented, what the provider was last told, and whether it was torn down.
    var state: (presented: Int, visible: Bool, scale: CGFloat, tornDown: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (presented, visible, scale, isTornDown)
    }

    /// Whether `layer` is the content layer (tests: the view's layer has no other sublayer).
    func isContentLayer(_ layer: CALayer) -> Bool { layer === contentLayer }
}
