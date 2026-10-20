import AppKit
import Darwin

/// An independent copy of the signed app finishes an update after the running app has saved and exited.
/// Merely preparing a handoff cannot replace anything: the parent must commit it after all quit vetoes pass.
enum AppUpdateInstaller {
    struct ProcessIdentity: Codable, Equatable {
        let seconds: Int64
        let microseconds: Int32
    }

    struct Manifest: Codable {
        let destination: URL
        let expectedVersion: String
        let parentPID: pid_t
        let parentIdentity: ProcessIdentity
    }

    enum Failure: LocalizedError {
        case invalidJob, unavailable, parentChanged, timedOut, helperFailed, launchFailed

        var errorDescription: String? {
            switch self {
            case .invalidJob: return "The prepared update could not be verified. Download the update again."
            case .unavailable: return "This copy of Deskset cannot update itself here. Move it to a writable Applications folder and try again."
            case .parentChanged: return "Deskset’s running process changed before the update could finish. The installed application was kept."
            case .timedOut: return "Deskset did not finish quitting in time. The installed application was kept."
            case .helperFailed: return "The update helper could not start. Deskset has not been replaced."
            case .launchFailed: return "Deskset was installed, but could not be opened automatically. Open it from its application folder."
            }
        }
    }

    final class Handoff {
        let directory: URL
        private let process: Process
        private var committed = false
        private var cancelled = false

        fileprivate init(directory: URL, process: Process) {
            self.directory = directory
            self.process = process
        }

        /// Call only after every editor/save veto has passed. The helper still waits for this exact process to exit.
        func commit() throws {
            guard !cancelled, process.isRunning else { throw Failure.helperFailed }
            guard !committed else { return }
            try AppUpdateInstaller.writeMarker(directory.appendingPathComponent("commit"))
            committed = true
        }

        /// Once committed, the helper owns cleanup; interrupting it could interrupt an application replacement.
        func cancel() {
            guard !committed, !cancelled else { return }
            cancelled = true
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// May run off the main thread. All copying and validation finish before the parent is asked to quit.
    static func prepare(source: URL, destination: URL, expectedVersion: String,
                        parentPID: pid_t = getpid()) throws -> Handoff {
        let fm = FileManager.default
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path == target.path,
              let identity = try processIdentity(parentPID) else { throw Failure.unavailable }
        try validateApplications(source: source, destination: target, expectedVersion: expectedVersion)
        let directory = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("DesksetUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var process: Process?
        do {
            // The executable signature includes its Info.plist: keep the complete bundle for verification.
            let helper = directory.appendingPathComponent("DesksetUpdater.app", isDirectory: true)
            try fm.copyItem(at: Bundle.main.bundleURL, to: helper)
            try AppInstallation.verifySignature(helper)
            let staged = directory.appendingPathComponent("Deskset.app", isDirectory: true)
            try fm.copyItem(at: source, to: staged)
            try AppInstallation.verifySignature(staged)
            let manifest = Manifest(destination: target, expectedVersion: expectedVersion,
                                    parentPID: parentPID, parentIdentity: identity)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            let child = Process()
            child.executableURL = helper.appendingPathComponent("Contents/MacOS/Deskset")
            child.arguments = ["--complete-update", manifestURL.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            process = child
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while child.isRunning && !fm.fileExists(atPath: directory.appendingPathComponent("ready").path)
                    && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard child.isRunning, fm.fileExists(atPath: directory.appendingPathComponent("ready").path)
            else { throw Failure.helperFailed }
            return Handoff(directory: directory, process: child)
        } catch {
            if let process, process.isRunning { process.terminate() }
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// Only the copied helper can consume its private manifest. Direct invocation in the ordinary app is refused.
    static func runHelper(manifest manifestURL: URL) -> Int32 {
        let directory = manifestURL.deletingLastPathComponent().standardizedFileURL
        var acceptedJob = false
        var committed = false
        var destination: URL?
        defer { if acceptedJob { try? FileManager.default.removeItem(at: directory) } }
        do {
            let manifest = try readManifest(at: manifestURL)
            acceptedJob = true
            destination = manifest.destination
            let source = directory.appendingPathComponent("Deskset.app", isDirectory: true)
            try validateApplications(source: source, destination: manifest.destination, expectedVersion: manifest.expectedVersion)
            guard try processIdentity(manifest.parentPID) == manifest.parentIdentity else { throw Failure.parentChanged }
            try writeMarker(directory.appendingPathComponent("ready"))
            try waitForParentExit(manifest, committed: {
                let marker = directory.appendingPathComponent("commit")
                guard FileManager.default.fileExists(atPath: marker.path) else { return false }
                try validatePrivateItem(marker, directory: false)
                committed = true
                return true
            })
            try validateApplications(source: source, destination: manifest.destination, expectedVersion: manifest.expectedVersion)
            return finishInstallation(source: source, destination: manifest.destination)
        } catch {
            // Before commitment, the still-running parent reports preparation/cancellation errors itself.
            if committed, let destination {
                showFailure(error, destination: destination)
                if (try? AppInstallation.info(at: destination)) != nil { try? openApplication(destination) }
            }
            return 1
        }
    }

    static func validateApplications(source: URL, destination: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        guard destination.pathExtension == "app",
              destination.standardizedFileURL.path == destination.resolvingSymlinksInPath().standardizedFileURL.path,
              source.resolvingSymlinksInPath().standardizedFileURL.path != destination.standardizedFileURL.path,
              fm.isWritableFile(atPath: destination.path),
              fm.isWritableFile(atPath: destination.deletingLastPathComponent().path)
        else { throw Failure.unavailable }
        let incoming = try AppInstallation.info(at: source)
        guard incoming.version == expectedVersion else { throw Failure.invalidJob }
        try AppInstallation.checkVersion(source: incoming, installed: try AppInstallation.info(at: destination))
    }

    static func processIdentity(_ pid: pid_t) throws -> ProcessIdentity? {
        guard pid > 1 else { throw Failure.invalidJob }
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, u_int(query.count), &info, &length, nil, 0) == 0 else {
            if errno == ESRCH { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard length > 0 else { return nil }
        return ProcessIdentity(seconds: Int64(info.kp_proc.p_starttime.tv_sec),
                               microseconds: Int32(info.kp_proc.p_starttime.tv_usec))
    }

    /// An error alert registers the helper with Launch Services. A relaunched app must not hand off to it.
    static func isHelperApplication(_ bundle: URL) -> Bool {
        let directory = bundle.deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard bundle.lastPathComponent == "DesksetUpdater.app", directory.lastPathComponent.hasPrefix("DesksetUpdate-"),
              directory.deletingLastPathComponent().path == temporary.path,
              bundle.standardizedFileURL.path == bundle.resolvingSymlinksInPath().standardizedFileURL.path
        else { return false }
        // Cleanup removes the private job just before helper exit; Launch Services can briefly retain its entry.
        if !FileManager.default.fileExists(atPath: directory.path) { return true }
        let manifest = directory.appendingPathComponent("manifest.json")
        do {
            try validatePrivateItem(directory, directory: true)
            try validatePrivateItem(manifest, directory: false)
            return true
        } catch { return false }
    }

    /// No app files are touched until both consent and the original process's exit have been observed.
    static func waitForParentExit(_ manifest: Manifest, committed: () throws -> Bool,
                                  identity: (pid_t) throws -> ProcessIdentity? = processIdentity,
                                  now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                  pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }) throws {
        try waitForParentExit(parentPID: manifest.parentPID, parentIdentity: manifest.parentIdentity,
                              committed: committed, identity: identity, now: now, pause: pause)
    }

    /// Shared by helpers that wait for an authorized, exact process exit. Returns the remaining deadline so a
    /// caller can check it again after its final file validation. Slow callbacks cannot authorize an expired job.
    @discardableResult
    static func waitForParentExit(parentPID: pid_t, parentIdentity: ProcessIdentity,
                                  committed: () throws -> Bool,
                                  identity: (pid_t) throws -> ProcessIdentity? = processIdentity,
                                  now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                  pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }) throws -> TimeInterval {
        let started = now()
        guard parentPID > 1, started.isFinite else { throw Failure.invalidJob }
        var previousTime = started
        var deadline = started + 1800
        var committedAt: TimeInterval?
        func checkTime() throws -> TimeInterval {
            let time = now()
            guard time.isFinite, time >= previousTime, time < deadline else { throw Failure.timedOut }
            previousTime = time
            return time
        }
        while true {
            _ = try checkTime()
            let authorized = try committed()
            let afterCommit = try checkTime()
            if authorized, committedAt == nil {
                committedAt = afterCommit
                deadline = afterCommit + 60
            }
            let current = try identity(parentPID)
            _ = try checkTime()
            if current == nil {
                guard committedAt != nil else { throw Failure.helperFailed }
                return deadline
            }
            guard current == parentIdentity else { throw Failure.parentChanged }
            pause()
        }
    }

    static func finishInstallation(source: URL, destination: URL,
                                   install: (URL, URL) throws -> Void = { try AppInstallation.install(source: $0, destination: $1) },
                                   open: (URL) throws -> Void = openApplication,
                                   report: (Error, URL) -> Void = showFailure) -> Int32 {
        do {
            try install(source, destination)
        } catch {
            report(error, destination)
            // install() has already restored its backup on a failed replacement. Only open a complete app.
            if (try? AppInstallation.info(at: destination)) != nil {
                do { try open(destination) } catch { report(error, destination) }
            }
            return 1
        }
        do { try open(destination); return 0 }
        catch { report(error, destination); return 1 }
    }

    private static func readManifest(at url: URL) throws -> Manifest {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        guard url.lastPathComponent == "manifest.json", directory.lastPathComponent.hasPrefix("DesksetUpdate-"),
              directory.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              Bundle.main.executableURL?.resolvingSymlinksInPath().path
                == directory.appendingPathComponent("DesksetUpdater.app/Contents/MacOS/Deskset").path
        else { throw Failure.invalidJob }
        try validatePrivateItem(directory, directory: true)
        try validatePrivateItem(url, directory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue < 16_384 else { throw Failure.invalidJob }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.parentPID > 1, manifest.parentPID != getpid(),
              ReleaseVersion(manifest.expectedVersion) != nil,
              !manifest.destination.path.hasPrefix(directory.path + "/") else { throw Failure.invalidJob }
        return manifest
    }

    private static func validatePrivateItem(_ url: URL, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == (directory ? 0o700 : 0o600)
        else { throw Failure.invalidJob }
    }

    private static func writeMarker(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func openApplication(_ target: URL) throws {
        // NSWorkspace can launch without NSApplication. Registering this same-bundle-ID helper with Launch
        // Services would let the target mistake it for an older running instance and immediately quit.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        var finished = false
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            DispatchQueue.main.async { launchError = error; finished = true }
        }
        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard finished else { throw Failure.launchFailed }
        if let launchError { throw launchError }
    }

    static func makeFailureAlert(error: Error, destination: URL) -> AppMaintenancePanel {
        let alert = AppMaintenancePanel()
        alert.alertStyle = .warning
        alert.content.badgeText = ""
        alert.messageText = "Couldn’t finish updating Deskset"
        alert.informativeText = "Your skins, layouts, and settings are kept."
        alert.content.configureErrorCard(
            message: error.localizedDescription,
            bottomNote: "Application location: \(destination.path)"
        )
        alert.content.footnote.stringValue = destination.deletingLastPathComponent().path
        alert.addButton(withTitle: "Close")
        return alert
    }

    private static func showFailure(_ error: Error, destination: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = makeFailureAlert(error: error, destination: destination)
        alert.runModal()
    }
}
