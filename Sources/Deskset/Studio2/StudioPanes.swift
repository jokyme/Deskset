import AppKit
import DesksetCore

/// The canvas pane's view: lays out what floats over the canvas (the caption above the widget, the capsule at the top,
/// the preview bar and the zoom capsule at the bottom) and passes keys it knows to the window.
final class StudioCanvasContainer: NSView {
    var onLayout: (() -> Void)?
    /// ⇧⌘D, ⌥⌘P: the Studio's keys without menu items of their own yet.
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// Keys the canvas passes up (⇧Return: one level up).
    var onKeyDown: ((NSEvent) -> Bool)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
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
    /// What pointed-at things draw, a wider scope's reach, the distances with ⌥ held.
    let overlay = StudioCanvasOverlay()
    let interactionView = StudioInteractionView()
    /// The code's problems on the parts: amber frames, red ghosts.
    let problemMarks = StudioProblemMarks()
    /// "The bars can’t draw · your desktop keeps the last working version", while red problems are open.
    let problemCapsule: StudioStatusCapsule
    let captionTag: StudioCaptionTag
    let statusCapsule: StudioStatusCapsule
    let previewBar: StudioPreviewBar
    let zoomCapsule: StudioZoomCapsule
    /// "Rainmeter skin · compatibility mode" (and the offer to switch), over a Rainmeter skin.
    let compatCapsule: StudioCompatCapsule
    /// A hint over the canvas's corner while the sidebar is closed ("Rainmeter names on · ⌥⌘R to hide").
    let hintPill = StudioHintPill()
    /// Whether the compatibility capsule shows, and its offer.
    var compatState: () -> (shown: Bool, offer: Bool) = { (false, false) }
    /// The skin the canvas draws (the session's instance).
    var skinProvider: () -> Skin? = { nil } {
        didSet {
            canvas.skinProvider = skinProvider
            interactionView.skinProvider = skinProvider
            overlay.skinProvider = skinProvider
            problemMarks.skinProvider = skinProvider
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
    /// The code is open beside the canvas: the preview bar keeps only icons (and "Interact"), the zoom capsule leaves
    /// Actual Size out.
    var besideCode = false {
        didSet {
            guard besideCode != oldValue, isViewLoaded else { return }
            previewBar.iconsOnly = besideCode
            zoomCapsule.hidesActualSize = besideCode
            layoutFloating()
        }
    }
    /// The toolbar's height over the canvas (its content stays below it).
    static let toolbarHeight: CGFloat = 52
    /// The room the preview bar takes at the bottom of the canvas (its height and margins).
    static let previewBarRoom: CGFloat = 76
    /// Where the status capsule's middle is, from the top of the pane.
    static let statusCapsuleY: CGFloat = 104
    /// Where the compatibility capsule's middle is (the design's 132).
    static let compatCapsuleY: CGFloat = 134
    private var redrawTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastZoom: CGFloat = 0

    init(standIns: Bool) {
        self.standIns = standIns
        glassPlane = StudioGlassPlane(standIns: standIns)
        captionTag = StudioCaptionTag(standIn: standIns)
        statusCapsule = StudioStatusCapsule(standIn: standIns)
        problemCapsule = StudioStatusCapsule(standIn: standIns)
        problemCapsule.messageItem.iconColor = StudioCodeColors.problem
        previewBar = StudioPreviewBar(standIn: standIns)
        zoomCapsule = StudioZoomCapsule(standIn: standIns)
        compatCapsule = StudioCompatCapsule(standIn: standIns)
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
        // Parts are selected and dragged; the first click passes over parts that draw nothing.
        canvas.isEditable = true
        canvas.hitFilter = { StudioHitRule.pick($0) }
        overlay.canvas = canvas
        overlay.skinProvider = skinProvider
        overlay.animates = !standIns
        canvas.skinProvider = skinProvider
        canvas.postsFrameChangedNotifications = true
        canvas.onUserZoom = { [weak self] in self?.autoFit = false }
        canvas.onZoom = { [weak self] _ in self?.geometryChanged() }
        canvas.onLayoutChange = { [weak self] in self?.geometryChanged() }
        canvas.setAccessibilityLabel(StudioText[.canvas])
        interactionView.canvas = canvas
        interactionView.skinProvider = skinProvider
        interactionView.onEvent = { [weak self] in self?.canvas.needsDisplay = true }
        problemMarks.canvas = canvas
        problemMarks.skinProvider = skinProvider
        for plane in [backdropView, neighboursView, glassPlane, scrollView, overlay, problemMarks, interactionView]
            as [NSView] {
            plane.autoresizingMask = [.width, .height]
            container.addSubview(plane)
        }
        for floating in [captionTag, problemCapsule, statusCapsule, compatCapsule, hintPill, previewBar, zoomCapsule]
            as [NSView] {
            container.addSubview(floating)
        }
        statusCapsule.isHidden = true
        problemCapsule.isHidden = true
        compatCapsule.isHidden = true
        hintPill.isHidden = true
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
        for plane in [backdropView, neighboursView, glassPlane, scrollView, overlay, problemMarks, interactionView]
            as [NSView] {
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
        overlay.needsDisplay = true
        problemMarks.needsDisplay = true
        if abs(m.zoom - lastZoom) > 0.0001 {
            lastZoom = m.zoom
            onZoomChange?()
        }
    }

    /// The widget's glass, as the preview shows it, on the glass plane.
    func updateGlass() {
        let dark = backdropView.showsDarkBackdrop
        glassPlane.darkBackdrop = dark
        glassPlane.darkAppearance = StudioPageStyle.isDark(view.effectiveAppearance)
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
        // Hidden under the toolbar, and where the capsule over the canvas already speaks.
        let underCapsule = [statusCapsule, problemCapsule].contains { capsule in
            !capsule.isHidden && captionTag.frame.intersects(capsule.frame.insetBy(dx: -4, dy: -4))
        }
        // Beside the code the canvas is narrow and the code says what the widget is: no caption.
        captionTag.isHidden = card.isEmpty || y < Self.toolbarHeight + 4 || captionTag.text.isEmpty || underCapsule
            || besideCode
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
        // Still too narrow: the zoom capsule goes up a row, over the bar's right end.
        let stacked = !fits()
        zoomCapsule.frame = NSRect(x: w - 16 - pill, y: h - 34 - barHeight / 2 - (stacked ? barHeight + 8 : 0),
                                   width: pill, height: barHeight)
        let right = stacked ? w : w - 16 - pill - 14
        let centred = w / 2 + bar / 2 <= right
        let room = right - 16
        let cx = centred ? w / 2 : 16 + max(bar, room) / 2
        previewBar.frame = NSRect(x: (cx - bar / 2).rounded(), y: h - 34 - barHeight / 2, width: bar, height: barHeight)
        var statusY = Self.statusCapsuleY
        // Red problems speak first: their capsule takes the compatibility capsule's place.
        if !problemCapsule.isHidden {
            let width = min(problemCapsule.fittingWidth, w - 32)
            problemCapsule.frame = NSRect(x: ((w - width) / 2).rounded(), y: statusY - StudioStatusCapsule.height / 2,
                                          width: width, height: StudioStatusCapsule.height)
            compatCapsule.isHidden = true
            statusY = problemCapsule.frame.maxY + 10 + StudioStatusCapsule.height / 2
        } else if !compatCapsule.isHidden {
            let size = compatCapsule.fittingSize2
            let width = min(size.width, w - 32)
            compatCapsule.frame = NSRect(x: ((w - width) / 2).rounded(), y: Self.compatCapsuleY - size.height / 2,
                                         width: width, height: size.height)
            statusY = compatCapsule.frame.maxY + 10 + StudioStatusCapsule.height / 2
        }
        let status = statusCapsule.fittingWidth
        statusCapsule.frame = NSRect(x: ((w - status) / 2).rounded(), y: statusY - StudioStatusCapsule.height / 2,
                                     width: status, height: StudioStatusCapsule.height)
        if !hintPill.isHidden {
            let size = hintPill.fittingSize(width: w - 32)
            hintPill.frame = NSRect(x: 16, y: Self.toolbarHeight + 12, width: size.width, height: size.height)
        }
        placeCaption()
    }

    /// The capsule of the code's red problems (nil: none).
    func showProblem(_ text: String?) {
        _ = view
        if let text { problemCapsule.show(text, symbol: "xmark.octagon.fill") }
        problemCapsule.isHidden = text == nil
        updateCompatCapsule()
    }

    /// Shows or hides the compatibility capsule and its offer, as the window says.
    func updateCompatCapsule() {
        _ = view
        let state = compatState()
        compatCapsule.isHidden = !state.shown || !problemCapsule.isHidden
        compatCapsule.showsOffer = state.offer
        layoutFloating()
    }

    /// The hint over the canvas's corner (nil: none).
    func setHint(_ text: String?) {
        _ = view
        hintPill.text = text ?? ""
        hintPill.isHidden = text == nil
        layoutFloating()
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
            if self.overlay.showsDistances { self.overlay.needsDisplay = true }
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
