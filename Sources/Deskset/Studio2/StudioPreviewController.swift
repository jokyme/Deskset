import AppKit
import DesksetCore

/// The Studio window's preview: what the preview bar, the zoom capsule and the capsules over the canvas show and do —
/// the backdrop (with the desktop picture read safely), the other widgets around this one, the Mac's look and the glass
/// the canvas shows, and Actual Size.
/// None of it changes the widget: the desktop copy keeps its live data, and nothing is written.
final class StudioPreviewController {
    private weak var windowController: StudioWindowController?
    let canvasController: StudioCanvasViewController
    let preferences: StudioPreferences
    let wallpapers = WallpaperSource()
    let menus = StudioPreviewMenus()
    /// Whether windows go on screen (not headless).
    let presentsWindows: Bool
    private(set) var state = StudioPreviewState()
    private(set) var fidelity = WallpaperFidelity.exact
    /// The canvas is at 100 % because Actual Size put it there (the caption says where it is).
    private(set) var isActualSize = false
    private(set) var previewPopover: NSPopover?
    private(set) var previewPopoverContent: StudioPreviewPopoverController?
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
        if !StudioBackdropKind.offered(reduceTransparency: reduceTransparency()).contains(state.backdrop) {
            state.backdrop = .desktop
        }
        canvas.backdropView.usesStandInDesktop = !presentsWindows
        wire()
    }

    deinit {
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
        let zoom = canvas.zoomCapsule
        zoom.zoomOutItem.action = { [weak self] in self?.zoomOut() }
        zoom.zoomInItem.action = { [weak self] in self?.zoomIn() }
        zoom.percentItem.action = { [weak self] in self?.zoomToFit() }
        zoom.actualSizeItem.action = { [weak self] in self?.actualSize() }
        canvas.caption = { [weak self] zoom in self?.caption(zoom: zoom) ?? "" }
        canvas.glassRegions = { [weak self] regions, dark in self?.state.previewed(regions, dark: dark) ?? regions }
        canvas.widgetFrame = { [weak self] in self?.link?.desktopFrame }
        canvas.onZoomChange = { [weak self] in self?.zoomChanged() }
        menus.onBackdrop = { [weak self] kind in self?.setBackdrop(kind) }
        menus.onNeighbours = { [weak self] on in self?.setShowsNeighbours(on) }
    }

    /// The window shows a widget.
    func attach() {
        guard session != nil else { return }
        applyAppearance(reload: false)
        refreshBackdrop()
        refreshAll()
    }

    /// The window lets go of the widget: the preview ends.
    func detach() {
        previewPopover?.close()
        neighbourTimer?.invalidate()
        neighbourTimer = nil
        session?.host.appearance = nil
        state.showsNeighbours = nil
    }

    // MARK: State

    /// Applies what changed from `old` to the canvas and the Studio's instance.
    private func stateChanged(from old: StudioPreviewState) {
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
    func setAppearance(_ appearance: StudioPreviewState.Appearance) { change { $0.appearance = appearance } }
    func setGlass(_ glass: StudioPreviewState.Glass) { change { $0.glass = glass } }

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

    /// A notice over the canvas for a while (a file opened for editing whose skin is no longer installed).
    private(set) var notice: String?
    private var noticeTimer: Timer?

    func showNotice(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            self?.notice = nil
            self?.refreshBars()
        }
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
        refreshBars()
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
        canvas.zoomCapsule.show(zoom: canvas.canvas.zoom)
        if let notice {
            canvas.statusCapsule.toolTip = nil
            canvas.statusCapsule.show(notice, symbol: "exclamationmark.triangle")
            canvas.statusCapsule.isHidden = false
        } else {
            canvas.statusCapsule.isHidden = true
        }
        canvas.view.needsLayout = true
        canvas.placeCaption()
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

    func showBackdropMenu() {
        let menu = menus.backdropMenu(state, fidelity: fidelity, reduceTransparency: reduceTransparency(),
                                      canShowNeighbours: link?.isOnDesktop ?? false, neighboursShown: showsNeighbours)
        popUp(menu, from: canvasController.previewBar.backdropItem)
    }

    private func popUp(_ menu: NSMenu, from item: NSView) {
        guard presentsWindows, item.window?.isVisible == true else { return }
        // Above the bar (the item is flipped: up is negative).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -(menu.size.height + 6)), in: item)
    }
}
