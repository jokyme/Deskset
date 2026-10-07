import AppKit
import DesksetCore

/// A view of an accepted options snapshot. The owning session validates, projects and saves its edits.
final class DeskProgramOptionsPanelController: NSWindowController, NSWindowDelegate {
    struct Change {
        let id: UUID
        let lease: UUID
        let revision: UInt64
        let name: String
        let value: ProgramOptionValue
        let finished: Bool
    }

    var onChange: ((Change) -> Void)?
    var onRestoreDefaults: ((UUID, UInt64) -> Void)?
    var onMoreStyles: ((UUID) -> Void)?
    var onRequestClose: ((UUID) -> Void)?
    var displayTitle = StudioText[.deskOptions] {
        didSet { window?.title = displayTitle; render() }
    }
    let pageView = StudioPageView(frame: .zero)
    let scrollView = NSScrollView()
    let restoreButton = NSButton(title: StudioText[.deskOptionsRestore], target: nil, action: nil)
    let moreStylesButton = NSButton(title: StudioText[.deskOptionsMoreStyles], target: nil, action: nil)
    let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var snapshot: ProgramOptionsSnapshot?
    private(set) var lease: UUID?
    private(set) var isClosed = false
    private let presentsWindows: Bool
    private let content = ContentView()
    private var isPreview = false
    private var acceptingEvents = false
    private var requestingClose = false
    private var options: [String: ProgramResolvedOption] = [:]
    private var drafts: [String: Change] = [:]
    private var invalidNumbers: [String: String] = [:]

    init(presentsWindows: Bool = true) {
        precondition(Thread.isMainThread)
        self.presentsWindows = presentsWindows
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 360, height: 260)
        panel.title = StudioText[.deskOptions]
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = content
        pageView.showsSearch = false
        scrollView.documentView = pageView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        feedbackLabel.font = StudioPageStyle.noteFont
        feedbackLabel.textColor = StudioPageStyle.attentionText
        feedbackLabel.isSelectable = false
        feedbackLabel.isHidden = true
        for button in [restoreButton, moreStylesButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        restoreButton.target = self; restoreButton.action = #selector(restoreDefaults)
        moreStylesButton.target = self; moreStylesButton.action = #selector(moreStyles)
        for view in [scrollView, feedbackLabel, restoreButton, moreStylesButton] as [NSView] { content.addSubview(view) }
        content.onLayout = { [weak self] in self?.layoutContent() }
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ snapshot: ProgramOptionsSnapshot, lease: UUID, isPreview: Bool = false, title: String? = nil) {
        precondition(Thread.isMainThread)
        guard !isClosed else { return }
        if self.lease != lease {
            acceptingEvents = false
            cancelMenus()
            window?.makeFirstResponder(nil)
            drafts.removeAll()
            invalidNumbers.removeAll()
            options.removeAll()
            self.snapshot = nil
            self.lease = lease
            // Retire the old controls as well as their lease: a retained old native target must stay inert.
            pageView.apply(StudioPage(id: "desk.options", title: "", subtitle: ""))
            setFeedback(nil)
        }
        guard self.snapshot.map({ snapshot.revision >= $0.revision }) ?? true else { return }
        self.snapshot = snapshot
        self.isPreview = isPreview
        if let title { displayTitle = title }
        options.removeAll()
        func collect(_ nodes: [ProgramResolvedOptionNode]) {
            for node in nodes {
                switch node {
                case .option(let option): options[option.name] = option
                case .section(_, let items): collect(items)
                }
            }
        }
        collect(snapshot.items)
        drafts = drafts.filter { options[$0.key] != nil }
        invalidNumbers = invalidNumbers.filter { options[$0.key]?.hidden == false }
        acceptingEvents = true
        render()
    }

    func complete(_ changeID: UUID, snapshot: ProgramOptionsSnapshot?, message: String? = nil) {
        precondition(Thread.isMainThread)
        guard !isClosed else { return }
        let completed = drafts.first { $0.value.id == changeID }?.key
        if let completed { drafts[completed] = nil }
        if let snapshot, let lease { apply(snapshot, lease: lease, isPreview: isPreview) }
        else { render() }
        // A failed older edit must not erase a newer draft or its feedback.
        if completed != nil { setFeedback(message) }
    }

    func setFeedback(_ message: String?) {
        precondition(Thread.isMainThread)
        let message = message ?? (invalidNumbers.isEmpty ? nil : StudioText[.deskOptionsInvalidNumber])
        feedbackLabel.stringValue = message ?? ""
        feedbackLabel.isHidden = message?.isEmpty ?? true
        layoutContent()
    }

    func present(relativeTo anchor: NSRect? = nil) {
        precondition(Thread.isMainThread)
        guard !isClosed, let window else { return }
        if let anchor, anchor.minX.isFinite, anchor.minY.isFinite, anchor.width.isFinite, anchor.height.isFinite {
            var frame = window.frame
            frame.origin = NSPoint(x: anchor.maxX + 12, y: anchor.maxY - frame.height)
            let screens = WindowGeometry.currentScreens()
            if let index = WindowGeometry.screenIndex(for: anchor, screens: screens) {
                frame = WindowGeometry.clamp(frame, into: screens[index].visibleFrame)
            }
            window.setFrame(frame, display: false)
        } else if presentsWindows { window.center() }
        if presentsWindows { window.makeKeyAndOrderFront(nil) }
    }

    /// Ending a field edit can submit another asynchronous change. The session must recheck its queue afterward.
    func commitEditing() -> Bool {
        precondition(Thread.isMainThread)
        guard !isClosed, let lease, let window, window.makeFirstResponder(nil) else { return false }
        return !isClosed && self.lease == lease && invalidNumbers.isEmpty
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosed, !requestingClose, let lease else { return false }
        requestingClose = true
        defer { requestingClose = false }
        // The session owns flushing: a synchronous rejected edit may revoke its close request while it commits.
        if let onRequestClose { onRequestClose(lease) }
        else if commitEditing(), self.lease == lease { close() }
        return false
    }

    override func close() {
        precondition(Thread.isMainThread)
        guard !isClosed else { return }
        isClosed = true
        acceptingEvents = false
        lease = nil
        drafts.removeAll()
        invalidNumbers.removeAll()
        cancelMenus()
        window?.makeFirstResponder(nil)
        onChange = nil; onRestoreDefaults = nil; onMoreStyles = nil; onRequestClose = nil
        super.close()
    }

    @objc private func restoreDefaults() {
        guard acceptingEvents, !isClosed, let lease else { return }
        window?.makeFirstResponder(nil)
        guard !isClosed, self.lease == lease, let snapshot else { return }
        drafts.removeAll()
        invalidNumbers.removeAll()
        setFeedback(nil)
        onRestoreDefaults?(lease, snapshot.revision)
    }

    @objc private func moreStyles() {
        guard acceptingEvents, !isClosed, let lease else { return }
        window?.makeFirstResponder(nil)
        guard !isClosed, self.lease == lease else { return }
        onMoreStyles?(lease)
    }

    private func render() {
        guard !isClosed, let snapshot, let lease else { return }
        var sections: [StudioPage.Section] = []
        func append(_ nodes: [ProgramResolvedOptionNode], path: String, title: String) {
            var items: [StudioPage.Item] = [], part = 0
            func flush() {
                guard !items.isEmpty else { return }
                sections.append(.init(id: path + ".\(part)", title: title, items: items))
                items.removeAll(); part += 1
            }
            for (index, node) in nodes.enumerated() {
                switch node {
                case .option(let option):
                    guard !option.hidden else { continue }
                    let value = drafts[option.name]?.value ?? option.value
                    guard var control = Self.control(option.control, value: value) else { continue }
                    if let raw = invalidNumbers[option.name], case .stepper(var number) = control {
                        number.text = raw
                        control = .stepper(number)
                    }
                    items.append(.init(id: option.name, kind: .row(.init(label: option.title, control: control,
                        tooltip: option.help, labelWidth: 135))))
                    if let help = option.help, !help.isEmpty {
                        items.append(.init(id: option.name + ":help", kind: .note(.init(text: help, symbol: "info.circle"))))
                    }
                case .section(let heading, let children):
                    flush()
                    append(children, path: path + ".\(index)", title: heading)
                }
            }
            flush()
        }
        append(snapshot.items, path: "options", title: StudioText[.deskOptions])
        var controls: [String: StudioPage.Control] = [:]
        for item in sections.flatMap(\.items) {
            if case .row(let row) = item.kind { controls[item.id] = row.control }
        }
        for item in pageView.page?.sections.flatMap(\.items) ?? [] {
            guard let row = pageView.itemView(item.id) as? StudioRowView else { continue }
            if controls[item.id].map({ row.accepts($0) }) != true { row.controlView.menu?.cancelTracking() }
        }
        // This panel shows the complete schema; the Studio inspector's twelve-control fitting rule does not apply.
        pageView.apply(StudioPage(id: "desk.options", title: displayTitle,
            subtitle: isPreview ? StudioText[.deskOptionsPreview] : "", sections: sections, tight: true))
        for option in options.values where !option.hidden {
            guard let row = pageView.itemView(option.name) as? StudioRowView else { continue }
            row.controlView.setAccessibilityLabel(option.title)
            row.numberBox?.field.setAccessibilityLabel(option.title)
            row.onEvent = { [weak self, weak row] event in
                guard let self, let row, self.acceptingEvents, !self.isClosed, self.lease == lease,
                      self.pageView.itemView(option.name) === row,
                      self.options[option.name]?.hidden == false else { return }
                self.handle(event, name: option.name)
            }
        }
        layoutContent()
    }

    private static func control(_ control: ProgramResolvedOptionControl, value: ProgramOptionValue) -> StudioPage.Control? {
        switch (control, value) {
        case (.toggle, .boolean(let value)): return .toggle(value)
        case (.input(let placeholder), .string(let value)):
            return .number(.init(text: value, placeholder: placeholder ?? "", isText: true))
        case (.slider(let min, let max, let step), .number(let value)):
            return .slider(.init(value: value.value, minimum: min.value, maximum: max.value,
                                 step: step?.value, unit: unit(value.dimension)))
        case (.stepper(let min, let max, let step), .number(let value)):
            return .stepper(.init(text: StudioNumericValue.text(value.value), value: value.value, unit: unit(value.dimension),
                                 step: step.value, minimum: min.value, maximum: max.value))
        case (.picker(let choices), _):
            let selected = choices.firstIndex { $0.value == value }
            if choices.count <= 3 { return .segmented(.init(items: choices.map(\.title), selected: selected ?? -1)) }
            return .popup(.init(items: choices.map { .init(title: $0.title) }, selected: selected))
        default: return nil
        }
    }

    private static func unit(_ dimension: ProgramNumberDimension) -> String? {
        switch dimension {
        case .plain: return nil
        case .percent: return "%"
        case .bytes: return "B"
        case .duration: return "s"
        case .length: return "pt"
        case .angle: return "°"
        }
    }

    private func handle(_ event: StudioRowView.Event, name: String) {
        guard let option = options[name] else { return }
        let current = drafts[name]?.value ?? option.value
        switch (option.control, event) {
        case (.toggle, .toggle(let value)): changed(name, value: .boolean(value))
        case (.input, .number(_, .typed(let text))): changed(name, value: .string(text))
        case (.picker(let choices), .choose(let index)), (.picker(let choices), .segment(let index)):
            guard choices.indices.contains(index) else { return }
            changed(name, value: choices[index].value)
        case (.slider(let min, let max, _), .slider(let value, let done)):
            numberChanged(name, value: value, current: current, minimum: min.value, maximum: max.value, done: done)
        case (.stepper(let min, let max, let step), .number(_, let change)):
            let value: Double
            var rawText: String?
            switch change {
            case .typed(let text):
                guard let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    invalidNumbers[name] = text; setFeedback(StudioText[.deskOptionsInvalidNumber]); return
                }
                value = parsed
                rawText = text
            case .step(let count):
                guard count.isFinite, case .number(let number) = current else { return }
                let advanced = number.value + step.value * count
                value = Swift.min(Swift.max(advanced, min.value), max.value)
            default: return
            }
            numberChanged(name, value: value, current: current, minimum: min.value, maximum: max.value,
                          done: true, rawText: rawText)
        default: break
        }
    }

    private func numberChanged(_ name: String, value: Double, current: ProgramOptionValue,
                               minimum: Double, maximum: Double, done: Bool, rawText: String? = nil) {
        guard case .number(let prototype) = current, value.isFinite, value >= minimum, value <= maximum else {
            invalidNumbers[name] = rawText ?? StudioNumericValue.text(value)
            setFeedback(StudioText[.deskOptionsInvalidNumber]); return
        }
        changed(name, value: .number(ProgramNumber(value, dimension: prototype.dimension, displayBase: prototype.displayBase)),
                finished: done)
    }

    private func changed(_ name: String, value: ProgramOptionValue, finished: Bool = true) {
        guard acceptingEvents, !isClosed, let lease, let snapshot else { return }
        let change = Change(id: UUID(), lease: lease, revision: snapshot.revision, name: name, value: value, finished: finished)
        drafts[name] = change
        invalidNumbers[name] = nil
        setFeedback(invalidNumbers.isEmpty ? nil : StudioText[.deskOptionsInvalidNumber])
        onChange?(change)
        render()
    }

    private func cancelMenus() {
        for name in options.keys { (pageView.itemView(name) as? StudioRowView)?.controlView.menu?.cancelTracking() }
    }

    private func layoutContent() {
        let size = content.bounds.size, margin: CGFloat = 16, gap: CGFloat = 8
        let footer: CGFloat = 48
        let feedback = feedbackLabel.isHidden ? 0 : min(64, StudioPageStyle.height(of: feedbackLabel.stringValue,
            font: StudioPageStyle.noteFont, width: max(size.width - margin * 2, 1)) + 8)
        scrollView.frame = NSRect(x: 0, y: 0, width: size.width, height: max(size.height - footer - feedback, 1))
        let width = scrollView.contentSize.width
        pageView.frame.size = NSSize(width: width, height: max(pageView.fittingHeight(width: width), scrollView.contentSize.height))
        feedbackLabel.frame = NSRect(x: margin, y: scrollView.frame.maxY, width: max(size.width - margin * 2, 1), height: feedback)
        let restoreWidth = ceil(restoreButton.fittingSize.width), moreWidth = ceil(moreStylesButton.fittingSize.width)
        restoreButton.frame = NSRect(x: margin, y: size.height - footer + gap, width: restoreWidth, height: 28)
        moreStylesButton.frame = NSRect(x: max(margin + restoreWidth + gap, size.width - margin - moreWidth),
                                       y: size.height - footer + gap, width: moreWidth, height: 28)
    }

    private final class ContentView: NSView {
        var onLayout: (() -> Void)?
        override var isFlipped: Bool { true }
        override func layout() { super.layout(); onLayout?() }
    }
}
