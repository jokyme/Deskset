// The plan's ComponentPartition: boxes in whole device pixels, a base (the leading run of big elements, drawn once
// into a whole-window bitmap), groups whose boxes never overlap, and base tiles covering the rest of the window.
import CoreGraphics

/// A half-open rectangle in whole device pixels, top-left origin.
struct PixelRect: Hashable, CustomStringConvertible {
    var x0, y0, x1, y1: Int

    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var area: Int { max(0, width) * max(0, height) }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var cg: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }
    var description: String { "[\(x0),\(y0) \(width)×\(height)]" }

    func intersects(_ o: PixelRect) -> Bool { x0 < o.x1 && o.x0 < x1 && y0 < o.y1 && o.y0 < y1 }
    func union(_ o: PixelRect) -> PixelRect {
        PixelRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }
    func intersection(_ o: PixelRect) -> PixelRect {
        PixelRect(x0: max(x0, o.x0), y0: max(y0, o.y0), x1: min(x1, o.x1), y1: min(y1, o.y1))
    }
    func contains(x: Int, y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
    /// In points at `scale`.
    func points(_ scale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x0) / scale, y: CGFloat(y0) / scale, width: CGFloat(width) / scale,
               height: CGFloat(height) / scale)
    }

    /// `rect` (points) scaled and rounded outward to whole pixels.
    static func roundingOut(_ rect: CGRect, scale: CGFloat) -> PixelRect {
        PixelRect(x0: Int((rect.minX * scale).rounded(.down)), y0: Int((rect.minY * scale).rounded(.down)),
                  x1: Int((rect.maxX * scale).rounded(.up)), y1: Int((rect.maxY * scale).rounded(.up)))
    }
}

struct Group {
    /// The smallest file index of its elements (the plan's identity rule).
    var id: Int
    var elements: [Int]
    var box: PixelRect
}

struct Partition {
    let window: PixelRect
    let scale: CGFloat
    /// Elements drawn into the base bitmap (file order).
    var base: [Int]
    var groups: [Group]
    /// The window minus all group boxes, as disjoint rectangles (row bands, equal spans merged downwards).
    var tiles: [PixelRect]
    /// Elements with an empty box: not drawn.
    var skipped: [Int]

    var json: JSON {
        ["groups": groups.count, "tiles": tiles.count, "baseElements": base.count,
         "groupPixels": groups.reduce(0) { $0 + $1.box.area }, "windowPixels": window.area,
         "largestGroupPixels": groups.map(\.box.area).max() ?? 0]
    }
}

/// ComponentPartition: boxes, base, union of overlapping boxes until stable, the 256-group cap, tiles.
func partition(_ widget: Widget, scale: CGFloat, maxGroups: Int = 256) -> Partition {
    let window = PixelRect(x0: 0, y0: 0, x1: Int((widget.size.width * scale).rounded()),
                           y1: Int((widget.size.height * scale).rounded()))
    // 1. Boxes: ink rounded out to device pixels, clipped to the window.
    var boxes: [PixelRect?] = widget.elements.map {
        let b = PixelRect.roundingOut($0.ink, scale: scale).intersection(window)
        return b.isEmpty ? nil : b
    }
    let skipped = boxes.indices.filter { boxes[$0] == nil }
    // 2. Base: the leading run of big elements (≥ 50 % of the window).
    var base: [Int] = []
    for (i, e) in widget.elements.enumerated() {
        guard let b = boxes[i] else { continue }
        guard e.big, b.area * 2 >= window.area else { break }
        base.append(i)
        boxes[i] = nil
    }
    // 3. Union-find on overlapping boxes, then merge groups whose bounding boxes intersect until stable.
    var groups: [Group] = boxes.enumerated().compactMap { i, b in b.map { Group(id: i, elements: [i], box: $0) } }
    func stabilize() {
        var merged = true
        while merged {
            merged = false
            outer: for a in 0..<groups.count {
                for b in (a + 1)..<groups.count where groups[a].box.intersects(groups[b].box) {
                    groups[a].elements += groups[b].elements
                    groups[a].box = groups[a].box.union(groups[b].box)
                    groups[a].id = min(groups[a].id, groups[b].id)
                    groups.remove(at: b)
                    merged = true
                    break outer
                }
            }
        }
    }
    stabilize()
    // 4. Cap: merge the pair whose union grows the least, then stabilize again.
    while groups.count > maxGroups {
        var best = (0, 1, Int.max)
        for a in 0..<groups.count {
            for b in (a + 1)..<groups.count {
                let u = groups[a].box.union(groups[b].box)
                let growth = u.area - groups[a].box.area - groups[b].box.area
                if growth < best.2 { best = (a, b, growth) }
            }
        }
        let (a, b, _) = best
        groups[a].elements += groups[b].elements
        groups[a].box = groups[a].box.union(groups[b].box)
        groups[a].id = min(groups[a].id, groups[b].id)
        groups.remove(at: b)
        stabilize()
    }
    for i in groups.indices { groups[i].elements.sort() }
    groups.sort { $0.id < $1.id }
    return Partition(window: window, scale: scale, base: base, groups: groups,
                     tiles: tiles(window, minus: groups.map(\.box)), skipped: skipped)
}

/// `window` minus `holes` as disjoint rectangles: horizontal bands between all hole edges, free spans in each band,
/// and a span continued into the next band when that band has the same span.
func tiles(_ window: PixelRect, minus holes: [PixelRect]) -> [PixelRect] {
    var ys = Set([window.y0, window.y1])
    for h in holes { ys.insert(h.y0); ys.insert(h.y1) }
    let bands = ys.sorted()
    var done: [PixelRect] = []
    var open: [Int: PixelRect] = [:]   // key: x0 << 20 | x1
    for k in 0..<(bands.count - 1) {
        let y0 = bands[k], y1 = bands[k + 1]
        guard y1 > y0 else { continue }
        let covering = holes.filter { $0.y0 < y1 && $0.y1 > y0 }.map { ($0.x0, $0.x1) }.sorted { $0.0 < $1.0 }
        var spans: [(Int, Int)] = []
        var x = window.x0
        for (a, b) in covering {
            if a > x { spans.append((x, a)) }
            x = max(x, b)
        }
        if x < window.x1 { spans.append((x, window.x1)) }
        var next: [Int: PixelRect] = [:]
        for (a, b) in spans {
            let key = a << 20 | b
            if var r = open[key], r.y1 == y0 {
                r.y1 = y1
                next[key] = r
                open[key] = nil
            } else {
                next[key] = PixelRect(x0: a, y0: y0, x1: b, y1: y1)
            }
        }
        done += open.values
        open = next
    }
    done += open.values
    return done.sorted { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
}

// MARK: Offline drawing of a partition (sRGB, 8-bit, premultiplied)

/// The base bitmap: the base elements drawn once into a whole-window bitmap.
func renderBase(_ widget: Widget, _ p: Partition, tick: Int) -> CGImage {
    renderWidget(widget, tick: tick, scale: p.scale, p.base.map { widget.elements[$0] })
}

/// Draws a group into a context whose device pixels are the group's box: first the base's pixels under the box,
/// copied exactly (.copy, no interpolation, in device space), then the group's elements, moved by whole pixels.
func drawGroup(_ widget: Widget, _ g: Group, base: CGImage, scale: CGFloat, tick: Int, into ctx: CGContext,
               baseCrop: CGImage? = nil) {
    if let crop = baseCrop ?? base.cropping(to: g.box.cg) {
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: g.box.width, height: g.box.height))
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(g.box.height))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -CGFloat(g.box.x0) / scale, y: -CGFloat(g.box.y0) / scale)
    widget.draw(ctx, tick: tick, g.elements.map { widget.elements[$0] })
    ctx.restoreGState()
}

func renderGroup(_ widget: Widget, _ g: Group, base: CGImage, scale: CGFloat, tick: Int,
                 space: CGColorSpace = sRGB) -> CGImage {
    let ctx = CGContext(data: nil, width: g.box.width, height: g.box.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: bgraInfo)!
    drawGroup(widget, g, base: base, scale: scale, tick: tick, into: ctx)
    return ctx.makeImage()!
}

/// The partition composited offline: the base bitmap, with each group's bitmap copied over its box.
func composePartition(_ widget: Widget, _ p: Partition, tick: Int) -> CGImage {
    let base = renderBase(widget, p, tick: tick)
    let ctx = CGContext(data: nil, width: p.window.width, height: p.window.height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB, bitmapInfo: bgraInfo)!
    ctx.setBlendMode(.copy)
    ctx.interpolationQuality = .none
    ctx.draw(base, in: p.window.cg)
    for g in p.groups {
        let image = renderGroup(widget, g, base: base, scale: p.scale, tick: tick)
        // Device space has a bottom-left origin: the box's top-left pixel row y0 is at height - y1.
        ctx.draw(image, in: CGRect(x: g.box.x0, y: p.window.height - g.box.y1, width: g.box.width,
                                   height: g.box.height))
    }
    return ctx.makeImage()!
}

/// Ink escape check: each element drawn alone into a window-sized bitmap must leave every pixel
/// outside its box transparent. Returns the elements that escape, with the number of pixels outside.
func inkEscapes(_ widget: Widget, scale: CGFloat, ticks: [Int]) -> [String: Int] {
    var escapes: [String: Int] = [:]
    let margin: CGFloat = 20
    let canvas = CGSize(width: widget.size.width + 2 * margin, height: widget.size.height + 2 * margin)
    for (i, e) in widget.elements.enumerated() {
        let box = PixelRect.roundingOut(e.ink, scale: scale)
        for tick in ticks {
            let ctx = bitmapContext(canvas, scale: scale)
            ctx.translateBy(x: margin, y: margin)
            widget.draw(ctx, tick: tick, [e])
            let p = Pixels.of(ctx.makeImage()!)
            let off = Int(margin * scale)
            var outside = 0
            for y in 0..<p.height {
                for x in 0..<p.width where p.bytes[(y * p.width + x) * 4 + 3] != 0 {
                    if !box.contains(x: x - off, y: y - off) { outside += 1 }
                }
            }
            if outside > 0 { escapes["\(i):\(e.name)", default: 0] = max(escapes["\(i):\(e.name)"] ?? 0, outside) }
        }
    }
    return escapes
}
