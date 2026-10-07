import AppKit
import DeskLanguage
import DesksetCore

/// Compare ordinary dynamic styles with the already supported explicit modifier path on real preview canvases.
/// Controlled vector resources qualify Icon transactions; SF Symbol color and font fidelity have separate oracles.
enum DeskDynamicStylePreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String) }
    private final class Inputs { var languages = ["en"] }

    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
    }

    private static func fixture(_ t: AppTestRunner, _ source: String, inputs: Inputs = Inputs(),
                                preparation: S.Preparation? = nil) throws -> Fixture {
        let file = DeskFileID(path: "DynamicStyles.desk")
        let service = DeskLanguageService(openFile: file, files: [file: source])
        guard !service.snapshot.diagnostics.contains(where: { $0.severity == .error }) else {
            throw Failure.fixture("checker: \(service.snapshot.diagnostics)")
        }
        let compilation = Desk.compile(service.snapshot.checked, catalog: service.snapshot.options.catalog)
        guard compilation.program != nil else { throw Failure.fixture("compiler: \(compilation.issues)") }
        let time = try S.clock()
        let prepare: DeskProgramPreviewController.IconPreparation = preparation.map { $0.submit } ?? DeskIconResources.prepare
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US") }, preferredLanguages: { inputs.languages },
            system: S.System(), prepareIcons: prepare, presentsTooltips: false, presentsMenus: false,
            presentsOptions: false) {
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

    private static func replacing(_ snapshot: ProgramOptionsSnapshot,
                                  _ changes: [String: ProgramOptionValue]) -> ProgramOptionsInput {
        var values = snapshot.values.values
        for (name, value) in changes { values[name] = value }
        return ProgramOptionsInput(values: values)
    }

    @discardableResult
    private static func update(_ fixture: Fixture, _ changes: [String: ProgramOptionValue]) throws -> ProgramOptionsSnapshot {
        let snapshot = try fixture.preview.optionsSnapshot()
        var replies: [Result<ProgramOptionsSnapshot, Error>] = []
        fixture.preview.updateOptions(replacing(snapshot, changes), expectedRevision: snapshot.revision) { replies.append($0) }
        guard replies.count == 1 else { throw Failure.fixture("expected one synchronous option reply, got \(replies.count)") }
        return try replies[0].get()
    }

    private static func pixels(_ t: AppTestRunner, _ styled: Fixture, _ explicit: Fixture) throws {
        t.equal(styled.preview.state, .ready)
        t.equal(explicit.preview.state, .ready)
        t.equal(styled.preview.canvas.bounds, explicit.preview.canvas.bounds)
        for scale in [1, 2] {
            let actual = try S.paint(styled.preview.canvas, scale: scale)
            let reference = try S.paint(explicit.preview.canvas, scale: scale)
            t.equal(actual.width, reference.width); t.equal(actual.height, reference.height)
            let data = try S.bytes(actual)
            t.check(data.contains { $0 != 0 }, "the fixture draws actual content")
            t.equal(data, try S.bytes(reference), "ordinary style and explicit modifiers have equal native pixels at \(scale)x")
        }
    }

    private static func text(_ fixture: Fixture, _ name: String) throws -> TextDraw {
        let element = try S.element(fixture.preview.scene, name)
        guard let draw = element.items.compactMap({ item -> TextDraw? in
            if case .text(let value) = item { return value }; return nil
        }).first else { throw Failure.fixture("text recipe for \(name)") }
        return draw
    }

    private static func point(_ fixture: Fixture, _ name: String) throws -> NSPoint {
        let frame = try S.element(fixture.preview.scene, name).frame
        return NSPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    static func run(_ t: AppTestRunner) {
        fonts(t)
        paints(t)
        labels(t)
        icons(t)
    }

    private static func fonts(_ t: AppTestRunner) {
        t.suite("Desk: dynamic style preview: option font and conditional text color inherit without replacing own facets") {
            let options = """
            options {
                size = Slider("Size", min: 0pt, max: 40pt, default: 16pt)
                hot = Toggle("Hot")
            }
            """
            let modifiers = ".font(options.size).color(\"#FF0000\").color(\"#0000FF\", if: options.hot)"
            let body = """
            Column(spacing: 0, align: .left) {
                Text("Inherited").size(210, 52).name(inherited)
                Text("Own").font(12).color("#00AA00").size(210, 28).name(own)
            }
            """
            let source = options + "\nstyle parent { \(modifiers) }\nwidget { \(body).style(parent) }"
            let direct = options + "\nwidget { \(body)\(modifiers) }"
            let styled = try fixture(t, source), explicit = try fixture(t, direct)
            let frames = styled.preview.scene?.elements.map(\.frame)
            let firstPixels = try S.bytes(S.paint(styled.preview.canvas))
            for (size, hot) in [(16.0, false), (28.0, true), (12.0, false)] {
                if size != 16 {
                    let changes: [String: ProgramOptionValue] = ["size": .number(.init(size, dimension: .length)),
                                                                "hot": .boolean(hot)]
                    try update(styled, changes); try update(explicit, changes)
                }
                t.equal(try text(styled, "inherited").style.fontSize, size * 0.75)
                t.equal(try text(styled, "inherited").style.color, hot ? S.blue : S.red)
                t.equal(try text(styled, "own").style.fontSize, 9)
                t.equal(try text(styled, "own").style.color, RGBA(r: 0, g: 170, b: 0, a: 255))
                t.equal(styled.preview.scene?.elements.map(\.frame), frames, "fixed layout remains unchanged as glyphs grow")
                try pixels(t, styled, explicit)
                if size == 28 {
                    t.check(firstPixels != (try S.bytes(S.paint(styled.preview.canvas))), "option changes reach native glyph pixels")
                }
            }
            t.equal(try styled.preview.optionsSnapshot().revision, 2)
            t.equal(styled.service.snapshot.text, source)
            t.equal(styled.preview.recordedEffects, [])
            t.equal(styled.time.pendingCount, 0, "option-only styles have no periodic clock")
        }
    }

    private static func paints(_ t: AppTestRunner) {
        t.suite("Desk: dynamic style preview: conditional fill gauge color track and hidden match explicit drawing") {
            let options = """
            options { hot = Toggle("Hot"); concealed = Toggle("Concealed") }
            """
            let fill = ".fill(\"#FF0000\").fill(\"#0000FF\", if: options.hot)"
            let meter = ".color(\"#0000FF\").color(\"#FF0000\", if: options.hot).track(\"#00FF00\").track(\"#FFFF00\", if: options.hot)"
            let hidden = ".hidden(if: options.concealed)"
            func body(_ styled: Bool) -> String {
                """
                widget { Row(spacing: 0, align: .top) {
                    Rectangle().size(32, 64)\(styled ? ".style(paint)" : fill).name(block)
                    Gauge(0.25, shape: .ring, thickness: 8pt).size(64)
                        \(styled ? ".style(meter).style(visibility)" : meter + hidden).name(dial)
                        .onClick { copy("dial") }
                    Rectangle().size(8, 64).fill("#00FF00").name(tail)
                } }
                """
            }
            let source = options + "\nstyle paint { \(fill) }\nstyle meter { \(meter) }\nstyle visibility { \(hidden) }\n" + body(true)
            let styled = try fixture(t, source), explicit = try fixture(t, options + "\n" + body(false))
            let frames = styled.preview.scene?.elements.map(\.frame), bounds = styled.preview.canvas.bounds
            let initial = try S.bytes(S.paint(styled.preview.canvas))
            try pixels(t, styled, explicit)
            for (hot, concealed) in [(true, false), (true, true), (false, false)] {
                let changes: [String: ProgramOptionValue] = ["hot": .boolean(hot), "concealed": .boolean(concealed)]
                try update(styled, changes); try update(explicit, changes)
                t.equal(try S.element(styled.preview.scene, "dial").visibility, concealed ? .hiddenKeepsSpace : .visible)
                t.equal(styled.preview.scene?.elements.map(\.frame), frames)
                t.equal(styled.preview.canvas.bounds, bounds)
                t.equal(styled.preview.scene?.hitMap.entries.contains(where: { $0.elementID?.name == "dial" }), !concealed)
                try pixels(t, styled, explicit)
                if hot { t.check(initial != (try S.bytes(S.paint(styled.preview.canvas))), "paint and visibility affect real pixels") }
            }
            t.equal(try S.bytes(S.paint(styled.preview.canvas)), initial, "restoring options recovers the original colors and ring")
            t.equal(styled.preview.recordedEffects, [])
            t.equal(styled.time.pendingCount, 0)
        }
    }

    private static func labels(_ t: AppTestRunner) {
        t.suite("Desk: dynamic style preview: option tooltip title and VoiceOver freeze with visibility and language") {
            let head = """
            options { title = Input("Title", default: "Start"); concealed = Toggle("Concealed") }
            translations { "zh-Hans" {
                "Hint {options.title}": "提示 {options.title}"
                "Title {options.title}": "标题 {options.title}"
                "Read {options.title}": "读取 {options.title}"
                "Own {options.title}": "自有 {options.title}"
            } }
            """
            let metadata = ".tooltip(\"Hint {options.title}\", title: \"Title {options.title}\").voiceOver(\"Read {options.title}\").hidden(if: options.concealed)"
            func body(_ modifiers: String, second: String) -> String {
                """
                widget { Column(spacing: 0, align: .left) {
                    Text("First").size(180, 36)\(modifiers).name(first).onClick { copy("first") }
                    Text("Second").size(180, 36)\(second).name(second)
                        .onClick { copy("second") }
                    Rectangle().size(180, 2).fill("#00FF00")
                } }
                """
            }
            let source = head + "\nstyle accessible { \(metadata) }\n"
                + body(".style(accessible)", second: ".style(accessible).tooltip(\"Own {options.title}\")")
            let inputs = Inputs()
            let styled = try fixture(t, source, inputs: inputs)
            // The explicit reference writes the final text/title once; duplicate own tooltip calls are invalid.
            let ownMetadata = metadata.replacingOccurrences(of: "Hint {options.title}", with: "Own {options.title}")
            let explicit = try fixture(t, head + "\n" + body(metadata, second: ownMetadata), inputs: inputs)
            let first = try point(styled, "first"), second = try point(styled, "second")
            let frames = styled.preview.scene?.elements.map(\.frame)
            for title in ["Start", "Changed"] {
                if title == "Changed" {
                    try update(styled, ["title": .string(title)]); try update(explicit, ["title": .string(title)])
                }
                t.equal(styled.preview.tooltipTarget(at: first)?.info, ToolTipInfo(text: "Hint \(title)", title: "Title \(title)"))
                t.equal(styled.preview.tooltipTarget(at: second)?.info, ToolTipInfo(text: "Own \(title)", title: "Title \(title)"),
                        "the own tooltip text keeps the independently resolved style title")
                t.equal(try S.element(styled.preview.scene, "first").accessibilityLabel, "Read \(title)")
                t.equal(try S.element(styled.preview.scene, "second").accessibilityLabel, "Read \(title)")
                try pixels(t, styled, explicit)
            }
            try update(styled, ["concealed": .boolean(true)]); try update(explicit, ["concealed": .boolean(true)])
            t.equal(styled.preview.scene?.elements.map(\.frame), frames)
            t.check(styled.preview.tooltipTarget(at: first) == nil && styled.preview.tooltipTarget(at: second) == nil)
            for name in ["first", "second"] {
                t.equal(try S.element(styled.preview.scene, name).visibility, .hiddenKeepsSpace)
                t.check(styled.preview.scene?.hitMap.entries.contains(where: { $0.elementID?.name == name }) == false)
            }
            try pixels(t, styled, explicit)
            try update(styled, ["concealed": .boolean(false)]); try update(explicit, ["concealed": .boolean(false)])
            let oldTarget = styled.preview.tooltipTarget(at: first)
            inputs.languages = ["zh-CN"]
            styled.preview.refreshDateInput(); explicit.preview.refreshDateInput()
            t.equal(try styled.preview.optionsSnapshot().values.values["title"], .string("Changed"))
            t.equal(styled.preview.tooltipTarget(at: first)?.info, ToolTipInfo(text: "提示 Changed", title: "标题 Changed"))
            t.equal(styled.preview.tooltipTarget(at: second)?.info, ToolTipInfo(text: "自有 Changed", title: "标题 Changed"))
            t.equal(try S.element(styled.preview.scene, "first").accessibilityLabel, "读取 Changed")
            t.check(styled.preview.tooltipTarget(at: first)?.revision.session != oldTarget?.revision.session)
            try pixels(t, styled, explicit)
            t.equal(styled.service.snapshot.text, source)
            t.equal(styled.preview.recordedEffects, [])
            t.equal(styled.time.pendingCount, 0)
        }
    }

    private static func icons(_ t: AppTestRunner) {
        t.suite("Desk: dynamic style preview: icon font ownership and pending option resources preserve accepted frames") {
            let options = """
            options {
                size = Slider("Size", min: 0pt, max: 40pt, default: 12pt)
                blue = Toggle("Blue")
            }
            """
            let font = ".font(options.size)"
            let color = ".color(\"#FF0000\").color(\"#0000FF\", if: options.blue)"
            func body(_ styled: Bool) -> String {
                """
                widget { Row(spacing: 0, align: .top) {
                    Icon("wifi").size(48)\(styled ? ".style(symbol)" : font + color).name(own)
                    Icon("wifi").size(48)\(styled ? ".style(weight)" : ".bold()" + color).name(inherited)
                }\(styled ? ".style(parent)" : font) }
                """
            }
            let source = options + "\nstyle parent { \(font) }\nstyle symbol { \(font)\(color) }\nstyle weight { .bold()\(color) }\n" + body(true)
            let prepared = S.Preparation(), referencePrepared = S.Preparation()
            let styled = try fixture(t, source, preparation: prepared)
            let explicit = try fixture(t, options + "\n" + body(false), preparation: referencePrepared)
            t.check(styled.preview.isPreparingIcons && explicit.preview.isPreparingIcons)
            try prepared.succeed(0); styled.time.runUntilIdle()
            try referencePrepared.succeed(0); explicit.time.runUntilIdle()
            t.equal(S.icons(styled.preview.scene).map(\.request.style.fontSize), [9, 9])
            t.equal(S.icons(styled.preview.scene).map(\.request.style.fontWeight), [400, 700])
            t.equal(S.icons(styled.preview.scene).map(\.contentFrame), [SkinRect(x: 14, y: 14, width: 20, height: 20),
                                                                        SkinRect(x: 48, y: 0, width: 48, height: 48)],
                    "style font is explicit; inherited font plus bold still fits the fixed box")
            try pixels(t, styled, explicit)
            let initial = try S.bytes(S.paint(styled.preview.canvas)), generation = styled.preview.scene?.generation
            let old = try styled.preview.optionsSnapshot(), referenceOld = try explicit.preview.optionsSnapshot()
            let changes: [String: ProgramOptionValue] = ["size": .number(.init(24, dimension: .length)), "blue": .boolean(true)]
            var replies: [Result<ProgramOptionsSnapshot, Error>] = []
            var referenceReplies: [Result<ProgramOptionsSnapshot, Error>] = []
            styled.preview.updateOptions(replacing(old, changes), expectedRevision: old.revision) { replies.append($0) }
            explicit.preview.updateOptions(replacing(referenceOld, changes), expectedRevision: referenceOld.revision) { referenceReplies.append($0) }
            t.check(styled.preview.isPreparingIcons && explicit.preview.isPreparingIcons)
            t.equal(replies.count, 0); t.equal(referenceReplies.count, 0)
            t.equal(styled.preview.scene?.generation, generation)
            t.equal(try styled.preview.optionsSnapshot(), old)
            t.equal(try S.bytes(S.paint(styled.preview.canvas)), initial)
            let demands = try prepared.call(1).demands
            t.equal(demands.count, 2)
            t.check(demands.allSatisfy { $0.request.style.fontSize == 18 && $0.request.style.color == S.blue })
            try prepared.succeed(1); styled.time.runUntilIdle()
            try referencePrepared.succeed(1); explicit.time.runUntilIdle()
            t.equal(replies.count, 1); t.equal(referenceReplies.count, 1)
            guard let result = replies.first, let referenceResult = referenceReplies.first else { throw Failure.fixture("prepared option reply") }
            t.equal(try result.get().revision, old.revision + 1)
            t.equal(try referenceResult.get().revision, referenceOld.revision + 1)
            t.equal(S.icons(styled.preview.scene).map(\.request.style.fontSize), [18, 18])
            t.equal(S.icons(styled.preview.scene).map(\.contentFrame.width), [20, 48])
            try pixels(t, styled, explicit)
            t.check(initial != (try S.bytes(S.paint(styled.preview.canvas))), "the newly accepted request changes actual colored pixels")
            let accepted = styled.preview.scene?.generation
            try prepared.succeed(1); styled.time.runUntilIdle()
            t.equal(replies.count, 1); t.equal(styled.preview.scene?.generation, accepted)

            let current = try styled.preview.optionsSnapshot()
            styled.preview.updateOptions(replacing(current, ["size": .number(.init(32, dimension: .length))]),
                                         expectedRevision: current.revision) { replies.append($0) }
            t.check(styled.preview.isPreparingIcons)
            t.equal(replies.count, 1)
            let held = try prepared.call(2)
            let replacement = "widget { Rectangle().size(96, 48).fill(\"#FFFF00\") }"
            styled.preview.show(styled.service.replaceText(replacement, version: 1), readError: nil)
            explicit.preview.show(explicit.service.replaceText(replacement, version: 1), readError: nil)
            t.check(held.ticket.isCancelled)
            t.equal(replies.count, 2)
            if let cancelled = replies.last, case .failure(let error) = cancelled {
                t.equal(error as? DeskProgramHost.Failure, .optionsCancelled)
            } else { t.check(false, "source replacement cancels the held option completion once") }
            let replacementGeneration = styled.preview.scene?.generation
            try prepared.succeed(2); styled.time.runUntilIdle()
            t.equal(styled.preview.scene?.generation, replacementGeneration)
            t.equal(replies.count, 2)
            t.equal(S.icons(styled.preview.scene), [])
            try pixels(t, styled, explicit)
            t.equal(styled.preview.recordedEffects, [])
            t.equal(styled.time.pendingCount, 0)
        }
    }
}
