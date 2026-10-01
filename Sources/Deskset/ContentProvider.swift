import AppKit
import DesksetCore
import DesksetRuntime

/// Internal, explicit selection at AppController.activate. Bitmap remains the default. The C budget belongs to
/// LayerRuntime's owned bitmaps, not all retained images, preparation storage or the process. Components remain
/// candidates; callers opt into that experimental partition independently of the safe Single presentation.
enum SkinFrameContentMode: Equatable {
    case bitmap
    case layers(partition: LayerRuntime.Partition, maximumOwnedBitmapBytes: Int)

    var usesLayers: Bool { if case .layers = self { return true }; return false }
}

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
    /// The window has been ordered out for a while: what the provider shows may be let go of. The producer presents a
    /// frame before the window is shown again. Optional: a provider that keeps nothing worth letting go of ignores it.
    func releaseContents()
}

extension ContentProvider {
    func releaseContents() {}
}

/// Frame delivery E on bitmaps (docs/skin-threading.md §7.3): the frame becomes the contents of a layer the skin owns,
/// `contentLayer`, a sublayer of `SkinView`'s layer. The view's own layer is AppKit's and shows nothing itself.
///
/// - The layer is anchored at the view's top-left corner (the view is flipped) and has no implicit animations.
/// - Its bounds are always the size of the frame it shows, set in the same transaction as the frame, so a frame is
///   never stretched. For as long as the window has not followed a new size yet it clips the frame, or leaves a
///   transparent margin.
/// - Every change is an explicit transaction with actions disabled. The frames of one turn of the executor's run loop
///   go together, in one transaction committed at the end of the turn (`SkinFrameTurn`, `SkinFrameBatch`); off the main
///   thread it is flushed at once.
/// - Nothing outside this class touches `contentLayer`.
final class LayerContentProvider: ContentProvider {
    /// Guards the layer and the state below: `teardown` comes from the main thread, frames from the skin's executor.
    private let lock = NSLock()
    private let contentLayer = CALayer()
    private var isTornDown = false
    private var visible = false
    private var scale: CGFloat = 0
    private var presented = 0
    private var ownerRoot: CALayer?
    private var retirementRequested = false
    private var retirementScheduled = false
    private var layerFrameReady = false

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
        guard !isTornDown, !retirementRequested, ownerRoot == nil else { return }
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

    /// Lets go of the picture (the window is ordered out); the next `present` shows one again.
    func releaseContents() {
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown else { return }
        transaction { contentLayer.contents = nil }
    }

    func teardown() {
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown else { return }
        // A direct late teardown may invalidate an install, but cannot detach a root its executor still updates.
        // SkinRuntime.teardownContent queues owner cleanup and acknowledges it before completeLayerTeardown.
        retirementRequested = true
        guard ownerRoot == nil else { return }
        isTornDown = true
        transaction {
            contentLayer.contents = nil
            contentLayer.removeFromSuperlayer()
        }
    }

    /// Main, inside the real executor's exclusive scope. The executor is parked BEFORE this lock is taken.
    /// Root contains completed C images only; no view, drawing context or native drawing callback is installed.
    func installLayerRoot(_ root: CALayer, frame: LayerRuntime.Frame, executor: SkinExecutor) -> Bool {
        precondition(Thread.isMainThread && executor.isCurrent)
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementRequested, ownerRoot == nil || ownerRoot === root else { return false }
        transaction {
            contentLayer.contents = nil
            contentLayer.isGeometryFlipped = true
            contentLayer.bounds = root.bounds
            contentLayer.contentsScale = frame.scale
            if ownerRoot == nil { contentLayer.addSublayer(root) }
        }
        ownerRoot = root
        layerFrameReady = true
        presented += 1
        return true
    }

    /// Main holds an authentic contentRoot writer, not the live SkinExecutor. This never accesses owner caches.
    /// Both the wrapper and root change inside the caller's one disabled-actions transaction.
    func applyScenePatch(_ patch: ScenePatch) -> Bool {
        precondition(Thread.isMainThread && patch.isMainWriter(for: patch.root))
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementRequested, ownerRoot == nil || ownerRoot === patch.root else { return false }
        guard patch.applyContentOnMain() else { return false }
        contentLayer.contents = nil
        contentLayer.isGeometryFlipped = true
        contentLayer.bounds = patch.bounds
        contentLayer.contentsScale = patch.frame.scale
        if ownerRoot == nil { contentLayer.addSublayer(patch.root) }
        ownerRoot = patch.root
        layerFrameReady = true
        presented += 1
        return true
    }

    /// The owner updates only its root; this method keeps the provider's private wrapper with that finished frame.
    func presentedLayerRoot(_ root: CALayer, frame: LayerRuntime.Frame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementRequested, ownerRoot === root else { return false }
        transaction {
            contentLayer.bounds = root.bounds
            contentLayer.contentsScale = frame.scale
        }
        presented += 1
        layerFrameReady = true
        return true
    }

    func releaseLayerFrame() {
        lock.lock()
        defer { lock.unlock() }
        layerFrameReady = false
    }

    var acceptsLayerFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isTornDown && !retirementRequested
    }

    var hasLayerFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownerRoot != nil && layerFrameReady && !isTornDown && !retirementRequested
    }

    /// Main invalidates pending installs immediately, while the last image remains available for closing/fading.
    func beginLayerTeardown() -> Bool {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementScheduled else { return false }
        retirementRequested = true
        retirementScheduled = true
        return true
    }

    /// Main, only after the executor has closed its owner and acknowledged that no further update is possible.
    func completeLayerTeardown() {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, retirementRequested else { return }
        isTornDown = true
        transaction {
            ownerRoot?.removeFromSuperlayer()
            ownerRoot = nil
            contentLayer.contents = nil
            contentLayer.removeFromSuperlayer()
        }
    }

    var installedLayerRoot: CALayer? {
        lock.lock()
        defer { lock.unlock() }
        return ownerRoot
    }

    /// An explicit transaction with actions disabled (docs/skin-threading.md §7.3, rule 2). Inside a turn of frames it
    /// goes with the turn's one transaction (`SkinFrameBatch`); otherwise it is committed now, and flushed at once off
    /// the main thread.
    private func transaction(_ body: () -> Void) {
        let batched = SkinFrameBatch.join()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        if !batched { SkinFrameBatch.committed() }
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
