import AppKit
import DesksetCore

enum ShapeDrawValueSelfTests {
    private static let formats = [(scale: 1, bgra: false), (scale: 1, bgra: true),
                                  (scale: 2, bgra: false), (scale: 2, bgra: true)]

    private struct Sample {
        let draw: ShapeDraw
        let pixels: [Data]
    }

    static func run(_ t: AppTestRunner) {
        drawingTests(t)
        cacheTests(t)
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

    /// Only active pixel bytes are compared, without bitmap row padding.
    private static func pixels(_ format: (scale: Int, bgra: Bool), _ draw: (CGContext) -> Void) throws -> Data {
        let width = 200 * format.scale, height = 150 * format.scale
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
