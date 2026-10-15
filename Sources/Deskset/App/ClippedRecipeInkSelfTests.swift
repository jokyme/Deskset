import AppKit
import CoreFoundation
import DesksetCore
import DesksetDraw
import DesksetRuntime

enum ClippedRecipeInkSelfTests {
    private typealias Rect = InkBounds.DeviceRect
    private static let maximumPixels = 40_000
    private static let maximumBytes = 160_000
    private static let scales: [CGFloat] = [1, 1.5, 2]
    private static let frame = SkinRect(x: 30.25, y: 25.375, width: 36.5, height: 24.5)
    private static let transform = ShapeTransform(a: 1, b: 0.125, c: 0.25, d: 1, tx: 3, ty: 4)

    static func run(_ t: AppTestRunner) {
        candidateTests(t)
        imageControls(t)
        graphControls(t)
    }

    private static func candidateTests(_ t: AppTestRunner) {
        t.suite("Runtime: clipped recipe ink: image candidates use explicit clips without resolving sources") {
            let target = DrawTarget(userToDevice: .identity), context = DrawContext(fonts: AppFontResolver())
            let expected = InkBounds.Candidate.rectangle(try rect(30, 25, 67, 50))
            // These synthetic paths do not exist and are never passed to drawing in this pure-query suite.
            var drawing = image(path: "unresolved-synthetic-source.png")
            func candidate(_ value: ImageDraw) -> InkBounds.Candidate {
                InkBounds.candidate(of: .image(value), context: context, target: target)
            }
            t.equal(candidate(drawing), expected, "unmasked meter retains its native clip frame without source dimensions")
            drawing.preserveAspectRatio = 1
            t.equal(candidate(drawing), expected, "fit retains the explicit clip upper bound")
            drawing.preserveAspectRatio = 2
            t.equal(candidate(drawing), expected, "fill retains the explicit clip upper bound")
            drawing.tile = true
            t.equal(candidate(drawing), expected, "meter tiles remain inside the same explicit clip")
            drawing.scaleMargins = SkinInsets(left: 3, top: 2, right: 3, bottom: 2)
            t.equal(candidate(drawing), expected, "slice margins do not require source preparation for this upper bound")
            drawing.placement = .backgroundTiled
            drawing.maskPath = "ignored-background-mask.png"
            t.equal(candidate(drawing), expected, "background tiling clips the frame and does not use the meter mask path")
            drawing.placement = .meter
            t.equal(candidate(drawing), .unknown(.unresolvedRasterization), "masked destination lacks this explicit target clip")
            drawing.placement = .backgroundNatural
            t.equal(candidate(drawing), .unknown(.unresolvedRasterization), "contentFrame is not the prepared natural extent")
            drawing = image(path: "unresolved-synthetic-source.png")
            drawing.path = nil
            t.equal(candidate(drawing), .empty, "supported image with no source has an explicit renderer early return")
            drawing.contentFrame.x = .nan
            t.equal(candidate(drawing), .unknown(.invalidGeometry), "invalid supported frame is not hidden by a missing source")
            for bad in [SkinRect(x: .nan, y: 4, width: 3, height: 2),
                        SkinRect(x: 4, y: 5, width: .infinity, height: 2),
                        SkinRect(x: .greatestFiniteMagnitude, y: 5, width: .greatestFiniteMagnitude, height: 2)] {
                drawing = image(path: "unresolved-synthetic-source.png")
                drawing.contentFrame = bad
                t.equal(candidate(drawing), .unknown(.invalidGeometry), "nonfinite edges remain typed unknown")
            }
            drawing = image(path: "unresolved-synthetic-source.png")
            drawing.contentFrame.width = 0
            t.equal(candidate(drawing), .empty, "zero computed CGRect width uses the image renderer's dimension guard")
            drawing.contentFrame.width = -1
            // CGRect.width normalizes the stored signed size; the renderer guards use that computed width.
            t.equal(candidate(drawing), .rectangle(try rect(29, 25, 31, 50)),
                    "negative stored width retains the renderer's standardized clip bounds")
            t.equal(InkBounds.candidate(of: .bevel(frame, BevelDraw(type: 1)), context: context, target: target),
                    .unknown(.unresolvedRasterization), "this slice does not infer inherited bevel stroke state")
        }
    }

    private static func imageControls(_ t: AppTestRunner) {
        t.suite("Runtime: clipped recipe ink: unmasked images preserve native alpha within observed candidates") {
            let space = try rgb(), canvas = try rect(6, 8, 198, 168)
            let path = t.temporaryDirectory("clipped-ink-image").appendingPathComponent("original.png")
            let png = try originalPNG(space)
            t.check(!png.isEmpty, "the original image canary encodes real data")
            try png.write(to: path)
            var fit = image(path: path.path), fill = fit, tiled = fit, sliced = fit, background = fit
            fit.preserveAspectRatio = 1
            fill.preserveAspectRatio = 2
            tiled.tile = true
            tiled.options.flip = .both
            sliced.scaleMargins = SkinInsets(left: 3, top: 2, right: 3, bottom: 2)
            background.placement = .backgroundTiled
            let recipes: [(String, DrawItem)] = [
                ("stretch", .image(image(path: path.path))), ("fit", .image(fit)), ("fill", .image(fill)),
                ("meter tile", .image(tiled)), ("sliced", .image(sliced)), ("background tile", .image(background)),
                ("transformed fill", .transformed(transform, [.image(fill)])),
            ]
            for scale in scales {
                for (name, item) in recipes {
                    try check(t, item, note: "\(name) at \(scale)x", canvas: canvas, scale: scale, space: space)
                }
            }
        }
    }

    private static func graphControls(_ t: AppTestRunner) {
        t.suite("Runtime: clipped recipe ink: graph clips retain aliased native snap and fixed strokes") {
            let space = try rgb(), canvas = try rect(6, 8, 198, 168)
            for antialias in [true, false] {
                let (skin, host) = try MediaUITests.bareSkin(t, graphFixture(antialias: antialias))
                defer { withExtendedLifetime(host) { skin.close() } }
                for _ in 0..<40 { skin.update() }
                guard let line = skin.meter(named: "Line") as? LineMeter,
                      let markers = skin.meter(named: "Markers") as? LineMeter,
                      let fixed = skin.meter(named: "Fixed") as? LineMeter,
                      let histogram = skin.meter(named: "Histogram") as? HistogramMeter,
                      let fallback = skin.meter(named: "Fallback") as? HistogramMeter else {
                    throw CocoaError(.coderInvalidValue)
                }
                let l = line.lower(), m = markers.lower(), f = fixed.lower()
                let h = histogram.lower(), missing = fallback.lower()
                t.equal(l.contentFrame, frame, "fractional configured frame survives lowering")
                t.equal(h.contentFrame, frame, "the histogram uses the same fractional clip fixture")
                t.equal(l.antiAlias, antialias)
                t.equal(h.antiAlias, antialias)
                t.check(l.lines.first?.isBound == true && l.historyLength > 0, "the line has real bound history")
                t.check(h.primary.isBound && h.primary.history.count >= h.historyLength,
                        "histogram history fills the whole clipped time extent")
                t.check(m.lineWidth == 0 && !m.markerCoordinates.isEmpty,
                        "marker-only control really precedes the pen guard")
                t.check(f.transformStrokeFixed && f.transformationMatrix == [1, 0.125, 0.25, 1, 3, 4],
                        "fixed stroke captures the same outer transform used by its actual recipe")
                t.check(missing.primaryImage != nil && missing.primaryColor.a > 0,
                        "missing-image histogram retains the native color-fallback recipe")
                let expectedRect: Rect
                if antialias { expectedRect = try rect(30, 25, 67, 50) }
                else { expectedRect = try rect(29, 24, 68, 51) }
                let expected = InkBounds.Candidate.rectangle(expectedRect)
                let queryContext = DrawContext(fonts: AppFontResolver()), identity = DrawTarget(userToDevice: .identity)
                for graph in [GraphDraw.line(l), .line(m), .histogram(h), .histogram(missing)] {
                    t.equal(InkBounds.candidate(of: .graph(graph), context: queryContext, target: identity), expected,
                            "AA=true keeps the frame; AA=false uses the source-gated one-user-unit envelope")
                }
                let recipes: [(String, GraphDraw, ShapeTransform?)] = [
                    ("line", .line(l), nil), ("markers without pen", .line(m), nil),
                    ("fixed transformed stroke", .line(f), transform),
                    ("histogram", .histogram(h), nil), ("missing image color fallback", .histogram(missing), nil),
                ]
                for scale in scales {
                    for (name, graph, outer) in recipes {
                        let item = outer.map { DrawItem.transformed($0, [.graph(graph)]) } ?? .graph(graph)
                        try check(t, item, note: "\(name), AA=\(antialias), \(scale)x",
                                  canvas: canvas, scale: scale, space: space) { ctx in
                            guard !antialias else { return }
                            ctx.saveGState()
                            defer { ctx.restoreGState() }
                            if let outer {
                                ctx.concatenate(CGAffineTransform(a: outer.a, b: outer.b, c: outer.c,
                                                                  d: outer.d, tx: outer.tx, ty: outer.ty))
                            }
                            let area: CGRect, direction: GraphDirection
                            switch graph {
                            case let .line(value): area = value.contentFrame.cgRect; direction = value.direction
                            case let .histogram(value): area = value.contentFrame.cgRect; direction = value.direction
                            }
                            // The clip-anchor corner is a pure value from the renderer's directional contract.
                            // Native point conversion, rounding and acceptance stay in the actual capture API.
                            let anchor = direction.vertical
                                ? CGPoint(x: direction.startRight ? area.maxX : area.minX,
                                          y: direction.flip ? area.minY : area.maxY)
                                : CGPoint(x: direction.flip ? area.maxX : area.minX,
                                          y: direction.startRight ? area.maxY : area.minY)
                            guard let delta = DrawTarget.capture(ctx, graphAnchor: anchor).graphTranslation else {
                                return t.check(false, "the aliased fixture must qualify for the actual native snap")
                            }
                            t.check(delta != .zero && abs(delta.x) < 1 && abs(delta.y) < 1,
                                    "the fractional AA=false recipe reaches the native snap path used by Rasterizer drawing")
                        }
                    }
                }
            }
        }
    }

    /// Candidate capture is on a separate native bitmap. It cannot supply a target, clip or canvas to drawing.
    private static func check(_ t: AppTestRunner, _ item: DrawItem, note: String,
                              canvas: Rect, scale: CGFloat, space: CGColorSpace,
                              qualification: ((CGContext) -> Void)? = nil) throws {
        let native = try calibration(canvas: canvas, scale: scale, space: space)
        let queryContext = DrawContext(fonts: AppFontResolver())
        let target = DrawTarget.prepareOwnedBitmap(native, glass: .none)
        t.equal(target.userToDevice, CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                     tx: -CGFloat(canvas.minX), ty: -CGFloat(canvas.minY)),
                "\(note): actual native mapping has the explicit canonical origin")
        t.check(target.colorSpace.map { CFEqual($0, space) } == true, "\(note): native target keeps the explicit profile")
        qualification?(native)
        func picture(_ context: DrawContext) throws -> CGImage {
            let owner = try Rasterizer(width: canvas.width, height: canvas.height, colorSpace: space,
                                       maximumBitmapBytes: maximumBytes)
            // The fixed canvas and original recipe are identical on both paths; no candidate is passed here.
            return try owner.image(of: [item], in: canvas, scale: scale, baseCrop: nil,
                                   context: context, cycle: 0, glass: .none)
        }
        let unqueried = try picture(DrawContext(fonts: AppFontResolver()))
        let beforeCTM = native.ctm
        let beforeMap = native.userSpaceToDeviceSpaceTransform
        let candidate = try global(InkBounds.candidate(of: item, context: queryContext, target: target), canvas: canvas)
        t.equal(native.ctm, beforeCTM, "\(note): ideal query does not mutate CTM")
        t.equal(native.userSpaceToDeviceSpaceTransform, beforeMap, "\(note): ideal query does not mutate native device mapping")
        guard case let .rectangle(inner) = candidate else {
            return t.check(false, "\(note): this supported recipe must have a nonempty known candidate: \(candidate)")
        }
        t.check(!inner.isEmpty && inner.minX > canvas.minX && inner.minY > canvas.minY
                && inner.maxX < canvas.maxX && inner.maxY < canvas.maxY,
                "\(note): candidate sits strictly inside a larger explicitly chosen canvas")
        let queried = try picture(queryContext), before = try bytes(queried)
        t.equal(before, try bytes(unqueried), "\(note): querying candidate changes no native snapshot byte")
        let observed = try scan(queried, canvas: canvas, candidate: candidate, space: space)
        t.check(observed.alphaPixels > 0 && observed.firstAlpha != nil, "\(note): actual native alpha is nonempty")
        t.equal(observed.edgePixels, 0, "\(note): this explicit canvas does not truncate observed ink at its border")
        t.equal(observed.outside, .counted(pixels: 0, first: nil), "\(note): no alpha escape is observed for this candidate")

        // This narrow negative inner is chosen before any alpha scan, independently of this recipe's bounds.
        guard let localShrink = InkBounds.deviceRectangle(covering: CGRect(x: 44, y: 34, width: 5, height: 6),
                                                          target: target),
              case let .rectangle(shrink) = try global(.rectangle(localShrink), canvas: canvas) else {
            throw CocoaError(.coderInvalidValue)
        }
        let wrong = try scan(queried, canvas: canvas, candidate: .rectangle(shrink), space: space)
        guard case let .counted(count, first) = wrong.outside else {
            return t.check(false, "\(note): fixed negative inner must produce a known observation")
        }
        t.check(count > 0 && first != nil, "\(note): fixed shrink catches actual ink outside the inner")
        if let first {
            t.check(first.alpha > 0 && !shrink.contains(x: first.globalX, y: first.globalY),
                    "\(note): first escape is real alpha outside the fixed inner: \(first)")
            let x = canvas.minX.addingReportingOverflow(first.column)
            let y = canvas.minY.addingReportingOverflow(first.row)
            t.check(!x.overflow && !y.overflow, "\(note): first-escape coordinate addition is checked")
            t.equal(first.globalX, x.partialValue, "\(note): escape keeps explicit global column")
            t.equal(first.globalY, y.partialValue, "\(note): escape keeps explicit global row")
        }
        let empty = try scan(queried, canvas: canvas, candidate: .empty, space: space)
        t.equal(empty.outside, .counted(pixels: observed.alphaPixels, first: observed.firstAlpha),
                "\(note): an empty declaration cannot hide nonempty native alpha")
        let unknown = try scan(queried, canvas: canvas, candidate: .unknown(.unresolvedRasterization), space: space)
        t.equal(unknown.outside, .unknown(.unresolvedRasterization), "\(note): observed ink does not resolve unknown")
        t.equal(try bytes(queried), before, "\(note): all observation scans leave every snapshot byte unchanged")
    }

    private static func global(_ candidate: InkBounds.Candidate, canvas: Rect) throws -> InkBounds.Candidate {
        guard case let .rectangle(local) = candidate else { return candidate }
        let edges = [(local.minX, canvas.minX), (local.minY, canvas.minY),
                     (local.maxX, canvas.minX), (local.maxY, canvas.minY)].map { edge, origin in
                         edge.addingReportingOverflow(origin)
                     }
        guard edges.allSatisfy({ !$0.overflow }),
              let global = Rect(minX: edges[0].partialValue, minY: edges[1].partialValue,
                                maxX: edges[2].partialValue, maxY: edges[3].partialValue) else {
            throw CocoaError(.coderInvalidValue)
        }
        return .rectangle(global)
    }

    private static func calibration(canvas: Rect, scale: CGFloat, space: CGColorSpace) throws -> CGContext {
        let bytes = try Rasterizer.requiredBytes(width: canvas.width, height: canvas.height)
        let (pixels, overflow) = canvas.width.multipliedReportingOverflow(by: canvas.height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard !overflow, pixels <= maximumPixels, bytes <= maximumBytes,
              let ctx = CGContext(data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8,
                                  bytesPerRow: canvas.width * 4, space: space, bitmapInfo: info),
              let actualSpace = ctx.colorSpace, CFEqual(actualSpace, space) else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.concatenate(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                          tx: -CGFloat(canvas.minX), ty: CGFloat(canvas.maxY)))
        return ctx
    }

    private static func image(path: String) -> ImageDraw {
        var options = ImageOptions()
        options.alpha = 170
        return ImageDraw(contentFrame: frame, path: path, options: options, maskPath: nil,
                         maskOptions: ImageOptions(), preserveAspectRatio: 0, tile: false,
                         scaleMargins: nil, decodesAtDrawnSize: false)
    }

    private static func originalPNG(_ space: CGColorSpace) throws -> Data {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
                                  bytesPerRow: 64, space: space, bitmapInfo: info) else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.6, blue: 0.8, alpha: 0.8))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.25, blue: 0.1, alpha: 0.65))
        ctx.fill(CGRect(x: 2, y: 3, width: 7, height: 5))
        guard let snapshot = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: snapshot).representation(using: .png, properties: [:]),
              !png.isEmpty else { throw CocoaError(.coderInvalidValue) }
        return png
    }

    private static func scan(_ image: CGImage, canvas: Rect, candidate: InkBounds.Candidate,
                             space: CGColorSpace) throws -> InkEscapeObservation.Observation {
        try InkEscapeObservation.scan(image, in: canvas, candidate: candidate, colorSpace: space,
                                      maximumPixels: maximumPixels, maximumBytes: maximumBytes)
    }

    private static func bytes(_ image: CGImage) throws -> Data {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
            throw CocoaError(.coderInvalidValue)
        }
        return withExtendedLifetime(data) { Data(bytes: pointer, count: CFDataGetLength(data)) }
    }

    private static func rgb() throws -> CGColorSpace {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.featureUnsupported) }
        return space
    }

    private static func rect(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) throws -> Rect {
        guard let result = Rect(minX: x1, minY: y1, maxX: x2, maxY: y2) else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    private static func graphFixture(antialias: Bool) -> String {
        let options = """
        X=30.25
        Y=25.375
        W=36.5
        H=24.5
        AntiAlias=\(antialias ? 1 : 0)
        """
        return """
        [Rainmeter]
        Update=-1
        [A]
        Measure=Calc
        Formula=1
        MinValue=0
        MaxValue=1
        [Line]
        Meter=Line
        MeasureName=A
        \(options)
        LineColor=50,130,210,170
        LineWidth=3
        HorizontalLines=1
        HorizontalLineColor=210,90,60,150
        [Markers]
        Meter=Line
        \(options)
        LineWidth=0
        HorizontalLines=1
        HorizontalLineColor=210,90,60,150
        [Fixed]
        Meter=Line
        MeasureName=A
        \(options)
        LineColor=50,130,210,170
        LineWidth=3
        TransformStroke=Fixed
        TransformationMatrix=1;0.125;0.25;1;3;4
        [Histogram]
        Meter=Histogram
        MeasureName=A
        \(options)
        PrimaryColor=50,130,210,170
        [Fallback]
        Meter=Histogram
        MeasureName=A
        \(options)
        PrimaryImage=missing-clipped-ink.png
        PrimaryColor=50,130,210,170
        """
    }
}
