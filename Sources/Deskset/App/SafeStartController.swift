import AppKit
import DesksetCore

/// The startup choice only; the caller backs up and replaces the layout after a confirmed offer.
/// Methods run on the main thread. Injected timer and prompt callbacks may arrive from another thread.
final class SafeStartController {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> SkinScheduledWork
    typealias Prompt = (@escaping (Bool) -> Void) -> (() -> Void)

    static let holdDuration: TimeInterval = 1
    static let samplingInterval: TimeInterval = 0.02

    private enum Phase { case idle, sampling, waiting, prompting, finished, cancelled }
    private let flags: () -> NSEvent.ModifierFlags
    private let clock: () -> TimeInterval
    private let schedule: Schedule
    private let prompt: Prompt
    private var phase = Phase.idle
    private var generation = 0
    private var recentCrashCount: Int?
    private var manualQualified: Bool?
    private var heldSince: TimeInterval = 0
    private var timer: SkinScheduledWork?
    private var cancelPrompt: (() -> Void)?
    private var completion: ((Bool) -> Void)?

    init(flags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { interval, fire in
             MainSkinExecutor.shared.timer(interval: interval, leeway: 0.005, repeats: true, fire)
         }, prompt: Prompt? = nil) {
        self.flags = flags
        self.clock = clock
        self.schedule = schedule
        self.prompt = prompt ?? Self.presentPrompt
    }

    deinit {
        timer?.cancel()
        if let cancelPrompt {
            if Thread.isMainThread { cancelPrompt() }
            else { DispatchQueue.main.async(execute: cancelPrompt) }
        }
    }

    /// A controller owns one startup attempt. False chooses normal startup; lifecycle cancellation calls neither path.
    func begin(recentCrashCount: Int, completion: @escaping (Bool) -> Void) {
        begin(loadCrashCount: { $0(recentCrashCount) }, completion: completion)
    }

    /// Modifier sampling starts while the watcher handshakes; neither startup path runs until both have answered.
    func begin(loadCrashCount: (@escaping (Int) -> Void) -> Void, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard phase == .idle else { return }
        generation += 1
        self.completion = completion
        let request = generation
        phase = .waiting
        manualQualified = false
        if Self.isManualChord(flags()) {
            let now = clock()
            if now.isFinite {
                heldSince = now
                manualQualified = nil
                phase = .sampling
                let timer = schedule(Self.samplingInterval) { [weak self] in self?.sample(request: request) }
                // Test schedulers can fire inline, including cancelling while scheduling.
                if generation == request, phase == .sampling { self.timer = timer }
                else { timer.cancel() }
            }
        }
        guard generation == request, phase == .sampling || phase == .waiting else { return }
        loadCrashCount { [weak self] count in self?.loadedCrashCount(count, request: request) }
    }

    /// Termination or an aborted startup must not continue either startup path when an old callback returns.
    func cancel() {
        precondition(Thread.isMainThread)
        guard phase != .cancelled else { return }
        generation += 1
        phase = .cancelled
        completion = nil
        timer?.cancel()
        timer = nil
        let close = cancelPrompt
        cancelPrompt = nil
        close?()
    }

    static func isManualChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains([.control, .shift])
    }

    private func sample(request: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.sample(request: request) }
            return
        }
        guard generation == request, phase == .sampling else { return }
        guard Self.isManualChord(flags()) else { return endManualHold(qualified: false) }
        let now = clock()
        guard now.isFinite else { return endManualHold(qualified: false) }
        if now < heldSince { heldSince = now }
        if now - heldSince >= Self.holdDuration { endManualHold(qualified: true) }
    }

    private func loadedCrashCount(_ count: Int, request: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.loadedCrashCount(count, request: request) }
            return
        }
        guard generation == request, phase == .sampling || phase == .waiting, recentCrashCount == nil else { return }
        recentCrashCount = count
        decideWhenReady()
    }

    private func endManualHold(qualified: Bool) {
        manualQualified = qualified
        timer?.cancel()
        timer = nil
        phase = .waiting
        decideWhenReady()
    }

    private func decideWhenReady() {
        guard let manualQualified, let recentCrashCount else { return }
        if manualQualified || recentCrashCount >= 2 { offer() }
        else { finish(false) }
    }

    private func offer() {
        guard phase != .prompting, phase != .finished, phase != .cancelled else { return }
        timer?.cancel()
        timer = nil
        phase = .prompting
        let request = generation
        let close = prompt { [weak self] accepted in self?.answered(accepted, request: request) }
        if generation == request, phase == .prompting { cancelPrompt = close }
        else { close() }
    }

    private func answered(_ accepted: Bool, request: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.answered(accepted, request: request) }
            return
        }
        guard generation == request, phase == .prompting else { return }
        finish(accepted)
    }

    private func finish(_ accepted: Bool) {
        guard phase != .finished, phase != .cancelled else { return }
        generation += 1
        phase = .finished
        timer?.cancel()
        timer = nil
        let close = cancelPrompt
        cancelPrompt = nil
        let completion = self.completion
        self.completion = nil
        let request = generation
        close?()
        guard generation == request, phase == .finished else { return }
        completion?(accepted)
    }

    struct PromptPresentation {
        let title: String
        let text: String
        let buttons: [String]
    }

    static var promptPresentation: PromptPresentation {
        PromptPresentation(title: L("Deskset Safe Start"),
            text: L("Deskset will start with its bundled default layout. Your current layout will be saved as @Backup.\n\nYour skin files will be kept."),
            buttons: [L("Safe Start"), L("Cancel")])
    }

    static func makeAlert() -> NSAlert {
        let presentation = promptPresentation
        let alert = NSAlert()
        alert.icon = AppIcon.image(size: 64)
        alert.messageText = presentation.title
        alert.informativeText = presentation.text
        alert.alertStyle = .warning
        for title in presentation.buttons { alert.addButton(withTitle: title) }
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert
    }

    private static func presentPrompt(_ completion: @escaping (Bool) -> Void) -> () -> Void {
        let alert = makeAlert()
        var cancelled = false
        // Return the cancellation handle before entering a modal run loop. Run-loop work, rather than a main-queue
        // block, also lets termination work on the main queue close the alert while it is modal.
        AppInstallation.scheduleAfterLaunch {
            guard !cancelled else { return }
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard !cancelled else { return }
            completion(response == .alertFirstButtonReturn)
        }
        return {
            cancelled = true
            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            alert.window.orderOut(nil)
        }
    }
}
