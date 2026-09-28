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
// Every skin of the app runs on the main executor so far, so all of it happens inline and in the same order as before.
// Bangs for other skins go straight to their runtimes (`SkinDirectory`), under the same rule.

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

    /// A bang another skin sent (by name, `*` or its skin group; a bang the app passes on for it): a window bang goes
    /// to the window model, any other to the skin (`Skin.performSent`). `hops`: how many skins it passed through; the
    /// runtime's own bangs for other skins count from there.
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

    /// What the main thread did with the window (`SkinWindowModel.take`). A later one waiting behind takes its place.
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

/// A bang the engine left to its host (`SkinHost.skin(_:handle:)`), as the runtime hands it to the main thread.
struct HostBang {
    var bang: Bang
    /// The hops of the work that sent it.
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
    /// One of the skin's own window changes (position, Z position, transparency, the window flags, !Show / !Hide), made
    /// in its window model already (`SkinWindowModel`): the main thread does the same to `AppState` and the panel.
    case window(SkinWindowChange)
    /// Lua `SKIN:FadeWindow(from, to)` (0…255).
    case fadeWindow(from: Int, to: Int)
    /// Bangs that load, unload or refresh skins, or quit (they run on a later turn, `AppController.later`).
    case lifecycle(HostBang)
    /// Menus and windows: !SkinMenu, !SkinCustomMenu, !TrayMenu, !Manage, !About, !EditSkin.
    case ui(HostBang)
    /// The system: the clipboard, the desktop picture, sounds. Paths are absolute already.
    case system(HostBang)
    /// `["https://…"]`, `["file.txt"]`, `["App.app" "file"]`.
    case open(SkinExecutePlan)
    /// A bang for another config that the skin could not hand to it itself (`SkinDirectory`): the config is loading
    /// (it follows the load), or not running. `*`: every other running skin (a runtime without a directory). With the
    /// sender's hops.
    case forward(Bang, toConfig: String, hops: Int)
    /// A window companion (FrostedGlass's backdrop, InputText's box): step 5 of phase 2 moves them here.
    case companion(SkinCompanionRequest)
    /// The skin published a snapshot in which something the main thread acts on changed (`SkinSnapshotChanges`): the
    /// tooltip areas, the compatibility notes, what it wants of the mouse outside its window… Posted only then.
    case snapshotChanged(SkinSnapshotChanges)
}

/// What a window companion is asked to do (none yet: FrostedGlass and InputText still reach their window directly).
enum SkinCompanionRequest {}

/// The main-thread side of a runtime: the skin's window (`SkinWindowController`), or a self-test's stand-in.
protocol SkinRuntimeWindow: AnyObject {
    /// Applies a request (main thread).
    func apply(_ request: SkinRequest, from runtime: SkinRuntime)
    /// Runs `body`, in which the skin's window bangs are applied, as one batch: the windows are stacked again and the
    /// app hears of changed settings once, at the end (main thread).
    func batchingWindowChanges(_ body: () -> Void)
    /// Debug builds: the environment the live window gives now, which the window model's must equal while the skin runs
    /// on the main executor (nil: nothing to compare, as while a skin's move waits for a drag to end). Main thread.
    func liveEnvironment(for skin: Skin) -> SkinEnvironment?
    /// Debug builds: whether the live window takes the pointer, which the published facts must say (nil: nothing to
    /// compare). Main thread.
    var liveTakesPointer: Bool? { get }
    /// The screen the window is on (`LiveSkinHost.windowScreen`; main thread).
    var screen: NSScreen? { get }
}
