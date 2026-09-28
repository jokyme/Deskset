import AppKit
import DesksetCore

/// Revert to Original on the widget page's footer: a built-in widget whose own files differ from the copy the app ships
/// shows the row, with how many places it would put back ("1 change"); one click is one named step ("Revert to
/// Original", undone like any other), and the confirmation says so at the top of the page. The suite's shared files
/// are not touched (every widget of the suite reads them).
extension StudioWidgetPage {
    /// The widget's own files that differ from their shipped originals (none for a widget the app does not ship).
    func originalChanges() -> [OriginalCopy.Change] {
        guard let session, let studio = session.studioSkin, let originals = app.defaultSkinsSource,
              studio.rootConfig.caseInsensitiveCompare(StudioBuiltInWords.suite) == .orderedSame else { return [] }
        let files = [studio.fileURL] + studio.includedFiles
        let texts = files.map { url in session.buffers.buffer(url)?.text }
        let key = zip(files, texts).map { "\($0.path)#\($1?.hashValue ?? 0)" }.joined(separator: "|")
        if let cached = originalCache, cached.key == key { return cached.changes }
        let changes = OriginalCopy.changes(files: files, widgetFolder: studio.fileURL.deletingLastPathComponent(),
                                           skinsDirectory: studio.skinsDirectory, originals: originals) { url in
            session.buffers.buffer(url)?.text ?? (try? String(contentsOf: url, encoding: .utf8))
        }
        originalCache = (key, changes)
        return changes
    }

    /// The footer's row, while there is something to put back.
    func revertLink() -> StudioPage.Link? {
        let places = originalChanges().reduce(0) { $0 + $1.places }
        guard places > 0 else { return nil }
        return StudioPage.Link(id: "revert", title: StudioText[.revertToOriginal],
                               detail: places == 1 ? StudioText[.revertOne] : StudioText.format(.revertMany, places),
                               symbol: "arrow.uturn.backward")
    }

    /// Puts the widget's own files back as they were shipped: one step.
    func revertToOriginal() {
        let changes = originalChanges()
        guard let session, !changes.isEmpty else { return }
        let name = StudioText[.revertToOriginal]
        window.pendingAnnouncement = StudioText[.confirmReverted]
        defer { window.pendingAnnouncement = nil }
        do {
            guard try session.apply(name, changes.map { .editSource(file: $0.file, text: $0.originalText, encoding: nil) })
                != nil else { return }
        } catch {
            Log.write("Studio: \(name) was not made: \(error)", level: .warning, source: session.config)
            if app.presentsWindows { NSSound.beep() }
            return
        }
        originalCache = nil
        rebuild()
        showTop(.init(text: StudioText[.confirmReverted], undo: StudioText[.confirmUndo]))
    }
}
