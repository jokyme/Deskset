import AppKit
import DesksetCore

/// Saves and nested close requests run through both editor window types, using only temporary files.
enum EditorTerminationSelfTests {
    static func run(_ t: AppTestRunner) {
        for kind in Kind.allCases {
            conversionTests(t, kind)
            conflictTests(t, kind)
            closeDecisionTests(t, kind)
            dirtyAfterCommitTests(t, kind)
            retryTests(t, kind, remainsDirty: false)
            retryTests(t, kind, remainsDirty: true)
        }
    }

    private static func conversionTests(_ t: AppTestRunner, _ kind: Kind) {
        for accepted in [false, true] {
            t.suite("App: Editor termination: conversion blocks nested close and quit (\(kind.rawValue), accept=\(accepted))") {
                let oldCodePage = TextDecoding.ansiCodePage
                TextDecoding.ansiCodePage = 1252
                defer { TextDecoding.ansiCodePage = oldCodePage }
                let bytes = CodeEditorSelfTests.ansiInclude
                let f = try fixture(t, kind, bytes: bytes)
                let editor = f.host.editor
                t.equal(editor.document(for: f.file)?.encoding, .windows1252)
                var nested: [Bool] = [], asked = 0, conversions = 0
                f.host.setCloseChoice { asked += 1; return .cancel }
                editor.onEncodingConversion = { _, _ in
                    conversions += 1
                    t.check(editor.hasCommitInProgress)
                    nested.append(f.host.canTerminate())
                    nested.append(f.host.shouldClose())
                    t.check(editor.commitNow(explicit: true), "ordinary nested host commits retain their existing result")
                    return accepted
                }
                CodeEditorSelfTests.type(editor, "日", at: 0)
                let typed = editor.text
                t.equal(editor.commitNow(explicit: true), accepted)
                t.equal(conversions, 1)
                t.equal(nested, [false, false])
                t.equal(asked, 0, "a busy save cannot open another close decision")
                t.check(!editor.hasCommitInProgress)
                t.equal(editor.hasUncommittedChanges, !accepted)
                if accepted {
                    let saved = try CodeDocument.load(f.file)
                    t.equal(saved.text, typed)
                    t.equal(saved.encoding, .utf16LittleEndian(bom: true))
                    t.check(f.host.canTerminate(), "the completed clean commit no longer blocks quitting")
                } else {
                    t.equal(try Data(contentsOf: f.file), bytes)
                    t.equal(editor.text, typed, "declining conversion keeps the typed buffer")
                }
            }
        }
    }

    private static func conflictTests(_ t: AppTestRunner, _ kind: Kind) {
        t.suite("App: Editor termination: a disk-conflict decision blocks nested close and quit (\(kind.rawValue))") {
            let f = try fixture(t, kind)
            let editor = f.host.editor
            CodeEditorSelfTests.type(editor, "; typed\n", at: 0)
            let typed = editor.text
            let external = Data("; written elsewhere\n[Variables]\nName=Disk\n".utf8)
            try external.write(to: f.file, options: .atomic)
            var nested: [Bool] = [], asked = 0, conflicts = 0
            f.host.setCloseChoice { asked += 1; return .cancel }
            editor.onDiskConflict = { _ in
                conflicts += 1
                t.check(editor.hasCommitInProgress)
                nested.append(f.host.canTerminate())
                nested.append(f.host.shouldClose())
                return .decideLater
            }
            t.check(!editor.commitNow(explicit: true))
            t.equal(conflicts, 1)
            t.equal(nested, [false, false])
            t.equal(asked, 0)
            t.check(editor.hasUncommittedChanges && !editor.hasCommitInProgress)
            t.equal(editor.text, typed)
            t.equal(try Data(contentsOf: f.file), external)
            editor.onDiskConflict = { _ in .takeDisk }
            t.check(f.host.canTerminate(), "the next decision may finish after the pending conflict returns")
            t.check(!editor.hasUncommittedChanges && !editor.hasCommitInProgress)
            t.equal(editor.text, String(decoding: external, as: UTF8.self))
            t.equal(try Data(contentsOf: f.file), external)
        }
    }

    private static func closeDecisionTests(_ t: AppTestRunner, _ kind: Kind) {
        t.suite("App: Editor termination: Save Discard Cancel cannot reenter its own close decision (\(kind.rawValue))") {
            let f = try fixture(t, kind)
            let editor = f.host.editor
            let bytes = try Data(contentsOf: f.file)
            CodeEditorSelfTests.type(editor, "; typed\n", at: 0)
            let typed = editor.text
            var commits = 0, asked = 0, nested: [Bool] = []
            editor.onCommit = { _, _ in commits += 1; return false }
            f.host.setCloseChoice {
                asked += 1
                t.check(!editor.hasCommitInProgress, "the close decision outlives the attempted commit")
                nested.append(f.host.canTerminate())
                nested.append(f.host.shouldClose())
                return .cancel
            }
            t.check(!f.host.canTerminate())
            t.equal(commits, 1)
            t.equal(asked, 1)
            t.equal(nested, [false, false])
            t.check(editor.hasUncommittedChanges)
            t.equal(editor.text, typed)
            t.equal(try Data(contentsOf: f.file), bytes)
            f.host.setCloseChoice { .discard }
            t.check(f.host.shouldClose(), "a later explicit discard can close")
            t.check(!editor.hasUncommittedChanges && !editor.hasCommitInProgress)
            t.equal(try Data(contentsOf: f.file), bytes, "discard never writes the rejected edits")
        }
    }

    private static func dirtyAfterCommitTests(_ t: AppTestRunner, _ kind: Kind) {
        t.suite("App: Editor termination: a successful callback with new dirty typing cannot authorize close (\(kind.rawValue))") {
            let f = try fixture(t, kind)
            let editor = f.host.editor
            CodeEditorSelfTests.type(editor, "; first edit\n", at: 0)
            let submitted = editor.text
            var commits = 0, asked = 0
            editor.onCommit = { url, text in
                commits += 1
                t.check(editor.hasCommitInProgress)
                guard let data = editor.document(for: url)?.data(for: text) else {
                    t.check(false, "the temporary document can encode its edited text")
                    return false
                }
                do { try data.write(to: url, options: .atomic) }
                catch { t.check(false, "temporary commit failed: \(error)"); return false }
                CodeEditorSelfTests.type(editor, "; later edit\n", at: 0)
                return true
            }
            f.host.setCloseChoice { asked += 1; return .cancel }
            t.check(!f.host.canTerminate())
            t.equal(commits, 1)
            t.equal(asked, 1)
            t.check(editor.hasUncommittedChanges && !editor.hasCommitInProgress)
            t.check(editor.text.hasPrefix("; later edit\n"))
            t.equal(try CodeDocument.load(f.file).text, submitted)
        }
    }

    private static func retryTests(_ t: AppTestRunner, _ kind: Kind, remainsDirty: Bool) {
        t.suite("App: Editor termination: Save retry requires a clean completed buffer (\(kind.rawValue), dirty=\(remainsDirty))") {
            let f = try fixture(t, kind)
            let editor = f.host.editor
            let original = try Data(contentsOf: f.file)
            CodeEditorSelfTests.type(editor, "; first edit\n", at: 0)
            let submitted = editor.text
            var commits = 0, asked = 0
            editor.onCommit = { url, text in
                commits += 1
                guard commits > 1 else { return false }
                guard let data = editor.document(for: url)?.data(for: text) else {
                    t.check(false, "the temporary document can encode its retry text")
                    return false
                }
                do { try data.write(to: url, options: .atomic) }
                catch { t.check(false, "temporary retry failed: \(error)"); return false }
                if remainsDirty { CodeEditorSelfTests.type(editor, "; later edit\n", at: 0) }
                return true
            }
            f.host.setCloseChoice {
                asked += 1
                t.equal((try? Data(contentsOf: f.file)), original, "the failed first attempt kept the file")
                return .save
            }
            t.equal(f.host.shouldClose(), !remainsDirty)
            t.equal(commits, 2)
            t.equal(asked, 1)
            t.check(!editor.hasCommitInProgress)
            t.equal(editor.hasUncommittedChanges, remainsDirty)
            t.equal(try CodeDocument.load(f.file).text, submitted)
            if remainsDirty { t.check(editor.text.hasPrefix("; later edit\n")) }
            else { t.check(f.host.canTerminate(), "the clean retry also allows the next quit decision") }
        }
    }

    private enum Kind: String, CaseIterable { case file, studio }

    private enum Host {
        case file(CodeFileWindowController)
        case studio(StudioWindowController)

        var editor: CodeEditorView {
            switch self {
            case .file(let controller): return controller.codeView
            case .studio(let controller): return controller.codeView
            }
        }

        var window: NSWindow? {
            switch self {
            case .file(let controller): return controller.window
            case .studio(let controller): return controller.window
            }
        }

        func canTerminate() -> Bool {
            switch self {
            case .file(let controller): return controller.canTerminate()
            case .studio(let controller): return controller.canTerminate()
            }
        }

        func shouldClose() -> Bool {
            guard let window else { return false }
            switch self {
            case .file(let controller): return controller.windowShouldClose(window)
            case .studio(let controller): return controller.windowShouldClose(window)
            }
        }

        func setCloseChoice(_ choose: @escaping () -> CodeFileWindowController.CloseChoice) {
            switch self {
            case .file(let controller): controller.closeChoice = choose
            case .studio(let controller): controller.closeChoice = choose
            }
        }
    }

    private struct Fixture {
        let app: AppController
        let file: URL
        let host: Host
    }

    private static func fixture(_ t: AppTestRunner, _ kind: Kind, bytes: Data? = nil) throws -> Fixture {
        let root = t.temporaryDirectory("editor-termination")
        let file = root.appendingPathComponent("Settings.inc")
        try (bytes ?? Data("[Variables]\nName=Original\n".utf8)).write(to: file)
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
                                skinsDirectory: root.appendingPathComponent("Skins"),
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                                settingsDirectory: root, presentsWindows: false,
                                system: NetworkStatisticsRuntimeSelfTests.TestSystem())
        let host: Host
        switch kind {
        case .file: host = .file(try CodeFileWindowController(file: file, app: app))
        case .studio:
            let studio = StudioWindowController(app: app)
            try studio.codeView.open(files: [file], current: file)
            host = .studio(studio)
        }
        host.editor.onCommit = nil
        host.editor.idleCommitDelay = 60
        host.editor.caretRestDelay = 60
        let fixture = Fixture(app: app, file: file, host: host)
        t.atSuiteEnd {
            host.editor.onCommit = nil
            host.editor.onEncodingConversion = nil
            host.editor.onDiskConflict = nil
            host.editor.discardUncommittedChanges()
            host.setCloseChoice { .discard }
            host.window?.close()
            app.stopAllForTermination()
        }
        return fixture
    }
}
