import DesksetCore
import DesksetDraw

/// Layer geometry and ordered content roles, without graphics resources, live owners or raster coverage.
package struct LayerPlan: Equatable, Sendable {
    package enum Identity: Equatable, Sendable {
        case single
        case group(fileIndex: Int)
        case baseSlice(index: Int)
    }

    package enum Content: Equatable, Sendable {
        case fullScene
        case group(members: [ElementID])
        case baseSlice(source: InkBounds.DeviceRect)
    }

    package let id: Identity
    package let rect: InkBounds.DeviceRect
    package let content: Content

    package init(id: Identity, rect: InkBounds.DeviceRect, content: Content) {
        self.id = id
        self.rect = rect
        self.content = content
    }
}

/// A transferable geometry plan. Arrays preserve the caller's order; constructing a plan is not a coverage check.
package struct PartitionPlan: Equatable, Sendable {
    package let window: InkBounds.DeviceRect
    package let baseMembers: [ElementID]
    package let layers: [LayerPlan]
    package let skipped: [ElementID]

    package init(window: InkBounds.DeviceRect, baseMembers: [ElementID], layers: [LayerPlan], skipped: [ElementID]) {
        self.window = window
        self.baseMembers = baseMembers
        self.layers = layers
        self.skipped = skipped
    }
}
