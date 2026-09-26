import AppKit
import DesksetCore

/// `Deskset --self-test "Friendly inspector"`: the selection pages of docs/editor-friendly.md §7–8 (WP-C) — the
/// identity strip, cards with their essentials and "More … Options", the text, bar, group, shape, picture, graph and
/// live data pages, several layers, and the click actions.
///
/// Names come from `LayerNaming` (the sidebar work): the checks compare with what it says (`displayName(ofSection:)`),
/// so they hold before and after its rules land.
enum FriendlyInspectorSelfTests {
    static func run(_ t: AppTestRunner) {
        seamTests(t)
        stripTests(t)
        textTests(t)
        positionTests(t)
        barAndGroupTests(t)
        groupWriteTests(t)
        tokenFieldTests(t)
        moreTests(t)
        severalTests(t)
        showsTests(t)
        clickTests(t)
        otherPageTests(t)
        plainWordsTests(t)
    }

    // MARK: Helpers

    static func find(_ editor: InspectorWindowController, _ id: String) -> NSView? {
        editor.inspectorStack.findSubview { $0.identifier?.rawValue == id }
    }

    /// The label texts of a card's first grid (its essential rows), in order.
    static func essentialLabels(_ editor: InspectorWindowController, card: String) -> [String] {
        guard let card = find(editor, "card-\(card)"),
              let grid = card.findSubview(where: { $0 is NSGridView }) as? NSGridView else { return [] }
        return (0..<grid.numberOfRows).compactMap { i -> String? in
            let cell = grid.row(at: i).cell(at: 0).contentView
            return cell?.subviewsMatching { $0 is NSTextField }.compactMap { ($0 as? NSTextField)?.stringValue }
                .first { !$0.isEmpty }
        }
    }

    /// The file's text and one section of it.
    static func text(_ editor: InspectorWindowController) -> String {
        guard let url = editor.skin?.fileURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func section(_ editor: InspectorWindowController, _ name: String) -> String {
        let t = text(editor)
        guard let r = t.range(of: "[\(name)]") else { return "" }
        let rest = t[r.upperBound...]
        return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
    }

    /// Ends the current event: the undo manager groups what one event registers (as in the app).
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    // MARK: Seams

    /// The seams the pages are built on (step 0 of the friendly studio).
    static func seamTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: colors and linked values have their own controls") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.select(section: "MeterTitle")
            // FontColor=#Text#: the color control, named after the shared color it uses.
            let color = editor.inspectorStack.findSubview { $0.identifier?.rawValue == "FontColor.row" } as? ColorControl
            t.check(color != nil, "the font color is a ColorControl")
            t.check(color?.swatch.color != nil)
            t.equal(color?.nameButton.title, "Title text")

            // Y=(36 + #BarH# + 4): a calculated position — the number in effect, and its tag.
            editor.select(section: "MeterLowFreq")
            t.equal((find(editor, "MeterLowFreq/Y") as? ValueField)?.stringValue, "136")
            let menu = (find(editor, "MeterLowFreq/Y/tag") as? NSPopUpButton)?.menu
            t.check(menu?.items.contains { $0.title == "Show the Calculation…" } == true, "its menu shows the calculation")
            editor.window?.close()
        }
    }

    // MARK: Identity strip

    static func stripTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: the identity strip") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let skin = editor.skin, let title = skin.meter(named: "MeterTitle") else { return }
            editor.select(section: "MeterTitle")
            let name = LayerNaming.layer(title, in: skin)
            t.equal((find(editor, "strip-title") as? NSTextField)?.stringValue, name.title, "the layer's name, not its section")
            t.equal((find(editor, "strip-sentence") as? NSTextField)?.stringValue, name.sentence)
            t.equal((find(editor, "breadcrumb-0") as? NSButton)?.title, "‹ Audio Visualizer", "the widget, as a link")
            t.check(find(editor, "strip-edit-text") is NSButton, "Edit Text for a text")
            t.equal((find(editor, "strip-hide") as? NSButton)?.title, "Hide")
            t.equal((find(editor, "strip-lock") as? NSButton)?.title, "Lock")
            t.check(find(editor, "source-link") == nil, "no source link without Rainmeter Details")
            t.check(find(editor, "strip-picture") != nil, "a picture")
            // The breadcrumb goes up a level.
            (find(editor, "breadcrumb-0") as? NSButton)?.performClick(nil)
            t.equal(editor.selectedSection, nil, "the widget")

            // Rainmeter Details: the section and its line.
            app.state.updateEditor { $0.showIniNames = true }
            editor.select(section: "MeterTitle")
            editor.rebuildInspector()
            t.check((find(editor, "source-link") as? NSButton)?.title.hasPrefix("[MeterTitle] · Visualizer.ini:") == true,
                    "the source link with Rainmeter Details")
            app.state.updateEditor { $0.showIniNames = false }
            editor.rebuildInspector()

            // Hide: one undo step, named for the layer; the button follows.
            (find(editor, "strip-hide") as? NSButton)?.performClick(nil)
            t.check(section(editor, "MeterTitle").contains("Hidden=1\n"), "hidden")
            t.equal(editor.window?.undoManager?.undoActionName, "Hide \(editor.displayName(ofSection: "MeterTitle"))")
            t.equal((find(editor, "strip-hide") as? NSButton)?.title, "Show")
            settle()
            editor.window?.undoManager?.undo()
            t.check(!section(editor, "MeterTitle").contains("Hidden"), "undone")
            settle()

            // Lock: editor state only (the file is unchanged), undoable.
            let before = text(editor)
            (find(editor, "strip-lock") as? NSButton)?.performClick(nil)
            t.check(editor.isLayerLocked("MeterTitle"), "locked")
            t.equal(text(editor), before, "nothing written")
            t.equal((find(editor, "strip-lock") as? NSButton)?.title, "Unlock")
            editor.window?.undoManager?.undo()
            t.check(!editor.isLayerLocked("MeterTitle"), "undo unlocks")

            // A member of a group: the group in the breadcrumb (when the runs are known).
            if let run = editor.series(containing: "MeterBand5", in: skin) {
                editor.select(section: "MeterBand5")
                t.equal((find(editor, "breadcrumb-1") as? NSButton)?.title, "› \(run.members.count) bars")
            }
            editor.window?.close()
        }
    }

    // MARK: Text

    static func textTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: a text layer") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.select(section: "MeterTitle")
            t.equal(essentialLabels(editor, card: "Text"), ["Text", "Font", "Size", "Color", "Align", "Effect"],
                    "TEXT's rows (§8.2)")
            t.check(find(editor, "card-Shows") == nil, "no SHOWS card for plain words")
            t.equal((find(editor, "MeterTitle/Text") as? ValueField)?.placeholderString, "Type the words to show")
            t.equal((find(editor, "more-Text") as? NSButton)?.title, "More Text Options")
            t.check((find(editor, "more-summary-Text") as? NSTextField)?.stringValue.hasPrefix("capitals, up and down") == true)
            // Weight in words, Italic a button, Align in words.
            let weight = editor.inspectorControl(for: "FontWeight") as? NSPopUpButton
            t.equal((weight as? CompactPopUpButton)?.shownTitle, "Semibold", "FontWeight=600 reads Semibold")
            t.check(find(editor, "StringStyle") is NSButton, "the Italic button")
            (find(editor, "StringStyle") as? NSButton).map { b in
                b.state = .on
                b.sendAction(b.action, to: b.target)
            }
            t.check(section(editor, "MeterTitle").contains("StringStyle=Italic\n"), "italic written")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // The outcome buttons for what isn't set yet.
            for id in ["outcome-data", "outcome-box", "outcome-click"] { t.check(find(editor, id) != nil, id) }

            // A text showing live data: SHOWS first, the Text a token field; the device name has no Number row.
            editor.select(section: "MeterLowFreq")
            t.check(find(editor, "card-Shows") != nil, "SHOWS")
            t.check(find(editor, "number-format") is NSPopUpButton, "a number: the Number menu")
            let tokens = find(editor, "text-tokens") as? DataTokenField
            t.equal(tokens?.tokens, [1], "%1 is a tag")
            t.equal(tokens?.stringValue, "%1 Hz", "and reads back as written")
            editor.select(section: "MeterDevice")
            t.check(find(editor, "number-format") == nil, "text data: no Number row")
            t.check(find(editor, "go-to-data") is NSButton, "Go to Live Data ›")

            // + Add a Box Behind It…: a color and some room, one undo step.
            editor.select(section: "MeterTitle")
            (find(editor, "outcome-box") as? NSButton)?.performClick(nil)
            t.check(section(editor, "MeterTitle").contains("Padding=4,2,4,2\n"), "room around it")
            t.check(section(editor, "MeterTitle").contains("SolidColor="), "a color")
            t.equal(editor.window?.undoManager?.undoActionName, "Add a Box Behind It")
            t.check(find(editor, "card-Box Behind It") != nil, "its card")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            editor.window?.close()
        }

        t.suite("App: friendly inspector: the Number menu writes what it shows") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.select(section: "MeterLowFreq")
            guard let popup = find(editor, "number-format") as? NSPopUpButton,
                  let item = popup.itemArray.first(where: { $0.title.hasSuffix(" k") }) else { return t.check(false, "the k choice") }
            // The undo step is named as the layer was called when it was made (its words change with the number).
            let name = editor.displayName(ofSection: "MeterLowFreq")
            popup.select(item)
            popup.sendAction(popup.action, to: popup.target)
            let s = section(editor, "MeterLowFreq")
            t.check(s.contains("AutoScale=2k\n") && s.contains("NumOfDecimals=2\n"), "written: \(s)")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Number of \(name)")
            settle()
            editor.window?.undoManager?.undo()
            t.check(section(editor, "MeterLowFreq").contains("NumOfDecimals=0\n") && !section(editor, "MeterLowFreq").contains("AutoScale"),
                    "one undo step")
            editor.window?.close()
        }
    }

    // MARK: Position and Size

    static func positionTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: positions say what they follow") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            func tag(_ id: String) -> String? { (find(editor, id) as? NSPopUpButton)?.title }
            func label(of id: String) -> String? {
                guard let field = find(editor, id) else { return nil }
                var view: NSView? = field.superview
                while let current = view, !(current is NSGridView) { view = current.superview }
                guard let grid = view as? NSGridView else { return nil }
                for i in 0..<grid.numberOfRows {
                    guard let control = grid.row(at: i).cell(at: 1).contentView, field.isDescendant(of: control) else { continue }
                    return grid.row(at: i).cell(at: 0).contentView?.subviewsMatching { $0 is NSTextField }
                        .compactMap { ($0 as? NSTextField)?.stringValue }.first
                }
                return nil
            }
            // A right-aligned text: X is its right edge.
            editor.select(section: "MeterDevice")
            t.equal(label(of: "MeterDevice/X"), "X (right edge)")
            t.equal((find(editor, "MeterDevice/X") as? ValueField)?.stringValue, "203")
            t.equal(tag("MeterDevice/X/tag"), "calculated")

            // Y=(36 + #BarH# + 4): calculated, and a nudge keeps the calculation.
            editor.select(section: "MeterLowFreq")
            t.equal(tag("MeterLowFreq/Y/tag"), "calculated")
            t.equal(tag("MeterLowFreq/X/tag"), "Left", "a shared value by its name")
            editor.nudge(dx: 0, dy: -1)
            editor.commitPendingNudge()
            t.check(section(editor, "MeterLowFreq").contains("Y=(36 + #BarH# + 3)\n"), "the link is kept: \(section(editor, "MeterLowFreq"))")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // Typing a number keeps it too.
            editor.select(section: "MeterLowFreq")
            (find(editor, "MeterLowFreq/Y") as? ValueField)?.type("130")
            t.check(section(editor, "MeterLowFreq").contains("Y=(36 + #BarH# - 2)\n"), "typed: \(section(editor, "MeterLowFreq"))")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // Y=0r: the same top as the layer before it.
            editor.select(section: "MeterHighFreq")
            t.equal(tag("MeterHighFreq/Y/tag"), "Same top as \(editor.displayName(ofSection: "MeterLowFreq"))")

            // X=#BarGap#R: n px after the bar before.
            editor.select(section: "MeterBand5")
            t.equal(tag("MeterBand5/X/tag"), "3 px after \(editor.displayName(ofSection: "MeterBand4"))")
            t.equal((find(editor, "MeterBand5/X") as? ValueField)?.stringValue, "74")
            // "Use a Fixed Position Here" writes the number.
            (find(editor, "MeterBand5/X/tag") as? NSPopUpButton)?.menu?.items
                .first { $0.title == "Use a Fixed Position Here" }
                .map { item in _ = item.target?.perform(item.action) }
            t.check(section(editor, "MeterBand5").contains("X=74\n"), "fixed")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // X=[MeasurePeakX]: moves with live data.
            editor.select(section: "MeterPeak")
            t.check(tag("MeterPeak/X/tag")?.hasPrefix("moves with ") == true, tag("MeterPeak/X/tag") ?? "")
            // Change ‘Left’ for All…: the field edits the shared value itself.
            editor.select(section: "MeterTitle")
            (find(editor, "MeterTitle/X/tag") as? NSPopUpButton)?.menu?.items
                .first { $0.title.hasPrefix("Change ‘Left’ for All") }
                .map { item in _ = item.target?.perform(item.action) }
            t.check(find(editor, "shared-caption") != nil, "“Changing Left for … layers.”")
            (find(editor, "MeterTitle/X") as? ValueField)?.type("20")
            t.check(section(editor, "Variables").contains("Left=20\n"), "the shared value changed")
            t.check(section(editor, "MeterTitle").contains("X=#Left#\n"), "the layer still uses it")
            editor.window?.close()
        }
    }

    // MARK: Bar and group

    static func barAndGroupTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: a bar and the group of bars") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.select(section: "MeterBand5")
            t.equal((find(editor, "look-badge") as? NSButton)?.title, "Look shared with 16 bars")
            t.equal(essentialLabels(editor, card: "Bar"), ["Shows", "Fill", "Empty part", "Fills toward"])
            t.check((find(editor, "right-now") as? NSTextField)?.stringValue.hasPrefix("Right now ") == true, "the value now")
            // Clicking the badge selects the look's users.
            (find(editor, "look-badge") as? NSButton)?.performClick(nil)
            t.equal(editor.selectedMeters.count, 16, "the 16 bars")

            // The group page: the 16 bars, their spacing.
            let bands = (0..<16).map { "MeterBand\($0)" }
            editor.canvasSelectionChanged(bands)
            t.equal((find(editor, "strip-title") as? NSTextField)?.stringValue, "16 bars")
            t.check(find(editor, "card-Bars") != nil && find(editor, "card-Spacing") != nil && find(editor, "card-Arrange") != nil,
                    "BARS, SPACING, ARRANGE")
            t.equal((find(editor, "strip-hide") as? NSButton)?.title, "Hide All")
            t.equal((find(editor, "spacing-width") as? ValueField)?.stringValue, "9")
            t.equal((find(editor, "spacing-gap") as? ValueField)?.stringValue, "3")
            t.equal((find(editor, "spacing-height/also") as? NSTextField)?.stringValue,
                    "Also moves \(editor.displayName(ofSection: "MeterLowFreq")).")
            (find(editor, "spacing-height") as? ValueField)?.type("100")
            t.check(section(editor, "Variables").contains("BarH=100\n"), "Height writes the shared size")
            t.equal(editor.skin?.meter(named: "MeterBand9")?.frame.height, 100, "every bar follows")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // Fills toward, for all 16 at once: their look.
            editor.canvasSelectionChanged(bands)
            t.check(editor.chooseOption("BarOrientation", value: "Right"), "fills toward")
            t.check(section(editor, "StyleBand").contains("BarOrientation=Horizontal\n"), "the look they share")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Fills Toward of 16 Bars")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // Hide All: one undo step for the 16.
            editor.canvasSelectionChanged(bands)
            (find(editor, "strip-hide") as? NSButton)?.performClick(nil)
            t.equal(bands.filter { editor.skin?.meter(named: $0)?.hidden == true }.count, 16)
            t.equal(editor.window?.undoManager?.undoActionName, "Hide 16 Bars")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(bands.filter { editor.skin?.meter(named: $0)?.hidden == true }.count, 0, "one undo step")
            editor.window?.close()
        }
    }

    /// What the group page writes reaches every member (§8.4: "Changes apply to all 16"), not only the first.
    static func groupWriteTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: the group moves and colors all its members") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            let bands = (0..<16).map { "MeterBand\($0)" }
            func frames() -> [SkinRect] { bands.compactMap { editor.skin?.meter(named: $0)?.frame } }
            editor.canvasSelectionChanged(bands)
            let before = frames()
            t.equal(before.count, 16)

            // Starts at Y: Y=36 comes from their look for all 16, so the look moves and every bar with it.
            (find(editor, "MeterBand0/Y") as? ValueField)?.type("40")
            t.check(section(editor, "StyleBand").contains("Y=40\n"), "the look they share: \(section(editor, "StyleBand"))")
            t.check(!section(editor, "MeterBand0").contains("Y="), "not the first bar alone")
            t.equal(frames().map(\.y), Array(repeating: 40.0, count: 16), "all 16 moved down")
            t.equal(editor.window?.undoManager?.undoActionName, "Move 16 Bars")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(frames().map(\.y), before.map(\.y), "one undo step")
            settle()

            // Starts at X, ↑: the first bar's link is kept and the others, placed after the one before, follow.
            editor.canvasSelectionChanged(bands)
            (find(editor, "MeterBand0/X") as? GeometryField)?.onStep?(1)
            t.check(section(editor, "MeterBand0").contains("X=(#Left# + 1)\n"), section(editor, "MeterBand0"))
            t.check(section(editor, "MeterBand1").contains("X=#BarGap#R\n"), "the others keep their spacing")
            t.equal(frames().map(\.x), before.map { $0.x + 1 }, "all 16 moved right")
            t.equal(editor.window?.undoManager?.undoActionName, "Move 16 Bars")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // The start's tag writes nothing for the first bar alone.
            editor.canvasSelectionChanged(bands)
            let items = (find(editor, "MeterBand0/X/tag") as? NSPopUpButton)?.menu?.items.map(\.title) ?? []
            t.check(!items.contains { $0.hasPrefix("Use a Fixed") } && items.contains { $0.hasPrefix("Change ‘Left’") }, "\(items)")

            // ARRANGE ▸ Top: the 16 move together and keep their spacing.
            editor.canvasSelectionChanged(bands)
            (find(editor, "card-Arrange")?.findSubview { $0.identifier?.rawValue == EditorAlign.Mode.top.rawValue } as? NSButton)?
                .performClick(nil)
            t.equal(frames().map(\.y), Array(repeating: 0.0, count: 16), "at the top")
            t.equal(frames().map(\.x), before.map(\.x), "spacing kept")
            t.check(editor.window?.undoManager?.undoActionName.hasSuffix(" 16 Bars") == true, editor.window?.undoManager?.undoActionName ?? "")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            editor.canvasSelectionChanged(bands)

            // Fill: picked for the 16 bars, written to their look (not to the first bar, not to the shared color the
            // two level bars use too).
            guard let fill = (find(editor, "BarColor.row") as? ColorControl)?.swatch else { return t.check(false, "the Fill control") }
            t.check(ShapeColorPicker.shared.activate(fill), "the pick is for all 16")
            ShapeColorPicker.shared.pick(RGBA(r: 255, g: 0, b: 0, a: 255), for: fill)
            ShapeColorPicker.shared.relinquish()
            t.check(section(editor, "StyleBand").contains("BarColor=255,0,0,255\n"), section(editor, "StyleBand"))
            t.check(!section(editor, "MeterBand0").contains("BarColor"), "not Bar 1 alone")
            t.check(section(editor, "Variables").contains("Accent=120,200,255,255\n"), "the shared color is left alone")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Fill of 16 Bars")
            settle()
            editor.window?.undoManager?.undo()
            t.check(section(editor, "StyleBand").contains("BarColor=#Accent#\n"), "one undo step")
            editor.window?.close()
        }

        t.suite("App: friendly inspector: a group's start moves members placed on their own") {
            // Calendar's weekday heads: each has its own X (a calculation), their Y comes from their look.
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Calendar", from: "DefaultSkins") else { return }
            let heads = (0..<7).map { "MeterHead\($0)" }
            func frames() -> [SkinRect] { heads.compactMap { editor.skin?.meter(named: $0)?.frame } }
            editor.canvasSelectionChanged(heads)
            guard find(editor, "card-Spacing") != nil, let x = find(editor, "MeterHead0/X") as? ValueField,
                  let start = Double(x.stringValue) else { return t.check(false, "the group page of the 7 heads") }
            let before = frames()
            x.type(GeometryEdit.format(start + 5))
            t.equal(frames().map(\.x), before.map { $0.x + 5 }, "all 7 moved right")
            for head in heads { t.check(section(editor, head).contains(" + 5)\n"), "\(head) keeps its calculation: \(section(editor, head))") }
            t.equal(editor.window?.undoManager?.undoActionName, "Move 7 Texts")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(frames().map(\.x), before.map(\.x), "one undo step")
            settle()
            editor.canvasSelectionChanged(heads)
            (find(editor, "MeterHead0/Y") as? GeometryField)?.onStep?(-2)
            t.equal(frames().map(\.y), before.map { $0.y - 2 }, "all 7 moved up")
            t.check(section(editor, "StyleHead").contains("Y=(#GridY# - 2)\n"), "their look: \(section(editor, "StyleHead"))")
            editor.window?.close()
        }
    }

    /// The token field of a text showing live data: typing is undone in the field, never from the window's stack; a
    /// rebuild while typing keeps the typed text.
    static func tokenFieldTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: typing in the data text field") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let window = editor.window else { return }
            editor.select(section: "MeterLowFreq")
            guard let field = find(editor, "text-tokens") as? DataTokenField else { return t.check(false, "the token field") }
            t.check(window.makeFirstResponder(field.textView), "editing")
            let end = field.textView.textStorage?.length ?? 0
            field.textView.setSelectedRange(NSRange(location: end, length: 0))
            field.textView.insertText("!", replacementRange: NSRange(location: end, length: 0))
            t.equal(field.stringValue, "%1 Hz!")
            t.check(field.textView.undoManager === field.typingUndoManager, "typing has the field's own undo")
            t.check(window.undoManager?.canUndo != true, "nothing on the window's stack")

            // A rebuild while typing: the new field goes on with the typed text, and it is written afterwards.
            editor.rebuildInspector()
            guard let again = find(editor, "text-tokens") as? DataTokenField else { return t.check(false, "rebuilt") }
            t.check(again !== field, "a new field")
            t.equal(again.stringValue, "%1 Hz!", "the typed text goes on")
            t.check(window.firstResponder === again.textView, "and keeps the focus")
            t.check(!section(editor, "MeterLowFreq").contains("Text=%1 Hz!"), "not written yet")
            _ = again.textView(again.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            t.check(section(editor, "MeterLowFreq").contains("Text=%1 Hz!\n"), "Return writes it")
            settle()
            // One undo step for the change, and no step for the typing behind it.
            window.undoManager?.undo()
            t.check(section(editor, "MeterLowFreq").contains("Text=%1 Hz\n"), "undone")
            t.check(window.undoManager?.canUndo != true, "no Typing step left: \(window.undoManager?.undoActionName ?? "")")
            editor.window?.close()
        }

        t.suite("App: friendly inspector: the Number menu keeps the text's base") {
            // System's memory text shortens by 1024s (AutoScale=1): its format is one of the choices.
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let skin = editor.skin, let measure = skin.meter(named: "MeterRAMValue")?.measures.first else { return }
            editor.select(section: "MeterRAMValue")
            guard let popup = find(editor, "number-format") as? NSPopUpButton else { return t.check(false, "the Number menu") }
            let presets = editor.numberPresets(for: measure, skin: skin, section: "MeterRAMValue")
            let current = FormatPresets.index(of: ["AutoScale": "1", "NumOfDecimals": "1"], in: presets)
            t.check(current != nil, "its format is a choice")
            t.equal(popup.selectedItem?.tag, current, "and is the one shown")
            t.check(!popup.itemArray.contains { $0.identifier?.rawValue == "number-format-custom" }, "not Custom")
            t.check(presets.prefix(2).allSatisfy { ($0.options["AutoScale"] ?? nil) == "1" }, "in 1024s")
            // Fewer decimals: the base stays.
            if let whole = popup.itemArray.first(where: { $0.tag == 0 && !$0.isSeparatorItem && !($0 is ClosureMenuItem) }) {
                popup.select(whole)
                popup.sendAction(popup.action, to: popup.target)
            }
            t.check(section(editor, "MeterRAMValue").contains("NumOfDecimals=0\n"), section(editor, "MeterRAMValue"))
            t.check(section(editor, "MeterRAMValue").contains("AutoScale=1\n"), "still 1024s")
            editor.window?.close()
        }

        t.suite("App: friendly inspector: a custom number format reads as a normal choice") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let url = editor.skin?.fileURL else { return }
            let ini = text(editor).replacingOccurrences(of: "Y=(36 + #BarH# + 4)\nNumOfDecimals=0\n",
                                                        with: "Y=(36 + #BarH# + 4)\nNumOfDecimals=0\nScale=1000\n")
            try ini.write(to: url, atomically: true, encoding: .utf8)
            editor.refreshSkin()
            editor.select(section: "MeterLowFreq")
            guard let popup = find(editor, "number-format") as? NSPopUpButton else { return t.check(false, "the Number menu") }
            t.equal(popup.selectedItem?.identifier?.rawValue, "number-format-custom")
            t.check(popup.selectedItem?.isEnabled == true, "drawn as a normal choice")
            t.check(popup.titleOfSelectedItem?.hasPrefix("Custom — ") == true, popup.titleOfSelectedItem ?? "")
            let before = text(editor)
            popup.sendAction(popup.action, to: popup.target)
            t.equal(text(editor), before, "choosing it keeps it")
            editor.window?.close()
        }
    }

    // MARK: More … Options

    static func moreTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: More opens by itself for what is in use") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.select(section: "MeterTitle")
            t.check(editor.inspectorControl(for: "StringCase") == nil, "More Text Options closed: nothing in it is in use")
            editor.writeProperty(section: "MeterTitle", key: "StringCase", value: "Upper", variable: nil, label: "Capitals")
            settle()
            editor.select(section: "MeterTitle")
            t.equal((find(editor, "more-summary-Text") as? NSTextField)?.stringValue,
                    "capitals, up and down, long text, text before and after, rotation · 1 in use")
            let capitals = editor.inspectorControl(for: "StringCase") as? CompactPopUpButton
            t.equal(capitals?.shownTitle, "UPPERCASE", "opened, Capitals in its own case")
            t.check(find(editor, "in-use-dot") != nil, "its row has the dot")
            // Closed by the user, it stays closed for this layer.
            (find(editor, "more-Text") as? NSButton)?.performClick(nil)
            t.check(editor.inspectorControl(for: "StringCase") == nil, "closed")
            editor.select(section: "MeterDevice")
            editor.select(section: "MeterTitle")
            t.check(editor.inspectorControl(for: "StringCase") == nil, "still closed")

            // Rainmeter Details: every More open, the lines the controls can't show.
            app.state.updateEditor { $0.showIniNames = true }
            for name in ["MeterTitle", "MeterBand5", "MeterBackground", "MeasureBand5"] {
                editor.select(section: name)
                editor.rebuildInspector()
                let rows = editor.inspectorStack.subviewsMatching { ($0.identifier?.rawValue ?? "").hasPrefix("more-row-") }
                t.check(!rows.isEmpty, "\(name) has More")
                for row in rows {
                    guard let stack = row.superview as? NSStackView, let i = stack.arrangedSubviews.firstIndex(of: row) else { continue }
                    t.check(i + 1 < stack.arrangedSubviews.count, "\(name): \(row.identifier?.rawValue ?? "") is open")
                }
            }
            app.state.updateEditor { $0.showIniNames = false }
            editor.window?.close()
        }
    }

    // MARK: Several

    static func severalTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: several layers") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.canvasSelectionChanged(["MeterLowFreq", "MeterHighFreq"])
            let across = find(editor, EditorAlign.Mode.distributeX.rawValue) as? NSButton
            t.equal(across?.isEnabled, false, "Space out needs three")
            t.equal(across?.toolTip, "Needs 3 or more layers.")
            let names = ["MeterLowFreq", "MeterHighFreq", "MeterLeftLabel"]
            editor.canvasSelectionChanged(names)
            t.equal((find(editor, "strip-title") as? NSTextField)?.stringValue, "3 texts")
            t.equal((find(editor, "strip-sentence") as? NSTextField)?.stringValue,
                    "\(editor.displayName(ofSection: names[0])), \(editor.displayName(ofSection: names[1])) and \(editor.displayName(ofSection: names[2]))")
            t.equal((find(editor, EditorAlign.Mode.distributeX.rawValue) as? NSButton)?.isEnabled, true)
            t.check(find(editor, "card-Shared") != nil, "the kind's shared settings")
            t.equal(names.map { find(editor, "selected-\($0)") is NSButton }, [true, true, true], "each a click away")
            // A size for all three: one undo step named for them.
            (find(editor, "several/FontSize") as? ValueField)?.type("9")
            for n in names {
                t.equal(editor.skin?.meter(named: n).flatMap { ($0 as? StringMeter)?.double("FontSize", 0) }, 9, n)
            }
            t.equal(editor.window?.undoManager?.undoActionName, "Change Size of 3 Texts")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // Different kinds: only arranging.
            editor.canvasSelectionChanged(["MeterTitle", "MeterBand3"])
            t.check(find(editor, "mixed-kinds") != nil && find(editor, "card-Shared") == nil)
            (find(editor, "selected-MeterBand3") as? NSButton)?.performClick(nil)
            t.equal(editor.selectedSection, "MeterBand3", "a chip selects one")
            editor.window?.close()
        }
    }

    // MARK: Shows

    static func showsTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: Shows creates live data and uses it in one step") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.select(section: "MeterBand5")
            guard let shows = editor.inspectorControl(for: "MeasureName") as? NSPopUpButton,
                  let new = shows.menu?.items.first(where: { $0.identifier?.rawValue == "new-live-data" }),
                  let cpu = new.submenu?.items.first(where: { ($0.representedObject as? String) == "CPU" }) as? ClosureMenuItem
            else { return t.check(false, "New ▸ CPU usage") }
            // IN THIS WIDGET: the 16 bands folded into one item.
            t.check(shows.menu?.items.contains { $0.submenu?.items.count == 16 } == true, "bands folded")
            let before = text(editor)
            _ = cpu.target?.perform(cpu.action)
            t.check(text(editor).contains("[MeasureCPU]\nMeasure=CPU\n"), "created")
            t.check(section(editor, "MeterBand5").contains("MeasureName=MeasureCPU\n"), "and shown")
            t.equal(editor.window?.undoManager?.undoActionName, "Show CPU Usage")
            t.equal(editor.selectedSection, "MeterBand5", "the bar stays selected")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(text(editor), before, "one undo step")
            settle()

            // "+ Show Live Data…" on plain words: the text shows it after its words.
            editor.showLiveData("MeasureDevice", in: "MeterTitle")
            t.check(section(editor, "MeterTitle").contains("Text=Audio %1\n"), section(editor, "MeterTitle"))
            t.check(section(editor, "MeterTitle").contains("MeasureName=MeasureDevice\n"))
            settle()
            editor.window?.undoManager?.undo()
            t.equal(text(editor), before, "one undo step")
            editor.window?.close()
        }
    }

    // MARK: Click actions

    static func clickTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: WHEN CLICKED") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            editor.select(section: "MeterTitle")
            t.check(find(editor, "card-When Clicked") == nil, "not until asked")
            (find(editor, "outcome-click") as? NSButton)?.performClick(nil)
            guard let click = find(editor, "LeftMouseUpAction.choice") as? NSPopUpButton,
                  let website = click.itemArray.first(where: { $0.title == "Open a Website…" }) else {
                return t.check(false, "the Click picker")
            }
            t.equal(essentialLabels(editor, card: "When Clicked"), ["Click", "Pointed at", "Tooltip"])
            click.select(website)
            click.sendAction(click.action, to: click.target)
            guard let url = find(editor, "MeterTitle/LeftMouseUpAction/url") as? ValueField else { return t.check(false, "address") }
            url.type("https://example.com")
            t.check(section(editor, "MeterTitle").contains("LeftMouseUpAction=[\"https://example.com\"]\n"),
                    section(editor, "MeterTitle"))
            t.equal(editor.window?.undoManager?.undoActionName, "Change When Clicked")
            t.equal((find(editor, "LeftMouseUpAction.choice") as? NSPopUpButton)?.selectedItem?.title, "Open a Website…",
                    "read back")
            settle()
            // Reload the Widget: written at once.
            if let c = find(editor, "LeftMouseUpAction.choice") as? NSPopUpButton,
               let reload = c.itemArray.first(where: { $0.title == "Reload the Widget" }) {
                c.select(reload)
                c.sendAction(c.action, to: c.target)
            }
            t.check(section(editor, "MeterTitle").contains("LeftMouseUpAction=[!Refresh]\n"))
            settle()
            editor.window?.close()
        }

        t.suite("App: friendly inspector: an action the picker can't read is never rewritten") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let url = editor.skin?.fileURL else { return }
            let action = #"[!SetOption MeterTitle Text "Hi there"][!Log   "x"]"#
            var ini = text(editor)
            ini = ini.replacingOccurrences(of: "Text=Audio\n", with: "Text=Audio\nLeftMouseUpAction=\(action)\n")
            try ini.write(to: url, atomically: true, encoding: .utf8)
            editor.refreshSkin()
            editor.select(section: "MeterTitle")
            t.equal((find(editor, "LeftMouseUpAction.choice") as? NSPopUpButton)?.selectedItem?.title, "Custom Command…")
            t.equal((find(editor, "MeterTitle/LeftMouseUpAction/sentence") as? NSTextField)?.stringValue, "Runs 2 commands")
            // An unrelated edit.
            (editor.inspectorControl(for: "FontSize") as? NumberControl)?.field.type("12")
            t.check(section(editor, "MeterTitle").contains("FontSize=12\n"))
            t.check(section(editor, "MeterTitle").contains("LeftMouseUpAction=\(action)\n"), "byte-identical")
            editor.window?.close()
        }
    }

    // MARK: Shape, picture, live data

    static func otherPageTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: shape, picture and live data pages") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            func shape() -> String? { editor.skin?.document.section(named: "MeterBackground")?.value(forKey: "Shape") }
            // One rounded rectangle: Type, Corners, Fill, Outline; its size is the rectangle's.
            editor.select(section: "MeterBackground")
            t.equal((find(editor, "shape-page-type") as? CompactPopUpButton)?.shownTitle, "Rounded rectangle")
            t.equal((find(editor, "shape-corners") as? NSPopUpButton)?.titleOfSelectedItem, "Medium", "10 px corners")
            t.check(find(editor, "add-shape") != nil, "one shape: + Add Another Shape")
            t.check(find(editor, "card-Parts") == nil, "no PARTS for one shape")
            t.equal((find(editor, "MeterBackground/Shape/Width") as? ValueField)?.stringValue, "217")
            (find(editor, "MeterBackground/Shape/Height") as? ValueField)?.type("200")
            t.equal(shape(), "Rectangle 0,0,#Width#,200,10 | Fill Color 16,19,28,235 | StrokeWidth 0", "the rectangle's height")
            settle()
            (find(editor, "MeterBackground/Shape/Width") as? ValueField)?.type("220")
            t.check(shape()?.hasPrefix("Rectangle 0,0,(#Width# + 3),200,10") == true, "a shared width keeps its link: \(shape() ?? "")")
            settle()
            (find(editor, "shape-corners") as? NSPopUpButton).map { p in
                p.selectItem(withTitle: "Large")
                p.sendAction(p.action, to: p.target)
            }
            t.check(shape()?.contains(",16 |") == true, "Large corners: 16")
            settle()

            // A color block.
            editor.select(section: "MeterPeak")
            t.check(find(editor, "card-Color Block") != nil, "a color block")
            t.equal(essentialLabels(editor, card: "Color Block"), ["Picture", "Color", "Opacity", "Fit"])

            // Live data: RIGHT NOW, USED BY, SETTINGS; the band 1-based.
            editor.select(section: "MeasureBand5")
            t.check(find(editor, "card-Right Now") != nil && find(editor, "card-Used By") != nil && find(editor, "card-Settings") != nil)
            t.check(find(editor, "used-by-MeterBand5") != nil, "the bar showing it")
            t.equal((find(editor, "MeasureBand5/BandIdx") as? ValueField)?.stringValue, "6", "band 6 of 16 (BandIdx=5)")
            (find(editor, "MeasureBand5/BandIdx") as? ValueField)?.type("7")
            t.check(section(editor, "MeasureBand5").contains("BandIdx=6\n"), "written 0-based")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // Used through a position: MeasurePeakX moves the Peak marker.
            editor.select(section: "MeasurePeakX")
            t.check(find(editor, "used-by-MeterPeak") != nil, "used by the layer that moves with it")
            t.check(find(editor, "unused") == nil)
            editor.window?.close()
        }

        t.suite("App: friendly inspector: a shape's colors") {
            // System's memory bar: part 1 is its look's track (StyleTrack, in the Styles.inc other widgets share),
            // filled with the theme color TrackColor.
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let skin = editor.skin else { return }
            let styles = skin.resourcesDirectory.appendingPathComponent("Styles.inc")
            let shared = try Data(contentsOf: styles)
            editor.select(section: "MeterRAMBar")
            // The fill (the part that follows the data) is shown first; the track is one click away.
            t.equal(editor.inspectorState.expandedShapes["meterrambar"], nil)
            t.check((find(editor, "part-Shape2") as? NSButton)?.title.hasSuffix("— fill") == true, "the fill part")
            editor.inspectorState.expandedShapes["meterrambar"] = "Shape"
            editor.rebuildInspector()
            // The theme color by the name the widget page gives it (its role), as every color control names it.
            let role = editor.colorRoleName(variable: "TrackColor", color: nil)
            t.check(role != nil && role != "Custom", "\(role ?? "nil")")
            t.equal((find(editor, "shape-page-fill-color.name") as? NSButton)?.title, role, "the theme color's name")
            t.check(["10%", "10% opacity"].contains((find(editor, "shape-page-fill-color.opacity") as? NSTextField)?.stringValue ?? ""),
                    "its opacity (under the name when both don't fit beside the swatch)")
            guard let swatch = find(editor, "shape-page-fill-color") as? SwatchButton else { return t.check(false, "the swatch") }
            t.check(swatch.superview is SwatchRim, "a rim that shows on a dark card")
            let menu = editor.shapePaintMenu(meter: "MeterRAMBar", key: "Shape", stroke: false, swatch: swatch)
            func item(_ id: String) -> NSMenuItem? { menu.items.first { $0.identifier?.rawValue == id } }
            t.equal(item("theme-color-TrackColor")?.state, .on, "the current theme color is checked")
            t.check(item("change-everywhere")?.title.contains("‘\(role ?? "")’") == true, item("change-everywhere")?.title ?? "")
            t.check(item("custom-color") != nil && menu.items.contains { $0.title.hasPrefix("Copy Color Code") })
            // Another theme color keeps the link — on this layer: the look other widgets share is not rewritten.
            item("theme-color-AccentColor").map { _ = $0.target?.perform($0.action, with: $0) }
            t.check(section(editor, "MeterRAMBar").contains("Fill Color #AccentColor#"), section(editor, "MeterRAMBar"))
            t.equal(try Data(contentsOf: styles), shared, "Styles.inc is unchanged")
            t.check(editor.toast.text.hasSuffix("Other widgets share its look, so the look stays as it is."), editor.toast.text)
            settle()
            editor.window?.undoManager?.undo()
            t.check(!section(editor, "MeterRAMBar").contains("\nShape="), "one undo step")
            settle()
            // A color of its own, from the color panel; the corners: the same.
            editor.select(section: "MeterRAMBar")
            if let swatch = find(editor, "shape-page-fill-color") as? SwatchButton {
                ShapeColorPicker.shared.pick(RGBA(r: 255, g: 0, b: 0, a: 255), for: swatch)
                ShapeColorPicker.shared.relinquish()
            }
            t.check(section(editor, "MeterRAMBar").contains("Fill Color 255,0,0,255"), section(editor, "MeterRAMBar"))
            settle()
            (find(editor, "shape-corners") as? NSPopUpButton).map { p in
                p.selectItem(withTitle: "Large")
                p.sendAction(p.action, to: p.target)
            }
            t.check(section(editor, "MeterRAMBar").contains(",16 |"), "Large corners on the layer")
            t.equal(try Data(contentsOf: styles), shared, "Styles.inc is still unchanged")
            editor.window?.close()
        }

        t.suite("App: friendly inspector: unused live data") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let url = editor.skin?.fileURL else { return }
            var ini = text(editor)
            ini = ini.replacingOccurrences(of: "; ---------- Styles ----------",
                                           with: "[MeasureSpare]\nMeasure=Calc\nFormula=1 + 1\nIfAboveValue=1\nIfAboveAction=[!Refresh]\n"
                                            + "IfCondition=MeasureSpare > 5\nIfTrueAction=[!Refresh]\n"
                                            + "IfCondition2=(MeasureSpare > 1) && (MeasureSpare < 3)\nIfTrueAction2=[!Refresh]\n\n"
                                            + "[MeasureIdle]\nMeasure=Calc\nFormula=2 + 2\n\n"
                                            + "; ---------- Styles ----------")
            try ini.write(to: url, atomically: true, encoding: .utf8)
            editor.refreshSkin()
            // Data nothing uses and that does nothing: offered for deletion, as in the Live Data tab.
            editor.select(section: "MeasureIdle")
            t.equal((find(editor, "unused") as? NSTextField)?.stringValue, "Not used by any layer.")
            t.check(find(editor, "delete-data") is NSButton && find(editor, "show-in-text") is NSButton)
            // Data with actions of its own does something: not "unused", no Delete (the sidebar's rule).
            editor.select(section: "MeasureSpare")
            t.check(find(editor, "unused") == nil && find(editor, "delete-data") == nil, "not offered for deletion")
            t.equal((find(editor, "acts") as? NSTextField)?.stringValue, "Runs actions when it updates.")
            // Its rule reads as a sentence (in More, which it opened: a rule is in use).
            t.equal((find(editor, "rule-0") as? NSTextField)?.stringValue, "When the value is above 1 → reloads the widget")
            t.equal((find(editor, "rule-1") as? NSTextField)?.stringValue, "When the value is above 5 → reloads the widget")
            // What isn't one comparison is shown as written, once.
            t.equal(editor.inspectorStack.subviewsMatching { $0.identifier?.rawValue == "MeasureSpare/IfCondition2" }.count, 1,
                    "the second rule's lines")
            t.check(find(editor, "MeasureSpare/IfCondition") == nil, "the first rule is a sentence, not lines")
            editor.select(section: "MeasureIdle")
            (find(editor, "show-in-text") as? NSButton)?.performClick(nil)
            settle()
            t.check(text(editor).contains("MeasureName=MeasureIdle\n"), "a new text shows it")
            t.equal(editor.skin?.meter(named: editor.selectedSection ?? "")?.type.lowercased(), "string", "and is selected")
            editor.window?.close()
        }
    }

    // MARK: Plain words

    /// The default pages use no engine words (§3.3, G3): every label, button title, segment and closed pop-up of every
    /// layer and live data page of Visualizer. The color control and linked-value tags are the widget page work's
    /// (checked there and at integration).
    static func plainWordsTests(_ t: AppTestRunner) {
        t.suite("App: friendly inspector: plain words on every page") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"), let skin = editor.skin else { return }
            func texts(_ root: NSView) -> [String] {
                if root is ColorControl || root is LinkedValueTag || root is ShapeEditorView { return [] }
                var result: [String] = []
                switch root {
                case let p as CompactPopUpButton: result.append(p.shownTitle)
                case let p as NSPopUpButton: result.append(p.titleOfSelectedItem ?? "")
                case let s as NSSegmentedControl: result += (0..<s.segmentCount).compactMap { s.label(forSegment: $0) }
                case let b as NSButton: result.append(b.title)
                case let f as NSTextField where !(f is ValueField) && !f.isEditable: result.append(f.stringValue)
                default: break
                }
                for v in root.subviews where !v.isHidden { result += texts(v) }
                return result
            }
            editor.select(section: "MeterTitle")
            let seen = texts(editor.inspectorStack)
            t.check(seen.contains("Hide") && seen.contains("More Text Options") && seen.contains("Font"), "the scan reads the page: \(seen)")
            let pages = skin.meters.map(\.name) + skin.measures.map(\.name)
            for name in pages {
                editor.select(section: name)
                for text in texts(editor.inspectorStack) {
                    if let word = EditorSchema.engineWord(in: text) { t.check(false, "\(name): “\(text)” says \(word)") }
                }
            }
            editor.canvasSelectionChanged((0..<16).map { "MeterBand\($0)" })
            for text in texts(editor.inspectorStack) where EditorSchema.engineWord(in: text) != nil {
                t.check(false, "group: “\(text)”")
            }
            editor.window?.close()
            // The default widgets too.
            for config in ["Deskset\\System", "Deskset\\Clock"] {
                guard let (_, other) = try FriendlyFixtures.openEditor(t, config: config, from: "DefaultSkins"),
                      let skin = other.skin else { continue }
                for name in skin.meters.map(\.name) + skin.measures.map(\.name) {
                    other.select(section: name)
                    for text in texts(other.inspectorStack) {
                        if let word = EditorSchema.engineWord(in: text) { t.check(false, "\(config) \(name): “\(text)” says \(word)") }
                    }
                }
                other.window?.close()
            }
        }
    }
}
