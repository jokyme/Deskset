import AppKit
import DesksetCore

enum DeskContainerClickWindowSelfTests {
    private typealias S = DeskConditionalTestSupport
    private static let settings = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    private final class Recorder {
        var calls: [String] = []
        var mainThreads: [Bool] = []
        func record(_ value: String) -> Bool { calls.append(value); mainThreads.append(Thread.isMainThread); return true }
    }
    private struct Fixture {
        let app: AppController
        let widget: DeskWidgetWindowController
        let host: DeskProgramHost
        let time: VirtualTimeExecutor
        let recorder: Recorder
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk container accessibility: parent identity reaches its handler while child and empty handlers keep pointer priority") {
            let source = """
            widget { Row(spacing: 0, align: .top) {
                Freeform {
                    Rectangle().size(40, 20).fill("#FF0000").name(child).voiceOver("Child")
                        .onClick { copy("child") }.onRightClick {}
                }.size(80, 60).background("#0000FF").name(card).voiceOver("Battery settings")
                    .onClick { open("\(settings)") }.onRightClick { copy("parent-right") }
                Column {}.size(40, 60).name(empty).voiceOver("Empty action").onClick {}
                Row {}.size(40, 60).name(secondary).voiceOver("Secondary only").onRightClick { copy("secondary") }
                Freeform {}.size(40, 60).name(group).voiceOver("Group")
            } }
            """
            let f = try fixture(t, source), widget = f.widget
            t.equal(widget.view.accessibilityParts.map { $0.id.name }, ["card", "child", "empty", "secondary", "group"])
            t.equal(try part(f, "card").accessibilityRole(), .button)
            t.equal(try part(f, "empty").accessibilityRole(), .button)
            for name in ["secondary", "group"] {
                let child = try part(f, name)
                t.equal(child.accessibilityRole(), .group); t.check(!child.accessibilityPerformPress())
            }
            let original = try part(f, "card")
            t.equal(widget.latestPresented?.scene.hitMap.entry(at: 40, 30, handling: .leftUp, images: nil)?.elementID?.name, "child")
            t.check(original.accessibilityPerformPress()); t.check(!original.accessibilityPerformPress())
            settle(t, f)
            t.equal(f.recorder.calls, ["open:" + settings])
            t.equal(original.accessibilityFrame(), .zero); t.check(!original.accessibilityPerformPress())
            try click(NSPoint(x: 40, y: 30), f); settle(t, f)
            t.equal(f.recorder.calls.last, "copy:child")
            let count = f.recorder.calls.count
            try click(NSPoint(x: 40, y: 30), f, secondary: true); settle(t, f)
            t.equal(f.recorder.calls.count, count, "the child's empty secondary handler consumes the event")
            try click(NSPoint(x: 5, y: 30), f, secondary: true); settle(t, f)
            t.equal(f.recorder.calls.last, "copy:parent-right")
            let generation = f.host.scene?.generation, calls = f.recorder.calls
            t.check(try part(f, "empty").accessibilityPerformPress()); settle(t, f)
            t.equal(f.host.scene?.generation, generation.map { $0 + 1 })
            t.equal(f.recorder.calls, calls, "an empty identity handler commits without executing an external service")
            t.check(f.recorder.mainThreads.allSatisfy { $0 })
            guard let image = widget.content.shown.image else { throw S.Failure.bitmap }
            t.equal(try S.bytes(image), try S.bytes(S.literal(size: NSSize(width: 200, height: 60),
                scale: Int(widget.window.backingScaleFactor), rectangles: [
                    (CGRect(x: 0, y: 0, width: 80, height: 60), S.blue),
                    (CGRect(x: 20, y: 20, width: 40, height: 20), S.red)])))
        }

        t.suite("App: Desk container accessibility: negative origin preset and native glass share the accepted identity and screen frame") {
            for preset in [false, true] {
                let source = """
                \(preset ? "info { size: .small }" : "")
                widget { Freeform {
                    Column(spacing: 0, align: .left) {
                        Rectangle().size(340, 170).fill("#FF0000").name(child).onClick { copy("child") }
                    }.size(340, 170).position(x: -40, y: -20).background(.glass).rounded(10)
                        .name(card).voiceOver("Battery card").onClick { open("\(settings)") }
                } }
                """
                let f = try fixture(t, source), widget = f.widget, card = try part(f, "card")
                let expected = preset ? NSRect(x: 0, y: 0, width: 170, height: 85) :
                    NSRect(x: 0, y: 0, width: 340, height: 170)
                t.equal(widget.latestPresented?.origin, preset ? SkinPoint() : SkinPoint(x: -40, y: -20))
                let frame = try S.element(widget.latestPresented?.scene, "card").frame
                t.equal(frame, preset ? SkinRect(width: 170, height: 85) : SkinRect(x: -40, y: -20, width: 340, height: 170))
                t.equal(card.accessibilityFrame(), NSAccessibility.screenRect(fromView: widget.view, rect: expected))
                t.equal(widget.nativeComposition.shownPieces.count, 1)
                t.check(card.accessibilityPerformPress()); settle(t, f)
                t.equal(f.recorder.calls, ["open:" + settings], "child-covered center does not retarget explicit container activation")
                try click(NSPoint(x: expected.midX, y: expected.midY), f); settle(t, f)
                t.equal(f.recorder.calls, ["open:" + settings, "copy:child"])
                t.equal(widget.nativeComposition.shownPieces.count, 1)
            }
        }

        t.suite("App: Desk container accessibility: held AX objects session epoch generation pointer facts and close reject stale activation") {
            let f = try fixture(t, cardSource), widget = f.widget
            let old = try part(f, "card")
            f.host.refresh(); settle(t, f)
            t.equal(old.accessibilityFrame(), .zero); t.check(!old.accessibilityPerformPress())
            guard let token = widget.issueClickToken() else { throw S.Failure.fixture }
            let id = try S.element(f.host.scene, "card").id, childID = try S.element(f.host.scene, "child").id
            let generation = f.host.scene?.generation
            var received = 0
            for invalid in [
                DeskWidgetClickToken(session: UUID(), epoch: token.epoch, sourceGeneration: token.sourceGeneration, serial: token.serial),
                DeskWidgetClickToken(session: token.session, epoch: token.epoch + 1, sourceGeneration: token.sourceGeneration, serial: token.serial),
                DeskWidgetClickToken(session: token.session, epoch: token.epoch, sourceGeneration: token.sourceGeneration - 1, serial: token.serial)
            ] {
                widget.owner.activateContainer(id, token: invalid) { _, _ in received += 1 }
            }
            widget.owner.activateContainer(childID, token: token) { _, _ in received += 1 }
            t.equal(received, 0); t.equal(f.host.scene?.generation, generation)
            try takeFacts(f, takesPointer: false)
            t.check(try part(f, "card").accessibilityPerformPress(), "Main queues the accepted object; owner facts remain authoritative")
            settle(t, f); t.equal(f.recorder.calls, [])
            try takeFacts(f); f.host.refresh(); settle(t, f)
            let beforeEpoch = try part(f, "card")
            let dark = widget.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            widget.window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            _ = widget.currentFacts()
            t.check(widget.destinationEpoch != beforeEpoch.epoch)
            t.check(!beforeEpoch.accessibilityPerformPress()); t.equal(beforeEpoch.accessibilityFrame(), .zero)
            // Drain the appearance callback's real offscreen facts before restoring this fixture's visible destination.
            f.time.runUntilIdle()
            try takeFacts(f); settle(t, f)
            widget.owner.activateContainer(id, token: token) { _, _ in received += 1 }
            t.equal(received, 0)
            let beforeClose = try part(f, "card")
            t.check(beforeClose.accessibilityPerformPress())
            widget.close(deactivate: false)
            t.check(!beforeClose.accessibilityPerformPress())
            t.check(AppSelfTest.spin(timeout: 10) { f.time.runUntilIdle(); return widget.isClosed })
            t.equal(beforeClose.accessibilityFrame(), .zero); t.equal(f.recorder.calls, [])
        }

        t.suite("App: Desk container accessibility: native Option menu and Command drag routes consume parent actions without moving the pointer") {
            let f = try fixture(t, cardSource), widget = f.widget
            var menus = 0
            widget.view.contextMenuPresenterForTesting = { menu, _ in
                menus += 1
                t.equal(menu.items.map(\.title), [StudioText[.removeWidgetFromDesktop]])
            }
            let padding = NSPoint(x: 5, y: 30), center = NSPoint(x: 40, y: 30)
            try click(padding, f, secondary: true); settle(t, f)
            t.equal(f.recorder.calls, ["copy:parent-right"])
            try mouse(.rightMouseDown, padding, f, flags: [.option]); try mouse(.rightMouseUp, padding, f)
            try mouse(.rightMouseDown, padding, f); try mouse(.rightMouseUp, padding, f, flags: [.option])
            try mouse(.leftMouseDown, center, f, flags: [.control, .option]); try mouse(.leftMouseUp, center, f)
            settle(t, f); t.equal(menus, 3); t.equal(f.recorder.calls, ["copy:parent-right"])
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { throw S.Failure.fixture }
            let bounds = screen.visibleFrame
            widget.window.setFrameOrigin(NSPoint(x: bounds.midX - 40, y: bounds.midY - 30))
            f.time.runUntilIdle(); try takeFacts(f); settle(t, f)
            let original = widget.window.frame
            var pointer = NSPoint(x: original.midX, y: original.midY)
            widget.view.pointerLocation = { pointer }
            try mouse(.leftMouseDown, padding, f, flags: [.command])
            pointer.x += 40; pointer.y += 30
            try mouse(.leftMouseDragged, padding, f, flags: [.command])
            try mouse(.leftMouseUp, padding, f, flags: [.command]); settle(t, f)
            t.equal(widget.window.frame.origin, NSPoint(x: original.minX + 40, y: original.minY + 30))
            let stored = f.app.state.deskInstance(widget.instance.id)
            let expected = WindowGeometry.topLeft(of: widget.window.frame,
                primaryHeight: WindowGeometry.primaryHeight(WindowGeometry.currentScreens()))
            t.close(stored?.x ?? .nan, expected.x); t.close(stored?.y ?? .nan, expected.y)
            t.equal(f.recorder.calls, ["copy:parent-right"], "desktop movement cancels the parent press before release")
            try takeFacts(f); settle(t, f)
            try click(padding, f); settle(t, f)
            t.equal(f.recorder.calls, ["copy:parent-right", "open:" + settings], "a new press still opens the captured settings URL")
            t.equal(menus, 3); t.equal(f.time.background.reports, [])
        }
    }

    private static var cardSource: String {
        """
        widget { Freeform {
            Rectangle().size(40, 20).fill(.red).name(child).onClick { copy("child") }.onRightClick {}
        }.size(80, 60).name(card).voiceOver("Battery settings")
            .onClick { open("\(settings)") }.onRightClick { copy("parent-right") } }
        """
    }

    private static func fixture(_ t: AppTestRunner, _ sourceText: String) throws -> Fixture {
        let root = t.temporaryDirectory("desk-container-window"), time = try S.clock(), recorder = Recorder()
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
        let services = DeskProgramActionServices(resolver: DeskProgramOpenResolver(application: { _ in nil },
            applicationNamed: { _ in nil }, exists: { _ in false }),
            copy: { recorder.record("copy:" + $0) }, open: { recorder.record("open:" + $0.absoluteString) })
        let widget = DeskWidgetWindowController(source: source, instance: instance, directory: directory,
            program: try S.program(sourceText), prepared: nil, app: app, executor: time, clock: time.clock, actionServices: services)
        t.atSuiteEnd {
            widget.close(deactivate: false)
            _ = AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isClosed }
            _ = app.stopAllForTermination(); app.endEngineThread()
        }
        t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isStarted && widget.latestPresented != nil })
        guard let host = widget.owner.host else { throw S.Failure.fixture }
        let result = Fixture(app: app, widget: widget, host: host, time: time, recorder: recorder)
        try takeFacts(result); settle(t, result)
        t.check(!widget.window.isVisible, "native fixtures are never ordered onto the user's desktop")
        return result
    }

    private static func takeFacts(_ f: Fixture, takesPointer: Bool = true) throws {
        let input = try DeskWidgetWindowController.makeInput(for: f.widget.window.effectiveAppearance,
            scale: f.widget.window.backingScaleFactor)
        guard let space = f.widget.window.colorSpace?.cgColorSpace else { throw S.Failure.fixture }
        let facts = SkinWindowFacts(frame: f.widget.window.frame, isVisible: true, isOrderedIn: true,
            scale: f.widget.window.backingScaleFactor, colorSpace: space, appearance: input.environment.appearance.name,
            takesPointer: takesPointer, sequence: 100, panelGeneration: f.widget.destinationEpoch)
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
        }, "visible=\(f.host.frames.canBeSeen), needsFrame=\(f.host.frames.needsFrame), pending=\(f.host.frames.hasBitmapDelivery), " +
            "ownerEpoch=\(f.widget.owner.currentEpoch), MainEpoch=\(f.widget.destinationEpoch), " +
            "generations=\(String(describing: f.host.scene?.generation))/\(String(describing: f.host.presented?.scene.generation))/" +
            "\(String(describing: f.widget.latestPresented?.scene.generation))", line: line)
    }

    private static func part(_ f: Fixture, _ name: String) throws -> DeskWidgetAccessibilityElement {
        guard let child = f.widget.view.accessibilityParts.first(where: { $0.id.name == name }) else { throw S.Failure.fixture }
        return child
    }

    private static func click(_ point: NSPoint, _ f: Fixture, secondary: Bool = false) throws {
        try mouse(secondary ? .rightMouseDown : .leftMouseDown, point, f)
        try mouse(secondary ? .rightMouseUp : .leftMouseUp, point, f)
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
        case .leftMouseDragged: f.widget.view.mouseDragged(with: event)
        case .rightMouseDown: f.widget.view.rightMouseDown(with: event)
        case .rightMouseUp: f.widget.view.rightMouseUp(with: event)
        default: throw S.Failure.fixture
        }
    }
}
