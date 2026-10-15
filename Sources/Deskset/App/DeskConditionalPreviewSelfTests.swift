import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// Real preview canvases and mouse events with deterministic clocks and immutable, controlled icon replies.
/// Conditional native symbol color fidelity remains covered by the existing IconDrawingSelfTests oracles.
enum DeskConditionalPreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
        let system: S.System
    }

    private static func fixture(_ t: AppTestRunner, _ source: String, dark: Bool = false,
                                prepare: @escaping DeskProgramPreviewController.IconPreparation = DeskIconResources.prepare) throws -> Fixture {
        let file = DeskFileID(path: "Conditional.desk")
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

    /// Uses Core Graphics rectangles directly; it does not lower ProgramColor or call the scene renderer.
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
        try mouse(.leftMouseDown, at: location, in: f); try mouse(.leftMouseUp, at: location, in: f)
    }
    private static func pixels(_ t: AppTestRunner, _ view: NSView, size: NSSize,
                               rectangles: [(CGRect, RGBA)]) throws {
        let reference = LiteralView(size: size, rectangles: rectangles)
        for scale in [1, 2] {
            let actual = try S.paint(view, scale: scale), expected = try S.paint(reference, scale: scale)
            t.equal(actual.width, Int(size.width) * scale); t.equal(actual.height, Int(size.height) * scale)
            t.equal(try S.bytes(actual), try S.bytes(expected), "independent native rectangle oracle at \(scale)x")
        }
    }

    static func run(_ t: AppTestRunner) {
        visibilityTests(t)
        colorTests(t)
        iconTests(t)
    }

    private static func visibilityTests(_ t: AppTestRunner) {
        t.suite("Desk: conditional preview: hidden keeps canvas space while pixels and mouse targets disappear") {
            for dark in [false, true] {
                let f = try fixture(t, S.visibilitySource, dark: dark), p = f.preview
                p.setVisible(true)
                t.equal(p.state, .ready)
                let frames = p.scene?.elements.map(\.frame), bounds = p.canvas.bounds
                let green = (CGRect(x: 0, y: 0, width: 20, height: 20), S.green)
                let red = (CGRect(x: 20, y: 0, width: 30, height: 20), S.red)
                let blue = (CGRect(x: 50, y: 0, width: 10, height: 20), S.blue)
                try pixels(t, p.canvas, size: NSSize(width: 60, height: 20), rectangles: [green, red, blue])
                try click(f, "switcher")
                t.equal(try S.element(p.scene, "target").visibility, .hiddenKeepsSpace)
                t.equal(p.scene?.elements.map(\.frame), frames); t.equal(p.canvas.bounds, bounds)
                t.check(p.scene?.hitMap.entries.contains(where: { $0.elementID?.name == "target" }) == false)
                try pixels(t, p.canvas, size: NSSize(width: 60, height: 20), rectangles: [green, blue])
                try click(f, "target"); t.equal(p.recordedEffects, [])
                try click(f, "switcher")
                try pixels(t, p.canvas, size: NSSize(width: 60, height: 20), rectangles: [green, red, blue])
                try click(f, "target"); t.equal(p.recordedEffects, [.copy("target")])
                t.equal(f.time.background.reports, [])
            }
        }

        t.suite("Desk: conditional preview: hiding then restoring a target retires its held press but ordinary ticks do not") {
            let source = """
            widget { Row(spacing: 0, align: .top) {
                Text("{time.now, format: "ss"}").size(40, 20).hidden(if: battery.charging).name(target)
                    .onClick { copy("primary") }.onRightClick { copy("secondary") }
                Rectangle().size(10, 20).fill(.white)
            } }
            """
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            let originalFrame = try S.element(p.scene, "target").frame
            t.equal(S.texts(p.scene), ["00"])
            for secondary in [false, true] {
                let location = try point(f, "target")
                let down: NSEvent.EventType = secondary ? .rightMouseDown : .leftMouseDown
                let up: NSEvent.EventType = secondary ? .rightMouseUp : .leftMouseUp
                try mouse(down, at: location, in: f)
                f.system.charging = true; p.notifyPowerChange()
                t.equal(S.texts(p.scene), [])
                t.equal(try S.element(p.scene, "target").visibility, .hiddenKeepsSpace)
                t.equal(try S.element(p.scene, "target").frame, originalFrame)
                let generation = p.scene?.generation, reads = f.system.batteryCalls, effects = p.recordedEffects
                f.time.advance(by: 3)
                t.equal(p.scene?.generation, generation); t.equal(f.system.batteryCalls, reads)
                f.system.charging = false; p.notifyPowerChange()
                t.equal(S.texts(p.scene), [secondary ? "07" : "03"])
                try mouse(up, at: location, in: f)
                t.equal(p.recordedEffects, effects, "the accepted hidden projection retired the old press")
                try mouse(down, at: location, in: f)
                f.time.advance(by: 1)
                try mouse(up, at: location, in: f)
                t.equal(p.recordedEffects, effects + [.copy(secondary ? "secondary" : "primary")],
                        "a clock repaint of the continuously visible target preserves the new gesture")
            }
            p.close(); let reads = f.system.batteryCalls
            p.notifyPowerChange(); f.time.advance(by: 3)
            t.equal(f.system.batteryCalls, reads)
        }

        t.suite("Desk: conditional preview: an empty hidden canvas keeps its controlling clock and restores static glass") {
            let source = """
            widget { Rectangle().size(40, 20).fill(.clear).background(.glass)
                .hidden(if: cpu.usage > 50%).name(panel) }
            """
            let f = try fixture(t, source), p = f.preview
            p.setVisible(true)
            t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
            let original = try S.bytes(S.paint(p.canvas)), bounds = p.canvas.bounds
            t.check(original.contains(where: { $0 != 0 }), "the static glass placeholder actually paints")
            f.system.cpu = 75; f.time.advance(by: 1)
            t.equal(p.state, .empty); t.check(p.canvas.isHidden)
            t.equal(try S.element(p.scene, "panel").visibility, .hiddenKeepsSpace)
            t.equal(p.scene?.drawingItems, []); t.equal(p.canvas.bounds, bounds)
            f.system.cpu = 25; f.time.advance(by: 1)
            t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
            t.equal(try S.bytes(S.paint(p.canvas)), original)
            p.setVisible(false); let reads = f.system.cpuCalls
            f.time.advance(by: 3); t.equal(f.system.cpuCalls, reads)
            p.setVisible(true); t.check(f.system.cpuCalls > reads)
        }
    }

    private static func colorTests(_ t: AppTestRunner) {
        t.suite("Desk: conditional preview: fill foreground and track conditions paint both branches without stale color") {
            let source = """
            widget { variable hot = false
                Row(spacing: 0, align: .top) {
                    Rectangle().size(20, 20).fill("#FFFFFF").name(switcher).onClick { hot = not hot }
                    Rectangle().size(20, 20).fill("#FF0000").fill("#0000FF", if: hot)
                    Progress(0.5).size(40, 20).color("#FF0000").color("#0000FF", if: hot)
                        .track("#00FF00").track("#FFFF00", if: hot)
                }
            }
            """
            for dark in [false, true] {
                let f = try fixture(t, source, dark: dark), p = f.preview
                p.setVisible(true)
                let frames = p.scene?.elements.map(\.frame)
                for (index, hot) in [false, true, false].enumerated() {
                    if index > 0 { try click(f, "switcher") }
                    let foreground = hot ? S.blue : S.red, track = hot ? S.yellow : S.green
                    try pixels(t, p.canvas, size: NSSize(width: 80, height: 20), rectangles: [
                        (CGRect(x: 0, y: 0, width: 20, height: 20), .white),
                        (CGRect(x: 20, y: 0, width: 20, height: 20), foreground),
                        (CGRect(x: 40, y: 0, width: 40, height: 20), track),
                        (CGRect(x: 40, y: 0, width: 20, height: 20), foreground)])
                    t.equal(p.scene?.elements.map(\.frame), frames)
                }
                t.equal(p.recordedEffects, [])
            }
        }
    }

    private static func iconTests(_ t: AppTestRunner) {
        t.suite("Desk: conditional preview: color-only icon preparation preserves old pixels and reuses the restored color") {
            let preparations = S.Preparation(), f = try fixture(t, S.iconSource(), prepare: preparations.submit), p = f.preview
            try preparations.succeed(0); f.time.runUntilIdle(); p.setVisible(true)
            let initial = try S.bytes(S.paint(p.canvas)), generation = p.scene?.generation
            try click(f, "signal")
            t.check(p.isPreparingIcons); t.equal(preparations.calls.count, 2)
            t.equal(p.scene?.generation, generation); t.equal(p.recordedEffects, [])
            t.equal(try S.bytes(S.paint(p.canvas)), initial)
            guard let old = try preparations.call(0).demands.first?.request,
                  let new = try preparations.call(1).demands.first?.request else { throw S.Failure.fixture }
            var expected = old; expected.style.color = S.blue
            t.equal(old.style.color, S.red); t.equal(new, expected)
            try preparations.succeed(1); f.time.runUntilIdle()
            t.equal(p.recordedEffects, [.copy("changed")])
            t.equal(S.icons(p.scene).first?.request.style.color, S.blue)
            t.check(try S.bytes(S.paint(p.canvas)) != initial)
            try click(f, "signal")
            t.check(!p.isPreparingIcons); t.equal(preparations.calls.count, 2)
            t.equal(p.recordedEffects, [.copy("changed"), .copy("changed")])
            t.equal(try S.bytes(S.paint(p.canvas)), initial)
            try preparations.succeed(1); f.time.runUntilIdle()
            t.equal(S.icons(p.scene).first?.request.style.color, S.red); t.equal(p.recordedEffects.count, 2)
        }

        t.suite("Desk: conditional preview: failed color candidates and replies after close never publish action effects") {
            let preparations = S.Preparation(), f = try fixture(t, S.iconSource(), prepare: preparations.submit), p = f.preview
            try preparations.succeed(0); f.time.runUntilIdle(); p.setVisible(true)
            let initial = try S.bytes(S.paint(p.canvas))
            try click(f, "signal"); try preparations.fail(1); f.time.runUntilIdle()
            if case .unavailable = p.state {} else { t.check(false, "failed color preparation reports unavailable") }
            t.check(p.scene == nil && p.canvas.isHidden); t.equal(p.recordedEffects, [])
            p.show(f.service.snapshot, readError: nil)
            if p.isPreparingIcons { try preparations.succeed(2); f.time.runUntilIdle() }
            t.equal(p.state, .ready); t.equal(S.icons(p.scene).first?.request.style.color, S.red)
            t.equal(try S.bytes(S.paint(p.canvas)), initial)
            try preparations.succeed(1); f.time.runUntilIdle()
            t.equal(S.icons(p.scene).first?.request.style.color, S.red); t.equal(p.recordedEffects, [])
            try click(f, "signal")
            let pendingIndex = preparations.calls.count - 1, pending = try preparations.call(pendingIndex)
            t.check(p.isPreparingIcons)
            p.close(); t.check(pending.ticket.isCancelled)
            try preparations.succeed(pendingIndex); f.time.runUntilIdle()
            t.equal(p.state, .closed); t.check(p.scene == nil && p.canvas.isHidden); t.equal(p.recordedEffects, [])
        }

        t.suite("Desk: conditional preview: pending color freezes visibility and deferred hidden state retains true icon measurement") {
            let preparations = S.Preparation()
            let f = try fixture(t, S.iconSource(condition: "cpu.usage > 50%"), prepare: preparations.submit), p = f.preview
            try preparations.succeed(0); f.time.runUntilIdle(); p.setVisible(true)
            let initial = try S.bytes(S.paint(p.canvas)), bounds = p.canvas.bounds
            var visibleAtCompletion = false
            p.onRecordedEffects = { _ in visibleAtCompletion = S.icons(p.scene).first?.request.style.color == S.blue }
            try click(f, "signal")
            let samples = f.system.cpuCalls
            f.system.cpu = 75; f.time.advance(by: 2)
            t.equal(f.system.cpuCalls, samples); t.equal(preparations.calls.count, 2)
            t.equal(try S.bytes(S.paint(p.canvas)), initial); t.equal(p.recordedEffects, [])
            try preparations.succeed(1); f.time.runUntilIdle()
            t.check(visibleAtCompletion, "effects observe the captured visible candidate before deferred input")
            t.equal(p.recordedEffects, [.copy("changed")])
            t.equal(p.state, .empty); t.check(p.canvas.isHidden)
            t.equal(try S.element(p.scene, "signal").visibility, .hiddenKeepsSpace)
            t.equal(p.canvas.bounds, bounds); t.equal(S.icons(p.scene), [])
            t.equal(f.system.cpuCalls, samples + 1); t.equal(preparations.calls.count, 2)
            f.system.cpu = 25; f.time.advance(by: 1)
            t.equal(p.state, .ready); t.equal(S.icons(p.scene).first?.request.style.color, S.blue)
            t.equal(preparations.calls.count, 2); t.equal(p.recordedEffects.count, 1)
            p.close(); let reads = f.system.cpuCalls
            f.time.advance(by: 3); t.equal(f.system.cpuCalls, reads)
        }
    }
}
