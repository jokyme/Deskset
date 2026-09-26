import Foundation

/// `Meter=Line`: the values of one or more measures as data points connected by straight line segments.
///
/// Manual (docs.rainmeter.net/manual/meters/line/):
/// - LineCount (default 1) lines; line N reads MeasureNameN, LineColorN, ScaleN (N omitted for the first line).
/// - LineWidth (default 1) in pixels.
/// - ScaleN (default 1.0) multiplies the measure value used for the line; ignored when AutoScale=1.
/// - AutoScale=1: the lines are scaled so the largest value is visible. Otherwise "the largest maximum value of
///   all of the measures used is used as the scale".
/// - HorizontalLines=1 draws marker lines behind the lines in HorizontalLineColor (default 0,0,0,255).
/// - GraphStart, GraphOrientation, Flip: see GraphHistory.swift.
/// - TransformStroke=Fixed keeps LineWidth unchanged by TransformationMatrix (done by the renderer).
///
/// Judgment calls:
/// - The value range is MinValue…MaxValue: the smallest MinValue and the largest MaxValue of the bound measures
///   (the version history notes MinValue is applied too). Values are clamped into the meter.
/// - AutoScale=1 range: from min(smallest MinValue, smallest recorded sample) to the largest recorded sample of
///   all lines (one common scale, so lines stay comparable). All-equal samples use a range of 1.
/// - LineColor has no documented default; white is used.
/// - Measure bindings are read per line (MeasureName, MeasureName2…MeasureNameLineCount) even across gaps; a line
///   whose measure is missing or unknown is not drawn. LineCount is capped at `maxLineCount`.
/// - The history stores raw measure values, so a changing MaxValue (e.g. Net measures that learn their maximum)
///   rescales the whole graph.
/// - HorizontalLines: the value axis is divided into quarters (halves below 16 px, none below 4 px); the markers
///   run parallel to the time axis (vertical lines when GraphOrientation=Horizontal).
public final class LineMeter: Meter {
    public static let maxLineCount = 64
    public static let defaultLineColor = RGBA.white

    public struct Line {
        public internal(set) var color: RGBA
        public internal(set) var scale: Double
        /// Bound measure; nil when MeasureNameN is empty or names no measure (the line is not drawn).
        public internal(set) var measure: Measure?
        public internal(set) var history: GraphHistory
    }

    public private(set) var lines: [Line] = []
    public private(set) var lineWidth = 1.0
    public private(set) var horizontalLines = false
    public private(set) var horizontalLineColor = RGBA.black
    public private(set) var autoScale = false
    public private(set) var direction = GraphDirection()
    /// TransformStroke=Fixed.
    public private(set) var transformStrokeFixed = false
    /// Samples per line (the time axis in whole pixels).
    public private(set) var historyLength = 0
    /// Value range mapped onto the value axis (recomputed on every meter update).
    public private(set) var rangeMin = 0.0
    public private(set) var rangeMax = 1.0

    public override func readMeterOptions() {
        let count = Int(double("LineCount", 1).clamped(0, Double(LineMeter.maxLineCount)))
        var newLines: [Line] = []
        newLines.reserveCapacity(count)
        for i in 0..<count {
            let suffix = i == 0 ? "" : String(i + 1)
            let measureName = string("MeasureName\(suffix)").trimmingCharacters(in: .whitespaces)
            let measure = measureName.isEmpty ? nil : skin.measure(named: measureName)
            let lineColor = color("LineColor\(suffix)", LineMeter.defaultLineColor)
            let scale = double("Scale\(suffix)", 1)
            let history = i < lines.count ? lines[i].history : GraphHistory(capacity: historyLength)
            newLines.append(Line(color: lineColor, scale: scale.isFinite ? scale : 1, measure: measure,
                                 history: history))
        }
        lines = newLines
        lineWidth = double("LineWidth", 1).clamped(0, 1000)
        horizontalLines = bool("HorizontalLines", false)
        horizontalLineColor = color("HorizontalLineColor", .black)
        autoScale = bool("AutoScale", false)
        direction = GraphDirection.read(from: self)
        transformStrokeFixed = string("TransformStroke", "Normal").trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("Fixed") == .orderedSame
    }

    /// Adds one sample per line, resizing the histories first when W (H) changed.
    public override func updateMeter() {
        historyLength = GraphHistory.capacity(forLength: direction.vertical ? widthOption : heightOption)
        for i in lines.indices {
            lines[i].history.resize(to: historyLength)
            lines[i].history.append(lines[i].measure?.value ?? 0)
        }
        computeRange()
    }

    private func computeRange() {
        var lo = Double.infinity, hi = -Double.infinity
        for line in lines {
            guard let m = line.measure else { continue }
            lo = min(lo, m.minValue)
            if autoScale {
                if let e = line.history.extremes {
                    lo = min(lo, e.min)
                    hi = max(hi, e.max)
                }
            } else {
                hi = max(hi, m.maxValue)
            }
        }
        if lo == .infinity { lo = 0 }
        if hi == -.infinity { hi = autoScale ? lo : 1 }
        (rangeMin, rangeMax) = GraphRange.normalized(lo, hi)
    }

    /// Value of `line` `age` samples ago, mapped to 0…1 on the value axis (Scale applied unless AutoScale).
    public func fraction(line: Int, age: Int) -> Double {
        guard lines.indices.contains(line) else { return 0 }
        var v = lines[line].history.value(age: age)
        if !autoScale { v *= lines[line].scale }
        return GraphRange.fraction(v, rangeMin, rangeMax)
    }

    /// Geometry of the current content frame.
    public var geometry: GraphGeometry { GraphGeometry(frame: contentFrame, direction: direction) }

    /// Vertex (skin coordinates) of `line` for the sample `age` samples old.
    public func point(line: Int, age: Int) -> (x: Double, y: Double) {
        geometry.point(age: age, fraction: fraction(line: line, age: age))
    }

    /// Skin coordinates (on the value axis) of the HorizontalLines markers, pixel-aligned to line centers.
    public var markerCoordinates: [Double] {
        let g = geometry
        let length = g.valueLength
        let divisions = length >= 16 ? 4 : (length >= 4 ? 2 : 0)
        guard divisions > 0 else { return [] }
        return (1..<divisions).map { k in
            (g.valueCoordinate(length * Double(k) / Double(divisions)) - 0.5).rounded(.down) + 0.5
        }
    }
}
