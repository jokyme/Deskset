/// Drawing services and reusable paths for one owner-confined execution context.
/// This mutable context stays on its owner's executor; only captured scene values cross executors.
public final class DrawContext {
    package let text: TextLayoutCache
    package let icons: IconCache
    package let rotatorImages = RotatorImageCache()
    package let histogram = HistogramCache()
    package let shapes = ShapeCG.Cache()

    /// At most this many sources, with only one revision per source; least recently drawn sources are evicted.
    package static let maxShapeSources = 256

    public init(fonts: any FontResolving, icons: (any IconRasterizing)? = nil) {
        text = TextLayoutCache(fonts: fonts)
        self.icons = IconCache(fonts: fonts, rasterizer: icons)
    }
}
