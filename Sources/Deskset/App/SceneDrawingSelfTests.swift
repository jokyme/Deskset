import AppKit
import DesksetCore

enum SceneDrawingSelfTests {
    private struct Variant: CustomStringConvertible {
        let scale: Int
        let bgra: Bool
        let clipped: Bool
        var description: String { "\(bgra ? "BGRA" : "RGBA") \(scale)x clip=\(clipped)" }
    }

    private static let variants = [1, 2].flatMap { scale in
        [false, true].flatMap { bgra in
            [false, true].map { Variant(scale: scale, bgra: bgra, clipped: $0) }
        }
    }

    private final class Environment: SceneEnvironment {
        let stamp = EnvironmentStamp(scale: 1, fontGeneration: 0,
                                     appearance: AppearanceStamp(value: .light, name: "test"), imageGeneration: 0)
        func imageStamp(_ path: String) -> ImageStamp? { nil }
    }

    private struct SceneCapture {
        let scene: WidgetScene
        let cycle: Int
        let glass: SkinRenderer.GlassDrawing
        let pictures: [Data]
    }

    private struct SelectionCapture {
        let elements: [SceneElement]
        let glass: SkinRenderer.GlassDrawing
        let pictures: [Data]
    }

    static func run(_ t: AppTestRunner) {
        backgroundTests(t)
        compositionTests(t)
        selectionTests(t)
        glassTests(t)
        stateTests(t)
    }

    private static func backgroundTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene drawing: backgrounds preserve natural size, sampling, margins, gradients and bevels") {
            let files = try imageFiles()
            let cases = [
                ("natural", 0, "Card.png", "ImageCrop=4,6,96,64\nImageRotate=90\nImageAlpha=173", true),
                ("stretched", 3, "Card.png", "ImageFlip=Horizontal\nImageTint=180,220,255,180", true),
                ("margins", 3, "Frame9.png", "BackgroundMargins=8,8,8,8\nImageRotate=90\nImageAlpha=171", true),
                ("tiled", 4, "Tile.png", "ImageRotate=90\nImageTint=210,160,250,173", true),
                ("gradient", 2, "", "SolidColor=210,40,60,100\nSolidColor2=20,170,220,230\nGradientAngle=37\n"
                    + "BevelType=2\nBevelColor=255,230,30,170\nBevelColor2=40,70,220,200", true),
                ("transparent", 1, "Card.png", "", false),
                ("missing", 4, "Missing.png", "", false)
            ]
            for (name, mode, file, options, visible) in cases {
                weak var releasedSkin: Skin?
                let saved = try autoreleasepool { () throws -> SceneCapture in
                    let loaded = try load(t, """
                    [Rainmeter]
                    Update=-1
                    SkinWidth=42
                    SkinHeight=34
                    BackgroundMode=\(mode)
                    Background=\(file)
                    \(options)
                    """, files: files)
                    let skin = loaded.skin
                    defer { withExtendedLifetime(loaded.host) { skin.close() } }
                    releasedSkin = skin
                    let scene = SceneProjector().project(skin, environment: Environment())
                    let result = try capture(scene, skin: skin, glass: .none, context: SkinRenderContext(), t, name)
                    for (index, variant) in variants.enumerated() {
                        t.equal(result.pictures[index].contains { $0 != 0 }, visible, "\(name), \(variant): nonempty fixture")
                        if name == "natural" {
                            t.check(hasAlpha(result.pictures[index], variant, outside: scene.size),
                                    "the natural background can draw beyond the fixed skin size")
                        }
                    }
                    return result
                }
                t.check(releasedSkin == nil, "a background recipe does not retain its owner")
                Images.purge()
                try checkSaved(saved, context: SkinRenderContext(), t, "cold background \(name)")
            }
        }
    }

    private static func compositionTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene drawing: containers, file order, hidden states and transforms remain frozen") {
            let files = try imageFiles()
            weak var releasedSkin: Skin?
            weak var releasedMeter: Meter?
            weak var releasedMeasure: Measure?
            let context = SkinRenderContext()
            let saved = try autoreleasepool { () throws -> [SceneCapture] in
                let loaded = try load(t, compositionFixture, files: files)
                let skin = loaded.skin
                defer { withExtendedLifetime(loaded.host) { skin.close() } }
                releasedSkin = skin
                releasedMeter = skin.meter(named: "Mask")
                releasedMeasure = skin.measure(named: "Level")
                for _ in 0..<4 { skin.update() }
                let projector = SceneProjector(), environment = Environment()
                var results: [SceneCapture] = []
                func record(_ label: String) throws {
                    let current = projector.project(skin, environment: environment, glassSource: .current)
                    results.append(try capture(current, skin: skin, glass: .placeholder(dark: false), context: context, t, label))
                    let published = projector.project(skin, environment: environment, glassSource: .published)
                    results.append(try capture(published, skin: skin, glass: .window, context: context, t, label))
                }
                try record("initial composition")
                skin.setVariable("Radius", "17")
                skin.execute("[!SetOption Mask TransformationMatrix \"1;0;0;1;11;4\"]"
                             + "[!SetOption ChildAfter Hidden 1][!SetOption Overlay SolidColor 210,50,140,170]", from: nil)
                skin.update()
                try record("changed measure, transform and hidden child")
                skin.execute("[!SetOption Mask Hidden 1]", from: nil)
                skin.update()
                try record("hidden container")
                t.check(results[0].pictures != results[2].pictures && results[2].pictures != results[4].pictures,
                        "both mutations visibly change the complete scene")
                for index in [0, 4, 2, 0, 3, 1, 5] {
                    try checkSaved(results[index], context: context, t, "alternating captured scenes")
                }
                for (index, variant) in variants.enumerated() {
                    let sample = results[0]
                    let runs = try pixels(variant) { ctx in
                        for run in sample.scene.drawingRuns {
                            DrawExecutor.draw(run, in: ctx, context: context, cycle: sample.cycle, glass: sample.glass)
                        }
                    }
                    t.equal(runs, sample.pictures[index], "base and top-level runs preserve the full composition")
                }
                return results
            }
            t.check(releasedSkin == nil && releasedMeter == nil && releasedMeasure == nil,
                    "scenes and the warm context retain no live owner")
            Images.purge()
            let cold = SkinRenderContext()
            for sample in saved { try checkSaved(sample, context: cold, t, "cold scene after owner release") }
        }
    }

    private static func selectionTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene drawing: selections draw own items in requested order with all glass behind them") {
            weak var releasedSkin: Skin?
            let context = SkinRenderContext()
            let saved = try autoreleasepool { () throws -> [SelectionCapture] in
                let loaded = try load(t, selectionFixture)
                let skin = loaded.skin
                defer { withExtendedLifetime(loaded.host) { skin.close() } }
                releasedSkin = skin
                let projector = SceneProjector(), environment = Environment()
                let selections = [["Back", "Glass"], ["Mask"], ["Child"], ["Mask", "Child"],
                                  ["Child", "Mask"], ["Hidden"], []]
                var results: [SelectionCapture] = []
                for names in selections {
                    let meters = names.compactMap { skin.meter(named: $0) }
                    t.equal(meters.count, names.count, "the selected meters exist")
                    let elements = try meters.map { meter in
                        guard let index = skin.meters.firstIndex(where: { $0 === meter }) else {
                            throw CocoaError(.coderInvalidValue)
                        }
                        return projector.projectElement(meter, index: index, environment: environment)
                    }
                    let appearances: [Bool?] = [nil, false, true]
                    for dark in appearances {
                        let glass = SkinRenderer.GlassDrawing.placeholder(dark: dark)
                        let pictures = try variants.map { variant in
                            let current = try pixels(variant) {
                                DrawExecutor.draw(elements: elements, in: $0, context: context, cycle: 1, glass: glass)
                            }
                            #if DEBUG
                            let reference = try pixels(variant) { LegacySkinRenderer.drawMeters(meters, $0, glassDark: dark) }
                            t.equal(current, reference, "selection \(names), dark=\(String(describing: dark)), \(variant)")
                            #endif
                            if names == ["Hidden"] {
                                t.check(current.contains { $0 != 0 }, "a hidden Shape's own items still draw in isolation")
                            }
                            if names == ["Back", "Glass"] {
                                let interleaved = try pixels(variant) { ctx in
                                    for element in elements {
                                        DrawExecutor.draw(element: element, in: ctx, context: context, cycle: 1, glass: glass)
                                    }
                                }
                                t.check(current != interleaved, "glass-before-content is observable when selections overlap")
                            }
                            return current
                        }
                        results.append(SelectionCapture(elements: elements, glass: glass, pictures: pictures))
                    }
                }
                return results
            }
            t.check(releasedSkin == nil, "selection recipes do not retain their skin")
            let cold = SkinRenderContext()
            for sample in saved {
                for (index, variant) in variants.enumerated() {
                    let current = try pixels(variant) {
                        DrawExecutor.draw(elements: sample.elements, in: $0, context: cold, cycle: 2, glass: sample.glass)
                    }
                    t.equal(current, sample.pictures[index], "cold selection after owner release")
                }
            }
        }
    }

    private static func glassTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene drawing: glass preserves overlap, publication and standalone regions beyond the limit") {
            let regions = [GlassRegion(id: "A", rect: SkinRect(x: 10, y: 10, width: 65, height: 60), cornerRadius: 7),
                           GlassRegion(id: "B", rect: SkinRect(x: 35, y: 18, width: 65, height: 60), cornerRadius: 9,
                                       style: .clear, tint: RGBA(r: 30, g: 140, b: 210, a: 150))]
            let paints: [SkinRenderer.GlassDrawing] = [.window, .placeholder(dark: nil), .placeholder(dark: true),
                                                       .placeholder(dark: false), .none]
            for glass in paints {
                for variant in variants {
                    let current = try pixels(variant) {
                        DrawExecutor.draw(regions.map(DrawItem.glass), in: $0, context: SkinRenderContext(), cycle: 0, glass: glass)
                    }
                    #if DEBUG
                    let reference = try pixels(variant) { ctx in
                        switch glass {
                        case .window: LegacyGlassPlaceholder.drawHitArea(regions, in: ctx)
                        case let .placeholder(dark): LegacyGlassPlaceholder.draw(regions, in: ctx, dark: dark)
                        case .none: break
                        }
                    }
                    t.equal(current, reference, "overlapping glass \(glass), \(variant)")
                    #endif
                    if glass == .window {
                        let single = try pixels(variant) {
                            DrawExecutor.draw([.glass(regions[0])], in: $0, context: SkinRenderContext(), cycle: 0, glass: glass)
                        }
                        let offset = ((30 * variant.scale) * (180 * variant.scale) + 45 * variant.scale) * 4 + 3
                        t.check(current[offset] > single[offset], "hit-area alpha accumulates where regions overlap")
                    }
                }
            }

            let loaded = try load(t, """
            [Rainmeter]
            Update=-1
            SkinWidth=70
            SkinHeight=60
            MacGlass=Regular
            MacGlassCornerRadius=#Radius#
            [Variables]
            Radius=2
            """)
            let skin = loaded.skin
            defer { withExtendedLifetime(loaded.host) { skin.close() } }
            let projector = SceneProjector(), environment = Environment()
            skin.setVariable("Radius", "24")
            let published = projector.project(skin, environment: environment, glassSource: .published)
            let current = projector.project(skin, environment: environment, glassSource: .current)
            t.check(published.glass != current.glass, "live preview can differ from the last published glass")
            _ = try capture(published, skin: skin, glass: .window, context: SkinRenderContext(), t, "published glass")
            _ = try capture(current, skin: skin, glass: .placeholder(dark: nil), context: SkinRenderContext(), t, "current glass")

            var many = "[Rainmeter]\nUpdate=-1\n"
            for index in 0...GlassRegion.maxRegions {
                many += "[Glass\(index)]\nMeter=Image\nX=12\nY=10\nW=80\nH=60\nMacGlass=Regular\n"
            }
            let crowded = try load(t, many)
            defer { withExtendedLifetime(crowded.host) { crowded.skin.close() } }
            let scene = projector.project(crowded.skin, environment: environment)
            t.equal(scene.glass.count, GlassRegion.maxRegions)
            guard let last = crowded.skin.meters.last else { throw CocoaError(.coderInvalidValue) }
            let element = projector.projectElement(last, index: GlassRegion.maxRegions, environment: environment)
            t.check(element.glass != nil && !scene.glass.contains(where: { $0.id == last.name }),
                    "a standalone element retains glass omitted from the complete scene")
            for variant in variants {
                let picture = try pixels(variant) {
                    DrawExecutor.draw(element: element, in: $0, context: SkinRenderContext(), cycle: 1,
                                      glass: .placeholder(dark: false))
                }
                t.check(picture.contains { $0 != 0 }, "glass beyond the full-scene limit still draws alone")
                #if DEBUG
                let reference = try self.pixels(variant) { LegacySkinRenderer.drawMeter(last, $0, glassDark: false) }
                t.equal(picture, reference, "standalone glass beyond the limit, \(variant)")
                #endif
            }
        }
    }

    private static func stateTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene drawing: identity and antialias groups restore state for the following drawing") {
            let red = Paint(color: RGBA(r: 220, g: 20, b: 30, a: 180))
            let rect = SkinRect(x: 12.25, y: 14.75, width: 24.5, height: 20.5)
            for antialias in [false, true] {
                for variant in variants {
                    func setup(_ ctx: CGContext) {
                        ctx.setFillColor(RGBA(r: 20, g: 160, b: 70, a: 210).cgColor)
                        ctx.setShouldAntialias(true)
                    }
                    func following(_ ctx: CGContext) {
                        ctx.fillEllipse(in: CGRect(x: 52.25, y: 18.25, width: 36.5, height: 31.5))
                    }
                    let current = try pixels(variant) { ctx in
                        setup(ctx)
                        let items: [DrawItem] = antialias ? [.antialias(false, [.fill(rect, red)])]
                            : [.transformed(.identity, [.fill(rect, red)])]
                        DrawExecutor.draw(items, in: ctx, context: SkinRenderContext(), cycle: 0, glass: .none)
                        following(ctx)
                    }
                    let reference = try pixels(variant) { ctx in
                        setup(ctx)
                        ctx.saveGState()
                        if antialias { ctx.setShouldAntialias(false) }
                        ctx.setFillColor(red.color.cgColor)
                        ctx.fill(rect.cgRect)
                        ctx.restoreGState()
                        following(ctx)
                    }
                    t.equal(current, reference, "the sibling keeps its incoming paint and antialias state, \(variant)")
                }
            }
        }
    }

    private static func capture(_ scene: WidgetScene, skin: Skin, glass: SkinRenderer.GlassDrawing,
                                context: SkinRenderContext, _ t: AppTestRunner, _ label: String) throws -> SceneCapture {
        let cycle = skin.updateCount
        let pictures = try variants.map { variant in
            let current = try pixels(variant) {
                DrawExecutor.draw(scene: scene, in: $0, context: context, cycle: cycle, glass: glass)
            }
            #if DEBUG
            let reference = try pixels(variant) { ctx in
                let mode: LegacySkinRenderer.GlassDrawing
                switch glass {
                case .window: mode = .window
                case let .placeholder(dark): mode = .placeholder(dark: dark)
                case .none: mode = .none
                }
                LegacySkinRenderer.draw(skin, in: ctx, glass: mode)
            }
            t.equal(current, reference, "\(label), \(variant): exact frozen-renderer pixels")
            #endif
            return current
        }
        return SceneCapture(scene: scene, cycle: cycle, glass: glass, pictures: pictures)
    }

    private static func checkSaved(_ sample: SceneCapture, context: SkinRenderContext, _ t: AppTestRunner,
                                   _ label: String) throws {
        for (index, variant) in variants.enumerated() {
            let current = try pixels(variant) {
                DrawExecutor.draw(scene: sample.scene, in: $0, context: context, cycle: sample.cycle, glass: sample.glass)
            }
            t.equal(current, sample.pictures[index], "\(label), \(variant)")
        }
    }

    private static func load(_ t: AppTestRunner, _ ini: String, files: [String: Data] = [:]) throws
        -> (skin: Skin, host: RenderHost, folder: URL) {
        guard let loaded = SkinDrawingSelfTests.load(t, ini, files: files, "scene-drawing") else {
            throw CocoaError(.coderInvalidValue)
        }
        return loaded
    }

    private static func imageFiles() throws -> [String: Data] {
        guard let folder = Paths.repositoryFolder("TestSkins/Image/ImageMeters/@Resources/Images") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Dictionary(uniqueKeysWithValues: ["Card.png", "Frame9.png", "Tile.png", "Mask.png"].map {
            ($0, try Data(contentsOf: folder.appendingPathComponent($0)))
        })
    }

    /// Active bitmap bytes only; the optional fractional clip exercises the renderer's unchanged tile anchoring.
    private static func pixels(_ variant: Variant, _ draw: (CGContext) -> Void) throws -> Data {
        let width = 180 * variant.scale, height = 140 * variant.scale
        let info = variant.bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info), let bytes = ctx.data else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(variant.scale), y: -CGFloat(variant.scale))
        if variant.clipped { ctx.clip(to: CGRect(x: 17.25, y: 12.5, width: 115.5, height: 84.25)) }
        draw(ctx)
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(bytes.advanced(by: row * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return result
    }

    private static func hasAlpha(_ pixels: Data, _ variant: Variant, outside size: SkinSize) -> Bool {
        let width = 180 * variant.scale, height = 140 * variant.scale
        for y in 0..<height {
            for x in 0..<width where Double(x) >= size.width * Double(variant.scale)
                || Double(y) >= size.height * Double(variant.scale) {
                if pixels[(y * width + x) * 4 + 3] > 0 { return true }
            }
        }
        return false
    }

    private static let selectionFixture = """
    [Rainmeter]
    Update=-1
    SkinWidth=170
    SkinHeight=130
    [Back]
    Meter=Image
    X=8
    Y=8
    W=82
    H=64
    SolidColor=30,110,170,255
    [Glass]
    Meter=Image
    X=26
    Y=18
    W=66
    H=54
    MacGlass=Regular
    MacGlassCornerRadius=8
    [Mask]
    Meter=Shape
    X=100
    Y=18
    W=54
    H=48
    Shape=Ellipse 26,24,23,18 | Fill Color 230,120,40,150 | StrokeWidth 3
    TransformationMatrix=0.9;0.2;-0.2;0.9;6;2
    [Child]
    Meter=Image
    Container=Mask
    X=-8
    Y=-8
    W=72
    H=60
    SolidColor=40,200,90,210
    [Hidden]
    Meter=Shape
    X=20
    Y=82
    Hidden=1
    Shape=Rectangle 0,0,40,20,4 | Fill Color 200,50,130,230 | StrokeWidth 0
    """

    private static let compositionFixture = """
    [Rainmeter]
    Update=-1
    SkinWidth=168
    SkinHeight=128
    BackgroundMode=2
    SolidColor=25,35,50,80
    SolidColor2=90,45,70,150
    GradientAngle=27
    BevelType=1
    MacGlass=Regular
    MacGlassCornerRadius=8
    [Variables]
    Radius=28
    [Level]
    Measure=Calc
    Formula=#Radius#
    DynamicVariables=1
    MinValue=0
    MaxValue=40
    [History]
    Measure=Calc
    Formula=History+5
    MinValue=0
    MaxValue=100
    [ChildBefore]
    Meter=Image
    Container=Mask
    X=-12
    Y=-8
    W=90
    H=68
    ImageName=Card.png
    MaskImageName=Mask.png
    ImageAlpha=190
    MacGlass=Clear
    MacGlassCornerRadius=5
    TransformationMatrix=1;0;0;1;-3;2
    [Overlay]
    Meter=Image
    X=52
    Y=18
    W=44
    H=45
    SolidColor=20,190,80,170
    SolidColor2=120,60,180,100
    GradientAngle=51
    BevelType=2
    [Mask]
    Meter=Shape
    X=25
    Y=16
    W=60
    H=52
    DynamicVariables=1
    Shape=Ellipse 30,25,[Level],22 | Fill Color 255,255,255,128 | StrokeWidth 3 | Stroke Color 255,255,255,200
    SolidColor=255,255,255,35
    BevelType=1
    MacGlass=Regular
    TransformationMatrix=0.95;0.15;-0.1;1;8;-4
    [ChildAfter]
    Meter=Shape
    Container=Mask
    X=4
    Y=7
    Shape=Rectangle 0,0,56,42,6 | Fill Color 210,60,100,130 | StrokeWidth 2
    AntiAlias=1
    [HiddenChild]
    Meter=Image
    Container=Mask
    W=80
    H=60
    SolidColor=0,0,255,255
    Hidden=1
    [EmptyMask]
    Meter=Image
    X=125
    Y=8
    W=28
    H=26
    [EmptyContent]
    Meter=Image
    Container=EmptyMask
    W=28
    H=26
    SolidColor=255,255,0,255
    [HiddenMask]
    Meter=Image
    X=130
    Y=58
    W=25
    H=26
    SolidColor=255,255,255,255
    Hidden=1
    [HiddenContent]
    Meter=Image
    Container=HiddenMask
    W=25
    H=26
    SolidColor=0,255,0,255
    [Foreground]
    Meter=Shape
    X=78
    Y=40
    Shape=Rectangle 0,0,45,35,5 | Fill Color 230,150,30,180 | StrokeWidth 2
    MacGlass=Clear
    TransformationMatrix=1;0;0;1;4;3
    [Line]
    Meter=Line
    MeasureName=History
    X=8
    Y=86
    W=48
    H=18
    LineColor=210,50,80,220
    AntiAlias=1
    [Histogram]
    Meter=Histogram
    MeasureName=History
    X=65
    Y=86
    W=44
    H=18
    PrimaryColor=50,180,220,170
    [Bar]
    Meter=Bar
    MeasureName=Level
    X=117
    Y=90
    W=40
    H=10
    BarOrientation=Horizontal
    BarColor=210,130,20,220
    [Label]
    Meter=String
    MeasureName=Level
    X=18
    Y=110
    FontFace=Helvetica
    FontSize=9
    FontColor=220,240,255,210
    Text=Value %1
    AntiAlias=1
    """
}
