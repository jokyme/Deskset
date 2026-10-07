import AppKit
import DesksetCore

enum DeskProgramOptionsPanelSelfTests {
    private typealias Panel = DeskProgramOptionsPanelController
    private enum Failure: Error { case fixture(String) }

    static func run(_ t: AppTestRunner) {
        t.suite("App: Desk options panel: complete schema native controls translated labels and hidden help") {
            let panel = fixture(t), lease = UUID()
            let extra = (0..<14).map { option("extra\($0)", "Extra \($0)", .toggle, .boolean(false)) }
            let snapshot = snapshot(items: [
                .section(title: "显示方式", items: options()),
                .section(title: "All options", items: extra),
                .section(title: "Invisible section", items: [option("onlyhidden", "Hidden", .toggle, .boolean(true), hidden: true)])
            ])
            panel.apply(snapshot, lease: lease, isPreview: true, title: "Battery · Small")
            panel.present()
            t.equal(panel.window?.title, "Battery · Small")
            t.equal(panel.pageView.page?.subtitle, StudioText[.deskOptionsPreview])
            t.equal(panel.pageView.page?.sections.map(\.title), ["显示方式", "All options"])
            t.equal(panel.pageView.page?.controlCount, 20, "the full panel is not capped at twelve inspector controls")
            t.check(panel.pageView.itemView("extra13") != nil)
            t.check(panel.pageView.itemView("hidden") == nil && panel.pageView.itemView("hidden:help") == nil)
            t.check(panel.pageView.itemView("note:help") != nil)
            let toggle = try row(panel, "enabled"), input = try row(panel, "note")
            t.check(toggle.controlView is NSSwitch); t.equal(toggle.label.stringValue, "显示电量")
            t.check(input.controlView is StudioNumberBox && input.scrubArea.isHidden)
            t.equal(input.numberBox?.field.placeholderString, "写下备注")
            t.equal(input.numberBox?.field.accessibilityLabel(), "备注")
            t.check(try row(panel, "level").controlView is StudioNumericSlider)
            t.check(try row(panel, "days").controlView is StudioNumericStepper)
            t.check(try row(panel, "mode").controlView is NSSegmentedControl)
            t.check(try row(panel, "city").controlView is NSPopUpButton)
            t.check(panel.window?.isVisible == false)
            t.check(panel.scrollView.documentView === panel.pageView && panel.scrollView.hasVerticalScroller)
            panel.apply(snapshot, lease: lease, isPreview: true)
            t.equal(panel.window?.title, "Battery · Small", "a normal reply does not reset the instance title")
            guard let window = panel.window, let content = window.contentView else { throw Failure.fixture("snapshot content") }
            let appearance = window.appearance
            defer { window.appearance = appearance }
            let process = ProcessInfo.processInfo
            let temporary: URL
            if let path = process.environment["TMPDIR"], !path.isEmpty {
                temporary = URL(fileURLWithPath: path, isDirectory: true)
            } else { temporary = FileManager.default.temporaryDirectory }
            let screenshots = temporary.appendingPathComponent("DeskOptionsPanel-\(process.processIdentifier)-\(UUID().uuidString)",
                                                               isDirectory: true)
            try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearanceName)
                var raw: Data?
                content.effectiveAppearance.performAsCurrentDrawingAppearance { raw = UISnapshot.png(of: content) }
                guard let raw, !raw.isEmpty else { throw Failure.fixture("\(name) raw PNG") }
                let rawOutput = screenshots.appendingPathComponent("desk-options-\(name)-raw.png")
                try raw.write(to: rawOutput, options: .atomic)
                print("    options panel raw offscreen PNG: \(rawOutput.path)")
                guard let composed = compositeWindowBackground(raw, content: content),
                      let png = composed.representation(using: .png, properties: [:]), !png.isEmpty else {
                    throw Failure.fixture("\(name) composed PNG")
                }
                t.equal(composed.colorAt(x: 0, y: 0)?.alphaComponent, 1, "the window background is opaque")
                let output = screenshots.appendingPathComponent("desk-options-\(name).png")
                try png.write(to: output, options: .atomic)
                print("    options panel offscreen PNG: \(output.path)")
            }
            t.check(!window.isVisible)
        }

        t.suite("App: Desk options panel: native edits preserve types units local cases and reject arithmetic") {
            let panel = fixture(t), lease = UUID()
            panel.apply(snapshot(), lease: lease)
            var changes: [Panel.Change] = []
            panel.onChange = { changes.append($0) }
            guard let toggle = try row(panel, "enabled").controlView as? NSSwitch,
                  let input = try row(panel, "note").numberBox,
                  let slider = try row(panel, "level").controlView as? StudioNumericSlider,
                  let stepper = try row(panel, "days").controlView as? StudioNumericStepper,
                  let segment = try row(panel, "mode").controlView as? NSSegmentedControl,
                  let popup = try row(panel, "city").controlView as? NSPopUpButton else { throw Failure.fixture("controls") }
            toggle.state = .on; t.check(perform(toggle)); t.equal(changes.last?.value, .boolean(true))
            let literal = "1 + 2 {options.level}"
            input.type(literal); t.equal(changes.last?.value, .string(literal))
            input.type(""); t.equal(changes.last?.value, .string(""))
            let beforeArrow = changes.count
            input.pressArrow(up: true); t.equal(changes.count, beforeArrow, "Input has no numeric arrow behavior")
            slider.slider.doubleValue = 0.73; t.check(perform(slider.slider))
            t.equal(changes.last?.value, number(70, .percent)); t.check(changes.last?.finished == true)
            t.equal(slider.valueLabel.stringValue, "70 %")
            t.close(stepper.stepper.increment, 0.5)
            stepper.stepper.doubleValue = 4.5; t.check(perform(stepper.stepper))
            t.equal(changes.last?.value, number(4.5, .duration))
            stepper.numberBox.pressArrow(up: true)
            t.equal(changes.last?.value, number(5, .duration))
            for invalid in ["1+2", "nan", "inf", "-1", "11", ""] {
                let count = changes.count
                stepper.numberBox.type(invalid)
                t.equal(changes.count, count, "invalid numeric input: \(invalid)")
                t.equal(panel.feedbackLabel.stringValue, StudioText[.deskOptionsInvalidNumber])
            }
            stepper.numberBox.type(" 2.25 ")
            t.equal(changes.last?.value, number(2.25, .duration), "typed values need not lie on the button step grid")
            t.check(panel.feedbackLabel.isHidden)
            segment.selectedSegment = 2; t.check(perform(segment))
            t.equal(changes.last?.value, .localCase(option: "mode", name: "compact"))
            popup.selectItem(at: 3); t.check(perform(popup)); t.equal(changes.last?.value, .string("D"))
            t.check(changes.allSatisfy { $0.lease == lease && $0.revision == 1 })
            t.equal(Set(changes.map(\.id)).count, changes.count)

            let bytes = option("bytes", "Bytes", .stepper(min: numeric(0, .bytes, 1024), max: numeric(8192, .bytes, 1024),
                step: numeric(1024, .bytes, 1024)), number(1024, .bytes, 1024))
            panel.apply(snapshot(revision: 2, items: [bytes]), lease: lease)
            try row(panel, "bytes").numberBox?.pressArrow(up: true)
            t.equal(changes.last?.value, number(2048, .bytes, 1024), "bytes retain their chosen display base")
        }

        t.suite("App: Desk options panel: stable rows field editor selection popup identity and stale native targets") {
            let panel = fixture(t), lease = UUID()
            panel.apply(snapshot(), lease: lease)
            let inputRow = try row(panel, "note"), toggleRow = try row(panel, "enabled")
            guard let input = inputRow.numberBox, let popup = try row(panel, "city").controlView as? NSPopUpButton,
                  let window = panel.window else { throw Failure.fixture("editor") }
            let menu = popup.menu, made = panel.pageView.viewsMade
            t.check(window.makeFirstResponder(input.field))
            guard let editor = input.field.currentEditor() as? NSTextView else { throw Failure.fixture("field editor") }
            editor.string = "uncommitted text"
            editor.setSelectedRange(NSRange(location: 3, length: 4))
            panel.apply(snapshot(revision: 2, replacements: ["enabled": .boolean(true)]), lease: lease)
            t.check(panel.pageView.itemView("note") === inputRow && panel.pageView.itemView("enabled") === toggleRow)
            t.equal(panel.pageView.viewsMade, made)
            t.check(input.field.currentEditor() === editor)
            t.equal(editor.string, "uncommitted text"); t.equal(editor.selectedRange(), NSRange(location: 3, length: 4))
            t.check(popup.menu === menu, "an unrelated reply keeps the menu AppKit is tracking")
            var changes: [Panel.Change] = []
            panel.onChange = { changes.append($0) }
            window.makeFirstResponder(nil)
            t.equal(changes.last?.value, .string("uncommitted text"))
            panel.apply(snapshot(revision: 1, replacements: ["enabled": .boolean(false)]), lease: lease)
            t.equal(panel.snapshot?.revision, 2)
            t.check((toggleRow.controlView as? NSSwitch)?.state == .on)
            let hidden = snapshot(revision: 3, hiddenNames: ["enabled"])
            panel.apply(hidden, lease: lease)
            let count = changes.count
            toggleRow.onEvent?(.toggle(false)); t.equal(changes.count, count)
            panel.apply(snapshot(revision: 4), lease: lease)
            t.check(panel.pageView.itemView("enabled") !== toggleRow)
            toggleRow.onEvent?(.toggle(false)); t.equal(changes.count, count)
            let oldInput = input
            panel.apply(snapshot(), lease: UUID(), title: "Replacement")
            oldInput.type("stale"); t.equal(changes.count, count, "an old source's field cannot edit the replacement")
            t.check(panel.pageView.itemView("note") !== inputRow)
        }

        t.suite("App: Desk options panel: pending drafts outlive older replies and slider tracking finishes once") {
            let panel = fixture(t), lease = UUID()
            panel.apply(snapshot(), lease: lease)
            var changes: [Panel.Change] = []
            panel.onChange = { changes.append($0) }
            guard let slider = try row(panel, "level").controlView as? StudioNumericSlider,
                  let input = try row(panel, "note").numberBox else { throw Failure.fixture("pending controls") }
            input.type("first")
            guard let first = changes.last else { throw Failure.fixture("first change") }
            input.type("latest")
            guard let latest = changes.last else { throw Failure.fixture("latest change") }
            let accepted = snapshot(revision: 2, replacements: ["note": .string("first")])
            panel.apply(accepted, lease: lease)
            panel.complete(first.id, snapshot: accepted, message: "An older edit failed")
            t.equal(input.field.stringValue, "latest")
            t.check(panel.feedbackLabel.isHidden, "an old completion cannot replace newer feedback")
            panel.complete(latest.id, snapshot: snapshot(revision: 3, replacements: ["note": .string("latest")]))
            t.equal(input.field.stringValue, "latest")
            slider.slider.beginTrackingValue()
            slider.slider.doubleValue = 0.4; t.check(perform(slider.slider))
            t.equal(changes.last?.value, number(40, .percent)); t.check(changes.last?.finished == false)
            slider.slider.doubleValue = 0.8; t.check(perform(slider.slider))
            panel.apply(snapshot(revision: 4, replacements: ["level": number(40, .percent)]), lease: lease)
            t.close(slider.slider.doubleValue, 0.8)
            t.equal(slider.valueLabel.stringValue, "80 %")
            let count = changes.count
            slider.slider.finishTrackingValue()
            t.equal(changes.count, count + 1); t.check(changes.last?.finished == true)
            t.equal(changes.last?.value, number(80, .percent))
            slider.slider.finishTrackingValue(); t.equal(changes.count, count + 1)
            guard let finished = changes.last else { throw Failure.fixture("slider release") }
            panel.complete(finished.id, snapshot: snapshot(revision: 5, replacements: ["level": number(40, .percent)]),
                           message: StudioText[.deskOptionsChangeFailed])
            t.equal(slider.valueLabel.stringValue, "40 %")
            t.equal(panel.feedbackLabel.stringValue, StudioText[.deskOptionsChangeFailed])
        }

        t.suite("App: Desk options panel: finite extreme ranges off-grid values and invalid numbers stay bounded") {
            let panel = fixture(t), lease = UUID(), greatest = Double.greatestFiniteMagnitude
            let huge: ProgramResolvedOptionNode = option("huge", "Range", .slider(min: numeric(-greatest), max: numeric(greatest),
                step: numeric(Double.leastNonzeroMagnitude)), number(0))
            let largeStep: ProgramResolvedOptionNode = option("large", "Step", .stepper(min: numeric(-greatest), max: numeric(greatest),
                step: numeric(greatest)), number(greatest / 2))
            let offgrid: ProgramResolvedOptionNode = option("offset", "Offset", .stepper(min: numeric(0), max: numeric(10),
                step: numeric(2)), number(3.25))
            panel.apply(snapshot(items: [huge, largeStep, offgrid]), lease: lease)
            var changes: [Panel.Change] = []
            panel.onChange = { changes.append($0) }
            guard let slider = try row(panel, "huge").controlView as? StudioNumericSlider,
                  let stepper = try row(panel, "large").controlView as? StudioNumericStepper,
                  let offset = try row(panel, "offset").controlView as? StudioNumericStepper else { throw Failure.fixture("extreme controls") }
            t.check(slider.slider.isEnabled && stepper.stepper.isEnabled)
            t.close(offset.stepper.doubleValue, 3.25); t.equal(offset.numberBox.field.stringValue, "3.25")
            offset.numberBox.pressArrow(up: true); t.equal(changes.last?.value, number(5.25))
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                slider.slider.doubleValue = fraction; t.check(perform(slider.slider))
                guard case .number(let value)? = changes.last?.value else { throw Failure.fixture("extreme value") }
                t.check(value.value.isFinite && value.value >= -greatest && value.value <= greatest)
                t.check(!slider.valueLabel.stringValue.lowercased().contains("nan"))
            }
            t.equal(changes.last?.value, number(greatest))
            stepper.numberBox.pressArrow(up: true); t.equal(changes.last?.value, number(greatest))
            stepper.numberBox.pressArrow(up: false, shift: true); t.equal(changes.last?.value, number(-greatest))
            let count = changes.count
            stepper.numberBox.type("NaN"); stepper.numberBox.type("1e999"); stepper.numberBox.type("1 / 0")
            t.equal(changes.count, count); t.equal(panel.feedbackLabel.stringValue, StudioText[.deskOptionsInvalidNumber])
            t.check(StudioNumericValue.clamped(.nan, minimum: -greatest, maximum: greatest, step: 1) == nil)
            var closes = 0
            panel.onRequestClose = { _ in if panel.commitEditing() { closes += 1 } }
            if let window = panel.window { t.check(!panel.windowShouldClose(window)) }
            t.equal(closes, 0, "invalid typed input stays open with its error rather than silently saving the old value")
            stepper.numberBox.type("0")
            if let window = panel.window { t.check(!panel.windowShouldClose(window)) }
            t.equal(closes, 1)
        }

        t.suite("App: Desk options panel: close commits the field before requesting save and force close retires callbacks") {
            let panel = fixture(t), lease = UUID()
            panel.apply(snapshot(), lease: lease)
            var order: [String] = []
            panel.onChange = { _ in order.append("change") }
            panel.onRequestClose = {
                t.equal($0, lease)
                order.append("close")
                t.check(panel.commitEditing())
            }
            panel.onMoreStyles = { t.equal($0, lease); order.append("styles") }
            panel.onRestoreDefaults = { value, revision in
                t.equal(value, lease); t.equal(revision, 1); order.append("restore")
            }
            guard let input = try row(panel, "note").numberBox, let window = panel.window else { throw Failure.fixture("closing editor") }
            t.check(window.makeFirstResponder(input.field))
            guard let editor = input.field.currentEditor() as? NSTextView else { throw Failure.fixture("closing editor text") }
            editor.string = "save me"
            t.check(!panel.windowShouldClose(window))
            t.equal(order, ["close", "change"], "the owner establishes its close request before flushing a possibly rejected edit")
            t.check(!panel.isClosed)
            t.check(window.makeFirstResponder(input.field))
            guard let lateEditor = input.field.currentEditor() as? NSTextView else { throw Failure.fixture("late closing editor") }
            lateEditor.string = "typed while the owner was pending"
            t.equal(order, ["close", "change"], "uncommitted text has not reached the owner yet")
            t.check(panel.commitEditing())
            t.equal(order, ["close", "change", "change"], "the final save boundary flushes text entered after the close request")
            t.check(panel.commitEditing()); t.equal(order.count, 3, "a repeated final check does not submit twice")
            panel.setFeedback(StudioText[.deskOptionsSaveFailed])
            t.equal(panel.feedbackLabel.stringValue, StudioText[.deskOptionsSaveFailed])
            t.check(perform(panel.moreStylesButton)); t.equal(order.last, "styles")
            t.check(perform(panel.restoreButton)); t.equal(order.last, "restore")
            let count = order.count
            panel.close()
            input.type("late")
            t.check(perform(panel.restoreButton)); t.check(perform(panel.moreStylesButton))
            panel.apply(snapshot(revision: 100), lease: UUID())
            panel.complete(UUID(), snapshot: snapshot(revision: 100))
            panel.present()
            t.equal(order.count, count)
            t.check(panel.isClosed && panel.lease == nil && panel.window?.isVisible == false)
            t.check(!panel.commitEditing())
        }

        t.suite("App: Desk options panel: invalid field text survives unrelated accepted updates until corrected or restored") {
            let panel = fixture(t), lease = UUID()
            panel.apply(snapshot(), lease: lease)
            guard let window = panel.window, let number = try row(panel, "days").numberBox,
                  let toggle = try row(panel, "enabled").controlView as? NSSwitch else { throw Failure.fixture("invalid field") }
            var values: [ProgramOptionValue] = [], closes = 0
            panel.onChange = { values.append($0.value) }
            panel.onRequestClose = { _ in if panel.commitEditing() { closes += 1 } }
            t.check(window.makeFirstResponder(number.field))
            guard let editor = number.field.currentEditor() as? NSTextView else { throw Failure.fixture("invalid field editor") }
            editor.string = "NaN"
            t.check(window.makeFirstResponder(nil)); t.equal(values, [])
            toggle.state = .on; t.check(perform(toggle))
            t.equal(values, [.boolean(true)])
            t.equal(number.field.stringValue, "NaN", "an unrelated row must not silently replace invalid text with the accepted value")
            panel.apply(snapshot(revision: 2, replacements: ["enabled": .boolean(true)]), lease: lease)
            panel.setFeedback(nil)
            t.equal(number.field.stringValue, "NaN")
            t.equal(panel.feedbackLabel.stringValue, StudioText[.deskOptionsInvalidNumber])
            t.check(!panel.commitEditing()); t.check(!panel.windowShouldClose(window)); t.equal(closes, 0)
            t.check(window.makeFirstResponder(number.field))
            guard let corrected = number.field.currentEditor() as? NSTextView else { throw Failure.fixture("corrected editor") }
            corrected.string = "3.25"
            t.check(panel.commitEditing()); t.equal(values.last, Self.number(3.25, .duration))
            t.check(panel.feedbackLabel.isHidden)
            t.check(!panel.windowShouldClose(window)); t.equal(closes, 1)
            number.type("1 / 0"); t.check(!panel.commitEditing())
            panel.onRestoreDefaults = { _, _ in panel.apply(snapshot(revision: 3), lease: lease) }
            t.check(perform(panel.restoreButton))
            t.equal(number.field.stringValue, "2")
            t.check(panel.feedbackLabel.isHidden && panel.commitEditing())
        }
    }

    private static func fixture(_ t: AppTestRunner) -> Panel {
        let panel = Panel(presentsWindows: false)
        t.atSuiteEnd { panel.close() }
        return panel
    }

    /// Content cache preserves the real native views and their alpha. Like SettingsWindowController.snapshot,
    /// place that cache over the window's actual background color; an unbacked view does not draw that surface.
    private static func compositeWindowBackground(_ raw: Data, content: NSView) -> NSBitmapImageRep? {
        let size = content.bounds.size
        guard size.width > 0, size.height > 0, let source = NSBitmapImageRep(data: raw),
              let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide,
                  pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        output.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(source.pixelsWide) / size.width, y: CGFloat(source.pixelsHigh) / size.height)
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            let rect = NSRect(origin: .zero, size: size)
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        return output
    }

    private static func row(_ panel: Panel, _ name: String) throws -> StudioRowView {
        guard let row = panel.pageView.itemView(name) as? StudioRowView else { throw Failure.fixture("row: \(name)") }
        return row
    }

    private static func numeric(_ value: Double, _ dimension: ProgramNumberDimension = .plain, _ base: Int? = nil) -> ProgramNumber {
        ProgramNumber(value, dimension: dimension, displayBase: base)
    }

    private static func number(_ value: Double, _ dimension: ProgramNumberDimension = .plain, _ base: Int? = nil) -> ProgramOptionValue {
        .number(numeric(value, dimension, base))
    }

    private static func option(_ name: String, _ title: String, _ control: ProgramResolvedOptionControl,
                               _ value: ProgramOptionValue, help: String? = nil, hidden: Bool = false) -> ProgramResolvedOptionNode {
        .option(ProgramResolvedOption(name: name, title: title, control: control, value: value, help: help, hidden: hidden))
    }

    private static func options() -> [ProgramResolvedOptionNode] {
        [
            option("enabled", "显示电量", .toggle, .boolean(false)),
            option("note", "备注", .input(placeholder: "写下备注"), .string("Original"), help: "只修改这个组件"),
            option("level", "Level", .slider(min: numeric(0, .percent), max: numeric(100, .percent), step: numeric(10, .percent)), number(20, .percent)),
            option("days", "Duration", .stepper(min: numeric(0, .duration), max: numeric(10, .duration), step: numeric(0.5, .duration)), number(2, .duration)),
            option("mode", "Mode", .picker(choices: ["full", "short", "compact"].map {
                ProgramResolvedOptionChoice(value: .localCase(option: "mode", name: $0), title: $0.capitalized)
            }), .localCase(option: "mode", name: "full")),
            option("city", "City", .picker(choices: ["A", "B", "C", "D"].map {
                ProgramResolvedOptionChoice(value: .string($0), title: "City " + $0)
            }), .string("A")),
            option("hidden", "Hidden", .toggle, .boolean(false), help: "Hidden help", hidden: true)
        ]
    }

    private static func snapshot(revision: UInt64 = 1, items: [ProgramResolvedOptionNode]? = nil,
                                 replacements: [String: ProgramOptionValue] = [:], hiddenNames: Set<String> = []) -> ProgramOptionsSnapshot {
        var values: [String: ProgramOptionValue] = [:]
        func replace(_ nodes: [ProgramResolvedOptionNode]) -> [ProgramResolvedOptionNode] {
            nodes.map { node in
                switch node {
                case .option(let option):
                    let value = replacements[option.name] ?? option.value
                    values[option.name] = value
                    return Self.option(option.name, option.title, option.control, value, help: option.help,
                                       hidden: option.hidden || hiddenNames.contains(option.name))
                case .section(let title, let nodes): return .section(title: title, items: replace(nodes))
                }
            }
        }
        let nodes = replace(items ?? options())
        return ProgramOptionsSnapshot(revision: revision, values: ProgramOptionsInput(values: values), items: nodes)
    }

    @discardableResult
    private static func perform(_ control: NSControl) -> Bool {
        guard let action = control.action else { return false }
        return control.sendAction(action, to: control.target)
    }
}
