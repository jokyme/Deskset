import AppKit
import DesksetCore

/// `Deskset --self-test "App: review fixes"`: what the friendliness review found wrong in where edits are written
/// (docs/editor-friendly.md §7.5, P6 "what you selected is what changes", P7 "show the reach", P11 fidelity) and on
/// the canvas: a widget's own edits never rewrite a file other widgets share (linked sizes, [Rainmeter] settings,
/// looks, layers only such a file defines), "All Widgets" really reaches them, a value that can't win is not
/// reported as done, several layers are each written in their own file, nothing another widget uses is deleted,
/// "Apply to All" means all, the eye keeps a Hidden that follows a setting, a refused undo leaves the window alone,
/// and a clicked "Used by" link takes its veil with it.
enum ReviewFixesSelfTests {
    typealias Editor = InspectorWindowController

    static func run(_ t: AppTestRunner) {
        overflowContrastTests(t)
        overlayTests(t)
        inspectorTests(t)
        sharedWriteTests(t)
        layerWriteTests(t)
        deletionTests(t)
        eyeTests(t)
        undoAndVeilTests(t)
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    /// A scratch root config "Suite" with these files (relative to it), and the editor open on `Suite\<widget>`.
    static func openSuite(_ t: AppTestRunner, _ files: [String: String], widget: String = "A") throws
        -> (app: AppController, editor: Editor, root: URL)? {
        var all: [String: String] = [:]
        for (path, text) in files { all["Suite/" + path] = text }
        guard let (app, editor) = try FriendlyWidgetPageSelfTests.openScratch(t, files: all, config: "Suite\\\(widget)") else {
            return nil
        }
        return (app, editor, app.skinsDirectory.appendingPathComponent("Suite"))
    }

    // MARK: Overflow in light mode

    /// The darkest pixel of a rectangle (view coordinates) of a rendering: 0…1.
    static func darkest(_ r: (rep: NSBitmapImageRep, scale: CGFloat), in rect: CGRect) -> CGFloat {
        var best: CGFloat = 1
        let x0 = max(Int(rect.minX * r.scale), 0), x1 = min(Int(rect.maxX * r.scale), r.rep.pixelsWide - 1)
        let y0 = max(Int(rect.minY * r.scale), 0), y1 = min(Int(rect.maxY * r.scale), r.rep.pixelsHigh - 1)
        guard x0 <= x1, y0 <= y1 else { return 1 }
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = r.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                best = min(best, 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
        }
        return best
    }

    static func overflowContrastTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: white words past any edge stay visible in light mode") {
            guard let v = try FriendlyCanvasSelfTests.openVisualizer(t), let file = v.file else { return }
            let canvas = v.canvas
            canvas.appearance = NSAppearance(named: .aqua)
            v.lockBackground()
            // Grown to the right while dragged: the new area is a mid-grey checkerboard the white title shows on.
            v.beginDrag("MeterTitle", dx: 215, dy: 0)
            guard let grown = FriendlyCanvasSelfTests.render(canvas) else { return t.check(false, "render") }
            let words = canvas.viewRect(v.frame("MeterTitle")).insetBy(dx: 1, dy: 1)
            let bright = FriendlyCanvasSelfTests.brightest(grown, in: words), dark = darkest(grown, in: words)
            t.check(bright - dark > 0.3, "the title stands out in the grown area: \(bright) vs \(dark)")
            canvas.cancelOperation(nil)
            // Written past the left edge, nothing selected: its ghost on the widget's dark panel, and its name.
            try v.text().replacingOccurrences(of: "[MeterTitle]\nMeter=String\nX=#Left#", with: "[MeterTitle]\nMeter=String\nX=-60")
                .write(to: file, atomically: true, encoding: .utf8)
            v.editor.refreshSkin()
            v.editor.canvasSelectionChanged([])
            let past = canvas.viewRect(v.frame("MeterTitle"))
            let outside = CGRect(x: past.minX, y: past.minY, width: canvas.origin.x - past.minX, height: past.height).insetBy(dx: 1, dy: 1)
            guard let ghost = FriendlyCanvasSelfTests.render(canvas) else { return t.check(false, "render") }
            let g1 = FriendlyCanvasSelfTests.brightest(ghost, in: outside), g0 = darkest(ghost, in: outside)
            t.check(g0 < 0.4, "the part outside is on a dark ground, not the light surface: \(g0)")
            t.check(g1 - g0 > 0.15, "its 35% ghost can be seen: \(g1) vs \(g0)")
            t.check(canvas.drawnTagRects.contains { $0.intersects(past.insetBy(dx: -30, dy: -30)) }, "and it is named")
        }
    }

    // MARK: Overlays and first looks

    static func overlayTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: the tips never cover the chip or the strip's buttons") {
            guard let (_, editor, _) = try openSuite(t, [
                "A/A.ini": "[Rainmeter]\n[Title]\nMeter=String\nText=Hello\nX=-20\nY=4\nFontColor=255,255,255,255\n"
                    + "[Body]\nMeter=Image\nSolidColor=30,30,30,255\nY=20\nW=200\nH=80\n",
            ]) else { return }
            editor.canvasSelectionChanged([])
            editor.updateCanvasOverlays()
            editor.showTip(.click)
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            guard let t1 = editor.tipViews[.click] else { return t.check(false, "T1") }
            t.check(!editor.widgetChip.isHidden, "the chip shows: \(editor.widgetChip.text)")
            t.check(!t1.frame.intersects(editor.widgetChip.frame), "T1 sits under the chip, not over it")
            // While a drag is under way the chip steps aside; afterwards it says what is true.
            editor.beginGeometry(meters: ["Title"], gesture: .move)
            t.check(editor.widgetChip.isHidden, "no chip during the gesture")
            editor.endGeometry(keep: false)
            editor.updateCanvasOverlays()
            t.check(!editor.widgetChip.isHidden)

            guard let v = try FriendlyCanvasSelfTests.openVisualizer(t) else { return }
            v.useBandRun()
            v.editor.canvasSelectionChanged(FriendlyCanvasSelfTests.bands)
            v.editor.showTip(.group)
            v.editor.window?.contentView?.layoutSubtreeIfNeeded()
            guard let content = v.editor.window?.contentView, let tip = v.editor.tipViews[.group] else { return t.check(false, "T2") }
            let buttons = v.editor.inspectorStack.subviewsMatching { ($0 as? NSButton)?.title == "Hide All" || ($0 as? NSButton)?.title == "Lock All" }
            t.check(!buttons.isEmpty, "the strip's buttons")
            for b in buttons {
                t.check(!tip.frame.intersects(b.convert(b.bounds, to: content)), "T2 leaves “\((b as? NSButton)?.title ?? "")” free")
            }
            // Faded out while the strip is scrolled away, T2 lets clicks through to the inspector under it.
            let centre = NSPoint(x: tip.frame.midX, y: tip.frame.midY)
            t.check(tip.hitTest(centre) != nil, "a shown tip takes its own clicks")
            let alpha = tip.alphaValue
            tip.alphaValue = 0
            t.check(tip.hitTest(centre) == nil, "a faded-out tip lets clicks through")
            tip.alphaValue = alpha
        }

        t.suite("App: review fixes: a cut-off clock's chip keeps its words while the time changes") {
            guard let (_, editor, root) = try openSuite(t, [
                "A/A.ini": "[Rainmeter]\n[MeasureText]\nMeasure=String\nString=10\n[Time]\nMeter=String\nMeasureName=MeasureText\n"
                    + "X=-8\nFontColor=255,255,255,255\n[Body]\nMeter=Image\nSolidColor=30,30,30,255\nY=20\nW=100\nH=40\n",
            ]) else { return }
            _ = root
            editor.canvasSelectionChanged([])
            editor.updateCanvasOverlays()
            let first = editor.widgetChip.text
            t.check(first.contains("“10”"), first)
            editor.skin?.measure(named: "MeasureText").map { $0.rawString = "11" }
            editor.skin?.update()
            editor.updateCanvasOverlays()
            t.equal(editor.widgetChip.text, first, "named as it was when the chip appeared")
        }

        t.suite("App: review fixes: a clock drawn with fixed gauges shows no choose-data chips") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Round\\AnalogClock") else { return }
            editor.canvasSelectionChanged([])
            t.equal(editor.canvas.chooseDataChips().map(\.0), [], "face, rim and ticks draw without data on purpose")
            t.check(editor.sidebar.catalog?.layer("MeterFace")?.subtitle == "Gauge · fixed shape")
        }

        t.suite("App: review fixes: words edited in place stay readable while selected") {
            let white = Editor.inlineSelectionAttributes(textColor: .white)
            let black = Editor.inlineSelectionAttributes(textColor: .black)
            func luminance(_ c: Any?) -> CGFloat {
                guard let c = (c as? NSColor)?.usingColorSpace(.sRGB) else { return -1 }
                return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            }
            t.check(luminance(white[.backgroundColor]) < 0.35, "white words on a dark accent: \(luminance(white[.backgroundColor]))")
            t.check(luminance(black[.backgroundColor]) > 0.55, "dark words on a light accent: \(luminance(black[.backgroundColor]))")
            t.equal(white[.foregroundColor] as? NSColor, .white, "in the layer's own color")
        }

        t.suite("App: review fixes: an empty widget's list says so below its own row") {
            guard let (_, editor, _) = try openSuite(t, ["A/A.ini": "[Rainmeter]\n[MeasureCPU]\nMeasure=CPU\n"]) else { return }
            editor.selectSidebarTab(.layers)
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            let empty = editor.sidebar.emptyState
            t.check(!empty.isHidden, "the empty state shows")
            let outline = editor.outline
            if outline.numberOfRows > 0, let content = editor.window?.contentView {
                let row = outline.convert(outline.rect(ofRow: outline.numberOfRows - 1), to: content)
                t.check(!empty.convert(empty.bounds, to: content).intersects(row), "not over the widget's row")
            }
        }

        t.suite("App: review fixes: a see-through widget with light words opens on a dark backdrop") {
            guard let (app, editor, _) = try openSuite(t, [
                "A/A.ini": "[Rainmeter]\n[Title]\nMeter=String\nText=Hello\nFontColor=255,255,255,255\n"
                    + "[Value]\nMeter=String\nText=42\nY=20\nFontColor=240,240,240,255\n",
                "B/B.ini": "[Rainmeter]\n[Title]\nMeter=String\nText=Hello\nFontColor=20,20,20,255\n",
            ]) else { return }
            t.equal(editor.canvas.backdrop, .dark, "white words on the white checkerboard would vanish")
            t.equal(app.state.editor.backdrops["suite\\a"], SkinCanvasView.Backdrop.dark.rawValue, "remembered for the widget")
            t.equal(editor.window?.subtitle, "", "no engine path under the name")
            guard let b = app.activate(config: "Suite\\B", file: nil) else { return t.check(false, "B loads") }
            app.showInspector(for: b)
            t.equal(app.inspector?.canvas.backdrop, .checkerboard, "dark words keep the checkerboard")
        }
    }

    // MARK: Inspector pages

    /// Every text a person reads in the inspector now (labels, buttons, pop-up titles, fields' placeholders).
    static func words(_ editor: Editor) -> [String] {
        var result: [String] = []
        for v in editor.inspectorStack.subviewsMatching({ !$0.isHiddenOrHasHiddenAncestor }) {
            switch v {
            case let popup as NSPopUpButton: result.append(popup.titleOfSelectedItem ?? "")
            case let button as NSButton: result.append(button.title)
            case let field as NSTextField: result += [field.stringValue, field.placeholderString ?? ""]
            default: break
            }
        }
        return result
    }

    static func inspectorTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: a color control uses its widget-page row's name") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Clock", from: "DefaultSkins"),
                  let skin = editor.skin else { return }
            let groups = editor.valueUsages(skin).colorGroups(separate: editor.inspectorState.separateColors)
            for variable in ["SubtleColor", "AccentColor", "TextColor"] {
                guard let group = groups.first(where: { $0.variables.contains(variable) }) else { continue }
                t.equal(editor.colorRoleName(variable: variable, color: nil), group.name, "\(variable): the row's name, not the variable's")
            }
            let titles = groups.map(\.name)
            t.equal(Set(titles).count, titles.count, "no two rows share a name: \(titles)")
            // AM/PM is text: no Number row, even while it is empty (24-hour mode).
            editor.select(section: "MeterSuffix")
            t.check(FriendlyWidgetPageSelfTests.find(editor, "number-format") == nil, "no Number row for AM/PM")
        }

        t.suite("App: review fixes: every trigger is a picker, the pointer one menu") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins") else { return }
            editor.select(section: "MeterTitle")
            editor.openMore("When Clicked")
            let seen = words(editor)
            t.check(!seen.contains("No action") && !seen.contains { $0.hasPrefix("[!") }, "no field for typing a command")
            t.check(!seen.contains("Show a pointing hand over it") && !seen.contains("Hide the tooltip"), "\(seen)")
            t.check(FriendlyWidgetPageSelfTests.find(editor, "RightMouseUpAction.choice") is NSPopUpButton, "Right-click picks")
            t.equal((FriendlyWidgetPageSelfTests.find(editor, "MeterTitle/pointer") as? NSPopUpButton)?.titleOfSelectedItem,
                    "Pointing hand")
            t.check(seen.contains("Turns its text back to its usual color"), "Pointer leaves reads as a sentence")
            t.check(!seen.contains { $0.contains("More") && $0.first?.isNumber == true }, "no unexplained “14 More”")
            // Numbers and words in the system font, not the code font.
            t.equal(ValueField("100").font?.isFixedPitch, false)
            t.equal(ValueField("(#A# + 1)", monospaced: true).font?.isFixedPitch, true, "a calculation stays code")
        }

        t.suite("App: review fixes: the pointer pick is written when a look turns the pointer off") {
            let ini = """
            [Rainmeter]
            Update=1000

            [Quiet]
            MouseActionCursor=0
            MouseActionCursorName=TEXT

            [Styled]
            Meter=String
            MeterStyle=Quiet
            Text=Hi
            LeftMouseUpAction=["https://example.com"]

            [Own]
            Meter=String
            Y=20
            Text=Yo
            MouseActionCursor=0
            LeftMouseUpAction=["https://example.com"]

            """
            guard let (_, editor) = try FriendlyWidgetPageSelfTests.openScratch(t, files: ["Ptr/Ptr.ini": ini], config: "Ptr"),
                  let file = editor.skin?.fileURL else { return }
            func pick(_ section: String, _ value: String) {
                editor.select(section: section)
                editor.openMore("When Clicked")
                t.check(FriendlyWidgetPageSelfTests.choose(FriendlyWidgetPageSelfTests.find(editor, "\(section)/pointer")
                                                           as? NSPopUpButton, value), "\(section) has the pointer pop-up")
                settle()
            }
            // The look says Arrow (and TEXT): picking the pointing hand writes both back explicitly in the layer.
            pick("Styled", "HAND")
            let styled = IniDocument.parse(read(file)).section(named: "Styled")
            t.equal(styled?.value(forKey: "MouseActionCursor"), "1", "on again, although the look turns it off")
            t.equal(styled?.value(forKey: "MouseActionCursorName"), "HAND", "the hand, although the look says TEXT")
            t.equal(editor.skin?.meter(named: "Styled")?.rawOption("MouseActionCursor"), "1")
            // The layer's own Arrow, no look: the default comes back by removing the key.
            pick("Own", "HAND")
            let own = IniDocument.parse(read(file)).section(named: "Own")
            t.equal(own?.value(forKey: "MouseActionCursor"), nil, "its own 0 removed")
            t.equal(own?.value(forKey: "MouseActionCursorName"), nil, "HAND is the default: nothing written")
        }

        t.suite("App: review fixes: dial, clock hand and bar pages speak plainly") {
            guard let (_, gauges) = try FriendlyFixtures.openEditor(t, config: "Round\\Gauges") else { return }
            gauges.select(section: "GaugeNeedle")
            gauges.openMore("Dial")
            let dial = words(gauges)
            t.check(dial.contains("Center X") && dial.contains("Center Y"), "one clear label each")
            t.check(!dial.contains("Use the camera's orientation") && !dial.contains("Picture folder"), "\(dial)")
            t.check(!dial.contains { $0.contains("#CURRENTPATH") }, "the picture by its file name")
            guard let (_, clock) = try FriendlyFixtures.openEditor(t, config: "Round\\AnalogClock") else { return }
            clock.select(section: "MeterHourHand")
            t.check(!words(clock).contains { $0.contains("less than 0") }, "a negative start is allowed: no warning")
            guard let (_, system) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins") else { return }
            system.select(section: "MeterRAMBar")
            let parts = words(system)
            t.check(parts.contains { $0.hasSuffix("— track (empty part)") } && parts.contains { $0.hasSuffix("— fill") }, "\(parts)")
            t.equal((FriendlyWidgetPageSelfTests.find(system, "part-Shape2") as? NSButton)?.font?.fontDescriptor.symbolicTraits
                        .contains(.bold), true, "the fill, what one sees, is the part shown")
            system.addShape(.rectangle, meter: "MeterRAMBar")
            settle()
            t.equal(system.toast.text, "Added a rectangle", "no option name in the toast")
        }

        t.suite("App: review fixes: a picture from live data, and what a widget is missing") {
            guard let (_, player) = try FriendlyFixtures.openEditor(t, config: "MediaUI\\NowPlaying") else { return }
            player.select(section: "MeterCover")
            t.check(words(player).contains("Picture from"), "where the picture comes from is its first row")
            guard let (_, editor, _) = try openSuite(t, [
                "A/A.ini": "[Variables]\n@Include=#@#Panel.inc\n[Box]\nMeter=Shape\nMeterStyle=StylePanel\n"
                    + "[T]\nMeter=String\nText=Hi\n",
            ]) else { return }
            editor.canvasSelectionChanged([])
            let lines = words(editor).filter { $0.hasPrefix("A file this widget needs") || $0.hasPrefix("The look") }
            t.equal(lines.count, 2, "the missing file and the missing look, in words: \(lines)")
            t.check(lines.contains { $0.contains("Panel.inc") })
        }
    }

    // MARK: Shared values, looks and widget settings

    static func sharedWriteTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: a linked size edited from a layer stays in this widget") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let skin = editor.skin else { return }
            let shared = skin.resourcesDirectory.appendingPathComponent("Variables.inc")
            let before = read(shared)
            editor.select(section: "MeterCPULabel")
            // "Change ‘Padding’ for All 12 Layers…" on the X tag, then 30 typed: the field commits.
            let id = "MeterCPULabel/X"
            editor.inspectorState.disclosures.insert("shared/\(id.lowercased())")
            editor.rebuildInspector()
            guard let field = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == id }) as? GeometryField else {
                return t.check(false, "the shared value's editor")
            }
            field.onCommit?("30")
            settle()
            t.equal(read(shared), before, "the file every Deskset widget reads is untouched")
            t.check(FriendlyWidgetPageSelfTests.section("Variables", in: read(skin.fileURL)).contains("Padding=30"),
                    "System's own [Variables] holds the new value")
            t.equal(app.activate(config: "Deskset\\Network", file: nil)?.skin.variable("Padding"), "18", "Network keeps its padding")
            t.equal(editor.skin?.variable("Padding"), "30")
        }

        t.suite("App: review fixes: All Widgets after a This Widget edit changes the theme, and the own value goes") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let skin = editor.skin else { return }
            let dark = skin.resourcesDirectory.appendingPathComponent("Themes/Dark.inc")
            editor.appliesToAllWidgets = false
            t.check(editor.writeSharedValues([("TextColor", "255,0,0,255")], undoName: "Change Main Text", toast: "Main text changed"))
            settle()
            t.check(FriendlyWidgetPageSelfTests.section("Variables", in: read(skin.fileURL)).contains("TextColor=255,0,0,255"))
            // The row offers the theme's color back: one step, then undone.
            if let reloaded = editor.skin,
               let group = editor.valueUsages(reloaded).colorGroups().first(where: { $0.variables.contains("TextColor") }),
               let back = editor.colorRowMenu(group).items.first(where: { $0.identifier?.rawValue == "use-theme-color" }) as? ClosureMenuItem {
                _ = back.target?.perform(back.action)
                settle()
                t.check(!FriendlyWidgetPageSelfTests.section("Variables", in: read(skin.fileURL)).contains("TextColor="),
                        "Use the Theme's Color removes System's own value")
                editor.window?.undoManager?.undo()
                settle()
            } else {
                t.check(false, "Use the Theme's Color")
            }
            editor.appliesToAllWidgets = true
            t.check(editor.writeSharedValues([("TextColor", "0,255,0,255")], undoName: "Change Main Text", toast: "Main text changed"))
            settle()
            t.check(read(dark).contains("TextColor=0,255,0,255"), "the theme's value changes")
            t.check(!FriendlyWidgetPageSelfTests.section("Variables", in: read(skin.fileURL)).contains("TextColor="),
                    "System's own value goes, so it follows the theme again")
            t.equal(editor.skin?.variable("TextColor"), "0,255,0,255")
            t.equal(app.activate(config: "Deskset\\Network", file: nil)?.skin.variable("TextColor"), "0,255,0,255")
            t.check(editor.toast.text.contains("in all"), "the toast states the reach: \(editor.toast.text)")
            editor.appliesToAllWidgets = false
        }

        t.suite("App: review fixes: a value this widget can't make its own is not reported as changed") {
            guard let (_, editor, root) = try openSuite(t, [
                "@Resources/Theme.inc": "[Variables]\nTextColor=255,255,255,255\n",
                "A/A.ini": "[Variables]\nSize=12\n[Rainmeter]\n@Include=#@#Theme.inc\n[T]\nMeter=String\nText=Hi\nFontColor=#TextColor#\n",
            ]) else { return }
            let before = read(root.appendingPathComponent("A/A.ini"))
            t.check(!editor.writeSharedValues([("TextColor", "255,0,0,255")], undoName: "Change Main Text", toast: "Main text changed"),
                    "the include read after [Variables] would still win")
            settle()
            t.equal(read(root.appendingPathComponent("A/A.ini")), before, "nothing is kept")
            t.equal(editor.toast.text, Editor.overrideLostMessage)
            t.equal(editor.window?.undoManager?.canUndo, false, "and there is nothing to undo")
        }

        t.suite("App: review fixes: a color written in a shared look changes for this widget, or for all") {
            guard let (app, editor, root) = try openSuite(t, [
                "@Resources/Styles.inc": "[StyleText]\nFontColor=200,100,50,255\nFontSize=10\n",
                "A/A.ini": "[Variables]\n@Include=#@#Styles.inc\n[T1]\nMeter=String\nMeterStyle=StyleText\nText=One\n"
                    + "[T2]\nMeter=String\nMeterStyle=StyleText\nText=Two\nY=20\n",
                "B/B.ini": "[Variables]\n@Include=#@#Styles.inc\n[T]\nMeter=String\nMeterStyle=StyleText\nText=B\n",
            ]) else { return }
            let styles = root.appendingPathComponent("@Resources/Styles.inc")
            let old = RGBA(r: 200, g: 100, b: 50)
            let blue = RGBA(r: 0, g: 0, b: 255)
            editor.appliesToAllWidgets = false
            t.check(editor.writeLiteralColor(old, to: blue, undoName: "Change Text Color", toast: "Text changed"))
            settle()
            t.check(!read(styles).contains("0,0,255"), "the shared look is untouched")
            t.check(FriendlyWidgetPageSelfTests.section("StyleText", in: read(root.appendingPathComponent("A/A.ini")))
                        .contains("FontColor=0,0,255,255"), "A has the look's color of its own")
            t.equal((editor.skin?.meter(named: "T1") as? StringMeter)?.style.color, blue, "and draws it")
            t.equal((app.activate(config: "Suite\\B", file: nil)?.skin.meter(named: "T") as? StringMeter)?.style.color, old)
            editor.appliesToAllWidgets = true
            t.check(editor.writeLiteralColor(blue, to: RGBA(r: 0, g: 255, b: 0), undoName: "Change Text Color",
                                             toast: "Text changed"))
            settle()
            t.check(!read(styles).contains("200,100,50"), "All Widgets rewrites the look in the shared file: \(read(styles))")
            editor.appliesToAllWidgets = false
        }

        t.suite("App: review fixes: widget settings a shared file makes stay in it") {
            guard let (app, editor, root) = try openSuite(t, [
                "@Resources/Common.inc": "[Rainmeter]\nUpdate=1000\nSkinWidth=150\nSkinHeight=80\n",
                "A/A.ini": "[Rainmeter]\n@Include=#@#Common.inc\n[T]\nMeter=String\nText=A\n",
                "B/B.ini": "[Rainmeter]\n@Include=#@#Common.inc\n[T]\nMeter=String\nText=B\n",
            ]) else { return }
            let common = root.appendingPathComponent("@Resources/Common.inc")
            let before = read(common)
            editor.writeUpdateSpeed(100)
            settle()
            t.equal(read(common), before, "Smooth writes nothing into the shared file")
            let a = read(root.appendingPathComponent("A/A.ini"))
            t.check(a.contains("@Include=#@#Common.inc\nUpdate=100") || a.contains("@Include=#@#Common.inc\r\nUpdate=100"),
                    "A's own Update, after its include: \(a)")
            t.equal(editor.skin?.settings.update, 100)
            editor.writeWidgetSettings([("SkinWidth", nil), ("SkinHeight", nil)], undoName: "Fit Widget to Its Content",
                                       toast: "The widget now fits its content")
            settle()
            t.equal(read(common), before, "Fits Its Content removes nothing from the shared file")
            t.check(read(root.appendingPathComponent("A/A.ini")).contains("SkinWidth=0"),
                    "A's own SkinWidth=0 (\"set to 0 it has no effect\") after its include")
            t.equal(editor.skin?.settings.skinWidth, nil, "A fits its content")
            t.equal(app.activate(config: "Suite\\B", file: nil)?.skin.settings.skinWidth, 150, "B keeps its fixed size")
        }
    }

    // MARK: Layers

    static func layerWriteTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: Fit Widget to Content on a fixed size keeps everything inside") {
            guard let (_, editor, root) = try openSuite(t, [
                "A/A.ini": "[Rainmeter]\nSkinWidth=200\nSkinHeight=100\n[Background]\nMeter=Image\nSolidColor=20,20,20,255\n"
                    + "W=200\nH=100\n[Title]\nMeter=String\nText=Hello\nX=-20\nY=10\nFontColor=255,255,255,255\n",
            ]) else { return }
            editor.fitWidgetToContent()
            settle()
            let text = read(root.appendingPathComponent("A/A.ini"))
            t.check(text.contains("SkinWidth=220"), "the fixed width grows by what moved: \(text)")
            t.equal(editor.cutOffLayers().map(\.name), [], "nothing is cut off on the right instead")
        }

        t.suite("App: review fixes: several layers are each written in their own file") {
            guard let (_, editor, root) = try openSuite(t, [
                "A/Parts.inc": "[TA]\nMeter=String\nText=A\nFontSize=10\n",
                "A/A.ini": "[Variables]\n@Include=#CURRENTPATH#Parts.inc\n[TB]\nMeter=String\nText=B\nY=20\nFontSize=10\n",
            ]) else { return }
            editor.canvasSelectionChanged(["TA", "TB"])
            editor.writeSeveral("FontSize", value: "20", sections: ["TA", "TB"], label: "Size")
            settle()
            let parts = read(root.appendingPathComponent("A/Parts.inc"))
            t.check(parts.contains("FontSize=20") && !parts.contains("[TB]"), "A in its file, no stray [TB]: \(parts)")
            t.equal(editor.skin?.meter(named: "TB")?.option("FontSize"), "20", "B changes too")
        }

        t.suite("App: review fixes: layers a shared file defines are never moved from one widget") {
            guard let (_, editor, root) = try openSuite(t, [
                "@Resources/Shine.inc": "[Shine]\nMeter=Image\nSolidColor=255,255,255,40\nX=0\nY=0\nW=40\nH=10\n",
                "A/A.ini": "[Variables]\n@Include=#@#Shine.inc\n[Body]\nMeter=Image\nSolidColor=0,0,0,255\nX=-10\nY=12\nW=60\nH=20\n",
                "B/B.ini": "[Variables]\n@Include=#@#Shine.inc\n[Other]\nMeter=String\nText=B\n",
            ]) else { return }
            let shine = root.appendingPathComponent("@Resources/Shine.inc")
            let before = read(shine)
            editor.fitWidgetToContent()
            settle()
            t.equal(read(shine), before, "Fit Widget to Content does not rewrite the shared layer")
            t.check(editor.toast.text.contains("other widgets share"), editor.toast.text)
            editor.commit([Editor.Edit(section: "Shine", key: "X", value: "8", own: true)], name: "Move “Shine”")
            settle()
            t.equal(read(shine), before, "a drag of it writes nothing there either")
            t.check(editor.toast.text.contains("other widgets share"), editor.toast.text)
        }

        t.suite("App: review fixes: Apply to All 16 Bars means all 16") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let skin = editor.skin else { return }
            editor.select(section: "MeterBand3")
            editor.writeProperty(section: "MeterBand3", key: "BarColor", value: "255,0,0,255", variable: nil, label: "Fill",
                                 selection: ["MeterBand3"])
            settle()
            editor.select(section: "MeterBand6")
            editor.writeProperty(section: "MeterBand6", key: "BarColor", value: "0,255,0,255", variable: nil, label: "Fill",
                                 selection: ["MeterBand6"])
            settle()
            t.check(editor.chooseToastAction("Apply to All 16 Bars"), "the toast offers it: \(editor.toastActions.map(\.title))")
            settle()
            let text = read(skin.fileURL)
            t.check(!FriendlyWidgetPageSelfTests.section("MeterBand3", in: text).contains("BarColor"),
                    "Bar 4's own red goes too")
            t.equal(editor.skin?.meter(named: "MeterBand3")?.option("BarColor").flatMap(OptionValue.color), RGBA(r: 0, g: 255, b: 0))
        }
    }

    // MARK: Deleting

    static func deletionTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: data another widget uses is never deleted from here") {
            guard let (app, editor, root) = try openSuite(t, [
                "@Resources/Measures.inc": "[MeasureCPU]\nMeasure=CPU\n[MeasureRAM]\nMeasure=PhysicalMemory\n",
                "A/A.ini": "[Variables]\n@Include=#@#Measures.inc\n[T]\nMeter=String\nMeasureName=MeasureCPU\n",
                "B/B.ini": "[Variables]\n@Include=#@#Measures.inc\n[T]\nMeter=String\nMeasureName=MeasureRAM\n",
            ]) else { return }
            let measures = root.appendingPathComponent("@Resources/Measures.inc")
            let before = read(measures)
            editor.select(section: "MeasureRAM")
            t.check(FriendlyWidgetPageSelfTests.find(editor, "delete-data") == nil, "no Delete for it")
            t.equal(FriendlyWidgetPageSelfTests.text(editor, "shared-data"), "Also used by 1 other widget, so it can't be deleted here.")
            editor.deleteData(["MeasureRAM"])
            settle()
            t.equal(read(measures), before, "the shared file keeps it")
            t.check(app.activate(config: "Suite\\B", file: nil)?.skin.measure(named: "MeasureRAM") != nil, "B keeps it")
            t.equal(LayerMenu.makeData(for: ["MeasureRAM"], in: editor).items.first { $0.title == "Delete" }?.isEnabled, false)
        }
    }

    // MARK: The eye

    static func eyeTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: the eye keeps a Hidden that follows a setting") {
            guard let (_, editor, root) = try openSuite(t, [
                "A/A.ini": "[Variables]\nHideSeconds=0\n[Seconds]\nMeter=String\nText=:00\nHidden=#HideSeconds#\n"
                    + "[Other]\nMeter=String\nText=Always\nY=20\n",
            ]) else { return }
            let file = root.appendingPathComponent("A/A.ini")
            editor.setLayersHidden(["Seconds"], hidden: true)
            settle()
            t.check(FriendlyWidgetPageSelfTests.section("Seconds", in: read(file)).contains("Hidden=1"))
            editor.setLayersHidden(["Seconds"], hidden: false)
            settle()
            t.check(FriendlyWidgetPageSelfTests.section("Seconds", in: read(file)).contains("Hidden=#HideSeconds#"),
                    "Show puts the setting back: \(read(file))")
            t.equal(editor.skin?.meter(named: "Seconds")?.hidden, false)
            // Hidden by its own setting: Show asks first.
            try read(file).replacingOccurrences(of: "HideSeconds=0", with: "HideSeconds=1").write(to: file, atomically: true, encoding: .utf8)
            editor.refreshSkin()
            editor.setLayersHidden(["Seconds"], hidden: false)
            settle()
            t.check(read(file).contains("Hidden=#HideSeconds#"), "nothing overwritten")
            t.check(editor.toast.text.contains("follows the widget's own setting"), editor.toast.text)
            t.check(editor.chooseToastAction("Show It Anyway"))
            settle()
            t.check(FriendlyWidgetPageSelfTests.section("Seconds", in: read(file)).contains("Hidden=0"))
            // A layer with no Hidden of its own: hiding then showing leaves no key behind.
            editor.setLayersHidden(["Other"], hidden: true)
            settle()
            editor.setLayersHidden(["Other"], hidden: false)
            settle()
            t.check(!FriendlyWidgetPageSelfTests.section("Other", in: read(file)).contains("Hidden"), read(file))
        }
    }

    // MARK: Undo and the veil

    static func undoAndVeilTests(_ t: AppTestRunner) {
        t.suite("App: review fixes: a refused undo of Fit Widget to Content leaves the window where it is") {
            guard let (_, editor, root) = try openSuite(t, [
                "A/A.ini": "[Rainmeter]\n[Title]\nMeter=String\nText=Hello\nX=-10\nY=4\nFontColor=255,255,255,255\n",
            ]) else { return }
            guard let before = editor.controller?.topLeftPosition else { return t.check(false, "a window") }
            editor.fitWidgetToContent()
            settle()
            guard let moved = editor.controller?.topLeftPosition else { return t.check(false, "still a window") }
            t.equal(moved.x, before.x - 10, "the window moved left by what the layers moved right")
            let file = root.appendingPathComponent("A/A.ini")
            // The live timer would notice the outside edit and reload the widget (a slow machine can reach its next
            // tick within this test); only the refused undo is under test here.
            editor.liveTimer?.invalidate()
            try (read(file) + "; edited in another app\n").write(to: file, atomically: true, encoding: .utf8)
            editor.window?.undoManager?.undo()
            t.check(editor.toast.text.hasPrefix("Can't undo"), editor.toast.text)
            settle()
            t.equal(editor.controller?.topLeftPosition.x, moved.x, "the files stayed, so the window stays too")
        }

        t.suite("App: review fixes: a clicked Used By link takes its veil with it") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.selectSidebarTab(.data)
            editor.select(section: "MeasureBand5")
            guard let link = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "used-by-MeterBand5" }) as? HoverButton
            else { return t.check(false, "the link") }
            guard let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                                     userData: nil) else { return t.check(false, "an event") }
            link.mouseEntered(with: enter)
            t.equal(editor.canvas.hoverHighlight, ["MeterBand5"], "pointing veils the rest")
            link.performClick(nil)
            settle()
            t.equal(editor.canvas.hoverHighlight, [], "no veil left once the page changed")
        }
    }
}
