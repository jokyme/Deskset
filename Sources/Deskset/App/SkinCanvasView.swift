import AppKit
import DesksetCore

/// The skin editor's canvas: the skin drawn by the real renderer, floating on a dotted work surface inside a
/// magnifying scroll view. Meters are selected by clicking (⇧-click adds or removes, dragging on the empty surface
/// draws a selection box, ⌘A selects all; skin actions never run here), moved by dragging (with smart guides; ⌘
/// disables snapping, ⇧ locks the axis), resized with eight handles (one meter selected) and nudged with the arrow
/// keys (⇧: 10 points). The canvas only reports the frames the user wants; the editor turns them into option values.
/// Components dragged out of the component library can be dropped on it (see "Dropping library components" below).
///
/// Selection works in levels, as in Keynote (docs/editor-friendly.md §9.2): a click on a layer of a run of repeated
/// layers (`groups`, "16 bars") selects the whole run, a double-click enters it and selects that layer, and further
/// clicks stay inside until one lands outside; Esc goes up a level (layer → run → the widget itself). Layers the
/// editor locked (`isLocked`, the widget's Background by default) are skipped by clicks and selection boxes.
///
/// Nothing is silently clipped (§9.10): content outside the widget is drawn ghosted around it, the widget grows live
/// while something is dragged past its right or bottom edge (with a badge saying so), and what goes past its left or
/// top edge — which the desktop cuts off — is hatched and labelled.
///
/// Coordinates: the view is flipped; the skin's (0, 0) is at `origin` (at least `margin` from the view's edges, more
/// when content lies left of or above the widget).
final class SkinCanvasView: NSView {
    enum Backdrop: Int, CaseIterable {
        case checkerboard, dark, light

        var title: String {
            switch self {
            case .checkerboard: return "Transparent"
            case .dark: return "Dark"
            case .light: return "Light"
            }
        }

        var symbol: String {
            switch self {
            case .checkerboard: return "checkerboard.rectangle"
            case .dark: return "moon"
            case .light: return "sun.max"
            }
        }
    }

    /// A resize handle, named by the edges it moves.
    struct Handle: Equatable {
        var left = false, right = false, top = false, bottom = false
        static let all: [Handle] = [
            Handle(left: true, top: true), Handle(top: true), Handle(right: true, top: true), Handle(right: true),
            Handle(right: true, bottom: true), Handle(bottom: true), Handle(left: true, bottom: true), Handle(left: true),
        ]
    }

    /// What the user is doing with the selected meter.
    enum Gesture: Equatable {
        case move
        case resize(Handle)
    }

    /// The least room around the widget (and around anything drawn outside it) on the work surface.
    static let margin: CGFloat = 64
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 16
    /// Zoom from which a 1-point grid is drawn over the skin.
    static let gridZoom: CGFloat = 8
    /// Distance (screen points) within which dragged edges snap to guides.
    static let snapDistance: CGFloat = 5
    /// How strongly content outside the widget is drawn (§9.10: a Keynote-style ghost).
    static let ghostAlpha: CGFloat = 0.35
    /// The veil over the rest of the widget while a layer's row is pointed at in the sidebar (§5.2).
    static let veilAlpha: CGFloat = 0.3
    /// The widget card's least size in the editor while the widget has no layers (room for its starters, §9.8).
    static let emptyCardSize = CGSize(width: 240, height: 150)
    /// How far outside the widget the work surface follows content (a layer parked far away must not shrink the view
    /// of everything else to a dot).
    static let overflowReach: Double = 2000
    /// The starters an empty widget offers (component ids, §9.8).
    static let starters = ["clock", "cpu", "text"]

    /// The skin to draw (the controller may be replaced on refresh, so it is looked up on every draw).
    var skinProvider: () -> Skin? = { nil }
    /// The layer under the pointer (never a locked one).
    private(set) var hover: String?
    /// Selected meters in the order they were selected; the last one is the primary selection.
    private(set) var selectedNames: [String] = []
    var selection: String? { selectedNames.last }
    /// Layers related to the inspector's selection (those showing the selected data source), outlined softly.
    var relatedNames: [String] = [] { didSet { if relatedNames != oldValue { needsDisplay = true } } }
    /// Layers outlined because the pointer is over their row in the sidebar (docs/editor-friendly.md §5.2 "Hover links
    /// the list and the canvas"): the rest of the widget is veiled.
    var hoverHighlight: [String] = [] { didSet { if hoverHighlight != oldValue { needsDisplay = true } } }
    /// The layer under the pointer changed (nil: none), for the sidebar to highlight its row.
    var onHoverChange: ((String?) -> Void)?
    var backdrop = Backdrop.checkerboard { didSet { needsDisplay = true } }
    /// Editing is off while no skin is loaded.
    var isEditable = true

    // MARK: What the editor tells the canvas

    /// Runs of repeated layers (section names, file order), selected as one by a first click (`LayerSeries`).
    var groups: [[String]] = [] { didSet { if groups != oldValue { enteredGroup = nil; needsDisplay = true } } }
    /// The run the user double-clicked into: clicks on its layers select them one by one.
    private(set) var enteredGroup: [String]?
    /// Whether a layer is locked in the editor (§9.6): clicks and selection boxes pass through it.
    var isLocked: (String) -> Bool = { _ in false }
    /// A layer's name in the editor ("Bar 6", "“Audio”"), for the tags.
    var layerName: (String) -> String = { EditorStyle.displayName($0) }
    /// A run's name ("16 bars"), for the tags.
    var groupName: ([String]) -> String = { "\($0.count) layers" }
    /// The layer the editor calls Background (it covers the whole widget, §5.2): new area it does not cover is hatched.
    var backgroundName: String? { didSet { if backgroundName != oldValue { needsDisplay = true } } }
    /// View ▸ Show Content Outside the Widget.
    var showsContentOutside = true {
        didSet {
            guard showsContentOutside != oldValue else { return }
            updateSize()
            needsDisplay = true
        }
    }
    /// Layers placed relative to the ones being moved (follower → the layer it follows), outlined while they move (§9.5).
    var followers: [String: String] = [:] { didSet { if followers != oldValue { needsDisplay = true } } }
    /// The text layer being edited in place: its placeholder is not drawn.
    var editingText: String? { didSet { if editingText != oldValue { needsDisplay = true } } }

    /// Called when the user changes the selection on the canvas (click, ⇧-click, selection box, ⌘A, Esc).
    var onSelectionChange: (([String]) -> Void)?
    /// A double-click on a layer (not the one that enters a run): editing its words in place, for text.
    var onDoubleClick: ((String) -> Void)?
    /// The user entered a run of repeated layers (a double-click or ⌘-click on one of them).
    var onEnterGroup: (([String]) -> Void)?
    /// The menu of a right-click at a point (skin coordinates).
    var onContextMenu: ((Double, Double) -> NSMenu?)?
    /// "Choose what this shows ▾" was clicked on a layer (its rectangle in view coordinates).
    var onChooseData: ((String, NSRect) -> Void)?
    /// An empty widget's starter was clicked (a component id).
    var onStarter: ((String) -> Void)?
    /// Called when the zoom changes (for the zoom label).
    var onZoom: ((CGFloat) -> Void)?
    /// Called when the user zooms with the keyboard, the scroll wheel or a pinch (ends automatic fitting).
    var onUserZoom: (() -> Void)?
    /// A drag or resize started on the selected meters (their frames at that moment are the reference).
    var onBeginGesture: (([String], Gesture) -> Void)?
    /// The frames the user wants for the meters now (skin coordinates, whole points).
    var onGestureFrames: (([String: SkinRect]) -> Void)?
    /// The gesture ended: true to keep the result, false when cancelled (Escape) or nothing moved.
    var onEndGesture: ((Bool) -> Void)?
    /// Arrow keys: move the selection by (dx, dy) points.
    var onNudge: ((Double, Double) -> Void)?
    /// Delete / Backspace, ⌘D.
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    /// The view's size or `origin` changed (the overlays over the canvas follow).
    var onLayoutChange: (() -> Void)?
    /// A library component was dropped: its id and the frame it should get (skin coordinates, whole points). The
    /// editor inserts it there.
    var onDropComponent: ((String, SkinRect) -> Void)?
    /// The library component being dragged over the canvas and where it would land (see `componentDragMoved`).
    private(set) var componentGhost: (id: String, frame: SkinRect)?
    /// The drag (its `draggingSequenceNumber`) whose own image is hidden while the ghost stands in for it.
    private var dragImageHiddenFor: Int?

    /// Where the skin's (0, 0) is in view coordinates.
    private(set) var origin = NSPoint(x: margin, y: margin)

    private var trackingArea: NSTrackingArea?
    private(set) var gesture: Gesture?
    private var gestureStart: NSPoint = .zero
    private var gestureFrames: [String: SkinRect] = [:]
    private(set) var gestureMoved = false
    /// The widget's size when the gesture started (the growth badge compares with it).
    private var gestureStartSize: CGSize?
    /// The selection box being dragged (view coordinates) and the selection it started from (⇧ adds to it).
    private(set) var marquee: CGRect?
    private var marqueeBase: [String] = []
    /// A press on a member of a multiple selection: becomes "select only this" if the mouse goes up without a drag.
    private var clickedInGroup: String?
    private(set) var guides: [EditorSnapping.Guide] = []
    /// Where the last drawing put the drag's badges and the name tags (view coordinates): tags keep off the badges.
    private(set) var badgeRects: [CGRect] = []
    private(set) var drawnTagRects: [CGRect] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.desksetComponent])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var skin: Skin? { skinProvider() }

    var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// The size the widget has on the desktop — while a layer, or a component from Add, is dragged past its right or
    /// bottom edge, the size it grows to (§9.10) — and at least `emptyCardSize` while it has no layers.
    var cardSize: CGSize {
        guard let skin else { return .zero }
        var width = skin.width, height = skin.height
        if gesture != nil, gestureMoved {
            let grown = skin.size(for: skin.contentBounds())
            width = max(width, grown.width)
            height = max(height, grown.height)
        }
        if let ghost = componentGhost?.frame {
            // The component is not in the skin yet: the widget as it will be once it is dropped there.
            let content = skin.contentBounds()
            let grown = skin.size(for: SkinRect(x: 0, y: 0, width: max(content.maxX, ghost.maxX),
                                                height: max(content.maxY, ghost.maxY)))
            width = max(width, grown.width)
            height = max(height, grown.height)
        }
        if skin.meters.isEmpty {
            width = max(width, Double(Self.emptyCardSize.width))
            height = max(height, Double(Self.emptyCardSize.height))
        }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    /// Skin rectangle (the widget card) in view coordinates.
    var skinRect: CGRect {
        guard skin != nil else { return .zero }
        return CGRect(origin: origin, size: cardSize)
    }

    /// Everything the canvas shows in skin coordinates: the widget card and, with Show Content Outside the Widget,
    /// the content around it (within `overflowReach`).
    private var extent: CGRect {
        let card = cardSize
        var r = CGRect(origin: .zero, size: card)
        if showsContentOutside, let skin, !skin.meters.isEmpty {
            let b = skin.contentBounds()
            let reach = Self.overflowReach
            let minX = max(b.x, -reach), minY = max(b.y, -reach)
            let maxX = min(b.maxX, Double(card.width) + reach), maxY = min(b.maxY, Double(card.height) + reach)
            r = r.union(CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0)))
        }
        return r
    }

    /// Resizes the view to the widget plus margins and whatever is drawn outside it (call after the skin loads or
    /// changes size). `origin` follows content left of or above the widget, except during a gesture (so nothing
    /// jumps under the pointer); when it moves, the visible area moves with it.
    func updateSize() {
        let e = extent
        let old = origin
        if gesture == nil {
            origin = NSPoint(x: Self.margin - min(e.minX, 0), y: Self.margin - min(e.minY, 0))
        }
        let size = NSSize(width: ceil(origin.x + max(e.maxX, 1) + Self.margin),
                          height: ceil(origin.y + max(e.maxY, 1) + Self.margin))
        let resized = frame.size != size
        if resized { setFrameSize(size) }
        if origin != old, let clip = enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: clip.bounds.minX + origin.x - old.x, y: clip.bounds.minY + origin.y - old.y))
            enclosingScrollView?.reflectScrolledClipView(clip)
            needsDisplay = true
        }
        if resized || origin != old { onLayoutChange?() }
    }

    // MARK: Selection

    func setSelection(_ name: String?, reveal: Bool = false) {
        setSelection(names: name.map { [$0] } ?? [], reveal: reveal)
    }

    func setSelection(names: [String], reveal: Bool = false) {
        leaveGroupUnlessInside(names)
        guard names != selectedNames else { return }
        selectedNames = names
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if reveal, let name = names.last, let skin, let m = skin.meter(named: name) {
            scrollToVisible(viewRect(m.frame).insetBy(dx: -24, dy: -24))
        }
    }

    private func changeSelection(_ names: [String]) {
        guard names != selectedNames else { return }
        setSelection(names: names)
        onSelectionChange?(names)
    }

    /// The entered run stays entered while the selection is one of its layers.
    private func leaveGroupUnlessInside(_ names: [String]) {
        guard let g = enteredGroup else { return }
        if names.count != 1 || !Self.contains(g, names[0]) { enteredGroup = nil }
    }

    private static func contains(_ names: [String], _ name: String) -> Bool {
        names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The run of repeated layers `name` belongs to (nil: none).
    func group(of name: String) -> [String]? {
        groups.first { Self.contains($0, name) }
    }

    /// Whether the selection is exactly one run of repeated layers.
    var selectedGroup: [String]? {
        guard selectedNames.count > 1, let g = group(of: selectedNames[0]),
              Set(g.map { $0.lowercased() }) == Set(selectedNames.map { $0.lowercased() }) else { return nil }
        return g
    }

    /// What a click on `name` selects: its run while the run is not entered (⌘ picks the layer itself), else the
    /// layer.
    func clickTarget(_ name: String, command: Bool = false) -> [String] {
        guard !command, let g = group(of: name), enteredGroup != g else { return [name] }
        return g
    }

    private func setHover(_ name: String?) {
        guard name != hover else { return }
        hover = name
        needsDisplay = true
        onHoverChange?(name)
    }

    /// The pointer over a layer (nil: over none), as a mouse move would report it (snapshots and self-tests).
    func simulateHover(_ name: String?) {
        setHover(name.flatMap { n in skin?.meter(named: n)?.name })
    }

    /// The topmost unlocked meter drawn at a point in skin coordinates (an empty text counts where its placeholder is).
    func pickableMeter(atSkinX x: Double, _ y: Double) -> Meter? {
        guard let skin else { return nil }
        return skin.meters.last { m in
            guard !m.isContainer, !isLocked(m.name) else { return false }
            if m.frame.width > 0, m.frame.height > 0, m.isHit(x: x, y: y) { return true }
            return placeholderRect(m).map { $0.contains(x: x, y: y) } ?? false
        }
    }

    /// The meter a click at a point in view coordinates picks.
    func meter(atViewPoint p: NSPoint) -> Meter? {
        pickableMeter(atSkinX: Double(p.x - origin.x), Double(p.y - origin.y))
    }

    /// Every layer drawn at a point in skin coordinates, front first — locked ones too (right-click ▸ Select ▸).
    func layers(atSkinX x: Double, _ y: Double) -> [String] {
        guard let skin else { return [] }
        return skin.meters.reversed().filter { m in
            !m.isContainer && !m.hidden && m.frame.width > 0 && m.frame.height > 0 && m.frame.contains(x: x, y: y)
        }.map(\.name)
    }

    /// Picks the meter at a point in skin coordinates, as a click there would (⇧: add / remove; ⌘: the layer itself,
    /// entering its run).
    func pick(skinX x: Double, y: Double, extend: Bool = false, command: Bool = false) {
        let name = pickableMeter(atSkinX: x, y)?.name
        if extend {
            guard let name else { return }
            changeSelection(selectedNames.contains(name) ? selectedNames.filter { $0 != name } : selectedNames + [name])
            return
        }
        guard let name else {
            enteredGroup = nil
            return changeSelection([])
        }
        if command, let g = group(of: name) {
            enteredGroup = g
            changeSelection([name])
            onEnterGroup?(g)
            return
        }
        if selectedNames.contains(name), selectedNames.count > 1 {
            // Clicking inside a multiple selection (or a selected run) keeps it (to drag it).
            return
        }
        let target = clickTarget(name)
        if target == selectedNames {
            if target.count == 1 { onSelectionChange?(selectedNames) }
        } else {
            changeSelection(target)
        }
    }

    /// A complete click (press and release without dragging) at a point in skin coordinates.
    func click(skinX x: Double, y: Double, extend: Bool = false, command: Bool = false) {
        pick(skinX: x, y: y, extend: extend, command: command)
        if !extend, !command, let name = pickableMeter(atSkinX: x, y)?.name, selectedNames.count > 1,
           selectedNames.contains(name) {
            let target = clickTarget(name)
            if target != selectedNames { changeSelection(target) }
        }
    }

    /// A double-click at a point in skin coordinates: enters the run of the layer there (selecting that layer), or
    /// reports the layer (`onDoubleClick`: text is edited in place).
    func doubleClick(skinX x: Double, y: Double) {
        guard let m = pickableMeter(atSkinX: x, y) else { return }
        if let g = group(of: m.name), enteredGroup != g {
            enteredGroup = g
            changeSelection([m.name])
            onEnterGroup?(g)
            return
        }
        if selectedNames != [m.name] { changeSelection([m.name]) }
        onDoubleClick?(m.name)
    }

    /// Esc: one level up — a layer of a run to the run, anything else to the widget itself (nothing selected).
    func selectLevelUp() {
        guard !selectedNames.isEmpty else { return }
        if selectedNames.count == 1, let g = group(of: selectedNames[0]) {
            enteredGroup = nil
            changeSelection(g)
        } else {
            enteredGroup = nil
            changeSelection([])
        }
    }

    /// Selects every visible meter (⌘A), locked ones included.
    func selectAll() {
        guard let skin else { return }
        enteredGroup = nil
        changeSelection(skin.meters.filter { !$0.isContainer && $0.frame.width > 0 && $0.frame.height > 0 }.map(\.name))
    }

    /// The single selected meter (handles and the size label only appear for one).
    private var selectedMeter: Meter? {
        selectedNames.count == 1 ? selectedNames.last.flatMap { skin?.meter(named: $0) } : nil
    }

    private var selectedMeters: [Meter] { selectedNames.compactMap { skin?.meter(named: $0) } }

    /// A skin rectangle in view coordinates (at least 2 points wide and high, so a line stays visible).
    func viewRect(_ f: SkinRect) -> CGRect {
        let r = CGRect(x: f.x + origin.x, y: f.y + origin.y, width: f.width, height: f.height)
        return r.width > 0 && r.height > 0 ? r : r.insetBy(dx: -2, dy: -2)
    }

    // MARK: Zoom

    func setZoom(_ value: CGFloat, centeredAt point: NSPoint? = nil) {
        guard let scroll = enclosingScrollView else { return }
        let z = min(max(value, Self.minZoom), Self.maxZoom)
        let center = point ?? NSPoint(x: visibleRect.midX, y: visibleRect.midY)
        scroll.setMagnification(z, centeredAt: center)
        onZoom?(scroll.magnification)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Steps through `steps` (25% … 1600%).
    func zoomIn() { setZoom(Self.steps.first { $0 > zoom + 0.001 } ?? Self.maxZoom) }
    func zoomOut() { setZoom(Self.steps.last { $0 < zoom - 0.001 } ?? Self.minZoom) }
    static let steps: [CGFloat] = [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16]

    /// Largest zoom (at most `limit`) that shows the whole widget — and what is drawn ghosted outside it — in the
    /// visible area.
    func fitZoom(limit: CGFloat = 4) -> CGFloat {
        guard let scroll = enclosingScrollView else { return 1 }
        let available = scroll.contentSize
        let e = extent
        let needed = NSSize(width: e.width + 2 * Self.margin, height: e.height + 2 * Self.margin)
        guard needed.width > 0, needed.height > 0 else { return 1 }
        let z = min(available.width / needed.width, available.height / needed.height, limit)
        return min(max(z, Self.minZoom), Self.maxZoom)
    }

    func zoomToFit() { setZoom(fitZoom(), centeredAt: NSPoint(x: bounds.midX, y: bounds.midY)) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad]) == .command,
              window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "a": selectAll()
        case "d": onDuplicate?()
        case "=", "+": onUserZoom?(); zoomIn()
        case "-": onUserZoom?(); zoomOut()
        case "0": onUserZoom?(); setZoom(1)
        case "9": zoomToFit()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌥-scroll zooms around the pointer (pinching works through the scroll view).
        guard event.modifierFlags.contains(.option) else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        onUserZoom?()
        setZoom(zoom * (1 + delta), centeredAt: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onUserZoom?()
        onZoom?(zoom)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard isEditable, !selectedNames.isEmpty, let key = event.specialKey else { return super.keyDown(with: event) }
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch key {
        case .leftArrow: onNudge?(-step, 0)
        case .rightArrow: onNudge?(step, 0)
        case .upArrow: onNudge?(0, -step)
        case .downArrow: onNudge?(0, step)
        case .delete, .deleteForward, .backspace: onDelete?()
        default: super.keyDown(with: event)
        }
    }

    /// Esc: cancels a gesture, else goes one selection level up (`selectLevelUp`).
    override func cancelOperation(_ sender: Any?) {
        if gesture != nil { endGesture(keep: false) } else { selectLevelUp() }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Handle rectangles (view coordinates) of the selected meter, in screen-constant size.
    private func handleRects() -> [(Handle, CGRect)] {
        guard let m = selectedMeter, isEditable else { return [] }
        let r = viewRect(m.frame)
        let size = 8 / zoom
        return Handle.all.map { h in
            let x = h.left ? r.minX : h.right ? r.maxX : r.midX
            let y = h.top ? r.minY : h.bottom ? r.maxY : r.midY
            return (h, CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
        }
    }

    override func resetCursorRects() {
        for (h, r) in handleRects() {
            addCursorRect(r.insetBy(dx: -2 / zoom, dy: -2 / zoom), cursor: Self.cursor(for: h))
        }
    }

    private static func cursor(for h: Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (h.left, h.right, h.top, h.bottom) {
            case (true, _, true, _): position = .topLeft
            case (_, true, true, _): position = .topRight
            case (true, _, _, true): position = .bottomLeft
            case (_, true, _, true): position = .bottomRight
            case (true, _, _, _): position = .left
            case (_, true, _, _): position = .right
            case (_, _, true, _): position = .top
            default: position = .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if (h.left || h.right) && !(h.top || h.bottom) { return .resizeLeftRight }
        if (h.top || h.bottom) && !(h.left || h.right) { return .resizeUpDown }
        return .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        // Editor-only chips and buttons drawn on the widget come first.
        if isEditable, let (name, rect) = chooseDataChips().first(where: { $0.1.contains(p) }) {
            onChooseData?(name, rect)
            return
        }
        if isEditable, let (id, _) = starterRects().first(where: { $0.1.contains(p) }) {
            onStarter?(id)
            return
        }
        if let (handle, _) = handleRects().first(where: { $0.1.insetBy(dx: -2 / zoom, dy: -2 / zoom).contains(p) }),
           selectedMeter != nil {
            beginGesture(.resize(handle), at: p)
            return
        }
        let shift = event.modifierFlags.contains(.shift), command = event.modifierFlags.contains(.command)
        let hit = meter(atViewPoint: p)
        let skinPoint = (x: Double(p.x - origin.x), y: Double(p.y - origin.y))
        if event.clickCount == 2, !shift, hit != nil {
            doubleClick(skinX: skinPoint.x, y: skinPoint.y)
            if let hit, isEditable, selectedNames.contains(hit.name), editingText == nil { beginGesture(.move, at: p) }
            return
        }
        clickedInGroup = !shift && selectedNames.count > 1 ? hit.flatMap { selectedNames.contains($0.name) ? $0.name : nil } : nil
        pick(skinX: skinPoint.x, y: skinPoint.y, extend: shift, command: command)
        if let hit, isEditable, selectedNames.contains(hit.name) {
            beginGesture(.move, at: p)
        } else if hit == nil {
            marquee = CGRect(origin: p, size: .zero)
            marqueeBase = shift ? selectedNames : []
            gestureStart = p
        }
    }

    /// Starts a gesture on the selected meters as a press at `p` would (also used by the self-tests).
    func beginGesture(_ g: Gesture, at p: NSPoint) {
        let meters = selectedMeters
        guard !meters.isEmpty else { return }
        if case .resize = g, meters.count != 1 { return }
        gesture = g
        gestureStart = p
        gestureFrames = Dictionary(uniqueKeysWithValues: meters.map { ($0.name, $0.frame) })
        gestureMoved = false
        gestureStartSize = skin.map { CGSize(width: $0.width, height: $0.height) }
        onBeginGesture?(meters.map(\.name), g)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if marquee != nil { return dragMarquee(to: p) }
        drag(to: p, shift: event.modifierFlags.contains(.shift), snapping: !event.modifierFlags.contains(.command))
    }

    /// The selection box follows the pointer; meters it touches are selected (locked ones are not).
    func dragMarquee(to p: NSPoint) {
        guard let skin else { return }
        let r = CGRect(x: min(p.x, gestureStart.x), y: min(p.y, gestureStart.y),
                       width: abs(p.x - gestureStart.x), height: abs(p.y - gestureStart.y))
        marquee = r
        let hits = skin.meters.filter { m in
            !m.isContainer && !m.hidden && !isLocked(m.name) && m.frame.width > 0 && m.frame.height > 0
                && viewRect(m.frame).intersects(r)
        }.map(\.name)
        enteredGroup = nil
        changeSelection(marqueeBase + hits.filter { !marqueeBase.contains($0) })
        needsDisplay = true
    }

    /// The gesture's pointer moved to `p` (view coordinates). Also used by the self-tests.
    func drag(to p: NSPoint, shift: Bool = false, snapping: Bool = true) {
        guard let g = gesture, let skin, !gestureFrames.isEmpty else { return }
        var dx = Double(p.x - gestureStart.x), dy = Double(p.y - gestureStart.y)
        if !gestureMoved && hypot(dx, dy) * Double(zoom) < 3 { return }
        gestureMoved = true
        // A group moves as its bounding box.
        let frames = Array(gestureFrames.values)
        let minX = frames.map(\.x).min()!, minY = frames.map(\.y).min()!
        let f = SkinRect(x: minX, y: minY, width: frames.map { $0.x + $0.width }.max()! - minX,
                         height: frames.map { $0.y + $0.height }.max()! - minY)
        var target = f
        switch g {
        case .move:
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            target.x = (f.x + dx).rounded()
            target.y = (f.y + dy).rounded()
        case .resize(let h):
            var minX = f.x, maxX = f.x + f.width, minY = f.y, maxY = f.y + f.height
            if h.left { minX = min((f.x + dx).rounded(), maxX - 1) }
            if h.right { maxX = max((maxX + dx).rounded(), minX + 1) }
            if h.top { minY = min((f.y + dy).rounded(), maxY - 1) }
            if h.bottom { maxY = max((maxY + dy).rounded(), minY + 1) }
            target = SkinRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        guides = []
        if snapping {
            let others = skin.meters.filter { !selectedNames.contains($0.name) && !$0.hidden && !$0.isContainer
                && $0.frame.width > 0 && $0.frame.height > 0 }.map(\.frame)
            let bounds = SkinRect(x: 0, y: 0, width: skin.width, height: skin.height)
            let snap = EditorSnapping.snap(target, to: others + [bounds], threshold: Double(Self.snapDistance / zoom))
            switch g {
            case .move:
                target.x += snap.dx
                target.y += snap.dy
                guides = snap.guides
            case .resize(let h):
                // Only the edges being dragged snap.
                for guide in snap.guides {
                    if guide.axis == .vertical, h.left || h.right {
                        if h.left { target.width -= snap.dx; target.x += snap.dx } else { target.width += snap.dx }
                        guides.append(guide)
                    }
                    if guide.axis == .horizontal, h.top || h.bottom {
                        if h.top { target.height -= snap.dy; target.y += snap.dy } else { target.height += snap.dy }
                        guides.append(guide)
                    }
                }
                target.width = max(target.width, 1)
                target.height = max(target.height, 1)
            }
        }
        if case .resize = g, let name = gestureFrames.keys.first {
            onGestureFrames?([name: target])
        } else {
            let mx = target.x - f.x, my = target.y - f.y
            onGestureFrames?(gestureFrames.mapValues { SkinRect(x: $0.x + mx, y: $0.y + my, width: $0.width, height: $0.height) })
        }
        // The widget grows live past its right and bottom edges (the canvas holding still on screen meanwhile).
        holdsPositionOnScreen = true
        updateSize()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if marquee != nil {
            marquee = nil
            needsDisplay = true
            return
        }
        guard gesture != nil else { return }
        let moved = gestureMoved
        endGesture(keep: moved)
        if !moved, let name = clickedInGroup {
            let target = clickTarget(name)
            if target != selectedNames { changeSelection(target) }
        }
        clickedInGroup = nil
    }

    /// Ends the gesture (also used by the self-tests).
    func endGesture(keep: Bool) {
        gesture = nil
        gestureMoved = false
        gestureStartSize = nil
        guides = []
        onEndGesture?(keep)
        updateSize()
        holdsPositionOnScreen = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// While a drag grows the canvas, the canvas stays where it is on screen: re-centring it in a larger visible area
    /// would slide the widget — and the drop spot — away under a pointer that has not moved. It centres again when
    /// the drag ends.
    private var holdsPositionOnScreen: Bool {
        get { (enclosingScrollView?.contentView as? CenteringClipView)?.holdsDocument ?? false }
        set { (enclosingScrollView?.contentView as? CenteringClipView)?.holdsDocument = newValue }
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(meter(atViewPoint: convert(event.locationInWindow, from: nil))?.name)
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return onContextMenu?(Double(p.x - origin.x), Double(p.y - origin.y))
    }

    // MARK: What the canvas shows about the gesture

    /// The widget's size before the drag that may grow it: a layer being moved or resized, or a component from Add
    /// being dragged over the canvas (nil: neither). An empty widget has no size to grow from.
    var growthStartSize: CGSize? {
        if gesture != nil, gestureMoved { return gestureStartSize }
        if componentGhost != nil, let skin, !skin.meters.isEmpty { return CGSize(width: skin.width, height: skin.height) }
        return nil
    }

    /// The widget's size now and the size it grows to while something is dragged past its right or bottom edge:
    /// "217 × 196 → 240 × 196" (nil when it does not grow).
    var growthBadge: String? {
        guard let start = growthStartSize else { return nil }
        let now = cardSize
        guard now.width > start.width + 0.5 || now.height > start.height + 0.5 else { return nil }
        return "\(Self.size(start)) → \(Self.size(now))"
    }

    /// Whether a layer being dragged — or a component from Add — is past the widget's left or top edge, or outside a
    /// fixed size, which the desktop cuts off ("Cut off on the desktop").
    var isDraggingPastEdge: Bool {
        guard let skin else { return false }
        let fixed = (w: skin.settings.skinWidth, h: skin.settings.skinHeight)
        func cut(_ f: SkinRect) -> Bool {
            f.x < 0 || f.y < 0 || (fixed.w.map { f.maxX > $0 } ?? false) || (fixed.h.map { f.maxY > $0 } ?? false)
        }
        if let ghost = componentGhost?.frame, cut(ghost) { return true }
        guard gesture != nil, gestureMoved else { return false }
        return gestureFrames.keys.contains { name in skin.meter(named: name).map { cut($0.frame) } ?? false }
    }

    static func size(_ s: CGSize) -> String { "\(format(Double(s.width))) × \(format(Double(s.height)))" }

    // MARK: Editor-only placeholders

    /// A text layer showing no words at all (its written Text is empty and nothing fills it): "Double-click to type"
    /// is drawn where its words would be, in skin coordinates.
    func placeholderRect(_ m: Meter) -> SkinRect? {
        guard let s = m as? StringMeter, !m.hidden, m.container == nil, s.text.isEmpty,
              (m.rawOption("Text") ?? "").trimmingCharacters(in: .whitespaces).isEmpty, m.measures.isEmpty
        else { return nil }
        let size = max(s.style.fontSize, 6) * 1.33
        let width = Double(Self.placeholderText.size(withAttributes: [.font: NSFont.systemFont(ofSize: CGFloat(size))]).width)
        var x = m.frame.x
        switch s.style.horizontalAlign {
        case .center: x -= width / 2
        case .right: x -= width
        default: break
        }
        return SkinRect(x: x, y: m.frame.y, width: width, height: size * 1.25)
    }

    static let placeholderText = "Double-click to type"
    static let chooseDataText = "Choose what this shows ▾"

    /// Bars, graphs and gauges that show no live data yet: their "Choose what this shows ▾" chip (view coordinates).
    func chooseDataChips() -> [(String, CGRect)] {
        guard let skin, isEditable else { return [] }
        let kinds: Set<String> = ["bar", "line", "histogram", "roundline", "rotator"]
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let size = pillSize(Self.chooseDataText, font: font, height: 22)
        var centres: Set<String> = []
        return skin.meters.compactMap { m in
            // A gauge drawn as a fixed shape (a clock's face, rim and ticks) isn't waiting for data.
            guard kinds.contains(m.type.lowercased()), !m.hidden, m.measures.isEmpty,
                  (m.rawOption("MeasureName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                  !LayerNaming.drawsWithoutData(m), m.frame.width > 0, m.frame.height > 0 else { return nil }
            let r = viewRect(m.frame)
            // One chip per place: gauges around one centre would stack theirs.
            guard centres.insert("\(Int(r.midX.rounded())),\(Int(r.midY.rounded()))").inserted else { return nil }
            let w = size.width / zoom, h = size.height / zoom
            return (m.name, CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        }
    }

    /// The starters an empty widget offers, as buttons (view coordinates).
    func starterRects() -> [(String, CGRect)] {
        guard let skin, skin.meters.isEmpty, isEditable else { return [] }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titles = Self.starters.map { EditorComponents.component($0)?.title ?? $0 }
        let sizes = titles.map { pillSize($0, font: font, height: 26, padding: 12) }
        let gap: CGFloat = 8
        let total = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(sizes.count - 1, 0))
        let card = skinRect
        var x = card.midX - total / 2 / zoom
        let y = card.midY + 14 / zoom
        var result: [(String, CGRect)] = []
        for (id, size) in zip(Self.starters, sizes) {
            result.append((id, CGRect(x: x, y: y, width: size.width / zoom, height: size.height / zoom)))
            x += (size.width + gap) / zoom
        }
        return result
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let z = max(zoom, 0.01)
        drawSurface(dirtyRect, zoom: z, ctx)
        guard let skin else { return }
        let rect = skinRect

        drawBackdrop(rect, zoom: z, ctx)
        // The hatch marks areas the desktop shows transparent or cuts off; the layers are drawn over it.
        drawHatch(skin, card: rect, zoom: z, ctx)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: origin.x, y: origin.y)
        SkinRenderer.draw(skin, in: ctx)
        ctx.restoreGState()
        drawOutside(skin, card: rect, ctx)
        drawCutOffOutlines(skin, card: rect, zoom: z, ctx)
        if z >= Self.gridZoom { drawGrid(rect, dirty: dirtyRect, zoom: z, ctx) }
        // The badges are placed first (off the layers being dragged), the tags then keep off them, and the badges are
        // drawn last, over everything: "Cut off on the desktop" stays readable when it matters most.
        let badges = badgePlacements(zoom: z)
        badgeRects = badges.map(\.rect)
        drawnTagRects = []
        drawOverlay(skin, zoom: z, ctx)
        drawComponentGhost(zoom: z, ctx)
        drawBadges(badges, zoom: z, ctx)
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The work surface: a quiet tone with a fine dot pattern at a constant on-screen spacing.
    private func drawSurface(_ dirty: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        ctx.setFillColor(isDark ? CGColor(red: 0.105, green: 0.105, blue: 0.115, alpha: 1)
                                : CGColor(red: 0.953, green: 0.949, blue: 0.941, alpha: 1))
        ctx.fill(dirty)
        let spacing = 18 / zoom, radius = 0.9 / zoom
        ctx.setFillColor(isDark ? CGColor(gray: 1, alpha: 0.07) : CGColor(gray: 0, alpha: 0.09))
        var y = (dirty.minY / spacing).rounded(.down) * spacing
        while y <= dirty.maxY {
            var x = (dirty.minX / spacing).rounded(.down) * spacing
            while x <= dirty.maxX {
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
                x += spacing
            }
            y += spacing
        }
    }

    private func drawBackdrop(_ rect: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        // A soft shadow lifts the skin off the surface, like a card on a desk.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8 / zoom), blur: 28 / zoom,
                      color: CGColor(gray: 0, alpha: isDark ? 0.55 : 0.18))
        ctx.setFillColor(CGColor(gray: isDark ? 0.16 : 1, alpha: 1))
        ctx.fill(rect)
        ctx.restoreGState()

        switch backdrop {
        case .dark:
            ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1))
            ctx.fill(rect)
        case .light:
            ctx.setFillColor(CGColor(red: 0.98, green: 0.975, blue: 0.965, alpha: 1))
            ctx.fill(rect)
        case .checkerboard:
            let a = CGColor(gray: isDark ? 0.19 : 1, alpha: 1), b = CGColor(gray: isDark ? 0.235 : 0.925, alpha: 1)
            ctx.setFillColor(a)
            ctx.fill(rect)
            let size = 8 / zoom
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.setFillColor(b)
            var row = 0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX + (row % 2 == 0 ? 0 : size)
                while x < rect.maxX {
                    ctx.fill(CGRect(x: x, y: y, width: size, height: size))
                    x += 2 * size
                }
                y += size
                row += 1
            }
            ctx.restoreGState()
        }
    }

    /// Whether content lies outside the widget card (skin coordinates).
    private func hasContentOutside(_ skin: Skin, card: CGSize) -> Bool {
        guard !skin.meters.isEmpty else { return false }
        let b = skin.contentBounds()
        return b.x < 0 || b.y < 0 || b.maxX > Double(card.width) || b.maxY > Double(card.height)
    }

    /// The ghost (§9.10): everything outside the widget at `ghostAlpha`, in one transparency layer clipped to the
    /// outside of the card (even-odd), so the card's edge stays crisp.
    private func drawOutside(_ skin: Skin, card: CGRect, _ ctx: CGContext) {
        guard showsContentOutside, hasContentOutside(skin, card: card.size) else { return }
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addRect(card)
        ctx.clip(using: .evenOdd)
        ctx.setAlpha(Self.ghostAlpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.translateBy(x: origin.x, y: origin.y)
        SkinRenderer.draw(skin, in: ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The ground the parts of layers outside the card are drawn on, under their 35% ghost (§9.10): the widget's own
    /// panel (its Background's fill or its whole-widget background), so its content keeps the contrast it has inside —
    /// white words of a dark widget don't vanish on the light work surface; a see-through widget gets a dark or light
    /// neutral, whichever its content stands out on.
    func outsideGround(_ skin: Skin) -> CGColor {
        if let panel = LayerThumbnails.ownPanelColor(of: skin, background: backgroundName), panel.a >= 128 {
            let a = panel.a / 255, grey = 0.5 * (1 - a)
            return CGColor(srgbRed: panel.r / 255 * a + grey, green: panel.g / 255 * a + grey, blue: panel.b / 255 * a + grey,
                           alpha: 1)
        }
        return LayerThumbnails.contentIsLight(skin, except: backgroundName) ? CGColor(gray: 0.2, alpha: 1)
                                                                              : CGColor(gray: 0.93, alpha: 1)
    }

    /// A checkerboard in mid greys over new area the widget grew by: still "transparent on the desktop", but light and
    /// dark content both show on it (on the white checkerboard, white words were invisible).
    private func fillGrownArea(_ regions: [CGRect], zoom: CGFloat, _ ctx: CGContext) {
        guard backdrop == .checkerboard, !regions.isEmpty else { return }
        ctx.saveGState()
        ctx.addRects(regions)
        ctx.clip()
        let area = regions.reduce(CGRect.null) { $0.union($1) }
        ctx.setFillColor(CGColor(gray: 0.54, alpha: 1))
        ctx.fill(area)
        ctx.setFillColor(CGColor(gray: 0.46, alpha: 1))
        let size = 8 / zoom
        var row = 0
        var y = skinRect.minY + ((area.minY - skinRect.minY) / size).rounded(.down) * size
        while y < area.maxY {
            let shift = Int(((y - skinRect.minY) / size).rounded()) % 2 == 0 ? 0 : size
            var x = skinRect.minX + ((area.minX - skinRect.minX) / (2 * size)).rounded(.down) * 2 * size + shift
            while x < area.maxX {
                ctx.fill(CGRect(x: x, y: y, width: size, height: size))
                x += 2 * size
            }
            y += size
            row += 1
        }
        ctx.restoreGState()
    }

    /// Faint diagonal lines over what will be transparent or cut off on the desktop: new area the Background does not
    /// cover (while the widget grows, and afterwards), on a mid-grey checkerboard, and the parts of layers past the
    /// edges, on the widget's panel color (`outsideGround`) under their ghost.
    private func drawHatch(_ skin: Skin, card: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        var regions: [CGRect] = []
        if let name = backgroundName, let bg = skin.meter(named: name), !bg.hidden {
            // The strips of the widget right of and below its Background: new area a drag or an addition made.
            let b = viewRect(bg.frame)
            if card.maxX - b.maxX > 1 {
                regions.append(CGRect(x: max(b.maxX, card.minX), y: card.minY, width: card.maxX - max(b.maxX, card.minX),
                                      height: card.height))
            }
            if card.maxY - b.maxY > 1 {
                let right = min(max(b.maxX, card.minX), card.maxX)
                regions.append(CGRect(x: card.minX, y: max(b.maxY, card.minY), width: right - card.minX,
                                      height: card.maxY - max(b.maxY, card.minY)))
            }
        } else if let start = growthStartSize {
            let old = CGRect(origin: origin, size: start)
            regions += Self.subtract(old, from: card)
        }
        let grown = regions.filter { $0.width > 0.01 && $0.height > 0.01 }
        fillGrownArea(grown, zoom: zoom, ctx)
        let outside = cutOffLayers(skin, card: card).flatMap { Self.subtract(card, from: viewRect($0.frame)) }
            .filter { $0.width > 0.01 && $0.height > 0.01 }
        let ground = outsideGround(skin)
        if showsContentOutside, !outside.isEmpty {
            ctx.saveGState()
            ctx.setFillColor(ground)
            ctx.fill(outside)
            ctx.restoreGState()
        }
        // Darker lines on the grey checkerboard and on a light ground, lighter on a dark one; without the ground, lines
        // that suit the work surface.
        strokeHatch(grown, color: CGColor(gray: 0, alpha: 0.14), zoom: zoom, ctx)
        let outsideLines = !showsContentOutside ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : Self.luminance(ground) > 0.5 ? CGColor(gray: 0, alpha: 0.12) : CGColor(gray: 1, alpha: 0.16)
        strokeHatch(outside, color: outsideLines, zoom: zoom, ctx)
    }

    /// Relative luminance of a colour (Rec. 709 weights on its sRGB components).
    static func luminance(_ color: CGColor) -> CGFloat {
        guard let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
            .components, c.count >= 3 else { return color.components?.first ?? 1 }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    private func strokeHatch(_ regions: [CGRect], color: CGColor, zoom: CGFloat, _ ctx: CGContext) {
        guard !regions.isEmpty else { return }
        ctx.saveGState()
        ctx.addRects(regions)
        ctx.clip()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1 / zoom)
        let spacing = 6 / zoom
        let area = regions.reduce(CGRect.null) { $0.union($1) }
        var x = area.minX - area.height
        while x < area.maxX {
            ctx.move(to: CGPoint(x: x, y: area.maxY))
            ctx.addLine(to: CGPoint(x: x + area.height, y: area.minY))
            x += spacing
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The layers partly or wholly outside the card (`card`, view coordinates) — cut off on the desktop: while a drag
    /// is under way the layers being dragged, and with Show Content Outside the Widget every visible layer (they stay
    /// marked after the drop, light words on the light work surface included).
    private func cutOffLayers(_ skin: Skin, card: CGRect) -> [Meter] {
        let dragged = gesture != nil && gestureMoved ? Set(gestureFrames.keys.map { $0.lowercased() }) : []
        return skin.meters.filter { m in
            guard !m.isContainer, m.frame.width > 0, m.frame.height > 0,
                  dragged.contains(m.name.lowercased()) || (showsContentOutside && !m.hidden && m.container == nil)
            else { return false }
            return !card.insetBy(dx: -0.01, dy: -0.01).contains(viewRect(m.frame))
        }
    }

    /// A dashed orange outline around the parts of layers the desktop cuts off (outside the card only): an editor-only
    /// mark that shows them whatever their colours (the ghost of white words on the light work surface is faint).
    private func drawCutOffOutlines(_ skin: Skin, card: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        let cut = cutOffLayers(skin, card: card)
        guard !cut.isEmpty else { return }
        let px = 1 / zoom
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addRect(card)
        ctx.clip(using: .evenOdd)
        ctx.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(px)
        ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
        // Inside the frame, where a selection outline covers it.
        for m in cut { ctx.stroke(viewRect(m.frame).insetBy(dx: px / 2, dy: px / 2)) }
        ctx.restoreGState()
    }

    /// The name of each layer partly outside the widget, next to it (unless it is selected or pointed at, which tag it
    /// already): a ghost says what it is even where its content is faint.
    private func drawGhostTags(_ skin: Skin, zoom: CGFloat, _ ctx: CGContext) {
        guard showsContentOutside, gesture == nil else { return }
        let card = skinRect
        let skip = Set((selectedNames + (hover.map { clickTarget($0) } ?? [])).map { $0.lowercased() })
        for m in cutOffLayers(skin, card: card) where !skip.contains(m.name.lowercased()) {
            let r = viewRect(m.frame)
            drawTag(layerName(m.name), near: r, leading: true, zoom: zoom,
                    fill: NSColor.systemOrange.withAlphaComponent(0.9), ctx,
                    avoiding: tagObstacles(except: [m.name], around: r, in: skin) + badgeRects)
        }
    }

    /// `r` minus `hole`, as up to four rectangles.
    static func subtract(_ hole: CGRect, from r: CGRect) -> [CGRect] {
        let h = hole.intersection(r)
        guard !h.isNull, h.width > 0, h.height > 0 else { return [r] }
        return [
            CGRect(x: r.minX, y: r.minY, width: r.width, height: h.minY - r.minY),
            CGRect(x: r.minX, y: h.maxY, width: r.width, height: r.maxY - h.maxY),
            CGRect(x: r.minX, y: h.minY, width: h.minX - r.minX, height: h.height),
            CGRect(x: h.maxX, y: h.minY, width: r.maxX - h.maxX, height: h.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    private func drawGrid(_ rect: CGRect, dirty: CGRect, zoom: CGFloat, _ ctx: CGContext) {
        let area = rect.intersection(dirty)
        guard !area.isNull else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.1).cgColor)
        ctx.setLineWidth(1 / zoom)
        var x = rect.minX + (area.minX - rect.minX).rounded(.down)
        while x <= area.maxX {
            ctx.move(to: CGPoint(x: x, y: area.minY))
            ctx.addLine(to: CGPoint(x: x, y: area.maxY))
            x += 1
        }
        var y = rect.minY + (area.minY - rect.minY).rounded(.down)
        while y <= area.maxY {
            ctx.move(to: CGPoint(x: area.minX, y: y))
            ctx.addLine(to: CGPoint(x: area.maxX, y: y))
            y += 1
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The union of some layers' frames in view coordinates.
    private func union(_ names: [String], in skin: Skin) -> CGRect {
        names.compactMap { skin.meter(named: $0) }.map { viewRect($0.frame) }.reduce(CGRect.null) { $0.union($1) }
    }

    /// Hover and selection outlines, handles, guides, tags, badges and editor-only placeholders, at a constant
    /// on-screen size.
    private func drawOverlay(_ skin: Skin, zoom: CGFloat, _ ctx: CGContext) {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let px = 1 / zoom
        drawPlaceholders(skin, zoom: zoom, ctx)
        drawGhostTags(skin, zoom: zoom, ctx)
        // A row pointed at in the sidebar: its layers outlined, the rest of the widget veiled.
        let highlighted = hoverHighlight.compactMap { skin.meter(named: $0) }
        if !highlighted.isEmpty, gesture == nil {
            ctx.saveGState()
            ctx.addRect(skinRect)
            for m in highlighted { ctx.addRect(viewRect(m.frame)) }
            ctx.setFillColor(CGColor(gray: 0, alpha: Self.veilAlpha))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
            for m in highlighted {
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.5 * px)
                ctx.stroke(viewRect(m.frame).insetBy(dx: -0.75 * px, dy: -0.75 * px))
            }
        }
        // The pointer over a layer (its run while the run is not entered): a thin outline and its name.
        if let name = hover, gesture == nil, marquee == nil {
            let target = clickTarget(name)
            if Set(target.map { $0.lowercased() }) != Set(selectedNames.map { $0.lowercased() }) {
                let r = union(target, in: skin)
                if !r.isNull {
                    ctx.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
                    ctx.setLineWidth(px)
                    ctx.stroke(r.insetBy(dx: -px / 2, dy: -px / 2))
                    let title = target.count > 1 ? groupName(target) : layerName(target[0])
                    drawTag(title, near: r, leading: true, zoom: zoom, fill: accent.withAlphaComponent(0.85), ctx,
                            avoiding: tagObstacles(except: target + selectedNames, around: r, in: skin))
                }
            }
        }
        for name in relatedNames where !selectedNames.contains(name) {
            guard let m = skin.meter(named: name) else { continue }
            let r = viewRect(m.frame)
            ctx.setFillColor(accent.withAlphaComponent(0.14).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5 * px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 2 * px])
            ctx.stroke(r.insetBy(dx: 0.75 * px, dy: 0.75 * px))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        drawFollowers(skin, zoom: zoom, accent: accent, ctx)
        let guideColor = NSColor.systemPink.cgColor
        for g in guides {
            ctx.setStrokeColor(guideColor)
            ctx.setLineWidth(px)
            let full = bounds
            switch g.axis {
            case .vertical:
                let x = CGFloat(g.position) + origin.x
                ctx.move(to: CGPoint(x: x, y: full.minY))
                ctx.addLine(to: CGPoint(x: x, y: full.maxY))
            case .horizontal:
                let y = CGFloat(g.position) + origin.y
                ctx.move(to: CGPoint(x: full.minX, y: y))
                ctx.addLine(to: CGPoint(x: full.maxX, y: y))
            }
            ctx.strokePath()
        }
        if let box = marquee {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(px)
            ctx.stroke(box.insetBy(dx: px / 2, dy: px / 2))
        }
        let group = selectedMeters
        if group.count > 1 {
            for m in group {
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.5 * px)
                ctx.stroke(viewRect(m.frame).insetBy(dx: 0.75 * px, dy: 0.75 * px))
            }
            let union = group.map { viewRect($0.frame) }.reduce(CGRect.null) { $0.union($1) }
            ctx.setStrokeColor(accent.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            ctx.stroke(union.insetBy(dx: -3 * px, dy: -3 * px))
            ctx.setLineDash(phase: 0, lengths: [])
            let size = "\(Self.format(Double(union.width))) × \(Self.format(Double(union.height)))"
            let title = selectedGroup.map { "\(groupName($0)) · \(size)" } ?? "\(group.count) layers"
            drawTag(title, near: union.insetBy(dx: -3 * px, dy: -3 * px), leading: false, zoom: zoom, fill: accent, ctx,
                    avoiding: tagObstacles(except: selectedNames, around: union, in: skin) + badgeRects)
            return
        }
        // A text being edited in place shows only its field (no handles or tag over the words).
        guard let m = selectedMeter, m.name != editingText else { return }
        let r = viewRect(m.frame)
        drawAnchorConnector(m, skin: skin, zoom: zoom, accent: accent, ctx)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5 * px)
        ctx.stroke(r.insetBy(dx: 0.75 * px, dy: 0.75 * px))
        for (_, h) in handleRects() {
            let path = CGPath(roundedRect: h, cornerWidth: 2 * px, cornerHeight: 2 * px, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(px)
            ctx.strokePath()
        }
        let text = gesture == nil
            ? "\(layerName(m.name)) · \(Self.format(m.frame.width)) × \(Self.format(m.frame.height))"
            : "X \(Self.format(m.frame.x))  Y \(Self.format(m.frame.y))  \(Self.format(m.frame.width)) × \(Self.format(m.frame.height))"
        // Outside the handles, so it never covers them or the layer.
        drawTag(text, near: r.insetBy(dx: -4 * px, dy: -4 * px), leading: false, zoom: zoom, fill: accent, ctx,
                avoiding: (gesture == nil ? tagObstacles(except: [m.name], around: r, in: skin) : []) + badgeRects)
    }

    /// Layers placed relative to the ones being moved: a dashed outline and "Follows “48 Hz”" (§9.5).
    private func drawFollowers(_ skin: Skin, zoom: CGFloat, accent: NSColor, _ ctx: CGContext) {
        let px = 1 / zoom
        for (name, anchor) in followers.sorted(by: { $0.key < $1.key }) {
            guard let m = skin.meter(named: name), !selectedNames.contains(m.name) else { continue }
            let r = viewRect(m.frame)
            ctx.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(px)
            ctx.setLineDash(phase: 0, lengths: [3 * px, 2 * px])
            ctx.stroke(r.insetBy(dx: -px, dy: -px))
            ctx.setLineDash(phase: 0, lengths: [])
            drawTag("Follows \(layerName(anchor))", near: r.insetBy(dx: -px, dy: -px), leading: true, zoom: zoom,
                    fill: accent.withAlphaComponent(0.7), ctx)
        }
    }

    /// A selected layer placed relative to another: a dotted line to the layer it follows.
    private func drawAnchorConnector(_ m: Meter, skin: Skin, zoom: CGFloat, accent: NSColor, _ ctx: CGContext) {
        guard gesture == nil, let anchorName = Self.anchor(of: m, in: skin), let anchor = skin.meter(named: anchorName)
        else { return }
        let px = 1 / zoom
        let a = viewRect(anchor.frame), r = viewRect(m.frame)
        let from = CGPoint(x: min(max(r.midX, a.minX), a.maxX), y: min(max(r.midY, a.minY), a.maxY))
        let to = CGPoint(x: min(max(from.x, r.minX), r.maxX), y: min(max(from.y, r.minY), r.maxY))
        ctx.saveGState()
        ctx.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.2 * px)
        ctx.setLineDash(phase: 0, lengths: [1.5 * px, 2.5 * px])
        ctx.stroke(a.insetBy(dx: -px, dy: -px))
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(accent.cgColor)
        ctx.fillEllipse(in: CGRect(x: from.x - 2.5 * px, y: from.y - 2.5 * px, width: 5 * px, height: 5 * px))
        ctx.restoreGState()
    }

    /// A badge next to the widget card during a drag.
    struct Badge {
        enum Kind { case growth, cutOff }
        var kind: Kind
        var text: String
        /// View coordinates.
        var rect: CGRect
    }

    static let cutOffBadgeText = "Cut off on the desktop"
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    /// Where the badges go: the growth badge under the card's bottom-right corner; "Cut off on the desktop" above the
    /// card's top-left corner, else above its top-right, under its bottom-left or under its bottom-right — the first
    /// place off the layers being dragged (their handles included) and off the growth badge.
    func badgePlacements(zoom: CGFloat) -> [Badge] {
        let card = skinRect
        guard !card.isEmpty else { return [] }
        var badges: [Badge] = []
        let gap = 8 / zoom
        if let text = growthBadge {
            let s = pillSize(text, font: Self.badgeFont, height: 20)
            let w = s.width / zoom, h = s.height / zoom
            badges.append(Badge(kind: .growth, text: text, rect: CGRect(x: card.maxX - w, y: card.maxY + gap, width: w, height: h)))
        }
        if isDraggingPastEdge {
            let s = pillSize(Self.cutOffBadgeText, font: Self.badgeFont, height: 20, icon: true)
            let w = s.width / zoom, h = s.height / zoom
            let places = [
                CGRect(x: card.minX, y: card.minY - gap - h, width: w, height: h),
                CGRect(x: card.maxX - w, y: card.minY - gap - h, width: w, height: h),
                CGRect(x: card.minX, y: card.maxY + gap, width: w, height: h),
                CGRect(x: card.maxX - w, y: card.maxY + gap, width: w, height: h),
            ]
            let margin = 8 / zoom
            var obstacles = badges.map(\.rect)
            if gesture != nil, gestureMoved, let skin {
                obstacles += gestureFrames.keys.compactMap { skin.meter(named: $0) }
                    .map { viewRect($0.frame).insetBy(dx: -margin, dy: -margin) }
            }
            if let ghost = componentGhost?.frame { obstacles.append(viewRect(ghost).insetBy(dx: -margin, dy: -margin)) }
            func covered(_ p: CGRect) -> CGFloat {
                obstacles.reduce(0) { total, o in
                    let i = p.intersection(o)
                    return i.isNull ? total : total + i.width * i.height
                }
            }
            let place = places.first { covered($0) == 0 } ?? places.min { covered($0) < covered($1) } ?? places[0]
            badges.append(Badge(kind: .cutOff, text: Self.cutOffBadgeText, rect: place))
        }
        return badges
    }

    /// The badges of the drag, where `badgePlacements` put them.
    private func drawBadges(_ badges: [Badge], zoom: CGFloat, _ ctx: CGContext) {
        for badge in badges {
            switch badge.kind {
            case .growth:
                drawPill(badge.text, in: badge.rect, font: Self.badgeFont, fill: NSColor.labelColor.withAlphaComponent(0.78),
                         textColor: isDark ? .black : .white, zoom: zoom, ctx)
            case .cutOff:
                drawPill(badge.text, in: badge.rect, font: Self.badgeFont, fill: .systemOrange, textColor: .white, zoom: zoom,
                         ctx, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Editor-only drawing: "Double-click to type" in empty texts, "Choose what this shows ▾" on bars, graphs and
    /// gauges without data, and an empty widget's starters (§9.8).
    private func drawPlaceholders(_ skin: Skin, zoom: CGFloat, _ ctx: CGContext) {
        for m in skin.meters where m.name != editingText {
            guard let p = placeholderRect(m) else { continue }
            let size = CGFloat(p.height / 1.25)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            NSGraphicsContext.saveGraphicsState()
            (Self.placeholderText as NSString).draw(at: NSPoint(x: CGFloat(p.x) + origin.x, y: CGFloat(p.y) + origin.y),
                                                    withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        for (_, r) in chooseDataChips() {
            drawPill(Self.chooseDataText, in: r, font: chipFont, fill: accent, textColor: .white, zoom: zoom, ctx)
        }
        guard skin.meters.isEmpty else { return }
        let card = skinRect
        let title = NSAttributedString(string: "Your widget is empty", attributes: [
            .font: NSFont.systemFont(ofSize: 13 / zoom, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let subtitle = NSAttributedString(string: "Drag something in from Add, or start with one of these:", attributes: [
            .font: NSFont.systemFont(ofSize: 11 / zoom), .foregroundColor: NSColor.secondaryLabelColor])
        NSGraphicsContext.saveGraphicsState()
        title.draw(at: NSPoint(x: card.midX - title.size().width / 2, y: card.midY - 34 / zoom))
        subtitle.draw(at: NSPoint(x: card.midX - subtitle.size().width / 2, y: card.midY - 14 / zoom))
        NSGraphicsContext.restoreGraphicsState()
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        for (id, r) in starterRects() {
            drawPill(EditorComponents.component(id)?.title ?? id, in: r, font: font,
                     fill: NSColor.controlAccentColor.withAlphaComponent(0.9), textColor: .white, zoom: zoom, ctx)
        }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// A pill's size in on-screen points: its text plus padding (and a leading symbol).
    private func pillSize(_ text: String, font: NSFont, height: CGFloat, padding: CGFloat = 7, icon: Bool = false) -> CGSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: ceil(width) + 2 * padding + (icon ? 14 : 0), height: height)
    }

    /// Where a tag of `size` (on-screen points) goes next to `r` (view coordinates) without covering it: above, else
    /// below, else to the right, else to the left — within the visible area, and off the other layers (`avoiding`)
    /// when a place allows (else the place covering the least of them). `leading`: aligned with `r`'s left edge
    /// (names), else centred on it (the selection's size).
    func tagRect(size: CGSize, near r: CGRect, leading: Bool, zoom: CGFloat, avoiding: [CGRect] = []) -> CGRect {
        let w = size.width / zoom, h = size.height / zoom, gap = 6 / zoom, inset = 4 / zoom
        var visible = visibleRect
        if visible.isEmpty { visible = bounds }
        var x = leading ? r.minX : r.midX - w / 2
        x = min(max(x, visible.minX + inset), visible.maxX - w - inset)
        let y = min(max(r.midY - h / 2, visible.minY), visible.maxY - h)
        let places = [
            CGRect(x: x, y: r.minY - gap - h, width: w, height: h),
            CGRect(x: x, y: r.maxY + gap, width: w, height: h),
            CGRect(x: r.maxX + gap, y: y, width: w, height: h),
            CGRect(x: r.minX - gap - w, y: y, width: w, height: h),
        ].filter { visible.contains($0) }
        guard let first = places.first else { return CGRect(x: x, y: r.minY - gap - h, width: w, height: h) }
        func covered(_ p: CGRect) -> CGFloat {
            avoiding.reduce(0) { total, o in
                let i = p.intersection(o)
                return i.isNull ? total : total + i.width * i.height
            }
        }
        return places.first { covered($0) == 0 } ?? places.min { covered($0) < covered($1) } ?? first
    }

    /// The other layers a tag next to `names` should not cover: visible ones, without those drawn behind the whole of
    /// `r` (a background panel).
    private func tagObstacles(except names: [String], around r: CGRect, in skin: Skin) -> [CGRect] {
        let skip = Set(names.map { $0.lowercased() })
        return skin.meters.compactMap { m in
            guard !m.hidden, !m.isContainer, !skip.contains(m.name.lowercased()), m.frame.width > 0, m.frame.height > 0
            else { return nil }
            let frame = viewRect(m.frame)
            return frame.contains(r) ? nil : frame
        }
    }

    /// A name tag next to `r` (see `tagRect`).
    private func drawTag(_ text: String, near r: CGRect, leading: Bool, zoom: CGFloat, fill: NSColor, _ ctx: CGContext,
                         avoiding: [CGRect] = []) {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let rect = tagRect(size: pillSize(text, font: font, height: 19), near: r, leading: leading, zoom: zoom,
                           avoiding: avoiding)
        drawnTagRects.append(rect)
        drawPill(text, in: rect, font: font, fill: fill, textColor: .white, zoom: zoom, ctx)
    }

    /// A capsule with its text, `r` in view coordinates, drawn at a constant on-screen size.
    private func drawPill(_ text: String, in r: CGRect, font: NSFont, fill: NSColor, textColor: NSColor, zoom: CGFloat,
                          _ ctx: CGContext, symbol: String? = nil) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: 1 / zoom, y: 1 / zoom)
        let w = r.width * zoom, h = r.height * zoom
        let pill = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        var textX: CGFloat = 7
        if let symbol, let image = EditorStyle.image(symbol, size: 9.5, weight: .bold) {
            let tinted = image.tinted(textColor)
            let s = image.size
            NSGraphicsContext.saveGraphicsState()
            tinted.draw(in: CGRect(x: textX, y: (h - s.height) / 2, width: s.width, height: s.height), from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            textX += 14
        }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor])
        let textWidth = attributed.size().width
        if symbol == nil { textX = (w - textWidth) / 2 }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.textMatrix = .identity
        ctx.translateBy(x: textX, y: (h + ascent - descent) / 2)
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Relative placement (followers and anchors, §9.5)

    /// The layer `m` is placed relative to: the one before it (in its container) when its X or Y ends in `r` / `R`,
    /// else the first layer its X / Y / W / H reads (`[MeterName:X]`). nil for a layer placed on its own.
    static func anchor(of m: Meter, in skin: Skin) -> String? {
        let meters = skin.meters
        if InspectorWindowController.isRelativelyPlaced(m), let i = meters.firstIndex(where: { $0 === m }) {
            if let previous = meters[..<i].last(where: { $0.container === m.container }) { return previous.name }
        }
        let raw = [m.rawOption("X"), m.rawOption("Y"), m.rawOption("W"), m.rawOption("H")].compactMap { $0 }
            .joined(separator: "\n").lowercased()
        guard raw.contains("[") else { return nil }
        return meters.first { $0 !== m && raw.contains("[\($0.name.lowercased()):") }?.name
    }

    /// The layers that move when `names` move (follower → the layer it directly follows), through chains of `r` / `R`
    /// and `[Meter:X]` references; the moved layers themselves are left out.
    static func followers(of names: [String], in skin: Skin) -> [String: String] {
        let anchors = skin.meters.compactMap { m in anchor(of: m, in: skin).map { (m.name, $0) } }
        var moving = Set(names.map { $0.lowercased() })
        var result: [String: String] = [:]
        var changed = true
        while changed {
            changed = false
            for (name, anchor) in anchors where !moving.contains(name.lowercased()) && moving.contains(anchor.lowercased()) {
                result[name] = anchor
                moving.insert(name.lowercased())
                changed = true
            }
        }
        return result
    }
}

private extension NSImage {
    /// The (template) image in one color.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

// MARK: - Dropping library components

/// The canvas is a drop target for components dragged out of the component library (`ComponentLibraryView`). While
/// one hovers, a ghost of its default size follows the pointer — centred on it, in whole skin points, snapped to the
/// other meters and the skin edges exactly like a moved meter (⌘ turns snapping off) — with a preview of the
/// component, its name and position, and the snap guides. The drop reports the ghost's frame via `onDropComponent`.
extension SkinCanvasView {
    /// The known component id a drag carries (nil for anything else).
    static func componentID(on pasteboard: NSPasteboard) -> String? {
        guard let id = pasteboard.string(forType: .desksetComponent), EditorComponents.component(id) != nil else { return nil }
        return id
    }

    /// Where component `id` lands with the pointer at `p` (view coordinates), and the guides it snapped to; nil when
    /// the canvas can't take it (no skin, not editable, unknown id). Never left of or above the skin's origin (a meter
    /// there would be cut off); past the right or bottom edge the widget grows.
    func componentDropFrame(id: String, at p: NSPoint, snapping: Bool = true) -> (frame: SkinRect, guides: [EditorSnapping.Guide])? {
        guard isEditable, let skin, let component = EditorComponents.component(id) else { return nil }
        let size = component.defaultSize
        var frame = SkinRect(x: (Double(p.x - origin.x) - size.width / 2).rounded(),
                             y: (Double(p.y - origin.y) - size.height / 2).rounded(),
                             width: size.width, height: size.height)
        var snapped: [EditorSnapping.Guide] = []
        if snapping {
            let others = skin.meters.filter { !$0.hidden && !$0.isContainer && $0.frame.width > 0 && $0.frame.height > 0 }
                .map(\.frame)
            let bounds = SkinRect(x: 0, y: 0, width: skin.width, height: skin.height)
            let snap = EditorSnapping.snap(frame, to: others + [bounds], threshold: Double(Self.snapDistance / zoom))
            // Whole points even when a centre line with a half-point position was the match.
            frame.x = (frame.x + snap.dx).rounded()
            frame.y = (frame.y + snap.dy).rounded()
            snapped = snap.guides
        }
        frame.x = max(frame.x, 0)
        frame.y = max(frame.y, 0)
        // Keep only guides the final frame still touches (clamping or rounding may have moved it off one).
        let edges = (vertical: [frame.x, frame.x + frame.width / 2, frame.maxX],
                     horizontal: [frame.y, frame.y + frame.height / 2, frame.maxY])
        snapped = snapped.filter { g in
            (g.axis == .vertical ? edges.vertical : edges.horizontal).contains { abs($0 - g.position) < 0.01 }
        }
        return (frame, snapped)
    }

    /// A component dragged over the canvas at `p`: moves the ghost and the guides (also used by the self-tests).
    @discardableResult
    func componentDragMoved(id: String, to p: NSPoint, snapping: Bool = true) -> SkinRect? {
        guard let (frame, snapped) = componentDropFrame(id: id, at: p, snapping: snapping) else {
            componentDragEnded()
            return nil
        }
        if componentGhost?.id != id || componentGhost?.frame != frame || guides != snapped {
            componentGhost = (id, frame)
            guides = snapped
            // The widget grows live past its right and bottom edges (§9.10), and the canvas with it, so the drag can
            // go on past the new edge; the canvas holds still on screen meanwhile.
            holdsPositionOnScreen = true
            updateSize()
            needsDisplay = true
        }
        return frame
    }

    /// The drag left the canvas or ended: no ghost, no guides, the widget at its own size again.
    func componentDragEnded() {
        guard componentGhost != nil else { return }
        componentGhost = nil
        guides = []
        updateSize()
        holdsPositionOnScreen = false
        needsDisplay = true
    }

    /// Drops component `id` with the pointer at `p` (also used by the self-tests): reports the frame through
    /// `onDropComponent`. False when the canvas can't take it.
    @discardableResult
    func dropComponent(id: String, at p: NSPoint, snapping: Bool = true) -> Bool {
        let result = componentDropFrame(id: id, at: p, snapping: snapping)
        componentDragEnded()
        guard let (frame, _) = result else { return false }
        onDropComponent?(id, frame)
        return true
    }

    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        // The library offers copy and, with ⌘ held, generic.
        sender.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    private static var snappingDuringDrag: Bool { !NSEvent.modifierFlags.contains(.command) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        componentDragOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        componentDragOperation(sender)
    }

    /// Entered or moved: the ghost follows the pointer, and the drag's own image is hidden exactly while there is a
    /// ghost — it comes back when the canvas refuses the drag (it stopped being editable while the pointer was on it).
    private func componentDragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = Self.componentID(on: sender.draggingPasteboard) else { return [] }
        let accepted = componentDragMoved(id: id, to: convert(sender.draggingLocation, from: nil),
                                          snapping: Self.snappingDuringDrag) != nil
        setDragImageHidden(accepted, sender, id: id)
        return accepted ? dragOperation(sender) : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        componentDragEnded()
        if let sender, let id = Self.componentID(on: sender.draggingPasteboard) {
            setDragImageHidden(false, sender, id: id)
        } else {
            dragImageHiddenFor = nil
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = Self.componentID(on: sender.draggingPasteboard) else {
            componentDragEnded()
            return false
        }
        window?.makeFirstResponder(self)
        let dropped = dropComponent(id: id, at: convert(sender.draggingLocation, from: nil), snapping: Self.snappingDuringDrag)
        if dropped {
            // Accepted: AppKit removes the drag image; nothing to restore.
            dragImageHiddenFor = nil
        } else {
            // Refused: the image slides back to the card, so it needs its thumbnail again.
            setDragImageHidden(false, sender, id: id)
        }
        return dropped
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        componentDragEnded()
        dragImageHiddenFor = nil
    }

    /// Hides the drag's own image while the ghost stands in for it (the library's thumbnail would only cover the
    /// component drawn at its real size), and puts the library's drag image back — centred on the pointer, as the
    /// card starts it — whenever the ghost goes away without a drop: the canvas refuses the drag, the pointer
    /// leaves, the drag is cancelled or the drop fails. AppKit documents that a destination's changes end when the
    /// drag exits, but not for a refusal while still over the canvas or for a failed drop, whose slide back would
    /// otherwise animate nothing; restoring on exit too keeps every path explicit. Tracked per drag
    /// (`draggingSequenceNumber`) so a drag that ended without `concludeDragOperation` can't leave stale state.
    private func setDragImageHidden(_ hidden: Bool, _ sender: NSDraggingInfo, id: String) {
        let sequence = sender.draggingSequenceNumber
        guard hidden != (dragImageHiddenFor == sequence) else { return }
        dragImageHiddenFor = hidden ? sequence : nil
        let image = hidden ? nil : ComponentThumbnails.dragImageOrSymbol(for: id, dark: isDark)
        let p = convert(sender.draggingLocation, from: nil)
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            if let image {
                item.setDraggingFrame(NSRect(x: p.x - image.size.width / 2, y: p.y - image.size.height / 2,
                                             width: image.size.width, height: image.size.height), contents: image)
            } else {
                item.imageComponentsProvider = { [] }
            }
        }
    }

    /// The ghost: the component's preview at its real size, a translucent accent fill, a dashed outline and a label
    /// with its name and position, at a constant on-screen line width.
    func drawComponentGhost(zoom: CGFloat, _ ctx: CGContext) {
        guard let (id, frame) = componentGhost, let component = EditorComponents.component(id) else { return }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let px = 1 / zoom
        let r = CGRect(x: CGFloat(frame.x) + origin.x, y: CGFloat(frame.y) + origin.y,
                       width: CGFloat(frame.width), height: CGFloat(frame.height))
        if let preview = ComponentThumbnails.preview(for: id) {
            NSGraphicsContext.saveGraphicsState()
            preview.draw(in: CGRect(origin: r.origin, size: preview.size), from: .zero, operation: .sourceOver,
                         fraction: 0.85, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
        // A 1-point divider still gets a visible outline.
        let outline = r.height * zoom < 6 || r.width * zoom < 6
            ? r.insetBy(dx: min(0, (r.width - 6 * px) / 2), dy: min(0, (r.height - 6 * px) / 2)) : r
        ctx.saveGState()
        ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
        ctx.fill(outline)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5 * px)
        ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
        ctx.stroke(outline.insetBy(dx: 0.75 * px, dy: 0.75 * px))
        ctx.restoreGState()
        drawTag("\(component.title)  X \(Self.format(frame.x))  Y \(Self.format(frame.y))", near: outline, leading: false,
                zoom: zoom, fill: accent, ctx, avoiding: badgeRects)
    }
}

/// Keeps a document smaller than the visible area centered (NSClipView pins it to the top-left otherwise).
final class CenteringClipView: NSClipView {
    /// The document stays where it is on screen while it changes size (a drag growing the canvas), instead of being
    /// centred again; setting it back to false centres it.
    var holdsDocument = false {
        didSet {
            guard oldValue, !holdsDocument else { return }
            scroll(to: bounds.origin)
            enclosingScrollView?.reflectScrolledClipView(self)
        }
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let size = document.frame.size
        if rect.width > size.width { rect.origin.x = holdsDocument ? proposedBounds.minX : (size.width - rect.width) / 2 }
        if rect.height > size.height { rect.origin.y = holdsDocument ? proposedBounds.minY : (size.height - rect.height) / 2 }
        return rect
    }
}
