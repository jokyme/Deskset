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
    fileprivate var timer: Timer?
    /// Patches the desktop copy took, and the ones it had to load again for instead (for the self-tests).
    fileprivate(set) var desktopPatches = 0
    fileprivate(set) var desktopPatchesRefused = 0

    deinit { timer?.invalidate() }

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
extension EditingSession {
    /// After a step, an undo or a redo made `changes` (the Studio's instance took them already): the desktop copy
    /// follows — by a patch when the Studio's instance took them as one, else by a reload — and its window moves to
    /// `place` after.
    func followStep(_ changes: [SourceChange], thenMoveTo place: WidgetPosition?) {
        let patched = studioSkin != nil && follow.studioPatched == changes
        follow.studioPatched = nil
        guard patched, !hasScheduledDesktopRefresh else {
            // The reload reads every file: a patch still waiting goes with it, and so does its move unless this step
            // moves the window itself.
            let waiting = follow.take()
            return scheduleDesktopRefresh(thenMoveTo: place ?? waiting?.place)
        }
        follow.add(changes.map(\.file), place: place)
        guard app.defersDesktopUpdates else { return flushDesktopPatch() }
        guard follow.timer == nil else { return }
        // A timer, as for the reload: the run loop draws the windows (the canvas shows the step) before it fires.
        let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in self?.flushDesktopPatch() }
        RunLoop.main.add(timer, forMode: .common)
        follow.timer = timer
    }

    /// Whether a patch of the desktop copy waits for its turn.
    var hasPendingDesktopPatch: Bool { follow.isPending }

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
        c.runtime.send(.patch(snapshot) { [weak self] result, elapsed in
            let done: () -> Void = { self?.desktopTookPatch(result, elapsed: elapsed, place: place, target: target) }
            if Thread.isMainThread { done() } else { DispatchQueue.main.async(execute: done) }
        })
    }

    /// The desktop copy took the patch (`result`), or says it must load again for it.
    private func desktopTookPatch(_ result: SkinPatchResult, elapsed: Double, place: WidgetPosition?,
                                  target: SkinController?) {
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
