import CoreGraphics
import DesksetCore
import DesksetDraw

/// Measuring and drawing one skin share its text, Rotator, Shape and Histogram caches. Only the skin's owner uses
/// this context; refreshing or unloading the skin releases it. The library context owns no engine objects, and
/// the resource bridge owns no context, so retained drawing values can be replayed with an independent context.
final class SkinRenderContext {
    /// The context of `skin`, made on first use. Only the skin's owner may call this.
    static func of(_ skin: Skin) -> SkinRenderContext {
        if let context = skin.renderContext as? SkinRenderContext { return context }
        let context = SkinRenderContext()
        skin.renderContext = context
        return context
    }

    let sceneProjector = SceneProjector()
    let resources: AppDrawResources
    let drawing: DesksetDraw.DrawContext

    init() {
        let resources = AppDrawResources()
        self.resources = resources
        drawing = DesksetDraw.DrawContext(resources: resources)
    }

    var text: TextLayoutCache { resources.text }
    var rotatorImages: RotatorImageCache { resources.rotatorImages }
    var shapes: ShapeCG.Cache { drawing.shapes }
    static let maxShapeSources = DesksetDraw.DrawContext.maxShapeSources

    var histogramParts: [[CGRect]] {
        get { resources.histogramParts }
        set { resources.histogramParts = newValue }
    }
    var histogramCrops: [String: (source: CGImage, rect: CGRect, cropped: CGImage)] {
        get { resources.histogramCrops }
        set { resources.histogramCrops = newValue }
    }
    static let maxHistogramCrops = AppDrawResources.maxHistogramCrops
}
