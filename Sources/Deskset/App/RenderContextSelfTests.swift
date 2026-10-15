import AppKit
import DesksetCore

/// The renderer's caches belong to one skin each (docs/skin-threading.md §4.3, phase 1): its text layouts, Rotator
/// images and Histogram scratch space live in the skin's `SkinRenderContext`, which only the skin's owner touches, so
/// skins drawn on threads of their own never share one. These suites check that each skin has its own, that measuring
/// and drawing share the skin's layouts, that the caches stay small and go with the skin, and that colors no longer go
/// through AppKit.
enum RenderContextSelfTests {
    static func run(_ t: AppTestRunner) {
        #if DEBUG
        roundDrawTests(t)
        roundCapTests(t)
        #endif
        t.suite("App: skin threading: each skin measures and draws with text layouts of its own") {
            let ini = "[Rainmeter]\nUpdate=-1\n[Title]\nMeter=String\nText=Hello there\nFontSize=12\n"
                + "[Info]\nMeter=String\nY=20\nText=Second line\nFontSize=10\n"
            let (a, hostA) = try MediaUITests.bareSkin(t, ini)
            let (b, hostB) = try MediaUITests.bareSkin(t, ini)
            a.update()
            b.update()
            let ca = SkinRenderContext.of(a), cb = SkinRenderContext.of(b)
            t.check(ca !== cb, "two skins, two contexts")
            t.check(SkinRenderContext.of(a) === ca, "one context per skin")
            t.check(ca.text.builds > 0 && cb.text.builds > 0, "each skin measured its texts with its own layouts")
            let (builtA, builtB, storedB) = (ca.text.builds, cb.text.builds, cb.text.storedCount)
            _ = AppSelfTest.drawSkin(a, width: 200, height: 60)
            t.equal(ca.text.builds, builtA, "drawing uses the layouts the texts were measured with")
            t.equal(cb.text.builds, builtB, "drawing one skin builds nothing in the other")
            t.equal(cb.text.storedCount, storedB, "and leaves its layouts alone")
            if let ma = a.meter(named: "Title") as? StringMeter, let mb = b.meter(named: "Title") as? StringMeter {
                let la = ca.text.layout(ma.text, style: ma.style, wrapWidth: nil, cycle: a.updateCount)
                let lb = cb.text.layout(mb.text, style: mb.style, wrapWidth: nil, cycle: b.updateCount)
                t.check(la !== lb, "the same text in two skins: a layout in each")
            } else {
                t.check(false, "String meters")
            }
            withExtendedLifetime((hostA, hostB)) {}
        }

        t.suite("App: skin threading: text layouts a skin keeps showing are not built again; changing ones do not pile up") {
            // A small skin: three fixed labels, a counter (a new text on every update) and a text that goes round
            // three values.
            var small = "[Rainmeter]\nUpdate=1000\n[Count]\nMeasure=Calc\nFormula=Counter\n"
                + "[Round]\nMeasure=Calc\nFormula=Counter % 3\n"
                + "[Tick]\nMeter=String\nMeasureName=Count\nText=%1\n"
                + "[Step]\nMeter=String\nMeasureName=Round\nY=16\nText=Step %1\n"
            for i in 0..<3 { small += "[Fixed\(i)]\nMeter=String\nY=\(32 + 16 * i)\nText=Label \(i)\n" }
            let (skin, host) = try MediaUITests.bareSkin(t, small)
            let cycles = 150
            let smallBuilds = try runCycles(skin, count: cycles)
            // From the fourth update on, the three values of the round have been shown.
            t.equal(smallBuilds[cycles - 1] - smallBuilds[3], cycles - 4,
                    "one new layout per update (the counter's): the labels and the round's three texts are kept")
            let context = SkinRenderContext.of(skin)
            t.check(context.text.storedCount <= 2 * (TextLayoutCache.turnoverFloor + 8),
                    "a few dozen layouts, not one per update: \(context.text.storedCount)")

            // A large skin (more texts than the turnover floor): fixed labels, a counter, and texts that come back
            // every third and every fifth update.
            var large = "[Rainmeter]\nUpdate=1000\n[Count]\nMeasure=Calc\nFormula=Counter\n"
                + "[Round]\nMeasure=Calc\nFormula=Counter % 3\n[Week]\nMeasure=Calc\nFormula=Counter % 5\n"
                + "[Tick]\nMeter=String\nMeasureName=Count\nText=%1\n"
                + "[Step]\nMeter=String\nMeasureName=Round\nX=40\nText=Step %1\n"
                + "[Day]\nMeter=String\nMeasureName=Week\nX=80\nText=Day %1\n"
            let labels = TextLayoutCache.turnoverFloor + 36
            for i in 0..<labels { large += "[Fixed\(i)]\nMeter=String\nX=\(i % 10 * 40)\nY=\(16 + i / 10 * 16)\nText=Label \(i)\n" }
            let (big, bigHost) = try MediaUITests.bareSkin(t, large)
            let bigBuilds = try runCycles(big, count: cycles)
            // From the sixth update on, every value of both rounds has been shown.
            t.equal(bigBuilds[cycles - 1] - bigBuilds[5], cycles - 6,
                    "one new layout per update: \(labels) labels and the rounds' texts are never built again")
            let bigContext = SkinRenderContext.of(big)
            t.check(bigContext.text.storedCount <= 4 * (labels + 12),
                    "the layouts of a few dozen updates: \(bigContext.text.storedCount)")

            // More layouts in one update than the limit: bounded all the same.
            let style = TextStyle()
            for i in 0..<(TextLayoutCache.cacheLimit + 500) {
                _ = bigContext.text.layout("Text \(i)", style: style, wrapWidth: nil, cycle: big.updateCount)
            }
            t.check(bigContext.text.storedCount <= 2 * TextLayoutCache.cacheLimit,
                    "bounded by the limit: \(bigContext.text.storedCount)")
            withExtendedLifetime((host, bigHost)) {}
        }

        t.suite("App: skin threading: Rotator images and Histogram crops belong to their skin") {
            let folder = t.temporaryDirectory("render-context")
            let image = folder.appendingPathComponent("square.png")
            try writeTestImage(to: image)
            let ini = """
            [Rainmeter]
            Update=-1
            [Angle]
            Measure=Calc
            Formula=0.25
            [Needle]
            Meter=Rotator
            MeasureName=Angle
            ImageName=\(image.path)
            ImageTint=255,0,0
            W=40
            H=40
            OffsetX=8
            OffsetY=8
            [Level]
            Measure=Calc
            Formula=50
            MinValue=0
            MaxValue=100
            [Graph]
            Meter=Histogram
            MeasureName=Level
            Y=40
            W=20
            H=20
            PrimaryImage=\(image.path)
            PrimaryImageCrop=0,0,8,8
            """
            let (a, hostA) = try MediaUITests.bareSkin(t, ini)
            let (b, hostB) = try MediaUITests.bareSkin(t, ini)
            a.update()
            b.update()
            let ca = SkinRenderContext.of(a), cb = SkinRenderContext.of(b)
            let pictureA = AppSelfTest.drawSkin(a, width: 60, height: 60)
            t.equal(ca.rotatorImages.count, 1, "the tinted needle is kept in the skin that drew it")
            t.equal(ca.histogramCrops.count, 1, "and so is the cropped Histogram image")
            t.check(ca.histogramParts.contains { !$0.isEmpty }, "the Histogram's columns went into its scratch space")
            t.equal(cb.rotatorImages.count, 0, "nothing in the skin that has not drawn yet")
            t.equal(cb.histogramCrops.count, 0)
            t.check(cb.histogramParts.allSatisfy(\.isEmpty))
            let pictureB = AppSelfTest.drawSkin(b, width: 60, height: 60)
            t.equal(cb.rotatorImages.count, 1, "the other skin builds its own")
            t.equal(cb.histogramCrops.count, 1)
            t.equal(ca.rotatorImages.count, 1, "and leaves the first one's alone")
            t.check(pictureA?.tiffRepresentation != nil && pictureA?.tiffRepresentation == pictureB?.tiffRepresentation,
                    "both skins draw the same picture")
            withExtendedLifetime((hostA, hostB)) {}
        }

        t.suite("App: skin threading: Rotator images: a share for each skin, the old total for all of them") {
            // Scaled down: 256 KB images, a share of two of them per skin, eight for all skins.
            let budget = RotatorImageCache.Budget(total: 8 << 18, perSkin: 2 << 18)
            guard let canvas = Images.bitmapContext(width: 256, height: 256), let source = canvas.makeImage() else {
                return t.check(false, "an image")
            }
            var flipped = RotatorMeter.ImageProcessing()
            flipped.flipHorizontal = true
            func fill(_ cache: RotatorImageCache, _ name: String, _ count: Int) {
                for i in 0..<count { _ = cache.image(for: source, path: "\(name)\(i)", processing: flipped) }
            }
            var a: RotatorImageCache? = RotatorImageCache(budget: budget)
            let b = RotatorImageCache(budget: budget)
            fill(a!, "a", 6)
            t.equal(a?.count, 6, "alone, a skin keeps more than its share: the others do not need theirs")
            fill(b, "b", 4)
            t.equal(b.count, 2, "another skin keeps its share, and no more while the total is reached")
            t.equal(a?.count, 6, "and leaves the first one's alone")
            t.equal(budget.bytes, 8 << 18, "all skins together: the total")
            a = nil
            t.equal(budget.bytes, 2 << 18, "a skin's images go with it")
            fill(b, "c", 4)
            t.equal(b.count, 6, "and the other skin may keep more again")
        }

        t.suite("App: skin threading: a skin's render context goes with the skin") {
            weak var released: SkinRenderContext?
            try autoreleasepool {
                let (skin, host) = try MediaUITests.bareSkin(t, "[Rainmeter]\nUpdate=-1\n[T]\nMeter=String\nText=Bye\n")
                skin.update()
                _ = AppSelfTest.drawSkin(skin, width: 40, height: 20)
                released = SkinRenderContext.of(skin)
                t.check(released?.text.storedCount ?? 0 > 0)
                withExtendedLifetime(host) {}
            }
            t.check(AppSelfTest.spin(timeout: 60) { released == nil }, "released with its skin")

            // A refresh replaces the skin, and with it everything its renderer kept.
            guard let app = try AppSelfTest.makeApp(t),
                  let c = app.activate(config: "App\\Counter", file: nil) else { return }
            let before = SkinRenderContext.of(c.skin)
            app.refresh(c)
            guard let refreshed = app.controller(for: "App\\Counter") else { return t.check(false, "refreshed") }
            t.check(refreshed.skin !== c.skin, "a new skin")
            t.check(SkinRenderContext.of(refreshed.skin) !== before, "with a context of its own")
            app.stopAllForTermination()
        }

        t.suite("App: skin threading: colors are made by CoreGraphics, as AppKit made them") {
            let samples: [(Double, Double, Double, Double)] = [(0, 0, 0, 255), (255, 128, 1, 77), (12.5, 200.25, 3, 0),
                                                               (300, -20, 255, 500)]
            for (r, g, b, a) in samples {
                let color = RGBA(r: r, g: g, b: b, a: a).cgColor
                let appKit = NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 255).cgColor
                t.check(color == appKit, "\(r),\(g),\(b),\(a): \(color) = \(appKit)")
                t.equal(color.colorSpace?.name.map { $0 as String }, CGColorSpace.sRGB as String)
            }
        }
    }

    #if DEBUG
    private static func roundDrawTests(_ t: AppTestRunner) {
        let formats = [(1, false), (1, true), (2, false), (2, true)]
        t.suite("App: round drawing values: Roundline keeps its pixels after its meter changes and goes away") {
            for solid in [false, true] {
                weak var releasedSkin: Skin?
                weak var releasedMeter: RoundlineMeter?
                let frozen = try autoreleasepool { () throws -> (draw: RoundlineDraw, pixels: [Data]) in
                    let (skin, host) = try MediaUITests.bareSkin(t, """
                    [Rainmeter]
                    Update=-1
                    [Variables]
                    Value=20
                    [Angle]
                    Measure=Calc
                    Formula=#Value#
                    MinValue=0
                    MaxValue=100
                    DynamicVariables=1
                    [Round]
                    Meter=Roundline
                    MeasureName=Angle
                    X=8
                    Y=8
                    W=80
                    H=80
                    Solid=\(solid ? 1 : 0)
                    LineStart=6
                    LineLength=29
                    LineWidth=3.25
                    LineColor=220,90,40,180
                    AntiAlias=1
                    """)
                    defer { skin.close(); withExtendedLifetime(host) {} }
                    skin.update()
                    guard let meter = skin.meter(named: "Round") as? RoundlineMeter else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    releasedSkin = skin
                    releasedMeter = meter
                    let draw = meter.lower()
                    let before = try formats.map { scale, window in
                        let pixels = try roundPixels(scale: scale, window: window) {
                            SkinRenderer.drawRoundline(draw, $0)
                        }
                        let reference = try roundPixels(scale: scale, window: window) {
                            LegacySkinRenderer.drawRoundline(meter, $0)
                        }
                        t.check(pixels.contains { $0 != 0 }, "the \(solid ? "sector" : "line") draws visible pixels")
                        t.check(pixels == reference, "\(scale)x, window=\(window): the original Roundline pixels")
                        return pixels
                    }
                    skin.setVariable("Value", "62.5")
                    for (key, value) in [("X", "15"), ("LineLength", "34"), ("LineColor", "50,180,240,96"),
                                         ("AntiAlias", "0")] {
                        skin.perform(Bang(name: "setoption", args: ["Round", key, value]))
                    }
                    skin.update()
                    let changed = meter.lower()
                    t.check(changed != draw, "the next update produces a new drawing value")
                    for (index, format) in formats.enumerated() {
                        let (scale, window) = format
                        let kept = try roundPixels(scale: scale, window: window) {
                            SkinRenderer.drawRoundline(draw, $0)
                        }
                        let next = try roundPixels(scale: scale, window: window) {
                            SkinRenderer.drawRoundline(changed, $0)
                        }
                        let reference = try roundPixels(scale: scale, window: window) {
                            LegacySkinRenderer.drawRoundline(meter, $0)
                        }
                        t.check(kept == before[index], "the old value ignores later measure, paint and layout changes")
                        t.check(next != before[index], "the new value draws the updated Roundline")
                        t.check(next == reference, "the updated value preserves the original drawing algorithm")
                    }
                    return (draw, before)
                }
                t.check(releasedSkin == nil && releasedMeter == nil, "the drawing value retains no skin or meter")
                for (index, format) in formats.enumerated() {
                    let pixels = try roundPixels(scale: format.0, window: format.1) {
                        SkinRenderer.drawRoundline(frozen.draw, $0)
                    }
                    t.check(pixels == frozen.pixels[index], "Roundline can be drawn after its skin is released")
                }
            }
        }

        t.suite("App: round drawing values: Rotator keeps its pixels after its meter changes and goes away") {
            let image = t.temporaryDirectory("rotator-draw").appendingPathComponent("needle.png")
            try writeTestImage(to: image)
            weak var releasedSkin: Skin?
            weak var releasedMeter: RotatorMeter?
            let frozen = try autoreleasepool { () throws -> (draw: RotatorDraw, pixels: [Data]) in
                let (skin, host) = try MediaUITests.bareSkin(t, """
                [Rainmeter]
                Update=-1
                [Variables]
                Value=20
                [Angle]
                Measure=Calc
                Formula=#Value#
                MinValue=0
                MaxValue=100
                DynamicVariables=1
                [Needle]
                Meter=Rotator
                MeasureName=Angle
                ImageName=\(image.path)
                X=24
                Y=24
                W=40
                H=40
                OffsetX=8
                OffsetY=8
                ImageCrop=-2,-1,20,18
                ImageFlip=Horizontal
                ImageRotate=25
                ImageTint=128,255,80,192
                UseExifOrientation=1
                """)
                defer { skin.close(); withExtendedLifetime(host) {} }
                skin.update()
                guard let meter = skin.meter(named: "Needle") as? RotatorMeter else {
                    throw CocoaError(.coderInvalidValue)
                }
                releasedSkin = skin
                releasedMeter = meter
                let context = SkinRenderContext.of(skin), legacy = LegacySkinRenderContext.of(skin)
                let draw = meter.lower()
                let before = try formats.map { scale, window in
                    let pixels = try roundPixels(scale: scale, window: window) {
                        SkinRenderer.drawRotator(draw, $0, context)
                    }
                    let reference = try roundPixels(scale: scale, window: window) {
                        LegacySkinRenderer.drawRotator(meter, $0, legacy)
                    }
                    t.check(pixels.contains { $0 != 0 }, "the processed image draws visible pixels")
                    t.check(pixels == reference, "\(scale)x, window=\(window): the original Rotator pixels")
                    return pixels
                }
                skin.setVariable("Value", "62.5")
                for (key, value) in [("X", "34"), ("OffsetY", "4"), ("ImageCrop", "0,0,12,16"),
                                     ("ImageTint", "255,70,180,96"), ("ImageFlip", "Vertical")] {
                    skin.perform(Bang(name: "setoption", args: ["Needle", key, value]))
                }
                skin.update()
                let changed = meter.lower()
                t.check(changed != draw, "the next update produces a new drawing value")
                for (index, format) in formats.enumerated() {
                    let (scale, window) = format
                    let kept = try roundPixels(scale: scale, window: window) {
                        SkinRenderer.drawRotator(draw, $0, context)
                    }
                    let next = try roundPixels(scale: scale, window: window) {
                        SkinRenderer.drawRotator(changed, $0, context)
                    }
                    let reference = try roundPixels(scale: scale, window: window) {
                        LegacySkinRenderer.drawRotator(meter, $0, legacy)
                    }
                    t.check(kept == before[index], "the old value ignores later measure, processing and layout changes")
                    t.check(next != before[index], "the new value draws the updated Rotator")
                    t.check(next == reference, "the updated value preserves the original drawing algorithm")
                }
                t.equal(context.rotatorImages.count, 2, "each processing value has its own cached image")
                return (draw, before)
            }
            t.check(releasedSkin == nil && releasedMeter == nil, "the drawing value retains no skin or meter")
            let context = SkinRenderContext()
            for (index, format) in formats.enumerated() {
                let pixels = try roundPixels(scale: format.0, window: format.1) {
                    SkinRenderer.drawRotator(frozen.draw, $0, context)
                }
                t.check(pixels == frozen.pixels[index], "Rotator can be drawn with a fresh cache after its skin is released")
            }
        }
    }

    /// New Desk round caps have their own native path oracle. The legacy default and its frozen comparison above
    /// remain untouched, including the existing full-circle even-odd rendering branch.
    private static func roundCapTests(_ t: AppTestRunner) {
        t.suite("App: round drawing values: Gauge round caps match an independent native centerline") {
            let color = RGBA(r: 230, g: 70, b: 40, a: 128)
            for (scale, window) in [(1, false), (1, true), (2, false), (2, true)] {
                for sweep in [Double.pi / 2, -Double.pi / 2, 0.01] {
                    let value = RoundlineDraw(shape: .sector(centerX: 48, centerY: 48, innerRadius: 20,
                        outerRadius: 30, startAngle: 0, sweep: sweep), color: color, antiAlias: true, roundCaps: true)
                    let actual = try roundPixels(scale: scale, window: window) { SkinRenderer.drawRoundline(value, $0) }
                    let expected = try roundPixels(scale: scale, window: window) { ctx in
                        ctx.setShouldAntialias(true)
                        ctx.setStrokeColor(CGColor(srgbRed: 230.0 / 255, green: 70.0 / 255, blue: 40.0 / 255, alpha: 128.0 / 255))
                        ctx.setLineWidth(10); ctx.setLineCap(.round)
                        let path = CGMutablePath()
                        path.addArc(center: CGPoint(x: 48, y: 48), radius: 25, startAngle: 0,
                                    endAngle: sweep, clockwise: sweep < 0)
                        ctx.addPath(path); ctx.strokePath()
                    }
                    t.equal(actual, expected, "single native stroke at \(scale)x window=\(window), sweep=\(sweep)")
                    let alpha = stride(from: 3, to: actual.count, by: 4).map { actual[$0] }
                    t.check(alpha.contains(128), "round-cap body is visible")
                    t.check(alpha.allSatisfy { $0 <= 128 }, "short-arc caps do not accumulate translucent alpha")
                    if sweep == Double.pi / 2 {
                        let capOffset = ((44 * scale) * (96 * scale) + 73 * scale) * 4 + 3
                        t.check(actual[capOffset] > 100, "the start cap extends before the 3 o'clock endpoint")
                        let butt = RoundlineDraw(shape: value.shape, color: color, antiAlias: true)
                        let old = try roundPixels(scale: scale, window: window) { SkinRenderer.drawRoundline(butt, $0) }
                        t.equal(old[capOffset], 0, "legacy sectors still have their original straight end")
                    }
                }
            }
        }

        t.suite("App: round drawing values: Gauge full circles preserve legacy seams and zero arcs paint nothing") {
            for (scale, window) in [(1, false), (1, true), (2, false), (2, true)] {
                for sweep in [2 * Double.pi, -2 * Double.pi] {
                    let shape = RoundlineMeter.Shape.sector(centerX: 48, centerY: 48, innerRadius: 20,
                                                     outerRadius: 30, startAngle: 0.3, sweep: sweep)
                    let ordinary = RoundlineDraw(shape: shape, color: .black, antiAlias: true)
                    let capped = RoundlineDraw(shape: shape, color: .black, antiAlias: true, roundCaps: true)
                    let before = try roundPixels(scale: scale, window: window) { SkinRenderer.drawRoundline(ordinary, $0) }
                    let after = try roundPixels(scale: scale, window: window) { SkinRenderer.drawRoundline(capped, $0) }
                    t.equal(after, before, "a full ring keeps the seam-free legacy ellipse fill")
                }
                let zero = RoundlineDraw(shape: .sector(centerX: 48, centerY: 48, innerRadius: 20,
                    outerRadius: 30, startAngle: 0, sweep: 0), color: .black, antiAlias: true, roundCaps: true)
                let bytes = try roundPixels(scale: scale, window: window) { SkinRenderer.drawRoundline(zero, $0) }
                t.check(bytes.allSatisfy { $0 == 0 }, "zero sweep does not become a round dot")
            }
        }
    }

    /// Exact RGBA or window-format BGRA bytes at the requested backing scale, excluding row padding.
    private static func roundPixels(scale: Int, window: Bool, _ draw: (CGContext) -> Void) throws -> Data {
        let width = 96 * scale, height = 96 * scale
        let info = window
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info), let pixels = ctx.data else {
            throw CocoaError(.featureUnsupported)
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        draw(ctx)
        var result = Data(capacity: width * height * 4)
        for row in 0..<height {
            result.append(pixels.advanced(by: row * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self),
                          count: width * 4)
        }
        return result
    }
    #endif

    /// Updates and draws `skin` `count` times, as the app does once per update, into one bitmap; returns how many text
    /// layouts the skin had built after each cycle.
    private static func runCycles(_ skin: Skin, count: Int) throws -> [Int] {
        guard let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.featureUnsupported) }
        ctx.translateBy(x: 0, y: 200)
        ctx.scaleBy(x: 1, y: -1)
        var builds: [Int] = []
        for _ in 0..<count {
            skin.update()
            ctx.clear(CGRect(x: 0, y: 0, width: 400, height: 200))
            ctx.saveGState()
            SkinRenderer.draw(skin, in: ctx)
            ctx.restoreGState()
            builds.append(SkinRenderContext.of(skin).text.builds)
        }
        return builds
    }

    /// A 16 × 16 PNG: opaque blue with a white top-left quarter.
    private static func writeTestImage(to url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.featureUnsupported) }
        ctx.cgContext.setFillColor(CGColor(red: 0, green: 0.2, blue: 1, alpha: 1))
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        ctx.cgContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.cgContext.fill(CGRect(x: 0, y: 8, width: 8, height: 8))
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
