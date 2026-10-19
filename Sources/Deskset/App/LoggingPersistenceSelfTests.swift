import AppKit
import DesksetCore

/// File logging uses temporary folders and restores the process logger after each suite.
enum LoggingPersistenceSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Logging persistence: startup applies saved settings without changing fixtures") {
            try withLogger(t) { root in
                let state = AppState(fileURL: root.appendingPathComponent("state.json"))
                t.check(!state.fileLoggingEnabled, "Logging defaults to off")
                state.setFileLoggingEnabled(true)
                state.saveNow()
                let app = makeApp(AppState(fileURL: state.fileURL))
                defer { app.stopAllForTermination() }
                t.check(!Log.fileLoggingEnabled, "constructing a fixture does not enable the process logger")
                Log.write("Before primary startup")
                Log.flush()
                t.check(!FileManager.default.fileExists(atPath: Log.directory.path))
                app.applyFileLoggingPreference()
                t.check(Log.fileLoggingEnabled)
                Log.write("Primary startup")
                Log.flush()
                let contents = try String(contentsOf: Log.fileURL, encoding: .utf8)
                t.check(contents.contains("Primary startup"))
                t.check(!contents.contains("Before primary startup"), "lines queued while disabled stay memory-only")
                app.setFileLoggingEnabled(false)
                t.check(!AppState(fileURL: state.fileURL).fileLoggingEnabled,
                        "Stop is saved before returning, without waiting for the debounce")
            }
        }

        t.suite("App: Logging persistence: disabled startup neither creates nor rotates a file") {
            try withLogger(t) { root in
                let app = makeApp(AppState(fileURL: root.appendingPathComponent("state.json")))
                defer { app.stopAllForTermination() }
                app.applyFileLoggingPreference()
                let incoming = LayoutState(skins: [:], order: [],
                                           rainmeterOptions: ["Logging": "1", "DisableDragging": "1"])
                let previous = LayoutState(skins: [:], order: [], rainmeterOptions: app.state.data.rainmeterOptions)
                app.state.replaceLayout(incoming.preservingSettings(from: previous))
                t.check(!app.state.fileLoggingEnabled && !Log.fileLoggingEnabled,
                        "a normal layout retains local default Logging=0 when the key is absent")
                t.check(app.state.disableDragging, "other layout settings still apply")
                Log.write("Memory only")
                Log.flush()
                t.check(!FileManager.default.fileExists(atPath: Log.directory.path))
                try FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
                let old = Log.directory.appendingPathComponent("Deskset.old.log")
                let large = Data(repeating: 65, count: 1024)
                try large.write(to: Log.fileURL)
                try Data("Previous archive".utf8).write(to: old)
                Log.maxLogSize = 512
                app.applyFileLoggingPreference()
                Log.rotateIfNeeded()
                Log.write("Still memory only")
                Log.flush()
                t.equal(try Data(contentsOf: Log.fileURL), large)
                t.equal(try String(contentsOf: old, encoding: .utf8), "Previous archive")
                app.setFileLoggingEnabled(true)
                t.equal(try Data(contentsOf: old), large, "enabled logging retains the existing rotation behavior")
                Log.write("After enabling")
                app.setFileLoggingEnabled(false)
                let stopped = try Data(contentsOf: Log.fileURL)
                Log.write("After stopping")
                Log.flush()
                t.equal(try Data(contentsOf: Log.fileURL), stopped, "Stop drains earlier writes and preserves the file")
            }
        }

        t.suite("App: Logging persistence: Debug actions save and refresh the log file menu") {
            try withLogger(t) { root in
                let state = AppState(fileURL: root.appendingPathComponent("state.json"))
                let app = makeApp(state)
                defer { app.stopAllForTermination() }
                app.applyFileLoggingPreference()
                let debug = DebugWindowController.show(app: app)
                defer { debug.close() }
                guard let menu = debug.testLogFileMenu else { return t.check(false, "Log file menu exists") }
                debug.refreshLogFileMenu()
                t.check(menu.item(withTitle: "Start logging")?.isEnabled == true)
                t.check(menu.item(withTitle: "Stop logging")?.isEnabled == false)
                perform("Start logging", in: menu, t: t)
                t.check(AppState(fileURL: state.fileURL).fileLoggingEnabled)
                t.check(menu.item(withTitle: "Start logging")?.isEnabled == false)
                t.check(menu.item(withTitle: "Stop logging")?.isEnabled == true)
                for index in 0..<100 { Log.write("Before stop \(index)") }
                perform("Stop logging", in: menu, t: t)
                t.check(!AppState(fileURL: state.fileURL).fileLoggingEnabled)
                let contents = try String(contentsOf: Log.fileURL, encoding: .utf8)
                t.check(contents.contains("Before stop 99"), "Stop waits for every previously queued write")
                t.check(menu.item(withTitle: "Start logging")?.isEnabled == true)
                t.check(menu.item(withTitle: "Show log file")?.isEnabled == true)
                perform("Start logging", in: menu, t: t)
                for index in 0..<100 { Log.write("Before delete \(index)") }
                perform("Delete log file", in: menu, t: t)
                t.check(!Log.fileLoggingEnabled)
                t.check(!AppState(fileURL: state.fileURL).fileLoggingEnabled)
                Log.write("After delete")
                Log.flush()
                t.check(!FileManager.default.fileExists(atPath: Log.fileURL.path), "queued writes cannot recreate a deleted log")
                t.check(menu.item(withTitle: "Start logging")?.isEnabled == true)
                t.check(menu.item(withTitle: "Stop logging")?.isEnabled == false)
                t.check(menu.item(withTitle: "Show log file")?.isEnabled == false)
                t.check(menu.item(withTitle: "Delete log file")?.isEnabled == false)
                perform("Start logging", in: menu, t: t)
                Log.write("Restarted")
                Log.flush()
                let restarted = try String(contentsOf: Log.fileURL, encoding: .utf8)
                t.check(restarted.contains("Restarted") && !restarted.contains("Before delete")
                        && !restarted.contains("After delete"))
            }
        }

        t.suite("App: Logging persistence: deletion failure still saves Stop and keeps truthful controls") {
            try withLogger(t) { root in
                let state = AppState(fileURL: root.appendingPathComponent("state.json"))
                let app = makeApp(state)
                defer { app.stopAllForTermination() }
                app.setFileLoggingEnabled(true)
                let debug = DebugWindowController.show(app: app)
                defer { debug.close() }
                guard let menu = debug.testLogFileMenu else { return t.check(false, "Log file menu exists") }
                for index in 0..<100 { Log.write("Retained \(index)") }
                var attempted = false
                do {
                    try app.deleteLogFile { file in
                        attempted = true
                        t.equal(file, Log.fileURL)
                        t.check(!AppState(fileURL: state.fileURL).fileLoggingEnabled)
                        t.check((try String(contentsOf: file, encoding: .utf8)).contains("Retained 99"))
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    t.check(false, "the removal failure is reported")
                } catch { t.check((error as NSError).code == CocoaError.Code.fileWriteNoPermission.rawValue) }
                t.check(attempted)
                t.check(!Log.fileLoggingEnabled)
                t.check(!AppState(fileURL: state.fileURL).fileLoggingEnabled)
                t.check(menu.item(withTitle: "Start logging")?.isEnabled == true)
                t.check(menu.item(withTitle: "Stop logging")?.isEnabled == false)
                t.check(menu.item(withTitle: "Show log file")?.isEnabled == true)
                t.check(menu.item(withTitle: "Delete log file")?.isEnabled == true)
                let retained = try Data(contentsOf: Log.fileURL)
                Log.write("Deletion error is memory only", level: .error)
                Log.flush()
                t.equal(try Data(contentsOf: Log.fileURL), retained)
                app.setFileLoggingEnabled(true)
                Log.write("After failed delete")
                Log.flush()
                t.check((try String(contentsOf: Log.fileURL, encoding: .utf8)).contains("After failed delete"),
                        "restart opens a fresh handle after deletion failed")
            }
        }

        t.suite("App: Logging persistence: global changes follow only the primary app and preserve local layout settings") {
            try withLogger(t) { root in
                let file = root.appendingPathComponent("state.json")
                try #"{"rainmeterOptions":{"lOgGiNg":"1","FutureSetting":"kept"},"futureApp":[1,2]}"#
                    .write(to: file, atomically: true, encoding: .utf8)
                let state = AppState(fileURL: file)
                let app = makeApp(state)
                defer { app.stopAllForTermination() }
                t.check(state.fileLoggingEnabled)
                app.applyFileLoggingPreference()
                app.setFileLoggingEnabled(false)
                let reopened = AppState(fileURL: file)
                t.check(!reopened.fileLoggingEnabled)
                t.equal(reopened.data.rainmeterOptions["lOgGiNg"], "0")
                t.equal(reopened.data.rainmeterOptions["FutureSetting"], "kept")
                t.equal(reopened.data.unknownKeys["futureApp"], .array([.number(1), .number(2)]))
                let other = AppState(fileURL: root.appendingPathComponent("other.json"))
                other.setFileLoggingEnabled(true)
                other.setFileLoggingEnabled(false)
                t.check(!Log.fileLoggingEnabled, "another fixture's settings cannot change this logger")
                let incoming = LayoutStateCodec.decode(IniDocument.parse("[Rainmeter]\nLogging=1\n"), library: [])
                let previous = LayoutState(skins: [:], order: [], rainmeterOptions: state.data.rainmeterOptions)
                state.replaceLayout(incoming.preservingSettings(from: previous))
                t.check(!state.fileLoggingEnabled && !Log.fileLoggingEnabled,
                        "an ordinary layout preserves explicit local Logging=0")
                state.replaceLayout(incoming)
                t.check(Log.fileLoggingEnabled, "a backup's restored Logging=1 reaches the live logger")
                state.replaceLayout(LayoutState(skins: [:], order: [], rainmeterOptions: ["Logging": "0"]))
                t.check(!Log.fileLoggingEnabled, "a backup's restored Logging=0 reaches the live logger")
                state.setFileLoggingEnabled(true)
                t.check(Log.fileLoggingEnabled, "the primary app observes the global setting")
                app.stopAllForTermination()
                state.setFileLoggingEnabled(false)
                t.check(Log.fileLoggingEnabled, "a stopped app no longer observes state changes")

            }
        }
    }

    private static func makeApp(_ state: AppState) -> AppController {
        let root = state.fileURL.deletingLastPathComponent()
        return AppController(state: state, skinsDirectory: root.appendingPathComponent("Skins"),
                             layoutsDirectory: root.appendingPathComponent("Layouts"),
                             backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
                             settingsDirectory: root, presentsWindows: false)
    }

    private static func perform(_ title: String, in menu: NSMenu, t: AppTestRunner) {
        guard let item = menu.item(withTitle: title), item.isEnabled, let action = item.action else {
            return t.check(false, "\(title) is available")
        }
        t.check(NSApp.sendAction(action, to: item.target, from: item), "\(title) dispatches")
    }

    private static func withLogger(_ t: AppTestRunner, _ body: (URL) throws -> Void) throws {
        let saved = (Log.directory, Log.fileLoggingEnabled, Log.mirrorsToStandardError, Log.maxLogSize)
        Log.fileLoggingEnabled = false
        let root = t.temporaryDirectory("logging-persistence")
        Log.directory = root.appendingPathComponent("Logs")
        Log.mirrorsToStandardError = false
        defer {
            Log.fileLoggingEnabled = false
            Log.directory = saved.0
            Log.mirrorsToStandardError = saved.2
            Log.maxLogSize = saved.3
            Log.fileLoggingEnabled = saved.1
        }
        try body(root)
    }
}
