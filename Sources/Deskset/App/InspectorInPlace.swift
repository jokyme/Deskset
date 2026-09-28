import AppKit
import DesksetCore

// The inspector following a step in place (design §9.5, "按行 id 就地更新"): after a value edit, an undo or a redo the
// page is not built again (hundreds of milliseconds: the views, their constraints and a layout of the whole column) —
// only the rows whose values changed follow.
//
// While a page is built, the parts that can follow a value register as slots (`InspectorSlot`): a property row (its
// id is the lowercased `section/key`, the scheme `updateRuntimeValue` uses), a position or size row, the text, the
// alignment, the identity strip, a widget color row. Each slot says what it shows, split into what a setter can follow
// (`value`) and the rest (`shape`). The rows a slot shows are its claims: their values leave the page's structure
// (`inspectorInputParts`), which keeps everything else the page is built from — the selection, the disclosures, the
// row keys, the values no slot shows, and what is derived from values across the page (which settings are in use,
// visible, their defaults, the look a card's settings come from…: `inPlaceStructureExtras`).
//
// On a refresh (`reloadDetail`): with the same structure, each slot whose description changed is set in place (a
// setter per control kind), else its row is made again in its grid cell, else its part of the page is made again;
// when a slot can do none of these, or the structure changed, the page is built again as before. Controls keep a
// `Meter` or a `Skin` in their actions, so the page only follows in place while it shows the skin object it was built
// from (a patch keeps it; a reload makes a new one).
//
// `DESKSET_VERIFY_IN_PLACE=1` checks every in-place update against the page built again (pixels and a description of
// the views); differences are kept in `InspectorInPlace.mismatches` and printed.

/// A part of the inspector that follows a change of what it shows without the page being built again.
final class InspectorSlot {
    struct Shown: Equatable {
        /// What a setter cannot follow: when it changes, the row (or part) is made again.
        var shape: String
        /// What the setter follows.
        var value: String
    }

    /// The rows it shows (lowercased `section/key`; `variables/name` for a shared value; a page part's own name).
    let claims: [String]
    /// What it shows, from the skin as it is now (nil: it cannot tell, the page is built again).
    let describe: () -> Shown?
    /// What it showed when it was built or last followed.
    var shown = Shown(shape: "", value: "")
    /// Sets its controls to what `describe` says now (only when the shape is the same); false when it could not.
    var set: (() -> Bool)?
    /// Called on every update that follows anything, whether or not its description changed (the identity strip's
    /// picture of the layer, drawn from the running skin).
    var refresh: (() -> Void)?
    /// The row made again with the values as they are now (a row of a card's grid).
    var remakeRow: (() -> InspectorRow?)?
    /// The part made again (a view of the page's column, such as the identity strip).
    var remakePart: (() -> NSView?)?
    /// The row as it went into its grid: its label (inside the grid's label box) and its control cell.
    weak var label: NSView?
    weak var control: NSView?
    /// The part in the page's column.
    weak var part: NSView?
    /// The control the setter sets (inside `control`).
    weak var inner: NSView?

    init(claims: [String], describe: @escaping () -> Shown?) {
        self.claims = claims
        self.describe = describe
    }
}

/// The inspector's split inputs: what decides the page's parts, and the values of the rows slots show (by row id).
struct InspectorInputs: Equatable {
    var structure: [String] = []
    var values: [String: String] = [:]

    /// Everything, as one text (`lastInspectorInputs`).
    var text: String {
        (structure + values.keys.sorted().map { "value\u{1F}\($0)\u{1F}\(values[$0] ?? "")" }).joined(separator: "\n")
    }
}

/// The slots of the page on show and what it was built from.
final class InspectorInPlace {
    enum Page: Equatable { case none, meter(String), widget }

    /// Off: every change builds the page again (`defaults write app.deskset.Deskset StudioInspectorInPlace -bool NO`).
    static var isEnabled: Bool {
        !isOffForTests && (UserDefaults.standard.object(forKey: "StudioInspectorInPlace") as? Bool ?? true)
    }
    /// Every step builds the page again (self-tests of that setting, without writing the defaults).
    static var isOffForTests = false
    /// Every in-place update checked against the page built again (`DESKSET_VERIFY_IN_PLACE`).
    static var verifies = ProcessInfo.processInfo.environment["DESKSET_VERIFY_IN_PLACE"].map { $0 != "0" } ?? false
    /// What the checks found (`verifies`).
    static var mismatches: [String] = []

    static func rowID(_ section: String, _ key: String) -> String { "\(section)/\(key)".lowercased() }

    var slots: [InspectorSlot] = []
    /// The page whose slots are collected while it is built (`.none`: a page that always builds again).
    var page: Page = .none
    var collecting = false
    /// The skin the page was built from.
    weak var builtSkin: Skin?
    /// The inputs it was built from, or last followed.
    var built: InspectorInputs?
    /// The rows the slots show.
    var claims: Set<String> = []
    /// The skin the layer list was last loaded or followed for (`followListInPlace`).
    weak var listSkin: Skin?
    /// How many times the layer list followed a step in place.
    var listUpdates = 0
    /// Rows of other sections than the selected one, read once per update.
    var rowCache: [String: [InspectorWindowController.Row]] = [:]

    // What happened (self-tests, the latency suite).
    var updates = 0
    var setters = 0
    var remadeRows = 0
    var remadeParts = 0
    /// Why the last refresh built the page again ("structure", "no setter for …"; nil after an in-place update).
    var lastFallback: String?

    func reset() {
        slots = []
        claims = []
        built = nil
        builtSkin = nil
        rowCache = [:]
    }

    func add(_ slot: InspectorSlot) {
        // A row that wraps rows made by other registrations (a special control falling back to the usual one, the Number
        // row's own settings): the outer one follows, and makes them again with it.
        if let outer = slot.control ?? slot.part, outer !== slot.part || slot.remakePart != nil {
            slots.removeAll { inner in
                guard let view = inner.control ?? inner.part else { return false }
                return view === outer || view.isDescendant(of: outer)
            }
        }
        slots.append(slot)
    }
}

extension InspectorWindowController {
    // MARK: Building

    /// A page is about to be built: its slots are collected when it is a page that follows values in place.
    func beginInPlaceBuild() {
        inPlace.reset()
        inPlace.page = .none
        if !isMultiSelection, let skin {
            if let name = selectedSection {
                if selectedKind == .meter, skin.meter(named: name) != nil { inPlace.page = .meter(name) }
            } else {
                inPlace.page = .widget
            }
        }
        inPlace.collecting = InspectorInPlace.isEnabled && inPlace.page != .none
    }

    /// The page is built: what each slot shows, what they claim, and the inputs split by those claims (returned as the
    /// text `lastInspectorInputs` keeps).
    func finishInPlaceBuild() -> String? {
        let state = inPlace
        state.collecting = false
        state.rowCache = [:]
        state.builtSkin = skin
        // Slots whose views did not make it into the page (a card dropped by a later rebuild) are left out.
        state.slots.removeAll { slot in (slot.control ?? slot.part) == nil }
        namingShared {
            for slot in state.slots { if let shown = slot.describe() { slot.shown = shown } }
        }
        state.claims = Set(state.slots.flatMap(\.claims))
        if InspectorInPlace.debugs, ProcessInfo.processInfo.environment["DESKSET_IN_PLACE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("Studio in place: built \(state.page) with slots \(state.slots.map { $0.claims.joined(separator: "+") })\n".utf8))
        }
        let inputs = inspectorInputParts()
        state.built = inputs
        return inputs?.text
    }

    /// Registers a property row (`propertyRow`): its control is set in place when it has a setter for the value's
    /// kind, else the row is made again. Rows of several layers (a group's page) are not registered.
    func inPlaceRow(_ row: InspectorRow, property p: EditorSchema.Property, section: String, key: String, control: NSView,
                    groups: [EditorSchema.Group], friendly: Bool, dot: Bool, selection: [String]?) -> InspectorRow {
        guard inPlace.collecting, selection == nil, Self.followsInPlace(p.kind) else { return row }
        let id = InspectorInPlace.rowID(section, key)
        let slot = InspectorSlot(claims: [id]) { [weak self] in
            self?.describeProperty(p, section: section, key: key)
        }
        slot.label = row.label
        slot.control = row.control
        slot.inner = control
        slot.remakeRow = { [weak self] in
            guard let self else { return nil }
            let fresh = self.row(for: p, in: self.inPlaceRows(of: section))
            return self.propertyRow(p, section: section, row: fresh, groups: groups, friendly: friendly, dot: dot)
        }
        slot.set = { [weak self, weak slot] in
            guard let self, let slot else { return false }
            return self.setProperty(p, section: section, slot: slot)
        }
        inPlace.add(slot)
        return row
    }

    /// The kinds a property row follows in place (the others are part of the page's structure: a change builds it again).
    static func followsInPlace(_ kind: EditorSchema.Kind) -> Bool {
        switch kind {
        case .bool, .choice, .number, .text, .color, .percent255, .angle, .font, .alignment9: return true
        default: return false
        }
    }

    /// The rows of a section as they are now (the selected section's are `rows`).
    func inPlaceRows(of section: String) -> [Row] {
        if let selected = selectedSection, selected.caseInsensitiveCompare(section) == .orderedSame { return rows }
        let key = section.lowercased()
        if let cached = inPlace.rowCache[key] { return cached }
        let fresh = rows(of: section, kind: key == "variables" ? .variables : nil)
        inPlace.rowCache[key] = fresh
        return fresh
    }

    // MARK: Property rows

    /// What a property row shows: its value for the setter; the rest (how it is written, where it comes from, what is
    /// said under it) is its shape.
    func describeProperty(_ p: EditorSchema.Property, section: String, key: String) -> InspectorSlot.Shown? {
        let r = row(for: p, in: inPlaceRows(of: section))
        // The row's key as written (an older spelling) is part of the page's structure.
        guard (r?.key ?? p.key).caseInsensitiveCompare(key) == .orderedSame else { return nil }
        let ctx = context(p, section: section, rows: inPlaceRows(of: section))
        var shape: [String] = ["\(ctx.form)", r.map { "\($0.style)" } ?? "unset", ctx.isSet ? "set" : ""]
        if let r {
            if ctx.form == .literal { shape.append(propertyIssue(p, row: r, section: section) ?? "") }
            if r.style == .inherited { shape.append(inheritedStyle(section: section, key: key) ?? "") }
            if r.style == .runtime { shape.append(r.sourceTip) }
            if r.style == .own { shape.append(differsFromItsLook(section: section, key: key) ? "differs" : "") }
        }
        // A variable's pill shows its current value.
        if ctx.variable != nil { shape.append(ctx.resolved) }
        var value: [String] = []
        switch p.kind {
        case .number:
            let text = ctx.variable != nil ? ctx.resolved : ctx.raw
            let plain = !(ctx.isSet && ctx.variable == nil
                && (OptionValue.number(text) == nil || EditorSchema.issue(for: text, property: p) != nil))
            shape.append(plain ? "number" : "text")
            shape.append(LenientNumberFormatter.isExpression(text) ? "expression" : "")
            value.append(text)
        case .bool:
            let n = OptionValue.number(ctx.effective)
            shape.append(n == nil ? "mixed" : "")
            value.append(n.map { $0 != 0 ? "on" : "off" } ?? "mixed")
        case .text:
            value.append(ctx.raw)
        case .choice(let choices, let style):
            let written = ctx.effective.trimmingCharacters(in: .whitespaces)
            let v = written.isEmpty ? p.defaultValue : written
            let match = EditorSchema.choice(for: v, in: choices)
            let segmented = style == .segmented && match != nil && segmentLabels(choices) != nil
            if segmented {
                shape.append("segmented")
                value.append(match?.value ?? "")
            } else {
                // A pop-up's menu holds the value itself when it is not one of the choices: made again.
                shape.append("popup \(v)")
            }
        case .color:
            // The color control follows its color, name and tooltip (`ColorControl.follow`, which also tells when it
            // would be laid out differently).
            let fallback = ctx.isSet ? nil : Self.visibleDefaultColor(p)
            let color = ctx.isSet ? OptionValue.color(ctx.resolved) : fallback
            shape += [matchTheOthersLink(section: section, key: key) == nil ? "" : "match",
                      color.map { $0.a < 254.5 && (ctx.isSet || fallback != nil) } == true ? "opacity" : ""]
            value += [ctx.raw, ctx.resolved, colorName(ctx), colorTooltip(color, ctx: ctx)]
        default:
            shape += [ctx.raw, ctx.resolved, ctx.effective]
        }
        return InspectorSlot.Shown(shape: shape.joined(separator: "\u{1F}"), value: value.joined(separator: "\u{1F}"))
    }

    /// Sets a property row's control to its value now, as `kindControl` makes it.
    func setProperty(_ p: EditorSchema.Property, section: String, slot: InspectorSlot) -> Bool {
        let ctx = context(p, section: section, rows: inPlaceRows(of: section))
        switch (p.kind, slot.inner) {
        case (.number(_, _, _, _), let control as NumberControl):
            let text = ctx.variable != nil ? ctx.resolved : ctx.raw
            setNumberField(control.field, to: text)
            control.stepper?.doubleValue = OptionValue.number(text) ?? OptionValue.number(p.defaultValue) ?? 0
            return true
        case (.bool, let row as CheckboxRow):
            guard let n = OptionValue.number(ctx.effective) else { return false }
            row.box.state = n != 0 ? .on : .off
            return true
        case (.text, let field as ValueField):
            setValueField(field, to: ctx.raw)
            return true
        case (.color, let control as ColorControl):
            return control.follow(ctx)
        case (.choice(let choices, _), let seg as ChoiceSegmentedControl):
            let written = ctx.effective.trimmingCharacters(in: .whitespaces)
            let match = EditorSchema.choice(for: written.isEmpty ? p.defaultValue : written, in: choices)
            seg.selectedSegment = choices.firstIndex { $0.value == match?.value } ?? -1
            return true
        default:
            return false
        }
    }

    /// A number field set as `NumberField.init` makes it (a field being edited keeps the typing unless the value
    /// written changed).
    func setNumberField(_ field: NumberField, to text: String) {
        setText(of: field, to: text) {
            field.stringValue = text
            if let n = field.objectValue as? NSNumber { field.original = field.formatter?.string(for: n) ?? text } else { field.original = text }
        }
    }

    /// A value field set as `ValueField.init` makes it.
    func setValueField(_ field: ValueField, to text: String) {
        setText(of: field, to: text) {
            field.stringValue = text
            field.original = text
        }
    }

    /// Sets a field's text with `apply`. A field being edited takes the new value the way a rebuilt one would
    /// (`restoreInspectorFocus`): the typing goes when the written value changed, and the caret stays where it was.
    func setText(of field: ValueField, to text: String, _ apply: () -> Void) {
        guard let editor = field.currentEditor() as? NSTextView else { return apply() }
        let selection = editor.selectedRange()
        let typed = editor.string
        let before = field.original
        apply()
        if typed != before, field.original == before {
            // Only what the field started from is written: the typing goes on.
            editor.string = typed
        } else {
            editor.string = field.stringValue
        }
        let length = (editor.string as NSString).length
        if selection.location <= length {
            editor.selectedRange = NSRange(location: selection.location, length: min(selection.length, length - selection.location))
        }
    }

    // MARK: Special rows of a layer's page

    /// Registers X, Y, W or H of the Position and Size card (`geometryRow`; not a group's "Starts at").
    func inPlaceGeometry(_ row: InspectorRow, meter m: Meter, key: String, run: [String]?) -> InspectorRow {
        guard inPlace.collecting, run == nil, inPlace.page == .meter(m.name) else { return row }
        let name = m.name
        // X and Y are named after the alignment ("X (right edge)").
        let claims = [InspectorInPlace.rowID(name, key)] + (key == "X" || key == "Y" ? [InspectorInPlace.rowID(name, "StringAlign")] : [])
        let slot = InspectorSlot(claims: claims) { [weak self] in self?.describeGeometry(name, key: key) }
        slot.label = row.label
        slot.control = row.control
        slot.inner = row.control.findSubview { $0 is GeometryField && $0.identifier?.rawValue == "\(name)/\(key)" }
        slot.remakeRow = { [weak self] in
            guard let self, let skin = self.skin, let m = skin.meter(named: name) else { return nil }
            let (raw, current) = Self.geometry(of: m, key: key)
            return self.geometryRow(m, key: key, raw: raw, current: current, skin: skin)
        }
        slot.set = { [weak self, weak slot] in
            guard let self, let slot, let field = slot.inner as? GeometryField, let m = self.skin?.meter(named: name) else { return false }
            let (raw, current) = Self.geometry(of: m, key: key)
            let empty = (key == "W" || key == "H") && raw.trimmingCharacters(in: .whitespaces).isEmpty
            self.setValueField(field, to: empty ? "" : GeometryEdit.format(current))
            field.placeholderString = empty ? GeometryEdit.format(current) : "0"
            return true
        }
        inPlace.add(slot)
        return row
    }

    /// X, Y, W or H as written and in effect (`positionCard`).
    static func geometry(of m: Meter, key: String) -> (raw: String, current: Double) {
        let raw = m.rawGeometry
        switch key {
        case "X": return (raw.x ?? "", m.anchorX)
        case "Y": return (raw.y ?? "", m.anchorY)
        case "W": return (raw.w ?? "", m.frame.width)
        default: return (raw.h ?? "", m.frame.height)
        }
    }

    func describeGeometry(_ name: String, key: String) -> InspectorSlot.Shown? {
        guard let skin, let m = skin.meter(named: name) else { return nil }
        let (raw, current) = Self.geometry(of: m, key: key)
        let label = key == "X" || key == "Y" ? Self.positionLabel(key, meter: m) : key
        let link = geometryLink(m, key: key, raw: raw, skin: skin)
        let id = "\(name)/\(key)".lowercased()
        let shape = [label, link.map { "\($0.title)\u{1E}\($0.kind)" } ?? "", link == nil ? "" : raw,
                     inspectorState.disclosures.contains("shared/\(id)") ? "shared" : "",
                     inspectorState.disclosures.contains("calc/\(id)") ? "calc \(raw)" : ""]
        let empty = (key == "W" || key == "H") && raw.trimmingCharacters(in: .whitespaces).isEmpty
        // The linked value's tag keeps the number in effect for its menu ("Use a Fixed Number Here").
        let value = [empty ? "" : GeometryEdit.format(current), empty ? GeometryEdit.format(current) : "0",
                     link == nil ? "" : GeometryEdit.format(current)]
        return InspectorSlot.Shown(shape: shape.joined(separator: "\u{1F}"), value: value.joined(separator: "\u{1F}"))
    }

    /// Registers the Text row (`textRow`): a field set in place; the text with live data tags is made again.
    func inPlaceText(_ row: InspectorRow, context ctx: PropertyContext, meter m: Meter, data: Bool) -> InspectorRow {
        guard inPlace.collecting, inPlace.page == .meter(m.name) else { return row }
        let name = m.name, p = ctx.property
        let slot = InspectorSlot(claims: [InspectorInPlace.rowID(name, ctx.key)]) { [weak self] in
            guard let self, let m = self.skin?.meter(named: name) else { return nil }
            let c = self.context(p, section: name, rows: self.rows)
            let names = m.measureSlots.enumerated().compactMap { i, slot -> String? in
                guard let slot, let skin = self.skin else { return nil }
                return "\(i + 1)=\(self.dataName(slot, in: skin))"
            }
            return InspectorSlot.Shown(shape: [c.key, data ? "data" : "", data ? c.raw : "", names.joined(separator: ",")]
                                        .joined(separator: "\u{1F}"), value: data ? "" : c.raw)
        }
        slot.label = row.label
        slot.control = row.control
        slot.inner = row.control as? ValueField
        slot.remakeRow = { [weak self] in
            guard let self, let m = self.skin?.meter(named: name) else { return nil }
            return self.textRow(self.context(p, section: name, rows: self.rows), meter: m, data: data)
        }
        slot.set = { [weak self, weak slot] in
            guard let self, let field = slot?.inner as? ValueField, !data else { return false }
            self.setValueField(field, to: self.context(p, section: name, rows: self.rows).raw)
            return true
        }
        inPlace.add(slot)
        return row
    }

    /// Registers Align (Left | Center | Right) or Up and down (Top | Middle | Bottom), the two parts of StringAlign.
    func inPlaceAlign(_ row: InspectorRow, context ctx: PropertyContext, vertical: Bool) -> InspectorRow {
        guard inPlace.collecting, inPlace.page == .meter(ctx.section), let seg = row.control as? NSSegmentedControl else { return row }
        let section = ctx.section, p = ctx.property
        let slot = InspectorSlot(claims: [InspectorInPlace.rowID(section, ctx.key)]) { [weak self] in
            guard let self else { return nil }
            let c = self.context(p, section: section, rows: self.rows)
            let value = c.isSet ? c.raw : p.defaultValue
            // The special control shows a literal, valid value (the usual row otherwise); Up and down's label has the
            // dot of a setting in use.
            let special = c.form == .literal && c.variable == nil
                && (!c.isSet || EditorSchema.issue(for: value, property: p) == nil)
            let (h, v) = Self.alignParts(value)
            return InspectorSlot.Shown(shape: [special ? "special" : "usual \(c.raw)", c.key, vertical && v != 0 ? "dot" : ""]
                                        .joined(separator: "\u{1F}"), value: "\(h) \(v)")
        }
        slot.label = row.label
        slot.control = row.control
        slot.inner = seg
        slot.remakeRow = { [weak self] in
            guard let self else { return nil }
            let c = self.context(p, section: section, rows: self.rows)
            if vertical { return self.skin?.meter(named: section).flatMap { self.upAndDownRow($0)?.row } }
            return self.alignRow(c)
        }
        slot.set = { [weak self, weak slot] in
            guard let self, let seg = slot?.inner as? NSSegmentedControl else { return false }
            let c = self.context(p, section: section, rows: self.rows)
            let (h, v) = Self.alignParts(c.isSet ? c.raw : p.defaultValue)
            // The action writes the other part as it is now.
            let write = self.writer(c)
            seg.selectedSegment = vertical ? v : h
            seg.onAction { control in
                guard let s = control as? NSSegmentedControl, s.selectedSegment >= 0 else { return }
                write(vertical ? Self.alignValue(h: h, v: s.selectedSegment) : Self.alignValue(h: s.selectedSegment, v: v))
            }
            return true
        }
        inPlace.add(slot)
        return row
    }

    /// Registers the identity strip of a layer: its picture follows every update; its words and buttons (the name, the
    /// sentence, Show / Hide, Lock) make it again when they change.
    func inPlaceStrip(_ strip: NSView, meter m: Meter) -> NSView {
        guard inPlace.collecting, inPlace.page == .meter(m.name) else { return strip }
        let name = m.name
        let slot = InspectorSlot(claims: [InspectorInPlace.rowID(name, "Hidden"), "strip"]) { [weak self] in
            guard let self, let skin = self.skin, let m = skin.meter(named: name) else { return nil }
            let layer = LayerNaming.layer(m, in: skin)
            let looks = OptionValue.list(m.rawOption("MeterStyle") ?? "").filter { skin.document.section(named: $0) != nil }
            let location = self.showsDetails ? skin.sources.location(section: name)?.description ?? "" : ""
            let crumbs = self.series(containing: name, in: skin).map { self.countedLayers($0.members, in: skin) } ?? ""
            // (Its warning when part of it is cut off says which edges.)
            let cut = Self.cutOffEdges(of: m, in: skin)
            let shape = [layer.title, layer.sentence, layer.symbol, "\(m.hidden)", "\(self.isLayerLocked(name))",
                         looks.joined(separator: ","), location, crumbs, self.widgetName(skin), "\(cut)",
                         self.cutOffSentence(of: name) ?? ""]
            return InspectorSlot.Shown(shape: shape.joined(separator: "\u{1F}"), value: "")
        }
        slot.part = strip
        slot.remakePart = { [weak self] in
            guard let self, let skin = self.skin, let m = skin.meter(named: name) else { return nil }
            return self.layerStrip(m, skin: skin)
        }
        slot.refresh = { [weak self, weak slot] in
            guard let self, let skin = self.skin, let picture = slot?.part?.findSubview(where: {
                $0.identifier?.rawValue == "strip-picture" }) as? NSImageView else { return }
            // The picture's kind (the layer's pixels or its symbol) is the strip's shape: made again when it changes.
            if let image = self.layerPicture([name], in: skin), picture.imageScaling != .scaleNone { picture.image = image }
        }
        slot.set = { true }
        inPlace.add(slot)
        return strip
    }

    // MARK: The widget page

    /// Registers one of the widget's colors (`colorRow`): its swatch follows the color, the row is made again when
    /// what it says changes.
    func inPlaceColorRow(_ row: ValueRowView, group: ValueUsageIndex.ColorGroup, index: Int, otherWidgets: Bool) -> ValueRowView {
        guard inPlace.collecting, inPlace.page == .widget, !otherWidgets, !group.variables.isEmpty else { return row }
        let claims = group.variables.map { InspectorInPlace.rowID("Variables", $0) }
        let slot = InspectorSlot(claims: claims) { [weak self] in
            guard let self, let group = self.inPlaceColorGroup(index) else { return nil }
            let opacity = group.color.a < 254.5 ? "\(Int((group.color.a / 255 * 100).rounded()))%" : ""
            // Its name and what else it changes (the roles of its uses, which name texts by their words now).
            // (Its users are named by their words now: "Used by “Hello”".)
            let shape = [group.name, group.variables.joined(separator: ","), opacity, group.usedRoles.map(\.name).joined(separator: ","),
                         "\(group.unusedCount)", self.usersPhrase(group.sections, atLeast: group.isAtLeast),
                         self.usersPhrase(group.sections)]
            return InspectorSlot.Shown(shape: shape.joined(separator: "\u{1F}"), value: "\(group.color)\u{1F}\(self.colorGroupTip(group))")
        }
        slot.part = row
        slot.remakePart = { [weak self] in
            guard let self, let group = self.inPlaceColorGroup(index) else { return nil }
            return self.colorRow(group, index: index)
        }
        slot.set = { [weak self, weak slot] in
            guard let self, let row = slot?.part as? ValueRowView, let group = self.inPlaceColorGroup(index),
                  let swatch = row.findSubview(where: { $0.identifier?.rawValue == "color-swatch:\(index)" }) as? SwatchButton
            else { return false }
            let tip = self.colorGroupTip(group)
            row.group = group
            swatch.color = group.color
            swatch.toolTip = tip
            (row.findSubview { $0.identifier?.rawValue == "color-name:\(index)" })?.toolTip = tip
            swatch.onAction { [weak self, weak swatch] _ in
                guard let self, let swatch else { return }
                self.colorRowMenu(group).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: swatch)
            }
            return true
        }
        inPlace.add(slot)
        return row
    }

    /// The widget page's color groups as the page lists them now.
    func inPlaceColorGroup(_ index: Int) -> ValueUsageIndex.ColorGroup? {
        guard let skin else { return nil }
        let groups = widgetColorGroups(skin)
        return index < groups.count ? groups[index] : nil
    }

    /// The widget's colors as its pages list them (`ValueUsageIndex.colorGroups`), made once for each state of the
    /// skin: every color control names its color by them.
    func widgetColorGroups(_ skin: Skin) -> [ValueUsageIndex.ColorGroup] {
        let index = valueUsages(skin)
        let separate = inspectorState.separateColors, expert = app.state.editor.showIniNames
        let key = "\(separate.sorted())|\(expert)"
        if let cache = inspectorState.usageCache, cache.skin === skin, let groups = cache.colorGroups[key] { return groups }
        let groups = index.colorGroups(separate: separate, includeInternal: expert)
        if let cache = inspectorState.usageCache, cache.skin === skin { cache.colorGroups[key] = groups }
        return groups
    }

    /// A color row's tooltip (`colorRow`).
    func colorGroupTip(_ group: ValueUsageIndex.ColorGroup) -> String {
        app.state.editor.showIniNames
            ? (group.variables.isEmpty ? "Written directly" : group.variables.joined(separator: ", ")) + " · " + (group.members.first?.current ?? "")
            : "\(Self.hex(group.color)) · \(Int((group.color.a / 255 * 100).rounded()))% opacity"
    }

    /// Registers the widget page's header: its picture of the widget follows every update.
    func inPlaceWidgetHeader(_ header: NSView) -> NSView {
        guard inPlace.collecting, inPlace.page == .widget else { return header }
        let slot = InspectorSlot(claims: ["widget-header"]) { InspectorSlot.Shown(shape: "", value: "") }
        slot.part = header
        slot.refresh = { [weak self, weak slot] in
            guard let self, let skin = self.skin, let header = slot?.part,
                  let picture = header.findSubview(where: { $0 is NSImageView && $0.accessibilityLabel() == "Picture of the widget" })
                    as? NSImageView else { return }
            picture.image = self.widgetThumbnail(skin, side: 48)
        }
        inPlace.add(slot)
        return header
    }

    // MARK: What is derived across the page

    /// What the page's parts are derived from beyond the rows (for `inspectorInputParts`): which settings are in use,
    /// visible and what their defaults are (the dots, "· 2 in use", the rows shown), the look a card's settings come
    /// from, and what the layer's page decides from its values (the text shows live data, the size fits the content…).
    func inPlaceStructureExtras() -> [String] {
        guard let skin else { return [] }
        var lines: [String] = []
        switch inPlace.page {
        case .meter(let name):
            guard let m = skin.meter(named: name) else { return ["gone"] }
            let groups = EditorSchema.meterGroups(m.type)
            let lookup = valueLookup(rows)
            var properties = groups.flatMap(\.properties)
            for r in rows {
                if let n = EditorSchema.numberedProperty(r.key, in: groups), n.index > 1 {
                    properties.append(EditorSchema.numbered(n.property, index: n.index, in: groups))
                }
            }
            for p in properties {
                // (Whether a setting is in use — the dots and "· 2 in use" of a card's More — is the card's:
                // `inPlaceCardGuard`.)
                lines.append(["property", p.key, EditorSchema.isVisible(p, in: groups, values: lookup) ? "visible" : "",
                              EditorSchema.defaultValue(of: p, in: groups, values: lookup)].joined(separator: "\u{1F}"))
            }
            // (The look behind a card's settings is its title row's: `inPlaceCardTitle`.)
            let raw = m.rawGeometry
            let data = m.measures.first
            lines.append(["layer", (m.rawOption("MeasureName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "" : "data",
                          data.map { isTime($0) ? "time" : "" } ?? "", data.map { Self.isTextData($0) ? "words" : "" } ?? "",
                          (raw.w ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "" : "w",
                          (raw.h ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "" : "h",
                          m.type.lowercased() == "shape" ? "\(shapeItems(of: name).count)" : ""]
                .joined(separator: "\u{1F}"))
            lines.append("panel\u{1F}\(widgetPanelColor().map { "\($0)" } ?? "")")
        case .widget:
            let groups = widgetColorGroups(skin)
            // Which colors are rows, in which order (a row says the rest: `inPlaceColorRow`); a color written directly
            // is part of the structure.
            // (Same-value colors nothing here uses join a row and leave it with their color: the row says so.)
            for g in groups {
                lines.append(["color group", g.variables.isEmpty ? "\(g.name) \(g.color) \(g.usedRoles.map(\.name))" : "",
                              g.sharedFile?.path ?? "",
                              g.members.filter { !$0.uses.isEmpty }.map(\.variableName).map { $0 ?? "" }.joined(separator: ",")]
                    .joined(separator: "\u{1F}"))
            }
            // The colors only other widgets use (More Widget Options): a color that leaves a row joins them.
            lines.append("other colors\u{1F}" + valueUsages(skin).colorsOtherWidgetsUse().compactMap(\.variableName).joined(separator: ","))
            lines.append("panel\u{1F}\(widgetPanelColor().map { "\($0)" } ?? "")")
        case .none:
            break
        }
        return lines
    }

    // MARK: Following a step

    /// Follows a refresh in place when only values the slots show changed (`reloadDetail`). Returns false when the
    /// page must be built again: another page, another skin object, a change of its structure, a slot that can
    /// neither set nor make its row again.
    func updateInspectorInPlace() -> Bool {
        let state = inPlace
        guard InspectorInPlace.isEnabled, deferredInspectorRebuild == nil, let skin, state.builtSkin === skin,
              let built = state.built, !inspectorState.isRebuilding, inspectorState.partSteps == nil, !isOpening else {
            state.lastFallback = "not built"
            return false
        }
        state.rowCache = [:]
        guard let now = inspectorInputParts() else { return false }
        guard now.structure == built.structure else {
            state.lastFallback = "structure"
            if InspectorInPlace.debugs {
                let a = Set(built.structure), b = Set(now.structure)
                var text = "Studio in place: structure changed: -\(a.subtracting(b).sorted()) +\(b.subtracting(a).sorted())"
                if a == b, let i = zip(built.structure, now.structure).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                    text += " order at #\(i): \(built.structure[i]) / \(now.structure[i])"
                }
                Log.write(text, level: .debug, source: config)
                if ProcessInfo.processInfo.environment["DESKSET_IN_PLACE_DEBUG"] != nil {
                    FileHandle.standardError.write(Data((text + "\n").utf8))
                }
            }
            return false
        }
        enum Action { case set, row, part, refresh }
        var plan: [(InspectorSlot, InspectorSlot.Shown, Action)] = []
        let described: Bool = namingShared {
            for slot in state.slots {
                guard let shown = slot.describe() else {
                    state.lastFallback = "a slot of \(slot.claims.joined(separator: ",")) cannot tell"
                    return false
                }
                if ProcessInfo.processInfo.environment["DESKSET_IN_PLACE_TRACE"].map({ slot.claims.contains($0) }) == true {
                    FileHandle.standardError.write(Data("Studio in place: trace \(slot.claims) \(slot.shown) → \(shown) control \(slot.control.map { "\(type(of: $0)) in grid \($0.superview is NSGridView) window \($0.window != nil)" } ?? "nil")\n".utf8))
                }
                if shown == slot.shown {
                    // A picture of the running widget follows every update (a page built again draws it anew).
                    if slot.refresh != nil { plan.append((slot, shown, .refresh)) }
                    continue
                }
                if shown.shape == slot.shown.shape, slot.set != nil {
                    plan.append((slot, shown, .set))
                } else if slot.remakeRow != nil, let control = slot.control, control.superview is NSGridView {
                    plan.append((slot, shown, .row))
                } else if slot.remakePart != nil, let part = slot.part, part.superview != nil {
                    plan.append((slot, shown, .part))
                } else {
                    state.lastFallback = "no way to follow \(slot.claims.joined(separator: ","))"
                    return false
                }
            }
            return true
        }
        guard described else { return false }
        // The keyboard focus is moving to a control that may be one made again: built again once the click is over
        // (`reloadDetail`).
        if plan.contains(where: { $0.2 == .row || $0.2 == .part }), (window as? EditorWindow)?.isChangingFirstResponder == true {
            state.lastFallback = "focus moving"
            return false
        }
        if InspectorInPlace.debugs, ProcessInfo.processInfo.environment["DESKSET_IN_PLACE_DEBUG"] != nil {
            let text = plan.map { "\($0.2) \($0.0.claims.joined(separator: ",")): \($0.0.shown.shape.debugDescription)→\($0.1.shape.debugDescription) \($0.0.shown.value.debugDescription)→\($0.1.value.debugDescription)" }
            FileHandle.standardError.write(Data("Studio in place: \(text.joined(separator: " | "))\n".utf8))
        }
        var ok = true
        inspectorState.isRebuilding = true
        namingShared {
            for (slot, shown, action) in plan where ok {
                switch action {
                case .refresh:
                    slot.refresh?()
                case .set:
                    if slot.set?() == true {
                        state.setters += 1
                        slot.refresh?()
                    } else if slot.remakeRow != nil, remakeRow(of: slot) {
                        state.remadeRows += 1
                    } else if slot.remakePart != nil, remakePart(of: slot) {
                        state.remadeParts += 1
                    } else {
                        ok = false
                    }
                case .row:
                    if remakeRow(of: slot) { state.remadeRows += 1 } else { ok = false }
                case .part:
                    if remakePart(of: slot) { state.remadeParts += 1 } else { ok = false }
                }
                slot.shown = shown
            }
        }
        inspectorState.isRebuilding = false
        guard ok else {
            state.lastFallback = "a row could not be made again"
            return false
        }
        state.built = now
        state.updates += 1
        state.lastFallback = nil
        lastInspectorInputs = now.text
        refreshLiveValues()
        inspectorState.liveUpdates.forEach { $0() }
        if InspectorInPlace.verifies { verifyInPlaceUpdate() }
        return true
    }

    /// Puts a slot's row made again into its grid cells, as `EditorStyle.grid` placed the first one.
    func remakeRow(of slot: InspectorSlot) -> Bool {
        guard let make = slot.remakeRow, let old = slot.control, let grid = old.superview as? NSGridView,
              let cell = grid.cell(for: old), let gridRow = cell.row else { return false }
        let index = grid.index(of: gridRow)
        guard index >= 0, let row = make() else { return false }
        forgetEdits(in: old)
        if let label = slot.label { forgetEdits(in: label) }
        // A cell given another view keeps the one it had among the grid's subviews: taken out here.
        let oldLabelBox = grid.cell(atColumnIndex: 0, rowIndex: index).contentView
        defer {
            if old.superview === grid { old.removeFromSuperview() }
            if let box = oldLabelBox, box !== old, box.superview === grid,
               grid.cell(atColumnIndex: 0, rowIndex: index).contentView !== box { box.removeFromSuperview() }
        }
        if row.fullWidth {
            cell.contentView = row.control
        } else {
            let line = EditorStyle.firstLineHeight(of: row.control)
            let label = row.label.map { EditorStyle.labelCell($0, height: line) }
            grid.cell(atColumnIndex: 0, rowIndex: index).contentView = label ?? NSGridCell.emptyContentView
            grid.cell(atColumnIndex: 1, rowIndex: index).contentView = row.control
            if let stack = row.control as? NSStackView, stack.orientation == .vertical {
                stack.setHuggingPriority(.defaultLow - 1, for: .vertical)
            }
            if let label { EditorStyle.yieldWidth(label) }
        }
        EditorStyle.yieldWidth(row.control)
        prepareInspectorFields(in: row.control)
        slot.label = row.label
        slot.control = row.control
        slot.inner = Self.innerControl(of: slot, in: row.control)
        return true
    }

    /// The control a slot's setter sets inside its row made again.
    static func innerControl(of slot: InspectorSlot, in control: NSView) -> NSView? {
        switch slot.inner {
        case is NumberControl: return control.findSubview(where: { $0 is NumberControl }) ?? (control as? NumberControl)
        case is CheckboxRow: return control.findSubview(where: { $0 is CheckboxRow }) ?? (control as? CheckboxRow)
        case is ChoiceSegmentedControl: return control.findSubview(where: { $0 is ChoiceSegmentedControl }) ?? (control as? ChoiceSegmentedControl)
        case is GeometryField: return control.findSubview(where: { $0 is GeometryField })
        case is NSSegmentedControl: return control.findSubview(where: { $0 is NSSegmentedControl }) ?? (control as? NSSegmentedControl)
        case is ColorControl: return control.findSubview(where: { $0 is ColorControl }) ?? (control as? ColorControl)
        case is ValueField: return control.findSubview(where: { $0 is ValueField }) ?? (control as? ValueField)
        default: return nil
        }
    }

    /// Puts a slot's part made again where it was: in the page's column (the identity strip) or a card (a color row).
    func remakePart(of slot: InspectorSlot) -> Bool {
        guard let make = slot.remakePart, let old = slot.part, let stack = old.superview as? NSStackView,
              let index = stack.arrangedSubviews.firstIndex(of: old), let part = make() else { return false }
        forgetEdits(in: old)
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        stack.insertArrangedSubview(part, at: index)
        if stack === inspectorStack {
            part.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor, constant: -32).isActive = true
            inspectorState.preparedParts.remove(ObjectIdentifier(old))
            yieldWidthOnce(part)
        } else {
            // A card's content (`EditorCard.append`).
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * EditorStyle.cardPadding).isActive = true
            EditorStyle.yieldWidth(part)
        }
        prepareInspectorFields(in: part)
        slot.part = part
        return true
    }

    /// The fields and swatches of views taken out: what they edit is forgotten (a new view could get their identity).
    func forgetEdits(in view: NSView) {
        for v in [view] + view.subviewsMatching({ _ in true }) {
            fieldEdits[ObjectIdentifier(v)] = nil
            swatchEdits[ObjectIdentifier(v)] = nil
        }
    }
}

extension InspectorInPlace {
    /// Logs why a refresh built the page again (`defaults write app.deskset.Deskset StudioInPlaceDebug -bool YES`).
    static var debugs: Bool {
        UserDefaults.standard.bool(forKey: "StudioInPlaceDebug") || ProcessInfo.processInfo.environment["DESKSET_IN_PLACE_DEBUG"] != nil
    }
}

// MARK: - Checking

extension InspectorWindowController {
    /// The inspector's column as drawn (2×) and a description of its views: what an in-place update must leave the
    /// same as a page built again.
    struct InspectorPicture: Equatable {
        var pixels: Data
        var views: [String]
        /// The column as a PNG (checks that write what differs).
        var png: Data? = nil

        static func == (a: InspectorPicture, b: InspectorPicture) -> Bool { a.pixels == b.pixels && a.views == b.views }
    }

    func inspectorPicture() -> InspectorPicture {
        window?.contentView?.layoutSubtreeIfNeeded()
        var pixels = Data()
        if let document = inspectorScroll.documentView, document.bounds.width > 0, document.bounds.height > 0,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(document.bounds.width * 2),
                                      pixelsHigh: Int(document.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = document.bounds.size
            document.cacheDisplay(in: document.bounds, to: rep)
            if let data = rep.bitmapData { pixels = Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh) }
            if ProcessInfo.processInfo.environment["DESKSET_VERIFY_IN_PLACE_DIR"] != nil {
                return InspectorPicture(pixels: pixels, views: Self.describeViews(inspectorStack),
                                        png: rep.representation(using: .png, properties: [:]))
            }
        }
        return InspectorPicture(pixels: pixels, views: Self.describeViews(inspectorStack))
    }

    /// Every view under `root`: kind, identifier, frame and what it shows (text, state, tooltip, color).
    static func describeViews(_ root: NSView) -> [String] {
        var lines: [String] = []
        func visit(_ view: NSView, depth: Int) {
            // Where it is in the column (a frame in a box of open height would say where it is in the box).
            let f = view.convert(view.bounds, to: root)
            // A plain view that only holds others (the box of a row's label) draws nothing: where its children are is
            // what shows. (Its height can be left open by a row taller than its label: any height is right.)
            let plain = type(of: view) == NSView.self && view.layer?.backgroundColor == nil
            var line = "\(depth) \(type(of: view)) \(view.identifier?.rawValue ?? "-") "
                + (plain ? "" : String(format: "%.1f,%.1f %.1fx%.1f", f.minX, f.minY, f.width, f.height))
                + (view.isHidden ? " hidden" : "")
            if let tip = view.toolTip { line += " tip“\(tip)”" }
            if let field = view as? NSTextField {
                line += " “\(field.stringValue)”"
                if let p = field.placeholderString, !p.isEmpty { line += " placeholder“\(p)”" }
            }
            if let popup = view as? NSPopUpButton {
                // What the closed pop-up shows (a menu's items can hold examples made when it was built, like the time
                // now: only its title is on screen).
                line += " [\((popup as? CompactPopUpButton)?.shownTitle ?? popup.titleOfSelectedItem ?? "")] \(popup.numberOfItems) items"
            } else if let button = view as? NSButton {
                line += " ‹\(button.title)› \(button.state.rawValue)\(button.isEnabled ? "" : " disabled")"
            }
            if let segments = view as? NSSegmentedControl { line += " seg\(segments.selectedSegment)" }
            if let swatch = view as? SwatchButton { line += " color \(swatch.color.map { "\($0)" } ?? "none")\(swatch.isDefault ? " default" : "")" }
            if let stepper = view as? NSStepper { line += " step \(stepper.doubleValue)" }
            if let slider = view as? NSSlider { line += " slider \(slider.doubleValue)" }
            if let image = view as? NSImageView, let i = image.image { line += " image \(i.size.width)x\(i.size.height)" }
            if let label = view.accessibilityLabel(), !label.isEmpty { line += " ax“\(label)”" }
            lines.append(line)
            guard !view.isHidden else { return }
            // A grid's cells in reading order (a cell given another view has it last among the grid's subviews).
            var children = view.subviews
            if view is NSGridView {
                children.sort { a, b in a.frame.minY != b.frame.minY ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX }
            } else if let stack = view as? NSStackView {
                // (A view put in place of another has it place among the arranged views, and is last among the subviews.)
                children = stack.arrangedSubviews + view.subviews.filter { !stack.arrangedSubviews.contains($0) }
            }
            for subview in children { visit(subview, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return lines
    }

    /// Checks the page just followed in place against the page built again (`InspectorInPlace.verifies`).
    func verifyInPlaceUpdate() {
        let inPlaceShown = inspectorPicture()
        let count = inspectorRebuildCount
        rebuildInspectorKeepingFocus(keepScroll: true)
        inspectorRebuildCount = count
        let rebuilt = inspectorPicture()
        guard inPlaceShown != rebuilt else { return }
        var what = "\(config) [\(selectedSection ?? "widget")]: "
        if let i = zip(inPlaceShown.views, rebuilt.views).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            what += "view #\(i) in place \(inPlaceShown.views[i]) · built again \(rebuilt.views[i])"
        } else if inPlaceShown.views.count != rebuilt.views.count {
            what += "\(inPlaceShown.views.count) views in place, \(rebuilt.views.count) built again"
        } else {
            what += "the pixels differ"
        }
        if let folder = ProcessInfo.processInfo.environment["DESKSET_VERIFY_IN_PLACE_DIR"] {
            let n = InspectorInPlace.mismatches.count
            let base = URL(fileURLWithPath: folder).appendingPathComponent("mismatch-\(n)")
            try? inPlaceShown.views.joined(separator: "\n").write(to: base.appendingPathExtension("in-place.txt"), atomically: true, encoding: .utf8)
            try? rebuilt.views.joined(separator: "\n").write(to: base.appendingPathExtension("rebuilt.txt"), atomically: true, encoding: .utf8)
            try? inPlaceShown.png?.write(to: base.appendingPathExtension("in-place.png"))
            try? rebuilt.png?.write(to: base.appendingPathExtension("rebuilt.png"))
        }
        InspectorInPlace.mismatches.append(what)
        FileHandle.standardError.write(Data("IN-PLACE MISMATCH \(what)\n".utf8))
    }
}

extension InspectorWindowController {
    /// Registers a card's title row (`friendlyCard`): its look badge ("Look shared with 16 bars") says where most of
    /// the card's settings come from, which a step can change (a size set on the layer itself now).
    func inPlaceCardTitle(_ titleRow: NSView, group: EditorSchema.Group, section: String, title: String, badge: Bool) -> NSView {
        guard inPlace.collecting, inPlace.page == .meter(section), badge else { return titleRow }
        let slot = InspectorSlot(claims: []) { [weak self] in
            guard let self else { return nil }
            let look = self.lookBehind(group, section: section, rows: self.rows)
            return InspectorSlot.Shown(shape: look.map { "\($0.look)\u{1F}\($0.users.joined(separator: ","))" } ?? "", value: "")
        }
        slot.part = titleRow
        slot.remakePart = { [weak self] in
            guard let self else { return nil }
            let look = self.lookBehind(group, section: section, rows: self.rows)
            return self.cardTitleRow(title, accessory: look.map { self.lookBadge(look: $0.look, users: $0.users) })
        }
        inPlace.add(slot)
        return titleRow
    }
}

extension InspectorWindowController {
    /// Registers the size of a layer that fits its content (`fitsSizeRow`): its button sets the size it has now.
    func inPlaceFitsRow(_ row: InspectorRow, meter m: Meter) -> InspectorRow {
        guard inPlace.collecting, inPlace.page == .meter(m.name) else { return row }
        let name = m.name
        let slot = InspectorSlot(claims: []) { [weak self] in
            guard let m = self?.skin?.meter(named: name) else { return nil }
            return InspectorSlot.Shown(shape: "\(EditorStyle.number(m.frame.width)) × \(EditorStyle.number(m.frame.height))", value: "")
        }
        slot.label = row.label
        slot.control = row.control
        slot.remakeRow = { [weak self] in self?.skin?.meter(named: name).flatMap { self?.fitsSizeRow($0) } }
        inPlace.add(slot)
        return row
    }
}

extension InspectorWindowController {
    /// Registers a trigger of the When Clicked card (`clickRow`): made again when its action changes, or — for "Change
    /// Color To…" — the widget's colors its menu lists.
    func inPlaceClickRow(_ row: InspectorRow, context ctx: PropertyContext, meter m: Meter, label: String, pointing: Bool) -> InspectorRow {
        guard inPlace.collecting, inPlace.page == .meter(m.name) else { return row }
        let name = m.name, p = ctx.property, key = ctx.key
        let slot = InspectorSlot(claims: [InspectorInPlace.rowID(name, key)]) { [weak self] in
            guard let self, let skin = self.skin, let m = skin.meter(named: name) else { return nil }
            let c = self.context(p, section: name, rows: self.rows)
            var value: [String] = []
            // (The row's picker shows "Change Color To…" with its menu; a color change another row cannot pick reads as
            // a sentence.)
            let pending = self.inspectorState.disclosures.contains { $0.hasPrefix("click/\(name.lowercased())/\(key.lowercased())=") }
            if !pending, pointing, case .changeColor = ClickAction.parse(c.raw) {
                // Its menu lists the widget's colors; leaving puts back the layer's color as it is now.
                value = self.widgetColors(skin).map { "\($0.title)=\($0.value)=\(skin.resolve($0.value, in: nil, sectionVariables: false))" }
                value.append(m.rawOption(Self.colorKey(forMeterType: m.type)) ?? "")
            }
            return InspectorSlot.Shown(shape: [c.key, c.raw].joined(separator: "\u{1F}"), value: value.joined(separator: "\u{1F}"))
        }
        slot.label = row.label
        slot.control = row.control
        slot.set = { [weak self, weak slot] in
            guard let self, let skin = self.skin, let m = skin.meter(named: name),
                  let popup = slot?.control?.findSubview(where: { $0.identifier?.rawValue == "\(name)/\(key)/color" }) as? CompactPopUpButton
            else { return false }
            let c = self.context(p, section: name, rows: self.rows)
            self.fillColorChoice(popup, parsed: ClickAction.parse(c.raw), section: name, key: key, meter: m, skin: skin)
            return true
        }
        slot.remakeRow = { [weak self] in
            guard let self, let m = self.skin?.meter(named: name) else { return nil }
            return self.clickRow(self.context(p, section: name, rows: self.rows), meter: m, label: label, pointing: pointing)
        }
        inPlace.add(slot)
        return row
    }
}

extension InspectorWindowController {
    /// Registers what a card's "More" shows of its settings (`friendlyCard`): which of them are in use (their dots, "· 2
    /// in use", and whether it opens by itself). When that changes the page is built again.
    func inPlaceCardGuard(_ group: EditorSchema.Group, groups: [EditorSchema.Group], section: String, more: [EditorSchema.Property],
                          extraInUse: [Bool]) {
        guard inPlace.collecting, inPlace.page == .meter(section) else { return }
        let slot = InspectorSlot(claims: []) { [weak self] in
            guard let self else { return nil }
            let inUse = more.map { self.isInUse($0, rows: self.rows, groups: groups) ? "1" : "0" }.joined()
            // The extra rows ("Up and down") say whether they are in use themselves: their dots are in their rows.
            let extra = group.title == "Text" ? self.skin?.meter(named: section).map {
                Self.alignParts($0.rawOption("StringAlign") ?? "").v != 0 ? "1" : "0" } ?? "" : extraInUse.map { $0 ? "1" : "0" }.joined()
            return InspectorSlot.Shown(shape: "\(inUse)|\(extra)", value: "")
        }
        slot.part = inspectorStack
        inPlace.add(slot)
    }
}

extension InspectorWindowController {
    /// Registers a special row that is made again whenever what it shows changes (`describe`): the Number and time
    /// Format of a text showing live data, whose choices show the value as it is now, and Shows.
    func inPlaceRemadeRow(_ row: InspectorRow, section: String, claims keys: [String], describe: @escaping () -> String?,
                          remake: @escaping () -> InspectorRow?) -> InspectorRow {
        guard inPlace.collecting, inPlace.page == .meter(section) else { return row }
        let slot = InspectorSlot(claims: keys.map { InspectorInPlace.rowID(section, $0) }) {
            describe().map { InspectorSlot.Shown(shape: $0, value: "") }
        }
        slot.label = row.label
        slot.control = row.control
        slot.remakeRow = remake
        inPlace.add(slot)
        return row
    }

    /// What the Number row shows (`numberRow`): its choices as they read now, the one chosen, the settings under it.
    func describeNumberRow(meter name: String, section: String) -> String? {
        guard let skin, let m = skin.meter(named: name), let measure = m.measures.first else { return "none" }
        var parts: [String] = [measure.name, showsDetails ? "details" : ""]
        if isTime(measure) {
            let zone = TimeFormatting.timeZone(forOption: measure.option("TimeZone"))
            let current = measure.option("Format") ?? "%H:%M:%S"
            let presets = FormatPresets.timePresets(at: Date(), timeZone: zone)
            parts += ["time", measure.rawOption("Format") ?? "", current, presets.map { "\($0.title)=\($0.format)" }.joined(separator: "|"),
                      presets.contains { $0.format == current } ? "" : TimeFormatting.format(Date(), format: current, timeZone: zone),
                      inspectorState.disclosures.contains("time-custom/\(measure.name.lowercased())") ? "custom" : ""]
        } else {
            let presets = numberPresets(for: measure, skin: skin, section: section)
            var current: [String: String] = [:]
            for key in FormatPresets.numberKeys {
                if let r = rows.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { current[key] = r.resolved }
            }
            let index = FormatPresets.index(of: current, in: presets)
            parts += ["number", presets.map(\.title).joined(separator: "|"), index.map(String.init) ?? "custom \((m as? StringMeter)?.text ?? "")",
                      current.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
                      inspectorState.disclosures.contains("number-custom/\(section.lowercased())") ? "custom" : ""]
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// What Shows shows (`showsRow`): the data item chosen and its name, or why it is none.
    func describeShowsRow(_ p: EditorSchema.Property, section: String) -> String? {
        let c = context(p, section: section, rows: rows)
        let dynamic = EditorSchema.isDynamicValue(c.raw)
        let current = (dynamic ? c.resolved : c.raw).trimmingCharacters(in: .whitespaces)
        let name = skin.flatMap { skin in skin.measure(named: current).map { dataName($0, in: skin) } } ?? "-"
        return [c.key, c.raw, current, name, dynamic ? "dynamic" : "", showsDetails ? "details" : ""].joined(separator: "\u{1F}")
    }
}
