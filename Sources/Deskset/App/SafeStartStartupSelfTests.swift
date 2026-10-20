import AppKit

enum SafeStartStartupSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Safe Start startup: native reopen waits for the startup decision") {
            let app = makeApp(t)
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            t.check(!app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            t.equal(app.pendingLayoutCommands.count, 1)
            t.check(Set(NSApp.windows.map(ObjectIdentifier.init)) == before && app.controllers.isEmpty)
            app.finishLayoutCommandStartup()
            t.check(app.pendingLayoutCommands.isEmpty)
            let opened = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }
            t.check(!opened.isEmpty, "the native request is handled after startup resumes")
            for window in opened { window.close() }
        }
        t.suite("App: Safe Start startup: abort discards a waiting native reopen") {
            let app = makeApp(t)
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            app.abortStartupRecovery()
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            t.check(app.pendingLayoutCommands.isEmpty)
            t.check(Set(NSApp.windows.map(ObjectIdentifier.init)) == before && app.controllers.isEmpty)
        }
        t.suite("App: Safe Start startup: an aborted recovery rejects queued and later commands") {
            let app = makeApp(t)
            var answers: [Bool] = []
            app.receiveLayoutCommand(.command(.manageLayouts)) { answers.append($0) }
            app.receiveLayoutCommand(.reopen([])) { answers.append($0) }
            t.equal(app.pendingLayoutCommands.count, 2)
            t.check(answers.isEmpty)

            app.abortStartupRecovery()
            t.equal(answers, [false, false])
            t.check(app.pendingLayoutCommands.isEmpty)
            t.check(app.startupRecoveryAborted)
            t.check(app.isTerminating)
            t.check(!app.layoutCommandsReady)
            app.abortStartupRecovery()
            t.equal(answers.count, 2, "abort completion is delivered once")

            app.receiveLayoutCommand(.command(.manageLayouts)) { answers.append($0) }
            t.equal(answers, [false, false, false], "late requests cannot load a desktop after recovery failed")
            t.check(app.activate(config: "Previous", file: "Skin.ini") == nil)
            t.check(app.controllers.isEmpty)
        }
        t.suite("App: Safe Start startup: termination after recovery failure does not write stale state") {
            let app = makeApp(t)
            let raw = Data("{\"startupSentinel\":true}".utf8)
            try raw.write(to: app.state.fileURL, options: .atomic)
            app.abortStartupRecovery()
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            t.equal(try Data(contentsOf: app.state.fileURL), raw)
            t.check(app.controllers.isEmpty)
        }
    }

    private static func makeApp(_ t: AppTestRunner) -> AppController {
        let root = t.temporaryDirectory("safe-start-startup")
        return AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
            skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
            backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
            settingsDirectory: root, presentsWindows: false)
    }
}
