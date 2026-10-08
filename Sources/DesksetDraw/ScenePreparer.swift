import DesksetCore

/// Runs synchronously on the drawing context's owner. Only the resulting values may leave that owner;
/// preparation may warm its geometry cache but does not render, cache scenes or establish raster coverage.
package enum ScenePreparer {
    package static func prepare(_ scene: WidgetScene, context: DrawContext, target: DrawTarget,
                                padding: Int = 0) -> SceneInkCandidates {
        let elementInk = scene.elements.map { element in
            let glass = element.glass.map { [DrawItem.glass($0)] } ?? []
            return InkBounds.candidate(of: glass + element.items, context: context, target: target, padding: padding)
        }
        let runInk = scene.drawingRuns.map {
            InkBounds.candidate(of: $0, context: context, target: target, padding: padding)
        }
        return SceneInkCandidates(scene: scene, elementInk: elementInk, runInk: runInk)
    }
}
