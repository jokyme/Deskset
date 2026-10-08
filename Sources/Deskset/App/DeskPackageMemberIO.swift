import Foundation
import Darwin
import DeskLanguage

/// Bounded synchronous I/O for one explicitly selected root-level document. One editor owner calls these
/// methods serially. Whole-package freshness is separate worker work; saving never follows a member link.
final class DeskPackageMemberIO {
    enum Failure: Error, Equatable {
        case invalidMember, changed, oversized, unreadable(Int32), writeFailed(Int32)
    }

    enum Checkpoint {
        case openedDescriptor(Int32), closedDescriptor(Int32)
        case willRead, didRead, willReplace, didReplace
    }

    struct Hooks {
        var at: ((Checkpoint) -> Void)?
        var read: ((Int32, UnsafeMutableRawPointer?, Int) -> Int)?
        var write: ((Int32, UnsafeRawPointer?, Int) -> Int)?
        init(at: ((Checkpoint) -> Void)? = nil,
             read: ((Int32, UnsafeMutableRawPointer?, Int) -> Int)? = nil,
             write: ((Int32, UnsafeRawPointer?, Int) -> Int)? = nil) {
            self.at = at; self.read = read; self.write = write
        }
    }

    private typealias Identity = DeskPackageCapture.Identity
    private let root: URL
    private let rootIdentity: Identity
    private let member: String
    private let maximumBytes: Int
    private let hooks: Hooks
    let file: URL
    private var lastRead: Identity?

    init(capture: DeskPackageCapture, member: DeskFileID, hooks: Hooks = Hooks()) throws {
        guard DeskPackagePath.kind(of: member.path) == .widget,
              let components = DeskPackagePath.safeComponents(member.path), components.count == 1,
              DeskPackagePath.sameBytes(components[0], member.path),
              capture.files.contains(where: { DeskPackagePath.sameBytes($0.path, member.path) }) else {
            throw Failure.invalidMember
        }
        root = capture.root
        rootIdentity = capture.rootIdentity
        self.member = member.path
        maximumBytes = capture.limits.maximumFileBytes
        self.hooks = hooks
        file = capture.root.appendingPathComponent(member.path).standardizedFileURL
    }

    /// A failed read revokes the write receipt. CodeEditorView's explicit conflict path may swallow a read error;
    /// its following onCommit must still fail rather than overwrite an unobserved document.
    func read(_ file: URL) throws -> Data {
        lastRead = nil
        try check(file)
        let result: (Data, Identity) = try withRoot { directory, validate in
            let before = try named(member, in: directory)
            guard before.kind == .regular else { throw Failure.invalidMember }
            guard before.size >= 0, before.size <= Int64(maximumBytes) else { throw Failure.oversized }
            let fd = try opened(openat(directory, member, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW))
            defer { close(fd) }
            guard try identity(fd) == before else { throw Failure.changed }
            hooks.at?(.willRead)
            var bytes = Data()
            bytes.reserveCapacity(Int(before.size))
            var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = chunk.withUnsafeMutableBytes {
                    hooks.read?(fd, $0.baseAddress, $0.count) ?? Darwin.read(fd, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0, count <= chunk.count else { throw Failure.unreadable(count < 0 ? errno : EIO) }
                if count == 0 { break }
                guard count <= Int(before.size) - bytes.count else { throw Failure.changed }
                bytes.append(contentsOf: chunk.prefix(count))
            }
            hooks.at?(.didRead)
            guard bytes.count == Int(before.size), try identity(fd) == before,
                  try named(member, in: directory) == before else { throw Failure.changed }
            try validate()
            return (bytes, before)
        }
        lastRead = result.1
        return result.0
    }

    /// True completion means actual bytes were written. A write consumes the last successful read; a retry must
    /// read again through the editor's existing conflict check. Named checks detect races, not a same-UID FS lock.
    func write(_ data: Data, to file: URL) throws {
        let receipt = lastRead
        lastRead = nil
        try check(file)
        guard data.count <= maximumBytes else { throw Failure.oversized }
        guard let receipt else { throw Failure.changed }
        try withRoot { directory, validate in
            guard try named(member, in: directory) == receipt else { throw Failure.changed }
            var source = stat()
            guard fstatat(directory, member, &source, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Failure.unreadable(errno)
            }
            guard try Self.identity(source) == receipt else { throw Failure.changed }
            let temporary = ".deskset-editor-\(UUID().uuidString).tmp"
            let fd = try opened(openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600))
            var published = false
            defer {
                // A replacement at our temporary name is not ours to remove.
                if !published, let held = try? identity(fd), let current = try? named(temporary, in: directory),
                   held.device == current.device, held.inode == current.inode {
                    _ = unlinkat(directory, temporary, 0)
                }
                close(fd)
            }
            guard fchmod(fd, source.st_mode & 0o777) == 0 else { throw Failure.writeFailed(errno) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let pointer = bytes.baseAddress!.advanced(by: offset)
                    let count = hooks.write?(fd, pointer, bytes.count - offset)
                        ?? Darwin.write(fd, pointer, bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0, count <= bytes.count - offset else {
                        throw Failure.writeFailed(count < 0 ? errno : EIO)
                    }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw Failure.writeFailed(errno) }
            hooks.at?(.willReplace)
            try validate()
            guard try named(member, in: directory) == receipt,
                  try named(temporary, in: directory) == identity(fd) else { throw Failure.changed }
            guard renameat(directory, temporary, directory, member) == 0 else { throw Failure.writeFailed(errno) }
            published = true
            hooks.at?(.didReplace)
            guard try named(member, in: directory) == identity(fd) else { throw Failure.changed }
            try validate()
        }
    }

    private func check(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0"),
              DeskPackagePath.sameBytes(url.standardizedFileURL.path, file.path) else { throw Failure.invalidMember }
    }

    private func opened(_ fd: Int32) throws -> Int32 {
        guard fd >= 0 else { throw Failure.unreadable(errno) }
        hooks.at?(.openedDescriptor(fd))
        return fd
    }

    private func close(_ fd: Int32) {
        Darwin.close(fd)
        hooks.at?(.closedDescriptor(fd))
    }

    private func identity(_ fd: Int32) throws -> Identity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.unreadable(errno) }
        return try Self.identity(info)
    }

    private func named(_ name: String, in directory: Int32) throws -> Identity {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unreadable(errno) }
        return try Self.identity(info)
    }

    private static func identity(_ info: stat) throws -> Identity {
        let kind: DeskPackageCapture.Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regular
        default: throw Failure.invalidMember
        }
        return Identity(device: info.st_dev, inode: info.st_ino, kind: kind, size: info.st_size,
                        mtimeSeconds: Int64(info.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                        ctimeSeconds: Int64(info.st_ctimespec.tv_sec), ctimeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private func sameRoot(_ value: Identity) -> Bool {
        value.kind == .directory && value.device == rootIdentity.device && value.inode == rootIdentity.inode
    }

    private func withRoot<T>(_ body: (Int32, () throws -> Void) throws -> T) throws -> T {
        let parent = root.path == "/" ? root : root.deletingLastPathComponent()
        let name = root.path == "/" ? "." : root.lastPathComponent
        let parentFD = try opened(open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        defer { close(parentFD) }
        guard sameRoot(try named(name, in: parentFD)) else { throw Failure.changed }
        let fd = try opened(openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
        defer { close(fd) }
        func validate() throws {
            guard sameRoot(try identity(fd)), sameRoot(try named(name, in: parentFD)) else { throw Failure.changed }
            let current = try opened(open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
            defer { close(current) }
            guard sameRoot(try identity(current)) else { throw Failure.changed }
        }
        try validate()
        return try body(fd, validate)
    }
}
