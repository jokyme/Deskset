import CoreGraphics
import DesksetRuntime
import Dispatch
import Foundation
import Metal
import QuartzCore

enum OffscreenRendererSelfTests {
    private typealias Failure = OffscreenRenderer.Failure
    private enum FailureKind { case invalidInput, resourceLimit, unavailable, timeout }
    private static let logicalWidth = 7
    private static let logicalHeight = 5

    static func run(_ t: AppTestRunner) {
        bitmapTests(t)
        allocationInputTests(t)
        frameInputTests(t)
        outputColorSpaceTests(t)
    }

    private static func bitmapTests(_ t: AppTestRunner) {
        t.suite("Runtime: offscreen renderer: Metal canary and reusable A/B/A destinations preserve 1x and 2x source bytes") {
            // This is the first native suite. Missing Metal is an explicit failure, never an empty/skipped pass.
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: offscreen native verification did not run")
            }
            for scale in [1, 2] {
                let width = logicalWidth * scale, height = logicalHeight * scale
                let expectedA = sourceBytes(variant: 0, scale: scale)
                let expectedB = sourceBytes(variant: 1, scale: scale)
                let blank = [UInt8](repeating: 0, count: width * height * 4)
                checkFixture(expectedA, expectedB, width: width, height: height, t)
                weak var releasedOwner: OffscreenRenderer?
                let saved = try autoreleasepool { () throws -> OffscreenRenderer.Readback in
                    let renderer = try OffscreenRenderer(width: width, height: height, device: device,
                                                         maximumReadbackBytes: width * height * 4)
                    releasedOwner = renderer
                    t.check(!renderer.hasVerifiedCanary, "new destination has not bypassed its automatic canary")
                    let firstTree = try tree(bytes: expectedA, scale: scale)
                    let first = try renderer.render(firstTree, at: 0, deadline: .now() + .seconds(30))
                    t.check(renderer.hasVerifiedCanary, "first business result follows the scribbled known-image check")
                    check(first, expectedA, width: width, height: height, t, "first A at \(scale)x")

                    // Every frame gets a new tree, while one fixed-size renderer/texture/queue remains alive.
                    for (label, pixels) in [("B", expectedB), ("A again", expectedA), ("blank", blank), ("A after blank", expectedA)] {
                        let nextTree = try tree(bytes: label == "blank" ? nil : pixels, scale: scale)
                        let next = try renderer.render(nextTree, at: 0, deadline: .now() + .seconds(30))
                        check(next, pixels, width: width, height: height, t, "\(label) at \(scale)x")
                        t.equal(first.rgba, expectedA, "later frames do not overwrite the previous Readback")
                        t.check(renderer.hasVerifiedCanary, "canary verification survives fixed-size reuse")
                    }
                    var independentlyMutableCopy = first.rgba
                    independentlyMutableCopy[0] ^= 0xFF
                    t.equal(first.rgba, expectedA, "mutating a copied array cannot mutate a saved readback")
                    return first
                }
                t.check(releasedOwner == nil, "readback and completion handler do not retain the owner")
                check(saved, expectedA, width: width, height: height, t, "saved A after owner release at \(scale)x")
            }
        }
    }

    private static func allocationInputTests(_ t: AppTestRunner) {
        t.suite("Runtime: offscreen renderer: dimensions arithmetic budgets and absent Metal fail before allocation") {
            for (width, height) in [(0, 5), (7, 0), (-1, 5), (7, -1), (Int.min, 1)] {
                expect(.invalidInput, t, "nonpositive dimensions \(width)x\(height)") {
                    _ = try OffscreenRenderer(width: width, height: height, device: nil, maximumReadbackBytes: 4096)
                }
            }
            for budget in [0, -1] {
                expect(.invalidInput, t, "nonpositive explicit budget") {
                    _ = try OffscreenRenderer(width: 7, height: 5, device: nil, maximumReadbackBytes: budget)
                }
            }
            for (width, height) in [(Int.max, 1), (Int.max / 4 + 1, 1), (Int.max / 4, 2), (Int.max / 16 + 1, 1)] {
                expect(.resourceLimit, t, "row, image or canary temporary arithmetic cannot trap") {
                    _ = try OffscreenRenderer(width: width, height: height, device: nil, maximumReadbackBytes: Int.max)
                }
            }
            expect(.resourceLimit, t, "one byte below the required readback budget is rejected") {
                _ = try OffscreenRenderer(width: 7, height: 5, device: nil, maximumReadbackBytes: 139)
            }
            expect(.unavailable, t, "valid dimensions and exact budget do not replace a nil device") {
                _ = try OffscreenRenderer(width: 7, height: 5, device: nil, maximumReadbackBytes: 140)
            }
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: actual texture-capability limit was not checked")
            }
            let limit = device.supportsFamily(.metal3) ? 16_384 : 8_192
            for (width, height) in [(limit + 1, 1), (1, limit + 1)] {
                expect(.resourceLimit, t, "a narrow allocation still obeys the supported texture dimension") {
                    _ = try OffscreenRenderer(width: width, height: height, device: device, maximumReadbackBytes: 1_000_000)
                }
            }
        }
    }

    private static func frameInputTests(_ t: AppTestRunner) {
        t.suite("Runtime: offscreen renderer: finite time and an unexpired bounded deadline precede all GPU work") {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.check(false, "Metal unavailable: frame-input verification did not run")
            }
            let renderer = try OffscreenRenderer(width: logicalWidth, height: logicalHeight, device: device,
                                                 maximumReadbackBytes: logicalWidth * logicalHeight * 4)
            let expected = sourceBytes(variant: 0, scale: 1)
            let input = try tree(bytes: expected, scale: 1)
            for time in [CFTimeInterval.nan, .infinity, -.infinity] {
                expect(.invalidInput, t, "nonfinite frame time") {
                    _ = try renderer.render(input, at: time, deadline: .now() + .seconds(30))
                }
                t.check(!renderer.hasVerifiedCanary, "invalid time does not start even the first canary")
            }
            expect(.invalidInput, t, "unbounded waiting is not an explicit GPU budget") {
                _ = try renderer.render(input, at: 0, deadline: .distantFuture)
            }
            expect(.timeout, t, "a deadline already in the past is deterministic, without a GPU race") {
                _ = try renderer.render(input, at: 0, deadline: DispatchTime(uptimeNanoseconds: 1))
            }
            t.check(!renderer.hasVerifiedCanary, "expired deadline returns before any automatic canary submission")
            let valid = try renderer.render(input, at: 0, deadline: .now() + .seconds(30))
            check(valid, expected, width: logicalWidth, height: logicalHeight, t, "valid frame after rejected inputs")
            t.check(renderer.hasVerifiedCanary, "a pre-submission rejection does not poison later valid work")
            // In-flight GPU failure/timeout invalidation needs real device evidence; do not manufacture it with
            // a tiny scheduling race or fake Metal. Every actual GPU wait above has an explicit 30-second budget.
        }
    }

    private static func outputColorSpaceTests(_ t: AppTestRunner) {
        t.suite("Runtime: offscreen renderer: optional RGB output preserves the default sRGB bytes and rejects gray") {
            guard let device = MTLCreateSystemDefaultDevice(), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                return t.check(false, "actual Metal and named sRGB are required")
            }
            t.equal(space.model, .rgb)
            expect(.invalidInput, t, "a supplied non-RGB space cannot label a BGRA destination") {
                _ = try OffscreenRenderer(width: logicalWidth, height: logicalHeight, device: device,
                    maximumReadbackBytes: logicalWidth * logicalHeight * 4, colorSpace: CGColorSpaceCreateDeviceGray())
            }
            for scale in [1, 2] {
                let width = logicalWidth * scale, height = logicalHeight * scale
                let implicit = try OffscreenRenderer(width: width, height: height, device: device,
                                                     maximumReadbackBytes: width * height * 4)
                let explicit = try OffscreenRenderer(width: width, height: height, device: device,
                                                     maximumReadbackBytes: width * height * 4, colorSpace: space)
                t.check(!implicit.hasVerifiedCanary)
                t.check(!explicit.hasVerifiedCanary)
                var saved: [[UInt8]] = []
                for variant in [0, 1, 0] {
                    let expected = sourceBytes(variant: variant, scale: scale)
                    let first = try implicit.render(tree(bytes: expected, scale: scale), at: 0, deadline: .now() + .seconds(30))
                    let second = try explicit.render(tree(bytes: expected, scale: scale), at: 0, deadline: .now() + .seconds(30))
                    check(first, expected, width: width, height: height, t, "default RGB output at \(scale)x variant=\(variant)")
                    check(second, expected, width: width, height: height, t, "explicit sRGB output at \(scale)x variant=\(variant)")
                    t.equal(first.rgba, second.rgba, "nil and explicit sRGB output retain strict active-byte identity")
                    saved.append(second.rgba)
                }
                t.check(implicit.hasVerifiedCanary && explicit.hasVerifiedCanary)
                t.equal(saved[0], saved[2], "configured destination A/B/A returns to the original bytes")
                t.check(saved[0] != saved[1], "the explicit-output positive control actually changes bytes")
            }
        }
    }

    /// A literal asymmetric bitmap, independent of the renderer's canary and readback conversion. Its 2x image
    /// contains each literal pixel four times; neither source nor expected bytes are painted by Core Animation.
    private static func sourceBytes(variant: Int, scale: Int) -> [UInt8] {
        let palette: [[UInt8]] = [[227, 31, 71, 255], [12, 73, 103, 128], [0, 0, 0, 0],
                                 [7, 22, 3, 37], [17, 139, 61, 200], [9, 43, 231, 255]]
        let rows = variant == 0 ? [
            [0, 1, 2, 3, 4, 5, 0],
            [5, 3, 4, 1, 0, 2, 3],
            [2, 5, 1, 4, 3, 0, 4],
            [4, 0, 3, 2, 5, 1, 5],
            [1, 4, 5, 0, 2, 3, 2],
        ] : [
            [2, 2, 2, 4, 2, 2, 1],
            [2, 5, 3, 2, 0, 2, 2],
            [2, 1, 4, 5, 3, 0, 2],
            [2, 2, 0, 2, 1, 3, 2],
            [3, 2, 2, 2, 2, 2, 2],
        ]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(logicalWidth * logicalHeight * scale * scale * 4)
        for row in rows {
            for _ in 0..<scale {
                for color in row {
                    for _ in 0..<scale { bytes.append(contentsOf: palette[color]) }
                }
            }
        }
        return bytes
    }

    private static func tree(bytes: [UInt8]?, scale: Int) throws -> CALayer {
        let width = logicalWidth * scale, height = logicalHeight * scale
        let image: CGImage?
        if let bytes {
            guard bytes.count == width * height * 4,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: width * 4, space: space,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw CocoaError(.coderInvalidValue)
            }
            image = source
        } else {
            image = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let top = CALayer()
        top.anchorPoint = .zero
        top.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        top.isGeometryFlipped = true
        top.contentsFormat = .RGBA8Uint
        let root = CALayer()
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
        root.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        root.contentsFormat = .RGBA8Uint
        top.addSublayer(root)
        if let image {
            let layer = CALayer()
            layer.anchorPoint = .zero
            layer.frame = root.bounds
            layer.contentsScale = CGFloat(scale)
            layer.contentsFormat = .RGBA8Uint
            layer.contents = image
            layer.contentsGravity = .resize
            layer.magnificationFilter = .nearest
            layer.minificationFilter = .nearest
            root.addSublayer(layer)
        }
        return top
    }

    private static func checkFixture(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, _ t: AppTestRunner) {
        t.equal(a.count, width * height * 4)
        t.equal(b.count, a.count)
        t.check(a != b, "A/B control images must differ")
        t.check(a.contains { $0 != 0 } && b.contains { $0 != 0 }, "both independent bitmap controls contain ink")
        let alpha = stride(from: 3, to: a.count, by: 4).map { a[$0] }
        t.check(alpha.contains(0) && alpha.contains(255) && alpha.contains { $0 > 0 && $0 < 255 },
                "opaque, transparent and premultiplied translucent pixels are exercised")
        t.check(Array(a.prefix(width * 4)) != Array(a.suffix(width * 4)), "flipping row order changes the fixture")
        t.check(a[0] != a[2], "swapping red and blue changes the fixture")
    }

    private static func check(_ actual: OffscreenRenderer.Readback, _ expected: [UInt8], width: Int, height: Int,
                              _ t: AppTestRunner, _ note: String, line: UInt = #line) {
        t.equal(actual.width, width, note, line: line)
        t.equal(actual.height, height, note, line: line)
        t.equal(actual.rgba.count, expected.count, "\(note): active bytes only, with no row padding", line: line)
        t.check(actual.rgba == expected, "\(note): strict independent source-byte equality; "
                + difference(actual.rgba, expected), line: line)
        if expected.contains(where: { $0 != 0 }) {
            t.check(actual.rgba.contains { $0 != 0 }, "\(note): successful colored frame is not blank", line: line)
        } else {
            t.check(actual.rgba.allSatisfy { $0 == 0 }, "\(note): an empty tree clears every previous pixel", line: line)
        }
    }

    private static func difference(_ actual: [UInt8], _ expected: [UInt8]) -> String {
        guard actual.count == expected.count else { return "byte count \(actual.count), expected \(expected.count)" }
        guard let index = actual.indices.first(where: { actual[$0] != expected[$0] }) else { return "equal" }
        return "first differing byte \(index): \(actual[index]), expected \(expected[index])"
    }

    private static func expect(_ kind: FailureKind, _ t: AppTestRunner, _ note: String, line: UInt = #line,
                               _ body: () throws -> Void) {
        do {
            try body()
            t.check(false, "\(note): expected a typed failure", line: line)
        } catch let failure as Failure {
            let matches: Bool
            switch (kind, failure) {
            case (.invalidInput, .invalidInput), (.resourceLimit, .resourceLimit),
                 (.unavailable, .unavailable), (.timeout, .timeout): matches = true
            default: matches = false
            }
            t.check(matches, "\(note): unexpected failure \(failure)", line: line)
        } catch {
            t.check(false, "\(note): untyped failure \(error)", line: line)
        }
    }
}
