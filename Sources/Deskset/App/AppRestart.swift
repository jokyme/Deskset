import Foundation
import Darwin

/// A private instance of the current executable waits for an authorized exit, then opens the same application.
/// Preparing a restart does not quit or change the running application.
enum AppRestart {
    struct Manifest: Codable, Equatable {
        let job: String
        let nonce: String
        let appURL: URL
        let executableURL: URL
        let parentPID: pid_t
        let parentIdentity: AppUpdateInstaller.ProcessIdentity
    }

    struct Ready: Codable, Equatable {
        let manifest: Manifest
        let helperPID: pid_t
        let helperIdentity: AppUpdateInstaller.ProcessIdentity
    }

    final class Child {
        let pid: pid_t
        let isRunning: () -> Bool
        let terminate: () -> Void
        init(pid: pid_t, isRunning: @escaping () -> Bool, terminate: @escaping () -> Void) {
            self.pid = pid
            self.isRunning = isRunning
            self.terminate = terminate
        }
    }

    struct Files {
        var makeDirectory: (URL) throws -> Void = makePrivateDirectory
        var validateDirectory: (URL) throws -> Void = validatePrivateDirectory
        var read: (URL) throws -> Data? = readPrivateFile
        var write: (Data, URL) throws -> Void = writePrivateFile
        var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }

    struct Dependencies {
        var currentAppURL: () -> URL = { Bundle.main.bundleURL }
        var currentExecutableURL: () -> URL? = { Bundle.main.executableURL }
        var pid: () -> pid_t = { getpid() }
        var parentPID: () -> pid_t = { getppid() }
        var identity: (pid_t) throws -> AppUpdateInstaller.ProcessIdentity? = AppUpdateInstaller.processIdentity
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var temporaryDirectory: () -> URL = { FileManager.default.temporaryDirectory.resolvingSymlinksInPath() }
        var files = Files()
        var spawn: (URL, [String]) throws -> Child = spawnChild
        var openApplication: (URL) throws -> Void = AppUpdateInstaller.openApplication
        var validateApplication: (URL) throws -> Void = { _ = try AppInstallation.info(at: $0) }
        static var live: Dependencies { Dependencies() }
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, invalidJob, helperFailed, cancelled, parentChanged, timedOut
        var errorDescription: String? {
            switch self {
            case .unavailable: return "This copy of Deskset could not prepare an automatic restart."
            case .invalidJob: return "The prepared restart could not be verified."
            case .helperFailed: return "The restart helper could not start. Deskset is still running."
            case .cancelled: return "The restart was cancelled."
            case .parentChanged: return "The running process changed before the restart could finish."
            case .timedOut: return "Deskset did not finish preparing or quitting in time."
            }
        }
    }

    /// Commit and cancellation are called serially on main, after preparation finishes on a worker.
    final class Handoff {
        let directory: URL
        private let ready: Ready
        private let child: Child
        private let dependencies: Dependencies
        private var committed = false
        private var cancelled = false

        init(directory: URL, ready: Ready, child: Child, dependencies: Dependencies) {
            self.directory = directory
            self.ready = ready
            self.child = child
            self.dependencies = dependencies
        }

        /// Called only after every editor/save veto has passed. Repeated commitment does not extend the wait.
        func commit() throws {
            guard !cancelled else { throw Failure.cancelled }
            guard child.isRunning(), child.pid == ready.helperPID,
                  try dependencies.identity(child.pid) == ready.helperIdentity,
                  try dependencies.identity(ready.manifest.parentPID) == ready.manifest.parentIdentity
            else { throw Failure.helperFailed }
            try verifyJob(directory: directory, ready: ready, files: dependencies.files)
            guard !committed else { return }
            try dependencies.files.write(JSONEncoder().encode(ready), directory.appendingPathComponent("commit.json"))
            committed = true
        }

        /// While this parent is alive its helper cannot launch anything, even after commitment.
        /// Removing or revoking the job makes every later helper poll fail closed.
        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            try? dependencies.files.write(JSONEncoder().encode(ready), directory.appendingPathComponent("cancel.json"))
            if child.isRunning() { child.terminate() }
            try? dependencies.files.remove(directory)
        }
    }

    static let argument = "--complete-restart"
    private static let jobPrefix = "DesksetRestart-"

    /// No application files are copied or written; only the private temporary job needs to be writable.
    static func prepare(appURL: URL, parentPID: pid_t = getpid(),
                        dependencies d: Dependencies = .live) throws -> Handoff {
        let target = URL(fileURLWithPath: appURL.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
        let currentApp = d.currentAppURL()
        guard appURL.isFileURL, currentApp.isFileURL, target.pathExtension == "app", parentPID == d.pid(),
              target.path == currentApp.resolvingSymlinksInPath().standardizedFileURL.path,
              let executable = d.currentExecutableURL()?.resolvingSymlinksInPath().standardizedFileURL,
              executable == target.appendingPathComponent("Contents/MacOS/Deskset"),
              let identity = try d.identity(parentPID) else { throw Failure.unavailable }
        try d.validateApplication(target)
        let job = UUID().uuidString
        let directory = d.temporaryDirectory().resolvingSymlinksInPath()
            .appendingPathComponent(jobPrefix + job, isDirectory: true)
        try d.files.makeDirectory(directory)
        var child: Child?
        do {
            let manifest = Manifest(job: job, nonce: UUID().uuidString, appURL: target, executableURL: executable,
                                    parentPID: parentPID, parentIdentity: identity)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            try d.files.write(JSONEncoder().encode(manifest), manifestURL)
            let process = try d.spawn(executable, [argument, manifestURL.path, manifest.nonce])
            child = process
            let started = d.now()
            guard started.isFinite else { throw Failure.timedOut }
            let deadline = started + 10
            while true {
                try checkDeadline(started: started, deadline: deadline, now: d.now())
                if let ready: Ready = try decode(directory.appendingPathComponent("ready.json"), files: d.files) {
                    guard ready.manifest == manifest, ready.helperPID == process.pid, ready.helperPID != parentPID,
                          try d.identity(ready.helperPID) == ready.helperIdentity,
                          process.isRunning() else { throw Failure.helperFailed }
                    try checkDeadline(started: started, deadline: deadline, now: d.now())
                    return Handoff(directory: directory, ready: ready, child: process, dependencies: d)
                }
                try checkDeadline(started: started, deadline: deadline, now: d.now())
                guard process.isRunning() else { throw Failure.helperFailed }
                d.pause(0.025)
            }
        } catch {
            if let child, child.isRunning() { child.terminate() }
            try? d.files.remove(directory)
            throw error
        }
    }

    static func runEarlyIfRequested(_ args: [String]) -> Int32? {
        guard args.dropFirst().first == argument else { return nil }
        guard args.count == 4 else { return 2 }
        return runHelper(manifestURL: URL(fileURLWithPath: args[2]), nonce: args[3], dependencies: .live)
    }

    /// The early helper never creates NSApplication, opens an alert, or initializes the desktop.
    static func runHelper(manifestURL: URL, nonce: String, dependencies d: Dependencies) -> Int32 {
        let directory = manifestURL.deletingLastPathComponent().standardizedFileURL
        var accepted = false
        defer { if accepted { try? d.files.remove(directory) } }
        do {
            guard manifestURL.lastPathComponent == "manifest.json",
                  directory.deletingLastPathComponent().path == d.temporaryDirectory().resolvingSymlinksInPath().standardizedFileURL.path,
                  let manifest: Manifest = try decode(manifestURL, files: d.files) else { throw Failure.invalidJob }
            try validate(manifest, directory: directory, nonce: nonce, dependencies: d)
            guard d.parentPID() == manifest.parentPID, d.pid() != manifest.parentPID,
                  try d.identity(manifest.parentPID) == manifest.parentIdentity,
                  let helperIdentity = try d.identity(d.pid()) else { throw Failure.parentChanged }
            accepted = true
            let ready = Ready(manifest: manifest, helperPID: d.pid(), helperIdentity: helperIdentity)
            try d.files.write(JSONEncoder().encode(ready), directory.appendingPathComponent("ready.json"))
            let started = d.now()
            let deadline = try AppUpdateInstaller.waitForParentExit(parentPID: manifest.parentPID,
                parentIdentity: manifest.parentIdentity, committed: {
                    try verifyJob(directory: directory, ready: ready, files: d.files)
                    guard let commit: Ready = try decode(directory.appendingPathComponent("commit.json"), files: d.files)
                    else { return false }
                    guard commit == ready else { throw Failure.invalidJob }
                    return true
                }, identity: d.identity, now: d.now, pause: { d.pause(0.1) })
            // Recheck authorization, the application and the departed process after the wait, without a fallback launch.
            try verifyJob(directory: directory, ready: ready, files: d.files)
            guard let commit: Ready = try decode(directory.appendingPathComponent("commit.json"), files: d.files),
                  commit == ready else { throw Failure.invalidJob }
            try d.validateApplication(manifest.appURL)
            guard try d.identity(manifest.parentPID) == nil else { throw Failure.parentChanged }
            try checkDeadline(started: started, deadline: deadline, now: d.now())
            try d.openApplication(manifest.appURL)
            return 0
        } catch { return 1 }
    }

    private static func checkDeadline(started: TimeInterval, deadline: TimeInterval, now: TimeInterval) throws {
        guard now.isFinite, now >= started, now < deadline else { throw Failure.timedOut }
    }

    private static func validate(_ manifest: Manifest, directory: URL, nonce: String,
                                 dependencies d: Dependencies) throws {
        try d.files.validateDirectory(directory)
        guard UUID(uuidString: manifest.job) != nil, UUID(uuidString: nonce) != nil, manifest.nonce == nonce,
              directory.lastPathComponent == jobPrefix + manifest.job, manifest.parentPID > 1,
              manifest.parentIdentity.seconds > 0, (0..<1_000_000).contains(manifest.parentIdentity.microseconds),
              manifest.appURL.isFileURL, manifest.appURL.pathExtension == "app", d.currentAppURL().isFileURL,
              manifest.appURL.path == d.currentAppURL().resolvingSymlinksInPath().standardizedFileURL.path,
              manifest.executableURL == d.currentExecutableURL()?.resolvingSymlinksInPath().standardizedFileURL,
              manifest.executableURL == manifest.appURL.appendingPathComponent("Contents/MacOS/Deskset")
        else { throw Failure.invalidJob }
        try d.validateApplication(manifest.appURL)
    }

    private static func verifyJob(directory: URL, ready: Ready, files: Files) throws {
        try files.validateDirectory(directory)
        if let _: Ready = try decode(directory.appendingPathComponent("cancel.json"), files: files) {
            throw Failure.cancelled
        }
        guard let manifest: Manifest = try decode(directory.appendingPathComponent("manifest.json"), files: files),
              manifest == ready.manifest,
              let recorded: Ready = try decode(directory.appendingPathComponent("ready.json"), files: files), recorded == ready
        else { throw Failure.invalidJob }
    }

    private static func decode<T: Decodable>(_ url: URL, files: Files) throws -> T? {
        guard let data = try files.read(url) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func spawnChild(executable: URL, arguments: [String]) throws -> Child {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return Child(pid: process.processIdentifier, isRunning: { process.isRunning },
                     terminate: { if process.isRunning { process.terminate() } })
    }

    private static func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func validatePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700, info.st_uid == getuid() else { throw Failure.invalidJob }
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else { throw posixFailure() }
        try validatePrivateDirectory(url)
    }

    private static func readPrivateFile(_ url: URL) throws -> Data? {
        try validatePrivateDirectory(url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw posixFailure()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_size >= 0,
              info.st_size <= 16_384 else { throw Failure.invalidJob }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.invalidJob }
                offset += count
            }
        }
        return data
    }

    private static func writePrivateFile(_ data: Data, _ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try validatePrivateDirectory(directory)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixFailure() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw posixFailure() }
    }
}
