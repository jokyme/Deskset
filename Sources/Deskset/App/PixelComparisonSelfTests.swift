import DesksetRuntime

enum PixelComparisonSelfTests {
    private typealias Failure = PixelComparison.Failure

    static func run(_ t: AppTestRunner) {
        orderedDifferenceTests(t)
        channelTests(t)
        pixelLimitTests(t)
        invalidInputTests(t)
    }

    private static func orderedDifferenceTests(_ t: AppTestRunner) {
        t.suite("Runtime: pixel comparison: exact input and row-major RGBA first difference") {
            let reference: [UInt8] = [10, 20, 30, 255, 40, 50, 60, 255,
                                      70, 80, 90, 255, 100, 110, 120, 255]
            let equal = try PixelComparison.compare(reference: reference, candidate: reference, width: 2, height: 2)
            t.check(equal.isExact && equal.meetsComponentTolerance && equal.firstDifference == nil,
                    "a nonempty literal match is exact, with no fabricated first difference")
            let candidate: [UInt8] = [10, 20, 30, 255, 40, 50, 63, 255,
                                      70, 80, 90, 253, 99, 110, 120, 255]
            let difference = try PixelComparison.compare(reference: reference, candidate: candidate, width: 2, height: 2)
            t.equal(difference.totalPixels, 4)
            t.equal(difference.changedPixels, 3, "later changed pixels must not be lost after finding the first")
            t.equal(difference.maxChannelDifference, 3)
            guard let first = difference.firstDifference else {
                return t.check(false, "literal mixed image has a first difference")
            }
            t.check(first.x == 1 && first.y == 0 && first.channel == 2 && first.expected == 60 && first.actual == 63,
                    "first difference is the blue byte of row 0, column 1, before later alpha/red differences")
            t.check(!difference.isExact && !difference.meetsComponentTolerance,
                    "the literal negative control cannot pass either equality or component tolerance")
            t.equal(reference, [10, 20, 30, 255, 40, 50, 60, 255,
                                70, 80, 90, 255, 100, 110, 120, 255],
                    "comparison leaves the independently specified original reference bytes unchanged")
        }
    }

    private static func channelTests(_ t: AppTestRunner) {
        t.suite("Runtime: pixel comparison: alpha and four-channel differences count each pixel once") {
            let reference = [UInt8](repeating: 0, count: 4000)
            var alphaCandidate = reference
            alphaCandidate[2815] = 2 // Row 17, column 23, alpha, in a 40 x 25 image.
            let alpha = try PixelComparison.compare(reference: reference, candidate: alphaCandidate, width: 40, height: 25)
            t.equal(alpha.changedPixels, 1, "an alpha-only difference changes a pixel")
            guard let first = alpha.firstDifference else {
                return t.check(false, "alpha-only control has a first difference")
            }
            t.check(first.x == 23 && first.y == 17 && first.channel == 3 && first.expected == 0 && first.actual == 2,
                    "top-row-first coordinates and the alpha channel are preserved")
            t.check(!alpha.isExact && alpha.meetsComponentTolerance, "one difference of 2 in 1000 pixels is allowed")

            var fourCandidate = reference
            fourCandidate.replaceSubrange(3996..<4000, with: [1, 2, 1, 2])
            let four = try PixelComparison.compare(reference: reference, candidate: fourCandidate, width: 40, height: 25)
            t.equal(four.changedPixels, 1, "four different channels of one pixel must not become four pixels")
            t.equal(four.maxChannelDifference, 2)
            t.check(four.meetsComponentTolerance && !four.isExact, "the inclusive channel limit is 2")

            fourCandidate[3999] = 3
            let over = try PixelComparison.compare(reference: reference, candidate: fourCandidate, width: 40, height: 25)
            t.equal(over.maxChannelDifference, 3, "a later channel still contributes to the maximum")
            t.check(!over.meetsComponentTolerance, "one pixel at channel difference 3 exceeds the fixed limit")
            let extremes = try PixelComparison.compare(reference: [0, 0, 0, 255], candidate: [255, 0, 0, 255],
                                                        width: 1, height: 1)
            t.equal(extremes.maxChannelDifference, 255, "absolute subtraction covers the complete UInt8 range")
            t.check(!extremes.meetsComponentTolerance, "a full-range channel difference is not a tolerance pass")
        }
    }

    private static func pixelLimitTests(_ t: AppTestRunner) {
        t.suite("Runtime: pixel comparison: 999 1000 and 3000 pixels enforce the exact fixed 0.1 percent limit") {
            for (pixels, allowed) in [(999, false), (1000, true)] {
                let reference = [UInt8](repeating: 0, count: pixels * 4)
                var candidate = reference
                candidate[3] = 2
                let difference = try PixelComparison.compare(reference: reference, candidate: candidate,
                                                              width: pixels, height: 1)
                t.equal(difference.changedPixels, 1)
                t.equal(difference.meetsComponentTolerance, allowed, "one changed pixel among \(pixels)")
            }
            let reference = [UInt8](repeating: 0, count: 12_000)
            var candidate = reference
            for byte in [7, 6003, 11999] { candidate[byte] = 2 }
            let three = try PixelComparison.compare(reference: reference, candidate: candidate, width: 60, height: 50)
            t.equal(three.changedPixels, 3)
            t.check(three.meetsComponentTolerance && !three.isExact, "3 of 3000 is exactly 0.1 percent and allowed")
            candidate[11995] = 2
            let four = try PixelComparison.compare(reference: reference, candidate: candidate, width: 60, height: 50)
            t.equal(four.changedPixels, 4)
            t.check(!four.meetsComponentTolerance, "4 of 3000 exceeds 0.1 percent")
        }
    }

    private static func invalidInputTests(_ t: AppTestRunner) {
        t.suite("Runtime: pixel comparison: invalid dimensions arithmetic and byte counts never become equality") {
            for (width, height) in [(0, 1), (1, 0), (-1, 1), (1, -1), (Int.min, 1)] {
                expect(.invalidDimensions, t, "nonpositive dimensions \(width)x\(height)") {
                    _ = try PixelComparison.compare(reference: [], candidate: [], width: width, height: height)
                }
            }
            for (width, height) in [(Int.max, 2), (Int.max / 4 + 1, 1)] {
                expect(.dimensionOverflow, t, "pixel or RGBA byte count overflow before reading arrays") {
                    _ = try PixelComparison.compare(reference: [], candidate: [], width: width, height: height)
                }
            }
            for (reference, candidate) in [
                ([UInt8](), [UInt8]()),
                ([0, 0, 0], [0, 0, 0, 0]),
                ([0, 0, 0, 0], [0, 0, 0]),
                ([0, 0, 0, 0, 0], [0, 0, 0, 0]),
                ([0, 0, 0, 0], [0, 0, 0, 0, 0]),
            ] {
                expect(.byteCountMismatch(expected: 4, reference: reference.count, candidate: candidate.count), t,
                       "both arrays must have exactly one RGBA pixel; equal emptiness is invalid") {
                    _ = try PixelComparison.compare(reference: reference, candidate: candidate, width: 1, height: 1)
                }
            }
            expect(.byteCountMismatch(expected: 8, reference: 4, candidate: 4), t,
                   "equal array lengths still must match the requested image dimensions") {
                _ = try PixelComparison.compare(reference: [0, 0, 0, 0], candidate: [0, 0, 0, 0], width: 1, height: 2)
            }
        }
    }

    private static func expect(_ expected: Failure, _ t: AppTestRunner, _ note: String, line: UInt = #line,
                               _ body: () throws -> Void) {
        do {
            try body()
            t.check(false, "\(note): expected a typed input failure", line: line)
        } catch let actual as Failure {
            t.equal(actual, expected, note, line: line)
        } catch {
            t.check(false, "\(note): unexpected failure \(error)", line: line)
        }
    }
}
