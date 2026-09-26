import AppKit
import DesksetCore

// The inspector pages of layers (docs/editor-friendly.md §8.2–8.7, §8.9): one layer (text, bar, shape, picture, graph,
// gauge…), a group of repeated layers ("16 bars"), several layers. The shared parts (identity strip, cards with
// "More", Position and Size) are in EditorSelectionPages.swift.

extension InspectorWindowController {
    // MARK: - One layer

    /// The page of one layer: identity strip, the kind's cards, Position and Size, Box Behind It and When Clicked
    /// (when set), the outcome buttons for what is not set yet, More Layer Options.
    func meterPage(_ m: Meter, skin: Skin) {
        noteSelectionShown(m.name)
        let groups = EditorSchema.meterGroups(m.type)
        add(layerStrip(m, skin: skin))
        let type = m.type.lowercased()
        let own = groups.filter { !["Box Behind It", "When Clicked", "Layer"].contains($0.title) }
        switch type {
        case "string": textCards(m, groups: groups, skin: skin)
        case "bar": if let g = own.first { add(barCard(m, group: g, groups: groups, skin: skin)) }
        case "shape": shapeCards(m, groups: groups, skin: skin)
        case "image": if let g = own.first { add(pictureCard(m, group: g, groups: groups, skin: skin)) }
        default:
            for g in own {
                var o = CardOptions(section: m.name)
                o.custom["measurename"] = { [weak self] ctx in self?.showsRow(ctx, meter: m) }
                if type == "line" {
                    o.custom["linecolor"] = { [weak self] ctx in self?.lineRow(ctx, groups: groups) }
                }
                add(friendlyCard(g, groups: groups, rows: rows, options: o))
            }
        }
        add(positionCard(m, skin: skin))
        var outcomes: [NSView] = []
        if type == "string", (m.rawOption("MeasureName") ?? "").isEmpty {
            outcomes.append(outcomeButton("Show Live Data…", id: "outcome-data") { [weak self] control in
                self?.showLiveDataMenu(for: m.name, from: control)
            })
        }
        if let box = groups.first(where: { $0.title == "Box Behind It" }) {
            if isGroupShown(box, section: m.name) {
                add(friendlyCard(box, groups: groups, rows: rows, options: CardOptions(section: m.name)))
            } else {
                outcomes.append(outcomeButton("Add a Box Behind It…", id: "outcome-box") { [weak self] _ in
                    self?.addBoxBehind(m.name)
                })
            }
        }
        if let click = groups.first(where: { $0.title == "When Clicked" }) {
            if isGroupShown(click, section: m.name) {
                add(whenClickedCard(m, group: click, groups: groups, skin: skin))
            } else {
                outcomes.append(outcomeButton("Do Something When Clicked…", id: "outcome-click") { [weak self] _ in
                    guard let self else { return }
                    self.revealedGroups.insert("\(m.name)/When Clicked")
                    self.rebuildKeepingScroll()
                })
            }
        }
        if !outcomes.isEmpty {
            let flow = FlowView()
            flow.spacing = 6
            flow.rowSpacing = 6
            flow.identifier = NSUserInterfaceItemIdentifier("outcomes")
            for b in outcomes { flow.addSubview(b) }
            add(flow)
        }
        if let layer = groups.first(where: { $0.title == "Layer" }) {
            var o = CardOptions(section: m.name)
            o.moreOnly = true
            o.skip = ["hidden"]
            add(friendlyCard(layer, groups: groups, rows: rows, options: o))
        }
        if showsDetails { add(unshownLinesCard(section: m.name, groups: groups, meter: m)) }
    }

    /// Whether an optional card (Box Behind It, When Clicked) is shown: something in it is set, or the user asked.
    func isGroupShown(_ group: EditorSchema.Group, section: String) -> Bool {
        if revealedGroups.contains("\(section)/\(group.title)") { return true }
        let set = group.properties.contains { row(for: $0, in: rows) != nil }
            || rows.contains { EditorSchema.numberedProperty($0.key, in: [group]).map { $0.index > 1 } ?? false }
        if set { revealedGroups.insert("\(section)/\(group.title)") }
        return set
    }

    /// "+ Show Live Data…", "+ Add a Box Behind It…": an action for something not set yet.
    func outcomeButton(_ title: String, id: String, _ action: @escaping (NSControl) -> Void) -> NSButton {
        let b = NSButton(title: title, image: EditorStyle.image("plus", size: 10, weight: .semibold) ?? NSImage(), target: nil,
                         action: nil)
        b.imagePosition = .imageLeading
        b.isBordered = false
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.contentTintColor = .controlAccentColor
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.onAction(action)
        return b
    }

    /// The identity strip of one layer: breadcrumb (the widget, the group it is in), picture, name, sentence, buttons.
    func layerStrip(_ m: Meter, skin: Skin) -> NSView {
        let name = LayerNaming.layer(m, in: skin)
        var crumbs: [(title: String, action: () -> Void)] = [(widgetName(skin), { [weak self] in self?.canvasSelectionChanged([]) })]
        if let s = series(containing: m.name, in: skin) {
            let members = s.members
            crumbs.append((countedLayers(members, in: skin), { [weak self] in self?.canvasSelectionChanged(members) }))
        }
        var buttons: [NSView] = []
        if m.type.lowercased() == "string" {
            buttons.append(stripButton("Edit Text", symbol: "pencil", id: "strip-edit-text",
                                       tooltip: "Change the words") { [weak self] in self?.editTextFromStrip(m.name) })
        }
        let hidden = m.hidden
        buttons.append(stripButton(hidden ? "Show" : "Hide", symbol: hidden ? "eye" : "eye.slash", id: "strip-hide",
                                   tooltip: hidden ? "Show this layer" : "Hide this layer") { [weak self] in
            self?.setLayersHidden([m.name], hidden: !hidden)
        })
        let locked = isLayerLocked(m.name)
        buttons.append(stripButton(locked ? "Unlock" : "Lock", symbol: locked ? "lock.open" : "lock", id: "strip-lock",
                                   tooltip: locked ? "Unlock" : "Lock it so it can't be moved by accident") { [weak self] in
            self?.setLayersLocked([m.name], locked: !locked)
        })
        buttons.append(stripMenuButton { [weak self] in
            guard let self else { return NSMenu() }
            return LayerMenu.make(for: [m.name], in: self)
        })
        var lines: [NSView] = []
        if locked, backgroundLayer(in: skin)?.caseInsensitiveCompare(m.name) == .orderedSame {
            let note = cardNote("Locked, so clicking the canvas picks the layers on top of it.")
            note.identifier = NSUserInterfaceItemIdentifier("locked-note")
            lines.append(note)
        }
        if let cut = cutOffLine([m.name], in: skin) { lines.append(cut) }
        let looks = OptionValue.list(m.rawOption("MeterStyle") ?? "").filter { skin.document.section(named: $0) != nil }
        if let details = detailsLine(section: m.name, looks: looks, skin: skin) { lines.append(details) }
        let picture = stripPicture(image: layerPicture([m.name], in: skin), symbol: name.symbol)
        let strip = identityStrip(title: name.title, sentence: name.sentence, picture: picture, crumbs: crumbs, buttons: buttons,
                                  lines: lines)
        strip.setAccessibilityLabel("\(name.title), \(LayerNaming.kindNoun(m))")
        return strip
    }

    /// [Edit Text] (§7.1): plain words are edited in place on the canvas (`beginInlineTextEdit`, §9.4); words
    /// showing live data put the keyboard in the inspector's Text field (`focusInspectorTextField`).
    func editTextFromStrip(_ name: String) {
        if beginInlineTextEdit(name) { return }
        focusInspectorTextField()
    }

    // MARK: Text

    /// Whether a data item gives words rather than a number: fixed text, a device or network name, a song's title…,
    /// a time written with words (AM/PM, a weekday); for other kinds, a value that is words now.
    static func isTextData(_ m: Measure) -> Bool {
        func option(_ key: String) -> String { (m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        let type = option("Measure")
        let plugin = type == "plugin" ? MeasureRegistry.normalizedPluginName(m.rawOption("Plugin") ?? "") : type
        switch plugin {
        case "string", "webparser": return true
        case "audiolevel": return ["devicename", "deviceid", "devicelist", "devicestatus", "format"].contains(option("type"))
        case "nowplaying": return ["title", "artist", "album", "cover", "coverpath", "genre", "lyrics", "file", "duration",
                                   "position"].contains(option("playertype"))
        case "wifistatus": return ["ssid", "encryption", "auth", "phy", "list"].contains(option("wifiinfotype"))
        case "time":
            let format = option("format")
            return format.contains("%p") || format.contains("%a") || format.contains("%b") || format.contains("%h")
        default:
            let s = m.stringValue.trimmingCharacters(in: .whitespaces)
            return !s.isEmpty && Double(s) == nil
        }
    }

    func textCards(_ m: Meter, groups: [EditorSchema.Group], skin: Skin) {
        let hasData = !(m.rawOption("MeasureName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if hasData, let shows = groups.first(where: { $0.title == "Shows" }) {
            var o = CardOptions(section: m.name)
            o.custom["measurename"] = { [weak self] ctx in self?.showsRow(ctx, meter: m) }
            o.custom["numofdecimals"] = { [weak self] ctx in self?.numberRow(ctx, meter: m, skin: skin) }
            o.note = ""
            // Text data (a device's name, fixed text, AM/PM) has no number to write: known by the kind of data, and
            // only by its value for kinds that can be either — never by an empty value, which is no number either.
            if let data = m.measures.first, !isTime(data), Self.isTextData(data) {
                o.skip.formUnion(["numofdecimals", "autoscale", "scale", "percentual"])
            }
            add(friendlyCard(shows, groups: groups, rows: rows, options: o))
        }
        guard let text = groups.first(where: { $0.title == "Text" }) else { return }
        var o = CardOptions(section: m.name)
        o.custom["text"] = { [weak self] ctx in self?.textRow(ctx, meter: m, data: hasData) }
        o.custom["fontface"] = { [weak self] ctx in self?.fontRow(ctx, groups: groups) }
        o.custom["stringalign"] = { [weak self] ctx in self?.alignRow(ctx) }
        o.custom["stringeffect"] = { [weak self] ctx in self?.effectRow(ctx, groups: groups) }
        o.custom["stringcase"] = { [weak self] ctx in self?.capitalsRow(ctx) }
        if let up = upAndDownRow(m) { o.extraMore.append(up) }
        let inline = rows.filter { $0.key.lowercased().hasPrefix("inlinesetting") }.count
        if inline > 0 {
            let code = linkLike("Edit in Code ›", id: "styled-parts") { [weak self] in
                self?.showInCode(skin.sources.location(section: m.name))
            }
            let row = InspectorRow(label: EditorStyle.rowLabel("Styled parts", key: nil, tooltip: "Parts of the text with their own style"),
                                   control: EditorStyle.hstack([EditorStyle.label("\(inline)", size: 12), code, EditorStyle.spacer()], spacing: 8))
            o.extraMore.append((row, true))
        }
        add(friendlyCard(text, groups: groups, rows: rows, options: o))
    }

    /// A borderless accent button that reads like a link ("Go to Live Data ›").
    func linkLike(_ title: String, id: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 11.5, weight: .medium)
        b.contentTintColor = .controlAccentColor
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.onAction { _ in action() }
        return b
    }

    /// "Right now 48 Hz" (a text: what it shows now), "Right now 0% — no sound is playing, so the bar is empty."
    func rightNowLine(_ m: Meter, skin: Skin) -> NSView? {
        guard let measure = m.measures.first else { return nil }
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = EditorStyle.inspectorWidth - 32 - 2 * EditorStyle.cardPadding
        label.identifier = NSUserInterfaceItemIdentifier("right-now")
        let name = m.name
        label.stringValue = rightNowText(m, measure: measure)
        inspectorState.liveUpdates.append { [weak self, weak label] in
            guard let self, let label, let m = self.skin?.meter(named: name), let data = m.measures.first else { return }
            let text = self.rightNowText(m, measure: data)
            if label.stringValue != text { label.stringValue = text }
        }
        return label
    }

    func rightNowText(_ m: Meter, measure: Measure) -> String {
        if let s = m as? StringMeter {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Right now it shows nothing." : "Right now “\(text.count > 40 ? String(text.prefix(39)) + "…" : text)”"
        }
        let percent = Int((NumberFormatting.percentage(measure.value, minValue: measure.minValue, maxValue: measure.maxValue)).rounded())
        var text = "Right now \(percent)%"
        if percent == 0 {
            let sound = EditorSchema.measureType(type: measure.type, plugin: measure.rawOption("Plugin"))?.name == "AudioLevel"
            let what = m.type.lowercased() == "bar" ? "the bar is empty" : "it shows nothing yet"
            text += sound ? " — no sound is playing, so \(what)." : " — \(what)."
        }
        return text
    }

    /// Text: a field, or — for text that shows live data — the token field with the blue data tags.
    func textRow(_ ctx: PropertyContext, meter m: Meter, data: Bool) -> InspectorRow {
        let label = EditorStyle.rowLabel("Text", key: showsDetails ? ctx.key : nil, tooltip: "The words to show")
        guard data else {
            let field = textField(ctx, value: ctx.raw, placeholder: "Type the words to show")
            field.font = .systemFont(ofSize: 12.5)
            field.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/Text")
            return InspectorRow(label: label, control: field)
        }
        let names: [Int: String] = Dictionary(uniqueKeysWithValues: m.measureSlots.enumerated().compactMap { i, slot in
            guard let slot, let skin = self.skin else { return nil }
            return (i + 1, dataName(slot, in: skin))
        })
        // No words of its own: the text shows the live value itself, as its tag.
        let field = DataTokenField(text: ctx.raw.isEmpty ? "%1" : ctx.raw, names: names)
        field.identifier = NSUserInterfaceItemIdentifier("text-tokens")
        let write = writer(ctx)
        field.onCommit = { [weak self] value in
            guard let self, !self.inspectorState.isRebuilding else { return }
            write(value)
        }
        field.tokenMenu = { [weak self, weak field] n in
            guard let self, let field else { return NSMenu() }
            return self.tokenMenu(n, section: ctx.section, field: field)
        }
        let caption = cardNote("The blue tag shows the live data.")
        let stack = EditorStyle.vstack([field, caption], spacing: 4)
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return InspectorRow(label: label, control: stack)
    }

    /// The token field being edited when the inspector is rebuilt: its typed text goes on in the rebuilt field.
    struct TokenFieldFocus {
        var identifier: NSUserInterfaceItemIdentifier?
        /// The text as typed (`%N` for the tags) and the written text it started from.
        var text: String
        var original: String
        var selection: NSRange
    }

    /// The token field whose text is being edited (nil: none, or not in the inspector).
    func focusedTokenField() -> TokenFieldFocus? {
        guard let textView = window?.firstResponder as? NSTextView, !textView.isFieldEditor,
              let field = textView.superview as? DataTokenField, field.isDescendant(of: inspectorStack) else { return nil }
        return TokenFieldFocus(identifier: field.identifier, text: field.stringValue, original: field.original,
                               selection: textView.selectedRange())
    }

    /// After a rebuild: the same token field takes the focus back, with the text typed and not written yet — when it
    /// still starts from the same written text (otherwise the file changed under it, and what it says now wins).
    func restoreTokenFieldFocus(_ focus: TokenFieldFocus) {
        guard let window, window.firstResponder == nil || window.firstResponder === window,
              let field = inspectorStack.findSubview(where: { $0 is DataTokenField && $0.identifier == focus.identifier }) as? DataTokenField,
              window.makeFirstResponder(field.textView) else { return }
        if focus.text != focus.original, field.original == focus.original { field.load(focus.text) }
        let length = field.textView.textStorage?.length ?? 0
        if field.stringValue == focus.text, focus.selection.location <= length {
            field.textView.setSelectedRange(NSRange(location: focus.selection.location,
                                                    length: min(focus.selection.length, length - focus.selection.location)))
        }
    }

    /// A data tag's menu: Change Live Data ▸ · Number ▸ · Remove.
    func tokenMenu(_ n: Int, section: String, field: DataTokenField) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let key = n == 1 ? "MeasureName" : "MeasureName\(n)"
        let change = NSMenuItem(title: "Change Live Data", action: nil, keyEquivalent: "")
        change.submenu = showsMenu(current: skin?.section(named: section)?.rawOption(key), popup: false) { [weak self] name in
            guard let self else { return }
            self.writeProperty(section: section, key: key, value: name, variable: nil, label: "Shows")
        } create: { [weak self] choice in
            self?.createLiveData(choice, for: section, key: key)
        }
        menu.addItem(change)
        if let skin, let m = skin.meter(named: section), let measure = m.measures.first {
            let number = NSMenuItem(title: "Number", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for preset in numberPresets(for: measure, skin: skin, section: section) {
                sub.addItem(ClosureMenuItem(preset.title) { [weak self] in self?.writeNumberPreset(preset, section: section) })
            }
            number.submenu = sub
            menu.addItem(number)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove", symbol: "xmark") { field.removeToken(n) })
        return menu
    }

    /// Font: the face (each in itself), then Weight and the Italic button.
    func fontRow(_ ctx: PropertyContext, groups: [EditorSchema.Group]) -> InspectorRow {
        let face = fontPopup(key: ctx.key, section: ctx.section, raw: ctx.raw, current: ctx.isSet ? ctx.resolved : "",
                             variable: ctx.variable)
        face.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var parts: [NSView] = []
        if let weight = EditorSchema.property("FontWeight", in: groups) {
            let wctx = context(weight, section: ctx.section, rows: rows)
            if wctx.form == .formula {
                parts.append(LinkedValueTag(ctx: wctx, controller: self))
            } else {
                let popup = choiceControl(wctx, choices: EditorSchema.fontWeights, style: .popup, write: writer(wctx))
                popup.toolTip = "Weight"
                parts.append(popup)
            }
        }
        if let style = EditorSchema.property("StringStyle", in: groups) {
            let sctx = context(style, section: ctx.section, rows: rows)
            let current = (sctx.isSet ? sctx.resolved : "Normal").lowercased()
            let italic = NSButton(image: EditorStyle.image("italic", size: 12, weight: .medium) ?? NSImage(), target: nil, action: nil)
            italic.setButtonType(.pushOnPushOff)
            italic.bezelStyle = .rounded
            italic.controlSize = .small
            italic.state = current.contains("italic") ? .on : .off
            italic.identifier = NSUserInterfaceItemIdentifier("StringStyle")
            italic.toolTip = "Italic"
            italic.setAccessibilityLabel("Italic")
            let write = writer(sctx)
            italic.onAction { b in
                let on = (b as? NSButton)?.state == .on
                let bold = current.hasPrefix("bold")
                write(on ? (bold ? "BoldItalic" : "Italic") : (bold ? "Bold" : "Normal"))
            }
            parts.append(italic)
        }
        let second = EditorStyle.hstack(parts, spacing: 6)
        var views: [NSView] = [face]
        if ctx.variable != nil {
            // A shared font: its tag says so (and changes it everywhere).
            let flow = FlowView()
            flow.identifier = NSUserInterfaceItemIdentifier("captions")
            flow.addSubview(LinkedValueTag(ctx: ctx, controller: self, asControl: false))
            views.append(flow)
        }
        views.append(second)
        let stack = EditorStyle.vstack(views, spacing: 6)
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let label = EditorStyle.rowLabel("Font", key: showsDetails ? ctx.key : nil, tooltip: "The font, its weight, italic")
        return InspectorRow(label: label, control: stack)
    }

    /// A segmented control of worded choices (symbols when the words do not fit).
    func wordedSegments(_ titles: [String], symbols: [String?], selected: Int, id: String,
                        _ action: @escaping (Int) -> Void) -> NSSegmentedControl {
        let seg = ChoiceSegmentedControl()
        seg.segmentCount = titles.count
        seg.trackingMode = .selectOne
        seg.controlSize = .small
        seg.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        seg.values = titles
        let choices = zip(titles, symbols).map { EditorSchema.Choice($0.0, $0.0, symbol: $0.1) }
        let labels = segmentLabels(choices) ?? choices.map { (title: $0.title, symbol: $0.symbol) }
        for (i, l) in labels.enumerated() {
            if let symbol = l.symbol, let image = EditorStyle.image(symbol, size: 12) {
                seg.setImage(image, forSegment: i)
                seg.setWidth(30, forSegment: i)
            } else {
                seg.setLabel(l.title, forSegment: i)
            }
            seg.setToolTip(titles[i], forSegment: i)
        }
        seg.selectedSegment = selected
        seg.identifier = NSUserInterfaceItemIdentifier(id)
        seg.onAction { c in
            guard let s = c as? NSSegmentedControl, s.selectedSegment >= 0 else { return }
            action(s.selectedSegment)
        }
        return seg
    }

    /// Align: Left | Center | Right (the horizontal part of StringAlign; Up and down is in More).
    func alignRow(_ ctx: PropertyContext) -> InspectorRow? {
        guard ctx.form == .literal, ctx.variable == nil else { return nil }
        let value = ctx.isSet ? ctx.raw : ctx.property.defaultValue
        guard ctx.isSet == false || EditorSchema.issue(for: value, property: ctx.property) == nil else {
            return propertyRow(ctx.property, section: ctx.section, row: ctx.row, groups: [], friendly: true)
        }
        let (h, v) = Self.alignParts(value)
        let write = writer(ctx)
        let seg = wordedSegments(["Left", "Center", "Right"], symbols: ["text.alignleft", "text.aligncenter", "text.alignright"],
                                 selected: h, id: "StringAlign") { i in write(Self.alignValue(h: i, v: v)) }
        seg.setAccessibilityLabel("Align")
        return InspectorRow(label: EditorStyle.rowLabel("Align", key: showsDetails ? ctx.key : nil,
                                                        tooltip: "Where X and Y are on the text: left, center or right"),
                            control: seg)
    }

    /// Up and down (More Text Options): Top | Middle | Bottom, the vertical part of StringAlign.
    func upAndDownRow(_ m: Meter) -> (row: InspectorRow, inUse: Bool)? {
        guard let p = EditorSchema.property("StringAlign", in: EditorSchema.meterGroups("String")) else { return nil }
        let ctx = context(p, section: m.name, rows: rows)
        guard ctx.form == .literal, ctx.variable == nil else { return nil }
        let value = ctx.isSet ? ctx.raw : p.defaultValue
        let (h, v) = Self.alignParts(value)
        let write = writer(ctx)
        let seg = wordedSegments(["Top", "Middle", "Bottom"], symbols: ["arrow.up.to.line", "arrow.up.and.down", "arrow.down.to.line"],
                                 selected: v, id: "StringAlign.vertical") { i in write(Self.alignValue(h: h, v: i)) }
        let label = EditorStyle.rowLabel("Up and down", key: nil, tooltip: "Where Y is on the text: top, middle or bottom")
        return (InspectorRow(label: v != 0 ? dotted(label) : label, control: seg), v != 0)
    }

    /// Capitals, each choice written in its own case.
    func capitalsRow(_ ctx: PropertyContext) -> InspectorRow? {
        guard ctx.form == .literal, ctx.variable == nil,
              case .choice(let choices, _) = ctx.property.kind else { return nil }
        let inUse = isInUse(ctx.property, rows: rows, groups: EditorSchema.meterGroups("String"))
        let control = choiceControl(ctx, choices: choices, style: .popup, write: writer(ctx))
        var lines: [NSView] = [control]
        if let row = ctx.row, let issue = propertyIssue(ctx.property, row: row, section: ctx.section) {
            lines.append(EditorStyle.issue(issue, width: inspectorControlWidth))
        }
        let label = EditorStyle.rowLabel("Capitals", key: showsDetails ? ctx.key : nil, tooltip: "Capital letters")
        let cell = lines.count == 1 ? control : EditorStyle.vstack(lines, spacing: 4)
        return InspectorRow(label: inUse ? dotted(label) : label, control: cell)
    }

    /// Effect: None | Shadow | Outline, and its color when there is one.
    func effectRow(_ ctx: PropertyContext, groups: [EditorSchema.Group]) -> InspectorRow {
        var row = propertyRow(ctx.property, section: ctx.section, row: ctx.row, groups: groups, friendly: true)
        guard let color = EditorSchema.property("FontEffectColor", in: groups),
              EditorSchema.isVisible(color, in: groups, values: valueLookup(rows)) else { return row }
        let cctx = context(color, section: ctx.section, rows: rows)
        let swatch = ColorControl(ctx: cctx, controller: self)
        let stack = EditorStyle.vstack([row.control, swatch], spacing: 6)
        row.control.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        swatch.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        row.control = stack
        return row
    }

    /// Line [■] [1] px: a graph's line color and thickness.
    func lineRow(_ ctx: PropertyContext, groups: [EditorSchema.Group]) -> InspectorRow? {
        guard let width = EditorSchema.property("LineWidth", in: groups) else { return nil }
        let color = ColorControl(ctx: ctx, controller: self)
        let wrow = propertyRow(width, section: ctx.section, row: row(for: width, in: rows), groups: groups, friendly: true)
        let stack = EditorStyle.vstack([color, wrow.control], spacing: 6)
        return InspectorRow(label: EditorStyle.rowLabel("Line", key: showsDetails ? ctx.key : nil, tooltip: "The line's color and thickness"),
                            control: stack)
    }

    /// A label with the small dot of a setting in use (in "More" sections).
    func dotted(_ label: NSView) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
        dot.identifier = NSUserInterfaceItemIdentifier("in-use-dot")
        dot.setAccessibilityLabel("In use")
        let row = EditorStyle.hstack([dot, label], spacing: 4)
        row.toolTip = label.toolTip
        return row
    }

    // MARK: Shows and Number

    /// Shows [live data ▾], "Go to Live Data ›".
    func showsRow(_ ctx: PropertyContext, meter m: Meter, rightNow: Bool = true) -> InspectorRow {
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier(ctx.property.key)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A name built from a shared value (MeasureTime#ClockHours#): the data it names now.
        let dynamic = EditorSchema.isDynamicValue(ctx.raw)
        let current = (dynamic ? ctx.resolved : ctx.raw).trimmingCharacters(in: .whitespaces)
        let section = ctx.section, key = ctx.key
        // Picking live data is named for what it now shows (§8.3, §10: "Show CPU Usage", "Bar 6 now shows CPU usage").
        func showing(_ name: String, by editor: InspectorWindowController) {
            guard let skin = editor.skin else { return }
            let data = skin.measure(named: name).map { editor.dataName($0, in: skin) } ?? name
            editor.writeProperty(section: section, key: key, value: name, variable: nil, label: "Shows",
                                 undoName: "Show " + Self.titleCase(data),
                                 message: "\(editor.displayName(ofSection: section)) now shows \(Self.lowerFirst(data))")
        }
        popup.menu = showsMenu(current: current, popup: true) { [weak self] name in
            if let self { showing(name, by: self) }
        } create: { [weak self] choice in
            self?.createLiveData(choice, for: section, key: key)
        }
        if let item = popup.menu?.items.first(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(current) == .orderedSame }) {
            popup.select(item)
        }
        popup.closedTitleShowsImage = false
        popup.closedTitle = { [weak self] item in
            guard let self, let skin = self.skin, let name = item.representedObject as? String else { return nil }
            if name.isEmpty { return NSAttributedString(string: "Nothing") }
            return skin.measure(named: name).map { NSAttributedString(string: self.dataName($0, in: skin)) }
        }
        let write = writer(ctx)
        popup.onAction { [weak self] c in
            guard let self, let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            if v.isEmpty { write(v) } else { showing(v, by: self) }
        }
        // The whole name first (a long one is cut in the pop-up: "Lowest band frequ…").
        popup.toolTip = showsDetails ? "MeasureName=\(ctx.raw)" : popup.shownTitle + "\n"
            + (dynamic ? "Chosen by a shared value: picking one here replaces that" : "The live data it shows")
        var views: [NSView] = [popup]
        if let skin, !current.isEmpty, let measure = skin.measure(named: current) {
            views.append(linkLike("Go to Live Data ›", id: "go-to-data") { [weak self] in self?.select(section: measure.name) })
        } else if !current.isEmpty, skin?.measure(named: current) == nil {
            views.append(EditorStyle.issue("“\(current)” isn't live data this widget has", width: inspectorControlWidth))
        }
        if rightNow, let skin, let line = rightNowLine(m, skin: skin) {
            (line as? NSTextField)?.preferredMaxLayoutWidth = inspectorControlWidth
            views.append(line)
        }
        let stack = EditorStyle.vstack(views, spacing: 3)
        popup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let label = EditorStyle.rowLabel(ctx.property.label, key: showsDetails ? ctx.key : nil, tooltip: "The live data it shows")
        return InspectorRow(label: label, control: stack)
    }

    /// The Shows menu (docs/editor-friendly.md §8.3): IN THIS WIDGET (repeated data folded: "Sound bands ▸"), then
    /// NEW ▸ the live data catalogue (created and used in one step). `popup`: its items are a pop-up's (their
    /// represented object is the section); the folded and new ones act themselves.
    func showsMenu(current: String?, popup: Bool, choose: @escaping (String) -> Void,
                   create: @escaping (EditorSchema.LiveDataChoice) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let skin else { return menu }
        let currentName = (current ?? "").trimmingCharacters(in: .whitespaces)
        func valueText(_ m: Measure) -> String { formattedValue(m, skin: skin) }
        func item(_ m: Measure, indent: Bool = false) -> NSMenuItem {
            let title = dataName(m, in: skin)
            let item: NSMenuItem
            if popup && !indent {
                item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            } else {
                let name = m.name
                item = ClosureMenuItem(title) { choose(name) }
            }
            item.attributedTitle = menuTitle(title, value: valueText(m))
            item.representedObject = m.name
            item.image = EditorStyle.image(EditorStyle.describe(m).symbol, size: 12)
            item.toolTip = showsDetails ? m.name : nil
            if m.name.caseInsensitiveCompare(currentName) == .orderedSame { item.state = .on }
            return item
        }
        if popup {
            let none = NSMenuItem(title: "Nothing", action: nil, keyEquivalent: "")
            none.representedObject = ""
            menu.addItem(none)
        }
        menu.addItem(sectionHeader("In This Widget"))
        let series = LayerSeries.detect(in: skin).filter { $0.kind == .data } + fallbackDataSeries(in: skin)
        var shown: Set<String> = []
        // The current one first when it is folded into a run.
        if let m = skin.measure(named: currentName), series.contains(where: { $0.contains(m.name) }) {
            menu.addItem(item(m))
            shown.insert(m.name.lowercased())
        }
        var folded: Set<String> = []
        for m in skin.measures where !shown.contains(m.name.lowercased()) {
            if let s = series.first(where: { $0.contains(m.name) }) {
                guard !folded.contains(s.members[0].lowercased()) else { continue }
                folded.insert(s.members[0].lowercased())
                let members = s.members.compactMap { skin.measure(named: $0) }
                let title = seriesTitle(members.map { dataName($0, in: skin) })
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.image = EditorStyle.image(EditorStyle.describe(m).symbol, size: 12)
                let sub = NSMenu()
                sub.autoenablesItems = false
                for member in members { sub.addItem(item(member, indent: true)) }
                parent.submenu = sub
                menu.addItem(parent)
                continue
            }
            menu.addItem(item(m))
        }
        if !currentName.isEmpty, skin.measure(named: currentName) == nil, popup {
            let missing = NSMenuItem(title: "“\(currentName)” (missing)", action: nil, keyEquivalent: "")
            missing.representedObject = currentName
            missing.isEnabled = false
            menu.insertItem(missing, at: 0)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        new.image = EditorStyle.image("plus.circle", size: 12)
        new.identifier = NSUserInterfaceItemIdentifier("new-live-data")
        new.submenu = liveDataCatalogueMenu(create)
        menu.addItem(new)
        return menu
    }

    /// "Sound bands" for "Sound band 1" … "Sound band 16".
    func seriesTitle(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        let stem = first.replacingOccurrences(of: #"\s*\d+$"#, with: "", options: .regularExpression)
        return stem.isEmpty ? first : Self.pluralKind(stem, count: names.count).prefix(1).uppercased()
            + Self.pluralKind(stem, count: names.count).dropFirst()
    }

    /// A menu title with the value on the right in grey.
    func menuTitle(_ title: String, value: String, detail: String? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 13), .paragraphStyle: style])
        if !value.isEmpty {
            s.append(NSAttributedString(string: "\t" + (value.count > 18 ? String(value.prefix(17)) + "…" : value),
                                        attributes: [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                                                     .paragraphStyle: style]))
        }
        if let detail {
            s.append(NSAttributedString(string: "\n" + detail, attributes: [.font: NSFont.menuFont(ofSize: 11),
                                                                            .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return s
    }

    func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let header = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        return header
    }

    /// The live data catalogue (docs/editor-friendly.md §5.3) as a menu: the same two-line items, Extras at the end,
    /// as the sidebar's "+ Add Live Data" (`dataSourceMenuItems`).
    func liveDataCatalogueMenu(_ create: @escaping (EditorSchema.LiveDataChoice) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in Self.dataSourceMenuItems(expert: showsDetails, { choice in create(choice.schemaChoice) }) { menu.addItem(item) }
        return menu
    }

    /// Opens the Shows menu from "+ Show Live Data…": the text becomes "{its words} %1" and shows the choice.
    func showLiveDataMenu(for section: String, from control: NSControl) {
        let menu = showsMenu(current: nil, popup: false) { [weak self] name in
            self?.showLiveData(name, in: section)
        } create: { [weak self] choice in
            self?.createLiveData(choice, for: section, key: "MeasureName", addToText: true)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: control.bounds.height + 3), in: control)
    }

    /// A literal text starts showing `measure`: MeasureName written, "%1" added to its words, one undo step.
    func showLiveData(_ measure: String, in section: String) {
        guard let skin else { return }
        let data = skin.measure(named: measure).map { dataName($0, in: skin) } ?? measure
        let text = skin.section(named: section)?.rawOption("Text") ?? ""
        let own = skin.ownTarget(section: section, key: "MeasureName")
        let textTarget = skin.ownTarget(section: section, key: "Text")
        writeKeysPlainly([KeyWrite(file: own.file, section: own.section, key: "MeasureName", value: measure),
                   KeyWrite(file: textTarget.file, section: textTarget.section, key: "Text",
                            value: text.trimmingCharacters(in: .whitespaces).isEmpty ? "%1" : text + " %1")],
                  name: "Show " + Self.titleCase(data), message: "\(displayName(ofSection: section)) now shows \(Self.lowerFirst(data))")
    }

    /// "New ▸ CPU usage": the live data is created (after the widget's other live data) and shown by `section`'s
    /// `key`, as one undo step "Show CPU Usage".
    func createLiveData(_ choice: EditorSchema.LiveDataChoice, for section: String, key: String, addToText: Bool = false) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.createLiveData(choice, for: section, key: key, addToText: addToText) }) {
            return
        }
        guard let skin, let type = choice.measureType else { return }
        var new = EditorComponents.measureSection(type, existing: skin.sectionNames)
        for (k, v) in choice.orderedOptions {
            if let i = new.options.firstIndex(where: { $0.key.caseInsensitiveCompare(k) == .orderedSame }) {
                new.options[i].value = v
            } else {
                new.options.append((key: k, value: v))
            }
        }
        let next = Self.dataSourceInsertionPoint(in: skin)
        let target = ScopeResolver(skin: skin).target(section: section, key: key, selection: [section])
        let textTarget = skin.ownTarget(section: section, key: "Text")
        let oldText = skin.section(named: section)?.rawOption("Text") ?? ""
        var files = [skin.fileURL, target.file]
        if addToText { files.append(textTarget.file) }
        let who = displayName(ofSection: section)
        perform("Show " + Self.titleCase(choice.title), files: files,
                message: { _ in "\(who) now shows \(Self.lowerFirst(choice.title))" }) {
            try skin.appendSections([new])
            if let next { _ = try skin.moveSection(new.name, before: next) }
            try IniWriter.writeValue(new.name, key: key, section: target.section, fileURL: target.file)
            if addToText {
                try IniWriter.writeValue(oldText.trimmingCharacters(in: .whitespaces).isEmpty ? "%1" : oldText + " %1",
                                         key: "Text", section: textTarget.section, fileURL: textTarget.file)
            }
        }
    }

    /// The live value of data in plain units: "48 Hz", "3.2 GB", "0%", "MacBook Pro扬声器".
    func formattedValue(_ m: Measure, skin: Skin) -> String {
        let s = m.stringValue.trimmingCharacters(in: .whitespaces)
        // A file (an album cover): what it is, never the path (the Live Data list says it the same way).
        if s.hasPrefix("/") || s.lowercased().hasPrefix("file:") { return liveValueText(m, in: skin) }
        if !s.isEmpty, Double(s) == nil { return s }
        let type = EditorSchema.measureType(type: m.type, plugin: m.rawOption("Plugin"))?.name ?? ""
        if type == "AudioLevel" {
            let kind = (m.rawOption("Type") ?? "RMS").lowercased()
            if kind.hasSuffix("freq") {
                return m.value >= 1000 ? NumberFormatting.fixed(m.value / 1000, decimals: 1) + " kHz"
                    : NumberFormatting.fixed(m.value, decimals: 0) + " Hz"
            }
        }
        switch FormatPresets.unit(forMeasureType: m.type, plugin: m.rawOption("Plugin")) {
        case .bytes:
            // Memory in 1024s, as the Mac counts it (a 24 GB Mac has 24.0 GB); disks in 1000s, as the Finder does.
            let memory = ["Memory", "PhysicalMemory", "SwapMemory"].contains(type)
            let scale: AutoScale = memory ? .binary(minimumPower: 0) : .decimal(minimumPower: 0)
            return NumberFormatting.format(m.value, minValue: 0, maxValue: 1, options: NumberFormatOptions(autoScale: scale, numOfDecimals: 1)).trimmingCharacters(in: .whitespaces) + "B"
        case .bytesPerSecond: return NumberFormatting.format(m.value, minValue: 0, maxValue: 1, options: NumberFormatOptions(autoScale: .decimal(minimumPower: 0), numOfDecimals: 1)).trimmingCharacters(in: .whitespaces) + "B/s"
        case .plain: break
        }
        if m.minValue == 0, m.maxValue == 1 || m.maxValue == 100, type != "Calc" {
            let p = NumberFormatting.percentage(m.value, minValue: m.minValue, maxValue: m.maxValue)
            return "\(Int(p.rounded()))%"
        }
        return EditorStyle.compact(m.value)
    }

    /// The Number choices for a text showing `measure`, rendered from its live value in the base the text shortens
    /// numbers in now (`section`'s AutoScale: 1024s for System's memory), so the current format is one of them.
    func numberPresets(for measure: Measure, skin: Skin, section: String) -> [FormatPresets.NumberPreset] {
        let unit = FormatPresets.unit(forMeasureType: measure.type, plugin: measure.rawOption("Plugin"))
        let range: (min: Double, max: Double)? = measure.maxValue > measure.minValue ? (measure.minValue, measure.maxValue) : nil
        let base = FormatPresets.base(ofAutoScale: skin.section(named: section)?.option("AutoScale"))
        return FormatPresets.numberPresets(for: measure.value, unit: unit, range: range, base: base)
    }

    /// Number [48 ▾]: the live value rendered with each choice (hidden for text data); a time shows its Format.
    /// Whether live data is a time (its text is written with a Format).
    func isTime(_ m: Measure) -> Bool {
        EditorSchema.measureType(type: m.type, plugin: m.rawOption("Plugin"))?.name == "Time"
    }

    func numberRow(_ ctx: PropertyContext, meter m: Meter, skin: Skin) -> InspectorRow? {
        guard let measure = m.measures.first else { return nil }
        if isTime(measure) { return timeFormatRow(measure, skin: skin) }
        let presets = numberPresets(for: measure, skin: skin, section: ctx.section)
        var current: [String: String] = [:]
        for key in FormatPresets.numberKeys {
            if let r = rows.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { current[key] = r.resolved }
        }
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("number-format")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let index = FormatPresets.index(of: current, in: presets)
        if index == nil {
            // A format none of the choices writes: shown as it reads now, as a normal choice (choosing it keeps it).
            let rendered = (m as? StringMeter)?.text ?? ""
            let custom = NSMenuItem(title: "Custom — \(rendered)", action: nil, keyEquivalent: "")
            custom.tag = -1
            custom.identifier = NSUserInterfaceItemIdentifier("number-format-custom")
            menu.addItem(custom)
            menu.addItem(.separator())
        }
        for (i, preset) in presets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: nil, keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let section = ctx.section
        menu.addItem(ClosureMenuItem("Custom…") { [weak self] in
            self?.inspectorState.disclosures.insert("number-custom/\(section.lowercased())")
            self?.rebuildKeepingScroll()
        })
        popup.menu = menu
        // (The pop-up gives its items an action of its own: the choices are told apart by tag and kind.)
        if let index, let item = menu.items.first(where: { $0.tag == index && !$0.isSeparatorItem && !($0 is ClosureMenuItem) }) {
            popup.select(item)
        } else {
            popup.selectItem(at: 0)
        }
        popup.onAction { [weak self] c in
            guard let item = (c as? NSPopUpButton)?.selectedItem, item.isEnabled, item.tag >= 0, item.tag < presets.count,
                  !item.isSeparatorItem, !(item is ClosureMenuItem) else { return }
            self?.writeNumberPreset(presets[item.tag], section: section)
        }
        var views: [NSView] = [popup]
        if inspectorState.disclosures.contains("number-custom/\(section.lowercased())") || showsDetails {
            // The four options as they are: decimals, scale units, divide by, percent.
            let groups = EditorSchema.meterGroups("String")
            let items: [InspectorRow] = ["NumOfDecimals", "AutoScale", "Scale", "Percentual"].compactMap { key in
                guard let p = EditorSchema.property(key, in: groups),
                      EditorSchema.isVisible(p, in: groups, values: valueLookup(rows)) else { return nil }
                var q = p
                if key == "NumOfDecimals" { q.label = "Decimals" }
                return propertyRow(q, section: section, row: row(for: q, in: rows), groups: groups, friendly: true)
            }
            // Each label above its control, the column's whole width for both (a grid inside the control column left
            // "Show / as a" cut off and the Decimals stepper past the card's edge).
            for item in items {
                if let label = item.label as? NSTextField { label.alignment = .left }
                if let label = item.label as? NSStackView {
                    label.alignment = .leading
                    for case let text as NSTextField in label.arrangedSubviews { text.alignment = .left }
                }
                let pair = EditorStyle.vstack([item.label, item.control].compactMap { $0 }, spacing: 2)
                item.control.widthAnchor.constraint(lessThanOrEqualTo: pair.widthAnchor).isActive = true
                views.append(pair)
            }
        }
        let stack = EditorStyle.vstack(views, spacing: 6)
        popup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for v in views.dropFirst() { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return InspectorRow(label: EditorStyle.rowLabel("Number", key: showsDetails ? "NumOfDecimals" : nil,
                                                        tooltip: "How the number is written"), control: stack)
    }

    /// Writes a Number choice: its options set or removed on the layer, one undo step.
    func writeNumberPreset(_ preset: FormatPresets.NumberPreset, section: String) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.writeNumberPreset(preset, section: section) }) { return }
        guard let skin else { return }
        var writes: [KeyWrite] = []
        let defaults = ["NumOfDecimals": "0", "AutoScale": "0", "Scale": "1", "Percentual": "0"]
        for key in FormatPresets.numberKeys {
            let target = skin.ownTarget(section: section, key: key)
            let current = skin.section(named: section)?.rawOption(key)
            if let value = preset.options[key] ?? nil {
                if current != value { writes.append(KeyWrite(file: target.file, section: target.section, key: key, value: value)) }
            } else if let file = skin.ownDefinitionFile(section: section, key: key) {
                writes.append(KeyWrite(file: file, section: target.section, key: key, value: nil))
            } else if current != nil, current != defaults[key] {
                // A look sets it: the layer writes the default over it.
                writes.append(KeyWrite(file: target.file, section: target.section, key: key, value: defaults[key]))
            }
        }
        writeKeysPlainly(writes, name: "Change Number of \(displayName(ofSection: section))", message: "Numbers now read \(preset.title)")
    }

    /// Format [14:05 ▾] for a text showing a time: the examples of §8.2, written to the time's Format.
    func timeFormatRow(_ measure: Measure, skin: Skin) -> InspectorRow {
        let zone = TimeFormatting.timeZone(forOption: measure.option("TimeZone"))
        let presets = FormatPresets.timePresets(at: Date(), timeZone: zone)
        // A format written as a shared value (#DateFormat#): its value, and choosing one changes the shared value.
        let raw = measure.rawOption("Format") ?? ""
        let shared = wholeVariable(raw)
        let current = measure.option("Format") ?? "%H:%M:%S"
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("time-format")
        let menu = NSMenu()
        if !presets.contains(where: { $0.format == current }) {
            let item = NSMenuItem(title: "Custom — \(TimeFormatting.format(Date(), format: current, timeZone: zone))",
                                  action: nil, keyEquivalent: "")
            item.representedObject = current
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for p in presets {
            let item = NSMenuItem(title: p.title, action: nil, keyEquivalent: "")
            item.representedObject = p.format
            menu.addItem(item)
        }
        let name = measure.name
        let customKey = "time-custom/\(name.lowercased())"
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Custom…") { [weak self] in
            self?.inspectorState.disclosures.insert(customKey)
            self?.rebuildKeepingScroll()
        })
        popup.menu = menu
        if let item = menu.items.first(where: { ($0.representedObject as? String) == current }) { popup.select(item) }
        popup.onAction { [weak self] c in
            guard let f = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, f != current else { return }
            self?.writeProperty(section: name, key: "Format", value: f, variable: shared, label: "Format")
        }
        popup.toolTip = shared.map { _ in "A shared format: choosing one changes it wherever it is used" }
        var views: [NSView] = [popup]
        if inspectorState.disclosures.contains(customKey) || showsDetails,
           let p = EditorSchema.property("Format", in: EditorSchema.measureGroups("Time")) {
            // The format as written, with its live preview (strftime codes: %H hours, %M minutes…).
            let ctx = context(p, section: name, rows: rows(of: name, kind: .measure))
            var lines: [NSView] = []
            views.append(kindControl(ctx, lines: &lines))
        }
        let stack = EditorStyle.vstack(views, spacing: 4)
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return InspectorRow(label: EditorStyle.rowLabel("Format", key: showsDetails && name == selectedSection ? "Format" : nil,
                                                        tooltip: "How the time is written"), control: stack)
    }

    // MARK: Bar

    /// BAR: Shows, "Right now", Fill, Empty part, Fills toward; More Bar Options.
    func barCard(_ m: Meter, group: EditorSchema.Group, groups: [EditorSchema.Group], skin: Skin) -> NSView {
        var o = CardOptions(section: m.name)
        o.custom["measurename"] = { [weak self] ctx in self?.showsRow(ctx, meter: m) }
        o.custom["barorientation"] = { [weak self] ctx in self?.fillsTowardRow(ctx, sections: [m.name]) }
        return friendlyCard(group, groups: groups, rows: rows, options: o)
    }

    /// Fills toward ↑ → ↓ ←: BarOrientation and Flip as one control, written together (one undo step).
    func fillsTowardRow(_ ctx: PropertyContext, sections: [String]) -> InspectorRow? {
        guard ctx.form == .literal, ctx.variable == nil, let skin else { return nil }
        let orientation = (ctx.isSet ? ctx.resolved : "Vertical").trimmingCharacters(in: .whitespaces).lowercased()
        let horizontal = orientation == "horizontal"
        let flip = OptionValue.bool(skin.section(named: ctx.section)?.option("Flip") ?? "0") ?? false
        let selected = horizontal ? (flip ? 3 : 1) : (flip ? 2 : 0)
        // An invalid direction stays as written (the usual pop-up shows it, with a warning).
        if ctx.isSet, EditorSchema.issue(for: ctx.raw, property: ctx.property) != nil { return nil }
        let seg = wordedSegments(["Up", "Right", "Down", "Left"], symbols: ["arrow.up", "arrow.right", "arrow.down", "arrow.left"],
                                 selected: selected, id: "BarOrientation") { [weak self] i in
            self?.writeFillsToward(i, sections: sections)
        }
        seg.setAccessibilityLabel("Fills toward")
        return InspectorRow(label: EditorStyle.rowLabel("Fills toward", key: showsDetails ? "BarOrientation" : nil,
                                                        tooltip: "The direction the bar fills as the value grows"), control: seg)
    }

    /// Writes "Fills toward" (0 up, 1 right, 2 down, 3 left) for the layers, where each is written (`ScopeResolver`).
    func writeFillsToward(_ index: Int, sections: [String]) {
        guard let skin else { return }
        let orientation = index == 1 || index == 3 ? "Horizontal" : "Vertical"
        let flip = index >= 2 ? "1" : "0"
        var writes: [KeyWrite] = []
        var shared: [String] = []
        func add(_ key: String, _ value: String) {
            let changing = sections.filter { s in
                let current = skin.section(named: s)?.option(key)
                if key == "Flip", (current ?? "0") == value || (OptionValue.bool(current ?? "0") ?? false) == (value == "1") { return false }
                if key == "BarOrientation", (current ?? "Vertical").caseInsensitiveCompare(value) == .orderedSame { return false }
                return true
            }
            let found = scopedWrites(key, value: value, sections: changing)
            for w in found.writes where !writes.contains(w) { writes.append(w) }
            for s in found.shared where !shared.contains(s) { shared.append(s) }
        }
        add("BarOrientation", orientation)
        add("Flip", flip)
        let what = sections.count == 1 ? displayName(ofSection: sections[0]) : Self.titleCase(countedLayers(sections, in: skin))
        writeKeysPlainly(writes, name: "Change Fills Toward of \(what)", message: "Fills toward changed" + sharedNote(shared))
    }

    // MARK: Picture

    func pictureCard(_ m: Meter, group: EditorSchema.Group, groups: [EditorSchema.Group], skin: Skin) -> NSView {
        var o = CardOptions(section: m.name)
        let file = (m.rawOption("ImageName") ?? "").trimmingCharacters(in: .whitespaces)
        let fromData = !(m.rawOption("MeasureName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        // A picture's Color is its box: shown here only for a color block (or when it is set).
        if !file.isEmpty || fromData, row(for: EditorSchema.Property("SolidColor", "", .color), in: rows) == nil {
            o.skip.insert("solidcolor")
        }
        o.title = file.isEmpty && !fromData ? "Color Block" : "Picture"
        guard fromData else { return friendlyCard(group, groups: groups, rows: rows, options: o) }
        // A picture live data chooses (an album cover): where it comes from is its first row, "Picture from [Album
        // cover ▾]", not a setting buried in More.
        var g = group
        if let i = g.properties.firstIndex(where: { $0.key == "MeasureName" }) {
            let shows = g.properties.remove(at: i).with(level: .essential).labelled("Picture from")
            g.properties.insert(shows, at: 0)
        }
        o.custom["measurename"] = { [weak self] ctx in self?.showsRow(ctx, meter: m) }
        if file.isEmpty { o.skip.insert("imagename") }
        return friendlyCard(g, groups: groups, rows: rows, options: o)
    }

    // MARK: Box and click

    /// "+ Add a Box Behind It…": the widget's panel color (else a dark translucent box) and a little room around it.
    func addBoxBehind(_ section: String) {
        guard let skin else { return }
        var color = "0,0,0,128"
        if let bg = backgroundLayer(in: skin), let raw = skin.meter(named: bg)?.rawOption("Shape"),
           let fill = ShapeSpec.parse(raw)?.fill, case .color(let c) = fill {
            color = c
        }
        let a = skin.ownTarget(section: section, key: "SolidColor"), b = skin.ownTarget(section: section, key: "Padding")
        revealedGroups.insert("\(section)/Box Behind It")
        writeKeysPlainly([KeyWrite(file: a.file, section: a.section, key: "SolidColor", value: color),
                   KeyWrite(file: b.file, section: b.section, key: "Padding", value: "4,2,4,2")],
                  name: "Add a Box Behind It", message: "Added a box behind \(displayName(ofSection: section))")
    }

    /// WHEN CLICKED: Click [what ▾] and its detail, Pointed at [what ▾], Tooltip; More Triggers.
    func whenClickedCard(_ m: Meter, group: EditorSchema.Group, groups: [EditorSchema.Group], skin: Skin) -> NSView {
        var o = CardOptions(section: m.name)
        o.custom["leftmouseupaction"] = { [weak self] ctx in self?.clickRow(ctx, meter: m, label: "Click", pointing: false) }
        o.custom["mouseoveraction"] = { [weak self] ctx in self?.clickRow(ctx, meter: m, label: "Pointed at", pointing: true) }
        // Every other trigger (right-click, double-click, scroll…) picks what happens the same way: never a field for
        // typing a command (P5); what the picker can't read back shows as a sentence with Edit in Code (P11).
        for p in group.properties where p.kind == .action && o.custom[p.key.lowercased()] == nil {
            let label = p.label
            o.custom[p.key.lowercased()] = { [weak self] ctx in self?.clickRow(ctx, meter: m, label: label, pointing: false) }
        }
        // One Pointer pop-up (the arrow, or a pointer shape) for the two options behind it.
        o.custom["mouseactioncursor"] = { [weak self] ctx in self?.pointerRow(ctx, meter: m) }
        o.skip.insert("mouseactioncursorname")
        // "Hide the tooltip" says nothing a person needs: an empty tooltip hides it. Shown only when it is set.
        if (OptionValue.number(m.rawOption("ToolTipHidden") ?? "0") ?? 0) == 0 { o.skip.insert("tooltiphidden") }
        return friendlyCard(group, groups: groups, rows: rows, options: o)
    }

    /// Pointer: "Arrow" (`MouseActionCursor=0`) or a pointer shape (`MouseActionCursorName`), as one pop-up; the pick
    /// is one undo step writing both.
    func pointerRow(_ ctx: PropertyContext, meter m: Meter) -> InspectorRow {
        let section = ctx.section
        let on = (OptionValue.number(m.rawOption("MouseActionCursor") ?? "1") ?? 1) != 0
        let shape = (m.rawOption("MouseActionCursorName") ?? "HAND").trimmingCharacters(in: .whitespaces).uppercased()
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("\(section)/pointer")
        let menu = NSMenu()
        let arrow = NSMenuItem(title: "Arrow", action: nil, keyEquivalent: "")
        arrow.representedObject = ""
        menu.addItem(arrow)
        menu.addItem(.separator())
        for c in EditorSchema.cursorNames {
            let item = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
            item.representedObject = c.value
            item.toolTip = c.supportedOnMac ? nil : "The Mac shows the arrow"
            menu.addItem(item)
        }
        popup.menu = menu
        let current = on ? shape : ""
        if let item = menu.items.first(where: { ($0.representedObject as? String) == current }) { popup.select(item) }
        popup.onAction { [weak self] c in
            guard let self, let value = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            var writes: [KeyWrite] = []
            // Arrow: MouseActionCursor=0; a shape: MouseActionCursor back on and the shape's name. A default (on, HAND)
            // is written by removing the layer's own key, unless a look sets something else — removing then changes
            // nothing, so the default is written instead.
            func back(to fallback: String, _ key: String, same: (String) -> Bool) -> String? {
                switch m.fileOrigin(key) {
                case nil: return nil
                case .own?: return m.styleFileOption(key).map(same) ?? true ? nil : fallback
                default: return fallback
                }
            }
            let cursorOn = back(to: "1", "MouseActionCursor") { (OptionValue.number($0) ?? 1) != 0 }
            if value.isEmpty {
                if on { writes += self.localWrites([section], key: "MouseActionCursor", value: "0").writes }
            } else {
                if !on { writes += self.localWrites([section], key: "MouseActionCursor", value: cursorOn).writes }
                if value != shape || !on {
                    let name = value == "HAND" ? back(to: "HAND", "MouseActionCursorName") {
                        $0.trimmingCharacters(in: .whitespaces).uppercased() == "HAND" } : value
                    writes += self.localWrites([section], key: "MouseActionCursorName", value: name).writes
                }
            }
            self.writeKeysPlainly(writes, name: "Change Pointer", message: value.isEmpty ? "Shows the arrow over it"
                                  : "Shows \(LayerNaming.inSentence(EditorSchema.cursorNames.first { $0.value == value }?.title ?? "a pointer")) over it")
        }
        let rowLabel = EditorStyle.rowLabel("Pointer", key: showsDetails ? "MouseActionCursor" : nil,
                                            tooltip: "What the pointer looks like over it")
        return InspectorRow(label: rowLabel, control: popup)
    }

    /// The choices of the click picker.
    enum ClickChoice: String, CaseIterable {
        case nothing = "Nothing"
        case website = "Open a Website…"
        case app = "Open an App…"
        case file = "Open a File or Folder…"
        case layer = "Show or Hide a Layer…"
        case widget = "Show or Hide Another Widget…"
        case reload = "Reload the Widget"
        case color = "Change Color To…"
        case showLayer = "Show a Layer…"
        case custom = "Custom Command…"

        static let click: [ClickChoice] = [.nothing, .website, .app, .file, .layer, .widget, .reload, .custom]
        static let pointing: [ClickChoice] = [.nothing, .color, .showLayer, .custom]
    }

    func clickChoice(_ action: ClickAction) -> ClickChoice {
        switch action {
        case .nothing: return .nothing
        case .openWebsite: return .website
        case .openApp: return .app
        case .openFile: return .file
        case .toggleLayer: return .layer
        case .showLayer: return .showLayer
        case .toggleWidget: return .widget
        case .reload: return .reload
        case .changeColor: return .color
        case .custom: return .custom
        }
    }

    /// Click / Pointed at: what happens, in words; the detail for the choice (an address, an app, a layer); anything
    /// the picker can't read back is shown as a sentence and never rewritten.
    func clickRow(_ ctx: PropertyContext, meter m: Meter, label: String, pointing: Bool) -> InspectorRow {
        let section = ctx.section, key = ctx.key
        let raw = ctx.raw
        let parsed = ClickAction.parse(raw)
        let pending = inspectorState.disclosures.first { $0.hasPrefix("click/\(section.lowercased())/\(key.lowercased())=") }
            .flatMap { ClickChoice(rawValue: String($0.split(separator: "=", maxSplits: 1).last ?? "")) }
        let available = pointing ? ClickChoice.pointing : ClickChoice.click
        // What this row's picker doesn't offer (a color change written for "Pointer leaves") reads as a sentence.
        let choice = pending ?? { let c = clickChoice(parsed); return available.contains(c) ? c : .custom }()
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("\(key).choice")
        let menu = NSMenu()
        for c in available {
            let item = NSMenuItem(title: c.rawValue, action: nil, keyEquivalent: "")
            item.representedObject = c.rawValue
            menu.addItem(item)
            if c == .nothing || c == .reload { menu.addItem(.separator()) }
        }
        popup.menu = menu
        if let item = menu.items.first(where: { ($0.representedObject as? String) == choice.rawValue }) { popup.select(item) }
        popup.closedTitle = { item in
            (item.representedObject as? String).map { NSAttributedString(string: $0.replacingOccurrences(of: "…", with: "")) }
        }
        popup.onAction { [weak self] c in
            guard let value = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String,
                  let picked = ClickChoice(rawValue: value) else { return }
            self?.clickChoiceMade(picked, section: section, key: key, pointing: pointing, meter: m.name)
        }
        var views: [NSView] = [popup]
        if let detail = clickDetail(choice, parsed: parsed, raw: raw, section: section, key: key, meter: m) { views.append(detail) }
        let stack = EditorStyle.vstack(views, spacing: 4)
        for v in views { v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        popup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let rowLabel = EditorStyle.rowLabel(label, key: showsDetails ? key : nil, tooltip: ctx.property.help)
        return InspectorRow(label: rowLabel, control: stack)
    }

    /// The line under a click choice: the address field, the app, the layer menu, or the sentence of a custom action.
    func clickDetail(_ choice: ClickChoice, parsed: ClickAction, raw: String, section: String, key: String, meter m: Meter) -> NSView? {
        guard let skin else { return nil }
        func write(_ action: ClickAction, leave: ClickAction? = nil) {
            self.writeClickAction(action, leave: leave, section: section, key: key)
        }
        switch choice {
        case .nothing, .reload:
            return nil
        case .website:
            var current = ""
            if case .openWebsite(let u) = parsed { current = u }
            let field = ValueField(current, placeholder: "https://example.com", monospaced: false)
            field.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/url")
            field.onCommit = { text in
                var t = text.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                if !t.contains("://") { t = "https://" + t }
                write(.openWebsite(t))
            }
            return field
        case .app, .file:
            var path = ""
            if case .openApp(let p) = parsed { path = p }
            if case .openFile(let p) = parsed { path = p }
            let name = path.isEmpty ? "Nothing chosen yet" : ActionSummary.sentence(for: "[\"\(path)\"]", name: { $0 }) ?? path
            // The whole sentence, on two lines if need be ("Opens “Activity Monitor”", never "Opens “Activi…").
            let label = NSTextField(wrappingLabelWithString: name)
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = .secondaryLabelColor
            label.isSelectable = false
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = inspectorControlWidth
            label.toolTip = path.isEmpty ? nil : path
            let choose = NSButton(title: "Choose…", target: nil, action: nil)
            choose.bezelStyle = .rounded
            choose.controlSize = .small
            choose.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/choose")
            let app = choice == .app
            choose.onAction { [weak self] _ in self?.chooseClickTarget(app: app, section: section, key: key) }
            let stack = EditorStyle.vstack([label, choose], spacing: 4)
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            return stack
        case .layer, .showLayer:
            var current = ""
            if case .toggleLayer(let n) = parsed { current = n }
            if case .showLayer(let n) = parsed { current = n }
            let popup = CompactPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/layer")
            let menu = NSMenu()
            let none = NSMenuItem(title: "Choose a layer", action: nil, keyEquivalent: "")
            none.representedObject = ""
            menu.addItem(none)
            for other in skin.meters.reversed() where other.name.caseInsensitiveCompare(section) != .orderedSame {
                let item = NSMenuItem(title: displayName(ofSection: other.name), action: nil, keyEquivalent: "")
                item.representedObject = other.name
                menu.addItem(item)
            }
            popup.menu = menu
            if let item = menu.items.first(where: { ($0.representedObject as? String)?.caseInsensitiveCompare(current) == .orderedSame }) {
                popup.select(item)
            }
            let showing = choice == .showLayer
            popup.onAction { c in
                guard let name = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, !name.isEmpty else { return }
                if showing {
                    write(.showLayer(name), leave: .custom("[!HideMeter \(name.contains(" ") ? "\"\(name)\"" : name)][!Redraw]"))
                } else {
                    write(.toggleLayer(name))
                }
            }
            return popup
        case .widget:
            var current = ""
            if case .toggleWidget(let c, _) = parsed { current = c }
            let popup = CompactPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/widget")
            let menu = NSMenu()
            let none = NSMenuItem(title: "Choose a widget", action: nil, keyEquivalent: "")
            none.representedObject = ""
            menu.addItem(none)
            for (config, file) in otherWidgets() {
                let item = NSMenuItem(title: config.split(separator: "\\").last.map(String.init) ?? config, action: nil, keyEquivalent: "")
                item.representedObject = "\(config)|\(file)"
                item.toolTip = config
                menu.addItem(item)
                if config.caseInsensitiveCompare(current) == .orderedSame { popup.select(item) }
            }
            popup.menu = menu
            popup.onAction { c in
                guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, v.contains("|") else { return }
                let parts = v.split(separator: "|", maxSplits: 1).map(String.init)
                write(.toggleWidget(config: parts[0], file: parts[1]))
            }
            return popup
        case .color:
            var current = ""
            if case .changeColor(_, _, let c) = parsed { current = c }
            let colorKey = Self.colorKey(forMeterType: m.type)
            let popup = CompactPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/color")
            let menu = NSMenu()
            for (title, value) in widgetColors(skin) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = value
                if let rgba = OptionValue.color(skin.resolve(value, in: nil, sectionVariables: false)) {
                    item.image = Self.swatchImage(rgba)
                }
                menu.addItem(item)
            }
            popup.menu = menu
            // The choice written, else the one of the same color (same-value colors are one choice).
            let resolved = OptionValue.color(skin.resolve(current, in: nil, sectionVariables: false))
            if let item = menu.items.first(where: { ($0.representedObject as? String) == current })
                ?? menu.items.first(where: { item in
                    (item.representedObject as? String).flatMap { OptionValue.color(skin.resolve($0, in: nil, sectionVariables: false)) } == resolved
                        && resolved != nil
                }) {
                popup.select(item)
            }
            popup.toolTip = popup.titleOfSelectedItem
            let original = skin.section(named: section)?.rawOption(colorKey) ?? ""
            popup.onAction { c in
                guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
                write(.changeColor(section: section, key: colorKey, color: v),
                      leave: .changeColor(section: section, key: colorKey, color: original.isEmpty ? "255,255,255,255" : original))
            }
            return popup
        case .custom:
            let written: String? = {
                if case .custom(let text) = parsed { return text }
                return parsed == .nothing ? nil : raw
            }()
            if let text = written, !text.isEmpty {
                let sentence = ActionSummary.sentence(for: text, section: section, in: skin) ?? "Runs a command"
                let label = NSTextField(wrappingLabelWithString: sentence)
                label.font = .systemFont(ofSize: 11.5)
                label.textColor = .secondaryLabelColor
                label.isSelectable = false
                label.preferredMaxLayoutWidth = inspectorControlWidth
                label.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/sentence")
                label.toolTip = showsDetails ? text : nil
                let location = skin.sources.location(section: section, key: key)
                let code = linkLike("Edit in Code ›", id: "\(section)/\(key)/code") { [weak self] in self?.showInCode(location) }
                return EditorStyle.vstack([label, code], spacing: 2)
            }
            let field = ValueField(raw, placeholder: "[!Bang …]", monospaced: true)
            field.identifier = NSUserInterfaceItemIdentifier("\(section)/\(key)/raw")
            field.onCommit = { text in write(ClickAction.parse(text) == .nothing ? .nothing : .custom(text)) }
            return field
        }
    }

    /// A choice made in a click picker: written at once when it needs nothing more, otherwise its detail is shown.
    func clickChoiceMade(_ choice: ClickChoice, section: String, key: String, pointing: Bool, meter: String) {
        let prefix = "click/\(section.lowercased())/\(key.lowercased())="
        inspectorState.disclosures = inspectorState.disclosures.filter { !$0.hasPrefix(prefix) }
        switch choice {
        case .nothing:
            writeClickAction(.nothing, leave: pointing ? .nothing : nil, section: section, key: key)
        case .reload:
            writeClickAction(.reload, section: section, key: key)
        case .color:
            guard let skin else { return }
            let colorKey = Self.colorKey(forMeterType: skin.meter(named: meter)?.type ?? "")
            let original = skin.section(named: section)?.rawOption(colorKey) ?? ""
            let first = widgetColors(skin).first { $0.value != original }?.value ?? "255,255,255,255"
            writeClickAction(.changeColor(section: section, key: colorKey, color: first),
                             leave: .changeColor(section: section, key: colorKey, color: original.isEmpty ? "255,255,255,255" : original),
                             section: section, key: key)
        default:
            inspectorState.disclosures.insert(prefix + choice.rawValue)
            rebuildKeepingScroll()
        }
    }

    /// Writes a click action (and, for pointing, what leaving undoes), as one undo step.
    func writeClickAction(_ action: ClickAction, leave: ClickAction? = nil, section: String, key: String) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.writeClickAction(action, leave: leave, section: section, key: key) }) { return }
        guard let skin else { return }
        let prefix = "click/\(section.lowercased())/\(key.lowercased())="
        inspectorState.disclosures = inspectorState.disclosures.filter { !$0.hasPrefix(prefix) }
        var writes: [KeyWrite] = []
        func add(_ k: String, _ a: ClickAction) {
            writes += localWrites([section], key: k, value: a == .nothing ? nil : a.text).writes
        }
        add(key, action)
        if let leave { add("MouseLeaveAction", leave) }
        let sentence = action == .nothing ? "Does nothing when \(key.lowercased().hasPrefix("mouseover") ? "pointed at" : "clicked")"
            : (ActionSummary.sentence(for: action.text, section: section, in: skin) ?? "Runs a command")
        writeKeysPlainly(writes, name: key.lowercased().hasPrefix("mouseover") ? "Change When Pointed At" : "Change When Clicked",
                  message: sentence)
    }

    /// Open an App… / Open a File or Folder…: asks for it (NSOpenPanel).
    func chooseClickTarget(app: Bool, section: String, key: String) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !app
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: app ? "/Applications" : NSHomeDirectory())
        if app { panel.allowedContentTypes = [.application] }
        panel.prompt = app ? "Use App" : "Use"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeClickAction(app ? .openApp(url.path) : .openFile(url.path), section: section, key: key)
        }
    }

    /// The widgets installed besides this one (config, file), for "Show or Hide Another Widget…".
    func otherWidgets() -> [(String, String)] {
        var result: [(String, String)] = []
        let root = app.skinsDirectory
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            if url.lastPathComponent == "@Resources" { e.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "ini" else { continue }
            let folder = url.deletingLastPathComponent().path
            guard folder.hasPrefix(root.path + "/") else { continue }
            let config = String(folder.dropFirst(root.path.count + 1)).replacingOccurrences(of: "/", with: "\\")
            if config.caseInsensitiveCompare(self.config) == .orderedSame || result.contains(where: { $0.0 == config }) { continue }
            result.append((config, url.lastPathComponent))
            if result.count >= 60 { break }
        }
        return result.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    /// The option a layer's "color" is (for Change Color To…).
    static func colorKey(forMeterType type: String) -> String {
        switch type.lowercased() {
        case "string": return "FontColor"
        case "bar": return "BarColor"
        case "line", "roundline": return "LineColor"
        case "histogram": return "PrimaryColor"
        default: return "SolidColor"
        }
    }

    /// Colors of the widget for menus: its shared colors by name, then colors written in its layers.
    func widgetColors(_ skin: Skin) -> [(title: String, value: String)] {
        var result: [(String, String)] = []
        var titles: Set<String> = []
        for v in skin.inspectedVariables() where OptionValue.color(v.current) != nil && v.raw.contains(",") || EditorStyle.isColorKey(v.name) {
            guard OptionValue.color(v.current) != nil else { continue }
            // Named as the widget page names it (one name per color, §7.4); same-value colors are one choice.
            let title = colorRoleName(variable: v.name, color: nil).flatMap { $0 == "Shared color" ? nil : $0 }
                ?? Self.sharedValueName(v.name)
            guard titles.insert(title).inserted else { continue }
            result.append((title, "#\(v.name)#"))
        }
        var seen = Set(result.map(\.1))
        for m in skin.meters {
            for key in ["FontColor", "BarColor", "SolidColor", "LineColor"] {
                guard let raw = m.rawOption(key)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.contains("#"),
                      OptionValue.color(raw) != nil, seen.insert(raw).inserted else { continue }
                result.append(("Color of \(displayName(ofSection: m.name))", raw))
            }
        }
        return result
    }

    /// A small color swatch for menus.
    static func swatchImage(_ c: RGBA) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 10), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            c.nsColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    // MARK: Shapes

    /// A Shape layer: SHAPE (type, corners, fill, outline, "Follows"), PARTS when it has two or more, and the exact
    /// geometry (the Shape editor) under More Shape Options.
    func shapeCards(_ m: Meter, groups: [EditorSchema.Group], skin: Skin) {
        let items = shapeItems(of: m.name)
        guard let group = groups.first(where: { $0.title == "Shape" }) else { return }
        // The part the user picked, else the one that follows data (the colored fill of a memory bar, what one sees),
        // else the first.
        let dataPart = items.first { !sectionReferences(in: $0.row.raw).compactMap { skin.measure(named: $0) }.isEmpty }
        let selectedKey = items.first { $0.key.caseInsensitiveCompare(inspectorState.expandedShapes[m.name.lowercased()] ?? "") == .orderedSame }?.key
            ?? dataPart?.key ?? items.first?.key
        if items.count >= 2 { add(partsCard(m, items: items, selected: selectedKey)) }
        var views: [NSView] = [cardTitleRow("Shape", accessory: lookBehind(group, section: m.name, rows: rows).map {
            lookBadge(look: $0.look, users: $0.users)
        })]
        var gridRows: [InspectorRow] = []
        if let key = selectedKey, let item = items.first(where: { $0.key == key }), let spec = item.spec, spec.unknownType == nil {
            gridRows += shapeEssentials(m, item: item, spec: spec)
        } else if items.isEmpty {
            views.append(cardNote("This shape has nothing to draw yet."))
        } else {
            views.append(cardNote("This part is written in a way the controls can't show. Open More Shape Options or the code."))
        }
        if let follows = followsRow(m, items: items, skin: skin) { gridRows.append(follows) }
        if !gridRows.isEmpty { views.append(EditorStyle.grid(gridRows)) }
        if items.count <= 1 {
            let add = outcomeButton("Add Another Shape", id: "add-shape") { [weak self] _ in self?.addShape(.rectangle, meter: m.name) }
            views.append(EditorStyle.hstack([add, EditorStyle.spacer()], spacing: 0))
        }
        // More Shape Options: the exact geometry, transforms, dashes and line ends (the Shape editor).
        let inUse = items.contains { item in
            guard let spec = item.spec else { return false }
            return spec.modifiers.contains { mod in
                switch mod { case .rotate, .scale, .skew, .offset, .strokeDashes: return true; default: return false }
            }
        } ? 1 : 0
        let open = isMoreOpen(group, section: m.name, inUse: inUse)
        views.append(moreRow(group, section: m.name, inUse: inUse, open: open))
        // (With Rainmeter Details, the whole editor: every setting of every part.)
        if open { views.append(ShapeEditorView(controller: self, meter: m.name, essentialsAbove: !showsDetails)) }
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card-Shape")
        add(card)
    }

    /// PARTS: "This shape has 2 parts", one row each; clicking one scopes Type, Corners, Fill and Outline to it.
    func partsCard(_ m: Meter, items: [ShapeEditorView.ShapeItem], selected: String?) -> NSView {
        var views: [NSView] = [cardTitleRow("Parts", accessory: nil), cardNote("This shape has \(items.count) parts. Click one to change it.")]
        // A bar built from shapes: the part whose length follows data is its fill, a full-length part without data under
        // it the track (§8.5).
        let followed = items.map { sectionReferences(in: $0.row.raw).compactMap { skin?.measure(named: $0) }.first }
        let isBar = followed.contains { $0 != nil } && followed.contains { $0 == nil }
        for (i, item) in items.enumerated() {
            var role = ""
            if isBar, followed[i] == nil, item.spec?.kind == .rectangle { role = " — track (empty part)" }
            if isBar, followed[i] != nil { role = " — fill" }
            let title = "\(i + 1)  \(ShapeEditorView.summary(item))\(role)"
            // What it follows reads whole on a line of its own ("its length follows memory used").
            var follows: String?
            if let data = followed[i], let skin {
                follows = isBar ? "its length follows \(Self.lowerFirst(dataName(data, in: skin)))"
                    : "follows \(Self.lowerFirst(dataName(data, in: skin)))"
            }
            let b = NSButton(title: title, target: nil, action: nil)
            b.isBordered = false
            b.alignment = .left
            b.font = .systemFont(ofSize: 12, weight: item.key == selected ? .semibold : .regular)
            b.contentTintColor = item.key == selected ? .controlAccentColor : .labelColor
            b.identifier = NSUserInterfaceItemIdentifier("part-\(item.key)")
            b.lineBreakMode = .byTruncatingTail
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let key = item.key, meter = m.name
            b.onAction { [weak self] _ in
                self?.inspectorState.expandedShapes[meter.lowercased()] = key
                self?.rebuildKeepingScroll()
            }
            views.append(b)
            if let follows {
                let note = NSTextField(wrappingLabelWithString: follows)
                note.font = .systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor
                note.isSelectable = false
                let line = EditorStyle.hstack([note], spacing: 0)
                line.edgeInsets = NSEdgeInsets(top: -4, left: 18, bottom: 0, right: 0)
                line.identifier = NSUserInterfaceItemIdentifier("part-\(item.key)-follows")
                views.append(line)
            }
        }
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card-Parts")
        return card
    }

    /// The SHAPE card's rows for one part: Type, Corners (rectangles), Fill, Outline.
    func shapeEssentials(_ m: Meter, item: ShapeEditorView.ShapeItem, spec: ShapeSpec) -> [InspectorRow] {
        let meter = m.name, key = item.key
        var result: [InspectorRow] = []
        // Type: a rectangle with corners reads "Rounded rectangle".
        let kinds: [(String, ShapeSpec.Kind, String)] = [("Rectangle", .rectangle, "rectangle"), ("Rounded rectangle", .rectangle, "rectangle.roundedtop"),
                                                         ("Circle", .ellipse, "circle"), ("Line", .line, "line.diagonal"),
                                                         ("Arc", .arc, "circle.bottomhalf.filled"), ("Curve", .curve, "scribble"),
                                                         ("Path", .path, "hexagon"), ("Combined shapes", .combine, "square.on.circle")]
        let radius = spec.rectangle.flatMap { OptionValue.number(item.resolved?.rectangle?.effectiveRadiusX ?? $0.effectiveRadiusX) } ?? 0
        let currentTitle: String = {
            if spec.kind == .rectangle { return radius > 0 ? "Rounded rectangle" : "Rectangle" }
            return kinds.first { $0.1 == spec.kind }?.0 ?? spec.kind.title
        }()
        let type = CompactPopUpButton()
        type.identifier = NSUserInterfaceItemIdentifier("shape-page-type")
        let menu = NSMenu()
        for (title, kind, symbol) in kinds where kind != .combine || spec.kind == .combine {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.representedObject = title
            it.image = EditorStyle.image(symbol, size: 12)
            menu.addItem(it)
            if title == currentTitle { type.select(it) }
            _ = kind
        }
        type.menu = menu
        if let it = menu.items.first(where: { ($0.representedObject as? String) == currentTitle }) { type.select(it) }
        type.closedTitleShowsImage = false
        type.closedTitle = { item in (item.representedObject as? String).map { NSAttributedString(string: $0) } }
        type.onAction { [weak self] c in
            guard let self, let title = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, title != currentTitle,
                  let kind = kinds.first(where: { $0.0 == title })?.1 else { return }
            if kind == .rectangle, spec.kind == .rectangle {
                self.setShapeCorners(title == "Rounded rectangle" ? "10" : nil, key: key, meter: meter)
            } else {
                self.setShapeKind(kind, key: key, meter: meter)
            }
        }
        result.append(InspectorRow(label: EditorStyle.rowLabel("Type", key: showsDetails ? key : nil, tooltip: "What this part is"),
                                   control: type))
        if spec.kind == .rectangle, let rect = spec.rectangle {
            let presets: [(String, Double)] = [("Square", 0), ("Small", 4), ("Medium", 10), ("Large", 16)]
            let written = rect.radiusX ?? "0"
            let selected = presets.firstIndex { $0.1 == radius && rect.radiusY == nil }
            // Four worded choices do not fit the column as segments: a pop-up, "Custom" for other radii.
            let seg = CompactPopUpButton()
            seg.identifier = NSUserInterfaceItemIdentifier("shape-corners")
            if selected == nil { seg.addItem(withTitle: "Custom") }
            for p in presets { seg.addItem(withTitle: p.0) }
            if let selected { seg.selectItem(withTitle: presets[selected].0) } else { seg.selectItem(at: 0) }
            seg.onAction { [weak self] c in
                guard let t = (c as? NSPopUpButton)?.titleOfSelectedItem, let p = presets.first(where: { $0.0 == t }) else { return }
                self?.setShapeCorners(p.1 == 0 ? nil : GeometryEdit.format(p.1), key: key, meter: meter)
            }
            let field = GeometryField(OptionValue.number(written) != nil ? written : GeometryEdit.format(radius))
            field.identifier = NSUserInterfaceItemIdentifier("\(meter)/\(key)/corners")
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 38).isActive = true
            field.toolTip = "Corner radius in px"
            field.onCommit = { [weak self] text in
                guard let n = Self.plainNumber(text) else { return }
                self?.setShapeCorners(n == 0 ? nil : GeometryEdit.format(n), key: key, meter: meter)
            }
            seg.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // Where the column is narrow (legacy scroll bars), the pop-up gives way; the unit stays whole.
            let unit = EditorStyle.label("px", size: 11, color: .tertiaryLabelColor)
            unit.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let line = EditorStyle.hstack([seg, field, unit], spacing: 4)
            let stack = line
            result.append(InspectorRow(label: EditorStyle.rowLabel("Corners", key: nil, tooltip: "How round the corners are"),
                                       control: stack))
        }
        // Fill: None | Color | Gradient, and its color.
        if spec.isClosed != false {
            let mode = ShapeEditorView.fillMode(spec)
            let index: Int = { switch mode { case .none: return 0; case .color: return 1; default: return 2 } }()
            let seg = wordedSegments(["None", "Color", "Gradient"], symbols: [nil, nil, nil], selected: index, id: "shape-page-fill") { [weak self] i in
                self?.setShapeFillMode([.none, .color, .linear][i], key: key, meter: meter)
            }
            var views: [NSView] = [seg]
            if case .color(let c)? = spec.fill {
                views.append(shapePaintControl(meter: meter, key: key, written: c, resolved: item.resolved?.fill, stroke: false))
            } else if mode == .linear || mode == .radial {
                views.append(cardNote("Change the gradient's colors in More Shape Options."))
            }
            let stack = EditorStyle.vstack(views, spacing: 4)
            result.append(InspectorRow(label: EditorStyle.rowLabel("Fill", key: nil, tooltip: "What fills it"), control: stack))
        }
        // Outline.
        let width = spec.strokeWidth.flatMap { OptionValue.number(item.resolved?.strokeWidth ?? $0) } ?? 1
        let on = width > 0
        let box = CheckboxRow(title: "Outline", width: inspectorControlWidth)
        box.box.state = on ? .on : .off
        box.box.identifier = NSUserInterfaceItemIdentifier("shape-page-outline")
        box.box.onAction { [weak self] b in self?.setShapeStroke((b as? NSButton)?.state == .on, key: key, meter: meter) }
        var views: [NSView] = [box]
        if on {
            let color: String = { if case .color(let c)? = spec.stroke { return c } else { return "0,0,0,255" } }()
            let thickness = GeometryField(GeometryEdit.format(width))
            thickness.identifier = NSUserInterfaceItemIdentifier("\(meter)/\(key)/thickness")
            thickness.alignment = .right
            thickness.widthAnchor.constraint(equalToConstant: 40).isActive = true
            thickness.onCommit = { [weak self] text in
                guard let n = Self.plainNumber(text) else { return }
                self?.editShape(key, meter: meter) { $0.setStrokeWidth(GeometryEdit.format(n)) }
            }
            let dashes = CompactPopUpButton()
            dashes.identifier = NSUserInterfaceItemIdentifier("shape-page-dashes")
            let current: String = {
                guard case .strokeDashes(let d)? = spec.modifier(.strokeDashes), !d.isEmpty else { return "Solid" }
                return d == ["1", "1"] ? "Dotted" : d == ["4", "2"] ? "Dashed" : "Custom"
            }()
            for t in ["Solid", "Dashed", "Dotted"] + (current == "Custom" ? ["Custom"] : []) { dashes.addItem(withTitle: t) }
            dashes.selectItem(withTitle: current)
            dashes.onAction { [weak self] c in
                guard let t = (c as? NSPopUpButton)?.titleOfSelectedItem, t != current, t != "Custom" else { return }
                self?.editShape(key, meter: meter) { $0.setStrokeDashes(t == "Solid" ? nil : t == "Dotted" ? ["1", "1"] : ["4", "2"]) }
            }
            views.append(shapePaintControl(meter: meter, key: key, written: color, resolved: item.resolved?.stroke, stroke: true))
            let px = EditorStyle.label("px", size: 11, color: .tertiaryLabelColor)
            px.setContentCompressionResistancePriority(.required, for: .horizontal)
            dashes.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = EditorStyle.hstack([thickness, px, dashes, EditorStyle.spacer()], spacing: 5)
            views.append(line)
        }
        let stack = EditorStyle.vstack(views, spacing: 4)
        result.append(InspectorRow(label: nil, control: stack))
        return result
    }

    /// A shape's fill or outline color, shown like every color in the inspector (§7.4): the swatch on a rim that
    /// shows on light and dark cards, the color's name (as the widget page names it: "Background panel", else "Custom") with ▾, and
    /// its opacity below 100%. The swatch and the name open the color menu (`shapePaintMenu`). The color panel
    /// ("Custom Color…") previews on the shape and writes a color of its own into it.
    func shapePaintControl(meter: String, key: String, written: String, resolved: ShapeSpec.Paint?, stroke: Bool) -> NSView {
        let id = stroke ? "shape-page-stroke-color" : "shape-page-fill-color"
        let color = resolved?.rgba ?? OptionValue.color(written)
        let variable = wholeVariable(written)
        let swatch = SwatchButton()
        swatch.color = color
        swatch.backdrop = widgetPanelColor()  // drawn over the widget's panel color, as every color control (§7.4)
        swatch.identifier = NSUserInterfaceItemIdentifier(id)
        swatch.removeConstraints(swatch.constraints)
        swatch.widthAnchor.constraint(equalToConstant: 26).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
        ShapeColorPicker.shared.register(swatch, identity: "\(meter)/\(key)/page-\(stroke ? "stroke" : "fill")", controller: self) {
            [weak self] rgba, finished in
            self?.previewShapeEdit(key, meter: meter, finished: finished) { spec in
                // A color of its own, written the way the shape writes its colors (a theme color: as its value).
                let like = self?.skin?.resolve(written, in: nil, sectionVariables: false) ?? written
                let text = ColorText.format(rgba, like: like)
                if stroke { spec.setStroke(.color(text)) } else { spec.setFill(.color(text)) }
            }
        }
        // Named as the widget page names it (a theme color by its role, a written color by its uses), else "Custom".
        let name = NSButton(title: colorRoleName(variable: variable, color: color) ?? "Custom", target: nil, action: nil)
        name.isBordered = false
        name.font = .systemFont(ofSize: 12)
        name.image = EditorStyle.image("chevron.down", size: 8, weight: .semibold)
        name.imagePosition = .imageTrailing
        name.contentTintColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.identifier = NSUserInterfaceItemIdentifier("\(id).name")
        name.setAccessibilityLabel("\(stroke ? "Outline" : "Fill") color: \(name.title)")
        for control in [swatch, name] as [NSControl] {
            control.onAction { [weak self, weak control, weak swatch] _ in
                guard let self, let control, let swatch else { return }
                let menu = self.shapePaintMenu(meter: meter, key: key, stroke: stroke, swatch: swatch)
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: control.isFlipped ? control.bounds.maxY + 4 : -4), in: control)
            }
        }
        var tip = color.map { c in Self.hexColor(c) + (c.a < 254.5 ? " · \(Int((c.a / 255 * 100).rounded()))% opacity" : "") } ?? written
        if showsDetails { tip = (variable ?? "Color") + " · " + (skin?.resolve(written, in: nil, sectionVariables: false) ?? written) }
        swatch.toolTip = tip
        name.toolTip = tip
        let rim = SwatchRim(swatch)
        var parts: [NSView] = [rim, name]
        var under: NSView?
        if let color, color.a < 254.5 {
            let opacity = EditorStyle.label("\(Int((color.a / 255 * 100).rounded()))%", size: 11, color: .secondaryLabelColor)
            opacity.identifier = NSUserInterfaceItemIdentifier("\(id).opacity")
            opacity.setContentCompressionResistancePriority(.required, for: .horizontal)
            // The name reads whole: when it and the opacity don't fit beside the swatch, the opacity goes under it.
            let room = inspectorControlWidth - rim.fittingSize.width - 6
            if name.intrinsicContentSize.width + 6 + opacity.intrinsicContentSize.width <= room {
                parts.append(opacity)
            } else {
                opacity.stringValue += " opacity"
                let line = EditorStyle.hstack([opacity, EditorStyle.spacer()], spacing: 0)
                line.edgeInsets = NSEdgeInsets(top: -2, left: rim.fittingSize.width + 6, bottom: 0, right: 0)
                under = line
            }
        }
        parts.append(EditorStyle.spacer())
        let line = EditorStyle.hstack(parts, spacing: 6)
        guard let under else { return line }
        let stack = EditorStyle.vstack([line, under], spacing: 2)
        for v in [line, under] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    /// The color menu of a shape's fill or outline (§7.4): its header, THEME COLORS (writes the link, `#Name#`),
    /// USED IN THIS WIDGET (writes the color), Custom Color…, "Change ‘Track color’ Everywhere…" for a theme color (the
    /// shared color itself, with the color panel), Copy Color Code.
    func shapePaintMenu(meter: String, key: String, stroke: Bool, swatch: SwatchButton?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let skin, let item = shapeItem(key, of: meter), let spec = item.spec else { return menu }
        let paint = stroke ? spec.stroke : spec.fill
        let written: String = { if case .color(let c)? = paint { return c } else { return "" } }()
        let color = (stroke ? item.resolved?.stroke : item.resolved?.fill)?.rgba ?? OptionValue.color(written)
        let variable = wholeVariable(written)
        let head = NSMenuItem(title: "\(stroke ? "Outline" : "Fill") · \(displayName(ofSection: meter))", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let set: (String) -> Void = { [weak self] text in
            self?.editShape(key, meter: meter) { s in if stroke { s.setStroke(.color(text)) } else { s.setFill(.color(text)) } }
        }
        let colors = shapeMenuColors(skin)
        let themes = colors.filter { $0.value.hasPrefix("#") }
        let used = colors.filter { !$0.value.hasPrefix("#") }
        if !themes.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Theme Colors"))
            for c in themes {
                let entry = ClosureMenuItem(c.title) { set(c.value) }
                if let rgba = OptionValue.color(skin.resolve(c.value, in: nil, sectionVariables: false)) { entry.image = Self.swatchImage(rgba) }
                entry.state = c.value.caseInsensitiveCompare(written) == .orderedSame ? .on : .off
                entry.identifier = NSUserInterfaceItemIdentifier("theme-color-\(c.value.trimmingCharacters(in: CharacterSet(charactersIn: "#")))")
                entry.toolTip = showsDetails ? c.value : nil
                menu.addItem(entry)
            }
        }
        if !used.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Used in This Widget"))
            for c in used {
                guard let rgba = OptionValue.color(c.value) else { continue }
                let text = ColorText.format(rgba, like: color == nil ? nil : skin.resolve(written, in: nil, sectionVariables: false))
                let entry = ClosureMenuItem(c.title) { set(text) }
                entry.image = Self.swatchImage(rgba)
                entry.state = variable == nil && color.map(Self.hexColor) == Self.hexColor(rgba) && color?.a == rgba.a ? .on : .off
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        let custom = ClosureMenuItem("Custom Color…") { [weak swatch] in
            guard let swatch else { return }
            ShapeColorPicker.shared.swatchClicked(swatch)
        }
        custom.identifier = NSUserInterfaceItemIdentifier("custom-color")
        menu.addItem(custom)
        if let variable {
            // The shared color itself (as the Shape editor always did): every layer using it follows. Named as its
            // widget-page row is.
            let role = colorRoleName(variable: variable, color: nil) ?? Self.sharedValueName(variable)
            let users = layersUsing(variable: variable, in: skin)
            let shared = skin.sources.location(section: "Variables", key: variable).map { !Self.isWidgetFile($0.file, of: skin) } ?? false
            let title = shared ? "Change ‘\(role)’ for Every Widget Sharing It…"
                : "Change ‘\(role)’ Everywhere (\(users.count) layer\(users.count == 1 ? "" : "s"))…"
            let everywhere = ClosureMenuItem(title) { [weak self] in
                guard let self else { return }
                ShapeColorPicker.shared.relinquish()
                self.beginColorEdit(section: meter, key: key, raw: written, variable: variable)
                InspectorColorPanel.shared.open(for: self, color: color?.nsColor ?? .white)
            }
            everywhere.identifier = NSUserInterfaceItemIdentifier("change-everywhere")
            menu.addItem(everywhere)
        }
        if let color {
            let hex = Self.hexColor(color)
            menu.addItem(ClosureMenuItem("Copy Color Code  (\(hex))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
            })
        }
        return menu
    }

    /// The colors a shape's color menu offers: the widget's (`widgetColors`) and the colors its shapes are filled
    /// and outlined with.
    func shapeMenuColors(_ skin: Skin) -> [(title: String, value: String)] {
        var result = widgetColors(skin)
        var seen = Set(result.map { $0.value.lowercased() })
        for m in skin.meters where m.type.lowercased() == "shape" {
            for item in shapeItems(of: m.name) {
                guard let spec = item.spec else { continue }
                for (paint, what) in [(spec.fill, "Fill"), (spec.stroke, "Outline")] {
                    guard case .color(let c)? = paint, !c.contains("#"), !c.contains("["), OptionValue.color(c) != nil,
                          seen.insert(c.lowercased()).inserted else { continue }
                    result.append(("\(what) of \(displayName(ofSection: m.name))", c))
                }
            }
        }
        return result
    }

    /// "#78C8FF" (the color without its opacity).
    static func hexColor(_ c: RGBA) -> String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int(max(0, min(255, v.rounded())))) }
        return "#" + byte(c.r) + byte(c.g) + byte(c.b)
    }

    /// Sets a rectangle's corner radius (nil: square), keeping the rest of the shape as written.
    func setShapeCorners(_ radius: String?, key: String, meter: String) {
        editShape(key, meter: meter) { spec in
            guard spec.kind == .rectangle else { return }
            while spec.params.count < 4 { spec.params.append("0") }
            spec.params = Array(spec.params.prefix(4))
            if let radius { spec.params.append(radius) }
        }
    }

    /// Follows [Memory used ▾]: a shape whose formulas use live data can follow other data (the name is swapped in
    /// every option of this layer that uses it, one undo step).
    func followsRow(_ m: Meter, items: [ShapeEditorView.ShapeItem], skin: Skin) -> InspectorRow? {
        let used = items.flatMap { sectionReferences(in: $0.row.raw) }.compactMap { skin.measure(named: $0) }
        guard let data = used.first else { return nil }
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("shape-follows")
        let menu = NSMenu()
        for measure in skin.measures {
            let item = NSMenuItem(title: dataName(measure, in: skin), action: nil, keyEquivalent: "")
            item.representedObject = measure.name
            menu.addItem(item)
        }
        popup.menu = menu
        if let item = menu.items.first(where: { ($0.representedObject as? String) == data.name }) { popup.select(item) }
        let meter = m.name, old = data.name
        popup.onAction { [weak self] c in
            guard let new = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, new != old else { return }
            self?.swapData(in: meter, from: old, to: new)
        }
        return InspectorRow(label: EditorStyle.rowLabel("Follows", key: nil, tooltip: "The live data its size follows"), control: popup)
    }

    /// Replaces `[Old]` / `[Old:…]` with the new name in every option of `meter` that uses it, one undo step.
    func swapData(in meter: String, from old: String, to new: String) {
        guard let skin else { return }
        var writes: [KeyWrite] = []
        let pattern = "\\[" + NSRegularExpression.escapedPattern(for: old) + "(?=[\\]:])"
        for r in rows(of: meter, kind: .meter) where r.raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            let value = r.raw.replacingOccurrences(of: pattern, with: "[" + new, options: [.regularExpression, .caseInsensitive])
            let t = skin.editTarget(section: meter, key: r.key)
            writes.append(KeyWrite(file: t.file, section: t.section, key: r.key, value: value))
        }
        let name = skin.measure(named: new).map { dataName($0, in: skin) } ?? new
        writeKeysPlainly(writes, name: "Follow " + Self.titleCase(name), message: "\(displayName(ofSection: meter)) now follows \(Self.lowerFirst(name))")
    }

    // MARK: Lines the controls can't show

    /// With Rainmeter Details: every option of the layer the controls don't cover, as editable `key = value` lines
    /// (only when there are any), and a way to add one.
    func unshownLinesCard(section: String, groups: [EditorSchema.Group], meter: Meter?) -> NSView {
        let card = otherOptionsCard(section: section, rows: rows, groups: groups, open: true,
                                    title: "Lines Deskset Can't Show as Controls", meter: meter)
        card.identifier = NSUserInterfaceItemIdentifier("card-unshown")
        return card
    }

    // MARK: - A group of repeated layers

    /// The group page (docs/editor-friendly.md §8.4): "16 bars", changes apply to all; BARS, SPACING, ARRANGE.
    func groupPage(_ series: Series, skin: Skin) {
        let members = series.members.compactMap { skin.meter(named: $0) }
        guard let first = members.first else { return }
        let names = members.map(\.name)
        noteSelectionShown("group:" + names.joined(separator: ","))
        let counted = countedLayers(names, in: skin)
        let kind = LayerNaming.kindNoun(first)
        let data = members.compactMap { $0.measures.first }
        var sentence = counted.prefix(1).uppercased() + counted.dropFirst()
        if data.count == members.count, let range = dataRange(data.map { dataName($0, in: skin) }) {
            sentence += " showing \(range)" + (members.count > 1 ? ", low to high." : ".")
        } else {
            sentence += "."
        }
        var buttons: [NSView] = []
        let allHidden = members.allSatisfy(\.hidden)
        buttons.append(stripButton(allHidden ? "Show All" : "Hide All", symbol: allHidden ? "eye" : "eye.slash", id: "strip-hide") { [weak self] in
            self?.setLayersHidden(names, hidden: !allHidden)
        })
        let allLocked = names.allSatisfy(isLayerLocked)
        buttons.append(stripButton(allLocked ? "Unlock All" : "Lock All", symbol: allLocked ? "lock.open" : "lock", id: "strip-lock") { [weak self] in
            self?.setLayersLocked(names, locked: !allLocked)
        })
        buttons.append(stripMenuButton { [weak self] in
            guard let self else { return NSMenu() }
            return LayerMenu.make(for: names, in: self)
        })
        var lines: [NSView] = [cardNote("Changes apply to all \(members.count). Double-click a \(kind.lowercased()) on the canvas to change just one.")]
        if let cut = cutOffLine(names, in: skin) { lines.append(cut) }
        add(identityStrip(title: counted, sentence: sentence,
                          picture: stripPicture(image: layerPicture(names, in: skin), symbol: LayerNaming.symbol(forMeterType: first.type)),
                          crumbs: [(widgetName(skin), { [weak self] in self?.canvasSelectionChanged([]) })], buttons: buttons, lines: lines))
        let firstRows = rows(of: first.name, kind: .meter)
        let groups = EditorSchema.meterGroups(first.type)
        if first.type.lowercased() == "bar", let bar = groups.first {
            add(groupBarsCard(members, group: bar, groups: groups, rows: firstRows, data: data, skin: skin))
        } else {
            add(sharedKindCard(names, skin: skin, title: Self.titleCase(Self.pluralKind(kind, count: 2))))
        }
        if let spacing = spacingCard(members, skin: skin) { add(spacing) }
        let arrange = EditorCard(title: nil, views: [cardTitleRow("Arrange", accessory: nil),
                                                     groupAlignButtons(names)])
        arrange.identifier = NSUserInterfaceItemIdentifier("card-Arrange")
        add(arrange)
    }

    /// "sound bands 1–16" for "Sound band 1" … "Sound band 16".
    func dataRange(_ names: [String]) -> String? {
        guard let first = names.first, let last = names.last, names.count > 1 else { return names.first.map(Self.lowerFirst) }
        let stem: (String) -> String = { $0.replacingOccurrences(of: #"\s*\d+$"#, with: "", options: .regularExpression) }
        guard stem(first) == stem(last), !stem(first).isEmpty else { return nil }
        let a = first.dropFirst(stem(first).count).trimmingCharacters(in: .whitespaces)
        let b = last.dropFirst(stem(last).count).trimmingCharacters(in: .whitespaces)
        return "\(Self.lowerFirst(Self.pluralKind(stem(first), count: 2))) \(a)–\(b)"
    }

    /// BARS: each shows (read-only), sound from, Fill, Empty part, Fills toward — written for all of them.
    func groupBarsCard(_ members: [Meter], group: EditorSchema.Group, groups: [EditorSchema.Group], rows firstRows: [Row],
                       data: [Measure], skin: Skin) -> NSView {
        let first = members[0]
        var views: [NSView] = [cardTitleRow("Bars", accessory: lookBehind(group, section: first.name, rows: firstRows).map {
            lookBadge(look: $0.look, users: $0.users)
        })]
        var items: [InspectorRow] = []
        if data.count == members.count, let range = dataRange(data.map { dataName($0, in: skin) }) {
            let label = NSTextField(wrappingLabelWithString: range.prefix(1).uppercased() + range.dropFirst() + ", one each")
            label.font = .systemFont(ofSize: 12)
            label.isSelectable = false
            label.preferredMaxLayoutWidth = inspectorControlWidth
            label.identifier = NSUserInterfaceItemIdentifier("each-shows")
            items.append(InspectorRow(label: EditorStyle.rowLabel("Each shows", key: nil, tooltip: "The live data of each bar"),
                                      control: label))
        }
        // Sound from: the parent of the bars' sound data.
        let parents = Set(data.compactMap { $0.rawOption("Parent")?.lowercased() })
        if parents.count == 1, let parent = skin.measure(named: data[0].rawOption("Parent") ?? ""),
           EditorSchema.measureType(type: parent.type, plugin: parent.rawOption("Plugin"))?.name == "AudioLevel",
           let port = EditorSchema.property("Port", in: EditorSchema.measureGroups("Plugin", plugin: "AudioLevel")) {
            let prows = rows(of: parent.name, kind: .measure)
            let ctx = context(port, section: parent.name, rows: prows)
            let popup = choiceControl(ctx, choices: [EditorSchema.Choice("Output", "What your Mac plays"),
                                                     EditorSchema.Choice("Input", "Microphone")], style: .popup, write: writer(ctx))
            let link = linkLike("Sound Settings ›", id: "sound-settings") { [weak self] in self?.select(section: parent.name) }
            let stack = EditorStyle.vstack([popup, link], spacing: 3)
            popup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            items.append(InspectorRow(label: EditorStyle.rowLabel("Sound from", key: nil, tooltip: "Where the sound comes from"),
                                      control: stack))
        }
        // Fill and Empty part: read from the first bar, written for all of them (their look when they share one).
        let names = members.map(\.name)
        for key in ["BarColor", "SolidColor"] {
            guard let p = EditorSchema.property(key, in: groups) else { continue }
            items.append(propertyRow(p, section: first.name, row: row(for: p, in: firstRows), groups: groups, friendly: true,
                                     selection: names))
        }
        if let orientation = EditorSchema.property("BarOrientation", in: groups),
           let r = fillsTowardRow(context(orientation, section: first.name, rows: firstRows), sections: members.map(\.name)) {
            items.append(r)
        }
        views.append(EditorStyle.grid(items))
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card-Bars")
        return card
    }

    /// SPACING (docs/editor-friendly.md §8.4): the shared sizes the members use — width, gap, height — and where the
    /// run starts. A size written as a shared value edits it (and says who else moves); otherwise every member.
    func spacingCard(_ members: [Meter], skin: Skin) -> NSView? {
        let names = members.map(\.name)
        var items: [InspectorRow] = []
        func common(_ key: String, _ list: ArraySlice<Meter>) -> String? {
            let values = Set(list.map { meter -> String in
                let raw = self.rows(of: meter.name, kind: .meter).first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.raw
                return (raw ?? "").trimmingCharacters(in: .whitespaces)
            })
            return values.count == 1 ? values.first : nil
        }
        func row(_ label: String, key: String, raw: String, value: Double, suffix: String = "", id: String,
                 write: @escaping (String) -> Void) -> InspectorRow {
            let field = GeometryField(GeometryEdit.format(value))
            field.identifier = NSUserInterfaceItemIdentifier(id)
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 58).isActive = true
            field.validate = { Self.plainNumber($0) == nil && !$0.isEmpty ? "“\($0)” is not a number" : nil }
            field.onInvalid = { [weak self] problem in self?.toast.show(problem, error: true) }
            field.onCommit = { text in if Self.plainNumber(text) != nil { write(text) } }
            field.onStep = { delta in write(GeometryEdit.format(value + delta)) }
            var views: [NSView] = [EditorStyle.hstack([field, EditorStyle.label("px", size: 11, color: .tertiaryLabelColor),
                                                      EditorStyle.spacer()], spacing: 4)]
            // Who else moves with a shared value.
            if let v = wholeVariable(raw) {
                let others = layersUsing(variable: v, in: skin).filter { n in !names.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }
                if !others.isEmpty {
                    let list = others.prefix(3).map { displayName(ofSection: $0) }.joined(separator: ", ")
                        + (others.count > 3 ? " and \(others.count - 3) more" : "")
                    let caption = cardNote("Also moves \(list).")
                    caption.identifier = NSUserInterfaceItemIdentifier("\(id)/also")
                    views.append(caption)
                }
            }
            let stack = EditorStyle.vstack(views, spacing: 3)
            let tip = wholeVariable(raw).map { showsDetails ? "#\($0)#" : "The shared size \(Self.sharedValueName($0))" } ?? label
            return InspectorRow(label: EditorStyle.rowLabel(label, key: showsDetails ? key : nil, tooltip: tip), control: stack)
        }
        /// Writes `key` for the group: the shared value when it is one, else every member (their look when they share it).
        func writer(_ key: String, raw: String, suffix: String = "") -> (String) -> Void {
            { [weak self] typed in
                guard let self, let skin = self.skin else { return }
                if let v = self.wholeVariable(raw.hasSuffix(suffix) && !suffix.isEmpty ? String(raw.dropLast(suffix.count)) : raw) {
                    // The shared size, where Apply to says (this widget alone by default), never straight into a file
                    // other widgets share.
                    self.writeLinkedValue(v, value: typed)
                    return
                }
                let list = key == "X" ? Array(names.dropFirst()) : names
                let found = self.scopedWrites(key, value: typed + suffix, sections: list)
                self.writeKeysPlainly(found.writes, name: "Change \(key == "X" ? "Gap" : key == "W" ? "Width" : "Height") of \(Self.titleCase(self.countedLayers(names, in: skin)))",
                               message: "Changed the \(names.count) \(Self.pluralKind(LayerNaming.kindNoun(members[0]), count: names.count))"
                                   + self.sharedNote(found.shared))
            }
        }
        if let w = common("W", members[...]) {
            items.append(row("Bar width", key: "W", raw: w, value: members[0].frame.width, id: "spacing-width", write: writer("W", raw: w)))
        }
        // The gap: members after the first placed "n px after the previous" (nR).
        if members.count > 1, let x = common("X", members.dropFirst()), x.hasSuffix("R") {
            let offset = String(x.dropLast())
            let resolved = OptionValue.number(skin.resolve(offset, in: nil, sectionVariables: false)) ?? 0
            items.append(row("Gap", key: "X", raw: offset, value: resolved, id: "spacing-gap",
                             write: writer("X", raw: x, suffix: "R")))
        }
        if let h = common("H", members[...]) {
            items.append(row("Height", key: "H", raw: h, value: members[0].frame.height, id: "spacing-height", write: writer("H", raw: h)))
        }
        // Where the run starts: the first member's X and Y; a new start moves all of them together.
        let first = members[0]
        for key in ["X", "Y"] {
            var r = geometryRow(first, key: key, raw: (key == "X" ? first.rawGeometry.x : first.rawGeometry.y) ?? "",
                                current: key == "X" ? first.anchorX : first.anchorY, skin: skin, run: names)
            r.label = EditorStyle.rowLabel("Starts at \(key)", key: showsDetails ? key : nil,
                                           tooltip: "Where the first one is, in px. A new number moves all \(names.count) together.")
            items.append(r)
        }
        guard !items.isEmpty else { return nil }
        let card = EditorCard(title: nil, views: [cardTitleRow("Spacing", accessory: nil),
                                                  cardNote("Changes the shared sizes these \(Self.pluralKind(LayerNaming.kindNoun(first), count: 2)) use."),
                                                  EditorStyle.grid(items)])
        card.identifier = NSUserInterfaceItemIdentifier("card-Spacing")
        return card
    }

    /// "Starts at" (§8.4): the whole run moves by `delta` px on `key` (X or Y), one undo step "Move 16 Bars".
    func moveRun(_ names: [String], key: String, by delta: Double) {
        guard let skin, key == "X" || key == "Y" else { return }
        moveRun(names, dx: key == "X" ? delta : 0, dy: key == "Y" ? delta : 0,
                name: "Move \(Self.titleCase(countedLayers(names, in: skin)))")
    }

    /// Moves a run of layers together, one undo step `name`. A position all of them take from one look — theirs
    /// alone, in this widget's own file, not placed after the layer before — is changed in the look (Visualizer's
    /// bars: `[StyleBand] Y=`). Otherwise each member's own value moves, its link kept (`(#Left# + 6)`), except a
    /// member placed after the layer before it when that layer moves too (`#BarGap#R`): it follows by itself.
    func moveRun(_ names: [String], dx: Double, dy: Double, name: String) {
        commitPendingNudge()
        if deferUntilCodeIsCommitted({ [weak self] in self?.moveRun(names, dx: dx, dy: dy, name: name) }) { return }
        guard let skin, !inspectorState.isRebuilding, dx.isFinite, dy.isFinite else { return }
        let wanted = Set(names.map { $0.lowercased() })
        var edits: [Edit] = []
        for (key, delta) in [("X", dx), ("Y", dy)] where delta != 0 {
            if let look = runLook(names, key: key, skin: skin) {
                edits.append(Edit(section: look.name, key: key, value: GeometryEdit.offset(look.raw, by: delta), own: true))
                continue
            }
            for (i, m) in skin.meters.enumerated() where wanted.contains(m.name.lowercased()) {
                let raw = ((key == "X" ? m.rawGeometry.x : m.rawGeometry.y) ?? "").trimmingCharacters(in: .whitespaces)
                if raw.hasSuffix("r") || raw.hasSuffix("R"), i > 0, wanted.contains(skin.meters[i - 1].name.lowercased()) { continue }
                edits.append(Edit(section: m.name, key: key, value: GeometryEdit.offset(raw, by: delta), own: true))
            }
        }
        commitPlainly(edits, name: name, message: "Moved the \(countedLayers(names, in: skin))")
    }

    /// The look every one of `names` takes `key` from, when they are all of its users, it is defined in this widget's
    /// own files and its value is not relative to the layer before (moving it then moves each of them once).
    func runLook(_ names: [String], key: String, skin: Skin) -> (name: String, file: URL, raw: String)? {
        var look: String?
        for n in names {
            guard let s = skin.section(named: n), case .style(let l, _)? = s.fileOrigin(key) else { return nil }
            if let look, look.caseInsensitiveCompare(l) != .orderedSame { return nil }
            look = l
        }
        guard let look else { return nil }
        let users = skin.meters.filter { m in
            if case .style(let l, _)? = m.fileOrigin(key) { return l.caseInsensitiveCompare(look) == .orderedSame }
            return false
        }
        guard Set(users.map { $0.name.lowercased() }) == Set(names.map { $0.lowercased() }),
              let file = skin.sources.location(section: look, key: key)?.file, Self.isWidgetFile(file, of: skin),
              let raw = skin.document.section(named: look)?.value(forKey: key)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, !raw.hasSuffix("r"), !raw.hasSuffix("R") else { return nil }
        return (skin.document.section(named: look)?.name ?? look, file, raw)
    }

    /// Whether `file` is this widget's own (its skin file, or a file in its folder outside the shared @Resources),
    /// not one other widgets include too.
    static func isWidgetFile(_ file: URL, of skin: Skin) -> Bool {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        if path == skin.fileURL.standardizedFileURL.resolvingSymlinksInPath().path { return true }
        let folder = skin.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let resources = skin.resourcesDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(folder) && !path.hasPrefix(resources)
    }

    /// Align in widget for a group: the whole run moves together.
    func groupAlignButtons(_ names: [String]) -> NSView {
        let view = alignInWidget(title: "Align in widget")
        for case let b as NSButton in view.subviewsMatching({ $0 is NSButton }) {
            guard let raw = b.identifier?.rawValue, let mode = EditorAlign.Mode(rawValue: raw) else { continue }
            b.target = nil
            b.onAction { [weak self] _ in self?.alignTogether(names, mode: mode) }
        }
        return view
    }

    /// Moves layers together so their union is aligned in the widget, one undo step.
    func alignTogether(_ names: [String], mode: EditorAlign.Mode) {
        commitPendingNudge()
        if deferUntilCodeIsCommitted({ [weak self] in self?.alignTogether(names, mode: mode) }) { return }
        guard let skin else { return }
        let wanted = Set(names.map { $0.lowercased() })
        let frames = skin.meters.filter { wanted.contains($0.name.lowercased()) }.map(\.frame)
        guard !frames.isEmpty else { return }
        let minX = frames.map(\.x).min()!, minY = frames.map(\.y).min()!
        let union = SkinRect(x: minX, y: minY, width: frames.map(\.maxX).max()! - minX, height: frames.map(\.maxY).max()! - minY)
        guard let target = EditorAlign.frames([union], mode: mode, skin: SkinRect(x: 0, y: 0, width: skin.width, height: skin.height))?.first
        else { return }
        moveRun(names, dx: target.x - union.x, dy: target.y - union.y,
                name: "\(Self.alignTitle(mode)) \(Self.titleCase(countedLayers(names, in: skin)))")
    }

    // MARK: - Several layers

    /// Several layers (docs/editor-friendly.md §8.9): Line up and Space out, the settings their kind shares (Mixed
    /// where they differ), and the selected layers, each a click away.
    func severalPage(_ skin: Skin) {
        let names = selectedMeters.filter { skin.meter(named: $0) != nil }
        noteSelectionShown("several:" + names.joined(separator: ","))
        let counted = countedLayers(names, in: skin)
        let titles = names.map { displayName(ofSection: $0) }
        let listed = titles.count <= 3 ? (titles.count > 1 ? titles.dropLast().joined(separator: ", ") + " and " + titles.last! : titles.joined())
            : titles.prefix(2).joined(separator: ", ") + " and \(titles.count - 2) more"
        let allHidden = names.allSatisfy { skin.meter(named: $0)?.hidden == true }
        let allLocked = names.allSatisfy(isLayerLocked)
        let buttons: [NSView] = [
            stripButton(allHidden ? "Show All" : "Hide All", symbol: allHidden ? "eye" : "eye.slash", id: "strip-hide") { [weak self] in
                self?.setLayersHidden(names, hidden: !allHidden)
            },
            stripButton(allLocked ? "Unlock All" : "Lock All", symbol: allLocked ? "lock.open" : "lock", id: "strip-lock") { [weak self] in
                self?.setLayersLocked(names, locked: !allLocked)
            },
            stripMenuButton { [weak self] in
                guard let self else { return NSMenu() }
                return LayerMenu.make(for: names, in: self)
            },
        ]
        var lines: [NSView] = []
        if let cut = cutOffLine(names, in: skin) { lines.append(cut) }
        add(identityStrip(title: counted, sentence: listed, picture: stripPicture(image: layerPicture(names, in: skin), symbol: "square.on.square"),
                          crumbs: [(widgetName(skin), { [weak self] in self?.canvasSelectionChanged([]) })], buttons: buttons, lines: lines))
        // ARRANGE: Line up, Space out.
        let spaceOut = EditorStyle.label("Space out", size: 11.5, color: .secondaryLabelColor)
        let distribute: [NSView] = [(EditorAlign.Mode.distributeX, "Evenly Across", "distribute.horizontal.center"),
                                    (.distributeY, "Evenly Down", "distribute.vertical.center")].map { mode, title, symbol in
            let b = NSButton(title: title, image: EditorStyle.image(symbol, size: 11) ?? NSImage(), target: self,
                             action: #selector(alignClicked(_:)))
            b.imagePosition = .imageLeading
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            b.isEnabled = names.count >= 3
            b.toolTip = names.count >= 3 ? Self.alignTitle(mode) : "Needs 3 or more layers."
            return b
        }
        let distributeRow = EditorStyle.hstack(distribute, spacing: 4)
        distributeRow.distribution = .fillEqually
        let spaceStack = EditorStyle.vstack([spaceOut, distributeRow], spacing: 4)
        distributeRow.widthAnchor.constraint(equalTo: spaceStack.widthAnchor).isActive = true
        let arrange = EditorCard(title: nil, views: [cardTitleRow("Arrange", accessory: nil),
                                                     alignInWidget(title: "Line up", several: true), spaceStack])
        arrange.identifier = NSUserInterfaceItemIdentifier("card-Arrange")
        add(arrange)
        let kinds = Set(names.compactMap { skin.meter(named: $0).map(LayerNaming.kindNoun) })
        if kinds.count == 1, let kind = kinds.first {
            add(sharedKindCard(names, skin: skin, title: kind))
        } else {
            let note = cardNote("These layers are different kinds, so only arranging is shared.")
            note.identifier = NSUserInterfaceItemIdentifier("mixed-kinds")
            add(note)
        }
        // SELECTED: each one a click away.
        let chips: [NSView] = names.map { name in
            let b = NSButton(title: displayName(ofSection: name), image: layerPicture([name], in: skin, size: NSSize(width: 22, height: 16))
                                ?? EditorStyle.image(skin.meter(named: name).map { LayerNaming.symbol(forMeterType: $0.type) } ?? "square", size: 11) ?? NSImage(),
                             target: nil, action: nil)
            b.imagePosition = .imageLeading
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.identifier = NSUserInterfaceItemIdentifier("selected-\(name)")
            b.toolTip = "Select only \(displayName(ofSection: name))"
            b.onAction { [weak self] _ in self?.select(section: name) }
            return b
        }
        let flow = FlowView()
        flow.spacing = 6
        flow.rowSpacing = 6
        for c in chips { flow.addSubview(c) }
        let selected = EditorCard(title: nil, views: [cardTitleRow("Selected", accessory: nil), flow])
        selected.identifier = NSUserInterfaceItemIdentifier("card-Selected")
        add(selected)
    }

    /// The settings layers of one kind share (§8.9): the kind's essential colors, choices and numbers; a value that
    /// differs between them shows "Mixed"; a change is written for all of them, one undo step.
    func sharedKindCard(_ names: [String], skin: Skin, title: String) -> NSView {
        guard let first = names.first.flatMap({ skin.meter(named: $0) }) else { return NSView() }
        let groups = EditorSchema.meterGroups(first.type)
        let own = groups.first { !["Shows", "Box Behind It", "When Clicked", "Layer"].contains($0.title) }
        let rowsBy = Dictionary(uniqueKeysWithValues: names.map { ($0, rows(of: $0, kind: .meter)) })
        var items: [InspectorRow] = []
        for p in own?.properties ?? [] where p.level == .essential {
            switch p.kind {
            case .color, .font, .number, .choice, .bool: break
            default: continue
            }
            if p.key == "FontEffectColor" || p.key == "Flip" { continue }
            let values = names.map { n -> String in
                let r = rowsBy[n].flatMap { row(for: p, in: $0) }
                return (r?.resolved ?? p.defaultValue).trimmingCharacters(in: .whitespaces)
            }
            let mixed = Set(values.map { EditorSchema.canonical($0, kind: p.kind) }).count > 1
            if let control = severalControl(p, names: names, value: values.first ?? "", mixed: mixed, skin: skin) {
                let label = EditorStyle.rowLabel(p.key == "FontWeight" ? "Weight" : p.key == "StringStyle" ? "Style" : p.label,
                                                 key: showsDetails ? p.key : nil, tooltip: mixed ? "Mixed: the layers differ" : p.help)
                items.append(InspectorRow(label: label, control: control))
            }
        }
        var views: [NSView] = [cardTitleRow(title, accessory: EditorStyle.label("Changes apply to all \(names.count).", size: 10.5,
                                                                              color: .tertiaryLabelColor))]
        if !items.isEmpty { views.append(EditorStyle.grid(items)) }
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card-Shared")
        return card
    }

    /// One control for a setting of several layers.
    func severalControl(_ p: EditorSchema.Property, names: [String], value: String, mixed: Bool, skin: Skin) -> NSView? {
        let label = p.label
        let write: (String) -> Void = { [weak self] v in self?.writeSeveral(p.key, value: v, sections: names, label: label) }
        switch p.kind {
        case .color:
            let swatch = SwatchButton()
            swatch.color = mixed ? nil : OptionValue.color(value)
            swatch.identifier = NSUserInterfaceItemIdentifier(p.key)
            swatch.toolTip = mixed ? "Mixed — pick a color for all of them" : "Pick a color for all of them"
            swatch.target = ShapeColorPicker.shared
            swatch.action = #selector(ShapeColorPicker.swatchClicked(_:))
            swatch.removeConstraints(swatch.constraints)
            swatch.widthAnchor.constraint(equalToConstant: 26).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
            ShapeColorPicker.shared.register(swatch, identity: "several/\(names.joined(separator: ","))/\(p.key)", controller: self) {
                [weak self] rgba, finished in
                self?.previewSeveralColor(p.key, rgba: rgba, like: value, sections: names, label: label, finished: finished)
            }
            let caption = EditorStyle.label(mixed ? "Mixed" : "", size: 11, color: .secondaryLabelColor)
            return EditorStyle.hstack([SwatchRim(swatch), caption, EditorStyle.spacer()], spacing: 6)
        case .font:
            let popup = fontPopup(key: p.key, section: names[0], raw: value, current: mixed ? "" : value, variable: nil)
            if mixed, let menu = popup.menu {
                let item = NSMenuItem(title: "Mixed", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.insertItem(item, at: 0)
                popup.select(item)
            }
            popup.onAction { c in
                guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
                write(v)
            }
            return popup
        case .number(let lo, let hi, let step, let unit):
            let control = NumberControl(value: mixed ? "" : value, placeholder: mixed ? "Mixed" : p.placeholder, min: lo, max: hi,
                                        step: step, unit: unit, fallback: OptionValue.number(p.defaultValue) ?? 0)
            control.identifier = NSUserInterfaceItemIdentifier(p.key)
            control.field.identifier = NSUserInterfaceItemIdentifier("several/\(p.key)")
            control.onCommit = { v in if !v.isEmpty { write(v) } }
            control.onStep = { v, finished in if finished { write(v) } }
            return control
        case .choice(let choices, _):
            let popup = CompactPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier(p.key)
            let menu = NSMenu()
            menu.autoenablesItems = false
            if mixed {
                let item = NSMenuItem(title: "Mixed", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            for c in choices {
                let item = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
                item.representedObject = c.value
                menu.addItem(item)
            }
            popup.menu = menu
            if !mixed, let match = EditorSchema.choice(for: value.isEmpty ? p.defaultValue : value, in: choices),
               let item = menu.items.first(where: { ($0.representedObject as? String) == match.value }) {
                popup.select(item)
            } else {
                popup.selectItem(at: 0)
            }
            popup.onAction { c in
                guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
                write(v)
            }
            return popup
        case .bool(let title):
            let row = CheckboxRow(title: title, width: inspectorControlWidth)
            row.box.allowsMixedState = mixed
            row.box.state = mixed ? .mixed : ((OptionValue.number(value) ?? 0) != 0 ? .on : .off)
            row.box.identifier = NSUserInterfaceItemIdentifier(p.key)
            row.box.onAction { b in write((b as? NSButton)?.state == .off ? "0" : "1") }
            return row
        default:
            return nil
        }
    }

    /// Writes one setting for several layers (where each is written: `ScopeResolver`), one undo step "Change Font Size
    /// of 3 Texts".
    func writeSeveral(_ key: String, value: String, sections: [String], label: String) {
        if deferUntilCodeIsCommitted({ [weak self] in self?.writeSeveral(key, value: value, sections: sections, label: label) }) { return }
        guard let skin, !inspectorState.isRebuilding else { return }
        let found = scopedWrites(key, value: value, sections: sections)
        let what = Self.titleCase(countedLayers(sections, in: skin))
        writeKeysPlainly(found.writes, name: "Change \(Self.titleCase(label)) of \(what)",
                         message: "\(label) changed on \(countedLayers(sections, in: skin))" + sharedNote(found.shared))
    }

    /// A color picked for several layers: previewed on all, written after a pause (or when the pick ends).
    func previewSeveralColor(_ key: String, rgba: RGBA, like: String, sections: [String], label: String, finished: Bool) {
        guard let skin else { return }
        let text = ColorText.format(rgba, like: like.isEmpty ? nil : like)
        for s in sections { skin.preview(section: s, [key: text]) }
        canvas.needsDisplay = true
        let state = pageState
        state.multiColor = (sections, key, text, label)
        state.multiColorTimer?.invalidate()
        let commit = { [weak self] in
            guard let self, let pending = self.pageState.multiColor else { return }
            self.pageState.multiColor = nil
            self.pageState.multiColorTimer?.invalidate()
            self.skin?.endPreview()
            self.writeSeveral(pending.key, value: pending.value, sections: pending.sections, label: pending.name)
        }
        if finished {
            commit()
        } else {
            let timer = Timer(timeInterval: 0.6, repeats: false) { _ in commit() }
            RunLoop.main.add(timer, forMode: .default)
            state.multiColorTimer = timer
        }
    }
}

// MARK: - The token field

/// The Text field of a text that shows live data (docs/editor-friendly.md §8.2): its words, with each `%1`, `%2`… as
/// a blue tag naming the live data. Clicking a tag opens its menu; editing ends with Return or leaving the field, and
/// writes the text with the tags back as `%N`.
///
/// Typing is undone in the field while it is being edited, from an undo stack of its own that is emptied when the
/// editing ends: the window's stack holds file changes only (one named step each), so ⌘Z never lands on a "Typing"
/// step of a field that is gone.
final class DataTokenField: NSView, NSTextViewDelegate {
    let textView = NSTextView()
    let names: [Int: String]
    var onCommit: ((String) -> Void)?
    var tokenMenu: ((Int) -> NSMenu)?
    /// The text as written in the file (what an edit is compared with).
    private(set) var original: String
    /// The typing of the current editing (see the type's comment).
    let typingUndoManager = UndoManager()

    init(text: String, names: [Int: String]) {
        self.names = names
        original = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12.5)
        textView.textContainerInset = NSSize(width: 3, height: 4)
        textView.textContainer?.lineFragmentPadding = 2
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.allowsUndo = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.setAccessibilityLabel("Text")
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        load(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return NSSize(width: NSView.noIntrinsicMetric, height: 24) }
        manager.ensureLayout(for: container)
        let h = manager.usedRect(for: container).height + 2 * textView.textContainerInset.height
        return NSSize(width: NSView.noIntrinsicMetric, height: max(24, ceil(h)))
    }

    private var laidOutHeight: CGFloat = 0

    override func layout() {
        super.layout()
        // The text wraps to the width it gets: its height follows (only when it changed, so layout settles).
        let height = intrinsicContentSize.height
        if height != laidOutHeight {
            laidOutHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    func textDidChange(_ notification: Notification) { invalidateIntrinsicContentSize() }

    /// The text with each `%N` shown as a tag.
    func load(_ text: String) {
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.labelColor]
        var i = text.startIndex
        var plain = ""
        func flush() {
            if !plain.isEmpty { result.append(NSAttributedString(string: plain, attributes: attributes)) }
            plain = ""
        }
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "%", next < text.endIndex, let digit = text[next].wholeNumberValue, digit > 0 {
                flush()
                let attachment = NSTextAttachment()
                attachment.attachmentCell = DataTokenCell(index: digit, title: names[digit] ?? "Live data \(digit)")
                result.append(NSAttributedString(attachment: attachment))
                i = text.index(after: next)
                continue
            }
            plain.append(c)
            i = next
        }
        flush()
        textView.textStorage?.setAttributedString(result)
        textView.typingAttributes = attributes
        invalidateIntrinsicContentSize()
    }

    /// The text as written: tags back to `%N`.
    var stringValue: String {
        guard let storage = textView.textStorage else { return "" }
        var out = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            if let a = attrs[.attachment] as? NSTextAttachment, let cell = a.attachmentCell as? DataTokenCell {
                out += String(repeating: "%\(cell.index)", count: range.length)
            } else {
                out += (storage.string as NSString).substring(with: range)
            }
        }
        return out
    }

    /// The tags in order (self-tests).
    var tokens: [Int] {
        var result: [Int] = []
        textView.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)) { v, _, _ in
            if let cell = (v as? NSTextAttachment)?.attachmentCell as? DataTokenCell { result.append(cell.index) }
        }
        return result
    }

    func commit() {
        typingUndoManager.removeAllActions()
        let value = stringValue
        guard value != original else { return }
        original = value
        onCommit?(value)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndoManager }

    /// Takes a tag out and writes the text.
    func removeToken(_ n: Int) {
        load(stringValue.replacingOccurrences(of: "%\(n)", with: "").replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces))
        commit()
    }

    /// Sets the text as if typed and committed (self-tests).
    func type(_ value: String) {
        load(value)
        commit()
    }

    func textDidEndEditing(_ notification: Notification) { commit() }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            load(original)
            typingUndoManager.removeAllActions()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            window?.selectNextKeyView(nil)
            return true
        }
        return false
    }

    func textView(_ textView: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let token = cell as? DataTokenCell, let menu = tokenMenu?(token.index) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: cellFrame.minX, y: cellFrame.maxY + 2), in: textView)
    }
}

/// A blue capsule naming live data inside the token field.
final class DataTokenCell: NSTextAttachmentCell {
    let index: Int
    let name: String

    init(index: Int, title: String) {
        self.index = index
        name = title
        super.init(textCell: title)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.controlAccentColor]
    }

    override func cellSize() -> NSSize {
        let size = (name as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(min(size.width, 150)) + 14, height: 17)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 1, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()
        let text = NSAttributedString(string: name, attributes: attributes)
        let size = text.size()
        let origin = NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2)
        text.draw(with: NSRect(origin: origin, size: NSSize(width: rect.width - 12, height: size.height)),
                  options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    override func wantsToTrackMouse() -> Bool { true }
}

/// A thin rim around a swatch, so a dark color shows on a dark card and a light one on a light card.
final class SwatchRim: NSView {
    init(_ swatch: SwatchButton) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(swatch)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor),
            swatch.trailingAnchor.constraint(equalTo: trailingAnchor),
            swatch.topAnchor.constraint(equalTo: topAnchor),
            swatch.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // The swatch paints inside a 1 px inset with 7 px corners: the rim lies just around it.
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
    }
}
