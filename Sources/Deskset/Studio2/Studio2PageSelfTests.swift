import AppKit
import DesksetCore

/// The new Studio's widget page: twelve controls at most (plus Text · Card) on System, Nocturne and Weather; rows
/// updated in place; the walkthroughs of the design's tasks on Stationery System with their steps counted (a color,
/// the card's color, a font, all text bigger); the names of the steps and a color undone byte for byte; the color
/// popover; no engine words in English or Chinese.
enum Studio2PageSelfTests {
    static func run(_ t: AppTestRunner) {
        countTests(t)
        inPlaceTests(t)
        walkthroughTests(t)
        stepTests(t)
        revertKeepsOptionsTests(t)
        popoverTests(t)
        wordTests(t)
    }

    /// A designed screen's widget in a new Studio window, without its popover.
    static func open(_ t: AppTestRunner, _ name: String) -> StudioSnapshot.Opened? {
        guard var screen = StudioScreen.named(name) else {
            t.check(false, "\(name) is a screen")
            return nil
        }
        screen.colorPopover = nil
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

    // MARK: Twelve controls

    static func countTests(_ t: AppTestRunner) {
        t.suite("Studio2: page: twelve controls") {
            Studio2SelfTests.prepare(t)
            for (name, widget) in [("03-customize", "System"), ("03b-weather", "Weather"), ("13b-compat", "Nocturne")] {
                guard let opened = open(t, name) else { continue }
                defer { opened.close() }
                guard let page = opened.controller.widgetPage.page else {
                    t.check(false, "\(widget): a widget page")
                    continue
                }
                t.equal(page.title, widget)
                t.check(page.controlCount <= StudioPage.controlLimit,
                        "\(widget): \(page.controlCount) controls (at most \(StudioPage.controlLimit))")
                // Text · Card: on every widget page, outside the count.
                guard case .swatches(let s)? = page.item("colors")?.kind else {
                    t.check(false, "\(widget): colors")
                    continue
                }
                t.check(s.pair.contains { $0.kind == .text }, "\(widget): Text")
                t.check(s.pair.contains { $0.kind == .card }, "\(widget): Card")
                t.check(s.parts.count <= 4, "\(widget): at most four part colors")
            }

            // System: the design's page — no options, four Shows rows, four part colors, two fonts, looks, sizes.
            guard let opened = open(t, "03-customize") else { return }
            defer { opened.close() }
            let page = opened.controller.widgetPage.page
            t.equal(page?.sections.map(\.id), ["shows", "colors", "fonts", "look"])
            t.equal(page?.controlCount, 12, "System has exactly twelve")
            t.equal(page?.section("shows")?.items.count, 4)
            if case .swatches(let s)? = page?.item("colors")?.kind {
                t.equal(s.parts.map(\.label), ["CPU", "Memory", "Disk", "GPU"])
                t.equal(s.pair.map(\.kind), [.text, .card], "no More…: every color is shown")
                t.equal(s.followNote, "follow the look")
            }
            t.equal(page?.section("fonts")?.trailing, .textSize, "A− / A+ beside Fonts")
            t.equal(page?.footer.map(\.id), ["more-settings"])

            // The fitting order: options beyond four, part colors beyond four, one font row, fewer colors.
            guard var facts = opened.controller.widgetPage.facts else { return t.check(false, "facts") }
            let extra = (1...6).map { StudioWidgetFacts.Option(variable: "Extra\($0)", measure: nil, kind: .toggle,
                                                               label: "Extra \($0)", raw: "1", current: "1", file: nil) }
            facts.options = extra
            let plan = StudioWidgetPage.plan(facts)
            t.equal(plan.options.count, 4, "four options, the others under All Options…")
            t.equal(plan.hiddenOptions, 2)
            t.check(plan.fontsMerged, "the two fonts became one row")
            t.equal(plan.shows.count, 2, "then Shows rows beyond two went under All Data…")
            t.equal(plan.hiddenShows, 2)
            t.equal(plan.parts.count, 3, "then a part color went under More…")
            t.equal(plan.count, 12)
            facts.options = Array(extra.prefix(1))
            let one = StudioWidgetPage.plan(facts)
            t.equal(one.options.count, 1)
            t.check(one.fontsMerged, "one option: the fonts merge")
            t.equal(one.parts.count, 4, "and every part color stays")
            t.equal(one.count, 12)
        }
    }

    // MARK: In place

    static func inPlaceTests(_ t: AppTestRunner) {
        t.suite("Studio2: page: rows updated in place") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "03-customize") else { return }
            defer { opened.close() }
            let studio = opened.controller
            let view = studio.inspectorController.pageView
            let made = view.viewsMade
            let row = view.itemView("shows:MeasureCPU")
            t.check(row != nil, "the CPU row")
            studio.widgetPage.rebuild()
            t.equal(view.viewsMade, made, "a new build of the same page makes no views")
            t.check(view.itemView("shows:MeasureCPU") === row, "the same row view")
            // A change: only the confirmation is new.
            studio.widgetPage.handle(.textSize(1))
            t.check(view.itemView("fonts.confirm") != nil, "the confirmation")
            t.check(view.itemView("shows:MeasureCPU") === row, "the row kept its view")
            t.equal(view.viewsMade, made + 1, "only the confirmation was made")
            // Invalid values show as written, with the amber mark.
            var facts = studio.widgetPage.facts!
            facts.options = [.init(variable: "Units", measure: nil, kind: .choice(["C", "F"]), label: "Units", raw: "K",
                                   current: "K", file: nil)]
            let page = studio.widgetPage.build(facts)
            if case .row(let r)? = page.item("option:Units")?.kind {
                t.equal(r.invalid, "K", "shown as written")
                if case .segmented(let s) = r.control { t.equal(s.selected, -1, "nothing chosen") }
            } else {
                t.check(false, "the option row")
            }
            // The view: the amber mark with the value as written, and where a value comes from in an icon and a word.
            let lone = StudioPageView(frame: NSRect(x: 0, y: 0, width: 318, height: 400))
            var units = StudioPage.Row(label: "Units", control: .segmented(.init(items: ["°C", "°F"], selected: -1)))
            units.invalid = "K"
            units.source = .live
            lone.apply(StudioPage(id: "p", title: "T", subtitle: "", sections: [
                .init(id: "s", title: "S", items: [.init(id: "r", kind: .row(units))])]))
            lone.layoutSubtreeIfNeeded()
            guard let rowView = lone.itemView("r") as? StudioRowView else { return t.check(false, "the row") }
            rowView.layoutSubtreeIfNeeded()
            t.check(!rowView.sourceChip.isHidden, "the source chip")
            t.equal(rowView.sourceChip.accessibilityLabel(), "Live")
            let shown = Studio2PageSelfTests.words(in: rowView)
            t.check(shown.contains("“K”"), "the value as written: \(shown)")
        }
    }

    // MARK: Walkthroughs

    /// Counts a person's steps from the desktop, as the design counts them (a click, a choice, Done or Esc).
    final class Steps {
        private(set) var count = 0
        func take(_ n: Int = 1, _ body: () -> Void = {}) {
            count += n
            body()
        }
    }

    static func walkthroughTests(_ t: AppTestRunner) {
        t.suite("Studio2: page: T1.3 a color in five steps") {
            Studio2SelfTests.prepare(t)
            let steps = Steps()
            // 1–2: the widget's menu ▸ Customize Look… (or a double-click and nothing else).
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "03-customize") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller, page = studio.widgetPage!, view = studio.inspectorController.pageView
            guard let session = studio.session else { return t.check(false, "a session") }
            let medium = file(opened, "Stationery/System/Medium.ini")
            let before = data(medium)
            // 3: the Memory swatch.
            guard let swatch = view.swatchView(item: "colors", swatch: "part:1") as? StudioSwatchView else {
                return t.check(false, "the Memory swatch")
            }
            t.equal(swatch.swatch.label, "Memory")
            steps.take { _ = swatch.accessibilityPerformPress() }
            guard let popover = page.colorPopover else { return t.check(false, "the color popover opens") }
            t.equal(popover.target.title, "Memory ring")
            t.equal(page.activeSwatch, "part:1")
            t.equal(StudioColorInput.hex(popover.target.color), "#34C759")
            // 4: Mint (the Mac's). It shows at once; nothing is written yet.
            let mint = popover.macSwatches[4]
            steps.take { _ = mint.accessibilityPerformPress() }
            let picked = StudioColorPopover.rgba(mint.resolvedColor)
            t.equal(popover.picked.map(ValueUsageIndex.colorKey), ValueUsageIndex.colorKey(picked))
            let rgb = "\(Int(picked.r)),\(Int(picked.g)),\(Int(picked.b))"
            t.equal(studio.skin?.variable("MemoryColor"), rgb, "previewed in the Studio's instance")
            t.equal(data(medium), before, "not written while picking")
            // 5: Done: the pick is one step, written, and the window closes.
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 5, "T1.3 in \(steps.count) steps (at most 5)")
            t.check(text(medium).contains("MemoryColor=\(rgb)"), "written for this widget: \(rgb)")
            t.equal(session.undoStack.undoActionName, "Color")
            t.check(StudioWindowController.window(for: opened.app) == nil, "Done closed the window")
            t.check(AppSelfTest.spin {
                opened.app.controller(for: "Stationery\\System")?.skin.variable("MemoryColor") == rgb
            }, "the widget on the desktop shows it")
            // Undone: the file byte for byte as it was.
            session.undoStack.undo()
            t.equal(data(medium), before, "undone byte for byte")
        }

        t.suite("Studio2: page: T1.3 the card's color in five steps") {
            Studio2SelfTests.prepare(t)
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "03-customize") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller, page = studio.widgetPage!, view = studio.inspectorController.pageView
            let medium = file(opened, "Stationery/System/Medium.ini")
            let session = studio.session
            guard let card = view.swatchView(item: "colors", swatch: "card") as? StudioSwatchView else {
                return t.check(false, "the Card swatch")
            }
            t.check(card.swatch.follows, "it follows the look until changed")
            steps.take { _ = card.accessibilityPerformPress() }
            guard let popover = page.colorPopover else { return t.check(false, "the popover") }
            t.equal(popover.target.title, "Card")
            let blue = popover.macSwatches[7]
            steps.take { _ = blue.accessibilityPerformPress() }
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 5, "the card's color in \(steps.count) steps (at most 5)")
            t.check(text(medium).contains("GlassTint="), "the card's tint, for this widget")
            t.equal(session?.undoStack.undoActionName, "Color")
        }

        t.suite("Studio2: page: T1.4 a font in five steps") {
            Studio2SelfTests.prepare(t)
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "03-customize") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller, view = studio.inspectorController.pageView
            let medium = file(opened, "Stationery/System/Medium.ini")
            let session = studio.session
            guard let popup = (view.itemView("font:numbers") as? StudioRowView)?.controlView as? NSPopUpButton else {
                return t.check(false, "the Numbers menu")
            }
            t.equal(popup.titleOfSelectedItem, "SF Pro Rounded")
            // 3: the menu opens; 4: New York.
            steps.take()
            guard let index = popup.itemTitles.firstIndex(of: "New York") else { return t.check(false, "New York") }
            t.check(popup.item(at: index)?.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) != nil,
                    "each face drawn in itself")
            steps.take {
                popup.selectItem(at: index)
                _ = popup.sendAction(popup.action, to: popup.target)
            }
            t.check(view.itemView("fonts.confirm") != nil, "confirmed under the fonts")
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 5, "T1.4 in \(steps.count) steps (at most 5)")
            t.check(text(medium).contains("FontNumber=System Serif"), "the numbers' font, for this widget")
            t.equal(session?.undoStack.undoActionName, "Font")
        }

        t.suite("Studio2: page: T1.4 all text bigger in four steps") {
            Studio2SelfTests.prepare(t)
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "03-customize") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller, view = studio.inspectorController.pageView
            let medium = file(opened, "Stationery/System/Medium.ini")
            let session = studio.session
            guard let buttons = view.textSizeButtons(section: "fonts") else { return t.check(false, "A− / A+") }
            let before = studio.skin?.meter(named: "MeterCPUValue")?.double("FontSize", 0) ?? 0
            steps.take { buttons.bigger.performClick(nil) }
            let after = studio.skin?.meter(named: "MeterCPUValue")?.double("FontSize", 0) ?? 0
            t.check(after > before, "the numbers grew: \(before) → \(after)")
            t.equal(studio.toolbar.undoButton.title, "Undo Text Size")
            steps.take { studio.doneAction(nil) }
            t.check(steps.count <= 4, "bigger in \(steps.count) steps (at most 4)")
            t.check(text(medium).contains("[sMetricS]"), "the look's size, overridden for this widget")
            t.equal(session?.undoStack.undoActionName, "Text Size")
        }
    }

    // MARK: Steps and their names

    /// An option is this copy's setting, not a change of the design (§3.2–3.5): °F alone leaves the widget "Built-in";
    /// a color then makes it "Edited by you" with one change, and Revert to Original takes the color back and keeps °F.
    static func revertKeepsOptionsTests(_ t: AppTestRunner) {
        t.suite("Studio2: page: Revert to Original keeps the options") {
            Studio2SelfTests.prepare(t)
            // The sample forecast of the designed screen (its parts show, so its unit is an option); never the network.
            let previousWeather = WeatherService.shared.environment
            var weather = WeatherWiring.previewEnvironment(demo: true, demoNow: METNorway.parseISO8601("2026-09-27T03:30:00Z"))
            weather.transport = WeatherSelfTests.ForbiddenTransport()
            WeatherService.install(weather)
            defer { WeatherService.install(previousWeather) }
            guard let opened = open(t, "03b-weather") else { return }
            defer { opened.close() }
            let studio = opened.controller, page = studio.widgetPage!
            guard let unit = page.facts?.options.first(where: { $0.variable?.caseInsensitiveCompare("TempUnit") == .orderedSame }),
                  case .choice(let values) = unit.kind, let f = values.firstIndex(where: { $0.uppercased() == "F" }) else {
                return t.check(false, "Weather's temperature unit: \(page.facts?.options.map(\.label) ?? [])")
            }
            let medium = file(opened, "Stationery/Weather/Medium.ini")
            let item = "option:\(StudioWidgetPage.key(unit))"
            page.handle(.choose(item: item, index: f))
            if !text(medium).contains("TempUnit=F") { page.handle(.segment(item: item, index: f)) }
            t.check(text(medium).contains("TempUnit=F"), "°F, for this widget")
            t.equal(studio.copySentence, StudioText[.copyBuiltIn], "an option is not an edit of the design")
            t.check(page.revertLink() == nil, "nothing to revert")
            t.check(page.page?.footer.contains { $0.id == "revert" } == false, "no Revert to Original in the footer")
            // A color: one change, and the widget is edited.
            page.handle(.swatch(item: "colors", swatch: "text"))
            page.colorPopover?.takeFieldText("#FF2D55")
            page.colorPopover?.close()
            t.equal(studio.copySentence, StudioText[.copyEdited], "a color is")
            t.equal(page.revertLink()?.detail, StudioText[.revertOne], "one change: the color")
            page.handle(.link("revert"))
            t.check(page.revertLink() == nil, "nothing left to revert")
            t.check(text(medium).contains("TempUnit=F"), "°F stays")
            t.check(!text(medium).uppercased().contains("FF2D55") && !text(medium).contains("255,45,85"), "the color went")
            t.equal(studio.copySentence, StudioText[.copyBuiltIn])
            t.check(AppSelfTest.spin {
                opened.app.controller(for: "Stationery\\Weather")?.skin.variable("TempUnit") == "F"
            }, "the desktop still shows °F")
            t.equal(studio.session?.undoStack.undoActionName, StudioText[.revertToOriginal], "one step")
        }
    }

    static func stepTests(_ t: AppTestRunner) {
        t.suite("Studio2: page: steps, names and confirmations") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "03-customize") else { return }
            defer { opened.close() }
            let studio = opened.controller, page = studio.widgetPage!, view = studio.inspectorController.pageView
            guard let session = studio.session else { return t.check(false, "a session") }
            let medium = file(opened, "Stationery/System/Medium.ini")
            let original = data(medium)

            // A color: the confirmation under the swatches, and Undo named in the toolbar.
            page.handle(.swatch(item: "colors", swatch: "part:0"))
            page.colorPopover?.takeFieldText("#40BA5C")
            t.equal(page.colorPopover?.field.stringValue, "64,186,92", "shown in the file's own notation")
            page.colorPopover?.close()
            t.check(page.colorPopover == nil, "closed")
            t.check(text(medium).contains("CPUColor=64,186,92"), "written in R,G,B like the file")
            t.equal(studio.toolbar.undoButton.title, "Undo Color")
            guard case .confirmation(let c)? = page.page?.item("colors.confirm")?.kind else {
                return t.check(false, "a confirmation under the colors")
            }
            t.equal(c.text, "CPU ring is now Green")
            t.equal(c.undo, "Undo")
            // Its Undo: the step goes, byte for byte, and so does the confirmation.
            (view.itemView("colors.confirm") as? StudioConfirmationView)?.undoButton.performClick(nil)
            t.equal(data(medium), original, "undone byte for byte")
            t.check(page.page?.item("colors.confirm") == nil, "the confirmation went with it")

            // Building (the sidebar open): a change to one value stays quiet.
            studio.setSidebarOpen(true)
            page.handle(.textSize(-1))
            t.check(page.page?.item("fonts.confirm") == nil, "no confirmation while building")
            t.equal(session.undoStack.undoActionName, "Text Size")
            session.undoStack.undo()
            studio.setSidebarOpen(false)
            t.equal(data(medium), original)

            // The look: this widget alone by default — its own value, read before the include that loads the look —
            // and nothing else changes; the scope sentence offers all the suite's widgets.
            let variables = file(opened, "Stationery/@Resources/Variables.inc")
            let suite = data(variables)
            let clock = opened.app.activate(config: "Stationery\\Clock", file: "Medium.ini")
            t.check(clock != nil, "another widget of the suite")
            guard case .note(let scope)? = page.page?.item("look.scope")?.kind else {
                return t.check(false, "the look's scope sentence")
            }
            t.equal(scope.text, "This widget only")
            t.equal(scope.link, "All 23 Widgets")
            t.check(!scope.text.contains("Stationery"), "no suite name people don't know")
            page.handle(.thumbnail(item: "look", index: 2))
            t.check(text(medium).contains("@Include2=#@#Variables.inc\nLook=Dark\n@Include3=#@#Suite/Tokens.inc"),
                    "this widget's own look, before the include that reads it")
            t.equal(data(variables), suite, "the suite's file is left alone")
            t.equal(studio.skin?.variable("Look"), "Dark")
            t.check(opened.app.controller(for: "Stationery\\Clock") === clock, "the other widget did not load again")
            t.equal(studio.copySentence, StudioText[.copyEdited], "a look is a change of the design")
            t.check(page.revertLink() != nil, "and Revert to Original puts it back")
            session.undoStack.undo()
            t.equal(data(medium), original, "undone byte for byte")
            // All 23: one explicit click, then the suite's file, and every Stationery widget follows (and its undo).
            page.handle(.noteLink(item: "look.scope"))
            guard case .note(let all)? = page.page?.item("look.scope")?.kind else { return t.check(false, "all") }
            t.equal(all.text, "All 23 built-in widgets")
            t.equal(all.link, "Only This Widget")
            page.handle(.thumbnail(item: "look", index: 2))
            t.check(text(variables).contains("\nLook=Dark"), "the suite's look")
            t.equal(data(medium), original, "this widget's file is left alone")
            t.check(page.revertLink() != nil, "Revert to Original counts the suite's look too")
            t.equal(studio.copySentence, StudioText[.copyEdited])
            t.check(AppSelfTest.spin { opened.app.controller(for: "Stationery\\Clock") !== clock },
                    "the other widget loaded again")
            let clockDark = opened.app.controller(for: "Stationery\\Clock")
            t.equal(session.undoStack.undoActionName, "Look")
            guard case .confirmation(let look)? = page.page?.item("look.confirm")?.kind else {
                return t.check(false, "the look's confirmation")
            }
            t.equal(look.text, "The look is now Dark")
            session.undoStack.undo()
            t.equal(data(variables), suite, "the look undone byte for byte")
            t.check(AppSelfTest.spin { opened.app.controller(for: "Stationery\\Clock") !== clockDark },
                    "and loaded again for the undo")
            page.handle(.noteLink(item: "look.scope"))

            // The size: another variant runs on the desktop; undone, the first one again.
            page.handle(.segment(item: "size", index: 2))
            t.check(AppSelfTest.spin { studio.skin?.fileURL.lastPathComponent == "Large.ini" }, "Large on the canvas")
            t.equal(opened.app.controller(for: "Stationery\\System")?.skin.fileURL.lastPathComponent, "Large.ini")
            t.equal(session.undoStack.undoActionName, "Size")
            session.undoStack.undo()
            t.check(AppSelfTest.spin { studio.skin?.fileURL.lastPathComponent == "Medium.ini" }, "Medium again")

            // Shows: Ring 4 is the widget's switch between the GPU and swap.
            guard case .row(let ring4)? = page.page?.item("shows:MeasureGPU")?.kind,
                  case .popup(let menu) = ring4.control else { return t.check(false, "Ring 4") }
            t.equal(ring4.label, "Ring 4")
            t.equal(menu.items.map(\.title), ["GPU usage", "Memory and swap used"])
            page.handle(.choose(item: "shows:MeasureGPU", index: 1))
            t.check(text(medium).contains("SystemFourthRing=Swap"), "the switch, for this widget")
            t.equal(session.undoStack.undoActionName, "Shows")
            session.undoStack.undo()
            t.equal(data(medium), original)
            // A ring that works out its own value offers the others, but not to choose.
            guard case .row(let ring1)? = page.page?.item("shows:MeasureCPU")?.kind,
                  case .popup(let cpu) = ring1.control else { return t.check(false, "Ring 1") }
            t.equal(cpu.items.first?.title, "CPU usage")
            t.check(cpu.items.dropFirst().allSatisfy { !$0.enabled }, "the others are not to be chosen here")
        }

        t.suite("Studio2: page: Nocturne's options") {
            Studio2SelfTests.prepare(t)
            guard let opened = open(t, "13b-compat") else { return }
            defer { opened.close() }
            let studio = opened.controller, page = studio.widgetPage!
            let variables = file(opened, "Nocturne/@Resources/Variables.inc")
            let nocturne = file(opened, "Nocturne/Nocturne.ini")
            let before = data(nocturne)
            // The first Rainmeter skin turned Rainmeter details on: All Variables… ends the options.
            t.check(studio.showsRainmeterDetails, "Rainmeter details on")
            t.equal(page.page?.section("options")?.items.map(\.id),
                    ["option:AccentColor", "option:PanelAlpha", "option:ClockFormat", "options.variables"])
            guard case .row(let clock)? = page.page?.item("option:ClockFormat")?.kind,
                  case .segmented(let s) = clock.control else { return t.check(false, "the clock") }
            t.equal(s.items, ["1:30 PM", "13:30"])
            t.equal(s.selected, 1)
            page.handle(.segment(item: "option:ClockFormat", index: 0))
            t.check(text(nocturne).contains("ClockFormat=%I:%M"), "only the letter changed, for this widget")
            t.check(!text(variables).contains("%I"), "the shared file keeps its own")
            t.equal(studio.session?.undoStack.undoActionName, "Clock")
            studio.session?.undoStack.undo()
            t.equal(data(nocturne), before)
            // Shows: a bar that names its data itself can show another.
            guard case .row(let bar)? = page.page?.item("shows:MeasureCPU")?.kind, case .popup(let menu) = bar.control,
                  let ram = menu.items.firstIndex(where: { $0.title == "Memory used" }) else {
                return t.check(false, "the CPU bar")
            }
            page.handle(.choose(item: "shows:MeasureCPU", index: ram))
            t.check(text(nocturne).contains("MeasureName=MeasureRAM"), "rebound")
            studio.session?.undoStack.undo()
            t.equal(data(nocturne), before)
            // The fonts: one for all words, and the size needs the engine (not yet).
            t.equal(page.page?.section("fonts")?.title, "Fonts and size")
            guard case .row(let size)? = page.page?.item("size")?.kind, case .segmented(let scale) = size.control else {
                return t.check(false, "the size")
            }
            t.equal(scale.items, ["75%", "100%", "125%", "150%"])
            t.check(!scale.enabled)
        }
    }

    // MARK: The color popover

    static func popoverTests(_ t: AppTestRunner) {
        t.suite("Studio2: page: the color popover") {
            Studio2SelfTests.prepare(t)
            t.equal(StudioColorInput.parse("#40BA5C").map(ValueUsageIndex.colorKey), "64,186,92,255")
            t.equal(StudioColorInput.parse("40ba5c").map(ValueUsageIndex.colorKey), "64,186,92,255", "Figma's")
            t.equal(StudioColorInput.parse("#4B5").map(ValueUsageIndex.colorKey), "68,187,85,255")
            t.equal(StudioColorInput.parse("#40BA5C80").map(ValueUsageIndex.colorKey), "64,186,92,128")
            t.equal(StudioColorInput.parse("rgba(64, 186, 92, 0.5)").map(ValueUsageIndex.colorKey), "64,186,92,128")
            t.equal(StudioColorInput.parse("rgb(64 186 92)").map(ValueUsageIndex.colorKey), "64,186,92,255")
            t.equal(StudioColorInput.parse("40BA5C 50%").map(ValueUsageIndex.colorKey), "64,186,92,128")
            t.equal(StudioColorInput.parse("255,255,255,200").map(ValueUsageIndex.colorKey), "255,255,255,200")
            t.equal(StudioColorInput.parse("nope").map(ValueUsageIndex.colorKey), nil)
            t.equal(StudioColorInput.parse("#12345").map(ValueUsageIndex.colorKey), nil)
            t.equal(StudioColorInput.hex(RGBA(r: 64, g: 186, b: 92)), "#40BA5C")
            t.equal(StudioColorWriting.text(RGBA(r: 64, g: 186, b: 92, a: 128), like: "FFFFFFC8", acceptsAlpha: true),
                    "40BA5C80", "hex stays hex")
            t.equal(StudioColorWriting.text(RGBA(r: 64, g: 186, b: 92, a: 128), like: "1,2,3", acceptsAlpha: false),
                    "64,186,92", "an alpha the place cannot take is left out")

            guard let opened = open(t, "03-customize") else { return }
            defer { opened.close() }
            let studio = opened.controller, page = studio.widgetPage!
            page.handle(.swatch(item: "colors", swatch: "part:1"))
            guard let popover = page.colorPopover else { return t.check(false, "opens") }
            _ = popover.view
            t.equal(popover.titleLabel.stringValue, "Memory ring")
            t.equal(popover.hexLabel.stringValue, "#34C759")
            t.equal(popover.noteLabel.stringValue, "·  1 part in this widget")
            t.equal(popover.macSwatches.count, 14)
            t.check(!popover.opacitySlider.isEnabled, "a color the widget adds its own alpha to takes none")
            t.equal(popover.widgetSwatches.count, 6, "the widget's colors")
            t.check(popover.widgetSwatches[1].selected, "its own color is ringed")
            // The page shows which swatch is open and what it paints.
            if case .swatches(let s)? = page.page?.item("colors")?.kind {
                t.check(s.parts[1].active, "the Memory swatch is ringed")
                t.equal(s.caption, "Memory ring · 1 part")
            }
            // A bad value is refused, nothing picked.
            popover.takeFieldText("zzz")
            t.check(popover.picked == nil)
            // Closing without a pick makes no step.
            let steps = studio.session?.undoStack.canUndo ?? false
            popover.close()
            t.equal(studio.session?.undoStack.canUndo ?? false, steps, "no step without a pick")
            // The snapshot composes it at the inspector's edge, level with its swatch.
            page.handle(.swatch(item: "colors", swatch: "part:1"))
            guard let anchor = page.popoverAnchor(), let rep = StudioSnapshot.render(studio) else {
                return t.check(false, "renders with the popover")
            }
            let edge = anchor.view.convert(anchor.rect, to: nil)
            t.close(edge.minX, studio.inspectorController.view.convert(NSPoint.zero, to: nil).x, accuracy: 1,
                    "at the inspector's edge")
            // Left of the edge, the popover's material covers the canvas.
            let x = Int((edge.minX - 60) * 2), y = Int((860 - edge.midY) * 2)
            let sample = rep.colorAt(x: x, y: y)
            t.check(sample.map { $0.brightnessComponent > 0.8 && $0.saturationComponent < 0.15 } == true,
                    "the popover's light material there: \(String(describing: sample))")
            page.colorPopover?.close()
        }
    }

    // MARK: Words

    /// Engine words the default state never shows (design: G3), by language.
    static let englishWords = ["skin", "meter", "measure", "section", "variable", "computed", "modifier", "binding",
                               "freeform", "ini", "try", "ink"]
    static let chineseWords = ["皮肤", "测量", "节", "变量", "修饰符", "绑定", "毫秒", "墨色"]

    /// The engine words in `text`.
    static func engineWords(in text: String, chinese: Bool) -> [String] {
        var found: [String] = []
        let lower = text.lowercased()
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        for w in englishWords where words.contains(w) { found.append(w) }
        if lower.range(of: #"#[a-z@][a-z0-9_]*#"#, options: .regularExpression) != nil { found.append("#…#") }
        if lower.range(of: #"\b\d+\s?ms\b"#, options: .regularExpression) != nil { found.append("ms") }
        if chinese { for w in chineseWords where text.contains(w) { found.append(w) } }
        return found
    }

    /// Every word a page view shows: labels, menu items, segments, tips.
    static func words(in view: NSView) -> String {
        var parts: [String] = []
        if let field = view as? NSTextField { parts.append(field.stringValue) }
        if let search = view as? NSSearchField { parts.append(search.placeholderString ?? "") }
        if let popup = view as? NSPopUpButton { parts += popup.itemTitles }
        if let seg = view as? NSSegmentedControl { parts += (0..<seg.segmentCount).compactMap { seg.label(forSegment: $0) } }
        if let button = view as? NSButton { parts.append(button.title) }
        if let tip = view.toolTip { parts.append(tip) }
        if let label = view.accessibilityLabel() { parts.append(label) }
        for sub in view.subviews { parts.append(words(in: sub)) }
        return parts.joined(separator: " ")
    }

    static func wordTests(_ t: AppTestRunner) {
        t.suite("Studio2: page: no engine words") {
            Studio2SelfTests.prepare(t)
            t.equal(engineWords(in: "Show the skin", chinese: false), ["skin"])
            t.equal(engineWords(in: "#TextColor# and 10 ms", chinese: false), ["#…#", "ms"])
            t.equal(engineWords(in: "变量", chinese: true), ["变量"])
            t.equal(engineWords(in: "Colors · Mint", chinese: false), [])
            for (screen, name) in [("03-customize", "System"), ("03b-weather", "Weather")] {
                for language in [StudioLanguage.english, .chinese] {
                    StudioText.languageOverride = language
                    guard let opened = open(t, screen) else { continue }
                    defer { opened.close() }
                    let studio = opened.controller
                    studio.widgetPage.handle(.swatch(item: "colors", swatch: "part:0"))
                    _ = studio.widgetPage.colorPopover?.view
                    var text = words(in: studio.inspectorController.pageView)
                    if let popover = studio.widgetPage.colorPopover {
                        // The color field shows the file's own notation (the design allows it for INI skins).
                        popover.field.stringValue = ""
                        text += " " + words(in: popover.view)
                    }
                    let found = engineWords(in: text, chinese: language == .chinese)
                    t.equal(found, [], "\(name), \(language.rawValue): \(found)")
                    studio.widgetPage.colorPopover?.close()
                }
            }
            StudioText.languageOverride = .english
        }
    }
}
