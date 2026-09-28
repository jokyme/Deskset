import AppKit
import DesksetCore

/// The live values of the Add page's data: this Mac's readings on screen, the design's sample numbers off screen (the
/// same on every Mac, for snapshots and self-tests).
final class StudioAddValues {
    let live: Bool
    private var lastNet: (NetworkCounters, TimeInterval)?
    private var speeds: (down: Double, up: Double) = (0, 0)

    init(live: Bool) {
        self.live = live
    }

    static let samples: [String: String] = [
        "cpu": "21%", "memory": "20.4 GB", "disk": "88%", "gpu": "34%", "download": "2.7 MB/s", "upload": "553 KB/s",
        "battery": "73%", "time": "10:09", "date": "", "uptime": "14 d 5 h", "temperature": "", "nowplaying": "",
    ]

    func value(_ item: StudioAddCatalog.DataItem) -> String? {
        guard live else { return Self.samples[item.id].flatMap { $0.isEmpty ? nil : $0 } }
        let system = SystemMonitor.shared
        switch item.id {
        case "cpu": return "\(Int(system.cpuUsage(processor: 0).rounded()))%"
        case "memory":
            return StudioText.bytes(Double(system.memoryStatus().physicalUsed), style: .memory)
        case "disk":
            guard let d = system.diskSpace(path: "/"), d.total > 0 else { return nil }
            return "\(Int(((d.total - d.free) / d.total * 100).rounded()))%"
        case "gpu":
            return system.sensors.value("gpu.usage").map { "\(Int($0.rounded()))%" }
        case "download", "upload":
            let now = ProcessInfo.processInfo.systemUptime
            let counters = system.networkCounters(interface: nil)
            if let (before, t) = lastNet, now - t > 0.5 {
                speeds = (Double(counters.received &- before.received) / (now - t),
                          Double(counters.sent &- before.sent) / (now - t))
                lastNet = (counters, now)
            } else if lastNet == nil {
                lastNet = (counters, now)
                return nil
            }
            let v = item.id == "download" ? speeds.down : speeds.up
            return StudioText.bytes(v, style: .file) + "/s"
        case "battery": return system.battery().map { "\(Int($0.percent.rounded()))%" }
        case "time":
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: Date())
        case "uptime":
            let v = system.uptime()
            let days = Int(v) / 86_400, hours = Int(v) % 86_400 / 3600
            return days > 0 ? "\(days) d \(hours) h" : "\(hours) h"
        default: return nil
        }
    }
}

/// The Add page in the window: a click adds after the selection (data asks how to show it first), a drag onto the
/// canvas adds where the ghost was; the widget's colors and fonts are used on the selected part.
extension StudioWindowController {
    func wireAdd() {
        let add = sidebarController.addView
        add.onEvent = { [weak self] event in self?.addEvent(event) }
        add.value = { [weak self] item in self?.sidebarState.addValues.value(item) }
        canvasController.canvas.onDropComponent = { [weak self] id, frame in self?.dropAdded(id, frame: frame) }
    }

    /// The Add page again: the widget's colors and fonts, the values.
    func refreshAddPage() {
        let add = sidebarController.addView
        if let facts = widgetPage.facts {
            var colors: [(id: String, color: RGBA, name: String)] = []
            for (i, role) in facts.colors.parts.enumerated() { colors.append(("part:\(i)", role.color, StudioWidgetPage.title(role))) }
            if let t = facts.colors.text { colors.append(("text", t.color, StudioWidgetPage.title(t))) }
            if let c = facts.colors.card { colors.append(("card", c.color, StudioWidgetPage.title(c))) }
            add.widgetColors = colors
            add.widgetFonts = facts.fonts.enumerated().map { (id: "font:\($0.offset)", face: $0.element.face) }
        } else {
            add.widgetColors = []
            add.widgetFonts = []
        }
        add.rebuild()
    }

    func addEvent(_ event: StudioAddEvent) {
        switch event {
        case .data(let id):
            chooseLook(for: id, at: nil)
        case .part(let p):
            addPart(p, at: nil)
        case .symbol(let s):
            addSymbol(s, at: nil)
        case .browse:
            browseSymbols()
        case .color(let id):
            useColor(id)
        case .font(let id):
            useFont(id)
        }
    }

    // MARK: Adding

    /// Adds data item `id` shown as `look` (at `spot`, else under the selection), after the selected part. One step
    /// "Add CPU usage". The part reads the widget's own measure when it has one that reads the same data.
    @discardableResult
    func addData(_ id: String, look: StudioAddCatalog.Look, at spot: (x: Double, y: Double)? = nil) -> Bool {
        guard let skin, let item = StudioAddCatalog.dataItem(id) else { return false }
        let p = spot ?? freeSpot()
        let sections = StudioAddCatalog.sections(data: id, look: look, x: p.x, y: p.y, existing: skin.sectionNames,
                                                 variables: skin.variableNames,
                                                 reuse: StudioAddCatalog.existingMeasure(for: id, in: skin))
        return insert(sections, title: StudioWords.data(item.title))
    }

    @discardableResult
    func addPart(_ part: StudioAddCatalog.Part, at spot: (x: Double, y: Double)? = nil) -> Bool {
        guard let skin else { return false }
        let p = spot ?? freeSpot()
        let sections = StudioAddCatalog.sections(part: part, x: p.x, y: p.y, existing: skin.sectionNames,
                                                 variables: skin.variableNames)
        return insert(sections, title: StudioAddContent.partTitle(part))
    }

    @discardableResult
    func addSymbol(_ symbol: String, at spot: (x: Double, y: Double)? = nil) -> Bool {
        guard let skin else { return false }
        let p = spot ?? freeSpot()
        let sections = StudioAddCatalog.symbolSections(symbol, x: p.x, y: p.y, existing: skin.sectionNames,
                                                       variables: skin.variableNames)
        let name = StudioSymbolIndex.name(of: symbol, chinese: StudioText.language == .chinese)
        guard insert(sections, title: name) else { return false }
        var recent = StudioAddView.recentSymbols.filter { $0 != symbol }
        recent.insert(symbol, at: 0)
        StudioAddView.recentSymbols = Array(recent.prefix(4))
        refreshAddPage()
        return true
    }

    /// The looks a data item can be shown as, as a menu ("Show CPU usage as…": Number, Bar, Ring, Graph); on screen it
    /// opens at the pointer (or where a drag ended) and a pick adds it.
    @discardableResult
    func chooseLook(for id: String, at spot: (x: Double, y: Double)?) -> NSMenu? {
        guard let item = StudioAddCatalog.dataItem(id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: StudioText.format(.addHowTo, StudioWords.data(item.title)), action: nil,
                                keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for look in item.looks {
            let title: String
            let symbol: String
            switch look {
            case .number: title = StudioText[.addNumber]; symbol = "textformat.123"
            case .bar: title = StudioText[.showsBar]; symbol = "rectangle.split.3x1"
            case .ring: title = StudioText[.showsRing]; symbol = "circle.dashed"
            case .graph: title = StudioText[.showsGraph]; symbol = "chart.xyaxis.line"
            }
            let entry = ClosureMenuItem(title) { [weak self] in self?.addData(id, look: look, at: spot) }
            entry.image = StudioPageStyle.symbol(symbol, size: 13)
            entry.representedObject = look.rawValue
            menu.addItem(entry)
        }
        sidebarState.lookMenu = menu
        guard app.presentsWindows, let window, window.isVisible else { return menu }
        let point = window.mouseLocationOutsideOfEventStream
        menu.popUp(positioning: menu.items.dropFirst().first, at: point, in: window.contentView)
        return menu
    }

    /// Browse…: every symbol of the index, in everyday words; a pick adds it.
    @discardableResult
    func browseSymbols() -> NSMenu {
        let menu = NSMenu()
        let chinese = StudioText.language == .chinese
        for e in StudioSymbolIndex.all {
            let item = ClosureMenuItem(e.name(chinese: chinese)) { [weak self] in self?.addSymbol(e.symbol) }
            item.image = StudioPageStyle.symbol(e.symbol, size: 13)
            item.toolTip = e.symbol
            menu.addItem(item)
        }
        sidebarState.lookMenu = menu
        if app.presentsWindows, let window, window.isVisible {
            menu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: window.contentView)
        }
        return menu
    }

    /// A drop on the canvas from the Add page (or a component the canvas knows): added where its ghost was; data asks
    /// how to show it first.
    func dropAdded(_ id: String, frame: SkinRect) {
        let spot = (x: frame.x.rounded(), y: frame.y.rounded())
        let drag = StudioAddView.currentDrag
        StudioAddView.currentDrag = nil
        switch drag {
        case .data(let item)?: chooseLook(for: item, at: spot)
        case .part(let p)?: addPart(p, at: spot)
        case .symbol(let s)?: addSymbol(s, at: spot)
        case nil:
            guard let skin, let component = EditorComponents.component(id) else { return }
            let sections = EditorComponents.sections(for: id, x: spot.x, y: spot.y, existing: skin.sectionNames,
                                                     variables: skin.variableNames)
            insert(sections, title: component.title)
        }
    }

    // MARK: This widget's colors and fonts

    /// The option of a part a color of the widget goes to (its text, its bar, its line, its symbol's tint).
    static func colorKey(_ m: Meter) -> String? {
        switch StudioPartKind(m) {
        case .number, .text: return "FontColor"
        case .bar: return "BarColor"
        case .ring, .graph: return "LineColor"
        case .symbol, .picture: return "ImageTint"
        case .shape, .part: return nil
        }
    }

    /// One of the widget's colors on the selected part, as the widget writes it (its variable when it has one).
    @discardableResult
    func useColor(_ id: String) -> Bool {
        guard let skin, let facts = widgetPage.facts, let role = widgetPage.colorRoles(facts)[id],
              let name = canvasController.canvas.selectedNames.last, let m = skin.meter(named: name),
              let key = Self.colorKey(m) else {
            if app.presentsWindows { NSSound.beep() }
            return false
        }
        let value = role.variable.map { "#\($0)#" }
            ?? StudioColorWriting.text(role.color, like: m.fileOption(key) ?? "", acceptsAlpha: true)
        let ops = WriteScopes.ops(.element, meter: m.name, key: key, value: value, in: skin)
        guard !ops.isEmpty else {
            partPage.sharedPartRefused(m)
            return false
        }
        return partPage.apply(StudioText[.rowColor], ops)
    }

    /// One of the widget's fonts on the selected text.
    @discardableResult
    func useFont(_ id: String) -> Bool {
        guard let skin, let facts = widgetPage.facts, id.hasPrefix("font:"), let i = Int(id.dropFirst(5)),
              facts.fonts.indices.contains(i), let name = canvasController.canvas.selectedNames.last,
              let m = skin.meter(named: name), m.type == "string" else {
            if app.presentsWindows { NSSound.beep() }
            return false
        }
        let font = facts.fonts[i]
        let value: String
        switch font.source {
        // The widget's variable for it: the part follows it from now on.
        case .variable(let v): value = "#\(v)#"
        // A look (MeterStyle) names a section, not a variable: the face it gives (taking the look itself would bring
        // its sizes and colors along).
        case .look, .meters: value = font.face
        }
        let ops = WriteScopes.ops(.element, meter: m.name, key: "FontFace", value: value, in: skin)
        guard !ops.isEmpty else {
            partPage.sharedPartRefused(m)
            return false
        }
        return partPage.apply(StudioText[.rowFont], ops)
    }
}
