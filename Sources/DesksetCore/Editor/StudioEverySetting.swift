import Foundation

/// Every Setting: every option a part (or a data item) can take, in one dense page in the order of the box — what it
/// shows, its text, its look, its size and place, the box itself, the pointer and clicks, what VoiceOver says — with a
/// filter that answers to the same words as the search (`StudioAliasIndex`): typing a Rainmeter name ("FontColor")
/// keeps the row it maps to, and the row says which word found it.
public enum StudioEverySetting {
    /// The page's sections, in the order of the box.
    public enum Section: String, CaseIterable, Equatable {
        case content, text, look, layout, box, pointer, spoken

        public var title: (en: String, zh: String) {
            switch self {
            case .content: return ("Content", "内容")
            case .text: return ("Text", "文字")
            case .look: return ("Look", "外观")
            case .layout: return ("Size and position", "大小和位置")
            case .box: return ("Box", "盒子")
            case .pointer: return ("Pointer and clicks", "指针和点按")
            case .spoken: return ("Spoken", "朗读")
            }
        }

        /// Where a catalog section goes on this page (the pointer and the clicks are one section).
        public init(_ s: StudioCatalog.Section) {
            switch s {
            case .shows: self = .content
            case .text: self = .text
            case .look: self = .look
            case .layout: self = .layout
            case .clicks, .pointer: self = .pointer
            case .box: self = .box
            case .spoken: self = .spoken
            }
        }
    }

    public struct Row: Equatable {
        public var item: StudioCatalog.Item
        /// The value as the files write it (nil: not set, the default applies).
        public var written: String?
        /// The value in effect: as written, else the default for the other values.
        public var value: String
        /// The filter found the row by a Rainmeter name or another word, not its label: which.
        public var via: StudioAliasIndex.Via?

        public var key: String { item.property.key }
        public var isSet: Bool { !(written ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public struct Group: Equatable {
        public var section: Section
        public var rows: [Row]
    }

    /// The rows of a part, grouped in the order of the box. Options that do not apply to the part's other values are
    /// left out (a clip width while the text does not clip); `filter` keeps the rows whose words match it.
    public static func groups(meter m: Meter, filter: String = "") -> [Group] {
        let schema = EditorSchema.meterGroups(m.type)
        return groups(items: geometry + StudioCatalog.items(forMeterType: m.type), schema: schema,
                      values: { m.fileOption($0) }, filter: filter)
    }

    /// Where a part is and how big: X, Y, W, H (the schema leaves them to the canvas; this page lists them).
    static let geometry: [StudioCatalog.Item] = ["X", "Y", "W", "H"].compactMap { key in
        guard let field = StudioCatalog.field(key) else { return nil }
        return StudioCatalog.Item(property: EditorSchema.Property(key, field.en, .formula, level: .essential),
                                  field: field)
    }

    /// The rows of a data item (a measure), grouped as a part's are (its settings are all in Content).
    public static func groups(measure: Measure, filter: String = "") -> [Group] {
        let plugin = measure.type.lowercased() == "plugin" ? measure.string("Plugin") : nil
        let schema = EditorSchema.measureGroups(measure.type, plugin: plugin)
        return groups(items: StudioCatalog.items(forMeasureType: measure.type, plugin: plugin), schema: schema,
                      values: { measure.fileOption($0) }, filter: filter, measure: true)
    }

    static func groups(items: [StudioCatalog.Item], schema: [EditorSchema.Group], values: (String) -> String?,
                       filter: String, measure: Bool = false) -> [Group] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var matched: [String: StudioAliasIndex.Via] = [:]
        if !query.isEmpty {
            // Each row's own words: its catalog entry (its labels, its Rainmeter names, its aliases).
            let index = StudioAliasIndex(fields: items.map(\.field))
            for m in index.matches(query) { matched[m.field.key.lowercased()] = m.via }
        }
        var bySection: [Section: [Row]] = [:]
        for item in items {
            let p = item.property
            guard EditorSchema.isVisible(p, in: schema, values: values) else { continue }
            let key = item.field.key.lowercased()
            var via: StudioAliasIndex.Via?
            if !query.isEmpty {
                guard let found = matched[key] else { continue }
                if case .label = found {} else { via = found }
            }
            let written = values(p.key) ?? p.legacyKeys.lazy.compactMap(values).first
            let value = (written?.isEmpty == false ? written : nil)
                ?? EditorSchema.defaultValue(of: p, in: schema, values: values)
            let section = measure ? Section.content : Section(item.field.section)
            bySection[section, default: []].append(Row(item: item, written: written, value: value, via: via))
        }
        return Section.allCases.compactMap { s in bySection[s].map { Group(section: s, rows: $0) } }
    }

    /// How many settings the page has (the footer's "Every Setting · 24 more" counts those not on the part page).
    public static func count(_ groups: [Group]) -> Int { groups.reduce(0) { $0 + $1.rows.count } }

    // MARK: The box

    /// The part's box from outside in, as the diagram draws it: margin, shadow, background, border, padding — mapped to
    /// what an INI part has (it has no margin; a text's shadow is its `StringEffect=Shadow`; the background is
    /// `SolidColor` (fading to `SolidColor2`); the border is `BevelType`; the padding is `Padding`).
    public struct Box: Equatable {
        public var margin: SkinInsets?
        public var shadow: RGBA?
        public var background: RGBA?
        public var backgroundFade: RGBA?
        /// 0 none, 1 raised, 2 sunken.
        public var border: Int
        public var padding: SkinInsets
    }

    public static func box(_ m: Meter) -> Box {
        var shadow: RGBA?
        if let s = m as? StringMeter, s.style.effect == .shadow { shadow = s.style.effectColor }
        let background = m.solidColor.a > 0 ? m.solidColor : nil
        return Box(margin: nil, shadow: shadow, background: background,
                   backgroundFade: background == nil ? nil : m.solidColor2, border: m.bevelType, padding: m.padding)
    }
}
