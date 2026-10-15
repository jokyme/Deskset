import Foundation
import DesksetDraw
import DesksetRuntime

enum RectangleClosureSelfTests {
    private typealias Rect = InkBounds.DeviceRect

    static func run(_ t: AppTestRunner) {
        boundaryTests(t)
        clippingTests(t)
        closureTests(t)
        extremeTests(t)
    }

    private static func boundaryTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle closure: positive overlap keeps occurrence identity and half-open boundaries") {
            let viewport = try rect(0, 0, 10, 10)
            check([], in: viewport, expected: [], t, "empty input")
            try check([rect(1, 1, 4, 4)], in: rect(5, 0, 5, 8), expected: [], t, "zero-width viewport")
            try check([rect(1, 1, 4, 4)], in: rect(0, 5, 8, 5), expected: [], t, "zero-height viewport")
            try check([rect(2, 3, 6, 8)], in: viewport, expected: [([0], rect(2, 3, 6, 8))], t,
                      "input occurrence zero is a normal member")
            try check([rect(0, 0, 3, 3), rect(2, 2, 5, 5), rect(4, 4, 8, 7)], in: viewport,
                      expected: [([0, 1, 2], rect(0, 0, 8, 7))], t, "transitive original overlap")
            try check([rect(1, 1, 8, 8), rect(3, 3, 4, 4), rect(1, 1, 8, 8)], in: viewport,
                      expected: [([0, 1, 2], rect(1, 1, 8, 8))], t, "contained and identical occurrences are not deduplicated")
            try check([rect(5, 5, 8, 7), rect(1, 1, 3, 3)], in: viewport,
                      expected: [([0], rect(5, 5, 8, 7)), ([1], rect(1, 1, 3, 3))], t,
                      "disjoint groups follow occurrence order, not spatial order")
            try check([rect(0, 0, 2, 4), rect(2, 0, 4, 4)], in: viewport,
                      expected: [([0], rect(0, 0, 2, 4)), ([1], rect(2, 0, 4, 4))], t, "touching vertical edges")
            try check([rect(0, 0, 4, 2), rect(0, 2, 4, 4)], in: viewport,
                      expected: [([0], rect(0, 0, 4, 2)), ([1], rect(0, 2, 4, 4))], t, "touching horizontal edges")
            try check([rect(0, 0, 2, 2), rect(2, 2, 4, 4)], in: viewport,
                      expected: [([0], rect(0, 0, 2, 2)), ([1], rect(2, 2, 4, 4))], t, "touching corners")
        }
    }

    private static func clippingTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle closure: clipping precedes connectivity and keeps original index gaps") {
            let viewport = try rect(0, 0, 10, 10)
            try check([rect(-4, 0, 0, 3), rect(-1, 1, 3, 4), rect(5, 5, 5, 8),
                       rect(7, 7, 9, 7), rect(11, 1, 14, 5)], in: viewport,
                      expected: [([1], rect(0, 1, 3, 4))], t, "outside and empty inputs leave a retained index gap")
            try check([rect(-4, 1, 0, 3), rect(10, 0, 12, 4), rect(2, 10, 5, 13)], in: viewport,
                      expected: [], t, "outside boxes may touch the viewport without sharing pixels")
            try check([rect(-3, -4, 12, 13)], in: viewport, expected: [([0], viewport)], t,
                      "an enclosing rectangle is clipped on all four sides")

            // The third rectangle connects the first two only outside the viewport. It must be removed first.
            try check([rect(0, 0, 2, 8), rect(4, 0, 6, 8), rect(1, 5, 5, 7)], in: rect(0, 0, 6, 4),
                      expected: [([0], rect(0, 0, 2, 4)), ([1], rect(4, 0, 6, 4))], t,
                      "an entirely clipped bridge does not connect visible components")
            let negative = try rect(-8, -7, 6, 5)
            try check([rect(-10, -9, -2, -1), rect(-4, -3, 8, 7)], in: negative,
                      expected: [([0, 1], negative)], t, "negative-origin clipping and positive overlap")
            try check([rect(-9, -8, -5, -3), rect(-5, -8, -1, -3)], in: rect(-10, -10, 0, 0),
                      expected: [([0], rect(-9, -8, -5, -3)), ([1], rect(-5, -8, -1, -3))], t,
                      "touching negative-coordinate edges stay separate")
        }
    }

    private static func closureTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle closure: enlarged component boxes are merged to a fixed point") {
            let viewport = try rect(0, 0, 20, 20)
            let a = try rect(0, 0, 2, 6), b = try rect(0, 4, 6, 6), c = try rect(4, 0, 6, 2)
            let threeBounds = try rect(0, 0, 6, 6)
            check([a, b, c], in: viewport, expected: [([0, 1, 2], threeBounds)], t,
                  "the AB box reaches C even though original C overlaps neither A nor B")
            check([c, a, b], in: viewport, expected: [([0, 1, 2], threeBounds)], t,
                  "an initially isolated first occurrence is still included in closure")

            let d = try rect(6, 4, 8, 6), widerC = try rect(4, 0, 8, 2), far = try rect(12, 8, 14, 10)
            let fourBounds = try rect(0, 0, 8, 6)
            check([d, a, b, widerC], in: viewport, expected: [([0, 1, 2, 3], fourBounds)], t,
                  "AB must merge C, then revisit earlier D after the box grows to x=8")

            let original = [d, a, b, widerC, far]
            let permutations = [[0, 1, 2, 3, 4], [4, 3, 2, 1, 0], [1, 4, 0, 3, 2], [3, 0, 4, 2, 1]]
            for permutation in permutations {
                let inputs = permutation.map { original[$0] }
                // Geometry labels 0...3 form the hand-calculated component; 4 is always the isolated far box.
                let joined = permutation.enumerated().compactMap { $0.element < 4 ? $0.offset : nil }
                guard let isolated = permutation.firstIndex(of: 4) else { throw CocoaError(.coderInvalidValue) }
                let expected = [(members: joined, bounds: fourBounds), (members: [isolated], bounds: far)]
                    .sorted { $0.members[0] < $1.members[0] }
                check(inputs, in: viewport, expected: expected, t,
                      "input permutation changes occurrence identities, not the two geometric components")
            }
            t.equal(RectangleClosure.groups(original, clippedTo: viewport),
                    RectangleClosure.groups(original, clippedTo: viewport), "identical input has deterministic output")
        }
    }

    private static func extremeTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle closure: validated extreme edges need no area or unchecked subtraction") {
            let low = try rect(Int.min, -3, -1, 3)
            try check([rect(Int.max - 8, -3, Int.max, 3), rect(Int.min, -3, Int.min + 2, 3),
                       rect(Int.min + 1, 2, -1, 3)], in: low, expected: [([1, 2], low)], t,
                      "a negative extreme union has exactly Int.max width")
            t.equal(low.width, Int.max, "the accepted viewport span is representable without computing area")

            let high = try rect(0, -3, Int.max, 3)
            try check([rect(Int.min, -3, Int.min + 8, 3), rect(0, -3, Int.max - 1, 3),
                       rect(Int.max - 2, 2, Int.max, 3)], in: high, expected: [([1, 2], high)], t,
                      "a positive extreme union retains the exact far edge")
            let mixed = try rect(-4, -5, Int.max - 4, Int.max - 5)
            try check([rect(-8, -9, 2, 3), rect(1, 2, Int.max, Int.max)], in: mixed,
                      expected: [([0, 1], mixed)], t, "both dimensions can span Int.max across zero")
            t.equal(mixed.width, Int.max)
            t.equal(mixed.height, Int.max)

            let tiny = try rect(Int.min, -2, Int.min + 4, 2)
            try check([rect(Int.max - 4, -1, Int.max, 1), rect(Int.min, -3, Int.min + 8, 3)], in: tiny,
                      expected: [([1], tiny)], t,
                      "reject a far outside rectangle before subtracting reversed clipped endpoints")
        }
    }

    private static func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) throws -> Rect {
        guard let rectangle = Rect(minX: x0, minY: y0, maxX: x1, maxY: y1) else {
            throw CocoaError(.coderInvalidValue)
        }
        return rectangle
    }

    /// Expected components come from the cases above, independently of the production traversal. These extra
    /// checks only establish the output contract; they never generate expected groups with another closure loop.
    private static func check(_ rectangles: [Rect], in viewport: Rect,
                              expected: [(members: [Int], bounds: Rect)], _ t: AppTestRunner, _ note: String,
                              line: UInt = #line) {
        let groups = RectangleClosure.groups(rectangles, clippedTo: viewport)
        t.equal(groups.map(\.members), expected.map { $0.members }, note, line: line)
        t.equal(groups.map(\.bounds), expected.map { $0.bounds }, note, line: line)
        let members = groups.flatMap(\.members)
        t.equal(members.sorted(), expected.flatMap { $0.members }.sorted(),
                "\(note): every retained occurrence is present", line: line)
        t.equal(Set(members).count, members.count, "\(note): occurrences belong to one component only", line: line)
        t.equal(groups.compactMap { $0.members.first }, groups.compactMap { $0.members.first }.sorted(),
                "\(note): output groups follow their earliest occurrence", line: line)
        for group in groups {
            t.check(!group.members.isEmpty && group.members == group.members.sorted(),
                    "\(note): each component has sorted members", line: line)
            t.check(!group.bounds.isEmpty && group.bounds.minX >= viewport.minX && group.bounds.minY >= viewport.minY
                    && group.bounds.maxX <= viewport.maxX && group.bounds.maxY <= viewport.maxY,
                    "\(note): every nonempty output box stays inside the viewport", line: line)
            for member in group.members {
                guard rectangles.indices.contains(member) else {
                    t.check(false, "\(note): member is not an original occurrence", line: line)
                    continue
                }
                let original = rectangles[member]
                t.check(group.bounds.minX <= max(original.minX, viewport.minX)
                        && group.bounds.minY <= max(original.minY, viewport.minY)
                        && group.bounds.maxX >= min(original.maxX, viewport.maxX)
                        && group.bounds.maxY >= min(original.maxY, viewport.maxY),
                        "\(note): component covers the clipped original occurrence", line: line)
            }
        }
        for first in groups.indices {
            for second in (first + 1)..<groups.count {
                let a = groups[first].bounds, b = groups[second].bounds
                t.check(a.maxX <= b.minX || b.maxX <= a.minX || a.maxY <= b.minY || b.maxY <= a.minY,
                        "\(note): final component boxes do not share positive area", line: line)
            }
        }
    }
}
