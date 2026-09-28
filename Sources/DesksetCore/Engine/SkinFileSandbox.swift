import Foundation

/// A private copy of the files a skin changes, for an instance of a widget that must not change the widget's files while
/// another instance runs them — the Studio's own instance, next to the widget on the desktop, which does everything for
/// real — or a run that must leave the Mac alone. It is the file half of `RecordingSideEffects`. What its scripts write
/// (`io.open` for writing, `io.output`, `os.remove`, `os.rename`), what its WebParser measures download to a
/// `DownloadFile` or dump, RunCommand's `OutputFile` and `!WriteKeyValue` go to a scratch folder instead; reading a
/// file it wrote or removed sees its copy, every other file is read where it is. Each change is recorded (`records`,
/// `onRecord`), as the bangs the instance does not run are.
///
/// A file under one of the `roots` (the Skins folder, the settings folder) keeps its place in a copy of that tree
/// (`<directory>/<generation>/<root name>/<path in the root>`), so that the copies sit next to each other as the
/// files do; any other file is copied as `<number>-<name>`. A copy starts as the real file (a symbolic link's target)
/// when it is updated rather than written from nothing.
///
/// `reset` forgets the copies (a new instance starts from the real files, as the desktop copy does when it reloads).
/// Thread-safe: a download's destination is taken on the skin's thread and written on another.
public final class SkinFileSandbox {
    /// How a file is opened.
    public enum Access {
        /// Read as it is.
        case read
        /// Written from nothing (`w`, `w+`, `io.output`).
        case write
        /// Written keeping what it holds (`a`, `a+`, `r+`).
        case update
    }

    /// A change of the widget's files that was kept here.
    public struct Record: Equatable, CustomStringConvertible {
        /// `write`, `remove`, `rename`.
        public var operation: String
        public var path: String
        /// A rename's new path.
        public var target: String?

        public var description: String {
            switch operation {
            case "rename": return "os.rename \(path) \(target ?? "")"
            case "remove": return "os.remove \(path)"
            default: return "write \(path)"
            }
        }
    }

    /// Where the copies go (made on the first write, removed with the sandbox).
    public let directory: URL
    /// Trees whose files keep their place in the copy: a name for the tree's folder in the copy, and the real folder.
    public let roots: [(name: String, url: URL)]
    /// The changes kept here, oldest first (the last `limit`).
    public private(set) var records: [Record] = []
    public var limit = 100
    /// Told of each change kept here.
    public var onRecord: ((Record) -> Void)?

    private let lock = NSLock()
    /// The copies, by the real file's key (`key(_:)`).
    private var copies: [String: String] = [:]
    /// Files removed (or renamed away) in this copy.
    private var removed: Set<String> = []
    private var generation = 0
    private var serial = 0

    public init(directory: URL? = nil, roots: [(name: String, url: URL)] = []) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Deskset-Sandbox-\(UUID().uuidString)", isDirectory: true)
        self.roots = roots.map { ($0.name, $0.url.standardizedFileURL.resolvingSymlinksInPath()) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// The real file `path` names, compared the way the default Mac file system compares names.
    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    /// The path to open instead of `path` for `access`: its copy (made now for a write; for an update it starts as the
    /// real file), a path that is not there for a file removed here, else `path` itself.
    public func path(for path: String, access: Access) -> String {
        self.path(for: path, access: access, recording: true)
    }

    /// `path(for:access:)`; `recording` false keeps a write out of `records` (the caller records it its own way).
    func path(for path: String, access: Access, recording: Bool) -> String {
        let key = Self.key(path)
        lock.lock()
        defer { lock.unlock() }
        if access == .read {
            if let copy = copies[key] { return copy }
            if removed.contains(key) { return missingPath() }
            return path
        }
        if let copy = copies[key] {
            if recording { record(Record(operation: "write", path: path)) }
            return copy
        }
        let copy = newCopyPath(for: path)
        if access == .update, !removed.contains(key), FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.copyItem(atPath: Self.target(of: path), toPath: copy)
        }
        copies[key] = copy
        removed.remove(key)
        if recording { record(Record(operation: "write", path: path)) }
        return copy
    }

    /// The copy of `path` if a change was kept here (nil for a file removed here or never changed).
    public func copy(of path: String) -> String? {
        let key = Self.key(path)
        lock.lock()
        defer { lock.unlock() }
        return copies[key]
    }

    /// Whether `path` lies in this sandbox's own folder (a copy, or a file of its scratch space).
    public func contains(_ path: String) -> Bool {
        let own = Self.key(directory.path)
        let key = Self.key(path)
        return key == own || key.hasPrefix(own + "/")
    }

    /// `path` for writing a whole file (a download).
    public func url(forWriting url: URL) -> URL {
        URL(fileURLWithPath: path(for: url.path, access: .write))
    }

    /// `os.remove`: the file goes from this copy only. False when there was nothing to remove.
    public func remove(_ path: String) -> Bool {
        let key = Self.key(path)
        lock.lock()
        defer { lock.unlock() }
        guard exists(key: key, path: path) else { return false }
        if let copy = copies.removeValue(forKey: key) { try? FileManager.default.removeItem(atPath: copy) }
        removed.insert(key)
        record(Record(operation: "remove", path: path))
        return true
    }

    /// `os.rename`: the file takes its new name in this copy only. False when there was nothing to rename.
    public func rename(_ from: String, to: String) -> Bool {
        let fromKey = Self.key(from), toKey = Self.key(to)
        lock.lock()
        defer { lock.unlock() }
        guard exists(key: fromKey, path: from) else { return false }
        guard fromKey != toKey else { return true }
        // The old copy of the new name goes first: a file in a root's tree has the same copy path every time.
        if let old = copies.removeValue(forKey: toKey) { try? FileManager.default.removeItem(atPath: old) }
        let copy = newCopyPath(for: to)
        if let source = copies.removeValue(forKey: fromKey) {
            try? FileManager.default.moveItem(atPath: source, toPath: copy)
        } else {
            try? FileManager.default.copyItem(atPath: Self.target(of: from), toPath: copy)
        }
        copies[toKey] = copy
        removed.remove(toKey)
        removed.insert(fromKey)
        record(Record(operation: "rename", path: from, target: to))
        return true
    }

    /// Forgets the copies: from now on the real files are read again. The records stay.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        copies = [:]
        removed = []
        let old = generationDirectory
        generation += 1
        try? FileManager.default.removeItem(at: old)
    }

    public func clearRecords() {
        lock.lock()
        records = []
        lock.unlock()
    }

    /// Whether a change was kept here for `path` (its copy, or its removal).
    public func holdsChange(of path: String) -> Bool {
        let key = Self.key(path)
        lock.lock()
        defer { lock.unlock() }
        return copies[key] != nil || removed.contains(key)
    }

    // MARK: Private

    private var generationDirectory: URL { directory.appendingPathComponent("\(generation)", isDirectory: true) }

    private func exists(key: String, path: String) -> Bool {
        if let copy = copies[key] { return FileManager.default.fileExists(atPath: copy) }
        return !removed.contains(key) && FileManager.default.fileExists(atPath: path)
    }

    /// A new file in the scratch folder: in the copy of its root's tree, else named after `path`'s last part.
    private func newCopyPath(for path: String) -> String {
        let real = Self.target(of: path)
        let lowered = real.lowercased()
        for root in roots {
            // Compared the way the default Mac file system compares names.
            let rootPath = root.url.path
            guard lowered.hasPrefix(rootPath.lowercased() + "/") else { continue }
            let relative = String(real.dropFirst(rootPath.count + 1))
            let copy = generationDirectory.appendingPathComponent(root.name, isDirectory: true)
                .appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            return copy.path
        }
        serial += 1
        let folder = generationDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return folder.appendingPathComponent("\(serial)-\(name.isEmpty ? "file" : name)").path
    }

    /// What `path` names after following symbolic links: a copy is made of the file, never of a link to it (writing
    /// through a copied link would change the real file).
    private static func target(of path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A path in the scratch folder that is never there (a file removed here reads as missing).
    private func missingPath() -> String {
        directory.appendingPathComponent("removed", isDirectory: true).appendingPathComponent("missing").path
    }

    private func record(_ r: Record) {
        records.append(r)
        if records.count > limit { records.removeFirst(records.count - limit) }
        let handler = onRecord
        // Told outside the lock (the handler may read the sandbox).
        lock.unlock()
        handler?(r)
        lock.lock()
    }
}
