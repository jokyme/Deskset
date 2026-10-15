import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Branch integration uses real preview canvases and mouse events. Controlled vector replies isolate
/// transaction ownership; the existing IconDrawingSelfTests retain the native SF Symbol pixel oracles.
enum DeskViewIfPreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private typealias V = DeskViewIfTestSupport
    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
        let system: S.System
    }

    private static func fixture(_ t: AppTestRunner, _ source: String, dark: Bool = false,
                                prepare: @escaping DeskProgramPreviewController.IconPreparation = DeskIconResources.prepare) throws -> Fixture {
        let file = DeskFileID(path: "ViewIf.desk")
        let service = DeskLanguageService(openFile: file, files: [file: source])
        guard !service.snapshot.diagnostics.contains(where: { $0.severity == .error }) else {
            throw S.Failure.compilation(String(describing: service.snapshot.diagnostics))
        }
        _ = try S.program(source)
        let time = try S.clock(), system = S.System()
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US_POSIX") }, system: system, prepareIcons: prepare) {
                $0.file == file && $0.generation == service.snapshot.generation
                    && $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: preview)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
        preview.show(service.snapshot, readError: nil)
        return Fixture(service: service, preview: preview, window: window, time: time, system: system)
    }

    private final class LiteralView: NSView {
        let rectangles: [(CGRect, RGBA)]
        override var isFlipped: Bool { true }
        init(size: NSSize, rectangles: [(CGRect, RGBA)]) {
            self.rectangles = rectangles
            super.init(frame: NSRect(origin: .zero, size: size))
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            for (rect, value) in rectangles {
                context.setFillColor(CGColor(srgbRed: value.r / 255, green: value.g / 255,
                                            blue: value.b / 255, alpha: value.a / 255))
                context.fill(rect)
            }
        }
    }

    private static func point(_ f: Fixture, _ name: String) throws -> NSPoint {
        let frame = try S.element(f.preview.scene, name).frame
        return NSPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }
    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in f: Fixture) throws {
        let location = f.preview.canvas.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) else { throw S.Failure.fixture }
        switch type {
        case .leftMouseDown: f.preview.canvas.mouseDown(with: event)
        case .leftMouseUp: f.preview.canvas.mouseUp(with: event)
        case .rightMouseDown: f.preview.canvas.rightMouseDown(with: event)
        case .rightMouseUp: f.preview.canvas.rightMouseUp(with: event)
        default: throw S.Failure.fixture
        }
    }
    private static func click(_ f: Fixture, _ name: String) throws {
        let location = try point(f, name)
        try mouse(.leftMouseDown, at: location, in: f)
        try mouse(.leftMouseUp, at: location, in: f)
    }
    private static func pixels(_ t: AppTestRunner, _ view: NSView, size: NSSize,
                               rectangles: [(CGRect, RGBA)]) throws {
        let reference = LiteralView(size: size, rectangles: rectangles)
        for scale in [1, 2] {
            let actual = try S.paint(view, scale: scale), expected = try S.paint(reference, scale: scale)
            t.equal(actual.width, Int(size.width) * scale); t.equal(actual.height, Int(size.height) * scale)
            t.equal(try S.bytes(actual), try S.bytes(expected), "independent rectangle oracle at \(scale)x")
        }
    }

    static func run(_ t: AppTestRunner) {
        // Keep this existing-grammar regression first so its failure is independent of view-if lowering.
        t.suite("Desk: view if preview: empty symbol pending retains one deferred clock refresh") {
            try emptyPending(t, source: #"widget { Icon(cpu.usage > 50% ? "wifi" : "").size(40) }"#)
        }
        t.suite("Desk: view if preview: empty branch pending retains one deferred clock refresh") {
            try emptyPending(t, source: #"widget { if cpu.usage > 50% { Icon("wifi").size(40) } }"#)
        }
        layoutTests(t)
        pressTest(t)
        pendingTest(t)
    }

    private static func emptyPending(_ t: AppTestRunner, source: String) throws {
        let preparations = S.Preparation(), f = try fixture(t, source, prepare: preparations.submit), p = f.preview
        p.setVisible(true)
        t.equal(p.state, .empty); t.check(p.canvas.isHidden)
        t.equal(preparations.calls.count, 0); t.equal(p.updateMilliseconds, 1_000)
        f.system.cpu = 75; f.time.advance(by: 1)
        t.check(p.isPreparingIcons); t.equal(p.state, .empty)
        t.equal(preparations.calls.count, 1)
        t.equal(try preparations.call(0).demands.map { $0.request.name }, ["wifi"])
        let reads = f.system.cpuCalls, generation = p.scene?.generation
        f.system.cpu = 25; f.time.advance(by: 2)
        t.equal(f.system.cpuCalls, reads, "pending ticks freeze system inputs")
        t.equal(preparations.calls.count, 1); t.equal(p.scene?.generation, generation)
        try preparations.succeed(0); f.time.runUntilIdle()
        t.equal(p.state, .empty); t.check(p.canvas.isHidden); t.equal(S.icons(p.scene), [])
        t.equal(f.system.cpuCalls, reads + 1, "the pending interval owes exactly one fresh sample")
        t.equal(p.scene?.generation, generation.map { $0 + 2 }, "commit the captured candidate, then the deferred input")
        t.equal(p.recordedEffects, []); t.check(!p.isPreparingIcons)
        let settledGeneration = p.scene?.generation
        try preparations.succeed(0); f.time.runUntilIdle()
        t.equal(p.scene?.generation, settledGeneration, "a duplicate reply cannot revive the captured visible branch")
        f.system.cpu = 75; f.time.advance(by: 1)
        t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
        t.equal(S.icons(p.scene).map { $0.request.name }, ["wifi"])
        t.equal(preparations.calls.count, 1, "returning to the branch reuses its prepared resource")
        t.check(try S.bytes(S.paint(p.canvas)).contains(where: { $0 != 0 }))
        p.close(); let closedReads = f.system.cpuCalls
        f.time.advance(by: 3); t.equal(f.system.cpuCalls, closedReads)
        t.equal(f.time.background.reports, [])
    }

    private static func layoutTests(_ t: AppTestRunner) {
        t.suite("Desk: view if preview: row branches splice children without a wrapper slot and retain identities") {
            for dark in [false, true] {
                let f = try fixture(t, V.rowSource, dark: dark), p = f.preview
                p.setVisible(true); t.equal(p.state, .ready)
                let switcher = try S.element(p.scene, "switcher").id
                let tail = try S.element(p.scene, "tail").id
                let first = try S.element(p.scene, "first").id
                let second = try S.element(p.scene, "second").id
                var alternate: ElementID?
                for (index, stage) in [0, 1, 2, 0].enumerated() {
                    if index > 0 { try click(f, "switcher") }
                    let expected = V.row(stage)
                    t.equal(p.scene?.size, SkinSize(width: expected.size.width, height: expected.size.height))
                    t.equal(p.canvas.bounds, NSRect(origin: .zero, size: expected.size))
                    try pixels(t, p.canvas, size: expected.size, rectangles: expected.rectangles)
                    t.equal(try S.element(p.scene, "switcher").id, switcher)
                    t.equal(try S.element(p.scene, "tail").id, tail)
                    t.equal(V.branchNames(p.scene), expected.names)
                    if stage == 0 {
                        t.equal(try S.element(p.scene, "first").id, first)
                        t.equal(try S.element(p.scene, "second").id, second)
                    } else if stage == 1 {
                        alternate = try S.element(p.scene, "alternate").id
                        t.check(alternate != first && alternate != second)
                    }
                    t.check(p.scene?.elements.contains(where: { $0.id.name.hasPrefix("if#") }) == false)
                }
                t.check(alternate != nil)
                try click(f, "tail"); t.equal(p.recordedEffects, [.copy("tail")])
            }
        }

        t.suite("Desk: view if preview: selected preset overflow scales pixels and native clicks as one candidate") {
            let source = """
            info { size: .small }
            widget { variable expanded = true
                Column(spacing: 0, align: .left) {
                    if expanded {
                        Rectangle().size(340, 340).fill("#FF0000").name(largebox)
                            .onClick { expanded = false; copy("large") }
                    } else {
                        Rectangle().size(170, 170).fill("#0000FF").name(smallbox)
                            .onClick { expanded = true; copy("small") }
                    }
                }
            }
            """
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            let original = try S.element(p.scene, "largebox").id
            let size = NSSize(width: 170, height: 170)
            for (index, large) in [true, false, true].enumerated() {
                t.equal(p.state, .ready); t.equal(p.scene?.size, SkinSize(width: 170, height: 170))
                let target = try S.element(p.scene, large ? "largebox" : "smallbox")
                t.equal(target.frame, SkinRect(width: 170, height: 170))
                if large { t.equal(target.id, original) } else { t.check(target.id != original) }
                try pixels(t, p.canvas, size: size,
                    rectangles: [(CGRect(origin: .zero, size: size), large ? S.red : S.blue)])
                let effects = p.recordedEffects
                try mouse(.leftMouseDown, at: NSPoint(x: 300, y: 85), in: f)
                try mouse(.leftMouseUp, at: NSPoint(x: 300, y: 85), in: f)
                t.equal(p.recordedEffects, effects, "unscaled coordinates cannot hit the preset branch")
                if index < 2 { try click(f, large ? "largebox" : "smallbox") }
            }
            t.equal(p.recordedEffects, [.copy("large"), .copy("small")])
        }
    }

    private static func pressTest(_ t: AppTestRunner) {
        t.suite("Desk: view if preview: branch deletion retires both presses while active clock repaint preserves them") {
            let f = try fixture(t, V.pressSource), p = f.preview
            p.setVisible(true)
            let oldID = try S.element(p.scene, "clocktarget").id
            for secondary in [false, true] {
                let location = try point(f, "clocktarget")
                let down: NSEvent.EventType = secondary ? .rightMouseDown : .leftMouseDown
                let up: NSEvent.EventType = secondary ? .rightMouseUp : .leftMouseUp
                try mouse(down, at: location, in: f)
                f.system.charging = true; p.notifyPowerChange()
                t.equal(S.texts(p.scene), []); t.equal(p.updateMilliseconds, 60_000)
                t.check(p.scene?.elements.contains(where: { $0.id == oldID }) == false)
                let replacement = try S.element(p.scene, "replacement")
                t.check(replacement.id != oldID); t.equal(replacement.frame, SkinRect(width: 40, height: 20))
                let generation = p.scene?.generation, reads = f.system.batteryCalls, effects = p.recordedEffects
                f.time.advance(by: 3)
                t.equal(p.scene?.generation, generation); t.equal(f.system.batteryCalls, reads)
                f.system.charging = false; p.notifyPowerChange()
                t.equal(try S.element(p.scene, "clocktarget").id, oldID); t.equal(p.updateMilliseconds, 1_000)
                try mouse(up, at: location, in: f)
                t.equal(p.recordedEffects, effects, "returning to the same stable ID must not resurrect a deleted gesture")
                try mouse(down, at: location, in: f)
                f.time.advance(by: 1)
                try mouse(up, at: location, in: f)
                t.equal(p.recordedEffects, effects + [.copy(secondary ? "primary-right" : "primary-left")])
            }
            p.close(); let reads = f.system.batteryCalls
            p.notifyPowerChange(); f.time.advance(by: 3); t.equal(f.system.batteryCalls, reads)
        }
    }

    private static func pendingTest(_ t: AppTestRunner) {
        t.suite("Desk: view if preview: inactive icons request nothing and pending branch actions keep their frozen owner") {
            let preparations = S.Preparation(), f = try fixture(t, V.iconSource, prepare: preparations.submit), p = f.preview
            t.equal(try preparations.call(0).demands.map { $0.request.name }, ["wifi"])
            try preparations.succeed(0); f.time.runUntilIdle(); p.setVisible(true)
            let initial = try S.bytes(S.paint(p.canvas)), oldID = try S.element(p.scene, "oldicon").id
            var committedAtEffect = false
            p.onRecordedEffects = { _ in
                committedAtEffect = S.icons(p.scene).map { $0.request.name } == ["sun.max.fill"]
                    && p.scene?.elements.contains(where: { $0.id == oldID }) == false
            }
            try click(f, "oldicon")
            t.check(p.isPreparingIcons); t.equal(p.recordedEffects, []); t.equal(preparations.calls.count, 2)
            t.equal(try preparations.call(1).demands.map { $0.request.name }, ["sun.max.fill"])
            let samples = f.system.cpuCalls, generation = p.scene?.generation
            f.system.cpu = 75; f.time.advance(by: 2)
            t.equal(f.system.cpuCalls, samples); t.equal(p.scene?.generation, generation)
            t.equal(try S.bytes(S.paint(p.canvas)), initial, "committed PDFs remain drawable during a branch request")
            try preparations.succeed(1); f.time.runUntilIdle()
            t.check(committedAtEffect); t.equal(p.recordedEffects, [.copy("next")])
            t.equal(try S.element(p.scene, "oldicon").id, oldID)
            t.equal(S.icons(p.scene).map { $0.request.name }, ["wifi"])
            t.equal(try S.bytes(S.paint(p.canvas)), initial)
            t.equal(f.system.cpuCalls, samples + 1); t.equal(preparations.calls.count, 2)
            f.system.cpu = 25; f.time.advance(by: 1)
            t.equal(S.icons(p.scene).map { $0.request.name }, ["sun.max.fill"])
            t.equal(preparations.calls.count, 2); t.check(try S.bytes(S.paint(p.canvas)) != initial)
            try preparations.succeed(1); f.time.runUntilIdle()
            t.equal(p.recordedEffects, [.copy("next")])
            try click(f, "newicon")
            t.equal(p.recordedEffects, [.copy("next"), .copy("back")])
            t.equal(try S.bytes(S.paint(p.canvas)), initial); t.equal(preparations.calls.count, 2)
            p.setVisible(false); let reads = f.system.cpuCalls
            f.time.advance(by: 3); t.equal(f.system.cpuCalls, reads)
            p.setVisible(true); t.check(f.system.cpuCalls > reads)
        }
    }
}
