import AppKit
import DesksetCore
import DesksetDraw
import DesksetRuntime

/// Draws a skin window's picture into a bitmap of its own, which the skin's frame producer presents as the contents of
/// its window's content layer (`SkinFrameProducer`, `LayerContentProvider`).
///
/// Why not AppKit's `draw(_:)`: on macOS 26 a layer-backed view's backing store is drawn through Core Animation's
/// accelerated path (CA::CG on Metal). As soon as a skin redrew every second or faster, that held 110–150 MB of
/// graphics memory per process. Measured on the release build (2026-09-27): the first-run four (Clock S, Calendar S,
/// Weather M, System M) took 187 MB with `draw(_:)` and 44 MB drawn here, for 0.55 % CPU instead of 0.32 %.
///
/// It also keeps pictures of runs of meters that did not change since the previous frame (`Meter.drawGeneration`): a
/// frame draws the meters that changed and copies the rest. Skins that redraw 30 times a second (a turning Turntable
/// label, Spectrum's bars, Studio VU's needles) would otherwise cost more than on the accelerated path (the playing
/// Turntable: 19 % of a core drawn in full, 14 % with `draw(_:)`, 6–7 % with kept pictures), and the ones that redraw
/// once a second save their static faces too (Studio VU at rest: 1.5 % → 0.7 %; System L 1.5 % → 1.1 %), for a few MB.
final class SkinBitmapDrawing {
    /// One step of the captured drawing: the base or a top-level element, including its container composition.
    struct Item: Equatable {
        enum ID: Hashable { case base, element(ElementID) }
        struct Revision: Equatable {
            let id: ElementID
            let generation: Int
        }
        let id: ID
        let drawing: [DrawItem]
        let dependencies: [ImageDependency]
        let revisions: [Revision]
    }

    /// A picture of consecutive items, the size of the whole skin, and the image files it was drawn from (a file
    /// replaced on disk shows in a full drawing without any meter changing: the picture is then drawn again).
    private struct Run {
        let items: [Item]
        let image: CGImage
        let files: Images.UsedFiles
    }

    /// Pictures kept per skin; runs beyond these are drawn every frame.
    static let maxRuns = 4
    /// `DESKSET_RUNCACHE_VERIFY=1`: every frame that copies a picture is also drawn in full, and a difference is
    /// logged (once per skin). A check for development, never on by default.
    static var verifies = ProcessInfo.processInfo.environment["DESKSET_RUNCACHE_VERIFY"] == "1"
    /// Levels per channel a copied picture may differ from direct drawing: pictures composite like direct drawing,
    /// but each 8-bit step rounds (4 measured where a turning label meets the ring over it). A stale picture differs
    /// by far more.
    static let tolerance = 8

    /// Two bitmaps, used in turn: the layer still shows the picture of one while the next frame is drawn into the
    /// other, so drawing never has to copy a picture Core Animation holds.
    private var bitmaps: [CGContext] = []
    private var nextBitmap = 0
    private var runs: [Run] = []
    /// Captured inputs at the previous frame: unchanged revisions, drawing values and resource observations can
    /// be kept. Revisions preserve the existing run partition even when an update resolves to identical pixels.
    private var previous: [Item.ID: Item] = [:]
    /// What every picture depends on besides the items (see `resetKey`).
    private var drawnFor: ResetKey?
    private var reportedDifference = false

    /// What a picture was drawn for: another skin (a refresh), size, scale, colour space, appearance or fonts.
    private struct ResetKey: Equatable {
        let context: ObjectIdentifier
        let width: Int
        let height: Int
        let scale: CGFloat
        let origin: SkinPoint
        /// Compared as color spaces (`CFEqual`), not by name: a display's own profile has none.
        let space: CGColorSpace
        let environment: EnvironmentStamp
    }

    /// What the last frame did (tests): runs copied, runs drawn into a new picture, items drawn directly.
    private(set) var lastStats = (copied: 0, made: 0, drawn: 0)

    /// Lets go of the kept pictures and both bitmaps (the picture a layer still shows keeps its own pixels): a window
    /// that cannot be seen for a while holds none of them. The next picture is drawn in full.
    func releaseKept() {
        runs = []
        previous = [:]
        bitmaps = []
        drawnFor = nil
    }

    /// Whether it keeps anything now: bitmaps or pictures (tests).
    var keepsPictures: Bool { !bitmaps.isEmpty || !runs.isEmpty }
    /// Pictures kept now (tests).
    var keptRuns: Int { runs.count }
    /// Frames that differed from a full drawing (`verifies`; tests).
    private(set) var differences = 0

    /// One owner-confined bitmap frame. The context holds graphics caches, never a live engine owner.
    struct Capture {
        let scene: WidgetScene
        let context: SkinRenderContext
        let cycle: Int
        let size: CGSize
        let source: String
        var origin = SkinPoint()
    }

    static func capture(_ skin: Skin, size: CGSize, scale: CGFloat, appearance: String) -> Capture {
        let context = SkinRenderContext.of(skin)
        let environment = AppSceneEnvironment(scale: Double(scale),
                                              appearance: skin.host?.environment(for: skin).appearance ?? .light,
                                              appearanceName: appearance)
        let scene = context.sceneProjector.project(skin, environment: environment, glassSource: .published)
        return Capture(scene: scene, context: context, cycle: skin.updateCount, size: size, source: skin.config)
    }

    /// The skin as it is now, `size` points at `scale` pixels per point; nil for an empty size.
    func picture(of skin: Skin, size: CGSize, scale: CGFloat, space: CGColorSpace, appearance: String) -> CGImage? {
        picture(Self.capture(skin, size: size, scale: scale, appearance: appearance), scale: scale, space: space)
    }

    func picture(_ frame: Capture, scale: CGFloat, space: CGColorSpace,
                 beforeDrawing: ((CGContext) -> Bool)? = nil) -> CGImage? {
        picture(scene: frame.scene, context: frame.context, cycle: frame.cycle, size: frame.size,
                scale: scale, space: space, source: frame.source, origin: frame.origin, beforeDrawing: beforeDrawing)
    }

    /// Draws and keeps only captured values. The context contains graphics caches, with no live engine objects.
    func picture(scene: WidgetScene, context: SkinRenderContext, cycle: Int, size: CGSize, scale: CGFloat,
                 space: CGColorSpace, source: String = "", origin: SkinPoint = SkinPoint(),
                 beforeDrawing: ((CGContext) -> Bool)? = nil) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              origin.x.isFinite, origin.y.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        let pixelWidth = (size.width * scale).rounded(.up), pixelHeight = (size.height * scale).rounded(.up)
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16384, pixelHeight <= 16384 else { return nil }
        let w = Int(pixelWidth), h = Int(pixelHeight)
        let key = ResetKey(context: ObjectIdentifier(context), width: w, height: h, scale: scale, origin: origin, space: space,
                           environment: scene.environment)
        if key != drawnFor {
            drawnFor = key
            runs = []
            previous = [:]
            bitmaps = [SkinBitmapDrawing.makeContext(w, h, space), SkinBitmapDrawing.makeContext(w, h, space)]
                .compactMap { $0 }
        }
        // Pictures of image files that changed since are drawn again.
        runs.removeAll { !Images.filesUnchanged($0.files) }
        guard bitmaps.count == 2 else { return nil }
        let ctx = bitmaps[nextBitmap]
        nextBitmap = 1 - nextBitmap
        if let beforeDrawing {
            // Image qualification sees the same destination mapping as the actual leaf, before any old picture
            // is reused. Legacy owners do not install this callback and retain their original failure behavior.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -origin.x, y: -origin.y)
            let ready = beforeDrawing(ctx)
            ctx.restoreGState()
            guard ready else { return nil }
        }
        let topLevel = scene.topLevelElements
        let drawingRuns = scene.drawingRuns
        var items = [Item(id: .base, drawing: scene.background, dependencies: scene.backgroundImageDependencies, revisions: [])]
        for (index, element) in topLevel.enumerated() {
            let children = element.isContainer ? scene.elements.filter { $0.container == element.id } : []
            items.append(Item(id: .element(element.id), drawing: drawingRuns[index + 1],
                              dependencies: element.imageDependencies + children.filter { $0.visibility == .visible }.flatMap(\.imageDependencies),
                              revisions: ([element] + children).map { Item.Revision(id: $0.id, generation: $0.drawGeneration) }))
        }
        let stable = items.map { previous[$0.id] == $0 }
        previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        var kept: [Run] = []
        var stats = (copied: 0, made: 0, drawn: 0)
        // The bitmap still holds an older frame: the first picture replaces all of it, else it is cleared first.
        var started = false
        func drawDirectly(_ range: Range<Int>) {
            if !started { ctx.clear(CGRect(x: 0, y: 0, width: w, height: h)) }
            started = true
            SkinBitmapDrawing.draw(items: range, drawingRuns, context: context, cycle: cycle, into: ctx, height: h, scale: scale, origin: origin)
            stats.drawn += range.count
        }
        func place(_ image: CGImage) {
            copy(image, into: ctx, w, h, replacing: !started)
            started = true
        }
        var index = 0
        while index < items.count {
            guard stable[index] else {
                drawDirectly(index..<index + 1)
                index += 1
                continue
            }
            var end = index + 1
            while end < items.count && stable[end] { end += 1 }
            let runItems = Array(items[index..<end])
            if let run = runs.first(where: { $0.items == runItems }) {
                place(run.image)
                kept.append(run)
                stats.copied += 1
            } else if kept.count < SkinBitmapDrawing.maxRuns,
                      let picture = SkinBitmapDrawing.makeContext(w, h, space) {
                let range = index..<end
                let files = Images.recordingFiles {
                    SkinBitmapDrawing.draw(items: range, drawingRuns, context: context, cycle: cycle, into: picture, height: h, scale: scale, origin: origin)
                }
                if let image = picture.makeImage() {
                    place(image)
                    kept.append(Run(items: runItems, image: image, files: files))
                    stats.made += 1
                } else {
                    drawDirectly(index..<end)
                }
            } else {
                drawDirectly(index..<end)
            }
            index = end
        }
        if !started { ctx.clear(CGRect(x: 0, y: 0, width: w, height: h)) }
        runs = kept
        lastStats = stats
        let image = ctx.makeImage()
        if SkinBitmapDrawing.verifies, stats.copied > 0, let image { verify(image, scene, context, cycle, w, h, scale, space, origin: origin, source: source) }
        return image
    }

    static func makeContext(_ w: Int, _ h: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Draws captured runs (0 is the base) in skin coordinates: top-left origin, points.
    static func draw(items range: Range<Int>, _ runs: [[DrawItem]], context: SkinRenderContext, cycle: Int,
                     into ctx: CGContext, height: Int, scale: CGFloat, origin: SkinPoint = SkinPoint()) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let target = DrawTarget.prepareOwnedBitmap(ctx, glass: .hitArea)
        for i in range {
            // Real glass is behind the content layer; these values only catch its mouse input.
            DesksetDraw.DrawExecutor.draw(runs[i], in: ctx, context: context.drawing, cycle: cycle, target: target)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// A picture of the whole skin's size, pixel for pixel: over what is there, or `replacing` it.
    private func copy(_ image: CGImage, into ctx: CGContext, _ w: Int, _ h: Int, replacing: Bool = false) {
        SkinBitmapDrawing.copy(image, into: ctx, w, h, replacing: replacing)
    }

    static func copy(_ image: CGImage, into ctx: CGContext, _ w: Int, _ h: Int, replacing: Bool = false) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        if replacing { ctx.setBlendMode(.copy) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    /// Compares `image` with the skin drawn in full (see `tolerance`).
    private func verify(_ image: CGImage, _ scene: WidgetScene, _ context: SkinRenderContext, _ cycle: Int,
                        _ w: Int, _ h: Int, _ scale: CGFloat, _ space: CGColorSpace, origin: SkinPoint, source: String) {
        guard let full = SkinBitmapDrawing.fullDrawing(scene: scene, context: context, cycle: cycle,
                                                       w, h, scale: scale, space: space, origin: origin),
              let found = SkinBitmapDrawing.difference(image, full) else { return }
        guard found.worst > SkinBitmapDrawing.tolerance else { return }
        differences += 1
        if !reportedDifference {
            reportedDifference = true
            Log.write("Kept pictures differ from a full drawing by \(found.worst) at pixel \(found.x),\(found.y)",
                      level: .warning, source: source)
        }
    }

    /// The skin drawn in full into a new bitmap of `w`×`h` pixels, as a picture draws it (glass as the window's hit
    /// areas); nil when the bitmap cannot be made. Engine access ends at projection.
    static func fullDrawing(of skin: Skin, _ w: Int, _ h: Int, scale: CGFloat, space: CGColorSpace) -> CGContext? {
        let context = SkinRenderContext.of(skin)
        let scene = context.sceneProjector.project(skin, environment: AppSceneEnvironment(
            scale: Double(scale), appearance: skin.host?.environment(for: skin).appearance ?? .light,
            appearanceName: NSAppearance.currentDrawing().name.rawValue), glassSource: .published)
        return fullDrawing(scene: scene, context: context, cycle: skin.updateCount, w, h, scale: scale, space: space)
    }

    static func fullDrawing(scene: WidgetScene, context: SkinRenderContext, cycle: Int, _ w: Int, _ h: Int,
                            scale: CGFloat, space: CGColorSpace, origin: SkinPoint = SkinPoint()) -> CGContext? {
        guard origin.x.isFinite, origin.y.isFinite, let ctx = makeContext(w, h, space) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let runs = scene.drawingRuns
        draw(items: 0..<runs.count, runs, context: context, cycle: cycle, into: ctx, height: h, scale: scale, origin: origin)
        return ctx
    }

    /// How `image` differs from `ctx`'s pixels: the largest difference of one channel, where it is, and how many
    /// pixels differ by more than `tolerance`. Nil when they cannot be compared (another size, no pixels).
    struct Difference: Equatable {
        var worst = 0
        var x = 0
        var y = 0
        var pixels = 0
    }

    static func difference(_ image: CGImage, _ ctx: CGContext) -> Difference? {
        guard image.width == ctx.width, image.height == ctx.height, let space = ctx.colorSpace,
              let copy = makeContext(image.width, image.height, space),
              let b = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        copy.setBlendMode(.copy)
        copy.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let a = copy.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowA = copy.bytesPerRow, rowB = ctx.bytesPerRow, rowBytes = image.width * 4
        var found = Difference()
        for y in 0..<image.height {
            let pa = a + y * rowA, pb = b + y * rowB
            if memcmp(pa, pb, rowBytes) == 0 { continue }
            var x = 0
            while x < rowBytes {
                var pixel = 0
                for c in 0..<4 { pixel = max(pixel, abs(Int(pa[x + c]) - Int(pb[x + c]))) }
                if pixel > tolerance { found.pixels += 1 }
                if pixel > found.worst {
                    found.worst = pixel
                    found.x = x / 4
                    found.y = y
                }
                x += 4
            }
        }
        return found
    }
}

// MARK: - Frames

/// An executor whose work runs on a run loop of its own: the frame producer draws at the end of that run loop's turns.
protocol SkinRunLoopExecutor: SkinExecutor {
    /// The run loop the executor's work runs on (nil before its thread has started).
    var runLoop: CFRunLoop? { get }
}

extension MainSkinExecutor: SkinRunLoopExecutor {
    var runLoop: CFRunLoop? { CFRunLoopGetMain() }
}

extension SkinThreadExecutor: SkinRunLoopExecutor {}

/// A skin's frames (docs/skin-threading.md §7.3, frame delivery E on bitmaps): on the skin's executor, whichever it is,
/// the producer draws the skin with `SkinBitmapDrawing` and presents the picture through its window's `ContentProvider`.
///
/// - The skin asks for a frame when it redraws (`setNeedsFrame`, from `SkinHost.skinNeedsDisplay`). The producer draws at
///   most once per turn of the executor's run loop, at its end: in an observer before the run loop waits (or leaves),
///   ordered before Core Animation's commit, which is where AppKit's display pass drew the view. A thread that never
///   waits also draws once a frame's time has passed since the skin asked.
/// - It draws at the backing scale, in the colour space and with the appearance of the window's facts
///   (`SkinWindowFacts`, which the main thread publishes whenever they change): what the view read from its window.
///   Another scale, colour space or appearance draws the frame again.
/// - It does not draw while the window cannot be seen: before it is shown, while it is ordered out (hidden by a bang,
///   never shown at all as in the headless self-tests, where AppKit never displayed the view either) or covered by
///   other windows. It draws one frame when the window can be seen again: when it is uncovered, if the skin redrew
///   meanwhile; when it is ordered in again, always, and before its occlusion state catches up (AppKit displayed the
///   view then).
/// - The first frame is drawn before the window is first shown (`drawFirstFrame`), whether it can be seen or not.
/// - Once the skin has closed (`stop`) nothing more is drawn: the window fades out with the last frame.
final class SkinFrameProducer {
    /// The pictures, with the ones kept of meters that did not change.
    let drawing = SkinBitmapDrawing()
    let provider: ContentProvider?
    let contentMode: SkinFrameContentMode
    /// The first successful load's selection, not an observed frame rate or a transferable writer permission.
    /// contentMode retains the automatic intent so a replacement runtime resolves its own loaded settings.
    private(set) var loadedAutomaticBackend: SkinLayerFrameBackend?
    /// Requests only cross to main. Main parks the real executor before installing the finished owner root.
    var requestLayerInstallation: (() -> Void)?
    var requestScenePatch: ((SkinScenePatch) -> Void)?
    var publishLayerHitMap: ((SkinHitMap, UInt64, UInt64) -> Void)?
    var requestNativeCompletion: ((SkinNativeStage, SkinNativeStageResult) -> Void)?
    var requestNativeStopRelease: ((SkinNativeStage) -> Void)?
    var requestNativePublicationFinished: ((SkinNativeStage, SkinNativeStageResult) -> Void)?
    var requestNativeRollback: ((SkinNativeStage, SkinNativeStageFailure) -> Void)?
    var requestNativeFrames: (() -> Void)?
    private(set) var nativeFrameFailure: SkinNativeStageFailure?
    private var failedNativeEpoch: SkinNativeStage.Epoch?
    private var pendingNativeStage: SkinNativeStage?
    /// The slot remains occupied until owner release AND main detach have been acknowledged.
    var hasNativeStage: Bool { pendingNativeStage != nil }
    var hasNativeFrameOwner: Bool { pendingNativeStage?.nativeFramesReady == true }
    private var pendingScenePatch: SkinScenePatch?
    private var panelGeneration: UInt64 = 0
    private var presentationGeneration: UInt64 = 0
    private var presentedSize: CGSize?
    private var presentedGlass: [GlassRegion]?
    private var presentedToolTipAreas: [SkinRect]?
    private var hostAcknowledgedGeneration: UInt64 = 0
    private var releaseAfterWriter = false
    private var explicitlyHidden = false
    /// Owner-only notification lets teardown wait for a claimed tree writer without parking either thread.
    var writerReleased: (() -> Void)?
    var hasLayerWriter: Bool { pendingScenePatch != nil }
    private(set) var layerRuntime: LayerRuntime?
    private(set) var layerInstalled = false
    private(set) var layerFailure: LayerFailure?
    private(set) var lastLayerDrawWasOnSkinThread = false
    enum LayerFailure: Equatable {
        case missingProfile, invalidDestination, unsupportedProvider, staleDestination, installDeclined
        case rendering(String)
    }
    enum LayerInstallation { case installed, staleDestination, declined, notReady }
    private struct LayerDestination {
        let size: CGSize
        let scale: CGFloat
        let space: CGColorSpace
        let appearance: String
    }
    private var layerDestination: LayerDestination?
    private var actualSpace: CGColorSpace?
    private var layerInstallRequested = false
    /// The skin, as long as the runtime has it.
    private let skin: () -> Skin?
    private let bitmapCapture: ((CGFloat, String) -> SkinBitmapDrawing.Capture?)?
    private let bitmapValidation: ((SkinBitmapDrawing.Capture, CGContext) -> Bool)?
    enum BitmapResult { case presented(SkinBitmapDrawing.Capture), failed }
    /// Synchronous on the producer's owner, after presentation or a failed bitmap. Callers capture owners weakly.
    var bitmapResult: ((BitmapResult) -> Void)?
    /// Opt-in immutable Main delivery. Without it, bitmap owners keep their direct presentation contract.
    var requestBitmapDelivery: ((SkinBitmapRequest) -> Void)?
    private struct PendingBitmap {
        let delivery: SkinBitmapDelivery
        let capture: SkinBitmapDrawing.Capture
        let began: TimeInterval
        let forShowing: Bool
    }
    private var pendingBitmap: PendingBitmap?
    private var pendingBitmapInvalidation: SkinBitmapInvalidation?
    private var bitmapSerial: UInt64 = 0
    private var bitmapLifecycle: UInt64 = 0
    var hasBitmapDelivery: Bool { pendingBitmap != nil }
    private let workActivity: SkinWorkWatchdog.Activity?

    /// The skin redrew since the last frame (or the window's scale, colour space or appearance changed).
    private(set) var needsFrame = false
    /// When the skin asked for the frame it waits for (the monotonic clock).
    private var askedAt: TimeInterval = 0
    private var isStopped = false
    /// The turns of the executor's run loop it draws in (`SkinFrameTurn`), once started.
    private let turn = Guarded<SkinFrameTurn?>(nil)
    private var isStarted = false

    // From the window's facts.
    private(set) var scale: CGFloat = 2
    private(set) var space: CGColorSpace = SkinFrameProducer.sRGB
    private(set) var appearance = NSAppearance.Name.aqua.rawValue
    private var isOrderedIn = false
    private var isUnoccluded = false
    /// Ordered in since the last turn ended: seen before the occlusion state says so.
    private var justOrderedIn = false
    /// A frame was drawn in this turn (the first frame, right before the window is ordered in).
    private var drewThisTurn = false
    /// The frame presented was drawn for the window's showing (`drawFirstFrame`: the first frame, or one after the
    /// provider let go of what it showed), which has not come yet: when the window is ordered in and the skin has not
    /// redrawn since, it shows that frame (on a skin thread the window's facts come a turn or more after it).
    private var drawnForShowing = false
    /// What the provider was told last.
    private var toldVisible: Bool?
    /// The provider let go of what it showed (`releaseContents`): the window was ordered out for a while.
    private var contentsReleased = false
    /// Counts the times the window stopped being seen; a release scheduled for an earlier time does nothing.
    private var unseenGeneration = 0
    /// Where the producer runs (`start(on:)`): the release after `releaseDelay` is scheduled there.
    private weak var executor: SkinExecutor?
    /// Releases of the kept pictures, and of the provider's contents, since the start (tests).
    private(set) var releases = (pictures: 0, contents: 0)

    /// How long a window that cannot be seen keeps its kept pictures (and, ordered out, its frame): hidden by a bang,
    /// never shown, covered for a while. The next frame after that is drawn in full.
    static var releaseDelay: TimeInterval = 10

    /// Frames drawn and presented (tests).
    private(set) var framesDrawn = 0
    /// Turns that ended with a frame wanted but not drawn because the window could not be seen (tests).
    private(set) var framesSkipped = 0
    /// Elapsed frame work, total and longest (on the executor). Layer handoff adds its bounded wait; this is not CPU.
    /// A claimed main transaction can finish later; its complete presentation latency is recorded by the ack.
    private(set) var drawingTime: TimeInterval = 0
    private(set) var longestFrame: TimeInterval = 0
    /// What `FrameTimingLog` reports next: when each frame was presented, and the longest drawing, since the last report.
    private var timing = FrameTimingLog.Window()

    /// How long a turn may run before a frame asked for in it is drawn anyway (a thread that never waits).
    static let frameInterval: TimeInterval = 1.0 / 60
    /// Before Core Animation's commit (2000000), after the run loop's other work.
    static let observerOrder: CFIndex = 1_999_000
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `provider` nil: a runtime without a window (tests), which draws nothing.
    init(provider: ContentProvider?, skin: @escaping () -> Skin?, contentMode: SkinFrameContentMode = .bitmap,
         workActivity: SkinWorkWatchdog.Activity? = nil) {
        self.provider = provider
        self.skin = skin
        bitmapCapture = nil
        bitmapValidation = nil
        self.contentMode = contentMode
        self.workActivity = workActivity
    }

    /// The independent compatibility owner currently supports bitmap presentation only. Layer paths still require
    /// their original Skin preparation and writer lifecycle; this initializer cannot select either of them.
    init(provider: ContentProvider?, bitmapCapture: @escaping (CGFloat, String) -> SkinBitmapDrawing.Capture?,
         bitmapValidation: ((SkinBitmapDrawing.Capture, CGContext) -> Bool)? = nil) {
        self.provider = provider
        skin = { nil }
        self.bitmapCapture = bitmapCapture
        self.bitmapValidation = bitmapValidation
        contentMode = .bitmap
        workActivity = nil
    }

    deinit {
        turn.current?.remove(self)
    }

    /// Called on the owner after successful Skin.load, before its first update. SkinSettings already normalized
    /// every negative Update to -1 and every nonnegative one to at least 16 ms. No later sample changes the backend.
    func selectLoadedBackend(updateMilliseconds: Int) {
        guard loadedAutomaticBackend == nil,
              case let .layers(partition, _, .automatic(bytes)) = contentMode else { return }
        precondition(skin()?.executor.isCurrent == true)
        if updateMilliseconds >= 0 && updateMilliseconds < 100 { loadedAutomaticBackend = .c }
        else if partition == .single { loadedAutomaticBackend = .nativeSingle(maximumCallbackBitmapBytes: bytes) }
        else { loadedAutomaticBackend = .nativeComponents(maximumCallbackBitmapBytes: bytes) }
    }

    private var shouldRequestNativeFrames: Bool {
        guard contentMode.requestsNativeFrames else { return false }
        if case .layers(_, _, .automatic) = contentMode {
            return loadedAutomaticBackend != nil && loadedAutomaticBackend != .c
        }
        return true
    }

    /// Starts drawing at the end of `executor`'s turns, with the other producers of its run loop (`SkinFrameTurn`).
    /// Any thread.
    func start(on executor: SkinExecutor) {
        guard provider != nil, !isStarted else { return }
        isStarted = true
        self.executor = executor
        if let executor = executor as? SkinRunLoopExecutor, let loop = executor.runLoop {
            join(SkinFrameTurn.on(loop))
        } else {
            // Its work runs on its run loop: it joins that one's turns there.
            executor.async { [weak self] in self?.join(SkinFrameTurn.on(CFRunLoopGetCurrent())) }
        }
    }

    private func join(_ turn: SkinFrameTurn) {
        let joined = self.turn.access { current -> Bool in
            guard current == nil, !isStopped else { return false }
            current = turn
            return true
        }
        if joined { turn.add(self) }
    }

    /// The skin closed: no more frames.
    func stop() {
        cancelBitmapDelivery()
        isStopped = true
        let endedNativeStage = stopNativeStage()
        needsFrame = false
        turn.access { current in
            current?.remove(self)
            current = nil
        }
        layerInstallRequested = false
        if let patch = pendingScenePatch {
            _ = patch.content.reclaim(.invalidated)
            finishScenePatch(patch)
        }
        if pendingScenePatch == nil, let layerRuntime, layerRuntime.state != .closed {
            do { try layerRuntime.beginClose() }
            catch { layerFailure = .rendering(String(describing: error)) }
        }
        if endedNativeStage { writerReleased?() }
    }

    /// A Desk bitmap failed or closed. It must not leave an earlier scene visible or reuse its pictures on recovery.
    /// Layer publication and legacy owners keep their own existing release and last-good-frame contracts.
    func clearBitmapContents() {
        precondition(contentMode == .bitmap)
        cancelBitmapDelivery()
        needsFrame = false
        drawnForShowing = false
        drawing.releaseKept()
        if requestBitmapDelivery != nil { requestBitmapClear() }
        else { provider?.releaseContents() }
        contentsReleased = true
    }

    /// Owner only. A claimed frame keeps its capture until Main finishes; no owner work waits for that ACK.
    private func cancelBitmapDelivery(cancelClear: Bool = true) {
        guard requestBitmapDelivery != nil else { return }
        bitmapLifecycle &+= 1
        if let pendingBitmap, pendingBitmap.delivery.cancel() { self.pendingBitmap = nil }
        if cancelClear {
            pendingBitmapInvalidation?.cancel()
            pendingBitmapInvalidation = nil
        }
    }

    private func requestBitmapClear() {
        guard let requestBitmapDelivery else { return }
        pendingBitmapInvalidation?.cancel()
        bitmapSerial &+= 1
        let clear = SkinBitmapInvalidation(panelGeneration: panelGeneration, serial: bitmapSerial,
                                          lifecycle: bitmapLifecycle)
        pendingBitmapInvalidation = clear
        requestBitmapDelivery(.clear(clear))
    }

    /// FIFO ACK after the Main transaction. Serial identity permits redraw of the same scene generation after
    /// releasing pixels; an invalidated or stopped delivery never advances owner presentation metadata.
    func finishBitmapDelivery(_ delivery: SkinBitmapDelivery) {
        precondition(executor?.isCurrent == true)
        guard let pending = pendingBitmap, pending.delivery === delivery else { return }
        let accepted: Bool
        switch delivery.state {
        case .pending, .applying: return
        case .finished(let value): accepted = value
        case .cancelled: accepted = false
        }
        pendingBitmap = nil
        let forShowing = pending.forShowing
        defer {
            if !isStopped, needsFrame {
                executor?.async { [weak self] in
                    guard let self else { return }
                    if forShowing && (framesDrawn == 0 || contentsReleased) { drawFirstFrame() }
                    else { runLoopTurn(.beforeWaiting) }
                }
            }
        }
        guard !isStopped, delivery.lifecycle == bitmapLifecycle,
              delivery.panelGeneration == panelGeneration else { return }
        if accepted {
            recordPresented(began: pending.began, source: pending.capture.source)
            if pending.forShowing && !isOrderedIn { drawnForShowing = true }
            bitmapResult?(.presented(pending.capture))
        } else {
            setNeedsFrame()
        }
    }

    func finishBitmapInvalidation(_ invalidation: SkinBitmapInvalidation) {
        precondition(executor?.isCurrent == true)
        guard pendingBitmapInvalidation === invalidation else { return }
        switch invalidation.state {
        case .pending, .applying: return
        case .finished(accepted: false): return // Keep the clear owed, but retry only when new facts arrive.
        case .finished(accepted: true), .cancelled: pendingBitmapInvalidation = nil
        }
    }

    /// Whether the window can be seen, as far as its facts tell.
    var canBeSeen: Bool { isOrderedIn && (isUnoccluded || justOrderedIn) }

    /// The skin redrew: a frame at the end of the turn, if the window can be seen then.
    func setNeedsFrame() {
        guard !isStopped else { return }
        // A ready persistent native owner samples the new frame before deciding whether its host is unchanged.
        // Old explicit stages retain their source-cycle cancellation rule.
        if pendingNativeStage?.nativeFramesReady != true { cancelNativeStage() }
        if !needsFrame { askedAt = ProcessInfo.processInfo.systemUptime }
        needsFrame = true
    }

    /// The window's facts, as the runtime's window model took them.
    func take(_ facts: SkinWindowFacts?) {
        guard let facts, !isStopped else { return }
        let destinationChanged = panelGeneration != facts.panelGeneration || actualSpace != facts.colorSpace
            || (facts.scale > 0 && facts.scale.isFinite && facts.scale != scale) || facts.appearance != appearance
        let hadBitmapDelivery = pendingBitmap != nil
        let hadBitmapInvalidation = pendingBitmapInvalidation != nil
        if destinationChanged { cancelBitmapDelivery() }
        explicitlyHidden = facts.settings.hidden
        if explicitlyHidden { cancelNativeStage() }
        var redraw = false
        if panelGeneration != facts.panelGeneration {
            panelGeneration = facts.panelGeneration
            if contentMode.usesLayers { redraw = true }
        }
        if actualSpace != facts.colorSpace {
            actualSpace = facts.colorSpace
            if contentMode.usesLayers { redraw = true }
        }
        if facts.scale != scale, facts.scale > 0, facts.scale.isFinite {
            scale = facts.scale
            provider?.setScale(scale)
            redraw = true
        }
        let space = facts.colorSpace ?? SkinFrameProducer.sRGB
        if space != self.space {
            self.space = space
            redraw = true
        }
        if facts.appearance != appearance {
            appearance = facts.appearance
            redraw = true
        }
        if facts.isOrderedIn && !isOrderedIn {
            justOrderedIn = true
            // AppKit displayed the view when its window was ordered in; not when the first frame, drawn for this
            // showing, is still what the skin looks like (drawn right now, or on an earlier turn of a skin thread).
            if contentsReleased || (!drewThisTurn && !(drawnForShowing && !needsFrame)) { redraw = true }
            drawnForShowing = false
        }
        isOrderedIn = facts.isOrderedIn
        isUnoccluded = facts.isVisible
        if requestBitmapDelivery != nil, hadBitmapInvalidation,
           destinationChanged || pendingBitmapInvalidation?.state == .finished(accepted: false) { requestBitmapClear() }
        // Before the first frame there is nothing to draw again: the skin's first redraw asks for it.
        if redraw && (framesDrawn > 0 || contentMode.usesLayers || hadBitmapDelivery) { setNeedsFrame() }
        if destinationChanged, requestBitmapDelivery != nil, framesDrawn > 0 || hadBitmapDelivery { setNeedsFrame() }
        let seen = canBeSeen
        if seen != toldVisible {
            toldVisible = seen
            provider?.setVisible(seen)
            if !seen { scheduleRelease() }
        }
    }

    /// The window stopped being seen: after `releaseDelay`, if it still cannot be seen, the kept pictures go, and
    /// what the provider shows when the window is ordered out.
    private func scheduleRelease() {
        unseenGeneration += 1
        let generation = unseenGeneration
        executor?.async(after: SkinFrameProducer.releaseDelay) { [weak self] in
            guard let self, generation == self.unseenGeneration else { return }
            self.releaseUnseen()
        }
    }

    /// Lets go of what a window that cannot be seen does not need (tests call it at once).
    func releaseUnseen() {
        guard !isStopped, !canBeSeen else { return }
        let hadBitmapDelivery = pendingBitmap != nil
        let owedBitmapFrame = hadBitmapDelivery && !contentsReleased
        cancelBitmapDelivery(cancelClear: false)
        if owedBitmapFrame { setNeedsFrame() }
        cancelNativeStage()
        if drawing.keepsPictures {
            drawing.releaseKept()
            releases.pictures += 1
        }
        if !isOrderedIn && (framesDrawn > 0 || hadBitmapDelivery) && !contentsReleased, let provider {
            guard pendingScenePatch == nil, layerRuntime?.nativePublicationHoldsWriter != true else {
                releaseAfterWriter = true
                return
            }
            if let layerRuntime {
                do { try layerRuntime.setVisible(false) }
                catch { layerFailure = .rendering(String(describing: error)); return }
                (provider as? LayerContentProvider)?.releaseLayerFrame()
            }
            if requestBitmapDelivery != nil { requestBitmapClear() }
            else { provider.releaseContents() }
            contentsReleased = true
            releases.contents += 1
        }
    }

    /// The window is about to be shown for the first time: the first frame now, whether the window can be seen yet or
    /// not (nothing when a frame was presented already, unless the provider let go of it: then this frame, for the
    /// window shown again).
    func drawFirstFrame() {
        guard framesDrawn == 0 || contentsReleased, !isStopped else { return }
        let before = framesDrawn
        draw(forShowing: true)
        if framesDrawn > before { drawnForShowing = true }
    }

    /// A turn of the executor's run loop ends (or, `beforeTimers`, the next one starts). The run-loop observer calls it
    /// (and the self-tests).
    func runLoopTurn(_ activity: CFRunLoopActivity) {
        guard !isStopped else { return }
        if activity == .beforeTimers {
            // A thread that has not waited for a frame's time.
            guard needsFrame, ProcessInfo.processInfo.systemUptime - askedAt >= SkinFrameProducer.frameInterval
            else { return }
            drawIfSeen()
            return
        }
        drawIfSeen()
        justOrderedIn = false
        drewThisTurn = false
    }

    private func drawIfSeen() {
        guard needsFrame else { return }
        // Layer resize/glass no longer posts ahead of the frame. A failed Loading frame must be able to recover
        // before orderIn; ordinary unseen/hidden live skins still do no drawing.
        let loading = contentMode.usesLayers && !layerInstalled && framesDrawn == 0 && !explicitlyHidden
        guard canBeSeen || loading else {
            framesSkipped += 1
            return
        }
        draw()
    }

    /// Draws the skin as it is now and presents it; a picture that cannot be made keeps the last one on screen.
    private func draw(forShowing: Bool = false) {
        // Applying can outlive the deadline. Keep a single dirty request, never overwrite the exported preparation.
        guard pendingScenePatch == nil, pendingBitmap == nil else { return }
        let nativeStage: SkinNativeStage?
        if let stage = pendingNativeStage, stage.nativeFramesReady,
           layerRuntime?.nativePublicationHoldsWriter == true, !stage.hasPublicationRollback,
           !stage.hasOwnerRelease, !stage.request.isCancelled {
            nativeStage = stage
        } else {
            nativeStage = nil
        }
        if nativeStage == nil, layerRuntime?.nativePublicationHoldsWriter == true {
            cancelNativeStage()
            return // Keep needsFrame and host debt. Only the matching Main rollback ack permits new C writes.
        }
        if nativeStage == nil {
            cancelNativeStage()
            needsFrame = false
        }
        guard let provider else { return }
        let skin = skin()
        guard skin != nil || bitmapCapture != nil else { return }
        workActivity?.begin(.drawing)
        defer { workActivity?.end() }
        let size = skin.map { SkinRuntime.windowSize(width: $0.width, height: $0.height) }
        let (scale, space, appearance, drawing) = (self.scale, self.space, self.appearance, self.drawing)
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            let took = ProcessInfo.processInfo.systemUptime - began
            drawingTime += took
            longestFrame = max(longestFrame, took)
        }
        if let nativeStage, let skin, let size {
            drawNativeFrame(nativeStage, skin: skin, size: size, began: began)
            return
        }
        var picture: CGImage?
        if case let .layers(partition, budget, _) = contentMode {
            guard let skin, let size else { return }
            drawLayerContent(skin, size: size, partition: partition, budget: budget, began: began)
            return
        }
        // The drawing appearance AppKit set while the view drew. Both owners use this same bitmap path.
        var source = ""
        var captured: SkinBitmapDrawing.Capture?
        SkinFrameProducer.withAppearance(appearance) {
            let capture: SkinBitmapDrawing.Capture?
            if let skin, let size {
                capture = SkinBitmapDrawing.capture(skin, size: size, scale: scale, appearance: appearance)
            } else {
                capture = bitmapCapture?(scale, appearance)
            }
            guard let capture else { return }
            captured = capture
            source = capture.source
            picture = drawing.picture(capture, scale: scale, space: space, beforeDrawing: bitmapValidation.map { validate in
                { ctx in validate(capture, ctx) }
            })
        }
        guard let picture else {
            if requestBitmapDelivery != nil {
                cancelBitmapDelivery()
                drawing.releaseKept()
                requestBitmapClear()
                contentsReleased = true
            }
            bitmapResult?(.failed)
            return
        }
        let frame = SkinFrame(image: picture, scale: scale)
        if let requestBitmapDelivery, let captured {
            pendingBitmapInvalidation?.cancel()
            pendingBitmapInvalidation = nil
            bitmapSerial &+= 1
            let delivery = SkinBitmapDelivery(frame: frame, scene: captured.scene, origin: captured.origin,
                space: space, appearance: appearance, panelGeneration: panelGeneration,
                serial: bitmapSerial, lifecycle: bitmapLifecycle)
            pendingBitmap = PendingBitmap(delivery: delivery, capture: captured, began: began, forShowing: forShowing)
            requestBitmapDelivery(.frame(delivery))
            return
        }
        provider.present(frame)
        recordPresented(began: began, source: source)
        if let captured { bitmapResult?(.presented(captured)) }
    }

    private func recordPresented(began: TimeInterval, source: String) {
        framesDrawn += 1
        drewThisTurn = true
        drawnForShowing = false
        contentsReleased = false
        if FrameTimingLog.period > 0 {
            let now = ProcessInfo.processInfo.systemUptime
            timing.note(presentedAt: now, drawing: now - began)
            if let report = timing.report(at: now, every: FrameTimingLog.period) {
                Log.write("Frames: \(report)", source: source)
            }
        }
    }

    private func drawLayerContent(_ skin: Skin, size: CGSize, partition: LayerRuntime.Partition, budget: Int, began: TimeInterval) {
        guard let executor, executor.isCurrent, provider is LayerContentProvider else {
            layerFailure = .unsupportedProvider
            return
        }
        guard (provider as? LayerContentProvider)?.acceptsLayerFrames == true else {
            layerFailure = .installDeclined
            return
        }
        guard let space = actualSpace else { layerFailure = .missingProfile; return }
        let w = (size.width * scale).rounded(.up), h = (size.height * scale).rounded(.up)
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              w.isFinite, h.isFinite, w > 0, h > 0,
              w <= CGFloat(Rasterizer.maximumDimension), h <= CGFloat(Rasterizer.maximumDimension),
              let window = InkBounds.DeviceRect(minX: 0, minY: 0, maxX: Int(w), maxY: Int(h)) else {
            layerFailure = .invalidDestination
            return
        }
        do {
            if layerRuntime == nil { layerRuntime = try LayerRuntime(executor: executor, maximumOwnedBitmapBytes: budget) }
            guard let layerRuntime else { return }
            if layerRuntime.state == .hidden { try layerRuntime.setVisible(true) }
            let context = SkinRenderContext.of(skin)
            let environment = AppSceneEnvironment(scale: Double(scale),
                appearance: skin.host?.environment(for: skin).appearance ?? .light, appearanceName: appearance)
            var preparation: LayerRuntime.Preparation?
            var capturedScene: WidgetScene?
            try SkinFrameProducer.withAppearanceThrowing(appearance) {
                let prepared = try prepareLayerScene(skin, context: context, environment: environment, space: space)
                let scene = prepared.scene
                capturedScene = scene
                preparation = try layerRuntime.prepare(prepared, in: window, scale: scale, colorSpace: space,
                    partition: partition, context: context.drawing, cycle: skin.updateCount, glass: .hitArea,
                    forcePresentation: !layerInstalled || size != presentedSize || scene.glass != presentedGlass
                        || scene.hitMap.toolTipAreas != presentedToolTipAreas)
            }
            guard let scene = capturedScene else { return }
            let (generation, overflow) = presentationGeneration.addingReportingOverflow(1)
            guard !overflow else { throw LayerRuntime.Failure.sequenceOverflow }
            presentationGeneration = generation
            layerDestination = LayerDestination(size: size, scale: scale, space: space, appearance: appearance)
            let frame: LayerRuntime.Frame
            switch preparation ?? .suppressed {
            case .ready(let prepared):
                let needsMain = !layerInstalled || size != presentedSize || scene.glass != presentedGlass
                    || scene.hitMap.toolTipAreas != presentedToolTipAreas
                if needsMain {
                    let patch = SkinScenePatch(content: try layerRuntime.transfer(prepared),
                        panelGeneration: panelGeneration, generation: generation, size: size, began: began,
                        glass: scene.glass, hitMap: scene.hitMap)
                    pendingScenePatch = patch
                    if let requestScenePatch { requestScenePatch(patch) }
                    else { _ = patch.content.reclaim(.invalidated) }
                    if !Thread.isMainThread { _ = patch.content.waitForMain() }
                    else if patch.content.state == .pending { _ = patch.content.reclaim(.invalidated) }
                    finishScenePatch(patch)
                    return
                }
                frame = try layerRuntime.commit(prepared)
                lastLayerDrawWasOnSkinThread = SkinThreadExecutor.isSkinThread
            case .unchanged(let completed): frame = completed
            case .suppressed: return
            }
            presentedSize = size
            presentedGlass = scene.glass
            presentedToolTipAreas = scene.hitMap.toolTipAreas
            layerFailure = nil
            let wasReleased = contentsReleased
            if layerInstalled, let provider = provider as? LayerContentProvider,
               provider.presentedLayerRoot(layerRuntime.root, frame: frame) {
                publishLayerHitMap?(scene.hitMap, generation, panelGeneration)
                recordPresented(began: began, source: skin.config)
                if wasReleased { requestLayerInstallation?() }
                if shouldRequestNativeFrames { requestNativeFrames?() }
            } else if !layerInstallRequested {
                layerInstallRequested = true
                requestLayerInstallation?()
            }
        } catch {
            layerFailure = .rendering(String(describing: error))
        }
    }

    /// Shared pure preparation: C and native frames use the same canonical mapping, actual space and scene.
    private func prepareLayerScene(_ skin: Skin, context: SkinRenderContext, environment: AppSceneEnvironment,
                                   space: CGColorSpace) throws -> SceneInkCandidates {
        let scene = context.sceneProjector.project(skin, environment: environment, glassSource: .published)
        guard let bitmap = SkinBitmapDrawing.makeContext(1, 1, space) else {
            throw Rasterizer.Failure.resourceFailure("Cannot prepare the owned destination mapping")
        }
        bitmap.translateBy(x: 0, y: 1)
        bitmap.scaleBy(x: scale, y: -scale)
        let target = DrawTarget.prepareOwnedBitmap(bitmap, glass: .hitArea)
        guard target.userToDevice == CGAffineTransform(scaleX: scale, y: scale),
              target.colorSpace.map({ CFEqual($0, space) }) == true else { throw Rasterizer.Failure.invalidMapping }
        return ScenePreparer.prepare(scene, context: context.drawing, target: target)
    }

    /// Only the explicit native backend asks for an attachment. No default/C/Main shadow scene or E allocation.
    func automaticNativeFrameRequest() -> SkinNativeStageRequest? {
        guard contentMode.requestsNativeFrames else { return nil }
        let automatic: Bool
        if case .layers(_, _, .automatic) = contentMode {
            automatic = true
            guard let loadedAutomaticBackend else { nativeFrameFailure = .notReady; return nil }
            guard loadedAutomaticBackend != .c else { return nil }
        } else { automatic = false }
        guard let budget = contentMode.nativeFrameBudget, var partition = contentMode.nativeFramePartition else {
            nativeFrameFailure = .unsupportedMode
            return nil
        }
        guard let worker = executor as? SkinThreadExecutor, worker.isOnThread, !Thread.isMainThread else {
            nativeFrameFailure = .unsupportedExecutor
            return nil
        }
        guard
              !isStopped, !explicitlyHidden, !needsFrame, !hasNativeStage, !hasLayerWriter,
              layerInstalled, let destination = layerDestination, let actualSpace else { return nil }
        if automatic, layerRuntime?.currentFrame?.contents.isEmpty == true { return nil }
        if partition == .acceptedComponents {
            guard let frame = layerRuntime?.currentFrame,
                  let mode = try? LayerContentBuilder.validateGeometry(frame.plan) else {
                nativeFrameFailure = .notReady
                return nil
            }
            switch mode {
            case .components where frame.fallback == nil: break
            case .single where automatic && frame.fallback != nil:
                // Unknown ink stays the accepted typed Single C fallback, never an approved component plan.
                partition = .single
            default:
                // Explicit components keep their original refusal; only automatic can follow a real Single fallback.
                nativeFrameFailure = .notReady
                return nil
            }
        }
        if let failedNativeEpoch,
           failedNativeEpoch.panelGeneration == panelGeneration, failedNativeEpoch.size == destination.size,
           failedNativeEpoch.scale == scale, failedNativeEpoch.appearance == appearance,
           CFEqual(failedNativeEpoch.colorSpace, actualSpace) { return nil }
        return SkinNativeStageRequest(maximumCallbackBitmapBytes: budget, nativePartition: partition,
                                      continuesFrames: true, completion: { _ in })
    }

    func rejectAutomaticNativeFrames(_ request: SkinNativeStageRequest, failure: SkinNativeStageFailure) {
        precondition(executor?.isCurrent == true)
        guard request.continuesFrames else { return }
        nativeFrameFailure = failure
        if case .rendering = failure, let destination = layerDestination, let actualSpace {
            failedNativeEpoch = SkinNativeStage.Epoch(panelGeneration: panelGeneration, size: destination.size,
                scale: scale, colorSpace: actualSpace, appearance: appearance, presentationGeneration: presentationGeneration)
        }
    }

    /// The Main result is consumed once on the owner before ordinary native drawing can start.
    func enableNativeFrames(_ stage: SkinNativeStage) {
        precondition(executor?.isCurrent == true)
        guard !stage.nativeFramesReady else { return }
        guard stage.request.continuesFrames, nativeStageIsCurrent(stage), let layerRuntime, let skin = skin() else {
            if pendingNativeStage === stage { cancelNativeStage() }
            return
        }
        do {
            try layerRuntime.enableNativeFrames(stage.attachment, cycle: skin.updateCount)
            stage.nativeFramesReady = true
            nativeFrameFailure = nil
        } catch { requestNativeRollback?(stage, .rendering(String(describing: error))) }
    }

    /// Ordinary native commits never touch C or host values. Host changes wait for matching Main rollback first.
    private func drawNativeFrame(_ stage: SkinNativeStage, skin: Skin, size: CGSize, began: TimeInterval) {
        guard let worker = executor as? SkinThreadExecutor, worker.isOnThread, !Thread.isMainThread,
              let layerRuntime, let actualSpace, !isStopped, !explicitlyHidden else {
            cancelNativeStage()
            return
        }
        guard stage.epoch.panelGeneration == panelGeneration, stage.epoch.size == size,
              stage.epoch.scale == scale, stage.epoch.appearance == appearance,
              CFEqual(stage.epoch.colorSpace, actualSpace) else { cancelNativeStage(); return }
        do {
            let context = SkinRenderContext.of(skin)
            let environment = AppSceneEnvironment(scale: Double(scale),
                appearance: skin.host?.environment(for: skin).appearance ?? .light, appearanceName: appearance)
            var native: LayerRuntime.NativeFrame?
            try Self.withAppearanceThrowing(appearance) {
                let prepared = try prepareLayerScene(skin, context: context, environment: environment, space: actualSpace)
                guard prepared.scene.glass == stage.attachment.sourceGlass,
                      prepared.scene.hitMap == stage.attachment.sourceHitMap else {
                    throw LayerRuntime.NativeStageFailure.staleSource
                }
                native = try layerRuntime.displayNativeFrame(stage.attachment, prepared: prepared,
                    context: context.drawing, cycle: skin.updateCount, glass: .hitArea)
            }
            guard native != nil else { return }
            needsFrame = false
            layerFailure = nil
            lastLayerDrawWasOnSkinThread = SkinThreadExecutor.isSkinThread
            recordPresented(began: began, source: skin.config)
        } catch LayerRuntime.NativeStageFailure.staleSource {
            cancelNativeStage()
        } catch {
            let failure = SkinNativeStageFailure.rendering(String(describing: error))
            nativeFrameFailure = failure
            failedNativeEpoch = stage.epoch
            if !stage.rollbackQueued {
                stage.rollbackQueued = true
                requestNativeRollback?(stage, failure)
            }
        }
    }

    /// Acknowledgment is always processed on the actual owner, including after close. Duplicate/late acks are inert.
    func finishScenePatch(_ patch: SkinScenePatch) {
        precondition(executor?.isCurrent == true)
        if patch.panelGeneration == panelGeneration, patch.generation > hostAcknowledgedGeneration {
            switch patch.hostAcknowledgment {
            case .none: break
            case .controls, .complete:
                hostAcknowledgedGeneration = patch.generation
                presentedSize = patch.size
                presentedGlass = patch.glass
                if patch.hostAcknowledgment == .complete { presentedToolTipAreas = patch.hitMap.toolTipAreas }
            }
        }
        guard pendingScenePatch?.content === patch.content, let layerRuntime else { return }
        do {
            guard let result = try layerRuntime.finish(patch.content, commitReclaimed: !isStopped) else { return }
            pendingScenePatch = nil
            switch result {
            case .submitted(let frame):
                lastLayerDrawWasOnSkinThread = SkinThreadExecutor.isSkinThread
                layerFailure = nil
                if patch.content.state == .appliedByMain {
                    layerInstalled = true
                    layerInstallRequested = false
                    if !isStopped { recordPresented(began: patch.began, source: skin()?.config ?? "") }
                } else if !isStopped {
                    // A reclaimed first frame still requires main attachment; a late patch only updates glass/size.
                    if layerInstalled, let provider = provider as? LayerContentProvider,
                       provider.presentedLayerRoot(layerRuntime.root, frame: frame) {
                        recordPresented(began: patch.began, source: skin()?.config ?? "")
                    } else if !layerInstallRequested {
                        layerInstallRequested = true
                        requestLayerInstallation?()
                    }
                }
            case .suppressed:
                if !isStopped { layerFailure = .staleDestination; setNeedsFrame() }
            case .unchanged: break
            }
            if isStopped, layerRuntime.state != .closed { try layerRuntime.beginClose() }
            else if needsFrame { executor?.async { [weak self] in self?.runLoopTurn(.beforeWaiting) } }
            writerReleased?()
            if !isStopped, !needsFrame, shouldRequestNativeFrames { requestNativeFrames?() }
            if releaseAfterWriter { releaseAfterWriter = false; releaseUnseen() }
        } catch { layerFailure = .rendering(String(describing: error)) }
    }

    /// Main, with a real exclusive lease. Readiness is checked against the CURRENT window, not a queued request's
    /// old panel or facts sequence. Moving the same provider to another panel cannot install for the old destination.
    func installLayerContent(for facts: SkinWindowFacts, size: CGSize) -> LayerInstallation {
        guard Thread.isMainThread, let executor, executor.isCurrent, !isStopped,
              let provider = provider as? LayerContentProvider, let layerRuntime, let frame = layerRuntime.currentFrame,
              let destination = layerDestination, pendingScenePatch == nil else { return .notReady }
        guard let space = facts.colorSpace, CFEqual(destination.space, space), destination.scale == facts.scale,
              destination.appearance == facts.appearance, destination.size == size else {
            layerFailure = .staleDestination
            layerInstallRequested = false
            setNeedsFrame()
            return .staleDestination
        }
        if layerInstalled {
            return provider.hasLayerFrame ? .installed : .declined
        }
        guard provider.installLayerRoot(layerRuntime.root, frame: frame, executor: executor) else {
            layerFailure = .installDeclined
            layerInstallRequested = false
            return .declined
        }
        layerInstalled = true
        layerInstallRequested = false
        layerFailure = nil
        // This is the main attachment acknowledgment, not additional drawing time or worker CPU work. The actual
        // drawing duration is accounted by draw() on its owner; waiting for installation is not counted there.
        recordPresented(began: ProcessInfo.processInfo.systemUptime, source: skin()?.config ?? "")
        drawnForShowing = true
        return .installed
    }

    /// Called only for an explicit request, on the physical worker after C acceptance. Reuses the accepted scene
    /// provenance; bitmap/Main paths cannot allocate an E owner, and ordinary C frames never call this method.
    func prepareNativeStage(_ request: SkinNativeStageRequest) throws -> SkinNativeStage {
        guard contentMode.usesLayers else { throw SkinNativeStageFailure.unsupportedMode }
        guard let executor = executor as? SkinThreadExecutor, executor.isCurrent, executor.isOnThread,
              !Thread.isMainThread else { throw SkinNativeStageFailure.unsupportedExecutor }
        guard pendingNativeStage == nil else { throw SkinNativeStageFailure.busy }
        guard !isStopped, !explicitlyHidden, !needsFrame, layerInstalled, pendingScenePatch == nil,
              let provider = provider as? LayerContentProvider, provider.hasLayerFrame,
              let layerRuntime, let destination = layerDestination, let actualSpace, let skin = skin(),
              destination.scale == scale, destination.appearance == appearance,
              CFEqual(destination.space, actualSpace) else { throw SkinNativeStageFailure.notReady }
        let attachment: LayerRuntime.NativeStage
        do {
            attachment = try layerRuntime.prepareNativeStage(maximumCallbackBitmapBytes: request.maximumCallbackBitmapBytes,
                                                             cycle: skin.updateCount, supportsFrames: request.continuesFrames,
                                                             partition: request.nativePartition)
        } catch LayerRuntime.NativeStageFailure.busy { throw SkinNativeStageFailure.busy }
        catch LayerRuntime.NativeStageFailure.notReady { throw SkinNativeStageFailure.notReady }
        let stage = SkinNativeStage(attachment: attachment, provider: provider,
            epoch: SkinNativeStage.Epoch(panelGeneration: panelGeneration, size: destination.size,
                scale: destination.scale, colorSpace: actualSpace, appearance: destination.appearance,
                presentationGeneration: presentationGeneration), request: request)
        pendingNativeStage = stage
        return stage
    }

    /// Main only inside an actual exclusive lease; both the captured scene and CURRENT host facts must still match.
    func attachNativeStage(_ stage: SkinNativeStage, facts: SkinWindowFacts, size: CGSize) -> Bool {
        precondition(Thread.isMainThread && executor?.isCurrent == true)
        guard nativeStageIsCurrent(stage), stage.epoch.matches(facts, size: size), let executor, let layerRuntime,
              stage.provider.attachNativeStage(stage.attachment, executor: executor) else { return false }
        do { try layerRuntime.attachedNativeStage(stage.attachment); return true }
        catch { return false }
    }

    func nativeStageIsCurrent(_ stage: SkinNativeStage) -> Bool {
        precondition(executor?.isCurrent == true)
        guard pendingNativeStage === stage, !stage.request.isCancelled, !isStopped, !explicitlyHidden, !needsFrame,
              !stage.hasOwnerRelease, !stage.hasPublicationRollback,
              pendingScenePatch == nil, layerInstalled, stage.provider.hasLayerFrame,
              stage.epoch.panelGeneration == panelGeneration,
              stage.epoch.presentationGeneration == presentationGeneration,
              let destination = layerDestination, let actualSpace, let skin = skin(),
              destination.size == stage.epoch.size, destination.scale == stage.epoch.scale,
              destination.appearance == stage.epoch.appearance, CFEqual(actualSpace, stage.epoch.colorSpace),
              layerRuntime?.nativeStageIsCurrent(stage.attachment, cycle: skin.updateCount) == true else { return false }
        return true
    }

    /// The attachment ack queues this next physical worker transaction. Unexpected native callbacks remain strict
    /// failures, distinct from C presentation failures; no image is installed or C statistic incremented here.
    func displayNativeStage(_ stage: SkinNativeStage) {
        precondition(executor?.isCurrent == true)
        guard pendingNativeStage === stage, !stage.completionQueued else { return }
        let result: SkinNativeStageResult
        do {
            guard let executor = executor as? SkinThreadExecutor, executor.isOnThread, !Thread.isMainThread else {
                throw SkinNativeStageFailure.unsupportedExecutor
            }
            guard nativeStageIsCurrent(stage), let layerRuntime, let skin = skin() else {
                throw SkinNativeStageFailure.cancelled
            }
            var observation: ELayerContent.Observation?
            try Self.withAppearanceThrowing(stage.epoch.appearance) {
                observation = try layerRuntime.displayNativeStage(stage.attachment, cycle: skin.updateCount)
            }
            guard let observation else { throw SkinNativeStageFailure.notReady }
            result = .success(SkinNativeStageObservation(sourceSequence: stage.attachment.sourceSequence,
                native: observation, drewOnPhysicalOwner: executor.isOnThread && SkinThreadExecutor.isSkinThread))
        } catch let failure as SkinNativeStageFailure { result = .failure(failure) }
        catch { result = .failure(.rendering(String(describing: error))) }
        queueNativeCompletion(stage, result)
    }

    private func cancelNativeStage() {
        guard let stage = pendingNativeStage else { return }
        stage.request.cancel()
        if stage.request.publishesContent, layerRuntime?.nativePublicationHoldsWriter == true {
            guard !stage.rollbackQueued else { return }
            stage.rollbackQueued = true
            requestNativeRollback?(stage, .cancelled)
            return
        }
        queueNativeCompletion(stage, .failure(.cancelled))
    }

    /// Main calls through authentic owner access before its host switch. This freezes only C tree mutation;
    /// subsequent logic turns still coalesce needsFrame, without preparing/exporting another C ScenePatch.
    func beginNativePublication(_ stage: SkinNativeStage) throws {
        precondition(Thread.isMainThread && executor?.isCurrent == true)
        guard nativeStageIsCurrent(stage), stage.request.publishesContent, !stage.hasPublicationRollback,
              let layerRuntime else { throw SkinNativeStageFailure.cancelled }
        try layerRuntime.beginNativePublication(stage.attachment)
    }

    /// The physical owner acknowledges a committed Main publication, never a hidden ready snapshot.
    func acknowledgeNativePublication(_ stage: SkinNativeStage, observation: SkinNativeStageObservation) {
        precondition(executor?.isCurrent == true)
        guard pendingNativeStage === stage, stage.wasPublished, !stage.hasOwnerRelease else { return }
        do {
            guard !isStopped, !stage.hasPublicationRollback, !stage.request.isCancelled, !needsFrame,
                  let layerRuntime else { throw SkinNativeStageFailure.cancelled }
            try layerRuntime.acknowledgeNativePublication(stage.attachment)
            let current = stage.attachment.callbackReport.observation
            if let failure = current.failure { throw failure }
            guard current.callbacks == observation.native.callbacks else {
                throw SkinNativeStageFailure.rendering("Native callback count changed before publication acknowledgment")
            }
            requestNativePublicationFinished?(stage, .success(SkinNativeStageObservation(
                sourceSequence: observation.sourceSequence, native: current,
                drewOnPhysicalOwner: observation.drewOnPhysicalOwner, published: true)))
        } catch let failure as SkinNativeStageFailure { requestNativeRollback?(stage, failure) }
        catch { requestNativeRollback?(stage, .rendering(String(describing: error))) }
    }

    /// Acknowledgment is cleanup authority for this identity, even if its old panel/profile is no longer current.
    /// Main has already selected the frozen C frame. Release E before resuming preparation of the latest scene.
    func rolledBackNativePublication(_ stage: SkinNativeStage) -> Bool {
        precondition(executor?.isCurrent == true)
        guard pendingNativeStage === stage, stage.hasPublicationRollback else { return stage.hasOwnerRelease }
        if stage.request.continuesFrames {
            if let failure = stage.publicationFailure {
                nativeFrameFailure = failure
                if case .rendering = failure { failedNativeEpoch = stage.epoch }
            }
            // The fallback is the original C anchor, not the last native scene. After rollback the owner must
            // render the latest values, including Update=-1 skins that will receive no timer-driven request.
            if !isStopped { setNeedsFrame() }
        }
        guard releaseNativeStage(stage) else { return false }
        if releaseAfterWriter { releaseAfterWriter = false; releaseUnseen() }
        if !isStopped, needsFrame { executor?.async { [weak self] in self?.runLoopTurn(.beforeWaiting) } }
        return true
    }

    private func queueNativeCompletion(_ stage: SkinNativeStage, _ result: SkinNativeStageResult) {
        guard pendingNativeStage === stage, !stage.completionQueued else { return }
        stage.completionQueued = true
        requestNativeCompletion?(stage, result)
    }

    /// Release the E owner/captured recipe first; retain only the bounded attachment envelope until main detach.
    @discardableResult
    func releaseNativeStage(_ stage: SkinNativeStage, permanentStop: Bool = false) -> Bool {
        precondition(executor?.isCurrent == true)
        guard pendingNativeStage === stage else { return stage.hasOwnerRelease }
        if stage.hasOwnerRelease { return true }
        do {
            guard let layerRuntime, try layerRuntime.releaseNativeStage(stage.attachment,
                rollbackAcknowledged: stage.hasPublicationRollback, permanentStop: permanentStop) else {
                throw LayerRuntime.NativeStageFailure.staleSource
            }
            stage.recordOwnerRelease(permanentStop: false)
            return true
        } catch {
            // Never fabricate an owner-release ack or detach a still-owned native root after cleanup failure.
            Log.write("Native staging owner release failed: \(error)", level: .error, source: skin()?.config ?? "")
            return false
        }
    }

    /// Exception for permanent stop only: no successful backing can be consumed afterwards. Release on the real
    /// owner now, before a synchronous app termination can stop that worker ahead of a queued main completion.
    /// C retains its own normal fade/teardown contract. Non-stop cancellation keeps completion-before-release.
    private func stopNativeStage() -> Bool {
        guard let stage = pendingNativeStage else { return false }
        stage.request.cancel()
        guard releaseNativeStage(stage, permanentStop: true) else { return false }
        stage.recordOwnerRelease(permanentStop: true)
        pendingNativeStage = nil
        requestNativeStopRelease?(stage)
        return true
    }

    func detachedNativeStage(_ stage: SkinNativeStage) {
        precondition(executor?.isCurrent == true)
        guard pendingNativeStage === stage, stage.hasOwnerRelease else { return }
        pendingNativeStage = nil
        writerReleased?()
        if !isStopped, !needsFrame, shouldRequestNativeFrames { requestNativeFrames?() }
    }

    /// Owner cleanup is queued only when main has finished displaying/fading the old frame. Its acknowledgment
    /// permits main to remove the root even if the executor stops immediately after this work item.
    func retireLayerContent() -> Bool {
        precondition(executor?.isCurrent == true)
        stop()
        guard pendingScenePatch == nil, pendingNativeStage == nil else { return false }
        if let layerRuntime {
            do { try layerRuntime.close() }
            catch { layerFailure = .rendering(String(describing: error)); return false }
        }
        layerRuntime = nil
        layerDestination = nil
        layerInstalled = false
        return true
    }

    private static func withAppearanceThrowing(_ name: String, _ body: () throws -> Void) throws {
        var failure: Error?
        withAppearance(name) { do { try body() } catch { failure = error } }
        if let failure { throw failure }
    }

    /// Runs `body` with the appearance named `name` as the thread's drawing appearance.
    static func withAppearance(_ name: String, _ body: () -> Void) {
        guard let appearance = NSAppearance(named: NSAppearance.Name(rawValue: name)) else { return body() }
        appearance.performAsCurrentDrawingAppearance(body)
    }
}

/// The turns of one run loop in which its skins' frames are drawn (docs/skin-threading.md §7.3): one run-loop observer
/// (before waiting, on exit and before timers, order 1,999,000, common modes) lets every frame producer on that run loop
/// draw, in the order they joined, and the frames of the turn go to the render server in one Core Animation
/// transaction (`SkinFrameBatch`) instead of one each: skins with the same update interval wake together.
final class SkinFrameTurn {
    private static let turns = Guarded<[ObjectIdentifier: SkinFrameTurn]>([:])

    private let loop: CFRunLoop
    private var observer: CFRunLoopObserver?
    /// The producers, weakly, under the registry's lock.
    private var producers: [WeakProducer] = []

    private struct WeakProducer {
        weak var producer: SkinFrameProducer?
    }

    private init(loop: CFRunLoop) {
        self.loop = loop
    }

    /// The turns of `loop` (made with the first producer that joins them). Any thread.
    static func on(_ loop: CFRunLoop) -> SkinFrameTurn {
        turns.access { turns in
            if let turn = turns[ObjectIdentifier(loop)] { return turn }
            let turn = SkinFrameTurn(loop: loop)
            turns[ObjectIdentifier(loop)] = turn
            return turn
        }
    }

    /// Any thread.
    func add(_ producer: SkinFrameProducer) {
        SkinFrameTurn.turns.access { turns in
            producers.removeAll { $0.producer == nil }
            producers.append(WeakProducer(producer: producer))
            // Back in the registry when the last producer had left it meanwhile.
            turns[ObjectIdentifier(loop)] = self
            guard observer == nil else { return }
            let activities: CFRunLoopActivity = [.beforeTimers, .beforeWaiting, .exit]
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true,
                                                              SkinFrameProducer.observerOrder) { [weak self] _, activity in
                self?.run(activity)
            }
            self.observer = observer
            if let observer { CFRunLoopAddObserver(loop, observer, .commonModes) }
        }
    }

    /// Any thread. The last one to leave takes the observer with it.
    func remove(_ producer: SkinFrameProducer) {
        SkinFrameTurn.turns.access { turns in
            producers.removeAll { $0.producer == nil || $0.producer === producer }
            guard producers.isEmpty else { return }
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
            if turns[ObjectIdentifier(loop)] === self { turns[ObjectIdentifier(loop)] = nil }
        }
    }

    /// Producers in this run loop's turns (tests).
    var count: Int { SkinFrameTurn.turns.access { _ in producers.filter { $0.producer != nil }.count } }
    /// Turns that committed frames (tests, measurements).
    private let committedTurns = Guarded(0)
    var commits: Int { committedTurns.current }

    private func run(_ activity: CFRunLoopActivity) {
        let now = SkinFrameTurn.turns.access { _ in producers.compactMap(\.producer) }
        guard !now.isEmpty else { return }
        let committed = SkinFrameBatch.run {
            for producer in now { producer.runLoopTurn(activity) }
        }
        if committed { committedTurns.access { $0 += 1 } }
    }
}

/// The Core Animation transaction a turn's frames go in (`SkinFrameTurn`): opened by the first frame presented in it,
/// committed once when the turn's producers are done (and flushed off the main thread, where no run loop observer of
/// Core Animation's commits it). A frame presented outside a turn (the first frame, drawn while a skin loads) has a
/// transaction of its own. Per thread.
enum SkinFrameBatch {
    private final class State {
        var depth = 0
        var opened = false
        var commits = 0
    }

    private static let key = "DesksetSkinFrameBatch"
    /// Outermost transactions committed for frames and layer changes of skin content (measurements, tests).
    private static let commitCount = Guarded(0)

    private static var state: State {
        let dictionary = Thread.current.threadDictionary
        if let state = dictionary[key] as? State { return state }
        let state = State()
        dictionary[key] = state
        return state
    }

    /// Runs `body` as a turn's batch: what is presented in it is committed once, at the end (true when there was).
    @discardableResult
    static func run(_ body: () -> Void) -> Bool {
        let state = self.state
        state.depth += 1
        body()
        state.depth -= 1
        guard state.depth == 0, state.opened else { return false }
        state.opened = false
        CATransaction.commit()
        committed()
        return true
    }

    /// A content provider is about to change its layer: inside a batch its transaction is opened now (once) and the
    /// change goes with it (true); outside one the provider commits its own (false).
    static func join() -> Bool {
        let state = self.state
        guard state.depth > 0 else { return false }
        if !state.opened {
            state.opened = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        return true
    }

    /// An outermost transaction was committed: flushed off the main thread, and counted.
    static func committed() {
        if !Thread.isMainThread { CATransaction.flush() }
        state.commits += 1
        commitCount.access { $0 += 1 }
        FrameTimingLog.noteCommit()
    }

    /// Outermost commits so far.
    static var commits: Int { commitCount.current }
    /// Outermost commits so far on this thread (tests).
    static var threadCommits: Int { state.commits }
}

/// `defaults write app.deskset.Deskset FrameTimingLog -int 10`: every 10 seconds, each skin that presented frames logs
/// how evenly they came (the time between two frames presented: median, 95th percentile and longest), how many there
/// were and its longest drawing. For measuring frame pacing (docs/skin-threading.md §15); read at launch, off by
/// default. A skin that presents no frame for a while logs nothing for that while; its next report counts the gap.
enum FrameTimingLog {
    static let defaultsKey = "FrameTimingLog"
    /// Seconds between two reports of a skin (0: off). Set at launch, before any skin loads.
    static var period: TimeInterval = 0

    static func configure(from defaults: UserDefaults) {
        let value = defaults.object(forKey: defaultsKey)
        let seconds = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) ?? 0
        period = seconds.isFinite && seconds > 0 ? seconds : 0
        if period > 0 { Log.write("Frame timing log on: every \(Int(period)) s") }
    }

    /// The Core Animation commits of skin frames since the last report (`SkinFrameBatch`), app-wide.
    private static let commits = Guarded<(count: Int, since: TimeInterval?)>((0, nil))

    /// A commit of skin frames: every `period` the app logs how many there were a second.
    static func noteCommit() {
        guard period > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report = commits.access { c -> String? in
            c.count += 1
            guard let since = c.since else {
                c.since = now
                return nil
            }
            guard now - since >= period else { return nil }
            let text = String(format: "%d in %.1f s (%.1f a second)", c.count, now - since,
                              Double(c.count) / (now - since))
            c = (0, now)
            return text
        }
        if let report { Log.write("Frame commits: \(report)") }
    }

    /// The frames of one skin since its last report. On the skin's executor.
    struct Window {
        private var presented: [TimeInterval] = []
        private var longestDrawing: TimeInterval = 0
        private var since: TimeInterval?

        mutating func note(presentedAt time: TimeInterval, drawing: TimeInterval) {
            if since == nil { since = time }
            if presented.count < 4096 { presented.append(time) }
            longestDrawing = max(longestDrawing, drawing)
        }

        /// The report when `period` has passed since the window began, and a new window from the last frame on.
        mutating func report(at now: TimeInterval, every period: TimeInterval) -> String? {
            guard let since, now - since >= period, presented.count >= 2 else { return nil }
            let gaps = zip(presented.dropFirst(), presented).map { ($0 - $1) * 1000 }.sorted()
            func at(_ q: Double) -> Double { gaps[min(gaps.count - 1, Int((Double(gaps.count - 1) * q).rounded()))] }
            let text = String(format: "%d in %.1f s; between frames p50 %.1f ms, p95 %.1f ms, longest %.1f ms; "
                              + "longest drawing %.1f ms", gaps.count, now - since, at(0.5), at(0.95),
                              gaps.last ?? 0, longestDrawing * 1000)
            let last = presented.last ?? now
            presented = [last]
            longestDrawing = 0
            self.since = last
            return text
        }
    }
}
