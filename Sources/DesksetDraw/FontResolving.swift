import CoreGraphics
import CoreText
import DesksetCore

/// The platform's font registration and resolution service, injected into text layout.
/// A resolver returns all the drawing and metric adjustments along with the Core Text font.
public protocol FontResolving {
    /// Changes whenever registered or available fonts change, invalidating layouts made with an earlier value.
    var generation: Int { get }
    func registerFolder(_ folder: String)
    func resolve(_ request: FontRequest) -> ResolvedFont
}

/// A font request. `size` is in skin points (pixels), after the Rainmeter point-size conversion.
public struct FontRequest: Hashable {
    public var face: String
    public var size: CGFloat
    /// Explicit `FontWeight` / inline `Weight`.
    public var weight: Int?
    /// `StringStyle=Bold` (700 unless an explicit weight is given).
    public var bold: Bool
    public var italic: Bool
    public var oblique: Bool
    /// Inline `Stretch` 1…9 (5 = normal).
    public var stretch: Int?
    /// Inline `Typography` features (OpenType tag, value).
    public var features: [FontFeature]

    public init(face: String, size: CGFloat, weight: Int? = nil, bold: Bool = false, italic: Bool = false,
                oblique: Bool = false, stretch: Int? = nil, features: [FontFeature] = []) {
        self.face = face
        self.size = size
        self.weight = weight
        self.bold = bold
        self.italic = italic
        self.oblique = oblique
        self.stretch = stretch
        self.features = features
    }

    public init(style: TextStyle) {
        self.init(face: style.fontFace, size: CGFloat(max(TextStyle.pixelSize(points: style.fontSize), 0.01)),
                  weight: style.fontWeight, bold: style.bold, italic: style.italic)
    }
}

public struct FontFeature: Hashable {
    public var tag: String
    public var value: Int

    public init(tag: String, value: Int) {
        self.tag = tag
        self.value = value
    }
}

public struct ResolvedFont {
    public let font: CTFont
    /// Draw with an additional stroke to simulate bold (the family has no heavy enough member).
    public let syntheticBold: Bool
    /// Characters to replace before shaping (Marlett, which has no Mac equivalent).
    public let characterMap: [UInt16: UInt16]?
    /// Horizontal shear for simulated italic / oblique (0 = upright). Applied through the text matrix,
    /// because CTRunDraw ignores a font's own matrix.
    public let slant: CGFloat
    /// Line metrics (pixels) of a substituted font; nil when the font is used as is.
    public let lineMetrics: FontLineMetrics?

    public init(font: CTFont, syntheticBold: Bool, characterMap: [UInt16: UInt16]?, slant: CGFloat,
                lineMetrics: FontLineMetrics?) {
        self.font = font
        self.syntheticBold = syntheticBold
        self.characterMap = characterMap
        self.slant = slant
        self.lineMetrics = lineMetrics
    }
}

public struct FontLineMetrics: Hashable {
    public var ascent: CGFloat
    public var descent: CGFloat
    public var leading: CGFloat

    public init(ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
    }
}
