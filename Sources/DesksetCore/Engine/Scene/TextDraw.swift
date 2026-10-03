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

    public init(text: String, style: TextStyle, frame: SkinRect, contentFrame: SkinRect, anchor: SkinPoint) {
        self.text = text
        self.style = style
        self.frame = frame
        self.contentFrame = contentFrame
        self.anchor = anchor
    }
}

public extension StringMeter {
    /// Capture on the skin's owner after layout. Subsequent updates and closing the skin cannot change this drawing.
    func lower() -> TextDraw {
        sectionContext.assertOwned(#function)
        let anchor = anchorPoint
        return TextDraw(text: text, style: style, frame: frame, contentFrame: contentFrame,
                        anchor: SkinPoint(x: anchor.x, y: anchor.y))
    }
}
