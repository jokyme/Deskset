import AppKit
import DesksetCore

/// How the Studio names a part everywhere it shows one — the Layers list, the canvas's tags, the part's page, the
/// accessibility elements: a part that shows live data by that data ("CPU usage", its bar "CPU bar"), a static text by
/// its words in quotes (“NOCTURNE”), anything else as `LayerNaming` names it.
enum StudioPartNames {
    /// The live data a part shows (through a formula or a text built from it, to the data it comes from).
    static func liveMeasure(_ m: Meter, in skin: Skin) -> Measure? {
        guard let bound = m.measures.first else { return nil }
        if ["string", "calc", "script"].contains(bound.type) {
            return LayerNaming.formulaSource(bound, in: skin) ?? referencedData(bound, in: skin) ?? bound
        }
        return bound
    }

    /// The first live data a text built from others names (`String=#Ready#|[MeasureCPU:0]` → MeasureCPU).
    static func referencedData(_ measure: Measure, in skin: Skin) -> Measure? {
        for key in ["String", "Formula"] {
            guard let text = measure.fileOption(key) else { continue }
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "[") {
                rest = rest[rest.index(after: open)...]
                let name = rest.prefix { $0 != "]" && $0 != ":" && $0 != "[" }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "&"))
                if let found = skin.measure(named: name), found !== measure,
                   !["string", "calc", "script"].contains(found.type) { return found }
            }
        }
        return nil
    }

    /// The data a shape draws from (a ring's arc that reads `[MeasureCPUAngle:]`, followed to the CPU's usage).
    static func shapeData(_ m: Meter, in skin: Skin) -> Measure? {
        guard m.type == "shape", m.measures.isEmpty else { return nil }
        for i in 1...9 {
            guard let text = m.rawOption(i == 1 ? "Shape" : "Shape\(i)") else { continue }
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "[") {
                rest = rest[rest.index(after: open)...]
                let name = rest.prefix { $0 != "]" && $0 != ":" && $0 != "[" }.trimmingCharacters(in: CharacterSet(charactersIn: "&"))
                guard let found = skin.measure(named: name) else { continue }
                if ["string", "calc", "script"].contains(found.type) {
                    return LayerNaming.formulaSource(found, in: skin) ?? referencedData(found, in: skin) ?? found
                }
                return found
            }
        }
        return nil
    }

    /// The data a part shows: what it names (`MeasureName`), else what its shapes read.
    static func shownData(_ m: Meter, in skin: Skin) -> Measure? {
        liveMeasure(m, in: skin) ?? shapeData(m, in: skin)
    }

    /// A shape that draws data is a ring when it has an arc or a circle, else a bar.
    static func shapeKind(_ m: Meter) -> StudioPartKind {
        let text = (1...9).compactMap { m.rawOption($0 == 1 ? "Shape" : "Shape\($0)") }.joined(separator: " ").lowercased()
        return text.contains("arc") || text.contains("ellipse") ? .ring : .bar
    }

    /// The part's name.
    static func title(_ m: Meter, in skin: Skin, names: LayerNameCatalog? = nil) -> String {
        var kind = StudioPartKind(m)
        if kind == .shape, let data = shapeData(m, in: skin) {
            kind = shapeKind(m)
            let n = StudioWidgetFacts.dataName(data, in: skin, names: names)
            return StudioWords.title(short: n.short, kind: kind.rawValue)
        }
        if let data = liveMeasure(m, in: skin) {
            let n = StudioWidgetFacts.dataName(data, in: skin, names: names)
            switch kind {
            case .bar, .ring, .graph: return StudioWords.title(short: n.short, kind: kind.rawValue)
            default: return StudioWords.data(n.name)
            }
        }
        if kind == .text, let s = m as? StringMeter {
            let words = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { return LayerNaming.quoted(words) }
        }
        if kind == .symbol, let image = m.fileOption("ImageName") {
            let symbol = image.trimmingCharacters(in: .whitespaces).dropFirst(3)
            if !symbol.isEmpty, !symbol.contains("%"), !symbol.contains("[") {
                return StudioSymbolIndex.name(of: String(symbol), chinese: StudioText.language == .chinese)
            }
        }
        return (names?.layer(m.name) ?? LayerNaming.layer(m, in: skin)).title
    }

    /// A data item's everyday name: a formula or text built from other data is named after that data ("GPU usage" for
    /// a Calc of the GPU's usage).
    static func dataName(_ measure: Measure, in skin: Skin, names: LayerNameCatalog? = nil) -> String {
        var m = measure
        if ["calc", "string", "script"].contains(m.type),
           let source = LayerNaming.formulaSource(m, in: skin) ?? referencedData(m, in: skin) { m = source }
        return StudioWords.data(StudioWidgetFacts.dataName(m, in: skin, names: names).name)
    }

    /// Whether a text is drawn as a button: it has no data and a click of its own.
    static func isButton(_ m: Meter) -> Bool {
        guard m.type == "string" || m.type == "button", m.measures.isEmpty else { return m.type == "button" }
        return !m.actionOption("LeftMouseUpAction").isEmpty || !m.actionOption("LeftMouseDownAction").isEmpty
    }

    /// The symbol of a part's kind in the list ("textformat" for a text, a bar's bars).
    static func glyph(_ m: Meter, in skin: Skin? = nil) -> String {
        if isButton(m) { return "button.horizontal" }
        var kind = StudioPartKind(m)
        if kind == .shape, let skin, shapeData(m, in: skin) != nil { kind = shapeKind(m) }
        switch kind {
        case .number, .text: return "textformat"
        case .symbol: return "star"
        case .picture: return "photo"
        case .bar: return "rectangle.split.3x1"
        case .ring: return "circle.dashed"
        case .graph: return "chart.xyaxis.line"
        case .shape: return "square.on.circle"
        case .part: return "square.dashed"
        }
    }

    /// The kind as a word for a screen reader ("text", "bar").
    static func role(_ m: Meter) -> String {
        if isButton(m) { return StudioText[.roleButton] }
        return StudioPartKind(m).noun()
    }

    /// The live value a part shows now, for its data chip: a text's words ("23%", "22:41"), else its data's value.
    static func value(_ m: Meter, data: Measure, in skin: Skin) -> String {
        if let s = m as? StringMeter {
            let t = LayerNaming.quoted(s.text, limit: 14)
            return String(t.dropFirst().dropLast())
        }
        return StudioWidgetPage.liveValue(data, skin: skin)
    }

    /// What needs attention in a part, in a sentence (nil: nothing).
    static func issueSentence(_ issues: [StudioPartIssue], in skin: Skin, names: LayerNameCatalog? = nil) -> String? {
        guard let first = issues.first else { return nil }
        switch first {
        case .windowsData(let measure, let plugin):
            let name = skin.measure(named: measure).map {
                StudioWords.data(StudioWidgetFacts.dataName($0, in: skin, names: names).name)
            } ?? measure
            if let plugin { return StudioText.format(.issueWindowsPlugin, name, plugin) }
            return StudioText.format(.issueWindowsData, name)
        case .windowsProgram:
            return StudioText.format(.issueWindowsProgram, first.programName ?? "")
        }
    }
}

/// A row of the Layers list: the widget (the list's root), one of its parts, or one of its data items (the group at
/// the bottom).
struct StudioLayerItem: Equatable {
    enum Kind: Equatable { case widget, part, data }

    var id: String
    var kind: Kind
    /// The section's name (the widget: "").
    var name: String
    var title: String
    /// Under the title: the meter's name (Rainmeter details on), a data item's everyday name.
    var subtitle: String?
    /// Quiet words at the right ("free layout").
    var word: String?
    var glyph: String
    /// The data chip: its symbol and the live value.
    var chip: (symbol: String, text: String)?
    /// What needs attention (the amber dot), in a sentence.
    var issue: String?
    var hidden = false
    var locked = false
    /// A data item's live value.
    var value: String?
    /// What a screen reader says ("CPU usage, 23%, text").
    var accessibility: String

    static func == (a: StudioLayerItem, b: StudioLayerItem) -> Bool {
        a.id == b.id && a.kind == b.kind && a.name == b.name && a.title == b.title && a.subtitle == b.subtitle
            && a.word == b.word && a.glyph == b.glyph && a.chip?.symbol == b.chip?.symbol && a.chip?.text == b.chip?.text
            && a.issue == b.issue && a.hidden == b.hidden && a.locked == b.locked && a.value == b.value
            && a.accessibility == b.accessibility
    }
}

/// The Layers list of an INI widget, worked out from the Studio's instance: flat (an INI widget places every part
/// freely), the widget's row first ("Nocturne · free layout"), its parts in file order (back to front), then its data
/// ("Measures" with Rainmeter details on, else "Data").
enum StudioLayersModel {
    struct Lists: Equatable {
        var widget: StudioLayerItem
        var parts: [StudioLayerItem]
        var data: [StudioLayerItem]
    }

    static func lists(skin: Skin, widgetName: String, details: Bool, filter: String = "",
                      locked: Set<String> = []) -> Lists {
        LayerNaming.sharingWork(for: skin) {
            let names = LayerNaming.catalog(of: skin)
            let widget = StudioLayerItem(id: "widget", kind: .widget, name: "", title: widgetName, subtitle: nil,
                                         word: StudioText[.freeLayout], glyph: "square.dashed",
                                         accessibility: StudioText.format(.axWidget, widgetName))
            var parts: [StudioLayerItem] = []
            for m in skin.meters {
                parts.append(part(m, skin: skin, names: names, details: details, locked: locked))
            }
            var data: [StudioLayerItem] = []
            for measure in skin.measures {
                data.append(dataItem(measure, skin: skin, names: names, details: details))
            }
            let f = filter.trimmingCharacters(in: .whitespaces)
            if !f.isEmpty {
                parts = parts.filter { matches($0, f) }
                data = data.filter { matches($0, f) }
            }
            return Lists(widget: widget, parts: parts, data: data)
        }
    }

    static func part(_ m: Meter, skin: Skin, names: LayerNameCatalog, details: Bool, locked: Set<String>)
        -> StudioLayerItem {
        let title = StudioPartNames.title(m, in: skin, names: names)
        let issues = StudioPartIssues.issues(of: m, in: skin)
        let issue = StudioPartNames.issueSentence(issues, in: skin, names: names)
        var chip: (symbol: String, text: String)?
        let data = StudioPartNames.shownData(m, in: skin)
        if let data, !issues.contains(where: { if case .windowsData = $0 { return true } else { return false } }) {
            let text = StudioPartNames.value(m, data: data, in: skin)
            if !text.isEmpty { chip = (StudioWords.symbol(data), text) }
        }
        var words = [title]
        if let chip { words.append(chip.text) }
        words.append(StudioPartNames.role(m))
        if m.hidden { words.append(StudioText[.axHidden]) }
        if let issue { words.append(issue) }
        return StudioLayerItem(id: "part:\(m.name)", kind: .part, name: m.name, title: title,
                               subtitle: details ? m.name : nil, word: nil, glyph: StudioPartNames.glyph(m, in: skin), chip: chip,
                               issue: issue, hidden: m.hidden, locked: locked.contains(m.name.lowercased()), value: nil,
                               accessibility: words.joined(separator: ", "))
    }

    static func dataItem(_ measure: Measure, skin: Skin, names: LayerNameCatalog, details: Bool) -> StudioLayerItem {
        var plain = StudioPartNames.dataName(measure, in: skin, names: names)
        if case .windowsData(_, let plugin?)? = StudioPartIssues.issue(of: measure, in: skin) {
            plain += " · " + plugin
        }
        let value = StudioWidgetPage.liveValue(measure, skin: skin)
        return StudioLayerItem(id: "data:\(measure.name)", kind: .data, name: measure.name,
                               title: details ? measure.name : plain, subtitle: details ? plain : nil, word: nil,
                               glyph: "dot.radiowaves.left.and.right", chip: nil, issue: nil, value: value,
                               accessibility: [details ? measure.name : nil, plain, value].compactMap { $0 }
                                   .joined(separator: ", "))
    }

    /// Whether `item` is found by `filter`: its name, the meter's or measure's name, its data, its value — each word of
    /// the filter somewhere in them, ignoring case and accents.
    static func matches(_ item: StudioLayerItem, _ filter: String) -> Bool {
        let haystack = fold([item.title, item.name, item.subtitle ?? "", item.chip?.text ?? "", item.value ?? ""]
            .joined(separator: " "))
        return filter.split(whereSeparator: { $0.isWhitespace }).allSatisfy { haystack.contains(fold(String($0))) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The parts that show a data item (directly, or through a text or formula built from it).
    static func users(of measure: Measure, in skin: Skin) -> [Meter] {
        skin.meters.filter { m in
            m.measures.contains { $0 === measure }
                || m.measures.contains { b in LayerNaming.formulaSource(b, in: skin) === measure }
        }
    }
}
