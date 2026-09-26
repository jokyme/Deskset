import Foundation

/// Turns an outline plus a stroke style into a `ShapeStrokePlan`: pieces the host can stroke natively (CGPath
/// stroking supports flat/round/square caps and one join per piece) plus filled patches for everything else.
///
/// Manual rules implemented here (Attribute Modifiers):
/// - StrokeStartCap / StrokeEndCap (Flat, Round, Square, Triangle) apply to the start / end of an open shape and
///   are ignored on closed shapes; StrokeDashCap applies to both ends of every dash.
/// - StrokeDashes: dash, gap, dash, gap… as multiples of StrokeWidth; StrokeDashOffset shifts the pattern (also a
///   multiple of StrokeWidth). A dash of 0 with Round caps makes dots, with Triangle caps diamonds.
/// - Path segment commands: after `SetNoStroke 1` segments are not stroked; after `SetRoundJoin 1` joins are round.
///
/// Judgment calls where the manual is silent:
/// - Dashes are laid out along each figure starting at its start point; the pattern runs on across unstroked
///   segments. On a closed figure, a dash crossing the start point is drawn as one dash.
/// - An odd-length dash list is repeated once (like SVG); negative entries count as 0; an all-zero list, or a
///   pattern that would produce more than `maxDashes` dashes, draws a solid stroke. Positive StrokeDashOffset
///   advances into the pattern (the first dash starts shorter).
/// - Where the stroke stops because of SetNoStroke, the stroke end is flat. Inside dashes, SetRoundJoin is ignored.
/// - `Miter` joins beyond the miter limit are "squared off" at the limit (manual): the host's native miter bevels
///   them, and `clippedMiter` patches add the rest. `MiterOrBevel` is exactly the native behavior.
public enum ShapeStroker {
    /// Flattening tolerance for dashed outlines (points; about a tenth of a device pixel at 2x).
    static let dashTolerance = 0.05
    static let maxDashes = 20_000

    public static func plan(for path: ShapePath, style: ShapeStrokeStyle) -> ShapeStrokePlan? {
        let w0 = style.width
        guard w0 > 0, w0.isFinite else { return nil }
        let width = style.placement == .center ? w0 : 2 * w0
        var builder = Builder(style: style, width: width)
        let pattern = dashPattern(style.dashes, strokeWidth: w0)
        for sub in path.subpaths {
            var segs = sub.segments
            if sub.closed, sub.end.distance(to: sub.start) > 1e-9 {
                segs.append(ShapeSegment(.line(to: sub.start), stroked: segs.last?.stroked ?? true))
            }
            guard !segs.isEmpty else { continue }
            if let pattern {
                builder.dashed(start: sub.start, segs, closed: sub.closed, pattern: pattern,
                               phase: style.dashOffset * w0)
            } else {
                builder.solid(start: sub.start, segs, closed: sub.closed)
            }
        }
        let plan = ShapeStrokePlan(width: width, miterLimit: max(style.miterLimit, 1), runs: builder.runs,
                                   patches: builder.patches, placement: style.placement)
        return plan.isEmpty ? nil : plan
    }

    /// Dash lengths in points, or nil for a solid stroke.
    static func dashPattern(_ dashes: [Double], strokeWidth: Double) -> [Double]? {
        guard !dashes.isEmpty else { return nil }
        var p = dashes.map { $0.isFinite ? max($0, 0) * strokeWidth : 0 }
        if p.count % 2 == 1 { p += p }
        return p.reduce(0, +) > 1e-9 ? p : nil
    }

    // MARK: Cap and join shapes

    /// Closed outline of a cap at `point`, extending in `direction` (unit vector pointing away from the stroke).
    /// `overlap` moves the cap's base back into the stroke body so anti-aliased edges do not leave a seam.
    static func capPatch(_ cap: ShapeLineCap, at point: ShapePoint, direction: ShapePoint, halfWidth h: Double,
                         overlap: Double = 0) -> ShapeSubpath? {
        let n = direction.perpendicular
        let a = point + n * h, b = point - n * h
        let back = direction * -overlap
        func withBase(_ body: [ShapeSegment]) -> ShapeSubpath {
            var segs: [ShapeSegment] = overlap > 0 ? [ShapeSegment(.line(to: a))] : []
            segs += body
            if overlap > 0 { segs.append(ShapeSegment(.line(to: b + back))) }
            return ShapeSubpath(start: overlap > 0 ? a + back : a, segments: segs, closed: true)
        }
        switch cap {
        case .flat:
            return nil
        case .round:
            // Half disc beyond the end point.
            let tip = point + direction * h
            let k = h * ShapeGeometryBuilder.kappa
            return withBase([
                ShapeSegment(.cubic(control1: a + direction * k, control2: tip + n * k, to: tip)),
                ShapeSegment(.cubic(control1: tip - n * k, control2: b + direction * k, to: b)),
            ])
        case .square:
            return withBase([ShapeSegment(.line(to: a + direction * h)), ShapeSegment(.line(to: b + direction * h)),
                             ShapeSegment(.line(to: b))])
        case .triangle:
            return withBase([ShapeSegment(.line(to: point + direction * h)), ShapeSegment(.line(to: b))])
        }
    }

    static func polygon(_ pts: [ShapePoint]) -> ShapeSubpath {
        ShapeSubpath(start: pts.first ?? .zero, segments: pts.dropFirst().map { ShapeSegment(.line(to: $0)) }, closed: true)
    }

    /// Manual (StrokeLineJoin): "Miter: Mitered corners. The corner will be mitered up to the point of MiterLimit,
    /// then squared off." The host's native miter join bevels a corner whose miter exceeds the limit, so this
    /// returns the missing part: the corner's outer wedge cut by a line perpendicular to the miter direction at
    /// `limit × halfWidth` from the vertex (the bevel triangle included, so the patch overlaps the stroke body).
    /// Nil when the miter is within the limit, the segments continue straight on, or they exactly reverse
    /// (no outer side is defined).
    static func clippedMiter(at v: ShapePoint, incoming u: ShapePoint, outgoing w: ShapePoint, halfWidth h: Double,
                             limit: Double) -> ShapeSubpath? {
        let cosTurn = u.x * w.x + u.y * w.y
        let cross = u.x * w.y - u.y * w.x
        guard abs(cross) > 1e-12, h > 0 else { return nil }
        let cosHalf = ((1 + cosTurn) / 2).squareRoot()   // = 1 / miter ratio
        guard cosHalf * limit < 1, let m = (u - w).normalized else { return nil }
        let side = cross > 0 ? -h : h
        let a = v + u.perpendicular * side, b = v + w.perpendicular * side
        let reach = limit * h
        func along(_ p: ShapePoint, _ d: ShapePoint) -> Double { p.x * d.x + p.y * d.y }
        let um = along(u, m), wm = -along(w, m)
        guard um > 1e-12, wm > 1e-12 else { return nil }
        let sa = (reach - along(a - v, m)) / um
        let sb = (reach - along(b - v, m)) / wm
        guard sa > 0, sb > 0, sa.isFinite, sb.isFinite else { return nil }
        return polygon([v, a, a + u * sa, b - w * sb, b])
    }

    // MARK: Bounds

    /// Bounds of everything the plan paints (the "widened" bounds): the body of every flattened edge (± half the
    /// width along its normal), the joins (miter tips within the limit, round joins), the offset of every curve
    /// extremum, the native caps and the patches. Flat caps add nothing, so a horizontal line of width 4 from x 0
    /// to 100 spans exactly 0…100 × −2…2.
    public static func bounds(of plan: ShapeStrokePlan) -> ShapeRect? {
        var acc = ShapeBoundsAccumulator()
        let h = plan.width / 2
        for run in plan.runs {
            let sub = run.subpath
            var pts = ShapeMath.polyline(sub, tolerance: 0.05)
            if sub.closed, let first = pts.first, let last = pts.last, first.distance(to: last) > 1e-9 { pts.append(first) }
            // Drop repeated points so every edge has a direction.
            var clean: [ShapePoint] = []
            for p in pts where clean.last.map({ $0.distance(to: p) > 1e-9 }) ?? true { clean.append(p) }
            if sub.closed, clean.count > 1, let first = clean.first, let last = clean.last, first.distance(to: last) <= 1e-9 {
                clean.removeLast()
            }
            let n = clean.count
            guard n >= 2 else { continue }
            let edgeCount = sub.closed ? n : n - 1
            for i in 0..<edgeCount {
                let a = clean[i], b = clean[(i + 1) % n]
                guard let d = (b - a).normalized else { continue }
                let off = d.perpendicular * h
                acc.add(a + off); acc.add(a - off); acc.add(b + off); acc.add(b - off)
            }
            let vertices = sub.closed ? Array(0..<n) : Array(1..<(n - 1))
            for i in vertices {
                let v = clean[i]
                guard let u = (v - clean[(i - 1 + n) % n]).normalized, let w = (clean[(i + 1) % n] - v).normalized else { continue }
                switch run.join {
                case .round:
                    addDisc(v, h, &acc)
                case .miter, .miterOrBevel:
                    if let tip = miterTip(v, u, w, h: h, limit: plan.miterLimit) { acc.add(tip) }
                case .bevel:
                    break
                }
            }
            // Where a curve is vertical (horizontal) the stroke reaches exactly h further in x (y).
            var p0 = sub.start
            for seg in sub.segments {
                for e in ShapeMath.extrema(from: p0, seg.kind) {
                    if e.vertical { acc.add(e.point + ShapePoint(h, 0)); acc.add(e.point - ShapePoint(h, 0)) }
                    else { acc.add(e.point + ShapePoint(0, h)); acc.add(e.point - ShapePoint(0, h)) }
                }
                p0 = seg.kind.end
            }
            if !sub.closed, run.cap != .flat {
                if let d = (clean[1] - clean[0]).normalized {
                    capPatch(run.cap, at: clean[0], direction: d * -1, halfWidth: h).map { ShapeMath.bounds(of: $0, into: &acc) }
                }
                if let d = (clean[n - 1] - clean[n - 2]).normalized {
                    capPatch(run.cap, at: clean[n - 1], direction: d, halfWidth: h).map { ShapeMath.bounds(of: $0, into: &acc) }
                }
            }
        }
        for patch in plan.patches { ShapeMath.bounds(of: patch, into: &acc) }
        return acc.rect
    }

    private static func addDisc(_ c: ShapePoint, _ r: Double, _ acc: inout ShapeBoundsAccumulator) {
        acc.add(ShapePoint(c.x - r, c.y - r))
        acc.add(ShapePoint(c.x + r, c.y + r))
    }

    /// Outer point of a miter join at `v` (arriving along `u`, leaving along `w`), or nil when the join is
    /// smooth or beveled because the miter limit is exceeded.
    static func miterTip(_ v: ShapePoint, _ u: ShapePoint, _ w: ShapePoint, h: Double, limit: Double) -> ShapePoint? {
        let cosTurn = u.x * w.x + u.y * w.y
        guard cosTurn < 0.9999 else { return nil }
        let cosHalf = ((1 + cosTurn) / 2).squareRoot()   // cos(turn/2) = sin(interior angle/2)
        guard cosHalf > 1e-9 else { return nil }
        let ratio = 1 / cosHalf
        guard ratio <= limit, let m = (u - w).normalized else { return nil }
        return v + m * (h * ratio)
    }

    // MARK: Builder

    private struct Builder {
        let style: ShapeStrokeStyle
        let width: Double
        var runs: [ShapeStrokeRun] = []
        var patches: [ShapeSubpath] = []

        init(style: ShapeStrokeStyle, width: Double) {
            self.style = style
            self.width = width
        }

        var h: Double { width / 2 }

        /// Adds a native run; for `Miter` joins, also the clipped miters the host's stroker would bevel.
        mutating func appendRun(_ run: ShapeStrokeRun) {
            runs.append(run)
            // A single open segment (most dashes) has no join.
            guard run.join == .miter, run.subpath.closed || run.subpath.segments.count > 1 else { return }
            // Non-degenerate segments with their start points (a zero-length segment has no direction).
            var items: [(start: ShapePoint, kind: ShapeSegmentKind)] = []
            var p0 = run.subpath.start
            for seg in run.subpath.segments {
                if ShapeMath.startTangent(p0, seg.kind) != nil { items.append((p0, seg.kind)) }
                p0 = seg.kind.end
            }
            if run.subpath.closed, p0.distance(to: run.subpath.start) > 1e-9 {
                items.append((p0, .line(to: run.subpath.start)))
            }
            guard items.count >= 2 else { return }
            func join(_ a: (start: ShapePoint, kind: ShapeSegmentKind), _ b: (start: ShapePoint, kind: ShapeSegmentKind)) {
                guard let u = ShapeMath.endTangent(a.start, a.kind), let w = ShapeMath.startTangent(b.start, b.kind),
                      let patch = ShapeStroker.clippedMiter(at: b.start, incoming: u, outgoing: w, halfWidth: h,
                                                            limit: max(style.miterLimit, 1)) else { return }
                patches.append(patch)
            }
            for i in 1..<items.count { join(items[i - 1], items[i]) }
            if run.subpath.closed, let last = items.last, let first = items.first { join(last, first) }
        }

        /// Adds a run, drawing the caps natively when both ends use the same flat/round/square cap.
        mutating func addRun(_ sub: ShapeSubpath, startCap: ShapeLineCap, endCap: ShapeLineCap,
                             startDirection: ShapePoint?, endDirection: ShapePoint?, join: ShapeLineJoin) {
            let zeroLength = sub.segments.allSatisfy { $0.kind.end.distance(to: sub.start) < 1e-12 }
            if !zeroLength, startCap == endCap, startCap != .triangle {
                appendRun(ShapeStrokeRun(subpath: sub, join: join, cap: startCap))
                return
            }
            if !zeroLength { appendRun(ShapeStrokeRun(subpath: sub, join: join, cap: .flat)) }
            let sd = startDirection ?? endDirection ?? ShapePoint(1, 0)
            let ed = endDirection ?? startDirection ?? ShapePoint(1, 0)
            // Overlap the body a little (never more than the run is long) to avoid anti-aliasing seams.
            var length = 0.0
            var p0 = sub.start
            for seg in sub.segments {
                length += p0.distance(to: seg.kind.end)
                p0 = seg.kind.end
            }
            let overlap = zeroLength ? 0 : min(0.5, length / 2)
            if let p = ShapeStroker.capPatch(startCap, at: sub.start, direction: sd * -1, halfWidth: h, overlap: overlap) {
                patches.append(p)
            }
            if let p = ShapeStroker.capPatch(endCap, at: sub.end, direction: ed, halfWidth: h, overlap: overlap) { patches.append(p) }
        }

        // MARK: Solid strokes

        mutating func solid(start: ShapePoint, _ segs: [ShapeSegment], closed: Bool) {
            let n = segs.count
            let base = style.join
            func startOf(_ i: Int) -> ShapePoint { i == 0 ? start : segs[i - 1].kind.end }
            /// Why the stroke must be split at the vertex where `segs[i]` begins (nil = joined natively).
            func breakKind(_ i: Int) -> (roundDisc: Bool, split: Bool) {
                let prev = i == 0 ? n - 1 : i - 1
                if !segs[i].stroked || !segs[prev].stroked { return (false, true) }
                if segs[i].roundJoin && base != .round { return (true, true) }
                return (false, false)
            }

            var order = Array(0..<n)
            if closed {
                if let b = (0..<n).first(where: { breakKind($0).split }) {
                    order = Array(b..<n) + Array(0..<b)
                    if breakKind(b).roundDisc { addDisc(startOf(b)) }
                } else {
                    appendRun(ShapeStrokeRun(subpath: ShapeSubpath(start: start, segments: segs, closed: true),
                                             join: base, cap: .flat))
                    return
                }
            }

            var current: [Int] = []
            func flush(isLast: Bool) {
                guard let first = current.first, let last = current.last else { return }
                let s = startOf(first)
                let sub = ShapeSubpath(start: s, segments: current.map { segs[$0] }, closed: false)
                let startCap = !closed && first == 0 ? style.startCap : .flat
                let endCap = !closed && isLast && last == n - 1 ? style.endCap : .flat
                addRun(sub, startCap: startCap, endCap: endCap,
                       startDirection: ShapeMath.startTangent(s, segs[first].kind),
                       endDirection: ShapeMath.endTangent(startOf(last), segs[last].kind), join: base)
                current = []
            }
            for (k, i) in order.enumerated() {
                if k > 0 {
                    let b = breakKind(i)
                    if b.split {
                        flush(isLast: false)
                        if b.roundDisc { addDisc(startOf(i)) }
                    }
                }
                if segs[i].stroked { current.append(i) }
            }
            flush(isLast: true)
        }

        mutating func addDisc(_ p: ShapePoint) {
            patches.append(ShapeGeometryBuilder.ellipse(centerX: p.x, centerY: p.y, radiusX: h))
        }

        // MARK: Dashed strokes

        private struct Edge {
            var a: ShapePoint
            var b: ShapePoint
            var startDistance: Double
            var length: Double
            var stroked: Bool
        }

        private struct Piece {
            var points: [ShapePoint]
            var startDirection: ShapePoint
            var endDirection: ShapePoint
            var atStart: Bool
            var atEnd: Bool
        }

        mutating func dashed(start: ShapePoint, _ segs: [ShapeSegment], closed: Bool, pattern: [Double], phase: Double) {
            var edges: [Edge] = []
            var total = 0.0
            var p0 = start
            for seg in segs {
                var pts: [ShapePoint] = []
                ShapeMath.flatten(from: p0, seg.kind, tolerance: ShapeStroker.dashTolerance, into: &pts)
                var a = p0
                for b in pts {
                    let len = a.distance(to: b)
                    if len > 1e-12 {
                        edges.append(Edge(a: a, b: b, startDistance: total, length: len, stroked: seg.stroked))
                        total += len
                    }
                    a = b
                }
                p0 = seg.kind.end
            }
            let sum = pattern.reduce(0, +)
            guard !edges.isEmpty, total > 0 else {
                // A figure of zero length: only dash caps could show; treat it as a dot at the start.
                if segs.contains(where: \.stroked) {
                    let sub = ShapeSubpath(start: start, segments: [ShapeSegment(.line(to: start))])
                    addRun(sub, startCap: closed ? style.dashCap : style.startCap, endCap: closed ? style.dashCap : style.endCap,
                           startDirection: nil, endDirection: nil, join: style.join)
                }
                return
            }
            // Too many dashes: draw solid.
            if total / sum * Double(pattern.count / 2) > Double(ShapeStroker.maxDashes) {
                solid(start: start, segs, closed: closed)
                return
            }

            var intervals: [(Double, Double)] = []
            var offset = phase.truncatingRemainder(dividingBy: sum)
            if offset < 0 { offset += sum }
            var pos = -offset
            var i = 0
            while pos <= total, intervals.count <= ShapeStroker.maxDashes {
                let len = pattern[i]
                if i % 2 == 0, pos + len >= 0 {
                    intervals.append((max(pos, 0), min(pos + len, total)))
                }
                pos += len
                i = (i + 1) % pattern.count
            }

            var pieces: [Piece] = []
            for (a, b) in intervals { extract(edges, from: a, to: b, total: total, into: &pieces) }
            if closed, pieces.count == 1, let only = pieces.first, only.atStart, only.atEnd, only.points.count >= 2 {
                // One dash covers the whole closed figure: no seam, no caps.
                appendRun(ShapeStrokeRun(subpath: ShapeSubpath(start: only.points[0],
                                                               segments: only.points.dropFirst().map { ShapeSegment(.line(to: $0)) },
                                                               closed: true),
                                         join: style.join, cap: .flat))
                return
            }
            if closed, pieces.count >= 2, let first = pieces.first, let last = pieces.last, first.atStart, last.atEnd {
                var merged = last
                merged.points += first.points.dropFirst()
                merged.endDirection = first.endDirection
                merged.atEnd = first.atEnd
                pieces[0] = merged
                pieces.removeLast()
            }
            for piece in pieces {
                let startCap = !closed && piece.atStart ? style.startCap : style.dashCap
                let endCap = !closed && piece.atEnd ? style.endCap : style.dashCap
                let sub = ShapeSubpath(start: piece.points[0],
                                       segments: piece.points.dropFirst().map { ShapeSegment(.line(to: $0)) })
                addRun(sub.segments.isEmpty ? ShapeSubpath(start: sub.start, segments: [ShapeSegment(.line(to: sub.start))]) : sub,
                       startCap: startCap, endCap: endCap,
                       startDirection: piece.startDirection, endDirection: piece.endDirection, join: style.join)
            }
        }

        /// The stroked parts of the outline between distances `a` and `b` (a ≤ b).
        private func extract(_ edges: [Edge], from a: Double, to b: Double, total: Double, into pieces: inout [Piece]) {
            var current: Piece?
            func point(_ e: Edge, _ d: Double) -> ShapePoint {
                let t = e.length > 0 ? min(max((d - e.startDistance) / e.length, 0), 1) : 0
                return e.a + (e.b - e.a) * t
            }
            // First edge that can contain `a` (binary search keeps long dashed paths cheap).
            var lo = 0, hi = edges.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if edges[mid].startDistance + edges[mid].length < a { lo = mid + 1 } else { hi = mid }
            }
            var k = lo
            while k < edges.count, edges[k].startDistance <= b {
                let e = edges[k]
                let eEnd = e.startDistance + e.length
                k += 1
                if eEnd < a { continue }
                let dir = (e.b - e.a).normalized ?? ShapePoint(1, 0)
                guard e.stroked else {
                    if let c = current { pieces.append(c) }
                    current = nil
                    continue
                }
                let s = max(a, e.startDistance), t = min(b, eEnd)
                var piece = current ?? Piece(points: [point(e, s)], startDirection: dir, endDirection: dir,
                                             atStart: s <= 1e-9, atEnd: false)
                let q = point(e, t)
                if let last = piece.points.last, q.distance(to: last) > 1e-12 { piece.points.append(q) }
                piece.endDirection = dir
                piece.atEnd = t >= total - 1e-9
                current = piece
                if t >= b { break }
            }
            if let c = current { pieces.append(c) }
        }
    }
}
