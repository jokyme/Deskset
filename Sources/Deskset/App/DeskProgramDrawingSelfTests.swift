import AppKit
import CoreText
import ImageIO
import DeskLanguage
import DesksetCore
import DesksetDraw

/// The source, compiler and program use actual Core Text measurement and the shared drawing executor.
/// No Skin, INI document, service or window is created. These are bitmap checks, not compositor acceptance.
enum DeskProgramDrawingSelfTests {
    private enum Failure: Error { case compilation, bitmap }

    static func run(_ t: AppTestRunner) {
        ownerTests(t)
        t.suite("App: Desk program drawing: checked text uses point fonts and matches native drawing") {
            let source = #"widget { Text("Desk 中文 😀").font(20).color(.accent).padding(4) }"#
            let program = try compile(source, t)
            let text = "Desk 中文 😀"
            for appearance in [SkinAppearance.light, .dark] {
                let context = DrawContext(fonts: AppFontResolver())
                var runtime = try ProgramRuntime(program: program)
                let scene = try runtime.project(environment: environment(appearance)) { value, style, width in
                    t.equal(value, text)
                    t.equal(width, nil)
                    t.close(CTFontGetSize(AppFontResolver().resolve(FontRequest(style: style)).font), 20,
                            "the native font is 20 points, without applying the legacy size conversion twice")
                    let layout = context.text.layout(value, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: 1)
                    t.close(layout.pad, 0, "Desk text does not inherit compatibility padding")
                    return SkinSize(width: layout.size.width, height: layout.size.height)
                }
                let style = referenceStyle(points: 20, color: appearance.accentColor)
                let size = context.text.layout(text, style: style, wrapWidth: nil, cycle: 1).size
                let frame = SkinRect(width: size.width + 8, height: size.height + 8)
                let content = SkinRect(x: 4, y: 4, width: size.width, height: size.height)
                let expected = TextDraw(text: text, style: style, frame: frame, contentFrame: content, anchor: SkinPoint())
                t.equal(scene.size, SkinSize(width: frame.width, height: frame.height))
                t.equal(scene.drawingItems, [.text(expected)], "the compiled geometry and style match the explicit native recipe")
                for scale in [1, 2] {
                    let actual = try pixels(scene.drawingItems, size: scene.size, scale: scale, context: context)
                    let reference = try pixels([.text(expected)], size: scene.size, scale: scale,
                                               context: DrawContext(fonts: AppFontResolver()))
                    t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] != 0 }, "native text produces visible pixels")
                    t.equal(actual, reference, "compiled / explicit native RGBA bytes at \(scale)x")
                    let cold = try pixels(scene.drawingItems, size: scene.size, scale: scale,
                                          context: DrawContext(fonts: AppFontResolver()))
                    t.equal(cold, actual, "the program scene replays with independent font/layout caches")
                }
            }
        }

        t.suite("App: Desk program drawing: hidden text keeps native layout space without painting") {
            let program = try compile(#"widget { Column(spacing: 3, align: .left) { Text("first").font(13).hidden(); Text("中文 😀").font(20) } }"#, t)
            let context = DrawContext(fonts: AppFontResolver())
            var runtime = try ProgramRuntime(program: program)
            let scene = try runtime.project(environment: environment(.light)) { text, style, width in
                let size = context.text.layout(text, style: style, wrapWidth: width.map { CGFloat($0) }, cycle: 1).size
                return SkinSize(width: size.width, height: size.height)
            }
            let first = context.text.layout("first", style: referenceStyle(points: 13, color: SkinAppearance.light.labelColor),
                                            wrapWidth: nil, cycle: 1).size
            let style = referenceStyle(points: 20, color: SkinAppearance.light.labelColor)
            let second = context.text.layout("中文 😀", style: style, wrapWidth: nil, cycle: 1).size
            let frame = SkinRect(x: 0, y: first.height + 3, width: second.width, height: second.height)
            let expected = TextDraw(text: "中文 😀", style: style, frame: frame, contentFrame: frame,
                                    anchor: SkinPoint(x: 0, y: first.height + 3))
            t.equal(scene.size, SkinSize(width: max(first.width, second.width), height: first.height + 3 + second.height))
            t.equal(scene.elements.count, 3)
            t.equal(scene.elements[1].visibility, .hiddenKeepsSpace)
            t.equal(scene.drawingItems, [.text(expected)])
            for scale in [1, 2] {
                let actual = try pixels(scene.drawingItems, size: scene.size, scale: scale, context: context)
                let reference = try pixels([.text(expected)], size: scene.size, scale: scale,
                                           context: DrawContext(fonts: AppFontResolver()))
                t.check(stride(from: 3, to: actual.count, by: 4).contains { actual[$0] != 0 })
                t.equal(actual, reference, "only the visible child paints, at its native measured offset")
            }
        }
    }

    private final class BitmapProvider: ContentProvider {
        let content: LayerContentProvider
        let threads = Guarded<[Bool]>([])
        init(_ view: NSView) { content = LayerContentProvider(in: view) }
        func present(_ frame: SkinFrame) {
            threads.access { $0.append(Thread.isMainThread) }
            content.present(frame)
        }
        func setVisible(_ visible: Bool) { content.setVisible(visible) }
        func setScale(_ scale: CGFloat) { content.setScale(scale) }
        func releaseContents() { content.releaseContents() }
        func teardown() { content.teardown() }
    }

    private static func ownerInput(_ name: NSAppearance.Name = .aqua, scale: Int = 1) throws -> DeskProgramHost.Input {
        guard let appearance = NSAppearance(named: name) else { throw Failure.bitmap }
        let values = try MacAppearance.programValues(for: appearance)
        return DeskProgramHost.Input(environment: AppSceneEnvironment(scale: Double(scale), appearance: values.appearance,
            appearanceName: name.rawValue).stamp, colors: values.colors, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func facts(_ input: DeskProgramHost.Input, ordered: Bool = true, seen: Bool = true,
                              pointer: Bool = true, space: CGColorSpace? = SkinFrameProducer.sRGB) -> SkinWindowFacts {
        SkinWindowFacts(frame: .zero, isVisible: seen, isOrderedIn: ordered, scale: CGFloat(input.environment.scale),
            colorSpace: space, appearance: input.environment.appearance.name, takesPointer: pointer, sequence: 1)
    }

    private static func ownerClock() throws -> VirtualTimeExecutor {
        guard let zone = TimeZone(secondsFromGMT: 0) else { throw Failure.bitmap }
        let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_586_059.25), timeZone: zone)
        executor.background.allowsUnfakedWork = false
        return executor
    }

    private static func textValues(_ host: DeskProgramHost) -> [String] {
        host.scene?.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil } ?? []
    }

    private static func presentedBytes(_ provider: BitmapProvider) throws -> Data {
        try bitmapBytes(provider.content.shown.image)
    }

    private static func bitmapBytes(_ image: CGImage?) throws -> Data {
        guard let image, image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.width > 0, image.height > 0,
              image.width <= 2048, image.height <= 2048, let raw = image.dataProvider?.data else { throw Failure.bitmap }
        let bytes = raw as Data, active = image.width * 4, row = image.bytesPerRow
        guard row >= active, row <= Int.max / image.height,
              bytes.count >= (image.height - 1) * row + active else { throw Failure.bitmap }
        var result = Data(capacity: active * image.height)
        for y in 0..<image.height { result.append(bytes[y * row..<y * row + active]) }
        return result
    }

    private static func referenceBitmap(_ size: CGSize, scale: Int, origin: CGPoint = .zero,
                                         draw: (CGContext) throws -> Void) throws -> CGImage {
        let w = Int(ceil(size.width * Double(scale))), h = Int(ceil(size.height * Double(scale)))
        guard w > 0, h > 0, w <= 2048, h <= 2048,
              let ctx = SkinBitmapDrawing.makeContext(w, h, SkinFrameProducer.sRGB) else { throw Failure.bitmap }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        ctx.translateBy(x: -origin.x, y: -origin.y)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        _ = DrawTarget.prepareOwnedBitmap(ctx, glass: .none)
        try draw(ctx)
        guard let image = ctx.makeImage() else { throw Failure.bitmap }
        return image
    }

    private static func clockReference(_ text: String, input: DeskProgramHost.Input, scale: Int) throws -> Data {
        let style = referenceStyle(points: 20, color: input.environment.appearance.value.accentColor)
        let value = TextDraw(text: text, style: style, frame: SkinRect(width: 160, height: 40),
                            contentFrame: SkinRect(x: 4, y: 4, width: 152, height: 32), anchor: SkinPoint())
        let image = try referenceBitmap(CGSize(width: 160, height: 40), scale: scale) { ctx in
            let context = DrawContext(fonts: AppFontResolver())
            DesksetDraw.DrawExecutor.draw([.text(value)], in: ctx, context: context, cycle: 1,
                                          target: DrawTarget.capture(ctx, glass: .none))
        }
        return try bitmapBytes(image)
    }

    private static func ownerTests(_ t: AppTestRunner) {
        t.suite("App: Desk bitmap owner: centered outlines retain negative paint bounds and native bytes") {
            let program = try compile("widget { Rectangle().size(24, 18).stroke(.accent, width: 4) }", t)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for scale in [1, 2] {
                    let input = try ownerInput(appearance, scale: scale), time = try ownerClock()
                    let view = NSView(), provider = BitmapProvider(view)
                    var host: DeskProgramHost? = try DeskProgramHost(program: program, executor: time, provider: provider,
                                                                   input: input, clock: time.clock)
                    weak var cache = host?.context
                    defer { host?.close(); provider.teardown(); withExtendedLifetime(view) {} }
                    guard let live = host else { throw Failure.bitmap }
                    var reported: DeskProgramHost.Presented?
                    live.didPresent = { reported = $0 }
                    live.take(facts(input), input: input); live.start(); live.drawFirstFrame()
                    t.equal(live.state, .ready)
                    t.equal(live.scene?.size, SkinSize(width: 24, height: 18))
                    t.equal(live.viewport, CGRect(x: -2, y: -2, width: 28, height: 22))
                    t.equal(reported?.origin, SkinPoint(x: -2, y: -2))
                    t.equal(reported?.size, CGSize(width: 28, height: 22))
                    t.equal(reported?.scene.generation, live.scene?.generation)
                    let reference = try referenceBitmap(CGSize(width: 28, height: 22), scale: scale,
                                                        origin: CGPoint(x: -2, y: -2)) { ctx in
                        ctx.setStrokeColor(input.environment.appearance.value.accentColor.cgColor)
                        ctx.setLineWidth(4); ctx.setLineCap(.butt); ctx.setLineJoin(.miter); ctx.setMiterLimit(10)
                        ctx.stroke(CGRect(x: 0, y: 0, width: 24, height: 18))
                    }
                    let expected = try bitmapBytes(reference)
                    t.check(stride(from: 3, to: expected.count, by: 4).contains { expected[$0] != 0 })
                    t.equal(try presentedBytes(provider), expected, "independent CoreGraphics stroke covers every outside pixel")
                    let omitted = try referenceBitmap(CGSize(width: 28, height: 22), scale: scale) { _ in }
                    t.check(try bitmapBytes(omitted) != expected, "missing the stroke cannot pass the pixel control")
                    let original = provider.content.shown.image
                    for _ in 0..<3 { live.frames.setNeedsFrame(); live.frames.runLoopTurn(.beforeWaiting) }
                    t.equal(try presentedBytes(provider), expected)
                    t.check(live.frames.drawing.lastStats.copied > 0)
                    live.close(); host = nil
                    t.check(cache == nil)
                    t.check(provider.content.shown.image == nil)
                    t.equal(try bitmapBytes(original), expected, "close cannot alter a previously handed image")
                    t.equal(time.background.reports, [])
                }
            }
        }

        t.suite("App: Desk bitmap owner: shared native cache and boundary clock sample one date per projection") {
            for (pattern, first, next, due) in [("HH:mm:ss", "09:00:59", "09:01:00", 0.75),
                                               ("HH:mm", "09:00", "09:01", 0.75)] {
                let program = try compile("widget { Text(\"{time.now, format: \"" + pattern + "\"}\").font(20).color(.accent).size(160, 40).padding(4) }", t)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    for scale in [1, 2] {
                        let input = try ownerInput(appearance, scale: scale), time = try ownerClock()
                        var reads = 0
                        let clock = SkinClock(now: { reads += 1; return time.wallClock }, uptime: { time.uptime }, timeZone: { time.timeZone })
                        let view = NSView(), provider = BitmapProvider(view)
                        let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input, clock: clock)
                        defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
                        host.take(facts(input), input: input); host.start()
                        t.equal(reads, 1)
                        let builds = host.context?.text.builds
                        host.drawFirstFrame()
                        t.equal(host.context?.text.builds, builds, "measurement and rendering consume the same native layout/cycle")
                        t.equal(try presentedBytes(provider), try clockReference(first, input: input, scale: scale))
                        time.advance(until: 0)
                        t.equal(time.pendingCount, 1); t.close(time.nextDue ?? -1, due)
                        time.advance(until: due - 0.001); t.equal(reads, 1)
                        time.advance(until: due); host.frames.runLoopTurn(.beforeWaiting)
                        t.equal(reads, 2); t.equal(textValues(host), [next])
                        t.equal(try presentedBytes(provider), try clockReference(next, input: input, scale: scale))
                        t.close(time.nextDue ?? -1, pattern == "HH:mm:ss" ? 1.75 : 60.75)
                        let generation = host.scene?.generation
                        host.pause(); time.advance(until: 2); host.wake()
                        t.equal(reads, 2); t.equal(host.scene?.generation, generation, "paused wake does not evaluate or catch up")
                        host.resume(updateNow: false)
                        t.equal(reads, 3, "rearming samples only the boundary, without a projection")
                        t.equal(host.scene?.generation, generation)
                        host.pause(); host.resume(updateNow: true)
                        t.equal(reads, 4)
                        host.frames.runLoopTurn(.beforeWaiting)
                        let before = reads
                        host.frames.setNeedsFrame(); host.frames.runLoopTurn(.beforeWaiting)
                        t.equal(reads, before, "an unchanged presentation never re-evaluates time")
                        host.wake(); t.equal(reads, before + 1)
                        host.close()
                        t.equal(time.pendingCount, 0)
                        let count = provider.content.state.presented
                        time.advance(until: 120); host.wake(); host.refresh(); host.drawFirstFrame()
                        t.equal(provider.content.state.presented, count)
                    }
                }
            }
        }

        pointerTests(t)
        actionOwnerTests(t)
        secondaryPointerTests(t)
        failureTests(t)
        imageOwnerTests(t)
        freeformOwnerTests(t)
        for worker in [false, true] {
            t.suite("App: Desk bitmap owner: real \(worker ? "worker" : "main") executor retains and releases its complete bundle") {
                try liveOwner(t, worker: worker)
            }
        }
    }

    private static func freeformOwnerTests(_ t: AppTestRunner) {
        t.suite("App: Desk Freeform bitmap: negative text image fill and stroke match independent native pixels") {
            let root = t.temporaryDirectory("desk-freeform-pictures")
            let picture = try referenceBitmap(CGSize(width: 4, height: 2), scale: 1) { ctx in
                ctx.setFillColor(RGBA(r: 220, g: 40, b: 20).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
                ctx.setFillColor(RGBA(r: 20, g: 60, b: 220).cgColor)
                ctx.fill(CGRect(x: 2, y: 0, width: 2, height: 1))
            }
            let output = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw Failure.bitmap }
            CGImageDestinationAddImage(encoder, picture, nil)
            guard CGImageDestinationFinalize(encoder) else { throw Failure.bitmap }
            try (output as Data).write(to: root.appendingPathComponent("picture.png"))
            let cases = [("text", #"Text("F").font(20).color(.accent)"#),
                         ("image", #"Image("picture.png").imageMode(.stretch)"#),
                         ("fill", "Rectangle().fill(.accent)"),
                         ("stroke", "Rectangle().stroke(.accent, width: 4)")]
            for (kind, leaf) in cases {
                for scale in [1, 2] {
                    let prepared = kind == "image" ? DeskProgramResources.prepare(root: root, literals: ["picture.png"],
                        maximumBytes: 4096, maximumFiles: 1) : nil
                    defer { prepared?.removeCopies() }
                    let source = "widget { Freeform { " + leaf + ".size(40, 32).position(x: -12, y: -9) } }"
                    let program: WidgetProgram
                    if let prepared {
                        t.equal(prepared.failure, nil)
                        let result = Desk.compile(Desk.check(Desk.parse(source, fileName: "Freeform.desk"), context: CheckContext(
                            resources: PackageResources(package: DeskPackage(files: prepared.files)))))
                        t.check(result.diagnostics.allSatisfy { $0.severity != .error })
                        t.check(result.issues.isEmpty, "\(result.issues)")
                        guard let value = result.program else { throw Failure.compilation }
                        program = value
                    } else { program = try compile(source, t) }
                    let input = try ownerInput(scale: scale), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
                    let host = try DeskProgramHost(program: program, executor: time, provider: provider,
                        input: input, prepared: prepared, clock: time.clock)
                    defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
                    host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
                    let frame = SkinRect(x: -12, y: -9, width: 40, height: 32)
                    let origin = kind == "stroke" ? CGPoint(x: -14, y: -11) : CGPoint(x: -12, y: -9)
                    let size = kind == "stroke" ? CGSize(width: 44, height: 36) : CGSize(width: 40, height: 32)
                    t.equal(host.state, .ready)
                    t.equal(host.scene?.size, SkinSize(width: 28, height: 23), "Freeform fits right/bottom extents without moving negative children")
                    t.equal(host.scene?.elements.dropFirst().first?.frame, frame)
                    t.equal(host.viewport, CGRect(origin: origin, size: size))
                    t.equal(host.presented?.origin, SkinPoint(x: origin.x, y: origin.y))
                    t.equal(host.presented?.size, size)
                    func reference(origin: CGPoint) throws -> Data {
                        let image = try referenceBitmap(size, scale: scale, origin: origin) { ctx in
                            let rect = CGRect(x: -12, y: -9, width: 40, height: 32)
                            switch kind {
                            case "text":
                                let text = TextDraw(text: "F", style: referenceStyle(points: 20,
                                    color: input.environment.appearance.value.accentColor), frame: frame,
                                    contentFrame: frame, anchor: SkinPoint(x: -12, y: -9))
                                DesksetDraw.DrawExecutor.draw([.text(text)], in: ctx,
                                    context: DrawContext(fonts: AppFontResolver()), cycle: 1,
                                    target: DrawTarget.capture(ctx, glass: .none))
                            case "image":
                                ctx.translateBy(x: -12, y: 23); ctx.scaleBy(x: 1, y: -1)
                                ctx.draw(picture, in: CGRect(x: 0, y: 0, width: 40, height: 32))
                            case "fill":
                                ctx.setFillColor(input.environment.appearance.value.accentColor.cgColor); ctx.fill(rect)
                            default:
                                ctx.setStrokeColor(input.environment.appearance.value.accentColor.cgColor)
                                ctx.setLineWidth(4); ctx.setLineCap(.butt); ctx.setLineJoin(.miter); ctx.setMiterLimit(10)
                                ctx.stroke(rect)
                            }
                        }
                        return try bitmapBytes(image)
                    }
                    let expected = try reference(origin: origin)
                    t.check(stride(from: 3, to: expected.count, by: 4).contains { expected[$0] != 0 }, "\(kind) has visible reference pixels")
                    t.equal(try presentedBytes(provider), expected, "\(kind) paints at the literal negative frame at \(scale)x")
                    t.check(try reference(origin: .zero) != expected, "omitting viewport translation must fail for \(kind)")
                }
            }
        }

        t.suite("App: Desk Freeform bitmap: all-negative transparent hit boxes survive while hidden overflow stays absent") {
            for transparent in [false, true] {
                let fill = transparent ? ".clear" : ".accent"
                let source = """
                widget { Freeform {
                    Rectangle().size(40, 32).fill(\(fill)).position(x: -60, y: -50).onClick { copy("visible") }
                    Rectangle().size(40, 32).fill(.accent).position(x: -70, y: -60).hidden().onClick { copy("hidden") }
                } }
                """
                let input = try ownerInput(), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
                let host = try DeskProgramHost(program: compile(source, t), executor: time, provider: provider,
                    input: input, clock: time.clock)
                defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
                host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
                t.equal(host.state, .ready)
                t.equal(host.scene?.size, SkinSize(), "all children end before the logical origin")
                t.equal(host.scene?.elements.last?.visibility, .hiddenKeepsSpace)
                t.equal(host.scene?.elements.last?.frame, SkinRect(x: -70, y: -60, width: 40, height: 32))
                t.equal(host.viewport, CGRect(x: -60, y: -50, width: 61, height: 51), "only the visible box extends the one-point root viewport")
                t.equal(host.presented?.origin, SkinPoint(x: -60, y: -50))
                let reference = try referenceBitmap(CGSize(width: 61, height: 51), scale: 1,
                                                    origin: CGPoint(x: -60, y: -50)) { ctx in
                    if !transparent {
                        ctx.setFillColor(input.environment.appearance.value.accentColor.cgColor)
                        ctx.fill(CGRect(x: -60, y: -50, width: 40, height: 32))
                    }
                }
                let expected = try bitmapBytes(reference)
                t.equal(try presentedBytes(provider), expected, "hidden paint is absent even when its box overlaps the visible child")
                t.equal(stride(from: 3, to: expected.count, by: 4).contains { expected[$0] != 0 }, !transparent)
                host.primaryPress(at: SkinPoint(x: -40, y: -34))
                t.check(host.primaryRelease(at: SkinPoint(x: -40, y: -34)) == nil, "scene coordinates are not bitmap-local input")
                let local = SkinPoint(x: 20, y: 16)
                host.primaryPress(at: local)
                t.equal(host.primaryRelease(at: local), [.copy("visible")], "transparent negative space remains actionable; hidden overlay cannot intercept")
                t.check(host.primaryRelease(at: local) == nil, "one press produces one transaction")
            }
        }

        t.suite("App: Desk Freeform bitmap: warm frame producer resets cached pixels when only viewport origin changes") {
            let input = try ownerInput(), context = SkinRenderContext()
            var runtime = try ProgramRuntime(program: compile("widget { Freeform { Rectangle().fill(.accent).size(40, 32).position(x: -12, y: -9) } }", t))
            let scene = try runtime.project(environment: input.environment, colorInput: input.colors) { _, _, _ in
                throw Failure.bitmap // This source has no text to measure.
            }
            let view = NSView(), provider = BitmapProvider(view)
            var origin = SkinPoint(x: -12, y: -9)
            let size = CGSize(width: 40, height: 32)
            let frames = SkinFrameProducer(provider: provider, bitmapCapture: { _, _ in
                SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: 1, size: size,
                                          source: "Freeform origin cache", origin: origin)
            })
            defer { frames.stop(); frames.clearBitmapContents(); provider.teardown(); withExtendedLifetime(view) {} }
            func expected(_ origin: CGPoint) throws -> Data {
                try bitmapBytes(referenceBitmap(size, scale: 1, origin: origin) { ctx in
                    ctx.setFillColor(input.environment.appearance.value.accentColor.cgColor)
                    ctx.fill(CGRect(x: -12, y: -9, width: 40, height: 32))
                })
            }
            frames.take(facts(input)); frames.setNeedsFrame(); frames.drawFirstFrame()
            let first = try expected(CGPoint(x: -12, y: -9))
            for _ in 0..<3 { frames.setNeedsFrame(); frames.runLoopTurn(.beforeWaiting) }
            t.equal(try presentedBytes(provider), first)
            t.check(frames.drawing.lastStats.copied > 0, "the same producer actually has warm reusable pictures")
            let held = provider.content.shown.image
            origin = SkinPoint(x: -8, y: -5)
            frames.setNeedsFrame(); frames.runLoopTurn(.beforeWaiting)
            let second = try expected(CGPoint(x: -8, y: -5))
            t.check(second != first, "the independent changed-origin recipe rejects stale cached bytes")
            t.equal(try presentedBytes(provider), second)
            t.equal(frames.drawing.lastStats.copied, 0, "same context, scene and dimensions cannot reuse the old-origin picture")
            for _ in 0..<3 { frames.setNeedsFrame(); frames.runLoopTurn(.beforeWaiting) }
            t.check(frames.drawing.lastStats.copied > 0)
            t.equal(try presentedBytes(provider), second)
            t.equal(try bitmapBytes(held), first, "changing origin cannot mutate an image already handed to a provider")
        }
    }

    private static func actionOwnerTests(_ t: AppTestRunner) {
        t.suite("App: Desk click actions: bitmap owner returns ordered effects after successful preflight") {
            let source = #"widget { variable n = 0; computed caption = "{n}"; Text(caption).font(20).size(160, 40).onClick { n = n + 1; copy(caption); open("https://example.com/{n}"); copy("done😀") } }"#
            let program = try compile(source, t), input = try ownerInput(), time = try ownerClock()
            let view = NSView(), provider = BitmapProvider(view)
            let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input, clock: time.clock)
            defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
            host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
            let inside = SkinPoint(x: 20, y: 20)
            t.check(host.primaryRelease(at: inside) == nil, "release without a press has no requests")
            host.primaryPress(at: inside)
            t.check(host.primaryRelease(at: SkinPoint(x: 300, y: 20)) == nil, "a miss has no requests")
            host.primaryPress(at: inside)
            let effects = host.primaryRelease(at: inside)
            t.equal(effects, [.copy("1"), .open("https://example.com/1"), .copy("done😀")])
            t.equal(textValues(host), ["1"], "preceding assignments are visible to computed action arguments")
            t.check(host.scene?.generation != host.presented?.scene.generation,
                    "requests are frozen after successful preflight without waiting for the new bitmap")
            t.check(host.primaryRelease(at: inside) == nil, "the press was consumed once")
            host.frames.runLoopTurn(.beforeWaiting)
            host.take(facts(input, pointer: false), input: input)
            host.primaryPress(at: inside)
            t.check(host.primaryRelease(at: inside) == nil, "ineligible pointer cannot produce requests")
            host.take(facts(input), input: input); host.primaryPress(at: inside)
            host.refresh()
            t.check(host.primaryRelease(at: inside) == nil, "an owner scene ahead of the actual bitmap rejects stale hit input")
            t.equal(textValues(host), ["1"], "ordinary re-projection does not replay actions")
        }

        t.suite("App: Desk click actions: failed bitmap-owner projection returns no requests") {
            let source = #"widget { variable size = 20; Text("Fail safely").font(size).size(160, 40).onClick { size = 0; copy("must not escape") } }"#
            let input = try ownerInput(), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
            let host = try DeskProgramHost(program: compile(source, t), executor: time, provider: provider,
                                          input: input, clock: time.clock)
            defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
            host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
            host.primaryPress(at: SkinPoint(x: 20, y: 20))
            t.check(host.primaryRelease(at: SkinPoint(x: 20, y: 20)) == nil)
            t.check(host.scene == nil && host.presented == nil, "failed layout retains no actionable picture")
            host.refresh()
            t.equal(textValues(host), ["Fail safely"], "the failed font assignment did not commit")
        }

        t.suite("App: Desk click actions: invalid owner clock boundary rejects variables and requests before commit") {
            let source = #"widget { variable n = 0; Row { Text(n).font(20).size(80, 40).onClick { n = n + 1; copy("{n}") }; Text(cpu.usage).font(20).size(80, 40) } }"#
            let input = try ownerInput(), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
            let system = DrawingSystemFixture()
            var instant = time.clock.now()
            let clock = SkinClock(now: { instant }, uptime: time.clock.uptime, timeZone: time.clock.timeZone)
            let host = try DeskProgramHost(program: compile(source, t), executor: time, provider: provider,
                                          input: input, clock: clock, system: system)
            defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
            host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
            t.equal(host.clockPrecision, .second)
            // VirtualTimeExecutor has no live run loop: SkinFrameProducer.start queues one immediate join.
            // Finish that lifecycle work before checking the independent future CPU clock lease.
            t.equal(time.nextDue, time.now, "the initial pending item is the immediate frame-producer registration")
            t.equal(time.runUntilIdle(), 1, "only the immediate run-loop registration is drained")
            t.equal(time.pendingCount, 1, "the future CPU boundary remains registered")
            t.close((time.nextDue ?? -1) - time.now, 0.75, "the CPU timer still targets the next second")
            host.primaryPress(at: SkinPoint(x: 20, y: 20))
            instant = Date(timeIntervalSince1970: .nan)
            t.check(host.primaryRelease(at: SkinPoint(x: 20, y: 20)) == nil)
            t.equal(host.state, .unavailable(String(describing: ProgramRuntimeError.invalidDateInput)))
            t.equal(time.pendingCount, 0, "the invalid boundary cancels the actual CPU clock lease")
            instant = time.clock.now()
            host.refresh()
            t.equal(textValues(host).first, "0", "the delay failure cannot commit the earlier assignment")
        }
    }

    private static func pointerTests(_ t: AppTestRunner) {
        t.suite("App: Desk bitmap owner: presented coordinates pointer facts and held presses govern real assignments") {
            let source = #"widget { variable n = 1; Row(spacing: 0, align: .top) { Rectangle().size(24, 18).stroke(.accent, width: 4).onClick { n = n + 1 }; Text(n).font(20).size(40, 30); Text("{time.now, format: "HH:mm:ss"}").font(20).size(160, 40) } }"#
            let program = try compile(source, t)
            for scale in [1, 2] {
                let input = try ownerInput(scale: scale), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
                let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: input, clock: time.clock)
                defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
                host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
                t.equal(host.presented?.origin, SkinPoint(x: -2, y: -2))
                t.equal(textValues(host), ["1", "09:00:59"])
                let first = try presentedBytes(provider)
                // The outer stroke paints here, but the original layout box does not catch this point.
                host.primaryPress(at: SkinPoint(x: 1, y: 6)); host.primaryRelease(at: SkinPoint(x: 1, y: 6))
                t.equal(textValues(host).first, "1", "viewport origin is added exactly once")
                let inside = SkinPoint(x: 2.5, y: 6)
                host.primaryPress(at: inside); host.primaryRelease(at: inside); host.frames.runLoopTurn(.beforeWaiting)
                t.equal(textValues(host).first, "2")
                let second = try presentedBytes(provider)
                t.check(second != first, "a real local assignment changes actual provider pixels")
                host.take(facts(input, pointer: false), input: input)
                host.primaryPress(at: inside); host.primaryRelease(at: inside); host.frames.runLoopTurn(.beforeWaiting)
                t.equal(textValues(host).first, "2", "takesPointer false blocks the action itself")
                t.equal(try presentedBytes(provider), second)
                host.take(facts(input), input: input); host.primaryPress(at: inside)
                host.take(facts(input, pointer: false), input: input)
                host.take(facts(input), input: input); host.primaryRelease(at: inside)
                t.equal(textValues(host).first, "2", "losing eligibility cancels an already held press")
                host.take(facts(input, seen: false), input: input)
                host.primaryPress(at: inside); host.primaryRelease(at: inside)
                t.equal(textValues(host).first, "2", "occlusion does not borrow the clock's ordered-in eligibility")
                host.take(facts(input), input: input)
                host.refresh() // New scene, still the previous picture until this executor's frame turn.
                host.primaryPress(at: inside); host.primaryRelease(at: inside)
                t.equal(textValues(host).first, "2", "an unpresented generation cannot accept a bitmap-coordinate action")
                host.frames.runLoopTurn(.beforeWaiting)
                host.primaryPress(at: inside)
                time.advance(until: 0.75); host.frames.runLoopTurn(.beforeWaiting)
                t.equal(textValues(host), ["2", "09:01:00"])
                host.primaryRelease(at: inside); host.frames.runLoopTurn(.beforeWaiting)
                t.equal(textValues(host), ["3", "09:01:00"], "a legal boundary tick retains the same source/element press")
                let third = try presentedBytes(provider)
                host.primaryPress(at: inside); host.primaryRelease(at: SkinPoint(x: 90, y: 6))
                host.primaryRelease(at: inside)
                t.equal(textValues(host).first, "3", "a missed release consumes the press rather than replaying it")
                t.check(third != second)
                host.close(); time.advance(until: 11)
                t.equal(time.pendingCount, 0)
            }
        }
    }

    private static func secondaryPointerTests(_ t: AppTestRunner) {
        t.suite("App: Desk pointer events: bitmap owner samples only the selected transaction and consumes empty secondary handlers") {
            let source = #"widget { variable n = 0; Row(spacing: 0) { Text(n).font(20).size(80, 40).onClick { n = n + 10; copy("{cpu.usage}") }.onRightClick { n = n + 1; copy("{n}"); copy("{memory.used, unit: .gib, unitStyle: .none, decimals: 0}"); open("https://example.com/{n}") }; Text("Empty").size(80, 40).onRightClick { } } }"#
            let input = try ownerInput(), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
            let system = DrawingSystemFixture()
            let host = try DeskProgramHost(program: compile(source, t), executor: time, provider: provider,
                                          input: input, clock: time.clock, system: system)
            defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
            host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
            t.equal(system.cpuCalls, 0); t.equal(system.memCalls, 0)
            let point = SkinPoint(x: 20, y: 20)
            t.check(host.secondaryRelease(at: point) == nil, "secondary release requires its own press")
            host.primaryPress(at: point)
            t.check(host.secondaryRelease(at: point) == nil, "a primary press cannot authorize the secondary event")
            host.secondaryPress(at: point)
            t.equal(host.secondaryRelease(at: point), [.copy("1"), .copy("8"), .open("https://example.com/1")])
            t.equal(system.cpuCalls, 0); t.equal(system.memCalls, 1)
            t.equal(textValues(host).first, "1")
            t.check(host.secondaryRelease(at: point) == nil)
            host.frames.runLoopTurn(.beforeWaiting)
            t.equal(host.primaryRelease(at: point), [.copy("25")], "the independent primary press retains its own handler")
            t.equal(system.cpuCalls, 1); t.equal(system.memCalls, 1)
            t.equal(textValues(host).first, "11")
            host.frames.runLoopTurn(.beforeWaiting)
            let before = host.scene?.generation
            host.secondaryPress(at: SkinPoint(x: 100, y: 20))
            t.equal(host.secondaryRelease(at: SkinPoint(x: 100, y: 20)), [])
            t.equal(host.scene?.generation, before.map { $0 + 1 }, "empty secondary handlers commit a consumed click")
        }

        t.suite("App: Desk pointer events: bitmap secondary hit identity origin ticks and cancellation stay qualified") {
            let source = #"widget { variable n = 0; Row(spacing: 0, align: .top) { Rectangle().size(24, 18).stroke(.accent, width: 4).onRightClick { n = n + 1; copy("{n}") }; Text(n).size(40, 30).onRightClick { copy("other") }; Text("{time.now, format: "HH:mm:ss"}").size(160, 40) } }"#
            for scale in [1, 2] {
                let input = try ownerInput(scale: scale), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
                let host = try DeskProgramHost(program: compile(source, t), executor: time, provider: provider,
                                              input: input, clock: time.clock)
                defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
                host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
                t.equal(host.presented?.origin, SkinPoint(x: -2, y: -2))
                host.secondaryPress(at: SkinPoint(x: 1, y: 6))
                t.check(host.secondaryRelease(at: SkinPoint(x: 1, y: 6)) == nil, "stroke outside the original box is not a handler")
                let point = SkinPoint(x: 2.5, y: 6)
                host.secondaryPress(at: point)
                time.advance(until: 0.75); host.frames.runLoopTurn(.beforeWaiting)
                t.equal(host.secondaryRelease(at: point), [.copy("1")], "a real boundary tick preserves a legal secondary press")
                host.frames.runLoopTurn(.beforeWaiting)
                host.secondaryPress(at: point)
                t.check(host.secondaryRelease(at: SkinPoint(x: 35, y: 6)) == nil, "a different valid handler cannot receive the press")
                t.check(host.secondaryRelease(at: point) == nil)
                host.secondaryPress(at: point); host.secondaryRelease(at: nil)
                t.check(host.secondaryRelease(at: point) == nil, "explicit cancellation consumes the press")
                host.secondaryPress(at: point)
                host.take(facts(input, pointer: false), input: input)
                host.take(facts(input), input: input)
                t.check(host.secondaryRelease(at: point) == nil, "restoring eligibility does not restore a cancelled press")
                host.secondaryPress(at: point); host.refresh()
                t.check(host.secondaryRelease(at: point) == nil, "an unpresented owner generation cannot qualify the release")
                host.frames.runLoopTurn(.beforeWaiting)
                host.secondaryPress(at: point); host.close()
                t.check(host.secondaryRelease(at: point) == nil)
                t.equal(textValues(host), [])
            }
        }

        t.suite("App: Desk pointer events: failed secondary bitmap projection releases no external requests") {
            let source = #"widget { variable points = 20; Text("Right").font(points).size(80, 40).onRightClick { points = 0; copy("must not escape") } }"#
            let input = try ownerInput(), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
            let host = try DeskProgramHost(program: compile(source, t), executor: time, provider: provider, input: input, clock: time.clock)
            defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
            host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
            host.secondaryPress(at: SkinPoint(x: 20, y: 20))
            t.check(host.secondaryRelease(at: SkinPoint(x: 20, y: 20)) == nil)
            t.check(host.scene == nil && host.presented == nil)
            host.refresh()
            t.equal(textValues(host), ["Right"], "the rejected font assignment did not commit")
        }
    }

    private static func failureTests(_ t: AppTestRunner) {
        t.suite("App: Desk bitmap owner: initial facts profile and recoverable errors never publish stale pixels") {
            let program = try compile(#"widget { variable n = 1; computed points = system.dark ? 0 : 20; Text(n).font(points).color(.accent).size(80, 40).padding(4).onClick { n = n + 1 } }"#, t)
            let light = try ownerInput(), dark = try ownerInput(.darkAqua), time = try ownerClock()
            let view = NSView(), provider = BitmapProvider(view)
            let host = try DeskProgramHost(program: program, executor: time, provider: provider, input: light, clock: time.clock)
            defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
            host.start(); host.drawFirstFrame()
            if case .unavailable = host.state { t.check(true) } else { t.check(false, "start before facts is not a default sRGB success") }
            t.equal(provider.content.state.presented, 0); t.check(host.presented == nil)
            host.take(facts(light, ordered: false, seen: false), input: light)
            t.equal(host.state, .ready)
            host.drawFirstFrame()
            t.equal(provider.content.state.presented, 1, "valid first facts draw before the window is ordered in")
            t.equal(textValues(host), ["1"])
            host.take(facts(light), input: light); host.frames.runLoopTurn(.beforeWaiting)
            host.primaryPress(at: SkinPoint(x: 20, y: 20)); host.primaryRelease(at: SkinPoint(x: 20, y: 20))
            host.frames.runLoopTurn(.beforeWaiting)
            t.equal(textValues(host), ["2"])
            let second = try presentedBytes(provider), count = provider.content.state.presented
            weak var failedCache = host.context
            host.take(facts(dark), input: dark)
            if case .unavailable = host.state { t.check(true) } else { t.check(false, "the actual invalid point font fails") }
            t.check(provider.content.shown.image == nil && host.scene == nil && host.presented == nil)
            t.check(failedCache == nil, "the failed scene's graphics context is released")
            host.drawFirstFrame(); host.primaryPress(at: SkinPoint(x: 20, y: 20)); host.primaryRelease(at: SkinPoint(x: 20, y: 20))
            t.equal(provider.content.state.presented, count, "failure is not a successful empty presentation")
            host.take(facts(light), input: light); host.drawFirstFrame()
            t.equal(textValues(host), ["2"], "recovery preserves the successful variable transaction, not startup defaults")
            t.equal(try presentedBytes(provider), second)
            for profile in [nil, CGColorSpaceCreateDeviceGray()] as [CGColorSpace?] {
                let before = provider.content.state.presented
                host.take(facts(light, space: profile), input: light); host.drawFirstFrame()
                t.check(provider.content.shown.image == nil && host.presented == nil)
                t.equal(provider.content.state.presented, before)
                host.take(facts(light), input: light); host.drawFirstFrame()
                t.equal(host.state, .ready)
                t.equal(try presentedBytes(provider), second, "same scale/appearance valid RGB facts recover without a changed input")
            }
            for mode in [SkinFrameContentMode.layers(partition: .single, maximumOwnedBitmapBytes: 16 << 20),
                         .layers(partition: .single, maximumOwnedBitmapBytes: 16 << 20,
                                 backend: .nativeSingle(maximumCallbackBitmapBytes: 16 << 20))] {
                do {
                    _ = try DeskProgramHost(program: program, executor: time, provider: provider, input: light, contentMode: mode)
                    t.check(false, "Desk layer intent cannot quietly succeed as bitmap")
                } catch let error as DeskProgramHost.Failure { t.equal(error, .unsupportedContentMode) }
            }

            guard let scene = host.scene else { throw Failure.bitmap }
            host.close()
            let context = SkinRenderContext()
            var origin = SkinPoint(), allowed = true, successes = 0, failures = 0
            let frames = SkinFrameProducer(provider: provider, bitmapCapture: { _, _ in
                SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: 1, size: CGSize(width: 80, height: 40),
                                          source: "bitmap result", origin: origin)
            }, bitmapValidation: { _, _ in allowed })
            frames.bitmapResult = { [weak frames] result in
                switch result {
                case .presented: successes += 1
                case .failed: failures += 1; frames?.clearBitmapContents()
                }
            }
            frames.take(facts(light)); frames.setNeedsFrame(); frames.drawFirstFrame()
            t.equal(successes, 1); t.equal(failures, 0)
            origin = SkinPoint(x: .nan)
            frames.setNeedsFrame(); frames.runLoopTurn(.beforeWaiting)
            t.equal(successes, 1); t.equal(failures, 1); t.check(provider.content.shown.image == nil)
            origin = SkinPoint(); allowed = false
            frames.setNeedsFrame(); frames.drawFirstFrame()
            t.equal(successes, 1); t.equal(failures, 2, "a failed actual-destination qualification is never presented")
            allowed = true
            frames.setNeedsFrame(); frames.drawFirstFrame()
            t.equal(successes, 2); t.equal(try presentedBytes(provider), second)
            frames.stop(); frames.clearBitmapContents()
        }
    }

    private static func imageOwnerTests(_ t: AppTestRunner) {
        t.suite("App: Desk bitmap owner: dedicated prepared pictures survive preview cleanup and retire with their owner") {
            let root = t.temporaryDirectory("desk-owner-pictures"), original = root.appendingPathComponent("picture.png")
            let picture = try referenceBitmap(CGSize(width: 4, height: 2), scale: 1) { ctx in
                for (rect, color) in [(CGRect(x: 0, y: 0, width: 2, height: 1), RGBA(r: 220, g: 40, b: 20)),
                                      (CGRect(x: 2, y: 0, width: 2, height: 1), RGBA(r: 20, g: 60, b: 220)),
                                      (CGRect(x: 0, y: 1, width: 2, height: 1), RGBA(r: 30, g: 180, b: 70)),
                                      (CGRect(x: 2, y: 1, width: 2, height: 1), RGBA(r: 230, g: 170, b: 20))] {
                    ctx.setFillColor(color.cgColor); ctx.fill(rect)
                }
            }
            let output = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw Failure.bitmap }
            CGImageDestinationAddImage(encoder, picture, nil)
            guard CGImageDestinationFinalize(encoder) else { throw Failure.bitmap }
            let sourceBytes = output as Data
            try sourceBytes.write(to: original)
            for scale in [1, 2] {
                let prepared = DeskProgramResources.prepare(root: root, literals: ["picture.png"], maximumBytes: 4096, maximumFiles: 1)
                let preview = DeskProgramResources.prepare(root: root, literals: ["picture.png"], maximumBytes: 4096, maximumFiles: 1)
                defer { prepared.removeCopies(); preview.removeCopies() }
                t.equal(prepared.failure, nil); t.equal(preview.failure, nil)
                guard let folder = prepared.folder, let previewFolder = preview.folder,
                      let resource = prepared.images["picture.png"] else { throw Failure.bitmap }
                t.check(folder != previewFolder)
                let source = #"widget { Image("picture.png").size(40, 20).imageMode(.stretch) }"#
                let checked = Desk.check(Desk.parse(source, fileName: "Picture.desk"), context: CheckContext(
                    resources: PackageResources(package: DeskPackage(files: prepared.files))))
                let compiled = Desk.compile(checked)
                t.check(compiled.diagnostics.allSatisfy { $0.severity != .error }); t.check(compiled.issues.isEmpty)
                guard let program = compiled.program else { throw Failure.compilation }
                preview.removeCopies()
                t.check(!FileManager.default.fileExists(atPath: previewFolder.path)); t.check(prepared.unchanged())
                let input = try ownerInput(scale: scale), time = try ownerClock(), view = NSView(), provider = BitmapProvider(view)
                let host = try DeskProgramHost(program: program, executor: time, provider: provider,
                    input: input, prepared: prepared, clock: time.clock)
                defer { host.close(); provider.teardown(); withExtendedLifetime(view) {} }
                host.take(facts(input), input: input); host.start(); host.drawFirstFrame()
                t.equal(host.state, .ready)
                let expected = try referenceBitmap(CGSize(width: 40, height: 20), scale: scale) { ctx in
                    ctx.translateBy(x: 0, y: 20); ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(picture, in: CGRect(x: 0, y: 0, width: 40, height: 20))
                }
                let before = try presentedBytes(provider)
                t.equal(before, try bitmapBytes(expected), "the real image leaf matches independent native sampling")
                t.check(stride(from: 3, to: before.count, by: 4).contains { before[$0] != 0 })
                let retained = provider.content.shown.image
                try Data("invalid private generation".utf8).write(to: URL(fileURLWithPath: resource.path))
                let count = provider.content.state.presented
                host.frames.setNeedsFrame(); host.frames.runLoopTurn(.beforeWaiting)
                t.check(provider.content.shown.image == nil && host.presented == nil)
                t.equal(provider.content.state.presented, count, "a changed file cannot reuse a previous decoded/cached picture")
                host.close()
                t.check(!FileManager.default.fileExists(atPath: folder.path))
                t.equal(try bitmapBytes(retained), before)
                t.equal(try Data(contentsOf: original), sourceBytes, "the approved original image is read only")
            }
        }

        t.suite("App: Desk bitmap owner: system data bindings render and advance across clock boundaries") {
            let program = try compile(#"widget { Text("{cpu.usage}%").font(20).color(.accent) }"#, t)
            let input = try ownerInput(.aqua, scale: 1), time = try ownerClock()
            let view = NSView(), provider = BitmapProvider(view)
            let system = DrawingSystemFixture()
            var host: DeskProgramHost? = try DeskProgramHost(program: program, executor: time, provider: provider,
                                                             input: input, clock: time.clock, system: system)
            defer { host?.close(); provider.teardown(); withExtendedLifetime(view) {} }
            guard let live = host else { throw Failure.bitmap }
            var presented: DeskProgramHost.Presented?
            live.didPresent = { presented = $0 }
            live.take(facts(input), input: input); live.start(); live.drawFirstFrame()
            t.equal(live.state, .ready)
            t.equal(live.clockPrecision, .second)
            guard let scene1 = live.scene else { throw Failure.bitmap }
            let text1 = scene1.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
            t.equal(text1, ["25%"])
            t.equal(presented?.scene.generation, scene1.generation)

            // Advance system state and tick clock
            system.cpu = 75.0
            _ = time.advance(by: 1.0)
            live.frames.runLoopTurn(.beforeWaiting)
            guard let scene2 = live.scene else { throw Failure.bitmap }
            let text2 = scene2.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
            t.equal(text2, ["75%"])
            t.check(scene2.generation > scene1.generation)
            host?.close(); host = nil

            // Hidden host invalidates battery on power change without projecting; updates when visible
            let batProgram = try compile(#"widget { Text(battery.charging ? "Charging" : "Discharging").font(20) }"#, t)
            let batHost = try DeskProgramHost(program: batProgram, executor: time, provider: provider,
                                              input: input, clock: time.clock, system: system)
            batHost.take(facts(input), input: input); batHost.start(); batHost.drawFirstFrame()
            guard let batScene1 = batHost.scene else { throw Failure.bitmap }
            let batText1 = batScene1.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
            t.equal(batText1, ["Discharging"])
            let batGen1 = batScene1.generation

            // Hide the host
            batHost.take(facts(input, ordered: false), input: input)
            system.batteryCharging = true

            // Power notification while hidden: cache invalidated, but no projection
            batHost.notifyPowerChange()
            t.equal(batHost.scene?.generation, batGen1, "hidden host does not project on power change")

            // Restoring visibility samples the fresh battery status
            batHost.take(facts(input, ordered: true), input: input)
            guard let batScene2 = batHost.scene else { throw Failure.bitmap }
            let batText2 = batScene2.drawingItems.compactMap { if case .text(let draw) = $0 { return draw.text }; return nil }
            t.equal(batText2, ["Charging"], "restored host projects fresh battery status invalidated while hidden")
            t.check(batScene2.generation > batGen1)
            batHost.close()

            // Mixed CPU 1s and Memory 2s reading count regression
            let mixedProgram = try compile(#"widget { Text("{cpu.usage}% {memory.used, unit: .gib}").font(20) }"#, t)
            let mixedHost = try DeskProgramHost(program: mixedProgram, executor: time, provider: provider,
                                                input: input, clock: time.clock, system: system)
            defer { mixedHost.close() }
            let cpuStart = system.cpuCalls, memStart = system.memCalls
            mixedHost.take(facts(input), input: input); mixedHost.start(); mixedHost.drawFirstFrame()
            t.equal(system.cpuCalls, cpuStart + 1)
            t.equal(system.memCalls, memStart + 1)

            // Advance 1s: CPU sampled, memory NOT sampled (needs 2s)
            _ = time.advance(by: 1.0)
            mixedHost.frames.runLoopTurn(.beforeWaiting)
            t.equal(system.cpuCalls, cpuStart + 2, "CPU sampled at 1s tick")
            t.equal(system.memCalls, memStart + 1, "Memory not re-sampled at 1s tick (needs 2s)")

            // Advance another 1s (total 2s): CPU and Memory both sampled
            _ = time.advance(by: 1.0)
            mixedHost.frames.runLoopTurn(.beforeWaiting)
            t.equal(system.cpuCalls, cpuStart + 3, "CPU sampled at 2s tick")
            t.equal(system.memCalls, memStart + 2, "Memory sampled at 2s boundary")
        }
    }

    private final class ReleaseProbe {
        let executor: SkinExecutor
        let result: Guarded<[(Bool, Bool)]>
        init(_ executor: SkinExecutor, _ result: Guarded<[(Bool, Bool)]>) { self.executor = executor; self.result = result }
        deinit { result.access { $0.append((executor.isCurrent, Thread.isMainThread)) } }
    }
    private final class WeakOwner { weak var context: SkinRenderContext? }

    private static func liveOwner(_ t: AppTestRunner, worker: Bool) throws {
        let program = try compile(#"widget { Text("{time.now, format: "HH:mm:ss"}").font(20).color(.accent).size(160, 40).padding(4) }"#, t)
        let executor: SkinExecutor = worker ? SkinThreadExecutor(name: "Desk bitmap owner") : MainSkinExecutor.shared
        let input = try ownerInput(), view = NSView(), provider = BitmapProvider(view)
        let held = Guarded<DeskProgramHost?>(nil), errors = Guarded<[String]>([]), releases = Guarded<[(Bool, Bool)]>([])
        let callbacks = Guarded<[Bool]>([]), unavailable = Guarded<[Bool]>([]), invalidDate = Guarded(false), weakOwner = WeakOwner()
        let time = try ownerClock(), fixed = SkinClock.fixed(time.wallClock, timeZone: time.timeZone)
        defer {
            _ = executor.exclusive(timeout: 30) { held.access { $0?.close(); $0 = nil } }
            provider.teardown(); (executor as? SkinThreadExecutor)?.stop(); withExtendedLifetime(view) {}
        }
        executor.async {
            do {
                let probe = ReleaseProbe(executor, releases)
                let clock = SkinClock(now: { withExtendedLifetime(probe) {
                    invalidDate.current ? Date(timeIntervalSince1970: .nan) : fixed.now()
                } }, uptime: fixed.uptime, timeZone: fixed.timeZone)
                let host = try DeskProgramHost(program: program, executor: executor, provider: provider, input: input, clock: clock)
                weakOwner.context = host.context
                host.didPresent = { _ in callbacks.access { $0.append(executor.isCurrent && Thread.isMainThread != worker) } }
                host.didBecomeUnavailable = { [weak host] _ in
                    unavailable.access { $0.append(executor.isCurrent && provider.content.shown.image == nil &&
                        host?.scene == nil && host?.presented == nil && host?.context == nil) }
                }
                host.take(facts(input), input: input); host.start()
                held.access { $0 = host }
            } catch { errors.access { $0.append(String(describing: error)) } }
        }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.state.presented >= 2 || !errors.current.isEmpty },
                "an actual executor timer and frame turn deliver both initial and boundary pictures")
        t.equal(errors.current, [])
        _ = executor.exclusive(timeout: 30) { held.current?.pause() }
        let before = provider.content.state.presented
        executor.async { for _ in 0..<5 { held.current?.refresh() } }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.state.presented > before })
        _ = executor.exclusive(timeout: 30) {}
        t.equal(provider.content.state.presented, before + 1, "five synchronous transactions coalesce into one actual frame")
        t.check(callbacks.current.count >= 3 && callbacks.current.allSatisfy { $0 })
        t.check(provider.threads.current.allSatisfy { $0 != worker })
        t.equal(try presentedBytes(provider), try clockReference("09:00:59", input: input, scale: 1))
        _ = executor.exclusive(timeout: 30) {
            held.current?.resume(updateNow: false)
            invalidDate.access { $0 = true }
        }
        t.check(AppSelfTest.spin(timeout: 30) { !unavailable.current.isEmpty }, "the real boundary callback reaches an invalid temporal input")
        t.equal(unavailable.current, [true], "failure delivery is owner-confined and follows clearing pixels, hit state and cache")
        _ = executor.exclusive(timeout: 30) { held.current?.refresh() }
        t.equal(unavailable.current, [true], "repeating the same failure does not flood the window")
        _ = executor.exclusive(timeout: 30) {
            invalidDate.access { $0 = false }
            held.current?.refresh(); held.current?.pause()
            weakOwner.context = held.current?.context
        }
        t.check(AppSelfTest.spin(timeout: 30) { provider.content.shown.image != nil })
        t.equal(try presentedBytes(provider), try clockReference("09:00:59", input: input, scale: 1))
        _ = executor.exclusive(timeout: 30) {
            held.current?.close()
            invalidDate.access { $0 = true }
            held.current?.refresh(); held.current?.wake()
        }
        t.equal(unavailable.current, [true], "closed owners deliver no late failure or recovery notification")
        if worker { held.access { $0 = nil } }
        else { DispatchQueue.global().async { held.access { $0 = nil } } }
        t.check(AppSelfTest.spin(timeout: 30) { !releases.current.isEmpty && weakOwner.context == nil })
        t.equal(releases.current.count, 1)
        t.check(releases.current.allSatisfy { $0.0 && $0.1 != worker })
        t.check(provider.content.shown.image == nil, "the final owner release clears its frame")
        t.equal(executor.exclusive(timeout: 30) { executor.isCurrent }, true, "closing one owner does not stop a shared executor")
        t.equal(errors.current, [])
    }

    private static func compile(_ source: String, _ t: AppTestRunner) throws -> WidgetProgram {
        let checked = Desk.check(Desk.parse(source, fileName: "NativeText.desk"))
        let result = Desk.compile(checked)
        t.check(!result.diagnostics.contains { $0.severity == .error }, "the native fixture passes the real checker")
        t.check(result.issues.isEmpty, "\(result.issues)")
        guard let program = result.program else { throw Failure.compilation }
        return program
    }

    private static func environment(_ appearance: SkinAppearance) -> EnvironmentStamp {
        EnvironmentStamp(scale: 1, fontGeneration: 0, appearance: AppearanceStamp(value: appearance, name: "native fixture"),
                         imageGeneration: 0)
    }

    /// Explicit renderer-side values, independent of the program's style adapter.
    private static func referenceStyle(points: Double, color: RGBA) -> TextStyle {
        var style = TextStyle()
        style.fontFace = "System"
        style.fontSize = points * 0.75
        style.fontWeight = 400
        style.color = color
        style.horizontalAlign = .center
        style.verticalAlign = .center
        style.accurateText = true
        style.antiAlias = true
        style.trailingSpaces = true
        return style
    }

    private static func pixels(_ items: [DrawItem], size: SkinSize, scale: Int, context: DrawContext) throws -> Data {
        let width = Int(ceil(size.width * Double(scale))), height = Int(ceil(size.height * Double(scale)))
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = canvas.data else { throw Failure.bitmap }
        canvas.clear(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        DesksetDraw.DrawExecutor.draw(items, in: canvas, context: context, cycle: 1,
                          target: DrawTarget.prepareOwnedBitmap(canvas, glass: .none))
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(bytes.advanced(by: row * canvas.bytesPerRow).assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        return result
    }
}

private final class DrawingSystemFixture: SystemDataSource {
    var cpu: Double = 25.0
    var processorCount: Int = 4
    var batteryCharging: Bool = false
    var cpuCalls: Int = 0
    var memCalls: Int = 0
    var batteryCalls: Int = 0
    func cpuUsage(processor: Int) -> Double { cpuCalls += 1; return cpu }
    func memoryStatus() -> MemoryStatus { memCalls += 1; return MemoryStatus(physicalTotal: 16 * 1024 * 1024 * 1024, physicalUsed: 8 * 1024 * 1024 * 1024) }
    func networkInterfaces() -> [String] { [] }
    func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
    func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
    func availableDiskSpace(path: String) -> Double? { nil }
    func uptime() -> TimeInterval { 3600 }
    func battery() -> BatteryStatus? { batteryCalls += 1; return BatteryStatus(percent: 80, isCharging: batteryCharging, isPluggedIn: true) }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
    func bestNetworkInterface() -> String? { nil }
    func volumeInfo(path: String) -> VolumeInfo? { nil }
    func cpuFrequency() -> Double? { nil }
    func desktopPicturePath() -> String? { nil }
    func graphicsAdapterName() -> String? { nil }
}
