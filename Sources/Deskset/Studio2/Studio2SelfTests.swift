import AppKit
import DesksetCore

/// The Studio window (`StudioWindowController`): the window and its preview + code panes, the toolbar, the editing
/// session it edits through, and the widget on the desktop it follows.
enum Studio2SelfTests {
    static func run(_ t: AppTestRunner) {
        windowTests(t)
        toolbarTests(t)
        sessionTests(t)
        textTests(t)
        Studio2PreviewSelfTests.run(t)
        Studio2CodeSelfTests.run(t)
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

        """

    /// Every Studio window closed when the suite ends.
    static func prepare(_ t: AppTestRunner) {
        t.atSuiteEnd {}
    }

    /// A headless app with the widget `Studio2\<name>` loaded from `ini`.
    static func loadSkin(_ t: AppTestRunner, _ name: String, _ ini: String) throws
        -> (app: AppController, c: SkinController, url: URL)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        let folder = app.skinsDirectory.appendingPathComponent("Studio2/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).ini")
        try ini.write(to: url, atomically: true, encoding: .utf8)
        guard let c = app.activate(config: "Studio2\\\(name)", file: "\(name).ini") else {
            t.check(false, "Studio2\\\(name) loads")
            return nil
        }
        t.atSuiteEnd { StudioWindowController.window(for: app)?.window?.close() }
        return (app, c, url)
    }

    /// Opens the Studio on `c`.
    static func openNew(_ app: AppController, _ c: SkinController) -> StudioWindowController? {
        app.showInspector(for: c)
        return StudioWindowController.window(for: app)
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    // MARK: The window

    static func windowTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: panes") {
            prepare(t)
            guard let (app, c, _) = try loadSkin(t, "Panes", ini) else { return }
            guard let studio = openNew(app, c), let window = studio.window else {
                return t.check(false, "the window opens")
            }
            t.equal(window.contentView?.bounds.size, StudioWindowController.defaultSize, "1400 × 860")
            t.check(window.contentViewController === studio.splitController, "a split view controller")
            t.equal(studio.splitController.splitViewItems, [studio.codeItem, studio.canvasItem], "code on the left, preview on the right")
            t.check(studio.codeController.view.frame.width > studio.canvasController.view.frame.width,
                    "the left code pane is wider than the right preview pane")
            t.check(!studio.codeItem.isCollapsed, "the code is open alongside the preview")
            t.equal(studio.codeState.mode, .alongside)
            t.check(window.styleMask.contains(.fullSizeContentView), "the canvas reaches under the toolbar")
            t.equal(window.toolbarStyle, .unified)
            t.check(window.toolbar === studio.toolbar.toolbar, "the Studio's toolbar")

            // The canvas draws the Studio's own instance over the backdrop, which shows through it.
            let canvas = studio.canvasController.canvas
            t.check(!canvas.isEditable, "the canvas does not allow manual dragging or editing")
            t.check(!canvas.paintsSurface, "the canvas leaves its surface to the backdrop")
            t.check(SkinCanvasView().paintsSurface, "other canvases paint theirs, as before")
            t.check(canvas.enclosingScrollView === studio.canvasController.scrollView, "in a scroll view")
            t.check(studio.canvasController.backdropView.superview === studio.canvasController.view,
                    "the backdrop below it")
            t.check(studio.skin != nil && studio.skin === studio.session?.studioSkin, "the Studio's instance")
            t.check(studio.skin !== c.skin, "not the desktop copy")
            t.check(canvas.skinRect.width > 0, "the widget is on the canvas")

            // Asking again keeps the one window.
            app.showInspector(for: c)
            t.check(StudioWindowController.window(for: app) === studio, "one window at a time")

            // The name and its popover: which file runs on the desktop.
            t.equal(studio.widgetName, "Panes")
            t.equal(studio.toolbar.titleView.nameLabel.stringValue, "Panes")
            t.equal(studio.copySentence, "Made by you · on your desktop", "a skin without an author")
            studio.showRunningPopover()
            guard let running = studio.runningPopoverContent else { return t.check(false, "the popover's content") }
            _ = running.view
            t.equal(running.pathLabel.stringValue, "Skins/Studio2/Panes/Panes.ini")
            t.equal(running.finderButton.title, "Show in Finder")
            t.check(running.finderButton.isEnabled, "Show in Finder")
        }
    }

    // MARK: The toolbar

    static func toolbarTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: toolbar") {
            prepare(t)
            guard let (app, c, url) = try loadSkin(t, "Toolbar", ini) else { return }
            guard let studio = openNew(app, c), let session = studio.session else {
                return t.check(false, "the window opens")
            }
            let toolbar = studio.toolbar.toolbar
            t.equal(toolbar.items.map(\.itemIdentifier), StudioToolbarState.itemIdentifiers, "the items, in order")
            func item(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
                toolbar.items.first { $0.itemIdentifier == id }
            }
            guard let done = item(.studioDone), let title = item(.studioTitle) else {
                return t.check(false, "every item is there")
            }
            t.equal(done.label, "Done")
            t.check(title.view === studio.toolbar.titleView, "the name and sentence")

            try session.apply("Change Font Size", [.setValue(file: url, section: "MeterTitle", key: "FontSize",
                                                             value: "20", afterIncludes: false)])
            studio.undoAction(nil)
            t.check(read(url).contains("FontSize=12"), "undone")
            studio.redoAction(nil)
            t.check(read(url).contains("FontSize=20"), "redone")
        }
    }

    // MARK: The session

    static func sessionTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: editing through the session") {
            prepare(t)
            guard let (app, c, url) = try loadSkin(t, "Session", ini) else { return }
            guard let studio = openNew(app, c), let session = studio.session, let window = studio.window else {
                return t.check(false, "the window opens")
            }
            t.check(session.client === studio, "the window is the session's client")
            t.check(window.undoManager === session.undoStack, "the window's undo stack is the widget's")
            t.check(session.desktop === c, "linked to the desktop copy")
            t.check(studio.link?.isOnDesktop == true, "on the desktop")
            t.check(session.studioSkin?.host is StudioHost, "the Studio's own instance")

            // A step: on disk, in the Studio's instance, on the desktop. A value step is a patch of both (they keep
            // what they have shown); the link stays on the same desktop copy.
            let instance = session.studioSkin
            let patches = session.desktopPatchCounts.applied
            try session.apply("Change Font Size", [.setValue(file: url, section: "MeterTitle", key: "FontSize",
                                                             value: "20", afterIncludes: false)])
            t.check(read(url).contains("FontSize=20"), "written")
            t.check(session.studioSkin === instance, "the Studio's instance took it as a patch")
            t.equal(studio.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")
            func desktopSize() -> String? {
                app.controller(for: "Studio2\\Session")?.skin.meter(named: "MeterTitle")?.rawOption("FontSize")
            }
            t.check(AppSelfTest.spin {
                !session.hasPendingDesktopPatch && !session.isDesktopPatchInFlight && desktopSize() == "20"
            }, "the desktop copy took the step")
            t.equal(session.desktopPatchCounts.applied - patches, 1, "as a patch")
            guard let reloaded = app.controller(for: "Studio2\\Session") else { return t.check(false, "still loaded") }
            t.check(reloaded === c, "the same desktop copy")
            t.check(session.desktop === reloaded, "the session follows the desktop copy")
            t.check(!session.isAwaitingOwnReload, "no reload on its way")
            t.equal(reloaded.skin.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")

            // Another refresh (the widget's menu): the Studio's instance loads again too.
            let before = session.studioSkin
            app.refresh(reloaded)
            t.check(AppSelfTest.spin { session.studioSkin !== before }, "a refresh elsewhere loads the instance again")
            t.check(session.desktop === app.controller(for: "Studio2\\Session"), "linked to the refreshed copy")

            // Closing keeps the undo stack; the instance and the link go.
            studio.doneAction(nil)
            t.check(StudioWindowController.window(for: app) == nil, "Done closes the window")
            t.check(session.studioSkin == nil, "the Studio's instance is closed")
            t.check(session.client == nil, "no client")
            t.check(session.undoStack.canUndo, "the undo stack is kept")
            t.equal(session.undoStack.undoActionName, "Change Font Size")

            // Opening again: the same session and stack; the step can still be undone.
            guard let current = app.controller(for: "Studio2\\Session"),
                  let again = openNew(app, current) else { return t.check(false, "opens again") }
            t.check(again.session === session, "the same session")
            t.check(again.window?.undoManager === session.undoStack, "and its stack")
            again.undoAction(nil)
            t.check(read(url).contains("FontSize=12"), "undone after closing and opening again")

            // Unloaded: the window stays, and says so.
            app.deactivate(config: "Studio2\\Session")
            t.check(again.link?.isUnloaded == true, "the link sees the widget go")
            t.equal(again.copySentence, "Not on your desktop right now")
        }

        t.suite("Studio2: window: files changed elsewhere") {
            prepare(t)
            guard let (app, c, url) = try loadSkin(t, "Elsewhere", ini) else { return }
            guard let studio = openNew(app, c), let session = studio.session else {
                return t.check(false, "the window opens")
            }
            let before = session.studioSkin
            try ini.replacingOccurrences(of: "FontSize=12", with: "FontSize=30")
                .write(to: url, atomically: true, encoding: .utf8)
            // FSEvents (or the check below) brings the change: the widget reloads.
            studio.checkFilesOnDisk()
            t.check(AppSelfTest.spin { session.studioSkin !== before && session.studioSkin?.meter(named: "MeterTitle")?
                .rawOption("FontSize") == "30" }, "the Studio's instance took the change")
            t.check(AppSelfTest.spin {
                app.controller(for: "Studio2\\Elsewhere")?.skin.meter(named: "MeterTitle")?.rawOption("FontSize") == "30"
            }, "so did the desktop copy")
        }
    }

    // MARK: Words

    static func textTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: words") {
            for key in StudioText.Key.allCases {
                guard let entry = StudioText.table[key] else {
                    t.check(false, "\(key.rawValue) has words")
                    continue
                }
                t.check(!entry.isEmpty, "\(key.rawValue) is non-empty")
            }
            t.equal(StudioText[.done], "Done")
            t.equal(StudioText[.undo], "Undo")
            t.equal(StudioText.format(.undoNamed, "Color"), "Undo Color")
        }
    }
}
