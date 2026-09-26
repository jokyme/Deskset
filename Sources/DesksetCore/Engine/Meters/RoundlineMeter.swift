import Foundation

// Roundline and Rotator meters, per the manual (docs.rainmeter.net/manual/meters/roundline/ and …/rotator/).
//
// Coordinates are skin coordinates: origin top-left, y grows downward. Angles are radians measured from the
// positive x axis ("the zero angle is to the right of the center"); because y points down, a positive angle
// turns clockwise on screen, so `StartAngle=4.712` (3π/2) points straight up and a positive `RotationAngle`
// runs clockwise — "use a negative value for counter-clockwise rotation".

/// Value and angle math shared by the Roundline and Rotator meters. Pure functions, no drawing.
public enum RoundMeterMath {
    public static let fullCircle = 2 * Double.pi

    /// Largest radius / offset / width we pass on to drawing; bigger (or infinite) option values are clamped.
    static let maxExtent = 1_000_000.0

    /// Fraction 0…1 of the rotation for a measure value.
    ///
    /// - `valueRemainder` ≠ 0 ("use a remainder instead of the actual measured value"): the value modulo
    ///   |ValueRemainder| divided by |ValueRemainder| — with a Time measure (seconds) and ValueRemainder=43200 /
    ///   3600 / 60 this is the position of the hour / minute / second hand. MinValue and MaxValue are not used in
    ///   this mode (the Time measure's number is a timestamp, not a percentage). Judgment calls (manual only says
    ///   "the % modulo mathematical operator"): a floating-point modulo, so fractional values keep moving
    ///   smoothly; negative values wrap into 0…R instead of running backwards; a negative ValueRemainder acts
    ///   like its absolute value.
    /// - otherwise the percentual value (value − MinValue) / (MaxValue − MinValue), clamped to 0…1; an empty or
    ///   non-finite range gives 0 (same rule as `Measure.relativeValue`).
    public static func fraction(value: Double, minValue: Double, maxValue: Double, valueRemainder: Double) -> Double {
        guard value.isFinite else { return 0 }
        let r = abs(valueRemainder)
        if r > 0, r.isFinite {
            var m = fmod(value, r)
            if m < 0 { m += r }
            let f = m / r
            return f.isFinite ? min(max(f, 0), 1) : 0
        }
        let range = maxValue - minValue
        guard range != 0, range.isFinite else { return 0 }
        let f = (value - minValue) / range
        return f.isFinite ? min(max(f, 0), 1) : 0
    }

    /// Angle for a fraction: `StartAngle + RotationAngle × fraction`; just `StartAngle` when ControlAngle=0
    /// ("the measure does not control the angle … RotationAngle is ignored"). Non-finite results give 0.
    public static func angle(startAngle: Double, rotationAngle: Double, fraction: Double,
                             controlAngle: Bool = true) -> Double {
        let a = controlAngle ? startAngle + rotationAngle * fraction : startAngle
        return a.isFinite ? a : 0
    }

    /// Point `radius` away from the center along `angle` (a negative radius lands on the opposite side).
    public static func point(centerX: Double, centerY: Double, radius: Double, angle: Double) -> (x: Double, y: Double) {
        (centerX + radius * cos(angle), centerY + radius * sin(angle))
    }

    /// Center of rotation of a round meter: the middle of its W×H box (without padding). With no W/H the box is
    /// empty and the center is the meter's X/Y — manual: "If the width and height are not defined, the center
    /// point is at the X and Y position of the meter".
    public static func center(of box: SkinRect) -> (x: Double, y: Double) {
        (box.x + box.width / 2, box.y + box.height / 2)
    }

    /// Clamps an option value into ±`maxExtent`; NaN becomes 0.
    static func extent(_ v: Double) -> Double {
        v.isNaN ? 0 : min(max(v, -maxExtent), maxExtent)
    }

    /// Affine transform `x' = a·x + c·y + tx`, `y' = b·x + d·y + ty` (same layout as CGAffineTransform).
    public struct Transform: Equatable {
        public var a: Double
        public var b: Double
        public var c: Double
        public var d: Double
        public var tx: Double
        public var ty: Double

        public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.tx = tx
            self.ty = ty
        }

        public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
            (a * x + c * y + tx, b * x + d * y + ty)
        }
    }

    /// Rotator transform from image pixel coordinates (top-left origin) to skin coordinates: the image point
    /// (offsetX, offsetY) — "the center of rotation" — lands on the meter's center and the image is turned by
    /// `angle` around it. At angle 0 the image is drawn upright (so a hand image should point right).
    public static func rotatorTransform(centerX: Double, centerY: Double, angle: Double,
                                        offsetX: Double, offsetY: Double) -> Transform {
        let cosA = cos(angle), sinA = sin(angle)
        return Transform(a: cosA, b: sinA, c: -sinA, d: cosA,
                         tx: centerX - (cosA * offsetX - sinA * offsetY),
                         ty: centerY - (sinA * offsetX + cosA * offsetY))
    }

    /// Geometry of a Roundline meter for one frame.
    public static func roundlineShape(centerX: Double, centerY: Double, fraction: Double,
                                      options o: RoundlineMeter.Options) -> RoundlineMeter.Shape {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        // ControlStart: "will range from LineStart to (LineStart + StartShift)"; ControlLength likewise for
        // LineLength / LengthShift. Both lengths are measured from the center of rotation.
        let start = extent(o.lineStart + (o.controlStart ? o.startShift * f : 0))
        let end = extent(o.lineLength + (o.controlLength ? o.lengthShift * f : 0))

        if o.solid {
            // "Fill the meter with LineColor from StartAngle to the current MeasureName percentage value": a pie
            // (LineStart 0) or ring sector between the two radii, both evaluated at the current percentage.
            // Judgment calls: radii are ordered and clamped at 0; with ControlAngle=0 the angle is not driven by
            // the measure and RotationAngle is ignored, so the whole circle is filled (the only useful reading —
            // a zero-width sweep would draw nothing).
            let sweep = o.controlAngle ? o.rotationAngle * f : fullCircle
            let inner = max(min(start, end), 0)
            let outer = max(max(start, end), 0)
            guard outer > inner, sweep != 0, sweep.isFinite, o.startAngle.isFinite else { return .none }
            return .sector(centerX: centerX, centerY: centerY, innerRadius: inner, outerRadius: outer,
                           startAngle: o.startAngle, sweep: sweep)
        }

        let a = angle(startAngle: o.startAngle, rotationAngle: o.rotationAngle, fraction: f,
                      controlAngle: o.controlAngle)
        guard o.lineWidth > 0, start != end else { return .none }
        let p1 = point(centerX: centerX, centerY: centerY, radius: start, angle: a)
        let p2 = point(centerX: centerX, centerY: centerY, radius: end, angle: a)
        return .line(x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y, width: o.lineWidth)
    }
}

/// `Meter=Roundline`: a line or solid fill that rotates around the center of the meter with a measure value.
public final class RoundlineMeter: Meter {
    /// Parsed Roundline options (all lengths in pixels, angles in radians).
    public struct Options: Equatable {
        public var startAngle = 0.0
        /// Manual lists no default for Roundline; we use the Rotator's documented default, a full turn (2π).
        public var rotationAngle = RoundMeterMath.fullCircle
        public var lineStart = 0.0
        /// No documented default; 0 (nothing drawn until LineLength is set).
        public var lineLength = 0.0
        public var lineWidth = 1.0
        public var lineColor = RGBA.white
        public var solid = false
        public var controlAngle = true
        public var controlStart = false
        public var startShift = 0.0
        public var controlLength = false
        public var lengthShift = 0.0
        /// 0 = off.
        public var valueRemainder = 0.0

        public init() {}
    }

    /// What to draw.
    public enum Shape: Equatable {
        case none
        /// Straight line (flat caps) of `width` pixels.
        case line(x1: Double, y1: Double, x2: Double, y2: Double, width: Double)
        /// Pie (innerRadius 0) or ring sector from `startAngle` sweeping `sweep` radians (signed; positive is
        /// clockwise on screen). |sweep| ≥ 2π is a full disc / ring.
        case sector(centerX: Double, centerY: Double, innerRadius: Double, outerRadius: Double,
                    startAngle: Double, sweep: Double)
    }

    public private(set) var options = Options()
    /// 0…1 rotation fraction from the bound measure (1 when no measure is bound — manual: "If MeasureName is not
    /// specified, then the value is in effect always 100%").
    public private(set) var fraction = 1.0

    public var lineColor: RGBA { options.lineColor }

    /// Center of rotation (middle of W×H, or X/Y when no size is given).
    public var center: (x: Double, y: Double) { RoundMeterMath.center(of: contentFrame) }

    /// Current angle of the line in radians.
    public var angle: Double {
        RoundMeterMath.angle(startAngle: options.startAngle, rotationAngle: options.rotationAngle,
                             fraction: fraction, controlAngle: options.controlAngle)
    }

    /// Geometry to draw now (the frame is final once the skin has laid out).
    public var shape: Shape {
        let c = center
        return RoundMeterMath.roundlineShape(centerX: c.x, centerY: c.y, fraction: fraction, options: options)
    }

    public override func readMeterOptions() {
        var o = Options()
        o.startAngle = finite(double("StartAngle", 0), 0)
        o.rotationAngle = finite(double("RotationAngle", RoundMeterMath.fullCircle), RoundMeterMath.fullCircle)
        o.lineStart = RoundMeterMath.extent(double("LineStart", 0))
        o.lineLength = RoundMeterMath.extent(double("LineLength", 0))
        o.lineWidth = min(max(finite(double("LineWidth", 1), 1), 0), RoundMeterMath.maxExtent)
        o.lineColor = color("LineColor", .white)
        o.solid = bool("Solid", false)
        o.controlAngle = bool("ControlAngle", true)
        o.controlStart = bool("ControlStart", false)
        o.startShift = RoundMeterMath.extent(double("StartShift", 0))
        o.controlLength = bool("ControlLength", false)
        o.lengthShift = RoundMeterMath.extent(double("LengthShift", 0))
        o.valueRemainder = finite(double("ValueRemainder", 0), 0)
        options = o
        updateFraction()
    }

    public override func updateMeter() {
        updateFraction()
    }

    private func updateFraction() {
        guard let m = measureSlots.first ?? nil else {
            fraction = 1
            return
        }
        fraction = RoundMeterMath.fraction(value: m.value, minValue: m.minValue, maxValue: m.maxValue,
                                           valueRemainder: options.valueRemainder)
    }

    private func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
}
