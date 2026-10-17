import AppKit
import DesksetCore
import DesksetDraw

enum ShapeDrawValueSelfTests {
    private static let canvasWidth = 200, canvasHeight = 150
    private static let formats = [(scale: 1, bgra: false), (scale: 1, bgra: true),
                                  (scale: 2, bgra: false), (scale: 2, bgra: true)]

    private struct Sample {
        let draw: ShapeDraw
        let pixels: [Data]
    }

    static func run(_ t: AppTestRunner) {
        drawingTests(t)
        cacheTests(t)
        geometryTests(t)
    }

    private static func drawingTests(_ t: AppTestRunner) {
        t.suite("Runtime: shape lowering: captured geometry, paint and placement survive updates and owner release") {
            weak var releasedSkin: Skin?
            weak var releasedMeter: ShapeMeter?
            let context = SkinRenderContext()
            let saved = try autoreleasepool { () throws -> [Sample] in
                let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                Update=-1
                [Variables]
                Width=50
                Hole=16
                [Level]
                Measure=Calc
                Formula=#Width#
                DynamicVariables=1
                [Drawing]
                Meter=Shape
                X=18.25
                Y=16.5
                Padding=3,4,5,6
                DynamicVariables=1
                Shape=Rectangle 0,0,[Level],40,5 | Fill LinearGradient Paint | StrokeWidth 3 | Stroke Color 40,50,80,190
                Shape2=Ellipse 28,20,#Hole#
                Shape3=Combine Shape | Exclude Shape2
                Shape4=Path Trace | StrokeWidth 3 | Stroke Color 220,80,40,180 | StrokeDashes 2,1 | StrokeStartCap Round | StrokeEndCap Round
                Shape5=Rectangle -8,66,30,8 | Fill Color 40,160,220,200 | StrokeWidth 0
                Paint=30 | 0,150,210,190 ; 0 | 255,80,120,230 ; 1
                Trace=0,55 | LineTo 24,48 | LineTo 48,58
                [Other]
                Meter=Shape
                X=18.25
                Y=16.5
                DynamicVariables=1
                Shape=Ellipse (20+[Level]/10),25,18,10 | Fill Color 40,220,140,210 | StrokeWidth 4
                Shape2=Rectangle 5,52,35,14,4 | Fill Color 180,80,220,230 | StrokeWidth 0
                """)
                defer { withExtendedLifetime(host) { skin.close() } }
                skin.update()
                guard let meter = skin.meter(named: "Drawing") as? ShapeMeter,
                      let other = skin.meter(named: "Other") as? ShapeMeter else {
                    throw CocoaError(.coderInvalidValue)
                }
                releasedSkin = skin
                releasedMeter = meter
                let integrationStorage = NSObject()
                meter.renderCache = integrationStorage

                func capture(_ meter: ShapeMeter) throws -> Sample {
                    let draw = meter.lower()
                    let pictures = try formats.map { format in
                        let current = try pixels(format) { SkinRenderer.drawShape(draw, $0, context) }
                        t.check(current.contains { $0 != 0 }, "the shape draws visible pixels")
                        #if DEBUG
                        let reference = try pixels(format) { LegacySkinRenderer.drawShape(meter, $0) }
                        t.check(current == reference, "\(meter.name) \(format): exact frozen-renderer pixels")
                        #endif
                        return current
                    }
                    return Sample(draw: draw, pixels: pictures)
                }

                let original = try capture(meter), independent = try capture(other)
                t.equal(original.draw, meter.lower(), "capturing an unchanged meter reuses its payload identity")
                t.equal(original.draw.revision, independent.draw.revision, "both meters began at the same revision")
                t.check(original.draw.sourceID != independent.draw.sourceID, "distinct meters have distinct drawing identities")
                t.check(original.pixels != independent.pixels, "same-revision fixtures draw different shapes")
                let adapted = try pixels(formats[0]) { SkinRenderer.drawShape(meter, $0) }
                t.check(adapted == original.pixels[0], "the meter entry point forwards the same captured drawing")
                t.check(meter.renderCache === integrationStorage, "drawing does not read or replace meter-owned storage")
                let originalBuilt = ShapeCG.built(for: original.draw, in: context)

                skin.perform(Bang(name: "setoption", args: ["Drawing", "X", "45.75"]))
                skin.perform(Bang(name: "setoption", args: ["Drawing", "Y", "29.25"]))
                skin.update()
                let moved = try capture(meter)
                t.equal(moved.draw.revision, original.draw.revision, "moving does not change parsed geometry")
                t.check(moved.draw != original.draw, "placement participates in drawing equality")
                t.check(moved.pixels != original.pixels, "the same geometry draws at its new content origin")
                let movedBuilt = ShapeCG.built(for: moved.draw, in: context)
                t.check(!originalBuilt.isEmpty && originalBuilt.count == movedBuilt.count
                        && zip(originalBuilt, movedBuilt).allSatisfy { $0.region === $1.region },
                        "moving reuses every prepared path")

                skin.setVariable("Width", "74")
                skin.setVariable("Hole", "11")
                skin.perform(Bang(name: "setoption", args: ["Drawing", "Shape3", "Combine Shape | Union Shape2"]))
                skin.perform(Bang(name: "setoption", args: ["Drawing", "Paint",
                    "65 | 220,80,20,210 ; 0 | 60,180,100,170 ; 1"]))
                skin.update()
                let changed = try capture(meter)
                t.equal(changed.draw.sourceID, original.draw.sourceID, "updates keep the source identity")
                t.check(changed.draw.revision != original.draw.revision, "changed geometry and paint have a new revision")
                t.check(changed.pixels != moved.pixels, "changing the measure, gradient and Combine changes the drawing")
                let changedBuilt = ShapeCG.built(for: changed.draw, in: context)
                guard let oldTrace = originalBuilt.first(where: { $0.item.index == 4 }),
                      let newTrace = changedBuilt.first(where: { $0.item.index == 4 }),
                      let oldCombined = originalBuilt.first(where: { $0.item.index == 3 }),
                      let newCombined = changedBuilt.first(where: { $0.item.index == 3 }) else {
                    t.check(false, "combined and unchanged shapes are built")
                    return []
                }
                t.check(oldTrace.region === newTrace.region, "an unchanged item reuses its prepared path across revisions")
                t.check(oldCombined.region !== newCombined.region, "changed Combine geometry gets another path")

                for sample in [original, changed, independent, moved, original, independent, changed] {
                    for (index, format) in formats.enumerated() {
                        let current = try pixels(format) { SkinRenderer.drawShape(sample.draw, $0, context) }
                        t.check(current == sample.pixels[index], "old, new and independent values alternate without cache collisions")
                    }
                    t.equal(context.shapes.count, 2, "one cache entry per source, regardless of the revision drawn")
                }
                return [original, moved, changed, independent]
            }
            t.check(releasedSkin == nil && releasedMeter == nil, "drawing values and the warm context retain no owner")
            t.equal(saved.count, 4, "old, moved, changed and independent drawings were captured")
            let cold = SkinRenderContext()
            for sample in saved {
                for (index, format) in formats.enumerated() {
                    let current = try pixels(format) { SkinRenderer.drawShape(sample.draw, $0, cold) }
                    t.check(current == sample.pixels[index], "a cold context draws the saved geometry after its owner is released")
                }
            }
        }
    }

    private static func cacheTests(_ t: AppTestRunner) {
        t.suite("Runtime: shape lowering: context caches keep one revision per source and evict least-used sources") {
            let (skin, host) = try MediaUITests.bareSkin(t, """
            [Rainmeter]
            Update=-1
            [Drawing]
            Meter=Shape
            Shape=Rectangle 0,0,24,18,4 | Fill Color 70,140,220,190 | StrokeWidth 2
            """)
            defer { withExtendedLifetime(host) { skin.close() } }
            skin.update()
            guard let meter = skin.meter(named: "Drawing") as? ShapeMeter else { throw CocoaError(.coderInvalidValue) }
            let value = meter.lower()
            let context = SkinRenderContext()
            let first = ShapeDraw(shapes: value.shapes, contentFrame: value.contentFrame)
            let second = ShapeDraw(shapes: value.shapes, contentFrame: value.contentFrame)
            guard let a = ShapeCG.built(for: first, in: context).first?.region,
                  let b = ShapeCG.built(for: second, in: context).first?.region else {
                return t.check(false, "prepared cache entries")
            }
            for _ in 0..<(SkinRenderContext.maxShapeSources - 2) {
                let next = ShapeDraw(shapes: value.shapes, contentFrame: value.contentFrame)
                _ = ShapeCG.built(for: next, in: context)
            }
            t.equal(context.shapes.count, SkinRenderContext.maxShapeSources)
            t.check(ShapeCG.built(for: first, in: context).first?.region === a, "a warm source reuses its paths")
            _ = ShapeCG.built(for: ShapeDraw(shapes: value.shapes, contentFrame: value.contentFrame), in: context)
            t.equal(context.shapes.count, SkinRenderContext.maxShapeSources, "another source evicts one entry")
            t.check(ShapeCG.built(for: first, in: context).first?.region === a, "recent use keeps the first source")
            t.check(ShapeCG.built(for: second, in: context).first?.region !== b, "the least-used source was evicted and rebuilt")
            t.equal(context.shapes.count, SkinRenderContext.maxShapeSources, "rebuilding an evicted source stays bounded")

            let revisions = SkinRenderContext()
            for step in 0..<12 {
                skin.perform(Bang(name: "setoption", args: ["Drawing", "Shape",
                    "Rectangle 0,0,\(24 + step),18,4 | Fill Color 70,140,220,190 | StrokeWidth 2"]))
                skin.update()
                _ = ShapeCG.built(for: meter.lower(), in: revisions)
            }
            t.equal(revisions.shapes.count, 1, "a changing source retains only its latest prepared revision")

            weak var released: ShapeCG.Cache?
            autoreleasepool {
                let temporary = SkinRenderContext()
                released = temporary.shapes
                _ = ShapeCG.built(for: value, in: temporary)
            }
            t.check(released == nil, "prepared paths leave with their drawing context")
        }
    }

    private static func geometryTests(_ t: AppTestRunner) {
        t.suite("Runtime: shape ink geometry: prepared paths cover pixels without changing drawing") {
            for format in formats {
                // Verify the active bytes' top-left row order and alpha channel before testing geometry.
                let rect = CGRect(x: 13, y: 7, width: 2, height: 3)
                let sentinel = try pixels(format) { ctx in
                    ctx.setShouldAntialias(false)
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                    ctx.fill(rect)
                }
                let expected = pixelBounds(rect, scale: format.scale)
                let first = firstAlpha(sentinel, scale: format.scale, outside: .null)
                t.check(first?.x == Int(expected.minX) && first?.y == Int(expected.minY) && first?.alpha == 255,
                        "\(format): the scanner sees the probe's top-left opaque pixel: \(String(describing: first))")
                let last = ((Int(expected.maxY) - 1) * canvasWidth * format.scale + Int(expected.maxX) - 1) * 4 + 3
                t.equal(sentinel[last], 255, "\(format): the probe reaches its bottom-right pixel")
                t.check(firstAlpha(sentinel, scale: format.scale, outside: expected) == nil,
                        "\(format): the probe has no alpha outside its known rectangle")
            }

            weak var releasedSkin: Skin?
            weak var releasedMeter: ShapeMeter?
            let context = SkinRenderContext()
            let saved = try autoreleasepool { () throws -> [(draw: ShapeDraw, bounds: CGRect, pixels: [Data])] in
                let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                Update=-1
                [Variables]
                Width=12
                [Drawing]
                Meter=Shape
                X=35.25
                Y=36.5
                W=18
                H=12
                Padding=3,4,0,0
                DynamicVariables=1
                Shape=Path Star | Fill Color 60,130,210,150 | StrokeWidth 8 | Stroke Color 230,60,60,160 | StrokeLineJoin Miter, 8
                Star=25,0 | LineTo 40,48 | LineTo 0,18 | LineTo 50,18 | LineTo 10,48 | ClosePath 1
                Shape2=Rectangle 60,16,10,10
                Shape3=Combine Shape | Union Shape2
                Shape4=Line -16,62,82,62 | StrokeWidth 10 | Stroke Color 30,90,180,180 | StrokeStartCap Triangle | StrokeEndCap Round | StrokeDashes 2,1 | StrokeDashCap Round
                Shape5=Ellipse 83,10,12,9 | Fill Color 100,150,80,120 | StrokeWidth 6 | Stroke Color 30,80,40,220 | StrokeType Outer
                Shape6=Rectangle -18,20,16,15 | Fill Color 200,120,60,160 | StrokeWidth 6 | Stroke Color 120,60,20,200 | StrokeType Inner
                Shape7=Rectangle 94,35,#Width#,16 | Fill Color 160,90,210,200 | StrokeWidth 2
                """)
                defer { withExtendedLifetime(host) { skin.close() } }
                skin.update()
                guard let meter = skin.meter(named: "Drawing") as? ShapeMeter else {
                    throw CocoaError(.coderInvalidValue)
                }
                releasedSkin = skin
                releasedMeter = meter
                t.equal(meter.shapes.map(\.index), [3, 4, 5, 6, 7], "Combine and each stroke fixture were parsed")

                func capture(_ label: String) throws -> (draw: ShapeDraw, bounds: CGRect, pixels: [Data]) {
                    let draw = meter.lower()
                    let bounds = DesksetDraw.ShapeRenderer.geometryBounds(draw, context: context.drawing)
                    t.check(!bounds.isNull && [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
                            "\(label): prepared geometry has finite bounds: \(bounds)")
                    let frame = CGRect(x: meter.frame.x, y: meter.frame.y,
                                       width: meter.frame.width, height: meter.frame.height)
                    let estimate = draw.shapes.reduce(CGRect.null) { result, item in
                        let rect = item.visualBounds
                        return result.union(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
                    }.offsetBy(dx: draw.contentFrame.x, dy: draw.contentFrame.y)
                    let pictures = try formats.map { format in
                        let note = "\(label), \(format)"
                        let direct = try pixels(format) { SkinRenderer.drawShape(draw, $0, SkinRenderContext()) }
                        let preparedContext = SkinRenderContext()
                        t.equal(preparedContext.shapes.count, 0, "\(note): this format starts with a cold shape cache")
                        let preparedBounds = DesksetDraw.ShapeRenderer.geometryBounds(draw, context: preparedContext.drawing)
                        t.equal(preparedBounds, bounds, "\(note): independent contexts compute the same geometry")
                        let prepared = try pixels(format) { SkinRenderer.drawShape(draw, $0, preparedContext) }
                        t.check(prepared == direct, "\(note): querying before drawing preserves every active byte")
                        t.equal(DesksetDraw.ShapeRenderer.geometryBounds(draw, context: preparedContext.drawing), bounds,
                                "\(note): querying a warm cache keeps the same bounds")
                        let warm = try pixels(format) { SkinRenderer.drawShape(draw, $0, preparedContext) }
                        t.check(warm == prepared, "\(note): repeated queries preserve every active byte")
                        #if DEBUG
                        let reference = try pixels(format) { LegacySkinRenderer.drawShape(meter, $0) }
                        t.check(prepared == reference, "\(note): exact frozen-renderer pixels after preparation")
                        #endif

                        let deviceBounds = pixelBounds(preparedBounds, scale: format.scale)
                        let first = firstAlpha(prepared, scale: format.scale, outside: .null)
                        t.check(first != nil, "\(note): the fixture paints nontransparent pixels")
                        let escape = firstAlpha(prepared, scale: format.scale, outside: deviceBounds)
                        t.check(escape == nil, "\(note): alpha outside \(deviceBounds): \(String(describing: escape))")
                        t.check(firstAlpha(prepared, scale: format.scale, outside: pixelBounds(frame, scale: format.scale)) != nil,
                                "\(note): actual pixels extend beyond the deliberately small meter frame")
                        t.check(firstAlpha(prepared, scale: format.scale, outside: pixelBounds(estimate, scale: format.scale)) != nil,
                                "\(note): the combined miter paints beyond the Core visual estimate")
                        let interior = CGRect(x: 1, y: 1, width: canvasWidth * format.scale - 2,
                                              height: canvasHeight * format.scale - 2)
                        t.check(firstAlpha(prepared, scale: format.scale, outside: interior) == nil,
                                "\(note): the independent fixed canvas has a transparent outer border")
                        if let first {
                            let left = max(deviceBounds.minX, CGFloat(first.x + 1))
                            let shrunken = CGRect(x: left, y: deviceBounds.minY,
                                                  width: max(0, deviceBounds.maxX - left), height: deviceBounds.height)
                            t.check(firstAlpha(prepared, scale: format.scale, outside: shrunken) != nil,
                                    "\(note): deliberately shrinking the predicted box detects a real pixel escape")
                        }
                        return prepared
                    }
                    return (draw, bounds, pictures)
                }

                let original = try capture("original")
                skin.setVariable("Width", "28")
                skin.update()
                let changed = try capture("changed")
                t.check(changed.draw.revision != original.draw.revision, "a geometry update changes the captured revision")
                t.check(changed.bounds.maxX > original.bounds.maxX, "the updated rectangle expands the prepared geometry")
                t.check(changed.pixels != original.pixels, "the geometry update changes visible pixels")
                t.equal(DesksetDraw.ShapeRenderer.geometryBounds(original.draw, context: context.drawing), original.bounds,
                        "querying the old value after an update restores its original bounds")
                t.equal(context.shapes.count, 1, "querying old and new revisions keeps one cache entry for the source")

                skin.perform(Bang(name: "setoption", args: ["Drawing", "X", "44.75"]))
                skin.perform(Bang(name: "setoption", args: ["Drawing", "Y", "42.25"]))
                skin.update()
                let moved = try capture("moved")
                t.equal(moved.draw.revision, changed.draw.revision, "moving the meter does not change its geometry revision")
                t.equal(moved.bounds, changed.bounds.offsetBy(dx: 9.5, dy: 5.75),
                        "the query applies the fractional content origin exactly once")

                let empty = ShapeDraw(shapes: [], contentFrame: original.draw.contentFrame)
                t.check(DesksetDraw.ShapeRenderer.geometryBounds(empty, context: context.drawing).isNull,
                        "an empty payload has no geometry")
                for format in formats {
                    let blank = try pixels(format) { SkinRenderer.drawShape(empty, $0, context) }
                    t.check(firstAlpha(blank, scale: format.scale, outside: .null) == nil,
                            "\(format): the empty payload paints no alpha")
                }
                return [original, changed, moved]
            }
            t.check(releasedSkin == nil && releasedMeter == nil, "geometry values and the warm cache retain no owner")
            t.equal(saved.count, 3, "original, changed and moved geometry were captured")
            for (sampleIndex, sample) in saved.enumerated() {
                for (index, format) in formats.enumerated() {
                    let note = "saved \(sampleIndex), \(format)"
                    weak var releasedCache: ShapeCG.Cache?
                    try autoreleasepool {
                        let cold = SkinRenderContext()
                        releasedCache = cold.shapes
                        t.equal(cold.shapes.count, 0, "\(note): owner-free replay starts cold")
                        t.equal(DesksetDraw.ShapeRenderer.geometryBounds(sample.draw, context: cold.drawing), sample.bounds,
                                "\(note): a cold query reproduces the saved bounds after owner release")
                        let picture = try pixels(format) { SkinRenderer.drawShape(sample.draw, $0, cold) }
                        t.check(picture == sample.pixels[index], "\(note): the prepared old value keeps exact pixels")
                    }
                    t.check(releasedCache == nil, "\(note): queried paths leave with their drawing context")
                }
            }
        }
    }

    /// These bitmap fixtures use only the known top-left translation and uniform scale in `pixels`.
    /// This is test geometry conversion, not the full target-dependent InkBounds calculation.
    private static func pixelBounds(_ bounds: CGRect, scale: Int) -> CGRect {
        guard !bounds.isNull else { return .null }
        return bounds.applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))).integral
    }

    /// RGBA and little-endian BGRA both store alpha in byte 3; `geometryTests` verifies the row convention.
    private static func firstAlpha(_ pixels: Data, scale: Int, outside bounds: CGRect) -> (x: Int, y: Int, alpha: UInt8)? {
        let width = canvasWidth * scale, height = canvasHeight * scale
        precondition(pixels.count == width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                if alpha > 0 && !bounds.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    return (x, y, alpha)
                }
            }
        }
        return nil
    }

    /// Only active pixel bytes are compared, without bitmap row padding.
    private static func pixels(_ format: (scale: Int, bgra: Bool), _ draw: (CGContext) -> Void) throws -> Data {
        let width = canvasWidth * format.scale, height = canvasHeight * format.scale
        let info = format.bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info), let data = ctx.data else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(format.scale), y: -CGFloat(format.scale))
        draw(ctx)
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(data.advanced(by: row * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return result
    }
}
