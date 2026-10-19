import AppKit
import DesksetCore

/// Desktop zoom is applied to drawing commands, window geometry and native glass at the same logical scale.
enum SkinZoomDrawingSelfTests {
    static func run(_ t: AppTestRunner) {
        frameTests(t)
        cacheTests(t)
        glassTests(t)
        glassControllerTests(t)
    }

    private static let fixture = """
    [Rainmeter]
    Update=-1
    [Extent]
    Meter=Image
    W=80
    H=40
    [Red]
    Meter=Shape
    W=40
    H=40
    Shape=Rectangle 0,0,40,40 | Fill Color 255,0,0 | StrokeWidth 0
    ToolTipText=Red region
    [Blue]
    Meter=Shape
    Shape=Rectangle 40,0,20,40 | Fill Color 0,0,255 | StrokeWidth 0
    [Text]
    Meter=String
    X=3
    Y=25
    W=54
    H=15
    FontSize=9
    FontColor=255,255,255
    Text=Zoom
    AntiAlias=1
    """

    private static func frameTests(_ t: AppTestRunner) {
        t.suite("App: skin zoom drawing: desktop frames and snapshots agree at 10, 100, 150 and 500 percent") {
            let window = FrameTestWindow()
            let runtime = try SkinDrawingSelfTests.frameRuntime(t, fixture, window: window)
            defer {
                runtime.send(.close(fadeOut: false))
                window.content.teardown()
            }
            _ = try runtime.load()
            runtime.send(.start)
            window.show(true)
            for scale: CGFloat in [1, 2] {
                window.publish { $0.scale = scale }
                for zoom in [1.0, 1.5, 0.1, 5.0, 1.0] {
                    let before = runtime.snapshot
                    runtime.send(.execute("[!SetZoomFactor \(zoom)]", section: nil))
                    SkinDrawingSelfTests.endTurn()
                    let snapshot = runtime.snapshot
                    let size = CGSize(width: 80 * zoom, height: 40 * zoom)
                    t.equal(snapshot.logicalSize, CGSize(width: 80, height: 40), "logical coordinates do not grow")
                    t.equal(snapshot.size, size, "published display size at \(zoom)")
                    t.equal(snapshot.zoomFactor, zoom)
                    t.equal(window.panel.frame.size, size, "the actual window follows the zoom")
                    t.equal(snapshot.toolTipAreas, [CGRect(x: 0, y: 0, width: 40 * zoom, height: 40 * zoom)],
                            "AppKit tooltip rectangles follow the displayed region")
                    if zoom != before.zoomFactor {
                        let changes = snapshot.changes(from: before)
                        t.check(changes.contains([.size, .toolTips, .glass]), "native geometry is invalidated together")
                    }
                    let shown = window.content.shown
                    guard let image = shown.image else { return t.check(false, "a desktop frame") }
                    let width = Int((size.width * scale).rounded(.up))
                    let height = Int((size.height * scale).rounded(.up))
                    t.equal(image.width, width, "the frame is rasterized at its new pixel width")
                    t.equal(image.height, height, "the frame is rasterized at its new pixel height")
                    t.equal(shown.bounds.size, size, "display points are independent of Retina backing pixels")
                    t.equal(shown.scale, scale, "the content layer keeps only the backing scale")
                    checkRegions(t, image, pixelsPerLogicalPoint: scale * CGFloat(zoom))
                    guard let screenshot = snapshotDrawing(runtime.skin, width: width, height: height, scale: scale),
                          let difference = SkinBitmapDrawing.difference(image, screenshot) else {
                        return t.check(false, "the view snapshot can be compared with the desktop frame")
                    }
                    t.check(difference.worst <= SkinBitmapDrawing.tolerance,
                            "snapshot and frame differ by \(difference.worst) at zoom \(zoom), backing \(scale)")
                    for _ in 0..<2 {
                        runtime.send(.frameWanted)
                        SkinDrawingSelfTests.endTurn()
                    }
                    t.check(runtime.frames.drawing.lastStats.copied > 0, "stable commands can still reuse zoomed runs")
                }
            }
        }
    }

    private static func snapshotDrawing(_ skin: Skin, width: Int, height: Int, scale: CGFloat,
                                        space: CGColorSpace = SkinFrameProducer.sRGB) -> CGContext? {
        guard let context = SkinBitmapDrawing.makeContext(width, height, space) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        SkinRenderer.drawZoomed(skin, in: context, glass: .window)
        return context
    }

    private static func checkRegions(_ t: AppTestRunner, _ image: CGImage, pixelsPerLogicalPoint scale: CGFloat) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        func color(_ x: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(x * scale), y: Int(10 * scale))?.usingColorSpace(.sRGB)
        }
        let red = color(20), blue = color(50), empty = color(70)
        t.check((red?.redComponent ?? 0) > 0.98 && (red?.blueComponent ?? 1) < 0.02,
                "the red region occupies the same logical area")
        t.check((blue?.blueComponent ?? 0) > 0.98 && (blue?.redComponent ?? 1) < 0.02,
                "the blue region moves with its scaled boundary")
        t.equal(empty?.alphaComponent, 0, "unpainted logical space remains transparent")
    }

    private static func cacheTests(_ t: AppTestRunner) {
        t.suite("App: skin zoom drawing: a new zoom invalidates kept pictures even at an unchanged bitmap size") {
            guard let (skin, host, _) = SkinDrawingSelfTests.load(t, fixture, "zoom-cache") else {
                return t.check(false, "the skin loads")
            }
            defer { skin.close() }
            let drawing = SkinBitmapDrawing()
            let size = CGSize(width: 80, height: 40)
            func picture() -> CGImage? {
                drawing.picture(of: skin, size: size, scale: 1, space: SkinFrameProducer.sRGB,
                                appearance: NSAppearance.Name.aqua.rawValue)
            }
            for _ in 0..<3 { _ = picture() }
            t.check(drawing.lastStats.copied > 0, "the old frame has kept runs")
            skin.applyHostZoomFactor(1.5)
            guard let image = picture() else { return t.check(false, "the new frame") }
            t.equal(drawing.lastStats.copied, 0, "no bitmap drawn at the previous zoom survives")
            let color = NSBitmapImageRep(cgImage: image).colorAt(x: 55, y: 10)?.usingColorSpace(.sRGB)
            t.check((color?.redComponent ?? 0) > 0.98 && (color?.blueComponent ?? 1) < 0.02,
                    "the red vector now reaches pixel 55, which was blue at the previous zoom")
            withExtendedLifetime(host) {}
        }
    }

    private static func glassTests(_ t: AppTestRunner) {
        t.suite("App: skin zoom drawing: native glass frames, clipping and corner radii follow user zoom") {
            let savedFallback = SkinGlassViews.forcesFallback
            defer { SkinGlassViews.forcesFallback = savedFallback }
            let region = GlassRegion(id: "Card", rect: SkinRect(x: 8, y: 12, width: 40, height: 24), cornerRadius: 6,
                                     tint: RGBA(r: 20, g: 80, b: 160, a: 255),
                                     clip: SkinRect(x: 10, y: 14, width: 20, height: 12))
            for fallback in [true, false] {
                SkinGlassViews.forcesFallback = fallback
                let glass = SkinGlassViews()
                let container = SkinContentView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
                let content = NSView(frame: container.bounds)
                container.addSubview(content)
                var firstPiece: SkinGlassViews.Piece?
                for zoom in [1.0, 1.5, 0.1, 5.0, 1.0] {
                    glass.apply([region], in: container, below: content, zoomFactor: zoom)
                    guard let piece = glass.shownPieces.first else { return t.check(false, "native glass") }
                    if let firstPiece { t.check(piece === firstPiece, "a zoom reuses the same native effect view") }
                    else { firstPiece = piece }
                    t.equal(glass.regions, [region], "the published region retains its logical coordinates")
                    t.close(Double(piece.frameView.frame.minX), 10 * zoom)
                    t.close(Double(piece.frameView.frame.minY), 14 * zoom)
                    t.close(Double(piece.frameView.frame.width), 20 * zoom)
                    t.close(Double(piece.frameView.frame.height), 12 * zoom)
                    t.close(Double(piece.glass.frame.minX), -2 * zoom)
                    t.close(Double(piece.glass.frame.minY), -2 * zoom)
                    t.close(Double(piece.glass.frame.width), 40 * zoom)
                    t.close(Double(piece.glass.frame.height), 24 * zoom)
                    t.check(piece.frameView.layer?.masksToBounds == true)
                    if #available(macOS 26.0, *), let effect = piece.glass as? NSGlassEffectView {
                        t.close(Double(effect.cornerRadius), 6 * zoom)
                    } else if let effect = piece.glass as? NSVisualEffectView {
                        t.close(Double(effect.maskImage?.capInsets.top ?? -1), 6 * zoom)
                        t.close(Double(piece.tint?.layer?.cornerRadius ?? -1), 6 * zoom)
                        t.equal(piece.tint?.frame, effect.bounds)
                    } else {
                        t.check(false, "a supported glass view")
                    }
                }
            }
        }
    }

    private static let glassFixture = """
    [Rainmeter]
    Update=-1
    MacGlass=Regular
    MacGlassCornerRadius=12
    [Extent]
    Meter=Image
    W=100
    H=80
    [Clip]
    Meter=Shape
    X=10
    Y=15
    Shape=Rectangle 0,0,20,12 | Fill Color 255,255,255,255 | StrokeWidth 0
    [Card]
    Meter=Image
    X=-2
    Y=-3
    W=40
    H=24
    Container=Clip
    MacGlass=Clear
    MacGlassCornerRadius=6
    MacGlassTint=20,80,160,255
    [Ink]
    Meter=Shape
    Shape=Rectangle 60,40,20,10 | Fill Color 20,80,160,255 | StrokeWidth 0
    """

    /// Unlike the isolated glass-view check above, these exercise the actual runtime-to-controller publication.
    /// The regions never change and there is no update timer to incidentally repair a stale native view.
    private static func glassControllerTests(_ t: AppTestRunner) {
        for threading: SkinThreading in [.main, .engine] {
            for initialPercent in [100, 150] {
                t.suite("App: skin zoom drawing: controller glass lifecycle on \(threading), saved \(initialPercent) percent") {
                    guard let app = try AppSelfTest.makeApp(t, threading: threading) else { return }
                    let config = "ZoomGlass"
                    let directory = app.skinsDirectory.appendingPathComponent(config)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try glassFixture.write(to: directory.appendingPathComponent("Skin.ini"), atomically: true,
                                           encoding: .utf8)
                    app.state.update(config) {
                        $0.file = "Skin.ini"
                        $0.keepOnScreen = false
                        $0.zoomOverridePercent = initialPercent
                    }
                    app.state.saveNow()
                    app.rescanLibrary()
                    guard let c = app.activate(config: config, file: "Skin.ini") else {
                        app.endEngineThread()
                        return t.check(false, "the glass fixture loads")
                    }
                    t.atSuiteEnd {
                        app.stopAllForTermination()
                        t.check(AppSelfTest.spin(timeout: 30) { c.hasClosed }, "the fixture closes on its owner")
                        let thread = app.engineThread
                        app.endEngineThread()
                        if let thread {
                            t.check(AppSelfTest.spin(timeout: 30) { thread.hasExited }, "the test engine thread exits")
                        }
                    }
                    t.check(AppSelfTest.spin(timeout: 30) { c.isStarted || c.loadFailed }, "the fixture starts")
                    guard !c.loadFailed else { return t.check(false, "the fixture loaded successfully") }
                    c.visibilityForTesting = true
                    waitForControllerWork(c, t)
                    let logicalRegions = c.runtime.snapshot.glass
                    let updateCount = c.runtime.snapshot.updateCount
                    t.equal(logicalRegions.map(\.id), [GlassRegion.skinID, "Card"])
                    t.equal(logicalRegions.last?.rect, SkinRect(x: 8, y: 12, width: 40, height: 24),
                            "the content coordinates are relative to its container")
                    t.equal(logicalRegions.last?.clip, SkinRect(x: 10, y: 15, width: 20, height: 12),
                            "the fixture has a real container clip")
                    let pieces = c.glass.shownPieces
                    var checkedPercent: Int?
                    var checkedFrameCount = 0
                    func check(_ percent: Int) {
                        let zoom = Double(percent) / 100
                        let snapshot = c.runtime.snapshot
                        t.equal(snapshot.zoomFactor, zoom)
                        t.equal(snapshot.glass, logicalRegions, "zoom leaves logical glass regions unchanged")
                        t.equal(snapshot.updateCount, updateCount, "no periodic update is needed to apply zoom")
                        t.equal(c.window.frame.size, CGSize(width: 100 * zoom, height: 80 * zoom))
                        t.equal(c.contentView.bounds.size, c.window.frame.size)
                        let scale = c.window.backingScaleFactor
                        let width = Int((c.window.frame.width * scale).rounded(.up))
                        let height = Int((c.window.frame.height * scale).rounded(.up))
                        t.check(AppSelfTest.spin(timeout: 10) {
                            guard let image = c.content.shown.image else { return false }
                            return image.width == width && image.height == height
                                && (checkedPercent == percent || c.content.state.presented > checkedFrameCount)
                        }, "the normal frame producer presents the new zoom without a manual redraw")
                        let shown = c.content.shown
                        if let image = shown.image {
                            t.equal(image.width, width, "the content bitmap follows the window width")
                            t.equal(image.height, height, "the content bitmap follows the window height")
                            t.equal(shown.scale, scale, "only backing scale is applied to the displayed bitmap")
                            t.equal(shown.bounds.size, CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
                            t.equal(shown.bounds.size, c.window.frame.size, "glass, window and content cover the same points")
                            let space = image.colorSpace ?? SkinFrameProducer.sRGB
                            let screenshot: CGContext? = c.runtime.exclusive(timeout: 30) { skin in
                                snapshotDrawing(skin, width: width, height: height, scale: scale, space: space)
                            } ?? nil
                            if let screenshot, let difference = SkinBitmapDrawing.difference(image, screenshot) {
                                t.check(difference.worst <= SkinBitmapDrawing.tolerance,
                                        "presented content and full snapshot differ by \(difference.worst) at \(percent)%")
                            } else {
                                t.check(false, "the controller frame can be compared with a full snapshot")
                            }
                        } else {
                            t.check(false, "the controller has presented content")
                        }
                        checkedPercent = percent
                        checkedFrameCount = c.content.state.presented
                        t.equal(c.glass.regions, logicalRegions)
                        t.equal(c.glass.shownPieces.count, logicalRegions.count)
                        for (index, region) in logicalRegions.enumerated() {
                            guard index < c.glass.shownPieces.count else { continue }
                            let piece = c.glass.shownPieces[index]
                            if index < pieces.count { t.check(piece === pieces[index], "the same native view follows the new zoom") }
                            let frame = region.clip ?? region.rect
                            t.close(Double(piece.frameView.frame.minX), frame.x * zoom, "\(region.id) clip x at \(percent)%")
                            t.close(Double(piece.frameView.frame.minY), frame.y * zoom, "\(region.id) clip y at \(percent)%")
                            t.close(Double(piece.frameView.frame.width), frame.width * zoom, "\(region.id) width at \(percent)%")
                            t.close(Double(piece.frameView.frame.height), frame.height * zoom, "\(region.id) height at \(percent)%")
                            t.close(Double(piece.glass.frame.minX), (region.rect.x - frame.x) * zoom)
                            t.close(Double(piece.glass.frame.minY), (region.rect.y - frame.y) * zoom)
                            t.close(Double(piece.glass.frame.width), region.rect.width * zoom)
                            t.close(Double(piece.glass.frame.height), region.rect.height * zoom)
                            t.equal(piece.frameView.layer?.masksToBounds, region.clip != nil)
                            if #available(macOS 26.0, *), let effect = piece.glass as? NSGlassEffectView {
                                t.close(Double(effect.cornerRadius), region.cornerRadius * zoom)
                            } else if let effect = piece.glass as? NSVisualEffectView {
                                t.close(Double(effect.maskImage?.capInsets.top ?? -1), region.cornerRadius * zoom)
                            } else {
                                t.check(false, "a supported native glass view")
                            }
                        }
                    }
                    check(initialPercent)
                    for percent in [100, 150, 200, 100] {
                        var completed = false
                        c.requestZoom(percent: percent) { completed = true }
                        waitForControllerWork(c, t)
                        t.check(completed, "the zoom request has been acknowledged")
                        check(percent)
                    }
                    if initialPercent == 100 {
                        c.requestZoom(percent: nil)
                        waitForControllerWork(c, t)
                        app.setDefaultZoom(percent: 150, force: false)
                        waitForControllerWork(c, t)
                        check(150)
                        c.requestZoom(percent: 200)
                        waitForControllerWork(c, t)
                        app.setDefaultZoom(percent: 125, force: true)
                        waitForControllerWork(c, t)
                        check(125)
                    }
                }
            }
        }
    }

    private static func waitForControllerWork(_ c: SkinWindowController, _ t: AppTestRunner) {
        var caughtUp = false
        c.runtime.whenCaughtUp { caughtUp = true }
        t.check(AppSelfTest.spin(timeout: 30) { caughtUp }, "runtime work and its queued main-thread requests finish")
    }
}
