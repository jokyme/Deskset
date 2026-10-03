import DesksetCore

/// Owner-side preparation metadata, without drawing services or a retained destination. These are ideal ink
/// candidates, not verified raster coverage; they cannot yet justify partitioning, clipping or skipping a run.
package struct SceneInkCandidates: Equatable, Sendable {
    package let scene: WidgetScene
    /// Original element order, including hidden elements. Each candidate covers its own selection recipe only.
    package let elementInk: [InkBounds.Candidate]
    /// Complete drawing-run order: background first, then visible top-level compositions with containers atomic.
    package let runInk: [InkBounds.Candidate]

    package init(scene: WidgetScene, elementInk: [InkBounds.Candidate], runInk: [InkBounds.Candidate]) {
        self.scene = scene
        self.elementInk = elementInk
        self.runInk = runInk
    }
}
