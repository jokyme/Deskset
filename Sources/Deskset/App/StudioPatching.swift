import AppKit
import DesksetCore

/// How a step reaches the Studio's instance of a widget (design §9.1 ②): as a patch of the running instance when the
/// change allows it, else by loading it again from the text in memory.
extension EditingSession {
    /// Gives a step, an undo or a redo — `changes`, already made to the text in memory — to the Studio's instance.
    ///
    /// When every change is in a file the instance reads as its source and every option that changed can be read again
    /// (`Skin.patch(sources:)`), the running instance takes the new text: nothing loads, and what it has shown stays —
    /// graph history, the Calc counter, variables set by clicks, hover states. The Studio window hears `patched`.
    /// Otherwise (a layer added, removed or moved, a `Meter=` changed, a `[Rainmeter]` option, another file…) it loads
    /// again (`reloadStudioSkin`), taking the counter and the Line and Histogram graphs of the old instance, and the
    /// window hears `reloaded`.
    ///
    /// Timed in `reloadPhases`: `studio.patch` (also when the patch found it must load again), `studio.reload`, and the
    /// window's parts. Returns the instance that shows the text now (the old one when the widget's file cannot be read).
    @discardableResult
    func applyToStudio(_ changes: [SourceChange]) -> Skin? {
        guard let skin = studioSkin else { return nil }
        reloadPhases.reset()
        // A file the instance reads another way (a script, a data file) is read again only by a load.
        let sources = Set(skin.sourceFiles.map(SourceFileID.init))
        if let other = changes.first(where: { !sources.contains($0.file) }) {
            return reloadStudioSkinKeepingGraphs(because: "\(other.file.url.lastPathComponent) is not a source file")
        }
        let stamps = diskSync.modificationDates()
        let result = reloadPhases.measure("studio.patch") {
            StudioSignposts.interval("studio.patch") { skin.patch(sources: buffers) }
        }
        switch result {
        case .needsReload(let reason):
            return reloadStudioSkinKeepingGraphs(because: reason.description)
        case .applied(let summary):
            // What a changed measure's actions wrote while it updated (they write to a private copy: nothing should).
            takeOwnWrites(since: stamps)
            reloadPhases.measure("window") { client?.session(self, didChange: .patched(summary)) }
            return skin
        }
    }

    /// Loads the Studio's instance again from memory (`reloadStudioSkin`, which continues the Calc counter) with the
    /// Line and Histogram graphs of the old instance, before the Studio window follows it. Timed as `studio.reload`,
    /// next to what was measured before it (the patch that could not be applied).
    private func reloadStudioSkinKeepingGraphs(because reason: String) -> Skin? {
        let tried = reloadPhases.take()
        let old = studioSkin
        let start = DispatchTime.now().uptimeNanoseconds
        let skin = StudioSignposts.interval("studio.reload") { reloadStudioSkin(notify: false) }
        reloadPhases.add(tried)
        // Not loaded (the file cannot be read now): the old instance stays, and nothing changed to tell.
        guard let skin, skin !== old else { return skin }
        if let old { skin.takeGraphs(from: old) }
        reloadPhases.add(["studio.reload": Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6])
        Log.write("Studio: loaded the widget's instance again: \(reason)", level: .debug, source: config)
        reloadPhases.measure("window") { client?.session(self, didChange: .reloaded) }
        return skin
    }
}

extension InspectorWindowController {
    /// The Studio's instance took a step without loading again (`SessionChange.patched`): everything that shows it
    /// follows as after a reload (`studioSkinReloaded`) — the canvas, the layers, the inspector, the live values and the
    /// code, the same parts — except binding the widget, which has not changed; the window's title follows
    /// `[Metadata]`. Each part is timed in the session's phases.
    func studioSkinPatched(_ summary: SkinPatchSummary) {
        guard let c = controller, let skin else { return }
        // A selection to apply comes with steps that add, copy or move layers, which load again; should one come with
        // a patch, the window follows it as after a reload.
        if pendingSelection != nil { return studioSkinReloaded() }
        finishOpening()
        let phases = session?.reloadPhases ?? StudioPhaseClock()
        phases.run(windowPart: ("widget", { [weak self] in
            guard let self else { return }
            let name = Self.skinName(skin, config: c.config)
            self.window?.title = name.isEmpty ? c.config : name
        }))
        // One naming of the layers for every part (the list's names, the identity strip, the live values): the skin does
        // not change while they follow it.
        LayerNaming.sharingWork(for: skin) {
            for part in attachParts(c) where part.label != "widget" { phases.run(windowPart: part) }
        }
    }
}
