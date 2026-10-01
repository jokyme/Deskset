import CoreGraphics
import DesksetCore
import DesksetDraw

/// Measuring and drawing one skin share its text, Rotator, Shape and Histogram caches. Only the skin's owner uses
/// this context; refreshing or unloading the skin releases it. The library context owns the caches without engine
/// objects, so retained drawing values can be replayed after the skin is released or with an independent context.
final class SkinRenderContext {
    /// The context of `skin`, made on first use. Only the skin's owner may call this.
    static func of(_ skin: Skin) -> SkinRenderContext {
        if let context = skin.renderContext as? SkinRenderContext { return context }
        let context = SkinRenderContext()
        skin.renderContext = context
        return context
    }

    let sceneProjector = SceneProjector()
    let drawing: DesksetDraw.DrawContext

    init() {
        drawing = DesksetDraw.DrawContext(fonts: AppFontResolver())
    }

    var text: TextLayoutCache { drawing.text }
    var rotatorImages: RotatorImageCache { drawing.rotatorImages }
    var shapes: ShapeCG.Cache { drawing.shapes }
    static let maxShapeSources = DesksetDraw.DrawContext.maxShapeSources

    var histogramParts: [[CGRect]] {
        get { drawing.histogram.parts }
        set { drawing.histogram.parts = newValue }
    }
    var histogramCrops: [String: (source: CGImage, rect: CGRect, cropped: CGImage)] {
        get { drawing.histogram.crops }
        set { drawing.histogram.crops = newValue }
    }
    static let maxHistogramCrops = DesksetDraw.HistogramCache.maxCrops
}
