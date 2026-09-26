import Foundation

// Clean-room implementation of the third-party Mouse plugin (Mouse.dll by NighthawkSLO, later maintained by others),
// written only from its public documentation — the Documentation wiki page of github.com/NighthawkSLO/Mouse.dll and
// that page's history, the PluginMouse wiki page of github.com/jsmorley/PluginMouse, the release notes and the
// plugin's example skins — and from how published skins use it. The plugin's source code was not read.
// Every Mac-vs-Windows difference is listed in docs/compat/plugins.md.

/// `Plugin=Mouse`: runs actions on mouse input anywhere on the skin ("not limited to a meter"), outside the update
/// cycle.
///
/// Model (documentation, with the judgment calls marked):
/// - Actions: the manual's mouse action options — `LeftMouseDownAction`, `LeftMouseUpAction`,
///   `LeftMouseDoubleClickAction` and their Right / Middle / X1 / X2 forms, `MouseScrollUpAction` / `…Down…` /
///   `…Left…` / `…Right…`, and (judgment: the pointer coming over the skin / leaving it) `MouseOverAction` /
///   `MouseLeaveAction` — plus `MouseMoveAction` ("gets executed when the mouse moves"; `MoveAction` in version 3.0.0)
///   and `LeftMouseDragAction` … `X2MouseDragAction` ("when their respective mouse button is pressed and the mouse
///   moves - these do not override the MoveAction but are executed after it"). A double click runs the DoubleClick
///   action and then the Down action, as a meter does ("both will be executed").
/// - `$MouseX$` / `$MouseY$` (any case) are the pointer position relative to the skin's top-left corner, or with
///   `RelativeToSkin=0` to the primary screen's top-left corner (the screen coordinates `!Move` uses). Nothing else
///   is replaced: `$MouseX:%$` stays as written.
/// - `RequireDragging=1`: `!CommandMeasure M "Start"` / `"Stop"` are accepted and the actions run only between them.
///   Judgment: the documentation only says that the commands "set mouse capturing to happen outside borders as well";
///   the plugin's example skin and the published skins start the measure from the LeftMouseDownAction of the meter
///   being dragged and stop it in the measure's own LeftMouseUpAction, and skins with two such measures rely on only
///   the started one reacting. Without RequireDragging, Start and Stop are ignored.
/// - Disabled / paused: no actions. Judgment: from the bang on — the documentation asks for `DynamicVariables=1` and
///   an update after the bang, which works as well. The commands work while the measure is disabled or paused.
/// - Input: what the skin window gets (`Skin.pointerEvent`). A press that started on the skin is followed until its
///   button goes up, also outside the skin (judgment: on Windows that needs RequireDragging and Start; macOS follows a
///   press in the window where it started, and a release that never arrives leaves a skin half-way through a drag).
///   A press that started elsewhere is never a drag of this skin.
/// - Order: the measure gets an event before the skin's meters (judgment: the plugin watches the mouse before the skin
///   window handles it); several Mouse measures get it in file order.
/// - `UpdateRate` (ms, default 20), documented for version 3.0 as "the interval (in milliseconds) for executing the
///   plugin's move and drag actions" and gone from the later documentation: move and drag actions run at most once
///   per interval. The last position of an interval runs when the interval ends, or before any other action of the
///   measure (a release comes after the final drag position). 0 runs them on every move.
/// - The measure's value is 0.
/// - Version 2 of the plugin, `Plugin=Slider`, is `SliderMeasure`: it reads that version's options into the same
///   settings.
public class MouseMeasure: Measure, PluginLifecycle, SkinPointerObserver {
    /// What the options ask for (`readMeasureOptions`).
    struct Settings {
        /// Actions of button, wheel and hover events (only the ones that are set).
        var eventActions: [MouseEventKind: String] = [:]
        var moveAction = ""
        var dragActions: [MouseButton: String] = [:]
        var relativeToSkin = true
        var requireDragging = false
        /// Seconds between two move / drag actions (0: every move).
        var moveInterval = MouseMeasure.defaultUpdateRate / 1000
    }
    var settings = Settings()
    /// Between `Start` and `Stop` (RequireDragging=1).
    public private(set) var isStarted = false
    private(set) var closed = false

    private struct Move {
        var x: Double
        var y: Double
        var dragging: [MouseButton]
    }
    /// A move that waits for the end of its UpdateRate interval.
    private var pendingMove: Move?
    /// Whether a move waits for the end of its interval (self-tests wait for its timer).
    var hasPendingMove: Bool { pendingMove != nil }
    private var moveTimer: SkinScheduledWork?
    private var lastMoveTime = -Double.infinity

    /// Monotonic clock (seconds); tests may replace it.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static let defaultUpdateRate = 20.0
    static let maxUpdateRate = 10_000.0

    /// `LeftMouseDragAction`, `RightMouseDragAction`…
    static func dragOption(_ button: MouseButton) -> String {
        switch button {
        case .left: return "LeftMouseDragAction"
        case .right: return "RightMouseDragAction"
        case .middle: return "MiddleMouseDragAction"
        case .x1: return "X1MouseDragAction"
        case .x2: return "X2MouseDragAction"
        }
    }

    deinit {
        moveTimer?.cancel()
    }

    // MARK: Options

    public override func readMeasureOptions() {
        var s = Settings()
        for kind in MouseEventKind.allCases { s.eventActions[kind] = action(kind.rawValue) }
        s.moveAction = action("MouseMoveAction") ?? action("MoveAction") ?? ""
        for button in MouseButton.allCases { s.dragActions[button] = action(MouseMeasure.dragOption(button)) }
        s.relativeToSkin = bool("RelativeToSkin", true)
        s.requireDragging = bool("RequireDragging", false)
        let rate = double("UpdateRate", MouseMeasure.defaultUpdateRate)
        s.moveInterval = (rate.isFinite ? min(max(rate, 0), MouseMeasure.maxUpdateRate)
            : MouseMeasure.defaultUpdateRate) / 1000
        settings = s
    }

    /// An action option; nil when it is missing or blank.
    func action(_ key: String) -> String? {
        let text = actionOption(key)
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
    }

    // MARK: Commands

    /// Whether the plugin has the Start and Stop commands (version 2, `SliderMeasure`, has no commands).
    class var hasStartStop: Bool { true }

    public override func execute(command: String) {
        let verb = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.hasStartStop, verb == "start" || verb == "stop" else {
            super.execute(command: command)
            return
        }
        // Read here: a measure disabled since the skin loaded has not read its options yet.
        guard bool("RequireDragging", false) else {
            skin.logOnce("Mouse [\(name)]: \"\(command)\" needs RequireDragging=1; ignored", level: .warning)
            return
        }
        isStarted = verb == "start"
        if !isStarted { dropPendingMove() }
    }

    public func skinWillClose() {
        closed = true
        dropPendingMove()
    }

    // MARK: Input

    /// Whether the actions run now.
    var isActive: Bool {
        !closed && !disabled && !paused && (!settings.requireDragging || isStarted)
    }

    func pointerInput(_ input: PointerInput, x: Double, y: Double) {
        guard !closed else { return }
        // Enabled or changed since its options were last read (`!EnableMeasure` without `!UpdateMeasure`).
        if needsOptionRead { readOptionsIfNeeded() }
        handle(input, x: x, y: y)
    }

    /// Runs the actions of one input (`SliderMeasure` adds its hold action).
    func handle(_ input: PointerInput, x: Double, y: Double) {
        switch input {
        case .move(let dragging):
            move(Move(x: x, y: y, dragging: dragging))
        case .down(let button, let doubleClick):
            flushPendingMove()
            if doubleClick { run(settings.eventActions[button.doubleClickKind], x: x, y: y) }
            run(settings.eventActions[button.downKind], x: x, y: y)
        case .up(let button):
            flushPendingMove()
            run(settings.eventActions[button.upKind], x: x, y: y)
        case .scroll(let kind):
            flushPendingMove()
            run(settings.eventActions[kind], x: x, y: y)
        case .enter:
            flushPendingMove()
            run(settings.eventActions[.over], x: x, y: y)
        case .leave:
            flushPendingMove()
            run(settings.eventActions[.leave], x: x, y: y)
        }
    }

    private func move(_ move: Move) {
        guard isActive else {
            dropPendingMove()
            return
        }
        let now = clock()
        if settings.moveInterval > 0, now - lastMoveTime < settings.moveInterval {
            pendingMove = move
            scheduleMoveTimer(at: lastMoveTime + settings.moveInterval)
            return
        }
        dropPendingMove()
        lastMoveTime = now
        runMove(move)
    }

    /// MouseMoveAction, then the drag action of every button held.
    private func runMove(_ move: Move) {
        run(settings.moveAction, x: move.x, y: move.y)
        for button in move.dragging { run(settings.dragActions[button], x: move.x, y: move.y) }
    }

    /// Runs the waiting move now: at the end of its interval, or before another action of the measure.
    func flushPendingMove() {
        guard let move = pendingMove else { return }
        dropPendingMove()
        guard isActive else { return }
        lastMoveTime = clock()
        runMove(move)
    }

    private func dropPendingMove() {
        pendingMove = nil
        moveTimer?.cancel()
        moveTimer = nil
    }

    private func scheduleMoveTimer(at time: TimeInterval) {
        guard moveTimer == nil else { return }
        // On the skin's executor, like the skin's update timer (on the main thread in the common modes: a drag goes on
        // while a menu is open).
        moveTimer = skin.executor.timer(interval: max(0, time - clock()), leeway: 0, repeats: false) { [weak self] in
            guard let self else { return }
            self.moveTimer = nil
            self.flushPendingMove()
        }
    }

    /// Runs an action if it is set and the measure is active (an earlier action of the same event may have disabled,
    /// paused or stopped it).
    func run(_ action: String?, x: Double, y: Double) {
        guard let action, !action.isEmpty, isActive else { return }
        skin.executePointerAction(action, from: self, x: x, y: y, relativeToSkin: settings.relativeToSkin)
    }
}
