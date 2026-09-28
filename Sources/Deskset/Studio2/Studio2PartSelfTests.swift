import AppKit
import DesksetCore

/// The new Studio's part page: what it says (named by its data, the way back, the scope sentence), its twelve
/// controls; the scope sentence widening a change to a style (and its Rainmeter-details wording); the walkthroughs of
/// the design's part tasks with their steps counted (a part's text size, what a part shows, hiding or moving a part);
/// the number fields' shortcuts; Every Setting (its filter by Rainmeter names, remembered per kind); "what it draws";
/// the first click passing over a part that draws nothing; the confirmation depth rules; going back up; no engine
/// words.
enum Studio2PartSelfTests {
    static func run(_ t: AppTestRunner) {
        pageTests(t)
        scopeTests(t)
        walkthroughTests(t)
        numberTests(t)
        everySettingTests(t)
        drawsTests(t)
        selectionTests(t)
        confirmationTests(t)
        wordTests(t)
    }

    typealias Steps = Studio2PageSelfTests.Steps

    /// A designed screen's widget, nothing selected (the tests click what they need).
    static func open(_ t: AppTestRunner, _ name: String, edits: [StudioScreen.FileEdit] = []) -> StudioSnapshot.Opened? {
        guard var screen = StudioScreen.named(name) else {
            t.check(false, "\(name) is a screen")
            return nil
        }
        screen.selection = nil
        screen.everySetting = false
        screen.scopeHover = false
        screen.distances = false
        screen.scrubbing = nil
        screen.colorPopover = nil
        screen.edits += edits
        StudioPartPage.rememberedInMemory = []
        guard let opened = StudioSnapshot.open(screen) else {
            t.check(false, "\(name) opens")
            return nil
        }
        return opened
    }

    static func file(_ opened: StudioSnapshot.Opened, _ path: String) -> URL {
        opened.root.appendingPathComponent("Skins").appendingPathComponent(path)
    }

    static func data(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
    static func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// The block of `section` in an INI text (up to the next section).
    static func block(_ section: String, in text: String) -> String {
        guard let start = text.range(of: "[\(section)]") else { return "" }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n[")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// A click on a part where the canvas draws it (its middle).
    static func click(_ studio: StudioWindowController, _ name: String) {
        guard let m = studio.skin?.meter(named: name) else { return }
        studio.canvasController.canvas.click(skinX: m.frame.x + m.frame.width / 2, y: m.frame.y + m.frame.height / 2)
    }

    static func rowView(_ studio: StudioWindowController, _ id: String) -> StudioRowView? {
        studio.inspectorController.pageView.itemView(id) as? StudioRowView
    }

    // MARK: The page

    static func pageTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: the page of a number") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "04-part") else { return }
            defer { opened.close() }
            let studio = opened.controller
            click(studio, "MeterCPUValue")
            t.equal(studio.canvasController.canvas.selectedNames, ["MeterCPUValue"])
            guard let page = studio.partPage.page else { return t.check(false, "a part page") }
            t.equal(page.title, "CPU usage", "named by its data")
            t.equal(page.crumbs, ["System", "CPU"], "the way back")
            t.check(page.subtitle.hasPrefix("Now 21%"), page.subtitle)
            t.equal(page.scope?.text, "This number only")
            t.equal(page.scope?.link, "Apply to All 4 Numbers")
            t.equal(page.sections.map(\.id), ["shows", "text", "layout", "clicks"])
            t.equal(page.section("text")?.items.map(\.id),
                    ["text.style", "text.font", "text.size", "text.weight", "text.color", "text.align"])
            t.check(page.controlCount <= StudioPage.controlLimit,
                    "\(page.controlCount) controls (at most \(StudioPage.controlLimit))")
            t.equal(page.footer.map(\.id), ["every-setting", "show-in-code"])
            t.check(page.footer.first?.detail.hasSuffix("more") == true, page.footer.first?.detail ?? "")
            if case .row(let row)? = page.item("text.color")?.kind, case .colorLabel(let c) = row.control {
                t.equal(c.title, "Text color")
                t.equal(c.note, "follows Light / Dark")
            } else {
                t.check(false, "the color row")
            }
            if case .row(let row)? = page.item("text.size")?.kind, case .number(let n) = row.control {
                t.equal(n.text, "15", "the size as it shows on screen (FontSize 11.25 at 96 dpi)")
                t.check(n.steppers, "A− / A+ beside it")
            } else {
                t.check(false, "the size row")
            }
            // The canvas names the selection by its data.
            if let m = studio.skin?.meter(named: "MeterCPUValue") {
                t.equal(studio.canvasController.canvas.selectionTag?(m), "CPU usage")
            }
            // The crumb back to the widget.
            studio.pageEvent(.crumb(0))
            t.equal(studio.partPage.focus, nil)
            t.equal(studio.canvasController.canvas.selectedNames, [])
            t.equal(studio.inspectorController.pageView.page?.id, "widget", "the widget page again")
        }

        t.suite("Studio2: part: the pages of other kinds") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "09-every-setting") else { return }
            defer { opened.close() }
            let studio = opened.controller
            for (name, kind, sections) in [
                ("MeterLabel", StudioPartKind.text, ["shows", "text", "layout", "clicks"]),
                ("MeterIcon", .symbol, ["shows", "look", "layout", "clicks"]),
                ("MeterBar", .shape, ["shape", "stroke", "layout", "clicks"]),
            ] {
                studio.select(part: name)
                guard let m = studio.skin?.meter(named: name), let page = studio.partPage.page else {
                    t.check(false, "\(name): a page")
                    continue
                }
                t.equal(StudioPartKind(m), kind, name)
                t.equal(page.sections.map(\.id), sections, name)
                t.check(page.controlCount <= StudioPage.controlLimit, "\(name): \(page.controlCount) controls")
            }
            // The shape's kind in compatibility mode: ShapeSpec keeps what it does not change.
            studio.select(part: "MeterBar")
            let cpu = file(opened, "CPU/CPU.ini")
            let before = data(cpu)
            studio.pageEvent(.number(item: "shape.corners", part: 0, change: .typed("5")))
            t.check(block("MeterBar", in: text(cpu)).contains("Shape=Rectangle 16,114,138,6,5 | Fill Color #Track# | StrokeWidth 0"),
                    block("MeterBar", in: text(cpu)))
            studio.session?.undoStack.undo()
            t.equal(data(cpu), before, "undone byte for byte")
            // A data item's page: who uses it; pointing at one outlines it.
            studio.partPage.show(data: "MeasureCPU")
            t.equal(studio.partPage.page?.title, "CPU usage")
            let used = studio.partPage.page?.section("used")?.items.map(\.id) ?? []
            t.check(used.contains("used:MeterValue"), "\(used)")
            studio.pageEvent(.hoverItem(item: "used:MeterValue", inside: true))
            t.equal(studio.canvasController.overlay.frames?.names, ["MeterValue"])
            studio.pageEvent(.link("used:MeterValue"))
            t.equal(studio.partPage.focus, .part("MeterValue"), "a user's link selects it")
        }
    }

    // MARK: Scope

    static func scopeTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: the scope sentence") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "04-part") else { return }
            defer { opened.close() }
            let studio = opened.controller
            let medium = file(opened, "Stationery/System/Medium.ini")
            let before = data(medium)
            click(studio, "MeterCPUValue")
            // Pointing at the link outlines the three other numbers, and says why.
            studio.pageEvent(.scopeHover(true))
            let reach = studio.canvasController.overlay.reach
            t.equal(Set(reach?.names ?? []), ["MeterMemValue", "MeterDiskValue", "MeterGPUValue"])
            t.equal(reach?.sentence, "4 numbers share one style")
            t.equal(studio.partPage.page?.scope?.linkHovered, true)
            studio.pageEvent(.scopeHover(false))
            t.check(studio.canvasController.overlay.reach == nil, "gone when the pointer leaves")
            // Rainmeter details: where it is written.
            studio.app.state.updateEditor { $0.showIniNames = true }
            studio.partPage.refresh()
            t.equal(studio.partPage.page?.scope?.text, "Only [MeterCPUValue] · shared style sMetricS (5 meters)")
            studio.app.state.updateEditor { $0.showIniNames = false }
            // Widened: a change goes to the style, for this widget (an override block in its own file).
            studio.pageEvent(.scopeLink)
            t.equal(studio.partPage.page?.scope?.text, "All 4 numbers")
            t.check(studio.partPage.page?.scope?.link?.hasPrefix("All ") == true, "then the suite's file")
            studio.pageEvent(.number(item: "text.size", part: 0, change: .step(1)))
            let written = text(medium)
            t.check(block("sMetricS", in: written).contains("FontSize=12"), "the style, in the widget's own file")
            t.check(!block("MeterCPUValue", in: written).contains("FontSize"), "not the part itself")
            t.check(AppSelfTest.spin {
                (studio.skin?.meter(named: "MeterMemValue") as? StringMeter)?.style.fontSize == 12
            }, "the other numbers follow")
            studio.session?.undoStack.undo()
            t.equal(data(medium), before, "undone byte for byte")
            // Narrowed again from the last scope.
            studio.pageEvent(.scopeLink)
            studio.pageEvent(.scopeLink)
            t.equal(studio.partPage.scopeLevel, 0, "back to this number only")
        }
    }

    // MARK: Walkthroughs

    static func walkthroughTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: T1.4 a part's text size in five steps") {
            Studio2SelfTests.prepare(t)
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            // 1–2: the widget's menu ▸ Customize Look….
            steps.take(2) { opened = open(t, "04-part") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller
            guard let session = studio.session else { return t.check(false, "a session") }
            let medium = file(opened, "Stationery/System/Medium.ini")
            let before = data(medium)
            // 3: the number on the canvas.
            steps.take { click(studio, "MeterCPUValue") }
            // 4: A+.
            guard let row = rowView(studio, "text.size"), let buttons = row.steppers else {
                return t.check(false, "the size row and A+")
            }
            steps.take { buttons.bigger.performClick(nil) }
            // At the Customize depth, a confirmation under the size.
            t.check(studio.inspectorController.pageView.itemView("text.confirm") != nil, "confirmed under the control")
            t.equal(session.undoStack.undoActionName, "Text Size")
            // 5: Done.
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 5, "T1.4 in \(steps.count) steps (at most 5)")
            t.check(block("MeterCPUValue", in: text(medium)).contains("FontSize=12"), "16 pt: FontSize 12, its own")
            session.undoStack.undo()
            t.equal(data(medium), before, "undone byte for byte")
        }

        t.suite("Studio2: part: T1.6 a part switched to other data") {
            Studio2SelfTests.prepare(t)
            let memory = StudioScreen.FileEdit(path: "CPU.ini", find: "[MeterCard]",
                                               replace: "[MeasureMemory]\nMeasure=PhysicalMemory\n\n[MeterCard]")
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "09-every-setting", edits: [memory]) }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller
            let cpu = file(opened, "CPU/CPU.ini")
            let before = data(cpu)
            steps.take { click(studio, "MeterValue") }
            steps.take { studio.pageEvent(.tokenData(item: "shows.token")) }
            steps.take { studio.partPage.chooseData("MeasureMemory") }
            t.check(block("MeterValue", in: text(cpu)).contains("MeasureName=MeasureMemory"), "written in the part")
            t.equal(studio.partPage.page?.title, "Memory used", "named by its new data")
            let session = studio.session
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 6, "T1.6 in \(steps.count) steps (at most 6)")
            session?.undoStack.undo()
            t.equal(data(cpu), before, "undone byte for byte")
        }

        t.suite("Studio2: part: T1.7 move a part in five steps") {
            Studio2SelfTests.prepare(t)
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "04-part") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller, canvas = studio.canvasController.canvas
            let medium = file(opened, "Stationery/System/Medium.ini")
            let before = data(medium)
            guard let m = studio.skin?.meter(named: "MeterCPUValue") else { return t.check(false, "the number") }
            let start = canvas.viewRect(m.frame)
            let p = NSPoint(x: start.midX, y: start.midY)
            // 3: press on it (it is selected), 4: drag it 10 points right and let go.
            steps.take { click(studio, "MeterCPUValue") }
            steps.take {
                canvas.beginGesture(.move, at: p)
                canvas.drag(to: NSPoint(x: p.x + 10, y: p.y), snapping: false)
                canvas.endGesture(keep: true)
            }
            let moved = block("MeterCPUValue", in: text(medium)).replacingOccurrences(of: "\n", with: " / ")
            t.check(moved.contains("X=67 "), "57 + 10, written as it was: \(moved)")
            t.check(moved.contains("Y=(130 - #Ascent15#) "), "Y as it was written: \(moved)")
            // A change on the canvas: confirmed at the top of the inspector.
            t.check(studio.partPage.page?.topConfirmation?.text.hasPrefix("Moved") == true,
                    studio.partPage.page?.topConfirmation?.text ?? "no top confirmation")
            t.check(studio.inspectorController.pageView.topConfirmation != nil, "drawn at the top")
            let session = studio.session
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 5, "T1.7 in \(steps.count) steps (at most 5)")
            session?.undoStack.undo()
            t.equal(data(medium), before, "undone byte for byte")
        }

        t.suite("Studio2: part: T1.7 hide a part in five steps") {
            Studio2SelfTests.prepare(t)
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "04-part") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller
            let medium = file(opened, "Stationery/System/Medium.ini")
            let before = data(medium)
            guard let m = studio.skin?.meter(named: "MeterCPULabel") else { return t.check(false, "the label") }
            // 3: Control-click the part, 4: Hide.
            var menu: NSMenu?
            steps.take { menu = studio.contextMenu(x: m.frame.x + m.frame.width / 2, y: m.frame.y + m.frame.height / 2) }
            guard let item = menu?.items.first else { return t.check(false, "the part's menu") }
            t.equal(item.title, "Hide “CPU”")
            steps.take { menu?.performActionForItem(at: 0) }
            t.check(block("MeterCPULabel", in: text(medium)).contains("Hidden=1"), "hidden, its own")
            t.equal(studio.skin?.meter(named: "MeterCPULabel")?.hidden, true)
            t.check(studio.widgetPage.page?.topConfirmation?.text == "“CPU” is hidden",
                    studio.widgetPage.page?.topConfirmation?.text ?? "no confirmation: it cannot be seen any more")
            let session = studio.session
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 5, "T1.7 in \(steps.count) steps (at most 5)")
            session?.undoStack.undo()
            t.equal(data(medium), before, "undone byte for byte")
        }
    }

    // MARK: Numbers

    static func numberTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: number fields") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "09-every-setting") else { return }
            defer { opened.close() }
            let studio = opened.controller
            guard let session = studio.session else { return t.check(false, "a session") }
            let cpu = file(opened, "CPU/CPU.ini")
            let before = data(cpu)
            click(studio, "MeterValue")
            guard let row = rowView(studio, "text.size"), let box = row.numberBox else { return t.check(false, "the size") }
            // 40 in the file is 53.3 on screen.
            t.equal(box.number.text, "53.5")
            // Dragging the label: a live preview, no step; one step on release.
            row.scrubArea.drag(by: 20, done: false)
            t.equal((studio.skin?.meter(named: "MeterValue") as? StringMeter)?.style.fontSize, 47.5,
                    "previewed: 53.3 + 10 pt = 63.3 pt, FontSize 47.5")
            t.equal(data(cpu), before, "nothing written while dragging")
            t.equal(session.undoStack.canUndo, false)
            row.scrubArea.drag(by: 20, done: true)
            t.check(block("MeterValue", in: text(cpu)).contains("FontSize=47.5"), block("MeterValue", in: text(cpu)))
            t.equal(session.undoStack.undoActionName, "Text Size", "one step")
            session.undoStack.undo()
            t.equal(data(cpu), before)
            // Arithmetic: 15+2 is 17 pt.
            rowView(studio, "text.size")?.numberBox?.type("15+2")
            t.check(block("MeterValue", in: text(cpu)).contains("FontSize=12.75"), "17 pt: FontSize 12.75")
            session.undoStack.undo()
            // Arrows: ±1, ⇧ ±10.
            rowView(studio, "text.size")?.numberBox?.pressArrow(up: true, shift: true)
            t.check(block("MeterValue", in: text(cpu)).contains("FontSize=47.25"), "63 pt: FontSize 47.25")
            session.undoStack.undo()
            rowView(studio, "text.size")?.numberBox?.pressArrow(up: false)
            t.check(block("MeterValue", in: text(cpu)).contains("FontSize=39"), "52 pt: FontSize 39")
            session.undoStack.undo()
            t.equal(data(cpu), before)
            // ⌥-click on the label: its default (the value goes).
            rowView(studio, "text.size")?.scrubArea.onChange?(.reset)
            t.check(!block("MeterValue", in: text(cpu)).contains("FontSize"), "back to the default")
            session.undoStack.undo()
            t.equal(data(cpu), before)
            // X keeps how it is written; a relative one stays relative.
            rowView(studio, "layout.x")?.scrubArea.drag(by: 8, done: true)
            t.check(block("MeterValue", in: text(cpu)).contains("X=18"), "14 + 4")
            session.undoStack.undo()
            rowView(studio, "layout.x")?.numberBox?.type("10R")
            t.check(block("MeterValue", in: text(cpu)).contains("X=10R"), "typed notation kept")
            if case .row(let r)? = studio.partPage.page?.item("layout.x")?.kind, case .number(let n) = r.control {
                t.equal(n.meaning, "after “CPU”", "what 10R means")
            }
            rowView(studio, "layout.x")?.numberBox?.pressArrow(up: true, shift: true)
            t.check(block("MeterValue", in: text(cpu)).contains("X=20R"), "10R + 10 = 20R")
            session.undoStack.undo()
            session.undoStack.undo()
            t.equal(data(cpu), before)
            t.equal(StudioNumberInput.evaluate("15+2"), 17)
            t.equal(StudioNumberInput.evaluate("(10 + 4) * 2"), 28)
            t.equal(StudioNumberInput.evaluate("#Gap# + 2"), nil, "a variable is not worked out")
            t.equal(StudioNumberInput.text(12.75), "12.75")
        }
    }

    // MARK: Every Setting

    static func everySettingTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: Every Setting") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "09-every-setting") else { return }
            defer { opened.close() }
            let studio = opened.controller
            click(studio, "MeterValue")
            t.check(studio.partPage.page?.id.hasPrefix("part:") == true)
            studio.partPage.toggleEverySetting()
            guard let page = studio.partPage.page else { return t.check(false, "a page") }
            t.check(page.id.hasPrefix("every:"), page.id)
            t.equal(page.sections.first?.id, "every.content", "in the order of the box")
            let order = page.sections.map(\.id)
            let expected = ["every.content", "every.text", "every.look", "every.layout", "every.box", "every.pointer",
                            "every.spoken"].filter { order.contains($0) }
            t.equal(order, expected)
            t.check(page.item("every.box") != nil, "the box diagram")
            t.equal(page.filter?.placeholder, "Filter these settings")
            // Filtering by a Rainmeter name keeps the row it maps to, and says so.
            studio.pageEvent(.filter("FontColor"))
            guard case .dense(let color)? = studio.partPage.page?.item("every:FontColor")?.kind else {
                return t.check(false, "the Color row stays")
            }
            t.equal(color.label, "Color")
            t.equal(color.note, "Color · Rainmeter: FontColor")
            studio.pageEvent(.filter(""))
            // Remembered per kind: another number opens on Every Setting; a text on its page.
            t.check(StudioPartPage.remembers(.number))
            studio.select(part: "MeterLabel")
            t.check(studio.partPage.page?.id.hasPrefix("part:") == true, "a text: its page")
            studio.select(part: "MeterValue")
            t.check(studio.partPage.page?.id.hasPrefix("every:") == true, "a number: Every Setting again")
            // Esc: back to the part's page, then to the widget.
            studio.goUp()
            t.check(studio.partPage.page?.id.hasPrefix("part:") == true, "Esc: the part's page")
            t.check(!StudioPartPage.remembers(.number), "and no longer remembered")
            studio.goUp()
            t.equal(studio.partPage.focus, nil, "Esc again: the widget")
            // ⌥⌘E on the canvas.
            click(studio, "MeterValue")
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e",
                                       isARepeat: false, keyCode: 14)
            if let key { t.check(studio.keyEquivalent(key), "⌥⌘E is taken") }
            t.check(studio.partPage.page?.id.hasPrefix("every:") == true, "⌥⌘E: Every Setting")
            StudioPartPage.rememberedInMemory = []
        }
    }

    // MARK: What it draws

    static func drawsTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: what it draws") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "09-every-setting") else { return }
            defer { opened.close() }
            let studio = opened.controller, overlay = studio.canvasController.overlay
            guard let skin = studio.skin else { return t.check(false, "the widget") }
            click(studio, "MeterValue")
            studio.pageEvent(.hoverItem(item: "text.color", inside: true))
            t.equal(overlay.frames?.names, ["MeterValue"])
            t.equal(overlay.frames?.tag, "CPU usage")
            // The CPU card is blue: graphite, not the (blue) accent.
            let blue = NSColor(srgbRed: 0, green: 122 / 255, blue: 1, alpha: 1)
            t.equal(StudioCanvasOverlay.ink(for: skin, accent: blue), .graphite)
            let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            t.equal(StudioCanvasOverlay.ink(for: skin, accent: magenta), .accent, "no color near it: the accent")
            // A popover opening clears it at once.
            studio.pageEvent(.swatch(item: "text.color", swatch: "text.color"))
            t.check(studio.partPage.colorPopover != nil, "the color popover")
            t.equal(overlay.frames, nil)
            studio.partPage.closePopover()
            studio.pageEvent(.hoverItem(item: "text.color", inside: false))
            t.equal(overlay.frames, nil, "gone when the pointer leaves")
            // ⌥ held: the distances to the neighbours and the card's edges.
            studio.optionChanged(true)
            t.check(overlay.showsDistances)
            let values = overlay.distances().map { Int($0.value.rounded()) }
            t.check(values.contains(14), "14 to the card's left edge: \(values)")
            studio.optionChanged(false)
            t.check(!overlay.showsDistances)
        }
    }

    // MARK: Selection

    static func selectionTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: the first click passes over a part that draws nothing") {
            Studio2SelfTests.prepare(t)
            let hitArea = StudioScreen.FileEdit(path: "CPU.ini", find: "[MeterCaption]", replace: """
                [MeterHitArea]
                Meter=Image
                SolidColor=0,0,0,1
                X=0
                Y=0
                W=170
                H=170
                LeftMouseUpAction=[!Refresh]

                [MeterCaption]
                """)
            guard let opened = open(t, "09-every-setting", edits: [hitArea]) else { return }
            defer { opened.close() }
            let studio = opened.controller, canvas = studio.canvasController.canvas
            guard let value = studio.skin?.meter(named: "MeterValue") else { return t.check(false, "the number") }
            let x = value.frame.x + value.frame.width / 2, y = value.frame.y + value.frame.height / 2
            canvas.click(skinX: x, y: y)
            t.equal(canvas.selectedNames, ["MeterValue"], "the number, not the area laid over it")
            // Without the rule (the old canvas): the area takes it.
            let rule = canvas.hitFilter
            canvas.hitFilter = nil
            t.equal(canvas.pickableMeter(atSkinX: x, y)?.name, "MeterHitArea", "the canvas's default is unchanged")
            canvas.hitFilter = rule
            // ⇧Return: one level up.
            let shiftReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                               windowNumber: 0, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let shiftReturn, let container = studio.canvasController.view as? StudioCanvasContainer {
                t.check(container.onKeyDown?(shiftReturn) == true, "⇧Return is taken")
            }
            t.equal(canvas.selectedNames, [], "⇧Return: the widget")
            t.equal(studio.partPage.focus, nil)
        }
    }

    // MARK: Confirmations

    static func confirmationTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: confirmations by depth") {
            Studio2SelfTests.prepare(t)
            typealias R = StudioConfirmRule
            t.equal(R.place(depth: .customize, change: .value, fromCanvas: false), .underControl)
            t.equal(R.place(depth: .customize, change: .value, fromCanvas: true), .top)
            t.equal(R.place(depth: .build, change: .value, fromCanvas: false), nil, "Build: one value stays quiet")
            t.equal(R.place(depth: .build, change: .value, fromCanvas: true), nil)
            t.equal(R.place(depth: .build, change: .beyondSelection, fromCanvas: false), .underControl)
            t.equal(R.place(depth: .build, change: .invisible, fromCanvas: true), .top)
            t.equal(R.place(depth: .build, change: .revert, fromCanvas: false), .underControl)
            guard let opened = open(t, "04-part") else { return }
            defer { opened.close() }
            let studio = opened.controller
            studio.setSidebarOpen(true)
            click(studio, "MeterCPUValue")
            studio.pageEvent(.number(item: "text.size", part: 0, change: .step(1)))
            t.equal(studio.partPage.confirmation == nil, true, "Build: a value of the part is quiet")
            studio.session?.undoStack.undo()
            studio.pageEvent(.scopeLink)
            studio.pageEvent(.number(item: "text.size", part: 0, change: .step(1)))
            t.check(studio.partPage.confirmation != nil, "Build: a change to all four numbers is confirmed")
            studio.session?.undoStack.undo()
            t.equal(studio.partPage.confirmation == nil, true, "gone with its step")
        }
    }

    // MARK: Words

    static func wordTests(_ t: AppTestRunner) {
        t.suite("Studio2: part: no engine words") {
            Studio2SelfTests.prepare(t)
            for language in [StudioLanguage.english, .chinese] {
                StudioText.languageOverride = language
                defer { StudioText.languageOverride = .english }
                guard let opened = open(t, "04-part") else { continue }
                defer { opened.close() }
                let studio = opened.controller
                click(studio, "MeterCPUValue")
                let view = studio.inspectorController.pageView
                // X and Y are shown as the file writes them (the design's notation pills): left out.
                var text = ""
                for sub in view.subviews where sub !== view.itemView("layout.x") && sub !== view.itemView("layout.y") {
                    text += " " + Studio2PageSelfTests.words(in: sub)
                }
                let found = Studio2PageSelfTests.engineWords(in: text, chinese: language == .chinese)
                t.equal(found, [], "\(language.rawValue): \(found)")
            }
        }
    }
}
