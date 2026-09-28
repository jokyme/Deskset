import Foundation

// Go to definition, find references, highlights and rename, over the open file, `package.desk` and the folder's
// other widgets (§4.2: own names, styles, options; §4.12–4.13: a widget's style or option replacing the package's,
// D99; §8.6: texts and their translations; §8.3: pictures).

/// A place a name occurs in the open file, for highlighting every other place it occurs.
public struct DeskHighlight: Sendable, Hashable {
    public var range: DeskRange
    public var role: DeskOccurrenceRole

    public init(range: DeskRange, role: DeskOccurrenceRole) {
        self.range = range
        self.role = role
    }
}

/// The name a rename would change: its range in the open file and its current spelling.
public struct DeskRenamePlace: Sendable, Hashable {
    public var range: DeskRange
    public var name: String
    public var kind: DeskNameKind

    public init(range: DeskRange, name: String, kind: DeskNameKind) {
        self.range = range
        self.name = name
        self.kind = kind
    }
}

/// A rename: the edits of every file it changes, and what the author should know about it.
public struct DeskRename: Sendable, Hashable {
    public var edit: DeskWorkspaceEdit
    /// Worded in the service's language: an option keeps its saved values by name, so renaming it resets them.
    public var notes: [String]

    public init(edit: DeskWorkspaceEdit, notes: [String] = []) {
        self.edit = edit
        self.notes = notes
    }
}

/// Why a name cannot be renamed, or not to that name, worded in the service's language.
public struct DeskRenameRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Reason: String, Sendable, Hashable {
        /// Nothing at the cursor is a name the author gave.
        case notAName
        /// A built-in name (`cpu`, `.font`, `Text`).
        case builtIn
        /// Text in quotes (a translation key, a picture's path).
        case insideText
        /// The new name is not a name (`9lives`, `my-name`, `Title`).
        case invalidName
        /// The new name is a word of the language (`if`, `event`, and except for styles and options `widget`).
        case reservedWord
        /// The new name is longer than 128 bytes.
        case tooLong
        /// The new name is already used where the renamed one is visible.
        case alreadyUsed
        /// The new name would hide a built-in value (`cpu`, `time`).
        case hidesBuiltIn
        /// The name cannot be renamed here (a name written the way another language writes it).
        case cannotRename
    }

    public var reason: Reason
    public var message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    public var description: String { "\(reason.rawValue): \(message)" }
}

extension DeskSnapshot {
    // MARK: Indexes

    /// Every node of the open file with its offsets, built once.
    var nodeTable: DeskNodeTable {
        caches.nodeTable.value { DeskNodeTable(tree: tree) }
    }

    /// The styles and options `package.desk` declares.
    var packageNames: (styles: Set<String>, options: Set<String>) {
        guard let package = isPackage ? checked : package else { return ([], []) }
        return (Set(package.styles.keys), Set(package.options.keys))
    }

    /// The symbol index of a file of the folder: the open file's from this snapshot's check, `package.desk`'s from
    /// its own check, another widget's from `folderResults()`. Nil for a file the folder does not have.
    func symbolIndex(of file: DeskFileID) -> DeskSymbolIndex? {
        if let known = caches.symbolIndexes.peek(file) { return known }
        let checkedFile: CheckedFile
        if file == self.file {
            checkedFile = checked
        } else if file == packageFile, let package {
            checkedFile = package
        } else {
            guard folder[file] != nil, let result = folderResults()[file] else { return nil }
            checkedFile = result
        }
        return caches.symbolIndexes.value(for: file) {
            let names = packageNames
            return DeskSymbolIndex(checked: checkedFile, table: file == self.file ? nodeTable : nil,
                                   packageFile: isPackage || package != nil ? packageFile : nil, packageStyles: names.styles,
                                   packageOptions: names.options, catalog: options.catalog)
        }
    }

    /// The open file's index.
    var symbolIndex: DeskSymbolIndex { symbolIndex(of: file)! }

    /// The files a name of this key may occur in: the open file first, then `package.desk`, then the other widgets
    /// by path.
    func files(searchedFor key: DeskSymbolKey) -> [DeskFileID] {
        switch key {
        case .local, .event:
            return [file]
        case .style(_, let group), .option(_, let group):
            if group != packageFile { return [file] }
        case .translation, .asset, .builtIn:
            break
        }
        var out = [file]
        if !isPackage, folder[packageFile] != nil { out.append(packageFile) }
        for other in folder.keys.sorted(by: { $0.path < $1.path })
        where other != file && other != packageFile && other.path.hasSuffix(".desk") {
            out.append(other)
        }
        return out
    }

    private func occurrence(at position: DeskPosition) -> DeskOccurrence? {
        symbolIndex.occurrence(at: index.utf8Offset(ofUTF16: index.clampedUTF16(position.offset)))
    }

    private func locations(_ occurrences: [DeskOccurrence], in file: DeskFileID) -> [DeskLocation] {
        occurrences.compactMap { location(file: file, utf8: $0.range) }
    }

    // MARK: Requests

    /// What the name at a position is: an own name, a built-in, a text or a picture's path. Nil on anything else
    /// (a keyword, a number, a comment).
    public func symbol(at position: DeskPosition) -> DeskSymbolInfo? {
        guard let o = occurrence(at: position) else { return nil }
        return DeskSymbolInfo(name: o.name, kind: o.kind, role: o.role, range: index.range(utf8: o.range), catalogPath: o.path)
    }

    /// Where the name at a position is declared. Own names: their declaration. A style or option a widget declares
    /// in place of the package's (D99): the widget's declaration, then the package's. An element name: its
    /// `.name(…)`. A text: its entries in the file's and the package's translations. A picture's path: the picture
    /// (an empty range at the start of the file). Built-in names have no declaration in the folder.
    public func definition(at position: DeskPosition) -> [DeskLocation] {
        guard let o = occurrence(at: position), let key = o.key else { return [] }
        let own = symbolIndex.occurrences(of: key).filter { $0.role == .declaration }
        switch key {
        case .local:
            return locations(own, in: file)
        case .style(_, let group), .option(_, let group):
            var out = locations(own, in: file)
            if !isPackage, group == packageFile, let packageIndex = symbolIndex(of: packageFile) {
                out += locations(packageIndex.occurrences(of: key).filter { $0.role == .declaration }, in: packageFile)
            }
            return out
        case .translation:
            // The widget's translations win over the package's (§8.6).
            var out = locations(own, in: file)
            if !isPackage, let packageIndex = symbolIndex(of: packageFile) {
                out += locations(packageIndex.occurrences(of: key).filter { $0.role == .declaration }, in: packageFile)
            }
            return out
        case .asset(let path):
            guard let picture = assetFile(path) else { return [] }
            let start = DeskPosition(offset: 0, line: 0, column: 0)
            return [DeskLocation(file: picture, range: DeskRange(start: start, end: start))]
        case .builtIn, .event:
            return []
        }
    }

    /// The file a picture's path names, relative to the open file's folder, when the folder has it (or when the
    /// service knows nothing of the folder's files).
    func assetFile(_ path: String) -> DeskFileID? {
        let folderPath = (file.path as NSString).deletingLastPathComponent
        var relative = path
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        let full = folderPath.isEmpty ? relative : folderPath + "/" + relative
        if let resources, resources.kind(of: full) == nil { return nil }
        return DeskFileID(path: full)
    }

    /// Every place the name at a position occurs: in the open file, `package.desk` and the other widgets for the
    /// package's styles and options (with the widgets' declarations that replace them), texts, pictures and
    /// built-in names; in the open file for everything else. Sorted by file (the open file first) and position.
    public func references(at position: DeskPosition, includeDeclaration: Bool = true) -> [DeskLocation] {
        guard let o = occurrence(at: position), let key = o.key else { return [] }
        var out: [DeskLocation] = []
        for file in files(searchedFor: key) {
            guard let fileIndex = symbolIndex(of: file) else { continue }
            let found = fileIndex.occurrences(of: key).filter { includeDeclaration || $0.role != .declaration }
            out += locations(found, in: file)
        }
        return out
    }

    /// Every place in the open file where the name at a position occurs, with whether it is declared, read or
    /// assigned there.
    public func documentHighlights(at position: DeskPosition) -> [DeskHighlight] {
        guard let o = occurrence(at: position), let key = o.key else { return [] }
        return symbolIndex.occurrences(of: key).map { DeskHighlight(range: index.range(utf8: $0.range), role: $0.role) }
    }
}
