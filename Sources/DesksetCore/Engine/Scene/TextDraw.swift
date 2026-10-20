import Foundation

/// The completed text and geometry a String meter draws. The text style includes its resolved inline spans;
/// measuring, font resolution and drawing caches remain with the drawing service. No skin or measure is retained.
public struct TextDraw: Equatable, Sendable {
    public var text: String
    public var style: TextStyle
    public var frame: SkinRect
    public var contentFrame: SkinRect
    /// The alignment anchor, before the StringAlign offset: Angle rotates about this point.
    public var anchor: SkinPoint
    /// TextEdit's captured editing state. Ordinary String meters leave this absent.
    public var editing: TextEditingDraw?

    public init(text: String, style: TextStyle, frame: SkinRect, contentFrame: SkinRect, anchor: SkinPoint,
                editing: TextEditingDraw? = nil) {
        self.text = text
        self.style = style
        self.frame = frame
        self.contentFrame = contentFrame
        self.anchor = anchor
        self.editing = editing
    }
}

/// Value-only input decorations, with indices in the displayed text's UTF-16 coordinates. Layouts, fonts and
/// blinking clocks remain with their owners; capturing this value retains no editing meter.
public struct TextEditingDraw: Equatable, Sendable {
    public var isFocused: Bool
    public var caretVisible: Bool
    public var caretOffset: Int
    /// Affinity when an insertion offset is shared by two soft-wrapped visual lines.
    public var caretLine: Int?
    public var selectionRange: Range<Int>
    public var scroll: SkinPoint
    public var caretColor: RGBA
    public var selectionColor: RGBA
    public var focusBorderWidth: Double
    public var focusBorderColor: RGBA
    public var multiline: Bool
    /// An empty input can paint a placeholder while laying out the caret against the empty input.
    public var layoutText: String?
    public var layoutStyle: TextStyle?

    public init(isFocused: Bool, caretVisible: Bool = true, caretOffset: Int, caretLine: Int? = nil,
                selectionRange: Range<Int>,
                scroll: SkinPoint = .init(), caretColor: RGBA = .white,
                selectionColor: RGBA = .init(r: 0, g: 60, b: 107, a: 255),
                focusBorderWidth: Double = 0, focusBorderColor: RGBA = .black, multiline: Bool = false,
                layoutText: String? = nil, layoutStyle: TextStyle? = nil) {
        self.isFocused = isFocused
        self.caretVisible = caretVisible
        self.caretOffset = caretOffset
        self.caretLine = caretLine
        self.selectionRange = selectionRange
        self.scroll = scroll
        self.caretColor = caretColor
        self.selectionColor = selectionColor
        self.focusBorderWidth = focusBorderWidth
        self.focusBorderColor = focusBorderColor
        self.multiline = multiline
        self.layoutText = layoutText
        self.layoutStyle = layoutStyle
    }
}

public extension StringMeter {
    /// Capture on the skin's owner after layout. Subsequent updates and closing the skin cannot change this drawing.
    func lower() -> TextDraw {
        skin.assertOwned()
        let anchor = anchorPoint
        return TextDraw(text: text, style: style, frame: frame, contentFrame: contentFrame,
                        anchor: SkinPoint(x: anchor.x, y: anchor.y))
    }
}
