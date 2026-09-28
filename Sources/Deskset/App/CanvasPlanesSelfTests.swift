import AppKit
import DesksetCore

/// "App: canvas planes": the canvas is drawn in three planes (`CanvasPlanes`) — pointing at a layer or selecting one
/// draws the overlay only, the widget updating draws the content and the overlay, and the workbench is drawn again
/// only for a zoom, size, backdrop or appearance change — and an off-screen picture of the planes is the one drawing
/// of the canvas, pixel for pixel.
enum CanvasPlanesSelfTests {
    static func run(_ t: AppTestRunner) {
        planeTests(t)
    }

    static let widget = """
        [Rainmeter]
        Update=1000

        [MeasureCount]
        Measure=Calc
        Formula=Counter % 10
        MaxValue=10

        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,220,120,10 | Fill Color 30,30,40,230 | StrokeWidth 0

        [MeterTitle]
        Meter=String
        Text=Planes
        X=12
        Y=10
        FontSize=16
        FontColor=255,255,255
        AntiAlias=1

        [MeterValue]
        Meter=String
        MeasureName=MeasureCount
        X=12
        Y=44
        FontSize=12
        FontColor=200,220,255
        AntiAlias=1

        [MeterBar]
        Meter=Bar
        MeasureName=MeasureCount
        X=12
        Y=80
        W=190
        H=10
        BarColor=120,200,255
        SolidColor=255,255,255,40
        BarOrientation=Horizontal

        """

    static func planeTests(_ t: AppTestRunner) {
        t.suite("App: canvas planes: hover and selection draw the overlay only") {
            guard let (_, editor, _) = try StudioReviewSelfTests.openSkin(t, "Planes", widget) else { return }
            let canvas = editor.canvas
            let planes = canvas.planes
            editor.window?.layoutIfNeeded()
            /// The display pass: each plane's layer draws when it was asked to (a window on screen does this at the end
            /// of every turn; the self-tests' windows are never on screen).
            func display() { for plane in planes.all { plane.layer?.displayIfNeeded() } }
            func asked(_ plane: CanvasPlane) -> Bool { plane.layer?.needsDisplay() ?? false }
            // The first display pass gives the views their layers.
            editor.window?.displayIfNeeded()
            display()

            // Three planes at the bottom of the canvas, bottom to top, filling it and taking no clicks.
            t.check(canvas.subviews.count >= 3 && canvas.subviews[0] === planes.workbench
                    && canvas.subviews[1] === planes.content && canvas.subviews[2] === planes.overlay,
                    "the planes are the canvas's first subviews, in order")
            t.check(planes.all.allSatisfy { $0.layer != nil }, "each plane has its own layer")
            for plane in planes.all { t.equal(plane.frame, canvas.bounds, "\(plane.kind) fills the canvas") }
            guard let title = editor.skin?.meter(named: "MeterTitle") else { return t.check(false, "the title") }
            let inside = canvas.viewRect(title.frame)
            if let superview = canvas.superview {
                t.check(canvas.hitTest(canvas.convert(NSPoint(x: inside.midX, y: inside.midY), to: superview)) === canvas,
                        "a click on a layer reaches the canvas")
            }

            // The pointer over a layer, then off it.
            let start = planes.drawCounts
            canvas.simulateHover("MeterTitle")
            t.check(!asked(planes.content), "hover leaves the content plane alone")
            t.check(!asked(planes.workbench), "and the workbench")
            t.check(asked(planes.overlay), "the overlay draws the hover")
            display()
            var now = planes.drawCounts
            t.equal(now.content, start.content, "no content draw on hover")
            t.equal(now.workbench, start.workbench, "no workbench draw on hover")
            t.equal(now.overlay, start.overlay + 1, "one overlay draw")
            canvas.simulateHover(nil)
            display()
            t.equal(planes.drawCounts.content, start.content, "none when the pointer leaves")

            // A click selects the layer (the whole editor follows: layers, inspector, code), then others and none.
            let before = planes.drawCounts
            canvas.click(skinX: title.frame.x + 2, y: title.frame.y + 2)
            t.equal(canvas.selectedNames, ["MeterTitle"], "selected by a click")
            t.check(!asked(planes.content), "a selection leaves the content plane alone")
            display()
            now = planes.drawCounts
            t.equal(now.content, before.content, "no content draw on a selection by click")
            t.equal(now.workbench, before.workbench, "no workbench draw on a selection")
            t.check(now.overlay > before.overlay, "the overlay drew the selection")
            editor.select(section: "MeterValue")
            t.equal(canvas.selectedNames, ["MeterValue"], "selected from the layer list")
            display()
            t.equal(planes.drawCounts.content, before.content, "none on a selection from the layer list")
            canvas.click(skinX: -40, y: -40)
            t.equal(canvas.selectedNames, [], "a click on the work surface selects the widget")
            display()
            t.equal(planes.drawCounts.content, before.content, "none when nothing is selected")

            // A row of the layer list pointed at: its layer outlined, the rest veiled — the overlay again.
            editor.setListHoverHighlight(["MeterBar"])
            t.check(!asked(planes.content), "a layer-list row under the pointer leaves the content plane alone")
            display()
            editor.setListHoverHighlight([])
            display()
            t.equal(planes.drawCounts.content, before.content, "none for a layer-list row under the pointer")

            // The widget updating draws the content and the overlay (a selection follows its layer), not the workbench.
            let ticked = planes.drawCounts
            canvas.needsDisplay = true
            t.check(asked(planes.content) && asked(planes.overlay), "an update asks the content and the overlay")
            t.check(!asked(planes.workbench), "not the workbench")
            display()
            now = planes.drawCounts
            t.equal(now.content, ticked.content + 1, "an update draws the content once")
            t.equal(now.overlay, ticked.overlay + 1, "and the overlay")
            t.equal(now.workbench, ticked.workbench, "not the workbench")

            // The canvas timer (the widget's update rate): the content draws again; the overlay only when what it reads
            // from the widget moved — a selected layer that grew, a layer that showed.
            editor.select(section: "MeterValue")
            display()
            let idle = planes.drawCounts
            canvas.widgetUpdated()
            t.check(asked(planes.content), "a tick draws the content")
            t.check(!asked(planes.overlay), "not the overlay, when nothing it outlines moved")
            t.check(!asked(planes.workbench), "nor the workbench")
            display()
            now = planes.drawCounts
            t.equal(now.content, idle.content + 1)
            t.equal(now.overlay, idle.overlay, "no overlay draw for a tick that moved nothing")
            guard let skin = editor.skin, let value = skin.meter(named: "MeterValue") else { return t.check(false, "value") }
            skin.execute("[!SetOption MeterValue FontSize 30][!UpdateMeter MeterValue]", from: nil)
            skin.layout()
            t.check(skin.meter(named: "MeterValue") === value)
            canvas.widgetUpdated()
            t.check(asked(planes.overlay), "a tick after the selected layer grew draws the overlay too")
            display()
            t.equal(planes.drawCounts.overlay, idle.overlay + 1)
            canvas.widgetUpdated()
            t.check(!asked(planes.overlay), "and the next one does not")
            skin.execute("[!HideMeter MeterBar]", from: nil)
            canvas.widgetUpdated()
            t.check(asked(planes.overlay), "a layer hidden by the widget draws the overlay")
            skin.execute("[!ShowMeter MeterBar][!SetOption MeterValue FontSize 12][!UpdateMeter MeterValue]", from: nil)
            skin.layout()
            display()
            canvas.click(skinX: -40, y: -40)
            display()

            // Fitting a fitted canvas again (the editor fits after every step) leaves the planes alone.
            canvas.zoomToFit()
            display()
            let fitted = (zoom: canvas.zoom, origin: canvas.enclosingScrollView?.contentView.bounds.origin)
            canvas.zoomToFit()
            t.check(!asked(planes.workbench) && !asked(planes.content) && !asked(planes.overlay),
                    "fitting a fitted canvas again asks no plane to draw")
            t.equal(canvas.zoom, fitted.zoom)
            t.equal(canvas.enclosingScrollView?.contentView.bounds.origin, fitted.origin, "and leaves it where it was")

            // The workbench: a backdrop, a zoom, a size or an appearance change draws it again.
            let backdrop = canvas.backdrop
            canvas.backdrop = backdrop == .dark ? .light : .dark
            t.check(asked(planes.workbench), "a backdrop change draws the workbench")
            display()
            canvas.backdrop = backdrop
            display()
            let zoom = canvas.zoom
            canvas.setZoom(zoom * 2)
            t.check(asked(planes.workbench), "a zoom draws the workbench")
            display()
            canvas.setZoom(zoom)
            display()
            canvas.appearance = NSAppearance(named: canvas.workbenchState.dark ? .aqua : .darkAqua)
            canvas.needsDisplay = true
            t.check(asked(planes.workbench), "an appearance change draws the workbench")
            canvas.appearance = nil
            canvas.needsDisplay = true
            display()
            let size = canvas.frame.size
            canvas.setFrameSize(NSSize(width: size.width + 10, height: size.height))
            t.equal(planes.workbench.frame, canvas.bounds, "the planes follow the canvas's size exactly")
            canvas.needsDisplay = true
            t.check(asked(planes.workbench), "a size change draws the workbench")
            canvas.updateSize()
            display()
            editor.window?.close()
        }

        t.suite("App: canvas planes: an off-screen picture of the planes is the one drawing of the canvas") {
            guard let (_, editor, _) = try StudioReviewSelfTests.openSkin(t, "PlanesPixels", widget) else { return }
            let canvas = editor.canvas
            editor.window?.layoutIfNeeded()
            for look in [NSAppearance.Name.aqua, .darkAqua] {
                canvas.appearance = NSAppearance(named: look)
                for select in [[], ["MeterTitle"], ["MeterTitle", "MeterBar"]] {
                    editor.canvasSelectionChanged(select)
                    canvas.setSelection(names: select)
                    canvas.simulateHover(select.isEmpty ? "MeterValue" : nil)
                    for zoom in [canvas.zoom, 3] {
                        canvas.setZoom(zoom)
                        let planes = FriendlyCanvasSelfTests.render(canvas)
                        canvas.planes.drawsInOne = true
                        let one = FriendlyCanvasSelfTests.render(canvas)
                        canvas.planes.drawsInOne = false
                        guard let planes, let one else { return t.check(false, "rendered") }
                        t.check(same(planes.rep, one.rep),
                                "\(look.rawValue), \(select), \(zoom)×: the planes compose the one drawing's pixels")
                    }
                }
            }
            canvas.appearance = nil
            editor.window?.close()
        }
    }

    /// Whether two pictures have the same size and bytes.
    static func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
              let x = a.bitmapData, let y = b.bitmapData else { return false }
        return memcmp(x, y, a.bytesPerRow * a.pixelsHigh) == 0
    }
}
