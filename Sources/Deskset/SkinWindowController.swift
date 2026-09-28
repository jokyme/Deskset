import AppKit
import DesksetCore

/// The main-thread half of a running skin (docs/skin-threading.md §5.4): its window (`SkinPanel`, `SkinView`, the
/// glass), fades, hover polling, placement, dragging, snapping and keeping on screen, and the skin's `AppState`. The
/// other half, `SkinRuntime`, owns the `Skin`; this one reaches it only through the runtime: messages (`runtime.send`),
/// the skin's snapshot (`runtime.snapshot`), or exclusive access (`runtime.exclusive`) where it still reads the live
/// skin. It applies what the runtime asks of the main thread (`apply`), and tells the runtime what it did with the
/// window after every change (`publishFacts`): the runtime's window model (`SkinWindowModel`) follows it.
final class SkinWindowController: NSObject, NSWindowDelegate, SkinRuntimeWindow {
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
    /// The glass behind the skin's drawing (`MacGlass`), in `contentView`.
    let glass = SkinGlassViews()
    private var hoverTimer: Timer?
    unowned let app: AppController

    /// Hidden with !Hide / !HideFade (the skin keeps updating).
    private(set) var isHiddenByBang = false
    /// The mouse is over the skin window (tracked only when OnHover is set).
    private(set) var isHovering = false
    private(set) var isStopped = false
    /// The skin is being closed (`stop`): OnCloseAction is running.
    private var isClosing = false
    /// The skin's updates are paused (as the runtime's: `pauseUpdates` / `resumeUpdates`): no hover tracking meanwhile.
    private var updatesPaused = false
    /// Updates stopped by `pauseUpdates()` (sleep, locked screens) until `resumeUpdates`.
    var areUpdatesPaused: Bool { updatesPaused }
    /// Lua `SKIN:FadeWindow`: the alpha (0…255) the window was faded to, and the saved AlphaValue it stands in for.
    /// It is not saved: a refresh, or any change of the saved AlphaValue (!SetTransparency, the menu, the Manage
    /// window), ends it.
    private(set) var fadedAlpha: (value: Int, base: Int)?
    /// A redraw was requested while the window was fully covered; done when it becomes visible again.
    private var displayPending = false
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

    /// `executor`: where the skin runs (the main executor, unless a self-test puts it on a thread of its own).
    init(config: String, file: String, app: AppController, executor: SkinExecutor = MainSkinExecutor.shared) throws {
        self.config = config
        self.file = file
        self.app = app
        view = SkinView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        contentView = SkinContentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        contentView.addSubview(view)
        window = SkinWindowController.makePanel()
        runtime = SkinRuntime(config: config, file: file, skinsDirectory: app.skinsDirectory, executor: executor)
        super.init()
        runtime.window = self
        runtime.directoryStore = app.skinDirectory
        // The window model starts from the window as it is: loading may read #CURRENTCONFIGX# already.
        publishFacts()

        let loaded: SkinRuntime.LoadResult
        if executor.isCurrent {
            loaded = try runtime.load()
        } else {
            // A skin on a thread of its own loads there, with the thread parked meanwhile.
            let runtime = self.runtime
            guard let result = executor.exclusive(timeout: 60, { Result { try runtime.load() } }) else {
                throw SkinWindowController.LoadTimeout()
            }
            loaded = try result.get()
        }
        // Wired up only once the skin loaded (NSWindow does not retain its delegate).
        window.contentView = contentView
        window.delegate = self
        view.controller = self
        // Skins measured before these fonts existed drew their text with a fallback font. (Fonts also announces the
        // change, later; `fontsChanged` does not pass the same fonts on twice.)
        if loaded.registeredFonts { app.fontsChanged() }
        for issue in loaded.issues { Log.write(issue, level: .warning, source: config) }
    }

    /// The skin's thread did not let the main thread load it in time.
    struct LoadTimeout: Error {}

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

    /// First update, placement, then shows the window (fading in over FadeDuration when `fadeIn`). With
    /// StartHidden the window stays hidden until !Show.
    func start(fadeIn: Bool) {
        if state.startHidden { isHiddenByBang = true }
        // Also publishes the settings the first load seeded (`seedWindowSettings`): #CURRENTCONFIGZPOS# of the first
        // update.
        applyWindowSettings()
        // The first update, then the update clock (which never fires inline).
        runtime.send(.start)
        placeWindow()
        view.needsDisplay = true
        if app.presentsWindows && !isHiddenByBang {
            let target = targetAlpha
            let duration = fadeIn ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
            window.alphaValue = duration > 0 ? 0 : target
            window.orderFrontRegardless()
            if duration > 0 { animateAlpha(to: target, duration: duration) }
        }
        publishFacts()
    }

    /// Stops updating, runs OnCloseAction and closes the window (fading out when `fadeOut`).
    func stop(fadeOut: Bool = false) {
        guard !isStopped, !isClosing else { return }
        hoverTimer?.invalidate()
        hoverTimer = nil
        // OnCloseAction runs while the skin can still handle bangs (it cannot reload or unload itself any more).
        isClosing = true
        runtime.send(.close(fadeOut: fadeOut))
        isStopped = true
        endDragPress(moved: false)
        publishFacts()
        let window = self.window
        window.delegate = nil
        fadeGeneration += 1
        let duration = fadeOut && window.isVisible && app.presentsWindows
            ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0
        guard duration > 0 else {
            window.orderOut(nil)
            window.close()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = 0
        }, completionHandler: {
            // Keeps the controller (and so the drawn skin) alive until the fade has finished.
            withExtendedLifetime(self) {
                window.orderOut(nil)
                window.close()
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

    private func replacePanel() {
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
        view.needsDisplay = true
    }

    private func applyAlpha(animated: Bool) {
        animateAlpha(to: targetAlpha, duration: animated ? SkinVisibility.fadeSeconds(state.fadeDuration) : 0)
    }

    private func animateAlpha(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeGeneration += 1
        let generation = fadeGeneration
        guard duration > 0, app.presentsWindows else {
            window.alphaValue = target
            completion?()
            return
        }
        let window = self.window
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
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
                window.alphaValue = duration > 0 ? 0 : targetAlpha
                window.orderFrontRegardless()
                view.needsDisplay = true
            }
            applyMouseHandling()
            animateAlpha(to: targetAlpha, duration: duration)
        }
    }

    // MARK: OnHover

    private func updateHoverTracking() {
        let wanted = state.onHover != 0 && !isHiddenByBang && !isStopped && !updatesPaused
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
    /// time (see `seedWindowSettings()`), used by the first placement.
    private var defaultPosition: (x: String, y: String, anchorX: String, anchorY: String)?

    /// First load of a config (no saved settings): the skin's `Default…` options in `[Rainmeter]` become its window
    /// settings (manual: skin sections of Rainmeter.ini, and "Default" values a skin may set for them).
    func seedWindowSettings() {
        let defaults = runtime.exclusive { $0.settings.windowDefaults } ?? [:]
        guard !defaults.isEmpty else { return }
        app.state.update(config) { $0 = SkinWindowController.seededState($0, defaults: defaults) }
        func value(_ key: String) -> String? { defaults[key].flatMap { $0.isEmpty ? nil : $0 } }
        if value("WindowX") != nil || value("WindowY") != nil {
            defaultPosition = (value("WindowX") ?? "0", value("WindowY") ?? "0", value("AnchorX") ?? "0",
                               value("AnchorY") ?? "0")
        }
    }

    /// `state` with the values of `defaults` (keys as in `SkinSettings.windowDefaults`) that can be read; the
    /// others keep their current value.
    static func seededState(_ state: SkinState, defaults: [String: String]) -> SkinState {
        var s = state
        func number(_ key: String) -> Double? {
            guard let raw = defaults[key], let v = OptionValue.number(raw), v.isFinite else { return nil }
            return v
        }
        func flag(_ key: String) -> Bool? { number(key).map { $0 != 0 } }
        func int(_ key: String, _ range: ClosedRange<Double>) -> Int? {
            number(key).map { Int(min(max($0.rounded(.towardZero), range.lowerBound), range.upperBound)) }
        }
        if let v = int("AlwaysOnTop", -2...2) { s.alwaysOnTop = v }
        if let v = flag("Draggable") { s.draggable = v }
        if let v = flag("SnapEdges") { s.snapEdges = v }
        if let v = flag("ClickThrough") { s.clickThrough = v }
        if let v = flag("KeepOnScreen") { s.keepOnScreen = v }
        if let v = flag("SavePosition") { s.savePosition = v }
        if let v = flag("StartHidden") { s.startHidden = v }
        if let v = flag("AutoSelectScreen") { s.autoSelectScreen = v }
        if let v = int("AlphaValue", 0...255) { s.alphaValue = v }
        if let v = int("OnHover", 0...3) { s.onHover = v }
        if let v = int("FadeDuration", 0...Double(SkinState.maxFadeDuration)) { s.fadeDuration = v }
        return s
    }

    /// Positions the window from saved state (top-left coordinates), the position it had earlier in this session
    /// (SavePosition=0), the skin's DefaultWindowX / DefaultWindowY on its first load, or cascades a new skin.
    func placeWindow() {
        let size = skinSize
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
        window.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: size)
        defaultPosition = nil
        if isNew { saveFrame(frame, force: true) }
        publishFacts()
    }

    /// Displays were added, removed or rearranged: re-derive the position from the saved one (so a skin returns to
    /// a monitor that comes back) and keep it on screen, without saving the adjusted position.
    func screensChanged() {
        guard !isStopped else { return }
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

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if displayPending, window.occlusionState.contains(.visible) {
            displayPending = false
            view.needsDisplay = true
        }
        publishFacts()
    }

    /// Whoever moved the window (a drag, a screen change, AppKit): the runtime hears of it.
    func windowDidMove(_ notification: Notification) {
        publishFacts()
    }

    func windowDidResize(_ notification: Notification) {
        publishFacts()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        publishFacts()
    }

    // MARK: Requests from the runtime

    /// Applies what the runtime asks of the main thread, in the order it asked.
    func apply(_ request: SkinRequest, from runtime: SkinRuntime) {
        switch request {
        case .display(let size):
            display(size: size)
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
            switch companion {}
        case .snapshotChanged(let changes):
            snapshotChanged(changes)
        }
    }

    /// The skin published a snapshot in which something changed that the main thread acts on.
    private func snapshotChanged(_ changes: SkinSnapshotChanges) {
        if changes.contains(.toolTips) { view.updateToolTips() }
        // Also once the skin closed: it no longer wants anything.
        if changes.contains(.outsidePointerNeeds) { app.outsidePointer.needsChanged() }
        if !changes.isDisjoint(with: [.issues, .metadata]) { app.skinDetailsChanged() }
    }

    /// The skin redrew: the window follows its size (the top-left corner stays) and shows the new picture.
    private func display(size: CGSize) {
        guard !isStopped else { return }
        if window.frame.size != size {
            // Keep the top-left corner fixed.
            let top = window.frame.maxY
            var frame = NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height)
            if state.keepOnScreen && window.isVisible { frame = keptOnScreen(frame) }
            window.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: size)
        }
        // Energy: a skin hidden behind other windows, on a locked screen or faded out is not redrawn until it can be
        // seen again (measures keep updating).
        if !app.presentsWindows || window.occlusionState.contains(.visible) {
            view.needsDisplay = true
        } else {
            displayPending = true
        }
        view.updateToolTips()
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

    /// What the window is now, for the runtime.
    var facts: SkinWindowFacts {
        SkinWindowFacts(frame: window.frame, screen: window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) },
                        isVisible: window.occlusionState.contains(.visible), isOrderedIn: window.isVisible,
                        scale: window.backingScaleFactor, colorSpace: window.colorSpace?.cgColorSpace,
                        appearance: view.effectiveAppearance.name.rawValue, takesPointer: takesPointer,
                        settings: SkinWindowSettings(state, hidden: isHiddenByBang,
                                                     fadedAlpha: fadedAlpha.map { SkinFadedAlpha(value: $0.value,
                                                                                                 base: $0.base) }),
                        // While a move of the skin's waits, its model keeps that move and what came after it.
                        modelSequence: heldMove.map { min(appliedModelSequence, $0.sequence - 1) } ?? appliedModelSequence,
                        sequence: factsSequence)
    }

    /// Tells the runtime what the window is (`SkinWindowFacts`) when that changed since it was last told: after every
    /// change the main thread makes or applies. With the main executor the model follows at once.
    func publishFacts() {
        var now = facts
        if let sent = sentFacts, sent.hasSameValues(as: now) { return }
        factsSequence += 1
        now.sequence = factsSequence
        sentFacts = now
        runtime.send(.windowFacts(now))
    }

    /// `["target" arguments…]`: a web page, a file or an app opens.
    private func open(_ plan: SkinExecutePlan) {
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

    var screen: NSScreen? { window.screen }

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
