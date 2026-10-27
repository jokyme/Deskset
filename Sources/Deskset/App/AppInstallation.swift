import AppKit

/// The downloaded disk image can install the app before normal startup (or duplicate-instance handoff).
enum AppInstallation {
    static let bundleID = "app.deskset.Deskset"

    struct AppInfo: Equatable {
        let version: String
    }

    enum Failure: LocalizedError, Equatable {
        case invalidApp, invalidVersion, olderVersion(String), notWritable(URL), running, signature
        case recovery(URL)

        var errorDescription: String? {
            switch self {
            case .invalidApp: return L("This is not a complete Deskset application. Download a fresh copy and try again.")
            case .invalidVersion: return L("The application’s version could not be verified. Use Finder to inspect the installed copy.")
            case .olderVersion(let version): return L("Deskset %@ is already installed. This older copy will not replace it.", version)
            case .notWritable(let url):
                return L("Deskset cannot write to %@. Quit the installed copy, then drag Deskset to that folder in Finder and choose Replace.", url.deletingLastPathComponent().path)
            case .running: return L("Another copy of Deskset is still running. Quit it from its menu, save any edits, then try again.")
            case .signature: return L("The copied application’s signature could not be verified. Download a fresh copy and try again.")
            case .recovery(let url): return L("The installation could not finish. Your previous application is kept at %@. Restore it with Finder before trying again.", url.path)
            }
        }
    }

    /// Pure detection: installed apps, development binaries and writable external drives do not prompt.
    static func needsInstallation(bundle: URL, volume: URL?, readOnly: Bool) -> Bool {
        guard bundle.pathExtension.lowercased() == "app", readOnly, let volume else { return false }
        let root = volume.standardizedFileURL.path
        return volume.deletingLastPathComponent().path == "/Volumes"
            && bundle.standardizedFileURL.path.hasPrefix(root + "/")
    }

    /// True means the caller must skip normal startup and must not save its unstarted AppState when it exits.
    /// All UI/exit work is deferred so the caller can set that guard before a modal run loop begins.
    static func handleLaunchIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL
        guard isInstallationSource(source) else { return false }
        scheduleAfterLaunch { begin(source: source) }
        return true
    }

    static func scheduleAfterLaunch(_ operation: @escaping () -> Void) {
        // A modal loop entered from a main-queue block cannot drain another main-queue block. Start from the
        // run loop instead, so the worker's completion can close the progress alert and open the installed app.
        RunLoop.main.perform(operation)
    }

    /// A newly installed app must not hand off to the disk-image process that is opening it.
    static func isInstallationSource(_ source: URL) -> Bool {
        let values = try? source.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey])
        return needsInstallation(bundle: source, volume: values?.volume, readOnly: values?.volumeIsReadOnly == true)
    }

    /// Prefer an existing installation; never create a second copy to bypass its permissions.
    static func destination(system: URL, user: URL, exists: (URL) -> Bool,
                            writable: (URL) -> Bool) throws -> URL {
        for folder in [system, user] {
            let app = folder.appendingPathComponent("Deskset.app", isDirectory: true)
            if exists(app) {
                guard writable(folder), writable(app) else { throw Failure.notWritable(app) }
                return app
            }
        }
        if writable(system) { return system.appendingPathComponent("Deskset.app", isDirectory: true) }
        let parent = exists(user) ? user : user.deletingLastPathComponent()
        guard writable(parent) else { throw Failure.notWritable(user.appendingPathComponent("Deskset.app")) }
        return user.appendingPathComponent("Deskset.app", isDirectory: true)
    }

    static func info(at app: URL) throws -> AppInfo {
        let fm = FileManager.default
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleID,
              plist["CFBundleExecutable"] as? String == "Deskset",
              let version = plist["CFBundleShortVersionString"] as? String,
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Deskset").path)
        else { throw Failure.invalidApp }
        guard ReleaseVersion(version) != nil else { throw Failure.invalidVersion }
        return AppInfo(version: version)
    }

    static func checkVersion(source: AppInfo, installed: AppInfo?) throws {
        guard let incoming = ReleaseVersion(source.version) else { throw Failure.invalidVersion }
        if let installed {
            guard let existing = ReleaseVersion(installed.version) else { throw Failure.invalidVersion }
            if incoming < existing { throw Failure.olderVersion(installed.version) }
        }
    }

    /// A complete, verified copy is staged on the destination volume before the existing application is touched.
    /// FileManager's replacement keeps a backup until success; failed replacements restore that backup.
    static func install(source: URL, destination: URL,
                        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
                        verify: (URL) throws -> Void = verifySignature,
                        replace: (URL, URL, String) throws -> Void = replaceApplication,
                        anotherCopyIsRunning: () -> Bool = isAnotherCopyRunning) throws {
        let fm = FileManager.default
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL
        else { throw Failure.invalidApp }
        let incoming = try info(at: source)
        let existing = fm.fileExists(atPath: destination.path) ? try info(at: destination) : nil
        try checkVersion(source: incoming, installed: existing)
        guard !anotherCopyIsRunning() else { throw Failure.running }
        let folder = destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".Deskset-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stagedApp = staging.appendingPathComponent("Deskset.app", isDirectory: true)
        try copy(source, stagedApp)
        guard try info(at: stagedApp) == incoming else { throw Failure.invalidApp }
        try verify(stagedApp)
        // Copying may take a while: check again before committing, including a newly installed newer version.
        guard !anotherCopyIsRunning() else { throw Failure.running }
        let current = fm.fileExists(atPath: destination.path) ? try info(at: destination) : nil
        try checkVersion(source: incoming, installed: current)
        guard current != nil else {
            try fm.moveItem(at: stagedApp, to: destination)
            return
        }
        let backupName = ".Deskset-previous-\(UUID().uuidString).app"
        let backup = folder.appendingPathComponent(backupName, isDirectory: true)
        do {
            try replace(destination, stagedApp, backupName)
        } catch {
            if fm.fileExists(atPath: backup.path) {
                do {
                    if fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: backup, options: [.usingNewMetadataOnly])
                    } else {
                        try fm.moveItem(at: backup, to: destination)
                    }
                } catch { throw Failure.recovery(backup) }
            }
            throw error
        }
        // A failed cleanup should not turn a successful installation into an error; the backup is harmless.
        if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
    }

    private static func replaceApplication(_ destination: URL, _ staged: URL, _ backup: String) throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged, backupItemName: backup,
                                                options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
    }

    static func verifySignature(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runSignatureVerification(process)
    }

    static func runSignatureVerification(_ process: Process, timeout: TimeInterval = 60) throws {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + max(0, timeout)) == .success else {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            throw Failure.signature
        }
        guard process.terminationStatus == 0 else { throw Failure.signature }
    }

    private static func isAnotherCopyRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
    }

    private static func begin(source: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let fm = FileManager.default
        let target: URL
        let incoming: AppInfo
        let installed: AppInfo?
        do {
            incoming = try info(at: source)
            target = try destination(system: URL(fileURLWithPath: "/Applications", isDirectory: true),
                                     user: fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
                                     exists: { fm.fileExists(atPath: $0.path) }, writable: { fm.isWritableFile(atPath: $0.path) })
            installed = fm.fileExists(atPath: target.path) ? try info(at: target) : nil
            try checkVersion(source: incoming, installed: installed)
        } catch {
            showFailure(error, source: source)
            quit()
            return
        }
        let alert = makeConfirmation(sourceVersion: incoming.version, installedVersion: installed?.version, destination: target)
        guard alert.runModal() == .alertFirstButtonReturn else { quit(); return }
        while isAnotherCopyRunning() {
            let running = makeRunningConflict(sourceVersion: incoming.version, destination: target)
            guard running.runModal() == .alertFirstButtonReturn else { quit(); return }
        }
        let progress = makeProgress(sourceVersion: incoming.version, destination: target)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try install(source: source, destination: target) }
            DispatchQueue.main.async {
                NSApp.stopModal()
                progress.window.orderOut(nil)
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error): showFailure(error, source: source); quit()
                    case .success: openInstalled(target)
                    }
                }
            }
        }
        progress.runModal()
    }

    /// Preserve only supported application commands when moving from the disk-image copy to the installed one.
    /// Development flags and Launch Services arguments do not become launch instructions for the installed app.
    static func relaunchArguments(_ arguments: [String]) -> [String] {
        guard case .command = LayoutCommand.parse(arguments) else { return [] }
        return Array(arguments.dropFirst())
    }

    private static func openInstalled(_ target: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = relaunchArguments(CommandLine.arguments)
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    let alert = makeLaunchFailure(error: error, destination: target)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                }
                quit()
            }
        }
    }

    private static func showFailure(_ error: Error, source: URL) {
        let alert = makeFailure(error: error)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([source]) }
    }

    static func makeConfirmation(sourceVersion: String, installedVersion: String?, destination: URL) -> AppMaintenancePanel {
        let alert = AppMaintenancePanel()
        alert.content.badgeText = AppUpdateAsset.processorName
        let parentPath = destination.deletingLastPathComponent().path
        if let installedVersion {
            alert.messageText = L("Replace Deskset %@?", installedVersion)
            alert.informativeText = L("Update the installed app in %@ and reopen Deskset.", parentPath)
            alert.content.configureTwoRowCard(
                leftLabel: L("Replacing"),
                oldVersion: installedVersion,
                mainValue: "→  \(sourceVersion)",
                rightMeta: parentPath,
                rightMetaAccent: false,
                bottomNote: L("Your skins, layouts, and settings will be kept.")
            )
            alert.addButton(withTitle: L("Replace and Open"))
        } else {
            alert.messageText = L("Install Deskset %@?", sourceVersion)
            alert.informativeText = L("Copy Deskset to your Applications folder and open it there.")
            alert.content.configureTwoRowCard(
                leftLabel: L("Destination"),
                oldVersion: nil,
                mainValue: destination.path,
                rightMeta: "v\(sourceVersion)",
                rightMetaAccent: false,
                bottomNote: L("Your skins, layouts, and settings will be kept.")
            )
            alert.addButton(withTitle: L("Install to Applications"))
        }
        alert.content.footnote.stringValue = L("Running from Disk Image")
        alert.addButton(withTitle: L("Cancel"))
        return alert
    }

    static func makeRunningConflict(sourceVersion: String = AppVersion.current, destination: URL) -> AppMaintenancePanel {
        let running = AppMaintenancePanel()
        running.content.badgeText = "v\(sourceVersion)"
        running.messageText = L("Quit the running copy of Deskset")
        running.informativeText = L("Another copy of Deskset is currently open.")
        running.content.configureTwoRowCard(
            leftLabel: L("Status"),
            oldVersion: nil,
            mainValue: L("Deskset is running"),
            rightMeta: destination.deletingLastPathComponent().path,
            rightMetaAccent: false,
            bottomNote: L("Choose Quit Deskset from its menu and save any edits, then click Retry.")
        )
        running.content.footnote.stringValue = L("Running from Disk Image")
        running.addButton(withTitle: L("Retry"))
        running.addButton(withTitle: L("Cancel"))
        return running
    }

    static func makeProgress(sourceVersion: String? = nil, destination: URL) -> AppMaintenancePanel {
        let progress = AppMaintenancePanel()
        progress.content.badgeText = ""
        progress.messageText = sourceVersion.map { L("Installing Deskset %@…", $0) } ?? L("Installing Deskset…")
        progress.informativeText = L("Deskset will open when installation finishes.")
        progress.content.configureProgressCard(
            status: L("Copying application and verifying signature…"),
            rightMeta: "",
            fraction: nil,
            bottomNote: L("Your skins and settings are kept in place.")
        )
        progress.content.footnote.stringValue = destination.path
        progress.content.showsDisabledCancelPlaceholder = true
        progress.allowsClosing = false
        return progress
    }

    static func makeFailure(error: Error) -> AppMaintenancePanel {
        let alert = AppMaintenancePanel()
        alert.alertStyle = .warning
        alert.content.badgeText = ""
        alert.messageText = L("Couldn’t install Deskset")
        alert.informativeText = L("Your skins, layouts, and settings are kept.")
        alert.content.configureErrorCard(
            message: error.localizedDescription,
            bottomNote: L("Reveal the installer in Finder to copy Deskset manually.")
        )
        alert.content.footnote.stringValue = L("Running from Disk Image")
        alert.addButton(withTitle: L("Show Installer in Finder"))
        alert.addButton(withTitle: L("Cancel"))
        return alert
    }

    static func makeLaunchFailure(error: Error, destination: URL) -> AppMaintenancePanel {
        let alert = AppMaintenancePanel()
        let parentPath = destination.deletingLastPathComponent().path
        alert.content.badgeText = L("Installed")
        alert.messageText = L("Deskset was installed")
        alert.informativeText = L("Open Deskset from %@.", parentPath)
        alert.content.configureErrorCard(
            message: error.localizedDescription,
            bottomNote: L("Use Show in Finder to open the installed application.")
        )
        alert.content.footnote.stringValue = parentPath
        alert.addButton(withTitle: L("Show in Finder"))
        alert.addButton(withTitle: L("Close"))
        return alert
    }

    private static func quit() { NSApp.terminate(nil) }
}
