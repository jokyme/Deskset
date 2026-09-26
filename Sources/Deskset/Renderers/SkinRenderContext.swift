import CoreGraphics
import DesksetCore

/// What measuring and drawing one skin keep from frame to frame (docs/skin-threading.md §4.3, §5.4):
/// - its text layouts, used both by `textSize` while the skin lays out its meters and by the String meter's drawing,
///   so the measured size is exactly what gets drawn;
/// - its Rotator images with the image options applied;
/// - the Histogram's scratch space and cropped images.
///
/// One context per skin rather than caches shared by the whole app, so that skins updating and drawing on threads of
/// their own never share one. Like everything reachable from the skin, a context is touched only by the skin's owner,
/// its executor (`Skin.renderContext` checks that in debug builds), and what it keeps goes with the skin: a refreshed
/// skin starts with an empty context, and an unloaded skin's layouts and images are released with it.
final class SkinRenderContext {
    /// The context of `skin`, made on first use. Only the skin's owner may call this.
    static func of(_ skin: Skin) -> SkinRenderContext {
        if let context = skin.renderContext as? SkinRenderContext { return context }
        let context = SkinRenderContext()
        skin.renderContext = context
        return context
    }

    /// The skin's text layouts.
    let text = TextLayoutCache()
    /// The skin's Rotator images with the general image options applied.
    let rotatorImages = RotatorImageCache()
    /// Scratch buffers for the Histogram's column rectangles (primary only, secondary only, overlap), reused from one
    /// Histogram and one frame to the next.
    var histogramParts: [[CGRect]] = [[], [], []]
    /// Histogram images cropped by ImageCrop, by path: reused while the decoded image and the crop rectangle stay the
    /// same.
    var histogramCrops: [String: (source: CGImage, rect: CGRect, cropped: CGImage)] = [:]
    /// Bound on `histogramCrops`: a skin whose Histogram image keeps changing does not pile up crops.
    static let maxHistogramCrops = 64
}
