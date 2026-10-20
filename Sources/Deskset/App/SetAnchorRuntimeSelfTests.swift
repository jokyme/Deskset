import AppKit
import DesksetCore

/// Position commands run through temporary desktop skins, their real window controllers and executor mailboxes.
enum SetAnchorRuntimeSelfTests {
    static func run(_ t: AppTestRunner) {
        for mode in [SkinThreading.main, .engine, .pool] {
            routingTests(t, mode)
            sessionTests(t, mode)
            heldTests(t, mode)
            initialTests(t, mode)
            initialNoSaveTests(t, mode)
            invalidInitialTests(t, mode)
        }
        for mode in [SkinThreading.engine, .pool] {
            loadingPeerTests(t, mode)
            initialHeldNoSaveTests(t, mode)
        }
    }

    private static func routingTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: current, explicit, all and compound group targets preserve saved expressions (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            let names = ["Source", "Both", "OnlyA", "Outside"]
            for (name, group) in zip(names, ["a|b", "a|b", "a", "c"]) {
                try write(app, name, group: group)
                seed(app, name) { $0.windowX = "(100 / 2)%R@1"; $0.windowY = "30%B@1" }
            }
            let skins = names.compactMap { load(t, app, $0) }
            guard skins.count == names.count else { return }
            let source = skins[0], peer = skins[1]
            send(source, "[!SetAnchor 0 0]")
            drain(t, app)
            t.equal(source.state.anchorX, "0")
            t.equal(peer.state.anchorX, "50%", "omitting Config selects only the source")
            send(source, "[!Skin:SetAnchor \(peer.config) 10%R 20%B]")
            drain(t, app)
            t.equal(peer.state.anchorX, "10%R")
            t.equal(peer.state.anchorY, "20%B")
            send(source, "[!SetAnchor 25% 25% *]")
            drain(t, app)
            t.check(skins.allSatisfy { $0.state.anchorX == "25%" && $0.state.anchorY == "25%" })
            send(source, "[!Skin:SetAnchor Group=a&b 0 0]")
            drain(t, app)
            t.equal(skins.map { $0.state.anchorX }, ["0", "0", "25%", "25%"])
            let sequences = skins.map { c in c.runtime.exclusive(timeout: 30) { _ in c.runtime.model.sequence } ?? -1 }
            send(source, "[!SetAnchor 10 20 Group=a|b]")
            drain(t, app)
            t.equal(skins.map { $0.state.anchorX }, ["10", "10", "10", "25%"])
            t.equal(zip(skins, sequences).map { c, before in
                (c.runtime.exclusive(timeout: 30) { _ in c.runtime.model.sequence } ?? -1) - before
            }, [1, 1, 1, 0], "a skin in both OR groups receives SetAnchor once")
            send(source, "[!SetAnchor 99 99 Group=a|b&c]")
            drain(t, app)
            t.equal(skins.map { $0.state.anchorX }, ["10", "10", "10", "25%"], "mixed selectors match nothing")
            for c in skins {
                t.equal(c.state.windowX, "(100 / 2)%R@1")
                t.equal(c.state.windowY, "30%B@1")
                // AppKit aligns a panel's fractional screen position to whole points.
                checkPosition(t, c, expected: resolve(c.state, size: c.window.frame.size), accuracy: 1)
                t.check(c.runtime.snapshot.issues.allSatisfy { !$0.localizedCaseInsensitiveContains("SetAnchor") })
            }
            let saved = peer.state, point = peer.topLeftPosition
            app.sessionPositions.removeValue(forKey: peer.config.lowercased())
            guard let reloaded = app.refresh(peer) else { return t.check(false, "the anchored variant reloads") }
            drain(t, app)
            t.check(AppSelfTest.spin(timeout: 30) { reloaded.isStarted })
            t.equal(reloaded.state.anchorX, saved.anchorX)
            t.equal(reloaded.state.windowX, saved.windowX)
            t.equal(reloaded.state.windowY, saved.windowY)
            checkPosition(t, reloaded, expected: point)
        }
    }

    private static func sessionTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: SavePosition off keeps a session drag separate from saved origins (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            try write(app, "Session")
            seed(app, "Session") { $0.savePosition = false }
            guard let c = load(t, app, "Session") else { return }
            let saved = c.state
            drag(t, c, by: NSPoint(x: 45, y: -35))
            drain(t, app)
            let dragged = c.topLeftPosition
            t.close(dragged.x, 345)
            t.close(dragged.y, 285)
            send(c, "[!SetAnchor 0 0]")
            drain(t, app)
            checkPosition(t, c, expected: (dragged.x + 100, dragged.y + 50))
            t.equal(c.state.windowX, saved.windowX)
            t.equal(c.state.windowY, saved.windowY)
            t.equal(c.state.x, saved.x)
            t.equal(c.state.y, saved.y)
            t.equal(c.state.anchorX, "0")

            try write(app, "Legacy")
            seed(app, "Legacy") { $0.savePosition = false; $0.windowX = nil; $0.windowY = nil }
            app.sessionPositions[config("Legacy").lowercased()] = (700, 400)
            guard let legacy = load(t, app, "Legacy") else { return }
            checkPosition(t, legacy, expected: (700, 400))
            send(legacy, "[!SetAnchor 0 0]")
            drain(t, app)
            checkPosition(t, legacy, expected: (800, 450))
            t.equal(legacy.state.windowX, "400", "legacy saved X uses its own old anchor, never the session drag")
            t.equal(legacy.state.windowY, "300")
            app.sessionPositions.removeValue(forKey: legacy.config.lowercased())
            guard let restored = app.refresh(legacy) else { return t.check(false, "legacy refresh loads") }
            drain(t, app)
            t.check(AppSelfTest.spin(timeout: 30) { restored.isStarted })
            checkPosition(t, restored, expected: (400, 300))

            try write(app, "MissingY")
            seed(app, "MissingY") { $0.windowY = nil }
            guard let missing = load(t, app, "MissingY") else { return }
            send(missing, "[!SetAnchor 0 0]")
            drain(t, app)
            t.equal(missing.state.windowX, "400")
            t.equal(missing.state.windowY, nil, "one omitted raw axis retains its zero origin")
            checkPosition(t, missing, expected: (400, 0))

            try write(app, "LegacySaved")
            seed(app, "LegacySaved") { $0.windowX = nil; $0.windowY = nil }
            app.sessionPositions[config("LegacySaved").lowercased()] = (800, 500)
            guard let savedLegacy = load(t, app, "LegacySaved") else { return }
            checkPosition(t, savedLegacy, expected: (300, 250))
            send(savedLegacy, "[!SetAnchor 0 0]")
            drain(t, app)
            t.equal(savedLegacy.state.windowX, "400")
            t.equal(savedLegacy.state.windowY, "300")
            checkPosition(t, savedLegacy, expected: (400, 300))
            app.sessionPositions.removeValue(forKey: savedLegacy.config.lowercased())
            guard let fresh = app.refresh(savedLegacy) else { return t.check(false, "saved legacy result reloads") }
            drain(t, app)
            t.check(AppSelfTest.spin(timeout: 30) { fresh.isStarted })
            checkPosition(t, fresh, expected: (400, 300))
        }
    }

    private static func heldTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: held Move and Anchor keep their order at release and across reload (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            for (index, action, expected) in [
                (0, "[!Move 500 350][!SetAnchor 0 0]", (x: 600.0, y: 400.0)),
                (1, "[!SetAnchor 0 0][!Move 500 350]", (x: 500.0, y: 350.0)),
            ] {
                let name = "Held\(index)"
                try write(app, name)
                seed(app, name)
                guard let c = load(t, app, name) else { return }
                let before = c.window.frame
                c.beginDragPress()
                send(c, action)
                drain(t, app, expectingHeld: c)
                t.equal(c.window.frame, before, "the skin's requested position waits for release")
                t.check(c.heldMove != nil)
                c.endDragPress(moved: false)
                drain(t, app)
                t.check(c.heldMove == nil && !c.isDragPressActive)
                t.equal(c.state.anchorX, "0")
                t.equal(c.state.anchorY, "0")
                checkPosition(t, c, expected: expected)
                checkPosition(t, c, expected: resolve(c.state, size: c.window.frame.size))
                app.sessionPositions.removeValue(forKey: c.config.lowercased())
                guard let refreshed = app.refresh(c) else { return t.check(false, "held result reloads") }
                drain(t, app)
                t.check(AppSelfTest.spin(timeout: 30) { refreshed.isStarted })
                checkPosition(t, refreshed, expected: expected)
            }

            try write(app, "DragWins")
            seed(app, "DragWins")
            guard let c = load(t, app, "DragWins") else { return }
            drag(t, c, by: NSPoint(x: 40, y: -30), whileHeld: {
                send(c, "[!Move 500 350][!SetAnchor 0 0]")
                drain(t, app, expectingHeld: c)
                t.check(c.heldMove != nil)
            })
            drain(t, app)
            t.check(c.heldMove == nil)
            t.equal(c.state.anchorX, "50%", "a real drag discards the held anchor with the held move")
            t.equal(c.state.anchorY, "50%")
            checkPosition(t, c, expected: (340, 280))
        }
    }

    private static func initialTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: OnRefresh uses actual 200-point bounds for saved, legacy and new placement (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            for kind in ["Raw", "Legacy", "New"] {
                for (index, action, expected) in [
                    (0, "[!SetAnchor 0 0]", (x: 400.0, y: 300.0)),
                    (1, "[!Move 500 350][!SetAnchor 0 0]", (x: 600.0, y: 400.0)),
                    (2, "[!SetAnchor 0 0][!Move 500 350]", (x: 500.0, y: 350.0)),
                ] {
                    let name = "Initial\(kind)\(index)"
                    try write(app, name, onRefresh: action, defaults: kind == "New")
                    if kind != "New" {
                        seed(app, name) { if kind == "Legacy" { $0.windowX = nil; $0.windowY = nil } }
                    }
                    guard let c = load(t, app, name) else { return }
                    t.equal(c.window.frame.size, CGSize(width: 200, height: 100))
                    t.equal(c.state.anchorX, "0")
                    t.equal(c.state.anchorY, "0", "first placement cannot seed old defaults over a completed bang")
                    checkPosition(t, c, expected: expected)
                    checkPosition(t, c, expected: resolve(c.state, size: c.window.frame.size))
                }
            }
        }
    }

    private static func initialNoSaveTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: new default and cascade origins save their first position even with SavePosition off (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            for cascade in [false, true] {
                for moveAfter in [false, true] {
                    let name = "NewNoSave\(cascade ? "Cascade" : "Default")\(moveAfter ? "Move" : "Anchor")"
                    let action = "[!SetAnchor 0 0]" + (moveAfter ? "[!Move 500 350]" : "")
                    try write(app, name, onRefresh: action, defaults: true,
                              defaultSavePosition: false, cascade: cascade)
                    let expected = initialOrigin(app, cascade: cascade)
                    guard let c = load(t, app, name) else { return }
                    t.check(!c.state.savePosition)
                    t.equal(c.state.anchorX, "0")
                    t.equal(c.state.anchorY, "0")
                    t.check(c.state.windowX != nil && c.state.windowY != nil,
                            "first placement materializes an origin instead of saving nil from old main-thread settings")
                    checkPosition(t, c, expected: moveAfter ? (500, 350) : expected)
                    let saved = resolve(c.state, size: c.window.frame.size)
                    t.close(saved.x, expected.x, accuracy: 0.01, "a later temporary Move cannot consume first-save twice")
                    t.close(saved.y, expected.y, accuracy: 0.01)
                    try write(app, name, defaults: true, defaultSavePosition: false, cascade: cascade)
                    app.sessionPositions.removeValue(forKey: c.config.lowercased())
                    guard let fresh = app.refresh(c) else { return t.check(false, "the first anchored position reloads") }
                    drain(t, app)
                    t.check(AppSelfTest.spin(timeout: 30) { fresh.isStarted })
                    checkPosition(t, fresh, expected: expected)
                }
            }
        }
    }

    private static func initialHeldNoSaveTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: a first held Anchor then Move keeps live movement separate from its one-time saved origin (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            for cascade in [false, true] {
                let name = cascade ? "HeldNewCascade" : "HeldNewDefault"
                try write(app, name, onRefresh: "[!SetAnchor 0 0][!Move 500 350]", defaults: true,
                          defaultSavePosition: false, cascade: cascade)
                let expected = initialOrigin(app, cascade: cascade)
                let gate = SkinLifecycleSelfTests.Gate()
                gate.hold(app.skinExecutor(config(name)))
                defer { gate.open() }
                guard let c = app.activate(config: config(name), file: "Skin.ini") else {
                    return t.check(false, "the initially held skin is registered")
                }
                c.beginDragPress()
                gate.open()
                t.check(AppSelfTest.spin(timeout: 30) { c.isStarted && c.heldMove != nil })
                drain(t, app, expectingHeld: c)
                c.endDragPress(moved: false)
                drain(t, app)
                t.check(!c.state.savePosition)
                t.equal(c.state.anchorX, "0")
                t.equal(c.state.anchorY, "0")
                checkPosition(t, c, expected: (500, 350))
                let saved = resolve(c.state, size: c.window.frame.size)
                t.close(saved.x, expected.x, accuracy: 0.01)
                t.close(saved.y, expected.y, accuracy: 0.01)
                try write(app, name, defaults: true, defaultSavePosition: false, cascade: cascade)
                app.sessionPositions.removeValue(forKey: c.config.lowercased())
                guard let fresh = app.refresh(c) else { return t.check(false, "the held first origin reloads") }
                drain(t, app)
                t.check(AppSelfTest.spin(timeout: 30) { fresh.isStarted })
                checkPosition(t, fresh, expected: expected)
            }
        }
    }

    private static func invalidInitialTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: invalid OnRefresh anchors leave initial state and sequence unchanged (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            try write(app, "Invalid", onRefresh: "[!SetAnchor nonsense 0][!SetAnchor 0 nonsense]"
                + "[!SetAnchor 0 20@1][!SetAnchor 50%]")
            seed(app, "Invalid")
            let before = app.state.skin(config("Invalid"))
            guard let c = load(t, app, "Invalid") else { return }
            t.equal(c.state, before)
            t.equal(c.runtime.exclusive(timeout: 30) { _ in c.runtime.model.sequence }, 0)
            t.equal(app.sessionPositions[c.config.lowercased()]?.0, nil)
            checkPosition(t, c, expected: (300, 250))
        }
    }

    private static func loadingPeerTests(_ t: AppTestRunner, _ mode: SkinThreading) {
        t.suite("App: SetAnchor: a peer command after load but before started is not overwritten by initial seeding (\(mode))") {
            guard let app = try fixture(t, mode) else { return }
            try write(app, "Ready")
            seed(app, "Ready")
            guard let source = load(t, app, "Ready") else { return }
            try write(app, "Loading")
            seed(app, "Loading")
            let gate = SkinLifecycleSelfTests.Gate()
            gate.hold(app.skinExecutor(config("Loading")))
            defer { gate.open() }
            guard let loading = app.activate(config: config("Loading"), file: "Skin.ini") else {
                return t.check(false, "the asynchronous target is registered")
            }
            t.check(!loading.isStarted)
            t.equal(loading.window.frame.size, CGSize(width: 1, height: 1))
            gate.open()
            // Runtime loads never wait for main; do not pump main until both executor messages have completed.
            t.equal(loading.runtime.exclusive(timeout: 30) { $0.meter(named: "Card") != nil }, true)
            t.check(!loading.isStarted)
            let beforeInvalid = loading.runtime.exclusive(timeout: 30) { _ in loading.runtime.model }
            let beforeState = loading.state, beforeFrame = loading.window.frame
            let beforeSession = app.sessionPositions[loading.config.lowercased()]
            send(loading, "[!SetAnchor nonsense 0]")
            let afterInvalid = loading.runtime.exclusive(timeout: 30) { _ in loading.runtime.model }
            t.equal(afterInvalid?.frame, beforeInvalid?.frame, "an invalid anchor cannot place the placeholder")
            t.equal(afterInvalid?.sequence, beforeInvalid?.sequence)
            t.equal(afterInvalid?.settings, beforeInvalid?.settings)
            t.equal(loading.state, beforeState)
            t.equal(loading.window.frame, beforeFrame)
            t.equal(app.sessionPositions[loading.config.lowercased()]?.0, beforeSession?.0)
            t.equal(app.sessionPositions[loading.config.lowercased()]?.1, beforeSession?.1)
            let oldSequence = loading.runtime.exclusive(timeout: 30) { _ in loading.runtime.model.sequence }
            send(source, "[!SetAnchor 0 0 \(loading.config)]")
            t.equal(source.runtime.exclusive(timeout: 30) { _ in true }, true)
            t.equal(loading.runtime.exclusive(timeout: 30) { _ in loading.runtime.model.settings.anchorX }, "0")
            t.equal(loading.runtime.exclusive(timeout: 30) { _ in loading.runtime.model.sequence }, (oldSequence ?? 0) + 1)
            t.check(!loading.isStarted)
            t.equal(loading.window.frame.size, CGSize(width: 1, height: 1), "main still has the unplaced window")
            drain(t, app)
            t.check(AppSelfTest.spin(timeout: 30) { loading.isStarted })
            t.equal(loading.state.anchorX, "0")
            t.equal(loading.state.anchorY, "0")
            t.equal(loading.state.windowX, "400")
            t.equal(loading.state.windowY, "300")
            checkPosition(t, loading, expected: (400, 300))
        }
    }

    private static func fixture(_ t: AppTestRunner, _ mode: SkinThreading) throws -> AppController? {
        EnvironmentStore.shared.publish()
        guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return nil }
        t.atSuiteEnd {
            let threads = (app.engineThread.map { [$0] } ?? []) + (app.skinThreadPool?.activeWorkers ?? [])
            app.stopAllForTermination()
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { threads.allSatisfy(\.hasExited) }, "SetAnchor fixture threads exited")
        }
        return app
    }

    private static func config(_ name: String) -> String { "Anchor\\\(name)" }

    private static func seed(_ app: AppController, _ name: String, _ change: (inout SkinState) -> Void = { _ in }) {
        app.state.update(config(name)) {
            $0.file = "Skin.ini"
            $0.x = 300; $0.y = 250
            $0.windowX = "400"; $0.windowY = "300"
            $0.anchorX = "50%"; $0.anchorY = "50%"
            $0.keepOnScreen = false; $0.snapEdges = false; $0.autoSelectScreen = false
            change(&$0)
        }
    }

    private static func write(_ app: AppController, _ name: String, group: String = "", onRefresh: String = "",
                              defaults: Bool = false, defaultSavePosition: Bool = true, cascade: Bool = false) throws {
        let folder = SkinLibrary.directory(for: config(name), root: app.skinsDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let initial = defaults ? (cascade ? "" : "DefaultWindowX=400\nDefaultWindowY=300\n")
            + "DefaultAnchorX=50%\nDefaultAnchorY=50%\nDefaultKeepOnScreen=0\n"
            + "DefaultSavePosition=\(defaultSavePosition ? 1 : 0)\n" : ""
        try """
        [Rainmeter]
        Update=-1
        Group=\(group)
        OnRefreshAction=\(onRefresh)
        \(initial)
        [Card]
        Meter=Image
        W=200
        H=100
        SolidColor=40,70,90,255
        """.write(to: folder.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        app.rescanLibrary()
    }

    private static func load(_ t: AppTestRunner, _ app: AppController, _ name: String) -> SkinWindowController? {
        guard let c = app.activate(config: config(name), file: "Skin.ini") else {
            t.check(false, "SetAnchor fixture loads")
            return nil
        }
        guard AppSelfTest.spin(timeout: 30, until: { c.isStarted }) else {
            t.check(false, "SetAnchor fixture starts")
            return nil
        }
        drain(t, app)
        return c
    }

    private static func send(_ c: SkinWindowController, _ action: String) {
        c.runtime.send(.execute(action, section: nil))
    }

    private static func drain(_ t: AppTestRunner, _ app: AppController, expectingHeld held: SkinWindowController? = nil) {
        for _ in 0..<2 {
            for c in app.sortedControllers { t.equal(c.runtime.exclusive(timeout: 30) { _ in true }, true) }
            t.check(ServiceThreadingSelfTests.drainMainQueue(), "window requests drained")
        }
        for c in app.sortedControllers where c !== held {
            t.check(AppSelfTest.spin(timeout: 30) {
                let frame = c.window.frame
                return c.runtime.exclusive(timeout: 0.25) { _ in c.runtime.model.frame == frame } == true
            }, "SetAnchor window and model agree")
        }
    }

    private static func resolve(_ state: SkinState, size: CGSize) -> (x: Double, y: Double) {
        WindowPosition.resolve(x: state.windowX ?? "0", y: state.windowY ?? "0",
            anchorX: state.anchorX ?? "0", anchorY: state.anchorY ?? "0", skinSize: size,
            screens: EnvironmentStore.shared.currentScreens) ?? (Double.nan, Double.nan)
    }

    private static func initialOrigin(_ app: AppController, cascade: Bool) -> (x: Double, y: Double) {
        guard cascade else { return (400, 300) }
        let screens = EnvironmentStore.shared.currentScreens
        let visible = NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = WindowGeometry.cascadeFrame(index: app.controllers.count + 1,
            size: CGSize(width: 200, height: 100), visible: visible)
        let origin = WindowGeometry.topLeft(of: frame, primaryHeight: WindowGeometry.primaryHeight(screens))
        return (origin.x + 100, origin.y + 50)
    }

    private static func checkPosition(_ t: AppTestRunner, _ c: SkinWindowController, expected: (x: Double, y: Double),
                                      accuracy: Double = 0.01) {
        t.close(c.topLeftPosition.x, expected.x, accuracy: accuracy)
        t.close(c.topLeftPosition.y, expected.y, accuracy: accuracy)
    }

    private static func drag(_ t: AppTestRunner, _ c: SkinWindowController, by delta: NSPoint,
                             whileHeld: () -> Void = {}) {
        let oldPointer = SkinView.pointerLocation
        var pointer = NSPoint(x: 700, y: 500)
        SkinView.pointerLocation = { pointer }
        defer { SkinView.pointerLocation = oldPointer }
        guard let down = AppSelfTest.mouseEvent(.leftMouseDown, c, x: 50, y: 50),
              let moved = AppSelfTest.mouseEvent(.leftMouseDragged, c, x: 50, y: 50),
              let up = AppSelfTest.mouseEvent(.leftMouseUp, c, x: 50, y: 50) else {
            return t.check(false, "SetAnchor synthetic mouse events exist")
        }
        c.view.mouseDown(with: down)
        t.check(c.isDragPressActive)
        whileHeld()
        pointer.x += delta.x; pointer.y += delta.y
        c.view.mouseDragged(with: moved)
        c.view.mouseUp(with: up)
        t.check(!c.isDragPressActive)
    }
}
