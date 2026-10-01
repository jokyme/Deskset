import DesksetCore
import DesksetDraw

/// Existing App diagnostics use the shared path cache through their owner-side context.
typealias ShapeCG = DesksetDraw.ShapeCG

extension ShapeCG {
    static func built(for draw: ShapeDraw, in context: SkinRenderContext) -> [BuiltShape] {
        built(for: draw, in: context.drawing)
    }
}
