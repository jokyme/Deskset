import Foundation
import Darwin
import CryptoKit
import DeskLanguage
import DesksetCore

/// Admission and installation of one supported, explicitly opened Desk source. This owns files and state only:
/// no window, Skin, frame producer or timer is created, and an installed instance remains inactive.
enum DeskWidgetInstallation {
    enum Failure: Error, Equatable {
        case staleSnapshot, invalidSource, unsupported, sourceChanged, invalidPackage, resourceLimit, collision, disposed
        case resources(String), io(Int32)
    }

    struct Admission: Sendable {
        let snapshot: DeskSnapshot
        let document: DeskProgramResources.Document
        let imageSources: [String]
        let program: WidgetProgram
    }

    struct Installed {
        let source: DeskWidgetSourceState
        let instance: DeskWidgetInstanceState
        let directory: URL
        let program: WidgetProgram
    }

    /// The editor's owner supplies its existing file/revision/text/service-generation guard. A save failure or an
    /// uncommitted buffer cannot be mistaken for bytes that the installation will later reload.
    static func admit(_ snapshot: DeskSnapshot, file: URL,
                      current: (DeskSnapshot) -> Bool) throws -> Admission {
        guard current(snapshot), snapshot.isChecked else { throw Failure.staleSnapshot }
        let name = file.lastPathComponent
        guard file.isFileURL, DeskPackagePath.isDeskFile(name), !DeskPackagePath.isPackageFile(name),
              !DeskPackagePath.isIgnoredName(name), !name.contains("\\"), !name.contains("\0"),
              snapshot.file == DeskFileID(path: name), snapshot.package == nil, snapshot.folder.count == 1 else {
            throw Failure.invalidSource
        }
        let result = Desk.compile(snapshot.checked, catalog: snapshot.options.catalog)
        guard let program = result.program else { throw Failure.unsupported }
        let document = try DeskProgramResources.document(at: file, maximumBytes: snapshot.options.catalog.limits.maximumFileBytes)
        guard case .text(let text, _) = Desk.load(document.bytes, fileName: name),
              text.utf8.elementsEqual(snapshot.text.utf8), current(snapshot) else { throw Failure.sourceChanged }
        return Admission(snapshot: snapshot, document: document, imageSources: result.imageSources, program: program)
    }

    /// Resource work may run on a preparation queue. The caller retains the returned lease until the main-thread
    /// commit; dropping it removes only this operation's exclusive staging directory and private image copies.
    static func prepare(_ admitted: Admission, sourceID: UUID, instanceID: UUID,
                        root: URL = Paths.widgets) throws -> Staged {
        let limits = admitted.snapshot.options.catalog.limits
        // This is the existing package budget (language specification §8.3): the source counts as one entry.
        let maximumBytes = min(limits.maximumPackageBytes, DeskCatalog.current.limits.maximumPackageBytes)
        let maximumFiles = min(limits.maximumPackageFiles, DeskCatalog.current.limits.maximumPackageFiles)
        guard maximumBytes >= admitted.document.bytes.count, maximumFiles >= 1 else { throw Failure.resourceLimit }
        guard admitted.document.unchanged(maximumBytes: limits.maximumFileBytes) else { throw Failure.sourceChanged }
        let language: StudioLanguage = admitted.snapshot.options.messageLanguage == .simplifiedChinese ? .chinese : .english
        let images = DeskProgramResources.prepare(root: admitted.document.file.deletingLastPathComponent(),
                                                  literals: admitted.imageSources,
                                                  maximumBytes: maximumBytes - admitted.document.bytes.count,
                                                  maximumFiles: maximumFiles - 1, language: language)
        var retained = false
        defer { if !retained { images.removeCopies() } }
        if let failure = images.failure { throw Failure.resources(failure) }
        guard images.unchanged() else { throw Failure.sourceChanged }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else { throw Failure.io(errno) }
        var transferred = false
        defer { if !transferred { Darwin.close(rootFD) } }
        let name = sourceID.uuidString.lowercased(), stageName = ".install-" + name
        var info = stat()
        if fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.collision }
        guard errno == ENOENT else { throw Failure.io(errno) }
        guard mkdirat(rootFD, stageName, 0o700) == 0 else {
            if errno == EEXIST { throw Failure.collision }
            throw Failure.io(errno)
        }
        let stageFD = openat(rootFD, stageName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stageFD >= 0 else {
            let code = errno
            _ = unlinkat(rootFD, stageName, AT_REMOVEDIR)
            throw Failure.io(code)
        }
        let staged = Staged(admitted: admitted, images: images, root: root, rootFD: rootFD,
                            directoryFD: stageFD, name: stageName, sourceID: sourceID, instanceID: instanceID)
        transferred = true; retained = true
        do {
            let sourceName = admitted.document.file.lastPathComponent
            staged.fingerprints[sourceName] = try write(admitted.document.bytes, path: sourceName, in: stageFD)
            var copied = Set<String>()
            for image in images.sources where copied.insert(image.resolved).inserted {
                try DeskProgramResources.withPreparedImage(image, in: images) { fd, count in
                    staged.fingerprints[image.resolved] = try copy(fd, count: count, path: image.resolved, in: stageFD)
                }
            }
            guard admitted.document.unchanged(maximumBytes: limits.maximumFileBytes), images.unchanged() else {
                throw Failure.sourceChanged
            }
            let package = try staged.checkedPackage()
            let checked = DeskLanguageService(package: package, openFile: admitted.snapshot.file,
                                              options: admitted.snapshot.options, version: admitted.snapshot.version).snapshot
            guard let program = Desk.compile(checked.checked, catalog: checked.options.catalog).program,
                  program == admitted.program else { throw Failure.invalidPackage }
            staged.program = program
            return staged
        } catch { staged.discard(); throw error }
    }

    final class Staged {
        let admitted: Admission
        let root: URL
        let sourceID: UUID
        let instanceID: UUID
        private let images: DeskProgramResources.Prepared
        private let rootFD: Int32
        private let directoryFD: Int32
        private var name: String
        private var ended = false
        fileprivate var fingerprints: [String: Fingerprint] = [:]
        fileprivate var program: WidgetProgram?
        var directory: URL { root.appendingPathComponent(name, isDirectory: true) }

        fileprivate init(admitted: Admission, images: DeskProgramResources.Prepared, root: URL, rootFD: Int32,
                         directoryFD: Int32, name: String, sourceID: UUID, instanceID: UUID) {
            self.admitted = admitted; self.images = images; self.root = root; self.rootFD = rootFD
            self.directoryFD = directoryFD; self.name = name; self.sourceID = sourceID; self.instanceID = instanceID
        }

        deinit { discard(); Darwin.close(directoryFD); Darwin.close(rootFD) }

        /// Committing state never means activation. The source directory is renamed without replacement; a failed
        /// state write removes that exact owned directory and leaves the original state and source untouched.
        func commit(to state: AppState, current: (DeskSnapshot) -> Bool) throws -> Installed {
            precondition(Thread.isMainThread)
            guard !ended else { throw Failure.disposed }
            defer { if !ended { discard() } }
            guard current(admitted.snapshot),
                  admitted.document.unchanged(maximumBytes: admitted.snapshot.options.catalog.limits.maximumFileBytes),
                  images.unchanged(), rootStillMatches(), directoryStillMatches() else { throw Failure.sourceChanged }
            try checkContents(in: directoryFD, files: Set(fingerprints.keys))
            for (path, expected) in fingerprints {
                guard try fingerprint(path, in: directoryFD, expectedSize: expected.size) == expected.digest else {
                    throw Failure.sourceChanged
                }
            }
            guard let program else { throw Failure.invalidPackage }
            let finalName = sourceID.uuidString.lowercased()
            guard directoryStillMatches() else { throw Failure.sourceChanged }
            guard renameatx_np(rootFD, name, rootFD, finalName, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST || errno == ENOTEMPTY { throw Failure.collision }
                throw Failure.io(errno)
            }
            name = finalName
            guard rootStillMatches(), directoryStillMatches(), current(admitted.snapshot) else { throw Failure.sourceChanged }
            let source = DeskWidgetSourceState(id: sourceID, entry: finalName + "/" + admitted.document.file.lastPathComponent)
            let instance = DeskWidgetInstanceState(id: instanceID, sourceID: sourceID)
            try state.registerDeskInstallation(source: source, instance: instance)
            ended = true
            images.removeCopies()
            return Installed(source: source, instance: instance, directory: directory, program: program)
        }

        func discard() {
            guard !ended else { return }
            removeContents(in: directoryFD)
            // A replaced name is not this operation's directory and must never be deleted by its cleanup.
            var held = stat(), named = stat()
            if fstat(directoryFD, &held) == 0,
               fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
               held.st_dev == named.st_dev, held.st_ino == named.st_ino {
                _ = unlinkat(rootFD, name, AT_REMOVEDIR)
            }
            ended = true
            images.removeCopies()
        }

        private func rootStillMatches() -> Bool {
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            var original = stat(), current = stat()
            return fstat(rootFD, &original) == 0 && fstat(fd, &current) == 0
                && original.st_dev == current.st_dev && original.st_ino == current.st_ino
        }

        private func directoryStillMatches() -> Bool {
            var held = stat(), named = stat()
            return fstat(directoryFD, &held) == 0 && fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0
                && named.st_mode & S_IFMT == S_IFDIR && held.st_dev == named.st_dev && held.st_ino == named.st_ino
        }

        fileprivate func checkedPackage() throws -> DeskPackage {
            guard rootStillMatches(), directoryStillMatches() else { throw Failure.sourceChanged }
            try checkContents(in: directoryFD, files: Set(fingerprints.keys))
            let source = try DeskProgramResources.document(at: directory.appendingPathComponent(admitted.snapshot.file.path),
                                                           maximumBytes: admitted.snapshot.options.catalog.limits.maximumFileBytes)
            guard source.bytes == admitted.document.bytes else { throw Failure.sourceChanged }
            // Like the editor's curated package, this reloads the sole source and supplies only its validated
            // references. Folder loading intentionally ignores dot folders, which a quoted Image path may use.
            var package = PackageLoader.load(deskData: source.bytes, fileName: admitted.snapshot.file.path,
                                             limits: admitted.snapshot.options.catalog.limits)
            package.files += images.files
            guard !package.diagnostics.contains(where: { $0.severity == .error }),
                  Set(package.files.map(\.path)) == Set(fingerprints.keys),
                  package.texts[admitted.snapshot.file]?.utf8.elementsEqual(admitted.snapshot.text.utf8) == true else {
                throw Failure.invalidPackage
            }
            return package
        }
    }

    /// The only writable trees are an exclusive 0700 staging directory and its final App-owned name. Every
    /// component is a no-follow directory FD; filenames cannot traverse outside it or overwrite existing files.
    private static func parent(of path: String, in root: Int32, create: Bool) throws -> (fd: Int32, name: String) {
        guard !path.contains("\0"), let parts = DeskPackagePath.safeComponents(path), let last = parts.last else {
            throw Failure.invalidSource
        }
        var directory = dup(root)
        guard directory >= 0 else { throw Failure.io(errno) }
        do {
            for part in parts.dropLast() {
                if create && mkdirat(directory, part, 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
                let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw Failure.io(errno) }
                Darwin.close(directory); directory = next
            }
            return (directory, last)
        } catch { Darwin.close(directory); throw error }
    }

    private static func create(_ path: String, in root: Int32) throws -> Int32 {
        let location = try parent(of: path, in: root, create: true)
        defer { Darwin.close(location.fd) }
        let fd = openat(location.fd, location.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? Failure.collision : Failure.io(errno) }
        return fd
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.io(count == 0 ? EIO : errno) }
            offset += count
        }
    }

    fileprivate struct Fingerprint {
        let digest: Data
        let size: Int
    }

    private static func write(_ bytes: Data, path: String, in root: Int32) throws -> Fingerprint {
        let fd = try create(path, in: root)
        defer { Darwin.close(fd) }
        try bytes.withUnsafeBytes { try writeAll($0, to: fd) }
        guard fsync(fd) == 0 else { throw Failure.io(errno) }
        return Fingerprint(digest: Data(SHA256.hash(data: bytes)), size: bytes.count)
    }

    private static func copy(_ source: Int32, count: Int, path: String, in root: Int32) throws -> Fingerprint {
        let fd = try create(path, in: root)
        defer { Darwin.close(fd) }
        var remaining = count, buffer = [UInt8](repeating: 0, count: 64 * 1024), hash = SHA256()
        while remaining > 0 {
            let size = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, min(remaining, $0.count)) }
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw Failure.sourceChanged }
            try buffer.withUnsafeBytes { try writeAll(UnsafeRawBufferPointer(rebasing: $0[..<size]), to: fd) }
            hash.update(data: Data(buffer.prefix(size)))
            remaining -= size
        }
        guard fsync(fd) == 0 else { throw Failure.io(errno) }
        return Fingerprint(digest: Data(hash.finalize()), size: count)
    }

    /// A commit reads only the immutable preparation's size plus one byte, even if its staged name was replaced
    /// by a giant file or a concurrent writer appends forever. Both the open file and its current name must still
    /// identify that same regular-file generation when the bounded digest is complete.
    private static func fingerprint(_ path: String, in root: Int32, expectedSize: Int) throws -> Data {
        let location = try parent(of: path, in: root, create: false)
        defer { Darwin.close(location.fd) }
        let fd = openat(location.fd, location.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.sourceChanged }
        defer { Darwin.close(fd) }
        var before = stat()
        guard expectedSize >= 0, fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size == Int64(expectedSize) else { throw Failure.sourceChanged }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), hash = SHA256()
        var read = 0
        while read <= expectedSize {
            let remaining = expectedSize - read
            let wanted = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.sourceChanged }
            if count == 0 { break }
            guard count <= remaining else { throw Failure.sourceChanged }
            hash.update(data: Data(buffer.prefix(count)))
            read += count
        }
        var after = stat(), named = stat()
        guard read == expectedSize, fstat(fd, &after) == 0,
              fstatat(location.fd, location.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              named.st_size == after.st_size,
              named.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              named.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              named.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              named.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.sourceChanged }
        return Data(hash.finalize())
    }

    /// No unlisted entry may ride along with the frozen reference graph. Only this exclusive staging tree is
    /// listed; regular files must exactly match the known names and directories must lead to a known file.
    private static func checkContents(in directory: Int32, files: Set<String>) throws {
        var directories = Set<String>()
        for path in files {
            guard let parts = DeskPackagePath.safeComponents(path) else { throw Failure.invalidPackage }
            for end in 1..<parts.count { directories.insert(parts[..<end].joined(separator: "/")) }
        }
        var found = Set<String>()
        func walk(_ fd: Int32, _ prefix: String) throws {
            // An independent directory description avoids sharing the held FD's readdir offset with cleanup.
            let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard scan >= 0 else { throw Failure.sourceChanged }
            guard let stream = fdopendir(scan) else { Darwin.close(scan); throw Failure.sourceChanged }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw Failure.sourceChanged }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
                }
                guard let name else { throw Failure.sourceChanged }
                if name == "." || name == ".." { continue }
                let path = prefix + name
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.sourceChanged }
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard directories.contains(path) else { throw Failure.sourceChanged }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    guard child >= 0 else { throw Failure.sourceChanged }
                    defer { Darwin.close(child) }
                    try walk(child, path + "/")
                } else {
                    guard info.st_mode & S_IFMT == S_IFREG, files.contains(path), found.insert(path).inserted else {
                        throw Failure.sourceChanged
                    }
                }
            }
        }
        try walk(directory, "")
        guard found == files else { throw Failure.sourceChanged }
    }

    private static func removeContents(in directory: Int32) {
        let duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard duplicate >= 0 else { return }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); return }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name, name != ".", name != ".." else { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if child >= 0 { removeContents(in: child); Darwin.close(child); _ = unlinkat(directory, name, AT_REMOVEDIR) }
            } else { _ = unlinkat(directory, name, 0) }
        }
    }
}
