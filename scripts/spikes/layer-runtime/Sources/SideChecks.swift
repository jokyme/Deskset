// The side checks of the H1 experiment:
//   offmain  many layers committed from a skin thread at 60 Hz (also while the main thread is stalled): do the
//            frames reach the screen, and does every frame appear as a whole (two groups far apart both carry the
//            frame number; a capture where they differ shows half of one commit and half of another)?
//   glass    a view on the main thread (the glass) following an element the skin thread moves every frame, through
//            the plan's main-thread frames (the skin rasterizes, hands a patch to the main thread, waits at most
//            50 ms, then reclaims and commits the content alone).
//   swap     a refresh that replaces the window: blank or doubled frames in the swap.
//   click    interactive: which window gets a click on transparent, 1/255 and opaque pixels.
import AppKit
import QuartzCore

/// Our windows that the window server has on screen now. CGWindowListCreateImageFromArray composites every window
/// in its list, including one that was ordered out (still captured 0.3 s later), so window swaps must filter first.
func onScreen(_ windows: [NSWindow]) -> [NSWindow] {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    let numbers = Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
    return windows.filter { numbers.contains($0.windowNumber) }
}

/// Captures one or more of our windows as fast as possible on its own thread and hands each capture to `inspect`.
/// `onScreenOnly`: capture only those of the windows the window server has on screen (checked before and after each
/// capture; a sample where that changed in between is dropped).
final class Sampler {
    private let lock = NSLock()
    private var stopRequested = false
    private var finished = false
    private(set) var count = 0
    private var windows: [NSWindow]
    private let bounds: CGRect?
    private let onScreenOnly: Bool
    private(set) var dropped = 0
    private let inspect: (Double, Pixels?) -> Void

    /// `bounds` (global display coordinates, top-left origin): capture exactly that area of the listed windows,
    /// transparent where none of them is on screen.
    init(_ windows: [NSWindow], bounds: CGRect? = nil, onScreenOnly: Bool = false,
         inspect: @escaping (Double, Pixels?) -> Void) {
        self.windows = windows
        self.bounds = bounds
        self.onScreenOnly = onScreenOnly
        self.inspect = inspect
    }

    func setWindows(_ w: [NSWindow]) {
        lock.lock()
        windows = w
        lock.unlock()
    }

    func start() {
        let t = Thread { [self] in
            while true {
                lock.lock()
                let stop = stopRequested
                let list = windows
                lock.unlock()
                if stop { break }
                let a = now()
                var shown = list
                if onScreenOnly { shown = onScreen(list) }
                let image: CGImage?
                if shown.isEmpty {
                    image = nil
                } else {
                    image = bounds.map { captureWindows(shown, bounds: $0) }
                        ?? (shown.count == 1 ? captureWindow(shown[0]) : captureWindows(shown))
                }
                if onScreenOnly, onScreen(list).map(\.windowNumber) != shown.map(\.windowNumber) {
                    lock.lock()
                    dropped += 1
                    lock.unlock()
                    continue
                }
                let b = now()
                // Nothing of ours on screen: a blank frame (a fully transparent capture of the area).
                inspect((a + b) / 2, image.map { Pixels.of($0) } ?? (shown.isEmpty && bounds != nil
                    ? Pixels(width: Int(bounds!.width * 2), height: Int(bounds!.height * 2),
                             bytes: [UInt8](repeating: 0, count: Int(bounds!.width * 2) * Int(bounds!.height * 2) * 4))
                    : nil))
                lock.lock()
                count += 1
                lock.unlock()
            }
            lock.lock()
            finished = true
            lock.unlock()
        }
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
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
}

// MARK: Off-main commits

func offMainCommits() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    var results: JSON = [:]
    for mode in [Mode.EP, .DP] {
        for stall in [false, true] {
            let widget = Widgets.system(frameCode: true)
            var c = Config(mode: mode)
            c.windowSpace = .srgb
            c.baseSurface = mode == .DP
            let thread = RunLoopThread.make("skin")
            let w = SkinWindow(widget, c, origin: gridOrigin(0, size: widget.size, columns: 4), thread: thread)
            w.buildAndCommit(tick: 0)
            w.show()
            pump(0.5)
            let codeA = widget.elements.first { $0.name == "MeterCodeA" }!.frame.origin
            let codeB = widget.elements.first { $0.name == "MeterCodeB" }!.frame.origin
            let lock = NSLock()
            var seenA: [(Double, Int)] = [], torn = 0, unreadable = 0, samples = 0
            let sampler = Sampler([w.panel]) { t, p in
                guard let p else { return }
                let a = FrameCode.read(p, at: codeA, scale: w.scale), b = FrameCode.read(p, at: codeB, scale: w.scale)
                lock.lock()
                samples += 1
                if let a, let b {
                    seenA.append((t, a))
                    if a != b { torn += 1 }
                } else {
                    unreadable += 1
                }
                lock.unlock()
            }
            let firstCommit = w.commitTimes.count
            w.start(interval: 1.0 / 60)
            sampler.start()
            var stalls: [(Double, Double)] = []
            if stall {
                for _ in 0..<3 {
                    pump(0.7)
                    let s = now()
                    spin(0.3)
                    stalls.append((s, now()))
                }
                pump(0.7)
            } else {
                pump(3)
            }
            sampler.stop()
            w.stop()
            let commits = w.commitTimes.dropFirst(firstCommit)
            lock.lock()
            let frames = seenA
            lock.unlock()
            var longest = 0.0
            var inStallDistinct = Set<Int>()
            if var cur = frames.first {
                for f in frames.dropFirst() where f.1 != cur.1 {
                    longest = max(longest, f.0 - cur.0)
                    cur = f
                }
            }
            for f in frames where stalls.contains(where: { f.0 >= $0.0 && f.0 < $0.1 }) { inStallDistinct.insert(f.1) }
            let committedInStalls = commits.filter { t in stalls.contains { t >= $0.0 && t < $0.1 } }.count
            var r: JSON = ["layers": (w.contentRoot.sublayers ?? []).count, "samples": samples,
                           "unreadable": unreadable, "tornSamples(codeA != codeB)": torn,
                           "framesCommitted": commits.count, "distinctFramesSeen": Set(frames.map(\.1)).count,
                           "longestSameFrameMs": r2(longest * 1000)]
            if stall {
                r["mainThreadStalls"] = "3 × 300 ms"
                r["framesCommittedDuringStalls"] = committedInStalls
                r["distinctFramesSeenDuringStalls"] = inStallDistinct.count
            }
            results["\(c.label)\(stall ? " main stalled" : "")"] = r
            w.close()
            thread.stop()
            pump(0.3)
        }
    }
    return results
}

func r2(_ v: Double) -> Double { r(v, 1) }

// MARK: Glass following an element

/// What the skin thread hands the main thread in a main-thread frame.
final class ScenePatch {
    enum State: Int { case pending, appliedByMain, reclaimedBySkin }
    let frame: Int
    let rect: CGRect
    let image: CGImage
    let posted: Double
    private let lock = NSLock()
    private var _state = State.pending
    let applied = DispatchSemaphore(value: 0)

    init(frame: Int, rect: CGRect, image: CGImage) {
        self.frame = frame
        self.rect = rect
        self.image = image
        posted = now()
    }

    /// Compare and swap: only one of the main thread (→ applied) and the skin thread (→ reclaimed) wins.
    func claim(_ to: State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _state == .pending else { return false }
        _state = to
        return true
    }
}

func glassFollow() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    var results: JSON = [:]
    let useRealGlass = flag("--real-glass")
    for scenario in ["main idle", "main stalls 30 ms every 250 ms", "main stalls 120 ms every 1 s"] {
        let size = CGSize(width: 420, height: 90)
        let panel = makePanel(NSRect(origin: gridOrigin(0, size: size, columns: 1), size: size))
        panel.colorSpace = .sRGB
        let container = FlippedView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        panel.contentView = container
        // GlassPlane: the stand-in glass (magenta), under ContentHost.
        let glass: NSView
        if useRealGlass, #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: .zero)
            g.tintColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            glass = g
        } else {
            glass = NSView(frame: .zero)
            glass.wantsLayer = true
            glass.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        }
        container.addSubview(glass)
        let host = ContentHostView(frame: container.bounds)
        host.wantsLayer = true
        container.addSubview(host)
        let root = QuietLayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(origin: .zero, size: size)
        host.layer?.addSublayer(root)
        let element = QuietLayer()
        element.anchorPoint = .zero
        element.contentsScale = 2
        root.addSublayer(element)
        let elementSize = CGSize(width: 40, height: 40)
        let image: CGImage = {
            let ctx = bitmapContext(elementSize, scale: 2)
            ctx.setFillColor(RGBA(40, 200, 80).cg)
            ctx.fill(CGRect(origin: .zero, size: elementSize))
            return ctx.makeImage()!
        }()
        func rect(_ f: Int) -> CGRect {
            let x = 20 + CGFloat((f * 3) % 340)
            return CGRect(x: x, y: 25, width: elementSize.width, height: elementSize.height)
        }
        glass.frame = rect(0)
        element.frame = rect(0)
        element.contents = image
        CATransaction.flush()
        panel.orderFrontRegardless()
        pump(0.5)

        // Skin thread: 60 Hz; every frame moves the element, so every frame is a main-thread frame.
        let thread = RunLoopThread.make("skin")
        let lock = NSLock()
        var latencies: [Double] = [], reclaimed = 0, appliedCount = 0, frames = 0
        var running = true
        let mainLoop = CFRunLoopGetMain()
        func frame(_ f: Int) {
            let patch = ScenePatch(frame: f, rect: rect(f), image: image)
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
                if patch.claim(.appliedByMain) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    glass.frame = patch.rect
                    element.frame = patch.rect
                    element.contents = patch.image
                    CATransaction.commit()
                    lock.lock()
                    latencies.append(now() - patch.posted)
                    appliedCount += 1
                    lock.unlock()
                    patch.applied.signal()
                } else {
                    // The skin already committed the content: only the glass catches up.
                    glass.frame = patch.rect
                }
            }
            CFRunLoopWakeUp(mainLoop)
            if patch.applied.wait(timeout: .now() + .milliseconds(50)) == .timedOut, patch.claim(.reclaimedBySkin) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                element.frame = patch.rect
                element.contents = patch.image
                CATransaction.commit()
                CATransaction.flush()
                lock.lock()
                reclaimed += 1
                lock.unlock()
            }
            lock.lock()
            frames += 1
            lock.unlock()
        }
        var f = 0
        thread.perform {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
                lock.lock()
                let go = running
                lock.unlock()
                guard go else { timer.invalidate(); return }
                f += 1
                autoreleasepool { frame(f) }
            }
            RunLoop.current.add(t, forMode: .default)
        }
        // Sampler: where the element (green) and any visible glass (magenta) are.
        var drifted = 0, samples = 0, maxDrift = 0.0
        let sampler = Sampler([panel]) { _, p in
            guard let p else { return }
            let magenta = find(p, RGBA(255, 0, 255), scale: 2)
            lock.lock()
            samples += 1
            if let m = magenta {
                drifted += 1
                maxDrift = max(maxDrift, Double(m.width))
            }
            lock.unlock()
        }
        sampler.start()
        let duration = 4.0
        let end = now() + duration
        while now() < end {
            switch scenario {
            case "main stalls 30 ms every 250 ms":
                pump(0.22)
                spin(0.03)
            case "main stalls 120 ms every 1 s":
                pump(0.88)
                spin(0.12)
            default:
                pump(0.25)
            }
        }
        sampler.stop()
        lock.lock()
        running = false
        lock.unlock()
        pump(0.2)
        thread.stop()
        lock.lock()
        results[scenario] = ["frames": frames, "appliedByMain": appliedCount, "reclaimedBySkin": reclaimed,
                             "mainApplyLatencyP50ms": r2(percentile(latencies, 0.5) * 1000),
                             "mainApplyLatencyP99ms": r2(percentile(latencies, 0.99) * 1000),
                             "mainApplyLatencyMaxms": r2((latencies.max() ?? 0) * 1000),
                             "samples": samples, "samplesWithGlassVisibleBesideElement": drifted,
                             "maxVisibleGlassWidthPt": maxDrift, "glass": useRealGlass ? "NSGlassEffectView" : "stand-in view"]
        lock.unlock()
        panel.orderOut(nil)
        panel.close()
        pump(0.3)
    }
    return results
}

// MARK: Window swap on refresh

func refreshSwap() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let widget = Widgets.system()
    var config = Config(mode: .EP)
    config.windowSpace = .srgb
    let thread = RunLoopThread.make("skin")
    let origin = gridOrigin(0, size: widget.size, columns: 4)
    // Probe points inside the panel where only the base is (alpha of the panel there, one window).
    let probes = [CGPoint(x: 8, y: 100), CGPoint(x: 130, y: 112), CGPoint(x: 250, y: 60), CGPoint(x: 140, y: 190)]
    var results: JSON = [:]
    for variant in ["new above old, then old out", "old out, then new in",
                    "both inside NSDisableScreenUpdates", "same window, contentRoot replaced in one transaction"] {
        var current = SkinWindow(widget, config, origin: origin, thread: thread)
        current.buildAndCommit(tick: 0)
        current.show()
        pump(0.5)
        let single = captureWindow(current.panel).map { Pixels.of($0) }
        let reference = probes.map { pt -> Int in
            guard let s = single else { return 0 }
            return Int(s[Int(pt.x * 2), Int(pt.y * 2), 3])
        }
        let lock = NSLock()
        var blank = 0, doubled = 0, ok = 0, missing = 0
        // The window's area in global display coordinates (top-left origin), captured whole every time.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let area = CGRect(x: current.panel.frame.minX, y: mainHeight - current.panel.frame.maxY,
                          width: current.panel.frame.width, height: current.panel.frame.height)
        let sampler = Sampler([current.panel], bounds: area, onScreenOnly: true) { _, p in
            lock.lock()
            defer { lock.unlock() }
            guard let p, p.width >= 520 else { missing += 1; return }
            let a = probes.map { Int(p[Int($0.x * 2), Int($0.y * 2), 3]) }
            if a.allSatisfy({ $0 == 0 }) { blank += 1 } else if zip(a, reference).contains(where: { $0 > $1 + 8 }) {
                doubled += 1
            } else { ok += 1 }
        }
        sampler.start()
        var swapMs: [Double] = []
        for _ in 0..<25 {
            let t0 = now()
            if variant.hasPrefix("same window") {
                // Build a new tree under a fresh root on the skin thread, then swap roots in one transaction.
                let next = SkinWindow(widget, config, origin: origin, thread: thread)
                next.buildAndCommit(tick: 0)
                let newRoot = next.contentRoot
                thread.sync {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    let old = current.contentRoot.sublayers ?? []
                    for l in old { l.removeFromSuperlayer() }
                    for l in newRoot.sublayers ?? [] { current.contentRoot.addSublayer(l) }
                    CATransaction.commit()
                    CATransaction.flush()
                }
                next.close()
            } else {
                let next = SkinWindow(widget, config, origin: origin, thread: thread)
                next.buildAndCommit(tick: 0)
                sampler.setWindows([current.panel, next.panel])
                switch variant {
                case "old out, then new in":
                    current.panel.orderOut(nil)
                    next.panel.orderFrontRegardless()
                case "both inside NSDisableScreenUpdates":
                    NSDisableScreenUpdates()
                    next.panel.order(.above, relativeTo: current.panel.windowNumber)
                    current.panel.orderOut(nil)
                    NSEnableScreenUpdates()
                default:
                    next.panel.order(.above, relativeTo: current.panel.windowNumber)
                    current.panel.orderOut(nil)
                }
                let old = current
                current = next
                pump(0.05)
                old.close()
                sampler.setWindows([current.panel])
            }
            swapMs.append((now() - t0) * 1000)
            pump(0.15)
        }
        sampler.stop()
        lock.lock()
        results[variant] = ["swaps": 25, "samples": blank + doubled + ok + missing, "blank": blank,
                            "doubled": doubled, "ok": ok, "captureFailed": missing,
                            "droppedWhileWindowListChanged": sampler.dropped,
                            "swapMsP50": r2(percentile(swapMs, 0.5))]
        lock.unlock()
        current.close()
        pump(0.3)
    }
    thread.stop()
    return results
}

// MARK: Click-through (interactive)

final class ClickLogView: NSView {
    var name = ""
    var onClick: ((String, NSPoint) -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?(name, convert(event.locationInWindow, from: nil)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func clickThrough() -> JSON {
    // A target window behind, and a skin window (partition, skin-thread commits) in front with:
    // 1 a fully transparent hole, 2 a 1/255 hit fill, 3 opaque content, 4 the translucent panel.
    let size = CGSize(width: 360, height: 220)
    let visible = NSScreen.main?.visibleFrame ?? .zero
    let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    let target = NSPanel(contentRect: NSRect(origin: NSPoint(x: origin.x - 20, y: origin.y - 20),
                                             size: CGSize(width: size.width + 40, height: size.height + 40)),
                         styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    target.title = "Click target (behind)"
    let targetView = ClickLogView(frame: NSRect(origin: .zero, size: target.contentRect(forFrameRect: target.frame).size))
    targetView.name = "target window behind"
    targetView.wantsLayer = true
    targetView.layer?.backgroundColor = CGColor(gray: 0.85, alpha: 1)
    target.contentView = targetView
    target.level = .floating
    let skin = makePanel(NSRect(origin: origin, size: size), clickable: true)
    skin.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    skin.colorSpace = .sRGB
    let content = ClickLogView(frame: NSRect(origin: .zero, size: size))
    content.name = "skin window"
    skin.contentView = content
    let host = ContentHostView(frame: content.bounds)
    host.wantsLayer = true
    content.addSubview(host)
    let root = QuietLayer()
    root.anchorPoint = .zero
    root.bounds = CGRect(origin: .zero, size: size)
    host.layer?.addSublayer(root)
    let thread = RunLoopThread.make("skin")
    let spots: [(String, CGRect, RGBA?)] = [
        ("1 transparent hole (expect: target window behind)", CGRect(x: 20, y: 20, width: 90, height: 70), nil),
        ("2 alpha 1/255 fill (expect: skin window)", CGRect(x: 135, y: 20, width: 90, height: 70), RGBA(0, 0, 0, 1)),
        ("3 opaque content (expect: skin window)", CGRect(x: 250, y: 20, width: 90, height: 70), RGBA(40, 120, 220)),
        ("4 translucent panel (expect: skin window)", CGRect(x: 20, y: 120, width: 320, height: 80),
         RGBA(44, 46, 56, 200)),
    ]
    thread.sync {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, spot) in spots.enumerated() {
            guard let color = spot.2 else { continue }
            let l = PaintLayer()
            l.anchorPoint = .zero
            l.contentsScale = 2
            l.contentsFormat = .RGBA8Uint
            l.frame = spot.1
            l.paint = { ctx in
                ctx.setFillColor(color.cg)
                ctx.fill(CGRect(origin: .zero, size: spot.1.size))
                if color.a > 100 {
                    drawText(ctx, "\(i + 1)", Widgets.value, RGBA(255, 255, 255), in: CGRect(x: 6, y: 4, width: 30, height: 20))
                }
            }
            root.addSublayer(l)
        }
        CATransaction.commit()
        CATransaction.flush()
    }
    thread.sync {
        CATransaction.begin()
        for l in root.sublayers ?? [] { l.setNeedsDisplay(); l.displayIfNeeded() }
        CATransaction.commit()
        CATransaction.flush()
    }
    var clicks: [String] = []
    let report: (String, NSPoint) -> Void = { name, p in
        let line = "click at (\(Int(p.x)), \(Int(p.y))) in the \(name)"
        print(line)
        clicks.append(line)
    }
    targetView.onClick = report
    content.onClick = report
    target.orderFrontRegardless()
    skin.orderFrontRegardless()
    print("""
        Click once inside each numbered area of the small window in the middle of the screen:
          1 (top left, fully transparent: the grey target window shows through) → the target window must log it
          2 (top middle, looks empty: alpha 1/255) → the skin window must log it
          3 (blue square) and 4 (dark panel) → the skin window must log them
        The program ends after 90 seconds.
        """)
    pump(90)
    skin.orderOut(nil)
    target.orderOut(nil)
    thread.stop()
    return ["clicks": clicks]
}
