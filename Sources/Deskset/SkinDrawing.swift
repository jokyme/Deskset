import AppKit
import DesksetCore

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
    /// One step of the drawing: the base (glass hit areas and background, `id` the skin) or a top-level meter (a
    /// container with its content), and the generation it was drawn at.
    struct Item: Equatable {
        let id: ObjectIdentifier
        let generation: Int
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
    /// Each item's generation at the previous frame: an item that kept it is unchanged.
    private var previous: [ObjectIdentifier: Int] = [:]
    /// What every picture depends on besides the items (see `resetKey`).
    private var drawnFor: ResetKey?
    private var baseGeneration = 0
    private var lastBase: Base?
    private var reportedDifference = false

    /// What a picture was drawn for: another skin (a refresh), size, scale, colour space, appearance or fonts.
    private struct ResetKey: Equatable {
        let skin: ObjectIdentifier
        let width: Int
        let height: Int
        let scale: CGFloat
        /// Compared as color spaces (`CFEqual`), not by name: a display's own profile has none.
        let space: CGColorSpace
        let appearance: String
        let fonts: Int
    }

    /// What the base (glass hit areas and background) is drawn from besides image files: the glass, and the skin's
    /// size, which the background fills or stretches over (a skin larger than its window changes it, not the window).
    private struct Base: Equatable {
        let glass: [GlassRegion]
        let width: Double
        let height: Double
    }

    /// What the last frame did (tests): runs copied, runs drawn into a new picture, items drawn directly.
    private(set) var lastStats = (copied: 0, made: 0, drawn: 0)
    /// Pictures kept now (tests).
    var keptRuns: Int { runs.count }
    /// Frames that differed from a full drawing (`verifies`; tests).
    private(set) var differences = 0

    /// The skin as it is now, `size` points at `scale` pixels per point; nil for an empty size.
    func picture(of skin: Skin, size: CGSize, scale: CGFloat, space: CGColorSpace, appearance: String) -> CGImage? {
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        let key = ResetKey(skin: ObjectIdentifier(skin), width: w, height: h, scale: scale, space: space,
                           appearance: appearance, fonts: Fonts.generation)
        if key != drawnFor {
            drawnFor = key
            runs = []
            previous = [:]
            lastBase = nil
            bitmaps = [SkinBitmapDrawing.makeContext(w, h, space), SkinBitmapDrawing.makeContext(w, h, space)]
                .compactMap { $0 }
        }
        // Pictures of image files that changed since are drawn again.
        runs.removeAll { !Images.filesUnchanged($0.files) }
        guard bitmaps.count == 2 else { return nil }
        let ctx = bitmaps[nextBitmap]
        nextBitmap = 1 - nextBitmap
        let meters = SkinRenderer.topLevelMeters(skin)
        let base = Base(glass: skin.glassRegions, width: skin.width, height: skin.height)
        if base != lastBase {
            lastBase = base
            baseGeneration &+= 1
        }
        var items = [Item(id: ObjectIdentifier(skin), generation: baseGeneration)]
        for m in meters { items.append(Item(id: ObjectIdentifier(m), generation: SkinBitmapDrawing.generation(of: m, in: skin))) }
        let stable = items.map { previous[$0.id] == $0.generation }
        previous = Dictionary(items.map { ($0.id, $0.generation) }, uniquingKeysWith: { a, _ in a })

        var kept: [Run] = []
        var stats = (copied: 0, made: 0, drawn: 0)
        // The bitmap still holds an older frame: the first picture replaces all of it, else it is cleared first.
        var started = false
        func drawDirectly(_ range: Range<Int>) {
            if !started { ctx.clear(CGRect(x: 0, y: 0, width: w, height: h)) }
            started = true
            draw(items: range, meters, skin, into: ctx, height: h, scale: scale)
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
                    draw(items: range, meters, skin, into: picture, height: h, scale: scale)
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
        if SkinBitmapDrawing.verifies, stats.copied > 0, let image { verify(image, skin, meters, w, h, scale, space) }
        return image
    }

    /// A meter's generation, with what its drawing reads when drawn (`Meter.hashDrawInputs`); a container's covers
    /// its content too.
    static func generation(of meter: Meter, in skin: Skin) -> Int {
        var hasher = Hasher()
        hasher.combine(meter.drawGeneration)
        meter.hashDrawInputs(into: &hasher)
        guard meter.isContainer else { return hasher.finalize() }
        for m in SkinRenderer.content(of: meter, in: skin) {
            hasher.combine(ObjectIdentifier(m))
            hasher.combine(m.drawGeneration)
            m.hashDrawInputs(into: &hasher)
        }
        return hasher.finalize()
    }

    static func makeContext(_ w: Int, _ h: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Draws items `range` (0 is the base, n the meter n − 1) in skin coordinates: top-left origin, points.
    private func draw(items range: Range<Int>, _ meters: [Meter], _ skin: Skin, into ctx: CGContext, height: Int,
                      scale: CGFloat) {
        SkinBitmapDrawing.draw(items: range, meters, skin, into: ctx, height: height, scale: scale)
    }

    static func draw(items range: Range<Int>, _ meters: [Meter], _ skin: Skin, into ctx: CGContext, height: Int,
                     scale: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let context = SkinRenderContext.of(skin)
        for i in range {
            // The glass itself is behind the view (`SkinGlassViews`): here it only catches the mouse.
            if i == 0 {
                SkinRenderer.drawBase(skin, in: ctx, glass: .window)
            } else {
                SkinRenderer.drawTopLevel(meters[i - 1], of: skin, in: ctx, context)
            }
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
    private func verify(_ image: CGImage, _ skin: Skin, _ meters: [Meter], _ w: Int, _ h: Int, _ scale: CGFloat,
                        _ space: CGColorSpace) {
        guard let full = SkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: scale, space: space),
              let found = SkinBitmapDrawing.difference(image, full) else { return }
        guard found.worst > SkinBitmapDrawing.tolerance else { return }
        differences += 1
        if !reportedDifference {
            reportedDifference = true
            Log.write("Kept pictures differ from a full drawing by \(found.worst) at pixel \(found.x),\(found.y)",
                      level: .warning, source: skin.config)
        }
    }

    /// The skin drawn in full into a new bitmap of `w`×`h` pixels, as a picture draws it (glass as the window's hit
    /// areas); nil when the bitmap cannot be made.
    static func fullDrawing(of skin: Skin, _ w: Int, _ h: Int, scale: CGFloat, space: CGColorSpace) -> CGContext? {
        guard let ctx = makeContext(w, h, space) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let meters = SkinRenderer.topLevelMeters(skin)
        draw(items: 0..<(meters.count + 1), meters, skin, into: ctx, height: h, scale: scale)
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
    /// The skin, as long as the runtime has it.
    private let skin: () -> Skin?

    /// The skin redrew since the last frame (or the window's scale, colour space or appearance changed).
    private(set) var needsFrame = false
    /// When the skin asked for the frame it waits for (the monotonic clock).
    private var askedAt: TimeInterval = 0
    private var isStopped = false
    private var observer: CFRunLoopObserver?

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
    /// What the provider was told last.
    private var toldVisible: Bool?

    /// Frames drawn and presented (tests).
    private(set) var framesDrawn = 0
    /// Turns that ended with a frame wanted but not drawn because the window could not be seen (tests).
    private(set) var framesSkipped = 0

    /// How long a turn may run before a frame asked for in it is drawn anyway (a thread that never waits).
    static let frameInterval: TimeInterval = 1.0 / 60
    /// Before Core Animation's commit (2000000), after the run loop's other work.
    static let observerOrder: CFIndex = 1_999_000
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `provider` nil: a runtime without a window (tests), which draws nothing.
    init(provider: ContentProvider?, skin: @escaping () -> Skin?) {
        self.provider = provider
        self.skin = skin
    }

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
    }

    /// Starts drawing at the end of `executor`'s turns. Any thread.
    func start(on executor: SkinExecutor) {
        guard provider != nil, observer == nil else { return }
        let activities: CFRunLoopActivity = [.beforeTimers, .beforeWaiting, .exit]
        guard let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true,
                                                                  SkinFrameProducer.observerOrder,
                                                                  { [weak self] _, activity in
                                                                      self?.runLoopTurn(activity)
                                                                  })
        else { return }
        self.observer = observer
        if let executor = executor as? SkinRunLoopExecutor, let loop = executor.runLoop {
            CFRunLoopAddObserver(loop, observer, .commonModes)
        } else {
            // Its work runs on its run loop: the observer goes there.
            executor.async { CFRunLoopAddObserver(CFRunLoopGetCurrent(), observer, .commonModes) }
        }
    }

    /// The skin closed: no more frames.
    func stop() {
        isStopped = true
        needsFrame = false
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }

    /// Whether the window can be seen, as far as its facts tell.
    var canBeSeen: Bool { isOrderedIn && (isUnoccluded || justOrderedIn) }

    /// The skin redrew: a frame at the end of the turn, if the window can be seen then.
    func setNeedsFrame() {
        guard !isStopped else { return }
        if !needsFrame { askedAt = ProcessInfo.processInfo.systemUptime }
        needsFrame = true
    }

    /// The window's facts, as the runtime's window model took them.
    func take(_ facts: SkinWindowFacts?) {
        guard let facts, !isStopped else { return }
        var redraw = false
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
            // Unless the first frame was drawn for it right now.
            if !drewThisTurn { redraw = true }
        }
        isOrderedIn = facts.isOrderedIn
        isUnoccluded = facts.isVisible
        // Before the first frame there is nothing to draw again: the skin's first redraw asks for it.
        if redraw && framesDrawn > 0 { setNeedsFrame() }
        let seen = canBeSeen
        if seen != toldVisible {
            toldVisible = seen
            provider?.setVisible(seen)
        }
    }

    /// The window is about to be shown for the first time: the first frame now, whether the window can be seen yet or
    /// not (nothing when a frame was presented already).
    func drawFirstFrame() {
        guard framesDrawn == 0, !isStopped else { return }
        draw()
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
        guard canBeSeen else {
            framesSkipped += 1
            return
        }
        draw()
    }

    /// Draws the skin as it is now and presents it; a picture that cannot be made keeps the last one on screen.
    private func draw() {
        needsFrame = false
        guard let provider, let skin = skin() else { return }
        let size = SkinRuntime.windowSize(width: skin.width, height: skin.height)
        let (scale, space, appearance, drawing) = (self.scale, self.space, self.appearance, self.drawing)
        var picture: CGImage?
        // The drawing appearance AppKit set while the view drew.
        SkinFrameProducer.withAppearance(appearance) {
            picture = drawing.picture(of: skin, size: size, scale: scale, space: space, appearance: appearance)
        }
        guard let picture else { return }
        provider.present(SkinFrame(image: picture, scale: scale))
        framesDrawn += 1
        drewThisTurn = true
    }

    /// Runs `body` with the appearance named `name` as the thread's drawing appearance.
    static func withAppearance(_ name: String, _ body: () -> Void) {
        guard let appearance = NSAppearance(named: NSAppearance.Name(rawValue: name)) else { return body() }
        appearance.performAsCurrentDrawingAppearance(body)
    }
}
