import AppKit
import DesksetCore

enum LayoutOperationError: LocalizedError {
    case busy, terminating, wallpaper(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "Wait for the current layout to finish loading."
        case .terminating: return "Deskset is closing."
        case .wallpaper(let message): return message
        }
    }
}

/// Serializes layout replacements around the existing skin lifecycle. Native settings metadata round-trips with
/// layouts; the app's editor, update and other macOS preferences remain independent.
final class LayoutController {
    private unowned let app: AppController
    private struct Request {
        let name: String
        let backup: LayoutDocument?
        let fromInstaller: Bool
        let afterAction: SkinRuntime?
        let completion: (Bool) -> Void
    }
    private enum Pending {
        case layout(Request)
        case application(SkinRuntime?, (AppController) -> Void)

        var fromInstaller: Bool {
            if case .layout(let request) = self { return request.fromInstaller }
            return false
        }
        var afterAction: SkinRuntime? {
            switch self {
            case .layout(let request): return request.afterAction
            case .application(let source, _): return source
            }
        }
    }
    private var queue: [Pending] = []
    private var busy = false
    private var retired: [SkinWindowController] = []
    private(set) var isClosingSkins = false
    private var closeActionDepth = 0
    var allowsLifecycleMutation: Bool { !isClosingSkins || closeActionDepth > 0 }
    var isLoading: Bool { busy || isClosingSkins || !queue.isEmpty }
    static let closeTimeout: TimeInterval = 10

    init(app: AppController) { self.app = app }

    func isRetired(_ controller: SkinWindowController) -> Bool { controller.retiredByLayout }

    func capture(options: LayoutSaveOptions) throws -> LayoutDocument {
        LayoutDocument(ini: LayoutStateCodec.capture(app.state.data, library: app.library, options: options),
                       wallpaper: options.includeWallpaper ? try app.layoutWallpaper.capture() : nil)
    }

    /// Capture settings for @Backup. Only explicitly saving with Include wallpaper requests a desktop picture.
    func captureBackup() -> LayoutDocument {
        return LayoutDocument(ini: LayoutStateCodec.capture(app.state.data, library: app.library,
                                                           options: LayoutSaveOptions()))
    }

    func save(named name: String, options: LayoutSaveOptions) throws {
        guard !app.isTerminating else { throw LayoutOperationError.terminating }
        guard !isLoading else { throw LayoutOperationError.busy }
        try app.layoutStore.save(capture(options: options), named: name)
        app.notifyChanged()
    }

    func load(named name: String, backup: LayoutDocument? = nil, fromInstaller: Bool = false,
              afterAction: SkinRuntime? = nil,
              completion: @escaping (Bool) -> Void) {
        guard !app.isTerminating else { completion(false); return }
        let request = Request(name: name, backup: backup, fromInstaller: fromInstaller,
                              afterAction: afterAction, completion: completion)
        // The installer's own load completes the installation already in progress. User requests wait until the
        // package's files are all in place; they cannot block that completion behind themselves.
        if fromInstaller { queue.insert(.layout(request), at: 0) } else { queue.append(.layout(request)) }
        app.notifyChanged()
        next()
    }

    func installationFinished() { next() }

    /// Explicit application commands outlive the skin that issued them, in their original order.
    func enqueueApplicationAction(afterAction: SkinRuntime? = nil, _ body: @escaping (AppController) -> Void) {
        guard !app.isTerminating else { return }
        queue.append(.application(afterAction, body))
        next()
    }

    func performingCloseAction(_ body: () -> Void) {
        closeActionDepth += 1
        defer { closeActionDepth -= 1 }
        body()
    }

    /// The installer waits for this before replacing files. Its own busy flag keeps application commands queued.
    func prepareInstallation(completion: @escaping (LayoutDocument?) -> Void) {
        guard !app.isTerminating else { completion(nil); return }
        closeDesktop { [weak self] completed in
            guard let self else { return }
            self.isClosingSkins = false
            completion(completed && !self.app.isTerminating ? self.captureBackup() : nil)
        }
    }

    private func next() {
        guard !busy, let first = queue.first, !app.installer.isInstalling || first.fromInstaller else { return }
        busy = true
        app.notifyChanged()
        let pending = queue.removeFirst()
        let deadline = DispatchTime.now() + Self.closeTimeout
        app.later { [weak self] app in
            guard let self else { return }
            self.waitForAction(pending.afterAction, deadline: deadline) {
                switch pending {
                case .layout(let request): self.begin(request, deadline: deadline)
                case .application(_, let body):
                    if !app.isTerminating { body(app) }
                    self.busy = false
                    app.notifyChanged()
                    self.next()
                }
            }
        }
    }

    private func waitForAction(_ runtime: SkinRuntime?, deadline: DispatchTime, completion: @escaping () -> Void) {
        guard let runtime, !runtime.didClose else { completion(); return }
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            completion()
        }
        runtime.whenCaughtUp { finish() }
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            guard !finished else { return }
            Log.write("Going on without waiting longer for the requesting skin action", level: .warning)
            finish()
        }
    }

    private func finish(_ request: Request, success: Bool) {
        busy = false
        isClosingSkins = false
        app.notifyChanged()
        request.completion(success)
        next()
    }

    private func fail(_ request: Request, error: Error) {
        Log.write("Could not load layout \(request.name): \(error.localizedDescription)", level: .error)
        if !app.isTerminating {
            app.alert("Couldn’t load layout “\(request.name)”", error.localizedDescription, style: .warning)
        }
        finish(request, success: false)
    }

    private func begin(_ request: Request, deadline: DispatchTime) {
        guard !app.isTerminating else { finish(request, success: false); return }
        let previous = request.backup ?? captureBackup()
        do {
            // Reject a missing target before any skin closes; read its final contents after close actions finish.
            _ = try app.layoutStore.iniURL(named: request.name)
        } catch { fail(request, error: error); return }

        closeDesktop(deadline: deadline) { [weak self] _ in
            guard let self else { return }
            guard !self.app.isTerminating else { self.finish(request, success: false); return }
            self.isClosingSkins = false
            do {
                let backupLayout = request.name.caseInsensitiveCompare("@Backup") == .orderedSame
                let settingsBeforeLoad = request.backup ?? self.captureBackup()
                if !backupLayout {
                    try self.app.layoutStore.save(settingsBeforeLoad, named: "@Backup")
                }
                let target = try self.app.layoutStore.read(named: request.name, includeWallpaper: !backupLayout)
                if !backupLayout, let wallpaper = target.wallpaper { try self.app.layoutWallpaper.apply(wallpaper) }
                let decoded = LayoutStateCodec.decode(target.ini, library: self.app.library)
                let previousSettings = LayoutStateCodec.decode(settingsBeforeLoad.ini, library: self.app.library)
                self.app.state.replaceLayout(backupLayout ? decoded : decoded.preservingSettings(from: previousSettings))
                self.app.sessionPositions.removeAll()
                self.activateSaved {
                    guard !self.app.isTerminating else { self.finish(request, success: false); return }
                    self.app.state.saveNow()
                    Log.write("Loaded layout \(request.name)")
                    self.finish(request, success: true)
                }
            } catch {
                // The wallpaper boundary restores each display itself. Restore the skin session on an IO failure.
                self.app.state.replaceLayout(LayoutStateCodec.decode(previous.ini, library: self.app.library))
                self.app.sessionPositions.removeAll()
                self.activateSaved { self.fail(request, error: error) }
            }
        }
    }

    /// Each close is a barrier: remaining configs are addressable until their own close begins, and a config
    /// created by a close action is also collected. Regular update clocks stay paused during replacement.
    private func closeDesktop(deadline: DispatchTime = .now() + LayoutController.closeTimeout,
                              completion: @escaping (Bool) -> Void) {
        app.lifecycleGeneration += 1
        isClosingSkins = true
        for controller in app.sortedControllers { controller.runtime.send(.pause) }
        closeNext(deadline: deadline, completion: completion)
    }

    private func secondsRemaining(until deadline: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline.uptimeNanoseconds > now ? Double(deadline.uptimeNanoseconds - now) / 1e9 : 0
    }

    private func closeNext(deadline: DispatchTime, completion: @escaping (Bool) -> Void) {
        guard !app.isTerminating else { completion(false); return }
        guard let controller = app.controllers.values.min(by: { $0.config.utf16.lexicographicallyPrecedes($1.config.utf16) })
        else { completion(true); return }
        guard secondsRemaining(until: deadline) > 0 else {
            for remaining in app.sortedControllers {
                remaining.retiredByLayout = true
                remaining.runtime.retireForLayout()
                _ = app.suspend(config: remaining.config)
                remaining.runtime.finishLayoutRetirement()
            }
            completion(false)
            return
        }
        controller.retiredByLayout = true
        controller.runtime.retireForLayout()
        retired.append(controller)
        _ = app.suspend(config: controller.config)
        app.whenClosed([controller], timeout: secondsRemaining(until: deadline)) { [weak self] in
            guard let self else { return }
            let closed = controller.runtime.didClose && self.secondsRemaining(until: deadline) > 0
            // Close notifications and host requests share the main mailbox. A later turn also lets config
            // operations requested by the close action settle before selecting the next instance.
            self.app.later { [weak self] _ in
                guard let self else { return }
                self.drainRemaining(deadline: deadline) { drained in
                    controller.runtime.finishLayoutRetirement()
                    self.retired.removeAll { $0 === controller }
                    self.closeNext(deadline: deadline) { rest in completion(closed && drained && rest) }
                }
            }
        }
    }

    private func drainRemaining(deadline: DispatchTime, completion: @escaping (Bool) -> Void) {
        let remaining = app.sortedControllers
        guard secondsRemaining(until: deadline) > 0 else { completion(false); return }
        let revision = app.skinDirectory.actionRevision
        let directoryGeneration = app.skinDirectory.directory.generation
        var count = remaining.count
        var finished = false
        func finish(_ completed: Bool) {
            guard !finished else { return }
            finished = true
            completion(completed)
        }
        func checkAfterTurn() {
            app.later { _ in
                guard !finished else { return }
                if self.secondsRemaining(until: deadline) <= 0 {
                    finish(false)
                } else if revision != self.app.skinDirectory.actionRevision
                    || directoryGeneration != self.app.skinDirectory.directory.generation {
                    finished = true
                    self.drainRemaining(deadline: deadline, completion: completion)
                } else {
                    finish(true)
                }
            }
        }
        // Even an empty registry can have a close action's activation waiting in the main mailbox.
        if remaining.isEmpty { checkAfterTurn() }
        for controller in remaining {
            controller.runtime.send(.pause)
            controller.runtime.whenCaughtUp { [weak self] in
                guard !finished, let self else { return }
                count -= 1
                if count == 0 { checkAfterTurn() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            guard !finished else { return }
            Log.write("Going on without waiting longer for closing skin actions", level: .warning)
            finish(false)
        }
    }

    private func activateSaved(completion: @escaping () -> Void) {
        let active = app.state.activeConfigs.filter { item in
            if item.state.file.isEmpty {
                Log.write("Layout config \(item.config) has no installed variant \(item.state.activeVariant ?? 0)",
                          level: .warning)
                return false
            }
            return true
        }
        app.activateInOrder(active.map { ($0.config, $0.state.file) }) { [weak self] in
            self?.app.restack()
            completion()
        }
    }
}

extension AppController {
    var isLoadingLayout: Bool { layouts.isLoading }

    func saveLayout(named name: String, options: LayoutSaveOptions) throws {
        try layouts.save(named: name, options: options)
    }

    func loadLayout(named name: String, completion: @escaping (Bool) -> Void = { _ in }) {
        layouts.load(named: name, completion: completion)
    }

    func deleteLayout(named name: String) throws {
        guard !isLoadingLayout else { throw LayoutOperationError.busy }
        try layoutStore.delete(named: name)
        notifyChanged()
    }

    func editLayout(named name: String) {
        do { CodeEditorRouter.open(file: try layoutStore.iniURL(named: name), app: self) }
        catch { alert("Couldn’t edit layout “\(name)”", error.localizedDescription, style: .warning) }
    }

    /// Config requests stay within their desktop. Genuine close actions finish inside its closing barrier.
    func laterLifecycle(from source: SkinWindowController, loading config: String? = nil, whileClosing: Bool = false,
                        _ body: @escaping (AppController) -> Void) {
        func permitted() -> Bool {
            !source.retiredByLayout || (whileClosing && source.runtime.acceptsLayoutCloseActions)
        }
        guard !isTerminating, permitted() else { return }
        let generation = lifecycleGeneration
        let run: (AppController) -> Void = { app in
            guard !app.isTerminating, app.lifecycleGeneration == generation, permitted() else { return }
            if whileClosing || app.layouts.isClosingSkins {
                app.layouts.performingCloseAction { body(app) }
            } else {
                body(app)
            }
        }
        if let config { later(loading: config, run) } else { later(run) }
    }

    func layoutsMenu() -> NSMenu {
        let menu = NSMenu()
        let names = (try? layoutStore.list()) ?? []
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(loadLayoutAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.isEnabled = !isLoadingLayout
            menu.addItem(item)
        }
        if names.isEmpty {
            menu.addItem(withTitle: "No saved layouts", action: nil, keyEquivalent: "").isEnabled = false
        }
        return menu
    }

    @objc private func loadLayoutAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        loadLayout(named: name)
    }
}
