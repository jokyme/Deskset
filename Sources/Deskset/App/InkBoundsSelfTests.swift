import AppKit
import DesksetCore
import DesksetDraw

enum InkBoundsSelfTests {
    static func run(_ t: AppTestRunner) {
        mappingTests(t)
        invalidTests(t)
        geometryTests(t)
        rasterControls(t)
    }

    private static func mappingTests(_ t: AppTestRunner) {
        t.suite("Runtime: ink bounds: device rectangles keep density, phase, shear and reflected axes") {
            let cases: [(CGAffineTransform, InkBounds.DeviceRect?)] = [
                (.identity, .init(minX: 1, minY: 2, maxX: 6, maxY: 10)),
                (.init(a: 2, b: 0, c: 0, d: 2, tx: 0.125, ty: 0.625),
                 .init(minX: 2, minY: 5, maxX: 11, maxY: 21)),
                (.init(a: 1.5, b: 0, c: 0, d: -1.5, tx: 0.625, ty: 64.125),
                 .init(minX: 2, minY: 49, maxX: 9, maxY: 61)),
                (.init(a: -1, b: 0, c: 0, d: 1, tx: -0.625, ty: -0.125),
                 .init(minX: -6, minY: 2, maxX: -1, maxY: 10)),
                (.init(a: 1, b: 0.5, c: -0.25, d: 1, tx: 2, ty: -3),
                 .init(minX: 0, minY: 0, maxX: 7, maxY: 10)),
            ]
            let rect = CGRect(x: 1.25, y: 2.5, width: 4, height: 7.25)
            for (mapping, expected) in cases {
                let target = DrawTarget(userToDevice: mapping)
                let actual = InkBounds.deviceRectangle(covering: rect, target: target)
                t.equal(actual, expected, "all four mapped corners are rounded outward")
                guard let actual else { continue }
                let padded = InkBounds.deviceRectangle(covering: rect, target: target, padding: 2)
                t.equal(padded, InkBounds.DeviceRect(minX: actual.minX - 2, minY: actual.minY - 2,
                                                    maxX: actual.maxX + 2, maxY: actual.maxY + 2),
                        "padding uses device pixels after the transform")
                t.equal(InkBounds.deviceRectangle(covering: CGRect(x: rect.maxX, y: rect.maxY,
                                                                   width: -rect.width, height: -rect.height),
                                                  target: target), actual,
                        "negative dimensions cover the standardized geometry")
                let empty = InkBounds.deviceRectangle(covering: CGRect(x: 2.25, y: 3.5, width: 0, height: 8),
                                                      target: target, padding: 2)
                t.check(empty?.isEmpty == true, "padding does not turn empty geometry into ink")
                t.check(actual.contains(x: actual.minX, y: actual.minY), "leading pixel is inside")
                t.check(!actual.contains(x: actual.maxX, y: actual.minY)
                        && !actual.contains(x: actual.minX, y: actual.maxY), "trailing edges are half-open")
            }

            // Native device conversion is checked independently of the implementation's affine arithmetic.
            let transforms = [CGAffineTransform.identity,
                              .init(a: 2, b: 0, c: 0, d: -2, tx: 0.125, ty: 96.625),
                              .init(a: 1.5, b: 0.25, c: -0.375, d: 1, tx: -2.125, ty: 3.625)]
            for transform in transforms {
                let ctx = try bitmap()
                ctx.concatenate(transform)
                let target = DrawTarget.capture(ctx, glass: .none)
                guard let actual = InkBounds.deviceRectangle(covering: rect, target: target) else {
                    t.check(false, "a finite native mapping produces a candidate")
                    continue
                }
                let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                    .map { ctx.convertToDeviceSpace($0) }
                for point in corners {
                    t.check(CGFloat(actual.minX) <= point.x && point.x <= CGFloat(actual.maxX)
                            && CGFloat(actual.minY) <= point.y && point.y <= CGFloat(actual.maxY),
                            "native transformed corners lie within the closed geometric edges")
                }
                t.equal(ctx.ctm, transform, "calculating bounds does not mutate the destination")
            }
        }
    }

    private static func invalidTests(_ t: AppTestRunner) {
        t.suite("Runtime: ink bounds: invalid geometry and integer overflow never become an empty pass") {
            let identity = DrawTarget(userToDevice: .identity)
            let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
            for invalid in [CGRect.null, .infinite,
                            CGRect(x: CGFloat.nan, y: 0, width: 2, height: 2),
                            CGRect(x: 0, y: CGFloat.infinity, width: 2, height: 2),
                            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                                   width: CGFloat.greatestFiniteMagnitude, height: 1),
                            CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1)] {
                t.equal(InkBounds.deviceRectangle(covering: invalid, target: identity), nil,
                        "invalid or unrepresentable geometry is rejected")
            }
            for invalid in [CGAffineTransform(a: 0, b: 0, c: 0, d: 1, tx: 0, ty: 0),
                            .init(a: 1, b: 1, c: 1, d: 1, tx: 0, ty: 0),
                            .init(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0),
                            .init(a: 1, b: 0, c: 0, d: 1, tx: .infinity, ty: 0),
                            .init(a: .greatestFiniteMagnitude, b: 0, c: 0, d: 1, tx: 0, ty: 0)] {
                t.equal(InkBounds.deviceRectangle(covering: rect, target: DrawTarget(userToDevice: invalid)), nil,
                        "nonfinite, singular or overflowing destination mappings are unknown")
            }
            t.equal(InkBounds.deviceRectangle(covering: rect, target: identity, padding: -1), nil,
                    "negative padding is rejected")
            t.equal(InkBounds.deviceRectangle(covering: rect, target: identity, padding: Int.max), nil,
                    "padding overflow is rejected")
            t.equal(InkBounds.DeviceRect(minX: 3, minY: 0, maxX: 2, maxY: 1), nil, "reversed edges are rejected")
            t.equal(InkBounds.DeviceRect(minX: Int.min, minY: 0, maxX: Int.max, maxY: 1), nil,
                    "a dimension overflowing Int is rejected")
            let largest = InkBounds.DeviceRect(minX: 0, minY: 0, maxX: Int.max, maxY: 1)
            t.equal(largest?.width, Int.max, "the largest representable dimension does not overflow")
            t.check(largest?.contains(x: Int.max - 1, y: 0) == true, "the last representable covered pixel is inside")
            t.check(largest?.contains(x: Int.max, y: 0) == false, "the exclusive maximum is outside")
        }
    }

    private static func geometryTests(_ t: AppTestRunner) {
        t.suite("Runtime: ink bounds: ideal candidates keep unknown text distinct from empty drawings") {
            let context = DrawContext(fonts: AppFontResolver())
            let target = DrawTarget(userToDevice: .identity)
            let frame = SkinRect(x: 12.25, y: 20.5, width: 28, height: 16)
            let text = TextDraw(text: "A😀", style: TextStyle(), frame: frame, contentFrame: frame,
                                anchor: SkinPoint(x: frame.x, y: frame.y))
            t.equal(InkBounds.candidate(of: .text(text), context: context, target: target),
                    .unknown(.unresolvedRasterization), "native glyph geometry is not claimed to cover raster ink")
            t.equal(InkBounds.candidate(of: .antialias(false, [.text(text)]), context: context, target: target),
                    .unknown(.unresolvedRasterization), "disabling antialiasing does not resolve native glyph bounds")
            t.equal(InkBounds.candidate(of: .transformed(.identity, []), context: context, target: target),
                    .empty, "an empty group is explicitly empty")
            t.equal(InkBounds.candidate(of: .fill(SkinRect(x: 4, y: 8), Paint(color: RGBA.white)),
                                       context: context, target: target, padding: 2), .empty,
                    "a zero-area fill is not padded into a partition")
            t.equal(InkBounds.candidate(of: .fill(SkinRect(x: .nan, y: 8, width: 3, height: 4),
                                                  Paint(color: RGBA.white)), context: context, target: target),
                    .unknown(.invalidGeometry), "invalid geometry stays unknown")
            t.equal(InkBounds.candidate(of: .fill(frame, Paint(color: RGBA.white)), context: context,
                                       target: DrawTarget(userToDevice: .init(a: 0, b: 0, c: 0, d: 1, tx: 0, ty: 0))),
                    .unknown(.invalidMapping), "a singular destination cannot supply a device rectangle")
        }
    }

    private static func bitmap() throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw NSError(domain: "InkBoundsSelfTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the named-sRGB test bitmap could not be created"])
        }
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx
    }

    private static func rasterControls(_ t: AppTestRunner) {
        t.suite("Runtime: ink bounds: geometry queries preserve drawing and escaped alpha is detected") {
            let calibration = try bitmap()
            calibration.setFillColor(CGColor(gray: 1, alpha: 1))
            calibration.fill(CGRect(x: 9, y: 7, width: 5, height: 3))
            // This raw bitmap keeps CoreGraphics' y-up user space. Memory row zero is the top device row.
            let calibrated = try coverage(.rectangle(.init(minX: 9, minY: calibration.height - 10,
                                                           maxX: 14, maxY: calibration.height - 7)!), calibration)
            t.equal(calibration.userSpaceToDeviceSpaceTransform,
                    CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(calibration.height)),
                    "the owned bitmap exposes the native y-up to memory-row mapping")
            t.equal(calibrated.visible, 15, "native integer rectangle establishes the alpha-row coordinate convention")
            t.equal(calibrated.escaped, 0, "the scanned memory rows match captured device coordinates")

            let (skin, host) = try MediaUITests.bareSkin(t, """
            [Rainmeter]
            Update=-1
            [Drawing]
            Meter=Shape
            X=14.25
            Y=18.5
            Shape=Rectangle 0,0,34,22,4 | Fill LinearGradient Paint | StrokeWidth 3 | Stroke Color 220,90,40,190
            Paint=270 | 20,90,160,160 ; 0 | 90,180,220,220 ; 1
            """)
            defer { withExtendedLifetime(host) { skin.close() } }
            skin.update()
            guard let shape = skin.meter(named: "Drawing") as? ShapeMeter else {
                return t.check(false, "the original shape parser builds the geometry fixture")
            }
            t.equal(shape.contentFrame.x, 14.25, "the shape is laid out before its drawing value is captured")
            t.equal(shape.contentFrame.y, 18.5, "the shape keeps its configured content origin")
            let frame = SkinRect(x: 14.25, y: 18.5, width: 34, height: 22)
            let fill = DrawItem.fill(frame, Paint(color: RGBA(r: 50, g: 130, b: 210, a: 170)))
            let transform = ShapeTransform(a: 1, b: 0.125, c: 0.25, d: 1, tx: 8, ty: 5)
            let recipes: [DrawItem] = [
                fill,
                .transformed(transform, [.antialias(false, [fill])]),
                .shape(shape.lower()),
                .bar(BarDraw(visibleRects: [frame], imageRect: nil, path: nil, options: ImageOptions(),
                             color: RGBA(r: 210, g: 90, b: 40, a: 180))),
                .roundline(RoundlineDraw(shape: .line(x1: 18.25, y1: 22.5, x2: 46.5, y2: 42.25, width: 3),
                                        color: RGBA(r: 70, g: 180, b: 110), antiAlias: true)),
                .roundline(RoundlineDraw(shape: .sector(centerX: 34.25, centerY: 38.5, innerRadius: 8, outerRadius: 15,
                                                       startAngle: 0.15, sweep: 1.8),
                                        color: RGBA(r: 70, g: 180, b: 110), antiAlias: true)),
                .container(clip: frame, mask: [fill],
                           content: [.fill(SkinRect(x: 8, y: 10, width: 60, height: 50),
                                           Paint(color: RGBA(r: 170, g: 110, b: 220, a: 210)))]),
            ]
            let scales: [CGFloat] = [1, 1.5, 2]
            let phases: [CGFloat] = [0.125, 0.625]
            for scale in scales {
                for phase in phases {
                    for recipe in recipes {
                        let queried = try bitmap(), unqueried = try bitmap()
                        for ctx in [queried, unqueried] {
                            ctx.translateBy(x: phase, y: phase)
                            ctx.scaleBy(x: scale, y: scale)
                        }
                        let target = DrawTarget.prepareOwnedBitmap(queried, glass: .none)
                        let context = DrawContext(fonts: AppFontResolver())
                        let candidate = InkBounds.candidate(of: recipe, context: context, target: target, padding: 2)
                        guard case .rectangle = candidate else {
                            t.check(false, "a supported finite recipe supplies a device candidate: \(candidate)")
                            continue
                        }
                        DesksetDraw.DrawExecutor.draw([recipe], in: queried, context: context, cycle: 0, target: target)
                        let control = DrawTarget.prepareOwnedBitmap(unqueried, glass: .none)
                        DesksetDraw.DrawExecutor.draw([recipe], in: unqueried, context: DrawContext(fonts: AppFontResolver()),
                                          cycle: 0, target: control)
                        t.equal(try packedBytes(queried), try packedBytes(unqueried),
                                "warming geometry does not change any drawn byte")
                        let actual = try coverage(candidate, queried)
                        t.check(actual.visible > 0, "the raster control has real visible pixels")
                        t.equal(actual.edge, 0, "the outer canvas does not hide escaped ink")
                        t.equal(actual.escaped, 0, "no positive alpha lies outside this fixture's declared candidate")
                        let wrong = try coverage(.empty, queried)
                        t.equal(wrong.escaped, actual.visible, "an intentionally empty declaration detects every ink pixel")
                    }
                }
            }

            let frameForText = SkinRect(x: 20, y: 30, width: 80, height: 25)
            let text = DrawItem.text(TextDraw(text: "A😀", style: TextStyle(), frame: frameForText,
                                             contentFrame: frameForText, anchor: SkinPoint(x: 20, y: 30)))
            let ctx = try bitmap(), context = DrawContext(fonts: AppFontResolver())
            let target = DrawTarget.prepareOwnedBitmap(ctx, glass: .none)
            let candidate = InkBounds.candidate(of: text, context: context, target: target, padding: 2)
            t.equal(candidate, .unknown(.unresolvedRasterization), "padding never qualifies a native glyph candidate")
            DesksetDraw.DrawExecutor.draw([text], in: ctx, context: context, cycle: 0, target: target)
            t.check(try coverage(.empty, ctx).visible > 0, "unknown bounds leave native glyph drawing intact")
        }
    }

    /// Independent raster evidence for these owned RGBA8 controls. It is not used to compute a candidate.
    private static func coverage(_ candidate: InkBounds.Candidate, _ ctx: CGContext) throws
        -> (visible: Int, escaped: Int, edge: Int) {
        if case .unknown = candidate {
            throw NSError(domain: "InkBoundsSelfTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "unknown coverage cannot be counted as contained"])
        }
        guard ctx.bitsPerComponent == 8, ctx.bitsPerPixel == 32, ctx.alphaInfo == .premultipliedLast,
              ctx.bitmapInfo.contains(.byteOrder32Big), let bytes = ctx.data else {
            throw NSError(domain: "InkBoundsSelfTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected alpha bitmap layout"])
        }
        var visible = 0, escaped = 0, edge = 0
        for y in 0..<ctx.height {
            let row = bytes.advanced(by: y * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<ctx.width where row[x * 4 + 3] > 0 {
                visible += 1
                if x == 0 || y == 0 || x == ctx.width - 1 || y == ctx.height - 1 { edge += 1 }
                switch candidate {
                case .empty: escaped += 1
                case let .rectangle(rect): if !rect.contains(x: x, y: y) { escaped += 1 }
                case .unknown:
                    throw NSError(domain: "InkBoundsSelfTests", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "unknown coverage cannot be counted as contained"])
                }
            }
        }
        return (visible, escaped, edge)
    }

    private static func packedBytes(_ ctx: CGContext) throws -> Data {
        guard let data = ctx.data else {
            throw NSError(domain: "InkBoundsSelfTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "the owned bitmap has no readable data"])
        }
        var result = Data()
        for y in 0..<ctx.height {
            result.append(data.advanced(by: y * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: ctx.width * 4)
        }
        return result
    }
}
