import Foundation

// The small types the catalog is written in: dimensions and types of values, element kinds, block kinds, how data
// is sampled and lowered, and the fields the editor's generated pages read.

// MARK: - Values

/// What a number measures. Lengths are points, times seconds, temperatures °C, angles degrees, speeds metres per
/// second, rainfall millimetres, pressure hectopascals; `bytes` and `bytesPerSecond` also carry a display base
/// (1000 or 1024) where the value is known.
public enum Dimension: String, Sendable, Hashable, CaseIterable {
    case plain, length, time, percent, bytes, bytesPerSecond, temperature, temperatureDelta, power, frequency,
         angle, rpm, voltage, current, speed, rainfall, pressure

    /// The unit a plain literal adopts, and the one shown after a number field ("pt", "%", "s").
    public var canonicalUnit: String? {
        switch self {
        case .plain: return nil
        case .length: return "pt"
        case .time: return "s"
        case .percent: return "%"
        case .bytes: return "B"
        case .bytesPerSecond: return "B/s"
        case .temperature, .temperatureDelta: return "°C"
        case .power: return "W"
        case .frequency: return "Hz"
        case .angle: return "°"
        case .rpm: return "rpm"
        case .voltage: return "V"
        case .current: return "A"
        case .speed: return "m/s"
        case .rainfall: return "mm"
        case .pressure: return "hPa"
        }
    }

    /// Dimensions where people mean different units by a plain number (ms or s, °C or °F, km/h or mph): a plain
    /// literal there must say its unit.
    public var needsWrittenUnit: Bool {
        switch self {
        case .time, .temperature, .temperatureDelta, .frequency, .speed, .rainfall, .pressure: return true
        default: return false
        }
    }
}

/// The type of a value, a parameter or a data member.
public indirect enum DeskType: Sendable, Hashable {
    /// A number with a dimension: `12` (length), `50%`, `2s`, `2GB`.
    case number(Dimension)
    /// A number of any dimension; the call fixes which (`Progress`'s value and `total:`, `min`, `max`).
    case anyNumber
    /// Parameters only: a percentage, or a plain number from 0 to 1.
    case fraction
    case string, bool, color, paint, date, json, secret, size
    case symbolName, imageSource, fontFamily, folderPath
    /// A length, `.fit` or `.fill`.
    case lengthSpec
    /// A catalog enum (`Weekday`, `FontPreset`…) by its id.
    case enumeration(String)
    /// A data record (`MonthGrid`, `DayCell`…) by its id.
    case record(String)
    case list(DeskType)
    /// A control's parameter: a `variable`, a `saved` value, an option or settable data of this type.
    case binding(DeskType)
    /// Any of these (overloaded parameters are separate signatures instead).
    case oneOf([DeskType])
    /// A type fixed by the call (`round(x)` returns what it is given).
    case typeVar(Int)
    case styleRef, elementName, any

    // Shorthands used throughout the catalog.
    public static let plainNumber = DeskType.number(.plain)
    public static let length = DeskType.number(.length)
    public static let duration = DeskType.number(.time)
    public static let percent = DeskType.number(.percent)
    public static let angle = DeskType.number(.angle)
    public static let bytes = DeskType.number(.bytes)
    public static let rate = DeskType.number(.bytesPerSecond)
    public static let temperature = DeskType.number(.temperature)
    public static let power = DeskType.number(.power)
    public static let frequency = DeskType.number(.frequency)
    public static let rpm = DeskType.number(.rpm)
    public static let voltage = DeskType.number(.voltage)
    public static let current = DeskType.number(.current)
    public static let speed = DeskType.number(.speed)
    public static let rainfall = DeskType.number(.rainfall)
    public static let pressure = DeskType.number(.pressure)

    /// The id of the display name that describes this type in messages (`"dimension:length"`, `"enum:Weekday"`,
    /// `"record:DayCell"`, `"type:list"`); see `DeskCatalog.displayName(for:)`.
    public var displayNameID: String {
        switch self {
        case .number(let d): return "dimension:\(d.rawValue)"
        case .anyNumber: return "type:anyNumber"
        case .fraction: return "type:fraction"
        case .string: return "type:string"
        case .bool: return "type:bool"
        case .color: return "type:color"
        case .paint: return "type:paint"
        case .date: return "type:date"
        case .json: return "type:json"
        case .secret: return "type:secret"
        case .size: return "type:size"
        case .symbolName: return "type:symbolName"
        case .imageSource: return "type:imageSource"
        case .fontFamily: return "type:fontFamily"
        case .folderPath: return "type:folderPath"
        case .lengthSpec: return "type:lengthSpec"
        case .enumeration(let id): return "enum:\(id)"
        case .record(let id): return "record:\(id)"
        case .list: return "type:list"
        case .binding: return "type:binding"
        case .oneOf: return "type:oneOf"
        case .typeVar: return "type:any"
        case .styleRef: return "type:styleRef"
        case .elementName: return "type:elementName"
        case .any: return "type:any"
        }
    }

    /// Every type this one is made of, itself included (list elements, `oneOf` members, bindings).
    public var components: [DeskType] {
        switch self {
        case .list(let t), .binding(let t): return [self] + t.components
        case .oneOf(let ts): return [self] + ts.flatMap(\.components)
        default: return [self]
        }
    }
}

extension DeskType: CustomStringConvertible {
    /// As the catalog listings write types: `Length`, `Percent`, `List(DayCell)`, `Weekday`.
    public var description: String {
        switch self {
        case .number(let d):
            switch d {
            case .plain: return "Number"
            case .length: return "Length"
            case .time: return "Duration"
            case .percent: return "Percent"
            case .bytes: return "Bytes"
            case .bytesPerSecond: return "Rate"
            case .angle: return "Angle"
            default: return "Number(\(d.rawValue))"
            }
        case .anyNumber: return "Number"
        case .fraction: return "Fraction"
        case .string: return "String"
        case .bool: return "Bool"
        case .color: return "Color"
        case .paint: return "Paint"
        case .date: return "Date"
        case .json: return "Json"
        case .secret: return "Secret"
        case .size: return "Size"
        case .symbolName: return "SymbolName"
        case .imageSource: return "ImageSource"
        case .fontFamily: return "FontFamily"
        case .folderPath: return "FolderPath"
        case .lengthSpec: return "LengthSpec"
        case .enumeration(let id), .record(let id): return id
        case .list(let t): return "List(\(t))"
        case .binding(let t): return "Binding(\(t))"
        case .oneOf(let ts): return ts.map(\.description).joined(separator: " or ")
        case .typeVar(let n): return "T\(n)"
        case .styleRef: return "StyleRef"
        case .elementName: return "ElementName"
        case .any: return "Any"
        }
    }
}

/// One property an element has, such as `font.size` or `padding.top`: the modifier name, then the parameter's
/// internal name. Several modifiers may set one facet (`.bold()` and `.font(13, .bold)` both set `font.weight`).
public struct FacetID: Sendable, Hashable, Comparable, RawRepresentable, ExpressibleByStringLiteral,
                       CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (a: FacetID, b: FacetID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

// MARK: - Elements

/// The built-in kinds of element.
public enum ElementKind: String, Sendable, Hashable, CaseIterable {
    case column, row, grid, freeform, scroll, spacer, divider
    case text, label, icon, image, progress, gauge, graph
    case rectangle, circle, ellipse, capsule, line, arc, path
    case button, toggle, slider, input
    case item, menu

    var bit: UInt64 { 1 << UInt64(ElementKind.allCases.firstIndex(of: self)!) }
}

/// A set of element kinds, for "applies to" lists.
public struct ElementKindSet: OptionSet, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ kinds: [ElementKind]) { self.rawValue = kinds.reduce(0) { $0 | $1.bit } }

    public static func of(_ kinds: ElementKind...) -> ElementKindSet { ElementKindSet(kinds) }

    public static let containers = ElementKindSet([.column, .row, .grid, .freeform, .scroll])
    public static let stacks = ElementKindSet([.column, .row, .grid])
    public static let textLike = ElementKindSet([.text, .label])
    public static let shapes = ElementKindSet([.rectangle, .circle, .ellipse, .capsule, .line, .arc, .path])
    public static let meters = ElementKindSet([.progress, .gauge, .graph])
    public static let controls = ElementKindSet([.button, .toggle, .slider, .input])
    public static let menuEntries = ElementKindSet([.item, .menu, .divider])
    /// "All" in the listings: every view component except `Spacer`, and not the menu entries.
    public static let all = ElementKindSet(ElementKind.allCases.filter { ![.spacer, .item, .menu].contains($0) })
    /// Every kind, `Spacer` and menu entries included.
    public static let everything = ElementKindSet(ElementKind.allCases)

    public func contains(_ kind: ElementKind) -> Bool { rawValue & kind.bit != 0 }
    public var kinds: [ElementKind] { ElementKind.allCases.filter(contains) }
}

/// What the `{ }` after a component or modifier holds. The parser gives every block the same body; the checker
/// uses this to tell what belongs.
public enum BlockKind: Sendable, Hashable {
    case none
    case views(required: Bool)
    case menuItems(required: Bool)
    case actions(required: Bool)
    case modifiers(required: Bool)
    case optionItems
}

/// Where a modifier acts in the fixed box of every element, from the outside in.
public enum BoxLayer: String, Sendable, Hashable, CaseIterable {
    case margin, shadow, background, border, clip, padding, content, transform, none
}

/// Drawn by Deskset, or a system view (controls, glass).
public enum BackingKind: String, Sendable, Hashable {
    case content, native
}

/// The ideal size used under an unspecified proposal.
public struct IdealSize: Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A component's default width and height spec (`".fit"`, `".fill"` or a number of points) and its ideal size.
public struct SizingDefaults: Sendable, Hashable {
    public var width: String
    public var height: String
    public var idealWhenUnspecified: IdealSize?
    public init(width: String, height: String, idealWhenUnspecified: IdealSize? = nil) {
        self.width = width
        self.height = height
        self.idealWhenUnspecified = idealWhenUnspecified
    }
}

// MARK: - Parameters

/// What a parameter is used for, beyond its type: it decides conversions (only display parameters turn values into
/// text), security rules (web addresses and commands) and write-back.
public enum ParamRole: String, Sendable, Hashable {
    case plain
    /// Text people read: any displayable value is formatted.
    case display
    /// A regular expression.
    case pattern
    /// A date pattern such as `"HH:mm"`.
    case datePattern
    /// A command run by the shell; options reach it as separate arguments.
    case command
    case webAddress
    case folderPath
    /// A named place or `"latitude,longitude"`.
    case place
    /// Refers to a named element: `show(details)`.
    case elementName
    /// Names the element it is written on: `.name(title)`.
    case declaresElementName
    /// One of the author's styles.
    case styleRef
    /// The condition of `if:`.
    case condition
    /// SVG path data.
    case pathData
}

/// Where a parameter's value may come from (the rule that keeps live data out of background requests).
public enum ValueSource: String, Sendable, Hashable {
    case any
    /// Written out in the file.
    case literal
    /// Written out, an option, or text whose interpolations are only options.
    case literalOrOption
}

/// Defaults that are not Desk text.
public enum SystemDefault: String, Sendable, Hashable {
    /// The first day of the week in the Mac's settings.
    case weekStart
    case today
    case systemFont
    /// The user's accent color.
    case accent
    /// km/h or mph, by the region.
    case regionSpeedUnit
    /// The file's name, without `.desk`.
    case fileName
    /// A Picker's first choice.
    case firstChoice
    /// The lowest / highest value of a control's binding, from the catalog's range.
    case bindingMinimum, bindingMaximum
    /// Each data member's own refresh cadence.
    case perData
}

/// A parameter's or field's default.
public enum DefaultValue: Sendable, Hashable {
    /// Desk text: `"8"`, `".center"`.
    case source(String)
    case system(SystemDefault)
    /// The value of another parameter of the same call (`rowSpacing:` = `spacing:`, a Slider's `default:` = `min:`).
    case parameter(String)
}

/// The result type of a function or member whose result depends on its arguments.
public enum ResultRule: Sendable, Hashable {
    case fixed(DeskType)
    /// The type and dimension of that argument (`round(x)`, `abs(x)`).
    case sameAs(param: String)
    /// The common dimension of these arguments (`min`, `max`, `clamp`).
    case commonOf([String])
    /// The receiver's type (`.ifMissing(f)`).
    case receiver
    /// A list's element type (`.item(n)`, `.first`, `.last`).
    case elementOf(receiver: Bool)
}

/// Whether a modifier may be written more than once on one element.
public enum Repeatable: Sendable, Hashable {
    case no
    /// Once per value of this positional argument, plus once without it (`.onScroll`, `.onScroll(.up)`…).
    case perArgument(Int)
    case yes
}

/// Where a modifier is used: on elements, on option controls, or both (`.hidden`).
public enum ModifierContext: String, Sendable, Hashable {
    case view, option, both
}

/// An event modifier: the runtime event it maps to, whether it counts as the user's own action (which allows
/// `open`, `copy`, `run` and `trash.empty`), and the record `event` holds in its block.
public struct EventSpec: Sendable, Hashable {
    public var runtimeEvent: String
    public var userInitiated: Bool
    public var eventRecord: String?
    public init(runtimeEvent: String, userInitiated: Bool, eventRecord: String? = nil) {
        self.runtimeEvent = runtimeEvent
        self.userInitiated = userInitiated
        self.eventRecord = eventRecord
    }
}

/// A timing modifier.
public enum TimingSpec: Sendable, Hashable {
    case every(minimumSeconds: Double)
    case when, onChange, onLoad, onWake
}

/// The card (and the section of the generated page) a modifier or parameter belongs to.
public enum InspectorCard: String, Sendable, Hashable, CaseIterable {
    case content, text, appearance, layout, interaction
}

// MARK: - Data

/// The range of a data member: fixed, up to another member (`memory.used` goes to `memory.total`), the largest value
/// seen so far (network speeds), or none.
public enum RangeSpec: Sendable, Hashable {
    case none
    case fixed(ClosedRange<Double>)
    case member(String)
    case observed
}

/// How many items a data list can hold at most (for the element-count estimate).
public enum MaxCount: Sendable, Hashable {
    case fixed(Int)
    /// As many as this argument allows (`files(…, limit:)`).
    case argument(String)
}

/// How a data member is formatted in text when no format is written.
public enum FormatDefault: Sendable, Hashable {
    /// A preset such as `.full`, `.clock`, `.time`.
    case style(String)
    /// A date pattern.
    case pattern(String)
}

/// How often a data member updates.
public enum Cadence: Sendable, Hashable {
    /// Every so many seconds, aligned to whole seconds.
    case periodic(seconds: Double)
    /// At the precision shown (minutes or seconds).
    case clock
    /// When the system reports a change.
    case event
    /// When the system reports a change, and at least every so many seconds.
    case eventAndPeriodic(seconds: Double)
    /// Every display frame while visible.
    case frame
    /// Deskset's shared service decides (weather).
    case service
    /// Read once.
    case once
    /// Set by an argument of the call (`web.json(…, every:)`), with its default in seconds.
    case argument(label: String, default: Double)
    /// A field of a record: it updates with the data the record comes from.
    case ofRecord
}

/// One option of the kernel a data member lowers to.
public enum OptionTemplate: Sendable, Hashable {
    case literal(String)
    /// The value of this argument (`"_"` for the first positional one): `cpu.core(n)` → `Processor=n`.
    case argument(label: String)
    /// Text with `{label}` placeholders for arguments: `"Sensor={key}"`.
    case format(String)
}

/// The kernel that produces a data member at run time: an engine measure type with synthesized options, a native
/// kernel, or a Desk expression over other data.
public enum DataLowering: Sendable, Hashable {
    case measure(type: String, options: [String: OptionTemplate], field: String?)
    case native(kernel: String, options: [String: OptionTemplate], field: String?)
    case derived(String)
    /// A field of the record value it is read from.
    case recordField(String)
    /// Not data: an action carried out by the widget or the namespace's kernel.
    case action(String)
}

// MARK: - Options panel

/// How an option control appears in the Options panel.
public enum PanelControl: String, Sendable, Hashable {
    case segmentedOrMenu, toggle, slider, stepper, textField, secureField, colorWell, fontMenu, imageChooser,
         folderChooser, datePicker, section, choice
}

/// The value type of an option control.
public enum ControlValueType: Sendable, Hashable {
    case fixed(DeskType)
    /// A Picker: from its choices.
    case fromChoices
    /// A Slider or Stepper: the dimension of this parameter (`min:`), settled by use when it is plain.
    case dimensionOf(param: String)
    /// Not a value (`Section`, `Choice`).
    case none
}

// MARK: - Presets

/// What a preset case sets, softly or not: `.headline` sets the size 15 and the weight semibold softly, so a
/// `.bold()` next to it wins.
public struct FacetValue: Sendable, Hashable {
    public var value: String
    public var soft: Bool
    public init(_ value: String, soft: Bool = true) {
        self.value = value
        self.soft = soft
    }
}

/// A name that is being replaced.
public struct Deprecation: Sendable, Hashable {
    public var since: AppVersion
    public var replacement: String
    public init(since: AppVersion, replacement: String) {
        self.since = since
        self.replacement = replacement
    }
}

// MARK: - Generated pages

/// The control a row of the editor's generated page uses. Only a few shapes exist: text and token fields, pop-up
/// menus, segmented controls (up to four choices), switches, number fields and color wells, plus the controls that
/// let people pick by the result (examples and thumbnails). Sliders are used for opacity only.
public enum PageControl: String, Sendable, Hashable, CaseIterable {
    case textField
    /// The data a part shows ("Choose data… ▾").
    case dataPicker
    case numberField
    case toggle
    case segmented
    case popup
    /// A pop-up menu whose items are shown in their own font.
    case fontMenu
    /// An SF Symbol name, with the symbol browser.
    case symbolPicker
    /// A picture from the widget's folder.
    case imagePicker
    case colorWell
    /// Four numbers, one per side.
    case insets
    /// The nine positions of a box.
    case alignmentGrid
    /// Only for opacity.
    case slider
    /// Rendered format examples ("21% · 21.4% · 0.21").
    case examples
    /// "Show as" thumbnails (progress bar · ring · graph · number).
    case showAsThumbnails
    /// Thumbnails of the author's styles.
    case styleThumbnails
    /// What happens on a click, in words, with an editor for the actions.
    case actionSummary
}

/// Where a row appears: always on the default page, or only under "All settings".
public enum PageLevel: String, Sendable, Hashable {
    case essential, more
}

/// A value offered next to a control: a number, a choice, a color.
public struct PagePreset: Sendable, Hashable {
    /// Desk text written when the preset is picked (`"13"`, `".semibold"`, `".uppercase()"`).
    public var value: String
    public var label: LocalizedText
    public init(_ value: String, _ label: LocalizedText) {
        self.value = value
        self.label = label
    }
}

/// How a facet or parameter appears on the editor's generated pages: its section, its label in both languages, the
/// control, presets, how prominent it is, and a long sample value for previews and fit checks.
public struct PageInfo: Sendable, Hashable {
    public var section: InspectorCard
    public var label: LocalizedText
    public var control: PageControl
    public var presets: [PagePreset]
    public var level: PageLevel
    /// Desk text of a long, realistic value (the longest text people are likely to see), or nil.
    public var longSample: String?

    public init(section: InspectorCard, label: LocalizedText, control: PageControl, presets: [PagePreset] = [],
                level: PageLevel, longSample: String? = nil) {
        self.section = section
        self.label = label
        self.control = control
        self.presets = presets
        self.level = level
        self.longSample = longSample
    }
}

// MARK: - Examples

/// The parent an example is placed in by the example harness.
public enum ParentKind: String, Sendable, Hashable {
    case column, row, freeform, grid, menu, options, section
}

/// Where the example harness puts an example.
public enum ExamplePlacement: String, Sendable, Hashable {
    /// A view statement in the parent (`Text("{cpu.usage}%")`).
    case view
    /// A modifier chain (`.padding(14)`) written on an element of `attachTo`, or on one the modifier applies to.
    case modifiers
    /// A declaration at the top of `widget` (`computed month = calendar.month(offset: 0)`).
    case declaration
    /// Statements inside an action block (`page = page + 1`).
    case actions
    /// A field of `info` (`name: "CPU"`).
    case infoField
    /// A field of `package`.
    case packageField
    /// An item of `options` (or of the `Section` the parent names).
    case optionItem
    /// A whole top-level item.
    case topLevel
}

/// Where the example harness puts an example, and what it needs next to it.
public struct ExampleContext: Sendable, Hashable {
    public var placement: ExamplePlacement
    /// The element a modifier example is written on (nil: one it applies to).
    public var attachTo: ElementKind?
    public var parent: ParentKind
    /// Extra Desk text placed next to the example (a named sibling for positions).
    public var siblings: [String]
    /// Extra declarations it needs.
    public var declarations: [String]
    /// The file is marked as converted (`info.convertedFrom`), for `.rainmeter(…)`.
    public var convertedFile: Bool
    /// Names the example declares itself, which replace the harness's items of the same name.
    public var replaces: [String]

    public init(placement: ExamplePlacement = .view, attachTo: ElementKind? = nil, parent: ParentKind = .column,
                siblings: [String] = [], declarations: [String] = [], convertedFile: Bool = false,
                replaces: [String] = []) {
        self.placement = placement
        self.attachTo = attachTo
        self.parent = parent
        self.siblings = siblings
        self.declarations = declarations
        self.convertedFile = convertedFile
        self.replaces = replaces
    }
}
