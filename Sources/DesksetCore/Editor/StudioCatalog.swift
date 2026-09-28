import Foundation

/// The Studio's catalog of settings: what each option of a part (and a few settings of the whole widget) is called
/// in everyday words, in English and Chinese, where it belongs on a page, which control changes it, its presets and
/// examples, whether it is shown at first or only in Every Setting, its unit and range, a long sample, the Rainmeter
/// name it maps to, and the other words people use for it. Pages are generated from it together with
/// `EditorSchema` (the option's kind, default and conditions), and the same entries feed the alias index that the
/// Every Setting filter and the search use (`StudioAliasIndex`).
///
/// Entries are keyed by the INI option name, case-insensitively; the widget page's own settings (Text, Card, Look,
/// Size…) have keys that start with `@`, which no INI option does.
public enum StudioCatalog {
    /// Where a setting is on a part's page, in the order of the box: what it shows, its text, its look, where it is,
    /// what a click does, its box, the pointer, and what VoiceOver says.
    public enum Section: String, CaseIterable, Equatable {
        case shows, text, look, layout, clicks, box, pointer, spoken

        public var title: (en: String, zh: String) {
            switch self {
            case .shows: return ("Shows", "显示内容")
            case .text: return ("Text", "文字")
            case .look: return ("Look", "外观")
            case .layout: return ("Layout", "排版")
            case .clicks: return ("Clicks", "点按时")
            case .box: return ("Box", "盒子")
            case .pointer: return ("Pointer", "指针")
            case .spoken: return ("Spoken", "朗读")
            }
        }
    }

    /// The control a setting takes on a page.
    public enum Control: String, Equatable {
        /// Words typed in a field, or a mix of words and data (a token field).
        case text, token
        /// A pop-up menu, a segmented control (at most four choices), a switch, a number field.
        case popup, segmented, toggle, number
        /// A color swatch (opens the color popover).
        case color
        /// The font menu (each item in its own face).
        case font
        /// Examples rendered with the real value ("21% · 21.4% · 0.21").
        case examples
        /// The nine-way alignment.
        case alignment
        /// Four numbers around a box.
        case insets
        /// A picture well.
        case image
        /// A sentence that says what a click does, with its menu.
        case action
        /// The shape editor (compatibility mode).
        case shapes
        /// Look thumbnails, Show As thumbnails.
        case thumbnails
    }

    /// Shown on a page at first, or only in Every Setting.
    public enum Level: Equatable {
        case essential, more
    }

    /// A value a setting often takes, named in both languages.
    public struct Preset: Equatable {
        public var value: String
        public var en: String
        public var zh: String

        public init(_ value: String, _ en: String, _ zh: String) {
            self.value = value
            self.en = en
            self.zh = zh
        }
    }

    /// One setting.
    public struct Field: Equatable {
        /// The INI option (`FontColor`), or `@Name` for a setting of the widget page.
        public var key: String
        public var section: Section
        public var en: String
        public var zh: String
        public var control: Control
        public var presets: [Preset]
        /// Values written as they would show ("21%", "21.4%").
        public var examples: [String]
        public var level: Level
        /// The unit a number is in (`pt`, `%`, `°`), in English and Chinese.
        public var unit: (en: String, zh: String)?
        public var range: ClosedRange<Double>?
        /// A long value, to see how the part takes it.
        public var sample: String
        /// The Rainmeter options it maps to (the first is the one written).
        public var rainmeter: [String]
        /// Other words for it, in either language (search and the Every Setting filter match them).
        public var aliases: [String]

        public init(_ key: String, _ section: Section, _ en: String, _ zh: String, _ control: Control,
                    presets: [Preset] = [], examples: [String] = [], level: Level = .more,
                    unit: (en: String, zh: String)? = nil, range: ClosedRange<Double>? = nil, sample: String = "",
                    rainmeter: [String]? = nil, aliases: [String] = []) {
            self.key = key
            self.section = section
            self.en = en
            self.zh = zh
            self.control = control
            self.presets = presets
            self.examples = examples
            self.level = level
            self.unit = unit
            self.range = range
            self.sample = sample
            self.rainmeter = rainmeter ?? (key.hasPrefix("@") ? [] : [key])
            self.aliases = aliases
        }

        public func label(chinese: Bool) -> String { chinese ? zh : en }

        public static func == (a: Field, b: Field) -> Bool {
            a.key == b.key && a.section == b.section && a.en == b.en && a.zh == b.zh && a.control == b.control
                && a.presets == b.presets && a.examples == b.examples && a.level == b.level && a.unit?.en == b.unit?.en
                && a.unit?.zh == b.unit?.zh && a.range == b.range && a.sample == b.sample && a.rainmeter == b.rainmeter
                && a.aliases == b.aliases
        }
    }

    /// A property of `EditorSchema` with its catalog entry.
    public struct Item: Equatable {
        public var property: EditorSchema.Property
        public var field: Field
    }

    // MARK: Lookup

    /// The entry of an INI option (case-insensitive; `FontColor2` finds `FontColor` with the number kept off), or of
    /// a widget page setting (`@Text`).
    public static func field(_ key: String) -> Field? {
        let lower = key.lowercased()
        if let f = byKey[lower] { return f }
        // Numbered options (`MeasureName2`, `LeftMouseUpAction` has none): the base name's entry.
        let base = String(lower.reversed().drop(while: \.isNumber).reversed())
        if base != lower, !base.isEmpty, let f = byKey[base] { return f }
        return nil
    }

    /// Every property of a meter type, each with its entry (an entry made from the property itself when the catalog
    /// has none: its label in English, `EditorSchema`'s level, the Look section), in the order of the box.
    public static func items(forMeterType type: String) -> [Item] {
        ordered(EditorSchema.meterGroups(type).flatMap(\.properties))
    }

    /// Every property of a measure type, each with its entry, as `items(forMeterType:)`.
    public static func items(forMeasureType type: String, plugin: String? = nil) -> [Item] {
        ordered(EditorSchema.measureGroups(type, plugin: plugin).flatMap(\.properties))
    }

    private static func ordered(_ properties: [EditorSchema.Property]) -> [Item] {
        var seen: Set<String> = []
        var items: [Item] = []
        for p in properties where seen.insert(p.key.lowercased()).inserted {
            items.append(Item(property: p, field: field(p.key) ?? fallback(p)))
        }
        let order = Dictionary(uniqueKeysWithValues: Section.allCases.enumerated().map { ($1, $0) })
        return items.enumerated().sorted { a, b in
            let sa = order[a.element.field.section] ?? 0, sb = order[b.element.field.section] ?? 0
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)
    }

    /// An entry for a property the catalog does not list.
    static func fallback(_ p: EditorSchema.Property) -> Field {
        let control: Control
        switch p.kind {
        case .text, .formula, .styleList, .sectionRef: control = .text
        case .number, .percent255, .angle: control = .number
        case .bool: control = .toggle
        case .choice(let choices, _): control = choices.count <= 4 ? .segmented : .popup
        case .alignment9: control = .alignment
        case .color: control = .color
        case .font: control = .font
        case .insets: control = .insets
        case .image: control = .image
        case .format: control = .examples
        case .action: control = .action
        case .shapes: control = .shapes
        }
        let section: Section
        let k = p.key.lowercased()
        if k.contains("mouse") || k.hasSuffix("action") { section = .clicks }
        else if k.hasPrefix("tooltip") { section = .pointer }
        else if k.hasPrefix("font") || k.hasPrefix("string") { section = .text }
        else { section = .look }
        return Field(p.key, section, p.label, p.label, control, level: p.level == .essential ? .essential : .more,
                     rainmeter: [p.key])
    }

    /// Every entry, in the order below (INI options, then the widget page's settings).
    public static let all: [Field] = parts + widget

    static let byKey: [String: Field] = {
        var map: [String: Field] = [:]
        for f in all where map[f.key.lowercased()] == nil { map[f.key.lowercased()] = f }
        return map
    }()

    // MARK: Entries

    static let pt = (en: "pt", zh: "点")
    static let percent = (en: "%", zh: "%")
    static let degrees = (en: "°", zh: "°")

    /// The options of parts.
    static let parts: [Field] = [
        // What the part shows.
        Field("MeasureName", .shows, "Shows", "显示", .popup, level: .essential,
              aliases: ["data", "measure", "source", "value", "数据", "数据源", "显示什么"]),
        Field("Text", .shows, "Text", "文字", .token, examples: ["%1", "CPU %1"], level: .essential,
              sample: "A much longer text than this part was made for",
              aliases: ["words", "label", "caption", "string", "内容", "字", "标签"]),
        Field("Prefix", .shows, "Before", "前缀", .text, aliases: ["prefix", "前面"]),
        Field("Postfix", .shows, "After", "后缀", .text, aliases: ["suffix", "unit", "后面", "单位"]),
        Field("NumOfDecimals", .shows, "Decimals", "小数位数", .number, examples: ["21", "21.4", "21.43"],
              range: 0...6, aliases: ["decimal places", "precision", "rounding", "小数"]),
        Field("Percentual", .shows, "As a Percentage", "显示成百分比", .toggle, examples: ["21%"],
              aliases: ["percent", "percentage", "百分比"]),
        Field("AutoScale", .shows, "Units", "单位换算", .popup,
              presets: [Preset("0", "None", "不换算"), Preset("1", "KB, MB, GB (1024)", "KB、MB、GB（1024）"),
                        Preset("2", "kB, MB, GB (1000)", "kB、MB、GB（1000）")],
              examples: ["20.4 GB", "21,904,333,209"], aliases: ["scale", "bytes", "kilobytes", "换算", "自动缩放"]),
        Field("Scale", .shows, "Divide By", "除以", .number, aliases: ["divide", "scale factor", "缩放"]),
        Field("ImageName", .shows, "Picture", "图片", .image, level: .essential,
              aliases: ["image", "icon", "symbol", "picture", "sf symbol", "图像", "图标", "符号"]),
        Field("Format", .shows, "Format", "格式", .examples, examples: ["10:09", "10:09:30", "Sunday"],
              aliases: ["time format", "date format", "日期格式", "时间格式"]),

        // Its text.
        Field("FontFace", .text, "Font", "字体", .font, level: .essential,
              aliases: ["typeface", "family", "font family", "字形"]),
        Field("FontSize", .text, "Size", "字号", .number, level: .essential, unit: pt, range: 1...400,
              aliases: ["text size", "font size", "bigger text", "larger", "smaller", "字大小", "放大", "大小"]),
        Field("FontWeight", .text, "Weight", "字重", .popup,
              presets: [Preset("400", "Regular", "常规"), Preset("500", "Medium", "中等"),
                        Preset("600", "Semibold", "中粗"), Preset("700", "Bold", "粗体")], level: .essential,
              aliases: ["bold", "heavy", "thin", "粗细", "加粗"]),
        Field("StringStyle", .text, "Style", "样式", .segmented,
              presets: [Preset("Normal", "Regular", "常规"), Preset("Bold", "Bold", "粗体"),
                        Preset("Italic", "Italic", "斜体"), Preset("BoldItalic", "Bold Italic", "粗斜体")],
              aliases: ["italic", "bold", "斜体"]),
        Field("FontColor", .text, "Color", "颜色", .color, level: .essential,
              aliases: ["text color", "font color", "colour", "ink", "字色", "文字颜色", "字体颜色"]),
        Field("StringAlign", .text, "Alignment", "对齐", .popup,
              presets: [Preset("Left", "Left", "左"), Preset("Center", "Center", "居中"), Preset("Right", "Right", "右")],
              level: .essential,
              aliases: ["align", "justify", "centre", "center", "左对齐", "居中", "右对齐"]),
        Field("StringCase", .text, "Capitals", "大小写", .popup,
              presets: [Preset("None", "As Written", "照原样"), Preset("Upper", "ALL CAPITALS", "全部大写"),
                        Preset("Lower", "lower case", "全部小写"), Preset("Proper", "Title Case", "首字母大写")],
              aliases: ["uppercase", "lowercase", "caps", "大写", "小写"]),
        Field("StringEffect", .text, "Effect", "效果", .segmented,
              presets: [Preset("None", "None", "无"), Preset("Shadow", "Shadow", "阴影"), Preset("Border", "Outline", "描边")],
              aliases: ["shadow", "outline", "stroke", "阴影", "描边"]),
        Field("FontEffectColor", .text, "Effect Color", "效果颜色", .color,
              aliases: ["shadow color", "outline color", "阴影颜色"]),
        Field("ClipString", .text, "If It’s Too Long", "太长时", .popup,
              presets: [Preset("0", "Keep Going", "继续显示"), Preset("1", "End with …", "用…结尾"),
                        Preset("2", "Wrap", "换行")],
              sample: "A much longer text than this part was made for",
              aliases: ["wrap", "truncate", "ellipsis", "clip", "换行", "截断", "省略"]),
        Field("InlineSetting", .text, "Styled Words", "局部样式", .text,
              aliases: ["inline", "highlight", "局部", "突出"]),
        Field("InlinePattern", .text, "Which Words", "哪些字", .text, aliases: ["pattern", "匹配"]),
        Field("AntiAlias", .text, "Smooth Edges", "平滑边缘", .toggle, aliases: ["antialias", "smooth", "平滑"]),

        // Its look.
        Field("BarColor", .look, "Fill", "填充色", .color, level: .essential,
              aliases: ["bar color", "fill color", "progress color", "进度条颜色", "填充"]),
        Field("BarOrientation", .look, "Fills Toward", "填充方向", .segmented,
              presets: [Preset("Horizontal", "Across", "横向"), Preset("Vertical", "Up", "向上")],
              aliases: ["direction", "orientation", "方向"]),
        Field("BarImage", .look, "Fill Picture", "填充图片", .image, aliases: ["bar image", "进度条图片"]),
        Field("LineColor", .look, "Line", "线条颜色", .color, level: .essential,
              aliases: ["graph color", "line colour", "curve color", "曲线颜色", "线的颜色"]),
        Field("LineWidth", .look, "Thickness", "粗细", .number, level: .essential, unit: pt, range: 0...50,
              aliases: ["line width", "stroke width", "thickness", "线宽", "粗细"]),
        Field("LineLength", .look, "Length", "长度", .number, unit: pt, aliases: ["radius", "长度", "半径"]),
        Field("LineStart", .look, "Starts From Center At", "从中心起", .number, unit: pt,
              aliases: ["inner radius", "内半径"]),
        Field("StartAngle", .look, "Starts At", "起始角度", .number, unit: degrees, range: -360...360,
              aliases: ["start angle", "起点"]),
        Field("RotationAngle", .look, "Sweep", "旋转角度", .number, unit: degrees, range: -360...360,
              aliases: ["rotation", "sweep", "扫过"]),
        Field("Solid", .look, "Filled", "实心", .toggle, aliases: ["solid", "filled", "实心"]),
        Field("ImageTint", .look, "Tint", "着色", .color, level: .essential,
              aliases: ["icon color", "symbol color", "image color", "图标颜色", "着色"]),
        Field("ImageAlpha", .look, "Opacity", "不透明度", .number, unit: percent, range: 0...255,
              aliases: ["transparency", "alpha", "透明度"]),
        Field("MacSymbolWeight", .look, "Symbol Weight", "符号粗细", .popup, aliases: ["symbol weight", "符号字重"]),
        Field("MacSymbolRendering", .look, "Symbol Colors", "符号的颜色", .segmented,
              presets: [Preset("Monochrome", "One Color", "一种颜色"), Preset("Hierarchical", "Shades", "深浅"),
                        Preset("Multicolor", "Its Own Colors", "自己的颜色")],
              aliases: ["rendering mode", "multicolor", "渲染"]),
        Field("Shape", .look, "Shape", "形状", .shapes, level: .essential,
              aliases: ["rectangle", "circle", "ellipse", "arc", "path", "矩形", "圆", "弧"]),
        Field("HorizontalLines", .look, "Grid Lines", "网格线", .toggle, aliases: ["grid", "网格"]),
        Field("GraphStart", .look, "New Values Appear On The", "新数值出现在", .segmented,
              presets: [Preset("Right", "Right", "右边"), Preset("Left", "Left", "左边")],
              aliases: ["graph direction", "方向"]),
        Field("MacGlass", .look, "Glass", "玻璃", .segmented,
              presets: [Preset("", "None", "无"), Preset("Regular", "Regular", "常规"), Preset("Clear", "Clear", "更透")],
              aliases: ["glass", "blur", "frosted", "background blur", "毛玻璃", "玻璃"]),
        Field("MacGlassTint", .look, "Glass Tint", "玻璃着色", .color, aliases: ["tint", "玻璃颜色"]),

        // Where it is.
        Field("X", .layout, "X", "X", .number, level: .essential, unit: pt, aliases: ["left", "horizontal position", "横坐标"]),
        Field("Y", .layout, "Y", "Y", .number, level: .essential, unit: pt, aliases: ["top", "vertical position", "纵坐标"]),
        Field("W", .layout, "Width", "宽", .number, level: .essential, unit: pt, range: 0...10000,
              aliases: ["width", "宽度"]),
        Field("H", .layout, "Height", "高", .number, level: .essential, unit: pt, range: 0...10000,
              aliases: ["height", "高度"]),
        Field("Hidden", .layout, "Hidden", "隐藏", .toggle, aliases: ["hide", "visible", "show", "隐藏", "显示"]),
        Field("Container", .layout, "Show Only Inside", "只在里面显示", .popup, aliases: ["container", "mask", "容器", "蒙版"]),

        // What a click does.
        Field("LeftMouseUpAction", .clicks, "Click", "点按", .action, level: .essential,
              aliases: ["click", "on click", "open", "link", "点击", "单击", "打开"]),
        Field("LeftMouseDoubleClickAction", .clicks, "Double-Click", "连按", .action,
              aliases: ["double click", "双击", "连按"]),
        Field("RightMouseUpAction", .clicks, "Secondary Click", "辅助点按", .action,
              aliases: ["right click", "右键", "右击"]),
        Field("MiddleMouseUpAction", .clicks, "Middle Click", "中键点按", .action, aliases: ["middle click", "中键"]),
        Field("MouseScrollUpAction", .clicks, "Scroll Up", "向上滚动", .action, aliases: ["scroll", "wheel", "滚轮"]),
        Field("MouseScrollDownAction", .clicks, "Scroll Down", "向下滚动", .action, aliases: ["scroll", "wheel", "滚轮"]),

        // Its box.
        Field("SolidColor", .box, "Background", "背景色", .color,
              aliases: ["background color", "fill", "box color", "背景", "底色"]),
        Field("SolidColor2", .box, "Background Fades To", "背景渐变到", .color, aliases: ["gradient", "渐变"]),
        Field("GradientAngle", .box, "Fade Direction", "渐变方向", .number, unit: degrees, range: 0...360,
              aliases: ["gradient angle", "渐变角度"]),
        Field("Padding", .box, "Padding", "内边距", .insets, aliases: ["margin", "inset", "spacing", "边距", "留白"]),
        Field("BevelType", .box, "Raised Edge", "凸起的边", .segmented,
              presets: [Preset("0", "None", "无"), Preset("1", "Raised", "凸起"), Preset("2", "Sunken", "凹陷")],
              aliases: ["bevel", "边框", "斜角"]),

        // The pointer.
        Field("MouseOverAction", .pointer, "When Pointed At", "指针移入时", .action,
              aliases: ["hover", "mouse over", "悬停", "指向"]),
        Field("MouseLeaveAction", .pointer, "When the Pointer Leaves", "指针移出时", .action,
              aliases: ["mouse leave", "hover end", "移开"]),
        Field("MouseActionCursor", .pointer, "Pointing Hand", "手形指针", .toggle, aliases: ["cursor", "pointer", "光标"]),
        Field("ToolTipText", .pointer, "Tip", "提示", .text, sample: "A much longer tip than this part was made for",
              aliases: ["tooltip", "hint", "help tag", "悬停提示", "提示文字"]),
        Field("ToolTipTitle", .pointer, "Tip Title", "提示标题", .text, aliases: ["tooltip title", "提示标题"]),
    ]

    /// The widget page's own settings (keys start with `@`).
    static let widget: [Field] = [
        Field("@Text", .text, "Text", "文字", .color, level: .essential, rainmeter: ["FontColor"],
              aliases: ["text color", "font color", "ink", "words color", "字色", "文字颜色", "字体颜色"]),
        Field("@Card", .box, "Card", "卡片", .color, level: .essential, rainmeter: ["SolidColor", "BackgroundColor"],
              aliases: ["background", "panel", "card color", "backdrop", "背景", "面板", "卡片颜色", "底色"]),
        Field("@Colors", .look, "More Colors", "更多颜色", .color, rainmeter: ["BarColor", "LineColor", "ImageTint"],
              aliases: ["palette", "all colors", "every color", "配色", "所有颜色"]),
        Field("@FontNumbers", .text, "Numbers", "数字", .font, level: .essential, rainmeter: ["FontFace"],
              aliases: ["number font", "digits font", "数字字体"]),
        Field("@FontLabels", .text, "Labels", "文字", .font, level: .essential, rainmeter: ["FontFace"],
              aliases: ["label font", "words font", "text font", "文字字体"]),
        Field("@TextSize", .text, "Make All Text Bigger", "放大全部文字", .number, rainmeter: ["FontSize"],
              aliases: ["bigger", "larger", "smaller", "zoom text", "text size", "大一点", "放大", "缩小", "字大"]),
        Field("@Look", .look, "Look", "外观", .thumbnails,
              presets: [Preset("Auto", "Auto", "自动"), Preset("Light", "Light", "浅色"), Preset("Dark", "Dark", "深色"),
                        Preset("Clear", "Clear", "透明")], level: .essential,
              aliases: ["theme", "appearance", "dark", "light", "style", "主题", "深色", "浅色"]),
        Field("@Size", .layout, "Size", "大小", .segmented,
              presets: [Preset("Small", "Small", "小"), Preset("Medium", "Medium", "中"), Preset("Large", "Large", "大")],
              level: .essential,
              aliases: ["scale", "bigger widget", "zoom", "variant", "尺寸", "变体", "大号"]),
        Field("@Update", .layout, "Refresh", "刷新", .popup,
              presets: [Preset("1000", "Every Second", "每 1 秒"), Preset("100", "10 Times a Second", "每秒 10 次"),
                        Preset("60000", "Every Minute", "每分钟")], rainmeter: ["Update"],
              aliases: ["update", "refresh rate", "interval", "speed", "刷新", "更新频率"]),
    ]
}

/// The words each catalog entry answers to — its labels in both languages, its Rainmeter names and its aliases —
/// indexed for the Every Setting filter and the search. A match says which word matched, so a row can say
/// "Color · Rainmeter: FontColor" when the Rainmeter name found it.
public struct StudioAliasIndex {
    /// Which of an entry's words matched.
    public enum Via: Equatable {
        case label
        case rainmeter(String)
        case alias(String)
    }

    public struct Match: Equatable {
        public var field: StudioCatalog.Field
        public var via: Via
        /// Lower is better: an exact word, then the start of one, then a word inside.
        public var rank: Int
    }

    struct Word {
        var text: String
        var via: Via
    }

    let entries: [(field: StudioCatalog.Field, words: [Word])]

    public init(fields: [StudioCatalog.Field] = StudioCatalog.all) {
        entries = fields.map { f in
            var words = [Word(text: Self.normalized(f.en), via: .label), Word(text: Self.normalized(f.zh), via: .label)]
            words += f.rainmeter.map { Word(text: Self.normalized($0), via: .rainmeter($0)) }
            words += f.aliases.map { Word(text: Self.normalized($0), via: .alias($0)) }
            return (f, words)
        }
    }

    public static let shared = StudioAliasIndex()

    /// Lower case, without accents, full-width forms, spaces or punctuation: "Font Color", "fontcolor" and
    /// "FONT-COLOR" are one word.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The entries `query` finds, best first (each entry once, by its best word); empty for an empty query.
    public func matches(_ query: String) -> [Match] {
        let q = Self.normalized(query)
        guard !q.isEmpty else { return [] }
        var result: [Match] = []
        for (i, entry) in entries.enumerated() {
            var best: (rank: Int, via: Via)?
            for w in entry.words where !w.text.isEmpty {
                let rank: Int
                if w.text == q { rank = 0 } else if w.text.hasPrefix(q) { rank = 1 } else if w.text.contains(q) { rank = 2 }
                else { continue }
                // A label beats a Rainmeter name beats an alias at the same rank.
                let order: Int
                switch w.via { case .label: order = 0; case .rainmeter: order = 1; case .alias: order = 2 }
                let score = rank * 3 + order
                if best == nil || score < best!.rank { best = (score, w.via) }
            }
            if let best { result.append(Match(field: entry.field, via: best.via, rank: best.rank * 1000 + i)) }
        }
        return result.sorted { $0.rank < $1.rank }
    }

    /// Whether `query` finds the entry of `key`, and by which word.
    public func match(_ query: String, key: String) -> Match? {
        matches(query).first { $0.field.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}
