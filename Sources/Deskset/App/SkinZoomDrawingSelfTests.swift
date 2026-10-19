import AppKit
import DesksetCore

/// Desktop zoom is applied to drawing commands, window geometry and native glass at the same logical scale.
enum SkinZoomDrawingSelfTests {
    static func run(_ t: AppTestRunner) {
        frameTests(t)
        cacheTests(t)
        glassTests(t)
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

    private static func snapshotDrawing(_ skin: Skin, width: Int, height: Int, scale: CGFloat) -> CGContext? {
        guard let context = SkinBitmapDrawing.makeContext(width, height, SkinFrameProducer.sRGB) else { return nil }
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
}
