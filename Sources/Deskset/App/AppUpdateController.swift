import Foundation

extension Notification.Name {
    static let desksetUpdatesChanged = Notification.Name("desksetUpdatesChanged")
}

/// App-level update checks. All methods and fetch completions run on the main thread; tests supply a clock and fetcher.
final class AppUpdateController {
    enum Status: Equatable {
        case idle, checking, upToDate, noRelease
        case available(AppRelease)
        case failed(String)
    }

    enum Notice: Equatable {
        case available(AppRelease), upToDate, noRelease, failed(String)
    }

    static let checkInterval: TimeInterval = 24 * 60 * 60
    let currentVersion: String
    private let state: AppState
    private let service: AppUpdateFetching
    private let now: () -> Date
    /// Returns whether the notice could be shown. A busy modal window can defer automatic notices.
    var onNotice: ((Notice, Bool) -> Bool)?
    var onChange: (() -> Void)?
    private(set) var status: Status = .idle
    private(set) var availableRelease: AppRelease?
    private var timer: Timer?
    private var started = false
    private var cancelRequest: (() -> Void)?
    private var generation = 0
    private var manualRequest = false

    init(state: AppState, service: AppUpdateFetching = GitHubAppUpdateService(),
         currentVersion: String = AppVersion.current, now: @escaping () -> Date = { Date() }) {
        self.state = state
        self.service = service
        self.currentVersion = currentVersion
        self.now = now
        // Keep a previously announced update visible across launches, even while the daily request is throttled.
        // The canonical latest page works with both `v1.2.3` and `1.2.3` release tags.
        if let text = state.updates.lastNotifiedVersion, let version = ReleaseVersion(text),
           let installed = ReleaseVersion(currentVersion), version > installed,
           version != state.updates.skippedVersion.flatMap(ReleaseVersion.init),
           let url = URL(string: "https://github.com/jokyme/Deskset/releases/latest") {
            let release = AppRelease(version: version, url: url)
            availableRelease = release
            status = .available(release)
        }
    }

    deinit { timer?.invalidate(); cancelRequest?() }

    var automaticallyChecks: Bool { state.updates.automaticallyChecks }
    var isChecking: Bool { status == .checking }
    var menuTitle: String { isChecking ? "Checking for Updates…" : "Check for Updates…" }

    var statusText: String {
        switch status {
        case .idle: return "Installed version: \(currentVersion)."
        case .checking: return "Checking for updates…"
        case .upToDate: return "Deskset \(currentVersion) is up to date."
        case .noRelease: return "No public release is available yet."
        case .available(let release): return "Deskset \(release.version.description) is available. You have \(currentVersion)."
        case .failed(let message): return "Couldn’t check for updates. \(message)"
        }
    }

    /// Only the interactive app calls this, after startup. Constructing settings or headless tests never starts a request.
    func start() {
        guard !started else { return }
        started = true
        configureTimer()
        changed()
        checkAutomaticallyIfDue()
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        cancelCheck()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        state.updateUpdates { $0.automaticallyChecks = enabled }
        if !enabled, isChecking, !manualRequest { cancelCheck() }
        configureTimer()
        changed()
        if enabled, started { checkAutomaticallyIfDue() }
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard started, automaticallyChecks else { return }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkAutomaticallyIfDue() }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkAutomaticallyIfDue() {
        guard automaticallyChecks, !isChecking else { return }
        if let last = state.updates.lastCheckAttempt {
            let elapsed = now().timeIntervalSince(last)
            // A clock correction must not suppress checks until a stored future date.
            guard elapsed < 0 || elapsed >= Self.checkInterval else { return }
        }
        check(manual: false)
    }

    func checkManually() { check(manual: true) }

    func showAvailableUpdate() {
        guard let release = availableRelease else { return }
        if onNotice?(.available(release), false) == true, !isSkipped(release) {
            state.updateUpdates { $0.lastNotifiedVersion = release.version.description }
        }
    }

    /// Skip the version offered in this alert, even if a different release becomes available while it is open.
    func skipUpdate(_ release: AppRelease) {
        state.updateUpdates {
            $0.skippedVersion = release.version.description
            if $0.lastNotifiedVersion.flatMap(ReleaseVersion.init) == release.version {
                $0.lastNotifiedVersion = nil
            }
        }
        if availableRelease?.version == release.version { availableRelease = nil }
        if case .available(let current) = status, current.version == release.version { status = .idle }
        changed()
    }

    private func isSkipped(_ release: AppRelease) -> Bool {
        state.updates.skippedVersion.flatMap(ReleaseVersion.init) == release.version
    }

    private func check(manual: Bool) {
        if isChecking {
            manualRequest = manualRequest || manual
            return
        }
        guard let installed = ReleaseVersion(currentVersion) else {
            status = .failed("The installed version could not be read.")
            changed()
            if manual { _ = onNotice?(.failed("The installed version could not be read."), false) }
            return
        }
        generation += 1
        let request = generation
        manualRequest = manual
        state.updateUpdates { $0.lastCheckAttempt = now() }
        status = .checking
        changed()
        let cancel = service.fetch { [weak self] result in
            guard let self, self.generation == request, self.isChecking else { return }
            self.cancelRequest = nil
            let manual = self.manualRequest
            self.manualRequest = false
            let notice: Notice
            switch result {
            case .success(let release):
                if let release, release.version > installed {
                    // A manual check may present a skipped release, but does not restore its persistent reminder.
                    self.availableRelease = self.isSkipped(release) ? nil : release
                    self.status = self.isSkipped(release) ? .idle : .available(release)
                    notice = .available(release)
                } else {
                    self.availableRelease = nil
                    self.state.updateUpdates { $0.lastNotifiedVersion = nil }
                    self.status = release == nil ? .noRelease : .upToDate
                    notice = release == nil ? .noRelease : .upToDate
                }
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
                notice = .failed(error.localizedDescription)
            }
            self.changed()
            if case .available(let release) = notice {
                let version = release.version.description
                if manual || !self.isSkipped(release) {
                    // Closing an offer only dismisses this check. The daily throttle controls later reminders.
                    // The callback can skip the release while its modal alert is open.
                    if self.onNotice?(notice, !manual) == true, !self.isSkipped(release) {
                        self.state.updateUpdates { $0.lastNotifiedVersion = version }
                    }
                }
            } else if manual {
                _ = self.onNotice?(notice, false)
            }
        }
        // A test fetcher may finish synchronously; don't retain an already-finished request's cancellation.
        if generation == request, isChecking { cancelRequest = cancel }
    }

    private func cancelCheck() {
        generation += 1
        cancelRequest?()
        cancelRequest = nil
        manualRequest = false
        if isChecking {
            status = availableRelease.map(Status.available) ?? .idle
            changed()
        }
    }

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: .desksetUpdatesChanged, object: self)
    }
}
