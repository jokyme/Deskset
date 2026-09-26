// Spike for docs/skin-threading.md: do skin frames keep reaching the screen while the main thread, or another skin,
// is busy?
//
// Two synthetic skins (borderless windows updating every 16 ms: animated bars, a CoreText label and the frame
// number drawn as a row of black and white cells) run in one of five modes:
//
//   main     today's model: a Timer on the main run loop updates the skin and the view draws in draw(_:) on main.
//   hop      each skin updates and draws into a new CGImage on its own executor (see below); the main thread sets
//            the image as the contents of the skin's layer (DispatchQueue.main.async).
//   commit   as hop, but the skin's executor sets the layer contents itself, in an explicit CATransaction.
//   surface  as commit, but the skin draws into one of a few reused IOSurfaces instead of a new bitmap per frame.
//   layer    the skin's executor has its CALayer redraw itself (setNeedsDisplay + displayIfNeeded, then commit):
//            the layer records the drawing and the window server rasterizes it, as for today's draw(_:).
//
// and one of three scenarios:
//
//   main-block  the main thread is busy for --block-ms (default 500) three times, like a busy Skin Studio.
//   slow-skin   skin B's update takes --slow-ms (default 250) four times, like heavy Lua or a big file list.
//   steady      nothing stalls: for comparing what each mode costs (run it with --no-capture).
//
// Outside main mode each skin's executor is its own serial DispatchQueue (--executor queue, the default) or a
// dedicated thread with its own run loop and an 8 MB stack (--executor thread, what the design recommends).
//
// For each skin it reports how many frames were produced and committed during those stalls and, when this process
// may capture the screen (CGPreflightScreenCaptureAccess; the spike never asks for the permission), which frames a
// sampler thread actually saw in the window: it reads the window back with CGWindowListCreateImage and decodes the
// frame number from the cells. The windows float at the top left of the main screen for a few seconds per run and
// let clicks through.
//
//     scripts/spikes/skin-threading/run.sh      every mode and scenario, then the cost table
//
// A standalone program: it does not use Deskset's code, and it is not part of the Swift package.
import AppKit
import Darwin
import IOSurface
import QuartzCore

// MARK: Options

enum Mode: String, CaseIterable { case main, hop, commit, surface, layer }
enum Scenario: String, CaseIterable { case mainBlock = "main-block", slowSkin = "slow-skin", steady }
enum Executor: String, CaseIterable { case queue, thread }

struct Options {
    var mode = Mode.commit
    var scenario = Scenario.mainBlock
    var intervalMs = 16.0
    var blockMs = 500.0
    var slowMs = 250.0
    var capture = true
    var header = true
    var executor = Executor.queue

    static let usage = """
        usage: SkinThreadingSpike [--mode main|hop|commit|surface|layer] [--scenario main-block|slow-skin|steady]
                                  [--executor queue|thread] [--interval-ms 16] [--block-ms 500] [--slow-ms 250]
                                  [--no-capture] [--no-header]
        """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func value() -> String {
            i += 1
            guard i < args.count else { fail() }
            return args[i]
        }
        func number() -> Double {
            guard let v = Double(value()), v.isFinite, v > 0 else { fail() }
            return v
        }
        func fail() -> Never {
            FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
            exit(2)
        }
        while i < args.count {
            switch args[i] {
            case "--mode":
                guard let v = Mode(rawValue: value()) else { fail() }
                o.mode = v
            case "--scenario":
                guard let v = Scenario(rawValue: value()) else { fail() }
                o.scenario = v
            case "--interval-ms": o.intervalMs = number()
            case "--block-ms": o.blockMs = number()
            case "--slow-ms": o.slowMs = number()
            case "--no-capture": o.capture = false
            case "--no-header": o.header = false
            case "--executor":
                guard let v = Executor(rawValue: value()) else { fail() }
                o.executor = v
            default: fail()
            }
            i += 1
        }
        return o
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

// MARK: Clock and records

let startTime = CACurrentMediaTime()

/// Seconds since the start (CACurrentMediaTime: monotonic, callable from any thread).
func now() -> Double { CACurrentMediaTime() - startTime }

/// Busy work until `end`: a CPU-bound stall, like layout in a big window or a long Lua function.
func spin(until end: Double) {
    while now() < end {}
}

struct Event {
    var t: Double
    var frame: Int
    /// Seconds spent: drawing (produced), setting the contents (committed) or capturing (seen).
    var cost: Double
}

enum Kind: Int { case produced, committed, seen }

/// Thread-safe event lists per skin and kind, plus the stall windows.
final class Records {
    private let lock = NSLock()
    private var events: [[[Event]]] = Array(repeating: Array(repeating: [], count: 3), count: 2)
    private var stallWindows: [(start: Double, end: Double, cause: String)] = []

    func add(_ kind: Kind, skin: Int, _ e: Event) {
        lock.lock()
        events[skin][kind.rawValue].append(e)
        lock.unlock()
    }

    func stall(_ start: Double, _ end: Double, cause: String) {
        lock.lock()
        stallWindows.append((start, end, cause))
        lock.unlock()
    }

    func list(_ kind: Kind, skin: Int) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events[skin][kind.rawValue]
    }

    var stalls: [(start: Double, end: Double, cause: String)] {
        lock.lock()
        defer { lock.unlock() }
        return stallWindows
    }
}

let records = Records()

// MARK: Skins

/// Frame numbers are drawn as `codeBits` cells after a white and a black marker cell.
let cell = 8
let codeBits = 20
let codeOrigin = CGPoint(x: 10, y: 100)

/// One synthetic skin. Its state is touched only by the thread that updates it (the main thread in `main` mode, the
/// skin's executor otherwise), like a Deskset `Skin`.
final class SpikeSkin {
    let index: Int
    let name: String
    let size = CGSize(width: 360, height: 120)
    private(set) var frame = 0
    /// Start times of the updates that take `slowMs` (slow-skin scenario, skin B).
    var slowUpdates: [Double] = []
    private var nextSlow = 0
    private let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)

    init(index: Int, name: String) {
        self.index = index
        self.name = name
    }

    func update() {
        frame += 1
        if nextSlow < slowUpdates.count, now() >= slowUpdates[nextSlow] {
            nextSlow += 1
            let start = now()
            spin(until: start + options.slowMs / 1000)
            records.stall(start, now(), cause: "\(name) slow update")
        }
    }

    /// Draws the skin into a context with a top-left origin in points.
    func draw(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.94))
        ctx.fill(CGRect(origin: .zero, size: size))
        let t = Double(frame) * 0.12
        ctx.setFillColor(index == 0 ? CGColor(srgbRed: 0.35, green: 0.78, blue: 0.98, alpha: 1)
                                    : CGColor(srgbRed: 0.98, green: 0.62, blue: 0.30, alpha: 1))
        for i in 0..<48 {
            let h = (sin(t + Double(i) * 0.35) * 0.5 + 0.5) * 60 + 4
            ctx.fill(CGRect(x: 10 + Double(i) * 7, y: 92 - h, width: 5, height: h))
        }
        let label = "\(name) · frame \(frame)" as CFString
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)]
            as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label, attributes))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: 200, y: 112)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        // The frame number: marker cells white, black, then the bits (white = 1), most significant first.
        let bits = [true, false] + (0..<codeBits).map { (frame >> (codeBits - 1 - $0)) & 1 == 1 }
        for (i, bit) in bits.enumerated() {
            ctx.setFillColor(CGColor(gray: bit ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: codeOrigin.x + Double(i * cell), y: codeOrigin.y, width: Double(cell),
                            height: Double(cell)))
        }
    }

    /// Draws into a new bitmap at `scale` pixels per point (what a skin queue would do).
    func image(scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        return ctx.makeImage()
    }
}

/// A few IOSurfaces a skin draws into in turn (surface mode). A surface the window server still shows or reads is
/// skipped (`isInUse`); when all are in use another one is made, up to `limit`.
final class SurfacePool {
    private var surfaces: [(surface: IOSurface, context: CGContext)] = []
    private let width: Int, height: Int
    private let limit = 4

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// A surface that nothing reads now, with a context (top-left origin, `scale` pixels per point) to draw into,
    /// or nil when every surface is busy.
    func next(scale: CGFloat) -> (surface: IOSurface, context: CGContext)? {
        if let free = surfaces.first(where: { !$0.surface.isInUse }) { return free }
        guard surfaces.count < limit, let made = make(scale: scale) else { return nil }
        surfaces.append(made)
        return made
    }

    private func make(scale: CGFloat) -> (surface: IOSurface, context: CGContext)? {
        let rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: rowBytes,
            .pixelFormat: 0x4247_5241,  // 'BGRA'
        ]), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: surface.bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        if let colorSpace = space.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, colorSpace)
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        return (surface, context)
    }
}

/// Today's skin view: draws the skin in draw(_:) on the main thread.
final class SpikeView: NSView {
    var onDraw: ((CGContext) -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        onDraw?(ctx)
    }
}

/// A layer that draws the skin when the skin's executor asks it to (layer mode). Under a flipped view's layer its
/// context has a top-left origin, like draw(_:).
final class SkinDrawLayer: CALayer {
    var onDraw: ((CGContext) -> Void)?

    override func draw(in ctx: CGContext) {
        onDraw?(ctx)
    }
}

// MARK: Screen sampler

typealias CreateWindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

/// CGWindowListCreateImage, looked up at run time: the macOS 15 SDK made it unavailable to new code, but it still
/// reads back this process's own windows without prompting when screen capture is allowed.
let createWindowImage: CreateWindowImage? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
    .map { unsafeBitCast($0, to: CreateWindowImage.self) }

/// Captures the skin windows over and over on its own thread (never the main thread) and records the frame numbers
/// it sees.
final class Sampler {
    let windows: [(skin: Int, number: UInt32, size: CGSize)]
    private let lock = NSLock()
    private var stopRequested = false
    private var finished = false

    init(windows: [(skin: Int, number: UInt32, size: CGSize)]) {
        self.windows = windows
    }

    func start() {
        let thread = Thread { [self] in
            while !isStopRequested {
                for w in windows {
                    let a = now()
                    // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | NominalResolution.
                    guard let image = createWindowImage?(.null, 1 << 3, w.number, 1 << 0 | 1 << 4)?
                        .takeRetainedValue() else { continue }
                    let b = now()
                    if let frame = Sampler.decode(image, size: w.size) {
                        records.add(.seen, skin: w.skin, Event(t: (a + b) / 2, frame: frame, cost: b - a))
                    }
                }
            }
            lock.lock()
            finished = true
            lock.unlock()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func stopAndWait() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        while true {
            lock.lock()
            let done = finished
            lock.unlock()
            if done { return }
            usleep(1000)
        }
    }

    /// The frame number drawn by `SpikeSkin.draw`, or nil when the cells cannot be read (a torn or empty capture).
    static func decode(_ image: CGImage, size: CGSize) -> Int? {
        let w = Int(size.width), h = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Rows are stored top-down: row y is y points from the top of the window.
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let y = Int(codeOrigin.y) + cell / 2
        func bit(_ i: Int) -> Bool? {
            let x = Int(codeOrigin.x) + i * cell + cell / 2
            let o = (y * w + x) * 4
            let luminance = (Int(pixels[o]) + Int(pixels[o + 1]) + Int(pixels[o + 2])) / 3
            return luminance > 170 ? true : luminance < 85 ? false : nil
        }
        guard bit(0) == true, bit(1) == false else { return nil }
        var value = 0
        for i in 0..<codeBits {
            guard let b = bit(2 + i) else { return nil }
            value = value << 1 | (b ? 1 : 0)
        }
        return value
    }
}

// MARK: Running the skins

/// A dedicated thread with its own run loop (--executor thread): a small "main thread" for one skin.
final class RunLoopThread: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A source keeps the run loop running while nothing else is scheduled.
        var context = CFRunLoopSourceContext()
        CFRunLoopAddSource(loop, CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
        ready.signal()
        CFRunLoopRun()
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    /// Runs `block` on this thread, after the blocks already posted.
    func perform(_ block: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }
}

/// One skin with its window, and the timer that drives it in the chosen mode.
final class SkinRun {
    let skin: SpikeSkin
    let panel: NSPanel
    let view: SpikeView
    /// Layer whose contents the skin's executor sets (hop, commit and surface modes) or redraws (layer mode).
    let content = SkinDrawLayer()
    let queue: DispatchQueue
    private var timer: Timer?
    private var source: DispatchSourceTimer?
    private var thread: RunLoopThread?
    /// The update timer on `thread` (touched only there).
    private var threadTimer: Timer?
    private let scale: CGFloat
    private lazy var surfaces = SurfacePool(width: Int(skin.size.width * scale), height: Int(skin.size.height * scale))

    init(skin: SpikeSkin, origin: CGPoint) {
        self.skin = skin
        panel = NSPanel(contentRect: NSRect(origin: origin, size: skin.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        view = SpikeView(frame: NSRect(origin: .zero, size: skin.size))
        view.wantsLayer = true
        panel.contentView = view
        scale = panel.backingScaleFactor
        queue = DispatchQueue(label: "spike.skin.\(skin.index)", qos: .userInteractive)
    }

    func start() {
        panel.orderFrontRegardless()
        let interval = options.intervalMs / 1000
        switch options.mode {
        case .main:
            view.onDraw = { [skin] ctx in
                let a = now()
                skin.draw(ctx)
                let b = now()
                records.add(.committed, skin: skin.index, Event(t: b, frame: skin.frame, cost: b - a))
            }
            let t = Timer(timeInterval: interval, repeats: true) { [skin, view] _ in
                skin.update()
                records.add(.produced, skin: skin.index, Event(t: now(), frame: skin.frame, cost: 0))
                view.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        case .hop, .commit, .surface, .layer:
            content.frame = view.layer?.bounds ?? view.bounds
            content.contentsScale = scale
            content.actions = ["contents": NSNull()]
            if options.mode == .layer { content.onDraw = { [skin] ctx in skin.draw(ctx) } }
            view.layer?.addSublayer(content)
            switch options.executor {
            case .queue:
                let s = DispatchSource.makeTimerSource(queue: queue)
                s.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
                s.setEventHandler { [self] in tick() }
                s.resume()
                source = s
            case .thread:
                let t = RunLoopThread()
                t.name = "spike.skin.\(skin.index)"
                t.stackSize = 8 << 20
                t.qualityOfService = .userInteractive
                t.startAndWait()
                t.perform { [self] in
                    let timer = Timer(timeInterval: interval, repeats: true) { [self] _ in tick() }
                    timer.tolerance = 0.001
                    RunLoop.current.add(timer, forMode: .default)
                    threadTimer = timer
                }
                thread = t
            }
        }
    }

    /// One update on the skin's executor: update, draw into an image, hand it to the layer.
    private func tick() {
        skin.update()
        let frame = skin.frame
        let a = now()
        if options.mode == .layer {
            // The layer records the drawing (on this queue); the commit sends it to the window server.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.setNeedsDisplay()
            content.displayIfNeeded()
            let b = now()
            CATransaction.commit()
            CATransaction.flush()
            let c = now()
            records.add(.produced, skin: skin.index, Event(t: b, frame: frame, cost: b - a))
            records.add(.committed, skin: skin.index, Event(t: c, frame: frame, cost: c - b))
            return
        }
        if options.mode == .surface {
            // A surface nothing reads now: cleared, drawn, then shown by the layer.
            guard let (surface, context) = surfaces.next(scale: scale) else { return }
            surface.lock(options: [], seed: nil)
            context.clear(CGRect(origin: .zero, size: skin.size))
            skin.draw(context)
            context.flush()
            surface.unlock(options: [], seed: nil)
            let b = now()
            records.add(.produced, skin: skin.index, Event(t: b, frame: frame, cost: b - a))
            commit(surface, frame: frame)
            return
        }
        guard let image = skin.image(scale: scale) else { return }
        let b = now()
        records.add(.produced, skin: skin.index, Event(t: b, frame: frame, cost: b - a))
        switch options.mode {
        case .hop:
            DispatchQueue.main.async { [self] in commit(image, frame: frame) }
        case .commit:
            commit(image, frame: frame)
        case .main, .surface, .layer:
            break
        }
    }

    private func commit(_ contents: Any, frame: Int) {
        let a = now()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = contents
        CATransaction.commit()
        // A queue thread has no run loop to commit implicit transactions at its end.
        if !Thread.isMainThread { CATransaction.flush() }
        let b = now()
        records.add(.committed, skin: skin.index, Event(t: b, frame: frame, cost: b - a))
    }

    func stop() {
        timer?.invalidate()
        if let source {
            source.cancel()
            queue.sync {}
        }
        if let thread {
            let stopped = DispatchSemaphore(value: 0)
            thread.perform { [self] in
                threadTimer?.invalidate()
                CFRunLoopStop(CFRunLoopGetCurrent())
                stopped.signal()
            }
            stopped.wait()
        }
    }
}

// MARK: Report

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(Int((Double(sorted.count - 1) * p).rounded()), sorted.count - 1)]
}

func overlaps(_ a: Double, _ b: Double, _ stalls: [(start: Double, end: Double, cause: String)]) -> Bool {
    stalls.contains { a < $0.end && b > $0.start }
}

func inStall(_ t: Double, _ stalls: [(start: Double, end: Double, cause: String)]) -> Bool {
    stalls.contains { t >= $0.start && t < $0.end }
}

func format(_ v: Double, _ digits: Int = 0) -> String {
    v.isNaN ? "–" : String(format: "%.\(digits)f", v)
}

/// One Markdown table row per skin.
func report(runs: [SkinRun], capturing: Bool, duration: Double, cpuSeconds: Double, spunSeconds: Double,
            windowServerSeconds: Double?) {
    let stalls = records.stalls
    let stallSeconds = stalls.reduce(0) { $0 + $1.end - $1.start }
    if options.header {
        print("| mode | scenario | skin | frames produced in stalls | committed in stalls | distinct frames seen "
              + "on screen in stalls | longest on-screen freeze, in stalls / elsewhere (ms) | draw p50 (µs) "
              + "| commit p50 / p99 (µs) | CPU, spike / WindowServer (% of a core) |")
        print("|---|---|---|---|---|---|---|---|---|---|")
    }
    for run in runs {
        let i = run.skin.index
        let produced = records.list(.produced, skin: i)
        let committed = records.list(.committed, skin: i)
        let seen = records.list(.seen, skin: i).sorted { $0.t < $1.t }
        let expected = Int((stallSeconds / (options.intervalMs / 1000)).rounded())
        let producedInStall = produced.filter { inStall($0.t, stalls) }.count
        let committedInStall = committed.filter { inStall($0.t, stalls) }.count
        var distinctInStall = Set<Int>()
        for e in seen where inStall(e.t, stalls) { distinctInStall.insert(e.frame) }
        // A frame's time on screen: from the first sample that shows it to the first sample that shows another one.
        var freezeInStall = 0.0, freezeElsewhere = 0.0
        if var current = seen.first {
            for e in seen.dropFirst() where e.frame != current.frame {
                let held = e.t - current.t
                if overlaps(current.t, e.t, stalls) {
                    freezeInStall = max(freezeInStall, held)
                } else {
                    freezeElsewhere = max(freezeElsewhere, held)
                }
                current = e
            }
        }
        let drawCosts = (options.mode == .main ? committed : produced).map(\.cost)
        let commitCosts = options.mode == .main ? [] : committed.map(\.cost)
        let windowServer = windowServerSeconds.map { format($0 / duration * 100) } ?? "?"
        let cpu = run.skin.index == 0 ? "\(format((cpuSeconds - spunSeconds) / duration * 100)) / \(windowServer)" : ""
        let screen = capturing ? "\(distinctInStall.count)" : "n/a"
        let freeze = capturing ? "\(format(freezeInStall * 1000)) / \(format(freezeElsewhere * 1000))" : "n/a"
        let mode = options.mode.rawValue + (options.mode != .main && options.executor == .thread ? " (thread)" : "")
        print("| \(mode) | \(options.scenario.rawValue) | \(run.skin.name) | \(producedInStall) of "
              + "\(expected) | \(committedInStall) | \(screen) | \(freeze) "
              + "| \(format(percentile(drawCosts, 0.5) * 1e6)) "
              + "| \(format(percentile(commitCosts, 0.5) * 1e6)) / \(format(percentile(commitCosts, 0.99) * 1e6)) "
              + "| \(cpu) |")
    }
    let samples = runs.map { records.list(.seen, skin: $0.skin.index) }
    if capturing, options.header {
        let captureCosts = samples.flatMap { $0.map(\.cost) }
        let rate = Double(samples.map(\.count).reduce(0, +)) / Double(max(samples.count, 1)) / duration
        FileHandle.standardError.write(("screen samples: \(format(rate)) per second per skin, capture p50 "
            + "\(format(percentile(captureCosts, 0.5) * 1000, 1)) ms\n").data(using: .utf8)!)
    }
}

func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// CPU seconds WindowServer has used so far (from `ps`, 10 ms resolution), or nil. It rasterizes what today's
/// draw(_:) records, so a mode that draws pixels itself moves work from WindowServer into Deskset. Other apps' drawing
/// counts too: compare runs made back to back on a quiet screen.
func windowServerCPUTime() -> Double? {
    func run(_ path: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let pid = run("/usr/bin/pgrep", ["-x", "WindowServer"])?.split(separator: "\n").first,
          let time = run("/bin/ps", ["-o", "time=", "-p", String(pid)]) else { return nil }
    // [hours:]minutes:seconds.hundredths
    let parts = time.split(separator: ":").compactMap { Double($0) }
    guard !parts.isEmpty else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
}

// MARK: Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

DispatchQueue.main.async {
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let a = SpikeSkin(index: 0, name: "Skin A"), b = SpikeSkin(index: 1, name: "Skin B")
    let runs = [a, b].enumerated().map { i, skin in
        SkinRun(skin: skin, origin: CGPoint(x: visible.minX + 40, y: visible.maxY - 40 - CGFloat(i + 1) * 140))
    }
    let capturing = options.capture && CGPreflightScreenCaptureAccess() && createWindowImage != nil
    if options.capture && !capturing {
        FileHandle.standardError.write("screen capture not allowed for this process: on-screen columns are n/a\n"
            .data(using: .utf8)!)
    }
    let duration: Double
    var spun = 0.0
    switch options.scenario {
    case .mainBlock:
        duration = 5.5
        for start in [1.0, 2.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                let s = now()
                spin(until: s + options.blockMs / 1000)
                records.stall(s, now(), cause: "main thread busy")
                spun += now() - s
            }
        }
    case .slowSkin:
        duration = 5.0
        b.slowUpdates = [1.0, 2.0, 3.0, 4.0].map { now() + $0 }
        spun = 4 * options.slowMs / 1000
    case .steady:
        duration = 5.0
    }
    let sampler = Sampler(windows: runs.map { ($0.skin.index, UInt32($0.panel.windowNumber), $0.skin.size) })
    let cpuStart = cpuTime()
    let windowServerStart = windowServerCPUTime()
    for run in runs { run.start() }
    // Let the windows appear before sampling.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        if capturing { sampler.start() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        for run in runs { run.stop() }
        if capturing { sampler.stopAndWait() }
        let cpu = cpuTime() - cpuStart
        let windowServer = windowServerCPUTime().flatMap { end in windowServerStart.map { end - $0 } }
        report(runs: runs, capturing: capturing, duration: duration, cpuSeconds: cpu, spunSeconds: spun,
               windowServerSeconds: windowServer)
        exit(0)
    }
}
app.run()
