import AppKit
import DesksetCore

/// What an editing session keeps to follow steps without loading the widget again (`EditingSession.follow`): the
/// desktop copy's patch waiting for its turn, and how the Studio's instance took the last step.
final class SessionFollowing {
    /// The changes the Studio's instance last took as a patch (`applyToStudio`): the step or undo that made them is
    /// sent to the desktop copy as a patch too (`followStep`).
    var studioPatched: [SourceChange]?
    /// The load of the Studio's instance under way replaces one that could not take a step as a patch: it goes on from
    /// everything the old one showed (`runtimeSeed`), not only its counter.
    var carriesState = false
    /// The files whose new text waits for the desktop copy (`flushDesktopPatch`), in the order the steps changed them,
    /// and where its window goes once it took them.
    fileprivate(set) var pendingFiles: [SourceFileID] = []
    fileprivate(set) var pendingPlace: WidgetPosition?
    fileprivate(set) var isPending = false
    /// Patches sent to the desktop copy whose answer has not come back yet: a copy on the engine thread answers on a
    /// later turn (with the main executor, inside the send).
    fileprivate(set) var patchesInFlight = 0
    fileprivate var timer: Timer?
    /// Patches the desktop copy took, and the ones it had to load again for instead (for the self-tests).
    fileprivate(set) var desktopPatches = 0
    fileprivate(set) var desktopPatchesRefused = 0
    /// What waits while the Studio holds the desktop copy on its last working version (`EditingSession.holdsDesktop`):
    /// the files the steps changed since the copy last followed, where its window goes, and whether the copy must load
    /// again (a step the Studio's instance could not take as a patch, a reload asked for). Sent once, when the hold ends.
    fileprivate(set) var held: HeldDesktopChange?

    deinit { timer?.invalidate() }

    fileprivate func hold(_ files: [SourceFileID], place: WidgetPosition?, reload: Bool) {
        var now = held ?? HeldDesktopChange()
        for file in files where !now.files.contains(file) { now.files.append(file) }
        if let place { now.place = place }
        if reload { now.reload = true }
        held = now
    }

    fileprivate func release() -> HeldDesktopChange? {
        defer { held = nil }
        return held
    }

    fileprivate func add(_ files: [SourceFileID], place: WidgetPosition?) {
        for file in files where !pendingFiles.contains(file) { pendingFiles.append(file) }
        if let place { pendingPlace = place }
        isPending = true
    }

    fileprivate func take() -> (files: [SourceFileID], place: WidgetPosition?)? {
        timer?.invalidate()
        timer = nil
        guard isPending else { return nil }
        defer {
            pendingFiles = []
            pendingPlace = nil
            isPending = false
        }
        return (pendingFiles, pendingPlace)
    }
}

/// The change the desktop copy did not take while the Studio held it (`SessionFollowing.held`).
struct HeldDesktopChange {
    var files: [SourceFileID] = []
    var place: WidgetPosition?
    var reload = false
}

/// The text of a few files as a step left them, for a widget that reads them on another thread (the desktop copy's
/// patch): a value, taken on the main thread from the session's buffers. Other files are read from the disk.
final class SourceSnapshot: SourceProvider {
    private let texts: [SourceFileID: String]

    init(_ texts: [SourceFileID: String]) { self.texts = texts }

    func sourceText(for url: URL) -> String? { texts[SourceFileID(url)] }
}

/// How a step reaches the widget on the desktop (design §9.1 "DesktopSync"): as a patch of the running copy when the
/// Studio's instance took it as one, else by loading the copy again from the files (`scheduleDesktopRefresh`).
///
/// A patch keeps what the desktop copy has shown — its graphs, its counter, variables set by clicks — where a reload
/// starts them again. It waits for the next turn of the run loop, as the reload does (the canvas draws the step first),
/// and the steps and undos made before that turn go as one. The desktop copy plans it against its own text, from the
/// files the steps changed as they are then, on its own executor: the patch is a message to its runtime
/// (`SkinMessage.patch`), whose answer comes back to the main thread; a copy that must load again for it (another
/// variant, or a change it cannot take) is loaded again. A reload waiting for its turn wins: it reads every
/// file. A step that moves the widget's window moves it once the copy took the patch.
///
/// Before either goes, the Studio's rule decides (`passDesktopHold`): while the widget has a new red problem the
/// desktop copy keeps its last working version, and what would reach it waits, to go once the problem is fixed.
extension EditingSession {
    /// After a step, an undo or a redo made `changes` (the Studio's instance took them already): the desktop copy
    /// follows — by a patch when the Studio's instance took them as one, else by a reload — and its window moves to
    /// `place` after.
    func followStep(_ changes: [SourceChange], thenMoveTo place: WidgetPosition?) {
        var patched = studioSkin != nil && follow.studioPatched == changes
        follow.studioPatched = nil
        var files = changes.map(\.file)
        var place = place
        switch passDesktopHold(files, place: place, reload: !patched) {
        case .held:
            return
        case .released(let waited):
            // The hold ended with this step: what waited goes with it, once — as a patch unless something that waited
            // needs a load (the copy plans the patch against its own text, which is still the last working version).
            files = waited.files + files
            place = place ?? waited.place
            if waited.reload { patched = false }
        case .open:
            break
        }
        guard patched, !hasScheduledDesktopRefresh else {
            // The reload reads every file: a patch still waiting goes with it, and so does its move unless this step
            // moves the window itself.
            let waiting = follow.take()
            return scheduleDesktopRefresh(thenMoveTo: place ?? waiting?.place)
        }
        follow.add(files, place: place)
        guard app.defersDesktopUpdates else { return flushDesktopPatch() }
        guard follow.timer == nil else { return }
        // A timer, as for the reload: the run loop draws the windows (the canvas shows the step) before it fires.
        let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in self?.flushDesktopPatch() }
        RunLoop.main.add(timer, forMode: .common)
        follow.timer = timer
    }

    /// Whether a patch of the desktop copy waits for its turn.
    var hasPendingDesktopPatch: Bool { follow.isPending }

    // MARK: The hold (the desktop keeps the last working version)

    /// What the Studio's rule (`holdsDesktop`) decided for a change on its way to the desktop copy.
    enum DesktopHoldDecision {
        /// Nothing is held: the change goes.
        case open
        /// The change waits with what waited before it (`SessionFollowing.held`).
        case held
        /// The hold ended: the change goes, with what waited (once).
        case released(HeldDesktopChange)
    }

    /// Asked before a step's patch or a reload goes to the desktop copy (`followStep`, `scheduleDesktopRefresh`): while
    /// the Studio's instance has a red problem the desktop's version does not have (`holdsDesktop`, the code pane's
    /// rule), the change waits — the files it changed (`files`), where the window goes (`place`), whether the copy must
    /// load again for it (`reload`) — and so does what was waiting for its turn (a patch or a reload that would read the
    /// files as they are now). Half-typed code never reaches the desktop. Once the rule lets it pass, what waited goes
    /// with the change that passed.
    func passDesktopHold(_ files: [SourceFileID], place: WidgetPosition?, reload: Bool) -> DesktopHoldDecision {
        guard let holds = holdsDesktop, let skin = studioSkin, holds(skin) else {
            return follow.release().map { .released($0) } ?? .open
        }
        if let pending = follow.take() { follow.hold(pending.files, place: pending.place, reload: false) }
        if let scheduled = takeScheduledDesktopRefresh() {
            follow.hold(scheduled.files, place: scheduled.place, reload: true)
        }
        follow.hold(files, place: place, reload: reload)
        return .held
    }

    /// A change waits for the desktop copy because the Studio holds it on its last working version.
    var isHoldingDesktop: Bool { follow.held != nil }

    /// The window that held the desktop copy lets go (it closes, or shows another widget): the desktop keeps the last
    /// working version it runs (the files still have the problem), nothing waits for it any more, and a move that
    /// waited is made now. The next change that reaches the copy reads every file (a patch reads the files it was not
    /// given from the disk; a reload reads them all).
    func endHold() {
        guard let waited = follow.release(), let place = waited.place else { return }
        runningDesktop?.moveTo(x: place.x, y: place.y)
    }

    /// Whether a patch was sent to the desktop copy and its answer has not come back yet (it may still say the copy must
    /// load again).
    var isDesktopPatchInFlight: Bool { follow.patchesInFlight > 0 }

    /// Patches the desktop copy has taken, and the ones it loaded again for instead.
    var desktopPatchCounts: (applied: Int, refused: Int) { (follow.desktopPatches, follow.desktopPatchesRefused) }

    /// Sends the patch waiting for the desktop copy now: the text the steps left in the files they changed. When the copy
    /// cannot take it — it is not running, it runs another variant, or the change needs a load — it is loaded again
    /// instead (`scheduleDesktopRefresh`).
    func flushDesktopPatch() {
        guard let pending = follow.take() else { return }
        if hasScheduledDesktopRefresh { return scheduleDesktopRefresh(thenMoveTo: pending.place) }
        guard let c = runningDesktop, let fileURL, SourceFileID(c.fileURL) == SourceFileID(fileURL) else {
            return scheduleDesktopRefresh(thenMoveTo: pending.place)
        }
        var texts: [SourceFileID: String] = [:]
        for file in pending.files { texts[file] = buffers.buffer(file.url)?.text }
        let snapshot = SourceSnapshot(texts)
        let place = pending.place
        // The window that moves after the patch: this copy's (a copy that replaced it meanwhile loaded the files).
        weak var target = c
        // Inline with the main executor (the answer too); a copy on the engine thread answers on a later turn.
        follow.patchesInFlight += 1
        c.runtime.send(.patch(snapshot) { [weak self] result, elapsed in
            let done: () -> Void = { self?.desktopTookPatch(result, elapsed: elapsed, place: place, target: target) }
            if Thread.isMainThread { done() } else { DispatchQueue.main.async(execute: done) }
        })
    }

    /// The desktop copy took the patch (`result`), or says it must load again for it.
    private func desktopTookPatch(_ result: SkinPatchResult, elapsed: Double, place: WidgetPosition?,
                                  target: SkinController?) {
        follow.patchesInFlight -= 1
        noteDesktopTiming(elapsed)
        switch result {
        case .needsReload(let reason):
            follow.desktopPatchesRefused += 1
            Log.write("Studio: loading the widget on the desktop again: \(reason)", level: .debug, source: config)
            scheduleDesktopRefresh(thenMoveTo: place)
        case .applied:
            follow.desktopPatches += 1
            guard let place, let c = runningDesktop, c === target else { return }
            c.moveTo(x: place.x, y: place.y)
        }
    }
}
