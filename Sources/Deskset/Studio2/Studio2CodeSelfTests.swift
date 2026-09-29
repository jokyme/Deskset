import AppKit
import DesksetCore

/// The new Studio's code pane (beside the canvas, or in the inspector's place; typing as one step, byte for byte), its
/// INI diagnostics (under their lines, on the canvas, with Fix), the desktop keeping the last working version while a
/// part can't draw, the selection both ways, the log, and the menus (every toolbar item has one, no key twice).
enum Studio2CodeSelfTests {
    static func run(_ t: AppTestRunner) {
        paneTests(t)
        typingTests(t)
        holdTests(t)
        diagnosticsTests(t)
        selectionTests(t)
        logTests(t)
        menuTests(t)
        duplicateDeleteTests(t)
        closingTests(t)
        knownProblemTests(t)
    }

    /// Only a red problem the desktop's version does not have holds it: a skin that already misses a picture still
    /// reaches the desktop with each step; a new problem holds it, and the other widgets reading a shared file written
    /// meanwhile load again once the hold ends.
    static func knownProblemTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: a problem the desktop already has does not hold it") {
            Studio2SelfTests.prepare(t)
            let ini = ["[Rainmeter]", "Update=1000", "", "[Variables]", "@Include=#@#Shared.inc", "",
                       "[MeterPic]", "Meter=Image", "ImageName=missing.png", "W=20", "H=20", "",
                       "[MeterTitle]", "Meter=String", "Text=Hello", "FontColor=255,255,255", "X=30", "",
                       "[MeterBar]", "Meter=Bar", "MeterStyle=StyleBar", "Y=30", ""].joined(separator: "\n")
            guard let (app, c, _) = try Studio2SelfTests.loadSkin(t, "HoldKnown", ini) else { return }
            let shared = app.skinsDirectory.appendingPathComponent("Studio2/@Resources/Shared.inc")
            try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "[StyleBar]\nW=(#BarWidth#)\nH=6\n\n[Variables]\nBarWidth=100\n".write(to: shared, atomically: true,
                                                                                         encoding: .utf8)
            let otherFolder = app.skinsDirectory.appendingPathComponent("Studio2/HoldOther")
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
            try "[Variables]\n@Include=#@#Shared.inc\n\n[MeterBar]\nMeter=Bar\nMeterStyle=StyleBar\n"
                .write(to: otherFolder.appendingPathComponent("HoldOther.ini"), atomically: true, encoding: .utf8)
            guard app.activate(config: "Studio2\\HoldOther", file: "HoldOther.ini") != nil else {
                return t.check(false, "the other widget")
            }
            app.refresh(c)
            guard let c2 = app.controller(for: "Studio2\\HoldKnown"), let studio = Studio2SelfTests.openNew(app, c2),
                  let session = studio.session, let skin = studio.skin else { return t.check(false, "opens") }
            t.check(IniDiagnostics.hasProblems(studio.diagnostics(of: skin)), "the widget misses a picture already")
            studio.codeView.idleCommitDelay = 60
            studio.setCodeMode(.alongside)
            t.check(type(studio, replacing: "FontColor=255,255,255", with: "FontColor=255,0,0"))
            studio.codeView.commitNow()
            t.check(!session.isHoldingDesktop, "a problem the desktop has already: not held")
            t.check(AppSelfTest.spin(timeout: 5) {
                app.controller(for: "Studio2\\HoldKnown")?.skin.meter(named: "MeterTitle")?.option("FontColor") == "255,0,0"
            }, "the desktop copy loads the step")
            AppSelfTest.spin(timeout: 0.05) { false }

            // A new problem in the shared file: this widget is held, and so is the other one reading the file.
            let other = app.controller(for: "Studio2\\HoldOther")
            studio.codeView.show(file: shared)
            t.check(type(studio, replacing: "W=(#BarWidth#)", with: "W=(#BarWidth# *)"))
            studio.codeView.commitNow()
            t.check(session.isHoldingDesktop, "a new red problem holds the desktop")
            AppSelfTest.spin(timeout: 0.3) { false }
            t.check(app.controller(for: "Studio2\\HoldOther") === other, "the other widget keeps its version too")
            // Fixed: this widget reloads, and the other one once.
            AppSelfTest.spin(timeout: 0.05) { false }
            t.check(type(studio, replacing: "(#BarWidth# *)", with: "(#BarWidth# * 2)"))
            studio.codeView.commitNow()
            t.check(!session.isHoldingDesktop)
            t.check(AppSelfTest.spin(timeout: 5) { app.controller(for: "Studio2\\HoldOther") !== other },
                    "the other widget loads the fixed file")
            // Held when the window lets go: nothing waits any more, the desktop keeps what it runs.
            AppSelfTest.spin(timeout: 0.05) { false }
            t.check(type(studio, replacing: "(#BarWidth# * 2)", with: "(#BarWidth# *)"))
            studio.codeView.commitNow()
            t.check(session.isHoldingDesktop)
            let held = app.controller(for: "Studio2\\HoldKnown")
            studio.window?.close()
            t.check(!session.isHoldingDesktop, "the hold ends with the window")
            AppSelfTest.spin(timeout: 0.3) { false }
            t.check(app.controller(for: "Studio2\\HoldKnown") === held, "and the desktop keeps its last working version")
            t.equal(app.controller(for: "Studio2\\HoldKnown")?.skin.meter(named: "MeterBar")?.rawOption("W"),
                    "(#BarWidth# * 2)", "the fixed bar, not the broken one")
        }
    }

    /// Edits waiting for their pause are made before an undo (the undo takes them back, and Redo stays), and before
    /// the window closes; typed code that can't be saved is asked about when closing or quitting.
    static func closingTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: waiting edits before an undo, and closing with code that can't be saved") {
            guard let (_, studio, url, _) = open(t, "CodeClosing"), let session = studio.session else { return }
            func x() -> String? { studio.skin?.meter(named: "MeterTitle")?.fileOption("X") }
            studio.select(part: "MeterTitle")
            studio.geometry.nudge(dx: 10, dy: 0)
            studio.geometry.commitNudge()
            t.equal(x(), "20", "moved: one step")
            AppSelfTest.spin(timeout: 0.05) { false }
            // A nudge waiting for its pause, then ⌘Z: it is the nudge that goes, and Redo brings it back.
            studio.geometry.nudge(dx: 1, dy: 0)
            t.check(studio.hasPendingEdits, "the nudge waits")
            t.check(session.undoStack.canUndo)
            session.undoStack.undo()
            t.equal(x(), "20", "the undo took the nudge back, not the move before it")
            t.check(session.undoStack.canRedo, "and it can be redone")
            session.undoStack.redo()
            t.equal(x(), "21")
            AppSelfTest.spin(timeout: 0.05) { false }

            // Typed code whose commit is refused (a conversion declined, a conflict put off): closing asks.
            t.check(type(studio, replacing: "Text=Hello", with: "Text=Hola"))
            let commit = studio.codeView.onCommit
            studio.codeView.onCommit = { _, _ in false }
            var asked = 0
            studio.closeChoice = {
                asked += 1
                return .cancel
            }
            guard let window = studio.window else { return t.check(false, "the window") }
            t.equal(studio.windowShouldClose(window), false, "Cancel: the window stays")
            t.equal(asked, 1, "asked once")
            t.equal(studio.canTerminate(), false, "quitting asks too")
            studio.doneAction(nil)
            t.check(StudioWindowController.window(for: studio.app) === studio, "Done asks as well: still open")
            studio.closeChoice = { .discard }
            t.equal(studio.windowShouldClose(window), true, "Discard Changes: it may close")
            t.check(!studio.codeView.hasUncommittedChanges, "the typing is gone")
            t.check(!((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("Hola"), "never written")
            studio.codeView.onCommit = commit
            studio.closeChoice = nil

            // Done with a color being picked: the pick is written before the window lets go of the widget.
            studio.select(part: "MeterTitle")
            studio.partPage.handle(.swatch(item: "text.color", swatch: ""))
            guard let popover = studio.partPage.colorPopover else { return t.check(false, "the color popover") }
            popover.takeFieldText("#FF0000")
            studio.doneAction(nil)
            t.check(((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("FontColor=255,0,0"),
                    "the pick is written")
            t.check(StudioWindowController.window(for: studio.app) == nil, "closed")
        }
    }

    /// ⌘D as the old Studio makes it (10 points right and down, at the end of the file, one step); Delete of several
    /// parts as one step.
    static func duplicateDeleteTests(_ t: AppTestRunner) {
        t.suite("Studio2: menus: Duplicate and Delete as one step each") {
            guard let (_, studio, url, _) = open(t, "CodeDuplicate", code: false),
                  let session = studio.session else { return }
            let original = (try? Data(contentsOf: url)) ?? Data()
            studio.select(part: "MeterTitle")
            studio.studioDuplicate(nil)
            guard let copy = studio.skin?.meter(named: "MeterTitle2"), let first = studio.skin?.meter(named: "MeterTitle")
            else { return t.check(false, "the copy") }
            t.equal(copy.frame.x, first.frame.x + 10, "10 points to the right")
            t.equal(copy.frame.y, first.frame.y + 10, "and down: not on top of it")
            t.equal(studio.skin?.meters.last?.name, "MeterTitle2", "at the end of the file")
            t.equal(session.undoStack.undoActionName, StudioText[.stepDuplicate])
            t.equal(studio.canvasController.canvas.selectedNames, ["MeterTitle2"], "the copy is selected")
            session.undoStack.undo()
            t.equal((try? Data(contentsOf: url)) ?? Data(), original, "undone byte for byte")
            // Three parts deleted: one step, undone at once.
            studio.canvasController.canvas.setSelection(names: ["MeterTitle", "MeterValue", "MeterBar"])
            studio.selectionChanged(["MeterTitle", "MeterValue", "MeterBar"])
            studio.delete(nil)
            t.check(studio.skin?.meter(named: "MeterTitle") == nil && studio.skin?.meter(named: "MeterBar") == nil,
                    "all three went")
            t.equal(session.undoStack.undoActionName, StudioText[.stepDelete])
            session.undoStack.undo()
            t.equal((try? Data(contentsOf: url)) ?? Data(), original, "one undo brings all three back")
        }
    }

    /// A widget with a shared style in an included file and CRLF line endings (so byte-exactness shows).
    static let ini = [
        "[Rainmeter]", "Update=1000", "", "[Variables]", "BarWidth=100", "@Include=#@#Styles.inc", "",
        "[MeasureCPU]", "Measure=CPU", "", "[MeterTitle]", "Meter=String", "Text=Hello", "FontColor=255,255,255",
        "X=10", "Y=10", "", "[MeterValue]", "Meter=String", "MeterStyle=StyleValue", "MeasureName=MeasureCPU",
        "Text=%1%", "X=10", "Y=30", "", "[MeterBar]", "Meter=Bar", "MeterStyle=StyleBar", "MeasureName=MeasureCPU",
        "X=10", "Y=60", "",
    ].joined(separator: "\r\n")
    static let styles = [
        "[StyleValue]", "FontSize=14", "FontColor=0,200,255", "", "[StyleBar]", "W=(#BarWidth#)", "H=6",
        "BarColor=0,200,255", "",
    ].joined(separator: "\r\n")

    /// The widget `Studio2\<name>` with its styles, and the new Studio open on it, the code beside the canvas.
    static func open(_ t: AppTestRunner, _ name: String, code: Bool = true)
        -> (app: AppController, studio: StudioWindowController, url: URL, styles: URL)? {
        Studio2SelfTests.prepare(t)
        guard let app = try? AppSelfTest.makeApp(t) else { return nil }
        let root = app.skinsDirectory.appendingPathComponent("Studio2")
        let folder = root.appendingPathComponent(name)
        let styles = root.appendingPathComponent("@Resources/Styles.inc")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: styles.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ini.utf8).write(to: folder.appendingPathComponent("\(name).ini"))
            try Data(Self.styles.utf8).write(to: styles)
        } catch {
            t.check(false, "\(error)")
            return nil
        }
        guard let c = app.activate(config: "Studio2\\\(name)", file: "\(name).ini"),
              let studio = Studio2SelfTests.openNew(app, c) else {
            t.check(false, "Studio2\\\(name) opens")
            return nil
        }
        t.atSuiteEnd { studio.window?.close() }
        studio.codeView.idleCommitDelay = 60
        studio.codeView.caretRestDelay = 60
        if code { studio.setCodeMode(.alongside) }
        return (app, studio, folder.appendingPathComponent("\(name).ini"), styles)
    }

    static func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    /// Types `text` in place of the first `find` in the code shown, as the keyboard does.
    @discardableResult
    static func type(_ studio: StudioWindowController, replacing find: String, with text: String) -> Bool {
        let tv = studio.codeView.textView
        let range = (tv.string as NSString).range(of: find)
        guard range.location != NSNotFound else { return false }
        tv.setSelectedRange(range)
        tv.insertText(text, replacementRange: range)
        return true
    }

    // MARK: Panes

    static func paneTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: beside the canvas or in the inspector's place") {
            guard let (_, studio, _, _) = open(t, "CodePanes", code: false) else { return }
            t.check(!studio.isCodeShown && studio.codeItem.isCollapsed, "closed at first")
            studio.setSidebarOpen(true)
            studio.codeAction(nil)
            t.check(studio.isCodeShown && !studio.codeItem.isCollapsed, "Code opens it")
            t.check(studio.sidebarItem.isCollapsed, "and closes the sidebar: three columns at most")
            t.check(studio.inspectorItem.isCollapsed, "1400 points: in the inspector's place")
            t.check(studio.codeState.replacedInspector)
            t.check(!studio.codeController.header.inspectorButton.isHidden, "a labelled way back")
            t.equal(studio.codeController.header.inspectorButton.title, "Inspector")
            t.check(studio.toolbar.state.codeOn, "the toolbar's Code is on")
            t.equal(studio.toolbar.state.undoTitle, nil, "Undo is an icon while the code is open")
            t.check(studio.canvasController.besideCode && studio.canvasController.previewBar.iconsOnly,
                    "the preview bar keeps its icons")
            t.check(studio.canvasController.zoomCapsule.actualSizeItem.isHidden, "no Actual Size in the zoom capsule")
            t.check(abs(studio.codeController.view.frame.width - StudioCodeState.narrowCodeWidth) < 2,
                    "590 points wide (\(studio.codeController.view.frame.width))")
            t.equal(studio.focusAreas, [.canvas, .code], "the keyboard's route passes the code")
            studio.codeController.header.inspectorButton.action?()
            t.check(!studio.isCodeShown && !studio.inspectorItem.isCollapsed, "Inspector: the code goes, it comes back")
            t.check(!studio.canvasController.besideCode)

            studio.window?.setContentSize(NSSize(width: 1600, height: 900))
            studio.window?.contentView?.layoutSubtreeIfNeeded()
            studio.setCodeMode(.alongside)
            t.check(!studio.inspectorItem.isCollapsed && !studio.codeItem.isCollapsed, "1600 points: a column of its own")
            t.check(studio.codeController.header.inspectorButton.isHidden)
            t.check(abs(studio.codeController.view.frame.width - StudioCodeState.wideCodeWidth) < 2,
                    "480 points (\(studio.codeController.view.frame.width))")
            studio.window?.setContentSize(NSSize(width: 1400, height: 860))
            studio.codeWindowResized()
            t.check(studio.inspectorItem.isCollapsed && studio.codeState.replacedInspector,
                    "narrower again: the inspector gives its place")
            studio.showCodeOnly(nil)
            t.check(studio.canvasItem.isCollapsed && studio.inspectorItem.isCollapsed, "Code Only: the code alone")
            studio.showDesignOnly(nil)
            t.check(!studio.canvasItem.isCollapsed && studio.codeItem.isCollapsed && !studio.inspectorItem.isCollapsed,
                    "Design Only: the canvas and the inspector")
        }
    }

    // MARK: Typing

    static func typingTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: typing is one step, byte for byte") {
            guard let (_, studio, url, _) = open(t, "CodeTyping"), let session = studio.session else { return }
            let before = bytes(url)
            t.equal(studio.codeView.currentFile.map { SourceFileID($0) }, SourceFileID(url), "the main file shows")
            t.check(type(studio, replacing: "Text=Hello", with: "Text=Hello there"))
            t.equal(studio.codeController.statusLine.state, .editing, "the status says it is not saved yet")
            t.check(studio.codeView.fireIdleCommit(), "the pause commits")
            let expected = String(decoding: before, as: UTF8.self).replacingOccurrences(of: "Text=Hello",
                                                                                      with: "Text=Hello there")
            t.equal(bytes(url), Data(expected.utf8), "written with its CRLF line endings")
            t.equal(session.undoStack.undoActionName, "Typing")
            t.equal(studio.toolbar.state.undoName, "Typing")
            t.equal(studio.codeController.statusLine.state, .saved, "Saved · your desktop is updated")
            t.equal(studio.codeController.statusLine.text, "Saved · your desktop is updated")
            t.equal((studio.skin?.meter(named: "MeterTitle") as? StringMeter)?.text, "Hello there", "the canvas shows it")
            session.undoStack.undo()
            t.equal(bytes(url), before, "one undo: the file exactly as it was")
            t.check(!session.undoStack.canUndo, "one step, not several")
            t.check(studio.codeView.text.contains("Text=Hello\r\n"), "the code follows the undo")
            session.undoStack.redo()
            t.equal(bytes(url), Data(expected.utf8), "redo")

            // A visual step commits typed code first, so nothing is lost and it starts from what the user sees.
            t.check(type(studio, replacing: "Y=10", with: "Y=12"))
            _ = try? session.apply("Change Color", [.setValue(file: url, section: "MeterTitle", key: "FontColor",
                                                              value: "1,2,3", afterIncludes: false)])
            let text = String(decoding: bytes(url), as: UTF8.self)
            t.check(text.contains("Y=12\r\n") && text.contains("FontColor=1,2,3"), "both are written")
            t.check(!studio.codeView.hasUncommittedChanges)
        }
    }

    // MARK: The desktop keeps the last working version

    static func holdTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: the desktop keeps the last working version") {
            guard let (app, studio, _, styles) = open(t, "CodeHold"), let session = studio.session,
                  let link = studio.link else { return }
            // The desktop copy follows a step as a patch (else it loads again): both count as the desktop taking it.
            var reloads = 0
            let previous = link.onChange
            link.onChange = { change in
                if case .reloaded = change { reloads += 1 }
                previous?(change)
            }
            let patchesBefore = session.desktopPatchCounts.applied
            func updates() -> Int { reloads + session.desktopPatchCounts.applied - patchesBefore }
            func settled() -> Bool { !session.hasPendingDesktopPatch && !session.isDesktopPatchInFlight }
            let desktop = app.controller(for: "Studio2\\CodeHold")
            func desktopBar() -> String? {
                app.controller(for: "Studio2\\CodeHold")?.skin.meter(named: "MeterBar")?.rawOption("W")
            }
            let working = desktopBar()
            t.equal(working, "(#BarWidth#)", "the desktop copy's bar as it works")
            studio.codeView.show(file: styles)
            t.check(type(studio, replacing: "W=(#BarWidth#)", with: "W=(#BarWidth# *)"))
            studio.codeView.commitNow()
            t.check(session.isHoldingDesktop, "a red problem: the desktop is held")
            AppSelfTest.spin(timeout: 0.3) { false }
            t.equal(updates(), 0, "no desktop refresh while red")
            t.check(app.controller(for: "Studio2\\CodeHold") === desktop, "the desktop copy is the one it was")
            t.equal(desktopBar(), working, "and it runs the last working version")
            t.equal(studio.codeController.statusLine.state, .held)
            t.equal(studio.codeController.statusLine.text,
                    "Saved · your desktop keeps the last working version until the red problem is fixed")
            t.check(!studio.canvasController.problemCapsule.isHidden, "the capsule over the canvas")
            t.equal(studio.canvasController.problemCapsule.messageItem.title,
                    "The CPU bar can’t draw · your desktop keeps the last working version")
            t.equal(studio.canvasController.problemMarks.ghosts.map(\.name), ["MeterBar"], "a ghost where the bar was")
            t.check((studio.canvasController.problemMarks.ghosts.first?.frame.width ?? 0) > 50,
                    "its last working size")
            // Each commit is a step of its own (the undo manager groups what happens in one turn of the run loop).
            AppSelfTest.spin(timeout: 0.05) { false }
            t.check(type(studio, replacing: "H=6", with: "H=7"))
            studio.codeView.commitNow()
            AppSelfTest.spin(timeout: 0.05) { false }
            t.equal(updates(), 0, "still red: still held")
            t.equal(desktopBar(), working)
            t.check(type(studio, replacing: "(#BarWidth# *)", with: "(#BarWidth# * 1)"))
            studio.codeView.commitNow()
            t.check(AppSelfTest.spin(timeout: 5) { updates() >= 1 && settled() }, "fixed: the desktop refreshes")
            t.check(!session.isHoldingDesktop)
            AppSelfTest.spin(timeout: 0.3) { false }
            t.equal(updates(), 1, "exactly once")
            t.equal(desktopBar(), "(#BarWidth# * 1)", "with the fixed bar")
            t.equal(app.controller(for: "Studio2\\CodeHold")?.skin.meter(named: "MeterBar")?.rawOption("H"), "7",
                    "and the step made while it was held")
            t.check(studio.canvasController.problemCapsule.isHidden, "the capsule goes")
            t.equal(studio.codeController.statusLine.state, .saved)
            session.undoStack.undo()
            t.check(session.isHoldingDesktop, "undoing the fix holds it again")
        }

        t.suite("Studio2: code: a step waiting for the desktop waits with the hold") {
            guard let (app, studio, _, styles) = open(t, "CodeHoldLater"), let session = studio.session else { return }
            // As in the app (headless, the desktop copy follows at once): the desktop copy follows on the next turn.
            app.defersDesktopUpdates = true
            defer { app.defersDesktopUpdates = false }
            func desktopBar(_ key: String) -> String? {
                app.controller(for: "Studio2\\CodeHoldLater")?.skin.meter(named: "MeterBar")?.rawOption(key)
            }
            func settled() -> Bool {
                !session.hasPendingDesktopPatch && !session.isDesktopPatchInFlight && !session.isAwaitingOwnReload
            }
            let patches = session.desktopPatchCounts.applied
            studio.codeView.show(file: styles)
            // A step that works, then — before the desktop copy took it — one that breaks the bar.
            t.check(type(studio, replacing: "H=6", with: "H=8"))
            studio.codeView.commitNow()
            t.check(session.hasPendingDesktopPatch, "the desktop copy takes it on the next turn")
            t.check(type(studio, replacing: "W=(#BarWidth#)", with: "W=(#BarWidth# *)"))
            studio.codeView.commitNow()
            t.check(session.isHoldingDesktop, "held")
            t.check(!session.hasPendingDesktopPatch, "the waiting step waits with it (it would read the broken file)")
            AppSelfTest.spin(timeout: 0.3) { false }
            t.equal(desktopBar("W"), "(#BarWidth#)", "the desktop runs the last working version")
            t.equal(desktopBar("H"), "6")
            t.equal(session.desktopPatchCounts.applied, patches, "nothing reached it")
            // Fixed: both steps reach the desktop, as one patch.
            t.check(type(studio, replacing: "(#BarWidth# *)", with: "(#BarWidth# * 2)"))
            studio.codeView.commitNow()
            t.check(!session.isHoldingDesktop)
            t.check(AppSelfTest.spin(timeout: 5) { settled() && desktopBar("W") == "(#BarWidth# * 2)" },
                    "fixed on the desktop")
            t.equal(desktopBar("H"), "8", "with the step that waited")
            t.equal(session.desktopPatchCounts.applied - patches, 1, "one patch")
            t.equal(studio.codeController.statusLine.state, .saved)
        }
    }

    // MARK: Diagnostics

    static func diagnosticsTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: the diagnostics of 12b") {
            Studio2SelfTests.prepare(t)
            let editorName = StudioCodeState.editorName
            t.atSuiteEnd { StudioCodeState.editorName = editorName }
            guard let opened = Studio2PageSelfTests.open(t, "12b-code-ini") else { return }
            defer { opened.close() }
            let studio = opened.controller
            let header = studio.codeController.header
            t.equal(header.problemsChip.title, "1", "one red")
            t.equal(header.warningsChip.title, "1", "one amber")
            t.equal(header.fileButton.title, "Styles.inc")
            t.equal(header.crumb.stringValue, "[StyleValue]")
            t.equal(studio.codeController.statusLine.line, 13, "the caret's line")
            let items = studio.codeController.decorations.items
            t.equal(items.map(\.diagnostic.line), [13, 18])
            t.equal(items.first?.message, "FontColr isn’t an option of a String meter. Did you mean FontColor? "
                + "The numbers draw in the default black until then.")
            t.equal(items.last?.message, "W=(#BarWidth# *) can’t be worked out: a number is missing after “*”. "
                + "The 3 bars don’t draw.")
            let cards = studio.codeController.decorations.cards
            t.check(cards[13]?.fixButton != nil, "Fix on the amber one")
            t.check(cards[18]?.fixButton == nil, "none where the change is not certain")
            t.check((cards[13]?.frame.height ?? 0) > 20, "the text made room for it")
            t.equal(studio.canvasController.problemMarks.ghosts.map(\.name), ["MeterCPUBar", "MeterGPUBar", "MeterRAMBar"])
            t.check(studio.canvasController.problemMarks.framed.contains("MeterCPU"), "an amber frame on the numbers")
            t.equal(studio.canvasController.problemCapsule.messageItem.title,
                    "The bars can’t draw · your desktop keeps the last working version")
            let files = studio.codeFiles()
            t.equal(files.map(\.title), ["Nocturne.ini", "@Resources/Styles.inc", "@Resources/Variables.inc"])
            t.equal(files.map(\.problems), [0, 1, 0])
            t.equal(files.map(\.warnings), [0, 1, 0])
            t.equal(files.map(\.current), [false, true, false])
            let menu = studio.fileMenu()
            t.equal(menu.items.map(\.title).suffix(2), ["Show in Finder", "Open in Visual Studio Code"])
            t.check(studio.isShowingFileMenu, "the screen has it open")

            // Fix: the line changes, one step named after it, and the amber goes.
            let styles = Studio2PageSelfTests.file(opened, "Nocturne/@Resources/Styles.inc")
            if let d = items.first?.diagnostic { studio.fix(d) }
            t.check(Studio2PageSelfTests.text(styles).contains("\nFontColor=#TextColor#"), "FontColor again")
            t.equal(studio.session?.undoStack.undoActionName, "Fix FontColr")
            t.equal(studio.codeState.diagnostics.filter { $0.severity == .warning }.count, 0)
            t.check(studio.canvasController.problemMarks.framed.isEmpty)

            // Typing is checked 0.3 s after it pauses, before it is committed.
            t.check(type(studio, replacing: "StringStyle=Bold\r\nAntiAlias=1\r\n\r\n[StyleBar]",
                         with: "StringStyle=Bold\r\nAntiAlis=1\r\n\r\n[StyleBar]")
                    || type(studio, replacing: "StringStyle=Bold\nAntiAlias=1\n\n[StyleBar]",
                            with: "StringStyle=Bold\nAntiAlis=1\n\n[StyleBar]"))
            t.check(studio.fireCodeCheck(), "a check waits for the pause")
            t.check(studio.codeView.hasUncommittedChanges, "not committed")
            t.check(studio.codeState.diagnostics.contains {
                $0.kind == .unknownKey(key: "AntiAlis", sectionType: "String", suggestion: "AntiAlias")
            }, "the typo is found in the typed text")
            t.equal(IniDiagnostics.checkDelay, 0.3)
        }

        t.suite("Studio2: code: the 12b screen renders") {
            Studio2SelfTests.prepare(t)
            let editorName = StudioCodeState.editorName
            t.atSuiteEnd { StudioCodeState.editorName = editorName }
            for dark in [false, true] {
                guard let screen = StudioScreen.named("12b-code-ini"), let opened = StudioSnapshot.open(screen) else {
                    t.check(false, "12b opens")
                    continue
                }
                defer { opened.close() }
                opened.controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let rep = StudioSnapshot.render(opened.controller)
                t.equal(rep?.pixelsWide, 2800, dark ? "dark" : "light")
                t.equal(rep?.pixelsHigh, 1720)
            }
        }
    }

    // MARK: Selection

    static func selectionTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: the selection both ways") {
            guard let (_, studio, url, _) = open(t, "CodeSelect") else { return }
            studio.select(part: "MeterBar")
            let lines = studio.codeView.lineRange(ofSection: "MeterBar")
            t.check(lines != nil, "its block")
            if let lines {
                t.equal(studio.codeView.textView.tintRange,
                        CodeDocument(text: studio.codeView.text).range(ofLines: lines), "tinted")
            }
            // The caret in another part's block selects it on the canvas.
            let offset = (studio.codeView.text as NSString).range(of: "Text=Hello").location
            studio.codeView.textView.setSelectedRange(NSRange(location: offset, length: 0))
            t.check(studio.codeView.fireCaretRest(), "the caret rests")
            t.equal(studio.canvasController.canvas.selectedNames, ["MeterTitle"], "the canvas follows")
            t.equal(studio.codeController.header.crumb.stringValue, "[MeterTitle]")
            t.equal(SourceFileID(studio.codeView.currentFile ?? url), SourceFileID(url))
            // ⌥⌘↩ Show in Code: the code at what is selected.
            studio.setCodeMode(.hidden)
            studio.select(part: "MeterValue")
            studio.showInCode(nil)
            t.check(studio.isCodeShown, "it opens")
            t.equal(studio.codeView.caretSection, "MeterValue")
        }
    }

    // MARK: Log

    static func logTests(_ t: AppTestRunner) {
        t.suite("Studio2: log: this widget, all widgets, and the line") {
            guard let (_, studio, _, _) = open(t, "CodeLog") else { return }
            Log.write("Formula error in [MeterBar]", level: .error, source: "Studio2\\CodeLog")
            Log.write("Something else", level: .warning, source: "Studio2\\Elsewhere")
            Log.write("Hello from the Studio", level: .notice, source: "Studio2\\CodeLog")
            let mine = studio.logEntries(allWidgets: false)
            t.check(mine.contains { $0.message == "Formula error in [MeterBar]" && $0.origin == .desktop })
            t.check(!mine.contains { $0.message == "Something else" }, "not another widget's")
            t.check(studio.logEntries(allWidgets: true).contains { $0.message == "Something else" }, "all widgets")
            t.check(studio.logCount >= 1, "the header counts warnings and errors")
            studio.showLog(allWidgets: false)
            guard let window = studio.codeState.logWindow else { return t.check(false, "the log window") }
            window.filter = .errors
            window.reload()
            t.check(window.entries.allSatisfy { $0.level == .error } && !window.entries.isEmpty, "errors only")
            t.equal(window.window?.title, "Log · \(studio.widgetName)")
            guard let entry = window.entries.first(where: { $0.message.contains("[MeterBar]") }) else { return }
            t.equal(studio.logTarget(entry)?.line, studio.skin?.sources.location(section: "MeterBar")?.line,
                    "it points at the part")
            studio.setCodeMode(.hidden)
            studio.showLogLine(entry)
            t.check(studio.isCodeShown, "Show the Line opens the code")
            t.equal(studio.codeView.caretSection, "MeterBar")
            window.close()
        }
    }

    // MARK: Menus

    static func menuTests(_ t: AppTestRunner) {
        t.suite("Studio2: menus: every toolbar item has a menu item, no key twice") {
            guard let (app, studio, _, _) = open(t, "CodeMenus") else { return }
            let menu = StudioMenus.make(app: app)
            let items = StudioMenus.allItems(menu)
            t.equal(menu.items.compactMap { $0.submenu?.title },
                    ["Deskset", "File", "Edit", "Insert", "Arrange", "View", "Widget", "Window", "Help"])
            let skip: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator]
            for id in StudioToolbarState.itemIdentifiers where !skip.contains(id) {
                let ids: [NSToolbarItem.Identifier] = id == .studioUndoRedo ? [.studioUndo, .studioRedo]
                    : id == .studioAddCode ? [.studioAdd, .studioCode] : [id]
                for sub in ids {
                    if id.rawValue.contains("Tracking") || id.rawValue.hasSuffix("SeparatorItem") { continue }
                    guard let command = StudioMenus.toolbarCommands.first(where: { $0.item == sub }) else {
                        t.check(false, "\(sub.rawValue) has a command")
                        continue
                    }
                    t.check(items.contains { $0.action == command.action }, "\(sub.rawValue) is in the menus")
                }
            }
            var keys: [String: String] = [:]
            for item in items where !item.keyEquivalent.isEmpty {
                let flags = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                let key = "\(flags.rawValue)-\(item.keyEquivalent.lowercased())"
                if let other = keys[key] { t.check(false, "\(item.title) and \(other) share a key") }
                keys[key] = item.title
            }
            t.check(keys.count >= 30, "\(keys.count) keys")
            func find(_ action: Selector) -> NSMenuItem? { items.first { $0.action == action } }
            let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
                                         (#selector(StudioWindowController.showLibrary(_:)), "l", [.command, .shift]),
                                         (#selector(StudioWindowController.showLayers(_:)), "l", [.command, .option]),
                                         (#selector(StudioWindowController.toggleInspectorPane(_:)), "i", [.command, .option]),
                                         (#selector(StudioWindowController.showDesignOnly(_:)), "1", [.command, .control]),
                                         (#selector(StudioWindowController.showCodeAlongside(_:)), "2", [.command, .control]),
                                         (#selector(StudioWindowController.showCodeOnly(_:)), "3", [.command, .control]),
                                         (#selector(StudioWindowController.studioEverySetting(_:)), "e", [.command, .option]),
                                         (#selector(StudioWindowController.actualSizeClicked), "0", [.command]),
                                         (#selector(StudioWindowController.fitClicked), "9", [.command]),
                                         (#selector(StudioWindowController.showOnDesktop(_:)), "d", [.command, .shift]),
                                         (#selector(StudioWindowController.toggleRainmeterDetails(_:)), "r", [.command, .option]),
                                         (#selector(StudioWindowController.studioRefresh(_:)), "r", [.command]),
                                         (#selector(StudioWindowController.toggleInteract(_:)), "p", [.command, .option]),
                                         (#selector(StudioWindowController.studioTextBigger(_:)), "=", [.command, .option]),
                                         (#selector(StudioWindowController.studioTextSmaller(_:)), "-", [.command, .option]),
                                         (#selector(StudioWindowController.studioZoomToSelection(_:)), "9",
                                          [.command, .shift])]
            for (action, key, flags) in expected {
                let item = find(action)
                t.equal(item?.keyEquivalent, key, "\(item?.title ?? NSStringFromSelector(action))")
                t.equal(item?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]).rawValue,
                        flags.rawValue)
            }
            // What the window answers.
            for item in items where item.action != nil && item.target == nil && item.submenu == nil {
                guard let action = item.action else { continue }
                let answered = studio.responds(to: action) || NSWindow.instancesRespond(to: action)
                    || NSTextView.instancesRespond(to: action) || NSApplication.shared.responds(to: action)
                t.check(answered, "\(item.title) is answered")
            }
            // Align with nothing selected points to Arrange Widgets instead.
            studio.select(part: nil)
            guard let hint = items.first(where: { $0.action == #selector(StudioWindowController.studioArrangeWidgetsHint(_:)) }),
                  let left = items.first(where: { ($0.representedObject as? String) == EditorAlign.Mode.left.rawValue }) else {
                return t.check(false, "Align's items")
            }
            t.equal(studio.validateMenuItem(hint), true, "said, not greyed out")
            t.check(!hint.isHidden, "the hint shows")
            t.equal(hint.title, "To line up widgets on your desktop, use Arrange Widgets")
            studio.studioArrangeWidgetsHint(hint)
            t.equal(studio.widgetPage.page?.topConfirmation?.text, StudioText[.arrangeWidgetsLater],
                    "until Arrange Widgets is there, the page says so")
            // File ▸ Revert to Original: only while there is something to put back (not a built-in widget here).
            if let revert = find(#selector(StudioWindowController.studioRevertToOriginal(_:))) {
                t.equal(studio.validateMenuItem(revert), false, "nothing to revert")
            } else {
                t.check(false, "File ▸ Revert to Original")
            }
            if let zoom = find(#selector(StudioWindowController.studioZoomToSelection(_:))) {
                t.equal(studio.validateMenuItem(zoom), false, "nothing selected: nothing to zoom to")
            }
            t.equal(studio.validateMenuItem(left), false, "nothing to align")
            studio.select(part: "MeterTitle")
            _ = studio.validateMenuItem(hint)
            t.check(hint.isHidden, "a part selected: no hint")
            t.equal(studio.validateMenuItem(left), true)
            if let zoom = find(#selector(StudioWindowController.studioZoomToSelection(_:))) {
                t.equal(studio.validateMenuItem(zoom), true)
                let before = studio.canvasController.canvas.zoom
                studio.studioZoomToSelection(zoom)
                t.check(studio.canvasController.canvas.zoom > before, "the selection fills the canvas")
                studio.fitClicked()
            }
            // Undo is named after the step.
            t.check(type(studio, replacing: "Text=Hello", with: "Text=Hi"))
            studio.codeView.commitNow()
            studio.window?.makeFirstResponder(studio.canvasController.canvas)
            if let undo = find(#selector(StudioWindowController.undoAction(_:))) {
                t.equal(studio.validateMenuItem(undo), true)
                t.equal(undo.title, "Undo Typing")
            }
            // Align writes one step.
            let before = studio.session?.undoStack.undoActionName
            let alignLeft = NSMenuItem()
            alignLeft.representedObject = EditorAlign.Mode.left.rawValue
            studio.select(part: "MeterValue")
            studio.studioAlign(alignLeft)
            t.check(studio.session?.undoStack.undoActionName != before || before == nil, "a step")
        }
    }
}
