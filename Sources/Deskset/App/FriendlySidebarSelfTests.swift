import AppKit
import DesksetCore

/// `Deskset --self-test "Friendly sidebar"`: the sidebar of docs/editor-friendly.md §5 (WP-A) — the Add, Layers and
/// Live Data tabs: rows named by their content, groups of repeated layers, thumbnails, hover links, search, the layer
/// menu, the reorder guard.
enum FriendlySidebarSelfTests {
    static func run(_ t: AppTestRunner) {
        fakeDeviceTests(t)
        seamTests(t)
        layerListTests(t)
        rowLookTests(t)
        fitTests(t)
        wrapTests(t)
        groupTests(t)
        thumbnailTests(t)
        hoverAndSearchTests(t)
        menuAndLockTests(t)
        reorderTests(t)
        liveDataTests(t)
        dataUseTests(t)
        addTabTests(t)
    }

    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    /// The Visualizer open in the editor, its device named the same everywhere (`FriendlyFixtures.fakeDevice`).
    static func visualizer(_ t: AppTestRunner) throws -> (app: AppController, editor: InspectorWindowController)? {
        guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return nil }
        editor.selectSidebarTab(.layers)
        return (app, editor)
    }

    /// `FriendlyFixtures.fakeDevice` holds for the whole suite (a refresh makes a new skin) and ends with it.
    static func fakeDeviceTests(_ t: AppTestRunner) {
        // For these two suites, a Mac without audio devices, whatever this one has.
        let saved = AudioLevelMeasure.sharedSystem
        defer { AudioLevelMeasure.sharedSystem = saved }
        AudioLevelMeasure.sharedSystem = { AudioSystemSnapshot(loaded: true) }
        t.suite("App: friendly sidebar: the fake output device outlasts refreshes") {
            guard let (app, _) = try visualizer(t), let before = app.controller(for: "Audio\\Visualizer") else { return }
            func device() -> String? {
                app.controller(for: "Audio\\Visualizer")?.skin?.measure(named: "MeasureDevice")?.stringValue
            }
            t.equal(device(), "MacBook Pro扬声器", "as the widget loads")
            app.refresh(before)
            t.check(app.controller(for: "Audio\\Visualizer")?.skin !== before.skin, "the refresh made a new skin")
            t.equal(device(), "MacBook Pro扬声器", "after a refresh")
        }
        t.suite("App: friendly sidebar: the fake output device ends with its suite") {
            t.equal(AudioLevelMeasure.sharedSystem().devices.count, 0, "the Mac's devices are back")
        }
    }

    static func cell(_ editor: InspectorWindowController, _ item: InspectorWindowController.Item?) -> LayerCell? {
        guard let item else { return nil }
        let row = editor.outline.row(forItem: item)
        return row >= 0 ? editor.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerCell : nil
    }

    static func rowView(_ editor: InspectorWindowController, _ item: InspectorWindowController.Item?) -> LayerRowView? {
        guard let item else { return nil }
        let row = editor.outline.row(forItem: item)
        return row >= 0 ? editor.outline.rowView(atRow: row, makeIfNecessary: true) as? LayerRowView : nil
    }

    /// The top-level row of a section or run (by its first member).
    static func row(_ editor: InspectorWindowController, _ name: String) -> InspectorWindowController.Item? {
        editor.listItems.first { $0.title.caseInsensitiveCompare(name) == .orderedSame && !$0.isGroup && !$0.isSkin }
    }

    /// The seams the sidebar is built on (step 0 of the friendly studio).
    static func seamTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: rows show their sections through their items") {
            guard let (app, editor) = try visualizer(t) else { return }
            guard let title = editor.layerItems.first(where: { $0.title == "MeterTitle" }) else {
                return t.check(false, "the title has a row")
            }
            t.equal(title.display, "“Audio”")
            t.equal(title.subtitle, "Text")
            t.equal(title.symbol, "textformat")
            t.equal(title.seriesMembers, nil)
            t.equal([title.isLocked, title.isCutOff], [false, false])
            t.equal(editor.displayName(ofSection: "metertitle"), "“Audio”")
            t.equal(cell(editor, title)?.textField?.stringValue, "“Audio”", "the row shows the item's name")

            editor.selectSidebarTab(.data)
            let band = editor.allItems.first { $0.title == "MeasureBand5" }
            t.equal(band?.display, "Sound band 6")
            t.equal(band?.subtitle, "Used by Bar 6")
            t.check(band?.symbol != nil)

            // A lock is editor state (state.json), never written to the skin.
            guard let file = editor.skin?.fileURL else { return t.check(false, "skin") }
            let bytes = try Data(contentsOf: file)
            app.state.updateEditor { $0.editorLocks["audio\\visualizer"] = ["metertitle"] }
            editor.rebuildSidebar()
            t.check(editor.isLayerLocked("MeterTitle") && !editor.isLayerLocked("MeterDevice"))
            t.equal(editor.allItems.first { $0.title == "MeterTitle" }?.isLocked, true)
            t.equal(try Data(contentsOf: file), bytes)

            // The canvas reports the layer under the pointer to the sidebar.
            t.check(editor.canvas.onHoverChange != nil)
        }
    }

    // MARK: Layers

    static func layerListTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: the Visualizer's layers as a user sees them") {
            guard let (_, editor) = try visualizer(t) else { return }
            let rows = editor.listItems.filter { !$0.isGroup }
            t.equal(rows.count, 12, "11 layer rows and the widget row instead of 26")
            t.equal(rows.map(\.display), ["Audio Visualizer", "Peak marker", "Right channel bar", "“R”", "Left channel bar",
                                         "“L”", "“13268 Hz”", "“48 Hz”", "16 bars", "“MacBook Pro扬声器”", "“Audio”",
                                         "Background"])
            t.equal(rows.map(\.subtitle), ["Whole widget · 217 × 196", "Color block · moves with peak level",
                                          "Bar · right channel level", "Text", "Bar · left channel level", "Text",
                                          "Text · highest band frequency", "Text · lowest band frequency",
                                          "Bar · sound bands 1–16", "Text · output device name", "Text",
                                          "Rounded rectangle · whole widget"])
            t.equal(editor.listItems.filter(\.isGroup).map(\.display), ["FRONT", "BACK"])
            t.equal(editor.listItems.firstIndex { $0.display == "FRONT" }, 1, "FRONT above the front layer")
            t.equal(editor.listItems.firstIndex { $0.display == "BACK" }, editor.listItems.count - 2, "BACK above the last")
            let sections = Set((editor.skin?.meters.map { $0.name.lowercased() } ?? []))
            t.check(!rows.contains { sections.contains($0.display.lowercased()) }, "no row title is a section name")
            t.equal(editor.outline.selectedRowIndexes, IndexSet(integer: 0), "the widget row shows the widget is selected")

            // Background: detected, locked in the editor (never in the file), shown with a lock.
            guard let background = row(editor, "MeterBackground") else { return t.check(false, "Background row") }
            t.check(background.isLocked, "the Background is locked")
            t.equal(cell(editor, background)?.lock.isHidden, false, "its lock shows")
            t.equal(cell(editor, row(editor, "MeterTitle"))?.lock.isHidden, true, "an unlocked layer shows no lock")

            // Rainmeter Details: the section joins the second line.
            editor.app.state.updateEditor { $0.showIniNames = true }
            editor.rebuildSidebar()
            t.equal(row(editor, "MeterTitle")?.subtitle, "Text · MeterTitle")
            editor.app.state.updateEditor { $0.showIniNames = false }
            editor.rebuildSidebar()
            t.equal(row(editor, "MeterTitle")?.subtitle, "Text")

            // Tooltips and accessibility.
            t.equal(cell(editor, row(editor, "MeterTitle"))?.toolTip, "MeterTitle — double-click to type")
            t.equal(cell(editor, row(editor, "MeterLowFreq"))?.toolTip, "MeterLowFreq")
            t.equal(cell(editor, row(editor, "MeterTitle"))?.accessibilityLabel(), "“Audio”, Text")
            t.equal(editor.tabControl.label(forSegment: 0), "Add")
            t.equal(editor.tabControl.label(forSegment: 2), "Live Data")
        }

        t.suite("App: friendly sidebar: an empty widget says what to do") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("Empty/Blank")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "[Rainmeter]\nUpdate=1000\n".write(to: folder.appendingPathComponent("Blank.ini"), atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let c = app.activate(config: "Empty\\Blank", file: nil) else { return t.check(false, "loads") }
            app.showInspector(for: c)
            guard let editor = app.inspector else { return t.check(false, "editor") }
            editor.selectSidebarTab(.layers)
            t.equal(editor.sidebar.emptyState.isHidden, false)
            t.equal(editor.sidebar.emptyState.label.stringValue, "Nothing here yet. Drag something from Add onto your widget.")
            t.equal(editor.sidebar.emptyState.button.title, "Open Add")
            editor.emptyStateButtonClicked()
            t.equal(editor.sidebarTab, .library, "Open Add opens Add")
            editor.selectSidebarTab(.data)
            t.equal(editor.sidebar.emptyState.label.stringValue,
                    "Live data brings numbers into your widget — CPU, memory, network speed, battery, time and more.")
            t.equal(editor.sidebar.emptyState.note.stringValue, "Most things in Add already come with their live data.")
            t.equal(editor.sidebar.emptyState.menuButton.isHidden, false, "+ Add Live Data")
            editor.window?.close()
        }
    }

    /// The selected row reads: a light accent tint, the name in its normal color (the source list's emphasized
    /// selection was a black bar off-screen).
    static func rowLookTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: the selected row is light and its name readable") {
            guard let (_, editor) = try visualizer(t) else { return }
            editor.select(section: "MeterTitle")
            guard let title = row(editor, "MeterTitle"), let view = rowView(editor, title), let cell = cell(editor, title)
            else { return t.check(false, "the title's row") }
            t.check(view.isSelected, "the row is selected")
            for dark in [false, true] {
                editor.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                editor.window?.contentView?.layoutSubtreeIfNeeded()
                // The sidebar material's stand-in (as in snapshots), under the row's own drawing without its content.
                let base = dark ? (0.17, 0.17, 0.17) : (0.925, 0.922, 0.918)
                cell.isHidden = true
                defer { cell.isHidden = false }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return t.check(false, "bitmap") }
                view.cacheDisplay(in: view.bounds, to: rep)
                let tint = view.tintRect
                var sum = 0.0, count = 0.0
                var background = (0.0, 0.0, 0.0)
                let sx = Double(rep.pixelsWide) / Double(view.bounds.width), sy = Double(rep.pixelsHigh) / Double(view.bounds.height)
                for y in stride(from: Int(tint.minY * sy) + 4, to: Int(tint.maxY * sy) - 4, by: 2) {
                    for x in stride(from: Int(tint.minX * sx) + 8, to: Int(tint.maxX * sx) - 8, by: 3) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        let a = Double(c.alphaComponent)
                        let rgb = (Double(c.redComponent) * a + base.0 * (1 - a), Double(c.greenComponent) * a + base.1 * (1 - a),
                                   Double(c.blueComponent) * a + base.2 * (1 - a))
                        sum += 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
                        count += 1
                        background = rgb
                    }
                }
                let mean = count > 0 ? sum / count : 0
                if !dark { t.check(mean > 0.6, "light mode: the selected row is light (mean luma \(mean))") }
                var text = (0.0, 0.0, 0.0), alpha = 1.0
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let c = (cell.textField?.textColor ?? .labelColor).usingColorSpace(.sRGB) ?? .black
                    text = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                    alpha = Double(c.alphaComponent)
                }
                let shown = (text.0 * alpha + background.0 * (1 - alpha), text.1 * alpha + background.1 * (1 - alpha),
                             text.2 * alpha + background.2 * (1 - alpha))
                let ratio = contrast(shown, background)
                t.check(ratio >= 4.5, "\(dark ? "dark" : "light") mode: the name contrasts \(ratio):1 with the selection")
            }
            editor.window?.appearance = nil
        }
    }

    /// WCAG contrast ratio of two sRGB colors.
    static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (Double, Double, Double)) -> Double {
            0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
        }
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    // MARK: Groups

    static func groupTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: 16 bars fold into one row") {
            guard let (app, editor) = try visualizer(t), let file = editor.skin?.fileURL else { return }
            func skin() -> Skin? { app.controller(for: "Audio\\Visualizer")?.skin }
            guard let group = row(editor, "MeterBand0") else { return t.check(false, "the group row") }
            t.equal(group.seriesMembers, (0...15).map { "MeterBand\($0)" })
            t.equal(group.children.map(\.display), (1...16).map { "Bar \($0)" }, "members in file order, 1-based")
            t.equal(group.children.first?.subtitle, "Sound band 1 of 16 (lowest)")
            t.equal(editor.outline.isItemExpanded(group), false, "closed at first")

            // Clicking the row selects all 16.
            editor.outline.selectRowIndexes(IndexSet(integer: editor.outline.row(forItem: group)), byExtendingSelection: false)
            t.equal(editor.canvas.selectedNames.count, 16)
            t.equal(Set(editor.selectedMeters), Set(group.seriesMembers ?? []))

            // The eye hides all 16 as one step; ⌘Z restores the bytes.
            let before = try Data(contentsOf: file)
            guard let eye = cell(editor, row(editor, "MeterBand0"))?.eye else { return t.check(false, "eye") }
            editor.eyeClicked(eye)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            t.equal(text.components(separatedBy: "Hidden=1").count - 1, 16, "16 × Hidden=1")
            t.equal(skin()?.meters.filter { $0.name.hasPrefix("MeterBand") && $0.hidden }.count, 16)
            t.equal(editor.window?.undoManager?.undoActionName, "Hide 16 Bars")
            t.equal(editor.toastText, "Hid 16 bars")
            t.equal(cell(editor, row(editor, "MeterBand0"))?.isLayerHidden, true, "the row shows an eye-slash")
            t.equal(cell(editor, row(editor, "MeterBand0"))?.contentAlpha, 0.45, "and is dimmed")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before, "one undo step")

            // Selecting a member (a double-click on the canvas) opens the group and highlights the member.
            editor.select(section: "MeterBand5")
            guard let reopened = row(editor, "MeterBand0") else { return t.check(false, "group") }
            t.check(editor.outline.isItemExpanded(reopened), "the group opens")
            let selected = editor.outline.selectedRowIndexes.compactMap { editor.outline.item(atRow: $0) as? InspectorWindowController.Item }
            t.equal(selected.map(\.display), ["Bar 6"])
            // Remembered per widget: still open after a refresh.
            editor.rebuildSidebar()
            t.check(row(editor, "MeterBand0").map(editor.outline.isItemExpanded) ?? false, "still open after a refresh")

            // Show as Separate Rows (remembered), and back.
            guard let run = editor.sidebar.catalog?.series(containing: "MeterBand0") else { return t.check(false, "run") }
            editor.setShownSeparately(run, true)
            t.equal(editor.layerItems.count, 26, "every layer its own row")
            t.equal(row(editor, "MeterBand5")?.display, "Bar 6")
            editor.rebuildSidebar()
            t.equal(editor.layerItems.count, 26, "remembered")
            editor.setShownSeparately(run, false)
            t.equal(editor.layerItems.count, 11)
        }
    }

    // MARK: Thumbnails

    static func thumbnailTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: pictures of the layers") {
            guard let (_, editor) = try visualizer(t), let skin = editor.skin else { return }
            let thumbnails = editor.sidebar.thumbnails
            // The rows on screen (a window that is not on screen lays them out when asked).
            let rows = editor.outline.rows(in: editor.outline.visibleRect)
            for r in rows.lowerBound..<rows.upperBound { _ = editor.outline.view(atColumn: 0, row: r, makeIfNecessary: true) }
            // On every tick, a picture on screen is drawn at most once, and only when what it shows changed.
            thumbnails.removeAll()
            let before = thumbnails.renderCount
            editor.tick()
            let drawn = thumbnails.renderCount - before
            let visible = rows.length
            t.check(drawn > 0 && drawn <= visible, "pictures on screen drawn: \(drawn) of \(visible) rows")
            t.equal(drawn, thumbnails.rendersThisPass, "each at most once in the tick")
            editor.tick()
            t.equal(thumbnails.renderCount - before, drawn, "nothing changed: nothing drawn again")

            // Each layer is its real pixels, cropped and scaled — quickly.
            let panel = editor.panelColor(for: skin)
            // This thread's CPU time, best of 5, so time spent waiting for a core on a busy CI runner does not count.
            // About 1 ms in a debug build on a fast Mac; the bound leaves room for a slow CI runner.
            var best = Double.infinity
            for _ in 0..<5 {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                for m in skin.meters { _ = LayerThumbnails.render([m], panel: panel) }
                best = min(best, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9)
            }
            t.equal(skin.meters.count, 26)
            t.check(best < 0.25, "26 layers in \(String(format: "%.1f", best * 1000)) ms of CPU time")
            let title = LayerThumbnails.render([skin.meter(named: "MeterTitle")!], panel: panel)
            t.equal(title?.size, LayerThumbnails.size)
            // Thin layers get a symbol instead of a speck.
            t.check(LayerThumbnails.usesGlyph([skin.meter(named: "MeterPeak")!]), "the Peak marker uses a glyph")
            t.check(!LayerThumbnails.usesGlyph([skin.meter(named: "MeterTitle")!]), "the title is pixels")
            // The panel color is the Background's fill (dark), not the canvas's light backdrop.
            let rgb = panel.usingColorSpace(.sRGB)
            t.check((rgb?.brightnessComponent ?? 1) < 0.3, "drawn on the widget's dark panel")
            t.check(cell(editor, row(editor, "MeterTitle"))?.thumbnail.image != nil, "the row has its picture")

            // The whole widget's picture follows each update (at most once per tick).
            thumbnails.beginPass()
            _ = thumbnails.widgetThumbnail(of: skin, panel: panel, dark: false)
            let widgetRenders = thumbnails.renderCount
            _ = thumbnails.widgetThumbnail(of: skin, panel: panel, dark: false)
            t.equal(thumbnails.renderCount, widgetRenders, "the same update: the same picture")
            skin.update()
            thumbnails.beginPass()
            _ = thumbnails.widgetThumbnail(of: skin, panel: panel, dark: false)
            t.equal(thumbnails.renderCount, widgetRenders + 1, "drawn again after an update")
            // Colors a running widget changes (`!SetOption` from an IfTrueAction) draw the picture again.
            guard let title = skin.meter(named: "MeterTitle") else { return t.check(false, "title") }
            let colored = LayerThumbnails.signature(of: [title], in: skin, panel: panel, dark: false)
            skin.execute("[!SetOption MeterTitle FontColor 255,0,0]", from: nil)
            skin.update()
            t.check(LayerThumbnails.signature(of: [title], in: skin, panel: panel, dark: false) != colored,
                    "a new color is a new picture")
        }

        t.suite("App: friendly sidebar: hidden layers keep a picture") {
            guard let (app, editor) = try openWidget(t, probe), let skin = editor.skin else { return }
            editor.selectSidebarTab(.layers)
            let panel = editor.panelColor(for: skin)
            // Hidden from the start: its kind in its own color (a hidden layer has no size to draw).
            t.equal(cell(editor, row(editor, "MeterNext"))?.thumbnail.image?.tiffRepresentation,
                    LayerThumbnails.glyph(for: skin.meter(named: "MeterNext"), panel: panel)?.tiffRepresentation,
                    "the text symbol, not an empty square")
            // Hidden from its row: the picture it had.
            guard let shown = cell(editor, row(editor, "MeterText"))?.thumbnail.image else { return t.check(false, "picture") }
            editor.setLayersHidden(["MeterText"], hidden: true)
            t.check(editor.skin !== skin, "the widget reloaded")
            t.check(cell(editor, row(editor, "MeterText"))?.thumbnail.image === shown, "the picture it had while shown")
            t.check(editor.sidebar.thumbnailSkin === editor.skin, "pictures of the old skin are not kept")
            // Another widget: the kept pictures go.
            guard let other = app.activate(config: "Deskset\\Clock", file: nil) else { return t.check(false, "Clock") }
            app.showInspector(for: other)
            t.equal(editor.sidebar.thumbnailConfig, "deskset\\clock")
        }
    }

    // MARK: Hover and search

    static func hoverAndSearchTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: hover links the list and the canvas") {
            guard let (_, editor) = try visualizer(t) else { return }
            editor.select(section: "MeterTitle")
            let rebuilds = editor.inspectorRebuildCount
            guard let device = rowView(editor, row(editor, "MeterDevice")) else { return t.check(false, "device row") }
            device.setHovered(true)
            t.equal(editor.canvas.hoverHighlight, ["MeterDevice"], "the row's layer is outlined")
            t.equal(cell(editor, row(editor, "MeterDevice"))?.eye.isHidden, false, "the eye shows on hover")
            t.equal(cell(editor, row(editor, "MeterDevice"))?.lock.isHidden, false, "and the lock")
            t.equal(editor.inspectorRebuildCount, rebuilds, "nothing else changes")
            device.setHovered(false)
            t.equal(editor.canvas.hoverHighlight, [])
            t.equal(cell(editor, row(editor, "MeterDevice"))?.eye.isHidden, true)
            rowView(editor, row(editor, "MeterBand0"))?.setHovered(true)
            t.equal(editor.canvas.hoverHighlight.count, 16, "a group row outlines all 16")
            rowView(editor, row(editor, "MeterBand0"))?.setHovered(false)

            // The canvas's hover tints the row (a closed group's row for a member).
            editor.layerHoverChanged("MeterTitle")
            t.equal(rowView(editor, row(editor, "MeterTitle"))?.isLinkedHover, true)
            t.equal(rowView(editor, row(editor, "MeterDevice"))?.isLinkedHover, false)
            editor.layerHoverChanged("MeterBand3")
            t.equal(rowView(editor, row(editor, "MeterBand0"))?.isLinkedHover, true)
            t.equal(rowView(editor, row(editor, "MeterTitle"))?.isLinkedHover, false)
            editor.layerHoverChanged(nil)
            t.equal(rowView(editor, row(editor, "MeterBand0"))?.isLinkedHover, false)
        }

        t.suite("App: friendly sidebar: hover survives the list reloading under the pointer") {
            guard let (_, editor) = try visualizer(t) else { return }
            guard let device = rowView(editor, row(editor, "MeterDevice")),
                  let eye = cell(editor, row(editor, "MeterDevice"))?.eye else { return t.check(false, "device row") }
            device.setHovered(true)
            t.equal(editor.canvas.hoverHighlight, ["MeterDevice"])
            // Its eye hides the layer: the list is made again under the pointer.
            editor.eyeClicked(eye)
            t.equal(editor.skin?.meter(named: "MeterDevice")?.hidden, true)
            t.equal(editor.canvas.hoverHighlight, [], "no outline left behind (the pointer is not over this window)")
            let rows = 0..<editor.outline.numberOfRows
            t.equal(rows.filter { (editor.outline.rowView(atRow: $0, makeIfNecessary: true) as? LayerRowView)?.isHovered == true },
                    [], "no row keeps a hover")
            t.equal(rows.filter { (editor.outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? LayerCell)?.isHovered == true },
                    [], "no row shows the toggles")
            // With the pointer over its row, the row gets its hover back.
            guard let item = row(editor, "MeterDevice") else { return t.check(false, "device row") }
            let rect = editor.outline.rect(ofRow: editor.outline.row(forItem: item))
            editor.restoreListHover(at: editor.outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
            t.equal(editor.canvas.hoverHighlight, ["MeterDevice"])
            t.equal(rowView(editor, item)?.isHovered, true)
            t.equal(cell(editor, item)?.eye.isHidden, false, "its toggles show again")
            // Onto the next row: the first row's late exit leaves the next one's outline.
            guard let title = rowView(editor, row(editor, "MeterTitle")) else { return t.check(false, "title row") }
            title.setHovered(true)
            rowView(editor, item)?.setHovered(false)
            t.equal(editor.canvas.hoverHighlight, ["MeterTitle"])
            t.equal(cell(editor, item)?.eye.isHidden, false, "a hidden layer keeps its eye-slash")
            t.equal(cell(editor, item)?.lock.isHidden, true, "but no lock toggle")
            title.setHovered(false)
            t.equal(editor.canvas.hoverHighlight, [])
            // A row reused while the pointer is over it lets go of what its hover showed.
            let reused = LayerRowView()
            var heard: [Bool] = []
            reused.onHover = { heard.append($0) }
            reused.setHovered(true)
            reused.prepareForReuse()
            t.equal(heard, [true, false])
            t.equal(reused.isHovered, false)
        }

        t.suite("App: friendly sidebar: find a layer") {
            guard let (_, editor) = try visualizer(t) else { return }
            editor.setSidebarSearch("MacBook")
            t.equal(editor.listItems.map(\.title), ["MeterDevice"], "one row: its text")
            t.equal(editor.layerDropOperation(hasLayers: true, proposedItem: nil, index: 0), [], "no reordering while filtered")
            t.equal(editor.sidebar.searchCaption.isHidden, false)
            t.equal(editor.sidebar.searchCaption.stringValue, "Clear the search to change the order.")
            t.check(editor.outlineView(editor.outline, pasteboardWriterForItem: editor.listItems[0]) == nil, "rows don't drag")
            editor.setSidebarSearch("picture")
            t.equal(editor.listItems.map(\.title), [], "kind words: no picture here")
            editor.setSidebarSearch("color block")
            t.equal(editor.listItems.map(\.title), ["MeterPeak"], "kind words")
            editor.setSidebarSearch("meterband1")
            t.equal(editor.listItems.count, 7, "section names (Band1, Band10…15)")
            editor.setSidebarSearch("hz")
            t.equal(editor.listItems.map(\.title), ["MeterHighFreq", "MeterLowFreq"])
            editor.setSidebarSearch("zzz")
            t.equal(editor.sidebar.emptyState.label.stringValue, "Nothing matches “zzz”.")
            editor.setSidebarSearch("")
            t.equal(editor.layerDropOperation(hasLayers: true, proposedItem: nil, index: 2), .move)
            t.equal(editor.sidebar.searchCaption.isHidden, true)
            t.check(editor.outlineView(editor.outline, pasteboardWriterForItem: row(editor, "MeterBand0")!) != nil,
                    "a group row drags as one")
            let member = row(editor, "MeterBand0")?.children.first
            t.check(member.map { editor.outlineView(editor.outline, pasteboardWriterForItem: $0) == nil } ?? false,
                    "members don't drag out of their group")
        }
    }

    // MARK: Menu and locks

    static func menuAndLockTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: the layer menu hides, duplicates, deletes and shows the code") {
            guard let (app, editor) = try visualizer(t), let file = editor.skin?.fileURL else { return }
            func current() -> Skin? { app.controller(for: "Audio\\Visualizer")?.skin }
            func choose(_ menu: NSMenu, _ title: String) {
                guard let item = menu.items.first(where: { $0.title == title }) else { return t.check(false, title) }
                _ = item.target?.perform(item.action)
            }
            let menu = LayerMenu.make(for: ["MeterTitle"], in: editor)
            t.equal(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                    ["Hide", "Lock", "Duplicate", "Delete", "Arrange", "Do Something When Clicked…", "Show in Code"])
            t.equal(menu.items.first { $0.title == "Arrange" }?.submenu?.items.map(\.title),
                    ["Bring to Front", "Bring Forward", "Send Backward", "Send to Back"])
            t.equal(LayerMenu.make(for: ["MeterBand5"], in: editor).items.first { $0.title.hasPrefix("Select All") }?.title,
                    "Select All 16 Bars")
            t.equal(LayerMenu.make(for: ["MeterLowFreq"], in: editor).items.first { $0.title.hasPrefix("Select All") }?.title,
                    "Select All 5 Small Texts")
            let runMenu = LayerMenu.make(for: (0...15).map { "MeterBand\($0)" }, in: editor,
                                         run: editor.sidebar.catalog?.series(containing: "MeterBand0"))
            t.check(runMenu.items.contains { $0.title == "Show as Separate Rows" }, "a group row adds Show as Separate Rows")

            let before = try Data(contentsOf: file)
            choose(menu, "Hide")
            t.equal(current()?.meter(named: "MeterTitle")?.hidden, true)
            t.equal(editor.window?.undoManager?.undoActionName, "Hide “Audio”")
            t.equal(editor.toastText, "Hid “Audio”")
            t.equal(LayerMenu.make(for: ["MeterTitle"], in: editor).items.first?.title, "Show")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before, "one undo step")

            choose(LayerMenu.make(for: ["MeterLeftLabel", "MeterRightLabel"], in: editor), "Hide")
            t.equal([current()?.meter(named: "MeterLeftLabel")?.hidden, current()?.meter(named: "MeterRightLabel")?.hidden],
                    [true, true])
            t.equal(editor.window?.undoManager?.undoActionName, "Hide 2 Texts", "counted by their kind (§10)")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before, "several layers: still one undo step")

            choose(LayerMenu.make(for: ["MeterDevice"], in: editor), "Delete")
            t.equal(current()?.meter(named: "MeterDevice") == nil, true, "deleted the menu's layer")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before)
            t.equal(LayerMenu.make(for: ["MeasureBand5"], in: editor).items.count, 0, "live data is not a layer")

            // Arrange ▸ Bring to Front.
            guard let arrange = LayerMenu.make(for: ["MeterTitle"], in: editor).items.first(where: { $0.title == "Arrange" })?
                .submenu else { return t.check(false, "Arrange") }
            choose(arrange, "Bring to Front")
            t.equal(current()?.meters.last?.name, "MeterTitle", "in front")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before)
            t.equal(LayerMenu.make(for: ["MeterPeak"], in: editor).items.first { $0.title == "Arrange" }?.submenu?.items
                        .first { $0.title == "Bring to Front" }?.isEnabled, false, "the front layer can't come further")
        }

        t.suite("App: friendly sidebar: locks are the editor's, and undo") {
            guard let (app, editor) = try visualizer(t), let file = editor.skin?.fileURL else { return }
            let bytes = try Data(contentsOf: file)
            let menu = LayerMenu.make(for: ["MeterTitle"], in: editor)
            guard let lock = menu.items.first(where: { $0.title == "Lock" }) else { return t.check(false, "Lock") }
            _ = lock.target?.perform(lock.action)
            t.check(editor.isLayerLocked("MeterTitle"))
            t.equal(app.state.editor.editorLocks["audio\\visualizer"], ["metertitle"])
            t.equal(editor.window?.undoManager?.undoActionName, "Lock “Audio”")
            t.equal(cell(editor, row(editor, "MeterTitle"))?.lock.isHidden, false, "the row shows the lock")
            t.equal(try Data(contentsOf: file), bytes, "nothing written to the widget")
            settle()
            editor.window?.undoManager?.undo()
            t.check(!editor.isLayerLocked("MeterTitle"), "undo unlocks")
            editor.window?.undoManager?.redo()
            t.check(editor.isLayerLocked("MeterTitle"), "redo locks again")
            settle()

            // The Background: locked until unlocked, which is remembered for the widget.
            t.check(editor.isLayerLocked("MeterBackground"))
            guard let lockButton = cell(editor, row(editor, "MeterBackground"))?.lock else { return t.check(false, "lock") }
            editor.lockClicked(lockButton)
            t.check(!editor.isLayerLocked("MeterBackground"), "unlocked")
            t.check(app.state.editor.unlockedBackgrounds.contains("audio\\visualizer"), "remembered")
            t.equal(editor.window?.undoManager?.undoActionName, "Unlock Background")
            editor.rebuildSidebar()
            t.check(!editor.isLayerLocked("MeterBackground"), "after a refresh too")
            settle()
            editor.window?.undoManager?.undo()
            t.check(editor.isLayerLocked("MeterBackground"), "undo locks it again")
            t.equal(try Data(contentsOf: file), bytes)
        }
    }

    // MARK: Reorder guard

    static func reorderTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: reordering keeps every layer where it is") {
            guard let (app, editor) = try visualizer(t), let file = editor.skin?.fileURL else { return }
            func current() -> Skin? { app.controller(for: "Audio\\Visualizer")?.skin }
            let frames = Dictionary(uniqueKeysWithValues: (current()?.meters ?? []).map { ($0.name, $0.frame) })
            let before = try Data(contentsOf: file)
            // Drag "48 Hz" to the top of the list.
            t.check(editor.moveLayer("MeterLowFreq", toListIndex: 1), "moved")
            t.equal(current()?.meters.last?.name, "MeterLowFreq", "in front")
            t.equal(current()?.meter(named: "MeterHighFreq")?.rawOption("Y"), "136", "“13268 Hz” got a fixed position")
            t.equal(editor.toastText, "Moved “48 Hz” to the front. “13268 Hz” now uses a fixed position, so nothing moved.")
            t.equal(editor.window?.undoManager?.undoActionName, "Move “48 Hz”")
            current()?.update()
            t.equal((current()?.meters ?? []).filter { !$0.name.hasPrefix("Meter") || frames[$0.name] != $0.frame }.map(\.name),
                    [], "every frame is unchanged")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before, "one undo step")

            // The group moves as a block, keeping its chain.
            guard let group = row(editor, "MeterBand0") else { return t.check(false, "group") }
            t.check(editor.moveLayers(group.seriesMembers ?? [], toListIndex: 1), "the 16 bars to the front")
            let order = current()?.meters.map(\.name) ?? []
            t.equal(Array(order.suffix(16)), (0...15).map { "MeterBand\($0)" }, "together, in their order")
            t.equal(current()?.meter(named: "MeterBand3")?.rawOption("X"), "#BarGap#R", "their chain is kept")
            t.equal(editor.toastText, "Moved 16 bars to the front.")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before)
            t.equal(editor.moveLayer("MeterPeak", toListIndex: 0), false, "already in front: nothing to do")
        }
    }

    // MARK: Live Data

    static func liveDataTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: live data, where the numbers come from") {
            guard let (app, editor) = try visualizer(t) else { return }
            editor.selectSidebarTab(.data)
            t.equal(editor.sidebar.explanation.stringValue, "Where the numbers and words in your widget come from.")
            t.equal(editor.sidebar.explanation.isHidden, false)
            t.equal(editor.listItems.map(\.display), ["Sound from your Mac", "Peak marker position"])
            guard let parent = editor.listItems.first else { return t.check(false, "parent") }
            t.equal(parent.children.map(\.display), ["16 sound bands", "Left channel level", "Right channel level", "Peak level",
                                                     "Output device name", "Lowest band frequency", "Highest band frequency"])
            t.check(editor.outline.isItemExpanded(parent), "the parent is open")
            t.equal(editor.outline.numberOfRows, 9, "9 rows instead of 24")
            func value(_ name: String) -> String? {
                editor.sidebarItem(forSection: name).flatMap { cell(editor, $0)?.detail.stringValue }
            }
            t.equal(value("MeasureLowFreq"), "48 Hz")
            t.equal(value("MeasureHighFreq"), "13.3 kHz")
            t.equal(value("MeasureDevice"), "", "text has a line of its own…")
            t.equal(editor.sidebarItem(forSection: "MeasureDevice").flatMap { cell(editor, $0)?.info.stringValue },
                    "MacBook Pro扬声器", "…in full, under the name")
            t.equal(value("MeasureLeft"), "0%")
            t.equal(value("MeasurePeakX"), "36")
            t.equal(cell(editor, parent)?.subtitle.stringValue, "What your Mac plays")
            let run = parent.children[0]
            t.equal(cell(editor, run)?.link.title, "Used by 16 bars")
            t.equal(cell(editor, run)?.strip.isHidden, false, "the run shows its values as a strip")
            t.equal(cell(editor, editor.sidebarItem(forSection: "MeasureLeft"))?.link.title, "Used by Left channel bar")
            t.equal(cell(editor, editor.sidebarItem(forSection: "MeasurePeak"))?.link.title, "Used by Peak marker position")
            t.equal(cell(editor, editor.sidebarItem(forSection: "MeasurePeakX"))?.info.stringValue,
                    "Calculated from peak level", "a formula named after its layer says what it is calculated from")
            t.equal(cell(editor, editor.sidebarItem(forSection: "MeasurePeakX"))?.link.title, "Used by Peak marker")
            // Members count from 1.
            editor.outline.expandItem(run)
            let band = editor.sidebarItem(forSection: "MeasureBand5")
            t.equal(cell(editor, band)?.textField?.stringValue, "Band 6")

            // "Used by" links: hover outlines the users, a click selects them.
            guard let link = cell(editor, run)?.link else { return t.check(false, "link") }
            link.onHover?(true)
            t.equal(editor.canvas.hoverHighlight.count, 16)
            link.onHover?(false)
            editor.dataLinkClicked(link)
            t.equal(editor.canvas.selectedNames.count, 16, "the link selects the 16 bars")

            // The banner: only after 3 seconds of silence (no sound in a self-test), so a pause between songs doesn't
            // move the list.
            editor.selectSidebarTab(.data)
            editor.sidebar.silence = SilenceClock()
            editor.sidebar.banner = nil
            let now = Date()
            t.equal(editor.liveDataBanner(now: now), nil, "not at once")
            t.equal(editor.liveDataBanner(now: now.addingTimeInterval(2.5)), nil, "a pause between songs")
            t.equal(editor.liveDataBanner(now: now.addingTimeInterval(3.5)), .silent, "after 3 seconds")
            editor.sidebar.silence.silentSince = Date(timeIntervalSinceNow: -5)
            editor.updateBanner()
            t.equal(editor.sidebar.bannerView.isHidden, false)
            t.equal(editor.sidebar.bannerView.label.stringValue,
                    "No sound is playing, so the bars are still. Play something to see them move.")
            // Once shown, it stays through a moment of sound and goes after 2 seconds of it.
            var clock = SilenceClock()
            let start = Date(timeIntervalSinceReferenceDate: 0)
            t.equal(clock.saysSilent(true, shown: false, now: start), false)
            t.equal(clock.saysSilent(true, shown: false, now: start.addingTimeInterval(3)), true)
            t.equal(clock.saysSilent(false, shown: true, now: start.addingTimeInterval(4)), true, "sound for a moment")
            t.equal(clock.saysSilent(false, shown: true, now: start.addingTimeInterval(5.5)), true)
            t.equal(clock.saysSilent(false, shown: true, now: start.addingTimeInterval(6.5)), false, "2 seconds of sound")
            t.equal(clock.saysSilent(true, shown: false, now: start.addingTimeInterval(7)), false, "a pause: not yet")
            t.equal(clock.saysSilent(nil, shown: false, now: start.addingTimeInterval(20)), false, "no sound data")
            // The clock runs whatever the tab: Live Data opens with its banner settled.
            editor.selectSidebarTab(.layers)
            t.equal(editor.sidebar.bannerView.isHidden, true, "no banner on Layers")
            editor.sidebar.silence.silentSince = Date(timeIntervalSinceNow: -10)
            editor.refreshSidebarValues()
            t.check(editor.sidebar.silence.silentSince.map { $0.timeIntervalSinceNow < -9 } ?? false, "the clock ran on")
            editor.selectSidebarTab(.data)
            t.equal(editor.sidebar.bannerView.isHidden, false, "shown as the tab opens")

            // Data nothing uses: dimmed, "Not used by any layer", and Delete.
            guard let skin = editor.skin else { return }
            let text = try String(contentsOf: skin.fileURL, encoding: .utf8)
            try (text + "\n[MeasureSpare]\nMeasure=Calc\nFormula=1 + 1\n").write(to: skin.fileURL, atomically: true, encoding: .utf8)
            if let c = app.controller(for: "Audio\\Visualizer") { app.refresh(c) }
            editor.selectSidebarTab(.data)
            guard let spare = editor.sidebarItem(forSection: "MeasureSpare"), let spareCell = cell(editor, spare) else {
                return t.check(false, "the new data's row")
            }
            t.equal(spareCell.subtitle.stringValue, "Not used by any layer")
            t.equal(spareCell.contentAlpha, 0.55, "dimmed")
            t.equal(spareCell.isUnused, true)
            spareCell.isHovered = true
            t.equal(spareCell.deleteButton.isHidden, false, "Delete on hover")
            editor.deleteDataClicked(spareCell.deleteButton)
            t.check(app.controller(for: "Audio\\Visualizer")?.skin.measure(named: "MeasureSpare") == nil, "deleted")
            t.equal(editor.window?.undoManager?.undoActionName, "Delete Calculated Number")
            let menu = LayerMenu.makeData(for: ["MeasureLeft"], in: editor)
            t.equal(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                    ["Show in a New Text Layer", "Duplicate", "Delete", "Show in Code"])
        }

        t.suite("App: friendly sidebar: deleting data says what goes with it") {
            guard let (app, editor) = try visualizer(t), let file = editor.skin?.fileURL else { return }
            let before = try Data(contentsOf: file)
            // A parent goes with the data under it, and its menu says so.
            let menu = LayerMenu.makeData(for: ["MeasureAudio"], in: editor)
            guard let delete = menu.items.first(where: { $0.title.hasPrefix("Delete") }) else { return t.check(false, "Delete") }
            t.equal(delete.title, "Delete with Its 22 Items")
            _ = delete.target?.perform(delete.action)
            t.equal(app.controller(for: "Audio\\Visualizer")?.skin.measures.map(\.name), ["MeasurePeakX"],
                    "no data is left without its parent")
            t.equal(editor.window?.undoManager?.undoActionName, "Delete Sound from Your Mac with Its 22 Items")
            t.equal(editor.toastText, "Deleted sound from your Mac and its 22 items. 21 layers used them.")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before, "one undo step")
            // Data a layer shows: the toast names the layer.
            editor.deleteData(["MeasureLeft"])
            t.equal(editor.toastText, "Deleted left channel level. Left channel bar used it.")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before)
        }

        t.suite("App: friendly sidebar: a data row's menu makes a text that shows it") {
            guard let (app, editor) = try visualizer(t), let file = editor.skin?.fileURL else { return }
            let before = try Data(contentsOf: file)
            let menu = LayerMenu.makeData(for: ["MeasureHighFreq"], in: editor)
            guard let item = menu.items.first(where: { $0.title == "Show in a New Text Layer" }) else { return t.check(false, "item") }
            _ = item.target?.perform(item.action)
            guard let skin = app.controller(for: "Audio\\Visualizer")?.skin,
                  let meter = skin.meters.last(where: { $0.measures.first?.name == "MeasureHighFreq" && $0.name != "MeterHighFreq" })
            else { return t.check(false, "a new text layer") }
            t.equal(meter.rawOption("Text"), "%1")
            t.check(meter.frame.y >= 196, "below what the widget has")
            t.equal(editor.selectedSection, meter.name, "and selected")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: file), before, "one undo step")
        }

        t.suite("App: friendly sidebar: + Add Live Data in plain words") {
            guard let (_, editor) = try visualizer(t) else { return }
            let items = LiveDataChoice.catalogue
            t.equal(items.map(\.section), ["On This Mac", "Calculate", "From the Web"])
            let menu = editor.liveDataMenu(title: "Add Live Data")
            let cpu = menu.items.first { ($0.representedObject as? String) == "CPU" }
            t.equal(cpu?.attributedTitle?.string, "CPU usage\nHow busy the processor is (0–100%)", "two lines")
            t.equal(menu.items.first { $0.identifier?.rawValue == "Network speed" }?.submenu?.items.compactMap(\.identifier?.rawValue),
                    ["Download", "Upload", "Both"])
            t.check(!menu.items.contains { ($0.representedObject as? String) == "Memory" }, "no Windows-style memory")
            let extras = menu.items.first { $0.title == "Extras (limited on a Mac)" }?.submenu?.items ?? []
            t.check(!extras.isEmpty, "everything else under Extras")
            t.check(!extras.contains { ($0.representedObject as? String) == "Registry" }, "Windows-only: hidden")
            let expert = InspectorWindowController.dataSourceMenuItems(expert: true, { _ in })
                .first { $0.title == "Extras (limited on a Mac)" }?.submenu?.items ?? []
            let registry = expert.first { ($0.representedObject as? String) == "Registry" }
            t.equal(registry?.isEnabled, false, "with Rainmeter details: shown, disabled")
            t.check(registry?.title.hasSuffix("Doesn't work on a Mac") ?? false)

            // A random number: a Calc with its options, one undo step, selected.
            guard let file = editor.skin?.fileURL,
                  let random = menu.items.first(where: { $0.identifier?.rawValue == "Random number" }) as? ClosureMenuItem
            else { return t.check(false, "Random number") }
            _ = random.target?.perform(random.action)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            t.check(text.contains("[MeasureCalc]\nMeasure=Calc\nFormula=Random\nLowBound=0\nHighBound=100\nUpdateRandom=1\n"),
                    "added with its options")
            t.equal(editor.window?.undoManager?.undoActionName, "Add Random Number")
            t.equal(editor.toastText, "Added random number")
            t.equal(editor.selectedSection, "MeasureCalc")
        }
    }

    // MARK: What fits

    /// Sets the sidebar's width as dragging its divider would, and lays the rows out.
    static func setSidebarWidth(_ editor: InspectorWindowController, _ width: CGFloat) {
        editor.mainSplit.setPosition(width, ofDividerAt: 0)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        for row in 0..<editor.outline.numberOfRows {
            guard let cell = editor.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerCell else { continue }
            cell.needsLayout = true
            cell.layoutSubtreeIfNeeded()
        }
    }

    /// What of a row's words doesn't show whole: "title", "info", "subtitle", "link", "value".
    static func cutParts(_ cell: LayerCell) -> [String] {
        var parts: [String] = []
        if let title = cell.textField, LayerCell.isCut(title, lines: cell.titleLines) { parts.append("title") }
        if LayerCell.isCut(cell.info) { parts.append("info") }
        if LayerCell.isCut(cell.subtitle) { parts.append("subtitle") }
        if cell.isLinkCut { parts.append("link") }
        if LayerCell.isCut(cell.detail) { parts.append("value") }
        return parts
    }

    /// The rows on screen with what is cut in each: ["“48 Hz”: subtitle"].
    static func cutRows(_ editor: InspectorWindowController, only: Set<String>? = nil) -> [String] {
        (0..<editor.outline.numberOfRows).compactMap { row -> String? in
            guard let cell = editor.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerCell else { return nil }
            let parts = cutParts(cell).filter { only?.contains($0) ?? true }
            return parts.isEmpty ? nil : "\(cell.textField?.stringValue ?? ""): \(parts.joined(separator: ", "))"
        }
    }

    /// Gives the list and the canvas legacy scrollers, as AppKit does with a mouse connected or Show scroll bars set
    /// to Always, whatever this Mac has: the worst case for what fits, since legacy scrollers take room at the right.
    static func useLegacyScrollers(_ editor: InspectorWindowController) {
        for scroll in [editor.outline.enclosingScrollView, editor.canvasScroll] { scroll?.scrollerStyle = .legacy }
    }

    /// Names read whole: the rows take the sidebar's width (a narrow chevron column instead of a wide gutter, and a
    /// scroller that floats over them), a value never shortens a name, long data names wrap, and what is still cut
    /// shows whole in the tooltip. With legacy scrollers, on every Mac.
    static func fitTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: names, values and users read whole") {
            guard let (_, editor) = try visualizer(t) else { return }
            useLegacyScrollers(editor)
            t.check(editor.outline.enclosingScrollView?.scrollerStyle == .overlay, "the list's scroller floats over the rows")
            t.check(editor.canvasScroll.scrollerStyle == .overlay, "and the canvas's over the widget")
            let width = EditorLayoutMemory(defaults: nil).sidebarWidth
            t.equal(width, 262, "the sidebar's first width")
            t.close(editor.sidebarPane.frame.width, width, accuracy: 0.5)
            let widget = editor.outline.row(forItem: editor.listItems.first)
            t.close(editor.outline.frameOfCell(atColumn: 0, row: widget).minX, 18, accuracy: 0.5,
                    "rows start after the chevron's narrow column")
            for tab in [InspectorWindowController.SidebarTab.layers, .data] {
                editor.selectSidebarTab(tab)
                setSidebarWidth(editor, width)
                t.equal(cutRows(editor), [], "\(tab): every line reads whole")
            }
            t.close(editor.outline.enclosingScrollView?.contentView.frame.width ?? 0, width, accuracy: 0.5,
                    "the scroller takes none of the list's width")
            // At the old width, the live data's names and values still read whole (the name comes first).
            setSidebarWidth(editor, 246)
            t.equal(cutRows(editor, only: ["title", "value"]), [], "names and values at 246 points")
            setSidebarWidth(editor, 220)
            t.equal(cutRows(editor, only: ["title", "value"]), [], "names and values at 220 points, the narrowest")

            // What is cut shows whole in the tooltip, the section after it.
            editor.selectSidebarTab(.layers)
            setSidebarWidth(editor, 220)
            guard let peak = cell(editor, row(editor, "MeterPeak")) else { return t.check(false, "the Peak marker's row") }
            t.equal(cutParts(peak), ["subtitle"])
            t.equal(peak.toolTip, "Peak marker\nColor block · moves with peak level\nMeterPeak")
            setSidebarWidth(editor, width)
            t.equal(cell(editor, row(editor, "MeterPeak"))?.toolTip, "MeterPeak", "nothing cut: the section alone")
        }
    }

    // MARK: Data in use

    /// A data name too long for one line takes two, and one again in a wider sidebar.
    static func wrapTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: a long data name takes two lines") {
            guard let (_, editor) = try openWidget(t, """
                [Rainmeter]
                [MeasureRAM]
                Measure=PhysicalMemory
                [MeasureVirtual]
                Measure=SwapMemory
                [MeasureSum]
                Measure=Calc
                Formula=MeasureVirtual + MeasureRAM
                [MeterText]
                Meter=String
                MeasureName=MeasureSum
                """) else { return }
            useLegacyScrollers(editor)
            editor.selectSidebarTab(.data)
            setSidebarWidth(editor, EditorLayoutMemory(defaults: nil).sidebarWidth)
            guard let sum = editor.sidebarItem(forSection: "MeasureSum"), let sumCell = cell(editor, sum) else {
                return t.check(false, "the formula's row")
            }
            t.equal(sumCell.textField?.stringValue, "Calculated from memory and swap used")
            t.equal(sumCell.titleLines, 2, "the name wraps")
            t.equal(cutParts(sumCell), [], "and reads whole")
            t.equal(editor.outline.rect(ofRow: editor.outline.row(forItem: sum)).height,
                    LayerCell.rowHeight(titleLines: 2, lines: 1), "its row is taller")
            setSidebarWidth(editor, InspectorWindowController.PaneSize.sidebarMax)
            t.equal(cell(editor, editor.sidebarItem(forSection: "MeasureSum"))?.titleLines, 1, "one line when there is room")
            t.equal(editor.outline.rect(ofRow: editor.outline.row(forItem: sum)).height, 40)
        }
    }

    /// A widget of its own, open in the editor.
    static func openWidget(_ t: AppTestRunner, _ ini: String) throws -> (app: AppController, editor: InspectorWindowController)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let folder = app.skinsDirectory.appendingPathComponent("Probe/Main")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ini.write(to: folder.appendingPathComponent("Main.ini"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
        guard let c = app.activate(config: "Probe\\Main", file: nil) else {
            t.check(false, "the widget loads")
            return nil
        }
        app.showInspector(for: c)
        guard let editor = app.inspector else {
            t.check(false, "the editor opens")
            return nil
        }
        return (app, editor)
    }

    static let probe = """
        [Rainmeter]
        Update=1000
        OnRefreshAction=[!EnableMeasure MeasureSlow]

        [MeasurePlayer]
        Measure=String
        String=Song

        [MeasureCounter]
        Measure=Calc
        Formula=(MeasureCounter+1)%10
        IfCondition=MeasureCounter = 5
        IfTrueAction=[!SetOption MeterText FontColor 255,0,0][!UpdateMeter MeterText][!Redraw]

        [MeasureSlow]
        Measure=Time
        Format=%H:%M
        Disabled=1

        [MeasureSpare]
        Measure=Calc
        Formula=1

        [MeasureReg]
        Measure=Registry
        RegHKey=HKEY_CURRENT_USER
        RegKey=Software\\Test
        RegValue=Value

        [MeterBg]
        Meter=Shape
        Shape=Rectangle 0,0,300,200,8 | Fill Color 30,30,40,255 | StrokeWidth 0

        [MeterText]
        Meter=String
        Text=Hello
        FontColor=255,255,255
        FontSize=12
        X=10
        Y=10
        LeftMouseUpAction=[!CommandMeasure MeasurePlayer "PlayPause"]

        [MeterNext]
        Meter=String
        Text=Next
        Hidden=1
        FontColor=255,255,255
        FontSize=12
        X=0r
        Y=4R
        LeftMouseUpAction=[!CommandMeasure MeasurePlayer "Next"]

        """

    static func dataUseTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: data used by actions is not offered for deletion") {
            guard let (_, editor) = try openWidget(t, probe) else { return }
            editor.selectSidebarTab(.data)
            func line(_ name: String) -> LayerCell? { editor.sidebarItem(forSection: name).flatMap { cell(editor, $0) } }
            t.equal(line("MeasurePlayer")?.link.attributedTitle.string, "Used by “Hello” and “Next”", "click actions")
            t.equal(line("MeasureCounter")?.subtitle.stringValue, "Runs actions when it updates", "its own IfTrueAction")
            t.equal(line("MeasureSlow")?.subtitle.stringValue, "Used by the widget", "turned on when the widget opens")
            for name in ["MeasurePlayer", "MeasureCounter", "MeasureSlow"] {
                guard let c = line(name) else { t.check(false, name); continue }
                t.equal([c.isUnused ? 1 : 0, c.contentAlpha], [0, 1], "\(name): not dimmed")
                c.isHovered = true
                t.equal(c.deleteButton.isHidden, true, "\(name): no Delete on hover")
                c.isHovered = false
            }
            t.equal(line("MeasureSpare")?.subtitle.stringValue, "Not used by any layer")
            t.equal(line("MeasureSpare")?.isUnused, true)

            // Data that only works on Windows is marked in its row, and the banner names it.
            guard let reg = editor.sidebarItem(forSection: "MeasureReg"), let regCell = cell(editor, reg) else {
                return t.check(false, "the Windows-only row")
            }
            t.equal(regCell.info.stringValue, "Doesn't work on a Mac")
            t.equal(regCell.warning.isHidden, false, "a warning on the row")
            t.equal(regCell.warning.toolTip, "Doesn't work on a Mac, so it reads 0.")
            t.equal(editor.sidebar.bannerView.isHidden, false)
            t.equal(reg.display, "Windows registry")
            t.equal(editor.sidebar.bannerView.label.stringValue, "Windows registry doesn't work on a Mac, so it reads 0.",
                    "the banner names it")
        }

        t.suite("App: friendly sidebar: sizes count as the widget and the Mac count them") {
            t.equal(InspectorWindowController.bytes(25_769_803_776, binary: true), "24.0 GB", "memory: powers of 1024")
            t.equal(InspectorWindowController.bytes(3_221_225_472), "3.2 GB", "disks and networks: powers of 1000")
            t.equal(InspectorWindowController.bytes(1536, binary: true), "1.5 KB")
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let skin = editor.skin else { return }
            func binary(_ name: String, otherwise: Bool) -> Bool? {
                skin.measure(named: name).map { InspectorWindowController.countsInBinary($0, in: skin, otherwise: otherwise) }
            }
            t.equal(binary("MeasureRAMTotal", otherwise: false), true, "as the widget's text scales it (AutoScale=1)")
            t.equal(binary("MeasureSwap", otherwise: false), true)
            t.equal(binary("MeasureCPU", otherwise: false), false, "no text scales it: the kind's own way")
            // Names that say what they count: SwapMemory is the memory and the swap; the swap is calculated.
            editor.selectSidebarTab(.data)
            t.equal(editor.listItems.map(\.display), ["CPU usage", "Memory used", "Total memory", "Memory and swap used",
                                                      "Total memory and swap", "Total swap", "Swap used", "Time since startup"])
            editor.selectSidebarTab(.layers)
            t.equal(row(editor, "MeterSwapBar")?.display, "Swap bar")
            t.equal(row(editor, "MeterSwapBar")?.subtitle, "Shape · swap used")
            // "+ Add Live Data" has no "Swap used" that would count the memory too; SwapMemory is under Extras.
            let menu = editor.liveDataMenu(title: "Add Live Data")
            t.check(!menu.items.contains { $0.identifier?.rawValue == "Swap used" }, "no Swap used")
            let extras = menu.items.first { $0.title == "Extras (limited on a Mac)" }?.submenu?.items ?? []
            t.equal(extras.first { ($0.representedObject as? String) == "SwapMemory" }?.title, "Memory and swap used", "named as LayerNaming names it")
        }

        t.suite("App: friendly sidebar: a size calculated from memory counts as memory") {
            guard let (_, editor) = try openWidget(t, """
                [Rainmeter]
                [MeasureRAMTotal]
                Measure=PhysicalMemory
                Total=1
                [MeasureFixed]
                Measure=Calc
                Formula=MeasureRAMTotal * 0 + 25769803776
                [MeterText]
                Meter=String
                MeasureName=MeasureFixed
                """), let skin = editor.skin, let fixed = skin.measure(named: "MeasureFixed") else { return }
            t.equal(editor.liveValueText(fixed, in: skin), "24.0 GB", "24 GB, as About This Mac says (not 25.8 GB)")
        }

        t.suite("App: friendly sidebar: menus and rows follow Show Rainmeter Details") {
            guard let (app, editor) = try visualizer(t) else { return }
            editor.selectSidebarTab(.data)
            guard let menu = editor.addDataSourceButton.menu else { return t.check(false, "+ Add Live Data") }
            func registry() -> NSMenuItem? {
                menu.items.first { $0.title == "Extras (limited on a Mac)" }?.submenu?.items
                    .first { ($0.representedObject as? String) == "Registry" }
            }
            t.check(registry() == nil, "Windows-only kinds are hidden")
            app.state.updateEditor { $0.showIniNames = true }
            menu.delegate?.menuNeedsUpdate?(menu)
            t.equal(registry()?.isEnabled, false, "shown, disabled, the next time the menu opens")
            // The rows follow at once: a group's second line names its sections.
            editor.selectSidebarTab(.layers)
            t.equal(row(editor, "MeterBand0")?.subtitle, "Bar · sound bands 1–16 · MeterBand0…MeterBand15")
            t.equal(row(editor, "MeterTitle")?.subtitle, "Text · MeterTitle")
            app.state.updateEditor { $0.showIniNames = false }
            t.equal(row(editor, "MeterBand0")?.subtitle, "Bar · sound bands 1–16")
            menu.delegate?.menuNeedsUpdate?(menu)
            t.check(registry() == nil, "hidden again")
        }
    }

    // MARK: Add

    static func addTabTests(_ t: AppTestRunner) {
        t.suite("App: friendly sidebar: the Add tab says what to do") {
            let library = ComponentLibraryView(onInsert: { _ in })
            library.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
            library.layoutSubtreeIfNeeded()
            t.equal(library.searchField.placeholderString, "Search things to add")
            t.equal(library.hint.stringValue, "Drag onto your widget, or click to add it below what's there.")
            t.check(!library.hint.isHidden && library.hint.frame.height > 0, "the hint is always shown")
            t.check(library.hint.frame.minY >= library.searchField.frame.maxY, "under the search field")
            let chips = library.subviews.compactMap { ($0 as? ChipButton)?.title }
            t.equal(chips, ["All", "Text", "Live Data", "Graphs", "Gauges", "Shapes", "Pictures"])
            t.equal(EditorComponents.component("image")?.summary, "A picture from the widget's folder")
            library.setFilter(query: "xyz", category: nil)
            let empty = library.findSubview { ($0 as? NSTextField)?.stringValue.hasPrefix("Nothing matches") ?? false }
            t.equal((empty as? NSTextField)?.stringValue, "Nothing matches “xyz”.")
        }
    }
}
