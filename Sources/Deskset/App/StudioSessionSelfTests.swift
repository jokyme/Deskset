import AppKit
import DesksetCore

/// The Studio's editing session: the Studio edits its own instance of the widget through the session; steps go to
/// memory, disk, the Studio's instance and the desktop copy; the undo stack is the widget's and outlives the window;
/// FSEvents brings changes made elsewhere; the Studio's instance keeps what would reach outside the widget to itself.
enum StudioSessionSelfTests {
    typealias Editor = InspectorWindowController

    static func run(_ t: AppTestRunner) {
        ownInstanceTests(t)
        patchTests(t)
        seedingTests(t)
        undoStackTests(t)
        filesElsewhereTests(t)
        ownWritesTests(t)
        followTests(t)
        laterTests(t)
        insideTests(t)
        failureTests(t)
        typingTests(t)
        threadTests(t)
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
            // The text in memory, and typed code once the code pane pauses (`StudioSources`).
            t.check(studio.sourceProvider === session.studioSources && session.studioSources.buffers === session.buffers,
                    "loaded from the text in memory")
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
            t.check(editor.skin === studio, "the Studio's instance took the step without loading again")
            t.equal(studio.sourceGeneration, 1, "as a patch")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")
            // On purpose: a value step reaches the desktop copy as a patch too — the same copy, not loaded again.
            t.check(app.controller(for: "Studio\\Session") === c, "the desktop copy took the step without loading again")
            t.equal(c.skin.sourceGeneration, 1, "as a patch")
            t.equal(c.skin.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")
            t.check(session.desktop === c, "and the session still follows it")
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

    /// A widget whose graphs and counter show whether the Studio's instance was loaded again: it updates only when the
    /// test says so (`Update=-1`).
    static let graphs = """
        [Rainmeter]
        Update=-1

        [MeasureCount]
        Measure=Calc
        Formula=Counter % 7
        MaxValue=7

        [MeterGraph]
        Meter=Line
        MeasureName=MeasureCount
        W=40
        H=20

        [MeterBars]
        Meter=Histogram
        MeasureName=MeasureCount
        X=44
        W=40
        H=20

        [MeterTitle]
        Meter=String
        Text=Hello
        FontSize=12
        Y=24

        """

    /// What the graphs of the Studio's instance hold.
    static func samples(_ skin: Skin?) -> [[Double]] {
        [(skin?.meter(named: "MeterGraph") as? LineMeter)?.lines.first?.history.samples ?? [],
         (skin?.meter(named: "MeterBars") as? HistogramMeter)?.primaryHistory.samples ?? []]
    }

    static func patchTests(_ t: AppTestRunner) {
        t.suite("App: studio session: steps and undos reach the Studio's instance as a patch") {
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "Patched", graphs) else { return }
            guard let session = editor.session, let studio = editor.skin else { return t.check(false, "loaded") }
            for _ in 0..<5 { studio.update() }
            let shown = samples(studio), counter = studio.counter
            t.check(shown.allSatisfy { $0.count >= 5 }, "the graphs have samples: \(shown)")
            // Selected first, so the canvas draws the same selection in every picture below.
            editor.select(section: "MeterTitle")
            let canvas = editor.canvas
            canvas.updateSize()
            func graphPixels() -> Data? {
                guard let meter = editor.skin?.meter(named: "MeterBars") else { return nil }
                let area = NSRect(x: canvas.origin.x, y: canvas.origin.y, width: CGFloat(meter.frame.maxX),
                                  height: CGFloat(meter.frame.maxY))
                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: area) else { return nil }
                canvas.cacheDisplay(in: area, to: rep)
                return rep.tiffRepresentation
            }
            let drawn = graphPixels()
            t.check(drawn != nil, "the canvas draws the graphs")

            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
            t.check(read(url).contains("FontSize=20\n"), "written")
            t.check(editor.skin === studio, "the Studio's instance took the step without loading again")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")
            t.equal(samples(editor.skin), shown, "the graphs keep their history")
            t.equal(editor.skin?.counter, counter, "and the counter")
            t.equal(graphPixels(), drawn, "the canvas draws the same graphs")
            t.check(session.lastTimings["studio.patch"] != nil && session.lastTimings["studio.reload"] == nil,
                    "timed as a patch: \(session.lastTimings.keys.sorted())")
            t.check(session.lastTimings["studio.load"] == nil && session.lastTimings["studio.update"] == nil)
            t.check(session.lastTimings["window.inspector"] != nil, "the window followed it")
            t.equal(editor.selectedSection, "MeterTitle", "the selection stays")
            settle()

            editor.window?.undoManager?.undo()
            t.equal(read(url), graphs, "undone, byte for byte")
            t.check(editor.skin === studio, "the undo is a patch too")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "12")
            t.equal(samples(editor.skin), shown, "the graphs still keep their history")
            t.equal(graphPixels(), drawn)
            t.check(session.lastTimings["studio.patch"] != nil && session.lastTimings["studio.reload"] == nil)
            settle()
            editor.window?.undoManager?.redo()
            t.check(read(url).contains("FontSize=20\n"), "redone")
            t.check(editor.skin === studio, "and so is the redo")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            editor.window?.close()
        }

        t.suite("App: studio session: a step a patch cannot make loads the instance again, graphs and counter kept") {
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "Structure", graphs) else { return }
            guard let session = editor.session, var studio = editor.skin else { return t.check(false, "loaded") }
            for _ in 0..<4 { studio.update() }
            let shown = samples(studio)
            func step(_ name: String, _ ops: [EditOp], _ what: String) {
                let counter = studio.counter
                do {
                    try session.apply(name, ops)
                } catch {
                    return t.check(false, "\(what): \(error)")
                }
                t.check(editor.skin !== studio, "\(what): the Studio's instance loaded again")
                t.check(session.lastTimings["studio.reload"] != nil && session.lastTimings["studio.load"] != nil,
                        "\(what): timed as a reload: \(session.lastTimings.keys.sorted())")
                t.equal(samples(editor.skin), shown, "\(what): the graphs keep their history")
                t.equal(editor.skin?.counter, counter + 1, "\(what): the counter goes on")
                if let now = editor.skin { studio = now }
                settle()
            }
            let added = graphs + "[MeterNew]\nMeter=String\nText=New\nY=40\n"
            step("Add Layer", [.editSource(file: url, text: added, encoding: nil)], "a layer added")
            t.check(editor.skin?.meter(named: "MeterNew") != nil)
            step("Delete Layer", [.removeSection("MeterNew", files: [url])], "a layer deleted")
            t.equal(read(url), graphs)
            step("Change Type", [.setValue(file: url, section: "MeterTitle", key: "Meter", value: "Image", afterIncludes: false)],
                 "Meter= changed")
            t.check(editor.skin?.meter(named: "MeterTitle") is ImageMeter)
            step("Change Update", [.setValue(file: url, section: "Rainmeter", key: "Update", value: "-2", afterIncludes: false)],
                 "a [Rainmeter] option changed")
            editor.window?.undoManager?.undo()
            editor.window?.undoManager?.undo()
            t.equal(read(url), graphs, "undone")
            t.check(editor.skin?.meter(named: "MeterTitle") is StringMeter, "the undo of a type change loads it again too")
            t.equal(samples(editor.skin), shown)
            editor.window?.close()
        }

        t.suite("App: studio session: a step that does not show is put back, in the files and the instance") {
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "Unshown", graphs) else { return }
            guard let session = editor.session, let studio = editor.skin else { return t.check(false, "loaded") }
            for _ in 0..<3 { studio.update() }
            let shown = samples(studio)
            var seen: String?
            do {
                try session.apply("Change Font Size",
                                  [.setValue(file: url, section: "MeterTitle", key: "FontSize", value: "30", afterIncludes: false)],
                                  verify: { skin in
                                      seen = skin.meter(named: "MeterTitle")?.rawOption("FontSize")
                                      return false
                                  })
                t.check(false, "the step is refused")
            } catch SessionError.notInEffect {
            } catch {
                t.check(false, "refused as not in effect: \(error)")
            }
            t.equal(seen, "30", "checked on the instance that took it")
            t.equal(read(url), graphs, "the file is put back")
            t.equal(session.buffers.buffer(url)?.text, graphs, "and the memory")
            t.check(editor.skin === studio, "the instance took it back without loading again")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "12", "and shows the file again")
            t.equal(samples(editor.skin), shown)
            t.check(!session.undoStack.canUndo, "no undo step")
            editor.window?.close()
        }

        t.suite("App: studio session: a change made elsewhere still loads the instance again") {
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(t, "Elsewhere", graphs) else { return }
            guard let studio = editor.skin else { return t.check(false, "loaded") }
            t.check(editor.liveReload, "live reload is on")
            try graphs.replacingOccurrences(of: "FontSize=12", with: "FontSize=14")
                .write(to: url, atomically: true, encoding: .utf8)
            let reloaded = AppSelfTest.spin(timeout: 10) {
                editor.checkFilesOnDisk()
                return editor.skin !== studio
            }
            t.check(reloaded, "loaded again")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "14")
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

            // The same bytes saved again (an editor that always writes, `touch`): reloaded as a save is, since an image
            // or a font the widget uses may have changed — the text in memory has nothing to take.
            try Data(contentsOf: url).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: url.path)
            _ = AppSelfTest.spin(timeout: 10) { app.controller(for: "Studio\\Watched") !== written }
            t.check(app.controller(for: "Studio\\Watched") !== written, "the same bytes saved again: reloaded")
            t.check(editor.skin !== studio, "the Studio's instance too")
            let touched = app.controller(for: "Studio\\Watched")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            t.check(app.controller(for: "Studio\\Watched") === touched, "once")
            // With live reload off, nothing reloads (and the touch is not reported again later).
            editor.liveReload = false
            defer { editor.liveReload = true }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            t.check(app.controller(for: "Studio\\Watched") === touched, "live reload off")
            editor.liveReload = true
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            editor.checkFilesOnDisk()
            t.check(app.controller(for: "Studio\\Watched") === touched, "that touch was seen")
            editor.window?.close()
        }
    }

    /// Reloads of `config` until `done` holds (at most `timeout` seconds; a slow CI runner may need several), and during
    /// `extra` seconds after that, to see a second reload that should not happen.
    static func reloads(_ app: AppController, _ config: String, until done: () -> Bool, timeout: TimeInterval = 20,
                        extra: TimeInterval = 0.3) -> Int {
        var seen: [SkinController] = app.controller(for: config).map { [$0] } ?? []
        func look() { if let c = app.controller(for: config), !seen.contains(where: { $0 === c }) { seen.append(c) } }
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            look()
        }
        let end = Date().addingTimeInterval(extra)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            look()
        }
        return seen.count - 1
    }

    /// Reloads of `config` while the run loop runs for `seconds`: every desktop copy seen (kept alive, so none is
    /// counted twice) but the first.
    static func reloads(_ app: AppController, _ config: String, during seconds: TimeInterval) -> Int {
        var seen: [SkinController] = app.controller(for: config).map { [$0] } ?? []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if let c = app.controller(for: config), !seen.contains(where: { $0 === c }) { seen.append(c) }
        }
        return seen.count - 1
    }

    static func ownWritesTests(_ t: AppTestRunner) {
        t.suite("App: studio session: what the widget writes as it reloads is its own") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Seeded", seeded) else { return }
            guard let session = editor.session else { return t.check(false, "session") }
            // A step the desktop copy loads again for (a value step is a patch: nothing closes).
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true),
                           .init(section: "Rainmeter", key: "ContextTitle", value: "Seeded", own: true)],
                          name: "Change Font Size")
            t.check(read(url).contains("FontSize=20\n"), "written")
            t.check(!read(url).contains("Seed=0\n"), "and the old copy wrote its seed as it closed")
            t.equal(session.buffers.buffer(url)?.text, read(url), "the memory took the widget's own write")
            t.equal(editor.skin?.variable("Seed"), app.controller(for: "Studio\\Seeded")?.skin.variable("Seed"),
                    "the Studio's instance follows it")
            let toast = editor.toastText
            t.check(toast.hasPrefix("Changed"), toast)
            t.equal(reloads(app, "Studio\\Seeded", during: 1.5), 0, "no reload follows, let alone a loop")
            t.equal(editor.toastText, toast, "the step's toast stays")
            t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
            // The same after an undo (refused here: the widget changed the file the step left) and the Refresh button.
            editor.refreshSkin()
            t.equal(reloads(app, "Studio\\Seeded", during: 1.5), 0, "after Refresh")
            t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
            editor.window?.close()
        }

        t.suite("App: studio session: a widget that counts its loads counts one per step") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Counting", counting) else { return }
            guard let session = editor.session else { return t.check(false, "session") }
            func loads() -> Int? { loadsWritten(url) }
            _ = AppSelfTest.spin(timeout: 5) { loads() == 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            t.equal(loads(), 1, "the desktop copy counted its first load")
            t.equal(session.host.policy.recorded.filter { $0.name == "writekeyvalue" }.count, 1,
                    "the Studio's instance did not write")
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "21", own: true)], name: "Change Font Size")
            t.equal(loads(), 2, "one load for the step")
            t.equal(session.buffers.buffer(url)?.text, read(url), "taken into memory")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "21")
            t.equal(reloads(app, "Studio\\Counting", during: 1.5), 0, "no reload follows")
            t.equal(loads(), 2, "no more loads")
            if editor.isCodeVisible { t.check(editor.codeView.text.contains("Loads=2"), "the code pane follows") }
            // And again for the next step.
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "22", own: true)], name: "Change Font Size")
            t.equal(loads(), 3)
            t.equal(reloads(app, "Studio\\Counting", during: 1), 0)
            editor.window?.close()
        }

        t.suite("App: studio session: a script that rewrites an include as it loads does not start a loop") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Generated", generated,
                                                                              files: generatedFiles("Generated"))
            else { return }
            guard let session = editor.session else { return t.check(false, "session") }
            let gen = url.deletingLastPathComponent().appendingPathComponent("Gen.inc")
            let written = read(gen)
            t.check(written.hasPrefix("[Variables]\nGen=") && written != "[Variables]\nGen=0\n", "the desktop copy wrote it")
            t.equal(reloads(app, "Studio\\Generated", during: 1.5), 0, "opening the Studio reloads nothing")
            t.equal(read(gen), written, "the Studio's instance wrote to a copy of its own")
            t.check(session.host.policy.recorded.contains { $0.kind == .file && $0.text.hasSuffix("Gen.inc") },
                    "and that was recorded: \(session.host.policy.recorded.map(\.text))")
            t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
            // A step reloads the desktop copy, which writes it again: its own write.
            editor.select(section: "MeterTitle")
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "19", own: true)], name: "Change Font Size")
            t.check(read(gen) != written, "written by the reloaded desktop copy")
            t.equal(session.buffers.buffer(gen)?.text, read(gen), "taken into memory")
            t.equal(reloads(app, "Studio\\Generated", during: 1.5), 0, "no loop")
            t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
            editor.window?.close()
        }
    }

    static func followTests(_ t: AppTestRunner) {
        t.suite("App: studio session: the canvas follows clicks on the widget on the desktop") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Paged", paged) else { return }
            guard let c = app.controller(for: "Studio\\Paged"), let session = editor.session, let studio = editor.skin else {
                return t.check(false, "loaded")
            }
            // Hovered on the desktop (as the widget's window reports it): the canvas shows the hover.
            c.skin.mouseMoved(x: 5, y: 5)
            t.equal(studio.meter(named: "Tab2")?.rawOption("SolidColor"), "255,0,0", "the hover")
            // Clicked on the desktop: page 2, in the dark theme, on the canvas too — where its layers can be picked.
            c.skin.mouseEvent(.leftUp, x: 5, y: 5)
            t.equal(studio.meter(named: "P2")?.hidden, false, "page 2 on the canvas")
            t.equal(studio.meter(named: "P1")?.hidden, true)
            t.equal(studio.variable("Theme"), "dark")
            t.equal(read(url).contains("Theme=dark\n"), true, "the desktop copy wrote the theme")
            t.check(session.host.policy.recorded.contains { $0.name == "writekeyvalue" }, "the Studio's instance did not")
            _ = AppSelfTest.spin(timeout: 5) { session.buffers.buffer(url)?.text.contains("Theme=dark\n") == true }
            t.check(session.buffers.buffer(url)?.text.contains("Theme=dark\n") == true, "the memory took its write")
            t.check(app.controller(for: "Studio\\Paged") === c, "not reloaded: the widget wrote its own file")
            t.check(editor.skin === studio, "nor the Studio's instance, which already shows it")
            t.equal(editor.skin?.meter(named: "P2")?.hidden, false, "still on page 2")
            editor.canvasSelectionChanged(["P2"])
            t.equal(editor.selectedSection, "P2", "a layer of page 2 can be picked")
            c.skin.mouseExited()
            t.equal(studio.meter(named: "Tab2")?.rawOption("SolidColor"), "0,0,0", "the hover ends")
            editor.window?.close()
            // The window closed: the desktop copy's input goes nowhere.
            t.check(app.controller(for: "Studio\\Paged")?.skin.inputMirror == nil, "no mirror without a Studio")
        }
    }

    static func laterTests(_ t: AppTestRunner) {
        t.suite("App: studio session: the desktop copy follows a moment later") {
            guard let (app, editor, url) = try StudioReviewSelfTests.openSkin(t, "Later", ini) else { return }
            guard let session = editor.session, let c = app.controller(for: "Studio\\Later") else {
                return t.check(false, "loaded")
            }
            // As in the app (headless, the desktop copy follows at once).
            app.defersDesktopUpdates = true
            defer { app.defersDesktopUpdates = false }
            editor.select(section: "MeterTitle")
            func fontSize() -> String? { c.skin.meter(named: "MeterTitle")?.rawOption("FontSize") }
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
            t.check(read(url).contains("FontSize=20\n"), "written")
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "20", "the canvas shows the step at once")
            // On purpose: a value step reaches the desktop copy as a patch, on the next turn.
            t.check(session.hasPendingDesktopPatch, "the desktop copy takes it on the next turn, as a patch")
            t.check(!session.hasScheduledDesktopRefresh, "not a reload")
            t.equal(fontSize(), "12", "not yet")
            // A burst of steps: one patch.
            let patched = session.desktopPatchCounts.applied
            editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "21", own: true)], name: "Change Font Size")
            t.equal(reloads(app, "Studio\\Later", until: { !session.hasPendingDesktopPatch }), 0, "no reload")
            t.check(!session.hasPendingDesktopPatch)
            t.equal(session.desktopPatchCounts.applied - patched, 1, "one patch for both steps")
            t.check(app.controller(for: "Studio\\Later") === c, "the same desktop copy")
            t.equal(fontSize(), "21")
            t.check((session.lastTimings["desktop"] ?? 0) > 0, "timed: \(session.lastTimings)")
            // Undo the same way (both steps came in one event: one undo step).
            editor.window?.undoManager?.undo()
            t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "12", "undone on the canvas at once")
            t.equal(fontSize(), "21", "the desktop copy on the next turn")
            // (After what else waits on the main thread: the inspector follows the undo first.)
            t.check(AppSelfTest.spin(timeout: 5) { !session.hasPendingDesktopPatch }, "patched")
            t.check(app.controller(for: "Studio\\Later") === c, "still the same desktop copy")
            t.equal(fontSize(), "12")
            settle()

            // A step the desktop copy must load again for (a `[Rainmeter]` option) reloads it on the next turn.
            func title() -> String? { app.controller(for: "Studio\\Later")?.skin.rainmeterSection?.rawOption("ContextTitle") }
            editor.commit([.init(section: "Rainmeter", key: "ContextTitle", value: "One", own: true)], name: "Change Title")
            t.check(read(url).contains("ContextTitle=One\n"), "written")
            t.check(app.controller(for: "Studio\\Later") === c, "the desktop copy loads it on the next turn")
            t.check(session.hasScheduledDesktopRefresh)
            editor.checkFilesOnDisk()
            t.check(editor.pendingDiskCheck, "changes on disk wait for it")
            // A burst of steps: one reload.
            editor.commit([.init(section: "Rainmeter", key: "ContextTitle", value: "Two", own: true)], name: "Change Title")
            t.equal(reloads(app, "Studio\\Later", until: { !session.hasScheduledDesktopRefresh }), 1, "one reload for both steps")
            t.check(!session.hasScheduledDesktopRefresh)
            t.equal(title(), "Two")
            let before = app.controller(for: "Studio\\Later")
            editor.window?.undoManager?.undo()
            t.check(app.controller(for: "Studio\\Later") === before, "the desktop copy on the next turn")
            t.check(AppSelfTest.spin(timeout: 5) { !session.hasScheduledDesktopRefresh }, "reloaded")
            t.check(app.controller(for: "Studio\\Later") !== before)
            t.equal(title(), nil, "undone")
            settle()

            // A gesture: the first preview reaches the desktop at once, later ones at most 20 times a second — always
            // the latest values; the Studio's instance shows every one.
            guard let box = editor.skin?.meter(named: "MeterBox") else { return t.check(false, "box") }
            editor.canvasSelectionChanged(["MeterBox"])
            let start = NSPoint(x: editor.canvas.origin.x + CGFloat(box.frame.x + 5),
                                y: editor.canvas.origin.y + CGFloat(box.frame.y + 5))
            func desktopX() -> Double? { app.controller(for: "Studio\\Later")?.skin.meter(named: "MeterBox")?.frame.x }
            editor.canvas.beginGesture(.move, at: start)
            editor.canvas.drag(to: NSPoint(x: start.x + 10, y: start.y), snapping: false)
            t.equal(desktopX(), 10, "the first preview at once")
            editor.canvas.drag(to: NSPoint(x: start.x + 20, y: start.y), snapping: false)
            editor.canvas.drag(to: NSPoint(x: start.x + 30, y: start.y), snapping: false)
            t.equal(editor.skin?.meter(named: "MeterBox")?.frame.x, 30, "the canvas follows every event")
            t.equal(desktopX(), 10, "the desktop copy waits")
            _ = AppSelfTest.spin(timeout: 2) { desktopX() == 30 }
            t.equal(desktopX(), 30, "then gets the latest values")
            editor.canvas.endGesture(keep: false)
            t.equal(desktopX(), 0, "a cancelled gesture ends the previews there too")
            t.check(app.controller(for: "Studio\\Later")?.skin.isPreviewing == false)
            t.check(!read(url).contains("X=30"), "nothing written")
            editor.window?.close()
        }
    }

    static func insideTests(_ t: AppTestRunner) {
        t.suite("App: studio session: plugins of the Studio's instance know it is paused, and where the widget is") {
            guard let (app, editor, _) = try StudioReviewSelfTests.openSkin(t, "Host", ini) else { return }
            guard let c = app.controller(for: "Studio\\Host"), let session = editor.session,
                  let host = editor.skin?.host as? LiveSkinHost else { return t.check(false, "loaded") }
            t.check(host === session.host, "the Studio's host")
            t.check(!host.areUpdatesPaused)
            // Sleep, a locked screen: NowPlaying's reads of a paused instance only peek (the players are not polled).
            session.setUpdatesPaused(true)
            t.check(host.areUpdatesPaused, "paused with the widgets on the desktop")
            session.setUpdatesPaused(false)
            t.check(!host.areUpdatesPaused)
            // Chameleon samples the wallpaper of the screen the desktop copy is on, not the Studio window's.
            t.equal(host.windowDisplay, c.window.screen.flatMap(DesktopInputs.displayID(of:)), "the desktop copy's screen")
            editor.window?.close()
        }

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
        t.suite("App: studio session: typed code for a file deleted meanwhile is saved as a new file") {
            let included = ini.replacingOccurrences(of: "[Variables]\n", with: "[Variables]\n@Include=Styles.inc\n")
            guard let (_, editor, url) = try StudioReviewSelfTests.openSkin(
                t, "Deleted", included, files: ["Deleted/Styles.inc": "[Variables]\nSize=12\n"]) else { return }
            let inc = url.deletingLastPathComponent().appendingPathComponent("Styles.inc")
            editor.setMode(.split)
            _ = editor.revealInCode(file: inc, line: 1)
            t.equal(editor.codeView.currentFile?.lastPathComponent, "Styles.inc", "shown in the code pane")
            t.check(EditorWindowSelfTests.type(editor, "4", after: "Size=12", offset: 7), "typed")
            // Deleted elsewhere (a git checkout, the Trash) while the typing waits for its commit.
            try FileManager.default.removeItem(at: inc)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            editor.saveSkinCode(nil)
            t.check(!editor.toastText.hasPrefix("Could not save"), editor.toastText)
            t.equal(read(inc), "[Variables]\nSize=124\n", "created again with the typed code")
            t.check(!editor.codeView.hasUncommittedChanges, "nothing left to save")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(try? Data(contentsOf: inc), Data(), "undo leaves it empty, as the editor always wrote it back")
            editor.window?.close()
        }

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

// MARK: - Widgets the suites share

extension StudioSessionSelfTests {
    /// Writes a new value each time it closes: taken for a change made elsewhere, it would reload the widget, which
    /// writes again, and so on.
    static let seeded = ini.replacingOccurrences(of: "[Rainmeter]\nUpdate=1000\n", with: """
        [Rainmeter]
        Update=1000
        OnCloseAction=[!WriteKeyValue Variables Seed [MeasureRandom]]

        [MeasureRandom]
        Measure=Calc
        Formula=Random
        LowBound=1
        HighBound=1000000000
        UpdateRandom=1

        """).replacingOccurrences(of: "[Variables]\n", with: "[Variables]\nSeed=0\n")

    /// Counts its loads in its own file (OnRefreshAction).
    static let counting = ini.replacingOccurrences(of: "[Rainmeter]\nUpdate=1000\n", with: """
        [Rainmeter]
        Update=1000
        OnRefreshAction=[!WriteKeyValue Variables Loads (#Loads#+1)]

        """).replacingOccurrences(of: "[Variables]\n", with: "[Variables]\nLoads=0\n")

    /// The loads `counting` counted in `url`.
    static func loadsWritten(_ url: URL) -> Int? {
        read(url).components(separatedBy: "\n").first { $0.hasPrefix("Loads=") }.flatMap { Int($0.dropFirst(6)) }
    }

    /// Includes a file its script writes anew as it loads (`generatedFiles`).
    static let generated = ini.replacingOccurrences(of: "[Variables]\n", with: "[Variables]\n@Include=Gen.inc\n")
        + """

        [MeasureGen]
        Measure=Script
        ScriptFile=gen.lua

        """

    /// `generated`'s script and include, for a widget in `folder` (under Studio).
    static func generatedFiles(_ folder: String) -> [String: String] {
        let lua = """
            function Initialize()
              local f = io.open(SKIN:MakePathAbsolute('Gen.inc'), 'w')
              f:write('[Variables]\\nGen=' .. os.time() .. '-' .. math.random(1, 1000000000) .. '\\n')
              f:close()
            end
            function Update() return 0 end
            """
        return ["\(folder)/gen.lua": lua, "\(folder)/Gen.inc": "[Variables]\nGen=0\n"]
    }

    /// Pages turned by a click, a theme it writes to its file, a hover.
    static let paged = """
        [Rainmeter]
        Update=1000

        [Variables]
        Theme=light

        [Tab2]
        Meter=Image
        SolidColor=0,0,0
        W=20
        H=20
        LeftMouseUpAction=[!HideMeterGroup Page1][!ShowMeterGroup Page2][!SetVariable Theme dark][!WriteKeyValue Variables Theme dark]
        MouseOverAction=[!SetOption Tab2 SolidColor 255,0,0][!UpdateMeter Tab2]
        MouseLeaveAction=[!SetOption Tab2 SolidColor 0,0,0][!UpdateMeter Tab2]

        [P1]
        Meter=String
        Y=30
        Text=one
        Group=Page1

        [P2]
        Meter=String
        Y=30
        Text=two #Theme#
        Group=Page2
        Hidden=1
        DynamicVariables=1

        """
}

// MARK: - The desktop copy on a thread of its own

/// The suites about reloads and following the desktop copy again, with the desktop copy on test threads
/// (`SkinThreadExecutor`, through `AppController.skinExecutor`; docs/skin-threading.md §8.5, §15 phase 2 step 6): the
/// Studio's instance stays on the main thread, and the desktop copy is reached only through messages, its snapshot, its
/// window controller and exclusive access. Its reloads report when their work gets there, so every wait here is for a
/// condition; only "nothing reloads" is watched over a stretch of time, as in the suites above.
extension StudioSessionSelfTests {
    /// A Studio on a widget whose copies on the desktop run on test threads: the first on `threads[0]`, every later one
    /// on the last thread (two threads let a test hold the old copy while the new one starts).
    final class Threaded {
        let app: AppController
        let editor: Editor
        let url: URL
        let config: String
        let threads: [SkinThreadExecutor]
        private var skins: [() -> Skin?] = []

        init(app: AppController, editor: Editor, url: URL, config: String, threads: [SkinThreadExecutor]) {
            self.app = app
            self.editor = editor
            self.url = url
            self.config = config
            self.threads = threads
        }

        var session: EditingSession? { editor.session }
        /// The copy on the desktop now.
        var desktop: SkinController? { app.controller(for: config) }

        /// What the copy on the desktop now answers, read on its thread while it waits (nil: it did not let go).
        func live<T>(_ body: (Skin) -> T) -> T? {
            guard let c = desktop else { return nil }
            note(c)
            return c.runtime.exclusive(timeout: 30, body)
        }

        /// Waits until the reload the session asked for has ended and the copy on the desktop has started.
        @discardableResult
        func settle() -> Bool {
            let done = AppSelfTest.spin(timeout: 30) { [self] in
                guard let session, !session.isAwaitingOwnReload, let c = desktop else { return false }
                return c.isStarted
            }
            if let c = desktop { note(c) }
            return done
        }

        /// Keeps track of a copy's skin (weakly), to wait for it to be let go of at the end.
        func note(_ c: SkinController) {
            weak var skin = c.runtime.skin
            skins.append { skin }
        }

        /// Closes the Studio, unloads the widget, waits for the skins of the copies it saw to be let go of on their
        /// threads, and ends the threads.
        func finish(_ t: AppTestRunner) {
            // (What AppKit autoreleases meanwhile goes before the wait.)
            autoreleasepool {
                editor.window?.close()
                app.inspector?.window?.close()
                app.deactivate(config: config)
            }
            t.check(AppSelfTest.spin(timeout: 30) { self.skins.allSatisfy { $0() == nil } },
                    "the copies' skins are let go of")
            for thread in threads { thread.stop() }
        }
    }

    /// `StudioReviewSelfTests.openSkin` with the copies on the desktop on `threads` test threads (see `Threaded`). The
    /// Studio opens once the first copy has started.
    static func openOnThread(_ t: AppTestRunner, _ name: String, _ text: String, files: [String: String] = [:],
                             threads count: Int = 1) throws -> Threaded? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let folder = app.skinsDirectory.appendingPathComponent("Studio/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, content) in files {
            let url = app.skinsDirectory.appendingPathComponent("Studio").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let url = folder.appendingPathComponent("\(name).ini")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let config = "Studio\\\(name)"
        let threads = (0..<max(count, 1)).map { SkinThreadExecutor(name: "Studio \(name) \($0 + 1)") }
        var loads = 0
        app.skinExecutor = { asked in
            guard asked.caseInsensitiveCompare(config) == .orderedSame else { return MainSkinExecutor.shared }
            defer { loads += 1 }
            return threads[min(loads, threads.count - 1)]
        }
        guard let c = app.activate(config: config, file: "\(name).ini"),
              AppSelfTest.spin(timeout: 30, until: { c.isStarted }) else {
            t.check(false, "\(config) starts on its thread")
            threads.forEach { $0.stop() }
            return nil
        }
        app.showInspector(for: c)
        guard let editor = app.inspector else {
            t.check(false, "the editor opens")
            threads.forEach { $0.stop() }
            return nil
        }
        let threaded = Threaded(app: app, editor: editor, url: url, config: config, threads: threads)
        threaded.note(c)
        return threaded
    }

    /// Runs `body` on a Studio opened by `openOnThread`, then `Threaded.finish` (once what the opening and `body`
    /// held, and what AppKit autoreleased meanwhile, has gone).
    static func onThread(_ t: AppTestRunner, _ name: String, _ text: String, files: [String: String] = [:],
                         threads: Int = 1, _ body: (Threaded) throws -> Void) throws {
        let opened: Threaded? = try autoreleasepool {
            guard let w = try openOnThread(t, name, text, files: files, threads: threads) else { return nil }
            try body(w)
            return w
        }
        opened?.finish(t)
    }

    static func threadTests(_ t: AppTestRunner) {
        threadOwnWritesTests(t)
        threadFollowTests(t)
        threadInsideTests(t)
        threadSeedingTests(t)
    }

    static func threadOwnWritesTests(_ t: AppTestRunner) {
        t.suite("App: studio session: on a thread, what the widget writes as it reloads is its own") {
            try onThread(t, "SeededThread", seeded) { w in
                guard let session = w.session else { return t.check(false, "session") }
                let editor = w.editor, url = w.url
                t.check(w.desktop?.runtime.executor !== MainSkinExecutor.shared, "the desktop copy runs on a thread")
                editor.select(section: "MeterTitle")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
                t.check(read(url).contains("FontSize=20\n"), "written")
                t.check(w.settle(), "the reload ends once the old copy closed and the new one started")
                t.check(!read(url).contains("Seed=0\n"), "and the old copy wrote its seed as it closed")
                t.equal(session.buffers.buffer(url)?.text, read(url), "the memory took the widget's own write")
                t.equal(editor.skin?.variable("Seed"), w.live { $0.variable("Seed") }, "the Studio's instance follows it")
                t.equal(w.live { $0.meter(named: "MeterTitle")?.rawOption("FontSize") }, "20", "the desktop copy shows the step")
                t.check(session.desktop === w.desktop, "the session follows the new copy")
                let toast = editor.toastText
                t.check(toast.hasPrefix("Changed"), toast)
                t.equal(reloads(w.app, w.config, during: 1.5), 0, "no reload follows, let alone a loop")
                t.equal(editor.toastText, toast, "the step's toast stays")
                t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
                editor.refreshSkin()
                t.check(w.settle(), "Refresh")
                t.equal(reloads(w.app, w.config, during: 1.5), 0, "after Refresh")
                t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
            }
        }

        t.suite("App: studio session: on threads, the old copy's OnCloseAction may write after the new copy started") {
            // The old copy on one thread, held there; the new one starts on another.
            try onThread(t, "SeededLate", seeded, threads: 2) { w in
                guard let session = w.session, let old = w.desktop else { return t.check(false, "session") }
                let editor = w.editor, url = w.url
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(w.threads[0])
                editor.select(section: "MeterTitle")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
                let toast = editor.toastText
                t.check(toast.hasPrefix("Changed"), toast)
                t.check(AppSelfTest.spin(timeout: 30) { w.desktop !== old && w.desktop?.isStarted == true },
                        "the new copy started")
                if let c = w.desktop { w.note(c) }
                t.check(w.desktop?.runtime.executor === w.threads[1], "on the other thread")
                t.check(session.isAwaitingOwnReload, "the reload waits for the old copy's close")
                t.check(read(url).contains("Seed=0\n"), "which has not run yet")
                t.check(session.desktop === w.desktop, "the Studio follows the new copy already")
                gate.open()
                t.check(AppSelfTest.spin(timeout: 30) { !session.isAwaitingOwnReload }, "the reload ends with the close")
                t.check(old.hasClosed, "the old copy reported its close")
                t.check(!read(url).contains("Seed=0\n"), "written as it closed")
                t.equal(session.buffers.buffer(url)?.text, read(url), "the memory took the widget's own write")
                t.equal(reloads(w.app, w.config, during: 1.5), 0, "no reload follows")
                t.equal(editor.toastText, toast, "the step's toast stays")
                t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
            }
        }

        t.suite("App: studio session: on a thread, a widget that counts its loads counts one per step") {
            try onThread(t, "CountingThread", counting) { w in
                guard let session = w.session else { return t.check(false, "session") }
                let editor = w.editor, url = w.url
                t.equal(loadsWritten(url), 1, "the desktop copy counted its first load")
                t.equal(session.host.policy.recorded.filter { $0.name == "writekeyvalue" }.count, 1,
                        "the Studio's instance did not write")
                editor.select(section: "MeterTitle")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "21", own: true)], name: "Change Font Size")
                t.check(w.settle(), "reloaded")
                t.equal(loadsWritten(url), 2, "one load for the step")
                t.equal(session.buffers.buffer(url)?.text, read(url), "taken into memory")
                t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "21")
                t.equal(reloads(w.app, w.config, during: 1.5), 0, "no reload follows")
                t.equal(loadsWritten(url), 2, "no more loads")
                editor.select(section: "MeterTitle")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "22", own: true)], name: "Change Font Size")
                t.check(w.settle(), "reloaded again")
                t.equal(loadsWritten(url), 3)
                t.equal(reloads(w.app, w.config, during: 1), 0)
            }
        }

        t.suite("App: studio session: on a thread, a script that rewrites an include as it loads does not start a loop") {
            try onThread(t, "GeneratedThread", generated, files: generatedFiles("GeneratedThread")) { w in
                guard let session = w.session else { return t.check(false, "session") }
                let editor = w.editor
                let gen = w.url.deletingLastPathComponent().appendingPathComponent("Gen.inc")
                let written = read(gen)
                t.check(written.hasPrefix("[Variables]\nGen=") && written != "[Variables]\nGen=0\n", "the desktop copy wrote it")
                t.equal(reloads(w.app, w.config, during: 1.5), 0, "opening the Studio reloads nothing")
                t.equal(read(gen), written, "the Studio's instance wrote to a copy of its own")
                t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
                editor.select(section: "MeterTitle")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "19", own: true)], name: "Change Font Size")
                t.check(w.settle(), "reloaded")
                t.check(read(gen) != written, "written by the reloaded desktop copy")
                t.equal(session.buffers.buffer(gen)?.text, read(gen), "taken into memory")
                t.equal(reloads(w.app, w.config, during: 1.5), 0, "no loop")
                t.check(!editor.toastText.contains("changed on disk"), editor.toastText)
            }
        }
    }

    static func threadFollowTests(_ t: AppTestRunner) {
        t.suite("App: studio session: on a thread, the canvas follows clicks on the widget on the desktop") {
            try onThread(t, "PagedThread", paged) { w in
                guard let c = w.desktop, let session = w.session, let studio = w.editor.skin else {
                    return t.check(false, "loaded")
                }
                let editor = w.editor, url = w.url
                // As the widget's window reports it: messages to the desktop copy, whose input the Studio replays.
                c.runtime.send(.hover(x: 5, y: 5))
                t.check(AppSelfTest.spin(timeout: 30) { studio.meter(named: "Tab2")?.rawOption("SolidColor") == "255,0,0" },
                        "the hover")
                c.runtime.send(.mouse(.leftUp, x: 5, y: 5))
                t.check(AppSelfTest.spin(timeout: 30) { studio.meter(named: "P2")?.hidden == false }, "page 2 on the canvas")
                t.equal(studio.meter(named: "P1")?.hidden, true)
                t.equal(studio.variable("Theme"), "dark")
                t.check(read(url).contains("Theme=dark\n"), "the desktop copy wrote the theme")
                t.check(session.host.policy.recorded.contains { $0.name == "writekeyvalue" }, "the Studio's instance did not")
                t.check(AppSelfTest.spin(timeout: 30) { session.buffers.buffer(url)?.text.contains("Theme=dark\n") == true },
                        "the memory took its write")
                t.equal(reloads(w.app, w.config, during: 1.5), 0, "not reloaded: the widget wrote its own file")
                t.check(w.desktop === c)
                t.check(editor.skin === studio, "nor the Studio's instance, which already shows it")
                t.equal(editor.skin?.meter(named: "P2")?.hidden, false, "still on page 2")
                editor.canvasSelectionChanged(["P2"])
                t.equal(editor.selectedSection, "P2", "a layer of page 2 can be picked")
                c.runtime.send(.exited)
                t.check(AppSelfTest.spin(timeout: 30) { studio.meter(named: "Tab2")?.rawOption("SolidColor") == "0,0,0" },
                        "the hover ends")
                editor.window?.close()
                t.equal(c.runtime.exclusive(timeout: 30) { $0.inputMirror == nil }, true, "no mirror without a Studio")
            }
        }

        t.suite("App: studio session: on a thread, the desktop copy follows a moment later") {
            try onThread(t, "LaterThread", ini) { w in
                guard let session = w.session, let c = w.desktop else { return t.check(false, "loaded") }
                let app = w.app, editor = w.editor, url = w.url
                app.defersDesktopUpdates = true
                defer { app.defersDesktopUpdates = false }
                editor.select(section: "MeterTitle")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
                t.check(read(url).contains("FontSize=20\n"), "written")
                t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "20", "the canvas shows the step at once")
                t.check(w.desktop === c, "the desktop copy loads it on the next turn")
                t.check(session.hasScheduledDesktopRefresh)
                editor.checkFilesOnDisk()
                t.check(editor.pendingDiskCheck, "changes on disk wait for it")
                editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "21", own: true)], name: "Change Font Size")
                t.equal(reloads(app, w.config, during: 0.3), 1, "one reload for both steps")
                t.check(!session.hasScheduledDesktopRefresh)
                t.check(w.settle(), "the new copy started")
                t.equal(w.live { $0.meter(named: "MeterTitle")?.rawOption("FontSize") }, "21")
                t.check((session.lastTimings["desktop"] ?? 0) > 0, "timed: \(session.lastTimings)")
                let before = w.desktop
                editor.window?.undoManager?.undo()
                t.equal(editor.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "12", "undone on the canvas at once")
                t.check(w.desktop === before, "the desktop copy on the next turn")
                t.check(AppSelfTest.spin(timeout: 5) { !session.hasScheduledDesktopRefresh }, "reloaded")
                t.check(w.settle(), "the new copy started")
                t.equal(w.live { $0.meter(named: "MeterTitle")?.rawOption("FontSize") }, "12")

                // A gesture: the previews are messages to the desktop copy, at most 20 a second, always the latest values.
                guard let box = editor.skin?.meter(named: "MeterBox") else { return t.check(false, "box") }
                editor.canvasSelectionChanged(["MeterBox"])
                let start = NSPoint(x: editor.canvas.origin.x + CGFloat(box.frame.x + 5),
                                    y: editor.canvas.origin.y + CGFloat(box.frame.y + 5))
                func desktopX() -> Double? { w.live { skin -> Double? in skin.meter(named: "MeterBox")?.frame.x } ?? nil }
                editor.canvas.beginGesture(.move, at: start)
                editor.canvas.drag(to: NSPoint(x: start.x + 10, y: start.y), snapping: false)
                t.equal(desktopX(), 10, "the first preview at once")
                editor.canvas.drag(to: NSPoint(x: start.x + 20, y: start.y), snapping: false)
                editor.canvas.drag(to: NSPoint(x: start.x + 30, y: start.y), snapping: false)
                t.equal(editor.skin?.meter(named: "MeterBox")?.frame.x, 30, "the canvas follows every event")
                t.equal(desktopX(), 10, "the desktop copy waits")
                t.check(AppSelfTest.spin(timeout: 5) { desktopX() == 30 }, "then gets the latest values")
                editor.canvas.endGesture(keep: false)
                t.equal(desktopX(), 0, "a cancelled gesture ends the previews there too")
                t.equal(w.live { $0.isPreviewing }, false)
                t.check(!read(url).contains("X=30"), "nothing written")
            }
        }
    }

    static func threadInsideTests(_ t: AppTestRunner) {
        t.suite("App: studio session: on a thread, plugins of the Studio's instance know it is paused, and where the widget is") {
            try onThread(t, "HostThread", ini) { w in
                guard let c = w.desktop, let session = w.session, let studio = w.editor.skin,
                      let host = studio.host as? StudioHost else { return t.check(false, "loaded") }
                t.check(host === session.host, "the Studio's host")
                session.setUpdatesPaused(true)
                t.check(host.areUpdatesPaused, "paused with the widgets on the desktop")
                session.setUpdatesPaused(false)
                t.check(!host.areUpdatesPaused)
                t.equal(host.windowDisplay, c.window.screen.flatMap(DesktopInputs.displayID(of:)), "the desktop copy's screen")
                // The desktop copy's place, from its window controller.
                c.moveTo(x: 321, y: 123)
                t.equal(host.environment(for: studio).windowFrame.x, 321, "#CURRENTCONFIGX#")
                t.equal(host.environment(for: studio).windowFrame.y, 123)
                t.equal(c.runtime.exclusive(timeout: 30) { $0.variable("CURRENTCONFIGX") }, "321",
                        "as the desktop copy reads it")
                // A reload by a step whose new copy has not started: the Studio's instance keeps the widget's place.
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(w.threads[0])
                w.editor.select(section: "MeterTitle")
                w.editor.commit([.init(section: "MeterTitle", key: "FontSize", value: "20", own: true)], name: "Change Font Size")
                t.check(w.desktop !== c && w.desktop?.isStarted == false, "the new copy waits to load")
                t.equal(w.editor.skin.map { host.environment(for: $0).windowFrame.x }, 321, "the Studio's instance keeps the place")
                t.check(w.editor.isWidgetRunning, "the widget counts as on the desktop meanwhile")
                gate.open()
                t.check(w.settle(), "the new copy started")
                t.equal(w.editor.skin.map { host.environment(for: $0).windowFrame.x }, 321, "where the old one was")
            }
        }

        t.suite("App: studio session: on a thread, a step that moves the widget moves it once the new copy started") {
            try onThread(t, "MovedThread", ini) { w in
                guard let c = w.desktop, let session = w.session else { return t.check(false, "loaded") }
                c.moveTo(x: 100, y: 100)
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(w.threads[0])
                let place = WidgetPosition(x: 150, y: 170)
                try session.apply("Move", [.setValue(file: w.url, section: "MeterTitle", key: "FontSize", value: "18",
                                                     afterIncludes: false)],
                                  commands: [.moveWidget(from: WidgetPosition(x: 100, y: 100), to: place)])
                guard let fresh = w.desktop, fresh !== c else { return t.check(false, "a new copy") }
                t.check(!fresh.isStarted, "not started")
                t.close(c.topLeftPosition.x, 100, accuracy: 0.5, "nothing moved yet")
                gate.open()
                t.check(w.settle(), "started")
                t.close(fresh.topLeftPosition.x, 150, accuracy: 0.5, "then the window moved")
                t.close(fresh.topLeftPosition.y, 170, accuracy: 0.5)
                t.equal(fresh.showCount, 1)
            }
        }
    }

    static func threadSeedingTests(_ t: AppTestRunner) {
        let graph = """
            [Rainmeter]
            Update=-1

            [MeasureCount]
            Measure=Calc
            Formula=Counter % 7
            MaxValue=7

            [MeterGraph]
            Meter=Line
            MeasureName=MeasureCount
            W=40
            H=20

            """
        t.suite("App: studio session: on a thread, the Studio opens on the graphs the desktop shows") {
            try onThread(t, "GraphThread", graph) { w in
                w.editor.window?.close()
                guard let c = w.desktop else { return t.check(false, "loaded") }
                for _ in 0..<6 { c.runtime.send(.update(hops: 0)) }
                let shown = w.live { skin -> ([Double], Int, Double?) in
                    let line = (skin.meter(named: "MeterGraph") as? LineMeter)?.lines[0].history
                    let samples = line.map { h in (0..<h.count).map { h.value(age: $0) } } ?? []
                    return (samples, skin.counter, skin.measure(named: "MeasureCount")?.value)
                }
                w.app.showInspector(for: c)
                guard let editor = w.app.inspector, let studio = editor.skin?.meter(named: "MeterGraph") as? LineMeter else {
                    return t.check(false, "the Studio shows the graph")
                }
                let history = studio.lines[0].history
                t.equal((0..<history.count).map { history.value(age: $0) }, shown?.0, "the desktop's samples, in order")
                t.equal(editor.skin?.counter, shown?.1, "the counter the desktop shows")
                t.equal(editor.skin?.measure(named: "MeasureCount")?.value, shown?.2)
                editor.window?.close()

                // A desktop copy busy past the wait: the Studio's instance starts from its own first update.
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(w.threads[0])
                w.app.showInspector(for: c)
                t.equal(w.app.inspector?.skin?.counter, 1, "its own first update")
                gate.open()
            }
        }
    }
}
