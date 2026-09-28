import AppKit
import DesksetCore

/// What a row of a part's page writes, kept while the page is shown so its events know the option.
struct StudioPartRow {
    enum Kind {
        /// A text size in points on screen (the file's `FontSize` is in points at 96 dpi: ×4/3).
        case fontSize
        /// X, Y, W, H: written the way the file writes them (`10R` stays relative).
        case geometry
        /// A plain number.
        case number(minimum: Double?, maximum: Double?)
        /// Words.
        case text
        /// A choice among values (written as they are).
        case choice([String])
        /// A choice of which the empty value removes the option.
        case fonts([String])
        case styles([String])
        case align
        case data([String])
        case examples([[String: String?]])
        case action
        case shapeKind
        /// A shape's corner radius (parameter 4 of a rectangle).
        case shapeRadius
        case shapeStrokeWidth
        case toggle
    }

    var key: String
    var kind: Kind
    /// The step's name ("Text Size").
    var name: String
    /// What the confirmation calls it ("Text size").
    var title: String
    var section: String
}

extension StudioPartPage {
    // MARK: The part's page

    func buildPart(_ m: Meter, skin: Skin) -> StudioPage {
        rows = [:]
        let kind = StudioPartKind(m)
        let title = partTitle(m, skin: skin)
        var page = StudioPage(id: "part:\(m.name)", title: title, subtitle: subtitle(m, kind: kind, skin: skin))
        page.crumbs = crumbs(m, skin: skin)
        page.scope = scopeSentence(m, kind: kind)
        switch kind {
        case .number, .text:
            page.sections = [showsSection(m, kind: kind, skin: skin), textSection(m, skin: skin)].compactMap { $0 }
        case .symbol, .picture:
            page.sections = [pictureSection(m, kind: kind), lookSection(m, kind: kind)].compactMap { $0 }
        case .bar, .ring, .graph:
            page.sections = [dataSection(m, skin: skin), lookSection(m, kind: kind)].compactMap { $0 }
        case .shape:
            page.sections = [shapeSection(m), strokeSection(m)].compactMap { $0 }
        case .part:
            break
        }
        page.sections.append(layoutSection(m, skin: skin))
        page.sections.append(clickSection(m, skin: skin))
        fit(&page, m: m)
        let everyCount = StudioEverySetting.count(StudioEverySetting.groups(meter: m))
        let shown = page.sections.flatMap(\.items).count
        page.footer = [
            StudioPage.Link(id: "every-setting", title: StudioText[.everySetting],
                            detail: StudioText.format(.everySettingMore, max(everyCount - shown, 0)),
                            symbol: "list.bullet.indent"),
            StudioPage.Link(id: "show-in-code", title: StudioText[.showInCode], detail: "⌥⌘↩",
                            symbol: "chevron.left.forwardslash.chevron.right"),
        ]
        insertConfirmation(&page)
        return page
    }

    /// The design's twelve controls: what does not fit goes to Every Setting, in this order — a click row with no
    /// action, the weight, the style, the size.
    func fit(_ page: inout StudioPage, m: Meter) {
        movedOut = []
        let order = ["clicks.action", "text.weight", "text.style", "layout.size", "layout.y"]
        for id in order where page.controlCount > StudioPage.controlLimit {
            if id == "clicks.action", (m.fileOption("LeftMouseUpAction") ?? "").trimmingCharacters(in: .whitespaces)
                .isEmpty == false { continue }
            for i in page.sections.indices {
                if let j = page.sections[i].items.firstIndex(where: { $0.id == id }) {
                    page.sections[i].items.remove(at: j)
                    movedOut.append(id)
                }
            }
            page.sections.removeAll { $0.items.isEmpty }
        }
    }

    func insertConfirmation(_ page: inout StudioPage) {
        page.topConfirmation = topConfirmation
        if topConfirmation != nil { page.tight = true }
        guard let c = confirmation, let si = page.sections.firstIndex(where: { $0.id == c.section }) else { return }
        let items = page.sections[si].items
        let at = (items.firstIndex { $0.id == c.after }).map { $0 + 1 } ?? items.count
        page.sections[si].items.insert(StudioPage.Item(id: "\(c.section).confirm", kind: .confirmation(c.value)), at: at)
        page.tight = true
    }

    /// "‹ System › CPU": the widget, and the data the part shows.
    func crumbs(_ m: Meter, skin: Skin) -> [String] {
        var result = [window.widgetName]
        if let data = liveMeasure(m) {
            result.append(StudioWords.short(StudioWidgetFacts.dataName(data, in: skin).short))
        }
        return result
    }

    /// "Now 21% · the number of CPU".
    func subtitle(_ m: Meter, kind: StudioPartKind, skin: Skin) -> String {
        var parts: [String] = []
        let now = nowValue(m)
        if let data = liveMeasure(m) {
            if let now { parts.append(StudioText.format(.nowValue, now)) }
            let short = StudioWords.short(StudioWidgetFacts.dataName(data, in: skin).short)
            parts.append(StudioText.format(.subtitleOf, kind.noun(), short))
        } else if kind == .text, let now {
            parts.append(StudioText.format(.subtitleSays, LayerNaming.quoted(now, limit: 32)
                .trimmingCharacters(in: CharacterSet(charactersIn: "“”"))))
        } else {
            parts.append(StudioText.format(.subtitleKind, kind.noun()))
        }
        return parts.joined(separator: " · ")
    }

    /// "This number only · Apply to All 4 Numbers"; with Rainmeter details, where it is written.
    func scopeSentence(_ m: Meter, kind: StudioPartKind) -> StudioPage.Scope {
        let choices = scopeChoices(m)
        let level = min(scopeLevel, max(choices.count - 1, 0))
        let current = choices.indices.contains(level) ? choices[level] : nil
        let next = level + 1 < choices.count ? choices[level + 1] : nil
        var text: String
        switch current?.scope {
        case .style?, .sharedValue?:
            text = StudioText.format(.scopeAll, current!.visibleParts.count, noun(current!, of: m, plural: true))
        case .package?:
            text = StudioText.format(.scopeWidgets, current!.widgets.count)
        default:
            text = StudioText.format(.scopeOnly, kind.noun())
        }
        var link: String?
        if let next {
            switch next.scope {
            case .element: link = nil
            case .style, .sharedValue:
                link = StudioText.format(.scopeApplyAll, next.visibleParts.count,
                                         StudioPartKind.titled(noun(next, of: m, plural: true)))
            case .package:
                link = StudioText.format(.scopeWidgetsLink, next.widgets.count)
            }
        } else if level > 0 {
            link = StudioText.format(.scopeOnlyThis, StudioPartKind.titled(kind.noun()))
        }
        if showsIniNames, let current {
            text = ([current] + (next.map { [$0] } ?? [])).map { detail($0, of: m) }.joined(separator: " · ")
        }
        return StudioPage.Scope(text: text, link: link, linkHovered: scopeHovered)
    }

    /// Where a scope writes, in the file's words: "Only [MeterCPU]", "shared style StyleValue (4 meters)".
    func detail(_ c: WriteScopeChoice, of m: Meter) -> String {
        switch c.scope {
        case .element: return StudioText.format(.scopeDetailOnly, m.name)
        case .style(let s): return StudioText.format(.scopeDetailStyle, s, c.parts.count)
        case .sharedValue(let v): return StudioText.format(.scopeDetailVariable, v, c.parts.count)
        case .package(let file, _, _): return StudioText.format(.scopeDetailFile, file.lastPathComponent, c.widgets.count)
        }
    }

    // MARK: Shows

    func showsSection(_ m: Meter, kind: StudioPartKind, skin: Skin) -> StudioPage.Section? {
        var items: [StudioPage.Item] = []
        if let data = liveMeasure(m) {
            let name = StudioWords.data(StudioWidgetFacts.dataName(data, in: skin).name)
            let pattern = textPattern(m)
            var parts: [StudioPage.Token.Part] = []
            let pieces = pattern.components(separatedBy: "%1")
            if let before = pieces.first, !before.isEmpty { parts.append(.text(before)) }
            parts.append(.data(name: name, symbol: StudioWords.symbol(data)))
            if pieces.count > 1 {
                let after = pieces.dropFirst().joined(separator: "…")
                if !after.isEmpty { parts.append(.text(after)) }
            }
            items.append(.init(id: "shows.token", kind: .token(.init(parts: parts))))
            rows["shows.token"] = StudioPartRow(key: "MeasureName", kind: .data(choosableData(skin)),
                                               name: StudioText[.undoShows], title: StudioText[.sectionShows],
                                               section: "shows")
            // Examples rendered with the real value, when the part formats the number itself.
            if let bound = m.measures.first, bound.rawString == nil || Double(bound.rawString ?? "") != nil {
                let unit = FormatPresets.unit(forMeasureType: bound.type)
                let presets = Array(FormatPresets.numberPresets(for: bound.value, unit: unit,
                                                                base: FormatPresets.base(ofAutoScale: m.fileOption("AutoScale")))
                    .prefix(3))
                if !presets.isEmpty {
                    var current: [String: String] = [:]
                    for k in FormatPresets.numberKeys { if let v = m.fileOption(k) { current[k] = v } }
                    let selected = FormatPresets.index(of: current, in: presets)
                    let titles = presets.map { pattern.replacingOccurrences(of: "%1", with: $0.title) }
                    items.append(.init(id: "shows.format", kind: .examples(.init(items: titles, selected: selected))))
                    rows["shows.format"] = StudioPartRow(key: "NumOfDecimals", kind: .examples(presets.map(\.options)),
                                                        name: StudioText[.undoFormat], title: StudioText[.undoFormat],
                                                        section: "shows")
                }
            }
        } else {
            let text = m.fileOption("Text") ?? ""
            var row = StudioPage.Row(label: StudioText[.sectionText], control: .number(.init(
                text: text, value: nil, placeholder: "", isText: true)))
            row.labelWidth = 58
            row.detail = showsIniNames ? "Text" : nil
            items.append(.init(id: "shows.text", kind: .row(row)))
            rows["shows.text"] = StudioPartRow(key: "Text", kind: .text, name: StudioText[.sectionText],
                                              title: StudioText[.sectionText], section: "shows")
        }
        return StudioPage.Section(id: "shows", title: StudioText[.sectionShows], items: items)
    }

    /// The part's words with `%1` where the data goes ("%1%"), its before and after included.
    func textPattern(_ m: Meter) -> String {
        let text = m.fileOption("Text").flatMap { $0.isEmpty ? nil : $0 } ?? "%1"
        return (m.fileOption("Prefix") ?? "") + text + (m.fileOption("Postfix") ?? "")
    }

    /// The data a part can be switched to: the widget's live data a Shows row may choose.
    func choosableData(_ skin: Skin) -> [String] {
        skin.measures.filter { m in
            StudioWidgetFacts.choosableTypes.contains(m.type)
                && (OptionValue.number(m.fileOption("Total") ?? "0") ?? 0) == 0
        }.map(\.name)
    }

    // MARK: Text

    func textSection(_ m: Meter, skin: Skin) -> StudioPage.Section? {
        guard let s = m as? StringMeter else { return nil }
        var items: [StudioPage.Item] = []
        // Style: the shared text styles of the widget, in words.
        let styles = textStyles(skin)
        let current = (m.fileOption("MeterStyle") ?? "").trimmingCharacters(in: .whitespaces)
        if !styles.isEmpty || !current.isEmpty {
            var list = styles
            if !current.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
                list.insert(current, at: 0)
            }
            let chosen = list.firstIndex { $0.caseInsensitiveCompare(current) == .orderedSame }
            var menu = list.map { StudioPage.MenuItem(title: Self.styleWords($0)) }
            menu.append(.init(title: StudioText[.noStyle]))
            var row = StudioPage.Row(label: StudioText[.rowStyle], control: .popup(.init(items: menu,
                                                                                       selected: chosen ?? list.count)))
            row.detail = showsIniNames ? "MeterStyle" : nil
            items.append(.init(id: "text.style", kind: .row(row)))
            rows["text.style"] = StudioPartRow(key: "MeterStyle", kind: .styles(list + [""]), name: StudioText[.undoStyle],
                                              title: StudioText[.rowStyle], section: "text")
        }
        // Font.
        let faces = self.faces(current: s.style.fontFace, skin: skin)
        var font = StudioPage.Row(label: StudioText[.rowFont], control: .popup(.init(
            items: faces.map { StudioPage.MenuItem(title: StudioFontMenu.title($0), face: $0) }, selected: 0, fonts: true)))
        font.detail = showsIniNames ? "FontFace" : nil
        items.append(.init(id: "text.font", kind: .row(font)))
        rows["text.font"] = StudioPartRow(key: "FontFace", kind: .fonts(faces), name: StudioText[.undoFont],
                                         title: StudioText[.rowFont], section: "text")
        // Text size, with A− / A+.
        let pt = TextStyle.pixelSize(points: s.style.fontSize)
        var size = StudioPage.Row(label: StudioText[.rowTextSize], control: .number(.init(
            text: StudioNumberInput.text((pt * 2).rounded() / 2), value: pt, unit: StudioText.language == .chinese ? "点" : "pt",
            defaultText: nil, steppers: true, width: 64, minimum: 1, maximum: 400)))
        size.detail = showsIniNames ? "FontSize" : nil
        items.append(.init(id: "text.size", kind: .row(size)))
        rows["text.size"] = StudioPartRow(key: "FontSize", kind: .fontSize, name: StudioText[.undoTextSize],
                                         title: StudioText[.rowTextSize], section: "text")
        // Weight.
        let weights = EditorSchema.fontWeights
        let weightNow = s.style.fontWeight ?? (s.style.bold ? 700 : 400)
        let weightIndex = weights.enumerated().min { abs((Int($0.element.value) ?? 400) - weightNow)
            < abs((Int($1.element.value) ?? 400) - weightNow) }?.offset
        var weight = StudioPage.Row(label: StudioText[.rowWeight], control: .popup(.init(
            items: weights.map { StudioPage.MenuItem(title: Self.weightWords($0.title)) }, selected: weightIndex, width: 124)))
        weight.detail = showsIniNames ? "FontWeight" : nil
        items.append(.init(id: "text.weight", kind: .row(weight)))
        rows["text.weight"] = StudioPartRow(key: "FontWeight", kind: .choice(weights.map(\.value)),
                                           name: StudioText[.undoWeight], title: StudioText[.rowWeight], section: "text")
        // Color.
        if let c = color("FontColor", of: m) {
            let raw = m.fileOption("FontColor") ?? ""
            let follows = followsLook(raw, meter: m.name, skin: skin)
            var note: String? = follows ? StudioText[.followsLightDark] : nil
            if showsIniNames { note = "\(StudioWords.color(LayerNaming.colorName(c.color))) — \(c.written)" }
            let swatch = StudioPage.Swatch(id: "text.color", kind: follows ? .text : .color, color: c.color,
                                           follows: follows, label: StudioText[.textColor],
                                           active: activeSwatch == "text.color")
            var row = StudioPage.Row(label: StudioText[.rowColor], control: .colorLabel(.init(
                swatch: swatch, title: StudioText[.textColor], note: note)))
            row.tooltip = showsIniNames ? "Rainmeter: FontColor" : nil
            items.append(.init(id: "text.color", kind: .row(row)))
            rows["text.color"] = StudioPartRow(key: "FontColor", kind: .text, name: StudioText[.undoColor],
                                              title: StudioText[.textColor], section: "text")
        }
        // Align.
        let alignIndex: Int
        switch s.style.horizontalAlign {
        case .left: alignIndex = 0
        case .center: alignIndex = 1
        case .right: alignIndex = 2
        }
        var align = StudioPage.Row(label: StudioText[.rowAlign], control: .segmented(.init(
            items: [StudioText[.alignLeft], StudioText[.alignCenter], StudioText[.alignRight]], selected: alignIndex,
            width: 116, symbols: ["text.alignleft", "text.aligncenter", "text.alignright"])))
        align.detail = showsIniNames ? "StringAlign" : nil
        items.append(.init(id: "text.align", kind: .row(align)))
        rows["text.align"] = StudioPartRow(key: "StringAlign", kind: .align, name: StudioText[.undoAlign],
                                          title: StudioText[.rowAlign], section: "text")
        return StudioPage.Section(id: "text", title: StudioText[.sectionText], items: items)
    }

    /// Whether a color follows the Mac's light or dark look (a variable the suite sets per look, the Mac's own).
    func followsLook(_ raw: String, meter: String, skin: Skin) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.uppercased().contains("#MAC") { return true }
        let v = WriteScopes.soleVariable(t)
        for role in [window.widgetPage.facts?.colors.text].compactMap({ $0 })
            + (window.widgetPage.facts?.colors.all ?? []) {
            let sameVariable = v != nil && role.variable?.caseInsensitiveCompare(v!) == .orderedSame
            let paints = role.meters.contains { $0.caseInsensitiveCompare(meter) == .orderedSame }
            if sameVariable || (paints && role.kind == .text) { return role.followsLook }
        }
        return false
    }

    /// The styles text parts of the widget use, in the order they first appear.
    func textStyles(_ skin: Skin) -> [String] {
        var result: [String] = []
        for m in skin.meters where m.type == "string" {
            for style in (m.fileOption("MeterStyle") ?? "").split(separator: "|") {
                let name = style.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    result.append(name)
                }
            }
        }
        return result
    }

    /// A style's name in words ("sMetricS | sMissing" → "Metric S"; "StyleValue" → "Value").
    static func styleWords(_ list: String) -> String {
        let first = list.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? list
        var name = first
        if name.count > 1, name.first == "s", name.dropFirst().first?.isUppercase == true { name = String(name.dropFirst()) }
        return ValueUsageIndex.humanizedLook(name)
    }

    static func weightWords(_ english: String) -> String {
        guard StudioText.language == .chinese else { return english }
        let table = ["Thin": "极细体", "Light": "细体", "Regular": "常规体", "Medium": "中等", "Semibold": "中粗体",
                     "Bold": "粗体", "Heavy": "特粗体"]
        return table[english] ?? english
    }

    /// The faces the font menu offers: the part's, the widget's own, then the Mac's.
    func faces(current: String, skin: Skin) -> [String] {
        var result: [String] = []
        func add(_ f: String) {
            if !f.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) { result.append(f) }
        }
        add(current)
        for f in window.widgetPage.facts?.fonts ?? [] { add(f.face) }
        for f in skin.settings.localFonts { add(f) }
        for f in StudioFontMenu.common { add(f) }
        return result
    }

    // MARK: Pictures, data, looks, shapes

    func pictureSection(_ m: Meter, kind: StudioPartKind) -> StudioPage.Section? {
        let raw = (m.fileOption("ImageName") ?? "").trimmingCharacters(in: .whitespaces)
        let words = raw.lowercased().hasPrefix("sf:") ? String(raw.dropFirst(3)) : LayerNaming.fileName(raw)
        var row = StudioPage.Row(label: StudioText[kind == .symbol ? .sectionSymbol : .rowPicture],
                                 control: .number(.init(text: words, value: nil, isText: true)))
        row.labelWidth = 58
        row.detail = showsIniNames ? "ImageName" : nil
        rows["shows.picture"] = StudioPartRow(key: "ImageName", kind: .text, name: StudioText[.rowPicture],
                                             title: StudioText[.rowPicture], section: "shows")
        return StudioPage.Section(id: "shows", title: StudioText[.sectionShows],
                                  items: [.init(id: "shows.picture", kind: .row(row))])
    }

    func dataSection(_ m: Meter, skin: Skin) -> StudioPage.Section? {
        let choices = choosableData(skin)
        let bound = m.measures.first
        var items = choices.compactMap { name -> StudioPage.MenuItem? in
            guard let measure = skin.measure(named: name) else { return nil }
            return StudioPage.MenuItem(title: StudioWords.data(StudioWidgetFacts.dataName(measure, in: skin).name),
                                       detail: StudioWidgetPage.liveValue(measure, skin: skin),
                                       symbol: StudioWords.symbol(measure))
        }
        var selected = bound.flatMap { b in choices.firstIndex { $0.caseInsensitiveCompare(b.name) == .orderedSame } }
        if let bound, selected == nil {
            items.insert(.init(title: StudioWords.data(StudioWidgetFacts.dataName(bound, in: skin).name)), at: 0)
            selected = 0
        }
        if bound == nil {
            items.insert(.init(title: StudioText[.dataDetails], enabled: false), at: 0)
            selected = 0
        }
        var row = StudioPage.Row(label: StudioText[.sectionShows], control: .popup(.init(
            items: items, selected: selected, symbol: bound.map(StudioWords.symbol))))
        row.labelWidth = 58
        row.detail = showsIniNames ? "MeasureName" : nil
        rows["shows.data"] = StudioPartRow(key: "MeasureName", kind: .data((bound != nil && choices.contains(bound!.name)
                                                                              ? [] : [""]) + choices),
                                          name: StudioText[.undoShows], title: StudioText[.sectionShows], section: "shows")
        return StudioPage.Section(id: "shows", title: StudioText[.sectionShows], items: [.init(id: "shows.data", kind: .row(row))])
    }

    func lookSection(_ m: Meter, kind: StudioPartKind) -> StudioPage.Section? {
        var items: [StudioPage.Item] = []
        func colorRow(_ id: String, _ key: String, label: String) {
            guard let c = color(key, of: m) else { return }
            let swatch = StudioPage.Swatch(id: id, kind: .color, color: c.color, label: label, active: activeSwatch == id)
            var row = StudioPage.Row(label: label, control: .colorLabel(.init(
                swatch: swatch, title: StudioWords.color(LayerNaming.colorName(c.color)),
                note: showsIniNames ? c.written : nil)))
            row.detail = showsIniNames ? key : nil
            items.append(.init(id: id, kind: .row(row)))
            rows[id] = StudioPartRow(key: key, kind: .text, name: StudioText[.undoColor], title: label, section: "look")
        }
        switch kind {
        case .symbol, .picture:
            colorRow("look.tint", "ImageTint", label: StudioText[.rowTint])
            if kind == .symbol {
                let values = ["Monochrome", "Hierarchical", "Multicolor"]
                let field = StudioCatalog.field("MacSymbolRendering")
                let titles = field?.presets.map { StudioText.language == .chinese ? $0.zh : $0.en } ?? values
                let now = (m.fileOption("MacSymbolRendering") ?? "Monochrome").trimmingCharacters(in: .whitespaces)
                let index = values.firstIndex { $0.caseInsensitiveCompare(now) == .orderedSame } ?? 0
                var row = StudioPage.Row(label: StudioText[.rowSymbolColors], control: .segmented(.init(
                    items: titles, selected: index)))
                row.detail = showsIniNames ? "MacSymbolRendering" : nil
                items.append(.init(id: "look.rendering", kind: .row(row)))
                rows["look.rendering"] = StudioPartRow(key: "MacSymbolRendering", kind: .choice(values),
                                                      name: StudioText[.rowSymbolColors],
                                                      title: StudioText[.rowSymbolColors], section: "look")
            }
        case .bar:
            colorRow("look.fill", "BarColor", label: StudioText[.rowFill])
            colorRow("look.track", "SolidColor", label: StudioText[.rowTrack])
        case .ring, .graph:
            colorRow("look.fill", "LineColor", label: StudioText[.rowFill])
            let width = OptionValue.number(m.option("LineWidth") ?? "") ?? 1
            var row = StudioPage.Row(label: StudioText[.rowThickness], control: .number(.init(
                text: StudioNumberInput.text(width), value: width, unit: StudioText.language == .chinese ? "点" : "pt", width: 64, minimum: 0, maximum: 50)))
            row.detail = showsIniNames ? "LineWidth" : nil
            items.append(.init(id: "look.thickness", kind: .row(row)))
            rows["look.thickness"] = StudioPartRow(key: "LineWidth", kind: .number(minimum: 0, maximum: 50),
                                                  name: StudioText[.rowThickness], title: StudioText[.rowThickness],
                                                  section: "look")
        default:
            break
        }
        guard !items.isEmpty else { return nil }
        return StudioPage.Section(id: "look", title: StudioText[kind == .symbol ? .sectionSymbol : .sectionLook],
                                  items: items)
    }

    /// The first shape of a Shape part, read with `ShapeSpec` (lossless: what it does not change stays as written).
    func shapeSpec(_ m: Meter) -> ShapeSpec? {
        ShapeSpec.parse(m.fileOption("Shape") ?? "")
    }

    func shapeSection(_ m: Meter) -> StudioPage.Section? {
        guard let spec = shapeSpec(m) else { return nil }
        var items: [StudioPage.Item] = []
        let kinds: [ShapeSpec.Kind] = [.rectangle, .ellipse, .line, .arc]
        var list = kinds
        if !list.contains(spec.kind) { list.insert(spec.kind, at: 0) }
        var row = StudioPage.Row(label: StudioText[.rowKind], control: .popup(.init(
            items: list.map { StudioPage.MenuItem(title: $0.title, symbol: $0.symbol) },
            selected: list.firstIndex(of: spec.kind))))
        row.detail = showsIniNames ? "Shape" : nil
        items.append(.init(id: "shape.kind", kind: .row(row)))
        rows["shape.kind"] = StudioPartRow(key: "Shape", kind: .shapeKind, name: StudioText[.undoShape],
                                          title: StudioText[.rowKind], section: "shape")
        if spec.kind == .rectangle {
            // A radius written as a variable shows its value (a change is this shape's own).
            let radius = spec.number(4) ?? OptionValue.number(m.skin.resolve(spec.param(4) ?? "0", in: m,
                                                                                sectionVariables: false)) ?? 0
            var r = StudioPage.Row(label: StudioText[.rowCorners], control: .number(.init(
                text: StudioNumberInput.text(radius), value: radius, unit: StudioText.language == .chinese ? "点" : "pt", defaultText: "0", width: 64, minimum: 0)))
            r.detail = showsIniNames ? "Shape" : nil
            items.append(.init(id: "shape.corners", kind: .row(r)))
            rows["shape.corners"] = StudioPartRow(key: "Shape", kind: .shapeRadius, name: StudioText[.rowCorners],
                                                 title: StudioText[.rowCorners], section: "shape")
        }
        return StudioPage.Section(id: "shape", title: StudioText[.sectionShape], items: items)
    }

    func strokeSection(_ m: Meter) -> StudioPage.Section? {
        guard let spec = shapeSpec(m), let shape = m as? ShapeMeter, let item = shape.shapes.first else { return nil }
        var items: [StudioPage.Item] = []
        func paint(_ p: ShapePaint) -> RGBA? { if case .color(let c) = p { return c }; return nil }
        for (id, label, color) in [("shape.fill", StudioText[.rowFill], paint(item.fill)),
                                   ("shape.stroke", StudioText[.rowStroke], paint(item.stroke))] {
            let c = color ?? RGBA(r: 0, g: 0, b: 0, a: 0)
            let swatch = StudioPage.Swatch(id: id, kind: .color, color: c, label: label, active: activeSwatch == id)
            items.append(.init(id: id, kind: .row(StudioPage.Row(label: label, control: .colorLabel(.init(
                swatch: swatch, title: StudioWords.color(LayerNaming.colorName(c)), note: nil))))))
            rows[id] = StudioPartRow(key: "Shape", kind: .text, name: StudioText[.undoColor], title: label,
                                     section: "stroke")
        }
        let width = spec.modifiers.compactMap { mod -> String? in
            if case .strokeWidth(let w) = mod { return w }
            return nil
        }.last ?? "1"
        items.append(.init(id: "shape.strokeWidth", kind: .row(StudioPage.Row(label: StudioText[.rowStrokeWidth],
            control: .number(.init(text: width, value: Double(width), unit: StudioText.language == .chinese ? "点" : "pt", defaultText: "1", width: 64,
                                   minimum: 0))))))
        rows["shape.strokeWidth"] = StudioPartRow(key: "Shape", kind: .shapeStrokeWidth,
                                                 name: StudioText[.rowStrokeWidth], title: StudioText[.rowStrokeWidth],
                                                 section: "stroke")
        return StudioPage.Section(id: "stroke", title: StudioText[.sectionFillStroke], items: items)
    }

    // MARK: Layout and clicks

    func layoutSection(_ m: Meter, skin: Skin) -> StudioPage.Section {
        var items: [StudioPage.Item] = []
        let raw = m.rawGeometry
        var relative = false
        for (id, key, text) in [("layout.x", "X", raw.x), ("layout.y", "Y", raw.y)] {
            let written = (text ?? "").trimmingCharacters(in: .whitespaces)
            let value = key == "X" ? m.frame.x : m.frame.y
            let meaning = geometryMeaning(written, key: key, of: m, skin: skin)
            if meaning != nil || written.hasPrefix("(") || written.contains("#") { relative = true }
            var row = StudioPage.Row(label: StudioText[key == "X" ? .rowX : .rowY], control: .number(.init(
                text: written.isEmpty ? "0" : written, value: value, defaultText: "0",
                width: meaning == nil ? nil : 96, meaning: meaning)))
            row.detail = showsIniNames ? key : nil
            items.append(.init(id: id, kind: .row(row)))
            rows[id] = StudioPartRow(key: key, kind: .geometry, name: StudioText[.undoPosition],
                                     title: StudioText[.undoPosition], section: "layout")
        }
        let w = (raw.w ?? "").trimmingCharacters(in: .whitespaces), h = (raw.h ?? "").trimmingCharacters(in: .whitespaces)
        var size = StudioPage.Row(label: StudioText[.rowSize], control: .pair([
            .number(.init(text: w, value: m.frame.width, prefix: StudioText[.widthPrefix], placeholder: StudioText[.fit],
                          defaultText: "")),
            .number(.init(text: h, value: m.frame.height, prefix: StudioText[.heightPrefix], placeholder: StudioText[.fit],
                          defaultText: "")),
        ]))
        size.detail = showsIniNames ? "W · H" : nil
        items.append(.init(id: "layout.size", kind: .row(size)))
        rows["layout.size"] = StudioPartRow(key: "W", kind: .geometry, name: StudioText[.undoPartSize],
                                           title: StudioText[.rowSize], section: "layout")
        if relative {
            items.append(.init(id: "layout.notation", kind: .note(.init(text: StudioText[.dragKeepsNotation],
                                                                          symbol: "arrow.left.and.right"))))
        }
        return StudioPage.Section(id: "layout", title: StudioText[.sectionLayout], items: items)
    }

    /// What a relative position means: "after “23%”" (`R`: after the part before it), "level with “CPU”" (`r`).
    func geometryMeaning(_ written: String, key: String, of m: Meter, skin: Skin) -> String? {
        guard let last = written.last, last == "r" || last == "R",
              let i = skin.meters.firstIndex(where: { $0 === m }), i > 0 else { return nil }
        let before = skin.meters[i - 1]
        let name = nowValue(before).map { LayerNaming.quoted($0, limit: 16).trimmingCharacters(in: CharacterSet(charactersIn: "“”")) }
            ?? partTitle(before, skin: skin)
        if last == "R" { return StudioText.format(key == "X" ? .afterPart : .belowPart, name) }
        return StudioText.format(.withPart, name)
    }

    /// An action written as one variable (`#OpenAction#`) is summed up as what the variable says.
    static func resolvedAction(_ action: String, skin: Skin) -> String {
        guard let name = WriteScopes.soleVariable(action), let value = skin.variable(name), !value.isEmpty else {
            return action
        }
        return value
    }

    func clickSection(_ m: Meter, skin: Skin) -> StudioPage.Section {
        let action = (m.fileOption("LeftMouseUpAction") ?? "").trimmingCharacters(in: .whitespaces)
        let sentence = action.isEmpty ? StudioText[.clickNothing]
            : ActionSummary.sentence(for: Self.resolvedAction(action, skin: skin), section: m.name, in: skin)
                .map(StudioWords.action) ?? StudioText[.clickNothing]
        var menu = [StudioPage.MenuItem(title: sentence)]
        if !action.isEmpty { menu.append(.init(title: StudioText[.clickRemove])) }
        var row = StudioPage.Row(label: "", control: .popup(.init(items: menu, selected: 0,
                                                                  symbol: "arrow.up.forward.app")))
        row.labelWidth = 0
        row.detail = showsIniNames ? "LeftMouseUpAction" : nil
        rows["clicks.action"] = StudioPartRow(key: "LeftMouseUpAction", kind: .action, name: StudioText[.undoClick],
                                             title: StudioText[.sectionClicked], section: "clicks")
        return StudioPage.Section(id: "clicks", title: StudioText[.sectionClicked],
                                  items: [.init(id: "clicks.action", kind: .row(row))])
    }

    // MARK: Every Setting

    func buildEverySetting(_ m: Meter, skin: Skin) -> StudioPage {
        rows = [:]
        let kind = StudioPartKind(m)
        let all = StudioEverySetting.groups(meter: m)
        let groups = filter.isEmpty ? all : StudioEverySetting.groups(meter: m, filter: filter)
        var subtitle: [String] = []
        if let now = nowValue(m) { subtitle.append(StudioText.format(.nowValue, now)) }
        subtitle.append(StudioText.format(.everySettingCount, StudioEverySetting.count(all)))
        var page = StudioPage(id: "every:\(m.name)", title: partTitle(m, skin: skin),
                              subtitle: subtitle.joined(separator: " · "))
        page.crumbs = [window.widgetName]
        page.scope = scopeSentence(m, kind: kind)
        page.filter = .init(placeholder: StudioText[.filterPlaceholder], text: filter)
        for g in groups {
            var items: [StudioPage.Item] = []
            if g.section == .box, filter.isEmpty {
                items.append(.init(id: "every.box", kind: .box(boxDiagram(m))))
            }
            for row in g.rows {
                let id = "every:\(row.key)"
                items.append(.init(id: id, kind: .dense(denseRow(row, m: m, skin: skin, id: id))))
            }
            if g.section == .spoken, filter.isEmpty { continue }
            let trailing: StudioPage.Trailing? = g.section == .box ? .note(StudioText[.boxOrder]) : nil
            page.sections.append(StudioPage.Section(id: "every.\(g.section.rawValue)", title: Self.everyTitle(g.section),
                                                    trailing: trailing, items: items, dense: true))
        }
        if filter.isEmpty {
            let spoken = "“\(partTitle(m, skin: skin))\(nowValue(m).map { ", \($0)" } ?? "")”"
            page.sections.append(StudioPage.Section(id: "every.spoken", title: Self.everyTitle(.spoken), items: [
                .init(id: "every.voiceover", kind: .dense(.init(label: StudioText[.voiceOver], control: .text(spoken)))),
            ], dense: true))
        }
        page.footer = [StudioPage.Link(id: "show-in-code", title: StudioText[.showInCode], detail: "⌥⌘↩",
                                       symbol: "chevron.left.forwardslash.chevron.right")]
        insertConfirmation(&page)
        return page
    }

    static func everyTitle(_ s: StudioEverySetting.Section) -> String {
        StudioText.language == .chinese ? s.title.zh : s.title.en
    }

    func boxDiagram(_ m: Meter) -> StudioPage.Box {
        let box = StudioEverySetting.box(m)
        let none = StudioText[.boxNone]
        func insets(_ i: SkinInsets) -> String {
            if i.left == i.top, i.top == i.right, i.right == i.bottom { return GeometryEdit.format(i.left) }
            return [i.left, i.top, i.right, i.bottom].map(GeometryEdit.format).joined(separator: ",")
        }
        let border: String
        switch box.border {
        case 1: border = StudioText[.boxRaised]
        case 2: border = StudioText[.boxSunken]
        default: border = none
        }
        return StudioPage.Box(
            margin: StudioText.format(.boxMargin, "0"),
            shadow: StudioText.format(.boxShadow, box.shadow.map { StudioWords.color(LayerNaming.colorName($0)) } ?? none),
            background: StudioText.format(.boxBackground, box.background.map { StudioWords.color(LayerNaming.colorName($0)) }
                                            ?? none),
            border: StudioText.format(.boxBorder, border),
            padding: StudioText.format(.boxPadding, insets(box.padding)),
            content: nowValue(m) ?? partTitle(m, skin: m.skin))
    }

    /// One row of Every Setting: its control by what the option is.
    func denseRow(_ row: StudioEverySetting.Row, m: Meter, skin: Skin, id: String) -> StudioPage.Dense {
        let chinese = StudioText.language == .chinese
        let field = row.item.field
        let p = row.item.property
        let label = field.label(chinese: chinese)
        var note: String?
        switch row.via {
        case .rainmeter(let name)?: note = StudioText.format(.filterViaRainmeter, label, name)
        case .alias(let word)?: note = StudioText.format(.filterViaAlias, label, word)
        default: break
        }
        let written = (row.written ?? "").trimmingCharacters(in: .whitespaces)
        let value = row.value.trimmingCharacters(in: .whitespaces)
        var control: StudioPage.Control = .text(written.isEmpty ? value : written)
        // The data a part shows, by its name (never the section's).
        if p.key.lowercased().hasPrefix("measurename") {
            let names = written.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let words = names.compactMap { skin.measure(named: $0) }.map { measure -> String in
                let source = ["string", "calc", "script"].contains(measure.type)
                    ? (LayerNaming.formulaSource(measure, in: skin) ?? StudioPartNames.referencedData(measure, in: skin) ?? measure) : measure
                return StudioWords.data(StudioWidgetFacts.dataName(source, in: skin).name)
            }
            return StudioPage.Dense(label: label, control: .text(words.isEmpty ? StudioText[.boxNone] : words.joined(separator: ", ")),
                                    note: note, tooltip: "Rainmeter: \(p.key)")
        }
        let tooltip = "Rainmeter: \(p.key)"
        let rowSpec = { (kind: StudioPartRow.Kind) in
            self.rows[id] = StudioPartRow(key: p.key, kind: kind, name: StudioText.format(.undoSetting, label), title: label,
                                          section: self.everySection(p.key))
        }
        switch p.kind {
        case .number, .percent255, .angle:
            if p.key.caseInsensitiveCompare("FontSize") == .orderedSame, let s = m as? StringMeter {
                let pt = TextStyle.pixelSize(points: s.style.fontSize)
                control = .number(.init(text: StudioNumberInput.text((pt * 2).rounded() / 2), value: pt,
                                        unit: chinese ? "点" : "pt", width: 70))
                rowSpec(.fontSize)
            } else {
                control = .number(.init(text: written, value: Double(value), placeholder: value, width: 70))
                rowSpec(.number(minimum: nil, maximum: nil))
            }
        case .formula where ["x", "y", "w", "h"].contains(p.key.lowercased()):
            control = .number(.init(text: written, value: nil, placeholder: p.key == "W" || p.key == "H" ? StudioText[.fit] : "0",
                                    width: 84))
            rowSpec(.geometry)
        case .choice(let choices, _):
            let values = choices.map(\.value)
            let schemaTitle = { (c: EditorSchema.Choice) in chinese ? StudioSchemaChinese.choice(c.title) ?? c.title : c.title }
            let titles = field.presets.isEmpty ? choices.map(schemaTitle)
                : choices.map { c in field.presets.first { $0.value.caseInsensitiveCompare(c.value) == .orderedSame }
                    .map { chinese ? $0.zh : $0.en } ?? schemaTitle(c) }
            let selected = EditorSchema.choice(for: value, in: choices).flatMap { c in values.firstIndex(of: c.value) }
            // Segments while every title fits its 62 pt (measured: a Chinese character is about twice a letter).
            let fits = titles.allSatisfy { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width <= 58 }
            if choices.count <= 3, fits {
                control = .segmented(.init(items: titles, selected: selected ?? -1, width: CGFloat(62 * choices.count)))
            } else {
                control = .popup(.init(items: titles.map { StudioPage.MenuItem(title: $0) }, selected: selected,
                                       width: 150))
            }
            rowSpec(.choice(values))
        case .bool:
            control = .toggle(OptionValue.bool(value) ?? false)
            rowSpec(.toggle)
        case .color:
            let c = color(p.key, of: m)
            let swatch = StudioPage.Swatch(id: id, kind: .color, color: c?.color ?? RGBA(r: 0, g: 0, b: 0, a: 0),
                                           label: label, active: activeSwatch == id)
            control = .colorLabel(.init(swatch: swatch, title: c.map { StudioWords.color(LayerNaming.colorName($0.color)) }
                                            ?? StudioText[.boxNone],
                                        note: showsIniNames && !written.isEmpty ? written : nil))
            rowSpec(.text)
        case .font:
            let faces = self.faces(current: value, skin: skin)
            control = .popup(.init(items: faces.map { StudioPage.MenuItem(title: StudioFontMenu.title($0), face: $0) },
                                   selected: 0, fonts: true, width: 150))
            rowSpec(.fonts(faces))
        case .action:
            let sentence = written.isEmpty ? StudioText[.clickNothing]
                : ActionSummary.sentence(for: Self.resolvedAction(written, skin: skin), section: m.name, in: skin)
                    .map(StudioWords.action) ?? written
            control = .text(sentence)
        case .text, .formula, .styleList, .sectionRef, .format, .image, .insets, .alignment9, .shapes:
            if case .alignment9 = p.kind {
                let title = EditorSchema.alignmentChoice(for: value).title
                control = .text(chinese ? StudioSchemaChinese.choice(title) ?? title : title)
            } else {
                control = .number(.init(text: written, value: nil, placeholder: value, isText: true))
                rowSpec(.text)
            }
        }
        return StudioPage.Dense(label: label, control: control, note: note, scrubbing: scrubbingItem == id,
                                tooltip: tooltip)
    }

    // MARK: A data item's page

    func buildData(_ measure: Measure, skin: Skin) -> StudioPage {
        rows = [:]
        let name = StudioWords.data(StudioWidgetFacts.dataName(measure, in: skin).name)
        var subtitle = [StudioText[.dataLive]]
        let value = StudioWidgetPage.liveValue(measure, skin: skin)
        subtitle.insert(StudioText.format(.nowValue, value), at: 0)
        var page = StudioPage(id: "data:\(measure.name)", title: name, subtitle: subtitle.joined(separator: " · "))
        page.crumbs = [window.widgetName]
        // Who uses it: every part that shows it (pointing at one outlines it on the canvas).
        let users = dataUsers(measure, skin: skin)
        var items: [StudioPage.Item] = users.map { m in
            .init(id: "used:\(m.name)", kind: .link(.init(id: "used:\(m.name)", title: partTitle(m, skin: skin),
                                                         detail: nowValue(m) ?? "", symbol: LayerNaming.layer(m, in: skin).symbol)))
        }
        if items.isEmpty {
            items.append(.init(id: "used.none", kind: .note(.init(text: StudioText[.dataNotUsed], symbol: "circle.dashed"))))
        }
        page.sections.append(StudioPage.Section(id: "used", title: StudioText[.dataUsedBy], items: items))
        for g in StudioEverySetting.groups(measure: measure, filter: filter) {
            let rowsItems = g.rows.map { row -> StudioPage.Item in
                let written = (row.written ?? "").trimmingCharacters(in: .whitespaces)
                let label = row.item.field.label(chinese: StudioText.language == .chinese)
                return .init(id: "every:\(row.key)", kind: .dense(.init(
                    label: label, control: .text(written.isEmpty ? row.value : written), note: nil,
                    tooltip: "Rainmeter: \(row.key)")))
            }
            page.sections.append(StudioPage.Section(id: "every.\(g.section.rawValue)", title: StudioText[.everySetting],
                                                    items: rowsItems, dense: true))
        }
        page.footer = [StudioPage.Link(id: "show-in-code", title: StudioText[.showInCode], detail: "⌥⌘↩",
                                       symbol: "chevron.left.forwardslash.chevron.right")]
        return page
    }

    /// The parts that show a data item (directly, or through a text or formula built from it).
    func dataUsers(_ measure: Measure, skin: Skin) -> [Meter] {
        skin.meters.filter { m in
            m.measures.contains { $0 === measure }
                || m.measures.contains { b in LayerNaming.formulaSource(b, in: skin) === measure }
        }
    }
}
