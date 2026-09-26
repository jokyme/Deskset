import AppKit
import DesksetCore

/// `Deskset --self-test "Friendly widget page"`: the inspector with nothing selected (docs/editor-friendly.md §8.1,
/// WP-B) — COLORS AND FONTS, UPDATE SPEED, ON YOUR DESKTOP, SIZE AND SPACING and the disclosures — where an edit is
/// written (§7.5: `ScopeResolver`, the toasts that widen it, ↺ Match the Others), and the color control and linked
/// values every page uses (§7.3–7.4).
enum FriendlyWidgetPageSelfTests {
    static func run(_ t: AppTestRunner) {
        scopeTests(t)
        pageTests(t)
        layoutTests(t)
        oneLayoutTests(t)
        plainWordsTests(t)
        editTests(t)
        colorPanelTests(t)
        desktopTests(t)
        widgetOptionsTests(t)
        sharedFileTests(t)
        suiteTests(t)
        controlTests(t)
    }

    typealias Editor = InspectorWindowController

    /// Ends the current event: the undo manager groups what one event registers (as in the app).
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// The text of one section of a file (up to the next header).
    static func section(_ name: String, in text: String) -> String {
        guard let r = text.range(of: "[\(name)]") else { return "" }
        let rest = text[r.upperBound...]
        return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
    }

    static func find(_ editor: Editor, _ id: String) -> NSView? {
        editor.inspectorStack.findSubview { $0.identifier?.rawValue == id }
    }

    /// A label's text with the page's non-breaking spaces as plain ones.
    static func text(_ editor: Editor, _ id: String) -> String? {
        (find(editor, id) as? NSTextField)?.stringValue.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Opens every disclosure of the widget page (as a person could, one by one), without Rainmeter Details.
    static func openEverything(_ editor: Editor) {
        editor.inspectorState.disclosures.formUnion(["widget/issues", "widget/about", "widget/more", "widget/desktop-more",
                                                     "widget/colors-more", "widget/other-colors"])
        editor.rebuildInspector()
    }

    /// Chooses the item of a pop-up whose title (or represented value) matches, as a click would.
    @discardableResult
    static func choose(_ popup: NSPopUpButton?, _ title: String) -> Bool {
        guard let popup, let item = popup.itemArray.first(where: { $0.title == title || ($0.representedObject as? String) == title })
        else { return false }
        popup.select(item)
        popup.sendAction(popup.action, to: popup.target)
        return true
    }

    /// A headless app with these files written into its widgets folder (paths relative to it) and the editor open on
    /// `config`.
    static func openScratch(_ t: AppTestRunner, files: [String: String], config: String) throws
        -> (app: AppController, editor: Editor)? {
        guard let app = try AppSelfTest.makeApp(t) else { return nil }
        for (path, text) in files {
            let url = app.skinsDirectory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        app.rescanLibrary()
        guard let c = app.activate(config: config, file: nil) else {
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

    /// What a person reads on the page in its default state (Rainmeter Details off) that uses engine words (§3.3, G3):
    /// labels, buttons, pop-ups and segments — not the widget's own content in editable fields.
    static func engineWords(_ editor: Editor) -> [String] {
        var words: [String] = []
        for v in editor.inspectorStack.subviewsMatching({ !$0.isHiddenOrHasHiddenAncestor }) {
            switch v {
            case let popup as NSPopUpButton:
                words += popup.pullsDown ? popup.itemArray.map(\.title) : [popup.titleOfSelectedItem ?? ""]
            case let button as NSButton:
                words.append(button.title)
            case let seg as NSSegmentedControl:
                words += (0..<seg.segmentCount).compactMap { seg.label(forSegment: $0) }
            case let field as NSTextField where !field.isEditable:
                words.append(field.stringValue)
            default:
                break
            }
        }
        return words.filter { WidgetPresets.isEngineText($0) }
    }

    /// The widget page's color row that changes this variable (or literal color).
    static func colorRow(_ editor: Editor, where match: (ValueUsageIndex.ColorGroup) -> Bool) -> ValueRowView? {
        editor.inspectorStack.subviewsMatching { ($0 as? ValueRowView)?.group.map(match) == true }.first as? ValueRowView
    }

    /// Everything a person reads on the page: labels, button titles, menus as closed, segment labels, field text.
    static func visibleWords(_ editor: Editor) -> [String] {
        var words: [String] = []
        for v in editor.inspectorStack.subviewsMatching({ !$0.isHiddenOrHasHiddenAncestor }) {
            switch v {
            case let popup as NSPopUpButton:
                if !popup.pullsDown { words.append(popup.titleOfSelectedItem ?? "") }
            case let button as NSButton:
                words.append(button.title)
            case let seg as NSSegmentedControl:
                words += (0..<seg.segmentCount).compactMap { seg.label(forSegment: $0) }
            case let field as NSTextField:
                words.append(field.stringValue)
            default:
                break
            }
        }
        return words.filter { !$0.isEmpty }
    }

    // MARK: Where an edit is written (§7.5)

    static func scopeTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: the narrowest place that covers the selection") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let skin = editor.skin else { return }
            let resolver = ScopeResolver(skin: skin)
            let bands = (0...15).map { "MeterBand\($0)" }
            // One bar of the 16 sharing StyleBand: its own key.
            let fill = resolver.target(section: "MeterBand5", key: "BarColor", selection: ["MeterBand5"])
            t.equal(fill.scope, .own, "one bar of 16: that bar")
            t.equal([fill.section, fill.key], ["MeterBand5", "BarColor"])
            t.equal(fill.file, skin.fileURL)
            // All 16: the look.
            t.equal(resolver.target(section: "MeterBand5", key: "BarColor", selection: bands).scope, .look("StyleBand"))
            // The shared value: only when the selection is every user (Accent: 16 bands and 2 level bars).
            t.equal(resolver.target(section: "MeterBand5", key: "BarColor", selection: bands, variable: "Accent").scope,
                    .look("StyleBand"), "16 of Accent's 18 users: the look")
            t.equal(resolver.target(section: "MeterBand5", key: "BarColor", selection: bands + ["MeterLeft", "MeterRight"],
                                    variable: "Accent").scope, .sharedValue("Accent"))
            let size = resolver.target(section: "MeterTitle", key: "FontSize", selection: ["MeterTitle"])
            t.equal(size.scope, .own)
            let shared = resolver.target(section: "MeterTitle", key: "FontColor", selection: ["MeterTitle"], variable: "Text")
            t.equal(shared.scope, .sharedValue("Text"), "Text's only user")
            t.equal([shared.section, shared.key], ["Variables", "Text"])
            // X of Band1…15 comes from each band itself (X=#BarGap#R): no look covers it.
            let x = resolver.target(section: "MeterBand5", key: "X", selection: Array(bands.dropFirst()))
            t.equal(x.scope, .own)
            t.equal(x.sections.count, 15, "each selected band's own key")
            // Not a layer: where the option is defined.
            t.equal(resolver.target(section: "Rainmeter", key: "Update", selection: ["Rainmeter"]).scope, .own)

            editor.canvasSelectionChanged([])
            t.check(editor.isSkinSelected)
        }
    }

    // MARK: The page (§8.1)

    static func pageTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: cards, plain words, who uses what") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let skin = editor.skin else { return }
            editor.canvasSelectionChanged([])
            // Card order.
            let cards = editor.inspectorStack.arrangedSubviews.compactMap { $0.identifier?.rawValue }
                .filter { $0.hasPrefix("card:") }
            t.equal(Array(cards.prefix(4)), ["card:COLORS AND FONTS", "card:UPDATE SPEED", "card:ON YOUR DESKTOP",
                                             "card:SIZE AND SPACING"])
            t.equal(Array(cards.dropFirst(4)), ["card:widget/about", "card:widget/more"], "then the disclosures")
            t.check(find(editor, "widget-tip") == nil, "no tip in self-tests")
            // No engine words, no units in ms, no #Var#, no R,G,B,A (G3 for this page).
            let words = visibleWords(editor)
            for w in words {
                t.check(!w.contains("Refresh"), "“\(w)” says Refresh")
                t.check(!w.contains("#"), "“\(w)” shows a # name")
                t.check(w.range(of: "\\bms\\b", options: .regularExpression) == nil, "“\(w)” shows ms")
                t.check(w.range(of: "^\\s*\\d+\\s*,\\s*\\d+\\s*,\\s*\\d+", options: .regularExpression) == nil, "“\(w)” is R,G,B")
                for banned in ["skin", "meter", "measure", "section", "variable", "MeterStyle", "INI"] {
                    t.check(w.range(of: "\\b\(banned)\\b", options: [.regularExpression, .caseInsensitive]) == nil,
                            "“\(w)” says \(banned)")
                }
            }
            t.check(!words.contains("120,200,255,255"))
            t.check(words.contains("A widget with 26 layers that updates 40 times a second."), "the header's sentence")

            // COLORS AND FONTS: roles, counts, opacity; the six colors in order.
            let names = (0..<6).compactMap { (find(editor, "color-name:\($0)") as? NSTextField)?.stringValue }
            t.equal(Array(names.prefix(5)), ["Bar color", "Empty part of bars", "Small text", "Title text", "Background panel"])
            t.equal((find(editor, "color-count:0") as? NSButton)?.title, "18 bars")
            t.equal((find(editor, "color-count:2") as? NSButton)?.title, "5 texts")
            t.equal((find(editor, "color-opacity:1") as? NSTextField)?.stringValue, "11%", "Track is 28 of 255")
            t.check(find(editor, "color-name:6") == nil, "no seventh color")
            // Swatches are drawn on the widget's panel color, not a checkerboard.
            let swatch = find(editor, "color-swatch:1") as? SwatchButton
            t.equal(swatch?.backdrop, OptionValue.color("16,19,28,235"))
            // Hovering a row outlines its users; its count selects them.
            guard let bar = colorRow(editor, where: { $0.variables == ["Accent"] }) else { return t.check(false, "Bar color row") }
            let rebuilds = editor.inspectorRebuildCount
            bar.onHover?(true)
            t.equal(editor.canvas.relatedNames.count, 18)
            bar.onHover?(false)
            t.equal(editor.canvas.relatedNames, [])
            t.equal(editor.inspectorRebuildCount, rebuilds, "hovering does not rebuild")
            (find(editor, "color-count:0") as? NSButton)?.performClick(nil)
            t.equal(editor.canvas.selectedNames.count, 18, "the count selects the 18 bars")
            t.equal(editor.selectedMeters.count, 18)
            editor.canvasSelectionChanged([])
            // Fonts: one row per source.
            t.check(find(editor, "font-row:Title text") != nil && find(editor, "font-row:Small text") != nil, "font rows")
            t.equal((find(editor, "font-count:Small text") as? NSButton)?.title, "5 texts")

            // UPDATE SPEED: the preset in words.
            t.equal((find(editor, "update-speed") as? NSPopUpButton)?.titleOfSelectedItem, "Real-time — 40 times a second")
            t.equal((find(editor, "update-caption") as? NSTextField)?.stringValue, "Smoothest animation. Uses the most battery.")

            // SIZE AND SPACING: the Background layer, shared sizes with who uses them, the calculated width.
            t.check((find(editor, "behind-everything") as? NSTextField)?.stringValue.hasPrefix("Nothing — the dark panel is the layer")
                    == true)
            t.equal((find(editor, "size-count:BarW") as? NSButton)?.title, "16 bars")
            t.equal((find(editor, "size-count:BarGap") as? NSButton)?.title, "15 bars")
            t.check((find(editor, "size-count:BarH") as? NSButton)?.title.hasPrefix("16 bars and ") == true, "and the label under them")
            t.equal((find(editor, "size-value:Width") as? NSTextField)?.stringValue, "217 px · calculated")
            t.equal((find(editor, "size:BarW") as? NumberControl)?.field.stringValue, "9")
            // Pointing at a shared size outlines who uses it too (P7); Left reaches the peak marker through its formula.
            (find(editor, "size-row:BarW") as? ValueRowView)?.onHover?(true)
            t.equal(editor.canvas.relatedNames.count, 16)
            (find(editor, "size-row:BarW") as? ValueRowView)?.onHover?(false)
            t.equal((find(editor, "size-count:Left") as? NSButton)?.title, "10 layers")

            // The header's ⋯ menu.
            t.equal((find(editor, "widget-more") as? NSPopUpButton)?.itemArray.map(\.title).filter { !$0.isEmpty },
                    ["Show in Code", "Reveal in Finder", "Show in Manage Widgets", "Reload Widget"])

            // More Widget Options: closed (nothing in use; Tight text boxes is quiet).
            t.equal(text(editor, "disclosure-summary:widget/more"), "timing, right-click menu, actions, looks")
            t.check(find(editor, "redraw-layers") == nil, "closed")
            (find(editor, "disclosure:widget/more") as? NSButton)?.performClick(nil)
            t.check(find(editor, "redraw-layers") != nil, "opened")
            t.check(editor.inspectorStack.findSubview { $0.identifier?.rawValue == "look:StyleBand" } != nil, "looks listed")
            t.equal((find(editor, "look:StyleBand") as? NSButton)?.title, "Band look · 16 bars ›")
            // Rainmeter Details: names, every More open.
            editor.app.state.updateEditor { $0.showIniNames = true }
            editor.rebuildInspector()
            t.check(find(editor, "about:Name") != nil && find(editor, "widget-DynamicWindowSize") != nil, "every disclosure open")
            t.equal((find(editor, "color-variables:0") as? NSTextField)?.stringValue, "Accent")
            t.check((find(editor, "update-caption") as? NSTextField)?.stringValue.contains("Update=25") == true)
            editor.app.state.updateEditor { $0.showIniNames = false }
            _ = skin
        }
    }

    // MARK: Nothing cut off (G1)

    static func layoutTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: every row's name is shown whole") {
            for (config, folder) in [("Audio\\Visualizer", "TestSkins"), ("Deskset\\System", "DefaultSkins"),
                                     ("Deskset\\Clock", "DefaultSkins"), ("Deskset\\Calendar", "DefaultSkins")] {
                guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: config, from: folder) else { return }
                editor.canvasSelectionChanged([])
                editor.inspectorState.disclosures.insert("widget/colors-more")
                editor.rebuildInspector()
                // The narrowest inspector there is.
                editor.inspectorWidthConstraint?.constant = Editor.PaneSize.inspectorMin
                editor.window?.contentView?.layoutSubtreeIfNeeded()
                let names = editor.inspectorStack.subviewsMatching {
                    guard let id = $0.identifier?.rawValue else { return false }
                    return id.hasPrefix("color-name:") || id.hasPrefix("font-name:") || id.hasPrefix("size-name:")
                }.compactMap { $0 as? NSTextField }
                t.check(names.count >= 8, "\(config): \(names.count) rows")
                for name in names {
                    let fitting = name.fittingSize.width, frame = name.frame
                    t.check(frame.width > 0 && fitting <= frame.width + 0.5,
                            "\(config): “\(name.stringValue)” is cut off (\(fitting) of \(frame.width))")
                    // Wrapped to a second line: every line shows.
                    let needed = name.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: frame.width, height: 10_000)).height ?? 0
                    t.check(needed <= frame.height + 0.5, "\(config): “\(name.stringValue)” needs \(needed) of \(frame.height)")
                }
                let counts = editor.inspectorStack.subviewsMatching {
                    guard let id = $0.identifier?.rawValue else { return false }
                    return id.hasPrefix("color-count:") || id.hasPrefix("font-count:") || id.hasPrefix("size-count:")
                }.compactMap { $0 as? NSButton }
                for count in counts where !count.isHiddenOrHasHiddenAncestor {
                    t.check(count.fittingSize.width <= count.frame.width + 0.5, "\(config): “\(count.title)” is cut off")
                }
            }
        }
    }

    // MARK: One layout in every window

    /// The views the editor window shows whose layout is ambiguous — their constraints allow more than one, and AppKit
    /// settles on one or another from one window to the next (the header was 72 pt in some editors built alike, 76 pt
    /// in others) — laid out first.
    static func ambiguousViews(_ editor: Editor) -> [String] {
        guard let content = editor.window?.contentView else { return ["no window"] }
        content.layoutSubtreeIfNeeded()
        return ([content] + content.subviewsMatching { !$0.isHiddenOrHasHiddenAncestor })
            .filter(\.hasAmbiguousLayout)
            .map { "\(type(of: $0)) \($0.identifier?.rawValue ?? "") \(NSStringFromRect($0.frame))" }
    }

    /// The pages of the editor's widget, each once: the widget page (nil), its layers, live data, looks and sections. A
    /// run of repeated layers or live data (the 16 sound bars) stands for its members by its first: their pages are alike.
    static func everyPage(_ editor: Editor) -> [String?] {
        guard let skin = editor.skin else { return [] }
        let repeats = Set(LayerSeries.detect(in: skin).flatMap { $0.members.dropFirst() }.map { $0.lowercased() })
        return [nil] + editor.allItems.map(\.title).filter { !repeats.contains($0.lowercased()) }
    }

    /// Checks that `pages` of the editor's widget are laid out one way only, with overlay and legacy scroll bars (legacy
    /// ones take their width from the page) and with View ▸ Show Rainmeter Details off and on, or as `details` says.
    static func checkOneLayout(_ t: AppTestRunner, _ editor: Editor, pages: [String?], details: [Bool] = [false, true]) {
        let widget = editor.skin?.config ?? ""
        for style in [NSScroller.Style.overlay, .legacy] {
            editor.inspectorScroll.scrollerStyle = style
            for on in details {
                editor.app.state.updateEditor { $0.showIniNames = on }
                // (Rebuilt for the new state; each page after is built when it is selected.)
                editor.canvasSelectionChanged([])
                for page in pages {
                    autoreleasepool {
                        if let page { editor.select(section: page) } else { editor.canvasSelectionChanged([]) }
                        t.equal(ambiguousViews(editor), [], "\(widget): \(page ?? "the widget page"), "
                                + (style == .legacy ? "legacy" : "overlay") + " scroll bars" + (on ? ", Rainmeter Details" : ""))
                    }
                }
            }
        }
        editor.app.state.updateEditor { $0.showIniNames = false }
    }

    static func oneLayoutTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: one layout in every window, every page of the Visualizer") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer") else { return }
            // Both kinds of scroll bars: legacy ones take their width from the page.
            for style in [NSScroller.Style.overlay, .legacy] {
                let bars = style == .legacy ? "legacy scroll bars" : "overlay scroll bars"
                editor.inspectorScroll.scrollerStyle = style
                editor.inspectorState.disclosures = []
                editor.canvasSelectionChanged([])
                editor.rebuildInspector()
                t.equal(ambiguousViews(editor), [], "the widget page, \(bars)")
                // The header keeps its inset under the picture and the words beside it.
                if let header = find(editor, "widget-header") as? NSStackView {
                    let tallest = header.arrangedSubviews.map(\.frame.height).max() ?? 0
                    t.close(header.frame.height, tallest + 4, accuracy: 0.5, "the header's bottom inset, \(bars)")
                } else {
                    t.check(false, "the header")
                }
                // The tip of the editor's first opening (at the top of the page there).
                editor.add(editor.widgetTipLine())
                t.equal(ambiguousViews(editor), [], "the first-run tip, \(bars)")
                // Every disclosure open, then with Rainmeter Details: rows whose labels take two lines or more.
                openEverything(editor)
                t.equal(ambiguousViews(editor), [], "every disclosure open, \(bars)")
                editor.app.state.updateEditor { $0.showIniNames = true }
                editor.rebuildInspector()
                t.equal(ambiguousViews(editor), [], "with Rainmeter Details, \(bars)")
                editor.app.state.updateEditor { $0.showIniNames = false }
            }
            // Its layers, live data, looks and sections: the identity strip's line of Rainmeter details, the shape list,
            // insets beside a label of several lines, a formula's value, a unit longer than the narrow column has room
            // for ("milliseconds").
            checkOneLayout(t, editor, pages: everyPage(editor))
            editor.toast.show("Bar width changed on 16 bars")
            t.equal(ambiguousViews(editor), [], "a toast")
            editor.toast.show("Undid Change Bar Width", actions: [ToastAction("Redo") {}])
            t.equal(ambiguousViews(editor), [], "a toast with a button")
            editor.toast.hide()
        }
        t.suite("App: friendly widget page: one layout in every window, pages of the sample widgets") {
            // Values linked to a shared value that are text (the language, the disk), formulas, a shape's parts, a
            // color whose opacity reads under its name.
            for (config, pages) in [("Deskset\\Calendar", ["MeasureTitle", "MeasureCell13"]),
                                    ("Deskset\\Clock", ["MeasureWeekday", "MeasureWeek", "MeterMinute"]),
                                    ("Deskset\\System", ["MeterCPUGraph", "MeasureSwap", "MeterRAMBar"]),
                                    ("Deskset\\Disk", ["MeasureTotal"])] {
                guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: config, from: "DefaultSkins") else { return }
                checkOneLayout(t, editor, pages: pages)
                AppSelfTest.closeEditors()
            }
        }
        t.suite("App: friendly widget page: one layout in every window, rows of test widgets") {
            // An action's sentence and "Edit in Code ›" beside a label of three lines; an option name beside the words
            // of a setting in a narrow column; a look's name too long for its token; a value of several lines beside
            // its sparkline; a long option name beside the line it is written on.
            for (config, file, pages, details) in [("App\\Focus", nil, [nil, "Rainmeter"], [true]),
                                                   ("App\\Background", "Margins.ini", [nil], [true]),
                                                   ("Engine\\Compat", "EarlyGeometry.ini", ["Dot1"], [true]),
                                                   ("String\\Inline", nil, ["MeasureText"], [false]),
                                                   ("App\\MousePlugin", nil, ["MeasureMouse"], [true])] as [(String, String?, [String?], [Bool])] {
                guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: config, file: file) else { return }
                checkOneLayout(t, editor, pages: pages, details: details)
                AppSelfTest.closeEditors()
            }
            // A rule read as a sentence of two lines, beside its "Edit as Text".
            let ini = """
                [Rainmeter]
                Update=1000

                [MeasureQuit]
                Measure=Calc
                Formula=0
                IfCondition=MeasureQuit = 0
                IfTrueAction=[!DisableMeasure MeasureGone]

                [MeasureGone]
                Measure=Calc
                Formula=1

                [MeterValue]
                Meter=String
                MeasureName=MeasureQuit
                """
            guard let (_, editor) = try openScratch(t, files: ["Rules/Rules.ini": ini], config: "Rules") else { return }
            checkOneLayout(t, editor, pages: ["MeasureQuit"], details: [false])
            t.check(find(editor, "rule-0-text") != nil, "the rule reads as a sentence (More Live Data Options open by itself)")
        }
    }

    // MARK: Plain words everywhere (G3)

    static func plainWordsTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: no engine words, every disclosure open") {
            for (config, folder) in [("Audio\\Visualizer", "TestSkins"), ("Deskset\\System", "DefaultSkins"),
                                     ("App\\Unsupported", "TestSkins"), ("Deskset\\Calendar", "DefaultSkins")] {
                guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: config, from: folder) else { return }
                t.equal(editor.app.state.editor.showIniNames, false)
                editor.canvasSelectionChanged([])
                openEverything(editor)
                t.check(find(editor, "redraw-layers") != nil && find(editor, "fade-time") != nil, "\(config): all open")
                t.equal(engineWords(editor), [], "\(config)")
            }
            // What doesn't work on a Mac, in sentences; the notes as written only with Rainmeter Details.
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "App\\Unsupported") else { return }
            editor.canvasSelectionChanged([])
            openEverything(editor)
            let plugin = editor.displayName(ofSection: "MeasurePlugin")
            let quoted = plugin.hasPrefix("“") ? plugin : "“\(plugin)”"
            let lines = (0..<5).compactMap { text(editor, "issue:\($0)") }
            t.check(lines.contains("\(quoted) uses a Windows add-on (ExampleWindowsPlugin.dll), so it stays empty on a Mac."),
                    "\(lines)")
            t.check(lines.contains { $0.hasSuffix("reads a Windows setting, so it stays empty on a Mac.") }, "\(lines)")
            t.check(lines.contains { $0.hasSuffix("runs a script file that is missing (Example.lua).") }, "\(lines)")
            t.check(!editor.inspectorStack.subviewsMatching { ($0 as? NSTextField)?.stringValue.hasPrefix("Plugin \"") == true }
                .contains { !$0.isHiddenOrHasHiddenAncestor }, "the raw note is not shown")
            editor.app.state.updateEditor { $0.showIniNames = true }
            editor.rebuildInspector()
            t.check(editor.inspectorStack.findSubview { ($0 as? NSTextField)?.stringValue.hasPrefix("Plugin \"ExampleWindowsPlugin") == true }
                    != nil, "with Rainmeter Details, the note as written")
            editor.app.state.updateEditor { $0.showIniNames = false }
        }
    }

    // MARK: Edits (§8.1.1–8.1.4, §7.5)

    static func editTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: edits, one undo step each") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let ini = editor.skin?.fileURL else { return }
            editor.canvasSelectionChanged([])
            let original = read(ini)

            // Update speed: "Every second" writes Update=1000; the sound bars will move in jumps.
            guard let popup = find(editor, "update-speed") as? NSPopUpButton,
                  let second = popup.menu?.items.first(where: { $0.title == "Every second (standard)" }) else {
                return t.check(false, "update speed pop-up")
            }
            popup.select(second)
            popup.sendAction(popup.action, to: popup.target)
            t.check(section("Rainmeter", in: read(ini)).contains("Update=1000\n"), "Update=1000")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Update Speed")
            t.equal(editor.toastText, "Now updates every second")
            let warning = editor.inspectorStack.findSubview { $0.identifier?.rawValue == "update-warning" }
            t.check(warning?.subviewsMatching { ($0 as? NSTextField)?.stringValue == "The sound bars will move in jumps." }.isEmpty == false,
                    "the sound warning")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(read(ini), original, "one undo step")
            settle()

            // A shared color: all its users follow, the variable is written.
            guard let track = colorRow(editor, where: { $0.variables == ["Track"] })?.group else { return t.check(false, "Track row") }
            editor.editColorRow(track)
            editor.previewColorEdit(RGBA(r: 255, g: 0, b: 0, a: 28))
            t.equal(editor.skin?.meter(named: "MeterBand3")?.solidColor, RGBA(r: 255, g: 0, b: 0, a: 28), "previewed live")
            editor.commitColorEdit()
            t.check(section("Variables", in: read(ini)).contains("Track=255,0,0,28\n"), "the shared color written")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Empty Part of Bars Color")
            t.equal(editor.toastText, "Empty part of bars changed on 18 bars")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // A literal color: every place this widget writes it, the Shape string included.
            guard let panel = colorRow(editor, where: { $0.variables.isEmpty && $0.role == "Background panel" })?.group else {
                return t.check(false, "Background panel row")
            }
            editor.editColorRow(panel)
            editor.previewColorEdit(RGBA(r: 1, g: 2, b: 3, a: 235))
            editor.commitColorEdit()
            t.check(read(ini).contains("Shape=Rectangle 0,0,#Width#,196,10 | Fill Color 1,2,3,235 | StrokeWidth 0\n"), "inside the Shape")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Background Panel Color")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(read(ini), original)
            settle()

            // Update speed, Custom…: a number of seconds.
            guard let speed = find(editor, "update-speed") as? NSPopUpButton else { return t.check(false, "update speed") }
            t.check(choose(speed, "custom"))
            guard let seconds = find(editor, "update-seconds") as? NumberField else { return t.check(false, "the seconds field") }
            seconds.type("2.5")
            t.check(section("Rainmeter", in: read(ini)).contains("Update=2500\n"))
            t.equal((find(editor, "update-speed") as? NSPopUpButton)?.titleOfSelectedItem, "Custom — every 2.5 seconds")
            t.equal(editor.toastText, "Now updates every 2.5 seconds")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(read(ini), original)
            settle()

            // A font face from a look.
            guard let face = find(editor, "font-face:Small text") as? NSPopUpButton,
                  let system = face.itemArray.first(where: { ($0.representedObject as? String) == "System Font" }) else {
                return t.check(false, "the Small text font pop-up")
            }
            face.select(system)
            face.sendAction(face.action, to: face.target)
            t.check(section("StyleSmall", in: read(ini)).contains("FontFace=System Font\n"), section("StyleSmall", in: read(ini)))
            t.equal(editor.window?.undoManager?.undoActionName, "Change Font of Small Text")
            t.equal(editor.toastText, "Font changed on 5 texts")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // A shared size.
            (find(editor, "size:BarW") as? NumberControl)?.field.type("11")
            settle()
            t.check(section("Variables", in: read(ini)).contains("BarW=11\n"))
            t.equal(editor.skin?.meter(named: "MeterBand0")?.frame.width, 11, "every bar follows")
            editor.window?.undoManager?.undo()
            settle()

            // A font size from a look.
            (find(editor, "font-size:Small text") as? NumberControl)?.field.type("9")
            settle()
            t.check(section("StyleSmall", in: read(ini)).contains("FontSize=9\n"), "the look's size")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Font Size of Small Text")
            editor.window?.undoManager?.undo()
            settle()

            // A look opened by itself: written there, and named in words.
            editor.writeProperty(section: "StyleSmall", key: "FontSize", value: "7", variable: nil, label: "Size")
            t.check(section("StyleSmall", in: read(ini)).contains("FontSize=7\n"))
            t.equal(editor.toastText, "Changed the small look", "no section names in toasts")
            editor.window?.undoManager?.undo()
            settle()

            // Size: fixed, then fitting its content again.
            (find(editor, "widget-size-mode") as? NSSegmentedControl).map { seg in
                seg.selectedSegment = 1
                seg.sendAction(seg.action, to: seg.target)
            }
            t.check(section("Rainmeter", in: read(ini)).contains("SkinWidth=217\n"), "fixed at today's size")
            t.check(find(editor, "widget-SkinWidth") != nil, "W and H fields")
            (find(editor, "widget-size-mode") as? NSSegmentedControl).map { seg in
                seg.selectedSegment = 0
                seg.sendAction(seg.action, to: seg.target)
            }
            t.check(!read(ini).contains("SkinWidth"), "fits its content")
            settle()

            // About This Widget.
            (find(editor, "disclosure:widget/about") as? NSButton)?.performClick(nil)
            (find(editor, "about:Author") as? ValueField)?.type("Someone")
            t.check(section("Metadata", in: read(ini)).contains("Author=Someone\n"))
            settle()

            // Scope from a selection page: Bar 6's fill, then the look for all 16, then back to matching them.
            editor.select(section: "MeterBand5")
            editor.writeProperty(section: "MeterBand5", key: "BarColor", value: "255,0,0,255", variable: "Accent", label: "Fill")
            t.check(section("MeterBand5", in: read(ini)).contains("BarColor=255,0,0,255\n"), "Bar 6 only")
            t.check(section("StyleBand", in: read(ini)).contains("BarColor=#Accent#\n"), "the look is left alone")
            t.check(section("Variables", in: read(ini)).contains("Accent=120,200,255,255\n"), "the shared color is left alone")
            t.check(editor.toastText.hasSuffix(" only"), editor.toastText)
            t.check(editor.toastActions.contains { $0.title == "Apply to All 16 Bars" },
                    "\(editor.toastActions.map(\.title))")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Fill of \(editor.displayName(ofSection: "MeterBand5"))")
            settle()
            t.check(editor.chooseToastAction("Apply to All 16 Bars"))
            t.check(section("StyleBand", in: read(ini)).contains("BarColor=255,0,0,255\n"), "the look has it")
            t.check(!section("MeterBand5", in: read(ini)).contains("BarColor"), "Bar 6's own key removed")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Fill of 16 Bars")
            settle()
            editor.window?.undoManager?.undo()
            t.check(section("MeterBand5", in: read(ini)).contains("BarColor=255,0,0,255\n") &&
                    section("StyleBand", in: read(ini)).contains("BarColor=#Accent#\n"), "one undo step")
            settle()
            // ↺ Match the Others.
            editor.select(section: "MeterBand5")
            t.check(editor.differsFromItsLook(section: "MeterBand5", key: "BarColor"))
            t.check(editor.matchTheOthersLink(section: "MeterBand5", key: "BarColor") != nil, "the row shows the link")
            editor.matchTheOthers(section: "MeterBand5", key: "BarColor")
            t.check(!section("MeterBand5", in: read(ini)).contains("BarColor"), "removed")
            t.equal(editor.window?.undoManager?.undoActionName, "Match the Others")
            settle()
            // The 16 bars together: the look.
            let bands = (0...15).map { "MeterBand\($0)" }
            editor.selectLayers(bands)
            editor.writeProperty(section: "MeterBand5", key: "BarColor", value: "0,255,0,255", variable: "Accent", label: "Fill")
            t.check(section("StyleBand", in: read(ini)).contains("BarColor=0,255,0,255\n"), "[StyleBand] BarColor=")
            t.equal(editor.toastText, "Changed the 16 bars")
            t.check(editor.toastActions.contains { $0.title == "Change ‘Bar color’ Everywhere" })
            settle()
            t.check(editor.chooseToastAction("Change ‘Bar color’ Everywhere"))
            t.check(section("StyleBand", in: read(ini)).contains("BarColor=#Accent#\n"), "the look names the shared color again")
            t.check(section("Variables", in: read(ini)).contains("Accent=0,255,0,255\n"), "which changes everywhere")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // Picking a theme color from Bar 6's color menu writes its name.
            editor.select(section: "MeterBand5")
            guard let color = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "BarColor.row" }) as? ColorControl,
                  let menu = color.colorMenu,
                  let item = menu.items.first(where: { $0.title == "Empty part of bars" }) as? ClosureMenuItem else {
                return t.check(false, "Bar 6's color menu")
            }
            t.check(menu.items.contains { $0.title == "THEME COLORS" } && menu.items.contains { $0.title == "Custom Color…" })
            t.check(menu.items.contains { $0.title.hasPrefix("Change ‘Bar color’ Everywhere (18 bars)") })
            _ = item.target?.perform(item.action)
            t.check(section("MeterBand5", in: read(ini)).contains("BarColor=#Track#\n"), "#Track# written for Bar 6")
            settle()
        }
    }

    // MARK: The color panel (§7.4: live, one undo step per session)

    static func colorPanelTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: the color panel, one undo step for a session") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let ini = editor.skin?.fileURL else { return }
            editor.canvasSelectionChanged([])
            let original = read(ini)
            // A literal color picked twice while the panel stays open: the second pick lands too.
            guard let panel = colorRow(editor, where: { $0.variables.isEmpty && $0.role == "Background panel" })?.group else {
                return t.check(false, "Background panel row")
            }
            editor.editColorRow(panel)
            editor.previewColorEdit(RGBA(r: 1, g: 2, b: 3, a: 235))
            editor.commitColorEdit()
            t.check(read(ini).contains("Fill Color 1,2,3,235 |"), "the first pick")
            settle()
            editor.previewColorEdit(RGBA(r: 200, g: 100, b: 50, a: 235))
            t.equal(editor.skin?.meter(named: "MeterBackground")?.rawOption("Shape")?.contains("Fill Color 200,100,50,235"), true,
                    "the second pick is previewed")
            editor.commitColorEdit()
            t.check(read(ini).contains("Fill Color 200,100,50,235 |"), "the second pick is written: \(section("MeterBackground", in: read(ini)))")
            t.check(!read(ini).contains("1,2,3,235"), "in place of the first")
            settle()
            editor.previewColorEdit(RGBA(r: 9, g: 9, b: 9, a: 235))
            editor.finishColorEdit()
            t.check(read(ini).contains("Fill Color 9,9,9,235 |"), "closing the panel writes the last pick")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Background Panel Color")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(read(ini), original, "one undo step for the whole session")
            settle()
            editor.window?.undoManager?.redo()
            t.check(read(ini).contains("Fill Color 9,9,9,235 |"), "and one redo")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // A pick still waiting for its pause is written before ⌘Z, so ⌘Z takes it back.
            guard let track = colorRow(editor, where: { $0.variables == ["Track"] })?.group else { return t.check(false, "Track") }
            editor.editColorRow(track)
            editor.previewColorEdit(RGBA(r: 0, g: 0, b: 255, a: 28))
            t.check(editor.hasPendingVisualEdits)
            editor.window?.undoManager?.undo()
            t.equal(read(ini), original, "the pending pick was written and undone")
            t.check(editor.inspectorState.colorEditValue == nil)
            settle()
            // After an undo, a new pick is a step of its own (the undone one stays undone).
            editor.previewColorEdit(RGBA(r: 0, g: 255, b: 0, a: 28))
            editor.finishColorEdit()
            t.check(section("Variables", in: read(ini)).contains("Track=0,255,0,28\n"))
            settle()
            editor.window?.undoManager?.undo()
            t.equal(read(ini), original)
            settle()
        }
    }

    // MARK: On your desktop (§8.1.3)

    static func desktopTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: on your desktop") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let ini = editor.skin?.fileURL, let c = editor.controller else { return }
            editor.canvasSelectionChanged([])
            let bytes = read(ini)
            t.equal(c.state.alwaysOnTop, -2, "on the desktop")
            t.check(editor.isWidgetRunning)
            guard let stacking = find(editor, "stacking") as? NSSegmentedControl else { return t.check(false, "stacking segments") }
            t.equal((0..<stacking.segmentCount).compactMap { stacking.label(forSegment: $0) }, ["On Desktop", "Normal", "Always on Top"])
            stacking.selectedSegment = 2
            stacking.sendAction(stacking.action, to: stacking.target)
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.alwaysOnTop, 1, "always on top")
            t.equal(read(ini), bytes, "no file changes")
            t.equal(editor.window?.undoManager?.undoActionName, "Always on Top")
            t.equal(editor.toastText, "Always on top")
            t.equal((find(editor, "stacking-caption") as? NSTextField)?.stringValue, "Stays in front of every window.")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.alwaysOnTop, -2, "⌘Z puts it back")
            t.equal(editor.toastText, "Undid Always on Top", "named as the step is")
            t.equal(editor.toastActions.map(\.title), ["Redo"])
            settle()
            editor.window?.undoManager?.redo()
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.alwaysOnTop, 1, "and redo")
            settle()

            // Lock position.
            (find(editor, "lock-position") as? NSButton).map { box in
                box.state = .on
                box.sendAction(box.action, to: box.target)
            }
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.draggable, false)
            t.equal(editor.window?.undoManager?.undoActionName, "Lock Position")
            t.equal(editor.toastText, "Position locked")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.draggable, true)
            settle()

            // An in-between level keeps its value in a pop-up of the five.
            app.changeSettings(of: c) { $0.alwaysOnTop = -1 }
            editor.rebuildInspector()
            guard let popup = find(editor, "stacking") as? NSPopUpButton else { return t.check(false, "the five-level pop-up") }
            t.equal(popup.numberOfItems, 5)
            t.equal(popup.titleOfSelectedItem, "Behind windows")
            t.equal(read(ini), bytes, "still no file changes")
            // A change made elsewhere (the menu bar icon) shows here within a live tick; the position does not count.
            let rebuilds = editor.inspectorRebuildCount
            app.changeSettings(of: c) { $0.x = 300 }
            editor.inspectorState.liveUpdates.forEach { $0() }
            t.equal(editor.inspectorRebuildCount, rebuilds, "moving the widget does not rebuild the page")
            app.changeSettings(of: c) { $0.clickThrough = true }
            editor.inspectorState.liveUpdates.forEach { $0() }
            t.equal((find(editor, "click-through") as? NSButton)?.state, .on, "clicks pass through, as set elsewhere")
            app.changeSettings(of: c) { $0.clickThrough = false }

            // Opacity: a drag is one undo step, from where it started.
            app.changeSettings(of: c) { $0.alwaysOnTop = -2 }
            editor.rebuildInspector()
            guard let opacity = find(editor, "desktop-opacity") as? PercentControl else { return t.check(false, "opacity") }
            opacity.onChange?("200", false)
            opacity.onChange?("150", false)
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.alphaValue, 150, "live while dragging")
            opacity.onChange?("128", true)
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.alphaValue, 128)
            t.equal(editor.window?.undoManager?.undoActionName, "Change Opacity")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(app.controller(for: "Audio\\Visualizer")?.state.alphaValue, 255, "one step back to before the drag")
            settle()

            // More Desktop Options: what is not the default is counted and shown (a widget that hides when pointed at).
            t.check(find(editor, "on-hover") == nil, "closed while everything is as usual")
            app.changeSettings(of: c) { $0.onHover = 1 }
            editor.rebuildInspector()
            t.equal(text(editor, "disclosure-summary:widget/desktop-more"), "snapping, keep on screen, fade, when pointed at · 1 in use")
            t.equal((find(editor, "on-hover") as? NSPopUpButton)?.titleOfSelectedItem, "Hide", "open by itself")
            app.changeSettings(of: c) { $0.onHover = 0; $0.snapEdges = false; $0.fadeDuration = 500 }
            editor.rebuildInspector()
            t.check(text(editor, "disclosure-summary:widget/desktop-more")?.hasSuffix("· 2 in use") == true)
            app.changeSettings(of: c) { $0.snapEdges = true; $0.fadeDuration = 250 }
            editor.rebuildInspector()

            // When someone else installs it: this Mac's settings copied.
            (find(editor, "disclosure:widget/more") as? NSButton)?.performClick(nil)
            (find(editor, "copy-current-settings") as? NSButton)?.performClick(nil)
            t.check(section("Rainmeter", in: read(ini)).contains("DefaultAlwaysOnTop=-2\n"), "copied")
            t.equal(editor.window?.undoManager?.undoActionName, "Copy My Current Settings")
            t.check(find(editor, "widget-DefaultSnapEdges") != nil && find(editor, "widget-DefaultKeepOnScreen") != nil,
                    "what it wrote shows")
            settle()

            // Not on the desktop: said so, the controls off, and one click shows it again.
            app.suspend(config: "Audio\\Visualizer")
            editor.rebuildInspector()
            t.check(!editor.isWidgetRunning)
            t.equal(text(editor, "desktop-not-running"), "This widget isn't on your desktop right now.")
            t.equal((find(editor, "stacking") as? NSControl)?.isEnabled, false)
            t.equal((find(editor, "lock-position") as? NSButton)?.isEnabled, false)
            (find(editor, "show-on-desktop") as? NSButton)?.performClick(nil)
            t.check(app.controller(for: "Audio\\Visualizer") != nil, "running again")
        }
    }

    // MARK: More Widget Options (§8.1.5)

    static func widgetOptionsTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: more widget options") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let ini = editor.skin?.fileURL else { return }
            editor.canvasSelectionChanged([])
            openEverything(editor)
            let original = read(ini)

            // When the widget…: no choice that reloads it when it opens, updates or closes (it would reload forever).
            for key in ["OnRefreshAction", "OnUpdateAction", "OnCloseAction", "OnFocusAction", "OnUnfocusAction"] {
                let popup = find(editor, "when-\(key)") as? NSPopUpButton
                t.check(popup != nil, key)
                t.check(popup?.itemArray.contains { ($0.representedObject as? String)?.contains("Refresh") == true } == false,
                        "\(key) offers no reload")
                t.check(popup?.itemArray.contains { $0.title == "Edit in Code…" } == true, key)
            }
            t.check(WidgetPresets.whenTheWidgetChoices("OnRefreshAction").isEmpty && WidgetPresets.whenTheWidgetChoices("OnUpdateAction").isEmpty)
            let wake = find(editor, "when-OnWakeAction") as? NSPopUpButton
            t.check(choose(wake, "Reload the widget"))
            t.check(section("Rainmeter", in: read(ini)).contains("OnWakeAction=[!Refresh]\n"))
            t.equal(editor.toastText, "When it wakes from sleep: reload the widget")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            openEverything(editor)
            t.check(choose(find(editor, "when-OnRefreshAction") as? NSPopUpButton, "Edit in Code…"))
            t.equal(read(ini), original, "Edit in Code writes nothing")

            // Redraw layers: Custom… asks for a number of updates.
            t.check(choose(find(editor, "redraw-layers") as? NSPopUpButton, "Custom…"))
            guard let every = find(editor, "redraw-every") as? NumberField else { return t.check(false, "every N updates") }
            every.type("3")
            t.check(section("Rainmeter", in: read(ini)).contains("DefaultUpdateDivider=3\n"))
            t.equal((find(editor, "redraw-layers") as? NSPopUpButton)?.titleOfSelectedItem, "Every 3rd update")
            settle()
            editor.window?.undoManager?.undo()
            settle()
            openEverything(editor)

            // Right-click menu: an item is edited here (its name, what it does), added, removed.
            (find(editor, "edit-menu-item:1") as? NSButton)?.performClick(nil)
            t.check(find(editor, "edit-menu-item:2") == nil, "a name built from shared values is edited in the code")
            guard let name = find(editor, "menu-item-name:1") as? ValueField else { return t.check(false, "the name field") }
            t.equal(name.stringValue, "Open Activity Monitor")
            name.type("Activity")
            t.check(section("Rainmeter", in: read(ini)).contains("ContextTitle=Activity\n"))
            settle()
            t.check(choose(find(editor, "menu-item-action:1") as? NSPopUpButton, "website"))
            (find(editor, "menu-item-address:1") as? ValueField)?.type("example.com")
            t.check(section("Rainmeter", in: read(ini)).contains("ContextAction=[\"https://example.com\"]\n"),
                    section("Rainmeter", in: read(ini)))
            t.equal(text(editor, "menu-item:1"), "“Activity” → Opens example.com")
            settle()
            (find(editor, "add-menu-item") as? NSButton)?.performClick(nil)
            t.check(section("Rainmeter", in: read(ini)).contains("ContextTitle3=New item\nContextAction3=[!Refresh]\n"))
            t.check(find(editor, "menu-item-name:3") != nil, "the new item opens for its name")
            settle()
            (find(editor, "remove-menu-item:1") as? NSButton)?.performClick(nil)
            let rainmeter = section("Rainmeter", in: read(ini))
            t.check(rainmeter.contains("ContextTitle=#ThemeMenuTitle#\n") && rainmeter.contains("ContextTitle2=New item\n")
                    && !rainmeter.contains("ContextTitle3"), "the items after it move up: \(rainmeter)")
            t.equal(editor.window?.undoManager?.undoActionName, "Remove Menu Item")
            settle()
            for _ in 0..<4 {
                editor.window?.undoManager?.undo()
                settle()
            }
            t.equal(read(ini), original, "each an undo step")

            // Other shared values: examples, not codes.
            guard let (_, calendar) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Calendar", from: "DefaultSkins"),
                  let calendarIni = calendar.skin?.fileURL else { return }
            calendar.canvasSelectionChanged([])
            openEverything(calendar)
            let week = find(calendar, "shared-value:WeekStart") as? NSPopUpButton
            t.equal(week?.titleOfSelectedItem, "Sunday", "not “0”")
            t.check(choose(week, "Monday"))
            t.check(section("Variables", in: read(calendarIni)).contains("WeekStart=1\n"), "written for this widget")
            t.equal(calendar.toastText, "Week start changed")
            settle()
            openEverything(calendar)
            let format = find(calendar, "shared-value:MonthFormat") as? NSPopUpButton
            t.check(format?.titleOfSelectedItem?.contains("2026") == true, "an example date: \(format?.titleOfSelectedItem ?? "")")
            t.check(!(format?.itemArray.contains { $0.title.contains("%") } ?? true), "no codes in the choices")
            guard let (_, clock) = try FriendlyFixtures.openEditor(t, config: "Deskset\\Clock", from: "DefaultSkins") else { return }
            clock.canvasSelectionChanged([])
            openEverything(clock)
            t.equal((find(clock, "shared-value:ClockHours") as? NSPopUpButton)?.titleOfSelectedItem, "24-hour (14:05)")

            // Settings for new installs that the page has no row for are shown once set (and counted).
            guard let (_, vis) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"), let visIni = vis.skin?.fileURL else { return }
            try read(visIni).replacingOccurrences(of: "[Rainmeter]\n", with: "[Rainmeter]\nDefaultStartHidden=1\n")
                .write(to: visIni, atomically: true, encoding: .utf8)
            vis.refreshClicked()
            vis.canvasSelectionChanged([])
            t.equal(text(vis, "disclosure-summary:widget/more"), "timing, right-click menu, actions, looks · 1 in use")
            t.equal((find(vis, "widget-DefaultStartHidden") as? NSButton)?.state, .on, "shown where it is counted")
        }
    }

    // MARK: Colors from a file other widgets share (§8.1.1)

    static func sharedFileTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: a theme shared by several widgets") {
            guard let (app, editor) = try FriendlyFixtures.openEditor(t, config: "Deskset\\System", from: "DefaultSkins"),
                  let skin = editor.skin else { return }
            let ini = skin.fileURL
            let dark = skin.resourcesDirectory.appendingPathComponent("Themes/Dark.inc")
            let darkBytes = read(dark)
            guard let network = app.activate(config: "Deskset\\Network", file: nil) else { return t.check(false, "Network loads") }
            let blue = RGBA(r: 64, g: 156, b: 255)
            t.equal(network.skin.variable("DownColor").flatMap(OptionValue.color), blue)
            editor.canvasSelectionChanged([])
            t.equal(text(editor, "shared-colors-note"), "These colors and fonts come from the Deskset theme, shared by 6 widgets.")
            // Plain words here too, More Widget Options (open by itself) included: the menu items are sentences.
            for w in visibleWords(editor) {
                t.check(!w.contains("#") && !w.contains("Refresh"), "“\(w)”")
                t.check(w.range(of: "\\b(skin|meter|measure|section|variable)\\b", options: [.regularExpression, .caseInsensitive]) == nil,
                        "“\(w)”")
            }
            t.equal((find(editor, "menu-item:1") as? NSTextField)?.stringValue, "“Open Activity Monitor” → Opens “Activity Monitor”")
            t.equal((find(editor, "menu-item:2") as? NSTextField)?.stringValue, "“Use Light Theme” → Runs 2 commands")
            t.equal(text(editor, "disclosure-summary:widget/more"), "timing, right-click menu, actions, looks · 3 in use",
                    "group names and two menu items")
            t.check((find(editor, "disclosure-summary:widget/more") as? NSTextField)?.stringValue.contains("3\u{00A0}in\u{00A0}use") == true,
                    "“· 3 in use” never breaks")
            guard let apply = find(editor, "apply-to") as? NSSegmentedControl else { return t.check(false, "Apply to") }
            t.equal(apply.selectedSegment, 0, "This Widget by default")
            t.equal(apply.label(forSegment: 1), "All 6 Widgets")
            t.equal(text(editor, "apply-to-caption"), "Only System changes. Also used when you switch to the Light look.")
            t.check(find(editor, "disclosure:widget/more") != nil && find(editor, "redraw-layers") != nil,
                    "More Widget Options opens by itself: things in it are in use")
            t.check(text(editor, "disclosure-summary:widget/more")?.contains("in use") == true)
            t.check(find(editor, "disclosure:widget/other-colors") != nil && find(editor, "color-row:1000") == nil,
                    "the colors only other widgets use, folded")

            // This Widget: System.ini gets CPUColor after its includes; Network keeps the theme's.
            guard let row = colorRow(editor, where: { $0.variables.contains("CPUColor") }), let group = row.group else {
                return t.check(false, "the CPU graph line row")
            }
            t.check(group.role.hasPrefix("CPU graph line"), group.role)
            // Merged with a same-value color only other widgets use: counted, not named by its variable.
            if let id = row.identifier?.rawValue.replacingOccurrences(of: "color-row:", with: "") {
                let caption = text(editor, "color-caption:\(id)") ?? ""
                t.check(caption.hasPrefix("Changes 3 shared colors — CPU graph line") && caption.hasSuffix(", and 1 that other widgets use")
                        && !caption.contains("Down color"), caption)
            }
            // Show Separately, then Show Together (every color shown).
            editor.inspectorState.disclosures.insert("widget/colors-more")
            guard let separately = editor.colorRowMenu(group).items.first(where: { $0.title == "Show Separately" }) as? ClosureMenuItem
            else { return t.check(false, "Show Separately") }
            _ = separately.target?.perform(separately.action)
            guard let cpu = colorRow(editor, where: { $0.variables == ["CPUColor"] })?.group else { return t.check(false, "CPU apart") }
            t.check(colorRow(editor, where: { $0.variables == ["AccentColor"] }) != nil, "each its own row")
            guard let together = editor.colorRowMenu(cpu).items.first(where: { $0.title == "Show Together" }) as? ClosureMenuItem
            else { return t.check(false, "Show Together") }
            _ = together.target?.perform(together.action)
            t.check(colorRow(editor, where: { Set($0.variables) == ["CPUColor", "DownColor", "AccentColor"] }) != nil, "one row again")
            editor.editColorRow(group)
            editor.previewColorEdit(RGBA(r: 255, g: 0, b: 0))
            editor.commitColorEdit()
            let variables = section("Variables", in: read(ini))
            t.check(variables.contains("@Include2=#@#Styles.inc\n"), variables)
            if let include = variables.range(of: "@Include2"), let written = variables.range(of: "CPUColor=255,0,0,255") {
                t.check(include.upperBound < written.lowerBound, "after the includes")
            } else {
                t.check(false, "CPUColor written: \(variables)")
            }
            t.equal(read(dark), darkBytes, "Dark.inc unchanged")
            t.equal(editor.skin?.variable("CPUColor").flatMap(OptionValue.color), RGBA(r: 255, g: 0, b: 0), "System sees the new one")
            app.refresh(network)
            t.equal(app.controller(for: "Deskset\\Network")?.skin.variable("DownColor").flatMap(OptionValue.color), blue,
                    "Network keeps the theme's")
            settle()
            editor.window?.undoManager?.undo()
            settle()

            // A key written before the includes is moved after them (inside one file the first one wins).
            let edited = read(ini).replacingOccurrences(of: "[Variables]\n@Include=", with: "[Variables]\nCPUColor=1,1,1,255\n@Include=")
            try edited.write(to: ini, atomically: true, encoding: .utf8)
            editor.refreshClicked()
            editor.canvasSelectionChanged([])
            guard let again = colorRow(editor, where: { $0.variables.contains("CPUColor") })?.group else {
                return t.check(false, "the row again")
            }
            editor.editColorRow(again)
            editor.previewColorEdit(RGBA(r: 0, g: 255, b: 0))
            editor.commitColorEdit()
            let moved = section("Variables", in: read(ini))
            t.check(!moved.contains("CPUColor=1,1,1,255"), "the old one is gone: \(moved)")
            if let include = moved.range(of: "@Include2"), let written = moved.range(of: "CPUColor=0,255,0,255") {
                t.check(include.upperBound < written.lowerBound, "moved after the includes")
            } else {
                t.check(false, "CPUColor written: \(moved)")
            }
            t.equal(editor.skin?.variable("CPUColor").flatMap(OptionValue.color), RGBA(r: 0, g: 255, b: 0), "and it wins")
            settle()

            // All 6 Widgets: the theme file itself, nothing in System.ini.
            let before = read(ini)
            apply.selectedSegment = 1
            apply.sendAction(apply.action, to: apply.target)
            t.check(editor.appliesToAllWidgets)
            t.equal(text(editor, "apply-to-caption"), "Changes every Deskset widget; theme colors in the Dark look only.",
                    "the fonts and sizes come from Variables.inc, which every look reads")
            guard let memory = colorRow(editor, where: { $0.variables.contains("MemoryColor") })?.group
                    ?? { () -> ValueUsageIndex.ColorGroup? in
                        (find(editor, "disclosure:widget/colors-more") as? NSButton)?.performClick(nil)
                        return colorRow(editor, where: { $0.variables.contains("MemoryColor") })?.group
                    }() else { return t.check(false, "the memory color row") }
            editor.editColorRow(memory)
            editor.previewColorEdit(RGBA(r: 1, g: 2, b: 3))
            editor.commitColorEdit()
            t.check(read(dark).contains("MemoryColor=1,2,3,255\n"), "written in Dark.inc")
            t.equal(read(ini), before, "System.ini unchanged")
            t.check(editor.toastText.hasSuffix(" changed in all 6 Deskset widgets"), "the toast says how far: \(editor.toastText)")
            t.check(editor.window?.undoManager?.undoActionName.hasSuffix(" in All 6 Widgets") == true,
                    editor.window?.undoManager?.undoActionName ?? "")
            t.equal(text(editor, "size-reach:PanelWidth"), "Changes all 6 Deskset widgets.", "a shared size says so too")
            settle()
            editor.window?.undoManager?.undo()
            t.equal(read(dark), darkBytes)
            editor.appliesToAllWidgets = false
            settle()

            // Colors only other widgets use: changed for all of them, whatever Apply to says (this widget doesn't use them).
            let unchanged = read(ini)
            editor.inspectorState.disclosures.formUnion(["widget/more", "widget/other-colors"])
            editor.rebuildInspector()
            t.check(text(editor, "other-colors-note")?.hasSuffix("changes it in all 6 Deskset widgets.") == true)
            guard let battery = colorRow(editor, where: { $0.variables == ["BatteryColor"] })?.group else {
                return t.check(false, "the battery color row")
            }
            t.check(editor.inspectorStack.subviewsMatching { ($0.identifier?.rawValue ?? "").hasPrefix("color-row:100") }.count >= 10)
            t.check(editor.inspectorStack.subviewsMatching { ($0.identifier?.rawValue ?? "").hasPrefix("color-count:100") }.isEmpty,
                    "no count of nothing: the note says who uses them")
            guard let custom = editor.colorRowMenu(battery, otherWidgets: true).items.first(where: { $0.title == "Custom Color…" })
                    as? ClosureMenuItem else { return t.check(false, "Custom Color…") }
            _ = custom.target?.perform(custom.action)
            editor.previewColorEdit(RGBA(r: 7, g: 7, b: 7))
            editor.finishColorEdit()
            t.check(read(dark).contains("BatteryColor=7,7,7,255\n"), "written where it is defined")
            t.equal(read(ini), unchanged, "not as an override nobody here sees")
            t.check(editor.toastText.hasSuffix("changed in all 6 Deskset widgets"), editor.toastText)
            settle()
            editor.window?.undoManager?.undo()
            t.equal(read(dark), darkBytes)
        }
    }

    // MARK: A suite whose shared files are not themes

    static func suiteTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: shared files that are not a theme") {
            let widget = { (name: String) in """
                [Rainmeter]
                Update=1000
                [Metadata]
                Name=\(name)
                [Variables]
                @Include=#@#Variables.inc
                @Include2=#@#Styles.inc
                [MeterBack]
                Meter=Image
                SolidColor=#Panel#
                W=100
                H=40
                [MeterText]
                Meter=String
                MeterStyle=StyleText
                Text=Hello
                X=#Gap#
                """ }
            guard let (_, editor) = try openScratch(t, files: [
                "Suite/@Resources/Variables.inc": "[Variables]\nAccent=255,128,0,255\nPanel=20,20,20,255\nGap=4\n",
                "Suite/@Resources/Styles.inc": "[StyleText]\nFontColor=#Accent#\nFontSize=12\n",
                "Suite/A/A.ini": widget("A"),
                "Suite/B/B.ini": widget("B"),
            ], config: "Suite\\A"), let skin = editor.skin else { return }
            editor.canvasSelectionChanged([])
            let variables = skin.resourcesDirectory.appendingPathComponent("Variables.inc")
            t.equal(text(editor, "shared-colors-note"), "These colors are shared by 2 Suite widgets.")
            t.equal(text(editor, "apply-to-caption"), "Only A changes.", "Styles.inc next to Variables.inc is not a look")
            t.check(editor.inspectorStack.findSubview { ($0 as? NSTextField)?.stringValue.contains("Only A changes — see Apply to") == true }
                    != nil, "SIZE AND SPACING says whom its sizes change")
            guard let apply = find(editor, "apply-to") as? NSSegmentedControl else { return t.check(false, "Apply to") }
            t.equal(apply.label(forSegment: 1), "All 2 Widgets")
            apply.selectedSegment = 1
            apply.sendAction(apply.action, to: apply.target)
            t.equal(text(editor, "apply-to-caption"), "Changes every Suite widget.")
            t.equal(text(editor, "size-reach:Gap"), "Changes all 2 Suite widgets.")
            guard let accent = colorRow(editor, where: { $0.variables == ["Accent"] })?.group else { return t.check(false, "Accent") }
            editor.editColorRow(accent)
            editor.previewColorEdit(RGBA(r: 1, g: 2, b: 3))
            editor.finishColorEdit()
            t.check(read(variables).contains("Accent=1,2,3,255\n"))
            t.check(editor.toastText.hasSuffix(" changed in all 2 Suite widgets"), editor.toastText)
            t.check(editor.window?.undoManager?.undoActionName.hasSuffix(" in All 2 Widgets") == true)
            settle()
            (find(editor, "size:Gap") as? NumberControl)?.field.type("6")
            settle()
            t.check(read(variables).contains("Gap=6\n"))
            t.equal(editor.toastText, "Gap changed in all 2 Suite widgets")
            editor.appliesToAllWidgets = false

            // A count that could be larger (a name built while the widget runs) says "at least".
            guard let (_, dynamic) = try openScratch(t, files: ["Dyn/Dyn.ini": """
                [Rainmeter]
                [Variables]
                Color1=255,0,0,255
                Color2=0,255,0,255
                Index=1
                [MeterA]
                Meter=String
                Text=A
                FontColor=[#Color[#Index]]
                DynamicVariables=1
                [MeterB]
                Meter=String
                Text=B
                FontColor=#Color1#
                """], config: "Dyn") else { return }
            dynamic.canvasSelectionChanged([])
            guard let row = colorRow(dynamic, where: { $0.variables == ["Color1"] }),
                  let id = row.identifier?.rawValue.replacingOccurrences(of: "color-row:", with: "") else {
                return t.check(false, "the Color1 row")
            }
            t.check((find(dynamic, "color-count:\(id)") as? NSButton)?.title.hasPrefix("at least ") == true,
                    (find(dynamic, "color-count:\(id)") as? NSButton)?.title ?? "")
        }
    }

    // MARK: The color control and linked values (§7.3–7.4)

    static func controlTests(_ t: AppTestRunner) {
        t.suite("App: friendly widget page: color control and linked values") {
            guard let (_, editor) = try FriendlyFixtures.openEditor(t, config: "Audio\\Visualizer"),
                  let ini = editor.skin?.fileURL else { return }
            // Bar 6's fill: named after the shared color, drawn on the panel color, with its opacity.
            editor.select(section: "MeterBand5")
            guard let empty = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "SolidColor.row" }) as? ColorControl
            else { return t.check(false, "the empty part's color") }
            t.equal(empty.nameButton.title, "Empty part of bars")
            // "11%" beside the name, or "11% opacity" under it when both don't fit beside the swatch.
            t.check(["11%", "11% opacity"].contains(empty.opacityLabel.stringValue), empty.opacityLabel.stringValue)
            t.check(empty.swatch.backdrop != nil, "on the panel color")
            t.check(empty.swatch.toolTip?.hasPrefix("#FFFFFF · 11% opacity") == true, empty.swatch.toolTip ?? "")

            // Linked positions: what they follow, in words.
            guard let skin = editor.skin, let band = skin.meter(named: "MeterBand5"), let high = skin.meter(named: "MeterHighFreq"),
                  let peak = skin.meter(named: "MeterPeak"), let title = skin.meter(named: "MeterTitle") else {
                return t.check(false, "layers")
            }
            let after = LinkedValueTag(geometry: band, key: "X", raw: "#BarGap#R", variable: nil, current: band.frame.x,
                                       controller: editor)
            t.equal(after.pill.nameLabel.stringValue, "3 px after \(editor.displayName(ofSection: "MeterBand4"))")
            t.equal(after.field?.stringValue, "74")
            let top = LinkedValueTag(geometry: high, key: "Y", raw: "0r", variable: nil, current: high.frame.y, controller: editor)
            t.equal(top.pill.nameLabel.stringValue, "Same top as \(editor.displayName(ofSection: "MeterLowFreq"))")
            let moves = LinkedValueTag(geometry: peak, key: "X", raw: "[MeasurePeakX]", variable: nil, current: peak.frame.x,
                                       controller: editor)
            t.check(moves.pill.nameLabel.stringValue.hasPrefix("moves with peak"), moves.pill.nameLabel.stringValue)
            t.equal(moves.pill.menuProvider?().items.map(\.title).filter { !$0.isEmpty }.dropFirst().first, "Show the Live Data")
            let left = LinkedValueTag(geometry: title, key: "X", raw: "#Left#", variable: "Left", current: 14, controller: editor)
            t.equal(left.pill.nameLabel.stringValue, "Left")
            let menu = left.pill.menuProvider?().items.map(\.title) ?? []
            t.check(menu.first?.hasPrefix("Change ‘Left’ for All 10 Layers") == true, "the peak marker moves with it too: \(menu)")
            t.check(menu.contains { $0.hasPrefix("Use a Fixed Number Here") } && menu.contains("Highlight the 10 Layers"), "\(menu)")
            // Typing keeps the link: 20 over #Left# (14) is (#Left# + 6).
            left.field?.type("20")
            t.check(section("MeterTitle", in: read(ini)).contains("X=(#Left# + 6)\n"), section("MeterTitle", in: read(ini)))
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // ↑ in a calculated value keeps the calculation (the layer page's Position and Size card).
            editor.select(section: "MeterLowFreq")
            guard let field = editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "MeterLowFreq/Y" }) as? GeometryField
            else { return t.check(false, "Y") }
            t.equal((editor.inspectorStack.findSubview(where: { $0.identifier?.rawValue == "MeterLowFreq/Y/tag" }) as? NSPopUpButton)?.title,
                    "calculated")
            field.onStep?(-3)
            t.check(section("MeterLowFreq", in: read(ini)).contains("Y=(36 + #BarH# + 1)\n"), section("MeterLowFreq", in: read(ini)))
            settle()
            editor.window?.undoManager?.undo()
            settle()
            // "Change ‘Left’ for All 10 Layers…" edits the shared value itself.
            editor.select(section: "MeterTitle")
            let tag = LinkedValueTag(geometry: title, key: "X", raw: "#Left#", variable: "Left", current: 14, controller: editor)
            editor.inspectorStack.addArrangedSubview(tag)
            tag.beginVariableEdit("Left")
            t.equal(tag.field?.stringValue, "14")
            t.check(tag.findSubview { ($0 as? NSTextField)?.stringValue == "Changing Left for 10 layers." } != nil, "the caption")
            // ↑ steps the shared value too, not the layer's own X.
            let before = section("MeterTitle", in: read(ini))
            (tag.field as? LinkedNumberField)?.onStep?(1)
            t.check(section("Variables", in: read(ini)).contains("Left=15\n"), "↑ in this mode: the shared value")
            t.equal(section("MeterTitle", in: read(ini)), before, "the layer keeps X=#Left#")
            t.equal(editor.inspectorState.variableEdit, "MeterTitle/X/pill", "still changing Left")
            t.equal(editor.window?.undoManager?.undoActionName, "Change Left")
            settle()
            editor.inspectorState.variableEdit = nil
            tag.field?.type("16")
            t.check(section("Variables", in: read(ini)).contains("Left=16\n"), "the shared value")
            settle()
            // An option name longer than the label column breaks between its words (Rainmeter Details).
            t.equal(EditorStyle.wordBreakable("DefaultUpdateDivider"), "Default\u{200B}Update\u{200B}Divider")
            t.equal(EditorStyle.wordBreakable("CPUColor"), "CPU\u{200B}Color")
        }
    }
}
