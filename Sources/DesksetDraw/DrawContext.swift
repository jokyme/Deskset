/// Drawing services and reusable paths for one owner-confined execution context.
/// This mutable context stays on its owner's executor; only captured scene values cross executors.
public final class DrawContext {
    let resources: any ResourceLeafDrawing
    package let shapes = ShapeCG.Cache()

    /// At most this many sources, with only one revision per source; least recently drawn sources are evicted.
    package static let maxShapeSources = 256

    public init(resources: any ResourceLeafDrawing) {
        self.resources = resources
    }
}
