import AppKit
import DesksetCore

/// Borderless, transparent, non-activating panel that hosts one skin. It becomes key only when the skin asks for
/// focus events (see `SkinView.needsPanelToBecomeKey`), so clicking a widget does not steal keyboard focus.
final class SkinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// A key skin window swallows typing quietly, whether or not its view is the first responder (skins have no text
    /// input; unhandled keys would beep).
    override func keyDown(with event: NSEvent) {}
}

/// Shows the skin and turns mouse events into skin actions / window dragging. Its frames are the contents of a layer of
/// their own inside the view's layer, which the skin's runtime presents from its executor (`LayerContentProvider`); the
/// view's own layer shows nothing, and `draw(_:)` stays for snapshots (`cacheDisplay`). It reaches the skin through its
/// window controller's runtime: events are messages (`SkinRuntime.send`); what it needs to know at once — whether a
/// press may drag, whether a right click opens the skin menu, the cursor, the tooltips, whether the panel becomes key —
/// it reads from the skin's snapshot (`SkinSnapshot`, as of the skin's last piece of work: the frame on screen), and
/// its own drawing from the live skin with exclusive access. Whether an event was handled is the skin's answer when the
/// message ran at once (the skin runs on the main thread), else what the snapshot predicted. Debug builds compare every
/// answer taken from the snapshot with the live skin's while the skin runs on the main thread (`SnapshotAudit`).
///
/// Mouse rules (manual: Mouse actions):
/// - "LeftMouseDownAction … disables dragging the skin": no drag starts where a LeftMouseDownAction is set (on a
///   meter or in `[Rainmeter]`), nor from a press on a Button meter's image.
/// - A double click runs the DoubleClick action and also the Down action of that press ("If LeftMouseDownAction or
///   LeftMouseUpAction is also set, both will be executed"); the release runs the Up action.
/// - RightMouseUpAction / RightMouseDownAction (and RightMouseDoubleClickAction) replace the skin menu.
/// - Hover (MouseOver/MouseLeave, Button hover frames) is not updated while a mouse button is held: the engine
///   treats a hover update as the end of a press, so leaving and re-entering during a press is reported once the
///   buttons are released.
/// - `Plugin=Mouse` measures get every press, drag, release, wheel notch and move first (`Skin.pointerEvent`), except
///   ⌘-presses (the CTRL override) and Control-clicks (the skin menu). Input elsewhere on the screen reaches
///   `Plugin=Slider` measures through `OutsidePointerMonitor`, never this skin's own window's input.
final class SkinView: NSView, NSViewToolTipOwner {
    weak var controller: SkinWindowController?
    private var trackingArea: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var windowOrigin: NSPoint?
    private var dragged = false
    /// ⌘ held at mouse-down: the manual's CTRL override. "Mouse Click Options may be overridden by holding down CTRL
    /// while clicking" (no click actions run) and Draggable is overridden ("Hold down the CTRL key to temporarily
    /// override this setting"). On the Mac Control-click is a right click, so Command plays that role.
    private var dragOverride = false
    /// Decided at mouse-down: Draggable (or ⌘), inside DragMargins, no LeftMouseDownAction there, not a Button.
    private(set) var dragAllowed = false
    /// A RightMouseDownAction / RightMouseDoubleClickAction caught the press: its release shows no skin menu.
    private var rightPressHandled = false
    /// Mouse buttons pressed on this view and not released yet (bit per button number).
    private(set) var heldButtons = 0
    /// The pointer entered or left the view while a button was held; reported when the buttons are released.
    private var hoverPending = false
    /// Buttons whose press was reported to `Skin.pointerEvent` and whose release was not yet.
    private(set) var pointerPresses: Set<MouseButton> = []
    private var scrollAccumulator: CGFloat = 0
    /// Tooltip areas (skin coordinates) currently registered with AppKit, one per meter with a tooltip.
    private(set) var toolTipRects: [CGRect] = []
    /// Cursor shown over the skin (nil: the arrow).
    private(set) var cursorName: String?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// OnFocusAction / OnUnfocusAction need the skin window to become key when clicked ("focus is given when the
    /// mouse is clicked on the skin"). A click on any skin also takes the focus away from another skin that holds it
    /// ("focus is lost when the mouse is clicked outside the skin"), so that skin's OnUnfocusAction runs.
    override var needsPanelToBecomeKey: Bool {
        guard let c = controller else { return false }
        if c.wantsFocus { return true }
        if let key = NSApp.keyWindow as? SkinPanel, key !== window { return true }
        return false
    }
    override var acceptsFirstResponder: Bool { controller?.wantsFocus ?? false }

    /// The manual's CTRL override (⌘ on the Mac, see `dragOverride`).
    static func isOverride(_ flags: NSEvent.ModifierFlags) -> Bool { flags.contains(.command) }

    /// Where the pointer is on the screen, which a drag follows (a self-test drags without moving the real pointer).
    static var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// Snapshots of the view (`cacheDisplay`): the skin drawn in full. AppKit never draws the view on screen: its layer
    /// asks for no drawing (`wantsUpdateLayer`) and has no contents of its own.
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let runtime = controller?.runtime else { return }
        ctx.clear(bounds)
        // The glass itself is behind this view (`SkinGlassViews`).
        runtime.exclusive { SkinRenderer.draw($0, in: ctx, glass: .window) }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = nil
    }

    /// The frames are drawn at the window's backing scale, in its colour space and with the view's appearance: another
    /// one (a window moved to another display, Dark Mode switched) goes to the runtime in the window's facts, and the
    /// frame is drawn again, not only when the skin redraws (an `Update=-1` skin never does).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.publishFacts()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.publishFacts()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                          .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func point(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        return (Double(p.x), Double(p.y))
    }

    /// Double clicks (and quadruple…: every second click of a series) run the DoubleClick actions.
    static func isDoubleClick(_ clickCount: Int) -> Bool { clickCount >= 2 && clickCount % 2 == 0 }

    private func pressed(_ button: Int) {
        heldButtons |= 1 << min(max(button, 0), 31)
    }

    // MARK: Plugin=Mouse input

    /// Reports mouse input to the skin's `Plugin=Mouse` measures, before the meters get the event. False when that
    /// stopped the skin.
    private func report(_ c: SkinWindowController, _ pointer: PointerEvent, _ event: NSEvent) -> Bool {
        let (x, y) = point(event)
        c.runtime.send(.pointer(pointer, x: x, y: y))
        return !c.isStopped
    }

    private func reportPress(_ c: SkinWindowController, _ button: MouseButton, _ event: NSEvent) -> Bool {
        pointerPresses.insert(button)
        return report(c, .pressed(button, doubleClick: SkinView.isDoubleClick(event.clickCount)), event)
    }

    /// The release of a reported press (also after the skin was dragged, or with ⌘ pressed meanwhile).
    private func reportRelease(_ c: SkinWindowController, _ button: MouseButton, _ event: NSEvent) -> Bool {
        guard pointerPresses.remove(button) != nil else { return true }
        return report(c, .released(button), event)
    }

    /// A drag of a reported press; a ⌘-press that moves the skin is not one.
    private func reportDrag(_ c: SkinWindowController, _ event: NSEvent) -> Bool {
        guard !pointerPresses.isEmpty else { return true }
        return report(c, .dragged, event)
    }

    /// A button went up: once none is held, hover changes that happened meanwhile are reported.
    private func released(_ button: Int) {
        heldButtons &= ~(1 << min(max(button, 0), 31))
        guard heldButtons == 0, hoverPending, let c = controller, !c.isStopped, let window else { return }
        hoverPending = false
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) {
            hover(c, x: Double(p.x), y: Double(p.y))
        } else {
            leave(c)
        }
    }

    // MARK: Left button: actions + dragging

    override func mouseDown(with event: NSEvent) {
        guard let c = controller, !c.isStopped else { return }
        // Control-click is the Mac right click: always the skin menu.
        if event.modifierFlags.contains(.control) {
            dragOrigin = nil
            c.showContextMenu(with: event, in: self)
            return
        }
        pressed(0)
        c.bringToFrontOnClick()
        let (x, y) = point(event)
        dragOrigin = SkinView.pointerLocation()
        windowOrigin = window?.frame.origin
        dragged = false
        dragOverride = SkinView.isOverride(event.modifierFlags)
        if !dragOverride && !reportPress(c, .left, event) {
            dragOrigin = nil
            dragAllowed = false
            return
        }
        dragAllowed = SkinView.leftMouseDown(c, x: x, y: y, clickCount: event.clickCount, override: dragOverride)
        // Until the release, the skin's own moves wait: a drag wins over them.
        if dragAllowed && !c.isStopped { c.beginDragPress() }
    }

    /// Runs the left-button down (and double-click) actions for a press at (x, y) and returns whether the press may
    /// start a drag. With the CTRL override no click action runs and the skin can always be dragged.
    static func leftMouseDown(_ c: SkinWindowController, x: Double, y: Double, clickCount: Int, override: Bool) -> Bool {
        if override { return true }
        // Decided before any action runs (an action may hide or move meters), on the frame on screen.
        let blocksDrag = hasAction(c, .leftDown, x: x, y: y) || isOnButton(c, x: x, y: y)
        let hasDoubleClick = hasAction(c, .leftDoubleClick, x: x, y: y)
        var handled = false
        if isDoubleClick(clickCount), hasDoubleClick {
            handled = deliver(c, .leftDoubleClick, x: x, y: y)
            guard !c.isStopped else { return false }
        }
        if deliver(c, .leftDown, x: x, y: y) { handled = true }
        guard !c.isStopped else { return false }
        return !blocksDrag && !handled && c.state.draggable && isInDragArea(c, x: x, y: y)
    }

    /// Sends a mouse action at (x, y) and tells whether it was handled: the skin's own answer when the message ran at
    /// once (the skin runs on the main thread), else what the snapshot predicted when it was sent.
    @discardableResult
    static func deliver(_ c: SkinWindowController, _ kind: MouseEventKind, x: Double, y: Double) -> Bool {
        let runtime = c.runtime
        let predicted = runtime.snapshot.hitMap.handles(kind, x: x, y: y)
        guard let live = runtime.send(.mouse(kind, x: x, y: y)) else { return predicted }
        SnapshotAudit.compare("handles(\(kind.rawValue)) at (\(x), \(y))", runtime, snapshot: predicted, live: live)
        return live
    }

    /// A click there runs (or is caught by) an action (`Skin.hasAction`), from the snapshot.
    static func hasAction(_ c: SkinWindowController, _ kind: MouseEventKind, x: Double, y: Double) -> Bool {
        let runtime = c.runtime
        return SnapshotAudit.check("hasAction(\(kind.rawValue)) at (\(x), \(y))", runtime,
                                   snapshot: runtime.snapshot.hitMap.hasAction(kind, x: x, y: y),
                                   live: { $0.hasAction(kind, x: x, y: y) })
    }

    /// The press is on the image of the topmost Button meter there (transparent pixels are not the button), like
    /// the engine's dispatch of clicks (Buttons first, even under other meters): from the snapshot.
    static func isOnButton(_ c: SkinWindowController, x: Double, y: Double) -> Bool {
        let runtime = c.runtime
        return SnapshotAudit.check("isOnButton at (\(x), \(y))", runtime,
                                   snapshot: runtime.snapshot.hitMap.isOnButton(x: x, y: y),
                                   live: { $0.isOnButton(x: x, y: y) })
    }

    /// Outside the skin's DragMargins (`Skin.isInDragArea`), from the snapshot.
    static func isInDragArea(_ c: SkinWindowController, x: Double, y: Double) -> Bool {
        let runtime = c.runtime
        return SnapshotAudit.check("isInDragArea at (\(x), \(y))", runtime,
                                   snapshot: runtime.snapshot.hitMap.isInDragArea(x: x, y: y),
                                   live: { $0.isInDragArea(x: x, y: y) })
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller, !c.isStopped, reportDrag(c, event), dragAllowed,
              let start = dragOrigin, let origin = windowOrigin, let window else { return }
        let now = SkinView.pointerLocation()
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        var frame = window.frame
        frame.origin = NSPoint(x: origin.x + dx, y: origin.y + dy)
        // ⌘ temporarily inverts SnapEdges ("CTRL key to temporarily override this setting").
        if c.state.snapEdges != event.modifierFlags.contains(.command) { frame = c.snapped(frame) }
        if c.state.keepOnScreen { frame = c.keptOnScreen(frame) }
        window.setFrameOrigin(frame.origin)
    }

    override func mouseUp(with event: NSEvent) {
        defer { released(0) }
        guard let c = controller, !c.isStopped else { return }
        guard reportRelease(c, .left, event) else {
            dragOrigin = nil
            dragged = false
            c.endDragPress(moved: false)
            return
        }
        let (x, y) = point(event)
        if dragged {
            dragged = false
            // The window's place is saved; a move the skin made meanwhile is dropped.
            c.endDragPress(moved: true)
            // The press became a drag: it must not count as a click later (LeftMouseUpAction does not run).
            SkinView.endMousePress(c, x: x, y: y)
        } else {
            // A move the skin made during the press is made now.
            c.endDragPress(moved: false)
            if dragOrigin != nil && !dragOverride { c.runtime.send(.mouse(.leftUp, x: x, y: y)) }
        }
        dragOrigin = nil
    }

    /// Ends the engine's record of a press whose release is not delivered as a click (the skin was dragged), so a
    /// pressed Button returns to normal.
    static func endMousePress(_ c: SkinWindowController, x: Double, y: Double) {
        guard !c.isStopped else { return }
        c.runtime.send(.pressCancelled)
    }

    // MARK: Right / middle / extra buttons

    override func rightMouseDown(with event: NSEvent) {
        guard let c = controller, !c.isStopped else { return }
        pressed(1)
        c.bringToFrontOnClick()
        rightPressHandled = false
        guard !SkinView.isOverride(event.modifierFlags), reportPress(c, .right, event) else { return }
        let (x, y) = point(event)
        rightPressHandled = SkinView.buttonDown(c, down: .rightDown, double: .rightDoubleClick, x: x, y: y,
                                                clickCount: event.clickCount)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let c = controller, !c.isStopped else { return }
        _ = reportDrag(c, event)
    }

    /// Runs the Down action of a press (and first the DoubleClick action of a double click); true when either was
    /// set at the point (for the right button: no skin menu on release).
    @discardableResult
    static func buttonDown(_ c: SkinWindowController, down: MouseEventKind, double: MouseEventKind, x: Double, y: Double,
                           clickCount: Int) -> Bool {
        var handled = false
        if isDoubleClick(clickCount), hasAction(c, double, x: x, y: y) {
            handled = deliver(c, double, x: x, y: y)
            guard !c.isStopped else { return true }
        }
        if deliver(c, down, x: x, y: y) { handled = true }
        return handled
    }

    override func rightMouseUp(with event: NSEvent) {
        defer { released(1) }
        guard let c = controller, !c.isStopped, reportRelease(c, .right, event) else { return }
        let (x, y) = point(event)
        let pressHandled = rightPressHandled
        rightPressHandled = false
        // Like Rainmeter: Ctrl+right-click always opens the skin menu (Control, or the ⌘ override, on the Mac);
        // otherwise RightMouseUpAction / RightMouseDownAction / RightMouseDoubleClickAction "disable the skin context
        // menu".
        let override = event.modifierFlags.contains(.control) || SkinView.isOverride(event.modifierFlags)
        if !override {
            let upHandled = SkinView.deliver(c, .rightUp, x: x, y: y)
            if upHandled || pressHandled || c.isStopped || !SkinView.showsSkinMenu(c, x: x, y: y) { return }
        }
        c.showContextMenu(with: event, in: self)
    }

    /// Whether a right click at the point may open the skin menu (its Down / Up actions did not catch it). A
    /// RightMouseDoubleClickAction there also "disables the context menu": the menu opened by the first click
    /// would swallow the second one, so the double click could never happen.
    static func showsSkinMenu(_ c: SkinWindowController, x: Double, y: Double) -> Bool {
        !hasAction(c, .rightDoubleClick, x: x, y: y)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let c = controller, !c.isStopped, let kinds = SkinView.otherKinds(event.buttonNumber) else { return }
        pressed(event.buttonNumber)
        c.bringToFrontOnClick()
        guard !SkinView.isOverride(event.modifierFlags) else { return }
        if let button = MouseButton(rawValue: event.buttonNumber), !reportPress(c, button, event) { return }
        let (x, y) = point(event)
        SkinView.buttonDown(c, down: kinds.down, double: kinds.double, x: x, y: y, clickCount: event.clickCount)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let c = controller, !c.isStopped else { return }
        _ = reportDrag(c, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        defer { released(event.buttonNumber) }
        guard let c = controller, !c.isStopped else { return }
        if let button = MouseButton(rawValue: event.buttonNumber), !reportRelease(c, button, event) { return }
        guard let kinds = SkinView.otherKinds(event.buttonNumber), !SkinView.isOverride(event.modifierFlags)
        else { return }
        let (x, y) = point(event)
        c.runtime.send(.mouse(kinds.up, x: x, y: y))
    }

    static func otherKinds(_ buttonNumber: Int) -> (down: MouseEventKind, up: MouseEventKind, double: MouseEventKind)? {
        switch buttonNumber {
        case 2: return (.middleDown, .middleUp, .middleDoubleClick)
        case 3: return (.x1Down, .x1Up, .x1DoubleClick)
        case 4: return (.x2Down, .x2Up, .x2DoubleClick)
        default: return nil
        }
    }

    /// Points of trackpad scrolling that count as one wheel notch.
    private static let preciseScrollStep: CGFloat = 24

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller, !c.isStopped else { return }
        let (x, y) = point(event)
        // Physical direction (wheel rolled away / fingers moved up = "up"), whatever the natural-scrolling setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let dy = event.scrollingDeltaY * sign, dx = event.scrollingDeltaX * sign
        let vertical = abs(dy) >= abs(dx)
        let delta = vertical ? dy : dx
        guard delta != 0 else { return }
        var steps = 1
        if event.hasPreciseScrollingDeltas {
            // Trackpads send a stream of small deltas plus momentum: one action per "notch" of travel, and none for
            // the momentum tail (Windows skins expect one action per wheel click).
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) { scrollAccumulator = 0 }
            if scrollAccumulator != 0 && (scrollAccumulator > 0) != (delta > 0) { scrollAccumulator = 0 }
            scrollAccumulator += delta
            steps = Int(min(abs(scrollAccumulator) / SkinView.preciseScrollStep, 10))
            guard steps > 0 else { return }
            scrollAccumulator -= CGFloat(steps) * SkinView.preciseScrollStep * (delta > 0 ? 1 : -1)
        }
        let kind: MouseEventKind = vertical ? (delta > 0 ? .scrollUp : .scrollDown) : (delta > 0 ? .scrollLeft : .scrollRight)
        for _ in 0..<steps {
            // `Plugin=Mouse` measures first, then the action (the skin stops between them when the first stopped it).
            c.runtime.send(.scroll(kind, x: x, y: y))
            guard !c.isStopped else { return }
        }
    }

    /// A focused skin swallows typing quietly (skins have no text input; unhandled keys would beep).
    override func keyDown(with event: NSEvent) {}

    // MARK: Hover, cursor

    override func mouseMoved(with event: NSEvent) {
        // Moves (not drags) arrive only while no button is down: a release this view never saw (the window was
        // replaced or hidden during the press) must not keep hover updates on hold. The engine reports such a
        // release to Plugin=Mouse measures now (see `Skin.pointerEvent`).
        heldButtons = 0
        hoverPending = false
        pointerPresses = []
        if let c = controller, c.isDragPressActive {
            c.endDragPress(moved: dragged)
            dragged = false
            dragOrigin = nil
        }
        guard let c = controller, !c.isStopped, report(c, .moved, event) else { return }
        let (x, y) = point(event)
        hover(c, x: x, y: y)
    }

    override func mouseEntered(with event: NSEvent) {
        guard heldButtons == 0 else {
            hoverPending = true
            return
        }
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let c = controller, !c.isStopped, report(c, .exited, event) else { return }
        guard heldButtons == 0 else {
            hoverPending = true
            return
        }
        leave(c)
    }

    override func cursorUpdate(with event: NSEvent) {
        SkinView.cursor(named: cursorName).set()
    }

    private func hover(_ c: SkinWindowController, x: Double, y: Double) {
        guard !c.state.clickThrough else { return }
        c.runtime.send(.hover(x: x, y: y))
        guard !c.isStopped else { return }
        let name = SkinView.cursorName(c, x: x, y: y)
        if name != cursorName || name != nil {
            cursorName = name
            SkinView.cursor(named: name).set()
        }
    }

    private func leave(_ c: SkinWindowController) {
        c.runtime.send(.exited)
        if cursorName != nil {
            cursorName = nil
            NSCursor.arrow.set()
        }
    }

    /// Cursor at a skin point (`Skin.pointerCursorName`), from the snapshot: the pointer over the image of a Button
    /// meter (the button that a click there presses: the engine gives Buttons the clicks before other meters, so a label
    /// drawn over a button does not hide it), otherwise the engine's choice (MouseActionCursor / MouseActionCursorName
    /// over mouse actions).
    static func cursorName(_ c: SkinWindowController, x: Double, y: Double) -> String? {
        let runtime = c.runtime
        return SnapshotAudit.check("cursor at (\(x), \(y))", runtime,
                                   snapshot: runtime.snapshot.hitMap.pointerCursorName(at: x, y),
                                   live: { $0.pointerCursorName(x: x, y: y) })
    }

    /// `MouseActionCursorName` values with a macOS equivalent; everything else (HELP, BUSY, custom .cur / .ani
    /// files…) shows the arrow.
    static func cursor(named name: String?) -> NSCursor {
        switch name?.trimmingCharacters(in: .whitespaces).uppercased() {
        case "HAND": return .pointingHand
        case "TEXT": return .iBeam
        case "CROSS": return .crosshair
        case "NO": return .operationNotAllowed
        case "SIZE_WE": return .resizeLeftRight
        case "SIZE_NS": return .resizeUpDown
        default: return .arrow
        }
    }

    // MARK: Tooltips

    /// Registers one tooltip area per meter that has a tooltip, so AppKit shows a new tooltip when the pointer moves
    /// from one meter to another (a single view-wide tooltip keeps showing the first text). The areas come from the
    /// snapshot (`SkinHitMap.toolTipAreas`: a meter's area includes its glass), the text is read when the tooltip
    /// appears. Called when the snapshot's areas change and after every redraw request; AppKit is only touched when the
    /// areas change.
    func updateToolTips() {
        var rects: [CGRect] = []
        if let c = controller, !c.isStopped, !c.state.clickThrough {
            let runtime = c.runtime
            rects = SnapshotAudit.check("tooltip areas", runtime, snapshot: runtime.snapshot.toolTipAreas,
                                        live: { $0.toolTipAreas().map(\.cgRect) })
        }
        guard rects != toolTipRects else { return }
        toolTipRects = rects
        removeAllToolTips()
        for r in rects { addToolTip(r, owner: self, userData: nil) }
    }

    /// Tooltip text at a skin point, from the snapshot: the title on its own line above the text.
    func toolTipText(x: Double, y: Double) -> String? {
        guard let c = controller, !c.isStopped else { return nil }
        let runtime = c.runtime
        let info = SnapshotAudit.check("tooltip at (\(x), \(y))", runtime,
                                       snapshot: runtime.snapshot.hitMap.toolTipInfo(at: x, y),
                                       live: { $0.toolTipInfo(at: x, y) })
        guard let info else { return nil }
        return info.title.isEmpty ? info.text : "\(info.title)\n\(info.text)"
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        toolTipText(x: Double(point.x), y: Double(point.y)) ?? ""
    }
}
