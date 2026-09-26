import Foundation

/// What the editor's inspector shows for each kind of section, in the user's words: groups of properties with
/// friendly labels and a typed value kind that decides the control (docs/editor-design.md §3). Every option not
/// listed here stays reachable under "Other options".
///
/// The lists are verified against the engine code that reads each option (`Engine/Meter.swift`, `Meters/*`,
/// `Measure.swift`, `Measures/*`, `Plugins/*`, the app's plugin registrations): only options the engine reads are
/// listed, with its defaults, its accepted values and their spellings (aliases). Option names and meanings follow
/// the public manual (docs.rainmeter.net/manual/…). Keeping this declarative keeps the inspector consistent across
/// types and makes a new type a matter of a few lines.
public enum EditorSchema {
    // MARK: - Value kinds

    public enum ChoiceStyle: Equatable {
        /// A segmented control (up to about four short choices).
        case segmented
        /// A pop-up menu.
        case popup
    }

    public enum AngleUnit: Equatable {
        case degrees
        /// Stored in radians; the editor shows degrees and writes `(Rad(n))`.
        case radians
    }

    public enum SectionKind: Equatable {
        case measure, meter, style
    }

    /// The live preview line of a format field.
    public enum FormatPreview: Equatable {
        /// strftime-style date / time codes (`%H:%M`).
        case time
        /// Uptime codes (`%4!i!d %3!i!:%2!02i!`).
        case uptime
        case number
        case none
    }

    /// How a value is edited (docs/editor-design.md §3, "Control per value kind").
    public enum Kind: Equatable {
        /// Free text.
        case text
        /// A number (or formula); limits and step for the field / stepper, unit shown after it.
        case number(min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: String? = nil)
        /// 0 / non-zero; `title` is the checkbox text, worded positively ("Smooth edges").
        case bool(title: String)
        /// One of fixed values.
        case choice([Choice], style: ChoiceStyle = .popup)
        /// `StringAlign`: horizontal Left / Center / Right × vertical Top / Center / Bottom.
        case alignment9
        /// 0…255 shown as 0…100 %.
        case percent255
        /// An angle; `orientation` = a direction (a circular slider makes sense).
        case angle(unit: AngleUnit, orientation: Bool)
        case color
        case font
        /// `Left,Top,Right,Bottom`.
        case insets
        /// An image file (relative to the skin folder or `#@#`).
        case image
        /// The name of another section.
        case sectionRef(SectionKind)
        /// `MeterStyle`: `|`-separated style sections.
        case styleList
        /// A format string with presets and a live preview.
        case format(presets: [String], preview: FormatPreview)
        /// A formula (Calc `Formula`, conditions).
        case formula
        /// Bangs.
        case action
        /// The Shape meter's `Shape`, `Shape2`… (the Shape editor, `ShapeSpec`).
        case shapes

        /// The fixed values of a choice (the nine alignments for `alignment9`).
        public var choices: [Choice]? {
            if case .choice(let c, _) = self { return c }
            if case .alignment9 = self { return EditorSchema.alignments }
            return nil
        }

        public var isBool: Bool {
            if case .bool = self { return true }
            return false
        }

        public var isNumeric: Bool {
            switch self {
            case .number, .percent255, .angle: return true
            default: return false
            }
        }
    }

    public struct Choice: Equatable {
        /// What is written to the file.
        public var value: String
        /// Plain title for menus.
        public var title: String
        /// Other spellings the engine reads as this choice (`LeftTop` for `Left`); matching is case-insensitive.
        public var aliases: [String]
        /// False when the engine reads the value but it has no effect on macOS (`note` says why).
        public var supportedOnMac: Bool
        public var note: String
        /// SF Symbol for a segmented control / menu item.
        public var symbol: String?

        public init(_ value: String, _ title: String, aliases: [String] = [], symbol: String? = nil,
                    supportedOnMac: Bool = true, note: String = "") {
            self.value = value
            self.title = title
            self.aliases = aliases
            self.supportedOnMac = supportedOnMac
            self.note = note
            self.symbol = symbol
        }
    }

    /// When a property is relevant, from another option of the same section (docs/editor-design.md §3,
    /// "Conditional visibility"). Missing options count as their default; `#Var#` / `[Section]` values always pass.
    public struct Condition: Equatable {
        public enum Test: Equatable {
            /// The other option is (by default) one of these values (alias- and case-insensitive; bools by truth).
            case equals([String])
            case notEquals([String])
            /// The other option has a non-empty value.
            case isSet
            case isNotSet
            /// The other option's text contains this (case-insensitive), e.g. a Calc formula using `Random`.
            case contains(String)
        }

        public var key: String
        public var test: Test

        public init(_ key: String, _ test: Test) {
            self.key = key
            self.test = test
        }

        public static func equals(_ key: String, _ values: String...) -> Condition { Condition(key, .equals(values)) }
        public static func notEquals(_ key: String, _ values: String...) -> Condition { Condition(key, .notEquals(values)) }
        public static func isSet(_ key: String) -> Condition { Condition(key, .isSet) }
        public static func isNotSet(_ key: String) -> Condition { Condition(key, .isNotSet) }
        public static func contains(_ key: String, _ text: String) -> Condition { Condition(key, .contains(text)) }
    }

    /// A default that depends on the other options: the engine uses `value` when the option is missing and all of
    /// `when` hold (`BackgroundMode` is 0, an image, when the skin sets `Background`).
    public struct ConditionalDefault: Equatable {
        public var when: [Condition]
        public var value: String

        public init(_ value: String, when: [Condition]) {
            self.value = value
            self.when = when
        }
    }

    /// Values outside a choice list the engine still accepts.
    public enum OtherValues: Equatable {
        /// Only the listed values (others fall back to the default).
        case none
        /// Any number (FontWeight 1…999, a code page).
        case numbers
        /// Anything (an interface name, a cursor file).
        case any
    }

    public struct Property: Equatable {
        /// The INI option name.
        public var key: String
        /// Plain-English label.
        public var label: String
        public var kind: Kind
        /// What the engine uses when the option is missing, in INI form ("" = nothing / depends on the data).
        /// See `defaultWhen` for defaults that depend on other options, and `defaultValue(of:in:values:)`.
        public var defaultValue: String
        /// Defaults that depend on the other options, tried in order before `defaultValue`.
        public var defaultWhen: [ConditionalDefault]
        /// Shown greyed out in an empty field (the default, or words like "auto").
        public var placeholder: String
        public var help: String
        /// All must hold for the property to be relevant.
        public var visibleWhen: [Condition]
        /// Older spellings the engine also reads (used when the documented key is missing).
        public var legacyKeys: [String]
        /// For choices: which values outside the list are valid.
        public var otherValues: OtherValues
        /// Replaces the generic consequence ("Left · Top is used") in `issue(for:property:)`.
        public var invalidNote: String?
        /// The option repeats as `Key2`, `Key3`… (read in sequence while they exist, like `IfCondition2`); see
        /// `numberedProperty(_:in:)`.
        public var numbered: Bool
        /// Where the inspector shows it (docs/editor-friendly.md §7.2): among a card's essentials, behind its
        /// "More … Options" disclosure, or never counted as "in use" there (AntiAlias, DynamicVariables…).
        public var level: Level
        /// The key of the essential row this property is shown in (FontWeight and StringStyle in the Font row, Flip in
        /// "Fills toward"); nil: a row of its own. Such a property counts as part of that row, not as a row.
        public var partOf: String?

        public init(_ key: String, _ label: String, _ kind: Kind, default defaultValue: String = "",
                    defaultWhen: [ConditionalDefault] = [], placeholder: String? = nil, help: String = "",
                    visibleWhen: [Condition] = [], legacyKeys: [String] = [], otherValues: OtherValues = .none,
                    invalidNote: String? = nil, numbered: Bool = false, level: Level = .more, partOf: String? = nil) {
            self.key = key
            self.label = label
            self.kind = kind
            self.defaultValue = defaultValue
            self.defaultWhen = defaultWhen
            self.placeholder = placeholder ?? defaultValue
            self.help = help
            self.visibleWhen = visibleWhen
            self.legacyKeys = legacyKeys
            self.otherValues = otherValues
            self.invalidNote = invalidNote
            self.numbered = numbered
            self.level = level
            self.partOf = partOf
        }

        /// The same property shown among its card's essentials (`partOf`: inside another essential row).
        public func essential(partOf row: String? = nil) -> Property {
            var p = self
            p.level = .essential
            p.partOf = row ?? partOf
            return p
        }

        /// The same property at another level.
        public func with(level: Level) -> Property {
            var p = self
            p.level = level
            if level != .essential { p.partOf = nil }
            return p
        }

        /// The same property with another label.
        public func labelled(_ label: String, help: String? = nil) -> Property {
            var p = self
            p.label = label
            if let help { p.help = help }
            return p
        }

        /// The same property shown only when `conditions` hold (added to its own).
        public func shown(when conditions: [Condition]) -> Property {
            var p = self
            p.visibleWhen += conditions
            return p
        }
    }

    /// How prominently a property is shown (docs/editor-friendly.md §2 P3–P4).
    public enum Level: Equatable {
        /// Always visible in its card (at most five per card; seven for Text).
        case essential
        /// Behind the card's "More {Kind} Options" disclosure, which counts it when it is set.
        case more
        /// Behind the disclosure and never counted as "in use" (AntiAlias, DynamicVariables, AccurateText).
        case quiet
    }

    public struct Group: Equatable {
        public var title: String
        public var properties: [Property]
        /// The card's one-line note (docs/editor-friendly.md §7.2); empty: none.
        public var summary: String
        /// What the card's "More {Kind} Options" disclosure holds, in a few plain words ("capitals, up and down,
        /// long text"); empty: no list.
        public var moreSummary: String
        /// The disclosure's title ("More Text Options", "More Triggers"); empty: "More {title} Options".
        public var moreTitle: String

        public init(title: String, properties: [Property], summary: String = "", moreSummary: String = "",
                    moreTitle: String = "") {
            self.title = title
            self.properties = properties
            self.summary = summary
            self.moreSummary = moreSummary
            self.moreTitle = moreTitle
        }

        /// "More Text Options".
        public var moreLabel: String { moreTitle.isEmpty ? "More \(title) Options" : moreTitle }

        /// The same group with other properties (title, notes and disclosure kept).
        public func with(_ properties: [Property]) -> Group {
            var g = self
            g.properties = properties
            return g
        }

        /// The essential rows, in order: essential properties that are not shown inside another row.
        public var essentialRows: [Property] { properties.filter { $0.level == .essential && $0.partOf == nil } }

        /// What the "More" disclosure holds: every property that is not essential.
        public var moreProperties: [Property] { properties.filter { $0.level != .essential } }
    }

    // MARK: - Kind helpers

    /// A choice kind: segmented for up to four choices, a pop-up otherwise (docs/editor-design.md §3).
    static func pick(_ choices: [Choice], style: ChoiceStyle? = nil) -> Kind {
        .choice(choices, style: style ?? (choices.count <= 4 ? .segmented : .popup))
    }

    static func num(_ min: Double? = nil, _ max: Double? = nil, step: Double? = nil, unit: String? = nil) -> Kind {
        .number(min: min, max: max, step: step, unit: unit)
    }

    static func flag(_ title: String) -> Kind { .bool(title: title) }

    static func list(_ values: [String]) -> [Choice] { values.map { Choice($0, $0) } }

    // MARK: - Choice lists

    /// `FontWeight` in the words of the Weight menu (docs/editor-friendly.md §8.2); any other weight from 1 to 999 is
    /// accepted too (`otherValues: .numbers`) and shown as its number.
    public static let fontWeights: [Choice] = [
        Choice("100", "Thin"), Choice("300", "Light"), Choice("400", "Regular"), Choice("500", "Medium"),
        Choice("600", "Semibold"), Choice("700", "Bold"), Choice("800", "Heavy"),
    ]

    /// `StringAlign`: the top row is written in its short form (Left = LeftTop, the manual's default).
    public static let alignments: [Choice] = [
        Choice("Left", "Left · Top", aliases: ["LeftTop"]), Choice("Center", "Center · Top", aliases: ["CenterTop"]),
        Choice("Right", "Right · Top", aliases: ["RightTop"]),
        Choice("LeftCenter", "Left · Middle"), Choice("CenterCenter", "Center · Middle"),
        Choice("RightCenter", "Right · Middle"),
        Choice("LeftBottom", "Left · Bottom"), Choice("CenterBottom", "Center · Bottom"),
        Choice("RightBottom", "Right · Bottom"),
    ]

    static let stringStyle: [Choice] = [Choice("Normal", "Regular"), Choice("Bold", "Bold", symbol: "bold"),
                                        Choice("Italic", "Italic", symbol: "italic"), Choice("BoldItalic", "Bold Italic")]
    /// `StringCase`: each title is written in its own case (docs/editor-friendly.md §8.2).
    static let stringCase: [Choice] = [Choice("None", "As typed"), Choice("Upper", "UPPERCASE"),
                                       Choice("Lower", "lowercase"), Choice("Proper", "Title Case")]
    static let stringEffect: [Choice] = [Choice("None", "None"), Choice("Shadow", "Shadow"), Choice("Border", "Outline")]
    static let clipString: [Choice] = [Choice("0", "Keep going"), Choice("1", "Cut off with “…”"),
                                       Choice("2", "Grow up to a size…")]
    static let autoScale: [Choice] = [
        Choice("0", "Off"),
        Choice("1", "1024-based (k, M, G, T)"), Choice("1k", "1024-based, from k"), Choice("1m", "1024-based, from M"),
        Choice("1g", "1024-based, from G"), Choice("1t", "1024-based, from T"),
        Choice("2", "1000-based (k, M, G, T)"), Choice("2k", "1000-based, from k"), Choice("2m", "1000-based, from M"),
        Choice("2g", "1000-based, from G"), Choice("2t", "1000-based, from T"),
    ]
    static let orientation: [Choice] = [Choice("Vertical", "Vertical", symbol: "arrow.up"),
                                        Choice("Horizontal", "Horizontal", symbol: "arrow.right")]
    static let flip: [Choice] = [Choice("None", "None"), Choice("Horizontal", "Horizontal", symbol: "arrow.left.and.right"),
                                 Choice("Vertical", "Vertical", symbol: "arrow.up.and.down"), Choice("Both", "Both")]
    static let aspect: [Choice] = [Choice("0", "Stretch"), Choice("1", "Fit Inside"), Choice("2", "Fill")]
    static let bevel: [Choice] = [Choice("0", "None"), Choice("1", "Raised"), Choice("2", "Sunken")]
    static let graphStart: [Choice] = [Choice("Right", "Right"), Choice("Left", "Left")]
    static let transformStroke: [Choice] = [Choice("Normal", "Scales with the layer"), Choice("Fixed", "Stays the same")]
    static let bitmapAlign: [Choice] = [Choice("Left", "Left"), Choice("Center", "Center"), Choice("Right", "Right")]
    /// `UpdateDivider` of a layer ("Redraw"): every Nth update; other numbers are accepted and shown as written.
    static let redraw: [Choice] = [Choice("1", "Every update"), Choice("2", "Every 2nd update"),
                                   Choice("5", "Every 5th update"), Choice("-1", "Only once")]
    /// `MouseActionCursorName`: only six names have a Mac cursor (SkinView.cursor(named:)); the rest show the arrow.
    public static let cursorNames: [Choice] = {
        let mac: Set<String> = ["HAND", "TEXT", "CROSS", "NO", "SIZE_NS", "SIZE_WE"]
        let titles: [(String, String)] = [
            ("HAND", "Pointing hand"), ("TEXT", "Text (I-beam)"), ("CROSS", "Crosshair"), ("NO", "Not allowed"),
            ("SIZE_NS", "Resize up/down"), ("SIZE_WE", "Resize left/right"), ("HELP", "Help"), ("BUSY", "Busy"),
            ("PEN", "Pen"), ("SIZE_ALL", "Move"), ("SIZE_NESW", "Resize diagonal ↗"), ("SIZE_NWSE", "Resize diagonal ↘"),
            ("UPARROW", "Up arrow"), ("WAIT", "Wait"),
        ]
        return titles.map { Choice($0.0, $0.1, supportedOnMac: mac.contains($0.0),
                                   note: mac.contains($0.0) ? "" : "the Mac shows the arrow") }
    }()

    public static let timeFormats = ["%H:%M", "%H:%M:%S", "%#I:%M %p", "%A", "%a, %b %#d", "%B %#d, %Y", "%Y-%m-%d",
                                     "%#d/%#m/%Y", "locale-time", "locale-date"]
    public static let uptimeFormats = ["%4!i!d %3!i!:%2!02i!", "%4!i! days, %3!i! hours", "%3!i!:%2!02i!:%1!02i!",
                                       "%4!i!d %3!i!h %2!i!m"]

    // MARK: - Shared meter groups
    //
    // A group is a card of the inspector (docs/editor-friendly.md §7.2): its essential rows are always shown (at most
    // five, seven for Text), the rest behind its "More … Options" disclosure. Labels follow §3.2.

    static let measureName = Property("MeasureName", "Shows", .sectionRef(.measure),
                                      help: "The live data this layer shows", level: .essential)

    /// Picture options every image-drawing meter reads (Engine/Meters/ImageOptions.swift, RotatorMeter). `crop` /
    /// `rotate`: the manual excludes ImageCrop / ImageRotate for Bitmap and Button.
    static func imageOptions(crop: Bool = true, rotate: Bool = true, when: [Condition] = []) -> [Property] {
        var list: [Property] = [
            Property("ImageTint", "Tint", .color, default: "255,255,255,255", placeholder: "none",
                     help: "Multiplies the colors; white leaves them unchanged", visibleWhen: when),
            Property("ImageAlpha", "Opacity", .percent255, default: "255", visibleWhen: when),
            Property("Greyscale", "Grayscale", flag("Grayscale"), default: "0", visibleWhen: when),
            Property("ImageFlip", "Flip", pick(flip), default: "None", visibleWhen: when),
        ]
        if rotate {
            list.append(Property("ImageRotate", "Rotation", .angle(unit: .degrees, orientation: true), default: "0",
                                 help: "Degrees, clockwise", visibleWhen: when))
        }
        if crop {
            list.append(Property("ImageCrop", "Crop", .text, help: "X, Y, width, height[, corner 1–5]", visibleWhen: when))
        }
        list.append(Property("UseExifOrientation", "Camera orientation", flag("Use the camera's orientation"),
                             default: "0", visibleWhen: when))
        list.append(Property("ImagePath", "Picture folder", .text, help: "The folder picture names are relative to",
                             visibleWhen: when))
        return list
    }

    /// The fading and edge options of a layer's box (SolidColor2, GradientAngle, BevelType…), for "More" sections.
    static let boxExtras: [Property] = [
        Property("SolidColor2", "Fades to", .color, placeholder: "none", help: "The box fades from its color to this one"),
        Property("GradientAngle", "Fade direction", .angle(unit: .degrees, orientation: true), default: "0",
                 visibleWhen: [.isSet("SolidColor2")]),
        Property("BevelType", "Raised edge", pick(bevel), default: "0"),
        Property("BevelColor", "Edge light", .color, default: "255,255,255,255", visibleWhen: [.notEquals("BevelType", "0")]),
        Property("BevelColor2", "Edge shadow", .color, default: "0,0,0,255", visibleWhen: [.notEquals("BevelType", "0")]),
    ]

    static let padding = Property("Padding", "Space around it", .insets, default: "0,0,0,0",
                                  help: "Left, top, right and bottom, in px")

    /// "Box Behind It" (the layer's SolidColor, Padding, fade and raised edge). `color`: SolidColor is the box's
    /// color here (a picture keeps it in its own card).
    static func boxGroup(color: Bool = true) -> Group {
        var list: [Property] = []
        if color {
            list.append(Property("SolidColor", "Color", .color, default: "0,0,0,0", placeholder: "none",
                                 help: "A box of color behind the layer", level: .essential))
        }
        list.append(padding.essential())
        return Group(title: "Box Behind It", properties: list + boxExtras,
                     summary: "A box of color behind the layer, and the space around it.",
                     moreSummary: "fades, raised edge", moreTitle: "More Box Options")
    }

    static let interaction = Group(title: "When Clicked", properties: [
        Property("LeftMouseUpAction", "Click", .action, help: "What happens when it's clicked", level: .essential),
        Property("MouseOverAction", "Pointed at", .action, help: "What happens when the pointer moves onto it",
                 level: .essential),
        Property("ToolTipText", "Tooltip", .text, placeholder: "Shown when the pointer rests on it",
                 help: "%1, %2… stand for the live values it shows", level: .essential),
        Property("ToolTipTitle", "Tooltip title", .text, visibleWhen: [.isSet("ToolTipText")]),
        Property("ToolTipHidden", "Hide tooltip", flag("Hide the tooltip"), default: "0",
                 visibleWhen: [.isSet("ToolTipText")]),
        Property("MouseLeaveAction", "Pointer leaves", .action),
        Property("RightMouseUpAction", "Right-click", .action, help: "Replaces the widget's right-click menu"),
        Property("LeftMouseDoubleClickAction", "Double-click", .action),
        Property("MouseScrollUpAction", "Scroll up", .action),
        Property("MouseScrollDownAction", "Scroll down", .action),
        Property("MouseScrollLeftAction", "Scroll left", .action),
        Property("MouseScrollRightAction", "Scroll right", .action),
        Property("LeftMouseDownAction", "Press", .action),
        Property("RightMouseDownAction", "Right press", .action),
        Property("RightMouseDoubleClickAction", "Right double-click", .action),
        Property("MiddleMouseUpAction", "Middle-click", .action),
        Property("MiddleMouseDownAction", "Middle press", .action),
        Property("MiddleMouseDoubleClickAction", "Middle double-click", .action),
        Property("X1MouseUpAction", "Back button", .action),
        Property("X1MouseDownAction", "Back button press", .action),
        Property("X1MouseDoubleClickAction", "Back button double-click", .action),
        Property("X2MouseUpAction", "Forward button", .action),
        Property("X2MouseDownAction", "Forward button press", .action),
        Property("X2MouseDoubleClickAction", "Forward button double-click", .action),
        Property("MouseActionCursor", "Pointer", flag("Show a pointing hand over it"), default: "1"),
        Property("MouseActionCursorName", "Pointer shape", pick(cursorNames, style: .popup), default: "HAND",
                 visibleWhen: [.notEquals("MouseActionCursor", "0")], otherValues: .any),
    ], moreSummary: "right-click, double-click, scroll, pointer leaves", moreTitle: "More Triggers")

    /// The layer itself: Hide (the identity strip's button) and "More Layer Options".
    static let behavior = Group(title: "Layer", properties: [
        Property("Hidden", "Hide", flag("Hide this layer"), default: "0", level: .essential),
        Property("UpdateDivider", "Redraw", pick(redraw, style: .popup), default: "1",
                 help: "How often it is drawn again", otherValues: .numbers),
        Property("DynamicVariables", "Live values", flag("Keep options in sync with live data"), default: "0",
                 level: .quiet),
        Property("Container", "Show only inside", .sectionRef(.meter), help: "Another layer that clips this one"),
        Property("OnUpdateAction", "When it redraws", .action),
        Property("Group", "Group names", .text, placeholder: "e.g. Clocks",
                 help: "Names separated by |, used by actions that change several layers at once"),
        Property("MeterStyle", "Uses looks", .styleList,
                 help: "Shared looks; later ones win, and the layer's own settings win over all", level: .quiet),
        Property("TransformationMatrix", "Custom transform", .text, help: "a;b;c;d;tx;ty"),
    ], moreSummary: "redraw timing, group names, show only inside, custom transform", moreTitle: "More Layer Options")

    static let antiAlias = Property("AntiAlias", "Smooth edges", flag("Smooth edges"), default: "0", level: .quiet)

    // MARK: - Meters

    /// Every `Meter=` type the engine draws (Skin.makeMeter).
    public static let meterTypes = ["String", "Image", "Bar", "Line", "Histogram", "Roundline", "Rotator", "Button",
                                    "Bitmap", "Shape"]

    /// The cards of a meter type, after Position and Size (which the inspector draws itself): the type's own cards,
    /// then Box Behind It (most types), When Clicked and Layer. Empty for types the engine does not draw.
    public static func meterGroups(_ type: String) -> [Group] {
        var groups: [Group]
        switch type.trimmingCharacters(in: .whitespaces).lowercased() {
        case "string": groups = stringGroups + [boxGroup()]
        case "image": groups = imageGroups + [boxGroup(color: false)]
        case "bar": groups = barGroups
        case "line": groups = lineGroups
        case "histogram": groups = histogramGroups
        case "roundline": groups = roundlineGroups + [boxGroup()]
        case "rotator": groups = rotatorGroups + [boxGroup()]
        case "button": groups = buttonGroups + [boxGroup()]
        case "bitmap": groups = bitmapGroups + [boxGroup()]
        case "shape": groups = shapeGroups + [boxGroup()]
        default: return []
        }
        groups += [interaction, behavior]
        return groups
    }

    static let stringGroups: [Group] = [
        Group(title: "Shows", properties: [
            measureName,
            Property("NumOfDecimals", "Number", num(0, 1000, step: 1), default: "0", help: "How the number is written",
                     visibleWhen: [.isSet("MeasureName")], level: .essential),
            Property("AutoScale", "Scale units", pick(autoScale), default: "0", visibleWhen: [.isSet("MeasureName")],
                     level: .essential, partOf: "NumOfDecimals"),
            Property("Scale", "Divide by", num(), default: "1", help: "Not used with scale units",
                     visibleWhen: [.isSet("MeasureName"), .equals("AutoScale", "0")], level: .essential,
                     partOf: "NumOfDecimals"),
            Property("Percentual", "Percent", flag("Show as a percent of the range"), default: "0",
                     visibleWhen: [.isSet("MeasureName")], level: .essential, partOf: "NumOfDecimals"),
        ], summary: "The live data this text shows, and how its number is written."),
        Group(title: "Text", properties: [
            Property("Text", "Text", .text, placeholder: "Type the words to show",
                     help: "%1, %2… stand for the live values it shows", level: .essential),
            Property("FontFace", "Font", .font, default: "Arial", level: .essential),
            Property("FontWeight", "Weight", pick(fontWeights, style: .popup), default: "400",
                     placeholder: "Regular", help: "Any weight from 1 to 999; when missing, Italic and Bold decide",
                     otherValues: .numbers, level: .essential, partOf: "FontFace"),
            Property("StringStyle", "Italic", pick(stringStyle), default: "Normal", level: .essential, partOf: "FontFace"),
            Property("FontSize", "Size", num(0, 1000, step: 1, unit: "pt"), default: "10", level: .essential),
            Property("FontColor", "Color", .color, default: "0,0,0,255", level: .essential),
            Property("StringAlign", "Align", .alignment9, default: "Left", help: "X and Y are this point of the text",
                     level: .essential),
            Property("StringEffect", "Effect", pick(stringEffect), default: "None", level: .essential),
            Property("FontEffectColor", "Effect color", .color, default: "0,0,0,255",
                     visibleWhen: [.notEquals("StringEffect", "None")], level: .essential, partOf: "StringEffect"),
            Property("StringCase", "Capitals", pick(stringCase), default: "None"),
            Property("ClipString", "If it's too long", pick(clipString, style: .popup), default: "0"),
            Property("ClipStringW", "Grow up to width", num(0, nil, step: 1, unit: "px"), placeholder: "none",
                     visibleWhen: [.equals("ClipString", "2")]),
            Property("ClipStringH", "Grow up to height", num(0, nil, step: 1, unit: "px"), placeholder: "none",
                     visibleWhen: [.equals("ClipString", "2")]),
            Property("Prefix", "Text before", .text, help: "Written before the live value"),
            Property("Postfix", "Text after", .text, help: "Written after the live value"),
            Property("Angle", "Rotation", .angle(unit: .radians, orientation: true), default: "0",
                     help: "Around the alignment point"),
            antiAlias,
            Property("TrailingSpaces", "Spaces", flag("Keep spaces at the start and end"), default: "0"),
        ], moreSummary: "capitals, up and down, long text, text before and after, rotation", moreTitle: "More Text Options"),
    ]

    static let imageGroups: [Group] = {
        var picture: [Property] = [
            Property("ImageName", "Picture", .image,
                     help: "A picture in the widget's folder; %1 stands for the live value it shows", level: .essential),
            Property("SolidColor", "Color", .color, default: "0,0,0,0", placeholder: "none",
                     help: "Without a picture, a block of this color", level: .essential),
            Property("ImageAlpha", "Opacity", .percent255, default: "255", level: .essential),
            Property("PreserveAspectRatio", "Fit", pick(aspect), default: "0",
                     help: "Fit Inside is used when only one of width and height is set",
                     invalidNote: "values are limited to 0–2", level: .essential),
            Property("Tile", "Tile", flag("Repeat the picture"), default: "0"),
            Property("ScaleMargins", "Edges that don't stretch", .insets, help: "Left, top, right, bottom",
                     visibleWhen: [.equals("Tile", "0"), .equals("PreserveAspectRatio", "0")]),
        ]
        for var p in imageOptions() where p.key != "ImageAlpha" {
            // `Path` is the deprecated spelling the Image meter still reads when ImagePath is empty.
            if p.key == "ImagePath" { p.legacyKeys = ["Path"] }
            picture.append(p)
        }
        picture += [
            measureName.labelled("Shows", help: "Live data whose value names the picture (%1)").with(level: .more),
            Property("MaskImageName", "Mask", .image, help: "Its shape cuts out the picture"),
            Property("MaskImagePath", "Mask folder", .text, visibleWhen: [.isSet("MaskImageName")]),
            Property("MaskImageFlip", "Flip mask", pick(flip), default: "None", visibleWhen: [.isSet("MaskImageName")]),
            Property("MaskImageRotate", "Rotate mask", .angle(unit: .degrees, orientation: true), default: "0",
                     visibleWhen: [.isSet("MaskImageName")]),
        ]
        return [Group(title: "Picture", properties: picture, moreSummary: "tint, crop, rotation, flip, tile, grayscale")]
    }()

    static let barGroups: [Group] = [
        Group(title: "Bar", properties: [
            measureName,
            Property("BarColor", "Fill", .color, default: "0,128,0,255", level: .essential),
            Property("SolidColor", "Empty part", .color, default: "0,0,0,0", placeholder: "none", level: .essential),
            Property("BarOrientation", "Fills toward", pick(orientation), default: "Vertical",
                     invalidNote: "anything but Horizontal fills upward", level: .essential),
            Property("Flip", "Reverse", flag("Fill from the other end"), default: "0", level: .essential,
                     partOf: "BarOrientation"),
            Property("BarImage", "Picture instead of a color", .image, help: "Revealed instead of the color, at its own size"),
            Property("BarBorder", "Fixed ends", num(0, 32768, step: 1, unit: "px"), default: "0",
                     visibleWhen: [.isSet("BarImage")]),
        ] + imageOptions(when: [.isSet("BarImage")]) + [
            Property("SolidColor2", "Empty part fades to", .color, placeholder: "none"),
            Property("GradientAngle", "Fade direction", .angle(unit: .degrees, orientation: true), default: "0",
                     visibleWhen: [.isSet("SolidColor2")]),
        ] + boxExtras.dropFirst(2) + [padding],
              moreSummary: "picture instead of a color, raised edge, space around it", moreTitle: "More Bar Options"),
    ]

    static let graphDirection: [Property] = [
        Property("GraphOrientation", "Direction", pick(orientation), default: "Vertical",
                 help: "Vertical: time runs left to right"),
        Property("Flip", "Flip", flag("Values grow from the top"), default: "0"),
    ]

    /// Behind a graph: the box options, SolidColor first as "Behind the graph".
    static let graphBox: [Property] = boxExtras + [padding]
    static let graphBackground = Property("SolidColor", "Behind the graph", .color, default: "0,0,0,0",
                                          placeholder: "none", level: .essential)

    static let lineGroups: [Group] = [
        Group(title: "Graph", properties: [
            measureName,
            Property("LineColor", "Line", .color, default: "255,255,255,255", level: .essential),
            Property("LineWidth", "Thickness", num(0, 1000, step: 0.5, unit: "px"), default: "1", level: .essential,
                     partOf: "LineColor"),
            graphBackground,
            Property("GraphStart", "New values appear on the", pick(graphStart), default: "Right", level: .essential),
            Property("HorizontalLines", "Grid lines", flag("Show grid lines"), default: "0"),
            Property("HorizontalLineColor", "Grid color", .color, default: "0,0,0,255",
                     visibleWhen: [.equals("HorizontalLines", "1")]),
            Property("AutoScale", "Scale", flag("Fit the largest value"), default: "0"),
            Property("Scale", "Multiply by", num(), default: "1", visibleWhen: [.equals("AutoScale", "0")]),
            Property("LineCount", "Lines", num(0, 64, step: 1), default: "1",
                     help: "Line N shows live data N, in color N"),
        ] + graphDirection + [
            Property("TransformStroke", "Line width", pick(transformStroke), default: "Normal",
                     visibleWhen: [.isSet("TransformationMatrix")]),
            antiAlias,
        ] + graphBox, moreSummary: "grid lines, scale, more lines", moreTitle: "More Graph Options"),
    ]

    static let histogramGroups: [Group] = [
        Group(title: "Graph", properties: [
            measureName,
            Property("PrimaryColor", "Bars", .color, default: "0,128,0,255", level: .essential),
            graphBackground,
            Property("GraphStart", "New values appear on the", pick(graphStart), default: "Right"),
            Property("MeasureName2", "Second value", .sectionRef(.measure), legacyKeys: ["SecondaryMeasureName"]),
            Property("SecondaryColor", "Second color", .color, default: "255,0,0,255", visibleWhen: [.isSet("MeasureName2")]),
            Property("BothColor", "Overlap color", .color, default: "255,255,0,255", visibleWhen: [.isSet("MeasureName2")]),
            Property("AutoScale", "Scale", flag("Fit the largest value"), default: "0"),
        ] + graphDirection + [
            Property("PrimaryImage", "Picture", .image, help: "Revealed instead of the color; sets the size"),
            Property("SecondaryImage", "Second picture", .image, visibleWhen: [.isSet("MeasureName2")]),
            Property("BothImage", "Overlap picture", .image, visibleWhen: [.isSet("MeasureName2")]),
            antiAlias,
        ] + graphBox, moreSummary: "second value, scale, pictures", moreTitle: "More Graph Options"),
    ]

    static let valueRemainder = Property("ValueRemainder", "Repeat every", num(0, nil, step: 1), default: "0",
                                         help: "0 = the live data's range; 60 = a second hand, 3600 minutes, 43200 hours",
                                         legacyKeys: ["ValueReminder"])

    static let roundlineGroups: [Group] = [
        Group(title: "Gauge", properties: [
            measureName,
            Property("LineColor", "Color", .color, default: "255,255,255,255", level: .essential),
            Property("LineWidth", "Thickness", num(0, nil, step: 0.5, unit: "px"), default: "1",
                     visibleWhen: [.equals("Solid", "0")], level: .essential),
            Property("StartAngle", "Starts at", .angle(unit: .radians, orientation: true), default: "0",
                     help: "0 = right of the center, clockwise", level: .essential),
            Property("RotationAngle", "Sweeps", .angle(unit: .radians, orientation: false), default: "6.2832",
                     placeholder: "full circle", help: "At 100 %; negative = counter-clockwise", level: .essential),
            Property("Solid", "Filled", flag("Fill a pie or ring"), default: "0"),
            // No minimum: a negative start puts the line's tail past the center (a clock hand), as the manual allows.
            Property("LineLength", "Length", num(nil, nil, step: 1, unit: "px"), default: "0",
                     help: "Nothing is drawn while it is 0"),
            Property("LineStart", "Starts from center at", num(nil, nil, step: 1, unit: "px"), default: "0",
                     help: "Negative values extend the line past the center"),
            valueRemainder,
            Property("ControlAngle", "Value turns", flag("The value turns the line"), default: "1"),
            Property("ControlStart", "Value moves inner end", flag("The value moves the inner end"), default: "0"),
            Property("StartShift", "Start offset", num(nil, nil, step: 1, unit: "px"), default: "0",
                     visibleWhen: [.equals("ControlStart", "1")]),
            Property("ControlLength", "Value moves outer end", flag("The value moves the outer end"), default: "0"),
            Property("LengthShift", "Length offset", num(nil, nil, step: 1, unit: "px"), default: "0",
                     visibleWhen: [.equals("ControlLength", "1")]),
            antiAlias,
        ], moreSummary: "filled, length, start offset", moreTitle: "More Gauge Options"),
    ]

    static let rotatorGroups: [Group] = [
        Group(title: "Dial", properties: [
            measureName,
            Property("ImageName", "Picture", .image, level: .essential),
            Property("StartAngle", "Starts at", .angle(unit: .radians, orientation: true), default: "0", level: .essential),
            Property("RotationAngle", "Sweeps", .angle(unit: .radians, orientation: false), default: "6.2832",
                     placeholder: "full circle", level: .essential),
            Property("OffsetX", "Center X", num(nil, nil, step: 1, unit: "px"), default: "0",
                     help: "The point of the picture that turns on the dial's center"),
            Property("OffsetY", "Center Y", num(nil, nil, step: 1, unit: "px"), default: "0",
                     help: "The point of the picture that turns on the dial's center"),
            valueRemainder,
        // A dial's picture comes from a file of its own: the camera's orientation and a picture folder show only when
        // a skin sets them.
        ] + imageOptions().map { p in
            ["UseExifOrientation", "ImagePath"].contains(p.key) ? p.shown(when: [.isSet(p.key)]) : p
        }, moreSummary: "turning point, tint, crop, flip", moreTitle: "More Dial Options"),
    ]

    static let buttonGroups: [Group] = [
        Group(title: "Button", properties: [
            Property("ButtonImage", "Picture", .image, help: "Three frames side by side or stacked: normal, pressed, hover",
                     level: .essential),
            Property("ButtonCommand", "When clicked", .action, level: .essential),
        ] + imageOptions(crop: false, rotate: false), moreSummary: "tint, flip, grayscale"),
    ]

    static let bitmapGroups: [Group] = [
        Group(title: "Number Picture", properties: [
            measureName,
            Property("BitmapImage", "Picture", .image, help: "A strip of frames", level: .essential),
            Property("BitmapFrames", "Frames", num(1, 100_000, step: 1), default: "1", level: .essential),
            Property("BitmapZeroFrame", "Zero frame", flag("First frame only at exactly 0"), default: "0"),
            Property("BitmapExtend", "Digits", flag("Show the number digit by digit"), default: "0"),
            Property("BitmapDigits", "Number of digits", num(0, 64, step: 1), default: "0", placeholder: "as needed",
                     visibleWhen: [.equals("BitmapExtend", "1")]),
            Property("BitmapAlign", "Alignment", pick(bitmapAlign), default: "Left", visibleWhen: [.equals("BitmapExtend", "1")]),
            Property("BitmapSeparation", "Digit spacing", num(nil, nil, step: 1, unit: "px"), default: "0",
                     visibleWhen: [.equals("BitmapExtend", "1")]),
            Property("BitmapTransitionFrames", "Transition frames", num(0, nil, step: 1), default: "0"),
        ] + imageOptions(crop: false, rotate: false), moreSummary: "digits, transition, tint",
              moreTitle: "More Number Picture Options"),
    ]

    static let shapeGroups: [Group] = [
        Group(title: "Shape", properties: [
            Property("Shape", "Shapes", .shapes, help: "Shape, Shape2… drawn in order, later ones in front",
                     level: .essential),
        ], moreSummary: "rotate, scale, skew, dashes, line ends", moreTitle: "More Shape Options"),
    ]

    // MARK: - Measures

    /// A measure type or plugin in plain words.
    public struct MeasureType: Equatable {
        /// As written in `Measure=` (or `Plugin=` for plugins).
        public var name: String
        /// Only as `Measure=Plugin` + `Plugin=name`.
        public var isPlugin: Bool
        /// Also accepted in the other form (former plugins: `Measure=Plugin` + `Plugin=X` = `Measure=X`).
        public var bothForms: Bool
        /// Other `Plugin=` names for the same plugin.
        public var aliases: [String]
        public var title: String
        public var symbol: String
        /// False when it cannot produce its values on macOS.
        public var supportedOnMac: Bool
    }

    static func type(_ name: String, _ title: String, _ symbol: String, plugin: Bool = false, both: Bool = false,
                     aliases: [String] = [], mac: Bool = true) -> MeasureType {
        MeasureType(name: name, isPlugin: plugin, bothForms: both, aliases: aliases, title: title, symbol: symbol,
                    supportedOnMac: mac)
    }

    /// Every measure type and plugin the engine and the app provide (Skin.makeMeasure, CorePlugins, LuaSupport,
    /// AudioPlugins, MediaUIPlugins) — 50 in all.
    public static let measureTypes: [MeasureType] = [
        type("CPU", "CPU usage", "cpu"),
        type("Memory", "Memory used (Windows-style)", "memorychip"),
        type("PhysicalMemory", "Memory used", "memorychip"),
        type("SwapMemory", "Memory and swap used", "memorychip.fill"),
        type("NetIn", "Download speed", "arrow.down.circle"),
        type("NetOut", "Upload speed", "arrow.up.circle"),
        type("NetTotal", "Network speed", "arrow.up.arrow.down.circle"),
        type("FreeDiskSpace", "Free disk space", "internaldrive"),
        type("Time", "Time and date", "clock"),
        type("Uptime", "Time since startup", "timer"),
        type("Calc", "Formula", "plus.forwardslash.minus"),
        type("Loop", "Counting number", "repeat"),
        type("String", "Fixed text", "textformat"),
        type("Process", "Running app", "app.badge", both: true),
        type("SysInfo", "Mac info", "info.circle", both: true),
        type("WebParser", "Text from a web page", "globe", both: true),
        type("Registry", "Windows registry", "list.bullet.rectangle", mac: false),
        type("Script", "Lua script", "curlybraces"),
        type("RecycleManager", "Trash", "trash", both: true),
        type("NowPlaying", "Now playing", "music.note", both: true),
        type("MediaKey", "Media keys", "playpause", both: true),
        type("WiFiStatus", "Wi-Fi signal", "wifi", both: true),
        type("PowerPlugin", "Battery", "battery.75percent", plugin: true),
        type("ActionTimer", "Timed actions", "stopwatch", plugin: true),
        type("CoreTemp", "CPU temperature", "thermometer.medium", plugin: true),
        type("AdvancedCPU", "Processor time by app", "chart.bar.xaxis", plugin: true),
        type("PingPlugin", "Ping time", "antenna.radiowaves.left.and.right", plugin: true, aliases: ["Ping"]),
        type("RunCommand", "Shell command", "terminal", plugin: true),
        type("QuotePlugin", "Random quote or file", "quote.bubble", plugin: true, aliases: ["Quote"]),
        type("FileView", "Folder browser", "folder", plugin: true),
        type("FolderInfo", "Folder size", "folder.circle", plugin: true),
        type("UsageMonitor", "Top apps", "list.number", plugin: true),
        type("PerfMon", "Performance counter", "gauge", plugin: true, aliases: ["PerfMonPlugin"]),
        type("ResMon", "Open files", "square.stack.3d.up", plugin: true),
        type("SpeedFanPlugin", "Temperatures and fans", "fanblades", plugin: true, aliases: ["SpeedFan"]),
        type("WindowMessagePlugin", "Window messages", "envelope", plugin: true, aliases: ["WindowMessage"], mac: false),
        type("VirtualDesktops", "Virtual desktops", "square.split.2x2", plugin: true),
        type("Mouse", "Mouse input", "computermouse", plugin: true),
        type("Slider", "Mouse input (Slider)", "slider.horizontal.3", plugin: true),
        type("AudioLevel", "Sound", "waveform", plugin: true),
        type("Win7AudioPlugin", "Volume", "speaker.wave.2", plugin: true, aliases: ["Win7Audio"]),
        type("AppVolume", "App volume", "speaker.wave.2.circle", plugin: true),
        type("iTunesPlugin", "Now playing (iTunes)", "music.note.list", plugin: true, aliases: ["iTunes"]),
        type("WebNowPlaying", "Now playing (any player)", "play.rectangle", plugin: true),
        type("InputText", "Text input box", "keyboard", plugin: true),
        type("FrostedGlass", "Blurred glass background", "camera.filters", plugin: true),
        type("Chameleon", "Colors from the wallpaper", "paintpalette", plugin: true),
        type("IsFullScreen", "Full-screen app", "arrow.up.left.and.arrow.down.right", plugin: true),
        type("GetActiveTitle", "Active window title", "macwindow", plugin: true),
        type("SysColor", "System accent color", "eyedropper", plugin: true),
    ]

    /// One item of the "+ Add Live Data" menu and of every Shows menu's "New ▸" (docs/editor-friendly.md §5.3): a
    /// name, a one-line description, the type it creates and the options it starts with. This catalogue is the only
    /// one: the sidebar's "+ Add Live Data", the Shows menus and the canvas's "Choose what this shows ▾" all list it.
    public struct LiveDataChoice: Equatable {
        public var title: String
        public var detail: String
        /// A `MeasureType.name` (nil for an item that only holds `children`).
        public var type: String?
        /// Options written after `Measure=` / `Plugin=` (`Formula=Random` for a random number), in writing order.
        public var orderedOptions: [(key: String, value: String)]
        /// A submenu (Network speed ▸ Download · Upload · Both).
        public var children: [LiveDataChoice]

        public init(_ title: String, _ detail: String, type: String?, options: KeyValuePairs<String, String> = [:],
                    children: [LiveDataChoice] = []) {
            self.title = title
            self.detail = detail
            self.type = type
            self.orderedOptions = options.map { (key: $0.key, value: $0.value) }
            self.children = children
        }

        /// The measure type it creates.
        public var measureType: MeasureType? { type.flatMap { t in measureTypes.first { $0.name == t } } }

        /// The options by name.
        public var options: [String: String] {
            Dictionary(orderedOptions.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        public static func == (a: LiveDataChoice, b: LiveDataChoice) -> Bool {
            a.title == b.title && a.detail == b.detail && a.type == b.type && a.children == b.children
                && a.orderedOptions.map { [$0.key, $0.value] } == b.orderedOptions.map { [$0.key, $0.value] }
        }
    }

    /// A section of the live data catalogue ("On This Mac", "Calculate", "From the Web").
    public struct LiveDataSection: Equatable {
        public var title: String
        public var items: [LiveDataChoice]
    }

    /// The live data catalogue (docs/editor-friendly.md §5.3), in menu order. Everything else is under "Extras"
    /// (`extraLiveDataTypes`). "Swap used" is not offered: the engine's SwapMemory is memory and swap together (it is
    /// under Extras), and real swap is a formula of two items.
    public static let liveDataCatalogue: [LiveDataSection] = [
        LiveDataSection(title: "On This Mac", items: [
            LiveDataChoice("CPU usage", "How busy the processor is (0–100%)", type: "CPU"),
            LiveDataChoice("Memory used", "How much memory apps are using", type: "PhysicalMemory"),
            LiveDataChoice("Network speed", "Download or upload speed", type: nil, children: [
                LiveDataChoice("Download", "Download speed", type: "NetIn"),
                LiveDataChoice("Upload", "Upload speed", type: "NetOut"),
                LiveDataChoice("Both", "Download and upload together", type: "NetTotal"),
            ]),
            LiveDataChoice("Disk space", "Free or used space on a disk", type: "FreeDiskSpace", options: ["Drive": "/"]),
            LiveDataChoice("Battery", "Charge level and status", type: "PowerPlugin"),
            LiveDataChoice("Time and date", "The current time or date", type: "Time"),
            LiveDataChoice("Time since startup", "How long your Mac has been on", type: "Uptime"),
            LiveDataChoice("Sound", "Loudness and spectrum of what's playing", type: "AudioLevel", options: ["Port": "Output"]),
            LiveDataChoice("Now playing", "The song in Music or Spotify", type: "NowPlaying", options: ["PlayerType": "Title"]),
            LiveDataChoice("Wi-Fi signal", "How strong the Wi-Fi is", type: "WiFiStatus", options: ["WiFiInfoType": "QUALITY"]),
            LiveDataChoice("Mac info", "Computer name, macOS version, user…", type: "SysInfo",
                           options: ["SysInfoType": "COMPUTER_NAME"]),
            LiveDataChoice("Running app", "Whether an app is open", type: "Process", options: ["ProcessName": "Finder"]),
        ]),
        LiveDataSection(title: "Calculate", items: [
            LiveDataChoice("Formula", "Math on other live data", type: "Calc"),
            LiveDataChoice("Counting number", "A number that counts up", type: "Loop",
                           options: ["StartValue": "1", "EndValue": "100"]),
            LiveDataChoice("Random number", "A new random number each update", type: "Calc",
                           options: ["Formula": "Random", "LowBound": "0", "HighBound": "100", "UpdateRandom": "1"]),
        ]),
        LiveDataSection(title: "From the Web", items: [
            LiveDataChoice("Text from a web page", "Reads a value from a page", type: "WebParser",
                           options: ["URL": "https://example.com", "RegExp": "(?siU)<title>(.*)</title>", "StringIndex": "1"]),
        ]),
    ]

    /// The types under "Extras (limited on a Mac)": every type the catalogue does not list, except the Windows-style
    /// memory; types that can't work on a Mac only with `details` (Show Rainmeter Details).
    public static func extraLiveDataTypes(details: Bool) -> [MeasureType] {
        func names(_ items: [LiveDataChoice]) -> [String] { items.flatMap { [$0.type].compactMap { $0 } + names($0.children) } }
        let listed = Set(liveDataCatalogue.flatMap { names($0.items) } + ["Memory"])
        return measureTypes.filter { !listed.contains($0.name) && ($0.supportedOnMac || details) }
    }

    /// The measure type a section uses: `Measure=X`, or `Measure=Plugin` with `Plugin=X` (folder, `.dll` and case
    /// ignored; plugin aliases accepted). `type` may also be the engine's effective type (`Measure.type`: the plugin
    /// name for plugin measures).
    public static func measureType(type: String, plugin: String? = nil) -> MeasureType? {
        let t = type.trimmingCharacters(in: .whitespaces).lowercased()
        let key = t == "plugin" ? MeasureRegistry.normalizedPluginName(plugin ?? "") : t
        guard !key.isEmpty else { return nil }
        return measureTypes.first { m in
            m.name.lowercased() == key || m.aliases.contains { $0.lowercased() == key }
        }
    }

    /// A measure in plain words, with an SF Symbol. `total` / `invert`: the measure's `Total=1` / `InvertMeasure=1`
    /// (memory and disk report totals or free / used space).
    public static func describeMeasure(type: String, plugin: String? = nil, total: Bool = false,
                                       invert: Bool = false) -> (title: String, symbol: String) {
        guard let m = measureType(type: type, plugin: plugin) else {
            let t = type.trimmingCharacters(in: .whitespaces)
            if t.lowercased() == "plugin" {
                // An add-on Deskset doesn't know, by its file's name ("Data from WebView"); never "plugin" (§3.2).
                var name = (plugin ?? "").replacingOccurrences(of: "\\", with: "/")
                if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
                if name.lowercased().hasSuffix(".dll") { name = String(name.dropLast(4)) }
                name = name.trimmingCharacters(in: .whitespaces)
                return (name.isEmpty ? "Add-on data" : "Data from \(name)", "puzzlepiece")
            }
            return (t.isEmpty ? "Data" : t, "waveform.path.ecg")
        }
        func amount(_ what: String, _ note: String = "") -> String {
            (total ? "Total \(what)" : invert ? what.prefix(1).uppercased() + what.dropFirst() + " free"
                : what.prefix(1).uppercased() + what.dropFirst() + " used") + note
        }
        switch m.name {
        // Memory counts RAM twice plus swap (the Windows commit total), SwapMemory RAM plus swap.
        case "Memory": return (amount("memory", " (Windows-style)"), m.symbol)
        case "PhysicalMemory": return (amount("memory"), m.symbol)
        case "SwapMemory": return (amount("memory and swap"), m.symbol)
        case "FreeDiskSpace": return (total ? "Disk size" : invert ? "Used disk space" : m.title, m.symbol)
        default: return (m.title, m.symbol)
        }
    }

    /// Settings of a measure type (or plugin), in plain words: one "Settings" card (docs/editor-friendly.md §8.8) —
    /// the type's essentials, then behind "More Live Data Options" the rest of its own options, its events, the
    /// lowest and highest value, smoothing, "When the value…" and timing. `type` is `Measure=` (or the engine's
    /// effective type), `plugin` the `Plugin=` value.
    public static func measureGroups(_ type: String, plugin: String? = nil) -> [Group] {
        let name = measureType(type: type, plugin: plugin)?.name ?? ""
        var specific = measureSettings(name) + measureEvents(name)
        // A type whose essentials are not listed: its first options that always show are its essentials.
        if !specific.contains(where: { $0.level == .essential }) {
            var picked = 0
            for i in specific.indices where picked < 2 && specific[i].visibleWhen.isEmpty && !specific[i].kind.isBool
                && specific[i].kind != .action {
                specific[i].level = .essential
                picked += 1
            }
        }
        var common = rangeProperties(name) + measureConditions.properties + measureBehavior.properties
        // Commands only (Media keys…): turning it off is what there is to do.
        if !specific.contains(where: { $0.level == .essential }),
           let i = common.firstIndex(where: { $0.key == "Disabled" }) {
            common[i].level = .essential
        }
        return [Group(title: "Settings", properties: specific + common,
                      moreSummary: "lowest and highest value, smoothing, when the value…, replace text, timing",
                      moreTitle: "More Live Data Options")]
    }

    /// MinValue / MaxValue / InvertMeasure / AverageSize as the type allows them (`Measure.allows…`: no MaxValue for
    /// Memory and FreeDiskSpace, none of them for Loop, no InvertMeasure for String; Memory and FreeDiskSpace list
    /// InvertMeasure under Settings as "free" / "used").
    static func rangeProperties(_ name: String) -> [Property] {
        let tracking: Set<String> = ["NetIn", "NetOut", "NetTotal", "Calc", "WebParser", "Script", "CoreTemp"]
        let automatic: [String: String] = ["CPU": "100", "PowerPlugin": "100", "Win7AudioPlugin": "100"]
        let net = name.hasPrefix("Net")
        var list: [Property] = []
        if name != "Loop" {
            list.append(Property("MinValue", "Lowest value", num(), default: "0",
                                 placeholder: tracking.contains(name) ? "auto" : "0",
                                 help: net ? "In bits per second" : ""))
        }
        if !["Loop", "Memory", "PhysicalMemory", "SwapMemory", "FreeDiskSpace"].contains(name) {
            let d = automatic[name] ?? (tracking.contains(name) ? "" : "1")
            list.append(Property("MaxValue", "Highest value", num(), default: d, placeholder: d.isEmpty ? "auto" : d,
                                 help: net ? "In bits per second; empty = learn from the values" : ""))
        }
        if !["String", "Memory", "PhysicalMemory", "SwapMemory", "FreeDiskSpace"].contains(name) {
            list.append(Property("InvertMeasure", "Flip the value", flag("Count down from the highest value"), default: "0"))
        }
        if name != "Loop" {
            list.append(Property("AverageSize", "Smoothing", num(0, 10_000, step: 1, unit: "readings"), default: "1",
                                 help: "Smooth over the last N readings"))
        }
        return list
    }

    /// The condition and threshold options every measure reads (`Measure.readConditions` / `readThresholds` /
    /// `readMatches`). IfCondition, its actions, IfMatch and its actions repeat as `IfCondition2`… (`numbered`); a
    /// threshold runs only with both its value and its action.
    static let measureConditions = Group(title: "Conditions", properties: [
        Property("IfCondition", "When", .formula,
                 help: "A comparison such as MeasureCPU > 80; names of live data stand for their values", numbered: true),
        Property("IfTrueAction", "Then", .action, visibleWhen: [.isSet("IfCondition")], numbered: true),
        Property("IfFalseAction", "Otherwise", .action, visibleWhen: [.isSet("IfCondition")], numbered: true),
        Property("IfConditionMode", "Repeat", flag("Run the actions on every update"), default: "0",
                 help: "Off: only when the result changes", visibleWhen: [.isSet("IfCondition")]),
        Property("IfAboveValue", "Above", num(), help: "Runs the action when the value rises above this"),
        Property("IfAboveAction", "When above", .action, visibleWhen: [.isSet("IfAboveValue")]),
        Property("IfBelowValue", "Below", num(), help: "Runs the action when the value drops below this"),
        Property("IfBelowAction", "When below", .action, visibleWhen: [.isSet("IfBelowValue")]),
        Property("IfEqualValue", "Equal to", num(step: 1), help: "Both are rounded to whole numbers"),
        Property("IfEqualAction", "When equal", .action, visibleWhen: [.isSet("IfEqualValue")]),
        Property("IfMatch", "Text matches", .text,
                 help: "A pattern tested against the text value (after Replace text)", numbered: true),
        Property("IfMatchAction", "When it matches", .action, visibleWhen: [.isSet("IfMatch")], numbered: true),
        Property("IfNotMatchAction", "When it doesn't match", .action, visibleWhen: [.isSet("IfMatch")], numbered: true),
        Property("IfMatchMode", "Repeat matches", flag("Run the match actions on every update"), default: "0",
                 help: "Off: only when the result changes", visibleWhen: [.isSet("IfMatch")]),
    ])

    static let measureBehavior = Group(title: "Behavior", properties: [
        Property("Substitute", "Replace text", .text, help: "\"old\":\"new\", \"old2\":\"new2\""),
        Property("RegExpSubstitute", "Patterns", flag("Replace using patterns"), default: "0",
                 visibleWhen: [.isSet("Substitute")]),
        Property("UpdateDivider", "Update every", num(-1, nil, step: 1, unit: "updates"), default: "1",
                 help: "-1 = only when the widget opens"),
        Property("Disabled", "Turned off", flag("Turned off (reads 0)"), default: "0"),
        Property("Paused", "Paused", flag("Paused (keeps its value)"), default: "0"),
        Property("DynamicVariables", "Live values", flag("Keep options in sync with live data"), default: "0",
                 level: .quiet),
        Property("OnUpdateAction", "When it updates", .action),
        Property("OnChangeAction", "When the value changes", .action),
        Property("Group", "Group names", .text, placeholder: "e.g. Sensors",
                 help: "Names separated by |, used by actions that change several at once"),
    ])

    static let sysInfoMonitorTypes = ["SCREEN_WIDTH", "SCREEN_HEIGHT", "VIRTUAL_SCREEN_TOP", "VIRTUAL_SCREEN_LEFT",
                                      "WORK_AREA_TOP", "WORK_AREA_LEFT", "WORK_AREA_WIDTH", "WORK_AREA_HEIGHT"]
    static let sysInfoAdapterTypes = ["ADAPTER_DESCRIPTION", "ADAPTER_TYPE", "ADAPTER_ALIAS", "ADAPTER_GUID",
                                      "ADAPTER_STATE", "ADAPTER_STATUS", "ADAPTER_TRANSMIT_SPEED",
                                      "ADAPTER_RECEIVE_SPEED", "MAC_ADDRESS", "NET_MASK", "IP_ADDRESS",
                                      "GATEWAY_ADDRESS", "GATEWAY_ADDRESS_V4", "GATEWAY_ADDRESS_V6", "LAN_CONNECTIVITY",
                                      "LAN_CONNECTIVITY_V4", "LAN_CONNECTIVITY_V6", "INTERNET_CONNECTIVITY",
                                      "INTERNET_CONNECTIVITY_V4", "INTERNET_CONNECTIVITY_V6"]
    static let sysInfoTypes: [Choice] = [
        Choice("COMPUTER_NAME", "Computer name"), Choice("USER_NAME", "User name"), Choice("HOST_NAME", "Host name"),
        Choice("OS_VERSION", "macOS version"), Choice("OS_PRODUCT_NAME", "OS name"), Choice("OS_BITS", "32 / 64 bit"),
        Choice("PAGESIZE", "Memory page size"), Choice("USER_LOGONTIME", "Login time"),
        Choice("LAST_SLEEP_TIME", "Last sleep"), Choice("LAST_WAKE_TIME", "Last wake"),
        Choice("IDLE_TIME", "Seconds since last input"), Choice("IP_ADDRESS", "IP address"),
        Choice("NET_MASK", "Subnet mask"), Choice("MAC_ADDRESS", "MAC address"), Choice("GATEWAY_ADDRESS", "Gateway"),
        Choice("GATEWAY_ADDRESS_V4", "Gateway (IPv4)"), Choice("GATEWAY_ADDRESS_V6", "Gateway (IPv6)"),
        Choice("DNS_SERVER", "DNS server"), Choice("DOMAIN_NAME", "Domain"),
        Choice("DOMAIN_WORKGROUP", "Domain / workgroup"),
        Choice("ADAPTER_DESCRIPTION", "Network adapter name"), Choice("ADAPTER_ALIAS", "Network adapter alias"),
        Choice("ADAPTER_TYPE", "Network adapter type"), Choice("ADAPTER_STATE", "Network adapter connected"),
        Choice("ADAPTER_STATUS", "Network adapter status"), Choice("ADAPTER_TRANSMIT_SPEED", "Link speed out"),
        Choice("ADAPTER_RECEIVE_SPEED", "Link speed in"),
        Choice("ADAPTER_GUID", "Network adapter GUID", supportedOnMac: false, note: "Windows only; empty on the Mac"),
        Choice("LAN_CONNECTIVITY", "Local network connected"), Choice("LAN_CONNECTIVITY_V4", "Local network (IPv4)"),
        Choice("LAN_CONNECTIVITY_V6", "Local network (IPv6)"), Choice("INTERNET_CONNECTIVITY", "Internet connected"),
        Choice("INTERNET_CONNECTIVITY_V4", "Internet (IPv4)"), Choice("INTERNET_CONNECTIVITY_V6", "Internet (IPv6)"),
        Choice("NUM_MONITORS", "Number of displays"), Choice("SCREEN_SIZE", "Screen size"),
        Choice("SCREEN_WIDTH", "Screen width"), Choice("SCREEN_HEIGHT", "Screen height"),
        Choice("VIRTUAL_SCREEN_TOP", "All displays: top"), Choice("VIRTUAL_SCREEN_LEFT", "All displays: left"),
        Choice("VIRTUAL_SCREEN_WIDTH", "All displays: width"), Choice("VIRTUAL_SCREEN_HEIGHT", "All displays: height"),
        Choice("WORK_AREA", "Work area size"), Choice("WORK_AREA_TOP", "Work area top"),
        Choice("WORK_AREA_LEFT", "Work area left"), Choice("WORK_AREA_WIDTH", "Work area width"),
        Choice("WORK_AREA_HEIGHT", "Work area height"), Choice("TIMEZONE_ISDST", "Daylight saving time now"),
        Choice("TIMEZONE_BIAS", "UTC offset (minutes)"), Choice("TIMEZONE_STANDARD_NAME", "Time zone name"),
        Choice("TIMEZONE_STANDARD_BIAS", "Standard offset"),
        Choice("TIMEZONE_DAYLIGHT_NAME", "Daylight time zone name"), Choice("TIMEZONE_DAYLIGHT_BIAS", "Daylight offset"),
        Choice("USER_SID", "Windows user ID", supportedOnMac: false, note: "Windows only; empty on the Mac"),
    ]

    /// The type's own options ("Settings").
    static func measureSettings(_ name: String) -> [Property] {
        switch name {
        case "CPU":
            return [Property("Processor", "Processor", pick(processorChoices, style: .popup), default: "0",
                             help: "All cores together, or one core", otherValues: .numbers, level: .essential)]
        case "Memory", "PhysicalMemory", "SwapMemory":
            return [Property("Total", "Show", flag("Report the total amount"), default: "0", level: .essential),
                    Property("InvertMeasure", "Free", flag("Report the free amount instead"), default: "0",
                             level: .essential, partOf: "Total")]
        case "NetIn", "NetOut", "NetTotal":
            return netSettings
        case "FreeDiskSpace":
            return [Property("Drive", "Disk", .text, default: "C:", placeholder: "startup disk",
                             help: "/ or /Volumes/Name; C: is the startup disk", level: .essential),
                    Property("Total", "Show", flag("Report the disk size"), default: "0", level: .essential),
                    Property("InvertMeasure", "Used", flag("Report used space instead of free"), default: "0",
                             level: .essential, partOf: "Total"),
                    Property("Label", "Name", flag("Text is the disk's name"), default: "0"),
                    Property("Type", "Disk type", flag("Report the disk type"), default: "0"),
                    Property("IgnoreRemovable", "Removable disks", flag("Ignore removable disks"), default: "1")]
        case "Time": return timeSettings
        case "Uptime":
            return [Property("Format", "Format", .format(presets: uptimeFormats, preview: .uptime),
                             default: "%4!i!d %3!i!:%2!02i!", help: "%4 days, %3 hours, %2 minutes, %1 seconds",
                             level: .essential),
                    Property("AddDaysToHours", "Days as hours", flag("Count days as hours when days are not shown"),
                             default: "1"),
                    Property("SecondsValue", "Seconds", num(0, nil, step: 1, unit: "s"), placeholder: "time since startup",
                             help: "Formats this number of seconds instead")]
        case "Calc":
            let random: [Condition] = [.contains("Formula", "Random")]
            return [Property("Formula", "Formula", .formula, default: "0",
                             help: "Math on other live data, by name; Random, Counter", level: .essential),
                    Property("LowBound", "Random from", num(nil, nil, step: 1), default: "0", visibleWhen: random,
                             level: .essential),
                    Property("HighBound", "Random to", num(nil, nil, step: 1), default: "100", visibleWhen: random,
                             level: .essential),
                    Property("UpdateRandom", "New random number", flag("New random number every update"), default: "0",
                             visibleWhen: random),
                    Property("UniqueRandom", "Unique", flag("No repeats until every number was used"), default: "0",
                             visibleWhen: random)]
        case "Loop":
            return [Property("StartValue", "Start at", num(nil, nil, step: 1), default: "1", level: .essential),
                    Property("EndValue", "End at", num(nil, nil, step: 1), default: "100", level: .essential),
                    Property("Increment", "Step", num(nil, nil, step: 1), default: "1", level: .essential),
                    Property("LoopCount", "Times", num(0, nil, step: 1), default: "0", placeholder: "forever",
                             level: .essential)]
        case "String":
            return [Property("String", "Text", .text, level: .essential)]
        case "Process":
            return [Property("ProcessName", "App", .text, help: "App or process name, e.g. Safari (.exe is ignored)",
                             level: .essential)]
        case "SysInfo":
            return [Property("SysInfoType", "Shows", pick(sysInfoTypes, style: .popup), level: .essential),
                    Property("SysInfoData", "Display or adapter", .text,
                             help: "Display number (1, 2…) or network adapter (Best, en0, 1…)",
                             visibleWhen: [Condition("SysInfoType", .equals(sysInfoMonitorTypes + sysInfoAdapterTypes))],
                             level: .essential)]
        case "WebParser": return webParserSettings
        case "Registry":
            return [Property("RegHKey", "Root",
                             pick(list(["HKEY_CURRENT_USER", "HKEY_LOCAL_MACHINE", "HKEY_CLASSES_ROOT",
                                        "HKEY_CURRENT_CONFIG", "HKEY_USERS"]), style: .popup),
                             default: "HKEY_CURRENT_USER", help: "The Mac has no registry: only a few values are emulated",
                             level: .essential),
                    Property("RegKey", "Key", .text, level: .essential),
                    Property("RegValue", "Value", .text, placeholder: "default value", level: .essential),
                    Property("OutputType", "Output", pick([Choice("Value", "Value"), Choice("SubKeyList", "Sub-keys"),
                                                           Choice("ValueList", "Value names")]), default: "Value"),
                    Property("OutputDelimiter", "Separator", .text, default: "#CRLF#",
                             visibleWhen: [.notEquals("OutputType", "Value")])]
        case "Script":
            return [Property("ScriptFile", "Script", .text, help: "A Lua file, relative to the widget's folder",
                             level: .essential)]
        case "PowerPlugin":
            return [Property("PowerState", "Shows",
                             pick([Choice("Percent", "Charge (%)"), Choice("ACLine", "Plugged in"), Choice("Status", "Status"),
                                   Choice("Status2", "Status flags"), Choice("Lifetime", "Time left"),
                                   Choice("Hz", "Processor speed (Hz)"), Choice("MHz", "Processor speed (MHz)")],
                                  style: .popup), default: "Percent", level: .essential),
                    Property("Format", "Format", .format(presets: ["%H:%M", "%#H:%M"], preview: .time), default: "%H:%M",
                             visibleWhen: [.equals("PowerState", "Lifetime")], level: .essential)]
        default:
            return pluginSettings(name)
        }
    }

    static let netSettings: [Property] = [
        Property("Interface", "Network",
                 pick([Choice("Best", "Active connection"), Choice("0", "All")], style: .popup),
                 default: "Best", help: "Or an interface name such as en0, or its number", otherValues: .any,
                 level: .essential),
        Property("Cumulative", "Total", flag("Total since startup instead of per second"), default: "0"),
        Property("UseBits", "Bits", flag("Count bits instead of bytes"), default: "0"),
    ]

    static let timeSettings: [Property] = [
        Property("Format", "Format", .format(presets: timeFormats, preview: .time), default: "%H:%M:%S",
                 help: "%H hours, %M minutes, %A weekday, %#d day without zero…", level: .essential),
        Property("TimeZone", "Time zone", pick(timeZoneChoices, style: .popup), default: "local",
                 help: "Hours from UTC (any number, e.g. -5 or 5.5), or this Mac's time", otherValues: .numbers,
                 invalidNote: "only hours from UTC are understood, so local time is used", level: .essential),
        Property("DaylightSavingTime", "Daylight saving", flag("Apply daylight saving time"), default: "1",
                 visibleWhen: [.isSet("TimeZone"), .notEquals("TimeZone", "local")]),
        Property("FormatLocale", "Language", .text, placeholder: "English",
                 help: "Local, en-US, de-DE, zh-CN…: language of day and month names"),
        Property("TimeStamp", "Fixed time", .text, help: "Shows this moment instead of now"),
        Property("TimeStampFormat", "Fixed time format", .format(presets: [], preview: .none),
                 visibleWhen: [.isSet("TimeStamp")]),
        Property("TimeStampLocale", "Fixed time language", .text, visibleWhen: [.isSet("TimeStamp")]),
    ]

    /// `TimeZone`: local time, then the UTC offsets in use (whole hours from −12 to +14, and the half- and
    /// quarter-hour ones). Any other number of hours is accepted too (`otherValues: .numbers`).
    static let timeZoneChoices: [Choice] = {
        let fractional: [Double] = [-9.5, -3.5, 3.5, 4.5, 5.5, 5.75, 6.5, 8.75, 9.5, 10.5, 12.75]
        let hours = ((-12...14).map(Double.init) + fractional).sorted()
        return [Choice("local", "This Mac")] + hours.map { h in
            let magnitude = abs(h)
            let whole = Int(magnitude)
            let minutes = Int(((magnitude - Double(whole)) * 60).rounded())
            let title = h == 0 ? "UTC" : "UTC\(h < 0 ? "−" : "+")\(whole)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
            return Choice(GeometryEdit.format(h), title)
        }
    }()

    static let webParserSettings: [Property] = [
        Property("URL", "Address", .text, help: "https://…, file://…, or [ParentMeasure] for a piece of another",
                 level: .essential),
        Property("RegExp", "Pattern", .text, help: "Regular expression, e.g. (?siU)<title>(.*)</title>",
                 level: .essential),
        Property("StringIndex", "Piece", num(0, 1000, step: 1), default: "0", help: "Which captured piece to show",
                 level: .essential),
        Property("StringIndex2", "Sub-piece", num(0, 1000, step: 1), default: "0", visibleWhen: [.isSet("RegExp")]),
        Property("UpdateRate", "Reload every", num(1, nil, step: 1, unit: "updates"), default: "600"),
        Property("DecodeCharacterReference", "Decode entities",
                 pick([Choice("0", "No"), Choice("1", "All"), Choice("2", "Numeric only"), Choice("3", "Named only")],
                      style: .popup), default: "0"),
        Property("Download", "Download", flag("Download the file instead of reading it"), default: "0"),
        Property("DownloadFile", "Save as", .text, visibleWhen: [.equals("Download", "1")]),
        Property("ErrorString", "Text on error", .text),
        Property("CodePage", "Encoding",
                 pick([Choice("0", "Automatic"), Choice("65001", "UTF-8"), Choice("1200", "UTF-16 LE"),
                       Choice("1201", "UTF-16 BE"), Choice("12000", "UTF-32 LE"), Choice("12001", "UTF-32 BE"),
                       Choice("1252", "Western (Latin-1)"), Choice("1251", "Cyrillic"), Choice("936", "Chinese (GBK)"),
                       Choice("932", "Japanese (Shift-JIS)")], style: .popup),
                 default: "0", otherValues: .numbers),
        Property("UserAgent", "User agent", .text, placeholder: "built-in"),
        Property("ProxyServer", "Proxy", pick([Choice("/auto", "System settings"), Choice("/none", "No proxy")], style: .popup),
                 default: "/auto", help: "Or host:port", otherValues: .any),
        Property("Flags", "Flags", .text, default: "Resync", help: "Names separated by |, e.g. ForceReload"),
        Property("DecodeCodePoints", "Decode \\u escapes", flag("Decode \\uXXXX escapes"), default: "0"),
        Property("LogSubstringErrors", "Log errors", flag("Log pieces that are not found"), default: "1"),
        Property("Debug", "Debug", pick([Choice("0", "Off"), Choice("1", "Log details"), Choice("2", "Save the page")]),
                 default: "0"),
        Property("Debug2File", "Debug file", .text, visibleWhen: [.equals("Debug", "2")]),
    ]

    /// Settings of the plugins (Engine/Plugins/*, the app's Plugins/*).
    static func pluginSettings(_ name: String) -> [Property] {
        switch name {
        case "ActionTimer":
            return [Property("ActionList1", "Sequence 1", .action,
                             help: "e.g. Step1 | Wait 10 | Repeat Step2, 5, 20; ActionList2… for more"),
                    Property("IgnoreWarnings", "Warnings", flag("Don't warn when a running sequence starts again"),
                             default: "0")]
        case "CoreTemp":
            let sensors = "needs hardware sensors; 0 on the Mac today"
            return [Property("CoreTempType", "Shows",
                             pick([Choice("MaxTemperature", "Hottest core", note: sensors),
                                   Choice("Temperature", "Core temperature", note: sensors),
                                   Choice("TjMax", "Maximum temperature", note: sensors), Choice("Load", "Core load"),
                                   Choice("CpuSpeed", "Processor speed"), Choice("CoreSpeed", "Core speed"),
                                   Choice("CpuName", "Processor name"), Choice("Vid", "Core voltage", note: sensors),
                                   Choice("Tdp", "Thermal design power", note: sensors),
                                   Choice("Power", "Power", note: sensors), Choice("BusSpeed", "Bus speed", note: sensors),
                                   Choice("BusMultiplier", "Multiplier", note: sensors),
                                   Choice("CoreBusMultiplier", "Core multiplier", note: sensors)], style: .popup),
                             default: "MaxTemperature"),
                    Property("CoreTempIndex", "Core", num(0, 4095, step: 1), default: "0", help: "0 = the first core")]
        case "AdvancedCPU":
            return [Property("CPUInclude", "Only apps", .text, help: "Names separated by ;"),
                    Property("CPUExclude", "Leave out apps", .text, help: "Names separated by ;"),
                    Property("TopProcess", "Shows", pick([Choice("0", "Total"), Choice("1", "Busiest app's value"),
                                                          Choice("2", "Busiest app's name")]), default: "0")]
        case "PingPlugin":
            return [Property("DestAddress", "Address", .text, help: "Host name or IP address"),
                    Property("UpdateRate", "Ping every", num(1, nil, step: 1, unit: "updates"), default: "32"),
                    Property("Timeout", "Timeout", num(0, nil, step: 100, unit: "milliseconds"), default: "30000"),
                    Property("TimeoutValue", "Value without reply", num(), default: "30000"),
                    Property("FinishAction", "After each ping", .action)]
        case "RunCommand":
            return [Property("Parameter", "Command", .text, help: "The command line to run"),
                    Property("Program", "Program", .text, placeholder: "/bin/sh -c"),
                    Property("StartInFolder", "Working folder", .text, placeholder: "widget's folder"),
                    Property("Timeout", "Stop after", num(-1, nil, step: 100, unit: "milliseconds"), default: "-1",
                             placeholder: "never"),
                    Property("OutputType", "Output encoding", pick(list(["UTF16", "UTF8", "ANSI"])), default: "UTF16"),
                    Property("OutputFile", "Save output to", .text),
                    Property("FinishAction", "When finished", .action)]
        case "QuotePlugin":
            return [Property("PathName", "File or folder", .text, help: "A text file (random line) or a folder (random file)"),
                    Property("Separator", "Separator", .text, placeholder: "new line"),
                    Property("Subfolders", "Subfolders", flag("Include subfolders"), default: "1"),
                    Property("FileFilter", "File types", .text, help: "e.g. *.jpg;*.png")]
        case "FileView":
            return [Property("Path", "Folder", .text, placeholder: "mounted disks",
                             help: "Folder to list (parent), or [ParentMeasure] for an item"),
                    Property("Count", "Items per page", num(1, nil, step: 1), default: "1"),
                    Property("Index", "Item", num(1, nil, step: 1), default: "1", help: "Item number on the page (child)"),
                    Property("Type", "Shows",
                             pick(list(["FolderPath", "FolderSize", "FileCount", "FolderCount", "FileName", "FileType",
                                        "FileSize", "FileDate", "FilePath", "PathToFile", "Icon"]), style: .popup),
                             default: "FolderPath"),
                    Property("SortType", "Sort by", pick(list(["Name", "Size", "Type", "Date"])), default: "Name"),
                    Property("SortAscending", "Ascending", flag("Sort ascending"), default: "1"),
                    Property("ShowHidden", "Hidden files", flag("Show hidden files"), default: "1"),
                    Property("ShowDotDot", "Parent entry", flag("Show “..”"), default: "1"),
                    Property("ShowFile", "Files", flag("Show files"), default: "1"),
                    Property("ShowFolder", "Folders", flag("Show folders"), default: "1"),
                    Property("HideExtensions", "Extensions", flag("Hide file extensions"), default: "0"),
                    Property("WildcardSearch", "Filter", .text, default: "*"),
                    Property("FinishAction", "When listed", .action)]
        case "FolderInfo":
            return [Property("Folder", "Folder", .text, help: "Or [OtherFolderInfo] to reuse its scan"),
                    Property("InfoType", "Shows", pick([Choice("FolderSize", "Size"), Choice("FileCount", "Files"),
                                                        Choice("FolderCount", "Folders")]), default: "FolderSize"),
                    Property("IncludeSubFolders", "Subfolders", flag("Include subfolders"), default: "0"),
                    Property("IncludeHiddenFiles", "Hidden files", flag("Include hidden files"), default: "0"),
                    Property("IncludeSystemFiles", "System files", flag("Include system files"), default: "0"),
                    Property("RegExpFilter", "Only names matching", .text)]
        case "RecycleManager":
            return [Property("RecycleType", "Shows", pick([Choice("Count", "Items"), Choice("Size", "Size")]),
                             default: "Count")]
        case "UsageMonitor":
            let perApp = "not available per app on the Mac"
            return [Property("Alias", "Rank by",
                             pick([Choice("CPU", "Processor"), Choice("RAM", "Memory"), Choice("RAMSHARED", "Shared memory"),
                                   Choice("IO", "Disk activity"), Choice("IOREAD", "Disk reads"),
                                   Choice("IOWRITE", "Disk writes"),
                                   Choice("GPU", "Graphics", supportedOnMac: false, note: perApp),
                                   Choice("VRAM", "Video memory", supportedOnMac: false, note: perApp),
                                   Choice("VRAMSHARED", "Shared video memory", supportedOnMac: false, note: perApp)],
                                  style: .popup)),
                    Property("Index", "Rank", num(-1, nil, step: 1), default: "0",
                             help: "0 = total, -1 = average, N = the Nth busiest app"),
                    Property("Name", "App", .text, help: "A specific app instead of a rank"),
                    Property("Blacklist", "Leave out", .text, default: "_Total|Idle"),
                    Property("Rollup", "Combine", flag("Add up apps with the same name"), default: "1"),
                    Property("Percent", "Percent", flag("Show as a percentage"), placeholder: "automatic for CPU")]
        case "PerfMon":
            return [Property("PerfMonObject", "Counter group",
                             pick(list(["Processor", "Processor Information", "Process", "Memory", "Paging File",
                                        "Network Interface", "Network Adapter", "LogicalDisk", "PhysicalDisk", "System",
                                        "Thermal Zone Information", "GPU Engine", "GPU Process Memory",
                                        "GPU Adapter Memory"]), style: .popup), otherValues: .any),
                    Property("PerfMonCounter", "Counter", .text, help: "e.g. % Processor Time, Bytes Received/sec"),
                    Property("PerfMonInstance", "Instance", .text, placeholder: "_Total"),
                    Property("PerfMonDifference", "Change", flag("Report the change since the last update"), default: "1")]
        case "ResMon":
            return [Property("ResCountType", "Counts",
                             pick([Choice("GDI", "GDI objects", supportedOnMac: false, note: "0 on the Mac"),
                                   Choice("USER", "USER objects", supportedOnMac: false, note: "0 on the Mac"),
                                   Choice("Handle", "Open files"),
                                   Choice("Window", "Windows", supportedOnMac: false, note: "0 on the Mac")]), default: "GDI"),
                    Property("ProcessName", "App", .text, placeholder: "whole system")]
        case "SpeedFanPlugin":
            return [Property("SpeedFanType", "Sensor", pick([Choice("Temperature", "Temperature"), Choice("Fan", "Fan"),
                                                             Choice("Voltage", "Voltage")]), default: "Temperature",
                             help: "Needs hardware sensors; 0 on the Mac today"),
                    Property("SpeedFanNumber", "Number", num(0, nil, step: 1), default: "0", help: "0 = the first sensor"),
                    Property("SpeedFanScale", "Unit", pick([Choice("C", "°C"), Choice("F", "°F"), Choice("K", "K")]),
                             default: "C")]
        case "WindowMessagePlugin":
            return [Property("WindowName", "Window title", .text, help: "Windows only; always 0 on the Mac"),
                    Property("WindowClass", "Window class", .text)]
        case "Mouse":
            return [Property("LeftMouseDragAction", "While dragging", .action,
                             help: "$MouseX$ and $MouseY$ are the pointer position; Right…, Middle…, X1…, X2… for "
                                 + "the other buttons", level: .essential),
                    Property("LeftMouseDownAction", "When pressed", .action),
                    Property("LeftMouseUpAction", "When released", .action),
                    Property("MouseMoveAction", "When the pointer moves", .action),
                    Property("RelativeToSkin", "Position from", pick([Choice("1", "The widget's corner"),
                                                                       Choice("0", "The screen's corner")]),
                             default: "1"),
                    Property("RequireDragging", "Start and stop", flag("Only between the Start and Stop commands"),
                             default: "0", help: "The commands are sent with !CommandMeasure"),
                    Property("UpdateRate", "Move actions at most every", num(0, 10_000, step: 1, unit: "milliseconds"),
                             default: "20", help: "0 = on every move")]
        case "Slider":
            return [Property("DragAction", "While dragging", .action,
                             help: "$MouseX$ and $MouseY$ are the pointer position", level: .essential),
                    Property("ClickAction", "When pressed", .action),
                    Property("ReleaseAction", "When released", .action),
                    Property("HoldAction", "When held down", .action),
                    Property("HoldDelay", "Held down for", num(0, nil, step: 1, unit: "milliseconds"), default: "300",
                             visibleWhen: [.isSet("HoldAction")]),
                    Property("MoveAction", "When the pointer moves", .action),
                    Property("MouseButton", "Button", pick(list(["Left", "Right", "Middle"])), default: "Left"),
                    Property("RelativeToSkin", "Position from", pick([Choice("1", "The widget's corner"),
                                                                       Choice("0", "The screen's corner")]),
                             default: "1")]
        case "VirtualDesktops":
            return [Property("VDMeasureType", "Shows",
                             pick(list(["VDMActive", "DesktopCount", "DesktopCountX", "DesktopCountY", "CurrentDesktop",
                                        "DesktopName", "Screenshot"]), style: .popup),
                             help: "The Mac reports one desktop")]
        case "AudioLevel": return audioLevelSettings
        case "AppVolume":
            let parent: [Condition] = [.isSet("Parent")], main: [Condition] = [.isNotSet("Parent")]
            return [Property("Parent", "Parent", .sectionRef(.measure), placeholder: "none (this is the parent)"),
                    Property("Index", "App number", num(0, nil, step: 1), default: "0", visibleWhen: parent),
                    Property("AppName", "App", .text, help: "A specific app instead of a number", visibleWhen: parent),
                    Property("NumberType", "Number shows", pick([Choice("Volume", "Volume"), Choice("Peak", "Peak level")]),
                             default: "Volume", legacyKeys: ["NumType"]),
                    Property("StringType", "Text shows", pick([Choice("FileName", "App name"), Choice("FilePath", "App path")]),
                             default: "FileName"),
                    Property("IgnoreSystemSound", "System sounds", flag("Hide system sounds"), default: "1", visibleWhen: main),
                    Property("ExcludeApp", "Leave out apps", .text, visibleWhen: main)]
        case "NowPlaying":
            return [Property("PlayerName", "Player", pick([Choice("iTunes", "Apple Music"), Choice("Spotify", "Spotify")]),
                             help: "Or [OtherMeasure] to share its player", otherValues: .any),
                    Property("PlayerType", "Shows",
                             pick(list(["Title", "Artist", "Album", "Cover", "Duration", "Position", "Progress", "State",
                                        "Status", "Volume", "Rating", "Repeat", "Shuffle", "Number", "Year", "Genre", "File",
                                        "Lyrics"]), style: .popup), default: "Title"),
                    Property("DisableLeadingZero", "Short times", flag("Write times as 3:05 instead of 03:05"), default: "0"),
                    Property("TrackChangeAction", "When the track changes", .action)]
        case "iTunesPlugin":
            return [Property("Command", "Shows",
                             pick(list(["GetCurrentTrackName", "GetCurrentTrackArtist", "GetCurrentTrackAlbum",
                                        "GetCurrentTrackArtwork", "GetCurrentTrackTime", "GetPlayerPosition",
                                        "GetPlayerPositionPercent", "GetSoundVolume", "GetCurrentTrackRating",
                                        "GetCurrentTrackGenre", "GetCurrentTrackYear", "GetCurrentTrackTrackNumber",
                                        "GetCurrentTrackTrackCount", "GetCurrentTrackComposer", "GetCurrentTrackComment",
                                        "GetCurrentTrackBitrate", "GetCurrentTrackSampleRate", "GetCurrentTrackBPM",
                                        "GetCurrentTrackEQ", "GetCurrentTrackKindAsString", "GetCurrentTrackSize"]),
                                  style: .popup), help: "Or the command a click runs", otherValues: .any),
                    Property("DefaultArtwork", "Artwork when missing", .image)]
        case "WebNowPlaying":
            return [Property("PlayerType", "Shows",
                             pick(list(["Title", "Artist", "Album", "Cover", "CoverWebAddress", "Duration", "Position",
                                        "Remaining", "Progress", "Volume", "State", "Status", "Rating", "Repeat", "Shuffle",
                                        "Player", "SupportsPlayPause", "SupportsSkipPrevious", "SupportsSkipNext",
                                        "SupportsSetPosition", "SupportsSetVolume", "SupportsToggleRepeatMode",
                                        "SupportsToggleShuffleActive", "SupportsSetRating", "RatingSystem",
                                        "IsUsingNativeAPIs"]), style: .popup), default: "Title"),
                    Property("DefaultPath", "Cover when missing", .image)]
        case "WiFiStatus":
            let listing: [Condition] = [.equals("WiFiInfoType", "LIST")]
            return [Property("WiFiInfoType", "Shows",
                             pick([Choice("SSID", "Network name"), Choice("QUALITY", "Signal quality"),
                                   Choice("TXRATE", "Transmit rate"), Choice("RXRATE", "Receive rate"),
                                   Choice("ENCRYPTION", "Encryption"), Choice("AUTH", "Authentication"),
                                   Choice("PHY", "Wi-Fi standard"), Choice("LIST", "Networks nearby")], style: .popup),
                             help: "Network name and list need Location permission"),
                    Property("WiFiIntfID", "Adapter", num(0, nil, step: 1), default: "0"),
                    Property("WiFiListStyle", "List style", num(0, 7, step: 1), default: "0", visibleWhen: listing),
                    Property("WiFiListLimit", "Networks in the list", num(1, nil, step: 1), default: "5", visibleWhen: listing)]
        case "InputText":
            return [Property("Command1", "Command", .action, help: "$UserInput$ is the typed text; Command2… for more"),
                    Property("DefaultValue", "Text in the box", .text),
                    Property("InputNumber", "Numbers", flag("Numbers only"), default: "0"),
                    Property("Password", "Password", flag("Hide the typed characters"), default: "0"),
                    Property("InputLimit", "Maximum length", num(0, nil, step: 1), default: "0", placeholder: "no limit"),
                    Property("FocusDismiss", "Close on focus loss", flag("Close when clicking elsewhere"), default: "1"),
                    Property("OnDismissAction", "When closed", .action)]
        case "FrostedGlass":
            return [Property("Type", "Effect",
                             pick([Choice("Blur", "Blur"), Choice("Acrylic", "Acrylic"), Choice("Mica", "Mica"),
                                   Choice("MicaAcrylic", "Mica Acrylic"), Choice("MicaAlt", "Mica Alt"),
                                   Choice("Backdrop", "Backdrop"),
                                   Choice("TranslucentBackdrop", "Translucent backdrop", aliases: ["TraslucentBackdrop"]),
                                   Choice("None", "None")], style: .popup), default: "Blur"),
                    Property("Corner", "Corners", pick([Choice("None", "Square"), Choice("Round", "Round"),
                                                        Choice("RoundSmall", "Round, small"), Choice("RoundWs", "Round (Ws)")]),
                             default: "None"),
                    Property("Border", "Border", .text, default: "None", help: "All, None, or Top | Left | Right | Bottom"),
                    Property("BorderColor", "Border color", .color, visibleWhen: [.notEquals("Border", "None")]),
                    Property("Backdrop", "Tint", .color, default: "0,0,0,0"),
                    Property("DarkMode", "Dark", flag("Dark appearance"), default: "0")]
        case "Chameleon":
            let main: [Condition] = [.isNotSet("Parent")]
            return [Property("Parent", "Parent", .sectionRef(.measure), placeholder: "none (this is the parent)"),
                    Property("Type", "Sample", pick([Choice("Desktop", "Wallpaper"), Choice("File", "Image file")]),
                             default: "Desktop", visibleWhen: main),
                    Property("Path", "Image", .image, visibleWhen: [.isNotSet("Parent"), .equals("Type", "File")]),
                    Property("Color", "Color",
                             pick(list(["Background1", "Background2", "Foreground1", "Foreground2", "Light1", "Light2",
                                        "Light3", "Light4", "Dark1", "Dark2", "Dark3", "Dark4", "Average", "Luminance"]),
                                  style: .popup), visibleWhen: [.isSet("Parent")]),
                    Property("Format", "Color format", pick([Choice("Hex", "Hex"), Choice("Dec", "R,G,B")]), default: "Hex",
                             visibleWhen: main),
                    Property("FallbackBG1", "Fallback background", .color, visibleWhen: main)]
        case "SysColor":
            return [Property("ColorType", "Color",
                             pick(list(["Accent", "Highlight", "HighlightText", "Desktop", "Window", "WindowText",
                                        "GrayText", "WindowFrame", "ButtonFace", "ButtonHighlight", "ButtonShadow", "Menu",
                                        "MenuText", "AppWorkspace", "ScrollBar", "Hyperlink", "DWM_OPAQUE_BLEND"]),
                                  style: .popup), default: "Accent"),
                    Property("DisplayType", "Channels", pick(list(["All", "RGB", "Red", "Green", "Blue", "Alpha"]),
                                                             style: .popup), default: "All"),
                    Property("Hex", "Hex", flag("Hex instead of R,G,B"), default: "0")]
        default:
            // Win7AudioPlugin, MediaKey, IsFullScreen, GetActiveTitle: no options (commands only).
            return []
        }
    }

    /// `Type` of an AudioLevel measure in the words of §8.8 ("Reads": the spec's "Measures" is an engine word).
    static let audioTypes: [Choice] = [
        Choice("RMS", "Loudness level"), Choice("Peak", "Peak level"), Choice("Band", "One sound band"),
        Choice("BandFreq", "Band frequency"), Choice("DeviceName", "Output device name"), Choice("FFT", "One frequency slice"),
        Choice("FFTFreq", "Slice frequency"), Choice("Format", "Sound format"), Choice("DeviceStatus", "Device status"),
        Choice("DeviceID", "Device ID"), Choice("DeviceList", "Device list"),
    ]

    static let audioLevelSettings: [Property] = {
        let main: [Condition] = [.isNotSet("Parent")]
        return [
            Property("Parent", "Listens to", .sectionRef(.measure), placeholder: "none (this is the parent)",
                     visibleWhen: [.isSet("Parent")], level: .essential),
            Property("Port", "Listen to", pick([Choice("Output", "What Your Mac Plays"), Choice("Input", "Microphone")]),
                     default: "Output", visibleWhen: main, level: .essential),
            Property("ID", "Device", .text, placeholder: "default device", visibleWhen: main),
            Property("Type", "Reads", pick(audioTypes, style: .popup), default: "RMS", level: .essential),
            Property("Channel", "Channel",
                     pick([Choice("Sum", "All channels", aliases: ["Avg"]), Choice("L", "Left", aliases: ["FL", "0"]),
                           Choice("R", "Right", aliases: ["FR", "1"]), Choice("C", "Center", aliases: ["2"]),
                           Choice("LFE", "Subwoofer", aliases: ["Sub", "3"]), Choice("BL", "Back left", aliases: ["4"]),
                           Choice("BR", "Back right", aliases: ["5"]), Choice("SL", "Side left", aliases: ["6"]),
                           Choice("SR", "Side right", aliases: ["7"])], style: .popup),
                     default: "Sum"),
            Property("Sensitivity", "Sensitivity", num(1, 1000, step: 1, unit: "dB"), default: "35", visibleWhen: main,
                     level: .essential),
            Property("FFTAttack", "Rises", num(0, 10_000, step: 10, unit: "milliseconds"), default: "300",
                     help: "How quickly the bands rise: 0 is instant", visibleWhen: main, level: .essential),
            Property("FFTDecay", "Falls", num(0, 10_000, step: 10, unit: "milliseconds"), default: "300",
                     help: "How slowly the bands fall", visibleWhen: main, level: .essential),
            Property("BandIdx", "Band", num(0, nil, step: 1), default: "0", visibleWhen: [.equals("Type", "Band", "BandFreq")],
                     level: .essential),
            Property("FFTSize", "Analysis size", num(0, 65536, step: 2), default: "0", visibleWhen: main),
            Property("FFTOverlap", "Overlap", num(0, nil, step: 1), default: "0", visibleWhen: main),
            Property("Bands", "Band count", num(0, 1024, step: 1), default: "0", visibleWhen: main),
            Property("FreqMin", "Lowest frequency", num(1, nil, step: 1, unit: "Hz"), default: "20", visibleWhen: main),
            Property("FreqMax", "Highest frequency", num(1, nil, step: 1, unit: "Hz"), default: "20000", visibleWhen: main),
            Property("RMSAttack", "Level rises", num(0, 10_000, step: 10, unit: "milliseconds"), default: "300",
                     visibleWhen: main),
            Property("RMSDecay", "Level falls", num(0, 10_000, step: 10, unit: "milliseconds"), default: "300",
                     visibleWhen: main),
            Property("RMSGain", "Level gain", num(0, nil, step: 0.1), default: "1", visibleWhen: main),
            Property("PeakAttack", "Peak rises", num(0, 10_000, step: 10, unit: "milliseconds"), default: "50",
                     visibleWhen: main),
            Property("PeakDecay", "Peak falls", num(0, 10_000, step: 10, unit: "milliseconds"), default: "2500",
                     visibleWhen: main),
            Property("FFTIdx", "Slice", num(0, nil, step: 1), default: "0", visibleWhen: [.equals("Type", "FFT", "FFTFreq")]),
        ]
    }()

    /// Events of some types (after their settings, in "More Live Data Options").
    static func measureEvents(_ name: String) -> [Property] {
        guard name == "WebParser" else { return [] }
        return [
            Property("FinishAction", "When loaded", .action),
            Property("OnConnectErrorAction", "When it can't connect", .action),
            Property("OnRegExpErrorAction", "When the pattern fails", .action),
            Property("OnDownloadErrorAction", "When the download fails", .action),
        ]
    }

    /// `Processor` of a CPU measure: all cores together (0), or one core.
    static let processorChoices: [Choice] = [Choice("0", "All cores")] + (1...32).map { Choice(String($0), "Core \($0)") }

    // MARK: - Lookup

    /// Every key the schema of `groups` covers (lowercased), legacy spellings included.
    public static func keys(_ groups: [Group]) -> Set<String> {
        var result = Set<String>()
        for g in groups {
            for p in g.properties {
                result.insert(p.key.lowercased())
                for k in p.legacyKeys { result.insert(k.lowercased()) }
            }
        }
        return result
    }

    /// The property for an option key (case-insensitive; legacy spellings find their property; `IfCondition2`
    /// finds the numbered `IfCondition`, see `numberedProperty`).
    public static func property(_ key: String, in groups: [Group]) -> Property? {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        for g in groups {
            for p in g.properties where p.key.lowercased() == k || p.legacyKeys.contains(where: { $0.lowercased() == k }) {
                return p
            }
        }
        return numberedProperty(key, in: groups)?.property
    }

    /// A repeated option (`numbered`): `IfCondition3` → (IfCondition, 3), `IfCondition` → (IfCondition, 1).
    /// Like the engine, the number starts at 2 and has no leading zero (`IfCondition1` / `IfCondition02` are not
    /// read). nil for keys that are not a numbered property.
    public static func numberedProperty(_ key: String, in groups: [Group]) -> (property: Property, index: Int)? {
        let k = key.trimmingCharacters(in: .whitespaces)
        let digits = k.reversed().prefix { $0.isASCII && $0.isNumber }.count
        let base = String(k.dropLast(digits)).lowercased()
        let index: Int
        if digits == 0 {
            index = 1
        } else {
            let number = k.suffix(digits)
            guard number.first != "0", let n = Int(number), n >= 2 else { return nil }
            index = n
        }
        for g in groups {
            for p in g.properties where p.numbered && p.key.lowercased() == base { return (p, index) }
        }
        return nil
    }

    /// The `index`-th copy of a numbered property (`IfTrueAction` 2 → key `IfTrueAction2`, label "Then (2)"), its
    /// conditions on other numbered options pointing at the same number (`IfCondition2`). Index 1 is `p` itself.
    public static func numbered(_ p: Property, index: Int, in groups: [Group]) -> Property {
        guard p.numbered, index >= 2 else { return p }
        var copy = p
        copy.key = p.key + String(index)
        copy.label = "\(p.label) (\(index))"
        copy.visibleWhen = p.visibleWhen.map { c in
            guard let other = property(c.key, in: groups), other.numbered else { return c }
            return Condition(other.key + String(index), c.test)
        }
        return copy
    }

    // MARK: - Validation

    /// The choice a written value stands for: case-insensitive, surrounding whitespace ignored, aliases understood;
    /// for number choices also the same number written differently (`1.0`, `(1)`, `5.50` for `5.5` in a list that
    /// also has words, like `TimeZone`'s `local`). nil when it matches none.
    public static func choice(for value: String, in choices: [Choice]) -> Choice? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if let c = choices.first(where: { c in
            c.value.caseInsensitiveCompare(v) == .orderedSame
                || c.aliases.contains { $0.caseInsensitiveCompare(v) == .orderedSame }
        }) {
            return c
        }
        if let n = OptionValue.number(v) {
            return choices.first { Double($0.value) == n }
        }
        return nil
    }

    /// `StringAlign` as the engine reads it (case and whitespace ignored; `Left` = `LeftTop`; unknown = Left · Top).
    public static func alignmentChoice(for value: String) -> Choice {
        let (h, v) = StringMeter.parseAlign(value)
        let name: String
        switch h {
        case .left: name = "Left"
        case .center: name = "Center"
        case .right: name = "Right"
        }
        let suffix: String
        switch v {
        case .top: suffix = ""
        case .center: suffix = "Center"
        case .bottom: suffix = "Bottom"
        }
        return choice(for: name + suffix, in: alignments) ?? alignments[0]
    }

    /// True when the text needs the skin to know its value (`#Var#`, `[Section]`).
    static func isDynamic(_ value: String) -> Bool { value.contains("#") || value.contains("[") }

    /// What is wrong with a written value, in plain words ("“aaaa” is not a shape type — nothing is drawn"), or nil
    /// when the engine reads it as intended. Values with variables are not judged (only the skin knows them); a
    /// choice the Mac reads but cannot honour says so.
    public static func issue(for value: String, property p: Property) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        if case .shapes = p.kind { return ShapeSpec.problem(in: value) }
        if isDynamic(v) { return nil }
        func fallback() -> String {
            if let note = p.invalidNote { return note }
            if let choices = p.kind.choices, let d = choice(for: p.defaultValue, in: choices) { return "\(d.title) is used" }
            if !p.defaultValue.isEmpty { return "the default (\(p.defaultValue)) is used" }
            return "it is ignored"
        }
        switch p.kind {
        case .choice(let choices, _):
            if let c = choice(for: v, in: choices) {
                if c.supportedOnMac { return nil }
                return "“\(c.title)” has no effect on the Mac" + (c.note.isEmpty ? "" : " — \(c.note)")
            }
            switch p.otherValues {
            case .any: return nil
            case .numbers where OptionValue.number(v) != nil: return nil
            default: return "“\(v)” is not one of the choices for \(p.label) — \(fallback())"
            }
        case .alignment9:
            if choice(for: v.filter { !$0.isWhitespace }, in: alignments) != nil { return nil }
            return "“\(v)” is not an alignment — \(alignmentChoice(for: v).title) is used"
        case .bool:
            return OptionValue.number(v) == nil ? "“\(v)” is not 0 or 1 — \(fallback())" : nil
        case .number(let lo, let hi, _, _):
            guard let n = OptionValue.number(v) else { return "“\(v)” is not a number — \(fallback())" }
            if let lo, n < lo { return "\(v) is less than \(GeometryEdit.format(lo))" }
            if let hi, n > hi { return "\(v) is more than \(GeometryEdit.format(hi))" }
            return nil
        case .percent255:
            guard let n = OptionValue.number(v) else { return "“\(v)” is not a number — \(fallback())" }
            return n < 0 || n > 255 ? "\(v) is outside 0–255 — it is limited to that range" : nil
        case .angle:
            return OptionValue.number(v) == nil ? "“\(v)” is not a number — \(fallback())" : nil
        case .color:
            return OptionValue.color(v) == nil ? "“\(v)” is not a color — \(fallback())" : nil
        default:
            return nil
        }
    }

    // MARK: - Relevance

    /// Whether a property is relevant given the section's current option values (`values(key)`: the written or
    /// resolved value, nil when missing). `groups` supplies the other options' kinds and defaults.
    public static func isVisible(_ p: Property, in groups: [Group], values: (String) -> String?) -> Bool {
        p.visibleWhen.allSatisfy { holds($0, in: groups, values: values, depth: 0) }
    }

    /// What the engine uses for a missing option given the other options: the first `defaultWhen` whose conditions
    /// hold, else `defaultValue`.
    public static func defaultValue(of p: Property, in groups: [Group], values: (String) -> String?) -> String {
        defaultValue(of: p, in: groups, values: values, depth: 0)
    }

    /// `depth` stops conditional defaults that (by mistake) depend on each other.
    static func defaultValue(of p: Property, in groups: [Group], values: (String) -> String?, depth: Int) -> String {
        guard depth < 8 else { return p.defaultValue }
        let rule = p.defaultWhen.first { $0.when.allSatisfy { holds($0, in: groups, values: values, depth: depth + 1) } }
        return rule?.value ?? p.defaultValue
    }

    /// One condition of `visibleWhen` / `defaultWhen`. Missing options count as their (conditional) default;
    /// `#Var#` / `[Section]` values always pass.
    static func holds(_ condition: Condition, in groups: [Group], values: (String) -> String?, depth: Int) -> Bool {
        let other = property(condition.key, in: groups)
        var raw = values(condition.key)
        if raw == nil, let other { raw = other.legacyKeys.lazy.compactMap(values).first }
        let written = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        if isDynamic(written) { return true }
        func current() -> String {
            var value = !written.isEmpty ? written
                : other.map { defaultValue(of: $0, in: groups, values: values, depth: depth) } ?? ""
            // A choice the engine does not accept counts as the default it uses instead (`TimeZone=Europe/Paris` is
            // local time, `StringEffect=aaaa` no effect).
            if !written.isEmpty, let other, case .choice(let choices, _) = other.kind, choice(for: written, in: choices) == nil {
                let accepted = other.otherValues == .any || (other.otherValues == .numbers && OptionValue.number(written) != nil)
                if !accepted { value = defaultValue(of: other, in: groups, values: values, depth: depth) }
            }
            return canonical(value, kind: other?.kind)
        }
        switch condition.test {
        case .isSet: return !written.isEmpty
        case .isNotSet: return written.isEmpty
        case .contains(let text): return written.range(of: text, options: .caseInsensitive) != nil
        case .equals(let list):
            let value = current()
            return list.contains { canonical($0, kind: other?.kind) == value }
        case .notEquals(let list):
            let value = current()
            return !list.contains { canonical($0, kind: other?.kind) == value }
        }
    }

    /// A value in comparable form: bools as 0 / 1, choices as their canonical value, lowercased.
    public static func canonical(_ value: String, kind: Kind?) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .bool?:
            return OptionValue.bool(v).map { $0 ? "1" : "0" } ?? v.lowercased()
        case .choice(let choices, _)?:
            return (choice(for: v, in: choices)?.value ?? v).lowercased()
        case .alignment9?:
            return alignmentChoice(for: v).value.lowercased()
        default:
            return v.lowercased()
        }
    }

    /// The groups with every property's `defaultValue` (and a placeholder that showed it) set to the default in
    /// effect for the current values (`defaultValue(of:in:values:)`), so a control marks the value the engine uses.
    public static func resolvingDefaults(_ groups: [Group], values: (String) -> String?) -> [Group] {
        groups.map { g in
            g.with(g.properties.map { p in
                guard !p.defaultWhen.isEmpty else { return p }
                var resolved = p
                resolved.defaultValue = defaultValue(of: p, in: groups, values: values)
                if p.placeholder == p.defaultValue { resolved.placeholder = resolved.defaultValue }
                return resolved
            })
        }
    }

    /// The groups with only the properties relevant for the current values (empty groups dropped), defaults
    /// resolved (`resolvingDefaults`).
    public static func visibleGroups(_ groups: [Group], values: (String) -> String?) -> [Group] {
        resolvingDefaults(groups, values: values).compactMap { g in
            let props = g.properties.filter { isVisible($0, in: groups, values: values) }
            return props.isEmpty ? nil : g.with(props)
        }
    }

    /// `meterGroups(type)` with only the properties relevant for the meter's current option values.
    public static func meterGroups(_ type: String, values: (String) -> String?) -> [Group] {
        visibleGroups(meterGroups(type), values: values)
    }

    /// `measureGroups(type, plugin:)` with only the properties relevant for the measure's current option values.
    public static func measureGroups(_ type: String, plugin: String? = nil, values: (String) -> String?) -> [Group] {
        visibleGroups(measureGroups(type, plugin: plugin), values: values)
    }
}

// MARK: - Reordering

extension IniWriter {
    /// Moves the `[section]` block so it comes right before `[before]` (nil: to the end of the file). Both must be
    /// in the file; returns false (and writes nothing) otherwise. Draw order follows file order, so this changes
    /// which meter is in front.
    @discardableResult
    public static func moveSection(_ section: String, before: String?, fileURL: URL) throws -> Bool {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        return try withFileLock(target) {
            let (text, encoding) = try TextDecoding.readFileDetectingEncoding(at: target)
            guard let updated = movingSection(text, section: section, before: before) else { return false }
            if updated.utf8.elementsEqual(text.utf8) { return true }
            let data = TextDecoding.encodeForWriting(updated, preferring: encoding)
            try data.write(to: target, options: .atomic)
            return true
        }
    }

    /// The text-level operation behind `moveSection`: a block is its header and every line up to the next header
    /// (comment lines right before the next header belong to that next section). nil when a section is missing.
    public static func movingSection(_ text: String, section: String, before: String?) -> String? {
        var lines: [(content: Substring, terminator: Substring)] = []
        IniSyntax.forEachLineWithTerminator(in: text) { lines.append(($0, $1)) }
        let newline: Substring = lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\r\n"
        // Block boundaries: [start, end) for the first definition of each section.
        var headers: [(name: Substring, index: Int)] = []
        for (i, line) in lines.enumerated() {
            if case .section(let name?) = IniSyntax.classify(line.content) { headers.append((name, i)) }
        }
        func block(_ name: String) -> Range<Int>? {
            guard let k = headers.firstIndex(where: { IniSyntax.namesEqual($0.name, name) }) else { return nil }
            var start = headers[k].index
            // The comments right above a header introduce it and move with it.
            while start > 0, case .comment = IniSyntax.classify(lines[start - 1].content) { start -= 1 }
            var end = k + 1 < headers.count ? headers[k + 1].index : lines.count
            while end > start + 1, case .comment = IniSyntax.classify(lines[end - 1].content) { end -= 1 }
            return start..<end
        }
        guard let moving = block(section) else { return nil }
        var destination = lines.count
        if let before {
            guard let b = block(before) else { return nil }
            if IniSyntax.namesEqual(before, section) { return text }
            destination = b.lowerBound
        }
        if destination >= moving.lowerBound && destination <= moving.upperBound { return text }
        var chunk = Array(lines[moving])
        // The moved block ends with a line break and a blank line, so it sits apart from its new neighbours.
        if chunk.last?.terminator.isEmpty == true { chunk[chunk.count - 1].terminator = newline }
        if let last = chunk.last, !IniSyntax.classify(last.content).isBlank { chunk.append(("", newline)) }
        var rest = lines
        rest.removeSubrange(moving)
        var insertAt = destination > moving.lowerBound ? destination - moving.count : destination
        if insertAt == rest.count, let last = rest.last {
            if last.terminator.isEmpty { rest[rest.count - 1].terminator = newline }
            if !IniSyntax.classify(rest[rest.count - 1].content).isBlank { rest.append(("", newline)) }
            insertAt = rest.count
        }
        rest.insert(contentsOf: chunk, at: min(insertAt, rest.count))
        // Drop a trailing blank line added at the very end.
        while let last = rest.last, IniSyntax.classify(last.content).isBlank, rest.count > 1,
              IniSyntax.classify(rest[rest.count - 2].content).isBlank {
            rest.removeLast()
        }
        var out = ""
        for l in rest { out += l.content; out += l.terminator }
        return out
    }
}

extension Skin {
    /// Moves a meter in the drawing order: right before `before` (nil: to the front, i.e. the end of the file).
    /// Only sections defined in the same file can be reordered; returns false otherwise.
    @discardableResult
    public func moveSection(_ name: String, before: String?) throws -> Bool {
        let file = sources.location(section: name)?.file ?? fileURL
        if let before, (sources.location(section: before)?.file ?? fileURL) != file { return false }
        return try IniWriter.moveSection(document.section(named: name)?.name ?? name, before: before, fileURL: file)
    }

    /// Meters that display `measure` (MeasureName, MeasureName2…).
    public func meters(using measure: String) -> [Meter] {
        meters.filter { m in m.measures.contains { $0.name.caseInsensitiveCompare(measure) == .orderedSame } }
    }
}

// MARK: - Plain words

extension EditorSchema {
    /// Engine words the default editor never shows (docs/editor-friendly.md §3.3, self-test G3), matched as whole
    /// words, singular or plural, in any case. "Plugin" too: add-ons are "Extras" (§3.2).
    public static let bannedWords = ["skin", "meter", "measure", "section", "variable", "meterstyle", "ms", "ini", "refresh",
                                     "plugin", "winding"]

    /// The first engine word or code in `text` ("skin", "#Accent#", "120,200,255,255", ".inc", "f(x)", "[MeasureCPU]"),
    /// nil when it reads as plain words. The one G3 check (the widget page's `WidgetPresets.isEngineText` asks it too).
    /// The widget's own words, quoted as the editor quotes them (“Audio”), are the author's and are not checked.
    public static func engineWord(in text: String) -> String? {
        let text = text.replacingOccurrences(of: #"“[^”]*”"#, with: "“”", options: .regularExpression)
        let lower = text.lowercased()
        for literal in [".inc", ".ini", "f(x)"] where lower.contains(literal) { return literal }
        if let r = text.range(of: #"#[^#\s]+#"#, options: .regularExpression) { return String(text[r]) }
        // Colors written as numbers: R,G,B,A (or R,G,B).
        for pattern in [#"\b\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\b"#, #"\b\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\b"#] {
            if let r = text.range(of: pattern, options: .regularExpression) { return String(text[r]) }
        }
        // A section variable written as code ("[MeasureCPU]").
        if let r = text.range(of: #"\[[^\]\s]+\]"#, options: .regularExpression) { return String(text[r]) }
        // An option's own name ("Shape2", "MeasureName2"), or a role built from an engine term ("Widget when…").
        if let r = text.range(of: #"\b(Shape|MeasureName|InlineSetting|IfCondition)\d+\b"#, options: .regularExpression) {
            return String(text[r])
        }
        if text.hasPrefix("Widget when") { return "Widget when" }
        let words = lower.split { !($0.isLetter || $0.isNumber) }
        for w in words {
            let word = String(w)
            for banned in bannedWords where word == banned || word == banned + "s" { return word }
        }
        return nil
    }
}
