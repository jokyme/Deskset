import AppKit
import DesksetCore

/// The half of a running skin that owns the `Skin` (docs/skin-threading.md §5.4): it is the skin's `SkinHost`, runs its
/// update clock, pause and wake, handles the messages sent to it (`send`) and asks the main thread for what only the
/// main thread can do (`request`). Everything here runs on the skin's executor; the window half,
/// `SkinWindowController`, stays on the main thread and reaches the skin only through this object: messages, or
/// exclusive access (`exclusive`) where it still needs an answer at once.
///
/// Every skin runs on the main executor so far (phase 2 of the design moves the desktop's skins to an engine thread
/// later), so messages and requests run inline and in the order they always did.
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
    /// The hops of the message being handled (0 for the skin's own work): what its forwards to other skins count from.
    private var currentHops = 0
    /// The window facts last received (nil: none yet).
    private(set) var windowFacts: SkinWindowFacts?
    /// What the window side last answered for the environment: the answer off the main thread (step 3 of phase 2
    /// replaces it with the environment store and the window model). nil: never asked.
    private var lastEnvironment: SkinEnvironment?

    /// Told of every message right before it is handled, on the executor (self-tests).
    var messageObserver: ((SkinMessage) -> Void)?

    /// Most bangs one skin passes on to another inside a single chain (`[!Update B]` in A's OnUpdateAction, `[!Update
    /// A]` in B's…): the next one is dropped (and logged).
    static let maxHops = 16

    /// A runtime for `file` of `config` under `skinsDirectory`, on `executor`. Load it with `load()`, on the executor.
    init(config: String, file: String, skinsDirectory: URL, executor: SkinExecutor = MainSkinExecutor.shared) {
        self.config = config
        self.file = file
        fileURL = SkinLibrary.directory(for: config, root: skinsDirectory).appendingPathComponent(file)
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: SystemMonitor.shared,
                        host: self)
        skin.executor = executor
        self.skin = skin
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

    // MARK: Messages

    /// Delivers a message: at once when the caller is on the runtime's executor (then the answer is the skin's: whether
    /// a mouse action was handled; true for other messages that were taken, false when the skin is closed), otherwise
    /// queued there, first in, first out (nil). A hover or window facts queued right behind the same kind, not run yet,
    /// replace it.
    @discardableResult
    func send(_ message: SkinMessage) -> Bool? {
        if executor.isCurrent { return handle(message) }
        enqueue(message)
        return nil
    }

    /// The messages queued and not run yet: the last one, when a later hover or window facts may replace it.
    private let queueLock = NSLock()
    private var coalescingTail: MessageBox?

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
            windowFacts = facts
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
            withHops(hops) { skin.performSent(bang) }
        case .execute(let action, let section):
            skin.executeInput(action, from: section.flatMap { skin.section(named: $0) })
        case .preview(let sections, let variables):
            if !variables.isEmpty { skin.previewVariables(variables) }
            for (section, values) in sections { skin.preview(section: section, values) }
        case .endPreview:
            skin.endPreview()
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
        case .close:
            close()
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

    // MARK: Exclusive access

    /// How long the main thread waits for a skin on another thread to park by default: a stand-in until the snapshot
    /// (step 2 of phase 2) answers what the window reads of the skin.
    static let defaultExclusiveTimeout: TimeInterval = 0.25

    /// Runs `body` with the live skin while its own work waits (`SkinExecutor.exclusive`): at once on the executor,
    /// nil when a skin on another thread does not park within `timeout`.
    @discardableResult
    func exclusive<T>(timeout: TimeInterval = SkinRuntime.defaultExclusiveTimeout, _ body: (Skin) -> T) -> T? {
        let skin: Skin = self.skin
        return skin.executor.exclusive(timeout: timeout) { body(skin) }
    }

    /// Before the first update of a refreshed skin: the Calc `Counter` goes on from the skin `previous` ran (manual:
    /// it "only resets when the skin is unloaded and then loaded again - not when the skin is refreshed").
    func continueCounter(from previous: SkinRuntime) {
        _ = previous.exclusive { old in exclusive { $0.continueCounter(from: old) } }
    }

    // MARK: Requests

    /// Asks the main thread: at once when on it, else queued there in order.
    func request(_ request: SkinRequest) {
        if Thread.isMainThread {
            window?.apply(request, from: self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.apply(request, from: self)
            }
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
    /// or unload itself any more).
    private func close() {
        guard !isClosing else { return }
        timer?.cancel()
        timer = nil
        isClosing = true
        skin.close()
        isClosed = true
    }

    // MARK: LiveSkinHost

    /// Updates stopped by a pause (sleep, locked screens) until a resume.
    var areUpdatesPaused: Bool { updatesPaused }

    var windowScreen: NSScreen? {
        Thread.isMainThread ? window?.screen : nil
    }

    // MARK: SkinHost

    func skinNeedsDisplay(_ skin: Skin) {
        guard !isClosed else { return }
        request(.display(size: SkinRuntime.windowSize(width: skin.width, height: skin.height)))
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

    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        request(.forward(bang, toConfig: config, hops: currentHops))
    }

    /// Window, config and app bangs: which kind they are is decided here (false: not supported on macOS, and the
    /// engine records a compatibility note); what they do is done on the main thread (`SkinWindowController.apply`).
    func skin(_ skin: Skin, handle bang: Bang) -> Bool {
        guard !isClosed else { return true }
        guard let kind = HostBangs.kind(of: bang.name) else { return false }
        let host = HostBang(bang: HostBangs.preparedForMain(bang, of: skin), hops: currentHops, whileClosing: isClosing)
        switch kind {
        case .window: request(.window(host))
        case .lifecycle: request(.lifecycle(host))
        case .group: request(.group(host))
        case .ui: request(.ui(host))
        case .system: request(.system(host))
        }
        return true
    }

    func skin(_ skin: Skin, fadeWindowFrom from: Int, to: Int) -> Bool {
        request(.fadeWindow(from: from, to: to))
        return true
    }

    func skinOutsidePointerNeedsChanged(_ skin: Skin) {
        request(.outsidePointerNeedsChanged)
    }

    /// MacGlass: the glass views follow the engine's regions (asked right before the redraw that shows the new layout).
    func skinGlassRegionsChanged(_ skin: Skin, regions: [GlassRegion]) {
        guard !isClosed else { return }
        request(.glass(regions))
    }

    func skinWindowTakesPointer(_ skin: Skin) -> Bool {
        if Thread.isMainThread, let window { return window.takesPointer }
        return windowFacts?.takesPointer ?? true
    }

    func skin(_ skin: Skin, execute target: String, arguments: [String]) {
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
        Log.write(message, level: level, source: config)
    }

    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        SkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }

    func imageSize(atPath path: String) -> (width: Double, height: Double)? {
        Images.size(atPath: path)
    }

    /// The window side's answer on the main thread; elsewhere the one it gave last (the engine's defaults before it
    /// answered).
    func environment(for skin: Skin) -> SkinEnvironment {
        if Thread.isMainThread, let window {
            let env = window.environment(for: skin)
            lastEnvironment = env
            return env
        }
        return lastEnvironment ?? SkinEnvironment()
    }

    // MARK: SkinImageQueries

    func imageExifOrientation(atPath path: String) -> Int { Images.exifOrientation(atPath: path) }

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
