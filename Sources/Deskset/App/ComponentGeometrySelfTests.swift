import Foundation
import DesksetDraw
import DesksetRuntime

enum ComponentGeometrySelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private typealias Expected = (members: [Int], bounds: Rect)

    static func run(_ t: AppTestRunner) {
        clippingTests(t)
        exactAreaTests(t)
        boundaryTests(t)
        spatialTests(t)
        fileTieTests(t)
        closureTests(t)
        extremeCapTests(t)
        membershipTests(t)
    }

    private static func clippingTests(_ t: AppTestRunner) {
        t.suite("Runtime: component area: clipping and empty rectangles precede half-window decisions") {
            let viewport = try rect(0, 0, 10, 10)
            t.check(ComponentGeometry.coversAtLeastHalf(try rect(0, 0, 10, 5), clippedTo: viewport),
                    "exactly half the window is large")
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(0, 0, 7, 7), clippedTo: viewport),
                    "49 pixels out of 100 is below half")
            t.check(ComponentGeometry.coversAtLeastHalf(try rect(0, 0, 6, 9), clippedTo: viewport),
                    "54 pixels out of 100 is above half")
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(-100, 0, 4, 10), clippedTo: viewport),
                    "a large unclipped box becomes only 40 visible pixels")
            t.check(ComponentGeometry.coversAtLeastHalf(try rect(-100, 0, 5, 10), clippedTo: viewport),
                    "clipping to 50 visible pixels keeps exact equality")
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(10, 0, 12, 10), clippedTo: viewport),
                    "a box that only touches the window has no visible area")
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(5, 0, 5, 10), clippedTo: viewport),
                    "zero-width input is empty")
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(0, 5, 10, 5), clippedTo: viewport),
                    "zero-height input is empty")
            t.check(!ComponentGeometry.coversAtLeastHalf(viewport, clippedTo: try rect(5, 0, 5, 10)),
                    "zero-width viewport is not a vacuous large-area match")
            t.check(!ComponentGeometry.coversAtLeastHalf(viewport, clippedTo: try rect(0, 5, 10, 5)),
                    "zero-height viewport is not a vacuous large-area match")
        }
    }

    private static func exactAreaTests(_ t: AppTestRunner) {
        t.suite("Runtime: component area: odd and maximal areas use exact words and borrowed subtraction") {
            let odd = try rect(0, 0, 9_007_199_254_740_993, 1)
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(0, 0, 4_503_599_627_370_496, 1),
                                                       clippedTo: odd),
                    "floor(odd area / 2) is below half beyond Double's exact integer range")
            t.check(ComponentGeometry.coversAtLeastHalf(try rect(0, 0, 4_503_599_627_370_497, 1),
                                                      clippedTo: odd),
                    "ceil(odd area / 2) is large")

            let enormous = try rect(0, 0, Int.max, Int.max), halfWidth = Int.max / 2
            let aboveHalf = try sum(halfWidth, 1)
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(0, 0, halfWidth, Int.max), clippedTo: enormous),
                    "126-bit odd window area minus this strip borrows from the high word")
            t.check(ComponentGeometry.coversAtLeastHalf(try rect(0, 0, aboveHalf, Int.max), clippedTo: enormous),
                    "the next strip compares above half with the same high word")
            t.check(ComponentGeometry.coversAtLeastHalf(enormous, clippedTo: enormous),
                    "maximal legal area is nonempty rather than an overflow fallback")
            t.check(ComponentGeometry.coversAtLeastHalf(try rect(0, 0, Int.max, 1),
                                                      clippedTo: try rect(0, 0, Int.max, 2)),
                    "a window area beyond Int.max still has an exact half")

            let negative = try rect(Int.min, Int.min, -1, -1)
            let belowEdge = try sum(Int.min, halfWidth), aboveEdge = try sum(belowEdge, 1)
            t.check(!ComponentGeometry.coversAtLeastHalf(try rect(Int.min, Int.min, belowEdge, -1),
                                                       clippedTo: negative),
                    "extreme negative origins retain the exact below-half result")
            t.check(ComponentGeometry.coversAtLeastHalf(try rect(Int.min, Int.min, aboveEdge, -1),
                                                      clippedTo: negative),
                    "extreme negative origins retain the exact above-half result")
            let crossing = try rect(-4, -5, Int.max - 4, Int.max - 5)
            t.equal(crossing.width, Int.max)
            t.equal(crossing.height, Int.max)
            t.check(ComponentGeometry.coversAtLeastHalf(crossing, clippedTo: crossing),
                    "both dimensions may legally span Int.max across zero")
            t.check(Rect(minX: Int.min, minY: 0, maxX: Int.max, maxY: 1) == nil,
                    "an unrepresentable dimension is invalid, not a legal huge-area rectangle")
        }
    }

    private static func boundaryTests(_ t: AppTestRunner) {
        t.suite("Runtime: component cap: empty and 256 groups remain while 257 uses the fixed cap") {
            let viewport = try rect(0, 0, 800, 1)
            check([], in: viewport, expected: [], t, "no groups")
            try check([rect(0, 0, 1, 1)], in: rect(5, 0, 5, 1), expected: [], t,
                      "empty viewport has an empty closed input")
            for count in [256, 257] {
                let inputs = try (0..<count).map { index -> Rect in
                    let x = try product(index, 3)
                    return try rect(x, 0, sum(x, 1), 1)
                }
                let expected: [Expected]
                if count == 256 {
                    expected = singletons(0..<count, from: inputs)
                } else {
                    expected = [(members: [0, 1], bounds: try rect(0, 0, 4, 1))]
                        + singletons(2..<count, from: inputs)
                }
                check(inputs, in: viewport, expected: expected, t,
                      "\(count) separated groups use the documented fixed 256 limit")
            }
        }
    }

    private static func spatialTests(_ t: AppTestRunner) {
        t.suite("Runtime: component cap: minimum area increment is neither file adjacency nor center distance") {
            var inputs = try [rect(1000, 0, 1100, 1), rect(0, 0, 1, 100), rect(2, 0, 3, 100)]
            inputs += try fillers(253)
            inputs.append(try rect(1150, 0, 1250, 1))
            let expected: [Expected] = [(members: [0, 256], bounds: try rect(1000, 0, 1250, 1))]
                + singletons(1..<256, from: inputs)
            check(inputs, in: try rect(0, 0, 2_540_000, 20_100), expected: expected, t,
                  "CD grows 50 pixels with centers 150 apart; AB grows 100 with centers only 2 apart")
        }
    }

    private static func fileTieTests(_ t: AppTestRunner) {
        t.suite("Runtime: component cap: equal costs use original file pairs and explicit occurrence mapping") {
            var inputs = try [rect(6, 0, 7, 1), rect(0, 0, 1, 1), rect(3, 0, 4, 1)]
            inputs += try fillers(254)
            let viewport = try rect(0, 0, 2_540_001, 20_100)
            let identityExpected: [Expected] = [(members: [0, 2], bounds: try rect(3, 0, 7, 1)),
                                                 (members: [1], bounds: inputs[1])]
                + singletons(3..<inputs.count, from: inputs)
            check(inputs, in: viewport, expected: identityExpected, t,
                  "equal growth 2 chooses file pair (0,2) before (1,2)", reverseClosed: true)

            var files = try inputs.indices.map { try sum(1000, $0) }
            files[0] = 99
            files[1] = 0
            files[2] = 77
            let mappedExpected: [Expected] = [(members: [1, 2], bounds: try rect(0, 0, 4, 1)),
                                               (members: [0], bounds: inputs[0])]
                + singletons(3..<inputs.count, from: inputs)
            check(inputs, in: viewport, fileOccurrences: files, expected: mappedExpected, t,
                  "file pair (0,77) wins despite filtered input 0 mapping to file 99", reverseClosed: true)
        }
    }

    private static func closureTests(_ t: AppTestRunner) {
        t.suite("Runtime: component cap: forced merge completes closure even after reaching 256") {
            var inputs = try [rect(19, 2, 21, 4), rect(0, 0, 10, 9), rect(10, 8, 20, 10), rect(11, 0, 12, 1)]
            inputs += try fillers(253)
            let expected: [Expected] = [(members: [0, 1, 2, 3], bounds: try rect(0, 0, 21, 10))]
                + singletons(4..<inputs.count, from: inputs)
            check(inputs, in: try rect(0, 0, 2_540_000, 20_100), expected: expected, t,
                  "AC growth 17 reaches B, then its larger box reaches earlier D, leaving 254 groups")
        }
    }

    private static func extremeCapTests(_ t: AppTestRunner) {
        t.suite("Runtime: component cap: every growth may exceed Int.max without choosing a sentinel pair") {
            let step = Int.max / 300
            let rightX = try product(256, step)
            var inputs = [try rect(rightX, 0, sum(rightX, 1), Int.max)]
            for position in 0..<256 {
                let x = try product(position, step)
                inputs.append(try rect(x, 0, sum(x, 1), Int.max))
            }
            let mergedMin = try product(255, step), mergedMax = try sum(rightX, 1)
            let expected: [Expected] = [(members: [0, 256], bounds: try rect(mergedMin, 0, mergedMax, Int.max))]
                + singletons(1..<256, from: inputs)
            check(inputs, in: try rect(0, 0, Int.max, Int.max), expected: expected, t,
                  "minimum growth (step-1)*Int.max chooses true pair (0,256), not initial pair (0,1)")
        }
    }

    private static func membershipTests(_ t: AppTestRunner) {
        t.suite("Runtime: component cap: repeated reclosing preserves composite members and skipped index gaps") {
            var inputs = try [rect(0, 0, 1, 1), rect(-2, 0, -1, 1), rect(0, 0, 1, 1)]
            for original in 3...261 {
                let x = try product(original - 2, 3)
                inputs.append(try rect(x, 0, sum(x, 1), 1))
            }
            let expected: [Expected] = [(members: [0, 2, 3, 4, 5, 6], bounds: try rect(0, 0, 13, 1))]
                + singletons(7..<inputs.count, from: inputs)
            check(inputs, in: try rect(0, 0, 780, 1), expected: expected, t,
                  "260 groups merge original 3,4,5,6 in four rounds without replacing original members")
        }
    }

    private static func fillers(_ count: Int) throws -> [Rect] {
        try (0..<count).map { index in
            let x = try sum(10_000, product(index, 10_000))
            return try rect(x, 20_000, sum(x, 1), 20_100)
        }
    }

    private static func singletons(_ indices: Range<Int>, from rectangles: [Rect]) -> [Expected] {
        indices.map { (members: [$0], bounds: rectangles[$0]) }
    }

    private static func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) throws -> Rect {
        guard let rectangle = Rect(minX: x0, minY: y0, maxX: x1, maxY: y1) else {
            throw CocoaError(.coderInvalidValue)
        }
        return rectangle
    }

    private static func product(_ a: Int, _ b: Int) throws -> Int {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw CocoaError(.coderInvalidValue) }
        return result.partialValue
    }

    private static func sum(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw CocoaError(.coderInvalidValue) }
        return result.partialValue
    }

    /// Membership and boxes are hand-calculated above; these checks never regenerate a greedy cap oracle.
    private static func check(_ rectangles: [Rect], in viewport: Rect, fileOccurrences: [Int]? = nil,
                              expected: [Expected], _ t: AppTestRunner, _ note: String,
                              reverseClosed: Bool = false, line: UInt = #line) {
        let files = fileOccurrences ?? Array(rectangles.indices)
        let closed = RectangleClosure.groups(rectangles, clippedTo: viewport)
        let groups = ComponentGeometry.capped(closed, in: viewport, fileOccurrences: files)
        let orderedExpected = expected.sorted { firstFile($0.members, files) < firstFile($1.members, files) }
        t.equal(groups.map(\.members), orderedExpected.map { $0.members }, "\(note): exact members", line: line)
        t.equal(groups.map(\.bounds), orderedExpected.map { $0.bounds }, "\(note): exact boxes", line: line)
        t.equal(groups.count, expected.count, "\(note): exact count", line: line)
        t.check(groups.count <= 256, "\(note): fixed cap", line: line)

        let members = groups.flatMap(\.members)
        t.equal(members.sorted(), expected.flatMap { $0.members }.sorted(),
                "\(note): every retained original occurrence is present", line: line)
        t.equal(Set(members).count, members.count, "\(note): no occurrence is duplicated", line: line)
        let validMembers = members.allSatisfy { rectangles.indices.contains($0) && files.indices.contains($0) }
        t.check(validMembers, "\(note): all members index the original input and file map", line: line)
        guard validMembers else { return }
        t.check(groups.allSatisfy { !$0.members.isEmpty && $0.members == $0.members.sorted() },
                "\(note): members remain sorted original input indices", line: line)
        let fileOrder = groups.compactMap { $0.members.map { files[$0] }.min() }
        t.equal(fileOrder, fileOrder.sorted(), "\(note): output follows minimum original file occurrence", line: line)
        t.check(groups.allSatisfy {
            !$0.bounds.isEmpty && $0.bounds.minX >= viewport.minX && $0.bounds.minY >= viewport.minY
                && $0.bounds.maxX <= viewport.maxX && $0.bounds.maxY <= viewport.maxY
        }, "\(note): boxes are nonempty and clipped", line: line)
        t.check(groups.allSatisfy { group in
            group.members.allSatisfy { member in
                let original = rectangles[member]
                return group.bounds.minX <= max(original.minX, viewport.minX)
                    && group.bounds.minY <= max(original.minY, viewport.minY)
                    && group.bounds.maxX >= min(original.maxX, viewport.maxX)
                    && group.bounds.maxY >= min(original.maxY, viewport.maxY)
            }
        }, "\(note): boxes retain clipped original rectangles", line: line)
        var disjoint = true
        for first in groups.indices {
            for second in (first + 1)..<groups.count {
                let a = groups[first].bounds, b = groups[second].bounds
                if a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY {
                    disjoint = false
                }
            }
        }
        t.check(disjoint, "\(note): closure leaves no positive-area box overlaps", line: line)
        if reverseClosed {
            t.equal(ComponentGeometry.capped(Array(closed.reversed()), in: viewport, fileOccurrences: files),
                    groups, "\(note): current group array order cannot alter a file-pair tie", line: line)
        }
    }

    private static func firstFile(_ members: [Int], _ files: [Int]) -> Int {
        guard let first = members.map({ files[$0] }).min() else {
            preconditionFailure("A hand-calculated expected group must have a member")
        }
        return first
    }
}
