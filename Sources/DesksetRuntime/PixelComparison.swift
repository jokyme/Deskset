/// Numeric comparison of tightly packed, top-row-first RGBA bytes only. Callers separately establish native
/// rendering/canary validity and whether a group requires exact equality rather than the component tolerance.
package enum PixelComparison {
    package struct FirstDifference: Equatable, Sendable {
        package let x: Int
        package let y: Int
        /// RGBA channel index: 0 = red, 1 = green, 2 = blue, 3 = alpha.
        package let channel: Int
        package let expected: UInt8
        package let actual: UInt8
    }

    package struct Difference: Equatable, Sendable {
        package let totalPixels: Int
        package let changedPixels: Int
        package let maxChannelDifference: Int
        package let firstDifference: FirstDifference?

        package var isExact: Bool { changedPixels == 0 }

        /// Fixed G2 component limits. Integer division gives the exact whole-pixel limit of 0.1%, without
        /// floating-point rounding or multiplying a possibly large pixel count.
        package var meetsComponentTolerance: Bool {
            maxChannelDifference <= 2 && changedPixels <= totalPixels / 1000
        }
    }

    package enum Failure: Error, Equatable, Sendable {
        case invalidDimensions
        case dimensionOverflow
        case byteCountMismatch(expected: Int, reference: Int, candidate: Int)
    }

    package static func compare(reference: [UInt8], candidate: [UInt8], width: Int, height: Int) throws -> Difference {
        guard width > 0, height > 0 else { throw Failure.invalidDimensions }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { throw Failure.dimensionOverflow }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !bytes.overflow else { throw Failure.dimensionOverflow }
        guard reference.count == bytes.partialValue, candidate.count == bytes.partialValue else {
            throw Failure.byteCountMismatch(expected: bytes.partialValue, reference: reference.count,
                                            candidate: candidate.count)
        }

        var changedPixels = 0
        var maximum = 0
        var first: FirstDifference?
        for pixel in 0..<pixels.partialValue {
            // The checked byte count bounds these offsets and changedPixels below Int.max.
            let offset = pixel * 4
            var changed = false
            for channel in 0..<4 {
                let expected = reference[offset + channel], actual = candidate[offset + channel]
                guard expected != actual else { continue }
                changed = true
                maximum = max(maximum, abs(Int(expected) - Int(actual)))
                if first == nil {
                    first = FirstDifference(x: pixel % width, y: pixel / width, channel: channel,
                                            expected: expected, actual: actual)
                }
            }
            if changed { changedPixels += 1 }
        }
        return Difference(totalPixels: pixels.partialValue, changedPixels: changedPixels,
                          maxChannelDifference: maximum, firstDifference: first)
    }
}
