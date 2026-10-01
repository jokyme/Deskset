import AppKit
import DesksetCore

/// A skin's window model, the environment store and the skin directory (docs/skin-threading.md §8.1, §8.2, phase 2
/// step 3). A skin's own window bangs change its window model at once and the main thread follows; its bangs for other
/// skins go straight to their runtimes. Every skin of the app still runs on the main executor, where all of it happens
/// inline (the existing suites check that nothing changed, and the debug comparison checks the model against the live
/// window wherever they read the environment); skins on test threads (`SkinThreadExecutor`, through
/// `AppController.skinExecutor`) show what happens once they run elsewhere.
enum SkinWindowModelSelfTests {
    static func run(_ t: AppTestRunner) {
        fractionalSizeTests(t)

        t.suite("App: window model: a skin on a thread reads its clamped place right after !Move, before its window moved") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            EnvironmentStore.shared.publish()
            let executor = SkinThreadExecutor(name: "Window model mover")
            try write(app, ["Mover": moverSkin])
            app.skinExecutor = { $0 == "Model\\Mover" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var skin: Skin?
            autoreleasepool {
                guard let c = app.activate(config: "Model\\Mover", file: nil) else {
                    return t.check(false, "the skin loads on its thread")
                }
                let r = c.runtime
                skin = r.skin
                t.check(r.executor === executor, "on the test thread")
                t.check(settled(c), "the window takes the skin's size, and the model follows")
                let screens = EnvironmentStore.shared.currentScreens
                let ph = WindowGeometry.primaryHeight(screens)
                let size = c.window.frame.size
                let before = c.window.frame

                // Far off every screen: KeepOnScreen brings it back, in the model at once.
                let expected = WindowGeometry.keptOnScreen(
                    WindowGeometry.frame(topLeftX: -5000, y: -5000, size: size, primaryHeight: ph), screens: screens)
                let p = WindowGeometry.topLeft(of: expected, primaryHeight: ph)
                r.send(.execute("[!Move -5000 -5000][!SetVariable Seen \"#CURRENTCONFIGX#,#CURRENTCONFIGY#\"]",
                                section: nil))
                // The main thread does not turn its run loop meanwhile: the window cannot have moved yet.
                let seen = r.exclusive(timeout: 30) { skin in (skin.variable("Seen"), r.model.frame) }
                t.equal(seen?.0, "\(Int(p.x)),\(Int(p.y))", "the skin read where its bang put the window")
                t.equal(seen?.1, expected, "its model has the clamped frame")
                t.equal(c.window.frame, before, "the window has not moved yet")
                t.check(AppSelfTest.spin(timeout: 30) { agrees(c) && c.window.frame == expected },
                        "then the window moves there and tells the model")
                t.equal(c.window.frame, expected)
                t.close(app.state.skin("Model\\Mover")?.x ?? -1, p.x, "SavePosition stores the move")
                t.close(app.state.skin("Model\\Mover")?.y ?? -1, p.y)

                // Z position, a flag and the screen: the skin reads its own changes at once, the main thread follows.
                r.send(.execute("[!ZPos 1][!KeepOnScreen 0][!AutoSelectScreen 1][!SetWindowPosition 50% 50% 50% 50%]"
                                + "[!SetVariable Seen \"#CURRENTCONFIGZPOS#,#CURRENTCONFIGX#,#WORKAREAX#\"]", section: nil))
                let centre = WindowPosition.resolve(x: "50%", y: "50%", anchorX: "50%", anchorY: "50%", skinSize: size,
                                                    screens: screens) ?? (0, 0)
                let primary = screens.first.map { WindowGeometry.topLeft(of: $0.visibleFrame, primaryHeight: ph).x } ?? 0
                let seenAgain = r.exclusive(timeout: 30) { $0.variable("Seen") }
                t.equal(seenAgain, "1,\(Int(centre.x)),\(Int(primary))", "Z position, place and screen at once")
                t.check(AppSelfTest.spin(timeout: 30) { agrees(c) && app.state.skin("Model\\Mover")?.alwaysOnTop == 1 },
                        "the main thread follows")
                t.equal(c.window.level, .floating)
                t.equal(app.state.skin("Model\\Mover")?.keepOnScreen, false)
                t.equal(app.state.skin("Model\\Mover")?.autoSelectScreen, true)
                t.close(c.topLeftPosition.x, centre.x, accuracy: 0.5)

                // A change that starts on the main thread (the Manage window moving it) reaches the model.
                c.moveTo(x: 120, y: 140)
                t.check(AppSelfTest.spin(timeout: 30) { agrees(c) }, "the model follows the main thread's move")
                r.send(.execute("[!SetVariable Seen \"#CURRENTCONFIGX#,#CURRENTCONFIGY#\"]", section: nil))
                t.equal(r.exclusive(timeout: 30) { $0.variable("Seen") }, "120,140")
                app.deactivate(config: "Model\\Mover")
            }
            finish(t, skin: { skin }, executor)
        }

        t.suite("App: window model: a drag in progress wins over a skin's !Move") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Mover": moverSkin])
            guard let c = app.activate(config: "Model\\Mover", file: nil) else { return t.check(false, "loads") }
            defer { app.deactivate(config: "Model\\Mover") }
            let screens = EnvironmentStore.shared.currentScreens
            guard let primary = screens.first?.visibleFrame else { return }
            let ph = WindowGeometry.primaryHeight(screens)
            let savedPointer = SkinView.pointerLocation
            defer { SkinView.pointerLocation = savedPointer }
            var pointer = NSPoint(x: 500, y: 500)
            SkinView.pointerLocation = { pointer }
            func event(_ type: NSEvent.EventType) -> NSEvent? { AppSelfTest.mouseEvent(type, c, x: 50, y: 50) }
            func seen() -> String? {
                c.runtime.send(.execute("[!SetVariable Seen \"#CURRENTCONFIGX#,#CURRENTCONFIGY#\"]", section: nil))
                return c.skin.variable("Seen")
            }
            // Where the skin moves itself, well inside the primary screen.
            let target = WindowGeometry.topLeft(of: CGRect(x: primary.minX + 200, y: primary.maxY - 300, width: 10,
                                                           height: 10), primaryHeight: ph)
            let moveBang = "[!Move \(Int(target.x)) \(Int(target.y))]"

            c.moveTo(x: Double(primary.minX) + 400, y: 200)
            let start = c.window.frame.origin
            guard let down = event(.leftMouseDown), let drag = event(.leftMouseDragged), let up = event(.leftMouseUp)
            else { return t.check(false, "events") }
            c.view.mouseDown(with: down)
            t.check(c.isDragPressActive, "a press that may drag the window")
            pointer.x += 40
            pointer.y -= 30
            c.view.mouseDragged(with: drag)
            t.equal(c.window.frame.origin, NSPoint(x: start.x + 40, y: start.y - 30), "dragged")
            c.runtime.send(.execute(moveBang, section: nil))
            t.equal(seen(), "\(Int(target.x)),\(Int(target.y))", "the skin believes its move meanwhile")
            t.check(c.heldMove != nil, "the move waits for the release")
            t.equal(c.window.frame.origin, NSPoint(x: start.x + 40, y: start.y - 30), "the window stays with the pointer")
            pointer.x += 10
            pointer.y -= 10
            c.view.mouseDragged(with: drag)
            c.view.mouseUp(with: up)
            let dragged = NSRect(origin: NSPoint(x: start.x + 50, y: start.y - 40), size: c.window.frame.size)
            t.equal(c.window.frame, dragged, "the drag wins")
            t.check(!c.isDragPressActive && c.heldMove == nil)
            let p = WindowGeometry.topLeft(of: dragged, primaryHeight: ph)
            t.close(app.state.skin("Model\\Mover")?.x ?? -1, p.x, "the drag's place is saved")
            t.close(app.state.skin("Model\\Mover")?.y ?? -1, p.y)
            t.equal(c.runtime.model.frame, dragged, "the model takes the window's place")
            t.equal(seen(), "\(Int(p.x)),\(Int(p.y))", "and the skin reads it")

            // A press that does not drag: the skin's move is made at the release.
            c.view.mouseDown(with: down)
            c.runtime.send(.execute(moveBang, section: nil))
            t.equal(c.window.frame, dragged, "waits")
            c.view.mouseUp(with: up)
            t.close(c.topLeftPosition.x, target.x, accuracy: 0.5, "made at the release")
            t.close(c.topLeftPosition.y, target.y, accuracy: 0.5)
            t.equal(c.runtime.model.frame, c.window.frame)
            t.equal(seen(), "\(Int(target.x)),\(Int(target.y))")
        }

        t.suite("App: window model: the debug comparison reports a model that does not follow its window") {
            #if DEBUG
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Mover": moverSkin])
            guard let c = app.activate(config: "Model\\Mover", file: nil) else { return t.check(false, "loads") }
            defer { app.deactivate(config: "Model\\Mover") }
            var reported: [String] = []
            SnapshotAudit.capturing({ reported.append($0) }) {
                // A move nobody hears of.
                c.window.delegate = nil
                c.window.setFrameOrigin(NSPoint(x: c.window.frame.minX + 33, y: c.window.frame.minY))
                c.window.delegate = c
                c.runtime.send(.execute("[!SetVariable Seen #CURRENTCONFIGX#]", section: nil))
            }
            t.check(reported.contains { $0.contains("environment") && $0.contains("the window model says") },
                    "\(reported)")
            c.publishFacts()
            reported = []
            SnapshotAudit.capturing({ reported.append($0) }) {
                c.runtime.send(.execute("[!SetVariable Seen #CURRENTCONFIGX#]", section: nil))
            }
            t.equal(reported, [], "told, the model follows")
            #endif
        }

        t.suite("App: skin directory: a group bang reaches every member in load order") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["GroupA": groupSkin, "GroupB": groupSkin, "GroupC": groupSkin, "Outside": moverSkin])
            let names = ["Model\\GroupA", "Model\\GroupB", "Model\\GroupC"]
            let loaded = names.compactMap { app.activate(config: $0, file: nil) }
            guard loaded.count == 3, let outside = app.activate(config: "Model\\Outside", file: nil) else {
                return t.check(false, "the skins load")
            }
            defer { for name in names + ["Model\\Outside"] { app.deactivate(config: name) } }
            // Load order: C, A, B.
            for (c, order) in zip(loaded, [2, 3, 1]) { app.changeSettings(of: c) { $0.loadOrder = order } }
            t.equal(app.skinDirectory.directory.runtimes(inGroup: "modelgroup").map(\.config),
                    ["Model\\GroupC", "Model\\GroupA", "Model\\GroupB"])
            var arrivals: [String] = []
            for c in loaded {
                c.runtime.messageObserver = { message in
                    if case .update = message { arrivals.append(c.config) }
                    if case .redraw = message { arrivals.append(c.config + " redraw") }
                }
            }
            // Sent by a member (it gets it too, at once) and by a skin outside the group.
            loaded[1].runtime.send(.execute("[!UpdateGroup ModelGroup]", section: nil))
            t.equal(arrivals, ["Model\\GroupC", "Model\\GroupA", "Model\\GroupB"])
            arrivals = []
            outside.runtime.send(.execute("[!RedrawGroup ModelGroup]", section: nil))
            t.equal(arrivals, ["Model\\GroupC redraw", "Model\\GroupA redraw", "Model\\GroupB redraw"])
            outside.runtime.send(.execute("[!SetVariableGroup Marker grouped ModelGroup][!HideGroup ModelGroup]"
                                          + "[!ZPosGroup 1 ModelGroup]", section: nil))
            t.equal(loaded.map { $0.skin.variable("Marker") ?? "" }, ["grouped", "grouped", "grouped"])
            t.check(loaded.allSatisfy { $0.isHiddenByBang }, "every member hidden")
            t.equal(loaded.map { app.state.skin($0.config)?.alwaysOnTop ?? 0 }, [1, 1, 1])
            t.equal(loaded.map { $0.runtime.model.settings.zPosition }, [1, 1, 1], "their models follow")
            t.check(!outside.isHiddenByBang, "the sender is not in the group")
            outside.runtime.send(.execute("[!ShowGroup ModelGroup]", section: nil))
            t.check(loaded.allSatisfy { !$0.isHiddenByBang })

            // The members on a thread of their own: they get the bangs in load order there.
            for c in loaded { c.runtime.messageObserver = nil }
            let executor = SkinThreadExecutor(name: "Skin directory group")
            app.skinExecutor = { names.contains($0) ? executor as SkinExecutor : MainSkinExecutor.shared }
            for name in names { app.deactivate(config: name) }
            weak var anySkin: Skin?
            autoreleasepool {
                let threaded = names.compactMap { app.activate(config: $0, file: nil) }
                t.equal(threaded.count, 3)
                anySkin = threaded.first?.runtime.skin
                let order = Guarded<[String]>([])
                for c in threaded {
                    let config = c.config
                    _ = c.runtime.exclusive(timeout: 30) { _ in
                        c.runtime.messageObserver = { message in
                            if case .update = message { order.access { $0.append(config) } }
                        }
                    }
                }
                outside.runtime.send(.execute("[!UpdateGroup ModelGroup][!HideGroup ModelGroup]", section: nil))
                t.check(AppSelfTest.spin(timeout: 30) {
                    order.current.count == 3 && threaded.allSatisfy(\.isHiddenByBang)
                }, "every member, on its thread, and hidden by the main thread after")
                t.equal(order.current, ["Model\\GroupC", "Model\\GroupA", "Model\\GroupB"], "in load order")
                for name in names { app.deactivate(config: name) }
            }
            finish(t, skin: { anySkin }, executor)
        }

        t.suite("App: skin directory: bangs to a skin on a thread arrive in order, and the 17th hop is dropped once") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["PingA": pingSkin("Model\\PingB"), "PingB": pingSkin("Model\\PingA")])
            let executor = SkinThreadExecutor(name: "Skin directory hops")
            app.skinExecutor = { $0 == "Model\\PingB" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var skinB: Skin?
            autoreleasepool {
                guard let a = app.activate(config: "Model\\PingA", file: nil),
                      let b = app.activate(config: "Model\\PingB", file: nil) else { return t.check(false, "load") }
                skinB = b.runtime.skin
                let values = Guarded<[String]>([])
                let onThread = Guarded<[Bool]>([])
                _ = b.runtime.exclusive(timeout: 30) { _ in
                    b.runtime.messageObserver = { message in
                        guard case .bang(let bang, let from, _) = message, bang.name == "setvariable",
                              from == "Model\\PingA" else { return }
                        values.access { $0.append(bang.args.count > 1 ? bang.args[1] : "") }
                        onThread.access { $0.append(executor.isCurrent) }
                    }
                }
                let action = (1...50).map { "[!SetVariable Log \($0) \"Model\\PingB\"]" }.joined()
                a.runtime.send(.execute(action, section: nil))
                t.check(AppSelfTest.spin(timeout: 30) { values.current.count == 50 }, "all arrive")
                t.equal(values.current, (1...50).map(String.init), "in the order they were sent")
                t.check(onThread.current.allSatisfy { $0 }, "on the skin's thread")
                t.equal(b.runtime.exclusive(timeout: 30) { $0.variable("Log") }, "50")
                _ = b.runtime.exclusive(timeout: 30) { _ in b.runtime.messageObserver = nil }

                // A and B update each other (their IfTrueAction), from main to the thread and back: the chain stops
                // at the 17th hop, which is dropped and logged once.
                func updatesB() -> Int { b.runtime.exclusive(timeout: 30) { $0.updateCount } ?? -1 }
                a.runtime.send(.execute("[!SetVariable Armed 1][!SetVariable Armed 1 \"Model\\PingB\"]", section: nil))
                for round in 1...2 {
                    let aBefore = a.skin.updateCount, bBefore = updatesB()
                    a.runtime.send(.update(hops: 0))
                    t.check(AppSelfTest.spin(timeout: 60) { a.runtime.droppedHops == round }, "round \(round) ends")
                    AppSelfTest.spin(timeout: 0.3) { false }
                    t.equal(a.skin.updateCount - aBefore, 9, "A updated at hops 0, 2 … 16")
                    t.equal(updatesB() - bBefore, 8, "B at hops 1 … 15")
                    t.equal(a.runtime.droppedHops, round, "the 17th hop is dropped")
                    t.equal(a.runtime.hopLimitLogs, 1, "and logged once")
                }
                t.equal(b.runtime.exclusive(timeout: 30) { _ in b.runtime.droppedHops }, 0)
                a.runtime.send(.execute("[!SetVariable Armed 0][!SetVariable Armed 0 \"Model\\PingB\"]", section: nil))
                app.deactivate(config: "Model\\PingA")
                app.deactivate(config: "Model\\PingB")
            }
            finish(t, skin: { skinB }, executor)
        }

        t.suite("App: skin directory: a skin on a thread sends a bang for a config it is loading after the load") {
            guard let app = try AppSelfTest.makeApp(t) else { return }
            try write(app, ["Sender": moverSkin, "Target": moverSkin])
            try moverSkin.replacingOccurrences(of: "Update=-1", with: "Update=-1\nDefaultWindowX=5")
                .write(to: app.skinsDirectory.appendingPathComponent("Model/Target/Other.ini"), atomically: true,
                       encoding: .utf8)
            app.rescanLibrary()
            let executor = SkinThreadExecutor(name: "Skin directory loads")
            app.skinExecutor = { $0 == "Model\\Sender" ? executor as SkinExecutor : MainSkinExecutor.shared }
            weak var sender: Skin?
            autoreleasepool {
                guard let s = app.activate(config: "Model\\Sender", file: nil) else { return t.check(false, "loads") }
                sender = s.runtime.skin
                s.runtime.send(.execute(#"[!ActivateConfig "Model\Target" "Target.ini"]"#
                                        + #"[!SetVariable Marker "after load" "Model\Target"][!Move 40 50 "Model\Target"]"#,
                                        section: nil))
                t.check(AppSelfTest.spin(timeout: 30) {
                    app.controller(for: "Model\\Target")?.skin.variable("Marker") == "after load"
                }, "the bang reaches the skin its load made")
                t.check(AppSelfTest.spin(timeout: 30) {
                    (app.controller(for: "Model\\Target")?.topLeftPosition.x ?? 0).rounded() == 40
                }, "the window bang too")
                guard let first = app.controller(for: "Model\\Target") else { return }

                // Another variant of a running config: the bang reaches the new variant, not the one it replaces.
                s.runtime.send(.execute(#"[!ActivateConfig "Model\Target" "Other.ini"]"#
                                        + #"[!SetVariable Marker "new variant" "Model\Target"]"#, section: nil))
                t.check(AppSelfTest.spin(timeout: 30) {
                    app.controller(for: "Model\\Target")?.skin.variable("Marker") == "new variant"
                }, "the new variant has it")
                t.equal(app.controller(for: "Model\\Target")?.file, "Other.ini")
                t.check(first.isStopped)
                t.equal(first.skin.variable("Marker"), "after load", "the replaced one never had it")
                t.check(!app.isLoadPending("Model\\Target"))
                app.deactivate(config: "Model\\Target")
                app.deactivate(config: "Model\\Sender")
            }
            finish(t, skin: { sender }, executor)
        }
    }

    // MARK: Helpers

    /// A skin with a box to press and nothing that catches the press.
    static let moverSkin = """
        [Rainmeter]
        Update=-1
        Group=ModelMovers

        [Variables]
        Seen=
        Marker=

        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,200,100 | Fill Color 30,30,40,255 | StrokeWidth 0

        """

    /// A member of the skin group ModelGroup.
    static let groupSkin = """
        [Rainmeter]
        Update=-1
        Group=ModelGroup | Other

        [Variables]
        Marker=

        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,60,40 | Fill Color 30,30,40,255 | StrokeWidth 0

        """

    /// A skin that updates `other` after each of its updates while armed (its OnUpdateAction's IfTrueAction).
    static func pingSkin(_ other: String) -> String {
        """
        [Rainmeter]
        Update=-1

        [Variables]
        Armed=0
        Log=

        [MeasureArmed]
        Measure=Calc
        Formula=#Armed#
        DynamicVariables=1
        IfCondition=MeasureArmed = 1
        IfTrueAction=[!Update "\(other)"]
        IfConditionMode=1

        [MeterBack]
        Meter=Shape
        Shape=Rectangle 0,0,60,40 | Fill Color 30,30,40,255 | StrokeWidth 0

        """
    }

    /// Writes the skins (name → text) as `Model\Name\Name.ini` in the app's Skins folder.
    static func fractionalSizeTests(_ t: AppTestRunner) {
        for mode in [SkinThreading.main, .engine, .pool] {
            t.suite("App: window model: fractional sizes keep the window's acknowledged frame (\(mode.rawValue))") {
                guard let app = try AppSelfTest.makeApp(t, threading: mode) else { return }
                try write(app, ["Fractional": """
                    [Rainmeter]
                    Update=-1
                    DynamicWindowSize=1
                    [Box]
                    Meter=Image
                    W=130.3
                    H=70.7
                    SolidColor=60,120,180,255
                    """])
                var tracked: [() -> Skin?] = []
                autoreleasepool {
                    guard let c = app.activate(config: "Model\\Fractional", file: nil) else {
                        return t.check(false, "the fractional skin loads")
                    }
                    tracked = [EngineThreadSelfTests.track(c)]
                    let runtime = c.runtime
                    guard AppSelfTest.spin(timeout: 30, until: { c.isStarted }) else {
                        return t.check(false, "the fractional skin starts")
                    }
                    // Its requests reach main before this marker; exclusive then consumes their returned facts.
                    func settledFrame() -> CGRect? {
                        var arrived = false
                        runtime.whenCaughtUp { arrived = true }
                        t.check(AppSelfTest.spin(timeout: 30) { arrived }, "the window has handled the pending requests")
                        return runtime.exclusive(timeout: 30) { _ in runtime.model }?.frame
                    }
                    func resize(_ width: Double) -> CGSize? {
                        runtime.send(.execute("[!SetOption Box W \(width)][!UpdateMeter Box][!Redraw]", section: nil))
                        return runtime.exclusive(timeout: 30) { _ in runtime.model }?.frame?.size
                    }
                    t.equal(settledFrame(), c.window.frame, "the first size takes AppKit's actual frame")
                    let first = c.window.frame
                    t.equal(runtime.snapshot.size, CGSize(width: 130.3, height: 70.7), "the logical size stays fractional")
                    t.check(first.size != runtime.snapshot.size, "AppKit rounded this window's frame")
                    let firstFacts = runtime.exclusive(timeout: 30) { _ in runtime.model.facts } ?? nil
                    runtime.send(.redraw)
                    runtime.send(.redraw)
                    t.equal(settledFrame(), first, "repeated redraws preserve the acknowledged frame")

                    let sameRounded = resize(130.7)
                    if mode != .main {
                        t.equal(sameRounded, CGSize(width: 130.7, height: 70.7), "a new size is readable before main follows")
                        t.equal(c.window.frame, first, "the window has not handled the new request yet")
                    }
                    t.equal(settledFrame(), c.window.frame, "a request with the same actual frame is acknowledged too")
                    t.equal(c.window.frame, first, "both fractional widths round to the same AppKit frame")
                    t.equal(runtime.snapshot.size, CGSize(width: 130.7, height: 70.7))

                    let firstPending = resize(151.2), lastPending = resize(164.6)
                    if mode != .main {
                        t.equal(firstPending, CGSize(width: 151.2, height: 70.7), "the first queued size is visible at once")
                        t.equal(lastPending, CGSize(width: 164.6, height: 70.7), "the next size replaces it at once")
                        t.equal(c.window.frame, first, "both requests are still waiting on main")
                    }
                    t.equal(settledFrame(), c.window.frame, "the final window acknowledgement wins")
                    t.check(c.window.frame.width > first.width, "the real window follows the changed size")
                    t.equal(runtime.snapshot.size, CGSize(width: 164.6, height: 70.7))
                    if let firstFacts { runtime.send(.windowFacts(firstFacts)) }
                    runtime.send(.redraw)
                    t.equal(settledFrame(), c.window.frame, "old facts and another redraw cannot undo the final frame")
                    app.deactivate(config: "Model\\Fractional")
                }
                EngineThreadSelfTests.finish(t, app, tracked)
            }
        }
    }

    static func write(_ app: AppController, _ skins: [String: String]) throws {
        for (name, text) in skins {
            let folder = app.skinsDirectory.appendingPathComponent("Model/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("\(name).ini"), atomically: true, encoding: .utf8)
        }
        app.rescanLibrary()
    }

    /// The window has the skin's size and the model has the window's frame and settings, with its own changes applied.
    static func agrees(_ c: SkinWindowController) -> Bool {
        let window = c.window.frame
        let state = SkinWindowSettings(c.state, hidden: c.isHiddenByBang, fadedAlpha: nil)
        let model = c.runtime.exclusive(timeout: 30) { _ in c.runtime.model }
        guard let model, let facts = model.facts else { return false }
        return model.frame == window && model.settings == state && facts.modelSequence == model.sequence
    }

    /// The first update has come and the window has the skin's size, which the model knows.
    static func settled(_ c: SkinWindowController) -> Bool {
        AppSelfTest.spin(timeout: 30) {
            c.runtime.snapshot.updateCount >= 1 && c.window.frame.size == c.runtime.snapshot.size && agrees(c)
        }
    }

    /// Waits for a skin on a test thread to be let go of (its runtime went with its window controller), then ends the
    /// thread.
    static func finish(_ t: AppTestRunner, skin: () -> Skin?, _ executor: SkinThreadExecutor) {
        t.check(AppSelfTest.spin(timeout: 30) { skin() == nil }, "the skin on the thread is let go of")
        executor.stop()
    }
}
