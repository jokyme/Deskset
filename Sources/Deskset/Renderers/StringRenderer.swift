import CoreGraphics
import DesksetCore
import DesksetDraw

typealias TextLayoutCache = DesksetDraw.TextLayoutCache
typealias TextLayout = DesksetDraw.TextLayout

extension SkinRenderer {
    // MARK: String

    /// The host's `SkinHost.textSize`: measured with `skin`'s own text layouts, the ones `drawString` then draws. Only
    /// the skin's owner may call this.
    static func textSize(_ text: String, style: TextStyle, wrapWidth: Double?,
                         for skin: Skin) -> (width: Double, height: Double) {
        guard !text.isEmpty, style.fontSize > 0 else { return (0, 0) }
        return SkinRenderContext.of(skin).text.layout(text, style: style, wrapWidth: wrapWidth.map { CGFloat($0) },
                                                      cycle: skin.updateCount).size
    }

    static func drawString(_ meter: StringMeter, _ ctx: CGContext, _ context: SkinRenderContext) {
        drawString(meter.lower(), ctx, context, cycle: meter.skin.updateCount)
    }

    /// `cycle` only governs layout-cache turnover; it is not an input to the picture or part of the text's value.
    static func drawString(_ drawing: TextDraw, _ ctx: CGContext, _ context: SkinRenderContext, cycle: Int) {
        DesksetDraw.TextRenderer.draw(drawing, in: ctx, layouts: context.text, cycle: cycle)
    }
}
