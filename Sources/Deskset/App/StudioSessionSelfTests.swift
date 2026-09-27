import AppKit
import DesksetCore

/// The Studio's editing session: the Studio edits its own instance of the widget through the session; steps go to
/// memory, disk, the Studio's instance and the desktop copy; the undo stack is the widget's and outlives the window;
/// FSEvents brings changes made elsewhere; the Studio's instance keeps what would reach outside the widget to itself.
enum StudioSessionSelfTests {
    typealias Editor = InspectorWindowController

    static func run(_ t: AppTestRunner) {
        ownInstanceTests(t)
        seedingTests(t)
        undoStackTests(t)
        filesElsewhereTests(t)
        insideTests(t)
        failureTests(t)
        typingTests(t)
    }

    static let ini = """
        [Rainmeter]
        Update=1000

        [Variables]
        Color=255,0,0

        [MeterTitle]
        Meter=String
        Text=Hello
        FontSize=12
        FontColor=#Color#

        [MeterBox]
        Meter=Image
        SolidColor=0,0,0
        X=0
        Y=30
        W=50
        H=20

        """

    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    static func ownInstanceTests(_ t: AppTestRunner) {
        t.suite("App: studio session: the Studio edits its own instance of the widget") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Session", ini) else { return }
            guard let c = app.controller(for: "Studio\\Session"), let session = editor.session, let studio = editor.skin else {
                return t.check(false, "the editor shows the widget")
            }
            t.check(studio !== c.skin, "the Studio's instance is not the desktop copy")
            t.check(studio.host is StudioHost, "hosted by the Studio")
            t.check(studio.sourceProvider === session.buffers, "loaded from the text in memory")
            t.check(studio.actionPolicy === session.host.policy, "its actions filtered")
            t.check(session.desktop === c, "linked to the desktop copy")
            t.check(editor.window?.undoManager === session.undoStack, "the window's undo stack is the widget's")
            t.check(app.editingSession(for: "studio\\session") === session, "the app keeps one session per widget")
            t.equal(session.buffers.buffer(url)?.text, read(url), "the files are in memory")
            t.check(session.isWatchingFiles, "and watched")

            // A step: in memory, on disk, in the Studio's instance, on the desktop, on the undo stack.
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
            t.check(read(url).contains("FontSize=20\n"), "written")
            t.equal(session.buffers.buffer(url)?.text, read(url), "the memory and the disk agree")
            t.check(!session.diskSync.hasUnwrittenChanges, "nothing left to write")
            t.check(editor.skin !== studio, "the Studio's instance loaded again")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")
            guard let reloaded = app.controller(for: "Studio\\Session") else { return t.check(false, "still loaded") }
            t.check(reloaded !== c, "the desktop copy reloaded")
            t.equal(reloaded.skin.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")
            t.check(session.desktop === reloaded, "and the session follows it")
            t.equal(session.undoStack.undoActionName, "Change Font Size")
            t.check((session.lastTimings["total"] ?? 0) > 0, "timed: \(session.lastTimings)")
            settle()

            // A gesture: previewed in both, then written once.
            guard let box = editor.skin?.meter(named: "MeterBox") else { return t.check(false, "box") }
            editor.canvasSelectionChanged(["MeterBox"])
            let start = NSPoint(x: editor.canvas.origin.x + CGFloat(box.frame.x + 5),
                                y: editor.canvas.origin.y + CGFloat(box.frame.y + 5))
            editor.canvas.beginGesture(.move, at: start)
            editor.canvas.drag(to: NSPoint(x: start.x + 10, y: start.y), snapping: false)
            t.check(editor.skin?.isPreviewing == true, "the Studio's instance shows the drag")
            t.check(app.controller(for: "Studio\\Session")?.skin.isPreviewing == true, "so does the desktop copy")
            t.equal(app.controller(for: "Studio\\Session")?.skin.meter(named: "MeterBox")?.frame.x, 10, "where it is dragged")
            t.check(!read(url).contains("X=10"), "nothing written yet")
            editor.canvas.endGesture(keep: true)
            t.check(read(url).contains("X=10\n"), "written when it ends")
            t.check(editor.skin?.isPreviewing == false, "the previews end")
            t.check(app.controller(for: "Studio\\Session")?.skin.isPreviewing == false)
            t.equal(app.controller(for: "Studio\\Session")?.skin.meter(named: "MeterBox")?.frame.x, 10)
            settle()

            // Undo and redo go through the widget's stack, and reach the disk and the desktop.
            editor.window?.undoManager?.undo()
            t.check(read(url).contains("X=0\n"), "undone")
            t.equal(app.controller(for: "Studio\\Session")?.skin.meter(named: "MeterBox")?.frame.x, 0)
            t.equal(editor.skin?.meter(named: "MeterBox")?.frame.x, 0)
            t.check(editor.toastText.hasPrefix("Undid"), editor.toastText)
            settle()
            editor.window?.undoManager?.redo()
            t.check(read(url).contains("X=10\n"), "redone")
            settle()
            editor.window?.undoManager?.undo()
            editor.window?.undoManager?.undo()
            t.equal(read(url), ini, "back to the bytes it started from")
            editor.window?.close()
        }
    }

    static func seedingTests(_ t: AppTestRunner) {
        t.suite("App: studio session: the Studio opens on the graphs the desktop shows") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            let folder = app.skinsDirectory.appendingPathComponent("Studio/Graph")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
                [Rainmeter]
                Update=1000

                [MeasureCount]
                Measure=Calc
                Formula=Counter % 7
                MaxValue=7

                [MeterGraph]
                Meter=Line
                MeasureName=MeasureCount
                W=40
                H=20

                """.write(to: folder.appendingPathComponent("Graph.ini"), atomically: true, encoding: .utf8)
            guard let c = app.activate(config: "Studio\\Graph", file: "Graph.ini") else { return t.check(false, "loads") }
            for _ in 0..<6 { c.skin.update() }
            guard let desktop = c.skin.meter(named: "MeterGraph") as? LineMeter else { return t.check(false, "graph") }
            let shown = (0..<desktop.lines[0].history.count).map { desktop.lines[0].history.value(age: $0) }
            app.showInspector(for: c)
            guard let editor = app.inspector, let studio = editor.skin?.meter(named: "MeterGraph") as? LineMeter else {
                return t.check(false, "the Studio shows the graph")
            }
            t.check(editor.skin !== c.skin)
            let history = studio.lines[0].history
            t.equal((0..<history.count).map { history.value(age: $0) }, shown, "the desktop's samples, in order")
            t.equal(editor.skin?.measure(named: "MeasureCount")?.value, c.skin.measure(named: "MeasureCount")?.value,
                    "the counter the desktop shows")
            t.equal(editor.skin?.counter, c.skin.counter)
            editor.window?.close()
        }
    }

    static func undoStackTests(_ t: AppTestRunner) {
        t.suite("App: studio session: the undo stack belongs to the widget") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Kept", ini) else { return }
            guard let session = editor.session else { return t.check(false, "session") }
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "Text", value: "Kept", own: true)], name: "Edit Text")
            settle()
            editor.window?.close()
            t.check(app.inspector == nil, "the window closed")
            t.check(session.studioSkin == nil, "the Studio's instance went with it")
            t.check(!session.isWatchingFiles, "and the watching of the files")
            t.check(session.client == nil)
            t.check(session.undoStack.canUndo, "the step stays with the widget")

            // Undone without a window: the files and the desktop copy follow.
            let before = app.controller(for: "Studio\\Kept")
            session.undoStack.undo()
            t.check(read(url).contains("Text=Hello\n"), "undone")
            t.check(app.controller(for: "Studio\\Kept") !== before, "the desktop copy reloaded")
            t.check(session.undoStack.canRedo)
            session.undoStack.redo()
            t.check(read(url).contains("Text=Kept\n"), "redone")
            // Refreshed on the desktop while no window follows it: the undo still reaches the widget running now.
            guard let running = app.controller(for: "Studio\\Kept") else { return t.check(false, "running") }
            app.refresh(running)
            let refreshed = app.controller(for: "Studio\\Kept")
            t.check(refreshed != nil && refreshed !== running, "refreshed")
            session.undoStack.undo()
            t.check(app.controller(for: "Studio\\Kept") !== refreshed, "the widget running now reloaded")
            t.equal(app.controller(for: "Studio\\Kept")?.skin.meter(named: "MeterTitle")?.rawOption("Text"), "Hello")
            session.undoStack.redo()
            t.check(read(url).contains("Text=Kept\n"), "redone")

            // The Studio opened again has the same stack.
            guard let c = app.controller(for: "Studio\\Kept") else { return t.check(false, "loaded") }
            app.showInspector(for: c)
            guard let again = app.inspector else { return t.check(false, "opens again") }
            t.check(again.window?.undoManager === session.undoStack, "the same stack")
            t.equal(again.window?.undoManager?.undoActionName, "Edit Text")
            again.window?.undoManager?.undo()
            t.check(read(url).contains("Text=Hello\n"), "undone from the new window")
            t.equal(again.skin?.meter(named: "MeterTitle")?.rawOption("Text"), "Hello")

            // Another widget has a stack of its own; this one's is still there when the Studio comes back to it.
            settle()
            again.commit([.init(section: "MeterTitle", key: "Text", value: "Mine", own: true)], name: "Edit Text")
            guard let clock = app.activate(config: "Deskset\\Clock", file: nil) else { return t.check(false, "Clock") }
            app.showInspector(for: clock)
            t.check(again.session === app.editingSession(for: "Deskset\\Clock"), "the Clock's session")
            t.check(again.window?.undoManager?.canUndo == false, "with nothing on its stack")
            t.check(session.studioSkin == nil, "the first widget's instance went")
            guard let kept = app.controller(for: "Studio\\Kept") else { return t.check(false, "loaded") }
            app.showInspector(for: kept)
            t.check(again.window?.undoManager === session.undoStack)
            t.equal(again.window?.undoManager?.undoActionName, "Edit Text", "its step is still there")
            again.window?.close()
        }

        t.suite("App: studio session: steps outside the files outlive the window too") {
            guard let (app, editor, _) = try StudioReviewSelfTests.openSkin(t, "Settings", ini) else { return }
            guard let session = editor.session, let c = app.controller(for: "Studio\\Settings") else {
                return t.check(false, "loaded")
            }
            let key = "studio\\settings"
            let stacking = c.state.alwaysOnTop
            // A desktop setting (ON YOUR DESKTOP) and a lock (the editor's own) are steps of the widget's stack.
            editor.setStacking(1)
            t.equal(app.controller(for: "Studio\\Settings")?.state.alwaysOnTop, 1, "on top")
            settle()
            editor.setLayersLocked(["MeterTitle"], locked: true)
            t.check(app.state.editor.editorLocks[key]?.contains("metertitle") == true, "locked")
            settle()
            editor.window?.close()
            t.check(session.undoStack.undoActionName.hasPrefix("Lock"), "kept with the widget: \(session.undoStack.undoActionName)")

            // Undone with no window: the widget's settings and the locks follow, nothing else is asked for.
            session.undoStack.undo()
            t.check(app.state.editor.editorLocks[key]?.contains("metertitle") != true, "unlocked")
            session.undoStack.undo()
            t.equal(app.controller(for: "Studio\\Settings")?.state.alwaysOnTop, stacking, "back to how it was stacked")
            t.check(session.undoStack.canRedo)

            // Redone from a window opened again, which follows.
            guard let now = app.controller(for: "Studio\\Settings") else { return t.check(false, "running") }
            app.showInspector(for: now)
            guard let again = app.inspector else { return t.check(false, "opens again") }
            again.window?.undoManager?.redo()
            t.equal(app.controller(for: "Studio\\Settings")?.state.alwaysOnTop, 1, "on top again")
            t.check(again.toastText.hasPrefix("Redid"), again.toastText)
            again.window?.undoManager?.redo()
            t.check(again.isLayerLocked("MeterTitle"), "locked again, as the window shows")
            again.window?.undoManager?.undo()
            again.window?.undoManager?.undo()
            again.window?.close()
        }
    }

    static func filesElsewhereTests(_ t: AppTestRunner) {
        t.suite("App: studio session: FSEvents brings changes made elsewhere") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Watched", ini) else { return }
            guard let c = app.controller(for: "Studio\\Watched"), let session = editor.session else {
                return t.check(false, "loaded")
            }
            t.check(editor.liveReload, "live reload is on")
            // Saved by another app: nobody calls the editor; FSEvents does.
            try read(url).replacingOccurrences(of: "Text=Hello", with: "Text=Elsewhere").write(to: url, atomically: true,
                                                                                               encoding: .utf8)
            _ = AppSelfTest.spin(timeout: 10) { app.controller(for: "Studio\\Watched") !== c }
            t.check(app.controller(for: "Studio\\Watched") !== c, "the widget reloaded")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("Text"), "Elsewhere", "the Studio shows the change")
            t.equal(session.buffers.buffer(url)?.text, read(url), "the memory took it")
            t.check(editor.toastText.contains("changed on disk"), editor.toastText)

            // Its own writes are not changes made elsewhere: no second reload.
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "15", own: true)], name: "Change Font Size")
            let written = app.controller(for: "Studio\\Watched")
            let studio = editor.skin
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            t.check(app.controller(for: "Studio\\Watched") === written, "no reload for the Studio's own write")
            t.check(editor.skin === studio)

            // The same bytes saved again change nothing.
            try Data(contentsOf: url).write(to: url)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            t.check(app.controller(for: "Studio\\Watched") === written, "the same bytes: no reload")
            editor.window?.close()
        }
    }

    static func insideTests(_ t: AppTestRunner) {
        t.suite("App: studio session: the Studio's instance keeps its effects inside the widget") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Inside", ini) else { return }
            guard let c = app.controller(for: "Studio\\Inside"), let session = editor.session, let studio = editor.skin else {
                return t.check(false, "loaded")
            }
            let frame = c.window.frame
            let bytes = read(url)
            studio.execute("[!SetOption MeterTitle Text Inside][!UpdateMeter MeterTitle]"
                           + "[!WriteKeyValue Variables Marker studio][!Move 5 5][\"https://example.com\"]"
                           + "[!ActivateConfig \"Deskset\\Clock\"]", from: nil)
            t.equal(studio.meter(named: "MeterTitle")?.rawOption("Text"), "Inside", "inside the widget: done")
            t.equal(read(url), bytes, "no file written")
            t.equal(c.window.frame, frame, "the desktop window stays")
            t.check(app.controller(for: "Deskset\\Clock") == nil, "no other widget loaded")
            t.equal(session.host.policy.recorded.map(\.name), ["writekeyvalue", "move", "https://example.com",
                                                                "activateconfig"], "recorded instead")
            t.equal(c.skin.meter(named: "MeterTitle")?.rawOption("Text"), "Hello", "the desktop copy is left alone")
            editor.window?.close()
        }
    }

    static func typingTests(_ t: AppTestRunner) {
        t.suite("App: studio session: typing in the window's fields stays with the window") {
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "Typed", ini) else { return }
            guard let window = editor.window, let session = editor.session else { return t.check(false, "loaded") }
            editor.select(section: "MeterTitle")
            guard let field = editor.inspectorControl(for: "Text") as? ValueField else {
                return t.check(false, "the Text field")
            }
            t.check(window.makeFirstResponder(field), "the field has the keyboard")
            guard let typing = field.currentEditor() as? NSTextView else { return t.check(false, "field editor") }
            typing.selectAll(nil)
            typing.insertText("Typed", replacementRange: typing.selectedRange())
            t.check(window.makeFirstResponder(nil), "editing ends")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            t.check(read(url).contains("Text=Typed\n"), "written")
            window.close()
            // The widget's stack keeps the edit, and nothing of the typing in the window's field editor.
            t.check(session.undoStack.canUndo, "the edit")
            session.undoStack.undo()
            t.check(read(url).contains("Text=Hello\n"), "the edit undone")
            t.check(!session.undoStack.canUndo, "nothing else on the stack")
        }
    }

    static func failureTests(_ t: AppTestRunner) {
        t.suite("App: studio session: a step that cannot be written changes nothing") {
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "Locked", ini) else { return }
            guard let session = editor.session, let studio = editor.skin else { return t.check(false, "loaded") }
            let folder = url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "30", own: true)], name: "Change Font Size")
            t.check(editor.toastText.hasPrefix("Could not save"), editor.toastText)
            t.equal(read(url), ini, "the file is as it was")
            t.equal(session.buffers.buffer(url)?.text, ini, "and so is the memory")
            t.check(!session.diskSync.hasUnwrittenChanges)
            t.check(editor.skin === studio, "the Studio's instance was not loaded again")
            t.check(!session.undoStack.canUndo, "no undo step")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "30", own: true)], name: "Change Font Size")
            t.check(read(url).contains("FontSize=30\n"), "written once it can be")
            editor.window?.close()
        }
    }
}
