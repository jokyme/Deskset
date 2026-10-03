import AppKit
import DesksetCore
import DesksetRuntime

/// The half of a running skin that owns the `Skin` (docs/skin-threading.md §5.4): it is the skin's `SkinHost`, runs its
/// update clock, pause and wake, draws its frames (`frames`), handles the messages sent to it (`send`), publishes what
/// the main thread reads of the skin (`snapshot`) and asks the main thread for what only the main thread can do
/// (`request`). Everything here runs on the skin's executor, except reading the snapshot; the window half,
/// `SkinWindowController`, stays on the main thread and reaches the skin only through this object: messages, the
/// snapshot, or exclusive access (`exclusive`) where it still needs the live skin at once.
///
/// Every skin runs on the main executor so far (phase 2 of the design moves the desktop's skins to an engine thread
/// later), so messages and requests run inline and in the order they always did.
///
/// Its life is messages too: `.load` loads and starts the skin and reports `.loaded` and `.started` (or `.failed`) to the
/// main thread, which places and shows the window; `.close` runs OnCloseAction and reports `.closed`. Whoever must wait for the close
/// (quitting, the installer) waits for the runtime (`whenClosed`, `waitUntilClosed`), which outlives its window half if
/// need be.
///
/// The skin lives as long as the runtime and is let go of on its executor: when the runtime goes elsewhere (the window
/// half that held it went on the main thread while the skin runs on a thread of its own), the skin is handed to its
/// executor to be released there, with its measures, meters and plugins.
final class SkinRuntime: LiveSkinHost, SkinImageQueries, TickTarget {
    let config: String
    let file: String
    let fileURL: URL
    /// Peer messages are always queued in pool mode, also when both skins happen to share a worker.
    let defersPeerBangs: Bool
    /// The same activity spans Core work, runtime messages and drawing. Main-thread skins do not need a worker log.
    private let workActivity: SkinWorkWatchdog.Activity?
    /// The skin. Touch it only on its executor (`executor.isCurrent`, or inside `exclusive`).
    private(set) var skin: Skin!
    /// The main-thread side: the skin's window, or a test's stand-in. Not retained: it owns the runtime.
    weak var window: SkinRuntimeWindow?

    /// Where the skin runs: its executor.
    var executor: SkinExecutor { skin.executor }

    // What the executor owns.
    private let ticks = TickScheduler()
    /// OnCloseAction is running, or has run.
    private(set) var isClosing = false
    /// The skin is closed: it takes no more messages.
    private(set) var isClosed = false
    private var updatesPaused: Bool {
        get { ticks.isPaused }
        set { ticks.isPaused = newValue }
    }
    /// The hops of the message being handled (0 for the skin's own work): what its bangs for other skins count from.
    private var currentHops = 0
    /// What the skin believes its window is (docs/skin-threading.md §8.1): its own window bangs change it at once, the
    /// main thread's facts after them. On the executor.
    private(set) var model = SkinWindowModel()
    /// The running skins, where the skin sends its bangs for other skins (nil: every such bang goes through the main
    /// thread, as for a runtime of the self-tests without an app).
    weak var directoryStore: SkinDirectoryStore?
    /// Loads this skin asked the main thread for (`!ActivateConfig`, `!ToggleConfig`) that the main thread has not
    /// scheduled yet, by lowercased config: until then a bang for that config goes behind them, through the main
    /// thread (the directory does not know of them yet). Only requests queued from another thread count.
    private let loadsInFlight = Guarded<[String: Int]>([:])
    /// Bangs for other skins dropped because a chain of skins triggering each other reached `maxHops`, and whether that
    /// was logged (once).
    private(set) var droppedHops = 0
    private(set) var hopLimitLogs = 0

    /// Told of every message right before it is handled, on the executor (self-tests).
    var messageObserver: ((SkinMessage) -> Void)?

    /// Draws the skin's frames at the end of its executor's turns and presents them through the window's content
    /// provider. On the executor.
    let frames: SkinFrameProducer
    /// The size the window was last asked to follow (`skinNeedsDisplay`). Not the window model's: AppKit rounds a
    /// window's frame to whole points, so a skin 130.3 points wide has a window 131 wide.
    private var requestedSize: CGSize?

    /// Most bangs one skin passes on to another inside a single chain (`[!Update B]` in A's OnUpdateAction, `[!Update
    /// A]` in B's…): the next one is dropped (and logged, once per skin).
    static let maxHops = 16

    /// A runtime for `file` of `config` under `skinsDirectory`, on `executor`, whose frames go to `content` (nil: none
    /// are drawn). Load it with `load()`, on the executor.
    init(config: String, file: String, skinsDirectory: URL, executor: SkinExecutor = MainSkinExecutor.shared,
         content: ContentProvider? = nil, contentMode: SkinFrameContentMode = .bitmap, defersPeerBangs: Bool = false,
         watchdog: SkinWorkWatchdog = .shared) {
        self.config = config
        self.file = file
        self.defersPeerBangs = defersPeerBangs
        workActivity = executor is SkinThreadExecutor ? SkinWorkWatchdog.Activity(watchdog: watchdog, config: config) : nil
        fileURL = SkinLibrary.directory(for: config, root: skinsDirectory).appendingPathComponent(file)
        var owner: (() -> Skin?)?
        frames = SkinFrameProducer(provider: content, skin: { owner?() }, contentMode: contentMode, workActivity: workActivity)
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: SystemMonitor.shared,
                        host: self)
        skin.executor = executor
        self.skin = skin
        owner = { [weak self] in self?.skin }
        frames.requestLayerInstallation = { [weak self] in self?.request(.installLayerContent) }
        frames.requestScenePatch = { [weak self] patch in
            guard let self else { _ = patch.content.reclaim(.invalidated); return }
            self.request(.scenePatch(patch))
        }
        frames.publishLayerHitMap = { [weak self] map, generation, panel in
            self?.request(.layerHitMap(map, generation: generation, panelGeneration: panel))
        }
        frames.writerReleased = { [weak self] in self?.finishLayerTeardown() }
        if contentMode.usesLayers, executor is SkinThreadExecutor {
            frames.requestNativeCompletion = { [weak self] stage, result in
                self?.request(.nativeStageCompleted(stage, result))
            }
            frames.requestNativeStopRelease = { [weak self] stage in self?.request(.nativeStageReleased(stage)) }
            frames.requestNativePublicationFinished = { [weak self] stage, result in
                self?.request(.nativeStagePublicationFinished(stage, result))
            }
            frames.requestNativeRollback = { [weak self] stage, failure in self?.request(.nativeStageRollback(stage, failure)) }
        }
        if contentMode.requestsNativeFrames {
            frames.requestNativeFrames = { [weak self] in self?.enqueue(.nativeFramesRequested) }
        }
        frames.start(on: executor)
    }

    deinit {
        ticks.cancel()
        // Only the executor lets go of a skin (docs/skin-threading.md, phase 0: Lifetime).
        guard let skin, !skin.executor.isCurrent else { return }
        self.skin = nil
        skin.executor.async { withExtendedLifetime(skin) {} }
    }

    // MARK: Loading

    /// What loading found: whether the skin registered fonts of its own, and its compatibility notes.
    struct LoadResult {
        var registeredFonts: Bool
        var issues: [String]
    }

    /// Loads the skin and registers its fonts (`@Resources/Fonts`). On the executor.
    func load() throws -> LoadResult {
        try skin.load()
        return LoadResult(registeredFonts: Fonts.registerFonts(for: skin), issues: skin.issues)
    }

    /// `SkinMessage.load`: loads the skin and starts it. The main thread hears that it loaded (`.loaded`: the settings a
    /// first load seeds, its fonts and notes), then what it needs to place and show the window (`.started`), or that
    /// the skin could not be loaded (`.failed`: the skin counts as closed). On the executor.
    private func start(_ order: SkinLoadOrder) {
        // From here on messages sent on the executor run at once again (the load is the one running now).
        queueLock.lock()
        loadQueued = false
        queueLock.unlock()
        let loaded: LoadResult
        do {
            loaded = try load()
        } catch {
            isClosing = true
            isClosed = true
            frames.stop()
            request(.failed(String(describing: error), ticket: order.ticket))
            markClosed()
            return
        }
        // A first load: the skin's Default… options seed its window settings (over what its own window bangs did while it
        // loaded, as the main thread seeds them over `AppState`), and StartHidden hides it. The main thread does the same
        // when it hears of the load; the model has them at once, before the first update, which may read
        // #CURRENTCONFIGZPOS#.
        let defaults = order.firstLoad ? skin.settings.windowDefaults : [:]
        if !defaults.isEmpty { model.settings = model.settings.seeded(with: defaults) }
        if order.state.seeded(with: defaults).startHidden { model.settings.hidden = true }
        request(.loaded(SkinLoadReport(windowDefaults: defaults, registeredFonts: loaded.registeredFonts,
                                       issues: loaded.issues)))
        // A refresh: the Calc Counter "only resets when the skin is unloaded and then loaded again".
        if let previous = order.continuing { skin.continueCounter(at: previous.snapshot.counter) }
        // Paused (sleep, locked screens): the first update happens, the clock waits for the resume.
        updatesPaused = order.paused
        skin.update()
        startTimer()
        // A window about to be shown never shows before its skin has drawn (a skin that stays hidden draws when shown).
        if order.presentsWindows && !model.settings.hidden { frames.drawFirstFrame() }
        let snapshot = self.snapshot
        request(.started(SkinStartReport(size: snapshot.size, metadata: snapshot.metadata, ticket: order.ticket)))
    }

    // MARK: Messages

    /// Delivers a message: at once when the caller is on the runtime's executor (then the answer is the skin's: whether
    /// a mouse action was handled; true for other messages that were taken, false when the skin is closed), otherwise
    /// queued there, first in, first out (nil). A hover or window facts queued right behind the same kind, not run yet,
    /// replace it.
    ///
    /// Not at once while `.load` waits in the queue: a skin on the same thread (a bang from another skin, a timer) that
    /// finds this runtime in the directory before its load ran would otherwise reach a skin that has not loaded (its
    /// first update would not be the first, so OnRefreshAction would never run). Such a message goes behind the load, as
    /// a message from another thread does.
    @discardableResult
    func send(_ message: SkinMessage) -> Bool? {
        if executor.isCurrent && !isLoadQueued { return handle(message) }
        enqueue(message)
        return nil
    }

    /// The messages queued and not run yet: the last one, when a later hover or window facts may replace it.
    private let queueLock = NSLock()
    private var coalescingTail: MessageBox?
    /// `.load` was queued and has not run yet (under `queueLock`).
    private var loadQueued = false

    /// Whether `.load` waits in the queue: set when it is queued (before the app lists the runtime in the directory),
    /// cleared when it runs. Any thread.
    var isLoadQueued: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return loadQueued
    }

    private final class MessageBox {
        var message: SkinMessage
        let coalesces: Bool

        init(_ message: SkinMessage) {
            self.message = message
            switch message {
            case .hover, .windowFacts: coalesces = true
            default: coalesces = false
            }
        }

        func takes(_ later: SkinMessage) -> Bool {
            switch (message, later) {
            case (.hover, .hover), (.windowFacts, .windowFacts): return true
            default: return false
            }
        }
    }

    private func enqueue(_ message: SkinMessage) {
        queueLock.lock()
        defer { queueLock.unlock() }
        if let tail = coalescingTail, tail.takes(message) {
            tail.message = message
            return
        }
        let box = MessageBox(message)
        coalescingTail = box.coalesces ? box : nil
        if case .load = message { loadQueued = true }
        // The work holds the runtime (and so the skin) until it ran, as `Skin.async` does. Queued under the lock, so
        // the tail is always the last message queued.
        executor.async {
            self.queueLock.lock()
            if self.coalescingTail === box { self.coalescingTail = nil }
            let message = box.message
            self.queueLock.unlock()
            self.handle(message)
        }
    }

    @discardableResult
    private func handle(_ message: SkinMessage) -> Bool {
        workActivity?.begin()
        defer { workActivity?.end() }
        messageObserver?(message)
        switch message {
        case .nativeStageRequested(let request):
            return prepareNativeRequest(request)
        case .nativeFramesRequested:
            guard !isClosing, !isClosed, let request = frames.automaticNativeFrameRequest() else { return false }
            return prepareNativeRequest(request)
        case .nativeFramesReady(let stage):
            frames.enableNativeFrames(stage)
            return true
        case .nativeStageAttached(let stage):
            frames.displayNativeStage(stage)
            return true
        case .nativeStageRelease(let stage):
            guard frames.releaseNativeStage(stage) else { return false }
            request(.nativeStageReleased(stage))
            return true
        case .nativeStageDetached(let stage):
            frames.detachedNativeStage(stage)
            return true
        case .nativeStagePublicationCommitted(let stage, let observation):
            frames.acknowledgeNativePublication(stage, observation: observation)
            return true
        case .nativeStageRolledBack(let stage):
            guard frames.rolledBackNativePublication(stage) else { return false }
            request(.nativeStageReleased(stage))
            return true
        case .scenePatchFinished(let patch):
            frames.finishScenePatch(patch)
            return true
        case .mirrorInput(let mirror):
            skin.inputMirror = mirror
            return true
        case .windowFacts(let facts):
            model.take(facts)
            frames.take(model.facts)
            skin.hostFactsChanged()
            return true
        case .patch(let sources, let done):
            // Answered whatever happens: the Studio waits for it to move the window or load the widget again.
            guard !isClosed else {
                done(.needsReload(.closed), 0)
                return false
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let result = StudioSignposts.interval("desktop.patch") { skin.patch(sources: sources) }
            done(result, Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6)
            return true
        default:
            break
        }
        guard !isClosed else { return false }
        switch message {
        case .mouse(let kind, let x, let y):
            return skin.mouseEvent(kind, x: x, y: y)
        case .pressCancelled:
            skin.cancelMousePress()
        case .scroll(let kind, let x, let y):
            skin.pointerEvent(.scrolled(kind), x: x, y: y)
            guard !isClosed else { return false }
            return skin.mouseEvent(kind, x: x, y: y)
        case .pointer(let event, let x, let y):
            skin.pointerEvent(event, x: x, y: y)
        case .outsidePointer(let event, let x, let y):
            skin.outsidePointerEvent(event, x: x, y: y)
        case .hover(let x, let y):
            skin.mouseMoved(x: x, y: y)
        case .exited:
            skin.mouseExited()
        case .focus(let focused):
            skin.focusChanged(focused)
        case .bang(let bang, _, let hops):
            withHops(hops) {
                // A window bang goes to the window model (the skin's actions never see it, as before); any other bang
                // to the skin.
                if HostBangs.kind(of: bang.name) == .window {
                    windowBang(bang)
                } else {
                    skin.performSent(bang)
                }
            }
        case .execute(let action, let section):
            skin.executeInput(action, from: section.flatMap { skin.section(named: $0) })
        case .run(let action):
            skin.execute(action, from: nil)
        case .inputTextAnswered(let id, let text):
            inputTextAnswers.removeValue(forKey: id)?(text)
        case .windowSettled(let id):
            windowFollowers[id]?()
        case .preview(let sections, let variables):
            if !variables.isEmpty { skin.previewVariables(variables) }
            for (section, values) in sections { skin.preview(section: section, values) }
        case .endPreview:
            skin.endPreview()
        case .load(let order):
            start(order)
        case .start:
            skin.update()
            startTimer()
        case .update(let hops):
            withHops(hops) { skin.update() }
        case .redraw:
            skin.redraw()
        case .pause:
            pause()
        case .resume(let updateNow):
            resume(updateNow: updateNow)
        case .wake:
            wake()
        case .fontsChanged:
            skin.fontsDidChange()
        case .appearanceChanged:
            skin.appearanceDidChange()
        case .close(_, let ticket):
            close(ticket: ticket)
        case .firstFrame:
            frames.drawFirstFrame()
        case .frameWanted:
            frames.setNeedsFrame()
        case .mirrorInput, .windowFacts, .patch, .scenePatchFinished,
             .nativeStageRequested, .nativeStageAttached, .nativeStageRelease, .nativeStageDetached,
             .nativeStagePublicationCommitted, .nativeStageRolledBack, .nativeFramesRequested, .nativeFramesReady:
            break
        }
        return true
    }

    private func withHops(_ hops: Int, _ body: () -> Void) {
        let saved = currentHops
        currentHops = hops
        defer { currentHops = saved }
        body()
    }

    // MARK: The snapshot

    /// The snapshot the main thread reads, swapped under `snapshotLock`.
    private let snapshotLock = NSLock()
    private var publishedSnapshot = SkinSnapshot()
    /// The executor's copy of the last snapshot published, and the skin's snapshot generation it was built at.
    private var ownSnapshot = SkinSnapshot()
    private var builtGeneration: Int?
    private var isPublishing = false

    /// What the main thread reads of the skin (see `SkinSnapshot`): as of the skin's last piece of work. Any thread. On
    /// the skin's executor what changed since is published first, so a reader there (on the main thread for a skin of
    /// the main executor) always reads the skin as it is.
    var snapshot: SkinSnapshot {
        if let skin, skin.executor.isCurrent { publishSnapshot() }
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return publishedSnapshot
    }

    /// Publishes the snapshot that follows the skin's last piece of work (`SkinSnapshot.next`) when anything in it
    /// changed, and asks the main thread to act on what it acts on (`.snapshotChanged`). On the executor: after every
    /// piece of the skin's work (`skinDidFinishWork`), and before a read there.
    func publishSnapshot() {
        guard let skin, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        let old = ownSnapshot
        guard let next = SkinSnapshot.next(after: old, of: skin, builtGeneration: &builtGeneration) else { return }
        ownSnapshot = next
        snapshotLock.lock()
        publishedSnapshot = next
        snapshotLock.unlock()
        var changes = next.changes(from: old)
        // Layer tooltips/hit maps are the values of a completed frame, not an independently posted work snapshot.
        if frames.contentMode.usesLayers { changes.remove(.toolTips) }
        if !changes.isEmpty { request(.snapshotChanged(changes)) }
    }

    // MARK: Exclusive access

    /// How long the main thread waits for a skin on another thread to park by default, where it still needs the live
    /// skin (the snapshot answers the window's mouse questions).
    static let defaultExclusiveTimeout: TimeInterval = 0.25

    /// Runs `body` with the live skin while its own work waits (`SkinExecutor.exclusive`): at once on the executor,
    /// nil when a skin on another thread does not park within `timeout`.
    @discardableResult
    func exclusive<T>(timeout: TimeInterval = SkinRuntime.defaultExclusiveTimeout, _ body: (Skin) -> T) -> T? {
        let skin: Skin = self.skin
        return skin.executor.exclusive(timeout: timeout) { body(skin) }
    }

    /// Main parks the executor before touching the provider, never while holding its layer lock. The caller
    /// supplies CURRENT window facts, including a real optional profile, and its actual content size.
    func installLayerContent(for facts: SkinWindowFacts, size: CGSize) -> SkinFrameProducer.LayerInstallation? {
        precondition(Thread.isMainThread)
        return executor.exclusive(timeout: Self.defaultExclusiveTimeout) {
            frames.installLayerContent(for: facts, size: size)
        }
    }

    /// Internal, explicit, one-shot qualification. No automatic frame path calls it. Unsupported bitmap or Main
    /// modes answer before allocating an E owner, capturing a scene or scheduling any worker work.
    func requestNativeStage(maximumCallbackBitmapBytes: Int, completion: @escaping (SkinNativeStageResult) -> Void) {
        requestNativeStage(maximumCallbackBitmapBytes: maximumCallbackBitmapBytes, publishesSingle: false, completion: completion)
    }

    /// Explicit same-generation Single E publication only. The ordinary C/default frame path never invokes it.
    func publishNativeSingle(maximumCallbackBitmapBytes: Int, completion: @escaping (SkinNativeStageResult) -> Void) {
        requestNativeStage(maximumCallbackBitmapBytes: maximumCallbackBitmapBytes, publishesSingle: true, completion: completion)
    }

    private func requestNativeStage(maximumCallbackBitmapBytes: Int, publishesSingle: Bool,
                                    completion: @escaping (SkinNativeStageResult) -> Void) {
        precondition(Thread.isMainThread)
        guard frames.contentMode.usesLayers else { return completion(.failure(.unsupportedMode)) }
        guard let worker = executor as? SkinThreadExecutor else { return completion(.failure(.unsupportedExecutor)) }
        guard !didClose, !worker.hasExited else { return completion(.failure(.cancelled)) }
        // Even inside a main exclusive callback, display/creation must run later on the physical worker.
        enqueue(.nativeStageRequested(SkinNativeStageRequest(maximumCallbackBitmapBytes: maximumCallbackBitmapBytes,
                                                            publishesSingle: publishesSingle, completion: completion)))
    }

    /// The controller calls after actual C installation. Existing C/bitmap activation queues nothing extra.
    func beginNativeFrames() {
        precondition(Thread.isMainThread)
        guard frames.contentMode.requestsNativeFrames, !didClose else { return }
        enqueue(.nativeFramesRequested)
    }

    private func prepareNativeRequest(_ request: SkinNativeStageRequest) -> Bool {
        precondition(executor.isCurrent)
        guard !isClosing, !isClosed else {
            self.request(.nativeStageRejected(request, .cancelled))
            return false
        }
        do {
            let stage = try frames.prepareNativeStage(request)
            if request.publishesContent {
                stage.attachment.callbackReport.observeFirstFailure { [weak self, weak stage] failure in
                    guard let self, let stage else { return }
                    self.request(.nativeStageCallbackFailed(stage, .rendering(String(describing: failure))))
                }
            }
            self.request(.attachNativeStage(stage))
        } catch {
            let failure = (error as? SkinNativeStageFailure) ?? .rendering(String(describing: error))
            frames.rejectAutomaticNativeFrames(request, failure: failure)
            self.request(.nativeStageRejected(request, failure))
        }
        return true
    }

    func nativeStageAttached(_ stage: SkinNativeStage) {
        precondition(Thread.isMainThread)
        enqueue(.nativeStageAttached(stage))
    }

    /// CURRENT host and captured scene validation precedes main attachment inside the actual executor lease.
    func attachNativeStage(_ stage: SkinNativeStage, facts: SkinWindowFacts, size: CGSize) -> Bool? {
        precondition(Thread.isMainThread)
        return executor.exclusive(timeout: Self.defaultExclusiveTimeout) {
            frames.attachNativeStage(stage, facts: facts, size: size)
        }
    }

    /// Completion is scoped: a successful callback runs while the physical owner is parked, then its E owner is
    /// released before main detaches. No native ready token or visible publication escapes this operation.
    func completeNativeStage(_ stage: SkinNativeStage, result: SkinNativeStageResult,
                             facts: SkinWindowFacts? = nil, size: CGSize? = nil) {
        precondition(Thread.isMainThread)
        // The permanent-stop ack is an actual owner-release fact, independent of whether the worker still exists.
        // A queued success/attach cannot turn it back into readiness or require another stopped-owner work item.
        if stage.hasStoppedOwnerRelease {
            stage.request.complete(.failure(.cancelled))
            if stage.request.publishesContent { rollbackNativePublication(stage, failure: .cancelled) }
            stage.provider.detachNativeStage(stage.attachment)
            return
        }
        if stage.request.publishesContent {
            completeNativePublication(stage, result: result, facts: facts, size: size)
            return
        }
        let completed: Bool
        switch result {
        case .success(let ready):
            if let facts, let size, stage.epoch.matches(facts, size: size) {
                completed = executor.exclusive(timeout: Self.defaultExclusiveTimeout) {
                    guard frames.nativeStageIsCurrent(stage) else { return stage.request.complete(.failure(.cancelled)) }
                    // CA may have supplied an unexpected callback AFTER worker display and before this main scope.
                    // The queued worker snapshot cannot override a current failure latch or extra native entry.
                    let current = stage.attachment.callbackReport.observation
                    if let failure = current.failure {
                        return stage.request.complete(.failure(.rendering(String(describing: failure))))
                    }
                    guard current.callbacks == ready.native.callbacks else {
                        return stage.request.complete(.failure(.rendering("Native callback count changed before completion")))
                    }
                    return stage.request.complete(.success(SkinNativeStageObservation(sourceSequence: ready.sourceSequence,
                        native: current, drewOnPhysicalOwner: ready.drewOnPhysicalOwner)))
                } ?? stage.request.complete(.failure(.attachmentTimedOut))
            } else { completed = stage.request.complete(.failure(.staleDestination)) }
        case .failure:
            completed = stage.request.complete(result)
        }
        if completed { enqueue(.nativeStageRelease(stage)) }
    }

    /// Main retains only the attachment envelope. Drawing ownership remains strong on the physical owner until
    /// rollback/release; a backend switch keeps the already presented scene generation and its host values.
    private var publishedNativePublication: SkinNativeStage?

    private func completeNativePublication(_ stage: SkinNativeStage, result: SkinNativeStageResult,
                                           facts: SkinWindowFacts?, size: CGSize?) {
        guard !stage.hasPublicationRollback, !stage.wasPublished else { return }
        do {
            let ready = try result.get()
            guard let facts, let size, stage.epoch.matches(facts, size: size) else {
                throw SkinNativeStageFailure.staleDestination
            }
            let publication: Result<Void, Error>? = executor.exclusive(timeout: Self.defaultExclusiveTimeout) {
                Result {
                    guard frames.nativeStageIsCurrent(stage) else { throw SkinNativeStageFailure.cancelled }
                    let current = stage.attachment.callbackReport.observation
                    if let failure = current.failure { throw failure }
                    guard current.callbacks == ready.native.callbacks else {
                        throw SkinNativeStageFailure.rendering("Native callback count changed before publication")
                    }
                    try frames.beginNativePublication(stage)
                    guard stage.provider.publishNativeStage(stage.attachment, executor: executor) else {
                        throw SkinNativeStageFailure.cancelled
                    }
                    stage.recordPublicationCommit()
                    publishedNativePublication = stage
                    if let failure = stage.attachment.callbackReport.observation.failure { throw failure }
                }
            }
            guard let publication else { throw SkinNativeStageFailure.attachmentTimedOut }
            try publication.get()
            enqueue(.nativeStagePublicationCommitted(stage, ready))
        } catch let failure as SkinNativeStageFailure { rollbackNativePublication(stage, failure: failure) }
        catch { rollbackNativePublication(stage, failure: .rendering(String(describing: error))) }
    }

    /// Called only after the actual owner consumed Main's commit acknowledgment. An older queued success cannot
    /// override a newer callback failure, cancellation, destination or rollback. The result carries no ready token.
    func finishNativePublication(_ stage: SkinNativeStage, result: SkinNativeStageResult,
                                 facts: SkinWindowFacts, size: CGSize) {
        precondition(Thread.isMainThread)
        // A replay of initial readiness cannot cancel a persistent attachment's newer ordinary native frames.
        if stage.request.continuesFrames && stage.request.isCompleted { return }
        guard publishedNativePublication === stage, !stage.hasPublicationRollback, !stage.hasOwnerRelease,
              stage.epoch.matches(facts, size: size) else {
            rollbackNativePublication(stage, failure: .staleDestination)
            return
        }
        do {
            let ready = try result.get()
            let checked: Result<SkinNativeStageObservation, Error>? = executor.exclusive(timeout: Self.defaultExclusiveTimeout) {
                Result {
                    guard frames.nativeStageIsCurrent(stage) else { throw SkinNativeStageFailure.cancelled }
                    let current = stage.attachment.callbackReport.observation
                    if let failure = current.failure { throw failure }
                    guard ready.published, current.callbacks == ready.native.callbacks else {
                        throw SkinNativeStageFailure.rendering("Native callback count changed after publication acknowledgment")
                    }
                    return SkinNativeStageObservation(sourceSequence: ready.sourceSequence, native: current,
                        drewOnPhysicalOwner: ready.drewOnPhysicalOwner, published: true)
                }
            }
            guard let checked else { throw SkinNativeStageFailure.attachmentTimedOut }
            if stage.request.complete(.success(try checked.get())), stage.request.continuesFrames {
                enqueue(.nativeFramesReady(stage))
            }
        } catch let failure as SkinNativeStageFailure { rollbackNativePublication(stage, failure: failure) }
        catch { rollbackNativePublication(stage, failure: .rendering(String(describing: error))) }
    }

    /// Main-only host rollback needs no stopped/busy executor lease. A stale envelope can release its own owner,
    /// but cannot hide a newer provider attachment or advance any newer panel/scene acknowledgment.
    func rollbackNativePublication(_ stage: SkinNativeStage, failure: SkinNativeStageFailure) {
        precondition(Thread.isMainThread)
        guard stage.request.publishesContent else { return }
        let hadAck = stage.hasPublicationRollback
        let hidden = stage.provider.rollbackNativeStage(stage.attachment)
        guard hidden || !stage.wasPublished || stage.hasOwnerRelease else { return }
        stage.recordPublicationRollback(failure: failure)
        if publishedNativePublication === stage { publishedNativePublication = nil }
        stage.request.complete(.failure(failure))
        if !hadAck, !stage.hasStoppedOwnerRelease { enqueue(.nativeStageRolledBack(stage)) }
    }

    func rollbackVisibleNativePublication(provider: LayerContentProvider, failure: SkinNativeStageFailure,
                                           facts: SkinWindowFacts? = nil, size: CGSize? = nil) {
        precondition(Thread.isMainThread)
        guard let stage = publishedNativePublication, stage.provider === provider else { return }
        if let facts, let size, stage.epoch.matches(facts, size: size) { return }
        rollbackNativePublication(stage, failure: failure)
    }

    /// Main calls this after the window/fade no longer needs its last frame. Cleanup goes behind close on the
    /// executor. Main removes the attachment only after the owner acknowledges that it is closed and stopped.
    func teardownContent() {
        precondition(Thread.isMainThread)
        guard frames.contentMode.usesLayers, let provider = frames.provider as? LayerContentProvider else {
            frames.provider?.teardown()
            return
        }
        guard provider.beginLayerTeardown() else { return }
        let cleanup = { [self] in
            layerCleanupRequested = true
            finishLayerTeardown()
        }
        if executor.isCurrent { cleanup() }
        else { executor.async(cleanup) }
    }

    private var layerCleanupRequested = false

    /// An applying main writer may outlive the deadline. Its ack triggers this owner cleanup without an upward wait.
    private func finishLayerTeardown() {
        precondition(executor.isCurrent)
        guard layerCleanupRequested, !frames.hasLayerWriter, !frames.hasNativeStage,
              let provider = frames.provider as? LayerContentProvider, frames.retireLayerContent() else { return }
        layerCleanupRequested = false
        if Thread.isMainThread { provider.completeLayerTeardown() }
        else { DispatchQueue.main.async { provider.completeLayerTeardown() } }
    }

    /// Runs `body` on the main thread once the work the skin's executor has now — the piece it is running and what is
    /// queued behind it — has run, so the snapshot counts what that work did: at once on the executor. Main thread.
    func whenCaughtUp(_ body: @escaping () -> Void) {
        if executor.isCurrent { return body() }
        executor.async { DispatchQueue.main.async(execute: body) }
    }

    // MARK: Requests

    /// Asks the main thread: at once when on it, else queued there in order.
    func request(_ request: SkinRequest) {
        if Thread.isMainThread {
            // A CA callback can arrive while a provider transaction holds its leaf lock. Failure notification must
            // leave that callback before attempting Main rollback; reuse the existing one Main delivery site.
            if case .nativeStageCallbackFailed = request {} else {
                applyRequestOnMain(request)
                return
            }
        }
        // A load the main thread has not scheduled yet: bangs for that config wait for it (`isLoadPending`).
        let load = SkinRuntime.configLoaded(by: request)
        if let load { loadsInFlight.access { $0[load, default: 0] += 1 } }
        // An in-flight native attachment must complete owner release/detach even if its window disappears. Only
        // these bounded requests retain the runtime across main delivery; ordinary requests keep their weak life.
        let nativeOwner: SkinRuntime?
        switch request {
        case .attachNativeStage, .nativeStageCompleted, .nativeStageReleased, .nativeStageRejected,
             .nativeStagePublicationFinished, .nativeStageRollback, .nativeStageCallbackFailed: nativeOwner = self
        default: nativeOwner = nil
        }
        DispatchQueue.main.async { [weak self, nativeOwner] in
            guard let self = self ?? nativeOwner else {
                if case .scenePatch(let patch) = request { _ = patch.content.reclaim(.invalidated) }
                return
            }
            self.applyRequestOnMain(request)
            if let load {
                self.loadsInFlight.access {
                    let left = ($0[load] ?? 1) - 1
                    $0[load] = left > 0 ? left : nil
                }
            }
        }
    }

    private func applyRequestOnMain(_ request: SkinRequest) {
        precondition(Thread.isMainThread)
        switch request {
        case .nativeStageReleased(let stage):
            guard stage.hasOwnerRelease else { return }
            if stage.request.publishesContent { rollbackNativePublication(stage, failure: .cancelled) }
            if stage.hasStoppedOwnerRelease { stage.request.complete(.failure(.cancelled)) }
            stage.provider.detachNativeStage(stage.attachment)
            if !stage.hasStoppedOwnerRelease { enqueue(.nativeStageDetached(stage)) }
        case .nativeStageRejected(let request, let failure):
            request.complete(.failure(failure))
        case .nativeStageRollback(let stage, let failure), .nativeStageCallbackFailed(let stage, let failure):
            rollbackNativePublication(stage, failure: failure)
        case .nativeStagePublicationFinished(let stage, _):
            if let window { window.apply(request, from: self) }
            else { rollbackNativePublication(stage, failure: .cancelled) }
        case .attachNativeStage(let stage), .nativeStageCompleted(let stage, _):
            if let window { window.apply(request, from: self) }
            else { completeNativeStage(stage, result: .failure(.cancelled)) }
        default:
            if let window { window.apply(request, from: self) }
            else if case .scenePatch(let patch) = request { _ = patch.content.reclaim(.invalidated) }
        }
    }

    /// The config (lowercased) a lifecycle request may load: !ActivateConfig and !ToggleConfig.
    private static func configLoaded(by request: SkinRequest) -> String? {
        guard case .lifecycle(let host) = request, host.bang.name == "activateconfig" || host.bang.name == "toggleconfig",
              let raw = host.bang.args.first else { return nil }
        let name = SkinLibrary.normalizedConfigName(raw).lowercased()
        return name.isEmpty ? nil : name
    }

    // MARK: Bangs for other skins

    /// Whether a bang for `config` must go behind a load: one the directory knows of, or one this skin asked for that
    /// the main thread has not scheduled yet.
    private func isLoadPending(_ config: String, in directory: SkinDirectory) -> Bool {
        if directory.isLoadPending(config) { return true }
        let key = SkinLibrary.normalizedConfigName(config).lowercased()
        return loadsInFlight.access { $0[key] != nil }
    }

    /// Hands `message` (made with the hops it carries) to another skin's runtime. Pool mode always queues peer bangs,
    /// so their ordering does not depend on worker placement. Other modes deliver inline on the same executor. A
    /// chain of skins triggering each other stops at `maxHops`: the bang is dropped and logged, once per skin.
    private func deliver(_ bang: String, to target: SkinRuntime, _ message: (_ hops: Int) -> SkinMessage) {
        guard currentHops < SkinRuntime.maxHops else {
            droppedHops += 1
            if hopLimitLogs == 0 {
                hopLimitLogs += 1
                Log.write("!\(bang) to \"\(target.config)\" ignored: skins keep triggering each other", level: .warning,
                          source: config)
            }
            return
        }
        let value = message(currentHops + 1)
        if target !== self && (defersPeerBangs || target.defersPeerBangs) {
            target.enqueue(value)
        } else {
            target.send(value)
        }
    }

    /// Sends a bang the engine performed to the config `name` (not this one): straight to its runtime when it runs; to
    /// the main thread when it is loading (the bang follows the load) or not running (the main thread says so in the
    /// log), or without a directory.
    private func send(_ bang: Bang, toConfig name: String) {
        if let directory = directoryStore?.directory, !isLoadPending(name, in: directory),
           let target = directory.runtime(for: name) {
            deliver(bang.name, to: target) { .bang(bang, from: config, hops: $0) }
        } else {
            request(.forward(bang, toConfig: name, hops: currentHops))
        }
    }

    /// The skins of a skin group, in load order (without a directory: this one, when it is in the group).
    private func groupMembers(_ group: String) -> [SkinRuntime] {
        if let directory = directoryStore?.directory { return directory.runtimes(inGroup: group) }
        return snapshot.isInSkinGroup(group) ? [self] : []
    }

    /// A window bang (`SkinWindowBangs`): this skin's own changes its window model at once; the others' go to their
    /// runtimes (a skin group, `*` and a config by name are resolved here, in load order). On the main thread the
    /// windows are stacked again and the app hears of the changed settings once, after all of them.
    private func windowBang(_ bang: Bang) {
        guard let (targets, member) = SkinWindowBangs.targets(of: bang) else { return }
        inWindowBatch {
            switch targets {
            case .own:
                ownWindowBang(member)
            case .config(let name) where name == "*":
                guard let directory = directoryStore?.directory else {
                    ownWindowBang(member)
                    request(.forward(member, toConfig: "*", hops: currentHops))
                    return
                }
                for target in directory.runtimes {
                    if target === self {
                        ownWindowBang(member)
                    } else {
                        deliver(member.name, to: target) { .bang(member, from: config, hops: $0) }
                    }
                }
            case .config(let name):
                if name.caseInsensitiveCompare(config) == .orderedSame {
                    ownWindowBang(member)
                } else if let directory = directoryStore?.directory, directory.runtime(for: name) == nil,
                          !isLoadPending(name, in: directory) {
                    // A config that does not run and is not loading: nothing happens (nor is it logged).
                } else {
                    send(member, toConfig: name)
                }
            case .group(let group):
                for target in groupMembers(group) {
                    if target === self {
                        ownWindowBang(member)
                    } else {
                        deliver(member.name, to: target) { .bang(member, from: config, hops: $0) }
                    }
                }
            }
        }
    }

    /// One of the skin's own window bangs: the model changes at once, then the main thread is asked to do the same.
    private func ownWindowBang(_ bang: Bang) {
        guard !isClosed, let change = model.apply(bang, screens: EnvironmentStore.shared.currentScreens) else { return }
        // Shown: a window that has not drawn yet (StartHidden) has its first frame before the main thread orders it
        // in, as at the start, wherever the skin runs.
        if case .hidden(false, _) = change.operation { frames.drawFirstFrame() }
        request(.window(change))
    }

    /// Runs `body` as one batch of window changes on the main thread (`SkinRuntimeWindow.batchingWindowChanges`).
    private func inWindowBatch(_ body: () -> Void) {
        if Thread.isMainThread, let window {
            window.batchingWindowChanges(body)
        } else {
            body()
        }
    }

    /// !UpdateGroup, !RedrawGroup, !SetVariableGroup and the skin group mouse bangs: for each skin of the group, in load
    /// order (this one too when it is in the group, at once).
    private func groupBang(_ bang: Bang) {
        let a = bang.args
        func arg(_ i: Int) -> String { i < a.count ? a[i].trimmingCharacters(in: .whitespaces) : "" }
        func each(_ group: String, _ message: (_ hops: Int) -> SkinMessage) {
            for target in groupMembers(group) {
                if target === self {
                    send(message(currentHops))
                } else {
                    deliver(bang.name, to: target, message)
                }
            }
        }
        let sender = config
        switch bang.name {
        case "disablemouseactionskingroup", "clearmouseactionskingroup", "enablemouseactionskingroup",
             "togglemouseactionskingroup":
            // "operate on the [Rainmeter] section of a named Group of skins": !XMouseAction Rainmeter MouseActions in
            // each skin of the group.
            let local = Bang(name: String(bang.name.dropLast("skingroup".count)), args: ["Rainmeter", a.first ?? ""])
            each(arg(1)) { .bang(local, from: sender, hops: $0) }
        case "updategroup":
            each(arg(0)) { .update(hops: $0) }
        case "redrawgroup":
            each(arg(0)) { _ in .redraw }
        case "setvariablegroup":
            // !SetVariableGroup Variable Value Group
            let local = Bang(name: "setvariable", args: [arg(0), a.count > 1 ? a[1] : ""])
            each(arg(2)) { .bang(local, from: sender, hops: $0) }
        default:
            break
        }
    }

    // MARK: The update clock

    /// `Update` in ms → timer interval: negative means "update once" (manual: `Update=-1`), otherwise at least 16 ms
    /// ("minimum effective value is 16").
    static func updateInterval(_ milliseconds: Int) -> TimeInterval? {
        TickScheduler.updateInterval(milliseconds)
    }

    /// Timer slack that lets macOS coalesce wake-ups (Apple suggests at least 10%); capped so slow skins still tick
    /// on time.
    static func timerTolerance(_ interval: TimeInterval) -> TimeInterval {
        TickScheduler.timerTolerance(interval)
    }

    // TickTarget reads the live skin at each operation, including after synchronous action callbacks.
    var updateMilliseconds: Int { skin.settings.update }
    func updateForTick() { skin.update() }
    func notifySystemWake() { skin.systemDidWake() }

    private func startTimer() { ticks.startTimer(for: self) }
    private func pause() { ticks.pause() }
    private func resume(updateNow: Bool) { ticks.resume(updateNow: updateNow, target: self) }
    private func wake() { ticks.wake(target: self) }

    /// Stops the clock and closes the skin: OnCloseAction runs while the skin can still handle bangs (it cannot reload
    /// or unload itself any more). Then the main thread hears of it (`.closed`, with the ticket of the reload the close is
    /// part of), and whoever waits for the close.
    private func close(ticket: SkinReloadTicket?) {
        guard !isClosing else { return }
        ticks.cancel()
        isClosing = true
        skin.close()
        isClosed = true
        // The window fades out with the last frame.
        frames.stop()
        // An InputText box still open answers nobody, and the window's moves are followed for nobody.
        inputTextAnswers = [:]
        windowFollowers = [:]
        // What the skin that replaces it goes on from (its Calc Counter), whatever thread that one runs on.
        publishSnapshot()
        request(.closed(ticket))
        markClosed()
    }

    // MARK: Closed

    private let closedCondition = NSCondition()
    private var hasClosed = false
    private var closedWaiters: [() -> Void] = []

    /// The skin has closed (OnCloseAction ran) or could not be loaded. Any thread.
    var didClose: Bool {
        closedCondition.lock()
        defer { closedCondition.unlock() }
        return hasClosed
    }

    /// Runs `body` on the main thread once the skin has closed or could not be loaded: at once when it has. The
    /// runtime keeps the waiters, so they run even when the window half has gone meanwhile. Main thread.
    func whenClosed(_ body: @escaping () -> Void) {
        closedCondition.lock()
        let closed = hasClosed
        if !closed { closedWaiters.append(body) }
        closedCondition.unlock()
        if closed { body() }
    }

    /// Waits until the skin has closed, at most until `deadline`; true when it closed. Quitting waits with it (the
    /// skin's thread never waits for the main thread, so it can close meanwhile).
    func waitUntilClosed(before deadline: Date) -> Bool {
        closedCondition.lock()
        defer { closedCondition.unlock() }
        while !hasClosed {
            if !closedCondition.wait(until: deadline) { return hasClosed }
        }
        return true
    }

    private func markClosed() {
        closedCondition.lock()
        hasClosed = true
        let waiters = closedWaiters
        closedWaiters = []
        closedCondition.broadcast()
        closedCondition.unlock()
        guard !waiters.isEmpty else { return }
        if Thread.isMainThread {
            waiters.forEach { $0() }
        } else {
            DispatchQueue.main.async { waiters.forEach { $0() } }
        }
    }

    // MARK: Window companions

    /// The InputText boxes open for the skin's measures, by id: what each measure does with the answer.
    private var inputTextAnswers: [Int: (String?) -> Void] = [:]
    /// What each watch of the window's moves calls once they stopped, by id.
    private var windowFollowers: [Int: () -> Void] = [:]
    private var lastCompanionID = 0

    // MARK: LiveSkinHost

    /// Updates stopped by a pause (sleep, locked screens) until a resume: the runtime's own.
    var areUpdatesPaused: Bool { updatesPaused }

    /// The display the window is on, as its facts last said.
    var windowDisplay: CGDirectDisplayID? { model.facts?.display }

    // MARK: SkinHost

    /// The skin redrew: a frame at the end of the turn (`frames`). A new size goes to the window model at once (the skin
    /// reads it right away) and to the main thread, which resizes the window with its top-left corner fixed; the frame
    /// of the new size goes to the content layer, which clips it or leaves a margin until the window follows, never
    /// stretching it.
    func skinNeedsDisplay(_ skin: Skin) {
        HostCallAudit.note(self, "skinNeedsDisplay")
        guard !isClosed else { return }
        let size = SkinRuntime.windowSize(width: skin.width, height: skin.height)
        if size != requestedSize {
            requestedSize = size
            model.resize(to: size, screens: EnvironmentStore.shared.currentScreens)
            if !frames.contentMode.usesLayers { request(.resize(size)) }
        }
        frames.setNeedsFrame()
    }

    /// Largest window side in points: guards against skins whose size formulas explode.
    static let maxWindowSide: CGFloat = 8192

    /// The window size for a skin size: at least 1 point, at most `maxWindowSide`.
    static func windowSize(width: Double, height: Double) -> CGSize {
        func side(_ v: Double) -> CGFloat {
            guard v.isFinite else { return 1 }
            return min(max(CGFloat(v), 1), maxWindowSide)
        }
        return CGSize(width: side(width), height: side(height))
    }

    /// A bang the engine performed with another config's name, or `*` (the engine has performed it here already: every
    /// other running skin follows, in load order).
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        HostCallAudit.note(self, "forward \(bang.name)")
        let name = SkinLibrary.normalizedConfigName(config)
        guard name == "*" else { return send(bang, toConfig: name) }
        guard let directory = directoryStore?.directory else {
            return request(.forward(bang, toConfig: "*", hops: currentHops))
        }
        for target in directory.runtimes where target !== self {
            deliver(bang.name, to: target) { .bang(bang, from: self.config, hops: $0) }
        }
    }

    /// Window, group, config and app bangs: which kind they are is decided here (false: not supported on macOS, and the
    /// engine records a compatibility note). Window bangs change the window model and group bangs go to the group's
    /// skins from here; what the others do is done on the main thread (`SkinWindowController.apply`).
    func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        HostCallAudit.note(self, "handle \(bang.name)")
        guard !isClosed else { return true }
        guard let kind = HostBangs.kind(of: bang.name) else { return false }
        switch kind {
        case .window:
            windowBang(bang)
            return true
        case .group:
            groupBang(bang)
            return true
        case .lifecycle, .ui, .system:
            break
        }
        let host = HostBang(bang: HostBangs.preparedForMain(bang, of: skin), hops: currentHops, whileClosing: isClosing)
        switch kind {
        case .lifecycle: request(.lifecycle(host))
        case .ui: request(.ui(host))
        default: request(.system(host))
        }
        return true
    }

    /// Lua `SKIN:FadeWindow`: the saved AlphaValue stays; the window model notes what it was faded to.
    func skin(_ skin: Skin, fadeWindowFrom from: Int, to: Int) -> Bool {
        HostCallAudit.note(self, "fadeWindow")
        model.settings.fadedAlpha = SkinFadedAlpha(value: min(max(to, 0), 255), base: model.settings.alphaValue)
        request(.fadeWindow(from: from, to: to))
        return true
    }

    /// The needs travel in the snapshot, published when the work ends (`.snapshotChanged(.outsidePointerNeeds)`).
    func skinOutsidePointerNeedsChanged(_ skin: Skin) {}

    func skinWillBeginWork(_ skin: Skin) {
        HostCallAudit.note(self, "skinWillBeginWork")
        workActivity?.begin()
    }

    func skinDidFinishWork(_ skin: Skin) {
        defer { workActivity?.end() }
        HostCallAudit.note(self, "skinDidFinishWork")
        publishSnapshot()
    }

    /// MacGlass: the glass views follow the engine's regions (asked right before the redraw that shows the new layout).
    func skinGlassRegionsChanged(_ skin: Skin, regions: [GlassRegion]) {
        HostCallAudit.note(self, "skinGlassRegionsChanged")
        guard !isClosed else { return }
        if !frames.contentMode.usesLayers { request(.glass(regions)) }
    }

    /// From the window's facts. Debug builds compare with the live window while the skin runs on the main executor.
    func skinWindowTakesPointer(_ skin: Skin) -> Bool {
        HostCallAudit.note(self, "skinWindowTakesPointer")
        let answer = model.takesPointer
        #if DEBUG
        if SnapshotAudit.isActive(self), let live = window?.liveTakesPointer {
            SnapshotAudit.compare("takes the pointer", self, snapshot: answer, live: live, sides: SkinRuntime.auditSides)
        }
        #endif
        return answer
    }

    /// How the debug comparison names the two answers it compares.
    static let auditSides = (predicted: "the window model", live: "the window")

    func skin(_ skin: Skin, execute target: String, arguments: [String]) {
        HostCallAudit.note(self, "execute")
        switch SkinRuntime.executePlan(skin, target: target, arguments: arguments) {
        case .nothing:
            break
        case .unsupported(let t):
            Log.write("Cannot run \"\(t)\" (Windows programs are not supported)", level: .warning, source: config)
        case let plan:
            request(.open(plan))
        }
    }

    /// Extensions of Windows programs, scripts and shortcuts that skins run with `["…"]`; none of them opens on a Mac.
    static let windowsProgramExtensions: Set<String> = ["exe", "com", "bat", "cmd", "scr", "pif", "msi", "vbs", "vbe",
                                                         "js", "jse", "wsf", "wsh", "ps1", "lnk", "ahk"]

    /// What `[target arguments…]` does: a URL opens; an application bundle opens the arguments that are files
    /// (relative to the skin folder) or URLs — the way skins open files in `#CONFIGEDITOR#` — and other arguments
    /// (command-line switches) are dropped; any other existing file opens with its default app; a Windows program
    /// or script is logged as not supported, even when the file exists.
    static func executePlan(_ skin: Skin, target: String, arguments: [String]) -> SkinExecutePlan {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .nothing }
        if let url = URL(string: t), let scheme = url.scheme, scheme.count > 1 { return .open(url) }
        let path = skin.absolutePath(t)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return .unsupported(t) }
        let url = URL(fileURLWithPath: path)
        // A Windows program or script that ships with a skin (`["#CURRENTPATH#Tool.exe"]`): opening it would only make
        // Finder say that macOS cannot open Windows applications, so it is logged instead.
        if !isFolder.boolValue, windowsProgramExtensions.contains(url.pathExtension.lowercased()) { return .unsupported(t) }
        if isFolder.boolValue, url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            let files = arguments.prefix(32).compactMap { raw -> URL? in
                let a = raw.trimmingCharacters(in: .whitespaces)
                guard !a.isEmpty else { return nil }
                if let url = URL(string: a), let scheme = url.scheme, scheme.count > 1 { return url }
                let p = skin.absolutePath(a)
                return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
            }
            if !files.isEmpty { return .openFiles(files, app: url) }
        }
        return .open(url)
    }

    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) {
        HostCallAudit.note(self, "log \(message.prefix(80))")
        Log.write(message, level: level, source: config)
    }

    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        HostCallAudit.note(self, "textSize")
        return SkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }

    func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        HostCallAudit.note(self, "imageSize")
        return Images.size(atPath: path)
    }

    /// The environment store's screens, paths and appearance with the window model's place, Z position and screen
    /// (AutoSelectScreen). Debug builds compare it with the live window's while the skin runs on the main executor.
    func environment(for skin: Skin) -> SkinEnvironment {
        HostCallAudit.note(self, "environment")
        let settings = model.settings
        let env = EnvironmentStore.shared.environment(windowFrame: model.frame, zPosition: settings.zPosition,
                                                      autoSelectScreen: settings.autoSelectScreen)
        #if DEBUG
        if SnapshotAudit.isActive(self), let live = window?.liveEnvironment(for: skin) {
            let compared = Self.environmentForAudit(live, snapshot: env, model: model, requestedSize: requestedSize,
                usesLayers: frames.contentMode.usesLayers, screens: EnvironmentStore.shared.currentScreens)
            SnapshotAudit.compare("environment", self, snapshot: env, live: compared, sides: SkinRuntime.auditSides)
        }
        #endif
        return env
    }

    #if DEBUG
    /// A C frame's logical resize precedes its host acknowledgment. Adjust only this known comparison debt;
    /// the actual window, returned environment and every unrelated audited value stay unchanged.
    static func environmentForAudit(_ live: SkinEnvironment, snapshot: SkinEnvironment, model: SkinWindowModel,
                                    requestedSize: CGSize?, usesLayers: Bool,
                                    screens: [WindowGeometry.Screen]) -> SkinEnvironment {
        guard usesLayers, let size = requestedSize, let facts = model.facts, let frame = model.frame,
              facts.frame.size != size, model.sequence == facts.modelSequence, model.settings == facts.settings else {
            return live
        }
        var resized = SkinWindowModel()
        resized.take(facts)
        resized.resize(to: size, screens: screens)
        guard resized.frame == frame else { return live }
        func geometry(_ frame: CGRect) -> SkinEnvironment {
            EnvironmentStore.environment(windowFrame: frame, screens: screens, settingsPath: snapshot.settingsPath,
                programPath: snapshot.programPath, configEditor: snapshot.configEditor, appearance: snapshot.appearance)
        }
        func selectedScreen(_ frame: CGRect) -> Int {
            // The same frame-dependent selection as EnvironmentStore; a resize may change the selected screen.
            guard model.settings.autoSelectScreen, frame.width > 1 || frame.height > 1 else { return 0 }
            return WindowGeometry.screenIndex(for: frame, screens: screens) ?? 0
        }
        let before = geometry(facts.frame), after = geometry(frame)
        guard live.windowFrame == before.windowFrame, snapshot.windowFrame == after.windowFrame,
              live.screens == before.screens, snapshot.screens == after.screens,
              live.currentScreen == selectedScreen(facts.frame), snapshot.currentScreen == selectedScreen(frame) else {
            return live
        }
        var compared = live
        compared.windowFrame = after.windowFrame
        compared.currentScreen = selectedScreen(frame)
        return compared
    }
    #endif

    // MARK: SkinImageQueries

    // Not audited (`HostCallAudit`): they read only `Images`, which any thread may, and nothing of the runtime. The
    // snapshot's hit map asks them from the main thread (a Button's pixels under the pointer).

    func imageExifOrientation(atPath path: String) -> Int {
        Images.exifOrientation(atPath: path)
    }

    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        Images.pixelAlpha(atPath: path, x: x, y: y, oriented: exifOriented)
    }
}

/// What `[target arguments…]` does (`SkinRuntime.executePlan`).
enum SkinExecutePlan: Equatable {
    case nothing
    /// A URL (`https://…`) or a file / app to open with its default handler.
    case open(URL)
    /// Files given as arguments to an application: `["#CONFIGEDITOR#" "#CURRENTPATH#Settings.inc"]`.
    case openFiles([URL], app: URL)
    case unsupported(String)
}

extension SkinRuntime: SkinCompanionChannel {
    /// On the skin's executor: asked of the main thread in order with the skin's other requests.
    func companion(_ companion: SkinCompanionRequest) {
        HostCallAudit.note(self, "companion")
        request(.companion(companion))
    }

    /// Opens an InputText box over the skin's window; `answered` runs here, on the skin's executor, with what the
    /// person typed (nil: dismissed), unless the box is cancelled or the skin closes first. On the executor.
    func showInputText(_ settings: InputTextSettings, answered: @escaping (String?) -> Void) -> Int {
        HostCallAudit.note(self, "showInputText")
        lastCompanionID += 1
        let id = lastCompanionID
        inputTextAnswers[id] = answered
        let size = CGSize(width: skin.width.isFinite ? skin.width : 0, height: skin.height.isFinite ? skin.height : 0)
        request(.companion(.showInputText(id: id, settings: settings, skinSize: size)))
        return id
    }

    /// Closes the box `id` without an answer. On the executor.
    func cancelInputText(_ id: Int) {
        HostCallAudit.note(self, "cancelInputText")
        guard inputTextAnswers.removeValue(forKey: id) != nil else { return }
        request(.companion(.cancelInputText(id: id)))
    }

    /// Follows the window's moves: `settled` runs here, on the skin's executor, once they stopped, until the watch ends
    /// or the skin closes. On the executor.
    func followWindowMoves(settled: @escaping () -> Void) -> Int {
        HostCallAudit.note(self, "followWindowMoves")
        lastCompanionID += 1
        let id = lastCompanionID
        windowFollowers[id] = settled
        request(.companion(.followWindow(id: id)))
        return id
    }

    /// Ends the watch `id`. On the executor.
    func stopFollowingWindow(_ id: Int) {
        HostCallAudit.note(self, "stopFollowingWindow")
        guard windowFollowers.removeValue(forKey: id) != nil else { return }
        request(.companion(.stopFollowingWindow(id: id)))
    }
}

/// Calls the engine makes to a runtime (its `SkinHost` and companion channel) must come from the skin's executor, as
/// the engine promises its host: a plugin's background work that logs, redraws or runs an action without handing it to
/// the skin's executor first would reach the runtime from another thread, where it races the skin's own work once the
/// skin leaves the main thread. Debug builds note such calls; the self-tests fail the suite in which one was made
/// (`drain`). Exclusive access counts as the owner's (`executor.isCurrent`). The image queries are not audited: any
/// thread may ask them.
enum HostCallAudit {
    private static let stray = Guarded<[String]>([])

    /// Notes `call` when it does not come from `runtime`'s executor. Debug builds only.
    @inline(__always)
    static func note(_ runtime: SkinRuntime, _ call: @autoclosure () -> String) {
        #if DEBUG
        guard let skin = runtime.skin, !skin.executor.isCurrent else { return }
        let thread = Thread.isMainThread ? "the main thread" : (Thread.current.name.flatMap { $0.isEmpty ? nil : $0 }
                                                                 ?? "another thread")
        let note = "\(runtime.config): \(call()) on \(thread)"
        stray.access { if $0.count < 100 { $0.append(note) } }
        #endif
    }

    /// The calls noted since the last drain, and forgets them.
    static func drain() -> [String] {
        stray.access { calls in
            defer { calls = [] }
            return calls
        }
    }
}
