/// The platform symbol's color rendering policy, separate from a file image's processing options.
public enum IconColors: String, CaseIterable, Equatable, Sendable {
    case monochrome, hierarchical, multicolor
}

/// A complete symbol request. The host resolves the font and symbol; Core retains no platform resources.
/// TextStyle uses the same font units as text drawing, including its resolved foreground color.
public struct IconRequest: Equatable, Sendable {
    public var name: String
    public var style: TextStyle
    public var colors: IconColors
    public var appearance: AppearanceStamp
    /// Native symbol metrics include display-scale alignment; do not reuse a measurement across destinations.
    public var scale: Double

    public init(name: String, style: TextStyle, colors: IconColors, appearance: AppearanceStamp, scale: Double = 1) {
        self.name = name; self.style = style; self.colors = colors; self.appearance = appearance
        self.scale = scale
    }
}

/// A measured symbol at its final glyph rectangle, which may extend beyond its layout box with an own font.
/// The recipe remains a typed symbol request; it is not a file path or a legacy sf URI.
public struct IconDraw: Equatable, Sendable {
    public var request: IconRequest
    public var naturalSize: SkinSize
    public var contentFrame: SkinRect

    public init(request: IconRequest, naturalSize: SkinSize, contentFrame: SkinRect) {
        self.request = request; self.naturalSize = naturalSize; self.contentFrame = contentFrame
    }
}
