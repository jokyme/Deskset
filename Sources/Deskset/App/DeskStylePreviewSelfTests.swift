import AppKit
import DeskLanguage
import DesksetCore

enum DeskStylePreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String) }
    private final class Inputs { var languages = ["en"] }

    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
    }

    private static func fixture(_ t: AppTestRunner, _ source: String, package: String? = nil,
                                inputs: Inputs = Inputs(), preparation: S.Preparation? = nil) throws -> Fixture {
        let file = DeskFileID(path: "Styles.desk")
        var files = [file: source]
        if let package { files[DeskFileID(path: "package.desk")] = package }
        let service = DeskLanguageService(openFile: file, files: files)
        let compilation = Desk.compile(service.snapshot.checked, catalog: service.snapshot.options.catalog,
                                       package: service.snapshot.package)
        guard compilation.program != nil else {
            throw Failure.fixture("\(compilation.diagnostics) \(compilation.issues)")
        }
        let time = try S.clock()
        let prepare: DeskProgramPreviewController.IconPreparation = preparation.map { $0.submit } ?? DeskIconResources.prepare
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US") }, preferredLanguages: { inputs.languages },
            system: S.System(), prepareIcons: prepare, presentsTooltips: false, presentsMenus: false) {
                $0.file == file && $0.generation == service.snapshot.generation
                    && $0.tree.version == service.snapshot.tree.version && service.snapshot.isChecked
            }
        let window = NSWindow(contentViewController: preview)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        t.atSuiteEnd { preview.close(); window.close(); time.runUntilIdle() }
        preview.show(service.snapshot, readError: nil)
        preview.setVisible(true)
        return Fixture(service: service, preview: preview, window: window, time: time)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("Desk: style preview: nested repeated styles match explicit native pixels before and after a click") {
            let source = """
            style base { .font(20).color(.black).digits(.normal) }
            style card { .padding(4).style(base).size(160, 48).background("#FFE080").rounded(6) }
            style accent { .color(.red) }
            widget { variable count = 0
                Text("Count {count}").style(card).style(accent).style(card).name(label)
                    .onClick { count = count + 1 }
            }
            """
            let explicit = """
            widget { variable count = 0
                Text("Count {count}").font(20).color(.black).digits(.normal)
                    .padding(4).size(160, 48).background("#FFE080").rounded(6).name(label)
                    .onClick { count = count + 1 }
            }
            """
            let styled = try fixture(t, source), direct = try fixture(t, explicit)
            t.equal(styled.preview.state, .ready)
            t.equal(try S.element(styled.preview.scene, "label").frame, SkinRect(width: 160, height: 48))
            let oldPixels = try S.bytes(S.paint(styled.preview.canvas))
            for count in [0, 1] {
                t.equal(S.texts(styled.preview.scene), ["Count \(count)"])
                t.equal(try S.element(styled.preview.scene, "label").frame,
                        try S.element(direct.preview.scene, "label").frame)
                for scale in [1, 2] {
                    let actual = try S.bytes(S.paint(styled.preview.canvas, scale: scale))
                    t.check(actual.contains { $0 != 0 })
                    t.equal(actual, try S.bytes(S.paint(direct.preview.canvas, scale: scale)),
                            "style lowering preserves explicit native drawing at \(scale)x")
                }
                if count == 0 { try click(styled, "label"); try click(direct, "label") }
            }
            t.check(oldPixels != (try S.bytes(S.paint(styled.preview.canvas))), "the click changes actual glyph pixels")
            t.equal(styled.service.snapshot.text, source)
            t.equal(styled.preview.recordedEffects, [])
            t.equal(styled.time.pendingCount, 0, "constant style expansion creates no refresh timer")
        }

        t.suite("Desk: style preview: package definitions own overrides and mixed tooltip facets use their source translations") {
            let package = """
            style base { .color(.black).voiceOver("Shared label") }
            style card { .style(base).font(20).size(200, 48).tooltip("Shared hint", title: "Shared title") }
            translations { "zh-Hans" {
                "Shared label": "包内标签"
                "Shared hint": "包内提示"
                "Shared title": "包内标题"
            } }
            """
            for overridesBase in [false, true] {
                let source = """
                \(overridesBase ? "style base { .color(.black).voiceOver(\"Local label\") }" : "")
                translations { "zh-Hans" {
                    "Shared label": "组件标签"
                    "Shared title": "组件标题"
                    "Local label": "本地标签"
                    "Own hint": "本地提示"
                } }
                widget { Text("Source text").style(card).tooltip("Own hint").name(label) }
                """
                let inputs = Inputs(); inputs.languages = ["zh-CN"]
                let f = try fixture(t, source, package: package, inputs: inputs), p = f.preview
                t.equal(p.state, .ready)
                let location = try point(f, "label")
                t.equal(p.tooltipTarget(at: location)?.info, ToolTipInfo(text: "本地提示", title: "组件标题"))
                t.equal(try S.element(p.scene, "label").accessibilityLabel, overridesBase ? "本地标签" : "组件标签")
                t.equal(S.texts(p.scene), ["Source text"])
                let previous = p.tooltipTarget(at: location)
                inputs.languages = ["en"]
                p.refreshDateInput()
                t.equal(p.tooltipTarget(at: location)?.info, ToolTipInfo(text: "Own hint", title: "Shared title"))
                t.equal(try S.element(p.scene, "label").accessibilityLabel, overridesBase ? "Local label" : "Shared label")
                t.check(p.tooltipTarget(at: location)?.revision.session != previous?.revision.session)
                t.equal(f.service.snapshot.text, source)
                t.equal(f.service.snapshot.folder[DeskFileID(path: "package.desk")], package)
            }
        }

        t.suite("Desk: style preview: style fonts control icon fitting and source replacement cancels old resources") {
            let source = """
            style symbol { .font(12).size(48).color(.black) }
            widget { Icon("wifi").style(symbol).name(symbol) }
            """
            let preparation = S.Preparation(), f = try fixture(t, source, preparation: preparation), p = f.preview
            t.check(p.isPreparingIcons)
            t.equal(preparation.calls.count, 1)
            let replacement = source.replacingOccurrences(of: ".font(12)", with: ".font(24)")
            p.show(f.service.replaceText(replacement, version: 1), readError: nil)
            t.check(try preparation.call(0).ticket.isCancelled)
            t.equal(preparation.calls.count, 2)
            try preparation.succeed(0); f.time.runUntilIdle()
            t.check(p.isPreparingIcons && p.scene == nil, "a stale style's native resource cannot publish")
            try preparation.succeed(1); f.time.runUntilIdle()
            t.equal(p.state, .ready)
            t.equal(S.icons(p.scene).first?.request.style.fontSize, 18)
            t.equal(S.icons(p.scene).first?.contentFrame, SkinRect(x: 14, y: 14, width: 20, height: 20),
                    "an explicit style font preserves the prepared natural size inside a fixed box")
            let natural = try S.bytes(S.paint(p.canvas))

            let inherited = """
            style font { .font(24) }
            style symbol { .bold().size(48).color(.black) }
            widget { Column(spacing: 0) { Icon("wifi").style(symbol).name(symbol) }.style(font) }
            """
            p.show(f.service.replaceText(inherited, version: 2), readError: nil)
            t.check(p.isPreparingIcons)
            try preparation.succeed(2); f.time.runUntilIdle()
            t.equal(S.icons(p.scene).first?.request.style.fontSize, 18)
            t.equal(S.icons(p.scene).first?.request.style.fontWeight, 700)
            t.equal(S.icons(p.scene).first?.contentFrame, SkinRect(width: 48, height: 48),
                    "an inherited font and style bold do not disable fixed-box fitting")
            t.check(natural != (try S.bytes(S.paint(p.canvas))), "the controlled vector visibly expands to the box")

            let invalid = source.replacingOccurrences(of: ".font(12)", with: ".font(12, if: system.dark)")
            let snapshot = f.service.replaceText(invalid, version: 3)
            t.check(!snapshot.diagnostics.contains { $0.severity == .error })
            p.show(snapshot, readError: nil)
            guard case .unavailable(let message) = p.state else { throw Failure.fixture("unsupported conditional style") }
            t.check(!message.isEmpty && p.scene == nil && p.canvas.isHidden)
            t.equal(p.recordedEffects, [])
            t.equal(f.time.pendingCount, 0)
        }
    }

    private static func point(_ fixture: Fixture, _ name: String) throws -> NSPoint {
        let frame = try S.element(fixture.preview.scene, name).frame
        return NSPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    private static func click(_ fixture: Fixture, _ name: String) throws {
        let location = fixture.preview.canvas.convert(try point(fixture, name), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failure.fixture("mouse event")
            }
            if type == .leftMouseDown { fixture.preview.canvas.mouseDown(with: event) }
            else { fixture.preview.canvas.mouseUp(with: event) }
        }
    }
}
