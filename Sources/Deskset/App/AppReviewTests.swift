import AppKit
import DesksetCore
import SystemConfiguration

/// Regression checks from the adversarial review of the app layer (run with `Deskset --self-test`, suites "App: …").
/// Fixtures: TestSkins/App/Mouse, Once, Closer, Observer and Hostile.
extension AppSelfTest {
    static func reviewTests(_ t: AppTestRunner) {
        backgroundTileTests(t)
        mouseActionTests(t)
        lifecycleReviewTests(t)
        stateReviewTests(t)
        connectivityReviewTests(t)
        installReviewTests(t)
        recursionReviewTests(t)
        forwardRecursionReviewTests(t)
    }

    // MARK: Background tiling

    /// Draws a skin like the app does (flipped, top-left origin) into a bitmap at 1 pixel per point.
    static func drawSkin(_ skin: Skin, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: width, height: height))
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        SkinRenderer.draw(skin, in: cg)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func loadSkin(_ url: URL, config: String, skins: URL) -> Skin? {
        let host = RenderHost()
        let skin = Skin(config: config, fileURL: url, skinsDirectory: skins, system: SystemMonitor.shared, host: host)
        guard (try? skin.load()) != nil else { return nil }
        skin.update()
        return withExtendedLifetime(host) { skin }
    }

    static func backgroundTileTests(_ t: AppTestRunner) {
        t.suite("App: background tiling (review)") {
            guard let testSkins = Paths.repositoryFolder("TestSkins") else {
                print("    (skipped: TestSkins not found; run from the repository)")
                return
            }
            // Orientation and origin: each 16×16 tile has an orange 4×4 square at its top-left corner.
            let checker = testSkins.appendingPathComponent("App/Hostile/TileChecker.ini")
            guard let skin = loadSkin(checker, config: "App\\Hostile", skins: testSkins),
                  let rep = drawSkin(skin, width: 100, height: 70) else {
                t.check(false, "TileChecker renders")
                return
            }
            func isOrange(_ x: Int, _ y: Int) -> Bool {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return c.redComponent > 0.9 && c.greenComponent > 0.45 && c.greenComponent < 0.75 && c.blueComponent < 0.3
            }
            // NSBitmapImageRep.colorAt uses a top-left origin.
            for (x, y) in [(1, 1), (17, 1), (1, 17), (33, 49), (97, 65)] {
                t.check(isOrange(x, y), "tile corner at \(x),\(y)")
            }
            for (x, y) in [(6, 1), (1, 6), (10, 10), (1, 14)] {
                t.check(!isOrange(x, y), "not a tile corner at \(x),\(y)")
            }
            t.check((rep.colorAt(x: 99, y: 69)?.alphaComponent ?? 0) > 0.99, "the whole skin is covered")

            // A 1×1 image tiled over a big skin: one draw call per pixel took seconds per frame (9 million calls
            // here); huge sizes never finished.
            let root = t.temporaryDirectory("tile")
            let config = root.appendingPathComponent("Root/Big")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let dot = testSkins.appendingPathComponent("App/@Resources/Images/Dot.png").path
            for (name, w, h) in [("Big", 3000, 3000), ("Huge", 1_000_000_000, 1_000_000_000)] {
                let ini = config.appendingPathComponent("\(name).ini")
                try "[Rainmeter]\nBackground=\(dot)\nBackgroundMode=4\nSkinWidth=\(w)\nSkinHeight=\(h)\n"
                    .write(to: ini, atomically: true, encoding: .utf8)
                guard let big = loadSkin(ini, config: "Root\\Big", skins: root) else {
                    t.check(false, "\(name) loads")
                    continue
                }
                let start = Date()
                let rep = drawSkin(big, width: 400, height: 300)
                let elapsed = Date().timeIntervalSince(start)
                t.check(elapsed < 0.5, "\(name): tiled background drawn in \(elapsed) s")
                let c = rep?.colorAt(x: 200, y: 150)?.usingColorSpace(.deviceRGB)
                t.check((c?.alphaComponent ?? 0) > 0.99 && (c?.blueComponent ?? 0) > 0.8, "\(name): dot color drawn")
            }
        }
    }

    // MARK: Mouse actions and dragging

    /// A mouse event at a skin point (top-left origin) in the controller's (headless) window.
    static func mouseEvent(_ type: NSEvent.EventType, _ c: SkinController, x: Double, y: Double,
                           clickCount: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        let height = c.view.bounds.height
        return NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: Double(height) - y), modifierFlags: flags,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
    }

    static func mouseActionTests(_ t: AppTestRunner) {
        t.suite("App: mouse actions and dragging (review)") {
            guard let app = try makeApp(t), let c = app.activate(config: "App\\Mouse", file: nil) else { return }
            func reset() { for name in ["Down", "Up", "Double"] { c.skin.setVariable(name, "0") } }
            func v(_ name: String) -> String { c.skin.variable(name) ?? "" }

            // "LeftMouseDownAction disables dragging the skin."
            reset()
            t.equal(SkinView.leftMouseDown(c, x: 25, y: 25, clickCount: 1, override: false), false,
                    "no drag from a meter with LeftMouseDownAction")
            t.equal(v("Down"), "1")
            t.equal(SkinView.leftMouseDown(c, x: 85, y: 25, clickCount: 1, override: false), true,
                    "LeftMouseUpAction does not prevent dragging")
            t.equal(SkinView.leftMouseDown(c, x: 145, y: 25, clickCount: 1, override: false), true)
            // CTRL (⌘ on the Mac): "Mouse Click Options may be overridden by holding down CTRL while clicking".
            reset()
            t.equal(SkinView.leftMouseDown(c, x: 25, y: 25, clickCount: 1, override: true), true, "override drags")
            t.equal(v("Down"), "0", "override runs no click action")
            // Draggable=0: only the override drags.
            app.changeSettings(of: c) { $0.draggable = false }
            t.equal(SkinView.leftMouseDown(c, x: 145, y: 25, clickCount: 1, override: false), false)
            t.equal(SkinView.leftMouseDown(c, x: 145, y: 25, clickCount: 1, override: true), true)
            app.changeSettings(of: c) { $0.draggable = true }

            // Real events through the view.
            let view = c.view
            func click(_ x: Double, _ y: Double, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
                if let down = mouseEvent(.leftMouseDown, c, x: x, y: y, clickCount: count, flags: flags) {
                    view.mouseDown(with: down)
                }
                if let up = mouseEvent(.leftMouseUp, c, x: x, y: y, clickCount: count, flags: flags) {
                    view.mouseUp(with: up)
                }
            }
            reset()
            click(85, 25)
            t.equal(v("Up"), "1", "a click runs LeftMouseUpAction")
            t.equal(v("Double"), "0")
            reset()
            click(85, 25, count: 2)
            t.equal(v("Double"), "1", "the second click of a double click runs LeftMouseDoubleClickAction")
            t.equal(v("Up"), "1", "…and its release still runs LeftMouseUpAction (both are executed)")
            t.equal(view.dragAllowed, false, "a double click does not start a drag")
            reset()
            click(85, 25, flags: .command)
            t.equal(v("Up"), "0", "⌘-click runs no LeftMouseUpAction")
            click(25, 25, flags: .command)
            t.equal(v("Down"), "0", "⌘-click runs no LeftMouseDownAction")
            t.equal(view.dragAllowed, true)
            reset()
            click(25, 25)
            t.equal(v("Down"), "1")
            t.equal(view.dragAllowed, false)

            // Z-order on click: Normal ("will be brought to the foreground") and Topmost come to the front of their
            // level; Bottom / On Desktop keep their load-order stacking; Stay Topmost has its own level.
            t.equal((-2...2).map { SkinController.bringsToFrontOnClick(alwaysOnTop: $0) }, [false, false, true, true, false])
        }
    }

    // MARK: Lifecycle

    static func lifecycleReviewTests(_ t: AppTestRunner) {
        t.suite("App: Update=-1 and quitting (review)") {
            guard let app = try makeApp(t), let once = app.activate(config: "App\\Once", file: nil) else { return }
            t.equal(once.skin.updateCount, 1)
            t.equal(once.skin.variable("Updates"), "1")
            once.pauseUpdates()
            once.resumeUpdates(updateNow: true)
            once.systemDidWake()
            t.equal(once.skin.updateCount, 1, "Update=-1: no extra update after sleep / display sleep")
            t.equal(once.skin.variable("Updates"), "1", "OnUpdateAction ran once")

            // OnCloseAction bangs while the app quits.
            guard let focus = app.activate(config: "App\\Focus", file: "Focus.ini"),
                  let closer = app.activate(config: "App\\Closer", file: nil) else {
                t.check(false, "Focus and Closer load")
                return
            }
            app.stopAllForTermination()
            t.check(focus.isStopped && closer.isStopped && once.isStopped, "every skin closed")
            t.check(app.controller(for: "App\\Observer") == nil || app.controller(for: "App\\Observer")?.isStopped == true,
                    "!ActivateConfig from OnCloseAction does not load a skin while quitting")
            t.check(app.state.skin("App\\Observer")?.active != true, "…nor marks it loaded for the next launch")
            t.equal(app.state.skin("App\\Focus")?.active, true, "!DeactivateConfig while quitting keeps App\\Focus for next launch")
            t.equal(app.state.skin("App\\Once")?.active, true, "!ToggleConfig while quitting keeps App\\Once for next launch")
            t.equal(app.state.skin("App\\Closer")?.active, true)
            RenderCommand.wait(milliseconds: 50)
            t.equal(app.state.skin("App\\Focus")?.active, true, "nothing deferred changes it afterwards")
        }
    }

    // MARK: State

    static func stateReviewTests(_ t: AppTestRunner) {
        t.suite("App: absurd saved positions (review)") {
            let dir = t.temporaryDirectory("state-review")
            let url = dir.appendingPathComponent("state.json")
            try #"{"skins": {"App\\Focus": {"file": "Focus.ini", "x": 1e300, "y": -1e300, "active": false}}}"#
                .write(to: url, atomically: true, encoding: .utf8)
            let state = AppState(fileURL: url)
            t.equal(state.skin("App\\Focus")?.x, SkinState.maxPosition)
            t.equal(state.skin("App\\Focus")?.y, -SkinState.maxPosition)
            state.update("App\\Focus") { $0.x = 5e200; $0.y = .nan }
            t.equal(state.skin("App\\Focus")?.x, SkinState.maxPosition)
            t.equal(state.skin("App\\Focus")?.y, nil)

            // The Manage window shows saved coordinates of a skin that is not loaded (Int conversion of huge values
            // used to trap).
            guard let app = try makeApp(t) else { return }
            app.state.update("App\\Controls") { $0.file = "Controls.ini"; $0.active = false; $0.x = 9e99; $0.y = 12 }
            let manage = ManageWindowController(app: app)
            manage.select(config: "App\\Controls", file: "Controls.ini")
            t.equal(manage.testLoadButtonTitle, "Load")
            manage.close()
        }

        t.suite("App: skin scan stops after a bounded number of folders (review)") {
            // A symlink into a big tree with few .ini files: the config limit alone never stops the walk.
            let root = t.temporaryDirectory("scan-limit")
            for i in 0..<30 {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Big/Empty\(i)/Deeper"),
                                                        withIntermediateDirectories: true)
            }
            let ini = root.appendingPathComponent("Big/Empty29/Deeper/Skin.ini")
            try "[Rainmeter]\n".write(to: ini, atomically: true, encoding: .utf8)
            t.equal(SkinLibrary.scan(root).map(\.name), ["Big\\Empty29\\Deeper"], "found with the default limit")
            t.equal(SkinLibrary.scan(root, folderLimit: 10).count, 0, "the walk stops at the folder limit")
            t.check(SkinLibrary.maxFolders >= 10_000, "the default limit leaves room for large libraries")
        }

        t.suite("App: log size is bounded while running (review)") {
            let dir = t.temporaryDirectory("log")
            let saved = (Log.directory, Log.maxLogSize, Log.fileLoggingEnabled, Log.mirrorsToStandardError)
            defer {
                Log.directory = saved.0
                Log.maxLogSize = saved.1
                Log.fileLoggingEnabled = saved.2
                Log.mirrorsToStandardError = saved.3
            }
            Log.directory = dir
            Log.maxLogSize = 20_000
            Log.fileLoggingEnabled = true
            Log.mirrorsToStandardError = false
            // A skin logging on every update (say an unsupported bang in OnUpdateAction) for a long time.
            for i in 0..<2_000 {
                Log.write("Unsupported bang: !SomeWindowsBang \(i) " + String(repeating: "x", count: 60), level: .warning,
                          source: "Suite\\Skin")
            }
            Log.flush()
            let size = { (name: String) -> Int in
                (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size]
                    as? Int ?? 0
            }
            t.check(size("Deskset.log") > 0 && size("Deskset.log") <= 20_000 + Log.maxLineLength + 200,
                    "current log stays under the limit: \(size("Deskset.log"))")
            t.check(size("Deskset.old.log") > 0 && size("Deskset.old.log") <= 20_000 + Log.maxLineLength + 200,
                    "one rotated log: \(size("Deskset.old.log"))")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            t.equal(files.sorted(), ["Deskset.log", "Deskset.old.log"])
            let last = (try? String(contentsOf: dir.appendingPathComponent("Deskset.log"), encoding: .utf8)) ?? ""
            t.check(last.contains("!SomeWindowsBang 1999 "), "the newest line is in the current log")
        }

        t.suite("App: manage window changes only the edited setting (review)") {
            guard let app = try makeApp(t), let focus = app.activate(config: "App\\Focus", file: "Focus.ini") else {
                return
            }
            let manage = ManageWindowController(app: app)
            manage.select(config: "App\\Focus", file: "Focus.ini")
            // An AlphaValue the slider cannot show (it stops at 90% transparency), e.g. an "invisible until hovered"
            // skin, and one between the 10% steps.
            for alpha in [1, 200] {
                focus.skin.execute("[!SetTransparency \(alpha)][!FadeDuration 400]", from: nil)
                let draggable = focus.state.draggable
                manage.testDraggableBox.performClick(nil)
                t.equal(focus.state.draggable, !draggable, "the checkbox applies")
                t.equal(focus.state.alphaValue, alpha, "clicking Draggable keeps AlphaValue \(alpha)")
                t.equal(focus.state.fadeDuration, 400)
            }
            // An empty fade field is not read as 0.
            manage.testFadeField.stringValue = ""
            manage.testFadeField.sendAction(manage.testFadeField.action, to: manage.testFadeField.target)
            t.equal(focus.state.fadeDuration, 400)
            manage.testFadeField.stringValue = "900"
            manage.testFadeField.sendAction(manage.testFadeField.action, to: manage.testFadeField.target)
            t.equal(focus.state.fadeDuration, 900)
            // The slider itself still sets the transparency.
            manage.testTransparencySlider.integerValue = 50
            manage.testTransparencySlider.sendAction(manage.testTransparencySlider.action,
                                                     to: manage.testTransparencySlider.target)
            t.equal(focus.state.alphaValue, ManageModel.alpha(forTransparencyPercent: 50))
            manage.close()
        }
    }

    // MARK: Connectivity

    static func connectivityReviewTests(_ t: AppTestRunner) {
        t.suite("App: SysInfo connectivity (review)") {
            let m = SystemMonitor.shared
            func number(_ type: String) -> Double { m.sysInfo(type: type, data: "")?.number ?? 0 }
            // Being on the Internet over a protocol version needs a routable address of that version.
            if number("INTERNET_CONNECTIVITY_V6") == 1 {
                t.equal(number("LAN_CONNECTIVITY_V6"), 1, "IPv6 Internet without a routable IPv6 address")
            }
            if number("INTERNET_CONNECTIVITY_V4") == 1 {
                t.equal(number("LAN_CONNECTIVITY_V4"), 1, "IPv4 Internet without a routable IPv4 address")
            }
            // And a default route of that version (what `scutil --nwi` shows).
            for (family, type) in [("IPv4", "INTERNET_CONNECTIVITY_V4"), ("IPv6", "INTERNET_CONNECTIVITY_V6")] {
                let store = SCDynamicStoreCreate(nil, "DesksetTest" as CFString, nil, nil)
                let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/\(family)" as CFString) }
                if global == nil {
                    t.equal(number(type), -1, "\(type) without a \(family) default route")
                }
            }
            let all = number("INTERNET_CONNECTIVITY")
            t.check(all == max(number("INTERNET_CONNECTIVITY_V4"), number("INTERNET_CONNECTIVITY_V6")),
                    "INTERNET_CONNECTIVITY is V4 or V6")
            t.equal(m.bestNetworkInterface(), m.resolveAdapter("Best"))
        }

        t.suite("App: network volumes are not read on the main thread (review)") {
            let mounts: [(path: String, local: Bool)] = [
                ("/", true), ("/System/Volumes/Data", true), ("/Volumes/NAS", false), ("/Volumes/NAS/inner", true),
                ("/Volumes/USB", true), ("/Network/Servers", false),
            ]
            t.equal(SystemMonitor.mountIsLocal("/", mounts: mounts), true)
            t.equal(SystemMonitor.mountIsLocal("/Users/me", mounts: mounts), true)
            t.equal(SystemMonitor.mountIsLocal("/Volumes/NAS", mounts: mounts), false)
            t.equal(SystemMonitor.mountIsLocal("/Volumes/NAS/Movies/", mounts: mounts), false)
            t.equal(SystemMonitor.mountIsLocal("/Volumes/NAS/inner/x", mounts: mounts), true, "longest mount wins")
            t.equal(SystemMonitor.mountIsLocal("/Volumes/NASBackup", mounts: mounts), true, "not a prefix match")
            t.equal(SystemMonitor.mountIsLocal("/Network/Servers/box/share", mounts: mounts), false)
            t.equal(SystemMonitor.mountIsLocal("/Volumes/USB/../NAS", mounts: mounts), false, "standardized")
            t.equal(SystemMonitor.mountIsLocal("/x", mounts: []), nil)
            // Local volumes still answer at once.
            let m = SystemMonitor.shared
            t.check(m.diskSpace(path: "/") != nil, "startup volume read synchronously")
            t.check(m.diskSpace(path: NSHomeDirectory()) != nil)
            t.check(m.diskSpace(path: "/no/such/path") == nil)
        }
    }

    // MARK: Install

    static func installReviewTests(_ t: AppTestRunner) {
        t.suite("App: install over a running skin loads it once (review)") {
            guard let app = try makeApp(t), let observer = app.activate(config: "App\\Observer", file: nil) else { return }
            let manifest = "[rmskin]\nName=Counted\nAuthor=Deskset tests\nVersion=1\nLoadType=Skin\nLoad=Counted\\Widget\\Widget.ini\n"
            let skin = "[Rainmeter]\nUpdate=1000\n"
                + "OnRefreshAction=[!UpdateMeasure MeasureLoads \"App\\Observer\"]\n"
                + "OnCloseAction=[!UpdateMeasure MeasureCloses \"App\\Observer\"]\n"
                + "[M]\nMeter=String\nText=Counted\n"
            let url = try makePackage(t, name: "Counted.rmskin", files: [
                "RMSKIN.ini": Data(manifest.utf8),
                "Skins/Counted/Widget/Widget.ini": Data(skin.utf8),
            ])
            func count(_ measure: String) -> Double { observer.skin.measure(named: measure)?.value ?? -1 }
            t.close(count("MeasureLoads"), 1)
            app.installer.open([url])
            spin { app.controller(for: "Counted\\Widget") != nil && app.installer.isIdle }
            t.close(count("MeasureLoads"), 2, "first install loads the skin once")
            let first = app.controller(for: "Counted\\Widget")
            app.installer.open([url])
            spin { app.installer.isIdle && app.controller(for: "Counted\\Widget") !== first }
            t.check(app.controller(for: "Counted\\Widget") != nil)
            t.close(count("MeasureLoads"), 3, "reinstalling loads the new skin once")
            t.close(count("MeasureCloses"), 2, "and closes the old one once")
        }
    }
}

extension AppSelfTest {
    static func recursionReviewTests(_ t: AppTestRunner) {
        t.suite("App: skins refreshing each other do not recurse without bound (review)") {
            guard let app = try makeApp(t) else { return }
            app.activate(config: "App\\PingB", file: nil)
            // Loading A refreshes B, whose OnRefreshAction refreshes A, and so on.
            let a = app.activate(config: "App\\PingA", file: nil)
            t.check(a != nil || app.controller(for: "App\\PingA") != nil, "App\\PingA is running")
            // They keep refreshing each other on later run-loop turns; the app stays responsive.
            let end = Date().addingTimeInterval(0.3)
            while Date() < end { RenderCommand.wait(milliseconds: 20) }
            t.check(app.controller(for: "App\\PingA") != nil && app.controller(for: "App\\PingB") != nil,
                    "both skins still loaded")
            app.deactivate(config: "App\\PingA")
            app.deactivate(config: "App\\PingB")
            RenderCommand.wait(milliseconds: 50)
            t.equal(app.controllers.count, 0)
        }
    }
}

extension AppSelfTest {
    static func forwardRecursionReviewTests(_ t: AppTestRunner) {
        t.suite("App: skins updating each other stop instead of recursing (review)") {
            guard let app = try makeApp(t) else { return }
            let b = app.activate(config: "App\\PongB", file: nil)
            let a = app.activate(config: "App\\PongA", file: nil)
            t.check(a != nil && b != nil, "both load")
            if let a, let b {
                let before = a.skin.updateCount + b.skin.updateCount
                a.skin.update()
                let added = a.skin.updateCount + b.skin.updateCount - before
                t.check(added >= 2 && added <= SkinController.maxForwardDepth + 2, "bounded chain: \(added) updates")
            }
        }
    }
}
