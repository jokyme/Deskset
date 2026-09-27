import Foundation

/// A private copy of the files a skin changes, for an instance of a widget that must not change the widget's files while
/// another instance runs them — the Studio's own instance, next to the widget on the desktop, which does everything for
/// real. What its scripts write (`io.open` for writing, `io.output`, `os.remove`, `os.rename`) and what its WebParser
/// measures download to a `DownloadFile` goes to a scratch folder instead; reading a file it wrote or removed sees its
/// copy, every other file is read where it is. Each change is recorded (`records`, `onRecord`), as the bangs the
/// instance does not run are.
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

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Deskset-Sandbox-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// The real file `path` names, compared the way the default Mac file system compares names.
    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    /// The path to open instead of `path` for `access`: its copy (made now for a write; for an update it starts as the
    /// real file), a path that is not there for a file removed here, else `path` itself.
    public func path(for path: String, access: Access) -> String {
        let key = Self.key(path)
        lock.lock()
        defer { lock.unlock() }
        if access == .read {
            if let copy = copies[key] { return copy }
            if removed.contains(key) { return missingPath() }
            return path
        }
        if let copy = copies[key] { return copy }
        let copy = newCopyPath(for: path)
        if access == .update, !removed.contains(key), FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.copyItem(atPath: path, toPath: copy)
        }
        copies[key] = copy
        removed.remove(key)
        record(Record(operation: "write", path: path))
        return copy
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
        let copy = newCopyPath(for: to)
        if let source = copies.removeValue(forKey: fromKey) {
            try? FileManager.default.moveItem(atPath: source, toPath: copy)
        } else {
            try? FileManager.default.copyItem(atPath: from, toPath: copy)
        }
        if let old = copies[toKey] { try? FileManager.default.removeItem(atPath: old) }
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

    /// A new file in the scratch folder, named after `path`'s last part.
    private func newCopyPath(for path: String) -> String {
        serial += 1
        let folder = generationDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return folder.appendingPathComponent("\(serial)-\(name.isEmpty ? "file" : name)").path
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
