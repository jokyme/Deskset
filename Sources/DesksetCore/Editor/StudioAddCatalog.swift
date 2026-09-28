import Foundation

/// What the Studio's Add page adds to an INI widget, and the sections it writes: data shown the way the person picks
/// (a number, a bar, a ring, a graph — "Show CPU usage as…"), parts (text, symbol, picture, bar, ring, graph, shape,
/// button) and SF Symbols. Colors and fonts come from the widget's own variables when it has the usual ones
/// (`#TextColor#`, `#AccentColor#`, `#FontFace#`…), as the old Studio's components do. Where the widget already reads
/// the same data, the new part reads that measure instead of adding another.
public enum StudioAddCatalog {
    /// How a data item is shown.
    public enum Look: String, CaseIterable, Equatable {
        case number, bar, ring, graph
    }

    /// Which group of the page a data item is in.
    public enum Category: String, CaseIterable, Equatable {
        case mac, time, weather, music
    }

    /// How a data item's value is written.
    public enum ValueKind: Equatable {
        case percent, bytes, bytesPerSecond, text, temperature
    }

    public struct DataItem: Equatable {
        public var id: String
        /// Its everyday name (English; the Studio translates it).
        public var title: String
        public var symbol: String
        public var category: Category
        /// The measure's name without a number (`MeasureCPU`).
        public var measureBase: String
        public var measure: [(key: String, value: String)]
        public var kind: ValueKind
        public var looks: [Look]
        /// More words search finds it by.
        public var keywords: [String]

        public static func == (a: DataItem, b: DataItem) -> Bool { a.id == b.id }
    }

    static func item(_ id: String, _ title: String, _ symbol: String, _ category: Category, _ base: String,
                     _ measure: [(String, String)], _ kind: ValueKind, looks: [Look] = Look.allCases,
                     keywords: [String] = []) -> DataItem {
        DataItem(id: id, title: title, symbol: symbol, category: category, measureBase: base,
                 measure: measure.map { (key: $0.0, value: $0.1) }, kind: kind, looks: looks, keywords: keywords)
    }

    /// The data the page offers, in its order.
    public static let data: [DataItem] = [
        item("cpu", "CPU usage", "cpu", .mac, "MeasureCPU", [("Measure", "CPU"), ("Processor", "0")], .percent,
             keywords: ["processor", "CPU", "处理器"]),
        item("memory", "Memory used", "memorychip", .mac, "MeasureMemory", [("Measure", "PhysicalMemory")], .bytes,
             keywords: ["RAM", "PhysicalMemory", "内存"]),
        item("disk", "Disk used", "internaldrive", .mac, "MeasureDiskUsed",
             [("Measure", "FreeDiskSpace"), ("Drive", "/"), ("InvertMeasure", "1")], .percent,
             keywords: ["storage", "FreeDiskSpace", "磁盘", "存储"]),
        item("gpu", "GPU usage", "cube.transparent", .mac, "MeasureGPU",
             [("Measure", "Plugin"), ("Plugin", "MacSensors"), ("Sensor", "gpu.usage"), ("MinValue", "0"),
              ("MaxValue", "100")], .percent, keywords: ["graphics", "显卡"]),
        item("download", "Download speed", "arrow.down.circle", .mac, "MeasureNetIn",
             [("Measure", "NetIn"), ("Interface", "0")], .bytesPerSecond, looks: [.number, .graph],
             keywords: ["network", "NetIn", "网速", "下载"]),
        item("upload", "Upload speed", "arrow.up.circle", .mac, "MeasureNetOut",
             [("Measure", "NetOut"), ("Interface", "0")], .bytesPerSecond, looks: [.number, .graph],
             keywords: ["network", "NetOut", "网速", "上传"]),
        item("battery", "Battery", "battery.75percent", .mac, "MeasureBattery",
             [("Measure", "Plugin"), ("Plugin", "PowerPlugin"), ("PowerState", "Percent")], .percent,
             looks: [.number, .bar, .ring], keywords: ["power", "charge", "电量"]),
        item("time", "Time", "clock", .time, "MeasureTime", [("Measure", "Time"), ("Format", "%H:%M")], .text,
             looks: [.number], keywords: ["clock", "时钟"]),
        item("date", "Date", "calendar", .time, "MeasureDate", [("Measure", "Time"), ("Format", "%A, %#d %B")], .text,
             looks: [.number], keywords: ["day", "calendar", "日历"]),
        item("uptime", "Uptime", "timer", .time, "MeasureUptime",
             [("Measure", "Uptime"), ("Format", "%4!i!d %3!i!h %2!02i!m")], .text, looks: [.number],
             keywords: ["startup", "开机"]),
        item("temperature", "Temperature", "thermometer.medium", .weather, "MeasureWeather",
             [("Measure", "Plugin"), ("Plugin", "MacWeather"), ("Location", "timezone"), ("Type", "Temperature")],
             .temperature, looks: [.number], keywords: ["weather", "天气", "气温"]),
        item("nowplaying", "Now playing", "music.note", .music, "MeasureNowPlaying",
             [("Measure", "NowPlaying"), ("PlayerName", "iTunes"), ("PlayerType", "Title")], .text, looks: [.number],
             keywords: ["song", "music", "Spotify", "音乐", "歌"]),
    ]

    public static func dataItem(_ id: String) -> DataItem? { data.first { $0.id == id } }

    /// The parts the page offers, in its order (four to a row).
    public enum Part: String, CaseIterable, Equatable {
        case text, symbol, picture, bar, ring, graph, shape, button

        public var symbol: String {
            switch self {
            case .text: return "textformat"
            case .symbol: return "star"
            case .picture: return "photo"
            case .bar: return "rectangle.split.3x1"
            case .ring: return "circle.dashed"
            case .graph: return "chart.xyaxis.line"
            case .shape: return "square.on.circle"
            case .button: return "button.horizontal"
            }
        }

        /// The old Studio's component a drag of it carries (the canvas draws its ghost at that size).
        public var dragComponent: String {
            switch self {
            case .text, .button: return "text"
            case .symbol, .picture: return "image"
            case .bar: return "cpu"
            case .ring: return "ring"
            case .graph: return "graph"
            case .shape: return "rectangle"
            }
        }
    }

    /// The component a dragged data item carries for its ghost.
    public static let dataDragComponent = "labelvalue"

    // MARK: Sections

    /// The widget's colors and font for new parts.
    struct Inks {
        var text: String
        var accent: String
        var track: String
        var font: [(String, String)]

        init(variables: Set<String>) {
            func has(_ v: String) -> Bool { variables.contains(v.lowercased()) }
            text = has("TextColor") ? "#TextColor#" : has("FontColor") ? "#FontColor#" : "255,255,255,235"
            accent = has("AccentColor") ? "#AccentColor#" : "110,190,255,255"
            track = has("TrackColor") ? "#TrackColor#" : "255,255,255,40"
            font = (has("FontFace") ? [("FontFace", "#FontFace#")] : has("FontName") ? [("FontFace", "#FontName#")] : [])
                + [("AntiAlias", "1")]
        }
    }

    static func section(_ name: String, _ options: [(String, String)]) -> EditorComponents.Section {
        EditorComponents.Section(name: name, options: options.map { (key: $0.0, value: $0.1) })
    }

    /// The sections that show data item `id` as `look` with its corner at (x, y): its measure (unless `reuse` names one
    /// the widget has that reads the same data) and the part. `existing`: the widget's section names (lowercased);
    /// `variables`: its variable names (lowercased).
    public static func sections(data id: String, look: Look, x: Double, y: Double, existing: Set<String>,
                                variables: Set<String>, reuse: String? = nil) -> [EditorComponents.Section] {
        guard let item = dataItem(id) else { return [] }
        var taken = Set(existing.map { $0.lowercased() })
        func name(_ base: String) -> String {
            let n = EditorComponents.uniqueName(base, taken: taken)
            taken.insert(n.lowercased())
            return n
        }
        let ink = Inks(variables: variables)
        let px = GeometryEdit.format(x), py = GeometryEdit.format(y)
        var result: [EditorComponents.Section] = []
        let measure: String
        if let reuse {
            measure = reuse
        } else {
            measure = name(item.measureBase)
            result.append(section(measure, item.measure.map { ($0.key, $0.value) }))
        }
        let short = item.measureBase.hasPrefix("Measure") ? String(item.measureBase.dropFirst("Measure".count))
            : item.measureBase
        func number(_ n: String, x: String, y: String, extra: [(String, String)] = []) -> EditorComponents.Section {
            var o: [(String, String)] = [("Meter", "String"), ("MeasureName", measure), ("X", x), ("Y", y),
                                         ("FontColor", ink.text), ("FontSize", "13")] + ink.font
            switch item.kind {
            case .percent:
                o += [("Text", "%1%"), ("NumOfDecimals", "0")]
                if item.id == "disk" { o.append(("Percentual", "1")) }
            case .bytes: o += [("Text", "%1B"), ("AutoScale", "1"), ("NumOfDecimals", "1")]
            case .bytesPerSecond: o += [("Text", "%1B/s"), ("AutoScale", "1"), ("NumOfDecimals", "1")]
            case .temperature: o += [("Text", "%1°"), ("NumOfDecimals", "0")]
            case .text: break
            }
            for (k, v) in extra {
                if let i = o.firstIndex(where: { $0.0.caseInsensitiveCompare(k) == .orderedSame }) { o[i].1 = v } else { o.append((k, v)) }
            }
            return section(n, o)
        }
        switch look {
        case .number:
            result.append(number(name("Meter\(short)"), x: px, y: py))
        case .bar:
            result.append(section(name("Meter\(short)Bar"), [
                ("Meter", "Bar"), ("MeasureName", measure), ("X", px), ("Y", py), ("W", "160"), ("H", "6"),
                ("BarColor", ink.accent), ("SolidColor", ink.track), ("BarOrientation", "Horizontal")]))
        case .ring:
            result.append(section(name("Meter\(short)RingTrack"), [
                ("Meter", "Shape"), ("X", px), ("Y", py),
                ("Shape", "Ellipse 32,32,29 | Fill Color 0,0,0,0 | StrokeWidth 6 | Stroke Color \(ink.track)")]))
            result.append(section(name("Meter\(short)Ring"), [
                ("Meter", "Roundline"), ("MeasureName", measure), ("X", px), ("Y", py), ("W", "64"), ("H", "64"),
                ("StartAngle", "(Rad(270))"), ("RotationAngle", "(Rad(360))"), ("LineStart", "26"),
                ("LineLength", "32"), ("LineColor", ink.accent), ("Solid", "1"), ("AntiAlias", "1")]))
            result.append(number(name("Meter\(short)RingValue"), x: GeometryEdit.format(x + 32),
                                 y: GeometryEdit.format(y + 32),
                                 extra: [("StringAlign", "CenterCenter"), ("FontWeight", "600")]))
        case .graph:
            result.append(section(name("Meter\(short)Graph"), [
                ("Meter", "Line"), ("MeasureName", measure), ("X", px), ("Y", py), ("W", "160"), ("H", "40"),
                ("LineColor", ink.accent), ("LineWidth", "1.5"), ("AntiAlias", "1")]))
        }
        return result
    }

    /// The sections of a part (bars, rings and graphs start with the CPU's usage, which the page can change).
    public static func sections(part: Part, x: Double, y: Double, existing: Set<String>, variables: Set<String>)
        -> [EditorComponents.Section] {
        switch part {
        case .text, .picture, .bar, .ring, .graph, .shape:
            let id: String
            switch part {
            case .text: id = "text"
            case .picture: id = "image"
            case .bar: id = "cpu"
            case .ring: id = "ring"
            case .graph: id = "graph"
            default: id = "rectangle"
            }
            return EditorComponents.sections(for: id, x: x, y: y, existing: existing, variables: variables)
        case .symbol:
            return symbolSections("star.fill", x: x, y: y, existing: existing, variables: variables)
        case .button:
            let ink = Inks(variables: variables)
            let name = EditorComponents.uniqueName("MeterButton", taken: Set(existing.map { $0.lowercased() }))
            return [section(name, [("Meter", "String"), ("Text", "Button"), ("X", GeometryEdit.format(x)),
                                   ("Y", GeometryEdit.format(y)), ("FontColor", ink.text), ("FontSize", "12"),
                                   ("SolidColor", ink.track), ("Padding", "12,5,12,5")] + ink.font)]
        }
    }

    /// An SF Symbol drawn 24 points high in the widget's text color.
    public static func symbolSections(_ symbol: String, x: Double, y: Double, existing: Set<String>,
                                      variables: Set<String>) -> [EditorComponents.Section] {
        let ink = Inks(variables: variables)
        let name = EditorComponents.uniqueName("MeterSymbol", taken: Set(existing.map { $0.lowercased() }))
        return [section(name, [("Meter", "Image"), ("ImageName", "sf:" + symbol), ("X", GeometryEdit.format(x)),
                               ("Y", GeometryEdit.format(y)), ("MacSymbolSize", "24"), ("ImageTint", ink.text)])]
    }

    // MARK: The widget's own data

    /// The measure of the widget that already reads data item `id` (so a new part reads it too), or nil.
    public static func existingMeasure(for id: String, in skin: Skin) -> String? {
        guard let item = dataItem(id), item.category == .mac else { return nil }
        let wanted = Dictionary(item.measure.map { ($0.key.lowercased(), $0.value.lowercased()) },
                                uniquingKeysWith: { a, _ in a })
        for m in skin.measures {
            var same = true
            for (key, value) in wanted {
                let own = (m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if own != value, !(key == "processor" && own.isEmpty && value == "0"),
                   !(key == "interface" && own.isEmpty && value == "0") {
                    same = false
                    break
                }
            }
            // A measure of the total or free amount reads something else.
            if same, m.rawOption("Total").map({ $0.trimmingCharacters(in: .whitespaces) == "1" }) == true { same = false }
            if same, id == "memory" || id == "disk",
               (m.rawOption("InvertMeasure") ?? "0").trimmingCharacters(in: .whitespaces) != (wanted["invertmeasure"] ?? "0") {
                same = false
            }
            if same { return m.name }
        }
        return nil
    }

    /// The data items `query` finds (a word of the title, a keyword or the category), in the page's order.
    public static func search(_ query: String, titles: (DataItem) -> String = { $0.title }) -> [DataItem] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }
        guard !terms.isEmpty else { return data }
        return data.filter { item in
            let words = ([titles(item), item.title, item.category.rawValue] + item.keywords).map(fold)
            return terms.allSatisfy { t in words.contains { $0.contains(t) } }
        }
    }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

extension StudioAddCatalog {
    /// A copy of a section under a new name (⌘D): its own options as written, the first of each key.
    public static func copy(of section: IniSection, named name: String) -> EditorComponents.Section {
        var seen: Set<String> = []
        let options = section.entries.filter { seen.insert($0.key.lowercased()).inserted }.map { (key: $0.key, value: $0.value) }
        return EditorComponents.Section(name: name, options: options)
    }
}
