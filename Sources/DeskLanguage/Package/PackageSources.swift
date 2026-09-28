import Foundation

// Where a widget folder's files come from: the disk (never through a link), or memory (tests, and archives already
// listed). Both walk a folder the same way — each folder's entries in byte order, a folder before what it holds —
// so the same files give the same model, even when the walk stops early.

/// What an entry of a widget folder is.
public enum PackageEntryType: Sendable, Hashable {
    case file
    case directory
    /// A symbolic link, with where it points as written; never followed.
    case link(destination: String)
    /// A socket, a pipe or a device: listed, never read.
    case special
}

/// One entry found while walking a widget folder.
public struct PackageEntry: Sendable, Hashable {
    /// Relative to the folder, `/`-separated.
    public var path: String
    public var type: PackageEntryType
    /// Bytes; for a link the length of its destination; 0 for folders.
    public var size: Int

    public init(path: String, type: PackageEntryType, size: Int) {
        self.path = path
        self.type = type
        self.size = size
    }
}

/// What the walk does after an entry.
public enum PackageWalkStep: Sendable {
    /// Go on (into a folder's entries when the entry is a folder).
    case next
    /// Go on, but not into this folder.
    case skip
    /// Stop walking.
    case stop
}

/// The files of a widget folder.
public protocol PackageFileSource: Sendable {
    /// Visits every entry below the folder, each folder's entries in byte order, a folder before its entries;
    /// links are reported, never followed. Throws when the folder itself cannot be listed.
    func walk(_ visit: (PackageEntry) -> PackageWalkStep) throws
    /// Up to `limit` bytes from the start of a regular file; never reads through a link.
    func read(_ path: String, limit: Int) throws -> Data
}

public enum PackageSourceError: Error, Sendable, Equatable {
    case notARegularFile(String)
    case cannotRead(String)
}

// MARK: - Disk

/// A folder on disk. Entries are examined without following links (`lstat`), and files are opened with
/// `O_NOFOLLOW`, so a link is never read through, even one that replaced a file after the walk.
public struct LocalPackageSource: PackageFileSource {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func walk(_ visit: (PackageEntry) -> PackageWalkStep) throws {
        _ = try walk(folder: "", visit, isRoot: true)
    }

    /// False when the walk was stopped.
    private func walk(folder: String, _ visit: (PackageEntry) -> PackageWalkStep, isRoot: Bool) throws -> Bool {
        let fm = FileManager.default
        let absolute = folder.isEmpty ? root.path : root.appendingPathComponent(folder).path
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: absolute)
        } catch {
            if isRoot { throw error }
            return true
        }
        for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let path = folder.isEmpty ? name : folder + "/" + name
            let full = (absolute as NSString).appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: full) else { continue }
            let type = attributes[.type] as? FileAttributeType
            let entry: PackageEntry
            switch type {
            case .typeDirectory?:
                entry = PackageEntry(path: path, type: .directory, size: 0)
            case .typeRegular?:
                entry = PackageEntry(path: path, type: .file, size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
            case .typeSymbolicLink?:
                let destination = (try? fm.destinationOfSymbolicLink(atPath: full)) ?? ""
                entry = PackageEntry(path: path, type: .link(destination: destination), size: destination.utf8.count)
            default:
                entry = PackageEntry(path: path, type: .special, size: 0)
            }
            switch visit(entry) {
            case .stop:
                return false
            case .skip:
                continue
            case .next:
                if entry.type == .directory, try !walk(folder: path, visit, isRoot: false) { return false }
            }
        }
        return true
    }

    public func read(_ path: String, limit: Int) throws -> Data {
        let full = root.appendingPathComponent(path).path
        let fd = open(full, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw PackageSourceError.cannotRead(path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PackageSourceError.notARegularFile(path)
        }
        var data = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while data.count < limit {
            let want = min(chunk, limit - data.count)
            let got = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
            if got < 0 { throw PackageSourceError.cannotRead(path) }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
        }
        return data
    }
}

// MARK: - Memory

/// A folder held in memory: files, links and empty folders by path. Folders are implied by the paths of what they
/// hold. Paths are kept exactly as given, so two names that differ only in Unicode normalization can both be there.
public struct InMemoryPackageSource: PackageFileSource {
    public enum Item: Sendable, Hashable {
        case file(Data)
        case link(String)
        case directory
    }

    public private(set) var items: [(path: String, item: Item)]

    public init(_ items: [(path: String, item: Item)] = []) {
        self.items = items
    }

    /// Files by path.
    public init(files: [String: Data]) {
        self.items = files.map { ($0.key, .file($0.value)) }
    }

    /// Text files by path, as UTF-8.
    public init(texts: [String: String]) {
        self.items = texts.map { ($0.key, .file(Data($0.value.utf8))) }
    }

    public mutating func add(_ path: String, _ item: Item) { items.append((path, item)) }
    public mutating func add(_ path: String, text: String) { items.append((path, .file(Data(text.utf8)))) }

    public func walk(_ visit: (PackageEntry) -> PackageWalkStep) throws {
        // Every entry once, folders implied by the paths below them.
        var entries: [(String, PackageEntry)] = []
        var seen = Set<[UInt8]>()
        func add(_ entry: PackageEntry) {
            if seen.insert(Array(entry.path.utf8)).inserted { entries.append((entry.path, entry)) }
        }
        for (path, item) in items {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            for k in 1..<max(parts.count, 1) {
                add(PackageEntry(path: parts[0..<k].joined(separator: "/"), type: .directory, size: 0))
            }
            switch item {
            case .file(let data): add(PackageEntry(path: path, type: .file, size: data.count))
            case .link(let destination): add(PackageEntry(path: path, type: .link(destination: destination), size: destination.utf8.count))
            case .directory: add(PackageEntry(path: path, type: .directory, size: 0))
            }
        }
        entries.sort { DeskPackagePath.walkPrecedes($0.0, $1.0) }
        var skipped: [String] = []
        for (path, entry) in entries {
            if skipped.contains(where: { path.utf8.starts(with: ($0 + "/").utf8) }) { continue }
            switch visit(entry) {
            case .stop: return
            case .skip: if entry.type == .directory { skipped.append(path) }
            case .next: break
            }
        }
    }

    public func read(_ path: String, limit: Int) throws -> Data {
        guard let item = items.last(where: { DeskPackagePath.sameBytes($0.path, path) })?.item else {
            throw PackageSourceError.cannotRead(path)
        }
        guard case .file(let data) = item else { throw PackageSourceError.notARegularFile(path) }
        return data.count <= limit ? data : data.prefix(limit)
    }
}
