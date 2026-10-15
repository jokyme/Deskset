import AppKit
import DesksetCore
import DesksetRuntime

/// Internal, explicit selection at AppController.activate. Bitmap remains the default. The C budget belongs to
/// LayerRuntime's owned bitmaps, not all retained images, preparation storage or the process. Components remain
/// candidates; callers opt into that experimental partition independently of the safe Single presentation.
enum SkinLayerFrameBackend: Equatable {
    case c
    /// Internal activation opt-in, initially only Single on a physical worker. This is not a total CA budget.
    case nativeSingle(maximumCallbackBitmapBytes: Int)
    /// Experimental fixed accepted component plan; no generic ink-coverage or per-group dirty policy.
    case nativeComponents(maximumCallbackBitmapBytes: Int)
    /// Internal layers intent. The owner resolves the loaded Update once; refresh keeps this intent and reselects.
    /// Effective intervals below 100 ms use C; slower or one-shot skins use qualified E with their actual C plan.
    case automatic(maximumCallbackBitmapBytes: Int)
}

enum SkinFrameContentMode: Equatable {
    case bitmap
    case layers(partition: LayerRuntime.Partition, maximumOwnedBitmapBytes: Int, backend: SkinLayerFrameBackend = .c)

    var usesLayers: Bool { if case .layers = self { return true }; return false }
    var requestsNativeFrames: Bool {
        if case .layers(_, _, .nativeSingle) = self { return true }
        if case .layers(_, _, .nativeComponents) = self { return true }
        if case .layers(_, _, .automatic) = self { return true }
        return false
    }
    var nativeFrameBudget: Int? {
        switch self {
        case let .layers(.single, _, .nativeSingle(bytes)),
             let .layers(.candidateComponents, _, .nativeComponents(bytes)),
             let .layers(_, _, .automatic(bytes)): return bytes
        default: return nil
        }
    }
    var nativeFramePartition: LayerRuntime.NativePartition? {
        switch self {
        case .layers(.single, _, .nativeSingle), .layers(.single, _, .automatic): return .single
        case .layers(.candidateComponents, _, .nativeComponents),
             .layers(.candidateComponents, _, .automatic): return .acceptedComponents
        default: return nil
        }
    }
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
    private var layerFrameSequence: UInt64?
    /// Allocated only by an explicit scoped observation or Single publication request. The C wrapper stays
    /// attached as the fallback; a qualified publication changes only the provider-owned host opacities.
    private var nativeStage: LayerRuntime.NativeStage?
    private var nativeStageHost: CALayer?
    private var publishedNativeStage: LayerRuntime.NativeStage?

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
        transaction { applyBitmap(frame) }
        presented += 1
    }

    /// Main has already claimed the delivery and supplies the surrounding disabled-actions transaction. This
    /// shares the legacy writer's lock/retirement guard, but never starts or flushes an earlier transaction.
    func presentAccepted(_ frame: SkinFrame) -> Bool {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementRequested, ownerRoot == nil else { return false }
        applyBitmap(frame)
        presented += 1
        return true
    }

    private func applyBitmap(_ frame: SkinFrame) {
        contentLayer.bounds = CGRect(origin: .zero, size: frame.size)
        contentLayer.contentsScale = frame.scale
        contentLayer.contents = frame.image
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

    /// The ordered Main clear belongs to the caller's transaction, just like presentAccepted.
    func releaseContentsAccepted() -> Bool {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementRequested, ownerRoot == nil else { return false }
        contentLayer.contents = nil
        return true
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
        layerFrameSequence = frame.sequence
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
        layerFrameSequence = patch.frame.sequence
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
        layerFrameSequence = frame.sequence
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

    /// Main with a real executor lease, acquired before taking this lock. A neutral transparent sibling inherits
    /// SkinView's native flip once. It is not presented, counted as a frame, or retained as a ready cache.
    func attachNativeStage(_ stage: LayerRuntime.NativeStage, executor: SkinExecutor) -> Bool {
        precondition(Thread.isMainThread && executor.isCurrent)
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementRequested, ownerRoot != nil, layerFrameReady, nativeStage == nil,
              let parent = contentLayer.superlayer else { return false }
        let host = CALayer()
        host.anchorPoint = .zero
        host.position = .zero
        host.bounds = stage.root.bounds
        host.contentsScale = stage.scale
        host.contentsFormat = .RGBA8Uint
        host.isGeometryFlipped = false
        host.opacity = 0
        host.actions = Self.noActions
        transaction {
            host.addSublayer(stage.root)
            parent.addSublayer(host)
        }
        nativeStage = stage
        nativeStageHost = host
        return true
    }

    /// Only after the owner has released the matching E candidate. A late ack cannot detach a newer attachment.
    func detachNativeStage(_ stage: LayerRuntime.NativeStage) {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        guard nativeStage === stage, publishedNativeStage !== stage else { return }
        transaction {
            stage.root.removeFromSuperlayer()
            nativeStageHost?.removeFromSuperlayer()
        }
        nativeStage = nil
        nativeStageHost = nil
    }

    /// Main has parked the actual owner and frozen C before taking this lock. The source scene is already the
    /// presented C generation, so only the provider-owned hosts change; no new glass, hit map or C frame is invented.
    func publishNativeStage(_ stage: LayerRuntime.NativeStage, executor: SkinExecutor) -> Bool {
        precondition(Thread.isMainThread && executor.isCurrent)
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown, !retirementRequested, nativeStage === stage, publishedNativeStage == nil,
              ownerRoot === stage.fallbackRoot, layerFrameReady, layerFrameSequence == stage.sourceSequence,
              let host = nativeStageHost else { return false }
        transaction {
            contentLayer.opacity = 0
            host.opacity = 1
        }
        publishedNativeStage = stage
        return true
    }

    /// A standing Main-only host permission. C is frozen while E is published; rollback reads no owner/cache and
    /// cannot touch a newer attachment. Its ack, rather than a queued request, allows the owner to write C again.
    @discardableResult
    func rollbackNativeStage(_ stage: LayerRuntime.NativeStage) -> Bool {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        guard nativeStage === stage else { return false }
        if publishedNativeStage === stage {
            transaction {
                contentLayer.opacity = 1
                nativeStageHost?.opacity = 0
            }
            publishedNativeStage = nil
        }
        return true
    }

    var visibleNativeStage: LayerRuntime.NativeStage? {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        return publishedNativeStage
    }

    var contentOpacity: Float {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        return contentLayer.opacity
    }

    /// Self-tests observe the hidden attachment only while holding the same actual executor lease as main.
    var stagedNativeHost: CALayer? {
        precondition(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        return nativeStageHost
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
