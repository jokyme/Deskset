import DesksetDraw

/// Full-scene geometry metadata for an explicit device viewport. No scene, ink or target is inferred here.
package enum SinglePartition {
    package static func plan(in viewport: InkBounds.DeviceRect) -> PartitionPlan {
        let layers: [LayerPlan] = viewport.isEmpty ? [] : [LayerPlan(id: .single, rect: viewport, content: .fullScene)]
        return PartitionPlan(window: viewport, baseMembers: [], layers: layers, skipped: [])
    }
}
