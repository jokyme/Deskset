import AppKit
import DesksetCore

/// The Studio's code pane (beside the canvas; typing as one step, byte for byte), its INI diagnostics (under their
/// lines, on the canvas, with Fix), the desktop keeping the last working version while a part can't draw, the log,
/// and the menus.
enum Studio2CodeSelfTests {
    static func run(_ t: AppTestRunner) {
        paneTests(t)
        typingTests(t)
        holdTests(t)
        diagnosticsTests(t)
        selectionTests(t)
        logTests(t)
        menuTests(t)
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

    /// Typed code that can't be saved is asked about when closing or quitting.
    static func closingTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: closing with code that can't be saved") {
            guard let (_, studio, url, _) = open(t, "CodeClosing") else { return }
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

    /// The widget `Studio2\<name>` with its styles, and the Studio open on it, the code beside the canvas.
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
        if code { studio.setCodeMode(.alongside) } else { studio.setCodeMode(.only) }
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
        t.suite("Studio2: code: beside the canvas or alone") {
            guard let (_, studio, _, _) = open(t, "CodePanes", code: true) else { return }
            t.check(studio.isCodeShown && !studio.codeItem.isCollapsed, "Code is open alongside")
            t.check(studio.canvasController.besideCode && studio.canvasController.previewBar.iconsOnly,
                    "the preview bar keeps its icons")
            t.check(studio.canvasController.zoomCapsule.actualSizeItem.isHidden, "no Actual Size in the zoom capsule")
            studio.showCodeOnly(nil)
            t.check(studio.canvasItem.isCollapsed && !studio.codeItem.isCollapsed, "Code Only: the code alone")
            studio.showCodeAlongside(nil)
            t.check(!studio.canvasItem.isCollapsed && !studio.codeItem.isCollapsed, "Code Alongside: both panes")
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
            t.equal(studio.codeController.statusLine.state, .saved, "Saved · your desktop is updated")
            t.equal(studio.codeController.statusLine.text, "Saved · your desktop is updated")
            t.equal((studio.skin?.meter(named: "MeterTitle") as? StringMeter)?.text, "Hello there", "the canvas shows it")
            session.undoStack.undo()
            t.equal(bytes(url), before, "one undo: the file exactly as it was")
            t.check(!session.undoStack.canUndo, "one step, not several")
            t.check(studio.codeView.text.contains("Text=Hello\r\n"), "the code follows the undo")
            session.undoStack.redo()
            t.equal(bytes(url), Data(expected.utf8), "redo")

            // A step commits typed code first, so nothing is lost and it starts from what the user sees.
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
                    "The MeterBar can’t draw · your desktop keeps the last working version")
            t.equal(studio.canvasController.problemMarks.ghosts.map(\.name), ["MeterBar"], "a ghost where the bar was")
            t.check((studio.canvasController.problemMarks.ghosts.first?.frame.width ?? 0) > 50,
                    "its last working size")
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
        t.suite("Studio2: code: INI diagnostics and Fix") {
            guard let (_, studio, _, styles) = open(t, "CodeDiag") else { return }
            studio.codeView.show(file: styles)
            t.check(type(studio, replacing: "FontColor=0,200,255", with: "FontColr=0,200,255"))
            studio.codeView.commitNow()
            let warnings = studio.codeState.diagnostics.filter { $0.severity == .warning }
            t.equal(warnings.count, 1, "one amber warning")
            if let d = warnings.first {
                studio.fix(d)
                t.equal(studio.session?.undoStack.undoActionName, "Fix FontColr")
                t.equal(studio.codeState.diagnostics.filter { $0.severity == .warning }.count, 0)
            }
            // Typing is checked 0.3 s after it pauses, before it is committed.
            t.check(type(studio, replacing: "FontSize=14", with: "FontSiz=14"))
            t.check(studio.fireCodeCheck(), "a check waits for the pause")
            t.check(studio.codeView.hasUncommittedChanges, "not committed")
            t.check(studio.codeState.diagnostics.contains {
                $0.kind == .unknownKey(key: "FontSiz", sectionType: "String", suggestion: "FontSize")
            }, "the typo is found in the typed text")
            t.equal(IniDiagnostics.checkDelay, 0.3)
        }
    }

    // MARK: Selection

    static func selectionTests(_ t: AppTestRunner) {
        t.suite("Studio2: code: section crumb") {
            guard let (_, studio, url, _) = open(t, "CodeSelect") else { return }
            let offset = (studio.codeView.text as NSString).range(of: "Text=Hello").location
            studio.codeView.textView.setSelectedRange(NSRange(location: offset, length: 0))
            t.check(studio.codeView.fireCaretRest(), "the caret rests")
            t.equal(studio.codeController.header.crumb.stringValue, "[MeterTitle]")
            t.equal(SourceFileID(studio.codeView.currentFile ?? url), SourceFileID(url))
            t.check(studio.isCodeShown, "it opens")
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
                    ["Deskset", "File", "Edit", "View", "Widget", "Window", "Help"])
            let skip: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .studioTitle]
            for id in StudioToolbarState.itemIdentifiers where !skip.contains(id) {
                guard let command = StudioMenus.toolbarCommands.first(where: { $0.item == id }) else {
                    t.check(false, "\(id.rawValue) has a command")
                    continue
                }
                t.check(items.contains { $0.action == command.action }, "\(id.rawValue) is in the menus")
            }
            var keys: [String: String] = [:]
            for item in items where !item.keyEquivalent.isEmpty {
                let flags = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                let key = "\(flags.rawValue)-\(item.keyEquivalent.lowercased())"
                if let other = keys[key] { t.check(false, "\(item.title) and \(other) share a key") }
                keys[key] = item.title
            }
            func find(_ action: Selector) -> NSMenuItem? { items.first { $0.action == action } }
            let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
                (#selector(StudioWindowController.showCodeAlongside(_:)), "2", [.command, .control]),
                (#selector(StudioWindowController.showCodeOnly(_:)), "3", [.command, .control]),
                (#selector(StudioWindowController.actualSizeClicked), "0", [.command]),
                (#selector(StudioWindowController.fitClicked), "9", [.command]),
                (#selector(StudioWindowController.studioRefresh(_:)), "r", [.command]),
            ]
            for (action, key, flags) in expected {
                let item = find(action)
                t.equal(item?.keyEquivalent, key, "\(item?.title ?? NSStringFromSelector(action))")
                t.equal(item?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]).rawValue,
                        flags.rawValue)
            }
            for item in items where item.action != nil && item.target == nil && item.submenu == nil {
                guard let action = item.action else { continue }
                let answered = studio.responds(to: action) || NSWindow.instancesRespond(to: action)
                    || NSTextView.instancesRespond(to: action) || NSApplication.shared.responds(to: action)
                t.check(answered, "\(item.title) is answered")
            }
        }
    }
}
