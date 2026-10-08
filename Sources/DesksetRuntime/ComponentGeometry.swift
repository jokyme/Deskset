import DesksetDraw

/// Exact area decisions and the fixed group cap for known device rectangles, without scene or raster policy.
package enum ComponentGeometry {
    private typealias Rect = InkBounds.DeviceRect
    private typealias Group = RectangleClosure.Group

    /// Uses the clipped rectangle's area, including exact equality at half the viewport. Empty is never large.
    package static func coversAtLeastHalf(_ rectangle: InkBounds.DeviceRect,
                                         clippedTo viewport: InkBounds.DeviceRect) -> Bool {
        guard !viewport.isEmpty, let clipped = intersection(rectangle, viewport) else { return false }
        let area = ExactArea(clipped), windowArea = ExactArea(viewport)
        // Clipping gives area <= windowArea. This is 2 * area >= windowArea without doubling or rounding.
        return area >= windowArea.subtracting(area)
    }

    /// Caps a bbox-closure fixed point at 256 groups, retaining original input occurrence indices in members.
    ///
    /// Preconditions: each group is nonempty, clipped to this valid viewport and disjoint from all other group
    /// boxes; members are sorted, nonempty and occur in exactly one group. fileOccurrences maps original input
    /// indices to unique original file occurrences, including any gaps from skipped inputs. Every retained
    /// member must index that map. Group array order need not be file order. Empty viewports require no groups.
    /// Future adapters must validate unknown/external inputs before calling; invariant failures are not empty
    /// coverage or a flat-rendering policy. This helper establishes no raster coverage or allocation budget.
    package static func capped(_ closedGroups: [RectangleClosure.Group], in viewport: InkBounds.DeviceRect,
                               fileOccurrences: [Int]) -> [RectangleClosure.Group] {
        let retained = validate(closedGroups, in: viewport, fileOccurrences: fileOccurrences)
        var groups = closedGroups
        while groups.count > 256 {
            let areas = groups.map { ExactArea($0.bounds) }
            let firstFiles = groups.map { firstFile(in: $0, fileOccurrences: fileOccurrences) }
            var best: Pair?
            for first in groups.indices {
                for second in (first + 1)..<groups.count {
                    let bounds = union(groups[first].bounds, groups[second].bounds)
                    let growth = ExactArea(bounds).subtracting(areas[first]).subtracting(areas[second])
                    let pair = Pair(first: first, second: second, bounds: bounds, growth: growth,
                                    firstFile: min(firstFiles[first], firstFiles[second]),
                                    secondFile: max(firstFiles[first], firstFiles[second]))
                    if let current = best {
                        if pair.precedes(current) { best = pair }
                    } else {
                        best = pair
                    }
                }
            }
            guard let best else { preconditionFailure("An over-cap fixed point must contain a pair") }
            groups[best.first] = Group(members: (groups[best.first].members + groups[best.second].members).sorted(),
                                       bounds: best.bounds)
            groups.remove(at: best.second)

            // Keep the forced bbox. Reclosing original element rectangles would lose the cap merge.
            let seeds = groups
            groups = RectangleClosure.groups(seeds.map(\.bounds), clippedTo: viewport).map { closed in
                // Closure members index this temporary seeds array, not the original input or file map.
                let members = closed.members.flatMap { seeds[$0].members }.sorted()
                return Group(members: members, bounds: closed.bounds)
            }
            // Complete bbox closure before checking the cap again, even when the forced merge reached 256.
        }
        let members = groups.flatMap(\.members)
        precondition(members.count == retained.count && Set(members) == retained,
                     "Capping must retain every original input occurrence exactly once")
        return groups.sorted {
            firstFile(in: $0, fileOccurrences: fileOccurrences) < firstFile(in: $1, fileOccurrences: fileOccurrences)
        }
    }

    private struct Pair {
        let first: Int
        let second: Int
        let bounds: Rect
        let growth: ExactArea
        let firstFile: Int
        let secondFile: Int

        func precedes(_ other: Pair) -> Bool {
            if growth != other.growth { return growth < other.growth }
            return (firstFile, secondFile) < (other.firstFile, other.secondFile)
        }
    }

    /// DeviceRect dimensions are each 0...Int.max, so their product fits exactly in two UInt words.
    private struct ExactArea: Equatable, Comparable {
        private let high: UInt
        private let low: UInt

        init(_ rectangle: Rect) {
            let product = UInt(rectangle.width).multipliedFullWidth(by: UInt(rectangle.height))
            high = product.high
            low = product.low
        }

        private init(high: UInt, low: UInt) {
            self.high = high
            self.low = low
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.high < rhs.high || (lhs.high == rhs.high && lhs.low < rhs.low)
        }

        func subtracting(_ other: Self) -> Self {
            let lo = low.subtractingReportingOverflow(other.low)
            let hi = high.subtractingReportingOverflow(other.high)
            let adjusted = hi.partialValue.subtractingReportingOverflow(lo.overflow ? 1 : 0)
            guard !hi.overflow, !adjusted.overflow else {
                preconditionFailure("Exact area subtraction must be nonnegative")
            }
            return Self(high: adjusted.partialValue, low: lo.partialValue)
        }
    }

    private static func validate(_ groups: [Group], in viewport: Rect, fileOccurrences: [Int]) -> Set<Int> {
        precondition(Set(fileOccurrences).count == fileOccurrences.count, "Original file occurrences must be unique")
        precondition(groups.isEmpty || !viewport.isEmpty, "An empty viewport cannot have closed groups")
        var retained = Set<Int>()
        for group in groups {
            precondition(!group.bounds.isEmpty && group.bounds.minX >= viewport.minX
                         && group.bounds.minY >= viewport.minY && group.bounds.maxX <= viewport.maxX
                         && group.bounds.maxY <= viewport.maxY, "Closed group boxes must be nonempty and clipped")
            precondition(!group.members.isEmpty && group.members == group.members.sorted(),
                         "Closed group members must be nonempty and sorted")
            for member in group.members {
                precondition(fileOccurrences.indices.contains(member), "A member must index the original file map")
                let inserted = retained.insert(member).inserted
                precondition(inserted, "An original input occurrence must belong to one group")
            }
        }
        for first in groups.indices {
            for second in (first + 1)..<groups.count {
                precondition(!overlaps(groups[first].bounds, groups[second].bounds),
                             "Capping requires a bbox-closure fixed point")
            }
        }
        return retained
    }

    private static func firstFile(in group: Group, fileOccurrences: [Int]) -> Int {
        guard let first = group.members.map({ fileOccurrences[$0] }).min() else {
            preconditionFailure("A closed group must have an original input occurrence")
        }
        return first
    }

    private static func intersection(_ rectangle: Rect, _ viewport: Rect) -> Rect? {
        let x0 = max(rectangle.minX, viewport.minX), y0 = max(rectangle.minY, viewport.minY)
        let x1 = min(rectangle.maxX, viewport.maxX), y1 = min(rectangle.maxY, viewport.maxY)
        guard x0 < x1, y0 < y1 else { return nil }
        return checkedBounds(x0, y0, x1, y1)
    }

    private static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    private static func union(_ a: Rect, _ b: Rect) -> Rect {
        checkedBounds(min(a.minX, b.minX), min(a.minY, b.minY), max(a.maxX, b.maxX), max(a.maxY, b.maxY))
    }

    /// All unions and intersections stay inside a common validated viewport, including extreme signed edges.
    private static func checkedBounds(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Rect {
        guard let bounds = Rect(minX: x0, minY: y0, maxX: x1, maxY: y1) else {
            preconditionFailure("Clipped component bounds must fit within the validated viewport")
        }
        return bounds
    }
}
