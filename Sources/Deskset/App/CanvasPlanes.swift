import AppKit
import DesksetCore

/// The canvas in planes. `SkinCanvasView` draws nothing itself: two sibling views fill it, bottom to top, each with its
/// own layer on screen, so one can be drawn again without the other:
///
/// - **content**: the dotted work surface, the widget card's shadow and its backdrop (the workbench), and over them the
///   widget (`SkinRenderer.draw`), the hatch over what the desktop leaves transparent or cuts off, the ghost of what
///   lies outside the card, the dashed outlines of what is cut off and the pixel grid. The work surface keeps what it
///   drew: only where the widget is — and was — is drawn again (`widgetArea`), unless the zoom, the canvas's size, the
///   card, the backdrop or the appearance changed (`CanvasPlanes.Workbench`), which draw all of it. The work surface
///   thus costs no drawing on an update and no backing store of its own (a full-size plane costs about 13 MB on a large
///   pane at any zoom: design §9.5 gives the Studio 30 MB).
/// - **overlay**: hover and selection outlines, handles, guides, the selection box, tags, badges, editor-only
///   placeholders and the ghost of a component dragged in from Add.
///
/// Pointing at a layer or selecting one draws the overlay only (`SkinCanvasView.overlayNeedsDisplay`); the widget's
/// update (`SkinCanvasView.widgetUpdated`) draws the widget's area of the content, and the overlay only when what it
/// outlines moved; anything else that asks the canvas to draw (`needsDisplay = true`: a step, a preview, a gesture)
/// draws the widget's area and the overlay. The planes draw with the canvas's own drawing code in the order it always
/// drew, and they are plain subviews, so an off-screen picture of the canvas (`cacheDisplay`, the snapshots and the
/// latency frame) composes exactly the pixels one drawing gave. They take no events: clicks, drags, drops and the
/// pointer all go to the canvas. A view the canvas adds later (the in-place text field) lies over both.
final class CanvasPlanes {
    /// What the work surface under the widget shows depends on: when one of these changes, all of it is drawn again.
    struct Workbench: Equatable {
        var zoom: CGFloat
        var size: CGSize
        /// The widget card, view coordinates (nil: no widget).
        var card: CGRect?
        var backdrop: SkinCanvasView.Backdrop
        var dark: Bool
    }

    let content = CanvasPlane(.content)
    let overlay = CanvasPlane(.overlay)
    var all: [CanvasPlane] { [content, overlay] }
    /// What the work surface was last asked to show (recorded when it is asked, so an off-screen picture, which draws
    /// everything, can't make the screen's copy look current).
    private var workbenchShows: Workbench?
    /// Where the widget was when the content plane was last asked to draw it (view coordinates): drawn again with where
    /// it is now, so what it leaves is cleared.
    private var widgetShows: CGRect?
    /// How often the whole work surface was asked to draw (the self-tests).
    private(set) var surfaceAsks = 0
    /// What the overlay plane read from the running widget when it last drew (`SkinCanvasView.overlayInputs`).
    var overlayDrew: OverlayInputs?

    /// What the overlay plane reads from the widget as it runs: where each layer is, whether it shows, and whether a text
    /// is empty (its placeholder) — the outlines, tags, placeholders and cut-off marks follow these — and the zoom, the
    /// card and the visible area the tags are kept in. Anything else it shows changes with a step, a preview, the
    /// pointer or a gesture, which draw it anyway.
    struct OverlayInputs: Equatable {
        struct Layer: Equatable {
            var frame: SkinRect
            var hidden: Bool
            var emptyText: Bool
        }
        var skin: ObjectIdentifier?
        var zoom: CGFloat
        var card: CGRect
        var visible: CGRect
        var layers: [Layer]
    }

    /// Self-tests: the canvas drawn as it was before it had planes — the content plane draws the overlay too, in one
    /// drawing, and the overlay plane is hidden.
    var drawsInOne = false {
        didSet {
            overlay.isHidden = drawsInOne
            content.needsDisplay = true
            workbenchShows = nil
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

    /// Draws the widget's area of the content and the overlay again (all of the content when the work surface changed).
    func invalidate(for canvas: SkinCanvasView) {
        invalidateContent(for: canvas)
        overlay.needsDisplay = true
    }

    /// Asks the content plane to draw the widget again: where it is and where it was — or everything, when the work
    /// surface changed since it was last asked to draw (or the overlay is drawn with it).
    func invalidateContent(for canvas: SkinCanvasView) {
        let now = canvas.workbenchState
        let widget = canvas.widgetArea
        guard now == workbenchShows, !drawsInOne, let before = widgetShows else {
            workbenchShows = now
            widgetShows = widget
            surfaceAsks += 1
            content.needsDisplay = true
            return
        }
        widgetShows = widget
        let area = before.union(widget)
        if !area.isNull, !area.isEmpty { content.setNeedsDisplay(area) }
    }

    /// Draws all of the content again when the work surface changed since it was last asked to (a change the asks
    /// missed: a pinch that ended, a card that grew between two asks), on the next pass.
    func invalidateWorkbenchIfChanged(for canvas: SkinCanvasView) {
        guard canvas.workbenchState != workbenchShows else { return }
        workbenchShows = canvas.workbenchState
        widgetShows = canvas.widgetArea
        surfaceAsks += 1
        content.needsDisplay = true
    }

    /// How often each plane drew (the self-tests).
    var drawCounts: (content: Int, overlay: Int) { (content.drawCount, overlay.drawCount) }
}

/// One plane of the canvas (`CanvasPlanes`): a transparent, flipped view the size of the canvas that draws its part
/// with the canvas's code and takes no events.
final class CanvasPlane: NSView {
    enum Kind: String { case content, overlay }

    let kind: Kind
    weak var canvas: SkinCanvasView?
    /// How often it drew (the self-tests).
    private(set) var drawCount = 0
    /// The rectangle it last drew (the self-tests).
    private(set) var lastDrawn: CGRect = .null

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
        // rectangle, and the dots would never end: then what can be seen. (A finite one stays as it is: the work surface
        // is drawn past the canvas's bounds where the clip view shows more than the canvas.)
        func finite(_ r: CGRect) -> Bool { !r.isNull && r.width < 1e7 && r.height < 1e7 }
        let dirtyRect = finite(dirtyRect) ? dirtyRect : finite(visibleRect) ? bounds.union(visibleRect) : bounds
        lastDrawn = dirtyRect
        guard let canvas, let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch kind {
        case .content:
            // A change of the work surface the asks missed is drawn on the next pass.
            canvas.planes.invalidateWorkbenchIfChanged(for: canvas)
            do {
                let state = StudioSignposts.signposter.beginInterval("canvas.workbench")
                defer { StudioSignposts.signposter.endInterval("canvas.workbench", state) }
                canvas.drawWorkbench(dirtyRect, ctx)
            }
            let state = StudioSignposts.signposter.beginInterval("canvas.paint")
            defer { StudioSignposts.signposter.endInterval("canvas.paint", state) }
            canvas.drawContent(dirtyRect, ctx)
            if canvas.planes.drawsInOne {
                canvas.planes.overlayDrew = canvas.overlayInputs
                canvas.drawOverlayPlane(dirtyRect, ctx)
            }
        case .overlay:
            let state = StudioSignposts.signposter.beginInterval("canvas.overlay")
            defer { StudioSignposts.signposter.endInterval("canvas.overlay", state) }
            canvas.planes.overlayDrew = canvas.overlayInputs
            canvas.drawOverlayPlane(dirtyRect, ctx)
        }
    }
}

extension SkinCanvasView {
    /// What the work surface under the widget shows depends on, now.
    var workbenchState: CanvasPlanes.Workbench {
        CanvasPlanes.Workbench(zoom: zoom, size: bounds.size, card: skinProvider() == nil ? nil : skinRect,
                               backdrop: backdrop,
                               dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// Where the content plane draws the widget over the work surface (view coordinates): the card, and every layer
    /// outside it (the ghost and the cut-off outlines), with room for what a layer draws past its frame (a text's
    /// shadow, a stroke) and for antialiasing — within the canvas.
    var widgetArea: CGRect {
        guard let skin = skinProvider() else { return .null }
        var area = skinRect
        if !skin.meters.isEmpty {
            let b = skin.contentBounds()
            if b.width > 0 || b.height > 0 {
                area = area.union(CGRect(x: b.x + origin.x, y: b.y + origin.y, width: b.width, height: b.height))
            }
        }
        let margin = 8 + 2 / max(zoom, 0.01)
        return area.insetBy(dx: -margin, dy: -margin).intersection(bounds.union(visibleRect))
    }

    /// Draws the overlay again, and only it: the pointer, the selection, the guides or the tags changed, not the widget.
    func overlayNeedsDisplay() {
        planes.overlay.needsDisplay = true
        if planes.drawsInOne { planes.content.needsDisplay = true }
    }

    /// The widget updated (the Studio's canvas timer, at its update rate): the widget's area of the content draws again,
    /// and the overlay only when what it reads from the widget changed since it last drew (a selected layer grew, a
    /// hidden one showed) — an animated widget does not draw its outlines and tags again 30 times a second while
    /// nothing about them moved.
    func widgetUpdated() {
        guard !planes.drawsInOne else {
            needsDisplay = true
            return
        }
        planes.invalidateContent(for: self)
        if planes.overlayDrew != overlayInputs { planes.overlay.needsDisplay = true }
    }

    /// What the overlay reads from the widget now (`CanvasPlanes.OverlayInputs`).
    var overlayInputs: CanvasPlanes.OverlayInputs {
        let skin = skinProvider()
        return CanvasPlanes.OverlayInputs(
            skin: skin.map(ObjectIdentifier.init), zoom: zoom, card: skinRect, visible: visibleRect,
            layers: (skin?.meters ?? []).map { m in
                CanvasPlanes.OverlayInputs.Layer(frame: m.frame, hidden: m.hidden,
                                                 emptyText: (m as? StringMeter)?.text.isEmpty ?? false)
            })
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        planes.fit(self)
    }
}
