import AppKit
import DesksetCore

/// A skin window's picture: drawn into a bitmap of its own (`SkinBitmapDrawing`), with pictures kept of the meters that
/// did not change while the skin redraws often.
enum SkinDrawingSelfTests {
    static func run(_ t: AppTestRunner) {
        keptPictureTests(t)
        viewTests(t)
        memoryTests(t)
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
                let scale = view.layer?.contentsScale ?? 1
                t.equal(image.width, Int((view.bounds.width * scale).rounded(.up)))
                t.equal(image.height, Int((view.bounds.height * scale).rounded(.up)))
            }
            app.stopAllForTermination()
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
