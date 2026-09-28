import AppKit
import DesksetCore

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
final class SkinRuntime: LiveSkinHost, SkinImageQueries {
    let config: String
    let file: String
    let fileURL: URL
    /// The skin. Touch it only on its executor (`executor.isCurrent`, or inside `exclusive`).
    private(set) var skin: Skin!
    /// The main-thread side: the skin's window, or a test's stand-in. Not retained: it owns the runtime.
    weak var window: SkinRuntimeWindow?

    /// Where the skin runs: its executor.
    var executor: SkinExecutor { skin.executor }

    // What the executor owns.
    private var timer: SkinScheduledWork?
    /// OnCloseAction is running, or has run.
    private(set) var isClosing = false
    /// The skin is closed: it takes no more messages.
    private(set) var isClosed = false
    private var updatesPaused = false
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
         content: ContentProvider? = nil) {
        self.config = config
        self.file = file
        fileURL = SkinLibrary.directory(for: config, root: skinsDirectory).appendingPathComponent(file)
        var owner: (() -> Skin?)?
        frames = SkinFrameProducer(provider: content, skin: { owner?() })
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: SystemMonitor.shared,
                        host: self)
        skin.executor = executor
        self.skin = skin
        owner = { [weak self] in self?.skin }
        frames.start(on: executor)
    }

    deinit {
        timer?.cancel()
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
        messageObserver?(message)
        switch message {
        case .mirrorInput(let mirror):
            skin.inputMirror = mirror
            return true
        case .windowFacts(let facts):
            model.take(facts)
            frames.take(model.facts)
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
        case .inputTextAnswered(let id, let text):
            inputTextAnswers.removeValue(forKey: id)?(text)
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
        case .mirrorInput, .windowFacts:
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
        let changes = next.changes(from: old)
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
            window?.apply(request, from: self)
            return
        }
        // A load the main thread has not scheduled yet: bangs for that config wait for it (`isLoadPending`).
        let load = SkinRuntime.configLoaded(by: request)
        if let load { loadsInFlight.access { $0[load, default: 0] += 1 } }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.apply(request, from: self)
            if let load {
                self.loadsInFlight.access {
                    let left = ($0[load] ?? 1) - 1
                    $0[load] = left > 0 ? left : nil
                }
            }
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

    /// Hands `message` (made with the hops it carries) to another skin's runtime: at once when it runs on this thread,
    /// queued there otherwise. A chain of skins triggering each other stops at `maxHops`: the bang is dropped and
    /// logged, once per skin.
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
        target.send(message(currentHops + 1))
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
        milliseconds < 0 ? nil : Double(max(milliseconds, 16)) / 1000
    }

    /// Timer slack that lets macOS coalesce wake-ups (Apple suggests at least 10%); capped so slow skins still tick
    /// on time.
    static func timerTolerance(_ interval: TimeInterval) -> TimeInterval {
        min(interval * 0.1, 0.5)
    }

    /// The update clock is skin work, so it runs on the skin's executor (on the main thread: a Foundation timer in the
    /// common modes, which keeps skins updating while a menu is open).
    private func startTimer() {
        timer?.cancel()
        timer = nil
        guard !isClosed, !updatesPaused, let interval = SkinRuntime.updateInterval(skin.settings.update) else { return }
        timer = skin.executor.timer(interval: interval, leeway: SkinRuntime.timerTolerance(interval),
                                    repeats: true) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.skin.update()
        }
    }

    /// Sleep / screens asleep / session switched away: no updates and no drawing.
    private func pause() {
        guard !updatesPaused else { return }
        updatesPaused = true
        timer?.cancel()
        timer = nil
    }

    /// `updateNow`: catch up at once. Skins with `Update=-1` ("update only once on load or refresh") are not updated:
    /// they have nothing to catch up on, and an extra update would run their OnUpdateAction again.
    private func resume(updateNow: Bool) {
        guard updatesPaused, !isClosed else { return }
        updatesPaused = false
        if updateNow && SkinRuntime.updateInterval(skin.settings.update) != nil { skin.update() }
        startTimer()
    }

    /// The Mac woke from sleep: the engine runs OnWakeAction at the end of the next update ("Action to execute when
    /// Windows returns from the sleep or hibernate states"; at once for Update=-1 skins), which happens right away.
    private func wake() {
        skin.systemDidWake()
        guard !isClosed else { return }
        if updatesPaused {
            resume(updateNow: true)
        } else if SkinRuntime.updateInterval(skin.settings.update) != nil {
            skin.update()
        }
    }

    /// Stops the clock and closes the skin: OnCloseAction runs while the skin can still handle bangs (it cannot reload
    /// or unload itself any more). Then the main thread hears of it (`.closed`, with the ticket of the reload the close is
    /// part of), and whoever waits for the close.
    private func close(ticket: SkinReloadTicket?) {
        guard !isClosing else { return }
        timer?.cancel()
        timer = nil
        isClosing = true
        skin.close()
        isClosed = true
        // The window fades out with the last frame.
        frames.stop()
        // An InputText box still open answers nobody.
        inputTextAnswers = [:]
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
        model.resize(to: size, screens: EnvironmentStore.shared.currentScreens)
        if size != requestedSize {
            requestedSize = size
            request(.resize(size))
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

    func skinDidFinishWork(_ skin: Skin) {
        HostCallAudit.note(self, "skinDidFinishWork")
        publishSnapshot()
    }

    /// MacGlass: the glass views follow the engine's regions (asked right before the redraw that shows the new layout).
    func skinGlassRegionsChanged(_ skin: Skin, regions: [GlassRegion]) {
        HostCallAudit.note(self, "skinGlassRegionsChanged")
        guard !isClosed else { return }
        request(.glass(regions))
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

    /// What `[target arguments…]` does: a URL opens; an application bundle opens the arguments that are files
    /// (relative to the skin folder) or URLs — the way skins open files in `#CONFIGEDITOR#` — and other arguments
    /// (command-line switches) are dropped; any other existing file opens with its default app.
    static func executePlan(_ skin: Skin, target: String, arguments: [String]) -> SkinExecutePlan {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .nothing }
        if let url = URL(string: t), let scheme = url.scheme, scheme.count > 1 { return .open(url) }
        let path = skin.absolutePath(t)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return .unsupported(t) }
        let url = URL(fileURLWithPath: path)
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
            SnapshotAudit.compare("environment", self, snapshot: env, live: live, sides: SkinRuntime.auditSides)
        }
        #endif
        return env
    }

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
