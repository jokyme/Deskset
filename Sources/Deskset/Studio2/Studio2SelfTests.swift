import AppKit
import DesksetCore

/// The new Studio window (`StudioWindowController`): the StudioV2 switch, the window and its panes, the toolbar, the
/// editing session it edits through, the widget on the desktop it follows, and the off-screen snapshot of the
/// designed screens.
enum Studio2SelfTests {
    static func run(_ t: AppTestRunner) {
        switchTests(t)
        windowTests(t)
        toolbarTests(t)
        sessionTests(t)
        snapshotTests(t)
        textTests(t)
        Studio2PreviewSelfTests.run(t)
        Studio2PageSelfTests.run(t)
        Studio2PartSelfTests.run(t)
        Studio2SidebarSelfTests.run(t)
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

    /// English, the switch as it was and every Studio window closed when the suite ends.
    static func prepare(_ t: AppTestRunner) {
        let language = StudioText.languageOverride, on = StudioSwitch.headlessValue
        StudioText.languageOverride = .english
        t.atSuiteEnd {
            StudioText.languageOverride = language
            StudioSwitch.headlessValue = on
        }
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

    /// Opens the new Studio on `c` (the switch on).
    static func openNew(_ app: AppController, _ c: SkinController) -> StudioWindowController? {
        StudioSwitch.headlessValue = true
        app.showInspector(for: c)
        return StudioWindowController.window(for: app)
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    // MARK: The switch

    static func switchTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: the StudioV2 switch") {
            prepare(t)
            guard let (app, c, _) = try loadSkin(t, "Switch", ini) else { return }
            StudioSwitch.headlessValue = false
            t.check(!StudioSwitch.isOn(for: app), "off by default")
            t.equal(StudioSwitch.defaultsKey, "StudioV2")
            app.showInspector(for: c)
            t.check(app.inspector != nil, "off: the old Studio opens")
            t.check(StudioWindowController.window(for: app) == nil, "and no new window")
            app.inspector?.window?.close()

            guard let studio = openNew(app, c) else { return t.check(false, "on: the new window opens") }
            t.check(app.inspector == nil, "on: the old Studio does not open")
            t.check(studio.session === app.editingSession(for: c.config), "on the widget's editing session")
            // Asking again keeps the one window.
            app.showInspector(for: c)
            t.check(StudioWindowController.window(for: app) === studio, "one window at a time")

            // The hidden menu item: an Option-alternate of About Deskset.
            let menu = NSMenu()
            app.buildMainMenu(menu)
            let before = menu.items.count
            StudioSwitch.addMenuItem(to: menu, for: app)
            t.equal(menu.items.count, before + 1, "one item added")
            guard let about = menu.items.firstIndex(where: { $0.action == #selector(AppController.aboutAction) }) else {
                return t.check(false, "the menu has About Deskset")
            }
            let item = menu.items[about + 1]
            t.equal(item.title, "Use New Studio")
            t.check(item.isAlternate, "hidden until Option is held")
            t.check(item.keyEquivalentModifierMask.contains(.option), "the Option alternate")
            t.equal(item.keyEquivalent, menu.items[about].keyEquivalent, "the key equivalent of the item it stands for")
            t.equal(item.state, .on, "checked while on")
            // Turning it off closes the new window; on again closes an old one.
            app.toggleNewStudioAction(item)
            t.check(!StudioSwitch.headlessValue, "turned off")
            t.check(StudioWindowController.window(for: app) == nil, "the new window closed")
            app.showInspector(for: c)
            t.check(app.inspector != nil, "the old Studio opens again")
            app.toggleNewStudioAction(item)
            t.check(StudioSwitch.headlessValue, "turned on")
            t.check(app.inspector == nil, "the old Studio closed")
        }
    }

    // MARK: The window

    static func windowTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: panes") {
            prepare(t)
            guard let (app, c, _) = try loadSkin(t, "Panes", ini) else { return }
            guard let studio = openNew(app, c), let window = studio.window else {
                return t.check(false, "the new window opens")
            }
            t.equal(window.contentView?.bounds.size, StudioWindowController.defaultSize, "1400 × 860")
            t.check(window.contentViewController === studio.splitController, "a split view controller")
            t.equal(studio.splitController.splitViewItems.count, 4, "sidebar, canvas, code, inspector")
            t.check(studio.codeItem.isCollapsed, "the code is closed")
            t.equal(studio.sidebarItem.behavior, .sidebar, "the sidebar is a sidebar item")
            t.equal(studio.sidebarItem.minimumThickness, 256)
            t.equal(studio.sidebarItem.maximumThickness, 256)
            t.check(studio.sidebarItem.isCollapsed, "collapsed: the Studio customizes")
            t.equal(studio.depth, .customize)
            if #available(macOS 14.0, *) {
                t.equal(studio.inspectorItem.behavior, .inspector, "an inspector item")
            }
            let inspectorWidth = studio.inspectorController.view.frame.width
            t.check(inspectorWidth >= 300 && inspectorWidth <= 330, "the inspector is 300–330 pt: \(inspectorWidth)")
            t.check(window.styleMask.contains(.fullSizeContentView), "the canvas reaches under the toolbar")
            t.equal(window.toolbarStyle, .unified)
            t.check(window.toolbar === studio.toolbar.toolbar, "the Studio's toolbar")

            // The canvas draws the Studio's own instance over the backdrop, which shows through it.
            let canvas = studio.canvasController.canvas
            t.check(!canvas.paintsSurface, "the canvas leaves its surface to the backdrop")
            t.check(SkinCanvasView().paintsSurface, "other canvases paint theirs, as before")
            t.check(canvas.enclosingScrollView === studio.canvasController.scrollView, "in a scroll view")
            t.check(studio.canvasController.backdropView.superview === studio.canvasController.view,
                    "the backdrop below it")
            t.check(studio.skin != nil && studio.skin === studio.session?.studioSkin, "the Studio's instance")
            t.check(studio.skin !== c.skin, "not the desktop copy")
            t.check(canvas.skinRect.width > 0, "the widget is on the canvas")

            // Build: the sidebar opens; Customize again: it closes.
            studio.addAction(nil)
            t.equal(studio.depth, .build)
            t.check(!studio.sidebarItem.isCollapsed, "Add opens the sidebar")
            studio.setSidebarOpen(false)
            t.equal(studio.depth, .customize)
            studio.setInspectorShown(false)
            t.check(studio.inspectorItem.isCollapsed, "the inspector hides")
            studio.setInspectorShown(true)
            t.check(!studio.inspectorItem.isCollapsed, "and shows")

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

        t.suite("Studio2: window: copy sentences") {
            prepare(t)
            for (name, sentence) in [("03-customize", "Built-in widget · on your desktop"),
                                     ("13b-compat", "Rainmeter skin · compatibility mode"),
                                     ("09-every-setting", "Made by you · on your desktop")] {
                guard let screen = StudioScreen.named(name), let opened = StudioSnapshot.open(screen) else {
                    t.check(false, "\(name) opens")
                    continue
                }
                t.equal(opened.controller.copySentence, sentence, name)
                t.equal(opened.controller.toolbar.titleView.sentenceLabel.stringValue, sentence, name)
                if name == "13b-compat" {
                    t.equal(opened.controller.link?.provenance, .rainmeter(author: "Mira"))
                    t.equal(opened.controller.link?.displayPath, "Skins/Nocturne/Nocturne.ini")
                }
                opened.close()
            }
        }
    }

    // MARK: The toolbar

    static func toolbarTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: toolbar") {
            prepare(t)
            guard let (app, c, url) = try loadSkin(t, "Toolbar", ini) else { return }
            guard let studio = openNew(app, c), let session = studio.session else {
                return t.check(false, "the new window opens")
            }
            let toolbar = studio.toolbar.toolbar
            var expected: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator, .studioTitle,
                                                        .flexibleSpace, .studioUndoRedo, .studioAddCode, .flexibleSpace]
            if #available(macOS 14.0, *) {
                expected += [.inspectorTrackingSeparator, .flexibleSpace, .studioShare, .studioDone, .toggleInspector]
            } else {
                expected += [.studioShare, .studioDone, .studioInspector]
            }
            t.equal(toolbar.items.map(\.itemIdentifier), expected, "the items, in order")
            t.equal(toolbar.centeredItemIdentifiers, [.studioUndoRedo, .studioAddCode], "Undo and Add in the middle")
            func item(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
                toolbar.items.first { $0.itemIdentifier == id }
            }
            guard let undoRedo = item(.studioUndoRedo) as? NSToolbarItemGroup,
                  let addCode = item(.studioAddCode) as? NSToolbarItemGroup,
                  let share = item(.studioShare), let done = item(.studioDone), let title = item(.studioTitle) else {
                return t.check(false, "every item is there")
            }
            t.equal(undoRedo.subitems.map(\.itemIdentifier), [.studioUndo, .studioRedo])
            t.equal(undoRedo.paletteLabel, "Undo", "labelled Undo in the Customize palette")
            t.equal(undoRedo.subitems.map(\.paletteLabel), ["Undo", "Redo"])
            t.equal(addCode.subitems.map(\.itemIdentifier), [.studioAdd, .studioCode])
            t.equal(addCode.subitems.map(\.label), ["Add", "Code"])
            t.equal(studio.toolbar.addButton.title, "Add", "Add carries its word")
            t.equal(studio.toolbar.codeButton.title, "Code", "Code carries its word")
            t.equal(share.label, "Share")
            t.check(!share.isEnabled, "Share waits for a later version")
            t.equal(done.label, "Done")
            t.check(title.view === studio.toolbar.titleView, "the name and sentence")

            // Customize: Undo carries words — "Undo", then the step's name.
            let undo = studio.toolbar.undoButton
            t.equal(undo.title, "Undo", "labelled while the Studio customizes")
            t.equal(undo.imagePosition, .imageLeading)
            t.check(!undo.isEnabled, "nothing to undo yet")
            try session.apply("Change Font Size", [.setValue(file: url, section: "MeterTitle", key: "FontSize",
                                                             value: "20", afterIncludes: false)])
            t.equal(undo.title, "Undo Font Size", "the step's name")
            t.check(undo.isEnabled, "something to undo")
            t.equal(undo.toolTip, "Undo Change Font Size")
            // Build: icons only.
            studio.setSidebarOpen(true)
            t.equal(undo.title, "", "an icon while the Studio builds")
            t.equal(undo.imagePosition, .imageOnly)
            studio.setSidebarOpen(false)
            t.equal(undo.title, "Undo Font Size", "words again")
            // Undo from the toolbar.
            studio.undoAction(nil)
            t.check(read(url).contains("FontSize=12"), "undone")
            t.equal(undo.title, "Undo", "nothing left to undo")
            t.check(studio.toolbar.redoButton.isEnabled, "something to redo")
            studio.redoAction(nil)
            t.check(read(url).contains("FontSize=20"), "redone")

            t.equal(StudioToolbarState.shortName("Change Bar Color"), "Bar Color")
            t.equal(StudioToolbarState.shortName("Move Layer"), "Move Layer")
            t.equal(StudioToolbarState.shortName("Change "), "Change ")
        }
    }

    // MARK: The session

    static func sessionTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: editing through the session") {
            prepare(t)
            guard let (app, c, url) = try loadSkin(t, "Session", ini) else { return }
            guard let studio = openNew(app, c), let session = studio.session, let window = studio.window else {
                return t.check(false, "the new window opens")
            }
            t.check(session.client === studio, "the window is the session's client")
            t.check(window.undoManager === session.undoStack, "the window's undo stack is the widget's")
            t.check(session.desktop === c, "linked to the desktop copy")
            t.check(studio.link?.isOnDesktop == true, "on the desktop")
            t.check(session.studioSkin?.host is StudioHost, "the Studio's own instance")

            // A step: on disk, in the Studio's instance, on the desktop (which reloads: the link follows it).
            let instance = session.studioSkin
            try session.apply("Change Font Size", [.setValue(file: url, section: "MeterTitle", key: "FontSize",
                                                             value: "20", afterIncludes: false)])
            t.check(read(url).contains("FontSize=20"), "written")
            t.check(session.studioSkin !== instance, "the Studio's instance loaded again")
            t.equal(studio.skin?.meter(named: "MeterTitle")?.rawOption("FontSize"), "20")
            t.check(AppSelfTest.spin { app.controller(for: "Studio2\\Session") !== c }, "the desktop copy reloaded")
            guard let reloaded = app.controller(for: "Studio2\\Session") else { return t.check(false, "still loaded") }
            t.check(session.desktop === reloaded, "the session follows the new desktop copy")
            t.check(!session.isAwaitingOwnReload, "its own reload arrived")
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
            t.equal(again.toolbar.undoButton.title, "Undo Font Size", "Undo names the last step")
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
                return t.check(false, "the new window opens")
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

    // MARK: The snapshot

    static func snapshotTests(_ t: AppTestRunner) {
        t.suite("Studio2: window: snapshot") {
            prepare(t)
            t.equal(StudioScreen.names, ["03-customize", "03-customize-changed", "03b-weather", "04-part", "07-layers",
                                         "08-add", "09-every-setting", "10-preview", "12b-code-ini", "13b-compat",
                                         "17-show-on-desktop"])
            for screen in StudioScreen.all {
                guard let source = Paths.repositoryFolder(screen.fixture.source) else {
                    t.check(false, "\(screen.name): \(screen.fixture.source) is in the repository")
                    continue
                }
                let folder = source.appendingPathComponent(screen.fixture.root)
                let file = folder.appendingPathComponent(
                    screen.fixture.config.split(separator: "\\").dropFirst().joined(separator: "/"))
                    .appendingPathComponent(screen.fixture.file)
                t.check(FileManager.default.fileExists(atPath: file.path), "\(screen.name): \(file.lastPathComponent)")
            }
            // Unknown screens and bad options are mistakes in the arguments.
            t.equal(StudioSnapshot.run(["Deskset", "--snapshot-ui", "studio2"]).failure != nil, true, "no --screen")
            t.equal(StudioSnapshot.run(["Deskset", "--snapshot-ui", "studio2", "--screen", "nope"]).failure?.message
                .hasPrefix("unknown screen \"nope\""), true)
            t.equal(StudioSnapshot.run(["Deskset", "--snapshot-ui", "studio2", "--screen", "03-customize",
                                        "--language", "fr"]).failure?.message, "--language needs en or zh")
            t.equal(StudioSnapshot.run(["Deskset", "--snapshot-ui", "studio2", "--screen", "03-customize",
                                        "--size", "90000x10"]).failure != nil, true, "sizes are bounded")
            t.equal(CommandLineTools.validate(["Deskset", "--snapshot-ui", "studio2", "--screen", "03-customize",
                                               "--language", "zh", "--dark", "--size", "1400x860"]), .mode)
            t.equal(CommandLineTools.validate(["Deskset", "--screen", "03-customize"]),
                    .invalid("--screen needs one of --render, --snapshot-ui, --weather-report"))
            t.check(CommandLineTools.usage.contains("studio2"), "the help names it")

            // 03-customize: the window at 2x, the toolbar stand-ins, Stationery System on the canvas, the inspector.
            guard let screen = StudioScreen.named("03-customize"), let opened = StudioSnapshot.open(screen) else {
                return t.check(false, "03-customize opens")
            }
            defer { opened.close() }
            let studio = opened.controller
            t.equal(studio.session?.config, "Stationery\\System")
            t.equal(studio.session?.studioSkin?.fileURL.lastPathComponent, "Medium.ini")
            t.equal(studio.depth, .customize)
            t.close(studio.canvasController.canvas.zoom, 1.65, accuracy: 0.001, "the screen's zoom")
            guard let rep = StudioSnapshot.render(studio) else { return t.check(false, "renders") }
            t.equal(rep.pixelsWide, 2800)
            t.equal(rep.pixelsHigh, 1720)
            // The widget card is drawn where the canvas has it: not the backdrop's colour there.
            let card = studio.canvasController.canvas.skinRect
            let centre = studio.canvasController.canvas.convert(NSPoint(x: card.midX, y: card.minY + 8), to: nil)
            let backdropSample = rep.colorAt(x: 40 * 2, y: Int((860 - 700) * 2))
            let cardSample = rep.colorAt(x: Int(centre.x * 2), y: Int((860 - centre.y) * 2))
            t.check(backdropSample != nil && cardSample != nil && backdropSample != cardSample,
                    "the widget over the backdrop: \(String(describing: cardSample)) vs "
                        + "\(String(describing: backdropSample))")
            // The inspector column is its own colour, right of the canvas.
            let inspector = rep.colorAt(x: (1400 - 150) * 2, y: 500 * 2)
            t.check(inspector != backdropSample, "the inspector pane")
            // The rounded corners are transparent.
            t.equal(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, "the window's corner")

            // Chinese.
            StudioText.languageOverride = .chinese
            studio.updateToolbar()
            t.equal(studio.toolbar.undoButton.title, "撤销")
            t.equal(studio.copySentence, "内置小组件 · 在桌面上")
            StudioText.languageOverride = .english
            studio.updateToolbar()

            // The name's popover is composed into the snapshot.
            studio.showRunningPopover()
            _ = studio.runningPopoverContent?.view
            t.equal(studio.runningPopoverContent?.pathLabel.stringValue, "Skins/Stationery/System/Medium.ini")
            guard let withPopover = StudioSnapshot.render(studio) else { return t.check(false, "renders") }
            let below = studio.toolbar.titleView.convert(studio.toolbar.titleView.bounds, to: nil)
            let px = Int(below.midX * 2), py = Int((860 - below.minY + 40) * 2)
            t.check(withPopover.colorAt(x: px, y: py) != rep.colorAt(x: px, y: py), "the popover shows under the name")
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
                t.check(!entry.en.isEmpty && !entry.zh.isEmpty, "\(key.rawValue) in both languages")
                t.equal(entry.en.components(separatedBy: "%").count, entry.zh.components(separatedBy: "%").count,
                        "\(key.rawValue): the same blanks")
            }
            t.equal(StudioText.macLanguage(["zh-Hans-CN", "en-US"]), .chinese)
            t.equal(StudioText.macLanguage(["zh-Hant-TW"]), .english)
            t.equal(StudioText.macLanguage(["en-GB", "zh-Hans"]), .english)
            t.equal(StudioText.macLanguage([]), .english)
            t.equal(StudioLanguage(argument: "ZH"), .chinese)
            t.equal(StudioLanguage(argument: "en"), .english)
            t.equal(StudioLanguage(argument: "fr"), nil)
            t.equal(StudioText.string(.done, in: .chinese), "完成")
            t.equal(StudioText.string(.undo, in: .chinese), "撤销")
            t.equal(StudioText.string(.add, in: .chinese), "添加")
            t.equal(StudioText.string(.code, in: .chinese), "代码")
            let language = StudioText.languageOverride
            StudioText.languageOverride = .chinese
            t.equal(StudioText.format(.copyBuiltInMany, 2), "内置小组件 · 桌面上有 2 个")
            StudioText.languageOverride = .english
            t.equal(StudioText.format(.undoNamed, "Color"), "Undo Color")
            StudioText.languageOverride = language
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
