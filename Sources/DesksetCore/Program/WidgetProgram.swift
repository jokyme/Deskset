/// The shared, typed program consumed without an INI file or a live Skin. This first executable slice has
/// rigid stacks, scalar text bindings and root startup assignments through the shared action executor.
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
    case fixed(Double)
}

/// A box in points. Child order is drawing order; identity is assigned by the producer, never by a syntax version.
public struct ProgramElement: Equatable, Sendable {
    public indirect enum Content: Equatable, Sendable {
        case text(ProgramText)
        case column(spacing: Double, align: HorizontalTextAlign, children: [ProgramElement])
        case row(spacing: Double, align: VerticalTextAlign, children: [ProgramElement])
    }

    public let id: ElementID
    public let content: Content
    public let width: ProgramLength
    public let height: ProgramLength
    public let padding: SkinInsets
    /// Hiding keeps layout space. This is not Rainmeter's collapsed visibility.
    public let hidden: Bool

    public init(id: ElementID, content: Content, width: ProgramLength = .fit, height: ProgramLength = .fit,
                padding: SkinInsets = .zero, hidden: Bool = false) {
        self.id = id
        self.content = content
        self.width = width
        self.height = height
        self.padding = padding
        self.hidden = hidden
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
