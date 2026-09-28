// A skin window in one of the ways a skin can reach the screen:
//
//   A    the drawing Deskset used until 2026-09-27: a flipped view draws the whole skin in draw(_:) on the main thread
//        (a display-list context; Core Animation rasterizes it in this process on its accelerated path).
//   B    Deskset's drawing since then: the view draws the whole skin on the main thread into a bitmap of its own
//        (8-bit, premultiplied BGRA, in the window's color space, two bitmaps used in turn) and sets it as its
//        layer's contents in updateLayer. Plain B draws in full; B+kept (--kept) also keeps pictures of runs of
//        unchanged elements and copies them, as Deskset does (SkinBitmapDrawing).
//   E1   one layer the skin thread redraws (setNeedsDisplay + displayIfNeeded, draw(in:) paints the whole skin).
//   EP   the partition (Partition.swift): base tiles showing one shared base bitmap through contentsRect, plus one layer
//        per group that the skin thread redraws with draw(in:) (base pixels copied in, then the group's elements).
//   D1   one layer whose contents is an IOSurface the skin thread draws into (sRGB, 8-bit, premultiplied).
//   DP   the partition with IOSurface contents for the groups.
//   +cgimage  (D1, DP; "C1", "CP" in the results) the contents are images of two bitmaps of our own used in turn, in
//        the window's color space, instead of sRGB IOSurfaces: what B does, per layer and from the skin thread.
//   +windowSpaceBase  (EP, DP) the base bitmap (and the scratch bitmap) in the window's color space instead of sRGB.
//   +scratch  (EP, DP) groups are not drawn moved into their own bitmap: the dirty groups are drawn at their window
//        position into one window-sized scratch bitmap (base pixels restored under their boxes first), and each
//        group's box is copied out of it. CoreGraphics is not exact under whole-pixel translation (q5), this is.
//   OVE / OVD  naive layering that does share pixels: the panel in one layer, everything else in a layer on top
//        (draw(in:) or our own sRGB bitmaps). Used to reproduce the "overlapping layers" difference.
//
// Layer modes follow the plan's view structure: panel → flipped container → ContentHost (layer-backed, flipped,
// wantsUpdateLayer, no drawing) → contentRoot (created and owned by the runtime) → tiles and groups.
import AppKit
import IOSurface
import QuartzCore

enum Mode: String, CaseIterable {
    case A, B, E1, EP, D1, DP, OVE, OVD
    /// A and B: a view drawn on the main thread (no contentRoot).
    var isView: Bool { self == .A || self == .B }
    var isLayered: Bool { !isView }
    var isD: Bool { self == .D1 || self == .DP || self == .OVD }
}

/// What to set as the E layers' contentsFormat: nothing (CA's default), RGBA8Uint or RGBA16Float.
enum FormatChoice: String, CaseIterable { case auto, rgba8, rgba16f }
/// NSWindow.colorSpace: left alone, sRGB, Display P3, or the screen's own color space.
enum WindowSpace: String, CaseIterable { case `default`, srgb, p3, display }

struct Config {
    var mode = Mode.EP
    /// The plan sets RGBA8Uint explicitly on every layer.
    var format = FormatChoice.rgba8
    var windowSpace = WindowSpace.default
    /// D bitmaps: sRGB or the screen's color space; 8-bit or 16-bit float.
    var dDisplaySpace = false
    var dHalfFloat = false
    /// Base tiles show an IOSurface instead of a CGImage.
    var baseSurface = false
    /// The base bitmap drawn in the window's color space (and in half float for RGBA16Float) instead of sRGB 8-bit.
    var baseInWindowSpace = false
    /// Commits from the skin's own thread (the design) or from the main thread.
    var skinThread = true
    /// E layers drawn for the first time in the same transaction that adds them (before the window's context
    /// knows them) instead of in the next one.
    var displayBeforeAttach = false
    /// EP / DP: draw groups in a window-sized scratch bitmap and copy their boxes out (see the header).
    var scratch = false
    /// B: keep pictures of unchanged runs of elements, like Deskset's SkinBitmapDrawing.
    var keptPictures = false
    /// D1 / DP: our own bitmap contexts (two used in turn) whose images become the contents, in the window's color
    /// space, instead of sRGB IOSurfaces ("C1" / "CP" in the results).
    var cgImages = false

    var label: String {
        var s = mode.rawValue
        if mode.isLayered && !mode.isD && format != .rgba8 { s += "/\(format.rawValue)" }
        if mode.isD && (dDisplaySpace || dHalfFloat) { s += "/\(dDisplaySpace ? "display" : "srgb")\(dHalfFloat ? "-16f" : "-8")" }
        if mode.isD && cgImages { s += "+cgimage" }
        if (mode == .EP || mode == .DP) && baseSurface { s += "+surfaceBase" }
        if (mode == .EP || mode == .DP) && scratch { s += "+scratch" }
        if (mode == .EP || mode == .DP) && baseInWindowSpace { s += "+windowSpaceBase" }
        if mode == .B && keptPictures { s += "+kept" }
        if displayBeforeAttach { s += "+displayBeforeAttach" }
        if windowSpace != .default { s += "@\(windowSpace.rawValue)" }
        return s
    }
}

func nsColorSpace(_ w: WindowSpace, screen: NSScreen?) -> NSColorSpace? {
    switch w {
    case .default: return nil
    case .srgb: return .sRGB
    case .p3: return .displayP3
    case .display: return screen?.colorSpace
    }
}

// MARK: Views

/// SkinContentView: a flipped container.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}

/// ContentHost: a layer-backed, flipped view that draws nothing; its layer belongs to AppKit.
final class ContentHostView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
}

/// Deskset's SkinView: A draws the whole skin in draw(_:) on the main thread; B (`ownBitmap`) draws it in
/// updateLayer into a bitmap of its own and sets that as the layer's contents.
final class SkinDrawView: NSView {
    var paint: ((CGContext) -> Void)?
    /// B with kept pictures: draws elements `range` (file order), and each element's state now (what it draws).
    var paintItems: ((CGContext, Range<Int>) -> Void)?
    var itemStates: (() -> [Int])?
    /// How long each drawing took, wall clock and this thread's CPU time (A: recording the display list, rasterized
    /// later; B: drawing the bitmap).
    var onDrawn: ((Double, Double) -> Void)?
    var label = "A"
    /// B: draw into our own bitmaps (updateLayer) instead of draw(_:).
    var ownBitmap = false
    /// B: keep pictures of runs of elements that did not change since the previous frame and copy them, like
    /// Deskset's SkinBitmapDrawing (at most 4 whole-window pictures; changed elements are drawn directly).
    var keptPictures = false
    private var bitmaps: [CGContext] = []
    private var nextBitmap = 0
    private struct Run {
        let range: Range<Int>
        let states: [Int]
        let image: CGImage
    }
    private var runs: [Run] = []
    private var previousStates: [Int]?
    /// What the last frame did: pictures copied, pictures made, elements drawn directly.
    private(set) var keptStats = (copied: 0, made: 0, drawn: 0)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { ownBitmap }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let start = now(), startCPU = threadCPUSeconds()
        noteContext(ctx, label)
        ctx.clear(bounds)
        paint?(ctx)
        onDrawn?(now() - start, threadCPUSeconds() - startCPU)
    }

    private static func makeContext(_ w: Int, _ h: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Like Deskset's SkinBitmapDrawing: the window's color space (sRGB when it has none), 8-bit premultiplied
    /// BGRA, two bitmaps used in turn so drawing never writes into the image the layer still shows; with
    /// `keptPictures`, its kept pictures of unchanged runs of elements.
    override func updateLayer() {
        guard let layer, let paint else { return }
        let scale = window?.backingScaleFactor ?? 2
        let space = window?.colorSpace?.cgColorSpace ?? sRGB
        let w = Int((bounds.width * scale).rounded(.up)), h = Int((bounds.height * scale).rounded(.up))
        if bitmaps.count != 2 || bitmaps[0].width != w || bitmaps[0].height != h
            || !CFEqual(bitmaps[0].colorSpace, space) {
            bitmaps = (0..<2).compactMap { _ in SkinDrawView.makeContext(w, h, space) }
            nextBitmap = 0
            runs = []
            previousStates = nil
        }
        guard bitmaps.count == 2 else { return }
        let start = now(), startCPU = threadCPUSeconds()
        let ctx = bitmaps[nextBitmap]
        nextBitmap = 1 - nextBitmap
        func inSkinSpace(_ c: CGContext, _ body: () -> Void) {
            c.saveGState()
            c.translateBy(x: 0, y: CGFloat(h))
            c.scaleBy(x: scale, y: -scale)
            body()
            c.restoreGState()
        }
        noteContext(ctx, label)
        if keptPictures, let paintItems, let itemStates {
            let states = itemStates()
            let stable = states.indices.map { i in previousStates.map { $0[i] == states[i] } ?? false }
            previousStates = states
            var kept: [Run] = []
            var stats = (copied: 0, made: 0, drawn: 0)
            var started = false
            func drawDirectly(_ range: Range<Int>) {
                if !started { ctx.clear(CGRect(x: 0, y: 0, width: w, height: h)) }
                started = true
                inSkinSpace(ctx) { paintItems(ctx, range) }
                stats.drawn += range.count
            }
            func place(_ image: CGImage) {
                ctx.saveGState()
                ctx.interpolationQuality = .none
                if !started { ctx.setBlendMode(.copy) }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.restoreGState()
                started = true
            }
            var index = 0
            while index < states.count {
                guard stable[index] else {
                    drawDirectly(index..<index + 1)
                    index += 1
                    continue
                }
                var end = index + 1
                while end < states.count && stable[end] { end += 1 }
                let range = index..<end, runStates = Array(states[range])
                if let run = runs.first(where: { $0.range == range && $0.states == runStates }) {
                    place(run.image)
                    kept.append(run)
                    stats.copied += 1
                } else if kept.count < 4, let picture = SkinDrawView.makeContext(w, h, space) {
                    inSkinSpace(picture) { paintItems(picture, range) }
                    if let image = picture.makeImage() {
                        place(image)
                        kept.append(Run(range: range, states: runStates, image: image))
                        stats.made += 1
                    } else {
                        drawDirectly(range)
                    }
                } else {
                    drawDirectly(range)
                }
                index = end
            }
            if !started { ctx.clear(CGRect(x: 0, y: 0, width: w, height: h)) }
            runs = kept
            keptStats = stats
        } else {
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            inSkinSpace(ctx) { paint(ctx) }
        }
        layer.contentsScale = scale
        let image = ctx.makeImage()
        layer.contents = image
        lastImage = image
        onDrawn?(now() - start, threadCPUSeconds() - startCPU)
    }

    /// B: the picture it showed last.
    private(set) var lastImage: CGImage?

    /// B+kept: the last picture against the skin drawn in full at `tick` into a new bitmap in the same color space.
    func keptCheck(tick: Int) -> JSON? {
        guard keptPictures, let image = lastImage, let space = image.colorSpace, let paint,
              let full = SkinDrawView.makeContext(image.width, image.height, space) else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        full.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        full.translateBy(x: 0, y: CGFloat(image.height))
        full.scaleBy(x: scale, y: -scale)
        paint(full)
        guard let fullImage = full.makeImage() else { return nil }
        return compare(Pixels.drawn(image, in: space), Pixels.drawn(fullImage, in: space)).json
    }

    /// B: bytes of the two bitmaps and the kept pictures.
    var ownedBitmapBytes: Int {
        bitmaps.reduce(0) { $0 + $1.bytesPerRow * $1.height } + runs.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
    }
}

// MARK: Context introspection

typealias GetContextType = @convention(c) (CGContext) -> Int32
let getContextType: GetContextType? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGContextGetType")
    .map { unsafeBitCast($0, to: GetContextType.self) }

/// CoreGraphics' own name for the context type (from its description), e.g. kCGContextTypeBitmap.
func contextTypeName(_ ctx: CGContext) -> String {
    let d = CFCopyDescription(ctx) as String
    if let r = d.range(of: "(kCGContextType"), let end = d[r.upperBound...].firstIndex(of: ")") {
        return "kCGContextType" + d[r.upperBound..<end]
    }
    return "type \(getContextType?(ctx) ?? -1)"
}

func contextInfo(_ ctx: CGContext) -> JSON {
    var j: JSON = ["type": contextTypeName(ctx), "typeNumber": Int(getContextType?(ctx) ?? -1),
                   "hasBitmapData": ctx.data != nil, "thread": Thread.isMainThread ? "main" : "skin",
                   "ctmD": Double(ctx.ctm.d)]
    if ctx.data != nil {
        j["pixels"] = "\(ctx.width)x\(ctx.height)"
        j["bitsPerComponent"] = ctx.bitsPerComponent
        j["bitsPerPixel"] = ctx.bitsPerPixel
        j["bitmapInfo"] = String(ctx.bitmapInfo.rawValue, radix: 16)
        j["colorSpace"] = colorSpaceName(ctx.colorSpace)
    }
    return j
}

/// Every kind of context each drawing path got, counted: label, thread, type, color space and depth.
///
/// Called on every draw, so it must stay cheap: describing a CGContext (`CFCopyDescription`) takes about 3 µs and
/// leaks about 200 bytes per call on macOS 26.5 (20 MB per 100,000 calls; at 60 Hz with 33 group layers that is
/// 0.4 MB a second). The type's name is taken from the description once per type number and reused.
let contextLog = ContextLog()
final class ContextLog {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var typeNames: [Int32: String] = [:]

    private func typeName(_ ctx: CGContext) -> String {
        guard let number = getContextType?(ctx) else { return contextTypeName(ctx) }
        lock.lock()
        let known = typeNames[number]
        lock.unlock()
        if let known { return known }
        let name = contextTypeName(ctx)
        lock.lock()
        typeNames[number] = name
        lock.unlock()
        return name
    }

    func note(_ ctx: CGContext, _ label: String) {
        var key = "\(label) [\(Thread.isMainThread ? "main" : "skin")] \(typeName(ctx))"
        if ctx.data != nil {
            key += " \(colorSpaceName(ctx.colorSpace)) \(ctx.bitsPerComponent)bpc"
            if ctx.bitmapInfo.contains(.floatComponents) { key += " float" }
        }
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }
    func reset() {
        lock.lock()
        counts = [:]
        lock.unlock()
    }
    var json: JSON {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

func noteContext(_ ctx: CGContext, _ label: String) { contextLog.note(ctx, label) }

// MARK: Layers

/// A layer with no implicit animations.
class QuietLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

/// A layer that paints through a closure in draw(in:) (E). The context arrives flipped (top-left) under the
/// flipped ContentHost; if not, the closure gets a flipped one anyway.
final class PaintLayer: QuietLayer {
    var label = "E"
    var paint: ((CGContext) -> Void)?

    override func draw(in ctx: CGContext) {
        noteContext(ctx, label)
        if ctx.ctm.d > 0 {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        paint?(ctx)
    }
}

/// A few IOSurfaces a layer shows in turn (D). A surface the window server still reads is skipped (isInUse).
final class SurfacePool {
    let width: Int, height: Int
    let halfFloat: Bool
    let space: CGColorSpace
    private var surfaces: [(surface: IOSurface, context: CGContext)] = []
    private let limit = 3
    /// C (`images`): two plain bitmap contexts used in turn instead of IOSurfaces; the layer gets an image of the
    /// one just drawn (like B's own bitmaps).
    let images: Bool
    private var contexts: [CGContext] = []
    private var nextContext = 0

    init(width: Int, height: Int, space: CGColorSpace, halfFloat: Bool, images: Bool = false) {
        self.width = width
        self.height = height
        self.space = space
        self.halfFloat = halfFloat
        self.images = images
    }

    var count: Int { images ? contexts.count : surfaces.count }
    var bytes: Int {
        images ? contexts.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            : surfaces.reduce(0) { $0 + $1.surface.allocationSize }
    }

    /// C: the context to draw the next frame into.
    func nextImageContext() -> CGContext? {
        if contexts.isEmpty {
            contexts = (0..<2).compactMap { _ in
                CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: bgraInfo)
            }
        }
        guard contexts.count == 2 else { return nil }
        defer { nextContext = 1 - nextContext }
        return contexts[nextContext]
    }

    func next() -> (surface: IOSurface, context: CGContext)? {
        if let free = surfaces.first(where: { !$0.surface.isInUse }) { return free }
        guard surfaces.count < limit, let made = make() else { return surfaces.first }
        surfaces.append(made)
        return made
    }

    private func make() -> (surface: IOSurface, context: CGContext)? {
        let bpe = halfFloat ? 8 : 4
        let rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bpe)
        let format: UInt32 = halfFloat ? 0x5247_6841 /* 'RGhA' */ : 0x4247_5241 /* 'BGRA' */
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: bpe, .bytesPerRow: rowBytes, .pixelFormat: format,
        ]) else { return nil }
        let info = halfFloat
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
            : bgraInfo
        guard let context = CGContext(data: surface.baseAddress, width: width, height: height,
                                      bitsPerComponent: halfFloat ? 16 : 8, bytesPerRow: surface.bytesPerRow,
                                      space: space, bitmapInfo: info) else { return nil }
        if let plist = space.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, plist)
        }
        return (surface, context)
    }
}

// MARK: The skin window

final class SkinWindow {
    let widget: Widget
    let config: Config
    let panel: NSPanel
    let container = FlippedView()
    let scale: CGFloat
    private(set) var drawView: SkinDrawView?
    private(set) var host: ContentHostView?
    let contentRoot = QuietLayer()
    let thread: RunLoopThread?

    private(set) var part: Partition?
    private(set) var base: CGImage?
    private var baseSurface: IOSurface?
    private var baseCrops: [Int: CGImage] = [:]
    private(set) var groupLayers: [PaintLayer] = []
    private var groupSurfaceLayers: [QuietLayer] = []
    private var pools: [SurfacePool] = []
    private(set) var tileLayers: [QuietLayer] = []
    private var single: CALayer?
    private var topLayer: CALayer?
    private var singlePool: SurfacePool?
    /// +scratch: the window-sized bitmap the groups are drawn in, and the image of it after the last drawing.
    private var scratchContext: CGContext?
    private var scratchImage: CGImage?

    /// The tick drawn by the layers (read by draw(in:) on whichever thread CA calls it).
    private let tickLock = NSLock()
    private var _tick = 0
    var tick: Int {
        get { tickLock.lock(); defer { tickLock.unlock() }; return _tick }
        set { tickLock.lock(); _tick = newValue; tickLock.unlock() }
    }

    // Statistics (written on the skin's executor, read from anywhere).
    private let statsLock = NSLock()
    private var _commitTimes: [Double] = []
    private var _commitTicks: [Int] = []
    private var _frameCosts: [Double] = []
    private var _commitCosts: [Double] = []
    private var _frameCPUCosts: [Double] = []
    private var _commitCPUCosts: [Double] = []
    var commitTimes: [Double] { statsLock.lock(); defer { statsLock.unlock() }; return _commitTimes }
    /// The tick each commit showed (same order as commitTimes).
    var commitTicks: [Int] { statsLock.lock(); defer { statsLock.unlock() }; return _commitTicks }
    /// The same costs as this thread's CPU time (wall-clock costs include time the thread was preempted).
    var frameCPUCosts: [Double] { statsLock.lock(); defer { statsLock.unlock() }; return _frameCPUCosts }
    var commitCPUCosts: [Double] { statsLock.lock(); defer { statsLock.unlock() }; return _commitCPUCosts }
    /// Drawing of one update on the skin's executor, before the commit (A: its draw(_:), recording only).
    var frameCosts: [Double] { statsLock.lock(); defer { statsLock.unlock() }; return _frameCosts }
    /// CATransaction.commit plus flush of one update on the skin's executor (layered modes).
    var commitCosts: [Double] { statsLock.lock(); defer { statsLock.unlock() }; return _commitCosts }
    private func record(commit: Double, tick: Int, cost: Double?, commitCost: Double? = nil, cpu: Double? = nil,
                        commitCPU: Double? = nil) {
        statsLock.lock()
        _commitTimes.append(commit)
        _commitTicks.append(tick)
        if let cost { _frameCosts.append(cost) }
        if let commitCost { _commitCosts.append(commitCost) }
        if let cpu { _frameCPUCosts.append(cpu) }
        if let commitCPU { _commitCPUCosts.append(commitCPU) }
        statsLock.unlock()
    }
    private func recordDraw(_ cost: Double, _ cpu: Double) {
        statsLock.lock()
        _frameCosts.append(cost)
        _frameCPUCosts.append(cpu)
        statsLock.unlock()
    }
    private var timer: Timer?

    init(_ widget: Widget, _ config: Config, origin: NSPoint, thread: RunLoopThread?) {
        self.widget = widget
        self.config = config
        self.thread = config.mode.isLayered && config.skinThread ? thread : nil
        panel = makePanel(NSRect(origin: origin, size: widget.size))
        scale = panel.backingScaleFactor
        if let space = nsColorSpace(config.windowSpace, screen: panel.screen) { panel.colorSpace = space }
        container.frame = NSRect(origin: .zero, size: widget.size)
        // Like Deskset: the skin view does not ask for a layer itself (AppKit gives every view in the window one).
        if config.mode.isLayered { container.wantsLayer = true }
        panel.contentView = container
        if config.mode.isView {
            let v = SkinDrawView(frame: container.bounds)
            v.label = config.label
            v.ownBitmap = config.mode == .B
            v.keptPictures = config.mode == .B && config.keptPictures
            v.paint = { [unowned self] ctx in widget.draw(ctx, tick: tick) }
            v.paintItems = { [unowned self] ctx, range in widget.draw(ctx, tick: tick, Array(widget.elements[range])) }
            v.itemStates = { [unowned self] in widget.elements.map { $0.state(at: tick) } }
            v.onDrawn = { [unowned self] d, c in recordDraw(d, c) }
            container.addSubview(v)
            drawView = v
        } else {
            let h = ContentHostView(frame: container.bounds)
            h.wantsLayer = true
            container.addSubview(h)
            host = h
            contentRoot.anchorPoint = .zero
            contentRoot.position = .zero
            contentRoot.bounds = CGRect(origin: .zero, size: widget.size)
            h.layer?.addSublayer(contentRoot)
        }
    }

    /// Runs `block` on the skin's executor (its thread, or main).
    func onSkin(_ block: @escaping () -> Void) {
        if let thread { thread.perform(block) } else if Thread.isMainThread { block() } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    func onSkinSync<T>(_ block: @escaping () -> T) -> T {
        if let thread { return thread.sync(block) }
        if Thread.isMainThread { return block() }
        return DispatchQueue.main.sync(execute: block)
    }

    /// Builds the layer tree and commits the first frame at `tick`, on the skin's executor; returns when done.
    func buildAndCommit(tick first: Int) {
        tick = first
        if config.mode.isView {
            drawView?.needsDisplay = true
            return
        }
        // contentRoot was attached on the main thread: commit that first (unless reproducing what happens when
        // layers are drawn before the window's context knows their tree).
        if !config.displayBeforeAttach { CATransaction.flush() }
        onSkinSync { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            build()
            CATransaction.commit()
            if !Thread.isMainThread { CATransaction.flush() }
        }
        guard !config.displayBeforeAttach else { return }
        // The first display in a later transaction, once the window's context knows the layers (otherwise CA
        // draws them again on the main thread in the window's color space).
        CATransaction.flush()
        onSkinSync { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for l in firstDisplay {
                l.setNeedsDisplay()
                l.displayIfNeeded()
            }
            firstDisplay = []
            CATransaction.commit()
            if !Thread.isMainThread { CATransaction.flush() }
        }
    }

    /// E layers waiting for their first display (see buildAndCommit).
    private var firstDisplay: [CALayer] = []

    private func displaySoon(_ l: CALayer) {
        if config.displayBeforeAttach {
            l.setNeedsDisplay()
            l.displayIfNeeded()
        } else {
            firstDisplay.append(l)
        }
    }

    func show() { panel.orderFrontRegardless() }

    func close() {
        stop()
        // The paint closures hold this object unowned: a display cycle AppKit already scheduled, or CA drawing a
        // layer on the main thread, must not reach it once it is gone (seen at 60 Hz: "read an unowned reference
        // but object was already destroyed").
        drawView?.paint = nil
        drawView?.onDrawn = nil
        if config.mode.isLayered {
            onSkinSync { [self] in
                for l in groupLayers { l.paint = nil }
                for l in [single, topLayer] { (l as? PaintLayer)?.paint = nil }
            }
        }
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Building

    private func configure(_ l: CALayer) {
        l.contentsScale = scale
        l.needsDisplayOnBoundsChange = false
        l.anchorPoint = .zero
        switch config.format {
        case .auto: break
        case .rgba8: l.contentsFormat = .RGBA8Uint
        case .rgba16f: l.contentsFormat = .RGBA16Float
        }
    }

    private func build() {
        let size = widget.size
        switch config.mode {
        case .A, .B:
            break
        case .E1:
            let l = PaintLayer()
            l.label = "\(config.label)"
            configure(l)
            l.frame = CGRect(origin: .zero, size: size)
            l.paint = { [unowned self] ctx in widget.draw(ctx, tick: tick) }
            contentRoot.addSublayer(l)
            displaySoon(l)
            single = l
        case .D1:
            let l = QuietLayer()
            configure(l)
            l.frame = CGRect(origin: .zero, size: size)
            contentRoot.addSublayer(l)
            singlePool = makePool(Int(size.width * scale), Int(size.height * scale))
            single = l
            drawSingleD()
        case .EP, .DP:
            let p = partition(widget, scale: scale)
            part = p
            let baseImage = config.baseInWindowSpace
                ? renderBaseInWindowSpace(p) : renderBase(widget, p, tick: tick)
            base = baseImage
            if config.baseSurface { baseSurface = surface(from: baseImage) }
            for t in p.tiles { tileLayers.append(makeTile(t, window: p.window)) }
            for t in tileLayers { contentRoot.addSublayer(t) }
            for g in p.groups { baseCrops[g.id] = baseImage.cropping(to: g.box.cg) }
            if config.scratch { drawScratch(Array(p.groups.indices)) }
            if config.mode == .EP {
                for g in p.groups {
                    let l = PaintLayer()
                    l.label = "\(config.label) group"
                    configure(l)
                    l.frame = g.box.points(scale)
                    l.paint = { [unowned self] ctx in paintGroup(g, ctx) }
                    contentRoot.addSublayer(l)
                    displaySoon(l)
                    groupLayers.append(l)
                }
            } else {
                for g in p.groups {
                    let l = QuietLayer()
                    configure(l)
                    l.frame = g.box.points(scale)
                    contentRoot.addSublayer(l)
                    groupSurfaceLayers.append(l)
                    pools.append(makePool(g.box.width, g.box.height))
                }
                for i in p.groups.indices { drawGroupD(i) }
            }
        case .OVE:
            let bottom = PaintLayer()
            bottom.label = "\(config.label) panel"
            configure(bottom)
            bottom.frame = CGRect(origin: .zero, size: size)
            let baseList = baseElements()
            bottom.paint = { [unowned self] ctx in widget.draw(ctx, tick: tick, baseList) }
            let top = PaintLayer()
            top.label = "\(config.label) content"
            configure(top)
            top.frame = bottom.frame
            let rest = Array(widget.elements.dropFirst(baseList.count))
            top.paint = { [unowned self] ctx in widget.draw(ctx, tick: tick, rest) }
            contentRoot.addSublayer(bottom)
            contentRoot.addSublayer(top)
            for l in [bottom, top] { displaySoon(l) }
            single = bottom
            topLayer = top
        case .OVD:
            let baseList = baseElements()
            let rest = Array(widget.elements.dropFirst(baseList.count))
            let bottom = QuietLayer(), top = QuietLayer()
            for l in [bottom, top] {
                configure(l)
                l.frame = CGRect(origin: .zero, size: size)
                contentRoot.addSublayer(l)
            }
            bottom.contents = renderWidget(widget, tick: tick, scale: scale, baseList)
            top.contents = renderWidget(widget, tick: tick, scale: scale, rest)
            single = bottom
            topLayer = top
        }
    }

    /// The base drawn in the window's color space (the screen's unless set), 16-bit float when the E layers are.
    private func renderBaseInWindowSpace(_ p: Partition) -> CGImage {
        let space = panel.colorSpace?.cgColorSpace ?? panel.screen?.colorSpace?.cgColorSpace ?? sRGB
        let half = config.format == .rgba16f
        let info = half ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue : bgraInfo
        let ctx = CGContext(data: nil, width: p.window.width, height: p.window.height, bitsPerComponent: half ? 16 : 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        ctx.translateBy(x: 0, y: CGFloat(p.window.height))
        ctx.scaleBy(x: scale, y: -scale)
        widget.draw(ctx, tick: tick, p.base.map { widget.elements[$0] })
        return ctx.makeImage()!
    }

    private func baseElements() -> [Element] {
        Array(widget.elements.prefix { $0.big })
    }

    private func makePool(_ w: Int, _ h: Int) -> SurfacePool {
        if config.cgImages {
            return SurfacePool(width: w, height: h, space: panel.colorSpace?.cgColorSpace ?? sRGB, halfFloat: false,
                               images: true)
        }
        let space = config.dDisplaySpace ? (panel.screen?.colorSpace?.cgColorSpace ?? sRGB)
            : (config.dHalfFloat ? CGColorSpace(name: CGColorSpace.extendedSRGB)! : sRGB)
        return SurfacePool(width: w, height: h, space: space, halfFloat: config.dHalfFloat)
    }

    /// A base tile: the shared base bitmap through contentsRect, nearest-neighbour sampling.
    private func makeTile(_ t: PixelRect, window: PixelRect) -> QuietLayer {
        let l = QuietLayer()
        l.contentsScale = scale
        l.anchorPoint = .zero
        l.frame = t.points(scale)
        l.contents = baseSurface ?? base
        l.contentsRect = unitRect(t, in: window)
        l.contentsGravity = .resize
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        return l
    }

    /// contentsRect for a pixel rectangle of the whole-window image. The unit square's origin is the image's
    /// top-left row here (verified on screen by `q6`: tiles read back byte for byte).
    private func unitRect(_ t: PixelRect, in window: PixelRect) -> CGRect {
        let W = CGFloat(window.width), H = CGFloat(window.height)
        return CGRect(x: CGFloat(t.x0) / W, y: CGFloat(t.y0) / H, width: CGFloat(t.width) / W,
                      height: CGFloat(t.height) / H)
    }

    private func surface(from image: CGImage) -> IOSurface? {
        let pool = SurfacePool(width: image.width, height: image.height, space: sRGB, halfFloat: false)
        guard let (s, ctx) = pool.next() else { return nil }
        s.lock(options: [], seed: nil)
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.flush()
        s.unlock(options: [], seed: nil)
        return s
    }

    /// E group: base pixels under the box copied in, then the group's elements (all in the layer's own context).
    /// +scratch: the group's box copied out of the scratch bitmap instead.
    private func paintGroup(_ g: Group, _ ctx: CGContext) {
        let size = g.box.points(scale).size
        if config.scratch, let crop = scratchImage?.cropping(to: g.box.cg) {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            drawImage(ctx, crop, in: CGRect(origin: .zero, size: size), interpolation: .none)
            ctx.restoreGState()
            return
        }
        if let crop = baseCrops[g.id] {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            drawImage(ctx, crop, in: CGRect(origin: .zero, size: size), interpolation: .none)
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.translateBy(x: -CGFloat(g.box.x0) / scale, y: -CGFloat(g.box.y0) / scale)
        widget.draw(ctx, tick: tick, g.elements.map { widget.elements[$0] })
        ctx.restoreGState()
    }

    private func drawGroupD(_ i: Int) {
        guard let p = part, let base else { return }
        let g = p.groups[i]
        if pools[i].images {
            // C: our own bitmap, then an image of it as the contents.
            guard let ctx = pools[i].nextImageContext() else { return }
            if config.scratch, let crop = scratchImage?.cropping(to: g.box.cg) {
                ctx.saveGState()
                ctx.setBlendMode(.copy)
                ctx.interpolationQuality = .none
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: g.box.width, height: g.box.height))
                ctx.restoreGState()
            } else {
                drawGroup(widget, g, base: base, scale: scale, tick: tick, into: ctx, baseCrop: baseCrops[g.id])
            }
            groupSurfaceLayers[i].contents = ctx.makeImage()
            return
        }
        guard let (s, ctx) = pools[i].next() else { return }
        s.lock(options: [], seed: nil)
        if config.scratch, let crop = scratchImage?.cropping(to: g.box.cg) {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: g.box.width, height: g.box.height))
            ctx.restoreGState()
        } else {
            drawGroup(widget, g, base: base, scale: scale, tick: tick, into: ctx, baseCrop: baseCrops[g.id])
        }
        ctx.flush()
        s.unlock(options: [], seed: nil)
        groupSurfaceLayers[i].contents = s
    }

    private func drawSingleD() {
        if let pool = singlePool, pool.images {
            guard let ctx = pool.nextImageContext() else { return }
            ctx.saveGState()
            ctx.clear(CGRect(x: 0, y: 0, width: pool.width, height: pool.height))
            ctx.translateBy(x: 0, y: CGFloat(pool.height))
            ctx.scaleBy(x: scale, y: -scale)
            widget.draw(ctx, tick: tick)
            ctx.restoreGState()
            single?.contents = ctx.makeImage()
            return
        }
        guard let pool = singlePool, let (s, ctx) = pool.next() else { return }
        s.lock(options: [], seed: nil)
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: pool.width, height: pool.height))
        ctx.translateBy(x: 0, y: CGFloat(pool.height))
        ctx.scaleBy(x: scale, y: -scale)
        widget.draw(ctx, tick: tick)
        ctx.restoreGState()
        ctx.flush()
        s.unlock(options: [], seed: nil)
        single?.contents = s
    }

    /// +scratch: restores the base under the boxes of `groups` in the scratch bitmap, draws their elements at their
    /// window position, and keeps an image of the result for the groups to copy their boxes from.
    private func drawScratch(_ groups: [Int]) {
        guard let p = part, base != nil else { return }
        if scratchContext == nil {
            // In the base bitmap's color space and depth (sRGB 8-bit unless +windowSpaceBase).
            if config.baseInWindowSpace, let b = base, let space = b.colorSpace {
                scratchContext = CGContext(data: nil, width: b.width, height: b.height,
                                           bitsPerComponent: b.bitsPerComponent, bytesPerRow: 0, space: space,
                                           bitmapInfo: b.bitmapInfo.rawValue)
                scratchContext?.translateBy(x: 0, y: CGFloat(b.height))
                scratchContext?.scaleBy(x: scale, y: -scale)
            } else {
                scratchContext = bitmapContext(widget.size, scale: scale)
            }
        }
        guard let ctx = scratchContext else { return }
        for i in groups {
            let g = p.groups[i]
            guard let crop = baseCrops[g.id] else { continue }
            ctx.saveGState()
            ctx.concatenate(ctx.ctm.inverted())
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: g.box.x0, y: p.window.height - g.box.y1, width: g.box.width,
                                      height: g.box.height))
            ctx.restoreGState()
        }
        for i in groups { widget.draw(ctx, tick: tick, p.groups[i].elements.map { widget.elements[$0] }) }
        scratchImage = ctx.makeImage()
    }

    // MARK: Updating

    /// Starts an update timer on the skin's executor: every `interval` seconds the next tick is drawn (only the
    /// groups whose elements changed) and committed.
    func start(interval: Double, after delay: Double = 0) {
        // Every update drains its own autorelease pool (see RunLoopThread.perform). `delay` shifts the first update
        // (and so every later one) by that much.
        let t = Timer(fire: Date().addingTimeInterval(interval + delay), interval: interval, repeats: true) {
            [unowned self] _ in autoreleasepool { step() }
        }
        t.tolerance = interval >= 0.5 ? 0.01 : 0.001
        if config.mode.isView || thread == nil {
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            thread?.perform { [self] in
                RunLoop.current.add(t, forMode: .default)
                timer = t
            }
        }
    }

    func stop() {
        guard let t = timer else { return }
        if let thread { thread.sync { t.invalidate() } } else { t.invalidate() }
        timer = nil
    }

    /// One update: the next tick, redrawing what changed, in one transaction (flushed off the main thread).
    /// `flush: false` (coalesced updates): the caller has a transaction open around several windows' steps and
    /// commits and flushes it once.
    func step(flush: Bool = true) {
        let next = tick + 1
        let a = now(), aCPU = threadCPUSeconds()
        tick = next
        guard widget.changed(at: next) else { return }
        if config.mode.isView {
            drawView?.needsDisplay = true
            record(commit: now(), tick: next, cost: nil)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch config.mode {
        case .A, .B:
            break
        case .E1, .OVE:
            for l in [single, topLayer].compactMap({ $0 }) {
                l.setNeedsDisplay()
                l.displayIfNeeded()
            }
        case .D1:
            drawSingleD()
        case .OVD:
            let baseList = baseElements()
            topLayer?.contents = renderWidget(widget, tick: next, scale: scale,
                                              Array(widget.elements.dropFirst(baseList.count)))
        case .EP:
            guard let p = part else { break }
            let dirty = p.groups.indices.filter { p.groups[$0].elements.contains { widget.elements[$0].changes(at: next) } }
            if config.scratch { drawScratch(dirty) }
            for i in dirty {
                groupLayers[i].setNeedsDisplay()
                groupLayers[i].displayIfNeeded()
            }
        case .DP:
            guard let p = part else { break }
            let dirty = p.groups.indices.filter { p.groups[$0].elements.contains { widget.elements[$0].changes(at: next) } }
            if config.scratch { drawScratch(dirty) }
            for i in dirty { drawGroupD(i) }
        }
        let b = now(), bCPU = threadCPUSeconds()
        CATransaction.commit()
        if flush && !Thread.isMainThread { CATransaction.flush() }
        let c = now(), cCPU = threadCPUSeconds()
        record(commit: c, tick: next, cost: b - a, commitCost: c - b, cpu: bCPU - aCPU, commitCPU: cCPU - bCPU)
    }

    /// Bytes of bitmaps this window's runtime owns itself (D surface pools, the base bitmap, the scratch bitmap).
    var ownedBitmapBytes: Int {
        var n = pools.reduce(0) { $0 + $1.bytes } + (singlePool?.bytes ?? 0) + (drawView?.ownedBitmapBytes ?? 0)
        if let base { n += base.bytesPerRow * base.height }
        if let s = baseSurface { n += s.allocationSize }
        if let c = scratchContext { n += c.bytesPerRow * c.height }
        return n
    }

    /// Bitmap bytes the window's layers show now, uncompressed, each image or surface once (CA backing stores with
    /// all their buffers; for A the view's own layer).
    var layerBitmapBytes: Int {
        if let l = drawView?.layer { return nominalBitmapBytes(l) }
        return nominalBitmapBytes(contentRoot)
    }
}
