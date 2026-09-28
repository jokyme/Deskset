import AppKit
import DesksetCore

/// What the Studio's instance of a widget reads as its source (`Skin.sourceProvider`, `Skin.patch(sources:)`): the text in
/// memory (`SourceBuffers`), except for files the code pane holds typed code for that is not written yet — the instance
/// shows that as soon as typing pauses (design §9.5: code to canvas after a 150 ms pause), before it is written as a
/// step. Nothing else reads it: steps are planned on the buffers, the desktop copy and the disk get only what is written.
final class StudioSources: SourceProvider {
    let buffers: SourceBuffers
    /// Typed code by file, while it differs from the text in memory.
    private(set) var typed: [SourceFileID: String] = [:]
    /// Why the Studio's instance does not show the typed code yet (nil: it shows it, or there is none): it could only
    /// show it by loading again (a layer typed, a `Meter=` changed), which waits for the code to be committed — one load
    /// then, not one at every pause in the typing (`EditingSession.showTypedCode`).
    var waiting: String? {
        didSet { if waiting == nil || oldValue == nil { waitingDismissed = false } }
    }
    /// The capsule that says so was closed (×): it stays closed until the typed code shows or waits anew.
    var waitingDismissed = false

    init(buffers: SourceBuffers) { self.buffers = buffers }

    func sourceText(for url: URL) -> String? {
        if !typed.isEmpty, let text = typed[SourceFileID(url)] { return text }
        return buffers.sourceText(for: url)
    }

    /// The text the instance reads for `file` (nil: the disk's).
    func text(of file: SourceFileID) -> String? { typed[file] ?? buffers.sourceText(for: file.url) }

    /// Typed code for `file` (nil, or the text in memory: none).
    func setTyped(_ text: String?, for file: SourceFileID) {
        let held = buffers.sourceText(for: file.url)
        guard let text, !(held.map { ($0 as NSString).isEqual(to: text) } ?? false) else {
            typed[file] = nil
            if typed.isEmpty { waiting = nil }
            return
        }
        typed[file] = text
    }

    /// A step wrote these files: their typed code, if any, is in the text in memory now (the code pane commits typed
    /// code before any other step), or is gone.
    func forget(_ files: [SourceFileID]) {
        guard !typed.isEmpty else { return }
        for file in files { typed[file] = nil }
        if typed.isEmpty { waiting = nil }
    }
}

extension EditingSession {
    /// Shows code typed in the Studio's code pane on the Studio's instance only, without writing it or making a step
    /// (the pane commits it later: ⌘S, focus leaving it, a longer pause — one "Edit Code" step, which then finds nothing
    /// more to show). `text` nil: the file holds no typed code any more (committed, discarded, typed back). The instance
    /// takes it as a patch when it can, and the Studio window follows as after a step (`patched` with no edits of the
    /// files' text: the code pane holds it already). Typed code the instance could show only by loading again (a layer
    /// typed, half a section, a `Meter=` changed, a `[Rainmeter]` option) is not shown at the pause: the instance keeps
    /// the last code it could take and says why it waits (`StudioSources.waiting`) — the commit loads it once, where a
    /// load at every pause in the typing would cost a load of the widget and a new inspector each time.
    ///
    /// Timed in `reloadPhases` like a step (`studio.patch`, the window's parts). Returns whether the instance changed.
    @discardableResult
    func showTypedCode(_ text: String?, in url: URL) -> Bool {
        let file = SourceFileID(url)
        let before = studioSources.text(of: file)
        studioSources.setTyped(text, for: file)
        guard let skin = studioSkin, studioSources.text(of: file) != before,
              skin.sourceFiles.contains(where: { SourceFileID($0) == file }) else { return false }
        reloadPhases.reset()
        follow.studioPatched = nil
        let stamps = diskSync.modificationDates()
        let result = reloadPhases.measure("studio.patch") {
            StudioSignposts.interval("studio.patch") { skin.patch(sources: studioSources) }
        }
        switch result {
        case .needsReload(let reason):
            studioSources.waiting = reason.description
            return false
        case .applied(let summary):
            studioSources.waiting = nil
            takeOwnWrites(since: stamps)
            reloadPhases.measure("window") { client?.session(self, didChange: .patched(summary, .none)) }
            return true
        }
    }
}

extension InspectorWindowController {
    /// Typing in the code pane paused (`CodeEditorView.onTypedText`): the canvas, the layers and the inspector show the
    /// typed code (`EditingSession.showTypedCode`), which is written when the pane commits it — or, when showing it
    /// takes loading the widget again, the capsule over the canvas says it shows once saved.
    func showTypedCode(_ text: String?, in url: URL) {
        guard let session, !committingCode else { return }
        session.showTypedCode(text, in: CodeDocument.writeTarget(for: url))
        updateSilentData()
    }

    /// Why the canvas does not show the code typed so far (nil: it does): see `StudioSources.waiting`.
    var typedCodeWaits: String? { session?.studioSources.waiting }

    static let typedCodeWaitsText = "The canvas shows this code once it's saved."
}
