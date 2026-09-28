import AppKit
import DesksetCore

// What crosses between a skin's two halves (docs/skin-threading.md §5.4): messages from the main thread (or another
// skin) to the runtime, which owns the `Skin` on its executor, and requests from the runtime to the main thread, which
// owns the window. Delivery:
// - `SkinRuntime.send` runs a message at once when the sender is on the runtime's executor, and hands back what the
//   skin answered; otherwise it queues it there, first in, first out (a hover or the window facts that follow the same
//   kind still waiting take its place).
// - `SkinRuntime.request` applies a request at once on the main thread; from any other thread it queues it with
//   `DispatchQueue.main.async`, the queue of `AppController.later`, so requests keep their order.
// Every skin runs on the main executor so far, so all of it happens inline and in the same order as before.

/// A message to a skin's runtime: input, actions, the window's facts and the skin's life.
enum SkinMessage {
    // MARK: Input

    /// A mouse action at a skin point (`Skin.mouseEvent`). The answer: whether it was handled.
    case mouse(MouseEventKind, x: Double, y: Double)
    /// A press whose release is not a click (the skin was dragged): a pressed Button goes back (`Skin.cancelMousePress`).
    case pressCancelled
    /// One wheel notch: `Plugin=Mouse` measures first (`Skin.pointerEvent`), then the mouse action. The answer: whether
    /// the action was handled.
    case scroll(MouseEventKind, x: Double, y: Double)
    /// Pointer input over the skin's window for `Plugin=Mouse` measures (`Skin.pointerEvent`).
    case pointer(PointerEvent, x: Double, y: Double)
    /// Pointer input elsewhere on the screen for `Plugin=Slider` measures (`Skin.outsidePointerEvent`).
    case outsidePointer(PointerEvent, x: Double, y: Double)
    /// The pointer moved over the skin (`Skin.mouseMoved`).
    case hover(x: Double, y: Double)
    /// The pointer left the skin (`Skin.mouseExited`).
    case exited
    /// The skin's window became key or stopped being key (`Skin.focusChanged`).
    case focus(Bool)

    // MARK: Actions

    /// A bang another skin sent (`Skin.performSent`), or one the app sends for a skin group. `hops`: how many skins
    /// it passed through; the runtime's own forwards count from there.
    case bang(Bang, from: String, hops: Int)
    /// An action run for the person from a section (by name): a context menu item (`Skin.executeInput`).
    case execute(String, section: String?)

    // MARK: The Studio

    /// Option and variable values shown without writing them (`Skin.previewVariables`, then `Skin.preview`).
    case preview(sections: [(section: String, values: [String: String])], variables: [String: String])
    /// Previews end (`Skin.endPreview`).
    case endPreview
    /// Where the skin tells of the input it took (`Skin.inputMirror`; nil: nowhere).
    case mirrorInput(((SkinInput) -> Void)?)

    // MARK: The window

    /// What the window really is (step 3 of phase 2 fills it in and reads it).
    case windowFacts(SkinWindowFacts)

    // MARK: Life

    /// The first update, then the update clock.
    case start
    /// An update now (`!UpdateGroup`), with the hops of the bang that asked for it.
    case update(hops: Int)
    /// `Skin.redraw` (`!RedrawGroup`).
    case redraw
    /// Sleep, screens asleep, the session switched away: the update clock stops.
    case pause
    /// The clock starts again; `updateNow`: with an update at once (not for `Update=-1` skins).
    case resume(updateNow: Bool)
    /// The Mac woke from sleep (`Skin.systemDidWake`), then an update (and the clock again when it was paused).
    case wake
    /// Fonts were registered or removed: text is measured again (`Skin.fontsDidChange`).
    case fontsChanged
    /// The appearance or a regional setting changed (`Skin.appearanceDidChange`).
    case appearanceChanged
    /// The update clock stops and the skin closes (`Skin.close`: OnCloseAction). The window fades out when `fadeOut`.
    case close(fadeOut: Bool)
}

/// What the main thread did with a skin's window, for the runtime (docs/skin-threading.md §8.1). Nothing publishes it
/// yet: step 3 of phase 2 echoes every window change in it.
struct SkinWindowFacts: Equatable {
    /// The window's frame (AppKit screen coordinates).
    var frame: CGRect
    /// The window's screen in the list of screens, when known.
    var screen: Int?
    /// Whether any part of the window can be seen (occlusion).
    var isVisible: Bool
    /// The backing scale factor of the window's screen.
    var scale: CGFloat
    /// Whether the window takes the pointer: shown and not letting it through (`SkinHost.skinWindowTakesPointer`).
    var takesPointer: Bool
    /// Counts the window changes, so the runtime can tell which of its own it has seen.
    var sequence: Int
}

/// A bang the engine left to its host (`SkinHost.skin(_:handle:)`), as the runtime hands it to the main thread.
struct HostBang {
    var bang: Bang
    /// The hops of the work that sent it: bangs the main thread passes on to other skins for it carry them.
    var hops: Int
    /// Sent while the skin's OnCloseAction runs: then the skin cannot reload or unload itself.
    var whileClosing: Bool
}

/// A request from a runtime to the main thread. Applied in the order the runtime made them.
enum SkinRequest {
    /// The skin changed what it shows: redraw its window, resized to `size` first (points; the top-left corner stays).
    case display(size: CGSize)
    /// Where the glass goes now (`MacGlass`), back to front, in skin points.
    case glass([GlassRegion])
    /// Window bangs for this skin or others: position, Z position, transparency, the window flags, !Show / !Hide.
    case window(HostBang)
    /// Lua `SKIN:FadeWindow(from, to)` (0…255).
    case fadeWindow(from: Int, to: Int)
    /// Bangs that load, unload or refresh skins, or quit (they run on a later turn, `AppController.later`).
    case lifecycle(HostBang)
    /// Bangs for the skins of a group: !UpdateGroup, !RedrawGroup, !SetVariableGroup, the skin group mouse bangs
    /// (step 3 of phase 2: the skin directory carries them).
    case group(HostBang)
    /// Menus and windows: !SkinMenu, !SkinCustomMenu, !TrayMenu, !Manage, !About, !EditSkin.
    case ui(HostBang)
    /// The system: the clipboard, the desktop picture, sounds. Paths are absolute already.
    case system(HostBang)
    /// `["https://…"]`, `["file.txt"]`, `["App.app" "file"]`.
    case open(SkinExecutePlan)
    /// A bang the engine performed, or `*`, for other skins (`SkinHost.skin(_:forward:toConfig:)`), with the sender's
    /// hops.
    case forward(Bang, toConfig: String, hops: Int)
    /// What the skin wants to hear of the pointer outside its window changed (`Plugin=Slider`).
    case outsidePointerNeedsChanged
    /// A window companion (FrostedGlass's backdrop, InputText's box): step 5 of phase 2 moves them here.
    case companion(SkinCompanionRequest)
    /// Something the main thread reads of the skin changed (step 2 of phase 2 posts it with the snapshot).
    case snapshotChanged
}

/// What a window companion is asked to do (none yet: FrostedGlass and InputText still reach their window directly).
enum SkinCompanionRequest {}

/// The main-thread side of a runtime: the skin's window (`SkinWindowController`), or a self-test's stand-in.
protocol SkinRuntimeWindow: AnyObject {
    /// Applies a request (main thread).
    func apply(_ request: SkinRequest, from runtime: SkinRuntime)
    /// `SkinHost.environment(for:)`, asked on the main thread (step 3 of phase 2: from the environment store and the
    /// window model instead).
    func environment(for skin: Skin) -> SkinEnvironment
    /// `SkinHost.skinWindowTakesPointer`, asked on the main thread.
    var takesPointer: Bool { get }
    /// The screen the window is on (`LiveSkinHost.windowScreen`; main thread).
    var screen: NSScreen? { get }
}
