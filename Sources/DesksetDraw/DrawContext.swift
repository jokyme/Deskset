import DesksetCore

/// Drawing services and reusable paths for one owner-confined execution context.
/// This mutable context stays on its owner's executor; only captured scene values cross executors.
public final class DrawContext {
    package let text: TextLayoutCache
    package let rotatorImages = RotatorImageCache()
    package let histogram = HistogramCache()
    package let shapes = ShapeCG.Cache()

    /// At most this many sources, with only one revision per source; least recently drawn sources are evicted.
    package static let maxShapeSources = 256

    public init(fonts: any FontResolving) {
        text = TextLayoutCache(fonts: fonts)
    }

    /// Shaping for an input's caret, selection, scrolling and navigation uses the same font/layout cache as drawing.
    /// The returned geometry is a pure value; its coordinates are relative to the viewport before scrolling.
    public func textEditLayout(_ text: String, style: TextStyle, viewport: SkinRect, multiline: Bool,
                               cycle: Int) -> TextEditLayout {
        TextRenderer.editingGeometry(text, style: style, viewport: viewport, multiline: multiline,
                                     layouts: self.text, cycle: cycle)
    }
}
