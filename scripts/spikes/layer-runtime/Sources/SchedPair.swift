// How the 10 System widgets' updates are scheduled, measured against each other in one process (the `cost` runs
// measure each variant in its own process, minutes apart, and this Mac's load moved between 6 and 37 while they ran).
//
//   schedpair [--mode EPw|CPw|E1] [--cycles N] [--phase S] [--seed N]
//
// Three sets of 10 System widgets are on screen the whole time (they overlap; this step reads this process's CPU,
// not WindowServer's): the partition with one skin thread per widget, the same partition with all 10 widgets on one
// shared skin thread, and B+kept on the main thread. Each phase runs one set in one way for `phase` seconds (default
// 5) after 1 s of lead-in, while the other sets stand still:
//
//   threads-aligned     10 threads, all timers due at the same moment (every run in the cost table)
//   threads-spread      10 threads, timer i due i/10 s after the first (real skins' timers are not aligned)
//   one-aligned         one thread, 10 timers due at the same moment
//   one-spread          one thread, timers spread over the second
//   one-coalesced       one thread, one timer that updates all 10 in one transaction with one flush
//   bkept-aligned       B+kept on the main thread, timers aligned
//   bkept-spread        B+kept, timers spread
//   idle                nothing updates
//
// Every cycle runs all phases in a shuffled order; per phase this process's CPU, interrupt wakeups and the
// proc_pid_rusage v6 counters (instructions, cycles, performance-core share, energy, time runnable). The summary
// gives each way's increase over the idle phase of the same cycle, mean ± standard error over the cycles.
import AppKit

func schedulingPairs() -> JSON {
    let modeName = option("--mode") ?? "EPw"
    let cycles = Int(option("--cycles") ?? "") ?? 8
    let phaseSeconds = Double(option("--phase") ?? "") ?? 5
    var rng = SeededRandom(seed: UInt64(option("--seed") ?? "") ?? 1)
    var layered: Config
    switch modeName {
    case "CPw": layered = Config(mode: .DP); layered.cgImages = true; layered.baseInWindowSpace = true
    case "E1": layered = Config(mode: .E1)
    default: layered = Config(mode: .EP); layered.baseInWindowSpace = true
    }
    var kept = Config(mode: .B)
    kept.keptPictures = true
    let count = 10, interval = 1.0
    let size = Widgets.system().size
    var ownThreads: [RunLoopThread] = []
    let shared = RunLoopThread.make("shared skin")
    var threaded: [SkinWindow] = [], oneThread: [SkinWindow] = [], bkept: [SkinWindow] = []
    autoreleasepool {
        for i in 0..<count {
            ownThreads.append(RunLoopThread.make("skin \(i)"))
            let a = SkinWindow(Widgets.system(), layered, origin: packedOrigin(i, size: size), thread: ownThreads[i])
            let b = SkinWindow(Widgets.system(), layered, origin: packedOrigin(i + 10, size: size), thread: shared)
            let c = SkinWindow(Widgets.system(), kept, origin: packedOrigin(i + 20, size: size), thread: nil)
            for w in [a, b, c] {
                w.buildAndCommit(tick: 0)
                w.show()
            }
            threaded.append(a)
            oneThread.append(b)
            bkept.append(c)
        }
    }
    pump(3)
    var coalescer: Timer?
    func start(_ way: String) {
        func stagger(_ i: Int) -> Double { way.hasSuffix("spread") ? Double(i) * interval / Double(count) : 0 }
        switch way {
        case "threads-aligned", "threads-spread":
            for (i, w) in threaded.enumerated() { w.start(interval: interval, after: stagger(i)) }
        case "one-aligned", "one-spread":
            for (i, w) in oneThread.enumerated() { w.start(interval: interval, after: stagger(i)) }
        case "one-coalesced":
            let ws = oneThread
            let t = Timer(fire: Date().addingTimeInterval(interval), interval: interval, repeats: true) { _ in
                autoreleasepool {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for w in ws { w.step(flush: false) }
                    CATransaction.commit()
                    CATransaction.flush()
                }
            }
            t.tolerance = 0.01
            shared.perform { RunLoop.current.add(t, forMode: .default) }
            coalescer = t
        case "bkept-aligned", "bkept-spread":
            for (i, w) in bkept.enumerated() { w.start(interval: interval, after: stagger(i)) }
        default:
            break
        }
    }
    func stopAll() {
        for w in threaded + oneThread + bkept { w.stop() }
        if let t = coalescer { shared.sync { t.invalidate() } }
        coalescer = nil
    }
    let ways = ["threads-aligned", "threads-spread", "one-aligned", "one-spread", "one-coalesced", "bkept-aligned",
                "bkept-spread", "idle"]
    // Warm-up: every way once for 2 s.
    for way in ways where way != "idle" {
        start(way)
        pump(2)
        stopAll()
    }
    pump(1)
    var phases: [JSON] = []
    for cycle in 0..<cycles {
        var order = ways
        rng.shuffle(&order)
        for way in order {
            start(way)
            pump(1)
            let load0 = loadAverage()
            let t0 = now(), cpu0 = cpuSeconds(), c0 = procCounters()
            pump(phaseSeconds)
            let t1 = now(), cpu1 = cpuSeconds(), c1 = procCounters()
            let load1 = loadAverage()
            stopAll()
            let dt = t1 - t0
            var counters = c0.rates(to: c1, seconds: dt)
            counters["interruptWakeupsPerSecond"] = r((c1.interruptWakeups - c0.interruptWakeups) / dt, 2)
            phases.append(["cycle": cycle, "way": way, "seconds": r(dt, 2),
                           "processPercentOfOneCore": r((cpu1 - cpu0) / dt * 100, 3), "counters": counters,
                           "loadAverageBefore": load0, "loadAverageAfter": load1,
                           "provisional": max(load0[0], load1[0]) > 8])
            pump(0.5)
        }
    }
    for w in threaded + oneThread + bkept { w.close() }
    for t in ownThreads + [shared] { t.stop() }

    func value(_ c: Int, _ way: String, _ key: String) -> Double? {
        guard let p = phases.first(where: { $0["cycle"] as? Int == c && $0["way"] as? String == way }) else { return nil }
        if key == "processPercentOfOneCore" { return p[key] as? Double }
        return (p["counters"] as? JSON)?[key] as? Double
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
    let keys = ["processPercentOfOneCore", "instructionsMillionsPerSecond", "cyclesMillionsPerSecond",
                "pCoreShareOfCPU", "averageGHz", "energyMilliwatts", "runnableMsPerSecond", "interruptWakeupsPerSecond"]
    var overIdle: JSON = [:]
    for way in ways where way != "idle" {
        var e: JSON = [:]
        for key in keys {
            let rateLike = ["pCoreShareOfCPU", "averageGHz"].contains(key)
            let v = (0..<cycles).compactMap { c -> Double? in
                guard let x = value(c, way, key) else { return nil }
                if rateLike { return x }
                guard let idle = value(c, "idle", key) else { return nil }
                return x - idle
            }
            e[key] = meanSE(v)
        }
        overIdle[way] = e
    }
    let loads = phases.flatMap { [($0["loadAverageBefore"] as? [Double])?[0], ($0["loadAverageAfter"] as? [Double])?[0]] }
        .compactMap { $0 }
    return ["mode": modeName, "config": layered.label, "widgetsPerSet": count, "cycles": cycles,
            "phaseSeconds": phaseSeconds, "phases": phases, "overIdle": overIdle,
            "note": "pCoreShareOfCPU and averageGHz are the way's own values, not differences",
            "loadAverage1mMax": loads.max() ?? 0, "loadAverage1mMedian": r(median(loads), 2),
            "provisionalPhases": phases.filter { $0["provisional"] as? Bool == true }.count]
}
