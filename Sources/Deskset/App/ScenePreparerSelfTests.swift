import AppKit
import DesksetCore
import DesksetDraw

enum ScenePreparerSelfTests {
    static func run(_ t: AppTestRunner) {
        compositionTests(t)
        unknownTests(t)
        glassAndVersionTests(t)
        nativeBackgroundTests(t)
        lifetimeAndDrawingTests(t)
    }

    private static func compositionTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene preparation: element indices and complete container runs stay distinct") {
            let context = DrawContext(fonts: AppFontResolver())
            let target = DrawTarget(userToDevice: .identity)
            let maskID = ElementID(name: "Mask", index: 1)
            let invalid = DrawItem.transformed(ShapeTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0),
                                               [fill(50, 50, 4, 4)])
            let elements = [
                element("Hidden", 0, [fill(1, 2, 4, 5), fill(8, 1, 2, 3)], visibility: .hiddenKeepsSpace),
                element("Mask", 1, [fill(21, 22, 5, 6)], frame: SkinRect(x: 20, y: 20, width: 20, height: 18),
                        isContainer: true),
                element("Child", 2, [text], container: maskID),
                element("HiddenChild", 3, [invalid], visibility: .collapsed, container: maskID),
                element("Front", 4, [fill(70, 6, 9, 4)]),
                element("EmptyMask", 5, [fill(80, 20, 5, 5)], isContainer: true),
                element("Collapsed", 6, [], visibility: .collapsed),
            ]
            let scene = makeScene(background: [fill(0, 0, 3, 3), fill(6, 2, 3, 2)], elements: elements)
            let prepared = ScenePreparer.prepare(scene, context: context, target: target)
            t.equal(prepared.scene, scene, "preparation keeps all captured scene fields")
            t.equal(prepared.elementInk, [rectangle(1, 1, 10, 7), rectangle(21, 22, 26, 28),
                                           .unknown(.unresolvedRasterization), .unknown(.invalidMapping),
                                           rectangle(70, 6, 79, 10), rectangle(80, 20, 85, 25), .empty],
                    "selection candidates keep file indices, hidden values and each container's own mask")
            t.equal(prepared.runInk, [rectangle(0, 0, 9, 4), rectangle(20, 20, 40, 38),
                                       rectangle(70, 6, 79, 10), .empty],
                    "base is first; the container clips unresolved visible children and excludes invalid hidden children")
            t.equal(prepared.scene.topLevelElements.map(\.id), [elements[1].id, elements[4].id, elements[5].id],
                    "run positions follow visible top-level order, including the empty container")

            let padded = ScenePreparer.prepare(scene, context: context, target: target, padding: 2)
            t.equal(padded.runInk, [rectangle(-2, -2, 11, 6), rectangle(18, 18, 42, 40),
                                     rectangle(68, 4, 81, 12), .empty],
                    "padding is forwarded for each run while empty compositions remain empty")
            let empty = ScenePreparer.prepare(makeScene(), context: context, target: target)
            t.equal(empty.elementInk, [], "a scene without elements has no selection candidates")
            t.equal(empty.runInk, [.empty], "even an empty scene keeps its background run")
        }
    }

    private static func unknownTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene preparation: unresolved and invalid candidates survive recipe unions") {
            let context = DrawContext(fonts: AppFontResolver())
            let target = DrawTarget(userToDevice: .identity)
            let invalidGeometry = fill(0, 0, .infinity, 4)
            let invalidMapping = DrawItem.transformed(ShapeTransform(a: 0, b: 0, c: 0, d: 1, tx: 0, ty: 0),
                                                      [fill(0, 0, 4, 4)])
            let cases: [([DrawItem], InkBounds.Candidate)] = [
                ([], .empty),
                ([fill(2, 3, 4, 5), fill(12, 1, 3, 3)], rectangle(2, 1, 15, 8)),
                ([text, fill(2, 3, 4, 5)], .unknown(.unresolvedRasterization)),
                ([text, invalidGeometry], .unknown(.invalidGeometry)),
                ([invalidGeometry, text], .unknown(.invalidGeometry)),
                ([text, invalidMapping], .unknown(.invalidMapping)),
                ([invalidMapping, text], .unknown(.invalidMapping)),
            ]
            for (items, expected) in cases {
                let prepared = ScenePreparer.prepare(makeScene(background: items, elements: [element("Own", 0, items)]),
                                                     context: context, target: target)
                t.equal(prepared.elementInk, [expected], "selection unions keep the typed result")
                t.equal(prepared.runInk, [expected, expected], "background and content unions keep invalid precedence")
            }

            // Each endpoint is safely inside Int and each width is representable, but their combined span is not.
            let farLeft = fill(-5e18, 0, 2048, 2), farRight = fill(5e18, 0, 2048, 2)
            t.equal(InkBounds.candidate(of: farLeft, context: context, target: target),
                    rectangle(-5_000_000_000_000_000_000, 0, -4_999_999_999_999_997_952, 2),
                    "the left item is independently a valid nonempty candidate")
            t.equal(InkBounds.candidate(of: farRight, context: context, target: target),
                    rectangle(5_000_000_000_000_000_000, 0, 5_000_000_000_000_002_048, 2),
                    "the right item is independently a valid nonempty candidate")
            for items in [[farLeft, farRight], [farRight, farLeft]] {
                let prepared = ScenePreparer.prepare(makeScene(background: items, elements: [element("Wide", 0, items)]),
                                                     context: context, target: target)
                t.equal(prepared.elementInk, [.unknown(.invalidMapping)], "overflowing union is never empty ink")
                t.equal(prepared.runInk, [.unknown(.invalidMapping), .unknown(.invalidMapping)],
                        "both run paths reject an unrepresentable total width in either order")
            }
        }
    }

    private static func glassAndVersionTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene preparation: destination glass and captured resource versions remain separate") {
            let context = DrawContext(fonts: AppFontResolver())
            let ctx = try bitmap(scale: 1, bgra: false)
            ctx.translateBy(x: 0, y: CGFloat(ctx.height))
            ctx.scaleBy(x: 1, y: -1)
            t.equal(DrawTarget.capture(ctx, glass: .none).userToDevice, .identity,
                    "the hand-computed candidates start with an explicit y-down device mapping")
            let published = GlassRegion(id: "Glass", rect: SkinRect(x: 2, y: 3, width: 4, height: 5))
            let current = GlassRegion(id: "Glass", rect: SkinRect(x: 40, y: 30, width: 8, height: 9))
            var own = element("Glass", 0, [fill(10, 12, 6, 4)], glass: current)
            own.imageDependencies = [ImageDependency(path: "/missing/child.png", stamp: nil)]
            own.drawGeneration = 11
            var scene = makeScene(background: [.glass(published)], elements: [own])
            scene.glass = [published]
            scene.backgroundImageDependencies = [ImageDependency(path: "/missing/background.png", stamp: nil)]

            let none = ScenePreparer.prepare(scene, context: context, target: .capture(ctx, glass: .none))
            t.equal(none.elementInk, [rectangle(10, 12, 16, 16)])
            t.equal(none.runInk, [.empty, rectangle(10, 12, 16, 16)], "none omits only glass candidate geometry")
            let hitArea = ScenePreparer.prepare(scene, context: context, target: .capture(ctx, glass: .hitArea))
            t.equal(hitArea.elementInk, [rectangle(10, 12, 48, 39)], "selection uses current glass with its own content")
            t.equal(hitArea.runInk, [rectangle(2, 3, 6, 8), rectangle(10, 12, 16, 16)],
                    "published glass stays in the background; element glass is not reinserted into whole runs")
            t.equal(hitArea.scene.background, [.glass(published)], "the captured background keeps its single glass item")
            t.equal(hitArea.scene, scene, "nil stamps, generations and both glass views remain unchanged")

            let placeholder = ScenePreparer.prepare(scene, context: context,
                                                     target: .capture(ctx, glass: .placeholder(dark: true)))
            t.equal(placeholder.elementInk, [.unknown(.unresolvedRasterization)])
            t.equal(placeholder.runInk, [.unknown(.unresolvedRasterization), rectangle(10, 12, 16, 16)],
                    "unqualified placeholder strokes stay unknown without affecting the own-content run")
            ctx.translateBy(x: 0.25, y: 0.75)
            ctx.scaleBy(x: 2, y: 2)
            let scaled = ScenePreparer.prepare(scene, context: context, target: .capture(ctx, glass: .hitArea))
            t.equal(scaled.runInk, [rectangle(4, 6, 13, 17), rectangle(20, 24, 33, 33)],
                    "candidate density and phase come from this target, even when scene versions are unchanged")

            let stamp = ImageStamp(seconds: 7, nanoseconds: 9, size: 23, inode: 41)
            scene.backgroundImageDependencies = [ImageDependency(path: "/missing/background.png", stamp: stamp)]
            scene.elements[0].imageDependencies = [ImageDependency(path: "/missing/child.png", stamp: stamp)]
            scene.environment = EnvironmentStamp(scale: 2, fontGeneration: 17,
                                                  appearance: AppearanceStamp(value: .dark, name: "changed"),
                                                  imageGeneration: 29)
            // An unchanged scene generation must not conceal newly captured resource versions.
            let changed = ScenePreparer.prepare(scene, context: context, target: .capture(ctx, glass: .hitArea))
            t.equal(changed.scene, scene, "new stamps and resource generations are carried without rewriting the scene")
            t.equal(changed.runInk, scaled.runInk, "resource metadata is preserved independently of ideal geometry")
            t.equal(hitArea.scene.backgroundImageDependencies,
                    [ImageDependency(path: "/missing/background.png", stamp: nil)], "old missing-file dependencies stay nil")
            t.equal(hitArea.scene.elements[0].imageDependencies,
                    [ImageDependency(path: "/missing/child.png", stamp: nil)], "old element dependencies stay nil")
            t.equal(hitArea.scene.environment, environment, "old environment generations stay frozen")
            t.equal(changed.scene.elements[0].drawGeneration, 11, "resource changes do not invent element revisions")
        }
    }

    private static func nativeBackgroundTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene preparation: native element backgrounds keep final geometry in their own drawing run") {
            let context = DrawContext(fonts: AppFontResolver())
            let ctx = try bitmap(scale: 1, bgra: false)
            ctx.translateBy(x: 0, y: CGFloat(ctx.height)); ctx.scaleBy(x: 1, y: -1)
            let region = GlassRegion(id: "desk-background:1:child", rect: SkinRect(x: 2, y: 3, width: 14, height: 12),
                                     cornerRadius: 3, style: .clear)
            let transform = ShapeTransform(a: 0.5, b: 0, c: 0, d: 0.5, tx: 10, ty: 10)
            let parent = element("Parent", 0, [fill(0, 0, 30, 24)])
            var child = element("Child", 1, [.transformed(transform, [fill(-12, -8, 8, 6)])], frame: region.rect, glass: region)
            child.backing = .native(.glass)
            let scene = makeScene(elements: [parent, child])
            let hit = ScenePreparer.prepare(scene, context: context, target: .capture(ctx, glass: .hitArea))
            t.equal(scene.drawingRuns, [[], parent.items, [.glass(region)] + child.items])
            t.equal(hit.elementInk, [rectangle(0, 0, 30, 24), rectangle(2, 3, 16, 15)])
            t.equal(hit.runInk, [.empty, rectangle(0, 0, 30, 24), rectangle(2, 3, 16, 15)],
                    "native glass stays in the child run after its parent's color")
            let none = ScenePreparer.prepare(scene, context: context, target: .capture(ctx, glass: .none))
            t.equal(none.elementInk, [rectangle(0, 0, 30, 24), rectangle(4, 6, 8, 9)])
            t.equal(none.runInk, [.empty, rectangle(0, 0, 30, 24), rectangle(4, 6, 8, 9)],
                    "omitting native pixels preserves the independently transformed bitmap candidate")
            ctx.saveGState(); ctx.scaleBy(x: 2, y: 2)
            let twice = ScenePreparer.prepare(scene, context: context, target: .capture(ctx, glass: .hitArea))
            ctx.restoreGState()
            t.equal(twice.runInk, [.empty, rectangle(0, 0, 60, 48), rectangle(4, 6, 32, 30)],
                    "the destination density applies once to already-final glass coordinates")
            let placeholder = ScenePreparer.prepare(scene, context: context,
                target: .capture(ctx, glass: .placeholder(dark: false)))
            t.equal(placeholder.runInk, [.empty, rectangle(0, 0, 30, 24), .unknown(.unresolvedRasterization)])
            t.equal(hit.scene, scene)
        }
    }

    private static func lifetimeAndDrawingTests(_ t: AppTestRunner) {
        t.suite("Runtime: scene preparation: results release owners and leave same-context pixels unchanged") {
            weak var releasedSkin: Skin?
            weak var releasedMeter: Meter?
            weak var releasedMeasure: Measure?
            weak var releasedContext: DrawContext?
            weak var releasedShapes: ShapeCG.Cache?
            let prepared = try autoreleasepool { () throws -> SceneInkCandidates in
                let (skin, host) = try MediaUITests.bareSkin(t, fixture)
                defer { withExtendedLifetime(host) { skin.close() } }
                skin.update()
                guard let meter = skin.meter(named: "Drawing") as? ShapeMeter,
                      let measure = skin.measure(named: "Value") else { throw CocoaError(.coderInvalidValue) }
                releasedSkin = skin
                releasedMeter = meter
                releasedMeasure = measure
                let context = DrawContext(fonts: AppFontResolver())
                releasedContext = context
                releasedShapes = context.shapes
                t.equal(context.shapes.count, 0, "preparation starts with a cold geometry cache")
                let scene = SceneProjector().project(skin, environment: AppSceneEnvironment(
                    scale: 1, appearance: .light, appearanceName: "scene-preparation"))
                let result = ScenePreparer.prepare(scene, context: context, target: DrawTarget(userToDevice: .identity))
                t.equal(result.scene.elements.count, 3, "the real fixture includes shape, measured bar and text")
                t.check(context.shapes.count > 0, "preparation reused real shape building without drawing")
                t.check(releasedSkin != nil && releasedMeter != nil && releasedMeasure != nil
                        && releasedContext != nil && releasedShapes != nil, "the lifetime controls started alive")
                return result
            }
            t.check(releasedSkin == nil && releasedMeter == nil && releasedMeasure == nil,
                    "a retained prepared scene keeps no engine owner")
            t.check(releasedContext == nil && releasedShapes == nil,
                    "candidates do not retain the context or the geometry cache they warmed")

            for scale in [1, 2] {
                for bgra in [false, true] {
                    let note = "\(bgra ? "BGRA" : "RGBA") \(scale)x"
                    let ctx = try bitmap(scale: scale, bgra: bgra)
                    ctx.translateBy(x: 0, y: CGFloat(ctx.height))
                    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
                    let target = DrawTarget.prepareOwnedBitmap(ctx, glass: .none)
                    let context = DrawContext(fonts: AppFontResolver())
                    t.equal(context.shapes.count, 0, "\(note): owner-free replay starts cold")
                    let before = try pixels(prepared.scene, in: ctx, context: context, target: target)
                    t.check(hasAlpha(before), "\(note): the control has real visible pixels")
                    let transform = ctx.ctm, clip = ctx.boundingBoxOfClipPath
                    let matrix = ctx.textMatrix, position = ctx.textPosition
                    let interpolation = ctx.interpolationQuality
                    let queried = ScenePreparer.prepare(prepared.scene, context: context, target: target, padding: 2)
                    t.equal(queried.scene, prepared.scene, "\(note): preparing leaves the drawing recipe intact")
                    t.equal(ctx.ctm, transform, "\(note): preparing does not change the transform")
                    t.equal(ctx.boundingBoxOfClipPath, clip, "\(note): preparing does not change the clip")
                    t.equal(ctx.textMatrix, matrix, "\(note): preparing does not change text state")
                    t.equal(ctx.textPosition, position, "\(note): preparing does not move the text origin")
                    t.equal(ctx.interpolationQuality, interpolation, "\(note): preparing does not change interpolation")
                    let after = try pixels(queried.scene, in: ctx, context: context, target: target)
                    t.check(hasAlpha(after), "\(note): the prepared replay has real visible pixels")
                    t.equal(after, before, "\(note): all active bytes match before and after preparing with the same cache")
                    withExtendedLifetime(queried) {}
                }
            }
            withExtendedLifetime(prepared) {}
        }
    }

    private static let environment = EnvironmentStamp(scale: 1, fontGeneration: 3,
                                                       appearance: AppearanceStamp(value: .light, name: "original"),
                                                       imageGeneration: 5)

    private static func makeScene(background: [DrawItem] = [], elements: [SceneElement] = []) -> WidgetScene {
        WidgetScene(generation: 7, size: SkinSize(width: 96, height: 72), background: background,
                    backgroundImageDependencies: [], glass: [], elements: elements, hitMap: SkinHitMap(),
                    environment: environment)
    }

    private static func element(_ name: String, _ index: Int, _ items: [DrawItem], frame: SkinRect = SkinRect(),
                                visibility: Visibility = .visible, container: ElementID? = nil,
                                isContainer: Bool = false, glass: GlassRegion? = nil) -> SceneElement {
        SceneElement(id: ElementID(name: name, index: index), kind: .shape, frame: frame, anchor: SkinPoint(),
                     visibility: visibility, container: container, isContainer: isContainer, items: items,
                     glass: glass, imageDependencies: [])
    }

    private static func fill(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> DrawItem {
        .fill(SkinRect(x: x, y: y, width: width, height: height), Paint(color: RGBA(r: 40, g: 130, b: 210)))
    }

    private static let text: DrawItem = {
        let frame = SkinRect(x: 22, y: 23, width: 8, height: 9)
        return .text(TextDraw(text: "Ink", style: TextStyle(), frame: frame, contentFrame: frame, anchor: SkinPoint()))
    }()

    private static func rectangle(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> InkBounds.Candidate {
        .rectangle(InkBounds.DeviceRect(minX: x0, minY: y0, maxX: x1, maxY: y1)!)
    }

    private static func bitmap(scale: Int, bgra: Bool) throws -> CGContext {
        let info = bgra
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 96 * scale, height: 72 * scale, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx
    }

    /// Same target and drawing caches before/after preparation; only active bytes, never row padding, are compared.
    private static func pixels(_ scene: WidgetScene, in ctx: CGContext, context: DrawContext, target: DrawTarget) throws
        -> Data {
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: 96, height: 72))
        DesksetDraw.DrawExecutor.draw(scene: scene, in: ctx, context: context, cycle: 0, target: target)
        ctx.restoreGState()
        guard let bytes = ctx.data else { throw CocoaError(.coderInvalidValue) }
        var result = Data(capacity: ctx.width * ctx.height * 4)
        for y in 0..<ctx.height {
            result.append(bytes.advanced(by: y * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: ctx.width * 4)
        }
        return result
    }

    private static func hasAlpha(_ pixels: Data) -> Bool {
        stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }
    }

    private static let fixture = """
    [Rainmeter]
    Update=-1
    SkinWidth=96
    SkinHeight=72
    BackgroundMode=2
    SolidColor=20,30,50,100
    [Value]
    Measure=Calc
    Formula=35
    MaxValue=100
    [Drawing]
    Meter=Shape
    X=7
    Y=9
    Shape=Rectangle 0,0,34,18,3 | Fill Color 80,150,200,190 | StrokeWidth 2 | Stroke Color 220,90,40,190
    [Level]
    Meter=Bar
    MeasureName=Value
    X=48
    Y=12
    W=30
    H=9
    BarOrientation=Horizontal
    BarColor=230,150,60,210
    [Caption]
    Meter=String
    MeasureName=Value
    Text=Value %1
    X=9
    Y=40
    W=80
    H=20
    FontSize=12
    FontColor=220,230,240,255
    AntiAlias=1
    """
}
