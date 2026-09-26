import Foundation

/// A Fill / Stroke modifier before it is placed on a shape (gradients need the shape's bounds).
enum ShapePaintSpec: Equatable {
    case none
    case color(RGBA)
    case linear(angle: Double, stops: [ShapeGradientStop], linearGamma: Bool)
    /// `CenterX, CenterY[, OffsetX, OffsetY[, RadiusX[, RadiusY]]]` (nil = default).
    case radial(parameters: [Double?], stops: [ShapeGradientStop], linearGamma: Bool)

    /// Places the paint on a shape whose (untransformed) bounds are `bounds`.
    func resolve(in bounds: ShapeRect) -> ShapePaint {
        switch self {
        case .none:
            return .none
        case .color(let c):
            return .color(c)
        case .linear(let angle, let stops, let gamma):
            let (start, end) = ShapeGradients.linearEndpoints(angle: angle, bounds: bounds)
            return .linearGradient(ShapeLinearGradient(start: start, end: end,
                                                       stops: ShapeGradients.normalizedStops(stops, linearGamma: gamma),
                                                       linearGamma: gamma))
        case .radial(let p, let stops, let gamma):
            return .radialGradient(ShapeGradients.radial(p, stops: stops, linearGamma: gamma, bounds: bounds))
        }
    }
}

/// Gradient geometry (manual, "Defining Gradients").
public enum ShapeGradients {
    static let maxStops = 256

    /// LinearGradient: "The Angle is defined as any number of degrees, with 0 or 360 starting directly to the
    /// right and rotating clockwise": 0 runs right → left, 90 bottom → top, 180 left → right, 270 top → bottom.
    ///
    /// Judgment call (the manual does not say where the gradient starts and ends): the gradient line passes
    /// through the center of the shape's bounds and is just long enough for the corners to reach positions 0 and 1
    /// (as CSS does), so every angle spans the whole shape.
    public static func linearEndpoints(angle: Double, bounds: ShapeRect) -> (start: ShapePoint, end: ShapePoint) {
        let r = angle * .pi / 180
        let dir = ShapePoint(cos(r), sin(r))
        let half = max((abs(bounds.width * dir.x) + abs(bounds.height * dir.y)) / 2, 1e-3)
        let c = bounds.center
        return (c + dir * half, c - dir * half)
    }

    /// RadialGradient: `CenterX, CenterY` offset the gradient ellipse's center from the center of the shape;
    /// `OffsetX, OffsetY` move the gradient origin (position 0) away from that center; `RadiusX, RadiusY` size the
    /// ellipse (position 1).
    ///
    /// Judgment calls: missing radii default to half the shape's width / height (the ellipse fills the bounds);
    /// a RadiusX without RadiusY is a circle. An origin outside the ellipse is pulled just inside it.
    static func radial(_ p: [Double?], stops: [ShapeGradientStop], linearGamma: Bool, bounds: ShapeRect) -> ShapeRadialGradient {
        func v(_ i: Int) -> Double? { i < p.count ? p[i] : nil }
        let center = bounds.center + ShapePoint(v(0) ?? 0, v(1) ?? 0)
        let rx = abs(v(4) ?? bounds.width / 2)
        let ry = abs(v(5) ?? (v(4) != nil ? rx : bounds.height / 2))
        var offset = ShapePoint(v(2) ?? 0, v(3) ?? 0)
        if rx > 0, ry > 0 {
            let reach = ShapePoint(offset.x / rx, offset.y / ry).length
            if reach > 0.999 { offset = offset * (0.999 / reach) }
        }
        return ShapeRadialGradient(center: center, origin: center + offset, radiusX: rx, radiusY: ry,
                                   stops: normalizedStops(stops, linearGamma: linearGamma), linearGamma: linearGamma)
    }

    /// Sorts the stops and fits them into 0…1. Manual: "Any defined color with a percentage outside the 0.0 to
    /// 1.0 range will not directly be displayed, but will still affect the interpolation of the gradient" — so the
    /// colors at 0 and 1 are interpolated from the stops around them. Before the first stop and after the last one
    /// the end colors continue. The result has at least one stop unless `stops` is empty.
    public static func normalizedStops(_ stops: [ShapeGradientStop], linearGamma: Bool) -> [ShapeGradientStop] {
        let sorted = stops.enumerated()
            .filter { $0.element.position.isFinite }
            .sorted { $0.element.position != $1.element.position ? $0.element.position < $1.element.position : $0.offset < $1.offset }
            .map(\.element)
        guard let first = sorted.first, let last = sorted.last else { return [] }
        if sorted.count == 1 { return [ShapeGradientStop(color: first.color, position: 0)] }
        func color(at t: Double) -> RGBA {
            if t <= first.position { return first.color }
            if t >= last.position { return last.color }
            for i in 1..<sorted.count where sorted[i].position >= t {
                let a = sorted[i - 1], b = sorted[i]
                let span = b.position - a.position
                return span > 0 ? mix(a.color, b.color, (t - a.position) / span, linearGamma: linearGamma) : b.color
            }
            return last.color
        }
        var result = [ShapeGradientStop(color: color(at: 0), position: 0)]
        result += sorted.filter { $0.position > 0 && $0.position < 1 }
        result.append(ShapeGradientStop(color: color(at: 1), position: 1))
        return result
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Double, linearGamma: Bool) -> RGBA {
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        guard linearGamma else {
            return RGBA(r: lerp(a.r, b.r), g: lerp(a.g, b.g), b: lerp(a.b, b.b), a: lerp(a.a, b.a))
        }
        func toLinear(_ c: Double) -> Double {
            let v = c / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func fromLinear(_ v: Double) -> Double {
            let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
            return (s * 255).clamped(0, 255)
        }
        return RGBA(r: fromLinear(lerp(toLinear(a.r), toLinear(b.r))), g: fromLinear(lerp(toLinear(a.g), toLinear(b.g))),
                    b: fromLinear(lerp(toLinear(a.b), toLinear(b.b))), a: lerp(a.a, b.a))
    }
}
