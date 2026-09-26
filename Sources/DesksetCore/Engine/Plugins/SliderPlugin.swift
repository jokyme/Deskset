import Foundation

// Clean-room implementation of Slider.dll by NighthawkSLO, the plugin's name in versions 2.x before it became the Mouse
// plugin (MousePlugin.swift), written only from its public documentation — the 2016 revisions of the Documentation
// wiki page of github.com/NighthawkSLO/Mouse.dll and the release notes of versions 2.0.0.24 to 2.2.2.41 — and from how
// published skins use it. The plugin's source code was not read. Every Mac-vs-Windows difference is listed in
// docs/compat/plugins.md.

/// `Plugin=Slider`: runs actions when one mouse button is pressed, held, dragged and released on the skin, and when
/// the mouse moves — version 2 of the Mouse plugin, which settings windows and scroll bars still load.
///
/// Model (documentation, with the judgment calls marked):
/// - `MouseButton`: the button to track, `Left` (default), `Right` or `Middle` (any case; judgment: anything else is
///   the left button, with a warning in the log). `ClickAction` / `ReleaseAction` run when it "is pressed or
///   released", `DragAction` when it "is pressed and the mouse moves", `HoldAction` when it "is held for a delay" of
///   `HoldDelay` milliseconds (default 300; 500 before version 2.2.1.38). `MoveAction` runs "when the mouse moves".
/// - `$MouseX$` / `$MouseY$` in all actions (any case, as since version 2.2.2.41) and `RelativeToSkin` (default 1;
///   0 = the screen's top-left corner): as in the Mouse plugin.
/// - Input on the skin, disabled / paused and the order against the skin's meters: as in the Mouse plugin
///   (`MouseMeasure`). Its press is followed until the button goes up, also outside the skin.
/// - Input elsewhere on the screen (judgment: version 2 "uses a detached thread" watching the mouse, version 3.2 "uses
///   [a] process hook instead of a global one", and published skins expect clicks anywhere): presses, releases, drags,
///   holds and moves made outside the skin window — in other apps, on the desktop, in Deskset's other windows — run
///   the same actions, with `$MouseX$` / `$MouseY$` outside the skin (`Skin.outsidePointerEvent`). The host watches
///   the mouse elsewhere only for what `outsidePointerNeeds()` asks: the tracked button while a Click, Release, Drag or
///   Hold action is set (its drags only for DragAction and HoldAction), every move only for a MoveAction; nothing while
///   the measure is disabled or paused.
/// - Judgment: MoveAction also runs during a drag, before DragAction (version 3 documents its move action that way).
///   A double click is two presses: version 2 has no double-click action.
/// - Judgment: move and drag actions run at most every 20 ms — version 2.0.0.24 "uses a detached thread with a 20 ms
///   cooldown" — and the waiting position runs before any other action of the measure (a release, a hold).
/// - Judgment: the hold runs once per press, when the button is still down HoldDelay ms after the press, whether the
///   pointer moved or not, with `$MouseX$` / `$MouseY$` where the pointer is then. A press made while the measure was
///   disabled holds once it is enabled, as it drags.
/// - No commands: Start and Stop came with version 3's RequireDragging. The measure's value is 0.
public final class SliderMeasure: MouseMeasure, SkinOutsidePointerObserver {
    /// `MouseButton`.
    private(set) var button = MouseButton.left
    private var holdAction: String?
    /// Seconds from a press to its hold.
    private(set) var holdDelay = SliderMeasure.defaultHoldDelay / 1000
    /// The tracked button while it is down after a press on the skin.
    private var heldButton: MouseButton?
    /// Where the pointer is while the hold waits: its `$MouseX$` / `$MouseY$`.
    private var holdPoint = (x: 0.0, y: 0.0)
    private var holdTimer: SkinScheduledWork?
    /// Whether a press waits for its HoldDelay to end (self-tests wait for its timer).
    var isHoldWaiting: Bool { holdTimer != nil }

    static let defaultHoldDelay = 300.0
    /// A day: a longer hold never happens.
    static let maxHoldDelay = 86_400_000.0

    override class var hasStartStop: Bool { false }

    deinit {
        holdTimer?.cancel()
    }

    // MARK: Options

    public override func readMeasureOptions() {
        button = readButton()
        holdAction = action("HoldAction")
        let delay = double("HoldDelay", SliderMeasure.defaultHoldDelay)
        holdDelay = (delay.isFinite ? min(max(delay, 0), SliderMeasure.maxHoldDelay) : SliderMeasure.defaultHoldDelay)
            / 1000
        // Version 2's actions are version 3's actions of one button (version 3's own options are not read); move and
        // drag keep the default 20 ms interval.
        var s = Settings()
        s.eventActions[button.downKind] = action("ClickAction")
        s.eventActions[button.upKind] = action("ReleaseAction")
        s.moveAction = action("MoveAction") ?? ""
        s.dragActions[button] = action("DragAction")
        s.relativeToSkin = bool("RelativeToSkin", true)
        settings = s
    }

    private func readButton() -> MouseButton {
        let text = string("MouseButton").trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "", "left": return .left
        case "right": return .right
        case "middle": return .middle
        default:
            skin.logOnce("Slider [\(name)]: MouseButton=\(text) is not Left, Right or Middle; the left button is used",
                         level: .warning)
            return .left
        }
    }

    // MARK: Input

    func outsidePointerNeeds() -> OutsidePointerNeeds {
        guard !closed, !disabled, !paused else { return OutsidePointerNeeds() }
        // Enabled or changed since its options were last read (`!EnableMeasure` or `!SetOption` without an update).
        if needsOptionRead { readOptionsIfNeeded() }
        guard isActive else { return OutsidePointerNeeds() }
        var needs = OutsidePointerNeeds()
        let drags = settings.dragActions[button] != nil || holdAction != nil
        if drags || settings.eventActions[button.downKind] != nil || settings.eventActions[button.upKind] != nil {
            needs.buttons = [button]
        }
        // A hold's `$MouseX$` / `$MouseY$` are where the pointer is when the delay ends.
        if drags { needs.dragButtons = [button] }
        needs.moves = !settings.moveAction.isEmpty
        return needs
    }

    public override func skinWillClose() {
        super.skinWillClose()
        endHold()
    }

    override func handle(_ input: PointerInput, x: Double, y: Double) {
        switch input {
        case .down(let pressed, _) where pressed == button:
            super.handle(input, x: x, y: y)
            // The ClickAction may have closed the skin.
            if !closed { startHold(pressed, x: x, y: y) }
        case .up(let released) where released == heldButton:
            endHold()
            super.handle(input, x: x, y: y)
        case .move where holdTimer != nil:
            holdPoint = (x, y)
            super.handle(input, x: x, y: y)
        default:
            super.handle(input, x: x, y: y)
        }
    }

    private func startHold(_ pressed: MouseButton, x: Double, y: Double) {
        endHold()
        heldButton = pressed
        holdPoint = (x, y)
        // Also without a HoldAction: a measure disabled since the skin loaded has not read its options yet, and it may
        // be enabled during the press.
        // On the skin's executor, like the move timer (on the main thread in the common modes: a hold goes on while a
        // menu is open).
        holdTimer = skin.executor.timer(interval: holdDelay, leeway: 0, repeats: false) { [weak self] in
            guard let self else { return }
            self.holdTimer = nil
            self.holdElapsed()
        }
    }

    private func endHold() {
        holdTimer?.cancel()
        holdTimer = nil
        heldButton = nil
    }

    /// The button is still down HoldDelay after its press.
    private func holdElapsed() {
        guard heldButton != nil, !closed else { return }
        // Enabled or changed during the press.
        if needsOptionRead { readOptionsIfNeeded() }
        guard let holdAction, isActive else { return }
        flushPendingMove()
        run(holdAction, x: holdPoint.x, y: holdPoint.y)
    }
}
