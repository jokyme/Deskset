import AppKit
import DesksetCore

/// A skin window's picture: drawn into a bitmap of its own (`SkinBitmapDrawing`), with pictures kept of the meters that
/// did not change while the skin redraws often.
enum SkinDrawingSelfTests {
    static func run(_ t: AppTestRunner) {
        keptPictureTests(t)
        invalidationTests(t)
        viewTests(t)
        memoryTests(t)
        repositorySkinTests(t)
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

    static func viewTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: a skin window's layer shows a picture of its own") {
            guard let app = try AppSelfTest.makeApp(t),
                  let c = app.activate(config: "App\\Focus", file: "Focus.ini") else { return t.check(false, "loads") }
            let view = c.view
            // Core Animation's accelerated drawing (CA::CG) kept 110–150 MB per process for skins that redraw.
            t.check(view.wantsUpdateLayer, "the view gives its layer a picture instead of drawing into a backing store")
            view.wantsLayer = true
            view.updateLayer()
            let contents = view.layer?.contents
            t.check(contents != nil && CFGetTypeID(contents as CFTypeRef) == CGImage.typeID, "a CGImage")
            if let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = contents as! CGImage
                // The window's color space (a display's profile), as AppKit drew the view before: sRGB colors come out
                // the same, and colors beyond sRGB (Display P3 pictures) are not clipped as in an sRGB bitmap.
                if let space = view.window?.colorSpace?.cgColorSpace {
                    t.check(image.colorSpace == space, "in the window's color space: \(String(describing: image.colorSpace))")
                }
                let scale = view.layer?.contentsScale ?? 1
                t.equal(image.width, Int((view.bounds.width * scale).rounded(.up)))
                t.equal(image.height, Int((view.bounds.height * scale).rounded(.up)))
            }
            // The picture is the view's own: another display (scale, color space) or appearance draws it again.
            view.needsDisplay = false
            view.viewDidChangeBackingProperties()
            t.check(view.needsDisplay, "a backing change draws the picture again")
            view.needsDisplay = false
            view.viewDidChangeEffectiveAppearance()
            t.check(view.needsDisplay, "an appearance change draws the picture again")
            app.stopAllForTermination()
        }
    }

    /// Every default skin and test skin (and, when `DESKSET_DRAWING_CHECK_SKINS` names more Skins folders, separated
    /// by colons, those too: a local corpus that never goes into the repository) through `DrawingCacheCheck`.
    static func repositorySkinTests(_ t: AppTestRunner) {
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
            DrawingCacheCheck.withCheckEnvironment(temporary) {
                for (i, folder) in folders.enumerated() {
                    let copy = temporary.appendingPathComponent("Skins\(i)")
                    guard (try? FileManager.default.copyItem(at: folder, to: copy)) != nil else {
                        return t.check(false, "copies \(folder.lastPathComponent)")
                    }
                    for file in DrawingCacheCheck.skinFiles(in: copy) {
                        let r = DrawingCacheCheck.check(file, skinsRoot: copy, updates: 3, scale: 2)
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

    static func memoryTests(_ t: AppTestRunner) {
        t.suite("App: skin drawing: the first-run widgets redrawn 30 times keep memory flat") {
            guard let root = Paths.repositoryFolder("DefaultSkins") else {
                print("    (skipped: DefaultSkins not found; run from the repository)")
                return
            }
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
