import AppKit
import DeskLanguage
import DesksetCore

enum DeskContainerClickPreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
        let system: S.System
    }

    private static func fixture(_ t: AppTestRunner, _ source: String) throws -> Fixture {
        let file = DeskFileID(path: "ContainerClicks.desk")
        let service = DeskLanguageService(openFile: file, files: [file: source])
        _ = try S.program(source)
        let time = try S.clock(), system = S.System()
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US_POSIX") }, system: system) {
                $0.file == file && $0.generation == service.snapshot.generation
                    && $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: preview)
        window.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
        preview.show(service.snapshot, readError: nil)
        preview.setVisible(true)
        return Fixture(service: service, preview: preview, window: window, time: time, system: system)
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ f: Fixture) throws {
        guard let event = NSEvent.mouseEvent(with: type,
            location: f.preview.canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) else { throw S.Failure.fixture }
        switch type {
        case .leftMouseDown: f.preview.canvas.mouseDown(with: event)
        case .leftMouseUp: f.preview.canvas.mouseUp(with: event)
        case .leftMouseDragged: f.preview.canvas.mouseDragged(with: event)
        case .rightMouseDown: f.preview.canvas.rightMouseDown(with: event)
        case .rightMouseUp: f.preview.canvas.rightMouseUp(with: event)
        default: throw S.Failure.fixture
        }
    }

    private static func click(_ point: NSPoint, _ f: Fixture, secondary: Bool = false) throws {
        try mouse(secondary ? .rightMouseDown : .leftMouseDown, point, f)
        try mouse(secondary ? .rightMouseUp : .leftMouseUp, point, f)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Desk: container click preview: empty interactive boxes retain established preview gesture semantics") {
            for component in ["Row {}", "Column {}", "Freeform {}"] {
                let source = """
                widget { \(component).size(80, 40).rounded(8).name(card)
                    .onClick { copy("primary") }.onRightClick { copy("secondary") } }
                """
                let f = try fixture(t, source), p = f.preview
                t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
                t.equal(p.canvas.bounds.size, NSSize(width: 80, height: 40))
                t.equal(try S.element(p.scene, "card").frame, SkinRect(width: 80, height: 40))
                t.equal(p.scene?.hitMap.entries.count, 1)
                try click(NSPoint(x: 0, y: 0), f)
                t.equal(p.recordedEffects, [], "a rounded corner is outside the transparent interaction box")
                let center = NSPoint(x: 40, y: 20)
                try click(center, f); try click(center, f, secondary: true)
                t.equal(p.recordedEffects, [.copy("primary"), .copy("secondary")])
                let effects = p.recordedEffects, generation = p.scene?.generation
                try mouse(.leftMouseDown, center, f)
                try mouse(.leftMouseDragged, NSPoint(x: 45, y: 20), f)
                try mouse(.leftMouseUp, center, f)
                t.equal(p.recordedEffects, effects + [.copy("primary")],
                        "simulation preserves its existing primary release-on-same-target behavior")
                t.equal(p.scene?.generation, generation.map { $0 + 1 })
                t.equal(f.time.background.reports, [])
            }
        }

        t.suite("Desk: container click preview: child empty primary catches while secondary and padding use parent") {
            let source = """
            widget { Freeform {
                Rectangle().size(40, 20).fill(.red).name(child).onClick {}
            }.size(80, 40).padding(4).rounded(8).name(card)
                .onClick { copy("parent") }.onRightClick { copy("right") } }
            """
            let f = try fixture(t, source), p = f.preview
            t.equal(p.state, .ready)
            t.equal(try S.element(p.scene, "child").frame, SkinRect(x: 20, y: 10, width: 40, height: 20))
            let center = NSPoint(x: 40, y: 20), padding = NSPoint(x: 2, y: 20)
            try click(center, f); t.equal(p.recordedEffects, [])
            try click(center, f, secondary: true); t.equal(p.recordedEffects, [.copy("right")])
            try click(padding, f); t.equal(p.recordedEffects, [.copy("right"), .copy("parent")])
            let effects = p.recordedEffects
            try mouse(.leftMouseDown, padding, f); try mouse(.leftMouseUp, center, f)
            try mouse(.leftMouseDown, center, f); try mouse(.leftMouseUp, padding, f)
            t.equal(p.recordedEffects, effects, "release on another handler cannot activate either target")
            t.equal(f.time.background.reports, [])
        }

        t.suite("Desk: container click preview: changing branches retains parent presses and retires removed child presses") {
            let source = """
            widget { Freeform {
                if battery.charging {
                    Rectangle().size(40, 20).fill(.red).name(child).onClick { copy("child") }
                }
            }.size(80, 40).name(card).onClick { copy("parent") } }
            """
            let f = try fixture(t, source), p = f.preview
            t.equal(p.state, .ready)
            let parent = try S.element(p.scene, "card").id
            let padding = NSPoint(x: 2, y: 20), center = NSPoint(x: 40, y: 20)
            try mouse(.leftMouseDown, padding, f)
            f.system.charging = true; p.notifyPowerChange()
            t.equal(try S.element(p.scene, "card").id, parent)
            t.equal(try S.element(p.scene, "child").frame, SkinRect(x: 20, y: 10, width: 40, height: 20))
            try mouse(.leftMouseUp, padding, f)
            t.equal(p.recordedEffects, [.copy("parent")])
            let child = try S.element(p.scene, "child").id
            try mouse(.leftMouseDown, center, f)
            f.system.charging = false; p.notifyPowerChange()
            t.equal(p.state, .ready, "the remaining empty container still handles clicks")
            t.check(p.scene?.elements.contains(where: { $0.id == child }) == false)
            f.system.charging = true; p.notifyPowerChange()
            t.equal(try S.element(p.scene, "child").id, child)
            try mouse(.leftMouseUp, center, f)
            t.equal(p.recordedEffects, [.copy("parent")])
            try click(center, f)
            t.equal(p.recordedEffects, [.copy("parent"), .copy("child")])
            t.equal(f.time.background.reports, [])
        }
    }
}
