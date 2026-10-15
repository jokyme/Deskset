import CoreGraphics
import DesksetCore

/// How captured glass regions are painted into this drawing destination.
public enum GlassPaint: Equatable, Sendable {
    case placeholder(dark: Bool?)
    case hitArea
    case none
}

/// Executes captured drawing values synchronously inside the current graphics state.
/// The target comes from this destination's entry point; local transforms are captured again by their consumers.
public enum DrawExecutor {
    public static func draw(scene: WidgetScene, in ctx: CGContext, context: DrawContext, cycle: Int,
                            target: DrawTarget) {
        draw(scene.drawingItems, in: ctx, context: context, cycle: cycle, target: target)
    }

    /// Studio selections keep the requested order and draw each element itself, including a selected container's
    /// own mask. Legacy glass stays behind all selected content. Native element backgrounds interleave with that
    /// element's content; visibility and container expansion do not apply.
    public static func draw(elements: [SceneElement], in ctx: CGContext, context: DrawContext, cycle: Int,
                            target: DrawTarget) {
        for element in elements where element.backing != .native(.glass) {
            if let region = element.glass { drawGlass(region, in: ctx, glass: target.glassPaint) }
        }
        for element in elements {
            if element.backing == .native(.glass), let region = element.glass {
                drawGlass(region, in: ctx, glass: target.glassPaint)
            }
            draw(element.items, in: ctx, context: context, cycle: cycle, target: target)
        }
    }

    public static func draw(element: SceneElement, in ctx: CGContext, context: DrawContext, cycle: Int,
                            target: DrawTarget) {
        draw(elements: [element], in: ctx, context: context, cycle: cycle, target: target)
    }

    public static func draw(_ items: [DrawItem], in ctx: CGContext, context: DrawContext, cycle: Int,
                            target: DrawTarget) {
        for item in items {
            switch item {
            case let .fill(rect, paint):
                DrawPrimitives.fill(rect.cgRect, paint.color, paint.secondColor, angle: paint.angle, ctx)
            case let .bevel(rect, bevel):
                DrawPrimitives.drawBevel(rect.cgRect, bevel.type, light: bevel.light, dark: bevel.dark, ctx)
            case let .text(text):
                TextRenderer.draw(text, in: ctx, layouts: context.text, cycle: cycle)
            case let .image(image):
                ImageRenderer.draw(image, in: ctx)
            case let .icon(icon):
                IconRenderer.draw(icon, in: ctx, cache: context.icons)
            case let .shape(shape):
                ShapeRenderer.draw(shape, in: ctx, context: context)
            case let .bar(bar):
                BarRenderer.draw(bar, in: ctx)
            case let .graph(graph):
                switch graph {
                case let .line(line): LineRenderer.draw(line, in: ctx)
                case let .histogram(histogram): HistogramRenderer.draw(histogram, in: ctx, cache: context.histogram)
                }
            case let .roundline(roundline):
                RoundlineRenderer.draw(roundline, in: ctx)
            case let .rotator(rotator):
                RotatorRenderer.draw(rotator, in: ctx, cache: context.rotatorImages)
            case let .sprite(sprite):
                SpriteRenderer.draw(sprite, in: ctx)
            case let .glass(region):
                drawGlass(region, in: ctx, glass: target.glassPaint)
            case let .transformed(transform, contents):
                // Even identity groups isolate the state changed by a meter's background or content.
                ctx.saveGState()
                ctx.concatenate(CGAffineTransform(a: transform.a, b: transform.b, c: transform.c,
                                                  d: transform.d, tx: transform.tx, ty: transform.ty))
                draw(contents, in: ctx, context: context, cycle: cycle, target: target)
                ctx.restoreGState()
            case let .antialias(enabled, contents):
                ctx.saveGState()
                ctx.setShouldAntialias(enabled)
                draw(contents, in: ctx, context: context, cycle: cycle, target: target)
                ctx.restoreGState()
            case let .container(clip, mask, content):
                let rect = clip.cgRect
                guard !content.isEmpty, rect.width > 0, rect.height > 0,
                      rect.minX.isFinite, rect.minY.isFinite else { continue }
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
                draw(content, in: ctx, context: context, cycle: cycle, target: target)
                ctx.setBlendMode(.destinationIn)
                ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
                draw(mask, in: ctx, context: context, cycle: cycle, target: target)
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
