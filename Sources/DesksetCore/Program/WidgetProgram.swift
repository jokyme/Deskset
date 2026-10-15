/// The shared, typed program consumed without an INI file or a live Skin. Proposal-based stacks and Freeform
/// arrange shapes, images, scalar text and dynamic progress/gauges, with startup/user click actions through the shared executor.
public struct WidgetProgram: Equatable, Sendable {
    public let name: String
    public let root: ProgramElement
    public let declarations: [ProgramDeclaration]
    public let onLoad: [ProgramAssignment]
    public let size: ProgramWidgetSize
    public let translations: ProgramTranslations
    public let nameKey: String?
    public let options: [ProgramOptionNode]

    public init(name: String, root: ProgramElement, declarations: [ProgramDeclaration] = [],
                onLoad: [ProgramAssignment] = [], size: ProgramWidgetSize = .fit,
                translations: ProgramTranslations = ProgramTranslations(), nameKey: String? = nil,
                options: [ProgramOptionNode] = []) {
        self.name = name
        self.root = root
        self.declarations = declarations
        self.onLoad = onLoad
        self.size = size
        self.translations = translations
        self.nameKey = nameKey
        self.options = options
    }

    /// Metadata can be displayed on Main from the immutable program, without accessing its runtime owner.
    public func displayName(language: String?) -> String {
        guard let key = nameKey, let pattern = translations.pattern(for: key, language: language),
              pattern.count <= ProgramLimits.maximumExpressions else { return name }
        var result = "", length = 0
        for part in pattern {
            guard case .text(let text) = part,
                  text.utf16.count <= ProgramLimits.maximumTextLength - length else { return name }
            length += text.utf16.count
            result += text
        }
        return result
    }
}

public enum ProgramSizePreset: String, CaseIterable, Equatable, Sendable { case small, medium, large }

/// Preset dimensions are supplied by the producer's checked catalog, in points.
public enum ProgramWidgetSize: Equatable, Sendable {
    case fit
    case preset(ProgramSizePreset, size: SkinSize)
}

public enum ProgramDirection: String, CaseIterable, Equatable, Sendable { case right, left, up, down }

/// A dynamic bar. Its range remains separate from the value, and is resolved from the same projection inputs.
public struct ProgramProgress: Equatable, Sendable {
    public let value: ProgramExpression
    public let total: ProgramExpression?
    public let fills: ProgramDirection
    public let color: ProgramColor
    public let track: ProgramColor

    public init(value: ProgramExpression, total: ProgramExpression? = nil, fills: ProgramDirection = .right,
                color: ProgramColor = .accent, track: ProgramColor = .faint) {
        self.value = value; self.total = total; self.fills = fills; self.color = color; self.track = track
    }
}

public enum ProgramGaugeShape: String, CaseIterable, Equatable, Sendable { case ring, arc, pie, needle }

/// A radial value in its content box. Angles use canonical degrees clockwise from twelve o'clock; thickness is
/// in points. Nil geometry uses the shape's defaults, while expressions resolve in the same frame as the value.
public struct ProgramGauge: Equatable, Sendable {
    public let value: ProgramExpression
    public let total: ProgramExpression?
    public let shape: ProgramGaugeShape
    public let start: ProgramExpression?
    public let sweep: ProgramExpression?
    public let thickness: ProgramExpression?
    public let color: ProgramColor
    public let track: ProgramColor

    public init(value: ProgramExpression, total: ProgramExpression? = nil, shape: ProgramGaugeShape = .ring,
                start: ProgramExpression? = nil, sweep: ProgramExpression? = nil, thickness: ProgramExpression? = nil,
                color: ProgramColor = .accent, track: ProgramColor = .faint) {
        self.value = value; self.total = total; self.shape = shape
        self.start = start; self.sweep = sweep; self.thickness = thickness
        self.color = color; self.track = track
    }
}

public enum ProgramLength: Equatable, Sendable {
    case fit
    case fill
    case fixed(Double)
}

/// Nine positions within a box, shared by Freeform alignment and a positioned child's anchor.
public enum ProgramAlignment: String, CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
}

/// A static point in the parent Freeform's content coordinates. The anchor belongs to the child's entire box.
public struct ProgramPosition: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let anchor: ProgramAlignment

    public init(x: Double = 0, y: Double = 0, anchor: ProgramAlignment = .topLeft) {
        self.x = x; self.y = y; self.anchor = anchor
    }
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

/// A uniform box radius. Backgrounds and hits use the outer box, including padding; Rectangle content also
/// resolves this radius against its own content box. Rounding a container does not clip its children.
public enum ProgramCornerRadius: Equatable, Sendable {
    case points(Double), full
}

/// A box background selected from solid colors, native glass or no background. Native glass remains a region
/// in the element's drawing order, not transparent paint. Pictures and gradients are not represented here.
public indirect enum ProgramBackground: Equatable, Sendable {
    case color(ProgramColor)
    case glass(style: GlassStyle, tint: ProgramColor? = nil)
    case conditional(ProgramExpression, then: ProgramBackground?, otherwise: ProgramBackground?)
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

/// A live platform symbol. The resolved font includes inherited facets; hasOwnFont records whether an explicit
/// element/style font disables fixed-box fitting. Bold/italic alone and an inherited font leave fitting enabled.
public struct ProgramIcon: Equatable, Sendable {
    public let name: ProgramExpression
    public let fontFamily: String
    public let fontSize: Double
    public let fontWeight: Int?
    public let italic: Bool
    public let color: ProgramColor
    public let align: HorizontalTextAlign
    public let colors: IconColors
    public let fontSizeExpression: ProgramExpression?
    public let hasOwnFont: Bool

    public init(name: ProgramExpression, fontFamily: String = "System", fontSize: Double = 13,
                fontWeight: Int? = 400, italic: Bool = false, color: ProgramColor = .text,
                align: HorizontalTextAlign = .center, colors: IconColors = .monochrome,
                fontSizeExpression: ProgramExpression? = nil, hasOwnFont: Bool = false) {
        self.name = name; self.fontFamily = fontFamily; self.fontSize = fontSize; self.fontWeight = fontWeight
        self.italic = italic; self.color = color; self.align = align; self.colors = colors
        self.fontSizeExpression = fontSizeExpression; self.hasOwnFont = hasOwnFont
    }

    func drawingStyle(in appearance: SkinAppearance, colorInput: ProgramColorInput?, resolvedFontSize: Double?,
                      resolvedColor: RGBA? = nil) throws -> TextStyle {
        try ProgramText(value: name, fontFamily: fontFamily, fontSize: fontSize, fontWeight: fontWeight,
                        italic: italic, color: color, align: align).drawingStyle(in: appearance, colorInput: colorInput,
                            wrap: false, resolvedFontSize: resolvedFontSize, resolvedColor: resolvedColor)
    }
}

/// One ordered arm of a view-level if. All arms are validated, but only the selected body's elements exist.
public struct ProgramConditionalBranch: Equatable, Sendable {
    public let condition: ProgramExpression
    public let body: [ProgramElement]

    public init(condition: ProgramExpression, body: [ProgramElement]) {
        self.condition = condition; self.body = body
    }
}

/// A transparent child-list selection. The first true condition wins; missing counts as false at this boundary.
public struct ProgramConditional: Equatable, Sendable {
    public let branches: [ProgramConditionalBranch]
    public let otherwise: [ProgramElement]

    public init(branches: [ProgramConditionalBranch], otherwise: [ProgramElement] = []) {
        self.branches = branches; self.otherwise = otherwise
    }
}

/// Display-only bindings for a local tooltip. An explicit empty value still masks an ancestor's tooltip.
public struct ProgramTooltip: Equatable, Sendable {
    public let text: ProgramExpression
    public let title: ProgramExpression?

    public init(text: ProgramExpression, title: ProgramExpression? = nil) {
        self.text = text; self.title = title
    }
}

/// A menu command. Checked is presentation only; selecting an item runs only its explicit actions.
public struct ProgramMenuItem: Equatable, Sendable {
    public let title: ProgramExpression
    public let checked: ProgramExpression
    public let enabled: ProgramExpression
    public let actions: [ProgramAction]

    public init(title: ProgramExpression, checked: ProgramExpression = .boolean(false),
                enabled: ProgramExpression = .boolean(true), actions: [ProgramAction] = []) {
        self.title = title; self.checked = checked; self.enabled = enabled; self.actions = actions
    }
}

public struct ProgramMenuConditionalBranch: Equatable, Sendable {
    public let condition: ProgramExpression
    public let body: [ProgramMenuNode]

    public init(condition: ProgramExpression, body: [ProgramMenuNode]) {
        self.condition = condition; self.body = body
    }
}

public struct ProgramMenuConditional: Equatable, Sendable {
    public let branches: [ProgramMenuConditionalBranch]
    public let otherwise: [ProgramMenuNode]

    public init(branches: [ProgramMenuConditionalBranch], otherwise: [ProgramMenuNode] = []) {
        self.branches = branches; self.otherwise = otherwise
    }
}

/// Non-layout menu templates. Only the selected conditional body exists in an opened menu.
public indirect enum ProgramMenuNode: Equatable, Sendable {
    case item(ProgramMenuItem)
    case submenu(title: ProgramExpression, items: [ProgramMenuNode])
    case divider
    case conditional(ProgramMenuConditional)
}

/// A command's source path within one compiled owner's menu, independent of titles or selected row positions.
/// A conditional contributes its node index, then its branch index (otherwise = branches.count), then body indices.
public struct ProgramMenuItemID: Equatable, Hashable, Sendable {
    public let owner: ElementID
    public let path: [Int]

    public init(owner: ElementID, path: [Int]) { self.owner = owner; self.path = path }
}

/// An immutable menu opening. It carries no executable expressions or actions across to the native presenter.
public struct ProgramMenuSnapshot: Equatable, Sendable {
    public indirect enum Node: Equatable, Sendable {
        case item(id: ProgramMenuItemID, title: String, checked: Bool, enabled: Bool)
        case submenu(title: String, items: [Node])
        case divider
    }
    public let owner: ElementID
    public let sourceGeneration: UInt64
    public let items: [Node]

    public init(owner: ElementID, sourceGeneration: UInt64, items: [Node]) {
        self.owner = owner; self.sourceGeneration = sourceGeneration; self.items = items
    }
}

/// A box in points, or a transparent conditional child-list item. Child order is drawing order; identity is
/// assigned by the producer, never by a syntax version or the currently selected branch.
public struct ProgramElement: Equatable, Sendable {
    public indirect enum Content: Equatable, Sendable {
        case text(ProgramText)
        case image(ProgramImage)
        case icon(ProgramIcon)
        case progress(ProgramProgress)
        case gauge(ProgramGauge)
        /// Empty layout along the enclosing Row/Column's main axis; elsewhere it takes no space.
        case spacer(minimum: Double)
        /// An unrounded solid rectangle in its content box. Nonfixed dimensions need an explicit ideal size.
        case rectangle(fill: ProgramColor)
        /// A solid curved shape. Like Rectangle, nonfixed dimensions require the producer's ideal size.
        case shape(kind: ProgramShapeKind, fill: ProgramColor)
        case column(spacing: Double, align: HorizontalTextAlign, children: [ProgramElement])
        case row(spacing: Double, align: VerticalTextAlign, children: [ProgramElement])
        case freeform(align: ProgramAlignment, children: [ProgramElement])
        /// Structural only: every field except id/content must have its default value. It cannot be the root,
        /// owns no box, and splices the selected body into its actual parent without adding layout space.
        case conditional(ProgramConditional)
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
    /// Uniform outer-box rounding, also applied to Rectangle content. Nonzero Image rounding needs picture
    /// clipping and is not admitted yet; rounding a box never implicitly clips its children.
    public let cornerRadius: ProgramCornerRadius?
    public let background: ProgramBackground?
    /// A local assignment-only primary click handler. nil has no handler; an empty block still consumes the click.
    /// Supplying both handler forms is rejected by ProgramRuntime, including two empty blocks.
    public let onClick: [ProgramAssignment]?
    /// Ordered assignments and frozen host requests. Core never executes the external requests itself.
    public let onClickActions: [ProgramAction]?
    /// Secondary release actions. An empty block consumes the event just as an empty primary handler does.
    public let onRightClickActions: [ProgramAction]?
    /// Valid only on a direct Freeform child. nil uses the parent's alignment; negative coordinates are allowed.
    public let position: ProgramPosition?
    /// A display string for this element's accessibility label. Hidden labels are validated but not evaluated.
    public let voiceOver: ProgramExpression?
    /// Combined with hidden and ancestor visibility. A true condition hides paint and input while retaining layout.
    public let hiddenIf: ProgramExpression?
    /// Local display strings resolved only while effectively visible; they never participate in measurement.
    public let tooltip: ProgramTooltip?
    /// A local menu template, resolved on demand rather than during layout or the display clock.
    public let menu: [ProgramMenuNode]?

    public init(id: ElementID, content: Content, width: ProgramLength = .fit, height: ProgramLength = .fit,
                padding: SkinInsets = .zero, hidden: Bool = false,
                minWidth: Double = 0, maxWidth: Double? = nil, minHeight: Double = 0, maxHeight: Double? = nil,
                idealSize: SkinSize? = nil, stroke: ProgramShapeStroke? = nil, cornerRadius: ProgramCornerRadius? = nil,
                onClick: [ProgramAssignment]? = nil, onClickActions: [ProgramAction]? = nil,
                onRightClickActions: [ProgramAction]? = nil, position: ProgramPosition? = nil,
                background: ProgramBackground? = nil, voiceOver: ProgramExpression? = nil,
                hiddenIf: ProgramExpression? = nil, tooltip: ProgramTooltip? = nil, menu: [ProgramMenuNode]? = nil) {
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
        self.background = background
        self.onClick = onClick
        self.onClickActions = onClickActions
        self.onRightClickActions = onRightClickActions
        self.position = position
        self.voiceOver = voiceOver
        self.hiddenIf = hiddenIf
        self.tooltip = tooltip
        self.menu = menu
    }
}

/// The catalog's named colors. Platform hosts resolve them, not Core or a fixed RGB approximation.
public enum ProgramPaletteColor: String, CaseIterable, Hashable, Sendable {
    case accent, text, dim, faint, separator
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray
    case white, black, clear
}

/// One immutable platform palette for one projection. A supplied palette must contain every catalog color.
public struct ProgramColorInput: Equatable, Sendable {
    public let colors: [ProgramPaletteColor: RGBA]

    public init(colors: [ProgramPaletteColor: RGBA]) { self.colors = colors }

    func validate() throws {
        guard colors.count == ProgramPaletteColor.allCases.count,
              ProgramPaletteColor.allCases.allSatisfy({ key in
                  guard let color = colors[key] else { return false }
                  return [color.r, color.g, color.b, color.a].allSatisfy { $0.isFinite && (0...255).contains($0) }
              }) else { throw ProgramRuntimeError.invalidColorInput }
    }
}

/// Appearance-dependent colors stay typed until scene projection; no variable substitution is involved.
public enum ProgramColor: Equatable, Sendable {
    case literal(RGBA)
    case text, dim, faint, accent, separator
    case palette(ProgramPaletteColor)
    /// Producers lower precedence and inheritance into this lazy selection; only Bool expressions are admitted.
    indirect case conditional(ProgramExpression, then: ProgramColor, otherwise: ProgramColor)

    func resolved(in appearance: SkinAppearance, colorInput: ProgramColorInput?) throws -> RGBA {
        let key: ProgramPaletteColor
        switch self {
        case .literal(let color): return color
        case .text: key = .text
        case .dim: key = .dim
        case .faint: key = .faint
        case .accent: key = .accent
        case .separator: key = .separator
        case .palette(let value): key = value
        case .conditional: throw ProgramRuntimeError.invalidExpression // Requires the projection's evaluator.
        }
        if let colorInput {
            guard let color = colorInput.colors[key] else { throw ProgramRuntimeError.invalidColorInput }
            return color
        }
        // The original eight colors keep their pre-palette API behavior. New system hues need a host input.
        switch key {
        case .text: return appearance.labelColor
        case .dim: return appearance.secondaryLabelColor
        case .faint: return appearance.tertiaryLabelColor
        case .accent: return appearance.accentColor
        case .separator: return appearance.separatorColor
        case .white: return .white
        case .black: return .black
        case .clear: return .clear
        default: throw ProgramRuntimeError.missingColorInput(key)
        }
    }
}

public struct ProgramText: Equatable, Sendable {
    public enum Digits: Equatable, Sendable { case automatic, normal, equalWidth }
    public let value: ProgramExpression
    public let fontFamily: String
    /// Desk/program points, not the String meter's 96-DPI font units.
    public let fontSize: Double
    /// Optional live point size. Nil preserves the original constant fontSize path.
    public let fontSizeExpression: ProgramExpression?
    public let fontWeight: Int?
    public let italic: Bool
    public let color: ProgramColor
    public let align: HorizontalTextAlign
    /// Automatic affects numeric interpolation ranges only; explicit policies apply to the whole text.
    public let digits: Digits
    /// At most this many lines, with an ellipsis when content is omitted. Nil leaves the text unrestricted.
    public let maximumLines: Int?

    public init(_ text: String, fontFamily: String = "System", fontSize: Double = 13, fontWeight: Int? = 400,
                italic: Bool = false, color: ProgramColor = .text, align: HorizontalTextAlign = .center, digits: Digits = .automatic,
                fontSizeExpression: ProgramExpression? = nil, maximumLines: Int? = nil) {
        self.init(value: .string(text), fontFamily: fontFamily, fontSize: fontSize, fontWeight: fontWeight,
                  italic: italic, color: color, align: align, digits: digits, fontSizeExpression: fontSizeExpression,
                  maximumLines: maximumLines)
    }

    public init(value: ProgramExpression, fontFamily: String = "System", fontSize: Double = 13, fontWeight: Int? = 400,
                italic: Bool = false, color: ProgramColor = .text, align: HorizontalTextAlign = .center, digits: Digits = .automatic,
                fontSizeExpression: ProgramExpression? = nil, maximumLines: Int? = nil) {
        self.value = value
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontSizeExpression = fontSizeExpression
        self.fontWeight = fontWeight
        self.italic = italic
        self.color = color
        self.align = align
        self.digits = digits
        self.maximumLines = maximumLines
    }

    /// Adapt once at the existing renderer boundary. Measuring and TextDraw receive this same value.
    func drawingStyle(in appearance: SkinAppearance, colorInput: ProgramColorInput?, wrap: Bool, text: ProgramTextValue? = nil,
                      resolvedFontSize: Double? = nil, resolvedColor: RGBA? = nil) throws -> TextStyle {
        var style = TextStyle()
        style.fontFace = fontFamily
        style.fontSize = (resolvedFontSize ?? fontSize) * (72.0 / 96.0)
        style.fontWeight = fontWeight
        style.italic = italic
        style.color = try resolvedColor ?? color.resolved(in: appearance, colorInput: colorInput)
        style.horizontalAlign = align
        style.verticalAlign = .center
        style.accurateText = true
        style.antiAlias = true
        style.trailingSpaces = true
        style.wrap = wrap
        style.maximumLines = maximumLines
        if let text {
            switch digits {
            case .automatic:
                style.inlineSpans = text.numberRanges.map { InlineSpan(location: $0.lowerBound, length: $0.count, setting: .typography(feature: "tnum", value: 1)) }
            case .normal:
                break // Preserve the font's normal figures and cancel automatic interpolation ranges.
            case .equalWidth:
                if !text.text.isEmpty { style.inlineSpans = [InlineSpan(location: 0, length: text.text.utf16.count, setting: .typography(feature: "tnum", value: 1))] }
            }
        }
        return style
    }
}

/// Current shared-program bounds use the language's default element, block and text budgets. The element and
/// depth limits also count transparent conditional items and every possible arm. A producer may enforce a smaller
/// budget; the runtime always guards direct programs too. Translation table entries and pattern parts count
/// toward maximumExpressions once, in addition to executable expressions that read them.
public enum ProgramLimits {
    public static let maximumElements = 5_000
    public static let maximumDepth = 64
    public static let maximumTextLength = 32_768
    public static let maximumExpressions = 5_000
    public static let maximumExpressionDepth = 128
}
