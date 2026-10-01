import CoreGraphics
import DesksetCore

/// Executes captured drawing values. Live engine objects are only read by the owner-side scene projector.
enum DrawExecutor {
    static func draw(scene: WidgetScene, in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        draw(scene.drawingItems, in: ctx, context: context, cycle: cycle, glass: glass)
    }

    /// Studio selections keep the requested order and draw each element itself, including a selected container's
    /// own mask. All selected glass is behind all selected content; visibility and container expansion do not apply.
    static func draw(elements: [SceneElement], in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        for element in elements {
            if let region = element.glass { drawGlass(region, in: ctx, glass: glass) }
        }
        for element in elements {
            draw(element.items, in: ctx, context: context, cycle: cycle, glass: glass)
        }
    }

    static func draw(element: SceneElement, in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        draw(elements: [element], in: ctx, context: context, cycle: cycle, glass: glass)
    }

    static func draw(_ items: [DrawItem], in ctx: CGContext, context: SkinRenderContext, cycle: Int,
                     glass: SkinRenderer.GlassDrawing) {
        for item in items {
            switch item {
            case let .fill(rect, paint):
                SkinRenderer.fill(rect.cgRect, paint.color, paint.secondColor, angle: paint.angle, ctx)
            case let .bevel(rect, bevel):
                SkinRenderer.drawBevel(rect.cgRect, bevel.type, light: bevel.light, dark: bevel.dark, ctx)
            case let .text(text):
                SkinRenderer.drawString(text, ctx, context, cycle: cycle)
            case let .image(image):
                SkinRenderer.drawImage(image, ctx)
            case let .shape(shape):
                SkinRenderer.drawShape(shape, ctx, context)
            case let .bar(bar):
                SkinRenderer.drawBar(bar, ctx)
            case let .graph(graph):
                switch graph {
                case let .line(line): SkinRenderer.drawLine(line, ctx)
                case let .histogram(histogram): SkinRenderer.drawHistogram(histogram, ctx, context)
                }
            case let .roundline(roundline):
                SkinRenderer.drawRoundline(roundline, ctx)
            case let .rotator(rotator):
                SkinRenderer.drawRotator(rotator, ctx, context)
            case let .sprite(sprite):
                SkinRenderer.drawSprite(sprite, ctx)
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

    private static func drawGlass(_ region: GlassRegion, in ctx: CGContext, glass: SkinRenderer.GlassDrawing) {
        switch glass {
        case let .placeholder(dark): GlassPlaceholder.draw(region, in: ctx, dark: dark)
        case .window: GlassPlaceholder.drawHitArea([region], in: ctx)
        case .none: break
        }
    }
}
