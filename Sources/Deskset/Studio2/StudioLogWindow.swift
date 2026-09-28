import AppKit
import DesksetCore

/// One line of the Studio's log: what a widget logged — in the Studio (its own instance: `!Log`, a script, a formula,
/// WebParser) or on the desktop (the copy there, through the app's log).
struct StudioLogEntry: Equatable {
    enum Origin: Equatable { case studio, desktop }

    var date: Date?
    var level: SkinLogLevel
    var origin: Origin
    /// The widget's config (nil: the app itself).
    var widget: String?
    var message: String

    /// What the level filter shows.
    enum Filter: Int, CaseIterable {
        case all, errors, warnings, info

        func accepts(_ level: SkinLogLevel) -> Bool {
            switch self {
            case .all: return true
            case .errors: return level == .error
            case .warnings: return level == .warning
            case .info: return level == .notice || level == .debug
            }
        }

        var title: String {
            switch self {
            case .all: return StudioText[.logAllLevels]
            case .errors: return StudioText[.logErrors]
            case .warnings: return StudioText[.logWarnings]
            case .info: return StudioText[.logInfo]
            }
        }
    }
}

extension StudioWindowController {
    /// The log of this widget — its Studio instance's lines and the desktop copy's — or of every widget on the desktop.
    func logEntries(allWidgets: Bool) -> [StudioLogEntry] {
        let config = session?.config
        var result: [StudioLogEntry] = []
        for line in Log.recent {
            guard let source = line.source else { continue }
            if !allWidgets {
                guard let config, source.caseInsensitiveCompare(config) == .orderedSame else { continue }
            }
            result.append(StudioLogEntry(date: line.date, level: line.level, origin: .desktop, widget: source,
                                         message: line.message))
        }
        for line in session?.host.logs ?? [] {
            result.append(StudioLogEntry(date: nil, level: line.level, origin: .studio, widget: config,
                                         message: line.message))
        }
        return result
    }

    /// The code header's "Log N": the widget's warnings and errors, each told once (the Studio's instance and the
    /// desktop copy often log the same thing).
    var logCount: Int {
        var seen: Set<String> = []
        for e in logEntries(allWidgets: false) where e.level == .warning || e.level == .error {
            seen.insert(e.message)
        }
        return seen.count
    }

    /// Where a log line points in the widget's code: a section it names (`[MeterCPU]`, `MeterCPU`), or `file.inc:12`.
    func logTarget(_ entry: StudioLogEntry) -> (file: URL, line: Int)? {
        guard let skin else { return nil }
        if let match = entry.message.range(of: #"[A-Za-z0-9_@\-. ]+\.(ini|inc|lua):[0-9]+"#, options: .regularExpression) {
            let text = entry.message[match]
            if let colon = text.lastIndex(of: ":"), let line = Int(text[text.index(after: colon)...]) {
                let name = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if let file = skin.sourceFiles.first(where: { $0.lastPathComponent.lowercased() == name }) {
                    return (file, line)
                }
            }
        }
        for section in skin.document.sections {
            let name = section.name
            guard name.count > 2, !["rainmeter", "variables", "metadata"].contains(name.lowercased()) else { continue }
            let bracketed = entry.message.range(of: "[\(name)]", options: .caseInsensitive) != nil
            let word = entry.message.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: name))\b"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil
            if bracketed || word, let location = skin.sources.location(section: name) {
                return (location.file, location.line)
            }
        }
        return nil
    }

    /// Window ▸ Log: the log window, on this widget or every widget.
    func showLog(allWidgets: Bool) {
        let controller = codeState.logWindow ?? StudioLogWindowController(studio: self)
        codeState.logWindow = controller
        controller.allWidgets = allWidgets
        controller.reload()
        guard app.presentsWindows else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// A log line's "Show the Line": the code opens at it.
    func showLogLine(_ entry: StudioLogEntry) {
        guard let target = logTarget(entry) else { return }
        if !isCodeShown { setCodeMode(.alongside) }
        codeView.reveal(line: target.line, in: target.file, select: true)
        showDiagnostics()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(codeView.textView)
    }

    @objc func showWidgetLog(_ sender: Any?) { showLog(allWidgets: false) }
    @objc func showAllLogs(_ sender: Any?) { showLog(allWidgets: true) }
}

/// Window ▸ Log: what the widget logged (or every widget), newest last, filtered by level; a line that points into the
/// code opens it there.
final class StudioLogWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    weak var studio: StudioWindowController?
    var allWidgets = false
    var filter = StudioLogEntry.Filter.all
    private(set) var entries: [StudioLogEntry] = []
    let scope = NSSegmentedControl(labels: [StudioText[.logThisWidget], StudioText[.logAllWidgets]],
                                   trackingMode: .selectOne, target: nil, action: nil)
    let levels = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = NSTableView()
    let showLineButton = NSButton(title: StudioText[.logShowLine], target: nil, action: nil)
    let emptyLabel = NSTextField(labelWithString: StudioText[.logEmpty])
    private var timer: Timer?
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(studio: StudioWindowController) {
        self.studio = studio
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        buildContent()
        if let frame = studio.window?.frame {
            window.setFrameOrigin(NSPoint(x: frame.maxX - 640, y: frame.minY + 20))
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        scope.target = self
        scope.action = #selector(scopeChanged)
        scope.selectedSegment = 0
        for f in StudioLogEntry.Filter.allCases { levels.addItem(withTitle: f.title) }
        levels.target = self
        levels.action = #selector(levelChanged)
        levels.setAccessibilityLabel(StudioText[.logTitle])
        showLineButton.target = self
        showLineButton.action = #selector(showLine)
        showLineButton.bezelStyle = .rounded
        for (id, title, width) in [("level", "", 22.0), ("time", "", 64.0), ("where", "", 110.0), ("message", "", 380.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            if id == "message" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(showLine)
        table.setAccessibilityLabel(StudioText[.logTitle])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        let bar = NSStackView(views: [scope, levels, NSView(), showLineButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        for v in [bar, scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    /// The entries as the scope and the level filter have them now.
    func reload() {
        guard let studio else { return }
        scope.selectedSegment = allWidgets ? 1 : 0
        levels.selectItem(at: filter.rawValue)
        entries = studio.logEntries(allWidgets: allWidgets).filter { filter.accepts($0.level) }
        let name = studio.widgetName
        window?.title = allWidgets ? StudioText[.logTitle] : StudioText.format(.logTitleWidget, name)
        table.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        updateButton()
        if !entries.isEmpty { table.scrollRowToVisible(entries.count - 1) }
        startTimer()
    }

    private func startTimer() {
        guard timer == nil, studio?.app.presentsWindows == true else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, let studio = self.studio else { return }
            let now = studio.logEntries(allWidgets: self.allWidgets).filter { self.filter.accepts($0.level) }
            guard now != self.entries else { return }
            self.entries = now
            self.table.reloadData()
            self.emptyLabel.isHidden = !now.isEmpty
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func updateButton() {
        let row = table.selectedRow
        showLineButton.isEnabled = row >= 0 && row < entries.count && studio?.logTarget(entries[row]) != nil
    }

    @objc func scopeChanged() {
        allWidgets = scope.selectedSegment == 1
        reload()
    }

    @objc func levelChanged() {
        filter = StudioLogEntry.Filter(rawValue: levels.indexOfSelectedItem) ?? .all
        reload()
    }

    @objc func showLine() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < entries.count else { return }
        studio?.showLogLine(entries[row])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButton() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < entries.count else { return nil }
        let e = entries[row]
        if id == "level" {
            let symbol: String, color: NSColor
            switch e.level {
            case .error: (symbol, color) = ("xmark.octagon.fill", StudioCodeColors.problem)
            case .warning: (symbol, color) = ("exclamationmark.triangle.fill", StudioCodeColors.warning)
            case .notice: (symbol, color) = ("info.circle", .secondaryLabelColor)
            case .debug: (symbol, color) = ("ant", .tertiaryLabelColor)
            }
            let image = NSImageView(image: StudioPageStyle.symbol(symbol, size: 11, color: color) ?? NSImage())
            image.setAccessibilityLabel(e.level.rawValue)
            return image
        }
        let text: String
        switch id {
        case "time": text = e.date.map { Self.timeFormatter.string(from: $0) } ?? "—"
        case "where":
            let place = e.origin == .studio ? StudioText[.logStudio] : StudioText[.logDesktop]
            text = allWidgets ? "\(e.widget ?? "") · \(place)" : place
        default: text = e.message
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = id == "message" ? .systemFont(ofSize: 12) : .systemFont(ofSize: 11)
        label.textColor = id == "message" ? .labelColor : .secondaryLabelColor
        label.toolTip = id == "message" ? text : nil
        return label
    }
}
