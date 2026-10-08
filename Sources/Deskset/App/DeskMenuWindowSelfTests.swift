import AppKit
import DesksetCore

enum DeskMenuWindowSelfTests {
    private typealias S = DeskConditionalTestSupport
    private static let settings = "x-apple.systempreferences:com.apple.Battery-Settings.extension"

    private final class Recorder {
        var calls: [String] = []
        var mainThreads: [Bool] = []
        func record(_ value: String) -> Bool {
            calls.append(value); mainThreads.append(Thread.isMainThread); return true
        }
    }

    private struct Fixture {
        let app: AppController
        let widget: DeskWidgetWindowController
        let host: DeskProgramHost
        let time: VirtualTimeExecutor
        let recorder: Recorder
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk menu windows: native right click resolves local root and builtins and selects once across ordinary generations") {
            let source = """
            widget {
                variable count = 0
                Column(spacing: 0, align: .left) {
                    Row {}.size(80, 40).name(card).menu { Item("Card").onClick { copy("card") } }
                    Text("Value {count}").size(80, 20).name(leaf).menu {
                        Item("Local {count}", checked: count == 0).onClick {
                            count = count + 1; copy(count); open("\(settings)")
                        }
                        Menu("More") {
                            Item("Disabled", enabled: false).onClick { copy("disabled") }
                            Item("Empty").onClick {}
                        }
                    }
                }.menu { Item("Root").onClick { copy("root") } }
            }
            """
            let f = try fixture(t, source), generation = f.host.scene?.generation
            let menu = try open(t, f, at: NSPoint(x: 40, y: 50))
            t.equal(menu.items.map(\.title), ["Local 0", "More", "", "Root", "", StudioText[.removeWidgetFromDesktop]])
            guard menu.items.count == 6 else { throw S.Failure.fixture }
            t.check(!menu.autoenablesItems && menu.items[2].isSeparatorItem && menu.items[4].isSeparatorItem)
            guard let local = menu.items.first, let nested = menu.items[1].submenu, nested.items.count == 2 else {
                throw S.Failure.fixture
            }
            t.equal(local.state, .on); t.check(local.isEnabled)
            t.equal(nested.items.map(\.title), ["Disabled", "Empty"]); t.check(!nested.items[0].isEnabled)
            try choose(t, nested.items[0]); settle(t, f)
            t.equal(f.recorder.calls, []); t.equal(f.host.scene?.generation, generation)
            t.check(f.widget.view.programMenus?.menu === menu, "a disabled command does not consume the opening")

            f.host.refresh(); settle(t, f)
            t.equal(f.host.scene?.generation, generation.map { $0 + 1 })
            t.check(f.widget.view.programMenus?.menu === menu, "an ordinary accepted refresh retains the source/menu lease")
            t.equal(local.title, "Local 0", "the opening's label is immutable")
            try choose(t, local); try choose(t, local); settle(t, f)
            t.equal(f.recorder.calls, ["copy:1", "open:" + settings])
            t.equal(S.texts(f.host.scene), ["Value 1"])
            t.check(f.recorder.mainThreads.allSatisfy { $0 })
            t.check(f.widget.view.programMenus?.menu == nil)

            let card = try open(t, f, at: NSPoint(x: 40, y: 20))
            t.equal(card.items.map(\.title), ["Card", "", "Root", "", StudioText[.removeWidgetFromDesktop]])
            guard card.items.count == 5 else { throw S.Failure.fixture }
            try choose(t, card.items[2]); settle(t, f)
            t.equal(f.recorder.calls.last, "copy:root")
            let fresh = try open(t, f, at: NSPoint(x: 40, y: 50))
            t.equal(fresh.items.first?.title, "Local 1"); t.equal(fresh.items.first?.state, .off)
            guard fresh.items.count == 6, let empty = fresh.items[1].submenu?.items.last else { throw S.Failure.fixture }
            let calls = f.recorder.calls, beforeEmpty = f.host.scene?.generation
            try choose(t, empty); settle(t, f)
            t.equal(f.recorder.calls, calls); t.equal(f.host.scene?.generation, beforeEmpty.map { $0 + 1 })
            t.check(f.widget.view.programMenus?.menu == nil)
            t.equal(f.time.background.reports, [])
        }

        t.suite("App: Desk menu windows: negative origin preset rounded boxes and explicit empty local menus use accepted geometry") {
            for preset in [false, true] {
                let source = """
                \(preset ? "info { size: .small }" : "")
                widget { Freeform {
                    Column {}.size(340, 170).position(x: -40, y: -20).background(.glass).rounded(20)
                        .name(card).menu { Item("Card").onClick { copy("card") } }
                }.menu { Item("Root").onClick { copy("root") } } }
                """
                let f = try fixture(t, source)
                let expected = preset ? SkinRect(width: 170, height: 85) : SkinRect(x: -40, y: -20, width: 340, height: 170)
                t.equal(try S.element(f.widget.latestPresented?.scene, "card").frame, expected)
                t.equal(f.widget.latestPresented?.origin, preset ? SkinPoint() : SkinPoint(x: -40, y: -20))
                let menu = try open(t, f, at: NSPoint(x: expected.width / 2, y: expected.height / 2))
                t.equal(menu.items.map(\.title), ["Card", "", "Root", "", StudioText[.removeWidgetFromDesktop]])
                guard let item = menu.items.first else { throw S.Failure.fixture }
                try choose(t, item); settle(t, f); t.equal(f.recorder.calls, ["copy:card"])
                let corner = try open(t, f, at: NSPoint(x: 0.1, y: 0.1))
                t.equal(corner.items.map(\.title), ["Root", "", StudioText[.removeWidgetFromDesktop]],
                        "rounded transparent corners do not hit the local card; the widget menu remains available")
                t.equal(f.widget.nativeComposition.shownPieces.count, 1)
            }
            let empty = try fixture(t, #"widget { Column { Column { Text("A").size(80, 30).menu {} }.size(80, 60).menu { Item("Ancestor") } }.menu { Item("Root") } }"#)
            let menu = try open(t, empty, at: NSPoint(x: 40, y: 15))
            t.equal(menu.items.map(\.title), ["Root", "", StudioText[.removeWidgetFromDesktop]],
                    "an explicit empty local declaration prevents searching an intermediate ancestor menu")
        }

        t.suite("App: Desk menu windows: Option builtin menus and secondary handlers retain native pointer priority") {
            let source = #"widget { Freeform { Rectangle().size(40, 20).name(child).onRightClick {} }.size(80, 60).name(card).onRightClick { copy("right") }.menu { Item("Custom").onClick { copy("custom") } } }"#
            let f = try fixture(t, source)
            var builtins = 0
            f.widget.view.contextMenuPresenterForTesting = { menu, _ in
                builtins += 1
                t.equal(menu.items.map(\.title), [StudioText[.removeWidgetFromDesktop]])
            }
            try click(NSPoint(x: 5, y: 30), f); settle(t, f)
            t.equal(f.recorder.calls, ["copy:right"]); t.check(f.widget.view.programMenus?.menu == nil)
            try click(NSPoint(x: 40, y: 30), f); settle(t, f)
            t.equal(f.recorder.calls, ["copy:right"], "a child's empty handler consumes its right click")
            try mouse(.rightMouseDown, NSPoint(x: 5, y: 30), f, flags: [.option])
            try mouse(.rightMouseUp, NSPoint(x: 5, y: 30), f)
            try mouse(.rightMouseDown, NSPoint(x: 5, y: 30), f)
            try mouse(.rightMouseUp, NSPoint(x: 5, y: 30), f, flags: [.option])
            try mouse(.leftMouseDown, NSPoint(x: 40, y: 30), f, flags: [.control, .option])
            try mouse(.leftMouseUp, NSPoint(x: 40, y: 30), f)
            settle(t, f)
            t.equal(builtins, 3); t.equal(f.recorder.calls, ["copy:right"])
            t.check(f.widget.view.programMenus?.menu == nil)
            try mouse(.rightMouseDown, NSPoint(x: 5, y: 30), f)
            try mouse(.rightMouseDragged, NSPoint(x: 10, y: 30), f)
            try mouse(.rightMouseUp, NSPoint(x: 10, y: 30), f); settle(t, f)
            t.equal(f.recorder.calls, ["copy:right"], "dragging retires the secondary press")
        }

        t.suite("App: Desk menu windows: pending replies held items replacement epoch and close cannot execute stale actions") {
            let source = #"widget { Row(spacing: 0) { Text("Old").size(80, 40).menu { Item("Old").onClick { copy("old") } }; Rectangle().size(80, 40).onRightClick {} } }"#
            let f = try fixture(t, source), point = NSPoint(x: 40, y: 20)
            try mouse(.rightMouseDown, point, f)
            t.check(f.widget.view.programMenus?.currentRequest != nil)
            f.widget.view.programMenus?.cancel()
            drain(t, f)
            t.check(f.widget.view.programMenus?.menu == nil && f.widget.view.programMenus?.currentRequest == nil,
                    "an asynchronous snapshot cannot revive a cancelled request")
            for gesture in ["primary", "secondary", "drag"] {
                try mouse(.rightMouseDown, point, f)
                t.check(f.widget.view.programMenus?.currentRequest != nil)
                if gesture == "primary" {
                    try mouse(.leftMouseDown, point, f); try mouse(.leftMouseUp, point, f)
                } else if gesture == "secondary" {
                    try mouse(.rightMouseDown, NSPoint(x: 120, y: 20), f)
                    try mouse(.rightMouseUp, NSPoint(x: 120, y: 20), f)
                } else {
                    try mouse(.rightMouseDragged, point, f); try mouse(.rightMouseUp, point, f)
                }
                drain(t, f)
                t.check(f.widget.view.programMenus?.currentRequest == nil && f.widget.view.programMenus?.menu == nil,
                        "a new \(gesture) gesture prevents a delayed menu from opening")
                t.equal(f.recorder.calls, [])
            }
            let oldMenu = try open(t, f, at: point)
            let freshMenu = try open(t, f, at: point)
            guard let oldItem = oldMenu.items.first, let epochItem = freshMenu.items.first else { throw S.Failure.fixture }
            try choose(t, oldItem); settle(t, f)
            t.equal(f.recorder.calls, []); t.check(f.widget.view.programMenus?.menu === freshMenu)

            let beforeEpoch = f.widget.destinationEpoch
            let dark = f.widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            f.widget.window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            _ = f.widget.currentFacts()
            t.check(f.widget.destinationEpoch != beforeEpoch)
            try choose(t, epochItem); f.time.runUntilIdle()
            try takeFacts(f); settle(t, f)
            t.equal(f.recorder.calls, []); t.check(f.widget.view.programMenus?.menu == nil)

            guard let beforeReplacement = try open(t, f, at: point).items.first else { throw S.Failure.fixture }
            f.widget.close(deactivate: false)
            let replacement = try replace(t, f, source: #"widget { Text("New").size(80, 40).menu { Item("New").onClick { copy("new") } } }"#)
            try choose(t, beforeReplacement); drain(t, replacement)
            t.check(f.widget.isClosed); t.equal(f.recorder.calls, [])
            t.check(f.app.deskWidgetWindows[f.widget.instance.id] === replacement.widget,
                    "the old close acknowledgement must not remove the replacement")
            guard let newItem = try open(t, replacement, at: point).items.first else { throw S.Failure.fixture }
            try choose(t, newItem); settle(t, replacement)
            t.equal(f.recorder.calls, ["copy:new"])
            guard let closingItem = try open(t, replacement, at: point).items.first else { throw S.Failure.fixture }
            try choose(t, closingItem)
            replacement.widget.close(deactivate: false)
            try choose(t, closingItem); drain(t, replacement)
            t.check(AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return replacement.widget.isClosed })
            t.equal(f.recorder.calls, ["copy:new"], "closing before the owner/Main action queues drain suppresses queued services")
            t.check(f.recorder.mainThreads.allSatisfy { $0 }); t.equal(f.time.background.reports, [])
        }
    }

    private static func fixture(_ t: AppTestRunner, _ sourceText: String) throws -> Fixture {
        let root = t.temporaryDirectory("desk-menu-window"), time = try S.clock(), recorder = Recorder()
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
            skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
            backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
            settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
            presentsWindows: false)
        let sourceID = UUID(), instanceID = UUID()
        let source = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
        let instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
        let directory = root.appendingPathComponent("Widgets").appendingPathComponent(sourceID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(sourceText.utf8).write(to: directory.appendingPathComponent("Main.desk"))
        try app.state.registerDeskInstallation(source: source, instance: instance)
        let widget = try controller(sourceText, app: app, source: source, instance: instance, directory: directory,
                                    time: time, recorder: recorder)
        t.atSuiteEnd {
            widget.close(deactivate: false)
            _ = AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isClosed }
            _ = app.stopAllForTermination(); app.endEngineThread()
        }
        return try finishFixture(t, app: app, widget: widget, time: time, recorder: recorder)
    }

    private static func replace(_ t: AppTestRunner, _ f: Fixture, source: String) throws -> Fixture {
        try Data(source.utf8).write(to: f.widget.directory.appendingPathComponent("Main.desk"))
        let widget = try controller(source, app: f.app, source: f.widget.source, instance: f.widget.instance,
            directory: f.widget.directory, time: f.time, recorder: f.recorder)
        t.atSuiteEnd {
            widget.close(deactivate: false)
            _ = AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return widget.isClosed }
        }
        return try finishFixture(t, app: f.app, widget: widget, time: f.time, recorder: f.recorder)
    }

    private static func controller(_ sourceText: String, app: AppController, source: DeskWidgetSourceState,
                                   instance: DeskWidgetInstanceState, directory: URL, time: VirtualTimeExecutor,
                                   recorder: Recorder) throws -> DeskWidgetWindowController {
        let services = DeskProgramActionServices(resolver: DeskProgramOpenResolver(application: { _ in nil },
            applicationNamed: { _ in nil }, exists: { _ in false }),
            copy: { recorder.record("copy:" + $0) }, open: { recorder.record("open:" + $0.absoluteString) })
        return DeskWidgetWindowController(source: source, instance: instance, directory: directory,
            program: try S.program(sourceText), prepared: nil, app: app, executor: time, clock: time.clock, actionServices: services)
    }

    private static func finishFixture(_ t: AppTestRunner, app: AppController, widget: DeskWidgetWindowController,
                                      time: VirtualTimeExecutor, recorder: Recorder) throws -> Fixture {
        t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isStarted && widget.latestPresented != nil })
        guard let host = widget.owner.host else { throw S.Failure.fixture }
        let result = Fixture(app: app, widget: widget, host: host, time: time, recorder: recorder)
        try takeFacts(result); settle(t, result)
        t.check(!widget.window.isVisible, "the native menu fixture never enters the user's desktop or a tracking loop")
        return result
    }

    private static func takeFacts(_ f: Fixture) throws {
        let input = try DeskWidgetWindowController.makeInput(for: f.widget.window.effectiveAppearance,
            scale: f.widget.window.backingScaleFactor)
        guard let space = f.widget.window.colorSpace?.cgColorSpace else { throw S.Failure.fixture }
        let facts = SkinWindowFacts(frame: f.widget.window.frame, isVisible: true, isOrderedIn: true,
            scale: f.widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
            takesPointer: true, sequence: 100, panelGeneration: f.widget.destinationEpoch)
        f.widget.owner.take(facts, input: input)
    }

    private static func settle(_ t: AppTestRunner, _ f: Fixture, line: UInt = #line) {
        f.time.runUntilIdle(); f.host.frames.runLoopTurn(.beforeWaiting)
        var drained = false
        f.time.async { DispatchQueue.main.async { drained = true } }
        t.check(AppSelfTest.spin(timeout: 10) {
            f.time.runUntilIdle(); f.host.frames.runLoopTurn(.beforeWaiting)
            return drained && !f.host.frames.hasBitmapDelivery &&
                f.host.presented?.scene.generation == f.widget.latestPresented?.scene.generation &&
                f.host.scene?.generation == f.host.presented?.scene.generation
        }, "pending=\(f.host.frames.hasBitmapDelivery), ownerEpoch=\(f.widget.owner.currentEpoch), MainEpoch=\(f.widget.destinationEpoch), " +
            "generations=\(String(describing: f.host.scene?.generation))/\(String(describing: f.host.presented?.scene.generation))/" +
            "\(String(describing: f.widget.latestPresented?.scene.generation))", line: line)
    }

    private static func drain(_ t: AppTestRunner, _ f: Fixture) {
        var drained = false
        f.time.async { DispatchQueue.main.async { drained = true } }
        t.check(AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return drained })
    }

    private static func open(_ t: AppTestRunner, _ f: Fixture, at point: NSPoint) throws -> NSMenu {
        try mouse(.rightMouseDown, point, f)
        t.check(f.widget.view.programMenus?.currentRequest != nil)
        t.check(f.widget.view.programMenus?.menu == nil, "native input queues an owner snapshot instead of resolving synchronously on Main")
        t.check(AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return f.widget.view.programMenus?.menu != nil })
        try mouse(.rightMouseUp, point, f)
        guard let menus = f.widget.view.programMenus, let menu = menus.menu else { throw S.Failure.fixture }
        t.check(!menus.isTracking)
        return menu
    }

    private static func choose(_ t: AppTestRunner, _ item: NSMenuItem) throws {
        guard let action = item.action, let target = item.target else { throw S.Failure.fixture }
        t.check(NSApplication.shared.sendAction(action, to: target, from: item))
    }

    private static func click(_ point: NSPoint, _ f: Fixture) throws {
        try mouse(.rightMouseDown, point, f); try mouse(.rightMouseUp, point, f)
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ f: Fixture,
                              flags: NSEvent.ModifierFlags = []) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: f.widget.view.convert(point, to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: f.widget.window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) else {
            throw S.Failure.fixture
        }
        switch type {
        case .leftMouseDown: f.widget.view.mouseDown(with: event)
        case .leftMouseUp: f.widget.view.mouseUp(with: event)
        case .rightMouseDown: f.widget.view.rightMouseDown(with: event)
        case .rightMouseUp: f.widget.view.rightMouseUp(with: event)
        case .rightMouseDragged: f.widget.view.rightMouseDragged(with: event)
        default: throw S.Failure.fixture
        }
    }
}
