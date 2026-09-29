import AppKit
import DesksetCore
import os

/// What happened in an editing session, for the Studio window that shows it.
enum SessionChange {
    /// The Studio's instance of the widget was loaded again: after a step, an undo or redo, a change on disk, a refresh
    /// of the widget. Whatever showed the old one follows the new one. With a step, an undo or a redo, the edits it made
    /// to each file's text (the code pane makes them in its own copy); nil when they are not known (a change on disk, a
    /// refresh: the code pane reads the files again).
    case reloaded(SourceTextEdits?)
    /// The Studio's instance took a step, an undo or a redo without loading again (`applyToStudio`): the same object
    /// shows the new text and keeps what it has shown (graphs, the counter, values set by clicks). Whatever showed it
    /// follows it as after `reloaded`, the code pane by the edits made to each file's text.
    case patched(SkinPatchSummary, SourceTextEdits?)
    /// A step was made: in memory, on disk, on the desktop, on the undo stack.
    case applied(Transaction)
    /// A step was undone (`undo`) or redone.
    case reverted(Transaction, undo: Bool)
    /// Undoing or redoing a step failed (a file changed elsewhere, or could not be written): nothing changed.
    case revertFailed(Transaction, undo: Bool, Error)
    /// Files of the widget changed on disk (another app saved them, or the widget ran `!WriteKeyValue`): what is taken
    /// is the Studio's call (live reload).
    case filesChangedOnDisk([URL])
    /// The widget on the desktop wrote these files while the session reloaded it (an OnCloseAction, an OnRefreshAction,
    /// a first update's `!WriteKeyValue`, a script): its own write, which the text in memory took. The Studio's instance
    /// follows it; nothing reloads the widget on the desktop again.
    case desktopWroteFiles([URL])
}

/// The Studio window showing a session.
protocol EditingSessionClient: AnyObject {
    /// An undo or redo is about to change the files: edits waiting for their pause and previews end first.
    func sessionWillRevert(_ session: EditingSession)
    func session(_ session: EditingSession, didChange change: SessionChange)
}

/// Why a step was not made.
enum SessionError: Error, CustomStringConvertible {
    /// The Studio's instance loaded with the step does not show it (`verify`): the files are as they were.
    case notInEffect

    var description: String { "the widget does not show the change" }
}

/// One widget being edited. The Studio reads and changes the widget only through it:
///
/// - **The text in memory is the truth** (`buffers`). Every edit is a list of `EditOp`s that the INI backend
///   (`IniBackend`, today's write-back rules) turns into changes of that text; together they are one step (`Transaction`)
///   on the widget's **undo stack** (`undoStack`). The stack belongs to the widget and is kept by the app (`AppController`
///   keeps the sessions), so closing the Studio window keeps it until the app quits.
/// - **The disk follows** (`diskSync`): for now every step is written at once — each step ends a gesture — atomically,
///   in each file's encoding. Files saved elsewhere are found with FSEvents (`SourceWatcher`) and by comparing their
///   bytes; buffers without edits of their own take the disk's text before every step, undo and reload, as the file
///   writers always read the file they change.
/// - **The Studio edits its own instance** of the widget (`studioSkin`, hosted by `StudioHost`): loaded from the text in
///   memory, on the main thread, running what stays inside the widget of its actions (`StudioActionPolicy`). The widget
///   on the desktop keeps running in its own window: it shows the previews of a gesture as they happen and follows a
///   step once it is written — as a patch when the Studio's instance took it as one (`followStep`), else by loading
///   again (`refreshDesktop`).
final class EditingSession {
    /// The widget's config, lowercased (the app's key for the session).
    let key: String
    private(set) var config: String
    unowned let app: AppController
    let buffers = SourceBuffers()
    /// What the Studio's instance reads: the text in memory, and typed code not written yet (`showTypedCode`).
    lazy var studioSources = StudioSources(buffers: buffers)
    let diskSync: DiskSync
    /// The widget's undo stack (the Studio window uses it as its own: ⌘Z, the toolbar, the toasts).
    let undoStack = EditorUndoManager()
    let host = StudioHost()
    /// Sample data the Studio's instance shows in place of what its measures read (the preview bar; nil: live).
    var measureValues: MeasureValueOverride? { didSet { studioSkin?.measureValues = measureValues } }
    /// The clock the Studio's instance reads (nil: the Mac's): frozen time in the preview. Taken at the next load.
    var studioClock: SkinClock?
    /// The Studio's own instance of the widget (nil while no Studio window shows the widget).
    private(set) var studioSkin: Skin?
    /// The widget's main file, as the desktop runs it.
    private(set) var fileURL: URL?
    /// The widget on the desktop, as the Studio window last linked it (`bind`). A refresh while no window follows the
    /// widget makes a new one: `currentDesktop` finds it.
    weak var desktop: SkinWindowController? {
        didSet { host.desktop = desktop }
    }
    /// The Studio window showing the widget.
    weak var client: EditingSessionClient?
    private let watcher = SourceWatcher()
    private var updates: SkinScheduledWork?
    private var updatesPaused = false
    /// A reload of the widget on the desktop the session asked for (`refreshDesktop`) that has not ended yet (see
    /// `OwnReload`). What the widget writes to its files meanwhile is its own write, taken when it ends
    /// (`absorbDesktopWrites`); FSEvents' reports wait for it (`touchedDuringReload`).
    private var ownReload: OwnReload?
    /// The session's latest reload: a copy that carries it and starts after that reload ended at its deadline is still
    /// the session's own (`isOwnReload`).
    private var lastTicket: SkinReloadTicket?
    /// Files FSEvents reported while a reload of the session's was open: looked at once it ended, against what it took.
    private var touchedDuringReload: [URL] = []
    /// `refreshDesktop` is asking the app for the reload: it does not end before the app has said what it did.
    private var isAskingForReload = false
    /// How long a reload of the session's is waited for at most.
    static let ownReloadTimeout: TimeInterval = 5
    /// How long the Studio's first instance waits for the desktop copy to let go of its counter and graphs.
    static let seedTimeout: TimeInterval = SkinRuntime.defaultExclusiveTimeout
    /// How long the phases of the last step, undo or redo took (milliseconds): `plan`, `apply`, `write`, `studio`
    /// (loading the Studio's instance and the Studio following it) with its parts (`reloadPhases`: `studio.load`,
    /// `studio.update`, `window`, `window.<part>`), `total` — and, once it ran, `desktop` (the reload of the desktop
    /// copy, on the next turn of the run loop).
    private(set) var lastTimings: [String: Double] = [:]
    /// The phases of the Studio's last reload (`reloadStudioSkin`); the Studio window times its parts here.
    let reloadPhases = StudioPhaseClock()
    /// The desktop copy's patch waiting for its turn, and how the Studio's instance took the last step (DesktopFollowing).
    let follow = SessionFollowing()
    /// The reload of the desktop copy waiting for the next turn of the run loop (`scheduleDesktopRefresh`), and where
    /// the widget's window goes once it ran (a step that moves it with the files).
    private var scheduledRefresh: Timer?
    private var placeAfterRefresh: WidgetPosition?

    private static let signposter = OSSignposter(subsystem: "app.deskset.Deskset", category: "Studio")

    init(config: String, app: AppController) {
        self.config = config
        key = config.lowercased()
        self.app = app
        diskSync = DiskSync(buffers: buffers)
        watcher.onChange = { [weak self] files in self?.filesTouched(files) }
    }

    deinit {
        updates?.cancel()
        scheduledRefresh?.invalidate()
        ownReload?.deadline?.invalidate()
        watcher.stop()
    }

    // MARK: The widget

    /// Links the widget on the desktop (each refresh makes a new one). Returns true when it runs another file than
    /// before (another variant, or the first link).
    @discardableResult
    func bind(desktop c: SkinWindowController) -> Bool {
        desktop = c
        config = c.config
        let url = c.fileURL
        let other = fileURL.map { SourceFileID($0) != SourceFileID(url) } ?? true
        fileURL = url
        followInput(of: c)
        return other
    }

    /// The input the widget on the desktop takes reaches the Studio's instance too (`Skin.inputMirror`): what a click,
    /// a hover or another widget's bang shows there — a page turned, a theme picked — the canvas shows, as it did when
    /// it drew the desktop copy.
    private func followInput(of c: SkinWindowController) {
        let runtime = c.runtime
        let mirror: (SkinInput) -> Void = { [weak self, weak runtime] input in
            let replay = {
                guard let self, let runtime, self.desktop?.runtime === runtime, let studio = self.studioSkin else { return }
                studio.replay(input)
            }
            if Thread.isMainThread { replay() } else { DispatchQueue.main.async(execute: replay) }
        }
        runtime.send(.mirrorInput(mirror))
    }

    /// The widget on the desktop now: the linked one, or — after it was loaded again while no Studio window followed it
    /// (the session outlives the window) — the one the app runs for the widget now, which is linked from then on. nil
    /// when the widget is not loaded (then the linked one, stopped, can still be loaded again: `refreshDesktop`).
    var currentDesktop: SkinWindowController? {
        if let linked = desktop, app.controller(for: linked.config) === linked { return linked }
        guard let now = app.controller(for: desktop?.config ?? config) else { return nil }
        desktop = now
        return now
    }

    /// The widget on the desktop when it runs there now (for steps outside the files: its window's settings).
    var runningDesktop: SkinWindowController? {
        guard let c = currentDesktop, !c.isStopped else { return nil }
        return c
    }

    /// Loads the Studio's own instance again from the text in memory — after buffers without edits of their own took
    /// what changed on disk — and tells the Studio window. The Calc `Counter` goes on from the old instance, which is
    /// closed once the new one had its first update (nothing in between shows nothing); the first instance takes the
    /// counter, the graphs and what else the widget on the desktop has shown (`runtimeSeed`), taken with exclusive
    /// access to it (`seedTimeout`). Keeps the old one when the widget's file cannot be read.
    @discardableResult
    func reloadStudioSkin(notify: Bool = true) -> Skin? {
        guard let fileURL else { return studioSkin }
        reloadPhases.reset()
        diskSync.adoptChanges()
        // In memory before it loads, so it reads them from there (files it includes that are new come in after).
        _ = try? buffers.load(fileURL)
        for url in studioSkin?.includedFiles ?? [] { _ = try? buffers.load(url) }
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: app.skinsDirectory, system: SystemMonitor.shared,
                        host: host)
        skin.sourceProvider = studioSources
        skin.actionPolicy = host.policy
        skin.measureValues = measureValues
        if let studioClock { skin.skinClock = studioClock }
        // A new instance reads the widget's real files again, as the desktop copy does when it reloads.
        host.policy.resetFiles()
        let stamps = diskSync.modificationDates()
        do {
            try reloadPhases.measure("studio.load") { try skin.load() }
        } catch {
            Log.write("Studio: cannot load \(fileURL.lastPathComponent): \(error)", level: .warning, source: config)
            return studioSkin
        }
        for url in skin.includedFiles { _ = try? buffers.load(url) }
        // The desktop copy registered the widget's fonts already; a new font file is registered here.
        if Fonts.registerFonts(for: skin) { app.fontsChanged() }
        let old = studioSkin
        // Opened: the canvas shows what the widget on the desktop shows — its Calc Counter and its graphs — as it did
        // when it drew that one. What the desktop copy has shown is taken as a value (`Skin.runtimeState`) with exclusive
        // access (at once on the main executor; a copy on another thread lets go between two pieces of its work), so the
        // counter and the graphs are of one moment. A copy busy past `seedTimeout` is not read: the Studio's instance
        // starts from its own first update.
        var mirrored: SkinRuntimeState?
        if old == nil, let running = runningDesktop?.runtime, SourceFileID(running.fileURL) == SourceFileID(fileURL) {
            mirrored = running.exclusive(timeout: Self.seedTimeout) { desktop in desktop.runtimeState(as: .mirror) }
        }
        let seed = runtimeSeed(old: old, mirrored: mirrored)
        if let seed { skin.seed(from: seed) }
        reloadPhases.measure("studio.update") { skin.update() }
        takeOwnWrites(since: stamps)
        if let seed { skin.seedGraphs(from: seed) }
        studioSkin = skin
        studioSources.waiting = nil
        startUpdates(skin)
        old?.close()
        watcher.watch(skin.sourceFiles)
        if notify { reloadPhases.measure("window") { client?.session(self, didChange: .reloaded(nil)) } }
        return skin
    }

    /// The Studio no longer shows the widget (its window closed, the widget was unloaded): its instance goes, and the
    /// watching of the files. The text in memory and the undo stack stay.
    func closeStudioSkin() {
        updates?.cancel()
        updates = nil
        watcher.stop()
        desktop?.runtime.send(.mirrorInput(nil))
        let old = studioSkin
        studioSkin = nil
        old?.close()
    }

    /// Sleep, a locked screen: no updates of the Studio's instance (the app pauses the widgets on the desktop too).
    func setUpdatesPaused(_ paused: Bool) {
        guard paused != updatesPaused else { return }
        updatesPaused = paused
        host.updatesPaused = paused
        if paused {
            updates?.cancel()
            updates = nil
        } else if let skin = studioSkin {
            if SkinRuntime.updateInterval(skin.settings.update) != nil { skin.update() }
            startUpdates(skin)
        }
    }

    /// The instance's update clock: the widget's own `Update`, as on the desktop.
    private func startUpdates(_ skin: Skin) {
        updates?.cancel()
        updates = nil
        guard !updatesPaused, let interval = SkinRuntime.updateInterval(skin.settings.update) else { return }
        updates = skin.executor.timer(interval: interval, leeway: SkinRuntime.timerTolerance(interval), repeats: true) {
            [weak self, weak skin] in
            guard let self, let skin, self.studioSkin === skin else { return }
            skin.update()
        }
    }

    /// A safety net: a file of the widget the Studio's instance changed while it loaded (its scripts and downloads write
    /// to a private copy, so nothing should) is the session's own write — the text in memory takes it (the Studio then
    /// shows it: `reloaded`) and no live reload follows, which would load the instance again, and it would write again.
    /// Not for its later updates: a save in another app landing in one of them (every 16 ms for a visualizer) would be
    /// taken for the instance's and not reload the widget.
    func takeOwnWrites(since stamps: [SourceFileID: Date]) {
        let now = diskSync.modificationDates(stamps.keys.map(\.url))
        let written = stamps.filter { now[$0.key] != $0.value }.map(\.key.url)
        guard !written.isEmpty else { return }
        diskSync.adoptChanges(written)
        diskSync.restamp()
        Log.write("Studio: the widget's own instance wrote \(written.map(\.lastPathComponent).joined(separator: ", "))",
                  level: .debug, source: config)
    }

    // MARK: Steps

    /// Makes a step: plans `ops` on the text in memory (buffers without edits of their own take what changed on disk
    /// first), makes the changes, writes them (for now every step is written: each ends a gesture), gives them to the
    /// Studio's instance (`applyToStudio`: a patch, else a reload) and — when `verify` finds the change in effect there —
    /// reloads the widget on the desktop and puts the step on the undo stack (unless `registersUndo` is false: the
    /// caller folds it into a step of its own). Returns nil when nothing changes.
    ///
    /// Throws when the step cannot be planned or written — nothing changed then — or when `verify` says the widget does
    /// not show it (`SessionError.notInEffect`): the files are put back, and so is the Studio's instance.
    @discardableResult
    func apply(_ name: String, _ ops: [EditOp], commands: [TransactionCommand] = [], selectionBefore: [String] = [],
               selectionAfter: [String] = [], registersUndo: Bool = true, verify: ((Skin) -> Bool)? = nil) throws
        -> Transaction? {
        willApply?()
        var timings: [String: Double] = [:]
        let start = DispatchTime.now().uptimeNanoseconds
        func lap(_ phase: String, _ since: UInt64) { timings[phase] = Double(DispatchTime.now().uptimeNanoseconds - since) / 1e6 }
        defer {
            timings["total"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            lastTimings = timings
        }
        var t0 = DispatchTime.now().uptimeNanoseconds
        let plan = Self.signposter.beginInterval("edit.plan")
        diskSync.adoptChanges()
        let changes = try IniBackend.plan(ops, in: buffers)
        Self.signposter.endInterval("edit.plan", plan)
        lap("plan", t0)
        guard !changes.isEmpty else { return nil }

        t0 = DispatchTime.now().uptimeNanoseconds
        try buffers.apply(changes)
        lap("apply", t0)
        t0 = DispatchTime.now().uptimeNanoseconds
        do {
            try write()
        } catch {
            // Nothing is kept that is not on disk: the text goes back to what the files still hold.
            try? buffers.apply(changes, reverse: true)
            _ = try? diskSync.flush()
            throw error
        }
        lap("write", t0)

        t0 = DispatchTime.now().uptimeNanoseconds
        let runtime = Self.signposter.beginInterval("runtime.apply")
        let reloaded = studioSkin != nil ? applyToStudio(changes) : nil
        Self.signposter.endInterval("runtime.apply", runtime)
        lap("studio", t0)
        if reloaded != nil { timings.merge(reloadPhases.take()) { own, _ in own } }
        if let verify, let reloaded, !verify(reloaded) {
            try? buffers.apply(changes, reverse: true)
            try? write()
            if studioSkin != nil { applyToStudio(changes, undo: true) }
            throw SessionError.notInEffect
        }

        // The desktop copy follows on the next turn (a patch, or a load): the canvas shows the step first.
        var place: WidgetPosition?
        for case .moveWidget(_, let to) in commands { place = to }
        followStep(changes, thenMoveTo: place)
        let t = Transaction(name: name, changes: changes, selectionBefore: selectionBefore, selectionAfter: selectionAfter,
                            commands: commands)
        if registersUndo { registerUndo(t) }
        client?.session(self, didChange: .applied(t))
        return t
    }

    /// Writes what is not written yet.
    private func write() throws {
        let state = Self.signposter.beginInterval("disk.flush")
        defer { Self.signposter.endInterval("disk.flush", state) }
        try diskSync.flush()
    }

    /// Puts `t` on the undo stack: undoing it takes it back (`undo`), and redoing it makes it again.
    func registerUndo(_ t: Transaction, undo: Bool = true) {
        undoStack.registerUndo(withTarget: self) { session in session.revert(t, undo: undo) }
        undoStack.setActionName(t.name)
    }

    /// Puts a step that grows (the color panel's picks, `step`) on the undo stack: undoing it takes back what it holds
    /// then, and seals it (a later pick makes a new step).
    func registerUndo(_ step: GrowingStep) {
        undoStack.registerUndo(withTarget: self) { session in
            step.isSealed = true
            session.revert(step.transaction, undo: true)
        }
        undoStack.setActionName(step.transaction.name)
    }

    /// Undoes (`undo`) or redoes a step: the files must hold what the step left in them (else nothing changes and the
    /// Studio hears why), the other side of the step goes on the stack, the widget's window moves with the files
    /// (`TransactionCommand`), the Studio's instance takes the text (`applyToStudio`) and the desktop copy loads the
    /// files again.
    func revert(_ t: Transaction, undo: Bool) {
        client?.sessionWillRevert(self)
        let start = DispatchTime.now().uptimeNanoseconds
        var timings: [String: Double] = [:]
        defer {
            timings["total"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            lastTimings = timings
        }
        diskSync.adoptChanges()
        do {
            try buffers.apply(t.changes, reverse: undo)
        } catch {
            client?.session(self, didChange: .revertFailed(t, undo: undo, error))
            return
        }
        do {
            try write()
        } catch {
            try? buffers.apply(t.changes, reverse: !undo)
            _ = try? diskSync.flush()
            client?.session(self, didChange: .revertFailed(t, undo: undo, error))
            return
        }
        registerUndo(t, undo: !undo)
        var place: WidgetPosition?
        for case .moveWidget(let from, let to) in t.commands { place = undo ? from : to }
        let t0 = DispatchTime.now().uptimeNanoseconds
        if studioSkin != nil { applyToStudio(t.changes, undo: undo) }
        timings["studio"] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if studioSkin != nil { timings.merge(reloadPhases.take()) { own, _ in own } }
        // The window moves with the files once the desktop copy took them (next turn).
        followStep(t.changes, thenMoveTo: place)
        client?.session(self, didChange: .reverted(t, undo: undo))
    }

    /// `first` and `later` (made right after it, on the text it left) as one step: each file goes from what it was
    /// before `first` to what it is now. nil when `later` does not start from what `first` left.
    func merged(_ first: Transaction, _ later: Transaction) -> Transaction? {
        var result = first
        for change in later.changes {
            guard let i = result.changes.firstIndex(where: { $0.file == change.file }) else {
                result.changes.append(change)
                continue
            }
            let mine = result.changes[i]
            guard mine.digestAfter == change.digestBefore, let now = buffers.buffer(change.file.url)?.text,
                  TextDigest(now) == change.digestAfter else { return nil }
            let before = mine.inverse.applied(to: change.inverse.applied(to: now))
            // What the file held before the first step, exactly (bytes that did not survive decoding come back too).
            if let combined = SourceChange(file: change.file, before: before, after: now, encodingBefore: mine.encodingBefore,
                                           encodingAfter: change.encodingAfter, bytesBefore: mine.exactBefore) {
                result.changes[i] = combined
            } else {
                result.changes.remove(at: i)
            }
        }
        result.commands += later.commands
        result.selectionAfter = later.selectionAfter
        return result
    }

    // MARK: Previews (a gesture in progress)

    /// How often a gesture's previews reach the desktop copy at most (design §9.1: about 20 times a second).
    static let desktopPreviewInterval: TimeInterval = 0.05

    /// Previews waiting for the desktop copy: the latest values of each section (in the order they came) and variable.
    private var pendingSections: [(section: String, values: [String: String])] = []
    private var pendingVariables: [String: String] = [:]
    private var desktopPreviewTimer: Timer?
    private var lastDesktopPreview: UInt64 = 0
    /// How many previews reached the desktop copy (for the self-tests).
    private(set) var desktopPreviewsSent = 0

    /// Shows option values without writing them (`Skin.preview`): at once in the Studio's instance, which the canvas
    /// draws; on the desktop at most `desktopPreviewInterval` apart, always with the latest values, and not while the
    /// desktop copy cannot be seen (the step reloads it when the gesture ends).
    func preview(section: String, _ values: [String: String]) {
        studioSkin?.preview(section: section, values)
        if let i = pendingSections.firstIndex(where: { $0.section.caseInsensitiveCompare(section) == .orderedSame }) {
            pendingSections[i].values.merge(values) { _, new in new }
        } else {
            pendingSections.append((section, values))
        }
        scheduleDesktopPreview()
    }

    /// Shows `[Variables]` values without writing them (`Skin.previewVariables`), as `preview` does.
    func previewVariables(_ values: [String: String]) {
        studioSkin?.previewVariables(values)
        pendingVariables.merge(values) { _, new in new }
        scheduleDesktopPreview()
    }

    /// Ends every preview, here and on the desktop (what still waits for the desktop is dropped).
    func endPreview() {
        studioSkin?.endPreview()
        desktopPreviewTimer?.invalidate()
        desktopPreviewTimer = nil
        pendingSections = []
        pendingVariables = [:]
        runningDesktop?.runtime.send(.endPreview)
    }

    /// Sends the waiting previews now when the last ones went at least `desktopPreviewInterval` ago, else once that
    /// much time has passed.
    private func scheduleDesktopPreview() {
        guard app.defersDesktopUpdates else { return flushDesktopPreview() }
        guard desktopPreviewTimer == nil else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- lastDesktopPreview) / 1e9
        let wait = Self.desktopPreviewInterval - elapsed
        guard wait > 0 else { return flushDesktopPreview() }
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            self?.desktopPreviewTimer = nil
            self?.flushDesktopPreview()
        }
        RunLoop.main.add(timer, forMode: .common)
        desktopPreviewTimer = timer
    }

    /// Sends the waiting previews to the desktop copy — unless its window cannot be seen (behind the Studio's, on
    /// another space): they wait for the next preview then.
    func flushDesktopPreview() {
        desktopPreviewTimer?.invalidate()
        desktopPreviewTimer = nil
        guard !pendingSections.isEmpty || !pendingVariables.isEmpty, let c = runningDesktop else { return }
        guard !app.presentsWindows || c.window.occlusionState.contains(.visible) else { return }
        let sections = pendingSections, variables = pendingVariables
        pendingSections = []
        pendingVariables = [:]
        lastDesktopPreview = DispatchTime.now().uptimeNanoseconds
        desktopPreviewsSent += 1
        c.runtime.send(.preview(sections: sections, variables: variables))
    }

    // MARK: The desktop and the disk

    /// Reloads the widget on the desktop from the files (after a step is written), or loads it again when an earlier
    /// reload could not (the files may be fixed since), then moves its window to where a step put it once the new copy
    /// started. The reload carries a ticket (docs/skin-threading.md §8.5): the copy that comes of it is the session's
    /// own (`isOwnReload`), and what the widget writes to its files until every copy it touched has reported — the old
    /// copy's OnCloseAction, the new one's OnRefreshAction or first update, a script — is its own write
    /// (`absorbDesktopWrites`, when the reload ends), not a change made elsewhere that would reload it again (and again,
    /// when it writes something new each time it loads). With the main executor all of it happens before this returns;
    /// a copy on another thread reports later, in whatever order its work gets there.
    func refreshDesktop() {
        scheduledRefresh?.invalidate()
        scheduledRefresh = nil
        let place = placeAfterRefresh
        placeAfterRefresh = nil
        guard let c = currentDesktop ?? desktop else { return }
        let state = Self.signposter.beginInterval("desktop.refresh")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            Self.signposter.endInterval("desktop.refresh", state)
            lastTimings["desktop"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        let ticket = SkinReloadTicket.next()
        lastTicket = ticket
        // A reload asked for while one is still open joins it: it ends when every copy either touched has reported.
        let reload = ownReload ?? OwnReload()
        ownReload = reload
        reload.tickets.insert(ticket)
        reload.deadline?.invalidate()
        let deadline = Timer(timeInterval: Self.ownReloadTimeout, repeats: false) { [weak self, weak reload] _ in
            guard let self, let reload, self.ownReload === reload else { return }
            Log.write("Studio: the widget's reload did not end within \(Int(Self.ownReloadTimeout)) s",
                      level: .debug, source: self.config)
            self.endOwnReload()
        }
        RunLoop.main.add(deadline, forMode: .common)
        reload.deadline = deadline
        isAskingForReload = true
        if app.controller(for: c.config) === c {
            app.refresh(c, ticket: ticket, thenMoveTo: place)
        } else if app.controller(for: c.config) == nil, c.isStopped {
            app.activate(config: c.config, file: c.file, ticket: ticket, thenMoveTo: place)
        }
        isAskingForReload = false
        // No new copy was made (the app could not load the widget again): the window moves as it is.
        if let place, !reload.made.contains(ticket) { runningDesktop?.moveTo(x: place.x, y: place.y) }
        endOwnReloadIfSettled()
    }

    /// A reload of the widget on the desktop the session asked for (`refreshDesktop`), until every copy it touched has
    /// reported (`SkinReloadEvent`): the old copy its close (`.closing`, then `.closed` once OnCloseAction ran), the
    /// new one its start (`.loading`, then `.started`, `.failed` or `.abandoned`). A reload asked for meanwhile joins
    /// it (`tickets`). It ends then, or at the deadline (`ownReloadTimeout`).
    private final class OwnReload {
        var tickets: Set<SkinReloadTicket> = []
        /// The reports still to come: each copy's close or start.
        var awaited: Set<Awaited> = []
        /// The tickets for which the app made a new copy.
        var made: Set<SkinReloadTicket> = []
        var deadline: Timer?
    }

    private struct Awaited: Hashable {
        /// The copy's window controller (kept until it reported: the app keeps a new copy, a stopped one keeps itself
        /// until its skin closed).
        let copy: ObjectIdentifier
        /// Its close (else its start).
        let closing: Bool
    }

    /// A copy of the widget went through a step of a reload the session asked for (`AppController.studioReload`).
    func reload(_ ticket: SkinReloadTicket, _ event: SkinReloadEvent, from c: SkinWindowController) {
        guard let reload = ownReload, reload.tickets.contains(ticket) else {
            // The copy of the session's latest reload started after that reload ended at its deadline: what it wrote so
            // far is its own too.
            if event == .started, ticket == lastTicket { absorbDesktopWrites() }
            return
        }
        let copy = ObjectIdentifier(c)
        switch event {
        case .closing:
            reload.awaited.insert(Awaited(copy: copy, closing: true))
        case .loading:
            reload.awaited.insert(Awaited(copy: copy, closing: false))
            reload.made.insert(ticket)
        case .closed:
            reload.awaited.remove(Awaited(copy: copy, closing: true))
        case .started, .failed, .abandoned:
            reload.awaited.remove(Awaited(copy: copy, closing: false))
        }
        endOwnReloadIfSettled()
    }

    /// Ends the open reload when every copy it touched has reported (not while the app is still being asked for it).
    private func endOwnReloadIfSettled() {
        guard !isAskingForReload, let reload = ownReload, reload.awaited.isEmpty else { return }
        endOwnReload()
    }

    /// The reload ends: what the widget wrote meanwhile is taken as its own (the Studio's instance follows it), and
    /// the changes FSEvents reported meanwhile are looked at against what was taken.
    private func endOwnReload() {
        guard let reload = ownReload else { return }
        reload.deadline?.invalidate()
        ownReload = nil
        absorbDesktopWrites()
        let touched = touchedDuringReload
        touchedDuringReload = []
        if !touched.isEmpty { filesTouched(touched) }
    }

    /// Reloads the desktop copy on the next turn of the run loop (`refreshDesktop`), once for a burst of steps, then
    /// moves its window to `place` when given. On that turn AppKit draws the canvas first — it shows the Studio's
    /// instance, loaded from memory — so a step reaches the canvas without waiting for the second load.
    /// While the Studio holds the desktop copy on its last working version (`passDesktopHold`) the reload waits, and is
    /// made once the hold ends.
    func scheduleDesktopRefresh(thenMoveTo place: WidgetPosition? = nil) {
        var place = place
        switch passDesktopHold([], place: place, reload: true) {
        case .held: return
        case .released(let waited): place = place ?? waited.place
        case .open: break
        }
        if let place { placeAfterRefresh = place }
        guard app.defersDesktopUpdates else { return refreshDesktop() }
        guard scheduledRefresh == nil else { return }
        // A timer, not the main queue: the run loop draws the windows before it waits for the timer, while it runs
        // the main queue's work before drawing.
        let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            guard let self, self.scheduledRefresh != nil else { return }
            self.refreshDesktop()
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduledRefresh = timer
    }

    /// Called before a step is planned (the Studio window commits code typed and not saved yet, so the step starts
    /// from what the user sees). nil by default.
    var willApply: (() -> Void)?
    /// While it says so for the Studio's instance, the desktop copy keeps the version it runs — the last working one:
    /// the files have a problem that stops a part from drawing (the code pane's red diagnostics). Steps are still
    /// written; what would reach the desktop copy — a step's patch, a reload — waits, and goes once, at the first step,
    /// undo or reload after which it no longer holds (`passDesktopHold`). nil (the default): never held.
    var holdsDesktop: ((Skin) -> Bool)?

    /// Whether a reload of the desktop copy waits for its turn.
    var hasScheduledDesktopRefresh: Bool { scheduledRefresh != nil }

    /// Takes back the reload of the desktop copy waiting for its turn (the Studio holds the copy now: it would read the
    /// files as they are), as a change that waits: a load, and where its window was to go. nil when no reload waited.
    func takeScheduledDesktopRefresh() -> HeldDesktopChange? {
        guard let timer = scheduledRefresh else { return nil }
        timer.invalidate()
        scheduledRefresh = nil
        defer { placeAfterRefresh = nil }
        return HeldDesktopChange(files: [], place: placeAfterRefresh, reload: true)
    }

    /// Runs a reload of the desktop copy that waits for its turn now.
    func flushDesktopRefresh() {
        guard scheduledRefresh != nil else { return }
        refreshDesktop()
    }

    /// Whether a reload of the desktop copy the session asked for is still on its way — waiting for its turn, or open:
    /// not every copy it touched has reported yet (changes on disk wait for it: they may be what it writes as it loads).
    var isAwaitingOwnReload: Bool { scheduledRefresh != nil || ownReload != nil }

    /// Whether the desktop copy `c` came of a reload the session asked for: its window controller carries the ticket of
    /// the open reload, or of the session's latest one.
    func isOwnReload(_ c: SkinWindowController) -> Bool {
        guard let ticket = c.reloadTicket else { return false }
        return ownReload?.tickets.contains(ticket) == true || ticket == lastTicket
    }

    /// What the widget on the desktop wrote to its files while it was reloaded is its own write, as when it writes them
    /// as it runs: buffers without edits of their own take it (the dates too, for a write of the same bytes), and —
    /// unless `notify` is false — the Studio window hears of it (`desktopWroteFiles`: its instance follows). Returns the
    /// files taken.
    @discardableResult
    func absorbDesktopWrites(notify: Bool = true) -> [URL] {
        let adopted = diskSync.adoptChanges()
        diskSync.restamp()
        if notify, !adopted.isEmpty { client?.session(self, didChange: .desktopWroteFiles(adopted)) }
        return adopted
    }

    /// FSEvents saw files of the widget touched: those that really changed (not the session's own writes) — or were
    /// saved again with the same bytes (an image or a font the widget uses may have changed) — are for the Studio window
    /// to decide about. While a reload the session asked for is open they wait for it to end: what the widget writes as
    /// it reloads is taken then, and only what is left is a change.
    private func filesTouched(_ files: [URL]) {
        if ownReload != nil {
            touchedDuringReload.append(contentsOf: files)
            return
        }
        let changed = diskSync.changedOnDisk(files)
        guard !changed.isEmpty || !diskSync.touchedOnDisk(files, marking: false).isEmpty else { return }
        client?.session(self, didChange: .filesChangedOnDisk(changed))
    }

    /// The files whose bytes on disk differ from what the buffers last saw.
    func filesChangedOnDisk() -> [URL] { diskSync.changedOnDisk() }

    /// The files saved again with the bytes the buffers last saw, or only touched, since last asked.
    func filesTouchedOnDisk() -> [URL] { diskSync.touchedOnDisk() }

    /// Buffers without edits of their own take what changed on disk. Returns the files that changed.
    @discardableResult
    func takeChangesFromDisk() -> [URL] { diskSync.adoptChanges() }

    /// The bytes of a source file as the code pane should see them: the session's text (in its encoding) while it holds
    /// edits not written yet, else what the file holds — a change made elsewhere is not taken here, so the window's
    /// check still sees it and decides about reloading the widget (live reload).
    func data(of url: URL) throws -> Data {
        if let buffer = buffers.buffer(url), buffer.isDirty { return buffer.data }
        return try Data(contentsOf: SourceFileID(url).url)
    }

    /// Whether FSEvents watches the widget's files.
    var isWatchingFiles: Bool { watcher.isWatching }
}

/// A step the color panel grows while the user picks (docs/editor-friendly.md §7.4 "one undo step"): later picks fold
/// into it (`EditingSession.merged`) until it is undone.
final class GrowingStep {
    private(set) var transaction: Transaction
    /// Undone once: a later pick is a step of its own (the redo holds its own copy).
    var isSealed = false

    init(_ transaction: Transaction) { self.transaction = transaction }

    /// Folds a later step in; false when it cannot (sealed, or it does not start from what this one left).
    func merge(_ later: Transaction, in session: EditingSession) -> Bool {
        guard !isSealed, let combined = session.merged(transaction, later) else { return false }
        transaction = combined
        return true
    }
}

// MARK: - What DesktopFollowing.swift uses of the session

extension EditingSession {
    /// How long the desktop copy took to follow the last step (milliseconds; `lastTimings["desktop"]`).
    func noteDesktopTiming(_ milliseconds: Double) { lastTimings["desktop"] = milliseconds }
}
