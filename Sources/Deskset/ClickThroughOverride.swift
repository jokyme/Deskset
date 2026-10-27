import AppKit

/// Holding ⌘ or Control over a click-through skin lets the mouse reach it (manual, ClickThrough: "To temporary disable
/// this, hold the CTRL key when interacting with the mouse"; ⌘ is Deskset's Ctrl override and Control-click opens the
/// skin menu): ⌘-drag moves it, Control-click opens its menu and Control-Option-click selects it.
///
/// macOS delivers no event at all to a window that ignores the mouse, and watching keys pressed in other apps needs
/// Accessibility, so the modifier keys, the mouse buttons and the pointer are read every `interval` seconds (no
/// permission), and only while a skin is click-through. A skin is overridden while a key is held and the pointer is
/// over its window; a press that started there keeps the override until every button is up, so a drag survives
/// releasing the key. A press already under way elsewhere starts no override.
final class ClickThroughOverride {
    /// What the monitor reads each turn; self-tests supply their own.
    protocol State {
        var modifierFlags: NSEvent.ModifierFlags { get }
        var pressedMouseButtons: Int { get }
        /// AppKit screen coordinates (origin at the bottom left of the primary display).
        var pointerLocation: NSPoint { get }
    }

    struct SystemState: State {
        var modifierFlags: NSEvent.ModifierFlags { NSEvent.modifierFlags }
        var pressedMouseButtons: Int { NSEvent.pressedMouseButtons }
        var pointerLocation: NSPoint { NSEvent.mouseLocation }
    }

    static let interval: TimeInterval = 0.1
    static let keys: NSEvent.ModifierFlags = [.command, .control]

    private unowned let app: AppController
    var state: State = SystemState()
    private var timer: Timer?
    var isWatching: Bool { timer != nil }

    init(app: AppController) {
        self.app = app
    }

    /// A skin is click-through: watch until none is. Headless apps never watch on their own (self-tests call `tick`).
    func watch() {
        guard timer == nil, app.presentsWindows else { return }
        let timer = Timer(timeInterval: ClickThroughOverride.interval, repeats: true) { [weak self] _ in self?.tick() }
        // Common modes: keep following while a menu or a drag runs the event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        let skins = app.controllersByName.filter { $0.isClickThrough || $0.clickThroughOverridden }
        guard !skins.isEmpty else { return stop() }
        let held = !state.modifierFlags.intersection(ClickThroughOverride.keys).isEmpty
        let pressed = state.pressedMouseButtons != 0
        let pointer = state.pointerLocation
        for c in skins {
            let wanted: Bool
            if !c.isClickThrough {
                wanted = false
            } else if c.clickThroughOverridden && pressed {
                wanted = true
            } else {
                wanted = held && !pressed && (c.visibilityForTesting ?? c.window.isVisible) && c.window.frame.contains(pointer)
            }
            c.setClickThroughOverridden(wanted)
        }
    }
}
