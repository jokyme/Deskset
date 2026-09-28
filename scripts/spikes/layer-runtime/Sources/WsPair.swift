// WindowServer's CPU (and this process's) for several ways of showing the 60 Hz visualizer, measured against each
// other in one process instead of against "off" phases.
//
// The `wscpu` rounds compared "on" phases (updating) with "off" phases (updates stopped) of the same windows. That
// baseline is biased: the main-thread ways read −4 … −5.5 % of a core (WindowServer cannot get cheaper when we
// update), and the ways on skin threads read −1 … +2 %. Here every way has its own window on screen the whole time
// (all at the same size, side by side over one opaque backdrop), and only one of them updates at a time:
//
//   wspair [--sets A,B,Bkept,E1,EPw,CPw,C1,E1@srgb,EP@srgb] [--cycles N] [--phase S] [--seed N]
//
// Every cycle runs one phase per set plus an idle phase (nothing updates), in a shuffled order; each phase starts the
// set's 60 Hz updates, waits 0.6 s, measures for `phase` seconds (default 4) and stops them. WindowServer's CPU (`ps`),
// this process's CPU and proc_pid_rusage v6 counters, the GPU's utilization (I/O Registry, every 0.5 s) and the load
// are recorded per phase. The summary gives, per set, the increase over the idle phase of the same cycle (WindowServer,
// this process, and their sum) and the pairwise differences between sets, with the cycles as the independent units
// (mean ± standard error over cycles).
import AppKit

func windowServerPairs() -> JSON {
    let names = (option("--sets") ?? "A,B,Bkept,E1,EPw,CPw,C1,E1@srgb,EP@srgb").split(separator: ",").map(String.init)
    let cycles = Int(option("--cycles") ?? "") ?? 10
    let phaseSeconds = Double(option("--phase") ?? "") ?? 4
    var rng = SeededRandom(seed: UInt64(option("--seed") ?? "") ?? 1)
    func config(_ name: String) -> Config {
        let parts = name.split(separator: "@").map(String.init)
        var c: Config
        switch parts[0] {
        case "A": c = Config(mode: .A)
        case "B": c = Config(mode: .B)
        case "Bkept": c = Config(mode: .B); c.keptPictures = true
        case "E1": c = Config(mode: .E1)
        case "EP": c = Config(mode: .EP)
        case "EPw": c = Config(mode: .EP); c.baseInWindowSpace = true
        case "EPxw": c = Config(mode: .EP); c.baseInWindowSpace = true; c.scratch = true
        case "C1": c = Config(mode: .D1); c.cgImages = true
        case "CPw": c = Config(mode: .DP); c.cgImages = true; c.baseInWindowSpace = true
        case "D1": c = Config(mode: .D1)
        case "DP": c = Config(mode: .DP); c.baseSurface = true
        default:
            log("wspair: unknown set \(name)")
            exit(2)
        }
        if parts.count > 1 { c.windowSpace = WindowSpace(rawValue: parts[1]) ?? .default }
        return c
    }
    let configs = names.map(config)
    let size = Widgets.visualizer().size
    let columns = 3
    // The backdrop under all of them.
    let frame = gridFrame(count: names.count, size: size, columns: columns)
    let backdrop = makePanel(frame)
    backdrop.isOpaque = true
    backdrop.backgroundColor = .black
    backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
    v.wantsLayer = true
    v.layer?.contents = backdropImage(frame.size, scale: 2)
    v.layer?.contentsGravity = .resize
    backdrop.contentView = v
    backdrop.orderFrontRegardless()

    var threads: [RunLoopThread] = []
    var windows: [SkinWindow] = []
    for (i, c) in configs.enumerated() {
        threads.append(RunLoopThread.make("skin \(i)"))
        let w = SkinWindow(Widgets.visualizer(), c, origin: gridOrigin(i, size: size, columns: columns),
                           thread: threads[i])
        w.buildAndCommit(tick: 0)
        w.show()
        windows.append(w)
    }
    pump(3)
    // Warm-up: every set updates for 1 s once.
    for w in windows {
        w.start(interval: 1.0 / 60)
        pump(1)
        w.stop()
    }
    pump(1)

    var phases: [JSON] = []
    for cycle in 0..<cycles {
        var order = Array(-1..<names.count)       // -1: idle
        rng.shuffle(&order)
        for k in order {
            let w = k >= 0 ? windows[k] : nil
            w?.start(interval: 1.0 / 60)
            pump(0.6)
            let load0 = loadAverage()
            let t0 = now(), cpu0 = cpuSeconds(), c0 = procCounters(), ws0 = windowServerCPUSeconds()
            let gpu = GPUSampler(every: 0.5)
            pump(phaseSeconds)
            let gpuStats = gpu.finish()
            let t1 = now(), cpu1 = cpuSeconds(), c1 = procCounters(), ws1 = windowServerCPUSeconds()
            let load1 = loadAverage()
            w?.stop()
            let dt = t1 - t0
            var p: JSON = ["cycle": cycle, "set": k >= 0 ? names[k] : "idle", "seconds": r(dt, 2),
                           "processPercentOfOneCore": r((cpu1 - cpu0) / dt * 100, 3),
                           "counters": c0.rates(to: c1, seconds: dt), "gpu": gpuStats,
                           "loadAverageBefore": load0, "loadAverageAfter": load1,
                           "provisional": max(load0[0], load1[0]) > 8,
                           "framesPerSecond": r(Double(w?.commitTimes.filter { $0 >= t0 && $0 <= t1 }.count ?? 0) / dt, 2)]
            if let a = ws0, let b = ws1 { p["windowServerPercentOfOneCore"] = r((b - a) / dt * 100, 2) }
            phases.append(p)
            pump(0.3)
        }
    }
    for w in windows { w.close() }
    backdrop.orderOut(nil)
    for t in threads { t.stop() }

    // Summary: per set, the increase over the same cycle's idle phase; pairwise differences per cycle.
    func value(_ cycle: Int, _ set: String, _ key: String) -> Double? {
        guard let p = phases.first(where: { $0["cycle"] as? Int == cycle && $0["set"] as? String == set }) else { return nil }
        if key == "gpuDevice" { return (p["gpu"] as? JSON)?["deviceUtilizationPercent"] as? Double }
        if key == "sum" {
            guard let a = p["windowServerPercentOfOneCore"] as? Double, let b = p["processPercentOfOneCore"] as? Double
            else { return nil }
            return a + b
        }
        return p[key] as? Double
    }
    func meanSE(_ v: [Double]) -> JSON {
        guard !v.isEmpty else { return [:] }
        let m = v.reduce(0, +) / Double(v.count)
        var j: JSON = ["mean": r(m, 3), "median": r(median(v), 3), "n": v.count]
        if v.count > 1 {
            let sd = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
            j["standardError"] = r(sd / Double(v.count).squareRoot(), 3)
        }
        return j
    }
    let keys = ["windowServerPercentOfOneCore", "processPercentOfOneCore", "sum", "gpuDevice"]
    var perSet: JSON = [:]
    for name in names {
        var e: JSON = [:]
        for key in keys {
            let d = (0..<cycles).compactMap { c -> Double? in
                guard let x = value(c, name, key), let idle = value(c, "idle", key) else { return nil }
                return x - idle
            }
            e[key + "OverIdle"] = meanSE(d)
        }
        perSet[name] = e
    }
    var pairs: JSON = [:]
    let wanted = [("CPw", "EPw"), ("EPw", "Bkept"), ("CPw", "Bkept"), ("EPw", "E1"), ("C1", "E1"), ("E1", "B"),
                  ("Bkept", "B"), ("EP@srgb", "E1@srgb"), ("E1@srgb", "E1"), ("EP@srgb", "EPw"), ("A", "B")]
    for (a, b) in wanted where names.contains(a) && names.contains(b) {
        var e: JSON = [:]
        for key in keys {
            let d = (0..<cycles).compactMap { c -> Double? in
                guard let x = value(c, a, key), let y = value(c, b, key) else { return nil }
                return x - y
            }
            e[key] = meanSE(d)
        }
        pairs["\(a) − \(b)"] = e
    }
    let loads = phases.flatMap { [($0["loadAverageBefore"] as? [Double])?[0], ($0["loadAverageAfter"] as? [Double])?[0]] }
        .compactMap { $0 }
    return ["sets": names, "configs": configs.map(\.label), "cycles": cycles, "phaseSeconds": phaseSeconds,
            "phases": phases, "perSetOverIdle": perSet, "pairs": pairs,
            "loadAverage1mMax": loads.max() ?? 0, "loadAverage1mMedian": r(median(loads), 2),
            "provisionalPhases": phases.filter { $0["provisional"] as? Bool == true }.count]
}

/// A small deterministic generator (xorshift64*), so a run's phase order can be repeated.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
    mutating func shuffle<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            a.swapAt(i, j)
        }
    }
}
