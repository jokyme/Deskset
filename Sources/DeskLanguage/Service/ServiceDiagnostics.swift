import Foundation

// Diagnostics as the editor shows them (§6.1): UTF-16 ranges with lines and columns, the message, notes and fix-it
// titles worded in the service's language, fix-its as workspace edits, and the range of what error isolation dropped
// (the Studio draws a dropped element as a ghost).

/// A secondary location of a diagnostic, worded.
public struct DeskServiceNote: Sendable, Hashable {
    /// Nil when the note points into a file the folder does not have.
    public var location: DeskLocation?
    public var message: String

    public init(location: DeskLocation?, message: String) {
        self.location = location
        self.message = message
    }
}

/// A one-click correction, worded, with its edits in UTF-16.
public struct DeskServiceFixIt: Sendable, Hashable {
    public var title: String
    public var edit: DeskWorkspaceEdit
    /// Fix-its with the same group form one "Fix all" action.
    public var group: String?

    public init(title: String, edit: DeskWorkspaceEdit, group: String?) {
        self.title = title
        self.edit = edit
        self.group = group
    }
}

/// What error isolation removed because of a diagnostic, and where it is.
public struct DeskDroppedUnit: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case modifier, element, field, option, action, declaration
    }
    public var kind: Kind
    public var location: DeskLocation

    public init(kind: Kind, location: DeskLocation) {
        self.kind = kind
        self.location = location
    }
}

/// A problem as the editor shows it.
public struct DeskServiceDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public var id: DiagnosticID
    public var severity: Severity
    /// The file `range` is in: the open file, or `package.desk` for a problem in a package style or option.
    public var file: DeskFileID
    public var range: DeskRange
    public var message: String
    public var notes: [DeskServiceNote]
    public var fixIts: [DeskServiceFixIt]
    public var dropped: DeskDroppedUnit?

    public init(id: DiagnosticID, severity: Severity, file: DeskFileID, range: DeskRange, message: String,
                notes: [DeskServiceNote] = [], fixIts: [DeskServiceFixIt] = [], dropped: DeskDroppedUnit? = nil) {
        self.id = id
        self.severity = severity
        self.file = file
        self.range = range
        self.message = message
        self.notes = notes
        self.fixIts = fixIts
        self.dropped = dropped
    }

    public var location: DeskLocation { DeskLocation(file: file, range: range) }
    /// 0-based, as the service counts.
    public var line: Int { range.start.line }
    /// 0-based UTF-16 column.
    public var column: Int { range.start.column }
    /// Errors and warnings are problems; an info is a tip, never counted (§6.1).
    public var isProblem: Bool { severity != .info }

    public var description: String {
        "\(id.rawValue) \(severity.rawValue) \(file.path):\(range.start) \(message)"
    }
}

/// How many problems and tips a file has.
public struct DeskProblemCount: Sendable, Hashable, CustomStringConvertible {
    public var errors = 0
    public var warnings = 0
    public var tips = 0

    public init(errors: Int = 0, warnings: Int = 0, tips: Int = 0) {
        self.errors = errors
        self.warnings = warnings
        self.tips = tips
    }

    /// Errors and warnings: the number the file-name menu shows.
    public var problems: Int { errors + warnings }

    mutating func add(_ severity: Severity) {
        switch severity {
        case .error: errors += 1
        case .warning: warnings += 1
        case .info: tips += 1
        }
    }

    public var description: String { "\(errors) errors, \(warnings) warnings, \(tips) tips" }
}

extension DeskSnapshot {
    /// The open file's diagnostics, in the checker's order: `diagnostics[i]` is `checked.diagnostics[i]`.
    public var diagnostics: [DeskServiceDiagnostic] {
        guard hasStackRoom else { return onLargeStack { diagnostics } }
        return caches.diagnostics.value { checked.diagnostics.map(serviceDiagnostic) }
    }

    /// `package.desk`'s own diagnostics when a widget is open (the package checked on its own); empty when the
    /// folder has no package or the open file is the package.
    public var packageDiagnostics: [DeskServiceDiagnostic] {
        guard hasStackRoom else { return onLargeStack { packageDiagnostics } }
        return caches.packageDiagnostics.value {
            guard let package, !isPackage else { return [] }
            return package.diagnostics.map(serviceDiagnostic)
        }
    }

    /// The problems of each file the open file's check and the package's own check found, for the file-name menu:
    /// the open file, and `package.desk` when it has any. The same problem found twice is counted once.
    public func problemCounts() -> [DeskFileID: DeskProblemCount] {
        var lists = [checked.diagnostics]
        if let package, !isPackage { lists.append(package.diagnostics) }
        var counts = Self.count(lists)
        if counts[file] == nil { counts[file] = DeskProblemCount() }
        return counts
    }

    /// The problems of every file of the folder (checks the other widgets: `folderResults`).
    public func folderProblemCounts() -> [DeskFileID: DeskProblemCount] {
        let results = folderResults()
        var counts = Self.count(results.keys.sorted { $0.path < $1.path }.map { results[$0]!.diagnostics })
        for file in results.keys where counts[file] == nil { counts[file] = DeskProblemCount() }
        return counts
    }

    /// The diagnostics of another widget of the folder (checks the other widgets: `folderResults`).
    public func folderDiagnostics(of file: DeskFileID) -> [DeskServiceDiagnostic] {
        guard hasStackRoom else { return onLargeStack { folderDiagnostics(of: file) } }
        if file == self.file && !isPackage { return diagnostics }
        return folderResults()[file]?.diagnostics.map(serviceDiagnostic) ?? []
    }

    /// Every fix-it of `group` in the open file's diagnostics, as one edit ("Fix all"); edits that would overlap an
    /// earlier one are left out.
    public func fixAll(group: String) -> DeskWorkspaceEdit {
        guard hasStackRoom else { return onLargeStack { fixAll(group: group) } }
        var files: [DeskFileID: [DeskTextEditU16]] = [:]
        for d in diagnostics {
            for fix in d.fixIts where fix.group == group {
                for (file, edits) in fix.edit.files { files[file, default: []] += edits }
            }
        }
        return DeskWorkspaceEdit(files)
    }

    /// A checker diagnostic in UTF-16, worded in the snapshot's language.
    public func serviceDiagnostic(_ d: Diagnostic) -> DeskServiceDiagnostic {
        let language = options.messageLanguage
        let catalog = options.catalog
        let range = index(of: d.file)?.range(utf8: d.range) ?? index.range(utf16: 0..<0)
        let notes = d.notes.map { note in
            DeskServiceNote(location: location(file: note.file, utf8: note.range),
                            message: note.message(in: language, catalog: catalog))
        }
        let fixIts = d.fixIts.compactMap { fix -> DeskServiceFixIt? in
            guard let edit = workspaceEdit(fix.edits) else { return nil }
            return DeskServiceFixIt(title: fix.title(in: language, catalog: catalog), edit: edit, group: fix.group)
        }
        var dropped: DeskDroppedUnit?
        if let unit = d.dropped {
            let (kind, id) = Self.split(unit)
            if let location = location(of: id) { dropped = DeskDroppedUnit(kind: kind, location: location) }
        }
        return DeskServiceDiagnostic(id: d.id, severity: d.severity, file: d.file, range: range,
                                     message: d.message(in: language, catalog: catalog), notes: notes, fixIts: fixIts,
                                     dropped: dropped)
    }

    /// Checker edits (UTF-8, per file) as a workspace edit; nil when an edit is in a file the folder does not have.
    public func workspaceEdit(_ edits: [TextEdit]) -> DeskWorkspaceEdit? {
        var files: [DeskFileID: [DeskTextEditU16]] = [:]
        for edit in edits {
            guard let index = index(of: edit.file) else { return nil }
            files[edit.file, default: []].append(DeskTextEditU16(range: index.range(utf8: edit.range),
                                                                  newText: edit.replacement))
        }
        return DeskWorkspaceEdit(files)
    }

    static func split(_ unit: DroppedUnit) -> (DeskDroppedUnit.Kind, NodeID) {
        switch unit {
        case .modifier(let id): return (.modifier, id)
        case .element(let id): return (.element, id)
        case .field(let id): return (.field, id)
        case .option(let id): return (.option, id)
        case .action(let id): return (.action, id)
        case .declarationPoisoned(let id): return (.declaration, id)
        }
    }

    static func count(_ lists: [[Diagnostic]]) -> [DeskFileID: DeskProblemCount] {
        // Two checks see a problem of package.desk alike: same file, id, range and arguments. Only a copy found by
        // an earlier check is left out.
        var earlier = Set<String>()
        var counts: [DeskFileID: DeskProblemCount] = [:]
        for list in lists {
            var keys: [String] = []
            for d in list {
                let key = "\(d.file.path)|\(d.description)"
                keys.append(key)
                guard !earlier.contains(key) else { continue }
                counts[d.file, default: DeskProblemCount()].add(d.severity)
            }
            earlier.formUnion(keys)
        }
        return counts
    }
}
