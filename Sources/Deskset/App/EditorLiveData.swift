import AppKit
import DesksetCore

/// The Live Data tab of the editor's sidebar (docs/editor-friendly.md §5.3): where the numbers and words in a widget
/// come from. Data is listed in file order with children under their `Parent=` (open) and repeated data folded
/// ("16 sound bands", closed); each row says who uses it — a link that outlines and selects those layers — and shows
/// its value in plain units (levels in %, sizes in GB, speeds per second, frequencies in Hz, text in full). Data
/// nothing uses is dimmed with Delete on hover. A banner says why the widget looks still (nothing plays, Deskset may
/// not hear the Mac, the data only works on Windows). "+ Add Live Data" (and a Shows menu's "New ▸") offers the
/// catalogue of `LiveDataChoice` in plain words.
extension InspectorWindowController {
    /// Rows of the Live Data tab: data without a parent in file order, each parent with its children; runs folded.
    func dataRows() -> [Item] {
        guard let skin else { return [] }
        let measures = allItems.filter { $0.kind == .measure }
        for item in measures { item.children = [] }
        let query = sidebar.dataQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return measures.filter { matches($0, query) } }
        func parentName(_ m: Measure?) -> String {
            (m?.rawOption("Parent") ?? "").trimmingCharacters(in: .whitespaces)
        }
        /// The parent a child is listed under (one level: a parent that has a parent itself is not one).
        func parent(of item: Item) -> String? {
            let raw = parentName(skin.measure(named: item.title))
            guard !raw.isEmpty, raw.caseInsensitiveCompare(item.title) != .orderedSame,
                  let p = skin.measure(named: raw), parentName(p).isEmpty else { return nil }
            return p.name.lowercased()
        }
        var children: [String: [Item]] = [:]
        var top: [Item] = []
        for item in measures {
            if let p = parent(of: item) { children[p, default: []].append(item) } else { top.append(item) }
        }
        func folded(_ items: [Item]) -> [Item] {
            var result: [Item] = []
            var i = 0
            while i < items.count {
                if let series = sidebar.catalog?.series(containing: items[i].title), series.kind == .data,
                   series.members.first?.caseInsensitiveCompare(items[i].title) == .orderedSame,
                   i + series.members.count <= items.count,
                   zip(series.members, items[i..<(i + series.members.count)]).allSatisfy({
                       $0.caseInsensitiveCompare($1.title) == .orderedSame
                   }) {
                    result.append(dataGroupItem(series, members: Array(items[i..<(i + series.members.count)])))
                    i += series.members.count
                } else {
                    result.append(items[i])
                    i += 1
                }
            }
            return result
        }
        let rows = folded(top)
        for row in rows where row.seriesMembers == nil {
            row.children = folded(children[row.title.lowercased()] ?? [])
        }
        return rows
    }

    /// The row of a run of data: "16 sound bands" over "Band 1 … Band 16".
    func dataGroupItem(_ series: Series, members: [Item]) -> Item {
        let item = Item(title: series.members[0], kind: .measure)
        item.display = sidebar.catalog?.dataName(of: series)?.name ?? "\(members.count) live data items"
        item.symbol = members.first?.symbol
        item.seriesMembers = series.members
        item.children = members
        if let skin, let catalog = sidebar.catalog {
            item.subtitle = dataLine(for: series.members, in: skin, catalog: catalog).text
        }
        return item
    }

    // MARK: The "+ Add Live Data" menu

    /// "+ Add Live Data" (and a Shows menu's "New ▸"): the catalogue of §5.3, each item with a grey line saying what
    /// it is. Windows-only kinds appear only with Rainmeter Details on, marked and disabled. `titleOnly`: the title
    /// item alone (the rest is added when the menu is first needed, see `LiveDataMenuDelegate`).
    func liveDataMenu(title: String, titleOnly: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.image = EditorStyle.image("plus", size: 11, weight: .semibold)
        menu.addItem(head)
        guard !titleOnly else { return menu }
        for item in Self.dataSourceMenuItems(expert: showsRainmeterDetails, { [weak self] choice in self?.addDataSource(choice) }) {
            menu.addItem(item)
        }
        return menu
    }

    /// The items of the live data catalogue, in sections (On This Mac, Calculate, From the Web, Extras ▸).
    static func dataSourceMenuItems(expert: Bool = false, _ choose: @escaping (LiveDataChoice) -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func header(_ title: String) {
            if !items.isEmpty { items.append(.separator()) }
            if #available(macOS 14.0, *) {
                items.append(.sectionHeader(title: title))
            } else {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                items.append(header)
            }
        }
        func item(_ choice: LiveDataChoice) -> NSMenuItem {
            let item = ClosureMenuItem(choice.title, symbol: choice.type.symbol, enabled: choice.type.supportedOnMac) {
                choose(choice)
            }
            item.attributedTitle = LiveDataChoice.twoLines(choice.title, choice.summary)
            item.representedObject = choice.type.name
            item.identifier = NSUserInterfaceItemIdentifier(choice.title)
            item.toolTip = choice.summary
            return item
        }
        for (section, choices) in LiveDataChoice.catalogue {
            header(section)
            for entry in choices {
                switch entry {
                case .choice(let choice):
                    items.append(item(choice))
                case .submenu(let title, let summary, let symbol, let choices):
                    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    parent.attributedTitle = LiveDataChoice.twoLines(title, summary)
                    parent.identifier = NSUserInterfaceItemIdentifier(title)
                    parent.image = EditorStyle.image(symbol, size: 13)
                    let submenu = NSMenu()
                    for c in choices { submenu.addItem(item(c)) }
                    parent.submenu = submenu
                    items.append(parent)
                }
            }
        }
        // Everything else, plainly named; what cannot work on a Mac only for experts.
        let listed = Set(LiveDataChoice.catalogue.flatMap { $0.choices.flatMap(\.types) }.map { $0.lowercased() })
        let extras = EditorSchema.measureTypes.filter { t in
            !listed.contains(t.name.lowercased()) && t.name != "Memory" && (t.supportedOnMac || expert)
        }
        if !extras.isEmpty {
            items.append(.separator())
            let parent = NSMenuItem(title: "Extras (limited on a Mac)", action: nil, keyEquivalent: "")
            parent.image = EditorStyle.image("puzzlepiece.extension", size: 13)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for t in extras {
                let item = ClosureMenuItem(t.supportedOnMac ? t.title : "\(t.title) — Doesn't work on a Mac", symbol: t.symbol,
                                           enabled: t.supportedOnMac) { choose(LiveDataChoice(type: t, title: t.title)) }
                item.representedObject = t.name
                item.toolTip = expert ? (t.isPlugin ? "Plugin=\(t.name)" : "Measure=\(t.name)") : nil
                submenu.addItem(item)
            }
            parent.submenu = submenu
            items.append(parent)
        }
        return items
    }

    /// Adds live data of `type` (from a Shows menu's "New ▸" with `ctx`: used there in the same step).
    func addDataSource(_ type: EditorSchema.MeasureType, for ctx: PropertyContext? = nil) {
        addDataSource(LiveDataChoice(type: type, title: type.title), for: ctx)
    }

    /// Adds live data among the widget's others (after the last one in the widget's file, else before its first
    /// layer), as one undo step, and selects it — or, from a Shows menu's "New ▸" (`ctx`), makes that option use it,
    /// in the same undo step.
    func addDataSource(_ choice: LiveDataChoice, for ctx: PropertyContext? = nil) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.addDataSource(choice, for: ctx) }) { return }
        guard let skin else { return }
        var section = EditorComponents.measureSection(choice.type, existing: skin.sectionNames)
        for (key, value) in choice.options {
            if let i = section.options.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                section.options[i].value = value
            } else {
                section.options.append((key: key, value: value))
            }
        }
        let next = Self.dataSourceInsertionPoint(in: skin)
        var files = [skin.fileURL]
        let reference: (target: SkinEditTarget, key: String)? = ctx.map { ctx in
            let key = ctx.variable ?? ctx.key
            return (skin.editTarget(section: ctx.variable != nil ? "Variables" : ctx.section, key: key), key)
        }
        if let reference { files.append(reference.target.file) } else { pendingSelection = [section.name] }
        let done = perform("Add \(Self.titleCase(choice.title))", files: files, message: nil) {
            try skin.appendSections([section])
            if let next { _ = try skin.moveSection(section.name, before: next) }
            if let reference {
                try IniWriter.writeValue(section.name, key: reference.key, section: reference.target.section,
                                         fileURL: reference.target.file)
            }
        }
        if done { toast.show("Added \(LayerNaming.inSentence(choice.title))", actions: [undoToastAction()]) }
    }

    /// Where new live data goes: before the section that follows the widget file's last data, else before its
    /// first layer (nil: at the end of the file).
    static func dataSourceInsertionPoint(in skin: Skin) -> String? {
        let main = CodeEditorRouter.comparablePath(skin.fileURL)
        func inMain(_ name: String) -> Bool {
            skin.sources.location(section: name).map { CodeEditorRouter.comparablePath($0.file) == main } ?? false
        }
        if let last = skin.measures.last(where: { inMain($0.name) }) { return section(after: last.name, in: skin) }
        return skin.meters.first(where: { inMain($0.name) })?.name
    }

    /// A live data item, a run of data, or a parent.
    func dataCell(_ item: Item, skin: Skin) -> LayerCell {
        let id = NSUserInterfaceItemIdentifier("data")
        let cell = listCell(id, style: .data)
        let catalog = sidebar.catalog ?? LayerNaming.catalog(of: skin)
        let layout = dataRowLayout(item, skin: skin)
        cell.textField?.stringValue = layout.title
        cell.titleLines = layout.titleLines
        let line = dataLine(for: item.seriesMembers ?? [item.title], in: skin, catalog: catalog)
        cell.setSubtitle(line.text, link: line.users.isEmpty ? nil : line.attributed)
        cell.shorterLinks = line.shorter
        cell.link.target = self
        cell.link.action = #selector(dataLinkClicked(_:))
        cell.link.identifier = NSUserInterfaceItemIdentifier(line.users.joined(separator: "\n"))
        cell.linkToolTip = line.users.count > 1 ? "Select them" : "Select it"
        cell.link.onHover = { [weak self] inside in self?.setListHoverHighlight(inside ? line.layers : []) }
        cell.isHovered = false
        cell.hasToggles = false
        // Data that only works on Windows is marked where it is, not only in the banner.
        cell.warningText = "Doesn't work on a Mac, so it reads 0."
        cell.isCutOff = layout.info == .windowsOnly
        cell.isUnused = line.unused
        cell.contentAlpha = line.unused ? 0.55 : 1
        cell.deleteButton.target = self
        cell.deleteButton.action = #selector(deleteDataClicked(_:))
        cell.deleteButton.identifier = NSUserInterfaceItemIdentifier(item.title)
        // Formulas get a calculator sign (the schema's "function" symbol reads as code).
        let symbol = item.symbol == "function" ? "plus.forwardslash.minus" : (item.symbol ?? "waveform.path.ecg")
        cell.thumbnail.image = dataGlyph(symbol)
        switch layout.info {
        case .calculated(let text, let shorter)?:
            cell.setInfo(text)
            // Narrower: the source's short name, then only that it is calculated (the tooltip says from what).
            cell.shorterInfos = (shorter.map { [$0] } ?? []) + ["Calculated"]
        case .windowsOnly?: cell.setInfo("Doesn't work on a Mac")
        case .text?, nil: cell.setInfo("")
        }
        updateDataValue(cell, item: item, skin: skin)
        cell.baseToolTip = item.seriesMembers.map { "\($0.first ?? "")…\($0.last ?? "")" } ?? item.title
        cell.setAccessibilityLabel("\(layout.title), live data")
        return cell
    }

    /// The live value of a data row: text on the line under the name, a number at the right of that line, a strip
    /// of values for a run.
    func updateDataValue(_ cell: LayerCell, item: Item, skin: Skin) {
        if let members = item.seriesMembers {
            let measures = members.compactMap { skin.measure(named: $0) }
            cell.strip.values = measures.map(\.relativeValue)
            cell.strip.isHidden = false
            cell.detail.stringValue = ""
        } else {
            cell.strip.isHidden = true
            let m = skin.measure(named: item.title)
            let text = m.map { liveValueText($0, in: skin) } ?? ""
            if let m, valueIsText(m), !isWindowsOnly(m) {
                cell.detail.stringValue = ""
                let line = text.components(separatedBy: .newlines).joined(separator: " ")
                cell.setInfo(line.trimmingCharacters(in: .whitespaces).isEmpty ? "Empty right now" : line)
            } else if cell.detail.stringValue != text {
                cell.detail.stringValue = text
                cell.needsLayout = true
            }
        }
        cell.refreshAccessories()
    }

    /// What a data row shows: its name (a run's member by its short name, "Band 6"), on one line or two, and the line
    /// under the name, if any.
    struct DataRowLayout {
        enum Info: Equatable {
            /// The text the data reads (set on every live tick).
            case text
            /// What a formula is calculated from, when its name doesn't say ("Calculated from peak level"), and the
            /// same with the source's short name ("Calculated from memory + swap") for a narrow list.
            case calculated(String, shorter: String?)
            /// Data that only works on Windows.
            case windowsOnly
        }

        var title: String
        var titleLines: Int
        var info: Info?
    }

    func dataRowLayout(_ item: Item, skin: Skin) -> DataRowLayout {
        let catalog = sidebar.catalog ?? LayerNaming.catalog(of: skin)
        let inRun = (outline.parent(forItem: item) as? Item)?.seriesMembers != nil
        let title = inRun ? (catalog.data(item.title)?.short ?? item.display) : item.display
        var info: DataRowLayout.Info?
        if item.seriesMembers == nil, let m = skin.measure(named: item.title) {
            if isWindowsOnly(m) {
                info = .windowsOnly
            } else if valueIsText(m) {
                info = .text
            } else if let from = calculatedFrom(m, in: skin, catalog: catalog) {
                info = .calculated(from.full, shorter: from.short)
            }
        }
        // A name that doesn't fit takes two lines (rows are laid out before the list knows its width: one line).
        var lines = 1
        let level = max(outline.level(forItem: item), 0)
        if let width = outline.contentWidth(level: level) {
            let words = width - LayerCell.textX(.data) - LayerCell.trailing - (info == .windowsOnly ? 17 : 0)
            lines = LayerCell.lineCount(title, font: LayerCell.titleFont, width: words) > 1 ? 2 : 1
        }
        return DataRowLayout(title: title, titleLines: lines, info: info)
    }

    /// "Calculated from peak level" for a formula whose name doesn't say what it is calculated from ("Peak marker
    /// position", "Total swap"), with the source's short name when it is shorter ("Calculated from memory + swap");
    /// nil for other data, and for formulas named after their source ("Calculated from CPU usage").
    func calculatedFrom(_ m: Measure, in skin: Skin, catalog: LayerNameCatalog) -> (full: String, short: String?)? {
        guard (m.rawOption("Measure") ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "calc",
              let name = catalog.data(m.name)?.name, !name.hasPrefix("Calculated from"),
              let source = LayerNaming.formulaSource(m, in: skin), let sourceName = catalog.data(source.name) else { return nil }
        guard !name.localizedCaseInsensitiveContains(sourceName.name) else { return nil }
        let full = "Calculated from \(LayerNaming.inSentence(sourceName.name))"
        let short = "Calculated from \(LayerNaming.inSentence(sourceName.short))"
        return (full, short.count < full.count ? short : nil)
    }

    /// Whether data reads words rather than a number (a device name, a song, a web page, a date): its value takes
    /// the line under its name.
    func valueIsText(_ m: Measure) -> Bool {
        func option(_ key: String) -> String { (m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        let measureType = option("Measure")
        let type = measureType == "plugin" ? MeasureRegistry.normalizedPluginName(m.rawOption("Plugin") ?? "") : measureType
        switch type {
        case "audiolevel":
            return ["devicename", "deviceid", "devicelist", "format"].contains(option("Type"))
        case "cpu", "physicalmemory", "memory", "swapmemory", "freediskspace", "netin", "netout", "nettotal", "calc",
             "loop", "powerplugin", "process":
            return false
        case "time", "uptime", "string", "webparser", "sysinfo":
            return true
        case "nowplaying":
            return !["progress", "duration", "position", "volume", "rating", "state", "status", "shuffle", "repeat"]
                .contains(option("PlayerType"))
        case "wifistatus":
            return option("WiFiInfoType") != "quality"
        default:
            return m.rawString != nil && Double(m.stringValue.trimmingCharacters(in: .whitespaces)) == nil
        }
    }

    /// Data that cannot work on a Mac (a Windows plugin, or a Windows-only kind): it reads 0.
    func isWindowsOnly(_ m: Measure) -> Bool {
        if m is UnsupportedMeasure, (m.rawOption("Plugin") ?? "").lowercased().hasSuffix(".dll") { return true }
        return EditorSchema.measureType(type: m.rawOption("Measure") ?? m.type, plugin: m.rawOption("Plugin"))?
            .supportedOnMac == false
    }

    /// A tile with the data's symbol.
    func dataGlyph(_ symbol: String) -> NSImage? {
        let key = "\(symbol)|\(isSidebarDark)"
        if let cached = sidebar.glyphs[key] { return cached }
        let dark = isSidebarDark
        let image = LayerThumbnails.symbolTile(symbol, color: NSColor(white: dark ? 0.82 : 0.38, alpha: 1),
                                               background: NSColor(white: dark ? 0.25 : 0.87, alpha: 1),
                                               size: NSSize(width: 24, height: 24))
        sidebar.glyphs[key] = image
        return image
    }

    var isSidebarDark: Bool { outline.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Live data lines and values

    /// The second line of a data row: who uses it ("Used by 16 bars") — a link to them —, a parent's own line ("What
    /// your Mac plays"), "Used by the widget" (its own actions), "Runs actions when it updates", or "Not used by any
    /// layer".
    struct DataLine {
        var text: String
        var attributed: NSAttributedString
        /// Sections the link selects (layers, else data).
        var users: [String]
        /// Layers it outlines.
        var layers: [String]
        var unused: Bool
        /// Shorter wordings of the link for a narrow list ("Used by 2 layers").
        var shorter: [NSAttributedString] = []
    }

    func dataLine(for names: [String], in skin: Skin, catalog: LayerNameCatalog) -> DataLine {
        let own = Set(names.map { $0.lowercased() })
        var layers: [String] = [], data: [String] = []
        for name in names {
            let users = catalog.users(ofData: name)
            for l in users.layers where !layers.contains(where: { $0.caseInsensitiveCompare(l) == .orderedSame }) { layers.append(l) }
            for d in users.data where !own.contains(d.lowercased())
                && !data.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) { data.append(d) }
        }
        func plain(_ text: String, unused: Bool = false) -> DataLine {
            DataLine(text: text, attributed: NSAttributedString(string: text), users: [], layers: [], unused: unused)
        }
        // A parent: its own line (the children are its users).
        let children = data.filter { skin.measure(named: $0)?.rawOption("Parent")?.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(names[0]) == .orderedSame }
        if names.count == 1, !children.isEmpty {
            let subtitle = catalog.data(names[0])?.subtitle ?? ""
            return plain(subtitle.isEmpty ? "Used by \(children.count) live data items" : subtitle)
        }
        let targets = layers.isEmpty ? data : layers
        guard !targets.isEmpty else {
            // Nothing shows it, but the widget's actions use it, or it acts by itself (`IfTrueAction`…): deleting it
            // would change what the widget does.
            let users = names.map { catalog.users(ofData: $0) }
            if users.contains(where: \.widget) { return plain("Used by the widget") }
            if users.contains(where: \.runsActions) { return plain("Runs actions when it updates") }
            return plain("Not used by any layer", unused: true)
        }
        let titles = layers.isEmpty ? data.map { catalog.data($0)?.name ?? $0 } : layers.map { catalog.layer($0)?.title ?? $0 }
        let phrase = layers.isEmpty ? namesPhrase(titles) : layersPhrase(layers, catalog: catalog)
        func usedBy(_ phrase: String) -> NSAttributedString {
            let attributed = NSMutableAttributedString(string: "Used by ", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            attributed.append(NSAttributedString(string: phrase, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor]))
            return attributed
        }
        // In a narrow list: "“L” and 1 more", then "2 layers" (the tooltip names them all).
        var shorter: [String] = []
        if titles.count == 2, phrase != titles[0] { shorter.append("\(titles[0]) and 1 more") }
        if titles.count >= 2, phrase.contains(" and ") {
            shorter.append(layers.isEmpty ? "\(titles.count) live data items" : "\(titles.count) layers")
        }
        let usedLayers = layers.isEmpty ? data.flatMap { catalog.users(ofData: $0).layers } : layers
        return DataLine(text: "Used by " + phrase, attributed: usedBy(phrase), users: targets, layers: usedLayers,
                        unused: false, shorter: shorter.map(usedBy))
    }

    /// "16 bars" (a whole run), "Left channel bar", "“48 Hz” and “13268 Hz”", "“L” and 3 more".
    func layersPhrase(_ layers: [String], catalog: LayerNameCatalog) -> String {
        let set = Set(layers.map { $0.lowercased() })
        if let run = catalog.series.first(where: { $0.kind == .layers && Set($0.members.map { $0.lowercased() }) == set }),
           let name = catalog.name(of: run) {
            return name.title
        }
        return namesPhrase(layers.map { catalog.layer($0)?.title ?? $0 })
    }

    /// Names already in words, listed: "“L”", "“L” and “R”", "“L” and 3 more" (a list of sections, counted by kind, is
    /// `usersPhrase(_:atLeast:)`).
    func namesPhrase(_ titles: [String]) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        default: return "\(titles[0]) and \(titles.count - 1) more"
        }
    }

    /// A live value in plain units: levels in %, bytes in GB / MB, speeds per second, frequencies in Hz / kHz, text in
    /// full. Sizes count as the widget's text shows them (its AutoScale), else memory in powers of 1024 (as Activity
    /// Monitor and About This Mac do) and disks and networks in powers of 1000 (as the Finder does).
    func liveValueText(_ m: Measure, in skin: Skin) -> String {
        func option(_ key: String) -> String { (m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        let measureType = option("Measure")
        let type = measureType == "plugin" ? MeasureRegistry.normalizedPluginName(m.rawOption("Plugin") ?? "") : measureType
        func percent(_ v: Double) -> String { "\(Int((v.isFinite ? v : 0).rounded()))%" }
        if m.disabled { return "Turned off" }
        // A picture's file (an album cover in a temporary folder) is shown as what it is, never as a path.
        let text = m.stringValue.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") || text.lowercased().hasPrefix("file:") {
            let ext = (text as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "ico"].contains(ext) { return "Picture" }
            if type == "nowplaying", option("PlayerType") == "cover" || option("PlayerType") == "coverpath" { return "Picture" }
            return LayerNaming.fileName(text)
        }
        switch type {
        case "audiolevel":
            if option("Parent").isEmpty {
                let children = skin.measures.filter {
                    ($0.rawOption("Parent") ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(m.name) == .orderedSame
                }
                let levels = children.filter { ["band", "rms", "peak", "fft"].contains(($0.rawOption("Type") ?? "").lowercased()) }
                return levels.allSatisfy { $0.value == 0 } ? "Silent" : "Playing"
            }
            switch option("Type") {
            case "band", "rms", "peak", "fft": return percent(m.value * 100)
            case "bandfreq", "fftfreq": return Self.frequency(m.value)
            case "devicestatus": return m.value > 0 ? "On" : "Off"
            default: return m.stringValue
            }
        case "cpu":
            return percent(m.value)
        case "powerplugin":
            return ["", "percent"].contains(option("PowerState")) ? percent(m.value) : m.stringValue
        case "physicalmemory", "memory", "swapmemory":
            return Self.bytes(m.value, binary: Self.countsInBinary(m, in: skin, otherwise: true))
        case "freediskspace":
            return Self.bytes(m.value, binary: Self.countsInBinary(m, in: skin, otherwise: false))
        case "netin", "netout", "nettotal":
            return Self.bytes(m.value, binary: Self.countsInBinary(m, in: skin, otherwise: false))
                + (option("Cumulative") == "1" ? "" : "/s")
        case "calc":
            // A formula on sizes of memory or disks is a size too.
            let sourcePlugin = LayerNaming.formulaSource(m, in: skin).map { ($0.rawOption("Measure") ?? "").lowercased() }
            if let source = sourcePlugin, ["physicalmemory", "memory", "swapmemory", "freediskspace"].contains(source) {
                return Self.bytes(m.value, binary: Self.countsInBinary(m, in: skin, otherwise: source != "freediskspace"))
            }
            return EditorStyle.number(m.value)
        default:
            if m.rawString != nil { return m.stringValue }
            return EditorStyle.number(m.value)
        }
    }

    /// 48.2 → "48 Hz", 13268 → "13.3 kHz".
    static func frequency(_ hz: Double) -> String {
        guard hz.isFinite else { return "0 Hz" }
        if abs(hz) < 1000 { return "\(Int(hz.rounded())) Hz" }
        let k = (hz / 100).rounded() / 10
        return (k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)) + " kHz"
    }

    /// 3221225472 → "3.2 GB" (powers of 1000, as the Finder counts), or "3.0 GB" in powers of 1024 (`binary`, as
    /// Activity Monitor counts memory).
    static func bytes(_ v: Double, binary: Bool = false) -> String {
        guard v.isFinite else { return "0 B" }
        let a = abs(v), k: Double = binary ? 1024 : 1000
        for (power, unit) in [(4.0, "TB"), (3.0, "GB"), (2.0, "MB"), (1.0, "KB")] where a >= pow(k, power) {
            let x = v / pow(k, power)
            return (x >= 100 ? String(Int(x.rounded())) : String(format: "%.1f", x)) + " " + unit
        }
        return "\(Int(v.rounded())) B"
    }

    /// Whether a size counts in powers of 1024: as the text layers that show it scale it (`AutoScale=1` or `2`) when
    /// they agree, else `otherwise`.
    static func countsInBinary(_ m: Measure, in skin: Skin, otherwise: Bool) -> Bool {
        var scales: Set<Bool> = []
        for case let text as StringMeter in skin.meters where text.measureSlots.contains(where: { $0 === m }) {
            switch AutoScale.parse(text.rawOption("AutoScale") ?? "") {
            case .binary: scales.insert(true)
            case .decimal: scales.insert(false)
            case .off: break
            }
        }
        return scales.count == 1 ? scales.contains(true) : otherwise
    }

    /// Right-hand detail of a data row: its live value.
    func detailText(for item: Item) -> String {
        guard let skin, item.kind == .measure, let m = skin.measure(named: item.title) else { return "" }
        return liveValueText(m, in: skin)
    }

    // MARK: Status banner

    /// Why the Live Data looks still, if it does: Deskset may not hear the Mac's sound, nothing has played for a few
    /// seconds, or some data only works on Windows. One at a time. Keeps the silence clock.
    func liveDataBanner(now: Date = Date()) -> LiveDataBanner? {
        guard let skin else { return nil }
        let catalog = sidebar.catalog
        let permissionNotes = [AudioPermissions.microphoneNote, AudioPermissions.screenRecordingNote, AudioCaptureEngine.silenceNote]
        if let note = skin.issues.first(where: { permissionNotes.contains($0) }) {
            return .cannotHear(microphone: note == AudioPermissions.microphoneNote)
        }
        let levels = skin.measures.filter { m in
            let plugin = MeasureRegistry.normalizedPluginName(m.rawOption("Plugin") ?? "")
            guard plugin == "audiolevel", !(m.rawOption("Parent") ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                  ["band", "rms", "peak", "fft"].contains((m.rawOption("Type") ?? "").lowercased()) else { return false }
            return catalog?.users(ofData: m.name).layers.contains { skin.meter(named: $0)?.hidden == false } ?? true
        }
        let silent: Bool? = levels.isEmpty ? nil : levels.allSatisfy { $0.value == 0 }
        if sidebar.silence.saysSilent(silent, shown: sidebar.banner == .silent, now: now) { return .silent }
        let windowsOnly = skin.measures.filter(isWindowsOnly)
        guard let first = windowsOnly.first else { return nil }
        return .windowsOnly(name: windowsOnly.count == 1 ? (catalog?.data(first.name)?.name ?? first.name) : nil,
                            count: windowsOnly.count)
    }

    /// Shows the banner the Live Data tab needs (none on the other tabs; the silence clock runs anyway). A banner
    /// that comes or goes moves the list, so on a live tick (`immediate` false) it waits until the pointer is off the
    /// list, and slides in or out.
    func updateBanner(immediate: Bool = true) {
        let wanted = liveDataBanner()
        let banner = sidebarTab == .data ? wanted : nil
        let view = sidebar.bannerView
        let moves = (banner == nil) != view.isHidden
        if moves, !immediate, isPointerOverList { return }
        sidebar.banner = banner
        switch banner {
        case .silent?:
            view.show(text: "No sound is playing, so the bars are still. Play something to see them move.",
                      symbol: "speaker.slash", button: nil)
        case .cannotHear?:
            view.show(text: "Deskset can't hear your Mac's sound yet.", symbol: "speaker.badge.exclamationmark",
                      button: "Allow…")
        case .windowsOnly(let name, let count)?:
            view.show(text: name.map { "\($0) doesn't work on a Mac, so it reads 0." }
                          ?? "\(count) live data items don't work on a Mac, so they read 0.",
                      symbol: "exclamationmark.triangle", button: nil)
        case nil:
            break
        }
        guard moves else { return }
        if !immediate, window?.isVisible == true {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                view.isHidden = banner == nil
                self.listPane.layoutSubtreeIfNeeded()
            }
        } else {
            view.isHidden = banner == nil
        }
    }

    /// Whether the pointer is over the list (rows must not move under it).
    var isPointerOverList: Bool {
        guard let window, window.isVisible, !listPane.isHiddenOrHasHiddenAncestor else { return false }
        return listPane.bounds.contains(listPane.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// "Allow…": the pane of System Settings that gives Deskset the sound.
    func bannerActionClicked() {
        guard case .cannotHear(let microphone)? = sidebar.banner, app.presentsWindows else { return }
        let pane = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Row commands (Delete, the "Used by" link, the row menu)

    /// "Delete" on data nothing uses.
    @objc func deleteDataClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        deleteData([name])
    }

    /// Deletes live data (every block of it) as one undo step. A parent goes with the data under it (left alone, that
    /// data would read nothing). The toast says when layers used it: they now show nothing, until Undo.
    func deleteData(_ names: [String]) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.deleteData(names) }) { return }
        guard let skin else { return }
        let chosen = names.compactMap { skin.measure(named: $0)?.name }
        guard !chosen.isEmpty else { return }
        let children = Self.dataChildren(of: chosen, in: skin)
        let all = chosen + children
        if let shared = sharedDeletionNote(all) {
            toast.show(shared, error: true)
            return
        }
        let label = chosen.count == 1 ? displayName(ofSection: chosen[0]) : "\(chosen.count) live data items"
        let files = all.flatMap { skin.definingFiles(ofSection: $0) }
        if all.contains(where: { $0.caseInsensitiveCompare(selectedSection ?? "") == .orderedSame }) { selectedSection = nil }
        // The layers that showed, followed or acted on it, by the names they have now.
        let catalog = sidebar.catalog ?? LayerNaming.catalog(of: skin)
        var layers: [String] = []
        for name in all {
            for layer in catalog.users(ofData: name).layers
            where !layers.contains(where: { $0.caseInsensitiveCompare(layer) == .orderedSame }) { layers.append(layer) }
        }
        let firstLayer = layers.first.map(displayName(ofSection:))
        let their = chosen.count == 1 ? "Its" : "Their"
        let undoName = "Delete \(Self.titleCase(label))" + (children.isEmpty ? "" : " with \(their) \(children.count) Items")
        let done = perform(undoName, files: files, message: nil) {
            for n in all { try skin.removeSection(n) }
        }
        guard done else { return }
        var text = "Deleted \(LayerNaming.inSentence(label))"
        if !children.isEmpty { text += " and \(their.lowercased()) \(children.count) items" }
        let it = all.count == 1 ? "it" : "them"
        if layers.count == 1, let firstLayer {
            text += ". \(firstLayer) used \(it)."
        } else if layers.count > 1 {
            text += ". \(layers.count) layers used \(it)."
        }
        toast.show(text, actions: [undoToastAction()])
    }

    /// The data whose `Parent=` is one of `parents` (and not one of them), in file order.
    static func dataChildren(of parents: [String], in skin: Skin) -> [String] {
        let chosen = Set(parents.map { $0.lowercased() })
        return skin.measures.filter { m in
            let parent = (m.rawOption("Parent") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return !parent.isEmpty && chosen.contains(parent) && !chosen.contains(m.name.lowercased())
        }.map(\.name)
    }

    /// Clicking "Used by …": selects those layers (or that data).
    @objc func dataLinkClicked(_ sender: NSButton) {
        let names = (sender.identifier?.rawValue ?? "").split(separator: "\n").map(String.init)
        guard !names.isEmpty else { return }
        if names.count == 1 { select(section: names[0]) } else { canvasSelectionChanged(names) }
    }

    /// A new text layer that shows live data, below what the widget has (one undo step).
    func showInNewTextLayer(_ measure: String) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.showInNewTextLayer(measure) }) { return }
        guard let skin, skin.measure(named: measure) != nil else { return }
        let bounds = skin.contentBounds()
        var sections = EditorComponents.sections(for: "text", x: max(bounds.x, 0).rounded(),
                                                 y: (bounds.width > 0 ? bounds.maxY + 8 : 0).rounded(),
                                                 existing: skin.sectionNames, variables: skin.variableNames)
        guard let i = sections.firstIndex(where: { $0.options.contains { $0.key == "Meter" } }) else { return }
        sections[i].options.removeAll { ["Text", "MeasureName"].contains($0.key) }
        if let meter = sections[i].options.firstIndex(where: { $0.key == "Meter" }) {
            sections[i].options.insert((key: "MeasureName", value: measure), at: meter + 1)
        }
        sections[i].options.append((key: "Text", value: "%1"))
        pendingSelection = [sections[i].name]
        let label = displayName(ofSection: measure)
        let done = perform("Show \(Self.titleCase(label)) in a New Text Layer", files: [skin.fileURL], message: nil) {
            try skin.appendSections(sections)
        }
        if done { toast.show("Added a text showing \(LayerNaming.inSentence(label))", actions: [undoToastAction()]) }
    }

    /// Copies of live data, right after each (one undo step).
    func duplicateData(_ names: [String]) {
        if deferUntilEditsAreCommitted({ [weak self] in self?.duplicateData(names) }) { return }
        guard let skin else { return }
        var taken = skin.sectionNames
        let copies = names.compactMap { name in skin.duplicateSections(name, dx: 0, dy: 0, taken: &taken).map { (name, $0) } }
        guard !copies.isEmpty else { return }
        pendingSelection = copies.last.map { [$0.1.name] }
        let done = perform(names.count == 1 ? "Duplicate \(Self.titleCase(displayName(ofSection: names[0])))" : "Duplicate",
                           files: [skin.fileURL], message: nil) {
            try skin.appendSections(copies.map(\.1))
            for (original, copy) in copies {
                if let next = Self.section(after: original, in: skin) { _ = try skin.moveSection(copy.name, before: next) }
            }
        }
        if done { toast.show("Duplicated \(LayerNaming.inSentence(displayName(ofSection: names[0])))", actions: [undoToastAction()]) }
    }
}

/// The status banner of the Live Data tab.
enum LiveDataBanner: Equatable {
    /// No sound data is moving (for a few seconds).
    case silent
    /// A permission keeps Deskset from hearing the Mac's sound (or the microphone).
    case cannotHear(microphone: Bool)
    /// Some live data only works on Windows: its name when it is the only one, and how many.
    case windowsOnly(name: String?, count: Int)
}

/// When the Live Data tab says "No sound is playing": after a few seconds of silence, and until sound has played for a
/// few seconds — pauses between songs don't make the banner come and go (each time moving the list).
struct SilenceClock {
    static let silenceBeforeShowing: TimeInterval = 3
    static let soundBeforeHiding: TimeInterval = 2

    /// Since when every sound level the widget shows has read 0 (nil: not silent).
    var silentSince: Date?
    /// Since when sound has played without a pause (nil: silent).
    var soundSince: Date?
    /// Snapshots say it as after a long silence.
    var settled = false

    /// Whether to say nothing plays, given whether the levels read 0 now (`silent`; nil: the widget has no sound
    /// data) and whether it is said already.
    mutating func saysSilent(_ silent: Bool?, shown: Bool, now: Date) -> Bool {
        guard let silent else {
            silentSince = nil
            soundSince = nil
            return false
        }
        if silent {
            soundSince = nil
            if silentSince == nil { silentSince = now }
            return shown || settled || now.timeIntervalSince(silentSince ?? now) >= Self.silenceBeforeShowing
        }
        silentSince = nil
        if soundSince == nil { soundSince = now }
        return shown && now.timeIntervalSince(soundSince ?? now) < Self.soundBeforeHiding
    }
}

/// One thing "+ Add Live Data" can add: a kind of data with its options, named and described in plain words.
struct LiveDataChoice {
    var type: EditorSchema.MeasureType
    var title: String
    var summary = ""
    /// Options set on the new section (replacing the kind's defaults).
    var options: [(key: String, value: String)] = []

    /// An entry of the catalogue: one choice, or a submenu of them.
    enum Entry {
        case choice(LiveDataChoice)
        case submenu(String, String, String, [LiveDataChoice])

        var types: [String] {
            switch self {
            case .choice(let c): return [c.type.name]
            case .submenu(_, _, _, let choices): return choices.map(\.type.name)
            }
        }
    }

    /// The same choice as Core writes it (for the Shows menus' `createLiveData`).
    var schemaChoice: EditorSchema.LiveDataChoice {
        var choice = EditorSchema.LiveDataChoice(title, summary, type: type.name)
        choice.orderedOptions = options
        return choice
    }

    /// docs/editor-friendly.md §5.3 "+ Add Live Data" menu: the catalogue in Core, which every Shows menu's "New ▸"
    /// and the canvas's "Choose what this shows ▾" list too.
    static let catalogue: [(section: String, choices: [Entry])] = EditorSchema.liveDataCatalogue.map { section in
        (section.title, section.items.compactMap { item -> Entry? in
            guard item.children.isEmpty else {
                let symbol = item.children.first?.measureType?.symbol ?? "arrow.up.arrow.down.circle"
                return .submenu(item.title, item.detail, item.title == "Network speed" ? "arrow.up.arrow.down.circle" : symbol,
                                item.children.compactMap(LiveDataChoice.init))
            }
            return LiveDataChoice(item).map(Entry.choice)
        })
    }

    /// A menu item title: the name, then a grey line saying what it is.
    static func twoLines(_ title: String, _ summary: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 13)])
        guard !summary.isEmpty else { return text }
        text.append(NSAttributedString(string: "\n" + summary, attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }
}

extension LiveDataChoice {
    /// A choice of the one catalogue in Core (`EditorSchema.liveDataCatalogue`).
    init?(_ choice: EditorSchema.LiveDataChoice) {
        guard let type = choice.measureType else { return nil }
        self.init(type: type, title: choice.title, summary: choice.detail, options: choice.orderedOptions)
    }
}

/// A one-line status in the Live Data tab ("No sound is playing…"), with an optional button.
final class SidebarBannerView: NSView {
    private let icon = NSImageView()
    let label = NSTextField(wrappingLabelWithString: "")
    let button = NSButton(title: "", target: nil, action: nil)
    var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(clicked)
        let text = NSStackView(views: [label, button])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.detachesHiddenViews = true
        for v in [icon, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(text: String, symbol: String, button title: String?) {
        label.stringValue = text
        icon.image = EditorStyle.image(symbol, size: 12)
        button.title = title ?? ""
        button.isHidden = title == nil
        setAccessibilityLabel(text)
    }

    @objc private func clicked() { onAction?() }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.75)).setFill()
        path.fill()
        (dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.08)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// Builds "+ Add Live Data" again each time it opens: with View ▸ Show Rainmeter Details on, its Extras list the kinds
/// that only work on Windows.
final class LiveDataMenuDelegate: NSObject, NSMenuDelegate {
    weak var editor: InspectorWindowController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let editor else { return }
        let fresh = editor.liveDataMenu(title: menu.items.first?.title ?? "Add Live Data")
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}
