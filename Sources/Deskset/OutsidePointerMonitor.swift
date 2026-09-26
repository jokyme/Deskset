import AppKit
import DesksetCore

/// Where the mouse input made outside the skin windows comes from: `SystemPointerEventSource` in the app. Self-tests
/// inject their own; headless apps (`--self-test`, `--snapshot-ui`) have none, so they never watch the real mouse.
protocol PointerEventSource: AnyObject {
    /// Starts watching: `handler(event, false)` gets the events of `global` that the system posts to other apps,
    /// `handler(event, true)` those of `local` dispatched to Deskset's own windows. Both masks hold mouse event types
    /// only. Returns what `stopWatching` takes.
    func startWatching(global: NSEvent.EventTypeMask, local: NSEvent.EventTypeMask,
                       handler: @escaping (NSEvent, Bool) -> Void) -> AnyObject
    func stopWatching(_ token: AnyObject)
    /// The pointer now, in screen coordinates (bottom-left origin at the primary screen's corner, in points).
    var pointerLocation: NSPoint { get }
    /// The mouse buttons down now: bit n for button number n.
    var pressedButtons: Int { get }
}

/// The real mouse: NSEvent's global monitor (copies of the events the system posts to other apps) and local monitor
/// (the events dispatched to Deskset's own windows, before they are dispatched). Mouse events only. Apple's
/// documentation of `addGlobalMonitorForEvents(matching:handler:)` limits the Accessibility requirement to key events
/// ("Key-related events may only be monitored if accessibility is enabled or if your application is trusted for
/// accessibility access"), so watching the mouse asks for no permission; key events are never watched (the masks are
/// cut down to `OutsidePointerMonitor.mouseTypes`). The handlers "are always called on the main thread" (Cocoa Event
/// Handling Guide, Monitoring Events).
final class SystemPointerEventSource: PointerEventSource {
    private final class Token {
        var global: Any?
        var local: Any?
    }

    func startWatching(global: NSEvent.EventTypeMask, local: NSEvent.EventTypeMask,
                       handler: @escaping (NSEvent, Bool) -> Void) -> AnyObject {
        let token = Token()
        let global = global.intersection(OutsidePointerMonitor.mouseTypes)
        let local = local.intersection(OutsidePointerMonitor.mouseTypes)
        if !global.isEmpty {
            token.global = NSEvent.addGlobalMonitorForEvents(matching: global) { handler($0, false) }
        }
        if !local.isEmpty {
            token.local = NSEvent.addLocalMonitorForEvents(matching: local) { event in
                handler(event, true)
                return event
            }
        }
        return token
    }

    func stopWatching(_ token: AnyObject) {
        guard let token = token as? Token else { return }
        // "You must ensure that eventMonitor is removed only once."
        if let monitor = token.global { NSEvent.removeMonitor(monitor) }
        if let monitor = token.local { NSEvent.removeMonitor(monitor) }
        token.global = nil
        token.local = nil
    }

    var pointerLocation: NSPoint { NSEvent.mouseLocation }
    var pressedButtons: Int { NSEvent.pressedMouseButtons }
}

/// Watches the mouse outside the skin windows for the skins whose measures follow it anywhere on the screen
/// (`Plugin=Slider`: `Skin.outsidePointerNeeds`), and reports what it sees to them (`Skin.outsidePointerEvent`).
///
/// - Only while a running skin asks for it, and only the event types it asks for: the tracked buttons' presses and
///   releases, their drags only while a press of theirs made elsewhere is held (DragAction, HoldAction), and every move
///   only when a measure has a MoveAction. Skins report changes of what they ask for
///   (`SkinHost.skinOutsidePointerNeedsChanged`: loaded, enabled, disabled, changed, unloaded, refreshed, closed when
///   the app quits); the monitors come and go with that.
/// - Other apps and the desktop: the global monitor, and while a watched button pressed there is held, a second global
///   monitor for its drags (`dragMask`), so other apps' drags wake Deskset only when an action wants them. Deskset's
///   own windows (another skin, the editor, the Manage window): the local monitor, for presses and moves only. The
///   drags and the release of a press made in one of Deskset's windows are followed with `pressedButtons` and
///   `pointerLocation` every 20 ms (the Slider plugin's own cooldown) until the button goes up: controls take them in
///   their tracking loops before any monitor sees them.
/// - A skin never gets its own window's input from here: SkinView reports that (`Skin.pointerEvent`), so no click
///   reaches a skin twice. Every other skin gets it as input from elsewhere.
/// - Delivery: on the run loop turn after an event was seen (common modes: also while a menu or a control tracks the
///   mouse), in the order seen; a run of moves waiting together is delivered as its newest position.
/// - Coordinates: screen points are converted into each skin's view (top-left origin), as SkinView converts its own
///   events; screen points are the same on every screen whatever its backing scale.
final class OutsidePointerMonitor {
    unowned let app: AppController
    private(set) var source: PointerEventSource?
    /// What the running skins ask for together.
    private(set) var needs = OutsidePointerNeeds()
    /// The event types watched now (empty while nothing is watched), besides `dragMask`.
    private(set) var globalMask: NSEvent.EventTypeMask = []
    private(set) var localMask: NSEvent.EventTypeMask = []
    private var token: AnyObject?
    var isWatching: Bool { token != nil }
    /// Watched buttons pressed in other apps whose release the global monitor has not seen yet.
    private(set) var heldElsewhere: Set<MouseButton> = []
    /// The drag types watched now in other apps, in a monitor of their own (`dragToken`): those of the buttons held
    /// there whose drags an action wants (`dragMask(for:held:)`). Empty exactly when `dragToken` is nil.
    private(set) var dragMask: NSEvent.EventTypeMask = []
    private var dragToken: AnyObject?

    /// Input seen and not delivered yet. `window`: the Deskset window it was dispatched to (0: another app's).
    struct Record: Equatable {
        var event: PointerEvent
        var location: NSPoint
        var window: Int
    }
    private(set) var queue: [Record] = []
    private var drainScheduled = false
    /// Presses made in Deskset's own windows and not released yet: the window of each.
    private(set) var followed: [MouseButton: Int] = [:]
    private var followedLocation = NSPoint.zero
    private var followTimer: Timer?

    /// Mouse event types, the only ones ever watched.
    static let mouseTypes: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved,
    ]
    static let followInterval: TimeInterval = 0.02
    /// Presses and releases come at a human pace (moves are merged): a longer queue means nothing is delivering it.
    static let maxQueue = 1024

    init(app: AppController) {
        self.app = app
        source = app.presentsWindows ? SystemPointerEventSource() : nil
    }

    /// Replaces the event source (self-tests) and watches with it what the skins ask for.
    func use(_ newSource: PointerEventSource?) {
        stopWatching()
        heldElsewhere = []
        source = newSource
        needsChanged()
    }

    // MARK: What is watched

    /// A skin's needs changed, or a skin stopped: watches what the running skins ask for now.
    func needsChanged() {
        var union = OutsidePointerNeeds()
        for c in app.controllers.values where !c.isStopped { union.formUnion(c.skin.outsidePointerNeeds) }
        needs = union
        // The release of a button no longer watched would not be seen.
        heldElsewhere.formIntersection(union.buttons)
        if union.isEmpty {
            stopFollowing()
            queue.removeAll()
        }
        let wanted = OutsidePointerMonitor.masks(for: union)
        if token == nil || wanted.global != globalMask || wanted.local != localMask {
            // The drags' monitor too, so no two monitors ever watch the same type (a MoveAction watches every drag).
            stopWatching()
            if !union.isEmpty, let source {
                globalMask = wanted.global
                localMask = wanted.local
                token = source.startWatching(global: wanted.global, local: wanted.local) { [weak self] event, local in
                    self?.capture(event, local: local)
                }
            }
        }
        updateDragWatch()
    }

    private func stopWatching() {
        if let token { source?.stopWatching(token) }
        token = nil
        globalMask = []
        localMask = []
        // Without `token`, no drags are watched either.
        updateDragWatch()
    }

    /// Watches the drags in other apps that `dragMask(for:held:)` asks for now. Never called from a monitor's own
    /// handler (monitors are not added or removed while AppKit hands an event to them): a press or release seen there
    /// takes effect when the input is delivered, on the next run loop turn.
    private func updateDragWatch() {
        let wanted = token == nil ? [] : OutsidePointerMonitor.dragMask(for: needs, held: heldElsewhere)
        guard wanted != dragMask else { return }
        if let dragToken { source?.stopWatching(dragToken) }
        dragToken = nil
        dragMask = []
        guard !wanted.isEmpty, let source else { return }
        dragMask = wanted
        dragToken = source.startWatching(global: wanted, local: []) { [weak self] event, local in
            self?.capture(event, local: local)
        }
    }

    /// The event types to watch for `needs`, in other apps (`global`) and in Deskset's own windows (`local`: presses
    /// and moves; the drags and the release of a press made there are followed, see `followTick`). A MoveAction runs
    /// on drags too, so moves need the presses in Deskset's windows (to follow their drags) and every drag elsewhere.
    /// The drags a Drag or Hold action wants are watched only during a press made elsewhere (`dragMask(for:held:)`).
    static func masks(for needs: OutsidePointerNeeds) -> (global: NSEvent.EventTypeMask, local: NSEvent.EventTypeMask) {
        var global: NSEvent.EventTypeMask = [], local: NSEvent.EventTypeMask = []
        for button in needs.buttons {
            let types = eventTypes(button)
            global.formUnion([types.down, types.up])
            local.formUnion(types.down)
        }
        if needs.moves {
            global.formUnion([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged])
            local.formUnion([.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown])
        }
        return (global.intersection(mouseTypes), local.intersection(mouseTypes))
    }

    /// The drag types to watch in other apps while the buttons `held` are down there: those whose drags a Drag or Hold
    /// action wants. None extra with a MoveAction, which watches every drag anyway (`masks(for:)`).
    static func dragMask(for needs: OutsidePointerNeeds, held: Set<MouseButton>) -> NSEvent.EventTypeMask {
        guard !needs.moves else { return [] }
        var mask: NSEvent.EventTypeMask = []
        for button in needs.dragButtons.intersection(held) { mask.formUnion(eventTypes(button).dragged) }
        return mask.intersection(mouseTypes)
    }

    private static func eventTypes(_ button: MouseButton)
        -> (down: NSEvent.EventTypeMask, up: NSEvent.EventTypeMask, dragged: NSEvent.EventTypeMask) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle, .x1, .x2: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    // MARK: Input

    /// The input an event stands for (nil for anything but a button of the five, a drag or a move).
    static func pointerEvent(for event: NSEvent) -> PointerEvent? {
        func other() -> MouseButton? { event.buttonNumber >= 2 ? MouseButton(rawValue: event.buttonNumber) : nil }
        switch event.type {
        case .leftMouseDown: return .pressed(.left, doubleClick: false)
        case .rightMouseDown: return .pressed(.right, doubleClick: false)
        case .otherMouseDown: return other().map { .pressed($0, doubleClick: false) }
        case .leftMouseUp: return .released(.left)
        case .rightMouseUp: return .released(.right)
        case .otherMouseUp: return other().map { .released($0) }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .dragged
        case .mouseMoved: return .moved
        default: return nil
        }
    }

    /// Where an event happened, in screen coordinates: an event of another app has no window, and its location is
    /// already in screen coordinates.
    static func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// An event from a monitor (`local`: dispatched to one of Deskset's windows).
    func capture(_ event: NSEvent, local: Bool) {
        guard let pointer = OutsidePointerMonitor.pointerEvent(for: event) else { return }
        let location = OutsidePointerMonitor.screenLocation(of: event)
        guard local else {
            // Its drags are watched from the delivery on (`updateDragWatch`), until its release.
            switch pointer {
            case .pressed(let button, _) where needs.buttons.contains(button): heldElsewhere.insert(button)
            case .released(let button): heldElsewhere.remove(button)
            // A move without buttons: every release arrived, or never will.
            case .moved: heldElsewhere.removeAll()
            default: break
            }
            enqueue(Record(event: pointer, location: location, window: 0))
            return
        }
        let window = event.window?.windowNumber ?? 0
        switch pointer {
        case .pressed(let button, _):
            enqueue(Record(event: pointer, location: location, window: window))
            follow(button, window: window, from: location)
        case .moved:
            enqueue(Record(event: pointer, location: location, window: window))
        default:
            // Drags and releases in Deskset's windows are followed (`followTick`).
            return
        }
    }

    private func enqueue(_ record: Record) {
        if let last = queue.last, last.event == record.event, last.window == record.window,
           record.event == .moved || record.event == .dragged {
            // Only the newest position of moves waiting together matters.
            queue[queue.count - 1] = record
        } else {
            guard queue.count < OutsidePointerMonitor.maxQueue else { return }
            queue.append(record)
        }
        guard !drainScheduled else { return }
        drainScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.drain() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Delivers the waiting input, oldest first, after watching the drags of the presses made elsewhere meanwhile.
    func drain() {
        drainScheduled = false
        updateDragWatch()
        while !queue.isEmpty {
            deliver(queue.removeFirst())
        }
    }

    private func deliver(_ record: Record) {
        let targets = app.controllers.values
            .filter { !$0.isStopped && !$0.skin.outsidePointerNeeds.isEmpty }
            .sorted { ($0.state.loadOrder, $0.config.lowercased()) < ($1.state.loadOrder, $1.config.lowercased()) }
        for c in targets where !c.isStopped {
            // A skin's own window reports its input itself (SkinView → Skin.pointerEvent).
            if record.window > 0 && c.window.windowNumber == record.window { continue }
            let p = c.skinPoint(fromScreen: record.location)
            c.skin.outsidePointerEvent(record.event, x: p.x, y: p.y)
        }
    }

    // MARK: Presses in Deskset's windows

    private func follow(_ button: MouseButton, window: Int, from location: NSPoint) {
        followed[button] = window
        followedLocation = location
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: OutsidePointerMonitor.followInterval, repeats: true) { [weak self] _ in
            self?.followTick()
        }
        // Common modes: the tracking loop of the control that took the press runs in the event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    /// Follows the presses made in Deskset's windows: a drag when the pointer moved (if anyone wants it), a release
    /// for each followed button that is up.
    func followTick() {
        guard let source, let first = MouseButton.allCases.first(where: { followed[$0] != nil }),
              let firstWindow = followed[first] else {
            stopFollowing()
            return
        }
        let location = source.pointerLocation
        let pressed = source.pressedButtons
        if location != followedLocation {
            followedLocation = location
            if needs.wantsDrag(pressed: Set(followed.keys)) {
                enqueue(Record(event: .dragged, location: location, window: firstWindow))
            }
        }
        for button in MouseButton.allCases {
            guard let window = followed[button], pressed & (1 << button.rawValue) == 0 else { continue }
            followed[button] = nil
            enqueue(Record(event: .released(button), location: location, window: window))
        }
        if followed.isEmpty { stopFollowing() }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        followed = [:]
    }
}
