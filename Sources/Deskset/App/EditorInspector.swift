import AppKit
import DesksetCore

/// The right side of the skin editor. What it shows follows the selection, like a design app's inspector
/// (docs/editor-friendly.md §7–8):
/// - nothing selected: the widget page (EditorWidgetPage.swift);
/// - a layer, a group of repeated layers, several layers (EditorLayerPages.swift) or a live data item
///   (EditorDataPage.swift): an identity strip, then calm cards of 3–5 essential settings, each ending in one
///   "More {Kind} Options" disclosure (EditorSelectionPages.swift).
///
/// This file holds what every page is built from: the rebuild and its inputs, and one control per value kind in a
/// label | control grid (docs/editor-design.md §3; the controls are in EditorControls.swift). Values are never replaced
/// silently: an invalid value stays selected with a warning; a value that is a `#Variable#` or a formula is linked
/// (its tag says to what).
extension InspectorWindowController {
    // MARK: Building

    /// Builds the inspector for the selection. With `steps` (the editor opening), the page's parts that `addPart`
    /// adds are built in steps of their own and the rebuild ends in a last step; a later rebuild drops the parts still
    /// waiting.
    func rebuildInspector(in steps: MainThreadSteps? = nil) {
        let state = inspectorState
        // A text field being edited keeps its typed text across the rebuild (see `restoreInspectorFocus`); another
        // control keeps the focus by its identifier.
        let fieldFocus = focusedInspectorField()
        // The text of live data's token field (a text view of its own, not a field editor) is kept the same way.
        let tokenFocus = focusedTokenField()
        let focus = fieldFocus == nil && tokenFocus == nil ? focusedInspectorIdentifier() : nil
        inspectorRebuildCount += 1
        state.generation += 1
        state.isRebuilding = true
        defer { state.isRebuilding = false }
        // The field being edited ends its editing now, while nothing it does is written: it is about to be taken out,
        // and its typed text goes on in the rebuilt field (below). Left to AppKit, the editing would end at the next
        // change of focus — and write to what the old field edited.
        if fieldFocus != nil || tokenFocus != nil { window?.makeFirstResponder(nil) }
        for v in inspectorStack.arrangedSubviews { inspectorStack.removeArrangedSubview(v); v.removeFromSuperview() }
        headerSubtitle = nil
        currentLabels = [:]
        liveValueLabel = nil
        liveStringLabel = nil
        liveRange = nil
        dataLabels = [:]
        fieldEdits = [:]
        swatchEdits = [:]
        pageState.severalSwatches.removeAllObjects()
        addKeyField = nil
        addValueField = nil
        state.liveUpdates = []
        state.preparedParts = []
        canvas.relatedNames = []
        let finish = { [weak self] in
            guard let self else { return }
            // Every field that refuses a value says why; none writes when it is taken out by the next rebuild.
            self.prepareInspectorFields(in: self.inspectorStack)
            // What a layer shows never widens the pane (and the canvas with it).
            for view in self.inspectorStack.arrangedSubviews { self.yieldWidthOnce(view) }
            // A shape color being picked whose swatch is gone (another layer) no longer receives the color panel.
            ShapeColorPicker.shared.inspectorRebuilt(self)
            self.startLiveUpdates()
            self.lastInspectorInputs = self.inspectorInputs()
            if let fieldFocus {
                self.restoreInspectorFocus(fieldFocus)
            } else if let tokenFocus {
                self.restoreTokenFieldFocus(tokenFocus)
            } else if let focus {
                onNextTurn { [weak self] in self?.restoreFocus(focus) }
            }
        }
        state.partSteps = steps
        namingShared { buildInspectorPage() }
        state.partSteps = nil
        guard let steps else { return finish() }
        let generation = state.generation
        steps.add("inspector: done") { [weak self] in
            guard let self, self.inspectorState.generation == generation else { return }
            self.inspectorState.isRebuilding = true
            defer { self.inspectorState.isRebuilding = false }
            finish()
        }
    }

    /// The page for the selection: the widget, one layer, several layers, a group, live data, a style or one of the
    /// widget's own sections.
    private func buildInspectorPage() {
        guard let skin else {
            add(emptyState("This widget isn't loaded."))
            return
        }
        if isMultiSelection {
            if let series = groupSeries(for: selectedMeters, in: skin) { groupPage(series, skin: skin) } else { severalPage(skin) }
            return
        }
        guard let name = selectedSection else {
            skinOverview(skin)
            return
        }
        switch selectedKind {
        case .meter?:
            if let m = skin.meter(named: name) { meterPage(m, skin: skin) }
        case .measure?:
            if let m = skin.measure(named: name) { dataPage(m, skin: skin) }
        case .variables?, .rainmeter?, .metadata?:
            widgetSectionPage(name, kind: selectedKind, skin: skin)
        default:
            styleInspector(name, skin: skin)
        }
    }

    /// Runs `body` with the naming of the edited skin's layers and data shared (`LayerNaming.sharingWork`): building a
    /// page names every data item for each Shows menu, and each name looks at all of them.
    func namingShared<T>(_ body: () -> T) -> T {
        guard let skin else { return body() }
        return LayerNaming.sharingWork(for: skin, body)
    }

    /// Adds a part of the page that `make` builds: at once, or — in a rebuild made in steps — in a step of its own
    /// (`label` names it in the stall log), unless a later rebuild came first.
    func addPart(_ label: String, _ make: @escaping () -> NSView?) {
        let state = inspectorState
        guard let steps = state.partSteps else {
            if let view = make() { add(view) }
            return
        }
        let generation = state.generation
        steps.add("inspector: \(label)") { [weak self] in
            guard let self, state.generation == generation else { return }
            state.isRebuilding = true
            defer { state.isRebuilding = false }
            guard let view = self.namingShared(make) else { return }
            self.add(view)
            // Ready to use at once, before the rest of the page is built.
            self.prepareInspectorFields(in: view)
            self.yieldWidthOnce(view)
        }
    }

    /// A card whose rows are parts of their own: `make` builds the card with its first rows and returns the makers of
    /// the others, which are added under them — at once, or each in a step of its own (see `addPart`).
    func addCard(_ label: String, _ make: @escaping () -> (card: EditorCard, rows: [() -> NSView])) {
        let state = inspectorState
        guard let steps = state.partSteps else {
            let (card, rows) = make()
            for row in rows { card.append(row()) }
            return add(card)
        }
        let generation = state.generation
        steps.add("inspector: \(label)") { [weak self] in
            guard let self, state.generation == generation else { return }
            state.isRebuilding = true
            defer { state.isRebuilding = false }
            let (card, rows) = self.namingShared(make)
            self.add(card)
            self.prepareInspectorFields(in: card)
            self.yieldWidthOnce(card)
            for (i, row) in rows.enumerated() {
                steps.add("inspector: \(label) \(i + 1)") { [weak self] in
                    guard let self, state.generation == generation else { return }
                    state.isRebuilding = true
                    defer { state.isRebuilding = false }
                    let view = self.namingShared(row)
                    card.append(view)
                    // As the card got when it came: its rows are not the stack's (`yieldWidthOnce`).
                    self.prepareInspectorFields(in: view)
                    EditorStyle.yieldWidth(view)
                }
            }
        }
    }

    /// The fields in `root` (and `root` itself): one that refuses a value says why, and none writes while the
    /// inspector is rebuilt (it is being taken out).
    func prepareInspectorFields(in root: NSView) {
        let state = inspectorState
        func matching(_ predicate: (NSView) -> Bool) -> [NSView] {
            (predicate(root) ? [root] : []) + root.subviewsMatching(predicate)
        }
        for case let field as ValueField in matching({ $0 is ValueField }) {
            if field.onInvalid == nil { field.onInvalid = { [weak self] problem in self?.toast.show(problem, error: true) } }
            field.isSuspended = { [weak state] in state?.isRebuilding == true }
        }
        for case let combo as ValueComboBox in matching({ $0 is ValueComboBox }) {
            combo.isSuspended = { [weak state] in state?.isRebuilding == true }
        }
    }

    /// `EditorStyle.yieldWidth` for an arranged view of the inspector, once: it lowers priorities from where they are,
    /// so a second time would lower them again (a part built in a step is readied then, the rest when the page is done).
    func yieldWidthOnce(_ view: NSView) {
        guard inspectorState.preparedParts.insert(ObjectIdentifier(view)).inserted else { return }
        EditorStyle.yieldWidth(view)
    }

    /// Everything the inspector is built from, as text (nil without a skin): the selection, the rows of the selected
    /// section (values that follow live data — section variables — left out: the live labels update those), the
    /// sections, variables and styles the menus and links list, and the inspector's own open disclosures. After a
    /// refresh that changed none of it the inspector is kept as it is (`reloadDetail`).
    func inspectorInputs() -> String? {
        guard let skin else { return nil }
        var lines: [String] = []
        func add(_ parts: [Any]) { lines.append(parts.map { "\($0)" }.joined(separator: "\u{1F}")) }
        func addRows(_ tag: String, _ rows: [Row]) {
            for r in rows {
                add([tag, r.key, r.raw, r.raw.contains("[") ? "" : r.resolved, r.source, r.sourceTip, "\(r.style)"])
            }
        }
        add(["selection", selectedSection ?? "", selectedKind.map { "\($0)" } ?? "", selectedMeters.joined(separator: ","),
             backSection ?? ""])
        add(["state", app.state.editor.showIniNames, advancedOpen, revealedGroups.sorted().joined(separator: ","),
             inspectorState.disclosures.sorted().joined(separator: ","),
             inspectorState.expandedShapes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
             inspectorState.insetLinks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
             inspectorScroll.scrollerStyle.rawValue])
        for item in allItems { add(["section", item.title, item.kind.map { "\($0)" } ?? "", item.detail]) }
        for v in skin.inspectedVariables() { add(["variable", v.name, v.raw, v.current, v.location?.description ?? ""]) }
        add(["issues"] + skin.issues)
        add(["fonts"] + skin.settings.localFonts)
        addRows("row", rows)
        // The selection pages: locks, the layers cut off, the nudge hint's first selections.
        add(["pages", (app.state.editor.editorLocks[config.lowercased()] ?? []).sorted().joined(separator: ","),
             app.state.editor.unlockedBackgrounds.contains(config.lowercased()), pageState.selections > 3,
             (isMultiSelection ? selectedMeters : selectedSection.map { [$0] } ?? []).filter(isLayerCutOff).joined(separator: ",")])
        if isMultiSelection {
            for name in selectedMeters {
                if let m = skin.meter(named: name) {
                    add(["layer", m.name, m.type, m.frame.width, m.frame.height, m.hidden])
                    addRows("layer-row", self.rows(of: m.name, kind: .meter))
                }
            }
        } else if let name = selectedSection {
            add(["header", skin.sources.location(section: selectedKind == .variables ? "Variables" : name)?.description ?? ""])
            switch selectedKind {
            case .meter?:
                // (The sizes and positions in effect follow live: `positionCard`.)
                if let m = skin.meter(named: name) { add(["meter", m.type, m.hidden] + m.measures.map(\.name)) }
            case .measure?:
                if let m = skin.measure(named: name) {
                    let users = self.users(of: m, in: skin)
                    add(["measure", m.type, users.widget, users.runsActions] + users.layers + users.data)
                    if let parent = m.rawOption("Parent") { addRows("parent", self.rows(of: parent, kind: .measure)) }
                }
            case .other?, nil:
                add(["style users"] + Self.styleUsers(name, in: skin))
            default:
                break
            }
        } else {
            addRows("skin", self.rows(of: "Rainmeter", kind: .rainmeter))
            addRows("about", self.rows(of: "Metadata", kind: .metadata))
            add(["skin", skin.width, skin.height, skin.meters.count, skin.measures.count,
                 skin.sources.location(section: "Rainmeter")?.description ?? ""])
            for style in allItems where style.kind == .other {
                add(["style", style.title, Self.styleUsers(style.title, in: skin).count])
            }
            for line in widgetPageInputs() { add(["widget", line]) }
        }
        return lines.joined(separator: "\n")
    }

    func add(_ view: NSView) {
        inspectorStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor, constant: -32).isActive = true
    }

    /// Rebuilds without jumping: the scroll position stays (opening a group, a disclosure, a shape).
    func rebuildKeepingScroll() {
        let origin = inspectorScroll.contentView.bounds.origin
        rebuildInspector()
        inspectorScroll.layoutSubtreeIfNeeded()
        inspectorScroll.contentView.scroll(to: origin)
        inspectorScroll.reflectScrolledClipView(inspectorScroll.contentView)
    }

    /// Width of the control column of a card grid (for wrapping warnings and checkbox titles, fitting segments): the
    /// column at the pane's minimum width, never the live width, so the inspector's content does not depend on how
    /// wide the pane happened to be and cannot widen it.
    var inspectorControlWidth: CGFloat { EditorStyle.inspectorControlWidth(scrollerStyle: inspectorScroll.scrollerStyle) }

    /// The identifier of the inspector control that has the keyboard focus (a text field being edited, too).
    func focusedInspectorIdentifier() -> String? {
        var responder = window?.firstResponder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor { responder = editor.delegate as? NSView }
        guard let view = responder, view.isDescendant(of: inspectorStack) else { return nil }
        return view.identifier?.rawValue
    }

    /// Gives the focus back to the control with the same identifier after a rebuild.
    func restoreFocus(_ identifier: String) {
        // Only while nothing else took the focus (removing the focused field leaves it with the window).
        guard let window, window.firstResponder === window,
              let view = inspectorStack.findSubview(where: { $0.identifier?.rawValue == identifier }),
              view.acceptsFirstResponder else { return }
        window.makeFirstResponder(view)
    }

    /// Updates the labels that follow live values (formula results, format previews, pill values) twice a second.
    func startLiveUpdates() {
        let state = inspectorState
        state.liveTimer?.invalidate()
        state.liveTimer = nil
        guard !state.liveUpdates.isEmpty else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak state] _ in state?.liveUpdates.forEach { $0() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        state.liveTimer = timer
    }

    func emptyState(_ text: String) -> NSView {
        let icon = NSImageView(image: EditorStyle.image("square.dashed", size: 28, weight: .light) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        let label = EditorStyle.label(text, size: 13, color: .secondaryLabelColor)
        let stack = EditorStyle.vstack([icon, label], spacing: 10)
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 60, left: 0, bottom: 0, right: 0)
        return stack
    }

    // MARK: Headers

    func header(title: String, subtitle: String, symbol: String, location: IniSourceLocation?,
                styles: [String] = []) -> NSView {
        let badge = NSImageView(image: EditorStyle.image(symbol, size: 15, weight: .medium) ?? NSImage())
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 9
        badge.layer?.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 34).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let titleLabel = EditorStyle.label(title, size: 17, weight: .semibold)
        let subtitleLabel = EditorStyle.label(subtitle, size: 11.5, color: .secondaryLabelColor)
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.cell?.wraps = true
        subtitleLabel.lineBreakMode = .byWordWrapping
        headerSubtitle = subtitleLabel
        var texts: [NSView] = [titleLabel, subtitleLabel]
        var flow: FlowView?
        if !styles.isEmpty {
            // The layer's shared styles, wrapping: click one to open it.
            let f = FlowView()
            f.spacing = 4
            f.rowSpacing = 2
            let caption = EditorStyle.label("Style", size: 11, color: .tertiaryLabelColor)
            f.addSubview(caption)
            for s in styles { f.addSubview(linkButton(s, section: s)) }
            texts.append(f)
            flow = f
        }
        if let location {
            let section = selectedSection.map { "[\($0)] · " } ?? ""
            let link = NSButton(title: "\(section)\(location.file.lastPathComponent):\(location.line)", target: self,
                                action: #selector(openInEditor))
            link.isBordered = false
            link.font = .systemFont(ofSize: 11)
            link.contentTintColor = .controlAccentColor
            link.image = EditorStyle.image("arrow.up.forward", size: 9, weight: .semibold)
            link.imagePosition = .imageTrailing
            link.toolTip = "Show \(location.file.lastPathComponent) in the code editor"
            texts.append(link)
        }
        var column: [NSView] = []
        if let back = backSection, selectedKind == .other {
            let button = NSButton(title: "‹ \(back)", target: self, action: #selector(goBack))
            button.isBordered = false
            button.font = .systemFont(ofSize: 11.5, weight: .medium)
            button.contentTintColor = .controlAccentColor
            column.append(button)
        }
        let textStack = EditorStyle.vstack(texts, spacing: 2)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = EditorStyle.hstack([badge, textStack], spacing: 12, alignment: .top)
        row.distribution = .fill
        column.append(row)
        let stack = EditorStyle.vstack(column, spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 4, right: 0)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2).isActive = true
        flow?.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        return stack
    }

    @objc func goBack() {
        if let back = backSection { select(section: back) }
    }

    /// Small link-like buttons (styles of a layer, layers of a data source).
    func linkButton(_ title: String, symbol: String? = nil, section: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(linkClicked(_:)))
        b.isBordered = false
        b.font = .systemFont(ofSize: 11.5, weight: .medium)
        b.contentTintColor = .controlAccentColor
        if let symbol { b.image = EditorStyle.image(symbol, size: 10); b.imagePosition = .imageLeading }
        b.identifier = NSUserInterfaceItemIdentifier(section)
        return b
    }

    @objc func linkClicked(_ sender: NSButton) {
        if let section = sender.identifier?.rawValue { select(section: section) }
    }

    /// Shows a defining line in the code editor the user chose — or the one chosen for this window ("Edit in
    /// Built-in Editor"): the built-in one reveals it beside the canvas (`showCode`).
    func showInCode(_ location: IniSourceLocation?) {
        guard let skin else { return }
        let l = location ?? IniSourceLocation(file: skin.fileURL, line: 1)
        showCode(file: l.file, line: l.line)
    }

    func cardNote(_ text: String) -> NSTextField {
        let l = EditorStyle.label(text, size: 11, color: .tertiaryLabelColor)
        l.maximumNumberOfLines = 3
        l.cell?.wraps = true
        l.lineBreakMode = .byWordWrapping
        return l
    }

    // MARK: Cards of the widget page

    /// "+ Background  + Interaction": groups with nothing set yet, one click away (the widget page's cards).
    func moreGroups(_ groups: [EditorSchema.Group], section: String) -> NSView {
        let buttons: [NSView] = groups.map { g in
            let b = NSButton(title: g.title, target: self, action: #selector(revealGroup(_:)))
            b.image = EditorStyle.image("plus", size: 10, weight: .semibold)
            b.imagePosition = .imageLeading
            b.bezelStyle = .inline
            b.controlSize = .small
            b.identifier = NSUserInterfaceItemIdentifier("\(section)/\(g.title)")
            return b
        }
        let flow = FlowView()
        for b in buttons { flow.addSubview(b) }
        let label = EditorStyle.label("Add", size: 11, weight: .semibold, color: .secondaryLabelColor)
        let stack = EditorStyle.vstack([label, flow], spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        flow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4).isActive = true
        return stack
    }

    @objc func revealGroup(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        revealedGroups.insert(id)
        rebuildKeepingScroll()
    }

    /// Why a typed position or size cannot be written (nil when it can: a number, a formula, a variable, relative).
    static func geometryProblem(_ value: String) -> String? {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || LenientNumberFormatter.isExpression(t) { return nil }
        var number = t
        if let last = number.last, last == "r" || last == "R" { number.removeLast() }
        return number.isEmpty || Double(number) != nil ? nil : "“\(t)” is not a number"
    }

    /// Writes a position or size into the meter's own section (empty: removes it, so it is automatic again).
    func commitGeometry(_ meter: String, key: String, value: String) {
        guard !inspectorState.isRebuilding else { return }
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            return resetProperty(section: meter, key: key, label: key)
        }
        let who = displayName(ofSection: meter)
        commitPlainly([Edit(section: meter, key: key, value: value, own: true)],
                      name: (key == "X" || key == "Y" ? "Move " : "Resize ") + who,
                      message: (key == "X" || key == "Y" ? "Moved " : "Resized ") + who)
    }

    // MARK: A data source

    /// A measure's value in a few characters (the live labels of the window).
    func liveText(_ m: Measure) -> String {
        let s = m.stringValue
        let n = EditorStyle.number(m.value)
        return s == n || s.isEmpty ? n : "\(s.prefix(24))"
    }

    // MARK: A style

    /// A look (a shared style section, selected from the code): who uses it, and its lines.
    func styleInspector(_ name: String, skin: Skin) {
        let users = Self.styleUsers(name, in: skin)
        let crumbs: [(title: String, action: () -> Void)] = [(widgetName(skin), { [weak self] in self?.canvasSelectionChanged([]) })]
            + (backSection.map { back in [(displayName(ofSection: back), { [weak self] in self?.select(section: back) })] } ?? [])
        add(identityStrip(title: "A look", sentence: users.count > 1 ? "Shared with \(countedLayers(users, in: skin)). Changes here apply to all of them."
                            : "Changes here apply to every layer that uses it.",
                          picture: stripPicture(image: layerPicture(users, in: skin), symbol: "square.on.square"), crumbs: crumbs,
                          buttons: [], lines: detailsLine(section: name, looks: [], skin: skin).map { [$0] } ?? []))
        if !users.isEmpty {
            let views: [NSView] = users.map { u in
                EditorStyle.hstack([linkButton(displayName(ofSection: u), section: u), EditorStyle.spacer()], spacing: 6)
            }
            add(EditorCard(title: "Used by", views: views))
        }
        add(otherOptionsCard(section: name, rows: rows, groups: [], open: true, title: "Options"))
    }

    // MARK: Schema cards

    /// Current values by option name for the schema's conditions (resolved; nil when not set).
    func valueLookup(_ rows: [Row]) -> (String) -> String? {
        { key in rows.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.resolved }
    }

    /// The row of a property (its documented key, else an older spelling).
    func row(for p: EditorSchema.Property, in rows: [Row]) -> Row? {
        for key in [p.key] + p.legacyKeys {
            if let r = rows.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { return r }
        }
        return nil
    }

    /// A card for one (visible) schema group: nil when none of its options is set (unless `force` or the user opened
    /// it). `groups` are all of the section's groups (defaults and conditions refer to them).
    func groupCard(_ group: EditorSchema.Group, groups: [EditorSchema.Group], section: String, rows: [Row],
                   force: Bool) -> NSView? {
        let full = groups.first { $0.title == group.title } ?? group
        let set = full.properties.contains { row(for: $0, in: rows) != nil }
            || rows.contains { r in EditorSchema.numberedProperty(r.key, in: [full]).map { $0.index > 1 } ?? false }
        let id = "\(section)/\(group.title)"
        guard set || force || revealedGroups.contains(id) else { return nil }
        // A card stays once shown, so it does not vanish when its last value is removed.
        if set { revealedGroups.insert(id) }
        if group.properties.contains(where: { $0.kind == .shapes }) {
            let editor = ShapeEditorView(controller: self, meter: section)
            return EditorCard(title: group.title, views: [editor])
        }
        var items: [InspectorRow] = []
        // Long lists of actions (Interaction): the ones in use and the usual three; the rest one click away.
        let actions = group.properties.filter { $0.kind == .action }
        let foldActions = actions.count > 6
        let actionsKey = "\(section.lowercased())/\(group.title)/actions"
        let actionsOpen = inspectorState.disclosures.contains(actionsKey)
        let usual: Set<String> = ["leftmouseupaction", "mouseoveraction", "mouseleaveaction"]
        var folded = 0
        for p in group.properties {
            let r = row(for: p, in: rows)
            if foldActions, p.kind == .action, r == nil, !usual.contains(p.key.lowercased()), !actionsOpen {
                folded += 1
                continue
            }
            items.append(propertyRow(p, section: section, row: r, groups: groups))
            // Further data sources of a text or a graph (MeasureName2…), unless the group lists them itself.
            if p.key == "MeasureName", !group.properties.contains(where: { $0.key == "MeasureName2" }) {
                var i = 2
                while let extra = rows.first(where: { $0.key.caseInsensitiveCompare("MeasureName\(i)") == .orderedSame }) {
                    let q = EditorSchema.Property(extra.key, "Shows (%\(i))", .sectionRef(.measure))
                    items.append(propertyRow(q, section: section, row: extra, groups: groups))
                    i += 1
                }
            }
        }
        // Repeated options (IfCondition2, IfTrueAction2…), in number order, while any of them is set.
        let numbered = group.properties.filter(\.numbered)
        if !numbered.isEmpty {
            let highest = rows.compactMap { r -> Int? in
                guard let n = EditorSchema.numberedProperty(r.key, in: [full]) else { return nil }
                return n.index
            }.max() ?? 1
            if highest >= 2 {
                for i in 2...highest {
                    for p in numbered {
                        let q = EditorSchema.numbered(p, index: i, in: groups)
                        guard EditorSchema.isVisible(q, in: groups, values: valueLookup(rows)) else { continue }
                        items.append(propertyRow(q, section: section, row: row(for: q, in: rows), groups: groups))
                    }
                }
            }
        }
        if foldActions, folded > 0 || actionsOpen {
            let more = EditorStyle.disclosure(actionsOpen ? "Fewer actions" : "\(folded) more actions", open: actionsOpen)
            more.identifier = NSUserInterfaceItemIdentifier("more-actions")
            more.toolTip = "Right, middle and extra buttons, double-clicks, scrolling"
            more.onAction { [weak self] _ in
                guard let self else { return }
                if self.inspectorState.disclosures.contains(actionsKey) {
                    self.inspectorState.disclosures.remove(actionsKey)
                } else {
                    self.inspectorState.disclosures.insert(actionsKey)
                }
                self.rebuildKeepingScroll()
            }
            items.append(InspectorRow(label: nil, control: EditorStyle.hstack([more, EditorStyle.spacer()], spacing: 0)))
        }
        return EditorCard(title: group.title, views: [EditorStyle.grid(items)])
    }

    /// How a value is written.
    enum ValueForm: Equatable {
        case literal
        /// One `#Var#`: editing it edits the variable.
        case variable(String)
        /// A formula or a mix with variables / section values.
        case formula
    }

    /// Kinds whose control can show a variable's current value (editing then writes the variable).
    static func controlShowsVariable(_ kind: EditorSchema.Kind) -> Bool {
        switch kind {
        case .bool, .choice, .alignment9, .percent255, .angle, .color, .font, .number, .image: return true
        default: return false
        }
    }

    func valueForm(_ p: EditorSchema.Property, raw: String) -> ValueForm {
        if let v = wholeVariable(raw) { return .variable(v) }
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .literal }
        switch p.kind {
        case .number, .percent255, .bool, .choice, .alignment9, .color:
            return LenientNumberFormatter.isExpression(t) ? .formula : .literal
        case .angle(let unit, _):
            return AngleControl.degrees(of: t, unit: unit) == nil && LenientNumberFormatter.isExpression(t) ? .formula : .literal
        case .insets:
            return InsetsControl.values(of: t) == nil && LenientNumberFormatter.isExpression(t) ? .formula : .literal
        default:
            return .literal
        }
    }

    /// One property: the row label (plain words; the INI name in the tooltip, or under the label when Settings says
    /// so), the control for its kind, and under it what the value needs to say (a warning, a variable pill, where an
    /// inherited value comes from).
    /// `friendly` (the selection pages): no "from Style" badge under each row (the card's look badge says it once),
    /// "↺ Match the Others" under a layer's own value that its look also sets, and — with `dot` — the dot of a setting
    /// in use before the label.
    /// `selection`: the layers the row edits together (a group's members; see `PropertyContext.selection`).
    func propertyRow(_ p: EditorSchema.Property, section: String, row: Row?, groups: [EditorSchema.Group],
                     friendly: Bool = false, dot: Bool = false, selection: [String]? = nil) -> InspectorRow {
        let raw = row?.raw ?? ""
        let key = row?.key ?? p.key
        let form = valueForm(p, raw: raw)
        let variable: String? = { if case .variable(let v) = form { return v } else { return nil } }()
        let showNames = app.state.editor.showIniNames
        let tooltip = key + (p.help.isEmpty ? "" : " — \(p.help)")
        let ctx = PropertyContext(property: p, section: section, key: key, row: row, variable: variable, form: form,
                                  selection: selection)
        let menu = rowMenu(ctx)

        var control: NSView
        var lines: [NSView] = []
        if form == .formula || (variable != nil && !Self.controlShowsVariable(p.kind)) {
            control = LinkedValueTag(ctx: ctx, controller: self)
        } else {
            control = kindControl(ctx, lines: &lines)
        }
        control.toolTip = control.toolTip ?? tooltip
        if control.identifier == nil { control.identifier = NSUserInterfaceItemIdentifier(p.key) }
        if let row = control as? CheckboxRow {
            attach(menu, to: row)
            row.box.toolTip = tooltip
        } else if !(control is NSPopUpButton), control.menu == nil {
            control.menu = menu
        }

        // Under the control: a warning, the variable pill, where an inherited value comes from.
        if let row, form == .literal, let issue = propertyIssue(p, row: row, section: section) {
            lines.append(EditorStyle.issue(issue, width: inspectorControlWidth))
        }
        var captions: [NSView] = []
        if variable != nil, Self.controlShowsVariable(p.kind), p.kind != .color {
            captions.append(LinkedValueTag(ctx: ctx, controller: self, asControl: false))
        }
        if friendly, selection == nil, let row, row.style == .own, let match = matchTheOthers(section: section, key: key, label: p.label) {
            _ = row
            captions.append(match)
        }
        if !friendly, let row, row.style == .inherited, let style = inheritedStyle(section: section, key: key) {
            let badge = EditorStyle.originBadge(style)
            badge.onAction { [weak self, weak badge] _ in
                guard let self, let badge else { return }
                self.rowMenu(ctx)?.popUp(positioning: nil, at: NSPoint(x: 0, y: badge.bounds.height + 2), in: badge)
            }
            captions.append(badge)
        } else if let row, row.style == .runtime {
            let note = EditorStyle.label(friendly ? "changed while the widget runs" : "set by the widget while it runs", size: 10.5,
                                         color: .systemOrange)
            note.toolTip = row.sourceTip
            captions.append(note)
        }
        if !captions.isEmpty {
            // Wrapping, so a pill keeps its name next to an origin badge in the narrow column.
            let flow = FlowView()
            flow.rowSpacing = 4
            flow.identifier = NSUserInterfaceItemIdentifier("captions")
            for c in captions { flow.addSubview(c) }
            lines.append(flow)
        }

        let cell: NSView
        if lines.isEmpty {
            cell = control
        } else {
            let stack = EditorStyle.vstack([control] + lines, spacing: 4)
            control.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            if control is NSStackView || control is ValueField || control is NSPopUpButton || control is FormatControl {
                control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            for l in lines {
                if l is FlowView {
                    l.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                } else {
                    l.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
                }
            }
            cell = stack
        }
        var label: NSView?
        if p.kind.isBool, form != .formula {
            // A checkbox carries its own positive title; the INI name, when shown, sits in the label column.
            label = showNames ? EditorStyle.rowLabel("", key: key, tooltip: tooltip) : (dot ? EditorStyle.rowLabel("", key: nil, tooltip: tooltip) : nil)
        } else {
            label = EditorStyle.rowLabel(p.label, key: showNames ? key : nil, tooltip: friendly && !showNames ? plainTooltip(p) : tooltip)
        }
        if dot, let l = label { label = dotted(l) }
        if let label { attach(menu, to: label) }
        return InspectorRow(label: label, control: cell)
    }

    /// A row's tooltip in plain words (the option's name only with Rainmeter Details).
    func plainTooltip(_ p: EditorSchema.Property) -> String {
        p.help.isEmpty ? p.label : p.help
    }

    /// "↺ Match the Others": the layer's own value of an option its look also sets; clicking removes the layer's
    /// value (one undo step "Match the Others"). nil when the look does not set it.
    func matchTheOthers(section: String, key: String, label: String) -> NSView? {
        guard let skin, let option = skin.inspectedOptions(ofSection: section).first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
              !option.shadowedStyles.isEmpty, skin.ownDefinitionFile(section: section, key: key) != nil else { return nil }
        let b = NSButton(title: "↺ Match the Others", target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 10.5, weight: .medium)
        b.contentTintColor = .controlAccentColor
        b.identifier = NSUserInterfaceItemIdentifier("match-others-\(key)")
        b.toolTip = "Use the look's value again"
        b.onAction { [weak self] _ in self?.matchOthers(section: section, key: key) }
        return b
    }

    /// Removes the layer's own value of `key`, so its look's value applies again (one undo step).
    func matchOthers(section: String, key: String) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.matchOthers(section: section, key: key) }) { return }
        guard let skin, let file = skin.ownDefinitionFile(section: section, key: key) else { return }
        perform("Match the Others", files: [file], message: { _ in "\(self.displayName(ofSection: section)) matches its look again" }) {
            try skin.removeOwnOption(section: section, key: key)
        }
    }

    /// What a control needs to know about its property.
    struct PropertyContext {
        var property: EditorSchema.Property
        /// The section whose inspector shows it.
        var section: String
        /// The key as written (an older spelling when the file uses one), else the documented key.
        var key: String
        var row: Row?
        var variable: String?
        var form: ValueForm
        /// The layers an edit is meant for when it is more than `section` (a group's page: all its members, §7.5);
        /// nil: the section alone.
        var selection: [String]? = nil

        var raw: String { row?.raw ?? "" }
        var resolved: String { row?.resolved ?? "" }
        var isSet: Bool { row != nil }
        /// The value in effect: the current value, or the default for a missing option.
        var effective: String { row == nil ? property.defaultValue : (variable != nil ? resolved : raw) }
        var label: String { property.label }
    }

    /// Writes a control's value (to the variable for `#Var#` values, else where the option is defined). For several
    /// layers (`ctx.selection`), each is written where `ScopeResolver` says for all of them together: the look they
    /// share when they are its users, else each layer (`writeSeveral`), one undo step "Change Fill of 16 Bars".
    func writer(_ ctx: PropertyContext) -> (String) -> Void {
        { [weak self] value in
            guard let self, !self.inspectorState.isRebuilding else { return }
            self.commitPendingPreview()
            if let sections = ctx.selection, sections.count > 1 {
                self.writeSeveral(ctx.key, value: value, sections: sections, label: ctx.label)
                return
            }
            self.writeProperty(section: ctx.section, key: ctx.key, value: value, variable: ctx.variable, label: ctx.label)
        }
    }

    /// Previews a continuous control's value; writes it when `finished`.
    func previewer(_ ctx: PropertyContext) -> (String, Bool) -> Void {
        { [weak self] value, finished in
            guard let self, !self.inspectorState.isRebuilding else { return }
            // Several layers: written for all of them when the step ends (a preview shows one section only).
            if let sections = ctx.selection, sections.count > 1 {
                if finished, !value.isEmpty { self.writeSeveral(ctx.key, value: value, sections: sections, label: ctx.label) }
                return
            }
            if value.isEmpty { return self.resetProperty(section: ctx.section, key: ctx.key, label: ctx.label) }
            self.previewProperty(PreviewTarget(section: ctx.section, key: ctx.key, variable: ctx.variable, name: ctx.label),
                                 value: value, finished: finished)
        }
    }

    /// Clearing a field: the layer's own value is removed (its style or the default applies again).
    func clearer(_ ctx: PropertyContext) -> () -> Void {
        { [weak self] in
            guard let self, !self.inspectorState.isRebuilding, ctx.variable == nil else { return }
            self.resetProperty(section: ctx.section, key: ctx.key, label: ctx.label)
        }
    }

    /// The control for the property's kind (the value is literal, or one variable the control can show).
    func kindControl(_ ctx: PropertyContext, lines: inout [NSView]) -> NSView {
        let p = ctx.property
        let write = writer(ctx)
        switch p.kind {
        case .bool(let title):
            let row = CheckboxRow(title: title, width: inspectorControlWidth)
            let box = row.box
            if let n = OptionValue.number(ctx.effective) {
                box.state = n != 0 ? .on : .off
            } else {
                box.allowsMixedState = true
                box.state = .mixed
            }
            box.identifier = NSUserInterfaceItemIdentifier(p.key)
            row.identifier = NSUserInterfaceItemIdentifier("\(p.key).row")
            box.onAction { b in write((b as? NSButton)?.state == .off ? "0" : "1") }
            return row
        case .choice(let choices, let style):
            return choiceControl(ctx, choices: choices, style: style, write: write)
        case .alignment9:
            let c = AlignmentControl(raw: ctx.effective)
            c.identifier = NSUserInterfaceItemIdentifier(p.key)
            c.onChange = write
            return c
        case .number(let lo, let hi, let step, let unit):
            let text = ctx.variable != nil ? ctx.resolved : ctx.raw
            if ctx.isSet, ctx.variable == nil, OptionValue.number(text) == nil || EditorSchema.issue(for: text, property: p) != nil {
                // Not a number (or out of range): shown as written, with the warning under it.
                let field = textField(ctx, value: text)
                field.validate = { v in v.isEmpty || LenientNumberFormatter.isExpression(v) || Double(v) != nil ? nil : "“\(v)” is not a number" }
                return field
            }
            let control = NumberControl(value: text, placeholder: p.placeholder, min: lo, max: hi, step: step, unit: unit,
                                        fallback: OptionValue.number(p.defaultValue) ?? 0)
            control.identifier = NSUserInterfaceItemIdentifier(p.key)
            control.field.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/\(ctx.key)")
            let clear = clearer(ctx)
            control.onCommit = { v in v.isEmpty ? clear() : write(v) }
            control.onStep = previewer(ctx)
            return control
        case .percent255:
            let control = PercentControl(value: OptionValue.number(ctx.effective) ?? 255)
            control.identifier = NSUserInterfaceItemIdentifier(p.key)
            control.field.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/\(ctx.key)")
            control.onChange = previewer(ctx)
            return control
        case .angle(let unit, let orientation):
            let control = AngleControl(raw: ctx.isSet ? (ctx.variable != nil ? ctx.resolved : ctx.raw) : "", unit: unit,
                                       orientation: orientation, placeholder: p.placeholder)
            control.identifier = NSUserInterfaceItemIdentifier(p.key)
            control.field.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/\(ctx.key)")
            control.onChange = previewer(ctx)
            return control
        case .color:
            let control = ColorControl(ctx: ctx, controller: self)
            if let sections = ctx.selection, sections.count > 1 {
                // A color of several layers (a group's): the picked color is previewed on all of them and written
                // for all of them (`writeSeveral`), not for the section the row reads.
                pageState.severalSwatches.add(control.swatch)
                let like = ctx.isSet ? ctx.resolved : ""
                ShapeColorPicker.shared.register(control.swatch, identity: "several/\(sections.joined(separator: ","))/\(ctx.key)",
                                                 controller: self) { [weak self] rgba, finished in
                    self?.previewSeveralColor(ctx.key, rgba: rgba, like: like, sections: sections, label: ctx.label, finished: finished)
                }
            }
            return control
        case .font:
            let popup = fontPopup(key: p.key, section: ctx.section, raw: ctx.raw, current: ctx.isSet ? ctx.resolved : "",
                                  variable: ctx.variable)
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return popup
        case .insets:
            let id = "\(ctx.section)/\(ctx.key)"
            guard let values = InsetsControl.values(of: ctx.isSet ? ctx.effective : p.defaultValue) else {
                return textField(ctx, value: ctx.raw)
            }
            let linked = inspectorState.insetLinks[id] ?? (Set(values.compactMap(Double.init)).count <= 1)
            let control = InsetsControl(values: values, linked: linked)
            control.identifier = NSUserInterfaceItemIdentifier(p.key)
            for (i, f) in control.fields.enumerated() { f.identifier = NSUserInterfaceItemIdentifier("\(id)/\(i)") }
            control.onFieldChange = { [weak self] index, value, linked in
                self?.editInsets(ctx, index: index, value: value, linked: linked)
            }
            control.onLinkChange = { [weak self] on in self?.inspectorState.insetLinks[id] = on }
            return control
        case .image:
            return imageControl(ctx, lines: &lines)
        case .sectionRef(let kind):
            return sectionControl(ctx, kind: kind, lines: &lines)
        case .styleList:
            let styles = OptionValue.list(ctx.raw)
            let available = allItems.filter { $0.kind == .other }.map(\.title)
            let missing = Set(styles.filter { s in skin?.document.section(named: s) == nil }.map { $0.lowercased() })
            let control = StyleListControl(styles: styles, available: available, missing: missing)
            control.identifier = NSUserInterfaceItemIdentifier(p.key)
            let clear = clearer(ctx)
            control.onChange = { list in list.isEmpty ? clear() : write(list.joined(separator: " | ")) }
            control.onAdd = { [weak self] name in self?.editStyles(ctx) { $0 + [name] } }
            control.onRemove = { [weak self] name in
                self?.editStyles(ctx) { list in
                    var list = list
                    if let i = list.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { list.remove(at: i) }
                    return list
                }
            }
            control.onOpen = { [weak self] name in self?.select(section: name) }
            return control
        case .format(let presets, let kind):
            let control = FormatControl(value: ctx.raw, placeholder: p.placeholder, presets: presets,
                                        render: formatRenderer(kind, section: ctx.section))
            control.identifier = NSUserInterfaceItemIdentifier(p.key)
            control.combo.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/\(ctx.key)")
            control.onCommit = write
            if kind == .time || kind == .uptime {
                inspectorState.liveUpdates.append { [weak control] in control?.updatePreview() }
            }
            return control
        case .formula:
            let field = textField(ctx, value: ctx.raw, monospaced: true)
            if let result = formulaResult(ctx) {
                let label = EditorStyle.mono("= " + result, size: 10.5, color: .secondaryLabelColor)
                label.identifier = NSUserInterfaceItemIdentifier("formula-result")
                lines.append(label)
                inspectorState.liveUpdates.append { [weak self, weak label] in
                    guard let self, let label, let r = self.formulaResult(ctx) else { return }
                    label.stringValue = "= " + r
                }
            }
            return field
        case .action:
            // An action that is set reads as a sentence (§8.2: "Turns its text back to its usual color", "Runs 2
            // commands"), its text one click away ("Edit as Text") and always with Rainmeter Details.
            let raw = ctx.raw.trimmingCharacters(in: .whitespaces)
            let asText = "action/\(ctx.section.lowercased())/\(ctx.key.lowercased())"
            if !raw.isEmpty, !showsDetails, !inspectorState.disclosures.contains(asText), let skin {
                let sentence = ActionSummary.sentence(for: raw, section: ctx.section, in: skin) ?? "Runs a command"
                let label = NSTextField(wrappingLabelWithString: sentence)
                label.font = .systemFont(ofSize: 11.5)
                label.textColor = .secondaryLabelColor
                label.isSelectable = false
                label.preferredMaxLayoutWidth = inspectorControlWidth
                label.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/\(ctx.key)/sentence")
                let id = "\(ctx.section)/\(ctx.key)"
                let edit = linkLike("Edit as Text", id: "\(id)/edit-text") { [weak self] in
                    guard let self else { return }
                    self.inspectorState.disclosures.insert(asText)
                    self.rebuildKeepingScroll()
                    if let field = self.inspectorStack.findSubview(where: { $0.identifier?.rawValue == id }) {
                        self.window?.makeFirstResponder(field)
                    }
                }
                return EditorStyle.vstack([label, edit], spacing: 2)
            }
            return textField(ctx, value: ctx.raw, placeholder: "No action", monospaced: true)
        case .text:
            return textField(ctx, value: ctx.raw, placeholder: p.placeholder)
        case .shapes:
            return ShapeEditorView(controller: self, meter: ctx.section)
        }
    }

    /// One side of an insets value (Padding) was committed: the value written is built from the four sides as the
    /// file holds them when it is written (typed code committed first), not from the other fields' text.
    func editInsets(_ ctx: PropertyContext, index: Int, value: String, linked: Bool) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.editInsets(ctx, index: index, value: value, linked: linked) }) {
            return
        }
        guard !inspectorState.isRebuilding else { return }
        let current = rows.first { $0.key.caseInsensitiveCompare(ctx.key) == .orderedSame }
        let written = ctx.variable != nil ? current?.resolved : current?.raw
        let sides = InsetsControl.values(of: written ?? ctx.property.defaultValue) ?? ["0", "0", "0", "0"]
        writer(ctx)(InsetsControl.combined(sides, index: index, value: value, linked: linked))
    }

    /// Adds or removes a style of `MeterStyle`, applied to the list the file holds when it is written.
    func editStyles(_ ctx: PropertyContext, _ change: @escaping ([String]) -> [String]) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.editStyles(ctx, change) }) { return }
        guard !inspectorState.isRebuilding else { return }
        let current = OptionValue.list(rows.first { $0.key.caseInsensitiveCompare(ctx.key) == .orderedSame }?.raw ?? "")
        var seen: Set<String> = []
        let list = change(current).filter { seen.insert($0.lowercased()).inserted }
        if list.isEmpty { clearer(ctx)() } else { writer(ctx)(list.joined(separator: " | ")) }
    }

    /// The default of a color option when it is a color that shows (not transparent, and not worded as "none" by
    /// the schema, like a white tint that changes nothing); nil otherwise.
    static func visibleDefaultColor(_ p: EditorSchema.Property) -> RGBA? {
        guard p.placeholder == p.defaultValue, let c = OptionValue.color(p.defaultValue), c.a > 0 else { return nil }
        return c
    }

    /// A color as it is usually read: `0,0,0` for `0,0,0,255` (opaque colors without their alpha).
    static func shortColor(_ text: String) -> String {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 4 && parts[3] == "255" ? parts.prefix(3).joined(separator: ",") : text
    }

    /// A plain field for a text-like value: words in the system font; `monospaced` (the code font) for what is code, a
    /// calculation or a command.
    func textField(_ ctx: PropertyContext, value: String, placeholder: String? = nil, monospaced: Bool = false) -> ValueField {
        let field = ValueField(value, placeholder: placeholder ?? ctx.property.placeholder, monospaced: monospaced)
        field.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/\(ctx.key)")
        field.onCommit = writer(ctx)
        field.onInvalid = { [weak self] problem in self?.toast.show(problem, error: true) }
        return field
    }

    /// A choice: segmented control for a few short values, pop-up otherwise (and always for an invalid value, which
    /// stays selected — disabled — above the valid ones).
    func choiceControl(_ ctx: PropertyContext, choices: [EditorSchema.Choice], style: EditorSchema.ChoiceStyle,
                       write: @escaping (String) -> Void) -> NSView {
        let p = ctx.property
        let written = ctx.effective.trimmingCharacters(in: .whitespaces)
        // An empty value reads as the default.
        let value = written.isEmpty ? p.defaultValue : written
        let match = EditorSchema.choice(for: value, in: choices)
        let accepted: Bool = {
            if match != nil || value.isEmpty { return true }
            switch p.otherValues {
            case .any: return true
            case .numbers: return OptionValue.number(value) != nil
            case .none: return false
            }
        }()
        if style == .segmented, match != nil, let segments = segmentLabels(choices) {
            let seg = ChoiceSegmentedControl()
            seg.segmentCount = choices.count
            seg.trackingMode = .selectOne
            seg.controlSize = .small
            seg.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            seg.values = choices.map(\.value)
            for (i, c) in choices.enumerated() {
                if let symbol = segments[i].symbol, let image = EditorStyle.image(symbol, size: 12) {
                    seg.setImage(image, forSegment: i)
                    seg.setWidth(30, forSegment: i)
                } else {
                    seg.setLabel(segments[i].title, forSegment: i)
                }
                let isDefault = c.value.caseInsensitiveCompare(p.defaultValue) == .orderedSame
                seg.setToolTip(c.title + (isDefault ? " (default)" : "") + (c.note.isEmpty ? "" : " — \(c.note)"), forSegment: i)
            }
            seg.selectedSegment = choices.firstIndex { $0.value == match?.value } ?? -1
            seg.identifier = NSUserInterfaceItemIdentifier(p.key)
            seg.setAccessibilityLabel(p.label)
            seg.onAction { c in
                guard let s = c as? ChoiceSegmentedControl, s.selectedSegment >= 0, s.selectedSegment < s.values.count else { return }
                write(s.values[s.selectedSegment])
            }
            return seg
        }
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier(p.key)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let menu = NSMenu()
        menu.autoenablesItems = false
        // The closed pop-up shows the plain title: "(default)" and notes are for the open menu.
        var plainTitles: [String: String] = [:]
        if !value.isEmpty, match == nil {
            // The file's value, first and selected: never replaced until the user picks another.
            let item = NSMenuItem(title: accepted ? value : "“\(value)”", action: nil, keyEquivalent: "")
            item.representedObject = value
            item.isEnabled = accepted
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for c in choices {
            let isDefault = c.value.caseInsensitiveCompare(p.defaultValue) == .orderedSame
            var title = c.title
            plainTitles[c.value.lowercased()] = title
            if isDefault { title += " (default)" }
            if !c.supportedOnMac, !c.note.isEmpty { title += " — \(c.note)" }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = c.value
            if let symbol = c.symbol { item.image = EditorStyle.image(symbol, size: 12) }
            menu.addItem(item)
        }
        popup.menu = menu
        let selected = match?.value ?? value
        if let item = menu.items.first(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(selected) == .orderedSame }) {
            popup.select(item)
        }
        popup.closedTitle = { item in
            (item.representedObject as? String).flatMap { plainTitles[$0.lowercased()] }.map { NSAttributedString(string: $0) }
        }
        popup.onAction { c in
            guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            write(v)
        }
        return popup
    }

    /// Segment labels that fit the control column: words, else symbols where the choice has one; nil when even that
    /// does not fit (a pop-up is used then).
    func segmentLabels(_ choices: [EditorSchema.Choice]) -> [(title: String, symbol: String?)]? {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) + 18 }
        let available = inspectorControlWidth - 4
        let words = choices.map { (title: $0.title, symbol: String?.none) }
        if words.reduce(0, { $0 + width($1.title) }) <= available { return words }
        let mixed = choices.map { (title: $0.title, symbol: $0.symbol) }
        if mixed.reduce(0, { $0 + ($1.symbol != nil ? 30 : width($1.title)) }) <= available { return mixed }
        return nil
    }

    /// What is wrong with a property's current value, in plain words (nil when the engine reads it as intended).
    func propertyIssue(_ p: EditorSchema.Property, row: Row, section: String) -> String? {
        if let issue = EditorSchema.issue(for: row.raw, property: p) { return issue }
        guard let skin else { return nil }
        let raw = row.raw.trimmingCharacters(in: .whitespaces)
        switch p.kind {
        case .image where !raw.isEmpty && !raw.contains("%") && !raw.contains("["):
            if let path = imagePath(ctxSection: section, key: p.key, resolved: row.resolved),
               !FileManager.default.fileExists(atPath: path) {
                return "“\(row.resolved)” was not found — nothing is drawn"
            }
        case .sectionRef where !raw.isEmpty && !EditorSchema.isDynamicValue(raw):
            if skin.document.section(named: raw) == nil { return "There is no [\(raw)] section" }
        default:
            break
        }
        return nil
    }

    // MARK: Row menu

    /// The shared style an inherited option comes from.
    func inheritedStyle(section: String, key: String) -> String? {
        if case .style(let name, _)? = skin?.section(named: section)?.optionOrigin(key) { return name }
        return nil
    }

    /// Right-click on a row (or click on its "from Style" badge): Override on this layer, Reset to default, Show in
    /// Code, Open the style.
    func rowMenu(_ ctx: PropertyContext) -> NSMenu? {
        guard let skin else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isLayerOrSource = skin.section(named: ctx.section) != nil && ctx.section.caseInsensitiveCompare("Rainmeter") != .orderedSame
        let style = inheritedStyle(section: ctx.section, key: ctx.key)
        if let style, isLayerOrSource {
            menu.addItem(ClosureMenuItem("Override on This Layer", symbol: "square.and.pencil") { [weak self] in
                self?.overrideProperty(section: ctx.section, key: ctx.key, value: ctx.raw, label: ctx.label)
            })
            menu.addItem(ClosureMenuItem("Open \(style)", symbol: "paintbrush") { [weak self] in self?.select(section: style) })
        }
        if ctx.section.caseInsensitiveCompare("Variables") != .orderedSame,
           skin.ownDefinitionFile(section: ctx.section, key: ctx.key) != nil {
            let shadowed = skin.inspectedOptions(ofSection: ctx.section)
                .first { $0.key.caseInsensitiveCompare(ctx.key) == .orderedSame }?.shadowedStyles.first
            let title = shadowed.map { "Use \($0)’s Value" } ?? "Reset to Default"
            menu.addItem(ClosureMenuItem(title, symbol: "arrow.uturn.backward") { [weak self] in
                self?.resetProperty(section: ctx.section, key: ctx.key, label: ctx.label)
            })
        }
        if let location = ctx.row?.location {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem("Show in Code", symbol: "curlybraces") { [weak self] in self?.showInCode(location) })
        }
        return menu.items.isEmpty ? nil : menu
    }

    func attach(_ menu: NSMenu?, to view: NSView) {
        guard let menu else { return }
        view.menu = menu
        for v in view.subviews { attach(menu, to: v) }
    }

    /// Runs a row menu item by title prefix for an option (self-tests: "Override", "Reset", "Use").
    @discardableResult
    func chooseRowMenuItem(_ key: String, _ title: String) -> Bool {
        guard let control = inspectorControl(for: key) else { return false }
        // A pop-up's own menu holds its choices; the row menu is on the control otherwise.
        let menu = control is NSPopUpButton ? control.superview?.menu : (control.menu ?? control.superview?.menu)
        guard let item = menu?.items.first(where: { $0.title.hasPrefix(title) }) else { return false }
        _ = item.target?.perform(item.action)
        return true
    }

    // MARK: Kinds that need the skin

    /// The absolute path of an image option's file (ImagePath / MaskImagePath prefix, skin folder).
    func imagePath(ctxSection section: String, key: String, resolved: String) -> String? {
        guard let skin else { return nil }
        let folderKey = key.lowercased().hasPrefix("mask") ? "MaskImagePath" : "ImagePath"
        let folder = key.caseInsensitiveCompare("Background") == .orderedSame ? ""
            : (skin.section(named: section)?.option(folderKey) ?? "")
        return ImageOptions.filePath(resolved, imagePath: folder, skin: skin)
    }

    /// Image files of the skin: in its folder (relative names) and in @Resources (`#@#…`).
    func imageFiles() -> [(group: String, title: String, value: String, url: URL)] {
        guard let skin else { return [] }
        var result: [(String, String, String, URL)] = []
        func scan(_ folder: URL, group: String, prefix: String, skip: URL?) {
            guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            var count = 0
            for case let url as URL in e {
                if let skip, url.standardizedFileURL.path.hasPrefix(skip.standardizedFileURL.path) { e.skipDescendants(); continue }
                if e.level > 3 { e.skipDescendants(); continue }
                guard ImageOptions.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                result.append((group, rel, prefix + rel, url))
                count += 1
                if count >= 300 { break }
            }
        }
        scan(skin.directory, group: "This skin", prefix: "", skip: skin.resourcesDirectory)
        scan(skin.resourcesDirectory, group: "@Resources", prefix: "#@#", skip: nil)
        return result
    }

    static let thumbnails = NSCache<NSString, NSImage>()

    /// A 16-point-wide menu thumbnail of an image file (cached: the inspector is rebuilt after every write).
    static func thumbnail(_ url: URL) -> NSImage? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)@\(stamp)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let ratio = max(min(image.size.height / image.size.width, 2), 0.25)
        let size = NSSize(width: 16, height: (16 * ratio).rounded())
        let thumb = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        thumbnails.setObject(thumb, forKey: key)
        return thumb
    }

    /// An image option: thumbnail, the images of the skin, "Choose…".
    func imageControl(_ ctx: PropertyContext, lines: inout [NSView]) -> NSView {
        let current = (ctx.variable != nil ? ctx.resolved : ctx.raw).trimmingCharacters(in: .whitespaces)
        let path = ctx.isSet ? imagePath(ctxSection: ctx.section, key: ctx.key, resolved: ctx.resolved) : nil
        let image = path.flatMap { FileManager.default.fileExists(atPath: $0) ? NSImage(contentsOfFile: $0) : nil }
        let control = ImageControl(image: image)
        control.identifier = NSUserInterfaceItemIdentifier(ctx.property.key)
        let popup = control.popup
        popup.identifier = NSUserInterfaceItemIdentifier("\(ctx.property.key).popup")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        none.representedObject = ""
        menu.addItem(none)
        let files = imageFiles()
        var selected: NSMenuItem? = current.isEmpty ? none : nil
        func normalized(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "/").lowercased() }
        for group in ["This skin", "@Resources"] {
            let items = files.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            menu.addItem(.separator())
            // (§3.2: the widget's own folder, and its shared files — "@Resources" only in tooltips.)
            let header = NSMenuItem(title: group == "This skin" ? "In the Widget's Folder" : "Shared Files", action: nil,
                                    keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for f in items {
                let item = NSMenuItem(title: f.title, action: nil, keyEquivalent: "")
                item.representedObject = f.value
                item.indentationLevel = 1
                if menu.items.count < 120 { item.image = Self.thumbnail(f.url) }
                menu.addItem(item)
                if selected == nil, !current.isEmpty,
                   normalized(f.value) == normalized(current) || (path.map { normalized($0) == normalized(f.url.path) } ?? false) {
                    selected = item
                }
            }
        }
        if selected == nil, !current.isEmpty {
            // The file's value (a missing file, a name with a data source, a file elsewhere) stays selected, named by its
            // file ("needle.png", never "#CURRENTPATH#…"), the whole path in its tooltip; not greyed out, as it is in use.
            let shown = showsDetails ? current : LayerNaming.fileName(path ?? current)
            let item = NSMenuItem(title: shown.isEmpty ? current : shown, action: nil, keyEquivalent: "")
            item.representedObject = current
            item.toolTip = path ?? current
            popup.toolTip = path ?? current
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            selected = item
        }
        menu.addItem(.separator())
        let choose = ClosureMenuItem("Choose…", symbol: "folder") { [weak self] in
            self?.chooseImageFile(section: ctx.section, key: ctx.key, variable: ctx.variable, label: ctx.label)
        }
        choose.representedObject = nil
        menu.addItem(choose)
        popup.menu = menu
        if let selected { popup.select(selected) }
        let write = writer(ctx)
        popup.onAction { c in
            guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            write(v)
        }
        return control
    }

    /// A reference to another section: a menu of the skin's measures (in plain words), meters or styles, with a way
    /// to open the one chosen.
    func sectionControl(_ ctx: PropertyContext, kind: EditorSchema.SectionKind, lines: inout [NSView]) -> NSView {
        guard let skin else { return NSView() }
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier(ctx.property.key)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let none = NSMenuItem(title: "Nothing", action: nil, keyEquivalent: "")
        none.representedObject = ""
        menu.addItem(none)
        menu.addItem(.separator())
        var names: [String] = []
        // Closed, a data source shows its plain name — or, when another data source has the same one (two
        // Calculations), its name without "Measure" first ("SwapTotal  Calculation"), so the two can be told apart in
        // a narrow column. No icon: the room goes to the words (the menu has the icons).
        var closedTitles: [String: NSAttributedString] = [:]
        let plainNames = skin.measures.map { EditorStyle.describe($0).title }
        switch kind {
        case .measure:
            for m in skin.measures {
                let d = EditorStyle.describe(m)
                if plainNames.filter({ $0 == d.title }).count > 1 {
                    let closed = NSMutableAttributedString(string: EditorStyle.displayName(m.name))
                    closed.append(NSAttributedString(string: "  \(d.title)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                    closedTitles[m.name.lowercased()] = closed
                } else {
                    closedTitles[m.name.lowercased()] = NSAttributedString(string: d.title)
                }
                let item = NSMenuItem(title: "\(d.title) — \(m.name)", action: nil, keyEquivalent: "")
                let title = NSMutableAttributedString(string: d.title, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                title.append(NSAttributedString(string: "  \(m.name)", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                item.attributedTitle = title
                item.image = EditorStyle.image(d.symbol, size: 12)
                item.representedObject = m.name
                menu.addItem(item)
                names.append(m.name)
            }
        case .meter:
            for m in skin.meters where m.name.caseInsensitiveCompare(ctx.section) != .orderedSame {
                let item = NSMenuItem(title: EditorStyle.displayName(m.name), action: nil, keyEquivalent: "")
                item.image = EditorStyle.image(EditorStyle.symbol(for: .meter, type: m.type), size: 12)
                item.representedObject = m.name
                item.toolTip = m.name
                menu.addItem(item)
                names.append(m.name)
            }
        case .style:
            for s in allItems where s.kind == .other {
                let item = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
                item.image = EditorStyle.image("paintbrush", size: 12)
                item.representedObject = s.title
                menu.addItem(item)
                names.append(s.title)
            }
        }
        let current = ctx.raw.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            let item = NSMenuItem(title: "\(current) (missing)", action: nil, keyEquivalent: "")
            item.representedObject = current
            item.isEnabled = false
            menu.insertItem(item, at: 0)
        }
        if kind == .measure {
            // A data source the skin does not have yet: created and used in one step.
            menu.addItem(.separator())
            let new = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
            new.image = EditorStyle.image("plus.circle", size: 12)
            new.identifier = NSUserInterfaceItemIdentifier("new-live-data")
            let submenu = NSMenu()
            for item in Self.dataSourceMenuItems(expert: showsRainmeterDetails, { [weak self] type in self?.addDataSource(type, for: ctx) }) { submenu.addItem(item) }
            new.submenu = submenu
            menu.addItem(new)
        }
        popup.menu = menu
        if let item = menu.items.first(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(current) == .orderedSame }) {
            popup.select(item)
        }
        popup.closedTitleShowsImage = false
        popup.closedTitle = { item in (item.representedObject as? String).flatMap { closedTitles[$0.lowercased()] } }
        if !current.isEmpty, let m = skin.measure(named: current) {
            popup.toolTip = "\(EditorStyle.describe(m).title) — [\(m.name)]"
        }
        let write = writer(ctx)
        popup.onAction { c in
            guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            write(v)
        }
        guard !current.isEmpty, skin.document.section(named: current) != nil else { return popup }
        let open = NSButton(image: EditorStyle.image("arrow.right.circle", size: 14) ?? NSImage(), target: self,
                            action: #selector(linkClicked(_:)))
        open.isBordered = false
        open.contentTintColor = .secondaryLabelColor
        open.identifier = NSUserInterfaceItemIdentifier(skin.document.section(named: current)?.name ?? current)
        open.toolTip = "Open \(current)"
        open.setAccessibilityLabel("Open \(current)")
        let row = EditorStyle.hstack([popup, open], spacing: 4)
        row.identifier = NSUserInterfaceItemIdentifier("\(ctx.property.key).row")
        return row
    }

    /// The live preview of a format field.
    func formatRenderer(_ kind: EditorSchema.FormatPreview, section: String) -> (String) -> String {
        { [weak self] format in
            guard let self, let skin = self.skin else { return "" }
            let s = skin.section(named: section)
            func option(_ key: String) -> String? { s?.option(key) }
            switch kind {
            case .time:
                let zone = TimeFormatting.timeZone(forOption: option("TimeZone"),
                                                   daylightSavingTime: OptionValue.bool(option("DaylightSavingTime") ?? "1") ?? true)
                let locale = TimeFormatting.locale(fromOption: option("FormatLocale")) ?? Locale(identifier: "en_US_POSIX")
                return TimeFormatting.format(Date(), format: format, timeZone: zone, locale: locale)
            case .uptime:
                return UptimeFormatting.format(seconds: ProcessInfo.processInfo.systemUptime, format: format,
                                               addDaysToHours: OptionValue.bool(option("AddDaysToHours") ?? "1") ?? true)
            case .number, .none:
                return ""
            }
        }
    }

    /// The current result of a formula option: the Calc measure's own value for `Formula`, the evaluated
    /// condition for `IfCondition`.
    func formulaResult(_ ctx: PropertyContext) -> String? {
        guard let skin, ctx.isSet else { return nil }
        if ctx.key.caseInsensitiveCompare("Formula") == .orderedSame, let m = skin.measure(named: ctx.section) {
            return EditorStyle.number(m.value)
        }
        let fresh = rows.first { $0.key.caseInsensitiveCompare(ctx.key) == .orderedSame }?.resolved ?? ctx.resolved
        guard let value = try? Formula.evaluate(fresh, lookup: { name in skin.measure(named: name)?.value }) else { return nil }
        if ctx.key.lowercased().hasPrefix("ifcondition") { return value != 0 ? "true" : "false" }
        return EditorStyle.number(value)
    }

    // MARK: Other options

    /// Every option of the section the schema does not cover, as written, editable, with where it is defined —
    /// folded away — and a way to the code.
    func otherOptionsCard(section: String, rows: [Row], groups: [EditorSchema.Group], open: Bool, title: String? = nil,
                          meter: Meter? = nil) -> NSView {
        let covered = EditorSchema.keys(groups).union(["meter", "measure", "plugin", "x", "y", "w", "h"])
        var shapeKeys = Set<String>()
        if meter?.type == "shape" {
            // The Shape editor edits the shapes and the gradients they name.
            for r in rows where ShapeSpec.index(ofOption: r.key) != nil {
                shapeKeys.insert(r.key.lowercased())
                if let spec = ShapeSpec.parse(r.raw) {
                    for paint in [spec.fill, spec.stroke].compactMap({ $0 }) {
                        if let g = paint.gradientOption { shapeKeys.insert(g.lowercased()) }
                    }
                }
            }
        }
        let extra = groups.isEmpty ? rows : rows.filter { r in
            let k = r.key.lowercased()
            if covered.contains(k) || shapeKeys.contains(k) { return false }
            if EditorSchema.numberedProperty(r.key, in: groups) != nil { return false }
            if meter != nil, k.hasPrefix("measurename"), Int(k.dropFirst("measurename".count)) != nil { return false }
            return true
        }
        let named = title ?? "Other options"
        let toggle = NSButton(title: "", target: self, action: #selector(toggleAdvanced))
        toggle.isBordered = false
        toggle.attributedTitle = NSAttributedString(string: named.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.8,
        ])
        toggle.identifier = NSUserInterfaceItemIdentifier("other-options")
        if title == nil {
            toggle.image = EditorStyle.image(open ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
            toggle.imagePosition = .imageTrailing
        }
        let count = EditorStyle.label(extra.isEmpty ? "none" : "\(extra.count) option\(extra.count == 1 ? "" : "s")", size: 11,
                                      color: .tertiaryLabelColor)
        let head = EditorStyle.hstack([toggle, EditorStyle.spacer(), count], spacing: 6)
        guard open else { return EditorCard(title: nil, views: [head]) }
        var views: [NSView] = [head]
        if extra.isEmpty && !groups.isEmpty {
            views.append(cardNote("Everything this \(meter != nil ? "layer" : "section") sets is shown above."))
        }
        views += extra.map { optionRow($0, section: section) }
        let code = NSButton(title: "Edit in Code", target: nil, action: nil)
        code.isBordered = false
        code.font = .systemFont(ofSize: 11.5, weight: .medium)
        code.contentTintColor = .controlAccentColor
        code.image = EditorStyle.image("curlybraces", size: 10, weight: .semibold)
        code.imagePosition = .imageLeading
        code.toolTip = "Show it in the code"
        code.identifier = NSUserInterfaceItemIdentifier("edit-in-code")
        let location = skin?.sources.location(section: section)
        code.onAction { [weak self] _ in self?.showInCode(location) }
        views.append(EditorStyle.hstack([code, EditorStyle.spacer()], spacing: 0))
        views.append(addRow())
        return EditorCard(title: nil, views: views)
    }

    @objc func toggleAdvanced() {
        advancedOpen.toggle()
        rebuildKeepingScroll()
    }

    /// Key and source on one line, the value field below, the current value under it when it differs.
    func optionRow(_ r: Row, section: String) -> NSView {
        let key = EditorStyle.label(r.key, size: 12, weight: .medium)
        // A long name and its source don't fit the card together: the source is shortened (at one priority, either
        // could be).
        key.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        let source = EditorStyle.label(r.source, size: 10.5, color: {
            switch r.style {
            case .own: return .tertiaryLabelColor
            case .inherited: return .systemPurple
            case .runtime: return .systemOrange
            }
        }())
        source.alignment = .right
        source.toolTip = r.sourceTip.isEmpty ? nil : r.sourceTip + (r.location == nil ? "" : "\nClick to show it in the code")
        if r.location != nil {
            let click = NSClickGestureRecognizer(target: self, action: #selector(sourceClicked(_:)))
            source.addGestureRecognizer(click)
            source.identifier = NSUserInterfaceItemIdentifier(r.key)
        }
        let top = EditorStyle.hstack([key, EditorStyle.spacer(), source], spacing: 6)
        let field = EditorStyle.field(r.raw)
        field.identifier = NSUserInterfaceItemIdentifier("\(section)/\(r.key)")
        register(field, key: r.key, own: false, section: section)
        let current = EditorStyle.mono("= " + r.resolved, size: 10.5)
        current.isHidden = r.resolved == r.raw
        current.toolTip = r.resolved
        if currentLabels[r.key.lowercased()] == nil { currentLabels[r.key.lowercased()] = current }
        let stack = EditorStyle.vstack([top, field, current], spacing: 4)
        for v in [top, field] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    func addRow() -> NSView {
        let key = EditorStyle.field("", placeholder: selectedKind == .variables ? "NewVariable" : "NewOption")
        let value = EditorStyle.field("", placeholder: "Value")
        key.delegate = self
        value.delegate = self
        addKeyField = key
        addValueField = value
        let plus = NSButton(image: EditorStyle.image("plus.circle.fill", size: 16) ?? NSImage(), target: self,
                            action: #selector(addOption))
        plus.isBordered = false
        plus.contentTintColor = .controlAccentColor
        plus.toolTip = "Add"
        key.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let row = EditorStyle.hstack([key, value, plus], spacing: 6)
        let divider = NSBox()
        divider.boxType = .separator
        let stack = EditorStyle.vstack([divider, row], spacing: 10)
        for v in [divider, row] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    func register(_ field: NSTextField, key: String, own: Bool, section: String? = nil) {
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.delegate = self
        let section = section ?? (selectedKind == .variables ? "Variables" : (selectedSection ?? ""))
        fieldEdits[ObjectIdentifier(field)] = (key, own, section)
    }

    // MARK: Multiple selection

    @objc func alignClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let mode = EditorAlign.Mode(rawValue: raw) else { return }
        align(mode)
    }

    // MARK: Fonts

    /// Font families for the font menu, each shown in its own face (`FontFamilies.all`).
    static var fontFamilies: [(name: String, title: NSAttributedString)] { FontFamilies.all }

    /// A `#Var#` that makes up the whole value (editing it edits the variable).
    func wholeVariable(_ raw: String) -> String? {
        let refs = SkinInspection.referencedVariables(in: raw)
        return refs.count == 1 && raw.trimmingCharacters(in: .whitespaces) == "#\(refs[0])#" ? refs[0] : nil
    }

    func fontPopup(key: String, section: String, raw: String, current: String, variable: String?) -> NSPopUpButton {
        let popup = FontPopUpButton()
        popup.target = self
        popup.action = #selector(choiceChosen(_:))
        popup.identifier = NSUserInterfaceItemIdentifier(key)
        let menu = NSMenu()
        func add(_ title: NSAttributedString, value: String) {
            let item = NSMenuItem(title: title.string, action: nil, keyEquivalent: "")
            item.attributedTitle = title
            item.representedObject = value
            menu.addItem(item)
        }
        let current = current.trimmingCharacters(in: .whitespaces)
        let skinFonts = (skin?.settings.localFonts ?? []).compactMap { path -> String? in
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL)
                    as? [CTFontDescriptor], let first = descriptors.first else { return nil }
            return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
        }
        // Only the pop-up's own family is looked up: the menu lists the others when it opens (`FontFamilies`).
        let installed = FontFamilies.installed(current)
        let isSystem = current.caseInsensitiveCompare("System Font") == .orderedSame
        if !isSystem, installed == nil, !skinFonts.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            let title: String
            if current.isEmpty {
                title = "Default (Arial)"
            } else if let shown = Fonts.substitution(for: current) {
                title = "\(current) — shown as \(shown)"
            } else {
                title = "\(current) (not installed)"
            }
            add(NSAttributedString(string: title), value: current)
            menu.addItem(.separator())
        }
        add(NSAttributedString(string: "System Font", attributes: [.font: NSFont.systemFont(ofSize: 13)]), value: "System Font")
        menu.addItem(.separator())
        if !skinFonts.isEmpty {
            let header = NSMenuItem(title: "Included with the Widget", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for f in Array(Set(skinFonts)).sorted() {
                add(NSAttributedString(string: f, attributes: NSFont(name: f, size: 13).map { [.font: $0] } ?? [:]), value: f)
            }
            menu.addItem(.separator())
        }
        // The families (a few hundred items in their own faces) are added when the menu opens; until then only the
        // current one is there, for the closed pop-up.
        if let family = installed {
            add(FontFamilies.title(family), value: family)
            menu.items.last?.tag = FontPopUpButton.placeholderTag
        }
        popup.menu = menu
        menu.delegate = popup
        if let item = menu.items.first(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(current) == .orderedSame }) {
            popup.select(item)
        }
        swatchEdits[ObjectIdentifier(popup)] = (section, key, raw, variable)
        return popup
    }

    /// An inspector swatch takes the shared color panel: a shape color being picked stops receiving it (its pending
    /// preview is still written by its own timer), so closing the panel later cannot write this color into the shape.
    @objc func inspectorSwatchClicked(_ sender: SwatchButton) {
        // A color of several layers picks through the shape picker, which previews it on all of them (`kindControl`).
        if pageState.severalSwatches.contains(sender) { return ShapeColorPicker.shared.swatchClicked(sender) }
        ShapeColorPicker.shared.relinquish()
        swatchClicked(sender)
    }

    /// Writes a font choice: to the variable when the value is one `#Var#`, else where it is defined.
    func writeChoice(_ control: NSView, value: String) {
        guard let info = swatchEdits[ObjectIdentifier(control)], !inspectorState.isRebuilding else { return }
        writeProperty(section: info.section, key: info.key, value: value, variable: info.variable, label: info.key)
    }

    @objc func choiceChosen(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        writeChoice(sender, value: value)
    }

    // MARK: Self-test access

    /// The inspector's control for an option key (the main control of its row).
    func inspectorControl(for key: String) -> NSView? {
        inspectorStack.findSubview { $0.identifier?.rawValue.caseInsensitiveCompare(key) == .orderedSame }
            ?? inspectorStack.findSubview { v in
                guard let id = v.identifier?.rawValue else { return false }
                return id.lowercased().hasSuffix("/" + key.lowercased())
            }
    }

    /// Chooses a value for an option as a user would: a menu item, a segment, a checkbox (self-tests).
    @discardableResult
    func chooseOption(_ key: String, value: String) -> Bool {
        guard var view = inspectorControl(for: key) else { return false }
        if let image = view as? ImageControl { view = image.popup }
        if let row = view as? NSStackView, let popup = row.arrangedSubviews.first as? NSPopUpButton { view = popup }
        switch view {
        case let popup as NSPopUpButton:
            if let menu = popup.menu { menu.delegate?.menuNeedsUpdate?(menu) }
            guard let item = popup.menu?.items.first(where: {
                ($0.representedObject as? String)?.caseInsensitiveCompare(value) == .orderedSame
            }) else { return false }
            popup.select(item)
            popup.sendAction(popup.action, to: popup.target)
            return true
        case let seg as ChoiceSegmentedControl:
            guard let i = seg.values.firstIndex(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return false }
            seg.selectedSegment = i
            seg.sendAction(seg.action, to: seg.target)
            return true
        case let box as NSButton:
            box.state = OptionValue.bool(value) == true ? .on : .off
            box.sendAction(box.action, to: box.target)
            return true
        default:
            return false
        }
    }

    /// Chooses a value in a menu of the inspector by option name (self-tests).
    func chooseFontOption(_ key: String, value: String) -> Bool { chooseOption(key, value: value) }
}

extension EditorSchema {
    /// True when a value needs the skin to know it (`#Var#`, `[Section]`).
    static func isDynamicValue(_ value: String) -> Bool { value.contains("#") || value.contains("[") }
}

/// The font menu: every installed family, each in its own face, added when the menu first opens (building them on
/// every rebuild of the inspector was a large part of its cost).
final class FontPopUpButton: NSPopUpButton, NSMenuDelegate {
    static let placeholderTag = 7_001
    private(set) var isFilled = false

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isFilled else { return }
        isFilled = true
        let selected = selectedItem?.representedObject as? String
        for item in menu.items where item.tag == Self.placeholderTag { menu.removeItem(item) }
        for f in FontFamilies.all {
            let item = NSMenuItem(title: f.title.string, action: nil, keyEquivalent: "")
            item.attributedTitle = f.title
            item.representedObject = f.name
            menu.addItem(item)
        }
        if let selected, let item = menu.items.first(where: {
            ($0.representedObject as? String)?.caseInsensitiveCompare(selected) == .orderedSame
        }) {
            select(item)
        }
    }
}

/// The font families the FontFace menus list, each named in its own face. Listing them in the order the font panel
/// uses takes the system most of a tenth of a second the first time, and making a font of every family longer still,
/// so the inspector never waits for either: a closed pop-up names only its own family (`installed`, `title`), the
/// list is made when a menu first opens (`all`), and the faces are made beforehand in small steps once the editor
/// has opened (`prepare(in:)`).
enum FontFamilies {
    private static var names: [String]?
    private static var titles: [String: NSAttributedString] = [:]

    /// The installed family called `name` (in any case), as the system spells it; nil when there is none.
    static func installed(_ name: String) -> String? {
        name.isEmpty ? nil : Fonts.installedFamily(named: name)
    }

    /// `family` in its own face.
    static func title(_ family: String) -> NSAttributedString {
        if let title = titles[family] { return title }
        let font = NSFont(name: family, size: 13) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)
        let title = NSAttributedString(string: family, attributes: font.map { [.font: $0] } ?? [:])
        titles[family] = title
        return title
    }

    /// Every installed family in the font panel's order (made once), each in its own face.
    static var all: [(name: String, title: NSAttributedString)] {
        let list = names ?? NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        names = list
        return list.map { ($0, title($0)) }
    }

    /// Makes the faces of the families not made yet, a step each (most take a fraction of a millisecond, a few much
    /// longer: `steps` should have a budget).
    static func prepare(in steps: MainThreadSteps) {
        for family in Fonts.installedFamilyNames.sorted() where titles[family] == nil {
            steps.add("font face") { _ = title(family) }
        }
    }
}
