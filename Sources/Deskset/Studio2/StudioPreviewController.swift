import AppKit
import DesksetCore

/// The Studio window's preview: what the preview bar, the zoom capsule and the capsules over the canvas show and do —
/// the backdrop (with the desktop picture read safely), the other widgets around this one, the Mac's look and the glass
/// the canvas shows, sample data and a frozen time in the Studio's instance, Interact, Actual Size and Show on Desktop.
/// None of it changes the widget: the desktop copy keeps its live data, and nothing is written.
final class StudioPreviewController {
    private weak var windowController: StudioWindowController?
    let canvasController: StudioCanvasViewController
    let preferences: StudioPreferences
    let wallpapers = WallpaperSource()
    let menus = StudioPreviewMenus()
    let desktopView = StudioDesktopView()
    /// The sample data the Studio's instance takes (the session holds it while the window shows the widget).
    let sample = MeasureValueOverride()
    /// Whether windows go on screen (not headless).
    let presentsWindows: Bool
    private(set) var state = StudioPreviewState()
    private(set) var fidelity = WallpaperFidelity.exact
    /// The canvas is at 100 % because Actual Size put it there (the caption says where it is).
    private(set) var isActualSize = false
    private(set) var previewPopover: NSPopover?
    private(set) var previewPopoverContent: StudioPreviewPopoverController?
    private var timePopover: NSPopover?
    /// What Interact held back last, while its capsule shows.
    private(set) var heldAction: StudioHeldAction?
    private var heldActionTimer: Timer?
    private var neighbourTimer: Timer?
    /// The Mac's own look (followed by "Follow Mac"; the self-tests set it).
    var macIsDark: () -> Bool = {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    var reduceTransparency: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    init(windowController: StudioWindowController, canvas: StudioCanvasViewController, presentsWindows: Bool) {
        self.windowController = windowController
        canvasController = canvas
        self.presentsWindows = presentsWindows
        preferences = StudioPreferences(defaults: presentsWindows ? .standard : nil)
        state.backdrop = preferences.backdrop
        if state.backdrop == .solid && !reduceTransparency() { state.backdrop = .desktop }
        canvas.backdropView.usesStandInDesktop = !presentsWindows
        desktopView.presentsWindows = presentsWindows
        desktopView.onChange = { [weak self] in self?.refreshBars() }
        wire()
    }

    deinit {
        heldActionTimer?.invalidate()
        neighbourTimer?.invalidate()
    }

    private var session: EditingSession? { windowController?.session }
    private var link: DesktopLink? { windowController?.link }

    // MARK: Wiring

    private func wire() {
        let canvas = canvasController
        let bar = canvas.previewBar
        bar.appearanceItem.action = { [weak self] in self?.showPreviewPopover() }
        bar.backdropItem.action = { [weak self] in self?.showBackdropMenu() }
        bar.dataItem.action = { [weak self] in self?.showDataMenu() }
        bar.interactItem.action = { [weak self] in self?.setInteracting(!(self?.state.interacting ?? false)) }
        bar.backToLiveItem.action = { [weak self] in self?.backToLive() }
        let zoom = canvas.zoomCapsule
        zoom.zoomOutItem.action = { [weak self] in self?.zoomOut() }
        zoom.zoomInItem.action = { [weak self] in self?.zoomIn() }
        zoom.percentItem.action = { [weak self] in self?.zoomToFit() }
        zoom.actualSizeItem.action = { [weak self] in self?.actualSize() }
        zoom.desktopItem.action = { [weak self] in self?.desktopView.toggle() }
        canvas.caption = { [weak self] zoom in self?.caption(zoom: zoom) ?? "" }
        canvas.glassRegions = { [weak self] regions, dark in self?.state.previewed(regions, dark: dark) ?? regions }
        canvas.widgetFrame = { [weak self] in self?.link?.desktopFrame }
        canvas.onZoomChange = { [weak self] in self?.zoomChanged() }
        canvas.interactionView.onEscape = { [weak self] in self?.setInteracting(false) }
        menus.onBackdrop = { [weak self] kind in self?.setBackdrop(kind) }
        menus.onNeighbours = { [weak self] on in self?.setShowsNeighbours(on) }
        menus.onData = { [weak self] data in self?.setData(data) }
        menus.onTime = { [weak self] time in self?.setTime(time) }
        menus.onPickTime = { [weak self] in self?.showTimePicker() }
        menus.onBackToLive = { [weak self] in self?.backToLive() }
        desktopView.widgetWindow = { [weak self] in self?.link?.desktopWindow }
        if let container = canvas.view as? StudioCanvasContainer {
            container.onKeyEquivalent = { [weak self] event in self?.keyEquivalent(event) ?? false }
        }
    }

    /// The window shows a widget: its session takes the sample data, its instance's held-back actions come here.
    func attach() {
        guard let session else { return }
        session.measureValues = sample
        session.host.policy.onRecord = { [weak self] recorded in self?.held(recorded) }
        desktopView.studioWindow = windowController?.window
        applyAppearance(reload: false)
        refreshBackdrop()
        refreshAll()
    }

    /// The window lets go of the widget: the preview ends (the next widget starts live).
    func detach() {
        desktopView.back(reactivate: false)
        setInteracting(false)
        previewPopover?.close()
        timePopover?.close()
        neighbourTimer?.invalidate()
        neighbourTimer = nil
        session?.host.policy.onRecord = nil
        session?.host.appearance = nil
        session?.host.takesPointer = false
        session?.measureValues = nil
        session?.studioClock = nil
        state.data = .live
        state.time = .live
        state.interacting = false
        state.showsNeighbours = nil
        state.apply(to: sample)
    }

    // MARK: State

    /// Applies what changed from `old` to the canvas and the Studio's instance.
    private func stateChanged(from old: StudioPreviewState) {
        if old.time != state.time, let session {
            // Frozen time is the instance's own clock (its wall clock stands still; its timers go on): every reader of
            // the time — clocks, the sun, the weather's hours, scripts — sees it. The instance loads again to take it.
            switch state.time {
            case .live: session.studioClock = nil
            case .frozen(let date):
                var clock = SkinClock.live
                clock.now = { date }
                session.studioClock = clock
            }
            state.apply(to: sample)
            session.reloadStudioSkin()
        }
        if old.data != state.data || old.time != state.time {
            state.apply(to: sample)
            if let skin = session?.studioSkin {
                skin.update()
                canvasController.canvas.needsDisplay = true
            }
        }
        if old.appearance != state.appearance { applyAppearance(reload: true) }
        if old.backdrop != state.backdrop {
            preferences.backdrop = state.backdrop
            refreshBackdrop()
        }
        if old.glass != state.glass || old.backdrop != state.backdrop { canvasController.updateGlass() }
        refreshAll()
    }

    private func change(_ body: (inout StudioPreviewState) -> Void) {
        let old = state
        body(&state)
        guard state != old else { return }
        stateChanged(from: old)
    }

    func setBackdrop(_ kind: StudioBackdropKind) { change { $0.backdrop = kind } }
    func setShowsNeighbours(_ on: Bool) { change { $0.showsNeighbours = on } }
    func setData(_ data: MeasureValueOverride.Data) { change { $0.data = data } }
    func setTime(_ time: StudioPreviewState.Time) { change { $0.time = time } }
    func setAppearance(_ appearance: StudioPreviewState.Appearance) { change { $0.appearance = appearance } }
    func setGlass(_ glass: StudioPreviewState.Glass) { change { $0.glass = glass } }

    /// Back to Live: every data and time preset off at once.
    func backToLive() {
        change {
            $0.data = .live
            $0.time = .live
        }
    }

    /// Interact on or off: the Studio's instance takes the pointer (its host says so to the engine).
    func setInteracting(_ on: Bool) {
        change { $0.interacting = on }
        session?.host.takesPointer = state.interacting
        canvasController.interactionView.isActive = state.interacting
        if state.interacting, presentsWindows {
            canvasController.view.window?.makeFirstResponder(canvasController.interactionView)
        }
        if !state.interacting { clearHeldAction() }
    }

    /// The canvas's look and the look the Studio's instance sees (its `#MACDARKMODE#`…, loaded again to take it).
    private func applyAppearance(reload: Bool) {
        let appearance: NSAppearance?
        switch state.appearance {
        case .followMac: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        canvasController.view.appearance = appearance
        let skinAppearance = appearance.map { MacAppearance.values(for: $0) }
        guard let session, session.host.appearance != skinAppearance else { return }
        session.host.appearance = skinAppearance
        if reload { session.reloadStudioSkin() }
    }

    /// Whether the canvas shows dark (the preview's look, else the Mac's).
    var canvasIsDark: Bool {
        switch state.appearance {
        case .followMac: return macIsDark()
        case .light: return false
        case .dark: return true
        }
    }

    // MARK: Backdrop and neighbours

    /// Reads the desktop picture of the widget's screen (off the main thread; the backdrop redraws when it arrives).
    func refreshBackdrop() {
        let backdrop = canvasController.backdropView
        backdrop.kind = state.backdrop
        guard state.backdrop == .desktop else { return }
        if backdrop.usesStandInDesktop {
            fidelity = .exact
            return
        }
        guard let screen = link?.desktopScreen ?? NSScreen.main else {
            backdrop.wallpaper = nil
            fidelity = .close
            return
        }
        let dark = canvasIsDark
        if let wallpaper = wallpapers.wallpaper(for: screen, dark: dark, ready: { [weak self] in
            self?.refreshBackdrop()
            self?.refreshBars()
        }) {
            backdrop.wallpaper = wallpaper
            fidelity = wallpaper.image == nil ? .close : wallpaper.fidelity
        }
    }

    /// Whether the other widgets are drawn: as chosen, else at 100 % when this one is on the desktop.
    var showsNeighbours: Bool {
        guard link?.isOnDesktop == true else { return false }
        return state.showsNeighbours ?? (abs(canvasController.canvas.zoom - 1) < 0.001)
    }

    /// Takes the other widgets' pictures from their windows now (and every 2 seconds while they are shown).
    func refreshNeighbours() {
        let view = canvasController.neighboursView
        guard showsNeighbours, let link else {
            view.neighbours = []
            neighbourTimer?.invalidate()
            neighbourTimer = nil
            return
        }
        view.neighbours = link.otherWidgetWindows().map(StudioNeighbourCapture.capture)
        guard neighbourTimer == nil, presentsWindows else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.windowController?.window?.isVisible == true else { return }
            // The widget may have moved on the desktop meanwhile.
            self.canvasController.geometryChanged()
            self.refreshNeighbours()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        neighbourTimer = timer
    }

    // MARK: Zoom

    func zoomIn() {
        isActualSize = false
        let z = canvasController.canvas.zoom
        canvasController.setZoom(SkinCanvasView.steps.first { $0 > z + 0.001 } ?? SkinCanvasView.maxZoom)
    }

    func zoomOut() {
        isActualSize = false
        let z = canvasController.canvas.zoom
        canvasController.setZoom(SkinCanvasView.steps.last { $0 < z - 0.001 } ?? SkinCanvasView.minZoom)
    }

    func zoomToFit() {
        isActualSize = false
        canvasController.zoomToFit()
        refreshAll()
    }

    /// Actual Size (⌘0): 100 %, the backdrop lined up with where the widget really is, the other widgets around it.
    func actualSize() {
        canvasController.setZoom(1)
        isActualSize = true
        refreshAll()
    }

    private func zoomChanged() {
        if abs(canvasController.canvas.zoom - 1) > 0.001 { isActualSize = false }
        refreshNeighbours()
        refreshBars()
    }

    /// The caption above the widget.
    func caption(zoom: CGFloat) -> String {
        let file = session?.fileURL?.lastPathComponent ?? ""
        return StudioSizeName.caption(zoom: zoom, file: file, onDesktop: link?.isOnDesktop ?? false,
                                      actualSize: isActualSize && abs(zoom - 1) < 0.001)
    }

    // MARK: The bars

    func refreshAll() {
        refreshNeighbours()
        refreshBars()
    }

    /// The preview bar, the zoom capsule, the status capsule and the caption say what is in use now.
    func refreshBars() {
        let canvas = canvasController
        canvas.previewBar.show(state, macIsDark: macIsDark(), fidelity: fidelity)
        canvas.zoomCapsule.show(zoom: canvas.canvas.zoom, showingDesktop: desktopView.isShowing,
                                canShowDesktop: link?.isOnDesktop ?? false)
        if let heldAction {
            canvas.statusCapsule.show(heldAction.sentence, symbol: "hand.point.up.left", action: heldAction.button) {
                [weak self] in self?.performHeldAction()
            }
            canvas.statusCapsule.toolTip = heldAction.recorded.text
            canvas.statusCapsule.isHidden = false
        } else if let sentence = state.previewingSentence {
            canvas.statusCapsule.toolTip = nil
            canvas.statusCapsule.show(sentence)
            canvas.statusCapsule.isHidden = false
        } else {
            canvas.statusCapsule.isHidden = true
        }
        canvas.view.needsLayout = true
        canvas.placeCaption()
    }

    // MARK: Interact's held-back actions

    /// The Studio's instance held an action back: while it interacts, the capsule offers it.
    private func held(_ recorded: StudioActionPolicy.Recorded) {
        guard state.interacting else { return }
        heldAction = StudioHeldAction(recorded)
        heldActionTimer?.invalidate()
        if presentsWindows {
            let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in self?.clearHeldAction() }
            RunLoop.main.add(timer, forMode: .common)
            heldActionTimer = timer
        }
        refreshBars()
    }

    func clearHeldAction() {
        heldActionTimer?.invalidate()
        heldActionTimer = nil
        guard heldAction != nil else { return }
        heldAction = nil
        refreshBars()
    }

    /// "Open": the widget on the desktop does it for real.
    func performHeldAction() {
        guard let action = heldAction else { return }
        link?.perform(action.recorded)
        clearHeldAction()
    }

    // MARK: Popovers and menus

    /// Preview: Light Mode ▾ opens the "Preview only" popover (headless: made, not shown; the snapshot composes it).
    func showPreviewPopover() {
        let content = StudioPreviewPopoverController(state: state)
        content.onChange = { [weak self] appearance, glass in
            self?.change {
                $0.appearance = appearance
                $0.glass = glass
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        previewPopover = popover
        previewPopoverContent = content
        guard presentsWindows, windowController?.window?.isVisible == true else { return }
        let item = canvasController.previewBar.appearanceItem
        popover.show(relativeTo: item.bounds, of: item, preferredEdge: .minY)
    }

    func closePreviewPopover() {
        previewPopover?.close()
        previewPopover = nil
        previewPopoverContent = nil
    }

    func showBackdropMenu() {
        let menu = menus.backdropMenu(state, fidelity: fidelity, reduceTransparency: reduceTransparency(),
                                      canShowNeighbours: link?.isOnDesktop ?? false, neighboursShown: showsNeighbours)
        popUp(menu, from: canvasController.previewBar.backdropItem)
    }

    func showDataMenu() {
        popUp(menus.dataMenu(state), from: canvasController.previewBar.dataItem)
    }

    private func popUp(_ menu: NSMenu, from item: NSView) {
        guard presentsWindows, item.window?.isVisible == true else { return }
        // Above the bar (the item is flipped: up is negative).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -(menu.size.height + 6)), in: item)
    }

    func showTimePicker() {
        var initial = StudioPreviewState.tenPastTen()
        if case .frozen(let date) = state.time { initial = date }
        let content = StudioTimePickerController(date: initial)
        content.onPick = { [weak self] date in self?.setTime(.frozen(date)) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        timePopover = popover
        guard presentsWindows, windowController?.window?.isVisible == true else { return }
        let item = canvasController.previewBar.dataItem
        popover.show(relativeTo: item.bounds, of: item, preferredEdge: .minY)
    }

    // MARK: Keys

    /// ⇧⌘D: Show on Desktop (a hold peeks); ⌥⌘P: Interact.
    func keyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if StudioDesktopView.isShortcut(event) {
            if !event.isARepeat { desktopView.toggle(fromKey: true) }
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [.command, .option],
           event.charactersIgnoringModifiers?.lowercased() == "p" || event.keyCode == 35 {
            setInteracting(!state.interacting)
            return true
        }
        return false
    }
}
