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
        app.inspector?.window?.close()
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
    let sidebarItem: NSSplitViewItem
    let canvasItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
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

    init(app: AppController) {
        self.app = app
        canvasController = StudioCanvasViewController(standIns: !app.presentsWindows)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        canvasItem = NSSplitViewItem(viewController: canvasController)
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

        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        canvasItem.minimumThickness = 360
        inspectorItem.minimumThickness = Self.inspectorMinWidth
        inspectorItem.maximumThickness = Self.inspectorMaxWidth
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .init(260)
        splitController.splitViewItems = [sidebarItem, canvasItem, inspectorItem]
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
            DispatchQueue.main.async { self?.updateToolbar() }
        })
        toolbar.titleView.onClick = { [weak self] in self?.showRunningPopover() }
        preview = StudioPreviewController(windowController: self, canvas: canvasController,
                                          presentsWindows: app.presentsWindows)
        widgetPage = StudioWidgetPage(window: self)
        partPage = StudioPartPage(window: self)
        geometry = StudioGeometry(window: self)
        inspectorController.pageView.onEvent = { [weak self] event in self?.pageEvent(event) }
        inspectorController.onEscape = { [weak self] in self?.goUp() }
        wireCanvas()
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
            unbindSession()
            self.session = session
            session.client = self
            let link = DesktopLink(app: app, session: session)
            link.onChange = { [weak self] change in self?.desktopChanged(change) }
            self.link = link
            observeUndo(session.undoStack)
        }
        link?.link(c)
        widgetChanged(fit: true)
        preview.attach()
    }

    /// The window lets go of its widget's session (it closes, or shows another widget): the Studio's instance and the
    /// watching of the files end; the text in memory and the undo stack stay with the app. What typing in the window's
    /// fields left on the stack goes, and anything registered for the window itself.
    func unbindSession() {
        guard let session else { return }
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
        for o in undoObservers { NotificationCenter.default.removeObserver(o) }
        undoObservers = []
        canvasController.stopRedrawing()
        self.session = nil
        link = nil
    }

    /// The widget shown changed (another one, or loaded again): its name, the canvas, the toolbar.
    private func widgetChanged(fit: Bool = false) {
        window?.title = widgetName
        canvasController.reload(fit: fit)
        updateToolbar()
        preview?.refreshAll()
        widgetPage?.rebuild()
        partPage?.refresh()
        scheduleThumbnails()
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
        if let skin, let name = ManageModel.metadataValue(skin.metadata, "Name"), !name.isEmpty { return name }
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

    // MARK: Depth and panes

    /// Customize while the sidebar is closed, Build while it is open.
    var depth: StudioDepth { sidebarItem.isCollapsed ? .customize : .build }

    func setSidebarOpen(_ open: Bool) {
        guard sidebarItem.isCollapsed == open else { return }
        sidebarItem.isCollapsed = !open
        updateToolbar()
        widgetPage?.refresh()
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
        s.depth = depth
        s.name = widgetName
        s.sentence = copySentence
        let undo = session?.undoStack
        s.canUndo = undo?.canUndo ?? false
        s.canRedo = undo?.canRedo ?? false
        s.undoName = undo?.undoActionName ?? ""
        s.redoName = undo?.redoActionName ?? ""
        // Add shows as on while the sidebar is on its Add page (the sidebar's pages come later).
        s.addOn = false
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

    @objc func undoAction(_ sender: Any?) {
        session?.undoStack.undo()
        updateToolbar()
    }

    @objc func redoAction(_ sender: Any?) {
        session?.undoStack.redo()
        updateToolbar()
    }

    /// Add: the sidebar opens (Build), on its Add page; again: it closes.
    @objc func addAction(_ sender: Any?) {
        setSidebarOpen(sidebarItem.isCollapsed)
    }

    /// Code: the code next to the canvas (comes with the code pane).
    @objc func codeAction(_ sender: Any?) {}

    /// Done: an open color popover hands its pick over, whatever is still waiting is written, then the window closes.
    @objc func doneAction(_ sender: Any?) {
        widgetPage.colorPopover?.close()
        partPage.closePopover()
        geometry.commitNudge()
        flush()
        window?.close()
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
        case .applied(let t):
            refreshOthers(t)
            partPage.refresh()
            updateToolbar()
        case .reverted(let t, _):
            refreshOthers(t)
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

    /// A step that changed a file other widgets read too (the suite's look): they load again, whichever way it went.
    private func refreshOthers(_ t: Transaction) {
        guard let skin else { return }
        let shared = t.files.filter { !skin.isOwnFile($0) }
        if !shared.isEmpty { link?.refreshOthers(reading: shared) }
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
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session?.undoStack ?? ownUndoManager }

    /// Back in the window: the desktop picture and the other widgets may have changed meanwhile.
    func windowDidBecomeKey(_ notification: Notification) {
        guard session != nil else { return }
        preview.refreshBackdrop()
        preview.refreshNeighbours()
    }

    func windowWillClose(_ notification: Notification) {
        thumbnailTimer?.invalidate()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        geometry.commitNudge()
        widgetPage.colorPopover?.close()
        partPage.closePopover()
        runningPopover?.close()
        pendingDiskCheck?.invalidate()
        pendingDiskCheck = nil
        flush()
        unbindSession()
        Self.openWindows.removeAll { $0 === self }
    }
}

/// The Studio's window. Off screen (snapshots, self-tests) it draws its controls as the key window does — the chosen
/// segment in the accent color, not the grey of a window behind others.
final class StudioWindow: NSWindow {
    var drawsAsKey = false
    override var isKeyWindow: Bool { drawsAsKey || super.isKeyWindow }
    override var isMainWindow: Bool { drawsAsKey || super.isMainWindow }
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
        titleLabel.font = NSFont(descriptor: NSFont.systemFont(ofSize: 15, weight: .semibold).fontDescriptor
            .withDesign(.serif) ?? NSFont.systemFont(ofSize: 15).fontDescriptor, size: 15)
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
            case .madeByYou, .rainmeter: noteLabel.stringValue = StudioText[.runningRainmeter]
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
                // ⇧Return: one level up.
                guard event.keyCode == 36 || event.keyCode == 76,
                      event.modifierFlags.intersection([.shift, .command, .option, .control]) == [.shift] else { return false }
                self?.goUp()
                return true
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
        if names.count == 1 {
            partPage.show(part: names[0])
        } else {
            partPage.show(part: nil)
            partPage.reset()
            widgetPage.refresh()
        }
        canvasController.overlay.setShowsDistances(false)
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
    @objc func cancelOperation(_ sender: Any?) {
        goUp()
    }

    /// ⌥⌘E: Every Setting; ⌥⌘↩: Show in Code.
    func keyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
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
        return false
    }

    /// Show in Code: the code of what is selected (the code pane comes in a later step; until then, the widget's own
    /// editor as Settings choose it).
    @objc func showInCode(_ sender: Any?) {
        codeAction(sender)
    }

    /// The canvas's menu on a part: hide it.
    func contextMenu(x: Double, y: Double) -> NSMenu? {
        guard let skin, let m = canvasController.canvas.pickableMeter(atSkinX: x, y) else { return nil }
        let menu = NSMenu()
        let title = partPage.partTitle(m, skin: skin)
        menu.addItem(ClosureMenuItem(StudioText.format(.menuHide, title)) { [weak self] in self?.hide(part: m.name) })
        return menu
    }

    /// Hides a part (its own `Hidden=1`), one step, confirmed: it cannot be seen afterwards.
    func hide(part name: String) {
        guard let skin, let m = skin.meter(named: name) else { return }
        let title = partPage.partTitle(m, skin: skin)
        let ops = WriteScopes.ops(.element, meter: m.name, key: "Hidden", value: "1", in: skin)
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
