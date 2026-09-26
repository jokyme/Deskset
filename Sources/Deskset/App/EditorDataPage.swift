import AppKit
import DesksetCore

// The page of a live data item (docs/editor-friendly.md §8.8): selected in Live Data or reached with "Go to Live
// Data ›". The identity strip names it and says what it measures; RIGHT NOW shows its value and the last 30 seconds;
// USED BY lists the layers that show it (hover outlines, click selects); SETTINGS holds the type's essentials and,
// behind "More Live Data Options", the rest — "When the value…" rules read as sentences.

extension InspectorWindowController {
    /// Options of the "When the value…" rules (shown as sentences, not as rows).
    static let ruleKeys: Set<String> = ["ifcondition", "iftrueaction", "iffalseaction", "ifconditionmode", "ifabovevalue",
                                        "ifaboveaction", "ifbelowvalue", "ifbelowaction", "ifequalvalue", "ifequalaction",
                                        "ifmatch", "ifmatchaction", "ifnotmatchaction", "ifmatchmode"]

    func dataPage(_ m: Measure, skin: Skin) {
        noteSelectionShown(m.name)
        let type = EditorSchema.measureType(type: m.type, plugin: m.rawOption("Plugin"))?.name ?? ""
        // Breadcrumb: the widget, the data it listens to, the run it is part of.
        var crumbs: [(title: String, action: () -> Void)] = [(widgetName(skin), { [weak self] in self?.canvasSelectionChanged([]) })]
        if let parentName = m.rawOption("Parent"), let parent = skin.measure(named: parentName) {
            crumbs.append((dataName(parent, in: skin), { [weak self] in self?.select(section: parent.name) }))
        }
        if let run = dataSeries(containing: m.name, in: skin) {
            let names = run.members.compactMap { skin.measure(named: $0) }.map { dataName($0, in: skin) }
            let title = "\(run.members.count) \(Self.lowerFirst(seriesTitle(names)))"
            let first = run.members[0]
            crumbs.append((title, { [weak self] in self?.select(section: first) }))
        }
        let symbol = EditorStyle.describe(m).symbol
        let more = stripMenuButton { [weak self] in
            guard let self else { return NSMenu() }
            return LayerMenu.makeData(for: [m.name], in: self)
        }
        var lines: [NSView] = []
        if let details = detailsLine(section: m.name, looks: [], skin: skin) { lines.append(details) }
        if let t = EditorSchema.measureType(type: m.type, plugin: m.rawOption("Plugin")), !t.supportedOnMac {
            lines.append(EditorStyle.issue("This live data doesn't work on a Mac, so it reads 0.", width: EditorStyle.inspectorWidth - 40))
        }
        add(identityStrip(title: dataName(m, in: skin), sentence: dataSentence(m, type: type, skin: skin),
                          picture: stripPicture(image: nil, symbol: symbol), crumbs: crumbs, buttons: [more], lines: lines))
        add(rightNowCard(m, type: type, skin: skin))
        add(usedByCard(m, skin: skin))
        let groups = EditorSchema.measureGroups(m.type, plugin: m.rawOption("Plugin"))
        if let settings = groups.first { add(settingsCard(m, type: type, group: settings, groups: groups, skin: skin)) }
        if showsDetails { add(unshownLinesCard(section: m.name, groups: groups, meter: nil)) }
    }

    // Its ⋯ menu is the Live Data row's (`LayerMenu.makeData`: Show in a New Text Layer · Duplicate · Delete · Show in
    // Code), and its commands are the sidebar's (`duplicateData`, `deleteData`, `showInNewTextLayer`).

    /// One sentence about what the data is ("How loud one slice of the sound is, from 0 to 100%.").
    func dataSentence(_ m: Measure, type: String, skin: Skin) -> String {
        switch type {
        case "AudioLevel":
            if m.rawOption("Parent") == nil || m.rawOption("Parent")?.isEmpty == true {
                let bands = Int(m.rawOption("Bands") ?? "") ?? 0
                let port = (m.rawOption("Port") ?? "Output").lowercased() == "input" ? "What the microphone hears" : "What your Mac plays"
                return bands > 0 ? "\(port), split into \(bands) bands." : "\(port)."
            }
            switch (m.rawOption("Type") ?? "RMS").lowercased() {
            case "band": return "How loud one slice of the sound is, from 0 to 100%."
            case "rms": return "How loud the sound is, from 0 to 100%."
            case "peak": return "The loudest moments of the sound, from 0 to 100%."
            case "bandfreq": return "The frequency of one slice of the sound, in Hz."
            case "devicename": return "The name of the device the sound plays on."
            default: return "A reading of the sound."
            }
        case "CPU": return "How busy the processor is, from 0 to 100%."
        case "Memory", "PhysicalMemory": return "How much memory apps are using."
        case "SwapMemory": return "Memory moved to disk."
        case "NetIn": return "How fast data comes in, per second."
        case "NetOut": return "How fast data goes out, per second."
        case "NetTotal": return "How fast data comes in and goes out, per second."
        case "FreeDiskSpace": return "Space on a disk."
        case "Time": return "The current time or date."
        case "Uptime": return "How long your Mac has been on."
        case "Calc":
            let refs = skin.measures.filter { other in
                other !== m && (m.rawOption("Formula") ?? "").range(of: "\\b\(NSRegularExpression.escapedPattern(for: other.name))\\b",
                                                                  options: [.regularExpression, .caseInsensitive]) != nil
            }
            if let first = refs.first { return "Calculated from \(Self.lowerFirst(dataName(first, in: skin)))." }
            return "Math on other live data."
        case "Loop": return "A number that counts up."
        case "String": return "Fixed text."
        case "WebParser": return "Text read from a web page."
        case "PowerPlugin": return "Your battery's charge and status."
        default:
            return EditorSchema.measureType(type: m.type, plugin: m.rawOption("Plugin")).map { "\($0.title)." } ?? "Live data."
        }
    }

    // MARK: Right now

    /// RIGHT NOW: the value, the last 30 seconds, and why it may be still.
    func rightNowCard(_ m: Measure, type: String, skin: Skin) -> NSView {
        let value = EditorStyle.label(formattedValue(m, skin: skin), size: 24, weight: .light)
        value.font = .monospacedDigitSystemFont(ofSize: 24, weight: .light)
        value.identifier = NSUserInterfaceItemIdentifier("right-now-value")
        value.lineBreakMode = .byTruncatingTail
        liveValueLabel = value
        let spark = SparklineView()
        spark.identifier = NSUserInterfaceItemIdentifier("sparkline")
        spark.values = pageState.history[m.name.lowercased()] ?? []
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.heightAnchor.constraint(equalToConstant: 22).isActive = true
        spark.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let caption = EditorStyle.label("last 30 seconds", size: 10.5, color: .tertiaryLabelColor)
        let history = EditorStyle.vstack([spark, caption], spacing: 1)
        // Beside a value of several lines, the sparkline and its caption keep their height (centred): hugging them as
        // weakly as the row pulls it to its own (250), the pair could be any height in between (ambiguous).
        history.setHuggingPriority(.defaultHigh, for: .vertical)
        let top = EditorStyle.hstack([value, EditorStyle.spacer(), history], spacing: 8)
        let status = EditorStyle.label("", size: 11.5, color: .secondaryLabelColor)
        status.identifier = NSUserInterfaceItemIdentifier("right-now-status")
        liveStringLabel = status
        let card = EditorCard(title: nil, views: [cardTitleRow("Right Now", accessory: nil), top, status])
        card.identifier = NSUserInterfaceItemIdentifier("card-Right Now")
        dataSparkline = spark
        updateLiveCard()
        return card
    }

    /// The sparkline of the page (weakly held by the state of the page).
    var dataSparkline: SparklineView? {
        get { objc_getAssociatedObject(self, &sparklineKey) as? SparklineView }
        set { objc_setAssociatedObject(self, &sparklineKey, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }

    /// Follows the live value of the selected data (every live tick): the value, the sparkline, the status line.
    func updateLiveCard() {
        guard let skin, let name = selectedSection, let m = skin.measure(named: name) else { return }
        // History: one reading per tick (0.5 s), 30 seconds.
        var h = pageState.history[m.name.lowercased()] ?? []
        let range = m.maxValue - m.minValue
        h.append(range > 0 ? (m.value - m.minValue) / range : 0)
        if h.count > 60 { h.removeFirst(h.count - 60) }
        pageState.history[m.name.lowercased()] = h
        guard liveValueLabel?.window != nil || liveValueLabel != nil else { return }
        liveValueLabel?.stringValue = formattedValue(m, skin: skin)
        dataSparkline?.values = h
        let type = EditorSchema.measureType(type: m.type, plugin: m.rawOption("Plugin"))?.name ?? ""
        var status = ""
        if type == "AudioLevel", m.value == 0, (m.rawOption("Type") ?? "RMS").lowercased() != "devicename" {
            status = "No sound is playing."
        } else if m.disabled {
            status = "It's turned off, so it reads 0."
        } else if m.paused {
            status = "It's paused, so it keeps its value."
        }
        liveStringLabel?.stringValue = status
        liveStringLabel?.isHidden = status.isEmpty
    }

    // MARK: Used by

    /// Who uses `m`, as the Live Data tab says it (`LayerNaming`): the layers that show it, place themselves by it or
    /// act on it, the live data built on it, and whether the widget's actions name it or it runs actions of its own.
    func users(of m: Measure, in skin: Skin) -> DataUsers {
        (sidebar.catalog ?? LayerNaming.catalog(of: skin)).users(ofData: m.name)
    }

    func usedByCard(_ m: Measure, skin: Skin) -> NSView {
        let users = users(of: m, in: skin)
        let (layers, data) = (users.layers, users.data)
        canvas.relatedNames = layers
        var views: [NSView] = [cardTitleRow("Used By", accessory: nil)]
        if users.isEmpty {
            let note = cardNote("Not used by any layer.")
            note.identifier = NSUserInterfaceItemIdentifier("unused")
            views.append(note)
            let show = NSButton(title: "Show It in a New Text Layer", target: nil, action: nil)
            show.bezelStyle = .rounded
            show.controlSize = .small
            show.identifier = NSUserInterfaceItemIdentifier("show-in-text")
            show.onAction { [weak self] _ in self?.showInNewTextLayer(m.name) }
            // Defined in a file other widgets read: unused here isn't unused there, so it is never offered for deleting.
            if let shared = sharedDeletionNote([m.name]) {
                let note = cardNote(shared)
                note.identifier = NSUserInterfaceItemIdentifier("shared-data")
                views.append(EditorStyle.vstack([show, note], spacing: 6))
            } else {
                let delete = NSButton(title: "Delete This Live Data", target: nil, action: nil)
                delete.bezelStyle = .rounded
                delete.controlSize = .small
                delete.identifier = NSUserInterfaceItemIdentifier("delete-data")
                delete.onAction { [weak self] _ in self?.deleteData([m.name]) }
                views.append(EditorStyle.vstack([show, delete], spacing: 6))
            }
        } else if layers.isEmpty && data.isEmpty {
            // Nothing shows it, but it isn't idle: the Live Data tab says the same.
            let note = cardNote(users.widget ? "Used by the widget's own actions." : "Runs actions when it updates.")
            note.identifier = NSUserInterfaceItemIdentifier("acts")
            views.append(note)
        }
        for name in layers {
            let button = HoverButton(title: displayName(ofSection: name),
                                     image: layerPicture([name], in: skin, size: NSSize(width: 24, height: 18))
                                        ?? EditorStyle.image(skin.meter(named: name).map { LayerNaming.symbol(forMeterType: $0.type) } ?? "square", size: 12)
                                        ?? NSImage(),
                                     target: nil, action: nil)
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .controlAccentColor
            button.identifier = NSUserInterfaceItemIdentifier("used-by-\(name)")
            button.toolTip = "Select \(displayName(ofSection: name))" + (showsDetails ? " (\(name))" : "")
            button.onHover = { [weak self] inside in
                self?.canvas.hoverHighlight = inside ? [name] : []
                self?.canvas.needsDisplay = true
            }
            button.onAction { [weak self] _ in
                // The veil the pointer put over the canvas goes with the page (as the look badge's does).
                self?.canvas.hoverHighlight = []
                self?.select(section: name)
            }
            views.append(EditorStyle.hstack([button, EditorStyle.spacer()], spacing: 0))
        }
        // Live data that reads this (children of a sound, a network…): one line; calculations from it: each a link.
        let children = data.filter { skin.measure(named: $0)?.rawOption("Parent")?.caseInsensitiveCompare(m.name) == .orderedSame }
        if !children.isEmpty {
            let note = cardNote("\(children.count) live data item\(children.count == 1 ? "" : "s") read\(children.count == 1 ? "s" : "") from it.")
            note.identifier = NSUserInterfaceItemIdentifier("children")
            views.append(note)
        }
        for name in data where !children.contains(name) {
            guard let other = skin.measure(named: name) else { continue }
            let link = linkLike(dataName(other, in: skin), id: "used-by-\(name)") { [weak self] in self?.select(section: name) }
            link.image = EditorStyle.image(EditorStyle.describe(other).symbol, size: 11)
            link.imagePosition = .imageLeading
            views.append(EditorStyle.hstack([link, EditorStyle.spacer()], spacing: 0))
        }
        let card = EditorCard(title: nil, views: views)
        card.identifier = NSUserInterfaceItemIdentifier("card-Used By")
        return card
    }

    // MARK: Settings

    /// SETTINGS: the type's essentials (with plain controls for the ones §8.8 names), then More Live Data Options
    /// with "When the value…" read as sentences.
    func settingsCard(_ m: Measure, type: String, group: EditorSchema.Group, groups: [EditorSchema.Group], skin: Skin) -> NSView {
        var o = CardOptions(section: m.name)
        o.title = "Settings"
        o.skip = Self.ruleKeys
        switch type {
        case "AudioLevel":
            o.custom["bandidx"] = { [weak self] ctx in self?.bandRow(ctx, m: m, skin: skin) }
            o.custom["parent"] = { [weak self] ctx in self?.listensToRow(ctx, skin: skin) }
            o.custom["fftattack"] = { [weak self] ctx in self?.speedSliderRow(ctx, label: "Rises", ends: ("Instantly", "Slowly")) }
            o.custom["fftdecay"] = { [weak self] ctx in self?.speedSliderRow(ctx, label: "Falls", ends: ("Quickly", "Slowly")) }
            if (m.rawOption("Parent") ?? "").isEmpty {
                let bands = Int(m.rawOption("Bands") ?? "") ?? 0
                let low = OptionValue.number(m.rawOption("FreqMin") ?? "20") ?? 20, high = OptionValue.number(m.rawOption("FreqMax") ?? "20000") ?? 20000
                if bands > 0 { o.note = "\(bands) bands from \(Self.hertz(low)) to \(Self.hertz(high))" }
            }
        case "Memory", "PhysicalMemory", "SwapMemory":
            o.custom["total"] = { [weak self] ctx in self?.amountRow(ctx, choices: ["Used", "Free", "Total"]) }
        case "FreeDiskSpace":
            o.custom["total"] = { [weak self] ctx in self?.amountRow(ctx, choices: ["Free", "Used", "Total"]) }
            o.custom["drive"] = { [weak self] ctx in self?.diskRow(ctx) }
        case "NetIn", "NetOut", "NetTotal":
            o.top = [EditorStyle.grid([networkRow(m, type: type)])]
        case "Calc":
            o.custom["formula"] = { [weak self] ctx in self?.formulaRow(ctx, m: m) }
        case "Time":
            o.custom["format"] = { [weak self] ctx in self?.timeFormatRow(m, skin: skin) }
        default:
            break
        }
        o.extraMore = ruleRows(m, skin: skin)
        o.extraMoreLast = true
        return friendlyCard(group, groups: groups, rows: rows, options: o)
    }

    static func hertz(_ v: Double) -> String {
        v >= 1000 ? GeometryEdit.format((v / 100).rounded() / 10) + " kHz" : GeometryEdit.format(v) + " Hz"
    }

    /// Band [6] of 16 (1-based), "Band 1 is the deepest bass."
    func bandRow(_ ctx: PropertyContext, m: Measure, skin: Skin) -> InspectorRow? {
        guard ctx.form == .literal, ctx.variable == nil else { return nil }
        let index = Int(OptionValue.number(ctx.isSet ? ctx.resolved : "0") ?? 0)
        let parent = m.rawOption("Parent").flatMap { skin.measure(named: $0) }
        let bands = Int(parent?.rawOption("Bands") ?? "") ?? 0
        let field = GeometryField("\(index + 1)")
        field.identifier = NSUserInterfaceItemIdentifier("\(ctx.section)/BandIdx")
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let write = writer(ctx)
        field.validate = { t in
            guard let n = Int(t), n >= 1, bands == 0 || n <= bands else { return bands > 0 ? "Choose a band from 1 to \(bands)" : "Choose a band from 1" }
            return nil
        }
        field.onInvalid = { [weak self] problem in self?.toast.show(problem, error: true) }
        field.onCommit = { t in if let n = Int(t) { write(String(n - 1)) } }
        field.onStep = { d in
            let n = index + Int(d)
            if n >= 0, bands == 0 || n < bands { write(String(n)) }
        }
        var parts: [NSView] = [field]
        if bands > 0 { parts.append(EditorStyle.label("of \(bands)", size: 12, color: .secondaryLabelColor)) }
        let line = EditorStyle.hstack(parts + [EditorStyle.spacer()], spacing: 6)
        let stack = EditorStyle.vstack([line, cardNote("Band 1 is the deepest bass.")], spacing: 3)
        return InspectorRow(label: EditorStyle.rowLabel("Band", key: showsDetails ? ctx.key : nil, tooltip: "Which slice of the sound"),
                            control: stack)
    }

    /// Listens to: the parent sound, with "Sound Settings ›".
    func listensToRow(_ ctx: PropertyContext, skin: Skin) -> InspectorRow? {
        guard let parent = skin.measure(named: ctx.raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        let name = EditorStyle.label(dataName(parent, in: skin), size: 12)
        let link = linkLike("Sound Settings ›", id: "sound-settings") { [weak self] in self?.select(section: parent.name) }
        return InspectorRow(label: EditorStyle.rowLabel("Listens to", key: showsDetails ? ctx.key : nil, tooltip: "The sound it reads"),
                            control: EditorStyle.vstack([name, link], spacing: 2))
    }

    /// Rises / Falls: a slider from instantly to slowly (0–2 seconds), previewed while dragging.
    func speedSliderRow(_ ctx: PropertyContext, label: String, ends: (String, String)) -> InspectorRow? {
        guard ctx.form == .literal, ctx.variable == nil else { return nil }
        let slider = TrackingSlider(value: OptionValue.number(ctx.isSet ? ctx.resolved : ctx.property.defaultValue) ?? 300,
                                    minValue: 0, maxValue: 2000, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.identifier = NSUserInterfaceItemIdentifier(ctx.property.key)
        let preview = previewer(ctx)
        slider.onAction { c in preview(GeometryEdit.format(((c as? NSSlider)?.doubleValue ?? 0).rounded()), false) }
        slider.onTrackingEnded = { [weak slider] in preview(GeometryEdit.format((slider?.doubleValue ?? 0).rounded()), true) }
        let captions = EditorStyle.hstack([EditorStyle.label(ends.0, size: 10, color: .tertiaryLabelColor), EditorStyle.spacer(),
                                           EditorStyle.label(ends.1, size: 10, color: .tertiaryLabelColor)], spacing: 4)
        let stack = EditorStyle.vstack([slider, captions], spacing: 0)
        slider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        captions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return InspectorRow(label: EditorStyle.rowLabel(label, key: showsDetails ? ctx.key : nil, tooltip: ctx.property.help),
                            control: stack)
    }

    /// Show [Used | Free | Total] (memory) or [Free | Used | Total] (disk): Total and InvertMeasure as one control.
    func amountRow(_ ctx: PropertyContext, choices: [String]) -> InspectorRow? {
        guard let skin, ctx.form == .literal, ctx.variable == nil else { return nil }
        let section = skin.section(named: ctx.section)
        let total = OptionValue.bool(section?.option("Total") ?? "0") ?? false
        let invert = OptionValue.bool(section?.option("InvertMeasure") ?? "0") ?? false
        let selected = total ? 2 : (invert ? 1 : 0)
        let name = ctx.section
        let seg = wordedSegments(choices, symbols: [nil, nil, nil], selected: selected, id: "amount") { [weak self] i in
            guard let self, let skin = self.skin else { return }
            let t = skin.ownTarget(section: name, key: "Total"), v = skin.ownTarget(section: name, key: "InvertMeasure")
            self.writeKeysPlainly([KeyWrite(file: t.file, section: t.section, key: "Total", value: i == 2 ? "1" : "0"),
                            KeyWrite(file: v.file, section: v.section, key: "InvertMeasure", value: i == 1 ? "1" : "0")],
                           name: "Show \(choices[i])", message: "Now shows \(choices[i].lowercased())")
        }
        return InspectorRow(label: EditorStyle.rowLabel("Show", key: showsDetails ? "Total" : nil, tooltip: "What it reports"), control: seg)
    }

    /// Disk [Macintosh HD ▾]: the disks of this Mac.
    func diskRow(_ ctx: PropertyContext) -> InspectorRow? {
        guard ctx.form == .literal, ctx.variable == nil else { return nil }
        let popup = CompactPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("Drive")
        let menu = NSMenu()
        let startup = NSMenuItem(title: FileManager.default.displayName(atPath: "/"), action: nil, keyEquivalent: "")
        startup.representedObject = "/"
        menu.addItem(startup)
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for url in volumes where url.path != "/" {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path), action: nil, keyEquivalent: "")
            item.representedObject = url.path
            menu.addItem(item)
        }
        let written = ctx.isSet ? ctx.resolved.trimmingCharacters(in: .whitespaces) : ""
        let current = written.isEmpty || written.count <= 3 && written.hasSuffix(":") ? "/" : written
        if !menu.items.contains(where: { ($0.representedObject as? String) == current }) {
            let item = NSMenuItem(title: current, action: nil, keyEquivalent: "")
            item.representedObject = current
            menu.insertItem(item, at: 0)
        }
        popup.menu = menu
        if let item = menu.items.first(where: { ($0.representedObject as? String) == current }) { popup.select(item) }
        let write = writer(ctx)
        popup.onAction { c in
            guard let v = (c as? NSPopUpButton)?.selectedItem?.representedObject as? String, v != current else { return }
            write(v)
        }
        return InspectorRow(label: EditorStyle.rowLabel("Disk", key: showsDetails ? ctx.key : nil, tooltip: "Which disk"), control: popup)
    }

    /// Show [Download | Upload | Both]: the network data's kind.
    func networkRow(_ m: Measure, type: String) -> InspectorRow {
        let kinds = ["NetIn", "NetOut", "NetTotal"]
        let name = m.name
        let seg = wordedSegments(["Download", "Upload", "Both"], symbols: ["arrow.down", "arrow.up", "arrow.up.arrow.down"],
                                 selected: kinds.firstIndex(of: type) ?? 0, id: "network-kind") { [weak self] i in
            guard let self, kinds[i] != type else { return }
            self.writeProperty(section: name, key: "Measure", value: kinds[i], variable: nil, label: "Network Speed")
        }
        return InspectorRow(label: EditorStyle.rowLabel("Show", key: showsDetails ? "Measure" : nil, tooltip: "Which way the data goes"),
                            control: seg)
    }

    /// Formula: its value, "calculated", and [Edit Formula…] (the formula itself in a field). The button is on the
    /// value's line when the three fit the control column, else on a line of its own under it.
    func formulaRow(_ ctx: PropertyContext, m: Measure) -> InspectorRow {
        let value = EditorStyle.label(EditorStyle.number(m.value), size: 12.5)
        value.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        // Too long for the line (a value can grow while it is shown), "calculated" is shortened before the value: at one
        // priority either could give way, and the value had shrunk out of sight.
        value.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        let tag = EditorStyle.label("calculated", size: 11, color: .tertiaryLabelColor)
        let id = "formula/\(ctx.section.lowercased())"
        let open = inspectorState.disclosures.contains(id) || showsDetails
        let edit = NSButton(title: open ? "Done" : "Edit Formula…", target: nil, action: nil)
        edit.bezelStyle = .rounded
        edit.controlSize = .small
        edit.identifier = NSUserInterfaceItemIdentifier("edit-formula")
        edit.onAction { [weak self] _ in
            guard let self else { return }
            if open { self.inspectorState.disclosures.remove(id) } else { self.inspectorState.disclosures.insert(id) }
            self.rebuildKeepingScroll()
        }
        let line = EditorStyle.hstack([value, tag, EditorStyle.spacer(), edit], spacing: 6)
        var views: [NSView] = [line]
        if line.fittingSize.width > inspectorControlWidth {
            line.removeArrangedSubview(edit)
            edit.removeFromSuperview()
            views.append(edit)
        }
        if open {
            let field = textField(ctx, value: ctx.raw, monospaced: true)
            views.append(field)
            views.append(cardNote("Math on other values. Numbers and names of live data work here."))
        }
        inspectorState.liveUpdates.append { [weak self, weak value] in
            guard let self, let value, let m = self.skin?.measure(named: ctx.section) else { return }
            value.stringValue = EditorStyle.number(m.value)
        }
        let stack = EditorStyle.vstack(views, spacing: 4)
        for v in views { v.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        return InspectorRow(label: EditorStyle.rowLabel("Formula", key: showsDetails ? ctx.key : nil, tooltip: ctx.property.help),
                            control: stack)
    }

    // MARK: "When the value…"

    /// A rule of "When the value…": a sentence when it reads as one (above / below / equal to a number, or one
    /// comparison of the value itself), else its lines as written, never rewritten.
    struct ValueRule {
        var sentence: String?
        /// The rule's keys (for its raw rows).
        var keys: [String]
    }

    func valueRules(_ m: Measure, skin: Skin) -> [ValueRule] {
        let options = Dictionary(rows.map { ($0.key.lowercased(), $0.raw) }, uniquingKeysWith: { a, _ in a })
        func summary(_ action: String?) -> String {
            guard let action, !action.trimmingCharacters(in: .whitespaces).isEmpty else { return "does nothing" }
            let s = ActionSummary.sentence(for: action, in: skin) ?? "runs a command"
            return Self.lowerFirst(s)
        }
        var rules: [ValueRule] = []
        for (value, action, word) in [("ifabovevalue", "ifaboveaction", "above"), ("ifbelowvalue", "ifbelowaction", "below"),
                                      ("ifequalvalue", "ifequalaction", "equal to")] {
            guard let v = options[value] else { continue }
            let keys = rows.filter { [value, action].contains($0.key.lowercased()) }.map(\.key)
            if OptionValue.number(v) != nil {
                rules.append(ValueRule(sentence: "When the value is \(word) \(v.trimmingCharacters(in: .whitespaces)) → \(summary(options[action]))", keys: keys))
            } else {
                rules.append(ValueRule(sentence: nil, keys: keys))
            }
        }
        // IfCondition (numbered): one comparison of this data's own value reads as a sentence.
        let conditionKeys = rows.map(\.key).filter { $0.lowercased().hasPrefix("ifcondition") && !$0.lowercased().hasPrefix("ifconditionmode") }
        for key in conditionKeys {
            let suffix = String(key.dropFirst("IfCondition".count))
            let condition = options[key.lowercased()] ?? ""
            let thenKey = "IfTrueAction" + suffix, elseKey = "IfFalseAction" + suffix
            let keys = rows.map(\.key).filter { [key.lowercased(), thenKey.lowercased(), elseKey.lowercased()].contains($0.lowercased()) }
            let pattern = "^\\s*" + NSRegularExpression.escapedPattern(for: m.name) + "\\s*(<=|>=|<>|=|<|>)\\s*(-?[0-9.]+)\\s*$"
            if options[elseKey.lowercased()] == nil,
               let r = condition.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let text = String(condition[r])
                let op = ["<=", ">=", "<>", "=", "<", ">"].first { text.contains($0) } ?? "="
                let number = text.components(separatedBy: op).last?.trimmingCharacters(in: .whitespaces) ?? ""
                let word = ["<=": "at most", ">=": "at least", "<>": "not", "=": "", "<": "below", ">": "above"][op] ?? ""
                rules.append(ValueRule(sentence: "When the value is \(word.isEmpty ? "" : word + " ")\(number) → \(summary(options[thenKey.lowercased()]))",
                                       keys: keys))
            } else if !condition.isEmpty {
                rules.append(ValueRule(sentence: nil, keys: keys + rows.map(\.key).filter { $0.lowercased() == "ifconditionmode" }))
            }
        }
        // Text matches (IfMatch…) are always shown as written.
        let matchKeys = rows.map(\.key).filter { $0.lowercased().hasPrefix("ifmatch") || $0.lowercased().hasPrefix("ifnotmatch") }
        if !matchKeys.isEmpty { rules.append(ValueRule(sentence: nil, keys: matchKeys)) }
        return rules
    }

    /// The "When the value…" part of More Live Data Options: sentences, and the lines of what isn't one.
    func ruleRows(_ m: Measure, skin: Skin) -> [(row: InspectorRow, inUse: Bool)] {
        let rules = valueRules(m, skin: skin)
        let groups = EditorSchema.measureGroups(m.type, plugin: m.rawOption("Plugin"))
        var result: [(row: InspectorRow, inUse: Bool)] = []
        let heading = EditorStyle.label("When the value…", size: 11.5, weight: .medium, color: .secondaryLabelColor)
        result.append((InspectorRow(label: nil, control: heading, fullWidth: true), false))
        if rules.isEmpty {
            let location = skin.sources.location(section: m.name)
            let code = linkLike("Add One in Code ›", id: "rules-code") { [weak self] in self?.showInCode(location) }
            result.append((InspectorRow(label: nil, control: EditorStyle.hstack([EditorStyle.label("No rules yet.", size: 11.5, color: .tertiaryLabelColor),
                                                                                 code, EditorStyle.spacer()], spacing: 6), fullWidth: true), false))
            return result
        }
        for (i, rule) in rules.enumerated() {
            let id = "rule/\(m.name.lowercased())/\(i)"
            let asText = rule.sentence == nil || inspectorState.disclosures.contains(id) || showsDetails
            if let sentence = rule.sentence {
                let label = NSTextField(wrappingLabelWithString: sentence)
                label.font = .systemFont(ofSize: 12)
                label.isSelectable = false
                // The card's width less the toggle's, with either kind of scroll bars: at the width of overlay ones, a
                // sentence of two lines didn't leave the toggle its room beside legacy ones, and either gave way.
                label.preferredMaxLayoutWidth = inspectorControlWidth + EditorStyle.labelColumnWidth + 10 - 90
                label.identifier = NSUserInterfaceItemIdentifier("rule-\(i)")
                let toggle = linkLike(asText ? "Hide Text" : "Edit as Text", id: "rule-\(i)-text") { [weak self] in
                    guard let self else { return }
                    if asText { self.inspectorState.disclosures.remove(id) } else { self.inspectorState.disclosures.insert(id) }
                    self.rebuildKeepingScroll()
                }
                let row = EditorStyle.hstack([label, EditorStyle.spacer(), toggle], spacing: 6, alignment: .top)
                result.append((InspectorRow(label: nil, control: row, fullWidth: true), true))
            }
            guard asText else { continue }
            for key in rule.keys {
                guard let p = EditorSchema.property(key, in: groups) else { continue }
                let q = EditorSchema.numberedProperty(key, in: groups).map { EditorSchema.numbered($0.property, index: $0.index, in: groups) } ?? p
                result.append((propertyRow(q, section: m.name, row: row(for: q, in: rows), groups: groups, friendly: true),
                               rule.sentence == nil))
            }
        }
        return result
    }
}

private var sparklineKey: UInt8 = 0

/// The last 30 seconds of a value (0…1 of its range), drawn as a thin line.
final class SparklineView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 2)
        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: rect.minX, y: rect.minY))
        base.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        base.lineWidth = 0.5
        base.stroke()
        guard values.count > 1 else { return }
        let path = NSBezierPath()
        let step = rect.width / CGFloat(max(59, values.count - 1))
        let start = rect.maxX - step * CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let p = NSPoint(x: start + step * CGFloat(i), y: rect.minY + rect.height * CGFloat(min(max(v, 0), 1)))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        path.stroke()
    }
}
