import AppKit
import DesksetCore

extension AppSelfTest {
    static func inspectorTests(_ t: AppTestRunner) {
        t.suite("App: skin editor") {
            guard let app = try makeApp(t) else { return }
            guard let c = app.activate(config: "Deskset\\System", file: nil) else {
                return t.check(false, "Deskset\\System loads")
            }
            app.showInspector(for: c)
            guard let inspector = app.inspector else { return t.check(false, "inspector opens") }
            t.check(inspector.canvas.frame.width > c.skin.width, "the canvas holds the skin plus margins")

            inspector.select(section: "MeterCPUValue")
            t.equal(inspector.selectedSection, "MeterCPUValue")
            t.equal(inspector.canvas.selection, "MeterCPUValue", "selection outlined on the canvas")
            let x = inspector.rows.first { $0.key == "X" }
            t.equal(x?.raw, "(#PanelWidth# - #Padding#)")
            t.equal(x?.resolved, "(260 - 18)")
            t.equal(x?.style, .inherited)
            t.check(x?.source.hasPrefix("↳ StyleValue") == true, "source names the style: \(x?.source ?? "")")

            if let bar = c.skin.meter(named: "MeterRAMBar") {
                inspector.canvas.pick(skinX: bar.frame.x + bar.frame.width / 2, y: bar.frame.y + bar.frame.height / 2)
            }
            t.equal(inspector.selectedSection, "MeterRAMBar", "clicking a meter on the canvas selects it")
            inspector.select(section: "MeasureCPU")
            t.equal(inspector.canvas.selection, nil, "measures have nothing to outline")
            t.check(inspector.autoFit, "fits the skin until the user zooms")
            inspector.canvas.onUserZoom?()  // what a pinch, ⌥-scroll or ⌘+ does
            t.check(!inspector.autoFit)
            inspector.canvas.setZoom(8)
            t.close(Double(inspector.canvas.zoom), 8, "zoom")
            inspector.canvas.zoomIn()
            t.close(Double(inspector.canvas.zoom), 12, "next zoom step")
            inspector.canvas.setZoom(100)
            t.close(Double(inspector.canvas.zoom), Double(SkinCanvasView.maxZoom), "zoom is clamped")

            // Edit a variable: written to Variables.inc, the skin reloads, the inspector follows it.
            inspector.select(section: "Variables")
            inspector.write(key: "PanelWidth", value: "300")
            let inc = c.skin.resourcesDirectory.appendingPathComponent("Variables.inc")
            t.check((try? String(contentsOf: inc, encoding: .utf8))?.contains("PanelWidth=300") == true,
                    "written where the variable is defined")
            guard let reloaded = app.controller(for: "Deskset\\System"), reloaded !== c else {
                return t.check(false, "skin refreshed")
            }
            t.check(c.isStopped)
            t.close(Double(inspector.canvas.zoom), Double(SkinCanvasView.maxZoom), "zoom kept across a refresh")
            t.equal(inspector.selectedSection, "Variables", "selection kept")
            t.equal(reloaded.skin.variable("PanelWidth"), "300")
            t.equal(inspector.rows.first { $0.key == "PanelWidth" }?.raw, "300")

            // A change made in another editor is picked up.
            let ini = reloaded.skin.fileURL
            let text = try String(contentsOf: ini, encoding: .utf8)
            try text.replacingOccurrences(of: "Update=1000", with: "Update=2000").write(to: ini, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: ini.path)
            inspector.tick()
            guard let external = app.controller(for: "Deskset\\System"), external !== reloaded else {
                return t.check(false, "refreshed after an external edit")
            }
            t.equal(external.skin.settings.update, 2000)

            // The skin writing its own file with !WriteKeyValue is not an edit.
            external.skin.execute("[!WriteKeyValue Variables Note hello]", from: nil)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: ini.path)
            inspector.tick()
            t.check(app.controller(for: "Deskset\\System") === external, "no refresh for !WriteKeyValue")

            app.deactivate(config: "Deskset\\System")
            t.equal(inspector.rows.count, 0, "unloading the skin empties the inspector")
            guard app.activate(config: "Deskset\\System", file: nil) != nil else { return t.check(false, "reloads") }
            t.check(!inspector.rows.isEmpty, "loading it again reattaches")

            inspector.window?.close()
            t.check(app.inspector == nil, "closing forgets the inspector")
        }
        EditorWindowSelfTests.run(t)
    }

    static func editorEditingTests(_ t: AppTestRunner) {
        t.suite("App: skin editor editing") {
            guard let app = try makeApp(t) else { return }
            guard let c = app.activate(config: "Deskset\\System", file: nil) else {
                return t.check(false, "Deskset\\System loads")
            }
            app.showInspector(for: c)
            guard let editor = app.inspector else { return t.check(false, "editor opens") }
            let ini = c.skin.fileURL
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func current() -> SkinController? { app.controller(for: "Deskset\\System") }
            func drag(_ meter: String, _ gesture: SkinCanvasView.Gesture, from: (Double, Double), by d: (Double, Double)) {
                editor.select(section: meter)
                let start = NSPoint(x: from.0 + SkinCanvasView.margin, y: from.1 + SkinCanvasView.margin)
                editor.canvas.beginGesture(gesture, at: start)
                editor.canvas.drag(to: NSPoint(x: start.x + d.0, y: start.y + d.1), snapping: false)
                editor.canvas.endGesture(keep: true)
            }

            // Move: a variable keeps working, a number changes.
            guard let label = current()?.skin.meter(named: "MeterCPULabel") else { return t.check(false, "label") }
            let before = label.frame
            drag("MeterCPULabel", .move, from: (before.x + 2, before.y + 2), by: (10, 5))
            t.check(text().contains("X=(#Padding# + 10)\n"), "X keeps #Padding#")
            t.check(text().contains("Y=53\n"), "Y moved")
            t.equal(current()?.skin.meter(named: "MeterCPULabel")?.frame.x, before.x + 10, "the refreshed skin shows it")
            t.check(editor.toastText.hasPrefix("Moved "), "toast: \(editor.toastText)")

            // Undo and redo restore the file byte for byte.
            let moved = text()
            editor.window?.undoManager?.undo()
            t.check(text().contains("X=#Padding#\n") && text().contains("Y=48\n"), "undo")
            t.equal(current()?.skin.meter(named: "MeterCPULabel")?.frame.x, before.x, "undo refreshes")
            editor.window?.undoManager?.redo()
            t.equal(text(), moved, "redo")

            // Resize the right edge of a variable width: the formula keeps the variable.
            guard let fill = current()?.skin.meter(named: "MeterCPUFill") else { return t.check(false, "fill") }
            let f = fill.frame
            drag("MeterCPUFill", .resize(.init(right: true)), from: (f.x + f.width, f.y + f.height / 2), by: (-20, 0))
            t.check(text().contains("W=(#ContentWidth# - 20)\n"), "W keeps #ContentWidth#")
            t.equal(current()?.skin.meter(named: "MeterCPUFill")?.frame.width, f.width - 20)
            t.equal(current()?.skin.meter(named: "MeterCPUFill")?.frame.x, f.x, "left edge stays")

            // Resize a right-aligned text: the anchor (X) is corrected so the left edge stays put.
            guard let value = current()?.skin.meter(named: "MeterCPUValue") else { return t.check(false, "value") }
            let v = value.frame
            drag("MeterCPUValue", .resize(.init(right: true)), from: (v.x + v.width, v.y + v.height / 2), by: (12, 0))
            let resized = current()?.skin.meter(named: "MeterCPUValue")?.frame
            t.equal(resized?.width, v.width + 12, "width")
            t.equal(resized?.x, v.x, "left edge of right-aligned text stays")
            t.check(text().range(of: "\\[MeterCPUValue\\][^\\[]*W=", options: .regularExpression) != nil,
                    "W written into [MeterCPUValue]")

            // Nudging: several arrow presses become one write and one undo step.
            editor.select(section: "MeterRAMBar")
            for _ in 0..<3 { editor.canvas.onNudge?(0, 1) }
            t.check(text().contains("Y=140\n"), "not written while nudging")
            editor.commitPendingNudge()
            t.check(text().contains("Y=143\n"), "nudged by 3")
            editor.window?.undoManager?.undo()
            t.check(text().contains("Y=140\n"), "one undo step for the run")

            // A color written as a variable edits the variable, in its own notation.
            editor.select(section: "MeterCPUGraph")
            guard let defined = current()?.skin.sources.location(section: "Variables", key: "CPUColor")?.file else {
                return t.check(false, "CPUColor is defined somewhere")
            }
            guard let raw = editor.rows.first(where: { $0.key == "LineColor" })?.raw else {
                return t.check(false, "LineColor row")
            }
            t.equal(raw, "#CPUColor#")
            editor.beginColorEdit(key: "LineColor", raw: raw, variable: "CPUColor", current: nil)
            editor.pickColor(RGBA(r: 255, g: 0, b: 0, a: 255))
            t.equal(current()?.skin.variable("CPUColor").flatMap(OptionValue.color), RGBA(r: 255, g: 0, b: 0, a: 255),
                    "previewed before writing")
            editor.commitPendingColor()
            let written = (try? String(contentsOf: defined, encoding: .utf8)) ?? ""
            t.check(written.contains("CPUColor=255,0,0,255\n"),
                    "written in \(defined.lastPathComponent), keeping its R,G,B,A notation")
            t.check(text().contains("LineColor=#CPUColor#"), "the option still uses the variable")

            // An external edit blocks undo instead of being overwritten.
            try (text() + "\n; edited elsewhere\n").write(to: ini, atomically: true, encoding: .utf8)
            let external = text()
            editor.window?.undoManager?.undo()
            editor.window?.undoManager?.undo()  // back past the color (another file) to the nudge-free resize
            t.check(editor.toastText.contains("Can't undo"), "undo refused: \(editor.toastText)")
            t.equal(text(), external)
            t.check(text().contains("; edited elsewhere"), "not overwritten")

            editor.window?.close()
        }
    }

    static func editorLayerTests(_ t: AppTestRunner) {
        t.suite("App: skin editor layers") {
            guard let app = try makeApp(t) else { return }
            guard let c = app.activate(config: "Deskset\\System", file: nil) else { return t.check(false, "loads") }
            app.showInspector(for: c)
            guard let editor = app.inspector else { return t.check(false, "editor opens") }
            let ini = c.skin.fileURL
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func skin() -> Skin? { app.controller(for: "Deskset\\System")?.skin }
            func frame(_ name: String) -> SkinRect { skin()?.meter(named: name)?.frame ?? SkinRect() }
            func click(_ name: String, extend: Bool = false) {
                let f = frame(name)
                editor.canvas.click(skinX: f.x + f.width / 2, y: f.y + f.height / 2, extend: extend)
            }
            /// Ends the current event: the undo manager groups what one event registers (as in the app).
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            func dragSelection(by d: (Double, Double)) {
                guard let first = editor.canvas.selectedNames.first else { return }
                let f = frame(first)
                let start = NSPoint(x: f.x + 1 + SkinCanvasView.margin, y: f.y + 1 + SkinCanvasView.margin)
                editor.canvas.beginGesture(.move, at: start)
                editor.canvas.drag(to: NSPoint(x: start.x + d.0, y: start.y + d.1), snapping: false)
                editor.canvas.endGesture(keep: true)
            }

            // ⇧-click builds a multiple selection.
            click("MeterCPULabel")
            click("MeterRAMLabel", extend: true)
            t.check(editor.isMultiSelection, "two layers selected")
            t.equal(editor.selectedMeters, ["MeterCPULabel", "MeterRAMLabel"])
            let cpu = frame("MeterCPULabel"), ram = frame("MeterRAMLabel")
            dragSelection(by: (8, 0))
            t.equal(frame("MeterCPULabel").x, cpu.x + 8)
            t.equal(frame("MeterRAMLabel").x, ram.x + 8)
            t.equal(text().components(separatedBy: "X=(#Padding# + 8)\n").count - 1, 2, "both keep #Padding#")
            t.check(editor.isMultiSelection, "selection kept after the refresh")
            editor.window?.undoManager?.undo()
            t.equal(frame("MeterCPULabel").x, cpu.x, "one undo step for the group")

            // A meter placed relative to another selected one is not moved twice.
            click("MeterCPULabel")
            click("MeterCPUValue", extend: true)
            let value = frame("MeterCPUValue")
            dragSelection(by: (0, 10))
            t.equal(frame("MeterCPULabel").y, cpu.y + 10)
            t.equal(frame("MeterCPUValue").y, value.y + 10, "relative meter moved once")
            t.check(text().contains("[MeterCPUValue]") && text().contains("Y=-5r\n"), "relative Y left alone")
            editor.window?.undoManager?.undo()

            // Align lefts, including a right-aligned text. The text normally shows the live CPU value, whose width
            // changes between updates; a fixed text keeps its width stable across the refresh that follows the edit.
            editor.select(section: "MeterCPUValue")
            editor.write(key: "Text", value: "100%")
            settle()
            click("MeterCPULabel")
            click("MeterCPUValue", extend: true)
            editor.align(.left)
            t.equal(frame("MeterCPUValue").x, frame("MeterCPULabel").x, "left edges line up")
            editor.align(.distributeX)
            t.check(editor.toastText.contains("three or more"), "distribute needs three: \(editor.toastText)")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            editor.window?.undoManager?.undo()
            t.check(text().contains("Text=%1%\n"), "fixed text undone")

            // One meter aligns to the skin.
            click("MeterCPULabel")
            editor.align(.centerX)
            let centered = frame("MeterCPULabel")
            t.close(centered.x + centered.width / 2, (skin()?.width ?? 0) / 2, accuracy: 0.51, "centered in the skin")
            editor.window?.undoManager?.undo()

            // Insert a component: measure and meter, selected, one undo step.
            editor.insertComponent("clock")
            t.check(text().contains("[MeasureTime]\nMeasure=Time"), "measure added")
            t.check(text().contains("[MeterClock]\nMeter=String\nMeasureName=MeasureTime"), "meter added")
            t.equal(editor.selectedSection, "MeterClock", "the new layer is selected")
            t.check((skin()?.meter(named: "MeterClock")?.frame.width ?? 0) > 0, "and drawn")
            t.equal(skin()?.issues.filter { $0.contains("MeterClock") || $0.contains("MeasureTime") }, [])
            editor.window?.undoManager?.undo()
            t.check(!text().contains("MeterClock"), "undo removes it")

            // Duplicate and delete.
            click("MeterCPULabel")
            editor.duplicateSelection()
            settle()
            t.check(text().contains("[MeterCPULabel2]"), "duplicate written")
            t.equal(editor.selectedSection, "MeterCPULabel2")
            t.equal(frame("MeterCPULabel2").x, frame("MeterCPULabel").x + 10)
            editor.deleteSelection()
            settle()
            t.check(!text().contains("[MeterCPULabel2]"), "deleted")
            editor.window?.undoManager?.undo()
            t.check(text().contains("[MeterCPULabel2]"), "undo restores it")
            editor.window?.undoManager?.undo()
            t.check(!text().contains("[MeterCPULabel2]"), "and undoing the duplicate removes it")

            // Font menus: FontWeight is the meter's own; FontFace is a variable every text shares, so choosing a font for
            // one text changes that text only (docs/editor-friendly.md §7.5; the toast offers to widen it).
            editor.select(section: "MeterCPUValue")
            t.check(editor.chooseFontOption("FontWeight", value: "700"), "weight menu")
            t.check(text().contains("FontWeight=700\n"), "weight written")
            editor.select(section: "MeterCPUValue")
            t.check(editor.chooseFontOption("FontFace", value: "Menlo"), "font menu")
            t.equal(skin()?.variable("FontFace"), "System Font", "the shared value is left alone")
            t.equal(skin()?.meter(named: "MeterCPUValue")?.rawOption("FontFace"), "Menlo", "the layer has its own font")

            editor.window?.close()
        }
    }

    static func editorUXTests(_ t: AppTestRunner) {
        t.suite("App: skin editor layout of information") {
            guard let app = try makeApp(t) else { return }
            guard let c = app.activate(config: "Deskset\\System", file: nil) else { return t.check(false, "loads") }
            app.showInspector(for: c)
            guard let editor = app.inspector else { return t.check(false, "editor opens") }
            let ini = c.skin.fileURL
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func skin() -> Skin? { app.controller(for: "Deskset\\System")?.skin }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            func section(_ name: String) -> String {
                let t = text()
                guard let r = t.range(of: "[\(name)]") else { return "" }
                let rest = t[r.upperBound...]
                return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
            }

            // Opening shows the skin itself; the list shows the pinned skin row, then the layers, front first.
            t.equal(editor.selectedSection, nil, "nothing selected: the skin's own settings")
            t.equal(editor.sidebarTab, .layers)
            t.check(editor.listItems.first?.isSkin == true, "the skin row is pinned first")
            t.equal(editor.outline.selectedRowIndexes, IndexSet(integer: 0), "and shows the skin is selected")
            t.equal(editor.layerItems.first?.title, skin()?.meters.last?.name, "front layer on top")
            t.check(editor.layerItems.allSatisfy { $0.kind == .meter }, "only layers in the layer list")
            t.equal(editor.listItems.filter(\.isSkin).count, 1)

            // A data source switches to the Data tab and highlights the layers showing it.
            editor.select(section: "MeasureCPU")
            t.equal(editor.sidebarTab, .data)
            t.check(editor.listItems.allSatisfy { $0.kind == .measure }, "only data sources in the data list")
            t.equal(Set(editor.canvas.relatedNames), ["MeterCPUValue", "MeterCPUFill", "MeterCPUGraph"])
            editor.select(section: "MeterCPUFill")
            t.equal(editor.sidebarTab, .layers, "a layer switches back")
            t.equal(editor.canvas.relatedNames, [])

            // The data source of a layer is a menu of data sources.
            t.check(editor.chooseFontOption("MeasureName", value: "MeasureRAM"), "data menu")
            t.check(section("MeterCPUFill").contains("MeasureName=MeasureRAM\n"), "data source changed")
            settle()
            editor.window?.undoManager?.undo()
            t.check(section("MeterCPUFill").contains("MeasureName=MeasureCPU\n"), "undo")
            settle()

            // A choice from a menu.
            editor.select(section: "MeterCPULabel")
            t.check(editor.chooseFontOption("StringCase", value: "Lower"), "case menu")
            // StringCase comes from StyleLabel, which other widgets share: this label changes, the others don't
            // (docs/editor-friendly.md §7.5).
            t.equal(skin()?.meter(named: "MeterCPULabel")?.rawOption("StringCase"), "Lower", "case written for this label")
            t.equal(skin()?.meter(named: "MeterRAMLabel")?.rawOption("StringCase"), "Upper", "the other labels keep theirs")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // Styles open from a layer and lead back to it.
            editor.select(section: "MeterCPULabel")
            editor.select(section: "StyleLabel")
            t.equal(editor.backSection, "MeterCPULabel")
            editor.goBack()
            t.equal(editor.selectedSection, "MeterCPULabel")

            // The eye hides and shows a layer.
            editor.setHidden(true, meter: "MeterTitle")
            t.check(section("MeterTitle").contains("Hidden=1\n"), "hidden written")
            t.check(skin()?.meter(named: "MeterTitle")?.hidden == true, "hidden on the canvas")
            settle()
            editor.window?.undoManager?.undo()
            t.check(skin()?.meter(named: "MeterTitle")?.hidden == false, "undo shows it again")
            settle()

            // Dragging in the layer list changes the drawing order.
            editor.select(section: "MeterBackground")
            t.check(editor.moveLayer("MeterBackground", toListIndex: 0), "moved to the front")
            t.equal(skin()?.meters.last?.name, "MeterBackground", "drawn last = in front")
            t.equal(editor.layerItems.first?.title, "MeterBackground")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(skin()?.meters.first?.name, "MeterBackground", "undo puts it back behind")

            // Clicking the empty canvas returns to the skin; so does the pinned skin row.
            editor.canvasSelectionChanged([])
            t.equal(editor.selectedSection, nil)
            t.equal(editor.outline.selectedRowIndexes, IndexSet(integer: 0))
            editor.select(section: "MeterTitle")
            editor.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            t.equal(editor.selectedSection, nil, "the skin row selects the skin")
            t.check(editor.window?.contentView?.findSubview { ($0 as? NSButton)?.title == "Skin Settings" } == nil,
                    "no Skin Settings button under the list")
            editor.window?.close()
        }
    }
}