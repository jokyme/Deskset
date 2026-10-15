import Foundation
import DesksetDraw
import DesksetRuntime

enum RectangleComplementSelfTests {
    private typealias Rect = InkBounds.DeviceRect

    static func run(_ t: AppTestRunner) {
        boundaryTests(t)
        holeTests(t)
        spanTests(t)
        extremeTests(t)
    }

    private static func boundaryTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle complement: empty viewports and a central hole have exact complements") {
            let viewport = try rect(0, 0, 10, 10)
            check([], in: viewport, expected: [viewport], t, "no holes keeps the complete viewport")
            check([viewport], in: viewport, expected: [], t, "a viewport-sized hole leaves no slices")
            try check([rect(-2, -3, 12, 13)], in: viewport, expected: [], t,
                      "an enclosing hole is clipped to complete coverage")
            try check([rect(1, 1, 4, 4)], in: rect(5, 0, 5, 8), expected: [], t, "zero-width viewport")
            try check([rect(1, 1, 4, 4)], in: rect(0, 5, 8, 5), expected: [], t, "zero-height viewport")
            try check([rect(3, 2, 7, 8)], in: viewport,
                      expected: [rect(0, 0, 10, 2), rect(0, 2, 3, 8), rect(7, 2, 10, 8), rect(0, 8, 10, 10)], t,
                      "a central hole leaves the four hand-calculated strips")
            try check([rect(-4, 0, 0, 4), rect(10, 0, 14, 4), rect(0, -4, 4, 0), rect(0, 10, 4, 14),
                       rect(5, 2, 5, 8), rect(2, 5, 8, 5)], in: viewport, expected: [viewport], t,
                      "outside, edge-touching and empty holes never remove viewport pixels")
        }
    }

    private static func holeTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle complement: clipping and hole unions retain free pixels") {
            let viewport = try rect(0, 0, 10, 8)
            try check([rect(-3, 2, 4, 6)], in: viewport,
                      expected: [rect(0, 0, 10, 2), rect(4, 2, 10, 6), rect(0, 6, 10, 8)], t,
                      "a partly outside hole reaches the left edge after clipping")
            try check([rect(-2, -1, 12, 3)], in: viewport, expected: [rect(0, 3, 10, 8)], t,
                      "clipping removes the top and both horizontal overhangs")
            let negative = try rect(-6, -4, 6, 4)
            try check([rect(-2, -1, 2, 1)], in: negative,
                      expected: [rect(-6, -4, 6, -1), rect(-6, -1, -2, 1),
                                 rect(2, -1, 6, 1), rect(-6, 1, 6, 4)], t,
                      "a negative-origin viewport keeps the same half-open complement")

            let overlap = try [rect(2, 1, 5, 4), rect(4, 3, 8, 6)]
            let overlapExpected = try [rect(0, 0, 10, 1), rect(0, 1, 2, 4), rect(5, 1, 10, 3),
                                       rect(8, 3, 10, 6), rect(0, 4, 4, 6), rect(0, 6, 10, 8)]
            check(overlap, in: viewport, expected: overlapExpected, t, "overlapping holes remove only their union")
            check([overlap[1], overlap[0], overlap[1]], in: viewport, expected: overlapExpected, t,
                  "duplicate and reordered holes have the same sorted slices")

            let square = try rect(0, 0, 10, 10)
            let centerExpected = try [rect(0, 0, 10, 2), rect(0, 2, 3, 8),
                                      rect(7, 2, 10, 8), rect(0, 8, 10, 10)]
            try check([rect(3, 2, 5, 8), rect(5, 2, 7, 8)], in: square, expected: centerExpected, t,
                      "horizontally touching holes leave no false gap")
            try check([rect(3, 2, 7, 5), rect(3, 5, 7, 8)], in: square, expected: centerExpected, t,
                      "vertically touching holes keep identical free spans continuous")
            try check([rect(2, 2, 5, 5), rect(5, 5, 8, 8)], in: square,
                      expected: [rect(0, 0, 10, 2), rect(0, 2, 2, 5), rect(5, 2, 10, 5),
                                 rect(0, 5, 5, 8), rect(8, 5, 10, 8), rect(0, 8, 10, 10)], t,
                      "corner-touching holes must not be replaced by their combined bounding box")
            try check([rect(0, 0, 6, 8), rect(4, 0, 10, 8)], in: viewport, expected: [], t,
                      "overlapping holes can jointly cover the complete viewport")
            try check([rect(1, 5, 5, 7)], in: rect(0, 0, 6, 4), expected: [rect(0, 0, 6, 4)], t,
                      "an entirely clipped hole cannot introduce row bands")
        }
    }

    private static func spanTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle complement: each matching span continues independently across adjacent bands") {
            let viewport = try rect(0, 0, 10, 6)
            let holes = try [rect(2, 0, 4, 3), rect(2, 3, 6, 6)]
            let expected = try [rect(0, 0, 2, 6), rect(4, 0, 10, 3), rect(6, 3, 10, 6)]
            check(holes, in: viewport, expected: expected, t,
                  "the left span continues even though the right span changes")
            check([holes[1], holes[0], holes[0]], in: viewport, expected: expected, t,
                  "hole order and duplication do not change independent span continuation")
            try check([rect(0, 2, 6, 4)], in: rect(0, 0, 6, 6),
                      expected: [rect(0, 0, 6, 2), rect(0, 4, 6, 6)], t,
                      "identical X spans separated by a covered band are never joined")

            let farEdge = 1_048_576
            try check([rect(0, 1, 1, 2)], in: rect(0, 0, farEdge, 2),
                      expected: [rect(0, 0, farEdge, 1), rect(1, 1, farEdge, 2)], t,
                      "large upper edges cannot make unequal X spans share an identity")
        }
    }

    private static func extremeTests(_ t: AppTestRunner) {
        t.suite("Runtime: rectangle complement: extreme validated viewports use edges without area or row scans") {
            let low = try rect(Int.min, -3, -1, 3)
            try check([rect(Int.min + 2, -1, -3, 1)], in: low,
                      expected: [rect(Int.min, -3, -1, -1), rect(Int.min, -1, Int.min + 2, 1),
                                 rect(-3, -1, -1, 1), rect(Int.min, 1, -1, 3)], t,
                      "negative extreme horizontal edges retain all four strips")
            let high = try rect(0, -3, Int.max, 3)
            try check([rect(2, -1, Int.max - 2, 1)], in: high,
                      expected: [rect(0, -3, Int.max, -1), rect(0, -1, 2, 1),
                                 rect(Int.max - 2, -1, Int.max, 1), rect(0, 1, Int.max, 3)], t,
                      "positive extreme horizontal edges retain their exact far edge")
            let mixed = try rect(-4, -5, Int.max - 4, Int.max - 5)
            try check([rect(0, 0, 3, 3)], in: mixed,
                      expected: [rect(-4, -5, Int.max - 4, 0), rect(-4, 0, 0, 3),
                                 rect(3, 0, Int.max - 4, 3), rect(-4, 3, Int.max - 4, Int.max - 5)], t,
                      "both viewport dimensions can span Int.max without computing their product")
            t.equal(mixed.width, Int.max)
            t.equal(mixed.height, Int.max)
            let bothLow = try rect(Int.min, Int.min, -1, -1)
            try check([rect(-3, -3, -2, -2)], in: bothLow,
                      expected: [rect(Int.min, Int.min, -1, -3), rect(Int.min, -3, -3, -2),
                                 rect(-2, -3, -1, -2), rect(Int.min, -2, -1, -1)], t,
                      "very distant Y edges create a few bands rather than one band per pixel")
            check([], in: bothLow, expected: [bothLow], t, "no holes retain an extreme viewport exactly")
            check([bothLow], in: bothLow, expected: [], t, "complete extreme coverage leaves no slices")
            let tiny = try rect(Int.min, -2, Int.min + 4, 2)
            try check([rect(Int.max - 4, -1, Int.max, 1), rect(Int.min + 1, -1, Int.min + 3, 1)], in: tiny,
                      expected: [rect(Int.min, -2, Int.min + 4, -1), rect(Int.min, -1, Int.min + 1, 1),
                                 rect(Int.min + 3, -1, Int.min + 4, 1), rect(Int.min, 1, Int.min + 4, 2)], t,
                      "a far outside hole is rejected before constructing reversed clipped endpoints")
        }
    }

    private static func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) throws -> Rect {
        guard let rectangle = Rect(minX: x0, minY: y0, maxX: x1, maxY: y1) else {
            throw CocoaError(.coderInvalidValue)
        }
        return rectangle
    }

    /// Hand-calculated expected rectangles fix the decomposition. The small-grid oracle independently asks
    /// the original holes about each pixel; it does not construct expectations with another row-band algorithm.
    private static func check(_ holes: [Rect], in viewport: Rect, expected: [Rect],
                              _ t: AppTestRunner, _ note: String, line: UInt = #line) {
        let slices = RectangleComplement.slices(in: viewport, excluding: holes)
        t.equal(slices, expected, note, line: line)
        t.equal(slices, slices.sorted {
            ($0.minY, $0.minX, $0.maxY, $0.maxX) < ($1.minY, $1.minX, $1.maxY, $1.maxX)
        }, "\(note): slices have deterministic edge order", line: line)
        for slice in slices {
            t.check(!slice.isEmpty && slice.minX >= viewport.minX && slice.minY >= viewport.minY
                    && slice.maxX <= viewport.maxX && slice.maxY <= viewport.maxY,
                    "\(note): every slice is positive and inside the viewport", line: line)
        }
        for first in slices.indices {
            for second in (first + 1)..<slices.count {
                let a = slices[first], b = slices[second]
                t.check(a.maxX <= b.minX || b.maxX <= a.minX || a.maxY <= b.minY || b.maxY <= a.minY,
                        "\(note): slices never share positive area", line: line)
            }
        }
        // Huge viewports have literal edge expectations above. Only small grids enumerate pixels in this test.
        guard viewport.width <= 16, viewport.height <= 16 else { return }
        for y in viewport.minY..<viewport.maxY {
            for x in viewport.minX..<viewport.maxX {
                let covered = holes.contains { $0.contains(x: x, y: y) }
                let appearances = slices.filter { $0.contains(x: x, y: y) }.count
                t.equal(appearances, covered ? 0 : 1,
                        "\(note): pixel (\(x),\(y)) appears once when free and never when covered", line: line)
            }
        }
    }
}
