import AppKit
import DesksetCore

/// App delegate: menu bar item, skin lifecycle, state, Manage window, skin installation, system events.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state: AppState
    let skinsDirectory: URL
    let layoutsDirectory: URL
    let backupsDirectory: URL
    /// False for headless use (`--self-test`, `--snapshot-ui`): skin windows are created but never shown.
    let presentsWindows: Bool
    /// The skin editor's window is built in steps, a few per turn of the run loop, so the skins go on animating while
    /// it opens (`InspectorWindowController.queueOpening`). Headless it is built at once, unless a self-test asks.
    var opensEditorInSteps: Bool

    /// Running skins keyed by lowercased config name.
    private(set) var controllers: [String: SkinController] = [:]
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

    private var systemAsleep = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var updatesPaused: Bool { systemAsleep || screensAsleep || sessionInactive }

    /// Bump when the bundled example skins change so they are re-copied.
    private static let defaultSkinsVersion = 2

    init(state: AppState? = nil, skinsDirectory: URL = Paths.skins, layoutsDirectory: URL = Paths.layouts,
         backupsDirectory: URL = Paths.backups, presentsWindows: Bool = true) {
        self.state = state ?? AppState()
        self.skinsDirectory = skinsDirectory
        self.layoutsDirectory = layoutsDirectory
        self.backupsDirectory = backupsDirectory
        self.presentsWindows = presentsWindows
        opensEditorInSteps = presentsWindows
        super.init()
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }
        Paths.ensureDirectories()
        Log.rotateIfNeeded()
        Log.write("Deskset \(DesksetCore.version) starting on macOS "
                  + ProcessInfo.processInfo.operatingSystemVersionString)
        // `defaults write app.deskset.Deskset MainThreadStallLog -int 50`: main-thread stalls go to the log.
        MainThreadStallMonitor.shared.configure(from: .standard)
        if !Paths.isAppBundle { NSApp.applicationIconImage = AppIcon.image(size: 512) }
        NSApp.mainMenu = MainMenu.make(app: self)
        CodeEditorRouter.install(app: self)
        WebParserAccess.install(settingsFolder: Paths.appSupport)
        let firstRun = state.data.skins.isEmpty
        installDefaultSkinsIfNeeded()
        setUpStatusItem()
        observeSystem()
        observeFonts()
        loadActiveSkins()
        launched = true
        if !pendingOpenURLs.isEmpty {
            installer.open(CodeEditorRouter.routeOpenedFiles(pendingOpenURLs, app: self))
            pendingOpenURLs = []
        } else if firstRun {
            // First launch: show where things are (the menu bar icon can be hidden by macOS).
            showManageWindow(selecting: "Deskset\\Clock", file: nil)
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

    /// Runs every skin's OnCloseAction and closes it, keeping the loaded set for the next launch. Bangs sent from an
    /// OnCloseAction while quitting cannot load, unload or refresh skins (they would load a skin nobody closes, or
    /// mark a skin unloaded for the next launch just because it was running when the app quit).
    func stopAllForTermination() {
        isTerminating = true
        for c in sortedControllers.reversed() { c.stop() }
        // Every skin stopped: nothing is watched any more.
        outsidePointer.needsChanged()
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

    private func installDefaultSkinsIfNeeded() {
        guard state.data.defaultSkinsInstalled < AppController.defaultSkinsVersion,
              let source = Paths.defaultSkins,
              let roots = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles]) else { return }
        let fm = FileManager.default
        for root in roots {
            let target = skinsDirectory.appendingPathComponent(root.lastPathComponent)
            var previous: URL?
            if fm.fileExists(atPath: target.path) {
                // Keep the old copy (users may have edited it) next to the new one.
                let backup = backupsDirectory.appendingPathComponent("\(root.lastPathComponent)-examples-v\(state.data.defaultSkinsInstalled)")
                try? fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
                try? fm.removeItem(at: backup)
                if (try? fm.moveItem(at: target, to: backup)) != nil { previous = backup } else { try? fm.removeItem(at: target) }
            }
            do {
                try fm.copyItem(at: root, to: target)
            } catch {
                Log.write("Could not install example skin \(root.lastPathComponent): \(error)", level: .error)
                continue
            }
            // Carry over the user's choices (Theme, ClockHours, Volume…) for keys that still exist.
            if let previous {
                let inc = "@Resources/Variables.inc"
                AppController.carryOverVariables(from: previous.appendingPathComponent(inc),
                                                 to: target.appendingPathComponent(inc))
            }
        }
        state.setDefaultSkinsInstalled(AppController.defaultSkinsVersion)
        cachedLibrary = nil
    }

    private func loadActiveSkins() {
        var active = state.activeConfigs
        if active.isEmpty && state.data.skins.isEmpty {
            state.update("Deskset\\Clock") { $0.file = "Clock.ini"; $0.active = true }
            active = state.activeConfigs
        }
        for (config, s) in active { activate(config: config, file: s.file, fade: true, restack: false) }
        restack()
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
    }

    /// Lays the skins out again whenever the fonts change, whoever changed them (docs/skin-threading.md §4.4): also a
    /// layout that read its skin's font folder for the first time, or a skin loaded for a thumbnail or a dry run. Set
    /// up at launch; the self-tests' apps do without (a suite sets it up itself).
    func observeFonts() {
        observe(NotificationCenter.default, Fonts.didChangeNotification) { app in
            if Fonts.generation > app.fontsGenerationSeen { app.fontsChanged() }
        }
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
    }

    private func systemDidWake() {
        Log.write("System woke from sleep")
        audioEngine.setSuspended(updatesPaused)
        for c in controllers.values {
            c.systemDidWake()
            if updatesPaused { c.pauseUpdates() }
        }
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

    func controller(for config: String) -> SkinController? {
        controllers[SkinLibrary.normalizedConfigName(config).lowercased()]
    }

    /// Active skins sorted by load order, then name.
    var sortedControllers: [SkinController] {
        controllers.values.sorted {
            let a = $0.state, b = $1.state
            return (a.loadOrder, $0.config.lowercased()) < (b.loadOrder, $1.config.lowercased())
        }
    }

    /// Skins a bang's optional Config argument names: empty → `current`, `*` → every active skin.
    func controllers(forConfigArgument raw: String, current: SkinController?) -> [SkinController] {
        let name = SkinLibrary.normalizedConfigName(raw)
        if name.isEmpty { return current.map { [$0] } ?? [] }
        if name == "*" { return sortedControllers }
        return controller(for: name).map { [$0] } ?? []
    }

    /// Active skins in the skin group `group` (`Group=` in `[Rainmeter]`, case-insensitive), in load order.
    func controllers(inGroup group: String) -> [SkinController] {
        guard !group.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return sortedControllers.filter { !$0.isStopped && $0.skin.isInSkinGroup(group) }
    }

    /// Runs `body` on the next run loop turn. Bangs load, unload and refresh skins this way: loading a skin runs its
    /// OnRefreshAction, which may refresh the skin itself or another skin whose OnRefreshAction refreshes it back —
    /// done synchronously, that recursed until the stack overflowed.
    func later(_ body: @escaping (AppController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self { body(self) }
        }
    }

    /// Configs a bang asked to load (or reload as another variant) that have not been loaded yet (lowercased name →
    /// number of scheduled loads).
    private var pendingLoads: [String: Int] = [:]

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
    @discardableResult
    func activate(config rawConfig: String, file: String?, fade: Bool = false, restack: Bool = true,
                  continuing previous: Skin? = nil) -> SkinController? {
        guard !isTerminating else { return nil }
        guard let entry = config(named: rawConfig) else {
            Log.write("Config not found: \(SkinLibrary.normalizedConfigName(rawConfig))", level: .error)
            return nil
        }
        guard let chosen = self.file(toLoad: file, of: entry) else { return nil }
        let key = entry.name.lowercased()
        let replacing = controllers[key] != nil
        // First load of this config: the skin's Default… window settings apply (see `seedWindowSettings`).
        let firstLoad = state.skin(entry.name) == nil
        if let running = controllers[key] {
            controllers[key] = nil
            running.stop()
        }
        state.update(entry.name) {
            $0.file = chosen
            $0.active = true
        }
        do {
            let c = try SkinController(config: entry.name, file: chosen, app: self)
            controllers[key] = c
            if firstLoad { c.seedWindowSettings() }
            if let previous { c.skin.continueCounter(from: previous) }
            c.start(fadeIn: fade && !replacing)
            if let inspector, inspector.config.lowercased() == key { inspector.attach(c) }
            if updatesPaused { c.pauseUpdates() }
            if restack { self.restack() }
            Log.write("Loaded \(entry.name)\\\(chosen)")
            notifyChanged()
            return c
        } catch {
            Log.write("Could not load \(entry.name)\\\(chosen): \(error)", level: .error)
            state.update(entry.name) { $0.active = false }
            notifyChanged()
            return nil
        }
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
    func deactivate(_ c: SkinController, fade: Bool = false) {
        guard controller(for: c.config) === c else { return }
        deactivate(config: c.config, fade: fade)
    }

    /// Stops a skin without marking it inactive (its files are about to be replaced by an installer).
    func suspend(config: String) {
        guard let c = controller(for: config) else { return }
        controllers[c.config.lowercased()] = nil
        c.stop()
    }

    /// The .ini file after the running one of `config` in its folder (after the last one: the first), nil when the
    /// config is not running.
    func nextVariant(of config: String) -> String? {
        guard let running = controller(for: config), let entry = self.config(named: config), !entry.files.isEmpty
        else { return nil }
        let index = entry.files.firstIndex { $0.caseInsensitiveCompare(running.file) == .orderedSame } ?? -1
        return entry.files[(index + 1) % entry.files.count]
    }

    func refresh(_ c: SkinController) {
        guard controller(for: c.config) === c else { return }
        activate(config: c.config, file: c.file, continuing: c.skin)
    }

    /// "Refresh all": image files are decoded again (a skin author may have edited them), font folders are read
    /// again (fonts added, replaced or removed in `@Resources/Fonts`) and every skin reloads. What each skin's renderer
    /// kept (text layouts, processed Rotator images: `SkinRenderContext`) goes with the skin it replaces.
    func refreshAll(rescan: Bool) {
        Images.purge()
        Fonts.rescanAllFolders()
        let fonts = Fonts.generation
        if rescan { cachedLibrary = nil }
        for c in sortedControllers { refresh(c) }
        // Every skin was just loaded again with these fonts.
        fontsGenerationSeen = max(fontsGenerationSeen, fonts)
        restack()
        notifyChanged()
    }

    /// Orders skins that share a Position by load order (higher in front), without moving them relative to
    /// other applications' windows.
    func restack() {
        guard presentsWindows else { return }
        let items = controllers.values.filter(\.isShown).map { c -> (item: SkinController, alwaysOnTop: Int, loadOrder: Int, name: String) in
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

    /// A skin registered fonts: skins laid out before may have measured their text with a fallback font, so their
    /// meters are laid out (and drawn) again with the fonts now available.
    func fontsChanged() {
        fontsGenerationSeen = max(fontsGenerationSeen, Fonts.generation)
        // Measure text again and recompute fixed window sizes (skins laid out with a fallback font), each skin where it
        // is owned: at once when that is here.
        for c in controllers.values where !c.isStopped {
            let skin: Skin = c.skin
            if skin.executor.isCurrent {
                skin.fontsDidChange()
            } else {
                skin.async { skin.fontsDidChange() }
            }
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .desksetSkinsChanged, object: self)
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
    func showInspector(for c: SkinController) {
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
                + "Rainmeter is a trademark of its respective owners; Deskset is not affiliated with it.",
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
        if menu === statusMenu { buildMainMenu(menu) }
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
    private func addCustomItems(_ items: [ContextMenuItem], for c: SkinController, to menu: NSMenu) {
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

    /// Menu with only the skin's custom items (`!SkinCustomMenu`), nil when it has none.
    func customSkinMenu(for c: SkinController) -> NSMenu? {
        let items = c.skin.contextMenuItems()
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        addCustomItems(items, for: c, to: menu)
        return menu
    }

    /// Per-skin menu (context menu on the skin and submenu in the status menu).
    func skinMenu(for c: SkinController, includeCustomItems: Bool) -> NSMenu {
        let menu = NSMenu()
        let s = c.state
        if includeCustomItems {
            let title = ManageModel.metadataValue(c.skin.metadata, "Name") ?? c.config
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
            let custom = c.skin.contextMenuItems()
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

        if !c.skin.issues.isEmpty {
            menu.addItem(.separator())
            let issues = NSMenu()
            for issue in c.skin.issues.prefix(50) {
                issues.addItem(withTitle: issue, action: nil, keyEquivalent: "").isEnabled = false
            }
            let issuesItem = NSMenuItem(title: "Compatibility Notes (\(c.skin.issues.count))", action: nil, keyEquivalent: "")
            issuesItem.submenu = issues
            menu.addItem(issuesItem)
        }

        menu.addItem(.separator())
        // Edit Skin… opens the Skin Studio (its Code view is the built-in code editor). A code editor app chosen in
        // Settings ▸ Editor gets an item of its own.
        var entries: [(String, Selector)] = [("Manage Skin…", #selector(manageSkinAction(_:))),
                                             ("Edit Skin…", #selector(inspectSkinAction(_:)))]
        if case .external(let editor, _) = CodeEditorRouter.route(file: c.skin.fileURL, line: nil,
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
    func changeSettings(of c: SkinController, animated: Bool = false, _ change: (inout SkinState) -> Void) {
        let before = c.state
        state.update(c.config, change)
        let after = c.state
        c.applyWindowSettings(animated: animated)
        if before.alwaysOnTop != after.alwaysOnTop || before.loadOrder != after.loadOrder {
            if presentsWindows && c.isShown { c.window.orderFrontRegardless() }
            restack()
        }
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

    @objc private func customContextAction(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? CustomMenuAction, let c = entry.controller, !c.isStopped,
              !entry.action.isEmpty else { return }
        c.skin.execute(entry.action, from: c.skin.rainmeterSection)
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
        if let c = args(sender).first.flatMap(controller(for:)) { CodeEditorRouter.open(file: c.skin.fileURL, app: self) }
    }

    @objc private func openSkinFolderAction(_ sender: NSMenuItem) {
        if let c = args(sender).first.flatMap(controller(for:)) { Workspace.reveal(c.skin.directory) }
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

    @objc private func quitAction() { NSApp.terminate(nil) }
}

/// A custom context menu item: the skin it belongs to (a refreshed or unloaded skin runs nothing) and its action.
final class CustomMenuAction: NSObject {
    weak var controller: SkinController?
    let action: String

    init(controller: SkinController, action: String) {
        self.controller = controller
        self.action = action
    }
}

extension AppController {
    /// Copies [Variables] values of `old` into `new` for keys present in both (new keys and comments stay).
    static func carryOverVariables(from old: URL, to new: URL) {
        guard let oldText = try? TextDecoding.readFile(at: old),
              let oldVars = IniDocument.parse(oldText).section(named: "Variables"),
              let newText = try? TextDecoding.readFile(at: new),
              let newVars = IniDocument.parse(newText).section(named: "Variables") else { return }
        for entry in newVars.entries where !entry.key.lowercased().hasPrefix("@include") {
            guard let value = oldVars.value(forKey: entry.key), value != entry.value else { continue }
            try? IniWriter.writeValue(value, key: entry.key, section: "Variables", fileURL: new)
        }
    }
}
