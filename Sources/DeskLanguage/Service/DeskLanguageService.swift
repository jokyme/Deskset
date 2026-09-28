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
    /// Increases with every change that needs a new check of the open file (its text, `package.desk`, the folder,
    /// the options): a check begun before the latest such change is dropped (`accept`).
    private var checkGeneration = 0
    /// What sharing subtrees kept at the last update, and over all updates (tests and the latency report read them).
    public private(set) var lastReuse: SubtreeReuseStats?
    public private(set) var totalReuse = SubtreeReuseStats()
    /// The other widgets' checks, shared by the snapshots: reused while a widget's text and `package.desk`'s tree
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
        // `package.desk` as the folder spells it (`Package.desk`: a Mac finds names without regard to case).
        let exact = DeskFileID(path: folder.isEmpty ? DeskPackage.packageFileName : folder + "/" + DeskPackage.packageFileName)
        let spelled = files.keys.filter {
            ($0.path as NSString).deletingLastPathComponent == folder
                && DeskPackagePath.isPackageFile(($0.path as NSString).lastPathComponent)
        }.min { DeskPackagePath.precedes($0.path, $1.path) }
        packageFile = files[exact] != nil ? exact : spelled ?? exact
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
        return replaceText(applying(changes), version: version)
    }

    /// Replaces the whole open text and re-checks.
    @discardableResult
    public func replaceText(_ text: String, version: Int) -> DeskSnapshot {
        checkGeneration += 1
        snapshot = makeSnapshot(tree: reparse(text), version: version)
        return snapshot
    }

    /// The open text with the changes applied.
    private func applying(_ changes: [DeskTextChange]) -> String {
        var bytes = snapshot.index.bytes
        var index = snapshot.index
        for (k, change) in changes.enumerated() {
            if k > 0 { index = DeskTextIndex(bytes: bytes) }
            let lower = index.utf8Offset(ofUTF16: change.range.lowerBound)
            let upper = max(lower, index.utf8Offset(ofUTF16: change.range.upperBound))
            bytes.replaceSubrange(lower..<upper, with: Array(change.text.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The new text parsed in full, with the subtrees it shares with the current tree taken from it
    /// (`SubtreeReuse`): equal to `Desk.parse` in every node, and the top-level blocks the edit did not touch are
    /// the same objects, so what the snapshot kept for them can be used again.
    private func reparse(_ text: String) -> SyntaxTree {
        let fresh = Desk.parse(text, file: openFile)
        let old = snapshot.index.bytes
        let new = fresh.lines.bytes
        let (tree, stats) = SubtreeReuse.share(fresh, previous: snapshot.tree, edit: SyntaxTextEdit.between(old, new),
                                               newBytes: new, oldBytes: old)
        lastReuse = stats
        totalReuse.add(stats)
        return tree
    }

    // MARK: Checking in the background

    /// Begins an update whose check runs elsewhere: the text is parsed now and a snapshot with only the syntax
    /// results (the tree's diagnostics, highlighting without the checker's names, folding) is published at once;
    /// the check is `DeskPendingCheck.run()`, on any queue; its result is published with `accept`, on this service's
    /// queue, unless a later change came first.
    public func beginUpdate(changes: [DeskTextChange], version: Int) -> DeskPendingCheck {
        beginReplacing(changes.isEmpty ? snapshot.text : applying(changes), version: version)
    }

    /// `beginUpdate` with the whole new text.
    public func beginReplacing(_ text: String, version: Int) -> DeskPendingCheck {
        checkGeneration += 1
        let tree = reparse(text)
        let state = isEditingPackage ? nil : currentPackageState()
        let syntax = CheckedFile(syntaxOf: tree, context: options.checkContext(package: state?.wrapped, resources: resources))
        snapshot = publish(tree: tree, version: version, checked: syntax, isChecked: false, state: state)
        return DeskPendingCheck(generation: checkGeneration, snapshot: snapshot, options: options, resources: resources,
                                package: state?.wrapped, isEditingPackage: isEditingPackage)
    }

    /// Publishes a check `run()` finished, unless a change since its update made it stale (then nil: it is dropped).
    @discardableResult
    public func accept(_ result: DeskCheckedText) -> DeskSnapshot? {
        guard result.generation == checkGeneration, result.tree.version == snapshot.tree.version else { return nil }
        let state = isEditingPackage ? nil : currentPackageState()
        snapshot = publish(tree: result.tree, version: snapshot.version, checked: result.checked, isChecked: true, state: state)
        return snapshot
    }

    /// Applies the changes; a text of at least `options.backgroundCheckBytes` is checked in the background: the
    /// snapshot returned has only the syntax results, the check runs on `queue`, and its snapshot is published and
    /// given to `completion` on `owner` (this service's queue), unless a later change came first. A smaller text is
    /// checked at once: the snapshot returned is checked and `completion` is not called.
    @discardableResult
    public func update(changes: [DeskTextChange], version: Int, checkingOn queue: DispatchQueue, deliverOn owner: DispatchQueue,
                       completion: @escaping (DeskSnapshot) -> Void) -> DeskSnapshot {
        let text = changes.isEmpty ? snapshot.text : applying(changes)
        guard text.utf8.count >= options.backgroundCheckBytes else { return replaceText(text, version: version) }
        let pending = beginReplacing(text, version: version)
        queue.async {
            let result = pending.run()
            owner.async { [weak self] in
                guard let self, let snapshot = self.accept(result) else { return }
                completion(snapshot)
            }
        }
        return pending.snapshot
    }

    /// Another file of the folder changed (nil: it was removed). A change to `package.desk` re-checks the open file
    /// with it; a change to another widget only replaces its text. The open file's text is changed with `update` or
    /// `replaceText`, never here.
    @discardableResult
    public func setText(_ text: String?, of file: DeskFileID) -> DeskSnapshot {
        guard file != openFile, otherFiles[file] != text else { return snapshot }
        otherFiles[file] = text
        if file == packageFile { checkGeneration += 1 }
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
        checkGeneration += 1
        snapshot = makeSnapshot(tree: snapshot.tree, version: snapshot.version)
        return snapshot
    }

    /// New options: everything is checked again, and nothing kept for the previous options is used.
    @discardableResult
    public func setOptions(_ options: DeskServiceOptions) -> DeskSnapshot {
        self.options = options
        packageState = nil
        siblings = DeskSiblingChecks()
        checkGeneration += 1
        forgetsBlocks = true
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

    /// Set by `setOptions`: the next snapshot keeps nothing of the blocks of the snapshots before it.
    private var forgetsBlocks = false

    private func makeSnapshot(tree: SyntaxTree, version: Int, recheck: Bool = true) -> DeskSnapshot {
        let state = isEditingPackage ? nil : currentPackageState()
        let fresh = recheck || snapshot.isPlaceholder
        let checked = fresh
            ? Desk.check(tree, context: options.checkContext(package: state?.wrapped, resources: resources))
            : snapshot.checked
        return publish(tree: tree, version: version, checked: checked, isChecked: fresh || snapshot.isChecked, state: state)
    }

    private func publish(tree: SyntaxTree, version: Int, checked: CheckedFile, isChecked: Bool, state: PackageState?) -> DeskSnapshot {
        generation += 1
        let index = tree.version == snapshot.tree.version ? snapshot.index : DeskTextIndex(tree: tree)
        var folder = otherFiles
        folder[openFile] = tree.text
        let memo = DeskBlockMemo(carrying: forgetsBlocks || snapshot.isPlaceholder ? nil : snapshot.memo, into: tree)
        forgetsBlocks = false
        if isEditingPackage {
            return DeskSnapshot(version: version, generation: generation, file: openFile, tree: tree,
                                checked: checked, index: index, options: options, packageFile: packageFile,
                                package: checked, packageIndex: index, folder: folder, resources: resources,
                                model: package, siblings: siblings, memo: memo, isChecked: isChecked)
        }
        return DeskSnapshot(version: version, generation: generation, file: openFile, tree: tree, checked: checked,
                            index: index, options: options, packageFile: packageFile, package: state?.checked,
                            packageIndex: state?.index, folder: folder, resources: resources, model: package,
                            siblings: siblings, memo: memo, isChecked: isChecked)
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
/// result computed from it on any thread stays true for its `version`. Its requests may be asked from several
/// threads at once (what they build is kept under locks); a request on a thread whose stack is too small for the
/// tree's nesting runs on a thread with a larger one (`StackSafety.swift`).
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
    /// What this snapshot and the ones before it worked out per top-level block.
    let memo: DeskBlockMemo
    let isPlaceholder: Bool
    /// False for the first snapshot of an update checked in the background (`DeskLanguageService.beginUpdate`):
    /// it has only the syntax results (the tree's diagnostics, and no names, types or elements from the checker).
    public let isChecked: Bool

    init(version: Int, generation: Int, file: DeskFileID, tree: SyntaxTree, checked: CheckedFile, index: DeskTextIndex,
         options: DeskServiceOptions, packageFile: DeskFileID, package: CheckedFile?, packageIndex: DeskTextIndex?,
         folder: [DeskFileID: String], resources: ResourceResolving?, model: DeskPackage? = nil,
         siblings: DeskSiblingChecks? = nil, memo: DeskBlockMemo = DeskBlockMemo(), isChecked: Bool = true,
         isPlaceholder: Bool = false) {
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
        self.memo = memo
        self.isChecked = isChecked
        self.isPlaceholder = isPlaceholder
    }

    static func placeholder(file: DeskFileID, options: DeskServiceOptions) -> DeskSnapshot {
        let tree = Desk.parse("", file: file)
        let checked = CheckedFile(syntaxOf: tree, diagnostics: [])
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
        guard hasStackRoom else { return onLargeStack { folderResults() } }
        return caches.folder.value {
            let context = options.checkContext(package: nil, resources: resources)
            // A widget's check names the package's styles and options by nodes of the package's tree: it is reused
            // only with that very tree, not with another parse of the same text.
            let packageTree = package?.tree
            let packageVersion = packageTree?.version
            var widgets: [(tree: SyntaxTree, checked: CheckedFile?)] = []
            if !isPackage { widgets.append((tree, checked)) }
            for (file, text) in folder.sorted(by: { $0.key.path < $1.key.path })
                where file != self.file && file != packageFile && DeskPackagePath.isDeskFile(file.path) {
                if let known = siblings?.checked(file, text: text, packageVersion: packageVersion) {
                    widgets.append((known.tree, known))
                } else {
                    widgets.append((Desk.parse(text, file: file), nil))
                }
            }
            let results = Desk.checkFolder(package: packageTree, checkedPackage: package, widgets: widgets, context: context)
            for (file, text) in folder where file != self.file && file != packageFile {
                if let result = results[file] { siblings?.store(file, text: text, packageVersion: packageVersion, checked: result) }
            }
            return results
        }
    }

    /// The folder checked as a whole: every file's results (`folderResults`), the folder checks (DK86xx), the
    /// cross-file index, and from it the languages, options panels and install summary. The folder is the one the
    /// service was made with, holding this snapshot's texts; without one, a folder of just the `.desk` texts.
    public func packageCheck() -> CheckedDeskPackage {
        guard hasStackRoom else { return onLargeStack { packageCheck() } }
        return caches.packageCheck.value {
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
    private var stored: [DeskFileID: (text: String, packageVersion: Int?, checked: CheckedFile)] = [:]

    /// The check of a widget with this text against this tree of `package.desk` (by its version; nil: no package),
    /// if it was made. A check made with another parse of the same package text is not reused: it names the
    /// package's styles and options by nodes of that other tree.
    func checked(_ file: DeskFileID, text: String, packageVersion: Int?) -> CheckedFile? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = stored[file], entry.text == text, entry.packageVersion == packageVersion else { return nil }
        return entry.checked
    }

    func store(_ file: DeskFileID, text: String, packageVersion: Int?, checked: CheckedFile) {
        lock.lock()
        defer { lock.unlock() }
        stored[file] = (text, packageVersion, checked)
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
    /// The UTF-8 ranges of the file's top-level children.
    let blockRanges = DeskLazy<[Range<Int>]>()
    /// The stack a request may need (`stackNeeded`).
    let stackNeeded = DeskLazy<Int>()
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

/// The check of an update that runs off the service's queue (`DeskLanguageService.beginUpdate`).
public final class DeskPendingCheck: @unchecked Sendable {
    /// The service's count of changes when the update began: a result is published only while it is the latest.
    public let generation: Int
    /// The snapshot published when the update began, with only the syntax results.
    public let snapshot: DeskSnapshot
    private let options: DeskServiceOptions
    private let resources: ResourceResolving?
    private let package: CheckedPackage?
    private let isEditingPackage: Bool
    private let lock = NSLock()
    private var result: DeskCheckedText?

    init(generation: Int, snapshot: DeskSnapshot, options: DeskServiceOptions, resources: ResourceResolving?,
         package: CheckedPackage?, isEditingPackage: Bool) {
        self.generation = generation
        self.snapshot = snapshot
        self.options = options
        self.resources = resources
        self.package = package
        self.isEditingPackage = isEditingPackage
    }

    /// Checks the text, on any queue; later calls return the first result. It reads only what the update captured.
    public func run() -> DeskCheckedText {
        lock.lock()
        defer { lock.unlock() }
        if let result { return result }
        let context = options.checkContext(package: isEditingPackage ? nil : package, resources: resources)
        let made = DeskCheckedText(generation: generation, tree: snapshot.tree, checked: Desk.check(snapshot.tree, context: context))
        result = made
        return made
    }
}

/// A finished check of a pending update, to give to `DeskLanguageService.accept`.
public struct DeskCheckedText: Sendable {
    public let generation: Int
    let tree: SyntaxTree
    let checked: CheckedFile
}

extension CheckedFile {
    /// A file with only what parsing found: the tree's diagnostics (or `diagnostics`), no names, types or elements.
    init(syntaxOf tree: SyntaxTree, diagnostics: [Diagnostic]? = nil) {
        self.init(tree: tree, diagnostics: diagnostics ?? tree.diagnostics, symbols: [:], types: [:], elements: [:],
                  dataUses: [], dependencies: [:], reactions: [], freeformOrders: [:], stringTable: [],
                  requirements: Requirements())
    }

    /// A file with only what parsing found, its diagnostics worded as a check words them: the parser leaves the
    /// Desk spelling of code written in another language's way to the checker (which fills it in from the catalog),
    /// and without it some messages would be empty. Fix-its that need the checked file (an option's name) come with
    /// the check. At most as many diagnostics as a check keeps.
    init(syntaxOf tree: SyntaxTree, context: CheckContext) {
        let checker = Checker(tree: tree, context: context)
        checker.enrichParserDiagnostics()
        var all = tree.diagnostics.map { checker.replacedParserDiagnostics[checker.diagnosticKey($0)] ?? $0 }
        let limit = context.catalog.limits.maximumDiagnosticsPerFile
        if all.count > limit, limit > 0 {
            let last = all[limit - 1]
            all = Array(all.prefix(limit)) + [Diagnostic(id: .tooManyProblems, severity: .info, file: tree.file, range: last.range,
                                                         arguments: ["count": .number(all.count - limit)])]
        }
        self.init(syntaxOf: tree, diagnostics: all)
    }
}
