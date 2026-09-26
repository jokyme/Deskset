import AppKit
import DesksetCore

/// `Deskset --self-test "App: studio"`: the skin studio's guarantees that a review found broken, each checked the way
/// the user meets it (headless: the window is never shown; typing goes through the text views; clicks through the
/// controls' own actions). Data first — nothing typed, picked or written by the running skin is lost or written to the
/// wrong place — then the fool-proof controls, then the window's behaviour.
enum StudioReviewSelfTests {
    typealias Editor = InspectorWindowController

    static func run(_ t: AppTestRunner) {
        codeFollowsDiskTests(t)
        editsAfterTypedCodeTests(t)
        renumberingTests(t)
        pendingEditsTests(t)
        undoTests(t)
        runtimeValueTests(t)
        unloadTests(t)
        deleteTests(t)
        dataSourceTests(t)
        controlTests(t)
        colorPanelTests(t)
        rebuildTests(t)
        shapeOrderTests(t)
        includeCommitTests(t)
        windowTests(t)
    }

    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    /// Waits (bounded) for an edit deferred to the next turn of the run loop.
    @discardableResult
    static func spin(until condition: () -> Bool) -> Bool { AppSelfTest.spin(timeout: 10, until: condition) }

    /// A headless app with `ini` as Studio\<name> loaded and its editor open.
    static func openSkin(_ t: AppTestRunner, _ name: String, _ ini: String, files: [String: String] = [:])
        throws -> (AppController, Editor, URL)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let folder = app.skinsDirectory.appendingPathComponent("Studio/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = app.skinsDirectory.appendingPathComponent("Studio").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let url = folder.appendingPathComponent("\(name).ini")
        try ini.write(to: url, atomically: true, encoding: .utf8)
        guard let c = app.activate(config: "Studio\\\(name)", file: "\(name).ini") else {
            t.check(false, "Studio\\\(name) loads")
            return nil
        }
        app.showInspector(for: c)
        guard let editor = app.inspector else {
            t.check(false, "the editor opens")
            return nil
        }
        return (app, editor, url)
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// The text of `[name]` in `text` (up to the next header).
    static func section(_ name: String, in text: String) -> String {
        guard let r = text.range(of: "[\(name)]") else { return "" }
        let rest = text[r.upperBound...]
        return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
    }

    /// Replaces `old` by `new` in the code pane's shown buffer, as typing does.
    @discardableResult
    static func retype(_ editor: Editor, _ old: String, with new: String) -> Bool {
        let range = (editor.codeView.text as NSString).range(of: old)
        guard range.location != NSNotFound else { return false }
        editor.codeView.textView.setSelectedRange(range)
        editor.codeView.textView.insertText(new, replacementRange: range)
        return true
    }

    /// Marks a file as changed on disk later than anything the editor saw (a write in the same second may keep the
    /// modification date).
    static func touch(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(seconds)], ofItemAtPath: url.path)
    }

    // MARK: The code pane follows the disk (a clean buffer never writes old text back)

    static func codeFollowsDiskTests(_ t: AppTestRunner) {
        t.suite("App: studio code pane follows every change on disk") {
            guard let (app, editor) = try EditorWindowSelfTests.openEditor(t) else { return }
            editor.setMode(.split)
            guard let c = app.controller(for: "Deskset\\System") else { return t.check(false, "skin") }
            let ini = c.skin.fileURL
            let skin = { app.controller(for: "Deskset\\System") }

            // The skin saves a setting of its own (a click on the desktop running !WriteKeyValue): the skin is not
            // refreshed — Rainmeter does not either — but the code pane shows the file as it is now.
            c.skin.execute("[!WriteKeyValue Variables StudioTheme dark]", from: nil)
            spin { read(ini).contains("StudioTheme=dark") }
            t.check(read(ini).contains("StudioTheme=dark"), "the skin wrote its file")
            try touch(ini, 5)
            editor.tick()
            t.check(skin() === c, "no refresh for the skin's own write")
            t.check(editor.codeView.text.contains("StudioTheme=dark"), "the clean buffer shows the skin's write")
            t.check(!editor.codeView.hasUncommittedChanges)
            // The next keystroke's commit keeps it.
            t.check(EditorWindowSelfTests.type(editor, "!", after: "Text=CPU\n", offset: 8), "typed")
            editor.saveSkinCode(nil)
            t.check(read(ini).contains("StudioTheme=dark") && read(ini).contains("Text=CPU!\n"),
                    "the skin's write survives the commit of other typing")

            // Live reload off: a save in another editor is not loaded into the skin, but the code pane follows it.
            editor.liveReload = false
            let running = skin()
            try read(ini).replacingOccurrences(of: "Update=1000", with: "Update=3000").write(to: ini, atomically: true,
                                                                                             encoding: .utf8)
            try touch(ini, 10)
            editor.tick()
            t.check(skin() === running, "live reload off: no refresh")
            t.check(editor.codeView.text.contains("Update=3000"), "the code pane shows the other editor's save")
            t.check(EditorWindowSelfTests.type(editor, "?", after: "Text=CPU!\n", offset: 9), "typed")
            editor.saveSkinCode(nil)
            t.check(read(ini).contains("Update=3000") && read(ini).contains("Text=CPU!?\n"), "and keeps it")

            // A hidden code pane catches up when it appears.
            editor.setMode(.design)
            try read(ini).replacingOccurrences(of: "Update=3000", with: "Update=4000").write(to: ini, atomically: true,
                                                                                             encoding: .utf8)
            try touch(ini, 15)
            editor.tick()
            editor.setMode(.split)
            t.check(editor.codeView.text.contains("Update=4000"), "the code pane re-reads the file when shown")

            // Typed code whose file changed meanwhile: the commit asks what to keep, never silently overwrites.
            var answer = CodeEditorView.DiskConflictChoice.decideLater
            var asked: [String] = []
            editor.codeView.onDiskConflict = { url in
                asked.append(url.lastPathComponent)
                return answer
            }
            t.check(EditorWindowSelfTests.type(editor, "X", after: "Text=CPU!?\n", offset: 10), "typed")
            try read(ini).replacingOccurrences(of: "Update=4000", with: "Update=5000").write(to: ini, atomically: true,
                                                                                             encoding: .utf8)
            try touch(ini, 20)
            editor.tick()
            t.check(editor.codeView.text.contains("Text=CPU!?X") && editor.codeView.hasUncommittedChanges,
                    "the typing stays in the buffer")
            editor.saveSkinCode(nil)
            t.equal(asked, ["System.ini"], "the commit asks")
            t.check(read(ini).contains("Update=5000") && !read(ini).contains("Text=CPU!?X"), "decide later: nothing written")
            t.check(editor.codeView.hasUncommittedChanges, "the typing is kept")
            t.check(!editor.codeView.fireIdleCommit(), "no automatic commit keeps asking")
            answer = .keepEdits
            editor.saveSkinCode(nil)
            t.equal(asked.count, 2, "⌘S asks again")
            t.check(read(ini).contains("Text=CPU!?X"), "keep my edits: written over the file")
            t.check(!editor.codeView.hasUncommittedChanges)

            // Take the file's version: the typing goes, the buffer shows the disk.
            t.check(EditorWindowSelfTests.type(editor, "Y", after: "Text=CPU!?X\n", offset: 11), "typed")
            try read(ini).replacingOccurrences(of: "Text=CPU!?X", with: "Text=Elsewhere").write(to: ini, atomically: true,
                                                                                                 encoding: .utf8)
            try touch(ini, 25)
            answer = .takeDisk
            editor.saveSkinCode(nil)
            t.check(read(ini).contains("Text=Elsewhere") && !read(ini).contains("Text=CPU!?XY"), "the file is left as it was")
            t.check(editor.codeView.text.contains("Text=Elsewhere") && !editor.codeView.hasUncommittedChanges,
                    "the buffer takes the file's version")
            editor.window?.close()
        }
    }

    // MARK: Visual edits apply on top of typed code

    static func editsAfterTypedCodeTests(_ t: AppTestRunner) {
        t.suite("App: studio visual edits apply after typed code") {
            guard let (app, editor, ini) = try AppSelfTest.makeKindsEditor(t) else { return }
            editor.setMode(.split)
            editor.select(section: "Shapes")
            func shape() -> String? { app.controller(for: "Studio\\Kinds")?.skin.document.section(named: "Shapes")?.value(forKey: "Shape") }

            // A new corner radius typed in the code, then — before the idle commit — a click on the Outline checkbox
            // (a click does not take the focus from the code): the radius is committed first, and the outline change
            // applies to the shape as the code left it.
            editor.window?.makeFirstResponder(editor.codeView.textView)
            t.check(retype(editor, "0,0,40,20,4 |", with: "0,0,40,20,16 |"), "typed a radius")
            t.check(editor.codeView.hasUncommittedChanges)
            guard let outline = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "shape-page-outline" }) as? NSButton
            else { return t.check(false, "Outline checkbox") }
            outline.performClick(nil)
            t.equal(editor.window?.undoManager?.undoActionName, "Edit Code", "the typing is committed at once")
            spin { shape()?.contains("StrokeWidth 0") == true }
            t.equal(shape(), "Rectangle 0,0,40,20,16 | Fill Color 255,0,0,255 | StrokeWidth 0",
                    "the typed radius and the outline change, both")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(shape(), "Rectangle 0,0,40,20,16 | Fill Color 255,0,0,255 | StrokeWidth 2",
                    "each is its own undo step: the typed code stays")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(shape(), "Rectangle 0,0,40,20,4 | Fill Color 255,0,0,255 | StrokeWidth 2")
            settle()

            // The same with the Type menu and a pop-up's value.
            t.check(retype(editor, "0,0,40,20,4 |", with: "0,0,40,30,4 |"), "typed a height")
            if let type = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "shape-page-type" }) as? NSPopUpButton,
               let line = type.itemArray.firstIndex(where: { ($0.representedObject as? String) == "Line" }) {
                type.selectItem(at: line)
                type.sendAction(type.action, to: type.target)
            }
            spin { shape()?.hasPrefix("Line") == true }
            t.equal(shape(), "Line 0,0,40,30 | Fill Color 255,0,0,255 | StrokeWidth 2", "converted from the typed height")
            settle()

            // Aligning layers after typing where one of them is: the frames come from the committed code.
            editor.canvasSelectionChanged(["Text", "VarText"])
            t.check(retype(editor, "X=10\nY=40", with: "X=30\nY=40"), "moved VarText in the code")
            editor.align(.left)
            spin { section("VarText", in: read(ini)).contains("X=10\n") }
            t.check(section("VarText", in: read(ini)).contains("X=10\n"), "aligned from where the code put it")
            editor.window?.close()
        }
    }

    // MARK: A value typed in a field lands where it was typed

    static func renumberingTests(_ t: AppTestRunner) {
        t.suite("App: studio typed values follow what they were typed for") {
            let ini = """
                [Rainmeter]
                Update=1000

                [Shapes]
                Meter=Shape
                Shape=Rectangle 0,0,10,10
                Shape2=Rectangle 20,20,10,10
                Shape3=Rectangle 40,40,10,10
                Text=Hi

                [G]
                Meter=Shape
                Y=60
                Shape=Rectangle 0,0,40,20 | Fill LinearGradient GFill
                GFill=0 | 255,0,0,255 ; 0.0 | 0,255,0,255 ; 0.3 | 0,0,255,255 ; 0.6 | 255,255,255,255 ; 1.0

                [Label]
                Meter=String
                Y=90
                Text=Hi

                """
            guard let (app, editor, url) = try openSkin(t, "Typed", ini), let window = editor.window else { return }
            func value(_ s: String, _ k: String) -> String? {
                app.controller(for: "Studio\\Typed")?.skin.document.section(named: s)?.value(forKey: k)
            }
            func find(_ id: String) -> NSView? { editor.inspectorStack.findSubview { $0.identifier?.rawValue == id } }

            // X typed into Shape2 (no Return), then ↓ (a button click does not end the editing): the value is written
            // to Shape2 first, and the move takes that shape along.
            editor.inspectorState.expandedShapes["shapes"] = "Shape2"
            editor.inspectorState.disclosures.insert("open/more:*")  // the Shape editor is in More Shape Options
            editor.select(section: "Shapes")
            guard let x = find("Shapes/Shape2/Position/X") as? NumberField else { return t.check(false, "X field") }
            t.check(window.makeFirstResponder(x), "X focused")
            x.currentEditor()?.string = "50"
            (find("shape-down") as? NSButton)?.performClick(nil)
            spin { value("Shapes", "Shape3") == "Rectangle 50,20,10,10" }
            t.equal(value("Shapes", "Shape3"), "Rectangle 50,20,10,10", "the typed X went with its shape")
            t.equal(value("Shapes", "Shape2"), "Rectangle 40,40,10,10", "the other shape is untouched")
            t.equal(editor.inspectorState.expandedShapes["shapes"], "Shape3", "the moved shape stays expanded")
            settle()

            // A position typed for a gradient color, then another color removed: written to the color it was typed for.
            editor.select(section: "G")
            guard let position = find("gradient-position-2") as? NumberField else { return t.check(false, "stop field") }
            t.check(window.makeFirstResponder(position))
            position.currentEditor()?.string = "0.5"
            (find("gradient-remove-0") as? NSButton)?.performClick(nil)
            let expected = "0 | 0,255,0,255 ; 0.3 | 0,0,255,255 ; 0.5 | 255,255,255,255 ; 1.0"
            spin { value("G", "GFill") == expected }
            t.equal(value("G", "GFill"), expected, "the blue color got 0.5; the white one kept 1.0")
            settle()

            // A rebuild while a field is being edited (here: opening a group) writes nothing: the typed text goes on
            // in the rebuilt field, and Return writes it there.
            editor.select(section: "Label")
            guard let text = find("Label/Text") as? ValueField else { return t.check(false, "Text field") }
            t.check(window.makeFirstResponder(text))
            text.currentEditor()?.string = "Typed"
            let before = read(url)
            editor.rebuildKeepingScroll()
            settle()
            t.equal(read(url), before, "nothing written by the rebuild")
            guard let again = editor.focusedInspectorField(), again.identifier?.rawValue == "Label/Text" else {
                return t.check(false, "the rebuilt field has the focus")
            }
            t.equal(again.text, "Typed", "the typing goes on in the rebuilt field")
            (editor.editedInspectorField as? ValueField)?.finishEditing(deferred: false)
            t.check(section("Label", in: read(url)).contains("Text=Typed\n"), "Return writes it to that field's option")
            window.makeFirstResponder(nil)
            editor.window?.close()
        }
    }

    // MARK: Closing and quitting write what is pending

    static func pendingEditsTests(_ t: AppTestRunner) {
        t.suite("App: studio closing and quitting write what is pending") {
            // A value typed in a field (no Return), then the window closes.
            if let (_, editor, ini) = try AppSelfTest.makeKindsEditor(t), let window = editor.window {
                editor.select(section: "Text")
                guard let size = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "Text/FontSize" }) as? NumberField
                else { return t.check(false, "font size field") }
                t.check(window.makeFirstResponder(size))
                size.currentEditor()?.string = "24"
                t.check(editor.windowShouldClose(window), "closes")
                t.check(section("StyleBig", in: read(ini)).contains("FontSize=24\n"), "the typed size is written where defined")
                window.close()
            }
            // Quitting (the app does not close its windows first) with a slider preview pending.
            if let (app, editor, ini) = try AppSelfTest.makeKindsEditor(t) {
                editor.select(section: "Pic")
                guard let percent = editor.inspectorControl(for: "ImageAlpha") as? PercentControl else {
                    return t.check(false, "opacity")
                }
                percent.slider.doubleValue = 10
                percent.slider.sendAction(percent.slider.action, to: percent.slider.target)
                t.check(editor.isPreviewingProperty, "a keyboard step waits for its pause")
                t.equal(app.applicationShouldTerminate(NSApp), .terminateNow)
                t.check(section("Pic", in: read(ini)).contains("ImageAlpha=26\n"), "written when quitting")
                t.equal(editor.window?.undoManager?.undoActionName, "Change Opacity of Dot", "as one undo step, naming its reach (the picture by its file)")
                // And a shape color picked in the color panel (the whole Shape editor's swatch, with Rainmeter Details).
                app.state.updateEditor { $0.showIniNames = true }
                editor.select(section: "Shapes")
                if let fill = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "shape-fill-color" }) as? SwatchButton {
                    ShapeColorPicker.shared.activate(fill)
                    ShapeColorPicker.shared.pickColor(RGBA(r: 0, g: 255, b: 0, a: 255))
                    t.check(editor.isPreviewingProperty)
                    t.equal(app.applicationShouldTerminate(NSApp), .terminateNow)
                    t.check(section("Shapes", in: read(ini)).contains("Fill Color 0,255,0,255"), "the picked color is written")
                    ShapeColorPicker.shared.relinquish()
                } else {
                    t.check(false, "fill swatch")
                }
                editor.window?.close()
            }
        }
    }

    // MARK: Undo takes back the change just made

    static func undoTests(_ t: AppTestRunner) {
        t.suite("App: studio undo takes back the change just made") {
            guard let (_, editor, ini) = try AppSelfTest.makeKindsEditor(t) else { return }
            guard let undo = editor.window?.undoManager else { return t.check(false, "undo manager") }
            t.check(undo === editor.editorUndoManager, "the window uses the editor's undo stack")
            editor.select(section: "Pic")
            (editor.inspectorControl(for: "ImageAlpha") as? PercentControl)?.field.type("40")
            t.check(section("Pic", in: read(ini)).contains("ImageAlpha=102\n"), "a first change")
            settle()
            // A slider step waiting for its pause, then ⌘Z: that step is what is undone, and redo brings it back.
            if let percent = editor.inspectorControl(for: "ImageAlpha") as? PercentControl {
                percent.slider.doubleValue = 10
                percent.slider.sendAction(percent.slider.action, to: percent.slider.target)
            }
            t.check(editor.isPreviewingProperty)
            undo.undo()
            t.check(section("Pic", in: read(ini)).contains("ImageAlpha=102\n"), "back to before the slider step")
            t.check(!editor.isPreviewingProperty, "nothing left to write later")
            t.check(undo.canRedo, "redo is possible")
            settle()
            undo.redo()
            t.check(section("Pic", in: read(ini)).contains("ImageAlpha=26\n"), "redo applies the step")
            settle()
            // A run of arrow-key nudges waiting for its pause.
            editor.select(section: "Text")
            editor.nudge(dx: 3, dy: 0)
            t.check(editor.hasPendingVisualEdits)
            t.check(undo.canUndo)
            undo.undo()
            t.check(section("Text", in: read(ini)).contains("X=10\n"), "the nudge is undone")
            t.check(undo.canRedo)
            settle()
            undo.redo()
            t.check(section("Text", in: read(ini)).contains("X=13\n"), "and redone")
            editor.window?.close()
        }
    }

    // MARK: Values the running skin sets

    static func runtimeValueTests(_ t: AppTestRunner) {
        t.suite("App: studio renumbering shapes keeps the files' values") {
            let ini = """
                [Rainmeter]
                Update=1000

                [Variables]
                CardColor=10,20,30
                Hover=255,255,255,40

                [MeterCard]
                Meter=Shape
                Shape=Rectangle 0,0,200,80,8 | Fill Color #CardColor#
                Shape2=Rectangle 0,0,10,10 | Fill Color 255,0,0
                Shape3=Rectangle 0,0,200,80,8 | Fill Color #CardColor#

                """
            guard let (app, editor, url) = try openSkin(t, "Card", ini) else { return }
            // Hovering the widget on the desktop: its action set Shape3 with the variable already replaced.
            app.controller(for: "Studio\\Card")?.skin
                .execute("[!SetOption MeterCard Shape3 \"Rectangle 0,0,200,80,8 | Fill Color #Hover#\"]", from: nil)
            editor.select(section: "MeterCard")
            t.equal(editor.shapeItem("Shape3", of: "MeterCard")?.row.raw, "Rectangle 0,0,200,80,8 | Fill Color 255,255,255,40",
                    "the inspector shows the running value")
            editor.removeShape("Shape2", meter: "MeterCard")
            let text = read(url)
            t.check(text.contains("Shape2=Rectangle 0,0,200,80,8 | Fill Color #CardColor#\n"),
                    "the moved shape keeps its variable: \(section("MeterCard", in: text))")
            t.check(!text.contains("Shape3="), "the last key is gone")
            t.check(!section("MeterCard", in: text).contains("255,255,255,40"), "no running value in the layer")
            t.check(editor.toastText.contains("changed while the widget ran"), editor.toastText)
            editor.window?.close()
        }
    }

    // MARK: The skin unloaded while the editor stays open

    static func unloadTests(_ t: AppTestRunner) {
        t.suite("App: studio unloading the skin saves what is pending") {
            guard let (app, editor) = try EditorWindowSelfTests.openEditor(t) else { return }
            editor.setMode(.split)
            guard let ini = app.controller(for: "Deskset\\System")?.skin.fileURL else { return t.check(false, "skin") }
            // Typing, and a nudge waiting for its pause, then the skin is unloaded (menu bar menu, !DeactivateConfig).
            editor.select(section: "MeterCPULabel")
            let y = app.controller(for: "Deskset\\System")?.skin.meter(named: "MeterCPULabel")?.rawOption("X") ?? ""
            editor.nudge(dx: 2, dy: 0)
            t.check(EditorWindowSelfTests.type(editor, "!", after: "Text=CPU\n", offset: 8), "typed")
            app.deactivate(config: "Deskset\\System")
            settle()
            t.check(editor.controller == nil, "the editor let go of the skin")
            t.check(read(ini).contains("Text=CPU!\n"), "the typing was saved before")
            t.check(!editor.codeView.hasUncommittedChanges)
            t.check(section("MeterCPULabel", in: read(ini)).contains("X=\(GeometryEdit.offset(y, by: 2))\n"),
                    "the nudge was written: \(section("MeterCPULabel", in: read(ini)))")
            t.check(app.controller(for: "Deskset\\System") == nil, "and the skin stays unloaded")
            // Code typed afterwards can still be saved (and undone), without a skin.
            t.check(EditorWindowSelfTests.type(editor, "?", after: "Text=CPU!\n", offset: 9), "typed")
            editor.saveSkinCode(nil)
            t.check(read(ini).contains("Text=CPU!?\n"), "saved without a loaded skin")
            t.check(!editor.codeView.hasUncommittedChanges)
            t.equal(editor.window?.undoManager?.undoActionName, "Edit Code")
            settle()
            editor.window?.undoManager?.undo()
            t.check(read(ini).contains("Text=CPU!\n") && !read(ini).contains("Text=CPU!?"), "undone")
            t.check(app.controller(for: "Deskset\\System") == nil, "still unloaded")
            t.check(editor.windowShouldClose(editor.window!), "closes without asking")
            editor.window?.close()
        }
    }

    // MARK: Delete removes every block

    static func deleteTests(_ t: AppTestRunner) {
        t.suite("App: studio deleting a layer removes every block of it") {
            let ini = """
                [Rainmeter]
                Update=1000
                @Include=#@#Extra.inc

                [Dup]
                Meter=String
                Text=First

                [Keep]
                Meter=String
                Y=20
                Text=Keep

                [Dup]
                Meter=Image
                W=5

                """
            let inc = "[Other]\nZ=1\n\n[Dup]\nText=From the include\n"
            guard let (app, editor, url) = try openSkin(t, "Dup", ini, files: ["@Resources/Extra.inc": inc]) else { return }
            let include = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("@Resources/Extra.inc")
            let before = (read(url), read(include))
            editor.select(section: "Dup")
            editor.deleteSelection()
            let skin = app.controller(for: "Studio\\Dup")?.skin
            t.check(skin?.meter(named: "Dup") == nil && skin?.document.section(named: "Dup") == nil,
                    "the layer does not come back after the refresh")
            t.check(skin?.meter(named: "Keep") != nil, "the rest stays")
            t.check(!read(url).contains("[Dup]") && !read(include).contains("[Dup]"), "no block left in either file")
            // Toasts never name a file (docs/editor-friendly.md §3.3).
            t.check(editor.toastText.hasPrefix("Deleted ") && !editor.toastText.contains(".in"), editor.toastText)
            settle()
            editor.window?.undoManager?.undo()
            t.check(read(url) == before.0 && read(include) == before.1, "one undo step restores both files")
            editor.window?.close()
        }
    }

    // MARK: Data sources

    static func dataSourceTests(_ t: AppTestRunner) {
        t.suite("App: studio data sources can be added") {
            guard let (app, editor, ini) = try AppSelfTest.makeKindsEditor(t) else { return }
            editor.selectSidebarTab(.data)
            let button = editor.addDataSourceButton
            t.check(!button.isHidden, "+ Add Live Data above the list")
            t.equal(button.menu?.items.first?.title, "Add Live Data")
            let items = (button.menu?.items ?? []).flatMap { [$0] + ($0.submenu?.items ?? []) }
            let names = items.compactMap { $0.representedObject as? String }
            t.equal(Set(names), Set(EditorSchema.measureTypes.filter { $0.supportedOnMac && $0.name != "Memory" }.map(\.name)),
                    "every type and plugin that works on a Mac (in Extras when not in the plain-words sections)")
            t.check(!names.contains("Registry"), "Windows-only ones only with Rainmeter details")
            editor.selectSidebarTab(.layers)
            t.check(button.isHidden, "only on the Data tab")
            editor.selectSidebarTab(.data)
            guard let cpu = button.menu?.items.first(where: { ($0.representedObject as? String) == "CPU" }) as? ClosureMenuItem
            else { return t.check(false, "CPU item") }
            _ = cpu.target?.perform(cpu.action)
            let text = read(ini)
            t.check(text.contains("[MeasureCPU]\nMeasure=CPU\n"), "added")
            if let cpuRange = text.range(of: "[MeasureCPU]"), let load = text.range(of: "[MeasureLoad]"),
               let first = text.range(of: "[Text]") {
                t.check(load.lowerBound < cpuRange.lowerBound && cpuRange.lowerBound < first.lowerBound,
                        "among the data sources, before the layers")
            }
            t.equal(editor.selectedSection, "MeasureCPU", "and selected")
            t.equal(editor.sidebarTab, .data)
            t.equal(editor.window?.undoManager?.undoActionName, "Add CPU Usage")
            settle()
            editor.window?.undoManager?.undo()
            t.check(!read(ini).contains("[MeasureCPU]"), "one undo step")
            settle()

            // "New Data Source" in a layer's "Shows" menu: created and used in one step.
            editor.select(section: "Text")
            guard let shows = editor.inspectorControl(for: "MeasureName") as? NSPopUpButton ?? editor.inspectorControl(for: "MeasureName")?
                    .subviewsMatching({ $0 is NSPopUpButton }).first as? NSPopUpButton,
                  let new = shows.menu?.items.first(where: { $0.identifier?.rawValue == "new-live-data" }),
                  let battery = new.submenu?.items.first(where: { ($0.representedObject as? String) == "PowerPlugin" }) as? ClosureMenuItem
            else { return t.check(false, "New Data Source in the Shows menu") }
            _ = battery.target?.perform(battery.action)
            let after = read(ini)
            t.check(after.contains("[MeasurePower]\nMeasure=Plugin\nPlugin=PowerPlugin\nPowerState=Percent\n"), "created")
            t.check(section("Text", in: after).contains("MeasureName=MeasurePower\n"), "and shown by the layer")
            t.equal(editor.selectedSection, "Text", "the layer stays selected")
            t.equal(app.controller(for: "Studio\\Kinds")?.skin.meter(named: "Text")?.measures.first?.name, "MeasurePower")
            settle()
            editor.window?.undoManager?.undo()
            t.check(!read(ini).contains("MeasurePower"), "one undo step for both")
            editor.window?.close()
        }
    }

    // MARK: Fool-proof controls

    static func controlTests(_ t: AppTestRunner) {
        t.suite("App: studio controls say what is in effect") {
            guard let (app, editor, ini) = try AppSelfTest.makeKindsEditor(t) else { return }
            func find(_ id: String) -> NSView? { editor.inspectorStack.findSubview { $0.identifier?.rawValue == id } }

            // Settings ▸ "Show INI option names" changes the open inspector at once.
            editor.select(section: "Text")
            func showsKeyLabel() -> Bool { editor.inspectorStack.findSubview { ($0 as? NSTextField)?.stringValue == "StringCase" } != nil }
            t.check(!showsKeyLabel())
            app.state.updateEditor { $0.showIniNames = true }
            t.check(showsKeyLabel(), "INI names shown without selecting anything else")
            app.state.updateEditor { $0.showIniNames = false }
            t.check(!showsKeyLabel(), "and hidden again")

            // An unset color shows the default the engine draws; "none" only where nothing is drawn.
            editor.select(section: "VarText")
            if let swatch = editor.inspectorControl(for: "FontColor") as? SwatchButton {
                t.equal(swatch.color, OptionValue.color("0,0,0,255"), "black text: a black swatch")
                t.check(swatch.isDefault, "marked as the default")
            } else {
                t.check(false, "FontColor swatch")
            }
            t.equal((find("FontColor.name") as? NSButton)?.title, "Default", "named, not written as numbers")
            editor.revealedGroups.insert("VarText/Box Behind It")
            editor.rebuildInspector()
            t.equal((editor.inspectorControl(for: "SolidColor") as? SwatchButton)?.color, nil, "a transparent fill")
            t.equal((find("SolidColor.name") as? NSButton)?.title, "None")

            // A choice's closed pop-up shows its plain title; "(default)" is for the open menu.
            if let clip = editor.inspectorControl(for: "ClipString") as? CompactPopUpButton {
                t.check(clip.selectedItem?.title.contains("(default)") == true, "the menu marks the default")
                t.check(!clip.shownTitle.contains("(default)") && !clip.shownTitle.isEmpty, "closed: \(clip.shownTitle)")
            } else {
                t.check(false, "ClipString pop-up")
            }

            // An invalid value of a segmented choice: a pop-up with it selected, disabled, and a warning.
            editor.writeProperty(section: "Bar", key: "BarOrientation", value: "Diagonal", variable: nil, label: "Direction")
            editor.select(section: "Bar")
            guard let orientation = editor.inspectorControl(for: "BarOrientation") as? NSPopUpButton else {
                return t.check(false, "BarOrientation=Diagonal is a pop-up, not segments")
            }
            t.equal(orientation.selectedItem?.title, "“Diagonal”")
            t.equal(orientation.selectedItem?.isEnabled, false)
            let warnings = editor.inspectorStack.subviewsMatching { $0.identifier?.rawValue == "issue" }.map { $0.accessibilityLabel() ?? "" }
            t.check(warnings.contains { $0.contains("“Diagonal” is not one of the choices for Fills toward") }, "\(warnings)")
            editor.writeProperty(section: "Bar", key: "W", value: "120", variable: nil, label: "W")
            t.check(section("Bar", in: read(ini)).contains("BarOrientation=Diagonal\n"), "not replaced by a refresh")
            settle()

            // Time zone: a menu of offsets; a zone name is flagged.
            editor.select(section: "MeasureTime")
            t.check(editor.inspectorControl(for: "TimeZone") is NSPopUpButton, "a menu")
            editor.writeProperty(section: "MeasureTime", key: "TimeZone", value: "Europe/Paris", variable: nil, label: "Time zone")
            if let zone = editor.inspectorControl(for: "TimeZone") as? NSPopUpButton {
                t.equal(zone.selectedItem?.title, "“Europe/Paris”")
                t.equal(zone.selectedItem?.isEnabled, false)
            }
            let zoneWarnings = editor.inspectorStack.subviewsMatching { $0.identifier?.rawValue == "issue" }.map { $0.accessibilityLabel() ?? "" }
            t.check(zoneWarnings.contains { $0.contains("local time is used") }, "\(zoneWarnings)")
            t.check(editor.chooseOption("TimeZone", value: "5.5"), "an offset from the menu")
            t.check(section("MeasureTime", in: read(ini)).contains("TimeZone=5.5\n"))
            editor.window?.close()

            // Two data sources with the same plain name: the closed menus tell them apart.
            guard let (_, system) = try EditorWindowSelfTests.openEditor(t) else { return }
            system.select(section: "MeterSwapValue")
            let shows = system.inspectorStack.subviewsMatching { $0 is CompactPopUpButton }
                .compactMap { $0 as? CompactPopUpButton }
                .filter { ["MeasureName", "MeasureName2"].contains($0.identifier?.rawValue ?? "") }
            t.equal(shows.map { String($0.shownTitle.split(separator: " ").first ?? "") }, ["Swap", "SwapTotal"],
                    "their names first: \(shows.map(\.shownTitle))")
            system.select(section: "MeterCPUValue")
            if let cpu = system.inspectorStack.subviewsMatching({ $0 is CompactPopUpButton && $0.identifier?.rawValue == "MeasureName" })
                .first as? CompactPopUpButton {
                t.equal(cpu.shownTitle, "CPU usage", "a unique plain name alone")
            }
            // A variable pill next to a "from Style" badge keeps its name.
            system.window?.contentView?.layoutSubtreeIfNeeded()
            let pills = system.inspectorStack.subviewsMatching { $0.identifier?.rawValue == "captions" }
                .flatMap { $0.subviewsMatching { $0 is PillView } }.compactMap { $0 as? PillView }
            t.check(!pills.isEmpty && pills.allSatisfy { !$0.nameLabel.isHidden }, "pill names shown under the controls")
            system.window?.close()
        }
    }

    // MARK: The color panel

    static func colorPanelTests(_ t: AppTestRunner) {
        t.suite("App: studio color panel after the editor closes") {
            weak var closed: Editor?
            try autoreleasepool { () throws -> Void in
                guard let (_, editor, _) = try AppSelfTest.makeKindsEditor(t) else { return }
                editor.select(section: "Text")
                guard let swatch = editor.inspectorControl(for: "FontColor") as? SwatchButton else { return t.check(false, "swatch") }
                editor.inspectorSwatchClicked(swatch)
                t.check(InspectorColorPanel.shared.owner === editor, "the panel picks for the editor")
                editor.window?.close()
                t.check(InspectorColorPanel.shared.owner == nil, "and forgets it when it closes")
                closed = editor
            }
            for _ in 0..<5 { autoreleasepool { settle() } }
            t.check(closed == nil, "the editor is gone")
            // The panel still reports (a drag in the color wheel): to an object that lives, which drops it.
            NSColorPanel.shared.color = .blue
            InspectorColorPanel.shared.colorPicked(NSColorPanel.shared)
            t.check(true, "no crash")
            NSColorPanel.shared.close()
        }
    }

    // MARK: Rebuilding the inspector

    static func rebuildTests(_ t: AppTestRunner) {
        t.suite("App: studio inspector rebuilt only when it has to be") {
            guard let (app, editor, ini) = try AppSelfTest.makeKindsEditor(t) else { return }
            editor.select(section: "Text")
            let control = editor.inspectorControl(for: "Text")
            var count = editor.inspectorRebuildCount

            // A refresh that changes nothing the inspector shows keeps its controls.
            editor.refreshClicked()
            t.equal(editor.inspectorRebuildCount, count, "no rebuild after a refresh that changed nothing shown")
            t.check(editor.inspectorControl(for: "Text") === control, "the same controls")
            // Code typed elsewhere in the file: committed and refreshed, the inspector stays.
            editor.setMode(.split)
            count = editor.inspectorRebuildCount
            t.check(EditorWindowSelfTests.type(editor, "; note\n", after: "[VarText]"), "typed above another layer")
            editor.saveSkinCode(nil)
            t.check(read(ini).contains("; note\n[VarText]"))
            t.equal(editor.inspectorRebuildCount, count, "typing in another section does not rebuild the inspector")
            // A change of the selected layer does.
            editor.writeProperty(section: "Text", key: "Prefix", value: "»", variable: nil, label: "Prefix")
            t.equal(editor.inspectorRebuildCount, count + 1, "a change of what it shows rebuilds it")
            count = editor.inspectorRebuildCount

            // Values the running skin sets (!SetOption, often on every update) update in place.
            let skin = { app.controller(for: "Studio\\Kinds")?.skin }
            skin()?.execute("[!SetOption Text FontColor \"1,100,100\"]", from: nil)
            editor.refreshLiveValues()
            t.equal(editor.inspectorRebuildCount, count + 1, "the value becoming a running one is shown once")
            count = editor.inspectorRebuildCount
            for i in 2...5 {
                skin()?.execute("[!SetOption Text FontColor \"\(i),100,100\"]", from: nil)
                editor.refreshLiveValues()
            }
            t.equal(editor.inspectorRebuildCount, count, "later values do not rebuild the inspector")
            t.equal((editor.inspectorControl(for: "FontColor") as? SwatchButton)?.color, OptionValue.color("5,100,100"),
                    "the swatch follows")
            // Nothing is rebuilt while a menu is open or a control follows the mouse.
            skin()?.execute("[!SetOption Text Postfix \"!\"]", from: nil)
            var tracked = -1
            RunLoop.main.perform(inModes: [.eventTracking]) {
                editor.refreshLiveValues()
                tracked = editor.inspectorRebuildCount
            }
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.1))
            t.equal(tracked, count, "not while tracking")
            editor.refreshLiveValues()
            t.equal(editor.inspectorRebuildCount, count + 1, "right after")

            // The font menu gets its hundreds of families when it opens, not on every rebuild.
            if let font = editor.inspectorControl(for: "FontFace") as? FontPopUpButton, let menu = font.menu {
                t.check(!font.isFilled && menu.items.count < 20, "closed: \(menu.items.count) items")
                let selected = font.selectedItem?.representedObject as? String
                font.menuNeedsUpdate(menu)
                t.check(menu.items.count > 20, "open: every family")
                t.equal(font.selectedItem?.representedObject as? String, selected, "the selection stays")
            } else {
                t.check(false, "font menu")
            }
            editor.window?.close()
        }
    }

    // MARK: Renumbering shapes defined in styles

    static func shapeOrderTests(_ t: AppTestRunner) {
        t.suite("App: studio shape order across styles") {
            guard let (app, editor) = try EditorWindowSelfTests.openEditor(t) else { return }
            guard let c = app.controller(for: "Deskset\\System") else { return t.check(false, "skin") }
            let styles = c.skin.resourcesDirectory.appendingPathComponent("Styles.inc")
            let ini = c.skin.fileURL
            let before = (styles: try Data(contentsOf: styles), ini: try Data(contentsOf: ini))
            func style(_ key: String) -> String? {
                app.controller(for: "Deskset\\System")?.skin.document.section(named: "StylePanel")?.value(forKey: key)
            }
            let panel = (style("Shape"), style("Shape2"))

            // MeterBackground's shapes all come from StylePanel (shared by the Deskset skins): reordered there.
            editor.select(section: "MeterBackground")
            editor.moveShape("Shape2", by: -1, meter: "MeterBackground")
            t.equal(style("Shape"), panel.1, "renumbered in the style")
            t.equal(style("Shape2"), panel.0)
            t.equal(try Data(contentsOf: ini), before.ini, "System.ini untouched")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: styles), before.styles, "one undo step restores Styles.inc byte for byte")
            settle()

            // MeterRAMBar: its Shape from StyleTrack, its Shape2 its own — both written on the layer.
            let track = app.controller(for: "Deskset\\System")?.skin.document.section(named: "StyleTrack")?.value(forKey: "Shape")
            editor.select(section: "MeterRAMBar")
            let own = app.controller(for: "Deskset\\System")?.skin.document.section(named: "MeterRAMBar")?.value(forKey: "Shape2")
            editor.moveShape("Shape2", by: -1, meter: "MeterRAMBar")
            let layer = app.controller(for: "Deskset\\System")?.skin.document.section(named: "MeterRAMBar")
            t.equal(layer?.value(forKey: "Shape"), own, "the layer's own shape first")
            t.equal(layer?.value(forKey: "Shape2"), track, "the style's shape copied onto the layer")
            t.equal(try Data(contentsOf: styles), before.styles, "the style is left alone")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: ini), before.ini, "undone")
            editor.window?.close()

            // A shape that only the style defines cannot be removed from the layer: nothing written, no undo step.
            let skinText = """
                [Rainmeter]
                [Look]
                Shape2=Ellipse 5,5,5
                [L]
                Meter=Shape
                MeterStyle=Look
                Shape=Rectangle 0,0,10,10

                """
            guard let (_, refusing, url) = try openSkin(t, "Refuse", skinText) else { return }
            refusing.select(section: "L")
            let untouched = read(url)
            let undoName = refusing.window?.undoManager?.undoActionName
            refusing.removeShape("Shape", meter: "L")
            t.equal(read(url), untouched, "nothing written")
            t.equal(refusing.window?.undoManager?.undoActionName, undoName, "no undo step")
            t.check(refusing.toastText.contains("This part comes from a look"), refusing.toastText)
            refusing.window?.close()
        }
    }

    // MARK: Code committed in an @Include file

    static func includeCommitTests(_ t: AppTestRunner) {
        t.suite("App: studio code committed in an included file") {
            guard let (app, editor) = try EditorWindowSelfTests.openEditor(t) else { return }
            editor.setMode(.split)
            guard let c = app.controller(for: "Deskset\\System") else { return t.check(false, "skin") }
            let styles = c.skin.resourcesDirectory.appendingPathComponent("Styles.inc")
            let ini = c.skin.fileURL
            let before = (styles: try Data(contentsOf: styles), ini: try Data(contentsOf: ini))
            guard let stylesURL = editor.codeView.files.first(where: { $0.lastPathComponent == "Styles.inc" }) else {
                return t.check(false, "Styles.inc is open in the code pane")
            }
            editor.codeView.show(file: stylesURL)
            t.check(EditorWindowSelfTests.type(editor, "; styles note\n", after: "[StyleLabel]"), "typed in Styles.inc")
            settle()
            // Leaving the file commits it (its own undo step), then the main file is typed in and saved.
            editor.codeView.show(file: ini)
            t.check(read(styles).contains("; styles note\n[StyleLabel]"), "Styles.inc committed on the way out")
            t.equal(editor.window?.undoManager?.undoActionName, "Edit Code")
            settle()
            t.check(EditorWindowSelfTests.type(editor, "!", after: "Text=CPU\n", offset: 8), "typed in System.ini")
            editor.saveSkinCode(nil)
            t.check(read(ini).contains("Text=CPU!\n"), "System.ini written")
            t.check(app.controller(for: "Deskset\\System")?.skin.includedFiles.contains { $0.lastPathComponent == "Styles.inc" } == true)
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: ini), before.ini, "the first undo takes back System.ini")
            t.check(read(styles).contains("; styles note"), "and only it")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try Data(contentsOf: styles), before.styles, "the second, Styles.inc, byte for byte")
            editor.codeView.show(file: stylesURL)
            t.check(!editor.codeView.text.contains("; styles note"), "the code pane re-read it")
            settle()
            editor.window?.undoManager?.redo()
            editor.window?.undoManager?.redo()
            t.check(read(styles).contains("; styles note") && read(ini).contains("Text=CPU!\n"), "redo applies both")
            editor.window?.close()
        }
    }

    // MARK: The window

    static func windowTests(_ t: AppTestRunner) {
        t.suite("App: studio window comes back and to the front") {
            guard let (app, editor) = try EditorWindowSelfTests.openEditor(t) else { return }
            // The jump bar names the selection's section (the caret goes there, silently).
            editor.setMode(.split)
            editor.select(section: "MeterCPUValue")
            t.equal(editor.codeView.sectionPopUp.item(at: 0)?.title, "MeterCPUValue", "the jump bar follows the selection")
            t.equal(editor.codeView.caretSection, "MeterCPUValue")
            t.check(!editor.codeView.fireCaretRest(), "not reported back as a caret move")
            editor.select(section: "StyleLabel")
            t.equal(editor.codeView.sectionPopUp.item(at: 0)?.title, "StyleLabel", "in an included file too")

            // Reopening the app (its Dock icon): the editor, Settings or a code window that is open — minimized or
            // not — before the Manage window.
            let editorWindow = NSWindow(), settings = NSWindow(), code = NSWindow()
            let open: Set<ObjectIdentifier> = [ObjectIdentifier(settings), ObjectIdentifier(code)]
            t.check(AppController.reopenTarget(editor: editorWindow, settings: settings, codeWindows: [code],
                                               isOpen: { _ in true }) === editorWindow, "the editor first")
            t.check(AppController.reopenTarget(editor: editorWindow, settings: settings, codeWindows: [code],
                                               isOpen: { open.contains(ObjectIdentifier($0)) }) === settings, "then Settings")
            t.check(AppController.reopenTarget(editor: nil, settings: nil, codeWindows: [code],
                                               isOpen: { _ in true }) === code, "then a code window")
            t.check(AppController.reopenTarget(editor: nil, settings: nil, codeWindows: [], isOpen: { _ in true }) == nil,
                    "none: the Manage window")

            // Editing the code of the skin already being edited: no re-attach, but the window comes to the front.
            guard let c = app.controller(for: "Deskset\\System") else { return t.check(false, "skin") }
            app.lastBroughtToFront = nil
            let count = editor.inspectorRebuildCount
            t.check(CodeEditorRouter.openBuiltIn(file: c.skin.fileURL, line: nil, app: app))
            t.check(app.lastBroughtToFront === editor.window, "brought to the front (activating the app)")
            t.check(app.inspector === editor && editor.controller === c, "the same editor on the same skin")
            t.equal(editor.inspectorRebuildCount, count, "not rebuilt")
            editor.window?.close()
        }
    }
}
