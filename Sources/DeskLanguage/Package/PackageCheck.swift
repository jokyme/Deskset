import Foundation

// A widget folder checked as a whole (§4.20): `Desk.checkFolder` over its `package.desk` and widgets, with the
// folder's pictures and fonts as resources, what loading found and the folder checks (DK86xx), and an index from
// each package style, option and translation key to where every file of the folder uses it.

/// Where something is written: a file of the folder and a UTF-8 range in it.
public struct DeskSite: Sendable, Hashable, CustomStringConvertible {
    public var file: DeskFileID
    public var range: Range<Int>

    public init(file: DeskFileID, range: Range<Int>) {
        self.file = file
        self.range = range
    }

    public var description: String { "\(file.path)@\(range.lowerBound)..<\(range.upperBound)" }
}

/// The package's shared styles, options and translation keys, each with its declarations in `package.desk` and its
/// uses in every file of the folder (`package.desk`'s own included), sorted by file and position.
public struct DeskPackageUses: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case style, option, translation
    }

    public struct Entry: Sendable, Hashable {
        public var kind: Kind
        public var name: String
        /// For a style or option its declaration; for a translation key, the key in each language's table.
        public var declarations: [DeskSite]
        public var uses: [DeskSite]
        /// Widgets that declare their own option or style of this name (D99): their uses are not this entry's.
        public var replacedIn: [DeskFileID]

        public init(kind: Kind, name: String, declarations: [DeskSite] = [], uses: [DeskSite] = [],
                    replacedIn: [DeskFileID] = []) {
            self.kind = kind
            self.name = name
            self.declarations = declarations
            self.uses = uses
            self.replacedIn = replacedIn
        }

        /// The widgets that use it (not `package.desk`).
        public var widgets: [DeskFileID] {
            var seen = Set<DeskFileID>()
            return uses.map(\.file).filter { $0.path != DeskPackage.packageFileName && seen.insert($0).inserted }
        }
    }

    public var styles: [String: Entry] = [:]
    public var options: [String: Entry] = [:]
    public var translations: [String: Entry] = [:]

    public init() {}

    public func entry(_ kind: Kind, _ name: String) -> Entry? {
        switch kind {
        case .style: return styles[name]
        case .option: return options[name]
        case .translation: return translations[name]
        }
    }

    /// The entry declared or used at a UTF-8 offset of a file.
    public func entry(at offset: Int, in file: DeskFileID) -> Entry? {
        for table in [styles, options, translations] {
            for entry in table.values {
                let sites = entry.declarations + entry.uses
                if sites.contains(where: { $0.file == file && ($0.range.contains(offset) || $0.range.upperBound == offset) }) {
                    return entry
                }
            }
        }
        return nil
    }
}

/// A widget folder checked as a whole.
public struct CheckedDeskPackage: Sendable {
    public let package: DeskPackage
    /// `package.desk` (with what only the folder knows) and every widget, checked with it.
    public let files: [DeskFileID: CheckedFile]
    public let packageFile: DeskFileID?
    /// The widgets that were checked, in file order.
    public let widgetFiles: [DeskFileID]
    /// What loading found and the folder checks (DK86xx), sorted by file and position.
    public let folderDiagnostics: [Diagnostic]
    public let uses: DeskPackageUses
    public let catalog: DeskCatalog

    /// Checks every file of the folder. Without `context.resources`, the folder's own files are the resources.
    public init(package: DeskPackage, context: CheckContext = CheckContext()) {
        var context = context
        context.package = nil
        if context.resources == nil { context.resources = PackageResources(package: package) }
        let packageTree = package.packageFile.flatMap { id in package.texts[id].map { Desk.parse($0, file: id) } }
        let widgetTrees = package.widgetFiles.compactMap { id in package.texts[id].map { Desk.parse($0, file: id) } }
        let results = Desk.checkFolder(package: packageTree, widgets: widgetTrees, context: context)
        self.init(package: package, results: results, catalog: context.catalog)
    }

    /// A folder whose files are already checked with `Desk.checkFolder` (the language service's results).
    public init(package: DeskPackage, results: [DeskFileID: CheckedFile], catalog: DeskCatalog = .current) {
        self.package = package
        self.files = results
        self.catalog = catalog
        packageFile = package.packageFile.flatMap { results[$0] != nil ? $0 : nil }
        widgetFiles = package.widgetFiles.filter { results[$0] != nil }
        uses = DeskPackageUses.build(files: results, packageFile: packageFile, widgets: widgetFiles)
        folderDiagnostics = PackageLoader.sorted(package.diagnostics
            + PackageValidator.validate(package, files: results, catalog: catalog))
    }

    /// The checked package file, as widgets are checked with it.
    public var checkedPackage: CheckedFile? { packageFile.flatMap { files[$0] } }

    /// Every file's diagnostics and the folder's, sorted by file and position.
    public var allDiagnostics: [Diagnostic] {
        PackageLoader.sorted(files.values.flatMap(\.diagnostics) + folderDiagnostics)
    }

    /// The diagnostics of one file (`DeskPackage.folderFile` for the folder's own), the folder checks included.
    public func diagnostics(of file: DeskFileID) -> [Diagnostic] {
        PackageLoader.sorted((files[file]?.diagnostics ?? []) + folderDiagnostics.filter { $0.file == file })
    }

    /// Errors, warnings and tips per file, for the file-name menu; the folder's own under `DeskPackage.folderFile`.
    public func problemCounts() -> [DeskFileID: DeskProblemCount] {
        var counts: [DeskFileID: DeskProblemCount] = [:]
        var seen = Set<String>()
        for d in allDiagnostics where seen.insert("\(d.file.path)|\(d.id.rawValue)|\(d.range)").inserted {
            counts[d.file, default: DeskProblemCount()].add(d.severity)
        }
        for file in files.keys where counts[file] == nil { counts[file] = DeskProblemCount() }
        return counts
    }
}

extension DeskPackageUses {
    static func build(files: [DeskFileID: CheckedFile], packageFile: DeskFileID?,
                      widgets: [DeskFileID]) -> DeskPackageUses {
        var uses = DeskPackageUses()
        guard let packageFile, let package = files[packageFile] else { return uses }
        let packageTree = package.tree
        var styleByID: [NodeID: String] = [:]
        var optionByID: [NodeID: String] = [:]
        for (name, id) in package.styles {
            styleByID[id] = name
            var entry = Entry(kind: .style, name: name)
            if let node = packageTree.quickResolve(id) {
                let name = StyleDeclSyntax(node)?.name.textRange ?? node.quickTextRange
                entry.declarations = [DeskSite(file: packageFile, range: name)]
            }
            uses.styles[name] = entry
        }
        for (name, facts) in package.options {
            optionByID[facts.node] = name
            var entry = Entry(kind: .option, name: name)
            if let node = packageTree.quickResolve(facts.node) {
                let target = OptionDeclSyntax(node)?.target.name.textRange ?? node.quickTextRange
                entry.declarations = [DeskSite(file: packageFile, range: target)]
            }
            uses.options[name] = entry
        }
        for (key, sites) in DeskTranslationKeys.sites(in: packageTree) {
            uses.translations[key] = Entry(kind: .translation, name: key, declarations: sites)
        }
        let trees = Dictionary(files.values.map { ($0.tree.version, $0.tree) }, uniquingKeysWith: { a, _ in a })
        for file in [packageFile] + widgets {
            guard let checked = files[file] else { continue }
            for (ref, symbol) in checked.symbols {
                let kind: Kind
                let name: String?
                switch symbol {
                case .style(let id, let declaredIn) where declaredIn == packageFile && ref != id:
                    kind = .style
                    name = styleByID[id]
                case .option(let id, let declaredIn) where declaredIn == packageFile && ref != id:
                    kind = .option
                    name = optionByID[id]
                default:
                    continue
                }
                guard let name, let tree = trees[ref.treeVersion], let node = tree.quickResolve(ref) else { continue }
                let site = DeskSite(file: tree.file, range: node.quickTextRange)
                if kind == .style { uses.styles[name]?.uses.append(site) } else { uses.options[name]?.uses.append(site) }
            }
            for entry in checked.stringTable where uses.translations[entry.key] != nil {
                uses.translations[entry.key]?.uses.append(DeskSite(file: file, range: entry.range))
            }
            if file != packageFile {
                for name in checked.options.keys where uses.options[name] != nil { uses.options[name]?.replacedIn.append(file) }
                for name in checked.styles.keys where uses.styles[name] != nil { uses.styles[name]?.replacedIn.append(file) }
            }
        }
        func tidy(_ table: inout [String: Entry]) {
            for name in Array(table.keys) {
                var seen = Set<DeskSite>()
                table[name]!.uses = table[name]!.uses.filter { seen.insert($0).inserted }.sorted {
                    $0.file != $1.file ? DeskPackagePath.precedes($0.file.path, $1.file.path) : $0.range.lowerBound < $1.range.lowerBound
                }
            }
        }
        tidy(&uses.styles)
        tidy(&uses.options)
        tidy(&uses.translations)
        return uses
    }
}

/// The keys of a `translations { }` block, computed as the checker computes them (§8.6: the text between
/// interpolations as written, each interpolation as its canonical tokens).
enum DeskTranslationKeys {
    static func key(of string: StringLiteralSyntax, in tree: SyntaxTree) -> String {
        var key = ""
        for segment in string.segments {
            switch segment {
            case .text(let token, _): key += token.token.text
            case .interpolation(let i): key += "{" + Checker.canonicalTokens(i.node.tokens.dropFirst().dropLast()) + "}"
            case .foreign(let n): key += DeskPackageReader.text(tree, n)
            }
        }
        return key
    }

    /// Every entry of the translations block: key → the key's range in each language, in order.
    static func sites(in tree: SyntaxTree) -> [String: [DeskSite]] {
        var out: [String: [DeskSite]] = [:]
        for entry in entries(in: tree) {
            out[entry.key, default: []].append(DeskSite(file: tree.file, range: entry.keyRange))
        }
        return out
    }

    struct Entry {
        var language: String
        var key: String
        var keyRange: Range<Int>
        /// The translation's value when it has no interpolation.
        var value: String?
    }

    /// Every entry of every language group, the language normalized.
    static func entries(in tree: SyntaxTree) -> [Entry] {
        var out: [Entry] = []
        for block in tree.rootNode.childNodes where block.kind == .translationsBlock {
            guard let body = block.firstChild(.block) else { continue }
            for statement in BlockSyntax(unchecked: body).statements where statement.kind == .group {
                let group = GroupSyntax(unchecked: statement)
                guard let tag = group.tag.literalValue else { continue }
                let language = DeskLocalization.normalize(tag)
                for entryNode in group.block.statements where entryNode.kind == .entry {
                    let entry = EntrySyntax(unchecked: entryNode)
                    let value = StringLiteralSyntax(entry.value.node)?.literalValue
                    out.append(Entry(language: language, key: key(of: entry.key, in: tree),
                                     keyRange: entry.key.node.quickTextRange, value: value))
                }
            }
        }
        return out
    }
}
