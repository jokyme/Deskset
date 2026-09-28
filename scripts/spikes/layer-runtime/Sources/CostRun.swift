// Questions 2 and 3: memory, CPU and wakeups of one mode in one scenario, in a fresh process. run.sh runs every
// mode and scenario three times, interleaved (round 1 of every combination, then round 2, …).
//
//   --scenario ten     10 System-like widgets (about 20 groups each), Update=1000
//              design  one 360 pt design skin, Update=1000
//              sixty   one audio visualizer at 60 Hz (33 groups change every frame)
//   --mode A|B|E1|EP|D1|DP  --format rgba8|auto|rgba16f  --window-cs default|srgb  [--window-space-base] [--scratch]
//                      [--kept] (B: kept pictures of unchanged elements, as Deskset does)
//   --seconds N        length of each on / off phase (default 5)
//   --pairs N          on / off phase pairs (default 3)
//   --settle N         seconds the windows run before this process's memory is read (default 20: `memtrace` shows
//                      CA adding second buffers to layers that keep updating within 5–20 s, and today's view drawing
//                      moving to a much larger rendering path after its first redraws)
//   --ws-cycles N      open / close cycles for WindowServer's memory at the end (default 1; the scenario's own open
//                      and close is one more)
//   --frames           60 Hz: after the phases, read the frame number back from the screen for 5 s (not in the CPU
//                      numbers; --frames-seconds N for longer), with the commits around the longest freeze
//   --no-top           phases do not sample WindowServer's idle wakeups (a `top` call takes about 0.9 s): for many
//                      short on / off pairs that only look at CPU
//   --reshow-wait N    seconds between showing the windows again and the next on phase (default 1.5)
//   --backdrop         an opaque, static window of ours under the whole grid, on screen in on and off phases alike:
//                      without it, showing the widgets hides whatever animates under them (other apps), which
//                      changes WindowServer's work by more than the widgets cost
//   --one-thread       all widgets share one skin thread (default: one thread per widget, as Deskset plans)
//   --stagger          widget i updates i / N of an interval after the first (default: all at the same moment)
//   --off-shown        off phases keep the windows on screen and only stop their updates (instead of ordering them
//                      out): the difference is then only what the updates cost, without the window server's work of
//                      ordering windows out and in (which spills into the next phase)
//   --coalesce         one timer per skin thread updates all of that thread's widgets in one transaction with one
//                      flush (updates that fall due together, coalesced); with --one-thread: one wakeup and one
//                      commit per second for all 10 widgets
//   --gpu              also sample the GPU's utilization (whole system, I/O Registry) every 0.5 s during each phase
//
// Every phase also records proc_pid_rusage v6 counters of this process (instructions, cycles, the share of both on
// performance cores, energy, time runnable but waiting for a core): CPU time alone cannot tell more work from the
// same work on a slower or not yet ramped-up core. Every update records its cost as wall-clock time and as the
// skin thread's CPU time.
//
// Order: warm-up, the scenario (memory, CPU phases, memory, close), then the extra WindowServer cycles, so this
// process's memory is measured before anything else was opened and closed. Every open and close runs in its own
// autorelease pool (the experiment runs inside one run-loop callout, whose pool would otherwise keep closed windows'
// objects until the process exits).
//
// Memory: this process's phys_footprint (task_info, median of 3 samples) before the windows open, after they ran for
// a few seconds, at the end of the phases and after closing. WindowServer: `footprint`, `vmmap` and proc_pid_rusage all
// need root for it, so its footprint comes from `top` (MEM, about 1 MB resolution, one sample takes about 0.9 s).
// WindowServer's footprint also moves by tens of MB on its own on a busy screen, so the estimate is the step when the
// windows open: the scenario's own opening (after the settle time) and more cycles, median of the open steps. Close
// steps are recorded too (WindowServer gives the memory back when the windows are released; `wsmem` measures one
// opening per process with more widgets).
//
// CPU and wakeups: phases of `seconds` with the windows on screen and updating ("on"), alternating with phases where
// the timers are stopped and the windows ordered out ("off"). WindowServer's CPU counts everything on the screen; the
// off phases are its baseline in the same minute. This process: getrusage and proc_pid_rusage (interrupt wakeups and
// package idle wakeups). WindowServer: CPU time from `ps` (10 ms resolution), idle wakeups from `top` (IDLEW), read on
// a background queue: `top` takes about 0.9 s, and blocking the main thread for it at the start of every phase cost
// today's view drawing (whose timer runs on the main thread) 15 % of its frames at 60 Hz.
import AppKit

func costRun() -> JSON {
    let mode = choice("--mode", Mode.EP)
    let scenario = scenarioOption()
    guard scenario != "static" else {
        log("cost: --scenario static is for memtrace and wsmem (cost measures updating widgets)")
        exit(2)
    }
    let seconds = Double(option("--seconds") ?? "") ?? 5
    let pairs = Int(option("--pairs") ?? "") ?? 3
    let settle = Double(option("--settle") ?? "") ?? 20
    let wsCycles = Int(option("--ws-cycles") ?? "") ?? 1
    let sampleTop = !flag("--no-top")
    let reshowWait = Double(option("--reshow-wait") ?? "") ?? 1.5
    let offShown = flag("--off-shown")
    var config = Config(mode: mode)
    config.format = choice("--format", FormatChoice.rgba8)
    config.windowSpace = choice("--window-cs", WindowSpace.default)
    config.baseSurface = mode == .DP && !flag("--cgimage")
    config.baseInWindowSpace = flag("--window-space-base")
    config.scratch = flag("--scratch")
    config.keptPictures = flag("--kept")
    config.cgImages = flag("--cgimage")

    let (make, count, interval): (() -> Widget, Int, Double) = {
        switch scenario {
        case "design": return ({ Widgets.design() }, 1, 1.0)
        case "sixty": return ({ Widgets.visualizer() }, 1, 1.0 / 60)
        default: return ({ Widgets.system() }, 10, 1.0)
        }
    }()
    var j: JSON = ["mode": mode.rawValue, "config": config.label, "scenario": scenario, "widgets": count,
                   "oneSkinThread": flag("--one-thread"), "staggered": flag("--stagger"), "phaseSeconds": seconds, "pairs": pairs, "settleSeconds": settle,
                   "updateIntervalMs": r(interval * 1000, 2),
                   "offPhases": offShown ? "windows on screen, updates stopped" : "windows ordered out, updates stopped"]
    let mb = 1024.0 * 1024.0

    func footprintMedian() -> Double {
        var v: [Double] = []
        for _ in 0..<3 {
            v.append(physFootprint())
            pump(0.2)
        }
        return median(v)
    }
    /// One `top` sample.
    func windowServerMB() -> Double? { windowServerMemory().mem.map { $0 / mb } }

    /// --stagger: widget i updates i / count of an interval after the first one (default: all at the same moment).
    func stagger(_ i: Int) -> Double { flag("--stagger") ? Double(i) * interval / Double(count) : 0 }
    let coalesce = flag("--coalesce") && mode.isLayered
    j["coalesced"] = coalesce
    var threads: [RunLoopThread] = []
    /// --coalesce: one timer per skin thread for all its widgets (see the header).
    var coalescers: [(thread: RunLoopThread, timer: Timer)] = []
    let coalescedLock = NSLock()
    var coalescedCommits: [Double] = []
    func startUpdates(_ ws: [SkinWindow]) {
        guard coalesce else {
            for (i, w) in ws.enumerated() { w.start(interval: interval, after: stagger(i)) }
            return
        }
        for t in threads {
            let mine = ws.filter { $0.thread === t }
            guard !mine.isEmpty else { continue }
            let timer = Timer(fire: Date().addingTimeInterval(interval), interval: interval, repeats: true) { _ in
                autoreleasepool {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for w in mine { w.step(flush: false) }
                    let a = now()
                    CATransaction.commit()
                    CATransaction.flush()
                    coalescedLock.lock()
                    coalescedCommits.append(now() - a)
                    coalescedLock.unlock()
                }
            }
            timer.tolerance = interval >= 0.5 ? 0.01 : 0.001
            t.perform { RunLoop.current.add(timer, forMode: .default) }
            coalescers.append((t, timer))
        }
    }
    func stopUpdates(_ ws: [SkinWindow]) {
        for w in ws { w.stop() }
        for c in coalescers { c.thread.sync { c.timer.invalidate() } }
        coalescers = []
    }
    func open(_ n: Int, start: Bool = true) -> [SkinWindow] {
        autoreleasepool {
            var ws: [SkinWindow] = []
            for i in 0..<n {
                let widget = make()
                // --one-thread: every widget on one skin thread (their updates then run one after another).
                let t = flag("--one-thread") ? 0 : i
                if threads.count <= t { threads.append(RunLoopThread.make("skin \(t)")) }
                let w = SkinWindow(widget, config, origin: gridOrigin(i, size: widget.size, columns: 5),
                                   thread: threads[t])
                w.buildAndCommit(tick: 0)
                w.show()
                ws.append(w)
            }
            if start { startUpdates(ws) }
            return ws
        }
    }
    func close(_ ws: inout [SkinWindow]) {
        autoreleasepool {
            for w in ws { w.close() }
            ws = []
        }
    }

    // The backdrop (--backdrop): below the widgets, covering the grid they open in.
    var backdrop: NSPanel?
    if flag("--backdrop") {
        let frame = gridFrame(count: count, size: make().size, columns: 5)
        let b = makePanel(frame)
        b.isOpaque = true
        b.backgroundColor = .black
        b.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.contents = backdropImage(frame.size, scale: 2)
        v.layer?.contentsGravity = .resize
        b.contentView = v
        b.orderFrontRegardless()
        backdrop = b
        j["backdrop"] = true
    }

    // Warm-up: the same kind of window once, so framework caches and code are in the baseline.
    do {
        var ws = open(1, start: false)
        pump(0.5)
        for _ in 0..<3 { ws[0].onSkinSync { ws[0].step() } }
        pump(0.5)
        close(&ws)
        pump(1.0)
    }

    // 1. The scenario: baseline, open, settle, memory.
    var memory: JSON = [:]
    let footprint0 = footprintMedian()
    memory["footprintBeforeMB"] = r(footprint0 / mb, 2)
    memory["footprintCategoriesBeforeMB"] = footprintCategories()
    memory["memoryPressureBefore"] = memoryPressure()
    let ws0 = windowServerMB()
    let t0 = now()
    var windows = open(count)
    j["openAllMs"] = r((now() - t0) * 1000, 1)
    pump(settle)
    let footprint1 = footprintMedian()
    let ws1 = windowServerMB()
    memory["footprintAfterSettleMB"] = r(footprint1 / mb, 2)
    memory["footprintIncreaseMB"] = r((footprint1 - footprint0) / mb, 3)
    memory["footprintIncreasePerWidgetMB"] = r((footprint1 - footprint0) / mb / Double(count), 3)
    memory["footprintCategoriesAfterSettleMB"] = footprintCategories()
    memory["memoryPressureAfterSettle"] = memoryPressure()
    if let w = windows.first {
        let window = Double(w.widget.size.width * w.scale * w.widget.size.height * w.scale)
        memory["oneBitmapOfTheWindowMB"] = r(window * 4 / mb, 3)
        if let p = w.part {
            memory["partitionMinimumMB"] = r((window + Double(p.groups.reduce(0) { $0 + $1.box.area })) * 4 / mb, 3)
            j["partition"] = p.json
        }
        memory["ownedBitmapsPerWidgetMB"] = r(Double(w.ownedBitmapBytes) / mb, 3)
        memory["layerBitmapsPerWidgetMB"] = r(Double(windows.reduce(0) { $0 + $1.layerBitmapBytes }) / mb
                                              / Double(count), 3)
        if w.config.mode.isLayered { memory["backingStores"] = backingSummary(w.contentRoot) }
    }

    // 2. CPU and wakeups: on / off pairs.
    /// A phase boundary. WindowServer's idle wakeups come from `top`, which takes about 0.9 s: it runs on a
    /// background queue, so the main thread (where today's view drawing runs) is not blocked during the phase.
    final class Sample {
        let commits: Int
        let t = now(), cpu = cpuSeconds(), wk = wakeups(), counters = procCounters()
        let wsCPU = windowServerCPUSeconds()
        let load = loadAverage()
        private let done = DispatchGroup()
        private var idle: (value: Double, t: Double)?
        init(_ commits: Int, top: Bool) {
            self.commits = commits
            guard top else { return }
            done.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                let v = windowServerMemory().idleWakeups
                idle = v.map { ($0, now()) }
                done.leave()
            }
        }
        /// WindowServer's idle wakeups so far and when `top` read them (waits for `top`).
        var wsIdle: (value: Double, t: Double)? {
            done.wait()
            return idle
        }
    }
    func commitCount() -> Int { windows.reduce(0) { $0 + $1.commitTimes.count } }
    /// The first window's commits during the last "on" phase (frame pacing is measured inside one phase: the
    /// timers stop between phases).
    var lastOnCommits = 0..<0
    let sampleGPU = flag("--gpu")
    func phase(_ label: String) -> JSON {
        let a = Sample(commitCount(), top: sampleTop)
        let firstWindowCommits = windows.first?.commitTimes.count ?? 0
        let gpu = sampleGPU ? GPUSampler(every: 0.5) : nil
        pump(seconds)
        let gpuStats = gpu?.finish()
        let lastWindowCommits = windows.first?.commitTimes.count ?? 0
        let b = Sample(commitCount(), top: sampleTop)
        if label == "on" { lastOnCommits = firstWindowCommits..<lastWindowCommits }
        let dt = b.t - a.t
        var p: JSON = ["phase": label, "seconds": r(dt, 2), "loadAverageBefore": a.load, "loadAverageAfter": b.load,
                       "provisional": max(a.load[0], b.load[0]) > 8,
                       "processPercentOfOneCore": r((b.cpu - a.cpu) / dt * 100, 3),
                       "interruptWakeupsPerSecond": r((b.wk.interrupt - a.wk.interrupt) / dt, 2),
                       "idleWakeupsPerSecond": r((b.wk.idle - a.wk.idle) / dt, 2),
                       "framesPerSecond": r(Double(b.commits - a.commits) / dt, 2),
                       "counters": a.counters.rates(to: b.counters, seconds: dt)]
        if let gpuStats { p["gpu"] = gpuStats }
        if let x = a.wsCPU, let y = b.wsCPU { p["windowServerPercentOfOneCore"] = r((y - x) / dt * 100, 2) }
        if let x = a.wsIdle, let y = b.wsIdle, y.t > x.t {
            p["windowServerIdleWakeupsPerSecond"] = r((y.value - x.value) / (y.t - x.t), 1)
        }
        return p
    }
    var phases: [JSON] = []
    for i in 0..<pairs {
        phases.append(phase("on"))
        stopUpdates(windows)
        for w in windows where !offShown { w.panel.orderOut(nil) }
        pump(0.5)
        phases.append(phase("off"))
        for w in windows where !offShown { w.show() }
        startUpdates(windows)
        pump(i == pairs - 1 ? 0.5 : offShown ? 0.5 : reshowWait)
    }
    j["phases"] = phases
    func mean(_ key: String, _ label: String) -> Double? {
        let v = phases.filter { $0["phase"] as? String == label }.compactMap { $0[key] as? Double }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    var cpu: JSON = [:]
    for key in ["processPercentOfOneCore", "interruptWakeupsPerSecond", "idleWakeupsPerSecond", "framesPerSecond",
                "windowServerPercentOfOneCore", "windowServerIdleWakeupsPerSecond"] {
        if let on = mean(key, "on") { cpu[key] = r(on, 3) }
        if key.hasPrefix("windowServer"), let on = mean(key, "on"), let off = mean(key, "off") {
            cpu[key + "Off"] = r(off, 3)
            cpu[key + "Increase"] = r(on - off, 3)
        }
    }
    cpu["provisional"] = phases.contains { $0["provisional"] as? Bool == true }
    // The counters of the on phases, averaged.
    var counters: JSON = [:]
    let onCounters = phases.filter { $0["phase"] as? String == "on" }.compactMap { $0["counters"] as? JSON }
    for key in onCounters.first?.keys.sorted() ?? [] {
        let v = onCounters.compactMap { $0[key] as? Double }
        if !v.isEmpty { counters[key] = r(v.reduce(0, +) / Double(v.count), 3) }
    }
    cpu["countersOn"] = counters
    j["cpu"] = cpu
    // Cost per update on the skin's executor (all windows): drawing before the commit (A: draw(_:) on the main
    // thread, which only records), and the commit with its flush.
    let costs = windows.flatMap(\.frameCosts)
    if !costs.isEmpty {
        var f: JSON = ["updates": costs.count, "p50us": r(percentile(costs, 0.5) * 1e6, 0),
                       "p99us": r(percentile(costs, 0.99) * 1e6, 0),
                       "what": mode == .A ? "draw(_:) on the main thread (recording)"
                        : mode == .B ? "updateLayer on the main thread (drawing the bitmap)" : "drawing before the commit"]
        let commits = windows.flatMap(\.commitCosts)
        if !commits.isEmpty {
            f["commitP50us"] = r(percentile(commits, 0.5) * 1e6, 0)
            f["commitP99us"] = r(percentile(commits, 0.99) * 1e6, 0)
        }
        let cpuCosts = windows.flatMap(\.frameCPUCosts)
        if !cpuCosts.isEmpty { f["threadCPUp50us"] = r(percentile(cpuCosts, 0.5) * 1e6, 0) }
        let commitCPU = windows.flatMap(\.commitCPUCosts)
        if !commitCPU.isEmpty { f["commitThreadCPUp50us"] = r(percentile(commitCPU, 0.5) * 1e6, 0) }
        coalescedLock.lock()
        let coalesced = coalescedCommits
        coalescedLock.unlock()
        if !coalesced.isEmpty { f["coalescedCommitP50us"] = r(percentile(coalesced, 0.5) * 1e6, 0) }
        j["frameCost"] = f
    }
    // B+kept: what the last frame copied and drew, and its picture against a full drawing (Deskset allows 8 levels:
    // copied pictures composite like direct drawing, but each 8-bit step rounds).
    // The widgets stop for it (a 60 Hz widget would otherwise move on between its last picture and the check).
    if let w = windows.first, let v = w.drawView, v.keptPictures {
        stopUpdates(windows)
        pump(0.2)
        let k = v.keptStats
        j["keptPicturesLastFrame"] = ["picturesCopied": k.copied, "picturesMade": k.made, "elementsDrawn": k.drawn,
                                      "elements": w.widget.elements.count]
        if let c = v.keptCheck(tick: w.tick) { j["keptPicturesVsFullDrawing"] = c }
        startUpdates(windows)
        pump(0.5)
    }

    // 3. The end of the scenario: memory after all phases, 60 Hz pacing, close.
    let footprintEnd = footprintMedian()
    let wsEnd = windowServerMB()
    memory["footprintAtEndMB"] = r(footprintEnd / mb, 2)
    memory["footprintIncreaseAtEndPerWidgetMB"] = r((footprintEnd - footprint0) / mb / Double(count), 3)
    if scenario == "sixty", let w = windows.first {
        // Frame pacing on the skin thread (commit to commit, within the last on phase) and the cost of one frame
        // (draw, before commit).
        let all = w.commitTimes
        let times = Array(all[min(lastOnCommits.lowerBound, all.count)..<min(lastOnCommits.upperBound, all.count)])
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        var frames: JSON = ["commits": times.count, "intervalP50ms": r(percentile(gaps, 0.5), 2),
                            "intervalP99ms": r(percentile(gaps, 0.99), 2), "intervalMaxMs": r(gaps.max() ?? 0, 2),
                            "frameCostP50us": r(percentile(w.frameCosts, 0.5) * 1e6, 0),
                            "frameCostP99us": r(percentile(w.frameCosts, 0.99) * 1e6, 0)]
        if !w.commitCosts.isEmpty {
            frames["commitCostP50us"] = r(percentile(w.commitCosts, 0.5) * 1e6, 0)
            frames["commitCostP99us"] = r(percentile(w.commitCosts, 0.99) * 1e6, 0)
        }
        j["frames"] = frames
        if flag("--frames") && canCapture {
            j["onScreen"] = sampleFrames(w, seconds: Double(option("--frames-seconds") ?? "") ?? 5)
        }
    }
    stopUpdates(windows)
    close(&windows)
    pump(1.5)
    let wsClosed = windowServerMB()
    memory["footprintAfterCloseMB"] = r(footprintMedian() / mb, 2)

    // 4. WindowServer's memory: the scenario's own open / close, and more cycles.
    var opens: [Double] = [], closes: [Double] = []
    if let a = ws0, let b = ws1, let c = wsEnd, let d = wsClosed {
        opens.append(b - a)
        closes.append(d - c)
    }
    for _ in 0..<wsCycles {
        let a = windowServerMB()
        var ws = open(count)
        pump(3)
        let b = windowServerMB()
        close(&ws)
        pump(1.5)
        let c = windowServerMB()
        if let a, let b, let c {
            opens.append(b - a)
            closes.append(c - b)
        }
    }
    memory["windowServerOpenStepsMB"] = opens.map { r($0, 1) }
    memory["windowServerCloseStepsMB"] = closes.map { r($0, 1) }
    if !opens.isEmpty {
        memory["windowServerIncreaseMB"] = r(median(opens), 2)
        memory["windowServerIncreasePerWidgetMB"] = r(median(opens) / Double(count), 3)
    }
    j["memory"] = memory
    for t in threads { t.stop() }
    backdrop?.orderOut(nil)
    j["contexts"] = contextLog.json
    return j
}

/// Reads the frame number back from the screen as fast as possible for `seconds` (a sampler thread; the main thread
/// keeps running): distinct frames seen vs frames committed, and the longest time one frame stayed on screen.
func sampleFrames(_ w: SkinWindow, seconds: Double) -> JSON {
    guard let code = w.widget.elements.first(where: { $0.name == "MeterCode" }) else { return [:] }
    let origin = code.frame.origin
    let lock = NSLock()
    var samples: [(t: Double, frame: Int?)] = []
    let firstCommit = w.commitTimes.count
    let sampler = Sampler([w.panel]) { t, p in
        let f = p.flatMap { FrameCode.read($0, at: origin, scale: w.scale) }
        lock.lock()
        samples.append((t, f))
        lock.unlock()
    }
    sampler.start()
    pump(seconds)
    sampler.stop()
    let committed = w.commitTimes.count - firstCommit
    lock.lock()
    let all = samples
    lock.unlock()
    let read = all.compactMap(\.frame)
    var longest = 0.0
    var longestSpan: (from: Double, to: Double, frame: Int, next: Int)?
    var current: (t: Double, frame: Int)?
    var gaps: [Double] = []
    for s in all {
        guard let f = s.frame else { continue }
        if let c = current, c.frame != f {
            if s.t - c.t > longest {
                longest = s.t - c.t
                longestSpan = (c.t, s.t, c.frame, f)
            }
            gaps.append(s.t - c.t)
            current = (s.t, f)
        }
        if current == nil { current = (s.t, f) }
    }
    var j: JSON = ["samples": all.count, "samplesPerSecond": r(Double(all.count) / seconds, 0),
                   "unreadable": all.count - read.count, "distinctFramesSeen": Set(read).count,
                   "framesCommitted": committed, "longestSameFrameMs": r(longest * 1000, 1),
                   "frameChangeIntervalP50ms": r(percentile(gaps, 0.5) * 1000, 1),
                   "frameChangeIntervalP99ms": r(percentile(gaps, 0.99) * 1000, 1)]
    // Around the longest freeze: when the frames on either side were committed on the skin thread, and what the
    // captures saw. Commits on time during a freeze mean the skin thread kept going and the frames did not reach
    // the screen; commits late mean the skin thread (or its timer) stalled.
    if let span = longestSpan {
        let times = w.commitTimes, ticks = w.commitTicks, costs = w.frameCosts, commits = w.commitCosts
        var around: [JSON] = []
        // The frame code holds 14 bits (FrameCode.bits): ticks are compared modulo 16384.
        for (k, t) in ticks.enumerated() where t % 16384 >= span.frame - 3 && t % 16384 <= span.next + 3
            && k < times.count {
            var e: JSON = ["tick": t, "committedAtMs": r(times[k] * 1000, 1)]
            if k > 0 { e["sincePreviousCommitMs"] = r((times[k] - times[k - 1]) * 1000, 1) }
            if k < costs.count { e["drawUs"] = r(costs[k] * 1e6, 0) }
            if k < commits.count { e["commitUs"] = r(commits[k] * 1e6, 0) }
            around.append(e)
        }
        let seen = all.filter { $0.t >= span.from - 0.05 && $0.t <= span.to + 0.05 }
            .map { ["atMs": r($0.t * 1000, 1), "frame": $0.frame ?? -1] as JSON }
        j["longestFreeze"] = ["frameShown": span.frame, "nextFrameSeen": span.next,
                              "fromMs": r(span.from * 1000, 1), "toMs": r(span.to * 1000, 1),
                              "commitsAround": around, "capturesAround": seen]
    }
    return j
}

/// Samples the GPU's utilization and memory in use every `every` seconds on a background thread until `finish()`.
final class GPUSampler {
    private let lock = NSLock()
    private var device: [Double] = [], renderer: [Double] = [], tiler: [Double] = [], inUse: [Double] = []
    private var running = true
    private let done = DispatchSemaphore(value: 0)
    init(every: Double) {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let go = running
                lock.unlock()
                guard go else { break }
                let g = gpuStatistics()
                lock.lock()
                if let v = g.device { device.append(v) }
                if let v = g.renderer { renderer.append(v) }
                if let v = g.tiler { tiler.append(v) }
                if let v = g.inUseMB { inUse.append(v) }
                lock.unlock()
                Thread.sleep(forTimeInterval: every)
            }
            done.signal()
        }
    }
    /// Means of the samples taken.
    func finish() -> JSON {
        lock.lock()
        running = false
        lock.unlock()
        done.wait()
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return ["samples": device.count, "deviceUtilizationPercent": r(mean(device), 2),
                "rendererUtilizationPercent": r(mean(renderer), 2), "tilerUtilizationPercent": r(mean(tiler), 2),
                "inUseMB": r(mean(inUse), 1)]
    }
}

/// `memtrace`: this process's footprint every second while one mode runs a scenario (after a warm-up window), with
/// the footprint's categories every 10 s: when does the memory settle, and what is it?
///   --mode --scenario --window-cs --format as for `cost`; --seconds N (default 40); --hide-at S: order the windows
///   out at S seconds and back in `--hide-for` (default 5) seconds later; --interval S: update interval instead of the
///   scenario's; --no-images: the widgets without their Image meters; --count N: widgets instead of the scenario's.
///   With --hide-at, the result also gives the footprint while shown (median of the 5 s before hiding) and while
///   hidden (median of the last 3 s hidden), per widget: the pages of CGImages handed to the window server are not
///   in phys_footprint while the window is on screen and come back while it is ordered out, so the hidden footprint
///   counts every mode's own bitmaps the same way.
func memTrace() -> JSON {
    let mode = choice("--mode", Mode.A)
    let scenario = scenarioOption()
    let seconds = Int(option("--seconds") ?? "") ?? 40
    let hideAt = Int(option("--hide-at") ?? "") ?? -1
    let hideFor = Int(option("--hide-for") ?? "") ?? 5
    let pressure0 = memoryPressure()
    var config = Config(mode: mode)
    config.format = choice("--format", FormatChoice.rgba8)
    config.windowSpace = choice("--window-cs", WindowSpace.default)
    config.baseSurface = mode == .DP && !flag("--cgimage")
    config.baseInWindowSpace = flag("--window-space-base")
    config.scratch = flag("--scratch")
    config.keptPictures = flag("--kept")
    config.cgImages = flag("--cgimage")
    let (make, scenarioCount, scenarioInterval): (() -> Widget, Int, Double) = {
        switch scenario {
        case "design": return ({ Widgets.design() }, 1, 1.0)
        case "sixty": return ({ Widgets.visualizer() }, 1, 1.0 / 60)
        case "static": return ({ Widgets.system() }, 10, 0)
        default: return ({ Widgets.system() }, 10, 1.0)
        }
    }()
    let count = Int(option("--count") ?? "") ?? scenarioCount
    let interval = Double(option("--interval") ?? "") ?? scenarioInterval
    let mb = 1024.0 * 1024.0
    var threads: [RunLoopThread] = []
    func open(_ n: Int) -> [SkinWindow] {
        autoreleasepool {
            (0..<n).map { i in
                let widget = make()
                if threads.count <= i { threads.append(RunLoopThread.make("skin \(i)")) }
                let w = SkinWindow(widget, config, origin: packedOrigin(i, size: widget.size),
                                   thread: threads[i])
                w.buildAndCommit(tick: 0)
                w.show()
                return w
            }
        }
    }
    autoreleasepool {
        let warm = open(1)
        pump(1)
        for w in warm { w.close() }
    }
    pump(1)
    let base = physFootprint()
    var trace: [Double] = []
    var categories: JSON = ["0": footprintCategories()]
    var windows = open(count)
    if interval > 0 { for w in windows { w.start(interval: interval) } }
    for s in 1...seconds {
        pump(1)
        trace.append(r((physFootprint() - base) / mb, 2))
        if s % 10 == 0 { categories["\(s)"] = footprintCategories() }
        if s == hideAt { for w in windows { w.panel.orderOut(nil) } }
        if s == hideAt + hideFor { for w in windows { w.show() } }
    }
    let bitmaps: JSON = windows.first.map { w in
        ["layerBitmapsPerWidgetMB": r(Double(windows.reduce(0) { $0 + $1.layerBitmapBytes }) / mb / Double(count), 3),
         "ownedBitmapsPerWidgetMB": r(Double(w.ownedBitmapBytes) / mb, 3)]
    } ?? [:]
    autoreleasepool {
        for w in windows { w.close() }
        windows = []
    }
    pump(2)
    let after = r((physFootprint() - base) / mb, 2)
    for t in threads { t.stop() }
    var j: JSON = ["config": config.label, "scenario": scenario, "widgets": count, "intervalMs": r(interval * 1000, 1),
                   "images": !Widgets.omitImages, "baselineMB": r(base / mb, 2),
                   "increaseEverySecondMB": trace, "increaseAfterCloseMB": after, "categories": categories,
                   "hideAt": hideAt, "hideFor": hideFor, "bitmaps": bitmaps,
                   "memoryPressureAtStart": pressure0, "memoryPressureAtEnd": memoryPressure()]
    if hideAt > 5 && hideAt + hideFor <= seconds && hideFor >= 3 {
        // trace[k] is the reading after k + 1 seconds; hidden from the reading after hideAt + 1 seconds.
        let shown = Array(trace[(hideAt - 5)..<hideAt])
        let hidden = Array(trace[(hideAt + hideFor - 3)..<(hideAt + hideFor)])
        j["shownPerWidgetMB"] = r(median(shown) / Double(count), 3)
        j["hiddenPerWidgetMB"] = r(median(hidden) / Double(count), 3)
    }
    return j
}

/// `wsmem`: WindowServer's footprint when a fresh process opens `--count` widgets of one scenario and mode, updating
/// at the scenario's rate: median of 5 `top` samples before, after 8 s, and after closing them. One open per process,
/// so WindowServer cannot reuse memory it kept from an earlier window of ours. Several windows per process (default
/// 20 System widgets, 5 design skins, 5 visualizers; `static`: 20 System widgets drawn once, never updated) so the
/// step stands out of `top`'s 1 MB resolution. WindowServer's footprint also jumps by ±100 MB on its own now and then; a round counts as clean when the footprint
/// went back to where it started after the windows closed (open step + close step within ±2 MB). Also recorded:
/// WindowServer's resident size (`ps`, KB; without GPU memory) and the GPU's "In use system memory" (the whole system,
/// this process's surfaces included).
///   --scenario ten|design|sixty|static  --count N  --mode --window-cs --format as for `cost`
func windowServerMemoryRun() -> JSON {
    let mode = choice("--mode", Mode.EP)
    let scenario = scenarioOption()
    let (make, defaultCount, interval, columns): (() -> Widget, Int, Double, Int) = {
        switch scenario {
        case "design": return ({ Widgets.design() }, 5, 1.0, 4)
        case "sixty": return ({ Widgets.visualizer() }, 5, 1.0 / 60, 5)
        case "static": return ({ Widgets.system() }, 20, 0, 5)
        default: return ({ Widgets.system() }, 20, 1.0, 5)
        }
    }()
    let count = Int(option("--count") ?? "") ?? defaultCount
    var config = Config(mode: mode)
    config.format = choice("--format", FormatChoice.rgba8)
    config.windowSpace = choice("--window-cs", WindowSpace.default)
    config.baseSurface = mode == .DP && !flag("--cgimage")
    config.baseInWindowSpace = flag("--window-space-base")
    config.scratch = flag("--scratch")
    config.keptPictures = flag("--kept")
    config.cgImages = flag("--cgimage")
    let mb = 1024.0 * 1024.0
    /// Medians of 5 samples: WindowServer's footprint (`top`) and resident size (`ps`), the GPU's memory in use.
    func sample() -> (mem: Double?, rss: Double?, gpu: Double?) {
        var mem: [Double] = [], rss: [Double] = [], gpu: [Double] = []
        for _ in 0..<5 {
            let w = windowServerMemory()
            if let m = w.mem { mem.append(m / mb) }
            if let r = w.rss { rss.append(r / mb) }
            if let g = gpuInUseMemory() { gpu.append(g / mb) }
        }
        return (mem.isEmpty ? nil : median(mem), rss.isEmpty ? nil : median(rss), gpu.isEmpty ? nil : median(gpu))
    }
    var threads: [RunLoopThread] = []
    var windows: [SkinWindow] = []
    let load0 = loadAverage()
    let pressure0 = memoryPressure()
    let before = sample()
    let footprint0 = physFootprint()
    var size = CGSize.zero
    autoreleasepool {
        for i in 0..<count {
            let widget = make()
            size = widget.size
            threads.append(RunLoopThread.make("skin \(i)"))
            let w = SkinWindow(widget, config, origin: gridOrigin(i, size: widget.size, columns: columns),
                               thread: threads[i])
            w.buildAndCommit(tick: 0)
            w.show()
            if interval > 0 { w.start(interval: interval) }
            windows.append(w)
        }
    }
    pump(8)
    let open = sample()
    let footprint1 = physFootprint()
    let layerBytes = windows.reduce(0) { $0 + $1.layerBitmapBytes }
    autoreleasepool {
        for w in windows { w.close() }
        windows = []
    }
    pump(2)
    let closed = sample()
    for t in threads { t.stop() }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let windowPixels = Double(size.width * scale * size.height * scale)
    var j: JSON = ["mode": mode.rawValue, "config": config.label, "scenario": scenario, "widgets": count,
                   "updateIntervalMs": r(interval * 1000, 2),
                   "oneBitmapOfTheWindowMB": r(windowPixels * 4 / mb, 3),
                   "footprintIncreasePerWidgetMB": r((footprint1 - footprint0) / mb / Double(count), 3),
                   "layerBitmapsPerWidgetMB": r(Double(layerBytes) / mb / Double(count), 3),
                   "memoryPressure": pressure0, "memoryPressureAtEnd": memoryPressure(),
                   "loadAverageAtStart": load0]
    if let a = before.mem, let b = open.mem {
        j["windowServerBeforeMB"] = r(a, 0)
        j["windowServerOpenStepMB"] = r(b - a, 1)
        j["windowServerOpenStepPerWidgetMB"] = r((b - a) / Double(count), 2)
        if let c = closed.mem {
            j["windowServerCloseStepMB"] = r(c - b, 1)
            j["windowServerBackToStart"] = abs(c - a) <= 2
        }
    }
    if let a = before.rss, let b = open.rss, let c = closed.rss {
        j["windowServerResidentOpenStepMB"] = r(b - a, 2)
        j["windowServerResidentCloseStepMB"] = r(c - b, 2)
    }
    if let a = before.gpu, let b = open.gpu, let c = closed.gpu {
        j["gpuInUseOpenStepMB"] = r(b - a, 1)
        j["gpuInUseCloseStepMB"] = r(c - b, 1)
        j["gpuInUseOpenStepPerWidgetMB"] = r((b - a) / Double(count), 2)
    }
    return j
}
