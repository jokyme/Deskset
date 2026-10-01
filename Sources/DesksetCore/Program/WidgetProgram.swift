/// The shared, typed program consumed without an INI file or a live Skin. This first executable slice has
/// proposal-based stacks, solid shape paints, local images, scalar text bindings and root startup assignments through the shared executor.
public struct WidgetProgram: Equatable, Sendable {
    public let name: String
    public let root: ProgramElement
    public let declarations: [ProgramDeclaration]
    public let onLoad: [ProgramAssignment]

    public init(name: String, root: ProgramElement, declarations: [ProgramDeclaration] = [],
                onLoad: [ProgramAssignment] = []) {
        self.name = name
        self.root = root
        self.declarations = declarations
        self.onLoad = onLoad
    }
}

public enum ProgramLength: Equatable, Sendable {
    case fit
    case fill
    case fixed(Double)
}

/// Filled curves in the final content box. Circle is centered and uses the smaller box dimension.
public enum ProgramShapeKind: Equatable, Sendable {
    case circle, ellipse, capsule
}

/// A solid, centered outline in points. The producer decides whether the shape also has a fill.
public struct ProgramShapeStroke: Equatable, Sendable {
    public let color: ProgramColor
    public let width: Double

    public init(color: ProgramColor, width: Double) { self.color = color; self.width = width }
}

/// A uniform Rectangle radius, resolved against the final content box after layout.
public enum ProgramCornerRadius: Equatable, Sendable {
    case points(Double), full
}

/// The picture fills its final content box. ImageSource resolution and decoding remain with the host.
public enum ProgramImageMode: Equatable, Sendable { case fit, fill, stretch, tile }

public struct ProgramImage: Equatable, Sendable {
    public let source: String
    public let mode: ProgramImageMode
    public init(source: String, mode: ProgramImageMode = .fit) { self.source = source; self.mode = mode }
}

/// One approved, upright image input. These are scene values, not a graphics object or a retained resource owner.
public struct ProgramImageResource: Equatable, Sendable {
    public let path: String
    public let naturalSize: SkinSize
    public let stamp: ImageStamp
    public init(path: String, naturalSize: SkinSize, stamp: ImageStamp) {
        self.path = path; self.naturalSize = naturalSize; self.stamp = stamp
    }
}

/// A box in points. Child order is drawing order; identity is assigned by the producer, never by a syntax version.
public struct ProgramElement: Equatable, Sendable {
    public indirect enum Content: Equatable, Sendable {
        case text(ProgramText)
        case image(ProgramImage)
        /// An unrounded solid rectangle in its content box. Nonfixed dimensions need an explicit ideal size.
        case rectangle(fill: ProgramColor)
        /// A solid curved shape. Like Rectangle, nonfixed dimensions require the producer's ideal size.
        case shape(kind: ProgramShapeKind, fill: ProgramColor)
        case column(spacing: Double, align: HorizontalTextAlign, children: [ProgramElement])
        case row(spacing: Double, align: VerticalTextAlign, children: [ProgramElement])
    }

    public let id: ElementID
    public let content: Content
    public let width: ProgramLength
    public let height: ProgramLength
    public let minWidth: Double
    public let maxWidth: Double?
    public let minHeight: Double
    public let maxHeight: Double?
    /// Intrinsic content size for a leaf without native measurement, supplied by its producer's catalog.
    public let idealSize: SkinSize?
    public let padding: SkinInsets
    /// Hiding keeps layout space. This is not Rainmeter's collapsed visibility.
    public let hidden: Bool
    /// Valid only for shape content. A zero-width or transparent stroke paints nothing.
    public let stroke: ProgramShapeStroke?
    /// Valid only for Rectangle content. Other box decorations are not implied.
    public let cornerRadius: ProgramCornerRadius?

    public init(id: ElementID, content: Content, width: ProgramLength = .fit, height: ProgramLength = .fit,
                padding: SkinInsets = .zero, hidden: Bool = false,
                minWidth: Double = 0, maxWidth: Double? = nil, minHeight: Double = 0, maxHeight: Double? = nil,
                idealSize: SkinSize? = nil, stroke: ProgramShapeStroke? = nil, cornerRadius: ProgramCornerRadius? = nil) {
        self.id = id
        self.content = content
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.idealSize = idealSize
        self.padding = padding
        self.hidden = hidden
        self.stroke = stroke
        self.cornerRadius = cornerRadius
    }
}

/// Appearance-dependent colors stay typed until scene projection; no variable substitution is involved.
public enum ProgramColor: Equatable, Sendable {
    case literal(RGBA)
    case text, dim, faint, accent, separator

    func resolved(in appearance: SkinAppearance) -> RGBA {
        switch self {
        case .literal(let color): return color
        case .text: return appearance.labelColor
        case .dim: return appearance.secondaryLabelColor
        case .faint: return appearance.tertiaryLabelColor
        case .accent: return appearance.accentColor
        case .separator: return appearance.separatorColor
        }
    }
}

public struct ProgramText: Equatable, Sendable {
    public let value: ProgramExpression
    public let fontFamily: String
    /// Desk/program points, not the String meter's 96-DPI font units.
    public let fontSize: Double
    public let fontWeight: Int?
    public let italic: Bool
    public let color: ProgramColor
    public let align: HorizontalTextAlign

    public init(_ text: String, fontFamily: String = "System", fontSize: Double = 13, fontWeight: Int? = 400,
                italic: Bool = false, color: ProgramColor = .text, align: HorizontalTextAlign = .center) {
        self.init(value: .string(text), fontFamily: fontFamily, fontSize: fontSize, fontWeight: fontWeight,
                  italic: italic, color: color, align: align)
    }

    public init(value: ProgramExpression, fontFamily: String = "System", fontSize: Double = 13, fontWeight: Int? = 400,
                italic: Bool = false, color: ProgramColor = .text, align: HorizontalTextAlign = .center) {
        self.value = value
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.italic = italic
        self.color = color
        self.align = align
    }

    /// Adapt once at the existing renderer boundary. Measuring and TextDraw receive this same value.
    func drawingStyle(in appearance: SkinAppearance, wrap: Bool) -> TextStyle {
        var style = TextStyle()
        style.fontFace = fontFamily
        style.fontSize = fontSize * (72.0 / 96.0)
        style.fontWeight = fontWeight
        style.italic = italic
        style.color = color.resolved(in: appearance)
        style.horizontalAlign = align
        style.verticalAlign = .center
        style.accurateText = true
        style.antiAlias = true
        style.trailingSpaces = true
        style.wrap = wrap
        return style
    }
}

/// Current shared-program bounds match the language's default element, block and text budgets. A producer may
/// enforce a smaller budget; the runtime always guards direct programs too.
public enum ProgramLimits {
    public static let maximumElements = 5_000
    public static let maximumDepth = 64
    public static let maximumTextLength = 32_768
    public static let maximumExpressions = 5_000
    public static let maximumExpressionDepth = 128
}
