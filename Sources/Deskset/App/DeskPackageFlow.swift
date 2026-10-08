import AppKit
import DeskLanguage

/// Explicit local Desk folders and the installed members they provide. Archive/INI installation uses its own flow.
final class DeskPackageFlow: NSObject, NSMenuDelegate {
    enum Failure: Error, Equatable { case cancelled, noWidgets }
    private unowned let app: AppController
    private let fileQueue = DispatchQueue(label: "deskset.package.open", qos: .userInitiated)
    private var openTicket: Guarded<Bool>?
    private var installations: [ObjectIdentifier: DeskPackageInstallationRequest] = [:]
    private var activations: [UUID: DeskWidgetActivation.Ticket] = [:]
    private(set) var isTerminating = false
    var didRegisterInstallationForTesting: (() -> Void)?

    init(app: AppController) { self.app = app }

    var hasPendingInstallations: Bool { installations.values.contains { !$0.isFinished } }

    func openFolderMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: StudioText[.deskOpenPackageFolder], action: #selector(openFolder(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func openFolder(_ sender: Any?) {
        guard !isTerminating, !app.isTerminating else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = StudioText[.deskOpenPackageFolder]
        panel.message = StudioText[.deskPackageFolderMessage]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url else { return }
        open(root: root) { [weak self] result in
            if case .failure(let error) = result { self?.show(error) }
        }
    }

    /// Headless callers supply a member; interactive callers choose from the actual captured root widgets.
    func open(root: URL, member: DeskFileID? = nil,
              completion: @escaping (Result<CodeFileWindowController, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !isTerminating, !app.isTerminating else { completion(.failure(Failure.cancelled)); return }
        openTicket?.access { $0 = true }
        let ticket = Guarded(false)
        openTicket = ticket
        fileQueue.async { [weak self] in
            let inspection: Result<(DeskPackageCapture, [DeskFileID]), Error>
            do {
                let capture = try DeskPackageCapture.read(root: root, isCancelled: { ticket.current })
                let package = try PackageLoader.load(capture.source, limits: capture.limits)
                guard !package.widgetFiles.isEmpty else { throw Failure.noWidgets }
                inspection = .success((capture, package.widgetFiles))
            } catch { inspection = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !ticket.current, !self.isTerminating, !self.app.isTerminating else {
                    completion(.failure(Failure.cancelled)); return
                }
                switch inspection {
                case .failure(let error): completion(.failure(error))
                case .success(let (capture, members)):
                    guard let selected = member ?? self.choose(members: members), members.contains(selected) else {
                        completion(.failure(Failure.cancelled)); return
                    }
                    self.fileQueue.async { [weak self] in
                        let input = Result { try DeskCodePackageInput(capture: capture, member: selected) }
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !ticket.current, !self.isTerminating, !self.app.isTerminating else {
                                completion(.failure(Failure.cancelled)); return
                            }
                            do { completion(.success(try self.app.showCodePackage(input.get(), line: nil))) }
                            catch { completion(.failure(error)) }
                        }
                    }
                }
            }
        }
    }

    private func choose(members: [DeskFileID]) -> DeskFileID? {
        if members.count == 1 { return members[0] }
        guard app.presentsWindows else { return nil }
        let alert = NSAlert()
        alert.messageText = StudioText[.deskPackageChooseWidget]
        alert.informativeText = StudioText[.deskPackageChooseMessage]
        let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        selector.addItems(withTitles: members.map(\.path))
        selector.setAccessibilityLabel(StudioText[.deskPackageChooseWidget])
        alert.accessoryView = selector
        alert.addButton(withTitle: StudioText[.deskPackageOpen])
        alert.addButton(withTitle: StudioText[.addCancel])
        guard alert.runModal() == .alertFirstButtonReturn, members.indices.contains(selector.indexOfSelectedItem) else { return nil }
        return members[selector.indexOfSelectedItem]
    }

    @discardableResult
    func install(_ package: DeskCodePackageSnapshot, plan: DeskWidgetInstallation.PackagePlan,
                 queue: DispatchQueue? = nil, current: @escaping () -> Bool,
                 completion: @escaping (DeskPackageInstallationRequest.Outcome) -> Void) -> DeskPackageInstallationRequest {
        precondition(Thread.isMainThread)
        let request = DeskPackageInstallationRequest.start(snapshot: package.snapshot, capture: package.input.capture,
            plan: plan, root: app.widgetsDirectory, state: app.state, queue: queue,
            current: { [weak self] in
                guard let self, !self.isTerminating, !self.app.isTerminating else { return false }
                return current()
            }, didRegister: didRegisterInstallationForTesting, completion: completion)
        let key = ObjectIdentifier(request)
        installations[key] = request
        request.whenFinished { [weak self] in self?.installations.removeValue(forKey: key) }
        return request
    }

    /// Normal quit waits for each published directory's registration decision and worker cleanup acknowledgement.
    /// The UI thread never joins the file queue or scans package contents.
    func cancelAndDrain(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        isTerminating = true
        openTicket?.access { $0 = true }
        for ticket in activations.values { ticket.cancel() }
        activations.removeAll()
        let pending = installations.values.filter { !$0.isFinished }
        guard !pending.isEmpty else { completion(); return }
        var remaining = pending.count
        for request in pending {
            request.cancel()
            request.whenFinished {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    func installedMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: StudioText[.deskInstalledWidgets], action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        menu.autoenablesItems = false
        menu.delegate = self
        populate(menu)
        item.submenu = menu
        return item
    }

    func menuWillOpen(_ menu: NSMenu) { populate(menu) }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sources = app.state.data.deskWidgets.sources.values.sorted {
            $0.entry == $1.entry ? $0.id.uuidString < $1.id.uuidString : $0.entry < $1.entry
        }
        var titles: [String: Int] = [:]
        for source in sources {
            let instances = app.state.data.deskWidgets.instances.values.filter { $0.sourceID == source.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            for instance in instances {
                let name = (source.entry as NSString).lastPathComponent
                let count = (titles[name] ?? 0) + 1
                titles[name] = count
                let title = count == 1 ? name : "\(name) — \(count)"
                let item = NSMenuItem(title: title, action: #selector(toggleMember(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = instance.id
                item.state = activations[instance.id] != nil ? .mixed : (instance.active ? .on : .off)
                item.isEnabled = !isTerminating && !app.isTerminating
                menu.addItem(item)
            }
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: StudioText[.deskNoInstalledWidgets], action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    @objc private func toggleMember(_ sender: NSMenuItem) {
        guard !isTerminating, !app.isTerminating, let id = sender.representedObject as? UUID,
              let instance = app.state.deskInstance(id) else { return }
        if instance.active || app.deskWidgetWindows[id] != nil || activations[id] != nil {
            activations.removeValue(forKey: id)?.cancel()
            app.deactivateDeskWidget(instanceID: id)
        } else {
            // The async entry also preserves the existing standalone activation behavior.
            let ticket = app.activateDeskWidgetAsync(instanceID: id) { [weak self] result in
                self?.activations.removeValue(forKey: id)
                if case .failure(let error) = result { self?.show(error) }
            }
            activations[id] = ticket
        }
    }

    /// UI reasons only; worker errors and their I/O/identity guards remain unchanged.
    /// Nil means cancellation, including a discarded installation or app termination.
    static func message(for error: Error) -> String? {
        func at(_ key: StudioText.Key, _ paths: String...) -> String {
            ([StudioText[key]] + paths.filter { !$0.isEmpty }).joined(separator: "\n")
        }
        switch error {
        case let failure as Failure:
            switch failure {
            case .cancelled: return nil
            case .noWidgets: return StudioText[.deskPackageNoWidgets]
            }
        case let failure as DeskPackageCapture.Failure:
            switch failure {
            case .cancelled: return nil
            case .invalidRoot: return StudioText[.deskPackageInvalidFiles]
            case .invalidName(let path), .unsupported(let path): return at(.deskPackageInvalidFiles, path)
            case .unreadable(let path, _): return at(.deskPackageUnreadable, path)
            case .changed(let path): return at(.deskPackageChanged, path)
            case .ambiguous(let first, let second): return at(.deskPackageNameConflict, first, second)
            case .resourceLimit: return StudioText[.deskWidgetPreparationFailed]
            }
        case let failure as DeskPackageMemberIO.Failure:
            switch failure {
            case .invalidMember: return StudioText[.deskPackageInvalidFiles]
            case .changed: return StudioText[.deskPackageChanged]
            case .oversized: return StudioText[.deskWidgetPreparationFailed]
            case .unreadable: return StudioText[.deskPackageUnreadable]
            case .writeFailed: return StudioText[.deskPackageSaveFailed]
            }
        case let failure as DeskWidgetActivation.Failure:
            switch failure {
            case .cancelled: return nil
            case .invalidEntry, .invalidPackage: return StudioText[.deskPackageInvalidFiles]
            case .compileFailed: return StudioText[.deskPackageUnsupported]
            case .resources(let message): return message.isEmpty ? StudioText[.deskWidgetPreparationFailed] : message
            }
        case let failure as DeskWidgetInstallation.Failure:
            switch failure {
            case .disposed: return nil
            case .staleSnapshot, .sourceChanged: return StudioText[.deskPackageChanged]
            case .invalidSource, .invalidPackage: return StudioText[.deskPackageInvalidFiles]
            case .unsupported: return StudioText[.deskPackageUnsupported]
            case .resourceLimit: return StudioText[.deskWidgetPreparationFailed]
            case .collision: return StudioText[.deskPackageCollision]
            case .resources(let message): return message.isEmpty ? StudioText[.deskWidgetPreparationFailed] : message
            case .io: return StudioText[.deskPackageSaveFailed]
            }
        case let failure as AppController.DeskWidgetActivationFailure:
            switch failure {
            case .isTerminating: return nil
            case .sourceNotFound, .instanceNotFound, .instanceSourceMismatch, .entryEscapes, .invalidPackage:
                return StudioText[.deskPackageInvalidFiles]
            case .compileFailed: return StudioText[.deskPackageUnsupported]
            case .resourceLimit: return StudioText[.deskWidgetPreparationFailed]
            }
        case let failure as CodeFileWindowController.PlaceOnDesktopError:
            switch failure {
            case .cancelled: return nil
            case .notDeskFile: return StudioText[.deskWidgetInvalidFile]
            case .documentNotChecked: return StudioText[.deskPreviewChecking]
            case .saveFailed: return StudioText[.deskPackageSaveFailed]
            }
        case let failure as DeskCodeDocumentChecking.ReadFailure:
            return failure.errorDescription
        default:
            return StudioText[.deskPackageOperationFailed]
        }
    }

    private func show(_ error: Error) {
        guard !isTerminating, !app.isTerminating, let message = Self.message(for: error) else { return }
        if app.presentsWindows {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = StudioText[.deskOpenPackageFolder]
            alert.informativeText = message
            alert.runModal()
        } else { Log.write("Desk package: \(message)", level: .warning) }
    }
}
