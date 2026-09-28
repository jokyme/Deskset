import AppKit
import DesksetCore

/// Changes of the widget's parts made from the Layers list, the canvas's menu and its accessibility actions, each one
/// named step through the editing session: the drawing order (a drag in Layers, Bring Forward, Send Backward), hiding
/// and showing, adding and deleting. Locking is the Studio's own state (it keeps a part from being dragged), never
/// written to the widget's files.
extension StudioWindowController {
    // MARK: Order

    /// Moves `names` right before `before` in their file (nil: after the last part, to the front), keeping every part
    /// where it is on the canvas (a part placed relative to the one before it gets its position written as numbers in
    /// the same step). One step, "Change Order" (or `step`). False when nothing moves or the parts are in different
    /// files.
    @discardableResult
    func moveParts(_ names: [String], before: String?, step: String = StudioText[.stepOrder]) -> Bool {
        guard let skin else { return false }
        let moving = Set(names.map { $0.lowercased() })
        let ordered = skin.meters.map(\.name).filter { moving.contains($0.lowercased()) }
        guard !ordered.isEmpty else { return false }
        let file = skin.sources.location(section: ordered[0])?.file ?? skin.fileURL
        let files = (ordered + (before.map { [$0] } ?? [])).map { skin.sources.location(section: $0)?.file ?? skin.fileURL }
        guard files.allSatisfy({ $0 == file }) else {
            if app.presentsWindows { NSSound.beep() }
            announce(StudioText[.layerDifferentFiles])
            return false
        }
        let old = skin.meters.map { $0.name.lowercased() }
        let new = LayerReorder.order(of: skin.meters.map(\.name), moving: ordered, before: before).map { $0.lowercased() }
        guard new != old else { return false }
        let fixes = LayerReorder.fixups(skin: skin, moving: ordered, to: before)
        let ops = fixes.map { skin.op(settingOwnOption: $0.key, of: $0.section, to: $0.value) }
            + ordered.compactMap { skin.op(movingSection: $0, before: before) }
        let selection = canvasController.canvas.selectedNames
        let title = names.count == 1 ? (skin.meter(named: ordered[0]).map { partTitle($0) } ?? ordered[0])
            : StudioWords.parts(names.count)
        pendingAnnouncement = StudioText.format(.confirmMoved, title)
        guard partPage.apply(step, ops) else { return false }
        if !selection.isEmpty { canvasController.canvas.setSelection(names: selection) }
        refreshLayers()
        return true
    }

    /// Bring Forward: the part one place further to the front (after the next part in the file).
    @discardableResult
    func bringForward(_ name: String) -> Bool {
        guard let skin, let i = skin.meters.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              i + 1 < skin.meters.count else { return false }
        let before = i + 2 < skin.meters.count ? skin.meters[i + 2].name : nil
        return moveParts([skin.meters[i].name], before: before, step: StudioText[.stepForward])
    }

    /// Send Backward: the part one place further back (before the previous part in the file).
    @discardableResult
    func sendBackward(_ name: String) -> Bool {
        guard let skin, let i = skin.meters.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              i > 0 else { return false }
        return moveParts([skin.meters[i].name], before: skin.meters[i - 1].name, step: StudioText[.stepBackward])
    }

    // MARK: Hidden

    /// Shows a hidden part: its own `Hidden=1` goes (the file as it was before it was hidden here), else `Hidden=0` in
    /// its own section (a style hid it). One step, "Show".
    @discardableResult
    func show(part name: String) -> Bool {
        guard let skin, let m = skin.meter(named: name), m.hidden else { return false }
        let title = partTitle(m)
        var ops: [EditOp] = []
        if case .own? = m.fileOrigin("Hidden"), let own = m.fileOption("Hidden"),
           Double(own.trimmingCharacters(in: .whitespaces)) != nil, skin.localTarget(section: m.name, key: "Hidden") != nil,
           let remove = skin.op(removingOwnOption: "Hidden", of: m.name) {
            ops = [remove]
        } else {
            ops = WriteScopes.ops(.element, meter: m.name, key: "Hidden", value: "0", in: skin)
        }
        guard !ops.isEmpty else {
            partPage.sharedPartRefused(m)
            return false
        }
        let step = StudioText[.stepShow]
        pendingAnnouncement = StudioText.format(.confirmShown, title)
        guard partPage.apply(step, ops) else { return false }
        refreshLayers()
        return true
    }

    /// The eye in Layers: hides a shown part, shows a hidden one.
    func toggleHidden(_ name: String) {
        guard let m = skin?.meter(named: name) else { return }
        if m.hidden { show(part: name) } else { hide(part: name) }
    }

    // MARK: Locks

    /// The parts locked in this widget (lowercased names): kept in the Studio's settings, not in the widget's files.
    var lockedParts: Set<String> {
        guard let config = session?.config else { return [] }
        return app.state.editor.editorLocks[config.lowercased()] ?? []
    }

    func toggleLock(_ name: String) {
        guard let config = session?.config else { return }
        let key = config.lowercased(), part = name.lowercased()
        app.state.updateEditor { e in
            var set = e.editorLocks[key] ?? []
            if set.contains(part) { set.remove(part) } else { set.insert(part) }
            e.editorLocks[key] = set.isEmpty ? nil : set
        }
        refreshLayers()
    }

    // MARK: Delete

    /// Deletes a part: every block of its section in the widget's own files. One step, "Delete". A part a file other
    /// widgets read defines is theirs too, and is not deleted here.
    @discardableResult
    func delete(part name: String) -> Bool {
        guard let skin, let m = skin.meter(named: name) else { return false }
        if let file = skin.sources.location(section: m.name)?.file, !skin.isOwnFile(file) {
            if app.presentsWindows { NSSound.beep() }
            return false
        }
        let title = partTitle(m)
        let step = StudioText[.stepDelete]
        canvasController.canvas.setSelection(nil)
        pendingAnnouncement = StudioText.format(.confirmDeleted, title)
        guard partPage.apply(step, [skin.op(removingSection: m.name)]) else { return false }
        partPage.show(part: nil)
        partPage.reset()
        widgetPage.refresh()
        refreshLayers()
        partPage.confirm(StudioText.format(.confirmDeleted, title), step: step, item: "", section: "",
                         change: .invisible, fromCanvas: true)
        if let c = partPage.topConfirmation { widgetPage.showTop(c) }
        return true
    }

    // MARK: Insert

    /// Adds `sections` (a part and the data it needs) as one step "Add <title>": written after the selected part (after
    /// the parts that are placed relative to it), else at the end of the widget's file; the new part is selected.
    @discardableResult
    func insert(_ sections: [EditorComponents.Section], title: String) -> Bool {
        guard let skin, !sections.isEmpty else { return false }
        var ops: [EditOp] = [skin.op(appending: sections)]
        if let anchor = canvasController.canvas.selectedNames.last,
           let next = Self.insertionPoint(after: anchor, in: skin) {
            for s in sections { ops.append(.moveSection(s.name, before: next, file: skin.fileURL)) }
        }
        let meters = sections.filter { $0.options.contains { $0.key == "Meter" } }.map(\.name)
        let step = StudioText.format(.stepAdd, title)
        pendingAnnouncement = StudioText.format(.confirmAdded, title)
        guard partPage.apply(step, ops) else { return false }
        refreshLayers()
        if let first = meters.first, self.skin?.meter(named: first) != nil {
            select(part: first)
        }
        return true
    }

    /// The section new parts added after `anchor` are written before (nil: the end of the widget's file): past the
    /// parts that follow `anchor` each placed relative to the one before it (`10R`), so none of them moves. nil also
    /// when `anchor` or the end of that run is in another file.
    static func insertionPoint(after anchor: String, in skin: Skin) -> String? {
        let meters = skin.meters
        guard var last = meters.firstIndex(where: { $0.name.caseInsensitiveCompare(anchor) == .orderedSame }) else {
            return nil
        }
        for i in meters.indices.dropFirst(last + 1) where meters[i].container == nil {
            let relative = [meters[i].rawOption("X"), meters[i].rawOption("Y")].contains { value in
                guard let c = value?.trimmingCharacters(in: .whitespaces).last else { return false }
                return c == "r" || c == "R"
            }
            guard relative else { break }
            last = i
        }
        return section(after: meters[last].name, in: skin)
    }

    /// The section whose header comes right after `name`'s in the widget's own file.
    static func section(after name: String, in skin: Skin) -> String? {
        let main = skin.fileURL.standardizedFileURL.path
        guard let own = skin.sources.location(section: name), own.file.standardizedFileURL.path == main else { return nil }
        return skin.sources.sections
            .filter { $0.value.file.standardizedFileURL.path == main && $0.value.line > own.line }
            .min { $0.value.line < $1.value.line }
            .map { skin.document.section(named: $0.key)?.name ?? $0.key }
    }

    /// Where a new part goes when nothing says: under the selected part, else under everything the widget shows.
    func freeSpot() -> (x: Double, y: Double) {
        guard let skin else { return (0, 0) }
        if let name = canvasController.canvas.selectedNames.last, let m = skin.meter(named: name) {
            return (m.frame.x.rounded(), (m.frame.maxY + 8).rounded())
        }
        let visible = skin.meters.filter { !$0.hidden && $0.container == nil && !$0.isContainer }
        guard !visible.isEmpty else { return (0, 0) }
        let b = skin.contentBounds()
        return (max(b.x, 0).rounded(), max(b.maxY + 8, 0).rounded())
    }

    // MARK: Names

    func partTitle(_ m: Meter) -> String {
        guard let skin else { return m.name }
        return StudioPartNames.title(m, in: skin)
    }
}
