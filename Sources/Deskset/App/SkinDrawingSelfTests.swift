import AppKit
import DesksetCore

/// A skin window's picture: drawn into a bitmap of its own (`SkinBitmapDrawing`), with pictures kept of the meters that
/// did not change while the skin redraws often, by the skin's frame producer on its executor (`SkinFrameProducer`), and
/// shown as the contents of a layer of its own in the skin's view (`LayerContentProvider`).
enum SkinDrawingSelfTests {
    static func run(_ t: AppTestRunner) {
        keptPictureTests(t)
        invalidationTests(t)
        frameTests(t)
        threadFrameTests(t)
        windowFrameTests(t)
        releaseTests(t)
        bitmapDeliveryTests(t)
        memoryTests(t)
        systemWidgetTests(t)
        repositorySkinTests(t)
        contentLayerCheckTests(t)
        benchmarkTests(t)
    }

    /// `Deskset --benchmark`: options, and a short run of a skin that keeps half of its meters.
    static func benchmarkTests(_ t: AppTestRunner) {
        t.suite("App: --benchmark runs a skin without a window and says what it costs") {
            let o = SkinBenchmark.parse(["Deskset", "--benchmark", "A.ini", "B.ini", "--seconds", "3", "--warmup", "0",
                                         "--scale", "1", "--appearance", "dark"])
            t.equal(o?.paths, ["A.ini", "B.ini"])
            t.equal(o?.seconds, 3)
            t.equal(o?.warmup, 0)
            t.equal(o?.scale, 1)
            t.equal(o?.appearance, .dark)
            t.check(SkinBenchmark.parse(["Deskset", "--benchmark"]) == nil, "a skin is needed")
            t.equal(SkinBenchmark.parse(["Deskset", "--benchmark", "A.ini", "--seconds", "-5"])?.seconds, 0.5)

            let root = t.temporaryDirectory("benchmark")
            let dir = root.appendingPathComponent("Bench/Clock", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("Clock.ini")
            try (keep.replacingOccurrences(of: "Update=50", with: "Update=40")).write(to: file, atomically: true,
                                                                                      encoding: .utf8)
            var options = SkinBenchmark.Options()
            options.seconds = 0.5
            options.warmup = 0.1
            guard let r = SkinBenchmark.measure(file, skinsRoot: root, options: options) else {
                return t.check(false, "the skin loads")
            }
            t.equal(r.config, "Bench\\Clock")
            t.check(r.updates >= 5, "it updates at its own rate: \(r.updates) in \(r.seconds) s")
            t.check(r.updateMs > 0 && r.drawMs > 0, "update \(r.updateMs) ms, drawing \(r.drawMs) ms")
            t.check(r.copied > 0, "the meters that rest are copied: \(r.copied)")
            t.check(r.mainThreadPercent > 0 && r.processPercent > 0,
                    "CPU \(r.mainThreadPercent) % / \(r.processPercent) %")
            t.check(SkinBenchmark.report(r).contains("drawing"))
        }
    }

    static let keep = """
    [Rainmeter]
    Update=50
    [MeasureCount]
    Measure=Calc
    Formula=MeasureCount + 1
    [MeterBack]
    Meter=Shape
    Shape=Rectangle 0,0,160,90,10 | Fill LinearGradient Back | StrokeWidth 0
    Back=90 | 30,120,200 ; 0 | 200,60,120 ; 1
    UpdateDivider=-1
    [MeterCount]
    Meter=String
    MeasureName=MeasureCount
    X=10
    Y=8
    FontSize=14
    FontColor=255,255,255
    AntiAlias=1
    [MeterFront]
    Meter=Shape
    Shape=Ellipse 120,45,24 | Fill Color 255,200,0,200 | StrokeWidth 2 | Stroke Color 0,0,0,120
    UpdateDivider=-1
    [MeterTurn]
    Meter=Shape
    Shape=Rectangle 60,40,40,12 | Fill Color 255,255,255,180 | StrokeWidth 0
    TransformationMatrix=[MeasureCos:];[MeasureSin:];(-[MeasureSin:]);[MeasureCos:];(80 - 80 * [MeasureCos:] + 46 * [MeasureSin:]);(46 - 80 * [MeasureSin:] - 46 * [MeasureCos:])
    DynamicVariables=1
    [MeasureCos]
    Measure=Calc
    Formula=Cos(MeasureCount / 5)
    [MeasureSin]
    Measure=Calc
    Formula=Sin(MeasureCount / 5)
    [MeterBox]
    Meter=Shape
    Shape=Rectangle 0,60,70,30 | Fill Color 0,0,0,255 | StrokeWidth 0
    UpdateDivider=-1
    [MeterInBox]
    Meter=Shape
    Shape=Rectangle 0,60,40,30 | Fill Color 0,255,120 | StrokeWidth 0
    Container=MeterBox
    UpdateDivider=-1
    [MeterLast]
    Meter=String
    Text=static
    X=100
    Y=70
    FontColor=0,0,0
    UpdateDivider=-1
    """

    /// The skin drawn in full, as a window picture is (glass as the window's hit areas).
    static func fullDrawing(_ skin: Skin, _ w: Int, _ h: Int, scale: CGFloat, _ space: CGColorSpace) -> CGContext? {
        guard let ctx = SkinBitmapDrawing.makeContext(w, h, space) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        SkinRenderer.draw(skin, in: ctx, glass: .window)
        NSGraphicsContext.restoreGraphicsState()
        return ctx
    }

    /// The largest difference of one channel between `image` and `ctx`'s pixels (Int.max when they cannot be read).
    static func difference(_ image: CGImage?, _ ctx: CGContext?) -> Int {
        guard let image, let ctx, let space = image.colorSpace,
              let copy = SkinBitmapDrawing.makeContext(image.width, image.height, space),
              image.width == ctx.width, image.height == ctx.height else { return .max }
        copy.setBlendMode(.copy)
        copy.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let a = copy.data?.assumingMemoryBound(to: UInt8.self),
              let b = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .max }
        var worst = 0
        for y in 0..<image.height {
            for x in 0..<(image.width * 4) {
                worst = max(worst, abs(Int(a[y * copy.bytesPerRow + x]) - Int(b[y * ctx.bytesPerRow + x])))
            }
        }
        return worst
    }

    static func keptPictureTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: kept pictures show what a full drawing shows") {
            let root = t.temporaryDirectory("skin-drawing")
            let folder = root.appendingPathComponent("Draw")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Keep.ini")
            try keep.write(to: url, atomically: true, encoding: .utf8)
            guard let skin = AppSelfTest.loadSkin(url, config: "Draw", skins: root),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return t.check(false, "the skin loads") }
            let size = CGSize(width: skin.width, height: skin.height), scale: CGFloat = 2
            let w = Int(size.width * scale), h = Int(size.height * scale)
            let drawing = SkinBitmapDrawing()
            /// One frame after `action`; its picture against a full drawing.
            func frame(_ label: String, _ action: String? = nil, update: Bool = true) -> SkinBitmapDrawing {
                if let action { skin.execute(action, from: nil) }
                if update { skin.update() }
                let picture = drawing.picture(of: skin, size: size, scale: scale, space: space, appearance: "test")
                let worst = difference(picture, fullDrawing(skin, w, h, scale: scale, space))
                t.check(worst <= SkinBitmapDrawing.tolerance, "\(label): differs by \(worst)")
                return drawing
            }
            for i in 0..<4 { _ = frame("frame \(i)") }
            t.check(drawing.lastStats.copied >= 2, "unchanged runs are copied: \(drawing.lastStats)")
            t.check(drawing.lastStats.drawn >= 2, "the count and the turning bar are drawn: \(drawing.lastStats)")
            t.check(drawing.keptRuns <= SkinBitmapDrawing.maxRuns)
            // Whatever changes a meter the update does not touch shows at once.
            _ = frame("hidden", "[!HideMeter MeterFront]")
            _ = frame("hidden, kept")
            _ = frame("shown again", "[!ShowMeter MeterFront]")
            _ = frame("an option",
                      "[!SetOption MeterFront Shape \"Ellipse 40,45,20 | Fill Color 255,0,0 | StrokeWidth 0\"][!UpdateMeter MeterFront]")
            _ = frame("a container's content",
                      "[!SetOption MeterInBox Shape \"Rectangle 30,60,40,30 | Fill Color 0,0,255 | StrokeWidth 0\"][!UpdateMeter MeterInBox]")
            _ = frame("resting", update: false)
            _ = frame("the container itself (its content is kept only where it is solid)",
                      "[!SetOption MeterBox Shape \"Rectangle 0,70,70,20 | Fill Color 0,0,0,255 | StrokeWidth 0\"][!UpdateMeter MeterBox][!Redraw]",
                      update: false)
            _ = frame("resting again", update: false)
            _ = frame("the content hidden", "[!HideMeter MeterInBox][!Redraw]", update: false)
            _ = frame("the content shown", "[!ShowMeter MeterInBox][!Redraw]", update: false)
            _ = frame("moved", "[!MoveMeter 50 20 MeterLast]")
            _ = frame("a redraw without an update", "[!SetOption MeterLast Text \"changed\"][!UpdateMeter MeterLast][!Redraw]",
                      update: false)
            for i in 0..<3 { _ = frame("again \(i)") }
            t.check(drawing.lastStats.copied >= 2, "and copies again once they rest: \(drawing.lastStats)")
            // Another look (or fonts, size, scale) starts again.
            _ = drawing.picture(of: skin, size: size, scale: scale, space: space, appearance: "other")
            t.equal(drawing.lastStats.copied, 0)
            t.equal(drawing.keptRuns, 0, "nothing kept from before")
            skin.close()
        }
    }

    /// A skin in a Skins folder of its own (a temporary one), loaded without a window with a host kept alive by the
    /// caller.
    static func load(_ t: AppTestRunner, _ ini: String, files: [String: Data] = [:], _ label: String)
        -> (skin: Skin, host: RenderHost, folder: URL)? {
        let root = t.temporaryDirectory("skin-drawing-\(label)")
        let folder = root.appendingPathComponent("Draw")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ini.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
            for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        } catch {
            return nil
        }
        let host = RenderHost()
        let skin = Skin(config: "Draw", fileURL: folder.appendingPathComponent("Skin.ini"), skinsDirectory: root,
                        system: SystemMonitor.shared, host: host)
        guard (try? skin.load()) != nil else { return nil }
        skin.update()
        return (skin, host, folder)
    }

    /// A PNG of `w`×`h` pixels in one color.
    static func png(_ w: Int, _ h: Int, _ color: RGBA) -> Data {
        guard let ctx = Images.bitmapContext(width: w, height: h) else { return Data() }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    /// Frames of `skin` through one `SkinBitmapDrawing`, each checked against a full drawing.
    final class Frames {
        let t: AppTestRunner
        let skin: Skin
        let drawing = SkinBitmapDrawing()
        var size: CGSize?
        var scale: CGFloat = 2
        var space = CGColorSpace(name: CGColorSpace.sRGB)!

        init(_ t: AppTestRunner, _ skin: Skin) {
            self.t = t
            self.skin = skin
        }

        /// One frame after `action` (and an update when `update`); returns its picture.
        @discardableResult
        func frame(_ label: String, _ action: String? = nil, update: Bool = false, line: UInt = #line) -> CGImage? {
            if let action { skin.execute(action, from: nil) }
            if update { skin.update() }
            let size = self.size ?? CGSize(width: skin.width, height: skin.height)
            let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
            let picture = drawing.picture(of: skin, size: size, scale: scale, space: space, appearance: "test")
            guard let picture, let full = SkinBitmapDrawing.fullDrawing(of: skin, w, h, scale: scale, space: space),
                  let found = SkinBitmapDrawing.difference(picture, full) else {
                t.check(false, "\(label): a picture", line: line)
                return nil
            }
            t.check(found.worst <= SkinBitmapDrawing.tolerance,
                    "\(label): differs from a full drawing by \(found.worst) in \(found.pixels) pixels", line: line)
            return picture
        }

        /// Two frames without a change: the next one starts from pictures of everything.
        func rest(line: UInt = #line) {
            frame("resting", "[!Redraw]", line: line)
            frame("rested", line: line)
            t.check(drawing.lastStats.copied > 0, "pictures are kept while nothing changes: \(drawing.lastStats)",
                    line: line)
        }
    }

    /// What can change a meter's pixels without its generation (`Meter.drawGeneration`) moving: each shows at once.
    static func invalidationTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: an image file replaced on disk shows at once") {
            // A meter that never updates, next to one that does; and the skin's background.
            let ini = """
            [Rainmeter]
            Update=1000
            BackgroundMode=3
            Background=#CURRENTPATH#Back.png
            [MeasureCount]
            Measure=Calc
            Formula=MeasureCount + 1
            [MeterPicture]
            Meter=Image
            ImageName=#CURRENTPATH#Picture.png
            X=10
            Y=10
            W=40
            H=40
            UpdateDivider=-1
            [MeterCount]
            Meter=String
            MeasureName=MeasureCount
            X=60
            Y=10
            FontColor=0,0,0
            """
            let red = RGBA(r: 220, g: 30, b: 30, a: 255), blue = RGBA(r: 30, g: 60, b: 220, a: 255)
            guard let (skin, host, folder) = load(t, ini, files: ["Picture.png": png(8, 8, red),
                                                                 "Back.png": png(4, 4, blue)], "image") else {
                return t.check(false, "the skin loads")
            }
            let frames = Frames(t, skin)
            frames.frame("first")
            frames.rest()
            // Another picture in the same file: a full drawing reads it again (Images checks the file on each lookup).
            try png(8, 8, blue).write(to: folder.appendingPathComponent("Picture.png"))
            frames.frame("the picture replaced, redrawn", "[!Redraw]")
            frames.frame("and kept again")
            frames.frame("after an update", update: true)
            frames.rest()
            try png(4, 4, red).write(to: folder.appendingPathComponent("Back.png"))
            frames.frame("the background replaced, after an update", update: true)
            frames.rest()
            // A file that goes missing, then comes back.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("Picture.png"))
            frames.frame("the picture removed", "[!Redraw]")
            frames.rest()
            try png(8, 8, red).write(to: folder.appendingPathComponent("Picture.png"))
            frames.frame("the picture back", "[!Redraw]")
            skin.close()
            withExtendedLifetime(host) {}
        }

        t.suite("App: skin drawing: a Histogram follows its measure's range, read when drawn") {
            let ini = """
            [Rainmeter]
            Update=1000
            [MeasureValue]
            Measure=Calc
            Formula=50
            MinValue=0
            MaxValue=100
            [MeterGraph]
            Meter=Histogram
            MeasureName=MeasureValue
            W=20
            H=40
            PrimaryColor=0,120,255
            UpdateDivider=-1
            """
            guard let (skin, host, _) = load(t, ini, "histogram") else { return t.check(false, "the skin loads") }
            let frames = Frames(t, skin)
            frames.frame("first")
            frames.rest()
            // The meter does not update (its history keeps the one sample), the measure's MaxValue does.
            frames.frame("a larger MaxValue", "[!SetOption MeasureValue MaxValue 200][!UpdateMeasure MeasureValue][!Redraw]")
            frames.frame("kept")
            skin.close()
            withExtendedLifetime(host) {}
        }

        t.suite("App: skin drawing: the background follows the skin's size, not only the window's") {
            // A skin larger than its window (windows stop at `SkinController.maxWindowSide`) keeps the window's size
            // while its background (a gradient over the whole skin) changes.
            let ini = """
            [Rainmeter]
            Update=1000
            DynamicWindowSize=1
            BackgroundMode=2
            SolidColor=255,0,0
            SolidColor2=0,0,255
            GradientAngle=0
            [MeterStatic]
            Meter=String
            Text=static
            FontColor=255,255,255
            UpdateDivider=-1
            [MeterWide]
            Meter=String
            Text=x
            W=100
            H=40
            """
            guard let (skin, host, _) = load(t, ini, "base") else { return t.check(false, "the skin loads") }
            let frames = Frames(t, skin)
            frames.size = CGSize(width: 100, height: 40)
            // MeterWide updates every time: the base and MeterStatic are kept as one picture.
            for i in 0..<3 { frames.frame("update \(i)", update: true) }
            t.check(frames.drawing.lastStats.copied == 1, "the base is kept: \(frames.drawing.lastStats)")
            frames.frame("the skin grew past the window", "[!SetOption MeterWide W 300]", update: true)
            t.equal(skin.width, 300)
            frames.frame("kept", update: true)
            skin.close()
            withExtendedLifetime(host) {}
        }

        t.suite("App: skin drawing: another color space starts the pictures again, named or not") {
            guard let (skin, host, _) = load(t, keep, "space") else { return t.check(false, "the skin loads") }
            let frames = Frames(t, skin)
            // A display's own profile (the built-in one's is "Color LCD") is a color space without a name: two
            // different ones must not look the same.
            let white: [CGFloat] = [0.9505, 1, 1.089]
            guard let first = CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil, gamma: [2.2, 2.2, 2.2],
                                           matrix: nil),
                  let second = CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: nil, gamma: [1.8, 1.8, 1.8],
                                            matrix: nil) else {
                return t.check(false, "calibrated color spaces")
            }
            t.check(first.name == nil && second.name == nil, "no names")
            frames.space = first
            frames.frame("first")
            frames.rest()
            frames.space = second
            let picture = frames.frame("another display's profile")
            t.equal(frames.drawing.lastStats.copied, 0, "nothing copied from the other color space")
            t.check(picture?.colorSpace == second, "the picture is in the window's color space")
            skin.close()
            withExtendedLifetime(host) {}
        }

        t.suite("App: skin drawing: a meter that never updates moves with the one it is placed after") {
            let ini = """
            [Rainmeter]
            Update=1000
            DynamicWindowSize=1
            [Variables]
            Word=a
            [MeterGrowing]
            Meter=String
            Text=#Word#
            FontSize=16
            FontColor=0,0,0
            DynamicVariables=1
            [MeterAfter]
            Meter=Shape
            X=4R
            Shape=Rectangle 0,0,20,20 | Fill Color 200,40,40 | StrokeWidth 0
            UpdateDivider=-1
            """
            guard let (skin, host, _) = load(t, ini, "relative") else { return t.check(false, "the skin loads") }
            let frames = Frames(t, skin)
            frames.frame("first")
            frames.rest()
            let x = skin.meter(named: "MeterAfter")?.frame.x ?? 0
            frames.frame("the first meter grew", "[!SetVariable Word \"a much longer text\"]", update: true)
            t.check((skin.meter(named: "MeterAfter")?.frame.x ?? 0) > x + 20, "the second meter moved")
            frames.frame("kept")
            skin.close()
            withExtendedLifetime(host) {}
        }

        t.suite("App: skin drawing: a font registered while the skin runs starts the pictures again") {
            let ini = """
            [Rainmeter]
            Update=1000
            [MeterStatic]
            Meter=String
            Text=Fonts
            FontFace=DesksetTstD
            FontSize=20
            FontColor=0,0,0
            UpdateDivider=-1
            [MeasureCount]
            Measure=Calc
            Formula=MeasureCount + 1
            [MeterCount]
            Meter=String
            MeasureName=MeasureCount
            Y=40
            FontColor=0,0,0
            """
            guard let (skin, host, _) = load(t, ini, "fonts") else { return t.check(false, "the skin loads") }
            let frames = Frames(t, skin)
            frames.frame("first (a fallback font)")
            frames.rest()
            let folder = t.temporaryDirectory("drawing-fonts").appendingPathComponent("Fonts")
            guard AppSelfTest.makeTestFont(family: "DesksetTstD", at: folder.appendingPathComponent("D.ttf")) else {
                print("    (skipped: Courier New not found)")
                return
            }
            let before = Fonts.generation
            t.check(Fonts.rescanFolder(folder.path), "the font registers")
            t.check(Fonts.generation != before, "the fonts moved on")
            // Another skin's font, or one added to a folder, arrives between two frames of this one.
            frames.frame("the font registered", "[!Redraw]")
            t.equal(frames.drawing.lastStats.copied, 0, "nothing copied from before the font")
            skin.fontsDidChange()
            frames.frame("measured again")
            frames.rest()
            try FileManager.default.removeItem(at: folder)
            _ = Fonts.rescanAllFolders()
            frames.frame("the font removed", "[!Redraw]")
            t.equal(frames.drawing.lastStats.copied, 0, "nothing copied from before")
            skin.close()
            withExtendedLifetime(host) {}
        }

        t.suite("App: skin drawing: graphs taken from a running widget count as a change") {
            let ini = """
            [Rainmeter]
            Update=1000
            [MeasureCount]
            Measure=Calc
            Formula=MeasureCount + 1
            MaxValue=10
            [MeterLine]
            Meter=Line
            MeasureName=MeasureCount
            W=40
            H=20
            [MeterHistogram]
            Meter=Histogram
            MeasureName=MeasureCount
            Y=20
            W=40
            H=20
            """
            guard let (running, host, _) = load(t, ini, "graphs"), let (fresh, freshHost, _) = load(t, ini, "graphs2")
            else { return t.check(false, "the skins load") }
            for _ in 0..<5 { running.update() }
            let before = fresh.meters.map(\.drawGeneration)
            fresh.takeGraphs(from: running)
            t.check(zip(before, fresh.meters.map(\.drawGeneration)).allSatisfy { $0 < $1 },
                    "each graph's generation moved on")
            running.close()
            fresh.close()
            withExtendedLifetime((host, freshHost)) {}
        }
    }

    // MARK: Frames

    /// Ends a turn of the main run loop: the frame producers of the skins on the main thread draw what their skins asked
    /// for in it.
    static func endTurn() {
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    static let sRGB = SkinFrameProducer.sRGB
    static let aqua = NSAppearance.Name.aqua.rawValue

    /// Updated only by the tests (`Update=-1`); `W` sets its width; one meter never updates (kept pictures).
    static let frameSkin = """
    [Rainmeter]
    Update=-1
    DynamicWindowSize=1
    AccurateText=1
    [Variables]
    W=120
    [MeasureCount]
    Measure=Calc
    Formula=MeasureCount + 1
    [MeterBack]
    Meter=Image
    W=#W#
    H=60
    SolidColor=30,120,200
    DynamicVariables=1
    [MeterCount]
    Meter=String
    MeasureName=MeasureCount
    X=8
    Y=8
    FontSize=14
    FontColor=255,255,255
    AntiAlias=1
    [MeterStatic]
    Meter=Shape
    Shape=Ellipse 90,30,12 | Fill Color 255,200,0,255 | StrokeWidth 0
    UpdateDivider=-1
    """

    /// A runtime of `ini` whose frames go to `window`'s content layer (or `content`).
    static func frameRuntime(_ t: AppTestRunner, _ ini: String, executor: SkinExecutor = MainSkinExecutor.shared,
                             window: FrameTestWindow, content: ContentProvider? = nil) throws -> SkinRuntime {
        let root = t.temporaryDirectory("frames")
        let folder = root.appendingPathComponent("Frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ini.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        let runtime = SkinRuntime(config: "Frames", file: "Skin.ini", skinsDirectory: root, executor: executor,
                                  content: content ?? window.content)
        runtime.window = window
        window.runtime = runtime
        return runtime
    }

    /// How much `image` differs from a full drawing of `skin` at `scale` in `space` (nil: not comparable).
    static func differenceFromFullDrawing(_ image: CGImage, _ skin: Skin, scale: CGFloat,
                                          space: CGColorSpace) -> SkinBitmapDrawing.Difference? {
        guard let full = SkinBitmapDrawing.fullDrawing(of: skin, image.width, image.height, scale: scale, space: space)
        else { return nil }
        return SkinBitmapDrawing.difference(image, full)
    }

    /// The content layer's picture against a full drawing of the skin, and where the layer is and how large.
    static func checkShown(_ t: AppTestRunner, _ content: LayerContentProvider, host: CALayer?, _ skin: Skin,
                           scale: CGFloat, space: CGColorSpace, _ label: String, line: UInt = #line) {
        let shown = content.shown
        guard let image = shown.image else { return t.check(false, "\(label): a picture", line: line) }
        let size = SkinRuntime.windowSize(width: skin.width, height: skin.height)
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        t.equal(image.width, w, "\(label): its width in pixels", line: line)
        t.equal(image.height, h, "\(label): its height in pixels", line: line)
        t.check(image.colorSpace == space, "\(label): in the window's colour space", line: line)
        t.equal(shown.bounds, CGRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale),
                "\(label): the layer is the frame's size, one pixel per pixel", line: line)
        t.equal(shown.scale, scale, "\(label): its scale", line: line)
        t.equal(shown.position, .zero, "\(label): at the view's top-left corner", line: line)
        t.equal(shown.anchorPoint, .zero, line: line)
        t.check(shown.superlayer === host, "\(label): in the view's layer", line: line)
        guard let found = differenceFromFullDrawing(image, skin, scale: scale, space: space) else {
            return t.check(false, "\(label): compared with a full drawing", line: line)
        }
        t.check(found.worst <= SkinBitmapDrawing.tolerance,
                "\(label): differs from a full drawing by \(found.worst) in \(found.pixels) pixels", line: line)
    }

    static func frameTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: frames go to the content layer at the end of the turn, while the window can be seen") {
            let w = FrameTestWindow()
            let runtime = try frameRuntime(t, frameSkin, window: w)
            let frames = runtime.frames
            let host = w.view.layer
            // The window as it is before the skin loads: never shown.
            w.publish()
            _ = try runtime.load()
            runtime.send(.start)
            let skin: Skin = runtime.skin
            endTurn()
            t.equal(frames.framesDrawn, 0, "never shown: nothing drawn (AppKit never displayed such a view either)")
            t.check(frames.framesSkipped > 0, "the frame asked for was skipped")
            t.equal(w.content.state.presented, 0)
            t.equal(host?.sublayers?.count, 1, "the view's layer holds one layer")
            t.check(host?.sublayers?.first.map(w.content.isContentLayer) == true, "the content layer")

            // The first frame, before the window is shown; only once.
            runtime.send(.firstFrame)
            t.equal(frames.framesDrawn, 1, "the first frame, whether the window can be seen yet or not")
            checkShown(t, w.content, host: host, skin, scale: 2, space: sRGB, "the first frame")
            runtime.send(.firstFrame)
            t.equal(frames.framesDrawn, 1, "only the first time")
            endTurn()

            // Ordered in on a later turn, as a skin thread hears of it: the first frame is what it shows, drawn again
            // only if the skin redrew since.
            w.show(true)
            endTurn()
            t.equal(frames.framesDrawn, 1, "ordered in after its first frame, nothing changed: that frame, not another")
            // Ordered out and in again: one frame (the view was displayed when its window was ordered in).
            w.show(false)
            endTurn()
            w.show(true)
            endTurn()
            t.equal(frames.framesDrawn, 2, "ordered in again: one frame")
            endTurn()
            t.equal(frames.framesDrawn, 2, "then nothing, while nothing changes")
            runtime.send(.update(hops: 0))
            t.equal(frames.framesDrawn, 2, "not in the middle of the turn")
            endTurn()
            t.equal(frames.framesDrawn, 3, "at its end")
            checkShown(t, w.content, host: host, skin, scale: 2, space: sRGB, "an update")
            t.check(host?.contents == nil, "the view's own layer shows nothing")

            // Many redraws in one turn: one frame.
            for _ in 0..<5 { runtime.send(.execute("[!Redraw]", section: nil)) }
            for _ in 0..<3 { runtime.send(.update(hops: 0)) }
            t.equal(frames.framesDrawn, 3)
            endTurn()
            t.equal(frames.framesDrawn, 4, "eight redraws in one turn: one frame")
            endTurn()
            t.equal(frames.framesDrawn, 4, "and nothing more")

            // At rest the pictures are copied.
            for _ in 0..<2 {
                runtime.send(.execute("[!Redraw]", section: nil))
                endTurn()
            }
            t.equal(frames.drawing.lastStats.copied, 1, "a resting skin's picture is copied: \(frames.drawing.lastStats)")
            checkShown(t, w.content, host: host, skin, scale: 2, space: sRGB, "at rest")

            // Another scale, colour space or appearance: drawn again, from nothing kept.
            var drawn = frames.framesDrawn
            w.publish { $0.scale = 1 }
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "another backing scale draws again")
            t.equal(frames.drawing.lastStats.copied, 0, "from nothing kept")
            t.equal(w.content.state.scale, 1, "the provider heard of the scale")
            checkShown(t, w.content, host: host, skin, scale: 1, space: sRGB, "at 1x")
            guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return t.check(false, "Display P3") }
            drawn = frames.framesDrawn
            w.publish { $0.colorSpace = p3 }
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "another colour space draws again")
            t.equal(frames.drawing.lastStats.copied, 0)
            checkShown(t, w.content, host: host, skin, scale: 1, space: p3, "in Display P3")
            drawn = frames.framesDrawn
            w.publish { $0.appearance = NSAppearance.Name.darkAqua.rawValue }
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "another appearance draws again")
            t.equal(frames.drawing.lastStats.copied, 0)
            w.publish {
                $0.scale = 2
                $0.colorSpace = sRGB
                $0.appearance = aqua
            }
            endTurn()
            drawn = frames.framesDrawn

            // Covered: nothing drawn; uncovered: one frame.
            w.publish { $0.isVisible = false }
            t.equal(w.content.state.visible, false, "the provider hears that the window cannot be seen")
            for _ in 0..<3 {
                runtime.send(.update(hops: 0))
                endTurn()
            }
            t.equal(frames.framesDrawn, drawn, "a covered window draws nothing")
            w.publish { $0.isVisible = true }
            t.equal(w.content.state.visible, true)
            endTurn()
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "one frame once it can be seen again")
            checkShown(t, w.content, host: host, skin, scale: 2, space: sRGB, "uncovered")
            w.publish { $0.isVisible = false }
            w.publish { $0.isVisible = true }
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "uncovered without a redraw meanwhile: nothing to draw")

            // Ordered out (!Hide): nothing; ordered in again: one frame, before its occlusion state catches up.
            drawn = frames.framesDrawn
            w.show(false)
            for _ in 0..<3 {
                runtime.send(.update(hops: 0))
                endTurn()
            }
            t.equal(frames.framesDrawn, drawn, "an ordered-out window draws nothing")
            w.publish { $0.isOrderedIn = true }
            endTurn()
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "ordered in again: one frame, although not uncovered yet")
            runtime.send(.update(hops: 0))
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "then it counts as covered until the occlusion state says otherwise")
            w.publish { $0.isVisible = true }
            endTurn()
            t.equal(frames.framesDrawn, drawn + 2)
            checkShown(t, w.content, host: host, skin, scale: 2, space: sRGB, "shown again")

            // A new size: the window follows with its top-left corner fixed; the frame is never stretched.
            let top = w.panel.frame.maxY
            runtime.send(.execute("[!SetVariable W 200]", section: nil))
            runtime.send(.update(hops: 0))
            t.equal(w.resizes.last, CGSize(width: 200, height: 60), "the window is asked to follow")
            t.equal(w.panel.frame.maxY, top, "with its top-left corner fixed")
            endTurn()
            checkShown(t, w.content, host: host, skin, scale: 2, space: sRGB, "grown")
            runtime.send(.execute("[!SetVariable W 130.3]", section: nil))
            runtime.send(.update(hops: 0))
            endTurn()
            t.close(skin.width, 130.3, accuracy: 1e-6, "a width that is not whole")
            t.equal(w.content.shown.bounds.width, 130.5, "261 pixels at 2x cover 130.5 points: nothing is stretched")
            checkShown(t, w.content, host: host, skin, scale: 2, space: sRGB, "a width that is not whole")
            let resizes = w.resizes.count
            runtime.send(.update(hops: 0))
            endTurn()
            t.equal(w.resizes.count, resizes, "the same size asks nothing of the window")

            // Closed: no more frames, the last one stays for the fade-out; the window tears the layer down.
            drawn = frames.framesDrawn
            let last = w.content.shown.image
            runtime.send(.close(fadeOut: false))
            runtime.send(.frameWanted)
            endTurn()
            t.equal(frames.framesDrawn, drawn, "a closed skin draws nothing")
            t.check(w.content.shown.image != nil && w.content.shown.image === last, "the last frame stays")
            w.content.teardown()
            t.equal(w.content.state.tornDown, true)
            t.check(host?.sublayers?.isEmpty ?? true, "the content layer is gone from the view's layer")
            if let last { w.content.present(SkinFrame(image: last, scale: 2)) }
            t.equal(w.content.shown.image == nil, true, "a frame after the teardown shows nothing")
        }

        t.suite("App: skin drawing: a turn longer than a frame draws before the next one ends") {
            let w = FrameTestWindow()
            let runtime = try frameRuntime(t, frameSkin, window: w)
            let frames = runtime.frames
            w.show(true)
            _ = try runtime.load()
            runtime.send(.start)
            endTurn()
            let drawn = frames.framesDrawn
            t.check(drawn >= 1, "shown")
            // What a thread that never waits sees: turns that start one after the other.
            runtime.send(.update(hops: 0))
            frames.runLoopTurn(.beforeTimers)
            t.equal(frames.framesDrawn, drawn, "asked for just now: the frame waits for the end of the turn")
            let asked = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - asked < 2 * SkinFrameProducer.frameInterval {}
            frames.runLoopTurn(.beforeTimers)
            t.equal(frames.framesDrawn, drawn + 1, "asked for longer than a frame ago: drawn as the next turn starts")
            frames.runLoopTurn(.beforeWaiting)
            t.equal(frames.framesDrawn, drawn + 1, "once")
            runtime.send(.close(fadeOut: false))
            w.content.teardown()
        }
    }

    static func threadFrameTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: a skin on a thread of its own draws at the end of its turns and presents from there") {
            let executor = SkinThreadExecutor(name: "Skin frames test")
            let w = FrameTestWindow()
            let recorder = PresentRecorder(w.content)
            var held: SkinRuntime? = try frameRuntime(t, frameSkin, executor: executor, window: w, content: recorder)
            defer { SkinRuntimeSelfTests.finish(t, &held, executor) }
            guard let r = held else { return }
            w.publish()
            guard SkinRuntimeSelfTests.load(t, r, on: executor) else { return }
            w.show(true)
            t.check(AppSelfTest.spin(timeout: 30) { recorder.count >= 1 }, "a frame arrives once the window is shown")
            t.check(recorder.threads.current.allSatisfy { !$0 }, "presented from the skin's thread")
            t.equal(w.offMain, 0, "the window's requests arrive on the main thread")

            // Ten redraws in one piece of the thread's work: one frame, at the end of that turn.
            _ = r.exclusive(timeout: 30) { _ in true }
            let before = recorder.count
            executor.async {
                for _ in 0..<5 {
                    r.send(.execute("[!Redraw]", section: nil))
                    r.send(.update(hops: 0))
                }
            }
            t.check(AppSelfTest.spin(timeout: 30) { recorder.count > before }, "the frame arrives")
            // Two more pieces of work, each at a turn of its own, ask for nothing.
            for _ in 0..<2 { _ = r.exclusive(timeout: 30) { _ in true } }
            t.equal(recorder.count, before + 1, "ten redraws in one piece of work: one frame")
            let worst = r.exclusive(timeout: 30) { skin -> Int in
                guard let image = w.content.shown.image,
                      let found = differenceFromFullDrawing(image, skin, scale: 2, space: sRGB) else { return .max }
                return found.worst
            }
            t.check((worst ?? .max) <= SkinBitmapDrawing.tolerance, "the frame is the skin's: \(String(describing: worst))")

            // Covered: nothing; uncovered: one frame.
            w.publish { $0.isVisible = false }
            _ = r.exclusive(timeout: 30) { _ in true }
            let covered = recorder.count
            for _ in 0..<3 { r.send(.update(hops: 0)) }
            for _ in 0..<2 { _ = r.exclusive(timeout: 30) { _ in true } }
            t.equal(recorder.count, covered, "a covered window draws nothing")
            w.publish { $0.isVisible = true }
            t.check(AppSelfTest.spin(timeout: 30) { recorder.count > covered }, "uncovered: a frame")
            for _ in 0..<2 { _ = r.exclusive(timeout: 30) { _ in true } }
            t.equal(recorder.count, covered + 1, "one")
            t.check(recorder.threads.current.allSatisfy { !$0 }, "every frame presented from the skin's thread")

            r.send(.close(fadeOut: false))
            _ = r.exclusive(timeout: 30) { _ in true }
            // The window's teardown may meet a frame under way: the provider takes care of that.
            w.content.teardown()
            t.equal(w.content.state.tornDown, true)
        }
    }

    static func windowFrameTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: a skin window shows its frames in a layer of its own") {
            guard let app = try AppSelfTest.makeApp(t),
                  let c = app.activate(config: "App\\Focus", file: "Focus.ini") else { return t.check(false, "loads") }
            // Its clock stops, so that only the test redraws it (the frames are counted).
            c.pauseUpdates()
            let view = c.view, frames = c.runtime.frames
            t.check(view.wantsUpdateLayer, "the view asks AppKit for no drawing of its own")
            view.updateLayer()
            t.check(view.layer?.contents == nil, "its layer has no contents")
            t.equal(view.layer?.sublayers?.count, 1)
            t.check(view.layer?.sublayers?.first.map(c.content.isContentLayer) == true, "only the content layer")
            // Snapshots of the view (`cacheDisplay`) draw the skin with draw(_:) and leave the layer without contents.
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let middle = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
                t.check((middle?.alphaComponent ?? 0) > 0, "a snapshot shows the skin")
                t.check(view.layer?.contents == nil, "and leaves the view's layer without contents")
            } else {
                t.check(false, "a snapshot")
            }
            endTurn()
            t.equal(frames.framesDrawn, 0, "headless: never shown, never drawn")

            // Ordered in (when the app presents windows): the first frame is there by then.
            var presentedAtOrderIn: Int?
            c.willOrderIn = { presentedAtOrderIn = c.content.state.presented }
            c.orderIn(alpha: 1)
            c.willOrderIn = nil
            t.equal(presentedAtOrderIn, 1, "the first frame exists before the window is ordered in")
            t.check(!c.window.isVisible, "(headless: the window stays out)")
            // Shown in the same turn (as `start` shows it): the first frame is the one it shows.
            c.visibilityForTesting = true
            endTurn()
            t.equal(frames.framesDrawn, 1, "ordered in right after its first frame: nothing drawn again")
            c.visibilityForTesting = false
            endTurn()

            // Shown and uncovered as far as the frames go.
            c.visibilityForTesting = true
            endTurn()
            t.equal(frames.framesDrawn, 2, "ordered in: one frame")
            let scale = c.window.backingScaleFactor
            let space = c.window.colorSpace?.cgColorSpace ?? sRGB
            // The window's colour space (a display's profile), as AppKit drew the view: sRGB colours come out the same,
            // and colours beyond sRGB (Display P3 pictures) are not clipped as in an sRGB bitmap.
            checkShown(t, c.content, host: view.layer, c.skin, scale: scale, space: space, "a skin window's frame")
            for _ in 0..<2 {
                c.skin.execute("[!Redraw]", from: nil)
                endTurn()
            }
            t.equal(frames.drawing.lastStats.copied, 1, "the resting skin is copied: \(frames.drawing.lastStats)")

            // The view's hooks publish the window's facts: the same scale and colour space change nothing; another
            // appearance draws the frame again.
            var drawn = frames.framesDrawn
            view.viewDidChangeBackingProperties()
            endTurn()
            t.equal(frames.framesDrawn, drawn, "the same backing: nothing drawn again")
            view.appearance = NSAppearance(named: .darkAqua)
            t.check(AppSelfTest.spin(timeout: 10) { frames.framesDrawn > drawn }, "another appearance draws the frame again")
            t.equal(frames.appearance, NSAppearance.Name.darkAqua.rawValue)
            t.equal(frames.drawing.lastStats.copied, 0, "from nothing kept")
            view.appearance = nil
            AppSelfTest.spin(timeout: 10) { frames.appearance != NSAppearance.Name.darkAqua.rawValue }

            // Not shown: its redraws are skipped; shown again: one frame.
            endTurn()
            drawn = frames.framesDrawn
            c.visibilityForTesting = false
            for _ in 0..<3 {
                c.skin.execute("[!Redraw]", from: nil)
                endTurn()
            }
            t.equal(frames.framesDrawn, drawn, "a window that cannot be seen draws nothing")
            c.visibilityForTesting = true
            endTurn()
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "one frame when it can be seen again")

            // A new panel (ClickThrough turned off again) keeps the content layer and draws it again.
            let firstPanel = c.window
            drawn = frames.framesDrawn
            c.skin.execute("[!ClickThrough 1][!ClickThrough 0]", from: nil)
            t.check(c.window !== firstPanel, "a new panel")
            t.check(c.content.shown.superlayer === view.layer, "the content layer went with the view")
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1, "and is drawn again, as the view was")

            // Closed: the window tears the content layer down.
            c.stop()
            t.equal(c.content.state.tornDown, true, "the window closed: the content layer is torn down")
            t.check(view.layer?.sublayers?.isEmpty ?? true)
            app.stopAllForTermination()
        }

        t.suite("App: skin drawing: FrostedGlass's rounded corners clip the content layer as they clipped the view") {
            guard let app = try AppSelfTest.makeApp(t),
                  let c = app.activate(config: "App\\Focus", file: "Focus.ini") else { return t.check(false, "loads") }
            defer { app.stopAllForTermination() }
            c.pauseUpdates()
            c.visibilityForTesting = true
            c.skin.execute("[!Redraw]", from: nil)
            endTurn()
            let scale = c.window.backingScaleFactor, size = c.view.bounds.size
            let space = c.window.colorSpace?.cgColorSpace ?? sRGB
            guard let image = c.content.shown.image, let square = composite(c.contentView.layer, size: size,
                                                                            scale: scale, space: space) else {
                return t.check(false, "a frame")
            }
            let corner = (x: 1, y: 1), middle = (x: image.width / 2, y: image.height / 2)
            t.check(pixel(square, corner.x, corner.y).a > 0, "square corners: the corner shows the skin")
            let measure = FrostedGlassMeasure(name: "FrostedGlass", section: MediaUITests.section("FrostedGlass", [
                ("Measure", "Plugin"), ("Plugin", "FrostedGlass"), ("Type", "Acrylic"), ("Corner", "Round"),
            ]), skin: c.skin, type: "frostedglass")
            measure.readOptions()
            _ = measure.computeValue()
            t.equal(c.contentView.layer?.cornerRadius, 8, "the skin's content view is rounded")
            guard let rounded = composite(c.contentView.layer, size: size, scale: scale, space: space) else {
                return t.check(false, "composited")
            }
            t.equal(pixel(rounded, corner.x, corner.y).a, 0, "rounded: the content layer is clipped at the corner")
            t.check(pixel(rounded, middle.x, middle.y) == pixel(square, middle.x, middle.y), "and not inside")

            // What the view's own contents looked like with the same rounding.
            let legacy = LegacyWindow()
            legacy.contentView.wantsLayer = true
            legacy.contentView.layer?.cornerRadius = 8
            legacy.contentView.layer?.masksToBounds = true
            legacy.resize(to: size)
            legacy.view.skin = c.skin
            legacy.view.scale = scale
            legacy.view.space = space
            legacy.view.drawingAppearance = c.view.effectiveAppearance.name.rawValue
            // AppKit settles the new panel's layer tree (which layers are flipped) on the next turn.
            endTurn()
            legacy.view.updateLayer()
            let old = composite(legacy.contentView.layer, size: size, scale: scale, space: space)
            let worst = differenceOfContexts(rounded, old)
            t.check(worst <= SkinBitmapDrawing.tolerance, "the same pixels as the view clipped: differs by \(worst)")

            measure.execute(command: "DisableCorner")
            t.equal(c.contentView.layer?.cornerRadius, 0, "no corners: no rounding")
            if let again = composite(c.contentView.layer, size: size, scale: scale, space: space) {
                t.check(pixel(again, corner.x, corner.y).a > 0, "the corner shows again")
            }
            withExtendedLifetime(measure) {}
        }
    }

    // MARK: Composites

    /// What a skin window's layer tree shows: `layer` (its content view's) and everything in it, rendered as Core
    /// Animation composites it, with the top-left corner first, `size` points at `scale`. Nothing is read from the
    /// screen: the layers are rendered in this process.
    static func composite(_ layer: CALayer?, size: CGSize, scale: CGFloat, space: CGColorSpace) -> CGContext? {
        guard let layer else { return nil }
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let ctx = SkinBitmapDrawing.makeContext(w, h, space) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        if layer.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
        } else {
            ctx.scaleBy(x: scale, y: scale)
        }
        layer.render(in: ctx)
        return ctx
    }

    struct Pixel: Equatable {
        var b: UInt8, g: UInt8, r: UInt8, a: UInt8
    }

    /// The pixel at (x, y), counted from the top-left corner.
    static func pixel(_ ctx: CGContext, _ x: Int, _ y: Int) -> Pixel {
        guard x >= 0, y >= 0, x < ctx.width, y < ctx.height,
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return Pixel(b: 0, g: 0, r: 0, a: 0) }
        let p = data + y * ctx.bytesPerRow + x * 4
        return Pixel(b: p[0], g: p[1], r: p[2], a: p[3])
    }

    /// The largest difference of one channel between two bitmaps of one size (Int.max: not comparable).
    static func differenceOfContexts(_ a: CGContext?, _ b: CGContext?) -> Int {
        guard let a, let b, let image = a.makeImage() else { return .max }
        return SkinBitmapDrawing.difference(image, b)?.worst ?? .max
    }

    /// Every default skin and test skin (and, when `DESKSET_DRAWING_CHECK_SKINS` names more Skins folders, separated
    /// by colons, those too: a local corpus that never goes into the repository) through `DrawingCacheCheck`.
    static func repositorySkinTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: the check finds skins in root configs and in configs below them") {
            let root = t.temporaryDirectory("drawing-check-files")
            let names = ["Loose.ini", "Clock/Clock.ini", "Clock/Small.ini", "Suite/Cpu/Cpu.ini", "Suite/Cpu/Deep/Deep.ini",
                         "Suite/@Resources/Styles.ini", "Suite/@resources/More/Other.ini", "Suite/Notes.txt"]
            for name in names {
                let url = root.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: Data("[Rainmeter]\n".utf8))
            }
            let found = DrawingCacheCheck.skinFiles(in: root).map { url in
                url.pathComponents.drop(while: { $0 != root.lastPathComponent }).dropFirst().joined(separator: "/")
            }
            t.equal(found, ["Clock/Clock.ini", "Clock/Small.ini", "Suite/Cpu/Cpu.ini", "Suite/Cpu/Deep/Deep.ini"],
                    "skins in a root config are checked; @Resources and files loose in the Skins folder are not")
        }
        t.suite("App: skin drawing: every repository skin's pictures match full drawings") {
            var folders = ["DefaultSkins", "TestSkins"].compactMap { Paths.repositoryFolder($0) }
            guard folders.count == 2 else {
                print("    (skipped: DefaultSkins or TestSkins not found; run from the repository)")
                return
            }
            let extra = ProcessInfo.processInfo.environment["DESKSET_DRAWING_CHECK_SKINS"] ?? ""
            folders += extra.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            let temporary = t.temporaryDirectory("drawing-check")
            var checked = 0, frames = 0, copied = 0
            DrawingCacheCheck.withCheckEnvironment(temporary, weatherPreview: false) {
                for (i, folder) in folders.enumerated() {
                    let copy = temporary.appendingPathComponent("Skins\(i)")
                    guard (try? FileManager.default.copyItem(at: folder, to: copy)) != nil else {
                        return t.check(false, "copies \(folder.lastPathComponent)")
                    }
                    for file in DrawingCacheCheck.skinFiles(in: copy) {
                        // One backing scale in the steps, the other in one frame (`check`); a few seconds per skin.
                        let r = DrawingCacheCheck.check(file, skinsRoot: copy, updates: 2, scale: 1,
                                                        budget: 3, pause: 10)
                        guard r.skipped == nil else { continue }
                        checked += 1
                        frames += r.frames
                        copied += r.copiedFrames
                        t.check(r.mismatches.isEmpty, DrawingCacheCheck.line(for: r))
                    }
                }
            }
            print("    \(checked) skins, \(frames) frames, \(copied) with kept pictures")
            t.check(checked >= 140, "the repository's skins were checked: \(checked)")
            t.check(copied > frames / 4, "kept pictures were used: \(copied) of \(frames) frames")
        }
    }

    static func physicalFootprint() -> Int {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int(info.ri_phys_footprint) : 0
    }

    static func releaseTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: a covered window lets go of its kept pictures after a while, an ordered-out one of its frame too") {
            let w = FrameTestWindow()
            let runtime = try frameRuntime(t, keep, window: w)
            let frames = runtime.frames
            w.publish()
            _ = try runtime.load()
            runtime.send(.start)
            runtime.send(.firstFrame)
            w.show(true)
            for _ in 0..<3 {
                runtime.send(.update(hops: 0))
                endTurn()
            }
            t.check(frames.drawing.keepsPictures && frames.drawing.lastStats.copied > 0, "shown: pictures kept")
            frames.releaseUnseen()
            t.equal(frames.releases.pictures, 0, "nothing goes while the window can be seen")

            // Covered: the pictures go, the frame stays on the layer (it shows as soon as the window is uncovered).
            w.publish { $0.isVisible = false }
            endTurn()
            frames.releaseUnseen()
            t.check(!frames.drawing.keepsPictures, "covered: the kept pictures and bitmaps go")
            t.check(w.content.shown.image != nil, "the frame stays")
            t.equal(frames.releases.contents, 0)
            let drawn = frames.framesDrawn
            w.publish { $0.isVisible = true }
            endTurn()
            t.equal(frames.framesDrawn, drawn, "uncovered without a redraw meanwhile: nothing drawn")
            runtime.send(.update(hops: 0))
            endTurn()
            t.equal(frames.framesDrawn, drawn + 1)
            t.equal(frames.drawing.lastStats.copied, 0, "the next frame is drawn in full")
            checkShown(t, w.content, host: w.view.layer, runtime.skin, scale: 2, space: sRGB, "after the release")

            // Ordered out: the frame goes too; shown again, the frame for the showing comes first.
            w.show(false)
            endTurn()
            frames.releaseUnseen()
            t.check(w.content.shown.image == nil, "ordered out: the layer lets go of its frame")
            t.equal(frames.releases.contents, 1)
            runtime.send(.firstFrame)
            t.check(w.content.shown.image != nil, "the frame for the showing")
            t.equal(frames.framesDrawn, drawn + 2)
            w.show(true)
            endTurn()
            t.equal(frames.framesDrawn, drawn + 2, "and no second one when the window is ordered in")
            checkShown(t, w.content, host: w.view.layer, runtime.skin, scale: 2, space: sRGB, "shown again")
            runtime.send(.close(fadeOut: false, ticket: nil))
        }
    }

    /// These use the independent value capture, not a synthetic live Skin. Main delivery is held explicitly and
    /// its owner ACK is stepped through a real FIFO executor, without sleeps or a second owner thread.
    private final class BitmapDeliveryFixture {
        let view = NSView()
        lazy var content = LayerContentProvider(in: view)
        let executor = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        let context = SkinRenderContext()
        var requests: [SkinBitmapRequest] = []
        var presented: [UInt64] = []
        var capturesAvailable = true
        var failures = 0
        var scene = WidgetScene(generation: 7, size: SkinSize(width: 8, height: 6),
            background: [.fill(SkinRect(width: 8, height: 6), Paint(color: RGBA(r: 255, g: 0, b: 0)))],
            backgroundImageDependencies: [], glass: [], elements: [], hitMap: SkinHitMap(),
            environment: EnvironmentStamp(scale: 2, fontGeneration: 0,
                appearance: AppearanceStamp(value: .light, name: NSAppearance.Name.aqua.rawValue), imageGeneration: 0))
        var facts = SkinWindowFacts(frame: CGRect(x: 0, y: 0, width: 8, height: 6), isVisible: true,
            isOrderedIn: true, scale: 2, colorSpace: SkinFrameProducer.sRGB, takesPointer: true, sequence: 0,
            panelGeneration: 1)
        lazy var frames = SkinFrameProducer(provider: content, bitmapCapture: { [weak self] _, _ in
            guard let self, capturesAvailable else { return nil }
            return SkinBitmapDrawing.Capture(scene: scene, context: context, cycle: Int(scene.generation),
                size: CGSize(width: 8, height: 6), source: "Bitmap delivery test")
        })

        init(optIn: Bool = true, ordered: Bool = true) {
            facts.isOrderedIn = ordered; facts.isVisible = ordered
            if optIn { frames.requestBitmapDelivery = { [weak self] in self?.requests.append($0) } }
            frames.bitmapResult = { [weak self] result in
                switch result {
                case .presented(let capture): self?.presented.append(capture.scene.generation)
                case .failed: self?.failures += 1
                }
            }
            frames.start(on: executor)
            executor.runUntilIdle()
            frames.take(facts)
        }

        func draw() { frames.setNeedsFrame(); frames.runLoopTurn(.beforeWaiting) }

        func present(_ delivery: SkinBitmapDelivery) -> Bool {
            guard case .bitmap(let frame) = delivery.content else { return false }
            guard delivery.claimOnMain() else { return false }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let accepted = content.presentAccepted(frame)
            CATransaction.commit()
            _ = delivery.finishOnMain(accepted: accepted)
            executor.async { [frames] in frames.finishBitmapDelivery(delivery) }
            return accepted
        }

        func clear(_ invalidation: SkinBitmapInvalidation) -> Bool {
            guard invalidation.claimOnMain() else { return false }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let accepted = content.releaseContentsAccepted()
            CATransaction.commit()
            _ = invalidation.finishOnMain(accepted: accepted)
            executor.async { [frames] in frames.finishBitmapInvalidation(invalidation) }
            return accepted
        }

        func close() { frames.stop(); content.teardown() }
    }

    private static func bitmapDeliveryTests(_ t: AppTestRunner) {
        t.suite("App: bitmap delivery: held Main publication keeps one capture and ACK presents before latest redraw") {
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.draw()
            guard case .frame(let first)? = f.requests.first else { return t.check(false, "one immutable request") }
            t.check(f.content.shown.image == nil, "owner drawing never publishes before Main")
            t.equal(f.frames.framesDrawn, 0); t.equal(f.presented, [])
            t.equal(first.scene.generation, 7); t.equal(first.content.scale, 2)
            t.equal(first.panelGeneration, 1); t.check(CFEqual(first.space, SkinFrameProducer.sRGB))
            f.scene.generation = 8; f.draw()
            f.scene.generation = 9; f.draw()
            t.equal(f.requests.count, 1, "logic may advance while the one capture stays immutable")
            t.equal(first.scene.generation, 7); t.check(f.frames.needsFrame)
            t.check(f.present(first), "Main accepts its claimed frame in one transaction")
            t.equal(f.frames.framesDrawn, 0, "presentation accounting waits for the owner FIFO ACK")
            f.executor.runUntilIdle()
            t.equal(f.frames.framesDrawn, 1); t.equal(f.presented, [7])
            guard case .frame(let latest)? = f.requests.last else { return t.check(false, "latest draw queued") }
            t.equal(f.requests.count, 2); t.equal(latest.scene.generation, 9)
            t.check(latest.serial > first.serial)
            t.check(!first.claimOnMain() && !first.finishOnMain(accepted: true), "duplicate Main completion is inert")
            f.frames.finishBitmapDelivery(first)
            t.equal(f.frames.framesDrawn, 1)
            t.check(f.present(latest)); f.executor.runUntilIdle()
            t.equal(f.presented, [7, 9]); t.equal(f.frames.framesDrawn, 2)
            t.check(!f.frames.hasBitmapDelivery)
        }
        t.suite("App: bitmap delivery: cancelled frame and old clear cannot erase same-generation recovery") {
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.draw()
            guard case .frame(let cancelled)? = f.requests.last else { return t.check(false, "frame") }
            f.frames.clearBitmapContents()
            guard case .clear(let oldClear)? = f.requests.last else { return t.check(false, "ordered clear") }
            t.equal(cancelled.state, .cancelled)
            t.check(!cancelled.claimOnMain() && !cancelled.finishOnMain(accepted: true))
            f.frames.finishBitmapDelivery(cancelled)
            t.equal(f.presented, []); t.equal(f.frames.framesDrawn, 0)
            f.draw()
            guard case .frame(let recovered)? = f.requests.last else { return t.check(false, "recovery frame") }
            t.equal(recovered.scene.generation, cancelled.scene.generation)
            t.check(recovered.serial > oldClear.serial && recovered.lifecycle > cancelled.lifecycle)
            t.equal(oldClear.state, .cancelled)
            t.check(f.present(recovered)); f.executor.runUntilIdle()
            let held = f.content.shown.image
            t.check(held != nil)
            t.check(!f.clear(oldClear), "an old unclaimed clear cannot touch the newer picture")
            f.frames.finishBitmapInvalidation(oldClear)
            t.check(f.content.shown.image === held)
            t.equal(f.presented, [7]); t.equal(f.frames.framesDrawn, 1)
            f.frames.clearBitmapContents()
            guard case .clear(let clear)? = f.requests.last else { return t.check(false, "new clear") }
            t.check(f.content.shown.image === held, "owner clear also waits for Main")
            t.check(f.clear(clear)); f.executor.runUntilIdle()
            t.check(f.content.shown.image == nil)
            f.frames.drawFirstFrame()
            guard case .frame(let same)? = f.requests.last else { return t.check(false, "same scene can repaint") }
            t.equal(same.scene.generation, 7); t.check(same.serial > clear.serial)
            t.check(f.present(same)); f.executor.runUntilIdle()
            t.equal(f.presented, [7, 7]); t.equal(f.frames.framesDrawn, 2)
        }
        t.suite("App: bitmap delivery: claimed cancellation retains capture until late ACK then clears in Main order") {
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.draw()
            guard case .frame(let claimed)? = f.requests.last else { return t.check(false, "frame") }
            t.check(claimed.claimOnMain())
            f.frames.clearBitmapContents()
            guard case .clear(let clear)? = f.requests.last else { return t.check(false, "ordered clear") }
            t.equal(claimed.state, .applying); t.check(!claimed.cancel())
            t.check(f.frames.hasBitmapDelivery)
            f.draw(); t.equal(f.requests.count, 2, "claimed capture cannot be replaced before its ACK")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if case .bitmap(let frame) = claimed.content { t.check(f.content.presentAccepted(frame)) }
            else { t.check(false, "the bitmap-only fixture must retain its bitmap payload") }
            CATransaction.commit()
            t.check(claimed.finishOnMain(accepted: true))
            f.executor.async { f.frames.finishBitmapDelivery(claimed) }
            t.check(f.clear(clear)); t.check(f.content.shown.image == nil)
            f.executor.runUntilIdle()
            t.equal(f.frames.framesDrawn, 0); t.equal(f.presented, [], "invalidated late ACK does not advance presented")
            guard case .frame(let next)? = f.requests.last else { return t.check(false, "latest dirty scene resumes") }
            t.check(next.serial > clear.serial)
            t.check(f.present(next)); f.executor.runUntilIdle()
            t.equal(f.presented, [7]); t.equal(f.frames.framesDrawn, 1)
            f.draw()
            guard case .frame(let closing)? = f.requests.last else { return t.check(false, "closing frame") }
            t.check(closing.claimOnMain()); f.frames.stop(); f.frames.clearBitmapContents()
            t.check(closing.finishOnMain(accepted: true))
            f.frames.finishBitmapDelivery(closing)
            t.equal(f.frames.framesDrawn, 1); t.equal(f.presented, [7])
        }
        t.suite("App: bitmap delivery: destination rejection and teardown leave legacy direct presentation intact") {
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.draw()
            guard case .frame(let stale)? = f.requests.last else { return t.check(false, "frame") }
            f.facts.panelGeneration += 1
            f.frames.take(f.facts)
            t.equal(stale.state, .cancelled); t.check(!stale.claimOnMain())
            f.frames.finishBitmapDelivery(stale); f.frames.runLoopTurn(.beforeWaiting)
            guard case .frame(let next)? = f.requests.last else { return t.check(false, "new destination") }
            t.equal(next.panelGeneration, f.facts.panelGeneration)
            t.check(next.lifecycle > stale.lifecycle)
            t.check(next.finishOnMain(accepted: false), "Main may reject before touching its provider")
            t.check(!next.finishOnMain(accepted: true))
            f.frames.finishBitmapDelivery(next)
            t.equal(f.frames.framesDrawn, 0); t.check(f.content.shown.image == nil)
            f.executor.runUntilIdle()
            guard case .frame(let retired)? = f.requests.last else { return t.check(false, "retry") }
            f.content.teardown()
            t.check(!f.present(retired), "provider rejection is an observable receipt")
            t.equal(f.content.state.presented, 0)
            let direct = BitmapDeliveryFixture(optIn: false)
            defer { direct.close() }
            direct.draw()
            t.check(direct.content.shown.image != nil)
            t.equal(direct.frames.framesDrawn, 1); t.equal(direct.presented, [7])
            t.equal(direct.requests.count, 0)
            direct.frames.clearBitmapContents()
            t.check(direct.content.shown.image == nil, "legacy clear remains synchronous")
        }
        t.suite("App: bitmap delivery: failed drawing and unseen release queue clears without owner pixel writes") {
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.draw()
            guard case .frame(let first)? = f.requests.last else { return t.check(false, "frame") }
            t.check(f.present(first)); f.executor.runUntilIdle()
            let held = f.content.shown.image
            f.capturesAvailable = false; f.draw()
            guard case .clear(let failed)? = f.requests.last else { return t.check(false, "failure queues an ordered clear") }
            t.equal(f.failures, 1); t.equal(f.presented, [7]); t.equal(f.frames.framesDrawn, 1)
            t.check(f.content.shown.image === held, "failure cannot clear the provider from its owner")
            t.check(f.clear(failed)); f.executor.runUntilIdle()
            t.check(f.content.shown.image == nil)
            f.capturesAvailable = true; f.frames.drawFirstFrame()
            guard case .frame(let same)? = f.requests.last else { return t.check(false, "same-generation recovery") }
            t.check(f.present(same)); f.executor.runUntilIdle()
            let recovered = f.content.shown.image
            f.facts.isOrderedIn = false; f.facts.isVisible = false
            f.frames.take(f.facts); f.frames.runLoopTurn(.beforeWaiting); f.frames.releaseUnseen()
            guard case .clear(let unseen)? = f.requests.last else { return t.check(false, "unseen queues the same Main channel") }
            t.check(f.content.shown.image === recovered)
            t.equal(f.frames.releases.contents, 1)
            t.check(f.clear(unseen)); f.executor.runUntilIdle()
            t.check(f.content.shown.image == nil)
            t.equal(f.presented, [7, 7]); t.equal(f.frames.framesDrawn, 2)
        }
        t.suite("App: bitmap delivery: unshown first-frame debt survives rejected and claimed stale ACKs") {
            for claimed in [false, true] {
                let f = BitmapDeliveryFixture(ordered: false)
                defer { f.close() }
                f.frames.setNeedsFrame(); f.frames.drawFirstFrame()
                guard case .frame(let first)? = f.requests.last else { return t.check(false, "first frame before ordering in") }
                if claimed { t.check(first.claimOnMain()) }
                else { t.check(first.finishOnMain(accepted: false)) }
                f.facts.panelGeneration += 1
                f.frames.take(f.facts); f.frames.drawFirstFrame()
                t.equal(f.requests.count, 1, "the finished/claimed capture stays held until its FIFO ACK")
                t.check(f.frames.hasBitmapDelivery && f.frames.needsFrame)
                t.check(!f.frames.canBeSeen)
                if claimed {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    if case .bitmap(let frame) = first.content { t.check(f.content.presentAccepted(frame)) }
                    else { t.check(false, "the bitmap-only fixture must retain its bitmap payload") }
                    CATransaction.commit()
                    t.check(first.finishOnMain(accepted: true))
                }
                f.executor.async { f.frames.finishBitmapDelivery(first) }
                f.executor.runUntilIdle()
                t.equal(f.frames.framesDrawn, 0); t.equal(f.presented, [])
                guard case .frame(let retry)? = f.requests.last else { return t.check(false, "first frame debt resumes without visibility") }
                t.equal(f.requests.count, 2); t.equal(retry.panelGeneration, f.facts.panelGeneration)
                t.equal(retry.scene.generation, first.scene.generation)
                t.check(retry.serial > first.serial && retry.lifecycle > first.lifecycle)
                t.check(!f.frames.canBeSeen, "no fake order-in is required")
                t.check(f.present(retry)); f.executor.runUntilIdle()
                t.equal(f.frames.framesDrawn, 1); t.equal(f.presented, [7])
            }
        }
        t.suite("App: bitmap delivery: unseen release preserves a held clear and destination change replaces its responsibility") {
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.draw()
            guard case .frame(let first)? = f.requests.last else { return t.check(false, "first frame") }
            t.check(f.present(first)); f.executor.runUntilIdle()
            f.frames.clearBitmapContents()
            guard case .clear(let heldClear)? = f.requests.last else { return t.check(false, "held clear") }
            f.facts.isOrderedIn = false; f.facts.isVisible = false
            f.frames.take(f.facts); f.frames.runLoopTurn(.beforeWaiting); f.frames.releaseUnseen()
            t.equal(heldClear.state, .pending, "unseen release cannot cancel the already owed Main clear")
            t.check(f.content.shown.image != nil)
            f.facts.panelGeneration += 1; f.frames.take(f.facts)
            guard case .clear(let replacement)? = f.requests.last else { return t.check(false, "current destination clear") }
            t.equal(heldClear.state, .cancelled)
            t.equal(replacement.panelGeneration, f.facts.panelGeneration)
            t.check(replacement.serial > heldClear.serial)
            t.check(f.clear(replacement)); f.executor.runUntilIdle()
            t.check(f.content.shown.image == nil)
            t.equal(f.frames.framesDrawn, 1); t.equal(f.presented, [7])
        }
        t.suite("App: bitmap delivery: rejected clear keeps responsibility in either facts ACK order without spinning") {
            for factsFirst in [false, true] {
                let f = BitmapDeliveryFixture()
                defer { f.close() }
                f.draw()
                guard case .frame(let first)? = f.requests.last else { return t.check(false, "first frame") }
                t.check(f.present(first)); f.executor.runUntilIdle()
                f.frames.clearBitmapContents()
                guard case .clear(let rejected)? = f.requests.last else { return t.check(false, "clear") }
                t.check(rejected.finishOnMain(accepted: false))
                f.facts.panelGeneration += 1
                if factsFirst {
                    f.executor.async { f.frames.take(f.facts) }
                    f.executor.async { f.frames.finishBitmapInvalidation(rejected) }
                } else {
                    f.executor.async { f.frames.finishBitmapInvalidation(rejected) }
                    f.executor.runUntilIdle()
                    t.equal(f.requests.count, 2, "false ACK alone never schedules a retry loop")
                    t.check(f.content.shown.image != nil)
                    f.executor.async { f.frames.take(f.facts) }
                }
                f.executor.runUntilIdle()
                guard case .clear(let current)? = f.requests.last else { return t.check(false, "clear responsibility follows current facts") }
                t.equal(f.requests.count, 3)
                t.equal(current.panelGeneration, f.facts.panelGeneration)
                t.check(current.serial > rejected.serial)
                t.check(f.clear(current)); f.executor.runUntilIdle()
                t.check(f.content.shown.image == nil)
                t.equal(f.presented, [7]); t.equal(f.frames.framesDrawn, 1)
            }
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.frames.clearBitmapContents()
            guard case .clear(let rejected)? = f.requests.last else { return t.check(false, "clear without a picture") }
            t.check(rejected.finishOnMain(accepted: false))
            f.frames.finishBitmapInvalidation(rejected); f.executor.runUntilIdle()
            t.equal(f.requests.count, 1)
            f.facts.sequence += 1; f.frames.take(f.facts)
            guard case .clear(let retry)? = f.requests.last else { return t.check(false, "new facts permit one retry") }
            t.equal(f.requests.count, 2); t.check(retry.serial > rejected.serial)
        }
        t.suite("App: bitmap delivery: covered-only cancellation preserves latest dirty scene for uncovering") {
            let f = BitmapDeliveryFixture()
            defer { f.close() }
            f.draw()
            guard case .frame(let first)? = f.requests.last else { return t.check(false, "first frame") }
            t.check(f.present(first)); f.executor.runUntilIdle()
            let shown = f.content.shown.image
            f.scene.generation = 8; f.draw()
            guard case .frame(let pending)? = f.requests.last else { return t.check(false, "new held picture") }
            t.check(!f.frames.needsFrame)
            f.facts.isVisible = false
            f.frames.take(f.facts); f.frames.runLoopTurn(.beforeWaiting); f.frames.releaseUnseen()
            t.equal(pending.state, .cancelled)
            t.check(f.frames.needsFrame, "discarded unpublished pixels retain their dirty scene debt")
            t.equal(f.requests.count, 2, "a covered window keeps its old accepted provider contents")
            t.check(f.content.shown.image === shown)
            t.equal(f.frames.releases.contents, 0)
            f.facts.isVisible = true; f.frames.take(f.facts); f.frames.runLoopTurn(.beforeWaiting)
            guard case .frame(let latest)? = f.requests.last else { return t.check(false, "uncovered picture") }
            t.equal(f.requests.count, 3); t.equal(latest.scene.generation, 8)
            t.check(latest.serial > pending.serial)
            t.check(f.present(latest)); f.executor.runUntilIdle()
            t.equal(f.frames.framesDrawn, 2); t.equal(f.presented, [7, 8])
        }
    }

    /// Stationery's System widget (design system §14): everything that changes is drawn at every update over one kept
    /// picture of everything that does not, so a frame copies that picture and makes none.
    static func systemWidgetTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: System copies one kept picture a frame in every size and view") {
            guard let defaults = Paths.repositoryFolder("DefaultSkins") else {
                print("    (skipped: DefaultSkins not found; run from the repository)")
                return
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            let host = RenderHost()
            // The suite's sample readings: the same numbers at every update, nothing read in the background.
            let views = [("defaults", [String: String]()),
                         ("Cores view, sorted by memory, Swap", ["SystemCPUView": "Cores", "SystemSortBy": "1",
                                                                 "SystemFourthRing": "Swap"])]
            for (label, settings) in views {
                let root = t.temporaryDirectory("system-widget")
                try FileManager.default.copyItem(at: defaults.appendingPathComponent("Stationery"),
                                                 to: root.appendingPathComponent("Stationery"))
                let resources = root.appendingPathComponent("Stationery/@Resources")
                for (file, pairs) in [("System/Settings.inc", ["SystemSource": "Demo"]), ("Variables.inc", settings)] {
                    let url = resources.appendingPathComponent(file)
                    var text = try String(contentsOf: url, encoding: .utf8)
                    for (key, value) in pairs {
                        text = text.replacingOccurrences(of: "(?m)^\(key)=.*$", with: "\(key)=\(value)",
                                                         options: .regularExpression)
                    }
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
                for size in ["Small", "Medium", "Large"] {
                    let url = root.appendingPathComponent("Stationery/System/\(size).ini")
                    let skin = Skin(config: "Stationery\\System", fileURL: url, skinsDirectory: root,
                                    system: SystemMonitor.shared, host: host)
                    try skin.load()
                    defer { skin.close() }
                    let drawing = SkinBitmapDrawing()
                    func frame() -> (copied: Int, made: Int, drawn: Int) {
                        skin.update()
                        _ = drawing.picture(of: skin, size: CGSize(width: skin.width, height: skin.height), scale: 2,
                                            space: space, appearance: "test")
                        return drawing.lastStats
                    }
                    // Loading: the first readings, the GPU's late one, the Disk ring's figure.
                    for _ in 0..<9 { _ = frame() }
                    let frames = (0..<12).map { _ in frame() }
                    t.check(frames.allSatisfy { $0.copied == 1 && $0.made == 0 },
                            "\(size), \(label): \(frames.map { "\($0.copied)/\($0.made)/\($0.drawn)" })")
                    t.equal(drawing.keptRuns, 1, "\(size), \(label): one picture kept")

                    // The card's sentence and a row's words are read when their tooltip opens.
                    let sentence = skin.measure(named: "MeasureSentence")?.stringValue ?? "?"
                    t.check(sentence.hasPrefix("CPU 21%"), sentence)
                    let card = skin.toolTipInfo(at: skin.width / 2, skin.height - 8)
                    t.equal(card?.title, "MacBook Pro", "\(size): the card's tooltip")
                    t.equal(card?.text, sentence)
                    if size == "Large" {
                        let sort = label == "defaults" ? "CPU" : "Mem"
                        let row = skin.toolTipInfo(at: 40, 270)
                        t.equal(row?.title, skin.measure(named: "MeasureTop\(sort)1Name")?.stringValue,
                                "\(label): the first row's tooltip")
                        t.equal(row?.text, skin.measure(named: "MeasureTop\(sort)1Tip")?.stringValue)
                        t.check(row?.text.isEmpty == false)
                    }
                    guard size != "Small" else { continue }

                    // What rests in the picture is drawn again when it changes: the uptime and the Disk ring.
                    skin.execute("[!SetOption MeasureUptimeText String \"3 d 4 h\"][!UpdateMeasure MeasureUptimeText]",
                                 from: nil)
                    t.equal((skin.meter(named: "MeterUptime") as? StringMeter)?.text, "Up 3 d 4 h", "\(size)")
                    skin.execute("[!SetOption MeasureDiskText String 97][!UpdateMeasure MeasureDiskText]"
                                 + "[!UpdateMeasure MeasureDiskShown]", from: nil)
                    t.equal((skin.meter(named: "MeterDiskValue") as? StringMeter)?.text, "97%", "\(size)")
                    // The changed meters are drawn around the rest of the picture, which is then made again whole
                    // once and copied from then on.
                    let changed = frame()
                    t.check(changed.made >= 1 && changed.drawn > frames[0].drawn, "\(size): \(changed)")
                    let whole = frame()
                    t.check(whole.copied == 0 && whole.made == 1, "\(size): \(whole)")
                    let after = frame()
                    t.check(after.copied == 1 && after.made == 0, "\(size): \(after)")
                }
            }
            withExtendedLifetime(host) {}
        }
    }

    static func memoryTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: the first-run widgets redrawn 30 times keep memory flat") {
            guard let repository = Paths.repositoryFolder("DefaultSkins") else {
                print("    (skipped: DefaultSkins not found; run from the repository)")
                return
            }
            // A copy: skins may write their own files.
            let root = t.temporaryDirectory("drawing-memory")
            try FileManager.default.copyItem(at: repository.appendingPathComponent("Stationery"),
                                             to: root.appendingPathComponent("Stationery"))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            var skins: [Skin] = []
            for (config, file) in [("Clock", "Small.ini"), ("Calendar", "Small.ini"), ("Weather", "Medium.ini"),
                                   ("System", "Medium.ini")] {
                let url = root.appendingPathComponent("Stationery/\(config)/\(file)")
                guard let skin = AppSelfTest.loadSkin(url, config: "Stationery\\\(config)", skins: root) else {
                    return t.check(false, "\(config) loads")
                }
                skins.append(skin)
            }
            let drawings = skins.map { _ in SkinBitmapDrawing() }
            func draw(_ frames: Int) {
                for _ in 0..<frames {
                    for (skin, drawing) in zip(skins, drawings) {
                        skin.update()
                        _ = drawing.picture(of: skin, size: CGSize(width: skin.width, height: skin.height), scale: 2,
                                            space: space, appearance: "test")
                    }
                }
            }
            draw(3)
            let before = physicalFootprint()
            draw(30)
            let grown = physicalFootprint() - before
            // Each skin holds two bitmaps of its own size and at most `maxRuns` pictures; nothing piles up.
            t.check(grown < 24 << 20, "grew \(grown >> 20) MB")
            skins.forEach { $0.close() }
        }
    }
}

/// The main-thread side of a runtime in the frame tests: a skin panel with the view and content layer of a skin window
/// (never shown), size requests applied as the window controller applies them, and window facts the test makes.
final class FrameTestWindow: SkinRuntimeWindow {
    let panel = SkinWindowController.makePanel()
    let contentView = SkinContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let view = SkinView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let content: LayerContentProvider
    weak var runtime: SkinRuntime?
    private(set) var facts: SkinWindowFacts
    /// The sizes the runtime asked the window to follow.
    private(set) var resizes: [CGSize] = []
    /// Requests that arrived off the main thread (none should).
    private(set) var offMain = 0

    init() {
        contentView.addSubview(view)
        content = LayerContentProvider(in: view)
        panel.contentView = contentView
        panel.setFrame(NSRect(x: 100, y: 500, width: 1, height: 1), display: false)
        facts = SkinWindowFacts(frame: panel.frame, isVisible: false, isOrderedIn: false, scale: 2,
                                colorSpace: SkinFrameProducer.sRGB, appearance: NSAppearance.Name.aqua.rawValue,
                                takesPointer: false, sequence: 0)
    }

    /// Changes the facts and tells the runtime (its frames follow them). Main thread.
    func publish(_ change: (inout SkinWindowFacts) -> Void = { _ in }) {
        change(&facts)
        facts.frame = panel.frame
        facts.sequence += 1
        runtime?.send(.windowFacts(facts))
    }

    /// Shown and uncovered, or ordered out.
    func show(_ shown: Bool) {
        publish {
            $0.isOrderedIn = shown
            $0.isVisible = shown
        }
    }

    func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
        if !Thread.isMainThread { offMain += 1 }
        guard case .resize(let size) = request else { return }
        resizes.append(size)
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: false)
        view.frame = NSRect(origin: .zero, size: size)
        publish()
    }

    func batchingWindowChanges(_ body: () -> Void) { body() }
    func liveEnvironment(for skin: Skin) -> SkinEnvironment? { nil }
    var liveTakesPointer: Bool? { nil }
    var screen: NSScreen? { nil }
}

/// A content provider that notes where each frame was presented from (main thread or not) before passing it on.
final class PresentRecorder: ContentProvider {
    let inner: ContentProvider
    /// For each frame: presented on the main thread.
    let threads = Guarded<[Bool]>([])

    init(_ inner: ContentProvider) {
        self.inner = inner
    }

    var count: Int { threads.current.count }

    func present(_ frame: SkinFrame) {
        threads.access { $0.append(Thread.isMainThread) }
        inner.present(frame)
    }

    func setVisible(_ visible: Bool) { inner.setVisible(visible) }
    func setScale(_ scale: CGFloat) { inner.setScale(scale) }
    func teardown() { inner.teardown() }
}

/// The skin window's view as it drew until phase 2 of the threading design: `SkinView.updateLayer`, which set the
/// picture as the view's own layer contents, drawn at the scale, in the colour space and with the appearance it read
/// from its window (here: set by the check, the values the window would have had). The content-layer check shows it
/// beside the new frames.
final class LegacySkinView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    let drawing = SkinBitmapDrawing()
    var skin: Skin?
    var scale: CGFloat = 2
    var space = SkinFrameProducer.sRGB
    var drawingAppearance = NSAppearance.Name.aqua.rawValue
    /// Times the view was drawn.
    private(set) var draws = 0

    override func updateLayer() {
        guard let layer else { return }
        guard let skin else {
            layer.contents = nil
            return
        }
        layer.contentsScale = scale
        let size = bounds.size
        guard let picture = drawing.picture(of: skin, size: size, scale: scale, space: space,
                                            appearance: drawingAppearance) else { return }
        layer.contents = picture
        draws += 1
    }

    /// What the layer shows.
    var shownImage: CGImage? {
        guard let contents = layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }
}

/// A never-shown skin panel with a `LegacySkinView` in its content view, sized as a skin window.
final class LegacyWindow {
    let panel = SkinWindowController.makePanel()
    let contentView = SkinContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let view = LegacySkinView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

    init() {
        contentView.addSubview(view)
        view.wantsLayer = true
        panel.contentView = contentView
        panel.setFrame(NSRect(x: 100, y: 500, width: 1, height: 1), display: false)
    }

    /// The window follows the skin's size with its top-left corner fixed, as the window controller does.
    func resize(to size: CGSize) {
        guard panel.frame.size != size else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: false)
        view.frame = NSRect(origin: .zero, size: size)
    }
}

extension SkinDrawingSelfTests {
    /// Every default skin and test skin (and the Skins folders `DESKSET_DRAWING_CHECK_SKINS` names, as for the drawing
    /// check) through `ContentLayerCheck`: the content layer against what the skin's view showed until phase 2.
    static func contentLayerCheckTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: every repository skin's content layer shows what its view showed") {
            var folders = ["DefaultSkins", "TestSkins"].compactMap { Paths.repositoryFolder($0) }
            guard folders.count == 2 else {
                print("    (skipped: DefaultSkins or TestSkins not found; run from the repository)")
                return
            }
            let extra = ProcessInfo.processInfo.environment["DESKSET_DRAWING_CHECK_SKINS"] ?? ""
            folders += extra.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            let temporary = t.temporaryDirectory("content-layer-check")
            var results: [ContentLayerCheck.Result] = []
            DrawingCacheCheck.withCheckEnvironment(temporary, weatherPreview: false) {
                for (i, folder) in folders.enumerated() {
                    let copy = temporary.appendingPathComponent("Skins\(i)")
                    guard (try? FileManager.default.copyItem(at: folder, to: copy)) != nil else {
                        return t.check(false, "copies \(folder.lastPathComponent)")
                    }
                    for file in DrawingCacheCheck.skinFiles(in: copy) {
                        let r = ContentLayerCheck.check(file, skinsRoot: copy, budget: 2)
                        guard r.skipped == nil else { continue }
                        results.append(r)
                        t.check(r.mismatches.isEmpty, ContentLayerCheck.line(for: r))
                    }
                }
            }
            let steps = results.reduce(0) { $0 + $1.steps }
            let worst = results.map(\.worstComposite).max() ?? 0
            let fractional = results.filter(\.fractional).count
            let stretched = results.filter { !$0.stretchedBefore.isEmpty }
            print("    \(results.count) skins, \(steps) steps compared, worst composite difference \(worst); "
                  + "\(fractional) skins with a size that is not whole points")
            // The one difference that remains (docs/compat/engine.md): the old view stretched a picture over a size that
            // is not a whole number of pixels; the content layer shows it pixel for pixel.
            for r in stretched {
                print("    stretched before, pixel for pixel now: \(r.config) \(r.file): "
                      + r.stretchedBefore.joined(separator: ", "))
            }
            if let path = ProcessInfo.processInfo.environment["DESKSET_CONTENT_LAYER_REPORT"] {
                let text = results.map(ContentLayerCheck.line(for:)).joined(separator: "\n") + "\n"
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
            t.check(results.count >= 140, "the repository's skins were checked: \(results.count)")
            t.check(steps >= results.count * 6, "most steps ran: \(steps)")
        }
    }
}

/// Phase 2, step 4 of docs/skin-threading.md: whether the content layer shows what the skin's view showed until then.
/// A skin runs without a window, as for the drawing check (no permissions asked for, nothing done outside the skin), and
/// is shown twice side by side, in never-shown skin panels:
/// - the new way: its frame producer draws at the end of each turn and presents to a `LayerContentProvider` in a
///   `SkinView`, following window facts the check makes;
/// - the old way: a `LegacySkinView` drawn when AppKit would have drawn the old view (a redraw while the window could be
///   seen; ordered in; uncovered after a redraw was skipped; another scale, colour space or appearance).
/// After every step in which the window can be seen, the two pictures are compared with each other and with a full
/// drawing, and the two panels' layer trees as Core Animation composites them (where the picture sits, its size and
/// scale, what clips it). Steps: shown, updates, redraws at rest, 1× and back, Display P3 and back, Dark and back,
/// covered and uncovered, ordered out (!Hide) and in again (!Show), and a fade (the window's alpha).
enum ContentLayerCheck {
    struct Result {
        var config: String
        var file: String
        /// Steps compared while the window could be seen.
        var steps = 0
        /// The largest differences of one channel: the content layer's picture against the old view's, against a full
        /// drawing, and the composited layer trees.
        var worstPicture = 0
        var worstFull = 0
        var worstComposite = 0
        var mismatches: [String] = []
        var skipped: String?
        /// A window size that is not a whole number of points showed up.
        var fractional = false
        /// Steps whose composites differ only because the old view stretched its picture over a size that is not a
        /// whole number of pixels (docs/compat/engine.md, "A skin whose size is not a whole number of pixels"), and by
        /// how much.
        var stretchedBefore: [String] = []
        var outOfTime = false
    }

    static func line(for r: Result) -> String {
        if let skipped = r.skipped { return "skip      \(r.config) \(r.file): \(skipped)" }
        let stretched = r.stretchedBefore.isEmpty ? "" : "; stretched before: " + r.stretchedBefore.joined(separator: ", ")
        let head = "\(r.config) \(r.file): \(r.steps) steps, worst picture \(r.worstPicture), full \(r.worstFull), "
            + "composite \(r.worstComposite)\(r.fractional ? ", fractional size" : "")\(r.outOfTime ? ", out of time" : "")"
            + stretched
        return r.mismatches.isEmpty ? "ok        \(head)" : "MISMATCH  \(head)\n    " + r.mismatches.joined(separator: "\n    ")
    }

    /// `--render`'s host, whose redraws reach the check.
    final class Host: SkinHost {
        let render = RenderHost()
        var redrew: () -> Void = {}

        func skinNeedsDisplay(_ skin: Skin) { redrew() }
        func skin(_ skin: Skin, handle bang: Bang) -> Bool { true }
        func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {}
        func skin(_ skin: Skin, execute target: String, arguments: [String]) {}
        func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {}
        func textSize(_ text: String, style: TextStyle, wrapWidth: Double?,
                      for skin: Skin) -> (width: Double, height: Double) {
            render.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
        }
        func imageSize(atPath path: String) -> (width: Double, height: Double)? { render.imageSize(atPath: path) }
        func environment(for skin: Skin) -> SkinEnvironment { render.environment(for: skin) }
    }

    static func check(_ file: URL, skinsRoot: URL, budget: TimeInterval) -> Result {
        let parent = file.deletingLastPathComponent().standardizedFileURL.pathComponents
        let config = parent.dropFirst(skinsRoot.standardizedFileURL.pathComponents.count).joined(separator: "\\")
        var result = Result(config: config, file: file.lastPathComponent)
        let started = ProcessInfo.processInfo.systemUptime
        let host = Host()
        let skin = Skin(config: config, fileURL: file, skinsDirectory: skinsRoot, system: SystemMonitor.shared, host: host)
        let policy = StudioActionPolicy()
        skin.actionPolicy = policy
        do {
            try skin.load()
        } catch {
            result.skipped = "does not load (\(error))"
            return result
        }
        defer { skin.close() }
        Fonts.registerFonts(for: skin)

        let new = FrameTestWindow()
        let producer = SkinFrameProducer(provider: new.content, skin: { skin })
        producer.start(on: MainSkinExecutor.shared)
        defer {
            producer.stop()
            new.content.teardown()
        }
        let old = LegacyWindow()
        old.view.skin = skin
        var facts = SkinWindowFacts(frame: .zero, isVisible: false, isOrderedIn: false, scale: 2,
                                    colorSpace: SkinFrameProducer.sRGB, appearance: NSAppearance.Name.aqua.rawValue,
                                    takesPointer: true, sequence: 0)
        // The old view: drawn at the end of the turn when it needs it and its window is ordered in; a redraw while the
        // window could not be seen waited for it to be uncovered.
        var oldNeedsDisplay = false
        var oldPending = false
        var seen: Bool { facts.isOrderedIn && facts.isVisible }
        /// Ordered in since the last step: on screen before its occlusion state says so.
        var orderedInNow = false

        func size() -> CGSize { SkinRuntime.windowSize(width: skin.width, height: skin.height) }
        func followSize() {
            let s = size()
            if s.width != s.width.rounded() || s.height != s.height.rounded() { result.fractional = true }
            if new.panel.frame.size != s {
                let top = new.panel.frame.maxY
                new.panel.setFrame(NSRect(x: new.panel.frame.minX, y: top - s.height, width: s.width, height: s.height),
                                   display: false)
                new.view.frame = NSRect(origin: .zero, size: s)
            }
            old.resize(to: s)
        }
        host.redrew = {
            followSize()
            producer.setNeedsFrame()
            if seen { oldNeedsDisplay = true } else { oldPending = true }
        }
        func publish(_ change: (inout SkinWindowFacts) -> Void) {
            let before = facts
            change(&facts)
            facts.sequence += 1
            if facts.scale != before.scale || facts.colorSpace != before.colorSpace
                || facts.appearance != before.appearance { oldNeedsDisplay = true }
            if facts.isOrderedIn && !before.isOrderedIn {
                oldNeedsDisplay = true
                orderedInNow = true
            }
            if seen && oldPending {
                oldPending = false
                oldNeedsDisplay = true
            }
            old.view.scale = facts.scale
            old.view.space = facts.colorSpace ?? SkinFrameProducer.sRGB
            old.view.drawingAppearance = facts.appearance
            producer.take(facts)
        }
        func endTurn() {
            SkinDrawingSelfTests.endTurn()
            if oldNeedsDisplay && facts.isOrderedIn {
                oldNeedsDisplay = false
                old.view.updateLayer()
            }
        }
        func step(_ label: String, _ action: String? = nil, update: Bool = false) {
            // A skin whose drawings are slow has had its time: the steps left are not taken.
            guard result.skipped == nil, ProcessInfo.processInfo.systemUptime - started < budget else {
                if result.skipped == nil { result.outOfTime = true }
                return
            }
            if let action { skin.execute(action, from: nil) }
            if update { skin.update() }
            endTurn()
            defer { orderedInNow = false }
            guard seen || (facts.isOrderedIn && orderedInNow) else { return }
            let s = size(), scale = facts.scale, space = facts.colorSpace ?? SkinFrameProducer.sRGB
            let w = Int((s.width * scale).rounded(.up)), h = Int((s.height * scale).rounded(.up))
            guard w * h <= DrawingCacheCheck.maxPixels else {
                result.skipped = "too large (\(w)×\(h) pixels)"
                return
            }
            guard let picture = new.content.shown.image else {
                result.mismatches.append("\(label): no frame on the content layer")
                return
            }
            guard let before = old.view.shownImage else {
                result.mismatches.append("\(label): the old view shows nothing")
                return
            }
            result.steps += 1
            func note(_ what: String, _ worst: Int) -> Int {
                if worst > SkinBitmapDrawing.tolerance { result.mismatches.append("\(label): \(what) differs by \(worst)") }
                return worst
            }
            var oldContext: CGContext?
            if let ctx = SkinBitmapDrawing.makeContext(before.width, before.height, before.colorSpace ?? space) {
                ctx.setBlendMode(.copy)
                ctx.draw(before, in: CGRect(x: 0, y: 0, width: before.width, height: before.height))
                oldContext = ctx
            }
            let pictures = oldContext.flatMap { SkinBitmapDrawing.difference(picture, $0)?.worst } ?? .max
            result.worstPicture = max(result.worstPicture, note("the picture from the old view's", pictures))
            let full = SkinDrawingSelfTests.differenceFromFullDrawing(picture, skin, scale: scale, space: space)?.worst
            result.worstFull = max(result.worstFull, note("the picture from a full drawing", full ?? .max))
            let a = SkinDrawingSelfTests.composite(new.contentView.layer, size: s, scale: scale, space: space)
            let b = SkinDrawingSelfTests.composite(old.contentView.layer, size: s, scale: scale, space: space)
            var composites = SkinDrawingSelfTests.differenceOfContexts(a, b)
            if composites > SkinBitmapDrawing.tolerance, CGFloat(w) != s.width * scale || CGFloat(h) != s.height * scale {
                // A size that is not a whole number of pixels: the old view stretched its picture (w × h pixels) over
                // it. Shown at the picture's own size, is the old view's composite the same?
                let fitted = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
                old.view.frame = NSRect(origin: .zero, size: fitted)
                old.view.updateLayer()
                let unstretched = SkinDrawingSelfTests.composite(old.contentView.layer, size: s, scale: scale,
                                                                 space: space)
                old.view.frame = NSRect(origin: .zero, size: s)
                old.view.updateLayer()
                let rest = SkinDrawingSelfTests.differenceOfContexts(a, unstretched)
                if rest <= SkinBitmapDrawing.tolerance {
                    result.stretchedBefore.append("\(label) (\(Int(scale))x): \(composites)")
                    composites = rest
                }
            }
            result.worstComposite = max(result.worstComposite, note("the composite from the old window's", composites))
        }

        followSize()
        publish { $0.frame = new.panel.frame }
        skin.update()
        endTurn()
        // `start`: the first frame, then the window is ordered in.
        producer.drawFirstFrame()
        oldNeedsDisplay = true
        publish {
            $0.isOrderedIn = true
            $0.isVisible = true
        }
        step("shown")
        for i in 0..<2 {
            RenderCommand.wait(milliseconds: DrawingCacheCheck.updateInterval)
            step("update \(i + 1)", update: true)
        }
        step("redraw at rest", "[!Redraw]")
        step("again", "[!Redraw]")
        publish { $0.scale = 1 }
        step("at 1x")
        step("an update at 1x", update: true)
        publish { $0.scale = 2 }
        step("back at 2x")
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3) {
            publish { $0.colorSpace = p3 }
            step("in Display P3")
            publish { $0.colorSpace = SkinFrameProducer.sRGB }
            step("back in sRGB")
        }
        publish { $0.appearance = NSAppearance.Name.darkAqua.rawValue }
        step("dark")
        publish { $0.appearance = NSAppearance.Name.aqua.rawValue }
        step("light again")
        publish { $0.isVisible = false }
        step("covered", update: true)
        publish { $0.isVisible = true }
        step("uncovered")
        publish {
            $0.isOrderedIn = false
            $0.isVisible = false
        }
        step("hidden", "[!Redraw]", update: true)
        publish { $0.isOrderedIn = true }
        step("shown again, before the occlusion state catches up")
        publish { $0.isVisible = true }
        step("shown again")
        publish { $0.settings.alphaValue = 100 }
        step("fading", update: true)
        publish { $0.settings.alphaValue = 255 }
        step("faded in", "[!Redraw]")
        return result
    }
}
