import Foundation

/// How different two colors look: CIEDE2000 (ΔE₀₀) between sRGB colors, through CIE L*a*b* under D65. Around 1 is
/// the smallest difference people see side by side; under about 20 two colors read as "the same color" at a glance —
/// the Studio's threshold for an outline that must not look like part of the widget.
public enum ColorDifference {
    public struct Lab: Equatable {
        public var l: Double
        public var a: Double
        public var b: Double

        public init(_ l: Double, _ a: Double, _ b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }
    }

    /// An sRGB color (alpha ignored) in CIE L*a*b* (D65 white).
    public static func lab(_ c: RGBA) -> Lab {
        func linear(_ v: Double) -> Double {
            let s = min(max(v / 255, 0), 1)
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return Lab(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// ΔE₀₀ between two sRGB colors.
    public static func deltaE2000(_ a: RGBA, _ b: RGBA) -> Double { deltaE2000(lab(a), lab(b)) }

    /// ΔE₀₀ between two L*a*b* colors (Sharma, Wu and Dalal's formulation, kL = kC = kH = 1).
    public static func deltaE2000(_ x: Lab, _ y: Lab) -> Double {
        let rad = Double.pi / 180
        let c1 = hypot(x.a, x.b), c2 = hypot(y.a, y.b)
        let cMean = (c1 + c2) / 2
        let c7 = pow(cMean, 7)
        let g = 0.5 * (1 - sqrt(c7 / (c7 + pow(25, 7))))
        let a1 = (1 + g) * x.a, a2 = (1 + g) * y.a
        let cp1 = hypot(a1, x.b), cp2 = hypot(a2, y.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let hp1 = hue(x.b, a1), hp2 = hue(y.b, a2)
        let dL = y.l - x.l
        let dC = cp2 - cp1
        var dh: Double
        if cp1 * cp2 == 0 { dh = 0 } else {
            dh = hp2 - hp1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * sqrt(cp1 * cp2) * sin(dh / 2 * rad)
        let lMean = (x.l + y.l) / 2
        let cpMean = (cp1 + cp2) / 2
        var hMean: Double
        if cp1 * cp2 == 0 { hMean = hp1 + hp2 } else if abs(hp1 - hp2) <= 180 { hMean = (hp1 + hp2) / 2 } else {
            hMean = hp1 + hp2 < 360 ? (hp1 + hp2 + 360) / 2 : (hp1 + hp2 - 360) / 2
        }
        let t = 1 - 0.17 * cos((hMean - 30) * rad) + 0.24 * cos(2 * hMean * rad) + 0.32 * cos((3 * hMean + 6) * rad)
            - 0.20 * cos((4 * hMean - 63) * rad)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let cp7 = pow(cpMean, 7)
        let rc = 2 * sqrt(cp7 / (cp7 + pow(25, 7)))
        let l50 = pow(lMean - 50, 2)
        let sl = 1 + 0.015 * l50 / sqrt(20 + l50)
        let sc = 1 + 0.045 * cpMean
        let sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * rad) * rc
        return sqrt(pow(dL / sl, 2) + pow(dC / sc, 2) + pow(dH / sh, 2) + rt * (dC / sc) * (dH / sh))
    }
}

/// The ink of "what it draws": the dashed frames the canvas draws around the parts a pointed-at color, color row or
/// data item paints. They must never look like part of the widget (a thin blue ring next to a blue ring reads as "a
/// stroke was added"): the accent color, unless a color of the widget is within ΔE₀₀ < 20 of it — then graphite (near
/// white in dark mode) with an inverted halo, for the whole widget.
public enum StudioOutlineInk: Equatable {
    case accent
    case graphite

    /// Below this ΔE₀₀ a widget's color reads as the accent.
    public static let threshold = 20.0

    /// The ink for a widget whose colors are `colors` (nearly transparent ones do not count), under `accent`.
    public static func choose(accent: RGBA, colors: [RGBA], threshold: Double = StudioOutlineInk.threshold)
        -> StudioOutlineInk {
        let close = colors.contains { $0.a >= 26 && ColorDifference.deltaE2000($0, accent) < threshold }
        return close ? .graphite : .accent
    }
}

/// Which parts the first click on the canvas passes over: a part that draws nothing — an area laid over others only to
/// catch the pointer (`SolidColor=0,0,0,1`), an empty text, an image without a picture — does not take the first click
/// (the design's refinement of "a click selects the outermost part": a container that only arranges does not block
/// it). The rule is conservative: a part that may draw something takes the click.
public enum StudioHitRule {
    /// At most this alpha counts as invisible (`SolidColor=0,0,0,1` is the common hit area).
    public static let invisibleAlpha = 2.0

    /// Whether `m` draws anything that can be seen (false only when sure it draws nothing).
    public static func drawsSomething(_ m: Meter) -> Bool {
        if m.hidden { return false }
        if m.solidColor.a > invisibleAlpha || (m.solidColor2?.a ?? 0) > invisibleAlpha { return true }
        if m.bevelType != 0 { return true }
        if m.glass != nil { return true }
        switch m {
        case let s as StringMeter:
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return false }
            if s.style.color.a > invisibleAlpha { return true }
            return s.style.effect != .none && s.style.effectColor.a > invisibleAlpha
        case let i as ImageMeter:
            guard let path = i.imagePath, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return i.imageAlpha > invisibleAlpha
        case let shape as ShapeMeter:
            return shape.shapes.contains { item in
                let alpha: (ShapePaint) -> Bool = { paint in
                    switch paint {
                    case .none: return false
                    case .color(let c): return c.a > invisibleAlpha
                    default: return paint.isVisible
                    }
                }
                return alpha(item.fill) || (item.strokeStyle.width > 0 && alpha(item.stroke))
            }
        default:
            return true
        }
    }

    /// The part a first click at a point takes, from the parts under it front first (`hits`): the frontmost one that
    /// draws something; when none does, the innermost (the smallest) of them — never nothing when something is there.
    public static func pick(_ hits: [Meter]) -> Meter? {
        if let drawn = hits.first(where: drawsSomething) { return drawn }
        return hits.enumerated().min { a, b in
            let sa = a.element.frame.width * a.element.frame.height, sb = b.element.frame.width * b.element.frame.height
            return sa != sb ? sa < sb : a.offset < b.offset
        }?.element
    }
}
