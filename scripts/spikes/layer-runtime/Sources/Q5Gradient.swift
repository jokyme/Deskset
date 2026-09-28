// Question 5 (pure CoreGraphics, no compositor): does cutting a drawing at a box edge change its pixels?
// StylePanel's 270° gradient cut by a 100 × 30 pt box vs drawn whole; other angles; a full-width box; translation
// only; a solid translucent panel; an even-odd clip edge in the same bitmap; and the plan's fix (one whole-window
// base bitmap, groups copy their sub-rectangle in whole pixels) including whole partitions of the test widgets.
import CoreGraphics

///   q5                        everything (2×)
///   q5 --partitions-only [--scale 1|2]   only the whole partitions of the test widgets composed offline (the part
///                             that depends on CoreGraphics' rasterizer: run it as an x86_64 build too)
///   q5 --review-search        every box position on a 1 pt grid at 270°, 180° and 225°, and which match the review's
///                             64.4 / 57.2 / 59.9 %
func q5Gradient() -> JSON {
    if flag("--partitions-only") {
        let scale = CGFloat(Double(option("--scale") ?? "") ?? 2)
        var j: JSON = ["scale": scale, "architecture": machineArchitecture(),
                       "partitionsComposedOffline": partitionsComposedOffline(scale: scale)]
        j["note"] = "pure CoreGraphics, sRGB 8-bit premultiplied; worst of ticks 0, 1, 7, 60, 61"
        return j
    }
    if flag("--review-search") { return reviewSearch() }
    let scale: CGFloat = 2
    let size = CGSize(width: 260, height: 200)

    /// The panel drawn into a bitmap that covers `region` (points) of it: the "group bitmap" for that box.
    func draw(_ region: CGRect, angle: Double, border: Bool, solid: Bool = false,
              clip: ((CGContext) -> Void)? = nil) -> Pixels {
        let ctx = CGContext(data: nil, width: Int(region.width * scale), height: Int(region.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bgraInfo)!
        ctx.translateBy(x: 0, y: region.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        clip?(ctx)
        if solid {
            ctx.addPath(roundedRect(CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1), 16))
            ctx.setFillColor(Theme.panelTop.cg)
            ctx.fillPath()
        } else {
            drawPanel(ctx, size: size, radius: 16, top: Theme.panelTop, bottom: Theme.panelBottom, angle: angle,
                      border: border)
        }
        return Pixels.of(ctx.makeImage()!)
    }

    let full = CGRect(origin: .zero, size: size)
    var wholeCache: [String: Pixels] = [:]
    func whole(_ angle: Double, _ border: Bool, solid: Bool = false) -> Pixels {
        let key = "\(angle)-\(border)-\(solid)"
        if let p = wholeCache[key] { return p }
        let p = draw(full, angle: angle, border: border, solid: solid)
        wholeCache[key] = p
        return p
    }
    func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }

    /// Cut vs whole for one box.
    func cut(_ box: CGRect, angle: Double, border: Bool = true, solid: Bool = false) -> Diff {
        compare(draw(box, angle: angle, border: border, solid: solid), whole(angle, border, solid: solid).crop(px(box)))
    }

    /// Every box position on a 2 pt grid (the whole box inside the panel).
    func scan(_ w: CGFloat, _ h: CGFloat, angle: Double, border: Bool = true) -> JSON {
        var ratios: [Double] = [], maxes: [Double] = []
        var y: CGFloat = 0
        while y + h <= size.height {
            var x: CGFloat = 0
            while x + w <= size.width {
                let d = cut(CGRect(x: x, y: y, width: w, height: h), angle: angle, border: border)
                ratios.append(d.ratio * 100)
                maxes.append(Double(d.maxChannel))
                x += 2
            }
            y += 2
        }
        return ["positions": ratios.count, "differingPercentMin": r(ratios.min() ?? 0, 1),
                "differingPercentMedian": r(median(ratios), 1), "differingPercentMax": r(ratios.max() ?? 0, 1),
                "maxChannelDiff": Int(maxes.max() ?? 0)]
    }

    var j: JSON = ["canvas": "260 × 200 pt at 2×, sRGB, 8-bit premultiplied BGRA; StylePanel radius 16, "
                   + "PanelTop → PanelBottom; box = a separate bitmap covering only the box, same drawing"]
    let box = CGRect(x: 80, y: 85, width: 100, height: 30)
    j["box100x30At80_85"] = [
        "angle270": cut(box, angle: 270).json, "angle270GradientOnly": cut(box, angle: 270, border: false).json,
        "angle180": cut(box, angle: 180).json, "angle225": cut(box, angle: 225).json,
    ]
    j["box100x30AllPositions"] = ["angle270": scan(100, 30, angle: 270), "angle180": scan(100, 30, angle: 180),
                                  "angle225": scan(100, 30, angle: 225)]
    // The review did not record where its box was. Positions (1 pt grid) where 270° gives its 64.4 %, with what
    // 180° and 225° give at the same positions (the review: 57.2 % and 59.9 %).
    do {
        var matches: [JSON] = []
        var y: CGFloat = 0
        while y + 30 <= size.height {
            var x: CGFloat = 0
            while x + 100 <= size.width {
                let b = CGRect(x: x, y: y, width: 100, height: 30)
                if abs(cut(b, angle: 270).ratio * 100 - 64.4) < 0.05 {
                    matches.append(["x": Int(x), "y": Int(y), "angle180": r(cut(b, angle: 180).ratio * 100, 1),
                                    "angle225": r(cut(b, angle: 225).ratio * 100, 1)])
                }
                x += 1
            }
            y += 1
        }
        j["positionsGiving64_4PercentAt270"] = ["count": matches.count, "first": Array(matches.prefix(12))]
    }
    j["fullWidthBox260x30AllRows"] = scan(260, 30, angle: 270)
    // Only the right and bottom edges cut (the box starts at the panel's top-left, gradient start inside).
    j["boxAtTopLeft100x30"] = cut(CGRect(x: 0, y: 0, width: 100, height: 30), angle: 270).json
    j["boxTopHalf260x100"] = cut(CGRect(x: 0, y: 0, width: 260, height: 100), angle: 270).json
    // Pure translation: the whole panel drawn 10 pt further right and down in a larger bitmap.
    do {
        let ctx = CGContext(data: nil, width: 560, height: 440, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: bgraInfo)!
        ctx.translateBy(x: 0, y: 440)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: 10, y: 10)
        drawPanel(ctx, size: size, radius: 16, top: Theme.panelTop, bottom: Theme.panelBottom)
        let moved = Pixels.of(ctx.makeImage()!).crop(CGRect(x: 20, y: 20, width: 520, height: 400))
        j["translatedWholePanel"] = compare(moved, whole(270, true)).json
    }
    j["solidTranslucentPanelCut"] = cut(box, angle: 270, solid: true).json
    // The same box as a clip inside the whole bitmap (winding, and as an even-odd path of the box alone).
    do {
        let boxPx = PixelRect.roundingOut(box, scale: scale)
        let clipped = draw(full, angle: 270, border: true) { $0.clip(to: box) }
        j["clipToBoxInSameBitmap"] = compare(clipped, whole(270, true)) { x, y in boxPx.contains(x: x, y: y) }.json
        let evenOddBox = draw(full, angle: 270, border: true) { ctx in
            ctx.addRect(box)
            ctx.clip(using: .evenOdd)
        }
        j["evenOddClipToBoxInSameBitmap"] = compare(evenOddBox, whole(270, true)) { x, y in
            boxPx.contains(x: x, y: y)
        }.json
    }
    // An even-odd clip that excludes the box, in the whole bitmap ("the base with the groups' boxes cut out").
    do {
        let holed = draw(full, angle: 270, border: true) { ctx in
            ctx.addRect(full)
            ctx.addRect(box)
            ctx.clip(using: .evenOdd)
        }
        let boxPx = PixelRect.roundingOut(box, scale: scale)
        j["evenOddHoleInSameBitmap"] = compare(holed, whole(270, true)) { x, y in !boxPx.contains(x: x, y: y) }.json
    }
    // The fix: the base drawn once, each group copies its box from it in whole pixels (.copy, no interpolation).
    do {
        let base = whole(270, true).image(space: sRGB)
        let g = Group(id: 0, elements: [], box: PixelRect.roundingOut(box, scale: scale))
        let copied = Pixels.of(renderGroup(Widget("empty", size, []), g, base: base, scale: scale, tick: 0))
        j["baseBitmapSubRectCopy"] = compare(copied, whole(270, true).crop(g.box.cg)).json
    }
    j["partitionsComposedOffline"] = partitionsComposedOffline(scale: scale)
    return j
}


/// Where the partition's last differences come from: each group's elements (no base) drawn at their place in a
/// window-sized bitmap vs drawn into a bitmap of the group's box, which moves them by whole device pixels (x0, and
/// the window's height minus y1: CoreGraphics' device origin is the bottom left). Then the same with the box's
/// device origin rounded down to a multiple of k pixels in both axes (the box grows to the left and down), to see
/// whether the rasterizer is exact for some coarser grid.
func translationCheck(_ w: Widget, _ p: Partition, scale: CGFloat, ticks: [Int]) -> JSON {
    var out: JSON = [:]
    let H = p.window.height
    for k in [1, 2, 4, 8, 16, 32, 64] {
        var differing = 0, maxDiff = 0
        var byGroup: [String: Int] = [:]
        for tick in ticks {
            for g in p.groups {
                let list = g.elements.map { w.elements[$0] }
                let whole = Pixels.of(renderWidget(w, tick: tick, scale: scale, list))
                let x0 = g.box.x0 / k * k
                let bottom = (H - g.box.y1) / k * k          // device y of the box's bottom edge, rounded down
                let box = PixelRect(x0: x0, y0: g.box.y0, x1: g.box.x1, y1: H - bottom)
                let ctx = CGContext(data: nil, width: box.width, height: box.height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: sRGB, bitmapInfo: bgraInfo)!
                ctx.translateBy(x: 0, y: CGFloat(box.height))
                ctx.scaleBy(x: scale, y: -scale)
                ctx.translateBy(x: -CGFloat(box.x0) / scale, y: -CGFloat(box.y0) / scale)
                w.draw(ctx, tick: tick, list)
                let d = compare(Pixels.of(ctx.makeImage()!), whole.crop(box.cg))
                differing += d.differing
                maxDiff = max(maxDiff, d.maxChannel)
                if d.differing > 0 { byGroup[list.map(\.name).joined(separator: "+"), default: 0] += d.differing }
            }
        }
        out["grid\(k)px"] = ["differingPixelsOver\(ticks.count)Ticks": differing, "maxChannelDiff": maxDiff,
                            "byGroup": byGroup]
    }
    return out
}

/// Whole partitions of the test widgets composed offline (base bitmap + each group's bitmap copied in) vs one bitmap,
/// worst of several ticks, and where the differences come from.
func partitionsComposedOffline(scale: CGFloat) -> JSON {
    var partitions: JSON = [:]
    for w in [Widgets.system(), Widgets.design(), Widgets.visualizer()] {
        let p = partition(w, scale: scale)
        var worst = Diff()
        for tick in [0, 1, 7, 60, 61] {
            let d = compare(Pixels.of(composePartition(w, p, tick: tick)),
                            Pixels.of(renderWidget(w, tick: tick, scale: scale)))
            if d.differing >= worst.differing { worst = d }
        }
        var e = p.json
        e["worstOf5Ticks"] = worst.json
        // Where the differences are: per group (element names), summed over the ticks.
        var byGroup: [String: Int] = [:]
        for tick in [0, 1, 7, 60, 61] {
            let a = Pixels.of(composePartition(w, p, tick: tick)), b = Pixels.of(renderWidget(w, tick: tick, scale: scale))
            for g in p.groups {
                let d = compare(a.crop(g.box.cg), b.crop(g.box.cg))
                if d.differing > 0 {
                    byGroup[g.elements.map { w.elements[$0].name }.joined(separator: "+"), default: 0] += d.differing
                }
            }
        }
        e["differingPixelsByGroup"] = byGroup
        e["inkEscapes"] = inkEscapes(w, scale: scale, ticks: [0, 1, 7, 60, 61])
        // The same widget cut naively: each group drawn with the base elements clipped to its box (no base copy).
        var naive = Diff()
        for tick in [0, 7] {
            let base = renderBase(w, p, tick: tick)
            let ctx = CGContext(data: nil, width: p.window.width, height: p.window.height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: sRGB, bitmapInfo: bgraInfo)!
            ctx.draw(base, in: p.window.cg)
            for g in p.groups {
                let gctx = CGContext(data: nil, width: g.box.width, height: g.box.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: sRGB, bitmapInfo: bgraInfo)!
                gctx.translateBy(x: 0, y: CGFloat(g.box.height))
                gctx.scaleBy(x: scale, y: -scale)
                gctx.translateBy(x: -CGFloat(g.box.x0) / scale, y: -CGFloat(g.box.y0) / scale)
                w.draw(gctx, tick: tick, p.base.map { w.elements[$0] } + g.elements.map { w.elements[$0] })
                ctx.setBlendMode(.copy)
                ctx.draw(gctx.makeImage()!, in: CGRect(x: g.box.x0, y: p.window.height - g.box.y1,
                                                       width: g.box.width, height: g.box.height))
            }
            let d = compare(Pixels.of(ctx.makeImage()!), Pixels.of(renderWidget(w, tick: tick, scale: scale)))
            if d.differing >= naive.differing { naive = d }
        }
        e["naiveRedrawBasePerGroup"] = naive.json
        e["translationOnly"] = translationCheck(w, p, scale: scale, ticks: [0, 1, 7, 60, 61])
        // The alternative that needs no translation: one window-sized scratch bitmap; for each group, the base
        // copied in, the group's elements drawn at their window position, and the group's box copied out.
        var scratchWorst = Diff()
        for tick in [0, 1, 7, 60, 61] {
            let base = renderBase(w, p, tick: tick)
            let out = CGContext(data: nil, width: p.window.width, height: p.window.height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: sRGB, bitmapInfo: bgraInfo)!
            out.setBlendMode(.copy)
            out.draw(base, in: p.window.cg)
            for g in p.groups {
                let scratch = bitmapContext(w.size, scale: scale)
                scratch.saveGState()
                scratch.concatenate(scratch.ctm.inverted())
                scratch.setBlendMode(.copy)
                scratch.draw(base, in: p.window.cg)
                scratch.restoreGState()
                w.draw(scratch, tick: tick, g.elements.map { w.elements[$0] })
                let full = scratch.makeImage()!
                let crop = full.cropping(to: g.box.cg)!
                out.draw(crop, in: CGRect(x: g.box.x0, y: p.window.height - g.box.y1, width: g.box.width,
                                          height: g.box.height))
            }
            let d = compare(Pixels.of(out.makeImage()!), Pixels.of(renderWidget(w, tick: tick, scale: scale)))
            if d.differing >= scratchWorst.differing { scratchWorst = d }
        }
        e["scratchWindowBitmapWorstOf5Ticks"] = scratchWorst.json
        partitions[w.name] = e
    }
    return partitions
}

/// The CPU architecture this process runs as (x86_64 under Rosetta on Apple silicon).
func machineArchitecture() -> String {
    #if arch(x86_64)
    var translated: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    return rosetta ? "x86_64 (Rosetta)" : "x86_64"
    #else
    return "arm64"
    #endif
}

/// The review measured 64.4 % at 270°, 57.2 % at 180° and 59.9 % at 225° for "a 100 × 30 pt box" without recording
/// where the box was. This scans every position on a 1 pt grid (whole box inside the 260 × 200 pt panel) at the three
/// angles and keeps every position that matches any of the three figures (to 0.05 %), and whether any position
/// matches all three. `--grid 0.5` scans a half-point grid instead.
func reviewSearch() -> JSON {
    let scale: CGFloat = 2
    let grid = CGFloat(Double(option("--grid") ?? "") ?? 1)
    let size = CGSize(width: 260, height: 200)
    var wholeCache: [Double: Pixels] = [:]
    func drawPanelBitmap(_ region: CGRect, angle: Double) -> Pixels {
        let ctx = CGContext(data: nil, width: Int(region.width * scale), height: Int(region.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bgraInfo)!
        ctx.translateBy(x: 0, y: region.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        drawPanel(ctx, size: size, radius: 16, top: Theme.panelTop, bottom: Theme.panelBottom, angle: angle,
                  border: true)
        return Pixels.of(ctx.makeImage()!)
    }
    func percent(_ box: CGRect, _ angle: Double) -> Double {
        if wholeCache[angle] == nil { wholeCache[angle] = drawPanelBitmap(CGRect(origin: .zero, size: size), angle: angle) }
        let px = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
        return compare(drawPanelBitmap(box, angle: angle), wholeCache[angle]!.crop(px)).ratio * 100
    }
    let targets: [(Double, Double)] = [(270, 64.4), (180, 57.2), (225, 59.9)]
    var all: [[Double]] = []          // x, y, p270, p180, p225
    var y: CGFloat = 0
    while y + 30 <= size.height {
        var x: CGFloat = 0
        while x + 100 <= size.width {
            let b = CGRect(x: x, y: y, width: 100, height: 30)
            all.append([Double(x), Double(y)] + targets.map { r(percent(b, $0.0), 2) })
            x += grid
        }
        y += grid
    }
    func matches(_ v: [Double], _ k: Int) -> Bool { abs(v[2 + k] - targets[k].1) < 0.05 }
    var j: JSON = ["grid": "\(grid) pt", "positions": all.count, "boxPoints": "100 x 30",
                   "reviewFigures": ["270": 64.4, "180": 57.2, "225": 59.9]]
    for (k, t) in targets.enumerated() {
        let hits = all.filter { matches($0, k) }
        j["matching\(Int(t.0))"] = ["count": hits.count,
                                   "positions": hits.map { ["x": $0[0], "y": $0[1], "p270": $0[2],
                                                            "p180": $0[3], "p225": $0[4]] as JSON }]
    }
    let triple = all.filter { v in (0..<3).allSatisfy { matches(v, $0) } }
    j["matchingAllThree"] = triple.count
    let pairs: [(Int, Int)] = [(0, 1), (0, 2), (1, 2)]
    for (a, b) in pairs {
        j["matching\(Int(targets[a].0))And\(Int(targets[b].0))"] = all.filter { matches($0, a) && matches($0, b) }.count
    }
    // The closest positions to all three at once (largest of the three deviations).
    let closest = all.map { v in (v, (0..<3).map { abs(v[2 + $0] - targets[$0].1) }.max()!) }
        .sorted { $0.1 < $1.1 }.prefix(10)
    j["closestToAllThree"] = closest.map { ["x": $0.0[0], "y": $0.0[1], "p270": $0.0[2], "p180": $0.0[3],
                                            "p225": $0.0[4], "largestDeviation": r($0.1, 2)] as JSON }
    for (k, t) in targets.enumerated() {
        let v = all.map { $0[2 + k] }
        j["distribution\(Int(t.0))"] = ["min": v.min() ?? 0, "median": r(median(v), 2), "max": v.max() ?? 0]
    }
    return j
}
