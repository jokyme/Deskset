import AppKit
import DesksetCore

/// Exercises the desktop's real quit delegates with private files and a nonlaunching helper.
enum AppRestartIntegrationSelfTests {
    static func run(_ t: AppTestRunner) {
        preparationTests(t)
        editorTests(t)
        updateTests(t)
        menuTests(t)
        for mode in [SkinThreading.main, .engine, .pool] { bangTests(t, mode) }
    }

    private static func preparationTests(_ t: AppTestRunner) {
        t.suite("App: Restart: preparation failure leaves the desktop running") {
            let app = makeApp(t)
            var answers: [Bool] = [], terminations = 0
            app.prepareRestart = { _, answer in answer(.failure(AppRestart.Failure.helperFailed)) }
            app.terminateForRestart = { terminations += 1 }
            app.requestRestart { answers.append($0) }
            t.equal(answers, [false])
            t.equal(terminations, 0)
            t.check(!app.isTerminating)
            var retried = false
            app.prepareRestart = { _, _ in retried = true }
            app.requestRestart()
            t.check(retried, "a failed request does not hold the next attempt")
            _ = app.applicationShouldTerminate(NSApp)
        }
        t.suite("App: Restart: one prepared request commits after approval and answers once") {
            let app = makeApp(t), helper = try Helper(t)
            var deliver: ((Result<AppRestart.Handoff, Error>) -> Void)?
            var prepares = 0, terminations = 0, answers: [Bool] = []
            app.prepareRestart = { _, answer in prepares += 1; deliver = answer }
            app.terminateForRestart = {
                terminations += 1
                t.equal(app.applicationShouldTerminate(NSApp), .terminateNow)
            }
            app.requestRestart { answers.append($0) }
            app.requestRestart { answers.append($0) }
            t.equal(prepares, 1)
            t.equal(answers, [false], "a second request is rejected without touching the first")
            t.check(!helper.committed)
            deliver?(.success(helper.handoff))
            t.equal(answers, [false, true])
            t.equal(terminations, 1)
            t.check(helper.committed)
            t.equal(helper.terminations, 0)
            deliver?(.success(helper.handoff))
            t.equal(terminations, 1)
            t.equal(helper.terminations, 0, "a duplicate answer cannot revoke the committed helper")
            app.state.setDisableDragging(true)
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            t.check(AppState(fileURL: app.state.fileURL).disableDragging)
            t.equal(helper.terminations, 0, "ordinary shutdown preserves the authorized helper")
        }
        t.suite("App: Restart: an ordinary quit invalidates a preparation still in flight") {
            let app = makeApp(t), helper = try Helper(t)
            var deliver: ((Result<AppRestart.Handoff, Error>) -> Void)?
            var answers: [Bool] = [], terminations = 0
            app.prepareRestart = { _, answer in deliver = answer }
            app.terminateForRestart = { terminations += 1 }
            app.requestRestart { answers.append($0) }
            t.equal(app.applicationShouldTerminate(NSApp), .terminateNow)
            t.equal(answers, [false])
            deliver?(.success(helper.handoff))
            t.equal(helper.terminations, 1)
            t.check(!helper.committed)
            t.equal(terminations, 0)
        }
        t.suite("App: Restart: background preparation returns to the main-thread quit decision") {
            let app = makeApp(t), helper = try Helper(t)
            var done = false
            app.prepareRestart = { _, answer in
                DispatchQueue.global().async { answer(.success(helper.handoff)) }
            }
            app.terminateForRestart = {
                t.check(Thread.isMainThread)
                t.equal(app.applicationShouldTerminate(NSApp), .terminateNow)
            }
            app.requestRestart { accepted in t.check(Thread.isMainThread && accepted); done = true }
            t.check(AppSelfTest.spin(timeout: 5) { done })
            t.check(helper.committed)
        }
    }

    private static func editorTests(_ t: AppTestRunner) {
        for accepted in [false, true] {
            t.suite("App: Restart: a nested conversion quit cannot decide the outer restart (accept=\(accepted))") {
                let old = TextDecoding.ansiCodePage
                TextDecoding.ansiCodePage = 1252
                defer { TextDecoding.ansiCodePage = old }
                let app = makeApp(t), helper = try Helper(t)
                let file = app.settingsDirectory.appendingPathComponent("Settings.inc")
                try CodeEditorSelfTests.ansiInclude.write(to: file)
                let window = try openEditor(t, app, file)
                window.closeChoice = { .cancel }
                let editor = window.codeView
                var nested: [NSApplication.TerminateReply] = [], answers: [Bool] = []
                editor.onEncodingConversion = { _, _ in
                    t.check(app.terminationDecisionInProgress && editor.hasCommitInProgress)
                    nested.append(app.applicationShouldTerminate(NSApp))
                    t.equal(helper.terminations, 0, "the inner veto does not cancel the outer handoff")
                    t.check(!helper.committed)
                    var rejected: Bool?
                    app.requestRestart { rejected = $0 }
                    t.equal(rejected, false)
                    return accepted
                }
                CodeEditorSelfTests.type(editor, "日", at: 0)
                let typed = editor.text
                app.prepareRestart = { _, answer in answer(.success(helper.handoff)) }
                app.terminateForRestart = {
                    t.equal(app.applicationShouldTerminate(NSApp), accepted ? .terminateNow : .terminateCancel)
                }
                app.requestRestart { answers.append($0) }
                t.equal(nested, [.terminateCancel])
                t.equal(answers, [accepted])
                t.equal(helper.committed, accepted)
                t.equal(helper.terminations, accepted ? 0 : 1)
                t.check(!app.terminationDecisionInProgress)
                t.equal(editor.hasUncommittedChanges, !accepted)
                if accepted { t.equal(try CodeDocument.load(file).text, typed) }
                else { t.equal(try Data(contentsOf: file), CodeEditorSelfTests.ansiInclude) }
            }
        }
        t.suite("App: Restart: a pending disk-conflict decision keeps both file and app running") {
            let app = makeApp(t), helper = try Helper(t)
            let file = app.settingsDirectory.appendingPathComponent("Settings.inc")
            try Data("[Variables]\nValue=Before\n".utf8).write(to: file)
            let window = try openEditor(t, app, file)
            window.closeChoice = { .cancel }
            CodeEditorSelfTests.type(window.codeView, "; typed\n", at: 0)
            let external = Data("[Variables]\nValue=External\n".utf8)
            try external.write(to: file, options: .atomic)
            window.codeView.onDiskConflict = { _ in
                t.equal(app.applicationShouldTerminate(NSApp), .terminateCancel)
                t.equal(helper.terminations, 0)
                return .decideLater
            }
            var answer: Bool?
            app.prepareRestart = { _, deliver in deliver(.success(helper.handoff)) }
            app.terminateForRestart = { t.equal(app.applicationShouldTerminate(NSApp), .terminateCancel) }
            app.requestRestart { answer = $0 }
            t.equal(answer, false)
            t.check(window.codeView.hasUncommittedChanges && !helper.committed)
            t.equal(try Data(contentsOf: file), external)
            t.equal(helper.terminations, 1)
        }
    }

    private static func updateTests(_ t: AppTestRunner) {
        t.suite("App: Restart: update preparation and restart requests exclude each other") {
            let update = Update(t), app = makeApp(t, updateFlow: update.flow)
            update.ready()
            update.flow.performPrimary()
            t.equal(update.flow.phase, .preparing)
            var prepared = 0, answer: Bool?
            app.prepareRestart = { _, _ in prepared += 1 }
            app.requestRestart { answer = $0 }
            t.equal(answer, false)
            t.equal(prepared, 0)
            update.flow.installationCancelled()
            app.requestRestart()
            t.equal(prepared, 1)
            update.flow.performPrimary()
            app.prepareUpdateInstallation(update.payload)
            t.equal(update.flow.phase, .ready)
            t.check(update.flow.detail.stringValue.contains("quitting or restarting"))
            _ = app.applicationShouldTerminate(NSApp)
            update.flow.cancelAndCleanUp()
        }
        t.suite("App: Restart: a late update result cannot enter an editor's quit decision") {
            let update = Update(t), app = makeApp(t, updateFlow: update.flow)
            update.ready()
            update.flow.performPrimary()
            app.prepareUpdateInstallation(update.payload)
            let old = TextDecoding.ansiCodePage
            TextDecoding.ansiCodePage = 1252
            defer { TextDecoding.ansiCodePage = old }
            let file = app.settingsDirectory.appendingPathComponent("Settings.inc")
            try CodeEditorSelfTests.ansiInclude.write(to: file)
            let window = try openEditor(t, app, file)
            window.closeChoice = { .cancel }
            window.codeView.onEncodingConversion = { _, _ in
                t.check(app.terminationDecisionInProgress)
                t.check(AppSelfTest.spin(timeout: 5) { update.flow.phase == .ready })
                t.check(update.flow.detail.stringValue.contains("quitting or restarting"))
                return false
            }
            CodeEditorSelfTests.type(window.codeView, "日", at: 0)
            t.equal(app.applicationShouldTerminate(NSApp), .terminateCancel)
            t.check(window.codeView.hasUncommittedChanges)
            update.flow.cancelAndCleanUp()
        }
    }

    private static func menuTests(_ t: AppTestRunner) {
        t.suite("App: Restart: Shift context alternate preserves the standard Quit shortcut") {
            let app = makeApp(t), menu = NSMenu()
            app.buildMainMenu(menu)
            guard let index = menu.items.firstIndex(where: { $0.title == "Quit Deskset" }), index + 1 < menu.items.count
            else { return t.check(false, "the context menu contains Quit") }
            let restart = menu.items[index + 1]
            t.equal(restart.title, "Restart Deskset")
            t.check(restart.isAlternate && restart.keyEquivalentModifierMask == [.shift])
            t.equal(menu.items[index].keyEquivalent, "")
            t.equal(restart.keyEquivalent, "")
            let main = MainMenu.make(app: app)
            t.check(main.items.compactMap(\.submenu).flatMap(\.items).contains {
                $0.action == #selector(NSApplication.terminate(_:)) && $0.keyEquivalent == "q"
                    && $0.keyEquivalentModifierMask == [.command]
            })
            var prepares = 0
            app.prepareRestart = { _, answer in prepares += 1; answer(.failure(AppRestart.Failure.helperFailed)) }
            t.check(NSApp.sendAction(restart.action!, to: restart.target, from: restart))
            t.equal(prepares, 1)
        }
    }

    private static func bangTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Restart: the bang runs after its action and recording cannot restart (\(mode))") {
            guard let app = try AppSelfTest.makeApp(t, threading: mode),
                  let skin = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            t.check(AppSelfTest.spin(timeout: 10) { skin.isStarted })
            var prepares = 0
            app.prepareRestart = { _, answer in
                prepares += 1
                t.equal(skin.runtime.exclusive(timeout: 10) { $0.variable("AfterRestart") }, "yes")
                answer(.failure(AppRestart.Failure.helperFailed))
            }
            skin.runtime.send(.execute("[!Restart][!SetVariable AfterRestart yes]", section: nil))
            t.check(AppSelfTest.spin(timeout: 10) { prepares == 1 })
            t.check(skin.runtime.snapshot.issues.allSatisfy { !$0.localizedCaseInsensitiveContains("!Restart") })
            let policy = StudioActionPolicy()
            _ = skin.runtime.exclusive(timeout: 10) { $0.actionPolicy = policy }
            skin.runtime.send(.execute("[!Restart]", section: nil))
            _ = skin.runtime.exclusive(timeout: 10) { _ in true }
            t.equal(prepares, 1)
            t.equal(skin.runtime.exclusive(timeout: 10) { _ in policy.recorded.filter { $0.name == "restart" }.count }, 1)
            app.stopAllForTermination()
        }
    }

    private static func makeApp(_ t: AppTestRunner, updateFlow: AppUpdateFlow? = nil) -> AppController {
        let root = t.temporaryDirectory("restart-integration")
        return AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
            skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
            backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
            settingsDirectory: root, presentsWindows: false,
            system: NetworkStatisticsRuntimeSelfTests.TestSystem(), updateFlow: updateFlow)
    }

    private static func openEditor(_ t: AppTestRunner, _ app: AppController, _ file: URL) throws -> CodeFileWindowController {
        guard app.showCodeFile(file, line: nil), let window = app.codeFileWindows.last else {
            throw CocoaError(.fileReadUnknown)
        }
        window.codeView.onCommit = nil
        window.codeView.onTypedText = nil
        window.codeView.idleCommitDelay = 60
        window.codeView.typedTextDelay = 60
        t.atSuiteEnd {
            window.codeView.onCommit = nil
            window.codeView.onEncodingConversion = nil
            window.codeView.onDiskConflict = nil
            window.codeView.discardUncommittedChanges()
            window.closeChoice = { .discard }
            window.close()
            app.stopAllForTermination()
        }
        return window
    }

    private final class Helper {
        let handoff: AppRestart.Handoff
        let directory: URL
        private final class State { var running = true; var terminations = 0 }
        private let state = State()
        var terminations: Int { state.terminations }
        var committed: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("commit.json").path) }
        init(_ t: AppTestRunner) throws {
            let job = UUID().uuidString
            directory = t.temporaryDirectory("restart-helper").resolvingSymlinksInPath()
                .appendingPathComponent("DesksetRestart-" + job)
            var d = AppRestart.Dependencies()
            try d.files.makeDirectory(directory)
            let parent = AppUpdateInstaller.ProcessIdentity(seconds: 41, microseconds: 1)
            let child = AppUpdateInstaller.ProcessIdentity(seconds: 42, microseconds: 1)
            let manifest = AppRestart.Manifest(job: job, nonce: UUID().uuidString,
                appURL: URL(fileURLWithPath: "/private/Deskset.app"),
                executableURL: URL(fileURLWithPath: "/private/Deskset.app/Contents/MacOS/Deskset"),
                parentPID: 41, parentIdentity: parent)
            let ready = AppRestart.Ready(manifest: manifest, helperPID: 42, helperIdentity: child)
            try d.files.write(JSONEncoder().encode(manifest), directory.appendingPathComponent("manifest.json"))
            try d.files.write(JSONEncoder().encode(ready), directory.appendingPathComponent("ready.json"))
            d.identity = { $0 == 41 ? parent : ($0 == 42 ? child : nil) }
            let state = self.state
            let process = AppRestart.Child(pid: 42, isRunning: { state.running }, terminate: {
                state.running = false; state.terminations += 1
            })
            handoff = AppRestart.Handoff(directory: directory, ready: ready, child: process, dependencies: d)
        }
    }

    private final class Update {
        private final class Fetcher: AppUpdateFetching {
            var answer: ((Result<AppRelease?, Error>) -> Void)?
            func fetch(completion: @escaping (Result<AppRelease?, Error>) -> Void) -> () -> Void { answer = completion; return {} }
        }
        private final class Downloader: AppUpdateDownloading {
            var answer: ((Result<AppPreparedUpdate, Error>) -> Void)?
            func download(_ release: AppRelease, progress: @escaping (Double?) -> Void,
                          completion: @escaping (Result<AppPreparedUpdate, Error>) -> Void) -> () -> Void { answer = completion; return {} }
        }
        let flow: AppUpdateFlow
        let payload: AppPreparedUpdate
        private let fetcher = Fetcher(), downloader = Downloader()
        private let release = AppRelease(version: ReleaseVersion("99.0.0")!,
            url: URL(string: "https://github.com/jokyme/Deskset/releases/tag/v99.0.0")!)
        init(_ t: AppTestRunner) {
            let root = t.temporaryDirectory("restart-update")
            payload = AppPreparedUpdate(directory: root, appURL: root.appendingPathComponent("Deskset.app"))
            flow = AppUpdateFlow(presentsWindows: false, service: fetcher, downloader: downloader) { _ in }
        }
        func ready() {
            flow.start(release)
            fetcher.answer?(.success(release))
            downloader.answer?(.success(payload))
        }
    }
}
