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

/// Draws the skin and turns mouse events into skin actions / window dragging.
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
    weak var controller: SkinController?
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let skin = controller?.skin else { return }
        ctx.clear(bounds)
        SkinRenderer.draw(skin, in: ctx)
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
    private func report(_ c: SkinController, _ pointer: PointerEvent, _ event: NSEvent) -> Bool {
        let (x, y) = point(event)
        c.skin.pointerEvent(pointer, x: x, y: y)
        return !c.isStopped
    }

    private func reportPress(_ c: SkinController, _ button: MouseButton, _ event: NSEvent) -> Bool {
        pointerPresses.insert(button)
        return report(c, .pressed(button, doubleClick: SkinView.isDoubleClick(event.clickCount)), event)
    }

    /// The release of a reported press (also after the skin was dragged, or with ⌘ pressed meanwhile).
    private func reportRelease(_ c: SkinController, _ button: MouseButton, _ event: NSEvent) -> Bool {
        guard pointerPresses.remove(button) != nil else { return true }
        return report(c, .released(button), event)
    }

    /// A drag of a reported press; a ⌘-press that moves the skin is not one.
    private func reportDrag(_ c: SkinController, _ event: NSEvent) -> Bool {
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
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
        dragged = false
        dragOverride = SkinView.isOverride(event.modifierFlags)
        if !dragOverride && !reportPress(c, .left, event) {
            dragOrigin = nil
            dragAllowed = false
            return
        }
        dragAllowed = SkinView.leftMouseDown(c, x: x, y: y, clickCount: event.clickCount, override: dragOverride)
    }

    /// Runs the left-button down (and double-click) actions for a press at (x, y) and returns whether the press may
    /// start a drag. With the CTRL override no click action runs and the skin can always be dragged.
    static func leftMouseDown(_ c: SkinController, x: Double, y: Double, clickCount: Int, override: Bool) -> Bool {
        if override { return true }
        let skin: Skin = c.skin
        // Decided before any action runs (an action may hide or move meters).
        let blocksDrag = skin.hasAction(.leftDown, x: x, y: y) || isOnButton(skin, x: x, y: y)
        var handled = false
        if isDoubleClick(clickCount), skin.hasAction(.leftDoubleClick, x: x, y: y) {
            handled = skin.mouseEvent(.leftDoubleClick, x: x, y: y)
            guard !c.isStopped else { return false }
        }
        if skin.mouseEvent(.leftDown, x: x, y: y) { handled = true }
        guard !c.isStopped else { return false }
        return !blocksDrag && !handled && c.state.draggable && skin.isInDragArea(x: x, y: y)
    }

    /// The press is on the image of the topmost Button meter there (transparent pixels are not the button), like
    /// the engine's dispatch of clicks (Buttons first, even under other meters).
    static func isOnButton(_ skin: Skin, x: Double, y: Double) -> Bool {
        guard let button = skin.meters.last(where: { $0.handlesMouseItself && $0.isHit(x: x, y: y) }) as? ButtonMeter
        else { return false }
        return button.hitTest(x: x, y: y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller, !c.isStopped, reportDrag(c, event), dragAllowed,
              let start = dragOrigin, let origin = windowOrigin, let window else { return }
        let now = NSEvent.mouseLocation
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
            return
        }
        let (x, y) = point(event)
        if dragged {
            dragged = false
            c.windowMoved()
            // The press became a drag: it must not count as a click later (LeftMouseUpAction does not run).
            SkinView.endMousePress(c, x: x, y: y)
        } else if dragOrigin != nil && !dragOverride {
            c.skin.mouseEvent(.leftUp, x: x, y: y)
        }
        dragOrigin = nil
    }

    /// Ends the engine's record of a press whose release is not delivered as a click (the skin was dragged), so a
    /// pressed Button returns to normal.
    static func endMousePress(_ c: SkinController, x: Double, y: Double) {
        guard !c.isStopped else { return }
        c.skin.cancelMousePress()
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
    static func buttonDown(_ c: SkinController, down: MouseEventKind, double: MouseEventKind, x: Double, y: Double,
                           clickCount: Int) -> Bool {
        var handled = false
        if isDoubleClick(clickCount), c.skin.hasAction(double, x: x, y: y) {
            handled = c.skin.mouseEvent(double, x: x, y: y)
            guard !c.isStopped else { return true }
        }
        if c.skin.mouseEvent(down, x: x, y: y) { handled = true }
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
            let upHandled = c.skin.mouseEvent(.rightUp, x: x, y: y)
            if upHandled || pressHandled || c.isStopped || !SkinView.showsSkinMenu(c.skin, x: x, y: y) { return }
        }
        c.showContextMenu(with: event, in: self)
    }

    /// Whether a right click at the point may open the skin menu (its Down / Up actions did not catch it). A
    /// RightMouseDoubleClickAction there also "disables the context menu": the menu opened by the first click
    /// would swallow the second one, so the double click could never happen.
    static func showsSkinMenu(_ skin: Skin, x: Double, y: Double) -> Bool {
        !skin.hasAction(.rightDoubleClick, x: x, y: y)
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
        c.skin.mouseEvent(kinds.up, x: x, y: y)
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
            guard report(c, .scrolled(kind), event) else { return }
            c.skin.mouseEvent(kind, x: x, y: y)
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

    private func hover(_ c: SkinController, x: Double, y: Double) {
        guard !c.state.clickThrough else { return }
        c.skin.mouseMoved(x: x, y: y)
        guard !c.isStopped else { return }
        let name = SkinView.cursorName(c.skin, x: x, y: y)
        if name != cursorName || name != nil {
            cursorName = name
            SkinView.cursor(named: name).set()
        }
    }

    private func leave(_ c: SkinController) {
        c.skin.mouseExited()
        if cursorName != nil {
            cursorName = nil
            NSCursor.arrow.set()
        }
    }

    /// Cursor at a skin point: the pointer over the image of a Button meter (the button that a click there presses:
    /// the engine gives Buttons the clicks before other meters, so a label drawn over a button does not hide it),
    /// otherwise the engine's choice (MouseActionCursor / MouseActionCursorName over mouse actions).
    static func cursorName(_ skin: Skin, x: Double, y: Double) -> String? {
        if let button = skin.meters.last(where: { $0.handlesMouseItself && $0.isHit(x: x, y: y) }) as? ButtonMeter,
           button.hitTest(x: x, y: y) {
            guard button.mouseActionCursor else { return nil }
            return button.mouseActionCursorName.isEmpty ? "HAND" : button.mouseActionCursorName
        }
        return skin.mouseCursorName(at: x, y)
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
    /// from one meter to another (a single view-wide tooltip keeps showing the first text). The text is read when
    /// the tooltip appears. Called after every redraw request; AppKit is only touched when the areas change.
    func updateToolTips() {
        var rects: [CGRect] = []
        if let c = controller, !c.isStopped, !c.skin.settings.toolTipHidden, !c.state.clickThrough {
            for m in c.skin.meters where !m.hidden && !m.toolTipHidden && !m.toolTipText.isEmpty {
                var r = m.frame.cgRect
                if let container = m.container {
                    // Content of a hidden container "in effect doesn't exist" (no tooltip either).
                    guard !container.hidden else { continue }
                    r = r.intersection(container.frame.cgRect)
                }
                guard !r.isNull, r.width > 0, r.height > 0, r.minX.isFinite, r.minY.isFinite else { continue }
                rects.append(r)
                if rects.count >= 512 { break }
            }
        }
        guard rects != toolTipRects else { return }
        toolTipRects = rects
        removeAllToolTips()
        for r in rects { addToolTip(r, owner: self, userData: nil) }
    }

    /// Tooltip text at a skin point: the title on its own line above the text.
    func toolTipText(x: Double, y: Double) -> String? {
        guard let c = controller, !c.isStopped, let info = c.skin.toolTipInfo(at: x, y) else { return nil }
        return info.title.isEmpty ? info.text : "\(info.title)\n\(info.text)"
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        toolTipText(x: Double(point.x), y: Double(point.y)) ?? ""
    }
}

/// One running skin: engine + window + update timer. Implements `SkinHost` for its skin.
final class SkinController: NSObject, SkinHost, NSWindowDelegate {
    let config: String
    let file: String
    private(set) var skin: Skin!
    private(set) var window: SkinPanel
    let view: SkinView
    /// The skin's update clock, on the skin's executor.
    private var timer: SkinScheduledWork?
    private var hoverTimer: Timer?
    unowned let app: AppController

    /// Hidden with !Hide / !HideFade (the skin keeps updating).
    private(set) var isHiddenByBang = false
    /// The mouse is over the skin window (tracked only when OnHover is set).
    private(set) var isHovering = false
    private(set) var isStopped = false
    /// OnCloseAction is running.
    private(set) var isClosing = false
    private var updatesPaused = false
    /// Updates stopped by `pauseUpdates()` (sleep, locked screens) until `resumeUpdates`.
    var areUpdatesPaused: Bool { updatesPaused }
    /// Lua `SKIN:FadeWindow`: the alpha (0…255) the window was faded to, and the saved AlphaValue it stands in for.
    /// It is not saved: a refresh, or any change of the saved AlphaValue (!SetTransparency, the menu, the Manage
    /// window), ends it.
    private(set) var fadedAlpha: (value: Int, base: Int)?
    /// A redraw was requested while the window was fully covered; done when it becomes visible again.
    private var displayPending = false
    private var fadeGeneration = 0

    /// Largest window side in points: guards against skins whose size formulas explode.
    static let maxWindowSide: CGFloat = 8192

    var state: SkinState { app.state.skin(config) ?? SkinState(file: file) }

    /// The skin defines OnFocusAction or OnUnfocusAction.
    var wantsFocus: Bool {
        guard let skin else { return false }
        return !skin.settings.onFocusAction.isEmpty || !skin.settings.onUnfocusAction.isEmpty
    }

    /// Whether the skin can currently be seen (loaded, not hidden by a bang).
    var isShown: Bool { !isStopped && !isHiddenByBang && window.isVisible }

    init(config: String, file: String, app: AppController) throws {
        self.config = config
        self.file = file
        self.app = app
        view = SkinView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window = SkinController.makePanel()
        super.init()

        let url = SkinLibrary.directory(for: config, root: app.skinsDirectory).appendingPathComponent(file)
        let skin = Skin(config: config, fileURL: url, skinsDirectory: app.skinsDirectory, system: SystemMonitor.shared,
                        host: self)
        self.skin = skin
        try skin.load()
        // Wired up only once the skin loaded (NSWindow does not retain its delegate).
        window.contentView = view
        window.delegate = self
        view.controller = self
        let fonts = Fonts.generation
        Fonts.registerFonts(for: skin)
        // Skins measured before these fonts existed drew their text with a fallback font.
        if Fonts.generation != fonts { app.fontsChanged() }
        for issue in skin.issues { Log.write(issue, level: .warning, source: config) }
    }

    static func makePanel() -> SkinPanel {
        let panel = SkinPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        // AppKit shows a window's tooltips only while its app is active, and Deskset (a menu bar app whose panels
        // never activate it) almost never is: skin tooltips (ToolTipText) show whichever app is in front.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        // ⌘H (hiding the app from the Manage window) must not hide the widgets.
        panel.canHide = false
        panel.level = WindowGeometry.level(forAlwaysOnTop: -2)
        panel.collectionBehavior = WindowGeometry.collectionBehavior(forAlwaysOnTop: -2)
        // `ignoresMouseEvents` is deliberately left at its default: then clicks on fully transparent pixels pass
        // through to what is below, like Rainmeter (skins use `SolidColor=0,0,0,1` to make an area clickable).
        return panel
    }

    // MARK: Lifecycle

    /// First update, placement, then shows the window (fading in over FadeDuration when `fadeIn`). With
    /// StartHidden the window stays hidden until !Show.
    func start(fadeIn: Bool) {
        if state.startHidden { isHiddenByBang = true }
        applyWindowSettings()
        skin.update()
        placeWindow()
        view.needsDisplay = true
        if app.presentsWindows && !isHiddenByBang {
            let target = targetAlpha
            let duration = fadeIn ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
            window.alphaValue = duration > 0 ? 0 : target
            window.orderFrontRegardless()
            if duration > 0 { animateAlpha(to: target, duration: duration) }
        }
        startTimer()
    }

    /// Stops updating, runs OnCloseAction and closes the window (fading out when `fadeOut`).
    func stop(fadeOut: Bool = false) {
        guard !isStopped, !isClosing else { return }
        timer?.cancel()
        timer = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        // OnCloseAction runs while the skin can still handle bangs (it cannot reload or unload itself any more).
        isClosing = true
        skin.close()
        isStopped = true
        let window = self.window
        window.delegate = nil
        fadeGeneration += 1
        let duration = fadeOut && window.isVisible && app.presentsWindows
            ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
        guard duration > 0 else {
            window.orderOut(nil)
            window.close()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = 0
        }, completionHandler: {
            // Keeps the controller (and so the drawn skin) alive until the fade has finished.
            withExtendedLifetime(self) {
                window.orderOut(nil)
                window.close()
            }
        })
    }

    // MARK: Updates

    /// `Update` in ms → timer interval: negative means "update once" (manual: `Update=-1`), otherwise at least 16 ms
    /// ("minimum effective value is 16").
    static func updateInterval(_ milliseconds: Int) -> TimeInterval? {
        milliseconds < 0 ? nil : Double(max(milliseconds, 16)) / 1000
    }

    /// Timer slack that lets macOS coalesce wake-ups (Apple suggests at least 10%); capped so slow skins still tick
    /// on time.
    static func timerTolerance(_ interval: TimeInterval) -> TimeInterval {
        min(interval * 0.1, 0.5)
    }

    /// The update clock is skin work, so it runs on the skin's executor (on the main thread: a Foundation timer in the
    /// common modes, which keeps skins updating while a menu is open).
    private func startTimer() {
        timer?.cancel()
        timer = nil
        guard !isStopped, !updatesPaused, let interval = SkinController.updateInterval(skin.settings.update) else { return }
        timer = skin.executor.timer(interval: interval, leeway: SkinController.timerTolerance(interval),
                                    repeats: true) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.skin.update()
        }
    }

    /// Sleep / screens asleep / session switched away: no updates and no drawing.
    func pauseUpdates() {
        guard !updatesPaused else { return }
        updatesPaused = true
        timer?.cancel()
        timer = nil
        updateHoverTracking()
    }

    /// `updateNow`: catch up at once. Skins with `Update=-1` ("update only once on load or refresh") are not updated:
    /// they have nothing to catch up on, and an extra update would run their OnUpdateAction again.
    func resumeUpdates(updateNow: Bool) {
        guard updatesPaused, !isStopped else { return }
        updatesPaused = false
        if updateNow && SkinController.updateInterval(skin.settings.update) != nil { skin.update() }
        startTimer()
        updateHoverTracking()
    }

    /// The Mac woke from sleep: the engine runs OnWakeAction at the end of the next update ("Action to execute when
    /// Windows returns from the sleep or hibernate states"; at once for Update=-1 skins), which happens right away.
    func systemDidWake() {
        guard !isStopped else { return }
        skin.systemDidWake()
        guard !isStopped else { return }
        if updatesPaused {
            resumeUpdates(updateNow: true)
        } else if SkinController.updateInterval(skin.settings.update) != nil {
            skin.update()
        }
    }

    // MARK: Window settings

    func applyWindowSettings(animated: Bool = false) {
        guard !isStopped else { return }
        let s = state
        window.level = WindowGeometry.level(forAlwaysOnTop: s.alwaysOnTop)
        window.collectionBehavior = WindowGeometry.collectionBehavior(forAlwaysOnTop: s.alwaysOnTop)
        updateHoverTracking()
        applyMouseHandling()
        applyAlpha(animated: animated)
        // A pending !HideFade may have been cut short by the new alpha: make sure a hidden skin is really gone.
        if isHiddenByBang && window.isVisible { window.orderOut(nil) }
        // ClickThrough has no tooltips.
        view.updateToolTips()
    }

    private var targetAlpha: CGFloat {
        let s = state
        return SkinVisibility.targetAlpha(alphaValue: effectiveAlphaValue, onHover: s.onHover, hovering: isHovering,
                                          hidden: isHiddenByBang)
    }

    /// The saved AlphaValue, or the value a Lua FadeWindow faded to while that AlphaValue is unchanged.
    var effectiveAlphaValue: Int {
        let saved = state.alphaValue
        if let faded = fadedAlpha, faded.base == saved { return faded.value }
        return saved
    }

    /// Ends a Lua FadeWindow override (the saved AlphaValue was set again, even to the same value).
    func clearFadedAlpha() {
        fadedAlpha = nil
    }

    /// Lua `SKIN:FadeWindow(from, to)`: the window goes to `from` and fades to `to` (0…255) over FadeDuration. The
    /// saved AlphaValue does not change (see `fadedAlpha`); OnHover and !Hide / !Show work on top of the new value.
    func fadeWindow(from: Int, to: Int) {
        guard !isStopped else { return }
        let from = min(max(from, 0), 255), to = min(max(to, 0), 255)
        fadedAlpha = (to, state.alphaValue)
        guard !isHiddenByBang else { return }
        let duration = SkinVisibility.fadeSeconds(state.fadeDuration)
        if duration > 0 && app.presentsWindows && window.isVisible { window.alphaValue = CGFloat(from) / 255 }
        animateAlpha(to: targetAlpha, duration: duration)
    }

    /// ClickThrough ("all mouse over detection is disabled, and mouse clicks will pass through the skin") and
    /// OnHover=Hide while hovered.
    private func applyMouseHandling() {
        let s = state
        let ignore = s.clickThrough
            || (isHovering && SkinVisibility.passesClicksWhileHovering(onHover: s.onHover))
        if ignore {
            if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        } else if window.ignoresMouseEvents {
            // Setting `ignoresMouseEvents = false` would make even fully transparent pixels catch clicks; a fresh
            // panel gets the default per-pixel behaviour back.
            replacePanel()
        }
        if ignore {
            skin.pointerEvent(.exited, x: -1, y: -1)
            skin.mouseExited()
        }
    }

    private func replacePanel() {
        let old = window
        let panel = SkinController.makePanel()
        panel.setFrame(old.frame, display: false)
        panel.level = old.level
        panel.collectionBehavior = old.collectionBehavior
        panel.alphaValue = old.alphaValue
        old.delegate = nil
        panel.contentView = view
        panel.delegate = self
        window = panel
        if old.isVisible && app.presentsWindows {
            panel.order(.above, relativeTo: old.windowNumber)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        old.orderOut(nil)
        old.close()
        view.needsDisplay = true
    }

    private func applyAlpha(animated: Bool) {
        animateAlpha(to: targetAlpha, duration: animated ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0)
    }

    private func animateAlpha(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeGeneration += 1
        let generation = fadeGeneration
        guard duration > 0, app.presentsWindows else {
            window.alphaValue = target
            completion?()
            return
        }
        let window = self.window
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
        }, completionHandler: { [weak self] in
            guard let self, generation == self.fadeGeneration else { return }
            completion?()
        })
    }

    /// Whether a click brings the skin in front of the windows at its level. AlwaysOnTop manual: "Normal. … will be
    /// brought to the foreground"; a clicked Topmost skin likewise comes in front of other topmost windows (a
    /// non-activating panel is not raised by AppKit on its own). Bottom and On Desktop skins "stay behind other
    /// normal application windows" in load order; Stay Topmost has its own level.
    static func bringsToFrontOnClick(alwaysOnTop: Int) -> Bool { alwaysOnTop == 0 || alwaysOnTop == 1 }

    func bringToFrontOnClick() {
        guard app.presentsWindows, !isStopped, !isHiddenByBang, window.isVisible,
              SkinController.bringsToFrontOnClick(alwaysOnTop: state.alwaysOnTop) else { return }
        window.orderFrontRegardless()
    }

    /// !Show / !Hide (`fade`: !ShowFade / !HideFade, over FadeDuration).
    func setHidden(_ hidden: Bool, fade: Bool) {
        guard !isStopped else { return }
        isHiddenByBang = hidden
        updateHoverTracking()
        let duration = fade ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
        if hidden {
            animateAlpha(to: 0, duration: window.isVisible ? duration : 0) { [weak self] in
                guard let self, self.isHiddenByBang else { return }
                self.window.orderOut(nil)
            }
        } else {
            if !window.isVisible && app.presentsWindows {
                window.alphaValue = duration > 0 ? 0 : targetAlpha
                window.orderFrontRegardless()
                view.needsDisplay = true
            }
            applyMouseHandling()
            animateAlpha(to: targetAlpha, duration: duration)
        }
    }

    // MARK: OnHover

    private func updateHoverTracking() {
        let wanted = state.onHover != 0 && !isHiddenByBang && !isStopped && !updatesPaused
        if wanted {
            guard hoverTimer == nil else { return }
            // The window may ignore the mouse (ClickThrough, or hidden by OnHover=Hide), so hover is detected by
            // polling the pointer position rather than with tracking areas.
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollHover() }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            hoverTimer = t
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            isHovering = false
        }
    }

    private func pollHover() {
        let inside = window.isVisible && window.frame.contains(NSEvent.mouseLocation)
        guard inside != isHovering else { return }
        isHovering = inside
        applyMouseHandling()
        applyAlpha(animated: true)
    }

    // MARK: Placement

    private var screens: [WindowGeometry.Screen] { WindowGeometry.currentScreens() }
    private var primaryHeight: CGFloat { WindowGeometry.primaryHeight(screens) }

    private var skinSize: NSSize {
        func side(_ v: Double) -> CGFloat {
            guard v.isFinite else { return 1 }
            return min(max(CGFloat(v), 1), SkinController.maxWindowSide)
        }
        return NSSize(width: side(skin.width), height: side(skin.height))
    }

    /// KeepOnScreen, or at least not lost entirely off-screen.
    private func constrained(_ frame: CGRect) -> CGRect {
        let screens = self.screens
        return state.keepOnScreen ? WindowGeometry.keptOnScreen(frame, screens: screens)
            : WindowGeometry.rescuedIfOffScreen(frame, screens: screens)
    }

    func keptOnScreen(_ frame: CGRect) -> CGRect { WindowGeometry.keptOnScreen(frame, screens: screens) }

    /// `DefaultWindowX` / `DefaultWindowY` / `DefaultAnchorX` / `DefaultAnchorY` of a config loaded for the first
    /// time (see `seedWindowSettings()`), used by the first placement.
    private var defaultPosition: (x: String, y: String, anchorX: String, anchorY: String)?

    /// First load of a config (no saved settings): the skin's `Default…` options in `[Rainmeter]` become its window
    /// settings (manual: skin sections of Rainmeter.ini, and "Default" values a skin may set for them).
    func seedWindowSettings() {
        let defaults = skin.settings.windowDefaults
        guard !defaults.isEmpty else { return }
        app.state.update(config) { $0 = SkinController.seededState($0, defaults: defaults) }
        func value(_ key: String) -> String? { defaults[key].flatMap { $0.isEmpty ? nil : $0 } }
        if value("WindowX") != nil || value("WindowY") != nil {
            defaultPosition = (value("WindowX") ?? "0", value("WindowY") ?? "0", value("AnchorX") ?? "0",
                               value("AnchorY") ?? "0")
        }
    }

    /// `state` with the values of `defaults` (keys as in `SkinSettings.windowDefaults`) that can be read; the
    /// others keep their current value.
    static func seededState(_ state: SkinState, defaults: [String: String]) -> SkinState {
        var s = state
        func number(_ key: String) -> Double? {
            guard let raw = defaults[key], let v = OptionValue.number(raw), v.isFinite else { return nil }
            return v
        }
        func flag(_ key: String) -> Bool? { number(key).map { $0 != 0 } }
        func int(_ key: String, _ range: ClosedRange<Double>) -> Int? {
            number(key).map { Int(min(max($0.rounded(.towardZero), range.lowerBound), range.upperBound)) }
        }
        if let v = int("AlwaysOnTop", -2...2) { s.alwaysOnTop = v }
        if let v = flag("Draggable") { s.draggable = v }
        if let v = flag("SnapEdges") { s.snapEdges = v }
        if let v = flag("ClickThrough") { s.clickThrough = v }
        if let v = flag("KeepOnScreen") { s.keepOnScreen = v }
        if let v = flag("SavePosition") { s.savePosition = v }
        if let v = flag("StartHidden") { s.startHidden = v }
        if let v = flag("AutoSelectScreen") { s.autoSelectScreen = v }
        if let v = int("AlphaValue", 0...255) { s.alphaValue = v }
        if let v = int("OnHover", 0...3) { s.onHover = v }
        if let v = int("FadeDuration", 0...Double(SkinState.maxFadeDuration)) { s.fadeDuration = v }
        return s
    }

    /// Positions the window from saved state (top-left coordinates), the position it had earlier in this session
    /// (SavePosition=0), the skin's DefaultWindowX / DefaultWindowY on its first load, or cascades a new skin.
    func placeWindow() {
        let size = skinSize
        let s = state
        let ph = primaryHeight
        var frame: CGRect
        var isNew = false
        if s.savePosition, let x = s.x, let y = s.y {
            frame = WindowGeometry.frame(topLeftX: x, y: y, size: size, primaryHeight: ph)
        } else if let p = app.sessionPositions[config.lowercased()] ?? s.x.flatMap({ x in s.y.map { (x, $0) } }) {
            frame = WindowGeometry.frame(topLeftX: p.0, y: p.1, size: size, primaryHeight: ph)
        } else if let d = defaultPosition,
                  let p = WindowPosition.resolve(x: d.x, y: d.y, anchorX: d.anchorX, anchorY: d.anchorY, skinSize: size,
                                                 screens: screens) {
            frame = WindowGeometry.frame(topLeftX: p.x, y: p.y, size: size, primaryHeight: ph)
            isNew = true
        } else {
            let visible = NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            frame = WindowGeometry.cascadeFrame(index: app.controllers.count, size: size, visible: visible)
            isNew = true
        }
        frame = constrained(frame)
        window.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: size)
        defaultPosition = nil
        if isNew { saveFrame(frame, force: true) }
    }

    /// Displays were added, removed or rearranged: re-derive the position from the saved one (so a skin returns to
    /// a monitor that comes back) and keep it on screen, without saving the adjusted position.
    func screensChanged() {
        guard !isStopped else { return }
        if state.savePosition, state.x != nil, state.y != nil {
            placeWindow()
        } else {
            window.setFrame(constrained(window.frame), display: false)
        }
    }

    /// After a drag or !Move.
    func windowMoved() {
        var frame = window.frame
        if state.keepOnScreen {
            frame = keptOnScreen(frame)
            window.setFrameOrigin(frame.origin)
        }
        saveFrame(frame)
    }

    private func saveFrame(_ frame: CGRect, force: Bool = false) {
        let p = WindowGeometry.topLeft(of: frame, primaryHeight: primaryHeight)
        app.sessionPositions[config.lowercased()] = (p.x, p.y)
        // SavePosition: "changes to the window position will be saved". A new skin's first position is always
        // stored so it does not cascade somewhere else next time.
        guard state.savePosition || force else { return }
        app.state.update(config) {
            $0.file = file
            $0.x = p.x
            $0.y = p.y
        }
    }

    /// Snaps to screen edges and nearby skins (SnapEdges).
    func snapped(_ frame: NSRect) -> NSRect {
        let others = app.controllers.values.filter { $0 !== self && $0.isShown }.map(\.window.frame)
        return WindowGeometry.snapped(frame, screens: screens, others: others)
    }

    func moveTo(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let size = window.frame.size
        let frame = WindowGeometry.frame(topLeftX: min(max(x, -1e6), 1e6), y: min(max(y, -1e6), 1e6), size: size,
                                         primaryHeight: primaryHeight)
        window.setFrameOrigin(frame.origin)
        windowMoved()
    }

    /// Top-left of the window in skin (top-left origin) coordinates.
    var topLeftPosition: (x: Double, y: Double) { WindowGeometry.topLeft(of: window.frame, primaryHeight: primaryHeight) }

    func showContextMenu(with event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(app.skinMenu(for: self, includeCustomItems: true), with: event, for: view)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard !isStopped, let skin else { return }
        skin.focusChanged(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isStopped, let skin else { return }
        skin.focusChanged(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if displayPending, window.occlusionState.contains(.visible) {
            displayPending = false
            view.needsDisplay = true
        }
    }

    // MARK: SkinHost

    func skinNeedsDisplay(_ skin: Skin) {
        guard !isStopped else { return }
        let size = skinSize
        if window.frame.size != size {
            // Keep the top-left corner fixed.
            let top = window.frame.maxY
            var frame = NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height)
            if state.keepOnScreen && window.isVisible { frame = keptOnScreen(frame) }
            window.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: size)
        }
        // Energy: a skin hidden behind other windows, on a locked screen or faded out is not redrawn until it can be
        // seen again (measures keep updating).
        if !app.presentsWindows || window.occlusionState.contains(.visible) {
            view.needsDisplay = true
        } else {
            displayPending = true
        }
        view.updateToolTips()
    }

    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        // `*`: the engine has already performed the bang on the sending skin; every other active skin follows.
        let everyone = SkinLibrary.normalizedConfigName(config) == "*"
        if !everyone && app.isLoadPending(config) {
            // `[!ActivateConfig X][!SetVariable V 1 X]`: X is loaded on the next run loop turn; the bang follows it.
            let sender = self.config
            app.later { app in
                let now = app.controllers(forConfigArgument: config, current: nil).filter { !$0.isStopped }
                if now.isEmpty {
                    Log.write("!\(bang.name): config \"\(config)\" is not active", level: .warning, source: sender)
                }
                for target in now { target.skin.perform(bang) }
            }
            return
        }
        let targets = app.controllers(forConfigArgument: config, current: self).filter { !everyone || $0 !== self }
        if targets.isEmpty && !everyone {
            Log.write("!\(bang.name): config \"\(config)\" is not active", level: .warning, source: self.config)
        }
        // Skins can send bangs to each other from actions those bangs trigger (A's OnUpdateAction does
        // [!Update "B"], B's does [!Update "A"]): each skin's own guards count only its own nesting, so the chain
        // across skins is cut here.
        guard SkinController.forwardDepth < SkinController.maxForwardDepth else {
            Log.write("!\(bang.name) to \"\(config)\" ignored: skins keep triggering each other", level: .warning,
                      source: self.config)
            return
        }
        SkinController.forwardDepth += 1
        defer { SkinController.forwardDepth -= 1 }
        for target in targets where !target.isStopped { target.skin.perform(bang) }
    }

    /// Bangs forwarded between skins that are running inside one another right now.
    private static var forwardDepth = 0
    static let maxForwardDepth = 16

    func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        handleHostBang(bang)
    }

    func skin(_ skin: Skin, fadeWindowFrom from: Int, to: Int) -> Bool {
        fadeWindow(from: from, to: to)
        return true
    }

    func skinOutsidePointerNeedsChanged(_ skin: Skin) {
        app.outsidePointer.needsChanged()
    }

    /// The window gets the mouse while it is on screen and does not let the mouse through (ClickThrough, OnHover=Hide
    /// while hovered). Asked when a move from elsewhere is delivered: !Hide orders the window out, and ClickThrough
    /// set during a press drops the pointer's leave, without SkinView ever reporting that the pointer left.
    func skinWindowTakesPointer(_ skin: Skin) -> Bool {
        !isStopped && window.isVisible && !window.ignoresMouseEvents
    }

    /// A point in screen coordinates (AppKit's: bottom-left origin at the primary screen's corner, in points on every
    /// screen whatever its backing scale) in skin coordinates, as `SkinView` converts its own events: the view's
    /// top-left origin, and its scale if it had one.
    func skinPoint(fromScreen point: NSPoint) -> (x: Double, y: Double) {
        let p = view.convert(window.convertPoint(fromScreen: point), from: nil)
        return (Double(p.x), Double(p.y))
    }

    func skin(_ skin: Skin, execute target: String, arguments: [String]) {
        switch SkinController.executePlan(skin, target: target, arguments: arguments) {
        case .nothing:
            break
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .openFiles(let files, let app):
            NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .unsupported(let t):
            Log.write("Cannot run \"\(t)\" (Windows programs are not supported)", level: .warning, source: config)
        }
    }

    enum ExecutePlan: Equatable {
        case nothing
        /// A URL (`https://…`) or a file / app to open with its default handler.
        case open(URL)
        /// Files given as arguments to an application: `["#CONFIGEDITOR#" "#CURRENTPATH#Settings.inc"]`.
        case openFiles([URL], app: URL)
        case unsupported(String)
    }

    /// What `[target arguments…]` does: a URL opens; an application bundle opens the arguments that are files
    /// (relative to the skin folder) or URLs — the way skins open files in `#CONFIGEDITOR#` — and other arguments
    /// (command-line switches) are dropped; any other existing file opens with its default app.
    static func executePlan(_ skin: Skin, target: String, arguments: [String]) -> ExecutePlan {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .nothing }
        if let url = URL(string: t), let scheme = url.scheme, scheme.count > 1 { return .open(url) }
        let path = skin.absolutePath(t)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return .unsupported(t) }
        let url = URL(fileURLWithPath: path)
        if isFolder.boolValue, url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            let files = arguments.prefix(32).compactMap { raw -> URL? in
                let a = raw.trimmingCharacters(in: .whitespaces)
                guard !a.isEmpty else { return nil }
                if let url = URL(string: a), let scheme = url.scheme, scheme.count > 1 { return url }
                let p = skin.absolutePath(a)
                return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
            }
            if !files.isEmpty { return .openFiles(files, app: url) }
        }
        return .open(url)
    }

    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        Log.write(message, level: level, source: config)
    }

    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?) -> (width: Double, height: Double) {
        SkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth)
    }

    func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        Images.size(atPath: path)
    }

    func environment(for skin: Skin) -> SkinEnvironment {
        var env = SkinController.environment(windowFrame: window.frame)
        let s = state
        env.zPosition = s.alwaysOnTop
        // AutoSelectScreen: "the WindowX/WindowY @N settings are dynamically set based on the position of the
        // window"; otherwise the monitor variables without @N refer to the primary screen.
        if s.autoSelectScreen, window.frame.width > 1 || window.frame.height > 1,
           let index = WindowGeometry.screenIndex(for: window.frame, screens: screens), index < env.screens.count {
            env.currentScreen = index
        }
        return env
    }

    /// Screens and window frame in skin coordinates (top-left origin at the primary screen's top-left).
    static func environment(windowFrame: CGRect?) -> SkinEnvironment {
        let screens = WindowGeometry.currentScreens()
        let ph = Double(WindowGeometry.primaryHeight(screens))
        func topLeft(_ r: CGRect) -> SkinRect {
            SkinRect(x: Double(r.minX), y: ph - Double(r.maxY), width: Double(r.width), height: Double(r.height))
        }
        let list = screens.map { SkinScreen(area: topLeft($0.frame), workArea: topLeft($0.visibleFrame)) }
        return SkinEnvironment(windowFrame: windowFrame.map(topLeft) ?? SkinRect(),
                               screens: list.isEmpty ? SkinEnvironment().screens : list,
                               settingsPath: Paths.appSupport.path + "/",
                               programPath: Bundle.main.bundleURL.path + "/",
                               configEditor: Workspace.configEditorPath)
    }
}

/// When skin tooltips (ToolTipText) appear. Windows shows a tooltip after the double-click time, 0.5 s by default;
/// AppKit waits noticeably longer, more so while another app is in front, which is nearly always the case for skin
/// windows. `NSInitialToolTipDelay` (milliseconds) is AppKit's app-wide setting; it is registered as a default, so a
/// value the user set for all apps (`defaults write -g NSInitialToolTipDelay …`) still wins. Called from main.swift
/// before any tooltip is created.
enum SkinTooltips {
    static let initialDelayMilliseconds = 500

    static func registerDelay(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["NSInitialToolTipDelay": initialDelayMilliseconds])
    }
}
