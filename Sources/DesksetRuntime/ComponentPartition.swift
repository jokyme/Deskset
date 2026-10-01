import DesksetCore
import DesksetDraw

/// Ordered component geometry for a canonical device window. This consumes ideal preparation candidates;
/// the returned plan is not raster admission and cannot authorize production clipping or skipped drawing.
package enum ComponentPartition {
    static let maximumElementCount = 5_000

    package enum Failure: Error, Equatable {
        case invalidPlan(String)
        case unresolvedInk(ElementID, InkBounds.Unknown)
        case resourceLimit(String)
    }

    private typealias Rect = InkBounds.DeviceRect

    /// Pass nil only when choosing the base prefix for a new window/scale. A runtime can pass that frozen
    /// prefix on later frames; an invalid prefix fails explicitly instead of silently changing drawing order.
    /// The caller still owns target provenance, coverage admission and the separate oversized-ink guard.
    package static func candidatePlan(_ prepared: SceneInkCandidates, in window: InkBounds.DeviceRect,
                                      baseMembers frozenBase: [ElementID]? = nil) throws -> PartitionPlan {
        let scene = prepared.scene
        guard scene.elements.count <= maximumElementCount else { throw Failure.resourceLimit("Scene exceeds 5000 elements") }
        guard window.minX == 0, window.minY == 0 else {
            throw Failure.invalidPlan("The device window must have a canonical zero origin")
        }
        let top = scene.topLevelElements
        guard prepared.elementInk.count == scene.elements.count, prepared.runInk.count == top.count + 1 else {
            throw Failure.invalidPlan("Preparation must retain the complete element and drawing-run order")
        }
        guard Set(scene.elements.map(\.id)).count == scene.elements.count,
              Set(scene.elements.map { $0.id.index }).count == scene.elements.count else {
            throw Failure.invalidPlan("Scene identities and file occurrences must be unique")
        }
        if window.isEmpty { return SinglePartition.plan(in: window) }
        var rectangles: [Rect?] = []
        for (index, element) in top.enumerated() {
            switch prepared.runInk[index + 1] {
            case .empty: rectangles.append(nil)
            case let .rectangle(rect): rectangles.append(intersection(rect, window))
            case let .unknown(reason): throw Failure.unresolvedInk(element.id, reason)
            }
        }
        let drawn = top.indices.filter { rectangles[$0] != nil }
        let baseMembers: [ElementID]
        if let frozenBase {
            guard Set(frozenBase).count == frozenBase.count,
                  drawn.prefix(frozenBase.count).map({ top[$0].id }) == frozenBase,
                  frozenBase.allSatisfy({ id in top.first(where: { $0.id == id })?.backing == .content }) else {
                throw Failure.invalidPlan("Frozen base members must be the drawn scene's leading content prefix")
            }
            baseMembers = frozenBase
        } else {
            var prefix: [ElementID] = []
            for index in drawn {
                guard let rectangle = rectangles[index], top[index].backing == .content,
                      ComponentGeometry.coversAtLeastHalf(rectangle, clippedTo: window) else { break }
                prefix.append(top[index].id)
            }
            baseMembers = prefix
        }
        let baseIDs = Set(baseMembers)
        guard let empty = Rect(minX: 0, minY: 0, maxX: 0, maxY: 0) else {
            preconditionFailure("The canonical empty device rectangle is representable")
        }
        // Keep a slot for every top-level occurrence, including base and empty units. Closure members therefore
        // continue to index the original order when skipped units leave gaps in the file occurrence map.
        let inputs = top.indices.map { baseIDs.contains(top[$0].id) ? empty : rectangles[$0] ?? empty }
        let closed = RectangleClosure.groups(inputs, clippedTo: window)
        let capped = ComponentGeometry.capped(closed, in: window, fileOccurrences: top.map { $0.id.index })
        let groups = capped.map { group -> LayerPlan in
            let ids = group.members.map { top[$0].id }
            guard let first = ids.map(\.index).min() else {
                preconditionFailure("A closed component must retain an original member")
            }
            return LayerPlan(id: .group(fileIndex: first), rect: group.bounds, content: .group(members: ids))
        }
        let slices = RectangleComplement.slices(in: window, excluding: groups.map(\.rect)).enumerated().map {
            LayerPlan(id: .baseSlice(index: $0.offset), rect: $0.element, content: .baseSlice(source: $0.element))
        }
        return PartitionPlan(window: window, baseMembers: baseMembers, layers: slices + groups,
                             skipped: top.indices.filter { rectangles[$0] == nil }.map { top[$0].id })
    }

    private static func intersection(_ rectangle: Rect, _ window: Rect) -> Rect? {
        let x0 = max(rectangle.minX, window.minX), y0 = max(rectangle.minY, window.minY)
        let x1 = min(rectangle.maxX, window.maxX), y1 = min(rectangle.maxY, window.maxY)
        guard x0 < x1, y0 < y1 else { return nil }
        guard let result = Rect(minX: x0, minY: y0, maxX: x1, maxY: y1) else {
            preconditionFailure("An intersection inside one valid device window is representable")
        }
        return result
    }
}
