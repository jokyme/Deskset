import AppKit
import DesksetCore

/// Everything that changes the skin: field and menu edits, colors, canvas geometry, alignment, adding,
/// duplicating and deleting layers, and the undo pipeline they share.
extension InspectorWindowController {
    // MARK: Inspector actions

    @objc func fieldCommitted(_ sender: NSTextField) {
        // Editing that ends because the inspector is rebuilt writes nothing (the text goes on in the rebuilt field).
        guard !inspectorState.isRebuilding, let edit = fieldEdits[ObjectIdentifier(sender)] else { return }
        let old = edit.own ? rawGeometryValue(edit.key) : rows.first { $0.key == edit.key }?.raw
        guard sender.stringValue != (old ?? "") else { return }
        commit([Edit(section: edit.section, key: edit.key, value: sender.stringValue, own: edit.own)], name: "Edit \(edit.key)")
    }

    func rawGeometryValue(_ key: String) -> String? {
        guard let name = selectedMeterName, let m = skin?.meter(named: name) else { return nil }
        return m.rawOption(key)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField,
           let edit = fieldEdits[ObjectIdentifier(field)] {
            field.stringValue = (edit.own ? rawGeometryValue(edit.key) : rows.first { $0.key == edit.key }?.raw) ?? ""
            window?.makeFirstResponder(canvas)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), control === addKeyField || control === addValueField {
            addOption()
            return true
        }
        return false
    }

    @objc func addOption() {
        guard let keyField = addKeyField, let valueField = addValueField else { return }
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            window?.makeFirstResponder(keyField)
            return
        }
        write(key: key, value: valueField.stringValue)
    }

    /// Writes `key=value` to the file that defines it and refreshes the skin (one undo step).
    func write(key: String, value: String) {
        guard let section = selectedSection else { return }
        let sectionName = selectedKind == .variables ? "Variables" : section
        commit([Edit(section: sectionName, key: key, value: value, own: false)], name: "Edit \(key)")
    }

    @objc func dataClicked(_ sender: NSButton) { select(section: sender.title) }

    @objc func sourceClicked(_ sender: NSClickGestureRecognizer) {
        guard let key = sender.view?.identifier?.rawValue, let r = rows.first(where: { $0.key == key }),
              let l = r.location else { return }
        showCode(file: l.file, line: l.line)
    }

    // MARK: Colors

    @objc func swatchClicked(_ sender: SwatchButton) {
        guard let info = swatchEdits[ObjectIdentifier(sender)] else { return }
        beginColorEdit(section: info.section, key: info.key, raw: info.raw, variable: info.variable)
        InspectorColorPanel.shared.open(for: self, color: sender.color?.nsColor ?? .white)
    }

    /// Starts picking a color for `key` of the selected section (also used by the self-tests).
    func beginColorEdit(key: String, raw: String, variable: String?, current: RGBA?) {
        beginColorEdit(section: selectedKind == .variables ? "Variables" : (selectedSection ?? ""), key: key, raw: raw,
                       variable: variable)
    }

    func beginColorEdit(section: String, key: String, raw: String, variable: String?) {
        commitPendingColor()
        colorTarget = (section, key, raw, variable)
    }

    @objc func colorPicked(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        pickColor(RGBA(r: Double(c.redComponent) * 255, g: Double(c.greenComponent) * 255,
                       b: Double(c.blueComponent) * 255, a: Double(c.alphaComponent) * 255))
    }

    /// Previews a picked color and schedules the write (self-tests call it directly).
    func pickColor(_ rgba: RGBA) {
        guard let target = colorTarget, let skin else { return }
        if let variable = target.variable {
            let like = skin.document.section(named: "Variables")?.value(forKey: variable)
            let text = ColorText.format(rgba, like: like)
            colorValue = text
            skin.previewVariables([variable: text])
        } else {
            let text = ColorText.format(rgba, like: skin.resolve(target.raw, in: nil, sectionVariables: false))
            colorValue = text
            if target.section == "Variables" {
                skin.previewVariables([target.key: text])
            } else {
                skin.preview(section: target.section, [target.key: text])
            }
        }
        canvas.needsDisplay = true
        colorTimer?.invalidate()
        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.commitPendingColor()
        }
    }

    @objc func colorPanelClosed() { commitPendingColor() }

    /// Writes a picked color now.
    func commitPendingColor() {
        colorTimer?.invalidate()
        colorTimer = nil
        guard let target = colorTarget, let value = colorValue else { return }
        colorValue = nil
        if let variable = target.variable {
            commit([Edit(section: "Variables", key: variable, value: value, own: false)], name: "Change Color")
        } else {
            commit([Edit(section: target.section, key: target.key, value: value, own: false)], name: "Change Color")
        }
    }

    // MARK: Geometry (canvas)

    func beginGeometry(meters names: [String], gesture: SkinCanvasView.Gesture) {
        commitPendingNudge()
        guard let skin else { return }
        let wanted = Set(names.map { $0.lowercased() })
        geometryBases = skin.meters.filter { wanted.contains($0.name.lowercased()) }.map {
            GeometryBase(meter: $0.name, raw: $0.rawGeometry, frame: $0.frame, content: $0.contentSize)
        }
        geometryValues = [:]
        let meters = geometryBases.map(\.meter)
        let resize: Bool = { if case .resize = gesture { return true } else { return false } }()
        gestureName = (resize ? "Resize " : "Move ") + layersLabel(meters)
        gestureMessage = (resize ? "Resized " : "Moved ") + layersLabel(meters, title: false)
        // Layers placed relative to the moving ones move with them: outlined while they do (§9.5).
        canvas.followers = SkinCanvasView.followers(of: geometryBases.map(\.meter), in: skin)
        // The cut-off chip steps aside while the gesture lasts (what it says may stop being true).
        updateWidgetChip()
    }

    /// Layers as undo names (`title`: "16 Bars", "3 Texts") and toasts ("16 bars", "3 texts") call them: one by its
    /// name ("“Audio”"), a run by its name (`LayerNaming`), others by their number and kind ("2 layers" when mixed).
    /// The canvas, the layer list, the identity strip and the menus all use this one.
    func layersLabel(_ names: [String], title: Bool = true) -> String {
        if names.count == 1 { return displayName(ofSection: names[0]) }
        let wanted = Set(names.map { $0.lowercased() })
        let catalog = sidebar.catalog ?? skin.map { LayerNaming.catalog(of: $0) }
        if let run = catalog?.series.first(where: { $0.kind == .layers && Set($0.members.map { $0.lowercased() }) == wanted }),
           let name = catalog?.name(of: run)?.title {
            return title ? Self.titleCase(name) : name
        }
        if let g = canvas.group(of: names.first ?? ""), Set(g.map { $0.lowercased() }) == wanted {
            let name = canvas.groupName(g)
            return title ? Self.titleCase(name) : name
        }
        guard let skin else { return "\(names.count) \(title ? "Layers" : "layers")" }
        let counted = countedLayers(names, in: skin)
        return title ? Self.titleCase(counted) : counted
    }

    /// Turns the frames the user wants into X / Y / W / H values written the way the skin wrote them, and previews
    /// them. Meters are handled in skin order and each is corrected against where it actually lands, so a meter
    /// placed relative to another moved one (`0R`) is not moved twice, and an anchor offset (StringAlign=Right) is
    /// compensated.
    func previewGeometry(_ targets: [String: SkinRect]) {
        guard let skin else { return }
        for base in geometryBases {
            guard let target = targets[base.meter], let m = skin.meter(named: base.meter) else { continue }
            let f = base.frame
            let dw = target.width - f.width, dh = target.height - f.height
            let previous = geometryValues[base.meter] ?? [:]
            func values(_ dx: Double, _ dy: Double) -> [String: String] {
                var v: [String: String] = [:]
                func set(_ key: String, _ raw: String?, _ delta: Double, fallback: Double?) {
                    if delta != 0 {
                        if let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                            v[key] = GeometryEdit.offset(raw, by: delta)
                        } else if let fallback {
                            v[key] = GeometryEdit.format(fallback + delta)
                        } else {
                            v[key] = GeometryEdit.offset(raw, by: delta)
                        }
                    } else if previous[key] != nil {
                        v[key] = raw ?? ""
                    }
                }
                set("W", base.raw.w, dw, fallback: base.content.width)
                set("H", base.raw.h, dh, fallback: base.content.height)
                set("X", base.raw.x, dx, fallback: nil)
                set("Y", base.raw.y, dy, fallback: nil)
                return v
            }
            // First pass with the plain offset from the current values, then correct by the remaining error.
            var dx = target.x - f.x, dy = target.y - f.y
            var v = values(dx, dy)
            skin.preview(section: base.meter, v)
            let ex = target.x - m.frame.x, ey = target.y - m.frame.y
            if abs(ex) >= 0.5 || abs(ey) >= 0.5 {
                dx += ex
                dy += ey
                let first = v
                v = values(dx, dy)
                // A value the first pass previewed and the corrected one leaves as written goes back to what is
                // written (a layer placed after a moved one already moves with it: `#BarGap#R` stays).
                var shown = v
                let written: [String: String?] = ["X": base.raw.x, "Y": base.raw.y, "W": base.raw.w, "H": base.raw.h]
                for key in first.keys where v[key] == nil { shown[key] = (written[key] ?? nil) ?? "" }
                skin.preview(section: base.meter, shown)
            }
            geometryValues[base.meter] = v
        }
        canvas.needsDisplay = true
    }

    /// Ends a gesture, nudge, alignment or fit: writes what it previewed (`keep`) as one undo step named
    /// `gestureName`, with `message` as its toast (nil: said from the undo name; a widget that grew says only that).
    func endGeometry(keep: Bool, message: String? = nil, growth: GrowthNote = .appended) {
        guard !geometryBases.isEmpty else { return }
        let bases = geometryBases
        geometryBases = []
        let allValues = geometryValues
        geometryValues = [:]
        canvas.followers = [:]
        skin?.endPreview()
        canvas.needsDisplay = true
        guard keep else { return }
        var edits: [Edit] = []
        for base in bases {
            let values = allValues[base.meter] ?? [:]
            let raw: [String: String?] = ["X": base.raw.x, "Y": base.raw.y, "W": base.raw.w, "H": base.raw.h]
            for key in ["X", "Y", "W", "H"] {
                guard let value = values[key], value != ((raw[key] ?? nil) ?? "") else { continue }
                edits.append(Edit(section: base.meter, key: key, value: value, own: true))
            }
        }
        if !edits.isEmpty, let skin {
            for (key, size, delta) in fixedSizeGrowth {
                let raw = skin.rainmeterSection?.fileOption(key) ?? GeometryEdit.format(size)
                edits.append(Edit(section: "Rainmeter", key: key, value: GeometryEdit.offset(raw, by: delta), own: false))
            }
            commit(edits, name: gestureName, message: message ?? gestureMessage, growth: message == nil ? .only : growth)
        }
    }

    /// The meters an arrow key, an alignment or Delete acts on.
    var actionMeters: [String] {
        let names = canvas.selectedNames.filter { skin?.meter(named: $0) != nil }
        return names.isEmpty ? (selectedMeterName.map { [$0] } ?? []) : names
    }

    /// Arrow keys: previews at once, writes after a short pause (one undo step for a run of presses).
    func nudge(dx: Double, dy: Double) {
        let names = actionMeters
        guard !names.isEmpty else { return }
        if geometryBases.isEmpty {
            beginGeometry(meters: names, gesture: .move)
            nudgeOffset = (0, 0)
        }
        nudgeOffset.dx += dx
        nudgeOffset.dy += dy
        var targets: [String: SkinRect] = [:]
        for base in geometryBases {
            var f = base.frame
            f.x += nudgeOffset.dx
            f.y += nudgeOffset.dy
            targets[base.meter] = f
        }
        previewGeometry(targets)
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.commitPendingNudge()
        }
    }

    /// Aligns the selected meters to each other (one meter: to the skin) or distributes them evenly.
    func align(_ mode: EditorAlign.Mode) {
        commitPendingNudge()
        // The frames come from the skin: typed code is committed first, and the alignment runs against the result.
        if deferUntilCodeIsCommitted({ [weak self] in self?.align(mode) }) { return }
        guard let skin else { return }
        let names = actionMeters
        guard !names.isEmpty else { return }
        beginGeometry(meters: names, gesture: .move)
        let frames = geometryBases.map(\.frame)
        guard let targets = EditorAlign.frames(frames, mode: mode, skin: SkinRect(x: 0, y: 0, width: skin.width, height: skin.height))
        else {
            geometryBases = []
            toast.show("Select three or more layers to distribute them", error: true)
            return
        }
        gestureName = Self.alignTitle(mode)
        gestureMessage = Self.doneMessage(gestureName)
        previewGeometry(Dictionary(uniqueKeysWithValues: zip(geometryBases.map(\.meter), targets)))
        endGeometry(keep: true)
    }

    static func alignTitle(_ mode: EditorAlign.Mode) -> String {
        switch mode {
        case .left: return "Align Left"
        case .centerX: return "Align Centers"
        case .right: return "Align Right"
        case .top: return "Align Top"
        case .centerY: return "Align Middles"
        case .bottom: return "Align Bottom"
        case .distributeX: return "Distribute Horizontally"
        case .distributeY: return "Distribute Vertically"
        }
    }

    /// Writes a pending run of arrow-key nudges now.
    func commitPendingNudge() {
        guard nudgeTimer != nil else { return }
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        endGeometry(keep: true)
    }

    func cancelPendingEdits() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        colorTimer?.invalidate()
        colorTimer = nil
        colorValue = nil
        geometryBases = []
        geometryValues = [:]
        skin?.endPreview()
    }

    // MARK: Writing and undo

    /// Writes the edits (each to its target file), records one undo step and refreshes the skin. The toast says
    /// `message` (nil: the undo name as a sentence, "Changed color"), and that the widget grew when it did (`growth`).
    func commit(_ edits: [Edit], name: String, message: String? = nil, growth: GrowthNote = .appended) {
        guard !edits.isEmpty else { return }
        if deferUntilCodeIsCommitted({ [weak self] in
            self?.commit(edits, name: name, message: message, growth: growth)
        }) { return }
        guard let skin else { return }
        // A layer's own keys are written for this widget alone (`Skin.localTarget`): one a file other widgets share
        // defines stays as it is, and the toast says so.
        var writes: [KeyWrite] = []
        var shared: [String] = []
        for e in edits {
            if e.own {
                guard let t = skin.localTarget(section: e.section, key: e.key) else {
                    if !shared.contains(where: { $0.caseInsensitiveCompare(e.section) == .orderedSame }) { shared.append(e.section) }
                    continue
                }
                let overrides = !skin.isOwnFile(skin.ownTarget(section: e.section, key: e.key).file)
                writes.append(KeyWrite(file: t.file, section: t.section, key: e.key, value: e.value, afterIncludes: overrides))
            } else {
                let t = skin.editTarget(section: e.section, key: e.key)
                if e.section.caseInsensitiveCompare("Rainmeter") == .orderedSame, !skin.isOwnFile(t.file) {
                    // A widget setting a shared file makes: this widget's own value, after its @Include lines.
                    writes.append(KeyWrite(file: skin.fileURL, section: "Rainmeter", key: e.key, value: e.value,
                                           afterIncludes: true))
                } else {
                    writes.append(KeyWrite(file: t.file, section: t.section, key: e.key, value: e.value))
                }
            }
        }
        let note = sharedNote(shared)
        guard !writes.isEmpty else {
            toast.show(note.trimmingCharacters(in: .whitespaces), error: true)
            return
        }
        perform(name, files: writes.map(\.file), message: { _ in (message ?? Self.doneMessage(name)) + note }, growth: growth) {
            try Self.apply(writes)
        }
    }

    /// A finished edit in words, from its undo name (§10): "Change Color" → "Changed color", "Hide “Audio”" →
    /// "Hid “Audio”", "Move 3 Layers" → "Moved 3 layers". Names in quotes and abbreviations keep their case.
    static func doneMessage(_ name: String) -> String {
        let past = ["Change": "Changed", "Edit": "Edited", "Move": "Moved", "Resize": "Resized", "Nudge": "Moved",
                    "Hide": "Hid", "Show": "Showed", "Add": "Added", "Align": "Aligned", "Distribute": "Distributed",
                    "Delete": "Deleted", "Duplicate": "Duplicated", "Override": "Overrode", "Stretch": "Stretched",
                    "Fit": "Fitted", "Reorder": "Reordered", "Remove": "Removed", "Use": "Used", "Make": "Made",
                    "Match": "Matched", "Apply": "Applied"]
        var words = name.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let verb = words.first else { return name }
        words[0] = past[verb] ?? verb
        var quoted = false
        for i in words.indices.dropFirst() {
            let word = words[i]
            if word.contains("“") { quoted = true }
            let plain = word.first?.isUppercase == true && word.dropFirst().allSatisfy { $0.isLowercase }
            if !quoted, plain { words[i] = word.lowercased() }
            if word.contains("”") { quoted = false }
        }
        return words.joined(separator: " ")
    }

    /// The toast button that undoes the change just made (every toast has one, §10).
    func undoToastAction() -> ToastAction {
        ToastAction("Undo") { [weak self] in self?.window?.undoManager?.undo() }
    }

    /// Runs a file change as one undo step (the bytes of `files` before and after) and refreshes the skin. A dirty
    /// code buffer is committed first (`flushingCode`; not for the code's own commit). Returns false when nothing
    /// could be written (the toast says why); true also when the files ended up unchanged.
    ///
    /// The toast (`message`, from the changed files' names; nil: none) gets `actions` and [Undo]; when the widget grew
    /// it also says "Widget grew to 240 × 196" (`growth`), with [Stretch Background] when the widget's Background no
    /// longer covers it (docs/editor-friendly.md §9.10, §10).
    ///
    /// Without a loaded skin (it was unloaded while the editor stayed open) the change is still written and
    /// undoable — the code pane's buffers can always be saved; only the refresh is skipped. Visual edits need the skin
    /// to compute their values and check for it themselves.
    ///
    /// `verify`: whether the reloaded skin shows the change (a value written for this widget alone must win over a
    /// shared file's); when it doesn't, the files are put back, no undo step is made, and the toast says why.
    @discardableResult
    func perform(_ name: String, files: [URL], flushingCode: Bool = true, message: ((String) -> String)?,
                 actions: [ToastAction] = [], growth: GrowthNote = .appended, verify: ((Skin) -> Bool)? = nil,
                 _ body: () throws -> Void) -> Bool {
        if flushingCode, !flushCode() { return false }
        let skin = self.skin
        skin?.endPreview()
        let sizeBefore = skin.map { SkinSize(width: $0.width, height: $0.height) }
        // The Background as it was: once the widget grows past it, it covers too little of it to be found again.
        let backgroundBefore = skin.flatMap { LayerNaming.background(in: $0) }
        do {
            let changes = try EditorFileChange.record(files, body)
            guard !changes.isEmpty else { return true }
            let text = message?(Set(changes.map { $0.file.lastPathComponent }).sorted().joined(separator: ", "))
            guard let skin else {
                registerUndo(changes, name: name, undo: true, move: widgetMove)
                if let text { toast.show(text, actions: actions + [undoToastAction()]) }
                return true
            }
            // Our own writes are not "changed elsewhere" for live reload, even if the refresh fails to load the skin.
            fileStamps = stamps(for: skin.sourceFiles)
            refreshSkin()
            if let verify, let reloaded = self.skin, !verify(reloaded) {
                try EditorFileChange.restore(changes, undo: true)
                fileStamps = stamps(for: reloaded.sourceFiles)
                refreshSkin()
                toast.show(Self.overrideLostMessage, error: true)
                return false
            }
            registerUndo(changes, name: name, undo: true, move: widgetMove)
            guard var text else { return true }
            var buttons = actions
            if growth != .none, let before = sizeBefore, let now = self.skin,
               now.width > before.width + 0.5 || now.height > before.height + 0.5 {
                let grew = "Widget grew to \(EditorStyle.number(now.width)) × \(EditorStyle.number(now.height))"
                text = growth == .only ? grew : "\(text) · \(grew)"
                if backgroundNeedsStretching(in: now, background: backgroundBefore) {
                    buttons.insert(ToastAction("Stretch Background") { [weak self] in self?.stretchBackground(backgroundBefore) },
                                   at: 0)
                }
            }
            toast.show(text, actions: buttons + [undoToastAction()])
            return true
        } catch {
            toast.show("Could not save: \(error)", error: true)
            NSSound.beep()
            return false
        }
    }

    // MARK: Layers: add, duplicate, delete

    /// Adds a ready-made component and selects its layer, as one undo step "Add <Component>", at the end of the skin
    /// file (in front of everything): at `frame` (a drop from the library: its top-left corner, default size — past
    /// the right or bottom edge the widget grows), else in free space (`freeSpotForNewLayer`): below everything the
    /// widget shows, never on top of another layer (docs/editor-friendly.md §5.1). The toast says when the widget
    /// grew, and offers to stretch its Background to the new size.
    func insertComponent(_ id: String, at frame: SkinRect? = nil) {
        commitPendingNudge()
        if deferUntilEditsAreCommitted({ [weak self] in self?.insertComponent(id, at: frame) }) { return }
        guard let skin, let component = EditorComponents.component(id) else { return }
        let spot = frame.map { (x: $0.x.rounded(), y: $0.y.rounded()) } ?? Self.freeSpotForNewLayer(in: skin)
        let sections = EditorComponents.sections(for: id, x: spot.x, y: spot.y, existing: skin.sectionNames,
                                                 variables: skin.variableNames)
        pendingSelection = sections.filter { $0.options.contains { $0.key == "Meter" } }.map(\.name)
        perform("Add \(component.title)", files: [skin.fileURL], message: { _ in "Added \(component.title)" }) {
            try skin.appendSections(sections)
        }
        dismissTip(.add)
    }

    /// Where a layer added with a click goes (§5.1): 8 points below the lowest visible layer, at the left edge of the
    /// leftmost one (never left of or above the widget's origin); at the origin in an empty widget. Nothing visible is
    /// below that line, so the new layer lands on none.
    static func freeSpotForNewLayer(in skin: Skin) -> (x: Double, y: Double) {
        let visible = skin.meters.filter { !$0.hidden && $0.container == nil && !$0.isContainer }
        guard !visible.isEmpty else { return (0, 0) }
        let b = skin.contentBounds()
        return (max(b.x, 0).rounded(), max(b.maxY + 8, 0).rounded())
    }

    /// The section a component added after the meter `anchor` is written in front of (nil: at the end of the skin
    /// file). Meters placed with `r` / `R` are relative to the meter before them in the file (manual: General Meter
    /// Options → X, Y), so new sections right after `anchor` would move the meter that follows it relative to `anchor`.
    /// They go after that chain instead: after the last of the meters that follow `anchor` each relative to the one
    /// before (content meters of a container are skipped — they are placed within their container, and the new meter
    /// is not content). When the chain ends in an included file, the component goes to the end of the skin file.
    static func insertionPoint(after anchor: String, in skin: Skin) -> String? {
        let meters = skin.meters
        guard var last = meters.firstIndex(where: { $0.name.caseInsensitiveCompare(anchor) == .orderedSame }) else {
            return nil
        }
        for i in meters.indices.dropFirst(last + 1) where meters[i].container == nil {
            guard isRelativelyPlaced(meters[i]) else { break }
            last = i
        }
        return section(after: meters[last].name, in: skin)
    }

    /// Whether the meter's X or Y is relative to the meter before it (`10r`, `(5+5)R`, or a variable that says so).
    static func isRelativelyPlaced(_ meter: Meter) -> Bool {
        [meter.option("X"), meter.option("Y")].contains { value in
            guard let last = value?.trimmingCharacters(in: .whitespaces).last else { return false }
            return last == "r" || last == "R"
        }
    }

    /// The section whose header comes right after `name`'s in the skin file (nil when `name` is the last one there,
    /// or is defined in an included file).
    static func section(after name: String, in skin: Skin) -> String? {
        let main = CodeEditorRouter.comparablePath(skin.fileURL)
        guard let own = skin.sources.location(section: name), CodeEditorRouter.comparablePath(own.file) == main else {
            return nil
        }
        return skin.sources.sections
            .filter { CodeEditorRouter.comparablePath($0.value.file) == main && $0.value.line > own.line }
            .min { $0.value.line < $1.value.line }
            .map { skin.document.section(named: $0.key)?.name ?? $0.key }
    }

    /// ⌘D: copies of the selected meters, 10 points down and right, selected.
    func duplicateSelection() {
        commitPendingNudge()
        if deferUntilEditsAreCommitted({ [weak self] in self?.duplicateSelection() }) { return }
        guard let skin else { return }
        let names = actionMeters
        guard !names.isEmpty else { return }
        var taken = skin.sectionNames
        let copies = names.compactMap { skin.duplicateSections($0, dx: 10, dy: 10, taken: &taken) }
        pendingSelection = copies.map(\.name)
        let label = layersLabel(names), words = layersLabel(names, title: false)
        perform("Duplicate \(label)", files: [skin.fileURL], message: { _ in "Duplicated \(words)" }) {
            try skin.appendSections(copies)
        }
    }

    /// Delete: removes the selected meters (or the selected measure / style) from the files that define them — every
    /// block of each (`Skin.removeSection`), so no ignored duplicate or included block brings it back.
    func deleteSelection() {
        commitPendingNudge()
        if deferUntilEditsAreCommitted({ [weak self] in self?.deleteSelection() }) { return }
        guard let skin else { return }
        var names = actionMeters
        if names.isEmpty, let name = selectedSection, selectedKind == .measure || selectedKind == .other { names = [name] }
        guard !names.isEmpty else { return }
        // A layer (or data item) a file other widgets read defines is theirs too: never deleted from here.
        if let shared = sharedDeletionNote(names) {
            toast.show(shared, error: true)
            return
        }
        let files = names.flatMap { skin.definingFiles(ofSection: $0) }
        let label = layersLabel(names), words = layersLabel(names, title: false)
        selectedMeters = []
        selectedSection = nil
        perform("Delete \(label)", files: files, message: { _ in "Deleted \(words)" }) {
            for n in names { try skin.removeSection(n) }
        }
    }

    /// The components by category, for the Insert menu (`target` nil: the key editor window, via the responder chain).
    static func componentMenuItems(target: AnyObject?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for category in EditorComponents.Category.allCases {
            let components = EditorComponents.all.filter { $0.category == category }
            guard !components.isEmpty else { continue }
            if !items.isEmpty { items.append(.separator()) }
            if #available(macOS 14.0, *) {
                items.append(.sectionHeader(title: category.title))
            } else {
                let header = NSMenuItem(title: category.title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                items.append(header)
            }
            for c in components {
                let item = NSMenuItem(title: c.title, action: #selector(componentChosen(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = c.id
                item.image = EditorStyle.image(c.symbol, size: 14)
                item.toolTip = c.summary
                items.append(item)
            }
        }
        return items
    }

    @objc func componentChosen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { insertComponent(id) }
    }

    /// `move`: the widget's window moved with this change (Fit Widget to Content); it moves back and forth with the
    /// files — and never without them.
    func registerUndo(_ changes: [EditorFileChange], name: String, undo: Bool, move: WidgetMove? = nil) {
        guard let manager = window?.undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            target.restore(changes, name: name, undo: undo, move: move)
        }
        manager.setActionName(name)
    }

    /// Undo / redo of a file change. Edits still pending (a nudge, a color, a slider preview) were committed before
    /// the undo manager got here (`EditorUndoManager`), so ⌘Z takes them back first; one still left now is dropped,
    /// so no write lands behind the undo (and clears the redo it makes possible).
    func restore(_ changes: [EditorFileChange], name: String, undo: Bool, move: WidgetMove? = nil) {
        cancelPendingEdits()
        cancelPendingPreview()
        do {
            try EditorFileChange.restore(changes, undo: undo)
            registerUndo(changes, name: name, undo: !undo, move: move)
            if let move {
                let to = undo ? move.from : move.to
                controller?.moveTo(x: to.x, y: to.y)
            }
            // "Undid Change Bar Color · [Redo]" (§10).
            toast.show(undo ? "Undid \(name)" : "Redid \(name)", actions: [
                undo ? ToastAction("Redo") { [weak self] in self?.window?.undoManager?.redo() } : undoToastAction(),
            ])
            if let skin { fileStamps = stamps(for: skin.sourceFiles) } else { codeFilesChangedOnDisk() }
            refreshSkin()
        } catch {
            toast.show("Can't \(undo ? "undo" : "redo"): \(error)", error: true)
            NSSound.beep()
        }
    }

    /// What a toast says when an edit made the widget grow (§9.10).
    enum GrowthNote {
        /// "Added Clock · Widget grew to 217 × 240".
        case appended
        /// "Widget grew to 240 × 196" (a drag).
        case only
        /// Nothing (Fit Widget to Content moves everything on purpose).
        case none
    }

    // MARK: Overflow (docs/editor-friendly.md §9.10)

    /// The edges of the widget a layer goes past, so the desktop cuts that part off.
    struct CutOffEdges: OptionSet {
        let rawValue: Int
        static let left = CutOffEdges(rawValue: 1)
        static let top = CutOffEdges(rawValue: 2)
        /// Past a fixed size (SkinWidth / SkinHeight): the widget does not grow.
        static let right = CutOffEdges(rawValue: 4)
        static let bottom = CutOffEdges(rawValue: 8)
    }

    /// Where a layer goes past the widget: its left or top edge, or the right or bottom of a fixed size. Hidden layers,
    /// empty ones and content of a container (clipped to the container) never are.
    static func cutOffEdges(of m: Meter, in skin: Skin) -> CutOffEdges {
        guard !m.hidden, m.container == nil, m.frame.width > 0, m.frame.height > 0 else { return [] }
        var edges: CutOffEdges = []
        if m.frame.x < -0.5 { edges.insert(.left) }
        if m.frame.y < -0.5 { edges.insert(.top) }
        if let w = skin.settings.skinWidth, m.frame.maxX > w + 0.5 { edges.insert(.right) }
        if let h = skin.settings.skinHeight, m.frame.maxY > h + 0.5 { edges.insert(.bottom) }
        return edges
    }

    /// The identity strip's line for a layer cut off on the desktop (§7.1): "Part of this layer is past the left edge
    /// and won't show on the desktop." (nil: it is not); its button is [Fit Widget to Content] (`fitWidgetToContent`)
    /// for the left and top edges, [Make Widget Bigger] (`makeWidgetBigger`) for a fixed size.
    func cutOffSentence(of name: String) -> String? {
        guard let skin, let m = skin.meter(named: name) else { return nil }
        let edges = Self.cutOffEdges(of: m, in: skin)
        if edges.contains(.left) || edges.contains(.top) {
            let edge = edges.contains(.left) && edges.contains(.top) ? "the left and top edges"
                : edges.contains(.left) ? "the left edge" : "the top edge"
            return "Part of this layer is past \(edge) and won't show on the desktop."
        }
        return edges.isEmpty ? nil : "Part of this layer is outside the widget's fixed size and won't show on the desktop."
    }

    /// Every layer cut off on the desktop, in file order, with the edges it goes past.
    func cutOffLayers() -> [(name: String, edges: CutOffEdges)] {
        guard let skin else { return [] }
        return skin.meters.compactMap { m in
            let edges = Self.cutOffEdges(of: m, in: skin)
            return edges.isEmpty ? nil : (m.name, edges)
        }
    }

    /// Fit Widget to Content (§9.10, one undo step "Fit Widget to Content"): every layer not inside a container —
    /// hidden ones too — moves right and down by what lies left of and above the widget, through the same geometry
    /// path as a drag (so `#Left#` becomes `(#Left# + 12)`, `[MeasurePeakX]` becomes `([MeasurePeakX] + 12)`, and
    /// layers placed after a moved one are not moved twice), and the widget's window moves left and up by as much, so
    /// nothing jumps on the desktop. ⌘Z puts back both the files and the window.
    func fitWidgetToContent() {
        commitPendingNudge()
        if deferUntilEditsAreCommitted({ [weak self] in self?.fitWidgetToContent() }) { return }
        guard let skin, let c = controller else { return }
        let bounds = skin.contentBounds()
        let dx = max(0, -bounds.x).rounded(.up), dy = max(0, -bounds.y).rounded(.up)
        guard dx > 0 || dy > 0 else { return }
        let layers = skin.meters.filter { $0.container == nil }.map(\.name)
        // Every layer moves, or none: one a file other widgets share defines can't move for this widget alone, and
        // moving the others without it would take them apart.
        let shared = layers.filter { name in
            ["X", "Y"].contains { skin.localTarget(section: name, key: $0) == nil }
                && !(skin.meter(named: name).map(Self.isRelativelyPlaced) ?? false)
        }
        if !shared.isEmpty {
            toast.show("Fit Widget to Content would move \(layersLabel(shared, title: false)), which "
                + "\(shared.count == 1 ? "comes" : "come") from a file other widgets share. Move the cut-off "
                + "\(cutOffLayers().count == 1 ? "layer" : "layers") instead.", error: true)
            return
        }
        beginGeometry(meters: layers, gesture: .move)
        gestureName = "Fit Widget to Content"
        gestureMessage = nil
        previewGeometry(Dictionary(uniqueKeysWithValues: geometryBases.map { base in
            (base.meter, SkinRect(x: base.frame.x + dx, y: base.frame.y + dy, width: base.frame.width,
                                  height: base.frame.height))
        }))
        // A fixed size grows by as much, in the same step, so what moved right isn't cut off on the right instead.
        fixedSizeGrowth = []
        if let w = skin.settings.skinWidth, dx > 0 { fixedSizeGrowth.append(("SkinWidth", w, dx)) }
        if let h = skin.settings.skinHeight, dy > 0 { fixedSizeGrowth.append(("SkinHeight", h, dy)) }
        let before = c.topLeftPosition
        let onDesktop = !c.isStopped && !c.isHiddenByBang
        let n = EditorStyle.number
        let content = [dx > 0 ? "\(n(dx)) px right" : nil, dy > 0 ? "\(n(dy)) px down" : nil].compactMap { $0 }
            .joined(separator: " and ")
        let widget = [dx > 0 ? "\(n(dx)) px left" : nil, dy > 0 ? "\(n(dy)) px up" : nil].compactMap { $0 }
            .joined(separator: " and ")
        let target = (x: before.x - dx, y: before.y - dy)
        // The window moves with the files, on ⌘Z and ⌘⇧Z too — and only when they do (`widgetMove`).
        widgetMove = (before, target)
        defer { widgetMove = nil; fixedSizeGrowth = [] }
        endGeometry(keep: true, message: onDesktop
            ? "Moved everything \(content) and the widget \(widget), so nothing jumps on your desktop."
            : "Moved everything \(content) so nothing is cut off.", growth: .none)
        // Written and reloaded (a new controller): the window follows.
        guard let now = controller, now !== c else { return }
        now.moveTo(x: target.x, y: target.y)
    }

    /// Whether the widget's Background (§5.2) no longer covers it: the widget grew past it.
    /// `background`: the layer that was the Background before the widget grew (nil: the one detected now).
    func backgroundNeedsStretching(in skin: Skin, background: String? = nil) -> Bool {
        guard let name = background ?? LayerNaming.background(in: skin), let m = skin.meter(named: name), !m.hidden else {
            return false
        }
        return m.frame.maxX < skin.width - 0.5 || m.frame.maxY < skin.height - 0.5
    }

    /// Stretch Background (one undo step "Stretch Background"): the Background's own size grows to the widget's —
    /// written numbers are replaced, variables and formulas are offset in place (`(#Width# + 23)`), and no shared
    /// value changes. `name`: the layer to stretch (nil: the detected Background).
    func stretchBackground(_ name: String? = nil) {
        commitPendingNudge()
        if deferUntilEditsAreCommitted({ [weak self] in self?.stretchBackground(name) }) { return }
        guard let skin, let background = name ?? LayerNaming.background(in: skin),
              let m = skin.meter(named: background) else { return }
        let dw = max(0, skin.width - m.frame.maxX).rounded(), dh = max(0, skin.height - m.frame.maxY).rounded()
        guard dw > 0 || dh > 0 else { return }
        guard let edits = Self.stretchEdits(m, dw: dw, dh: dh) else {
            toast.show("This background's shape can't be stretched here — change its size in the inspector", error: true)
            return
        }
        commit(edits, name: "Stretch Background", message: "Stretched the background to fill the widget", growth: .none)
    }

    /// The edits that make layer `m` `dw` wider and `dh` higher: a Shape layer's first shape when it is a rectangle,
    /// else its W and H. nil when its size can't be changed that way.
    static func stretchEdits(_ m: Meter, dw: Double, dh: Double) -> [Edit]? {
        if m.type.lowercased() == "shape" {
            guard let raw = m.rawOption("Shape"), var spec = ShapeSpec.parse(raw), spec.kind == .rectangle,
                  spec.unknownType == nil, spec.params.count >= 4 else { return nil }
            if dw > 0 { spec.params[2] = GeometryEdit.offset(spec.params[2], by: dw) }
            if dh > 0 { spec.params[3] = GeometryEdit.offset(spec.params[3], by: dh) }
            return [Edit(section: m.name, key: "Shape", value: spec.text, own: true)]
        }
        let raw = m.rawGeometry, content = m.contentSize
        func grown(_ written: String?, _ natural: Double, by delta: Double) -> String {
            if let written, !written.trimmingCharacters(in: .whitespaces).isEmpty { return GeometryEdit.offset(written, by: delta) }
            return GeometryEdit.format(natural + delta)
        }
        var edits: [Edit] = []
        if dw > 0 { edits.append(Edit(section: m.name, key: "W", value: grown(raw.w, content.width, by: dw), own: true)) }
        if dh > 0 { edits.append(Edit(section: m.name, key: "H", value: grown(raw.h, content.height, by: dh), own: true)) }
        return edits
    }

    /// Make Widget Bigger (a fixed-size widget with content outside it): SkinWidth / SkinHeight grow to the content.
    func makeWidgetBigger() {
        guard let skin else { return }
        let b = skin.contentBounds()
        var edits: [Edit] = []
        if let w = skin.settings.skinWidth, b.maxX > w {
            edits.append(Edit(section: "Rainmeter", key: "SkinWidth", value: GeometryEdit.format(b.maxX.rounded(.up)), own: false))
        }
        if let h = skin.settings.skinHeight, b.maxY > h {
            edits.append(Edit(section: "Rainmeter", key: "SkinHeight", value: GeometryEdit.format(b.maxY.rounded(.up)), own: false))
        }
        commit(edits, name: "Make Widget Bigger", message: "Made the widget bigger", growth: .none)
    }

    /// Fit to Content (a fixed-size widget): SkinWidth and SkinHeight are removed, so the widget fits its content — in
    /// this widget's own files; a fixed size a file other widgets share sets is undone here with this widget's own 0
    /// (`writeWidgetSettings`), never removed from that file.
    func fitFixedSizeToContent() {
        commitPendingNudge()
        if deferUntilEditsAreCommitted({ [weak self] in self?.fitFixedSizeToContent() }) { return }
        guard let skin, skin.settings.skinWidth != nil || skin.settings.skinHeight != nil else { return }
        writeWidgetSettings([("SkinWidth", nil), ("SkinHeight", nil)], undoName: "Fit Widget to Content",
                            toast: "The widget now fits its content")
    }

    // MARK: Visibility and drawing order

    /// Whether part of a layer is outside the widget, so the desktop cuts it off (docs/editor-friendly.md §9.10; its
    /// row shows ⚠): past the left or top edge, or outside a fixed size (SkinWidth / SkinHeight). Hidden layers and
    /// content of a container (clipped to it) are not.
    func isLayerCutOff(_ name: String) -> Bool {
        guard let skin, let m = skin.meter(named: name) else { return false }
        return Self.cutOffEdges(of: m, in: skin) != []
    }

    /// The eye in the layer list: writes Hidden into the meter's own section, one undo step "Hide “Audio”" (toast
    /// "Hid “Audio”", §10).
    func setHidden(_ hidden: Bool, meter: String) {
        setLayersHidden([meter], hidden: hidden)
    }

    /// Moves a meter in the drawing order (see `Skin.moveSection`). False when it cannot (different files).
    @discardableResult
    func reorder(_ name: String, before: String?) -> Bool {
        if deferUntilEditsAreCommitted({ [weak self] in self?.reorder(name, before: before) }) { return true }
        guard let skin else { return false }
        let file = skin.sources.location(section: name)?.file ?? skin.fileURL
        if let before, (skin.sources.location(section: before)?.file ?? skin.fileURL) != file {
            toast.show("These layers are defined in different files, so their order can't change here", error: true)
            return false
        }
        pendingSelection = [name]
        perform("Reorder Layers", files: [file], message: { "Drawing order saved to \($0)" }) {
            _ = try skin.moveSection(name, before: before)
        }
        return true
    }
}

/// The skin editor's undo stack. Edits still waiting for their pause — a run of arrow-key nudges, a color being
/// picked, a slider or stepper preview — are committed before an undo or redo runs, so ⌘Z takes back the change the
/// user just made (instead of the one before it, with the pending one written afterwards over the redo).
final class EditorUndoManager: UndoManager {
    /// Commits the pending edits (the window controller); not called while typing in a text field or the code, whose
    /// undo is the typing.
    var commitPendingEdits: (() -> Void)?
    /// Whether edits are pending (Undo is available for them even with nothing on the stack yet).
    var hasPendingEdits: (() -> Bool)?

    override func undo() {
        if !isUndoing, !isRedoing { commitPendingEdits?() }
        // A pending edit that ended where it started wrote nothing: nothing to undo then.
        guard super.canUndo || groupingLevel > 0 else { return }
        super.undo()
    }

    override func redo() {
        if !isUndoing, !isRedoing { commitPendingEdits?() }
        guard super.canRedo else { return }
        super.redo()
    }

    override var canUndo: Bool { super.canUndo || hasPendingEdits?() == true }
}

/// The target of the shared color panel for the inspector's own swatches. The panel does not retain its target (and
/// does not forget it when the target goes away), so it always reports to this object, which lives as long as the
/// app and passes the color on to the editor window that opened the panel, as long as that window exists.
final class InspectorColorPanel: NSObject {
    static let shared = InspectorColorPanel()
    /// The editor the panel picks for (nil: another swatch took the panel, or the editor closed).
    private(set) weak var owner: InspectorWindowController?
    private var observing = false

    /// Opens the panel for `owner`'s color being edited.
    func open(for owner: InspectorWindowController, color: NSColor) {
        self.owner = owner
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(nil)
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(self, selector: #selector(panelClosed), name: NSWindow.willCloseNotification,
                                                   object: panel)
        }
    }

    /// Another picker took the panel (the Shape editor's), or `owner` is going away: nothing reaches it any more.
    /// (The panel may keep this object as its target: it outlives every window.)
    func release(_ owner: InspectorWindowController? = nil) {
        guard owner == nil || self.owner === owner else { return }
        self.owner = nil
    }

    @objc func colorPicked(_ sender: NSColorPanel) { owner?.colorPicked(sender) }

    @objc func panelClosed() { owner?.colorPanelClosed() }
}
