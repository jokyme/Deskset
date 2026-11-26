import AppKit
import DesksetCore

/// Regression suites for asynchronous host bang continuations (`!SkinCustomMenu`, `!SkinMenu`, `!TrayMenu`, `!SetClip`,
/// `!SetWallpaper`) across `main`, `engine`, and `pool` threading modes, including GitHub issue #76 on the bundled
/// `Stationery\Launcher` widget.
enum HostBangContinuationSelfTests {
    static func run(_ t: AppTestRunner) {
        MediaUIPlugins.register()
        for mode in [SkinThreading.main, .engine, .pool] {
            menuContinuationTests(t, mode)
            luaMenuQueueTests(t, mode)
            crossSkinMenuTests(t, mode)
            continuationHopTests(t, mode)
            measureSequenceTests(t, mode)
            launcherTileMenuTests(t, mode)
            systemBangContinuationTests(t, mode)
        }
    }

    // MARK: - Menu continuation & ContextAction ordering

    private static func menuContinuationTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Host bang continuation: !SkinCustomMenu and !SkinMenu hold state until menu closes (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            let script = """
                evalCount = 0
                function ResetEvalCount()
                    evalCount = 0
                end
                function TitleTag()
                    evalCount = evalCount + 1
                    return 'Eval' .. evalCount
                end
                function PickFromLua()
                    SKIN:Bang('!SetVariable', 'LuaPicked', SKIN:GetVariable('MenuKind') .. ':' .. SKIN:GetVariable('Highlight'))
                end
                """
            try writeFile(app, "Cont/@Resources/Menu.lua", script)
            try writeSkin(app, "Menu", text: """
                [Rainmeter]
                Update=-1
                ContextTitle=[#Item1_[#MenuKind]]
                ContextAction=[!SetVariable Picked "#MenuCell#|[#MenuKind]|[#Highlight]"]
                ContextTitle2=[&MeasureLua:TitleTag()]
                ContextAction2=[!CommandMeasure MeasureLua "PickFromLua()"]
                ContextTitle3=---
                ContextTitle4=Fourth ([#MenuKind])
                ContextAction4=[!SetVariable Picked "fourth:[#MenuKind]"]

                [Variables]
                CardKind=9
                MenuKind=9
                MenuCell=0
                Highlight=off
                Picked=none
                LuaPicked=none
                Item1_1=Open Tile
                Item1_9=Edit Card

                [MeasureLua]
                Measure=Script
                ScriptFile=#@#Menu.lua
                DynamicVariables=1

                [MeterPad]
                Meter=String
                Text=Pad
                W=60
                H=60
                RightMouseUpAction=[!CommandMeasure MeasureLua "ResetEvalCount()"][!SetVariable MenuKind 1][!SetVariable MenuCell 3][!SetVariable Highlight on][!SkinCustomMenu][!SetVariable MenuKind #CardKind#][!SetVariable MenuCell 0][!SetVariable Highlight off]
                """)
            guard let c = load(t, app, "Menu") else { return }

            // 1. Right-click triggers !SkinCustomMenu: verify titles, live state while open, and deferred [#Var] action.
            var seenTitles: [String] = []
            var stateWhileOpen: String?
            app.popUpMenuForTesting = { menu in
                seenTitles = menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
                if mode != .main {
                    stateWhileOpen = c.runtime.exclusive(timeout: 5) {
                        "\($0.variable("MenuKind") ?? "")|\($0.variable("Highlight") ?? "")"
                    }
                }
                if let first = menu.items.first {
                    app.customContextAction(first)
                }
            }
            c.runtime.send(.mouse(.rightUp, x: 10, y: 10))
            guard wait(t, "reset completed after !SkinCustomMenu", {
                !seenTitles.isEmpty
                    && variable(c, "Picked") == "3|1|on"
                    && variable(c, "MenuKind") == "9"
                    && variable(c, "MenuCell") == "0"
                    && variable(c, "Highlight") == "off"
            }) else { return }
            t.equal(seenTitles, ["Open Tile", "Eval1", "---", "Fourth (1)"],
                    "custom menu reads tile titles and evaluates inline Lua once")
            if mode != .main {
                t.equal(stateWhileOpen, "1|on", "trailing reset bangs wait while the menu is open")
            }

            // 2. !SkinMenu with >3 custom items (placed in Custom Skin Actions submenu) and Lua reading SKIN:GetVariable.
            var submenuTitles: [String] = []
            app.popUpMenuForTesting = { menu in
                let sub = menu.item(withTitle: L("Custom Skin Actions"))?.submenu
                submenuTitles = sub?.items.map { $0.isSeparatorItem ? "---" : $0.title } ?? []
                if let luaItem = sub?.items[1] {
                    app.customContextAction(luaItem)
                }
            }
            execute(c, "[!CommandMeasure MeasureLua \"ResetEvalCount()\"][!SetVariable MenuKind 1][!SetVariable Highlight on][!SkinMenu][!SetVariable MenuKind 9][!SetVariable Highlight off]")
            guard wait(t, "!SkinMenu Lua item and reset completed", {
                !submenuTitles.isEmpty
                    && variable(c, "LuaPicked") == "1:on"
                    && variable(c, "MenuKind") == "9"
                    && variable(c, "Highlight") == "off"
            }) else { return }
            t.equal(submenuTitles, ["Open Tile", "Eval1", "---", "Fourth (1)"],
                    "!SkinMenu uses single-pass executor snapshot without re-running inline Lua")
        }
    }

    // MARK: - Lua SKIN:Bang queue

    private static func luaMenuQueueTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Host bang continuation: Lua SKIN:Bang queue waits for !SkinCustomMenu (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            let script = """
                function OpenTileMenu()
                    SKIN:Bang('!SetVariable', 'MenuKind', '2')
                    SKIN:Bang('!SkinCustomMenu')
                    SKIN:Bang('!SetVariable', 'MenuKind', '9')
                    SKIN:Bang('!SetVariable', 'Done', '1')
                end
                """
            try writeFile(app, "Cont/@Resources/Queue.lua", script)
            try writeSkin(app, "LuaQueue", text: """
                [Rainmeter]
                Update=-1
                ContextTitle=Kind [#MenuKind]
                ContextAction=[!SetVariable ChosenFromLua "[#MenuKind]"]

                [Variables]
                MenuKind=9
                ChosenFromLua=none
                Done=0

                [MeasureLua]
                Measure=Script
                ScriptFile=#@#Queue.lua
                """)
            guard let c = load(t, app, "LuaQueue") else { return }
            var titles: [String] = []
            app.popUpMenuForTesting = { menu in
                titles = menu.items.map(\.title)
                if let first = menu.items.first { app.customContextAction(first) }
            }
            execute(c, #"[!CommandMeasure MeasureLua "OpenTileMenu()"]"#)
            guard wait(t, "Lua queue resumed after menu", { variable(c, "Done") == "1" }) else { return }
            t.equal(titles, ["Kind 2"])
            t.equal(variable(c, "ChosenFromLua"), "2")
            t.equal(variable(c, "MenuKind"), "9")
        }
    }

    // MARK: - Cross-skin menu ordering

    private static func crossSkinMenuTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Host bang continuation: cross-skin !SkinCustomMenu orders with target bangs (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            try writeSkin(app, "Sender", text: """
                [Rainmeter]
                Update=-1
                ContextTitle=WrongSenderMenu
                ContextAction=[!SetVariable Wrong 1]
                [Variables]
                SenderAfter=0
                """)
            try writeSkin(app, "Target", text: """
                [Rainmeter]
                Update=-1
                ContextTitle=Target [#MenuKind]
                ContextAction=[!SetVariable TargetChosen "[#MenuKind]"]
                [Variables]
                MenuKind=9
                TargetChosen=none
                """)
            guard let sender = load(t, app, "Sender"), let target = load(t, app, "Target") else { return }

            var titles: [String] = []
            app.popUpMenuForTesting = { menu in
                titles = menu.items.map(\.title)
                if let first = menu.items.first { app.customContextAction(first) }
            }
            execute(sender, "[!SetVariable MenuKind 4 \"Cont\\Target\"]"
                + "[!SkinCustomMenu \"Cont\\Target\"]"
                + "[!SetVariable MenuKind 9 \"Cont\\Target\"]"
                + "[!SetVariable SenderAfter 1]")
            guard wait(t, "sender and target settled", {
                variable(sender, "SenderAfter") == "1" && variable(target, "MenuKind") == "9"
            }) else { return }
            t.equal(titles, ["Target 4"], "target's menu was captured after preceding SetVariable, not sender's")
            t.equal(variable(target, "TargetChosen"), "4", "chosen action ran on target before trailing reset")
        }
    }

    private static func continuationHopTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Host bang continuation: resumed peer actions keep the incoming hop count (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            try writeSkin(app, "Sender", text: """
                [Rainmeter]
                Update=-1
                [Probe]
                Measure=Calc
                Formula=1
                Disabled=1
                OnUpdateAction=[!SkinCustomMenu][!SkinCustomMenu "Cont\\Target"][!SetVariable Delivered 1 "Cont\\Target"][!SetVariable Finished 1]
                """)
            try writeSkin(app, "Target", text: "[Rainmeter]\nUpdate=-1")
            guard let sender = load(t, app, "Sender"), let target = load(t, app, "Target") else { return }
            let completions = Guarded(0)
            _ = sender.runtime.exclusive(timeout: 5) { _ in
                sender.runtime.messageObserver = { message in
                    if case .hostBangCompleted = message { completions.access { $0 += 1 } }
                }
            }
            defer { _ = sender.runtime.exclusive(timeout: 5) { _ in sender.runtime.messageObserver = nil } }
            execute(sender, "[!EnableMeasure Probe]")
            sender.runtime.send(.bang(Bang(name: "updatemeasure", args: ["Probe"]), from: target.config,
                                      hops: SkinRuntime.maxHops))
            guard wait(t, "caller finished the resumed action", { variable(sender, "Finished") == "1" }) else { return }
            t.equal(sender.runtime.exclusive(timeout: 5) { _ in sender.runtime.droppedHops }, 2)
            t.equal(completions.current, 1, "only the delivered local menu sends a completion")
            t.equal(variable(target, "Delivered"), nil)
        }
    }

    // MARK: - One measure's actions in order

    private static func measureSequenceTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Host bang continuation: a measure's OnUpdateAction waits for its IfTrueAction's menu (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            try writeSkin(app, "MeasureMenu", text: """
                [Rainmeter]
                Update=-1
                ContextTitle=Item
                ContextAction=[!SetVariable Picked "[#Phase]"]
                [Variables]
                Armed=0
                Phase=idle
                Seen=none
                Picked=none
                [Tile]
                Measure=Calc
                Formula=#Armed#
                DynamicVariables=1
                IfConditionMode=1
                IfCondition=Tile = 1
                IfTrueAction=[!SetVariable Phase menu][!SkinCustomMenu][!SetVariable Phase reset]
                OnUpdateAction=[!SetVariable Seen "[#Phase]"]
                """)
            guard let c = load(t, app, "MeasureMenu") else { return }
            t.equal(variable(c, "Seen"), "idle")
            var whileOpen: String?
            app.popUpMenuForTesting = { menu in
                whileOpen = c.runtime.exclusive(timeout: 5) {
                    "\($0.variable("Phase") ?? "")|\($0.variable("Seen") ?? "")"
                }
                if let first = menu.items.first { app.customContextAction(first) }
            }
            execute(c, "[!SetVariable Armed 1][!Update]")
            guard wait(t, "the measure's pass finished", { variable(c, "Seen") == "reset" }) else { return }
            t.equal(whileOpen, "menu|idle", "OnUpdateAction had not run while the menu was open")
            t.equal(variable(c, "Picked"), "menu", "the chosen item saw the tile's state")
        }
    }

    // MARK: - Bundled Stationery\Launcher regression (#76)

    private static func launcherTileMenuTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Host bang continuation: Stationery Launcher tile right-click opens tile menu and Rename hits tile (\(mode))") {
            guard let defaults = Paths.repositoryFolder("DefaultSkins") else {
                print("    (skipped: DefaultSkins folder not found)")
                return
            }
            guard let app = try fixture(t, mode) else { return }
            let fm = FileManager.default
            try fm.copyItem(at: defaults.appendingPathComponent("Stationery"),
                            to: app.skinsDirectory.appendingPathComponent("Stationery"))
            let existingTarget = app.skinsDirectory.path
            let stationeryFile = app.settingsDirectory.appendingPathComponent(DefaultSkins.stationeryFileName)
            try fm.createDirectory(at: app.settingsDirectory, withIntermediateDirectories: true)
            try (DefaultSkins.stationeryFileHeader + "\nLaunch1=\(existingTarget)\n")
                .write(to: stationeryFile, atomically: true, encoding: .utf8)
            app.rescanLibrary()

            for (variant, cardKind, clickPoint) in [("Medium.ini", "9", (x: 55.0, y: 50.0)),
                                                    ("Small.ini", "8", (x: 50.0, y: 50.0))] {
                app.state.update("Stationery\\Launcher") { $0.file = variant; $0.keepOnScreen = false }
                guard let c = app.activate(config: "Stationery\\Launcher", file: variant, exactFile: true),
                      wait(t, "Launcher \(variant) starts", { c.isStarted }) else { return }
                // Wait for FolderInfo on Item 1's parent so Launch1Missing is settled at 0 (kind 1: path).
                _ = AppSelfTest.spin(timeout: 5) {
                    variable(c, "Launch1Missing") == "0" && variable(c, "Launch1Kind") == "1"
                }

                var titles: [String] = []
                app.popUpMenuForTesting = { menu in
                    titles = menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
                    if let rename = menu.items.first(where: { $0.title == "Rename…" }) {
                        app.customContextAction(rename)
                    }
                }
                c.runtime.send(.mouse(.rightUp, x: clickPoint.x, y: clickPoint.y))
                guard wait(t, "Launcher \(variant) Rename and reset finished", {
                    !titles.isEmpty
                        && variable(c, "EditCell") == "1"
                        && variable(c, "MenuKind") == cardKind
                        && variable(c, "MenuCell") == "0"
                }) else { return }
                t.equal(titles, ["Open", "Show in Finder", "---", "Rename…", "Change Item…", "Remove Item"],
                        "Launcher \(variant) shows tile 1's menu, not card menu")
                app.deactivate(c, fade: false)
                _ = wait(t, "Launcher \(variant) closed", { c.hasClosed })
            }
        }
    }

    // MARK: - System bangs (!SetWallpaper, !SetClip)

    private static func systemBangContinuationTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: Host bang continuation: !SetWallpaper and !SetClip finish before later bangs (\(mode))") {
            let savedFake = DesktopInputs.fake.current
            let savedWallpaperHook = SkinWindowController.setWallpaperForTesting
            let pasteboard = NSPasteboard.withUniqueName()
            t.atSuiteEnd {
                DesktopInputs.fake.access { $0 = savedFake }
                SkinWindowController.setWallpaperForTesting = savedWallpaperHook
                pasteboard.releaseGlobally()
            }

            let screenRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
            guard let app = try fixture(t, mode) else { return }
            let oldPic = app.skinsDirectory.appendingPathComponent("Cont/@Resources/Old.png")
            let nextPic = app.skinsDirectory.appendingPathComponent("Cont/@Resources/Next.png")
            try writePNG(to: oldPic, color: .systemBlue)
            try writePNG(to: nextPic, color: .systemRed)
            DesktopInputs.fake.access {
                $0 = [DesktopInputs.ScreenDesktop(picture: oldPic.path, frame: screenRect, area: screenRect)]
            }
            SkinWindowController.setWallpaperForTesting = { path, _ in
                DesktopInputs.fake.access {
                    $0 = [DesktopInputs.ScreenDesktop(picture: path, frame: screenRect, area: screenRect)]
                }
            }

            try writeSkin(app, "SystemSync", text: """
                [Rainmeter]
                Update=-1
                [Variables]
                SawWallpaper=none
                ClipDone=0
                [MeasureCham]
                Measure=Plugin
                Plugin=Chameleon
                Type=Desktop
                [MeterStub]
                Meter=String
                Text=Stub
                W=40
                H=20
                """)
            guard let c = load(t, app, "SystemSync") else { return }
            c.setClipPasteboard = pasteboard
            t.equal(c.runtime.exclusive(timeout: 5) { $0.measure(named: "MeasureCham")?.stringValue }, oldPic.path)

            execute(c, "[!SetWallpaper \"#@#Next.png\"][!UpdateMeasure MeasureCham]"
                + "[!SetVariable SawWallpaper \"[MeasureCham]\"]"
                + "[!SetClip \"DesksetClipCheck-\(mode.rawValue)\"][!SetVariable ClipDone 1]")
            guard wait(t, "wallpaper and clip chain finished", { variable(c, "ClipDone") == "1" }) else { return }
            t.equal(variable(c, "SawWallpaper"), nextPic.path,
                    "MeasureCham immediately sees the wallpaper set by !SetWallpaper without !Delay")
            t.equal(pasteboard.string(forType: .string), "DesksetClipCheck-\(mode.rawValue)")
        }
    }

    // MARK: - Helpers

    private static func fixture(_ t: AppTestRunner, _ mode: SkinThreading) throws -> AppController? {
        guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return nil }
        t.atSuiteEnd {
            app.popUpMenuForTesting = nil
            let threads = (app.engineThread.map { [$0] } ?? []) + (app.skinThreadPool?.activeWorkers ?? [])
            app.stopAllForTermination()
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { threads.allSatisfy(\.hasExited) }, "fixture executors stopped")
        }
        return app
    }

    private static func writeFile(_ app: AppController, _ relativePath: String, _ text: String) throws {
        let url = app.skinsDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeSkin(_ app: AppController, _ name: String, text: String) throws {
        try writeFile(app, "Cont/\(name)/\(name).ini", text)
        app.state.update("Cont\\\(name)") { $0.file = "\(name).ini"; $0.keepOnScreen = false }
        app.rescanLibrary()
    }

    private static func load(_ t: AppTestRunner, _ app: AppController, _ name: String) -> SkinWindowController? {
        guard let c = app.activate(config: "Cont\\\(name)", file: "\(name).ini") else {
            t.check(false, "fixture \(name) activates")
            return nil
        }
        guard wait(t, "fixture \(name) starts", { c.isStarted }) else { return nil }
        return c
    }

    private static func execute(_ c: SkinWindowController, _ action: String) {
        c.runtime.send(.execute(action, section: nil))
    }

    private static func variable(_ c: SkinWindowController, _ name: String) -> String? {
        c.runtime.exclusive(timeout: 5) { $0.variable(name) } ?? nil
    }

    private static func wait(_ t: AppTestRunner, _ message: String, _ condition: () -> Bool) -> Bool {
        let ok = AppSelfTest.spin(timeout: 30, until: condition)
        t.check(ok, message)
        return ok
    }

    private static func writePNG(to url: URL, color: NSColor) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "HostBangContinuationSelfTests", code: 1)
        }
        try png.write(to: url)
    }
}
