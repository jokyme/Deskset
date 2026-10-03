import CoreFoundation
import CoreGraphics
import DesksetCore
import DesksetDraw
import DesksetRuntime
import Foundation

enum InkEscapeObservationSelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private typealias Observation = InkEscapeObservation.Observation
    private enum FailureKind { case invalidInput, resourceLimit, unsupportedImage, incompatibleColorSpace }
    private static let maximumPixels = 32_768
    private static let maximumBytes = 262_144

    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: ink escape: foreground bitmap observation is bounded and checked") {
            let space = try rgb()
            let canvas = try rect(6, 8, 126, 104), inner = try rect(18, 20, 110, 92)
            let rasterizer = try Rasterizer(width: canvas.width, height: canvas.height, colorSpace: space,
                                            maximumBitmapBytes: maximumBytes)
            let context = DrawContext(fonts: AppFontResolver())
            let scale: CGFloat = 1.5
            func picture(_ items: [DrawItem]) throws -> CGImage {
                try rasterizer.image(of: items, in: canvas, scale: scale, baseCrop: nil,
                                     context: context, cycle: 0, glass: .none)
            }
            let fill = DrawItem.fill(SkinRect(x: 16, y: 18, width: 24, height: 14),
                                     Paint(color: RGBA(r: 50, g: 130, b: 210, a: 120)))
            let transform = ShapeTransform(a: 1, b: 0.125, c: 0.25, d: 1, tx: 6, ty: 4)
            let maskFrame = SkinRect(x: 38, y: 32, width: 20, height: 14)
            let container = DrawItem.container(
                clip: maskFrame, mask: [.fill(maskFrame, Paint(color: RGBA.white))],
                content: [.fill(SkinRect(x: 25, y: 25, width: 55, height: 40),
                                Paint(color: RGBA(r: 170, g: 90, b: 40, a: 160)))])
            let recipes: [(String, [DrawItem])] = [
                ("half-transparent fill", [fill]),
                ("transformed fill", [.transformed(transform, [fill])]),
                ("whole container recipe", [container]),
            ]
            var retained: [(CGImage, Data)] = []
            var fillImage: CGImage?
            var fillObservation: Observation?
            for (note, items) in recipes {
                let image = try picture(items), before = try bytes(image)
                let observed = try scan(image, canvas: canvas, candidate: .rectangle(inner), space: space)
                t.check(observed.alphaPixels > 0 && observed.firstAlpha != nil, "\(note): real foreground alpha is present")
                t.equal(observed.outside, .counted(pixels: 0, first: nil), "\(note): no observed alpha outside this fixed inner")
                t.equal(observed.edgePixels, 0, "\(note): this fixture's canvas border is transparent")
                t.equal(observed.firstEdge, nil, "\(note): no observed border pixel")
                t.equal(try bytes(image), before, "\(note): scanning leaves every snapshot byte unchanged")
                if note == "half-transparent fill" {
                    fillImage = image
                    fillObservation = observed
                    // The frozen factory maps (x,y) to (1.5*x-6,1.5*y-8). This is also a row/alpha canary.
                    t.equal(observed.alphaPixels, 756, "the integer device fill paints 36*21 real pixels")
                    t.equal(observed.firstAlpha?.column, 18, "canonical local column")
                    t.equal(observed.firstAlpha?.row, 19, "canonical top-row index")
                    t.equal(observed.firstAlpha?.globalX, 24, "explicit global device x")
                    t.equal(observed.firstAlpha?.globalY, 27, "explicit global device y")
                    t.equal(observed.firstAlpha?.alpha, 120, "half-transparent BGRA alpha is read at byte 3")
                }
                retained.append((image, before))
            }
            guard let fillImage, let fillObservation else { throw CocoaError(.coderInvalidValue) }
            let shrunken = try rect(45, 20, 110, 92)
            let wrong = try scan(fillImage, canvas: canvas, candidate: .rectangle(shrunken), space: space)
            guard case let .counted(escaped, firstEscape) = wrong.outside else {
                return t.check(false, "a fixed known inner produces an observed escape count")
            }
            t.check(escaped > 0 && firstEscape != nil, "the fixed shrink excludes real painted fill pixels")
            if let firstEscape {
                t.check(firstEscape.alpha > 0 && !shrunken.contains(x: firstEscape.globalX, y: firstEscape.globalY),
                        "the first escape is an actual nonzero pixel outside the fixed inner")
                t.equal(firstEscape.column, 18, "first escape retains row-major column order")
                t.equal(firstEscape.row, 19, "first escape retains row-major row order")
                t.equal(firstEscape.globalX, 24, "first escape reports origin plus column")
                t.equal(firstEscape.globalY, 27, "first escape reports origin plus row")
            }
            let emptyClaim = try scan(fillImage, canvas: canvas, candidate: .empty, space: space)
            t.equal(emptyClaim.outside, .counted(pixels: fillObservation.alphaPixels, first: fillObservation.firstAlpha),
                    "an empty declaration treats every observed alpha pixel as outside")
            for reason in [InkBounds.Unknown.invalidGeometry, .invalidMapping, .unresolvedRasterization] {
                let unknown = try scan(fillImage, canvas: canvas, candidate: .unknown(reason), space: space)
                t.equal(unknown.alphaPixels, fillObservation.alphaPixels, "unknown geometry still observes actual ink")
                t.equal(unknown.outside, .unknown(reason), "unknown never becomes counted zero or an empty pass")
            }
            let emptyImage = try picture([])
            let empty = try scan(emptyImage, canvas: canvas, candidate: .empty, space: space)
            t.equal(empty.alphaPixels, 0, "an explicitly empty recipe produces this transparent snapshot")
            t.equal(empty.firstAlpha, nil, "a transparent snapshot has no observed first alpha")
            t.equal(empty.outside, .counted(pixels: 0, first: nil), "empty is an observed finite result")
            let emptyUnknown = try scan(emptyImage, canvas: canvas, candidate: .unknown(.unresolvedRasterization), space: space)
            t.equal(emptyUnknown.outside, .unknown(.unresolvedRasterization), "zero observed alpha does not resolve unknown")

            // Background is a separate recipe. Explicitly injecting it into foreground must poison this observation.
            let base = DrawItem.fill(SkinRect(x: 0, y: 0, width: 100, height: 80), Paint(color: RGBA.white))
            let baseImage = try picture([base, fill])
            let baseLeak = try scan(baseImage, canvas: canvas, candidate: .rectangle(inner), space: space)
            guard case let .counted(baseEscapes, baseFirst) = baseLeak.outside else {
                return t.check(false, "the injected base canary has known observation coordinates")
            }
            t.check(baseLeak.alphaPixels > 0 && baseEscapes > 0, "including opaque window base paints the outer ring")
            t.equal(baseFirst?.column, 0, "base leak reaches the first local pixel")
            t.equal(baseFirst?.row, 0, "base leak reaches the first local row")
            t.equal(baseFirst?.globalX, canvas.minX, "base leak keeps explicit global origin")
            t.equal(baseFirst?.globalY, canvas.minY, "base leak keeps explicit global origin")

            let clipped = try picture([.fill(SkinRect(x: 76, y: 58, width: 20, height: 18),
                                             Paint(color: RGBA(r: 20, g: 90, b: 120, a: 180)))])
            let edge = try scan(clipped, canvas: canvas, candidate: .rectangle(inner), space: space)
            t.check(edge.alphaPixels > 0 && edge.edgePixels > 0 && edge.firstEdge != nil,
                    "a fill that continues beyond this canvas records actual border ink")
            t.equal(edge.firstEdge?.column, 119, "row-major first edge is the last column")
            t.equal(edge.firstEdge?.row, 79, "row-major first edge is at global y=87")
            t.equal(edge.firstEdge?.globalX, 125, "edge report is half-open global maxX minus one")
            t.equal(edge.firstEdge?.globalY, 87, "edge report keeps canonical global row")
            t.equal(edge.firstEdge?.alpha, 180, "edge report contains real nonzero alpha")

            // A real TextDraw effect, not a copied CGContext shadow. Native qualification remains mandatory.
            try shadowControl(t, canvas: canvas, inner: inner, space: space, picture: picture)
            for (image, expected) in retained {
                t.equal(try bytes(image), expected, "later factory reuse and all scans leave retained snapshots unchanged")
            }
            try storageControls(t, space: space)
            try rejectedInputs(t, image: fillImage, canvas: canvas, inner: inner, space: space)
        }
    }

    private static func shadowControl(_ t: AppTestRunner, canvas: Rect, inner: Rect, space: CGColorSpace,
                                      picture: ([DrawItem]) throws -> CGImage) throws {
        var style = TextStyle()
        style.fontFace = "Helvetica"
        style.fontSize = 16
        style.accurateText = true
        style.antiAlias = true
        style.color = RGBA(r: 80, g: 40, b: 120, a: 0)
        style.effectColor = RGBA(r: 35, g: 130, b: 200, a: 190)
        let frame = SkinRect(x: 38, y: 30, width: 24, height: 26)
        let clip = SkinRect(x: 30, y: 26, width: 44, height: 30)
        func recipe(_ style: TextStyle) -> DrawItem {
            let text = TextDraw(text: "A", style: style, frame: frame, contentFrame: frame,
                                anchor: SkinPoint(x: frame.x, y: frame.y))
            return .container(clip: clip, mask: [.fill(clip, Paint(color: RGBA.white))], content: [.text(text)])
        }
        let plainImage = try picture([recipe(style)])
        let plain = try scan(plainImage, canvas: canvas, candidate: .rectangle(inner), space: space)
        style.effect = .shadow
        let shadowImage = try picture([recipe(style)]), before = try bytes(shadowImage)
        let shadow = try scan(shadowImage, canvas: canvas, candidate: .rectangle(inner), space: space)
        t.equal(plain.alphaPixels, 0, "the transparent foreground control has no observed ink without its effect")
        t.check(shadow.alphaPixels > 0 && shadow.firstAlpha != nil, "native shadow effect itself contributes actual alpha")
        t.check(before != (try bytes(plainImage)), "shadow qualification changes actual snapshot bytes")
        t.equal(shadow.outside, .counted(pixels: 0, first: nil), "this fixed container-shadow inner contains observed ink")
        t.equal(shadow.edgePixels, 0, "this shadow fixture does not touch the explicit canvas border")
        t.equal(try bytes(shadowImage), before, "reading shadow alpha does not mutate its snapshot")
    }

    private static func storageControls(_ t: AppTestRunner, space: CGColorSpace) throws {
        let canvas = try rect(3, 5, 5, 7)
        // Two 2-pixel rows with 4 poison padding bytes each. Alpha=1 must count; padding alpha=255 must not.
        let data = Data([0, 0, 0, 1, 0, 0, 0, 0, 255, 255, 255, 255,
                         0, 0, 0, 0, 0, 0, 0, 128, 255, 255, 255, 255])
        let image = try storedImage(data, space: space)
        let observed = try scan(image, canvas: canvas, candidate: .empty, space: space)
        t.equal(observed.alphaPixels, 2, "positive alpha byte 1 counts and poisoned row padding does not")
        t.equal(observed.firstAlpha?.alpha, 1, "first nonzero alpha is not thresholded")
        t.equal(observed.firstAlpha?.globalX, 3, "stored-row canary uses its explicit x origin")
        t.equal(observed.firstAlpha?.globalY, 5, "stored-row canary uses its explicit y origin")
        t.equal(observed.outside, .counted(pixels: 2, first: observed.firstAlpha), "empty counts only active alpha")
        t.equal(observed.edgePixels, 2, "both active canary pixels lie at this small canvas edge")
        expect(.resourceLimit, t, "the stride budget includes all row padding") {
            _ = try InkEscapeObservation.scan(image, in: canvas, candidate: .empty, colorSpace: space,
                                               maximumPixels: 4, maximumBytes: 23)
        }
        let extra = try storedImage(data + Data([0]), space: space)
        expect(.resourceLimit, t, "extra provider bytes cannot silently exceed the declared data budget") {
            _ = try InkEscapeObservation.scan(extra, in: canvas, candidate: .empty, colorSpace: space,
                                               maximumPixels: 4, maximumBytes: 24)
        }
        let rgba = try storedImage(data, space: space, bgra: false)
        expect(.unsupportedImage, t, "RGBA storage is not silently interpreted as BGRA") {
            _ = try scan(rgba, canvas: canvas, candidate: .empty, space: space)
        }
        t.equal(try bytes(image), data, "poison padding canary is not overwritten by any scan")
    }

    private static func rejectedInputs(_ t: AppTestRunner, image: CGImage, canvas: Rect,
                                       inner: Rect, space: CGColorSpace) throws {
        let wrongSize = try rect(canvas.minX, canvas.minY, canvas.maxX - 1, canvas.maxY)
        expect(.invalidInput, t, "a snapshot is not relabelled as a different canvas size") {
            _ = try scan(image, canvas: wrongSize, candidate: .rectangle(inner), space: space)
        }
        expect(.invalidInput, t, "an empty canvas is unavailable, not an observed transparent image") {
            _ = try scan(image, canvas: rect(0, 0, 0, 1), candidate: .empty, space: space)
        }
        for limit in [0, -1] {
            expect(.invalidInput, t, "pixel budget must be explicitly positive") {
                _ = try InkEscapeObservation.scan(image, in: canvas, candidate: .empty, colorSpace: space,
                                                   maximumPixels: limit, maximumBytes: maximumBytes)
            }
            expect(.invalidInput, t, "byte budget must be explicitly positive") {
                _ = try InkEscapeObservation.scan(image, in: canvas, candidate: .empty, colorSpace: space,
                                                   maximumPixels: maximumPixels, maximumBytes: limit)
            }
        }
        expect(.resourceLimit, t, "a finite real image cannot bypass the pixel budget") {
            _ = try InkEscapeObservation.scan(image, in: canvas, candidate: .rectangle(inner), colorSpace: space,
                                               maximumPixels: 1, maximumBytes: maximumBytes)
        }
        for huge in [try rect(0, 0, Int.max, 2), try rect(0, 0, Int.max / 4 + 1, 1)] {
            expect(.resourceLimit, t, "logical canvas preflight rejects checked products without giant allocation") {
                _ = try InkEscapeObservation.scan(image, in: huge, candidate: .empty, colorSpace: space,
                                                   maximumPixels: Int.max, maximumBytes: Int.max)
            }
        }
        guard let other = CGColorSpace(name: CGColorSpace.displayP3) else { throw CocoaError(.featureUnsupported) }
        expect(.incompatibleColorSpace, t, "a different explicit profile is not replaced by the snapshot profile") {
            _ = try scan(image, canvas: canvas, candidate: .rectangle(inner), space: other)
        }
    }

    private static func scan(_ image: CGImage, canvas: Rect, candidate: InkBounds.Candidate,
                             space: CGColorSpace) throws -> Observation {
        try InkEscapeObservation.scan(image, in: canvas, candidate: candidate, colorSpace: space,
                                      maximumPixels: maximumPixels, maximumBytes: maximumBytes)
    }

    private static func bytes(_ image: CGImage) throws -> Data {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
            throw CocoaError(.coderInvalidValue)
        }
        return withExtendedLifetime(data) { Data(bytes: pointer, count: CFDataGetLength(data)) }
    }

    private static func storedImage(_ data: Data, space: CGColorSpace, bgra: Bool = true) throws -> CGImage {
        let info = bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.coderInvalidValue)
        }
        return image
    }

    private static func rgb() throws -> CGColorSpace {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.featureUnsupported) }
        return space
    }

    private static func rect(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) throws -> Rect {
        guard let result = Rect(minX: x1, minY: y1, maxX: x2, maxY: y2) else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    private static func expect(_ kind: FailureKind, _ t: AppTestRunner, _ note: String,
                               _ body: () throws -> Void) {
        do {
            try body()
            t.check(false, "\(note): expected an observation failure")
        } catch let error as InkEscapeObservation.Failure {
            let matches: Bool
            switch (kind, error) {
            case (.invalidInput, .invalidInput), (.resourceLimit, .resourceLimit),
                 (.unsupportedImage, .unsupportedImage), (.incompatibleColorSpace, .incompatibleColorSpace):
                matches = true
            default: matches = false
            }
            t.check(matches, "\(note): actual \(error)")
        } catch {
            t.check(false, "\(note): unexpected error \(error)")
        }
    }
}
