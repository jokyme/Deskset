import AppKit
import DeskLanguage
import DesksetCore

/// Actual single-file windows and NSTextView edits. No skin is activated, and all document I/O is in test scratch.
enum DeskCodeDocumentSelfTests {
    static func run(_ t: AppTestRunner) {
        checkingTests(t)
        resourceLanguageTests(t)
        encodingTests(t)
        reloadTests(t)
        staleTests(t)
    }

    private struct Fixture {
        let app: AppController
        let file: URL
        let controller: CodeFileWindowController
        var editor: CodeEditorView { controller.codeView }
    }

    private static func app(_ t: AppTestRunner) -> AppController {
        let root = t.temporaryDirectory("desk-document-app")
        return AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                             skinsDirectory: root.appendingPathComponent("Skins"),
                             layoutsDirectory: root.appendingPathComponent("Layouts"),
                             backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                             settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
    }

    private static func fixture(_ t: AppTestRunner, data: Data,
                                queue: DispatchQueue = DispatchQueue(label: "desk.document.test.check")) throws -> Fixture {
        let owner = app(t)
        let file = t.temporaryDirectory("desk-document").appendingPathComponent("Widget.desk")
        try data.write(to: file)
        let controller = try CodeFileWindowController(file: file, app: owner, deskCheckQueue: queue)
        // Keep typing in memory until this suite explicitly asks to save.
        controller.codeView.idleCommitDelay = 600
        controller.codeView.typedTextDelay = 600
        t.atSuiteEnd {
            controller.deskChecking?.close()
            controller.codeView.onCommit = { _, _ in false }
            controller.codeView.onDiskConflict = { _ in .decideLater }
            controller.codeView.discardUncommittedChanges()
            controller.window?.close()
            _ = owner.stopAllForTermination()
            owner.endEngineThread()
        }
        return Fixture(app: owner, file: file, controller: controller)
    }

    private static func type(_ text: String, replacing range: NSRange, in editor: CodeEditorView) {
        editor.textView.setSelectedRange(range)
        editor.textView.insertText(text, replacementRange: range)
    }

    private static func settled(_ fixture: Fixture) -> Bool {
        AppSelfTest.spin(timeout: 10) {
            guard let snapshot = fixture.controller.deskChecking?.snapshot else { return false }
            return snapshot.isChecked && snapshot.version == fixture.editor.textRevision
                && snapshot.text.utf8.elementsEqual(fixture.editor.text.utf8)
        }
    }

    private static func checkingTests(_ t: AppTestRunner) {
        t.suite("Desk: document checking: unknown native symbols warn and an actual edit removes the warning") {
            let missing = "deskset.nonexistent.symbol.87fc2"
            let text = "info { name: \"Symbols\" }\nwidget { Icon(\"\(missing)\") }\n"
            let f = try fixture(t, data: Data(text.utf8))
            guard let checking = f.controller.deskChecking else { return t.check(false, "missing document checker") }
            let warnings = checking.snapshot.diagnostics.filter { $0.id == .unknownSymbol }
            t.equal(warnings.count, 1)
            t.equal(warnings.first?.severity, .warning)
            t.check(!checking.snapshot.checked.diagnostics.contains { $0.severity == .error })
            let previous = checking.snapshot
            type("wifi", replacing: (f.editor.text as NSString).range(of: missing), in: f.editor)
            t.check(settled(f), "native availability is checked after the source edit")
            t.check(!checking.snapshot.diagnostics.contains { $0.id == .unknownSymbol })
            t.check(!checking.publish(previous), "old platform warnings cannot republish after an edit")
            t.equal(try Data(contentsOf: f.file), Data(text.utf8), "platform checks do not save the document")
            t.equal(f.app.sortedControllers.count, 0, "checking a symbol does not activate a desktop widget")
        }

        t.suite("Desk: document checking: actual text edits, UTF16 ranges, platform fonts and window messages") {
            let oldLanguage = StudioText.languageOverride
            StudioText.languageOverride = .english
            defer { StudioText.languageOverride = oldLanguage }
            guard let installed = Fonts.installedFamily(named: "Helvetica") else {
                return t.check(false, "the real installed Helvetica control is unavailable")
            }
            let missing = "Deskset Missing Document Font E39874A1"
            t.check(Fonts.installedFamily(named: missing) == nil, "the negative family really is absent")
            let text = "\u{FEFF}info { name: \"文档😀\" }\r\nwidget { Text(\"中文😀\").colr(.red).font(\"\(missing)\", 13) }\r\n"
            let original = Data(text.utf8)
            let f = try fixture(t, data: original)
            guard let checking = f.controller.deskChecking,
                  let typo = checking.snapshot.diagnostics.first(where: { $0.id == .unknownModifier }),
                  let font = checking.snapshot.diagnostics.first(where: { $0.id == .fontNotInstalled }) else {
                return t.check(false, "the actual window did not consume both checker and platform font diagnostics")
            }
            t.equal(f.editor.text, text, "Desk BOM and original line endings remain in the editor text")
            t.equal(f.editor.document(for: f.file)?.data, original, "the BOM is encoded exactly once")
            t.equal(typo.range.nsRange, (text as NSString).range(of: "colr"), "the UTF16 range follows CJK and surrogate pairs")
            t.equal(f.controller.window?.subtitle, typo.message, "the window consumes a real checked diagnostic")
            t.check(!font.message.isEmpty, "the missing native family has a localized message")
            let revision = f.editor.textRevision
            type("color", replacing: typo.range.nsRange, in: f.editor)
            t.check(f.editor.textRevision > revision, "revision advances before the typed-text debounce")
            t.check(settled(f), "the corrected text is checked")
            t.check(!checking.snapshot.diagnostics.contains { $0.id == .unknownModifier }, "actual typing removes DK3001")
            t.check(checking.snapshot.diagnostics.contains { $0.id == .fontNotInstalled }, "the independent font error remains")
            type(installed, replacing: (f.editor.text as NSString).range(of: missing), in: f.editor)
            t.check(settled(f), "the installed-family edit is checked")
            t.check(!checking.snapshot.diagnostics.contains { $0.id == .fontNotInstalled || $0.id == .windowsFont },
                    "the real installed provider result reaches this editor")
            t.equal(f.controller.window?.subtitle, f.file.deletingLastPathComponent().path, "a clear check restores the subtitle")
            t.equal(try Data(contentsOf: f.file), original, "checking and typing do not save through a skin session")
            t.check(f.editor.commitNow(explicit: true), "the existing commit path saves")
            t.equal(try Data(contentsOf: f.file), Data(f.editor.text.utf8), "UTF8/BOM/CRLF save without double BOM or conversion")
            t.equal(f.app.sortedControllers.count, 0, "editing did not activate or reload a widget")
        }
    }

    private static func resourceLanguageTests(_ t: AppTestRunner) {
        t.suite("Desk: document checking: image failures retain the checked document language across queued work") {
            let oldLanguage = StudioText.languageOverride
            defer { StudioText.languageOverride = oldLanguage }
            let name = "missing%2F图片😀.png"
            let source = "widget { Image(\"\(name)\").size(48, 40) }"
            for language in StudioLanguage.allCases {
                StudioText.languageOverride = language
                let queue = DispatchQueue(label: "desk.document.test.resource-language")
                queue.suspend()
                var suspended = true
                defer { if suspended { queue.resume() } }
                let f = try fixture(t, data: Data(source.utf8), queue: queue)
                guard let checking = f.controller.deskChecking, let preview = f.controller.deskPreview else {
                    return t.check(false, "the real document has its checker and preview")
                }
                t.check(checking.snapshot.isChecked)
                if case .pending = checking.imageResources(for: checking.snapshot) {} else {
                    return t.check(false, "the suspended queue must retain real pending image work")
                }
                // The queued task must use the language captured with its checked source, even if the UI changes.
                StudioText.languageOverride = language == .chinese ? .english : .chinese
                queue.resume(); suspended = false
                var failure: String?
                let completed = AppSelfTest.spin(timeout: 10) {
                    if case .failed(let message) = checking.imageResources(for: checking.snapshot) {
                        failure = message
                        return true
                    }
                    return false
                }
                guard completed, let failure else { return t.check(false, "the actual background resource failure was not delivered") }
                let prefix = language == .chinese ? "无法读取小组件文件夹内的图片文件：" : "Cannot read a regular image in the widget folder: "
                t.equal(failure, prefix + name, "CJK, emoji and percent sequences remain literal path text")
                t.equal(preview.state, .unavailable(failure), "the preview displays the resource failure without replacing it")
                t.check(preview.scene == nil && preview.canvas.isHidden)
                t.equal(try Data(contentsOf: f.file), Data(source.utf8))
                t.equal(f.app.sortedControllers.count, 0)

                let brokenName = "broken%25图片.png"
                let root = f.file.deletingLastPathComponent()
                try Data("not an image".utf8).write(to: root.appendingPathComponent(brokenName))
                let inputs = DeskProgramResources.prepare(root: root, literals: [brokenName], maximumBytes: 1_024,
                                                          maximumFiles: 1, language: language)
                defer { inputs.removeCopies() }
                let invalidPrefix = language == .chinese ? "图片过大或无法解码：" : "Image is too large or cannot be decoded: "
                t.equal(inputs.failure, invalidPrefix + brokenName)
                t.check(inputs.images.isEmpty && inputs.folder == nil, "localization does not publish partial inputs")
            }
        }
    }

    private static func encodingTests(_ t: AppTestRunner) {
        t.suite("Desk: document checking: initial strict load rejects invalid UTF8 and UTF16 without writing") {
            let owner = app(t)
            let root = t.temporaryDirectory("desk-encoding")
            for (name, bytes) in [("Truncated.desk", Data([0xC3])),
                                  ("UTF16.desk", Data([0xFF, 0xFE, 0x41, 0])),
                                  ("ANSI.desk", Data([0xE9]))] {
                let file = root.appendingPathComponent(name)
                try bytes.write(to: file)
                do {
                    _ = try CodeFileWindowController(file: file, app: owner)
                    t.check(false, "\(name) should fail the actual window open")
                } catch let failure as DeskCodeDocumentChecking.ReadFailure {
                    t.equal(failure.diagnostic.id, .invalidEncoding, name)
                    t.check(failure.localizedDescription.contains("DK1008"), "the existing failure path gets a concrete error")
                }
                t.equal(try Data(contentsOf: file), bytes, "rejected raw data is untouched")
            }
            let ini = root.appendingPathComponent("Legacy.ini")
            try Data([0xFF, 0xFE, 0x41, 0]).write(to: ini)
            let legacy = try CodeFileWindowController(file: ini, app: owner)
            defer { legacy.window?.close() }
            t.equal(legacy.codeView.text, "A", "the non-Desk decoder still accepts the original skin encoding")
            t.equal(legacy.codeView.document(for: ini)?.encoding, .utf16LittleEndian(bom: true))
            t.check(legacy.deskChecking == nil, "the non-Desk window has no Desk checker")
            let empty = root.appendingPathComponent("Empty.desk")
            try Data().write(to: empty)
            let blank = try CodeFileWindowController(file: empty, app: owner)
            defer { blank.window?.close() }
            t.check(blank.deskChecking?.snapshot.diagnostics.contains { $0.id == .missingWidget } == true,
                    "valid empty UTF8 is checked as an incomplete document, not an equal-success placeholder")
            let blankError = blank.deskChecking?.snapshot.diagnostics.first(where: \.isProblem)
            t.check(blankError != nil && blank.window?.subtitle == blankError?.message,
                    "the actual empty document displays its checker error")
            t.equal(owner.sortedControllers.count, 0)
        }
    }

    private static func reloadTests(_ t: AppTestRunner) {
        t.suite("Desk: document checking: reload and take-disk reject bytes while retaining edits and undo") {
            let original = "info { name: \"Reload\" }\nwidget { Text(\"A\") }\n"
            let f = try fixture(t, data: Data(original.utf8))
            let sibling = f.file.deletingLastPathComponent().appendingPathComponent("package.desk")
            try Data([0xFF]).write(to: sibling)
            var reads: [URL] = []
            f.editor.readData = { url in reads.append(url); return try Data(contentsOf: url) }
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.check(reads.allSatisfy { $0 == f.file } && !reads.isEmpty, "a recheck reads only the explicitly opened file")
            t.equal(f.controller.deskChecking?.snapshot.folder.keys.sorted { $0.path < $1.path }, [DeskFileID("Widget.desk")],
                    "the invalid sibling was not turned into folder input")
            type("// typed\n", replacing: NSRange(location: 0, length: 0), in: f.editor)
            let typed = f.editor.text
            let revision = f.editor.textRevision
            let undo = f.editor.textView.undoManager
            t.check(undo?.canUndo == true, "a real text edit is undoable")
            let invalid = Data([0xFF, 0xFE, 0x41, 0])
            try invalid.write(to: f.file)
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.equal(f.editor.text, typed, "invalid reload retains the typed text")
            t.equal(f.editor.textRevision, revision, "a rejected load is not a text edit")
            t.check(f.editor.isDirty && undo?.canUndo == true, "dirty and undo survive rejection")
            t.check(f.controller.readError?.contains("DK1008") == true, "the rejection is displayed through the existing subtitle")
            t.equal(f.controller.window?.subtitle, f.controller.readError)
            f.editor.onDiskConflict = { _ in .takeDisk }
            t.check(!f.editor.commitNow(explicit: true), "take-disk cannot adopt invalid bytes")
            t.equal(f.editor.text, typed)
            t.check(f.editor.isDirty && undo?.canUndo == true, "failed adoption preserves both safeguards")
            t.equal(try Data(contentsOf: f.file), invalid, "failed adoption did not replace the raw disk data")
            try Data(original.utf8).write(to: f.file)
            undo?.undo()
            t.equal(f.editor.text, original, "the original typing undo still works")
            t.check(!f.editor.isDirty)
            let changed = "info { name: \"Reload\" }\nwidget { Text(\"B😀\") }\n"
            try Data(changed.utf8).write(to: f.file)
            f.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            t.check(settled(f), "a subsequent valid clean reload reaches the checker")
            t.equal(f.editor.text, changed)
            t.check(f.controller.readError == nil && !f.editor.isDirty)
            t.equal(f.app.sortedControllers.count, 0)
        }
    }

    private static func staleTests(_ t: AppTestRunner) {
        t.suite("Desk: document checking: immediate revisions and service generations reject actual stale snapshots") {
            let text = "info { name: \"Versions\" }\nwidget { Text(\"A\").colr(.red) }\n"
            let f = try fixture(t, data: Data(text.utf8))
            guard let checking = f.controller.deskChecking else { return t.check(false, "the window has a checker") }
            let old = checking.snapshot
            let hook = f.editor.onTextRevision
            // A delayed host has not told the service yet: its generation is still old, but the editor's revision is not.
            f.editor.onTextRevision = nil
            type(" ", replacing: NSRange(location: 0, length: 0), in: f.editor)
            t.check(!checking.publish(old), "the immediate editor revision rejects a service-current old result")
            f.editor.onTextRevision = hook
            checking.recheck()
            t.check(settled(f))
            let beforeRecheck = checking.snapshot
            checking.recheck()
            t.check(settled(f))
            t.equal(checking.snapshot.version, beforeRecheck.version, "an unchanged recheck keeps the editor revision")
            t.check(checking.snapshot.generation != beforeRecheck.generation, "the actual service publication has a new generation")
            t.check(!checking.publish(beforeRecheck), "generation rejects an old result of the same text and revision")
            let other = f.file.deletingLastPathComponent().appendingPathComponent("Other.desk")
            try Data(text.utf8).write(to: other)
            let current = checking.snapshot
            try f.editor.open(files: [other], current: other)
            t.check(!checking.publish(current), "a snapshot never publishes into a different open file")
            checking.close()
            t.check(!checking.publish(current), "a closed session cannot publish")
        }

        t.suite("Desk: document checking: queued old checks and closing never replace the latest editor result") {
            let queue = DispatchQueue(label: "desk.document.test.ordered-checks")
            queue.suspend()
            var suspended = true
            defer { if suspended { queue.resume() } }
            let text = "info { name: \"Async\" }\nwidget { Text(\"A\").colr(.red) }\n//" + String(repeating: "x", count: 9_000) + "\n"
            let f = try fixture(t, data: Data(text.utf8), queue: queue)
            guard let checking = f.controller.deskChecking else { return t.check(false, "the window has a checker") }
            var delivered: [Int] = []
            let consumer = checking.onSnapshot
            checking.onSnapshot = { snapshot in delivered.append(snapshot.version); consumer?(snapshot) }
            type("color", replacing: (f.editor.text as NSString).range(of: "colr"), in: f.editor)
            let first = checking.snapshot
            t.check(!first.isChecked, "the suspended queue exposes real pending syntax")
            type("colr", replacing: (f.editor.text as NSString).range(of: "color"), in: f.editor)
            let latestVersion = f.editor.textRevision
            t.check(!checking.publish(first), "the fixed previous editor version is rejected")
            queue.resume()
            suspended = false
            t.check(settled(f), "the latest queued check completes through the real service")
            t.equal(checking.snapshot.version, latestVersion)
            t.check(checking.snapshot.diagnostics.contains { $0.id == .unknownModifier }, "the latest error remains, not the older corrected text")
            let final = checking.snapshot
            t.equal(f.controller.window?.subtitle, final.diagnostics.first(where: \.isProblem)?.message,
                    "the actual window consumed the latest finished check")
            queue.suspend()
            suspended = true
            type(" ", replacing: NSRange(location: 0, length: 0), in: f.editor)
            f.controller.window?.close()
            let countAtClose = delivered.count
            queue.resume()
            suspended = false
            var drained = false
            queue.async { DispatchQueue.main.async { drained = true } }
            t.check(AppSelfTest.spin(timeout: 10) { drained }, "the queued checks and their main-queue deliveries drained")
            t.equal(delivered.count, countAtClose, "closing disconnected the real window consumer")
            t.check(!checking.publish(final))
            t.equal(f.app.sortedControllers.count, 0)
        }
    }
}
