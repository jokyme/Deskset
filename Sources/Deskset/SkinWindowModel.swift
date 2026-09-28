import AppKit
import DesksetCore

// A skin's window as its runtime sees it (docs/skin-threading.md §8.1). The runtime keeps a model of the window —
// where it is, its Z position, transparency, flags and whether a bang hid it — so that everything the skin reads
// afterwards (`#CURRENTCONFIGX#` in the next bang or update, the KeepOnScreen clamp, AutoSelectScreen's monitor) sees
// what its own window bangs did at once, even before the main thread has moved the window:
// - The skin's own window bangs (!Move, !SetWindowPosition, !ZPos, !SetTransparency, !Show / !Hide / !Toggle and their
//   Fade forms, the flag bangs, !FadeDuration, !AutoSelectScreen) change the model synchronously (`apply`), then ask
//   the main thread to do the same (`SkinRequest.window(SkinWindowChange)`), in order.
// - The main thread applies the change to `AppState` and the panel and publishes what it really did
//   (`SkinWindowFacts`), as it does after every change of its own: a drag, the menus, the Manage window, a screen
//   change, the window shown or hidden. The model takes the facts once they include its latest change: the last writer
//   wins.
// - While a press on the skin may drag the window, the skin's moves wait for the release; a press that became a drag
//   wins.

/// A Lua `SKIN:FadeWindow` override: the alpha (0…255) the window was faded to, and the saved AlphaValue it stands in
/// for. It is not saved: a refresh, or any change of the saved AlphaValue, ends it.
struct SkinFadedAlpha: Equatable {
    var value: Int
    var base: Int
}

/// The window settings that a skin's bangs change and the app changes too (the menus, the Manage window, the first
/// load's Default… options): the per-config values of `AppState` its window follows, !Hide / !Show and a Lua
/// FadeWindow.
struct SkinWindowSettings: Equatable {
    /// `AlwaysOnTop` (-2 on desktop … 2 stay topmost): `#CURRENTCONFIGZPOS#`.
    var zPosition: Int
    var alphaValue: Int
    var fadedAlpha: SkinFadedAlpha?
    /// Hidden with !Hide / !HideFade (or StartHidden).
    var hidden: Bool
    var draggable: Bool
    var clickThrough: Bool
    var keepOnScreen: Bool
    var snapEdges: Bool
    var savePosition: Bool
    var fadeDuration: Int
    var autoSelectScreen: Bool

    /// The settings of a config nobody changed.
    init() {
        self.init(SkinState(file: ""), hidden: false, fadedAlpha: nil)
    }

    init(_ state: SkinState, hidden: Bool, fadedAlpha: SkinFadedAlpha?) {
        zPosition = state.alwaysOnTop
        alphaValue = state.alphaValue
        self.fadedAlpha = fadedAlpha
        self.hidden = hidden
        draggable = state.draggable
        clickThrough = state.clickThrough
        keepOnScreen = state.keepOnScreen
        snapEdges = state.snapEdges
        savePosition = state.savePosition
        fadeDuration = state.fadeDuration
        autoSelectScreen = state.autoSelectScreen
    }
}

/// What the main thread did with a skin's window, for its runtime: published after every change the main thread makes
/// or applies (`SkinWindowController.publishFacts`), in order.
struct SkinWindowFacts: Equatable {
    /// The window's frame (AppKit screen coordinates).
    var frame: CGRect
    /// The window's screen in `NSScreen.screens`, when it has one.
    var screen: Int?
    /// Whether any part of the window can be seen (occlusion).
    var isVisible: Bool
    /// Whether the window is on screen at all (ordered in).
    var isOrderedIn: Bool
    /// The backing scale factor of the window's screen.
    var scale: CGFloat
    /// The window's color space.
    var colorSpace: CGColorSpace?
    /// The appearance the skin's view has (`NSAppearance.Name`).
    var appearance: String
    /// Whether the window takes the pointer: shown and not letting it through (`SkinHost.skinWindowTakesPointer`).
    var takesPointer: Bool
    /// The window settings as the main thread has them.
    var settings: SkinWindowSettings
    /// The last of the skin's own window changes (`SkinWindowChange.sequence`) that `frame` and `settings` include.
    var modelSequence: Int
    /// Counts the facts the main thread published for this window.
    var sequence: Int

    init(frame: CGRect, screen: Int? = nil, isVisible: Bool, isOrderedIn: Bool = false, scale: CGFloat,
         colorSpace: CGColorSpace? = nil, appearance: String = NSAppearance.Name.aqua.rawValue, takesPointer: Bool,
         settings: SkinWindowSettings = SkinWindowSettings(), modelSequence: Int = 0, sequence: Int) {
        self.frame = frame
        self.screen = screen
        self.isVisible = isVisible
        self.isOrderedIn = isOrderedIn
        self.scale = scale
        self.colorSpace = colorSpace
        self.appearance = appearance
        self.takesPointer = takesPointer
        self.settings = settings
        self.modelSequence = modelSequence
        self.sequence = sequence
    }

    /// The same facts, whatever their sequence numbers.
    func hasSameValues(as other: SkinWindowFacts) -> Bool {
        var a = self, b = other
        a.sequence = 0
        b.sequence = 0
        return a == b
    }
}

/// A setting a flag bang switches.
enum SkinWindowFlag: Equatable {
    case draggable, clickThrough, keepOnScreen, snapEdges, autoSelectScreen

    var state: WritableKeyPath<SkinState, Bool> {
        switch self {
        case .draggable: return \.draggable
        case .clickThrough: return \.clickThrough
        case .keepOnScreen: return \.keepOnScreen
        case .snapEdges: return \.snapEdges
        case .autoSelectScreen: return \.autoSelectScreen
        }
    }

    var setting: WritableKeyPath<SkinWindowSettings, Bool> {
        switch self {
        case .draggable: return \.draggable
        case .clickThrough: return \.clickThrough
        case .keepOnScreen: return \.keepOnScreen
        case .snapEdges: return \.snapEdges
        case .autoSelectScreen: return \.autoSelectScreen
        }
    }
}

/// What a skin's window bang asks of the main thread, with the values the runtime worked out.
enum SkinWindowOperation: Equatable {
    /// !Move, !SetWindowPosition: the window's new frame (AppKit coordinates), kept on screen with KeepOnScreen.
    case move(CGRect)
    /// !ZPos.
    case zPosition(Int)
    /// !SetTransparency (it also ends a Lua FadeWindow).
    case alpha(Int)
    /// !Draggable, !ClickThrough, !KeepOnScreen, !SnapEdges, !AutoSelectScreen.
    case flag(SkinWindowFlag, Bool)
    /// !FadeDuration (milliseconds).
    case fadeDuration(Int)
    /// !Show, !Hide, !Toggle (`fade`: their Fade forms).
    case hidden(Bool, fade: Bool)
}

/// One of a skin's own window changes, for the main thread (`SkinRequest.window`).
struct SkinWindowChange {
    /// The bang that made it (its name).
    var bang: String
    var operation: SkinWindowOperation
    /// The model after the change.
    var model: SkinWindowModel
    /// The model's sequence number after the change.
    var sequence: Int
}

/// What the skin believes its window is: on the skin's executor, owned by its runtime.
struct SkinWindowModel {
    /// The window's frame (AppKit screen coordinates); nil until the window told it (a runtime without a window: the
    /// skin's environment then has the skin's own size at 0,0, as the engine's default).
    var frame: CGRect?
    var settings = SkinWindowSettings()
    /// The facts last taken.
    private(set) var facts: SkinWindowFacts?
    /// Counts the skin's own window changes.
    private(set) var sequence = 0

    /// The window takes the pointer (true until the window said otherwise).
    var takesPointer: Bool { facts?.takesPointer ?? true }

    /// The facts the main thread published. Their frame and settings replace the model's once they include the model's
    /// latest change (the last writer wins); until then the model keeps what the skin did (the main thread applies it
    /// after what it published). Older facts than those taken are ignored.
    mutating func take(_ facts: SkinWindowFacts) {
        if let taken = self.facts, facts.sequence <= taken.sequence { return }
        self.facts = facts
        guard facts.modelSequence >= sequence else { return }
        frame = facts.frame
        settings = facts.settings
    }

    /// The skin's size changed: the window follows it with its top-left corner fixed, kept on screen when it is shown
    /// with KeepOnScreen (as the main thread does).
    mutating func resize(to size: CGSize, screens: [WindowGeometry.Screen]) {
        guard let old = frame, old.size != size else { return }
        var f = CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        if settings.keepOnScreen && facts?.isOrderedIn == true { f = WindowGeometry.keptOnScreen(f, screens: screens) }
        frame = f
    }

    /// Does what a window bang for this skin does to the model (its Config argument taken off: `SkinWindowBangs`) and
    /// returns what the main thread is to do; nil when the bang changes nothing (a position that cannot be read, a bang
    /// that is not a window bang). `screens` are the store's (`EnvironmentStore`).
    mutating func apply(_ bang: Bang, screens: [WindowGeometry.Screen]) -> SkinWindowChange? {
        guard let operation = operation(for: bang, screens: screens) else { return nil }
        sequence += 1
        return SkinWindowChange(bang: bang.name, operation: operation, model: self, sequence: sequence)
    }

    private mutating func operation(for bang: Bang, screens: [WindowGeometry.Screen]) -> SkinWindowOperation? {
        let a = bang.args
        func arg(_ i: Int) -> String { i < a.count ? a[i].trimmingCharacters(in: .whitespaces) : "" }
        func setFlag(_ flag: SkinWindowFlag) -> SkinWindowOperation {
            let value = SkinVisibility.flag(arg(0), current: settings[keyPath: flag.setting])
            settings[keyPath: flag.setting] = value
            return .flag(flag, value)
        }
        func setHidden(_ hidden: Bool, fade: Bool) -> SkinWindowOperation {
            settings.hidden = hidden
            return .hidden(hidden, fade: fade)
        }
        switch bang.name {
        case "move":
            guard let x = OptionValue.number(arg(0)), let y = OptionValue.number(arg(1)) else { return nil }
            return move(x: x, y: y, screens: screens)
        case "setwindowposition":
            // !SetWindowPosition WindowX WindowY [AnchorX AnchorY]
            let anchor = a.count >= 4 ? (arg(2), arg(3)) : ("0", "0")
            guard let p = WindowPosition.resolve(x: arg(0), y: arg(1), anchorX: anchor.0, anchorY: anchor.1,
                                                 skinSize: currentFrame.size, screens: screens) else { return nil }
            return move(x: p.x, y: p.y, screens: screens)
        case "zpos":
            let value = min(max(OptionValue.int(arg(0)) ?? 0, -2), 2)
            settings.zPosition = value
            return .zPosition(value)
        case "settransparency":
            let value = min(max(OptionValue.int(arg(0)) ?? 255, 0), 255)
            settings.alphaValue = value
            settings.fadedAlpha = nil
            return .alpha(value)
        case "draggable": return setFlag(.draggable)
        case "clickthrough": return setFlag(.clickThrough)
        case "keeponscreen":
            let operation = setFlag(.keepOnScreen)
            // The window is kept on screen at once.
            if settings.keepOnScreen { frame = WindowGeometry.keptOnScreen(currentFrame, screens: screens) }
            return operation
        case "snapedges": return setFlag(.snapEdges)
        case "autoselectscreen":
            // Positions are kept in desktop coordinates whatever the setting; it decides which monitor the monitor
            // variables without @N refer to (`EnvironmentStore.environment`).
            return setFlag(.autoSelectScreen)
        case "show": return setHidden(false, fade: false)
        case "hide": return setHidden(true, fade: false)
        case "toggle": return setHidden(!settings.hidden, fade: false)
        case "showfade": return setHidden(false, fade: true)
        case "hidefade": return setHidden(true, fade: true)
        case "togglefade": return setHidden(!settings.hidden, fade: true)
        case "fadeduration":
            let v = OptionValue.number(arg(0)) ?? 250
            let ms = v.isFinite ? Int(min(max(v, 0), Double(SkinState.maxFadeDuration))) : 250
            settings.fadeDuration = ms
            return .fadeDuration(ms)
        default:
            return nil
        }
    }

    /// The frame, or the one a window has before it is placed.
    private var currentFrame: CGRect { frame ?? CGRect(x: 0, y: 0, width: 1, height: 1) }

    /// The window's top-left corner goes to (x, y) (skin coordinates, clamped to ±1e6 like the saved positions), kept on
    /// screen with KeepOnScreen.
    private mutating func move(x: Double, y: Double, screens: [WindowGeometry.Screen]) -> SkinWindowOperation? {
        guard x.isFinite, y.isFinite else { return nil }
        let limit = SkinState.maxPosition
        var f = WindowGeometry.frame(topLeftX: min(max(x, -limit), limit), y: min(max(y, -limit), limit),
                                     size: currentFrame.size, primaryHeight: WindowGeometry.primaryHeight(screens))
        if settings.keepOnScreen { f = WindowGeometry.keptOnScreen(f, screens: screens) }
        frame = f
        return .move(f)
    }
}

/// Which skins a window bang names (docs/skin-threading.md §8.1, §8.2), and the bang each of them applies to its own
/// window: its Config argument, or the group of a Group form, taken off.
enum SkinWindowBangs {
    enum Targets: Equatable {
        /// The skin that performs it.
        case own
        /// A config by name (normalized), or `*`: every running skin, in load order.
        case config(String)
        /// The skins of a skin group (`Group=` in `[Rainmeter]`), in load order.
        case group(String)
    }

    /// The targets of a window bang and the bang each target applies; nil for other bangs. Manual: skin bangs take an
    /// optional trailing Config ("the config name of a currently loaded skin … or * (asterisk) to act on all currently
    /// loaded skins … defaults to the current config"); the Group forms name a group instead.
    static func targets(of bang: Bang) -> (targets: Targets, member: Bang)? {
        let a = bang.args
        func configTarget(_ index: Int?) -> (Targets, Bang) {
            guard let index, index < a.count else { return (.own, bang) }
            let member = Bang(name: bang.name, args: Array(a.prefix(index)))
            let name = SkinLibrary.normalizedConfigName(a[index].trimmingCharacters(in: .whitespaces))
            return (name.isEmpty ? .own : .config(name), member)
        }
        func groupTarget(_ index: Int) -> (Targets, Bang) {
            let group = index < a.count ? a[index].trimmingCharacters(in: .whitespaces) : ""
            return (.group(group), Bang(name: String(bang.name.dropLast("group".count)), args: Array(a.prefix(index))))
        }
        switch bang.name {
        case "move":
            return configTarget(2)
        case "setwindowposition":
            // !SetWindowPosition WindowX WindowY [AnchorX AnchorY] [Config]
            return configTarget(a.count >= 5 ? 4 : (a.count == 3 ? 2 : nil))
        case "zpos", "settransparency", "draggable", "clickthrough", "keeponscreen", "snapedges", "autoselectscreen",
             "fadeduration":
            return configTarget(1)
        case "show", "hide", "toggle", "showfade", "hidefade", "togglefade":
            return configTarget(0)
        case "zposgroup", "settransparencygroup", "draggablegroup", "clickthroughgroup", "keeponscreengroup",
             "snapedgesgroup", "autoselectscreengroup", "fadedurationgroup":
            return groupTarget(1)
        case "showgroup", "hidegroup", "togglegroup", "showfadegroup", "hidefadegroup", "togglefadegroup":
            return groupTarget(0)
        default:
            return nil
        }
    }
}
