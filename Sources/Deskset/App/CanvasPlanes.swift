import AppKit
import DesksetCore

/// The canvas in planes. `SkinCanvasView` draws nothing itself: three sibling views fill it, bottom to top, each
/// with its own layer on screen, so one can be drawn again without the others:
///
/// - **workbench**: the dotted work surface, the widget card's shadow and its backdrop. It is drawn again only when
///   the zoom, the canvas's size, the card, the backdrop or the appearance changes (`CanvasPlanes.Workbench`).
/// - **content**: the widget (`SkinRenderer.draw`), the hatch over what the desktop leaves transparent or cuts off,
///   the ghost of what lies outside the card, the dashed outlines of what is cut off and the pixel grid.
/// - **overlay**: hover and selection outlines, handles, guides, the selection box, tags, badges, editor-only
///   placeholders and the ghost of a component dragged in from Add.
///
/// Pointing at a layer or selecting one draws the overlay only (`SkinCanvasView.overlayNeedsDisplay`); anything else
/// that asks the canvas to draw (`needsDisplay = true`: the widget updated, a preview, a gesture) draws the content
/// and the overlay. The planes draw with the canvas's own drawing code in the order it always drew, and they are
/// plain subviews, so an off-screen picture of the canvas (`cacheDisplay`, the snapshots and the latency frame)
/// composes exactly the pixels one drawing gave. They take no events: clicks, drags, drops and the pointer all go to
/// the canvas. A view the canvas adds later (the in-place text field) lies over all three.
final class CanvasPlanes {
    /// What the workbench plane shows depends on: when one of these changes, it is drawn again.
    struct Workbench: Equatable {
        var zoom: CGFloat
        var size: CGSize
        /// The widget card, view coordinates (nil: no widget).
        var card: CGRect?
        var backdrop: SkinCanvasView.Backdrop
        var dark: Bool
    }

    let workbench = CanvasPlane(.workbench)
    let content = CanvasPlane(.content)
    let overlay = CanvasPlane(.overlay)
    var all: [CanvasPlane] { [workbench, content, overlay] }
    /// What the workbench plane was last asked to draw (recorded when it is asked, so an off-screen picture, which
    /// draws every plane, can't make the screen's copy look current).
    private var workbenchShows: Workbench?
    /// Self-tests: the canvas drawn as it was before it had planes — the workbench plane draws all three parts in one
    /// drawing and the other two are hidden.
    var drawsInOne = false {
        didSet {
            content.isHidden = drawsInOne
            overlay.isHidden = drawsInOne
            workbench.needsDisplay = true
        }
    }

    /// Puts the planes in `canvas`, bottom to top, filling it (call before it has other subviews).
    func install(in canvas: SkinCanvasView) {
        for plane in all {
            plane.canvas = canvas
            canvas.addSubview(plane)
        }
        fit(canvas)
    }

    /// The planes take the canvas's size (exactly: autoresizing rounds, and they must cover every pixel it has).
    func fit(_ canvas: SkinCanvasView) {
        for plane in all where plane.frame != canvas.bounds { plane.frame = canvas.bounds }
    }

    /// Draws the content and the overlay again, and the workbench when what it shows changed.
    func invalidate(for canvas: SkinCanvasView) {
        content.needsDisplay = true
        overlay.needsDisplay = true
        invalidateWorkbenchIfChanged(for: canvas)
    }

    /// Draws the workbench again when the zoom, size, card, backdrop or appearance changed since it was last asked to.
    func invalidateWorkbenchIfChanged(for canvas: SkinCanvasView) {
        let now = canvas.workbenchState
        guard now != workbenchShows else { return }
        workbenchShows = now
        workbench.needsDisplay = true
    }

    /// How often each plane drew (the self-tests).
    var drawCounts: (workbench: Int, content: Int, overlay: Int) { (workbench.drawCount, content.drawCount, overlay.drawCount) }
}

/// One plane of the canvas (`CanvasPlanes`): a transparent, flipped view the size of the canvas that draws its part
/// with the canvas's code and takes no events.
final class CanvasPlane: NSView {
    enum Kind: String { case workbench, content, overlay }

    let kind: Kind
    weak var canvas: SkinCanvasView?
    /// How often it drew (the self-tests).
    private(set) var drawCount = 0

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("canvas-plane-\(kind.rawValue)")
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// The canvas takes every click, drag, drop and pointer move.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        // A layer drawn outside a window (an off-screen picture of a canvas that is in none) is asked for an infinite
        // rectangle: the dots would never end.
        let dirtyRect = dirtyRect.intersection(bounds)
        guard let canvas, !dirtyRect.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch kind {
        case .workbench:
            let state = StudioSignposts.signposter.beginInterval("canvas.workbench")
            defer { StudioSignposts.signposter.endInterval("canvas.workbench", state) }
            canvas.drawWorkbench(dirtyRect, ctx)
            if canvas.planes.drawsInOne {
                canvas.drawContent(dirtyRect, ctx)
                canvas.drawOverlayPlane(dirtyRect, ctx)
            }
        case .content:
            let state = StudioSignposts.signposter.beginInterval("canvas.paint")
            defer { StudioSignposts.signposter.endInterval("canvas.paint", state) }
            // A change the workbench missed (a pinch that ended, a card that grew between two asks) is caught here.
            canvas.planes.invalidateWorkbenchIfChanged(for: canvas)
            canvas.drawContent(dirtyRect, ctx)
        case .overlay:
            let state = StudioSignposts.signposter.beginInterval("canvas.overlay")
            defer { StudioSignposts.signposter.endInterval("canvas.overlay", state) }
            canvas.drawOverlayPlane(dirtyRect, ctx)
        }
    }
}

extension SkinCanvasView {
    /// What the workbench plane shows depends on, now.
    var workbenchState: CanvasPlanes.Workbench {
        CanvasPlanes.Workbench(zoom: zoom, size: bounds.size, card: skinProvider() == nil ? nil : skinRect,
                               backdrop: backdrop,
                               dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// Draws the overlay again, and only it: the pointer, the selection, the guides or the tags changed, not the widget.
    func overlayNeedsDisplay() {
        planes.overlay.needsDisplay = true
        if planes.drawsInOne { planes.workbench.needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        planes.fit(self)
    }
}
