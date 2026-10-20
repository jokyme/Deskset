import AppKit
import DesksetCore

enum SVGSceneSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("Runtime: SVG scene: retained pictures follow resource overrides and preserve old snapshots") {
            weak var releasedSkin: Skin?
            weak var releasedMeter: SVGMeter?
            let environment = AppSceneEnvironment(scale: 2, appearance: .light, appearanceName: "test")
            let context = SkinRenderContext()
            let scenes = try autoreleasepool { () throws -> [WidgetScene] in
                let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                Update=-1
                SkinWidth=120
                SkinHeight=90
                BackgroundMode=2
                SolidColor=20,30,40,255
                [Variables]
                EndColor=blue
                [Drawing]
                Meter=SVG
                X=10
                Y=12
                W=90
                H=60
                DynamicVariables=1
                SVGImage=<svg xmlns:xlink="http://www.w3.org/1999/xlink" width="90" height="60"><defs><linearGradient id="paint"><stop offset="0" stop-color="red"/><stop id="end" offset="1" stop-color="blue"/></linearGradient><clipPath id="clip"><circle cx="45" cy="30" r="27"/></clipPath><rect id="tile" width="90" height="60" fill="url(#paint)"/></defs><g clip-path="url(#clip)" opacity="0.7"><use xlink:href="#tile"/></g></svg>
                Attribute=end | stop-color | #EndColor#
                """)
                defer { withExtendedLifetime(host) { skin.close() } }
                skin.update()
                releasedSkin = skin
                guard let meter = skin.meter(named: "Drawing") as? SVGMeter else {
                    throw CocoaError(.coderInvalidValue)
                }
                releasedMeter = meter
                let projector = SceneProjector()
                let first = projector.project(skin, environment: environment)
                let revision = meter.revision
                skin.setVariable("EndColor", "lime")
                skin.update()
                let changed = projector.project(skin, environment: environment)
                t.check(meter.revision != revision, "a resource attribute override invalidates the SVG payload")
                t.check(first.elements[0].items != changed.elements[0].items)
                skin.perform(Bang(name: "setoption", args: ["Drawing", "X", "25"]))
                skin.update()
                let moved = projector.project(skin, environment: environment)
                t.check(changed.elements[0].items != moved.elements[0].items, "placement participates in identity")
                t.check(first.elements[0].imageDependencies.isEmpty,
                        "local SVG resources do not become filesystem image dependencies")
                return [first, changed, moved]
            }
            t.check(releasedSkin == nil && releasedMeter == nil, "captured SVG scenes do not retain the owner")
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.coderInvalidValue) }
            let drawing = SkinBitmapDrawing()
            func frame(_ scene: WidgetScene, scale: CGFloat) throws -> Data {
                let image = drawing.picture(scene: scene, context: context, cycle: 0,
                                            size: CGSize(width: 120, height: 90), scale: scale, space: space)
                let full = SkinBitmapDrawing.fullDrawing(scene: scene, context: SkinRenderContext(), cycle: 0,
                                                        Int(120 * scale), Int(90 * scale), scale: scale, space: space)
                t.check(SkinDrawingSelfTests.difference(image, full) <= SkinBitmapDrawing.tolerance,
                        "cached SVG composition matches a cold complete drawing")
                return try pixels(image)
            }
            for scale: CGFloat in [1, 2] {
                let original = try frame(scenes[0], scale: scale)
                _ = try frame(scenes[0], scale: scale)
                _ = try frame(scenes[0], scale: scale)
                t.check(drawing.lastStats.copied > 0, "unchanged SVG runs reuse retained pixels")
                let changed = try frame(scenes[1], scale: scale)
                t.check(original != changed, "the gradient override changes rendered pixels")
                let moved = try frame(scenes[2], scale: scale)
                t.check(changed != moved, "moving an SVG moves its resources and clipping")
                let restored = try frame(scenes[0], scale: scale)
                t.check(maxDifference(original, restored) <= SkinBitmapDrawing.tolerance,
                        "an older snapshot still draws correctly after new revisions")
            }
        }

        t.suite("Runtime: SVG scene: outer meter transforms and skin containers compose with SVG clips") {
            let (skin, host) = try MediaUITests.bareSkin(t, """
            [Rainmeter]
            Update=-1
            SkinWidth=100
            SkinHeight=80
            [Container]
            Meter=Shape
            X=12
            Y=8
            Shape=Rectangle 0,0,48,48 | Fill Color 255,255,255,160 | StrokeWidth 0
            [Drawing]
            Meter=SVG
            Container=Container
            W=60
            H=60
            TransformationMatrix=1;0;0;1;5;4
            SVGImage=<svg width="60" height="60"><defs><clipPath id="half"><rect width="30" height="60"/></clipPath><linearGradient id="g"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient></defs><rect width="60" height="60" fill="url(#g)" clip-path="url(#half)"/></svg>
            """)
            defer { withExtendedLifetime(host) { skin.close() } }
            skin.update()
            let scene = SceneProjector().project(skin, environment: AppSceneEnvironment(scale: 1, appearance: .light,
                                                                                      appearanceName: "test"))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = SkinBitmapDrawing.fullDrawing(scene: scene, context: SkinRenderContext(), cycle: 0,
                                                            100, 80, scale: 1, space: space) else {
                throw CocoaError(.coderInvalidValue)
            }
            let data = try pixels(image.makeImage())
            t.check(data.contains { $0 != 0 }, "transformed SVG content reaches the container")
            // Full-drawing and retained-drawing paths must apply both clipping layers identically.
            let retained = SkinBitmapDrawing().picture(scene: scene, context: SkinRenderContext(), cycle: 0,
                                                       size: CGSize(width: 100, height: 80), scale: 1, space: space)
            t.check(SkinDrawingSelfTests.difference(retained, image) <= SkinBitmapDrawing.tolerance)
        }
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
