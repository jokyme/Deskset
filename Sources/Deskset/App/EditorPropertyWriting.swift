import AppKit
import DesksetCore

/// Writes made by the inspector's controls, on top of the shared pipeline in EditorEditing.swift (`perform`: one undo
/// step with the bytes of the changed files, a refresh of the skin): one property, written to the narrowest place that
/// covers exactly what is selected (docs/editor-friendly.md §7.5, `ScopeResolver`), with a toast that states the reach
/// and offers the next wider place ("Changed Bar 6 only · [Apply to All 16 Bars]"); shared values (a variable, for
/// this widget only or for every widget sharing its file); a literal color everywhere this widget writes it; resetting
/// a property; several keys at once (the Shape editor's renumbering); image files picked from outside the widget.
///
/// With typed code not committed yet, each of them commits the code first and writes on the next turn of the run
/// loop (`deferUntilCodeIsCommitted`), so the write lands on what the code says and is an undo step of its own. A value
/// built from the skin's current options (a whole Shape, a gradient, the four insets) must be built after that too:
/// those callers defer before they read the options (see `editShape`).
extension InspectorWindowController {
    /// One key of one section of one file to set (`value`) or remove (nil). `afterIncludes`: set after the block's
    /// `@Include` lines, so it wins over the same key from a shared file (`IniWriter.writeAfterIncludes`).
    struct KeyWrite: Equatable {
        var file: URL
        var section: String
        var key: String
        var value: String?
        var afterIncludes = false
    }

    /// Writes of `key=value` into each section's own key for this widget alone (`Skin.localTarget`: never into a file
    /// other widgets share), and the sections that can't be changed that way (a layer only a shared file defines).
    func localWrites(_ sections: [String], key: String, value: String?) -> (writes: [KeyWrite], shared: [String]) {
        guard let skin else { return ([], sections) }
        var writes: [KeyWrite] = []
        var shared: [String] = []
        for s in sections {
            guard let t = skin.localTarget(section: s, key: key) else { shared.append(s); continue }
            if value == nil, skin.ownDefinitionFile(section: s, key: key).map(skin.isOwnFile) != true { continue }
            // Overriding a shared file's value: written after the block's @Include lines, so it is read later and wins.
            let overrides = !skin.isOwnFile(skin.ownTarget(section: s, key: key).file)
            writes.append(KeyWrite(file: t.file, section: t.section, key: key, value: value, afterIncludes: overrides && value != nil))
        }
        return (writes, shared)
    }

    /// Writes of one key for several sections edited together (a group's card, several layers), where `ScopeResolver`
    /// says for each: the shared value or the look once, else each section's own key in that section's own file
    /// (never all in the first one's), for this widget alone (`localWrites`).
    func scopedWrites(_ key: String, value: String, sections: [String]) -> (writes: [KeyWrite], shared: [String]) {
        guard let skin else { return ([], []) }
        let resolver = ScopeResolver(skin: skin, usages: valueUsages(skin))
        var writes: [KeyWrite] = []
        var own: [String] = []
        for s in sections {
            let t = resolver.target(section: s, key: key, selection: sections)
            let w: KeyWrite
            switch t.scope {
            case .look(let look): w = KeyWrite(file: t.file, section: look, key: key, value: value)
            case .sharedValue: w = KeyWrite(file: t.file, section: "Variables", key: t.key, value: value)
            case .own:
                own.append(s)
                continue
            }
            if !writes.contains(w) { writes.append(w) }
        }
        let local = localWrites(own, key: key, value: value)
        return (writes + local.writes, local.shared)
    }

    /// "Change ‘Left’ for All 10 Layers…" typed or stepped: the shared value itself, where the widget page's Apply to
    /// says (this widget's own value after its @Include lines by default, `writeSharedValues`), as one undo step whose
    /// toast states the reach. The one writer of both linked-number editors.
    func writeLinkedValue(_ variable: String, value: String) {
        guard let skin else { return }
        let users = valueUsages(skin).variable(variable)?.sections ?? []
        let words = ValueUsageIndex.humanizedVariable(variable)
        writeSharedValues([(variable, value)], undoName: "Change \(Self.titleCase(words))",
                          toast: "\(words) changed on \(usersPhrase(users))")
    }

    /// The linked-number menu's "Change ‘Left’ for All 10 Layers…", worded by its reach: "… in All 6 Widgets…" when
    /// Apply to says every widget sharing the file that defines it.
    func changeSharedTitle(_ variable: String, users: String, many: Bool) -> String {
        let name = ValueUsageIndex.humanizedVariable(variable)
        if appliesToAllWidgets, let skin, let file = skin.sources.location(section: "Variables", key: variable)?.file,
           !skin.isOwnFile(file), configsIncluding(file).count > 1 {
            return "Change ‘\(name)’ in All \(configsIncluding(file).count) Widgets…"
        }
        return many ? "Change ‘\(name)’ for All \(Self.titleCase(users))…" : "Change ‘\(name)’…"
    }

    /// The other widgets reading a file that defines `section` (a data item or layer in a shared include), by config:
    /// deleting it there would take it from them too. Empty when only this widget's own files define it.
    func otherWidgetsSharing(_ section: String) -> [String] {
        guard let skin else { return [] }
        let files = skin.definingFiles(ofSection: section).filter { !skin.isOwnFile($0) }
        let own = config.lowercased()
        return Array(Set(files.flatMap(configsIncluding).map { $0.lowercased() }).filter { $0 != own }).sorted()
    }

    /// "Also used by 3 other widgets." for sections other widgets read too (nil: none is).
    func sharedDeletionNote(_ sections: [String]) -> String? {
        let others = Set(sections.flatMap(otherWidgetsSharing))
        guard !others.isEmpty else { return nil }
        return "Also used by \(others.count) other widget\(others.count == 1 ? "" : "s"), so it can't be deleted here."
    }

    /// The toast's note for layers left as they are because a file other widgets share defines them (empty: none).
    func sharedNote(_ sections: [String]) -> String {
        guard !sections.isEmpty else { return "" }
        let what = sections.count == 1 ? displayName(ofSection: sections[0]) : "\(sections.count) layers"
        let verb = sections.count == 1 ? "comes" : "come"
        return " \(Self.capitalizedFirst(what)) \(verb) from a file other widgets share, so \(sections.count == 1 ? "it" : "they") stayed as before."
    }

    // MARK: One property, where the selection says

    /// The sections an edit of `section` is meant for: the multiple selection when it holds the section (a group, or
    /// several layers edited together), else the section alone.
    func scopeSelection(for section: String) -> [String] {
        if selectedMeters.count > 1, selectedMeters.contains(where: { $0.caseInsensitiveCompare(section) == .orderedSame }) {
            return selectedMeters
        }
        return [section]
    }

    /// Writes a property of the selection (`selection`, default `scopeSelection(for:)`) where `ScopeResolver` says:
    /// the shared value itself, the look, or each selected section's own key (§7.5). `variable`: the value is written
    /// as this one `#Var#` now. A number typed over a linked size keeps the link (`(#Left# + 6)`, §7.3).
    /// `undoName` / `message`: the step's name and the toast's words when the page words them itself ("Show Sound
    /// Band 6", "Bar 4 now shows sound band 6"); the toast's offers to widen the change stay.
    func writeProperty(section: String, key: String, value: String, variable: String?, label: String,
                       selection: [String]? = nil, undoName: String? = nil, message: String? = nil) {
        if deferUntilCodeIsCommitted({ [weak self] in
            self?.writeProperty(section: section, key: key, value: value, variable: variable, label: label, selection: selection,
                                undoName: undoName, message: message)
        }) { return }
        guard let skin else { return }
        let sections = selection ?? scopeSelection(for: section)
        let target = ScopeResolver(skin: skin, usages: valueUsages(skin)).target(section: section, key: key, selection: sections, variable: variable)
        switch target.scope {
        case .sharedValue(let name):
            let usage = valueUsages(skin).variable(name)
            let role = usage?.role ?? ValueUsageIndex.humanizedVariable(name)
            writeSharedValues([(name, value)], undoName: "Change \(Self.titleCase(role))",
                              toast: "\(Self.capitalizedFirst(role)) changed on \(usersPhrase(usage?.sections ?? sections))")
        case .look(let look):
            let before = skin.document.section(named: look)?.value(forKey: key)
            let written = linkedNumber(value, variable: variable, key: key, in: skin)
            let users = lookUsers(look, key: key)
            let what = kindPhrase(users, definite: true)
            let name = undoName ?? "Change \(Self.titleCase(label)) of \(Self.titleCase(kindPhrase(users, definite: false)))"
            guard performEdit(name, files: [target.file], {
                try IniWriter.writeValue(written, key: key, section: look, fileURL: target.file)
            }) else { return }
            var actions: [ToastAction] = []
            if let before, let v = wholeVariable(before), let everywhere = changeEverywhereAction(
                variable: v, value: value, restoring: [KeyWrite(file: target.file, section: look, key: key, value: before)]) {
                actions.append(everywhere)
            }
            showToast(message ?? "Changed \(what)", actions: actions)
        case .own:
            let written = linkedNumber(value, variable: variable, key: key, in: skin)
            // Each section's own key, in its own file (never one file for all), and never in a file other widgets
            // share: a layer only such a file defines stays as it is, and the toast says so.
            let local = localWrites(target.sections, key: key, value: written)
            let writes = local.writes
            guard !writes.isEmpty else {
                toast.show(sharedNote(local.shared).trimmingCharacters(in: .whitespaces), error: true)
                return
            }
            let changed = target.sections.filter { s in !local.shared.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) }
            let own = changed.map { s in (section: s, target: skin.localTarget(section: s, key: key)) }
            // Where the value came from before: a look the selected layers share, or a shared value.
            let look = local.shared.isEmpty ? sharedLook(of: target.sections, key: key) : nil
            let before = own.map { (s: $0.section, raw: skin.section(named: $0.section)?.fileOption(key)) }
            let name = undoName ?? (own.count == 1
                ? "Change \(Self.titleCase(label)) of \(reachWords(own[0].section))"
                : "Change \(Self.titleCase(label)) of \(Self.titleCase(kindPhrase(changed, definite: false)))")
            guard performEdit(name, files: writes.map(\.file), { try Self.apply(writes) }) else { return }
            let what = own.count == 1 ? reachWords(own[0].section) : kindPhrase(changed, definite: true)
            var actions: [ToastAction] = []
            if let look, let apply = applyToLookAction(look, key: key, value: written, sections: target.sections, label: label) {
                actions.append(apply)
            } else if let variable, let everywhere = changeEverywhereAction(variable: variable, value: value, restoring: before.compactMap { b in
                guard let raw = b.raw, let t = skin.localTarget(section: b.s, key: key) else { return nil }
                return KeyWrite(file: t.file, section: t.section, key: key, value: raw)
            }) {
                actions.append(everywhere)
            }
            showToast((message ?? (actions.isEmpty ? "Changed \(what)" : "Changed \(what) only")) + sharedNote(local.shared),
                      actions: actions)
        }
    }

    /// Writes the property into the layer's own section, so it no longer follows its shared style.
    func overrideProperty(section: String, key: String, value: String, label: String) {
        if deferUntilCodeIsCommitted({ [weak self] in
            self?.overrideProperty(section: section, key: key, value: value, label: label)
        }) { return }
        guard let skin else { return }
        let file = skin.ownTarget(section: section, key: key).file
        guard perform("Override \(label)", files: [file], message: nil, {
            try skin.writeOwnOption(section: section, key: key, value: value)
        }) else { return }
        showToast("\(label) set on \(displayName(ofSection: section)) only")
    }

    /// Removes the section's own value of the property: its shared style's value or the default applies again.
    func resetProperty(section: String, key: String, label: String) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.resetProperty(section: section, key: key, label: label) }) {
            return
        }
        guard let skin, let file = skin.ownDefinitionFile(section: section, key: key) else { return }
        guard perform("Reset \(label)", files: [file], message: nil, {
            try skin.removeOwnOption(section: section, key: key)
        }) else { return }
        showToast("\(label) reset on \(displayName(ofSection: section))")
    }

    /// "↺ Match the Others" (§7.5): the layer's own value of a key its look also sets is removed, so the look's value
    /// applies again — one undo step "Match the Others".
    func matchTheOthers(section: String, key: String) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.matchTheOthers(section: section, key: key) }) { return }
        guard let skin, let file = skin.ownDefinitionFile(section: section, key: key) else { return }
        guard perform("Match the Others", files: [file], message: nil, {
            try skin.removeOwnOption(section: section, key: key)
        }) else { return }
        showToast("\(displayName(ofSection: section)) matches the others again")
    }

    /// Whether a layer has its own value for a key its look also sets (the row shows "↺ Match the Others").
    func differsFromItsLook(section: String, key: String) -> Bool {
        guard let s = skin?.section(named: section), case .own? = s.fileOrigin(key) else { return false }
        return !(skin?.inspectedOptions(ofSection: section).first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?
            .shadowedStyles.isEmpty ?? true)
    }

    /// The small "↺ Match the Others" link of a row whose layer has its own value for a key its look also sets (nil
    /// otherwise).
    func matchTheOthersLink(section: String, key: String) -> NSView? {
        guard differsFromItsLook(section: section, key: key) else { return nil }
        let link = NSButton(title: "↺ Match the Others", target: nil, action: nil)
        link.isBordered = false
        link.font = .systemFont(ofSize: 11, weight: .medium)
        link.contentTintColor = .controlAccentColor
        link.toolTip = "Use the look's value again"
        link.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/match")
        link.onAction { [weak self] _ in self?.matchTheOthers(section: section, key: key) }
        return link
    }

    /// Sets and removes several keys as one undo step.
    func writeKeys(_ writes: [KeyWrite], name: String, message: String) {
        guard !writes.isEmpty else { return }
        if deferUntilCodeIsCommitted({ [weak self] in self?.writeKeys(writes, name: name, message: message) }) { return }
        guard perform(name, files: writes.map(\.file), message: nil, { try Self.apply(writes) }) else { return }
        showToast(message)
    }

    static func apply(_ writes: [KeyWrite]) throws {
        for w in writes {
            if let value = w.value, w.afterIncludes {
                try IniWriter.writeAfterIncludes(value, key: w.key, section: w.section, fileURL: w.file)
            } else if let value = w.value {
                try IniWriter.writeValue(value, key: w.key, section: w.section, fileURL: w.file)
            } else {
                try IniWriter.removeKey(w.key, section: w.section, fileURL: w.file)
            }
        }
    }

    // MARK: Shared values and literal colors

    /// Writes shared values (variables) as one undo step: the widget page's colors, fonts and sizes, "Change ‘…’
    /// Everywhere", a group's shared sizes. A variable defined in a file shared with other widgets goes where the
    /// widget page's "Apply to" says (§8.1.1), or `everywhere` when given: into this widget's own `[Variables]`, after
    /// its `@Include` lines ("This Widget", the default), or into the file that defines it ("All N Widgets") — the
    /// toast and the undo name then say so ("Bar color changed in all 6 Deskset widgets", G4). `extra` is written in the
    /// same step.
    @discardableResult
    func writeSharedValues(_ values: [(name: String, value: String)], undoName: String, toast: String,
                           extra: [KeyWrite] = [], everywhere: Bool? = nil) -> Bool {
        guard let skin, !values.isEmpty || !extra.isEmpty else { return false }
        let all = everywhere ?? appliesToAllWidgets
        var plan: [KeyWrite] = []
        for v in values {
            let defined = skin.sources.location(section: "Variables", key: v.name)?.file
            if let defined, !skin.isOwnFile(defined), !all {
                plan.append(KeyWrite(file: skin.fileURL, section: "Variables", key: v.name, value: v.value, afterIncludes: true))
            } else if all, let defined, skin.isOwnFile(defined), let shared = skin.sharedDefinition(ofVariable: v.name) {
                // Every widget: the shared file's value changes, and this widget's own value (an earlier "This
                // Widget" edit) goes, so it follows the shared one again.
                plan.append(KeyWrite(file: shared, section: "Variables", key: v.name, value: v.value))
                plan.append(KeyWrite(file: defined, section: "Variables", key: v.name, value: nil))
            } else {
                plan.append(KeyWrite(file: skin.editTarget(section: "Variables", key: v.name).file, section: "Variables",
                                     key: v.name, value: v.value))
            }
        }
        var undoName = undoName, toast = toast
        if let reach = sharedReach(plan.filter { !$0.afterIncludes && $0.value != nil }.map(\.file)) {
            undoName += " in All \(reach.count) Widgets"
            toast = Self.widened(toast, count: reach.count, root: reach.root)
        }
        // A value this widget writes for itself must win over the shared file's (an @Include read after the block
        // written would still win): checked after the reload, and nothing is kept when it doesn't.
        let own = plan.filter(\.afterIncludes)
        let verify: ((Skin) -> Bool)? = own.isEmpty ? nil : { reloaded in
            own.allSatisfy { w in reloaded.sources.location(section: "Variables", key: w.key).map { reloaded.isOwnFile($0.file) } ?? false }
        }
        guard performEdit(undoName, files: plan.map(\.file) + extra.map(\.file), verify: verify, {
            try Self.apply(plan)
            try Self.apply(extra)
        }) else { return false }
        showToast(toast)
        return true
    }

    /// The toast when a value written for this widget alone could not win over a file other widgets share.
    static let overrideLostMessage = "This widget can't keep its own value here: a file other widgets share is read "
        + "after it. Choose All Widgets in Apply To, or change it in Code."

    /// How far a write to these files reaches beyond this widget: the most widgets reading one of them (nil when
    /// they are all this widget's own, or no other widget reads them).
    func sharedReach(_ files: [URL]) -> (count: Int, root: String)? {
        guard let skin else { return nil }
        let count = files.filter { !skin.isOwnFile($0) }.map { configsIncluding($0).count }.max() ?? 0
        return count > 1 ? (count, skin.rootConfig) : nil
    }

    /// "Bar color changed on 18 bars" → "Bar color changed in all 6 Deskset widgets".
    static func widened(_ toast: String, count: Int, root: String) -> String {
        let reach = "in all \(count) \(root) widgets"
        if let on = toast.range(of: " changed on ") { return String(toast[..<on.lowerBound]) + " changed " + reach }
        if toast.hasSuffix(" changed") { return toast + " " + reach }
        return toast + " — " + reach
    }

    /// Writes a new color everywhere this widget's own files write the literal color `old` — color options, Shape
    /// strings, gradients, inline settings — as one undo step (§8.1.1: the row shows the reach before the edit).
    /// `uses`: the options to rewrite (default: every option writing `old` now).
    @discardableResult
    func writeLiteralColor(_ old: RGBA, to new: RGBA, uses: [ValueUsageIndex.Use]? = nil, undoName: String,
                           toast: String) -> Bool {
        guard let skin, let found = uses ?? valueUsages(skin).literal(old)?.uses else { return false }
        let all = appliesToAllWidgets
        var writes: [KeyWrite] = []
        var seen: Set<String> = []
        var kept: [String] = []
        for use in found {
            guard let s = skin.section(named: use.section), let raw = s.fileOption(use.key),
                  let origin = s.fileOrigin(use.key) else { continue }
            let section: String
            switch origin {
            case .style(let look, _): section = look
            default: section = s.name
            }
            guard let defined = origin.location?.file ?? skin.sources.location(section: section)?.file,
                  let rewritten = ValueUsageIndex.replacingColor(old, with: new, in: raw, key: use.key) else { continue }
            var file = defined
            var afterIncludes = false
            if all, skin.isOwnFile(defined), ValueUsageIndex.isColorKey(use.key), skin.meter(named: section) == nil,
               let shared = skin.sharedDefinition(ofVariable: use.key, section: section),
               let sharedRaw = (try? TextDecoding.readFileDetectingEncoding(at: shared).text)
                .flatMap({ IniDocument.parse($0).section(named: section)?.value(forKey: use.key) }) {
                // Every widget, after this widget gave the look a color of its own: the shared look takes the new color
                // and this widget's own goes, so it follows the shared one again.
                guard seen.insert("\(shared.path)|\(section.lowercased())|\(use.key.lowercased())").inserted else { continue }
                writes.append(KeyWrite(file: shared, section: section, key: use.key, value: ColorText.format(new, like: sharedRaw)))
                writes.append(KeyWrite(file: defined, section: section, key: use.key, value: nil))
                continue
            }
            if !skin.isOwnFile(defined), !all {
                // A file other widgets share writes it (a look in @Resources): this widget's own .ini gets the look's
                // (or layer's) key, read later so it wins; a layer only the shared file defines stays.
                guard let local = skin.localTarget(section: section, key: use.key) else { kept.append(s.name); continue }
                file = local.file
                afterIncludes = section.caseInsensitiveCompare("Rainmeter") == .orderedSame
            }
            guard seen.insert("\(file.path)|\(section.lowercased())|\(use.key.lowercased())").inserted else { continue }
            writes.append(KeyWrite(file: file, section: section, key: use.key, value: rewritten, afterIncludes: afterIncludes))
        }
        guard !writes.isEmpty else {
            self.toast.show(kept.isEmpty ? "This color couldn't be changed here — change it in Code"
                                    : sharedNote(kept).trimmingCharacters(in: .whitespaces), error: true)
            return false
        }
        var undoName = undoName, toast = toast
        if all, let reach = sharedReach(writes.map(\.file)) {
            undoName += " in All \(reach.count) Widgets"
            toast = Self.widened(toast, count: reach.count, root: reach.root)
        }
        // A look's key written into this widget must win over the shared file's.
        let local = writes.filter { !all && skin.isOwnFile($0.file) && skin.meter(named: $0.section) == nil
            && !skin.isOwnFile(skin.sources.location(section: $0.section, key: $0.key)?.file ?? skin.fileURL) }
        let verify: ((Skin) -> Bool)? = local.isEmpty ? nil : { reloaded in
            local.allSatisfy { w in reloaded.sources.location(section: w.section, key: w.key).map { reloaded.isOwnFile($0.file) } ?? false }
        }
        guard performEdit(undoName, files: writes.map(\.file), verify: verify, { try Self.apply(writes) }) else {
            return false
        }
        showToast(toast + sharedNote(kept))
        return true
    }

    /// `perform`, except while the color panel's pick is being written (`commitColorEdit`): every write of one session
    /// in the panel is then one undo step (§7.4 "one undo step"), as long as nothing else changed those files in
    /// between and the step was not undone.
    func performEdit(_ name: String, files: [URL], verify: ((Skin) -> Bool)? = nil, _ body: () throws -> Void) -> Bool {
        guard inspectorState.colorCommitting, let session = inspectorState.colorSession else {
            return perform(name, files: files, message: nil, verify: verify, body)
        }
        if !flushCode() { return false }
        skin?.endPreview()
        do {
            let changes = try EditorFileChange.record(files, body)
            guard !changes.isEmpty else { return true }
            if let verify {
                if let skin { fileStamps = stamps(for: skin.sourceFiles) }
                refreshSkin()
                if let skin, !verify(skin) {
                    // Written, but it doesn't take effect: the files go back, and no undo step is made.
                    try EditorFileChange.restore(changes, undo: true)
                    if let skin = self.skin { fileStamps = stamps(for: skin.sourceFiles) }
                    refreshSkin()
                    toast.show(Self.overrideLostMessage, error: true)
                    return false
                }
            }
            // Folded into the session's step (its undo puts back what was there before the first pick) — not with a
            // redo waiting, which a new step clears and a folded one would leave to fail.
            if let step = session.step, window?.undoManager?.canRedo != true, step.merge(changes) {
            } else {
                let step = InspectorState.ColorStep(changes)
                session.step = step
                if let manager = window?.undoManager {
                    manager.registerUndo(withTarget: self) { target in
                        step.isSealed = true
                        target.restore(step.changes, name: name, undo: true)
                    }
                    manager.setActionName(name)
                }
            }
            if verify == nil {
                if let skin { fileStamps = stamps(for: skin.sourceFiles) }
                refreshSkin()
            }
            return true
        } catch {
            toast.show("Could not save: \(error)", error: true)
            NSSound.beep()
            return false
        }
    }

    /// The widget page's "Apply to": every widget sharing the file (true) or this widget only (false, the default).
    var appliesToAllWidgets: Bool {
        get { inspectorState.applyToAllWidgets.contains(config.lowercased()) }
        set {
            if newValue { inspectorState.applyToAllWidgets.insert(config.lowercased()) }
            else { inspectorState.applyToAllWidgets.remove(config.lowercased()) }
        }
    }

    // MARK: Picking a color (the color panel)

    /// Opens the color panel for a color control or a widget-page row: what is picked is shown at once (on every
    /// layer it will reach) and written after a short pause, or when the panel closes, as one undo step.
    func startColorEdit(_ edit: ColorEdit, current: RGBA?) {
        commitColorEdit()
        var edit = edit
        // A literal color: the options writing it now (after the first write they hold the color picked).
        if case .literal(let old, _, _) = edit.target, edit.literalUses.isEmpty, let skin {
            edit.literalUses = valueUsages(skin).literal(old)?.uses ?? []
        }
        inspectorState.colorEdit = edit
        inspectorState.colorEditValue = nil
        inspectorState.colorSession = InspectorState.ColorSession()
        if inspectorState.colorEditCloseObserver == nil {
            inspectorState.colorEditCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in self?.commitColorEdit() }
        }
        ScopedColorPicker.shared.open(for: self, color: current?.nsColor ?? .white)
    }

    /// Shows a picked color live and schedules its write (the self-tests call it directly).
    func previewColorEdit(_ rgba: RGBA) {
        guard let edit = inspectorState.colorEdit, let skin else { return }
        inspectorState.colorEditValue = rgba
        switch edit.target {
        case .property(let section, let key, let raw, let variable, _, let selection):
            let text = ColorText.format(rgba, like: skin.resolve(raw, in: skin.section(named: section), sectionVariables: false))
            let target = ScopeResolver(skin: skin, usages: valueUsages(skin)).target(section: section, key: key, selection: selection, variable: variable)
            switch target.scope {
            case .sharedValue(let name):
                skin.previewVariables([name: text])
            case .look(let look):
                for s in lookUsers(look, key: key) { skin.preview(section: s, [key: text]) }
            case .own:
                for s in target.sections { skin.preview(section: s, [key: text]) }
            }
        case .variables(let names, _, _):
            var values: [String: String] = [:]
            for name in names {
                let like = skin.inspectedVariables().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.raw
                values[name] = ColorText.format(rgba, like: like)
            }
            skin.previewVariables(values)
        case .literal(let old, _, _):
            for use in edit.literalUses {
                guard let raw = skin.section(named: use.section)?.fileOption(use.key),
                      let rewritten = ValueUsageIndex.replacingColor(old, with: rgba, in: raw, key: use.key) else { continue }
                skin.preview(section: use.section, [use.key: rewritten])
            }
        }
        canvas.needsDisplay = true
        inspectorState.colorEditTimer?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in self?.commitColorEdit() }
        RunLoop.main.add(timer, forMode: .default)
        inspectorState.colorEditTimer = timer
    }

    /// Writes the picked color now (nothing when nothing was picked). Writes of one session in the color panel are one
    /// undo step (`performEdit`).
    func commitColorEdit() {
        inspectorState.colorEditTimer?.invalidate()
        inspectorState.colorEditTimer = nil
        guard let edit = inspectorState.colorEdit, let rgba = inspectorState.colorEditValue, let skin else { return }
        inspectorState.colorEditValue = nil
        inspectorState.colorCommitting = true
        defer { inspectorState.colorCommitting = false }
        switch edit.target {
        case .property(let section, let key, let raw, let variable, let label, let selection):
            let text = ColorText.format(rgba, like: skin.resolve(raw, in: skin.section(named: section), sectionVariables: false))
            writeProperty(section: section, key: key, value: text, variable: variable, label: label, selection: selection)
        case .variables(let names, let role, let users):
            let values = names.map { name -> (String, String) in
                let like = skin.inspectedVariables().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.raw
                return (name, ColorText.format(rgba, like: like))
            }
            writeSharedValues(values, undoName: Self.colorUndoName(role),
                              toast: "\(Self.capitalizedFirst(role)) changed on \(usersPhrase(users))",
                              everywhere: edit.everywhere ? true : nil)
        case .literal(let old, let role, let users):
            if writeLiteralColor(old, to: rgba, uses: edit.literalUses, undoName: Self.colorUndoName(role),
                                 toast: "\(Self.capitalizedFirst(role)) changed on \(usersPhrase(users))") {
                // The same options hold the new color now: the next pick replaces that one.
                inspectorState.colorEdit?.target = .literal(rgba, role: role, users: users)
            } else {
                skin.endPreview()
            }
        }
    }

    /// The color panel closed: what was picked last is written, and the session ends.
    func finishColorEdit() {
        commitColorEdit()
        inspectorState.colorEdit = nil
        inspectorState.colorSession = nil
    }

    /// "Change Bar Color", "Change Background Panel Color".
    static func colorUndoName(_ role: String) -> String {
        role.lowercased().hasSuffix("color") ? "Change \(titleCase(role))" : "Change \(titleCase(role)) Color"
    }

    // MARK: Toast actions that widen an edit

    /// "Apply to All 16 Bars": the look gets the value and the selected layers' own keys go, in one step.
    func applyToLookAction(_ look: String, key: String, value: String, sections: [String], label: String) -> ToastAction? {
        guard let skin, let lookFile = skin.sources.location(section: look, key: key)?.file
                ?? skin.sources.location(section: look)?.file else { return nil }
        let users = lookUsers(look, key: key, includingOwn: true)
        let title: String
        if skin.isOwnFile(lookFile) {
            title = "Apply to All \(Self.titleCase(kindPhrase(users, definite: false)))"
        } else {
            let widgets = configsIncluding(lookFile).count
            // A look in a file several widgets share: its layers in all of them ("Apply to All 6 Widget Titles").
            let kind = LayerNaming.kindPlural(ValueUsageIndex.humanizedLook(look))
            title = widgets > 1 ? "Apply to All \(widgets) Widget \(Self.titleCase(kind))"
                : "Apply to All \(Self.titleCase(kindPhrase(users, definite: false)))"
        }
        return ToastAction(title) { [weak self] in
            guard let self, let skin = self.skin else { return }
            var writes = [KeyWrite(file: lookFile, section: look, key: key, value: value)]
            // Every user of the look with a value of its own lets it go (not only the selected ones): the button said
            // all of them follow.
            for s in self.lookUsers(look, key: key, includingOwn: true) {
                if let file = skin.ownDefinitionFile(section: s, key: key), skin.isOwnFile(file) {
                    writes.append(KeyWrite(file: file, section: skin.section(named: s)?.name ?? s, key: key, value: nil))
                }
            }
            let name = "Change \(Self.titleCase(label)) of \(Self.titleCase(self.kindPhrase(users, definite: false)))"
            guard self.perform(name, files: writes.map(\.file), message: nil, { try Self.apply(writes) }) else { return }
            self.showToast("Changed \(self.kindPhrase(users, definite: true))")
        }
    }

    /// "Change ‘Bar color’ Everywhere": the shared value takes the new value and the options written in its place go
    /// back to naming it (`restoring`), in one step.
    func changeEverywhereAction(variable: String, value: String, restoring: [KeyWrite]) -> ToastAction? {
        guard let skin, let usage = valueUsages(skin).variable(variable) else { return nil }
        let role = usage.role
        return ToastAction("Change ‘\(role)’ Everywhere") { [weak self] in
            self?.writeSharedValues([(variable, value)], undoName: "Change \(Self.titleCase(role))",
                                    toast: "\(Self.capitalizedFirst(role)) changed on \(self?.usersPhrase(usage.sections) ?? "")",
                                    extra: restoring)
        }
    }

    /// Shows a toast with its buttons (and remembers them, for the self-tests and the toolbar).
    func showToast(_ text: String, actions: [ToastAction] = []) {
        let undo = ToastAction("Undo") { [weak self] in self?.window?.undoManager?.undo() }
        toast.show(text, actions: actions + [undo])
    }

    /// The buttons of the toast showing now ("Apply to All 16 Bars", "Undo"; docs/editor-friendly.md §10).
    var toastActions: [ToastAction] { toast.shownActions }

    /// Clicks the button with this title on the toast showing now (self-tests: what clicking it does).
    @discardableResult
    func chooseToastAction(_ title: String) -> Bool {
        guard let button = toast.button(title) else { return false }
        button.performClick(nil)
        return true
    }

    // MARK: Who uses what

    /// Where the skin's shared values are used (`Skin.valueUsages()`), scanned once per state of the skin: its files
    /// (a skin object never reloads them), its previews and its variables' values — not once per update (a big
    /// widget takes a noticeable moment to scan).
    func valueUsages(_ skin: Skin) -> ValueUsageIndex {
        let key = "\(skin.isPreviewing)|\(skin.keyValueWrites)|\(skin.variableStamp)"
        if let cached = inspectorState.usageCache, cached.skin === skin, cached.key == key { return cached.index }
        let index = skin.valueUsages()
        inspectorState.usageCache = InspectorState.UsageCache(skin: skin, key: key, index: index)
        return index
    }

    /// The configs whose skins read a shared file (`Skin.configsIncluding`): the widget folder is walked once per
    /// editor, for every shared file at once.
    func configsIncluding(_ file: URL) -> [String] {
        guard let skin else { return [] }
        if inspectorState.includeMap == nil { inspectorState.includeMap = skin.includeMap() }
        return inspectorState.includeMap?.configs(including: file) ?? []
    }

    /// The theme a shared file is (`Skin.switchedInclude`), found once per editor.
    func theme(_ file: URL) -> Skin.SwitchedInclude? {
        guard let skin else { return nil }
        let key = file.standardizedFileURL.path
        if let cached = inspectorState.themeCache[key] { return cached }
        let found = skin.switchedInclude(file)
        inspectorState.themeCache[key] = found
        return found
    }

    // MARK: Words for the reach

    /// The layers (meters) using a look that take `key` from it (or, `includingOwn`, every user of the look).
    func lookUsers(_ look: String, key: String, includingOwn: Bool = false) -> [String] {
        guard let skin else { return [] }
        return skin.meters.filter { m in
            guard OptionValue.list(m.rawOption("MeterStyle") ?? "").contains(where: { $0.caseInsensitiveCompare(look) == .orderedSame })
            else { return false }
            if includingOwn { return true }
            if case .style(let name, _)? = m.fileOrigin(key) { return name.caseInsensitiveCompare(look) == .orderedSame }
            return false
        }.map(\.name)
    }

    /// The one look all `sections` take `key` from (nil when they don't share one).
    func sharedLook(of sections: [String], key: String) -> String? {
        guard let skin else { return nil }
        var found: String?
        for s in sections {
            guard let section = skin.section(named: s) else { return nil }
            // The value came from the look, or the look sets it too (a layer's own value hides it).
            let options = skin.inspectedOptions(ofSection: s).first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
            var look: String?
            if case .style(let name, _)? = section.fileOrigin(key) { look = name } else { look = options?.shadowedStyles.first }
            guard let look else { return nil }
            if let found, found.caseInsensitiveCompare(look) != .orderedSame { return nil }
            found = look
        }
        return found
    }

    /// "16 bars", "3 texts", "9 layers" (`definite`: "the 16 bars"; one layer: its name).
    func kindPhrase(_ sections: [String], definite: Bool) -> String {
        guard let skin else { return "\(sections.count) layers" }
        let meters = sections.compactMap { skin.meter(named: $0) }
        if meters.count == 1 { return displayName(ofSection: meters[0].name) }
        let kinds = Set(meters.map { LayerNaming.kindNoun($0) })
        let noun = kinds.count == 1 ? Self.plural(kinds.first ?? "layer", meters.count) : Self.plural("layer", meters.count)
        let count = meters.isEmpty ? sections.count : meters.count
        return (definite ? "the " : "") + "\(count) \(noun)"
    }

    /// The layers a change of these sections reaches (`ValueUsageIndex.reach`): the layers among them, then those
    /// that follow a data item among them (the peak marker is placed by a formula using Left).
    func layersReached(_ sections: [String]) -> [String] {
        guard let skin else { return [] }
        return valueUsages(skin).reach(sections).filter { skin.meter(named: $0) != nil }
    }

    /// Who uses a value, as the widget page says it: "18 bars", "“Audio”", "16 bars and “48 Hz”", "10 layers" (the
    /// layers it reaches, `layersReached`).
    func usersPhrase(_ sections: [String], atLeast: Bool = false) -> String {
        guard let skin else { return "" }
        let meters = layersReached(sections).compactMap { skin.meter(named: $0) }
        let prefix = atLeast ? "at least " : ""
        guard !meters.isEmpty else {
            if sections.isEmpty { return "nothing yet" }
            // [Rainmeter]: the widget's own settings and actions.
            return sections.contains { skin.measure(named: $0) != nil } ? "live data only" : "the widget"
        }
        if meters.count == 1 { return prefix + displayName(ofSection: meters[0].name) }
        // A run of one kind and one or two others: "16 bars and “48 Hz”".
        var byKind: [String: [Meter]] = [:]
        for m in meters { byKind[LayerNaming.kindNoun(m), default: []].append(m) }
        if let main = byKind.max(by: { $0.value.count < $1.value.count }), byKind.count == 2, meters.count - main.value.count <= 2,
           main.value.count >= 3 {
            let others = meters.filter { LayerNaming.kindNoun($0) != main.key }
            // One other is named ("16 bars and “48 Hz”"); two are counted by kind ("7 texts and 2 shapes").
            let rest = others.count == 1 ? displayName(ofSection: others[0].name)
                : "\(others.count) \(Self.plural(LayerNaming.kindNoun(others[0]), others.count))"
            return prefix + "\(main.value.count) \(Self.plural(main.key, main.value.count)) and " + rest
        }
        let noun = byKind.count == 1 ? Self.plural(byKind.keys.first ?? "layer", meters.count) : Self.plural("layer", meters.count)
        return prefix + "\(meters.count) \(noun)"
    }

    /// What one section is called in a toast or an undo name: a layer or data item by its name; the widget's own
    /// sections and looks in words (never a section name).
    func reachWords(_ section: String) -> String {
        guard let skin else { return displayName(ofSection: section) }
        if skin.meter(named: section) != nil || skin.measure(named: section) != nil { return displayName(ofSection: section) }
        switch section.lowercased() {
        case "variables": return "the shared values"
        case "rainmeter": return "the widget"
        case "metadata": return "the widget's details"
        default: return "the \(ValueUsageIndex.humanizedLook(section).lowercased()) look"
        }
    }

    /// "Bar" → "bars", "Text" → "texts", "Color block" → "color blocks" (1 → the singular, lowercased).
    static func plural(_ kind: String, _ count: Int) -> String {
        count == 1 ? kind.lowercased() : LayerNaming.kindPlural(kind)
    }

    /// "bar color" → "Bar Color" (short words stay lowercase inside: "Empty Part of Bars").
    static func titleCase(_ s: String) -> String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "for", "from", "in", "of", "on", "or", "the", "to", "with"]
        return s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, word in
            let w = String(word)
            if w.hasPrefix("“") || w.contains(where: { $0.isUppercase }) && w.count > 1 && w.dropFirst().contains(where: { $0.isUppercase }) {
                return w
            }
            if i > 0, small.contains(w.lowercased()) { return w.lowercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first, first != "“" else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// A number typed over a linked size keeps its link (§7.3): `#Left#` with 20 typed (Left = 14) is written
    /// `(#Left# + 6)`. Anything else is written as typed.
    func linkedNumber(_ value: String, variable: String?, key: String, in skin: Skin) -> String {
        guard let variable, ValueUsageIndex.isSizeKey(key), ShapeSpec.index(ofOption: key) == nil,
              let typed = Double(value.trimmingCharacters(in: .whitespaces)),
              let current = skin.variable(variable).flatMap(OptionValue.number) else { return value }
        return GeometryEdit.offset("#\(variable)#", by: typed - current).replacingOccurrences(of: "(#\(variable)#)", with: "#\(variable)#")
    }

    // MARK: Image files

    /// How an image file is referred to from the skin: relative to the skin folder, `#@#…` inside @Resources, or —
    /// for a file elsewhere — a copy in @Resources/Images (`copy` says where to put it).
    static func imageReference(for url: URL, skin: Skin) -> (value: String, copy: URL?) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        func relative(to folder: URL) -> String? {
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
        }
        if let inside = relative(to: skin.resourcesDirectory) { return ("#@#" + inside, nil) }
        if let inside = relative(to: skin.directory) { return (inside, nil) }
        let folder = skin.resourcesDirectory.appendingPathComponent("Images", isDirectory: true)
        let name = url.lastPathComponent
        var destination = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        // An identical file already copied is reused; a different one with the same name gets a number.
        while FileManager.default.fileExists(atPath: destination.path),
              (try? Data(contentsOf: destination)) != (try? Data(contentsOf: url)) {
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return ("#@#Images/" + destination.lastPathComponent, destination)
    }

    /// Uses an image file for an image option (copied into @Resources when it is outside the skin).
    func useImageFile(_ url: URL, section: String, key: String, variable: String?, label: String) {
        guard let skin else { return }
        let reference = Self.imageReference(for: url, skin: skin)
        if let copy = reference.copy, !FileManager.default.fileExists(atPath: copy.path) {
            do {
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                toast.show("Could not copy the image: \(error.localizedDescription)", error: true)
                return
            }
        }
        writeProperty(section: section, key: key, value: reference.value, variable: variable, label: label)
    }

    /// Asks for an image file (NSOpenPanel) for an image option.
    func chooseImageFile(section: String, key: String, variable: String?, label: String) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Pictures from elsewhere are copied into the widget's shared files."
        panel.prompt = "Use Picture"
        panel.directoryURL = skin?.directory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.useImageFile(url, section: section, key: key, variable: variable, label: label)
        }
    }
}

/// Where an inspector edit of a property is written.
struct WriteTarget: Equatable {
    /// Who the change reaches (docs/editor-friendly.md §7.5).
    enum Scope: Equatable {
        /// The shared value itself (a `[Variables]` entry): every option using it follows.
        case sharedValue(String)
        /// The look (MeterStyle) the value comes from: every layer using the look follows.
        case look(String)
        /// The selected layers' (or data items') own sections.
        case own
    }

    var scope: Scope
    /// The section and key written (for `.own` with several sections selected, the first of `sections`).
    var section: String
    var key: String
    /// The file that is written (for `.own`, the first section's).
    var file: URL
    /// `.own`: every section written, each its own key; otherwise the one section written.
    var sections: [String]

    init(scope: Scope, section: String, key: String, file: URL, sections: [String]? = nil) {
        self.scope = scope
        self.section = section
        self.key = key
        self.file = file
        self.sections = sections ?? [section]
    }
}

/// Decides where an edit of a property of the selection is written (docs/editor-friendly.md §7.5): the narrowest
/// place that covers exactly what is selected.
/// 1. The shared value (variable), when the value is exactly `#Var#`, the selection is every layer (and data item) of
///    this widget using Var, and Var is defined in this widget's own files.
/// 2. The look, when the value comes from look L, the selection is every layer taking the option from L, and L is
///    defined in this widget's own files.
/// 3. Otherwise each selected section's own key.
/// A section that is not a layer or a data item (`[Variables]`, `[Rainmeter]`, a look opened itself) is written where
/// the option is defined, as before.
struct ScopeResolver {
    let skin: Skin
    /// The skin's `valueUsages()` when the caller has it already.
    var usages: ValueUsageIndex? = nil

    /// `section`/`key`: the property as the inspector shows it; `selection`: the sections the edit is meant for;
    /// `variable`: the value is this one `#Var#` (as the control shows it).
    func target(section: String, key: String, selection: [String], variable: String? = nil) -> WriteTarget {
        let selected = selection.isEmpty ? [section] : selection
        let wanted = Set(selected.map { $0.lowercased() })
        // Not a layer or data item: where the option is defined (the variable itself on the [Variables] page).
        guard skin.meter(named: section) != nil || skin.measure(named: section) != nil else {
            let defined = skin.editTarget(section: section, key: key)
            return WriteTarget(scope: .own, section: defined.section, key: key, file: defined.file)
        }
        if let variable {
            let usage = (usages ?? skin.valueUsages()).variable(variable)
            let users = Set((usage?.sections ?? []).map { $0.lowercased() })
            let defined = skin.sources.location(section: "Variables", key: variable)?.file
            if users == wanted, let defined, skin.isOwnFile(defined) {
                return WriteTarget(scope: .sharedValue(variable), section: "Variables", key: variable, file: defined)
            }
        }
        if let look = commonLook(of: selected, key: key) {
            let users = skin.meters.filter { m in
                if case .style(let name, _)? = m.fileOrigin(key) { return name.caseInsensitiveCompare(look) == .orderedSame }
                return false
            }
            let file = skin.sources.location(section: look, key: key)?.file ?? skin.sources.location(section: look)?.file
            if Set(users.map { $0.name.lowercased() }) == wanted, let file, skin.isOwnFile(file) {
                return WriteTarget(scope: .look(look), section: look, key: key, file: file)
            }
        }
        let names = selected.map { skin.section(named: $0)?.name ?? $0 }
        let first = names.first ?? section
        return WriteTarget(scope: .own, section: first, key: key, file: skin.ownTarget(section: first, key: key).file,
                           sections: names)
    }

    /// The look every selected section takes `key` from (nil when one writes it itself or they differ).
    func commonLook(of sections: [String], key: String) -> String? {
        var found: String?
        for s in sections {
            guard let section = skin.section(named: s), case .style(let look, _)? = section.fileOrigin(key) else { return nil }
            if let found, found.caseInsensitiveCompare(look) != .orderedSame { return nil }
            found = look
        }
        return found
    }
}
