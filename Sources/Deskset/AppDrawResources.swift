import CoreGraphics
import DesksetCore
import DesksetDraw

/// Resource-backed drawing and its owner-local caches. This bridge never retains an engine object or DrawContext.
final class AppDrawResources: ResourceLeafDrawing {
    let text = TextLayoutCache(fonts: AppFontResolver())
    let rotatorImages = RotatorImageCache()
    let histogram = DesksetDraw.HistogramCache()
    static let maxHistogramCrops = DesksetDraw.HistogramCache.maxCrops

    func draw(_ value: TextDraw, in ctx: CGContext, cycle: Int) {
        DesksetDraw.TextRenderer.draw(value, in: ctx, layouts: text, cycle: cycle)
    }

    func draw(_ value: ImageDraw, in ctx: CGContext) {
        DesksetDraw.ImageRenderer.draw(value, in: ctx)
    }

    func draw(_ value: BarDraw, in ctx: CGContext) {
        DesksetDraw.BarRenderer.draw(value, in: ctx)
    }

    func draw(_ value: GraphDraw, in ctx: CGContext) {
        switch value {
        case let .line(line): DesksetDraw.LineRenderer.draw(line, in: ctx)
        case let .histogram(histogram): DesksetDraw.HistogramRenderer.draw(histogram, in: ctx, cache: self.histogram)
        }
    }

    func draw(_ value: RotatorDraw, in ctx: CGContext) {
        DesksetDraw.RotatorRenderer.draw(value, in: ctx, cache: rotatorImages)
    }

    func draw(_ value: SpriteDraw, in ctx: CGContext) {
        DesksetDraw.SpriteRenderer.draw(value, in: ctx)
    }
}
