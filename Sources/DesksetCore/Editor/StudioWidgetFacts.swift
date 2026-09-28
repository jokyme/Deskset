import Foundation

/// What the Studio's widget page (nothing selected) says about an INI widget, worked out once from its loaded skin and
/// `ValueUsageIndex`: its name and sentence; the author's options (typed `[Variables]` entries a part uses); what its
/// data parts show; its colors by role (the parts' colors, Text, Card, the rest); its fonts by role; every text size
/// A− / A+ scales; its look and its sizes. The page generator turns these into rows; writes go through the editing
/// session, to the places named here (a `[Variables]` entry, a look, a section's own option).
public struct StudioWidgetFacts {
    // MARK: Colors

    /// What a color of the widget is for on the page.
    public enum ColorKind: Equatable {
        /// A part's color (a ring, a bar, a symbol): one of the first swatches.
        case part
        /// The text's color ("follows the look" until changed).
        case text
        /// The card's color (the background layer's fill or glass tint).
        case card
        /// A color used for words and drawings alike (an accent): an option of its own.
        case accent
        /// Everything else: under More….
        case other
    }

    /// One color of the widget with what it paints and where a change is written.
    public struct ColorRole: Equatable {
        public var kind: ColorKind
        public var group: ValueUsageIndex.ColorGroup
        /// The color in effect.
        public var color: RGBA
        /// A short word for what it paints ("Memory"), under its swatch.
        public var label: String
        /// What it paints, as a title ("Memory ring"), for the color popover.
        public var title: String
        /// The kind of data part it paints ("ring", "bar"), when it paints one.
        public var partKind: String?
        /// The parts it paints that are shown (for the outline on the canvas).
        public var meters: [String]
        /// How many parts that is, as a person counts them: a symbol inside a ring is part of the ring.
        public var parts: Int
        /// The `[Variables]` entry a change writes; nil: the color is written in the options themselves.
        public var variable: String?
        /// Whether the written value may carry an alpha (false when it is used as `#Name#,alpha`).
        public var acceptsAlpha: Bool
        /// Whether it comes from a file the look chooses (a theme): the swatch shows "follow the look" until it is
        /// changed for this widget.
        public var followsLook: Bool
    }

    public struct Colors: Equatable {
        /// The parts' colors, the most used first (the page shows up to four).
        public var parts: [ColorRole] = []
        public var text: ColorRole?
        public var card: ColorRole?
        /// Colors used for words and drawings alike (they are options).
        public var accents: [ColorRole] = []
        public var others: [ColorRole] = []

        /// Every color, in the order More… lists them.
        public var all: [ColorRole] { parts + [text, card].compactMap { $0 } + accents + others }
    }

    // MARK: Options

    /// What kind of value an option takes.
    public enum OptionKind: Equatable {
        case color
        /// An alpha, 0–255, shown as a percentage.
        case alpha
        /// 0 or 1.
        case toggle
        /// One of these values.
        case choice([String])
        /// The hours of a time format: 12 or 24 (the letter of `%H` / `%I` is what changes).
        case hours(twentyFour: Bool)
    }

    /// An option the widget's author gave it: a `[Variables]` entry, or a time format's hours.
    public struct Option: Equatable {
        /// The `[Variables]` entry written; for `.hours` of a format written in a measure, nil.
        public var variable: String?
        /// For `.hours` in a measure's own Format: the measure.
        public var measure: String?
        public var kind: OptionKind
        public var label: String
        /// As written in the file.
        public var raw: String
        /// In effect.
        public var current: String
        /// The file that defines it.
        public var file: URL?

        public init(variable: String?, measure: String?, kind: OptionKind, label: String, raw: String, current: String,
                    file: URL?) {
            self.variable = variable
            self.measure = measure
            self.kind = kind
            self.label = label
            self.raw = raw
            self.current = current
            self.file = file
        }
    }

    // MARK: Shows

    /// One row of Shows: a part that draws data (a ring, a bar, a graph), what data it shows, and what else it can
    /// show.
    public struct ShowsRow: Equatable {
        /// "ring", "bar", "graph", "gauge", "shape".
        public var kind: String
        /// 1, 2… among the rows of the same kind (0: the only one).
        public var number: Int
        /// The data item the row's parts follow.
        public var measure: String
        /// The parts that follow it (shown ones), the representative first.
        public var meters: [String]
        /// Choices: the data item and how choosing it is written.
        public var choices: [ShowsChoice]
    }

    /// Something a Shows row can show instead.
    public struct ShowsChoice: Equatable {
        public enum Write: Equatable {
            /// Nothing to write: it is what the row shows now.
            case current
            /// `[Variables]` `name=value` (a switch between parts the widget has for each).
            case variable(String, String)
            /// `MeasureName=` of these meters.
            case rebind([String])
            /// Cannot be chosen here (the parts work their values out in their own way).
            case none
        }

        public var measure: String
        public var write: Write
    }

    // MARK: Fonts and text sizes

    public enum FontRoleKind: Equatable {
        /// The font of numbers (data), of labels, or of all words when there is one.
        case numbers, labels, words
    }

    /// Where a font of the widget comes from, and which role it plays.
    public struct FontRole: Equatable {
        public enum Source: Equatable {
            case variable(String)
            case look(String)
            case meters([String])
        }

        public var role: FontRoleKind
        public var source: Source
        /// The face in effect ("System Rounded").
        public var face: String
        public var meters: [String]
    }

    /// One place a text size is defined (A− / A+ scale them all as one step).
    public struct TextSize: Equatable {
        public enum Source: Equatable {
            case variable(String)
            case look(String)
            case meter(String)
        }

        public var source: Source
        public var raw: String
        public var value: Double
    }

    // MARK: Look and sizes

    /// The look a suite's widgets share (the file of looks a variable chooses: `Looks/#Look#.inc`).
    public struct Look: Equatable {
        public var variable: String
        /// The looks there are, in the order of the page (Auto, Light, Dark, Clear, then the others).
        public var values: [String]
        public var current: String
        /// The file that defines the variable (shared by the suite: the page says so).
        public var file: URL?
        /// The widgets of the suite that read it (this one included).
        public var widgets: Int
    }

    /// The sizes a widget comes in: the variant files of its folder named Small, Medium and Large.
    public struct Variants: Equatable {
        public var files: [String]
        public var current: String
    }

    // MARK: The facts

    public var name: String
    public var information: String
    public var colors = Colors()
    public var options: [Option] = []
    public var shows: [ShowsRow] = []
    public var fonts: [FontRole] = []
    public var textSizes: [TextSize] = []
    public var look: Look?
    public var variants: Variants?
    /// The layer the widget calls its card (background), if any.
    public var background: String?

    public init(skin: Skin, index: ValueUsageIndex? = nil) {
        let index = index ?? skin.valueUsages()
        let names = LayerNaming.catalog(of: skin)
        let builder = Builder(skin: skin, index: index, names: names)
        name = builder.widgetName()
        information = builder.information()
        background = builder.background
        colors = builder.colors()
        shows = builder.shows()
        options = builder.options(excluding: colors, shows: shows)
        fonts = builder.fonts()
        textSizes = builder.textSizes()
        look = builder.look()
        variants = builder.variants()
    }

    /// The data item's name in words ("CPU usage"), with sensors named by what they read.
    public static func dataName(_ measure: Measure, in skin: Skin, names: LayerNameCatalog? = nil) -> (name: String, short: String) {
        if measure.type == "macsensors" || measure.type == "usagemonitor" {
            let sensor = measure.string(measure.type == "macsensors" ? "Sensor" : "Alias").lowercased()
            if sensor.hasPrefix("gpu") { return sensor.contains("temp") ? ("GPU temperature", "GPU") : ("GPU usage", "GPU") }
            if sensor.hasPrefix("cpu") { return ("CPU temperature", "CPU") }
            if sensor.hasPrefix("fan") { return ("Fan speed", "Fan") }
            if sensor.hasPrefix("power") { return ("Power", "Power") }
        }
        if measure.type == "powerplugin" { return ("Battery", "Battery") }
        let n = (names ?? LayerNaming.catalog(of: skin)).data(measure.name)
        return (n?.name ?? LayerNaming.humanized(measure.name), n?.short ?? LayerNaming.humanized(measure.name))
    }

    /// Measure types whose data a Shows row may switch between.
    public static let choosableTypes: Set<String> = [
        "cpu", "memory", "physicalmemory", "swapmemory", "netin", "netout", "nettotal", "freediskspace", "macsensors",
        "usagemonitor", "advancedcpu", "coretemp", "powerplugin", "perfmon", "resmon",
    ]
}

// MARK: - Working it out

extension SkinSection {
    /// The options the section's own block writes (lowercased), in order.
    var ownKeys: [String] {
        var seen: Set<String> = []
        return own.entries.map { $0.key.lowercased() }.filter { seen.insert($0).inserted }
    }
}

/// Works the facts out, keeping what several of them need (who follows which data item, which file a variable
/// chooses, which colors take an alpha) so each is worked out once.
private final class Builder {
    let skin: Skin
    let index: ValueUsageIndex
    let names: LayerNameCatalog
    let background: String?
    /// Lowercased names of meters that are shown and draw something.
    let shown: Set<String>
    /// The meters in drawing order (lowercased name → position).
    let order: [String: Int]

    init(skin: Skin, index: ValueUsageIndex, names: LayerNameCatalog) {
        self.skin = skin
        self.index = index
        self.names = names
        background = names.background ?? skin.detectedBackgroundLayer()
        shown = Set(skin.meters.filter { !$0.hidden && !Builder.isInvisible($0) }.map { $0.name.lowercased() })
        order = Dictionary(skin.meters.enumerated().map { ($1.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// A meter that draws nothing of its own: a hit box (an empty picture or text with a clear background).
    static func isInvisible(_ m: Meter) -> Bool {
        guard m.solidColor.a < 5 else { return false }
        switch m.type {
        case "image": return (m.fileOption("ImageName") ?? "").isEmpty
        case "string": return (m.fileOption("Text") ?? "").isEmpty && m.measures.isEmpty
        default: return false
        }
    }

    // MARK: Caches

    private var reachCache: [String: [String]] = [:]

    /// The sections following `section` (itself first), transitively.
    func reach(_ section: String) -> [String] {
        let key = section.lowercased()
        if let r = reachCache[key] { return r }
        let r = index.reach([section])
        reachCache[key] = r
        return r
    }

    private var shownFollowersCache: [String: [String]] = [:]

    /// The shown meters that follow a data item, in the order they follow it.
    func shownFollowers(of measure: String) -> [String] {
        let key = measure.lowercased()
        if let r = shownFollowersCache[key] { return r }
        let r = reach(measure).filter { shown.contains($0.lowercased()) && skin.meter(named: $0) != nil }
        shownFollowersCache[key] = r
        return r
    }

    /// The data items a Shows row can be about: reading the Mac (not a total, a disk's name, or a battery's state).
    lazy var dataItems: [Measure] = skin.measures.filter { m in
        guard StudioWidgetFacts.choosableTypes.contains(m.type), !m.bool("Total", false), !m.bool("Label", false)
        else { return false }
        if m.type == "powerplugin" { return m.string("PowerState").lowercased() == "percent" }
        return true
    }

    /// The data item each meter follows: of those reaching it, the one it is fewest steps from.
    lazy var followed: [String: String] = {
        var best: [String: (measure: String, distance: Int)] = [:]
        for m in dataItems {
            for (distance, section) in reach(m.name).enumerated() where skin.meter(named: section) != nil {
                let key = section.lowercased()
                if best[key] == nil || distance < best[key]!.distance { best[key] = (m.name, distance) }
            }
        }
        return best.mapValues(\.measure)
    }()

    func followedData(_ meter: Meter) -> String? { followed[meter.name.lowercased()] }

    /// File path → the variable its `@Include` line chooses it by (a variable of the widget, or a Mac appearance
    /// variable), for every file included that way.
    lazy var chosenFiles: [String: String] = {
        var result: [String: String] = [:]
        for source in skin.sourceFiles {
            guard let text = skin.sourceText(of: source) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("@include"), let eq = trimmed.firstIndex(of: "=") else { continue }
                var raw = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") { raw = String(raw.dropFirst().dropLast()) }
                let slashed = raw.replacingOccurrences(of: "\\", with: "/")
                let fileName = slashed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? slashed
                guard let variable = SkinInspection.referencedVariables(in: fileName).first(where: {
                    !BuiltInVariables.isBuiltIn($0) || BuiltInVariables.isMacAppearanceKey($0.lowercased())
                }) else { continue }
                let resolved = skin.resolve(slashed, in: nil, sectionVariables: false)
                for path in [skin.absolutePath(resolved),
                             skin.absolutePath(resolved, relativeTo: source.deletingLastPathComponent())] {
                    result[Builder.pathKey(URL(fileURLWithPath: path))] = variable
                }
            }
        }
        return result
    }()

    static func pathKey(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }

    /// The variable `file` is chosen by (nil: every include names it outright).
    func chosenBy(_ file: URL) -> String? { chosenFiles[Builder.pathKey(file)] }

    /// Every raw value of the widget: variable definitions, and the options of its sections and looks.
    lazy var allRaws: [String] = {
        var raws = index.values.map(\.raw)
        var looks: Set<String> = []
        for s in skin.meters as [SkinSection] + skin.measures as [SkinSection] {
            for key in s.ownKeys { if let v = s.fileOption(key) { raws.append(v) } }
            for style in s.styles where looks.insert(style.lowercased()).inserted {
                raws += (skin.styleValues(named: style) ?? [:]).values
            }
        }
        return raws
    }()

    /// Variables written with an alpha after them (`#Name#,…`), lowercased — with those that are one of them by
    /// another name (`DiskColor=#StorageColor#`).
    lazy var withAlpha: Set<String> = {
        var result: Set<String> = []
        for raw in allRaws {
            var rest = raw[...]
            while let hash = rest.firstIndex(of: "#") {
                let after = rest[rest.index(after: hash)...]
                guard let end = after.firstIndex(of: "#") else { break }
                let name = after[..<end]
                let next = after[after.index(after: end)...]
                if !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "[" }), next.first == "," {
                    result.insert(name.lowercased())
                }
                rest = next
            }
        }
        // An alias of a variable taken with an alpha takes it too, and so does what it aliases.
        var changed = true
        while changed {
            changed = false
            for v in index.values {
                guard let name = v.variableName?.lowercased(), result.contains(name) else { continue }
                let refs = SkinInspection.referencedVariables(in: v.raw)
                if refs.count == 1, v.raw.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("#\(refs[0])#") == .orderedSame,
                   result.insert(refs[0].lowercased()).inserted {
                    changed = true
                }
            }
        }
        return result
    }()

    /// Variables a widget sets while it runs (`!SetVariable`): its state, not an option.
    lazy var setWhileRunning: Set<String> = {
        var result: Set<String> = []
        for text in allRaws {
            var rest = text[...]
            while let r = rest.range(of: "!SetVariable", options: .caseInsensitive) {
                let after = rest[r.upperBound...].drop(while: { $0 == " " || $0 == "\"" })
                let name = after.prefix(while: { !$0.isWhitespace && $0 != "\"" && $0 != "]" })
                if !name.isEmpty { result.insert(name.lowercased()) }
                rest = rest[r.upperBound...]
            }
        }
        return result
    }()

    // MARK: Header

    func widgetName() -> String {
        if let name = skin.metadata.first(where: { $0.key.caseInsensitiveCompare("Name") == .orderedSame })?.value,
           !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return String(skin.config.split(separator: "\\").last ?? Substring(skin.config))
    }

    /// The first sentence of `[Metadata] Information`, without a leading "Suite · ".
    func information() -> String {
        guard var text = skin.metadata.first(where: { $0.key.caseInsensitiveCompare("Information") == .orderedSame })?
            .value.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return "" }
        text = text.replacingOccurrences(of: "|", with: " ")
        let root = skin.rootConfig
        for prefix in ["\(root) · ", "\(root) - ", "\(root): "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if let end = text.range(of: ". ") { text = String(text[..<end.lowerBound]) + "." }
        return text
    }

    // MARK: Colors

    static let textKeys: Set<String> = ["fontcolor", "fonteffectcolor"]

    func isTextUse(_ use: ValueUsageIndex.Use) -> Bool {
        let k = use.key.lowercased()
        return Self.textKeys.contains(k) || k.hasPrefix("inlinesetting")
    }

    /// A use by an action (a color set in some states): not what is drawn.
    func isActionUse(_ use: ValueUsageIndex.Use) -> Bool {
        let k = use.key.lowercased()
        return k.hasSuffix("action") || k.hasPrefix("ifcondition") || k.contains("action")
    }

    /// A use that draws: by a shown meter, or by a data item shown meters follow (an icon's palette); not an action.
    func isDrawn(_ use: ValueUsageIndex.Use) -> Bool {
        guard !isActionUse(use) else { return false }
        if shown.contains(use.section.lowercased()) { return true }
        if skin.measure(named: use.section) != nil { return !shownFollowers(of: use.section).isEmpty }
        return false
    }

    func colors() -> StudioWidgetFacts.Colors {
        let groups = index.colorGroups()
        var result = StudioWidgetFacts.Colors()
        var taken: Set<Int> = []
        // Text: the color most text is written in (a variable named for text wins a tie).
        var bestText: (i: Int, score: Int)?
        for (i, g) in groups.enumerated() where g.color.a >= 10 {
            let uses = g.members.flatMap(\.uses).filter { isTextUse($0) && isDrawn($0) }
            guard !uses.isEmpty else { continue }
            let named = (g.variables + g.members.flatMap(\.uses).compactMap(\.via)).contains {
                let l = $0.lowercased()
                return l.contains("text") || l.contains("font") || l.contains("ink")
            }
            let score = uses.count + (named ? 1000 : 0)
            if bestText == nil || score > bestText!.score { bestText = (i, score) }
        }
        if let bestText {
            result.text = role(groups[bestText.i], kind: .text)
            taken.insert(bestText.i)
        }
        // Card: the background layer's fill (or its glass tint, or the widget's own background color).
        if let card = cardGroup(groups, taken: taken) {
            result.card = role(groups[card], kind: .card)
            taken.insert(card)
        }
        var parts: [(role: StudioWidgetFacts.ColorRole, uses: Int, first: Int)] = []
        for (i, g) in groups.enumerated() where !taken.contains(i) {
            let drawn = g.members.flatMap(\.uses).filter(isDrawn)
            guard g.color.a >= 10, !drawn.isEmpty else {
                result.others.append(role(g, kind: .other))
                continue
            }
            let text = drawn.filter(isTextUse).count
            // Used for words and drawings alike, one variable not chosen by the look: the author's accent.
            if text > 0, text < drawn.count, g.members.count == 1, g.variables.count == 1, !isTheme(g) {
                result.accents.append(role(g, kind: .accent))
                continue
            }
            let r = role(g, kind: .part)
            let first = r.meters.compactMap { order[$0.lowercased()] }.min() ?? Int.max
            parts.append((r, drawn.count, first))
        }
        // The most used first; among those used as much, in drawing order.
        parts.sort { a, b in a.uses != b.uses ? a.uses > b.uses : a.first < b.first }
        result.parts = parts.map(\.role)
        return result
    }

    /// Whether a group's color is defined by a file the look chooses (a theme's color).
    func isTheme(_ g: ValueUsageIndex.ColorGroup) -> Bool {
        g.members.contains { m in m.file.map { chosenBy($0) != nil } ?? false }
    }

    func cardGroup(_ groups: [ValueUsageIndex.ColorGroup], taken: Set<Int>) -> Int? {
        var candidates: [(i: Int, rank: Int)] = []
        for (i, g) in groups.enumerated() where !taken.contains(i) && g.color.a >= 1 {
            for use in g.members.flatMap(\.uses) {
                let key = use.key.lowercased()
                if let background, use.section.caseInsensitiveCompare(background) == .orderedSame {
                    if key.hasPrefix("shape") {
                        if shapeFill(of: background, key: use.key, references: g) { candidates.append((i, 0)) }
                    } else if key == "solidcolor" || key == "barcolor" {
                        candidates.append((i, 1))
                    } else if key == "macglasstint" {
                        candidates.append((i, 3))
                    }
                } else if use.section.caseInsensitiveCompare("Rainmeter") == .orderedSame, key == "solidcolor" {
                    candidates.append((i, 2))
                }
            }
        }
        return candidates.min { $0.rank < $1.rank }?.i
    }

    /// The `Fill Color` segments of a Shape option.
    static func fillSegments(_ raw: String) -> [String] {
        raw.split(separator: "|").compactMap { segment in
            let s = segment.trimmingCharacters(in: .whitespaces)
            guard s.lowercased().hasPrefix("fill color") else { return nil }
            return String(s.dropFirst("fill color".count)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Whether the `Fill Color` of the Shape `key` of `meter` is the group's color.
    func shapeFill(of meter: String, key: String, references g: ValueUsageIndex.ColorGroup) -> Bool {
        guard let m = skin.meter(named: meter), let raw = m.fileOption(key) else { return false }
        let names = Set((g.variables + g.members.flatMap(\.uses).compactMap(\.via)).map { $0.lowercased() })
        for value in Self.fillSegments(raw) {
            let refs = SkinInspection.referencedVariables(in: value).map { $0.lowercased() }
            if refs.contains(where: names.contains) { return true }
            if let c = OptionValue.color(skin.resolve(value, in: m, sectionVariables: false)),
               ValueUsageIndex.colorKey(c) == ValueUsageIndex.colorKey(g.color) { return true }
        }
        return false
    }

    func role(_ g: ValueUsageIndex.ColorGroup, kind: StudioWidgetFacts.ColorKind) -> StudioWidgetFacts.ColorRole {
        var meters: [String] = []
        var seen: Set<String> = []
        for use in g.members.flatMap(\.uses) where isDrawn(use) {
            let sections = skin.measure(named: use.section) != nil ? shownFollowers(of: use.section) : [use.section]
            for s in sections where seen.insert(s.lowercased()).inserted { meters.append(s) }
        }
        meters.sort { (order[$0.lowercased()] ?? 0) < (order[$1.lowercased()] ?? 0) }
        let variable = writtenVariable(g)
        let (label, title, partKind) = words(for: g, meters: meters, variable: variable)
        return StudioWidgetFacts.ColorRole(kind: kind, group: g, color: g.color, label: label, title: title,
                                           partKind: partKind, meters: meters, parts: partCount(meters),
                                           variable: variable,
                                           acceptsAlpha: variable.map { !withAlpha.contains($0.lowercased()) } ?? true,
                                           followsLook: followsLook(variable: variable, g))
    }

    /// The meters as parts: those drawn inside another of them (a symbol in its ring) count with it.
    func partCount(_ meters: [String]) -> Int {
        let frames = meters.compactMap { skin.meter(named: $0)?.frame }
        let count = frames.enumerated().filter { i, f in
            !frames.enumerated().contains { j, g in
                j != i && g.width * g.height > f.width * f.height && g.x <= f.x && g.y <= f.y
                    && g.x + g.width >= f.x + f.width && g.y + g.height >= f.y + f.height
            }
        }.count
        return max(count, 1)
    }

    /// The `[Variables]` entry a change of the group writes: the one every use reaches its color through, nearest to
    /// the uses (`MemoryColor` for `#MemoryColor#` = `#Green#`; the ink `InkRGB` under `TextColor` and
    /// `SecondaryTextColor`); nil for a literal color.
    func writtenVariable(_ g: ValueUsageIndex.ColorGroup) -> String? {
        guard !g.variables.isEmpty else { return nil }
        var chains: [[String]] = []
        for member in g.members where !member.uses.isEmpty {
            guard let root = member.variableName else { continue }
            let vias = Set(member.uses.map { $0.via ?? root })
            for via in vias { chains.append(chain(from: via, to: root)) }
        }
        guard let first = chains.first else { return g.variables.first }
        for candidate in first {
            let l = candidate.lowercased()
            if chains.allSatisfy({ $0.contains { $0.lowercased() == l } }) { return candidate }
        }
        return g.variables.first
    }

    /// The variables from `start` to `root`, following definitions that are one color variable (`#Green#`, or
    /// `#InkRGB#,#Alpha1#`).
    func chain(from start: String, to root: String) -> [String] {
        var result = [start]
        var current = start
        var steps = 0
        while current.caseInsensitiveCompare(root) != .orderedSame, steps < 16 {
            steps += 1
            guard let raw = index.variable(current)?.raw,
                  let next = SkinInspection.referencedVariables(in: raw).first,
                  raw.trimmingCharacters(in: .whitespaces).hasPrefix("#\(next)#") else { break }
            result.append(next)
            current = next
        }
        return result
    }

    func followsLook(variable: String?, _ g: ValueUsageIndex.ColorGroup) -> Bool {
        guard let variable else { return false }
        // Changed for this widget: its own file overrides the theme's value.
        if let own = skin.sources.location(section: "Variables", key: variable)?.file, skin.isOwnFile(own) { return false }
        var files: [URL] = []
        if let f = index.variable(variable)?.file { files.append(f) }
        files += g.members.compactMap(\.file)
        return files.contains { chosenBy($0) != nil }
    }

    /// The words of a color: a short one for its swatch and a title for its popover.
    func words(for g: ValueUsageIndex.ColorGroup, meters: [String], variable: String?) -> (String, String, String?) {
        func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        let role = Self.plainRole(g.role)
        // Data parts: one data item names it ("Memory", "Memory ring"); several of one kind are named by the kind
        // ("Bars"); the empty part behind them is their track.
        var data: [String] = []
        var kinds: Set<String> = []
        for m in meters {
            guard let meter = skin.meter(named: m), Self.drawsData.contains(meter.type), let d = followedData(meter) else {
                continue
            }
            if !data.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) { data.append(d) }
            kinds.insert(Self.kindNoun(meter))
        }
        let track = role.lowercased().hasPrefix("empty part")
        if data.count == 1, !track, let measure = skin.measure(named: data[0]), let kind = kinds.first {
            let short = StudioWidgetFacts.dataName(measure, in: skin, names: names).short
            return (short, "\(short) \(kind)", kind)
        }
        if data.count > 1, kinds.count == 1, let kind = kinds.first {
            let plural = capitalized(Self.plural(kind))
            return track ? ("Tracks", "\(capitalized(kind)) tracks", nil) : (plural, plural, nil)
        }
        if let variable {
            var words = ValueUsageIndex.humanizedVariable(variable)
            for suffix in [" text color", " color", " colour", " tint", " rgb"] where words.lowercased().hasSuffix(suffix) {
                words = String(words.dropLast(suffix.count))
            }
            let short = words.isEmpty ? role : capitalized(words)
            return (short, short, nil)
        }
        let title = capitalized(role)
        // A long role in one word: its last ("Background panel outline" → "Outline").
        let label = title.count <= 12 ? title : capitalized(String(title.split(separator: " ").last ?? Substring(title)))
        return (label, title, nil)
    }

    /// A role without its count and the word "color" ("Bar color and 2 more" → "Bar").
    static func plainRole(_ role: String) -> String {
        var r = role
        if let range = r.range(of: #" and \d+ more$"#, options: .regularExpression) { r.removeSubrange(range) }
        for suffix in [" color", " colour"] where r.lowercased().hasSuffix(suffix) { r = String(r.dropLast(suffix.count)) }
        return r
    }

    static func plural(_ kind: String) -> String {
        switch kind {
        case "graph", "ring", "bar", "gauge", "shape", "picture": return kind + "s"
        default: return kind
        }
    }

    // MARK: Shows

    static func kindNoun(_ m: Meter) -> String {
        switch m.type {
        case "bar": return "bar"
        case "line", "histogram": return "graph"
        case "roundline", "rotator": return "gauge"
        case "string": return "text"
        case "image", "bitmap": return "picture"
        case "shape":
            let shapes = ((m.fileOption("Shape") ?? "") + (m.fileOption("Shape2") ?? "")).lowercased()
            return shapes.contains("arc") || shapes.contains("ellipse") ? "ring" : "shape"
        default: return "part"
        }
    }

    static let drawsData: Set<String> = ["bar", "line", "histogram", "roundline", "rotator", "shape"]

    func shows() -> [StudioWidgetFacts.ShowsRow] {
        var rows: [StudioWidgetFacts.ShowsRow] = []
        for m in dataItems {
            // The parts that follow this data item more closely than any other.
            let parts = shownFollowers(of: m.name).compactMap { skin.meter(named: $0) }.filter {
                followedData($0)?.caseInsensitiveCompare(m.name) == .orderedSame
                    && $0.name.caseInsensitiveCompare(background ?? "") != .orderedSame
            }
            guard let representative = parts.first(where: { Self.drawsData.contains($0.type) }) else { continue }
            let meters = [representative.name] + parts.map(\.name).filter { $0 != representative.name }
            rows.append(StudioWidgetFacts.ShowsRow(kind: Self.kindNoun(representative), number: 0, measure: m.name,
                                                   meters: meters, choices: []))
        }
        rows.sort { (order[$0.meters[0].lowercased()] ?? 0) < (order[$1.meters[0].lowercased()] ?? 0) }
        var counts: [String: Int] = [:]
        for r in rows { counts[r.kind, default: 0] += 1 }
        var seen: [String: Int] = [:]
        for i in rows.indices where (counts[rows[i].kind] ?? 0) > 1 {
            seen[rows[i].kind, default: 0] += 1
            rows[i].number = seen[rows[i].kind]!
        }
        for i in rows.indices { rows[i].choices = choices(for: rows[i]) }
        return rows
    }

    /// A `[Variables]` choice that only shows or hides parts, with the data each value shows.
    struct ShowSwitch {
        var variable: String
        var values: [(value: String, data: String)]
    }

    lazy var showSwitches: [ShowSwitch] = {
        var result: [ShowSwitch] = []
        for choice in choiceVariables {
            let meterUses = uses(ofChoice: choice.variable).filter { skin.meter(named: $0.section) != nil }
            guard !meterUses.isEmpty, meterUses.allSatisfy({ $0.key.lowercased() == "hidden" }) else { continue }
            var values: [(String, String)] = []
            for value in choice.values {
                let visible = meterUses.compactMap { use -> Meter? in
                    guard let meter = skin.meter(named: use.section) else { return nil }
                    return hidden(meter, with: choice.variable, value) == false ? meter : nil
                }
                if let data = visible.lazy.compactMap({ self.followedData($0) }).first { values.append((value, data)) }
            }
            if values.count >= 2, Set(values.map { $0.1.lowercased() }).count == values.count {
                result.append(ShowSwitch(variable: choice.variable, values: values))
            }
        }
        return result
    }()

    /// Whether `meter` is hidden when `variable` is `value`: its Hidden formula with the choice's variables worked out
    /// for that value (nil when that cannot be said).
    func hidden(_ meter: Meter, with variable: String, _ value: String) -> Bool? {
        guard let raw = meter.fileOption("Hidden") else { return nil }
        var text = raw
        for name in SkinInspection.referencedVariables(in: raw) {
            guard let def = index.variable(name)?.raw else { continue }
            var replaced: String
            if let r = def.range(of: "[#\(variable)]", options: .caseInsensitive), def.hasPrefix("[#"), def.hasSuffix("]") {
                var nested = def
                nested.replaceSubrange(r, with: value)
                let inner = String(nested.dropFirst(2).dropLast())
                replaced = index.variable(inner)?.raw ?? skin.variable(inner) ?? nested
            } else if def.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("#\(variable)#") == .orderedSame {
                replaced = value
            } else {
                replaced = skin.variable(name) ?? def
            }
            text = text.replacingOccurrences(of: "#\(name)#", with: replaced, options: .caseInsensitive)
        }
        guard !text.contains("#"), !text.contains("[") else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let n = Double(trimmed) { return n != 0 }
        guard let n = try? Formula.evaluate(trimmed) else { return nil }
        return n != 0
    }

    func choices(for row: StudioWidgetFacts.ShowsRow) -> [StudioWidgetFacts.ShowsChoice] {
        for s in showSwitches {
            guard let current = s.values.first(where: { $0.data.caseInsensitiveCompare(row.measure) == .orderedSame })
            else { continue }
            return s.values.map { v in
                v.value == current.value ? .init(measure: v.data, write: .current)
                    : .init(measure: v.data, write: .variable(s.variable, v.value))
            }
        }
        // Parts that name the data item themselves (`MeasureName=`) can name another.
        let direct = row.meters.filter { name in
            guard let m = skin.meter(named: name) else { return false }
            return m.measures.contains { $0.name.caseInsensitiveCompare(row.measure) == .orderedSame }
        }
        let rebindable = direct.contains { $0.caseInsensitiveCompare(row.meters.first ?? "") == .orderedSame }
        return dataItems.map(\.name).map { d in
            if d.caseInsensitiveCompare(row.measure) == .orderedSame { return .init(measure: d, write: .current) }
            return .init(measure: d, write: rebindable ? .rebind(direct) : .none)
        }
    }

    // MARK: Options

    struct Choice {
        var variable: String
        var values: [String]
    }

    /// `[Variables]` entries chosen between by name: `[#Prefix[#Name]]` where `Prefix<value>` entries exist for at
    /// least two values (a name that a longer prefix of the same choice claims belongs to that one: `TempUnitNextC`
    /// is not a value of `[#TempUnit[#TempUnit]]` when `[#TempUnitNext[#TempUnit]]` is written too).
    lazy var choiceVariables: [Choice] = {
        var prefixes: [(prefix: String, selector: String)] = []
        for raw in allRaws {
            var search = raw[...]
            while let open = search.range(of: "[#") {
                let rest = search[open.upperBound...]
                guard let inner = rest.range(of: "[#"), let close = rest.range(of: "]"), inner.lowerBound < close.lowerBound
                else { search = rest; continue }
                let prefix = String(rest[..<inner.lowerBound])
                let selector = String(rest[inner.upperBound..<close.lowerBound])
                search = rest[close.upperBound...]
                guard !prefix.isEmpty, !selector.isEmpty, !selector.contains("#"), !BuiltInVariables.isBuiltIn(selector),
                      !prefixes.contains(where: { $0.prefix.lowercased() == prefix.lowercased()
                          && $0.selector.lowercased() == selector.lowercased() }) else { continue }
                prefixes.append((prefix, selector))
            }
        }
        let defined = index.values.compactMap(\.variableName)
        var result: [Choice] = []
        var done: Set<String> = []
        for (prefix, selector) in prefixes where !done.contains(selector.lowercased()) {
            // The selector's own lookup: the prefix that is the selector's name, else the first one.
            let own = prefixes.filter { $0.selector.lowercased() == selector.lowercased() }
            let main = own.first { $0.prefix.lowercased() == selector.lowercased() }?.prefix ?? prefix
            let longer = own.map(\.prefix).filter { $0.count > main.count && $0.lowercased().hasPrefix(main.lowercased()) }
            let values = defined.compactMap { name -> String? in
                let l = name.lowercased()
                guard name.count > main.count, l.hasPrefix(main.lowercased()),
                      !longer.contains(where: { l.hasPrefix($0.lowercased()) }) else { return nil }
                return String(name.dropFirst(main.count))
            }
            guard values.count >= 2, index.variable(selector) != nil else { continue }
            done.insert(selector.lowercased())
            result.append(Choice(variable: selector, values: values))
        }
        return result
    }()

    /// The uses of a choice variable, including those through the variables it chooses between.
    func uses(ofChoice variable: String) -> [ValueUsageIndex.Use] {
        var result = index.variable(variable)?.uses ?? []
        let needle = "[#\(variable.lowercased())]"
        for value in index.values where value.raw.lowercased().contains(needle) { result += value.uses }
        return result
    }

    /// Whether uses reach what is shown: a shown meter, or a data item shown meters follow.
    func usedByShownParts(_ uses: [ValueUsageIndex.Use]) -> Bool {
        uses.contains { use in
            if shown.contains(use.section.lowercased()) { return true }
            if skin.measure(named: use.section) != nil { return !shownFollowers(of: use.section).isEmpty }
            return false
        }
    }

    static let stateWords = ["confirmed", "ready", "missing", "loading", "full", "last", "demo", "debug", "state",
                             "index", "count", "stale", "source"]

    func options(excluding colors: StudioWidgetFacts.Colors, shows: [StudioWidgetFacts.ShowsRow]) -> [StudioWidgetFacts.Option] {
        var result: [StudioWidgetFacts.Option] = []
        var taken: Set<String> = []
        func add(_ o: StudioWidgetFacts.Option) {
            let key = (o.variable ?? o.measure ?? "").lowercased()
            guard taken.insert(key).inserted else { return }
            result.append(o)
        }
        func label(_ name: String) -> String {
            var words = ValueUsageIndex.humanizedVariable(name)
            for suffix in [" color", " colour", " alpha", " opacity"] where words.lowercased().hasSuffix(suffix) {
                words = String(words.dropLast(suffix.count))
            }
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        /// Defined in a file the look chooses: the look's own business.
        func inTheme(_ v: ValueUsageIndex.Value) -> Bool { v.file.map { chosenBy($0) != nil } ?? false }
        for accent in colors.accents {
            guard let v = accent.variable, let value = index.variable(v) else { continue }
            add(.init(variable: v, measure: nil, kind: .color, label: label(v), raw: value.raw, current: value.current,
                      file: value.file))
        }
        if let alpha = cardAlphaVariable(), let value = index.variable(alpha) {
            add(.init(variable: alpha, measure: nil, kind: .alpha, label: label(alpha), raw: value.raw,
                      current: value.current, file: value.file))
        }
        let switches = Set(showSwitches.map { $0.variable.lowercased() })
        let lookVariable = look()?.variable.lowercased()
        for choice in choiceVariables {
            let lower = choice.variable.lowercased()
            guard !switches.contains(lower), lower != lookVariable, !setWhileRunning.contains(lower),
                  let value = index.variable(choice.variable), !value.isCalculated, !inTheme(value),
                  usedByShownParts(uses(ofChoice: choice.variable)) else { continue }
            add(.init(variable: choice.variable, measure: nil, kind: .choice(choice.values), label: label(choice.variable),
                      raw: value.raw, current: value.current, file: value.file))
        }
        for value in index.values {
            guard let name = value.variableName, value.kind != .color, !value.isCalculated, !value.isInternal,
                  !inTheme(value), ["0", "1"].contains(value.raw.trimmingCharacters(in: .whitespaces)),
                  !setWhileRunning.contains(name.lowercased()),
                  !Self.stateWords.contains(where: { name.lowercased().contains($0) }),
                  value.uses.contains(where: { $0.key.lowercased() == "hidden" && skin.meter(named: $0.section) != nil })
            else { continue }
            add(.init(variable: name, measure: nil, kind: .toggle, label: label(name), raw: value.raw,
                      current: value.current, file: value.file))
        }
        for m in skin.measures where m.type == "time" {
            guard let raw = m.fileOption("Format"), !raw.contains("[#") else { continue }
            let refs = SkinInspection.referencedVariables(in: raw)
            if refs.count == 1, raw.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("#\(refs[0])#") == .orderedSame,
               let value = index.variable(refs[0]), !value.isCalculated, let hours = Self.hours(in: value.current) {
                add(.init(variable: refs[0], measure: nil, kind: .hours(twentyFour: hours), label: "Clock",
                          raw: value.raw, current: value.current, file: value.file))
            } else if refs.isEmpty, let hours = Self.hours(in: raw) {
                add(.init(variable: nil, measure: m.name, kind: .hours(twentyFour: hours), label: "Clock", raw: raw,
                          current: raw, file: skin.sources.location(section: m.name, key: "Format")?.file))
            }
        }
        return result
    }

    /// true for a format with `%H`, false for one with `%I`, nil for neither.
    static func hours(in format: String) -> Bool? {
        let f = format.replacingOccurrences(of: "%#", with: "%")
        if f.contains("%H") { return true }
        if f.contains("%I") { return false }
        return nil
    }

    /// The variable that is the alpha of the card's fill (`#PanelAlpha#` in `Fill Color #Panel#,#PanelAlpha#`).
    func cardAlphaVariable() -> String? {
        guard let background, let meter = skin.meter(named: background) else { return nil }
        var values = Self.fillSegments(meter.fileOption("Shape") ?? "")
        if let solid = meter.fileOption("SolidColor") { values.append(solid) }
        for value in values {
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let last = parts.last else { continue }
            let refs = SkinInspection.referencedVariables(in: last)
            if refs.count == 1, last.caseInsensitiveCompare("#\(refs[0])#") == .orderedSame,
               let v = index.variable(refs[0]), !v.isCalculated,
               Double(v.current.trimmingCharacters(in: .whitespaces)) != nil { return refs[0] }
        }
        return nil
    }

    // MARK: Fonts

    func fonts() -> [StudioWidgetFacts.FontRole] {
        struct Found { var source: StudioWidgetFacts.FontRole.Source; var face: String; var meters: [String]; var data: Int }
        var found: [Found] = []
        for m in skin.meters where m.type == "string" && !m.hidden {
            let raw = m.fileOption("FontFace") ?? ""
            let refs = SkinInspection.referencedVariables(in: raw)
            let source: StudioWidgetFacts.FontRole.Source
            if refs.count == 1, raw.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("#\(refs[0])#") == .orderedSame,
               !BuiltInVariables.isBuiltIn(refs[0]) {
                source = .variable(refs[0])
            } else if case .style(let look, _)? = m.fileOrigin("FontFace") {
                source = .look(look)
            } else {
                source = .meters([m.name])
            }
            let face = m.option("FontFace").map { skin.resolve($0, in: m, sectionVariables: false) } ?? "Arial"
            let isData = !m.measures.isEmpty
            let match = found.firstIndex { f in
                if case .meters = source, case .meters = f.source { return f.face.caseInsensitiveCompare(face) == .orderedSame }
                return same(f.source, source)
            }
            if let i = match {
                found[i].meters.append(m.name)
                if case .meters(var list) = found[i].source { list.append(m.name); found[i].source = .meters(list) }
                if isData { found[i].data += 1 }
            } else {
                found.append(Found(source: source, face: face, meters: [m.name], data: isData ? 1 : 0))
            }
        }
        guard !found.isEmpty else { return [] }
        func name(_ s: StudioWidgetFacts.FontRole.Source) -> String {
            switch s { case .variable(let v): return v.lowercased(); case .look(let l): return l.lowercased(); case .meters: return "" }
        }
        func numeric(_ f: Found) -> Bool {
            let n = name(f.source)
            if n.contains("number") || n.contains("digit") || n.contains("value") { return true }
            if n.contains("text") || n.contains("label") { return false }
            return f.data * 2 > f.meters.count
        }
        let numbers = found.filter(numeric), labels = found.filter { !numeric($0) }
        let n = numbers.max { $0.meters.count < $1.meters.count }
        let l = labels.max { $0.meters.count < $1.meters.count }
        if let n, let l {
            return [.init(role: .numbers, source: n.source, face: n.face, meters: n.meters),
                    .init(role: .labels, source: l.source, face: l.face, meters: l.meters)]
        }
        guard let one = n ?? l else { return [] }
        return [.init(role: .words, source: one.source, face: one.face, meters: one.meters)]
    }

    func same(_ a: StudioWidgetFacts.FontRole.Source, _ b: StudioWidgetFacts.FontRole.Source) -> Bool {
        switch (a, b) {
        case (.variable(let x), .variable(let y)), (.look(let x), .look(let y)): return x.caseInsensitiveCompare(y) == .orderedSame
        default: return false
        }
    }

    func textSizes() -> [StudioWidgetFacts.TextSize] {
        var result: [StudioWidgetFacts.TextSize] = []
        for m in skin.meters where m.type == "string" {
            guard let raw = m.fileOption("FontSize") else { continue }
            let refs = SkinInspection.referencedVariables(in: raw)
            let value = OptionValue.number(skin.resolve(raw, in: m, sectionVariables: false)) ?? m.double("FontSize", 10)
            let size: StudioWidgetFacts.TextSize
            if refs.count == 1, raw.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("#\(refs[0])#") == .orderedSame,
               let v = index.variable(refs[0]), !v.isCalculated {
                size = .init(source: .variable(refs[0]), raw: v.raw, value: value)
            } else if case .style(let look, _)? = m.fileOrigin("FontSize") {
                size = .init(source: .look(look), raw: raw, value: value)
            } else {
                size = .init(source: .meter(m.name), raw: raw, value: value)
            }
            if !result.contains(where: { $0.source == size.source }) { result.append(size) }
        }
        return result
    }

    // MARK: Look and sizes

    private var lookCache: StudioWidgetFacts.Look??

    func look() -> StudioWidgetFacts.Look? {
        if let cached = lookCache { return cached }
        let found = findLook()
        lookCache = .some(found)
        return found
    }

    private func findLook() -> StudioWidgetFacts.Look? {
        for file in skin.includedFiles {
            guard let variable = chosenBy(file), !BuiltInVariables.isBuiltIn(variable) else { continue }
            let folder = file.deletingLastPathComponent().lastPathComponent.lowercased()
            let lower = variable.lowercased()
            guard lower.contains("look") || lower.contains("theme") || folder.contains("look") || folder.contains("theme")
            else { continue }
            let ext = file.pathExtension
            let siblings = ((try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(),
                                                                         includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.caseInsensitiveCompare(ext) == .orderedSame }
                .map { $0.deletingPathExtension().lastPathComponent }
            let known = ["Auto", "Light", "Dark", "Clear"]
            let values = known.filter { k in siblings.contains { $0.caseInsensitiveCompare(k) == .orderedSame } }
                + siblings.filter { s in !known.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }.sorted()
            guard values.count >= 2, let definition = index.variable(variable) else { continue }
            return .init(variable: variable, values: values, current: definition.current, file: definition.file,
                         widgets: max(Builder.widgetCount(in: skin.rootConfigDirectory), 1))
        }
        return nil
    }

    /// The widgets of a root folder: its folders (at any depth, `@Resources` aside) that hold a skin file.
    static func widgetCount(in root: URL) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return 0 }
        var folders: Set<String> = []
        for case let url as URL in walker {
            if url.lastPathComponent == "@Resources" { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "ini" { folders.insert(url.deletingLastPathComponent().path) }
        }
        return folders.count
    }

    func variants() -> StudioWidgetFacts.Variants? {
        let folder = skin.fileURL.deletingLastPathComponent()
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "ini" }
            .map { $0.deletingPathExtension().lastPathComponent }
        let sized = ["Small", "Medium", "Large"].filter { o in files.contains { $0.caseInsensitiveCompare(o) == .orderedSame } }
        guard sized.count >= 2 else { return nil }
        let current = skin.fileURL.deletingPathExtension().lastPathComponent
        guard sized.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) else { return nil }
        return .init(files: sized, current: current)
    }
}
