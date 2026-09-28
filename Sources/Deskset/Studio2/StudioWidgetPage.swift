import AppKit
import DesksetCore

/// The widget page — what the inspector shows while nothing is selected — generated from what the widget is
/// (`StudioWidgetFacts`) in the order of the tasks: the author's options, what the data parts show, the colors (the
/// parts', then Text and Card, then More…), the fonts with A− / A+, the look and the size, More Settings. It keeps to
/// twelve controls (plus Text · Card), moving what does not fit in the design's order, and carries out what is done on
/// it: every change goes through the editing session as one step with a name, and at the Customize depth a
/// confirmation with that name and Undo appears under the control that made it.
final class StudioWidgetPage {
    unowned let window: StudioWindowController
    private(set) var facts: StudioWidgetFacts?
    private(set) var page: StudioPage?
    /// The plan the page was built from (what fitted, what moved).
    private(set) var plan = Plan()
    /// The confirmation under the control that made the last change, and the step it names.
    private(set) var confirmation: Confirmation?
    /// The swatch the color popover is open on (drawn with its ring), and the one the pointer is on.
    private(set) var activeSwatch: String?
    private(set) var hoveredSwatch: String?
    /// The color popover, while it is open (off screen: made, not shown; the snapshot composes it).
    private(set) var colorPopover: StudioColorPopover?
    let thumbnails: StudioLookThumbnails

    struct Confirmation {
        /// The item it follows, and its section.
        var after: String
        var section: String
        var value: StudioPage.Confirmation
        /// The name of the step it confirms (it goes when that step is undone).
        var step: String
    }

    init(window: StudioWindowController) {
        self.window = window
        thumbnails = StudioLookThumbnails()
    }

    var session: EditingSession? { window.session }
    var skin: Skin? { window.skin }
    var app: AppController { window.app }
    /// The INI names beside rows (Show Rainmeter Details).
    var showsIniNames: Bool { app.state.editor.showIniNames }

    // MARK: Building

    /// Works the facts out again from the Studio's instance and shows the page.
    func rebuild() {
        guard let skin else {
            facts = nil
            page = nil
            return
        }
        let facts = LayerNaming.sharingWork(for: skin) { StudioWidgetFacts(skin: skin) }
        self.facts = facts
        refresh()
    }

    /// Shows the page again from the facts it has (a swatch opened, a confirmation came or went).
    func refresh() {
        guard let facts else { return }
        let page = build(facts)
        self.page = page
        window.inspectorController.show(page)
    }

    /// What goes on the page, after fitting it to twelve controls.
    struct Plan: Equatable {
        var options: [StudioWidgetFacts.Option] = []
        var hiddenOptions = 0
        var shows: [StudioWidgetFacts.ShowsRow] = []
        var hiddenShows = 0
        var parts: [StudioWidgetFacts.ColorRole] = []
        var fontsMerged = false
        var sizeInFonts = false
        var fonts = 0
        var look = false
        var size = false

        var count: Int {
            options.count + shows.count + parts.count + (fontsMerged ? min(fonts, 1) : fonts) + (look ? 1 : 0)
                + (size ? 1 : 0)
        }
    }

    /// The design's order of moving things off an overfull page: options beyond four go to All Options…, part colors
    /// beyond four to More…, the two fonts become one row, the size joins the fonts when there are no look
    /// thumbnails; still too many: Shows rows beyond two go to All Data…, then fewer part colors, then fewer options.
    static func plan(_ facts: StudioWidgetFacts, limit: Int = StudioPage.controlLimit) -> Plan {
        var p = Plan()
        p.options = facts.options
        p.shows = facts.shows
        p.parts = Array(facts.colors.parts.prefix(4))
        p.fonts = facts.fonts.count
        p.look = facts.look != nil
        p.size = true
        p.sizeInFonts = facts.look == nil
        if p.count > limit, p.options.count > 4 {
            p.hiddenOptions = p.options.count - 4
            p.options = Array(p.options.prefix(4))
        }
        if p.count > limit, p.fonts > 1 { p.fontsMerged = true }
        while p.count > limit, p.shows.count > 2 {
            p.shows.removeLast()
            p.hiddenShows += 1
        }
        while p.count > limit, p.parts.count > 1 { p.parts.removeLast() }
        while p.count > limit, p.options.count > 1 {
            p.options.removeLast()
            p.hiddenOptions += 1
        }
        return p
    }

    func build(_ facts: StudioWidgetFacts) -> StudioPage {
        plan = Self.plan(facts)
        var page = StudioPage(id: "widget", title: facts.name, subtitle: facts.information)
        if let s = optionsSection(facts) { page.sections.append(s) }
        if let s = showsSection(facts) { page.sections.append(s) }
        page.sections.append(colorsSection(facts))
        if let s = fontsSection(facts) { page.sections.append(s) }
        if let s = lookSection(facts) { page.sections.append(s) }
        page.footer = [StudioPage.Link(id: "more-settings", title: StudioText[.moreSettings],
                                       detail: StudioText[.moreSettingsDetail])]
        // A confirmation goes right under the control that made the change.
        if let c = confirmation, let si = page.sections.firstIndex(where: { $0.id == c.section }) {
            let items = page.sections[si].items
            let at = (items.firstIndex { $0.id == c.after }).map { $0 + 1 } ?? items.count
            page.sections[si].items.insert(StudioPage.Item(id: "\(c.section).confirm", kind: .confirmation(c.value)), at: at)
            page.tight = true
        }
        return page
    }

    // MARK: Options

    func optionsSection(_ facts: StudioWidgetFacts) -> StudioPage.Section? {
        guard !plan.options.isEmpty else { return nil }
        var items = plan.options.map { StudioPage.Item(id: "option:\(Self.key($0))", kind: .row(optionRow($0))) }
        if plan.hiddenOptions > 0 {
            items.append(.init(id: "options.all", kind: .link(.init(id: "options.all", title: StudioText.format(
                .allOptions, facts.options.count)))))
        }
        if showsIniNames, let skin {
            let count = skin.valueUsages().values.filter { $0.variableName != nil && $0.origin != .none }.count
            items.append(.init(id: "options.variables", kind: .link(.init(id: "options.variables",
                                                                           title: StudioText.format(.allVariables, count)))))
        }
        return StudioPage.Section(id: "options", title: StudioText[.sectionOptions], items: items)
    }

    static func key(_ o: StudioWidgetFacts.Option) -> String { o.variable ?? o.measure ?? o.label }

    func optionRow(_ o: StudioWidgetFacts.Option) -> StudioPage.Row {
        let label = o.label == "Clock" ? StudioText[.clock] : o.label
        var row = StudioPage.Row(label: label, control: .text(o.current))
        row.detail = showsIniNames ? (o.variable ?? "Format") : nil
        switch o.kind {
        case .color:
            let color = OptionValue.color(o.current)
            row.control = .color(.init(id: "option:\(Self.key(o))", kind: .color, color: color, label: label,
                                       active: activeSwatch == "option:\(Self.key(o))"))
            if color == nil { row.invalid = o.raw }
        case .alpha:
            let v = Double(o.current.trimmingCharacters(in: .whitespaces)) ?? 255
            row.control = .percent(min(max(v / 255, 0), 1))
        case .toggle:
            row.control = .toggle(o.current.trimmingCharacters(in: .whitespaces) == "1")
        case .choice(let values):
            let titles = values.map { StudioWords.choice($0, of: o.variable ?? "") }
            let selected = values.firstIndex { $0.caseInsensitiveCompare(o.current) == .orderedSame }
            if selected == nil { row.invalid = o.current }
            if values.count <= 4 {
                row.control = .segmented(.init(items: titles, selected: selected ?? -1))
            } else {
                row.control = .popup(.init(items: titles.map { StudioPage.MenuItem(title: $0) }, selected: selected))
            }
        case .hours(let twentyFour):
            row.control = .segmented(.init(items: [StudioText[.hours12], StudioText[.hours24]], selected: twentyFour ? 1 : 0))
        }
        return row
    }

    // MARK: Shows

    func showsSection(_ facts: StudioWidgetFacts) -> StudioPage.Section? {
        guard !plan.shows.isEmpty, let skin else { return nil }
        var items: [StudioPage.Item] = []
        for row in plan.shows {
            items.append(.init(id: "shows:\(row.measure)", kind: .row(showsRow(row, facts: facts, skin: skin))))
        }
        if plan.hiddenShows > 0 {
            items.append(.init(id: "shows.all", kind: .link(.init(id: "shows.all",
                                                                   title: StudioText.format(.allData, facts.shows.count)))))
        }
        return StudioPage.Section(id: "shows", title: StudioText[.sectionShows], items: items)
    }

    func showsRow(_ row: StudioWidgetFacts.ShowsRow, facts: StudioWidgetFacts, skin: Skin) -> StudioPage.Row {
        let label = StudioWords.kind(row.kind) + (row.number > 0 ? " \(row.number)" : "")
        var items: [StudioPage.MenuItem] = []
        var selected: Int?
        var anyChoice = false
        for choice in row.choices {
            guard let m = skin.measure(named: choice.measure) else { continue }
            let name = StudioWords.data(StudioWidgetFacts.dataName(m, in: skin).name)
            if case .current = choice.write { selected = items.count }
            let enabled: Bool
            switch choice.write {
            case .current: enabled = true
            case .none: enabled = false
            case .variable, .rebind: enabled = true; anyChoice = true
            }
            items.append(.init(title: name, detail: Self.liveValue(m, skin: skin), symbol: StudioWords.symbol(m),
                               enabled: enabled))
        }
        if !anyChoice {
            items.append(.init(title: StudioText[.showsOnlyThis], enabled: false))
        }
        let measure = skin.measure(named: row.measure)
        let partColor = facts.colors.parts.first { !Set($0.meters).isDisjoint(with: row.meters) }?.color
        var r = StudioPage.Row(label: label, control: .popup(.init(items: items, selected: selected,
                                                                   symbol: measure.map(StudioWords.symbol),
                                                                   symbolColor: partColor)))
        r.labelWidth = 58
        r.detail = showsIniNames ? row.measure : nil
        return r
    }

    /// A data item's value as its parts would show it ("21%", "20.4 GB").
    static func liveValue(_ m: Measure, skin: Skin) -> String {
        if let text = m.rawString, !text.isEmpty, Double(text) == nil { return text }
        let v = m.value
        switch m.type {
        case "cpu", "advancedcpu", "usagemonitor": return "\(Int(v.rounded()))%"
        case "macsensors":
            let s = m.string("Sensor").lowercased()
            return s.contains("usage") ? "\(Int(v.rounded()))%" : NumberFormatting.plain((v * 10).rounded() / 10)
        case "physicalmemory", "memory", "swapmemory", "freediskspace":
            return ByteCountFormatter.string(fromByteCount: Int64(max(v, 0)), countStyle: .memory)
        case "netin", "netout", "nettotal":
            return ByteCountFormatter.string(fromByteCount: Int64(max(v, 0)), countStyle: .file) + "/s"
        default: return NumberFormatting.plain((v * 10).rounded() / 10)
        }
    }

    // MARK: Colors

    /// What a color paints, as the page and the popover name it: Text and Card by those words.
    static func title(_ role: StudioWidgetFacts.ColorRole) -> String {
        switch role.kind {
        case .text: return StudioText[.swatchText]
        case .card: return StudioText[.swatchCard]
        default: return StudioWords.title(short: role.label, kind: role.partKind)
        }
    }

    /// The swatches' roles by id.
    func colorRoles(_ facts: StudioWidgetFacts) -> [String: StudioWidgetFacts.ColorRole] {
        var map: [String: StudioWidgetFacts.ColorRole] = [:]
        for (i, r) in facts.colors.parts.enumerated() { map["part:\(i)"] = r }
        if let t = facts.colors.text { map["text"] = t }
        if let c = facts.colors.card { map["card"] = c }
        for r in facts.colors.accents { if let v = r.variable { map["option:\(v)"] = r } }
        return map
    }

    func colorsSection(_ facts: StudioWidgetFacts) -> StudioPage.Section {
        var parts: [StudioPage.Swatch] = []
        for (i, r) in plan.parts.enumerated() {
            parts.append(.init(id: "part:\(i)", kind: .color, color: r.color, label: StudioWords.short(r.label),
                               active: activeSwatch == "part:\(i)",
                               tooltip: StudioWords.title(short: r.label, kind: r.partKind)))
        }
        var pair: [StudioPage.Swatch] = []
        let text = facts.colors.text, card = facts.colors.card
        pair.append(.init(id: "text", kind: .text, color: text?.color, follows: text?.followsLook ?? true,
                          label: StudioText[.swatchText], active: activeSwatch == "text"))
        if card != nil {
            pair.append(.init(id: "card", kind: .card, color: card?.color, follows: card?.followsLook ?? true,
                              label: StudioText[.swatchCard], active: activeSwatch == "card"))
        }
        let shown = plan.parts.count + (text == nil ? 0 : 1) + (card == nil ? 0 : 1)
        let everything = facts.colors.all.filter { $0.color.a >= 10 && !$0.meters.isEmpty }.count
        if everything > shown {
            pair.append(.init(id: "more", kind: .more, label: StudioText[.swatchMore], active: activeSwatch == "more"))
        }
        let follows = (text?.followsLook ?? true) && (card?.followsLook ?? true)
        var caption: String?
        if let id = activeSwatch ?? hoveredSwatch, let role = colorRoles(facts)[id] {
            caption = StudioText.format(.paints, Self.title(role), StudioWords.parts(role.parts))
        }
        let block = StudioPage.Swatches(parts: parts, pair: pair, followNote: follows ? StudioText[.followTheLook] : nil,
                                        caption: caption)
        return StudioPage.Section(id: "colors", title: StudioText[.sectionColors],
                                  items: [.init(id: "colors", kind: .swatches(block))])
    }

    // MARK: Fonts

    func fontsSection(_ facts: StudioWidgetFacts) -> StudioPage.Section? {
        guard !facts.fonts.isEmpty || plan.sizeInFonts else { return nil }
        var items: [StudioPage.Item] = []
        let roles = plan.fontsMerged ? Array(facts.fonts.prefix(1)) : facts.fonts
        for role in roles {
            let key: String
            let label: String
            switch plan.fontsMerged ? .words : role.role {
            case .numbers: key = "numbers"; label = StudioText[.fontNumbers]
            case .labels: key = "labels"; label = StudioText[.fontLabels]
            case .words: key = "words"; label = StudioText[.fontWords]
            }
            items.append(.init(id: "font:\(key)", kind: .row(fontRow(role, label: label))))
        }
        if plan.sizeInFonts { items.append(.init(id: "size", kind: .row(sizeRow(facts)))) }
        let title = plan.sizeInFonts ? StudioText[.sectionFontsAndSize] : StudioText[.sectionFonts]
        return StudioPage.Section(id: "fonts", title: title, trailing: facts.textSizes.isEmpty ? nil : .textSize,
                                  items: items)
    }

    /// The faces a font menu offers: the widget's own first, then the Mac's.
    func faces(current: String) -> [String] {
        var result: [String] = []
        func add(_ f: String) {
            if !result.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) { result.append(f) }
        }
        add(current)
        for f in facts?.fonts ?? [] { add(f.face) }
        for f in skin?.settings.localFonts ?? [] { add(f) }
        for f in StudioFontMenu.common { add(f) }
        return result
    }

    func fontRow(_ role: StudioWidgetFacts.FontRole, label: String) -> StudioPage.Row {
        let list = faces(current: role.face)
        let items = list.map { StudioPage.MenuItem(title: StudioFontMenu.title($0), face: $0) }
        var row = StudioPage.Row(label: label, control: .popup(.init(items: items, selected: 0, fonts: true)))
        if showsIniNames { row.detail = "FontFace" }
        return row
    }

    // MARK: Look and size

    func lookSection(_ facts: StudioWidgetFacts) -> StudioPage.Section? {
        guard let look = facts.look else { return nil }
        var items: [StudioPage.Item] = []
        let tiles = look.values.map { value -> StudioPage.Thumbnails.Tile in
            .init(title: Self.lookTitle(value), image: thumbnails.image(look: value),
                  selected: value.caseInsensitiveCompare(look.current) == .orderedSame)
        }
        items.append(.init(id: "look", kind: .thumbnails(.init(tiles: tiles))))
        // The look is the suite's: choosing one changes every widget that reads it (package scope).
        if look.widgets > 1 {
            items.append(.init(id: "look.scope", kind: .note(.init(
                text: StudioText.format(.lookShared, look.widgets, skin?.rootConfig ?? ""), symbol: "square.stack"))))
        }
        if !plan.sizeInFonts { items.append(.init(id: "size", kind: .row(sizeRow(facts)))) }
        return StudioPage.Section(id: "look", title: StudioText[.sectionLookAndSize], items: items)
    }

    static func lookTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "auto": return StudioText[.lookAuto]
        case "light": return StudioText[.lookLight]
        case "dark": return StudioText[.lookDark]
        case "clear": return StudioText[.lookClear]
        default: return value
        }
    }

    func sizeRow(_ facts: StudioWidgetFacts) -> StudioPage.Row {
        if let v = facts.variants {
            let titles = v.files.map { f -> String in
                switch f.lowercased() {
                case "small": return StudioText[.sizeSmallShort]
                case "medium": return StudioText[.sizeMediumShort]
                case "large": return StudioText[.sizeLargeShort]
                default: return f
                }
            }
            let selected = v.files.firstIndex { $0.caseInsensitiveCompare(v.current) == .orderedSame } ?? -1
            var row = StudioPage.Row(label: StudioText[.size], control: .segmented(.init(items: titles, selected: selected,
                                                                                         width: 222)))
            row.labelWidth = 52
            return row
        }
        // Scaling a whole skin needs the engine to draw it bigger: not there yet.
        var row = StudioPage.Row(label: StudioText[.size], control: .segmented(.init(
            items: ["75%", "100%", "125%", "150%"], selected: 1, enabled: false)))
        row.tooltip = StudioText[.sizeLater]
        row.labelWidth = 52
        return row
    }

    // MARK: What is done on the page

    func handle(_ event: StudioPageEvent) {
        switch event {
        case .choose(let item, let index): choose(item, index)
        case .segment(let item, let index): segment(item, index)
        case .toggle(let item, let on):
            if let o = option(item) { writeOption(o, value: on ? "1" : "0", shown: on ? StudioText[.onLabel] : "0", item: item) }
        case .percent(let item, let value, let done): percent(item, value, done: done)
        case .swatch(_, let swatch): openSwatch(swatch)
        case .hoverSwatch(_, let swatch):
            guard activeSwatch == nil else { return }
            hoveredSwatch = swatch
            window.canvasController.canvas.relatedNames = swatch.flatMap { facts.flatMap(colorRoles)?[$0]?.meters } ?? []
            refresh()
        case .thumbnail(_, let index): chooseLook(index)
        case .link(let id): link(id)
        case .noteLink: break
        case .textSize(let step): scaleText(step)
        case .undo: session?.undoStack.undo()
        case .suggestion: break
        }
    }

    func option(_ item: String) -> StudioWidgetFacts.Option? {
        facts?.options.first { "option:\(Self.key($0))" == item }
    }

    private func choose(_ item: String, _ index: Int) {
        if item.hasPrefix("shows:") { return chooseShows(item, index) }
        if item.hasPrefix("font:") { return chooseFont(item, index) }
        guard let o = option(item), case .choice(let values) = o.kind, values.indices.contains(index) else { return }
        writeOption(o, value: values[index], shown: StudioWords.choice(values[index], of: o.variable ?? ""), item: item)
    }

    private func segment(_ item: String, _ index: Int) {
        if item == "size" { return chooseSize(index) }
        guard let o = option(item) else { return }
        switch o.kind {
        case .choice(let values) where values.indices.contains(index):
            writeOption(o, value: values[index], shown: StudioWords.choice(values[index], of: o.variable ?? ""), item: item)
        case .hours:
            let twentyFour = index == 1
            let format = Self.format(o.current, twentyFour: twentyFour)
            let shown = twentyFour ? StudioText[.hours24] : StudioText[.hours12]
            if let variable = o.variable {
                writeVariable(variable, value: format, name: StudioText[.clock], confirm: StudioText.format(
                    .confirmOption, StudioText[.clock], shown), item: item, section: "options")
            } else if let measure = o.measure, let skin, let target = skin.localTarget(section: measure, key: "Format") {
                apply(StudioText[.clock], [.setValue(file: target.file, section: target.section, key: "Format",
                                                     value: format, afterIncludes: false)],
                      confirm: StudioText.format(.confirmOption, StudioText[.clock], shown), item: item, section: "options")
            }
        default: break
        }
    }

    /// A time format with its hours letter changed (`%H` ↔ `%I`, `%#H` ↔ `%#I`), nothing else.
    static func format(_ format: String, twentyFour: Bool) -> String {
        twentyFour ? format.replacingOccurrences(of: "%I", with: "%H").replacingOccurrences(of: "%#I", with: "%#H")
            : format.replacingOccurrences(of: "%H", with: "%I").replacingOccurrences(of: "%#H", with: "%#I")
    }

    private func percent(_ item: String, _ value: Double, done: Bool) {
        guard let o = option(item), let variable = o.variable else { return }
        let text = String(Int((value * 255).rounded()))
        if !done {
            session?.previewVariables([variable: text])
            return
        }
        session?.endPreview()
        writeOption(o, value: text, shown: "\(Int((value * 100).rounded())) %", item: item)
    }

    func writeOption(_ o: StudioWidgetFacts.Option, value: String, shown: String, item: String) {
        guard let variable = o.variable else { return }
        writeVariable(variable, value: value, name: o.label,
                      confirm: StudioText.format(.confirmOption, o.label, shown), item: item, section: "options")
    }

    /// Writes a `[Variables]` entry for this widget: in its own file, after its includes (so it wins over a shared
    /// definition), where `Skin.localTarget` says.
    func writeVariable(_ variable: String, value: String, name: String, confirm: String, item: String, section: String) {
        guard let skin, let target = skin.localTarget(section: "Variables", key: variable) else { return }
        apply(name, [.setValue(file: target.file, section: target.section, key: variable, value: value,
                               afterIncludes: true)], confirm: confirm, item: item, section: section)
    }

    private func chooseShows(_ item: String, _ index: Int) {
        guard let facts, let skin, let row = facts.shows.first(where: { "shows:\($0.measure)" == item }) else { return }
        // The menu's items are the choices whose data exists, in order.
        let choices = row.choices.filter { skin.measure(named: $0.measure) != nil }
        guard choices.indices.contains(index) else { return }
        let choice = choices[index]
        let name = StudioWords.data(skin.measure(named: choice.measure).map {
            StudioWidgetFacts.dataName($0, in: skin).name } ?? choice.measure)
        let part = StudioWords.kind(row.kind) + (row.number > 0 ? " \(row.number)" : "")
        let confirm = StudioText.format(.confirmShows, part, name)
        switch choice.write {
        case .current, .none: return
        case .variable(let variable, let value):
            writeVariable(variable, value: value, name: StudioText[.undoShows], confirm: confirm, item: item, section: "shows")
        case .rebind(let meters):
            let ops: [EditOp] = meters.map { meter in
                Self.own(meter, key: "MeasureName", value: choice.measure, skin: skin)
            }
            apply(StudioText[.undoShows], ops, confirm: confirm, item: item, section: "shows")
        }
    }

    private func chooseFont(_ item: String, _ index: Int) {
        guard let facts, let skin else { return }
        let key = String(item.dropFirst("font:".count))
        let role: StudioWidgetFacts.FontRole?
        switch key {
        case "numbers": role = facts.fonts.first { $0.role == .numbers }
        case "labels": role = facts.fonts.first { $0.role == .labels }
        default: role = facts.fonts.first
        }
        guard let role else { return }
        let list = faces(current: role.face)
        guard list.indices.contains(index), list[index].caseInsensitiveCompare(role.face) != .orderedSame else { return }
        let face = list[index]
        // Merged into one row: every font of the widget changes.
        let roles = plan.fontsMerged ? facts.fonts : [role]
        var ops: [EditOp] = []
        for r in roles { ops += fontOps(r, face: face, skin: skin) }
        let what: String
        switch key {
        case "numbers": what = StudioText[.fontNumbers]
        case "labels": what = StudioText[.fontLabels]
        default: what = StudioText[.fontWords]
        }
        apply(StudioText[.undoFont], ops, confirm: StudioText.format(.confirmFont, what, StudioFontMenu.title(face)),
              item: item, section: "fonts")
    }

    func fontOps(_ role: StudioWidgetFacts.FontRole, face: String, skin: Skin) -> [EditOp] {
        switch role.source {
        case .variable(let v):
            guard let t = skin.localTarget(section: "Variables", key: v) else { return [] }
            return [.setValue(file: t.file, section: t.section, key: v, value: face, afterIncludes: true)]
        case .look(let look):
            guard let t = skin.localTarget(section: look, key: "FontFace") else { return [] }
            return [.setValue(file: t.file, section: t.section, key: "FontFace", value: face, afterIncludes: false)]
        case .meters(let meters):
            return meters.map { Self.own($0, key: "FontFace", value: face, skin: skin) }
        }
    }

    /// A− / A+: every text size of the widget one step smaller or bigger (×1.125), in one step.
    func scaleText(_ step: Int) {
        guard let facts, let skin, !facts.textSizes.isEmpty else { return }
        let factor = step > 0 ? 1.125 : 1 / 1.125
        var ops: [EditOp] = []
        for size in facts.textSizes {
            let value = Self.scaled(size.value, by: factor)
            let text = NumberFormatting.plain(value)
            switch size.source {
            case .variable(let v):
                guard let t = skin.localTarget(section: "Variables", key: v) else { continue }
                ops.append(.setValue(file: t.file, section: t.section, key: v, value: text, afterIncludes: true))
            case .look(let look):
                guard let t = skin.localTarget(section: look, key: "FontSize") else { continue }
                ops.append(.setValue(file: t.file, section: t.section, key: "FontSize", value: text, afterIncludes: false))
            case .meter(let m):
                ops.append(Self.own(m, key: "FontSize", value: text, skin: skin))
            }
        }
        apply(StudioText[.undoTextSize], ops, confirm: StudioText[step > 0 ? .confirmBigger : .confirmSmaller],
              item: "fonts.top", section: "fonts")
    }

    /// An option of one part, written for this widget: where `Skin.localTarget` says when the part is the widget's
    /// own, else where `ScopeResolver` puts the part's own value.
    static func own(_ section: String, key: String, value: String, skin: Skin) -> EditOp {
        if let t = skin.localTarget(section: section, key: key) {
            return .setValue(file: t.file, section: t.section, key: key, value: value, afterIncludes: false)
        }
        let t = ScopeResolver(skin: skin).target(section: section, key: key, selection: [section])
        return .setValue(file: t.file, section: t.section, key: t.key, value: value, afterIncludes: false)
    }

    /// A size one step on: to a quarter point, at least a quarter point further, never below 1.
    static func scaled(_ value: Double, by factor: Double) -> Double {
        var v = (value * factor * 4).rounded() / 4
        if factor > 1, v <= value { v = value + 0.25 }
        if factor < 1, v >= value { v = value - 0.25 }
        return max(v, 1)
    }

    /// A look (a thumbnail): the suite's look variable, in the file the suite shares (a look for one widget alone is
    /// not something the suite's files can say: the look is read before the widget's own values). The other widgets
    /// that read the file load again (the window does that for any step on a shared file).
    private func chooseLook(_ index: Int) {
        guard let look = facts?.look, look.values.indices.contains(index), let file = look.file,
              look.values[index].caseInsensitiveCompare(look.current) != .orderedSame else { return }
        let value = look.values[index]
        apply(StudioText[.undoLook], [.setValue(file: file, section: "Variables", key: look.variable, value: value,
                                                afterIncludes: false)],
              confirm: StudioText.format(.confirmLook, Self.lookTitle(value)), item: "look", section: "look")
    }

    /// Small, Medium or Large: the desktop runs that variant file instead (undoable).
    private func chooseSize(_ index: Int) {
        guard let v = facts?.variants, v.files.indices.contains(index),
              v.files[index].caseInsensitiveCompare(v.current) != .orderedSame, let session, let link = window.link
        else { return }
        let from = v.current + ".ini", to = v.files[index] + ".ini"
        guard link.switchVariant(to: to) else { return }
        let name = StudioText[.undoSize]
        // On the widget's own undo stack, which outlives the window: the app loads the variant, and a window showing
        // the widget follows it (`DesktopLink` hears the desktop change).
        func register(_ back: String, _ forward: String) {
            session.undoStack.registerUndo(withTarget: session) { session in
                if session.app.activate(config: session.config, file: back) != nil { register(forward, back) }
            }
            session.undoStack.setActionName(name)
        }
        register(from, to)
        let shown: String
        switch v.files[index].lowercased() {
        case "small": shown = StudioText[.sizeSmall]
        case "large": shown = StudioText[.sizeLarge]
        default: shown = StudioText[.sizeMedium]
        }
        setConfirmation(.init(after: "size", section: plan.sizeInFonts ? "fonts" : "look",
                              value: .init(text: StudioText.format(.confirmSize, shown), undo: StudioText[.confirmUndo]),
                              step: name))
        window.updateToolbar()
    }

    private func link(_ id: String) {
        guard let facts, let skin else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch id {
        case "options.all":
            for o in facts.options.dropFirst(plan.options.count) {
                menu.addItem(ClosureMenuItem("\(o.label) — \(o.current)", enabled: false) {})
            }
        case "options.variables":
            for v in skin.valueUsages().values {
                guard let name = v.variableName, v.origin != .none else { continue }
                menu.addItem(ClosureMenuItem("\(name) = \(v.raw)", enabled: false) {})
            }
        case "shows.all":
            for row in facts.shows.dropFirst(plan.shows.count) {
                let name = skin.measure(named: row.measure).map { StudioWidgetFacts.dataName($0, in: skin).name } ?? row.measure
                menu.addItem(ClosureMenuItem(StudioWords.kind(row.kind) + (row.number > 0 ? " \(row.number)" : "")
                                             + " — " + StudioWords.data(name), enabled: false) {})
            }
        case "more-settings":
            // How often the widget refreshes ([Rainmeter] Update), for this widget.
            let current = skin.settings.update
            for (ms, key) in [(1000, StudioText.Key.refreshSecond), (2000, .refreshTwoSeconds), (60000, .refreshMinute)] {
                let item = ClosureMenuItem(StudioText[key]) { [weak self] in self?.setUpdate(ms) }
                item.state = current == ms ? .on : .off
                menu.addItem(item)
            }
        default: return
        }
        guard app.presentsWindows, menu.numberOfItems > 0 else { return }
        let view: NSView? = id == "more-settings" ? window.inspectorController.pageView.footerView(id)
            : window.inspectorController.pageView.itemView(id)
        guard let view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
    }

    /// How often the widget refreshes, for this widget.
    func setUpdate(_ milliseconds: Int) {
        guard let skin, let t = skin.localTarget(section: "Rainmeter", key: "Update") else { return }
        let shown: String
        switch milliseconds {
        case 1000: shown = StudioText[.refreshSecond]
        case 2000: shown = StudioText[.refreshTwoSeconds]
        default: shown = StudioText[.refreshMinute]
        }
        apply(StudioText[.undoRefresh], [.setValue(file: t.file, section: t.section, key: "Update",
                                                   value: String(milliseconds), afterIncludes: false)],
              confirm: StudioText.format(.confirmRefresh, shown), item: "more-settings", section: "look")
    }

    // MARK: Colors

    private func openSwatch(_ id: String) {
        guard let facts else { return }
        if id == "more" { return showMoreColors(facts) }
        guard let role = colorRoles(facts)[id] else { return }
        openColor(role, swatch: id)
    }

    /// More…: every color of the widget and what it paints; choosing one opens the color popover on it.
    private func showMoreColors(_ facts: StudioWidgetFacts) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = StudioPageView.heading(StudioText[.moreColorsTitle])
        menu.addItem(header)
        for role in facts.colors.all where role.color.a >= 10 && !role.meters.isEmpty {
            let title = Self.title(role) + " · " + StudioWords.parts(role.parts)
            let item = ClosureMenuItem(title) { [weak self] in self?.openColor(role, swatch: "more") }
            item.image = Self.swatchImage(role.color)
            menu.addItem(item)
        }
        guard app.presentsWindows, let anchor = window.inspectorController.pageView.swatchView(item: "colors",
                                                                                                swatch: "more") else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    static func swatchImage(_ c: RGBA) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            StudioPageStyle.color(c).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    /// Opens the color popover on a role: its picks show at once (a preview), and closing it makes one step.
    func openColor(_ role: StudioWidgetFacts.ColorRole, swatch: String) {
        guard let skin, let facts else { return }
        colorPopover?.close()
        activeSwatch = swatch
        hoveredSwatch = nil
        window.canvasController.canvas.relatedNames = []
        let written = StudioColorWriting.currentText(role, skin: skin)
        let target = StudioColorPopover.Target(title: Self.title(role),
                                               color: role.color, written: written, parts: role.parts,
                                               acceptsAlpha: role.acceptsAlpha)
        let widgetColors = facts.colors.parts.map(\.color) + [facts.colors.text, facts.colors.card].compactMap { $0?.color }
            + facts.colors.accents.map(\.color)
        let popover = StudioColorPopover(target: target, widgetColors: widgetColors, presentsWindows: app.presentsWindows)
        popover.onPreview = { [weak self] color in self?.previewColor(role, color) }
        popover.onClose = { [weak self] color, name in self?.commitColor(role, color, name: name, swatch: swatch) }
        popover.anchorItem = swatch.hasPrefix("option:") ? swatch : "colors"
        _ = popover.view
        colorPopover = popover
        refresh()
        if app.presentsWindows, window.window?.isVisible == true, let anchor = popoverAnchor() {
            popover.show(relativeTo: anchor.rect, of: anchor.view)
        }
    }

    /// Where the color popover points: the inspector's edge, level with the swatch it is open on (it sits over the
    /// canvas, leaving the other swatches in sight).
    func popoverAnchor() -> (view: NSView, rect: NSRect)? {
        guard let swatch = activeSwatch, let popover = colorPopover else { return nil }
        let pageView = window.inspectorController.pageView
        guard let anchor = pageView.swatchView(item: popover.anchorItem, swatch: swatch) else { return nil }
        let dot = (anchor as? StudioSwatchView)?.dotRect ?? anchor.bounds
        let inPage = anchor.convert(dot, to: pageView)
        return (pageView, NSRect(x: 0, y: inPage.minY, width: 1, height: inPage.height))
    }

    private func previewColor(_ role: StudioWidgetFacts.ColorRole, _ color: RGBA) {
        guard let skin, let session else { return }
        let preview = StudioColorWriting.preview(role, color, skin: skin)
        if !preview.variables.isEmpty { session.previewVariables(preview.variables) }
        for (section, values) in preview.sections { session.preview(section: section, values) }
    }

    /// The popover closed: what it picked becomes one step ("Color"), confirmed under the swatches.
    private func commitColor(_ role: StudioWidgetFacts.ColorRole, _ color: RGBA?, name: String?, swatch: String) {
        colorPopover = nil
        activeSwatch = nil
        session?.endPreview()
        guard let color, let skin,
              ValueUsageIndex.colorKey(color) != ValueUsageIndex.colorKey(role.color) || name == "accent"
        else { return refresh() }
        var ops = StudioColorWriting.ops(role, color, skin: skin)
        // The accent that follows the Mac, where the color may carry its alpha: the Mac's own accent variable.
        if name == "accent", role.acceptsAlpha, let v = role.variable,
           let target = skin.localTarget(section: "Variables", key: v) {
            ops = [.setValue(file: target.file, section: target.section, key: v,
                             value: "#\(BuiltInVariables.macAccentColor)#", afterIncludes: true)]
        }
        let words = name.map(StudioWords.color) ?? StudioWords.color(LayerNaming.colorName(color))
        let what = Self.title(role)
        let section = swatch.hasPrefix("option:") ? "options" : "colors"
        apply(StudioText[.undoColor], ops, confirm: StudioText.format(.confirmColor, what, words),
              item: swatch.hasPrefix("option:") ? swatch : "colors", section: section)
    }

    // MARK: Steps

    /// Makes a step through the session and confirms it under the control that made it (at the Customize depth).
    func apply(_ name: String, _ ops: [EditOp], confirm: String, item: String, section: String) {
        guard let session, !ops.isEmpty else { return }
        do {
            guard try session.apply(name, ops) != nil else { return }
        } catch {
            Log.write("Studio: \(name) was not made: \(error)", level: .warning, source: session.config)
            if app.presentsWindows { NSSound.beep() }
            return
        }
        setConfirmation(.init(after: item, section: section,
                              value: .init(text: confirm, undo: StudioText[.confirmUndo]), step: name))
    }

    private func setConfirmation(_ c: Confirmation) {
        // Building (the sidebar open), a change to one value stays quiet: the canvas shows it.
        confirmation = window.depth == .customize ? c : nil
        refresh()
    }

    /// A step was undone or redone: the confirmation of an undone step goes.
    func stepReverted() {
        confirmation = nil
    }

    /// The window closes or shows another widget: the popover closes (what it picked is kept).
    func close() {
        colorPopover?.close()
        colorPopover = nil
        activeSwatch = nil
        confirmation = nil
    }
}
