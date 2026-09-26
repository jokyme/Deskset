import Foundation

/// Rectangle in skin coordinates (origin top-left, y grows downward, 1 unit = 1 point).
public struct SkinRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }
}

/// A width and height in skin coordinates (points).
public struct SkinSize: Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }
}

public struct SkinInsets: Equatable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public static let zero = SkinInsets()
}

public enum SkinLogLevel: String {
    case debug = "Debug", notice = "Notice", warning = "Warning", error = "Error"
}

/// Mouse action option names, shared by meters and the `[Rainmeter]` section.
public enum MouseEventKind: String, CaseIterable {
    case leftUp = "LeftMouseUpAction"
    case leftDown = "LeftMouseDownAction"
    case leftDoubleClick = "LeftMouseDoubleClickAction"
    case rightUp = "RightMouseUpAction"
    case rightDown = "RightMouseDownAction"
    case rightDoubleClick = "RightMouseDoubleClickAction"
    case middleUp = "MiddleMouseUpAction"
    case middleDown = "MiddleMouseDownAction"
    case middleDoubleClick = "MiddleMouseDoubleClickAction"
    case x1Up = "X1MouseUpAction"
    case x1Down = "X1MouseDownAction"
    case x1DoubleClick = "X1MouseDoubleClickAction"
    case x2Up = "X2MouseUpAction"
    case x2Down = "X2MouseDownAction"
    case x2DoubleClick = "X2MouseDoubleClickAction"
    case over = "MouseOverAction"
    case leave = "MouseLeaveAction"
    case scrollUp = "MouseScrollUpAction"
    case scrollDown = "MouseScrollDownAction"
    case scrollLeft = "MouseScrollLeftAction"
    case scrollRight = "MouseScrollRightAction"
}

/// A mouse button, for mouse input that is not tied to a meter (`Plugin=Mouse`, see `Skin.pointerEvent(_:x:y:)`).
/// The raw value is AppKit's button number (0 left, 1 right, 2 middle, 3 and 4 the side buttons that Windows calls
/// X1 and X2).
public enum MouseButton: Int, CaseIterable {
    case left, right, middle, x1, x2

    /// `LeftMouseDownAction`, `RightMouseDownAction`…
    public var downKind: MouseEventKind {
        switch self {
        case .left: return .leftDown
        case .right: return .rightDown
        case .middle: return .middleDown
        case .x1: return .x1Down
        case .x2: return .x2Down
        }
    }

    public var upKind: MouseEventKind {
        switch self {
        case .left: return .leftUp
        case .right: return .rightUp
        case .middle: return .middleUp
        case .x1: return .x1Up
        case .x2: return .x2Up
        }
    }

    public var doubleClickKind: MouseEventKind {
        switch self {
        case .left: return .leftDoubleClick
        case .right: return .rightDoubleClick
        case .middle: return .middleDoubleClick
        case .x1: return .x1DoubleClick
        case .x2: return .x2DoubleClick
        }
    }
}

/// Mouse input a skin window receives, reported to `Skin.pointerEvent(_:x:y:)` for the measures that follow the mouse
/// themselves (`Plugin=Mouse`).
public enum PointerEvent: Equatable {
    /// A button went down on the skin; `doubleClick` for the second click of a double click.
    case pressed(MouseButton, doubleClick: Bool)
    /// A button went up, wherever the pointer is now (the release of a press that started on the skin).
    case released(MouseButton)
    /// The pointer moved while no button was down.
    case moved
    /// The pointer moved while a button was down (a press that started on the skin: also outside the window).
    case dragged
    /// One notch of the wheel: `.scrollUp`, `.scrollDown`, `.scrollLeft` or `.scrollRight`.
    case scrolled(MouseEventKind)
    /// The pointer left the skin window.
    case exited
}

/// The mouse input made outside a skin's window that its measures want now (`Skin.outsidePointerNeeds`): Plugin=Slider
/// sees the mouse anywhere on the screen. The host watches the mouse elsewhere only for what is asked here and reports
/// it through `Skin.outsidePointerEvent(_:x:y:)`. Mouse input only; nothing ever asks for keys.
public struct OutsidePointerNeeds: Equatable {
    /// Buttons whose presses and releases are wanted.
    public var buttons: Set<MouseButton> = []
    /// Buttons whose drags (moves while that button is down) are wanted.
    public var dragButtons: Set<MouseButton> = []
    /// Every move: without a button down, and the drags of any button.
    public var moves = false

    public init(buttons: Set<MouseButton> = [], dragButtons: Set<MouseButton> = [], moves: Bool = false) {
        self.buttons = buttons
        self.dragButtons = dragButtons
        self.moves = moves
    }

    public var isEmpty: Bool { buttons.isEmpty && dragButtons.isEmpty && !moves }

    /// Whether a drag while `pressed` is wanted.
    public func wantsDrag(pressed: Set<MouseButton>) -> Bool {
        moves || !dragButtons.isDisjoint(with: pressed)
    }

    public mutating func formUnion(_ other: OutsidePointerNeeds) {
        buttons.formUnion(other.buttons)
        dragButtons.formUnion(other.dragButtons)
        moves = moves || other.moves
    }
}

/// State of one mouse action on a meter or the `[Rainmeter]` section, set by the mouse action state bangs
/// (`!EnableMouseAction`, `!DisableMouseAction`, `!ClearMouseAction`, `!ToggleMouseAction` and their Group
/// variants). Manual (Bangs → Mouse Action state bangs):
/// - enabled: detected and executed normally;
/// - disabled: detected (it blocks meters / the skin behind it) but takes no action — like an action of `[]`;
/// - cleared: not detected at all, so actions behind it run — like an action of `""`.
/// The option values themselves are kept: enabling again restores the defined action.
public enum MouseActionState: Equatable {
    case enabled, disabled, cleared
}

/// Everything the host needs to show a meter's tooltip (manual: Meters → Tooltips).
public struct ToolTipInfo: Equatable {
    /// `ToolTipText` with `%1`, `%2`… replaced by the bound measures' values.
    public var text: String
    /// `ToolTipTitle` (one line).
    public var title: String
    /// `ToolTipIcon`: `Info`, `Warning`, `Error`, `Question`, `Shield` or a path to an icon file (empty = none).
    /// Only used with a title.
    public var icon: String
    /// `ToolTipType=1`: balloon tooltip.
    public var balloon: Bool
    /// `ToolTipWidth` (default 1000): maximum width before the text wraps.
    public var maxWidth: Double

    public init(text: String, title: String = "", icon: String = "", balloon: Bool = false, maxWidth: Double = 1000) {
        self.text = text
        self.title = title
        self.icon = icon
        self.balloon = balloon
        self.maxWidth = maxWidth
    }
}

/// One custom context menu entry (`ContextTitleN` / `ContextActionN` in `[Rainmeter]`).
public struct ContextMenuItem: Equatable {
    /// Title (at most 30 characters, longer titles end in `...`).
    public var title: String
    /// Action to execute (`Skin.execute(_:from:)` with `skin.rainmeterSection`); empty for separators.
    public var action: String
    /// A title made only of dashes when more than 3 items are given: drawn as a separator.
    public var isSeparator: Bool

    public init(title: String, action: String, isSeparator: Bool = false) {
        self.title = title
        self.action = action
        self.isSeparator = isSeparator
    }
}

public struct SkinScreen: Equatable {
    public var area: SkinRect
    public var workArea: SkinRect

    public init(area: SkinRect, workArea: SkinRect) {
        self.area = area
        self.workArea = workArea
    }
}

/// Facts about the world outside the skin that built-in variables expose.
public struct SkinEnvironment: Equatable {
    /// Current window frame (top-left origin, primary-screen coordinates).
    public var windowFrame: SkinRect
    /// Index 0 is the primary screen.
    public var screens: [SkinScreen]
    /// Folder for settings (trailing slash).
    public var settingsPath: String
    /// Folder of the running program (trailing slash).
    public var programPath: String
    /// `#CURRENTCONFIGZPOS#`: the skin's z-position (-2 on desktop … 2 stay topmost).
    public var zPosition: Int
    /// `#CONFIGEDITOR#`: the text editor used to edit skins (path of an app or executable).
    public var configEditor: String
    /// Index into `screens` of the monitor the skin is on, for `#SCREENAREAX#`-style variables without `@N`
    /// (manual: the primary monitor unless the skin auto-selects its screen). 0 = primary.
    public var currentScreen: Int

    public init(windowFrame: SkinRect = SkinRect(),
                screens: [SkinScreen] = [SkinScreen(area: SkinRect(width: 1920, height: 1080),
                                                    workArea: SkinRect(width: 1920, height: 1080))],
                settingsPath: String = NSTemporaryDirectory(),
                programPath: String = "/Applications/Deskset.app/",
                zPosition: Int = 0,
                configEditor: String = "/System/Applications/TextEdit.app",
                currentScreen: Int = 0) {
        self.windowFrame = windowFrame
        self.screens = screens
        self.settingsPath = settingsPath
        self.programPath = programPath
        self.zPosition = zPosition
        self.configEditor = configEditor
        self.currentScreen = currentScreen
    }
}

/// Implemented by the app: drawing, window-level bangs, text/image metrics.
public protocol SkinHost: AnyObject {
    /// Meters changed; redraw the window (and resize it to `skin.size`).
    func skinNeedsDisplay(_ skin: Skin)
    /// A bang the engine does not handle itself (window, config and app level bangs, or a bang whose Config
    /// argument names another skin). Return false when it is not supported.
    func skin(_ skin: Skin, handle bang: Bang) -> Bool
    /// A bang the engine handles itself but whose trailing Config argument names another skin. `bang` no longer
    /// contains that argument; the host should call `perform(_:)` on the target skin.
    /// `config` is `*` for "all currently loaded skins" (manual: Bangs → Config parameter): the engine has already
    /// performed the bang on `skin` itself, so the host should perform it on every *other* active skin.
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String)
    /// `["https://…"]`, `["file.txt"]`, `[program args]`.
    func skin(_ skin: Skin, execute target: String, arguments: [String])
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel)
    /// Size of `text` drawn with `style` in `skin` (in skin points), wrapped to `wrapWidth` when given. Asked on the
    /// skin's owner while it lays out its meters; the skin is named so that the host can measure with that skin's
    /// own text layouts, the ones it then draws (a host may serve several skins).
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double)
    /// Pixel size of the image file at `path`, or nil when it cannot be loaded.
    func imageSize(atPath path: String) -> (width: Double, height: Double)?
    func environment(for skin: Skin) -> SkinEnvironment
    /// Lua `SKIN:FadeWindow(from, to)` (alpha 0…255): animate the window from `from` to `to` over the skin's
    /// FadeDuration without changing its saved AlphaValue. Return false when the host cannot, and the engine applies
    /// `!SetTransparency to` instead (the default).
    func skin(_ skin: Skin, fadeWindowFrom from: Int, to: Int) -> Bool
    /// `skin.outsidePointerNeeds` changed (a Plugin=Slider measure was loaded, enabled, disabled, changed or closed):
    /// the host watches the mouse outside the skin window while it is not empty, and only then. Hosts that draw skins
    /// off screen (the default) watch nothing.
    func skinOutsidePointerNeedsChanged(_ skin: Skin)
    /// Whether the skin window gets the mouse now: shown, and not letting the mouse through (ClickThrough, OnHover=Hide
    /// while hovered). While it does, it reports the pointer over the skin itself (`Skin.pointerEvent`); while it does
    /// not, a move over the skin's area is input from elsewhere (`Skin.outsidePointerEvent`). Asked at the time of the
    /// move, so a window hidden or made click-through in the middle of a hover never keeps such moves away. Default
    /// true.
    func skinWindowTakesPointer(_ skin: Skin) -> Bool
}

extension SkinHost {
    public func skin(_ skin: Skin, fadeWindowFrom from: Int, to: Int) -> Bool { false }
    public func skinOutsidePointerNeedsChanged(_ skin: Skin) {}
    public func skinWindowTakesPointer(_ skin: Skin) -> Bool { true }
}
