import Foundation

/// The single description of every built-in name of Desk: components, modifiers and their facets, data and action
/// namespaces, global functions and actions, records, enums and named values, option controls, `info` and
/// `package` fields, units, format options, permissions, features, foreign spellings, display names, the Rainmeter
/// details a converted widget may keep, and the diagnostics. The checker, completion, hover help, the editor's
/// generated pages, the language reference and the Rainmeter conversion table are all built from it.
///
/// `current` is built once. A copy may be changed (tests build a catalog with extra future names); lookups then use
/// an index rebuilt for the copy.
public struct DeskCatalog: Sendable {
    public var components: [ComponentSpec] { didSet { invalidate() } }
    public var modifiers: [ModifierSpec] { didSet { invalidate() } }
    /// Every facet a modifier can set, with how the editor's pages show it.
    public var facets: [FacetSpec] { didSet { invalidate() } }
    /// Data and action namespaces with all their members: `cpu`, `music`, `weather`…
    public var namespaces: [NamespaceSpec] { didSet { invalidate() } }
    /// Global functions and actions only: `round`, `open`, `after`…
    public var functions: [FunctionSpec] { didSet { invalidate() } }
    public var records: [RecordSpec] { didSet { invalidate() } }
    /// Members of the built-in value types: every value, text, lists, dates, colors, web data.
    public var typeMembers: [TypeMembersSpec] { didSet { invalidate() } }
    public var enums: [EnumSpec] { didSet { invalidate() } }
    /// Named values of types that are not enums: the colors and paints.
    public var namedValues: [NamedValueSpec] { didSet { invalidate() } }
    /// Option controls: `Picker`, `Toggle`…
    public var controls: [ControlSpec] { didSet { invalidate() } }
    public var infoFields: [FieldSpec] { didSet { invalidate() } }
    public var packageFields: [FieldSpec] { didSet { invalidate() } }
    public var units: [UnitSpec] { didSet { invalidate() } }
    public var unitMisspellings: [UnitMisspellingSpec] { didSet { invalidate() } }
    public var formatOptions: [FormatOptionSpec] { didSet { invalidate() } }
    /// How each type shows in text by default (§4.11).
    public var typeFormats: [TypeFormatSpec]
    public var permissions: [PermissionSpec] { didSet { invalidate() } }
    /// What `supports(…)` can ask about.
    public var features: [FeatureSpec] { didSet { invalidate() } }
    /// `VStack` → `Column`, `FontColor=` → `.color(…)`…
    public var foreign: [ForeignSpec] { didSet { invalidate() } }
    /// Names of types, dimensions, facets, components, presets and grammar slots for messages.
    public var displayNames: [DisplayNameSpec] { didSet { invalidate() } }
    /// The Rainmeter details `.rainmeter(…)` may keep in a converted widget.
    public var compatDetails: [CompatDetailSpec] { didSet { invalidate() } }
    /// Commands that run an argument as code: `sh -c`, `osascript -e`…
    public var rereadingCommands: [RereadSpec] { didSet { invalidate() } }
    public var diagnostics: [DiagnosticSpec] { didSet { invalidate() } }
    public var fixItTitles: [FixItTitleSpec] { didSet { invalidate() } }
    public var notes: [NoteSpec] { didSet { invalidate() } }
    public var limits: CatalogLimits

    private var box = IndexBox()

    public init(components: [ComponentSpec], modifiers: [ModifierSpec], facets: [FacetSpec],
                namespaces: [NamespaceSpec], functions: [FunctionSpec], records: [RecordSpec],
                typeMembers: [TypeMembersSpec], enums: [EnumSpec],
                namedValues: [NamedValueSpec], controls: [ControlSpec], infoFields: [FieldSpec],
                packageFields: [FieldSpec], units: [UnitSpec], unitMisspellings: [UnitMisspellingSpec],
                formatOptions: [FormatOptionSpec], typeFormats: [TypeFormatSpec] = [], permissions: [PermissionSpec],
                features: [FeatureSpec],
                foreign: [ForeignSpec], displayNames: [DisplayNameSpec], compatDetails: [CompatDetailSpec],
                rereadingCommands: [RereadSpec], diagnostics: [DiagnosticSpec], fixItTitles: [FixItTitleSpec],
                notes: [NoteSpec], limits: CatalogLimits = CatalogLimits()) {
        self.components = components
        self.modifiers = modifiers
        self.facets = facets
        self.namespaces = namespaces
        self.functions = functions
        self.records = records
        self.typeMembers = typeMembers
        self.enums = enums
        self.namedValues = namedValues
        self.controls = controls
        self.infoFields = infoFields
        self.packageFields = packageFields
        self.units = units
        self.unitMisspellings = unitMisspellings
        self.formatOptions = formatOptions
        self.typeFormats = typeFormats
        self.permissions = permissions
        self.features = features
        self.foreign = foreign
        self.displayNames = displayNames
        self.compatDetails = compatDetails
        self.rereadingCommands = rereadingCommands
        self.diagnostics = diagnostics
        self.fixItTitles = fixItTitles
        self.notes = notes
        self.limits = limits
    }

    /// The catalog of this Deskset.
    public static let current: DeskCatalog = {
        typealias D = CatalogData
        let modifiers = D.modifiers
        return DeskCatalog(
            components: D.components, modifiers: modifiers, facets: D.facets, namespaces: D.namespaces,
            functions: D.functions, records: D.records, typeMembers: D.typeMembers, enums: D.enums,
            namedValues: D.namedValues,
            controls: D.controls, infoFields: D.fields.filter(\.inInfo), packageFields: D.fields.filter(\.inPackage),
            units: D.units, unitMisspellings: D.unitMisspellings, formatOptions: D.formatOptions, typeFormats: D.typeFormats,
            permissions: D.permissions, features: D.features, foreign: D.foreign, displayNames: D.displayNames,
            compatDetails: D.compatDetails, rereadingCommands: D.rereadingCommands, diagnostics: D.diagnostics,
            fixItTitles: D.fixItTitles, notes: D.notes)
    }()

    /// Lookups by name, built on first use for this copy of the catalog.
    public var index: CatalogIndex { box.index(for: self) }

    private mutating func invalidate() { box = IndexBox() }
}

/// Holds one catalog's index, built on first use (thread-safe).
private final class IndexBox: @unchecked Sendable {
    private let lock = NSLock()
    private var built: CatalogIndex?

    func index(for catalog: DeskCatalog) -> CatalogIndex {
        lock.lock()
        defer { lock.unlock() }
        if let built { return built }
        let index = CatalogIndex(catalog)
        built = index
        return index
    }
}

/// The limits that keep a wrong or hostile widget from slowing the Mac down, and the preset sizes.
public struct CatalogLimits: Sendable, Hashable {
    public var maximumFileBytes = 1_048_576
    public var maximumTokens = 200_000
    public var maximumBlockNesting = 64
    public var maximumExpressionNesting = 128
    public var maximumDiagnosticsPerFile = 500
    /// UTF-16 code units of one text literal.
    public var maximumTextLength = 32_768
    public var maximumListLiteral = 1_000
    public var maximumRange = 1_000
    public var maximumForInstances = 1_000
    public var maximumForNesting = 4
    public var maximumElementInstances = 5_000
    public var maximumOptions = 100
    /// Seconds.
    public var minimumEvery = 0.016
    /// Below this `.every` gets a battery tip (seconds).
    public var everyTipBelow = 0.25
    public var refreshRange: ClosedRange<Double> = 0.25...3_600
    public var minimumWebEvery = 60.0
    public var minimumCommandEvery = 1.0
    public var maximumCommandTimeout = 60.0
    public var afterRange: ClosedRange<Double> = 0...86_400
    public var maximumPendingAfters = 256
    /// A user-initiated action inside `after` needs a literal delay of at most this (seconds).
    public var maximumUserActionDelay = 2.0
    public var maximumReactionRounds = 16
    public var maximumSavedValueBytes = 65_536
    public var maximumSavedBytesPerInstance = 1_048_576
    public var maximumWebResponseBytes = 5_242_880
    public var maximumWebImageBytes = 20_971_520
    public var maximumWebImageSide = 8_192
    public var notificationsPerMinute = 1
    /// The preset sizes in points: a medium is two smalls side by side with a 16 pt gap, a large two by two.
    public var smallSize = IdealSize(width: 170, height: 170)
    public var mediumSize = IdealSize(width: 356, height: 170)
    public var largeSize = IdealSize(width: 356, height: 356)
    /// The language version this Deskset understands.
    public var deskVersion = 1

    public init() {}
}
