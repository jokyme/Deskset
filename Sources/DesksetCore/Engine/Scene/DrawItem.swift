/// A solid fill or the existing two-color, angle-based background gradient.
public struct Paint: Equatable, Sendable {
    public var color: RGBA
    public var secondColor: RGBA?
    public var angle: Double

    public init(color: RGBA, secondColor: RGBA? = nil, angle: Double = 0) {
        self.color = color
        self.secondColor = secondColor
        self.angle = angle
    }
}

/// A raised or sunken one-point bevel; nil colors use the renderer's white and black defaults.
public struct BevelDraw: Equatable, Sendable {
    public var type: Int
    public var light: RGBA?
    public var dark: RGBA?

    public init(type: Int, light: RGBA? = nil, dark: RGBA? = nil) {
        self.type = type
        self.light = light
        self.dark = dark
    }
}

public enum GraphDraw: Equatable, Sendable {
    case line(LineDraw)
    case histogram(HistogramDraw)
}

/// A drawing recipe in skin coordinates. Every payload is a value; preparing and executing it never needs a
/// live skin, meter or measure. Transformed groups also isolate graphics state when the transform is identity.
public indirect enum DrawItem: Equatable, Sendable {
    case fill(SkinRect, Paint)
    case bevel(SkinRect, BevelDraw)
    case text(TextDraw)
    case image(ImageDraw)
    case icon(IconDraw)
    case shape(ShapeDraw)
    case bar(BarDraw)
    case graph(GraphDraw)
    case roundline(RoundlineDraw)
    case rotator(RotatorDraw)
    case sprite(SpriteDraw)
    case glass(GlassRegion)
    case transformed(ShapeTransform, [DrawItem])
    case antialias(Bool, [DrawItem])
    case container(clip: SkinRect, mask: [DrawItem], content: [DrawItem])
}
