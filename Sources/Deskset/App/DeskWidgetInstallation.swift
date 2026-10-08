import Foundation
import Darwin
import CryptoKit
import DeskLanguage
import DesksetCore

/// Admission and installation of supported Desk sources. This owns files and state only: no window, Skin,
/// frame producer or timer is created, and every installed instance remains inactive.
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

    struct PackageMember: Sendable {
        let file: DeskFileID
        let program: WidgetProgram
        let imageSources: [String]
    }

    struct PackageAdmission: Sendable {
        let snapshot: DeskSnapshot
        let capture: DeskPackageCapture
        let checked: CheckedDeskPackage
        let members: [PackageMember]

        fileprivate init(snapshot: DeskSnapshot, capture: DeskPackageCapture, checked: CheckedDeskPackage,
                         members: [PackageMember]) {
            self.snapshot = snapshot; self.capture = capture; self.checked = checked; self.members = members
        }
    }

    struct PackageMemberIDs: Sendable {
        let file: DeskFileID
        let sourceID: UUID
        let instanceID: UUID
    }

    struct PackagePlan: Sendable {
        let requestID: UUID
        let packageID: UUID
        let selected: DeskFileID
        let members: [PackageMemberIDs]
    }

    struct PackagePublication: Sendable {
        let plan: PackagePlan
        let root: URL
        let directory: URL
        let members: [PackageMember]
        fileprivate let rootIdentity: DirectoryIdentity
        fileprivate let directoryIdentity: DirectoryIdentity
        fileprivate let registration: PackageRegistration
    }

    struct InstalledPackage {
        let sources: [DeskWidgetSourceState]
        let instances: [DeskWidgetInstanceState]
        let selectedInstanceID: UUID
        let directory: URL
    }

    enum PackageDecision { case registered, rejected }
    enum PackageCheckpoint { case wroteFile(String), willVerifyFiles, didVerifyFile(String), willRename }

    /// A publication carries only immutable values and this acknowledgement, never its worker's descriptors.
    /// The lock orders the one Main state write against deletion. Worker I/O never holds it, so Main cannot wait
    /// for a directory scan; a late rejection cannot delete a directory whose state write has succeeded.
    fileprivate final class PackageRegistration: @unchecked Sendable {
        private enum Phase: Equatable { case prepared, published, registered, rejected }
        private let lock = NSLock()
        private var phase = Phase.prepared

        func publish() throws {
            lock.lock(); defer { lock.unlock() }
            guard phase == .prepared else { throw Failure.disposed }
            phase = .published
        }

        func register<T>(_ body: () throws -> T) throws -> T {
            lock.lock(); defer { lock.unlock() }
            guard phase == .published else { throw Failure.disposed }
            do {
                let value = try body()
                phase = .registered
                return value
            } catch { phase = .rejected; throw error }
        }

        var isRegistered: Bool {
            lock.lock(); defer { lock.unlock() }
            return phase == .registered
        }

        func relinquish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if phase == .registered { return false }
            phase = .rejected
            return true
        }
    }

    fileprivate struct DirectoryIdentity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64

        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
        func matches(_ info: stat) -> Bool {
            info.st_mode & S_IFMT == S_IFDIR && device == info.st_dev && inode == info.st_ino
        }
    }

    /// The saved editor text and every sibling must belong to this capture. All members compile against one
    /// freshly checked package tree, without mixing receipts from independent parses of package.desk.
    static func admitPackage(_ snapshot: DeskSnapshot, capture: DeskPackageCapture,
                             isCancelled: () -> Bool = { false }) throws -> PackageAdmission {
        precondition(!Thread.isMainThread)
        try checkCancelled(isCancelled)
        guard snapshot.isChecked else { throw Failure.staleSnapshot }
        var limits = snapshot.options.catalog.limits
        limits.maximumFileBytes = min(limits.maximumFileBytes, DeskCatalog.current.limits.maximumFileBytes)
        limits.maximumPackageBytes = min(limits.maximumPackageBytes, capture.limits.maximumPackageBytes)
        limits.maximumPackageFiles = min(limits.maximumPackageFiles, capture.limits.maximumPackageFiles)
        guard limits.maximumFileBytes >= 0, limits.maximumPackageBytes >= capture.totalBytes,
              limits.maximumPackageFiles >= capture.files.count else {
            throw Failure.resourceLimit
        }
        let package = try PackageLoader.load(capture.source, fonts: nil, limits: limits)
        guard !package.isTruncated, !package.diagnostics.contains(where: { $0.severity == .error }),
              !package.widgetFiles.isEmpty,
              package.widgetFiles.contains(where: { DeskPackagePath.sameBytes($0.path, snapshot.file.path) }),
              package.texts.count == snapshot.folder.count else { throw Failure.invalidPackage }
        for (file, text) in package.texts {
            guard let original = snapshot.folder.first(where: { DeskPackagePath.sameBytes($0.key.path, file.path) })?.value,
                  text.utf8.elementsEqual(original.utf8) else { throw Failure.sourceChanged }
        }
        let checked = DeskLanguageService(package: package, openFile: snapshot.file, options: snapshot.options,
                                          version: snapshot.version).snapshot.packageCheck()
        guard !checked.allDiagnostics.contains(where: { $0.severity == .error }),
              checked.widgetFiles.count == package.widgetFiles.count else { throw Failure.invalidPackage }
        var members: [PackageMember] = []
        for file in checked.widgetFiles.sorted(by: { DeskPackagePath.precedes($0.path, $1.path) }) {
            try checkCancelled(isCancelled)
            guard let source = checked.files[file] else { throw Failure.invalidPackage }
            let result = Desk.compile(source, catalog: checked.catalog, package: checked.checkedPackage)
            guard let program = result.program else { throw Failure.unsupported }
            members.append(PackageMember(file: file, program: program, imageSources: result.imageSources))
        }
        try checkCancelled(isCancelled)
        return PackageAdmission(snapshot: snapshot, capture: capture, checked: checked, members: members)
    }

    /// Creates an exclusive complete copy on a file worker. The caller keeps this lease on the same serial
    /// worker through publication and Main acknowledgement; it is never a window's mutable staging object.
    static func preparePackage(_ admitted: PackageAdmission, plan: PackagePlan, root: URL = Paths.widgets,
                               isCancelled: () -> Bool = { false },
                               observe: ((PackageCheckpoint) -> Void)? = nil) throws -> PackageStaged {
        precondition(!Thread.isMainThread)
        try checkCancelled(isCancelled)
        let paths = Set(admitted.members.map { Array($0.file.path.utf8) })
        guard !plan.members.isEmpty, plan.members.count == admitted.members.count,
              Set(plan.members.map { Array($0.file.path.utf8) }) == paths,
              Set(plan.members.map(\.sourceID)).count == plan.members.count,
              Set(plan.members.map(\.instanceID)).count == plan.members.count,
              paths.contains(Array(plan.selected.path.utf8)), root.isFileURL else { throw Failure.invalidSource }
        try validateCapture(admitted.capture, isCancelled: isCancelled)
        let language: StudioLanguage = admitted.snapshot.options.messageLanguage == .simplifiedChinese ? .chinese : .english
        let literals = Set(admitted.members.flatMap(\.imageSources)).sorted(by: DeskPackagePath.precedes)
        let images = DeskProgramResources.prepare(capture: admitted.capture, literals: literals, language: language)
        var retained = false
        defer { if !retained { images.removeCopies() } }
        if let failure = images.failure { throw Failure.resources(failure) }
        try checkCancelled(isCancelled)
        let opened = try makeStage(root: root, identity: plan.packageID)
        let staged = PackageStaged(admitted: admitted, plan: plan, images: images, root: root,
                                   rootFD: opened.root, directoryFD: opened.directory, name: opened.name)
        retained = true
        do {
            for entry in admitted.capture.directories where !entry.path.isEmpty {
                try checkCancelled(isCancelled)
                let fd = try directory(entry.path, in: opened.directory, create: true)
                Darwin.close(fd)
            }
            for file in admitted.capture.files {
                staged.fingerprints[file.path] = try write(file.bytes, path: file.path, in: opened.directory,
                                                           isCancelled: isCancelled)
                observe?(.wroteFile(file.path))
                try checkCancelled(isCancelled)
            }
            for entry in admitted.capture.directories.reversed() {
                try checkCancelled(isCancelled)
                let fd = try directory(entry.path, in: opened.directory, create: false)
                let result = fsync(fd), code = errno
                Darwin.close(fd)
                guard result == 0 else { throw Failure.io(code) }
            }
            return staged
        } catch { try? staged.finish(.rejected); throw error }
    }

    final class PackageStaged {
        let admitted: PackageAdmission
        let plan: PackagePlan
        let root: URL
        private let images: DeskProgramResources.Prepared
        private let rootFD: Int32
        private let directoryFD: Int32
        private let registration = PackageRegistration()
        private var name: String
        private var ended = false
        private var published = false
        fileprivate var fingerprints: [String: Fingerprint] = [:]
        var directory: URL { root.appendingPathComponent(name, isDirectory: true) }

        fileprivate init(admitted: PackageAdmission, plan: PackagePlan, images: DeskProgramResources.Prepared,
                         root: URL, rootFD: Int32, directoryFD: Int32, name: String) {
            self.admitted = admitted; self.plan = plan; self.images = images; self.root = root
            self.rootFD = rootFD; self.directoryFD = directoryFD; self.name = name
        }

        deinit {
            guard !ended else { return }
            // Normal retirement is explicit on the worker. A dropped caller must not turn fallback cleanup
            // into a recursive Main filesystem operation, or remove a successfully registered installation.
            let rootFD = rootFD, directoryFD = directoryFD, name = name, images = images, registration = registration
            let retire = {
                if registration.relinquish() { try? discardDirectory(in: rootFD, directory: directoryFD, name: name) }
                images.removeCopies()
                Darwin.close(directoryFD); Darwin.close(rootFD)
            }
            if Thread.isMainThread { DispatchQueue.global(qos: .utility).async(execute: retire) }
            else { retire() }
        }

        func publish(isCancelled: () -> Bool = { false },
                     observe: ((PackageCheckpoint) -> Void)? = nil) throws -> PackagePublication {
            precondition(!Thread.isMainThread)
            guard !ended, !published else { throw Failure.disposed }
            do {
                try validateCapture(admitted.capture, isCancelled: isCancelled)
                guard images.copiesUnchanged(), rootStillMatches(root, fd: rootFD),
                      directoryStillMatches(in: rootFD, fd: directoryFD, name: name) else { throw Failure.sourceChanged }
                let directories = Set(admitted.capture.directories.map(\.path))
                let before = try checkContents(in: directoryFD, files: Set(fingerprints.keys),
                                               directories: directories, isCancelled: isCancelled)
                observe?(.willVerifyFiles)
                for path in fingerprints.keys.sorted(by: DeskPackagePath.precedes) {
                    let expected = fingerprints[path]!
                    guard try fingerprint(path, in: directoryFD, expectedSize: expected.size,
                                          isCancelled: isCancelled) == expected.digest else { throw Failure.sourceChanged }
                    observe?(.didVerifyFile(path))
                }
                let after = try checkContents(in: directoryFD, files: Set(fingerprints.keys),
                                              directories: directories, isCancelled: isCancelled)
                guard before == after else { throw Failure.sourceChanged }
                observe?(.willRename)
                try checkCancelled(isCancelled)
                guard rootStillMatches(root, fd: rootFD), directoryStillMatches(in: rootFD, fd: directoryFD, name: name) else {
                    throw Failure.sourceChanged
                }
                let finalName = plan.packageID.uuidString.lowercased()
                guard renameatx_np(rootFD, name, rootFD, finalName, UInt32(RENAME_EXCL)) == 0 else {
                    throw errno == EEXIST || errno == ENOTEMPTY ? Failure.collision : Failure.io(errno)
                }
                name = finalName
                guard rootStillMatches(root, fd: rootFD), directoryStillMatches(in: rootFD, fd: directoryFD, name: name) else {
                    throw Failure.sourceChanged
                }
                guard fsync(rootFD) == 0 else { throw Failure.io(errno) }
                try checkCancelled(isCancelled)
                var rootInfo = stat(), directoryInfo = stat()
                guard fstat(rootFD, &rootInfo) == 0, fstat(directoryFD, &directoryInfo) == 0 else { throw Failure.io(errno) }
                try registration.publish()
                published = true
                return PackagePublication(plan: plan, root: root, directory: directory, members: admitted.members,
                    rootIdentity: DirectoryIdentity(rootInfo), directoryIdentity: DirectoryIdentity(directoryInfo), registration: registration)
            } catch { try? finish(.rejected); throw error }
        }

        func finish(_ decision: PackageDecision) throws {
            precondition(!Thread.isMainThread)
            guard !ended else { return }
            if case .registered = decision, !registration.isRegistered { throw Failure.disposed }
            let discard = registration.relinquish()
            ended = true
            defer { images.removeCopies(); Darwin.close(directoryFD); Darwin.close(rootFD) }
            if discard { try discardDirectory(in: rootFD, directory: directoryFD, name: name) }
        }
    }

    /// Main performs only constant-size identity checks and one state write. The acknowledgement is marked
    /// before returning, independently of whether the caller later delivers the worker's finish message.
    static func registerPackage(_ publication: PackagePublication, to state: AppState,
                                current: () -> Bool) throws -> InstalledPackage {
        precondition(Thread.isMainThread)
        return try publication.registration.register {
            guard current() else { throw Failure.staleSnapshot }
            let fd = open(publication.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw Failure.sourceChanged }
            defer { Darwin.close(fd) }
            var root = stat(), directory = stat()
            let name = publication.plan.packageID.uuidString.lowercased()
            guard fstat(fd, &root) == 0, publication.rootIdentity.matches(root),
                  fstatat(fd, name, &directory, AT_SYMLINK_NOFOLLOW) == 0,
                  publication.directoryIdentity.matches(directory) else { throw Failure.sourceChanged }
            let sources = publication.plan.members.map {
                DeskWidgetSourceState(id: $0.sourceID, entry: name + "/" + $0.file.path, packageID: publication.plan.packageID)
            }
            let instances = publication.plan.members.map { DeskWidgetInstanceState(id: $0.instanceID, sourceID: $0.sourceID) }
            guard let selected = publication.plan.members.first(where: {
                DeskPackagePath.sameBytes($0.file.path, publication.plan.selected.path)
            }) else { throw Failure.invalidPackage }
            try state.registerDeskInstallation(sources: sources, instances: instances)
            return InstalledPackage(sources: sources, instances: instances,
                                    selectedInstanceID: selected.instanceID, directory: publication.directory)
        }
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
        let opened = try makeStage(root: root, identity: sourceID)
        let rootFD = opened.root, stageFD = opened.directory, stageName = opened.name
        let staged = Staged(admitted: admitted, images: images, root: root, rootFD: rootFD,
                            directoryFD: stageFD, name: stageName, sourceID: sourceID, instanceID: instanceID)
        retained = true
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
            DeskWidgetInstallation.rootStillMatches(root, fd: rootFD)
        }

        private func directoryStillMatches() -> Bool {
            DeskWidgetInstallation.directoryStillMatches(in: rootFD, fd: directoryFD, name: name)
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

    private static func checkCancelled(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw Failure.disposed }
    }

    private static func validateCapture(_ capture: DeskPackageCapture, isCancelled: () -> Bool) throws {
        do { try capture.validateUnchanged(isCancelled: isCancelled) }
        catch DeskPackageCapture.Failure.cancelled { throw Failure.disposed }
        catch { throw Failure.sourceChanged }
    }

    private static func makeStage(root: URL, identity: UUID) throws -> (root: Int32, directory: Int32, name: String) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else { throw Failure.io(errno) }
        var transferred = false
        defer { if !transferred { Darwin.close(rootFD) } }
        let name = identity.uuidString.lowercased(), stageName = ".install-" + name
        var info = stat()
        if fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.collision }
        guard errno == ENOENT else { throw Failure.io(errno) }
        guard mkdirat(rootFD, stageName, 0o700) == 0 else {
            throw errno == EEXIST ? Failure.collision : Failure.io(errno)
        }
        let stageFD = openat(rootFD, stageName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stageFD >= 0 else {
            let code = errno
            _ = unlinkat(rootFD, stageName, AT_REMOVEDIR)
            throw Failure.io(code)
        }
        transferred = true
        return (rootFD, stageFD, stageName)
    }

    private static func rootStillMatches(_ root: URL, fd: Int32) -> Bool {
        let current = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { return false }
        defer { Darwin.close(current) }
        var held = stat(), named = stat()
        return fstat(fd, &held) == 0 && fstat(current, &named) == 0 && DirectoryIdentity(held).matches(named)
    }

    private static func directoryStillMatches(in root: Int32, fd: Int32, name: String) -> Bool {
        var held = stat(), named = stat()
        return fstat(fd, &held) == 0 && fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0
            && DirectoryIdentity(held).matches(named)
    }

    private static func discardDirectory(in root: Int32, directory: Int32, name: String) throws {
        var failure: Error?
        do { try removeContentsChecked(in: directory) } catch { failure = error }
        if directoryStillMatches(in: root, fd: directory, name: name), unlinkat(root, name, AT_REMOVEDIR) != 0,
           failure == nil { failure = Failure.io(errno) }
        if let failure { throw failure }
    }

    /// The only writable trees are an exclusive 0700 staging directory and its final App-owned name. Every
    /// component is a no-follow directory FD; filenames cannot traverse outside it or overwrite existing files.
    private static func parent(of path: String, in root: Int32, create: Bool,
                               known: [[UInt8]: DirectoryIdentity]? = nil) throws -> (fd: Int32, name: String) {
        guard !path.contains("\0"), let parts = DeskPackagePath.safeComponents(path), let last = parts.last else {
            throw Failure.invalidSource
        }
        var directory = dup(root)
        guard directory >= 0 else { throw Failure.io(errno) }
        var prefix = ""
        do {
            for part in parts.dropLast() {
                if create && mkdirat(directory, part, 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
                let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw Failure.io(errno) }
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                if let known {
                    var held = stat(), named = stat()
                    guard let expected = known[Array(prefix.utf8)], fstat(next, &held) == 0,
                          fstatat(directory, part, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          expected.matches(held), expected.matches(named) else {
                        Darwin.close(next); throw Failure.sourceChanged
                    }
                }
                Darwin.close(directory); directory = next
            }
            return (directory, last)
        } catch { Darwin.close(directory); throw error }
    }

    private static func directory(_ path: String, in root: Int32, create: Bool,
                                  known: [[UInt8]: DirectoryIdentity]? = nil) throws -> Int32 {
        if path.isEmpty {
            let fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw Failure.io(errno) }
            return fd
        }
        let location = try parent(of: path, in: root, create: create, known: known)
        defer { Darwin.close(location.fd) }
        if create && mkdirat(location.fd, location.name, 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
        let fd = openat(location.fd, location.name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.io(errno) }
        if let known {
            var held = stat(), named = stat()
            guard let expected = known[Array(path.utf8)], fstat(fd, &held) == 0,
                  fstatat(location.fd, location.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  expected.matches(held), expected.matches(named) else {
                Darwin.close(fd); throw Failure.sourceChanged
            }
        }
        return fd
    }

    private static func create(_ path: String, in root: Int32) throws -> Int32 {
        let location = try parent(of: path, in: root, create: true)
        defer { Darwin.close(location.fd) }
        let fd = openat(location.fd, location.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? Failure.collision : Failure.io(errno) }
        return fd
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to fd: Int32,
                                 isCancelled: () -> Bool = { false }) throws {
        var offset = 0
        while offset < bytes.count {
            try checkCancelled(isCancelled)
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(64 * 1024, bytes.count - offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.io(count == 0 ? EIO : errno) }
            offset += count
        }
    }

    fileprivate struct Fingerprint {
        let digest: Data
        let size: Int
    }

    private static func write(_ bytes: Data, path: String, in root: Int32,
                              isCancelled: () -> Bool = { false }) throws -> Fingerprint {
        try checkCancelled(isCancelled)
        let fd = try create(path, in: root)
        defer { Darwin.close(fd) }
        try bytes.withUnsafeBytes { try writeAll($0, to: fd, isCancelled: isCancelled) }
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
    private static func fingerprint(_ path: String, in root: Int32, expectedSize: Int,
                                    isCancelled: () -> Bool = { false }) throws -> Data {
        try checkCancelled(isCancelled)
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
            try checkCancelled(isCancelled)
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

    /// Lists exactly the owned tree. Legacy callers admit only directories leading to a referenced file;
    /// package callers also supply independent empty directories. Raw keys retain every actual spelling.
    @discardableResult
    private static func checkContents(in root: Int32, files: Set<String>, directories supplied: Set<String>? = nil,
                                      isCancelled: () -> Bool = { false }) throws -> [[UInt8]: DeskPackageCapture.Identity] {
        var directories = supplied ?? [""]
        for path in files {
            guard let parts = DeskPackagePath.safeComponents(path) else { throw Failure.invalidPackage }
            if supplied == nil {
                for end in 1..<parts.count { directories.insert(parts[..<end].joined(separator: "/")) }
            }
        }
        let fileKeys = Set(files.map { Array($0.utf8) }), directoryKeys = Set(directories.map { Array($0.utf8) })
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0 else { throw Failure.sourceChanged }
        var known: [[UInt8]: DirectoryIdentity] = [[]: DirectoryIdentity(rootInfo)]
        var inventory: [[UInt8]: DeskPackageCapture.Identity] = [[]: try stamp(rootInfo)]
        var foundFiles = Set<[UInt8]>(), foundDirectories: Set<[UInt8]> = [[]]
        var pending = [""], index = 0
        while index < pending.count {
            try checkCancelled(isCancelled)
            let path = pending[index]; index += 1
            let fd = try directory(path, in: root, create: false, known: known)
            defer { Darwin.close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, try stamp(before) == inventory[Array(path.utf8)] else { throw Failure.sourceChanged }
            try forEachEntry(in: fd, isCancelled: isCancelled) { name, info in
                let child = path.isEmpty ? name : path + "/" + name, key = Array(child.utf8)
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard directoryKeys.contains(key), foundDirectories.insert(key).inserted else { throw Failure.sourceChanged }
                    known[key] = DirectoryIdentity(info)
                    pending.append(child)
                } else {
                    guard info.st_mode & S_IFMT == S_IFREG, fileKeys.contains(key), foundFiles.insert(key).inserted else {
                        throw Failure.sourceChanged
                    }
                }
                inventory[key] = try stamp(info)
            }
            guard fstat(fd, &after) == 0, try stamp(after) == stamp(before) else { throw Failure.sourceChanged }
        }
        guard foundFiles == fileKeys, foundDirectories == directoryKeys else { throw Failure.sourceChanged }
        return inventory
    }

    private static func stamp(_ info: stat) throws -> DeskPackageCapture.Identity {
        let kind: DeskPackageCapture.Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regular
        default: throw Failure.sourceChanged
        }
        return DeskPackageCapture.Identity(device: info.st_dev, inode: info.st_ino, kind: kind, size: info.st_size,
            mtimeSeconds: Int64(info.st_mtimespec.tv_sec), mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            ctimeSeconds: Int64(info.st_ctimespec.tv_sec), ctimeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func forEachEntry(in directory: Int32, isCancelled: () -> Bool = { false },
                                      _ body: (String, stat) throws -> Void) throws {
        let scan = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard scan >= 0 else { throw Failure.sourceChanged }
        guard let stream = fdopendir(scan) else { Darwin.close(scan); throw Failure.sourceChanged }
        defer { closedir(stream) }
        while true {
            try checkCancelled(isCancelled)
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.sourceChanged }
                break
            }
            let count = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(bytes: $0.prefix(count), encoding: .utf8) }
            guard let name, !name.contains("\0"), !name.contains("/") else { throw Failure.sourceChanged }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.sourceChanged }
            try body(name, info)
        }
    }

    private static func removeContents(in directory: Int32) { try? removeContentsChecked(in: directory) }

    /// Reopen from the held root with bounded live FDs, then remove directories in postorder. A changed child
    /// identity is left alone; even fallback cleanup never follows a link or descends a replaced ancestor.
    private static func removeContentsChecked(in root: Int32) throws {
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0 else { throw Failure.io(errno) }
        var known: [[UInt8]: DirectoryIdentity] = [[]: DirectoryIdentity(rootInfo)]
        var pending: [(path: String, afterChildren: Bool)] = [("", false)]
        var failure: Error?
        while let item = pending.popLast() {
            do {
                let fd = try directory(item.path, in: root, create: false, known: known)
                defer { Darwin.close(fd) }
                if item.afterChildren {
                    if !item.path.isEmpty {
                        let location = try parent(of: item.path, in: root, create: false, known: known)
                        defer { Darwin.close(location.fd) }
                        var named = stat()
                        guard let expected = known[Array(item.path.utf8)],
                              fstatat(location.fd, location.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                              expected.matches(named) else { throw Failure.sourceChanged }
                        guard unlinkat(location.fd, location.name, AT_REMOVEDIR) == 0 else { throw Failure.io(errno) }
                    }
                } else {
                    pending.append((item.path, true))
                    try forEachEntry(in: fd) { name, info in
                        if info.st_mode & S_IFMT == S_IFDIR {
                            let child = item.path.isEmpty ? name : item.path + "/" + name
                            known[Array(child.utf8)] = DirectoryIdentity(info)
                            pending.append((child, false))
                        } else {
                            guard unlinkat(fd, name, 0) == 0 else { throw Failure.io(errno) }
                        }
                    }
                }
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}
