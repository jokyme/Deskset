import Foundation
import Darwin

/// A separate process records the kernel's exit status after the application itself has stopped.
/// An unfinished session is never evidence of a crash.
final class StartupCrashWatcher {
    struct Summary: Equatable {
        let recentCrashCount: Int
        let warning: String?
    }

    struct Manifest: Codable, Equatable {
        let session: String
        let nonce: String
        let parentPID: pid_t
        let parentIdentity: AppUpdateInstaller.ProcessIdentity
        let executable: URL
        let startedAt: TimeInterval
    }

    struct Ready: Codable, Equatable {
        let manifest: Manifest
        let watcherPID: pid_t
        let watcherIdentity: AppUpdateInstaller.ProcessIdentity
    }

    struct Result: Codable {
        let ready: Ready
        let exitedAt: TimeInterval
        let status: Int32
    }

    final class Child {
        let isRunning: () -> Bool
        init(isRunning: @escaping () -> Bool) { self.isRunning = isRunning }
    }

    final class Observation {
        let wait: () throws -> Int32
        private let release: () -> Void
        init(wait: @escaping () throws -> Int32, release: @escaping () -> Void = {}) {
            self.wait = wait
            self.release = release
        }
        deinit { release() }
    }

    struct Files {
        var makeDirectory: (URL) throws -> Void = makePrivateDirectory
        var read: (URL) throws -> Data? = readPrivateFile
        var write: (Data, URL) throws -> Void = writePrivateFile
        var directories: (URL) throws -> [URL] = { url in
            try validateDirectory(url)
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
        }
        var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }

    struct Dependencies {
        var identity: (pid_t) throws -> AppUpdateInstaller.ProcessIdentity? = AppUpdateInstaller.processIdentity
        var owner: (pid_t) throws -> uid_t? = processOwner
        var pid: () -> pid_t = { getpid() }
        var parentPID: () -> pid_t = { getppid() }
        var uid: () -> uid_t = { getuid() }
        var executable: () -> URL? = { Bundle.main.executableURL }
        var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var launch: (URL, URL, String) throws -> Child = launchChild
        var observe: (pid_t) throws -> Observation = observeExit
        var files = Files()
        static var live: Dependencies { Dependencies() }
    }

    enum Failure: LocalizedError {
        case invalidRecord, changedProcess, unavailable, notReady
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "A startup observation record could not be verified."
            case .changedProcess: return "The process changed before startup observation was ready."
            case .unavailable: return "The system could not observe this application's exit."
            case .notReady: return "Startup observation did not become ready in time."
            }
        }
    }

    static let argument = "--watch-startup-crash"
    static let directoryName = "startup-crashes"
    private let directory: URL
    private let executable: URL
    private let dependencies: Dependencies
    private let queue = DispatchQueue(label: "Deskset.StartupCrashWatcher", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var summary: Summary?
    private var completions: [(Summary) -> Void] = []
    // Retaining Process also keeps its termination handling alive. Normal app termination does not cancel it.
    private var child: Child?

    init(settingsDirectory: URL, executableURL: URL, dependencies: Dependencies = .live) {
        directory = settingsDirectory.resolvingSymlinksInPath().appendingPathComponent(Self.directoryName,
                                                                                     isDirectory: true)
        executable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        self.dependencies = dependencies
    }

    /// Multiple subscribers share one observation. Every callback is delivered asynchronously on main, once.
    func begin(completion: @escaping (Summary) -> Void) {
        lock.lock()
        if let summary {
            lock.unlock()
            DispatchQueue.main.async { completion(summary) }
            return
        }
        completions.append(completion)
        let shouldStart = !started
        started = true
        lock.unlock()
        if shouldStart {
            queue.async {
                let answer = self.prepare()
                self.lock.lock()
                self.summary = answer
                let callbacks = self.completions
                self.completions.removeAll()
                self.lock.unlock()
                DispatchQueue.main.async { callbacks.forEach { $0(answer) } }
            }
        }
    }

    private func prepare() -> Summary {
        var warnings: [String] = []
        var currentSession: String?
        do {
            try dependencies.files.makeDirectory(directory)
            let pid = dependencies.pid()
            guard let identity = try dependencies.identity(pid),
                  try dependencies.owner(pid) == dependencies.uid() else { throw Failure.changedProcess }
            let manifest = Manifest(session: UUID().uuidString, nonce: UUID().uuidString, parentPID: pid,
                                    parentIdentity: identity, executable: executable, startedAt: dependencies.now())
            currentSession = manifest.session
            let session = directory.appendingPathComponent(manifest.session, isDirectory: true)
            try dependencies.files.makeDirectory(session)
            let manifestURL = session.appendingPathComponent("manifest.json")
            try dependencies.files.write(JSONEncoder().encode(manifest), manifestURL)
            let launched = try dependencies.launch(executable, manifestURL, manifest.nonce)
            child = launched
            let deadline = dependencies.uptime() + 5
            while true {
                if let ready: Ready = try Self.decode(session.appendingPathComponent("ready.json"), using: dependencies.files) {
                    guard ready.manifest == manifest,
                          try dependencies.identity(ready.watcherPID) == ready.watcherIdentity,
                          try dependencies.owner(ready.watcherPID) == dependencies.uid(),
                          launched.isRunning() else { throw Failure.changedProcess }
                    break
                }
                guard launched.isRunning(), dependencies.uptime() < deadline else { throw Failure.notReady }
                dependencies.pause(0.025)
            }
        } catch { warnings.append(error.localizedDescription) }

        // Older evidence remains useful even if a new observer could not be started.
        let history = readHistory(excluding: currentSession)
        if let warning = history.warning { warnings.append(warning) }
        return Summary(recentCrashCount: history.recentCrashCount,
                       warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    private func readHistory(excluding current: String?) -> Summary {
        var sessions: [(URL, Manifest, Ready)] = []
        var warning: String?
        do {
            for url in try dependencies.files.directories(directory) where url.lastPathComponent != current {
                guard UUID(uuidString: url.lastPathComponent) != nil else { continue }
                do {
                    guard let manifest: Manifest = try Self.decode(url.appendingPathComponent("manifest.json"),
                                                                  using: dependencies.files) else { continue }
                    try Self.validate(manifest, at: url)
                    guard let ready: Ready = try Self.decode(url.appendingPathComponent("ready.json"),
                                                            using: dependencies.files) else { continue }
                    guard ready.manifest == manifest, ready.watcherPID > 1,
                          ready.watcherPID != manifest.parentPID else { throw Failure.invalidRecord }
                    sessions.append((url, manifest, ready))
                } catch { warning = error.localizedDescription }
            }
        } catch { warning = error.localizedDescription }

        // A previous main process can release its single-instance lock before the kernel reports its exit.
        // Give its already-ready observer time to commit the result, without ever blocking the UI thread.
        let deadline = dependencies.uptime() + 2
        var crashes: [String: TimeInterval] = [:]
        var remaining = sessions
        while !remaining.isEmpty {
            var pending: [(URL, Manifest, Ready)] = []
            for (url, manifest, ready) in remaining {
                do {
                    let resultURL = url.appendingPathComponent("result.json")
                    var result: Result? = try Self.decode(resultURL, using: dependencies.files)
                    if result == nil {
                        if try dependencies.identity(ready.watcherPID) == ready.watcherIdentity,
                           try dependencies.owner(ready.watcherPID) == dependencies.uid() {
                            pending.append((url, manifest, ready))
                            continue
                        }
                        // Its atomic result may have appeared between the first read and observing its exit.
                        result = try Self.decode(resultURL, using: dependencies.files)
                    }
                    guard let result else {
                        warning = "A previous startup observer ended without an exit result."
                        continue
                    }
                    guard result.ready == ready, result.exitedAt.isFinite, result.exitedAt >= manifest.startedAt,
                          result.status >= 0, result.status <= 0xffff else { throw Failure.invalidRecord }
                    let age = dependencies.now() - result.exitedAt
                    if Self.isFatalStatus(result.status) {
                        let identity = "\(manifest.parentPID):\(manifest.parentIdentity.seconds):\(manifest.parentIdentity.microseconds)"
                        crashes[identity] = max(crashes[identity] ?? result.exitedAt, result.exitedAt)
                    }
                    // Completed, expired sessions only. Never remove an active process's directory.
                    if age > 300, try dependencies.identity(manifest.parentPID) != manifest.parentIdentity {
                        try? dependencies.files.remove(url)
                    }
                } catch { warning = error.localizedDescription }
            }
            guard !pending.isEmpty else { break }
            guard dependencies.uptime() < deadline else {
                warning = "A previous startup observer has not finished recording its exit result."
                break
            }
            remaining = pending
            dependencies.pause(0.025)
        }
        let now = dependencies.now()
        let recent = crashes.values.filter { now - $0 >= 0 && now - $0 <= 300 }.count
        return Summary(recentCrashCount: recent, warning: warning)
    }

    /// Called before ordinary command-line initialization. Malformed helper requests never start the app.
    static func runEarlyIfRequested(_ args: [String]) -> Int32? {
        guard args.dropFirst().first == argument else { return nil }
        guard args.count == 4 else { return 2 }
        return runHelper(manifestURL: URL(fileURLWithPath: args[2]), nonce: args[3], dependencies: .live)
    }

    static func runHelper(manifestURL: URL, nonce: String, dependencies d: Dependencies) -> Int32 {
        do {
            let session = manifestURL.deletingLastPathComponent().standardizedFileURL
            guard manifestURL.lastPathComponent == "manifest.json",
                  session.deletingLastPathComponent().lastPathComponent == directoryName,
                  UUID(uuidString: nonce) != nil,
                  let manifest: Manifest = try decode(manifestURL, using: d.files) else { throw Failure.invalidRecord }
            try validate(manifest, at: session)
            guard manifest.nonce == nonce,
                  manifest.executable == d.executable()?.resolvingSymlinksInPath().standardizedFileURL,
                  d.parentPID() == manifest.parentPID,
                  try d.identity(manifest.parentPID) == manifest.parentIdentity,
                  try d.owner(manifest.parentPID) == d.uid() else { throw Failure.changedProcess }
            let observation = try d.observe(manifest.parentPID)
            // Registration's kernel receipt must precede READY. Recheck birth identity after registering.
            guard d.parentPID() == manifest.parentPID,
                  try d.identity(manifest.parentPID) == manifest.parentIdentity,
                  try d.owner(manifest.parentPID) == d.uid(),
                  d.pid() > 1, d.pid() != manifest.parentPID,
                  let watcherIdentity = try d.identity(d.pid()) else { throw Failure.changedProcess }
            let ready = Ready(manifest: manifest, watcherPID: d.pid(), watcherIdentity: watcherIdentity)
            try d.files.write(JSONEncoder().encode(ready), session.appendingPathComponent("ready.json"))
            let status = try observation.wait()
            let result = Result(ready: ready, exitedAt: d.now(), status: status)
            try d.files.write(JSONEncoder().encode(result), session.appendingPathComponent("result.json"))
            return 0
        } catch { return 1 }
    }

    static func isFatalStatus(_ status: Int32) -> Bool {
        guard status >= 0, status <= 0xffff else { return false }
        let signal = status & 0x7f
        return [SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE].contains(signal)
    }

    private static func validate(_ manifest: Manifest, at session: URL) throws {
        guard manifest.session == session.lastPathComponent, UUID(uuidString: manifest.session) != nil,
              UUID(uuidString: manifest.nonce) != nil, manifest.parentPID > 1,
              manifest.parentIdentity.seconds > 0, (0..<1_000_000).contains(manifest.parentIdentity.microseconds),
              manifest.startedAt.isFinite, manifest.executable.isFileURL else { throw Failure.invalidRecord }
    }

    private static func decode<T: Decodable>(_ url: URL, using files: Files) throws -> T? {
        guard let data = try files.read(url) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func launchChild(executable: URL, manifest: URL, nonce: String) throws -> Child {
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, manifest.path, nonce]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return Child(isRunning: { process.isRunning })
    }

    private static func observeExit(_ pid: pid_t) throws -> Observation {
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw posixFailure() }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { close(descriptor); throw posixFailure() }
        var change = kevent64_s(ident: UInt64(pid), filter: Int16(EVFILT_PROC),
                               flags: UInt16(EV_ADD | EV_ENABLE | EV_RECEIPT),
                               fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: 0, ext: (0, 0))
        var receipt = kevent64_s()
        var zero = timespec()
        let registered = kevent64(descriptor, &change, 1, &receipt, 1, 0, &zero)
        guard registered == 1, receipt.flags & UInt16(EV_ERROR) != 0, receipt.data == 0 else {
            close(descriptor)
            throw Failure.unavailable
        }
        return Observation(wait: {
            var event = kevent64_s()
            var received: Int32
            repeat { received = kevent64(descriptor, nil, 0, &event, 1, 0, nil) } while received < 0 && errno == EINTR
            guard received == 1, event.filter == Int16(EVFILT_PROC), event.ident == UInt64(pid),
                  event.flags & UInt16(EV_ERROR) == 0, event.fflags & UInt32(NOTE_EXIT) != 0,
                  let status = Int32(exactly: event.data) else { throw Failure.unavailable }
            return status
        }, release: { close(descriptor) })
    }

    private static func processOwner(_ pid: pid_t) throws -> uid_t? {
        guard pid > 1 else { throw Failure.changedProcess }
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, u_int(query.count), &info, &length, nil, 0) == 0 else {
            if errno == ESRCH { return nil }
            throw posixFailure()
        }
        return length > 0 ? info.kp_eproc.e_ucred.cr_uid : nil
    }

    private static func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700, info.st_uid == getuid() else { throw Failure.invalidRecord }
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw posixFailure() }
        try validateDirectory(url)
    }

    private static func readPrivateFile(_ url: URL) throws -> Data? {
        try validateDirectory(url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw posixFailure()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_size >= 0,
              info.st_size <= 16_384 else { throw Failure.invalidRecord }
        var result = Data(count: Int(info.st_size))
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.invalidRecord }
                offset += count
            }
        }
        return result
    }

    private static func writePrivateFile(_ data: Data, _ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try validateDirectory(directory)
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
