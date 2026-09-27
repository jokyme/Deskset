import Foundation

// The entries of the catalog: components, modifiers, data, functions and actions, records, enums, option controls,
// `info` fields, units, format options, permissions, features, foreign spellings, display names and the Rainmeter
// details a converted widget may keep.

// MARK: - Parameters and signatures

/// One parameter of a component, modifier, function or control.
public struct ParamSpec: Sendable, Hashable {
    /// The label written before `:`; nil for a positional parameter (`_` in the listings).
    public var label: String?
    /// The internal name (facet ids and messages use it).
    public var name: String
    public var type: DeskType
    /// Nil: "not set" when left out.
    public var defaultValue: DefaultValue?
    public var required: Bool
    /// In the dimension's canonical unit; `.item(n)` and friends start at 1.
    public var range: ClosedRange<Double>?
    public var wholeNumber: Bool
    public var variadic: Bool
    /// Tied to another parameter's dimension and display base (a Slider's `min:`/`max:` follow its value).
    public var sameAs: String?
    /// The facets this parameter sets.
    public var facets: [FacetID]
    /// Inside one call, higher wins where parameters set the same facet: side 2 > axis 1 > all 0.
    public var specificity: Int
    public var role: ParamRole
    public var source: ValueSource
    /// Goes through the widget's translations.
    public var translatable: Bool
    /// Desk text inserted by the "missing argument" fix-it (`"7"` for `Grid`'s `columns:`).
    public var previewValue: String?
    /// The unit shown after its number field (`"pt"`, `"%"`, `"s"`); nil for values without a unit.
    public var unit: String?
    public var doc: LocalizedText
    /// Component parameters only: how the parameter appears on the editor's generated page. Modifier parameters
    /// appear through their facets (`FacetSpec.page`).
    public var page: PageInfo?
    /// The Rainmeter options this parameter corresponds to (`FontSize` for `.font`'s size).
    public var rainmeter: [RainmeterMapping]

    public init(label: String?, name: String, type: DeskType, defaultValue: DefaultValue? = nil, required: Bool = false,
                range: ClosedRange<Double>? = nil, wholeNumber: Bool = false, variadic: Bool = false,
                sameAs: String? = nil, facets: [FacetID] = [], specificity: Int = 0, role: ParamRole = .plain,
                source: ValueSource = .any, translatable: Bool = false, previewValue: String? = nil,
                unit: String? = nil, doc: LocalizedText, page: PageInfo? = nil, rainmeter: [RainmeterMapping] = []) {
        self.label = label
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.required = required
        self.range = range
        self.wholeNumber = wholeNumber
        self.variadic = variadic
        self.sameAs = sameAs
        self.facets = facets
        self.specificity = specificity
        self.role = role
        self.source = source
        self.translatable = translatable
        self.previewValue = previewValue
        self.unit = unit
        self.doc = doc
        self.page = page
        self.rainmeter = rainmeter
    }

    public var isPositional: Bool { label == nil }
    /// True for a positional parameter that may be left out.
    public var isOptionalPositional: Bool { label == nil && !required }
}

/// One way to call something: its parameters in order, its result, and the release that added it.
public struct Signature: Sendable, Hashable {
    public var params: [ParamSpec]
    public var result: ResultRule?
    public var since: AppVersion

    public init(params: [ParamSpec], result: ResultRule? = nil, since: AppVersion = .deskFirstRelease) {
        self.params = params
        self.result = result
        self.since = since
    }

    public func param(labelled label: String) -> ParamSpec? { params.first { $0.label == label } }
    public func param(named name: String) -> ParamSpec? { params.first { $0.name == name } }
}

// MARK: - Components

/// The library's sections.
public enum ComponentGroup: String, Sendable, Hashable, CaseIterable {
    case containers, content, shapes, controls, menuEntries
}

public struct ComponentSpec: Sendable, Hashable {
    public var name: String
    public var kind: ElementKind
    public var group: ComponentGroup
    /// How the library and the layers list name it ("Progress bar" / "进度条").
    public var title: LocalizedText
    public var signatures: [Signature]
    public var block: BlockKind
    /// Nil: any view container. Menu entries list the menus they may be in.
    public var allowedParents: ElementKindSet?
    /// Facet defaults that differ from the general ones, as Desk text (`"color": ".accent"`).
    public var defaults: [FacetID: String]
    public var sizing: SizingDefaults
    public var backing: BackingKind
    /// Sample data for the fit check and thumbnails.
    public var previewValue: String?
    public var doc: Doc

    public init(name: String, kind: ElementKind, group: ComponentGroup, title: LocalizedText, signatures: [Signature],
                block: BlockKind, allowedParents: ElementKindSet? = nil, defaults: [FacetID: String] = [:],
                sizing: SizingDefaults, backing: BackingKind = .content, previewValue: String? = nil, doc: Doc) {
        self.name = name
        self.kind = kind
        self.group = group
        self.title = title
        self.signatures = signatures
        self.block = block
        self.allowedParents = allowedParents
        self.defaults = defaults
        self.sizing = sizing
        self.backing = backing
        self.previewValue = previewValue
        self.doc = doc
    }
}

// MARK: - Modifiers

/// The groups of the modifier listings.
public enum ModifierGroup: String, Sendable, Hashable, CaseIterable {
    case sizeAndPosition, appearance, shapesAndMeters, text, picturesAndIcons, transforms, statesAndAnimation,
         interaction, timing, reuse
}

public struct ModifierSpec: Sendable, Hashable {
    public var name: String
    public var group: ModifierGroup
    /// A short name for menus and help ("Padding" / "内边距").
    public var title: LocalizedText
    public var signatures: [Signature]
    public var appliesTo: ElementKindSet
    public var context: ModifierContext
    public var boxLayer: BoxLayer
    /// Every facet it may set; each parameter says which it sets.
    public var facets: [FacetID]
    /// What a modifier without parameters sets: `.bold()` → `font.weight = .bold`.
    public var fixedValues: [FacetID: String]
    /// Its presets set facets softly, so a hard value beats them.
    public var softFacets: Bool
    /// Passed on from containers to `Text`, `Label` and `Icon`.
    public var inheritable: Bool
    public var allowedInStyle: Bool
    /// Allowed inside `.hover { }` and `.pressed { }`.
    public var allowedInState: Bool
    /// Takes `if:`.
    public var acceptsCondition: Bool
    public var repeatable: Repeatable
    public var block: BlockKind
    public var event: EventSpec?
    public var timing: TimingSpec?
    public var inspectorCard: InspectorCard
    /// Where the editor inserts it among an element's modifiers (lower first).
    public var sortKey: Int
    public var doc: Doc

    public init(name: String, group: ModifierGroup, title: LocalizedText, signatures: [Signature],
                appliesTo: ElementKindSet, context: ModifierContext = .view, boxLayer: BoxLayer = .none,
                facets: [FacetID] = [], fixedValues: [FacetID: String] = [:], softFacets: Bool = false,
                inheritable: Bool = false, allowedInStyle: Bool, allowedInState: Bool, acceptsCondition: Bool,
                repeatable: Repeatable = .no, block: BlockKind = .none, event: EventSpec? = nil,
                timing: TimingSpec? = nil, inspectorCard: InspectorCard, sortKey: Int, doc: Doc) {
        self.name = name
        self.group = group
        self.title = title
        self.signatures = signatures
        self.appliesTo = appliesTo
        self.context = context
        self.boxLayer = boxLayer
        self.facets = facets
        self.fixedValues = fixedValues
        self.softFacets = softFacets
        self.inheritable = inheritable
        self.allowedInStyle = allowedInStyle
        self.allowedInState = allowedInState
        self.acceptsCondition = acceptsCondition
        self.repeatable = repeatable
        self.block = block
        self.event = event
        self.timing = timing
        self.inspectorCard = inspectorCard
        self.sortKey = sortKey
        self.doc = doc
    }
}

/// One property an element has, as the editor's pages show it and as messages name it.
public struct FacetSpec: Sendable, Hashable {
    public var id: FacetID
    public var valueType: DeskType
    /// How messages name it, as a phrase that fits in a sentence ("the text size" / "字号").
    public var displayName: LocalizedText
    /// Passed on from containers (`.font`, `.color`, `.digits`, `.align`).
    public var inheritable: Bool
    public var page: PageInfo
    public var unit: String?
    public var range: ClosedRange<Double>?
    public var rainmeter: [RainmeterMapping]

    public init(id: FacetID, valueType: DeskType, displayName: LocalizedText, inheritable: Bool = false,
                page: PageInfo, unit: String? = nil, range: ClosedRange<Double>? = nil,
                rainmeter: [RainmeterMapping] = []) {
        self.id = id
        self.valueType = valueType
        self.displayName = displayName
        self.inheritable = inheritable
        self.page = page
        self.unit = unit
        self.range = range
        self.rainmeter = rainmeter
    }
}

// MARK: - Data, functions and actions

public struct MemberSpec: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case field, function, action
    }

    public var name: String
    public var kind: Kind
    /// How pickers and layer names call it ("CPU usage" / "处理器占用率").
    public var title: LocalizedText
    /// For functions and actions.
    public var signatures: [Signature]
    /// The result type (for actions, nothing is returned: `.any`).
    public var type: DeskType
    public var range: RangeSpec
    public var maxCount: MaxCount?
    /// 1000 or 1024 for bytes.
    public var displayBase: Int?
    public var defaultFormat: FormatDefault?
    public var cadence: Cadence
    /// Initializers and on-demand reads get the current value at once.
    public var readsSynchronously: Bool
    /// A permission this member itself needs (beyond its namespace's).
    public var permission: String?
    /// May be assigned (`volume.level`, `volume.muted`, `music.position`).
    public var settable: Bool
    /// What to write instead of assigning it (`music.playing` → `music.play()`).
    public var settableTwin: String?
    /// Only from the user's own clicks and menu items.
    public var userInitiatedOnly: Bool
    public var lowering: DataLowering
    /// A long, realistic sample for thumbnails and the fit check (Desk text).
    public var previewValue: String?
    public var doc: Doc

    public init(name: String, kind: Kind = .field, title: LocalizedText, signatures: [Signature] = [],
                type: DeskType, range: RangeSpec = .none, maxCount: MaxCount? = nil, displayBase: Int? = nil,
                defaultFormat: FormatDefault? = nil, cadence: Cadence, readsSynchronously: Bool = false,
                permission: String? = nil, settable: Bool = false, settableTwin: String? = nil,
                userInitiatedOnly: Bool = false, lowering: DataLowering, previewValue: String? = nil, doc: Doc) {
        self.name = name
        self.kind = kind
        self.title = title
        self.signatures = signatures
        self.type = type
        self.range = range
        self.maxCount = maxCount
        self.displayBase = displayBase
        self.defaultFormat = defaultFormat
        self.cadence = cadence
        self.readsSynchronously = readsSynchronously
        self.permission = permission
        self.settable = settable
        self.settableTwin = settableTwin
        self.userInitiatedOnly = userInitiatedOnly
        self.lowering = lowering
        self.previewValue = previewValue
        self.doc = doc
    }
}

/// A data or action namespace (`cpu`, `music`, `weather`) with all its members.
public struct NamespaceSpec: Sendable, Hashable {
    /// `"cpu"`; nested namespaces are written with a dot (`"audio.microphone"`).
    public var name: String
    public var title: LocalizedText
    /// The namespace used as a value itself (`uptime`, `disks`): its type, range, cadence and lowering.
    public var value: MemberSpec?
    /// The record this namespace is the automatic-location instance of (`weather` is a `Weather`).
    public var instanceOf: String?
    /// What reading the namespace's own data needs (`weather` needs `.location`); records returned by its
    /// functions (`weather.at(…)`) do not inherit it.
    public var permission: String?
    /// The member a bare use of the namespace most likely meant (`cpu` → `cpu.usage`).
    public var mainMember: String?
    /// Members come from the file (the `options` namespace).
    public var dynamicMembers: Bool
    public var members: [MemberSpec]
    public var doc: Doc

    public init(name: String, title: LocalizedText, value: MemberSpec? = nil, instanceOf: String? = nil,
                permission: String? = nil, mainMember: String? = nil, dynamicMembers: Bool = false,
                members: [MemberSpec], doc: Doc) {
        self.name = name
        self.title = title
        self.value = value
        self.instanceOf = instanceOf
        self.permission = permission
        self.mainMember = mainMember
        self.dynamicMembers = dynamicMembers
        self.members = members
        self.doc = doc
    }

    /// Non-nil when the namespace is itself a value.
    public var valueType: DeskType? { value?.type }

    public func member(named name: String) -> MemberSpec? { members.first { $0.name == name } }
}

/// A global function or action (`round`, `open`, `after`).
public struct FunctionSpec: Sendable, Hashable {
    public var name: String
    public var kind: MemberSpec.Kind
    public var title: LocalizedText
    public var signatures: [Signature]
    public var permission: String?
    public var userInitiatedOnly: Bool
    /// `after(…) { }`.
    public var takesActionBlock: Bool
    /// No side effects.
    public var pure: Bool
    /// Only in actions (and `variable` initializers, for `random`).
    public var onlyInActions: Bool
    /// The action to use when it is written as a statement (`command` → `run`).
    public var actionTwin: String?
    /// For the functions that read data (`files(…)`, `folder(…)`, `command(…)`): the data's facts — result, range,
    /// cadence, lowering. They count as data names, like the namespaces.
    public var data: MemberSpec?
    public var doc: Doc

    public init(name: String, kind: MemberSpec.Kind, title: LocalizedText, signatures: [Signature],
                permission: String? = nil, userInitiatedOnly: Bool = false, takesActionBlock: Bool = false,
                pure: Bool, onlyInActions: Bool = false, actionTwin: String? = nil, data: MemberSpec? = nil,
                doc: Doc) {
        self.name = name
        self.kind = kind
        self.title = title
        self.signatures = signatures
        self.permission = permission
        self.userInitiatedOnly = userInitiatedOnly
        self.takesActionBlock = takesActionBlock
        self.pure = pure
        self.onlyInActions = onlyInActions
        self.actionTwin = actionTwin
        self.data = data
        self.doc = doc
    }
}

/// The members of a built-in value type: every value (`"Any"`), `"String"`, `"List"`, `"Date"`, `"Color"`,
/// `"Json"`. Records list their own fields.
public struct TypeMembersSpec: Sendable, Hashable {
    public var type: String
    public var members: [MemberSpec]
    public init(type: String, members: [MemberSpec]) {
        self.type = type
        self.members = members
    }
}

/// A data record (`MonthGrid`, `DayCell`, `Weather`).
public struct RecordSpec: Sendable, Hashable {
    public var id: String
    public var fields: [MemberSpec]
    /// The field that identifies an item across updates (`DayCell.date`); nil: by position.
    public var identityField: String?
    public var doc: Doc

    public init(id: String, fields: [MemberSpec], identityField: String? = nil, doc: Doc) {
        self.id = id
        self.fields = fields
        self.identityField = identityField
        self.doc = doc
    }

    public func field(named name: String) -> MemberSpec? { fields.first { $0.name == name } }
}

// MARK: - Enums and named values

public struct EnumSpec: Sendable, Hashable {
    public var id: String
    public var cases: [EnumCaseSpec]
    public var doc: Doc

    public init(id: String, cases: [EnumCaseSpec], doc: Doc) {
        self.id = id
        self.cases = cases
        self.doc = doc
    }

    public func enumCase(named name: String) -> EnumCaseSpec? { cases.first { $0.name == name } }
}

public struct EnumCaseSpec: Sendable, Hashable {
    public var name: String
    /// How pickers and text show it.
    public var title: LocalizedText?
    /// How other languages and older drafts write it (`.leading` for `.left`).
    public var foreignSpellings: [String]
    /// Synonyms (`blur`, `frosted` for `.glass`).
    public var keywords: [String]
    /// What a preset sets (`.headline`: size 15, weight semibold, softly).
    public var facetValues: [FacetID: FacetValue]
    public var rank: Int
    public var since: AppVersion
    /// Older systems do nothing for it (symbol effects).
    public var minimumMacOS: Int?

    public init(name: String, title: LocalizedText?, foreignSpellings: [String] = [], keywords: [String] = [],
                facetValues: [FacetID: FacetValue] = [:], rank: Int = 50, since: AppVersion = .deskFirstRelease,
                minimumMacOS: Int? = nil) {
        self.name = name
        self.title = title
        self.foreignSpellings = foreignSpellings
        self.keywords = keywords
        self.facetValues = facetValues
        self.rank = rank
        self.since = since
        self.minimumMacOS = minimumMacOS
    }
}

/// A named value of a type that is not an enum: the colors (`.red`, `.text`) and paints (`.glass`).
public struct NamedValueSpec: Sendable, Hashable {
    /// The qualifier: `"Color"` or `"Paint"` (`Color.text`, `Paint.glass`).
    public var type: String
    public var name: String
    public var title: LocalizedText
    public var keywords: [String]
    public var rank: Int
    public var doc: Doc

    public init(type: String, name: String, title: LocalizedText, keywords: [String] = [], rank: Int = 50, doc: Doc) {
        self.type = type
        self.name = name
        self.title = title
        self.keywords = keywords
        self.rank = rank
        self.doc = doc
    }
}

// MARK: - Options, info, units, formats

/// A control of the Options panel (`Picker`, `Toggle`…).
public struct ControlSpec: Sendable, Hashable {
    public var name: String
    public var title: LocalizedText
    public var signatures: [Signature]
    public var valueType: ControlValueType
    public var panel: PanelControl
    /// `Section { … }` holds option items.
    public var block: BlockKind
    public var doc: Doc

    public init(name: String, title: LocalizedText, signatures: [Signature], valueType: ControlValueType,
                panel: PanelControl, block: BlockKind = .none, doc: Doc) {
        self.name = name
        self.title = title
        self.signatures = signatures
        self.valueType = valueType
        self.panel = panel
        self.block = block
        self.doc = doc
    }
}

/// A field of `info { }` or `package { }`.
public struct FieldSpec: Sendable, Hashable {
    public var name: String
    public var type: DeskType
    public var defaultValue: DefaultValue?
    public var inInfo: Bool
    public var inPackage: Bool
    public var translatable: Bool
    public var range: ClosedRange<Double>?
    public var source: ValueSource
    public var doc: Doc

    public init(name: String, type: DeskType, defaultValue: DefaultValue?, inInfo: Bool = true, inPackage: Bool = false,
                translatable: Bool = false, range: ClosedRange<Double>? = nil, source: ValueSource = .literal,
                doc: Doc) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.inInfo = inInfo
        self.inPackage = inPackage
        self.translatable = translatable
        self.range = range
        self.source = source
        self.doc = doc
    }
}

/// A unit written right after a number (`2s`, `50%`, `2GB`).
public struct UnitSpec: Sendable, Hashable {
    public var spelling: String
    public var dimension: Dimension
    /// value × factor + offset = the value in the dimension's canonical unit. For `KB`…`TB` the factor is for a
    /// base of 1000; see `basePower`.
    public var factor: Double
    public var offset: Double
    /// `KB`, `MB`, `GB`, `TB` (and their `/s` forms) take the display base settled for their expression.
    public var adoptsBase: Bool
    /// For units that adopt a base: the power of the base (KB 1, MB 2…).
    public var basePower: Int?

    public init(spelling: String, dimension: Dimension, factor: Double, offset: Double = 0, adoptsBase: Bool = false,
                basePower: Int? = nil) {
        self.spelling = spelling
        self.dimension = dimension
        self.factor = factor
        self.offset = offset
        self.adoptsBase = adoptsBase
        self.basePower = basePower
    }

    /// The factor for a display base of 1000 or 1024 (units that do not adopt a base ignore it).
    public func factor(base: Int) -> Double {
        guard adoptsBase, let basePower else { return factor }
        return pow(Double(base), Double(basePower))
    }
}

/// A unit spelling Desk recognises only to report it (`px`, `em`, `sec`, `Mbps`).
public struct UnitMisspellingSpec: Sendable, Hashable {
    public var spelling: String
    public var diagnostic: DiagnosticID
    /// Replacements, the likelier first (`kb` → `KB`; `mb` → `MB`, or `mbar` next to pressure).
    public var suggestions: [String]
    /// The dimension the value keeps for recovery (`18px` is still 18 points).
    public var dimension: Dimension?
    public var note: LocalizedText?

    public init(spelling: String, diagnostic: DiagnosticID, suggestions: [String] = [], dimension: Dimension? = nil,
                note: LocalizedText? = nil) {
        self.spelling = spelling
        self.diagnostic = diagnostic
        self.suggestions = suggestions
        self.dimension = dimension
        self.note = note
    }
}

/// A format option of `"{value, option: …}"`.
public struct FormatOptionSpec: Sendable, Hashable {
    public var label: String
    /// The value types it applies to (`.any` for every value).
    public var appliesTo: [DeskType]
    public var type: DeskType
    public var range: ClosedRange<Double>?
    public var doc: Doc

    public init(label: String, appliesTo: [DeskType], type: DeskType, range: ClosedRange<Double>? = nil, doc: Doc) {
        self.label = label
        self.appliesTo = appliesTo
        self.type = type
        self.range = range
        self.doc = doc
    }
}

// MARK: - Permissions, features, security

public struct PermissionSpec: Sendable, Hashable {
    /// `"music"`, written `.music` in `info { permissions: [.music] }`.
    public var id: String
    /// The macOS prompt it leads to, if any.
    public var systemPrompt: String?
    /// What the widget does, completing "This widget …" / "这个组件要……".
    public var needsPhrase: LocalizedText
    /// The data and actions that need it (`"music.*"`, `"calendar.events"`).
    public var neededBy: [String]
    public var doc: Doc

    public init(id: String, systemPrompt: String?, needsPhrase: LocalizedText, neededBy: [String], doc: Doc) {
        self.id = id
        self.systemPrompt = systemPrompt
        self.needsPhrase = needsPhrase
        self.neededBy = neededBy
        self.doc = doc
    }
}

/// Something `supports(…)` can ask about.
public struct FeatureSpec: Sendable, Hashable {
    public var id: String
    /// When it is true.
    public var availability: String
    public var minimumMacOS: Int?
    /// What happens where it is false.
    public var fallback: LocalizedText
    public var doc: Doc

    public init(id: String, availability: String, minimumMacOS: Int? = nil, fallback: LocalizedText, doc: Doc) {
        self.id = id
        self.availability = availability
        self.minimumMacOS = minimumMacOS
        self.fallback = fallback
        self.doc = doc
    }
}

/// A Rainmeter detail a converted widget may keep with `.rainmeter(option, value)`, drawn by Deskset's renderer as
/// it is for the converted skin.
public struct CompatDetailSpec: Sendable, Hashable {
    public var key: String
    /// A meter type for element details, `.skin` for `[Rainmeter]` ones (which go on the outermost element).
    public var owner: RainmeterMapping.Owner
    public var appliesTo: ElementKindSet
    /// How its value is checked.
    public var type: DeskType
    /// The typed property the renderer reads.
    public var prop: String
    public var since: AppVersion

    public init(key: String, owner: RainmeterMapping.Owner, appliesTo: ElementKindSet, type: DeskType, prop: String,
                since: AppVersion = .deskFirstRelease) {
        self.key = key
        self.owner = owner
        self.appliesTo = appliesTo
        self.type = type
        self.prop = prop
        self.since = since
    }
}

/// A command that runs one of its arguments as code (`sh -c`, `osascript -e`): an option value placed there would
/// be read as code a second time.
public struct RereadSpec: Sendable, Hashable {
    public var command: String
    /// The flag before the code argument; nil: every argument is code (`eval`, `ssh`).
    public var codeFlag: String?

    public init(command: String, codeFlag: String?) {
        self.command = command
        self.codeFlag = codeFlag
    }
}

// MARK: - Display names

/// How messages name a type, dimension, facet, component, preset or grammar slot, in both languages, never with
/// an id: `"type:bool"` → "yes or no (`true` or `false`)".
public struct DisplayNameSpec: Sendable, Hashable {
    public var id: String
    public var name: LocalizedText
    /// For types: the plural used after "a list of" ("days of a month").
    public var plural: LocalizedText?

    public init(id: String, name: LocalizedText, plural: LocalizedText? = nil) {
        self.id = id
        self.name = name
        self.plural = plural
    }
}

// MARK: - Foreign spellings

/// A spelling from another language or framework that Desk recognises and answers with its own.
public struct ForeignSpec: Sendable, Hashable {
    public enum Family: String, Sendable, Hashable, CaseIterable {
        case swiftUI, swift, javaScript, reactNative, flutter, html, css, rainmeter, olderDesk, other
    }

    public var family: Family
    public var pattern: ForeignPattern
    public var context: ForeignContext
    /// The Desk spelling, as a replacement template (`{0}` stands for the first argument) or, when not exact, the
    /// Desk pattern to show.
    public var deskText: String
    public var diagnostic: DiagnosticID
    public var severity: Severity
    /// True: offered as a fix-it; false: shown in the message only.
    public var exact: Bool

    public init(family: Family, pattern: ForeignPattern, context: ForeignContext = .any, deskText: String,
                diagnostic: DiagnosticID, severity: Severity = .error, exact: Bool) {
        self.family = family
        self.pattern = pattern
        self.context = context
        self.deskText = deskText
        self.diagnostic = diagnostic
        self.severity = severity
        self.exact = exact
    }
}

/// What a foreign row matches.
public enum ForeignPattern: Sendable, Hashable {
    /// A name used as a component or value: `VStack`, `self`.
    case name(String)
    /// A modifier: `.foregroundColor(…)`.
    case modifier(String)
    /// A modifier with this argument label or leading implicit member: `.frame(maxWidth:)`, `.padding(.horizontal, …)`.
    case modifierWithArgument(String, argument: String)
    /// A call with this argument label: `Image(systemName:)`.
    case call(String, label: String)
    /// A member or a member path: `music.artwork`, `toggle()`.
    case member(String)
    /// An implicit member: `.leading`, `.secondary`.
    case implicitMember(String)
    /// An argument label: `alignment:`.
    case label(String)
    /// A token: `&&`, `$`.
    case token(String)
    /// A statement-start keyword pattern: `let`, `struct`.
    case keyword(String)
    /// A whole line (INI, HTML, CSS), as a regular expression.
    case line(regex: String)
    /// A Rainmeter option name in `Key=Value`.
    case iniKey(String)
    /// A Rainmeter bang.
    case bang(String)

    /// The text the pattern matches, for lookups (`"VStack"`, `".foregroundColor"`, `"&&"`).
    public var key: String {
        switch self {
        case .name(let s), .member(let s), .token(let s), .keyword(let s), .iniKey(let s): return s
        case .modifier(let s), .modifierWithArgument(let s, _): return "." + s
        case .call(let s, _): return s
        case .implicitMember(let s): return "." + s
        case .label(let s): return s + ":"
        case .line(let regex): return regex
        case .bang(let s): return s
        }
    }
}

/// Where a foreign row applies.
public enum ForeignContext: String, Sendable, Hashable {
    case any
    /// On an element placed with `.position` in a `Freeform` (`StringAlign` becomes the anchor there).
    case positionedInFreeform
    /// On an element (not an option control): `.help(…)` on a view means a tooltip.
    case onElement
    /// Inside a string.
    case inText
}

// MARK: - Paths

/// Identifies one built-in name of the catalog, for what a name resolved to.
public enum CatalogPath: Sendable, Hashable {
    case component(String)
    case modifier(String)
    case namespace(String)
    case member(namespace: String, name: String)
    case recordField(record: String, name: String)
    /// A member of a built-in value type (`"String"`, `"List"`…).
    case typeMember(type: String, name: String)
    case function(String)
    case control(String)
    case enumCase(type: String, name: String)
    case namedValue(type: String, name: String)
    case infoField(String)
    case packageField(String)
    case formatOption(String)
    case permission(String)
    case feature(String)
}

extension CatalogPath: CustomStringConvertible {
    public var description: String {
        switch self {
        case .component(let n), .function(let n), .control(let n), .namespace(let n): return n
        case .modifier(let n): return "." + n
        case .member(let ns, let n): return "\(ns).\(n)"
        case .recordField(let r, let n), .typeMember(let r, let n): return "\(r).\(n)"
        case .enumCase(let t, let n), .namedValue(let t, let n): return "\(t).\(n)"
        case .infoField(let n): return "info.\(n)"
        case .packageField(let n): return "package.\(n)"
        case .formatOption(let n): return n + ":"
        case .permission(let n), .feature(let n): return "." + n
        }
    }
}
