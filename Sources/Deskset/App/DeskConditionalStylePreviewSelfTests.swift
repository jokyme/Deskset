import AppKit
import DeskLanguage
import DesksetCore

/// Conditional style candidates use the same native drawing and resource transactions as explicit modifiers.
enum DeskConditionalStylePreviewSelfTests {
    private typealias S = DeskConditionalTestSupport
    private enum Failure: Error { case fixture(String) }
    private struct Fixture {
        let service: DeskLanguageService
        let preview: DeskProgramPreviewController
        let window: NSWindow
        let time: VirtualTimeExecutor
    }

    private static func fixture(_ t: AppTestRunner, _ source: String,
                                preparation: S.Preparation? = nil) throws -> Fixture {
        let file = DeskFileID(path: "ConditionalStyles.desk")
        let service = DeskLanguageService(openFile: file, files: [file: source])
        guard !service.snapshot.diagnostics.contains(where: { $0.severity == .error }) else {
            throw Failure.fixture("checker: \(service.snapshot.diagnostics)")
        }
        let result = Desk.compile(service.snapshot.checked, catalog: service.snapshot.options.catalog)
        guard result.program != nil else { throw Failure.fixture("compiler: \(result.issues)") }
        let time = try S.clock()
        let prepare: DeskProgramPreviewController.IconPreparation = preparation.map { $0.submit } ?? DeskIconResources.prepare
        let preview = DeskProgramPreviewController(clock: time.clock, executor: time,
            dateLocale: { Locale(identifier: "en_US") }, preferredLanguages: { ["en"] },
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
        ProgramOptionsInput(values: snapshot.values.values.merging(changes) { _, new in new })
    }
    @discardableResult
    private static func update(_ fixture: Fixture, _ changes: [String: ProgramOptionValue]) throws -> ProgramOptionsSnapshot {
        let snapshot = try fixture.preview.optionsSnapshot()
        var replies: [Result<ProgramOptionsSnapshot, Error>] = []
        fixture.preview.updateOptions(replacing(snapshot, changes), expectedRevision: snapshot.revision) { replies.append($0) }
        guard replies.count == 1 else { throw Failure.fixture("one option reply; got \(replies.count)") }
        return try replies[0].get()
    }
    private static func equalDrawing(_ t: AppTestRunner, _ styled: Fixture, _ explicit: Fixture) throws {
        t.equal(styled.preview.state, .ready); t.equal(explicit.preview.state, .ready)
        t.equal(styled.preview.scene, explicit.preview.scene,
                "identical element order and update history produce the complete same scene")
        t.equal(styled.preview.canvas.bounds, explicit.preview.canvas.bounds)
        for scale in [1, 2] {
            let actual = try S.paint(styled.preview.canvas, scale: scale)
            let reference = try S.paint(explicit.preview.canvas, scale: scale)
            t.equal(actual.width, reference.width); t.equal(actual.height, reference.height)
            let bytes = try S.bytes(actual)
            t.check(bytes.contains { $0 != 0 }, "the canvas paints actual content")
            t.equal(bytes, try S.bytes(reference), "conditional style and explicit modifier pixels at \(scale)x")
        }
    }
    private static func textColor(_ fixture: Fixture, _ name: String) throws -> RGBA {
        guard let color = try S.element(fixture.preview.scene, name).items.compactMap({ item -> RGBA? in
            if case .text(let draw) = item { return draw.style.color }; return nil
        }).first else { throw Failure.fixture("text color \(name)") }
        return color
    }

    static func run(_ t: AppTestRunner) {
        drawing(t)
        resources(t)
    }

    private static func drawing(_ t: AppTestRunner) {
        t.suite("Desk: conditional style preview: nested applications and repeated origins match explicit scene and pixels") {
            let options = """
            options {
                outer = Toggle("Outer"); middle = Toggle("Middle")
                leaf = Toggle("Leaf", default: true); concealed = Toggle("Concealed")
            }
            """
            let definitions = """
            style leaf {
                .color("#FF0000", if: options.leaf)
                .fill("#FF0000", if: options.leaf)
                .track("#FFFF00", if: options.leaf)
                .hidden(if: options.concealed)
            }
            style gate { .style(leaf, if: options.middle) }
            style red { .color("#FF0000") }
            style green { .color("#00FF00") }
            """
            let visibleColor = "options.outer and options.middle and options.leaf"
            let hidden = ".hidden(if: options.outer and options.middle and options.concealed)"
            func body(_ styled: Bool) -> String {
                let application = ".style(gate, if: options.outer)"
                let text = styled ? application : ".color(\"#FF0000\", if: \(visibleColor))" + hidden
                let block = styled ? application : ".fill(\"#FF0000\", if: \(visibleColor))" + hidden
                let meter = styled ? application :
                    ".color(\"#FF0000\", if: \(visibleColor)).track(\"#FFFF00\", if: \(visibleColor))" + hidden
                let repeated = styled
                    ? ".style(red, if: options.outer).style(green, if: true).style(red, if: options.middle)"
                    : ".color(\"#00FF00\", if: true).color(\"#FF0000\", if: options.middle)"
                return """
                widget { Row(spacing: 0, align: .top) {
                    Text("Color").font(16).size(120, 48).color("#0000FF")\(text).name(label)
                    Rectangle().size(24, 48).fill("#0000FF")\(block).name(block)
                    Gauge(25%, shape: .ring, thickness: 6pt).size(48).color("#0000FF").track("#00FF00")
                        \(meter).name(dial).onClick { copy("dial") }
                    Text("Repeat").font(16).size(120, 48).color("#0000FF")\(repeated).name(repeated)
                    Rectangle().size(4, 48).fill("#00FF00")
                } }
                """
            }
            let source = options + "\n" + definitions + "\n" + body(true)
            let styled = try fixture(t, source), explicit = try fixture(t, options + "\n" + body(false))
            let originalFrames = styled.preview.scene?.elements.map(\.frame)
            let originalIDs = styled.preview.scene?.elements.map(\.id)
            let initialPixels = try S.bytes(S.paint(styled.preview.canvas))
            try equalDrawing(t, styled, explicit)
            let cases = [(false, true, true, false), (true, false, true, false), (true, true, false, false),
                         (true, true, true, false), (true, true, true, true), (false, false, true, false)]
            for (outer, middle, leaf, concealed) in cases {
                let changes: [String: ProgramOptionValue] = [
                    "outer": .boolean(outer), "middle": .boolean(middle),
                    "leaf": .boolean(leaf), "concealed": .boolean(concealed)
                ]
                try update(styled, changes); try update(explicit, changes)
                let hides = outer && middle && concealed
                for name in ["label", "block", "dial"] {
                    t.equal(try S.element(styled.preview.scene, name).visibility, hides ? .hiddenKeepsSpace : .visible)
                }
                if !hides { t.equal(try textColor(styled, "label"), outer && middle && leaf ? S.red : S.blue) }
                t.equal(try textColor(styled, "repeated"), middle ? S.red : S.green,
                        "the last red application has its own condition despite sharing the first one's source origin")
                t.equal(styled.preview.scene?.elements.map(\.frame), originalFrames)
                t.equal(styled.preview.scene?.elements.map(\.id), originalIDs)
                t.equal(styled.preview.scene?.hitMap.entries.contains(where: { $0.elementID?.name == "dial" }), !hides)
                try equalDrawing(t, styled, explicit)
                if outer && middle { t.check((try S.bytes(S.paint(styled.preview.canvas))) != initialPixels) }
            }
            t.equal(try S.bytes(S.paint(styled.preview.canvas)), initialPixels, "restoring conditions restores every original pixel")
            t.equal(styled.preview.recordedEffects, [])
            t.equal(styled.time.pendingCount, 0)
            t.equal(styled.service.snapshot.text, source)
        }
    }

    private static func resources(_ t: AppTestRunner) {
        t.suite("Desk: conditional style preview: color resource rejection rolls back and source replacement rejects held replies") {
            let options = """
            options { blue = Toggle("Blue"); green = Toggle("Green") }
            """
            let source = options + "\n" + """
            style blue { .color("#0000FF") }
            style green { .color("#00FF00") }
            widget { Icon("wifi").font(20).size(48).color("#FF0000")
                .style(blue, if: options.blue).style(green, if: options.green).name(symbol) }
            """
            let reference = options + "\n" + """
            widget { Icon("wifi").font(20).size(48).color("#FF0000")
                .color("#0000FF", if: options.blue).color("#00FF00", if: options.green).name(symbol) }
            """
            let prepared = S.Preparation(), referencePrepared = S.Preparation()
            let styled = try fixture(t, source, preparation: prepared)
            let explicit = try fixture(t, reference, preparation: referencePrepared)
            t.check(styled.preview.isPreparingIcons && explicit.preview.isPreparingIcons)
            try prepared.succeed(0); styled.time.runUntilIdle()
            try referencePrepared.succeed(0); explicit.time.runUntilIdle()
            try equalDrawing(t, styled, explicit)
            let initial = try styled.preview.optionsSnapshot()
            let referenceInitial = try explicit.preview.optionsSnapshot()
            let oldScene = styled.preview.scene
            let redPixels = try S.bytes(S.paint(styled.preview.canvas))
            var replies: [Result<ProgramOptionsSnapshot, Error>] = []
            var referenceReplies: [Result<ProgramOptionsSnapshot, Error>] = []
            func requestBlue() {
                styled.preview.updateOptions(replacing(initial, ["blue": .boolean(true)]),
                    expectedRevision: initial.revision) { replies.append($0) }
                explicit.preview.updateOptions(replacing(referenceInitial, ["blue": .boolean(true)]),
                    expectedRevision: referenceInitial.revision) { referenceReplies.append($0) }
            }
            requestBlue()
            t.check(styled.preview.isPreparingIcons && explicit.preview.isPreparingIcons)
            t.equal(replies.count, 0); t.equal(referenceReplies.count, 0)
            t.equal(try styled.preview.optionsSnapshot(), initial)
            t.equal(styled.preview.scene, oldScene)
            t.equal(try S.bytes(S.paint(styled.preview.canvas)), redPixels)
            t.equal(try prepared.call(1).demands.map { $0.request.style.color }, [S.blue])
            try prepared.fail(1); styled.time.runUntilIdle()
            try referencePrepared.fail(1); explicit.time.runUntilIdle()
            t.equal(replies.count, 1); t.equal(referenceReplies.count, 1)
            if let result = replies.first, case .failure = result { t.check(true) }
            else { t.check(false, "the failed resource rejects the option transaction") }
            t.equal(try styled.preview.optionsSnapshot(), initial)
            t.equal(styled.preview.scene, oldScene)
            t.equal(try S.bytes(S.paint(styled.preview.canvas)), redPixels)
            t.equal(styled.preview.recordedEffects, [])
            try equalDrawing(t, styled, explicit)

            replies.removeAll(); referenceReplies.removeAll()
            requestBlue()
            try prepared.succeed(2); styled.time.runUntilIdle()
            try referencePrepared.succeed(2); explicit.time.runUntilIdle()
            t.equal(replies.count, 1); t.equal(referenceReplies.count, 1)
            guard let accepted = replies.first, let referenceAccepted = referenceReplies.first else { throw Failure.fixture("accepted blue") }
            t.equal(try accepted.get().revision, initial.revision + 1)
            t.equal(try referenceAccepted.get().revision, referenceInitial.revision + 1)
            t.equal(S.icons(styled.preview.scene).map { $0.request.style.color }, [S.blue])
            t.check((try S.bytes(S.paint(styled.preview.canvas))) != redPixels)
            try equalDrawing(t, styled, explicit)
            try update(styled, ["blue": .boolean(false)]); try update(explicit, ["blue": .boolean(false)])
            t.equal(prepared.calls.count, 3, "the accepted red request remains reusable after a failed and a successful candidate")
            t.equal(try S.bytes(S.paint(styled.preview.canvas)), redPixels)
            try equalDrawing(t, styled, explicit)

            let current = try styled.preview.optionsSnapshot(), referenceCurrent = try explicit.preview.optionsSnapshot()
            replies.removeAll(); referenceReplies.removeAll()
            styled.preview.updateOptions(replacing(current, ["green": .boolean(true)]),
                expectedRevision: current.revision) { replies.append($0) }
            explicit.preview.updateOptions(replacing(referenceCurrent, ["green": .boolean(true)]),
                expectedRevision: referenceCurrent.revision) { referenceReplies.append($0) }
            let held = try prepared.call(3), referenceHeld = try referencePrepared.call(3)
            t.equal(held.demands.map { $0.request.style.color }, [S.green])
            t.equal(replies.count, 0); t.equal(try styled.preview.optionsSnapshot(), current)
            let replacement = ##"widget { Rectangle().size(48).fill("#FFFF00") }"##
            styled.preview.show(styled.service.replaceText(replacement, version: 1), readError: nil)
            explicit.preview.show(explicit.service.replaceText(replacement, version: 1), readError: nil)
            t.check(held.ticket.isCancelled && referenceHeld.ticket.isCancelled)
            t.equal(replies.count, 1); t.equal(referenceReplies.count, 1)
            if let result = replies.first, case .failure(let error) = result {
                t.equal(error as? DeskProgramHost.Failure, .optionsCancelled)
            } else { t.check(false, "source replacement cancels the held option once") }
            let acceptedScene = styled.preview.scene
            try prepared.succeed(3); styled.time.runUntilIdle()
            try referencePrepared.succeed(3); explicit.time.runUntilIdle()
            t.equal(styled.preview.scene, acceptedScene)
            t.equal(replies.count, 1); t.equal(referenceReplies.count, 1)
            t.equal(S.icons(styled.preview.scene), [])
            try equalDrawing(t, styled, explicit)
            t.equal(styled.preview.recordedEffects, []); t.equal(styled.time.pendingCount, 0)
        }
    }
}
