import Foundation

// The checker's input (the context: catalog, package, injected services, target version) and its output, the checked
// model (§4.20): diagnostics, what every name resolved to, the type of every expression, per-element facts with the
// precedence of every facet's candidates, data uses, dependencies, reactions, Freeform evaluation orders, the string
// table and the requirements. Every piece is keyed by `NodeID`, so lowering, hover, completion, the inspector and the
// edit API read the same facts.

// MARK: - Injected services

/// What a file in the widget's folder is.
public enum ResourceKind: Sendable, Hashable {
    case image(width: Int, height: Int)
    case font(families: [String])
    case other
}

/// Files in the widget's folder (pictures and fonts). Without it, file checks are skipped.
public protocol ResourceResolving: Sendable {
    /// Nil when there is no such file.
    func kind(of relativePath: String) -> ResourceKind?
    /// Files whose names are close (DK4029's suggestion).
    func similarPaths(to relativePath: String) -> [String]
    /// Pictures whose path or name starts with `prefix` (every picture for an empty one), at most `limit`, for
    /// completion. The default lists none.
    func paths(matching prefix: String, limit: Int) -> [String]
}

extension ResourceResolving {
    public func paths(matching prefix: String, limit: Int) -> [String] { [] }
}

/// The fonts of this Mac. Without it, font checks are skipped.
public protocol FontCataloging: Sendable {
    func isInstalled(family: String) -> Bool
    /// The Mac font a Windows family is shown with (DK4033), or nil when it is not a Windows font.
    func macSubstitute(forWindowsFamily family: String) -> String?
    func similarFamilies(to family: String) -> [String]
    /// Families whose name, or a word of it, starts with `prefix`, best first, at most `limit`, for completion (an
    /// empty prefix: the usual ones). Not the misspelling suggestion (`similarFamilies`). The default lists none.
    func families(matching prefix: String, limit: Int) -> [String]
}

extension FontCataloging {
    public func families(matching prefix: String, limit: Int) -> [String] { [] }
}

/// SF Symbol names. Without it, symbol checks are skipped.
public protocol SymbolValidating: Sendable {
    func exists(_ symbol: String) -> Bool
    func minimumMacOS(of symbol: String) -> Int?
    func similarSymbols(to symbol: String) -> [String]
    /// Symbol names that start with `prefix`, or have a part (between dots) that does, best first, at most `limit`,
    /// for completion. Not the misspelling suggestion (`similarSymbols`). The default lists none.
    func symbols(matching prefix: String, limit: Int) -> [String]
}

extension SymbolValidating {
    public func symbols(matching prefix: String, limit: Int) -> [String] { [] }
}

/// A font as the layout pass measures it.
public struct ResolvedFont: Sendable, Hashable {
    public var family: String
    public var size: Double
    public var weight: String
    public var design: String
    public var italic: Bool

    public init(family: String = "System", size: Double = 13, weight: String = "regular", design: String = "standard",
                italic: Bool = false) {
        self.family = family
        self.size = size
        self.weight = weight
        self.design = design
        self.italic = italic
    }
}

/// Text and picture measurement for the optional "does it fit" pass (§4.9.8). Built on the App's drawing code.
public protocol LayoutMeasuring: Sendable {
    func textSize(_ text: String, font: ResolvedFont, maxWidth: Double?, lines: Int?) -> (width: Double, height: Double)
    func imageSize(relativePath: String) -> (width: Double, height: Double)?
}

// MARK: - Context

/// What a file is checked with (§0.4, §4.20).
public struct CheckContext: Sendable {
    public var catalog: DeskCatalog
    /// `package.desk` of the folder, already checked.
    public var package: CheckedPackage?
    public var resources: ResourceResolving?
    public var fonts: FontCataloging?
    public var symbols: SymbolValidating?
    public var layout: LayoutMeasuring?
    /// The Deskset that runs the checker. A file whose `requires` is newer gets DK3023 for every name this catalog
    /// does not know (§8.5). Default: the newest release the catalog knows.
    public var appVersion: AppVersion
    /// The Deskset the file is checked against; an item whose `since` is later is DK8302 (§8.5). Default: `appVersion`.
    public var targetAppVersion: AppVersion
    /// The language messages are shown in; follows the system.
    public var messageLanguage: DiagnosticLanguage
    /// The region's measurement system: which unit DK4011 offers first for speed, rainfall and pressure.
    public var usesMetric: Bool
    /// The Mac shows temperatures in °F: DK4011 offers `°F` first.
    public var usesFahrenheit: Bool

    public init(catalog: DeskCatalog = .current, package: CheckedPackage? = nil, resources: ResourceResolving? = nil,
                fonts: FontCataloging? = nil, symbols: SymbolValidating? = nil, layout: LayoutMeasuring? = nil,
                appVersion: AppVersion? = nil, targetAppVersion: AppVersion? = nil,
                messageLanguage: DiagnosticLanguage = .english, usesMetric: Bool = true, usesFahrenheit: Bool = false) {
        self.catalog = catalog
        self.package = package
        self.resources = resources
        self.fonts = fonts
        self.symbols = symbols
        self.layout = layout
        let app = appVersion ?? catalog.newestSince
        self.appVersion = app
        self.targetAppVersion = targetAppVersion ?? app
        self.messageLanguage = messageLanguage
        self.usesMetric = usesMetric
        self.usesFahrenheit = usesFahrenheit
    }
}

// MARK: - Checked model

/// What a name, member or implicit member resolved to.
public enum Symbol: Sendable, Hashable {
    case declaration(NodeID)
    case loopVariable(NodeID)
    case element(NodeID)
    case style(NodeID, file: DeskFileID)
    case option(NodeID, file: DeskFileID)
    case builtIn(CatalogPath)
    /// A case of a catalog enum or named-value table (`Weekday`, `Color`), or of a Picker's own choices (`Theme`).
    case enumCase(type: String, case: String)
    case event
}

/// The type of an expression: its type (with the dimension of a number), the display base of amounts of data, and
/// the range data knows for itself.
public struct SemType: Sendable, Hashable {
    public var type: DeskType
    public var displayBase: Int?
    public var range: RangeSpec?

    public init(type: DeskType, displayBase: Int? = nil, range: RangeSpec? = nil) {
        self.type = type
        self.displayBase = displayBase
        self.range = range
    }
}

/// When a facet's candidate applies.
public indirect enum CandidateCondition: Sendable, Hashable {
    /// While this `if:` condition holds.
    case expr(NodeID)
    /// While the pointer is over the element's box.
    case hover
    /// While a press that started on the element is held inside it.
    case pressed
    /// All of these at once.
    case all([CandidateCondition])
}

/// Where a candidate value was written.
public enum CandidateOrigin: Sendable, Hashable {
    /// On the element itself (the modifier's node).
    case own(NodeID)
    /// In a style, reached through `.style(…)`; the modifier's node, in the style's file.
    case style(String, NodeID, file: DeskFileID)
}

/// One value a facet may take (§4.8.5). The highest key whose condition holds wins:
/// (conditional, level, hard, position).
public struct Candidate: Sendable, Hashable {
    /// The argument expression, or the modifier itself for values it fixes (`.bold()`) and presets.
    public var value: NodeID
    /// The value as Desk text when it does not come from an argument (`.bold`, a preset's `15`).
    public var fixedValue: String?
    public var condition: CandidateCondition?
    /// 3 own, 2 from a style.
    public var level: Int
    public var hard: Bool
    /// Later in the expansion order wins.
    public var position: Int
    public var origin: CandidateOrigin

    public init(value: NodeID, fixedValue: String? = nil, condition: CandidateCondition?, level: Int, hard: Bool,
                position: Int, origin: CandidateOrigin) {
        self.value = value
        self.fixedValue = fixedValue
        self.condition = condition
        self.level = level
        self.hard = hard
        self.position = position
        self.origin = origin
    }

    /// The precedence key of §4.8.5.
    public var sortKey: (Int, Int, Int, Int) { (condition == nil ? 0 : 1, level, hard ? 1 : 0, position) }
}

/// The facts of one element (a view call): its component, every facet's candidates best first, what isolation
/// dropped, and the facets whose value when no candidate holds is inherited from the nearest ancestor (§4.8.6).
public struct ElementFacts: Sendable {
    public var component: String
    public var kind: ElementKind
    public var facets: [FacetID: [Candidate]]
    public var dropped: [DroppedUnit]
    public var inherits: Set<FacetID>
    /// The own name given with `.name(…)`.
    public var name: String?
    /// The enclosing element, nil for the root.
    public var parent: NodeID?
    /// Inside an `if` branch or a `for` body (not referable by position, §4.10).
    public var insideIf: Bool
    public var insideFor: Bool
    /// The element is the widget's root (or a top-level statement of an implicit root Column).
    public var isRoot: Bool

    public init(component: String, kind: ElementKind, facets: [FacetID: [Candidate]] = [:], dropped: [DroppedUnit] = [],
                inherits: Set<FacetID> = [], name: String? = nil, parent: NodeID? = nil, insideIf: Bool = false,
                insideFor: Bool = false, isRoot: Bool = false) {
        self.component = component
        self.kind = kind
        self.facets = facets
        self.dropped = dropped
        self.inherits = inherits
        self.name = name
        self.parent = parent
        self.insideIf = insideIf
        self.insideFor = insideFor
        self.isRoot = isRoot
    }
}

/// Something an expression depends on (§4.18).
public enum DepKey: Sendable, Hashable, Comparable {
    /// A data node and field: `"cpu.usage"`, `"calendar.month"`.
    case data(String)
    /// A `variable` or `saved` value.
    case variable(String)
    case computed(String)
    case option(String)
    case loopVariable(String)
    /// The geometry of a named element (`title.right`).
    case elementGeometry(String)
    case widgetSize
    /// Light or dark, and the accent color (adaptive colors).
    case appearance
    /// The display language (formatted text).
    case language
    case event
    case hover
    case pressed

    public static func < (a: DepKey, b: DepKey) -> Bool { a.sortText < b.sortText }

    var sortText: String {
        switch self {
        case .data(let s): return "data:" + s
        case .variable(let s): return "variable:" + s
        case .computed(let s): return "computed:" + s
        case .option(let s): return "option:" + s
        case .loopVariable(let s): return "loop:" + s
        case .elementGeometry(let s): return "element:" + s
        case .widgetSize: return "widget.size"
        case .appearance: return "appearance"
        case .language: return "language"
        case .event: return "event"
        case .hover: return "hover"
        case .pressed: return "pressed"
        }
    }
}

/// How a data reference is used (§4.18): shown, driving logic, or read only inside actions.
public enum DataUsage: String, Sendable, Hashable {
    case display, logic, onDemand
}

/// One reference to data (§7.4): the node it reads (its path, and the arguments that key it), the member read, how
/// it is used, and the `for` loops whose variables its arguments read (one node per instance).
public struct DataUse: Sendable, Hashable {
    /// The node read: `"cpu"`, `"calendar.month"`, `"web.json"`.
    public var nodePath: String
    /// The member path read from it: `"cpu.usage"`, `"calendar.month"`.
    public var memberPath: String
    public var usage: DataUsage
    /// The argument expressions that key the node.
    public var arguments: [NodeID]
    /// The loops whose variables the arguments read.
    public var instanceScope: [NodeID]
    /// Where it is read.
    public var reference: NodeID

    public init(nodePath: String, memberPath: String, usage: DataUsage, arguments: [NodeID], instanceScope: [NodeID],
                reference: NodeID) {
        self.nodePath = nodePath
        self.memberPath = memberPath
        self.usage = usage
        self.arguments = arguments
        self.instanceScope = instanceScope
        self.reference = reference
    }
}

/// A reaction or timer, in document order (§4.18).
public struct ReactionFacts: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case every, when, onChange, onLoad, onWake
    }
    public var kind: Kind
    /// The modifier.
    public var modifier: NodeID
    /// The element it is written on.
    public var element: NodeID
    /// What its condition or watched value reads (empty for `.every`, `.onLoad`, `.onWake`).
    public var dependencies: Set<DepKey>
    /// `.every`'s interval in seconds, when it is a literal.
    public var interval: Double?

    public init(kind: Kind, modifier: NodeID, element: NodeID, dependencies: Set<DepKey>, interval: Double? = nil) {
        self.kind = kind
        self.modifier = modifier
        self.element = element
        self.dependencies = dependencies
        self.interval = interval
    }
}

/// A translatable string of the file (§8.6): where it is, its key, and whether it reaches a translatable parameter
/// directly (false: stored in a declaration first, which is not translated in deskVersion 1).
public struct StringEntry: Sendable, Hashable {
    public var range: Range<Int>
    public var node: NodeID
    /// The canonical source text, as the formatter prints it.
    public var key: String
    public var translatable: Bool

    public init(range: Range<Int>, node: NodeID, key: String, translatable: Bool) {
        self.range = range
        self.node = node
        self.key = key
        self.translatable = translatable
    }
}

/// A command the widget can run, as the install dialog lists it (§8.1): the template, and for each placeholder the
/// option it reads and every value the author wrote for it.
public struct CommandFacts: Sendable, Hashable {
    public var node: NodeID
    public var template: String
    /// The script with each placeholder replaced by its positional parameter (`open "${1}"`).
    public var script: String
    /// The options read by the placeholders, in order (`${1}`, `${2}`…).
    public var placeholders: [String]
    /// A whole command taken from an option (`run(options.script)`).
    public var scriptOption: String?
    /// For each option: its default and the constants actions assign to it, as Desk text.
    public var knownValues: [String: [String]]

    public init(node: NodeID, template: String, script: String, placeholders: [String], scriptOption: String?,
                knownValues: [String: [String]]) {
        self.node = node
        self.template = template
        self.script = script
        self.placeholders = placeholders
        self.scriptOption = scriptOption
        self.knownValues = knownValues
    }
}

/// What a file needs (§8.1, §8.5): permissions, network hosts, the oldest Deskset that runs it, the features it asks
/// about, and the commands it can run.
public struct Requirements: Sendable, Hashable {
    public var permissions: Set<String>
    public var hosts: [String]
    public var minimumAppVersion: AppVersion
    public var features: Set<String>
    public var commands: [CommandFacts]

    public init(permissions: Set<String> = [], hosts: [String] = [], minimumAppVersion: AppVersion = .deskFirstRelease,
                features: Set<String> = [], commands: [CommandFacts] = []) {
        self.permissions = permissions
        self.hosts = hosts
        self.minimumAppVersion = minimumAppVersion
        self.features = features
        self.commands = commands
    }
}

/// An option of `options { }`: its control, its value type once settled, its default as Desk text, and whether it
/// belongs to the widget or the package.
public struct OptionFacts: Sendable, Hashable {
    public enum Scope: String, Sendable, Hashable { case widget, package }
    public var name: String
    public var control: String
    public var type: DeskType
    public var displayBase: Int?
    public var defaultText: String?
    public var scope: Scope
    public var node: NodeID
    /// A Picker's own choices, when they form a local enum (`Theme`).
    public var localEnum: String?
    public var choices: [String]

    public init(name: String, control: String, type: DeskType, displayBase: Int? = nil, defaultText: String?,
                scope: Scope, node: NodeID, localEnum: String? = nil, choices: [String] = []) {
        self.name = name
        self.control = control
        self.type = type
        self.displayBase = displayBase
        self.defaultText = defaultText
        self.scope = scope
        self.node = node
        self.localEnum = localEnum
        self.choices = choices
    }
}

/// The translations of a file: language tag (normalized) → key → translation text as written.
public struct TranslationTable: Sendable, Hashable {
    public var languages: [String: [String: String]]
    public init(languages: [String: [String: String]] = [:]) { self.languages = languages }
}

/// The pictures a file names where a picture is expected (§8.3): every literal path with where it is written, and
/// whether some picture comes from anything else (data, an option, a template), so that the file's pictures cannot
/// all be known.
public struct AssetUses: Sendable, Hashable {
    public struct Site: Sendable, Hashable {
        public var path: String
        public var file: DeskFileID
        public var range: Range<Int>

        public init(path: String, file: DeskFileID, range: Range<Int>) {
            self.path = path
            self.file = file
            self.range = range
        }
    }

    public var images: [Site]
    public var computedImages: Bool

    public init(images: [Site] = [], computedImages: Bool = false) {
        self.images = images
        self.computedImages = computedImages
    }
}

/// A checked file (§4.20).
public struct CheckedFile: Sendable {
    public let tree: SyntaxTree
    /// The tree's diagnostics and the checker's, sorted by file and position.
    public let diagnostics: [Diagnostic]
    public let symbols: [NodeID: Symbol]
    public let types: [NodeID: SemType]
    public let elements: [NodeID: ElementFacts]
    public let dataUses: [DataUse]
    public let dependencies: [NodeID: Set<DepKey>]
    public let reactions: [ReactionFacts]
    public let freeformOrders: [NodeID: [NodeID]]
    public let stringTable: [StringEntry]
    public let requirements: Requirements
    /// The options this file declares (for a package, the package's).
    public let options: [String: OptionFacts]
    /// The styles this file declares, by name.
    public let styles: [String: NodeID]
    public let translations: TranslationTable
    /// The widget's root element, when it has one; nil for an implicit Column.
    public let root: NodeID?
    /// How each `for` identifies its instances (§4.15): the identity field of the list's records (`"date"`), or
    /// `"position"`.
    public var loopIdentities: [NodeID: String] = [:]
    /// The pictures the file names.
    public var assets = AssetUses()
    /// The type each `variable`, `saved` and `computed` declaration settled to (by its initializer, or by its uses
    /// when the initializer left it open), keyed by the declaration; absent where no use decided it.
    public var declarationTypes: [NodeID: SemType] = [:]

    public init(tree: SyntaxTree, diagnostics: [Diagnostic], symbols: [NodeID: Symbol], types: [NodeID: SemType],
                elements: [NodeID: ElementFacts], dataUses: [DataUse], dependencies: [NodeID: Set<DepKey>],
                reactions: [ReactionFacts], freeformOrders: [NodeID: [NodeID]], stringTable: [StringEntry],
                requirements: Requirements, options: [String: OptionFacts] = [:], styles: [String: NodeID] = [:],
                translations: TranslationTable = TranslationTable(), root: NodeID? = nil) {
        self.tree = tree
        self.diagnostics = diagnostics
        self.symbols = symbols
        self.types = types
        self.elements = elements
        self.dataUses = dataUses
        self.dependencies = dependencies
        self.reactions = reactions
        self.freeformOrders = freeformOrders
        self.stringTable = stringTable
        self.requirements = requirements
        self.options = options
        self.styles = styles
        self.translations = translations
        self.root = root
    }

    /// Diagnostics of one severity.
    public func diagnostics(_ severity: Severity) -> [Diagnostic] { diagnostics.filter { $0.severity == severity } }

    /// Diagnostics only the whole folder can decide (a package's translation no text of the package uses, which
    /// a widget's text may still use): `Desk.checkFolder` adds the ones that hold.
    var folderPending: [Diagnostic] = []
}

/// `package.desk`, checked once per folder (§4.20).
public struct CheckedPackage: Sendable {
    public let file: CheckedFile
    public let options: [String: OptionFacts]
    /// Re-expanded per widget (§4.12).
    public let styles: [String: NodeID]
    public let translations: TranslationTable

    public init(file: CheckedFile) {
        self.file = file
        self.options = file.options
        self.styles = file.styles
        self.translations = file.translations
    }
}
