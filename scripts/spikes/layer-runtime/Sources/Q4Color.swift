// Question 4: what context draw(in:) gets on this screen, what CA keeps as the backing store, and which
// combination of contentsFormat and window color space brings E closest to A (the view drawing Deskset used until
// 2026-09-27) and to B (its own-bitmap drawing since then).
//
// One run per window color space (--window-cs default|srgb|p3|display). Every run also shows today's A (window
// color space left alone) and D1 (our own sRGB bitmap) as common references, so runs can be compared.
import AppKit

func q4Color() -> JSON {
    guard canCapture else { return ["error": "screen capture is not allowed for this process"] }
    let widget = Widgets.system()
    let tick = 7
    let space = choice("--window-cs", WindowSpace.default)
    var names: [String] = []
    var configs: [Config] = []
    func add(_ name: String, _ m: Mode, _ f: FormatChoice = .rgba8, _ ws: WindowSpace, beforeAttach: Bool = false) {
        var c = Config(mode: m)
        c.format = f
        c.windowSpace = ws
        c.displayBeforeAttach = beforeAttach
        configs.append(c)
        names.append(name)
    }
    add("A (today)", .A, .rgba8, .default)
    add("B (today)", .B, .rgba8, .default)
    add("D1 (sRGB IOSurface, today's window)", .D1, .rgba8, .default)
    if space != .default {
        add("A", .A, .rgba8, space)
        add("B", .B, .rgba8, space)
    }
    for f in FormatChoice.allCases {
        add("E1/\(f.rawValue)", .E1, f, space)
        add("EP/\(f.rawValue)", .EP, f, space)
    }
    if space == .default {
        add("E1/rgba8+displayBeforeAttach", .E1, .rgba8, space, beforeAttach: true)
        add("EP/rgba8+displayBeforeAttach", .EP, .rgba8, space, beforeAttach: true)
    }
    // The partition with its base bitmap in the window's own color space and depth (so the base copy needs no
    // conversion): can a partition keep today's look?
    for f in [FormatChoice.rgba8, .rgba16f] {
        var c = Config(mode: .EP)
        c.format = f
        c.windowSpace = space
        c.baseInWindowSpace = true
        configs.append(c)
        names.append("EP/\(f.rawValue)+windowSpaceBase")
    }
    // Context kinds, summed over the batches: the first frames, and three more frames on the skin threads (the
    // contexts and backing stores in steady state).
    var firstContexts: [String: Int] = [:]
    var steadyContexts: [String: Int] = [:]
    func add(_ log: JSON, to sum: inout [String: Int]) {
        for (k, v) in log { sum[k, default: 0] += v as? Int ?? 0 }
    }
    var steadyBackings: JSON = [:]
    contextLog.reset()
    let capture = captureModes(widget, configs, tick: tick, backdrops: false) { windows in
        add(contextLog.json, to: &firstContexts)
        contextLog.reset()
        for _ in 0..<3 {
            for w in windows { w.onSkinSync { w.step() } }
            pump(0.2)
        }
        for w in windows where w.config.mode.isLayered {
            if let n = names.indices.first(where: { configs[$0].label == w.config.label
                                                    && configs[$0].windowSpace == w.config.windowSpace }) {
                steadyBackings[names[n]] = backingSummary(w.contentRoot)
            }
        }
        add(contextLog.json, to: &steadyContexts)
        contextLog.reset()
    }
    let shots = capture.shots, backings = capture.backings
    guard shots.count == configs.count else { return ["error": "capture failed"] }
    let scale = capture.scale
    let p = partition(widget, scale: scale)
    let boxes = p.groups.map(\.box)
    func shot(_ n: String) -> Shot { shots[names.firstIndex(of: n)!] }
    var pairs: JSON = [:]
    let sameSpaceA = space == .default ? "A (today)" : "A"
    for n in names where n.hasPrefix("E1") || n.hasPrefix("EP") {
        var e: JSON = ["vs A in this window space": comparison(shot(n), shot(sameSpaceA), groups: boxes)["all"]!,
                       "vs A (today)": comparison(shot(n), shot("A (today)"), groups: boxes)["all"]!,
                       "vs B (today)": comparison(shot(n), shot("B (today)"), groups: boxes)["all"]!,
                       "vs D1 (today's window)": comparison(shot(n), shot("D1 (sRGB IOSurface, today's window)"),
                                                            groups: boxes)["all"]!]
        if n.hasPrefix("EP") {
            let single = n.replacingOccurrences(of: "EP", with: "E1").replacingOccurrences(of: "+windowSpaceBase", with: "")
            e["vs \(single)"] = comparison(shot(n), shot(single), groups: boxes)
        }
        pairs[n] = e
    }
    pairs["B (today) vs A (today)"] = comparison(shot("B (today)"), shot("A (today)"), groups: boxes)["all"]!
    if space != .default {
        pairs["A vs A (today)"] = comparison(shot("A"), shot("A (today)"), groups: boxes)["all"]!
        pairs["B vs B (today)"] = comparison(shot("B"), shot("B (today)"), groups: boxes)["all"]!
        pairs["B vs A"] = comparison(shot("B"), shot("A"), groups: boxes)["all"]!
    }
    var j: JSON = ["windowColorSpace": space.rawValue, "widget": "system (260 × 196 pt), tick \(tick)",
                   "configs": Dictionary(uniqueKeysWithValues: zip(names, configs.map(\.label)).map { ($0, $1) }),
                   "contextsFirstFrames": firstContexts, "contextsNextThreeFrames": steadyContexts,
                   "backingStoresAfterFirstFrame": backings, "backingStoresAfterThreeMoreFrames": steadyBackings,
                   "pairs": pairs, "captureFormat": shots[0].format]
    j["windowColorSpaces"] = Dictionary(uniqueKeysWithValues: zip(names, capture.windowColorSpaces).map { ($0, $1) })
    j["screenColorSpace"] = capture.screenSpace.map { colorSpaceName($0) } ?? "none"
    return j
}
