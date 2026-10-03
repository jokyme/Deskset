import AppKit
import DesksetCore
import DesksetRuntime

/// The main-thread half of a running skin (docs/skin-threading.md §5.4): its window (`SkinPanel`, `SkinView`, the
/// glass), fades, hover polling, placement, dragging, snapping and keeping on screen, and the skin's `AppState`. The
/// other half, `SkinRuntime`, owns the `Skin`; this one reaches it only through the runtime: messages (`runtime.send`),
/// the skin's snapshot (`runtime.snapshot`), or exclusive access (`runtime.exclusive`) where it still reads the live
/// skin. It applies what the runtime asks of the main thread (`apply`), and tells the runtime what it did with the
/// window after every change (`publishFacts`): the runtime's window model (`SkinWindowModel`) follows it.
///
/// Its life: `AppController.activate` makes it and sends the runtime `.load`; the settings a first load seeds apply when
/// the runtime reports `.loaded`, the window is placed and shown when it reports `.started` (after the skin's first
/// update), and unloaded when it reports `.failed`. `stop` sends `.close`; the runtime
/// reports `.closed` when OnCloseAction has run. With the main executor all of it happens inside `activate` and `stop`.
/// The windows plugins show with it (FrostedGlass's backdrop, InputText's box) are its companions (`companions`).
final class SkinWindowController: NSObject, NSWindowDelegate, SkinRuntimeWindow, SkinCompanionHost {
    let config: String
    let file: String
    /// The skin's main file.
    var fileURL: URL { runtime.fileURL }
    /// The half that owns the skin.
    let runtime: SkinRuntime
    /// The live skin, for the self-tests, which own their skins on the main thread. App code goes through `runtime`.
    var skin: Skin! { runtime.skin }
    private(set) var window: SkinPanel
    /// The window's content view: the glass (`MacGlass`), then `view` in front of it.
    let contentView: SkinContentView
    let view: SkinView
    /// Where the skin's frames go: a layer of their own in `view`'s layer. Only the runtime's frame producer presents
    /// frames; the window tears it down once it has closed.
    let content: LayerContentProvider
    let contentMode: SkinFrameContentMode
    private var layerInstallRetryQueued = false
    private var layerPanelRetryQueued = false
    private var deferredLayerOrderIn: (alpha: CGFloat, fade: TimeInterval)?
    private var layerStartPending: SkinStartReport?
    /// The glass behind the skin's drawing (`MacGlass`), in `contentView`.
    let glass = SkinGlassViews()
    /// FrostedGlass's backdrop and InputText's boxes, which the skin's plugins ask for.
    private(set) var companions: SkinWindowCompanions!
    private var hoverTimer: Timer?
    unowned let app: AppController
    /// The same app, held weakly: a window half that outlives its app (a self-test's, kept until its skin closed) must
    /// not reach it when AppKit calls its view afterwards (an appearance change reaches every window).
    private weak var owningApp: AppController?

    /// Hidden with !Hide / !HideFade (the skin keeps updating).
    private(set) var isHiddenByBang = false
    /// The mouse is over the skin window (tracked only when OnHover is set).
    private(set) var isHovering = false
    private(set) var isStopped = false
    /// The skin is being closed (`stop`): OnCloseAction is running.
    private var isClosing = false
    /// The runtime reported `.loaded`: the window's settings apply.
    private(set) var isLoaded = false
    /// The runtime reported `.started`: the window is placed and shown (or kept hidden: StartHidden).
    private(set) var isStarted = false
    /// The runtime reported `.failed`: the skin could not be loaded, and the window was never shown.
    private(set) var loadFailed = false
    /// The runtime was sent `.load` (`load(_:fadeIn:)`).
    private var loadSent = false
    /// What waits for `.started` (`whenStarted`).
    private var startWaiters: [() -> Void] = []
    /// What waits for the start to be over, however it ends (`whenSettled`).
    private var settleWaiters: [() -> Void] = []
    /// The runtime reported `.closed`: OnCloseAction has run.
    private(set) var hasClosed = false
    /// Until the skin loaded, the window's facts wait (the first ones excepted): the runtime seeds its model with the
    /// first load's Default… settings, which `AppState` has only once the load is reported.
    private var holdsFacts = false
    /// How the window is shown once the skin started: fading in, and whether the windows are stacked again.
    private var startFade = false
    var restacksWhenStarted = true
    /// The reload the Studio asked for that made this window (`SkinReloadTicket`, from the load order): the Studio's
    /// editing session knows the copy as its own by it.
    private(set) var reloadTicket: SkinReloadTicket?
    /// Where the window goes once the skin started (top-left, as `moveTo` takes it): a step of the Studio that moves the
    /// widget with its files. Applied right after the window is placed, before it is shown.
    var moveWhenStarted: WidgetPosition?
    /// The window of the copy this one replaces, kept on screen with its last frame (`stop(keepsWindow:)`) until this
    /// one has started, failed or been stopped (`settled`): a reload on another thread does not make the widget vanish
    /// meanwhile.
    var replacedWindow: SkinWindowController?
    /// The window was stopped but kept (`stop(keepsWindow:)`) until the copy replacing it settles.
    private(set) var isKeptForReplacement = false
    /// The skin's updates are paused (as the runtime's: `pauseUpdates` / `resumeUpdates`): no hover tracking meanwhile.
    private var updatesPaused = false
    /// Updates stopped by `pauseUpdates()` (sleep, locked screens) until `resumeUpdates`.
    var areUpdatesPaused: Bool { updatesPaused }
    /// Lua `SKIN:FadeWindow`: the alpha (0…255) the window was faded to, and the saved AlphaValue it stands in for.
    /// It is not saved: a refresh, or any change of the saved AlphaValue (!SetTransparency, the menu, the Manage
    /// window), ends it.
    private(set) var fadedAlpha: (value: Int, base: Int)?
    private var fadeGeneration = 0

    /// The last of the skin's own window changes applied here (`SkinWindowFacts.modelSequence`).
    private var appliedModelSequence = 0
    /// Counts the facts published, and the ones sent last.
    private var factsSequence = 0
    private var sentFacts: SkinWindowFacts?
    /// A press on the skin that may drag its window is under way (`SkinView`): the skin's moves wait for its release.
    private(set) var isDragPressActive = false
    /// The skin's latest move while a press may drag the window: applied at the release, unless the press became a
    /// drag (a drag in progress wins).
    private(set) var heldMove: SkinWindowChange?

    /// Largest window side in points: guards against skins whose size formulas explode.
    static let maxWindowSide: CGFloat = SkinRuntime.maxWindowSide
    /// Most bangs one skin passes on to another inside a single chain.
    static let maxForwardDepth = SkinRuntime.maxHops

    var state: SkinState { app.state.skin(config) ?? SkinState(file: file) }

    /// The skin defines OnFocusAction or OnUnfocusAction (from the snapshot).
    var wantsFocus: Bool {
        SnapshotAudit.check("wantsFocus", runtime, snapshot: runtime.snapshot.wantsFocus,
                            live: { !$0.settings.onFocusAction.isEmpty || !$0.settings.onUnfocusAction.isEmpty })
    }

    /// Whether the skin can currently be seen (loaded, not hidden by a bang).
    var isShown: Bool { !isStopped && !isHiddenByBang && window.isVisible }

    /// A window for `file` of `config` whose skin runs on `executor` (the main executor, unless a self-test puts it on
    /// a thread of its own) and loads when it is sent `.load` (`load(_:fadeIn:)`).
    init(config: String, file: String, app: AppController, executor: SkinExecutor,
         contentMode: SkinFrameContentMode = .bitmap) {
        self.config = config
        self.file = file
        self.app = app
        self.contentMode = contentMode
        owningApp = app
        view = SkinView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        contentView = SkinContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        contentView.addSubview(view)
        content = LayerContentProvider(in: view)
        window = SkinWindowController.makePanel()
        runtime = SkinRuntime(config: config, file: file, skinsDirectory: app.skinsDirectory, executor: executor,
                              content: content, contentMode: contentMode,
                              defersPeerBangs: app.threading == .pool, watchdog: app.workWatchdog)
        super.init()
        companions = SkinWindowCompanions(host: self, runtime: runtime)
        runtime.window = self
        runtime.directoryStore = app.skinDirectory
        // The window model starts from the window as it is: loading may read #CURRENTCONFIGX# already.
        publishFacts()
        holdsFacts = true
        window.contentView = contentView
    }

    /// Self-tests: a window whose skin loads at once, on the main executor, and is not started (`start(fadeIn:)`
    /// starts it). Throws when the skin cannot be loaded.
    convenience init(config: String, file: String, app: AppController) throws {
        self.init(config: config, file: file, app: app, executor: MainSkinExecutor.shared)
        holdsFacts = false
        let loaded = try runtime.load()
        wireUp()
        if loaded.registeredFonts { app.fontsChanged(except: self) }
        for issue in loaded.issues { Log.write(issue, level: .warning, source: config) }
    }

    /// The window takes AppKit's calls once the skin loaded (NSWindow does not retain its delegate).
    private func wireUp() {
        window.delegate = self
        view.controller = self
    }

    static func makePanel() -> SkinPanel {
        let panel = SkinPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        // AppKit shows a window's tooltips only while its app is active, and Deskset (a menu bar app whose panels
        // never activate it) almost never is: skin tooltips (ToolTipText) show whichever app is in front.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        // ⌘H (hiding the app from the Manage window) must not hide the widgets.
        panel.canHide = false
        panel.level = WindowGeometry.level(forAlwaysOnTop: -2)
        panel.collectionBehavior = WindowGeometry.collectionBehavior(forAlwaysOnTop: -2)
        // `ignoresMouseEvents` is deliberately left at its default: then clicks on fully transparent pixels pass
        // through to what is below, like Rainmeter (skins use `SolidColor=0,0,0,1` to make an area clickable).
        return panel
    }

    // MARK: Lifecycle

    /// Sends the runtime `.load`: it loads and starts the skin and reports `.loaded` and `.started` (then the window is
    /// placed and shown, fading in over FadeDuration when `fadeIn`) or `.failed`. With the main executor all of it
    /// happens before this returns.
    func load(_ order: SkinLoadOrder, fadeIn: Bool) {
        loadSent = true
        startFade = fadeIn
        updatesPaused = order.paused
        reloadTicket = order.ticket
        runtime.send(.load(order))
    }

    /// `.loaded`: the skin loaded (its first update comes next). Its fonts and notes reach the app, a first load's
    /// Default… settings are saved, and StartHidden and the window settings apply, as before the first update.
    private func loaded(_ report: SkinLoadReport) {
        guard !isStopped, !isLoaded else { return }
        isLoaded = true
        holdsFacts = false
        wireUp()
        // Skins measured before these fonts existed drew their text with a fallback font. (Fonts also announces the
        // change, later; `fontsChanged` does not pass the same fonts on twice.)
        if report.registeredFonts { app.fontsChanged(except: self) }
        for issue in report.issues { Log.write(issue, level: .warning, source: config) }
        seed(report.windowDefaults)
        prepareToShow()
    }

    /// `.started`: the skin made its first update. The window is placed and shown; then the app hears of it, and the
    /// Studio of its reload (after the Studio followed the new copy: `AppController.skinStarted`).
    private func started(_ report: SkinStartReport) {
        guard !isStopped, isLoaded, !isStarted else { return }
        if contentMode.usesLayers, !content.hasLayerFrame, !isHiddenByBang {
            // A successful load is not a successful content installation. Keep a replacement's old window until
            // its first actual C frame is attached; failure/missing profile must not settle into an empty window.
            layerStartPending = report
            placeWindow(size: report.size)
            publishFacts(force: true)
            runtime.send(.firstFrame)
            return
        }
        layerStartPending = nil
        isStarted = true
        show(fadeIn: startFade, size: report.size)
        app.skinStarted(self)
        if let ticket = report.ticket { app.studioReload(ticket, .started, self) }
        let waiters = startWaiters
        startWaiters = []
        for body in waiters { body() }
        settled()
    }

    /// The runtime was sent `.load` and has reported neither `.started` nor `.failed` yet, and the window was not stopped
    /// meanwhile: a skin on a thread of its own is loading (with the main executor, never once `activate` returned).
    var isStarting: Bool { loadSent && !isStarted && !loadFailed && !isStopped }

    /// Runs `body` on the main thread once the skin has started and its window is placed (`.started`); at once when it
    /// is not starting (`isStarting`). A `body` still waiting is dropped when the skin never starts (the load failed, or
    /// the window was stopped first). What uses the window right after `activate` waits with it (the Studio opening on
    /// a skin it just loaded).
    func whenStarted(_ body: @escaping () -> Void) {
        guard isStarting else { return body() }
        startWaiters.append(body)
    }

    /// Runs `body` on the main thread once the skin is no longer starting (`isStarting`): it started, its load failed,
    /// or the window was stopped first; at once when it is not starting. Loading skins one after another waits with it
    /// (`AppController.activateInOrder`).
    func whenSettled(_ body: @escaping () -> Void) {
        guard isStarting else { return body() }
        settleWaiters.append(body)
    }

    private func settled() {
        if let old = replacedWindow {
            replacedWindow = nil
            old.closeReplacedWindow(by: self)
        }
        let waiters = settleWaiters
        settleWaiters = []
        for body in waiters { body() }
    }

    /// The window kept for this copy, which has not started: it is handed on to the copy replacing this one.
    func takeReplacedWindow() -> SkinWindowController? {
        defer { replacedWindow = nil }
        return replacedWindow
    }

    /// The copy replacing this one settled (`replacedWindow`): the new window, when it shows, goes where this one was in
    /// the stacking, and this one closes.
    func closeReplacedWindow(by new: SkinWindowController) {
        guard isKeptForReplacement else { return }
        isKeptForReplacement = false
        if app.presentsWindows && window.isVisible && new.window.isVisible {
            new.window.order(.above, relativeTo: window.windowNumber)
        }
        window.orderOut(nil)
        window.close()
        companions.tearDown()
        runtime.teardownContent()
    }

    /// `.failed`: the skin could not be loaded. The window, never shown, goes; the app unloads the config, and the
    /// Studio hears of its reload.
    private func failed(_ error: String, ticket: SkinReloadTicket?) {
        guard !loadFailed, !isLoaded else { return }
        loadFailed = true
        startWaiters = []
        holdsFacts = false
        isStopped = true
        hasClosed = true
        window.delegate = nil
        window.close()
        companions.tearDown()
        runtime.teardownContent()
        app.skinFailed(self, error: error)
        if let ticket { app.studioReload(ticket, .failed, self) }
        settled()
    }

    /// Self-tests: starts a window whose skin loaded at once (`init(config:file:app:)`): the first update, placement,
    /// then the window is shown (fading in over FadeDuration when `fadeIn`). With StartHidden it stays hidden until
    /// !Show.
    func start(fadeIn: Bool) {
        guard !isStarted, !isStopped else { return }
        isLoaded = true
        isStarted = true
        prepareToShow()
        // The first update, then the update clock (which never fires inline).
        runtime.send(.start)
        show(fadeIn: fadeIn, size: runtime.snapshot.size)
    }

    /// Before the skin's first update: StartHidden, and the window settings (published: the model has the settings a
    /// first load seeded, which the runtime gave it already).
    private func prepareToShow() {
        if state.startHidden { isHiddenByBang = true }
        applyWindowSettings()
    }

    /// How many times the window was placed and shown at a start (ordered in when the app presents windows and the skin
    /// does not start hidden). Self-tests.
    private(set) var showCount = 0

    /// Places the window for a skin of `size` (then where a step of the Studio moves it: `moveWhenStarted`) and shows
    /// it with its first frame (fading in when `fadeIn`), unless it starts hidden.
    private func show(fadeIn: Bool, size: CGSize) {
        showCount += 1
        placeWindow(size: size)
        if let place = moveWhenStarted {
            moveWhenStarted = nil
            moveTo(x: place.x, y: place.y)
        }
        if app.presentsWindows && !isHiddenByBang {
            let target = targetAlpha
            let duration = fadeIn ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
            let ordered = orderIn(alpha: duration > 0 ? 0 : target)
            if duration > 0 {
                if ordered { animateAlpha(to: target, duration: duration) }
                else { deferredLayerOrderIn?.fade = duration }
            }
        }
        publishFacts()
    }

    /// `.closed`: OnCloseAction has run. The Studio hears of it when the close was part of a reload it asked for.
    private func closed(ticket: SkinReloadTicket?) {
        hasClosed = true
        if let ticket { app.studioReload(ticket, .closed, self) }
    }

    /// Self-tests: told right before the window is ordered in (`orderIn`).
    var willOrderIn: (() -> Void)?

    /// Orders the window in at `alpha`, with its first frame drawn already: a skin's window never shows before its
    /// skin has drawn (a skin that started hidden draws its first frame here). The headless self-tests call it to see
    /// what the window would show: without presented windows nothing is ordered in.
    @discardableResult
    func orderIn(alpha: CGFloat) -> Bool {
        runtime.send(.firstFrame)
        if contentMode.usesLayers, !content.hasLayerFrame {
            deferredLayerOrderIn = (alpha, 0)
            return false
        }
        deferredLayerOrderIn = nil
        willOrderIn?()
        guard app.presentsWindows else { return true }
        window.alphaValue = alpha
        window.orderFrontRegardless()
        return true
    }

    /// Stops updating, runs OnCloseAction (the runtime reports `.closed` when it has: `runtime.whenClosed`) and
    /// closes the window (fading out when `fadeOut`), with its companions. `ticket`: the reload the Studio asked for
    /// that this close is part of (the Studio hears of the close, then of `.closed`).
    ///
    /// `keepsWindow`: the copy replacing this one loads on another thread; the window stays as it is, showing its last
    /// frame, until that copy settles (`closeReplacedWindow`). Its InputText boxes close now.
    func stop(fadeOut: Bool = false, ticket: SkinReloadTicket? = nil, keepsWindow: Bool = false) {
        guard !isStopped, !isClosing else { return }
        startWaiters = []
        hoverTimer?.invalidate()
        hoverTimer = nil
        // A copy a reload of the Studio's made, stopped before it started, will never report its start.
        if let own = reloadTicket, !isStarted, !loadFailed { app.studioReload(own, .abandoned, self) }
        if let ticket { app.studioReload(ticket, .closing, self) }
        // OnCloseAction runs while the skin can still handle bangs (it cannot reload or unload itself any more).
        runtime.rollbackVisibleNativePublication(provider: content, failure: .cancelled)
        isClosing = true
        layerStartPending = nil
        deferredLayerOrderIn = nil
        runtime.send(.close(fadeOut: fadeOut, ticket: ticket))
        // This window half stays until the skin has closed (at once on the main executor): OnCloseAction's requests
        // (config, menu and system bangs, what it opens, bangs for configs that are loading) and the Studio's
        // `.closed(ticket)` come through it.
        runtime.whenClosed { withExtendedLifetime(self) {} }
        isStopped = true
        endDragPress(moved: false)
        holdsFacts = false
        publishFacts()
        let window = self.window
        window.delegate = nil
        fadeGeneration += 1
        let duration = fadeOut && window.isVisible && app.presentsWindows
            ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
        let companions = self.companions!
        defer { settled() }
        if keepsWindow {
            isKeptForReplacement = true
            companions.closeInputTexts()
            return
        }
        guard duration > 0 else {
            window.orderOut(nil)
            window.close()
            companions.tearDown()
            runtime.teardownContent()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = 0
            companions.animateAlpha(to: 0)
        }, completionHandler: {
            // Keeps the controller (and so the skin's last frame) alive until the fade has finished.
            withExtendedLifetime(self) {
                window.orderOut(nil)
                window.close()
                companions.tearDown()
                self.runtime.teardownContent()
            }
        })
    }

    // MARK: Updates

    /// `Update` in ms → timer interval (`SkinRuntime.updateInterval`).
    static func updateInterval(_ milliseconds: Int) -> TimeInterval? { SkinRuntime.updateInterval(milliseconds) }

    /// The update clock's slack (`SkinRuntime.timerTolerance`).
    static func timerTolerance(_ interval: TimeInterval) -> TimeInterval { SkinRuntime.timerTolerance(interval) }

    /// Sleep / screens asleep / session switched away: no updates and no drawing.
    func pauseUpdates() {
        guard !updatesPaused else { return }
        updatesPaused = true
        runtime.send(.pause)
        updateHoverTracking()
    }

    /// `updateNow`: catch up at once (not for `Update=-1` skins: see `SkinRuntime`).
    func resumeUpdates(updateNow: Bool) {
        guard updatesPaused, !isStopped else { return }
        updatesPaused = false
        runtime.send(.resume(updateNow: updateNow))
        updateHoverTracking()
    }

    /// The Mac woke from sleep: the skin runs OnWakeAction and updates, and its clock starts again when it was paused.
    func systemDidWake() {
        guard !isStopped else { return }
        runtime.send(.wake)
        guard !isStopped, updatesPaused else { return }
        updatesPaused = false
        updateHoverTracking()
    }

    // MARK: Window settings

    func applyWindowSettings(animated: Bool = false) {
        guard !isStopped else { return }
        let s = state
        window.level = WindowGeometry.level(forAlwaysOnTop: s.alwaysOnTop)
        window.collectionBehavior = WindowGeometry.collectionBehavior(forAlwaysOnTop: s.alwaysOnTop)
        updateHoverTracking()
        applyMouseHandling()
        applyAlpha(animated: animated)
        // A pending !HideFade may have been cut short by the new alpha: make sure a hidden skin is really gone.
        if isHiddenByBang && window.isVisible { window.orderOut(nil) }
        // ClickThrough has no tooltips.
        view.updateToolTips()
        publishFacts()
    }

    private var targetAlpha: CGFloat {
        let s = state
        return SkinVisibility.targetAlpha(alphaValue: effectiveAlphaValue, onHover: s.onHover, hovering: isHovering,
                                          hidden: isHiddenByBang)
    }

    /// The saved AlphaValue, or the value a Lua FadeWindow faded to while that AlphaValue is unchanged.
    var effectiveAlphaValue: Int {
        let saved = state.alphaValue
        if let faded = fadedAlpha, faded.base == saved { return faded.value }
        return saved
    }

    /// Ends a Lua FadeWindow override (the saved AlphaValue was set again, even to the same value).
    func clearFadedAlpha() {
        fadedAlpha = nil
        publishFacts()
    }

    /// Lua `SKIN:FadeWindow(from, to)`: the window goes to `from` and fades to `to` (0…255) over FadeDuration. The
    /// saved AlphaValue does not change (see `fadedAlpha`); OnHover and !Hide / !Show work on top of the new value.
    func fadeWindow(from: Int, to: Int) {
        guard !isStopped else { return }
        let from = min(max(from, 0), 255), to = min(max(to, 0), 255)
        fadedAlpha = (to, state.alphaValue)
        defer { publishFacts() }
        guard !isHiddenByBang else { return }
        let duration = SkinVisibility.fadeSeconds(state.fadeDuration)
        if duration > 0 && app.presentsWindows && window.isVisible { window.alphaValue = CGFloat(from) / 255 }
        animateAlpha(to: targetAlpha, duration: duration)
    }

    /// ClickThrough ("all mouse over detection is disabled, and mouse clicks will pass through the skin") and
    /// OnHover=Hide while hovered.
    private func applyMouseHandling() {
        let s = state
        let ignore = s.clickThrough
            || (isHovering && SkinVisibility.passesClicksWhileHovering(onHover: s.onHover))
        if ignore {
            if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        } else if window.ignoresMouseEvents {
            // Setting `ignoresMouseEvents = false` would make even fully transparent pixels catch clicks; a fresh
            // panel gets the default per-pixel behaviour back.
            replacePanel()
        }
        if ignore {
            runtime.send(.pointer(.exited, x: -1, y: -1))
            runtime.send(.exited)
        }
    }

    private(set) var panelGeneration: UInt64 = 0
    private var applyingScenePatch: SkinScenePatch?
    private var lastLayerGeneration: UInt64 = 0
    #if DEBUG
    /// Controlled native fixture: entered only after the real main callback owns this contentRoot writer.
    var willApplyScenePatch: ((SkinScenePatch) -> Void)?
    #endif

    private func replacePanel() {
        if applyingScenePatch != nil {
            guard !layerPanelRetryQueued else { return }
            layerPanelRetryQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layerPanelRetryQueued = false
                guard !self.isStopped else { return }
                self.applyWindowSettings()
            }
            return
        }
        if contentMode.usesLayers {
            // The provider/view move intact. Pause its actual owner before AppKit moves their host layer tree.
            let changed = runtime.exclusive { _ in self.replacePanelNow() }
            if changed == nil, !layerPanelRetryQueued {
                layerPanelRetryQueued = true
                runtime.whenCaughtUp { [weak self] in
                    guard let self else { return }
                    self.layerPanelRetryQueued = false
                    guard !self.isStopped else { return }
                    self.applyWindowSettings()
                }
            }
            return
        }
        replacePanelNow()
    }

    private func replacePanelNow() {
        runtime.rollbackVisibleNativePublication(provider: content, failure: .staleDestination)
        let (generation, overflow) = panelGeneration.addingReportingOverflow(1)
        guard !overflow else { return }
        panelGeneration = generation
        let old = window
        let panel = SkinWindowController.makePanel()
        panel.setFrame(old.frame, display: false)
        panel.level = old.level
        panel.collectionBehavior = old.collectionBehavior
        panel.alphaValue = old.alphaValue
        old.delegate = nil
        // The skin's drawing and its glass move to the new panel together.
        panel.contentView = contentView
        panel.delegate = self
        window = panel
        if old.isVisible && app.presentsWindows {
            panel.order(.above, relativeTo: old.windowNumber)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        old.orderOut(nil)
        old.close()
        runtime.send(.frameWanted)
    }

    private func applyAlpha(animated: Bool) {
        animateAlpha(to: targetAlpha, duration: animated ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0)
    }

    private func animateAlpha(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeGeneration += 1
        let generation = fadeGeneration
        guard duration > 0, app.presentsWindows else {
            window.alphaValue = target
            companions.windowChanged()
            completion?()
            return
        }
        let window = self.window, companions = self.companions!
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
            companions.animateAlpha(to: target)
        }, completionHandler: { [weak self] in
            guard let self, generation == self.fadeGeneration else { return }
            completion?()
        })
    }

    /// Whether a click brings the skin in front of the windows at its level. AlwaysOnTop manual: "Normal. … will be
    /// brought to the foreground"; a clicked Topmost skin likewise comes in front of other topmost windows (a
    /// non-activating panel is not raised by AppKit on its own). Bottom and On Desktop skins "stay behind other
    /// normal application windows" in load order; Stay Topmost has its own level.
    static func bringsToFrontOnClick(alwaysOnTop: Int) -> Bool { alwaysOnTop == 0 || alwaysOnTop == 1 }

    func bringToFrontOnClick() {
        guard app.presentsWindows, !isStopped, !isHiddenByBang, window.isVisible,
              SkinWindowController.bringsToFrontOnClick(alwaysOnTop: state.alwaysOnTop) else { return }
        window.orderFrontRegardless()
    }

    /// !Show / !Hide (`fade`: !ShowFade / !HideFade, over FadeDuration).
    func setHidden(_ hidden: Bool, fade: Bool) {
        guard !isStopped else { return }
        isHiddenByBang = hidden
        defer { publishFacts() }
        updateHoverTracking()
        let duration = fade ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
        if hidden {
            animateAlpha(to: 0, duration: window.isVisible ? duration : 0) { [weak self] in
                guard let self, self.isHiddenByBang else { return }
                self.window.orderOut(nil)
                self.publishFacts()
            }
        } else {
            if !window.isVisible && app.presentsWindows {
                // A skin that started hidden shows its first frame; the others one frame, when they redrew meanwhile
                // (the window's facts tell the runtime it can be seen again).
                if !orderIn(alpha: duration > 0 ? 0 : targetAlpha) { deferredLayerOrderIn?.fade = duration }
            }
            applyMouseHandling()
            animateAlpha(to: targetAlpha, duration: duration)
        }
    }

    // MARK: OnHover

    private func updateHoverTracking() {
        let wanted = state.onHover != 0 && isLoaded && !isHiddenByBang && !isStopped && !updatesPaused
        if wanted {
            guard hoverTimer == nil else { return }
            // The window may ignore the mouse (ClickThrough, or hidden by OnHover=Hide), so hover is detected by
            // polling the pointer position rather than with tracking areas.
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollHover() }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            hoverTimer = t
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            isHovering = false
        }
    }

    private func pollHover() {
        let inside = window.isVisible && window.frame.contains(NSEvent.mouseLocation)
        guard inside != isHovering else { return }
        isHovering = inside
        applyMouseHandling()
        applyAlpha(animated: true)
        publishFacts()
    }

    // MARK: Placement

    private var screens: [WindowGeometry.Screen] { EnvironmentStore.shared.currentScreens }
    private var primaryHeight: CGFloat { WindowGeometry.primaryHeight(screens) }

    /// The window size for the skin's size (from the snapshot).
    private var skinSize: NSSize { runtime.snapshot.size }

    /// KeepOnScreen, or at least not lost entirely off-screen.
    private func constrained(_ frame: CGRect) -> CGRect {
        let screens = self.screens
        return state.keepOnScreen ? WindowGeometry.keptOnScreen(frame, screens: screens)
            : WindowGeometry.rescuedIfOffScreen(frame, screens: screens)
    }

    func keptOnScreen(_ frame: CGRect) -> CGRect { WindowGeometry.keptOnScreen(frame, screens: screens) }

    /// `DefaultWindowX` / `DefaultWindowY` / `DefaultAnchorX` / `DefaultAnchorY` of a config loaded for the first
    /// time (see `seed(_:)`), used by the first placement.
    private var defaultPosition: (x: String, y: String, anchorX: String, anchorY: String)?

    /// First load of a config (no saved settings): the skin's `Default…` options in `[Rainmeter]` (`defaults`, which
    /// its runtime read and seeded its window model with) become its window settings (manual: skin sections of
    /// Rainmeter.ini, and "Default" values a skin may set for them).
    private func seed(_ defaults: [String: String]) {
        guard !defaults.isEmpty else { return }
        app.state.update(config) { $0 = $0.seeded(with: defaults) }
        func value(_ key: String) -> String? { defaults[key].flatMap { $0.isEmpty ? nil : $0 } }
        if value("WindowX") != nil || value("WindowY") != nil {
            defaultPosition = (value("WindowX") ?? "0", value("WindowY") ?? "0", value("AnchorX") ?? "0",
                               value("AnchorY") ?? "0")
        }
    }

    /// `state` with the values of `defaults` (keys as in `SkinSettings.windowDefaults`) that can be read; the
    /// others keep their current value (`SkinState.seeded(with:)`).
    static func seededState(_ state: SkinState, defaults: [String: String]) -> SkinState {
        state.seeded(with: defaults)
    }

    /// Positions the window from saved state (top-left coordinates), the position it had earlier in this session
    /// (SavePosition=0), the skin's DefaultWindowX / DefaultWindowY on its first load, or cascades a new skin. `size`:
    /// the skin's (its snapshot's when nil).
    func placeWindow(size: CGSize? = nil) {
        let size = size ?? skinSize
        let s = state
        let ph = primaryHeight
        var frame: CGRect
        var isNew = false
        if s.savePosition, let x = s.x, let y = s.y {
            frame = WindowGeometry.frame(topLeftX: x, y: y, size: size, primaryHeight: ph)
        } else if let p = app.sessionPositions[config.lowercased()] ?? s.x.flatMap({ x in s.y.map { (x, $0) } }) {
            frame = WindowGeometry.frame(topLeftX: p.0, y: p.1, size: size, primaryHeight: ph)
        } else if let d = defaultPosition,
                  let p = WindowPosition.resolve(x: d.x, y: d.y, anchorX: d.anchorX, anchorY: d.anchorY, skinSize: size,
                                                 screens: screens) {
            frame = WindowGeometry.frame(topLeftX: p.x, y: p.y, size: size, primaryHeight: ph)
            isNew = true
        } else {
            let visible = NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            frame = WindowGeometry.cascadeFrame(index: app.controllers.count, size: size, visible: visible)
            isNew = true
        }
        frame = constrained(frame)
        // setFrame can synchronously publish facts and install a first layer frame on the main executor.
        // Its install callback must see the destination view's size, including while this placement is reentrant.
        view.frame = NSRect(origin: .zero, size: size)
        window.setFrame(frame, display: false)
        defaultPosition = nil
        if isNew { saveFrame(frame, force: true) }
        publishFacts()
    }

    /// Displays were added, removed or rearranged: re-derive the position from the saved one (so a skin returns to
    /// a monitor that comes back) and keep it on screen, without saving the adjusted position.
    func screensChanged() {
        guard !isStopped, isStarted else { return }
        if state.savePosition, state.x != nil, state.y != nil {
            placeWindow()
        } else {
            window.setFrame(constrained(window.frame), display: false)
        }
        publishFacts()
    }

    /// After a drag or !Move.
    func windowMoved() {
        var frame = window.frame
        if state.keepOnScreen {
            frame = keptOnScreen(frame)
            window.setFrameOrigin(frame.origin)
        }
        saveFrame(frame)
        publishFacts()
    }

    private func saveFrame(_ frame: CGRect, force: Bool = false) {
        let p = WindowGeometry.topLeft(of: frame, primaryHeight: primaryHeight)
        app.sessionPositions[config.lowercased()] = (p.x, p.y)
        // SavePosition: "changes to the window position will be saved". A new skin's first position is always
        // stored so it does not cascade somewhere else next time.
        guard state.savePosition || force else { return }
        app.state.update(config) {
            $0.file = file
            $0.x = p.x
            $0.y = p.y
        }
    }

    /// Snaps to screen edges and nearby skins (SnapEdges).
    func snapped(_ frame: NSRect) -> NSRect {
        let others = app.controllers.values.filter { $0 !== self && $0.isShown }.map(\.window.frame)
        return WindowGeometry.snapped(frame, screens: screens, others: others)
    }

    func moveTo(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let size = window.frame.size
        let frame = WindowGeometry.frame(topLeftX: min(max(x, -1e6), 1e6), y: min(max(y, -1e6), 1e6), size: size,
                                         primaryHeight: primaryHeight)
        window.setFrameOrigin(frame.origin)
        windowMoved()
    }

    /// Top-left of the window in skin (top-left origin) coordinates.
    var topLeftPosition: (x: Double, y: Double) { WindowGeometry.topLeft(of: window.frame, primaryHeight: primaryHeight) }

    func showContextMenu(with event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(app.skinMenu(for: self, includeCustomItems: true), with: event, for: view)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard !isStopped else { return }
        runtime.send(.focus(true))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isStopped else { return }
        runtime.send(.focus(false))
    }

    /// Covered or uncovered: the runtime draws no frames while the window cannot be seen, and one when it can again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        publishFacts()
    }

    /// Whoever moved the window (a drag, a screen change, AppKit): the runtime hears of it.
    func windowDidMove(_ notification: Notification) {
        publishFacts()
    }

    func windowDidResize(_ notification: Notification) {
        publishFacts()
    }

    /// Another backing scale or colour space (the window moved to another display): the frames follow.
    func windowDidChangeBackingProperties(_ notification: Notification) {
        publishFacts()
    }

    func windowDidChangeScreenProfile(_ notification: Notification) {
        publishFacts()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        publishFacts()
    }

    // MARK: Requests from the runtime

    /// Applies what the runtime asks of the main thread, in the order it asked.
    func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
        switch request {
        case .attachNativeStage(let stage):
            guard runtime === self.runtime else {
                runtime.completeNativeStage(stage, result: .failure(.cancelled))
                return
            }
            attachNativeStage(stage)
        case .nativeStageCompleted(let stage, let result):
            guard runtime === self.runtime, !isStopped, stage.provider === content else {
                runtime.completeNativeStage(stage, result: .failure(.cancelled))
                return
            }
            runtime.completeNativeStage(stage, result: result, facts: facts, size: view.bounds.size)
        case .nativeStageReleased, .nativeStageRejected:
            break // SkinRuntime handles cleanup/rejection before window delivery, including a released window.
        case .nativeStagePublicationFinished(let stage, let result):
            guard runtime === self.runtime, !isStopped, stage.provider === content else {
                runtime.rollbackNativePublication(stage, failure: .cancelled)
                return
            }
            runtime.finishNativePublication(stage, result: result, facts: facts, size: view.bounds.size)
        case .nativeStageRollback(let stage, let failure), .nativeStageCallbackFailed(let stage, let failure):
            runtime.rollbackNativePublication(stage, failure: failure)
        case .scenePatch(let patch):
            guard runtime === self.runtime else { _ = patch.content.reclaim(.invalidated); return }
            applyScenePatch(patch)
        case .layerHitMap(let map, let generation, let panel):
            guard runtime === self.runtime, !isStopped, panel == panelGeneration,
                  generation > lastLayerGeneration else { return }
            lastLayerGeneration = generation
            view.takeLayerHitMap(map)
        case .installLayerContent:
            guard runtime === self.runtime else { return }
            installLayerContent()
        case .loaded(let report):
            loaded(report)
        case .started(let report):
            started(report)
        case .failed(let error, let ticket):
            failed(error, ticket: ticket)
        case .closed(let ticket):
            closed(ticket: ticket)
        case .resize(let size):
            resize(to: size)
        case .glass(let regions):
            guard !isStopped else { return }
            glass.apply(regions, in: contentView, below: view)
        case .window(let change):
            applyWindowChange(change)
        case .lifecycle(let bang), .ui(let bang), .system(let bang):
            applyHostBang(bang)
        case .fadeWindow(let from, let to):
            fadeWindow(from: from, to: to)
        case .open(let plan):
            open(plan)
        case .forward(let bang, let config, let hops):
            forward(bang, toConfig: config, hops: hops)
        case .companion(let companion):
            companions.apply(companion)
        case .snapshotChanged(let changes):
            snapshotChanged(changes)
        }
    }

    /// Explicit experimental native qualification only. Default bitmap, every-frame drawing and user settings
    /// never call this entry. The successful result is a scoped observation, not E publication or a ready cache.
    func requestNativeStage(maximumCallbackBitmapBytes: Int, completion: @escaping (SkinNativeStageResult) -> Void) {
        precondition(Thread.isMainThread)
        guard !isStopped else { return completion(.failure(.cancelled)) }
        runtime.requestNativeStage(maximumCallbackBitmapBytes: maximumCallbackBitmapBytes, completion: completion)
    }

    /// An explicit same-generation Single publication. Default/ordinary C frames never call this method.
    func publishNativeSingle(maximumCallbackBitmapBytes: Int, completion: @escaping (SkinNativeStageResult) -> Void) {
        precondition(Thread.isMainThread)
        guard !isStopped, !isHiddenByBang else { return completion(.failure(.cancelled)) }
        runtime.publishNativeSingle(maximumCallbackBitmapBytes: maximumCallbackBitmapBytes, completion: completion)
    }

    func rollbackNativeSingle() {
        precondition(Thread.isMainThread)
        runtime.rollbackVisibleNativePublication(provider: content, failure: .cancelled)
    }

    private func attachNativeStage(_ stage: SkinNativeStage) {
        let current = facts
        guard !isStopped, !isHiddenByBang, applyingScenePatch == nil, stage.provider === content,
              stage.epoch.matches(current, size: view.bounds.size) else {
            runtime.completeNativeStage(stage, result: .failure(.staleDestination))
            return
        }
        // Main parks BEFORE the provider takes its lock. No C root, host values or presentation count changes.
        let attached = runtime.attachNativeStage(stage, facts: current, size: view.bounds.size)
        guard attached == true else {
            runtime.completeNativeStage(stage, result: .failure(attached == nil ? .attachmentTimedOut : .cancelled))
            return
        }
        // The transparent real-window attachment transaction has committed. Native display is the next physical
        // worker message, never main redraw or a hand-written CGContext standing in for a CA callback.
        runtime.nativeStageAttached(stage)
    }

    /// A tree-only claim never parks an executor or grants access to its Skin/cache metadata.
    private func applyScenePatch(_ patch: SkinScenePatch) {
        defer { runtime.send(.scenePatchFinished(patch)) }
        guard contentMode.usesLayers, !isStopped, patch.panelGeneration == panelGeneration,
              patch.generation > lastLayerGeneration, content.acceptsLayerFrames else {
            _ = patch.content.reclaim(.invalidated)
            return
        }
        if patch.content.state == .reclaimedBySkin {
            guard patch.content.reclamation == .timeout else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glass.apply(patch.glass, in: contentView, below: view)
            resize(to: patch.size, updateTips: false)
            CATransaction.commit()
            lastLayerGeneration = patch.generation
            patch.acknowledgeHost(.controls)
            Log.write("Layer frame reclaimed after its main deadline; glass/window caught up without touching content", source: config)
            return
        }
        // A first attachment must still have the current actual profile/scale. Later coherent old frames may
        // finish while new facts wait on the owner, whose next frame is then a full destination redraw.
        if content.installedLayerRoot == nil {
            guard let space = facts.colorSpace, CFEqual(space, patch.content.frame.colorSpace),
                  facts.scale == patch.content.frame.scale else {
                _ = patch.content.reclaim(.invalidated)
                publishFacts(force: true)
                return
            }
        }
        guard patch.content.claimOnMain() else { return }
        applyingScenePatch = patch
        #if DEBUG
        willApplyScenePatch?(patch)
        #endif
        var installed = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !isStopped, patch.panelGeneration == panelGeneration, content.acceptsLayerFrames {
            glass.apply(patch.glass, in: contentView, below: view)
            resize(to: patch.size, updateTips: false)
            if !isStopped, content.acceptsLayerFrames, content.applyScenePatch(patch.content) {
                lastLayerGeneration = patch.generation
                view.takeLayerHitMap(patch.hitMap)
                installed = true
            }
        }
        CATransaction.commit()
        if installed { patch.acknowledgeHost(.complete) }
        patch.content.finishOnMain()
        applyingScenePatch = nil
        if installed { layerContentInstalled() }
        publishFacts()
    }

    /// A request is just readiness, not a panel/facts acknowledgment. Validate against the current actual window
    /// after parking its executor. A failed park retains the old contents and retries without extending the lease.
    private func installLayerContent() {
        guard contentMode.usesLayers, !isStopped else { return }
        publishFacts()
        let result = runtime.installLayerContent(for: facts, size: view.bounds.size)
        switch result {
        case .installed:
            layerContentInstalled()
        case nil:
            guard !layerInstallRetryQueued else { return }
            layerInstallRetryQueued = true
            // Queue behind the owner's current work instead of repeatedly parking a still-busy worker from main.
            runtime.whenCaughtUp { [weak self] in
                guard let self else { return }
                self.layerInstallRetryQueued = false
                self.installLayerContent()
            }
        case .staleDestination:
            // Current facts supersede the finished root. Preparation/drawing stay on the owner, including a skin
            // with Update=-1; its next successful frame requests a new installation rather than certifying this one.
            publishFacts(force: true)
            runtime.send(.firstFrame)
        case .declined, .notReady:
            break
        }
    }

    private func layerContentInstalled() {
        if var report = layerStartPending {
            // The scene may have recovered from a failed initial size. The installed frame matched the
            // CURRENT view in the lease above; do not restore the load report's now-obsolete dimensions.
            report.size = view.bounds.size
            started(report)
        }
        if let pending = deferredLayerOrderIn, !isHiddenByBang {
            deferredLayerOrderIn = nil
            if orderIn(alpha: pending.alpha), pending.fade > 0 {
                animateAlpha(to: targetAlpha, duration: pending.fade)
            }
            publishFacts()
        }
        runtime.beginNativeFrames()
    }

    /// The skin published a snapshot in which something changed that the main thread acts on.
    private func snapshotChanged(_ changes: SkinSnapshotChanges) {
        if changes.contains(.toolTips) { view.updateToolTips() }
        // Also once the skin closed: it no longer wants anything.
        if changes.contains(.outsidePointerNeeds) { app.outsidePointer.needsChanged() }
        if !changes.isDisjoint(with: [.issues, .metadata]) { app.skinDetailsChanged() }
    }

    /// The skin's size changed: the window follows (the top-left corner stays). The frames go to the content layer
    /// from the skin's executor, which skips them while the window cannot be seen (energy: a skin hidden behind other
    /// windows, on a locked screen or ordered out is not drawn until it can be seen again; its measures keep updating).
    private func resize(to size: CGSize, updateTips: Bool = true) {
        guard !isStopped else { return }
        let before = factsSequence
        if window.frame.size != size {
            // Keep the top-left corner fixed.
            let top = window.frame.maxY
            var frame = NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height)
            if state.keepOnScreen && window.isVisible { frame = keptOnScreen(frame) }
            window.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: size)
        }
        if updateTips { view.updateToolTips() }
        // Different requested sizes can round to the same frame. Acknowledge that actual frame even when AppKit
        // made no change; a delegate notification that already published it needs no second acknowledgement.
        if factsSequence == before { publishFacts(force: true) }
    }

    /// A bang the engine performed, or `*`, for other skins, sent with `hops` (the sender's).
    private func forward(_ bang: Bang, toConfig config: String, hops: Int) {
        // `*`: the engine has already performed the bang on the sending skin; every other active skin follows.
        let everyone = SkinLibrary.normalizedConfigName(config) == "*"
        let sender = self.config
        if !everyone && app.isLoadPending(config) {
            // `[!ActivateConfig X][!SetVariable V 1 X]`: X is loaded on the next run loop turn; the bang follows it.
            app.later { app in
                let now = app.controllers(forConfigArgument: config, current: nil).filter { !$0.isStopped }
                if now.isEmpty {
                    Log.write("!\(bang.name): config \"\(config)\" is not active", level: .warning, source: sender)
                }
                // On a later turn: the chain it came from has ended.
                for target in now { target.runtime.send(.bang(bang, from: sender, hops: 0)) }
            }
            return
        }
        let targets = app.controllers(forConfigArgument: config, current: self).filter { !everyone || $0 !== self }
        if targets.isEmpty && !everyone {
            Log.write("!\(bang.name): config \"\(config)\" is not active", level: .warning, source: sender)
        }
        // Skins can send bangs to each other from actions those bangs trigger (A's OnUpdateAction does
        // [!Update "B"], B's does [!Update "A"]): each skin's own guards count only its own nesting, so the chain
        // across skins is cut here.
        guard hops < SkinRuntime.maxHops else {
            Log.write("!\(bang.name) to \"\(config)\" ignored: skins keep triggering each other", level: .warning,
                      source: sender)
            return
        }
        for target in targets where !target.isStopped { target.runtime.send(.bang(bang, from: sender, hops: hops + 1)) }
    }

    // MARK: The window model

    /// One of the skin's own window changes, made in its window model already: the same happens to `AppState` and the
    /// panel, as the window bangs always did here. The windows are stacked again and the app hears of the settings once
    /// per batch (`AppController.batchingWindowChanges`). A move that comes while a press may drag the window waits for
    /// the release (`endDragPress`).
    private func applyWindowChange(_ change: SkinWindowChange) {
        guard !isStopped else { return }
        if case .move = change.operation, isDragPressActive {
            heldMove = change
            return
        }
        appliedModelSequence = max(appliedModelSequence, change.sequence)
        switch change.operation {
        case .move(let frame):
            let p = WindowGeometry.topLeft(of: frame, primaryHeight: primaryHeight)
            moveTo(x: p.x, y: p.y)
        case .zPosition(let value):
            app.state.update(config) { $0.alwaysOnTop = value }
            applyWindowSettings()
            if isShown && app.presentsWindows { window.orderFrontRegardless() }
            // Skins sharing the new Position are stacked by load order again (as the menu and the Manage window do).
            app.windowChangesNeed(restack: true, settingsChanged: true)
        case .alpha(let value):
            clearFadedAlpha()
            app.state.update(config) { $0.alphaValue = value }
            applyWindowSettings()
            app.windowChangesNeed(settingsChanged: true)
        case .flag(let flag, let value):
            app.state.update(config) { $0[keyPath: flag.state] = value }
            applyWindowSettings()
            app.windowChangesNeed(settingsChanged: true)
            if flag == .keepOnScreen { windowMoved() }
        case .fadeDuration(let milliseconds):
            app.state.update(config) { $0.fadeDuration = milliseconds }
            applyWindowSettings()
            app.windowChangesNeed(settingsChanged: true)
        case .hidden(let hidden, let fade):
            setHidden(hidden, fade: fade)
        }
        publishFacts()
    }

    /// A press on the skin that may drag its window (Draggable, no LeftMouseDownAction there…) began (`SkinView`).
    func beginDragPress() {
        isDragPressActive = true
    }

    /// That press ended; `moved`: it dragged the window. The window's place is saved after a drag; a move the skin made
    /// meanwhile is dropped (the drag wins) or, when the press did not drag, made now. The runtime hears where the window
    /// is either way.
    func endDragPress(moved: Bool) {
        guard isDragPressActive else {
            if moved { windowMoved() }
            return
        }
        isDragPressActive = false
        let held = heldMove
        heldMove = nil
        if let held { appliedModelSequence = max(appliedModelSequence, held.sequence) }
        if moved {
            windowMoved()
        } else if let held, case .move(let frame) = held.operation, !isStopped {
            let p = WindowGeometry.topLeft(of: frame, primaryHeight: primaryHeight)
            moveTo(x: p.x, y: p.y)
        }
        publishFacts()
    }

    /// Self-tests: whether the window counts as shown and uncovered in the facts, although the headless tests never
    /// show it (nil: as it is). The frames follow the facts.
    var visibilityForTesting: Bool? {
        didSet { publishFacts() }
    }

    /// The window as this controller last told its runtime (`publishFacts`): its copy of the runtime's window model —
    /// the frame, screen and display, and the window settings. Kept once the skin stopped. Main thread.
    var publishedFacts: SkinWindowFacts? { sentFacts }

    /// What the window is now, for the runtime.
    var facts: SkinWindowFacts {
        SkinWindowFacts(frame: window.frame, screen: window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) },
                        display: window.screen.flatMap(DesktopInputs.displayID(of:)),
                        isVisible: visibilityForTesting ?? window.occlusionState.contains(.visible),
                        isOrderedIn: visibilityForTesting ?? window.isVisible,
                        scale: window.backingScaleFactor, colorSpace: window.colorSpace?.cgColorSpace,
                        appearance: view.effectiveAppearance.name.rawValue, takesPointer: takesPointer,
                        settings: SkinWindowSettings(state, hidden: isHiddenByBang,
                                                     fadedAlpha: fadedAlpha.map { SkinFadedAlpha(value: $0.value,
                                                                                                 base: $0.base) }),
                        // While a move of the skin's waits, its model keeps that move and what came after it.
                        modelSequence: heldMove.map { min(appliedModelSequence, $0.sequence - 1) } ?? appliedModelSequence,
                        sequence: factsSequence, panelGeneration: panelGeneration)
    }

    /// Tells the runtime what the window is (`SkinWindowFacts`) when that changed since it was last told: after every
    /// change the main thread makes or applies. With the main executor the model follows at once. The window's
    /// companions follow the window too. Until the skin started, only the first facts go (`holdsFacts`).
    func publishFacts(force: Bool = false) {
        guard owningApp != nil else { return }
        companions?.windowChanged()
        if holdsFacts && sentFacts != nil { return }
        var now = facts
        runtime.rollbackVisibleNativePublication(provider: content, failure: .staleDestination,
                                                   facts: now, size: view.bounds.size)
        if !force, let sent = sentFacts, sent.hasSameValues(as: now) { return }
        factsSequence += 1
        now.sequence = factsSequence
        sentFacts = now
        runtime.send(.windowFacts(now))
        if contentMode.usesLayers, layerStartPending != nil || deferredLayerOrderIn != nil {
            runtime.send(.firstFrame)
        }
    }

    /// Self-tests: what skins open goes here instead of to the workspace (nil: it opens). Main thread.
    static var opensForTesting: ((SkinExecutePlan) -> Void)?

    /// `["target" arguments…]`: a web page, a file or an app opens.
    private func open(_ plan: SkinExecutePlan) {
        if let hook = SkinWindowController.opensForTesting { return hook(plan) }
        switch plan {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .openFiles(let files, let app):
            NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .nothing, .unsupported:
            break
        }
    }

    // MARK: SkinRuntimeWindow

    /// What the runtime answers the engine for a bang left to the host (false: not supported on macOS), after asking
    /// the main thread to do it; for the self-tests.
    func handleHostBang(_ bang: Bang) -> Bool {
        runtime.skin(runtime.skin, handle: bang)
    }

    /// The window gets the mouse while it is on screen and does not let the mouse through (ClickThrough, OnHover=Hide
    /// while hovered). Asked when a move from elsewhere is delivered: !Hide orders the window out, and ClickThrough
    /// set during a press drops the pointer's leave, without SkinView ever reporting that the pointer left.
    var takesPointer: Bool {
        !isStopped && window.isVisible && !window.ignoresMouseEvents
    }

    // MARK: SkinCompanionHost

    var skinWindow: NSWindow { window }
    var skinContentView: NSView { contentView }
    var showsWindows: Bool { app.presentsWindows }

    /// What the runtime answers the engine (`SkinHost.skinWindowTakesPointer`); for the self-tests.
    func skinWindowTakesPointer(_ skin: Skin) -> Bool {
        runtime.skinWindowTakesPointer(skin)
    }

    /// A point in screen coordinates (AppKit's: bottom-left origin at the primary screen's corner, in points on every
    /// screen whatever its backing scale) in skin coordinates, as `SkinView` converts its own events: the view's
    /// top-left origin, and its scale if it had one.
    func skinPoint(fromScreen point: NSPoint) -> (x: Double, y: Double) {
        let p = view.convert(window.convertPoint(fromScreen: point), from: nil)
        return (Double(p.x), Double(p.y))
    }

    /// What `[target arguments…]` does (`SkinRuntime.executePlan`).
    typealias ExecutePlan = SkinExecutePlan

    static func executePlan(_ skin: Skin, target: String, arguments: [String]) -> ExecutePlan {
        SkinRuntime.executePlan(skin, target: target, arguments: arguments)
    }

    /// The environment of the live window (main thread): the Studio's instance of the widget reads its desktop copy's.
    var environment: SkinEnvironment {
        let s = state
        return EnvironmentStore.shared.environment(windowFrame: window.frame, zPosition: s.alwaysOnTop,
                                                   autoSelectScreen: s.autoSelectScreen)
    }

    /// While a move of the skin's waits for a drag to end, the model and the window differ on purpose.
    func liveEnvironment(for skin: Skin) -> SkinEnvironment? {
        heldMove == nil ? environment : nil
    }

    var liveTakesPointer: Bool? { takesPointer }

    func batchingWindowChanges(_ body: () -> Void) {
        app.batchingWindowChanges(body)
    }
}

/// The window half's old name, kept while the Studio and the self-tests still use it (until phase 5 of the threading
/// design).
typealias SkinController = SkinWindowController

/// When skin tooltips (ToolTipText) appear. Windows shows a tooltip after the double-click time, 0.5 s by default;
/// AppKit waits noticeably longer, more so while another app is in front, which is nearly always the case for skin
/// windows. `NSInitialToolTipDelay` (milliseconds) is AppKit's app-wide setting; it is registered as a default, so a
/// value the user set for all apps (`defaults write -g NSInitialToolTipDelay …`) still wins. Called from main.swift
/// before any tooltip is created.
enum SkinTooltips {
    static let initialDelayMilliseconds = 500

    static func registerDelay(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["NSInitialToolTipDelay": initialDelayMilliseconds])
    }
}
