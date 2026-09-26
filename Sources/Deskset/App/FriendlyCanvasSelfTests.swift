import AppKit
import DesksetCore

/// `Deskset --self-test "Friendly canvas"`: the canvas and window of docs/editor-friendly.md §4 and §9 (WP-D) —
/// selection levels, hover, overflow (ghost, growing, Fit Widget to Content), editing text in place, followers,
/// placeholders, tips, toasts with buttons, the toolbar.
enum FriendlyCanvasSelfTests {
    static func run(_ t: AppTestRunner) {
        seamTests(t)
        selectionTests(t)
        hoverTests(t)
        growthTests(t)
        componentGrowthTests(t)
        cutOffTests(t)
        overlayPlacementTests(t)
        fixedSizeTests(t)
        inlineTextTests(t)
        followerTests(t)
        placementTests(t)
        placeholderTests(t)
        silentDataTests(t)
        tipTests(t)
        chromeTests(t)
        snapshotOptionTests(t)
    }

    typealias Editor = InspectorWindowController

    /// The 16 bars of the Visualizer: one run of repeated layers.
    static let bands = (0..<16).map { "MeterBand\($0)" }

    /// The Visualizer (a temporary copy) in an open editor, with its helpers.
    struct Visualizer {
        let app: AppController
        let editor: Editor
        var canvas: SkinCanvasView { editor.canvas }
        var skin: Skin? { app.controller(for: "Audio\\Visualizer")?.skin }
        var file: URL? { skin?.fileURL }
        func text() -> String { file.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" } ?? "" }
        func frame(_ name: String) -> SkinRect { skin?.meter(named: name)?.frame ?? SkinRect() }
        /// A point of a layer in view coordinates.
        func point(_ name: String, dx: Double = 0, dy: Double = 0) -> NSPoint {
            let f = frame(name)
            return NSPoint(x: canvas.origin.x + CGFloat(f.x + f.width / 2 + dx), y: canvas.origin.y + CGFloat(f.y + f.height / 2 + dy))
        }

        /// The 16 bars are a run (the sidebar's `LayerSeries` finds them; before it does, the test says so itself).
        func useBandRun() {
            if canvas.groups.isEmpty { canvas.groups = [FriendlyCanvasSelfTests.bands] }
        }

        /// The Background locked (the editor locks the detected Background by itself; the user's lock otherwise).
        func lockBackground() {
            guard !editor.isLockedOnCanvas("MeterBackground") else { return }
            app.state.updateEditor { $0.editorLocks["audio\\visualizer", default: []].insert("meterbackground") }
        }

        /// Drags a layer by (dx, dy) points without ending the gesture.
        func beginDrag(_ name: String, dx: Double, dy: Double) {
            if canvas.selectedNames != [name] { editor.canvasSelectionChanged([name]) }
            let start = point(name)
            canvas.beginGesture(.move, at: start)
            canvas.drag(to: NSPoint(x: start.x + CGFloat(dx), y: start.y + CGFloat(dy)), snapping: false)
        }
    }

    static func openVisualizer(_ t: AppTestRunner) throws -> Visualizer? {
        guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return nil }
        return Visualizer(app: app, editor: editor)
    }

    /// Ends the current event: the undo manager groups what one event registers (as in the app).
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    /// The canvas drawn off-screen, with its pixel scale.
    static func render(_ view: NSView) -> (rep: NSBitmapImageRep, scale: CGFloat)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / max(view.bounds.width, 1))
    }

    /// The brightest pixel of a rectangle (view coordinates) of a rendering: 0…1.
    static func brightest(_ r: (rep: NSBitmapImageRep, scale: CGFloat), in rect: CGRect) -> CGFloat {
        var best: CGFloat = 0
        let x0 = max(Int(rect.minX * r.scale), 0), x1 = min(Int(rect.maxX * r.scale), r.rep.pixelsWide - 1)
        let y0 = max(Int(rect.minY * r.scale), 0), y1 = min(Int(rect.maxY * r.scale), r.rep.pixelsHigh - 1)
        guard x0 <= x1, y0 <= y1 else { return 0 }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = r.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                best = max(best, 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
        }
        return best
    }

    /// How many pixels of a rectangle (view coordinates) of a rendering are the orange of the cut-off marks.
    static func orangePixels(_ r: (rep: NSBitmapImageRep, scale: CGFloat), in rect: CGRect) -> Int {
        var n = 0
        let x0 = max(Int(rect.minX * r.scale), 0), x1 = min(Int(rect.maxX * r.scale), r.rep.pixelsWide - 1)
        let y0 = max(Int(rect.minY * r.scale), 0), y1 = min(Int(rect.maxY * r.scale), r.rep.pixelsHigh - 1)
        guard x0 <= x1, y0 <= y1 else { return 0 }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = r.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Orange's hue, however faint the line is drawn (a thin line at a small scale blends with the surface).
                let (r0, g0, b0) = (c.redComponent, c.greenComponent, c.blueComponent)
                if r0 - b0 > 0.25, r0 >= g0, g0 >= b0, g0 - b0 > 0.1 { n += 1 }
            }
        }
        return n
    }

    /// A mouse event at a point of the canvas (view coordinates).
    static func mouse(_ type: NSEvent.EventType, _ canvas: SkinCanvasView, at p: NSPoint, clicks: Int = 1,
                      flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)
    }

    // MARK: Step 0 seams

    /// The seams the canvas work is built on (step 0 of the friendly studio).
    static func seamTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: snapshot options from the command line") {
            let parsed = SnapshotOptions.parse(["Deskset", "--snapshot-ui", "inspector", "--hover", "MeterBand5",
                                                "--drag", "MeterTitle:-30,0.5", "--expert", "--tip", "1",
                                                "--expand", "MeterBand0", "--edit-text", "MeterTitle",
                                                "--scroll", "ON YOUR DESKTOP"])
            var expected = SnapshotOptions()
            expected.hover = "MeterBand5"
            expected.drag = .init(name: "MeterTitle", dx: -30, dy: 0.5)
            expected.expert = true
            expected.tip = 1
            expected.expand = "MeterBand0"
            expected.editText = "MeterTitle"
            expected.scroll = "ON YOUR DESKTOP"
            t.equal(try parsed.get(), expected)
            t.equal(try SnapshotOptions.parse(["Deskset"]).get(), SnapshotOptions())
            for bad in [["--drag", "MeterTitle"], ["--drag", "MeterTitle:1"], ["--drag", ":1,2"], ["--tip", "4"], ["--tip"]] {
                if case .success = SnapshotOptions.parse(["Deskset"] + bad) { t.check(false, "\(bad) is refused") }
            }
            t.equal(SnapshotOptions.drag("Group:A:5,-6"), .init(name: "Group:A", dx: 5, dy: -6))
            t.equal(["add", "library", "Layers", "live", "data", "other"].map(UISnapshot.sidebarTab(named:)),
                    [.library, .library, .layers, .data, .data, nil])
            for flag in ["--hover", "--drag", "--tip", "--expand", "--edit-text", "--scroll"] {
                t.equal(CommandLineTools.validate(["Deskset", "--snapshot-ui", "inspector", flag, "X"]), .mode, flag)
            }
            t.equal(CommandLineTools.validate(["Deskset", "--snapshot-ui", "inspector", "--expert"]), .mode)
        }

        t.suite("App: friendly canvas: hover, overlays and toast actions") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            var reported: [String?] = []
            let sidebar = editor.canvas.onHoverChange
            editor.canvas.onHoverChange = { reported.append($0) }
            var options = SnapshotOptions()
            options.hover = "metertitle"
            editor.applySnapshotCanvasOptions(options)
            t.equal(editor.canvas.hover, "MeterTitle", "the pointer is over the layer")
            t.equal(reported, ["MeterTitle"], "and the sidebar hears of it")
            editor.canvas.onHoverChange = sidebar

            // Overlays are drawn into the snapshot, over the panes.
            guard let content = editor.window?.contentView else { return t.check(false, "window") }
            for view in editor.overlayViews { view.isHidden = true }
            func magentaPixels() -> Int {
                guard let rep = editor.snapshot() else { return -1 }
                var n = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if c.redComponent > 0.95, c.greenComponent < 0.05, c.blueComponent > 0.95 { n += 1 }
                    }
                }
                return n
            }
            t.equal(magentaPixels(), 0)
            let overlay = SolidOverlay(frame: NSRect(x: content.bounds.midX - 30, y: content.bounds.midY - 30, width: 60, height: 60))
            content.addSubview(overlay)
            let before = editor.overlayViews
            editor.overlayViews = [overlay]
            t.check(magentaPixels() > 0, "the overlay shows in the snapshot")
            overlay.isHidden = true
            t.equal(magentaPixels(), 0, "a hidden overlay does not")
            editor.overlayViews = before
            overlay.removeFromSuperview()

            var undone = false
            editor.toast.show("Hid “Audio”", actions: [ToastAction("Undo") { undone = true }])
            t.equal(editor.toastText, "Hid “Audio”")
            t.check(!undone, "nothing runs by itself")
            editor.toast.button("Undo")?.performClick(nil)
            t.check(undone, "the button runs its action")

            // A toast that is gone leaves no invisible buttons over the canvas: they stop working when it hides, and
            // clicks pass through it.
            var ran = false
            editor.toast.show("Moved “Audio”", actions: [ToastAction("Undo") { ran = true }])
            content.layoutSubtreeIfNeeded()
            guard let undo = editor.toast.button("Undo"), let parent = editor.toast.superview else {
                return t.check(false, "the toast's button")
            }
            let point = undo.convert(NSPoint(x: undo.bounds.midX, y: undo.bounds.midY), to: parent)
            let hit = editor.toast.hitTest(point)
            t.check(hit === undo || hit?.isDescendant(of: undo) == true, "a showing toast's button takes the click")
            editor.toast.hide()
            t.check(editor.toast.hitTest(point) == nil, "a hidden toast takes no clicks")
            undo.performClick(nil)
            t.check(!ran, "its buttons do nothing any more")
            t.check(editor.toast.button("Undo") == nil)
            editor.toast.show("Moved “Audio”", actions: [ToastAction("Undo") { ran = true }])
            editor.toast.button("Undo")?.performClick(nil)
            t.check(ran, "the next toast's buttons work")
        }
    }

    /// A plain magenta square.
    final class SolidOverlay: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
            bounds.fill()
        }
    }

    // MARK: Selection levels (§9.2)

    static func selectionTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: selection levels") {
            guard let v = try openVisualizer(t) else { return }
            v.useBandRun()
            v.lockBackground()
            let canvas = v.canvas, editor = v.editor
            func click(_ name: String, command: Bool = false) {
                let f = v.frame(name)
                canvas.click(skinX: f.x + f.width / 2, y: f.y + f.height / 2, command: command)
            }
            func doubleClick(_ name: String) {
                let f = v.frame(name)
                canvas.doubleClick(skinX: f.x + f.width / 2, y: f.y + f.height / 2)
            }

            click("MeterBand3")
            t.equal(canvas.selectedNames, bands, "the first click selects the whole run")
            t.equal(editor.selectedMeters, bands, "and the inspector shows it")
            t.equal(canvas.selectedGroup, bands)
            click("MeterBand9")
            t.equal(canvas.selectedNames, bands, "another bar of the run keeps the run")
            doubleClick("MeterBand3")
            t.equal(canvas.selectedNames, ["MeterBand3"], "a double-click enters the run")
            t.equal(editor.selectedSection, "MeterBand3")
            t.equal(canvas.enteredGroup, bands)
            click("MeterBand7")
            t.equal(canvas.selectedNames, ["MeterBand7"], "clicks stay inside the run")
            canvas.cancelOperation(nil)
            t.equal(canvas.selectedNames, bands, "Esc: up to the run")
            canvas.cancelOperation(nil)
            t.equal(canvas.selectedNames, [], "Esc: up to the widget")
            t.equal(editor.selectedSection, nil, "the widget page")

            // A click outside leaves the run; ⌘-click picks a bar directly.
            doubleClick("MeterBand3")
            click("MeterTitle")
            t.equal(canvas.selectedNames, ["MeterTitle"])
            t.equal(canvas.enteredGroup, nil, "clicking outside the run leaves it")
            click("MeterBand3")
            t.equal(canvas.selectedNames, bands)
            click("MeterBand5", command: true)
            t.equal(canvas.selectedNames, ["MeterBand5"], "⌘-click selects the bar itself")
            // Esc from a bar selected any other way (its row) goes to its run too.
            editor.select(section: "MeterBand2")
            canvas.cancelOperation(nil)
            t.equal(canvas.selectedNames, bands)

            // The Background is locked: a click on its empty area selects the widget, and a drag there draws a box.
            guard let skin = v.skin else { return t.check(false, "skin") }
            t.check(editor.isLockedOnCanvas("MeterBackground"), "the Background is locked")
            t.equal(canvas.pickableMeter(atSkinX: 4, 190)?.name, nil, "clicks pass through it")
            canvas.click(skinX: 4, y: 190)
            t.equal(canvas.selectedNames, [])
            let empty = NSPoint(x: canvas.origin.x + 4, y: canvas.origin.y + 190)
            if let down = mouse(.leftMouseDown, canvas, at: empty),
               let drag = mouse(.leftMouseDragged, canvas, at: NSPoint(x: empty.x + 30, y: empty.y - 40)),
               let up = mouse(.leftMouseUp, canvas, at: NSPoint(x: empty.x + 30, y: empty.y - 40)) {
                canvas.mouseDown(with: down)
                canvas.mouseDragged(with: drag)
                t.check(canvas.marquee != nil, "a drag on the locked Background draws a selection box")
                t.check(!canvas.selectedNames.contains("MeterBackground"), "which skips the locked layer")
                t.check(canvas.selectedNames.contains("MeterLeftLabel"), "and takes the layers it touches")
                canvas.mouseUp(with: up)
            }
            // Still reachable: ⌘A, right-click ▸ Select ▸ and its row.
            canvas.selectAll()
            t.check(canvas.selectedNames.contains("MeterBackground"), "⌘A includes locked layers")
            editor.select(section: "MeterBackground")
            t.equal(canvas.selectedNames, ["MeterBackground"])
            // The detected Background is locked by itself, unless the user unlocked it.
            if let background = LayerNaming.background(in: skin) {
                v.app.state.updateEditor { $0.editorLocks = [:] }
                t.check(editor.isLockedOnCanvas(background), "the detected Background is locked by itself")
                v.app.state.updateEditor { $0.unlockedBackgrounds.insert("audio\\visualizer") }
                t.check(!editor.isLockedOnCanvas(background), "unless it was unlocked")
            }

            // A real double-click (two presses) goes the same way.
            canvas.click(skinX: 4, y: 190)
            let bar = v.point("MeterBand4")
            for clicks in [1, 2] {
                guard let down = mouse(.leftMouseDown, canvas, at: bar, clicks: clicks),
                      let up = mouse(.leftMouseUp, canvas, at: bar, clicks: clicks) else { continue }
                canvas.mouseDown(with: down)
                canvas.mouseUp(with: up)
            }
            t.equal(canvas.selectedNames, ["MeterBand4"], "double-clicking a bar enters the run")
        }
    }

    // MARK: Hover, tags, veil (§9.1, §9.3, §5.2)

    static func hoverTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: hover, tags and the veil") {
            guard let v = try openVisualizer(t) else { return }
            v.useBandRun()
            v.lockBackground()
            let canvas = v.canvas
            var reported: [String?] = []
            canvas.onHoverChange = { reported.append($0) }
            canvas.simulateHover("MeterBand5")
            t.equal(canvas.hover, "MeterBand5")
            t.equal(canvas.clickTarget("MeterBand5"), bands, "a bar of a run not entered outlines the run")
            t.equal(canvas.groupName(bands), "16 bars", "tagged with its name")
            canvas.simulateHover(nil)
            t.equal(reported, ["MeterBand5", nil], "the sidebar hears of every change")
            t.equal(canvas.meter(atViewPoint: NSPoint(x: canvas.origin.x + 4, y: canvas.origin.y + 190))?.name, nil,
                    "a locked layer is never under the pointer")

            // The selection tag sits outside the layer: above it, else below, else beside.
            let size = CGSize(width: 90, height: 19)
            canvas.scrollToVisible(canvas.bounds)
            let visible = canvas.visibleRect
            let middle = CGRect(x: visible.midX - 5, y: visible.midY - 5, width: 10, height: 10)
            let z = canvas.zoom
            t.check(canvas.tagRect(size: size, near: middle, leading: false, zoom: z).maxY <= middle.minY, "above")
            let top = CGRect(x: visible.midX - 5, y: visible.minY + 1 / z, width: 10, height: 10)
            t.check(canvas.tagRect(size: size, near: top, leading: false, zoom: z).minY >= top.maxY, "below at the top")
            let tall = CGRect(x: visible.minX + 20, y: visible.minY, width: 10, height: visible.height)
            let beside = canvas.tagRect(size: size, near: tall, leading: false, zoom: z)
            t.check(!beside.intersects(tall), "beside a layer as tall as the view")

            // A row pointed at in the sidebar: the rest of the widget is veiled at 30%.
            let probe = CGRect(x: canvas.origin.x + 150, y: canvas.origin.y + 60, width: 1, height: 1)
            guard let plain = render(canvas) else { return t.check(false, "render") }
            canvas.hoverHighlight = ["MeterTitle"]
            guard let veiled = render(canvas) else { return t.check(false, "render") }
            let title = canvas.viewRect(v.frame("MeterTitle"))
            t.check(brightest(veiled, in: probe) < brightest(plain, in: probe) - 0.01, "the rest of the widget is veiled")
            t.check(brightest(veiled, in: title.insetBy(dx: 2, dy: 2)) > 0.8, "the pointed-at layer is not")
            canvas.hoverHighlight = []
        }
    }

    // MARK: Growing to the right and bottom (§9.10)

    static func growthTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: the widget grows while a layer is dragged past its right edge") {
            guard let v = try openVisualizer(t) else { return }
            v.lockBackground()
            let canvas = v.canvas
            canvas.backdrop = .dark
            guard let width = v.skin?.width, let height = v.skin?.height else { return t.check(false, "skin") }
            t.equal(width, 217)
            let title = v.frame("MeterTitle")
            let bytes = v.text()
            // 60 points past the right edge.
            let dx = width + 60 - title.maxX
            v.beginDrag("MeterTitle", dx: dx, dy: 0)
            let grownWidth = title.maxX + dx
            t.close(canvas.skinRect.width, CGFloat(grownWidth), accuracy: 0.5, "the card grows live")
            t.equal(canvas.growthBadge, "217 × 196 → \(SkinCanvasView.format(grownWidth)) × 196")
            t.check(!canvas.isDraggingPastEdge, "nothing is cut off")
            t.check(canvas.frame.width >= canvas.origin.x + canvas.skinRect.width, "the canvas holds the grown card")
            // Past the old width the title is drawn at full strength (inside the card, not ghosted).
            let moved = canvas.viewRect(v.frame("MeterTitle"))
            t.check(moved.minX > canvas.origin.x + CGFloat(width), "the title is past the old edge")
            if let r = render(canvas) {
                t.check(brightest(r, in: moved) > 0.75, "drawn at full strength: \(brightest(r, in: moved))")
            }
            // Esc: nothing written, the widget as it was.
            canvas.cancelOperation(nil)
            t.equal(canvas.skinRect.width, 217, "Esc restores the size")
            t.equal(canvas.growthBadge, nil)
            t.equal(v.frame("MeterTitle"), title)
            t.equal(v.text(), bytes, "and writes nothing")

            // Dropped: written, and the widget keeps its new size after the refresh.
            v.beginDrag("MeterTitle", dx: dx, dy: 0)
            canvas.endGesture(keep: true)
            t.equal(v.skin?.width, grownWidth, "the refreshed widget has grown")
            t.equal(v.skin?.height, height)
            t.equal(canvas.skinRect.width, CGFloat(grownWidth))
            t.equal(v.editor.toastText, "Widget grew to \(EditorStyle.number(grownWidth)) × 196")
            // The Background it had no longer covers it (§9.10: the toast offers to stretch it).
            t.equal(v.editor.toast.buttons.map(\.title), ["Stretch Background", "Undo"])
            settle()

            // Stretch Background: the Background's own size, a variable offset in place, the variable unchanged.
            v.editor.stretchBackground("MeterBackground")
            let shape = StudioReviewSelfTests.section("MeterBackground", in: v.text())
            t.check(shape.contains("Shape=Rectangle 0,0,(#Width# + \(EditorStyle.number(grownWidth - 217))),196,10 | Fill Color 16,19,28,235 | StrokeWidth 0"),
                    shape)
            t.check(v.text().contains("Width=(14*2 + 16*9 + 15*3)\n"), "the shared value is never changed")
            t.equal(v.frame("MeterBackground").width, grownWidth, "the Background covers the widget again")
            t.equal(v.editor.window?.undoManager?.undoActionName, "Stretch Background")
            t.check(!(v.skin.map { v.editor.backgroundNeedsStretching(in: $0) } ?? true), "nothing left to stretch")
            settle()
            v.editor.window?.undoManager?.undo()
            t.check(StudioReviewSelfTests.section("MeterBackground", in: v.text()).contains("Rectangle 0,0,#Width#,196,10"),
                    "one undo step")
            t.equal(v.editor.toastText, "Undid Stretch Background")
            t.equal(v.editor.toast.buttons.map(\.title), ["Redo"])
        }

        t.suite("App: friendly canvas: content outside the widget is ghosted") {
            guard let v = try openVisualizer(t) else { return }
            v.lockBackground()
            let canvas = v.canvas
            canvas.appearance = NSAppearance(named: .darkAqua)
            v.beginDrag("MeterTitle", dx: -80, dy: 0)
            t.check(canvas.isDraggingPastEdge, "“Cut off on the desktop” while dragged past the left edge")
            t.equal(canvas.growthBadge, nil, "the widget does not grow to the left")
            canvas.cancelOperation(nil)
            t.check(!canvas.isDraggingPastEdge)

            // A layer written past the left edge, nothing selected: only the ghost is drawn there.
            guard let file = v.file else { return t.check(false, "skin") }
            try v.text().replacingOccurrences(of: "[MeterTitle]\nMeter=String\nX=#Left#", with: "[MeterTitle]\nMeter=String\nX=-80")
                .write(to: file, atomically: true, encoding: .utf8)
            v.editor.refreshSkin()
            v.editor.canvasSelectionChanged([])
            t.equal(v.frame("MeterTitle").x, -80)
            t.close(canvas.origin.x, SkinCanvasView.margin + 80, accuracy: 0.5, "the canvas makes room on the left")
            let past = canvas.viewRect(v.frame("MeterTitle"))
            t.check(past.maxX < canvas.origin.x, "the title is left of the widget")
            guard let ghost = render(canvas) else { return t.check(false, "render") }
            let faint = brightest(ghost, in: past.insetBy(dx: 2, dy: 2))
            t.check(faint > 0.2 && faint < 0.6, "drawn at 35%: \(faint)")
            // Light words on the light work surface are faint as a ghost: the cut-off part keeps an editor-only mark
            // (a dashed orange outline over the hatch) after the drop, in either appearance.
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                canvas.appearance = NSAppearance(named: appearance)
                guard let marked = render(canvas) else { return t.check(false, "render") }
                t.check(orangePixels(marked, in: past.insetBy(dx: -1, dy: -1)) > 20, "the cut-off part is marked (\(appearance.rawValue))")
                t.equal(orangePixels(marked, in: canvas.skinRect.insetBy(dx: 4, dy: 4)), 0, "nothing inside the widget is")
            }
            canvas.appearance = NSAppearance(named: .darkAqua)
            v.app.state.updateEditor { $0.showsContentOutside = false }
            t.check(!canvas.showsContentOutside, "View ▸ Show Content Outside the Widget turns it off")
            t.equal(canvas.origin.x, SkinCanvasView.margin, "no room made for it")
            guard let none = render(canvas) else { return t.check(false, "render") }
            let visible = canvas.viewRect(v.frame("MeterTitle")).intersection(canvas.bounds)
            t.check(!visible.isNull && visible.maxX < canvas.origin.x - 4, "part of it is in the margin")
            // As bright as the empty surface (its dots) below it.
            let surface = brightest(none, in: visible.offsetBy(dx: 0, dy: 120))
            t.check(brightest(none, in: visible) <= surface + 0.03,
                    "where nothing is drawn: \(brightest(none, in: visible)) vs \(surface)")
            t.equal(orangePixels(none, in: visible), 0, "and no mark")
            v.app.state.updateEditor { $0.showsContentOutside = true }
            // Zoom to Fit takes the ghost in.
            t.check(canvas.frame.width >= canvas.origin.x + canvas.skinRect.width + SkinCanvasView.margin)
        }
    }

    /// A component dragged in from Add grows the widget live, as a dragged layer does (§9.10, §13 task 6).
    static func componentGrowthTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: the widget grows while a component is dragged in past its bottom edge") {
            guard let v = try openVisualizer(t) else { return }
            let canvas = v.canvas
            guard let width = v.skin?.width, let height = v.skin?.height, let clock = EditorComponents.component("clock")
            else { return t.check(false, "skin") }
            let bytes = v.text()
            // The Clock's middle 30 points below the widget's bottom edge.
            let p = NSPoint(x: canvas.origin.x + 20.2 + CGFloat(clock.defaultSize.width / 2),
                            y: canvas.origin.y + CGFloat(height) + 30.2)
            let onScreen = canvas.convert(p, to: nil)
            guard let ghost = canvas.componentDragMoved(id: "clock", to: p, snapping: false) else {
                return t.check(false, "the canvas takes the Clock")
            }
            t.check(ghost.maxY > height, "past the bottom edge: \(ghost)")
            t.close(canvas.skinRect.height, CGFloat(ghost.maxY), accuracy: 0.5, "the card grows live")
            t.equal(canvas.skinRect.width, CGFloat(width))
            t.equal(canvas.growthBadge, "217 × 196 → 217 × \(SkinCanvasView.format(ghost.maxY))")
            t.check(!canvas.isDraggingPastEdge, "nothing is cut off")
            t.check(canvas.frame.height >= canvas.origin.y + canvas.skinRect.height + SkinCanvasView.margin - 0.5,
                    "the canvas reaches past the new edge, so the drag can go further")
            // The canvas holds still while it grows: the next update with the pointer where it was lands on the spot.
            t.equal(canvas.componentDragMoved(id: "clock", to: canvas.convert(onScreen, from: nil), snapping: false), ghost,
                    "the drop spot does not slide away under the pointer")
            // Further down: it grows on.
            let further = canvas.componentDragMoved(id: "clock", to: NSPoint(x: p.x, y: p.y + 40), snapping: false)
            t.close(canvas.skinRect.height, CGFloat(further?.maxY ?? 0), accuracy: 0.5, "and on")
            // The drag leaves the canvas: the widget as it was, nothing written.
            canvas.componentDragEnded()
            t.equal(canvas.skinRect.height, CGFloat(height))
            t.equal(canvas.growthBadge, nil)
            t.equal(v.text(), bytes)

            // Dropped there: the widget has grown as the card showed.
            canvas.componentDragMoved(id: "clock", to: p, snapping: false)
            t.check(canvas.dropComponent(id: "clock", at: p, snapping: false))
            guard let skin = v.skin else { return t.check(false, "skin") }
            t.equal(v.frame("MeterClock").y, ghost.y)
            t.equal(skin.height, v.frame("MeterClock").maxY)
            t.equal(v.editor.toastText, "Added Clock · Widget grew to 217 × \(EditorStyle.number(skin.height))")

            // A fixed-size widget does not grow: the part outside it is cut off.
            guard let file = v.file else { return }
            try v.text().replacingOccurrences(of: "[Rainmeter]\nUpdate=25\n", with: "[Rainmeter]\nUpdate=25\nSkinHeight=196\n")
                .write(to: file, atomically: true, encoding: .utf8)
            v.editor.refreshSkin()
            canvas.componentDragMoved(id: "clock", to: NSPoint(x: p.x, y: p.y + 60), snapping: false)
            t.equal(canvas.skinRect.height, 196, "no growth")
            t.equal(canvas.growthBadge, nil)
            t.check(canvas.isDraggingPastEdge, "cut off on the desktop")
            canvas.componentDragEnded()
        }
    }

    /// Where the canvas's badges, tags and the overlays over it go: never over each other or over the code.
    static func overlayPlacementTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: the drag's tag keeps off “Cut off on the desktop”") {
            guard let v = try openVisualizer(t) else { return }
            v.lockBackground()
            let canvas = v.canvas
            // Past the top-left corner, where the badge used to be.
            v.beginDrag("MeterTitle", dx: -30, dy: -14)
            t.check(canvas.isDraggingPastEdge)
            guard render(canvas) != nil else { return t.check(false, "render") }
            guard let badge = canvas.badgePlacements(zoom: canvas.zoom).first(where: { $0.kind == .cutOff }) else {
                return t.check(false, "the badge")
            }
            t.equal(canvas.badgeRects, [badge.rect], "drawn where it was placed")
            t.check(!canvas.drawnTagRects.isEmpty, "the drag's tag is drawn")
            for tag in canvas.drawnTagRects { t.check(!tag.intersects(badge.rect), "the tag keeps off the badge: \(tag)") }
            let dragged = canvas.viewRect(v.frame("MeterTitle"))
            t.check(!badge.rect.intersects(dragged.insetBy(dx: -4 / canvas.zoom, dy: -4 / canvas.zoom)),
                    "the badge keeps off the layer and its handles")
            canvas.cancelOperation(nil)
            // Past the left edge only: the badge at its usual place, above the card's top-left corner.
            v.beginDrag("MeterLowFreq", dx: -40 - v.frame("MeterLowFreq").x, dy: 0)
            let usual = canvas.badgePlacements(zoom: canvas.zoom).first { $0.kind == .cutOff }?.rect
            t.close(usual?.minX ?? -1, canvas.skinRect.minX, accuracy: 0.01)
            t.check((usual?.maxY ?? .infinity) < canvas.skinRect.minY, "above the card")
            canvas.cancelOperation(nil)
        }

        t.suite("App: friendly canvas: the overlays over the canvas go with it") {
            guard let v = try openVisualizer(t) else { return }
            v.lockBackground()
            let editor = v.editor, chip = editor.widgetChip, capsule = editor.statusCapsule
            guard let window = editor.window, let content = window.contentView else { return t.check(false, "window") }
            window.setContentSize(NSSize(width: 1400, height: 1000))
            content.layoutSubtreeIfNeeded()
            // The title past the left edge (the chip), the sound silent (the capsule), T1 as the running app shows it.
            let title = v.frame("MeterTitle")
            v.beginDrag("MeterTitle", dx: -12 - title.x, dy: 0)
            v.canvas.endGesture(keep: true)
            settle()
            var now = Date(timeIntervalSinceReferenceDate: 1000)
            editor.overlayClock = { now }
            editor.silentSince = nil
            editor.updateSilentData()
            now += 2.5
            editor.updateSilentData()
            editor.canvasSelectionChanged([])
            editor.automaticTips = true
            editor.updateTips()
            t.check(!chip.isHidden && !capsule.isHidden && editor.isTipShown(.click), "all three over the canvas")

            // Code mode: none of them over the code, on any tick.
            editor.setMode(.code)
            t.check(chip.isHidden && capsule.isHidden && !editor.isTipShown(.click), "none in Code mode")
            now += 1
            editor.updateCanvasOverlays()
            t.check(chip.isHidden && capsule.isHidden && !editor.isTipShown(.click), "not on the next tick either")
            editor.setMode(.design)
            t.check(!chip.isHidden && !capsule.isHidden && editor.isTipShown(.click), "back with the canvas")
            editor.tipViews[.click]?.onClose?()

            // The capsule's words have the room they need, inside it, and it stays within the canvas.
            func fits(_ c: OverlayCapsule, _ what: String) {
                let label = c.label
                t.check(label.intrinsicContentSize.height <= label.frame.height + 0.5,
                        "\(what): every line shows (\(label.intrinsicContentSize.height) in \(label.frame.height))")
                t.check(label.intrinsicContentSize.width <= label.frame.width + 0.5, "\(what): no word cut")
                t.check(c.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.convert(label.bounds, to: c)),
                        "\(what): the words inside the capsule")
                let pane = editor.canvasPane.convert(editor.canvasPane.bounds, to: nil)
                t.check(pane.insetBy(dx: -0.5, dy: -0.5).contains(c.convert(c.bounds, to: nil)), "\(what): within the canvas")
            }
            // As the window lays itself out (no help from the test).
            func layOut() { for _ in 0..<4 { content.layoutSubtreeIfNeeded() } }

            fits(chip, "chip in Design")
            t.check(!chip.buttonsBelowWords, "the chip's button beside its words")
            let wide = (words: chip.label.preferredMaxLayoutWidth, capsule: capsule.label.preferredMaxLayoutWidth)

            // Split: a narrow canvas. The words wrap to the room and the button goes under them.
            editor.setMode(.split)
            layOut()
            t.check(editor.canvasPane.frame.width < 480, "a narrow canvas: \(editor.canvasPane.frame.width)")
            fits(chip, "chip in Split")
            fits(capsule, "capsule in Split")
            t.check(chip.buttonsBelowWords, "the chip's button under its words")
            t.check(capsule.label.preferredMaxLayoutWidth < wide.capsule - 20, "the capsule's words wrap narrower")
            // The narrowest window Split allows.
            window.setContentSize(NSSize(width: window.contentMinSize.width, height: 1000))
            layOut()
            fits(chip, "chip in a narrow window")
            fits(capsule, "capsule in a narrow window")
            // Wide again: the words take the room back (a capsule is not left wrapped at a width it once had).
            window.setContentSize(NSSize(width: 1400, height: 1000))
            editor.setMode(.design)
            layOut()
            t.close(chip.label.preferredMaxLayoutWidth, wide.words, accuracy: 0.5, "the chip's words")
            t.close(capsule.label.preferredMaxLayoutWidth, wide.capsule, accuracy: 0.5, "the capsule's words")
            t.check(!chip.buttonsBelowWords, "the button beside the words again")
            fits(chip, "chip in Design again")
            fits(capsule, "capsule in Design again")
        }
    }

    // MARK: Past the left and top edges, and Fit Widget to Content (§9.10)

    static func cutOffTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: past the left edge, and Fit Widget to Content") {
            guard let v = try openVisualizer(t) else { return }
            v.lockBackground()
            let canvas = v.canvas, editor = v.editor
            let title = v.frame("MeterTitle")
            v.beginDrag("MeterTitle", dx: -12 - title.x, dy: 0)
            t.check(canvas.isDraggingPastEdge, "the badge says it is cut off")
            t.check(editor.widgetChip.isHidden, "no chip during the drag")
            canvas.endGesture(keep: true)
            t.equal(v.frame("MeterTitle").x, -12)
            t.check(editor.isLayerCutOff("MeterTitle"), "its row shows ⚠")
            t.check(!editor.isLayerCutOff("MeterBand0"))
            t.equal(editor.cutOffSentence(of: "MeterTitle"), "Part of this layer is past the left edge and won't show on the desktop.",
                    "the identity strip's line")
            t.equal(editor.cutOffSentence(of: "MeterBand0"), nil)
            t.check(!editor.widgetChip.isHidden, "a sticky chip")
            t.equal(editor.widgetChip.text,
                    "\(editor.displayName(ofSection: "MeterTitle")) goes past the left edge. That part won't show on the desktop.")
            t.equal(editor.widgetChip.buttons.map(\.title), ["Fit Widget to Content"])
            t.check(editor.validateMenuItem(NSMenuItem(title: "", action: #selector(Editor.fitWidgetToContentClicked(_:)),
                                                       keyEquivalent: "")), "and a menu command")
            // × closes it until something else is cut off.
            editor.widgetChip.onClose?()
            editor.updateWidgetChip()
            t.check(editor.widgetChip.isHidden, "closed")
            editor.dismissedChipSubject = nil
            editor.updateWidgetChip()

            guard let skin = v.skin, let c = v.app.controller(for: "Audio\\Visualizer") else { return t.check(false, "skin") }
            let frames = Dictionary(uniqueKeysWithValues: skin.meters.filter { $0.container == nil }.map { ($0.name, $0.frame) })
            let position = c.topLeftPosition
            let bytes = v.text()
            settle()
            editor.widgetChip.buttons.first?.performClick(nil)
            guard let fitted = v.skin, let now = v.app.controller(for: "Audio\\Visualizer") else { return t.check(false, "skin") }
            t.equal(fitted.contentBounds().x, 0, "nothing left of the widget")
            for (name, before) in frames {
                t.equal(fitted.meter(named: name)?.frame.x, before.x + 12, "\(name) moved 12 right")
                t.equal(fitted.meter(named: name)?.frame.y, before.y, "\(name) stayed at its height")
            }
            t.close(now.topLeftPosition.x, position.x - 12, accuracy: 0.5, "the window moved 12 left")
            t.close(now.topLeftPosition.y, position.y, accuracy: 0.5)
            let text = v.text()
            for i in 1..<16 {
                t.check(StudioReviewSelfTests.section("MeterBand\(i)", in: text).contains("X=#BarGap#R\n"),
                        "Band\(i) keeps #BarGap#R")
            }
            t.check(StudioReviewSelfTests.section("MeterBand0", in: text).contains("X=(#Left# + 12)\n"))
            t.check(StudioReviewSelfTests.section("MeterPeak", in: text).contains("X=([MeasurePeakX] + 12)\n"),
                    StudioReviewSelfTests.section("MeterPeak", in: text))
            t.check(StudioReviewSelfTests.section("MeterTitle", in: text).contains("X=(#Left# - 14)\n"))
            t.equal(editor.window?.undoManager?.undoActionName, "Fit Widget to Content")
            t.equal(editor.toastText, "Moved everything 12 px right and the widget 12 px left, so nothing jumps on your desktop.")
            t.check(editor.widgetChip.isHidden, "nothing is cut off any more")
            t.check(!editor.isLayerCutOff("MeterTitle"))

            // One ⌘Z puts back the files and the window.
            settle()
            editor.window?.undoManager?.undo()
            t.equal(v.text(), bytes, "the file bytes")
            if let back = v.app.controller(for: "Audio\\Visualizer") {
                t.close(back.topLeftPosition.x, position.x, accuracy: 0.5, "and the window")
            }
            settle()
            editor.window?.undoManager?.redo()
            if let again = v.app.controller(for: "Audio\\Visualizer") {
                t.close(again.topLeftPosition.x, position.x - 12, accuracy: 0.5, "redo moves it again")
            }
            t.equal(v.skin?.contentBounds().x, 0)

            // The canvas makes room for content left of the widget (its origin moves with it).
            settle()
            editor.window?.undoManager?.undo()
            t.close(canvas.origin.x, SkinCanvasView.margin + 12, accuracy: 0.5, "room for the ghost on the left")
            t.equal(canvas.origin.y, SkinCanvasView.margin)

            // Several layers past the top edge.
            let copy = v.text().replacingOccurrences(of: "[MeterTitle]\nMeter=String\nX=(#Left# - 26)\nY=12",
                                                     with: "[MeterTitle]\nMeter=String\nX=#Left#\nY=-6")
                .replacingOccurrences(of: "[MeterLeftLabel]\nMeter=String\nMeterStyle=StyleSmall\nX=#Left#\nY=158",
                                      with: "[MeterLeftLabel]\nMeter=String\nMeterStyle=StyleSmall\nX=#Left#\nY=-4")
            guard let file = v.file else { return }
            try copy.write(to: file, atomically: true, encoding: .utf8)
            editor.refreshSkin()
            t.equal(editor.widgetChip.text, "2 layers go past the top edge. That part won't show on the desktop.")
            let menu = editor.canvasMenu(atSkinX: -40, y: -40)
            t.equal(menu.items.map(\.title), ["Widget Settings", "Fit Widget to Content", "Zoom to Fit"],
                    "the empty canvas's menu")
        }
    }

    // MARK: Fixed size (§9.10 rule 7)

    static func fixedSizeTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: a fixed-size widget does not grow") {
            guard let v = try openVisualizer(t) else { return }
            guard let file = v.file else { return t.check(false, "skin") }
            try v.text().replacingOccurrences(of: "[Rainmeter]\nUpdate=25\n", with: "[Rainmeter]\nUpdate=25\nSkinWidth=240\n")
                .write(to: file, atomically: true, encoding: .utf8)
            v.editor.refreshSkin()
            t.equal(v.skin?.width, 240)
            t.check(v.editor.widgetChip.isHidden, "nothing outside yet")
            v.beginDrag("MeterTitle", dx: 220, dy: 0)
            t.equal(v.canvas.skinRect.width, 240, "no growth")
            t.equal(v.canvas.growthBadge, nil)
            t.check(v.canvas.isDraggingPastEdge, "cut off on the desktop")
            v.canvas.endGesture(keep: true)
            settle()
            t.equal(v.skin?.width, 240)
            t.check(v.editor.isLayerCutOff("MeterTitle"))
            t.equal(v.editor.widgetChip.text,
                    "Part of \(v.editor.displayName(ofSection: "MeterTitle")) is outside the widget's fixed size (240 × 196).")
            t.equal(v.editor.widgetChip.buttons.map(\.title), ["Make Widget Bigger", "Fit to Content"])
            let right = v.frame("MeterTitle").maxX
            v.editor.widgetChip.buttons[0].performClick(nil)
            t.check(v.text().contains("SkinWidth=\(EditorStyle.number(right.rounded(.up)))\n"), "Make Widget Bigger")
            t.check(v.editor.widgetChip.isHidden)
            settle()
            v.editor.window?.undoManager?.undo()
            t.check(v.text().contains("SkinWidth=240\n"))
            v.editor.widgetChip.buttons[1].performClick(nil)
            t.check(!v.text().contains("SkinWidth"), "Fit to Content: the widget fits its content")
            t.equal(v.skin?.width, right.rounded(.up))
        }
    }

    // MARK: Editing text in place (§9.4)

    static func inlineTextTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: editing words on the canvas") {
            guard let v = try openVisualizer(t) else { return }
            let editor = v.editor, canvas = v.canvas
            func doubleClick(_ name: String) {
                let f = v.frame(name)
                canvas.doubleClick(skinX: f.x + f.width / 2, y: f.y + f.height / 2)
            }
            func fieldEditor() -> NSTextView? { editor.window?.firstResponder as? NSTextView }
            t.check(editor.canEditTextInPlace("MeterTitle"))
            t.check(!editor.canEditTextInPlace("MeterHighFreq"), "text showing data")
            t.check(!editor.canEditTextInPlace("MeterBand0"), "not text")

            doubleClick("MeterTitle")
            guard let field = editor.inlineTextEditor else { return t.check(false, "the field opens") }
            t.equal(field.stringValue, "Audio")
            t.equal(canvas.editingText, "MeterTitle")
            t.check(field.superview === canvas, "on the canvas, zoomed with it")
            t.check(field.frame.insetBy(dx: -1, dy: -1).contains(canvas.viewRect(v.frame("MeterTitle"))),
                    "over the words: \(field.frame) \(canvas.viewRect(v.frame("MeterTitle")))")
            t.equal(field.font?.pointSize, Fonts.font(for: (v.skin?.meter(named: "MeterTitle") as? StringMeter)?.style ?? TextStyle()).pointSize,
                    "in the layer's font")
            t.check((fieldEditor()?.delegate as? NSTextField) === field, "with the keyboard")
            guard let typing = fieldEditor() else { return t.check(false, "field editor") }
            typing.selectAll(nil)
            typing.insertText("Sound", replacementRange: typing.selectedRange())
            typing.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            t.check(editor.inlineTextEditor == nil, "Return ends it")
            t.check(StudioReviewSelfTests.section("MeterTitle", in: v.text()).contains("Text=Sound\n"), "and writes Text=")
            t.equal(editor.window?.undoManager?.undoActionName, "Edit Text")
            t.equal(canvas.editingText, nil)

            // Esc leaves the bytes as they were.
            settle()
            let bytes = v.text()
            t.check(editor.beginInlineTextEdit("MeterTitle"), "[Edit Text] does the same")
            if let esc = fieldEditor() {
                esc.selectAll(nil)
                esc.insertText("Nope", replacementRange: esc.selectedRange())
                esc.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            }
            t.check(editor.inlineTextEditor == nil, "Esc ends it")
            t.equal(v.text(), bytes, "and writes nothing")
            t.check(v.skin?.isPreviewing == false, "the words show again")

            // Clicking elsewhere commits.
            editor.beginInlineTextEdit("MeterTitle")
            if let other = fieldEditor() {
                other.selectAll(nil)
                other.insertText("Mix", replacementRange: other.selectedRange())
            }
            canvas.click(skinX: 4, y: 190)
            t.check(StudioReviewSelfTests.section("MeterTitle", in: v.text()).contains("Text=Mix\n"), "a click elsewhere commits")

            // Words showing data: the inspector's Text field takes the keyboard instead.
            doubleClick("MeterHighFreq")
            t.check(editor.inlineTextEditor == nil, "no field on the canvas")
            t.equal(editor.selectedSection, "MeterHighFreq")
            // (§9.4: the inspector's token field, where the words around the blue data tag are typed.)
            let tokens = editor.inspectorStack.findSubview { $0.identifier?.rawValue == "text-tokens" } as? DataTokenField
            t.check(tokens != nil && editor.window?.firstResponder === tokens?.textView, "the inspector's Text field has the keyboard")
            t.check(tokens?.isDescendant(of: editor.inspectorStack) == true)
        }

        t.suite("App: friendly canvas: an empty text shows where to type") {
            let ini = "[Rainmeter]\nUpdate=1000\n[Box]\nMeter=Image\nSolidColor=40,40,40\nW=200\nH=80\n"
                + "[Empty]\nMeter=String\nX=10\nY=10\nFontSize=12\nText=\n"
            guard let (_, editor, _) = try StudioReviewSelfTests.openSkin(t, "Blank", ini) else { return }
            guard let empty = editor.skin?.meter(named: "Empty"), let placeholder = editor.canvas.placeholderRect(empty) else {
                return t.check(false, "a placeholder")
            }
            t.check(placeholder.width > 50, "“Double-click to type”")
            t.equal(editor.canvas.pickableMeter(atSkinX: placeholder.x + 5, placeholder.y + 5)?.name, "Empty",
                    "and it can be clicked")
            editor.canvas.doubleClick(skinX: placeholder.x + 5, y: placeholder.y + 5)
            t.equal(editor.inlineTextEditor?.section, "Empty", "double-clicking it edits the words")
            t.equal(editor.canvas.editingText, "Empty")
            editor.endInlineTextEdit(commit: false)
            t.check(!(editor.skin.flatMap { try? String(contentsOf: $0.fileURL, encoding: .utf8) } ?? "")
                        .contains("Double-click"), "never written")
        }
    }

    // MARK: Followers (§9.5)

    static func followerTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: layers that follow the moved one") {
            guard let v = try openVisualizer(t) else { return }
            guard let skin = v.skin else { return t.check(false, "skin") }
            t.equal(SkinCanvasView.anchor(of: skin.meter(named: "MeterHighFreq")!, in: skin), "MeterLowFreq", "Y=0r")
            t.equal(SkinCanvasView.anchor(of: skin.meter(named: "MeterBand5")!, in: skin), "MeterBand4", "X=#BarGap#R")
            t.equal(SkinCanvasView.anchor(of: skin.meter(named: "MeterTitle")!, in: skin), nil, "placed on its own")
            t.equal(SkinCanvasView.followers(of: ["MeterBand13"], in: skin), ["MeterBand14": "MeterBand13",
                                                                             "MeterBand15": "MeterBand14"],
                    "through the whole chain")
            v.beginDrag("MeterLowFreq", dx: 0, dy: -3)
            t.equal(v.canvas.followers, ["MeterHighFreq": "MeterLowFreq"], "outlined while it moves")
            v.canvas.cancelOperation(nil)
            t.equal(v.canvas.followers, [:], "until the drag ends")
            // Nudging too.
            v.editor.canvasSelectionChanged(["MeterLowFreq"])
            v.editor.nudge(dx: 0, dy: -1)
            t.equal(v.canvas.followers, ["MeterHighFreq": "MeterLowFreq"])
            v.editor.commitPendingNudge()
            t.equal(v.canvas.followers, [:])
            t.check(StudioReviewSelfTests.section("MeterLowFreq", in: v.text()).contains("Y=(36 + #BarH# + 3)\n"),
                    "the calculation is kept")
        }
    }

    // MARK: Adding in free space (§5.1)

    static func placementTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: a clicked component lands in free space") {
            guard let v = try openVisualizer(t) else { return }
            guard let before = v.skin else { return t.check(false, "skin") }
            let bounds = before.contentBounds()
            let frames = before.meters.filter { !$0.hidden && $0.frame.width > 0 && $0.frame.height > 0 }.map(\.frame)
            v.editor.select(section: "MeterBand5")
            v.editor.insertComponent("clock")
            let clock = v.frame("MeterClock")
            t.check(clock.y >= bounds.maxY + 8 - 0.5, "below everything: \(clock)")
            t.equal(clock.x, max(bounds.x, 0), "at the left edge of the content")
            for f in frames {
                let overlaps = clock.x < f.maxX && f.x < clock.maxX && clock.y < f.maxY && f.y < clock.maxY
                t.check(!overlaps, "on no other layer: \(f)")
            }
            guard let skin = v.skin else { return t.check(false, "skin") }
            t.check(skin.height > 196, "the widget grew")
            t.equal(v.editor.toastText, "Added Clock · Widget grew to \(EditorStyle.number(skin.width)) × \(EditorStyle.number(skin.height))")
            // §5.1: "Added Clock · Widget grew to 217 × 240 · [Stretch Background] [Undo]".
            t.equal(v.editor.toast.buttons.map(\.title), ["Stretch Background", "Undo"])

            // [Undo] undoes it; the next toast offers [Redo].
            settle()
            v.editor.toast.button("Undo")?.performClick(nil)
            t.check(!v.text().contains("[MeterClock]"), "the toast's Undo button undoes")
            t.equal(v.editor.toastText, "Undid Add Clock")
            settle()
            v.editor.toast.button("Redo")?.performClick(nil)
            t.check(v.text().contains("[MeterClock]"), "and its Redo button redoes")

            // An empty widget: at the origin.
            let empty = try StudioReviewSelfTests.openSkin(t, "Nothing", "[Rainmeter]\nUpdate=1000\n")
            guard let (_, editor, _) = empty else { return }
            t.equal(editor.canvas.starterRects().map(\.0), ["clock", "cpu", "text"], "three starters")
            t.check(editor.canvas.skinRect.width >= SkinCanvasView.emptyCardSize.width, "a card big enough for them")
            editor.canvas.onStarter?("text")
            t.equal(editor.skin?.meters.first?.frame.x, 0)
            t.equal(editor.skin?.meters.first?.frame.y, 0)
            t.equal(editor.canvas.starterRects().count, 0, "gone once there is a layer")
        }
    }

    // MARK: Placeholders (§9.8) and the right-click menu (§9.7)

    static func placeholderTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: placeholders and the right-click menu") {
            let ini = "[Rainmeter]\nUpdate=1000\n[MeasureCPU]\nMeasure=CPU\n"
                + "[Empty]\nMeter=Bar\nX=10\nY=10\nW=150\nH=10\nBarColor=255,255,255\nSolidColor=60,60,60\n"
                + "[Shown]\nMeter=Bar\nMeasureName=MeasureCPU\nX=10\nY=30\nW=150\nH=10\n"
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "Bars", ini) else { return }
            let chips = editor.canvas.chooseDataChips()
            t.equal(chips.map(\.0), ["Empty"], "“Choose what this shows ▾” on the bar without data")
            if let (name, rect) = chips.first {
                editor.canvas.onChooseData?(name, rect)
                t.equal(editor.selectedSection, "Empty", "clicking it selects the bar")
            }
            let menu = editor.chooseDataMenu(for: "Empty")
            t.equal(menu.items.first?.title, "In This Widget")
            // The inspector's Shows menu (§9.8), shared with the canvas.
            t.equal(menu.items.compactMap { $0.representedObject as? String }, ["MeasureCPU"], "the live data of this widget")
            t.equal(menu.items.last?.title, "New")
            t.check(menu.items.last?.submenu?.items.contains { $0.title.contains("Memory") } == true, "New ▸ every kind")
            if let item = menu.items.first(where: { ($0.representedObject as? String) == "MeasureCPU" }) {
                _ = item.target?.perform(item.action)
            }
            t.check(StudioReviewSelfTests.section("Empty", in: StudioReviewSelfTests.read(url)).contains("MeasureName=MeasureCPU"),
                    "picking it shows it")
            t.equal(editor.canvas.chooseDataChips().count, 0, "and the chip is gone")

            // The right-click menu: Select ▸ with every layer under the pointer, then the layer's own menu.
            guard let shown = editor.skin?.meter(named: "Shown") else { return t.check(false, "skin") }
            let layerMenu = editor.canvasMenu(atSkinX: shown.frame.x + 5, y: shown.frame.y + 5)
            t.equal(layerMenu.items.first?.title, "Select")
            t.equal(layerMenu.items.first?.submenu?.items.map(\.toolTip), ["Shown"])
            t.check(layerMenu.items.contains { $0.title == "Hide" } && layerMenu.items.contains { $0.title == "Duplicate" },
                    "the layer menu follows")
        }
    }

    // MARK: Silent data (§9.9, phase 1)

    static func silentDataTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: silent sound is explained") {
            guard let v = try openVisualizer(t) else { return }
            let editor = v.editor
            // Self-tests never capture audio: the sound data reads 0.
            guard let state = editor.soundState() else { return t.check(false, "the bars show sound data") }
            t.check(state != .playing, "\(state)")
            var now = Date(timeIntervalSinceReferenceDate: 1000)
            editor.overlayClock = { now }
            editor.silentSince = nil
            editor.updateSilentData()
            t.check(editor.statusCapsule.isHidden, "not at once")
            now += 2.5
            editor.updateSilentData()
            t.check(!editor.statusCapsule.isHidden, "after 2 seconds")
            if state == .silent {
                t.equal(editor.statusCapsule.text, "No sound is playing, so the bars are still. Play something to see them move.")
                t.equal(editor.statusCapsule.buttons.map(\.title), [])
            } else {
                t.equal(editor.statusCapsule.text, "Deskset can't hear your Mac's sound yet.")
                t.equal(editor.statusCapsule.buttons.map(\.title), ["Allow…"])
            }
            editor.statusCapsule.onClose?()
            now += 5
            editor.updateSilentData()
            t.check(editor.statusCapsule.isHidden, "closed stays closed")

            // A widget without sound data never shows it.
            guard let (_, clock, _) = try StudioReviewSelfTests.openSkin(t, "Quiet", "[Rainmeter]\n[T]\nMeter=String\nText=Hi\n")
            else { return }
            t.equal(clock.soundState(), nil)
            clock.updateSilentData(settled: true)
            t.check(clock.statusCapsule.isHidden)
        }
    }

    // MARK: Tips (§12)

    static func tipTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: first-run tips") {
            guard let v = try openVisualizer(t) else { return }
            v.useBandRun()
            let editor = v.editor
            t.check(EditorTip.allCases.allSatisfy { !editor.isTipShown($0) }, "never by themselves in self-tests")
            t.check(!editor.showsTipsAutomatically)
            t.equal(v.app.state.editor.seenTips, [])

            // As the running app shows them.
            editor.automaticTips = true
            editor.updateTips()
            t.check(editor.isTipShown(.click), "T1 on the first open")
            t.equal(editor.tipViews[.click]?.text, "Click anything in your widget to change it. Drag new things in from Add.")
            t.equal(v.app.state.editor.seenTips, ["T1"], "recorded as seen")
            let band = v.frame("MeterBand3")
            v.canvas.click(skinX: band.x + 1, y: band.y + 5)
            t.check(!editor.isTipShown(.click), "gone at the first selection")
            t.check(editor.isTipShown(.group), "T2 when a run is selected")
            t.equal(editor.tipViews[.group]?.text,
                    "These 16 bars change together. Double-click one bar on the canvas to change just that one.")
            v.canvas.doubleClick(skinX: band.x + 1, y: band.y + 5)
            t.check(!editor.isTipShown(.group), "gone after a double-click into the run")
            v.canvas.cancelOperation(nil)
            v.canvas.cancelOperation(nil)
            editor.updateTips()
            t.check(!editor.isTipShown(.click) && !editor.isTipShown(.group), "each is shown once")
            editor.selectSidebarTab(.library)
            editor.updateTips()
            t.check(editor.isTipShown(.add), "T3 when the Add tab opens")
            t.equal(editor.tipViews[.add]?.text, "Drag any of these onto your widget, or click one to add it below what's there.")
            editor.insertComponent("text")
            t.check(!editor.isTipShown(.add), "gone at the first add")
            t.equal(v.app.state.editor.seenTips, ["T1", "T2", "T3"])
            editor.tipViews[.add]?.onClose?()

            // Help ▸ Show Tips Again.
            editor.canvasSelectionChanged([])
            editor.selectSidebarTab(.layers)
            editor.showTipsAgain(nil)
            t.equal(v.app.state.editor.seenTips, ["T1"], "every tip again, T1 now")
            t.check(editor.isTipShown(.click))
            editor.tipViews[.click]?.onClose?()
            t.check(!editor.isTipShown(.click), "× closes it")

            // --tip N shows one whatever was seen (snapshots), and it is drawn.
            editor.automaticTips = false
            guard let without = editor.snapshot() else { return t.check(false, "snapshot") }
            var options = SnapshotOptions()
            options.tip = 1
            editor.applySnapshotCanvasOptions(options)
            t.check(editor.isTipShown(.click), "--tip 1")
            guard let with = editor.snapshot() else { return t.check(false, "snapshot") }
            t.check(with.tiffRepresentation != without.tiffRepresentation, "drawn in the snapshot")
        }
    }

    // MARK: Toolbar, menus, toasts (§4, §10)

    static func chromeTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: toolbar, menus and toasts") {
            guard let v = try openVisualizer(t) else { return }
            let editor = v.editor
            guard let items = editor.window?.toolbar?.items else { return t.check(false, "toolbar") }
            func item(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? { items.first { $0.itemIdentifier == id } }
            let undo = item(Editor.toolbarUndo), redo = item(Editor.toolbarRedo)
            t.check(undo != nil && redo != nil, "↶ ↷")
            if let undo, let redo {
                t.check(!editor.validateToolbarItem(undo) && !editor.validateToolbarItem(redo), "disabled with nothing to undo")
                t.equal(undo.toolTip, "Undo")
                editor.insertComponent("text")
                settle()
                t.check(editor.validateToolbarItem(undo), "enabled after a change")
                t.equal(undo.toolTip, "Undo Add Text", "its tooltip names the step")
                editor.undoClicked(nil)
                t.check(!v.text().contains("[MeterText]"), "it undoes")
                t.check(editor.validateToolbarItem(redo))
                t.equal(redo.toolTip, "Redo Add Text")
                editor.redoClicked(nil)
                t.check(v.text().contains("[MeterText]"), "and redoes")
            }
            let add = item(Editor.toolbarLibrary)
            t.equal(add?.label, "Add")
            t.equal((add?.view as? NSButton)?.title, "Add", "+ Add")
            let backdrop = item(Editor.toolbarBackdrop)
            t.equal(backdrop?.label, "Backdrop")
            t.equal(backdrop?.toolTip, "The color behind your widget in the editor. It isn't part of the widget.")
            let popup = backdrop?.view as? NSPopUpButton
            t.equal(popup?.itemArray.map(\.title), ["Backdrop", "Transparent", "Dark", "Light"])
            if let dark = popup?.itemArray.first(where: { $0.title == "Dark" }) {
                editor.backdropChosen(dark)
                t.equal(editor.canvas.backdrop, .dark)
                t.equal(dark.state, .on, "checked")
            }

            // The menus.
            let main = MainMenu.make(app: v.app)
            func menu(_ title: String) -> NSMenu? { main.items.first { $0.title == title }?.submenu }
            let view = menu("View")
            let reload = view?.items.first { $0.action == #selector(Editor.refreshClicked) }
            t.equal(reload?.title, "Reload Widget")
            t.equal(reload?.keyEquivalent, "r")
            let details = view?.items.first { $0.action == #selector(Editor.toggleRainmeterDetails(_:)) }
            t.equal(details?.title, "Show Rainmeter Details")
            let outside = view?.items.first { $0.action == #selector(Editor.toggleContentOutside(_:)) }
            t.equal(outside?.title, "Show Content Outside the Widget")
            t.equal(view?.items.first { $0.title == "Canvas Backdrop" }?.submenu?.items.map(\.title), ["Transparent", "Dark", "Light"])
            if let outside {
                t.check(editor.validateMenuItem(outside) && outside.state == .on, "on by default")
                editor.toggleContentOutside(outside)
                t.check(!editor.canvas.showsContentOutside, "turns the ghost off")
                t.check(editor.validateMenuItem(outside) && outside.state == .off)
                editor.toggleContentOutside(outside)
            }
            if let details {
                t.check(editor.validateMenuItem(details) && details.state == .off)
                editor.toggleRainmeterDetails(details)
                t.check(v.app.state.editor.showIniNames, "the Rainmeter details preference")
                editor.toggleRainmeterDetails(details)
            }
            t.equal(menu("Help")?.items.map(\.title), ["Show Tips Again"])
            t.equal(menu("Insert")?.items.first?.title, "Add…")
            t.equal((editor.moreMenu().items.first)?.title, "Reload Widget")

            // Toasts: plain words, never a file name, and [Undo].
            editor.canvasSelectionChanged(["MeterTitle"])
            editor.nudge(dx: 1, dy: 0)
            editor.commitPendingNudge()
            t.equal(editor.toastText, "Moved \(editor.displayName(ofSection: "MeterTitle"))")
            t.equal(editor.toast.buttons.map(\.title), ["Undo"])
            t.equal(editor.window?.undoManager?.undoActionName, "Move \(editor.displayName(ofSection: "MeterTitle"))")
            editor.setHidden(true, meter: "MeterDevice")
            let device = editor.displayName(ofSection: "MeterDevice")
            t.equal(editor.toastText, "Hid \(device)")
            t.equal(editor.window?.undoManager?.undoActionName, "Hide \(device)")
            t.equal(Editor.doneMessage("Change Font Size of 3 Texts"), "Changed font size of 3 texts")
            t.equal(Editor.doneMessage("Hide “MacBook Pro”"), "Hid “MacBook Pro”")
            t.equal(Editor.doneMessage("Add CPU Bar"), "Added CPU bar")
            t.equal(ZoomPill(target: editor, zoomOut: #selector(Editor.zoomOutClicked), zoomIn: #selector(Editor.zoomInClicked),
                             actual: #selector(Editor.actualSizeClicked), fit: #selector(Editor.fitClicked))
                        .findSubview { ($0 as? NSButton)?.title == "Zoom to Fit" } != nil, true, "Zoom to Fit in words")
        }
    }

    // MARK: Snapshot options (§14.4 D13)

    static func snapshotOptionTests(_ t: AppTestRunner) {
        t.suite("App: friendly canvas: snapshot states") {
            guard let v = try openVisualizer(t) else { return }
            var options = SnapshotOptions()
            options.drag = .init(name: "MeterTitle", dx: 222, dy: 0)
            v.editor.applySnapshotCanvasOptions(options)
            t.check(v.canvas.gesture != nil, "--drag begins a gesture and leaves it open")
            t.equal(v.canvas.growthBadge, "217 × 196 → 277 × 196")
            v.canvas.cancelOperation(nil)

            options = SnapshotOptions()
            options.editText = "MeterTitle"
            v.editor.applySnapshotCanvasOptions(options)
            t.equal(v.editor.inlineTextEditor?.stringValue, "Audio", "--edit-text")
            v.editor.endInlineTextEdit(commit: false)

            options = SnapshotOptions()
            options.scroll = "text"
            v.editor.select(section: "MeterTitle")
            v.editor.window?.setContentSize(NSSize(width: 1180, height: 540))
            v.editor.window?.contentView?.layoutSubtreeIfNeeded()
            v.editor.applySnapshotCanvasOptions(options)
            t.check(v.editor.inspectorScroll.contentView.bounds.minY > 0, "--scroll moves the inspector to the card")
            t.check(!v.editor.scrollInspector(toCard: "No Such Card"))
        }
    }
}
