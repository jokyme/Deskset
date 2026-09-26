import Foundation

// MARK: - Removing a section

extension IniWriter {
    /// Removes every `[section]` block of the file (header and every line up to the next header), keeping the rest
    /// byte for byte. Comment lines right before the next header stay (they usually describe that section). A file
    /// can repeat a header: readers use the first block and ignore the others, which would become the section
    /// after the first one is gone, so they go too. Nothing is written when the section is not there.
    public static func removeSection(_ section: String, fileURL: URL) throws {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { throw IniWriterError.fileNotFound(fileURL.path) }
        let (text, encoding) = try TextDecoding.readFileDetectingEncoding(at: target)
        let updated = removingSection(text, section: section)
        if updated.utf8.elementsEqual(text.utf8) { return }
        let data = TextDecoding.encodeForWriting(updated, preferring: encoding)
        try data.write(to: target, options: .atomic)
    }

    /// The text-level operation behind `removeSection`: every block of `section` removed.
    public static func removingSection(_ text: String, section: String) -> String {
        var current = text
        while true {
            let next = removingFirstSection(current, section: section)
            if next.utf8.elementsEqual(current.utf8) { return current }
            current = next
        }
    }

    /// Whether the text has a `[section]` header.
    public static func definesSection(_ text: String, section: String) -> Bool {
        var found = false
        IniSyntax.forEachLineWithTerminator(in: text) { content, _ in
            guard !found, case .section(let name) = IniSyntax.classify(content), let name else { return }
            if IniSyntax.namesEqual(name, section) { found = true }
        }
        return found
    }

    /// The first block of `section` removed (the text unchanged when there is none).
    static func removingFirstSection(_ text: String, section: String) -> String {
        var lines: [(content: Substring, terminator: Substring)] = []
        IniSyntax.forEachLineWithTerminator(in: text) { lines.append(($0, $1)) }
        var start: Int?
        var end = lines.count
        for (i, line) in lines.enumerated() {
            guard case .section(let name) = IniSyntax.classify(line.content) else { continue }
            if start != nil { end = i; break }
            if let name, IniSyntax.namesEqual(name, section) { start = i }
        }
        guard let start else { return text }
        // Keep the comment block that introduces the next section.
        var cut = end
        while cut > start + 1, case .comment = IniSyntax.classify(lines[cut - 1].content) { cut -= 1 }
        // The block's own trailing blank lines go with it (the blank line before it keeps sections apart). At the
        // end of the file the blank lines before it go too, so no blank tail is left behind.
        var removed = Array(start..<cut)
        if cut == lines.count {
            var i = start - 1
            while i >= 0, IniSyntax.classify(lines[i].content).isBlank { removed.append(i); i -= 1 }
        }
        let drop = Set(removed)
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for (i, line) in lines.enumerated() where !drop.contains(i) {
            out += line.content
            out += line.terminator
        }
        return out
    }
}

extension IniSyntax.Line {
    var isBlank: Bool { if case .blank = self { return true } else { return false } }
}

// MARK: - Components

/// Ready-made meters (with the measures they need) that the editor's component library inserts into a skin. All
/// originals; colors and fonts use the skin's own variables when it defines the usual ones (`TextColor`, `FontFace`,
/// `AccentColor`…), so a component dropped into a themed skin matches it.
///
/// Every component is laid out from its top-left corner (x, y) and covers about `defaultSize` from there: the canvas
/// shows a ghost of that size while a component is dragged over it, and the drop lands where the ghost was.
public enum EditorComponents {
    /// Library sections, in display order.
    public enum Category: String, CaseIterable, Equatable {
        case text, data, graphs, gauges, shapes, images

        public var title: String {
            switch self {
            case .text: return "Text"
            case .data: return "Live Data"
            case .graphs: return "Graphs"
            case .gauges: return "Gauges"
            case .shapes: return "Shapes"
            case .images: return "Pictures"
            }
        }

        public var symbol: String {
            switch self {
            case .text: return "textformat"
            case .data: return "waveform.path.ecg"
            case .graphs: return "chart.xyaxis.line"
            case .gauges: return "gauge.with.dots.needle.33percent"
            case .shapes: return "square.on.circle"
            case .images: return "photo"
            }
        }
    }

    /// A size in points (skin coordinates).
    public struct Size: Equatable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct Component: Equatable {
        public var id: String
        public var title: String
        public var symbol: String
        public var summary: String
        public var category: Category
        /// What the component covers when inserted, from (x, y). Text components: their usual size in the system
        /// font (the text itself decides the final size).
        public var defaultSize: Size
        /// The data it shows, in a word ("CPU", "Memory"); nil for plain text, shapes and pictures.
        public var badge: String?
        /// More words search finds it by: synonyms and the Rainmeter meter / measure types it uses, so people who
        /// know skins by their INI names find things too ("Roundline" finds the gauges).
        public var keywords: [String]
        /// Uses measures the app registers (NowPlaying, WiFiStatus): DesksetCore alone reports them as unsupported.
        public var needsAppMeasures: Bool

        init(_ id: String, _ title: String, _ symbol: String, _ category: Category, _ summary: String,
             size: (Double, Double), badge: String? = nil, keywords: [String] = [], needsAppMeasures: Bool = false) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.summary = summary
            self.category = category
            self.defaultSize = Size(width: size.0, height: size.1)
            self.badge = badge
            self.keywords = keywords
            self.needsAppMeasures = needsAppMeasures
        }
    }

    /// One section to write, options in order.
    public struct Section: Equatable {
        public var name: String
        public var options: [(key: String, value: String)]

        public static func == (a: Section, b: Section) -> Bool {
            a.name == b.name && a.options.map(\.key) == b.options.map(\.key) && a.options.map(\.value) == b.options.map(\.value)
        }
    }

    /// Every component, grouped by category in `Category` order (the library's "All" shows them in this order).
    /// Text sizes were measured with the app's renderer (system font; a Rainmeter `FontSize` is in points at 96 DPI,
    /// so 13 is a 17.3-pixel font) with typical values; the app self-test keeps them in step.
    public static let all: [Component] = [
        Component("text", "Text", "textformat", .text, "A line of text", size: (46, 20),
                  keywords: ["String", "label", "title", "heading"]),
        Component("clock", "Clock", "clock", .text, "The time, updated every second", size: (158, 43),
                  badge: "Time", keywords: ["Time", "String", "hours", "minutes"]),
        Component("date", "Date", "calendar", .text, "Weekday and date", size: (196, 20),
                  badge: "Date", keywords: ["Time", "String", "day", "calendar"]),
        Component("labelvalue", "Label and Value", "list.bullet.rectangle", .text,
                  "A name on the left, its value on the right", size: (160, 20),
                  badge: "CPU", keywords: ["String", "pair", "row", "caption", "processor"]),

        Component("network", "Network Speed", "arrow.up.arrow.down", .data, "Download and upload per second",
                  size: (198, 20), badge: "Network", keywords: ["NetIn", "NetOut", "String", "internet", "bandwidth"]),
        Component("disk", "Disk Space", "internaldrive", .data, "Free space on the startup disk", size: (114, 20),
                  badge: "Disk", keywords: ["FreeDiskSpace", "String", "storage", "drive", "volume"]),
        Component("battery", "Battery", "battery.75", .data, "Charge level with a battery icon", size: (73, 20),
                  badge: "Battery", keywords: ["PowerPlugin", "Plugin", "Shape", "power", "charge"]),
        Component("uptime", "Uptime", "timer", .data, "How long the Mac has been running", size: (115, 20),
                  badge: "Uptime", keywords: ["Uptime", "String", "startup", "boot"]),
        Component("wifi", "Wi-Fi Signal", "wifi", .data, "Strength of the Wi\u{2011}Fi connection", size: (88, 20),
                  badge: "Wi-Fi", keywords: ["WiFiStatus", "wireless", "network", "quality"], needsAppMeasures: true),
        Component("nowplaying", "Now Playing", "music.note", .data, "The song and artist playing now",
                  size: (200, 43), badge: "Music", keywords: ["NowPlaying", "song", "track", "artist", "Spotify"],
                  needsAppMeasures: true),

        Component("graph", "CPU Graph", "chart.xyaxis.line", .graphs, "Processor usage over time", size: (160, 40),
                  badge: "CPU", keywords: ["Line", "chart", "history", "processor"]),
        Component("cpu", "CPU Bar", "cpu", .graphs, "Processor usage as a bar", size: (160, 6),
                  badge: "CPU", keywords: ["Bar", "processor", "usage"]),
        Component("memory", "Memory Bar", "memorychip", .graphs, "Memory in use as a bar", size: (160, 6),
                  badge: "Memory", keywords: ["Bar", "PhysicalMemory", "RAM"]),
        Component("progress", "Progress Bar", "rectangle.lefthalf.filled", .graphs,
                  "A rounded bar that fills up with disk use", size: (160, 8),
                  badge: "Disk", keywords: ["Shape", "FreeDiskSpace", "bar", "level", "fill", "storage"]),

        Component("gauge", "CPU Gauge", "gauge.with.dots.needle.33percent", .gauges, "A dial for processor usage",
                  size: (64, 64), badge: "CPU", keywords: ["Roundline", "dial", "meter", "processor"]),
        Component("ring", "CPU Ring", "chart.pie", .gauges, "Processor usage as a ring",
                  size: (64, 64), badge: "CPU", keywords: ["Roundline", "Shape", "donut", "circle", "processor"]),

        Component("rectangle", "Rounded Box", "rectangle", .shapes, "A rounded shape for backgrounds",
                  size: (120, 48), keywords: ["Shape", "Rectangle", "box", "background", "panel", "card"]),
        Component("circle", "Circle", "circle", .shapes, "A filled circle", size: (48, 48),
                  keywords: ["Shape", "Ellipse", "dot", "round"]),
        Component("divider", "Divider Line", "minus", .shapes, "A thin line between sections", size: (160, 1),
                  keywords: ["Shape", "Line", "separator", "rule"]),

        Component("image", "Image", "photo", .images, "A picture from the widget's folder", size: (64, 64),
                  keywords: ["Image", "picture", "photo", "icon", "logo"]),
        Component("albumart", "Album Art", "music.note.list", .images, "Cover of the song that is playing",
                  size: (64, 64), badge: "Music", keywords: ["NowPlaying", "Image", "cover", "artwork", "Spotify"],
                  needsAppMeasures: true),
    ]

    /// The component with `id`.
    public static func component(_ id: String) -> Component? {
        all.first { $0.id == id }
    }

    /// Components in `category` (nil = all) matching `query`: every word of the query must start a word of the
    /// title, badge, keywords or category, or appear in the title or summary. Best matches first (title words that
    /// start with the query, then titles containing it, then badges and keywords, then summaries), otherwise in
    /// library order — so Return in the search field inserts what the user most likely meant.
    public static func search(_ query: String, category: Category? = nil) -> [Component] {
        let pool = all.filter { category == nil || $0.category == category }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { fold(String($0)) }
        guard !terms.isEmpty else { return pool }
        var found: [(score: Int, index: Int, component: Component)] = []
        for (index, c) in pool.enumerated() {
            var total = 0
            var matches = true
            for term in terms {
                guard let s = score(term, c) else { matches = false; break }
                total += s
            }
            if matches { found.append((total, index, c)) }
        }
        return found.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.component)
    }

    /// Lower-cased, without diacritics ("Écran" matches "ecran").
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// 0 best … 3 weakest; nil when `term` does not match.
    private static func score(_ term: String, _ c: Component) -> Int? {
        if words(c.title).contains(where: { $0.hasPrefix(term) }) { return 0 }
        if fold(c.title).contains(term) { return 1 }
        let tags = ([c.badge ?? "", c.category.title] + c.keywords).flatMap(words)
        if tags.contains(where: { $0.hasPrefix(term) }) || c.keywords.contains(where: { fold($0).hasPrefix(term) }) {
            return 2
        }
        if fold(c.summary).contains(term) { return 3 }
        return nil
    }

    /// The sections for component `id` with its top-left corner at (x, y), with names not yet used in the skin
    /// (`existing` and `variables` are lowercased). An unknown id gives a Text component.
    public static func sections(for id: String, x: Double, y: Double, existing: Set<String>, variables: Set<String>) -> [Section] {
        var taken = Set(existing.map { $0.lowercased() })
        func name(_ base: String) -> String {
            let n = uniqueName(base, taken: taken)
            taken.insert(n.lowercased())
            return n
        }
        func has(_ v: String) -> Bool { variables.contains(v.lowercased()) }
        let text = has("TextColor") ? "#TextColor#" : has("FontColor") ? "#FontColor#" : "255,255,255,235"
        let subtle = has("SubtleColor") ? "#SubtleColor#" : "255,255,255,150"
        let accent = has("AccentColor") ? "#AccentColor#" : "110,190,255,255"
        let track = has("TrackColor") ? "#TrackColor#" : "255,255,255,40"
        let fill = has("AccentColor") ? "#AccentColor#" : "110,190,255,90"
        let line = has("TrackColor") ? "#TrackColor#" : "255,255,255,64"
        let placeholder = "255,255,255,26"
        var font: [(String, String)] = has("FontFace") ? [("FontFace", "#FontFace#")] : []
        font.append(("AntiAlias", "1"))
        let px = GeometryEdit.format(x), py = GeometryEdit.format(y)
        /// Positions relative to the component's corner.
        func ox(_ d: Double) -> String { GeometryEdit.format(x + d) }
        func oy(_ d: Double) -> String { GeometryEdit.format(y + d) }

        /// A String meter at the corner; `extra` replaces options in place (so X and Y stay at the top) or adds them.
        func stringMeter(_ n: String, measure: String?, extra: [(String, String)]) -> Section {
            var o: [(String, String)] = [("Meter", "String")]
            if let measure { o.append(("MeasureName", measure)) }
            o += [("X", px), ("Y", py), ("FontColor", text), ("FontSize", "13")] + font
            for (key, value) in extra {
                if let i = o.firstIndex(where: { $0.0.caseInsensitiveCompare(key) == .orderedSame }) {
                    o[i].1 = value
                } else {
                    o.append((key, value))
                }
            }
            return Section(name: n, options: o.map { (key: $0.0, value: $0.1) })
        }
        func section(_ n: String, _ o: [(String, String)]) -> Section { Section(name: n, options: o.map { (key: $0.0, value: $0.1) }) }
        func cpuMeasure() -> Section { section(name("MeasureCPU"), [("Measure", "CPU"), ("Processor", "0")]) }

        switch id {
        case "clock":
            let m = name("MeasureTime")
            return [section(m, [("Measure", "Time"), ("Format", "%H:%M:%S")]),
                    stringMeter(name("MeterClock"), measure: m, extra: [("FontSize", "28"), ("FontWeight", "300")])]
        case "date":
            let m = name("MeasureDate")
            return [section(m, [("Measure", "Time"), ("Format", "%A, %#d %B")]),
                    stringMeter(name("MeterDate"), measure: m, extra: [("FontColor", subtle)])]
        case "labelvalue":
            // The value is right-aligned at the far end, so longer values grow to the left.
            let m = cpuMeasure()
            return [m,
                    stringMeter(name("MeterCPULabel"), measure: nil, extra: [("FontColor", subtle), ("Text", "CPU")]),
                    stringMeter(name("MeterCPUValue"), measure: m.name,
                                extra: [("X", ox(160)), ("StringAlign", "Right"), ("Text", "%1%")])]
        case "cpu", "memory":
            let cpu = id == "cpu"
            let m = name(cpu ? "MeasureCPU" : "MeasureMemory")
            return [section(m, cpu ? [("Measure", "CPU"), ("Processor", "0")] : [("Measure", "PhysicalMemory")]),
                    section(name(cpu ? "MeterCPUBar" : "MeterMemoryBar"),
                            [("Meter", "Bar"), ("MeasureName", m), ("X", px), ("Y", py), ("W", "160"), ("H", "6"),
                             ("BarColor", accent), ("SolidColor", track), ("BarOrientation", "Horizontal")])]
        case "progress":
            // One Shape: a rounded track and a rounded fill whose width follows the measure's percentage
            // (section variables need DynamicVariables=1). The fill never gets narrower than its own corners.
            let m = name("MeasureDiskUsed")
            return [section(m, [("Measure", "FreeDiskSpace"), ("Drive", "/"), ("InvertMeasure", "1")]),
                    section(name("MeterDiskProgress"),
                            [("Meter", "Shape"), ("X", px), ("Y", py),
                             ("Shape", "Rectangle 0,0,160,8,4 | Fill Color \(track) | StrokeWidth 0"),
                             ("Shape2", "Rectangle 0,0,(Max(8, 160 * [\(m):%] / 100)),8,4 | Fill Color \(accent) | StrokeWidth 0"),
                             ("DynamicVariables", "1")])]
        case "network":
            let down = name("MeasureNetIn"), up = name("MeasureNetOut")
            return [section(down, [("Measure", "NetIn"), ("Interface", "0")]),
                    section(up, [("Measure", "NetOut"), ("Interface", "0")]),
                    stringMeter(name("MeterNetwork"), measure: down,
                                extra: [("MeasureName2", up), ("Text", "↓ %1B/s   ↑ %2B/s"), ("AutoScale", "1"),
                                        ("NumOfDecimals", "1")])]
        case "graph":
            let m = cpuMeasure()
            return [m,
                    section(name("MeterCPUGraph"), [("Meter", "Line"), ("MeasureName", m.name), ("X", px), ("Y", py),
                                                    ("W", "160"), ("H", "40"), ("LineColor", accent), ("LineWidth", "1.5"),
                                                    ("AntiAlias", "1")])]
        case "gauge":
            // A 270° dial open at the bottom: the track (a Shape arc of radius 27 from 135° to 45° through the top,
            // 6 pt wide), the used part over the same 24…30 pt band (Roundline) and the percentage in the middle.
            let m = cpuMeasure()
            return [m,
                    section(name("MeterGaugeTrack"), [("Meter", "Shape"), ("X", px), ("Y", py),
                                                      ("Shape", "Arc 12.91,51.09,51.09,51.09,27,27,0,0,1 | Fill Color 0,0,0,0 | StrokeWidth 6 | Stroke Color \(track)")]),
                    section(name("MeterGauge"), [("Meter", "Roundline"), ("MeasureName", m.name), ("X", px), ("Y", py),
                                                 ("W", "64"), ("H", "64"), ("StartAngle", "(Rad(135))"),
                                                 ("RotationAngle", "(Rad(270))"), ("LineStart", "24"), ("LineLength", "30"),
                                                 ("LineColor", accent), ("Solid", "1"), ("AntiAlias", "1")]),
                    stringMeter(name("MeterGaugeValue"), measure: m.name,
                                extra: [("X", ox(32)), ("Y", oy(32)), ("StringAlign", "CenterCenter"), ("FontWeight", "600"),
                                        ("Text", "%1%")])]
        case "ring":
            // A full-circle track (Shape), the used part from twelve o'clock clockwise (Roundline over the same
            // 26…32 pt band) and the percentage in the middle.
            let m = cpuMeasure()
            return [m,
                    section(name("MeterCPURingTrack"), [("Meter", "Shape"), ("X", px), ("Y", py),
                                                        ("Shape", "Ellipse 32,32,29 | Fill Color 0,0,0,0 | StrokeWidth 6 | Stroke Color \(track)")]),
                    section(name("MeterCPURing"), [("Meter", "Roundline"), ("MeasureName", m.name), ("X", px), ("Y", py),
                                                   ("W", "64"), ("H", "64"), ("StartAngle", "(Rad(270))"),
                                                   ("RotationAngle", "(Rad(360))"), ("LineStart", "26"), ("LineLength", "32"),
                                                   ("LineColor", accent), ("Solid", "1"), ("AntiAlias", "1")]),
                    stringMeter(name("MeterCPURingValue"), measure: m.name,
                                extra: [("X", ox(32)), ("Y", oy(32)), ("StringAlign", "CenterCenter"), ("FontWeight", "600"),
                                        ("Text", "%1%")])]
        case "disk":
            let m = name("MeasureDiskFree")
            return [section(m, [("Measure", "FreeDiskSpace"), ("Drive", "/")]),
                    stringMeter(name("MeterDisk"), measure: m,
                                extra: [("Text", "%1B free"), ("AutoScale", "1"), ("NumOfDecimals", "1")])]
        case "battery":
            // A battery outline whose level follows the charge (Shape3 reads the measure's value, hence
            // DynamicVariables=1), then the percentage.
            let m = name("MeasureBattery")
            return [section(m, [("Measure", "Plugin"), ("Plugin", "PowerPlugin"), ("PowerState", "Percent")]),
                    section(name("MeterBatteryIcon"),
                            [("Meter", "Shape"), ("X", px), ("Y", oy(2)),
                             ("Shape", "Rectangle 0.5,0.5,23,12,3 | Fill Color 0,0,0,0 | StrokeWidth 1 | Stroke Color \(subtle)"),
                             ("Shape2", "Rectangle 24,4,2,5,1 | Fill Color \(subtle) | StrokeWidth 0"),
                             ("Shape3", "Rectangle 2.5,2.5,(19 * [\(m):] / 100),8,1.5 | Fill Color \(text) | StrokeWidth 0"),
                             ("DynamicVariables", "1")]),
                    stringMeter(name("MeterBattery"), measure: m, extra: [("X", ox(32)), ("Text", "%1%")])]
        case "uptime":
            let m = name("MeasureUptime")
            return [section(m, [("Measure", "Uptime"), ("Format", "%4!i!d %3!i!h %2!02i!m")]),
                    stringMeter(name("MeterUptime"), measure: m, extra: [("Text", "Up %1")])]
        case "wifi":
            // Signal quality needs no permission (the network name would ask for Location Services).
            let m = name("MeasureWiFi")
            return [section(m, [("Measure", "WiFiStatus"), ("WiFiInfoType", "Quality")]),
                    stringMeter(name("MeterWiFi"), measure: m, extra: [("Text", "Wi-Fi %1%")])]
        case "nowplaying":
            // The artist measure shares the title measure's player. Fixed sizes with ClipString keep the layout
            // steady when a long title plays or nothing does.
            let title = name("MeasureNowPlaying"), artist = name("MeasureNowPlayingArtist")
            return [section(title, [("Measure", "NowPlaying"), ("PlayerName", "iTunes"), ("PlayerType", "Title"),
                                    ("Substitute", "\"\":\"Not playing\"")]),
                    section(artist, [("Measure", "NowPlaying"), ("PlayerName", "[\(title)]"), ("PlayerType", "Artist")]),
                    stringMeter(name("MeterNowPlaying"), measure: title,
                                extra: [("W", "200"), ("H", "23"), ("ClipString", "1"), ("FontSize", "14"),
                                        ("FontWeight", "600")]),
                    stringMeter(name("MeterNowPlayingArtist"), measure: artist,
                                extra: [("Y", oy(23)), ("W", "200"), ("H", "20"), ("ClipString", "1"),
                                        ("FontColor", subtle), ("FontSize", "12")])]
        case "rectangle":
            return [section(name("MeterRectangle"),
                            [("Meter", "Shape"), ("X", px), ("Y", py),
                             ("Shape", "Rectangle 0,0,120,48,8 | Fill Color \(fill) | StrokeWidth 0")])]
        case "circle":
            return [section(name("MeterCircle"),
                            [("Meter", "Shape"), ("X", px), ("Y", py),
                             ("Shape", "Ellipse 24,24,24 | Fill Color \(fill) | StrokeWidth 0")])]
        case "divider":
            // Half-point offsets keep a 1-point line on whole pixels.
            return [section(name("MeterDivider"),
                            [("Meter", "Shape"), ("X", px), ("Y", py),
                             ("Shape", "Line 0,0.5,160,0.5 | StrokeWidth 1 | Stroke Color \(line)")])]
        case "image":
            // No picture yet (chosen in the inspector); the faint square shows where it goes.
            return [section(name("MeterImage"),
                            [("Meter", "Image"), ("X", px), ("Y", py), ("W", "64"), ("H", "64"),
                             ("PreserveAspectRatio", "1"), ("SolidColor", placeholder)])]
        case "albumart":
            let m = name("MeasureNowPlayingCover")
            return [section(m, [("Measure", "NowPlaying"), ("PlayerName", "iTunes"), ("PlayerType", "Cover")]),
                    section(name("MeterAlbumArt"),
                            [("Meter", "Image"), ("MeasureName", m), ("X", px), ("Y", py), ("W", "64"), ("H", "64"),
                             ("PreserveAspectRatio", "2"), ("SolidColor", placeholder)])]
        default:
            return [stringMeter(name("MeterText"), measure: nil, extra: [("Text", "Hello")])]
        }
    }

    /// `base`, or `base2`, `base3`… — the first name not in `taken` (lowercased names).
    public static func uniqueName(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base.lowercased()) { return base }
        var i = 2
        while taken.contains("\(base)\(i)".lowercased()) { i += 1 }
        return "\(base)\(i)"
    }

    /// A new data source of a measure type or plugin (`EditorSchema.measureTypes`): `[MeasureCPU]`,
    /// `[MeasureBattery2]`… (`existing`: the skin's lowercased section names) with `Measure=` — or `Measure=Plugin` and
    /// `Plugin=` — and the few options a type needs to show a value right away.
    public static func measureSection(_ type: EditorSchema.MeasureType, existing: Set<String>) -> Section {
        var base = type.name
        if base.hasSuffix("Plugin"), base.count > "Plugin".count { base.removeLast("Plugin".count) }
        let name = uniqueName("Measure" + base, taken: existing)
        var options: [(key: String, value: String)] = type.isPlugin
            ? [(key: "Measure", value: "Plugin"), (key: "Plugin", value: type.name)]
            : [(key: "Measure", value: type.name)]
        switch type.name {
        case "Time": options.append((key: "Format", value: "%H:%M"))
        case "Calc": options.append((key: "Formula", value: "0"))
        case "String": options.append((key: "String", value: "Text"))
        case "PowerPlugin": options.append((key: "PowerState", value: "Percent"))
        default: break
        }
        return Section(name: name, options: options)
    }
}

// MARK: - Align and distribute

/// Target frames for aligning / distributing selected meters. With one meter, alignment is to the skin.
public enum EditorAlign {
    public enum Mode: String, CaseIterable, Equatable {
        case left, centerX, right, top, centerY, bottom, distributeX, distributeY
    }

    /// New frames (same order as `frames`); nil when the mode needs more meters (distribute needs 3).
    public static func frames(_ frames: [SkinRect], mode: Mode, skin: SkinRect) -> [SkinRect]? {
        guard !frames.isEmpty else { return nil }
        let box: SkinRect
        if frames.count == 1 {
            box = skin
        } else {
            let minX = frames.map(\.x).min()!, minY = frames.map(\.y).min()!
            let maxX = frames.map { $0.x + $0.width }.max()!, maxY = frames.map { $0.y + $0.height }.max()!
            box = SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        func r(_ v: Double) -> Double { v.rounded() }
        switch mode {
        case .left: return frames.map { SkinRect(x: box.x, y: $0.y, width: $0.width, height: $0.height) }
        case .right: return frames.map { SkinRect(x: box.x + box.width - $0.width, y: $0.y, width: $0.width, height: $0.height) }
        case .centerX: return frames.map { SkinRect(x: r(box.x + (box.width - $0.width) / 2), y: $0.y, width: $0.width, height: $0.height) }
        case .top: return frames.map { SkinRect(x: $0.x, y: box.y, width: $0.width, height: $0.height) }
        case .bottom: return frames.map { SkinRect(x: $0.x, y: box.y + box.height - $0.height, width: $0.width, height: $0.height) }
        case .centerY: return frames.map { SkinRect(x: $0.x, y: r(box.y + (box.height - $0.height) / 2), width: $0.width, height: $0.height) }
        case .distributeX, .distributeY:
            guard frames.count >= 3 else { return nil }
            let horizontal = mode == .distributeX
            let order = frames.indices.sorted { horizontal ? frames[$0].x < frames[$1].x : frames[$0].y < frames[$1].y }
            let total = frames.reduce(0) { $0 + (horizontal ? $1.width : $1.height) }
            let span = horizontal ? box.width : box.height
            let gap = (span - total) / Double(frames.count - 1)
            var result = frames
            var pos = horizontal ? box.x : box.y
            for i in order {
                if horizontal { result[i].x = r(pos) } else { result[i].y = r(pos) }
                pos += (horizontal ? frames[i].width : frames[i].height) + gap
            }
            return result
        }
    }
}

// MARK: - Skin edits

extension Skin {
    /// Appends `sections` to the skin file (each at the end, in order).
    public func appendSections(_ sections: [EditorComponents.Section]) throws {
        for s in sections {
            for o in s.options { try IniWriter.writeValue(o.value, key: o.key, section: s.name, fileURL: fileURL) }
        }
    }

    /// The skin's files with a `[name]` block: the file holding its header first, then any other source file that
    /// adds to it (an @Include file's block of the same name is merged into the section).
    public func definingFiles(ofSection name: String) -> [URL] {
        let sectionName = document.section(named: name)?.name ?? name
        let header = sources.location(section: sectionName)?.file ?? fileURL
        var result = [header]
        let key = header.standardizedFileURL.resolvingSymlinksInPath().path
        var seen: Set<String> = [key]
        for url in sourceFiles {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted, let text = try? TextDecoding.readFile(at: url),
                  IniWriter.definesSection(text, section: sectionName) else { continue }
            result.append(url)
        }
        return result
    }

    /// Removes a section: every block of it, from every file that defines one (`definingFiles(ofSection:)`), so no
    /// ignored duplicate or included block brings it back after the refresh.
    public func removeSection(_ name: String) throws {
        let sectionName = document.section(named: name)?.name ?? name
        for file in definingFiles(ofSection: sectionName) {
            try IniWriter.removeSection(sectionName, fileURL: file)
        }
    }

    /// The sections a duplicate of `name` needs: its own options under a new name, moved by (dx, dy).
    public func duplicateSections(_ name: String, dx: Double, dy: Double, taken: inout Set<String>) -> EditorComponents.Section? {
        guard let s = document.section(named: name) else { return nil }
        let newName = EditorComponents.uniqueName(s.name, taken: taken)
        taken.insert(newName.lowercased())
        var options = s.entries.map { (key: $0.key, value: $0.value) }
        func shift(_ key: String, _ d: Double) {
            if let i = options.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                options[i].value = GeometryEdit.offset(options[i].value, by: d)
            } else if let m = meter(named: name), let raw = m.rawOption(key) {
                options.append((key: key, value: GeometryEdit.offset(raw, by: d)))
            } else {
                options.append((key: key, value: GeometryEdit.format(d)))
            }
        }
        shift("X", dx)
        shift("Y", dy)
        return EditorComponents.Section(name: newName, options: options)
    }

    /// Lowercased names of every section (for picking new names).
    public var sectionNames: Set<String> { Set(document.sections.map { $0.name.lowercased() }) }

    /// Lowercased `[Variables]` names.
    public var variableNames: Set<String> {
        Set((document.section(named: "Variables")?.entries ?? []).map { $0.key.lowercased() })
    }
}
