import CoreGraphics
import DesksetCore
import DesksetDraw

/// App entry points share one library executor and the skin's existing resource caches.
enum DrawExecutor {
    static func draw(scene: WidgetScene, in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        DesksetDraw.DrawExecutor.draw(scene: scene, in: ctx, context: context.drawing, cycle: cycle,
                                     target: .capture(ctx, glass: paint(glass)))
    }

    static func draw(elements: [SceneElement], in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        DesksetDraw.DrawExecutor.draw(elements: elements, in: ctx, context: context.drawing, cycle: cycle,
                                     target: .capture(ctx, glass: paint(glass)))
    }

    static func draw(element: SceneElement, in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        DesksetDraw.DrawExecutor.draw(element: element, in: ctx, context: context.drawing, cycle: cycle,
                                     target: .capture(ctx, glass: paint(glass)))
    }

    static func draw(_ items: [DrawItem], in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        DesksetDraw.DrawExecutor.draw(items, in: ctx, context: context.drawing, cycle: cycle,
                                     target: .capture(ctx, glass: paint(glass)))
    }

    static func paint(_ glass: SkinRenderer.GlassDrawing) -> GlassPaint {
        switch glass {
        case let .placeholder(dark): return .placeholder(dark: dark)
        case .window: return .hitArea
        case .none: return .none
        }
    }
}
