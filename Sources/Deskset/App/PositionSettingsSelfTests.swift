import AppKit
import DesksetCore

/// Position settings and their actual menu actions use temporary skins and state.
enum PositionSettingsSelfTests {
    static func run(_ t: AppTestRunner) {
        monitorStateTests(t)
        representationStateTests(t)
        savedPositionTests(t)
        menuTests(t)
        legacyPositionMenuTests(t)
        selectedMenuTests(t)
        staleMenuTests(t)
        loadingMenuTests(t)
    }

    private static func monitorStateTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: monitor choices preserve expressions and relative placement") {
            var state = SkinState(file: "Card.ini")
            state.windowX = "(100 / 2)%R@2"
            state.windowY = "(30 + 10)B"
            state.anchorX = "25%"
            state.anchorY = "10"
            state.autoSelectScreen = true
            let size = CGSize(width: 200, height: 100)
            let position = resolved(state, size: size, screens: screens)!
            let primary = apply(.monitor(1), state, position, size: size)
            t.equal(primary.state.windowX, "(100 / 2)%R@1")
            t.equal(primary.state.windowY, "(30 + 10)B@1")
            t.check(!primary.state.autoSelectScreen)
            t.close(primary.destination?.x ?? -1, 670)
            t.close(primary.destination?.y ?? -1, 850)
            t.equal(primary.state.anchorX, state.anchorX)
            t.equal(primary.state.anchorY, state.anchorY)

            let defaultMonitor = apply(.monitor(nil), primary.state, primary.destination!, size: size)
            t.equal(defaultMonitor.state.windowX, "(100 / 2)%R")
            t.equal(defaultMonitor.state.windowY, "(30 + 10)B")
            t.close(defaultMonitor.destination?.x ?? -1, 670)
            t.close(defaultMonitor.destination?.y ?? -1, 850)
            let virtual = apply(.monitor(0), state, position, size: size)
            t.equal(virtual.state.windowX, "(100 / 2)%R@0")
            t.equal(virtual.state.windowY, "(30 + 10)B@0")
            t.close(virtual.destination?.x ?? -1, 1630)
            t.close(virtual.destination?.y ?? -1, 1030)
            for invalid in [-1, 33] {
                let ignored = apply(.monitor(invalid), state, position, size: size)
                t.equal(ignored.state, state)
                t.check(ignored.destination == nil)
            }

            var pixels = SkinState(file: "Card.ini")
            pixels.windowX = "(100 + 50)@2"
            pixels.windowY = "(80 / 2)@2"
            let moved = apply(.monitor(1), pixels, (1590, 40), size: size)
            t.close(moved.destination?.x ?? -1, 150, "pixel offsets carry from the previous display")
            t.close(moved.destination?.y ?? -1, 40)
            t.equal(moved.state.windowX, "(100 + 50)@1")
            t.equal(moved.state.windowY, "(80 / 2)@1")
        }

        t.suite("App: Position settings: automatic monitor uses the live frame and disabling retains suffixes") {
            var state = SkinState(file: "Card.ini")
            state.windowX = "(100 + 50)"
            state.windowY = "(80 / 2)"
            let position = (x: 1640.0, y: 200.0)
            let enabled = apply(.automaticMonitor(true), state, position)
            t.check(enabled.state.autoSelectScreen)
            t.equal(WindowPosition.parse(enabled.state.windowX ?? "", endLetter: "R")?.screen, 2)
            t.equal(WindowPosition.parse(enabled.state.windowY ?? "", endLetter: "B")?.screen, 2)
            checkPosition(t, enabled.state, expected: position)
            t.check(enabled.destination == nil, "automatic selection does not move the live window")
            let disabled = apply(.automaticMonitor(false), enabled.state, position)
            t.check(!disabled.state.autoSelectScreen)
            t.equal(disabled.state.windowX, enabled.state.windowX)
            t.equal(disabled.state.windowY, enabled.state.windowY)
            t.check(disabled.destination == nil)
            let noDisplay = SkinPositionSettings.applying(.automaticMonitor(true), to: state, position: position,
                size: CGSize(width: 200, height: 100), screens: [], zoomFactor: 1)
            t.check(noDisplay.state.autoSelectScreen)
            t.equal(noDisplay.state.windowX, state.windowX)
            t.equal(noDisplay.state.windowY, state.windowY)
        }
    }

    private static func representationStateTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: right, bottom and percentage changes preserve anchored zoomed geometry") {
            let changes: [SkinPositionSettings.Change] = [
                .fromRight(true), .fromBottom(true), .xAsPercentage(true), .yAsPercentage(true),
                .fromRight(false), .fromBottom(false), .xAsPercentage(false), .yAsPercentage(false)
            ]
            for zoom in [0.1, 1, 2.5, 5] {
                var state = SkinState(file: "Card.ini")
                state.windowX = "150@2"
                state.windowY = "240"
                state.anchorX = "25%R"
                state.anchorY = "12B"
                let size = CGSize(width: 200 * zoom, height: 100 * zoom)
                let point = resolved(state, size: size, screens: screens, zoom: zoom)!
                for change in changes {
                    let result = apply(change, state, point, size: size, zoom: zoom)
                    checkPosition(t, result.state, expected: point, size: size, zoom: zoom)
                    t.equal(result.state.anchorX, "25%R")
                    t.equal(result.state.anchorY, "12B")
                    t.equal(WindowPosition.parse(result.state.windowX ?? "", endLetter: "R")?.screen, 2)
                    t.equal(WindowPosition.parse(result.state.windowY ?? "", endLetter: "B")?.screen, nil)
                    t.check(result.destination == nil)
                    state = result.state
                }
                t.equal(WindowPosition.parse(state.windowX ?? "", endLetter: "R")?.fromEnd, false)
                t.equal(WindowPosition.parse(state.windowY ?? "", endLetter: "B")?.fromEnd, false)
                t.equal(WindowPosition.parse(state.windowX ?? "", endLetter: "R")?.percent, false)
                t.equal(WindowPosition.parse(state.windowY ?? "", endLetter: "B")?.percent, false)
            }
        }
    }

    private static func savedPositionTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: SavePosition off keeps the saved origin separate from a session drag") {
            var state = SkinState(file: "Card.ini")
            state.savePosition = false
            state.windowX = "(100 + 50)@2"
            state.windowY = "(80 / 2)@2"
            state.x = 1590
            state.y = 40
            let live = (x: 1800.0, y: 200.0)
            let saved = (x: 1590.0, y: 40.0)
            let changes: [SkinPositionSettings.Change] = [.fromRight(true), .fromBottom(true),
                .xAsPercentage(true), .yAsPercentage(true), .automaticMonitor(true)]
            for change in changes {
                let result = apply(change, state, live)
                checkPosition(t, result.state, expected: saved)
                t.equal(result.state.x, state.x)
                t.equal(result.state.y, state.y)
                t.check(result.destination == nil)
            }
            let primary = apply(.monitor(nil), state, live)
            t.equal(primary.state.windowX, "(100 + 50)")
            t.equal(primary.state.windowY, "(80 / 2)")
            t.close(primary.destination?.x ?? -1, 360, "only the live destination uses the temporary drag")
            t.close(primary.destination?.y ?? -1, 200)
            checkPosition(t, primary.state, expected: (150, 40))
            state.windowX = nil
            state.windowY = nil
            state.x = 150
            state.y = 40
            let legacy = apply(.fromRight(true), state, live)
            checkPosition(t, legacy.state, expected: (150, 40))
            t.equal(legacy.state.windowY, "40", "the first mode change fills the other axis of an older state")
        }
    }

    private static func legacyPositionMenuTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: first coordinate mode preserves both legacy axes after reloading") {
            for savePosition in [true, false] {
                for title in ["From right", "From bottom"] {
                    guard let (app, skins) = try fixture(t, count: 1), let skin = skins.first else { return }
                    let saved = (x: 150.0, y: 120.0)
                    app.changeSettings(of: skin) {
                        $0.x = saved.x
                        $0.y = saved.y
                        $0.windowX = nil
                        $0.windowY = nil
                        $0.savePosition = savePosition
                    }
                    if !savePosition { skin.moveTo(x: 740, y: 330) }
                    let live = skin.topLeftPosition
                    perform(positionMenu(app, skin)?.item(withTitle: title), t)
                    checkLivePosition(t, skin, expected: live)
                    let state = skin.state
                    t.check(state.windowX != nil && state.windowY != nil,
                            "the first mode edit completes both legacy coordinate expressions")
                    guard let point = resolved(state, size: skin.window.frame.size,
                        screens: EnvironmentStore.shared.currentScreens) else {
                        return t.check(false, "legacy coordinate expressions resolve")
                    }
                    t.close(point.x, saved.x)
                    t.close(point.y, saved.y)
                    t.equal(state.x, saved.x)
                    t.equal(state.y, saved.y)
                    app.deactivate(config: skin.config)
                    // Clearing only this fixture's transient position simulates reopening in a new app session.
                    app.sessionPositions.removeValue(forKey: skin.config.lowercased())
                    guard let replacement = app.activate(config: skin.config, file: skin.file) else {
                        return t.check(false, "legacy position fixture reloads")
                    }
                    t.check(AppSelfTest.spin { replacement.isStarted })
                    replacement.pauseUpdates()
                    checkLivePosition(t, replacement, expected: saved)
                }
            }
        }
    }

    private static func menuTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: actual menu order, checkmarks and actions") {
            guard let (app, skins) = try fixture(t, count: 1), let skin = skins.first,
                  let menu = positionMenu(app, skin) else { return t.check(false, "Position menu exists") }
            t.equal(menu.items.map { $0.isSeparatorItem ? "separator" : $0.title },
                ["Display monitor", "separator"] + ManageModel.positions.map(\.title)
                    + ["separator", "From right", "From bottom", "X as percentage", "Y as percentage"])
            let point = skin.topLeftPosition
            for title in representationTitles {
                t.equal(positionMenu(app, skin)?.item(withTitle: title)?.state, .off)
                perform(positionMenu(app, skin)?.item(withTitle: title), t)
                t.equal(positionMenu(app, skin)?.item(withTitle: title)?.state, .on)
                checkLivePosition(t, skin, expected: point)
            }
            for title in representationTitles {
                perform(positionMenu(app, skin)?.item(withTitle: title), t)
                t.equal(positionMenu(app, skin)?.item(withTitle: title)?.state, .off)
                checkLivePosition(t, skin, expected: point)
            }
            let monitorMenu = app.displayMonitorMenu(for: skin)
            let count = min(EnvironmentStore.shared.currentScreens.count, 32)
            t.equal(monitorMenu.items.count, count + 5)
            t.equal(monitorMenu.items.first?.title, "Use default: Primary monitor")
            t.check(monitorMenu.items[1].isSeparatorItem)
            t.equal(monitorMenu.items[2].title, "@0: Virtual screen")
            for index in 1...max(count, 1) where index <= count {
                t.check(monitorMenu.items[index + 2].title.hasPrefix("@\(index): "))
            }
            t.equal(monitorMenu.items.last?.title, "Auto-select based on window position")
            t.equal(monitorMenu.items.first?.state, .on)
            t.equal(monitorMenu.items.last?.state, .off)
            perform(monitorMenu.items.last, t)
            t.check(skin.state.autoSelectScreen)
            t.equal(app.displayMonitorMenu(for: skin).items.last?.state, .on)
            checkLivePosition(t, skin, expected: point)
            let encodedX = skin.state.windowX, encodedY = skin.state.windowY
            perform(app.displayMonitorMenu(for: skin).items.last, t)
            t.check(!skin.state.autoSelectScreen)
            t.equal(skin.state.windowX, encodedX)
            t.equal(skin.state.windowY, encodedY)

            app.changeSettings(of: skin) {
                $0.windowX = "(300 / 2)"
                $0.windowY = "(240 / 2)"
                $0.autoSelectScreen = true
            }
            perform(app.displayMonitorMenu(for: skin).item(withTitle: "@0: Virtual screen"), t)
            t.check(!skin.state.autoSelectScreen)
            t.equal(skin.state.windowX, "(300 / 2)@0", "a real monitor action retains the X formula")
            t.equal(skin.state.windowY, "(240 / 2)@0", "a real monitor action retains the Y formula")
            t.equal(app.displayMonitorMenu(for: skin).item(withTitle: "@0: Virtual screen")?.state, .on)
            perform(app.displayMonitorMenu(for: skin).items.first, t)
            t.equal(skin.state.windowX, "(300 / 2)")
            t.equal(skin.state.windowY, "(240 / 2)")
            t.equal(app.displayMonitorMenu(for: skin).items.first?.state, .on)
        }
    }

    private static func selectedMenuTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: selected skins show common modes and batch changes") {
            guard let (app, skins) = try fixture(t, count: 3) else { return }
            let first = skins[0], second = skins[1], other = skins[2]
            let firstPoint = first.topLeftPosition, secondPoint = second.topLeftPosition
            perform(positionMenu(app, first)?.item(withTitle: "From right"), t)
            app.skinSelection.toggle(first)
            app.skinSelection.toggle(second)
            t.equal(positionMenu(app, first)?.item(withTitle: "From right")?.state, .off,
                    "mixed values are unchecked")
            for title in representationTitles {
                perform(positionMenu(app, first)?.item(withTitle: title), t)
                t.equal(positionMenu(app, first)?.item(withTitle: title)?.state, .on)
                t.equal(positionMenu(app, second)?.item(withTitle: title)?.state, .on)
                t.equal(positionMenu(app, other)?.item(withTitle: title)?.state, .off)
                checkLivePosition(t, first, expected: firstPoint)
                checkLivePosition(t, second, expected: secondPoint)
            }
            perform(positionMenu(app, second)?.item(withTitle: "From right"), t)
            t.equal(positionMenu(app, first)?.item(withTitle: "From right")?.state, .off)
            t.equal(positionMenu(app, second)?.item(withTitle: "From right")?.state, .off)
            app.changeSettings(of: first) { $0.autoSelectScreen = true }
            t.equal(app.displayMonitorMenu(for: first).items.last?.state, .off)
            perform(app.displayMonitorMenu(for: first).items.last, t)
            t.check(first.state.autoSelectScreen && second.state.autoSelectScreen)
            t.check(!other.state.autoSelectScreen)
            t.equal(app.displayMonitorMenu(for: first).items.last?.state, .on)
            perform(app.displayMonitorMenu(for: second).items.first, t)
            t.check(!first.state.autoSelectScreen && !second.state.autoSelectScreen)
            t.check(WindowPosition.parse(first.state.windowX ?? "", endLetter: "R")?.screen == nil)
            t.check(WindowPosition.parse(second.state.windowY ?? "", endLetter: "B")?.screen == nil)
            app.skinSelection.clear()
            t.equal(positionMenu(app, first)?.item(withTitle: "X as percentage")?.state, .on,
                    "deselection preserves changes made through the group menu")
        }
    }

    private static func staleMenuTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: an unloaded instance's old menu cannot change its replacement") {
            guard let (app, skins) = try fixture(t, count: 1), let old = skins.first else { return }
            let mode = positionMenu(app, old)?.item(withTitle: "From right")
            let monitor = app.displayMonitorMenu(for: old).item(withTitle: "@0: Virtual screen")
            app.deactivate(config: old.config)
            t.check(old.isStopped)
            guard let replacement = app.activate(config: old.config, file: old.file) else {
                return t.check(false, "replacement skin loads")
            }
            t.check(AppSelfTest.spin { replacement.isStarted })
            replacement.pauseUpdates()
            let state = replacement.state, point = replacement.topLeftPosition
            perform(mode, t)
            perform(monitor, t)
            t.equal(replacement.state, state)
            checkLivePosition(t, replacement, expected: point)
        }
    }

    private static func loadingMenuTests(_ t: AppTestRunner) {
        t.suite("App: Position settings: loading skins cannot overwrite saved coordinates through menus") {
            guard let (app, skins) = try fixture(t, count: 1), let ready = skins.first else { return }
            let config = "Position\\Loading"
            let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "[Rainmeter]\nUpdate=-1\n[Card]\nMeter=Image\nW=200\nH=100\nSolidColor=40,70,90,255\n"
                .write(to: folder.appendingPathComponent("Card.ini"), atomically: true, encoding: .utf8)
            app.state.update(config) {
                $0.file = "Card.ini"
                $0.x = 150
                $0.y = 120
                $0.windowX = "(300 / 2)"
                $0.windowY = "(240 / 2)"
                $0.keepOnScreen = false
                $0.autoSelectScreen = false
            }
            let executor = SkinThreadExecutor(name: "Position loading")
            app.skinExecutor = { $0 == config ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var retainedSkin: Skin?
            autoreleasepool {
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(executor)
                defer { gate.open() }
                guard let loading = app.activate(config: config, file: "Card.ini") else {
                    return t.check(false, "the loading skin is registered immediately")
                }
                retainedSkin = loading.runtime.skin
                defer {
                    app.skinSelection.clear()
                    app.deactivate(config: config)
                }
                t.check(app.controller(for: config) === loading)
                t.check(!loading.isStarted)
                t.equal(loading.window.frame.size, CGSize(width: 1, height: 1), "the skin has not supplied its size")
                let savedX = loading.state.windowX, savedY = loading.state.windowY
                let manage = ManageWindowController(app: app)
                defer { manage.close() }
                manage.select(config: config, file: "Card.ini")
                t.check(!manage.testDisplayMonitorPopup.isEnabled, "Manage cannot edit the unplaced window")
                let disabledMonitor = app.displayMonitorMenu(for: loading)
                t.check(disabledMonitor.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
                let disabledPosition = positionMenu(app, loading)
                t.equal(disabledPosition?.item(withTitle: "Display monitor")?.isEnabled, false)
                for title in representationTitles {
                    let choice = disabledPosition?.item(withTitle: title)
                    t.equal(choice?.isEnabled, false)
                    perform(choice, t)
                }
                perform(disabledMonitor.item(withTitle: "@0: Virtual screen"), t)
                perform(disabledMonitor.items.last, t)
                t.equal(loading.state.windowX, savedX, "forced action dispatch cannot encode the placeholder frame")
                t.equal(loading.state.windowY, savedY)
                t.check(!loading.state.autoSelectScreen)

                let oldReadyMode = positionMenu(app, ready)?.item(withTitle: "From right")
                let oldReadyMonitor = app.displayMonitorMenu(for: ready).item(withTitle: "@0: Virtual screen")
                t.equal(oldReadyMode?.isEnabled, true)
                t.equal(oldReadyMonitor?.isEnabled, true)
                app.skinSelection.toggle(ready)
                app.skinSelection.toggle(loading)
                let readyState = ready.state
                let grouped = positionMenu(app, ready)
                for title in representationTitles {
                    t.equal(grouped?.item(withTitle: title)?.isEnabled, false,
                            "a loading peer disables the entire selected group's coordinate edit")
                }
                t.check(app.displayMonitorMenu(for: ready).items
                    .filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
                perform(oldReadyMode, t)
                perform(oldReadyMonitor, t)
                t.equal(ready.state, readyState, "an earlier enabled action cannot partially edit a loading group")
                t.equal(loading.state.windowX, savedX)
                t.equal(loading.state.windowY, savedY)

                gate.open()
                t.check(AppSelfTest.spin(timeout: 30) { loading.isStarted }, "the engine reports its real dimensions")
                loading.pauseUpdates()
                t.equal(loading.window.frame.size, CGSize(width: 200, height: 100))
                checkLivePosition(t, loading, expected: (150, 120))
                t.equal(loading.state.windowX, savedX)
                t.equal(loading.state.windowY, savedY)
                t.check(AppSelfTest.spin { manage.testDisplayMonitorPopup.isEnabled },
                        "Manage follows the started notification")
                t.check(app.displayMonitorMenu(for: ready).items
                    .filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled))
                t.equal(positionMenu(app, ready)?.item(withTitle: "From right")?.isEnabled, true)
                let readyPoint = ready.topLeftPosition, loadingPoint = loading.topLeftPosition
                perform(positionMenu(app, ready)?.item(withTitle: "From right"), t)
                t.equal(positionMenu(app, ready)?.item(withTitle: "From right")?.state, .on)
                t.equal(positionMenu(app, loading)?.item(withTitle: "From right")?.state, .on)
                checkLivePosition(t, ready, expected: readyPoint)
                checkLivePosition(t, loading, expected: loadingPoint)
            }
            SkinLifecycleSelfTests.finish(t, skin: { retainedSkin }, executor)
        }
    }

    private static let representationTitles = ["From right", "From bottom", "X as percentage", "Y as percentage"]
    private static let screens = [AppSelfTest.screen, AppSelfTest.screen2]

    private static func apply(_ change: SkinPositionSettings.Change, _ state: SkinState,
                              _ position: (x: Double, y: Double), size: CGSize = CGSize(width: 200, height: 100),
                              zoom: Double = 1) -> SkinPositionSettings.Result {
        SkinPositionSettings.applying(change, to: state, position: position, size: size, screens: screens,
                                      zoomFactor: zoom)
    }

    private static func resolved(_ state: SkinState, size: CGSize, screens: [WindowGeometry.Screen],
                                 zoom: Double = 1) -> (x: Double, y: Double)? {
        WindowPosition.resolve(x: state.windowX ?? "0", y: state.windowY ?? "0", anchorX: state.anchorX ?? "0",
            anchorY: state.anchorY ?? "0", skinSize: size, screens: screens, zoomFactor: zoom)
    }

    private static func checkPosition(_ t: AppTestRunner, _ state: SkinState, expected: (x: Double, y: Double),
                                      size: CGSize = CGSize(width: 200, height: 100), zoom: Double = 1) {
        guard let point = resolved(state, size: size, screens: screens, zoom: zoom) else {
            return t.check(false, "saved position resolves")
        }
        t.close(point.x, expected.x)
        t.close(point.y, expected.y)
    }

    private static func checkLivePosition(_ t: AppTestRunner, _ skin: SkinWindowController,
                                          expected: (x: Double, y: Double)) {
        t.close(skin.topLeftPosition.x, expected.x, accuracy: 0.01)
        t.close(skin.topLeftPosition.y, expected.y, accuracy: 0.01)
    }

    private static func fixture(_ t: AppTestRunner, count: Int) throws -> (AppController, [SkinWindowController])? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        var skins: [SkinWindowController] = []
        for index in 0..<count {
            let config = "Position\\Card\(index)"
            let folder = SkinLibrary.directory(for: config, root: app.skinsDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "[Rainmeter]\nUpdate=-1\n[Card]\nMeter=Image\nW=200\nH=100\nSolidColor=40,70,90,255\n"
                .write(to: folder.appendingPathComponent("Card.ini"), atomically: true, encoding: .utf8)
            guard let skin = app.activate(config: config, file: "Card.ini") else {
                t.check(false, "position fixture loads")
                return nil
            }
            t.check(AppSelfTest.spin { skin.isStarted && skin.window.frame.size == CGSize(width: 200, height: 100) })
            skin.pauseUpdates()
            app.changeSettings(of: skin) { $0.keepOnScreen = false; $0.autoSelectScreen = false }
            skin.moveTo(x: 150 + Double(index) * 230, y: 120)
            skins.append(skin)
        }
        return (app, skins)
    }

    private static func positionMenu(_ app: AppController, _ skin: SkinWindowController) -> NSMenu? {
        app.skinMenu(for: skin, includeCustomItems: true).item(withTitle: "Settings")?
            .submenu?.item(withTitle: "Position")?.submenu
    }

    private static func perform(_ item: NSMenuItem?, _ t: AppTestRunner) {
        guard let item, let action = item.action else { return t.check(false, "menu action exists") }
        t.check(NSApp.sendAction(action, to: item.target, from: item), "menu action is connected")
    }
}
