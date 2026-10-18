import AppKit
import DesksetCore

/// Original INI fixtures exercise public layout entry points with isolated app state and fake desktop pictures.
enum LayoutsSelfTests {
    static func run(_ t: AppTestRunner) {
        t.suite("App: Layouts: loading replaces configs and preserves application preferences") {
            guard let app = try AppSelfTest.makeApp(t), let old = app.activate(config: "App\\Focus", file: "Focus.ini")
            else { return }
            app.state.setDefaultSkinsInstalled(91)
            app.state.setShippedVariables(["Unchanged": ["value": "yes"]])
            app.state.updateUpdates { $0.automaticallyChecks = false }
            app.state.setSettingsPane("editor")
            app.state.update("App\\Focus") { $0.x = 91; $0.y = 47 }
            app.sessionPositions["app\\controls"] = (900, 800)
            try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("""
            [Rainmeter]
            ConfigEditor=AuthorEditor
            SkinPath=C:\\Author\\Skins
            [App\\Controls]
            Active=1
            WindowX=37
            WindowY=62
            KeepOnScreen=0
            SavePosition=0
            [App\\Focus]
            Active=0
            """)), named: "Work")
            t.check(load(app, "Work"))
            t.check(old.isStopped)
            t.equal(app.controller(for: "App\\Focus"), nil)
            t.equal(app.controller(for: "App\\Controls")?.file, "Controls.ini")
            let point = app.controller(for: "App\\Controls")?.topLeftPosition
            t.close(point?.x ?? -1, 37)
            t.close(point?.y ?? -1, 62)
            t.equal(app.state.data.defaultSkinsInstalled, 91)
            t.equal(app.state.data.shippedVariables, ["Unchanged": ["value": "yes"]])
            t.check(!app.state.updates.automaticallyChecks)
            t.equal(app.state.data.settingsPane, "editor")
            t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "App\\Focus")?["Active"], "0",
                    "Focus.ini deactivates itself in OnCloseAction before the backup is captured")
            t.check(app.state.data.hasLoadedLayout)
        }

        t.suite("App: Layouts: empty layouts survive restart and @Backup remains unchanged when loaded") {
            guard let app = try AppSelfTest.makeApp(t), app.activate(config: "App\\Focus", file: "Compact.ini") != nil
            else { return }
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            t.check(load(app, "Empty"))
            t.equal(app.controllers.count, 0)
            let restoredState = AppState(fileURL: app.state.fileURL)
            let restarted = AppController(state: restoredState, skinsDirectory: app.skinsDirectory,
                                          layoutsDirectory: app.layoutsDirectory, defaultSkinsSource: nil,
                                          presentsWindows: false)
            restarted.loadActiveSkins()
            t.equal(restarted.controllers.count, 0, "an intentionally empty desktop is not a first launch")
            t.check(load(app, "@Backup"))
            t.check(app.controller(for: "App\\Focus") != nil)
            t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "App\\Focus")?["Active"], "1",
                    "loading the backup does not replace it with the empty desktop")
            t.check(load(app, "@Backup"))
            t.check(app.controller(for: "App\\Focus") != nil, "reloading the same backup restores the same desktop")
        }

        t.suite("App: Layouts: missing layouts leave the desktop intact and failed backups restore its session") {
            guard let app = try AppSelfTest.makeApp(t), let old = app.activate(config: "App\\Focus", file: "Focus.ini")
            else { return }
            t.check(!load(app, "Missing"))
            t.check(app.controller(for: "App\\Focus") === old && !old.isStopped)
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            let unsafe = app.layoutsDirectory.appendingPathComponent("@Backup")
            try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: app.skinsDirectory)
            t.check(!load(app, "Empty"))
            t.check(old.isStopped)
            t.equal(app.controller(for: "App\\Focus")?.file, "Focus.ini", "a backup IO failure restores the session")
        }

        t.suite("App: Layouts: wallpapers are optional and use the injectable BMP boundary") {
            guard let app = try AppSelfTest.makeApp(t), let pictures = app.layoutWallpaper as? MemoryLayoutWallpaper
            else { return }
            pictures.bitmap = Data([0x42, 0x4D, 1])
            try app.saveLayout(named: "Picture", options: LayoutSaveOptions(includeWallpaper: true))
            try app.saveLayout(named: "No picture", options: LayoutSaveOptions())
            pictures.bitmap = Data([0x42, 0x4D, 2])
            t.check(load(app, "No picture"))
            t.equal(pictures.bitmap, Data([0x42, 0x4D, 2]))
            t.equal(pictures.applied.count, 0)
            t.check(load(app, "Picture"))
            t.equal(pictures.bitmap, Data([0x42, 0x4D, 1]))
            t.equal(try app.layoutStore.read(named: "@Backup").wallpaper, nil,
                    "the automatic backup contains settings; it does not add an implicit wallpaper save")
            try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("[Rainmeter]\n"),
                                                    wallpaper: Data([0x42, 0x4D, 9])), named: "@Backup")
            t.check(load(app, "@Backup"))
            t.equal(pictures.bitmap, Data([0x42, 0x4D, 1]), "@Backup never changes the wallpaper")
            t.equal(try app.layoutStore.read(named: "@Backup").wallpaper, Data([0x42, 0x4D, 9]),
                    "the stored backup remains untouched")
        }

        t.suite("App: Layouts: native Active indices do not fall back to another variant") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("""
            [App\\Focus]
            Active=99
            [NotInstalled]
            Active=1
            """)), named: "Missing variants")
            t.check(load(app, "Missing variants"))
            t.equal(app.controllers.count, 0)
            t.equal(app.state.skin("App\\Focus")?.activeVariant, 99)
            app.loadActiveSkins()
            t.equal(app.controllers.count, 0, "reopening still cannot select the wrong file")
        }

        t.suite("App: Layouts: an unencodable macOS desktop picture cannot block a layout switch") {
            guard let base = try AppSelfTest.makeApp(t) else { return }
            let wallpaper = UnavailableWallpaper()
            let app = AppController(state: base.state, skinsDirectory: base.skinsDirectory,
                                    layoutsDirectory: base.layoutsDirectory, presentsWindows: false,
                                    layoutWallpaper: wallpaper)
            defer { _ = app.stopAllForTermination() }
            _ = app.activate(config: "App\\Focus", file: "Focus.ini")
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            do {
                try app.saveLayout(named: "Explicit picture", options: LayoutSaveOptions(includeWallpaper: true))
                t.check(false, "an explicit Include wallpaper request reports its failure")
            } catch { t.check(true) }
            t.equal(wallpaper.captureAttempts, 1, "only the explicit Include wallpaper save requests a picture")
            t.check(load(app, "Empty"), "automatic skin-state backup still succeeds")
            t.equal(wallpaper.captureAttempts, 1, "the automatic backup never attempts to read the current picture")
            t.equal(app.controllers.count, 0)
            t.equal(try app.layoutStore.read(named: "@Backup").wallpaper, nil)
            t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "App\\Focus")?["Active"], "0",
                    "the saved settings include Focus.ini's close-time self deactivation")
        }

        t.suite("App: Layouts: a wallpaper failure restores skins without replacing per-display rollback") {
            guard let base = try AppSelfTest.makeApp(t) else { return }
            let wallpaper = RejectingWallpaper()
            let app = AppController(state: base.state, skinsDirectory: base.skinsDirectory,
                                    layoutsDirectory: base.layoutsDirectory, presentsWindows: false,
                                    layoutWallpaper: wallpaper)
            defer { _ = app.stopAllForTermination() }
            _ = app.activate(config: "App\\Focus", file: "Focus.ini")
            try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("[Rainmeter]\n"),
                                                    wallpaper: Data([0x42, 0x4D, 3])), named: "Rejected picture")
            t.check(!load(app, "Rejected picture"))
            t.equal(app.controller(for: "App\\Focus")?.file, "Focus.ini", "the previous skin set is restored")
            t.equal(wallpaper.applied, [Data([0x42, 0x4D, 3])],
                    "the coordinator does not overwrite the wallpaper boundary's per-display rollback")
        }

        t.suite("App: Layouts: main and engine loads keep INI order and collect configs activated during close") {
            for mode in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                try writeSkin(app, "Layout\\Old", "[!ActivateConfig Layout\\Zombie Zombie.ini][!Draggable 0]")
                try writeSkin(app, "Layout\\Zombie", "[!Draggable 0]")
                try writeSkin(app, "Layout\\Zed")
                try writeSkin(app, "Layout\\Alpha")
                app.rescanLibrary()
                let old = app.activate(config: "Layout\\Old", file: "Old.ini")
                t.check(AppSelfTest.spin { old?.isStarted == true })
                try app.saveLayout(named: "Old", options: LayoutSaveOptions())
                try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("""
                [Layout\\Zed]
                Active=1
                LoadOrder=1
                [Layout\\Alpha]
                Active=1
                LoadOrder=1
                """)), named: "Ordered")
                t.check(load(app, "Ordered"))
                t.check(AppSelfTest.spin { old?.hasClosed == true })
                t.equal(app.sortedControllers.map(\.config), ["Layout\\Zed", "Layout\\Alpha"])
                t.equal(app.controller(for: "Layout\\Zombie"), nil, "a config activated during close is closed before commit")
                t.equal(app.controller(for: "Layout\\Old"), nil)
                let backup = try app.layoutStore.read(named: "@Backup").ini
                t.equal(backup.section(named: "Layout\\Old")?["Draggable"], "0")
                t.equal(backup.section(named: "Layout\\Zombie")?["Active"], "1",
                        "\(mode): the close action activates its config before the backup is captured")
                t.equal(backup.section(named: "Layout\\Zombie")?["Draggable"], "0",
                        "\(mode): the newly activated config's own close action also finishes before backup")
                if let old {
                    t.check(app.layouts.isRetired(old), "retirement survives releasing the close-time retention")
                    var drained = false
                    // A lifecycle request can reach the main mailbox after whenClosed released its sender.
                    app.laterLifecycle(from: old) { $0.loadLayout(named: "Old") }
                    app.later { _ in drained = true }
                    t.check(AppSelfTest.spin { drained && !app.isLoadingLayout })
                    t.equal(app.sortedControllers.map(\.config), ["Layout\\Zed", "Layout\\Alpha"],
                            "a delayed request from a retired instance cannot replace the completed desktop")
                }
                _ = app.stopAllForTermination()
                app.endEngineThread()
            }
        }

        t.suite("App: Layouts: closing uses config name order and includes close-time settings in backup") {
            for mode in [SkinThreading.main, .engine, .pool] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                var opened: [String] = []
                SkinWindowController.opensForTesting = { plan in
                    if case .open(let url) = plan { opened.append(url.lastPathComponent) }
                }
                defer {
                    _ = app.stopAllForTermination()
                    app.endEngineThread()
                    SkinWindowController.opensForTesting = nil
                }
                try writeSkin(app, "Closing\\Alpha", "[!Draggable 0][!Draggable 1 Closing\\Alpha]"
                    + "[!DeactivateConfig][!SetVariable Marker received Closing\\Zulu]"
                    + "[!Draggable 0 Closing\\Zulu][!ActivateConfig Closing\\Bravo Bravo.ini]"
                    + "[\"https://example.invalid/alpha\"]")
                try writeSkin(app, "Closing\\Bravo", "[\"https://example.invalid/bravo\"]")
                try writeSkin(app, "Closing\\Zulu", "[!WriteKeyValue Variables Marker [#Marker]]"
                    + "[\"https://example.invalid/zulu\"]")
                app.rescanLibrary()
                app.state.update("Closing\\Alpha") { $0.loadOrder = 100 }
                app.state.update("Closing\\Zulu") { $0.loadOrder = -100 }
                guard let zulu = app.activate(config: "Closing\\Zulu", file: "Zulu.ini"),
                      let alpha = app.activate(config: "Closing\\Alpha", file: "Alpha.ini") else { continue }
                t.check(AppSelfTest.spin(timeout: 30) { zulu.isStarted && alpha.isStarted })
                try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
                t.check(load(app, "Empty"))
                t.equal(opened, ["alpha", "bravo", "zulu"], "\(mode): closing follows config names, including new configs")
                let backup = try app.layoutStore.read(named: "@Backup").ini
                t.equal(backup.section(named: "Closing\\Alpha")?["Draggable"], "0",
                        "\(mode): an explicit name no longer finds the removed closing instance")
                t.equal(backup.section(named: "Closing\\Alpha")?["Active"], "0",
                        "\(mode): implicit self deactivation still changes the saved Active setting")
                t.equal(backup.section(named: "Closing\\Zulu")?["Draggable"], "0")
                let closedINI = IniDocument.parse(try TextDecoding.readFile(at: zulu.fileURL))
                t.equal(closedINI.section(named: "Variables")?["Marker"], "received",
                        "\(mode): a peer mutation reaches the remaining skin before its close action")
                t.equal(app.controllers.count, 0)
            }
        }

        t.suite("App: Layouts: close barriers include actions relayed through multiple skin executors") {
            for mode in [SkinThreading.main, .engine, .pool] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                defer { _ = app.stopAllForTermination(); app.endEngineThread() }
                try writeSkin(app, "ChainAlpha", "[!CommandMeasure Relay Relay() ChainZulu]")
                try writeSkin(app, "ChainBeta", "[!WriteKeyValue Variables Marker [#Marker]]")
                for name in ["ChainYankee", "ChainZulu"] {
                    try writeSkin(app, name)
                    let folder = SkinLibrary.directory(for: name, root: app.skinsDirectory)
                    let file = folder.appendingPathComponent(name + ".ini")
                    let ini = try TextDecoding.readFile(at: file)
                    try (ini + "\n[Relay]\nMeasure=Script\nScriptFile=Relay.lua\n")
                        .write(to: file, atomically: true, encoding: .utf8)
                    let action = name == "ChainZulu"
                        ? "SKIN:Bang('!CommandMeasure', 'Relay', 'Relay()', 'ChainYankee')"
                        : "SKIN:Bang('!SetVariable', 'Marker', 'relayed', 'ChainBeta')\n"
                            + "SKIN:Bang('!Draggable', '0', 'ChainBeta')"
                    try "function Relay()\n\(action)\nend\n"
                        .write(to: folder.appendingPathComponent("Relay.lua"), atomically: true, encoding: .utf8)
                }
                app.rescanLibrary()
                var old: [SkinWindowController] = []
                for name in ["ChainAlpha", "ChainBeta", "ChainYankee", "ChainZulu"] {
                    if let controller = app.activate(config: name, file: name + ".ini") { old.append(controller) }
                }
                t.equal(old.count, 4)
                t.check(AppSelfTest.spin(timeout: 30) { old.allSatisfy(\.isStarted) })
                try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
                t.check(load(app, "Empty"))
                t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "ChainBeta")?["Draggable"], "0",
                        "\(mode): every relayed window request reaches the backup")
                let target = SkinLibrary.directory(for: "ChainBeta", root: app.skinsDirectory)
                    .appendingPathComponent("ChainBeta.ini")
                t.equal(IniDocument.parse(try TextDecoding.readFile(at: target)).section(named: "Variables")?["Marker"],
                        "relayed", "\(mode): relayed core actions finish before the target's own close")
            }
        }

        t.suite("App: Layouts: one close deadline bounds a blocked shared executor") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try writeSkin(app, "Blocked\\Alpha", "[\"https://example.invalid/late-close\"]")
            try writeSkin(app, "Blocked\\Beta", "[!Draggable 0]")
            app.rescanLibrary()
            guard let alpha = app.activate(config: "Blocked\\Alpha", file: "Alpha.ini"),
                  let beta = app.activate(config: "Blocked\\Beta", file: "Beta.ini") else { return }
            t.check(AppSelfTest.spin(timeout: 30) { alpha.isStarted && beta.isStarted })
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            let gate = DispatchSemaphore(value: 0)
            let entered = Guarded(false)
            var opened = false
            SkinWindowController.opensForTesting = { _ in opened = true }
            alpha.runtime.executor.async { entered.access { $0 = true }; gate.wait() }
            defer {
                gate.signal()
                _ = app.stopAllForTermination()
                app.endEngineThread()
                SkinWindowController.opensForTesting = nil
            }
            t.check(AppSelfTest.spin(timeout: 30) { entered.current })
            var result: Bool?
            app.loadLayout(named: "Empty") { result = $0 }
            t.check(AppSelfTest.spin(timeout: LayoutController.closeTimeout + 3) { result != nil },
                    "one shared executor does not consume a separate timeout for each remaining skin")
            t.equal(result, true)
            t.equal(app.controllers.count, 0)
            t.check(!alpha.runtime.acceptsLayoutCloseActions && !beta.runtime.acceptsLayoutCloseActions)
            gate.signal()
            t.check(AppSelfTest.spin(timeout: 30) { alpha.hasClosed && beta.hasClosed })
            t.check(!opened, "a close action completing after the deadline cannot open resources on the new desktop")
            t.equal(app.controllers.count, 0)
        }

        t.suite("App: Layouts: close-time layout commands preserve FIFO and the rest of the action") {
            for mode in [SkinThreading.main, .engine, .pool] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                var opened: [String] = []
                SkinWindowController.opensForTesting = { plan in
                    if case .open(let url) = plan { opened.append(url.lastPathComponent) }
                }
                defer {
                    _ = app.stopAllForTermination()
                    app.endEngineThread()
                    SkinWindowController.opensForTesting = nil
                }
                try writeSkin(app, "FIFO\\Old", "[!LoadLayout Second][!LoadLayout Third]"
                    + "[!WriteKeyValue Variables Continued yes]")
                for name in ["First", "Second", "Third", "Fourth"] {
                    try writeSkin(app, "FIFO\\\(name)", name == "First" ? "[!LoadLayout Fourth]" : "",
                                  refresh: "[\"https://example.invalid/\(name)\"]")
                    try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("[FIFO\\\(name)]\nActive=1\n")),
                                             named: name)
                }
                app.rescanLibrary()
                guard let old = app.activate(config: "FIFO\\Old", file: "Old.ini") else { continue }
                t.check(AppSelfTest.spin(timeout: 30) { old.isStarted })
                var firstDone = false
                app.loadLayout(named: "First") { firstDone = $0 }
                t.check(AppSelfTest.spin(timeout: 30) { firstDone && !app.isLoadingLayout })
                t.equal(opened, ["First", "Second", "Third", "Fourth"],
                        "\(mode): requests emitted by First's close follow the already queued Third")
                t.equal(app.sortedControllers.map(\.config), ["FIFO\\Fourth"])
                t.equal(IniDocument.parse(try TextDecoding.readFile(at: old.fileURL))
                    .section(named: "Variables")?["Continued"], "yes", "\(mode): layout requests do not abort the action")
                t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "FIFO\\Third")?["Active"], "1")
            }
        }

        t.suite("App: Layouts: a layout bang waits for the requesting engine action to finish") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try writeSkin(app, "ActionGate\\Source")
            app.rescanLibrary()
            guard let source = app.activate(config: "ActionGate\\Source", file: "Source.ini") else { return }
            t.check(AppSelfTest.spin(timeout: 30) { source.isStarted })
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            let gate = DispatchSemaphore(value: 0)
            let entered = Guarded(false)
            var opened = false
            SkinWindowController.opensForTesting = { _ in
                opened = true
                t.check(!source.isStopped, "the rest of the requesting action runs before the desktop closes")
            }
            defer {
                gate.signal()
                _ = app.stopAllForTermination()
                app.endEngineThread()
                SkinWindowController.opensForTesting = nil
            }
            source.runtime.executor.async {
                source.runtime.send(.execute("[!LoadLayout Empty]", section: nil))
                entered.access { $0 = true }
                gate.wait()
                source.runtime.send(.execute("[\"https://example.invalid/action-finished\"]", section: nil))
            }
            t.check(AppSelfTest.spin(timeout: 30) { entered.current && app.isLoadingLayout })
            var checkpoint = false
            app.later { _ in checkpoint = true }
            t.check(AppSelfTest.spin(timeout: 30) { checkpoint })
            t.check(!source.isStopped && app.controller(for: source.config) === source,
                    "an accepted command does not retire a skin in the middle of its current work")
            t.check(!app.layouts.isClosingSkins)
            gate.signal()
            t.check(AppSelfTest.spin(timeout: 30) { opened && !app.isLoadingLayout && app.controllers.isEmpty })
            t.check(source.hasClosed)
        }

        t.suite("App: Layouts: application refresh stays in the close action command queue") {
            for mode in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                var opened: [String] = []
                SkinWindowController.opensForTesting = { plan in
                    if case .open(let url) = plan { opened.append(url.lastPathComponent) }
                }
                defer {
                    _ = app.stopAllForTermination()
                    app.endEngineThread()
                    SkinWindowController.opensForTesting = nil
                }
                try writeSkin(app, "RefreshQueue\\Old", "[!RefreshApp][!LoadLayout Last]")
                for name in ["First", "Last"] {
                    try writeSkin(app, "RefreshQueue\\\(name)", refresh: "[\"https://example.invalid/\(name)\"]")
                    try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("[RefreshQueue\\\(name)]\nActive=1\n")),
                                             named: name)
                }
                app.rescanLibrary()
                guard let old = app.activate(config: "RefreshQueue\\Old", file: "Old.ini") else { continue }
                t.check(AppSelfTest.spin(timeout: 30) { old.isStarted })
                var firstDone = false
                app.loadLayout(named: "First") { firstDone = $0 }
                t.check(AppSelfTest.spin(timeout: 30) { firstDone && !app.isLoadingLayout })
                t.equal(opened, ["First", "First", "Last"], "\(mode): RefreshApp executes after First, before Last")
            }
        }

        t.suite("App: Layouts: a close action can update the layout before its final read") {
            for mode in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                let priorSettings = EnvironmentStore.shared.settingsPath
                EnvironmentStore.shared.settingsPath = app.layoutsDirectory.deletingLastPathComponent().path + "/"
                defer {
                    _ = app.stopAllForTermination()
                    app.endEngineThread()
                    EnvironmentStore.shared.settingsPath = priorSettings
                }
                try app.layoutStore.save(LayoutDocument(ini: IniDocument.parse("[App\\Controls]\nActive=1\nWindowX=1\n")),
                                         named: "Edited")
                let target = try app.layoutStore.iniURL(named: "Edited")
                try writeSkin(app, "Closing\\Writer", "[!WriteKeyValue App\\Controls WindowX 211 \"\(target.path)\"]")
                app.rescanLibrary()
                guard let old = app.activate(config: "Closing\\Writer", file: "Writer.ini") else { continue }
                t.check(AppSelfTest.spin(timeout: 30) { old.isStarted })
                t.check(load(app, "Edited"))
                t.equal(app.state.skin("App\\Controls")?.windowX, "211", "\(mode): final target contents are loaded")
            }
        }

        t.suite("App: Layouts: main and engine close actions open resources once before completion") {
            for mode in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                let url = URL(string: "https://example.invalid/layout-close")!
                var events: [String] = []
                var opened: [SkinExecutePlan] = []
                SkinWindowController.opensForTesting = { plan in
                    opened.append(plan)
                    events.append("open")
                    t.check(app.isLoadingLayout, "\(mode): OnCloseAction opens during the layout switch")
                    t.check(Thread.isMainThread, "\(mode): resource opening reaches the main thread")
                }
                defer {
                    _ = app.stopAllForTermination()
                    app.endEngineThread()
                    SkinWindowController.opensForTesting = nil
                }
                try writeSkin(app, "Layout\\Closer", "[\"\(url.absoluteString)\"]")
                app.rescanLibrary()
                guard let old = app.activate(config: "Layout\\Closer", file: "Closer.ini") else {
                    t.check(false, "\(mode): the closing skin activates")
                    continue
                }
                t.check(AppSelfTest.spin(timeout: 30) { old.isStarted })
                try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
                var completed: Bool?
                app.loadLayout(named: "Empty") { ok in
                    completed = ok
                    events.append("complete")
                }
                t.check(AppSelfTest.spin(timeout: 30) { completed != nil })
                var drained = false
                old.runtime.whenCaughtUp { drained = true }
                t.check(AppSelfTest.spin(timeout: 30) { drained })
                t.equal(completed, true, "\(mode): the layout completes")
                t.equal(opened, [.open(url)], "\(mode): OnCloseAction opens its resource exactly once")
                t.equal(events, ["open", "complete"], "\(mode): the resource opens before layout completion")
                t.equal(app.controllers.count, 0)
            }
        }

        t.suite("App: Layouts: !LoadLayout reaches the coordinator and queued requests finish in order") {
            guard let app = try AppSelfTest.makeApp(t), let old = app.activate(config: "App\\Focus", file: "Focus.ini")
            else { return }
            try app.saveLayout(named: "Desktop", options: LayoutSaveOptions())
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            old.runtime.send(.execute("[!LoadLayout Empty]", section: nil))
            t.check(AppSelfTest.spin { app.controllers.isEmpty && !app.isLoadingLayout })
            t.check(!old.runtime.snapshot.issues.contains { $0.contains("LoadLayout") })
            var completed: [String] = []
            app.loadLayout(named: "Desktop") { ok in if ok { completed.append("Desktop") } }
            app.loadLayout(named: "Empty") { ok in if ok { completed.append("Empty") } }
            t.check(AppSelfTest.spin { completed.count == 2 })
            t.equal(completed, ["Desktop", "Empty"])
            t.equal(app.controllers.count, 0)
        }

        t.suite("App: Layouts: retirement drops UI requests already in the main mailbox") {
            let executor = SkinThreadExecutor(name: "Layout retirement mailbox")
            let window = RecordingWindow()
            var held: SkinRuntime? = try SkinRuntimeSelfTests.makeRuntime(t, SkinRuntimeSelfTests.testSkin,
                                                                          executor: executor, window: window)
            defer { SkinRuntimeSelfTests.finish(t, &held, executor) }
            guard let runtime = held, SkinRuntimeSelfTests.load(t, runtime, on: executor) else { return }
            var ready = false
            runtime.whenCaughtUp { ready = true }
            t.check(AppSelfTest.spin(timeout: 30) { ready })
            window.log.removeAll()
            let queued = DispatchSemaphore(value: 0)
            executor.async {
                runtime.request(.ui(HostBang(bang: Bang(name: "manage", args: ["Layouts"]), hops: 0,
                                            whileClosing: false)))
                runtime.request(.open(.open(URL(string: "https://example.invalid/retired")!)))
                queued.signal()
            }
            // The main queue cannot deliver either request while this wait holds its thread. Retirement therefore
            // happens after enqueue but before delivery, reproducing the close-callback/mailbox race deterministically.
            t.check(queued.wait(timeout: .now() + 30) == .success)
            runtime.retireForLayout()
            var drained = false
            runtime.whenCaughtUp { drained = true }
            t.check(AppSelfTest.spin(timeout: 30) { drained })
            t.equal(window.log, [], "queued UI and open requests are discarded at delivery")
            runtime.send(.execute("[!Manage Layouts][!Move 99 88][!SetVariable Local cleanup]", section: nil))
            t.equal(runtime.exclusive(timeout: 30) { $0.variable("Local") }, "cleanup",
                    "retirement still permits local core cleanup")
            runtime.send(.close(fadeOut: false))
            t.equal(runtime.exclusive(timeout: 30) { $0.variable("Closed") }, "1", "OnCloseAction still runs")
        }

        t.suite("App: Layouts: close UI and system actions stop at the end of retirement") {
            for mode in [SkinThreading.main, .engine] {
                let thread = mode == .engine ? SkinThreadExecutor(name: "Layout close actions") : nil
                let executor: SkinExecutor
                if let thread { executor = thread } else { executor = MainSkinExecutor.shared }
                let window = RecordingWindow()
                let ini = SkinRuntimeSelfTests.testSkin.replacingOccurrences(
                    of: "OnCloseAction=[!SetVariable Closed 1]",
                    with: "OnCloseAction=[!Manage Layouts][!SetClip closing]")
                var held: SkinRuntime? = try SkinRuntimeSelfTests.makeRuntime(t, ini, executor: executor, window: window)
                defer {
                    if let thread { SkinRuntimeSelfTests.finish(t, &held, thread) }
                }
                guard let runtime = held else { continue }
                if let thread {
                    guard SkinRuntimeSelfTests.load(t, runtime, on: thread) else { continue }
                } else {
                    _ = try runtime.load()
                    runtime.send(.start)
                }
                var ready = false
                runtime.whenCaughtUp { ready = true }
                t.check(AppSelfTest.spin(timeout: 30) { ready })
                window.log.removeAll()
                runtime.retireForLayout()
                runtime.send(.close(fadeOut: false))
                var closed = false
                runtime.whenCaughtUp { closed = true }
                t.check(AppSelfTest.spin(timeout: 30) { closed })
                t.check(runtime.didClose)
                t.equal(window.log, ["other on main", "system setclip on main", "other on main"],
                        "\(mode): close-time UI, system and closed notifications reach the recording window")

                runtime.finishLayoutRetirement()
                window.log.removeAll()
                var drained = false
                executor.async {
                    runtime.request(.ui(HostBang(bang: Bang(name: "manage", args: ["Layouts"]), hops: 0,
                                                whileClosing: true)))
                    runtime.request(.system(HostBang(bang: Bang(name: "setclip", args: ["late"]), hops: 0,
                                                    whileClosing: true)))
                    runtime.request(.open(.open(URL(string: "https://example.invalid/late-close")!), whileClosing: true))
                    DispatchQueue.main.async { drained = true }
                }
                t.check(AppSelfTest.spin(timeout: 30) { drained })
                t.equal(window.log, [], "\(mode): late close-tagged UI, system and open requests are discarded")
            }
        }

        t.suite("App: Layouts: retirement isolates directory peers and pending main forwards while allowing file cleanup") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try writeSkin(app, "Cleanup\\Source", "[!WriteKeyValue Variables Closed 1][!SetVariable Probe late Cleanup\\Target]")
            try writeSkin(app, "Cleanup\\Target")
            app.rescanLibrary()
            app.state.update("Cleanup\\Target") { $0.file = "Target.ini"; $0.group = "Cleanup" }
            guard let source = app.activate(config: "Cleanup\\Source", file: "Source.ini"),
                  let target = app.activate(config: "Cleanup\\Target", file: "Target.ini") else { return }
            target.runtime.send(.execute("[!SetVariable Probe unchanged]", section: nil))
            let oldPosition = target.topLeftPosition
            app.later(loading: target.config) { _ in }
            source.apply(.forward(Bang(name: "setvariable", args: ["Probe", "queued"]),
                                  toConfig: target.config, hops: 0), from: source.runtime)
            source.retiredByLayout = true
            source.runtime.retireForLayout()
            source.runtime.send(.execute("[!SetVariable Probe direct Cleanup\\Target]"
                + "[!SetVariable Probe broadcast *][!SetVariableGroup Probe grouped Cleanup]"
                + "[!Move 99 88 Cleanup\\Target][!SetVariable Local cleanup]", section: nil))
            source.apply(.forward(Bang(name: "setvariable", args: ["Probe", "mailbox"]),
                                  toConfig: target.config, hops: 0), from: source.runtime)
            var opened = false
            SkinWindowController.opensForTesting = { _ in opened = true }
            defer { SkinWindowController.opensForTesting = nil }
            source.apply(.open(.open(URL(string: "https://example.invalid/retired")!)), from: source.runtime)
            var drained = false
            app.later { _ in drained = true }
            t.check(AppSelfTest.spin { drained })
            t.equal(target.runtime.exclusive { $0.variable("Probe") }, "unchanged")
            t.close(target.topLeftPosition.x, oldPosition.x)
            t.close(target.topLeftPosition.y, oldPosition.y)
            t.check(!opened, "the retired window cannot open a resource")
            t.equal(source.runtime.exclusive { $0.variable("Local") }, "cleanup")
            _ = app.suspend(config: source.config)
            t.check(AppSelfTest.spin { source.hasClosed })
            t.equal(IniDocument.parse(try TextDecoding.readFile(at: source.fileURL)).section(named: "Variables")?["Closed"], "1",
                    "local OnCloseAction file cleanup still runs")
            t.equal(target.runtime.exclusive { $0.variable("Probe") }, "late",
                    "a genuine OnCloseAction still reaches a remaining config")
            source.runtime.finishLayoutRetirement()
            source.apply(.forward(Bang(name: "setvariable", args: ["Probe", "after"]),
                                  toConfig: target.config, hops: 0, whileClosing: true), from: source.runtime)
            t.equal(target.runtime.exclusive { $0.variable("Probe") }, "late",
                    "close-tagged work is rejected once that close barrier is finished")
        }

        t.suite("App: Layouts: quitting while old skins close does not commit the pending layout") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine),
                  let old = app.activate(config: "App\\Focus", file: "Focus.ini") else { return }
            t.check(AppSelfTest.spin(timeout: 30) { old.isStarted })
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            let gate = DispatchSemaphore(value: 0)
            let entered = Guarded(false)
            old.runtime.executor.async { entered.access { $0 = true }; gate.wait() }
            t.check(AppSelfTest.spin(timeout: 30) { entered.access { $0 } })
            var completed: Bool?
            app.loadLayout(named: "Empty") { completed = $0 }
            t.check(AppSelfTest.spin(timeout: 30) { app.layouts.isClosingSkins })
            _ = app.stopAllForTermination(budget: 0)
            gate.signal()
            t.check(AppSelfTest.spin(timeout: 30) { completed != nil })
            t.equal(completed, false)
            t.check(!app.state.data.hasLoadedLayout, "the previous desktop remains the saved session")
            t.check(app.state.skin("App\\Focus")?.active == true)
            app.endEngineThread()
        }

        installTests(t)
    }

    private static func installTests(_ t: AppTestRunner) {
        t.suite("App: Layouts: package layout applies after install and the checkbox can keep the current desktop") {
            for apply in [true, false] {
                guard let app = try AppSelfTest.makeApp(t),
                      let previous = app.activate(config: "App\\Focus", file: "Focus.ini") else { continue }
                let package = try AppSelfTest.makePackage(t, name: "Layout.rmskin", files: [
                    "RMSKIN.ini": Data("[rmskin]\nName=Layout fixture\nLoadType=Layout\nLoad=Desk\n".utf8),
                    "Skins/LayoutPkg/Card/Card.ini": Data("[Rainmeter]\nUpdate=-1\n[M]\nMeter=String\nText=Card\n".utf8),
                    "Layouts/Desk/Rainmeter.ini": Data("[Rainmeter]\nLanguage=Author\n[LayoutPkg\\Card]\nActive=1\nWindowX=44\nWindowY=55\n".utf8),
                ])
                SkinInstallFlow.applyLayoutAfterInstallForTesting = apply
                defer { SkinInstallFlow.applyLayoutAfterInstallForTesting = nil }
                app.installer.open([package])
                t.check(AppSelfTest.spin(timeout: 30) { app.installer.isIdle && !app.isLoadingLayout })
                t.check(app.layoutStore.contains(named: "Desk"))
                if apply {
                    t.check(app.controller(for: "LayoutPkg\\Card") != nil)
                    t.equal(app.controller(for: "App\\Focus"), nil)
                    t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "App\\Focus")?["Active"], "0",
                            "the fixture's implicit self-deactivation is recorded after its close action")
                } else {
                    t.check(app.controller(for: "App\\Focus") === previous)
                    t.equal(app.controller(for: "LayoutPkg\\Card"), nil)
                    t.check(!app.layoutStore.contains(named: "@Backup"))
                }
            }
        }
        t.suite("App: Layouts: an unused packaged layout does not close unrelated skins") {
            guard let app = try AppSelfTest.makeApp(t),
                  let previous = app.activate(config: "App\\Focus", file: "Compact.ini") else { return }
            let package = try AppSelfTest.makePackage(t, name: "UnusedLayout.rmskin", files: [
                "RMSKIN.ini": Data("[rmskin]\nName=Unused layout\nLoadType=Skin\nLoad=SkinOnly\\Card\\Card.ini\n".utf8),
                "Skins/SkinOnly/Card/Card.ini": Data("[Rainmeter]\nUpdate=-1\n[M]\nMeter=String\nText=Card\n".utf8),
                "Layouts/Unused/Rainmeter.ini": Data("[SkinOnly\\Card]\nActive=1\n".utf8),
            ])
            app.installer.open([package])
            t.check(AppSelfTest.spin(timeout: 30) { app.installer.isIdle && !app.isLoadingLayout })
            t.check(app.controller(for: "App\\Focus") === previous, "an unrelated skin is not closed and reloaded")
            t.check(app.controller(for: "SkinOnly\\Card") != nil, "the package's requested skin still loads")
            t.check(app.layoutStore.contains(named: "Unused"), "the unused layout is installed for later")
            t.check(!app.layoutStore.contains(named: "@Backup"), "no layout application took place")
        }

        t.suite("App: Layouts: package replacement waits for the whole desktop to close") {
            for mode in [SkinThreading.main, .engine] {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { continue }
                defer { _ = app.stopAllForTermination(); app.endEngineThread() }
                try writeSkin(app, "InstallOrder\\Closer",
                              "[!Draggable 0][!WriteKeyValue Marker Value Closed \"#CURRENTPATH#Order.ini\"]")
                try writeSkin(app, "OutsidePackage\\Observer", "[!Draggable 0]")
                let oldMarker = SkinLibrary.directory(for: "InstallOrder\\Closer", root: app.skinsDirectory)
                    .appendingPathComponent("Order.ini")
                try "[Marker]\nValue=Original\n".write(to: oldMarker, atomically: true, encoding: .utf8)
                app.rescanLibrary()
                guard let replaced = app.activate(config: "InstallOrder\\Closer", file: "Closer.ini"),
                      let unrelated = app.activate(config: "OutsidePackage\\Observer", file: "Observer.ini")
                else { t.check(false, "\(mode): old desktop activates"); continue }
                t.check(AppSelfTest.spin(timeout: 30) { replaced.isStarted && unrelated.isStarted })
                let package = try AppSelfTest.makePackage(t, name: "CloseOrder.rmskin", files: [
                    "RMSKIN.ini": Data("[rmskin]\nName=Close order\nLoadType=Layout\nLoad=AfterInstall\n".utf8),
                    "Skins/InstallOrder/Closer/Closer.ini": Data("[Rainmeter]\nUpdate=-1\n[M]\nMeter=String\nText=New\n".utf8),
                    "Skins/InstallOrder/Closer/Order.ini": Data("[Marker]\nValue=Installed\n".utf8),
                    "Layouts/AfterInstall/Rainmeter.ini": Data("[InstallOrder\\Closer]\nActive=1\n".utf8),
                ])
                app.installer.open([package])
                t.check(AppSelfTest.spin(timeout: 30) { app.installer.isIdle && !app.isLoadingLayout })
                t.check(replaced.hasClosed && unrelated.hasClosed, "\(mode): every old skin closes before application")
                let backup = try app.layoutStore.read(named: "@Backup").ini
                t.equal(backup.section(named: "InstallOrder\\Closer")?["Draggable"], "0",
                        "\(mode): backup includes the replaced skin's close-time setting")
                t.equal(backup.section(named: "OutsidePackage\\Observer")?["Draggable"], "0",
                        "\(mode): backup includes the unrelated skin's close-time setting")
                let marker = SkinLibrary.directory(for: "InstallOrder\\Closer", root: app.skinsDirectory)
                    .appendingPathComponent("Order.ini")
                t.equal(IniDocument.parse(try TextDecoding.readFile(at: marker)).section(named: "Marker")?["Value"],
                        "Installed", "\(mode): old close writes happen before package files replace them")
                t.equal(app.controller(for: "OutsidePackage\\Observer"), nil)
            }
        }

        t.suite("App: Layouts: a close timeout cancels package replacement") {
            guard let app = try AppSelfTest.makeApp(t, threading: .engine) else { return }
            try writeSkin(app, "InstallTimeout\\Closer", "[!WriteKeyValue Marker Value Closed \"#CURRENTPATH#Order.ini\"]")
            let marker = SkinLibrary.directory(for: "InstallTimeout\\Closer", root: app.skinsDirectory)
                .appendingPathComponent("Order.ini")
            try "[Marker]\nValue=Original\n".write(to: marker, atomically: true, encoding: .utf8)
            app.rescanLibrary()
            guard let old = app.activate(config: "InstallTimeout\\Closer", file: "Closer.ini") else {
                t.check(false, "the old skin activates"); return
            }
            t.check(AppSelfTest.spin(timeout: 30) { old.isStarted })
            let original = try Data(contentsOf: old.fileURL)
            let package = try AppSelfTest.makePackage(t, name: "CloseTimeout.rmskin", files: [
                "RMSKIN.ini": Data("[rmskin]\nName=Close timeout\nLoadType=Layout\nLoad=AfterTimeout\n".utf8),
                "Skins/InstallTimeout/Closer/Closer.ini": Data("[Rainmeter]\nUpdate=-1\n[M]\nMeter=String\nText=New\n".utf8),
                "Skins/InstallTimeout/Closer/Order.ini": Data("[Marker]\nValue=Installed\n".utf8),
                "Layouts/AfterTimeout/Rainmeter.ini": Data("[InstallTimeout\\Closer]\nActive=1\n".utf8),
            ])
            let gate = DispatchSemaphore(value: 0)
            let entered = Guarded(false)
            old.runtime.executor.async { entered.access { $0 = true }; gate.wait() }
            defer { gate.signal(); _ = app.stopAllForTermination(); app.endEngineThread() }
            t.check(AppSelfTest.spin(timeout: 30) { entered.current })
            app.installer.open([package])
            t.check(AppSelfTest.spin(timeout: 30) { app.installer.waitsForSkinsToClose })
            t.check(app.isLoadingLayout, "saving is blocked while the installer closes the desktop")
            t.check(AppSelfTest.spin(timeout: LayoutController.closeTimeout + 3) { app.installer.isIdle },
                    "the installer aborts within the single close budget")
            t.equal(try Data(contentsOf: old.fileURL), original, "the old file remains intact")
            t.check(!app.layoutStore.contains(named: "AfterTimeout"), "the package layout was not installed")
            gate.signal()
            t.check(AppSelfTest.spin(timeout: 30) { old.hasClosed })
            t.equal(try Data(contentsOf: old.fileURL), original, "late cleanup cannot overwrite a replacement file")
            t.equal(IniDocument.parse(try TextDecoding.readFile(at: marker)).section(named: "Marker")?["Value"],
                    "Closed", "late cleanup still runs against the original package files")
        }

        t.suite("App: Layouts: an installing package completes its own layout before a queued user layout") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try app.saveLayout(named: "Empty", options: LayoutSaveOptions(empty: true))
            let package = try AppSelfTest.makePackage(t, name: "QueuedLayout.rmskin", files: [
                "RMSKIN.ini": Data("[rmskin]\nName=Queued layout\nLoadType=Layout\nLoad=Package\n".utf8),
                "Skins/Queued/Card/Card.ini": Data("[Rainmeter]\nUpdate=-1\n[M]\nMeter=String\nText=Card\n".utf8),
                "Layouts/Package/Rainmeter.ini": Data("[Queued\\Card]\nActive=1\n".utf8),
            ])
            app.installer.open([package])
            t.check(app.installer.isInstalling)
            var completed: Bool?
            app.loadLayout(named: "Empty") { completed = $0 }
            t.check(AppSelfTest.spin(timeout: 30) { app.installer.isIdle && completed != nil && !app.isLoadingLayout })
            t.equal(completed, true)
            t.equal(app.controllers.count, 0)
            t.equal(try app.layoutStore.read(named: "@Backup").ini.section(named: "Queued\\Card")?["Active"], "1",
                    "the queued user layout replaces the package's completed desktop")
        }
    }

    private final class UnavailableWallpaper: LayoutWallpaper {
        private(set) var captureAttempts = 0
        func capture() throws -> Data? {
            captureAttempts += 1
            throw LayoutOperationError.wallpaper("A dynamic desktop picture cannot be encoded.")
        }
        func apply(_ bitmap: Data) throws {}
    }

    private final class RejectingWallpaper: LayoutWallpaper {
        private(set) var applied: [Data] = []
        func capture() throws -> Data? { Data([0x42, 0x4D, 1]) }
        func apply(_ bitmap: Data) throws {
            applied.append(bitmap)
            throw LayoutOperationError.wallpaper("The desktop picture could not be applied.")
        }
    }

    private static func load(_ app: AppController, _ name: String) -> Bool {
        var result: Bool?
        app.loadLayout(named: name) { result = $0 }
        return AppSelfTest.spin(timeout: 30) { result != nil } && result == true
    }

    private static func writeSkin(_ app: AppController, _ config: String, _ close: String = "", refresh: String = "") throws {
        let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = config.split(separator: "\\").last.map(String.init) ?? "Skin"
        try "[Rainmeter]\nUpdate=-1\nOnCloseAction=\(close)\nOnRefreshAction=\(refresh)\n[M]\nMeter=String\nText=\(name)\n"
            .write(to: folder.appendingPathComponent(name + ".ini"), atomically: true, encoding: .utf8)
    }
}
