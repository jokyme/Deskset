import AppKit
import DesksetCore

/// The new Skin Studio window (behind `StudioSwitch`; the old `InspectorWindowController` stays the default). One
/// window, the widget as the main thing in it:
///
/// - an `NSSplitViewController`: the sidebar (256 pt, `sidebarWithViewController`; collapsed while the Studio
///   customizes, open while it builds), the canvas (the widget over its backdrop, reaching under the toolbar) and the
///   inspector (300–330 pt; `inspectorWithViewController` from macOS 14, a plain pane on 13);
/// - an `NSToolbar` (`StudioToolbar`): sidebar · the widget's name and copy sentence · Undo Redo · Add Code · Share ·
///   Done · inspector.
///
/// It edits the widget through its editing session exactly as the old Studio does: the session is the app's
/// (`AppController.editingSession(for:)`), this window its client, its undo stack the window's; the Studio's own
/// instance is what the canvas draws. Everything about the widget on the desktop goes through `DesktopLink`. Closing
/// the window lets go of the instance and keeps the undo stack (the app keeps it until it quits).
final class StudioWindowController: NSWindowController, NSWindowDelegate, EditingSessionClient {
    static let defaultSize = NSSize(width: 1400, height: 860)
    static let sidebarWidth: CGFloat = 256
    static let inspectorMinWidth: CGFloat = 300
    static let inspectorMaxWidth: CGFloat = 330

    /// The open Studio windows (one per app at a time; the app keeps no reference of its own).
    private static var openWindows: [StudioWindowController] = []

    /// The app's open Studio window, if any.
    static func window(for app: AppController) -> StudioWindowController? {
        openWindows.first { $0.app === app }
    }

    /// Opens the Studio on the widget `c` (moving the open window to it), in front. The old Studio closes: one Studio
    /// edits at a time, and a session has one window.
    static func show(for c: SkinController, app: AppController) {
        // The old Studio closes as closing it would (its typed code asked about; Cancel keeps it open, and this one
        // does not open).
        if let inspector = app.inspector {
            guard inspector.canTerminate() else { return }
            inspector.window?.close()
        }
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
    let sidebarController = StudioSidebarViewController()
    let canvasController: StudioCanvasViewController
    let inspectorController = StudioInspectorViewController()
    /// The code: a column between the canvas and the inspector, or in the inspector's place (`setCodeMode`).
    let codeController = StudioCodeViewController()
    let sidebarItem: NSSplitViewItem
    let canvasItem: NSSplitViewItem
    let codeItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    /// The code pane's mode, diagnostics and commits.
    let codeState = StudioCodeState()
    private(set) var toolbar: StudioToolbar!
    /// The preview bar, the zoom capsule, Interact, Actual Size and Show on Desktop.
    private(set) var preview: StudioPreviewController!
    /// The widget page (the inspector while nothing is selected).
    private(set) var widgetPage: StudioWidgetPage!
    /// The page of the part (or data item) selected, and Every Setting.
    private(set) var partPage: StudioPartPage!
    /// Moving and resizing parts on the canvas.
    private(set) var geometry: StudioGeometry!
    private var flagsMonitor: Any?
    /// The editing session of the widget shown (nil before it shows one, and once closed).
    private(set) var session: EditingSession?
    /// The widget on the desktop (nil with no session).
    private(set) var link: DesktopLink?
    private var observations: [NSKeyValueObservation] = []
    private var undoObservers: [NSObjectProtocol] = []
    private var pendingDiskCheck: Timer?
    private var runningPopover: NSPopover?
    /// The window's own undo stack until it shows a widget.
    private let ownUndoManager = UndoManager()
    /// The sidebar's filter, hint and timer, and the keyboard's route.
    let sidebarState = StudioSidebarState()
    /// The canvas's parts as VoiceOver sees them.
    private(set) var canvasAccess: StudioCanvasAccessibility!
    /// What VoiceOver says when the step being made is done (else the step's name).
    var pendingAnnouncement: String?
    /// Answers the question about typed code that can't be saved (self-tests); nil: an alert asks.
    var closeChoice: (() -> InspectorWindowController.CloseChoice)?

    init(app: AppController) {
        self.app = app
        canvasController = StudioCanvasViewController(standIns: !app.presentsWindows)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        canvasItem = NSSplitViewItem(viewController: canvasController)
        codeItem = NSSplitViewItem(viewController: codeController)
        if #available(macOS 14.0, *) {
            inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        } else {
            inspectorItem = NSSplitViewItem(viewController: inspectorController)
        }
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
        // Tab goes through the panes' controls in the order they are laid out (they are made in code).
        window.autorecalculatesKeyViewLoop = true

        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        canvasItem.minimumThickness = 360
        canvasItem.canCollapse = true
        codeItem.minimumThickness = 300
        codeItem.canCollapse = true
        codeItem.isCollapsed = true
        codeItem.holdingPriority = .init(255)
        inspectorItem.minimumThickness = Self.inspectorMinWidth
        inspectorItem.maximumThickness = Self.inspectorMaxWidth
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .init(260)
        splitController.splitViewItems = [sidebarItem, canvasItem, codeItem, inspectorItem]
        window.contentViewController = splitController
        canvasController.skinProvider = { [weak self] in self?.session?.studioSkin }

        toolbar = StudioToolbar(target: self)
        window.toolbar = toolbar.toolbar
        window.setContentSize(Self.defaultSize)
        window.minSize = NSSize(width: 900, height: 560)
        window.contentView?.layoutSubtreeIfNeeded()
        placeInspector()
        window.center()
        observations.append(sidebarItem.observe(\.isCollapsed) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateToolbar() }
        })
        observations.append(inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.inspectorVisibilityChanged()
                self?.updateToolbar()
            }
        })
        toolbar.titleView.onClick = { [weak self] in self?.showRunningPopover() }
        preview = StudioPreviewController(windowController: self, canvas: canvasController,
                                          presentsWindows: app.presentsWindows)
        widgetPage = StudioWidgetPage(window: self)
        partPage = StudioPartPage(window: self)
        geometry = StudioGeometry(window: self)
        inspectorController.pageView.onEvent = { [weak self] event in self?.pageEvent(event) }
        inspectorController.onEscape = { [weak self] in self?.escapeFromInspector() }
        canvasAccess = StudioCanvasAccessibility(window: self)
        wireCanvas()
        wireSidebar()
        wireCode()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        pendingDiskCheck?.invalidate()
        for o in undoObservers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: The widget

    /// The Studio's own instance of the widget (its session's), which the canvas draws.
    var skin: Skin? { session?.studioSkin }

    /// Shows `c`'s widget: its editing session (the app's) takes this window as its client, the desktop copy is
    /// linked, and the Studio's own instance loads when the session has none or runs another file.
    func attach(_ c: SkinController) {
        let session = app.editingSession(for: c.config)
        if self.session !== session {
            // What the widget shown so far still waits for is made for it, before it goes.
            commitPendingEdits()
            flushCode()
            unbindSession()
            self.session = session
            session.client = self
            // Before an undo or redo, what waits for its pause is made, so the undo takes it back.
            session.undoStack.commitPendingEdits = { [weak self] in self?.commitPendingEditsBeforeUndo() }
            session.undoStack.hasPendingEdits = { [weak self] in self?.hasPendingEdits ?? false }
            let link = DesktopLink(app: app, session: session)
            link.onChange = { [weak self] change in self?.desktopChanged(change) }
            self.link = link
            observeUndo(session.undoStack)
            codeAttached(session)
        }
        link?.link(c)
        noteDesktopProblems()
        turnOnRainmeterDetailsTheFirstTime()
        widgetChanged(fit: true)
        preview.attach()
        startLayersTimer()
        announce(StudioText.format(depth == .build ? .announceOpenBuild : .announceOpen, widgetName))
    }

    /// The window lets go of its widget's session (it closes, or shows another widget): the Studio's instance and the
    /// watching of the files end; the text in memory and the undo stack stay with the app. What typing in the window's
    /// fields left on the stack goes, and anything registered for the window itself.
    func unbindSession() {
        guard let session else { return }
        codeDetached(session)
        geometry.cancel()
        partPage.reset()
        canvasController.canvas.setSelection(nil)
        widgetPage.close()
        widgetPage.thumbnails.clear()
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
        session.undoStack.commitPendingEdits = nil
        session.undoStack.hasPendingEdits = nil
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
        widgetPage?.rebuild()
        // The copy sentence counts design changes the way the page's Revert does (with the facts just worked out).
        updateToolbar()
        partPage?.refresh()
        if sidebarController.isViewLoaded, canvasAccess != nil { refreshLayers() }
        canvasController.updateCompatCapsule()
        scheduleThumbnails()
        codeSessionChanged()
    }

    private var thumbnailTimer: Timer?

    /// The look thumbnails are drawn a moment after the widget changed (each is an instance of the widget), in a
    /// window on screen; off screen they are drawn when asked (`drawThumbnails`).
    private func scheduleThumbnails() {
        guard app.presentsWindows else { return }
        thumbnailTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in self?.drawThumbnails() }
        RunLoop.main.add(timer, forMode: .common)
        thumbnailTimer = timer
    }

    /// Draws the look thumbnails now and shows them.
    func drawThumbnails() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = nil
        guard let session, let look = widgetPage.facts?.look else { return }
        widgetPage.thumbnails.render(session: session, look: look, skinsDirectory: app.skinsDirectory)
        widgetPage.refresh()
    }

    /// The name the window shows: the widget's `[Metadata] Name`, else its folder.
    var widgetName: String {
        let config = session?.config ?? ""
        if let skin, let name = ManageModel.metadataValue(skin.metadata, "Name"), !name.isEmpty {
            return StudioBuiltInWords.name(name, root: skin.rootConfig)
        }
        return String(config.split(separator: "\\").last ?? Substring(config))
    }

    /// Values show in the file's own notation (`10R`, `(#A# + 5)`, `52,199,89`): in a Rainmeter skin, or with Rainmeter
    /// details on (§4.4); elsewhere as the Studio's words (a calculated position, `#34C759`).
    var showsFileNotation: Bool {
        if app.state.editor.showIniNames { return true }
        if case .rainmeter? = link?.provenance { return true }
        return false
    }

    /// The sentence under the name: which copy the Studio changes.
    var copySentence: String {
        guard let link else { return "" }
        guard link.isOnDesktop else { return StudioText[.copyNotLoaded] }
        switch link.provenance {
        case .builtIn: return widgetPage.revertLink() != nil ? StudioText[.copyEdited] : StudioText[.copyBuiltIn]
        case .madeByYou: return StudioText[.copyMadeByYou]
        case .rainmeter: return StudioText[.copyRainmeter]
        }
    }

    // MARK: Depth and panes

    /// Customize while the sidebar is closed, Build while it is open.
    var depth: StudioDepth { sidebarItem.isCollapsed ? .customize : .build }

    func setSidebarOpen(_ open: Bool) {
        guard sidebarItem.isCollapsed == open else { return }
        sidebarItem.isCollapsed = !open
        updateToolbar()
        widgetPage?.refresh()
        if canvasAccess != nil {
            placeHint()
            if open { refreshLayers() }
        }
    }

    /// The inspector's width when the window opens (the design's 318 pt, within 300–330).
    static let inspectorWidth: CGFloat = 318

    /// Gives the inspector its opening width.
    func placeInspector() {
        guard !inspectorItem.isCollapsed, let index = splitController.splitViewItems.firstIndex(of: inspectorItem),
              index > 0 else { return }
        let split = splitController.splitView
        split.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.width - Self.inspectorWidth - split.dividerThickness, ofDividerAt: index - 1)
    }

    func setInspectorShown(_ shown: Bool) {
        guard inspectorItem.isCollapsed == shown else { return }
        inspectorItem.isCollapsed = !shown
        updateToolbar()
    }

    // MARK: Toolbar

    var toolbarState: StudioToolbarState {
        var s = StudioToolbarState()
        // With the code open the Studio builds: Undo is an icon.
        s.depth = isCodeShown ? .build : depth
        s.name = widgetName
        s.sentence = copySentence
        let undo = session?.undoStack
        s.canUndo = undo?.canUndo ?? false
        s.canRedo = undo?.canRedo ?? false
        s.undoName = undo?.undoActionName ?? ""
        s.redoName = undo?.redoActionName ?? ""
        // Add shows as on while the sidebar is open on its Add page.
        s.addOn = !sidebarItem.isCollapsed && sidebarController.page == .add
        s.codeOn = isCodeShown
        s.primary = StudioText[.done]
        return s
    }

    func updateToolbar() {
        toolbar?.apply(toolbarState)
        if canvasAccess != nil { canvasController.updateCompatCapsule() }
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

    /// Add: the sidebar opens (Build), on its Add page; again: it closes.
    @objc func addAction(_ sender: Any?) {
        if !sidebarItem.isCollapsed, sidebarController.page == .add {
            setSidebarOpen(false)
        } else {
            showSidebarPage(.add)
        }
    }

    /// Code: the code next to the canvas; again: it goes.
    @objc func codeAction(_ sender: Any?) {
        setCodeMode(isCodeShown ? .hidden : .alongside)
    }

    /// Done: an open color popover hands its pick over, whatever is still waiting is written, then the window closes
    /// (after asking about typed code that can't be saved, as closing does).
    @objc func doneAction(_ sender: Any?) {
        guard let window, windowShouldClose(window) else { return }
        flush()
        announce(StudioText[.announceDone])
        window.close()
    }

    /// Edits still waiting for their pause — a color being picked, arrow-key nudges — made now, in this turn.
    func commitPendingEdits() {
        widgetPage.colorPopover?.commitNow()
        partPage.closePopover()
        geometry.commitNudge()
    }

    /// Before an undo or redo of the widget's stack: not while typing in a field or the code (⌘Z undoes the typing).
    func commitPendingEditsBeforeUndo() {
        guard !(window?.firstResponder is NSTextView) else { return }
        commitPendingEdits()
    }

    /// Whether an edit waits for its pause (Undo is there for it).
    var hasPendingEdits: Bool {
        geometry.hasPendingNudge || widgetPage.colorPopover?.picked != nil || partPage.colorPopover?.picked != nil
    }

    // MARK: The canvas's view (View menu items and keys)

    @objc func zoomInClicked() { preview.zoomIn() }
    @objc func zoomOutClicked() { preview.zoomOut() }
    /// ⌘0: Actual Size.
    @objc func actualSizeClicked() { preview.actualSize() }
    /// ⌘9: Zoom to Fit.
    @objc func fitClicked() { preview.zoomToFit() }
    /// ⇧⌘D: Show on Desktop (on and off).
    @objc func showOnDesktop(_ sender: Any?) { preview.desktopView.toggle() }
    /// ⌥⌘P: Interact.
    @objc func toggleInteract(_ sender: Any?) { preview.setInteracting(!preview.state.interacting) }

    /// Check marks and titles of the menu items the window answers.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let answer = validateMenusItem(item) ?? validateStudioMenuItem(item) { return answer }
        return responds(to: item.action)
    }

    /// The inspector button on macOS 13 (from 14 the split view controller's `toggleInspector:`).
    @objc func toggleInspectorPane(_ sender: Any?) {
        setInspectorShown(inspectorItem.isCollapsed)
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

    /// The popover's content (headless too: the snapshot composes it).
    var runningPopoverContent: StudioRunningViewController? {
        runningPopover?.contentViewController as? StudioRunningViewController
    }

    // MARK: The desktop and the disk

    private func desktopChanged(_ change: DesktopLink.Change) {
        switch change {
        case .reloaded(let own):
            // The session's own reload: the instance already shows it (nothing to follow but the sentence).
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
        case .reloaded:
            widgetChanged()
        case .patched:
            // The same instance took the step without loading again (the fast path): follow it as after a reload.
            // (Updating only the rows the patch touched, as the old Studio does, is left for later.)
            widgetChanged()
        case .applied(let t):
            refreshOthers(t)
            refreshDiagnostics()
            partPage.refresh()
            updateToolbar()
            refreshLayers()
            canvasController.updateCompatCapsule()
            announce(pendingAnnouncement ?? t.name)
            pendingAnnouncement = nil
        case .reverted(let t, let undo):
            refreshOthers(t)
            refreshDiagnostics()
            refreshLayers()
            canvasController.updateCompatCapsule()
            announce(StudioText.format(undo ? .announceUndo : .announceRedo, t.name))
            widgetPage.stepReverted()
            partPage.stepReverted()
            widgetPage.refresh()
            partPage.refresh()
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

    /// Live reload: a file of the widget changed on disk by something other than the session reloads the widget (the
    /// Studio's instance and the desktop copy), as the old Studio does — unless the widget wrote it itself
    /// (`!WriteKeyValue`), or live reload is off: then only the text in memory takes the change. Put off while a
    /// reload the session asked for is on its way (what the widget writes as it loads is its own).
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
    /// Changes, or Cancel. Everything else still waiting is written first: a color being picked, a nudge, a value typed
    /// in a field. Quitting runs this too (`canTerminate`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let editor = sender.firstResponder as? NSTextView, editor.isFieldEditor { sender.makeFirstResponder(nil) }
        commitPendingEdits()
        guard codeController.isViewLoaded else { return true }
        if codeView.commitNow(explicit: true) || !codeView.hasUncommittedChanges { return true }
        switch askAboutUncommittedCode() {
        case .save:
            return codeView.commitNow(explicit: true)
        case .discard:
            codeView.discardUncommittedChanges()
            return true
        case .cancel:
            return false
        }
    }

    /// Quitting the app (⌘Q, logging out): the same check as closing, the window staying open on Cancel.
    func canTerminate() -> Bool {
        guard let window else { return true }
        return windowShouldClose(window)
    }

    func askAboutUncommittedCode() -> InspectorWindowController.CloseChoice {
        if let closeChoice { return closeChoice() }
        // Without windows (self-tests, snapshots) nobody can be asked: the typing is kept.
        guard app.presentsWindows, let window else { return .cancel }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        let dirty = codeView.files.filter { codeView.isDirty($0) }.map(\.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = StudioText.format(.codeNotSavedTitle, dirty.isEmpty ? StudioText[.codeNotSavedTheCode]
                                                                             : StudioWords.list(dirty))
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
        thumbnailTimer?.invalidate()
        sidebarState.liveTimer?.invalidate()
        sidebarState.liveTimer = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        commitPendingEdits()
        runningPopover?.close()
        pendingDiskCheck?.invalidate()
        pendingDiskCheck = nil
        flush()
        unbindSession()
        // What the window listened to goes with it: a closed window never answers another app's notifications (a new
        // app state can take the address of this window's gone one).
        for o in sidebarState.observers + codeState.observers { NotificationCenter.default.removeObserver(o) }
        sidebarState.observers = []
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

// MARK: - Selecting parts

extension StudioWindowController {
    /// The canvas selects parts (the first click passes over parts that draw nothing), drags them, and says what
    /// they are called; ⇧Return and Esc go one level up; ⌥ held shows distances.
    func wireCanvas() {
        let canvas = canvasController.canvas
        canvas.onSelectionChange = { [weak self] names in self?.selectionChanged(names) }
        canvas.onBeginGesture = { [weak self] names, gesture in
            let resize: Bool = { if case .resize = gesture { return true } else { return false } }()
            self?.geometry.begin(names, resize: resize)
        }
        canvas.onGestureFrames = { [weak self] frames in self?.geometry.preview(frames) }
        canvas.onEndGesture = { [weak self] keep in self?.geometry.end(keep: keep) }
        canvas.onNudge = { [weak self] dx, dy in self?.geometry.nudge(dx: dx, dy: dy) }
        // Tab / ⇧Tab walk the parts in reading order; the selected one carries the focus ring.
        canvas.onTab = { [weak self] backward in self?.selectNextPart(backward: backward) ?? false }
        canvas.drawsPartFocusRing = true
        canvas.selectionTag = { [weak self] m in
            guard let self, let skin = self.skin else { return m.name }
            return self.partPage.partTitle(m, skin: skin)
        }
        canvas.layerName = { [weak self] name in
            guard let self, let skin = self.skin, let m = skin.meter(named: name) else { return name }
            return self.partPage.partTitle(m, skin: skin)
        }
        canvas.onContextMenu = { [weak self] x, y in self?.contextMenu(x: x, y: y) }
        if let container = canvasController.view as? StudioCanvasContainer {
            let previous = container.onKeyEquivalent
            container.onKeyEquivalent = { [weak self] event in
                if previous?(event) == true { return true }
                return self?.keyEquivalent(event) ?? false
            }
            container.onKeyDown = { [weak self] event in
                guard let self, event.keyCode == 36 || event.keyCode == 76 else { return false }
                let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
                // ⇧Return: one level up; Return: the keyboard to the part's page.
                if flags == [.shift] {
                    self.goUp()
                    return true
                }
                return flags.isEmpty && self.returnFromCanvas()
            }
        }
        if app.presentsWindows {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.optionChanged(event.modifierFlags.contains(.option) && event.window === self?.window)
                return event
            }
        }
    }

    /// ⌥ held (or let go): the selected part's distances on the canvas.
    func optionChanged(_ held: Bool) {
        canvasController.overlay.setShowsDistances(held && canvasController.canvas.selectedNames.count == 1)
    }

    /// One part selected: its page; nothing (or several): the widget page.
    func selectionChanged(_ names: [String]) {
        if canvasAccess != nil {
            sidebarController.layersView.outline(parts: [])
            sidebarController.layersView.select(parts: names)
        }
        if names.count == 1 {
            partPage.show(part: names[0])
        } else {
            partPage.show(part: nil)
            partPage.reset()
            widgetPage.refresh()
        }
        canvasController.overlay.setShowsDistances(false)
        codeSelectionChanged()
    }

    /// The parts one can see, in the order the widget is read: a row above first, then left to right (a row is the
    /// parts whose heights overlap).
    func partsInReadingOrder() -> [String] {
        guard let skin else { return [] }
        let parts = skin.meters.filter { !$0.hidden && !$0.isContainer && $0.frame.width > 0 && $0.frame.height > 0 }
            .sorted { $0.frame.y < $1.frame.y }
        var rows: [(bottom: Double, parts: [Meter])] = []
        for m in parts {
            if let last = rows.indices.last, m.frame.y < rows[last].bottom - 0.5 {
                rows[last].parts.append(m)
                rows[last].bottom = max(rows[last].bottom, m.frame.y + m.frame.height)
            } else {
                rows.append((m.frame.y + m.frame.height, [m]))
            }
        }
        return rows.flatMap { $0.parts.sorted { $0.frame.x < $1.frame.x } }.map(\.name)
    }

    /// Tab (⇧Tab) on the canvas: the next (previous) part in reading order, round to the first again; the part's page
    /// follows and VoiceOver says which part it is. False with no part to select.
    func selectNextPart(backward: Bool) -> Bool {
        let order = partsInReadingOrder()
        guard !order.isEmpty else { return false }
        let current = canvasController.canvas.selectedNames.last.flatMap { name in
            order.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let next: Int
        if let current {
            next = (current + (backward ? order.count - 1 : 1)) % order.count
        } else {
            next = backward ? order.count - 1 : 0
        }
        select(part: order[next])
        if let skin, let m = skin.meter(named: order[next]) { announce(partPage.partTitle(m, skin: skin)) }
        return true
    }

    /// Selects a part (a data page's "Used by", the self-tests).
    func select(part name: String?) {
        canvasController.canvas.setSelection(name, reveal: true)
        selectionChanged(name.map { [$0] } ?? [])
    }

    /// Esc (on the inspector) or ⇧Return: back one level — Every Setting to the part's page, a part to the widget.
    func goUp() {
        if partPage.everySetting, partPage.meter != nil { return partPage.toggleEverySetting() }
        if case .data? = partPage.focus {
            if let name = canvasController.canvas.selectedNames.last, skin?.meter(named: name) != nil {
                return partPage.show(part: name)
            }
        }
        canvasController.canvas.selectLevelUp()
        if canvasController.canvas.selectedNames.isEmpty, partPage.focus != nil { partPage.leave() }
    }

    /// The inspector's events go to the page it shows.
    func pageEvent(_ event: StudioPageEvent) {
        if partPage.focus != nil { partPage.handle(event) } else { widgetPage.handle(event) }
    }

    /// Esc with nothing in the window taking it: one level up.
    override func cancelOperation(_ sender: Any?) {
        goUp()
    }

    /// ⌥⌘E: Every Setting; ⌥⌘↩: Show in Code; ⌥⌘= and ⌥⌘−: text size; the sidebar's keys.
    func keyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if sidebarKeyEquivalent(event) { return true }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == [.command, .option] else { return false }
        if event.charactersIgnoringModifiers?.lowercased() == "e" || event.keyCode == 14 {
            partPage.toggleEverySetting()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            showInCode(nil)
            return true
        }
        // ⌥⌘= / ⌥⌘−: one step of text size (the Edit menu has them too).
        if [24, 69].contains(event.keyCode), canStepText {
            stepText(1)
            return true
        }
        if [27, 78].contains(event.keyCode), canStepText {
            stepText(-1)
            return true
        }
        return false
    }

    /// Show in Code (⌥⌘↩): the code opens next to the canvas at what is selected, and takes the keyboard.
    @objc func showInCode(_ sender: Any?) {
        if !isCodeShown { setCodeMode(.alongside) }
        revealSelectionInCode()
        window?.makeFirstResponder(codeView.textView)
    }

    /// The canvas's menu on a part: hide it.
    func contextMenu(x: Double, y: Double) -> NSMenu? {
        guard let skin, let m = canvasController.canvas.pickableMeter(atSkinX: x, y) else { return nil }
        let menu = NSMenu()
        let title = partPage.partTitle(m, skin: skin)
        menu.addItem(ClosureMenuItem(StudioText.format(.menuHide, title)) { [weak self] in self?.hide(part: m.name) })
        menu.addItem(.separator())
        let index = skin.meters.firstIndex { $0 === m } ?? 0
        menu.addItem(ClosureMenuItem(StudioText[.axBringForward], enabled: index + 1 < skin.meters.count) { [weak self] in
            self?.bringForward(m.name)
        })
        menu.addItem(ClosureMenuItem(StudioText[.axSendBackward], enabled: index > 0) { [weak self] in
            self?.sendBackward(m.name)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(StudioText[.axDelete]) { [weak self] in self?.delete(part: m.name) })
        return menu
    }

    /// Hides a part (its own `Hidden=1`), one step, confirmed: it cannot be seen afterwards.
    func hide(part name: String) {
        guard let skin, let m = skin.meter(named: name) else { return }
        let title = partPage.partTitle(m, skin: skin)
        let ops = WriteScopes.ops(.element, meter: m.name, key: "Hidden", value: "1", in: skin)
        guard !ops.isEmpty else { return partPage.sharedPartRefused(m) }
        let step = StudioText[.undoHide]
        guard partPage.apply(step, ops) else { return }
        canvasController.canvas.setSelection(nil)
        partPage.show(part: nil)
        partPage.reset()
        widgetPage.refresh()
        partPage.confirm(StudioText.format(.confirmHidden, title), step: step, item: "", section: "",
                         change: .invisible, fromCanvas: true)
        if let c = partPage.topConfirmation { widgetPage.showTop(c) }
    }
}
