import AppKit
import DesksetCore

/// What VoiceOver says: captured in the self-tests, posted as an announcement in the app.
enum StudioAnnouncer {
    private(set) static var log: [String] = []
    static var captures = false

    static func clear() { log = [] }

    static func post(_ text: String, in window: NSWindow?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if captures { log.append(trimmed) }
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: trimmed,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// Which pane of the Studio has the keyboard (⌃Tab cycles between them).
enum StudioFocusArea: CaseIterable {
    case canvas
    case code
}

/// The Skin Studio window: the widget preview canvas alongside the INI code pane, with a unified toolbar
/// (widget title + copy sentence, Undo/Redo, Done).
final class StudioWindowController: NSWindowController, NSWindowDelegate, EditingSessionClient {
    static let defaultSize = NSSize(width: 1400, height: 860)

    /// The open Studio windows (one per app at a time; the app keeps no reference of its own).
    private static var openWindows: [StudioWindowController] = []

    /// The app's open Studio window, if any.
    static func window(for app: AppController) -> StudioWindowController? {
        openWindows.first { $0.app === app }
    }

    /// Opens the Studio on the widget `c` (moving the open window to it), in front.
    static func show(for c: SkinController, app: AppController) {
        let controller: StudioWindowController
        if let open = window(for: app) {
            controller = open
        } else {
            controller = StudioWindowController(app: app)
            openWindows.append(controller)
        }
        controller.attach(c)
        app.bringToFront(controller)
    }

    unowned let app: AppController
    let splitController = NSSplitViewController()
    let canvasController: StudioCanvasViewController
    let codeController = StudioCodeViewController()
    let canvasItem: NSSplitViewItem
    let codeItem: NSSplitViewItem
    /// The code pane's mode, diagnostics and commits.
    let codeState = StudioCodeState()
    private(set) var toolbar: StudioToolbar!
    /// The preview bar, the zoom capsule, Interact and Actual Size.
    private(set) var preview: StudioPreviewController!
    /// The editing session of the widget shown (nil before it shows one, and once closed).
    private(set) var session: EditingSession?
    /// The widget on the desktop (nil with no session).
    private(set) var link: DesktopLink?
    private var undoObservers: [NSObjectProtocol] = []
    private var pendingDiskCheck: Timer?
    private var runningPopover: NSPopover?
    /// The window's own undo stack until it shows a widget.
    private let ownUndoManager = UndoManager()
    /// What VoiceOver says when the step being made is done (else the step's name).
    var pendingAnnouncement: String?
    /// Answers the question about typed code that can't be saved (self-tests); nil: an alert asks.
    var closeChoice: (() -> CodeFileWindowController.CloseChoice)?
    private var isCheckingClose = false

    init(app: AppController) {
        self.app = app
        canvasController = StudioCanvasViewController(standIns: !app.presentsWindows)
        canvasItem = NSSplitViewItem(viewController: canvasController)
        codeItem = NSSplitViewItem(viewController: codeController)
        let window = StudioWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        // Off screen nothing is ever the key window: the controls draw as they do in the window in front.
        window.drawsAsKey = !app.presentsWindows
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.title = StudioText[.studioWindow]
        super.init(window: window)
        window.delegate = self
        window.onControlTab = { [weak self] backward in self?.cycleFocus(backward: backward) }
        window.onDone = { [weak self] in self?.doneAction(nil) }
        window.autorecalculatesKeyViewLoop = true

        codeItem.minimumThickness = 420
        codeItem.canCollapse = true
        canvasItem.minimumThickness = 360
        canvasItem.canCollapse = true
        canvasItem.holdingPriority = .init(255)
        splitController.splitViewItems = [codeItem, canvasItem]
        window.contentViewController = splitController
        canvasController.skinProvider = { [weak self] in self?.session?.studioSkin }

        toolbar = StudioToolbar(target: self)
        window.toolbar = toolbar.toolbar
        window.setContentSize(Self.defaultSize)
        window.minSize = NSSize(width: 900, height: 560)
        window.contentView?.layoutSubtreeIfNeeded()
        window.center()
        toolbar.titleView.onClick = { [weak self] in self?.showRunningPopover() }
        preview = StudioPreviewController(windowController: self, canvas: canvasController,
                                          presentsWindows: app.presentsWindows)
        wireCode()
        setCodeMode(.alongside)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        pendingDiskCheck?.invalidate()
        for o in undoObservers { NotificationCenter.default.removeObserver(o) }
    }

    func announce(_ text: String) {
        StudioAnnouncer.post(text, in: app.presentsWindows ? window : nil)
    }

    var focusArea: StudioFocusArea {
        guard let responder = window?.firstResponder as? NSView else { return .canvas }
        if responder.isDescendant(of: codeController.view) { return .code }
        return .canvas
    }

    func cycleFocus(backward: Bool) {
        guard let window else { return }
        if focusArea == .code && !canvasItem.isCollapsed {
            window.makeFirstResponder(canvasController.canvas)
        } else {
            window.makeFirstResponder(codeView.textView)
        }
    }

    // MARK: The widget

    /// The Studio's own instance of the widget (its session's), which the canvas draws.
    var skin: Skin? { session?.studioSkin }

    /// Shows `c`'s widget: its editing session (the app's) takes this window as its client, the desktop copy is
    /// linked, and the Studio's own instance loads when the session has none or runs another file.
    func attach(_ c: SkinController) {
        let session = app.editingSession(for: c.config)
        if self.session !== session {
            flushCode()
            unbindSession()
            self.session = session
            session.client = self
            let link = DesktopLink(app: app, session: session)
            link.onChange = { [weak self] change in self?.desktopChanged(change) }
            self.link = link
            observeUndo(session.undoStack)
            codeAttached(session)
        }
        link?.link(c)
        noteDesktopProblems()
        if !isCodeShown {
            setCodeMode(.alongside)
        }
        widgetChanged(fit: true)
        preview.attach()
        announce(StudioText.format(.announceOpen, widgetName))
    }

    /// The window lets go of its widget's session (it closes, or shows another widget): the Studio's instance and the
    /// watching of the files end; the text in memory and the undo stack stay with the app.
    func unbindSession() {
        guard let session else { return }
        codeDetached(session)
        preview.detach()
        if let fieldEditor = window?.fieldEditor(false, for: nil) {
            session.undoStack.removeAllActions(withTarget: fieldEditor)
            if let storage = (fieldEditor as? NSTextView)?.textStorage {
                session.undoStack.removeAllActions(withTarget: storage)
            }
        }
        session.undoStack.removeAllActions(withTarget: self)
        session.closeStudioSkin()
        if session.client === self { session.client = nil }
        for o in undoObservers { NotificationCenter.default.removeObserver(o) }
        undoObservers = []
        canvasController.stopRedrawing()
        self.session = nil
        link?.detach()
        link = nil
    }

    /// The widget shown changed (another one, or loaded again): its name, the canvas, the toolbar.
    private func widgetChanged(fit: Bool = false) {
        window?.title = widgetName
        canvasController.reload(fit: fit)
        updateToolbar()
        preview?.refreshAll()
        codeSessionChanged()
    }

    /// The name the window shows: the widget's `[Metadata] Name`, else its folder.
    var widgetName: String {
        let config = session?.config ?? ""
        if let skin, let name = ManageModel.metadataValue(skin.metadata, "Name"), !name.isEmpty {
            return name
        }
        return String(config.split(separator: "\\").last ?? Substring(config))
    }

    /// The sentence under the name: which copy the Studio changes.
    var copySentence: String {
        guard let link else { return "" }
        guard link.isOnDesktop else { return StudioText[.copyNotLoaded] }
        switch link.provenance {
        case .builtIn: return StudioText[.copyBuiltIn]
        case .madeByYou: return StudioText[.copyMadeByYou]
        case .rainmeter: return StudioText[.copyRainmeter]
        }
    }

    // MARK: Toolbar

    var toolbarState: StudioToolbarState {
        var s = StudioToolbarState()
        s.name = widgetName
        s.sentence = copySentence
        s.primary = StudioText[.done]
        return s
    }

    func updateToolbar() {
        toolbar?.apply(toolbarState)
    }

    private func observeUndo(_ manager: UndoManager) {
        for o in undoObservers { NotificationCenter.default.removeObserver(o) }
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange, .NSUndoManagerWillCloseUndoGroup]
        undoObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                self?.updateToolbar()
            }
        }
    }

    /// Undo: the typing in the code while it has the keyboard, else the widget's last step (typed code is committed
    /// first, so it is that step).
    @objc func undoAction(_ sender: Any?) {
        if focusArea == .code, let text = codeView.textView.undoManager, text.canUndo {
            text.undo()
            return
        }
        flushCode()
        session?.undoStack.undo()
        updateToolbar()
    }

    @objc func redoAction(_ sender: Any?) {
        if focusArea == .code, let text = codeView.textView.undoManager, text.canRedo {
            text.redo()
            return
        }
        session?.undoStack.redo()
        updateToolbar()
    }

    /// Done: whatever is still waiting is written, then the window closes (after asking about typed code that can't be
    /// saved, as closing does).
    @objc func doneAction(_ sender: Any?) {
        guard let window, windowShouldClose(window) else { return }
        flush()
        announce(StudioText[.announceDone])
        window.close()
    }

    // MARK: The canvas's view (View menu items and keys)

    @objc func zoomInClicked() { preview.zoomIn() }
    @objc func zoomOutClicked() { preview.zoomOut() }
    /// ⌘0: Actual Size.
    @objc func actualSizeClicked() { preview.actualSize() }
    /// ⌘9: Zoom to Fit.
    @objc func fitClicked() { preview.zoomToFit() }

    /// Check marks and titles of the menu items the window answers.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let answer = validateMenusItem(item) { return answer }
        return responds(to: item.action)
    }

    /// Writes what is not on disk yet (every step is written as it is made; this is the safety net).
    func flush() {
        _ = try? session?.diskSync.flush()
    }

    // MARK: The name's popover

    /// The popover under the widget's name: which file runs on the desktop, and Show in Finder.
    func showRunningPopover() {
        guard let link else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = StudioRunningViewController(link: link)
        runningPopover = popover
        guard app.presentsWindows, window?.isVisible == true else { return }
        popover.show(relativeTo: toolbar.titleView.bounds, of: toolbar.titleView, preferredEdge: .minY)
    }

    /// The popover's content.
    var runningPopoverContent: StudioRunningViewController? {
        runningPopover?.contentViewController as? StudioRunningViewController
    }

    // MARK: The desktop and the disk

    private func desktopChanged(_ change: DesktopLink.Change) {
        switch change {
        case .reloaded(let own):
            if own { updateToolbar() } else { widgetChanged() }
        case .unloaded:
            updateToolbar()
        }
        preview.refreshBackdrop()
        preview.refreshAll()
    }

    func sessionWillRevert(_ session: EditingSession) {}

    func session(_ session: EditingSession, didChange change: SessionChange) {
        guard session === self.session else { return }
        switch change {
        case .reloaded, .patched:
            widgetChanged()
        case .applied(let t):
            refreshOthers(t)
            refreshDiagnostics()
            updateToolbar()
            announce(pendingAnnouncement ?? t.name)
            pendingAnnouncement = nil
        case .reverted(let t, let undo):
            refreshOthers(t)
            refreshDiagnostics()
            announce(StudioText.format(undo ? .announceUndo : .announceRedo, t.name))
            updateToolbar()
        case .revertFailed:
            if app.presentsWindows { NSSound.beep() }
            updateToolbar()
        case .filesChangedOnDisk:
            checkFilesOnDisk()
        case .desktopWroteFiles:
            session.reloadStudioSkin()
        }
    }

    /// A step that changed a file other widgets read too (the suite's look): they load again, whichever way it went —
    /// unless the desktop is held (half-typed code never reaches the desktop, theirs neither): then once it is not.
    private func refreshOthers(_ t: Transaction) {
        guard let skin else { return }
        let shared = t.files.filter { !skin.isOwnFile($0) }
        for f in shared where !codeState.othersWaiting.contains(where: { SourceFileID($0) == SourceFileID(f) }) {
            codeState.othersWaiting.append(f)
        }
        releaseOthers()
    }

    /// The other widgets waiting for files written while the desktop was held load again, once it is not.
    func releaseOthers() {
        guard session?.isHoldingDesktop != true, !codeState.othersWaiting.isEmpty else { return }
        let files = codeState.othersWaiting
        codeState.othersWaiting = []
        link?.refreshOthers(reading: files)
    }

    /// Live reload: a file of the widget changed on disk by something other than the session reloads the widget.
    func checkFilesOnDisk() {
        guard let session, let link, link.isOnDesktop else { return }
        pendingDiskCheck?.invalidate()
        pendingDiskCheck = nil
        guard !session.isAwaitingOwnReload else {
            let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in self?.checkFilesOnDisk() }
            RunLoop.main.add(timer, forMode: .common)
            pendingDiskCheck = timer
            return
        }
        let changed = session.filesChangedOnDisk()
        let touched = session.filesTouchedOnDisk()
        guard !changed.isEmpty || !touched.isEmpty else { return }
        let wroteThemItself = link.takeOwnWrites()
        session.takeChangesFromDisk()
        if wroteThemItself || !app.state.editor.liveReload {
            session.diskSync.restamp()
            return canvasController.reload()
        }
        session.reloadStudioSkin()
        session.scheduleDesktopRefresh()
        releaseOthers()
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session?.undoStack ?? ownUndoManager }

    /// Back in the window: the desktop picture and the other widgets may have changed meanwhile.
    func windowDidBecomeKey(_ notification: Notification) {
        StudioMenus.install(for: self)
        guard session != nil else { return }
        preview.refreshBackdrop()
        preview.refreshNeighbours()
    }

    func windowDidResignKey(_ notification: Notification) {
        StudioMenus.restore(for: self)
    }

    func windowDidResize(_ notification: Notification) {
        codeWindowResized()
    }

    /// Closing (⌘W, the close button, Done) with typed code that can't be saved asks first: Save (try again), Discard
    /// Changes, or Cancel. Quitting runs this too (`canTerminate`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCheckingClose else { return false }
        guard !codeController.isViewLoaded || !codeView.hasCommitInProgress else { return false }
        isCheckingClose = true
        defer { isCheckingClose = false }
        if let editor = sender.firstResponder as? NSTextView, editor.isFieldEditor { sender.makeFirstResponder(nil) }
        guard codeController.isViewLoaded else { return true }
        _ = codeView.commitNow(explicit: true)
        if !codeView.hasUncommittedChanges && !codeView.hasCommitInProgress { return true }
        switch askAboutUncommittedCode() {
        case .save:
            _ = codeView.commitNow(explicit: true)
            return !codeView.hasUncommittedChanges && !codeView.hasCommitInProgress
        case .discard:
            codeView.discardUncommittedChanges()
            return !codeView.hasUncommittedChanges && !codeView.hasCommitInProgress
        case .cancel:
            return false
        }
    }

    /// Quitting the app (⌘Q, logging out): the same check as closing, the window staying open on Cancel.
    func canTerminate() -> Bool {
        guard let window else { return true }
        return windowShouldClose(window)
    }

    func askAboutUncommittedCode() -> CodeFileWindowController.CloseChoice {
        if let closeChoice { return closeChoice() }
        // Without windows (self-tests, snapshots) nobody can be asked: the typing is kept.
        guard app.presentsWindows, let window else { return .cancel }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        let dirty = codeView.files.filter { codeView.isDirty($0) }.map(\.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = StudioText.format(.codeNotSavedTitle, dirty.isEmpty ? StudioText[.codeNotSavedTheCode]
                                                                             : dirty.joined(separator: ", "))
        alert.informativeText = StudioText[.codeNotSavedInfo]
        alert.addButton(withTitle: StudioText[.codeNotSavedSave])
        alert.addButton(withTitle: StudioText[.codeNotSavedCancel])
        alert.addButton(withTitle: StudioText[.codeNotSavedDiscard])
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func windowWillClose(_ notification: Notification) {
        StudioMenus.restore(for: self)
        codeState.logWindow?.close()
        if codeController.isViewLoaded { codeView.commitNow(explicit: true) }
        runningPopover?.close()
        pendingDiskCheck?.invalidate()
        pendingDiskCheck = nil
        flush()
        unbindSession()
        for o in codeState.observers { NotificationCenter.default.removeObserver(o) }
        codeState.observers = []
        Self.openWindows.removeAll { $0 === self }
    }
}

/// The Studio's window. Off screen (snapshots, self-tests) it draws its controls as the key window does — the chosen
/// segment in the accent color, not the grey of a window behind others.
final class StudioWindow: NSWindow {
    var drawsAsKey = false
    /// ⌃Tab and ⌃⇧Tab: the keyboard's route between the panes (before any view takes the key).
    var onControlTab: ((Bool) -> Void)?
    /// ⌘↩: Done, whichever pane has the keyboard (the Widget menu has it too, while the menu bar is the Studio's).
    var onDone: (() -> Void)?
    override var isKeyWindow: Bool { drawsAsKey || super.isKeyWindow }
    override var isMainWindow: Bool { drawsAsKey || super.isMainWindow }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.control, .command, .option, .shift]) == [.command], let onDone {
            onDone()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48,
           event.modifierFlags.intersection([.control, .command, .option]) == [.control], let onControlTab {
            onControlTab(event.modifierFlags.contains(.shift))
            return
        }
        super.sendEvent(event)
    }
}

/// The popover under the widget's name: which file runs on the desktop, a sentence on what that means, and Show in
/// Finder.
final class StudioRunningViewController: NSViewController {
    let link: DesktopLink
    let titleLabel = NSTextField(labelWithString: StudioText[.runningTitle])
    let pathLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let finderButton = NSButton(title: StudioText[.showInFinder], target: nil, action: nil)

    init(link: DesktopLink) {
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        titleLabel.font = StudioPageStyle.titleFont(15)
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        noteLabel.font = .systemFont(ofSize: 11.5)
        noteLabel.textColor = .secondaryLabelColor
        finderButton.bezelStyle = .rounded
        finderButton.target = self
        finderButton.action = #selector(showInFinder)
        if link.isOnDesktop, let path = link.displayPath {
            pathLabel.stringValue = path
            switch link.provenance {
            case .builtIn: noteLabel.stringValue = StudioText[.runningBuiltIn]
            case .madeByYou: noteLabel.stringValue = StudioText[.runningMadeByYou]
            case .rainmeter: noteLabel.stringValue = StudioText[.runningRainmeter]
            }
        } else {
            pathLabel.stringValue = link.displayPath ?? ""
            noteLabel.stringValue = StudioText[.runningNothing]
        }
        finderButton.isEnabled = link.fileURL != nil
        let stack = NSStackView(views: [titleLabel, pathLabel, noteLabel, finderButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: noteLabel)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 320),
            noteLabel.widthAnchor.constraint(equalToConstant: 288),
        ])
        view = v
    }

    @objc func showInFinder() {
        link.showInFinder()
    }
}
