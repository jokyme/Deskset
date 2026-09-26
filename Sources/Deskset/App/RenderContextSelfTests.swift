import AppKit
import DesksetCore

/// The renderer's caches belong to one skin each (docs/skin-threading.md §4.3, phase 1): its text layouts, Rotator
/// images and Histogram scratch space live in the skin's `SkinRenderContext`, which only the skin's owner touches, so
/// skins drawn on threads of their own never share one. These suites check that each skin has its own, that measuring
/// and drawing share the skin's layouts, that the caches stay small and go with the skin, and that colors no longer go
/// through AppKit.
enum RenderContextSelfTests {
    static func run(_ t: AppTestRunner) {
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

            // A large skin (more texts than the turnover floor): fixed labels and a counter.
            var large = "[Rainmeter]\nUpdate=1000\n[Count]\nMeasure=Calc\nFormula=Counter\n"
                + "[Tick]\nMeter=String\nMeasureName=Count\nText=%1\n"
            let labels = TextLayoutCache.turnoverFloor + 36
            for i in 0..<labels { large += "[Fixed\(i)]\nMeter=String\nX=\(i % 10 * 40)\nY=\(16 + i / 10 * 16)\nText=Label \(i)\n" }
            let (big, bigHost) = try MediaUITests.bareSkin(t, large)
            let bigBuilds = try runCycles(big, count: cycles)
            t.equal(bigBuilds.last, bigBuilds.first.map { $0 + cycles - 1 },
                    "one new layout per update: \(labels) labels are never built again")
            let bigContext = SkinRenderContext.of(big)
            t.check(bigContext.text.storedCount <= 2 * (labels + 4),
                    "the layouts of about two updates: \(bigContext.text.storedCount)")

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
