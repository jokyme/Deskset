import Foundation

/// The language service of one open `.desk` file: it holds the file's text with the folder's other `.desk` texts,
/// takes the text view's changes, and publishes each result as an immutable `DeskSnapshot` that answers the editor's
/// questions in UTF-16 positions.
///
/// Not thread-safe: one queue owns it (the main queue for small files, a background queue for large ones). Its
/// snapshots are `Sendable` and may be read anywhere. Every update re-parses and re-checks the open file only;
/// `package.desk` is parsed and checked once and reused until its own text changes, and the other widgets of the
/// folder are checked only when a snapshot is asked for the folder (`DeskSnapshot.folderResults`).
public final class DeskLanguageService {
    /// The open file, as a path relative to the widget folder.
    public let openFile: DeskFileID
    /// The folder's `package.desk` (next to the open file), whether or not it exists yet.
    public let packageFile: DeskFileID
    public private(set) var resources: ResourceResolving?
    /// The folder the open file belongs to, when the service was made with one (`init(package:openFile:)`): its
    /// pictures, fonts and what loading found. Its texts are those it was made with; a snapshot's `packageCheck()`
    /// uses the snapshot's texts.
    public private(set) var package: DeskPackage?
    public private(set) var options: DeskServiceOptions
    /// The latest snapshot.
    public private(set) var snapshot: DeskSnapshot

    /// The texts of every `.desk` file of the folder but the open one.
    public private(set) var otherFiles: [DeskFileID: String]
    private var packageState: PackageState?
    private var generation = 0
    /// The other widgets' checks, shared by the snapshots: reused while a widget's text and `package.desk`'s text
    /// are unchanged, so editing `package.desk` checks every widget again and editing a widget checks no other.
    private var siblings = DeskSiblingChecks()

    /// How many times `package.desk` was parsed and checked on its own (tests read it).
    private(set) var packageChecks = 0

    /// `package.desk` parsed and checked on its own, kept while its text and the options are unchanged.
    struct PackageState {
        var text: String
        var checked: CheckedFile
        var index: DeskTextIndex
        var wrapped: CheckedPackage
    }

    /// - Parameters:
    ///   - openFile: the file being edited; its text is `files[openFile]` (empty when absent).
    ///   - files: the `.desk` texts of the folder, the open file's included.
    ///   - version: the text view's version of the open text, given back in each snapshot.
    public convenience init(openFile: DeskFileID, files: [DeskFileID: String], resources: ResourceResolving? = nil,
                            options: DeskServiceOptions = DeskServiceOptions(), version: Int = 0) {
        self.init(openFile: openFile, files: files, resources: resources, options: options, version: version, package: nil)
    }

    private init(openFile: DeskFileID, files: [DeskFileID: String], resources: ResourceResolving?,
                 options: DeskServiceOptions, version: Int, package: DeskPackage?) {
        self.openFile = openFile
        self.package = package
        let folder = (openFile.path as NSString).deletingLastPathComponent
        packageFile = DeskFileID(path: folder.isEmpty ? "package.desk" : folder + "/package.desk")
        self.resources = resources
        self.options = options
        var others = files
        let text = others.removeValue(forKey: openFile) ?? ""
        otherFiles = others
        // A placeholder until the first real snapshot is made below.
        snapshot = DeskSnapshot.placeholder(file: openFile, options: options)
        snapshot = makeSnapshot(tree: Desk.parse(text, file: openFile), version: version)
    }

    /// A service for a file of a loaded folder: the folder's `.desk` texts and its pictures and fonts as resources.
    public convenience init(package: DeskPackage, openFile: DeskFileID, options: DeskServiceOptions = DeskServiceOptions(),
                            version: Int = 0) {
        self.init(openFile: openFile, files: package.texts, resources: PackageResources(package: package), options: options,
                  version: version, package: package)
    }

    /// The open file is `package.desk`.
    public var isEditingPackage: Bool { openFile == packageFile }

    /// The open text.
    public var text: String { snapshot.text }

    // MARK: Updates

    /// Applies the text view's changes in order (each range is in the text the changes before it left) and
    /// re-checks. A range is clamped to the text and to scalar boundaries.
    @discardableResult
    public func update(changes: [DeskTextChange], version: Int) -> DeskSnapshot {
        if changes.isEmpty {
            snapshot = makeSnapshot(tree: snapshot.tree, version: version, recheck: false)
            return snapshot
        }
        var bytes = snapshot.index.bytes
        var index = snapshot.index
        for (k, change) in changes.enumerated() {
            if k > 0 { index = DeskTextIndex(bytes: bytes) }
            let lower = index.utf8Offset(ofUTF16: change.range.lowerBound)
            let upper = max(lower, index.utf8Offset(ofUTF16: change.range.upperBound))
            bytes.replaceSubrange(lower..<upper, with: Array(change.text.utf8))
        }
        return replaceText(String(decoding: bytes, as: UTF8.self), version: version)
    }

    /// Replaces the whole open text and re-checks.
    @discardableResult
    public func replaceText(_ text: String, version: Int) -> DeskSnapshot {
        snapshot = makeSnapshot(tree: Desk.parse(text, file: openFile), version: version)
        return snapshot
    }

    /// Another file of the folder changed (nil: it was removed). A change to `package.desk` re-checks the open file
    /// with it; a change to another widget only replaces its text. The open file's text is changed with `update` or
    /// `replaceText`, never here.
    @discardableResult
    public func setText(_ text: String?, of file: DeskFileID) -> DeskSnapshot {
        guard file != openFile, otherFiles[file] != text else { return snapshot }
        otherFiles[file] = text
        snapshot = makeSnapshot(tree: snapshot.tree, version: snapshot.version, recheck: file == packageFile)
        return snapshot
    }

    /// The folder changed on disk (a picture added, a widget removed): its other `.desk` texts, pictures and fonts
    /// are taken from `package`; the open file keeps its text. Everything is checked again.
    @discardableResult
    public func setPackage(_ package: DeskPackage) -> DeskSnapshot {
        self.package = package
        resources = PackageResources(package: package)
        var others = package.texts
        others[openFile] = nil
        otherFiles = others
        packageState = nil
        siblings = DeskSiblingChecks()
        snapshot = makeSnapshot(tree: snapshot.tree, version: snapshot.version)
        return snapshot
    }

    /// New options: everything is checked again.
    @discardableResult
    public func setOptions(_ options: DeskServiceOptions) -> DeskSnapshot {
        self.options = options
        packageState = nil
        siblings = DeskSiblingChecks()
        snapshot = makeSnapshot(tree: snapshot.tree, version: snapshot.version)
        return snapshot
    }

    /// Another message language: messages are worded again; nothing is checked again.
    @discardableResult
    public func setMessageLanguage(_ language: DiagnosticLanguage) -> DeskSnapshot {
        options.messageLanguage = language
        snapshot = makeSnapshot(tree: snapshot.tree, version: snapshot.version, recheck: false)
        return snapshot
    }

    // MARK: Snapshots

    private func makeSnapshot(tree: SyntaxTree, version: Int, recheck: Bool = true) -> DeskSnapshot {
        generation += 1
        let index = tree.version == snapshot.tree.version ? snapshot.index : DeskTextIndex(tree: tree)
        var folder = otherFiles
        folder[openFile] = tree.text
        if isEditingPackage {
            let checked = recheck || snapshot.isPlaceholder
                ? Desk.check(tree, context: options.checkContext(package: nil, resources: resources))
                : snapshot.checked
            return DeskSnapshot(version: version, generation: generation, file: openFile, tree: tree,
                                checked: checked, index: index, options: options, packageFile: packageFile,
                                package: checked, packageIndex: index, folder: folder, resources: resources,
                                model: package, siblings: siblings)
        }
        let state = currentPackageState()
        let checked = recheck || snapshot.isPlaceholder
            ? Desk.check(tree, context: options.checkContext(package: state?.wrapped, resources: resources))
            : snapshot.checked
        return DeskSnapshot(version: version, generation: generation, file: openFile, tree: tree, checked: checked,
                            index: index, options: options, packageFile: packageFile, package: state?.checked,
                            packageIndex: state?.index, folder: folder, resources: resources, model: package,
                            siblings: siblings)
    }

    /// `package.desk` checked on its own, reused while its text is the same.
    private func currentPackageState() -> PackageState? {
        guard let text = otherFiles[packageFile] else {
            packageState = nil
            return nil
        }
        if let packageState, packageState.text == text { return packageState }
        let tree = Desk.parse(text, file: packageFile)
        let checked = Desk.check(tree, context: options.checkContext(package: nil, resources: resources))
        packageChecks += 1
        let state = PackageState(text: text, checked: checked, index: DeskTextIndex(tree: tree),
                                 wrapped: CheckedPackage(file: checked))
        packageState = state
        return state
    }
}

/// One state of the open file: its text, tree, checked model and position index, with what the editor asks of it
/// built on first use and kept. Immutable and `Sendable`: a snapshot never changes after the service made it, so a
/// result computed from it on any thread stays true for its `version`.
public final class DeskSnapshot: Sendable {
    /// The text view's version of the text, as given to the service.
    public let version: Int
    /// Increases with every snapshot of the service (a new check of the same text also counts).
    public let generation: Int
    public let file: DeskFileID
    public let tree: SyntaxTree
    /// The open file checked with the folder's `package.desk` (or on its own when it is `package.desk`).
    public let checked: CheckedFile
    public let index: DeskTextIndex
    public let options: DeskServiceOptions
    /// Where the folder's `package.desk` is (next to the open file), whether or not it exists.
    public let packageFile: DeskFileID
    /// `package.desk` checked on its own; when the open file is `package.desk`, the same as `checked`.
    public let package: CheckedFile?
    let packageIndex: DeskTextIndex?
    /// Every `.desk` text of the folder at this snapshot, the open file's included.
    public let folder: [DeskFileID: String]
    let resources: ResourceResolving?
    /// The folder the service was made with, if any.
    let model: DeskPackage?
    let siblings: DeskSiblingChecks?
    let caches = DeskSnapshotCaches()
    let isPlaceholder: Bool

    init(version: Int, generation: Int, file: DeskFileID, tree: SyntaxTree, checked: CheckedFile, index: DeskTextIndex,
         options: DeskServiceOptions, packageFile: DeskFileID, package: CheckedFile?, packageIndex: DeskTextIndex?,
         folder: [DeskFileID: String], resources: ResourceResolving?, model: DeskPackage? = nil,
         siblings: DeskSiblingChecks? = nil, isPlaceholder: Bool = false) {
        self.version = version
        self.generation = generation
        self.file = file
        self.tree = tree
        self.checked = checked
        self.index = index
        self.options = options
        self.packageFile = packageFile
        self.package = package
        self.packageIndex = packageIndex
        self.folder = folder
        self.resources = resources
        self.model = model
        self.siblings = siblings
        self.isPlaceholder = isPlaceholder
    }

    static func placeholder(file: DeskFileID, options: DeskServiceOptions) -> DeskSnapshot {
        let tree = Desk.parse("", file: file)
        let checked = CheckedFile(tree: tree, diagnostics: [], symbols: [:], types: [:], elements: [:], dataUses: [],
                                  dependencies: [:], reactions: [], freeformOrders: [:], stringTable: [],
                                  requirements: Requirements())
        return DeskSnapshot(version: 0, generation: 0, file: file, tree: tree, checked: checked,
                            index: DeskTextIndex(tree: tree), options: options, packageFile: file, package: nil,
                            packageIndex: nil, folder: [:], resources: nil, isPlaceholder: true)
    }

    /// The open text.
    public var text: String { tree.text }

    /// The open file is `package.desk`.
    public var isPackage: Bool { file == packageFile }

    /// The position index of a file of the folder (nil when the folder has no such file).
    public func index(of file: DeskFileID) -> DeskTextIndex? {
        if file == self.file { return index }
        if file == packageFile, let packageIndex { return packageIndex }
        guard let text = folder[file] else { return nil }
        return caches.fileIndexes.value(for: file) { DeskTextIndex(text) }
    }

    /// A UTF-8 range of a file of the folder as a location (nil when the folder has no such file).
    public func location(file: DeskFileID, utf8 range: Range<Int>) -> DeskLocation? {
        guard let index = index(of: file) else { return nil }
        return DeskLocation(file: file, range: index.range(utf8: range))
    }

    /// The trees a node reference may belong to: the open file's, the package's, and the folder's once checked.
    func tree(of id: NodeID) -> SyntaxTree? {
        if id.treeVersion == tree.version { return tree }
        if let package, id.treeVersion == package.tree.version { return package.tree }
        if let folder = caches.folder.peek() {
            return folder.values.first { $0.tree.version == id.treeVersion }?.tree
        }
        return nil
    }

    /// Where a node of one of the snapshot's trees is, its text without trivia.
    public func location(of id: NodeID) -> DeskLocation? {
        guard let tree = tree(of: id), let node = tree.quickResolve(id) else { return nil }
        return location(file: tree.file, utf8: node.quickTextRange)
    }

    /// Every widget of the folder checked with the package, and the package with what only the whole folder can
    /// know (§4.20). Built on first use: the open file's and the package's results are reused, the other widgets
    /// are parsed and checked.
    public func folderResults() -> [DeskFileID: CheckedFile] {
        caches.folder.value {
            let context = options.checkContext(package: nil, resources: resources)
            let packageText = folder[packageFile]
            var widgets: [(tree: SyntaxTree, checked: CheckedFile?)] = []
            if !isPackage { widgets.append((tree, checked)) }
            for (file, text) in folder.sorted(by: { $0.key.path < $1.key.path })
                where file != self.file && file != packageFile && file.path.hasSuffix(".desk") {
                if let known = siblings?.checked(file, text: text, packageText: packageText) {
                    widgets.append((known.tree, known))
                } else {
                    widgets.append((Desk.parse(text, file: file), nil))
                }
            }
            let packageTree = package?.tree
            let results = Desk.checkFolder(package: packageTree, checkedPackage: package, widgets: widgets, context: context)
            for (file, text) in folder where file != self.file && file != packageFile {
                if let result = results[file] { siblings?.store(file, text: text, packageText: packageText, checked: result) }
            }
            return results
        }
    }

    /// The folder checked as a whole: every file's results (`folderResults`), the folder checks (DK86xx), the
    /// cross-file index, and from it the languages, options panels and install summary. The folder is the one the
    /// service was made with, holding this snapshot's texts; without one, a folder of just the `.desk` texts.
    public func packageCheck() -> CheckedDeskPackage {
        caches.packageCheck.value {
            var model = self.model ?? DeskPackage()
            for (file, text) in folder where model.texts[file] != text {
                model = model.settingText(text, of: file)
            }
            for file in model.texts.keys where folder[file] == nil {
                model = model.settingText(nil, of: file)
            }
            return CheckedDeskPackage(package: model, results: folderResults(), catalog: options.catalog)
        }
    }
}

/// The other widgets' checks, shared by a service's snapshots (each snapshot may be read on any thread).
final class DeskSiblingChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DeskFileID: (text: String, packageText: String?, checked: CheckedFile)] = [:]

    /// The check of a widget with this text against this `package.desk` text, if it was made.
    func checked(_ file: DeskFileID, text: String, packageText: String?) -> CheckedFile? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = stored[file], entry.text == text, entry.packageText == packageText else { return nil }
        return entry.checked
    }

    func store(_ file: DeskFileID, text: String, packageText: String?, checked: CheckedFile) {
        lock.lock()
        defer { lock.unlock() }
        stored[file] = (text, packageText, checked)
    }

    /// How many widgets have a stored check (tests read it).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }
}

/// Values a snapshot builds on first use, each behind its own lock.
final class DeskSnapshotCaches: @unchecked Sendable {
    let diagnostics = DeskLazy<[DeskServiceDiagnostic]>()
    let packageDiagnostics = DeskLazy<[DeskServiceDiagnostic]>()
    let formatEdits = DeskLazy<[TextEdit]>()
    let folder = DeskLazy<[DeskFileID: CheckedFile]>()
    let packageCheck = DeskLazy<CheckedDeskPackage>()
    let fileIndexes = DeskLazyMap<DeskFileID, DeskTextIndex>()
    let nodeTable = DeskLazy<DeskNodeTable>()
    let symbolIndexes = DeskLazyMap<DeskFileID, DeskSymbolIndex>()
    let outline = DeskLazy<[DeskDocumentSymbol]>()
    let folding = DeskLazy<[DeskFoldingRange]>()
    let semanticFacts = DeskLazy<DeskSemanticFacts>()
    /// By the index of the top-level child of the file.
    let semanticBlocks = DeskLazyMap<Int, DeskSemanticBlock>()
    let semanticTokens = DeskLazy<DeskSemanticTokens>()
    let tokenTable = DeskLazy<DeskTokenTable>()
}

/// A value built once, on first use, under a lock (a second reader waits for the first).
final class DeskLazy<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func value(_ make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let stored { return stored }
        let made = make()
        stored = made
        return made
    }

    /// The value if it was built.
    func peek() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Values built once per key, on first use, under a lock.
final class DeskLazyMap<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Key: Value] = [:]

    func value(for key: Key, _ make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value = stored[key] { return value }
        let made = make()
        stored[key] = made
        return made
    }

    /// The value for a key if it was built.
    func peek(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored[key]
    }

    /// How many values were built (tests read it).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }
}
