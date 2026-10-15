import Foundation
import Darwin
import DeskLanguage

/// A complete, immutable capture of an explicitly chosen folder. Files are read only between two complete
/// manifests. This detects changes while reading; it is not a filesystem snapshot or a promise about later writes.
/// Run capture and validation on a file worker. The returned value owns bytes and metadata, never descriptors.
struct DeskPackageCapture: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidRoot, invalidName(String), unsupported(String)
        case unreadable(path: String, code: Int32)
        case changed(String), ambiguous(String, String), resourceLimit, cancelled
    }

    enum Kind: Equatable, Sendable { case directory, regular }

    struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let kind: Kind
        let size: Int64
        let mtimeSeconds: Int64
        let mtimeNanoseconds: Int64
        let ctimeSeconds: Int64
        let ctimeNanoseconds: Int64
    }

    struct Member: Sendable {
        let name: String
        let identity: Identity
    }

    struct Directory: Sendable {
        /// Actual relative spelling; the root has the empty path.
        let path: String
        let identity: Identity
        let members: [Member]
    }

    struct File: Sendable {
        let path: String
        let identity: Identity
        let bytes: Data
    }

    /// Synchronous observation and syscall seams for deterministic race/error tests. None survive the operation.
    enum Checkpoint {
        case willScanDirectory(String), didCaptureManifest, willReadFile(String)
        case willReadChunk(path: String, offset: Int), didReadFile(String), willVerifyManifest
        case openedDescriptor(Int32), closedDescriptor(Int32)
    }

    struct Hooks {
        var at: ((Checkpoint) -> Void)?
        var read: ((Int32, UnsafeMutableRawPointer?, Int) -> Int)?
        var nextEntry: ((UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?)?

        init(at: ((Checkpoint) -> Void)? = nil,
             read: ((Int32, UnsafeMutableRawPointer?, Int) -> Int)? = nil,
             nextEntry: ((UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?)? = nil) {
            self.at = at; self.read = read; self.nextEntry = nextEntry
        }
    }

    let root: URL
    let rootIdentity: Identity
    let directories: [Directory]
    let files: [File]
    let totalBytes: Int
    let limits: CatalogLimits
    private let manifest: Manifest

    var source: InMemoryPackageSource {
        var items: [(path: String, item: InMemoryPackageSource.Item)] = directories.compactMap {
            $0.path.isEmpty ? nil : ($0.path, .directory)
        }
        items += files.map { ($0.path, .file($0.bytes)) }
        items.sort { DeskPackagePath.precedes($0.path, $1.path) }
        return InMemoryPackageSource(items)
    }

    static func read(root: URL, limits: CatalogLimits = DeskCatalog.current.limits,
                     isCancelled: () -> Bool = { false }, hooks: Hooks = Hooks()) throws -> Self {
        try withoutActuallyEscaping(isCancelled) { isCancelled in
            let io = IO(isCancelled: isCancelled, hooks: hooks)
            try io.checkCancelled()
            let limits = try effectiveLimits(limits)
            return try withRoot(root, expected: nil, io: io) { anchor in
                let before = try scan(anchor, limits: limits, io: io)
                try io.checkpoint(.didCaptureManifest)
                let directories = before.directoryIdentities
                var files: [File] = []
                for file in before.files {
                    let bytes = try readFile(file, anchor: anchor, directories: directories,
                                             limits: limits, comparing: nil, io: io)
                    files.append(File(path: file.path, identity: file.identity, bytes: bytes))
                }
                try io.checkpoint(.willVerifyManifest)
                let after = try scan(anchor, limits: limits, io: io)
                guard before.matches(after) else { throw Failure.changed("") }
                try anchor.validate(io)
                try io.checkCancelled()
                return Self(root: anchor.root, rootIdentity: anchor.identity, directories: before.directories,
                            files: files, totalBytes: before.totalBytes, limits: limits, manifest: before)
            }
        }
    }

    /// Rechecks the complete inventory, then compares bytes in bounded chunks without allocating another package.
    /// Newly added files or empty directories invalidate the capture, as do changes to existing members.
    func validateUnchanged(isCancelled: () -> Bool = { false }, hooks: Hooks = Hooks()) throws {
        try withoutActuallyEscaping(isCancelled) { isCancelled in
            let io = IO(isCancelled: isCancelled, hooks: hooks)
            try io.checkCancelled()
            try Self.withRoot(root, expected: rootIdentity, io: io) { anchor in
                let before = try Self.scan(anchor, limits: limits, io: io)
                guard manifest.matches(before) else { throw Failure.changed("") }
                try io.checkpoint(.didCaptureManifest)
                let directories = manifest.directoryIdentities
                for (record, file) in zip(manifest.files, files) {
                    _ = try Self.readFile(record, anchor: anchor, directories: directories,
                                          limits: limits, comparing: file.bytes, io: io)
                }
                try io.checkpoint(.willVerifyManifest)
                let after = try Self.scan(anchor, limits: limits, io: io)
                guard manifest.matches(after) else { throw Failure.changed("") }
                try anchor.validate(io)
                try io.checkCancelled()
            }
        }
    }

    /// Used for every directory's actual entries, before any normalized-key resource model is constructed.
    static func validateNames(_ names: [String], in directory: String) throws {
        var spellings: [String: String] = [:]
        for name in names where name != "." && name != ".." && !DeskPackagePath.isIgnoredName(name) {
            let path = join(directory, name)
            guard !name.isEmpty, !name.contains("/"), !name.contains("\0"),
                  let components = DeskPackagePath.safeComponents(path),
                  DeskPackagePath.sameBytes(components.joined(separator: "/"), path) else {
                throw Failure.invalidName(path)
            }
            let key = DeskPackagePath.foldedKey(name)
            if let previous = spellings[key] {
                throw Failure.ambiguous(join(directory, previous), join(directory, name))
            }
            spellings[key] = name
        }
    }

    private struct Record: Sendable {
        let path: String
        let identity: Identity
    }

    private struct Manifest: Sendable {
        let directories: [Directory]
        let files: [Record]
        let totalBytes: Int

        var directoryIdentities: [[UInt8]: Identity] {
            Dictionary(uniqueKeysWithValues: directories.map { (Array($0.path.utf8), $0.identity) })
        }

        func matches(_ other: Manifest) -> Bool {
            guard totalBytes == other.totalBytes, directories.count == other.directories.count,
                  files.count == other.files.count else { return false }
            for (left, right) in zip(directories, other.directories) {
                guard DeskPackagePath.sameBytes(left.path, right.path), left.identity == right.identity,
                      left.members.count == right.members.count else { return false }
                for (a, b) in zip(left.members, right.members) {
                    guard DeskPackagePath.sameBytes(a.name, b.name), a.identity == b.identity else { return false }
                }
            }
            return zip(files, other.files).allSatisfy {
                DeskPackagePath.sameBytes($0.0.path, $0.1.path) && $0.0.identity == $0.1.identity
            }
        }
    }

    private struct Budget {
        let limits: CatalogLimits
        var files = 0
        var bytes = 0

        mutating func add(_ identity: Identity) throws {
            guard identity.size >= 0, identity.size <= Int64(Int.max),
                  identity.size <= Int64(limits.maximumPackageBytes) else { throw Failure.resourceLimit }
            let count = files.addingReportingOverflow(1), total = bytes.addingReportingOverflow(Int(identity.size))
            guard !count.overflow, !total.overflow, count.partialValue <= limits.maximumPackageFiles,
                  total.partialValue <= limits.maximumPackageBytes else { throw Failure.resourceLimit }
            files = count.partialValue; bytes = total.partialValue
        }
    }

    private static func effectiveLimits(_ requested: CatalogLimits) throws -> CatalogLimits {
        guard requested.maximumPackageBytes >= 0, requested.maximumPackageFiles >= 0 else { throw Failure.resourceLimit }
        var result = requested
        result.maximumPackageBytes = min(result.maximumPackageBytes, DeskCatalog.current.limits.maximumPackageBytes)
        result.maximumPackageFiles = min(result.maximumPackageFiles, DeskCatalog.current.limits.maximumPackageFiles)
        return result
    }

    private struct IO {
        let isCancelled: () -> Bool
        let hooks: Hooks

        func checkCancelled() throws { if isCancelled() { throw Failure.cancelled } }

        func checkpoint(_ point: Checkpoint) throws {
            try checkCancelled()
            hooks.at?(point)
            try checkCancelled()
        }

        func opened(_ fd: Int32, path: String) throws -> Int32 {
            guard fd >= 0 else { throw Failure.unreadable(path: path, code: errno) }
            hooks.at?(.openedDescriptor(fd))
            return fd
        }

        func close(_ fd: Int32) {
            Darwin.close(fd)
            hooks.at?(.closedDescriptor(fd))
        }

        func identity(_ fd: Int32, path: String) throws -> Identity {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Failure.unreadable(path: path, code: errno) }
            return try DeskPackageCapture.identity(info, path: path)
        }

        func named(_ name: String, in directory: Int32, path: String) throws -> Identity {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Failure.unreadable(path: path, code: errno)
            }
            return try DeskPackageCapture.identity(info, path: path)
        }
    }

    private struct Anchor {
        let root: URL
        let parentFD: Int32
        let name: String
        let fd: Int32
        let identity: Identity

        func validate(_ io: IO) throws {
            try io.checkCancelled()
            guard try io.identity(fd, path: "") == identity,
                  try io.named(name, in: parentFD, path: "") == identity else { throw Failure.changed("") }
            // The held parent protects named lookup; reopening the original URL also detects a replaced ancestor.
            let current = try io.opened(open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW), path: "")
            defer { io.close(current) }
            guard try io.identity(current, path: "") == identity else { throw Failure.changed("") }
        }
    }

    private static func withRoot<T>(_ root: URL, expected: Identity?, io: IO,
                                    _ body: (Anchor) throws -> T) throws -> T {
        guard root.isFileURL, !root.path.contains("\0") else { throw Failure.invalidRoot }
        let isVolumeRoot = root.path == "/"
        let parent = isVolumeRoot ? root : root.deletingLastPathComponent()
        let name = isVolumeRoot ? "." : root.lastPathComponent
        guard !name.isEmpty else { throw Failure.invalidRoot }
        try io.checkCancelled()
        // The explicitly selected root's ancestors are the caller's trust boundary. Only the root and its
        // descendants are required to be non-links; do not silently change that boundary by resolving siblings.
        let parentFD = try io.opened(open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC), path: root.path)
        defer { io.close(parentFD) }
        let named: Identity
        do { named = try io.named(name, in: parentFD, path: "") }
        catch Failure.unsupported(_) { throw Failure.invalidRoot }
        guard named.kind == .directory else { throw Failure.invalidRoot }
        let fd = try io.opened(openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW), path: "")
        defer { io.close(fd) }
        let held = try io.identity(fd, path: "")
        guard held == named, expected == nil || held == expected else { throw Failure.changed("") }
        let anchor = Anchor(root: root, parentFD: parentFD, name: name, fd: fd, identity: held)
        try anchor.validate(io)
        return try body(anchor)
    }

    private static func identity(_ info: stat, path: String) throws -> Identity {
        let kind: Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regular
        default: throw Failure.unsupported(path)
        }
        return Identity(device: info.st_dev, inode: info.st_ino, kind: kind, size: info.st_size,
                        mtimeSeconds: Int64(info.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                        ctimeSeconds: Int64(info.st_ctimespec.tv_sec), ctimeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    /// Reopen components from the held root, matching every directory observed in the manifest. At most two
    /// traversal descriptors coexist, irrespective of the folder's depth; no recursive call stack is used.
    private static func openDirectory(_ path: String, anchor: Anchor,
                                      known: [[UInt8]: Identity], io: IO) throws -> Int32 {
        var fd = try io.opened(openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW), path: "")
        var retained = false
        defer { if !retained { io.close(fd) } }
        guard try io.identity(fd, path: "") == anchor.identity else { throw Failure.changed("") }
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: false) where !component.isEmpty {
            try io.checkCancelled()
            let name = String(component)
            current = join(current, name)
            guard let expected = known[Array(current.utf8)], expected.kind == .directory,
                  try io.named(name, in: fd, path: current) == expected else { throw Failure.changed(current) }
            let next = try io.opened(openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW), path: current)
            do {
                guard try io.identity(next, path: current) == expected,
                      try io.named(name, in: fd, path: current) == expected else { throw Failure.changed(current) }
            } catch {
                io.close(next)
                throw error
            }
            io.close(fd)
            fd = next
        }
        retained = true
        return fd
    }

    private static func scan(_ anchor: Anchor, limits: CatalogLimits, io: IO) throws -> Manifest {
        try anchor.validate(io)
        var pending = [Record(path: "", identity: anchor.identity)], cursor = 0
        var known: [[UInt8]: Identity] = [Array("".utf8): anchor.identity]
        var directories: [Directory] = [], files: [Record] = [], budget = Budget(limits: limits)
        while cursor < pending.count {
            let directory = pending[cursor]; cursor += 1
            try io.checkpoint(.willScanDirectory(directory.path))
            let fd = try openDirectory(directory.path, anchor: anchor, known: known, io: io)
            let members: [Member]
            do {
                members = try scanMembers(fd, directory: directory, budget: &budget, io: io)
                io.close(fd)
            } catch {
                io.close(fd)
                throw error
            }
            directories.append(Directory(path: directory.path, identity: directory.identity, members: members))
            for member in members {
                let path = join(directory.path, member.name), record = Record(path: path, identity: member.identity)
                if member.identity.kind == .directory {
                    known[Array(path.utf8)] = member.identity
                    pending.append(record)
                } else {
                    files.append(record)
                }
            }
        }
        directories.sort { DeskPackagePath.precedes($0.path, $1.path) }
        files.sort { DeskPackagePath.precedes($0.path, $1.path) }
        try anchor.validate(io)
        return Manifest(directories: directories, files: files, totalBytes: budget.bytes)
    }

    private static func scanMembers(_ fd: Int32, directory: Record, budget: inout Budget, io: IO) throws -> [Member] {
        guard try io.identity(fd, path: directory.path) == directory.identity else { throw Failure.changed(directory.path) }
        let scanFD = try io.opened(openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW), path: directory.path)
        guard let stream = fdopendir(scanFD) else {
            let code = errno
            io.close(scanFD)
            throw Failure.unreadable(path: directory.path, code: code)
        }
        defer {
            closedir(stream)
            io.hooks.at?(.closedDescriptor(scanFD))
        }
        var members: [Member] = []
        while true {
            try io.checkCancelled()
            errno = 0
            let entry: UnsafeMutablePointer<dirent>?
            if let nextEntry = io.hooks.nextEntry { entry = nextEntry(stream) }
            else { entry = readdir(stream) }
            guard let entry else {
                guard errno == 0 else { throw Failure.unreadable(path: directory.path, code: errno) }
                break
            }
            let count = Int(entry.pointee.d_namlen)
            let name: String? = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                guard count > 0, count < raw.count else { return nil }
                return String(bytes: raw.prefix(count), encoding: .utf8)
            }
            guard let name, !name.contains("\0"), !name.contains("/") else { throw Failure.invalidName(directory.path) }
            if name == "." || name == ".." || DeskPackagePath.isIgnoredName(name) { continue }
            let path = join(directory.path, name)
            let identity = try io.named(name, in: fd, path: path)
            if identity.kind == .regular { try budget.add(identity) }
            members.append(Member(name: name, identity: identity))
        }
        try validateNames(members.map(\.name), in: directory.path)
        guard try io.identity(fd, path: directory.path) == directory.identity else { throw Failure.changed(directory.path) }
        members.sort { DeskPackagePath.precedes($0.name, $1.name) }
        return members
    }

    private static func readFile(_ file: Record, anchor: Anchor, directories: [[UInt8]: Identity],
                                 limits: CatalogLimits, comparing expectedBytes: Data?, io: IO) throws -> Data {
        try io.checkpoint(.willReadFile(file.path))
        let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = parts.last, !last.isEmpty else { throw Failure.invalidName(file.path) }
        let parent = parts.dropLast().joined(separator: "/"), name = String(last)
        let directory = try openDirectory(parent, anchor: anchor, known: directories, io: io)
        defer { io.close(directory) }
        guard try io.named(name, in: directory, path: file.path) == file.identity else { throw Failure.changed(file.path) }
        let fd = try io.opened(openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK), path: file.path)
        defer { io.close(fd) }
        guard try io.identity(fd, path: file.path) == file.identity, file.identity.kind == .regular,
              file.identity.size >= 0, file.identity.size <= Int64(Int.max) else { throw Failure.changed(file.path) }
        guard file.identity.size <= Int64(limits.maximumPackageBytes) else { throw Failure.resourceLimit }
        let size = Int(file.identity.size)
        guard expectedBytes == nil || expectedBytes?.count == size else { throw Failure.changed(file.path) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024), offset = 0
        if expectedBytes == nil { bytes.reserveCapacity(size) }
        while offset <= size {
            try io.checkpoint(.willReadChunk(path: file.path, offset: offset))
            let remaining = size - offset, wanted = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = buffer.withUnsafeMutableBytes { raw in
                io.hooks.read?(fd, raw.baseAddress, wanted) ?? Darwin.read(fd, raw.baseAddress, wanted)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unreadable(path: file.path, code: errno) }
            if count == 0 { break }
            guard count <= wanted, count <= remaining else { throw Failure.changed(file.path) }
            if let expectedBytes {
                let equal = expectedBytes.withUnsafeBytes { expected in
                    buffer.withUnsafeBytes { actual in
                        memcmp(expected.baseAddress!.advanced(by: offset), actual.baseAddress!, count) == 0
                    }
                }
                guard equal else { throw Failure.changed(file.path) }
            } else {
                bytes.append(contentsOf: buffer.prefix(count))
            }
            offset += count
        }
        guard offset == size, try io.identity(fd, path: file.path) == file.identity,
              try io.named(name, in: directory, path: file.path) == file.identity else { throw Failure.changed(file.path) }
        try io.checkpoint(.didReadFile(file.path))
        return bytes
    }
}
