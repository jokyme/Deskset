import CoreGraphics
import DesksetCore

/// How captured glass regions are painted into this drawing destination.
public enum GlassPaint: Equatable, Sendable {
    case placeholder(dark: Bool?)
    case hitArea
    case none
}

/// Executes captured drawing values. Resource leaves run synchronously inside the current graphics state.
public enum DrawExecutor {
    public static func draw(scene: WidgetScene, in ctx: CGContext, context: DrawContext, cycle: Int,
                            glass: GlassPaint) {
        draw(scene.drawingItems, in: ctx, context: context, cycle: cycle, glass: glass)
    }

    /// Studio selections keep the requested order and draw each element itself, including a selected container's
    /// own mask. All selected glass is behind all selected content; visibility and container expansion do not apply.
    public static func draw(elements: [SceneElement], in ctx: CGContext, context: DrawContext, cycle: Int,
                            glass: GlassPaint) {
        for element in elements {
            if let region = element.glass { drawGlass(region, in: ctx, glass: glass) }
        }
        for element in elements {
            draw(element.items, in: ctx, context: context, cycle: cycle, glass: glass)
        }
    }

    public static func draw(element: SceneElement, in ctx: CGContext, context: DrawContext, cycle: Int,
                            glass: GlassPaint) {
        draw(elements: [element], in: ctx, context: context, cycle: cycle, glass: glass)
    }

    public static func draw(_ items: [DrawItem], in ctx: CGContext, context: DrawContext, cycle: Int,
                            glass: GlassPaint) {
        for item in items {
            switch item {
            case let .fill(rect, paint):
                DrawPrimitives.fill(rect.cgRect, paint.color, paint.secondColor, angle: paint.angle, ctx)
            case let .bevel(rect, bevel):
                DrawPrimitives.drawBevel(rect.cgRect, bevel.type, light: bevel.light, dark: bevel.dark, ctx)
            case let .text(text):
                context.resources.draw(text, in: ctx, cycle: cycle)
            case let .image(image):
                context.resources.draw(image, in: ctx)
            case let .shape(shape):
                ShapeRenderer.draw(shape, in: ctx, context: context)
            case let .bar(bar):
                context.resources.draw(bar, in: ctx)
            case let .graph(graph):
                context.resources.draw(graph, in: ctx)
            case let .roundline(roundline):
                RoundlineRenderer.draw(roundline, in: ctx)
            case let .rotator(rotator):
                context.resources.draw(rotator, in: ctx)
            case let .sprite(sprite):
                context.resources.draw(sprite, in: ctx)
            case let .glass(region):
                drawGlass(region, in: ctx, glass: glass)
            case let .transformed(transform, contents):
                // Even identity groups isolate the state changed by a meter's background or content.
                ctx.saveGState()
                ctx.concatenate(CGAffineTransform(a: transform.a, b: transform.b, c: transform.c,
                                                  d: transform.d, tx: transform.tx, ty: transform.ty))
                draw(contents, in: ctx, context: context, cycle: cycle, glass: glass)
                ctx.restoreGState()
            case let .antialias(enabled, contents):
                ctx.saveGState()
                ctx.setShouldAntialias(enabled)
                draw(contents, in: ctx, context: context, cycle: cycle, glass: glass)
                ctx.restoreGState()
            case let .container(clip, mask, content):
                let rect = clip.cgRect
                guard !content.isEmpty, rect.width > 0, rect.height > 0,
                      rect.minX.isFinite, rect.minY.isFinite else { continue }
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
                draw(content, in: ctx, context: context, cycle: cycle, glass: glass)
                ctx.setBlendMode(.destinationIn)
                ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
                draw(mask, in: ctx, context: context, cycle: cycle, glass: glass)
                ctx.endTransparencyLayer()
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
    }

    private static func drawGlass(_ region: GlassRegion, in ctx: CGContext, glass: GlassPaint) {
        switch glass {
        case let .placeholder(dark): GlassPlaceholder.draw(region, in: ctx, dark: dark)
        case .hitArea: GlassPlaceholder.drawHitArea([region], in: ctx)
        case .none: break
        }
    }
}
