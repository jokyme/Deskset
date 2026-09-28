import AppKit
import DesksetCore

/// The canvas pane's view: lays out what floats over the canvas (the caption above the widget, the capsule at the top,
/// the preview bar and the zoom capsule at the bottom) and passes keys it knows to the window.
final class StudioCanvasContainer: NSView {
    var onLayout: (() -> Void)?
    /// ⇧⌘D, ⌥⌘P: the Studio's keys without menu items of their own yet.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The canvas pane: the widget where it will be seen, over planes back to front — the backdrop (your desktop picture
/// by default), the other widgets on the desktop, the widget's glass — with the widget itself (the Studio's own
/// instance, drawn by the real renderer on `SkinCanvasView`) in a magnifying scroll view over them, a transparent layer
/// that takes the pointer while the Studio interacts, and the floating controls. It reaches under the toolbar, as the
/// window's content does.
final class StudioCanvasViewController: NSViewController {
    /// Stand-ins for glass (no window server to draw it: snapshots, self-tests).
    let standIns: Bool
    let backdropView = StudioBackdropView()
    let neighboursView = StudioNeighboursView()
    let glassPlane: StudioGlassPlane
    let scrollView = OverlayScrollView()
    let canvas = SkinCanvasView()
    let interactionView = StudioInteractionView()
    let captionTag: StudioCaptionTag
    let statusCapsule: StudioStatusCapsule
    let previewBar: StudioPreviewBar
    let zoomCapsule: StudioZoomCapsule
    /// The skin the canvas draws (the session's instance).
    var skinProvider: () -> Skin? = { nil } {
        didSet {
            canvas.skinProvider = skinProvider
            interactionView.skinProvider = skinProvider
        }
    }
    /// Where the widget is on the desktop (its window's frame, global coordinates; nil: not on the desktop).
    var widgetFrame: () -> CGRect? = { nil }
    /// The caption above the widget, for the zoom it is drawn at.
    var caption: (CGFloat) -> String = { _ in "" }
    /// How the preview shows glass.
    var glassRegions: ([GlassRegion], Bool) -> [GlassRegion] = { regions, _ in regions }
    /// The zoom changed (the zoom capsule, the caption, the neighbours follow).
    var onZoomChange: (() -> Void)?
    /// Until the user zooms, the canvas fits the widget whenever it or the pane changes size.
    var autoFit = true
    /// The zoom the canvas keeps when set (a screen of `--snapshot-ui studio2`); nil: fit.
    var fixedZoom: CGFloat?
    /// The toolbar's height over the canvas (its content stays below it).
    static let toolbarHeight: CGFloat = 52
    /// The room the preview bar takes at the bottom of the canvas (its height and margins).
    static let previewBarRoom: CGFloat = 76
    /// Where the status capsule's middle is, from the top of the pane.
    static let statusCapsuleY: CGFloat = 104
    private var redrawTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastZoom: CGFloat = 0

    init(standIns: Bool) {
        self.standIns = standIns
        glassPlane = StudioGlassPlane(standIns: standIns)
        captionTag = StudioCaptionTag(standIn: standIns)
        statusCapsule = StudioStatusCapsule(standIn: standIns)
        previewBar = StudioPreviewBar(standIn: standIns)
        zoomCapsule = StudioZoomCapsule(standIn: standIns)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        redrawTimer?.invalidate()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    override func loadView() {
        let container = StudioCanvasContainer()
        container.setAccessibilityElement(false)
        container.onLayout = { [weak self] in self?.layoutFloating() }
        let clip = CenteringClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = SkinCanvasView.minZoom
        scrollView.maxMagnification = SkinCanvasView.maxZoom
        scrollView.automaticallyAdjustsContentInsets = false
        // The widget sits in the room between the toolbar and the preview bar.
        scrollView.contentInsets = NSEdgeInsets(top: Self.toolbarHeight, left: 0, bottom: Self.previewBarRoom, right: 0)
        canvas.paintsSurface = false
        canvas.glassDrawing = SkinRenderer.GlassDrawing.none
        canvas.isEditable = false
        canvas.skinProvider = skinProvider
        canvas.postsFrameChangedNotifications = true
        canvas.onUserZoom = { [weak self] in self?.autoFit = false }
        canvas.onZoom = { [weak self] _ in self?.geometryChanged() }
        canvas.onLayoutChange = { [weak self] in self?.geometryChanged() }
        canvas.setAccessibilityLabel(StudioText[.canvas])
        interactionView.canvas = canvas
        interactionView.skinProvider = skinProvider
        interactionView.onEvent = { [weak self] in self?.canvas.needsDisplay = true }
        for plane in [backdropView, neighboursView, glassPlane, scrollView, interactionView] as [NSView] {
            plane.autoresizingMask = [.width, .height]
            container.addSubview(plane)
        }
        for floating in [captionTag, statusCapsule, previewBar, zoomCapsule] as [NSView] {
            container.addSubview(floating)
        }
        statusCapsule.isHidden = true
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        view = container
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.geometryChanged()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: canvas, queue: .main) { [weak self] _ in
                self?.geometryChanged()
            })
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        for plane in [backdropView, neighboursView, glassPlane, scrollView, interactionView] as [NSView] {
            plane.frame = view.bounds
        }
        fitIfAutomatic()
        geometryChanged()
    }

    /// The widget was loaded again (or another one is shown): the canvas takes its size and draws it; `fit` fits it
    /// again (another widget).
    func reload(fit: Bool = false) {
        _ = view
        if fit { autoFit = true }
        canvas.updateSize()
        fitIfAutomatic()
        canvas.needsDisplay = true
        geometryChanged()
        startRedrawing()
    }

    /// Fits the widget to the pane, or keeps `fixedZoom`, until the user zooms.
    func fitIfAutomatic() {
        guard canvas.enclosingScrollView != nil else { return }
        if let fixedZoom {
            if abs(canvas.zoom - fixedZoom) > 0.001 { canvas.setZoom(fixedZoom, centeredAt: centre) }
            return
        }
        guard autoFit else { return }
        let z = canvas.fitZoom()
        if abs(canvas.zoom - z) > 0.001 { canvas.setZoom(z, centeredAt: centre) }
    }

    private var centre: NSPoint { NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY) }

    /// Sets the zoom (the zoom capsule, ⌘0, ⌘+): the user's own from then on.
    func setZoom(_ zoom: CGFloat) {
        autoFit = false
        fixedZoom = nil
        canvas.setZoom(zoom, centeredAt: centre)
        geometryChanged()
    }

    func zoomToFit() {
        fixedZoom = nil
        autoFit = true
        fitIfAutomatic()
        geometryChanged()
    }

    // MARK: Geometry

    /// The widget's card in the pane's coordinates.
    var cardRect: CGRect {
        guard skinProvider() != nil else { return .zero }
        return canvas.convert(canvas.skinRect, to: view)
    }

    /// How the desktop lies under the canvas: the widget's real frame at the card (a made-up place when it is not on
    /// the desktop).
    var mapping: DesktopMapping {
        let card = cardRect
        let zoom = canvas.zoom
        let frame = widgetFrame() ?? CGRect(x: 0, y: 0, width: card.width / max(zoom, 0.01),
                                            height: card.height / max(zoom, 0.01))
        return DesktopMapping(widgetFrame: frame, cardRect: card, zoom: zoom)
    }

    /// The canvas moved, zoomed or the widget changed size: the planes and the caption follow.
    func geometryChanged() {
        guard isViewLoaded else { return }
        let m = mapping
        backdropView.mapping = m
        neighboursView.mapping = m
        glassPlane.cardRect = m.cardRect
        glassPlane.zoom = m.zoom
        updateGlass()
        placeCaption()
        if abs(m.zoom - lastZoom) > 0.0001 {
            lastZoom = m.zoom
            onZoomChange?()
        }
    }

    /// The widget's glass, as the preview shows it, on the glass plane.
    func updateGlass() {
        let dark = backdropView.showsDarkBackdrop
        glassPlane.darkBackdrop = dark
        neighboursView.darkBackdrop = dark
        glassPlane.regions = glassRegions(skinProvider()?.glassRegions ?? [], dark)
    }

    /// The caption sits above the widget's top-left corner (hidden when that is under the toolbar).
    func placeCaption() {
        let card = cardRect
        captionTag.text = caption(canvas.zoom)
        let size = captionTag.intrinsicContentSize
        let y = card.minY - 9 - size.height
        captionTag.frame = NSRect(x: card.minX + 2, y: y, width: size.width, height: size.height)
        captionTag.isHidden = card.isEmpty || y < Self.toolbarHeight + 4 || captionTag.text.isEmpty
    }

    /// The preview bar and the zoom capsule at the bottom, the status capsule at the top. On a narrow canvas the zoom
    /// capsule's words shorten first ("1:1", "Desktop"), then the backdrop's go; the bar sits in the middle when there
    /// is room, else in the room left of the zoom capsule.
    func layoutFloating() {
        let w = view.bounds.width, h = view.bounds.height
        zoomCapsule.compact = false
        previewBar.compact = false
        func fits() -> Bool { previewBar.fittingWidth + zoomCapsule.fittingWidth + 16 + 16 + 14 <= w }
        if !fits() { zoomCapsule.compact = true }
        if !fits() { previewBar.compact = true }
        let pill = zoomCapsule.fittingWidth, bar = previewBar.fittingWidth
        let barHeight = StudioPreviewBar.height
        zoomCapsule.frame = NSRect(x: w - 16 - pill, y: h - 34 - barHeight / 2, width: pill, height: barHeight)
        let centred = w / 2 + bar / 2 <= w - 16 - pill - 14
        let room = w - 16 - pill - 14 - 16
        let cx = centred ? w / 2 : 16 + max(bar, room) / 2
        previewBar.frame = NSRect(x: (cx - bar / 2).rounded(), y: h - 34 - barHeight / 2, width: bar, height: barHeight)
        let status = statusCapsule.fittingWidth
        statusCapsule.frame = NSRect(x: ((w - status) / 2).rounded(), y: Self.statusCapsuleY - StudioStatusCapsule.height / 2,
                                     width: status, height: StudioStatusCapsule.height)
        placeCaption()
    }

    // MARK: Drawing

    /// The canvas follows the widget's own update rate (at most 30 frames a second, at least once a second).
    private func startRedrawing() {
        redrawTimer?.invalidate()
        let update = Double(skinProvider()?.settings.update ?? 1000) / 1000
        let interval = update > 0 ? min(max(update, 1.0 / 30), 1) : 1
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.skinProvider() != nil else { return }
            let before = self.canvas.frame.size
            self.canvas.updateSize()
            if self.canvas.frame.size != before { self.fitIfAutomatic() }
            self.canvas.needsDisplay = true
            self.updateGlass()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    func stopRedrawing() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }
}

/// The sidebar (Build depth): Add and Layers. Empty for now; it is collapsed while the Studio customizes.
final class StudioSidebarViewController: NSViewController {
    override func loadView() {
        let v = NSView()
        v.setAccessibilityLabel(StudioText[.sidebar])
        view = v
    }
}

/// The inspector: the page of what is selected ("What do you want to change?" on top). Empty for now.
final class StudioInspectorViewController: NSViewController {
    override func loadView() {
        let v = NSView()
        v.setAccessibilityLabel(StudioText[.inspector])
        view = v
    }
}
