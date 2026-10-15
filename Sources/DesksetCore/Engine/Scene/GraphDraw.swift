import Foundation

/// A read-only, copy-on-write history snapshot. Only lowering constructs it, so its samples cannot be replaced
/// without taking their revision too. Comparing drawings never walks the potentially long sample buffers.
public struct GraphDrawHistory: Equatable, Sendable {
    private let history: GraphHistory
    private let owner: UUID
    private let slot: Int
    private let drawGeneration: Int

    init(_ history: GraphHistory, owner: UUID, slot: Int, drawGeneration: Int) {
        self.history = history
        self.owner = owner
        self.slot = slot
        self.drawGeneration = drawGeneration
    }

    public var capacity: Int { history.capacity }
    public var count: Int { history.count }
    public func value(age: Int) -> Double { history.value(age: age) }

    public static func == (lhs: GraphDrawHistory, rhs: GraphDrawHistory) -> Bool {
        lhs.owner == rhs.owner && lhs.slot == rhs.slot && lhs.drawGeneration == rhs.drawGeneration
            && lhs.history.revision == rhs.history.revision
    }
}

/// A Line's history, range and paint captured on its owner's thread, with no live measure references.
public struct LineDraw: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let color: RGBA
        public let scale: Double
        public let isBound: Bool
        public let history: GraphDrawHistory
    }

    public let lines: [Line]
    public let geometry: GraphGeometry
    public let historyLength: Int
    public let rangeMin: Double
    public let rangeMax: Double
    public let autoScale: Bool
    public let lineWidth: Double
    public let horizontalLines: Bool
    public let horizontalLineColor: RGBA
    public let markerCoordinates: [Double]
    public let transformStrokeFixed: Bool
    public let transformationMatrix: [Double]?
    public let antiAlias: Bool

    public var contentFrame: SkinRect { geometry.frame }
    public var direction: GraphDirection { geometry.direction }

    public func fraction(line: Int, age: Int) -> Double {
        guard lines.indices.contains(line) else { return 0 }
        var v = lines[line].history.value(age: age)
        if !autoScale { v *= lines[line].scale }
        return GraphRange.fraction(v, rangeMin, rangeMax)
    }
}

/// A Histogram's history and current ranges. Without AutoScale, a measure's range may change between meter
/// updates, so the range is captured separately from the versioned sample buffers.
public struct HistogramDraw: Equatable, Sendable {
    public struct Series: Equatable, Sendable {
        public let history: GraphDrawHistory
        public let isBound: Bool
        public let minValue: Double
        public let maxValue: Double
    }

    public let primary: Series
    public let secondary: Series
    public let geometry: GraphGeometry
    public let historyLength: Int
    public let autoScale: Bool
    public let autoRangeMin: Double
    public let autoRangeMax: Double
    public let primaryColor: RGBA
    public let secondaryColor: RGBA
    public let bothColor: RGBA
    public let primaryImage: HistogramMeter.HistogramImage?
    public let secondaryImage: HistogramMeter.HistogramImage?
    public let bothImage: HistogramMeter.HistogramImage?
    public let antiAlias: Bool

    public var contentFrame: SkinRect { geometry.frame }
    public var direction: GraphDirection { geometry.direction }
    public var hasSecondary: Bool { secondary.isBound }

    public func fraction(secondary: Bool = false, age: Int) -> Double {
        let series = secondary ? self.secondary : primary
        guard series.isBound else { return 0 }
        let v = series.history.value(age: age)
        if autoScale { return GraphRange.fraction(v, autoRangeMin, autoRangeMax) }
        return GraphRange.fraction(v, series.minValue, series.maxValue)
    }

    public func columnLengths(age: Int) -> (primary: Double, secondary: Double) {
        let length = geometry.valueLength
        func size(_ f: Double) -> Double {
            let v = f * length
            return antiAlias ? v : v.rounded()
        }
        return (size(fraction(age: age)), hasSecondary ? size(fraction(secondary: true, age: age)) : 0)
    }

    public func columnRects(age: Int) -> (primary: SkinRect, secondary: SkinRect, both: SkinRect) {
        let g = geometry
        let (p, s) = columnLengths(age: age)
        let empty = g.column(age: age, from: 0, to: 0)
        guard hasSecondary else { return (g.column(age: age, from: 0, to: p), empty, empty) }
        let common = min(p, s)
        return (p > common ? g.column(age: age, from: common, to: p) : empty,
                s > common ? g.column(age: age, from: common, to: s) : empty,
                common > 0 ? g.column(age: age, from: 0, to: common) : empty)
    }
}

public extension LineMeter {
    /// Captures the current drawing after layout, on the skin's owner.
    func lower() -> LineDraw {
        skin.assertOwned()
        let captured = lines.enumerated().map { index, line in
            LineDraw.Line(color: line.color, scale: line.scale, isBound: line.measure != nil,
                          history: GraphDrawHistory(line.history, owner: drawIdentity, slot: index,
                                                    drawGeneration: drawGeneration))
        }
        return LineDraw(lines: captured, geometry: geometry, historyLength: historyLength,
                        rangeMin: rangeMin, rangeMax: rangeMax, autoScale: autoScale, lineWidth: lineWidth,
                        horizontalLines: horizontalLines, horizontalLineColor: horizontalLineColor,
                        markerCoordinates: markerCoordinates, transformStrokeFixed: transformStrokeFixed,
                        transformationMatrix: transformationMatrix, antiAlias: antiAlias)
    }
}

public extension HistogramMeter {
    /// Captures the current drawing, including each measure's range as it is read when drawn.
    func lower() -> HistogramDraw {
        skin.assertOwned()
        func series(_ history: GraphHistory, _ measure: Measure?, slot: Int) -> HistogramDraw.Series {
            HistogramDraw.Series(history: GraphDrawHistory(history, owner: drawIdentity, slot: slot,
                                                           drawGeneration: drawGeneration),
                                 isBound: measure != nil, minValue: measure?.minValue ?? 0,
                                 maxValue: measure?.maxValue ?? 1)
        }
        return HistogramDraw(primary: series(primaryHistory, primaryMeasure, slot: 0),
                             secondary: series(secondaryHistory, secondaryMeasure, slot: 1), geometry: geometry,
                             historyLength: historyLength, autoScale: autoScale,
                             autoRangeMin: autoRangeMin, autoRangeMax: autoRangeMax,
                             primaryColor: primaryColor, secondaryColor: secondaryColor, bothColor: bothColor,
                             primaryImage: primaryImage, secondaryImage: secondaryImage, bothImage: bothImage,
                             antiAlias: antiAlias)
    }
}
