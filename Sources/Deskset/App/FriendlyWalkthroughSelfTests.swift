import AppKit
import DesksetCore

/// `Deskset --self-test "Friendly walkthrough"`: the ten walkthrough tasks of docs/editor-friendly.md §13, done the
/// way a first-time user would on temporary copies of Visualizer and System, each checked against its outcome, and
/// each step's control reachable without opening a disclosure (§14.5, integration). Also the G3 scan: no engine words
/// in any default state of Visualizer, System and Clock.
enum FriendlyWalkthroughSelfTests {
    static func run(_ t: AppTestRunner) {
        visualizerWalkthrough(t)
        systemWalkthrough(t)
        plainWordsScan(t)
    }

    typealias Editor = InspectorWindowController

    // MARK: Helpers

    /// Ends the current event: the undo manager groups what one event registers (as in the app).
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// The text of one section of a file (up to the next header).
    static func section(_ name: String, in text: String) -> String {
        guard let r = text.range(of: "[\(name)]") else { return "" }
        let rest = text[r.upperBound...]
        return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
    }

    /// A control a first-time user can reach: on the page as it opens, with no disclosure opened (its section of
    /// the page is not folded away), not hidden. Nil — and a failed check naming the step — otherwise.
    static func reach(_ t: AppTestRunner, _ editor: Editor, _ id: String, _ step: String, line: UInt = #line) -> NSView? {
        let root = editor.window?.contentView ?? editor.inspectorStack
        guard let view = root.findSubview(where: { $0.identifier?.rawValue == id }) else {
            t.check(false, "\(step): “\(id)” is on the page", line: line)
            return nil
        }
        t.check(!view.isHiddenOrHasHiddenAncestor, "\(step): “\(id)” is shown", line: line)
        return view
    }

    /// The disclosures of the page the user opened (none: the walkthrough never opens one).
    static func openedDisclosures(_ editor: Editor) -> [String] {
        editor.inspectorState.disclosures.filter { $0.hasPrefix("open/") }.sorted()
    }

    /// The widget page's color row of a shared color.
    static func colorRow(_ editor: Editor, variable: String) -> ValueRowView? {
        editor.inspectorStack.subviewsMatching { ($0 as? ValueRowView)?.group?.variables.contains(variable) == true }.first
            as? ValueRowView
    }

    /// Clicks a layer on the canvas (at its centre, or at an offset from its top-left corner).
    static func click(_ editor: Editor, _ name: String, at offset: (x: Double, y: Double)? = nil) {
        guard let f = editor.skin?.meter(named: name)?.frame else { return }
        let p = offset.map { (f.x + $0.x, f.y + $0.y) } ?? (f.x + f.width / 2, f.y + f.height / 2)
        editor.canvas.click(skinX: p.0, y: p.1)
    }

    static func doubleClick(_ editor: Editor, _ name: String) {
        guard let f = editor.skin?.meter(named: name)?.frame else { return }
        editor.canvas.doubleClick(skinX: f.x + f.width / 2, y: f.y + f.height / 2)
    }

    /// Chooses a pop-up's item as a click would.
    @discardableResult
    static func choose(_ popup: NSPopUpButton?, where match: (NSMenuItem) -> Bool) -> Bool {
        guard let popup, let item = popup.itemArray.first(where: match) else { return false }
        popup.select(item)
        popup.sendAction(popup.action, to: popup.target)
        return true
    }

    /// Runs a menu item as a click would (a closure item, or a pop-up's item by its represented object).
    static func perform(_ item: NSMenuItem?) -> Bool {
        guard let item, let target = item.target, let action = item.action else { return false }
        _ = target.perform(action, with: item)
        return true
    }

    // MARK: The ten tasks (§13), on the Visualizer

    static func visualizerWalkthrough(_ t: AppTestRunner) {
        t.suite("App: friendly walkthrough: the ten tasks on the Visualizer") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let ini = editor.skin?.fileURL else { return }
            func skin() -> Skin? { app.controller(for: "Audio\\Visualizer")?.skin }
            let bands = (0..<16).map { "MeterBand\($0)" }
            let original = read(ini)

            // 1. Change the accent colour everywhere. The editor opens with nothing selected; COLORS AND FONTS is the
            // first card, its first row "Bar color · 18 bars".
            editor.selectSidebarTab(.layers)
            editor.canvasSelectionChanged([])
            let cards = editor.inspectorStack.subviewsMatching { $0.identifier?.rawValue.hasPrefix("card:") == true }
            t.equal(cards.first?.identifier?.rawValue, "card:COLORS AND FONTS", "task 1: colors come first")
            guard let accent = colorRow(editor, variable: "Accent"), let group = accent.group else {
                return t.check(false, "task 1: the Bar color row")
            }
            t.equal(group.role, "Bar color")
            t.check(!accent.isHiddenOrHasHiddenAncestor, "task 1: the row is on the page as it opens")
            let count = accent.findSubview { $0.identifier?.rawValue.hasPrefix("color-count:") == true } as? NSButton
            t.equal(count?.title, "18 bars", "task 1: its reach")
            accent.onHover?(true)
            t.equal(editor.canvas.relatedNames.count, 18, "task 1: pointing at it outlines the 18 bars")
            accent.onHover?(false)
            // The swatch's menu ▸ Custom Color… (the color panel, previewed live), then the panel closes.
            t.check(accent.findSubview { $0.identifier?.rawValue.hasPrefix("color-swatch:") == true } is SwatchButton, "the swatch")
            t.check(perform(editor.colorRowMenu(group).items.first { $0.title == "Custom Color…" }), "task 1: Custom Color…")
            let red = RGBA(r: 255, g: 64, b: 64, a: 255)
            editor.previewColorEdit(red)
            func barColor(_ name: String) -> RGBA? { (skin()?.meter(named: name) as? BarMeter)?.barColor }
            t.equal(barColor("MeterBand9"), red, "task 1: previewed live")
            editor.commitColorEdit()
            let users = bands + ["MeterLeft", "MeterRight"]
            t.equal(users.filter { barColor($0) == red }.count, 18, "task 1: 18 bars changed")
            t.check(section("Variables", in: read(ini)).contains("Accent=255,64,64,255\n"), "task 1: the shared color")
            t.equal(editor.toastText, "Bar color changed on 18 bars")
            t.check(editor.toastActions.map(\.title).contains("Undo"), "task 1: the toast has Undo")
            settle()

            // 9. Undo a mistake: the toolbar's ↶ names the step, and takes it back.
            t.equal(editor.undoToolbarTip(undo: true), "Undo Change Bar Color", "task 9: ↶ names the step")
            editor.undoClicked(nil)
            t.equal(read(ini), original, "task 9: undone")
            t.equal(editor.toastText, "Undid Change Bar Color")
            t.equal(editor.toastActions.map(\.title), ["Redo"])
            settle()

            // 2. Make the title bigger and change its font: click "Audio" on the canvas; TEXT is the first card.
            click(editor, "MeterTitle")
            t.equal(editor.selectedSection, "MeterTitle", "task 2: the click selects the title")
            let pageCards = editor.inspectorStack.subviewsMatching { $0.identifier?.rawValue.hasPrefix("card-") == true }
            t.equal(pageCards.first?.identifier?.rawValue, "card-Text", "task 2: TEXT comes first")
            let before2 = read(ini)
            guard let size = reach(t, editor, "MeterTitle/FontSize", "task 2") as? ValueField else { return }
            size.type("14")
            settle()
            let families = InspectorWindowController.fontFamilies.map(\.name)
            let avenir = families.first { $0 == "Avenir" } ?? families.first { $0.hasPrefix("Avenir") } ?? "Helvetica"
            let face = reach(t, editor, "FontFace", "task 2") as? FontPopUpButton
            // Opening the menu lists every font (each in itself).
            if let face, let menu = face.menu { face.menuNeedsUpdate(menu) }
            t.check(choose(face) { ($0.representedObject as? String) == avenir }, "task 2: Font ▾ \(avenir)")
            settle()
            let title = section("MeterTitle", in: read(ini))
            t.check(title.contains("FontSize=14\n") && title.contains("FontFace=\(avenir)\n"), "task 2: \(title)")
            t.equal((skin()?.meter(named: "MeterTitle") as? StringMeter)?.style.fontSize, 14, "task 2: bigger on the canvas")
            // Nothing else changed: the title only.
            t.equal(read(ini).replacingOccurrences(of: title, with: ""), before2.replacingOccurrences(of: section("MeterTitle", in: before2), with: ""),
                    "task 2: only the title changed")
            editor.window?.undoManager?.undo()
            settle()
            editor.window?.undoManager?.undo()
            settle()
            t.equal(read(ini), original, "task 2: two undo steps")

            // 3. Find the speaker name and hide it: its row, with its picture, named by what it says.
            editor.selectSidebarTab(.layers)
            guard let device = editor.listItems.first(where: { $0.title == "MeterDevice" }) else {
                return t.check(false, "task 3: the device row")
            }
            t.equal(device.display, "“MacBook Pro扬声器”")
            t.equal(device.subtitle, "Text · output device name")
            let deviceCell = FriendlySidebarSelfTests.cell(editor, device)
            t.check(deviceCell?.thumbnail.image != nil, "task 3: the row has a picture")
            FriendlySidebarSelfTests.rowView(editor, device)?.setHovered(true)
            t.equal(editor.canvas.hoverHighlight, ["MeterDevice"], "task 3: pointing at the row outlines it")
            guard let eye = deviceCell?.eye else { return t.check(false, "task 3: the row's eye") }
            t.check(!eye.isHidden, "task 3: the eye shows under the pointer")
            editor.eyeClicked(eye)
            FriendlySidebarSelfTests.rowView(editor, editor.listItems.first { $0.title == "MeterDevice" })?.setHovered(false)
            t.check(section("MeterDevice", in: read(ini)).contains("Hidden=1\n"), "task 3: Hidden=1 on MeterDevice")
            t.equal(editor.toastText, "Hid “MacBook Pro扬声器”")
            t.check(editor.toastActions.map(\.title).contains("Undo"), "task 3: with Undo")
            t.equal(FriendlySidebarSelfTests.cell(editor, editor.listItems.first { $0.title == "MeterDevice" })?.isLayerHidden, true,
                    "task 3: the row shows it is hidden")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // Typing in Find a layer finds it too.
            editor.setSidebarSearch("MacBook")
            t.equal(editor.listItems.filter { !$0.isSkin }.map(\.title), ["MeterDevice"], "task 3: Find finds it")
            editor.setSidebarSearch("")

            // 4. Move the frequency labels up a little: click "48 Hz", ↑ three times; "13268 Hz" follows.
            click(editor, "MeterLowFreq")
            t.equal(editor.selectedSection, "MeterLowFreq")
            let highBefore = skin()?.meter(named: "MeterHighFreq")?.frame.y ?? 0
            editor.nudge(dx: 0, dy: -1)
            t.check(editor.canvas.followers.keys.contains { $0.caseInsensitiveCompare("MeterHighFreq") == .orderedSame },
                    "task 4: “13268 Hz” is outlined as a follower: \(editor.canvas.followers)")
            editor.nudge(dx: 0, dy: -1)
            editor.nudge(dx: 0, dy: -1)
            editor.commitPendingNudge()
            settle()
            t.check(section("MeterLowFreq", in: read(ini)).contains("Y=(36 + #BarH# + 1)\n"), "task 4: the calculation kept")
            t.equal(skin()?.meter(named: "MeterHighFreq")?.frame.y, highBefore - 3, "task 4: “13268 Hz” moved with it")
            t.check(section("MeterHighFreq", in: read(ini)).contains("Y=0r\n"), "task 4: and still follows it")
            editor.select(section: "MeterLowFreq")
            t.equal((reach(t, editor, "MeterLowFreq/Y/tag", "task 4") as? NSPopUpButton)?.title, "calculated")
            editor.window?.undoManager?.undo()
            settle()
            t.equal(read(ini), original, "task 4: one undo step")

            // 5. Change what a bar shows: a click selects the 16 bars, a double-click the 4th; Shows ▾ ▸ Band 6.
            click(editor, "MeterBand3")
            t.equal(editor.canvas.selectedNames, bands, "task 5: the first click selects the group")
            t.equal((reach(t, editor, "strip-title", "task 5") as? NSTextField)?.stringValue, "16 bars")
            doubleClick(editor, "MeterBand3")
            t.equal(editor.canvas.selectedNames, ["MeterBand3"], "task 5: a double-click, one bar")
            t.equal((reach(t, editor, "strip-title", "task 5") as? NSTextField)?.stringValue, "Bar 4")
            guard let shows = editor.inspectorControl(for: "MeasureName") as? NSPopUpButton else {
                return t.check(false, "task 5: Shows ▾")
            }
            t.check(!shows.isHiddenOrHasHiddenAncestor, "task 5: Shows is on the page")
            let folded = shows.menu?.items.first { $0.submenu?.items.count == 16 }
            t.equal(folded?.title, "Sound bands", "task 5: the 16 bands in one item")
            t.check(perform(folded?.submenu?.items.first { ($0.representedObject as? String) == "MeasureBand5" }), "task 5: Band 6")
            settle()
            t.check(section("MeterBand3", in: read(ini)).contains("MeasureName=MeasureBand5\n"), "task 5: Bar 4 shows band 6")
            t.equal(editor.window?.undoManager?.undoActionName, "Show Sound Band 6")
            editor.window?.undoManager?.undo()
            settle()
            t.equal(read(ini), original, "task 5: one undo step")

            // 6. Add a clock: "+ Add" opens the Add tab; clicking Clock places it in free space below.
            editor.canvasSelectionChanged([])
            let frames = (skin()?.meters ?? []).filter { !$0.hidden && $0.frame.width > 0 }.map { ($0.name, $0.frame) }
            let bottom = frames.map(\.1.maxY).max() ?? 0
            editor.showLibrary(nil)
            t.equal(editor.sidebarTab, .library, "task 6: + Add opens Add")
            guard let clockCard = editor.libraryView.card(for: "clock") else { return t.check(false, "task 6: the Clock card") }
            t.check(!clockCard.isHiddenOrHasHiddenAncestor, "task 6: the Clock card is shown")
            clockCard.insert()
            settle()
            guard let clock = skin()?.meters.first(where: { m in !frames.contains { $0.0 == m.name } && m.frame.height > 0 }) else {
                return t.check(false, "task 6: a clock")
            }
            t.check(clock.frame.y >= bottom + 8 - 0.5, "task 6: below what is there (\(clock.frame.y) ≥ \(bottom) + 8)")
            let placed = clock.frame
            t.check(!frames.contains { f in
                f.1.x < placed.maxX && placed.x < f.1.maxX && f.1.y < placed.maxY && placed.y < f.1.maxY
            }, "task 6: on nothing else")
            t.check((skin()?.height ?? 0) > 196, "task 6: the widget grew")
            t.equal(editor.toastText, "Added Clock · Widget grew to 217 × \(EditorStyle.number(skin()?.height ?? 0))")
            t.equal(editor.toastActions.map(\.title), ["Stretch Background", "Undo"])
            settle()
            editor.window?.undoManager?.undo()
            settle()
            t.equal(read(ini), original, "task 6: one undo step")
            editor.selectSidebarTab(.layers)

            // 7. Update less often: click the empty canvas (the Background is locked, so it picks the widget).
            click(editor, "MeterBackground", at: (4, 190))
            t.equal(editor.canvas.selectedNames, [], "task 7: the widget page")
            t.check(reach(t, editor, "update-speed", "task 7") is NSPopUpButton)
            t.check(choose(editor.inspectorControl(for: "update-speed") as? NSPopUpButton) { $0.title == "Every second (standard)" },
                    "task 7: Every second")
            t.check(section("Rainmeter", in: read(ini)).contains("Update=1000\n"), "task 7: Update=1000")
            let warning = editor.inspectorStack.findSubview { $0.identifier?.rawValue == "update-warning" }
            t.check(warning?.findSubview { ($0 as? NSTextField)?.stringValue == "The sound bars will move in jumps." } != nil,
                    "task 7: the warning")
            t.equal(editor.toastText, "Now updates every second")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // 8. Keep it on top and stop dragging: ON YOUR DESKTOP, at once, no file written.
            guard let c = editor.controller else { return t.check(false, "task 8: running") }
            let bytes = read(ini)
            guard let stacking = reach(t, editor, "stacking", "task 8") as? NSSegmentedControl else { return }
            stacking.selectedSegment = 2
            stacking.sendAction(stacking.action, to: stacking.target)
            t.equal(c.state.alwaysOnTop, 1, "task 8: always on top")
            t.equal(editor.toastText, "Always on top")
            t.check(editor.toastActions.map(\.title).contains("Undo"))
            settle()
            guard let lock = reach(t, editor, "lock-position", "task 8") as? NSButton else { return }
            lock.state = .on
            lock.sendAction(lock.action, to: lock.target)
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.draggable, false, "task 8: position locked")
            t.equal(editor.toastText, "Position locked")
            t.equal(read(ini), bytes, "task 8: the file is unchanged")
            settle()
            // 9. ⌘Z takes desktop settings back too.
            editor.window?.undoManager?.undo()
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.draggable, true, "task 9: unlocked again")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.alwaysOnTop, -2, "task 9: on the desktop again")
            settle()

            // 10. Find where "Track" is used: the widget page's "Empty part of bars · 18 bars".
            editor.canvasSelectionChanged([])
            guard let track = colorRow(editor, variable: "Track") else { return t.check(false, "task 10: the Track row") }
            t.equal(track.group?.role, "Empty part of bars")
            t.check(!track.isHiddenOrHasHiddenAncestor, "task 10: on the page as it opens")
            track.onHover?(true)
            t.equal(editor.canvas.relatedNames.count, 18, "task 10: pointing outlines them")
            track.onHover?(false)
            guard let trackCount = track.findSubview(where: { $0.identifier?.rawValue.hasPrefix("color-count:") == true }) as? NSButton
            else { return t.check(false, "task 10: its count") }
            t.equal(trackCount.title, "18 bars")
            trackCount.performClick(nil)
            t.equal(Set(editor.canvas.selectedNames), Set(users), "task 10: the count selects them")
            // From any bar: the same name, and Change Everywhere in its menu.
            editor.select(section: "MeterBand5")
            guard let empty = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "SolidColor.row" }) as? ColorControl
            else { return t.check(false, "task 10: Bar 6's Empty part") }
            t.check(!empty.isHiddenOrHasHiddenAncestor, "task 10: Empty part is an essential row")
            t.equal(empty.nameButton.title, "Empty part of bars")
            t.check(empty.colorMenu?.items.contains { $0.title == "Change ‘Empty part of bars’ Everywhere (18 bars)…" } == true,
                    "task 10: Change Everywhere")
            // With Rainmeter Details, the shared color's own name.
            app.state.updateEditor { $0.showIniNames = true }
            editor.canvasSelectionChanged([])
            t.check(colorRow(editor, variable: "Track")?.findSubview { ($0 as? SwatchButton)?.toolTip?.contains("Track") == true } != nil,
                    "task 10: “Track” with Rainmeter Details")
            app.state.updateEditor { $0.showIniNames = false }

            t.equal(openedDisclosures(editor), [], "no step opened a disclosure")
            t.equal(read(ini), original, "everything undone")
            editor.window?.close()
        }
    }

    // MARK: The tasks that differ on System (a theme shared by several widgets)

    static func systemWalkthrough(_ t: AppTestRunner) {
        t.suite("App: friendly walkthrough: the tasks on System") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let skin = editor.skin else { return }
            let ini = skin.fileURL
            let resources = skin.resourcesDirectory
            let dark = resources.appendingPathComponent("Themes/Dark.inc"), styles = resources.appendingPathComponent("Styles.inc")
            let (darkBytes, styleBytes, original) = (read(dark), read(styles), read(ini))
            guard let network = app.activate(config: "Deskset\\Network", file: nil) else { return t.check(false, "Network loads") }
            let networkBlue = network.skin.variable("DownColor").flatMap(OptionValue.color)

            // 1. The blue you see is the first row, "CPU graph line and 2 more"; Apply to: This Widget is chosen.
            editor.canvasSelectionChanged([])
            guard let row = colorRow(editor, variable: "CPUColor"), let group = row.group else {
                return t.check(false, "task 1: the CPU graph line row")
            }
            t.check(group.role.hasPrefix("CPU graph line"), "task 1: \(group.role)")
            // Among the colors the page shows as it opens (the first six; the rest wait behind "Show N More Colors").
            let rows = editor.inspectorStack.subviewsMatching { ($0 as? ValueRowView)?.group != nil }
            t.check(rows.prefix(6).contains { $0 === row } && !row.isHiddenOrHasHiddenAncestor, "task 1: shown as the page opens")
            t.equal((reach(t, editor, "apply-to", "task 1") as? NSSegmentedControl)?.selectedSegment, 0, "task 1: This Widget")
            t.check(perform(editor.colorRowMenu(group).items.first { $0.title == "Custom Color…" }), "task 1: Custom Color…")
            editor.previewColorEdit(RGBA(r: 255, g: 0, b: 0))
            editor.commitColorEdit()
            t.equal(editor.skin?.variable("CPUColor").flatMap(OptionValue.color), RGBA(r: 255, g: 0, b: 0), "task 1: System changed")
            t.equal(read(dark), darkBytes, "task 1: the theme file is unchanged")
            app.refresh(network)
            t.equal(app.controller(for: "Deskset\\Network")?.skin.variable("DownColor").flatMap(OptionValue.color), networkBlue,
                    "task 1: Network is unchanged")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            t.equal(read(ini), original, "task 1: one undo step")

            // 2. The title's size: this title only, and the toast offers the other widgets' titles.
            click(editor, "MeterTitle")
            t.equal(editor.selectedSection, "MeterTitle")
            guard let size = reach(t, editor, "MeterTitle/FontSize", "task 2") as? ValueField else { return }
            size.type("14")
            settle()
            t.check(section("MeterTitle", in: read(ini)).contains("FontSize=14\n"), "task 2: on the title")
            t.equal(read(styles), styleBytes, "task 2: the shared look is unchanged")
            t.equal(editor.toastText, "Changed “System” only")
            t.check(editor.toastActions.contains { $0.title.hasPrefix("Apply to All ") && $0.title.hasSuffix(" Widget Titles") },
                    "task 2: \(editor.toastActions.map(\.title))")
            editor.window?.undoManager?.undo()
            settle()
            t.equal(read(ini), original, "task 2: one undo step")

            // 5. The memory bar is a shape: "Follows [Memory used ▾]".
            editor.select(section: "MeterRAMBar")
            guard let follows = reach(t, editor, "shape-follows", "task 5") as? NSPopUpButton else { return }
            t.equal((follows as? CompactPopUpButton)?.shownTitle ?? follows.titleOfSelectedItem, "Memory used")

            // 7. Update speed: no sound here, so no warning about it.
            editor.canvasSelectionChanged([])
            t.check(choose(editor.inspectorControl(for: "update-speed") as? NSPopUpButton) { $0.title.hasPrefix("Every 5 seconds") },
                    "task 7: every 5 seconds")
            t.check(section("Rainmeter", in: read(ini)).contains("Update=5000\n"), "task 7: Update=5000")
            t.check(editor.inspectorStack.findSubview { ($0 as? NSTextField)?.stringValue == "The sound bars will move in jumps." } == nil,
                    "task 7: no sound warning")
            editor.window?.undoManager?.undo()
            settle()

            t.equal(openedDisclosures(editor), [], "no step opened a disclosure")
            t.equal(read(ini), original, "everything undone")
            t.equal(read(styles), styleBytes)
            editor.window?.close()
        }
    }

    // MARK: G3: plain words in every default state

    /// Every text a person reads in a view (and the views in it that are shown): labels, button titles, closed
    /// pop-ups (a pull-down's items: its tag menu), segment labels, the text of fields.
    /// `fields`: with what editable fields hold (a widget's own words and values as its author wrote them).
    static func texts(_ root: NSView, fields: Bool = true) -> [String] {
        guard !root.isHidden, root.alphaValue > 0 else { return [] }
        var result: [String] = []
        switch root {
        case let p as CompactPopUpButton: result.append(p.shownTitle)
        case let p as NSPopUpButton:
            result += p.pullsDown ? p.itemArray.map(\.title) : [p.titleOfSelectedItem ?? ""]
        case let s as NSSegmentedControl: result += (0..<s.segmentCount).compactMap { s.label(forSegment: $0) }
        case let b as NSButton: result.append(b.title)
        case let f as NSTextField where fields || !f.isEditable: result.append(f.stringValue)
        case let v as NSTextView where fields || !v.isEditable: result.append(v.string)
        default: break
        }
        for v in root.subviews { result += texts(v, fields: fields) }
        return result.filter { !$0.isEmpty }
    }

    /// Every item title of a menu and its submenus.
    static func texts(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            let own = item.attributedTitle?.string ?? item.title
            return (own.isEmpty ? [] : [own]) + (item.submenu.map(texts) ?? [])
        }
    }

    /// The window as it is: its panes (the code pane is hidden in Design), the toolbar's words, and every row of the
    /// sidebar list (rows scrolled out of view too).
    static func windowTexts(_ editor: Editor, fields: Bool = true) -> [String] {
        var result = editor.window?.contentView.map { texts($0, fields: fields) } ?? []
        for item in editor.window?.toolbar?.items ?? [] {
            result.append(item.label)
            if let view = item.view { result += texts(view, fields: fields) }
        }
        let outline = editor.outline
        for row in 0..<outline.numberOfRows {
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) { result += texts(cell, fields: fields) }
        }
        return result
    }

    /// The default states of a widget, each with what it shows: nothing selected (the widget page), every layer, every
    /// run of repeated layers, every live data item — with the Layers and Live Data lists opened all the way, the Add
    /// tab, and the layer and data menus.
    /// `fields`: what editable fields hold is read too (the widgets written for the editor's own tests); off for widgets
    /// whose authors wrote code in their values (a time stamp, a picture folder), which the fields show as written.
    static func scan(_ editor: Editor, _ t: AppTestRunner, _ config: String, fields: Bool = true) -> [String] {
        guard let skin = editor.skin else { return ["\(config): no widget"] }
        var hits: [String] = []
        func windowTexts(_ editor: Editor) -> [String] { Self.windowTexts(editor, fields: fields) }
        func check(_ state: String, _ texts: [String]) {
            for text in texts {
                if let word = EditorSchema.engineWord(in: text) {
                    let hit = "\(config) · \(state): “\(text)” (\(word))"
                    if !hits.contains(hit) { hits.append(hit) }
                }
            }
        }
        t.equal(editor.app.state.editor.showIniNames, false, "\(config): Rainmeter Details are off")
        editor.selectSidebarTab(.library)
        editor.canvasSelectionChanged([])
        check("Add", windowTexts(editor))
        editor.selectSidebarTab(.layers)
        editor.outline.expandItem(nil, expandChildren: true)
        editor.canvasSelectionChanged([])
        let page = windowTexts(editor)
        check("nothing selected", page)
        // The scan reads what is on screen: the widget page's cards and the list's rows.
        t.check(page.contains("UPDATE SPEED") && page.contains("Whole widget · \(Int(skin.width)) × \(Int(skin.height))"),
                "\(config): the scan reads the page and the list")
        for m in skin.meters {
            editor.select(section: m.name)
            let texts = windowTexts(editor)
            t.check(texts.contains(LayerNaming.layer(m, in: skin).title), "\(config) \(m.name): the strip is read")
            check(m.name, texts)
            check("\(m.name) menu", Self.texts(LayerMenu.make(for: [m.name], in: editor)))
            // Every "More" open too (More Shape Options, More Triggers and its other buttons): still the default UI.
            let opened = EditorSchema.meterGroups(m.type).map { "open/more:" + $0.title.lowercased() }
                + EditorSchema.meterGroups(m.type).map { "\(m.name.lowercased())/\($0.title)/actions" }
            editor.inspectorState.disclosures.formUnion(opened)
            editor.rebuildInspector()
            check("\(m.name) opened", windowTexts(editor))
            editor.inspectorState.disclosures.subtract(opened)
        }
        for run in LayerSeries.detect(in: skin) where run.kind == .layers {
            editor.canvasSelectionChanged(run.members)
            check("\(run.members.count) \(run.members[0])…", windowTexts(editor))
        }
        editor.selectSidebarTab(.data)
        editor.outline.expandItem(nil, expandChildren: true)
        for m in skin.measures {
            editor.select(section: m.name)
            check(m.name, windowTexts(editor))
            check("\(m.name) menu", Self.texts(LayerMenu.makeData(for: [m.name], in: editor)))
        }
        return hits
    }

    static func plainWordsScan(_ t: AppTestRunner) {
        t.suite("App: friendly walkthrough: no engine words in any default state (G3)") {
            for (config, folder, fields) in [("Audio\\Visualizer", "TestSkins", true), ("Deskset\\System", "DefaultSkins", true),
                                             ("Deskset\\Clock", "DefaultSkins", true), ("Deskset\\Calendar", "DefaultSkins", false),
                                             ("Deskset\\Battery", "DefaultSkins", false), ("Round\\AnalogClock", "TestSkins", false),
                                             ("Round\\Gauges", "TestSkins", false), ("Shape\\Types", "TestSkins", false),
                                             ("MediaUI\\NowPlaying", "TestSkins", false)] {
                guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: config, from: folder) else { return }
                let hits = scan(editor, t, config, fields: fields)
                for hit in hits { print("    G3 " + hit) }
                t.equal(hits.count, 0, "\(config): \(hits.count) engine words")
                editor.window?.close()
            }
        }
    }
}

/// Fixtures shared by the Friendly suites (sidebar, widget page, inspector, canvas, walkthrough).
enum FriendlyFixtures {
    /// A headless app with a copy of a repository widget loaded — `config` ("Audio\Visualizer", "Deskset\System") from
    /// `folder` (TestSkins or DefaultSkins; its whole root config folder, @Resources included), in its variant `file`
    /// if given — and its editor open, hearing the same output device on every Mac (`fakeDevice`). Nil (and a note)
    /// when the repository is not around.
    static func openEditor(_ t: AppTestRunner, config: String, file: String? = nil, from folder: String = "TestSkins") throws
        -> (app: AppController, editor: InspectorWindowController)? {
        guard let source = Paths.repositoryFolder(folder), let app = try AppSelfTest.makeApp(t) else {
            print("    (skipped: \(folder) not found; run from the repository)")
            return nil
        }
        fakeDevice(t)
        let root = String(config.split(separator: "\\").first ?? "")
        let destination = app.skinsDirectory.appendingPathComponent(root)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source.appendingPathComponent(root), to: destination)
        app.rescanLibrary()
        guard let c = app.activate(config: config, file: file) else {
            t.check(false, "\(config) loads")
            return nil
        }
        app.showInspector(for: c)
        guard let editor = app.inspector else {
            t.check(false, "the editor opens")
            return nil
        }
        return (app, editor)
    }

    /// The output device the widgets hear, the same on every Mac (the Visualizer names it): until the suite ends, every
    /// AudioLevel measure reads this device list instead of the Mac's — also those of a skin a refresh creates (each
    /// edit written to the file). Installed before the widget loads, so it shows the device from its first update.
    static func fakeDevice(_ t: AppTestRunner, name: String = "MacBook Pro扬声器") {
        let device = AudioDeviceInfo(id: 7, uid: "test-output", name: name, inputChannels: 0, outputChannels: 2,
                                     sampleRate: 48000, canBeDefaultOutput: true, canBeDefaultInput: false)
        let saved = AudioLevelMeasure.sharedSystem
        AudioLevelMeasure.sharedSystem = {
            AudioSystemSnapshot(loaded: true, devices: [device], defaultOutput: 7, defaultInput: nil)
        }
        t.atSuiteEnd { AudioLevelMeasure.sharedSystem = saved }
    }
}
