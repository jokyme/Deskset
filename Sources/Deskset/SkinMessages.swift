import AppKit
import DesksetCore
import DesksetRuntime

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
    /// An action the widget runs on its own behalf, not as input another instance should follow (`Skin.execute`): the
    /// Studio's Interact running what its own instance held back.
    case run(String)

    // MARK: The Studio

    /// Option and variable values shown without writing them (`Skin.previewVariables`, then `Skin.preview`).
    case preview(sections: [(section: String, values: [String: String])], variables: [String: String])
    /// Previews end (`Skin.endPreview`).
    case endPreview
    /// Where the skin tells of the input it took (`Skin.inputMirror`; nil: nowhere).
    case mirrorInput(((SkinInput) -> Void)?)
    /// A step of the Studio as a patch of the running skin (`Skin.patch(sources:)`), from the text `sources` gives:
    /// `done` hears what it did and how long it took (milliseconds), on the skin's executor. A closed skin answers that
    /// it must be loaded again.
    case patch(SourceProvider, done: (SkinPatchResult, Double) -> Void)

    // MARK: The window

    /// What the main thread did with the window (`SkinWindowModel.take`). A later one waiting behind takes its place.
    case windowFacts(SkinWindowFacts)

    // MARK: Life

    /// Loads the skin and starts it (`SkinRuntime.start(_:)`): its fonts, the window defaults of a first load (then
    /// `.loaded`), the counter of the skin it replaces, the first update, the update clock and, when the window is to be
    /// shown, the first frame (then `.started`); `.failed` when the skin cannot be loaded.
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
    /// The update clock stops and the skin closes (`Skin.close`: OnCloseAction), then reports `.closed` with `ticket`
    /// (a reload the Studio asked for, which this close is part of). The window fades out when `fadeOut`.
    case close(fadeOut: Bool, ticket: SkinReloadTicket? = nil)

    // MARK: Window companions

    /// What the person typed into InputText's box `id` (nil: they dismissed it): the measure's answer runs here.
    case inputTextAnswered(id: Int, text: String?)
    /// The window's moves stopped for watch `id` (`SkinCompanionRequest.followWindow`): its measure hears it here.
    case windowSettled(id: Int)

    // MARK: Frames

    /// The window is about to be shown: its first frame now, if no frame was presented yet (`SkinFrameProducer`).
    case firstFrame
    /// The window wants its frame again at the end of the turn (its content went to a new panel).
    case frameWanted
    /// An already-released tree writer; owner metadata and deferred cleanup are finalized on the executor.
    case scenePatchFinished(SkinScenePatch)
    /// Explicit experimental native staging, never requested automatically by a C frame.
    case nativeStageRequested(SkinNativeStageRequest)
    /// Internal opt-in only; no capture/allocation in bitmap, C or Main mode.
    case nativeFramesRequested
    case nativeFramesReady(SkinNativeStage)
    case nativeStageAttached(SkinNativeStage)
    case nativeStageRelease(SkinNativeStage)
    case nativeStageDetached(SkinNativeStage)
    case nativeStagePublicationCommitted(SkinNativeStage, SkinNativeStageObservation)
    case nativeStageRolledBack(SkinNativeStage)
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
    /// A reload the Studio asked for, which this load is part of: it comes back with `.started` or `.failed`.
    var ticket: SkinReloadTicket? = nil
}

/// A reload of a widget that the Studio's editing session asked for (docs/skin-threading.md §8.5). It rides on the
/// reload: in the load order of the new copy and in the close of the old one, whose runtimes report it back
/// (`.started(ticket)` or `.failed(ticket)`, `.closed(ticket)`) whenever their work gets there. So the session knows the
/// copy that starts, and what the widget writes to its files meanwhile, as its own, however late and in whatever order
/// the reports come in.
struct SkinReloadTicket: Hashable, CustomStringConvertible {
    let id: Int

    /// Main thread.
    private static var last = 0

    /// A new ticket (main thread).
    static func next() -> SkinReloadTicket {
        last += 1
        return SkinReloadTicket(id: last)
    }

    var description: String { "reload #\(id)" }
}

/// What happened to a copy of a widget in a reload the Studio asked for (`SkinReloadTicket`), as the app tells the
/// widget's editing session (`AppController.studioReload`). Main thread.
enum SkinReloadEvent: Equatable {
    /// The old copy was sent `.close` with the ticket: its `.closed` is to come.
    case closing
    /// The old copy's OnCloseAction has run.
    case closed
    /// The new copy was made and sent `.load` with the ticket: its `.started` or `.failed` is to come.
    case loading
    /// The new copy made its first update (OnRefreshAction has run), and its window was placed and shown.
    case started
    /// The new copy could not be loaded.
    case failed
    /// The new copy was stopped before it started (a later reload replaced it, or it was unloaded): it will not report.
    case abandoned
}

/// What a runtime reports once its skin loaded, before its first update (`SkinRequest.loaded`).
struct SkinLoadReport {
    /// The skin's `Default…` window options (`SkinSettings.windowDefaults`), read on a first load; empty otherwise. The
    /// runtime seeded its window model with them already.
    var windowDefaults: [String: String]
    /// The skin registered fonts of its own (`@Resources/Fonts`): skins laid out before are measured again.
    var registeredFonts: Bool
    /// The compatibility notes loading found.
    var issues: [String]
}

/// What a runtime reports once its skin made its first update (`SkinRequest.started`).
struct SkinStartReport {
    /// The window size for the skin's size after its first update (points).
    var size: CGSize
    /// `[Metadata]`.
    var metadata: [String: String]
    /// The reload the load order carried (`SkinLoadOrder.ticket`).
    var ticket: SkinReloadTicket? = nil
}

/// A request from a runtime to the main thread. Applied in the order the runtime made them.
enum SkinRequest {
    case attachNativeStage(SkinNativeStage)
    case nativeStageCompleted(SkinNativeStage, SkinNativeStageResult)
    case nativeStageReleased(SkinNativeStage)
    case nativeStageRejected(SkinNativeStageRequest, SkinNativeStageFailure)
    case nativeStagePublicationFinished(SkinNativeStage, SkinNativeStageResult)
    case nativeStageRollback(SkinNativeStage, SkinNativeStageFailure)
    case nativeStageCallbackFailed(SkinNativeStage, SkinNativeStageFailure)
    /// A finished owner C root awaits main attachment. No live owner or stale panel is carried by this request.
    case installLayerContent
    /// Completed C values with an authentic tree-only writer capability, never a live drawing owner.
    case scenePatch(SkinScenePatch)
    /// A completed ordinary frame publishes its immutable hit map without any drawing on main.
    case layerHitMap(SkinHitMap, generation: UInt64, panelGeneration: UInt64)
    /// The skin loaded (`SkinMessage.load`): the main thread saves a first load's Default… settings, StartHidden and
    /// the window settings apply, before the window is placed.
    case loaded(SkinLoadReport)
    /// The skin made its first update: the main thread places and shows the window.
    case started(SkinStartReport)
    /// The skin could not be loaded (the error, as text): the main thread unloads it. With the load order's ticket.
    case failed(String, ticket: SkinReloadTicket? = nil)
    /// The skin closed (`SkinMessage.close`): OnCloseAction has run. With the close's ticket.
    case closed(SkinReloadTicket? = nil)
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
    /// The window's moves, changes of screen and of the displays' arrangement are followed for watch `id`
    /// (`WindowMoveWatch`, Chameleon's `CropDesktop=Skin`): once they stop, `SkinMessage.windowSettled` comes back.
    case followWindow(id: Int)
    /// Watch `id` ends (its measure closed).
    case stopFollowingWindow(id: Int)
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

/// The AppKit portion of a captured scene. Panel and presentation generations are separate from facts sequence.
final class SkinScenePatch {
    let content: ScenePatch
    let panelGeneration: UInt64
    let generation: UInt64
    let size: CGSize
    /// Original draw start: frame presentation elapsed time includes the handoff wait, never CPU time.
    let began: TimeInterval
    let glass: [GlassRegion]
    let hitMap: SkinHitMap
    private let lock = NSLock()
    private var hostAck = HostAcknowledgment.none

    init(content: ScenePatch, panelGeneration: UInt64, generation: UInt64, size: CGSize, began: TimeInterval,
         glass: [GlassRegion], hitMap: SkinHitMap) {
        self.content = content
        self.panelGeneration = panelGeneration
        self.generation = generation
        self.size = size
        self.began = began
        self.glass = glass
        self.hitMap = hitMap
    }

    var hostAcknowledgment: HostAcknowledgment {
        lock.lock()
        defer { lock.unlock() }
        return hostAck
    }

    func acknowledgeHost(_ value: HostAcknowledgment) {
        precondition(Thread.isMainThread)
        lock.lock()
        hostAck = value
        lock.unlock()
    }
}

extension SkinScenePatch {
    enum HostAcknowledgment: Equatable { case none, controls, complete }
}

enum SkinNativeStageFailure: Error, Equatable {
    case unsupportedMode, unsupportedExecutor, notReady, busy, cancelled, staleDestination, attachmentTimedOut
    case rendering(String)
}

/// Finite metadata from a scoped observation or an acknowledged explicit Single publication. It grants no access
/// to a layer, owner, cache or reusable ready frame, and never enables automatic every-frame E rendering.
struct SkinNativeStageObservation {
    let sourceSequence: UInt64
    let native: ELayerContent.Observation
    let drewOnPhysicalOwner: Bool
    let published: Bool

    init(sourceSequence: UInt64, native: ELayerContent.Observation, drewOnPhysicalOwner: Bool, published: Bool = false) {
        self.sourceSequence = sourceSequence
        self.native = native
        self.drewOnPhysicalOwner = drewOnPhysicalOwner
        self.published = published
    }
}
typealias SkinNativeStageResult = Result<SkinNativeStageObservation, SkinNativeStageFailure>

final class SkinNativeStageRequest {
    let maximumCallbackBitmapBytes: Int
    let publishesContent: Bool
    let nativePartition: LayerRuntime.NativePartition
    var publishesSingle: Bool { publishesContent && nativePartition == .single }
    let continuesFrames: Bool
    private let completion: (SkinNativeStageResult) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false

    init(maximumCallbackBitmapBytes: Int, publishesSingle: Bool = false, continuesFrames: Bool = false,
         completion: @escaping (SkinNativeStageResult) -> Void) {
        self.maximumCallbackBitmapBytes = maximumCallbackBitmapBytes
        self.publishesContent = publishesSingle
        nativePartition = .single
        self.continuesFrames = continuesFrames
        self.completion = completion
    }

    /// Publication intent and native plan are separate from the attachment's executor permissions.
    init(maximumCallbackBitmapBytes: Int, nativePartition: LayerRuntime.NativePartition, continuesFrames: Bool,
         completion: @escaping (SkinNativeStageResult) -> Void) {
        self.maximumCallbackBitmapBytes = maximumCallbackBitmapBytes
        publishesContent = true
        self.nativePartition = nativePartition
        self.continuesFrames = continuesFrames
        self.completion = completion
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    /// Exactly once on main, with cancellation taking precedence over an already queued observation.
    @discardableResult
    func complete(_ result: SkinNativeStageResult) -> Bool {
        precondition(Thread.isMainThread)
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        completed = true
        let delivered: SkinNativeStageResult = cancelled ? .failure(.cancelled) : result
        lock.unlock()
        completion(delivered)
        return true
    }
}

/// The attachment envelope retains no live E owner, Skin or DrawContext. Its immutable epoch must be checked
/// against CURRENT AppKit facts inside actual owner access, not merely against a queued request's facts sequence.
final class SkinNativeStage {
    struct Epoch {
        let panelGeneration: UInt64
        let size: CGSize
        let scale: CGFloat
        let colorSpace: CGColorSpace
        let appearance: String
        let presentationGeneration: UInt64

        func matches(_ facts: SkinWindowFacts, size: CGSize) -> Bool {
            facts.panelGeneration == panelGeneration && self.size == size && facts.scale == scale &&
                facts.appearance == appearance && !facts.settings.hidden &&
                facts.colorSpace.map { CFEqual($0, colorSpace) } == true
        }
    }
    let attachment: LayerRuntime.NativeStage
    let provider: LayerContentProvider
    let epoch: Epoch
    let request: SkinNativeStageRequest
    private let releaseLock = NSLock()
    private var ownerReleased = false
    private var stoppedOwnerReleased = false
    private var publicationCommitted = false
    private var publicationRollback = false
    private var rollbackFailure: SkinNativeStageFailure?
    /// Changed only on the real owner, after the initial Main completion acknowledgment.
    var nativeFramesReady = false
    /// The real executor alone changes this flag. Main completes through the request's locked once gate.
    var completionQueued = false
    var rollbackQueued = false

    init(attachment: LayerRuntime.NativeStage, provider: LayerContentProvider, epoch: Epoch,
         request: SkinNativeStageRequest) {
        self.attachment = attachment
        self.provider = provider
        self.epoch = epoch
        self.request = request
    }

    /// Published only after this exact attachment's E owner has actually been released on its executor.
    /// Permanent stop additionally closes the owner slot; main must not request a stopped executor's lease/ack.
    func recordOwnerRelease(permanentStop: Bool) {
        releaseLock.lock()
        ownerReleased = true
        stoppedOwnerReleased = stoppedOwnerReleased || permanentStop
        releaseLock.unlock()
    }

    var hasOwnerRelease: Bool {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return ownerReleased
    }

    var hasStoppedOwnerRelease: Bool {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return stoppedOwnerReleased
    }

    func recordPublicationCommit() {
        precondition(Thread.isMainThread)
        releaseLock.lock()
        publicationCommitted = true
        releaseLock.unlock()
    }

    /// Main may acknowledge only after the provider has actually hidden this attachment (or never installed it).
    func recordPublicationRollback(failure: SkinNativeStageFailure? = nil) {
        precondition(Thread.isMainThread)
        releaseLock.lock()
        publicationRollback = true
        if rollbackFailure == nil { rollbackFailure = failure }
        releaseLock.unlock()
    }

    var wasPublished: Bool {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return publicationCommitted
    }

    var publicationFailure: SkinNativeStageFailure? {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return rollbackFailure
    }

    var hasPublicationRollback: Bool {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return publicationRollback
    }
}
