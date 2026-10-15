import AppKit
import DeskLanguage
import DesksetCore
import DesksetDraw

/// The preview uses a literal placeholder for native glass; desktop material qualification is tested separately.
enum DeskConditionalBackgroundPreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String) }
    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
        let system: S.System
    }

    private static func fixture(_ t: AppTestRunner, _ source: String, dark: Bool = false) throws -> Fixture {
        let file = DeskFileID(path: "ConditionalBackgrounds.desk")
        let service = DeskLanguageService(openFile: file, files: [file: source])
        guard !service.snapshot.diagnostics.contains(where: { $0.severity == .error }) else {
            throw Failure.fixture("checker: \(service.snapshot.diagnostics)")
        }
        let result = Desk.compile(service.snapshot.checked, catalog: service.snapshot.options.catalog)
        guard result.program != nil else { throw Failure.fixture("compiler: \(result.issues)") }
        let time = try S.clock(), system = S.System()
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US") }, preferredLanguages: { ["en"] },
            system: system, presentsTooltips: false, presentsMenus: false, presentsOptions: false) {
                $0.file == file && $0.generation == service.snapshot.generation
                    && $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: preview)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
        preview.show(service.snapshot, readError: nil)
        preview.setVisible(true)
        return Fixture(service: service, preview: preview, window: window, time: time, system: system)
    }

    @discardableResult
    private static func update(_ f: Fixture, _ changes: [String: ProgramOptionValue]) throws -> ProgramOptionsSnapshot {
        let previous = try f.preview.optionsSnapshot()
        let input = ProgramOptionsInput(values: previous.values.values.merging(changes) { _, new in new })
        var replies: [Result<ProgramOptionsSnapshot, Error>] = []
        f.preview.updateOptions(input, expectedRevision: previous.revision) { replies.append($0) }
        guard replies.count == 1 else { throw Failure.fixture("one option reply; got \(replies.count)") }
        return try replies[0].get()
    }

    private static func body(_ background: String) -> String {
        """
        widget { Freeform {
            Rectangle().size(16, 12).position(x: 8, y: 6).fill("#0000FF").name(button)
                .voiceOver("Button").onClick { copy("button") }
        }.size(80, 40).name(panel)\(background) }
        """
    }

    private final class ReferenceView: NSView {
        let items: [DrawItem]
        let dark: Bool
        let context = DrawContext(fonts: AppFontResolver())
        override var isFlipped: Bool { true }
        init(items: [DrawItem], size: NSSize, dark: Bool) {
            self.items = items; self.dark = dark
            super.init(frame: NSRect(origin: .zero, size: size))
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let destination = NSGraphicsContext.current?.cgContext else { return }
            DesksetDraw.DrawExecutor.draw(items, in: destination, context: context, cycle: 1,
                              target: DrawTarget.capture(destination, glass: .placeholder(dark: dark)))
        }
    }

    private static func pixels(_ t: AppTestRunner, _ canvas: NSView, items: [DrawItem], dark: Bool) throws {
        let reference = ReferenceView(items: items, size: canvas.bounds.size, dark: dark)
        for scale in [1, 2] {
            let actual = try S.paint(canvas, scale: scale), expected = try S.paint(reference, scale: scale)
            t.equal(actual.width, expected.width); t.equal(actual.height, expected.height)
            let bytes = try S.bytes(actual)
            t.check(bytes.contains { $0 != 0 }, "the native cache contains the foreground or glass placeholder")
            t.equal(bytes, try S.bytes(expected), "literal background and foreground recipe at \(scale)x")
        }
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Desk: conditional background preview: options select one paint and independent tint with stable scene and pixels") {
            let source = """
            options { colored = Toggle("Colored"); glass = Toggle("Glass"); clear = Toggle("Clear") }
            style colored { .background("#FF0000") }
            style glassy { .background(.glass, tint: "#00FF0080") }
            style clear { .background(.clearGlass) }
            """ + "\n" + body(".style(colored, if: options.colored).style(glassy, if: options.glass).style(clear, if: options.clear)")
            let tint = RGBA(r: 0, g: 255, b: 0, a: 128)
            let cases: [(Bool, Bool, Bool, String, GlassStyle?, RGBA?)] = [
                (false, false, false, "", nil, nil),
                (true, false, false, ".background(\"#FF0000\")", nil, nil),
                (true, true, false, ".background(.glass, tint: \"#00FF0080\")", .regular, tint),
                (true, true, true, ".background(.clearGlass, tint: \"#00FF0080\")", .clear, tint),
                (false, false, true, ".background(.clearGlass)", .clear, nil),
                (false, false, false, "", nil, nil)
            ]
            let process = ProcessInfo.processInfo
            let temporary = process.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            let screenshots = temporary.appendingPathComponent("DeskConditionalBackground-\(process.processIdentifier)-\(UUID().uuidString)",
                                                               isDirectory: true)
            try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
            for dark in [false, true] {
                let f = try fixture(t, source, dark: dark), p = f.preview
                let explicit = try fixture(t, body(""), dark: dark)
                guard let initial = p.scene else { throw Failure.fixture("initial scene") }
                let initialOptions = try p.optionsSnapshot()
                let originalPixels = try S.bytes(S.paint(p.canvas))
                for (index, item) in cases.enumerated() {
                    let (colored, glass, clear, modifier, style, glassTint) = item
                    if index > 0 {
                        let options = try update(f, ["colored": .boolean(colored), "glass": .boolean(glass), "clear": .boolean(clear)])
                        t.equal(options.revision, initialOptions.revision + UInt64(index))
                        explicit.preview.show(explicit.service.replaceText(body(modifier), version: index), readError: nil)
                    }
                    guard let actual = p.scene, var expected = explicit.preview.scene else { throw Failure.fixture("selected scene") }
                    // The reference is a new static source; publication generations are intentionally different.
                    expected.generation = actual.generation
                    t.equal(actual, expected, "the complete selected scene equals the independent static background program")
                    t.equal(actual.elements.map(\.frame), initial.elements.map(\.frame))
                    t.equal(actual.elements.map(\.id), initial.elements.map(\.id))
                    t.equal(actual.hitMap, initial.hitMap, "no background is not a hidden element")
                    t.equal(actual.elements.map(\.accessibilityLabel), initial.elements.map(\.accessibilityLabel))
                    t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
                    let panel = try S.element(actual, "panel")
                    t.equal(panel.backing, style == nil ? .content : .native(.glass))
                    t.equal(panel.glass?.style, style); t.equal(panel.glass?.tint, glassTint)
                    var items: [DrawItem] = []
                    if let style {
                        items.append(.glass(GlassRegion(id: "reference", rect: SkinRect(width: 80, height: 40),
                                                        cornerRadius: 0, style: style, tint: glassTint)))
                    } else if colored { items.append(.fill(SkinRect(width: 80, height: 40), Paint(color: S.red))) }
                    items.append(.fill(SkinRect(x: 8, y: 6, width: 16, height: 12), Paint(color: S.blue)))
                    try pixels(t, p.canvas, items: items, dark: dark)
                    if index == 3 {
                        let bitmap = NSBitmapImageRep(cgImage: try S.paint(p.canvas, scale: 2))
                        guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                            throw Failure.fixture("offscreen preview PNG")
                        }
                        let output = screenshots.appendingPathComponent(dark ? "background-dark.png" : "background-light.png")
                        try png.write(to: output, options: .atomic)
                        print("    conditional background offscreen preview placeholder PNG: \(output.path)")
                    }
                }
                t.equal(try S.bytes(S.paint(p.canvas)), originalPixels, "returning to no background removes every old paint pixel")
                t.equal(p.recordedEffects, []); t.equal(f.time.pendingCount, 0)
                t.equal(f.service.snapshot.text, source, "preview options do not rewrite source")
            }
        }

        t.suite("Desk: conditional background preview: empty paint retains recovery clock and follows appearance without hiding its box") {
            let source = """
            widget { Column { }.size(40, 20).name(panel)
                .background(.glass, if: cpu.usage > 50%)
                .background(.clearGlass, if: system.dark) }
            """
            let f = try fixture(t, source), p = f.preview
            let box = try S.element(p.scene, "panel"), bounds = p.canvas.bounds
            t.equal(p.state, .empty); t.check(p.canvas.isHidden)
            t.equal(p.scene?.drawingItems, []); t.equal(box.visibility, .visible)
            t.check(f.time.pendingCount > 0, "an inactive background retains the CPU condition's recovery boundary")

            f.system.cpu = 75; f.time.advance(by: 1)
            t.equal(p.state, .ready); t.check(!p.canvas.isHidden)
            let regular = GlassRegion(id: "reference", rect: SkinRect(width: 40, height: 20), cornerRadius: 0)
            try pixels(t, p.canvas, items: [.glass(regular)], dark: false)
            f.system.cpu = 25; f.time.advance(by: 1)
            t.equal(p.state, .empty); t.equal(p.scene?.drawingItems, [])
            t.equal(try S.element(p.scene, "panel").frame, box.frame)
            t.equal(try S.element(p.scene, "panel").id, box.id)
            t.equal(try S.element(p.scene, "panel").visibility, .visible)

            f.window.appearance = NSAppearance(named: .darkAqua); p.refreshEnvironment()
            t.equal(p.state, .ready)
            let clear = GlassRegion(id: "reference", rect: regular.rect, cornerRadius: 0, style: .clear)
            try pixels(t, p.canvas, items: [.glass(clear)], dark: true)
            t.equal(f.time.pendingCount, 0, "the higher active appearance candidate does not read the lower CPU condition")
            f.window.appearance = NSAppearance(named: .aqua); p.refreshEnvironment()
            t.equal(p.state, .empty); t.check(f.time.pendingCount > 0)
            f.system.cpu = 75; f.time.advance(by: 1)
            t.equal(p.state, .ready)
            try pixels(t, p.canvas, items: [.glass(regular)], dark: false)
            t.equal(p.canvas.bounds, bounds)

            p.setVisible(false)
            let reads = f.system.cpuCalls
            f.time.advance(by: 3); t.equal(f.system.cpuCalls, reads)
            p.setVisible(true); t.check(f.system.cpuCalls > reads)
            p.close()
            let closedReads = f.system.cpuCalls
            f.time.advance(by: 3); p.refreshEnvironment()
            t.equal(f.system.cpuCalls, closedReads); t.equal(p.state, .closed)
            t.equal(p.recordedEffects, [])
        }
    }
}
