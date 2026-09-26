import Foundation

/// Where a widget's shared values are used: every `#Variable#` (and every literal color) with the options that use
/// it, so the editor can say who shares a value before it is changed ("Bar color · 18 bars", "Also moves “48 Hz”")
/// and select or outline them (docs/editor-friendly.md §8.1.1 and §7.5).
///
/// A value is used by a layer or a data item (never by a look itself: a look's option counts once for every layer
/// that uses the look and does not set the option itself), and by `[Rainmeter]`. Uses are found:
/// - in every option as the skin's files define it (the section's own value, else its looks', the last listed first —
///   what the engine reads, without values set while it runs);
/// - inside formulas, bang arguments (`[!SetOption … "#Accent#"]`), Shape strings and gradient options;
/// - through other variables: `W=#ContentWidth#` with `ContentWidth=(#PanelWidth# - 2 * #Padding#)` uses
///   `ContentWidth`, and `PanelWidth` and `Padding` through it;
/// - with the nested form `[#Name]`. A name built at run time (`[#Color[#Index]]`) cannot be known: every variable
///   it could name is marked "at least" (`isAtLeast`).
/// Literal colors are grouped by value (`16,19,28,235` and `10131CEB` are one value).
public struct ValueUsageIndex: Equatable {
    /// One option that uses a value.
    public struct Use: Equatable, Hashable {
        /// The section whose option it is (a layer, a data item, `Rainmeter`).
        public var section: String
        public var key: String
        /// The look (MeterStyle) that writes the option for the section; nil when the section writes it itself.
        public var look: String?
        /// The variable the option names, when the value is reached through that variable's definition
        /// (`W=#ContentWidth#` uses `PanelWidth` via `ContentWidth`); nil when the option names the value itself.
        public var via: String?

        public init(section: String, key: String, look: String? = nil, via: String? = nil) {
            self.section = section
            self.key = key
            self.look = look
            self.via = via
        }
    }

    /// A role name of a value with how many uses have it ("Bar color", 18).
    public struct Role: Equatable {
        public var name: String
        public var count: Int
        /// The value is used by an action (a state "when pointed at"), not by what is drawn: listed after the drawn
        /// roles used as often.
        public var isAction: Bool

        public init(name: String, count: Int, isAction: Bool = false) {
            self.name = name
            self.count = count
            self.isAction = isAction
        }
    }

    /// A shared value and its uses.
    public struct Value: Equatable {
        public enum Source: Equatable {
            /// A `[Variables]` entry, by name.
            case variable(String)
            /// A value written directly in the options (a color used by several layers), normalised to
            /// `R,G,B,A` with whole numbers.
            case literal(String)
        }

        /// What the value is, from its value and from the options that use it.
        public enum Kind: Equatable {
            case color
            /// A font face.
            case font
            /// A number used for positions and sizes (X, Y, W, H, font sizes, shapes…).
            case size
            case other
        }

        /// Where the value is defined.
        public enum Origin: Equatable {
            /// In this widget's own files (its .ini, or a file in its own folder).
            case own
            /// In a file shared with other widgets (an include outside the widget's folder, usually `@Resources`).
            case shared(URL)
            /// In no file (a built-in variable, or one set only while the widget runs).
            case none
        }

        public var source: Source
        public var uses: [Use]
        public var kind: Kind
        /// As written: the variable's definition, or the literal color as the first use writes it.
        public var raw: String
        /// The value in effect.
        public var current: String
        public var origin: Origin
        /// The file that defines a variable (nil for literals and variables defined nowhere).
        public var file: URL?
        /// The value is computed from others (a formula, or other variables): it is shown, not edited as a number.
        public var isCalculated: Bool
        /// A name built while the widget runs (`[#Color[#Index]]`) may name this value too: the uses are a minimum.
        public var isAtLeast: Bool
        /// Only an expert's business (theme switching, menu titles, actions): shown with Rainmeter Details.
        public var isInternal: Bool
        /// What the uses do, in plain words, most frequent first (§8.1.1 "Row title = role").
        public var roles: [Role]

        public init(source: Source, uses: [Use], kind: Kind = .other, raw: String = "", current: String = "",
                    origin: Origin = .own, file: URL? = nil, isCalculated: Bool = false, isAtLeast: Bool = false,
                    isInternal: Bool = false, roles: [Role] = []) {
            self.source = source
            self.uses = uses
            self.kind = kind
            self.raw = raw
            self.current = current
            self.origin = origin
            self.file = file
            self.isCalculated = isCalculated
            self.isAtLeast = isAtLeast
            self.isInternal = isInternal
            self.roles = roles
        }

        /// The sections using it, each once, in the order of `uses`.
        public var sections: [String] {
            var seen: Set<String> = []
            return uses.map(\.section).filter { seen.insert($0.lowercased()).inserted }
        }

        /// The variable's name (nil for a literal).
        public var variableName: String? {
            if case .variable(let name) = source { return name }
            return nil
        }

        /// The color in effect (nil when it is not a color).
        public var color: RGBA? { kind == .color ? OptionValue.color(current) : nil }

        /// The row title: the most frequent role, plus how many others there are ("CPU graph line and 2 more").
        public var role: String {
            guard let first = roles.first else { return variableName.map(ValueUsageIndex.humanizedVariable) ?? "Color" }
            return roles.count == 1 ? first.name : "\(first.name) and \(roles.count - 1) more"
        }
    }

    /// Colors with the same value, which one row of the widget page changes together (§8.1.1 "Merged same-value
    /// variables"): several variables, or one literal color.
    public struct ColorGroup: Equatable {
        public var color: RGBA
        public var members: [Value]
        /// Set by `colorGroups` when another row would have the same title (`name`).
        var distinctName: String?

        public init(color: RGBA, members: [Value]) {
            self.color = color
            self.members = members
        }

        /// The one name of this color everywhere — its widget-page row and every color control using it (§7.4, §8.1.1):
        /// the row title (`role`), told apart from another row with the same title by its color ("Counter graph line
        /// (blue)").
        public var name: String { distinctName ?? role }

        /// Every section using one of the members, each once, in order.
        public var sections: [String] {
            var seen: Set<String> = []
            return members.flatMap(\.uses).map(\.section).filter { seen.insert($0.lowercased()).inserted }
        }

        /// The roles of all members, merged and most frequent first; a member nothing here uses is named after its
        /// variable ("Down color").
        public var roles: [Role] {
            ValueUsageIndex.merge(members.map { m in
                m.roles.isEmpty ? [Role(name: m.role, count: 0)] : m.roles
            })
        }

        /// The row title ("Bar color", "CPU graph line and 1 more"): the roles of this widget's uses.
        public var role: String {
            let used = usedRoles
            guard let first = used.first else { return members.first?.role ?? "Color" }
            return used.count == 1 ? first.name : "\(first.name) and \(used.count - 1) more"
        }

        /// The roles of this widget's uses only, merged, most frequent first.
        public var usedRoles: [Role] { ValueUsageIndex.merge(members.map(\.roles)) }

        /// How many members nothing in this widget uses (same-value colors of other widgets).
        public var unusedCount: Int { members.filter { $0.uses.isEmpty }.count }

        /// The variables among the members.
        public var variables: [String] { members.compactMap(\.variableName) }

        public var isAtLeast: Bool { members.contains(where: \.isAtLeast) }

        /// A file shared with other widgets that defines one of the members (nil when all are this widget's own).
        public var sharedFile: URL? {
            for m in members { if case .shared(let url) = m.origin { return url } }
            return nil
        }
    }

    public var values: [Value]
    /// What follows a data item (lowercased name): the layers that show it or are placed by it (`MeasureName=`,
    /// `X=[MeasurePeakX]`) and the data items computed from it (`Formula=MeasurePeak * 2`), by section name.
    public var followers: [String: [String]]

    public init(values: [Value] = [], followers: [String: [String]] = [:]) {
        self.values = values
        self.followers = followers
    }

    public static let empty = ValueUsageIndex()

    /// Every section a change of these sections reaches: the sections themselves, then whatever follows a data item
    /// among them, transitively (`Left` is used by the formula of the peak marker's position, so the peak marker
    /// moves with it), each once, in that order.
    public func reach(_ sections: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        var queue = sections
        var i = 0
        while i < queue.count {
            let next = queue[i]
            i += 1
            guard seen.insert(next.lowercased()).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: followers[next.lowercased()] ?? [])
        }
        return result
    }

    /// The entry of a `[Variables]` entry (case-insensitive), nil when it is not defined.
    public func variable(_ name: String) -> Value? {
        values.first { value in
            if case .variable(let v) = value.source { return v.caseInsensitiveCompare(name) == .orderedSame }
            return false
        }
    }

    /// The sections using a variable, each once.
    public func users(ofVariable name: String) -> [String] {
        variable(name)?.sections ?? []
    }

    /// The literal color entry for a color (nil when no option writes it directly).
    public func literal(_ color: RGBA) -> Value? {
        let key = ValueUsageIndex.colorKey(color)
        return values.first { $0.source == .literal(key) }
    }

    /// The colors the widget uses, one group per value and source (§8.1.1), most used first: variables with the same
    /// value in one group (unless listed in `separate`, lowercased names), each literal color value in its own.
    /// Variables nothing here uses join a group of the same value but never make one; values that are only an
    /// expert's business are left out unless `includeInternal`.
    public func colorGroups(separate: Set<String> = [], includeInternal: Bool = false) -> [ColorGroup] {
        var groups: [ColorGroup] = []
        var byColor: [String: Int] = [:]
        let colors = values.filter { $0.kind == .color && !$0.isCalculated && (includeInternal || !$0.isInternal) }
        for value in colors where !value.uses.isEmpty {
            guard let color = value.color else { continue }
            if case .variable(let name) = value.source, !separate.contains(name.lowercased()) {
                let key = ValueUsageIndex.colorKey(color)
                if let i = byColor[key] {
                    groups[i].members.append(value)
                } else {
                    byColor[key] = groups.count
                    groups.append(ColorGroup(color: color, members: [value]))
                }
            } else {
                groups.append(ColorGroup(color: color, members: [value]))
            }
        }
        // Variables of the same value that this widget does not use are changed along with it (they are the same
        // color; "Show Separately" splits them).
        for value in colors where value.uses.isEmpty {
            guard let color = value.color, case .variable(let name) = value.source, !separate.contains(name.lowercased()),
                  let i = byColor[ValueUsageIndex.colorKey(color)] else { continue }
            groups[i].members.append(value)
        }
        // Most used first; invisible colors (0% opacity) after every visible one, so they fold behind "Show N More".
        var sorted = groups.enumerated().sorted { a, b in
            let clearA = a.element.color.a < 0.5, clearB = b.element.color.a < 0.5
            if clearA != clearB { return !clearA }
            let ca = a.element.sections.count, cb = b.element.sections.count
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
        ValueUsageIndex.nameApart(&sorted)
        return sorted
    }

    /// Rows with the same title are told apart by their color's name, then by number ("Gauge (white)", "Gauge 2").
    static func nameApart(_ groups: inout [ColorGroup]) {
        var byTitle: [String: [Int]] = [:]
        for (i, g) in groups.enumerated() { byTitle[g.role, default: []].append(i) }
        for (title, indices) in byTitle where indices.count > 1 {
            let colored = indices.map { "\(title) (\(LayerNaming.colorName(groups[$0].color)))" }
            let distinct = Set(colored).count == colored.count
            for (n, i) in indices.enumerated() { groups[i].distinctName = distinct ? colored[n] : "\(title) \(n + 1)" }
        }
    }

    /// Color variables defined in a file shared with other widgets that this widget does not use, in the order they
    /// are defined (§8.1.1: "Colors other widgets use"). One with the same value as a color this widget uses is not
    /// listed: its row changes it (`colorGroups`).
    public func colorsOtherWidgetsUse() -> [Value] {
        let used = Set(values.filter { $0.kind == .color && !$0.isCalculated && !$0.uses.isEmpty && $0.variableName != nil }
            .compactMap { $0.color.map(ValueUsageIndex.colorKey) })
        return values.filter { v in
            guard v.kind == .color, v.uses.isEmpty, !v.isInternal, !v.isCalculated, v.variableName != nil,
                  let color = v.color, !used.contains(ValueUsageIndex.colorKey(color)) else { return false }
            if case .shared = v.origin { return true }
            return false
        }
    }

    /// Variables used for positions and sizes (§8.1.4 "Shared sizes"), in the order they are defined.
    public func sharedSizes() -> [Value] {
        values.filter { v in
            v.kind == .size && v.variableName != nil && !v.isInternal
                && v.uses.contains { ValueUsageIndex.isSizeKey($0.key) }
        }
    }

    // MARK: - Helpers

    /// A color as the index keys it: `R,G,B,A` with whole numbers.
    public static func colorKey(_ c: RGBA) -> String {
        [c.r, c.g, c.b, c.a].map { String(Int($0.rounded())) }.joined(separator: ",")
    }

    /// A variable name as words ("BarW" → "Bar width", "PanelHeight" → "Panel height", "CPUColor" → "CPU color").
    public static func humanizedVariable(_ name: String) -> String {
        let words = LayerNaming.humanized(name).split(separator: " ").map(String.init)
        let expanded = words.enumerated().map { i, w -> String in
            switch w {
            case "W": return i == 0 ? "Width" : "width"
            case "H": return i == 0 ? "Height" : "height"
            default: return w
            }
        }
        return expanded.joined(separator: " ")
    }

    /// A look's name as words, without the customary `Style` prefix ("StyleSmall" → "Small").
    public static func humanizedLook(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.count > 5, n.lowercased().hasPrefix("style") {
            let next = n[n.index(n.startIndex, offsetBy: 5)]
            if next.isUppercase || next.isNumber || next == "_" || next == " " { n = String(n.dropFirst(5)) }
        }
        return LayerNaming.humanized(n)
    }

    /// "Small" → "Small text"; a name that already says text stays as it is (§8.1.1 role names).
    public static func textRole(_ words: String) -> String { ValueUsageScanner.textRole(words) }

    /// A layer's words inside a role name: its humanised section name, or `title` when the section name ends in digits.
    public static func layerWords(_ meter: Meter, title: String) -> String { ValueUsageScanner.sectionWords(meter, title: title) }

    static func merge(_ lists: [[Role]]) -> [Role] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var actions: Set<String> = []
        for list in lists {
            for r in list {
                if counts[r.name] == nil { order.append(r.name) }
                counts[r.name, default: 0] += r.count
                if r.isAction { actions.insert(r.name) }
            }
        }
        return sorted(order.map { Role(name: $0, count: counts[$0] ?? 0, isAction: actions.contains($0)) })
    }

    /// Most used first; on a tie, what is drawn before what an action sets, then in order of appearance.
    static func sorted(_ roles: [Role]) -> [Role] {
        roles.enumerated().sorted { a, b in
            if a.element.count != b.element.count { return a.element.count > b.element.count }
            if a.element.isAction != b.element.isAction { return !a.element.isAction }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// True for options whose value is a color (by name, as skins use them).
    public static func isColorKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.hasSuffix("color") || k.contains("color2") || k == "solidcolor" || k == "solidcolor2"
            || k.hasPrefix("fontcolor") || k.hasPrefix("barcolor") || k.hasPrefix("linecolor")
            || k.hasPrefix("primarycolor") || k.hasPrefix("secondarycolor") || k.hasPrefix("bothcolor")
            || k.hasPrefix("fonteffectcolor") || k.hasPrefix("imagetint")
    }

    /// Option keys that hold a position or a size (the shapes of a Shape meter included).
    public static func isSizeKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if ["x", "y", "w", "h", "fontsize", "padding", "linewidth", "linelength", "linestart", "skinwidth", "skinheight",
            "barborder", "offsetx", "offsety", "dragmargins"].contains(k) {
            return true
        }
        return ShapeSpec.index(ofOption: key) != nil
    }
}

// MARK: - Rewriting literal colors

extension ValueUsageIndex {
    /// `raw` with every occurrence of the color `old` replaced by `new` (`key` says what kind of option it is: a
    /// color option, a Shape (`Fill Color …`, `Stroke Color …`), a gradient (`180 | 1,2,3 ; 0.0 | …`) or an inline
    /// setting (`Color | 1,2,3`)); nil when there is none. Everything else stays as written.
    public static func replacingColor(_ old: RGBA, with new: RGBA, in raw: String, key: String) -> String? {
        let oldKey = colorKey(old)
        func matches(_ text: Substring) -> Bool {
            let t = IniSyntax.trim(text)
            guard !t.isEmpty, !t.contains("#"), !t.contains("["), let c = OptionValue.color(String(t)) else { return false }
            return colorKey(c) == oldKey
        }
        func formatted(like text: Substring) -> String { ColorText.format(new, like: String(IniSyntax.trim(text))) }
        if isColorKey(key) {
            return matches(Substring(raw)) ? formatted(like: Substring(raw)) : nil
        }
        // Segments separated by `|`; each rewritten in place, keeping its spacing.
        var changed = false
        var out = ""
        let segments = raw.split(separator: "|", omittingEmptySubsequences: false)
        for (i, segment) in segments.enumerated() {
            if i > 0 { out += "|" }
            if let rewritten = rewriteSegment(segment, index: i, matches: matches, formatted: formatted) {
                out += rewritten
                changed = true
            } else {
                out += segment
            }
        }
        return changed ? out : nil
    }

    private static func rewriteSegment(_ segment: Substring, index: Int, matches: (Substring) -> Bool,
                                       formatted: (Substring) -> String) -> String? {
        func blanks(_ s: Substring) -> (lead: Substring, trail: Substring) {
            let lead = s.prefix { $0 == " " || $0 == "\t" }
            let rest = s.dropFirst(lead.count)
            var end = rest.endIndex
            while end > rest.startIndex, rest[rest.index(before: end)] == " " || rest[rest.index(before: end)] == "\t" {
                end = rest.index(before: end)
            }
            return (lead, rest[end...])
        }
        let (lead, trail) = blanks(segment)
        let body = segment.dropFirst(lead.count).dropLast(trail.count)
        let lower = body.lowercased()
        // `Fill Color c`, `Stroke Color c` (Shape).
        for prefix in ["fill color", "stroke color"] where lower.hasPrefix(prefix) {
            let color = body.dropFirst(prefix.count)
            guard matches(color) else { return nil }
            let spaces = color.prefix { $0 == " " || $0 == "\t" }
            return String(lead) + body.prefix(prefix.count) + spaces + formatted(color) + trail
        }
        // A gradient stop `c ; offset`, or an inline setting's color (the segment after `Color`).
        guard index > 0 else { return nil }
        let parts = segment.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let color = parts.first, matches(color) else { return nil }
        let (cl, ct) = blanks(color)
        let rest = parts.count > 1 ? ";" + parts[1] : ""
        return String(cl) + formatted(color) + ct + rest
    }
}

// MARK: - Writing a shared value for one widget

extension IniWriter {
    /// Writes `key=value` into the first `[section]` block of the file so that it wins over the same key read from
    /// the block's `@Include` files (docs/editor-friendly.md §8.1.1, "This Widget"). Per the include rules
    /// (`SkinFileLoader` 5 and 6): a key written after the `@Include` lines overrides the included one, and inside
    /// one file the first definition of a key wins — so a definition before the last `@Include` is moved after it
    /// (removed, then appended at the end of the block). A definition already after the includes is updated in place.
    public static func writeAfterIncludes(_ value: String, key: String, section: String, fileURL: URL) throws {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let (text, encoding) = try TextDecoding.readFileDetectingEncoding(at: target)
        let updated = try writingAfterIncludes(text, value: value, key: key, section: section)
        if updated.utf8.elementsEqual(text.utf8) { return }
        let data = TextDecoding.encodeForWriting(updated, preferring: encoding)
        try data.write(to: target, options: .atomic)
    }

    /// The text-level operation behind `writeAfterIncludes`.
    public static func writingAfterIncludes(_ text: String, value: String, key: String, section: String) throws -> String {
        let sectionName = IniSyntax.trim(section)
        let keyName = IniSyntax.trim(key)
        var inside = false
        var lastInclude: Int?
        var firstKey: Int?
        var index = 0
        var done = false
        IniSyntax.forEachLineWithTerminator(in: text) { content, _ in
            defer { index += 1 }
            guard !done else { return }
            switch IniSyntax.classify(content) {
            case .section(let name):
                if inside { done = true; return }
                if let name, IniSyntax.namesEqual(name, sectionName) { inside = true }
            case .entry(let k, _):
                guard inside else { return }
                if k.lowercased().hasPrefix("@include") { lastInclude = index }
                if firstKey == nil, IniSyntax.namesEqual(k, keyName) { firstKey = index }
            default:
                break
            }
        }
        if let firstKey, let lastInclude, firstKey < lastInclude {
            let removed = removingKey(text, key: keyName, section: sectionName)
            return try updating(removed, value: value, key: keyName, section: sectionName)
        }
        return try updating(text, value: value, key: keyName, section: sectionName)
    }
}

// MARK: - Building the index

extension Skin {
    /// Where the skin's shared values are used (see `ValueUsageIndex`).
    public func valueUsages() -> ValueUsageIndex {
        ValueUsageScanner(skin: self).index()
    }

    /// A number that changes whenever a variable's value does (`!SetVariable`, previews): with the skin object and
    /// its previews, what the editor's cache of `valueUsages()` is keyed on (the files of one skin object never
    /// change: a refresh loads a new one).
    public var variableStamp: Int {
        var hasher = Hasher()
        for e in document.section(named: "Variables")?.entries ?? [] {
            hasher.combine(e.key.lowercased())
            hasher.combine(variable(e.key))
        }
        return hasher.finalize()
    }

    /// Whether a file is one of this widget's own (its .ini, or a file in its folder outside `@Resources`), as opposed
    /// to one shared with the other widgets of its root config.
    public func isOwnFile(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == fileURL.standardizedFileURL.resolvingSymlinksInPath().path { return true }
        let folder = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let resources = resourcesDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(folder) && !path.hasPrefix(resources)
    }

    /// The configs of this widget's root config (itself included) whose skin files read `file` through their
    /// `@Include`s, sorted — who changes when a shared value is written where it is defined (§8.1.1 "All 9 Widgets").
    public func configsIncluding(_ file: URL) -> [String] {
        includeMap().configs(including: file)
    }

    /// Which configs of this widget's root config read which files through their `@Include`s: every .ini file of
    /// every config folder is loaded once, the way the engine loads it (include paths expanded with the built-in path
    /// variables and the variables read so far); a config counts once, whichever of its files includes a file.
    /// One walk answers `configsIncluding` for every shared file (a suite of 300 skins took a second per file).
    public func includeMap() -> IncludeMap {
        let root = rootConfigDirectory.standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return IncludeMap()
        }
        func dir(_ url: URL) -> String { url.path.hasSuffix("/") ? url.path : url.path + "/" }
        var map = IncludeMap()
        var visited = 0
        for case let url as URL in walker {
            if url.lastPathComponent.hasPrefix("@") { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "ini", visited < 400 else { continue }
            visited += 1
            let folder = url.deletingLastPathComponent().standardizedFileURL
            let relative = folder.path.hasPrefix(root.path) ? String(folder.path.dropFirst(root.path.count)) : ""
            let config = ([rootConfig] + relative.split(separator: "/").map(String.init)).joined(separator: "\\")
            let builtins: [String: String] = [
                "@": dir(resourcesDirectory), "currentpath": dir(folder), "currentfile": url.lastPathComponent,
                "currentconfig": config, "rootconfig": rootConfig, "rootconfigpath": dir(rootConfigDirectory),
                "skinspath": dir(skinsDirectory),
            ]
            guard let loaded = try? SkinFileLoader.load(url: url, expandVariables: { raw, readSoFar in
                VariableResolver(variableLookup: { readSoFar[$0.lowercased()] ?? builtins[$0.lowercased()] }).resolve(raw)
            }) else { continue }
            for included in loaded.includedFiles {
                map.readers[IncludeMap.key(included), default: []].insert(config.lowercased())
            }
        }
        return map
    }

    /// The files each config reads through `@Include` (`Skin.includeMap()`).
    public struct IncludeMap: Equatable {
        /// A file's standardised, symlink-resolved path → the configs (lowercased) that read it.
        var readers: [String: Set<String>] = [:]

        public init() {}

        static func key(_ file: URL) -> String { file.standardizedFileURL.resolvingSymlinksInPath().path }

        /// The configs reading `file`, sorted.
        public func configs(including file: URL) -> [String] { (readers[Self.key(file)] ?? []).sorted() }
    }

    /// A file shared with other widgets that is one of several a variable chooses between — a theme, read by
    /// `@IncludeTheme=#@#Themes/#Theme#.inc` — as opposed to one every widget always reads (`@Include=#@#Variables.inc`).
    /// Found from the `@Include` line of this widget's files that reads `file` with a variable in its file name.
    public struct SwitchedInclude: Equatable {
        /// The variable that chooses the file ("Theme").
        public var variable: String
        /// The file's name without its extension ("Dark").
        public var name: String
        /// The other files it can choose: the same folder and extension ("Light"), sorted.
        public var others: [String]
    }

    public func switchedInclude(_ file: URL) -> SwitchedInclude? {
        let target = file.standardizedFileURL.resolvingSymlinksInPath().path
        for source in sourceFiles {
            guard let text = try? TextDecoding.readFileDetectingEncoding(at: source).text else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("@include"), let eq = trimmed.firstIndex(of: "=") else { continue }
                var raw = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") { raw = String(raw.dropFirst().dropLast()) }
                let slashed = raw.replacingOccurrences(of: "\\", with: "/")
                let fileName = slashed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? slashed
                // A variable of the widget's own (not a path such as #@#) chooses the file.
                guard let variable = SkinInspection.referencedVariables(in: fileName).first(where: {
                    !BuiltInVariables.isBuiltIn($0.lowercased())
                }) else { continue }
                let resolved = resolve(slashed, in: nil, sectionVariables: false)
                let candidates = [absolutePath(resolved), absolutePath(resolved, relativeTo: source.deletingLastPathComponent())]
                guard candidates.contains(where: {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == target
                }) else { continue }
                let folder = file.deletingLastPathComponent()
                let ext = file.pathExtension.lowercased()
                let others = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == ext && $0.lastPathComponent != file.lastPathComponent }
                    .map { $0.deletingPathExtension().lastPathComponent }.sorted()
                return SwitchedInclude(variable: variable, name: file.deletingPathExtension().lastPathComponent, others: others)
            }
        }
        return nil
    }

    /// The layer the editor calls "Background" (`LayerNaming.background(in:)`), or — until that rule is in place —
    /// the same rule applied here (docs/editor-friendly.md §5.2): the first visible Shape or Picture / Color block,
    /// outside any container, that covers at least 90% of the widget.
    public func detectedBackgroundLayer() -> String? {
        if let name = LayerNaming.background(in: self) { return name }
        guard let first = meters.first(where: { !$0.hidden && $0.container == nil }),
              first.type == "shape" || first.type == "image" else { return nil }
        let area = width * height
        guard area > 0 else { return nil }
        let f = first.frame
        let w = max(0, min(f.x + f.width, width) - max(f.x, 0)), h = max(0, min(f.y + f.height, height) - max(f.y, 0))
        return w * h >= 0.9 * area ? first.name : nil
    }
}

/// Collects the uses of every value of a skin (`Skin.valueUsages()`).
struct ValueUsageScanner {
    let skin: Skin
    /// One namer for the whole scan: roles name layers and data for every use.
    let namer: LayerNamer

    init(skin: Skin) {
        self.skin = skin
        namer = LayerNaming.namer(for: skin)
    }

    /// A `[Variables]` entry as defined.
    struct Definition {
        var name: String
        var raw: String
        var current: String
        var file: URL?
    }

    func index() -> ValueUsageIndex {
        var definitions: [String: Definition] = [:]
        var order: [String] = []
        for v in skin.inspectedVariables() {
            let key = v.name.lowercased()
            guard definitions[key] == nil else { continue }
            definitions[key] = Definition(name: v.name, raw: v.raw, current: v.current, file: v.location?.file)
            order.append(key)
        }
        // Variables named in other variables' definitions, transitively (cycle-safe).
        var direct: [String: [String]] = [:]
        for (key, d) in definitions { direct[key] = Self.references(in: d.raw).names.map { $0.lowercased() } }
        func closure(_ key: String) -> [String] {
            var seen: Set<String> = [key]
            var result: [String] = []
            var stack = Array((direct[key] ?? []).reversed())
            while let next = stack.popLast() {
                guard seen.insert(next).inserted, definitions[next] != nil else { continue }
                result.append(next)
                stack.append(contentsOf: (direct[next] ?? []).reversed())
            }
            return result
        }

        var uses: [String: [ValueUsageIndex.Use]] = [:]
        var seenUses: [String: Set<String>] = [:]
        var atLeast: Set<String> = []
        var literals: [String: (raw: String, uses: [ValueUsageIndex.Use])] = [:]
        var literalOrder: [String] = []
        var usedKeys: [String: Set<String>] = [:]
        func add(_ variable: String, _ use: ValueUsageIndex.Use) {
            let key = variable.lowercased()
            guard definitions[key] != nil else { return }
            // One use per section and option (named directly wins over reached through another variable).
            let id = use.section.lowercased() + "\u{1F}" + use.key.lowercased()
            guard seenUses[key, default: []].insert(id).inserted else { return }
            uses[key, default: []].append(use)
            usedKeys[key, default: []].insert(use.key.lowercased())
        }
        func addLiteral(_ color: RGBA, raw: String, _ use: ValueUsageIndex.Use) {
            let key = ValueUsageIndex.colorKey(color)
            if literals[key] == nil {
                literals[key] = (raw, [])
                literalOrder.append(key)
            }
            if literals[key]?.uses.contains(use) == false { literals[key]?.uses.append(use) }
        }

        for section in sections() {
            let gradients = gradientOptions(of: section)
            for (key, raw, look) in fileOptions(of: section) {
                let lower = key.lowercased()
                if lower == "meter" || lower == "measure" || lower == "meterstyle" || lower == "plugin" { continue }
                let refs = Self.references(in: raw)
                for prefix in refs.dynamicPrefixes {
                    for name in order where name.hasPrefix(prefix.lowercased()) { atLeast.insert(name) }
                }
                for name in refs.names {
                    add(name, ValueUsageIndex.Use(section: section.name, key: key, look: look))
                }
                for name in refs.names {
                    for other in closure(name.lowercased()) {
                        add(other, ValueUsageIndex.Use(section: section.name, key: key, look: look,
                                                       via: definitions[name.lowercased()]?.name ?? name))
                    }
                }
                guard section is Meter || section is RainmeterSection else { continue }
                for color in Self.literalColors(in: raw, key: key, gradients: gradients) {
                    addLiteral(color, raw: raw, ValueUsageIndex.Use(section: section.name, key: key, look: look))
                }
            }
        }

        let background = skin.detectedBackgroundLayer()
        let followers = self.followers()
        // What a variable an action sets is drawn as (`HoverOn=[!SetVariable PanelBorderNow "#PanelBorderHover#"]`
        // colors what `PanelBorderNow` colors).
        let drawn: (String) -> [ValueUsageIndex.Use] = { name in
            (uses[name.lowercased()] ?? []).filter { !LayerReferences.isAction($0.key) }
        }
        var values: [ValueUsageIndex.Value] = []
        for key in order {
            guard let d = definitions[key] else { continue }
            let found = uses[key] ?? []
            let keys = usedKeys[key] ?? []
            let trimmed = d.raw.trimmingCharacters(in: .whitespaces)
            let calculated = trimmed.hasPrefix("(") || trimmed.contains("#") || trimmed.contains("[")
            let kind = Self.kind(raw: trimmed, current: d.current, name: d.name, keys: keys)
            let origin: ValueUsageIndex.Value.Origin = d.file.map { skin.isOwnFile($0) ? .own : .shared($0) } ?? .none
            var value = ValueUsageIndex.Value(source: .variable(d.name), uses: found, kind: kind, raw: d.raw,
                                              current: d.current, origin: origin, file: d.file, isCalculated: calculated,
                                              isAtLeast: atLeast.contains(key),
                                              isInternal: Self.isInternal(name: d.name, raw: d.raw))
            value.roles = roles(of: found, kind: kind, background: background, token: .variable(d.name), drawn: drawn)
            values.append(value)
        }
        for key in literalOrder {
            guard let entry = literals[key] else { continue }
            let files = entry.uses.compactMap { definingFile(of: $0) }
            let shared = files.first { !skin.isOwnFile($0) }
            let ownOnly = shared == nil
            var value = ValueUsageIndex.Value(source: .literal(key), uses: entry.uses, kind: .color, raw: entry.raw,
                                              current: key, origin: ownOnly ? .own : .shared(shared ?? skin.fileURL))
            value.roles = roles(of: entry.uses, kind: .color, background: background,
                                token: OptionValue.color(key).map { .color($0) }, drawn: drawn)
            values.append(value)
        }
        return ValueUsageIndex(values: values, followers: followers)
    }

    /// Data item (lowercased) → the layers and data items that follow it: a layer showing it (`MeasureName`,
    /// `MeasureName2`…), any section naming it in an option (`X=[MeasurePeakX]`, `Text=[MeasureCPU:1]`), a Calc naming
    /// it in its formula.
    func followers() -> [String: [String]] {
        let measures = Set(skin.measures.map { $0.name.lowercased() })
        guard !measures.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        var seen: Set<String> = []
        func add(_ measure: String, _ follower: String) {
            let key = measure.lowercased()
            guard measures.contains(key), key != follower.lowercased(),
                  seen.insert(key + "\u{1F}" + follower.lowercased()).inserted else { return }
            result[key, default: []].append(follower)
        }
        for section in sections() where section is Meter || section is Measure {
            let isCalc = (section as? Measure)?.type == "calc"
            for (key, raw, _) in fileOptions(of: section) {
                let lower = key.lowercased()
                if lower == "meter" || lower == "measure" || lower == "meterstyle" || lower == "plugin" { continue }
                // Actions (a click, a condition) run later: what they name does not move or draw the section.
                if lower.hasSuffix("action") || lower.hasPrefix("ifcondition") || lower.hasPrefix("ifmatch") { continue }
                if section is Meter, lower.hasPrefix("measurename") {
                    add(raw.trimmingCharacters(in: .whitespaces), section.name)
                    continue
                }
                for name in Self.sectionReferences(in: raw) { add(name, section.name) }
                if isCalc, lower == "formula" {
                    for word in Self.identifiers(in: raw) { add(word, section.name) }
                }
            }
        }
        return result
    }

    /// The sections a value names as section variables: `[Name]`, `[Name:]`, `[Name:MaxValue]`, `[&Name]` (never
    /// `[#Var]`, `[*Escaped*]`, `[\x263A]` or a bang `[!…]`).
    static func sectionReferences(in raw: String) -> [String] {
        guard raw.contains("[") else { return [] }
        var names: [String] = []
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            guard chars[i] == "[" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] != "]", chars[j] != "[" { j += 1 }
            guard j < chars.count, chars[j] == "]" else { i = j; continue }
            var inner = String(chars[(i + 1)..<j]).trimmingCharacters(in: .whitespaces)
            if inner.hasPrefix("&") { inner.removeFirst() }
            if let colon = inner.firstIndex(of: ":") { inner = String(inner[..<colon]) }
            if let first = inner.first, !"#*!\\\"".contains(first) { names.append(inner) }
            i = j + 1
        }
        return names
    }

    /// The words of a formula that could name a data item (`MeasurePeak` in `Clamp(MeasurePeak, 0, 1)`).
    static func identifiers(in formula: String) -> [String] {
        var words: [String] = []
        var current = ""
        for c in formula {
            if c.isLetter || c.isNumber || c == "_" || c == "." {
                current.append(c)
            } else {
                if let first = current.first, first.isLetter || first == "_" { words.append(current) }
                current = ""
            }
        }
        if let first = current.first, first.isLetter || first == "_" { words.append(current) }
        return words
    }

    /// `[Rainmeter]`, then the measures and meters in file order.
    func sections() -> [SkinSection] {
        var result: [SkinSection] = []
        if let r = skin.rainmeterSection { result.append(r) }
        var byName: [String: SkinSection] = [:]
        for m in skin.measures { byName[m.name.lowercased()] = m }
        for m in skin.meters { byName[m.name.lowercased()] = m }
        for s in skin.document.sections {
            if let section = byName.removeValue(forKey: s.name.lowercased()) { result.append(section) }
        }
        return result
    }

    /// Every option of a section as the files define it: (key as written, raw value, the look that writes it).
    func fileOptions(of section: SkinSection) -> [(String, String, String?)] {
        var keys: [String] = []
        var seen: Set<String> = []
        for e in section.own.entries where seen.insert(e.key.lowercased()).inserted { keys.append(e.key) }
        for style in section.styles {
            for e in skin.styleSection(named: style)?.entries ?? [] where seen.insert(e.key.lowercased()).inserted {
                keys.append(e.key)
            }
        }
        return keys.compactMap { key in
            guard let raw = section.fileOption(key), !raw.isEmpty else { return nil }
            var look: String?
            if case .style(let name, _)? = section.fileOrigin(key) { look = name }
            return (key, raw, look)
        }
    }

    /// The options of a Shape meter that its shapes name as gradients (`Fill LinearGradient RAMFill`), lowercased.
    func gradientOptions(of section: SkinSection) -> Set<String> {
        guard let meter = section as? Meter, meter.type == "shape" else { return [] }
        var names: Set<String> = []
        for (key, raw, _) in fileOptions(of: section) where ShapeSpec.index(ofOption: key) != nil {
            for segment in raw.split(separator: "|") {
                let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard words.count >= 3, ["fill", "stroke"].contains(words[0].lowercased()),
                      words[1].lowercased().hasSuffix("gradient") else { continue }
                names.insert(words[2].lowercased())
            }
        }
        return names
    }

    /// The file that defines a use's option (the section's own value or its look's).
    func definingFile(of use: ValueUsageIndex.Use) -> URL? {
        guard let s = skin.section(named: use.section) else { return nil }
        return s.fileOrigin(use.key)?.location?.file
    }

    // MARK: Parsing

    /// Variables named in a value: `#Name#` and `[#Name]`; for names built at run time (`[#Color[#Index]]`), the part
    /// before the nested name (`Color`).
    static func references(in raw: String) -> (names: [String], dynamicPrefixes: [String]) {
        var names = SkinInspection.referencedVariables(in: raw)
        var seen = Set(names.map { $0.lowercased() })
        var prefixes: [String] = []
        guard raw.contains("[#") else { return (names, prefixes) }
        let chars = Array(raw)
        var i = 0
        while i + 1 < chars.count {
            guard chars[i] == "[", chars[i + 1] == "#" else { i += 1; continue }
            // The matching `]`, counting nested brackets.
            var depth = 0
            var j = i
            var nested = false
            while j < chars.count {
                if chars[j] == "[" {
                    depth += 1
                    if j > i { nested = true }
                } else if chars[j] == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            guard j < chars.count else { break }
            let inner = String(chars[(i + 2)..<j])
            if nested {
                let prefix = String(inner.prefix { $0 != "[" }).trimmingCharacters(in: .whitespaces)
                if !prefix.isEmpty { prefixes.append(prefix) }
            } else if !inner.isEmpty, !inner.hasPrefix("*"), seen.insert(inner.lowercased()).inserted {
                names.append(inner)
            }
            i = j + 1
        }
        return (names, prefixes)
    }

    /// Colors written directly in an option: the whole value of a color option, `Fill Color` / `Stroke Color` of a
    /// Shape, the stops of a gradient option, `Color | …` of an inline setting.
    static func literalColors(in raw: String, key: String, gradients: Set<String>) -> [RGBA] {
        func literal(_ text: Substring) -> RGBA? {
            let t = IniSyntax.trim(text)
            guard !t.isEmpty, !t.contains("#"), !t.contains("["), !t.contains("(") else { return nil }
            return OptionValue.color(String(t))
        }
        let lower = key.lowercased()
        if ValueUsageIndex.isColorKey(key) { return literal(Substring(raw)).map { [$0] } ?? [] }
        let segments = raw.split(separator: "|", omittingEmptySubsequences: false)
        var result: [RGBA] = []
        if ShapeSpec.index(ofOption: key) != nil {
            for segment in segments {
                let t = IniSyntax.trim(segment)
                let l = t.lowercased()
                for prefix in ["fill color", "stroke color"] where l.hasPrefix(prefix) {
                    if let c = literal(t.dropFirst(prefix.count)) { result.append(c) }
                }
            }
        } else if gradients.contains(lower) {
            for segment in segments.dropFirst() {
                if let first = segment.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                   let c = literal(first) { result.append(c) }
            }
        } else if lower.hasPrefix("inlinesetting"), segments.count >= 2,
                  IniSyntax.trim(segments[0]).lowercased() == "color", let c = literal(segments[1]) {
            result.append(c)
        }
        return result
    }

    static func kind(raw: String, current: String, name: String, keys: Set<String>) -> ValueUsageIndex.Value.Kind {
        if keys.contains("fontface") { return .font }
        let value = current.trimmingCharacters(in: .whitespaces)
        let isColor = OptionValue.color(value) != nil
        if isColor, keys.contains(where: ValueUsageIndex.isColorKey) { return .color }
        // `R,G,B[,A]`: a color, unless it is only used where numbers go (a position, a size).
        if isColor, value.contains(","), !value.contains("|"), value.split(separator: ",").count <= 4,
           !keys.contains(where: { ValueUsageIndex.isSizeKey($0) && ShapeSpec.index(ofOption: $0) == nil }) {
            return .color
        }
        let lowerName = name.lowercased()
        if keys.isEmpty, isColor, lowerName.hasSuffix("color") || lowerName.hasSuffix("color2") { return .color }
        if keys.isEmpty, lowerName.contains("font"), OptionValue.number(value) == nil { return .font }
        if OptionValue.number(value) != nil || raw.hasPrefix("(") {
            if keys.isEmpty || keys.contains(where: ValueUsageIndex.isSizeKey) { return .size }
        }
        return .other
    }

    /// Values only an expert needs to see: theme switching, menu titles, actions.
    static func isInternal(name: String, raw: String) -> Bool {
        let n = name.lowercased()
        if raw.contains("[!") { return true }
        return n.hasPrefix("theme") || n.hasSuffix("menutitle") || n.hasSuffix("menuaction")
    }

    // MARK: Roles

    /// The roles of a value's uses, in words (docs/editor-friendly.md §8.1.1).
    /// What a role looks for inside an option: the variable the value is (or is reached through), or a literal color.
    enum Token {
        case variable(String)
        case color(RGBA)
    }

    func roles(of uses: [ValueUsageIndex.Use], kind: ValueUsageIndex.Value.Kind, background: String?,
               token: Token?, drawn: (String) -> [ValueUsageIndex.Use] = { _ in [] }) -> [ValueUsageIndex.Role] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var actions: Set<String> = []
        // Empty parts of bars: a Bar's SolidColor, or the full-length part of a Shape whose other part follows data.
        let emptyBars = uses.filter { use in
            guard let meter = skin.meter(named: use.section) else { return false }
            return (meter.type == "bar" && use.key.lowercased() == "solidcolor") || isTrack(use, of: meter)
        }.count
        let dimmed = uses.filter { $0.key.lowercased().hasPrefix("inlinesetting") }.count
        for use in uses {
            var found = token
            if let via = use.via { found = .variable(via) }
            var name = role(of: use, kind: kind, background: background, emptyBars: emptyBars, token: found)
            if LayerReferences.isAction(use.key), let own = token,
               let set = roleSetByAction(use, holding: own, background: background, drawn: drawn) {
                name = set
            }
            if use.key.lowercased().hasPrefix("inlinesetting"), dimmed > 1, let meter = skin.meter(named: use.section) {
                name = "\(inlineWord(use, of: meter, token: found)) parts of texts"
            }
            guard let name else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
            if use.key.lowercased().hasSuffix("action") { actions.insert(name) }
        }
        return ValueUsageIndex.sorted(order.map {
            ValueUsageIndex.Role(name: $0, count: counts[$0] ?? 0, isAction: actions.contains($0))
        })
    }

    func role(of use: ValueUsageIndex.Use, kind: ValueUsageIndex.Value.Kind, background: String?, emptyBars: Int,
              token: Token? = nil, in known: Meter? = nil) -> String? {
        let key = use.key.lowercased()
        guard let meter = known ?? skin.meter(named: use.section) else {
            if use.section.caseInsensitiveCompare("Rainmeter") == .orderedSame {
                if key == "mouseoveraction" { return "Color while you point at the widget" }
                if key == "mouseleaveaction" { return "Color after the pointer leaves the widget" }
                return key.hasPrefix("solidcolor") ? "Widget background" : "Widget settings"
            }
            if let m = skin.measure(named: use.section) { return "Changes with \(LayerNaming.inSentence(namer.data(m).name))" }
            return nil
        }
        let title = namer.layer(meter).title
        let words = Self.sectionWords(meter, title: title)
        let isBackground = background.map { $0.caseInsensitiveCompare(meter.name) == .orderedSame } ?? false
        let data = meter.measures.first.map { namer.data($0).short }
        func withData(_ noun: String) -> String { data.map { "\($0) \(noun)" } ?? Self.capitalizedFirst(noun) }
        switch key {
        case "barcolor":
            return "Bar color"
        case "solidcolor" where meter.type == "bar":
            return emptyBars > 1 ? "Empty part of bars" : "Empty part of \(Self.lowercasedFirst(title))"
        case "solidcolor", "solidcolor2":
            if isBackground { return "Background panel" }
            if meter.type == "image", (meter.rawOption("ImageName") ?? "").isEmpty { return title }
            return "Box behind \(Self.lowercasedFirst(title))"
        case "fontcolor":
            if let look = use.look { return Self.textRole(ValueUsageIndex.humanizedLook(look)) }
            return Self.textRole(words)
        case "fonteffectcolor":
            return "\(Self.textRole(use.look.map(ValueUsageIndex.humanizedLook) ?? words)) shadow"
        case "mouseoveraction":
            return "\(Self.lowercasedFirst(words)) when pointed at"
        case "mouseleaveaction":
            return "\(Self.lowercasedFirst(words)) when the pointer leaves"
        case "leftmouseupaction", "leftmousedownaction":
            return "\(Self.lowercasedFirst(words)) when clicked"
        default:
            break
        }
        if key.hasPrefix("linecolor") {
            let n = Int(key.dropFirst("linecolor".count)) ?? 1
            let shown = n > 1 && n - 1 < meter.measures.count ? namer.data(meter.measures[n - 1]).short : data
            let noun = meter.type == "roundline" ? "gauge" : "graph line"
            // A gauge with no data (a clock face, its ticks): named after its look or itself ("Tick", "Face").
            return shown.map { "\($0) \(noun)" } ?? use.look.map(ValueUsageIndex.humanizedLook) ?? words
        }
        if key.hasPrefix("primarycolor") || key.hasPrefix("secondarycolor") || key.hasPrefix("bothcolor") {
            return withData("graph fill")
        }
        if key.hasPrefix("horizontallinecolor") { return withData("graph grid lines") }
        if key.hasPrefix("inlinesetting") {
            let text = Self.textRole(use.look.map(ValueUsageIndex.humanizedLook) ?? words)
            return "\(inlineWord(use, of: meter, token: token)) part of \(Self.lowercasedFirst(text))"
        }
        if meter.type == "shape" {
            let what = isBackground ? "Background panel" : title
            guard let raw = meter.fileOption(use.key) else { return what }
            let segments = raw.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let index = token.flatMap { t in segments.firstIndex { Self.segment($0, holds: t) } }
            if ShapeSpec.index(ofOption: use.key) != nil {
                if let index, segments[index].lowercased().hasPrefix("stroke") {
                    // A line's stroke is the line itself (a highlight along the panel's top), not an outline.
                    let open = ShapeSpec.parse(raw).map { [.line, .arc, .curve].contains($0.kind) } ?? false
                    return open ? "\(what) line" : "\(what) outline"
                }
                // The full-length part under a part that follows data: the empty part of the bar.
                if isTrack(use, of: meter) {
                    return emptyBars > 1 ? "Empty part of bars" : "Empty part of \(Self.lowercasedFirst(title))"
                }
                return what
            }
            // A gradient option: its first and last stops are the two ends of the fade, named by where they are.
            if let index, index > 0, segments.count > 2 {
                let ends = Self.gradientEnds(angle: segments[0])
                if index == 1 { return "\(what) (\(ends.start))" }
                if index == segments.count - 1 { return "\(what) (\(ends.end))" }
            }
            return what
        }
        if kind == .color { return "\(title) \(LayerNaming.humanized(use.key).lowercased())" }
        return title
    }

    /// Where a linear gradient's first and last stops are, from its angle (`ShapeGradients.linearEndpoints`: 270 runs
    /// top → bottom, 90 bottom → top, 180 left → right, 0 right → left); "start" and "end" for a slanted one.
    static func gradientEnds(angle text: String) -> (start: String, end: String) {
        guard let angle = OptionValue.number(String(IniSyntax.trim(Substring(text)))) else { return ("start", "end") }
        let a = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch a {
        case 255...285: return ("top", "bottom")
        case 75...105: return ("bottom", "top")
        case 165...195: return ("left", "right")
        case 0...15, 345..<360: return ("right", "left")
        default: return ("start", "end")
        }
    }

    /// Whether a use is the full-length part of a Shape under a part that follows data (the grey track of a memory
    /// bar): a shape option naming no data, in a Shape whose other options do.
    func isTrack(_ use: ValueUsageIndex.Use, of meter: Meter) -> Bool {
        guard meter.type == "shape", ShapeSpec.index(ofOption: use.key) != nil,
              LayerReferences.bracketNames(in: meter.fileOption(use.key) ?? "").isEmpty else { return false }
        return LayerReferences.shapeKeys(of: meter).contains { key in
            key.caseInsensitiveCompare(use.key) != .orderedSame
                && !LayerReferences.bracketNames(in: meter.fileOption(key) ?? "").isEmpty
        }
    }

    /// "Dimmed" when a styled part's color is fainter than the text around it (the grey " / 16 GB"), else
    /// "Highlighted".
    func inlineWord(_ use: ValueUsageIndex.Use, of meter: Meter, token: Token?) -> String {
        let segments = (meter.fileOption(use.key) ?? "").split(separator: "|", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return "Styled" }
        let resolved = skin.resolveStandardVariables(String(segments[1]), in: meter).trimmingCharacters(in: .whitespaces)
        let text = skin.resolveStandardVariables(meter.rawOption("FontColor") ?? "255,255,255,255", in: meter)
        guard let part = OptionValue.color(resolved), let around = OptionValue.color(text) else { return "Styled" }
        func strength(_ c: RGBA) -> Double { (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255 * c.a / 255 }
        // On a dark panel fainter means darker; the text's own brightness says which side it is on.
        let fainter = strength(around) > 0.5 ? strength(part) < strength(around) : strength(part) > strength(around)
        return fainter ? "Dimmed" : "Highlighted"
    }

    /// The role of a color an action sets (`!SetVariable PanelBorderNow "#PanelBorderHover#"` in a MouseOverAction,
    /// `!SetOption MeterFill FontColor "#Low#"` in an IfTrueAction): what it colors then, in which state
    /// ("Background panel outline when pointed at", "Battery bar in some states"); nil when the action sets nothing
    /// that is drawn.
    func roleSetByAction(_ use: ValueUsageIndex.Use, holding token: Token, background: String?,
                         drawn: (String) -> [ValueUsageIndex.Use]) -> String? {
        let raw: String
        if let via = use.via, let definition = skin.document.section(named: "Variables")?.value(forKey: via) {
            raw = definition
        } else {
            guard let own = skin.section(named: use.section)?.fileOption(use.key) else { return nil }
            raw = own
        }
        guard raw.contains("!") else { return nil }
        var target: String?
        for action in ActionParser.parse(raw) {
            guard case .bang(let b) = action, b.args.count >= 2 else { continue }
            if b.name == "setvariable", Self.text(b.args[1], holds: token) {
                let uses = drawn(b.args[0])
                let found = uses.lazy.compactMap { u -> String? in
                    guard let m = self.skin.meter(named: u.section) else { return nil }
                    return self.role(of: u, kind: .color, background: background, emptyBars: 0,
                                     token: .variable(u.via ?? b.args[0]), in: m)
                }.first
                if let found { target = found; break }
            } else if b.name == "setoption", b.args.count >= 3, Self.text(b.args[2], holds: token),
                      let m = skin.meter(named: skin.resolveStandardVariables(b.args[0], in: skin.section(named: use.section))) {
                target = role(of: ValueUsageIndex.Use(section: m.name, key: b.args[1]), kind: .color, background: background,
                              emptyBars: 0, token: nil, in: m)
                if target != nil { break }
            }
        }
        guard let target else { return nil }
        switch use.key.lowercased() {
        case "mouseoveraction": return "\(target) when pointed at"
        // Leaving puts back the color it has the rest of the time.
        case "mouseleaveaction": return target
        case let k where k.hasPrefix("left") || k.hasPrefix("right") || k.hasPrefix("middle"): return "\(target) when clicked"
        default: return skin.measure(named: use.section) != nil ? "\(target) in some states" : target
        }
    }

    /// Whether an action argument holds the value.
    static func text(_ text: String, holds token: Token) -> Bool {
        switch token {
        case .variable(let name):
            return text.range(of: "#\(name)#", options: .caseInsensitive) != nil
                || text.range(of: "[#\(name)]", options: .caseInsensitive) != nil
        case .color(let color):
            return OptionValue.color(text.trimmingCharacters(in: .whitespaces)).map(ValueUsageIndex.colorKey)
                == ValueUsageIndex.colorKey(color)
        }
    }

    /// Whether one `|` segment of a Shape or gradient option holds the value.
    static func segment(_ segment: String, holds token: Token) -> Bool {
        switch token {
        case .variable(let name):
            return segment.range(of: "#\(name)#", options: .caseInsensitive) != nil
                || segment.range(of: "[#\(name)]", options: .caseInsensitive) != nil
        case .color(let color):
            let key = ValueUsageIndex.colorKey(color)
            let lower = segment.lowercased()
            var text = Substring(segment)
            for prefix in ["fill color", "stroke color"] where lower.hasPrefix(prefix) { text = text.dropFirst(prefix.count) }
            if let stop = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first { text = stop }
            return OptionValue.color(String(text).trimmingCharacters(in: .whitespaces)).map(ValueUsageIndex.colorKey) == key
        }
    }

    /// The words for a layer inside a role: its humanised section name, or its title when the section name ends in
    /// digits ("MeterBand5" names nothing a person would recognise).
    static func sectionWords(_ meter: Meter, title: String) -> String {
        if let last = meter.name.last, last.isNumber { return title }
        return LayerNaming.humanized(meter.name)
    }

    /// "Small" → "Small text"; a name that already says text stays as it is.
    static func textRole(_ words: String) -> String {
        if words.lowercased() == "text" { return "Main text" }
        return words.lowercased().hasSuffix("text") ? words : "\(words) text"
    }

    /// The first letter in lowercase, unless the first word is an acronym ("CPU graph") or a quotation.
    static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first, first != "“" else { return s }
        let word = s.prefix { $0 != " " }
        if word.count > 1, word.allSatisfy({ $0.isUppercase || $0.isNumber }) { return s }
        // A word with a capital inside keeps its spelling ("Wi-Fi", "iPhone").
        if word.dropFirst().contains(where: \.isUppercase) { return s }
        return first.lowercased() + s.dropFirst()
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
