import AppKit
import DesksetCore

/// The new Studio measured against the design's checks, in English and Chinese, light and dark:
/// - "Studio2: walkthrough": the tasks T1.3–T1.8 on Stationery (an INI widget) with their steps counted from the desktop
///   (a click, a choice, a key that commits, Done; typing is not a step), each primary control in view without
///   scrolling, the step named in the language; and one pass with the keyboard alone.
/// - Twelve controls on every page the Studio generates (widget, part and data pages), with the exceptions named.
/// - The banned engine words (G3) on the default pages, the sidebar, the popovers and the menus, in both languages.
/// - Contrast measured on the snapshots: labels and notes at least 4.5 : 1 on the Bright, Busy and Dark samples, a
///   chosen segment at least 3 : 1 against its track.
/// - Labels are never cut, and the Chinese follows Apple's style.
enum Studio2AuditSelfTests {
    static func run(_ t: AppTestRunner) {
        walkthroughTests(t)
        keyboardTests(t)
        controlCountTests(t)
        wordTests(t)
        contrastTests(t)
        layoutTests(t)
    }

    typealias Steps = Studio2PageSelfTests.Steps

    /// The four ways the walkthroughs run.
    static let variants: [(language: StudioLanguage, dark: Bool)] = [
        (.english, false), (.english, true), (.chinese, false), (.chinese, true),
    ]

    /// Runs `body` with the Studio in `language` and the Mac in dark (or light) mode, and puts both back.
    static func with(_ language: StudioLanguage, dark: Bool, _ body: () -> Void) {
        let appearance = NSApp.appearance, before = StudioText.languageOverride
        StudioText.languageOverride = language
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer {
            NSApp.appearance = appearance
            StudioText.languageOverride = before
        }
        body()
    }

    static func name(_ language: StudioLanguage, _ dark: Bool) -> String {
        "\(language == .chinese ? "Chinese" : "English"), \(dark ? "dark" : "light")"
    }

    /// A designed screen's widget in a new Studio window, nothing selected and no popover open.
    static func open(_ t: AppTestRunner, _ name: String, edits: [StudioScreen.FileEdit] = [],
                     tweak: (inout StudioScreen) -> Void = { _ in }) -> StudioSnapshot.Opened? {
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
        screen.colorPicked = nil
        screen.hoverSwatch = nil
        screen.previewPopover = false
        screen.edits += edits
        tweak(&screen)
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

    /// Whether `view` is in the inspector's view without scrolling (the design: a primary control that has to be
    /// scrolled to fails the task, however few the steps).
    static func inView(_ view: NSView?, _ studio: StudioWindowController) -> Bool {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return false }
        let page = studio.inspectorController.pageView
        guard let clip = page.enclosingScrollView?.contentView else { return true }
        let r = view.convert(view.bounds, to: clip)
        return clip.bounds.insetBy(dx: -1, dy: -1).contains(r)
    }

    // MARK: Walkthroughs

    static func walkthroughTests(_ t: AppTestRunner) {
        t.suite("Studio2: walkthrough") {
            Studio2SelfTests.prepare(t)
            var counts: [String: [Int]] = [:]
            for v in variants {
                with(v.language, dark: v.dark) {
                    let label = name(v.language, v.dark)
                    for (task, run) in tasks {
                        guard let n = run(t, label) else { continue }
                        counts[task, default: []].append(n)
                    }
                }
            }
            // One line per task: its steps in each of the four runs (they never differ by language or look).
            for (task, _) in tasks {
                let n = counts[task] ?? []
                print("    \(task): \(n.map(String.init).joined(separator: " · ")) steps")
                t.equal(n.count, variants.count, "\(task) ran in every language and look")
                t.check(Set(n).count <= 1, "\(task): the same steps in every run: \(n)")
            }
        }
    }

    /// The tasks and their step targets (a task returns its steps, nil when it could not run).
    static let tasks: [(String, (AppTestRunner, String) -> Int?)] = [
        ("T1.3 a color (at most 5)", color),
        ("T1.3 the card's color (at most 5)", cardColor),
        ("T1.4 a font (at most 5)", font),
        ("T1.4 all text bigger (at most 4)", bigger),
        ("T1.4 a part's text size (at most 5)", partTextSize),
        ("T1.5 the size, in the Studio (at most 4; 2 from the desktop's menu)", size),
        ("T1.6 what a part shows (at most 6)", shows),
        ("T1.7 move a part (at most 5)", move),
        ("T1.7 hide a part (at most 5)", hide),
        ("T1.8 back to the original (at most 3)", revert),
    ]

    static func color(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        // 1–2: the widget's menu ▸ Customize Look… (or a double-click on the widget and nothing else).
        steps.take(2) { opened = open(t, "03-customize") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, page = studio.widgetPage!, view = studio.inspectorController.pageView
        let medium = file(opened, "Stationery/System/Medium.ini")
        t.check(StudioPageStyle.isDark(studio.window?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
                == label.hasSuffix("dark"), "\(label): the window's look")
        guard let swatch = view.swatchView(item: "colors", swatch: "part:1") as? StudioSwatchView else {
            t.check(false, "\(label): the Memory swatch")
            return nil
        }
        t.check(inView(swatch, studio), "\(label): the swatch is in view without scrolling")
        steps.take { _ = swatch.accessibilityPerformPress() }
        guard let popover = page.colorPopover, popover.macSwatches.count > 4 else {
            t.check(false, "\(label): the color popover")
            return nil
        }
        let mint = popover.macSwatches[4]
        steps.take { _ = mint.accessibilityPerformPress() }
        let picked = StudioColorPopover.rgba(mint.resolvedColor)
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 5, "\(label): T1.3 in \(steps.count) steps")
        t.check(text(medium).contains("MemoryColor=\(Int(picked.r)),\(Int(picked.g)),\(Int(picked.b))"),
                "\(label): written for this widget")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoColor], "\(label): the step's name")
        t.check(StudioWindowController.window(for: opened.app) == nil, "\(label): Done closed the window")
        return steps.count
    }

    static func cardColor(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "03-customize") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, page = studio.widgetPage!, view = studio.inspectorController.pageView
        let medium = file(opened, "Stationery/System/Medium.ini")
        guard let card = view.swatchView(item: "colors", swatch: "card") as? StudioSwatchView else {
            t.check(false, "\(label): the Card swatch")
            return nil
        }
        t.check(inView(card, studio), "\(label): Card is in view")
        steps.take { _ = card.accessibilityPerformPress() }
        guard let popover = page.colorPopover, popover.macSwatches.count > 7 else {
            t.check(false, "\(label): the popover")
            return nil
        }
        steps.take { _ = popover.macSwatches[7].accessibilityPerformPress() }
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 5, "\(label): the card's color in \(steps.count) steps")
        t.check(text(medium).contains("GlassTint="), "\(label): the card's tint, for this widget")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoColor])
        return steps.count
    }

    static func font(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "03-customize") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, view = studio.inspectorController.pageView
        let medium = file(opened, "Stationery/System/Medium.ini")
        guard let popup = (view.itemView("font:numbers") as? StudioRowView)?.controlView as? NSPopUpButton,
              let index = popup.itemTitles.firstIndex(of: "New York") else {
            t.check(false, "\(label): the Numbers menu with New York")
            return nil
        }
        t.check(inView(popup, studio), "\(label): the font menu is in view")
        // 3: the menu opens; 4: New York.
        steps.take()
        steps.take {
            popup.selectItem(at: index)
            _ = popup.sendAction(popup.action, to: popup.target)
        }
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 5, "\(label): T1.4 in \(steps.count) steps")
        t.check(text(medium).contains("FontNumber=System Serif"), "\(label): the numbers' font, for this widget")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoFont])
        return steps.count
    }

    static func bigger(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "03-customize") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, view = studio.inspectorController.pageView
        let medium = file(opened, "Stationery/System/Medium.ini")
        guard let buttons = view.textSizeButtons(section: "fonts") else {
            t.check(false, "\(label): A− / A+")
            return nil
        }
        t.check(inView(buttons.bigger, studio), "\(label): A+ is in view")
        steps.take { buttons.bigger.performClick(nil) }
        t.equal(studio.toolbar.undoButton.title, StudioText.format(.undoNamed, StudioText[.undoTextSize]),
                "\(label): Undo is named in the toolbar")
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 4, "\(label): bigger in \(steps.count) steps")
        t.check(text(medium).contains("[sMetricS]"), "\(label): the look's size, overridden for this widget")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoTextSize])
        return steps.count
    }

    static func partTextSize(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "04-part") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller
        let medium = file(opened, "Stationery/System/Medium.ini")
        steps.take { Studio2PartSelfTests.click(studio, "MeterCPUValue") }
        guard let row = Studio2PartSelfTests.rowView(studio, "text.size"), let buttons = row.steppers else {
            t.check(false, "\(label): the size row and A+")
            return nil
        }
        t.check(inView(buttons.bigger, studio), "\(label): A+ is in view")
        steps.take { buttons.bigger.performClick(nil) }
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 5, "\(label): a part's text size in \(steps.count) steps")
        t.check(Studio2PartSelfTests.block("MeterCPUValue", in: text(medium)).contains("FontSize=12"),
                "\(label): 16 pt, its own")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoTextSize])
        return steps.count
    }

    static func size(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "03-customize") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, view = studio.inspectorController.pageView
        guard let control = (view.itemView("size") as? StudioRowView)?.controlView as? NSSegmentedControl,
              control.segmentCount == 3 else {
            t.check(false, "\(label): Small · Medium · Large")
            return nil
        }
        t.check(inView(control, studio), "\(label): the sizes are in view")
        steps.take {
            control.selectedSegment = 2
            _ = control.sendAction(control.action, to: control.target)
        }
        t.check(AppSelfTest.spin { opened.app.controller(for: "Stationery\\System")?.skin.fileURL.lastPathComponent == "Large.ini" },
                "\(label): the desktop runs Large")
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 4, "\(label): the size in \(steps.count) steps")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoSize])
        return steps.count
    }

    static func shows(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "03-customize") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, view = studio.inspectorController.pageView
        let medium = file(opened, "Stationery/System/Medium.ini")
        // The first ring whose menu offers other data (on System, the fourth: GPU or swap; the others' data is
        // worked out in the widget's own files).
        let candidates = (studio.widgetPage.facts?.shows ?? []).compactMap { row -> (NSPopUpButton, Int)? in
            guard let popup = (view.itemView("shows:\(row.measure)") as? StudioRowView)?.controlView as? NSPopUpButton,
                  let i = (0..<popup.numberOfItems).first(where: { i in
                      i != popup.indexOfSelectedItem && popup.item(at: i)?.isEnabled == true
                  }) else { return nil }
            return (popup, i)
        }
        guard let (popup, index) = candidates.first else {
            t.check(false, "\(label): a ring with other data to choose")
            return nil
        }
        t.check(inView(popup, studio), "\(label): the ring's menu is in view")
        let before = text(medium)
        steps.take()
        steps.take {
            popup.selectItem(at: index)
            _ = popup.sendAction(popup.action, to: popup.target)
        }
        t.check(text(medium) != before || opened.app.controller(for: "Stationery\\System") != nil,
                "\(label): written for this widget")
        t.equal(studio.session?.undoStack.undoActionName, StudioText[.undoShows])
        t.check(view.itemView("shows.confirm") != nil, "\(label): confirmed under the ring")
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 6, "\(label): T1.6 in \(steps.count) steps")
        return steps.count
    }

    static func move(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "04-part") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, canvas = studio.canvasController.canvas
        let medium = file(opened, "Stationery/System/Medium.ini")
        guard let m = studio.skin?.meter(named: "MeterCPUValue") else {
            t.check(false, "\(label): the number")
            return nil
        }
        let start = canvas.viewRect(m.frame)
        let p = NSPoint(x: start.midX, y: start.midY)
        steps.take { Studio2PartSelfTests.click(studio, "MeterCPUValue") }
        steps.take {
            canvas.beginGesture(.move, at: p)
            canvas.drag(to: NSPoint(x: p.x + 10, y: p.y), snapping: false)
            canvas.endGesture(keep: true)
        }
        t.check(Studio2PartSelfTests.block("MeterCPUValue", in: text(medium)).contains("X=67"), "\(label): moved 10 pt")
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 5, "\(label): T1.7 (move) in \(steps.count) steps")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoMove])
        return steps.count
    }

    static func hide(_ t: AppTestRunner, _ label: String) -> Int? {
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "04-part") }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller
        let medium = file(opened, "Stationery/System/Medium.ini")
        guard let m = studio.skin?.meter(named: "MeterCPULabel") else {
            t.check(false, "\(label): the label")
            return nil
        }
        var menu: NSMenu?
        steps.take { menu = studio.contextMenu(x: m.frame.x + m.frame.width / 2, y: m.frame.y + m.frame.height / 2) }
        guard let item = menu?.items.first else {
            t.check(false, "\(label): the part's menu")
            return nil
        }
        t.check(item.title.hasPrefix(StudioText.format(.menuHide, "").trimmingCharacters(in: .whitespaces)),
                "\(label): \(item.title)")
        steps.take { menu?.performActionForItem(at: 0) }
        t.check(Studio2PartSelfTests.block("MeterCPULabel", in: text(medium)).contains("Hidden=1"), "\(label): hidden")
        let session = studio.session
        steps.take { studio.doneAction(nil) }
        t.check(steps.count <= 5, "\(label): T1.7 (hide) in \(steps.count) steps")
        t.equal(session?.undoStack.undoActionName, StudioText[.undoHide])
        return steps.count
    }

    /// The widget changed earlier (its CPU ring's color); from the desktop: Customize Look… (2), Revert to Original in
    /// the page's footer (1). The desktop shows it at once; the step is undone like any other.
    static func revert(_ t: AppTestRunner, _ label: String) -> Int? {
        let changed = StudioScreen.FileEdit(path: "System/Medium.ini", find: "CardH=170", replace: "CardH=170\nCPUColor=255,45,85")
        let steps = Steps()
        var opened: StudioSnapshot.Opened?
        steps.take(2) { opened = open(t, "03-customize", edits: [changed]) }
        guard let opened else { return nil }
        defer { opened.close() }
        let studio = opened.controller, view = studio.inspectorController.pageView
        let medium = file(opened, "Stationery/System/Medium.ini")
        guard let shipped = Paths.repositoryFolder("DefaultSkins")?.appendingPathComponent("Stationery/System/Medium.ini")
        else {
            t.check(false, "\(label): the shipped copy")
            return nil
        }
        t.equal(studio.copySentence, StudioText[.copyEdited], "\(label): the copy sentence says it was edited")
        guard let row = view.footerView("revert") else {
            t.check(false, "\(label): Revert to Original in the footer")
            return nil
        }
        t.check(inView(row, studio), "\(label): the footer row is in view")
        t.equal(studio.widgetPage.page?.footer.last?.detail, StudioText[.revertOne], "\(label): what it takes away")
        steps.take { studio.widgetPage.handle(.link("revert")) }
        t.equal(data(medium), data(shipped), "\(label): the file as shipped, byte for byte")
        t.check(AppSelfTest.spin {
            opened.app.controller(for: "Stationery\\System")?.skin.variable("CPUColor").map { $0 != "255,45,85" } ?? false
        }, "\(label): the desktop shows the original")
        t.equal(studio.session?.undoStack.undoActionName, StudioText[.revertToOriginal])
        t.equal(studio.widgetPage.page?.topConfirmation?.text, StudioText[.confirmReverted])
        t.check(view.footerView("revert") == nil, "\(label): nothing left to revert")
        t.check(steps.count <= 3, "\(label): T1.8 in \(steps.count) steps")
        // Undone: the change is back.
        studio.session?.undoStack.undo()
        t.check(text(medium).contains("CPUColor=255,45,85"), "\(label): undone")
        return steps.count
    }

    // MARK: The keyboard alone

    static func key(_ window: NSWindow, _ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return }
        if flags.contains(.command), window.performKeyEquivalent(with: event) { return }
        window.sendEvent(event)
    }

    static func keyboardTests(_ t: AppTestRunner) {
        t.suite("Studio2: walkthrough: the keyboard alone") {
            Studio2SelfTests.prepare(t)
            // T1.3 with keys only: ⌃Tab to the inspector, Tab to the Memory swatch, Space, the color typed and Return,
            // Esc, ⌘Return.
            let steps = Steps()
            var opened: StudioSnapshot.Opened?
            steps.take(2) { opened = open(t, "03-customize") }
            guard let opened else { return }
            defer { opened.close() }
            let studio = opened.controller
            guard let window = studio.window else { return t.check(false, "a window") }
            let view = studio.inspectorController.pageView
            guard let memory = view.swatchView(item: "colors", swatch: "part:1") as? StudioSwatchView else {
                return t.check(false, "the Memory swatch")
            }
            var presses = 0
            while studio.focusArea != .inspector, presses < 4 {
                steps.take { key(window, "\t", 48, [.control]) }
                presses += 1
            }
            t.equal(studio.focusArea, .inspector, "⌃Tab reaches the inspector")
            presses = 0
            while window.firstResponder !== memory, presses < 40 {
                steps.take { key(window, "\t", 48) }
                presses += 1
            }
            t.check(window.firstResponder === memory, "Tab reaches the Memory swatch (\(presses) presses)")
            steps.take { key(window, " ", 49) }
            guard let popover = studio.widgetPage.colorPopover else { return t.check(false, "Space opens the popover") }
            // The color typed (⌨, not a step) and Return; then Esc closes the popover (the popover's own keys: there is
            // no popover window off screen, so its field and its close are driven directly).
            steps.take { popover.takeFieldText("#30D158") }
            steps.take { popover.close() }
            let medium = file(opened, "Stationery/System/Medium.ini")
            t.check(text(medium).contains("MemoryColor=48,209,88"), "written: \(Studio2PartSelfTests.block("Variables", in: text(medium)).prefix(200))")
            let session = studio.session
            steps.take { key(window, "\r", 36, [.command]) }
            t.check(StudioWindowController.window(for: opened.app) == nil, "⌘Return is Done")
            t.equal(session?.undoStack.undoActionName, StudioText[.undoColor])
            print("    T1.3 with the keyboard alone: \(steps.count) steps")

            // T1.7 with keys only: a part chosen from the canvas's layers by the keyboard, moved with the arrow keys.
            guard let again = open(t, "04-part") else { return }
            defer { again.close() }
            let s2 = again.controller
            guard let w2 = s2.window else { return t.check(false, "a window") }
            s2.select(part: "MeterCPUValue")
            s2.focus(.canvas)
            t.equal(s2.focusArea, .canvas)
            key(w2, String(UnicodeScalar(NSRightArrowFunctionKey)!), 124)
            key(w2, String(UnicodeScalar(NSRightArrowFunctionKey)!), 124, [.shift])
            s2.geometry.commitNudge()
            let m2 = file(again, "Stationery/System/Medium.ini")
            t.check(Studio2PartSelfTests.block("MeterCPUValue", in: text(m2)).contains("X=68"), "→ and ⇧→: 1 + 10 pt")
            // Return takes the keyboard to the part's page, Esc brings it back.
            key(w2, "\r", 36)
            t.equal(s2.focusArea, .inspector, "Return: the part's page")
            s2.escapeFromInspector()
            t.equal(s2.focusArea, .canvas, "Esc: back to the part")
        }
    }

    // MARK: Twelve controls

    /// Pages that do not keep to twelve controls, and why.
    static let countExceptions: [String: String] = [
        "every-setting": "Every Setting lists every setting of the part on purpose: the twelve are its part page's",
    ]

    /// Built-in widgets whose pages are counted (the ones that ask for no permission while they load).
    static let countedWidgets = ["System", "Clock", "Calendar", "Battery", "Storage", "Temperature", "Timer",
                                 "Countdown", "WorldClock", "AnalogClock", "SentenceClock", "ToDo", "Almanac",
                                 "Daybreak", "Network", "Launcher"]

    static func controlCountTests(_ t: AppTestRunner) {
        t.suite("Studio2: audit: twelve controls on every generated page") {
            Studio2SelfTests.prepare(t)
            t.check(countExceptions.values.allSatisfy { !$0.isEmpty }, "every exception has a reason")
            var pages = 0
            func count(_ page: StudioPage?, _ what: String) {
                guard let page else { return t.check(false, "\(what): a page") }
                pages += 1
                t.check(page.controlCount <= StudioPage.controlLimit,
                        "\(what): \(page.controlCount) controls (at most \(StudioPage.controlLimit))")
            }
            func audit(_ opened: StudioSnapshot.Opened, _ widget: String, parts: Bool) {
                let studio = opened.controller
                count(studio.widgetPage.page, "\(widget): the widget page")
                guard parts, let skin = studio.skin else { return }
                for m in skin.meters {
                    studio.select(part: m.name)
                    count(studio.partPage.page, "\(widget): \(m.name)'s page")
                    // Every Setting is the named exception.
                    studio.partPage.toggleEverySetting()
                    t.check(studio.partPage.page?.id.isEmpty == false, "\(widget): \(m.name)'s Every Setting")
                    studio.partPage.toggleEverySetting()
                }
                for measure in skin.measures {
                    studio.partPage.show(data: measure.name)
                    count(studio.partPage.page, "\(widget): \(measure.name)'s data page")
                }
                studio.select(part: nil)
            }
            for w in countedWidgets {
                let dir = Paths.repositoryFolder("DefaultSkins")?.appendingPathComponent("Stationery/\(w)")
                let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir?.path ?? "")) ?? [])
                    .filter { $0.hasSuffix(".ini") }.sorted()
                guard let file = files.contains("Medium.ini") ? "Medium.ini" : files.first else {
                    t.check(false, "\(w): a variant")
                    continue
                }
                var screen = StudioScreen(name: "audit-\(w)", fixture: .init(source: "DefaultSkins", root: "Stationery",
                                                                            config: "Stationery\\\(w)", file: file),
                                          zoom: 1)
                screen.updates = 2
                guard let opened = StudioSnapshot.open(screen) else {
                    t.check(false, "\(w) opens")
                    continue
                }
                audit(opened, w, parts: w == "System" || w == "Clock" || w == "Battery")
                opened.close()
            }
            for name in ["03b-weather", "13b-compat", "09-every-setting"] {
                guard let opened = open(t, name) else { continue }
                audit(opened, name, parts: true)
                opened.close()
            }
            print("    \(pages) pages counted")
        }
    }

    // MARK: Words (G3)

    /// Every word a menu shows, its submenus' too.
    static func words(in menu: NSMenu) -> String {
        menu.items.map { item in [item.title, item.toolTip ?? "", item.submenu.map(words) ?? ""].joined(separator: " ") }
            .joined(separator: " ")
    }

    static func wordTests(_ t: AppTestRunner) {
        t.suite("Studio2: audit: no engine words on the default pages, the sidebar, the popovers and the menus") {
            Studio2SelfTests.prepare(t)
            for language in [StudioLanguage.english, .chinese] {
                with(language, dark: false) {
                    let chinese = language == .chinese
                    func scan(_ text: String, _ what: String) {
                        var found = Studio2PageSelfTests.engineWords(in: text, chinese: chinese)
                        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
                        for w in Studio2PreviewSelfTests.bannedEnglish where words.contains(w) && !found.contains(w) {
                            found.append(w)
                        }
                        if chinese {
                            // "节" (a section) is an engine word; in 细节 (details) and the like it is not.
                            let plain = ["细节", "调节", "节省", "季节", "节日"].reduce(text) {
                                $0.replacingOccurrences(of: $1, with: "")
                            }
                            found.removeAll { $0 == "节" && !plain.contains("节") }
                            for w in Studio2PreviewSelfTests.bannedChinese where plain.contains(w) && !found.contains(w) {
                                found.append(w)
                            }
                        }
                        // Where the first one is, so a failure says what to change.
                        let context = found.first.flatMap { w -> String? in
                            let needle = w == "#…#" ? "#" : w
                            guard let r = text.range(of: needle, options: .caseInsensitive) else { return nil }
                            let from = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
                            let to = text.index(r.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
                            return String(text[from..<to])
                        } ?? ""
                        t.equal(found, [], "\(language.rawValue): \(what): …\(context)…")
                    }
                    for name in ["03-customize", "03b-weather", "09-every-setting"] {
                        guard let opened = open(t, name) else { continue }
                        defer { opened.close() }
                        let studio = opened.controller
                        let page = studio.inspectorController.pageView
                        // The widget page, as it opens.
                        scan(Studio2PageSelfTests.words(in: page), "\(name): the widget page")
                        // The color popover (its color field shows the file's own notation, allowed for INI).
                        studio.widgetPage.handle(.swatch(item: "colors", swatch: "part:0"))
                        if let popover = studio.widgetPage.colorPopover {
                            popover.field.stringValue = ""
                            scan(Studio2PageSelfTests.words(in: popover.view), "\(name): the color popover")
                            popover.close()
                        }
                        // The preview-only popover and the name's popover.
                        studio.preview.showPreviewPopover()
                        if let p = studio.preview.previewPopoverContent {
                            scan(Studio2PageSelfTests.words(in: p.view), "\(name): the preview popover")
                        }
                        studio.preview.closePreviewPopover()
                        studio.showRunningPopover()
                        if let p = studio.runningPopoverContent {
                            _ = p.view
                            // Its words (the file's path is the file's own).
                            scan([p.titleLabel.stringValue, p.noteLabel.stringValue, p.finderButton.title]
                                .joined(separator: " "), "\(name): the name's popover")
                        }
                        // The canvas's floating controls, and the preview bar's menus.
                        let canvas = studio.canvasController
                        for v in [canvas.previewBar, canvas.zoomCapsule, canvas.captionTag, canvas.statusCapsule] as [NSView] {
                            scan(Studio2PageSelfTests.words(in: v), "\(name): the canvas's controls")
                        }
                        let menus = StudioPreviewMenus()
                        scan(words(in: menus.backdropMenu(studio.preview.state, fidelity: .close, reduceTransparency: true,
                                                          canShowNeighbours: true, neighboursShown: false)),
                             "\(name): the Backdrop menu")
                        scan(words(in: menus.dataMenu(studio.preview.state)), "\(name): the Data menu")
                        // The first part's page as it opens, and its menu on the canvas.
                        if let m = studio.skin?.meters.first(where: { !$0.hidden }) {
                            studio.select(part: m.name)
                            scan(Studio2PageSelfTests.words(in: page), "\(name): \(m.name)'s page")
                            if let menu = studio.contextMenu(x: m.frame.x + m.frame.width / 2, y: m.frame.y + m.frame.height / 2) {
                                scan(words(in: menu), "\(name): the part's menu")
                            }
                            studio.select(part: nil)
                        }
                        // The sidebar: Layers and Add, with Rainmeter details off.
                        studio.setSidebarOpen(true)
                        studio.sidebarController.show(.layers)
                        studio.refreshLayers()
                        scan(studio.sidebarController.snapshotViews.map(Studio2PageSelfTests.words).joined(separator: " "),
                             "\(name): Layers")
                        studio.sidebarController.show(.add)
                        scan(studio.sidebarController.snapshotViews.map(Studio2PageSelfTests.words).joined(separator: " "),
                             "\(name): Add")
                        // The menu bar while the Studio is key.
                        scan(words(in: StudioMenus.make(app: opened.app)), "\(name): the menus")
                    }
                }
            }
        }
    }

    // MARK: Contrast

    /// sRGB relative luminance.
    static func luminance(_ c: NSColor) -> Double {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// The pixels of `rect` (content coordinates) in a snapshot of `content`.
    static func pixels(_ rep: NSBitmapImageRep, _ rect: NSRect, content: NSView) -> [[Double]] {
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        let x0 = max(Int((rect.minX * scale).rounded()), 0), x1 = min(Int((rect.maxX * scale).rounded()), rep.pixelsWide)
        let y0 = max(Int((top * scale).rounded()), 0), y1 = min(Int(((top + rect.height) * scale).rounded()), rep.pixelsHigh)
        guard x1 > x0, y1 > y0 else { return [] }
        return (y0..<y1).map { y in (x0..<x1).map { x in rep.colorAt(x: x, y: y).map(luminance) ?? 0 } }
    }

    /// The contrast of the ink in `rect` against what it sits on: the background is the middle luminance of the
    /// rectangle, the ink the pixels furthest from it (the 98th percentile, so a stray pixel does not decide).
    static func inkContrast(_ rep: NSBitmapImageRep, _ rect: NSRect, content: NSView) -> Double {
        let grid = pixels(rep, rect, content: content)
        guard grid.count > 2, let width = grid.first?.count, width > 2 else { return 0 }
        // What the words sit on is what most of the rectangle is (the words' strokes are a small part of it).
        let all = grid.flatMap { $0 }.sorted()
        let background = all[all.count / 2]
        let contrasts = all.map { ratio($0, background) }.sorted()
        return contrasts[Int(Double(contrasts.count - 1) * 0.98)]
    }

    /// The contrast of a segmented control's chosen segment against the rest of its track (the middles of the two).
    static func segmentContrast(_ rep: NSBitmapImageRep, _ control: NSSegmentedControl, content: NSView) -> Double? {
        let chosen = control.selectedSegment
        guard chosen >= 0, control.segmentCount > 1 else { return nil }
        let r = control.convert(control.bounds, to: content)
        let w = r.width / CGFloat(control.segmentCount)
        func middle(_ i: Int) -> Double? {
            // A thin band just above the label's baseline area: the fill, not the text.
            let band = NSRect(x: r.minX + w * CGFloat(i) + w * 0.15, y: r.midY - 1, width: w * 0.7, height: 2)
            let values = pixels(rep, band, content: content).flatMap { $0 }.sorted()
            // The fill is what most of the band is (the label's strokes are the minority).
            return values.isEmpty ? nil : values[values.count / 5]
        }
        let other = chosen == 0 ? 1 : 0
        guard let a = middle(chosen), let b = middle(other) else { return nil }
        return ratio(a, b)
    }

    static func contrastTests(_ t: AppTestRunner) {
        t.suite("Studio2: audit: contrast measured on the snapshots") {
            Studio2SelfTests.prepare(t)
            for dark in [false, true] {
                with(.english, dark: dark) {
                    let look = dark ? "dark" : "light"
                    for backdrop in [StudioBackdropKind.bright, .busy, .dark] {
                        guard let opened = open(t, "03-customize-changed", tweak: { s in
                            s.backdrop = backdrop
                            s.colorPicked = ("part:1", 4)
                        }) else { continue }
                        defer { opened.close() }
                        let studio = opened.controller
                        studio.preview.showPreviewPopover()
                        guard let content = studio.window?.contentView, let rep = StudioSnapshot.render(studio) else {
                            t.check(false, "\(look), \(backdrop): a snapshot")
                            continue
                        }
                        let canvas = studio.canvasController
                        // What floats on the canvas: its words are labels and notes (4.5 : 1).
                        var floating: [(String, NSView)] = [("caption", canvas.captionTag),
                                                            ("zoom", canvas.zoomCapsule.percentItem)]
                        for (i, item) in [canvas.previewBar.appearanceItem, canvas.previewBar.backdropItem,
                                          canvas.previewBar.dataItem].enumerated() {
                            floating.append(("preview bar \(i)", item))
                        }
                        for (what, view) in floating where !view.isHiddenOrHasHiddenAncestor {
                            let c = inkContrast(rep, view.convert(view.bounds, to: content), content: content)
                            t.check(c >= 4.5, String(format: "%@, %@: %@ %.2f : 1", look, "\(backdrop)", what, c))
                        }
                        // The preview popover's labels and footer (composed off screen at the bar).
                        if let p = studio.preview.previewPopoverContent {
                            for label in [p.titleLabel, p.footerLabel] {
                                t.check(!label.stringValue.isEmpty, "\(look): the popover's words")
                            }
                        }
                        // The inspector: a row's label, a section's note, the confirmation and its Undo (the page is
                        // the same over every backdrop: measured once).
                        guard backdrop == .bright else { continue }
                        let page = studio.inspectorController.pageView
                        var inspector: [(String, NSView?)] = []
                        if let row = page.itemView("font:numbers") as? StudioRowView { inspector.append(("row label", row.label)) }
                        inspector.append(("confirmation", page.itemView("colors.confirm")))
                        inspector.append(("footer", page.footerView("revert")))
                        for (what, view) in inspector {
                            guard let view, !view.isHiddenOrHasHiddenAncestor else {
                                t.check(false, "\(look): \(what) on the page")
                                continue
                            }
                            let c = inkContrast(rep, view.convert(view.bounds, to: content), content: content)
                            t.check(c >= 4.5, String(format: "%@: %@ %.2f : 1", look, what, c))
                        }
                        // The chosen segment against its track (3 : 1): the size, the preview popover's look.
                        if let size = (page.itemView("size") as? StudioRowView)?.controlView as? NSSegmentedControl {
                            // 3 : 1, or a mark that does not rely on color (Dark Mode: a check mark).
                            let c = segmentContrast(rep, size, content: content) ?? 0
                            let marked = size.image(forSegment: size.selectedSegment) === StudioPageStyle.segmentMark
                            t.check(c >= 3 || marked, String(format: "%@: the chosen size %.2f : 1%@", look, c,
                                                             marked ? ", with a check mark" : ""))
                            if c < 3 { print(String(format: "    %@: the chosen size %.2f : 1 and a check mark", look, c)) }
                        } else {
                            t.check(false, "\(look): the size row")
                        }
                    }
                }
            }
        }
    }

    // MARK: Layout and Chinese

    /// Every label under `view` that is cut: shown on one line in less room than its words need.
    static func cutLabels(in view: NSView) -> [String] {
        var cut: [String] = []
        func walk(_ v: NSView) {
            guard !v.isHiddenOrHasHiddenAncestor else { return }
            // A number box's text is cut too when its box is too narrow ("14.5" as "14…").
            if let f = v as? NSTextField, !f.stringValue.isEmpty, f.maximumNumberOfLines <= 1, f.cell?.wraps != true,
               f.lineBreakMode == .byTruncatingTail || f.lineBreakMode == .byTruncatingMiddle || f.isEditable,
               f.frame.width > 1, f.fittingSize.width > f.frame.width + 1.5 {
                cut.append("“\(f.stringValue)” (\(Int(f.fittingSize.width)) in \(Int(f.frame.width)))")
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return cut
    }

    static func layoutTests(_ t: AppTestRunner) {
        t.suite("Studio2: audit: Chinese in Apple's style") {
            // The table: full-width punctuation next to Chinese, a space between Chinese and Latin or digits.
            for key in StudioText.Key.allCases {
                guard let entry = StudioText.table[key] else { continue }
                let problems = StudioSchemaChinese.styleProblems(entry.zh)
                t.equal(problems, [], "\(key.rawValue): \(entry.zh)")
            }
            // Where the sentence meets what is filled in, a space goes between Chinese and Latin or digits; the
            // filled-in text itself is left alone.
            let before = StudioText.languageOverride
            StudioText.languageOverride = .chinese
            defer { StudioText.languageOverride = before }
            t.equal(StudioText.format(.scopeOnly, "CPU"), "只改这个 CPU")
            t.equal(StudioText.format(.scopeOnly, "数字"), "只改这个数字")
            t.equal(StudioText.format(.confirmColor, "CPU 圆环", "薄荷绿"), "CPU 圆环已改为薄荷绿")
            t.equal(StudioText.format(.confirmHidden, "“CPU”"), "“CPU”已隐藏", "quotes need no space")
            t.equal(StudioText.format(.scopeApplyAll, 4, "数字"), "应用到全部 4 个数字")
            t.equal(StudioText.format(.confirmMoved, "MeterCPU值"), "已移动 MeterCPU值", "the value itself is as written")
            t.equal(StudioText.format(.subtitleOf, "数字", "CPU"), "CPU 的数字")
            t.equal(StudioText.spacedFormat("%@%%", ["23"]), "23%", "a percent sign is not a specifier")
            // Titles in Songti SC; New York in English.
            t.equal(StudioPageStyle.titleFont().familyName, "Songti SC")
            StudioText.languageOverride = .english
            t.check(StudioPageStyle.titleFont().familyName != "Songti SC", "not Songti in English")
        }

        t.suite("Studio2: audit: no label is cut") {
            Studio2SelfTests.prepare(t)
            for v in variants {
                with(v.language, dark: v.dark) {
                    let label = name(v.language, v.dark)
                    for screen in ["03-customize-changed", "03b-weather", "04-part", "07-layers", "09-every-setting",
                                   "10-preview", "13b-compat", "17-show-on-desktop"] {
                        guard let base = StudioScreen.named(screen), let opened = StudioSnapshot.open(base) else {
                            t.check(false, "\(screen) opens")
                            continue
                        }
                        let studio = opened.controller
                        studio.window?.contentView?.layoutSubtreeIfNeeded()
                        studio.inspectorController.pageView.layoutSubtreeIfNeeded()
                        var cut = cutLabels(in: studio.inspectorController.pageView)
                        if let p = studio.preview.previewPopoverContent {
                            p.view.layoutSubtreeIfNeeded()
                            cut += cutLabels(in: p.view)
                        }
                        t.equal(cut, [], "\(label), \(screen)")
                        opened.close()
                    }
                }
            }
        }
    }
}
