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

    /// Loads the skin and starts it (`SkinRuntime.start(_:)`): its fonts, the window defaults of a first load, the
    /// counter of the skin it replaces, the first update, the update clock and, when the window is to be shown, the
    /// first frame. The runtime then reports `.started` or `.failed`.
    case load(SkinLoadOrder)
    /// The first update, then the update clock (a skin loaded at once: `SkinWindowController.start(fadeIn:)`).
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
    /// The update clock stops and the skin closes (`Skin.close`: OnCloseAction), then reports `.closed`. The window
    /// fades out when `fadeOut`.
    case close(fadeOut: Bool)

    // MARK: Window companions

    /// What the person typed into InputText's box `id` (nil: they dismissed it): the measure's answer runs here.
    case inputTextAnswered(id: Int, text: String?)

    // MARK: Frames

    /// The window is about to be shown: its first frame now, if no frame was presented yet (`SkinFrameProducer`).
    case firstFrame
    /// The window wants its frame again at the end of the turn (its content went to a new panel).
    case frameWanted
}

/// A bang the engine left to its host (`SkinHost.skin(_:handle:)`), as the runtime hands it to the main thread.
struct HostBang {
    var bang: Bang
    /// The hops of the work that sent it.
    var hops: Int
    /// Sent while the skin's OnCloseAction runs: then the skin cannot reload or unload itself.
    var whileClosing: Bool
}

/// What `SkinMessage.load` needs from the main thread: the config's window settings as the app has them, and what
/// kind of load it is.
struct SkinLoadOrder {
    /// The config's window settings (`AppState`): on a first load the skin's Default… options go on top of them.
    var state: SkinState
    /// No settings were saved for the config before: the skin's `Default…` options in `[Rainmeter]` seed them.
    var firstLoad: Bool
    /// The runtime of the skin this one replaces (a refresh): the Calc `Counter` goes on from the snapshot it published
    /// when it closed.
    var continuing: SkinRuntime?
    /// The app shows windows (not headless): then the first frame is drawn before `.started`, unless the skin starts
    /// hidden.
    var presentsWindows: Bool
    /// The app's skins are paused (sleep, locked screens): the skin loads and makes its first update, but its clock
    /// waits for a resume.
    var paused: Bool
}

/// What a runtime reports once its skin loaded and made its first update (`SkinRequest.started`).
struct SkinStartReport {
    /// The window size for the skin's size after its first update (points).
    var size: CGSize
    /// The skin's `Default…` window options (`SkinSettings.windowDefaults`), read on a first load; empty otherwise.
    var windowDefaults: [String: String]
    /// Whether the window stays hidden: StartHidden, unless the skin's first update showed it (`!Show`), or hidden by
    /// the skin itself (`!Hide`).
    var hidden: Bool
    /// The skin registered fonts of its own (`@Resources/Fonts`): skins laid out before are measured again.
    var registeredFonts: Bool
    /// The compatibility notes loading found.
    var issues: [String]
    /// `[Metadata]`.
    var metadata: [String: String]
}

/// A request from a runtime to the main thread. Applied in the order the runtime made them.
enum SkinRequest {
    /// The skin loaded and made its first update (`SkinMessage.load`): the main thread places and shows the window.
    case started(SkinStartReport)
    /// The skin could not be loaded (the error, as text): the main thread unloads it.
    case failed(String)
    /// The skin closed (`SkinMessage.close`): OnCloseAction has run.
    case closed
    /// The skin's size changed: the window follows (points; the top-left corner stays). Its frames go to the content
    /// provider from the skin's executor.
    case resize(CGSize)
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
    /// A window companion: FrostedGlass's backdrop, InputText's box (`SkinWindowCompanions`).
    case companion(SkinCompanionRequest)
    /// The skin published a snapshot in which something the main thread acts on changed (`SkinSnapshotChanges`): the
    /// tooltip areas, the compatibility notes, what it wants of the mouse outside its window… Posted only then.
    case snapshotChanged(SkinSnapshotChanges)
}

/// What a window companion on the main thread is asked to do, with the values it needs (`SkinWindowCompanions`).
enum SkinCompanionRequest {
    /// FrostedGlass's backdrop behind the window, in `style`, for the measure `owner` (nil: that measure let go of it).
    case frostedGlass(owner: Int, style: FrostedGlassStyle?)
    /// InputText's box `id` over the window, for a skin of `skinSize` points; its answer comes back as
    /// `SkinMessage.inputTextAnswered`.
    case showInputText(id: Int, settings: InputTextSettings, skinSize: CGSize)
    /// The box `id` closes without an answer (its measure went, or asked again).
    case cancelInputText(id: Int)
}

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
}
