import AppKit

/// A nonmodal download window: network callbacks keep running and the user can keep working until restart.
final class AppUpdateFlow: NSWindowController, NSWindowDelegate {
    enum Phase: Equatable { case idle, fetching, downloading, ready, preparing, failed }
    private(set) var phase: Phase = .idle
    private(set) var prepared: AppPreparedUpdate?
    private(set) var release: AppRelease?
    let panelContent = MaintenancePanelContent()
    var heading: NSTextField { panelContent.heading }
    var detail: NSTextField { panelContent.detail }
    var progress: NSProgressIndicator { panelContent.progress }
    var progressText: NSTextField { panelContent.progressText }
    let primary: NSButton = MaintenanceActionButton(title: L("Retry"), target: nil, action: nil)
    let secondary: NSButton = MaintenanceActionButton(title: L("Cancel"), target: nil, action: nil)
    let manualDownload: NSButton = MaintenanceActionButton(title: L("Download Manually…"), target: nil, action: nil)
    private let presentsWindows: Bool
    private let service: AppUpdateFetching
    private let downloader: AppUpdateDownloading
    private let install: (AppPreparedUpdate) -> Void
    private var cancelRequest: (() -> Void)?
    private var generation = 0

    init(presentsWindows: Bool = true, service: AppUpdateFetching = GitHubAppUpdateService(),
         downloader: AppUpdateDownloading = AppUpdateDownloader(), install: @escaping (AppPreparedUpdate) -> Void) {
        self.presentsWindows = presentsWindows
        self.service = service
        self.downloader = downloader
        self.install = install
        let window = MaintenancePanelContent.makeWindow(title: L("Update Deskset"))
        super.init(window: window)
        window.delegate = self
        window.contentView = panelContent
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(performPrimary)
        secondary.keyEquivalent = "\u{1b}"
        secondary.target = self
        secondary.action = #selector(dismiss)
        manualDownload.target = self
        manualDownload.action = #selector(openReleasePage)
        panelContent.setActions(leading: [manualDownload], trailing: [secondary, primary])
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { cancelRequest?(); removePrepared() }

    var isBusy: Bool { phase == .fetching || phase == .downloading || phase == .preparing }

    func start(_ offered: AppRelease, refreshMetadata: Bool = false) {
        if isBusy || (phase == .ready && release?.version == offered.version) { present(); return }
        cancelRequest?()
        cancelRequest = nil
        removePrepared()
        generation += 1
        let request = generation
        release = offered
        phase = .fetching
        render()
        present()
        if !refreshMetadata, !offered.assets.isEmpty {
            download(offered, request: request)
            return
        }
        // Persisted menu hints contain only a version and page URL. Refresh metadata before downloading.
        let cancel = service.fetch { [weak self] result in
            guard let self, self.generation == request, self.phase == .fetching else { return }
            self.cancelRequest = nil
            switch result {
            case .success(let current):
                guard let current, current.version >= offered.version else {
                    self.fail(L("This update is no longer available. Use Check for Updates to try again."))
                    return
                }
                self.release = current
                self.download(current, request: request)
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
        if generation == request, phase == .fetching { cancelRequest = cancel }
    }

    private func download(_ release: AppRelease, request: Int) {
        phase = .downloading
        render()
        let cancel = downloader.download(release, progress: { [weak self] fraction in
            guard let self, self.generation == request, self.phase == .downloading else { return }
            if let fraction {
                let pct = "\(Int(max(0, min(1, fraction)) * 100))%"
                self.panelContent.configureProgressCard(
                    status: L("Downloading update package…"),
                    rightMeta: pct,
                    fraction: fraction,
                    bottomNote: L("Deskset verifies the signature before asking you to restart.")
                )
            } else {
                self.panelContent.configureProgressCard(
                    status: L("Verifying signature and preparing update…"),
                    rightMeta: L("Verifying"),
                    fraction: nil,
                    bottomNote: L("Your skins, layouts, and settings will be kept.")
                )
            }
            self.fitWindow()
        }, completion: { [weak self] result in
            guard let self, self.generation == request, self.phase == .downloading else {
                if case .success(let obsolete) = result { try? FileManager.default.removeItem(at: obsolete.directory) }
                return
            }
            self.cancelRequest = nil
            switch result {
            case .success(let prepared):
                self.prepared = prepared
                self.phase = .ready
                self.render()
            case .failure(let error): self.fail(error.localizedDescription)
            }
        })
        if generation == request, phase == .downloading { cancelRequest = cancel }
    }

    @objc func performPrimary() {
        if phase == .ready, let prepared {
            phase = .preparing
            render()
            install(prepared)
        } else if phase == .failed, let release { start(release, refreshMetadata: true) }
    }

    @objc private func openReleasePage() {
        guard let release else { return }
        if !NSWorkspace.shared.open(release.url) {
            detail.stringValue = L("Couldn’t open the download page. Visit %@ in your browser.", release.url.absoluteString)
            panelContent.configureErrorCard(
                message: L("Couldn’t open the download page."),
                bottomNote: L("Visit %@ in your browser.", release.url.absoluteString)
            )
            fitWindow()
        }
    }

    /// A failed handoff or a cancelled editor save leaves the verified download available for another attempt.
    func installationCancelled(_ message: String? = nil) {
        guard prepared != nil else { return }
        phase = .ready
        render()
        if let message { detail.stringValue = message }
        fitWindow()
        present()
    }

    @objc func dismiss() {
        guard phase != .preparing else { return }
        if phase != .ready { cancelAndCleanUp() }
        // Close emits willClose so AppActivation releases the temporary Dock/menu-bar presence.
        // The window is retained and a Ready payload remains available when the user comes back.
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

    func cancelAndCleanUp() {
        generation += 1
        cancelRequest?()
        cancelRequest = nil
        removePrepared()
        phase = .idle
    }

    private func removePrepared() {
        if let prepared { try? FileManager.default.removeItem(at: prepared.directory) }
        prepared = nil
    }

    private func fail(_ message: String) {
        let version = release?.version.description ?? ""
        phase = .failed
        render()
        detail.stringValue = L("Your installed copy (%@) has not been changed.", AppVersion.current)
        let fallback = version.isEmpty
            ? L("Try again now, or download the update directly in your browser.")
            : L("Try again now, or download Deskset %@ directly in your browser.", version)
        panelContent.configureErrorCard(message: message, bottomNote: fallback)
        fitWindow()
    }

    private func render() {
        let version = release?.version.description ?? ""
        let hasPrimary = phase == .ready || phase == .failed
        primary.isHidden = !hasPrimary
        (primary as? MaintenanceActionButton)?.isPrimaryAction = hasPrimary
        window?.defaultButtonCell = hasPrimary ? (primary.cell as? NSButtonCell) : nil
        manualDownload.isHidden = phase != .failed
        secondary.isEnabled = phase != .preparing
        window?.standardWindowButton(.closeButton)?.isEnabled = phase != .preparing
        secondary.title = phase == .ready ? L("Later") : phase == .failed ? L("Close") : L("Cancel")
        panelContent.alertStyle = phase == .failed ? .warning : .informational

        switch phase {
        case .idle:
            heading.stringValue = L("Update Deskset")
            panelContent.badgeText = AppUpdateAsset.processorName
            detail.stringValue = L("A newer version is ready to download for this Mac.")
            panelContent.footnote.stringValue = L("Installed: %@", AppVersion.current)
        case .fetching:
            heading.stringValue = version.isEmpty ? L("Preparing update…") : L("Downloading Deskset %@…", version)
            panelContent.badgeText = AppUpdateAsset.processorName
            detail.stringValue = L("You can keep working while the update downloads.")
            panelContent.configureProgressCard(
                status: L("Getting the download for this Mac…"),
                rightMeta: "",
                fraction: nil,
                bottomNote: L("Deskset verifies the signature before asking you to restart.")
            )
            panelContent.footnote.stringValue = L("Installed: %@", AppVersion.current)
        case .downloading:
            heading.stringValue = L("Downloading Deskset %@…", version)
            panelContent.badgeText = AppUpdateAsset.processorName
            detail.stringValue = L("You can keep working while the update downloads.")
            panelContent.configureProgressCard(
                status: L("Downloading update package…"),
                rightMeta: "0%",
                fraction: 0,
                bottomNote: L("Deskset verifies the signature before asking you to restart.")
            )
            panelContent.footnote.stringValue = L("Installed: %@", AppVersion.current)
        case .ready:
            heading.stringValue = L("Deskset %@ is ready to install", version)
            panelContent.badgeText = L("Verified")
            detail.stringValue = L("Deskset will quit, install the update, and reopen automatically.")
            panelContent.configureTwoRowCard(
                leftLabel: L("Ready to install"),
                oldVersion: AppVersion.current,
                mainValue: "→  \(version)",
                rightMeta: AppUpdateAsset.processorName,
                rightMetaAccent: false,
                bottomNote: L("Your skins, layouts, and settings will be kept.")
            )
            panelContent.footnote.stringValue = L("You’ll be asked to save open edits.")
            primary.title = L("Install and Relaunch")
        case .preparing:
            heading.stringValue = L("Preparing to restart…")
            panelContent.badgeText = ""
            detail.stringValue = L("Save your edits when prompted, then Deskset will restart.")
            panelContent.configureProgressCard(
                status: L("Preparing the update helper and verifying the signature…"),
                rightMeta: "",
                fraction: nil,
                bottomNote: L("Your skins, layouts, and settings will be kept.")
            )
            panelContent.footnote.stringValue = L("Installed: %@", AppVersion.current)
        case .failed:
            heading.stringValue = L("Couldn’t update Deskset")
            panelContent.badgeText = ""
            detail.stringValue = L("Your installed copy (%@) has not been changed.", AppVersion.current)
            panelContent.footnote.stringValue = ""
            primary.title = L("Retry")
        }
        fitWindow()
    }

    private func fitWindow() {
        if let window { panelContent.fit(window: window) }
    }

    private func present() {
        guard presentsWindows else { return }
        AppActivation.track(window)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
