import DesksetCore
import Foundation

/// Update preferences use temporary state files; tests never change the user's settings or contact a server.
enum AppUpdatePreferencesSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Updates: older state files keep update defaults") {
            let raw = Data(#"{"skins":{"Clock":{"file":"Clock.ini"}},"editor":{"liveReload":false}}"#.utf8)
            let data = try JSONDecoder().decode(AppStateData.self, from: raw)
            t.equal(data.updates, AppUpdatePreferences())
            t.check(data.updates.automaticallyChecks)
            t.equal(data.updates.lastCheckAttempt, nil)
            t.equal(data.updates.lastNotifiedVersion, nil)
            t.equal(data.skins["Clock"]?.file, "Clock.ini")
            t.equal(data.editor.liveReload, false)
        }

        t.suite("App: Updates: preferences round trip through state.json") {
            let url = t.temporaryDirectory("update-preferences").appendingPathComponent("state.json")
            let state = AppState(fileURL: url)
            let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
            state.update("Clock") { $0.file = "Clock.ini" }
            state.updateUpdates {
                $0.automaticallyChecks = false
                $0.lastCheckAttempt = checkedAt
                $0.lastNotifiedVersion = "1.2.3"
            }
            state.saveNow()
            let loaded = AppState(fileURL: url)
            t.equal(loaded.updates, state.updates)
            t.equal(loaded.updates.automaticallyChecks, false)
            t.equal(loaded.updates.lastCheckAttempt, checkedAt)
            t.equal(loaded.updates.lastNotifiedVersion, "1.2.3")
            t.equal(loaded.skin("Clock")?.file, "Clock.ini")

            loaded.updateUpdates {
                $0.automaticallyChecks = true
                $0.lastCheckAttempt = nil
                $0.lastNotifiedVersion = nil
            }
            loaded.saveNow()
            t.equal(AppState(fileURL: url).updates, AppUpdatePreferences())
        }

        t.suite("App: Updates: malformed fields leave other preferences intact") {
            func decode(_ updates: String) throws -> AppStateData {
                let raw = #"{"skins":{"Clock":{"file":"Clock.ini"}},"editor":{"liveReload":false},"updates":\#(updates)}"#
                return try JSONDecoder().decode(AppStateData.self, from: Data(raw.utf8))
            }
            let broken = try decode(#"{"automaticallyChecks":"yes","lastCheckAttempt":"yesterday","lastNotifiedVersion":"1.2.3"}"#)
            t.check(broken.updates.automaticallyChecks)
            t.equal(broken.updates.lastCheckAttempt, nil)
            t.equal(broken.updates.lastNotifiedVersion, "1.2.3")
            t.equal(broken.skins["Clock"]?.file, "Clock.ini")
            t.equal(broken.editor.liveReload, false)

            let partial = try decode(#"{"automaticallyChecks":false,"lastCheckAttempt":800000000,"lastNotifiedVersion":false}"#)
            t.equal(partial.updates.automaticallyChecks, false)
            t.equal(partial.updates.lastCheckAttempt, Date(timeIntervalSinceReferenceDate: 800_000_000))
            t.equal(partial.updates.lastNotifiedVersion, nil)

            for value in ["null", "5", "[]", "{}"] {
                let data = try decode(value)
                t.equal(data.updates, AppUpdatePreferences(), "defaults for \(value)")
                t.equal(data.skins["Clock"]?.file, "Clock.ini")
                t.equal(data.editor.liveReload, false)
            }
        }

        t.suite("App: Updates: unknown fields survive preference changes") {
            let url = t.temporaryDirectory("update-unknown-fields").appendingPathComponent("state.json")
            let raw = #"{"updates":{"automaticallyChecks":false,"future":{"channels":["stable","preview"],"enabled":true}},"futureApp":{"count":3}}"#
            try raw.write(to: url, atomically: true, encoding: .utf8)
            let state = AppState(fileURL: url)
            let expected = JSONValue.object(["channels": .array([.string("stable"), .string("preview")]),
                                             "enabled": .bool(true)])
            t.equal(state.updates.unknownKeys["future"], expected)
            t.check(state.data.unknownKeys["updates"] == nil, "updates is a known top-level field")
            state.updateUpdates {
                $0.automaticallyChecks = true
                $0.lastNotifiedVersion = "1.2.3"
            }
            state.saveNow()
            let loaded = AppState(fileURL: url)
            t.equal(loaded.updates.unknownKeys["future"], expected)
            t.equal(loaded.data.unknownKeys["futureApp"], state.data.unknownKeys["futureApp"])
            t.check(loaded.updates.automaticallyChecks)
            t.equal(loaded.updates.lastNotifiedVersion, "1.2.3")
        }
    }
}
