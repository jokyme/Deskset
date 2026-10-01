import AppKit
import DeskLanguage
import DesksetCore

/// Native completion consumers from actual checked single-file documents. Nothing is activated or shown.
enum DeskCodeCompletionSelfTests {
    static func run(_ t: AppTestRunner) {
        textTests(t)
        permissionTests(t)
        gridTests(t)
        rejectionTests(t)
    }

    private struct Fixture {
        let app: AppController
        let file: URL
        let controller: CodeFileWindowController
        var editor: CodeEditorView { controller.codeView }
    }

    private enum Failure: Error {
        case missingCurrentCheck
        case missingServiceItem(String)
        case missingNativeTitle(String)
    }

    private static func fixture(_ t: AppTestRunner, text: String,
                                queue: DispatchQueue = DispatchQueue(label: "desk.completion.test.check")) throws -> Fixture {
        let root = t.temporaryDirectory("desk-completion")
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        let file = root.appendingPathComponent("Widget.desk")
        try Data(text.utf8).write(to: file)
        let controller = try CodeFileWindowController(file: file, app: app, deskCheckQueue: queue)
        controller.codeView.idleCommitDelay = 600
        controller.codeView.typedTextDelay = 600
        controller.codeView.layoutSubtreeIfNeeded()
        t.atSuiteEnd {
            controller.deskChecking?.close()
            controller.codeView.onCommit = { _, _ in false }
            controller.codeView.onDiskConflict = { _ in .decideLater }
            controller.codeView.discardUncommittedChanges()
            controller.window?.close()
            _ = app.stopAllForTermination()
            app.endEngineThread()
        }
        return Fixture(app: app, file: file, controller: controller)
    }

    private static func settled(_ f: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            guard let checking = f.controller.deskChecking else { return false }
            return checking.snapshot.isChecked && checking.isCurrent(checking.snapshot)
        }
    }

    private static func useLanguage(_ language: StudioLanguage, _ t: AppTestRunner) {
        let original = StudioText.languageOverride
        StudioText.languageOverride = language
        t.atSuiteEnd { StudioText.languageOverride = original }
    }

    /// The service item is only observed. Native API callbacks, not synthetic snapshots or host closures, choose it.
    private static func choice(_ f: Fixture, caret: Int, label: String, title: String) throws
        -> (range: NSRange, title: String, item: DeskCompletionItem, snapshot: DeskSnapshot) {
        f.editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
        guard let checking = f.controller.deskChecking, checking.snapshot.isChecked,
              checking.isCurrent(checking.snapshot) else { throw Failure.missingCurrentCheck }
        let snapshot = checking.snapshot
        let list = snapshot.completions(at: snapshot.index.position(utf16: caret))
        guard let item = list.items.first(where: { $0.label == label }) else { throw Failure.missingServiceItem(label) }
        let range = f.editor.textView.rangeForUserCompletion
        var selected = -99
        let words = f.editor.textView.completions(forPartialWordRange: range, indexOfSelectedItem: &selected)
        guard let words, words.contains(title), selected == 0 else { throw Failure.missingNativeTitle(title) }
        return (range, title, item, snapshot)
    }

    private static let textBefore = "\u{FEFF}info { name: \"补全😀\" }\r\nwidget {\r\n    Tex\r\n}\r\n"
    private static let textPrefix = "\u{FEFF}info { name: \"补全😀\" }\r\nwidget {\r\n    Tex"
    private static let textAfter = "\u{FEFF}info { name: \"补全😀\" }\r\nwidget {\r\n    Text(\"Text\")\r\n}\r\n"
    private static let textTitle = "Text — Text (what it shows)"

    private static func textTests(_ t: AppTestRunner) {
        t.suite("Desk: code completion: native Text preview and cancellation are read only and final insertion has one undo") {
            useLanguage(.english, t)
            let f = try fixture(t, text: textBefore)
            guard let undo = f.editor.textView.undoManager else { return t.check(false, "the native text view has no undo manager") }
            let preview = try choice(f, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            t.equal(preview.range, NSRange(location: textPrefix.utf16.count - 3, length: 3), "BOM and emoji count as UTF16 before the real prefix")
            t.equal(preview.item.plainText, "Text(\"Text\")")
            let revision = f.editor.textRevision
            f.editor.textView.insertCompletion(preview.title, forPartialWordRange: preview.range,
                                              movement: NSDownTextMovement, isFinal: false)
            t.equal(f.editor.text, textBefore)
            t.equal(f.editor.textRevision, revision)
            t.check(!undo.canUndo && !f.editor.isDirty, "native keyboard preview creates no edit")
            f.editor.textView.insertCompletion(preview.title, forPartialWordRange: preview.range,
                                              movement: NSCancelTextMovement, isFinal: true)
            t.equal(f.editor.text, textBefore)
            t.equal(f.editor.textView.selectedRange(), NSRange(location: textPrefix.utf16.count, length: 0))
            t.equal(f.editor.textRevision, revision)
            t.check(!undo.canUndo && !f.editor.isDirty, "native cancellation creates no edit")
            let accepted = try choice(f, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            f.editor.textView.insertCompletion(accepted.title, forPartialWordRange: accepted.range,
                                              movement: NSReturnTextMovement, isFinal: true)
            t.equal(f.editor.text, textAfter, "the whole-buffer expected answer is a literal, not the completion edit implementation")
            t.equal(f.editor.textView.selectedRange(), NSRange(location: "\u{FEFF}info { name: \"补全😀\" }\r\nwidget {\r\n    Text(\"Text\")".utf16.count, length: 0))
            t.check(f.editor.textRevision > revision && f.editor.isDirty)
            t.check(settled(f))
            t.equal(try Data(contentsOf: f.file), Data(textBefore.utf8), "accepting writes only the buffer")
            CodeEditorSelfTests.spin(0.02)
            t.equal(undo.undoActionName, "Complete Text")
            undo.undo()
            t.equal(f.editor.text, textBefore)
            t.check(!undo.canUndo && !f.editor.isDirty, "one undo restores the entire original BOM/CRLF buffer")
            t.check(settled(f))
            undo.redo()
            t.equal(f.editor.text, textAfter)
            t.check(settled(f))
            t.equal(f.app.sortedControllers.count, 0, "completion never activates a skin")

            // The actual service already tests a name before its existing call. Here a real misspelled suffix must
            // disappear, although AppKit's request range contains only the prefix before the caret.
            let middleBefore = "\u{FEFF}info { name: \"中词😀\" }\r\nwidget {\r\n    Texxx(\"甲😀\")\r\n}\r\n"
            let middlePrefix = "\u{FEFF}info { name: \"中词😀\" }\r\nwidget {\r\n    Tex"
            let middleAfter = "\u{FEFF}info { name: \"中词😀\" }\r\nwidget {\r\n    Text(\"甲😀\")\r\n}\r\n"
            let middle = try fixture(t, text: middleBefore)
            guard let middleUndo = middle.editor.textView.undoManager else {
                return t.check(false, "the native middle-word fixture has no undo manager")
            }
            let name = try choice(middle, caret: middlePrefix.utf16.count, label: "Text", title: textTitle)
            t.equal(name.range, NSRange(location: middlePrefix.utf16.count - 3, length: 3))
            t.equal(name.item.range.nsRange, NSRange(location: middlePrefix.utf16.count - 3, length: 5), "the actual service edit includes the suffix after the caret")
            t.equal(name.item.plainText, "Text", "the existing call keeps its parentheses and argument")
            middle.editor.textView.insertCompletion(name.title, forPartialWordRange: name.range,
                                                   movement: NSReturnTextMovement, isFinal: true)
            t.equal(middle.editor.text, middleAfter, "the whole word is corrected with no duplicate call or parameter")
            t.equal(middle.editor.textView.selectedRange(), NSRange(location: "\u{FEFF}info { name: \"中词😀\" }\r\nwidget {\r\n    Text".utf16.count, length: 0))
            t.check(settled(middle))
            t.equal(try Data(contentsOf: middle.file), Data(middleBefore.utf8))
            CodeEditorSelfTests.spin(0.02)
            t.equal(middleUndo.undoActionName, "Complete Text")
            middleUndo.undo()
            t.equal(middle.editor.text, middleBefore)
            t.check(!middleUndo.canUndo && !middle.editor.isDirty, "the middle-word acceptance is one complete undo step")
            t.check(settled(middle))
        }
    }

    private static func permissionTests(_ t: AppTestRunner) {
        t.suite("Desk: code completion: native music play and its permission additional edit are one atomic undo step") {
            useLanguage(.english, t)
            let before = "\u{FEFF}info {\r\n    name: \"音乐😀\"\r\n}\r\n\r\nwidget {\r\n    Text(\"Play\").onClick {\r\n        music.pl\r\n    }\r\n}\r\n"
            let prefix = "\u{FEFF}info {\r\n    name: \"音乐😀\"\r\n}\r\n\r\nwidget {\r\n    Text(\"Play\").onClick {\r\n        music.pl"
            let after = "\u{FEFF}info {\r\n    name: \"音乐😀\"\r\n    permissions: [.music]\r\n}\r\n\r\nwidget {\r\n    Text(\"Play\").onClick {\r\n        music.play()\r\n    }\r\n}\r\n"
            let f = try fixture(t, text: before)
            guard let checking = f.controller.deskChecking, let undo = f.editor.textView.undoManager else {
                return t.check(false, "the native permission fixture has no checker or undo manager")
            }
            let selected = try choice(f, caret: prefix.utf16.count, label: "play", title: "play — Play")
            t.equal(selected.range, NSRange(location: prefix.utf16.count - 2, length: 2))
            t.equal(selected.item.plainText, "play()")
            t.equal(selected.item.additionalEdits.count, 1, "the actual service supplies the required second edit")
            t.equal(selected.item.additionalEdits.first?.newText, "\n    permissions: [.music]")
            t.check(!undo.canUndo)
            f.editor.textView.insertCompletion(selected.title, forPartialWordRange: selected.range,
                                              movement: NSReturnTextMovement, isFinal: true)
            t.equal(f.editor.text, after, "the primary and permission text must both appear in their original ranges")
            t.equal(f.editor.textView.selectedRange(), NSRange(location: "\u{FEFF}info {\r\n    name: \"音乐😀\"\r\n    permissions: [.music]\r\n}\r\n\r\nwidget {\r\n    Text(\"Play\").onClick {\r\n        music.play()".utf16.count, length: 0))
            t.check(settled(f))
            t.check(checking.snapshot.checked.requirements.permissions.contains("music"), "the resulting buffer is really checked as using music")
            t.check(!checking.snapshot.diagnostics.contains { $0.id == .missingPermission })
            t.equal(try Data(contentsOf: f.file), Data(before.utf8), "metadata editing does not execute music or save immediately")
            CodeEditorSelfTests.spin(0.02)
            t.equal(undo.undoActionName, "Complete play")
            undo.undo()
            t.equal(f.editor.text, before)
            t.check(!undo.canUndo && !f.editor.isDirty, "the permission cannot be left behind by the one undo")
            t.check(settled(f))
            undo.redo()
            t.equal(f.editor.text, after)
            t.check(settled(f))
            t.equal(f.app.sortedControllers.count, 0)
        }
    }

    private static func gridTests(_ t: AppTestRunner) {
        t.suite("Desk: code completion: native Grid uses the plain multiline fallback and real localized labels") {
            let original = StudioText.languageOverride
            t.atSuiteEnd { StudioText.languageOverride = original }
            let before = "info { name: \"Grid😀\" }\r\nwidget {\r\n    Gri\r\n}\r\n"
            let prefix = "info { name: \"Grid😀\" }\r\nwidget {\r\n    Gri"
            let after = "info { name: \"Grid😀\" }\r\nwidget {\r\n    Grid(columns: 7) {\r\n        \r\n    }\r\n}\r\n"
            let variants: [(StudioLanguage, String, String)] = [
                (.english, "Grid — Grid (columns: a number, …)", "Complete Grid"),
                (.chinese, "Grid — 网格（columns：数字，…）", "补全 Grid")
            ]
            for (language, title, actionName) in variants {
                StudioText.languageOverride = language
                let f = try fixture(t, text: before)
                guard let undo = f.editor.textView.undoManager else { return t.check(false, "the native Grid fixture has no undo manager") }
                let selected = try choice(f, caret: prefix.utf16.count, label: "Grid", title: title)
                t.check(selected.item.isSnippet && selected.item.insertText.contains("${1:7}") && selected.item.insertText.contains("$0"), "the actual item really has tab stops")
                t.equal(selected.item.plainText, "Grid(columns: 7) {\n        \n    }")
                f.editor.textView.insertCompletion(selected.title, forPartialWordRange: selected.range,
                                                  movement: NSReturnTextMovement, isFinal: true)
                t.equal(f.editor.text, after)
                t.check(!f.editor.text.contains("${") && !f.editor.text.contains("$0"), "snippet markers never enter the native buffer")
                t.check(settled(f))
                t.equal(try Data(contentsOf: f.file), Data(before.utf8))
                CodeEditorSelfTests.spin(0.02)
                t.equal(undo.undoActionName, actionName)
                undo.undo()
                t.equal(f.editor.text, before)
                t.check(!undo.canUndo && !f.editor.isDirty)
                t.check(settled(f))
                t.equal(f.app.sortedControllers.count, 0)
            }
        }
    }

    private static func unchanged(_ t: AppTestRunner, _ f: Fixture, text: String, revision: Int) {
        t.equal(f.editor.text, text)
        t.equal(f.editor.textRevision, revision)
        t.check(!f.editor.isDirty && f.editor.textView.undoManager?.canUndo == false, "rejection creates neither a partial edit nor an undo step")
    }

    private static func rejectionTests(_ t: AppTestRunner) {
        t.suite("Desk: code completion: generation selection pending closed read error and read only reject native retained choices") {
            useLanguage(.english, t)
            let unknown = try fixture(t, text: textBefore)
            let offered = try choice(unknown, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let unknownRevision = unknown.editor.textRevision
            unknown.editor.textView.insertCompletion("No such checked completion — control", forPartialWordRange: offered.range,
                                                     movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, unknown, text: textBefore, revision: unknownRevision)

            let wrongRange = try fixture(t, text: textBefore)
            let rightRange = try choice(wrongRange, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let rangeRevision = wrongRange.editor.textRevision
            let mismatch = NSRange(location: rightRange.range.location + 1, length: rightRange.range.length)
            wrongRange.editor.textView.insertCompletion(rightRange.title, forPartialWordRange: mismatch,
                                                        movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, wrongRange, text: textBefore, revision: rangeRevision)

            let nonempty = try fixture(t, text: textBefore)
            let nonemptyRevision = nonempty.editor.textRevision
            nonempty.editor.textView.setSelectedRange(NSRange(location: textPrefix.utf16.count - 3, length: 3))
            let absent = nonempty.editor.textView.rangeForUserCompletion
            t.equal(absent, NSRange(location: NSNotFound, length: 0), "an actual nonempty native selection cannot request Desk completion")
            var selectedIndex = -99
            let noWords = nonempty.editor.textView.completions(forPartialWordRange: absent, indexOfSelectedItem: &selectedIndex)
            t.equal(noWords ?? ["unexpected nil"], [])
            t.equal(selectedIndex, -1)
            unchanged(t, nonempty, text: textBefore, revision: nonemptyRevision)

            // Selection changes invalidate a real list even when the checked text is unchanged.
            let selected = try fixture(t, text: textBefore)
            let oldSelection = try choice(selected, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let selectionRevision = selected.editor.textRevision
            selected.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            selected.editor.textView.insertCompletion(oldSelection.title, forPartialWordRange: oldSelection.range,
                                                      movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, selected, text: textBefore, revision: selectionRevision)
            t.equal(selected.editor.textView.selectedRange(), NSRange(location: 0, length: 0))

            // A same-text recheck is still a different generation; no fake snapshot is supplied to the consumer.
            let generation = try fixture(t, text: textBefore)
            let oldGeneration = try choice(generation, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let generationRevision = generation.editor.textRevision
            generation.controller.deskChecking?.recheck()
            t.check(generation.controller.deskChecking?.snapshot.generation != oldGeneration.snapshot.generation)
            generation.editor.textView.insertCompletion(oldGeneration.title, forPartialWordRange: oldGeneration.range,
                                                       movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, generation, text: textBefore, revision: generationRevision)
            t.check(settled(generation))

            let queue = DispatchQueue(label: "desk.completion.test.held")
            queue.suspend()
            var held = true
            defer { if held { queue.resume() } }
            let largeText = textBefore + "//" + String(repeating: "x", count: 9_000) + "\r\n"
            let pending = try fixture(t, text: largeText, queue: queue)
            let oldPending = try choice(pending, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let pendingRevision = pending.editor.textRevision
            pending.controller.deskChecking?.recheck()
            t.check(pending.controller.deskChecking?.snapshot.isChecked == false, "the held current real service check is pending")
            t.equal(pending.editor.textView.rangeForUserCompletion, NSRange(location: NSNotFound, length: 0))
            pending.editor.textView.insertCompletion(oldPending.title, forPartialWordRange: oldPending.range,
                                                    movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, pending, text: largeText, revision: pendingRevision)
            queue.resume()
            held = false
            t.check(settled(pending))

            let readOnly = try fixture(t, text: textBefore)
            let oldReadOnly = try choice(readOnly, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let readOnlyRevision = readOnly.editor.textRevision
            readOnly.editor.textView.isEditable = false
            readOnly.editor.textView.insertCompletion(oldReadOnly.title, forPartialWordRange: oldReadOnly.range,
                                                     movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, readOnly, text: textBefore, revision: readOnlyRevision)
            t.equal(readOnly.editor.textView.rangeForUserCompletion, NSRange(location: NSNotFound, length: 0))
            readOnly.editor.textView.isEditable = true

            let failedRead = try fixture(t, text: textBefore)
            let oldRead = try choice(failedRead, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let readRevision = failedRead.editor.textRevision
            try Data([0xC3]).write(to: failedRead.file)
            failedRead.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification,
                                                                 object: failedRead.controller.window))
            t.check(failedRead.controller.readError != nil, "the real strict disk reload fails")
            failedRead.editor.textView.insertCompletion(oldRead.title, forPartialWordRange: oldRead.range,
                                                       movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, failedRead, text: textBefore, revision: readRevision)
            t.equal(try Data(contentsOf: failedRead.file), Data([0xC3]))
            t.equal(failedRead.editor.textView.rangeForUserCompletion, NSRange(location: NSNotFound, length: 0))

            let closed = try fixture(t, text: textBefore)
            let oldClosed = try choice(closed, caret: textPrefix.utf16.count, label: "Text", title: textTitle)
            let closedRevision = closed.editor.textRevision
            closed.controller.deskChecking?.close()
            closed.editor.textView.insertCompletion(oldClosed.title, forPartialWordRange: oldClosed.range,
                                                   movement: NSReturnTextMovement, isFinal: true)
            unchanged(t, closed, text: textBefore, revision: closedRevision)
            t.equal(closed.editor.textView.rangeForUserCompletion, NSRange(location: NSNotFound, length: 0))
            closed.controller.window?.close()
            t.check(closed.editor.onCompletionRange == nil && closed.editor.onCompletions == nil
                    && closed.editor.onInsertCompletion == nil, "actual window close unregisters the native Desk callbacks")
            t.equal(try Data(contentsOf: closed.file), Data(textBefore.utf8))
            t.check([unknown, wrongRange, nonempty, selected, generation, pending, readOnly, failedRead, closed].allSatisfy { $0.app.sortedControllers.isEmpty })
        }
    }
}
