import Foundation

// Shared pieces of the Line and Histogram meters (LineMeter.swift, HistogramMeter.swift).
//
// Manual (docs.rainmeter.net/manual/meters/line/ and /manual/meters/histogram/): both meters display the current
// and past values of their measures. Common options:
// - GraphStart (default Right): starting point of the graph, Left or Right.
// - GraphOrientation (default Vertical): orientation of the graph elements, Horizontal or Vertical.
// - Flip (default 0): 1 flips the meter vertically.
//
// Judgment calls (the manual is silent on these):
// - One sample per pixel along the time axis: the history holds W samples (H for GraphOrientation=Horizontal),
//   in whole pixels, capped at `GraphHistory.maxCapacity`. A sample is added on every meter update (so a meter
//   UpdateDivider slows the scrolling). Slots not filled yet read as 0, so a fresh graph starts as a flat line.
// - GraphStart=Right puts the newest sample at the right edge and the graph scrolls to the left; Left mirrors it.
// - GraphOrientation=Horizontal is the vertical graph turned 90° clockwise: values grow from the left edge
//   towards the right, GraphStart=Right puts the newest sample at the bottom (Left: at the top) and Flip=1 makes
//   values grow from the right edge — i.e. Flip always mirrors the value axis in the graph's own frame.
// - When the time-axis size changes (W/H via !SetOption, a new image), the newest samples are kept.

/// Fixed-size ring buffer of graph samples.
public struct GraphHistory {
    /// Upper bound for the history length (a W of 1e9 must not allocate gigabytes).
    public static let maxCapacity = 8192

    public private(set) var capacity: Int
    /// Number of samples recorded so far (≤ capacity).
    public private(set) var count = 0
    private var storage: [Double]
    /// Next write position.
    private var head = 0

    public init(capacity: Int = 0) {
        let c = GraphHistory.clampedCapacity(capacity)
        self.capacity = c
        storage = Array(repeating: 0, count: c)
    }

    static func clampedCapacity(_ c: Int) -> Int {
        min(max(c, 0), maxCapacity)
    }

    /// History length for a size in points (W or H): whole pixels, clamped; NaN / negative → 0.
    static func capacity(forLength length: Double?) -> Int {
        guard let length, length.isFinite, length >= 1 else { return 0 }
        return Int(length.clamped(0, Double(maxCapacity)))
    }

    /// Adds the newest sample (non-finite values are stored as 0). No-op when the capacity is 0.
    public mutating func append(_ value: Double) {
        guard capacity > 0 else { return }
        storage[head] = value.isFinite ? value : 0
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Sample by age: 0 is the newest. Ages that were never filled (or are out of range) read as 0.
    public func value(age: Int) -> Double {
        guard age >= 0, age < count else { return 0 }
        var i = head - 1 - age
        if i < 0 { i += capacity }
        return storage[i]
    }

    /// Changes the capacity, keeping the newest samples.
    public mutating func resize(to newCapacity: Int) {
        let c = GraphHistory.clampedCapacity(newCapacity)
        guard c != capacity else { return }
        let keep = min(count, c)
        var fresh = Array(repeating: 0.0, count: c)
        for j in 0..<keep { fresh[j] = value(age: keep - 1 - j) }  // oldest kept sample first
        storage = fresh
        capacity = c
        count = keep
        head = c == 0 ? 0 : keep % c
    }

    public mutating func removeAll() {
        for i in storage.indices { storage[i] = 0 }
        count = 0
        head = 0
    }

    /// Smallest and largest recorded sample; nil while nothing was recorded.
    public var extremes: (min: Double, max: Double)? {
        guard count > 0 else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        for age in 0..<count {
            let v = value(age: age)
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        return (lo, hi)
    }

    /// Recorded samples, oldest first (for tests and debugging).
    public var samples: [Double] {
        (0..<count).reversed().map { value(age: $0) }
    }
}

/// GraphStart / GraphOrientation / Flip.
public struct GraphDirection: Equatable {
    /// GraphStart=Right (default): the newest sample is at the right (bottom when horizontal).
    public var startRight = true
    /// GraphOrientation=Vertical (default): time runs along X, values along Y.
    public var vertical = true
    /// Flip=1: values grow from the top (from the right when horizontal).
    public var flip = false

    public init(startRight: Bool = true, vertical: Bool = true, flip: Bool = false) {
        self.startRight = startRight
        self.vertical = vertical
        self.flip = flip
    }

    /// Unknown values fall back to the defaults (Right, Vertical).
    static func read(from section: SkinSection) -> GraphDirection {
        func keyword(_ key: String, _ defaultValue: String) -> String {
            section.string(key, defaultValue).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return GraphDirection(startRight: keyword("GraphStart", "Right") != "left",
                              vertical: keyword("GraphOrientation", "Vertical") != "horizontal",
                              flip: section.bool("Flip", false))
    }
}

/// Maps graph samples to skin coordinates inside a meter's content rectangle.
public struct GraphGeometry: Equatable {
    public var frame: SkinRect
    public var direction: GraphDirection

    public init(frame: SkinRect, direction: GraphDirection) {
        self.frame = frame
        self.direction = direction
    }

    /// Size of the time axis in points (one sample per point).
    public var timeLength: Double { direction.vertical ? frame.width : frame.height }
    /// Size of the value axis in points.
    public var valueLength: Double { direction.vertical ? frame.height : frame.width }

    /// Leading edge (skin coordinate on the time axis) of the one-point slot of the sample `age` samples old.
    /// The newest sample sits at the GraphStart edge, so a graph wider than its history stays anchored there.
    public func slotStart(age: Int) -> Double {
        let a = Double(age)
        if direction.vertical { return direction.startRight ? frame.maxX - 1 - a : frame.x + a }
        return direction.startRight ? frame.maxY - 1 - a : frame.y + a
    }

    /// Skin coordinate on the value axis at `distance` points from the baseline.
    public func valueCoordinate(_ distance: Double) -> Double {
        if direction.vertical { return direction.flip ? frame.y + distance : frame.maxY - distance }
        return direction.flip ? frame.maxX - distance : frame.x + distance
    }

    /// Line vertex of a sample with a 0…1 value: pixel centers, so a 1-pixel line at 0 or 1 stays inside the meter.
    public func point(age: Int, fraction: Double) -> (x: Double, y: Double) {
        let t = slotStart(age: age) + 0.5
        let v = valueCoordinate(fraction.clamped(0, 1) * max(valueLength - 1, 0) + min(valueLength, 1) / 2)
        return direction.vertical ? (t, v) : (v, t)
    }

    /// `point(age:fraction:)` with the value rounded to whole pixels when `wholePixels` is set (AntiAlias=0, like
    /// the histogram's whole-pixel columns): the vertex sits on the center of the pixel row (column) the value
    /// falls in, so an aliased 1-pixel line is never rasterized two pixels thick at values that land exactly
    /// between two pixel rows.
    public func point(age: Int, fraction: Double, wholePixels: Bool) -> (x: Double, y: Double) {
        guard wholePixels else { return point(age: age, fraction: fraction) }
        let t = slotStart(age: age) + 0.5
        let steps = max(valueLength.rounded(.down) - 1, 0)
        let v = valueCoordinate((fraction.clamped(0, 1) * steps).rounded() + min(valueLength, 1) / 2)
        return direction.vertical ? (t, v) : (v, t)
    }

    /// Rectangle of the column slot `age` between two distances from the baseline (a histogram element).
    public func column(age: Int, from: Double, to: Double) -> SkinRect {
        let t = slotStart(age: age)
        let a = valueCoordinate(from), b = valueCoordinate(to)
        let lo = min(a, b), size = abs(b - a)
        return direction.vertical ? SkinRect(x: t, y: lo, width: 1, height: size)
            : SkinRect(x: lo, y: t, width: size, height: 1)
    }
}

enum GraphRange {
    /// Maps `value` into 0…1 within lo…hi; an empty or invalid range maps everything to 0.
    static func fraction(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        guard lo.isFinite, hi.isFinite, hi > lo else { return 0 }
        let span = hi - lo
        // MinValue=-1e308, MaxValue=1e308: the span overflows, so work with halves (still exact enough).
        let f = span.isFinite ? (value - lo) / span : (value / 2 - lo / 2) / (hi / 2 - lo / 2)
        return f.clamped(0, 1)
    }

    /// A usable range: non-finite bounds are replaced and `hi` is forced above `lo`.
    static func normalized(_ lo: Double, _ hi: Double) -> (min: Double, max: Double) {
        let l = lo.isFinite ? lo : 0
        var h = hi.isFinite ? hi : l + 1
        if !(h > l) { h = l + 1 }
        return (l, h)
    }
}
