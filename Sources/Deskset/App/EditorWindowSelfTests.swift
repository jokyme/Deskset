import AppKit
import DesksetCore

/// `Deskset --self-test "skin editor window"`: the skin studio window (docs/editor-design.md §1, §2, §5, §6) — modes and
/// panes, the code pane's commit model, selection sync, inserting from the library, the external-editor toolbar,
/// closing with unsaved code and the menus. Headless like the other editor suites: the window is never shown, text is
/// typed through the code view's text view as keyboard input arrives, files live in temporary folders.
enum EditorWindowSelfTests {
    static func run(_ t: AppTestRunner) {
        modeTests(t)
        codeCommitTests(t)
        focusTests(t)
        selectionSyncTests(t)
        insertTests(t)
        externalEditorTests(t)
        closeTests(t)
        menuTests(t)
    }

    typealias Editor = InspectorWindowController

    /// An app with Deskset\System loaded and its editor open.
    static func openEditor(_ t: AppTestRunner) throws -> (AppController, Editor)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        guard let c = app.activate(config: "Deskset\\System", file: nil) else {
            t.check(false, "Deskset\\System loads")
            return nil
        }
        app.showInspector(for: c)
        guard let editor = app.inspector else {
            t.check(false, "the editor opens")
            return nil
        }
        return (app, editor)
    }

    /// Ends the current event: the undo manager groups what one event registers (as in the app).
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Types `text` into the code pane at the start of the first occurrence of `anchor` plus `offset`.
    static func type(_ editor: Editor, _ text: String, after anchor: String, offset: Int = 0) -> Bool {
        let range = (editor.codeView.text as NSString).range(of: anchor)
        guard range.location != NSNotFound else { return false }
        editor.codeView.textView.setSelectedRange(NSRange(location: range.location + offset, length: 0))
        editor.codeView.textView.insertText(text, replacementRange: editor.codeView.textView.selectedRange())
        return true
    }

    static func validate(_ editor: Editor, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.isEnabled = editor.validateMenuItem(item)
        return item
    }

    // MARK: Modes and panes

    static func modeTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window modes and panes") {
            guard let (app, editor) = try openEditor(t) else { return }
            guard let window = editor.window else { return t.check(false, "window") }
            t.equal(editor.mode, .design, "opens as Settings ▸ Editor ▸ Open skins in says (Design)")
            let items = window.toolbar?.items ?? []
            t.equal(items.map(\.itemIdentifier), [Editor.toolbarSidebar, .sidebarTrackingSeparator, .flexibleSpace,
                                                   Editor.toolbarUndo, Editor.toolbarRedo, Editor.toolbarLibrary,
                                                   Editor.toolbarMode, .flexibleSpace,
                                                   Editor.toolbarBackdrop, Editor.toolbarLive, Editor.toolbarCode,
                                                   Editor.toolbarMore, Editor.toolbarInspector],
                    "sidebar toggle | undo, redo, + Add, mode | backdrop, live reload, code, more, inspector toggle")
            t.equal(window.toolbar?.centeredItemIdentifiers,
                    [Editor.toolbarUndo, Editor.toolbarRedo, Editor.toolbarLibrary, Editor.toolbarMode])
            let group = items.first { $0.itemIdentifier == Editor.toolbarMode } as? NSToolbarItemGroup
            t.equal(group?.subitems.map(\.label), ["Design", "Split", "Code"])
            t.equal(group?.selectedIndex, 0)
            t.equal(items.first { $0.itemIdentifier == Editor.toolbarCode }?.label, "Show in Code")
            t.equal((items.first { $0.itemIdentifier == Editor.toolbarMore } as? NSMenuToolbarItem)?.menu.items.first?.title,
                    "Reload Widget", "rarely used buttons fold into the … menu")
            t.equal(window.title, "System")
            t.equal(window.subtitle, "", "no engine path under the name (§4); with Rainmeter Details it shows")
            t.check(editor.isCanvasVisible && !editor.isCodeVisible, "Design: the canvas only")
            let designMinimum = window.contentMinSize.width

            editor.setMode(.split)
            t.check(editor.isCanvasVisible && editor.isCodeVisible, "Split: canvas and code")
            t.equal(editor.codeView.files.map(CodeEditorRouter.comparablePath),
                    (editor.skin?.sourceFiles ?? []).map(CodeEditorRouter.comparablePath), "the skin's files, main first")
            t.equal(editor.codeView.files.map(\.lastPathComponent).prefix(2), ["System.ini", "Variables.inc"])
            t.equal(editor.codeView.currentFile?.lastPathComponent, "System.ini")
            t.check(window.contentMinSize.width > designMinimum, "the window minimum grows in Split")
            t.check(window.contentRect(forFrameRect: window.frame).width >= window.contentMinSize.width - 0.5,
                    "and the window with it")
            t.check(editor.codePane.frame.width >= Editor.PaneSize.codeMin - 0.5
                    && editor.canvasPane.frame.width >= Editor.PaneSize.canvasMin - 0.5, "no pane below its minimum")
            t.close(editor.codePane.frame.width, editor.centreSplit.bounds.width * 0.5, accuracy: 2,
                    "the code takes half of the centre by default")
            t.check(editor.codeView.scrollView.contentView.bounds.minX < 0, "the text starts after the line numbers")

            // The mode is the window's: a refresh keeps it.
            let before = app.controller(for: "Deskset\\System")
            editor.refreshClicked()
            t.check(app.controller(for: "Deskset\\System") !== before, "refreshed")
            t.equal(editor.mode, .split, "the mode survives a refresh")
            t.check(editor.isCodeVisible)

            t.equal(group?.selectedIndex, 1, "the mode control follows")
            group?.selectedIndex = 2
            editor.modeGroupChanged(group)
            t.equal(editor.mode, .code, "choosing Code in the mode control")
            t.check(!editor.isCanvasVisible && editor.isCodeVisible, "Code: the code only")
            editor.toggleCodePane(nil)
            t.equal(editor.mode, .design, "⌥⌘↩ hides the code")
            editor.toggleCodePane(nil)
            t.equal(editor.mode, .code, "and brings back the last code mode")
            t.equal(validate(editor, #selector(Editor.showCodeMode(_:))).state, .on, "the View menu checks the mode")
            t.equal(validate(editor, #selector(Editor.showDesignMode(_:))).state, .off)
            t.equal(validate(editor, #selector(Editor.toggleCodePane(_:))).title, "Hide Code")
            t.check(!validate(editor, #selector(Editor.zoomInClicked)).isEnabled, "no canvas zoom without the canvas")
            editor.setMode(.split)

            // Code below the canvas.
            editor.setCodeBelow(true)
            t.check(!editor.centreSplit.isVertical, "View ▸ Code Below")
            t.check(editor.codePane.frame.minY >= editor.canvasPane.frame.maxY, "the code under the canvas")
            t.equal(validate(editor, #selector(Editor.showCodeBelow(_:))).state, .on)
            editor.setCodeBelow(false)
            t.check(editor.centreSplit.isVertical, "and back on the right")

            // Sidebar and inspector collapse and come back at their width.
            let sidebarWidth = editor.sidebarPane.frame.width
            t.equal(validate(editor, #selector(Editor.toggleSidebarPane(_:))).title, "Hide Sidebar")
            editor.toggleSidebarPane(nil)
            t.check(editor.isSidebarHidden, "sidebar hidden")
            t.check(editor.centreSplit.frame.minX <= 1.5, "the centre takes its room")
            t.equal(validate(editor, #selector(Editor.toggleSidebarPane(_:))).title, "Show Sidebar")
            editor.toggleSidebarPane(nil)
            t.check(!editor.isSidebarHidden)
            t.close(editor.sidebarPane.frame.width, sidebarWidth, accuracy: 0.5, "the sidebar keeps its width")
            let inspectorWidth = editor.inspectorPane.frame.width
            editor.toggleInspectorPane(nil)
            t.check(editor.isInspectorHidden, "inspector hidden")
            t.close(editor.centreSplit.frame.maxX, window.contentView?.bounds.width ?? 0, accuracy: 1.5,
                    "the centre reaches the right edge")
            t.equal(validate(editor, #selector(Editor.toggleInspectorPane(_:))).title, "Show Inspector")
            editor.toggleInspectorPane(nil)
            t.close(editor.inspectorPane.frame.width, inspectorWidth, accuracy: 0.5, "the inspector keeps its width")

            // The inspector's divider moves, within its minimum and maximum, and the width is remembered.
            editor.setMode(.design)
            let split = editor.mainSplit
            func dragInspector(to width: CGFloat) {
                split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 1)
                window.contentView?.layoutSubtreeIfNeeded()
            }
            t.close(editor.inspectorPane.frame.width, Editor.PaneSize.inspectorMin, accuracy: 0.5, "starts at its minimum")
            editor.select(section: "MeterSwapBar")
            window.contentView?.layoutSubtreeIfNeeded()
            t.close(editor.inspectorPane.frame.width, Editor.PaneSize.inspectorMin, accuracy: 0.5,
                    "a long formula does not widen it")
            dragInspector(to: 400)
            t.close(editor.inspectorPane.frame.width, 400, accuracy: 0.5, "the inspector's divider moves")
            t.close(editor.layoutMemory.inspectorWidth, 400, accuracy: 0.5, "and the width is remembered")
            t.close(editor.sidebarPane.frame.width, sidebarWidth, accuracy: 0.5, "the sidebar keeps its width")
            editor.select(section: "MeterCPULabel")
            window.contentView?.layoutSubtreeIfNeeded()
            t.close(editor.inspectorPane.frame.width, 400, accuracy: 0.5, "a new selection keeps it")
            dragInspector(to: 900)
            t.close(editor.inspectorPane.frame.width, Editor.PaneSize.inspectorMax, accuracy: 0.5, "at most its maximum")
            dragInspector(to: 100)
            t.close(editor.inspectorPane.frame.width, Editor.PaneSize.inspectorMin, accuracy: 0.5, "at least its minimum")
            dragInspector(to: 380)
            editor.toggleInspectorPane(nil)
            editor.toggleInspectorPane(nil)
            t.close(editor.inspectorPane.frame.width, 380, accuracy: 0.5, "hidden and shown, it comes back at that width")
            let windowSize = window.frame.size
            window.setContentSize(NSSize(width: 1000, height: window.contentRect(forFrameRect: window.frame).height))
            window.contentView?.layoutSubtreeIfNeeded()
            t.close(editor.inspectorPane.frame.width, 380, accuracy: 0.5, "a narrower window keeps it (the canvas gives way)")
            window.setFrame(NSRect(origin: window.frame.origin, size: windowSize), display: false)
            editor.layoutMemory.inspectorWidth = 350
            editor.applyPaneSizes()
            t.close(editor.inspectorPane.frame.width, 350, accuracy: 0.5, "a new window opens at the remembered width")
            editor.layoutMemory.inspectorWidth = Editor.PaneSize.inspectorMin
            editor.applyPaneSizes()
            editor.setMode(.split)

            // "+ Library" (⇧⌘L) opens a hidden sidebar on the Library tab.
            editor.setSidebarHidden(true)
            editor.showLibrary(nil)
            t.check(!editor.isSidebarHidden, "the sidebar comes back")
            t.equal(editor.sidebarTab, .library)
            t.check(!editor.libraryView.isHidden && editor.outline.enclosingScrollView?.isHiddenOrHasHiddenAncestor == true,
                    "the library replaces the list")
            t.check(editor.snapshot() != nil, "renders off-screen with the code and the library")

            // Pane sizes are remembered (only by the running app: self-tests pass no defaults).
            t.check(editor.layoutMemory.defaults == nil, "self-tests leave the user's defaults alone")
            do {
                // An in-memory store: a UserDefaults suite would leave a file in ~/Library/Preferences.
                let defaults = MemoryKeyValueStore()
                var memory = EditorLayoutMemory(defaults: defaults)
                memory.sidebarWidth = 280
                memory.inspectorWidth = 372
                memory.codeFraction = 0.6
                memory.inspectorHidden = true
                memory.codeBelow = true
                memory.save()
                let again = EditorLayoutMemory(defaults: defaults)
                t.equal(again.sidebarWidth, 280)
                t.equal(again.inspectorWidth, 372)
                t.close(again.codeFraction, 0.6, accuracy: 0.001)
                t.check(again.inspectorHidden && again.codeBelow && !again.sidebarHidden, "visibility and orientation too")
                t.check(defaults.values[EditorLayoutMemory.key] is [String: Any], "stored under one key")
            }

            // A new window starts from the preference.
            window.close()
            app.state.updateEditor { $0.openSkinsIn = .code }
            guard let c = app.controller(for: "Deskset\\System") else { return t.check(false, "still loaded") }
            app.showInspector(for: c)
            t.equal(app.inspector?.mode, .code, "Open skins in: Code")
            t.check(app.inspector?.isCodeVisible == true && app.inspector?.isCanvasVisible == false)
            app.inspector?.window?.close()
        }
    }

    // MARK: Commit model

    static func codeCommitTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window code commits") {
            guard let (app, editor) = try openEditor(t) else { return }
            editor.setMode(.split)
            guard let ini = app.controller(for: "Deskset\\System")?.skin.fileURL else { return t.check(false, "skin") }
            func bytes() -> Data { (try? Data(contentsOf: ini)) ?? Data() }
            func text() -> String { String(decoding: bytes(), as: UTF8.self) }
            func skin() -> Skin? { app.controller(for: "Deskset\\System")?.skin }
            let original = bytes()

            // Typing, then ⌘S: the bytes are written, the skin refreshes, one undo step restores them.
            t.check(type(editor, "!", after: "Text=CPU\n", offset: 8), "typed")
            t.check(editor.codeView.isDirty, "the buffer is dirty until it is committed")
            t.equal(text(), String(decoding: original, as: UTF8.self), "nothing written while typing")
            let before = app.controller(for: "Deskset\\System")
            editor.saveSkinCode(nil)
            t.check(!editor.codeView.hasUncommittedChanges, "committed")
            t.check(text().contains("Text=CPU!\n"), "written to System.ini")
            t.equal(bytes().count, original.count + 1, "only the typed byte changed (encoding and line endings kept)")
            t.check(app.controller(for: "Deskset\\System") !== before, "the skin refreshed")
            t.equal(skin()?.meter(named: "MeterCPULabel")?.rawOption("Text"), "CPU!")
            t.equal(editor.window?.undoManager?.undoActionName, "Edit Code")
            let edited = bytes()
            settle()
            editor.window?.undoManager?.undo()
            t.equal(bytes(), original, "undo restores the bytes")
            t.check(editor.window?.undoManager?.canUndo == false, "it was one undo step")
            t.check(!editor.codeView.text.contains("Text=CPU!"), "the code pane re-read the file")
            t.equal(skin()?.meter(named: "MeterCPULabel")?.rawOption("Text"), "CPU")
            settle()
            editor.window?.undoManager?.redo()
            t.equal(bytes(), edited, "redo")
            settle()

            // The idle commit (its timer is fired: the pause itself is the code editor's own suite's business).
            t.check(type(editor, "?", after: "Text=CPU!\n", offset: 9), "typed again")
            t.check(!text().contains("Text=CPU!?\n"), "not yet")
            t.check(editor.codeView.fireIdleCommit(), "an idle commit is pending")
            t.check(text().contains("Text=CPU!?\n"), "committed after a pause")
            settle()

            // A visual edit while the buffer is dirty commits the typing first: nothing is lost, and each is its own
            // undo step (the edit follows on the next turn of the run loop).
            t.check(type(editor, "; typed here\n", after: "[MeterTitle]"), "typed above a layer")
            t.check(editor.codeView.hasUncommittedChanges)
            editor.setHidden(true, meter: "MeterTitle")
            t.check(text().contains("; typed here\n[MeterTitle]"), "the typing was committed at once")
            t.equal(editor.window?.undoManager?.undoActionName, "Edit Code")
            AppSelfTest.spin(timeout: 3) { skin()?.meter(named: "MeterTitle")?.hidden == true }
            t.check(skin()?.meter(named: "MeterTitle")?.hidden == true, "then the visual edit written")
            t.check(!editor.codeView.hasUncommittedChanges)
            t.check(editor.codeView.text.contains("; typed here") && editor.codeView.text.contains("Hidden=1"),
                    "the code pane shows both")
            t.equal(editor.window?.undoManager?.undoActionName, "Hide \(editor.displayName(ofSection: "MeterTitle"))")
            settle()
            editor.window?.undoManager?.undo()
            t.check(text().contains("; typed here") && skin()?.meter(named: "MeterTitle")?.hidden == false,
                    "undo takes back the visual edit only")
            settle()
            editor.window?.undoManager?.undo()
            t.check(!text().contains("; typed here"), "then the typing")

            // Live reload does not take our own commits for changes made elsewhere.
            t.check(type(editor, "x", after: "Text=CPU!?\n", offset: 10), "typed")
            editor.saveSkinCode(nil)
            let committed = app.controller(for: "Deskset\\System")
            editor.tick()
            t.check(app.controller(for: "Deskset\\System") === committed, "no second refresh")
            t.check(!editor.toastText.contains("changed on disk"), editor.toastText)

            // A change made elsewhere reaches the clean buffer (keeping the caret).
            let caret = editor.codeView.textView.selectedRange()
            try text().replacingOccurrences(of: "Update=1000", with: "Update=2000").write(to: ini, atomically: true,
                                                                                         encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: ini.path)
            editor.tick()
            t.equal(skin()?.settings.update, 2000, "live reload")
            t.check(editor.codeView.text.contains("Update=2000"), "the code pane follows")
            t.equal(editor.codeView.textView.selectedRange().location, caret.location, "the caret stays")
            editor.window?.close()
        }
    }

    // MARK: Focus

    static func focusTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window keeps the keyboard focus") {
            guard let (app, editor) = try openEditor(t) else { return }
            guard let window = editor.window, let ini = app.controller(for: "Deskset\\System")?.skin.fileURL else {
                return t.check(false, "window")
            }
            editor.setMode(.split)
            editor.select(section: "MeterCPULabel")
            func fields() -> [NSTextField] {
                var found: [NSTextField] = []
                func collect(_ view: NSView) {
                    for v in view.subviews {
                        if let f = v as? NSTextField, f.isEditable, !f.isHiddenOrHasHiddenAncestor { found.append(f) }
                        collect(v)
                    }
                }
                collect(editor.inspectorStack)
                return found
            }
            /// The field whose field editor has the keyboard focus.
            func focused() -> NSTextField? {
                guard let e = window.firstResponder as? NSTextView, e.isFieldEditor else { return nil }
                return e.delegate as? NSTextField
            }
            /// What a field edits: the inspector names its fields "<section>/<option>".
            func edit(of field: NSTextField?) -> String? { field?.identifier?.rawValue }
            // The layer's Y (48).
            guard let field = fields().first(where: { $0.identifier?.rawValue == "MeterCPULabel/Y" }) else {
                return t.check(false, "the inspector has a Y field")
            }
            let target = edit(of: field)

            // Typing in the code, then clicking a field of the inspector: the code is committed as the focus leaves
            // it (which refreshes the skin), and the field the user clicked still gets the focus.
            t.check(window.makeFirstResponder(editor.codeView.textView), "the code has the focus")
            t.check(type(editor, "!", after: "Text=CPU\n", offset: 8), "typed")
            let before = app.controller(for: "Deskset\\System")
            t.check(window.makeFirstResponder(field), "clicked a field")
            t.check(!editor.codeView.hasUncommittedChanges, "the code was committed on the way out")
            t.check(((try? String(contentsOf: ini, encoding: .utf8)) ?? "").contains("Text=CPU!\n"), "and written")
            t.check(app.controller(for: "Deskset\\System") !== before, "the skin refreshed")
            t.check(focused() === field && field.window === window, "the clicked field has the focus, in the window")
            // The inspector is rebuilt for the refreshed skin once the click is over; the same field keeps the focus.
            settle()
            let again = focused()
            t.check(again != nil && again?.window === window && again?.isDescendant(of: editor.inspectorStack) == true,
                    "a field of the inspector still has the focus")
            t.equal(edit(of: again), target, "the same field")
            t.equal(editor.skin?.meter(named: "MeterCPULabel")?.rawOption("Text"), "CPU!", "the inspector shows the new skin")

            // A field committed while it keeps the focus (Return): the rebuilt inspector gives it back.
            if let again, let fieldEditor = again.currentEditor() {
                fieldEditor.string = "50"
                if let value = again as? ValueField { value.finishEditing(deferred: false) } else { editor.fieldCommitted(again) }
                t.equal(editor.skin?.meter(named: "MeterCPULabel")?.rawOption("Y"), "50", "written")
                let after = focused()
                t.check(after != nil && after !== again && after?.window === window,
                        "the new inspector's field has the focus after its own commit")
                t.equal(edit(of: after), target)
                t.equal(after?.currentEditor()?.string, "50")
            } else {
                t.check(false, "the field has a field editor")
            }
            settle()

            // Clicking the canvas after typing: the refresh happens before the click reaches the canvas (it drags the
            // refreshed layers), and nothing in the inspector takes the focus back.
            t.check(window.makeFirstResponder(editor.codeView.textView))
            t.check(type(editor, "?", after: "Text=CPU!\n", offset: 9), "typed")
            t.check(window.makeFirstResponder(editor.canvas), "clicked the canvas")
            t.equal(app.controller(for: "Deskset\\System")?.skin.meter(named: "MeterCPULabel")?.rawOption("Text"), "CPU!?",
                    "refreshed at once")
            settle()
            t.check(window.firstResponder === editor.canvas, "the canvas keeps the focus")
            window.close()
        }
    }

    // MARK: Selection sync

    static func selectionSyncTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window selection sync") {
            guard let (_, editor) = try openEditor(t) else { return }
            editor.setMode(.split)
            let code = editor.codeView
            func tinted(_ section: String) -> Bool {
                guard let lines = code.lineRange(ofSection: section), let tint = code.tintedRange else { return false }
                return CodeDocument(text: code.text).range(ofLines: lines) == tint
            }
            func headerVisible(_ section: String) -> Bool {
                guard let lines = code.lineRange(ofSection: section),
                      let rect = code.textView.lineRect(forCharacterRange: CodeDocument(text: code.text).range(ofLine: lines.lowerBound))
                else { return false }
                return code.textView.visibleRect.intersects(rect)
            }
            editor.window?.makeFirstResponder(editor.canvas)

            // A layer reveals its section and tints it, without taking the focus.
            editor.select(section: "MeterSwapBar")
            t.equal(code.currentFile?.lastPathComponent, "System.ini")
            t.check(tinted("MeterSwapBar"), "the layer's block is tinted")
            t.check(headerVisible("MeterSwapBar"), "and scrolled into view")
            t.check(editor.window?.firstResponder === editor.canvas, "the canvas keeps the focus")

            // A style defined in an @Include file: the code switches files.
            editor.select(section: "StyleLabel")
            t.equal(code.currentFile?.lastPathComponent, "Styles.inc", "the file that defines it")
            t.check(tinted("StyleLabel") && headerVisible("StyleLabel"))
            // The skin itself: [Rainmeter].
            editor.canvasSelectionChanged([])
            t.equal(code.currentFile?.lastPathComponent, "System.ini")
            t.check(tinted("Rainmeter"), "the skin shows [Rainmeter]")
            // A data source.
            editor.select(section: "MeasureRAM")
            t.check(tinted("MeasureRAM"))

            // The caret coming to rest in a section selects what it defines.
            func putCaret(in section: String, line offset: Int = 1) {
                guard let lines = code.lineRange(ofSection: section) else { return t.check(false, "no [\(section)]") }
                let range = CodeDocument(text: code.text).range(ofLine: lines.lowerBound + offset)
                code.textView.setSelectedRange(NSRange(location: range.location + 2, length: 0))
                // The rest is reported by its timer; fired here so the run loop's timing cannot matter.
                t.check(code.fireCaretRest(), "a caret rest is pending")
            }
            let origin = code.scrollView.contentView.bounds.origin
            putCaret(in: "MeterRAMBar")
            t.equal(editor.selectedSection, "MeterRAMBar", "caret in [MeterRAMBar] selects the layer")
            t.equal(editor.sidebarTab, .layers)
            t.equal(editor.canvas.selection, "MeterRAMBar", "outlined on the canvas")
            t.check(tinted("MeterRAMBar"), "the block is tinted")
            t.equal(code.scrollView.contentView.bounds.origin, origin, "the code does not jump")
            putCaret(in: "MeasureCPU")
            t.equal(editor.selectedSection, "MeasureCPU")
            t.equal(editor.sidebarTab, .data, "the sidebar follows to Data")
            putCaret(in: "Metadata")
            t.equal(editor.selectedSection, nil, "[Metadata] selects the skin")
            t.equal(editor.sidebarTab, .layers)
            putCaret(in: "MeterTitle")
            t.equal(editor.selectedSection, "MeterTitle")
            editor.selectSidebarTab(.library)
            putCaret(in: "MeterCPUGraph")
            t.equal(editor.sidebarTab, .layers, "from the code, even the library gives way to the layer")

            // Selections made elsewhere keep the library open (adding several components in a row).
            editor.selectSidebarTab(.library)
            editor.select(section: "MeterCPUFill")
            t.equal(editor.sidebarTab, .library)

            // "Show in Code" / the router: Split from Design, the line shown in its file.
            editor.setMode(.design)
            guard let skin = editor.skin, let styles = skin.includedFiles.first(where: { $0.lastPathComponent == "Styles.inc" }),
                  let location = skin.sources.location(section: "StyleValueRight") else { return t.check(false, "fixture") }
            let selected = editor.revealInCode(file: styles, line: location.line + 1)
            t.equal(selected, "StyleValueRight")
            t.equal(editor.mode, .split, "Design switches to Split")
            t.equal(code.currentFile?.lastPathComponent, "Styles.inc")
            t.check(headerVisible("StyleValueRight"))
            editor.window?.close()
        }
    }

    // MARK: Inserting

    static func insertTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window inserts from the library") {
            guard let (app, editor) = try openEditor(t) else { return }
            guard let ini = app.controller(for: "Deskset\\System")?.skin.fileURL else { return t.check(false, "skin") }
            func text() -> String { (try? String(contentsOf: ini, encoding: .utf8)) ?? "" }
            func skin() -> Skin? { app.controller(for: "Deskset\\System")?.skin }
            func frame(_ name: String) -> SkinRect { skin()?.meter(named: name)?.frame ?? SkinRect() }

            // Dropped on the canvas: at the ghost's frame, selected, one undo step.
            let m = SkinCanvasView.margin
            t.check(editor.canvas.dropComponent(id: "cpu", at: NSPoint(x: m + 100, y: m + 50), snapping: false), "dropped")
            t.equal(editor.selectedSection, "MeterCPUBar", "the new layer is selected")
            t.equal(frame("MeterCPUBar").x, 20, "X from the drop (centred on the pointer)")
            t.equal(frame("MeterCPUBar").y, 47)
            t.equal(frame("MeterCPUBar").width, 160, "default size")
            t.equal(skin()?.measure(named: "MeasureCPU2")?.type.lowercased(), "cpu", "with its data source")
            t.equal(editor.window?.undoManager?.undoActionName, "Add CPU Bar")
            settle()
            editor.window?.undoManager?.undo()
            t.check(!text().contains("MeterCPUBar") && !text().contains("MeasureCPU2"), "one undo step removes both")
            settle()

            // Where every layer is placed (its X / Y before alignment), to check that inserting moves none of them.
            func anchors() -> [String: [Double]] {
                Dictionary(uniqueKeysWithValues: (skin()?.meters ?? []).map { ($0.name, [$0.anchorX, $0.anchorY]) })
            }
            func checkNothingMoved(_ before: [String: [Double]], except added: String) {
                let now = anchors()
                for (name, place) in before where now[name] != place {
                    t.check(false, "[\(name)] moved from \(place) to \(now[name] ?? [])")
                }
                t.equal(Set(now.keys), Set(before.keys).union([added]), "one layer more")
            }
            func offset(_ name: String) -> Int { (text() as NSString).range(of: "[\(name)]").location }

            // Clicked: in free space (docs/editor-friendly.md §5.1) — 8 points below the lowest visible layer, at the
            // leftmost layer's left edge, never 10 points under the selection — written at the end of the skin file
            // (in front of everything): nothing else moves.
            editor.select(section: "MeterCPULabel")
            guard let content = skin()?.contentBounds() else { return t.check(false, "skin") }
            let before = anchors()
            editor.insertComponent("text")
            guard let added = editor.selectedSection, added != "MeterCPULabel" else {
                return t.check(false, "the new layer is selected")
            }
            t.equal(frame(added).x, max(content.x, 0), "at the leftmost edge")
            t.equal(frame(added).y, (content.maxY + 8).rounded(), "8 points below everything")
            checkNothingMoved(before, except: added)
            t.check(offset("MeterSwapBar") < offset(added), "written after every layer")
            t.equal(skin()?.meters.last?.name, added, "drawn in front of everything")
            t.equal(editor.window?.undoManager?.undoActionName, "Add Text")
            settle()
            editor.window?.undoManager?.undo()
            t.check(!text().contains("[\(added)]"), "undo")
            settle()

            // The chain rule: relative X or Y (also through a variable), content of a container skipped.
            if let skin = skin() {
                t.check(Editor.isRelativelyPlaced(skin.meter(named: "MeterCPUValue")!), "Y=-5r")
                t.check(Editor.isRelativelyPlaced(skin.meter(named: "MeterCPUGraph")!), "X=0r Y=0r")
                t.check(!Editor.isRelativelyPlaced(skin.meter(named: "MeterCPUFill")!), "X=#Padding# Y=66")
                t.equal(Editor.insertionPoint(after: "MeterCPUFill", in: skin), "MeterRAMLabel",
                        "after [MeterCPUGraph] (X=0r), which follows [MeterCPUFill]")
                t.equal(Editor.insertionPoint(after: "MeterSwapLabel", in: skin), "MeterSwapBar")
                t.equal(Editor.insertionPoint(after: "MeterSwapBar", in: skin), nil, "the last layer: the end of the file")
            }
            let dir = t.temporaryDirectory("insert-chain").appendingPathComponent("Skins/Chain", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("Chain.ini")
            try """
                [Variables]
                Below=4R
                [Box]
                Meter=Shape
                X=0
                Y=100
                Shape=Rectangle 0,0,50,50
                [A]
                Meter=String
                X=10
                Y=10
                Text=A
                [Inside]
                Meter=String
                Container=Box
                X=5r
                Y=5r
                Text=in
                [B]
                Meter=String
                X=0r
                Y=#Below#
                Text=B
                [C]
                Meter=String
                X=20
                Y=200
                Text=C

                """.write(to: file, atomically: true, encoding: .utf8)
            let chain = Skin(config: "Chain", fileURL: file, skinsDirectory: dir.deletingLastPathComponent(),
                             system: ComponentSampleSystem(), host: RenderHost())
            try chain.load()
            chain.update()
            t.equal(Editor.insertionPoint(after: "A", in: chain), "C",
                    "[B] follows [A] (Y=#Below# is 4R; [Inside] is placed in its container), so after [B]")
            t.equal(Editor.insertionPoint(after: "Box", in: chain), "A", "[A] is placed on its own")

            // From the Library tab: the tab stays open for the next one.
            editor.selectSidebarTab(.library)
            editor.canvasSelectionChanged([])
            editor.libraryView.card(for: "clock")?.insert()
            t.equal(editor.selectedSection, "MeterClock", "inserted and selected")
            t.equal(editor.sidebarTab, .library, "the library stays open")
            t.check(text().hasSuffix("\n") && text().contains("[MeterClock]"), "appended to the skin file")
            editor.window?.close()
        }
    }

    // MARK: External editor

    static func externalEditorTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window with an external code editor") {
            guard let (app, editor) = try openEditor(t) else { return }
            let locator = CodeEditorRoutingSelfTests.FakeLocator()
            let opener = CodeEditorRoutingSelfTests.RecordingOpener()
            let dir = t.temporaryDirectory("studio-external")
            CodeEditorRoutingSelfTests.withFakes(locator, opener) {
                let forky = CodeEditorRoutingSelfTests.fakeApp(dir, "Forky", product: ["urlProtocol": "forky"])
                locator.apps["com.example.forky"] = forky
                editor.setMode(.split)
                t.equal(editor.codeButtonTitle, "Show in Code", "built-in: the code button shows the code")
                app.state.updateEditor { $0.codeEditor = .app(bundleID: "com.example.forky", lastKnownPath: forky.path) }
                t.equal(editor.mode, .design, "an external app: no code pane")
                t.equal(editor.availableModes, [.design], "the mode control offers Design only")
                t.equal(editor.codeButtonTitle, "Open in Forky")
                let items = editor.window?.toolbar?.items ?? []
                t.check(!items.isEmpty, "the toolbar has its items")
                if !items.isEmpty {
                    let code = items.first { $0.itemIdentifier == Editor.toolbarCode }
                    t.equal(code?.label, "Open in Forky", "the toolbar button")
                    t.check(code?.view === editor.openInControl, "with its pull-down")
                    let group = items.first { $0.itemIdentifier == Editor.toolbarMode } as? NSToolbarItemGroup
                    t.equal(group?.subitems.count, 1, "no Split / Code segments")
                }
                t.equal(editor.openInControl.label(forSegment: 0), "Open in Forky")
                let menu = editor.openInControl.menu(forSegment: 1)?.items.map(\.title) ?? []
                t.equal(menu.filter { !$0.isEmpty }, ["Open in Forky", "Edit in Built-in Editor", "Reveal in Finder",
                                                      "Change Default Editor…"])
                t.check(!validate(editor, #selector(Editor.showSplitMode(_:))).isEnabled, "View ▸ Split is disabled")
                editor.setMode(.split)
                t.equal(editor.mode, .design, "and cannot be chosen")

                // The button opens the selection's section in that app, at its line.
                editor.select(section: "MeterCPUValue")
                guard let location = editor.skin?.sources.location(section: "MeterCPUValue") else {
                    return t.check(false, "location")
                }
                editor.openInEditor()
                let expected = "forky://file" + (location.file.standardizedFileURL.path
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") + ":\(location.line)"
                t.equal(opener.opened.last?.urls, [URL(string: expected)!], "through the router")
                t.equal(opener.opened.last?.app, forky)

                // Edit in Built-in Editor, once.
                editor.editInBuiltInEditor(nil)
                t.equal(editor.mode, .split, "the code pane for this window")
                t.equal(editor.availableModes, Editor.Mode.allCases)
                t.equal(editor.codeButtonTitle, "Show in Code")
                t.check(editor.codeView.lineRange(ofSection: "MeterCPUValue") != nil && editor.codeView.tintedRange != nil,
                        "showing the selection")
                // Every "Show in Code" of this window follows that choice: a pill's, a row's, the Shapes card's.
                let launched = opener.opened.count + opener.runs.count
                editor.select(section: "MeterCPUValue")
                if let location = editor.skin?.sources.location(section: "MeterCPUValue", key: "MeasureName") {
                    editor.setMode(.design)
                    editor.showInCode(location)
                    t.equal(opener.opened.count + opener.runs.count, launched, "Show in Code stays in this window")
                    t.equal(editor.mode, .split, "in its code pane")
                    t.equal(editor.codeView.caretLine, location.line, "at the line")
                } else {
                    t.check(false, "location of MeasureName")
                }

                // Back to the built-in editor.
                app.state.updateEditor { $0.codeEditor = .builtIn }
                t.equal(editor.codeButtonTitle, "Show in Code")
                t.equal(editor.availableModes, Editor.Mode.allCases)
                let opened = opener.opened.count
                editor.setMode(.design)
                editor.openInEditor()
                t.equal(opener.opened.count, opened, "the built-in editor launches nothing")
                t.equal(editor.mode, .split, "Show in Code switches to Split")
            }
            editor.window?.close()
        }
    }

    // MARK: Closing

    static func closeTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window closing with unsaved code") {
            guard let (app, editor) = try openEditor(t) else { return }
            guard let window = editor.window, let ini = app.controller(for: "Deskset\\System")?.skin.fileURL else {
                return t.check(false, "window")
            }
            editor.setMode(.split)
            let folder = ini.deletingLastPathComponent()
            let original = try Data(contentsOf: ini)
            t.check(editor.windowShouldClose(window), "nothing typed: closes")

            // A commit that cannot be written (read-only folder): the window asks, Cancel keeps it open.
            t.check(type(editor, "!", after: "Text=CPU\n", offset: 8), "typed")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            var asked = 0
            editor.closeChoice = {
                asked += 1
                return .cancel
            }
            t.check(!editor.windowShouldClose(window), "stays open")
            t.equal(asked, 1, "asked once")
            t.check(editor.codeView.hasUncommittedChanges, "the typing is kept")
            t.equal(try Data(contentsOf: ini), original, "the file is untouched")

            // Quitting (⌘Q does not close the window first) asks the same way; Cancel keeps the app running.
            t.check(app.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "the app keeps running")
            t.equal(asked, 2, "asked")
            t.check(editor.codeView.hasUncommittedChanges, "the typing is still kept")

            // A visual edit is refused too (it would be overwritten by the typing later).
            editor.setHidden(true, meter: "MeterTitle")
            t.check(editor.toastText.contains("couldn’t be saved"), editor.toastText)
            t.equal(try Data(contentsOf: ini), original)

            // Save tries again; Discard throws the typing away.
            editor.closeChoice = { .save }
            t.check(!editor.windowShouldClose(window), "Save that fails again: still open")
            editor.closeChoice = { .discard }
            t.check(editor.windowShouldClose(window), "Discard: closes")
            t.check(!editor.codeView.hasUncommittedChanges, "the edits are gone")
            t.check(!editor.codeView.text.contains("Text=CPU!"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

            // Save that works.
            t.check(type(editor, "?", after: "Text=CPU\n", offset: 8), "typed")
            editor.closeChoice = { t.check(false, "not asked when the commit works"); return .cancel }
            t.check(editor.windowShouldClose(window), "committed and closes")
            t.check(((try? String(contentsOf: ini, encoding: .utf8)) ?? "").contains("Text=CPU?\n"), "saved")

            // Quitting commits typing that was not committed yet (within the idle delay), without asking.
            t.check(type(editor, "#", after: "Text=CPU?\n", offset: 9), "typed")
            t.check(app.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "quits")
            t.check(((try? String(contentsOf: ini, encoding: .utf8)) ?? "").contains("Text=CPU?#\n"), "saved first")
            window.close()
            t.check(app.inspector == nil && app.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
                    "no editor: quits")
        }
    }

    // MARK: Menus

    static func menuTests(_ t: AppTestRunner) {
        t.suite("App: skin editor window menus") {
            guard let (app, editor) = try openEditor(t) else { return }
            let main = MainMenu.make(app: app)
            func menu(_ title: String) -> NSMenu? { main.items.first { $0.title == title }?.submenu }
            func item(_ menu: NSMenu?, _ action: Selector) -> NSMenuItem? {
                menu?.items.first { $0.action == action }
            }
            t.equal(main.items.map(\.title), ["Deskset", "File", "Edit", "View", "Insert", "Window", "Help"])
            let save = item(menu("File"), #selector(Editor.saveSkinCode(_:)))
            t.equal(save?.keyEquivalent, "s")
            t.equal(save?.keyEquivalentModifierMask, [.command])
            let view = menu("View")
            for (action, key, modifiers) in [
                (#selector(Editor.toggleSidebarPane(_:)), "s", NSEvent.ModifierFlags([.command, .control])),
                (#selector(Editor.toggleInspectorPane(_:)), "i", [.command, .option]),
                (#selector(Editor.showDesignMode(_:)), "1", [.command, .control]),
                (#selector(Editor.showSplitMode(_:)), "2", [.command, .control]),
                (#selector(Editor.showCodeMode(_:)), "3", [.command, .control]),
                (#selector(Editor.toggleCodePane(_:)), "\r", [.command, .option]),
                (#selector(Editor.zoomInClicked), "+", [.command]),
                (#selector(Editor.fitClicked), "9", [.command]),
            ] as [(Selector, String, NSEvent.ModifierFlags)] {
                let i = item(view, action)
                t.equal(i?.keyEquivalent, key, "\(action)")
                t.equal(i?.keyEquivalentModifierMask, modifiers, "\(action)")
                t.check(i?.target == nil, "\(action) goes to the key window")
            }
            t.check(item(view, #selector(Editor.showCodeBelow(_:))) != nil && item(view, #selector(Editor.showCodeOnRight(_:))) != nil)
            let find = menu("Edit")?.items.first { $0.title == "Find" }?.submenu
            let findItem = find?.items.first { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command] }
            t.equal(findItem?.action, #selector(NSTextView.performFindPanelAction(_:)))
            t.equal(findItem?.tag, NSTextFinder.Action.showFindInterface.rawValue)
            let insert = menu("Insert")
            t.equal(item(insert, #selector(Editor.showLibrary(_:)))?.keyEquivalentModifierMask, [.command, .shift])
            let ids = insert?.items.compactMap { $0.representedObject as? String } ?? []
            t.equal(ids, EditorComponents.Category.allCases.flatMap { c in EditorComponents.all.filter { $0.category == c }.map(\.id) },
                    "every component, by category")

            // Insert ▸ a component goes to the editor.
            if let clock = insert?.items.first(where: { $0.representedObject as? String == "clock" }) {
                t.check(editor.validateMenuItem(clock), "enabled with a skin")
                editor.componentChosen(clock)
                t.equal(editor.selectedSection, "MeterClock", "inserted")
            }
            // Edit ▸ Find with the focus elsewhere: the code pane's find bar.
            t.check(!validate(editor, #selector(Editor.performFindPanelAction(_:))).isEnabled, "no Find without the code")
            editor.setMode(.split)
            t.check(validate(editor, #selector(Editor.performFindPanelAction(_:))).isEnabled)
            let show = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
            show.tag = NSTextFinder.Action.showFindInterface.rawValue
            editor.performFindPanelAction(show)
            t.check((editor.window?.firstResponder as? NSView)?.isDescendant(of: editor.codeView) == true,
                    "the focus moves to the code")
            t.check(editor.codeView.scrollView.isFindBarVisible, "the find bar shows")
            editor.window?.close()
        }
    }
}
