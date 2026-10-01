import CoreGraphics
import DesksetCore
import DesksetDraw

/// Resource-backed drawing and its owner-local caches. This bridge never retains an engine object or DrawContext.
final class AppDrawResources: ResourceLeafDrawing {
    let text = TextLayoutCache(fonts: AppFontResolver())
    let rotatorImages = RotatorImageCache()
    var histogramParts: [[CGRect]] = [[], [], []]
    var histogramCrops: [String: (source: CGImage, rect: CGRect, cropped: CGImage)] = [:]
    static let maxHistogramCrops = 64

    func draw(_ value: TextDraw, in ctx: CGContext, cycle: Int) {
        SkinRenderer.drawString(value, ctx, self, cycle: cycle)
    }

    func draw(_ value: ImageDraw, in ctx: CGContext) {
        SkinRenderer.drawImage(value, ctx)
    }

    func draw(_ value: BarDraw, in ctx: CGContext) {
        SkinRenderer.drawBar(value, ctx)
    }

    func draw(_ value: GraphDraw, in ctx: CGContext) {
        switch value {
        case let .line(line): SkinRenderer.drawLine(line, ctx)
        case let .histogram(histogram): SkinRenderer.drawHistogram(histogram, ctx, self)
        }
    }

    func draw(_ value: RotatorDraw, in ctx: CGContext) {
        SkinRenderer.drawRotator(value, ctx, self)
    }

    func draw(_ value: SpriteDraw, in ctx: CGContext) {
        SkinRenderer.drawSprite(value, ctx)
    }
}
