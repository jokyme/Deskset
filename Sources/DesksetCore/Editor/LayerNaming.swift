import Foundation

/// What a layer is called wherever the editor names it: its row in the layer list, its tag on the canvas, the
/// inspector's identity strip, breadcrumbs, toasts and undo names (docs/editor-friendly.md §6.1).
public struct LayerName: Equatable {
    /// "“Audio”", "Left channel bar", "16 bars".
    public var title: String
    /// Its kind, and what it shows: "Text · lowest band frequency".
    public var subtitle: String
    /// One sentence for the identity strip: "Text that says “Audio”."
    public var sentence: String
    /// An SF Symbol for its kind.
    public var symbol: String

    public init(title: String, subtitle: String, sentence: String, symbol: String) {
        self.title = title
        self.subtitle = subtitle
        self.sentence = sentence
        self.symbol = symbol
    }
}

/// What a live data item (a measure) is called (docs/editor-friendly.md §6.2).
public struct DataName: Equatable {
    /// "Sound band 6", "CPU usage".
    public var name: String
    /// The short form used inside other names: "Band 6" ("Band 6 bar"), "CPU" ("CPU graph").
    public var short: String
    /// A second line for the Live Data list ("What your Mac plays"); empty: none.
    public var subtitle: String

    public init(name: String, short: String, subtitle: String) {
        self.name = name
        self.short = short
        self.subtitle = subtitle
    }
}

/// Who uses a live data item: the layers that show it, place themselves by it or act on it (`[!CommandMeasure …]` in
/// a click action), and the data built on it or acting on it (formulas, the children of a `Parent=`, `IfTrueAction`),
/// each in file order; whether the widget's own actions or variables name it; and whether it runs actions of its own.
public struct DataUsers: Equatable {
    public var layers: [String]
    public var data: [String]
    /// The widget's own actions or variables name it (`[Rainmeter] OnRefreshAction=[!EnableMeasure …]`).
    public var widget: Bool
    /// It runs actions of its own when it updates (`IfTrueAction`, `OnChangeAction`, `OnUpdateAction`…), so it does
    /// something even when nothing names it.
    public var runsActions: Bool

    public init(layers: [String] = [], data: [String] = [], widget: Bool = false, runsActions: Bool = false) {
        self.layers = layers
        self.data = data
        self.widget = widget
        self.runsActions = runsActions
    }

    /// Nothing uses it and it does nothing by itself: deleting it changes nothing the widget shows or does.
    public var isEmpty: Bool { layers.isEmpty && data.isEmpty && !widget && !runsActions }
}

/// Every name of a skin at once, for lists that name everything (the sidebar names all rows on each refresh).
public struct LayerNameCatalog {
    /// The runs of repeated layers and data (`LayerSeries.detect`).
    public let series: [Series]
    /// The layer the editor calls "Background" (`LayerNaming.background(in:)`).
    public let background: String?
    private let layers: [String: LayerName]
    private let data: [String: DataName]
    private let seriesNames: [String: LayerName]
    private let dataSeriesNames: [String: DataName]
    private let users: [String: DataUsers]

    init(namer: LayerNamer) {
        let skin = namer.skin
        series = namer.series
        background = namer.background
        var layers: [String: LayerName] = [:]
        for m in skin.meters { layers[m.name.lowercased()] = namer.layer(m) }
        var data: [String: DataName] = [:]
        var users: [String: DataUsers] = [:]
        for m in skin.measures {
            data[m.name.lowercased()] = namer.data(m)
            users[m.name.lowercased()] = namer.references.users(of: m.name)
        }
        var seriesNames: [String: LayerName] = [:]
        var dataSeriesNames: [String: DataName] = [:]
        for s in namer.series {
            guard let first = s.members.first?.lowercased() else { continue }
            switch s.kind {
            case .layers: seriesNames[first] = namer.seriesName(s)
            case .data: dataSeriesNames[first] = namer.dataSeriesName(s)
            }
        }
        self.layers = layers
        self.data = data
        self.seriesNames = seriesNames
        self.dataSeriesNames = dataSeriesNames
        self.users = users
    }

    /// The name of the layer `section`.
    public func layer(_ section: String) -> LayerName? { layers[section.lowercased()] }

    /// The name of the live data item `section`.
    public func data(_ section: String) -> DataName? { data[section.lowercased()] }

    /// The name of a run of layers ("16 bars").
    public func name(of series: Series) -> LayerName? {
        series.kind == .layers ? series.members.first.flatMap { seriesNames[$0.lowercased()] } : nil
    }

    /// The name of a run of data ("16 sound bands").
    public func dataName(of series: Series) -> DataName? {
        series.kind == .data ? series.members.first.flatMap { dataSeriesNames[$0.lowercased()] } : nil
    }

    /// The run `section` belongs to.
    public func series(containing section: String) -> Series? {
        series.first { $0.contains(section) }
    }

    /// Who uses the live data item `section`.
    public func users(ofData section: String) -> DataUsers { users[section.lowercased()] ?? DataUsers() }
}

/// Names for layers and live data taken from what they are and show, never the section name, which stays the
/// identity for code, errors and selection (docs/editor-friendly.md §6).
public enum LayerNaming {
    // MARK: One namer for a piece of work

    /// The namer that every naming call for its skin uses while `sharingWork` runs (main thread only).
    private static var shared: LayerNamer?

    /// Runs `body` with every naming call for `skin` sharing one namer, so what naming needs — the runs of repeated
    /// sections, who references whom, each data item's own name — is worked out once instead of at every call: a
    /// Shows menu names every data item, and each name looks at all of them. Only for work during which the skin does
    /// not change, such as building one part of an inspector page. A nested call for the same skin shares the outer
    /// namer. Off the main thread, `body` simply runs.
    public static func sharingWork<T>(for skin: Skin, _ body: () throws -> T) rethrows -> T {
        guard Thread.isMainThread, shared?.skin !== skin else { return try body() }
        let saved = shared
        shared = LayerNamer(skin: skin)
        defer { shared = saved }
        return try body()
    }

    /// The shared namer for `skin` inside `sharingWork`, else a new one.
    static func namer(for skin: Skin) -> LayerNamer {
        if Thread.isMainThread, let shared, shared.skin === skin { return shared }
        return LayerNamer(skin: skin)
    }

    /// The name of a layer.
    public static func layer(_ m: Meter, in skin: Skin) -> LayerName {
        namer(for: skin).layer(m)
    }

    /// The name of a live data item.
    public static func data(_ m: Measure, in skin: Skin) -> DataName {
        namer(for: skin).data(m)
    }

    /// The name of a run of layers ("16 bars") or data ("16 sound bands", as a layer name with its kind).
    public static func series(_ s: Series, in skin: Skin) -> LayerName {
        let shared = namer(for: skin)
        if s.kind == .layers { return shared.seriesName(s) }
        let d = shared.dataSeriesName(s)
        return LayerName(title: d.name, subtitle: d.subtitle, sentence: "\(d.name).", symbol: "waveform.path.ecg")
    }

    /// The name of a run of data: "16 sound bands" (short "Sound bands").
    public static func dataSeries(_ s: Series, in skin: Skin) -> DataName {
        namer(for: skin).dataSeriesName(s)
    }

    /// Every name of the skin at once.
    public static func catalog(of skin: Skin) -> LayerNameCatalog {
        LayerNameCatalog(namer: namer(for: skin))
    }

    /// The layer drawn first when it is a Shape or a Picture (an Image meter) that covers at least 90% of the widget:
    /// the editor calls it "Background" and locks it (§5.2); nil when there is none.
    public static func background(in skin: Skin) -> String? {
        let w = skin.width, h = skin.height
        guard w > 0, h > 0, w.isFinite, h.isFinite,
              let first = skin.meters.first(where: { !$0.hidden && $0.container == nil }),
              ["shape", "image"].contains(first.type.lowercased()) else { return nil }
        let f = first.frame
        let covered = max(0, min(f.maxX, w) - max(f.x, 0)) * max(0, min(f.maxY, h) - max(f.y, 0))
        return covered >= 0.9 * w * h ? first.name : nil
    }

    /// Who uses the live data item `name` (layers that show it, place themselves by it or act on it; data built on
    /// it or acting on it; the widget's own actions), and whether it runs actions of its own.
    public static func users(ofData name: String, in skin: Skin) -> DataUsers {
        namer(for: skin).references.users(of: name)
    }

    /// What a formula is calculated from: the first live data it names, through other formulas to data that is not
    /// one (the peak marker's position is calculated from the peak level); nil when it names none.
    public static func formulaSource(_ m: Measure, in skin: Skin) -> Measure? {
        let shared = namer(for: skin)
        return shared.formulaReferences(m).first.map { shared.underlying($0, depth: 0) }
    }

    /// The live data a layer's position follows (`X=[MeasurePeakX]`), through formulas to the data they are
    /// calculated from (the Peak marker follows the peak level, not the formula placing it); nil when it has none.
    public static func followedData(of m: Meter, in skin: Skin) -> Measure? {
        namer(for: skin).followedData(of: m)
    }

    /// Whether a gauge or dial with no data still draws something on purpose (a clock face, rim or tick: `Solid=1`,
    /// a line, a picture): it isn't waiting for data.
    public static func drawsWithoutData(_ m: Meter) -> Bool { LayerNamer.drawsWithoutData(m) }

    /// The kind of a layer in the editor's words (§3.2): "Text", "Picture", "Color block", "Bar", "Line graph"…
    public static func kindNoun(_ m: Meter) -> String {
        switch m.type.lowercased() {
        case "string": return "Text"
        case "image":
            let file = (m.rawOption("ImageName") ?? "").trimmingCharacters(in: .whitespaces)
            let fromData = !(m.rawOption("MeasureName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            // A picture live data chooses (an album cover: `MeasureName=`, or `ImageName=%1`) is a picture too.
            return file.isEmpty && !fromData ? "Color block" : "Picture"
        case "bar": return "Bar"
        case "line": return "Line graph"
        case "histogram": return "Bar graph"
        case "roundline": return "Gauge"
        case "rotator": return "Dial"
        case "bitmap": return "Number picture"
        case "button": return "Button"
        case "shape": return "Shape"
        default: return "Layer"
        }
    }

    /// A kind in the plural, lowercased: "Bar" → "bars", "Line graph" → "line graphs".
    public static func kindPlural(_ kind: String) -> String {
        plural(kind.lowercased())
    }

    /// The word a layer's name ends with when it is named after its data: "CPU graph", "Left channel bar".
    static func titleNoun(_ m: Meter) -> String {
        switch m.type.lowercased() {
        case "bar": return "bar"
        case "line": return "graph"
        case "histogram": return "bar graph"
        case "roundline": return "gauge"
        case "rotator": return "dial"
        case "bitmap": return "number picture"
        case "image": return "picture"
        default: return kindNoun(m).lowercased()
        }
    }

    /// An SF Symbol for a meter type (the same symbols the layer list has always used).
    public static func symbol(forMeterType type: String) -> String {
        switch type.lowercased() {
        case "string": return "textformat"
        case "image", "bitmap": return "photo"
        case "button": return "hand.tap"
        case "bar": return "chart.bar.fill"
        case "histogram": return "chart.bar.xaxis"
        case "line": return "chart.xyaxis.line"
        case "roundline", "rotator": return "gauge.with.dots.needle.33percent"
        case "shape": return "square.on.circle"
        default: return "square.dashed"
        }
    }

    /// The shape a Shape layer draws, in words: "Rounded rectangle", "Rectangle", "Circle", "Line", "Path" or "Shape".
    public static func shapeKind(_ m: Meter) -> String {
        guard m.type.lowercased() == "shape" else { return kindNoun(m) }
        let keys = LayerReferences.shapeKeys(of: m)
        guard let raw = keys.first.flatMap({ m.rawOption($0) }), let spec = ShapeSpec.parse(raw) else { return "Shape" }
        switch spec.kind {
        case .rectangle:
            let radius = (spec.param(4) ?? "").trimmingCharacters(in: .whitespaces)
            return radius.isEmpty || OptionValue.number(radius) == 0 ? "Rectangle" : "Rounded rectangle"
        case .ellipse: return "Circle"
        case .line, .arc, .curve: return "Line"
        case .path, .path1: return "Path"
        case .combine: return "Shape"
        }
    }

    /// A section name as words: the customary `Meter` / `Measure` prefix dropped, camel case and digits split, the
    /// first word capitalised and the others lowercased, acronyms and single capitals kept ("MeterLeftLabel" →
    /// "Left label", "MeterCPUValue" → "CPU value", "MeasureBand5" → "Band 5", "Meter_Top_Bar" → "Top bar",
    /// "MeterPeakX" → "Peak X").
    public static func humanized(_ section: String) -> String {
        var name = section.trimmingCharacters(in: .whitespaces)
        for prefix in ["Measure", "Meter"] where name.count > prefix.count && name.hasPrefix(prefix) {
            let next = name[name.index(name.startIndex, offsetBy: prefix.count)]
            if next.isUppercase || next.isNumber || next == "_" || next == " " {
                name = String(name.dropFirst(prefix.count))
                break
            }
        }
        let words = self.words(name)
        guard !words.isEmpty else { return section }
        return sentence(words)
    }

    /// The file name of a path as written, without its folder or the variables it starts with
    /// ("#@#Images\\clock-face.png" and "#@#clock-face.png" → "clock-face.png").
    public static func fileName(_ path: String) -> String {
        let bare = path.replacingOccurrences(of: #"#[^#\s]*#"#, with: "/", options: .regularExpression)
        return bare.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// A file name as words: its folder and extension dropped, separators and camel case split
    /// ("#@#Images/clock-face.png" → "Clock face").
    public static func humanizedFile(_ path: String) -> String {
        let last = fileName(path)
        let base = (last as NSString).deletingPathExtension
        let words = self.words(base)
        return words.isEmpty ? last : sentence(words)
    }

    /// Words of an identifier: split at separators, between letters and digits, and at camel case humps.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for (i, c) in characters.enumerated() {
            if c == "_" || c == "-" || c == " " || c == "." {
                flush()
                continue
            }
            if let last = current.last {
                let next = i + 1 < characters.count ? characters[i + 1] : nil
                let startsWord = (c.isNumber != last.isNumber)
                    || (c.isUppercase && last.isLowercase)
                    // The last capital of an acronym starts the next word: "CPUValue" → "CPU", "Value".
                    || (c.isUppercase && last.isUppercase && (next?.isLowercase ?? false))
                if startsWord { flush() }
            }
            current.append(c)
        }
        flush()
        return words
    }

    /// Words as a sentence-case phrase: the first capitalised, the others lowercased, acronyms kept.
    static func sentence(_ words: [String]) -> String {
        words.enumerated().map { i, word in
            if isAcronym(word) { return word }
            return i == 0 ? word.prefix(1).uppercased() + word.dropFirst().lowercased() : word.lowercased()
        }.joined(separator: " ")
    }

    /// A word written in capitals (digits allowed): "CPU", "X", "RAM2".
    static func isAcronym(_ word: String) -> Bool {
        word.contains { $0.isLetter } && word.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// A name used inside a sentence: its first letter lowercased unless the first word is written with capitals
    /// inside it ("Lowest band frequency" → "lowest band frequency"; "CPU usage" and "Wi-Fi signal" stay).
    public static func inSentence(_ name: String) -> String {
        guard let first = name.split(separator: " ").first else { return name }
        if isAcronym(String(first)) || first.dropFirst().contains(where: { $0.isUppercase }) { return name }
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    /// Text shown as a name: on one line, trimmed, in curly quotes, cut at `limit` characters with "…".
    public static func quoted(_ text: String, limit: Int = 28) -> String {
        "“\(clipped(oneLine(text), limit: limit))”"
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func clipped(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    /// An English plural of a lowercased phrase (its last word): "bar" → "bars", "sound band" → "sound bands".
    static func plural(_ phrase: String) -> String {
        guard let last = phrase.last else { return phrase }
        if phrase.hasSuffix("s") || phrase.hasSuffix("x") || phrase.hasSuffix("ch") || phrase.hasSuffix("sh") {
            return phrase + "es"
        }
        if last == "y", let before = phrase.dropLast().last, !"aeiou".contains(before) { return phrase.dropLast() + "ies" }
        return phrase + "s"
    }

    /// A number in a name or sentence: "217", "2.5".
    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    /// A color in one plain word ("white", "blue"), from its lightness, saturation and hue.
    public static func colorName(_ c: RGBA) -> String {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let lightness = (maxC + minC) / 2
        let delta = maxC - minC
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        if c.a == 0 { return "clear" }
        if lightness > 0.9 { return "white" }
        if lightness < 0.1 { return "black" }
        if saturation < 0.15 { return lightness > 0.65 ? "light gray" : lightness < 0.3 ? "dark gray" : "gray" }
        var hue: Double
        if delta == 0 { hue = 0 } else if maxC == r { hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
        else if maxC == g { hue = 60 * ((b - r) / delta + 2) } else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15: return "red"
        case ..<45: return lightness < 0.35 ? "brown" : "orange"
        case ..<70: return "yellow"
        case ..<160: return "green"
        case ..<200: return "teal"
        case ..<255: return "blue"
        case ..<290: return "purple"
        case ..<345: return "pink"
        default: return "red"
        }
    }

    /// What a time format shows, in words, from its codes (docs/editor-friendly.md §6.2): "Hours and minutes",
    /// "Seconds", "Weekday", "Week number", "AM/PM", "Date"… Never a rendered example: a frozen moment contradicted
    /// the live value shown next to it, and the seconds and the month both read "Time (09)".
    public static func timeName(format: String) -> (name: String, short: String) {
        var codes: Set<Character> = []
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%", i + 1 < chars.count else { i += 1; continue }
            var j = i + 1
            // Flags and modifiers: `%#d` (no leading zero), `%-d`, `%Ey`, `%Od`.
            while j < chars.count, "#-_0^EO".contains(chars[j]) { j += 1 }
            guard j < chars.count else { break }
            // Codes that stand for several: %R = %H:%M, %T and %X = %H:%M:%S, %r = %I:%M:%S %p, %D and %x = %m/%d/%y,
            // %F = %Y-%m-%d, %c = date and time.
            let expanded: [Character: String] = ["R": "HM", "T": "HMS", "X": "HMS", "r": "IMSp", "D": "mdy", "x": "mdy",
                                                 "F": "Ymd", "c": "aBdHMSY"]
            if chars[j] != "%" { codes.formUnion(expanded[chars[j]].map(Array.init) ?? [chars[j]]) }
            i = j + 1
        }
        func has(_ letters: String) -> Bool { letters.contains(where: codes.contains) }
        let hour = has("HIkl"), minute = has("M"), second = has("S"), ampm = has("p")
        let twelve = has("Il")
        let weekdayName = has("aA"), weekdayNumber = has("uw"), week = has("UVW")
        let day = has("de"), dayOfYear = has("j"), month = has("m"), monthName = has("bBh"), year = has("yYCGg")
        let isTime = hour || minute || second || ampm
        let isDate = weekdayName || weekdayNumber || week || day || dayOfYear || month || monthName || year
        if isTime && isDate { return ("Date and time", "Time") }
        if isTime {
            let clock = twelve ? " (12-hour)" : ""
            if hour && minute && second { return ("Time with seconds" + clock, "Time") }
            if hour && minute { return ("Hours and minutes" + clock, "Time") }
            if minute && second { return ("Minutes and seconds", "Time") }
            if hour { return ("Hour" + clock, "Hour") }
            if minute { return ("Minutes", "Minutes") }
            if second { return ("Seconds", "Seconds") }
            return ("AM/PM", "AM/PM")
        }
        if isDate {
            let parts = [weekdayName || weekdayNumber, week, day || dayOfYear, month || monthName, year].filter { $0 }.count
            if parts == 1 {
                if weekdayName { return ("Weekday", "Weekday") }
                if weekdayNumber { return ("Weekday number", "Weekday") }
                if week { return ("Week number", "Week") }
                if dayOfYear && !day { return ("Day of the year", "Day") }
                if day { return ("Day of the month", "Day") }
                if monthName && !month { return ("Month name", "Month") }
                if month { return ("Month number", "Month") }
                return ("Year", "Year")
            }
            if parts == 2, month || monthName, year { return ("Month and year", "Month") }
            return ("Date", "Date")
        }
        if has("Zz") { return ("Time zone", "Time zone") }
        return ("Time", "Time")
    }

    /// A name without a bracketed part ("Hours and minutes (12-hour)" → "Hours and minutes").
    static func withoutBrackets(_ name: String) -> String {
        guard let open = name.firstIndex(of: "(") else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - References between sections

/// Which sections name which: `MeasureName`, section variables in any option (`X=[MeasurePeakX]`,
/// `Shape2=… [MeasureRAM:%] …`), measure names in formulas and conditions, `Parent=`, and the sections bangs act on
/// in actions (`LeftMouseUpAction=[!CommandMeasure MeasurePlayer "PlayPause"]`, `IfTrueAction=[!SetOption …]`),
/// including the widget's own actions and variables (`[Rainmeter] OnRefreshAction=…`, `[Variables]`). Built from the
/// files (the options as written, looks included), once per skin.
struct LayerReferences {
    enum Origin {
        case meter, measure
        /// `[Rainmeter]` (its actions) or `[Variables]`.
        case widget
    }

    struct Reference {
        /// The section that names the other one.
        var from: String
        var key: String
        var origin: Origin
        var fromMeter: Bool { origin == .meter }
    }

    /// Referenced section (lowercased) → who names it, in file order (meters first, then measures, then the widget).
    private(set) var references: [String: [Reference]] = [:]
    /// Data (lowercased) with actions of its own (`IfTrueAction`, `OnChangeAction`, `OnUpdateAction`…).
    private(set) var actingData: Set<String> = []
    let skin: Skin

    /// Bang parameters that name a section of the widget (`BangCatalog`): `!SetOption Meter/Measure …`,
    /// `!CommandMeasure Measure …`, `!ShowMeter Meter`, `!WriteKeyValue Section …`.
    static let sectionParameters: Set<String> = ["Meter", "Measure", "Meter/Measure", "Section"]

    init(skin: Skin) {
        self.skin = skin
        for m in skin.meters {
            for (key, value) in Self.entries(of: m) {
                let k = key.lowercased()
                if k.hasPrefix("measurename") {
                    // As written, as it resolves now, and — built from a variable (`MeasureTime#ClockHours#`) —
                    // every data item the variable could choose (`MeasureTime24`, `MeasureTime12`): all are used.
                    let raw = value.trimmingCharacters(in: .whitespaces)
                    var names = [raw, skin.resolveStandardVariables(raw, in: m).trimmingCharacters(in: .whitespaces)]
                    names += Self.measures(matching: raw, in: skin)
                    var seen: Set<String> = []
                    for name in names where seen.insert(name.lowercased()).inserted {
                        add(name, Reference(from: m.name, key: key, origin: .meter))
                    }
                } else {
                    for name in names(in: value, key: k, section: m) {
                        add(name, Reference(from: m.name, key: key, origin: .meter))
                    }
                }
            }
            // The data it is bound to while it runs (a MeasureName set by `!SetOption` or built another way).
            for bound in m.measures where !(references[bound.name.lowercased()] ?? []).contains(where: {
                $0.from.caseInsensitiveCompare(m.name) == .orderedSame
            }) {
                add(bound.name, Reference(from: m.name, key: "MeasureName", origin: .meter))
            }
        }
        for m in skin.measures {
            for (key, value) in Self.entries(of: m) {
                let k = key.lowercased()
                var found = names(in: value, key: k, section: m)
                if k == "formula" || k.hasPrefix("ifcondition") || k == "maxvalue" || k == "minvalue" {
                    found += Self.identifiers(in: value)
                }
                if k == "parent" { found.append(value.trimmingCharacters(in: .whitespaces)) }
                if Self.isAction(k), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    actingData.insert(m.name.lowercased())
                }
                var seen: Set<String> = []
                for name in found where seen.insert(name.lowercased()).inserted
                    && name.caseInsensitiveCompare(m.name) != .orderedSame {
                    add(name, Reference(from: m.name, key: key, origin: .measure))
                }
            }
        }
        // The widget's own actions (`OnRefreshAction`, mouse actions, `ContextAction`) and its variables (a variable
        // can hold an action or a section variable).
        for widget in ["Rainmeter", "Variables"] {
            for e in skin.document.section(named: widget)?.entries ?? [] {
                let k = e.key.lowercased()
                var found = Self.bracketNames(in: e.value)
                if widget == "Variables" || Self.isAction(k) { found += bangTargets(in: e.value, section: nil) }
                for name in found { add(name, Reference(from: widget, key: e.key, origin: .widget)) }
            }
        }
    }

    /// The data items a MeasureName built from variables could name: each `#Var#` stands for any text
    /// (`MeasureTime#ClockHours#` → `MeasureTime24`, `MeasureTime12`); none when it names no variable.
    static func measures(matching raw: String, in skin: Skin) -> [String] {
        let variables = SkinInspection.referencedVariables(in: raw)
        guard !variables.isEmpty else { return [] }
        var pattern = NSRegularExpression.escapedPattern(for: raw)
        for v in variables {
            pattern = pattern.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "#\(v)#"), with: ".*")
        }
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.caseInsensitive]) else { return [] }
        return skin.measures.map(\.name).filter { name in
            regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
    }

    private mutating func add(_ name: String, _ ref: Reference) {
        let key = name.lowercased()
        guard !key.isEmpty, skin.measure(named: key) != nil || skin.meter(named: key) != nil else { return }
        references[key, default: []].append(ref)
    }

    /// The sections an option's value names: section variables anywhere, and in an action what its bangs act on.
    private func names(in value: String, key: String, section: SkinSection) -> [String] {
        var names = Self.bracketNames(in: value)
        if Self.isAction(key) { names += bangTargets(in: value, section: section) }
        return names
    }

    /// Whether an option is an action (`LeftMouseUpAction`, `IfTrueAction2`, `OnChangeAction`, `ButtonCommand`…).
    static func isAction(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.contains("action") || k == "buttoncommand"
    }

    /// The sections of this widget the bangs of an action act on (`[!CommandMeasure MeasurePlayer "Next"]` →
    /// MeasurePlayer); bangs aimed at another widget (a `Config` argument) are left out.
    func bangTargets(in text: String, section: SkinSection?) -> [String] {
        guard text.contains("!") else { return [] }
        var names: [String] = []
        for action in ActionParser.parse(text) {
            guard case .bang(let bang) = action, let definition = BangCatalog.definition(for: bang.name) else { continue }
            if let config = definition.configArgument(in: bang.args),
               config.caseInsensitiveCompare(skin.config) != .orderedSame { continue }
            for (i, parameter) in definition.parameters.enumerated()
            where i < bang.args.count && Self.sectionParameters.contains(parameter.name) {
                let name = skin.resolveStandardVariables(bang.args[i], in: section).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.append(name) }
            }
        }
        return names
    }

    func references(to name: String) -> [Reference] { references[name.lowercased()] ?? [] }

    /// Who uses the live data item `name`.
    func users(of name: String) -> DataUsers {
        var users = DataUsers()
        var seen: Set<String> = []
        for r in references(to: name) where seen.insert("\(r.origin):" + r.from.lowercased()).inserted {
            switch r.origin {
            case .meter: users.layers.append(r.from)
            case .measure: users.data.append(r.from)
            case .widget: users.widget = true
            }
        }
        users.runsActions = actingData.contains(name.lowercased())
        return users
    }

    /// The options of a section as written: its own, then (for meters) those of its looks that it does not set.
    static func entries(of section: SkinSection) -> [(key: String, value: String)] {
        let skin = section.skin
        var result: [(String, String)] = []
        var seen: Set<String> = []
        func add(_ entries: [IniEntry]) {
            for e in entries where seen.insert(e.key.lowercased()).inserted { result.append((e.key, e.value)) }
        }
        add(skin.document.section(named: section.name)?.entries ?? [])
        if section is Meter {
            let looks = (section.rawOption("MeterStyle") ?? "").split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for look in looks.reversed() where !look.isEmpty {
                add(skin.document.section(named: look)?.entries ?? [])
            }
        }
        return result
    }

    /// The `Shape`, `Shape2`, … options of a Shape meter (its own or its looks'), in number order.
    static func shapeKeys(of m: Meter) -> [String] {
        let keys = entries(of: m).map(\.key).filter { key in
            let k = key.lowercased()
            guard k.hasPrefix("shape") else { return false }
            let rest = k.dropFirst(5)
            return rest.isEmpty || rest.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return keys.sorted { (Int($0.dropFirst(5)) ?? 1) < (Int($1.dropFirst(5)) ?? 1) }
    }

    /// Section names in brackets: `[Name]`, `[Name:X]`, `[&Name:…]`; not `[#Var]`, `[*Name*]`, `[\x20]`.
    static func bracketNames(in text: String) -> [String] {
        var names: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            rest = rest[rest.index(after: open)...]
            guard let close = rest.firstIndex(where: { $0 == "]" || $0 == "[" }) else { break }
            if rest[close] == "[" { continue }
            var inner = rest[..<close].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: close)...]
            if inner.hasPrefix("&") { inner.removeFirst() }
            guard let first = inner.first, first != "#", first != "*", first != "\\", first != "!", first != "\"" else {
                continue
            }
            let name = inner.split(separator: ":", maxSplits: 1).first.map(String.init) ?? inner
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { names.append(trimmed) }
        }
        return names
    }

    /// Identifier words of a formula, in order (measure names used directly in `Formula=` / `IfCondition=`).
    static func identifiers(in text: String) -> [String] {
        var names: [String] = []
        var current = ""
        var inVariable = false
        for c in text {
            if c.isLetter || c.isNumber || c == "_" || c == "." {
                current.append(c)
                continue
            }
            if !current.isEmpty, !inVariable, current.first.map({ !$0.isNumber }) ?? false { names.append(current) }
            current = ""
            // `#Var#` is a variable, not a measure name.
            if c == "#" { inVariable.toggle() }
        }
        if !current.isEmpty, !inVariable, current.first.map({ !$0.isNumber }) ?? false { names.append(current) }
        return names
    }
}

// MARK: - Naming

/// Names the layers and data of one skin (§6), with what naming needs computed once: the runs of repeated sections,
/// the background, and who references whom.
final class LayerNamer {
    let skin: Skin
    /// Each computed when first needed: naming one data item or following a formula needs none of them.
    lazy var series: [Series] = LayerSeries.detect(in: skin)
    lazy var background: String? = LayerNaming.background(in: skin)
    lazy var references = LayerReferences(skin: skin)
    private lazy var positions: [String: (series: Series, index: Int)] = {
        var positions: [String: (series: Series, index: Int)] = [:]
        for s in series {
            for (i, name) in s.members.enumerated() { positions[(s.kind == .layers ? "m:" : "d:") + name.lowercased()] = (s, i) }
        }
        return positions
    }()
    private var layerCache: [String: LayerName] = [:]
    private var rawLayerCache: [String: LayerName] = [:]
    /// Layer (lowercased) → the title that tells it apart from layers with the same name (`makeDistinctTitles`).
    private var distinctTitles: [String: String]?
    private var namingAllLayers = false
    private var dataCache: [String: DataName] = [:]
    private var rawDataCache: [String: DataName] = [:]
    /// Data item (lowercased) → its numbered name as a member of a run (`repeatedDataNames`), found once.
    private var numberedData: [String: String]?
    private var distinctData: [String: String]?
    private var numberingData = false
    /// Data being named (a formula's name can depend on a layer's, which can depend on data again).
    private var naming: Set<String> = []
    /// Layers being named (the same loop, seen from the layer).
    private var namingLayers: Set<String> = []

    init(skin: Skin) {
        self.skin = skin
    }

    // MARK: Layers

    func layer(_ m: Meter) -> LayerName {
        let key = m.name.lowercased()
        if let cached = layerCache[key] { return cached }
        if distinctTitles == nil {
            // Asked while every layer is being named for the check below: its own name, not kept.
            if namingAllLayers { return rawLayer(m) }
            namingAllLayers = true
            distinctTitles = makeDistinctTitles()
            namingAllLayers = false
        }
        var name = rawLayer(m)
        if let title = distinctTitles?[key] { name.title = title }
        if name.subtitle == name.title, m.frame.width > 0 || m.frame.height > 0 {
            // "Color block · Color block" tells nothing: the size says which.
            name.subtitle = "\(name.title) · \(LayerNaming.number(m.frame.width)) × \(LayerNaming.number(m.frame.height))"
        }
        layerCache[key] = name
        return name
    }

    /// A layer's name from what it is and shows (before names that several layers share are told apart).
    private func rawLayer(_ m: Meter) -> LayerName {
        let key = m.name.lowercased()
        if let cached = rawLayerCache[key] { return cached }
        guard namingLayers.insert(key).inserted else {
            // Asked again while it is being named (a loop through the data it follows): its kind for now, never kept.
            let kind = LayerNaming.kindNoun(m)
            return LayerName(title: kind, subtitle: kind, sentence: "\(kind).", symbol: LayerNaming.symbol(forMeterType: m.type))
        }
        defer { namingLayers.remove(key) }
        let name = makeLayer(m)
        rawLayerCache[key] = name
        return name
    }

    /// Titles for layers that would otherwise share one ("Gauge" 13 times, the hour and minute hands both "Time
    /// gauge", two "Path"s): each is named after its section when that name says something ("Hour hand", "Tick 12",
    /// "Previous"), else numbered in file order ("Counter graph 2"). Runs ("Bar 6") and texts (named by their words,
    /// which change as they run) keep their names.
    private func makeDistinctTitles() -> [String: String] {
        var byTitle: [String: [Meter]] = [:]
        var order: [String] = []
        for m in skin.meters where positions["m:" + m.name.lowercased()] == nil {
            let title = rawLayer(m).title
            guard !title.hasPrefix("“"), title != "Background" else { continue }
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(m)
        }
        var result: [String: String] = [:]
        // Titles other rows already have: a new title must not be one of them.
        let taken = Set(order.filter { byTitle[$0]?.count == 1 }.map { $0.lowercased() } + ["background"])
        for title in order {
            guard let meters = byTitle[title], meters.count > 1 else { continue }
            let words = meters.map { m in Self.descriptiveWords(m, title: title).flatMap { taken.contains($0.lowercased()) ? nil : $0 } }
            let usable = !words.contains(where: { $0 == nil }) && Set(words.compactMap { $0?.lowercased() }).count == meters.count
            for (i, m) in meters.enumerated() {
                result[m.name.lowercased()] = usable ? (words[i] ?? title) : "\(title) \(i + 1)"
            }
        }
        return result
    }

    /// A section name as words when they say more than the kind of layer: "MeterHourHand" → "Hour hand", "Tick12" →
    /// "Tick 12"; nil for "Meter3", "MeterLine2", "Shape" or words that are the title again.
    static func descriptiveWords(_ m: Meter, title: String) -> String? {
        let words = LayerNaming.humanized(m.name)
        let parts = LayerNaming.words(words).filter { !$0.allSatisfy(\.isNumber) }.map { $0.lowercased() }
        let kinds: Set<String> = ["text", "string", "image", "picture", "bar", "line", "histogram", "roundline", "rotator",
                                  "bitmap", "button", "shape", "graph", "gauge", "dial", "meter", "layer", "block", "color"]
        guard !parts.isEmpty, !parts.allSatisfy(kinds.contains), words.caseInsensitiveCompare(title) != .orderedSame else {
            return nil
        }
        return words
    }

    private func makeLayer(_ m: Meter) -> LayerName {
        let symbol = LayerNaming.symbol(forMeterType: m.type)
        let size = "\(LayerNaming.number(m.frame.width)) × \(LayerNaming.number(m.frame.height))"
        if let (s, i) = positions["m:" + m.name.lowercased()] { return member(m, of: s, at: i) }
        if m.name.caseInsensitiveCompare(background ?? "") == .orderedSame {
            let kind = m.type.lowercased() == "shape" ? LayerNaming.shapeKind(m) : LayerNaming.kindNoun(m)
            return LayerName(title: "Background", subtitle: "\(kind) · whole widget",
                             sentence: "\(kind), \(size), behind everything.", symbol: symbol)
        }
        let kind = LayerNaming.kindNoun(m)
        switch m.type.lowercased() {
        case "string":
            return text(m, symbol: symbol)
        case "bar", "line", "histogram", "roundline", "rotator", "bitmap":
            guard let measure = m.measures.first else {
                if Self.drawsWithoutData(m) {
                    // A clock face, rim or tick: the usual way to draw a fixed ring, disc or line.
                    return LayerName(title: kind, subtitle: "\(kind) · fixed shape",
                                     sentence: "\(kind) drawn as a fixed shape, \(size).", symbol: symbol)
                }
                return LayerName(title: kind, subtitle: "\(kind) · not showing anything yet",
                                 sentence: "\(kind) that isn't showing anything yet.", symbol: symbol)
            }
            let d = data(measure)
            return LayerName(title: "\(d.short) \(LayerNaming.titleNoun(m))",
                             subtitle: "\(kind) · \(LayerNaming.inSentence(d.name))",
                             sentence: "\(kind) showing the \(LayerNaming.inSentence(d.name))\(filling(m)).", symbol: symbol)
        case "image":
            let file = (m.rawOption("ImageName") ?? "").trimmingCharacters(in: .whitespaces)
            if let measure = m.measures.first, !file.isEmpty || kind == "Picture" {
                // A picture live data chooses: "Album cover", "Web picture".
                let d = data(measure)
                let lower = d.name.lowercased()
                let title = ["cover", "picture", "image", "art", "icon", "photo"].contains(where: { lower.hasSuffix($0) })
                    ? d.name : "\(d.short) picture"
                return LayerName(title: title, subtitle: "Picture · \(LayerNaming.inSentence(d.name))",
                                 sentence: "Picture showing the \(LayerNaming.inSentence(d.name)), \(size).", symbol: symbol)
            }
            if !file.isEmpty {
                let written = LayerNaming.fileName(file)
                return LayerName(title: LayerNaming.humanizedFile(file), subtitle: "Picture",
                                 sentence: "Picture “\(written)”, \(size).", symbol: symbol)
            }
            let color = LayerNaming.colorName(m.solidColor)
            if let followed = followedData(of: m) {
                if isCalc(followed), formulaReferences(followed).isEmpty {
                    // Placed by a formula that reads no other data: a counter (it reads itself) moves the block on
                    // its own; a fixed number does not move it. (Named after that formula, the block would be named
                    // after itself: the formula is "{this layer} position".)
                    if refersToItself(followed) {
                        return LayerName(title: "Moving block", subtitle: "Color block · moves on its own",
                                         sentence: "A \(size) \(color) block that moves on its own.", symbol: symbol)
                    }
                } else {
                    let d = data(followed)
                    return LayerName(title: "\(d.short) marker",
                                     subtitle: "Color block · moves with \(LayerNaming.inSentence(d.name))",
                                     sentence: "A \(size) \(color) block that moves with the \(LayerNaming.inSentence(d.name)).",
                                     symbol: symbol)
                }
            }
            return LayerName(title: "Color block", subtitle: "Color block", sentence: "A \(size) \(color) block.",
                             symbol: symbol)
        case "shape":
            let shape = LayerNaming.shapeKind(m)
            let keys = LayerReferences.shapeKeys(of: m)
            let used = keys.flatMap { LayerReferences.bracketNames(in: m.rawOption($0) ?? "") }
                .compactMap { skin.measure(named: $0) }.first
            if let used {
                let d = data(used)
                // A rectangle whose length follows the data is a bar ("Memory bar"), or a progress line when thin
                // ("Seconds progress line").
                let noun = Self.dataRectangle(m) ? (m.frame.height <= 4 ? "progress line" : "bar") : "shape"
                return LayerName(title: "\(d.short) \(noun)", subtitle: "Shape · \(LayerNaming.inSentence(d.name))",
                                 sentence: "\(shape) that follows the \(LayerNaming.inSentence(d.name)).", symbol: symbol)
            }
            if keys.count > 1 {
                return LayerName(title: "\(keys.count) shapes", subtitle: "Shape", sentence: "\(keys.count) shapes, \(size).",
                                 symbol: symbol)
            }
            return LayerName(title: shape, subtitle: "Shape", sentence: "\(shape), \(size).", symbol: symbol)
        default:
            return LayerName(title: LayerNaming.humanized(m.name), subtitle: kind, sentence: "\(kind).", symbol: symbol)
        }
    }

    /// Text layers: named by what they say.
    private func text(_ m: Meter, symbol: String) -> LayerName {
        let shown = (m as? StringMeter)?.text ?? ""
        let rendered = LayerNaming.oneLine(shown.isEmpty && m.measures.isEmpty ? (m.option("Text") ?? "") : shown)
        if let measure = m.measures.first {
            var d = data(measure)
            if rendered.isEmpty, let other = alternative(of: measure, for: m) {
                // Empty because a setting chose empty data (`MeasureName=MeasureSuffix#ClockHours#` in 24-hour
                // mode): named after what it shows otherwise ("AM/PM (empty)").
                d = data(other)
            }
            let about = LayerNaming.inSentence(d.name)
            if rendered.isEmpty {
                return LayerName(title: "\(d.name) (empty)", subtitle: "Text · \(about)",
                                 sentence: "Text showing the \(about), empty right now.", symbol: symbol)
            }
            return LayerName(title: LayerNaming.quoted(rendered), subtitle: "Text · \(about)",
                             sentence: "Text showing the \(about), written as \(LayerNaming.quoted(rendered, limit: 60)).",
                             symbol: symbol)
        }
        if rendered.isEmpty {
            return LayerName(title: "Empty text", subtitle: "Text", sentence: "Text with no words yet.", symbol: symbol)
        }
        return LayerName(title: LayerNaming.quoted(rendered), subtitle: "Text",
                         sentence: "Text that says \(LayerNaming.quoted(rendered, limit: 60)).", symbol: symbol)
    }

    /// Another data item a MeasureName built from a variable can choose (`MeasureSuffix#ClockHours#`: the
    /// `MeasureSuffix12` of `MeasureSuffix24`), one that isn't fixed text; nil when there is none.
    private func alternative(of measure: Measure, for m: Meter) -> Measure? {
        let raw = (m.rawOption("MeasureName") ?? "").trimmingCharacters(in: .whitespaces)
        return LayerReferences.measures(matching: raw, in: skin).lazy
            .filter { $0.caseInsensitiveCompare(measure.name) != .orderedSame }
            .compactMap { self.skin.measure(named: $0) }
            .first { self.typeName($0) != "string" }
    }

    /// Whether a gauge or dial with no data still draws something: a solid disc or ring (`Solid=1`), a line
    /// (`LineLength` past `LineStart`), or a picture.
    static func drawsWithoutData(_ m: Meter) -> Bool {
        func number(_ key: String) -> Double? { OptionValue.number((m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces)) }
        switch m.type.lowercased() {
        case "roundline":
            if (number("Solid") ?? 0) != 0 { return true }
            return (number("LineLength") ?? 0) > (number("LineStart") ?? 0) || !(m.rawOption("ImageName") ?? "").isEmpty
        case "rotator", "bitmap":
            return !(m.rawOption("ImageName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return false
        }
    }

    /// Whether a Shape's part that follows data is a rectangle (a bar that grows with it).
    static func dataRectangle(_ m: Meter) -> Bool {
        LayerReferences.shapeKeys(of: m).contains { key in
            guard let raw = m.rawOption(key), !LayerReferences.bracketNames(in: raw).isEmpty,
                  let spec = ShapeSpec.parse(raw) else { return false }
            return spec.kind == .rectangle
        }
    }

    /// ", filling upward" for a bar (from BarOrientation and Flip); empty for other layers.
    private func filling(_ m: Meter) -> String {
        guard let bar = m as? BarMeter else { return "" }
        if bar.vertical { return bar.flip ? ", filling downward" : ", filling upward" }
        return bar.flip ? ", filling to the left" : ", filling to the right"
    }

    /// One layer of a run: "Bar 6", "Sound band 6 of 16".
    private func member(_ m: Meter, of s: Series, at i: Int) -> LayerName {
        let kind = LayerNaming.kindNoun(m)
        let n = s.members.count
        let symbol = LayerNaming.symbol(forMeterType: m.type)
        let title = "\(kind) \(i + 1)"
        guard let measure = m.measures.first else {
            return LayerName(title: title, subtitle: "\(kind) \(i + 1) of \(n)", sentence: "\(kind) \(i + 1) of \(n).",
                             symbol: symbol)
        }
        let d = data(measure)
        let numbered = LayerSeries.numbered(d.name) != nil
        var subtitle = numbered ? "\(d.name) of \(n)" : d.name
        if isSoundBand(measure) {
            if i == 0 { subtitle += " (lowest)" } else if i == n - 1 { subtitle += " (highest)" }
        }
        let about = LayerNaming.inSentence(d.name) + (numbered ? " of \(n)" : "")
        return LayerName(title: title, subtitle: subtitle, sentence: "\(kind) showing \(about)\(filling(m)).", symbol: symbol)
    }

    /// A run of layers: "16 bars", "Bar · sound bands 1–16".
    func seriesName(_ s: Series) -> LayerName {
        let meters = s.members.compactMap { skin.meter(named: $0) }
        guard let first = meters.first else {
            return LayerName(title: "\(s.members.count) layers", subtitle: "Layer", sentence: "", symbol: "square.stack")
        }
        let kind = LayerNaming.kindNoun(first)
        let title = "\(meters.count) \(LayerNaming.kindPlural(kind))"
        let symbol = LayerNaming.symbol(forMeterType: first.type)
        guard let range = numberedRange(meters.map { $0.measures.first }) else {
            return LayerName(title: title, subtitle: kind, sentence: "\(title).", symbol: symbol)
        }
        let order = meters.first?.measures.first.map(isSoundBand) == true ? ", low to high" : ""
        return LayerName(title: title, subtitle: "\(kind) · \(range)", sentence: "\(title) showing \(range)\(order).",
                         symbol: symbol)
    }

    /// "sound bands 1–16" when the data are the same name with numbers counting up; nil otherwise.
    private func numberedRange(_ measures: [Measure?]) -> String? {
        let names = measures.map { $0.map { data($0).name } }
        guard let firstName = names.first ?? nil, let lastName = names.last ?? nil,
              let first = Self.trailingNumber(firstName), let last = Self.trailingNumber(lastName),
              first.base == last.base, !first.base.isEmpty else { return nil }
        for (i, name) in names.enumerated() {
            guard let name, let n = Self.trailingNumber(name), n.base == first.base, n.number == first.number + i else {
                return nil
            }
        }
        return "\(LayerNaming.plural(LayerNaming.inSentence(first.base))) \(first.number)–\(last.number)"
    }

    /// "Sound band 6" → ("Sound band", 6).
    static func trailingNumber(_ name: String) -> (base: String, number: Int)? {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last, let n = Int(last) else { return nil }
        return (parts.dropLast().joined(separator: " "), n)
    }

    /// The data a layer's X or Y follows (`[MeasurePeakX]`), through formulas to what they are calculated from.
    func followedData(of m: Meter) -> Measure? {
        let raw = [m.rawOption("X"), m.rawOption("Y")].compactMap { $0 }
        guard let direct = raw.flatMap(LayerReferences.bracketNames).compactMap({ skin.measure(named: $0) }).first else {
            return nil
        }
        return underlying(direct, depth: 0)
    }

    /// A formula's first data that is not a formula itself (the formula when it uses none).
    func underlying(_ m: Measure, depth: Int) -> Measure {
        guard isCalc(m), depth < 4, let next = formulaReferences(m).first else { return m }
        return underlying(next, depth: depth + 1)
    }

    private func isCalc(_ m: Measure) -> Bool {
        (m.rawOption("Measure") ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "calc"
    }

    /// A formula that reads its own value (`Formula=(MeasureScroll + 1) % 100`): a counter.
    private func refersToItself(_ m: Measure) -> Bool {
        let formula = m.rawOption("Formula") ?? ""
        return (LayerReferences.bracketNames(in: formula) + LayerReferences.identifiers(in: formula))
            .contains { $0.caseInsensitiveCompare(m.name) == .orderedSame }
    }

    /// Data a formula names, in order.
    func formulaReferences(_ m: Measure) -> [Measure] {
        let formula = m.rawOption("Formula") ?? ""
        var seen: Set<String> = []
        return (LayerReferences.bracketNames(in: formula) + LayerReferences.identifiers(in: formula)).compactMap { name in
            guard name.caseInsensitiveCompare(m.name) != .orderedSame, let found = skin.measure(named: name),
                  seen.insert(found.name.lowercased()).inserted else { return nil }
            return found
        }
    }

    // MARK: Data

    func data(_ m: Measure) -> DataName {
        let key = m.name.lowercased()
        if let cached = dataCache[key] { return cached }
        if numberedData == nil {
            // Asked while the runs are being named (a member's formula names another data item): its own name, not
            // kept.
            if numberingData { return rawData(m) }
            numberingData = true
            numberedData = repeatedDataNames()
            distinctData = makeDistinctDataNames()
            numberingData = false
        }
        var name = rawData(m)
        if let numbered = numberedData?[key] {
            name.name = numbered
        } else if let distinct = distinctData?[key] {
            // Told apart by the author's own words; what it is stays as its second line.
            if name.subtitle.isEmpty { name.subtitle = name.name }
            name.name = distinct
        }
        dataCache[key] = name
        return name
    }

    /// Names for data items that would otherwise share one (a calendar's formulas, each "Calculated from month
    /// number"): each is named after its section when that says something ("Leap year", "First weekday"), else numbered
    /// ("Calculated from month number 2"). Members of a run are numbered by `repeatedDataNames` instead.
    private func makeDistinctDataNames() -> [String: String] {
        var inRun: Set<String> = []
        for s in series where s.kind == .data { inRun.formUnion(s.members.map { $0.lowercased() }) }
        var byName: [String: [Measure]] = [:]
        var order: [String] = []
        for m in skin.measures where !inRun.contains(m.name.lowercased()) {
            // A formula that is only another data item shares its name on purpose (it is the same thing).
            let formula = option(m, "Formula")
            if isCalc(m), formulaReferences(m).count == 1, Self.isOnlyName(formula, formulaReferences(m)[0].name) { continue }
            let name = rawData(m).name
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(m)
        }
        let generic: Set<String> = ["measure", "calc", "value", "data", "number", "item", "string", "time"]
        // Names other rows already have ("Year"): a new name must not be one of them.
        let taken = Set(order.filter { byName[$0]?.count == 1 }.map { $0.lowercased() })
        var result: [String: String] = [:]
        for name in order {
            guard let measures = byName[name], measures.count > 1 else { continue }
            let words: [String?] = measures.map { m in
                let w = LayerNaming.humanized(m.name)
                let parts = LayerNaming.words(w).filter { !$0.allSatisfy(\.isNumber) }.map { $0.lowercased() }
                guard !parts.isEmpty, !parts.allSatisfy(generic.contains), w.caseInsensitiveCompare(name) != .orderedSame else {
                    return nil
                }
                // Another row's name already: said as what it is too ("Year, calculated").
                return taken.contains(w.lowercased()) ? (isCalc(m) ? "\(w), calculated" : nil) : w
            }
            let usable = !words.contains(where: { $0 == nil }) && Set(words.compactMap { $0?.lowercased() }).count == measures.count
            for (i, m) in measures.enumerated() { result[m.name.lowercased()] = usable ? (words[i] ?? name) : "\(name) \(i + 1)" }
        }
        return result
    }

    /// The name of a data item from its own settings (before the members of a run are numbered).
    private func rawData(_ m: Measure) -> DataName {
        let key = m.name.lowercased()
        if let cached = rawDataCache[key] { return cached }
        guard naming.insert(key).inserted else {
            let fallback = LayerNaming.humanized(m.name)
            return DataName(name: fallback, short: fallback, subtitle: "")
        }
        defer { naming.remove(key) }
        let name = makeData(m)
        rawDataCache[key] = name
        return name
    }

    private func option(_ m: Measure, _ key: String) -> String {
        (m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func flag(_ m: Measure, _ key: String) -> Bool {
        (OptionValue.number(skin.resolveStandardVariables(option(m, key), in: m)) ?? 0) != 0
    }

    /// Memory measures: the free amount (`Free=1`, or `InvertMeasure=1` on the used amount).
    private func isFree(_ m: Measure) -> Bool {
        flag(m, "InvertMeasure") != flag(m, "Free")
    }

    private func typeName(_ m: Measure) -> String {
        let type = option(m, "Measure").lowercased()
        return type == "plugin" ? MeasureRegistry.normalizedPluginName(option(m, "Plugin")) : type
    }

    private func isSoundBand(_ m: Measure) -> Bool {
        typeName(m) == "audiolevel" && option(m, "Type").lowercased() == "band"
    }

    private func makeData(_ m: Measure) -> DataName {
        func named(_ name: String, _ short: String, _ subtitle: String = "") -> DataName {
            DataName(name: name, short: short, subtitle: subtitle)
        }
        let type = typeName(m)
        switch type {
        case "cpu":
            let p = Int(OptionValue.number(option(m, "Processor")) ?? 0)
            return p <= 0 ? named("CPU usage", "CPU") : named("CPU core \(p) usage", "Core \(p)")
        case "physicalmemory":
            if flag(m, "Total") { return named("Total memory", "Memory") }
            return isFree(m) ? named("Memory free", "Memory") : named("Memory used", "Memory")
        case "memory":
            // The Windows commit total: the memory counted twice, plus the swap.
            if flag(m, "Total") { return named("Total memory (Windows-style)", "Memory") }
            return isFree(m) ? named("Memory free (Windows-style)", "Memory")
                             : named("Memory used (Windows-style)", "Memory")
        case "swapmemory":
            // The memory plus the swap files, as Windows counts the memory plus its page file (not the swap alone).
            if flag(m, "Total") { return named("Total memory and swap", "Memory + swap") }
            return isFree(m) ? named("Memory and swap free", "Memory + swap")
                             : named("Memory and swap used", "Memory + swap")
        case "netin":
            return flag(m, "Cumulative") ? named("Downloaded in total", "Download") : named("Download speed", "Download")
        case "netout":
            return flag(m, "Cumulative") ? named("Uploaded in total", "Upload") : named("Upload speed", "Upload")
        case "nettotal":
            return flag(m, "Cumulative") ? named("Network use in total", "Network") : named("Network speed", "Network")
        case "freediskspace":
            let volume = Self.volumeName(skin.resolveStandardVariables(option(m, "Drive"), in: m))
            if flag(m, "Total") { return named("Size of \(volume)", "Disk") }
            return flag(m, "InvertMeasure") ? named("Used space on \(volume)", "Disk") : named("Free space on \(volume)", "Disk")
        case "time":
            let raw = skin.resolveStandardVariables(option(m, "Format"), in: m)
            let time = LayerNaming.timeName(format: raw.isEmpty ? TimeFormatting.defaultFormat : raw)
            return named(time.name, time.short)
        case "uptime":
            return named("Time since startup", "Uptime")
        case "powerplugin":
            switch option(m, "PowerState").lowercased() {
            case "acline": return named("Charger connected", "Charger")
            case "status", "status2": return named("Battery status", "Battery")
            case "lifetime": return named("Battery time left", "Battery")
            case "mhz", "hz": return named("Processor speed", "Processor")
            default: return named("Battery level", "Battery")
            }
        case "audiolevel":
            return audio(m)
        case "calc":
            return calc(m)
        case "loop":
            return named("Counting number", "Counter")
        case "webparser":
            // A child (`URL=[Parent]`, `StringIndex=N`) is one value the parent found.
            let index = Int(OptionValue.number(option(m, "StringIndex")) ?? 0)
            let isChild = !LayerReferences.bracketNames(in: option(m, "URL")).isEmpty
            let source = host(of: m, depth: 0)
            return isChild && index > 0 ? named("Value \(index) from \(source)", "Web") : named("Text from \(source)", "Web")
        case "string":
            return named("Fixed text", "Text")
        case "process":
            let app = option(m, "ProcessName").replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
            return named(app.isEmpty ? "Whether an app is open" : "Whether \(app) is open", "App")
        case "sysinfo":
            let info = option(m, "SysInfoType")
            return named(info.isEmpty ? "Mac info" : LayerNaming.sentence(LayerNaming.words(info.lowercased())), "Info")
        case "wifistatus":
            switch option(m, "WiFiInfoType").lowercased() {
            case "ssid": return named("Wi-Fi network name", "Wi-Fi")
            case "quality": return named("Wi-Fi signal", "Wi-Fi")
            case "txrate": return named("Wi-Fi send speed", "Wi-Fi")
            case "rxrate": return named("Wi-Fi receive speed", "Wi-Fi")
            case "encryption": return named("Wi-Fi encryption", "Wi-Fi")
            case "auth": return named("Wi-Fi security", "Wi-Fi")
            case "phy": return named("Wi-Fi standard", "Wi-Fi")
            case "list": return named("Nearby Wi-Fi networks", "Networks")
            default: return named("Wi-Fi", "Wi-Fi")
            }
        case "nowplaying":
            switch option(m, "PlayerType").lowercased() {
            case "title": return named("Song title", "Song")
            case "artist": return named("Song artist", "Artist")
            case "album": return named("Album", "Album")
            case "cover", "coverpath": return named("Album cover", "Cover")
            case "progress": return named("Song progress", "Progress")
            case "duration": return named("Song length", "Length")
            case "position": return named("Song position", "Position")
            case "year": return named("Song year", "Year")
            case "number": return named("Track number", "Track")
            case "genre": return named("Song genre", "Genre")
            case "rating": return named("Song rating", "Rating")
            case "lyrics": return named("Song lyrics", "Lyrics")
            case "file": return named("Song file", "File")
            case "volume": return named("Player volume", "Volume")
            case "state": return named("Play state", "State")
            case "status": return named("Whether the player is open", "Player")
            case "shuffle": return named("Shuffle", "Shuffle")
            case "repeat": return named("Repeat", "Repeat")
            default: return named("Now playing", "Music")
            }
        default:
            let title = EditorSchema.describeMeasure(type: option(m, "Measure").isEmpty ? m.type : option(m, "Measure"),
                                                     plugin: m.rawOption("Plugin"), total: flag(m, "Total"),
                                                     invert: flag(m, "InvertMeasure")).title
            return named(title, title)
        }
    }

    /// AudioLevel: the parent is the sound itself, the children what is measured of it (§6.2).
    private func audio(_ m: Measure) -> DataName {
        let parentName = option(m, "Parent")
        guard !parentName.isEmpty else {
            return option(m, "Port").lowercased() == "input"
                ? DataName(name: "Sound from the microphone", short: "Sound", subtitle: "What the microphone hears")
                : DataName(name: "Sound from your Mac", short: "Sound", subtitle: "What your Mac plays")
        }
        let parent = skin.measure(named: parentName)
        let input = parent.map { option($0, "Port").lowercased() == "input" } ?? false
        let channel = option(m, "Channel").lowercased()
        let left = ["l", "left", "0"].contains(channel), right = ["r", "right", "1"].contains(channel)
        func index(_ key: String) -> Int { Int(OptionValue.number(option(m, key)) ?? 0) }
        switch option(m, "Type").lowercased() {
        case "band":
            return DataName(name: "Sound band \(index("BandIdx") + 1)", short: "Band \(index("BandIdx") + 1)", subtitle: "")
        case "rms":
            if left { return DataName(name: "Left channel level", short: "Left channel", subtitle: "") }
            if right { return DataName(name: "Right channel level", short: "Right channel", subtitle: "") }
            return DataName(name: "Sound level", short: "Level", subtitle: "")
        case "peak":
            if left { return DataName(name: "Left channel peak", short: "Left peak", subtitle: "") }
            if right { return DataName(name: "Right channel peak", short: "Right peak", subtitle: "") }
            return DataName(name: "Peak level", short: "Peak", subtitle: "")
        case "devicename":
            return DataName(name: input ? "Input device name" : "Output device name", short: "Device", subtitle: "")
        case "deviceid":
            return DataName(name: input ? "Input device ID" : "Output device ID", short: "Device", subtitle: "")
        case "devicelist":
            return DataName(name: input ? "Input devices" : "Output devices", short: "Devices", subtitle: "")
        case "devicestatus":
            return DataName(name: "Sound device status", short: "Status", subtitle: "")
        case "format":
            return DataName(name: "Sound format", short: "Format", subtitle: "")
        case "bandfreq":
            let i = index("BandIdx")
            let bands = parent.map { Int(OptionValue.number(option($0, "Bands")) ?? 0) } ?? 0
            if i == 0 { return DataName(name: "Lowest band frequency", short: "Frequency", subtitle: "") }
            if bands > 0, i == bands - 1 { return DataName(name: "Highest band frequency", short: "Frequency", subtitle: "") }
            return DataName(name: "Band \(i + 1) frequency", short: "Frequency", subtitle: "")
        case "fft":
            return DataName(name: "Sound frequency bin \(index("FFTIdx") + 1)", short: "Bin \(index("FFTIdx") + 1)",
                            subtitle: "")
        case "fftfreq":
            return DataName(name: "Frequency of bin \(index("FFTIdx") + 1)", short: "Frequency", subtitle: "")
        default:
            return DataName(name: "Sound level", short: "Level", subtitle: "")
        }
    }

    /// Formulas: the swap (memory and swap − memory), named after the one layer they place, a counter, else after
    /// what they are calculated from.
    private func calc(_ m: Measure) -> DataName {
        let formula = option(m, "Formula")
        if LayerReferences.identifiers(in: formula).contains(where: { $0.caseInsensitiveCompare("Random") == .orderedSame }) {
            return DataName(name: "Random number", short: "Random", subtitle: "")
        }
        if let swap = swap(m) { return swap }
        let refs = references.references(to: m.name)
        let places = refs.filter { $0.fromMeter && ["x", "y"].contains($0.key.lowercased()) }
        if !places.isEmpty, refs.count == places.count, Set(places.map { $0.from.lowercased() }).count == 1,
           let meter = skin.meter(named: places[0].from) {
            return DataName(name: "\(layer(meter).title) position", short: "Position", subtitle: "")
        }
        if refersToItself(m) { return DataName(name: "Counting number", short: "Counter", subtitle: "") }
        let sources = formulaReferences(m).filter { !naming.contains($0.name.lowercased()) }
        // Only another data item (`Formula=MeasureWeekText`): the same thing.
        if sources.count == 1, Self.isOnlyName(formula, sources[0].name) { return data(sources[0]) }
        // `A / B * 100`: A as a percentage (a disk's percent used, not "calculated from its size").
        if let part = percentPart(of: formula, among: sources) {
            let d = data(part)
            if !d.name.hasPrefix("Calculated") {
                return DataName(name: "\(d.name) as %", short: d.short, subtitle: "")
            }
        }
        if let first = sources.first {
            // Named after the data it is calculated from, through other formulas, in short too ("Swap shape", not
            // "Formula shape"). A chain too long to follow is only "calculated": a name is never "calculated from
            // calculated from…".
            let source = underlying(first, depth: 0)
            if !isCalc(source), !naming.contains(source.name.lowercased()) {
                let d = data(source)
                if !d.name.hasPrefix("Calculated") {
                    return DataName(name: "Calculated from \(LayerNaming.inSentence(d.name))", short: d.short, subtitle: "")
                }
            }
            return DataName(name: "Calculated number", short: "Formula", subtitle: "")
        }
        if LayerReferences.identifiers(in: formula).contains(where: { $0.caseInsensitiveCompare("Counter") == .orderedSame }) {
            return DataName(name: "Counting number", short: "Counter", subtitle: "")
        }
        return DataName(name: "Calculated number", short: "Formula", subtitle: "")
    }

    /// Whether a formula is only `name` (`MeasureWeek`, `(MeasureWeek)`, `[MeasureWeek:]`).
    static func isOnlyName(_ formula: String, _ name: String) -> Bool {
        let bare = formula.filter { !"()[]: \t".contains($0) }
        return bare.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The data a formula shows as a percentage of another (`A / B * 100`, `100 * A / B`, `[A:] / [B:] * 100`): A.
    private func percentPart(of formula: String, among sources: [Measure]) -> Measure? {
        let bare = formula.filter { !"[]:".contains($0) }
        guard bare.range(of: #"(?<![\d.])100(?![\d.])"#, options: .regularExpression) != nil,
              let regex = try? NSRegularExpression(pattern: #"([A-Za-z_][\w.]*)\s*\)?\s*/\s*\(?\s*([A-Za-z_][\w.]*)"#) else {
            return nil
        }
        let range = NSRange(bare.startIndex..., in: bare)
        for match in regex.matches(in: bare, range: range) {
            guard let a = Range(match.range(at: 1), in: bare), let b = Range(match.range(at: 2), in: bare) else { continue }
            let first = String(bare[a]), second = String(bare[b])
            if let part = sources.first(where: { $0.name.caseInsensitiveCompare(first) == .orderedSame }),
               sources.contains(where: { $0.name.caseInsensitiveCompare(second) == .orderedSame }) {
                return part
            }
        }
        return nil
    }

    /// `SwapMemory − PhysicalMemory` (both used, both free or both totals) is the swap itself: SwapMemory counts the
    /// memory too. "Swap used", "Swap free", "Total swap"; nil for any other formula.
    private func swap(_ m: Measure) -> DataName? {
        let formula = option(m, "Formula")
        let refs = formulaReferences(m)
        func escaped(_ name: String) -> String { NSRegularExpression.escapedPattern(for: name) }
        for s in refs where typeName(s) == "swapmemory" {
            for p in refs where typeName(p) == "physicalmemory" && flag(p, "Total") == flag(s, "Total")
                && (flag(s, "Total") || isFree(p) == isFree(s)) {
                let pattern = "(?<![A-Za-z0-9_])\\[?\(escaped(s.name))\\]?\\s*-\\s*\\[?\(escaped(p.name))\\]?(?![A-Za-z0-9_])"
                guard formula.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                if flag(s, "Total") { return DataName(name: "Total swap", short: "Swap", subtitle: "") }
                return DataName(name: isFree(s) ? "Swap free" : "Swap used", short: "Swap", subtitle: "")
            }
        }
        return nil
    }

    /// The web site a WebParser reads (its parent's for a child, `URL=[Parent]`).
    private func host(of m: Measure, depth: Int) -> String {
        let url = option(m, "URL")
        if depth < 4, let parent = LayerReferences.bracketNames(in: url).compactMap({ skin.measure(named: $0) }).first,
           parent !== m {
            return host(of: parent, depth: depth + 1)
        }
        let resolved = skin.resolveStandardVariables(url, in: m).trimmingCharacters(in: .whitespaces)
        let parsed = URL(string: resolved)
        var host = parsed?.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.isEmpty, parsed?.isFileURL == true || resolved.hasPrefix("/") {
            // A file on this Mac: named after the file ("feed.xml").
            let name = LayerNaming.fileName(parsed?.path ?? resolved)
            if !name.isEmpty { return name }
        }
        return host.isEmpty ? "a web page" : host
    }

    /// A disk by name: a Windows drive letter is the Mac's startup disk; `/Volumes/Name` is "Name".
    static func volumeName(_ drive: String) -> String {
        let d = drive.trimmingCharacters(in: .whitespaces)
        let isLetter = d.count <= 3 && d.first?.isLetter == true && d.dropFirst().first == ":"
        if d.isEmpty || isLetter || d == "/" {
            return FileManager.default.displayName(atPath: "/").isEmpty ? "your Mac" : FileManager.default.displayName(atPath: "/")
        }
        let parts = d.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes" { return String(parts[1]) }
        return parts.last.map(String.init) ?? d
    }

    // MARK: Runs of data

    /// "16 sound bands" (short "Sound bands").
    func dataSeriesName(_ s: Series) -> DataName {
        let names = s.members.compactMap { skin.measure(named: $0) }.map { data($0).name }
        let n = s.members.count
        if let first = names.first.flatMap(Self.trailingNumber),
           names.allSatisfy({ Self.trailingNumber($0)?.base == first.base }) {
            let plural = LayerNaming.plural(LayerNaming.inSentence(first.base))
            return DataName(name: "\(n) \(plural)", short: plural.prefix(1).uppercased() + plural.dropFirst(), subtitle: "")
        }
        // One name for every member ("Weekday"): "7 weekdays".
        if let first = names.first, names.allSatisfy({ $0 == first }) {
            let plural = LayerNaming.plural(LayerNaming.inSentence(LayerNaming.withoutBrackets(first)))
            return DataName(name: "\(n) \(plural)", short: plural.prefix(1).uppercased() + plural.dropFirst(), subtitle: "")
        }
        // Different names: named after their kind ("42 calculated numbers"), never after the section names.
        let kind = s.members.first.flatMap { skin.measure(named: $0) }.map(seriesNoun) ?? "live data item"
        let plural = LayerNaming.plural(kind)
        return DataName(name: "\(n) \(plural)", short: plural.prefix(1).uppercased() + plural.dropFirst(), subtitle: "")
    }

    /// What one member of a run of data is, as a lowercased noun ("calculated number", "time", "text").
    private func seriesNoun(_ m: Measure) -> String {
        switch typeName(m) {
        case "calc": return "calculated number"
        case "time": return "time"
        case "string": return "text"
        case "webparser": return "web value"
        case "cpu": return "CPU core"
        case "audiolevel": return "sound value"
        default: return "live data item"
        }
    }

    /// The members of a run of data that would otherwise share one name ("Weekday", "Calculated number") are
    /// numbered, 1-based ("Weekday 3"); nil when the members' names already differ.
    private func repeatedDataNames() -> [String: String] {
        var result: [String: String] = [:]
        for s in series where s.kind == .data {
            let members = s.members.compactMap { skin.measure(named: $0) }
            let names = members.map { rawData($0).name }
            guard let first = names.first, names.count > 1, names.allSatisfy({ $0 == first }) else { continue }
            let base = LayerNaming.withoutBrackets(first)
            for (i, m) in members.enumerated() { result[m.name.lowercased()] = "\(base) \(i + 1)" }
        }
        return result
    }
}
