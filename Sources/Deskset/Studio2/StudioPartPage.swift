import AppKit
import DesksetCore

/// The kind of a part, in the words its page uses: a number (a text that shows data), a text, a symbol, a picture, a
/// bar, a ring, a graph, a shape.
enum StudioPartKind: String, CaseIterable {
    case number, text, symbol, picture, bar, ring, graph, shape, part

    init(_ m: Meter) {
        switch m.type {
        case "string": self = m.measures.isEmpty ? .text : .number
        case "image":
            let name = (m.fileOption("ImageName") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            self = name.hasPrefix("sf:") ? .symbol : .picture
        case "button", "bitmap": self = .picture
        case "bar": self = .bar
        case "roundline", "rotator": self = .ring
        case "line", "histogram": self = .graph
        case "shape": self = .shape
        default: self = .part
        }
    }

    /// "number" / "numbers" (Chinese has one word for both).
    func noun(plural: Bool = false) -> String {
        let keys: [StudioPartKind: (StudioText.Key, StudioText.Key)] = [
            .number: (.kindNumber, .kindNumbers), .text: (.kindText, .kindTexts), .symbol: (.kindSymbol, .kindSymbols),
            .picture: (.kindPicture, .kindPictures), .bar: (.kindBar, .kindBars), .ring: (.kindRing, .kindRings),
            .graph: (.kindGraph, .kindGraphs), .shape: (.kindShape, .kindShapes), .part: (.kindPart, .kindParts),
        ]
        let pair = keys[self]!
        return StudioText[plural ? pair.1 : pair.0]
    }

    /// The option a change of the page is measured by (the scope sentence asks where it would be written).
    var mainKey: String {
        switch self {
        case .number, .text: return "FontSize"
        case .symbol, .picture: return "ImageTint"
        case .bar: return "BarColor"
        case .ring, .graph: return "LineColor"
        case .shape: return "Shape"
        case .part: return "X"
        }
    }

    /// Title case for links ("Numbers").
    static func titled(_ word: String) -> String {
        guard StudioText.language == .english else { return word }
        return word.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Where a confirmation of a change appears (the design's depth rules): at the Customize depth after every change,
/// under the control that made it; at the Build depth only when the change goes beyond the selection, widens the
/// scope, cannot be seen, or reverts something; a change made on the canvas (a drag) at the top of the inspector.
enum StudioConfirmRule {
    enum Change: Equatable {
        /// One value of what is selected.
        case value
        /// More than the selection (a style, a shared value, the suite's file).
        case beyondSelection
        /// Nothing to see on the canvas (hidden, removed, moved out of sight).
        case invisible
        /// Back to a default or an earlier state.
        case revert
    }

    enum Place: Equatable {
        case underControl
        case top
    }

    static func place(depth: StudioDepth, change: Change, fromCanvas: Bool) -> Place? {
        if depth == .build, change == .value { return nil }
        return fromCanvas ? .top : .underControl
    }
}

/// The inspector's page of what is selected on the canvas: a part's page (what it shows, its text or look, its
/// layout, what a click does), its Every Setting page (⌥⌘E, remembered per kind of part), or a data item's page. Every
/// change goes through the editing session as one named step, written where the scope sentence says
/// (`WriteScopes`); numbers preview while their label is dragged and make one step on release.
final class StudioPartPage {
    unowned let window: StudioWindowController

    enum Focus: Equatable {
        case part(String)
        case data(String)
    }

    private(set) var focus: Focus?
    private(set) var page: StudioPage?
    /// Every Setting is open on the part.
    private(set) var everySetting = false
    private(set) var filter = ""
    /// How far changes reach: an index into the part's scope choices (0: this part only).
    private(set) var scopeLevel = 0
    private(set) var scopeHovered = false
    private(set) var confirmation: StudioWidgetPage.Confirmation?
    private(set) var topConfirmation: StudioPage.Confirmation?
    private(set) var hoveredItem: String?
    var colorPopover: StudioColorPopover?
    var activeSwatch: String?
    /// The row whose label is being dragged (drawn with ↔).
    var scrubbingItem: String?
    /// A number being dragged: its item and what it started from.
    var drag: (item: String, part: Int, start: String)?
    /// The rows the page left out to keep twelve controls (they are in Every Setting).
    var movedOut: [String] = []
    /// What each row of the page shown writes.
    var rows: [String: StudioPartRow] = [:]
    /// The scope choices worked out for the Studio's instance of the widget.
    private var scopeCache: (skin: Skin?, choices: [String: [WriteScopeChoice]]) = (nil, [:])

    init(window: StudioWindowController) {
        self.window = window
    }

    var session: EditingSession? { window.session }
    var skin: Skin? { window.skin }
    var showsIniNames: Bool { window.app.state.editor.showIniNames }

    var meter: Meter? {
        guard case .part(let name)? = focus else { return nil }
        return skin?.meter(named: name)
    }

    var measure: Measure? {
        guard case .data(let name)? = focus else { return nil }
        return skin?.measure(named: name)
    }

    // MARK: Showing

    /// Shows the page of a part (nil: the widget page again).
    func show(part name: String?) {
        let new: Focus? = name.map { .part($0) }
        if new != focus {
            closePopover()
            confirmation = nil
            topConfirmation = nil
            scopeLevel = 0
            scopeHovered = false
            hoveredItem = nil
            filter = ""
            window.canvasController.overlay.clearReach()
            window.canvasController.overlay.showFrames(nil)
        }
        focus = new
        if let m = meter { everySetting = Self.remembers(StudioPartKind(m)) }
        refresh()
    }

    /// Shows a data item's page.
    func show(data name: String) {
        closePopover()
        confirmation = nil
        topConfirmation = nil
        everySetting = false
        filter = ""
        focus = .data(name)
        refresh()
    }

    /// Builds the page again from the Studio's instance and shows it; the widget page comes back when what was
    /// selected is gone.
    func refresh() {
        guard let skin, let focus else {
            page = nil
            return
        }
        switch focus {
        case .part(let name):
            guard let m = skin.meter(named: name) else { return leave() }
            page = everySetting ? buildEverySetting(m, skin: skin) : buildPart(m, skin: skin)
        case .data(let name):
            guard let measure = skin.measure(named: name) else { return leave() }
            page = buildData(measure, skin: skin)
        }
        if let page { window.inspectorController.show(page) }
    }

    /// Forgets the part without showing anything (the window shows the widget page itself).
    func reset() {
        focus = nil
        page = nil
        rows = [:]
        closePopover()
        window.canvasController.overlay.clearReach()
        window.canvasController.overlay.showFrames(nil)
    }

    /// Back to the widget page (the selection is cleared).
    func leave() {
        focus = nil
        page = nil
        closePopover()
        window.canvasController.overlay.clearReach()
        window.canvasController.overlay.showFrames(nil)
        if !window.canvasController.canvas.selectedNames.isEmpty {
            window.canvasController.canvas.setSelection(nil)
        }
        window.widgetPage.refresh()
    }

    // MARK: Every Setting, remembered per kind

    private static let everySettingKey = "StudioEverySettingKinds"
    /// Headless runs keep the choice in memory only.
    static var rememberedInMemory: Set<String> = []

    static func remembers(_ kind: StudioPartKind) -> Bool {
        if NSApp?.activationPolicy() == .prohibited { return rememberedInMemory.contains(kind.rawValue) }
        let list = UserDefaults.standard.stringArray(forKey: everySettingKey) ?? []
        return list.contains(kind.rawValue) || rememberedInMemory.contains(kind.rawValue)
    }

    static func remember(_ kind: StudioPartKind, open: Bool, persist: Bool) {
        if open { rememberedInMemory.insert(kind.rawValue) } else { rememberedInMemory.remove(kind.rawValue) }
        guard persist else { return }
        var list = Set(UserDefaults.standard.stringArray(forKey: everySettingKey) ?? [])
        if open { list.insert(kind.rawValue) } else { list.remove(kind.rawValue) }
        UserDefaults.standard.set(list.sorted(), forKey: everySettingKey)
    }

    /// ⌥⌘E: Every Setting on or off for the selected part (and, from then on, for parts of its kind).
    func toggleEverySetting() {
        guard let m = meter else { return }
        everySetting.toggle()
        filter = ""
        Self.remember(StudioPartKind(m), open: everySetting, persist: window.app.presentsWindows)
        refresh()
    }

    // MARK: Scope

    /// The scopes a change of the part can take, narrowest first.
    func scopeChoices(_ m: Meter, key: String? = nil) -> [WriteScopeChoice] {
        guard let skin else { return [] }
        let k = key ?? StudioPartKind(m).mainKey
        // Worked out once per instance of the widget (which widgets read a shared file walks the whole suite).
        if scopeCache.skin !== skin { scopeCache = (skin, [:]) }
        let id = "\(m.name.lowercased())|\(k.lowercased())"
        if let cached = scopeCache.choices[id] { return cached }
        let choices = WriteScopes.choices(meter: m.name, key: k, in: skin)
        scopeCache.choices[id] = choices
        return choices
    }

    /// The scope a change of `key` is written with, following the page's scope: the same style, variable or file when
    /// the key comes from it, else the part alone.
    func scope(for key: String, of m: Meter) -> WriteScopeChoice? {
        let page = scopeChoices(m)
        let current = page.indices.contains(scopeLevel) ? page[scopeLevel].scope : .element
        let choices = scopeChoices(m, key: key)
        if let same = choices.first(where: { $0.scope == current }) { return same }
        // The page reaches a style; this key's value is the style's variable, or its file: the part alone.
        return choices.first
    }

    // MARK: What is done on the page

    func handle(_ event: StudioPageEvent) {
        switch event {
        case .crumb(let i): crumb(i)
        case .scopeLink: scopeLink()
        case .scopeHover(let inside): hoverScope(inside)
        case .tokenData(let item): tokenData(item)
        case .example(let item, let index): example(item, index)
        case .choose(let item, let index): choose(item, index)
        case .segment(let item, let index): segment(item, index)
        case .toggle(let item, let on): toggle(item, on)
        case .number(let item, let part, let change): number(item, part: part, change)
        case .swatch(let item, _): openColor(item)
        case .hoverItem(let item, let inside): hover(item, inside: inside)
        case .filter(let text):
            filter = text
            refresh()
        case .link(let id): link(id)
        case .undo, .topUndo: session?.undoStack.undo()
        case .noteLink(let item):
            // A position worked out from other values: its line in the code.
            if item == "layout.calculated" || item == "shows.words" { window.showInCode(nil) }
        case .percent, .slider, .hoverSwatch, .thumbnail, .textSize, .suggestion: break
        }
    }

    private func crumb(_ i: Int) {
        if i == 0 { return leave() }
        // The second crumb names the data the part shows: its page.
        if let m = meter, let data = liveMeasure(m) { show(data: data.name) }
    }

    private func scopeLink() {
        guard let m = meter else { return }
        let choices = scopeChoices(m)
        guard choices.count > 1 else { return }
        scopeLevel = scopeLevel + 1 < choices.count ? scopeLevel + 1 : 0
        hoverScope(false)
        refresh()
        announce(page?.scope?.text ?? "")
    }

    private func hoverScope(_ inside: Bool) {
        scopeHovered = inside
        let overlay = window.canvasController.overlay
        defer { refresh() }
        guard inside, let m = meter else { return overlay.clearReach() }
        let choices = scopeChoices(m)
        let next = scopeLevel + 1 < choices.count ? choices[scopeLevel + 1] : nil
        guard let next else { return overlay.clearReach() }
        let others = next.visibleParts.filter { $0.caseInsensitiveCompare(m.name) != .orderedSame }
        overlay.showReach(others, sentence: reachSentence(next, of: m))
    }

    /// Under the widget while the pointer is on the widen link: "4 numbers share one style".
    func reachSentence(_ c: WriteScopeChoice, of m: Meter) -> String {
        switch c.scope {
        case .element: return ""
        case .style: return StudioText.format(.scopeShareStyle, c.visibleParts.count, noun(c, of: m, plural: true))
        case .sharedValue: return StudioText.format(.scopeShareValue, c.visibleParts.count)
        case .package: return StudioText.format(.scopeWidgets, c.widgets.count)
        }
    }

    /// The kind of parts a choice reaches: the part's own when they are all of it, else "parts".
    func noun(_ c: WriteScopeChoice, of m: Meter, plural: Bool) -> String {
        let kind = StudioPartKind(m)
        let same = c.parts.allSatisfy { name in skin?.meter(named: name).map { StudioPartKind($0) == kind } ?? true }
        return (same ? kind : .part).noun(plural: plural)
    }

    private func hover(_ item: String, inside: Bool) {
        hoveredItem = inside ? item : nil
        let overlay = window.canvasController.overlay
        guard inside, colorPopover == nil, let skin else { return overlay.showFrames(nil) }
        var names: [String] = []
        var tag = ""
        if item.hasPrefix("used:") {
            let name = String(item.dropFirst(5))
            names = [name]
            tag = skin.meter(named: name).map { partTitle($0, skin: skin) } ?? name
        } else if let m = meter {
            let key = colorKey(item, of: m) ?? StudioPartKind(m).mainKey
            let reach = scope(for: key, of: m)?.visibleParts ?? [m.name]
            names = reach.isEmpty ? [m.name] : reach
            tag = names.count > 1 ? StudioText.format(.paints, partTitle(m, skin: skin), StudioWords.parts(names.count))
                : partTitle(m, skin: skin)
        }
        overlay.showFrames(.init(names: names, tag: tag, ink: StudioCanvasOverlay.ink(for: skin)))
    }

    private func link(_ id: String) {
        switch id {
        case "every-setting": toggleEverySetting()
        case "show-in-code": window.showInCode(nil)
        default:
            if id.hasPrefix("used:") {
                let name = String(id.dropFirst(5))
                window.select(part: name)
            }
        }
    }

    /// A change of scope, said to VoiceOver ("Now changing: All 4 numbers").
    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        window.announce(StudioText.format(.announceScope, text))
    }

    // MARK: Writing

    /// Writes `value` to `key` of the part where its scope says (nil: the part's own value goes: the default or the
    /// style applies again), as one step named `name`, confirmed as the depth rules say.
    @discardableResult
    func write(_ key: String, _ value: String?, of m: Meter, name: String, confirm: String, item: String,
               section: String, change: StudioConfirmRule.Change = .value, fromCanvas: Bool = false,
               elementOnly: Bool = false) -> Bool {
        guard let skin else { return false }
        var ops: [EditOp] = []
        var wide = false
        if let value {
            let choice = elementOnly ? nil : scope(for: key, of: m)
            let scope = choice?.scope ?? .element
            ops = WriteScopes.ops(scope, meter: m.name, key: key, value: value, in: skin)
            wide = (choice?.parts.count ?? 1) > 1 || { if case .package = scope { return true }; return false }()
        } else if let op = skin.op(removingOwnOption: key, of: m.name) {
            ops = [op]
        }
        if ops.isEmpty, !WriteScopes.isLocal(meter: m.name, key: key, in: skin) {
            // Only a shared file defines the part: nothing changes for this widget alone (the scope sentence says so
            // and offers the file's scope).
            sharedPartRefused(m)
            return false
        }
        guard apply(name, ops) else { return false }
        let kind: StudioConfirmRule.Change = change == .value && wide ? .beyondSelection : change
        self.confirm(confirm, step: name, item: item, section: section, change: kind, fromCanvas: fromCanvas)
        return true
    }

    /// A change this widget can't make on its own (the part comes from a file other widgets share): said, not made.
    func sharedPartRefused(_ m: Meter) {
        if window.app.presentsWindows { NSSound.beep() }
        let text = scopeChoices(m).first(where: { if case .package = $0.scope { return true }; return false })
            .map { StudioText.format(.scopeSharedPart, StudioPartKind(m).noun(), $0.widgets.count) }
        window.announce(text ?? StudioText.format(.sharedPartsKept, skin.map { partTitle(m, skin: $0) } ?? m.name))
    }

    /// One step through the session.
    @discardableResult
    func apply(_ name: String, _ ops: [EditOp]) -> Bool {
        guard let session, !ops.isEmpty else { return false }
        do {
            return try session.apply(name, ops, selectionBefore: window.canvasController.canvas.selectedNames,
                                     selectionAfter: window.canvasController.canvas.selectedNames) != nil
        } catch {
            Log.write("Studio: \(name) was not made: \(error)", level: .warning, source: session.config)
            if window.app.presentsWindows { NSSound.beep() }
            return false
        }
    }

    /// Shows the confirmation of a step where the depth rules put it.
    func confirm(_ text: String, step: String, item: String, section: String, change: StudioConfirmRule.Change,
                 fromCanvas: Bool) {
        confirmation = nil
        topConfirmation = nil
        switch StudioConfirmRule.place(depth: window.depth, change: change, fromCanvas: fromCanvas) {
        case .underControl?:
            confirmation = .init(after: item, section: section,
                                 value: .init(text: text, undo: StudioText[.confirmUndo]), step: step)
        case .top?:
            topConfirmation = .init(text: text, undo: StudioText[.confirmUndo])
        case nil:
            break
        }
        refresh()
        window.updateToolbar()
    }

    /// A step was undone or redone: the confirmation of an undone step goes.
    func stepReverted() {
        confirmation = nil
        topConfirmation = nil
    }

    /// Previews a value of `key` for what the scope reaches (a drag in progress, a color being picked).
    func preview(_ key: String, _ value: String, of m: Meter, elementOnly: Bool = false) {
        guard let session else { return }
        let choice = elementOnly ? nil : scope(for: key, of: m)
        switch choice?.scope ?? .element {
        case .sharedValue(let v):
            session.previewVariables([v: value])
        case .package(_, let section, let packageKey) where section.caseInsensitiveCompare("Variables") == .orderedSame:
            session.previewVariables([packageKey: value])
        case .element:
            session.preview(section: m.name, [key: value])
        default:
            for part in choice?.parts ?? [m.name] { session.preview(section: part, [key: value]) }
        }
    }

    // MARK: Colors

    /// The option a color row writes.
    func colorKey(_ item: String, of m: Meter) -> String? {
        switch item {
        case "text.color": return "FontColor"
        case "look.fill": return m.type == "bar" ? "BarColor" : "LineColor"
        case "look.track": return "SolidColor"
        case "look.tint": return "ImageTint"
        case "shape.fill", "shape.stroke": return "Shape"
        default:
            if item.hasPrefix("every:") { return String(item.dropFirst(6)) }
            return nil
        }
    }

    /// The color a row shows, and how the file writes it.
    func color(_ key: String, of m: Meter) -> (color: RGBA, written: String)? {
        guard let skin else { return nil }
        let raw = (m.fileOption(key) ?? "").trimmingCharacters(in: .whitespaces)
        let resolved = m.option(key) ?? raw
        if let v = WriteScopes.soleVariable(raw), let value = skin.variable(v), let c = OptionValue.color(value) {
            return (c, value)
        }
        if let c = OptionValue.color(resolved) { return (c, raw.isEmpty ? resolved : raw) }
        switch m {
        case let s as StringMeter where key.caseInsensitiveCompare("FontColor") == .orderedSame:
            return (s.style.color, ColorText.format(s.style.color, like: "0,0,0"))
        case let i as ImageMeter where key.caseInsensitiveCompare("ImageTint") == .orderedSame:
            let c = i.imageTint ?? RGBA(r: 255, g: 255, b: 255)
            return (c, ColorText.format(c, like: "0,0,0"))
        default:
            return nil
        }
    }

    func openColor(_ item: String) {
        guard let m = meter, let skin else { return }
        if item.hasPrefix("shape.") { return openShapeColor(item, m) }
        guard let key = colorKey(item, of: m), let current = color(key, of: m) else { return }
        closePopover()
        window.canvasController.overlay.clearFramesNow()
        activeSwatch = item
        let reach = scope(for: key, of: m)?.visibleParts.count ?? 1
        let target = StudioColorPopover.Target(title: rowTitle(item, m), color: current.color, written: current.written,
                                               parts: max(reach, 1), acceptsAlpha: true,
                                               showsNotation: window.showsFileNotation)
        let popover = StudioColorPopover(target: target, widgetColors: StudioCanvasOverlay.colors(of: skin),
                                         presentsWindows: window.app.presentsWindows)
        popover.onPreview = { [weak self] c in
            guard let self, let m = self.meter else { return }
            self.preview(key, StudioColorWriting.text(c, like: current.written, acceptsAlpha: true), of: m)
        }
        popover.onClose = { [weak self] c, name in self?.commitColor(item, key: key, c, name: name, like: current) }
        popover.anchorItem = item
        _ = popover.view
        colorPopover = popover
        refresh()
        if window.app.presentsWindows, window.window?.isVisible == true,
           let anchor = window.inspectorController.pageView.swatchView(item: item, swatch: item) {
            popover.show(relativeTo: anchor.bounds, of: anchor)
        }
    }

    private func commitColor(_ item: String, key: String, _ color: RGBA?, name: String?,
                             like current: (color: RGBA, written: String)) {
        colorPopover = nil
        activeSwatch = nil
        session?.endPreview()
        guard let m = meter, let color,
              ValueUsageIndex.colorKey(color) != ValueUsageIndex.colorKey(current.color) else { return refresh() }
        let text = StudioColorWriting.text(color, like: current.written, acceptsAlpha: true)
        let words = name.map(StudioWords.color) ?? StudioWords.color(LayerNaming.colorName(color))
        let section = item.hasPrefix("every:") ? everySection(key) : String(item.prefix { $0 != "." })
        write(key, text, of: m, name: StudioText[.undoColor], confirm: StudioText.format(.confirmColor, rowTitle(item, m), words),
              item: item, section: section)
    }

    /// Closes the color popover now, its pick handed over in this turn (never after the page moved on).
    func closePopover() {
        colorPopover?.commitNow()
        colorPopover = nil
        activeSwatch = nil
    }

    /// The title a color's popover and confirmation use ("Text color", "Fill").
    func rowTitle(_ item: String, _ m: Meter) -> String {
        switch item {
        case "text.color": return StudioText[.textColor]
        case "look.fill", "shape.fill": return StudioText[.rowFill]
        case "look.track": return StudioText[.rowTrack]
        case "look.tint": return StudioText[.rowTint]
        case "shape.stroke": return StudioText[.rowStroke]
        default:
            if item.hasPrefix("every:"), let f = StudioCatalog.field(String(item.dropFirst(6))) {
                return f.label(chinese: StudioText.language == .chinese)
            }
            return StudioText[.rowColor]
        }
    }

    // MARK: Names

    /// The live data a part shows (through a formula or a text built from it, to the data it comes from).
    func liveMeasure(_ m: Meter) -> Measure? {
        guard let skin else { return nil }
        return StudioPartNames.liveMeasure(m, in: skin)
    }

    /// A part named by its data ("CPU usage", its bar "CPU bar"), a static text by its words, else by what it is
    /// (`StudioPartNames`).
    func partTitle(_ m: Meter, skin: Skin) -> String {
        StudioPartNames.title(m, in: skin)
    }

    /// What the part shows now ("21%").
    func nowValue(_ m: Meter) -> String? {
        switch m {
        case let s as StringMeter:
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        default:
            guard let data = m.measures.first, data.maxValue > data.minValue else { return nil }
            let p = (data.value - data.minValue) / (data.maxValue - data.minValue) * 100
            return "\(Int(p.rounded()))%"
        }
    }

    /// Every Setting's section of an option (for a confirmation under its row).
    func everySection(_ key: String) -> String {
        guard let f = StudioCatalog.field(key) else { return "every" }
        return "every." + StudioEverySetting.Section(f.section, key: f.key).rawValue
    }
}
