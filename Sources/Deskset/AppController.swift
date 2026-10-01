import AppKit
import DesksetCore

/// App delegate: menu bar item, skin lifecycle, state, Manage window, skin installation, system events.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state: AppState
    let skinsDirectory: URL
    let layoutsDirectory: URL
    let backupsDirectory: URL
    /// The bundled default skins (`DefaultSkins`, see `DefaultSkins`); nil when the app has none.
    let defaultSkinsSource: URL?
    /// `#SETTINGSPATH#`: where `Stationery.inc` is kept.
    let settingsDirectory: URL
    /// False for headless use (`--self-test`, `--snapshot-ui`): skin windows are created but never shown.
    let presentsWindows: Bool
    /// The skin editor's window is built in steps, a few per turn of the run loop, so the skins go on animating while
    /// it opens (`InspectorWindowController.queueOpening`). Headless it is built at once, unless a self-test asks.
    var opensEditorInSteps: Bool
    /// The widget on the desktop follows the Studio a moment later (`EditingSession`): a step's reload waits for the
    /// next turn of the run loop, after the canvas drew the step, and a gesture's previews reach it at most about 20
    /// times a second. Headless it follows at once, unless a self-test asks.
    var defersDesktopUpdates: Bool

    /// Running skins keyed by lowercased config name. The skins' directory follows every change.
    private(set) var controllers: [String: SkinWindowController] = [:] {
        didSet { if directoryHeld == 0 { publishDirectory() } }
    }
    /// While positive, a change of `controllers` is not published yet (`activate` publishes once, when it is done).
    private var directoryHeld = 0
    /// What the skins know of each other: the running ones and the configs a bang is loading (`SkinDirectory`).
    let skinDirectory = SkinDirectoryStore()
    /// Where the desktop skins run (the `SkinThreading` default, read once at launch; `.main` for the self-tests and
    /// every headless mode).
    let threading: SkinThreading
    /// Production uses the shared live monitor; bounded stress fixtures can supply their own diagnostic clock.
    let workWatchdog: SkinWorkWatchdog
    /// The engine thread every desktop skin shares with `SkinThreading=engine` (docs/skin-threading.md §15, phase 2):
    /// made with the first skin it runs. nil with `.main`, and before then.
    private(set) var engineThread: SkinThreadExecutor?
    /// The bounded workers used by the pool mode, created with its first skin.
    private(set) var skinThreadPool: SkinThreadPool?
    /// Where a config's skin runs: the engine thread, a stable pool worker or the main executor. Self-tests put
    /// some skins on threads of their own. The Studio's own instance of a widget, the Manage window's dry runs and
    /// thumbnails are not desktop skins: they always run on the main executor (§8.5, §8.7).
    lazy var skinExecutor: (String) -> SkinExecutor = { [unowned self] config in
        switch self.threading {
        case .main: return MainSkinExecutor.shared
        case .engine: return self.sharedEngineThread()
        case .pool:
            if self.skinThreadPool == nil { self.skinThreadPool = SkinThreadPool() }
            return self.skinThreadPool!.executor(for: SkinLibrary.normalizedConfigName(config).lowercased())
        }
    }
    /// Last position of each config in this session (used on refresh when SavePosition is off).
    var sessionPositions: [String: (Double, Double)] = [:]
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var pendingOpenURLs: [URL] = []
    private var launched = false
    private var cachedLibrary: [SkinConfig]?
    private var lastMissRescan: TimeInterval = -.infinity
    private var manageWindow: ManageWindowController?
    /// The skin inspector (one at a time).
    private(set) var inspector: InspectorWindowController?
    /// The editing sessions of the widgets the Studio has edited, by lowercased config: a widget's undo stack belongs to
    /// the app, not to the Studio window, and lasts until the app quits.
    private(set) var studioSessions: [String: EditingSession] = [:]
    /// Text files the built-in code editor has open outside the skin editor (`showCodeFile`).
    private(set) var codeFileWindows: [CodeFileWindowController] = []
    /// The window `bringToFront` last brought up (also headless, for self-tests).
    weak var lastBroughtToFront: NSWindow?
    private(set) lazy var installer = SkinInstallFlow(app: self)
    /// Watches the mouse outside the skin windows while a skin asks for it (Plugin=Slider sees clicks anywhere).
    private(set) lazy var outsidePointer = OutsidePointerMonitor(app: self)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The fonts generation the running skins were last laid out again for (`fontsChanged`). Fonts announces every
    /// change a turn later (`Fonts.didChangeNotification`); a change a caller already passed on is not passed on twice.
    private var fontsGenerationSeen = Fonts.generation
    /// The appearance the running skins last saw (`appearanceChanged`); nil until the app observes it.
    private var appearanceSeen: SkinAppearance?
    private var appearanceObservation: NSKeyValueObservation?
    /// Watches the preference keys behind the clock, week and temperature settings (`regionalSettingsChanged`).
    private var regionalDefaults: RegionalDefaultsObserver?
    private var regionalRecheck: DispatchWorkItem?

    private var systemAsleep = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var updatesPaused: Bool { systemAsleep || screensAsleep || sessionInactive }

    /// The config the Manage window shows on a first launch (the first one the first-run layout loaded).
    private(set) var firstRunSelection = DefaultSkins.firstClock.config

    init(state: AppState? = nil, skinsDirectory: URL = Paths.skins, layoutsDirectory: URL = Paths.layouts,
         backupsDirectory: URL = Paths.backups, defaultSkinsSource: URL? = Paths.defaultSkins,
         settingsDirectory: URL = Paths.appSupport, presentsWindows: Bool = true, threading: SkinThreading = .main,
         workWatchdog: SkinWorkWatchdog = .shared) {
        self.threading = threading
        self.workWatchdog = workWatchdog
        self.state = state ?? AppState()
        self.skinsDirectory = skinsDirectory
        self.layoutsDirectory = layoutsDirectory
        self.backupsDirectory = backupsDirectory
        self.defaultSkinsSource = defaultSkinsSource
        self.settingsDirectory = settingsDirectory
        self.presentsWindows = presentsWindows
        opensEditorInSteps = presentsWindows
        defersDesktopUpdates = presentsWindows
        super.init()
    }

    /// The engine thread, made the first time a skin needs it. Main thread.
    private func sharedEngineThread() -> SkinThreadExecutor {
        if let engineThread { return engineThread }
        let thread = SkinThreadExecutor(name: "Deskset skin engine", qualityOfService: .userInitiated)
        engineThread = thread
        return thread
    }

    /// Ends the skin threads once the work queued on them has run (the skins must have closed: self-tests, after
    /// `stopAllForTermination`). A later skin gets new workers.
    func endEngineThread() {
        engineThread?.stop()
        engineThread = nil
        skinThreadPool?.stop()
        skinThreadPool = nil
    }

    /// Said in the log at launch about the `SkinThreading` default (an unknown value; the main thread).
    var threadingNote: String?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }
        Paths.ensureDirectories()
        Log.rotateIfNeeded()
        Log.write("Deskset \(DesksetCore.version) starting on macOS "
                  + ProcessInfo.processInfo.operatingSystemVersionString
                  + "; legacy ANSI skins use code page \(TextDecoding.ansiCodePage)")
        if let threadingNote {
            Log.write(threadingNote, level: .warning)
        } else if threading == .engine {
            Log.write("Desktop skins run on the engine thread")
        } else if threading == .pool {
            Log.write("Desktop skins share \(SkinThreadPool.defaultWorkerCount) skin worker threads")
        }
        // `defaults write app.deskset.Deskset MainThreadStallLog -int 50`: main-thread stalls go to the log.
        MainThreadStallMonitor.shared.configure(from: .standard)
        // `defaults write app.deskset.Deskset FrameTimingLog -int 10`: how evenly each skin's frames come, in the log.
        FrameTimingLog.configure(from: .standard)
        if !Paths.isAppBundle { NSApp.applicationIconImage = AppIcon.image(size: 512) }
        NSApp.mainMenu = MainMenu.make(app: self)
        CodeEditorRouter.install(app: self)
        WebParserAccess.install(settingsFolder: Paths.appSupport)
        // Weather skins may reach MET Norway from here on (never in the command-line modes or the self-tests).
        WeatherWiring.install()
        let firstRun = state.data.skins.isEmpty
        installDefaultSkinsIfNeeded()
        ensureStationeryFile()
        setUpStatusItem()
        observeSystem()
        observeFonts()
        // What SysColor and Chameleon ask AppKit, and the screens, paths and appearance every skin reads, published for
        // skins that update on threads of their own.
        DesktopInputs.publishAll()
        EnvironmentStore.shared.publish()
        observeAppearance()
        let opensFiles = !pendingOpenURLs.isEmpty
        loadActiveSkins { [weak self] in
            // First launch: show where things are (the menu bar icon can be hidden by macOS), beside the first widgets
            // rather than over them, once they are placed.
            guard let self, firstRun, !opensFiles else { return }
            let manage = self.manageWindow ?? ManageWindowController(app: self)
            self.manageWindow = manage
            manage.placeBeside(self.controllers.values.map { $0.window.frame })
            self.showManageWindow(selecting: self.firstRunSelection, file: nil)
        }
        launched = true
        if opensFiles {
            installer.open(CodeEditorRouter.routeOpenedFiles(pendingOpenURLs, app: self))
            pendingOpenURLs = []
        }
    }

    /// Set when this launch handed over to an instance that was already running (see `handOffToRunningInstance`).
    private var isDuplicateInstance = false

    /// Another copy of Deskset (same bundle identifier: say one in Downloads and one in Applications, or a build next
    /// to the installed app) is already running. Two instances would draw every skin twice and overwrite each
    /// other's state.json, so the running one is asked to show its Manage window (or to install the packages, ZIP
    /// archives or folders this launch was opened with) and this one quits. Of two copies started at the same
    /// moment, the one launched first (then the lower process id) stays.
    private func handOffToRunningInstance() -> Bool {
        guard presentsWindows, Paths.isAppBundle, let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        func startedEarlier(_ other: NSRunningApplication) -> Bool {
            if let a = other.launchDate, let b = me.launchDate, a != b { return a < b }
            return other.processIdentifier < me.processIdentifier
        }
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
                  $0.processIdentifier != me.processIdentifier && !$0.isTerminated && startedEarlier($0)
              }),
              let otherURL = other.bundleURL else { return false }
        isDuplicateInstance = true
        Log.write("Deskset is already running (pid \(other.processIdentifier)); handing over and quitting")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let quit: (NSRunningApplication?, Error?) -> Void = { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        if pendingOpenURLs.isEmpty {
            NSWorkspace.shared.openApplication(at: otherURL, configuration: configuration, completionHandler: quit)
        } else {
            NSWorkspace.shared.open(pendingOpenURLs, withApplicationAt: otherURL, configuration: configuration,
                                    completionHandler: quit)
        }
        return true
    }

    /// Quitting with code typed in the skin editor asks first, like closing its window: it is committed, and when that
    /// fails, Save / Discard / Cancel (Cancel keeps the app running).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isDuplicateInstance else { return .terminateNow }
        if let inspector, !inspector.canTerminate() { return .terminateCancel }
        if let studio = StudioWindowController.window(for: self), !studio.canTerminate() { return .terminateCancel }
        for window in codeFileWindows where !window.canTerminate() { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A duplicate instance never loaded anything; saving its copy of the state would overwrite the running one's.
        guard !isDuplicateInstance else { return }
        stopAllForTermination()
        SoundPlayer.stop()
        state.saveNow()
        Fonts.removePrivateCopies()
    }

    /// True once the app is quitting: skins are being closed ("OnCloseAction: … when Rainmeter is closed").
    private(set) var isTerminating = false

    /// How long quitting waits in all for the skins' OnCloseActions (on their threads).
    static let terminationBudget: TimeInterval = 2
    /// Once a pool worker cannot close in order, leave the other worker time to run its own close actions.
    static let terminationWorkerReserve: TimeInterval = 0.25

    /// Runs every skin's OnCloseAction and closes it, keeping the loaded set for the next launch: `.close` goes to each
    /// skin in reverse load order, then quitting waits for them to close, at most `terminationBudget` in all (a skin on
    /// the main executor has closed by then already). Bangs sent from an OnCloseAction while quitting cannot load,
    /// unload or refresh skins (they would load a skin nobody closes, or mark a skin unloaded for the next launch just
    /// because it was running when the app quit). Returns the skins that had not closed in time.
    @discardableResult
    func stopAllForTermination(budget: TimeInterval = AppController.terminationBudget) -> [String] {
        isTerminating = true
        let deadline = Date().addingTimeInterval(budget)
        for session in studioSessions.values {
            // Every step is written as it is made; anything still waiting is written now.
            _ = try? session.diskSync.flush()
            session.closeStudioSkin()
        }
        let closing = Array(sortedControllers.reversed())
        let orderedDeadline = deadline.addingTimeInterval(-min(Self.terminationWorkerReserve, max(0, budget) / 4))
        var stalledWorkers: Set<ObjectIdentifier> = []
        for (index, c) in closing.enumerated() {
            c.stop()
            if threading == .pool {
                // A closing skin may send another skin a bang. Let it enqueue those messages before the next
                // skin's close is queued. Only reserve time when another, independent worker still needs to close.
                // This is one global cutoff, not a short per-skin timeout: ordinary close actions keep their order.
                let worker = ObjectIdentifier(c.runtime.executor)
                guard !stalledWorkers.contains(worker) else { continue }
                let hasOtherWorker = closing.dropFirst(index + 1).contains {
                    let other = ObjectIdentifier($0.runtime.executor)
                    return other != worker && !stalledWorkers.contains(other)
                }
                let limit = hasOtherWorker ? orderedDeadline : deadline
                if !c.runtime.waitUntilClosed(before: limit) {
                    stalledWorkers.insert(worker)
                    Log.write("Closing remaining skins without waiting longer for this worker's close action",
                              level: .warning, source: c.config)
                }
            }
        }
        let late = closing.filter { !$0.runtime.waitUntilClosed(before: deadline) }.map(\.config)
        if !late.isEmpty {
            Log.write("Quitting without waiting longer for \(late.joined(separator: ", ")) to close", level: .warning)
        }
        // Every skin stopped: nothing is watched any more.
        outsidePointer.needsChanged()
        return late
    }

    /// Opening the app again (Finder, Spotlight, Launchpad, its Dock icon while the editor or Settings is open) while
    /// it runs: the skin editor, Settings or a code window that is open comes back — out of the Dock when it was
    /// minimized; with none of them open, the Manage window (macOS may hide the menu bar icon, so this is the way back
    /// in).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isDuplicateInstance else { return false }
        if let window = reopenableWindow {
            if presentsWindows {
                NSApp.activate(ignoringOtherApps: true)
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            return false
        }
        showManageWindow(selecting: nil, file: nil)
        return false
    }

    /// The window a reopen brings back (nil: none is open).
    var reopenableWindow: NSWindow? {
        Self.reopenTarget(editor: inspector?.window, settings: SettingsWindowController.openWindow,
                          codeWindows: codeFileWindows.compactMap(\.window)) { $0.isVisible || $0.isMiniaturized }
    }

    /// The skin editor, else Settings, else the latest code window — the first of them that `isOpen` (shown, or
    /// minimized in the Dock).
    static func reopenTarget(editor: NSWindow?, settings: NSWindow?, codeWindows: [NSWindow],
                             isOpen: (NSWindow) -> Bool) -> NSWindow? {
        ([editor, settings].compactMap { $0 } + codeWindows.reversed()).first(where: isOpen)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isDuplicateInstance else { return }
        if launched { installer.open(CodeEditorRouter.routeOpenedFiles(urls, app: self)) } else { pendingOpenURLs += urls }
    }

    /// Loads the skins of the last session, one after another (`activateInOrder`). On the very first launch (no skin
    /// has any state yet) the first-run layout's skins at their places (`loadFirstRunLayout`); without one, the Clock
    /// alone. `then`: once the last one has started (at once with the main executor).
    func loadActiveSkins(then: (() -> Void)? = nil) {
        var active = state.activeConfigs
        if active.isEmpty && state.data.skins.isEmpty {
            let layout = firstRunLayout()
            if let first = layout.first {
                // Known before the first one loads: `then` shows the Manage window on it.
                firstRunSelection = first.config
                loadFirstRunLayout(layout, then: then)
                restack()
                return
            }
            state.update(DefaultSkins.firstClock.config) { $0.file = DefaultSkins.firstClock.file; $0.active = true }
            active = state.activeConfigs
        }
        activateInOrder(active.map { ($0.config, $0.state.file) }) { [weak self] in
            self?.restack()
            then?()
        }
        restack()
    }

    /// Loads the skins of `items` (config, file) one after another, each once the one before has started (or its load
    /// failed, or it was unloaded meanwhile), as the main thread always has: with the main executor each load is over
    /// when `activate` returns, and a skin's OnRefreshAction sees only the skins loaded before it. On the engine thread
    /// the loads would otherwise all be asked for at once, and a skin's `!DeactivateConfig` for a config further down
    /// the list (Enigma's Dock unloads its Menu when it loads) would unload a skin that had not loaded yet, which then
    /// never showed. `each`: every window made, with the index of its item (the first-run layout places it). `done`:
    /// after the last one settled (at once with the main executor). Main thread.
    func activateInOrder(_ items: [(config: String, file: String?)],
                         each: ((SkinWindowController, Int) -> Void)? = nil, done: @escaping () -> Void) {
        for (index, item) in items.enumerated() {
            inTurn { app in
                guard let c = app.activate(config: item.config, file: item.file, fade: true, restack: false) else {
                    return nil
                }
                each?(c, index)
                return c
            }
        }
        inTurn { _ in
            done()
            return nil
        }
    }

    // MARK: Loads one after another

    /// Loads (and reloads) waiting for their turn (`inTurn`), and whether one is under way.
    private var turns: [(AppController) -> SkinWindowController?] = []
    private var isTakingTurns = false
    /// What `later` was asked for while loads were taken in turn: run once the last of them settled, in order.
    private var afterTurns: [(AppController) -> Void] = []

    /// Runs `load` — an `activate` or a `refresh`, which returns the window it made — once every load asked for this
    /// way before it has settled: its skin started, its load failed, or it was unloaded (`whenSettled`). Main thread.
    ///
    /// On the main thread each load is over before the next begins, and a skin's OnRefreshAction sees only the skins
    /// loaded before it. A skin on the engine thread starts after `activate` returned, so loads asked for together
    /// (the session's skins at launch, Refresh All, `!RefreshGroup`, the `[!Refresh]` of every skin that follows the
    /// appearance, an installer loading a suite again) would otherwise all be registered before any of them loaded:
    /// Enigma's Dock unloads its Menu when it loads, and would then unload the Menu's new copy. With the main executor
    /// `load` runs at once, as before, unless an earlier load is still settling.
    func inTurn(_ load: @escaping (AppController) -> SkinWindowController?) {
        turns.append(load)
        takeTurns()
    }

    private func takeTurns() {
        guard !isTakingTurns else { return }
        isTakingTurns = true
        while !turns.isEmpty {
            let load = turns.removeFirst()
            if let c = load(self), c.isStarting {
                c.whenSettled { [weak self] in
                    guard let self else { return }
                    self.isTakingTurns = false
                    self.takeTurns()
                }
                return
            }
        }
        isTakingTurns = false
        let waiting = afterTurns
        afterTurns = []
        for body in waiting { later(body) }
    }

    /// `refresh`, in turn with the other loads asked for together (`inTurn`): the bangs' `!Refresh` and
    /// `!RefreshGroup`, and the appearance's `[!Refresh]`.
    func refreshInTurn(_ c: SkinWindowController) {
        inTurn { $0.refresh(c) }
    }

    /// Whether `activate` would make a window for `config` and `file`: the config exists and has an .ini file to load.
    func canActivate(config: String, file: String?) -> Bool {
        guard let entry = self.config(named: config) else { return false }
        return self.file(toLoad: file, of: entry) != nil
    }

    // MARK: System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { app in
            app.systemAsleep = true
            app.applyPause()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { app in
            app.systemAsleep = false
            app.systemDidWake()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { app in
            app.screensAsleep = true
            app.applyPause()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { app in
            app.screensAsleep = false
            app.applyPause()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { app in
            app.sessionInactive = true
            app.applyPause()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { app in
            app.sessionInactive = false
            app.applyPause()
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { app in
            app.screensChanged()
        }
        // `#CONFIGEDITOR#` follows Settings ▸ Editor.
        observe(NotificationCenter.default, .desksetEditorPreferencesChanged) { _ in
            EnvironmentStore.shared.publishConfigEditor()
        }
    }

    /// Lays the skins out again whenever the fonts change, whoever changed them (docs/skin-threading.md §4.4): also a
    /// layout that read its skin's font folder for the first time, or a skin loaded for a thumbnail or a dry run. Set
    /// up at launch; the self-tests' apps do without (a suite sets it up itself).
    func observeFonts() {
        observe(NotificationCenter.default, Fonts.didChangeNotification) { app in
            if Fonts.generation > app.fontsGenerationSeen { app.fontsChanged() }
        }
    }

    /// Publishes the appearance skins see (`MacAppearance`) and watches it: macOS switching between light and dark
    /// (the app's effective appearance) and the accent color changing (`NSColor.systemColorsDidChangeNotification`)
    /// run `appearanceChanged`; the 12/24-hour clock, the first day of the week and the temperature unit changing run
    /// `regionalSettingsChanged` (Foundation's locale change, and the preference keys behind them). A new time zone
    /// drops Foundation's cached one, so `Location=timezone` finds the new zone's city. Set up at launch; the
    /// self-tests' apps do without (a suite sets it up itself).
    func observeAppearance() {
        appearanceSeen = MacAppearance.current.refresh()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appearanceChanged() }
        }
        observe(NotificationCenter.default, NSColor.systemColorsDidChangeNotification) { app in app.appearanceChanged() }
        observe(NotificationCenter.default, NSLocale.currentLocaleDidChangeNotification) { app in
            app.regionalSettingsChanged()
        }
        regionalDefaults = RegionalDefaultsObserver { [weak self] in self?.regionalSettingsChanged(recheck: true) }
        observe(NotificationCenter.default, .NSSystemTimeZoneDidChange) { _ in NSTimeZone.resetSystemTimeZone() }
    }

    /// The clock, week or temperature setting may have changed (System Settings → General → Date & Time, Language &
    /// Region): worked out again (`MacRegional`) and passed on like an appearance change, so skins that use
    /// `#MACCLOCKHOURS#`, `#MACFIRSTWEEKDAY#` or `#MACTEMPERATUREUNIT#` run their `MacOnAppearanceChangeAction`.
    /// `recheck`: a preference key changed, which Foundation's current locale may not show yet — look once more a
    /// second later. Main thread.
    func regionalSettingsChanged(recheck: Bool = false) {
        MacRegional.refresh()
        appearanceChanged()
        guard recheck else { return }
        regionalRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MacRegional.refresh()
            self?.appearanceChanged()
        }
        regionalRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The appearance, the accent color or a clock, week or temperature setting may have changed: the new values are
    /// published, and when they differ from what the skins last saw, every skin that follows the appearance (it uses an
    /// appearance variable or writes an action of its own) runs its `MacOnAppearanceChangeAction`
    /// (`Skin.appearanceDidChange()`: `[!Refresh]` by default), where it is owned. Other skins are left alone.
    /// Main thread.
    func appearanceChanged() {
        DesktopInputs.appearance.refresh()
        let now = MacAppearance.current.refresh()
        guard now != appearanceSeen else { return }
        appearanceSeen = now
        for c in sortedControllers where !c.isStopped { c.runtime.send(.appearanceChanged) }
        // The Studio's own instances follow the appearance as the desktop copies do.
        for session in studioSessions.values { session.studioSkin?.appearanceDidChange() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping (AppController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { body(self) }
        }
        observers.append((center, token))
    }

    /// Sleep, display sleep and fast user switching stop all skin timers; they resume with an immediate update.
    /// Audio capture (AudioLevel, AppVolume peaks) stops meanwhile too: nothing would read it, and macOS would keep
    /// showing its recording indicator.
    private func applyPause() {
        audioEngine.setSuspended(updatesPaused)
        for c in controllers.values {
            if updatesPaused { c.pauseUpdates() } else { c.resumeUpdates(updateNow: true) }
        }
        for session in studioSessions.values { session.setUpdatesPaused(updatesPaused) }
    }

    private func systemDidWake() {
        Log.write("System woke from sleep")
        audioEngine.setSuspended(updatesPaused)
        for c in controllers.values {
            c.systemDidWake()
            if updatesPaused { c.pauseUpdates() }
        }
        for session in studioSessions.values { session.studioSkin?.systemDidWake() }
    }

    /// The capture engine suspended with skin updates (replaced in tests).
    var audioEngine = AudioCaptureEngine.shared

    /// Sets the pause reasons the system notifications set (tests) and applies them.
    func simulatePause(systemAsleep: Bool? = nil, screensAsleep: Bool? = nil, sessionInactive: Bool? = nil) {
        if let systemAsleep { self.systemAsleep = systemAsleep }
        if let screensAsleep { self.screensAsleep = screensAsleep }
        if let sessionInactive { self.sessionInactive = sessionInactive }
        applyPause()
    }

    /// Displays were connected, disconnected or rearranged.
    func screensChanged() {
        EnvironmentStore.shared.publishScreens()
        DesktopInputs.mainScreenDesktop.refresh()
        DesktopInputs.displayDesktops.refresh()
        DesktopInputs.allScreenDesktops.refresh()
        for c in controllers.values { c.screensChanged() }
    }

    // MARK: Skins

    /// All configs under the Skins folder (cached; `rescanLibrary()` refreshes).
    var library: [SkinConfig] {
        if let cachedLibrary { return cachedLibrary }
        let scanned = SkinLibrary.scan(skinsDirectory)
        cachedLibrary = scanned
        return scanned
    }

    func rescanLibrary() {
        cachedLibrary = nil
        notifyChanged()
    }

    /// A config by name (case-insensitive). An unknown name rescans the Skins folder (new folders may have been
    /// added in Finder), at most every few seconds so a skin asking for a missing config on every update cannot
    /// keep the disk busy.
    func config(named name: String) -> SkinConfig? {
        let key = SkinLibrary.normalizedConfigName(name)
        if let hit = library.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) { return hit }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMissRescan > 3 else { return nil }
        lastMissRescan = now
        cachedLibrary = nil
        return library.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    func controller(for config: String) -> SkinWindowController? {
        controllers[SkinLibrary.normalizedConfigName(config).lowercased()]
    }

    /// Active skins sorted by load order, then name.
    var sortedControllers: [SkinWindowController] {
        controllers.values.sorted {
            let a = $0.state, b = $1.state
            return (a.loadOrder, $0.config.lowercased()) < (b.loadOrder, $1.config.lowercased())
        }
    }

    /// Skins a bang's optional Config argument names: empty → `current`, `*` → every active skin.
    func controllers(forConfigArgument raw: String, current: SkinWindowController?) -> [SkinWindowController] {
        let name = SkinLibrary.normalizedConfigName(raw)
        if name.isEmpty { return current.map { [$0] } ?? [] }
        if name == "*" { return sortedControllers }
        return controller(for: name).map { [$0] } ?? []
    }

    /// Active skins in the skin group `group` (`Group=` in `[Rainmeter]`, case-insensitive), in load order: their
    /// snapshots say.
    func controllers(inGroup group: String) -> [SkinWindowController] {
        guard !group.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return sortedControllers.filter { c in
            !c.isStopped && SnapshotAudit.check("isInSkinGroup(\(group))", c.runtime,
                                                snapshot: c.runtime.snapshot.isInSkinGroup(group),
                                                live: { $0.isInSkinGroup(group) })
        }
    }

    /// Runs `body` on the next run loop turn. Bangs load, unload and refresh skins this way: loading a skin runs its
    /// OnRefreshAction, which may refresh the skin itself or another skin whose OnRefreshAction refreshes it back —
    /// done synchronously, that recursed until the stack overflowed.
    ///
    /// While loads are taken in turn (`inTurn`), what is asked meanwhile waits until the last of them has settled, as
    /// on the main thread, where a batch of loads (Refresh All, the session's skins) ran in one turn and what their
    /// OnRefreshActions asked for ran after all of them: Enigma's Dock, refreshed before its Menu, unloads the Menu it
    /// found, which is gone by then, not the Menu's new copy.
    func later(_ body: @escaping (AppController) -> Void) {
        if isTakingTurns {
            afterTurns.append(body)
            return
        }
        DispatchQueue.main.async { [weak self] in
            if let self { body(self) }
        }
    }

    /// Configs a bang asked to load (or reload as another variant) that have not been loaded yet (lowercased name →
    /// number of scheduled loads). The skins' directory follows every change.
    private var pendingLoads: [String: Int] = [:] {
        didSet { publishDirectory() }
    }

    /// Publishes the skins' directory: the running skins in load order, the configs a bang is loading.
    func publishDirectory() {
        skinDirectory.publish(entries: sortedControllers.map { SkinDirectory.Entry(config: $0.config, runtime: $0.runtime) },
                              pendingLoads: Set(pendingLoads.keys))
    }

    /// `later` for a change that may load `config` (`!ActivateConfig`, `!ToggleConfig`). Until it has run, bangs
    /// addressed to that config wait for it (see `isLoadPending`), so `[!ActivateConfig X][!Move 10 10 X]` moves the
    /// skin it has just loaded instead of finding no such skin (or the variant it replaces). Blocks run in the order
    /// they were scheduled.
    func later(loading config: String, _ body: @escaping (AppController) -> Void) {
        let key = SkinLibrary.normalizedConfigName(config).lowercased()
        pendingLoads[key, default: 0] += 1
        later { app in
            defer {
                let left = (app.pendingLoads[key] ?? 1) - 1
                app.pendingLoads[key] = left > 0 ? left : nil
            }
            body(app)
        }
    }

    /// True when a bang has scheduled loading `config` (`later(loading:_:)`) and that has not happened yet: a bang
    /// sent to it now should be scheduled after that load (with `later`), not dropped or sent to the skin it replaces.
    func isLoadPending(_ config: String) -> Bool {
        pendingLoads[SkinLibrary.normalizedConfigName(config).lowercased()] != nil
    }

    /// Loads `file` of `config` (the last used .ini, else the first one when nil), replacing a running variant.
    /// `continuing`: the skin a refresh replaces; the Calc `Counter` "only resets when the skin is unloaded and then
    /// loaded again - not when the skin is refreshed".
    ///
    /// The window controller and its runtime are made and registered at once (bangs for the config queue behind the
    /// load on the skin's executor); the runtime loads and starts the skin and reports `.loaded` (the window's settings
    /// apply) and `.started` (`skinStarted`: the window is placed and shown, the Studio attached, the app told), or
    /// `.failed` (`skinFailed`: the config is marked inactive). With the main executor all of it happens before this
    /// returns, and a skin that cannot be loaded returns nil.
    ///
    /// `ticket`: a reload the Studio asked for (`SkinReloadTicket`). It rides on the close of the running copy and the
    /// load of the new one, and the widget's editing session hears of each (`studioReload`). `place`: where the new
    /// copy's window goes once it started (a step that moves the widget with its files).
    @discardableResult
    func activate(config rawConfig: String, file: String?, fade: Bool = false, restack: Bool = true,
                  continuing previous: SkinRuntime? = nil, ticket: SkinReloadTicket? = nil,
                  thenMoveTo place: WidgetPosition? = nil) -> SkinWindowController? {
        guard !isTerminating else { return nil }
        activating += 1
        defer { activating -= 1 }
        guard let entry = config(named: rawConfig) else {
            Log.write("Config not found: \(SkinLibrary.normalizedConfigName(rawConfig))", level: .error)
            return nil
        }
        guard let chosen = self.file(toLoad: file, of: entry) else { return nil }
        let key = entry.name.lowercased()
        let replacing = controllers[key] != nil
        // First load of this config: the skin's Default… window settings apply (its runtime reads them).
        let firstLoad = state.skin(entry.name) == nil
        let executor = skinExecutor(entry.name)
        // A skin on another thread is listed in the skins' directory once its load is queued, in one change with the
        // copy it replaces: a skin on that thread that finds it there sends behind the load (`SkinRuntime.send`), and
        // never finds the config missing in between. On the main executor the skin loads inside `load`, listed as
        // before, so that its own bangs for its group or `*` find it.
        let inline = executor.isCurrent
        if !inline { directoryHeld += 1 }
        // The copy it replaces: on another thread its window stays, showing its last frame, until the new copy has
        // started (or failed), so the widget does not vanish for the time the load takes. On the main executor both
        // happen in this turn, as before.
        var replaced: SkinWindowController?
        if let running = controllers[key] {
            controllers[key] = nil
            // A copy that has not started shows nothing yet: the window it was to replace waits for this one instead.
            let handedOver = running.isStarting ? running.takeReplacedWindow() : nil
            let keepsWindow = !inline && !running.isStarting
            running.stop(ticket: ticket, keepsWindow: keepsWindow)
            replaced = handedOver ?? (keepsWindow ? running : nil)
        }
        state.update(entry.name) {
            $0.file = chosen
            $0.active = true
        }
        let c = SkinWindowController(config: entry.name, file: chosen, app: self, executor: executor)
        controllers[key] = c
        c.restacksWhenStarted = restack
        c.moveWhenStarted = place
        c.replacedWindow = replaced
        let order = SkinLoadOrder(state: c.state, firstLoad: firstLoad, continuing: previous,
                                  presentsWindows: presentsWindows, paused: updatesPaused, ticket: ticket)
        if let ticket { studioReload(ticket, .loading, c) }
        c.load(order, fadeIn: fade && !replacing)
        if !inline {
            directoryHeld -= 1
            if directoryHeld == 0 { publishDirectory() }
        }
        return c.loadFailed ? nil : c
    }

    /// A skin loaded and made its first update (`.started`), and its window is placed and shown: the Studio attaches
    /// to it when it edits the config, the windows are stacked again and the app hears of it.
    func skinStarted(_ c: SkinWindowController) {
        if let inspector, inspector.config.lowercased() == c.config.lowercased() { inspector.attach(c) }
        if c.restacksWhenStarted {
            restack()
        } else if activating == 0 {
            // Started after the batch that loaded it stacked the windows (a skin on the engine thread): stacked again
            // once for all the skins that start in this turn.
            restackSoon()
        }
        Log.write("Loaded \(c.config)\\\(c.file)")
        notifyChanged()
    }

    /// A skin could not be loaded (`.failed`): its config is unloaded and marked inactive (unless another load of it
    /// came meanwhile).
    func skinFailed(_ c: SkinWindowController, error: String) {
        Log.write("Could not load \(c.config)\\\(c.file): \(error)", level: .error)
        if controller(for: c.config) === c {
            controllers[c.config.lowercased()] = nil
            state.update(c.config) { $0.active = false }
        }
        notifyChanged()
    }

    /// The .ini file `activate` loads for `file`: that file of the config (in any case), else the last used one, else
    /// the first. nil when the config has no .ini file.
    private func file(toLoad file: String?, of entry: SkinConfig) -> String? {
        let requested = file.flatMap { f in entry.files.first { $0.caseInsensitiveCompare(f) == .orderedSame } }
        if let file, !file.isEmpty, requested == nil {
            Log.write("\(entry.name) has no file \"\(file)\"", level: .warning)
        }
        let remembered = state.skin(entry.name)?.file
        return requested ?? entry.files.first(where: { $0 == remembered }) ?? entry.files.first
    }

    /// `!ActivateConfig Config [File]`, sent by the skin `sender`. "If no file is specified, the next .ini file variant
    /// in the config folder is activated": a running config moves on to its next variant (one that is not running
    /// loads its last used one). Judgment call (the manual does not say what happens when the config already runs the
    /// file asked for): nothing happens but a warning in the log; forum threads about an "already active" warning
    /// suggest Rainmeter does the same. Reloading instead would let a skin that activates its own config reload itself
    /// endlessly (Monstercat Visualizer's update notice does that on every load while a newer version exists).
    /// `!Refresh`, the Manage window and the menus call `activate`, which always loads.
    func activateFromBang(config rawConfig: String, file: String?, sender: String) {
        guard !isTerminating else { return }
        guard let entry = config(named: rawConfig) else {
            Log.write("Config not found: \(SkinLibrary.normalizedConfigName(rawConfig))", level: .error)
            return
        }
        guard let chosen = self.file(toLoad: file ?? nextVariant(of: entry.name), of: entry) else { return }
        if let running = controller(for: entry.name), running.file.caseInsensitiveCompare(chosen) == .orderedSame {
            Log.write("!ActivateConfig: \"\(entry.name)\\\(running.file)\" is already active", level: .warning,
                      source: sender)
            return
        }
        activate(config: entry.name, file: chosen, fade: true)
    }

    func deactivate(config: String, fade: Bool = false) {
        guard !isTerminating, let c = controller(for: config) else { return }
        controllers[c.config.lowercased()] = nil
        state.update(c.config) { $0.active = false }
        if let inspector, inspector.config.lowercased() == c.config.lowercased() { inspector.detach() }
        c.stop(fadeOut: fade)
        Log.write("Unloaded \(c.config)")
        notifyChanged()
    }

    /// Unloads this particular controller (a no-op when its config has been reloaded or unloaded meanwhile).
    func deactivate(_ c: SkinWindowController, fade: Bool = false) {
        guard controller(for: c.config) === c else { return }
        deactivate(config: c.config, fade: fade)
    }

    /// Stops a skin without marking it inactive (its files are about to be replaced by an installer, which waits for
    /// it to close: `whenClosed`).
    @discardableResult
    func suspend(config: String) -> SkinWindowController? {
        guard let c = controller(for: config) else { return nil }
        controllers[c.config.lowercased()] = nil
        c.stop()
        return c
    }

    /// Runs `body` on the main thread once every skin of `stopped` has closed (their OnCloseActions have run), or once
    /// `timeout` has passed (a skin that does not close in time is logged): at once when they have (the main executor).
    func whenClosed(_ stopped: [SkinWindowController], timeout: TimeInterval, _ body: @escaping () -> Void) {
        var waiting = Set(stopped.map { ObjectIdentifier($0.runtime) })
        var done = false
        func finish() {
            guard !done else { return }
            done = true
            body()
        }
        guard !waiting.isEmpty else { return finish() }
        for c in stopped {
            let id = ObjectIdentifier(c.runtime)
            c.runtime.whenClosed {
                waiting.remove(id)
                if waiting.isEmpty { finish() }
            }
        }
        guard !done else { return }
        let names = stopped.map(\.config)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !done else { return }
            Log.write("Going on without waiting longer for \(names.joined(separator: ", ")) to close", level: .warning)
            finish()
        }
    }

    /// The .ini file after the running one of `config` in its folder (after the last one: the first), nil when the
    /// config is not running.
    func nextVariant(of config: String) -> String? {
        guard let running = controller(for: config), let entry = self.config(named: config), !entry.files.isEmpty
        else { return nil }
        let index = entry.files.firstIndex { $0.caseInsensitiveCompare(running.file) == .orderedSame } ?? -1
        return entry.files[(index + 1) % entry.files.count]
    }

    /// Loads `c`'s skin again (a new window controller and runtime), when it is the one running for its config: the
    /// new window (nil when `c` is not running any more or the load failed on the main executor).
    @discardableResult
    func refresh(_ c: SkinWindowController) -> SkinWindowController? {
        refresh(c, ticket: nil, thenMoveTo: nil)
    }

    /// `refresh` for a reload the Studio asked for (`ticket`), and where the window goes once the new copy started
    /// (`place`; see `activate`).
    @discardableResult
    func refresh(_ c: SkinWindowController, ticket: SkinReloadTicket?, thenMoveTo place: WidgetPosition?)
        -> SkinWindowController? {
        guard controller(for: c.config) === c else { return nil }
        return activate(config: c.config, file: c.file, continuing: c.runtime, ticket: ticket, thenMoveTo: place)
    }

    /// A copy of a widget went through a step of a reload the Studio asked for (`SkinReloadEvent`): the widget's
    /// editing session hears of it, whenever and in whatever order the copies get there. Main thread.
    func studioReload(_ ticket: SkinReloadTicket, _ event: SkinReloadEvent, _ c: SkinWindowController) {
        studioSessions[SkinLibrary.normalizedConfigName(c.config).lowercased()]?.reload(ticket, event, from: c)
    }

    /// "Refresh all": image files are decoded again (a skin author may have edited them), font folders are read
    /// again (fonts added, replaced or removed in `@Resources/Fonts`) and every skin reloads. What each skin's renderer
    /// kept (text layouts, processed Rotator images: `SkinRenderContext`) goes with the skin it replaces.
    func refreshAll(rescan: Bool) {
        Images.purge()
        Fonts.rescanAllFolders()
        let fonts = Fonts.generation
        if rescan { cachedLibrary = nil }
        // One after another (`inTurn`): each skin's OnRefreshAction sees the others as the main thread showed them.
        for c in sortedControllers { refreshInTurn(c) }
        // Every skin is loaded again with these fonts.
        fontsGenerationSeen = max(fontsGenerationSeen, fonts)
        inTurn { app in
            app.restack()
            app.notifyChanged()
            return nil
        }
    }

    /// `activate` calls under way (a skin of the main executor starts inside them).
    private var activating = 0
    private var restackPending = false

    /// `restack` on the next turn, once for everything asking before then.
    private func restackSoon() {
        guard !restackPending else { return }
        restackPending = true
        later { app in
            app.restackPending = false
            app.restack()
        }
    }

    /// Orders skins that share a Position by load order (higher in front), without moving them relative to
    /// other applications' windows.
    func restack() {
        guard presentsWindows else { return }
        let items = controllers.values.filter(\.isShown).map { c -> (item: SkinWindowController, alwaysOnTop: Int, loadOrder: Int, name: String) in
            let s = c.state
            return (c, s.alwaysOnTop, s.loadOrder, c.config)
        }
        for group in WindowGeometry.stackingGroups(items) {
            for (below, above) in zip(group, group.dropFirst()) {
                above.window.order(.above, relativeTo: below.window.windowNumber)
            }
        }
    }

    /// A skin's window settings changed (menu, Manage window or bang).
    func skinSettingsChanged() {
        notifyChanged()
    }

    // MARK: Window changes from skins

    private var windowBatchDepth = 0
    private var windowBatchNeeds = (restack: false, settingsChanged: false)
    private var windowBatchFlushQueued = false

    /// Runs `body`, in which skins' window bangs are applied (`SkinWindowController.applyWindowChange`), as one batch:
    /// the windows are stacked again and the app hears of changed settings once, at the end, as for one bang for a
    /// group of skins. Re-entrant.
    func batchingWindowChanges(_ body: () -> Void) {
        windowBatchDepth += 1
        body()
        windowBatchDepth -= 1
        if windowBatchDepth == 0 { flushWindowChanges() }
    }

    /// A skin's window change needs the windows stacked again, or the app told of changed settings: at the end of the
    /// batch it came in; one that came on its own (queued from a skin's thread) after the others queued with it.
    func windowChangesNeed(restack: Bool = false, settingsChanged: Bool = false) {
        if restack { windowBatchNeeds.restack = true }
        if settingsChanged { windowBatchNeeds.settingsChanged = true }
        guard windowBatchDepth == 0, !windowBatchFlushQueued else { return }
        windowBatchFlushQueued = true
        later { app in
            app.windowBatchFlushQueued = false
            app.flushWindowChanges()
        }
    }

    private func flushWindowChanges() {
        let needs = windowBatchNeeds
        windowBatchNeeds = (false, false)
        if needs.settingsChanged { skinSettingsChanged() }
        if needs.restack { restack() }
    }

    /// A skin registered fonts: skins laid out before may have measured their text with a fallback font, so their
    /// meters are laid out (and drawn) again with the fonts now available. `except`: the skin that registered them,
    /// which was laid out with them.
    func fontsChanged(except registering: SkinWindowController? = nil) {
        fontsGenerationSeen = max(fontsGenerationSeen, Fonts.generation)
        // Measure text again and recompute fixed window sizes (skins laid out with a fallback font), each skin where it
        // is owned: at once when that is here.
        for c in controllers.values where !c.isStopped && c !== registering { c.runtime.send(.fontsChanged) }
        for session in studioSessions.values { session.studioSkin?.fontsDidChange() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .desksetSkinsChanged, object: self)
    }

    /// Told on the next turn, once however many there were.
    private var detailsChangePending = false

    /// A running skin's compatibility notes or metadata changed (its snapshot says): the Manage window and the menus
    /// hear of it on the next turn, not in the middle of the skin's work.
    func skinDetailsChanged() {
        guard !detailsChangePending else { return }
        detailsChangePending = true
        later { app in
            app.detailsChangePending = false
            app.notifyChanged()
        }
    }

    // MARK: Windows

    func showManageWindow(selecting config: String?, file: String?) {
        let controller = manageWindow ?? ManageWindowController(app: self)
        manageWindow = controller
        if presentsWindows {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        if let config { controller.select(config: config, file: file) }
    }

    /// Opens the inspector on a loaded skin (moving it from another skin if it was open). A new editor window comes
    /// to the front once it is ready to be shown (its panes, toolbar and the widget on the canvas: `whenReadyToShow`);
    /// the rest of it is built while it shows.
    func showInspector(for c: SkinWindowController) {
        // A skin loading on the engine thread has no place and no first update yet: the Studio opens once it started
        // (at once with the main executor, where `activate` returns a started skin).
        guard !c.isStarting else {
            return c.whenStarted { [weak self, weak c] in
                guard let self, let c, self.controller(for: c.config) === c else { return }
                self.showInspector(for: c)
            }
        }
        // The new Studio window, while the StudioV2 switch is on (`StudioSwitch`).
        if StudioSwitch.isOn(for: self) { return StudioWindowController.show(for: c, app: self) }
        if let inspector {
            inspector.attach(c)
            return bringToFront(inspector)
        }
        let controller = InspectorWindowController(app: self, controller: c)
        inspector = controller
        controller.whenReadyToShow { [weak self, weak controller] in
            guard let self, let controller, self.inspector === controller else { return }
            self.bringToFront(controller)
        }
    }

    /// Activates the app and brings the window in front of the other apps' windows (a menu of the menu bar icon or
    /// a click on a skin does not activate the app, and an inactive app's window stays behind the active app's).
    func bringToFront(_ controller: NSWindowController) {
        lastBroughtToFront = controller.window
        guard presentsWindows, let window = controller.window else { return }
        activateApp(for: controller)
        if window.isMiniaturized { window.deminiaturize(nil) }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Makes the app active, with a Dock icon and menu bar while the window is open (`AppActivation`).
    func activateApp(for controller: NSWindowController) {
        guard presentsWindows, let window = controller.window else { return }
        AppActivation.track(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    func inspectorDidClose(_ controller: InspectorWindowController) {
        if inspector === controller { inspector = nil }
    }

    /// The editing session of a widget (made the first time the Studio edits it; kept until the app quits, with the
    /// widget's undo stack).
    func editingSession(for config: String) -> EditingSession {
        let key = SkinLibrary.normalizedConfigName(config).lowercased()
        if let session = studioSessions[key] { return session }
        let session = EditingSession(config: SkinLibrary.normalizedConfigName(config), app: self)
        studioSessions[key] = session
        return session
    }

    /// Opens a text file no running skin reads in a code window of the built-in editor (one per file; an open one
    /// comes to the front), at `line`. False when the file cannot be read.
    @discardableResult
    func showCodeFile(_ file: URL, line: Int?) -> Bool {
        let key = CodeEditorRouter.comparablePath(file)
        let controller: CodeFileWindowController
        if let open = codeFileWindows.first(where: { CodeEditorRouter.comparablePath($0.file) == key }) {
            controller = open
        } else {
            do {
                controller = try CodeFileWindowController(file: file, app: self)
            } catch {
                Log.write("Code editor: cannot open \(file.path): \(error.localizedDescription)", level: .warning)
                if file.isFileURL, file.pathExtension.lowercased() == "desk" {
                    let title = StudioText.language == .chinese
                        ? "无法打开“\(file.lastPathComponent)”" : "Can’t open “\(file.lastPathComponent)”"
                    alert(title, error.localizedDescription, style: .critical)
                }
                return false
            }
            codeFileWindows.append(controller)
        }
        bringToFront(controller)
        controller.reveal(line: line)
        return true
    }

    func codeFileWindowDidClose(_ controller: CodeFileWindowController) {
        codeFileWindows.removeAll { $0 === controller }
    }

    /// The Manage window when it is open (sheets attach to it).
    var visibleManageWindow: NSWindow? {
        guard let w = manageWindow?.window, w.isVisible else { return nil }
        return w
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Desktop widgets for your Mac, compatible with Rainmeter skins.\n"
                + "Rainmeter is a trademark of its respective owners; Deskset is not affiliated with it.\n"
                + WeatherWiring.credits,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits,
                                                                .applicationVersion: DesksetCore.version]
        if !Paths.isAppBundle { options[.applicationIcon] = AppIcon.image(size: 256) }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    /// The last alert asked for (title, text), also in headless mode (tests).
    private(set) var lastAlert: (title: String, text: String)?

    func alert(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        lastAlert = (title, text)
        guard presentsWindows else {
            Log.write("\(title): \(text)", level: .warning)
            return
        }
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        if let window = visibleManageWindow {
            a.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = AppIcon.statusBarImage()
            button.toolTip = "Deskset"
        }
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
    }

    func showMainMenu() {
        let menu = NSMenu()
        buildMainMenu(menu)
        popUpMenu(menu)
    }

    func popUpMenu(_ menu: NSMenu) {
        guard presentsWindows else { return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        buildMainMenu(menu)
        StudioSwitch.addMenuItem(to: menu, for: self)
    }

    func buildMainMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Manage Skins…", #selector(manageAction), key: ","))
        menu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())

        let skinsItem = NSMenuItem(title: "Skins", action: nil, keyEquivalent: "")
        skinsItem.submenu = skinsSubmenu()
        menu.addItem(skinsItem)

        let active = sortedControllers.sorted { $0.config.localizedStandardCompare($1.config) == .orderedAscending }
        if !active.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Loaded Skins", action: nil, keyEquivalent: "").isEnabled = false
            for c in active {
                let item = NSMenuItem(title: c.config, action: nil, keyEquivalent: "")
                item.submenu = skinMenu(for: c, includeCustomItems: false)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Refresh All", #selector(refreshAllAction), key: "r"))
        menu.addItem(item("Install Skin…", #selector(installSkinAction)))
        menu.addItem(item("Open Skins Folder", #selector(openSkinsFolderAction)))
        menu.addItem(item("Open Log", #selector(openLogAction)))
        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLaunchAtLoginAction))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        if !LaunchAtLogin.isAvailable {
            login.isEnabled = false
            login.toolTip = "Available when Deskset runs as an installed app."
        }
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(settingsAction), key: ","))
        menu.addItem(item("About Deskset", #selector(aboutAction)))
        menu.addItem(item("Quit Deskset", #selector(quitAction), key: "q"))
    }

    private func skinsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let library = self.library
        if library.isEmpty {
            menu.addItem(withTitle: "No skins installed", action: nil, keyEquivalent: "").isEnabled = false
        }
        var roots: [String: NSMenu] = [:]
        for entry in library {
            let parts = entry.name.split(separator: "\\").map(String.init)
            let rootName = entry.rootName
            let rootMenu: NSMenu
            if let m = roots[rootName.lowercased()] {
                rootMenu = m
            } else {
                rootMenu = NSMenu()
                roots[rootName.lowercased()] = rootMenu
                let rootItem = NSMenuItem(title: rootName, action: nil, keyEquivalent: "")
                rootItem.submenu = rootMenu
                menu.addItem(rootItem)
            }
            let running = controller(for: entry.name)
            let configMenu = NSMenu()
            for file in entry.files {
                let i = item(file, #selector(toggleSkinAction(_:)))
                i.representedObject = [entry.name, file]
                i.state = running?.file == file ? .on : .off
                configMenu.addItem(i)
            }
            let title = parts.count > 1 ? parts.dropFirst().joined(separator: " › ") : rootName
            let configItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            configItem.submenu = configMenu
            configItem.state = running != nil ? .on : .off
            rootMenu.addItem(configItem)
        }
        return menu
    }

    /// Custom skin actions (https://docs.rainmeter.net/manual/skins/rainmeter-section/#ContextTitle), as the
    /// engine reads them when the menu opens (titles "are always dynamic"; separators, 30-character titles and the
    /// rules for invalid items are the engine's). Each item runs its action from `[Rainmeter]`.
    private func addCustomItems(_ items: [ContextMenuItem], for c: SkinWindowController, to menu: NSMenu) {
        for entry in items {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let i = item(entry.title, #selector(customContextAction(_:)))
            i.representedObject = CustomMenuAction(controller: c, action: entry.action)
            menu.addItem(i)
        }
    }

    /// What a skin's menu shows of the skin itself: its custom items, its name and the weather credit.
    struct SkinMenuFacts {
        var items: [ContextMenuItem]
        var name: String?
        var weather: (uses: Bool, updated: String?)
        /// Read from the live skin; false: from its snapshot, because the skin was busy.
        var isLive: Bool
    }

    /// How long a menu waits for a busy skin (a skin on another thread in the middle of its work) before it shows what
    /// the skin's snapshot has.
    static let menuReadTimeout: TimeInterval = 0.05

    /// The skin's custom items, name and weather credit for its menu: read from the live skin with exclusive access
    /// (the titles "are always dynamic"), or, when the skin does not let go within `menuReadTimeout`, from its
    /// snapshot (the items as of the last change of its variables, the credit without the time of the data).
    func menuFacts(for c: SkinWindowController) -> SkinMenuFacts {
        if let live = c.runtime.exclusive(timeout: AppController.menuReadTimeout, { skin in
            SkinMenuFacts(items: skin.contextMenuItems(), name: ManageModel.metadataValue(skin.metadata, "Name"),
                          weather: MacWeatherMeasure.attributionInfo(for: skin), isLive: true)
        }) {
            return live
        }
        let snapshot = c.runtime.snapshot
        return SkinMenuFacts(items: snapshot.contextItems, name: ManageModel.metadataValue(snapshot.metadata, "Name"),
                             weather: (snapshot.usesWeather, nil), isLive: false)
    }

    /// Menu with only the skin's custom items (`!SkinCustomMenu`), nil when it has none.
    func customSkinMenu(for c: SkinWindowController) -> NSMenu? {
        let items = menuFacts(for: c).items
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        addCustomItems(items, for: c, to: menu)
        return menu
    }

    /// Per-skin menu (context menu on the skin and submenu in the status menu).
    func skinMenu(for c: SkinWindowController, includeCustomItems: Bool) -> NSMenu {
        let menu = NSMenu()
        let s = c.state
        // The compatibility notes from the skin's snapshot; the custom items, the name and the weather credit read when
        // the menu opens (`menuFacts`).
        let snapshot = c.runtime.snapshot
        if includeCustomItems {
            let facts = menuFacts(for: c)
            let title = facts.name ?? c.config
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
            let custom = facts.items
            // "If more than 3 ContextTitleN options are given, 'Custom skin actions' becomes a submenu."
            if custom.count > 3 {
                let submenu = NSMenu()
                addCustomItems(custom, for: c, to: submenu)
                let holder = NSMenuItem(title: "Custom Skin Actions", action: nil, keyEquivalent: "")
                holder.submenu = submenu
                menu.addItem(holder)
            } else if !custom.isEmpty {
                addCustomItems(custom, for: c, to: menu)
            }
            // CC BY 4.0: every skin that shows MET Norway's forecasts credits them, whoever wrote it.
            for weather in WeatherWiring.menuItems(for: facts.weather, target: self,
                                                   action: #selector(openWeatherSourceAction(_:))) {
                menu.addItem(weather)
            }
            menu.addItem(.separator())
        }

        if let entry = config(named: c.config), entry.files.count > 1 {
            let variants = NSMenu()
            for file in entry.files {
                let i = item(file, #selector(variantAction(_:)))
                i.representedObject = [c.config, file]
                i.state = file == c.file ? .on : .off
                variants.addItem(i)
            }
            let variantsItem = NSMenuItem(title: "Variants", action: nil, keyEquivalent: "")
            variantsItem.submenu = variants
            menu.addItem(variantsItem)
        }

        let position = NSMenu()
        for (title, value) in ManageModel.positions {
            let i = item(title, #selector(zPositionAction(_:)))
            i.representedObject = [c.config, String(value)]
            i.state = s.alwaysOnTop == value ? .on : .off
            position.addItem(i)
        }
        let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        positionItem.submenu = position
        menu.addItem(positionItem)

        let transparency = NSMenu()
        for percent in stride(from: 0, through: 90, by: 10) {
            let alpha = ManageModel.alpha(forTransparencyPercent: percent)
            let i = item("\(percent)%", #selector(transparencyAction(_:)))
            i.representedObject = [c.config, String(alpha)]
            i.state = ManageModel.transparencyPercent(forAlpha: s.alphaValue) == percent ? .on : .off
            transparency.addItem(i)
        }
        let transparencyItem = NSMenuItem(title: "Transparency", action: nil, keyEquivalent: "")
        transparencyItem.submenu = transparency
        menu.addItem(transparencyItem)

        let hover = NSMenu()
        for mode in SkinVisibility.HoverMode.allCases {
            let i = item(mode.title, #selector(hoverAction(_:)))
            i.representedObject = [c.config, String(mode.rawValue)]
            i.state = s.onHover == mode.rawValue ? .on : .off
            hover.addItem(i)
        }
        let hoverItem = NSMenuItem(title: "On Hover", action: nil, keyEquivalent: "")
        hoverItem.submenu = hover
        menu.addItem(hoverItem)

        for (title, key, on) in [("Draggable", "draggable", s.draggable), ("Click Through", "clickthrough", s.clickThrough),
                                 ("Keep on Screen", "keeponscreen", s.keepOnScreen), ("Snap to Edges", "snapedges", s.snapEdges),
                                 ("Save Position", "saveposition", s.savePosition)] {
            let i = item(title, #selector(toggleSettingAction(_:)))
            i.representedObject = [c.config, key]
            i.state = on ? .on : .off
            menu.addItem(i)
        }

        let skinIssues = snapshot.issues
        if !skinIssues.isEmpty {
            menu.addItem(.separator())
            let issues = NSMenu()
            for issue in skinIssues.prefix(50) {
                issues.addItem(withTitle: issue, action: nil, keyEquivalent: "").isEnabled = false
            }
            let issuesItem = NSMenuItem(title: "Compatibility Notes (\(skinIssues.count))", action: nil, keyEquivalent: "")
            issuesItem.submenu = issues
            menu.addItem(issuesItem)
        }

        menu.addItem(.separator())
        // Edit Skin… opens the Skin Studio (its Code view is the built-in code editor). A code editor app chosen in
        // Settings ▸ Editor gets an item of its own.
        var entries: [(String, Selector)] = [("Manage Skin…", #selector(manageSkinAction(_:))),
                                             ("Edit Skin…", #selector(inspectSkinAction(_:)))]
        if case .external(let editor, _) = CodeEditorRouter.route(file: c.fileURL, line: nil,
                                                                  preferences: state.editor,
                                                                  locator: CodeEditorRouter.locator) {
            entries.append(("Edit in \(editor.name)", #selector(editSkinAction(_:))))
        }
        entries += [("Refresh Skin", #selector(refreshSkinAction(_:))),
                    ("Open Skin Folder", #selector(openSkinFolderAction(_:))),
                    ("Unload Skin", #selector(unloadSkinAction(_:)))]
        for (title, selector) in entries {
            let i = item(title, selector)
            i.representedObject = [c.config]
            menu.addItem(i)
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func args(_ sender: NSMenuItem) -> [String] { sender.representedObject as? [String] ?? [] }

    // MARK: Settings (shared by menus and the Manage window)

    /// Changes a skin's window settings and applies them.
    func changeSettings(of c: SkinWindowController, animated: Bool = false, _ change: (inout SkinState) -> Void) {
        let before = c.state
        state.update(c.config, change)
        let after = c.state
        c.applyWindowSettings(animated: animated)
        if before.alwaysOnTop != after.alwaysOnTop || before.loadOrder != after.loadOrder {
            if presentsWindows && c.isShown { c.window.orderFrontRegardless() }
            restack()
        }
        // Bangs for `*` and skin groups go in load order.
        if before.loadOrder != after.loadOrder { publishDirectory() }
        if !before.keepOnScreen && after.keepOnScreen { c.windowMoved() }
        if !before.savePosition && after.savePosition { c.windowMoved() }
        skinSettingsChanged()
    }

    // MARK: Menu actions

    @objc private func toggleSkinAction(_ sender: NSMenuItem) {
        let a = args(sender)
        guard a.count == 2 else { return }
        if let running = controller(for: a[0]), running.file == a[1] {
            deactivate(config: a[0], fade: true)
        } else {
            activate(config: a[0], file: a[1], fade: true)
        }
    }

    @objc private func variantAction(_ sender: NSMenuItem) {
        let a = args(sender)
        guard a.count == 2 else { return }
        activate(config: a[0], file: a[1])
    }

    /// A chosen custom item: its action runs on the skin's executor, from `[Rainmeter]`.
    @objc func customContextAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? CustomMenuAction, let c = entry.controller, !c.isStopped,
              !entry.action.isEmpty else { return }
        c.runtime.send(.execute(entry.action, section: "Rainmeter"))
    }

    @objc private func zPositionAction(_ sender: NSMenuItem) {
        let a = args(sender)
        guard a.count == 2, let c = controller(for: a[0]), let v = Int(a[1]) else { return }
        changeSettings(of: c) { $0.alwaysOnTop = v }
    }

    @objc private func transparencyAction(_ sender: NSMenuItem) {
        let a = args(sender)
        guard a.count == 2, let c = controller(for: a[0]), let v = Int(a[1]) else { return }
        c.clearFadedAlpha()
        changeSettings(of: c, animated: true) { $0.alphaValue = v }
    }

    @objc private func hoverAction(_ sender: NSMenuItem) {
        let a = args(sender)
        guard a.count == 2, let c = controller(for: a[0]), let v = Int(a[1]) else { return }
        changeSettings(of: c) { $0.onHover = v }
    }

    @objc private func toggleSettingAction(_ sender: NSMenuItem) {
        let a = args(sender)
        guard a.count == 2, let c = controller(for: a[0]) else { return }
        changeSettings(of: c) {
            switch a[1] {
            case "draggable": $0.draggable.toggle()
            case "clickthrough": $0.clickThrough.toggle()
            case "keeponscreen": $0.keepOnScreen.toggle()
            case "snapedges": $0.snapEdges.toggle()
            case "saveposition": $0.savePosition.toggle()
            default: break
            }
        }
    }

    @objc private func manageSkinAction(_ sender: NSMenuItem) {
        if let c = args(sender).first.flatMap(controller(for:)) { showManageWindow(selecting: c.config, file: c.file) }
    }

    @objc private func inspectSkinAction(_ sender: NSMenuItem) {
        if let c = args(sender).first.flatMap(controller(for:)) { showInspector(for: c) }
    }

    @objc private func refreshSkinAction(_ sender: NSMenuItem) {
        if let c = args(sender).first.flatMap(controller(for:)) { refresh(c) }
    }

    @objc private func editSkinAction(_ sender: NSMenuItem) {
        if let c = args(sender).first.flatMap(controller(for:)) { CodeEditorRouter.open(file: c.fileURL, app: self) }
    }

    @objc private func openSkinFolderAction(_ sender: NSMenuItem) {
        if let c = args(sender).first.flatMap(controller(for:)) { Workspace.reveal(c.fileURL.deletingLastPathComponent()) }
    }

    @objc private func unloadSkinAction(_ sender: NSMenuItem) {
        if let config = args(sender).first { deactivate(config: config, fade: true) }
    }

    @objc func manageAction() { showManageWindow(selecting: nil, file: nil) }

    @objc func refreshAllAction() { refreshAll(rescan: true) }

    @objc func installSkinAction() { installer.chooseAndInstall() }

    @objc func openSkinsFolderAction() {
        try? FileManager.default.createDirectory(at: skinsDirectory, withIntermediateDirectories: true)
        Workspace.reveal(skinsDirectory)
    }

    @objc private func openLogAction() { Workspace.edit(Paths.logFile) }

    @objc func toggleLaunchAtLoginAction() {
        LaunchAtLogin.toggle(app: self)
        notifyChanged()
    }

    @objc func aboutAction() { showAbout() }

    /// The skin menu's MET Norway credit: opens the data's source.
    @objc func openWeatherSourceAction(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}

/// A custom context menu item: the skin it belongs to (a refreshed or unloaded skin runs nothing) and its action.
final class CustomMenuAction: NSObject {
    weak var controller: SkinWindowController?
    let action: String

    init(controller: SkinWindowController, action: String) {
        self.controller = controller
        self.action = action
    }
}

/// Where the app runs its desktop skins: the `SkinThreading` default, read once at launch (`main.swift`). The shared
/// engine thread remains the default while the bounded worker pool is validated.
///
///     defaults write app.deskset.Deskset SkinThreading main     (or -SkinThreading main for one launch)
enum SkinThreading: String {
    /// Every skin on the main thread, as the app ran them before phase 2: for debugging.
    case main
    /// The desktop skins on one engine thread (the default); the Studio's own instances, dry runs and thumbnails stay
    /// on main.
    case engine
    /// A bounded worker pool, with periodic updates coalesced per worker and asynchronous bangs between skins.
    case pool

    static let defaultsKey = "SkinThreading"
    /// Without the key, or with an unknown value.
    static let appDefault = SkinThreading.engine

    /// The mode `defaults` asks for, and what to say about it in the log: an unknown value means the default.
    static func chosen(in defaults: UserDefaults) -> (mode: SkinThreading, note: String?) {
        guard let raw = defaults.object(forKey: defaultsKey) else { return (appDefault, nil) }
        let text = (raw as? String ?? "\(raw)").trimmingCharacters(in: .whitespaces)
        if let mode = SkinThreading(rawValue: text.lowercased()) {
            return (mode, mode == .main ? "Desktop skins run on the main thread (\(defaultsKey)=main)" : nil)
        }
        return (appDefault, "Unknown \(defaultsKey) value \"\(text)\" (main, engine or pool): desktop skins run on the "
                + "engine thread")
    }
}
