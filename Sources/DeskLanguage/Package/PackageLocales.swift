import Foundation

/// How far one language's translations cover a file's texts: a hint for the translation view, never a diagnostic.
public struct DeskTranslationCoverage: Sendable, Hashable {
    /// Normalized (`zh-Hans`).
    public var language: String
    /// Translatable texts of the file (unique keys).
    public var total: Int
    /// Keys with no translation in this language, in the order they first appear.
    public var missing: [String]

    public init(language: String, total: Int, missing: [String]) {
        self.language = language
        self.total = total
        self.missing = missing
    }

    public var translated: Int { total - missing.count }
}

/// The languages of a widget folder (§8.6): the package's translations apply to every widget, and a widget's own
/// entry for the same key and language wins (D99). Tags are normalized (`zh-CN` is `zh-Hans`); the display language
/// is chosen with `DeskLocalization.displayLanguage`.
public struct DeskPackageLocales: Sendable {
    /// Every language the package or a widget translates, normalized, sorted.
    public let languages: [String]
    /// `package.desk`'s tables: language → key → the translation as written.
    public let packageTables: [String: [String: String]]
    /// Each widget's tables: the package's entries with the widget's own on top.
    public let widgetTables: [DeskFileID: [String: [String: String]]]

    /// Translations without interpolation, as text: language → key → value.
    private let packageValues: [String: [String: String]]
    private let widgetValues: [DeskFileID: [String: [String: String]]]
    /// The translatable texts of each file, unique keys in order.
    private let packageKeys: [String]
    private let widgetKeys: [DeskFileID: [String]]
    /// The keys of `name` and `description` in each file's `info` / `package` block.
    private let fieldKeys: [DeskFileID: [String: String]]
    private let entries: [DeskFileID: DeskWidgetEntry]
    private let manifest: DeskManifest?
    private let packageFile: DeskFileID?

    public init(_ checked: CheckedDeskPackage) {
        var languages = Set<String>()
        var packageTables: [String: [String: String]] = [:]
        var packageValues: [String: [String: String]] = [:]
        var fieldKeys: [DeskFileID: [String: String]] = [:]
        var packageKeys: [String] = []
        if let file = checked.packageFile, let package = checked.files[file] {
            packageTables = package.translations.languages
            packageValues = Self.values(package.tree)
            packageKeys = Self.keys(package)
            fieldKeys[file] = Self.fieldKeys(package.tree, kind: .packageBlock)
        }
        languages.formUnion(packageTables.keys)
        var widgetTables: [DeskFileID: [String: [String: String]]] = [:]
        var widgetValues: [DeskFileID: [String: [String: String]]] = [:]
        var widgetKeys: [DeskFileID: [String]] = [:]
        for file in checked.widgetFiles {
            guard let widget = checked.files[file] else { continue }
            var tables = packageTables
            for (language, table) in widget.translations.languages {
                tables[language, default: [:]].merge(table) { _, own in own }
            }
            var values = packageValues
            for (language, table) in Self.values(widget.tree) {
                values[language, default: [:]].merge(table) { _, own in own }
            }
            widgetTables[file] = tables
            widgetValues[file] = values
            widgetKeys[file] = Self.keys(widget)
            fieldKeys[file] = Self.fieldKeys(widget.tree, kind: .infoBlock)
            languages.formUnion(widget.translations.languages.keys)
        }
        self.languages = languages.sorted()
        self.packageTables = packageTables
        self.widgetTables = widgetTables
        self.packageValues = packageValues
        self.widgetValues = widgetValues
        self.packageKeys = packageKeys
        self.widgetKeys = widgetKeys
        self.fieldKeys = fieldKeys
        self.entries = Dictionary(checked.package.widgets.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        self.manifest = checked.package.manifest
        self.packageFile = checked.packageFile
    }

    /// The languages a widget is translated into (the package's included), sorted; `package.desk`'s own for the
    /// package or nil.
    public func languages(of file: DeskFileID?) -> [String] {
        guard let file, file != packageFile else { return packageTables.keys.sorted() }
        return (widgetTables[file] ?? [:]).keys.sorted()
    }

    /// The language a widget (nil: the package page) is shown in for the Mac's preferred languages, normalized; nil
    /// for the source text (English).
    public func displayLanguage(of file: DeskFileID?, preferred: [String]) -> String? {
        DeskLocalization.displayLanguage(available: languages(of: file), preferred: preferred)
    }

    /// The translation of a text of a widget (nil: of the package) in a language, as text; nil when it has none or
    /// the translation holds data (it is then a pattern the runtime fills).
    public func translate(_ key: String, in file: DeskFileID?, language: String?) -> String? {
        guard let language else { return nil }
        let normalized = DeskLocalization.normalize(language)
        let values = file.flatMap { $0 == packageFile ? nil : widgetValues[$0] } ?? packageValues
        return values[normalized]?[key]
    }

    /// A text in a language, or the source text itself.
    public func localized(_ source: String, key: String? = nil, in file: DeskFileID?, language: String?) -> String {
        translate(key ?? source, in: file, language: language) ?? source
    }

    /// The widget's name as the library shows it in the display language for `preferred`.
    public func name(of file: DeskFileID, preferred: [String]) -> String {
        let source = entries[file]?.name ?? (file.path as NSString).deletingPathExtension
        guard let key = fieldKeys[file]?["name"] else { return source }
        return localized(source, key: key, in: file, language: displayLanguage(of: file, preferred: preferred))
    }

    public func description(of file: DeskFileID, preferred: [String]) -> String {
        let source = entries[file]?.description ?? ""
        guard let key = fieldKeys[file]?["description"] else { return source }
        return localized(source, key: key, in: file, language: displayLanguage(of: file, preferred: preferred))
    }

    /// `package { name: … }` in the display language; nil when the package has no name.
    public func packageName(preferred: [String]) -> String? {
        guard let source = manifest?.name else { return nil }
        let key = packageFile.flatMap { fieldKeys[$0]?["name"] } ?? source
        return localized(source, key: key, in: nil, language: displayLanguage(of: nil, preferred: preferred))
    }

    public func packageDescription(preferred: [String]) -> String? {
        guard let source = manifest?.description else { return nil }
        let key = packageFile.flatMap { fieldKeys[$0]?["description"] } ?? source
        return localized(source, key: key, in: nil, language: displayLanguage(of: nil, preferred: preferred))
    }

    /// For each language of the widget (nil: of the package), the translatable texts it leaves untranslated. The
    /// widget's own texts count for a widget; the package's texts (its option labels, its styles' tooltips) count
    /// for the package.
    public func coverage(of file: DeskFileID?) -> [DeskTranslationCoverage] {
        let isPackage = file == nil || file == packageFile
        let keys = isPackage ? packageKeys : (file.flatMap { widgetKeys[$0] } ?? [])
        let tables = isPackage ? packageTables : (file.flatMap { widgetTables[$0] } ?? [:])
        return tables.keys.sorted().map { language in
            let table = tables[language] ?? [:]
            return DeskTranslationCoverage(language: language, total: keys.count, missing: keys.filter { table[$0] == nil })
        }
    }

    // MARK: - Reading

    /// Every translatable text's key, once, in order.
    private static func keys(_ file: CheckedFile) -> [String] {
        var seen = Set<String>()
        return file.stringTable.filter(\.translatable).map(\.key).filter { seen.insert($0).inserted }
    }

    /// Translations without interpolation, as text.
    private static func values(_ tree: SyntaxTree) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for entry in DeskTranslationKeys.entries(in: tree) {
            guard let value = entry.value, out[entry.language]?[entry.key] == nil else { continue }
            out[entry.language, default: [:]][entry.key] = value
        }
        return out
    }

    /// The keys of the literal `name` and `description` fields.
    private static func fieldKeys(_ tree: SyntaxTree, kind: SyntaxKind) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in DeskPackageReader.fields(tree, kind: kind) where ["name", "description"].contains(name) {
            guard out[name] == nil, let string = StringLiteralSyntax(value) else { continue }
            out[name] = DeskTranslationKeys.key(of: string, in: tree)
        }
        return out
    }
}
