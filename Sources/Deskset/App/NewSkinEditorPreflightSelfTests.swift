import AppKit
import DesksetCore

/// New Skin file operations must never leave an editor able to save to a removed path. All files, settings and close
/// decisions in these suites are temporary; no native alert or external editor is opened.
enum NewSkinEditorPreflightSelfTests {
    static func run(_ t: AppTestRunner) {
        matchingTests(t)
        closeChoiceTests(t)
        saveDecisionTests(t)
        reentryTests(t)
        retainedIncludeTests(t)
        sessionFlushTests(t)
    }

    private struct Fixture {
        let app: AppController
        let root: URL

        func file(_ path: String, bytes: Data = Data("[Variables]\nName=Original\n".utf8)) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url
        }

        func open(_ file: URL) throws -> CodeFileWindowController {
            guard app.showCodeFile(file, line: nil), let editor = app.codeFileWindows.last else {
                throw CocoaError(.fileReadUnknown)
            }
            NewSkinEditorPreflightSelfTests.slowTimers(editor.codeView)
            return editor
        }
    }

    private static func fixture(_ t: AppTestRunner) throws -> Fixture {
        let root = t.temporaryDirectory("new-skin-editors")
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
        return Fixture(app: app, root: root)
    }

    private static func slowTimers(_ editor: CodeEditorView) {
        editor.idleCommitDelay = 60
        editor.caretRestDelay = 60
    }

    private static func save(_ editor: CodeEditorView, file: URL, text: String) -> Bool {
        guard let bytes = editor.document(for: file)?.data(for: text) else { return false }
        do { try bytes.write(to: file, options: .atomic); return true } catch { return false }
    }

    private static func matchingTests(_ t: AppTestRunner) {
        t.suite("App: New Skin editors: directory boundaries and no late old-path save") {
            let f = try fixture(t)
            let first = try f.file("Target/A.ini"), nested = try f.file("Target/Sub/B.inc")
            let sibling = try f.file("TargetExtra/C.inc")
            let a = try f.open(first), b = try f.open(nested), other = try f.open(sibling)
            CodeEditorSelfTests.type(a.codeView, "; saved\n", at: 0)
            CodeEditorSelfTests.type(other.codeView, "; untouched\n", at: 0)
            let otherText = other.codeView.text
            let directory = first.deletingLastPathComponent()
            t.check(NewSkinEditorPreflight.closeEditors(affectedBy: directory, isDirectory: true, app: f.app))
            t.equal(f.app.codeFileWindows.map { ObjectIdentifier($0) }, [ObjectIdentifier(other)])
            t.check((try String(contentsOf: first, encoding: .utf8)).hasPrefix("; saved\n"))
            t.check(!a.codeView.hasUncommittedChanges && !b.codeView.hasUncommittedChanges)
            t.equal(other.codeView.text, otherText)
            t.check(other.codeView.hasUncommittedChanges, "an unrelated dirty editor is never committed or closed")
            try FileManager.default.moveItem(at: directory, to: f.root.appendingPathComponent("Renamed"))
            t.check(!a.codeView.fireIdleCommit() && !b.codeView.fireIdleCommit(), "no idle saves remain after preflight")
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            t.check(!FileManager.default.fileExists(atPath: directory.path), "closed editors never recreate the old folder")
            t.check(NewSkinEditorPreflight.closeEditors(affectedBy: first, isDirectory: false, app: f.app))
            t.equal(f.app.codeFileWindows.count, 1, "an absent target does not close a prefix neighbour")
        }

        t.suite("App: New Skin editors: file matching does not imply a directory prefix") {
            let f = try fixture(t)
            let first = try f.file("Files/One.ini"), second = try f.file("Files/One.ini.extra.inc")
            let a = try f.open(first), other = try f.open(second)
            t.check(NewSkinEditorPreflight.closeEditors(affectedBy: first, isDirectory: false, app: f.app))
            t.equal(f.app.codeFileWindows.map { ObjectIdentifier($0) }, [ObjectIdentifier(other)])
            t.check(!a.codeView.hasUncommittedChanges)
        }
    }

    private static func closeChoiceTests(_ t: AppTestRunner) {
        for choice in [CodeFileWindowController.CloseChoice.cancel, .discard, .save] {
            t.suite("App: New Skin editors: failed commit then \(choice)") {
                let f = try fixture(t)
                let file = try f.file("Created/Skin.ini")
                let bytes = try Data(contentsOf: file), editor = try f.open(file)
                CodeEditorSelfTests.type(editor.codeView, "; typed\n", at: 0)
                var commits = 0, decisions = 0
                editor.codeView.onCommit = { url, text in
                    commits += 1
                    return commits > 1 && save(editor.codeView, file: url, text: text)
                }
                editor.closeChoice = { decisions += 1; return choice }
                let closed = NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app)
                switch choice {
                case .cancel:
                    t.check(!closed)
                    t.equal(f.app.codeFileWindows.count, 1)
                    t.check(editor.codeView.hasUncommittedChanges)
                    t.equal(try Data(contentsOf: file), bytes)
                case .discard:
                    t.check(closed)
                    t.equal(f.app.codeFileWindows.count, 0)
                    t.check(!editor.codeView.hasUncommittedChanges)
                    t.equal(try Data(contentsOf: file), bytes)
                case .save:
                    t.check(closed)
                    t.equal(f.app.codeFileWindows.count, 0)
                    t.check(!editor.codeView.hasUncommittedChanges)
                    t.check((try String(contentsOf: file, encoding: .utf8)).hasPrefix("; typed\n"))
                }
                t.equal(decisions, 1)
            }
        }

        t.suite("App: New Skin editors: all approvals precede every close") {
            let f = try fixture(t)
            let first = try f.file("Created/One.ini"), second = try f.file("Created/Two.ini")
            let a = try f.open(first), b = try f.open(second)
            CodeEditorSelfTests.type(a.codeView, "; saved first\n", at: 0)
            CodeEditorSelfTests.type(b.codeView, "; refused second\n", at: 0)
            b.codeView.onCommit = { _, _ in false }
            b.closeChoice = { .cancel }
            t.check(!NewSkinEditorPreflight.closeEditors(affectedBy: first.deletingLastPathComponent(), isDirectory: true,
                                                         app: f.app))
            t.equal(f.app.codeFileWindows.count, 2, "Cancel keeps all the relevant editor windows open")
            t.check(!a.codeView.hasUncommittedChanges && b.codeView.hasUncommittedChanges)
            t.check((try String(contentsOf: first, encoding: .utf8)).hasPrefix("; saved first\n"))
        }
    }

    private static func saveDecisionTests(_ t: AppTestRunner) {
        t.suite("App: New Skin editors: declined conversion blocks file mutation") {
            let oldPage = TextDecoding.ansiCodePage
            TextDecoding.ansiCodePage = 1252
            defer { TextDecoding.ansiCodePage = oldPage }
            let f = try fixture(t)
            let bytes = CodeEditorSelfTests.ansiInclude
            let file = try f.file("Created/ANSI.inc", bytes: bytes), editor = try f.open(file)
            editor.codeView.onEncodingConversion = { _, _ in false }
            editor.closeChoice = { .cancel }
            CodeEditorSelfTests.type(editor.codeView, "日", at: 0)
            t.check(!NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app))
            t.equal(try Data(contentsOf: file), bytes)
            t.check(editor.codeView.hasUncommittedChanges)
            t.equal(f.app.codeFileWindows.count, 1)
        }

        t.suite("App: New Skin editors: unresolved disk conflict keeps the editor and file") {
            let f = try fixture(t)
            let file = try f.file("Created/Skin.ini"), editor = try f.open(file)
            CodeEditorSelfTests.type(editor.codeView, "; typed\n", at: 0)
            let external = Data("; external\n[Variables]\nName=Disk\n".utf8)
            try external.write(to: file, options: .atomic)
            editor.codeView.onDiskConflict = { _ in .decideLater }
            editor.closeChoice = { .cancel }
            t.check(!NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app))
            t.equal(try Data(contentsOf: file), external)
            t.check(editor.codeView.hasUncommittedChanges)
            editor.codeView.onDiskConflict = { _ in .takeDisk }
            t.check(NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app))
            t.equal(try Data(contentsOf: file), external)
            t.equal(f.app.codeFileWindows.count, 0)
        }
    }

    private static func reentryTests(_ t: AppTestRunner) {
        t.suite("App: New Skin editors: a nested request invalidates the outer request") {
            let f = try fixture(t)
            let file = try f.file("Created/Skin.ini"), editor = try f.open(file)
            CodeEditorSelfTests.type(editor.codeView, "; saved\n", at: 0)
            var nested: [Bool] = []
            editor.codeView.onCommit = { url, text in
                nested.append(NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app))
                return save(editor.codeView, file: url, text: text)
            }
            t.check(!NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app))
            t.equal(nested, [false])
            t.equal(f.app.codeFileWindows.count, 1)
            t.check(!editor.codeView.hasUncommittedChanges)
            t.check(NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app),
                    "a later request starts a fresh preflight")
        }

        t.suite("App: New Skin editors: new registrations during Save abort the operation") {
            let f = try fixture(t)
            let file = try f.file("Created/Skin.ini"), other = try f.file("Other/Settings.inc")
            let editor = try f.open(file)
            CodeEditorSelfTests.type(editor.codeView, "; saved\n", at: 0)
            editor.codeView.onCommit = { url, text in
                t.check(f.app.showCodeFile(other, line: nil))
                return save(editor.codeView, file: url, text: text)
            }
            t.check(!NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app))
            t.equal(f.app.codeFileWindows.count, 2)
            t.check(f.app.codeFileWindows.first === editor)
        }

        t.suite("App: New Skin editors: a previously approved buffer becoming dirty aborts all closes") {
            let f = try fixture(t)
            let first = try f.file("Created/One.ini"), second = try f.file("Created/Two.ini")
            let a = try f.open(first), b = try f.open(second)
            CodeEditorSelfTests.type(b.codeView, "; saved second\n", at: 0)
            b.codeView.onCommit = { url, text in
                CodeEditorSelfTests.type(a.codeView, "; later first\n", at: 0)
                return save(b.codeView, file: url, text: text)
            }
            t.check(!NewSkinEditorPreflight.closeEditors(affectedBy: first.deletingLastPathComponent(), isDirectory: true,
                                                         app: f.app))
            t.equal(f.app.codeFileWindows.count, 2)
            t.check(a.codeView.hasUncommittedChanges)
        }
    }

    private static func openStudio(_ f: Fixture, _ t: AppTestRunner) throws -> (StudioWindowController, URL)? {
        let file = try f.file("Skins/Created/Skin.ini", bytes: Data("[Rainmeter]\nUpdate=1000\n\n[Meter]\nMeter=String\nText=Hello\n".utf8))
        f.app.rescanLibrary()
        guard let skin = f.app.activate(config: "Created", file: "Skin.ini") else {
            t.check(false, "the temporary skin loads"); return nil
        }
        f.app.showInspector(for: skin)
        guard let studio = StudioWindowController.window(for: f.app) else {
            t.check(false, "the temporary Studio opens"); return nil
        }
        slowTimers(studio.codeView)
        return (studio, file)
    }

    private static func retainedIncludeTests(_ t: AppTestRunner) {
        t.suite("App: New Skin editors: retained dirty includes participate in preflight") {
            let f = try fixture(t)
            guard let (studio, main) = try openStudio(f, t) else { return }
            let include = try f.file("Created/Retained.inc")
            try studio.codeView.open(files: [main, include], current: include)
            studio.codeView.onCommit = { _, _ in false }
            CodeEditorSelfTests.type(studio.codeView, "; retained typing\n", at: 0)
            let retained = try studio.codeView.open(files: [main], current: main)
            t.equal(retained, [include])
            t.check(studio.codeView.files.contains(include))
            studio.closeChoice = { .cancel }
            t.check(!NewSkinEditorPreflight.closeEditors(affectedBy: include, isDirectory: false, app: f.app))
            t.check(StudioWindowController.window(for: f.app) === studio)
            t.check(studio.codeView.isDirty(include))
            studio.closeChoice = { .discard }
            t.check(NewSkinEditorPreflight.closeEditors(affectedBy: include, isDirectory: false, app: f.app))
            t.check(StudioWindowController.window(for: f.app) == nil)
            t.check(!studio.codeView.hasUncommittedChanges)
            try FileManager.default.removeItem(at: include)
            t.check(!studio.codeView.fireIdleCommit(), "discard cancels the pending idle save")
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            t.check(!FileManager.default.fileExists(atPath: include.path), "discarded retained code cannot recreate a deleted include")
        }
    }

    private static func sessionFlushTests(_ t: AppTestRunner) {
        for fails in [false, true] {
            t.suite("App: New Skin editors: explicit session flush, failure=\(fails)") {
                let f = try fixture(t)
                guard let (studio, file) = try openStudio(f, t), let session = studio.session else { return }
                let before = try session.buffers.load(file)
                let after = before.text + "; waiting session write\n"
                guard let change = SourceChange(file: SourceFileID(file), before: before.text, after: after,
                                                encodingBefore: before.encoding, encodingAfter: before.encoding) else {
                    return t.check(false, "the buffer edit exists")
                }
                try session.buffers.apply([change])
                session.diskSync.idleDelay = 60
                session.diskSync.scheduleFlush()
                t.check(session.diskSync.hasUnwrittenChanges && session.diskSync.hasScheduledFlush)
                if fails {
                    try FileManager.default.removeItem(at: file)
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                }
                t.equal(NewSkinEditorPreflight.closeEditors(affectedBy: file, isDirectory: false, app: f.app), !fails)
                t.check(!session.diskSync.hasScheduledFlush, "the explicit check cancels a pending disk timer")
                if fails {
                    t.check(StudioWindowController.window(for: f.app) === studio)
                    t.check(session.diskSync.hasUnwrittenChanges)
                    try FileManager.default.removeItem(at: file)
                    try Data(before.text.utf8).write(to: file)
                    try session.diskSync.flush()
                } else {
                    t.check(StudioWindowController.window(for: f.app) == nil)
                    t.check(!session.diskSync.hasUnwrittenChanges)
                    t.equal(try TextDecoding.readFile(at: file), after)
                    try FileManager.default.removeItem(at: file)
                    session.diskSync.scheduleFlush()
                    try session.diskSync.flush()
                    t.check(!FileManager.default.fileExists(atPath: file.path), "clean session buffers cannot recreate a deleted file")
                }
            }
        }
    }
}
