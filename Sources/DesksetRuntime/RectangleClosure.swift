import DesksetDraw

/// A geometry primitive for known device rectangles. This neither establishes raster coverage nor implements
/// layer partition policy: callers supply the rectangles and viewport, without scenes, targets or size budgets.
package enum RectangleClosure {
    package struct Group: Equatable, Sendable {
        /// Original input occurrence indices, in ascending order; skipped inputs leave gaps and zero is valid.
        package let members: [Int]
        package let bounds: InkBounds.DeviceRect
    }

    package static func groups(_ rectangles: [InkBounds.DeviceRect],
                               clippedTo viewport: InkBounds.DeviceRect) -> [Group] {
        guard !viewport.isEmpty else { return [] }
        let clipped = rectangles.enumerated().compactMap { index, rectangle -> (member: Int, bounds: InkBounds.DeviceRect)? in
            guard let bounds = intersection(rectangle, viewport) else { return nil }
            return (index, bounds)
        }

        // First connect only original clipped rectangles, not the unoccupied space inside a component's box.
        var visited = Array(repeating: false, count: clipped.count)
        var result: [Group] = []
        for seed in clipped.indices where !visited[seed] {
            visited[seed] = true
            var pending = [seed]
            var members: [Int] = []
            var bounds = clipped[seed].bounds
            while let current = pending.popLast() {
                let item = clipped[current]
                members.append(item.member)
                bounds = union(bounds, item.bounds)
                for other in clipped.indices where !visited[other] && overlaps(item.bounds, clipped[other].bounds) {
                    visited[other] = true
                    pending.append(other)
                }
            }
            result.append(Group(members: members.sorted(), bounds: bounds))
        }

        // A component's box can meet another component even when their original rectangles never intersect.
        // Restart after every merge: the enlarged box can reach a group examined earlier in this pass.
        var changed = true
        while changed {
            changed = false
            scan: for first in result.indices {
                for second in (first + 1)..<result.count {
                    guard overlaps(result[first].bounds, result[second].bounds) else { continue }
                    result[first] = Group(members: (result[first].members + result[second].members).sorted(),
                                          bounds: union(result[first].bounds, result[second].bounds))
                    result.remove(at: second)
                    changed = true
                    break scan
                }
            }
        }
        return result.sorted { $0.members[0] < $1.members[0] }
    }

    private static func intersection(_ rectangle: InkBounds.DeviceRect, _ viewport: InkBounds.DeviceRect)
        -> InkBounds.DeviceRect? {
        let x0 = max(rectangle.minX, viewport.minX), y0 = max(rectangle.minY, viewport.minY)
        let x1 = min(rectangle.maxX, viewport.maxX), y1 = min(rectangle.maxY, viewport.maxY)
        guard x0 < x1, y0 < y1 else { return nil }
        return checkedBounds(x0, y0, x1, y1)
    }

    private static func overlaps(_ a: InkBounds.DeviceRect, _ b: InkBounds.DeviceRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    private static func union(_ a: InkBounds.DeviceRect, _ b: InkBounds.DeviceRect) -> InkBounds.DeviceRect {
        checkedBounds(min(a.minX, b.minX), min(a.minY, b.minY), max(a.maxX, b.maxX), max(a.maxY, b.maxY))
    }

    /// Every edge is inside the same valid viewport. Intersections and unions therefore have representable
    /// spans no larger than that viewport; a failure is an internal invariant violation, never empty coverage.
    private static func checkedBounds(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> InkBounds.DeviceRect {
        guard let bounds = InkBounds.DeviceRect(minX: x0, minY: y0, maxX: x1, maxY: y1) else {
            preconditionFailure("Clipped rectangle bounds must fit within the validated viewport")
        }
        return bounds
    }
}
