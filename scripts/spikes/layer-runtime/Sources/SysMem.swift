// Memory that this process's phys_footprint does not see. phys_footprint leaves out the pages of CGImages made from
// bitmap contexts once Core Animation has handed them to the window server (they come back into the footprint when
// the window is ordered out), and `top` shows WindowServer's footprint growing by the same 12–13 MB for one image or
// eight separate copies of it (q6). So neither can rank ways that hand pixels over as images against ways that keep
// them in CA backing stores or IOSurfaces.
//
// `sysmem` measures what opening windows costs the whole machine, with a positive control that must show up:
//
//   sysmem --control none|single|copies [--window-cs default|srgb]
//        an 800 × 800 pt window (1600 × 1600 px): empty, one layer showing a 9.77 MB image of random pixels (which
//        the memory compressor cannot shrink), or 8 layers each showing its own copy of it (78 MB of distinct
//        pixels). copies − single must come out near 7 × 9.77 = 68 MB for a method to be trusted.
//   sysmem --scenario ten|design|sixty --mode … [--count N] [--one-thread]   widgets updating at the scenario's rate
//        (options as for `cost`; default 20 System widgets, 12 design skins, 12 visualizers; windows overlap when they
//        do not fit; --one-thread: all widgets on one skin thread, to tell the layers' memory from the threads')
//
//   --cycles N   open / close cycles in this process (default 5)
//   --settle S   seconds the windows run before the "open" sample (default 20 for widgets: CA adds second buffers to
//                layers that keep updating within 5–20 s; 4 for the controls)
//
// Each cycle: a sample, open, wait `settle`, a sample, close, wait 4 s, a sample. A sample is the median of 7 readings
// 0.25 s apart (with --quiet-gpu it is taken only when the readings agree, the GPU's memory in use within 4 MB,
// retried up to 8 times otherwise). The steps of every cycle are kept (open: after − before, close: after closing −
// open).
//
// Readings: the GPU's "In use system memory" (IOAccelerator, the whole system: every IOSurface and texture, the window
// server's included), WindowServer's footprint from `top` (1 MB resolution), system-wide anonymous + wired +
// compressed pages (host_statistics64; everything the machine holds, very noisy when builds run), this process's
// phys_footprint, and this process as `footprint --vmObjectDirty` sees it (every dirty page of the VM objects mapped
// into it, also those the window server maps: see vmObjectDirtyFootprint).
import AppKit
import QuartzCore

func systemMemoryRun() -> JSON {
    let control = option("--control")
    let cycles = Int(option("--cycles") ?? "") ?? 5
    let settle = Double(option("--settle") ?? "") ?? (control == nil ? 20 : 4)
    let mb = 1024.0 * 1024.0
    var j: JSON = ["cycles": cycles, "settleSeconds": settle, "loadAverageAtStart": loadAverage(),
                   "memoryPressureAtStart": memoryPressure()]

    /// One sample (see the header).
    func sample() -> JSON {
        var attempt = 0
        var gpu: [Double] = [], system: [Double] = [], wired: [Double] = []
        while true {
            attempt += 1
            gpu = []; system = []; wired = []
            for k in 0..<7 {
                if k > 0 { pump(0.25) }
                if let g = gpuStatistics().inUseMB { gpu.append(g) }
                let s = systemMemoryMB()
                if let v = s["anonymousWiredCompressed"] as? Double { system.append(v) }
                if let v = s["wired"] as? Double { wired.append(v) }
            }
            let spread = (gpu.max() ?? 0) - (gpu.min() ?? 0)
            if !flag("--quiet-gpu") || spread <= 4 || attempt >= 8 { break }
            pump(1)
        }
        var ws: [Double] = []
        for _ in 0..<3 { if let m = windowServerMemory().mem { ws.append(m / mb) } }
        let vm = vmObjectDirtyFootprint()
        var s: JSON = ["attempts": attempt, "gpuSpreadMB": r((gpu.max() ?? 0) - (gpu.min() ?? 0), 1),
                       "footprintMB": r(physFootprint() / mb, 2), "load": loadAverage()[0],
                       "pressureLevel": memoryPressure()["pressureLevel"] ?? -1]
        if !gpu.isEmpty { s["gpuInUseMB"] = r(median(gpu), 1) }
        if !system.isEmpty { s["systemAnonymousWiredCompressedMB"] = r(median(system), 1) }
        if !wired.isEmpty { s["systemWiredMB"] = r(median(wired), 1) }
        if !ws.isEmpty { s["windowServerMB"] = r(median(ws), 0) }
        if let t = vm["totalMB"] as? Double { s["vmObjectDirtyMB"] = t }
        s["vmObjectDirtyCategoriesMB"] = vm
        return s
    }
    func step(_ a: JSON, _ b: JSON, _ key: String) -> Double? {
        guard let x = a[key] as? Double, let y = b[key] as? Double else { return nil }
        return y - x
    }

    // What to open.
    var widgets = 1
    var lastBitmaps: JSON = [:]
    var open: () -> [AnyObject] = { [] }
    /// Opens one window of the same kind on a thread of its own (the warm-up: frameworks and caches, not counted).
    var warmUp: () -> Void = {}
    var close: ([AnyObject]) -> Void = { _ in }
    if let control {
        let space = choice("--window-cs", WindowSpace.default)
        let W = 1600, H = 1600
        let scale: CGFloat = 2
        j["control"] = control
        j["windowColorSpace"] = space.rawValue
        j["imageMB"] = r(Double(W * H * 4) / mb, 2)
        open = {
            autoreleasepool {
                let size = CGSize(width: CGFloat(W) / scale, height: CGFloat(H) / scale)
                let visible = NSScreen.main?.visibleFrame ?? .zero
                let panel = makePanel(NSRect(x: visible.maxX - 20 - size.width, y: visible.minY + 20,
                                             width: size.width, height: size.height))
                if let cs = nsColorSpace(space, screen: panel.screen) { panel.colorSpace = cs }
                let host = ContentHostView(frame: NSRect(origin: .zero, size: size))
                host.wantsLayer = true
                panel.contentView = host
                let root = QuietLayer()
                root.anchorPoint = .zero
                root.bounds = CGRect(origin: .zero, size: size)
                host.layer?.addSublayer(root)
                let image = q6BaseImage(W, H, noise: true)
                let n = control == "copies" ? 8 : control == "single" ? 1 : 0
                for k in 0..<n {
                    // Each layer its own copy (a new buffer), offset so every one is visible.
                    let copy = n == 1 ? image : Pixels.of(image).image(space: sRGB)
                    let l = QuietLayer()
                    l.anchorPoint = .zero
                    l.contentsScale = scale
                    l.frame = CGRect(x: CGFloat(k) * 4, y: CGFloat(k) * 4, width: size.width - 28,
                                     height: size.height - 28)
                    l.contents = copy
                    root.addSublayer(l)
                }
                CATransaction.flush()
                panel.orderFrontRegardless()
                return [panel]
            }
        }
        close = { objects in
            autoreleasepool {
                for case let p as NSPanel in objects {
                    p.orderOut(nil)
                    p.close()
                    p.contentView = nil
                }
            }
        }
    } else {
        let mode = choice("--mode", Mode.EP)
        let scenario = scenarioOption()
        var config = Config(mode: mode)
        config.format = choice("--format", FormatChoice.rgba8)
        config.windowSpace = choice("--window-cs", WindowSpace.default)
        config.baseSurface = mode == .DP && !flag("--cgimage")
        config.baseInWindowSpace = flag("--window-space-base")
        config.scratch = flag("--scratch")
        config.keptPictures = flag("--kept")
        config.cgImages = flag("--cgimage")
        let (make, defaultCount, interval): (() -> Widget, Int, Double) = {
            switch scenario {
            case "design": return ({ Widgets.design() }, 12, 1.0)
            case "sixty": return ({ Widgets.visualizer() }, 12, 1.0 / 60)
            default: return ({ Widgets.system() }, 20, 1.0)
            }
        }()
        widgets = Int(option("--count") ?? "") ?? defaultCount
        j["mode"] = mode.rawValue
        j["config"] = config.label
        j["scenario"] = scenario
        j["widgets"] = widgets
        let size = make().size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        j["oneBitmapOfTheWindowMB"] = r(Double(size.width * scale * size.height * scale) * 4 / mb, 3)
        var threads: [RunLoopThread] = []
        let oneThread = flag("--one-thread")
        j["oneSkinThread"] = oneThread
        for i in 0..<(oneThread ? 1 : widgets) { threads.append(RunLoopThread.make("skin \(i)")) }
        open = {
            autoreleasepool {
                var ws: [SkinWindow] = []
                for i in 0..<widgets {
                    let w = SkinWindow(make(), config, origin: packedOrigin(i, size: size),
                                       thread: threads[oneThread ? 0 : i])
                    w.buildAndCommit(tick: 0)
                    w.show()
                    w.start(interval: interval)
                    ws.append(w)
                }
                return ws
            }
        }
        let warmThread = RunLoopThread.make("warm-up")
        warmUp = {
            autoreleasepool {
                let w = SkinWindow(make(), config, origin: packedOrigin(0, size: size), thread: warmThread)
                w.buildAndCommit(tick: 0)
                w.show()
                w.start(interval: interval)
                pump(3)
                w.close()
            }
        }
        close = { objects in
            let ws = objects.compactMap { $0 as? SkinWindow }
            if let w = ws.first {
                lastBitmaps = ["layerBitmapsPerWidgetMB": r(Double(ws.reduce(0) { $0 + $1.layerBitmapBytes }) / mb
                                                           / Double(ws.count), 3),
                               "ownedBitmapsPerWidgetMB": r(Double(w.ownedBitmapBytes) / mb, 3)]
            }
            autoreleasepool { for w in ws { w.close() } }
        }
    }

    // Warm-up, not counted: the controls open and close once; widgets open one window on a thread of their own (the
    // measured windows' threads then hold nothing from before, and nothing the warm-up keeps can be released during
    // the measurement). With widgets, use one cycle per process (run.sh does): memory a closed window's thread or CA
    // keeps is released when the next cycle's windows open, which would hide part of the next open step.
    if control != nil {
        let o = open()
        pump(min(settle, 5))
        close(o)
    } else {
        warmUp()
    }
    pump(2)
    let keys = ["vmObjectDirtyMB", "footprintMB", "gpuInUseMB", "windowServerMB", "systemAnonymousWiredCompressedMB",
                "systemWiredMB"]
    var perCycle: [JSON] = []
    var opens: [String: [Double]] = [:], closes: [String: [Double]] = [:]
    for _ in 0..<cycles {
        let a = sample()
        let o = open()
        pump(settle)
        let b = sample()
        close(o)
        pump(4)
        let c = sample()
        var e: JSON = ["before": a, "open": b, "closed": c]
        var steps: JSON = [:]
        for k in keys {
            if let x = step(a, b, k) {
                steps[k + "Open"] = r(x, 1)
                opens[k, default: []].append(x)
            }
            if let y = step(b, c, k) {
                steps[k + "Close"] = r(y, 1)
                closes[k, default: []].append(y)
            }
        }
        e["steps"] = steps
        perCycle.append(e)
    }
    j["cycles"] = perCycle
    var summary: JSON = [:]
    for k in keys {
        guard let o = opens[k], let c = closes[k], !o.isEmpty else { continue }
        // The open step and the negated close step estimate the same thing; their mean per cycle cancels a drift
        // that runs through the cycle.
        let both = zip(o, c).map { ($0 - $1) / 2 }
        summary[k] = ["openStepMedian": r(median(o), 1), "closeStepMedian": r(median(c), 1),
                      "meanOfOpenAndMinusClose": r(median(both), 1),
                      "perWidget": r(median(both) / Double(widgets), 3),
                      "openSteps": o.map { r($0, 1) }, "closeSteps": c.map { r($0, 1) }]
    }
    j["summary"] = summary
    if !lastBitmaps.isEmpty { j["bitmapsAtLastClose"] = lastBitmaps }
    j["memoryPressureAtEnd"] = memoryPressure()
    return j
}

/// Grid positions at the bottom right of the main screen, as many columns and rows as fit; further windows start
/// the grid again, shifted by (13, 11) pt, so they overlap.
func packedOrigin(_ index: Int, size: CGSize, gap: CGFloat = 8) -> NSPoint {
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let cols = max(1, Int((visible.width - 40 + gap) / (size.width + gap)))
    let rows = max(1, Int((visible.height - 40 + gap) / (size.height + gap)))
    let layer = index / (cols * rows), k = index % (cols * rows)
    let col = k % cols, row = k / cols
    let x = visible.maxX - 20 - CGFloat(col + 1) * size.width - CGFloat(col) * gap - CGFloat(layer) * 13
    let y = visible.minY + 20 + CGFloat(row) * (size.height + gap) + CGFloat(layer) * 11
    return NSPoint(x: x, y: y)
}
