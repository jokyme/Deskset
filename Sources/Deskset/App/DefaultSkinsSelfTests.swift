import AppKit
import DesksetCore

/// `Deskset --self-test "default skins"`: installing and upgrading the bundled default skins, the first-run layout
/// (`DefaultSkins/FirstRun.ini`) and the Stationery widgets' `Stationery.inc` (docs/compat/app.md). Every folder is a
/// temporary one: nothing here touches the user's skins or settings.
enum DefaultSkinsSelfTests {
    static func run(_ t: AppTestRunner) {
        layoutTests(t)
        installTests(t)
        stationeryFileTests(t)
        upgradeTests(t)
        shippedStateTests(t)
    }

    /// A bundle's default skins in a temporary folder: `files` maps paths (`Root/Config/Skin.ini`, `FirstRun.ini`) to
    /// their text.
    static func source(_ t: AppTestRunner, _ files: [String: String]) throws -> URL {
        let root = t.temporaryDirectory("default-skins")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// An app with temporary Skins, Backups and settings folders and `source` as its default skins.
    static func app(_ t: AppTestRunner, source: URL?, state: String? = nil) throws -> AppController {
        let root = t.temporaryDirectory("default-skins-app")
        let skins = root.appendingPathComponent("Skins")
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        if let state { try state.write(to: stateURL, atomically: true, encoding: .utf8) }
        let app = AppController(state: AppState(fileURL: stateURL), skinsDirectory: skins,
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: source,
                                settingsDirectory: root.appendingPathComponent("Settings"), presentsWindows: false)
        t.atSuiteEnd { app.stopAllForTermination() }
        return app
    }

    static let widget = "[Rainmeter]\nUpdate=1000\n[M]\nMeter=String\nText=Hi\nW=100\nH=40\n"

    // MARK: The layout file

    static func layoutTests(_ t: AppTestRunner) {
        t.suite("App: default skins: the first-run layout file") {
            let layout = FirstRunLayout.parse("""
            ; a comment
            [Stationery\\Clock]
            File=Small.ini
            X=20
            Y=20

            [stationery/weather/]
            File = Medium.ini
            X=20
            Y=210

            [Stationery\\Clock]
            X=500

            [Stationery\\System]
            X=abc
            Y=1e99

            [Stationery\\Calendar]
            File=
            Y=20
            """)
            t.equal(layout.entries.map(\.config), ["Stationery\\Clock", "stationery\\weather", "Stationery\\System",
                                                  "Stationery\\Calendar"], "in the order written, each config once")
            t.equal(layout.entries[0], FirstRunLayout.Entry(config: "Stationery\\Clock", file: "Small.ini", x: 20, y: 20))
            t.equal(layout.entries[1].file, "Medium.ini")
            t.equal(layout.entries[2].x, nil, "not a number")
            t.equal(layout.entries[2].y, SkinState.maxPosition, "clamped like a position")
            t.equal(layout.entries[3].file, nil, "empty: the config's usual file")
            // X and Y are measured from the visible area's top-left corner, below the menu bar and beside the Dock.
            let screen = CGRect(x: 0, y: 60, width: 1440, height: 815)   // Dock below, menu bar 25 pt, 900 high
            t.equal(layout.entries[0].position(visibleFrame: screen, primaryHeight: 900)?.x, 20)
            t.equal(layout.entries[0].position(visibleFrame: screen, primaryHeight: 900)?.y, 45)
            let dockLeft = CGRect(x: 80, y: 0, width: 1360, height: 875)
            t.equal(layout.entries[1].position(visibleFrame: dockLeft, primaryHeight: 900)?.x, 100)
            t.equal(layout.entries[1].position(visibleFrame: dockLeft, primaryHeight: 900)?.y, 235)
            t.equal(layout.entries[3].position(visibleFrame: screen, primaryHeight: 900)?.x, 0, "a missing X is 0")
            t.equal(FirstRunLayout.Entry(config: "A").position(visibleFrame: screen, primaryHeight: 900)?.x, nil,
                    "neither: the skin places itself")
            let folder = t.temporaryDirectory("first-run-file")
            t.equal(FirstRunLayout.load(from: folder.appendingPathComponent("FirstRun.ini")), nil, "no file")
            let comments = folder.appendingPathComponent("Comments.ini")
            try "; nothing yet\n".write(to: comments, atomically: true, encoding: .utf8)
            t.equal(FirstRunLayout.load(from: comments), nil, "a file that names no config")
        }
    }

    // MARK: Installing, and the first launch

    static func installTests(_ t: AppTestRunner) {
        t.suite("App: default skins: the first launch loads the first-run layout") {
            let source = try source(t, [
                "Stationery/Clock/Small.ini": widget, "Stationery/Clock/Medium.ini": widget,
                "Stationery/Weather/Medium.ini": widget, "Stationery/Weather/Small.ini": widget,
                "Stationery/@Resources/Variables.inc": "[Variables]\nClockHours=Auto\nLocation=timezone\n",
                "FirstRun.ini": """
                [Stationery\\Clock]
                File=Small.ini
                X=20
                Y=20
                [Stationery\\Missing]
                X=1
                Y=1
                [Stationery\\Weather]
                File=Medium.ini
                X=20
                Y=210
                """,
            ])
            let app = try app(t, source: source)
            app.installDefaultSkinsIfNeeded()
            let fm = FileManager.default
            t.check(fm.fileExists(atPath: app.skinsDirectory.appendingPathComponent("Stationery/Clock/Small.ini").path))
            t.check(!fm.fileExists(atPath: app.skinsDirectory.appendingPathComponent("FirstRun.ini").path),
                    "the layout file is not a root config")
            t.equal(app.state.data.defaultSkinsInstalled, DefaultSkins.version)
            t.check(DefaultSkins.version >= 3, "Stationery arrived with version 3")
            t.equal(app.state.data.shippedVariables["Stationery"], ["clockhours": "Auto", "location": "timezone"],
                    "what this version ships is recorded")

            // What the launch does once the layout is loaded (the Manage window) runs once, and knows the first one.
            var selectedThen: [String] = []
            app.loadActiveSkins { selectedThen.append(app.firstRunSelection) }
            t.equal(selectedThen, ["Stationery\\Clock"], "once the layout loaded (at once on the main thread)")
            let clock = app.controller(for: "Stationery\\Clock"), weather = app.controller(for: "Stationery\\Weather")
            t.equal(clock?.file, "Small.ini")
            t.equal(weather?.file, "Medium.ini")
            t.equal(app.controller(for: "Stationery\\Missing") == nil, true, "a config that is not there is left out")
            t.equal(app.firstRunSelection, "Stationery\\Clock", "the Manage window shows the first one")
            t.equal(app.controller(for: "Deskset\\Clock") == nil, true, "not the old single Clock")
            let screens = WindowGeometry.currentScreens()
            let visible = screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
            let height = WindowGeometry.primaryHeight(screens)
            if let clock, let weather {
                t.close(clock.topLeftPosition.x, Double(visible.minX) + 20, accuracy: 0.5)
                t.close(clock.topLeftPosition.y, Double(height - visible.maxY) + 20, accuracy: 0.5)
                t.close(weather.topLeftPosition.y, Double(height - visible.maxY) + 210, accuracy: 0.5)
                t.equal(app.state.skin("Stationery\\Weather")?.y, weather.topLeftPosition.y, "saved like a drag")
                // The windows have their size by now, so the Manage window can be placed beside them.
                t.equal(clock.window.frame.size, NSSize(width: 100, height: 40))
                t.equal(weather.window.frame.size, NSSize(width: 100, height: 40))
                let column = clock.window.frame.union(weather.window.frame)
                if let beside = ManageWindowController.frame(beside: column, size: NSSize(width: 900, height: 692),
                                                             minSize: NSSize(width: 780, height: 520), visible: visible) {
                    t.check(!beside.intersects(column), "the Manage window leaves the first widgets uncovered")
                }
            }
            t.equal(app.state.activeConfigs.map(\.config).sorted(), ["Stationery\\Clock", "Stationery\\Weather"])

            // The next launch loads the last session's skins where they were; the layout is for new users only.
            app.stopAllForTermination()
            app.state.saveNow()
            let again = AppController(state: AppState(fileURL: app.state.fileURL), skinsDirectory: app.skinsDirectory,
                                      layoutsDirectory: app.layoutsDirectory, backupsDirectory: app.backupsDirectory,
                                      defaultSkinsSource: source, settingsDirectory: app.settingsDirectory,
                                      presentsWindows: false)
            t.atSuiteEnd { again.stopAllForTermination() }
            let saved = again.state.skin("Stationery\\Weather")
            again.loadActiveSkins()
            t.equal(again.controller(for: "Stationery\\Weather")?.topLeftPosition.y, saved?.y)
            t.equal(again.controller(for: "Stationery\\Weather")?.file, "Medium.ini")
        }

        t.suite("App: default skins: without a first-run layout a new user gets the Clock") {
            // The Stationery Clock, small, as far as the first launch sees it.
            t.equal(DefaultSkins.firstClock.config, "Stationery\\Clock")
            t.equal(DefaultSkins.firstClock.file, "Small.ini")
            for layout in [nil, "[Nowhere\\Nothing]\nX=20\nY=20\n"] {
                var files = ["Stationery/Clock/Medium.ini": widget, "Stationery/Clock/Small.ini": widget,
                             "Stationery/System/Medium.ini": widget]
                if let layout { files[DefaultSkins.firstRunFileName] = layout }
                let root = try source(t, files)
                let app = try app(t, source: root)
                app.installDefaultSkinsIfNeeded()
                var then = 0
                app.loadActiveSkins { then += 1 }
                t.equal(then, 1, "what follows the load runs once")
                t.equal(app.controller(for: "Stationery\\Clock")?.file, "Small.ini", layout ?? "no layout file")
                t.equal(app.state.activeConfigs.map(\.config), ["Stationery\\Clock"])
                t.equal(app.firstRunSelection, "Stationery\\Clock")
            }
            // The root configs: folders only, not files, hidden or @ folders.
            let mixed = try source(t, ["A/A.ini": widget, "FirstRun.ini": "", ".Hidden/H.ini": widget, "@Vault/x.txt": "x"])
            t.equal(DefaultSkins.rootConfigs(in: mixed)?.map(\.lastPathComponent), ["A"])
        }
    }

    // MARK: Stationery.inc

    static func stationeryFileTests(_ t: AppTestRunner) {
        t.suite("App: default skins: Stationery.inc exists for the widgets to save into") {
            let app = try app(t, source: nil)
            let url = app.settingsDirectory.appendingPathComponent("Stationery.inc")
            t.check(!FileManager.default.fileExists(atPath: url.path))
            app.ensureStationeryFile()
            let made = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            t.check(made.hasPrefix("; Deskset keeps what you type into the Stationery widgets"), made)
            t.equal(DefaultSkins.variables(in: url), nil, "no settings in it yet")
            // What a widget does: !WriteKeyValue writes only into a file that exists.
            try IniWriter.writeValue("Buy milk", key: "Todo1", section: "Variables", fileURL: url)
            try IniWriter.writeValue("北京", key: "City2", section: "Variables", fileURL: url)
            t.equal(DefaultSkins.variables(in: url), ["todo1": "Buy milk", "city2": "北京"])
            app.ensureStationeryFile()
            t.equal(DefaultSkins.variables(in: url)?["todo1"], "Buy milk", "never overwritten")
            try FileManager.default.removeItem(at: url)
            app.ensureStationeryFile()
            t.check(FileManager.default.fileExists(atPath: url.path), "a deleted file comes back empty")
            t.equal(DefaultSkins.variables(in: url), nil)
        }
    }

    // MARK: What the widgets keep in their own files

    /// Widgets that keep a state of their own in their files (`!WriteKeyValue`) ship it at rest: the Turntable's tempo
    /// is Rest (an update a second) until a record plays. A self-test that ran a widget in the repository's folder while a
    /// player was playing once left it at Live, and every new install then ran 30 updates a second until the deck noticed.
    static func shippedStateTests(_ t: AppTestRunner) {
        t.suite("App: default skins: the widgets ship their own state at rest") {
            guard let source = Paths.repositoryFolder("DefaultSkins") else {
                print("    (skipped: DefaultSkins not found; run from the repository)")
                return
            }
            let url = source.appendingPathComponent("Stationery/Turntable/Large.ini")
            let variables = IniDocument.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .section(named: "Variables")
            t.equal(variables?.value(forKey: "Tempo"), "Rest", "the Turntable's tempo")
            t.equal(variables?.value(forKey: "TempoLive"), "0")
        }
    }

    /// The repository's default skins, file by file (path under DefaultSkins → contents); empty outside the repository.
    static func fingerprint() -> [String: Data] {
        guard let root = Paths.repositoryFolder("DefaultSkins"),
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [:] }
        var result: [String: Data] = [:]
        let prefix = root.resolvingSymlinksInPath().path.count
        for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result[String(url.resolvingSymlinksInPath().path.dropFirst(prefix))] = try? Data(contentsOf: url)
        }
        return result
    }

    // MARK: Upgrades

    static func upgradeTests(_ t: AppTestRunner) {
        t.suite("App: default skins: an upgrade keeps what the user changed, not the old defaults") {
            let fm = FileManager.default
            let newVariables = """
            [Variables]
            Theme=Dark
            ClockHours=Auto
            WeekStart=Auto
            DateFormat=%B %#d
            Location=timezone
            """
            let source = try source(t, ["Deskset/Clock/Small.ini": widget, "Deskset/@Resources/Variables.inc": newVariables])
            func userCopy(_ app: AppController, _ text: String) throws {
                let inc = app.skinsDirectory.appendingPathComponent("Deskset/@Resources/Variables.inc")
                try fm.createDirectory(at: inc.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: inc, atomically: true, encoding: .utf8)
            }
            func installed(_ app: AppController) -> [String: String] {
                DefaultSkins.variables(in: app.skinsDirectory.appendingPathComponent("Deskset/@Resources/Variables.inc")) ?? [:]
            }

            // From Deskset 0.1 (version 2, which recorded nothing): its own defaults give way to the new ones.
            let v2 = try app(t, source: source, state: #"{"defaultSkinsInstalled": 2, "skins": {}}"#)
            let edited = DefaultSkins.version2Variables
                .replacingOccurrences(of: "Theme=Dark", with: "Theme=Light")
                .replacingOccurrences(of: "WeekStart=0", with: "WeekStart=1")
            try userCopy(v2, edited)
            v2.installDefaultSkinsIfNeeded()
            let after = installed(v2)
            t.equal(after["theme"], "Light", "changed by the user: kept")
            t.equal(after["weekstart"], "1", "changed by the user: kept")
            t.equal(after["clockhours"], "Auto", "0.1's 24-hour default gives way to Automatic")
            t.equal(after["dateformat"], "%B %#d", "0.1's date format gives way to the new one")
            t.equal(after["location"], "timezone", "a new key keeps its default")
            t.check(fm.fileExists(atPath: v2.backupsDirectory.appendingPathComponent("Deskset-examples-v2/@Resources/Variables.inc").path),
                    "the old copy is kept in Backups")
            t.equal(v2.state.data.shippedVariables["Deskset"]?["clockhours"], "Auto")

            // A later upgrade reads what the installed version recorded.
            let recorded = try app(t, source: try self.source(t, ["Deskset/@Resources/Variables.inc":
                "[Variables]\nClockHours=12\nWeekStart=Auto\nLocation=timezone\nLocationConfirmed=0\n"]),
                state: #"{"defaultSkinsInstalled": 2, "shippedVariables": {"Deskset": {"clockhours": "Auto", "weekstart": "Auto", "location": "timezone", "locationconfirmed": "0"}}}"#)
            try userCopy(recorded, "[Variables]\nClockHours=Auto\nWeekStart=2\nLocation=Beijing\nLocationConfirmed=1\n")
            recorded.installDefaultSkinsIfNeeded()
            let later = installed(recorded)
            t.equal(later["clockhours"], "12", "never changed: the new default")
            t.equal(later["weekstart"], "2")
            t.equal(later["location"], "Beijing", "a city the user chose stays")
            t.equal(later["locationconfirmed"], "1")

            // Nothing known about the old copy (a folder of the same name from elsewhere): every value that differs is
            // carried over, as before.
            let unknown = try app(t, source: source, state: #"{"defaultSkinsInstalled": 0}"#)
            try userCopy(unknown, "[Variables]\nClockHours=24\nTheme=Dark\n")
            unknown.installDefaultSkinsIfNeeded()
            t.equal(installed(unknown)["clockhours"], "24")
            t.equal(DefaultSkins.shippedVariables(root: "Deskset", version: 0), nil)
            t.equal(DefaultSkins.shippedVariables(root: "Other", version: 2), nil)
            t.equal(DefaultSkins.shippedVariables(root: "Deskset", version: 2)?["clockhours"], "24")
        }

        t.suite("App: default skins: 0.1's Variables.inc is what the app remembers of it") {
            // The table an upgrade of a Deskset root compares with must be the file version 2 shipped: the example
            // skins of Deskset 0.1, kept in TestSkins since the Stationery suite replaced them in DefaultSkins.
            guard let repository = Paths.repositoryFolder("TestSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            let shipped = DefaultSkins.variables(in: repository.appendingPathComponent("Deskset/@Resources/Variables.inc"))
            t.equal(DefaultSkins.variables(inText: DefaultSkins.version2Variables), shipped,
                    "the remembered table matches 0.1's file")
            t.equal(shipped?["clockhours"], "24")
        }

        t.suite("App: default skins: an upgrade from 0.1 adds Stationery and leaves the old example skins alone") {
            // What Deskset 0.1 left: its example skins in the Skins folder, the Clock loaded, version 2 installed.
            let fm = FileManager.default
            let source = try source(t, [
                "Stationery/Clock/Small.ini": widget, "Stationery/Weather/Medium.ini": widget,
                "Stationery/@Resources/Variables.inc": "[Variables]\nClockHours=Auto\n",
                "FirstRun.ini": "[Stationery\\Clock]\nFile=Small.ini\nX=20\nY=20\n",
            ])
            let app = try app(t, source: source, state: #"{"defaultSkinsInstalled": 2, "skins": {"Deskset\\Clock": {"file": "Clock.ini", "active": true}}}"#)
            let old = app.skinsDirectory.appendingPathComponent("Deskset")
            let files = ["Clock/Clock.ini": widget, "@Resources/Variables.inc": "[Variables]\nClockHours=12\nTheme=Light\n",
                         "Clock/Edited.ini": widget + "; the user's own variant\n"]
            for (path, text) in files {
                let url = old.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            app.installDefaultSkinsIfNeeded()
            t.check(fm.fileExists(atPath: app.skinsDirectory.appendingPathComponent("Stationery/Clock/Small.ini").path),
                    "the new suite is installed")
            for (path, text) in files {
                t.equal(try? String(contentsOf: old.appendingPathComponent(path), encoding: .utf8), text,
                        "\(path) stays as the user left it")
            }
            t.check(!fm.fileExists(atPath: app.backupsDirectory.appendingPathComponent("Deskset-examples-v2").path),
                    "nothing of the old suite is moved away")
            t.equal(app.state.data.defaultSkinsInstalled, DefaultSkins.version)
            t.equal(DefaultSkins.variables(in: app.skinsDirectory.appendingPathComponent("Stationery/@Resources/Variables.inc")),
                    ["clockhours": "Auto"], "the new suite starts from its own defaults")

            // The user's desktop comes back as it was: the first-run layout is for new users only.
            app.loadActiveSkins()
            t.equal(app.controller(for: "Deskset\\Clock")?.file, "Clock.ini")
            t.equal(app.controller(for: "Stationery\\Clock") == nil, true, "the new Clock waits in the Manage window")
            t.equal(app.state.activeConfigs.map(\.config), ["Deskset\\Clock"])
        }
    }
}
