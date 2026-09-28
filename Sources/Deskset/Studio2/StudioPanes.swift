import AppKit
import DesksetCore

/// What lies behind the widget on the Studio's canvas. For now a quiet placeholder; the wallpaper behind the widget,
/// the workbench and the samples come next (the canvas leaves its own work surface unpainted, so this shows).
final class StudioBackdropView: NSView {
    enum Kind: Equatable {
        /// A plain, soft backdrop until the real ones exist.
        case placeholder
    }

    var kind = Kind.placeholder { didSet { needsDisplay = true } }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = dark ? NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1)
                       : NSColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1)
        let bottom = dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
                          : NSColor(srgbRed: 0.82, green: 0.84, blue: 0.88, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: bounds, angle: 90)
    }
}

/// The canvas pane: the backdrop, and the widget (the Studio's own instance, drawn by the real renderer on
/// `SkinCanvasView`) in a magnifying scroll view over it. It reaches under the toolbar, as the window's content does.
final class StudioCanvasViewController: NSViewController {
    let backdropView = StudioBackdropView()
    let scrollView = OverlayScrollView()
    let canvas = SkinCanvasView()
    /// The skin the canvas draws (the session's instance).
    var skinProvider: () -> Skin? = { nil } {
        didSet { canvas.skinProvider = skinProvider }
    }
    /// Until the user zooms, the canvas fits the widget whenever it or the pane changes size.
    var autoFit = true
    /// The zoom the canvas keeps when set (a screen of `--snapshot-ui studio2`); nil: fit.
    var fixedZoom: CGFloat?
    /// The toolbar's height over the canvas (its content stays below it).
    static let toolbarHeight: CGFloat = 52
    private var redrawTimer: Timer?

    override func loadView() {
        let container = NSView()
        container.setAccessibilityElement(false)
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdropView)
        container.addSubview(scrollView)
        let clip = CenteringClipView()
        clip.drawsBackground = false
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
        scrollView.contentInsets = NSEdgeInsets(top: Self.toolbarHeight, left: 0, bottom: 0, right: 0)
        canvas.paintsSurface = false
        canvas.isEditable = false
        canvas.skinProvider = skinProvider
        canvas.onUserZoom = { [weak self] in self?.autoFit = false }
        canvas.setAccessibilityLabel(StudioText[.canvas])
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: container.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitIfAutomatic()
    }

    /// The widget was loaded again (or another one is shown): the canvas takes its size and draws it; `fit` fits it
    /// again (another widget).
    func reload(fit: Bool = false) {
        _ = view
        if fit { autoFit = true }
        canvas.updateSize()
        fitIfAutomatic()
        canvas.needsDisplay = true
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
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    func stopRedrawing() {
        redrawTimer?.invalidate()
        redrawTimer = nil
    }

    deinit { redrawTimer?.invalidate() }
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
