import AppKit
import DesksetCore

enum MetadataEditingSelfTests {
    static func run(_ t: AppTestRunner) {
        modelTests(t)
        manageWindowTests(t)
        singleFileReloadTests(t)
        editorPreflightTests(t)
        studioSessionTests(t)
    }

    private struct Fixture {
        let app: AppController
        let root: URL
        let skins: URL

        func skinFile(_ relativePath: String,
                      text: String = "[Rainmeter]\nUpdate=1000\n\n[Meter]\nMeter=String\nText=Hello\n") throws -> URL {
            let url = skins.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        func openCodeWindow(_ file: URL) throws -> CodeFileWindowController {
            guard app.showCodeFile(file, line: nil), let editor = app.codeFileWindows.last else {
                throw CocoaError(.fileReadUnknown)
            }
            MetadataEditingSelfTests.slowTimers(editor.codeView)
            return editor
        }
    }

    private static func makeFixture(_ t: AppTestRunner) throws -> Fixture {
        let root = t.temporaryDirectory("metadata-editing")
        let skins = root.appendingPathComponent("Skins")
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: skins, layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false,
                                system: NetworkStatisticsRuntimeSelfTests.TestSystem())
        t.atSuiteEnd {
            if let studio = StudioWindowController.window(for: app) {
                studio.codeView.onCommit = nil
                studio.codeView.onEncodingConversion = nil
                studio.codeView.onDiskConflict = nil
                studio.codeView.discardUncommittedChanges()
                studio.closeChoice = { .discard }
                _ = try? studio.session?.diskSync.flush()
                studio.window?.close()
            }
            for editor in app.codeFileWindows {
                editor.codeView.onCommit = nil
                editor.codeView.onEncodingConversion = nil
                editor.codeView.onDiskConflict = nil
                editor.codeView.discardUncommittedChanges()
                editor.closeChoice = { .discard }
                editor.window?.close()
            }
            app.stopAllForTermination()
        }
        return Fixture(app: app, root: root, skins: skins)
    }

    private static func slowTimers(_ editor: CodeEditorView) {
        editor.idleCommitDelay = 60
        editor.typedTextDelay = 60
        editor.caretRestDelay = 60
    }

    private static func save(_ editor: CodeEditorView, file: URL, text: String) -> Bool {
        guard let bytes = editor.document(for: file)?.data(for: text) else { return false }
        do { try bytes.write(to: file, options: .atomic); return true } catch { return false }
    }

    private static func expectThrows(_ t: AppTestRunner, _ message: String = "",
                                     line: UInt = #line,
                                     _ body: () throws -> Void) {
        do {
            try body()
            t.check(false, message.isEmpty ? "expected error" : message, line: line)
        } catch {
            t.check(true, message, line: line)
        }
    }

    // MARK: ManageModel

    private static func modelTests(_ t: AppTestRunner) {
        t.suite("App: Metadata: ManageModel.hasMetadataSection classification") {
            let dir = t.temporaryDirectory("metadata-model")
            let missing = dir.appendingPathComponent("Missing.ini")
            t.equal(ManageModel.hasMetadataSection(missing), nil)
            t.equal(ManageModel.hasMetadataSection(dir), nil)

            let absent = dir.appendingPathComponent("Absent.ini")
            try Data(";[Metadata]\n[Rainmeter]\nUpdate=1000\n".utf8).write(to: absent)
            t.equal(ManageModel.hasMetadataSection(absent), false)

            let emptySection = dir.appendingPathComponent("EmptySection.ini")
            try Data("[Rainmeter]\nUpdate=1000\n\n[Metadata]\nName=\n".utf8).write(to: emptySection)
            t.equal(ManageModel.hasMetadataSection(emptySection), true)
            t.equal(ManageModel.readMetadata(emptySection)["Name"], "")
            t.equal(ManageModel.metadataValue(ManageModel.readMetadata(emptySection), "Name"), nil)

            let lower = dir.appendingPathComponent("Lower.ini")
            try Data("[metadata]\n".utf8).write(to: lower)
            t.equal(ManageModel.hasMetadataSection(lower), true)

            let link = dir.appendingPathComponent("Link.ini")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: absent)
            t.equal(ManageModel.hasMetadataSection(link), false)

            let oversized = dir.appendingPathComponent("Oversized.ini")
            let big = Data(repeating: UInt8(ascii: "A"), count: ManageModel.maxMetadataFileSize + 1)
            try big.write(to: oversized)
            t.equal(ManageModel.hasMetadataSection(oversized), nil)
        }
    }

    // MARK: ManageWindowController

    private static func manageWindowTests(_ t: AppTestRunner) {
        t.suite("App: Metadata: Manage window empty states and Add metadata action") {
            let f = try makeFixture(t)
            let noMetaURL = try f.skinFile("Suite/Alpha/NoMeta.ini", text: "[Rainmeter]\nUpdate=-1\n[Meter]\nMeter=String\n")
            _ = try f.skinFile("Suite/Alpha/EmptyMeta.ini",
                               text: "[Rainmeter]\nUpdate=-1\n[Metadata]\nName=\nAuthor=\n")
            _ = try f.skinFile("Suite/Alpha/NamedOnly.ini",
                               text: "[Rainmeter]\nUpdate=-1\n[Metadata]\nName=Custom Title\n")
            _ = try f.skinFile("Suite/Alpha/FullMeta.ini",
                               text: "[Rainmeter]\nUpdate=-1\n[Metadata]\nAuthor=Ada\nVersion=1.0\n")
            let bigURL = try f.skinFile("Suite/Alpha/Big.ini")
            try Data(repeating: UInt8(ascii: ";"), count: ManageModel.maxMetadataFileSize + 16).write(to: bigURL)

            f.app.rescanLibrary()
            let manage = ManageWindowController(app: f.app)
            defer { manage.close() }

            // Folder-only node selection has no Add metadata button.
            manage.select(config: "Suite", file: nil)
            t.equal(manage.testMetadataEmptyText, "Contains 0 skins.")
            t.check(manage.testAddMetadataButton == nil)

            // File without [Metadata] shows the link button.
            manage.select(config: "Suite\\Alpha", file: "NoMeta.ini")
            t.equal(manage.testMetadataEmptyText, "This skin has no [Metadata] section.")
            guard let button = manage.testAddMetadataButton else {
                return t.check(false, "Add metadata button is shown when [Metadata] is absent")
            }
            t.equal(button.title, "Add metadata")
            t.equal(button.accessibilityLabel(), "Add metadata")

            // Empty [Metadata] section hides the button and shows "This skin has no metadata values."
            manage.select(config: "Suite\\Alpha", file: "EmptyMeta.ini")
            t.equal(manage.testMetadataEmptyText, "This skin has no metadata values.")
            t.check(manage.testAddMetadataButton == nil)

            // [Metadata] with only Name= sets the header title and shows "This skin has no metadata values."
            manage.select(config: "Suite\\Alpha", file: "NamedOnly.ini")
            t.equal(manage.testTitle, "Custom Title")
            t.equal(manage.testMetadataEmptyText, "This skin has no metadata values.")
            t.check(manage.testAddMetadataButton == nil)

            // Populated [Metadata] shows rows and no empty label or button.
            manage.select(config: "Suite\\Alpha", file: "FullMeta.ini")
            t.check(manage.testMetadataEmptyText == nil)
            t.check(manage.testAddMetadataButton == nil)

            // Oversized file shows "No metadata available." and no button.
            manage.select(config: "Suite\\Alpha", file: "Big.ini")
            t.equal(manage.testMetadataEmptyText, "No metadata available.")
            t.check(manage.testAddMetadataButton == nil)

            // Clicking Add metadata on a loaded skin inserts [Metadata], hides the button, and neither opens an editor
            // nor refreshes the running skin.
            guard let running = f.app.activate(config: "Suite\\Alpha", file: "NoMeta.ini") else {
                return t.check(false, "loaded Suite\\Alpha\\NoMeta.ini")
            }
            manage.select(config: "Suite\\Alpha", file: "NoMeta.ini")
            guard let activeButton = manage.testAddMetadataButton else {
                return t.check(false, "loaded skin without [Metadata] still offers Add metadata")
            }
            activeButton.performClick(nil)
            t.check(manage.testAddMetadataButton == nil, "button disappears after adding [Metadata]")
            t.equal(manage.testMetadataEmptyText, "This skin has no metadata values.")
            t.equal(f.app.codeFileWindows.count, 0, "Add metadata does not open an editor window")
            t.check(StudioWindowController.window(for: f.app) == nil, "Add metadata does not open Studio")
            t.check(f.app.controller(for: "Suite\\Alpha") === running, "Add metadata does not reload the active skin")
            let doc = IniDocument.parse(try TextDecoding.readFile(at: noMetaURL))
            t.equal(doc.section(named: "Metadata")?.keys, IniWriter.metadataKeys)
        }

        // A skin's metadata rows have two columns; a folder's one-cell row must not keep the second one, empty and
        // zero wide, or layout squeezes the window below its minimum size (after installing a package, Manage
        // selects its root folder) and `keepMinimumSize` loops with it until AppKit raises an exception.
        t.suite("App: Metadata: a folder after a skin leaves no empty metadata column") {
            let f = try makeFixture(t)
            _ = try f.skinFile("Suite/Alpha/FullMeta.ini",
                               text: "[Rainmeter]\nUpdate=-1\n[Metadata]\nAuthor=Ada\nVersion=1.0\n")
            _ = try f.skinFile("Suite/Alpha/NoMeta.ini", text: "[Rainmeter]\nUpdate=-1\n[Meter]\nMeter=String\n")
            f.app.rescanLibrary()
            let manage = ManageWindowController(app: f.app)
            defer { manage.close() }
            guard let window = manage.window else { return t.check(false, "Manage has a window") }

            for (config, file, columns) in [("Suite\\Alpha", "FullMeta.ini", 2), ("Suite", nil, 1),
                                            ("Suite\\Alpha", "FullMeta.ini", 2), ("Suite\\Alpha", "NoMeta.ini", 1)] {
                manage.select(config: config, file: file)
                t.equal(manage.testMetadataColumns, columns, "\(config) \(file ?? "(folder)")")
                window.layoutIfNeeded()
                t.check(window.frame.width >= window.minSize.width,
                        "\(config) \(file ?? "(folder)"): window keeps its minimum width (\(window.frame.width))")
            }
        }

        t.suite("App: Metadata: button captures target fileURL and alerts on failure") {
            let f = try makeFixture(t)
            let firstURL = try f.skinFile("Beta/First.ini", text: "[Rainmeter]\nUpdate=-1\n")
            let secondURL = try f.skinFile("Beta/Second.ini", text: "[Rainmeter]\nUpdate=-1\n")
            f.app.rescanLibrary()
            let manage = ManageWindowController(app: f.app)
            defer { manage.close() }

            manage.select(config: "Beta", file: "First.ini")
            guard let capturedButton = manage.testAddMetadataButton else {
                return t.check(false, "First.ini has Add metadata button")
            }
            // Select Second.ini before sending the captured button's action: First.ini must be updated, not Second.ini.
            manage.select(config: "Beta", file: "Second.ini")
            t.check(NSApp.sendAction(capturedButton.action!, to: capturedButton.target, from: capturedButton))
            t.equal(ManageModel.hasMetadataSection(firstURL), true, "captured First.ini received [Metadata]")
            t.equal(ManageModel.hasMetadataSection(secondURL), false, "newly selected Second.ini was not touched")

            // If a file is deleted before clicking its button, Manage reports the error through app.alert.
            manage.select(config: "Beta", file: "Second.ini")
            guard let missingButton = manage.testAddMetadataButton else {
                return t.check(false, "Second.ini has Add metadata button")
            }
            try FileManager.default.removeItem(at: secondURL)
            missingButton.performClick(nil)
            t.equal(f.app.lastAlert?.title, "Could not add metadata")
            t.equal(manage.testMetadataEmptyText, "No metadata available.")
            t.check(manage.testAddMetadataButton == nil)
        }
    }

    // MARK: CodeEditorView single-file reload

    private static func singleFileReloadTests(_ t: AppTestRunner) {
        t.suite("App: Metadata: reloadFromDisk(only:) reloads only the targeted buffer") {
            let cf = try CodeEditorSelfTests.makeFixture(t)
            let editor = cf.editor
            slowTimers(editor)

            // Open a third clean file alongside main and include.
            let extra = cf.main.deletingLastPathComponent().appendingPathComponent("Extra.inc").standardizedFileURL
            try Data("[Variables]\nExtra=1\n".utf8).write(to: extra)
            _ = try editor.open(files: [cf.main, cf.include, extra], current: cf.include)

            // Make include dirty and keep it dirty when switching back to main.
            cf.recorder.accept = false
            let includeBaseDoc = editor.document(for: cf.include)?.text
            CodeEditorSelfTests.type(editor, "; dirty include\n", at: 0)
            let includeDirtyText = editor.text
            t.check(editor.isDirty(cf.include))
            editor.show(file: cf.main)
            t.check(editor.isDirty(cf.include))

            // Modify all three files on disk, then reload ONLY main.
            let updatedMain = CodeEditorSelfTests.mainText + "\r\n[Metadata]\r\nName=\r\n"
            try Data(updatedMain.utf8).write(to: cf.main)
            try Data("[Variables]\nSize=999\n".utf8).write(to: cf.include)
            try Data("[Variables]\nExtra=2\n".utf8).write(to: extra)

            editor.reloadFromDisk(keepCaret: true, only: SourceFileID(cf.main))

            t.equal(editor.text, updatedMain, "targeted main file reloaded")
            t.equal(editor.document(for: cf.include)?.text, includeBaseDoc, "dirty include base document untouched")
            t.equal(editor.document(for: extra)?.text, "[Variables]\nExtra=1\n", "unrelated clean buffer untouched")
            editor.show(file: cf.include)
            t.equal(editor.text, includeDirtyText, "dirty include text untouched")
            t.check(editor.isDirty(cf.include))
        }
    }

    // MARK: CodeFileWindowController preflight & sync

    private static func editorPreflightTests(_ t: AppTestRunner) {
        t.suite("App: Metadata: clean and dirty CodeFileWindow synchronize without losing edits") {
            let f = try makeFixture(t)
            let file = try f.skinFile("Sync/Skin.ini")
            let editor = try f.openCodeWindow(file)

            // Clean open editor adopts [Metadata] and stays open and clean.
            t.equal(try MetadataEditing.addIfMissing(to: file, app: f.app), true)
            t.equal(f.app.codeFileWindows.count, 1)
            t.check(!editor.codeView.hasUncommittedChanges)
            t.equal(IniDocument.parse(editor.codeView.text).section(named: "Metadata")?.keys, IniWriter.metadataKeys)

            // Typing and committing afterwards keeps [Metadata] on disk.
            CodeEditorSelfTests.type(editor.codeView, "; after metadata\n", at: 0)
            t.check(editor.codeView.commitNow(explicit: true))
            let afterText = try TextDecoding.readFile(at: file)
            t.check(afterText.hasPrefix("; after metadata\n"))
            t.equal(IniDocument.parse(afterText).section(named: "Metadata")?.keys, IniWriter.metadataKeys)

            // Dirty open editor commits first, then receives [Metadata], keeping both edits.
            let second = try f.skinFile("Sync/Second.ini")
            let secondEditor = try f.openCodeWindow(second)
            CodeEditorSelfTests.type(secondEditor.codeView, "; unsaved header\n", at: 0)
            t.check(secondEditor.codeView.hasUncommittedChanges)
            t.equal(try MetadataEditing.addIfMissing(to: second, app: f.app), true)
            t.check(!secondEditor.codeView.hasUncommittedChanges)
            t.check(secondEditor.codeView.text.hasPrefix("; unsaved header\n"))
            t.equal(IniDocument.parse(secondEditor.codeView.text).section(named: "Metadata")?.keys,
                    IniWriter.metadataKeys)
            t.equal(try TextDecoding.readFile(at: second), secondEditor.codeView.text)
        }

        t.suite("App: Metadata: declined conversion, disk conflict, or failed save aborts before mutation") {
            let oldPage = TextDecoding.ansiCodePage
            TextDecoding.ansiCodePage = 1252
            defer { TextDecoding.ansiCodePage = oldPage }

            let f = try makeFixture(t)

            // 1. Declined encoding conversion
            let ansiBytes = CodeEditorSelfTests.ansiInclude
            let ansiFile = try f.skinFile("Abort/ANSI.ini")
            try ansiBytes.write(to: ansiFile)
            let ansiEditor = try f.openCodeWindow(ansiFile)
            ansiEditor.codeView.onEncodingConversion = { _, _ in false }
            CodeEditorSelfTests.type(ansiEditor.codeView, "日", at: 0)
            expectThrows(t) { _ = try MetadataEditing.addIfMissing(to: ansiFile, app: f.app) }
            t.equal(try Data(contentsOf: ansiFile), ansiBytes, "declined conversion leaves file untouched")
            t.check(ansiEditor.codeView.hasUncommittedChanges)

            // 2. Unresolved disk conflict (.decideLater)
            let conflictFile = try f.skinFile("Abort/Conflict.ini")
            let conflictEditor = try f.openCodeWindow(conflictFile)
            CodeEditorSelfTests.type(conflictEditor.codeView, "; local\n", at: 0)
            let diskBytes = Data("; external edit\n[Rainmeter]\nUpdate=1000\n".utf8)
            try diskBytes.write(to: conflictFile, options: .atomic)
            conflictEditor.codeView.onDiskConflict = { _ in .decideLater }
            expectThrows(t) { _ = try MetadataEditing.addIfMissing(to: conflictFile, app: f.app) }
            t.equal(try Data(contentsOf: conflictFile), diskBytes, "decideLater leaves disk bytes without [Metadata]")
            t.check(conflictEditor.codeView.hasUncommittedChanges)

            // 3. .takeDisk where disk already gained [Metadata] returns false and syncs editor
            let diskWithMeta = Data("[Rainmeter]\nUpdate=1000\n\n[Metadata]\nName=FromDisk\n".utf8)
            try diskWithMeta.write(to: conflictFile, options: .atomic)
            conflictEditor.codeView.onDiskConflict = { _ in .takeDisk }
            t.equal(try MetadataEditing.addIfMissing(to: conflictFile, app: f.app), false)
            t.check(!conflictEditor.codeView.hasUncommittedChanges)
            t.equal(IniDocument.parse(conflictEditor.codeView.text).section(named: "Metadata")?["Name"], "FromDisk")

            // 4. Failed commit
            let failFile = try f.skinFile("Abort/FailCommit.ini")
            let failInitial = try Data(contentsOf: failFile)
            let failEditor = try f.openCodeWindow(failFile)
            CodeEditorSelfTests.type(failEditor.codeView, "; unsaved\n", at: 0)
            failEditor.codeView.onCommit = { _, _ in false }
            expectThrows(t) { _ = try MetadataEditing.addIfMissing(to: failFile, app: f.app) }
            t.equal(try Data(contentsOf: failFile), failInitial, "failed commit prevents [Metadata] write")
        }

        t.suite("App: Metadata: reentry, new editor registration, and mid-preflight dirtying abort safely") {
            let f = try makeFixture(t)

            // 1. Reentrant request inside onCommit
            let reentrantFile = try f.skinFile("Reentry/One.ini")
            let reentrantEditor = try f.openCodeWindow(reentrantFile)
            CodeEditorSelfTests.type(reentrantEditor.codeView, "; saved\n", at: 0)
            var innerErrors = 0
            reentrantEditor.codeView.onCommit = { url, text in
                do {
                    _ = try MetadataEditing.addIfMissing(to: reentrantFile, app: f.app)
                } catch {
                    innerErrors += 1
                }
                return save(reentrantEditor.codeView, file: url, text: text)
            }
            expectThrows(t) { _ = try MetadataEditing.addIfMissing(to: reentrantFile, app: f.app) }
            t.equal(innerErrors, 1)
            t.equal(ManageModel.hasMetadataSection(reentrantFile), false, "outer request aborted before adding [Metadata]")
            reentrantEditor.codeView.onCommit = { url, text in save(reentrantEditor.codeView, file: url, text: text) }
            t.equal(try MetadataEditing.addIfMissing(to: reentrantFile, app: f.app), true, "subsequent request succeeds")

            // 2. New editor window registered during onCommit
            let regFile = try f.skinFile("Reentry/Two.ini")
            let otherFile = try f.skinFile("Reentry/Other.ini")
            let regEditor = try f.openCodeWindow(regFile)
            CodeEditorSelfTests.type(regEditor.codeView, "; saved\n", at: 0)
            regEditor.codeView.onCommit = { url, text in
                t.check(f.app.showCodeFile(otherFile, line: nil))
                return save(regEditor.codeView, file: url, text: text)
            }
            expectThrows(t) { _ = try MetadataEditing.addIfMissing(to: regFile, app: f.app) }
            t.equal(ManageModel.hasMetadataSection(regFile), false, "new editor registration aborts mutation")

            // 3. Previously approved Studio buffer becoming dirty during a file window's onCommit aborts mutation
            let dualFile = try f.skinFile("Reentry/Three.ini",
                                          text: "[Rainmeter]\nUpdate=1000\n[Meter]\nMeter=String\nText=Hi\n")
            f.app.rescanLibrary()
            guard let dualSkin = f.app.activate(config: "Reentry", file: "Three.ini") else {
                return t.check(false, "activated Reentry\\Three.ini")
            }
            f.app.showInspector(for: dualSkin)
            guard let studio = StudioWindowController.window(for: f.app) else {
                return t.check(false, "opened Studio for Reentry\\Three.ini")
            }
            slowTimers(studio.codeView)
            let fileWindow = try f.openCodeWindow(dualFile)
            CodeEditorSelfTests.type(fileWindow.codeView, "; file window saves\n", at: 0)
            fileWindow.codeView.onCommit = { url, text in
                CodeEditorSelfTests.type(studio.codeView, "; studio dirtied late\n", at: 0)
                return save(fileWindow.codeView, file: url, text: text)
            }
            expectThrows(t) { _ = try MetadataEditing.addIfMissing(to: dualFile, app: f.app) }
            t.equal(ManageModel.hasMetadataSection(dualFile), false, "late dirty Studio buffer aborts [Metadata] write")
            studio.codeView.discardUncommittedChanges()
            studio.closeChoice = { .discard }
            studio.window?.close()
        }
    }

    // MARK: StudioWindowController & EditingSession

    private static func studioSessionTests(_ t: AppTestRunner) {
        t.suite("App: Metadata: Studio and EditingSession adopt [Metadata] without refreshing or touching dirty includes") {
            let f = try makeFixture(t)
            let main = try f.skinFile("StudioSkin/Skin.ini",
                                      text: "[Rainmeter]\nUpdate=1000\n@Include=Vars.inc\n[Meter]\nMeter=String\nText=Hi\n")
            let include = try f.skinFile("StudioSkin/Vars.inc", text: "[Variables]\nColor=255,255,255\n")
            f.app.rescanLibrary()
            guard let skin = f.app.activate(config: "StudioSkin", file: "Skin.ini") else {
                return t.check(false, "activated StudioSkin")
            }
            f.app.showInspector(for: skin)
            guard let studio = StudioWindowController.window(for: f.app), let session = studio.session else {
                return t.check(false, "opened Studio")
            }
            slowTimers(studio.codeView)
            _ = try studio.codeView.open(files: [main, include], current: include)
            studio.codeView.onCommit = { url, text in save(studio.codeView, file: url, text: text) }
            CodeEditorSelfTests.type(studio.codeView, "; committed include edit\n", at: 0)
            let committedIncludeText = studio.codeView.text
            t.check(studio.codeView.commitNow(explicit: true))
            t.check(studio.codeView.textView.undoManager?.canUndo == true, "include has undo history")
            studio.codeView.show(file: main)

            // Externally change include on disk to verify single-file reload of main does not reload include or clear
            // include's undo history.
            try Data("[Variables]\nColor=0,0,0\n".utf8).write(to: include)

            // Queue a pending EditingSession buffer change on main before clicking Add metadata.
            let loaded = try session.buffers.load(main)
            let editedMain = loaded.text + "\n[Variables]\nFromSession=1\n"
            guard let change = SourceChange(file: SourceFileID(main), before: loaded.text, after: editedMain,
                                            encodingBefore: loaded.encoding, encodingAfter: loaded.encoding) else {
                return t.check(false, "constructed session SourceChange")
            }
            try session.buffers.apply([change])
            session.diskSync.idleDelay = 60
            session.diskSync.scheduleFlush()
            t.check(session.diskSync.hasUnwrittenChanges)

            t.equal(try MetadataEditing.addIfMissing(to: main, app: f.app), true)
            t.check(!session.diskSync.hasUnwrittenChanges, "pending session changes were flushed")
            t.equal(session.diskSync.touchedOnDisk([main], marking: false), [],
                    "session diskDate adopted the metadata write so FSEvents will not trigger a reload")
            t.check(f.app.controller(for: "StudioSkin") === skin, "running skin was not reloaded")

            let diskText = try TextDecoding.readFile(at: main)
            let doc = IniDocument.parse(diskText)
            t.equal(doc.section(named: "Variables")?["FromSession"], "1")
            t.equal(doc.section(named: "Metadata")?.keys, IniWriter.metadataKeys)
            t.equal(studio.codeView.text, diskText, "Studio main buffer adopted the new disk text")
            t.equal(try session.buffers.load(main).text, diskText, "EditingSession buffer adopted the new disk text")

            // Unrelated include buffer in Studio was not reloaded from disk and kept its undo history.
            studio.codeView.show(file: include)
            t.equal(studio.codeView.text, committedIncludeText)
            t.check(studio.codeView.textView.undoManager?.canUndo == true, "include undo history preserved")

            // Even after Studio window closes, a retained EditingSession in app.studioSessions stays synchronized
            // when another variant in the same session has metadata added.
            studio.codeView.discardUncommittedChanges()
            studio.closeChoice = { .discard }
            studio.window?.close()
            let closedVariant = try f.skinFile("StudioSkin/Alt.ini", text: "[Rainmeter]\nUpdate=1000\n")
            _ = try session.buffers.load(closedVariant)
            t.equal(try MetadataEditing.addIfMissing(to: closedVariant, app: f.app), true)
            t.equal(IniDocument.parse(try session.buffers.load(closedVariant).text).section(named: "Metadata")?.keys,
                    IniWriter.metadataKeys)
            t.equal(session.diskSync.touchedOnDisk([closedVariant], marking: false), [])

            // A failing session.diskSync.flush() aborts before addMetadataIfMissing runs.
            let flushFailVariant = try f.skinFile("StudioSkin/FlushFail.ini", text: "[Rainmeter]\nUpdate=1000\n")
            let flushLoaded = try session.buffers.load(flushFailVariant)
            let flushAfter = flushLoaded.text + "; pending session edit\n"
            if let flushChange = SourceChange(file: SourceFileID(flushFailVariant), before: flushLoaded.text,
                                              after: flushAfter, encodingBefore: flushLoaded.encoding,
                                              encodingAfter: flushLoaded.encoding) {
                try session.buffers.apply([flushChange])
                session.diskSync.idleDelay = 60
                session.diskSync.scheduleFlush()
                try FileManager.default.removeItem(at: flushFailVariant)
                try FileManager.default.createDirectory(at: flushFailVariant, withIntermediateDirectories: false)
                expectThrows(t) { _ = try MetadataEditing.addIfMissing(to: flushFailVariant, app: f.app) }
                t.check(session.diskSync.hasUnwrittenChanges)
                try FileManager.default.removeItem(at: flushFailVariant)
                try Data(flushLoaded.text.utf8).write(to: flushFailVariant)
                try session.diskSync.flush()
            }
        }
    }
}
