import AppKit
import DesksetCore
import DesksetDraw

enum SceneBitmapSelfTests {
    static func run(_ t: AppTestRunner) {
        viewportTests(t)
        t.suite("Runtime: scene bitmap: retained runs use captured inputs after the engine owner is released") {
            weak var releasedSkin: Skin?
            weak var releasedMeter: Meter?
            let context = SkinRenderContext()
            let scenes = try autoreleasepool { () throws -> [WidgetScene] in
                let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                Update=-1
                SkinWidth=90
                SkinHeight=70
                BackgroundMode=2
                SolidColor=20,30,50,120
                [Value]
                Measure=Calc
                Formula=30
                MaxValue=100
                [Static]
                Meter=Shape
                Shape=Rectangle 4,4,45,20,4 | Fill Color 80,150,200,190 | StrokeWidth 0
                [Graph]
                Meter=Histogram
                MeasureName=Value
                X=8
                Y=30
                W=50
                H=30
                PrimaryColor=240,100,70,180
                [Caption]
                Meter=String
                Text=Scene
                X=45
                Y=7
                FontSize=12
                AntiAlias=1
                """)
                defer { withExtendedLifetime(host) { skin.close() } }
                skin.update()
                releasedSkin = skin
                releasedMeter = skin.meter(named: "Graph")
                let projector = SceneProjector()
                let environment = AppSceneEnvironment(scale: 2, appearance: .light, appearanceName: "test")
                let first = projector.project(skin, environment: environment, glassSource: .published)
                guard let value = skin.measure(named: "Value") else { throw CocoaError(.coderInvalidValue) }
                skin.perform(Bang(name: "setoption", args: ["Value", "MaxValue", "50"]))
                skin.perform(Bang(name: "updatemeasure", args: ["Value"]))
                t.close(value.maxValue, 50)
                let second = projector.project(skin, environment: environment, glassSource: .published)
                t.check(first.elements[1].items != second.elements[1].items, "a range-only update changes the captured graph")
                return [first, second]
            }
            t.check(releasedSkin == nil && releasedMeter == nil, "cached scenes hold no engine owner")
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.coderInvalidValue) }
            let size = CGSize(width: 90, height: 70), scale: CGFloat = 2
            let drawing = SkinBitmapDrawing()
            func frame(_ scene: WidgetScene) -> CGImage? {
                let image = drawing.picture(scene: scene, context: context, cycle: 1, size: size, scale: scale, space: space)
                let full = SkinBitmapDrawing.fullDrawing(scene: scene, context: SkinRenderContext(), cycle: 1,
                                                        180, 140, scale: scale, space: space)
                t.check(SkinDrawingSelfTests.difference(image, full) <= SkinBitmapDrawing.tolerance,
                        "the retained drawing matches a cold full drawing")
                return image
            }
            for _ in 0..<3 { t.check(frame(scenes[0]) != nil) }
            t.check(drawing.lastStats.copied > 0, "unchanged captured inputs reuse pictures")
            let oldPixels = try pixels(frame(scenes[0]))
            let newPixels = try pixels(frame(scenes[1]))
            t.check(maxDifference(oldPixels, newPixels) > SkinBitmapDrawing.tolerance,
                    "changing only the captured range visibly changes the bitmap")
            let restoredPixels = try pixels(frame(scenes[0]))
            let restoredDifference = maxDifference(oldPixels, restoredPixels)
            print("    retained old scene after a newer one: maximum channel difference \(restoredDifference)")
            // Changing which runs are copied changes 8-bit compositing roundoff; full scene execution is checked
            // byte for byte separately. This cache uses the same compositing budget as the existing window path.
            t.check(restoredDifference <= SkinBitmapDrawing.tolerance,
                    "the previous scene remains drawable within the retained-picture compositing budget")
            for _ in 0..<3 { _ = frame(scenes[1]) }
            t.check(drawing.lastStats.copied > 0, "the newer scene also settles into cached runs")
            drawing.releaseKept()
            t.check(!drawing.keepsPictures)
            t.check(frame(scenes[0]) != nil, "a released drawing restarts from the retained scene")
            t.equal(drawing.lastStats.copied, 0)
            t.check(drawing.picture(scene: scenes[0], context: context, cycle: 1,
                                    size: CGSize(width: CGFloat.infinity, height: 70), scale: scale, space: space) == nil)
            t.check(drawing.picture(scene: scenes[0], context: context, cycle: 1,
                                    size: size, scale: .nan, space: space) == nil)
            t.check(drawing.picture(scene: scenes[0], context: context, cycle: 1,
                                    size: CGSize(width: -90, height: -70), scale: -2, space: space) == nil)
        }
    }

    private static func viewportTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene bitmap viewport: direct kept full and verification share the captured point origin") {
            let oldVerify = SkinBitmapDrawing.verifies
            SkinBitmapDrawing.verifies = true
            defer { SkinBitmapDrawing.verifies = oldVerify }
            let space = SkinFrameProducer.sRGB, size = CGSize(width: 12, height: 10)
            let rect = SkinRect(x: -1, y: -2, width: 6, height: 5)
            let color = RGBA(r: 35, g: 141, b: 218)
            for scale in [CGFloat(1), 2] {
                let stamp = AppSceneEnvironment(scale: Double(scale), appearance: .light, appearanceName: "bitmap viewport").stamp
                let scene = WidgetScene(generation: 1, size: SkinSize(width: 12, height: 10),
                    background: [.fill(rect, Paint(color: color))], backgroundImageDependencies: [], glass: [],
                    elements: [], hitMap: SkinHitMap(), environment: stamp)
                let context = SkinRenderContext(), drawing = SkinBitmapDrawing()
                let w = Int(size.width * scale), h = Int(size.height * scale)
                func reference(_ origin: SkinPoint) throws -> Data {
                    guard let ctx = SkinBitmapDrawing.makeContext(w, h, space) else { throw CocoaError(.coderInvalidValue) }
                    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
                    ctx.translateBy(x: -origin.x, y: -origin.y)
                    _ = DrawTarget.prepareOwnedBitmap(ctx, glass: .none)
                    ctx.setFillColor(red: color.r / 255, green: color.g / 255, blue: color.b / 255, alpha: 1)
                    ctx.fill(CGRect(x: -1, y: -2, width: 6, height: 5))
                    return try activeBytes(ctx.makeImage())
                }
                var retained: CGImage?, retainedBytes: Data?
                let origins = [SkinPoint(x: -2, y: -3), SkinPoint(x: -3, y: -2),
                               SkinPoint(x: -2.25, y: -3.5), SkinPoint(x: -2, y: -3)]
                for origin in origins {
                    let capture = SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: 1, size: size,
                                                           source: "viewport", origin: origin)
                    let expected = try reference(origin)
                    let direct = drawing.picture(capture, scale: scale, space: space)
                    t.equal(try activeBytes(direct), expected, "same-size changed origin invalidates old cached pictures")
                    t.equal(drawing.lastStats.copied, 0)
                    t.check(stride(from: 3, to: expected.count, by: 4).contains { expected[$0] != 0 })
                    t.check(expected != (try reference(SkinPoint())), "omitting the translation is an effective negative control")
                    for _ in 0..<2 { t.equal(try activeBytes(drawing.picture(capture, scale: scale, space: space)), expected) }
                    t.check(drawing.lastStats.copied > 0, "the strict control actually copies a kept run")
                    let full = SkinBitmapDrawing.fullDrawing(scene: scene, context: context, cycle: 1, w, h,
                                                            scale: scale, space: space, origin: origin)
                    t.equal(try activeBytes(full?.makeImage()), expected, "cold full and warm direct/copy use one viewport")
                    t.equal(drawing.differences, 0, "the enabled full verifier also receives the origin")
                    if retained == nil { retained = direct; retainedBytes = expected }
                    t.equal(try activeBytes(retained), retainedBytes, "later origins do not mutate an already presented image")
                }
                let zero = SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: 1, size: size, source: "zero")
                t.equal(zero.origin, SkinPoint())
                t.equal(try activeBytes(drawing.picture(zero, scale: scale, space: space)), try reference(SkinPoint()))
                t.equal(try activeBytes(drawing.picture(scene: scene, context: context, cycle: 1, size: size,
                    scale: scale, space: space)), try reference(SkinPoint()), "the old API still means the original zero origin")
                for bad in [SkinPoint(x: .nan), SkinPoint(y: .infinity)] {
                    t.check(drawing.picture(scene: scene, context: context, cycle: 1, size: size, scale: scale,
                        space: space, origin: bad) == nil)
                    t.check(SkinBitmapDrawing.fullDrawing(scene: scene, context: context, cycle: 1, w, h,
                        scale: scale, space: space, origin: bad) == nil)
                }
            }
        }
    }

    private static func activeBytes(_ image: CGImage?) throws -> Data {
        guard let image, image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data), image.height > 0,
              CFDataGetLength(data) >= (image.height - 1) * image.bytesPerRow + image.width * 4 else {
            throw CocoaError(.coderInvalidValue)
        }
        var result = Data()
        for y in 0..<image.height { result.append(bytes + y * image.bytesPerRow, count: image.width * 4) }
        return result
    }

    private static func pixels(_ image: CGImage?) throws -> Data {
        guard let image, let space = image.colorSpace,
              let context = SkinBitmapDrawing.makeContext(image.width, image.height, space) else {
            throw CocoaError(.coderInvalidValue)
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data else { throw CocoaError(.coderInvalidValue) }
        return Data(bytes: bytes, count: context.bytesPerRow * context.height)
    }

    private static func maxDifference(_ a: Data, _ b: Data) -> Int {
        guard a.count == b.count else { return .max }
        return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }
}
