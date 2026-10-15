import AppKit
import DeskLanguage
import DesksetCore

enum DeskTooltipIntegrationSelfTests {
    private typealias S = DeskConditionalTestSupport
    private final class Pointer { var point = NSPoint.zero }
    private struct Desktop {
        let app: AppController
        let widget: DeskWidgetWindowController
        let time: VirtualTimeExecutor
        let pointer: Pointer
    }
    private struct Preview {
        let service: DeskLanguageService
        let controller: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
        let pointer: Pointer
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk tooltip integration: desktop hover uses the accepted negative origin and preset once") {
            for preset in [false, true] {
                let f = try desktop(t, """
                \(preset ? "info { size: .small }" : "")
                widget { Freeform {
                    Rectangle().size(340, 170).position(x: -40, y: -20).fill(.red)
                        .name(card).tooltip("Body", title: "Battery")
                } }
                """), w = f.widget
                guard let hover = w.view.programTooltips, let shown = w.latestPresented else { throw S.Failure.fixture }
                t.equal(shown.origin, preset ? SkinPoint() : SkinPoint(x: -40, y: -20))
                let expectedFrame = preset ? SkinRect(width: 170, height: 85) :
                    SkinRect(x: -40, y: -20, width: 340, height: 170)
                t.equal(try S.element(shown.scene, "card").frame, expectedFrame)
                // A small preset keeps a square viewport; this 2:1 card occupies only its top half.
                let point = preset ? NSPoint(x: 85, y: 42.5) : NSPoint(x: 170, y: 85)
                t.equal(w.tooltipTarget(at: point)?.id.name, "card",
                        "preset=\(preset), point=\(point), origin=\(shown.origin), size=\(shown.size), " +
                        "epoch=\(w.lastAcceptedEpoch)/\(w.destinationEpoch), ignoresMouse=\(w.window.ignoresMouseEvents), " +
                        "error=\(String(describing: w.view.toolTip)), hits=\(shown.scene.hitMap.entries.map { $0.frame })")
                t.equal(w.tooltipTarget(at: NSPoint(x: -1, y: -1)), nil)
                if preset { t.equal(w.tooltipTarget(at: NSPoint(x: 85, y: 85)), nil, "the card's bottom edge is outside its hit box") }
                try move(w.view, in: w.window, to: point, pointer: f.pointer)
                t.equal(hover.selectedTarget?.info, ToolTipInfo(text: "Body", title: "Battery"))
                f.time.advance(by: hover.initialDelay + 0.01)
                t.equal(hover.shownTarget?.id.name, "card")
                t.equal(hover.shownTarget?.revision.generation, shown.scene.generation)
                t.check(hover.panel?.ignoresMouseEvents == true)
                t.check(hover.panel?.isVisible == false && !w.window.isVisible)
                t.equal(shown.scene.hitMap.entry(at: 0, 0, handling: .leftUp, images: nil), nil,
                        "tooltip-only content does not acquire a click handler")
                try mouse(.leftMouseDown, view: w.view, window: w.window, point: point)
                t.equal(hover.shownTarget, nil)
                hover.refresh(); f.time.advance(by: hover.initialDelay + 0.01)
                t.equal(hover.shownTarget, nil, "a press suppresses refresh until the next real pointer motion")
                try mouse(.leftMouseUp, view: w.view, window: w.window, point: point)
                try move(w.view, in: w.window, to: point, pointer: f.pointer)
                f.time.advance(by: hover.initialDelay + 0.01)
                t.equal(hover.shownTarget?.id.name, "card")
                w.close(deactivate: false)
                t.equal(hover.selectedTarget, nil); t.equal(hover.shownTarget, nil)
                t.check(w.tooltipTarget(at: point) == nil)
            }
        }

        t.suite("App: Desk tooltip integration: errors destination changes and unavailable scenes retire desktop hover") {
            let f = try desktop(t, #"widget { Rectangle().size(80, 40).fill(.blue).tooltip("Current").onClick { copy("value") } }"#)
            let w = f.widget, point = NSPoint(x: 40, y: 20)
            guard let hover = w.view.programTooltips else { throw S.Failure.fixture }
            try move(w.view, in: w.window, to: point, pointer: f.pointer)
            f.time.advance(by: hover.initialDelay + 0.01)
            t.equal(hover.shownTarget?.info.text, "Current")
            guard let token = w.issueClickToken() else { throw S.Failure.fixture }
            w.handleEffects([.copy("fails in the injected service")], token: token, issuedToken: token)
            t.check(w.lastActionFailure != nil && w.view.toolTip != nil)
            t.equal(hover.shownTarget, nil); t.equal(w.tooltipTarget(at: point), nil)
            let oldEpoch = w.destinationEpoch
            let dark = w.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            w.window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            _ = w.currentFacts()
            t.check(w.destinationEpoch != oldEpoch)
            t.equal(w.tooltipTarget(at: point), nil)
            w.handleUnavailable("resources", session: w.sessionID, epoch: w.destinationEpoch)
            t.check(w.latestPresented == nil && w.lastUnavailableMessage != nil)
            hover.refresh(); f.time.advance(by: hover.initialDelay + 0.01)
            t.equal(hover.selectedTarget, nil); t.equal(hover.shownTarget, nil)
        }

        t.suite("App: Desk tooltip integration: preview mouse conversion follows negative bounds zoom and scrolling") {
            let f = try preview(t, """
            widget { variable count = 0
                Freeform { Rectangle().size(340, 170).position(x: -40, y: -20).fill(.red)
                    .name(card).tooltip("Count {count}", title: "Details").onClick { count = count + 1 }
                }
            }
            """), p = f.controller
            guard let hover = p.canvas.programTooltips else { throw S.Failure.fixture }
            t.equal(p.canvas.bounds.origin, NSPoint(x: -40, y: -20))
            for zoom in [0.5, 1.5] {
                p.setZoom(zoom)
                f.window.contentView?.layoutSubtreeIfNeeded()
                let area = p.canvas.visibleRect.intersection(p.canvas.bounds)
                t.check(!area.isEmpty)
                let point = NSPoint(x: area.midX, y: area.midY)
                try move(p.canvas, in: f.window, to: point, pointer: f.pointer)
                t.equal(hover.selectedTarget?.id.name, "card")
                f.time.advance(by: hover.initialDelay + 0.01)
                t.equal(hover.shownTarget?.info.title, "Details")
                t.check(hover.panel?.isVisible == false && !f.window.isVisible)
            }
            let area = p.canvas.visibleRect.intersection(p.canvas.bounds)
            let point = NSPoint(x: area.midX, y: area.midY)
            try mouse(.leftMouseDown, view: p.canvas, window: f.window, point: point)
            try mouse(.leftMouseUp, view: p.canvas, window: f.window, point: point)
            t.equal(p.tooltipTarget(at: point)?.info.text, "Count 1")
            t.equal(hover.shownTarget, nil)
            try move(p.canvas, in: f.window, to: point, pointer: f.pointer)
            f.time.advance(by: hover.initialDelay + 0.01)
            t.equal(hover.shownTarget?.info.text, "Count 1")
            f.pointer.point = .init(x: -100_000, y: -100_000)
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: p.scrollView.contentView)
            t.equal(hover.shownTarget, nil, "viewport changes re-hit the actual pointer through AppKit conversion")
            p.setVisible(false)
            t.equal(p.tooltipTarget(at: point), nil); t.equal(hover.selectedTarget, nil)
            p.close(); t.equal(hover.shownTarget, nil)
            t.equal(f.time.background.reports, [])
        }

        t.suite("App: Desk tooltip integration: preview pending resources keep old hover until the accepted picture changes") {
            let preparations = S.Preparation()
            let f = try preview(t, """
            widget { variable name = "wifi"; variable count = 0
                Icon(name).size(80, 40).name(symbol).tooltip("Count {count}", title: "Icon")
                    .onClick { name = "sun.max.fill"; count = count + 1; copy("{count}") }
            }
            """, prepare: preparations.submit), p = f.controller
            t.check(p.isPreparingIcons); t.equal(preparations.calls.count, 1)
            try preparations.succeed(0); f.time.runUntilIdle()
            t.equal(p.state, .ready)
            guard let hover = p.canvas.programTooltips else { throw S.Failure.fixture }
            let point = NSPoint(x: 40, y: 20)
            try move(p.canvas, in: f.window, to: point, pointer: f.pointer)
            f.time.advance(by: hover.initialDelay + 0.01)
            let old = hover.shownTarget
            t.equal(old?.info.text, "Count 0")
            try mouse(.leftMouseDown, view: p.canvas, window: f.window, point: point)
            try mouse(.leftMouseUp, view: p.canvas, window: f.window, point: point)
            t.check(p.isPreparingIcons); t.equal(preparations.calls.count, 2)
            t.equal(p.tooltipTarget(at: point), old)
            try move(p.canvas, in: f.window, to: point, pointer: f.pointer)
            f.time.advance(by: hover.initialDelay + 0.01)
            t.equal(hover.shownTarget, old); t.equal(p.recordedEffects, [])
            try preparations.succeed(1); f.time.runUntilIdle()
            f.time.advance(by: hover.initialDelay + 0.01)
            t.equal(hover.shownTarget?.info.text, "Count 1")
            t.check(hover.shownTarget?.revision.generation != old?.revision.generation)
            t.equal(p.recordedEffects, [.copy("1")])
            let replacement = f.service.replaceText(#"widget { Text("replacement") }"#, version: 2)
            t.equal(p.tooltipTarget(at: point), nil, "unaccepted source cannot borrow old scene hover")
            p.show(replacement, readError: nil)
            t.equal(hover.selectedTarget, nil); t.equal(hover.shownTarget, nil)
            t.equal(f.time.background.reports, [])
        }

        t.suite("App: Desk tooltip integration: explicit empty child suppresses parent without intercepting its click") {
            let f = try preview(t, """
            widget { Freeform {
                Rectangle().size(40, 20).fill(.red).name(child).tooltip("")
            }.size(80, 40).name(parent).tooltip("", title: "Title only").onClick { copy("parent") } }
            """), p = f.controller
            guard let hover = p.canvas.programTooltips else { throw S.Failure.fixture }
            let padding = NSPoint(x: 5, y: 20), center = NSPoint(x: 40, y: 20)
            try move(p.canvas, in: f.window, to: padding, pointer: f.pointer)
            f.time.advance(by: hover.initialDelay + 0.01)
            t.equal(hover.shownTarget?.info.title, "Title only")
            try move(p.canvas, in: f.window, to: center, pointer: f.pointer)
            t.equal(hover.selectedTarget?.id.name, "child")
            t.equal(hover.shownTarget, nil)
            try mouse(.leftMouseDown, view: p.canvas, window: f.window, point: center)
            try mouse(.leftMouseUp, view: p.canvas, window: f.window, point: center)
            t.equal(p.recordedEffects, [.copy("parent")])
            t.equal(f.time.background.reports, [])
        }
    }

    private static func desktop(_ t: AppTestRunner, _ sourceText: String) throws -> Desktop {
        let root = t.temporaryDirectory("desk-tooltip-window"), time = try S.clock(), pointer = Pointer()
        let app = AppController(state: AppState(fileURL: root.appendingPathComponent("state.json")),
            skinsDirectory: root.appendingPathComponent("Skins"), layoutsDirectory: root.appendingPathComponent("Layouts"),
            backupsDirectory: root.appendingPathComponent("Backups"), defaultSkinsSource: nil,
            settingsDirectory: root.appendingPathComponent("Settings"), widgetsDirectory: root.appendingPathComponent("Widgets"),
            presentsWindows: false)
        let sourceID = UUID(), source = DeskWidgetSourceState(id: sourceID, entry: sourceID.uuidString.lowercased() + "/Main.desk")
        let instance = DeskWidgetInstanceState(id: UUID(), sourceID: sourceID)
        let directory = root.appendingPathComponent("Widgets").appendingPathComponent(sourceID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(sourceText.utf8).write(to: directory.appendingPathComponent("Main.desk"))
        try app.state.registerDeskInstallation(source: source, instance: instance)
        let services = DeskProgramActionServices(resolver: DeskProgramOpenResolver(application: { _ in nil },
            applicationNamed: { _ in nil }, exists: { _ in false }), copy: { _ in false }, open: { _ in false })
        let widget = DeskWidgetWindowController(source: source, instance: instance, directory: directory,
            program: try S.program(sourceText), prepared: nil, app: app, executor: time, clock: time.clock,
            actionServices: services, tooltipExecutor: time)
        widget.view.pointerLocation = { pointer.point }
        t.atSuiteEnd {
            widget.close(deactivate: false)
            _ = AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isClosed }
            _ = app.stopAllForTermination(); app.endEngineThread()
        }
        t.check(AppSelfTest.spin(timeout: 10) { time.runUntilIdle(); return widget.isStarted && widget.latestPresented != nil })
        t.check(!widget.window.isVisible)
        return Desktop(app: app, widget: widget, time: time, pointer: pointer)
    }

    private static func preview(_ t: AppTestRunner, _ text: String,
                                prepare: @escaping DeskProgramPreviewController.IconPreparation = DeskIconResources.prepare) throws -> Preview {
        let file = DeskFileID(path: "Tooltip.desk"), service = DeskLanguageService(openFile: file, files: [file: text])
        _ = try S.program(text)
        let time = try S.clock(), pointer = Pointer()
        let controller = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US_POSIX") }, system: S.System(), prepareIcons: prepare,
            presentsTooltips: false) {
                $0.file == file && $0.generation == service.snapshot.generation
                    && $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: controller)
        window.contentView?.layoutSubtreeIfNeeded()
        controller.canvas.pointerLocation = { pointer.point }
        t.atSuiteEnd { controller.close(); window.close(); time.runUntilIdle() }
        controller.show(service.snapshot, readError: nil)
        controller.setVisible(true)
        return Preview(service: service, controller: controller, window: window, time: time, pointer: pointer)
    }

    private static func move(_ view: NSView, in window: NSWindow, to point: NSPoint, pointer: Pointer) throws {
        pointer.point = window.convertPoint(toScreen: view.convert(point, to: nil))
        try mouse(.mouseMoved, view: view, window: window, point: point)
    }

    private static func mouse(_ type: NSEvent.EventType, view: NSView, window: NSWindow, point: NSPoint) throws {
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw S.Failure.fixture }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: throw S.Failure.fixture
        }
    }
}
