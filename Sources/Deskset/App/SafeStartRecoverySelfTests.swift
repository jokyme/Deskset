import AppKit
import DesksetCore

/// Startup recovery uses temporary settings, layouts and skins; no fixture loads the user's desktop.
enum SafeStartRecoverySelfTests {
    static func run(_ t: AppTestRunner) {
        transactionTests(t)
        failureTests(t)
        planTests(t)
        for mode in [SkinThreading.main, .engine, .pool] {
            for savePosition in [true, false] { loadTests(t, mode, savePosition: savePosition) }
        }
    }

    private static func transactionTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start: backup precedes the atomic empty-state commit and notification") {
            let app = try fixture(t)
            let old = app.state.data
            let oldBytes = try Data(contentsOf: app.state.fileURL)
            let oldValue = try value(old)
            app.sessionPositions["broken\\old"] = (700, 500)
            var steps: [String] = []
            var notifications = 0
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: nil) { _ in
                notifications += 1
                t.check(app.state.data.skins.isEmpty && app.state.data.hasLoadedLayout)
                t.check(app.sessionPositions.isEmpty, "session positions clear before the committed state is announced")
            }
            defer { NotificationCenter.default.removeObserver(token) }
            try app.prepareSafeStartRecovery(saveBackup: { document in
                t.equal(try value(app.state.data), oldValue)
                t.equal(try Data(contentsOf: app.state.fileURL), oldBytes)
                t.equal(notifications, 0)
                t.check(document.wallpaper == nil)
                t.equal(document.ini.section(named: "Broken\\Old")?["Active"], "1")
                t.equal(document.ini.section(named: "Broken\\Old")?["FutureSkinOption"], "retained")
                try app.layoutStore.save(document, named: "@Backup")
                steps.append("backup")
            }, writeState: { bytes, destination in
                t.equal(steps, ["backup"])
                t.equal(try value(app.state.data), oldValue, "memory changes only after the writer succeeds")
                t.equal(try Data(contentsOf: destination), oldBytes)
                t.equal(app.sessionPositions["broken\\old"]?.0, 700)
                t.equal(notifications, 0)
                let candidate = try JSONDecoder().decode(AppStateData.self, from: bytes)
                var expected = old
                expected.skins = [:]; expected.skinOrder = []; expected.hasLoadedLayout = true
                t.equal(try value(candidate), try value(expected), "only the desktop and intentional-layout flag change")
                try bytes.write(to: destination, options: .atomic)
                steps.append("state")
            })
            t.equal(steps, ["backup", "state"])
            t.equal(notifications, 1)
            t.check(app.controllers.isEmpty, "no saved skin was loaded to capture its backup")
            t.equal(app.state.data.skinOrder, [])
            t.equal(app.state.data.favorites, old.favorites)
            t.equal(app.state.data.rainmeterOptions, old.rainmeterOptions)
            t.equal(app.state.data.trayMeasureOptions, old.trayMeasureOptions)
            t.equal(app.state.data.editor, old.editor)
            t.equal(app.state.data.updates, old.updates)
            t.equal(app.state.data.unknownKeys, old.unknownKeys)
            t.equal(try value(AppState(fileURL: app.state.fileURL).data), try value(app.state.data))
            let backup = try app.layoutStore.read(named: "@Backup", includeWallpaper: false)
            t.equal(backup.ini.section(named: "Broken\\Old")?["WindowX"], "40%R@1")
            t.equal(backup.ini.section(named: "Rainmeter")?["FutureSetting"], "retained")
        }

        t.suite("App: Safe Start: an atomic state commit clears obsolete selection snapshots") {
            let app = try fixture(t)
            app.state.beginSkinSelection("Broken\\Old")
            app.state.update("Broken\\Old") { $0.alphaValue = 99 }
            try app.prepareSafeStartRecovery()
            app.state.update("Broken\\Old") { $0.file = "Other.ini"; $0.alphaValue = 123 }
            app.state.saveNow()
            let saved = AppState(fileURL: app.state.fileURL)
            t.equal(saved.skin("Broken\\Old")?.file, "Other.ini")
            t.equal(saved.skin("Broken\\Old")?.alphaValue, 123, "a later skin is not replaced by the discarded selection")
        }
    }

    private static func failureTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start: a failed backup cannot write state or clear the saved session") {
            let app = try fixture(t)
            let before = try value(app.state.data)
            let bytes = try Data(contentsOf: app.state.fileURL)
            app.sessionPositions["broken\\old"] = (700, 500)
            var writes = 0, notifications = 0
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: nil) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            do {
                try app.prepareSafeStartRecovery(saveBackup: { _ in throw POSIXError(.EIO) },
                                                 writeState: { _, _ in writes += 1 })
                t.check(false, "the backup error must reach startup")
            } catch { t.check(error is POSIXError) }
            t.equal(writes, 0)
            t.equal(notifications, 0)
            t.equal(try value(app.state.data), before)
            t.equal(try Data(contentsOf: app.state.fileURL), bytes)
            t.equal(app.sessionPositions["broken\\old"]?.0, 700)
            t.check(app.controllers.isEmpty)
        }

        t.suite("App: Safe Start: failed candidate writing leaves memory and disk unchanged after backup") {
            let app = try fixture(t)
            let before = try value(app.state.data)
            let bytes = try Data(contentsOf: app.state.fileURL)
            app.sessionPositions["broken\\old"] = (700, 500)
            var notifications = 0
            let token = NotificationCenter.default.addObserver(forName: .desksetSkinsChanged, object: app,
                                                               queue: nil) { _ in notifications += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            do {
                try app.prepareSafeStartRecovery(writeState: { _, _ in
                    t.check(app.layoutStore.contains(named: "@Backup"))
                    throw POSIXError(.ENOSPC)
                })
                t.check(false, "the state write error must reach startup")
            } catch { t.check(error is POSIXError) }
            t.equal(notifications, 0)
            t.equal(try value(app.state.data), before)
            t.equal(try Data(contentsOf: app.state.fileURL), bytes)
            t.equal(app.sessionPositions["broken\\old"]?.0, 700)
            t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "Broken\\Old")?["Active"], "1")
            t.check(app.controllers.isEmpty)
        }

        t.suite("App: Safe Start: filesystem backup and state errors propagate without an old-skin fallback") {
            let app = try fixture(t)
            let before = try value(app.state.data)
            let bytes = try Data(contentsOf: app.state.fileURL)
            try FileManager.default.createDirectory(at: app.layoutsDirectory, withIntermediateDirectories: true)
            let blocked = app.layoutsDirectory.appendingPathComponent("@Backup")
            try Data("not a layout directory".utf8).write(to: blocked)
            do { try app.prepareSafeStartRecovery(); t.check(false, "an unsafe backup item rejects recovery") }
            catch { t.check(error is LayoutStoreError) }
            t.equal(try value(app.state.data), before)
            t.equal(try Data(contentsOf: app.state.fileURL), bytes)
            try FileManager.default.removeItem(at: blocked)
            try FileManager.default.removeItem(at: app.state.fileURL)
            try FileManager.default.createDirectory(at: app.state.fileURL, withIntermediateDirectories: true)
            do { try app.prepareSafeStartRecovery(); t.check(false, "writing over a directory must fail") }
            catch { t.check(true) }
            t.equal(try value(app.state.data), before)
            t.check(app.controllers.isEmpty)
        }

        t.suite("App: Safe Start: recovery rejects an already running desktop") {
            let app = try fixture(t)
            guard let skin = app.activate(config: "Broken\\Old", file: "Broken.ini") else {
                return t.check(false, "the temporary skin loads")
            }
            let before = try value(app.state.data)
            var boundaries = 0
            do {
                try app.prepareSafeStartRecovery(saveBackup: { _ in boundaries += 1 },
                                                 writeState: { _, _ in boundaries += 1 })
                t.check(false, "startup recovery cannot replace a running desktop")
            } catch { t.check(error is SafeStartRecoveryError) }
            t.equal(boundaries, 0)
            t.equal(try value(app.state.data), before)
            t.check(app.controller(for: skin.config) === skin && !skin.isStopped)
        }
    }

    private static func planTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start: the manifest selects exact bundled variants without remembered-file fallback") {
            let app = try fixture(t, files: [
                "FirstRun.ini": "[Defaults\\Card]\nFile=Exact.ini\nX=40\nY=60\n"
                    + "[Defaults\\NoFile]\nX=80\nY=90\n"
                    + "[defaults\\matching]\nFile=exact.ini\nX=120\nY=140\n"
                    + "[Defaults\\NotBundled]\nFile=Extra.ini\n",
                "Defaults/Card/Exact.ini": widget,
                "Defaults/NoFile/A.ini": widget, "Defaults/NoFile/B.ini": widget,
                "Defaults/Matching/Exact.ini": widget,
            ], installDefaults: false)
            try writeInstalled(app, "Defaults\\Card", "Other.ini")
            try writeInstalled(app, "Defaults\\NoFile", "B.ini")
            try writeInstalled(app, "Defaults\\Matching", "eXACT.ini")
            try writeInstalled(app, "Defaults\\NotBundled", "Extra.ini")
            app.state.update("Defaults\\Card") { $0.file = "Other.ini" }
            app.state.update("Defaults\\NoFile") { $0.file = "B.ini" }
            let before = try value(app.state.data)
            let plan = app.safeStartLayout()
            t.equal(plan.map(\.config), ["Defaults\\Matching"])
            t.equal(plan.map { $0.entry.file }, ["eXACT.ini"])
            t.equal(plan.first?.entry.x, 120)
            t.equal(plan.first?.entry.y, 140)
            t.equal(try value(app.state.data), before, "resolving a default plan does not preseed skin state")
            t.check(app.controllers.isEmpty)
            try app.prepareSafeStartRecovery()
            t.check(app.activate(config: "Defaults\\Card", file: "Exact.ini", exactFile: true) == nil)
            t.check(app.controller(for: "Defaults\\Card") == nil)
            t.check(app.state.skin("Defaults\\Card") == nil, "a missing exact variant does not choose Other.ini")
        }

        for manifest in [Optional<String>.none, "", "[Missing\\Default]\nFile=Missing.ini\n"] {
            t.suite("App: Safe Start: unavailable defaults finish once on an intentional empty desktop (\(manifest ?? "missing"))") {
                var files = ["Stationery/Clock/Small.ini": widget]
                if let manifest { files[DefaultSkins.firstRunFileName] = manifest }
                let app = try fixture(t, files: files)
                try app.prepareSafeStartRecovery()
                var completed = 0
                app.loadSafeStartLayout { completed += 1 }
                t.equal(completed, 1)
                t.check(app.controllers.isEmpty && app.state.data.skins.isEmpty)
                t.check(app.state.data.hasLoadedLayout)
                app.loadActiveSkins { completed += 1 }
                t.equal(completed, 2, "even a later ordinary load cannot take the first-launch Clock fallback")
                t.check(app.controllers.isEmpty)
                t.check(AppState(fileURL: app.state.fileURL).data.hasLoadedLayout)
            }
        }
    }

    private static func loadTests(_ t: AppTestRunner, _ mode: SkinThreading, savePosition: Bool) {
        t.suite("App: Safe Start: first-load defaults and full-size manifest placement survive recovery (\(mode), SavePosition=\(savePosition))") {
            let text = """
            [Rainmeter]
            Update=-1
            DefaultWindowX=500
            DefaultWindowY=350
            DefaultAnchorX=50%
            DefaultAnchorY=50%
            DefaultKeepOnScreen=0
            DefaultSnapEdges=0
            DefaultAlwaysOnTop=1
            DefaultClickThrough=1
            DefaultAlphaValue=180
            DefaultDraggable=0
            DefaultSavePosition=\(savePosition ? 1 : 0)
            [Card]
            Meter=Image
            W=200
            H=100
            SolidColor=40,70,90,255
            """
            let app = try fixture(t, mode: mode, files: [
                "Defaults/Card/Exact.ini": text, "Defaults/Card/Other.ini": widget,
                "FirstRun.ini": "[Defaults\\Card]\nFile=Exact.ini\nX=80\nY=90\n",
            ])
            app.sessionPositions["defaults\\card"] = (900, 650)
            try app.prepareSafeStartRecovery()
            t.check(app.state.skin("Defaults\\Card") == nil, "the empty candidate keeps firstLoad true")
            var completed = 0
            app.loadSafeStartLayout { completed += 1 }
            t.check(AppSelfTest.spin(timeout: 30) { completed == 1 })
            guard let card = app.controller(for: "Defaults\\Card") else {
                return t.check(false, "the exact default skin loads")
            }
            drain(t, app)
            t.equal(completed, 1)
            t.equal(app.sortedControllers.map(\.config), ["Defaults\\Card"], "the old desktop never loads")
            t.equal(card.file, "Exact.ini")
            t.equal(card.state.anchorX, "50%")
            t.equal(card.state.anchorY, "50%")
            t.equal(card.state.savePosition, savePosition)
            t.equal(card.state.alwaysOnTop, 1)
            t.check(!card.state.draggable && card.state.clickThrough && !card.state.snapEdges)
            t.equal(card.state.alphaValue, 180)
            let zoom = card.effectiveZoomFactor
            t.close(Double(card.window.frame.width), 200 * zoom)
            t.close(Double(card.window.frame.height), 100 * zoom)
            let screens = WindowGeometry.currentScreens()
            let visible = screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
            let primaryHeight = WindowGeometry.primaryHeight(screens)
            let x = Double(visible.minX) + 80, y = Double(primaryHeight - visible.maxY) + 90
            t.close(card.topLeftPosition.x, x, accuracy: 1)
            t.close(card.topLeftPosition.y, y, accuracy: 1)
            let saved = card.state
            if savePosition {
                let point = WindowPosition.resolve(x: saved.windowX ?? "0", y: saved.windowY ?? "0",
                    anchorX: saved.anchorX ?? "0", anchorY: saved.anchorY ?? "0", skinSize: card.window.frame.size,
                    screens: screens, zoomFactor: zoom)
                t.close(point?.x ?? .nan, x, accuracy: 1, "the saved anchor uses the real window size")
                t.close(point?.y ?? .nan, y, accuracy: 1)
            } else {
                t.equal(saved.windowX, "500")
                t.equal(saved.windowY, "350", "a temporary manifest move preserves the initial default position")
            }
            app.sessionPositions.removeAll()
            guard let reloaded = app.refresh(card) else { return t.check(false, "the default skin reloads") }
            t.check(AppSelfTest.spin(timeout: 30) { reloaded.isStarted })
            drain(t, app)
            let restored = WindowPosition.resolve(x: saved.windowX ?? "0", y: saved.windowY ?? "0",
                anchorX: saved.anchorX ?? "0", anchorY: saved.anchorY ?? "0", skinSize: reloaded.window.frame.size,
                screens: screens, zoomFactor: zoom)
            t.close(reloaded.topLeftPosition.x, restored?.x ?? .nan, accuracy: 1)
            t.close(reloaded.topLeftPosition.y, restored?.y ?? .nan, accuracy: 1)
            t.equal(reloaded.state.anchorX, "50%")
        }
    }

    private static let widget = "[Rainmeter]\nUpdate=-1\n[Card]\nMeter=Image\nW=100\nH=40\nSolidColor=40,70,90,255\n"

    private static func fixture(_ t: AppTestRunner, mode: SkinThreading = .main,
                                files: [String: String] = [:], installDefaults: Bool = true) throws -> AppController {
        EnvironmentStore.shared.publish()
        let root = t.temporaryDirectory("safe-start-recovery")
        let source = root.appendingPathComponent("DefaultSkins")
        let skins = root.appendingPathComponent("Skins")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        for (path, text) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        if installDefaults {
            for folder in DefaultSkins.rootConfigs(in: source) ?? [] {
                try FileManager.default.copyItem(at: folder, to: skins.appendingPathComponent(folder.lastPathComponent))
            }
        }
        var original = AppStateData()
        var bad = SkinState(file: "Broken.ini")
        bad.windowX = "40%R@1"; bad.windowY = "50%B@1"
        bad.anchorX = "25%"; bad.layoutOptions["FutureSkinOption"] = "retained"
        bad.unknownKeys["futureSkin"] = .bool(true)
        original.skins = ["Broken\\Old": bad]
        original.skinOrder = ["Broken\\Old"]
        original.favorites = [SkinFavorite(config: "Broken\\Old", file: "Broken.ini")!]
        original.rainmeterOptions = ["dIsAbLeDrAgGiNg": "1", "Logging": "0", "DefaultZoom": "150",
                                     "FutureSetting": "retained"]
        original.trayMeasureOptions = ["Measure": "Calc", "Formula": "2"]
        original.editor.codeEditor = .systemDefault
        original.editor.codeFontSize = 17
        original.editor.liveReload = false
        original.updates.automaticallyChecks = false
        original.updates.skippedVersion = "9.9.9"
        original.updates.unknownKeys["futureUpdate"] = .array([.bool(true), .number(3)])
        original.defaultSkinsInstalled = DefaultSkins.version
        original.shippedVariables = ["Defaults": ["theme": "Original"]]
        original.settingsPane = "editor"
        original.unknownKeys["futureApp"] = .object(["preserved": .string("yes")])
        let stateURL = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(original).write(to: stateURL, options: .atomic)
        let app = AppController(state: AppState(fileURL: stateURL), skinsDirectory: skins,
                                layoutsDirectory: root.appendingPathComponent("Layouts"),
                                backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: source,
                                settingsDirectory: root, presentsWindows: false, threading: mode,
                                system: NetworkStatisticsRuntimeSelfTests.TestSystem())
        try writeInstalled(app, "Broken\\Old", "Broken.ini")
        try writeInstalled(app, "Broken\\Old", "Other.ini")
        t.atSuiteEnd {
            let threads = (app.engineThread.map { [$0] } ?? []) + (app.skinThreadPool?.activeWorkers ?? [])
            app.stopAllForTermination()
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { threads.allSatisfy(\.hasExited) }, "Safe Start fixture threads exited")
        }
        return app
    }

    private static func writeInstalled(_ app: AppController, _ config: String, _ file: String) throws {
        let directory = SkinLibrary.directory(for: config, root: app.skinsDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try widget.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        app.rescanLibrary()
    }

    private static func value(_ data: AppStateData) throws -> JSONValue {
        try JSONValue.parse(JSONEncoder().encode(data))
    }

    private static func drain(_ t: AppTestRunner, _ app: AppController) {
        for _ in 0..<2 {
            for controller in app.sortedControllers {
                t.equal(controller.runtime.exclusive(timeout: 30) { _ in true }, true)
            }
            t.check(ServiceThreadingSelfTests.drainMainQueue(), "Safe Start window requests drained")
        }
    }
}
