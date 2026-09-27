import AppKit
import DesksetCore
import os

/// What happened in an editing session, for the Studio window that shows it.
enum SessionChange {
    /// The Studio's instance of the widget was loaded again: after a step, an undo or redo, a change on disk, a refresh
    /// of the widget. Whatever showed the old one follows the new one.
    case reloaded
    /// A step was made: in memory, on disk, on the desktop, on the undo stack.
    case applied(Transaction)
    /// A step was undone (`undo`) or redone.
    case reverted(Transaction, undo: Bool)
    /// Undoing or redoing a step failed (a file changed elsewhere, or could not be written): nothing changed.
    case revertFailed(Transaction, undo: Bool, Error)
    /// Files of the widget changed on disk (another app saved them, or the widget ran `!WriteKeyValue`): what is taken
    /// is the Studio's call (live reload).
    case filesChangedOnDisk([URL])
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
///   on the desktop keeps running in its own window: it shows the previews of a gesture as they happen and reloads when
///   a step is written (`refreshDesktop`), as it did when the Studio edited it directly.
final class EditingSession {
    /// The widget's config, lowercased (the app's key for the session).
    let key: String
    private(set) var config: String
    unowned let app: AppController
    let buffers = SourceBuffers()
    let diskSync: DiskSync
    /// The widget's undo stack (the Studio window uses it as its own: ⌘Z, the toolbar, the toasts).
    let undoStack = EditorUndoManager()
    let host = StudioHost()
    /// The Studio's own instance of the widget (nil while no Studio window shows the widget).
    private(set) var studioSkin: Skin?
    /// The widget's main file, as the desktop runs it.
    private(set) var fileURL: URL?
    /// The widget on the desktop, as the Studio window last linked it (`bind`). A refresh while no window follows the
    /// widget makes a new one: `currentDesktop` finds it.
    weak var desktop: SkinController? {
        didSet { host.desktop = desktop }
    }
    /// The Studio window showing the widget.
    weak var client: EditingSessionClient?
    private let watcher = SourceWatcher()
    private var updates: SkinScheduledWork?
    private var updatesPaused = false
    /// True while the session reloads the widget on the desktop after writing a step (`refreshDesktop`).
    private(set) var isRefreshingDesktop = false
    /// How long the phases of the last step, undo or redo took (milliseconds): `plan`, `apply`, `write`, `studio`
    /// (loading the Studio's instance and the Studio following it), `desktop`, `total`.
    private(set) var lastTimings: [String: Double] = [:]

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
        watcher.stop()
    }

    // MARK: The widget

    /// Links the widget on the desktop (each refresh makes a new one). Returns true when it runs another file than
    /// before (another variant, or the first link).
    @discardableResult
    func bind(desktop c: SkinController) -> Bool {
        desktop = c
        config = c.config
        let url = c.skin.fileURL
        let other = fileURL.map { SourceFileID($0) != SourceFileID(url) } ?? true
        fileURL = url
        followInput(of: c)
        return other
    }

    /// The input the widget on the desktop takes reaches the Studio's instance too (`Skin.inputMirror`): what a click,
    /// a hover or another widget's bang shows there — a page turned, a theme picked — the canvas shows, as it did when
    /// it drew the desktop copy.
    private func followInput(of c: SkinController) {
        let skin: Skin = c.skin
        let mirror: (SkinInput) -> Void = { [weak self, weak skin] input in
            let replay = {
                guard let self, let skin, self.desktop?.skin === skin, let studio = self.studioSkin else { return }
                studio.replay(input)
            }
            if Thread.isMainThread { replay() } else { DispatchQueue.main.async(execute: replay) }
        }
        if skin.executor.isCurrent { skin.inputMirror = mirror } else { skin.async { skin.inputMirror = mirror } }
    }

    /// The widget on the desktop now: the linked one, or — after it was loaded again while no Studio window followed it
    /// (the session outlives the window) — the one the app runs for the widget now, which is linked from then on. nil
    /// when the widget is not loaded (then the linked one, stopped, can still be loaded again: `refreshDesktop`).
    var currentDesktop: SkinController? {
        if let linked = desktop, app.controller(for: linked.config) === linked { return linked }
        guard let now = app.controller(for: desktop?.config ?? config) else { return nil }
        desktop = now
        return now
    }

    /// The widget on the desktop when it runs there now (for steps outside the files: its window's settings).
    var runningDesktop: SkinController? {
        guard let c = currentDesktop, !c.isStopped else { return nil }
        return c
    }

    /// Loads the Studio's own instance again from the text in memory — after buffers without edits of their own took
    /// what changed on disk — and tells the Studio window. The Calc `Counter` goes on from the old instance, which is
    /// closed once the new one had its first update (nothing in between shows nothing); the first instance takes the
    /// counter and the graphs of the widget on the desktop (`Skin.mirrorCounter`, `Skin.takeGraphs`). Keeps the old one
    /// when the widget's file cannot be read.
    @discardableResult
    func reloadStudioSkin(notify: Bool = true) -> Skin? {
        guard let fileURL else { return studioSkin }
        diskSync.adoptChanges()
        // In memory before it loads, so it reads them from there (files it includes that are new come in after).
        _ = try? buffers.load(fileURL)
        for url in studioSkin?.includedFiles ?? [] { _ = try? buffers.load(url) }
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: app.skinsDirectory, system: SystemMonitor.shared,
                        host: host)
        skin.sourceProvider = buffers
        skin.actionPolicy = host.policy
        do {
            try skin.load()
        } catch {
            Log.write("Studio: cannot load \(fileURL.lastPathComponent): \(error)", level: .warning, source: config)
            return studioSkin
        }
        for url in skin.includedFiles { _ = try? buffers.load(url) }
        // The desktop copy registered the widget's fonts already; a new font file is registered here.
        if Fonts.registerFonts(for: skin) { app.fontsChanged() }
        let old = studioSkin
        // Opened: the canvas shows what the widget on the desktop shows — its Calc Counter and its graphs — as it did
        // when it drew that one (a widget on a thread of its own is not read from here).
        var mirrored: Skin?
        if old == nil, let running = runningDesktop?.skin, running.executor.isCurrent,
           SourceFileID(running.fileURL) == SourceFileID(fileURL) {
            mirrored = running
        }
        if let old {
            skin.continueCounter(from: old)
        } else if let mirrored {
            skin.mirrorCounter(of: mirrored)
        }
        skin.update()
        if let mirrored { skin.takeGraphs(from: mirrored) }
        studioSkin = skin
        startUpdates(skin)
        old?.close()
        watcher.watch(skin.sourceFiles)
        if notify { client?.session(self, didChange: .reloaded) }
        return skin
    }

    /// The Studio no longer shows the widget (its window closed, the widget was unloaded): its instance goes, and the
    /// watching of the files. The text in memory and the undo stack stay.
    func closeStudioSkin() {
        updates?.cancel()
        updates = nil
        watcher.stop()
        if let skin = desktop?.skin {
            if skin.executor.isCurrent { skin.inputMirror = nil } else { skin.async { skin.inputMirror = nil } }
        }
        let old = studioSkin
        studioSkin = nil
        old?.close()
    }

    /// Sleep, a locked screen: no updates of the Studio's instance (the app pauses the widgets on the desktop too).
    func setUpdatesPaused(_ paused: Bool) {
        guard paused != updatesPaused else { return }
        updatesPaused = paused
        if paused {
            updates?.cancel()
            updates = nil
        } else if let skin = studioSkin {
            if SkinController.updateInterval(skin.settings.update) != nil { skin.update() }
            startUpdates(skin)
        }
    }

    /// The instance's update clock: the widget's own `Update`, as on the desktop.
    private func startUpdates(_ skin: Skin) {
        updates?.cancel()
        updates = nil
        guard !updatesPaused, let interval = SkinController.updateInterval(skin.settings.update) else { return }
        updates = skin.executor.timer(interval: interval, leeway: SkinController.timerTolerance(interval), repeats: true) {
            [weak self, weak skin] in
            guard let self, let skin, self.studioSkin === skin else { return }
            skin.update()
        }
    }

    // MARK: Steps

    /// Makes a step: plans `ops` on the text in memory (buffers without edits of their own take what changed on disk
    /// first), makes the changes, writes them (for now every step is written: each ends a gesture), loads the Studio's
    /// instance again and — when `verify` finds the change in effect there —
    /// reloads the widget on the desktop and puts the step on the undo stack (unless `registersUndo` is false: the
    /// caller folds it into a step of its own). Returns nil when nothing changes.
    ///
    /// Throws when the step cannot be planned or written — nothing changed then — or when `verify` says the widget does
    /// not show it (`SessionError.notInEffect`): the files are put back and the Studio's instance loaded again.
    @discardableResult
    func apply(_ name: String, _ ops: [EditOp], commands: [TransactionCommand] = [], selectionBefore: [String] = [],
               selectionAfter: [String] = [], registersUndo: Bool = true, verify: ((Skin) -> Bool)? = nil) throws
        -> Transaction? {
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
        let reloaded = studioSkin != nil ? reloadStudioSkin() : nil
        Self.signposter.endInterval("runtime.apply", runtime)
        lap("studio", t0)
        if let verify, let reloaded, !verify(reloaded) {
            try? buffers.apply(changes, reverse: true)
            try? write()
            if studioSkin != nil { reloadStudioSkin() }
            throw SessionError.notInEffect
        }

        t0 = DispatchTime.now().uptimeNanoseconds
        refreshDesktop()
        lap("desktop", t0)
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
    /// (`TransactionCommand`), the Studio's instance and the desktop copy load the files again.
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
        for command in t.commands {
            switch command {
            case .moveWidget(let from, let to):
                let place = undo ? from : to
                runningDesktop?.moveTo(x: place.x, y: place.y)
            }
        }
        var t0 = DispatchTime.now().uptimeNanoseconds
        if studioSkin != nil { reloadStudioSkin() }
        timings["studio"] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        t0 = DispatchTime.now().uptimeNanoseconds
        refreshDesktop()
        timings["desktop"] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
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

    /// Shows option values without writing them, in the Studio's instance and on the desktop (`Skin.preview`).
    func preview(section: String, _ values: [String: String]) {
        studioSkin?.preview(section: section, values)
        desktopSkin { $0.preview(section: section, values) }
    }

    /// Shows `[Variables]` values without writing them (`Skin.previewVariables`).
    func previewVariables(_ values: [String: String]) {
        studioSkin?.previewVariables(values)
        desktopSkin { $0.previewVariables(values) }
    }

    /// Ends every preview, here and on the desktop.
    func endPreview() {
        studioSkin?.endPreview()
        desktopSkin { $0.endPreview() }
    }

    /// Runs `work` on the desktop copy of the widget, where it is owned.
    private func desktopSkin(_ work: @escaping (Skin) -> Void) {
        guard let c = runningDesktop else { return }
        let skin: Skin = c.skin
        if skin.executor.isCurrent { work(skin) } else { skin.async { work(skin) } }
    }

    // MARK: The desktop and the disk

    /// Reloads the widget on the desktop from the files (after a step is written), or loads it again when an earlier
    /// reload could not (the files may be fixed since).
    func refreshDesktop() {
        guard let c = currentDesktop ?? desktop else { return }
        let state = Self.signposter.beginInterval("desktop.refresh")
        defer { Self.signposter.endInterval("desktop.refresh", state) }
        isRefreshingDesktop = true
        defer { isRefreshingDesktop = false }
        if app.controller(for: c.config) === c {
            app.refresh(c)
        } else if app.controller(for: c.config) == nil, c.isStopped {
            app.activate(config: c.config, file: c.file)
        }
    }

    /// FSEvents saw files of the widget touched: those that really changed (not the session's own writes) are for the
    /// Studio window to decide about.
    private func filesTouched(_ files: [URL]) {
        let changed = diskSync.changedOnDisk(files)
        guard !changed.isEmpty else { return }
        client?.session(self, didChange: .filesChangedOnDisk(changed))
    }

    /// The files whose bytes on disk differ from what the buffers last saw.
    func filesChangedOnDisk() -> [URL] { diskSync.changedOnDisk() }

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
