import AppKit
import DesksetCore

// In-window overlays of the skin editor (docs/editor-friendly.md §9.9, §9.10, §12): the sticky chip at the top of the
// canvas when layers are cut off, the status capsule above the zoom control when the sound data is silent, and the
// three first-run tips. They float over the panes; each draws its own background (no material, no NSPopover), so the
// off-screen snapshot shows them exactly as they are (`InspectorWindowController.overlayViews`).

/// A capsule over the editor: an optional symbol, a line of words, buttons and a close button — drawn by itself on a
/// quiet surface, with an arrow when it points at something (a tip).
class OverlayCapsule: NSView {
    enum Arrow { case none, up, down }

    let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    /// The symbol, the words with the buttons, and the close button.
    private let row: NSStackView
    /// The words and the buttons: side by side, or the buttons under the words when the capsule is too narrow for
    /// both on one line (`buttonsBelowWords`).
    private let wordsAndButtons: NSStackView
    private let buttonRow: NSStackView
    private(set) var buttons: [NSButton] = []
    let closeButton: NSButton
    var arrow: Arrow {
        didSet {
            needsDisplay = true
            updateInsets()
        }
    }
    /// A warning (orange symbol and rim) instead of a neutral note.
    var isWarning = false { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    private var handlers: [() -> Void] = []
    private var topInset: NSLayoutConstraint!
    private var bottomInset: NSLayoutConstraint!
    /// Counts the layout passes that changed how the words wrap (`settleLayout` stops once one changes nothing).
    private var wrapChanges = 0

    static let arrowSize: CGFloat = 7
    /// The capsule's padding left and right of its row.
    private static let sidePadding: (leading: CGFloat, trailing: CGFloat) = (12, 10)
    /// Below this width for the words beside the buttons, the buttons go under the words.
    static let minWordsBesideButtons: CGFloat = 200

    init(arrow: Arrow = .none) {
        self.arrow = arrow
        closeButton = NSButton(image: EditorStyle.image("xmark", size: 9, weight: .bold) ?? NSImage(), target: nil, action: nil)
        row = EditorStyle.hstack([], spacing: 8)
        buttonRow = EditorStyle.hstack([], spacing: 8)
        wordsAndButtons = EditorStyle.hstack([], spacing: 8)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        // The width decides the lines (`layout`): however narrow the capsule gets, every word shows.
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = maxTextWidth
        label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        label.setContentHuggingPriority(.init(250), for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityLabel("Close")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        buttonRow.isHidden = true
        wordsAndButtons.addArrangedSubview(label)
        wordsAndButtons.addArrangedSubview(buttonRow)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(wordsAndButtons)
        row.addArrangedSubview(closeButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // The padding is constraints of the capsule (a stack's own insets do not always make it taller).
        topInset = row.topAnchor.constraint(equalTo: topAnchor)
        bottomInset = bottomAnchor.constraint(equalTo: row.bottomAnchor)
        NSLayoutConstraint.activate([
            topInset, bottomInset,
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sidePadding.leading),
            trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: Self.sidePadding.trailing),
        ])
        updateInsets()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateInsets() {
        let a = Self.arrowSize
        topInset?.constant = 7 + (arrow == .up ? a : 0)
        bottomInset?.constant = 7 + (arrow == .down ? a : 0)
    }

    /// The words, the symbol and the buttons (a close button stays last).
    func configure(_ text: String, symbol: String?, actions: [ToastAction]) {
        label.stringValue = text
        setAccessibilityLabel(text)
        icon.image = symbol.flatMap { EditorStyle.image($0, size: 12, weight: .semibold) }
        icon.isHidden = symbol == nil
        icon.contentTintColor = isWarning ? .systemOrange : .controlAccentColor
        for b in buttons { b.removeFromSuperview() }
        handlers = actions.map(\.handler)
        buttons = actions.enumerated().map { i, action in
            let b = NSButton(title: action.title, target: self, action: #selector(buttonClicked(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            return b
        }
        for b in buttons { buttonRow.addArrangedSubview(b) }
        buttonRow.isHidden = buttons.isEmpty
        label.invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    /// Lays the window out until the words wrap at the width they get and the capsule has their height (a change of
    /// width can need a second pass, and one more to take the new height).
    func settleLayout() {
        for _ in 0..<6 {
            let changes = wrapChanges
            needsLayout = true
            window?.contentView?.layoutSubtreeIfNeeded()
            if wrapChanges == changes { break }
        }
    }

    var text: String { label.stringValue }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < handlers.count else { return }
        handlers[sender.tag]()
    }

    @objc private func closeClicked() { onClose?() }

    /// The capsule's body (without the arrow).
    private var body: NSRect {
        // Flipped: the arrow up takes the top of the view, the arrow down its bottom.
        var r = bounds.insetBy(dx: 0.5, dy: 0.5)
        switch arrow {
        case .up:
            r.origin.y += Self.arrowSize
            r.size.height -= Self.arrowSize
        case .down:
            r.size.height -= Self.arrowSize
        case .none:
            break
        }
        return r
    }

    override var isFlipped: Bool { true }

    /// A capsule faded out (T2 waits with `alphaValue` 0 while the identity strip is scrolled away,
    /// `positionGroupTip`) lets clicks through to what is under it: AppKit hit-tests views whatever their alpha.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.01 ? nil : super.hitTest(point)
    }

    /// The widest the words get before they wrap (a capsule sized by its words).
    var maxTextWidth: CGFloat = 380 { didSet { needsLayout = true } }
    /// The capsule's width is set from outside (pinned to a pane): the words wrap at the width they get.
    var fillsWidth = false { didSet { needsLayout = true } }
    /// The widest a capsule sized by its words may be now (the pane it floats over; nil: no limit but
    /// `maxTextWidth`). Read on every layout, so the words wrap narrower in a narrow pane and wider again when it
    /// widens.
    var widthLimit: (() -> CGFloat)? { didSet { needsLayout = true } }
    /// Whether the buttons are under the words (the capsule is too narrow for both on one line).
    private(set) var buttonsBelowWords = false

    /// The width the capsule takes besides its words and buttons: its padding, the symbol, the close button and the
    /// spaces between them.
    private var chromeWidth: CGFloat {
        let others = row.arrangedSubviews.filter { $0 !== wordsAndButtons && !$0.isHidden }
        return Self.sidePadding.leading + Self.sidePadding.trailing + others.map { $0.fittingSize.width }.reduce(0, +)
            + row.spacing * CGFloat(others.count)
    }

    /// Wrapped words need a width to know their height. It comes from the room the capsule has — its own width when
    /// that is set from outside, else `widthLimit` — never from the width the label happened to get last time, so
    /// the words wrap wider again when the room grows. Buttons that leave the words too little room move under them.
    override func layout() {
        super.layout()
        let room: CGFloat
        if fillsWidth {
            guard bounds.width > 0 else { return }
            room = bounds.width - chromeWidth
        } else {
            let limit = widthLimit?() ?? .greatestFiniteMagnitude
            guard limit > 0 else { return }
            room = limit - chromeWidth
        }
        let cap = fillsWidth ? CGFloat.greatestFiniteMagnitude : maxTextWidth
        let buttonsWidth = buttons.isEmpty ? 0 : buttonRow.fittingSize.width + 8
        let beside = min(cap, room - buttonsWidth)
        let below = !buttons.isEmpty && beside < Self.minWordsBesideButtons
        let words = floor(below ? min(cap, room) : beside)
        guard words > 20 else { return }
        var changed = false
        if below != buttonsBelowWords {
            buttonsBelowWords = below
            wordsAndButtons.orientation = below ? .vertical : .horizontal
            wordsAndButtons.alignment = below ? .leading : .centerY
            wordsAndButtons.spacing = below ? 6 : 8
            changed = true
        }
        if abs(label.preferredMaxLayoutWidth - words) > 0.5 {
            label.preferredMaxLayoutWidth = words
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        if changed {
            wrapChanges += 1
            needsLayout = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = body
        let radius = min(r.height / 2, 14)
        let capsule = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        // The arrow: a triangle on the capsule's edge, its two sides outlined (its base is inside the capsule).
        let a = Self.arrowSize
        var tip: (base: CGFloat, point: CGFloat)?
        switch arrow {
        case .up: tip = (r.minY + 1.5, r.minY - a)
        case .down: tip = (r.maxY - 1.5, r.maxY + a)
        case .none: break
        }
        let fill = dark ? NSColor(white: 0.22, alpha: 0.98) : NSColor(white: 1, alpha: 0.98)
        let rim = isWarning ? NSColor.systemOrange.withAlphaComponent(0.55) : NSColor.separatorColor
        fill.setFill()
        capsule.fill()
        if isWarning {
            NSColor.systemOrange.withAlphaComponent(0.12).setFill()
            capsule.fill()
        }
        rim.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        guard let tip else { return }
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: r.midX - a, y: tip.base))
        triangle.line(to: NSPoint(x: r.midX, y: tip.point))
        triangle.line(to: NSPoint(x: r.midX + a, y: tip.base))
        triangle.close()
        fill.setFill()
        triangle.fill()
        let sides = NSBezierPath()
        let edge = arrow == .up ? r.minY : r.maxY
        let run = a * abs(edge - tip.base) / abs(tip.point - tip.base)
        sides.move(to: NSPoint(x: r.midX - a + run, y: edge))
        sides.line(to: NSPoint(x: r.midX, y: tip.point))
        sides.line(to: NSPoint(x: r.midX + a - run, y: edge))
        sides.lineWidth = 1
        rim.setStroke()
        sides.stroke()
    }
}

/// The first-run tips (§12): at most three, each shown once (`EditorPreferences.seenTips`), never by itself in
/// self-tests or snapshots (`--tip N` shows one).
enum EditorTip: Int, CaseIterable {
    /// The canvas, the first time the editor opens.
    case click = 1
    /// The identity strip, the first time a run of repeated layers is selected.
    case group = 2
    /// The Add tab's cards, the first time the tab opens.
    case add = 3

    /// Its name in `seenTips`.
    var key: String { "T\(rawValue)" }
}

extension InspectorWindowController {
    // MARK: Building

    /// Creates the overlays (hidden) over the window's content and registers them for the snapshot.
    func buildCanvasOverlays() {
        guard let content = window?.contentView else { return }
        let top = content.safeAreaLayoutGuide.topAnchor
        widgetChip.isWarning = true
        widgetChip.onClose = { [weak self] in self?.dismissWidgetChip() }
        statusCapsule.onClose = { [weak self] in self?.dismissSilentData() }
        for (tip, view) in tipViews.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            view.onClose = { [weak self] in self?.dismissTip(tip) }
        }
        let views: [NSView] = [widgetChip, statusCapsule] + EditorTip.allCases.compactMap { tipViews[$0] }
        for view in views { content.addSubview(view) }
        let t1 = tipViews[.click]!, t2 = tipViews[.group]!, t3 = tipViews[.add]!
        t1.maxTextWidth = 340
        widgetChip.maxTextWidth = 400
        statusCapsule.maxTextWidth = 460
        t2.fillsWidth = true
        t3.fillsWidth = true
        // The canvas's capsules are sized by their words, at most `widest` and 16 points in from the pane's sides; the
        // words wrap at the room that leaves (the pane narrows in Split mode and widens again).
        for (capsule, widest) in [(widgetChip, CGFloat(560)), (statusCapsule, 560), (t1, 440)] {
            NSLayoutConstraint.activate([
                capsule.centerXAnchor.constraint(equalTo: canvasPane.centerXAnchor),
                capsule.widthAnchor.constraint(lessThanOrEqualTo: canvasPane.widthAnchor, constant: -32),
                capsule.widthAnchor.constraint(lessThanOrEqualToConstant: widest),
            ])
            capsule.widthLimit = { [weak self] in min(widest, (self?.canvasPane.bounds.width ?? 0) - 32) }
        }
        // T1 goes under the chip while the chip shows, never over it (`updateWidgetChip`); T2 under the identity
        // strip's buttons, never over them (`positionGroupTip`).
        clickTipAtTop = t1.topAnchor.constraint(equalTo: top, constant: 52)
        clickTipBelowChip = t1.topAnchor.constraint(equalTo: widgetChip.bottomAnchor, constant: 8)
        groupTipTop = t2.topAnchor.constraint(equalTo: top, constant: 104)
        // Selector-based, so windowWillClose's removeObserver(self) ends it with the window.
        NotificationCenter.default.addObserver(self, selector: #selector(inspectorScrolled),
                                               name: NSView.boundsDidChangeNotification, object: inspectorScroll.contentView)
        inspectorScroll.contentView.postsBoundsChangedNotifications = true
        NSLayoutConstraint.activate([
            widgetChip.topAnchor.constraint(equalTo: top, constant: 52),
            statusCapsule.bottomAnchor.constraint(equalTo: zoomPill.topAnchor, constant: -10),
            clickTipAtTop!,
            groupTipTop!,
            t2.leadingAnchor.constraint(equalTo: inspectorPane.leadingAnchor, constant: 12),
            t2.trailingAnchor.constraint(equalTo: inspectorPane.trailingAnchor, constant: -12),
            t3.bottomAnchor.constraint(equalTo: sidebarPane.bottomAnchor, constant: -16),
            t3.leadingAnchor.constraint(equalTo: sidebarPane.leadingAnchor, constant: 10),
            t3.trailingAnchor.constraint(equalTo: sidebarPane.trailingAnchor, constant: -10),
        ])
        overlayViews += views
    }

    @objc func inspectorScrolled(_ note: Notification) { positionGroupTip() }

    // MARK: Cut-off chip (§9.10)

    /// The sticky chip's words for the layers cut off now: past the left or top edge ("“Audio” goes past the left
    /// edge. That part won't show on the desktop."), else outside a fixed size; nil when nothing is.
    func widgetChipContent() -> (text: String, actions: [ToastAction])? {
        guard let skin else { return nil }
        let cut = cutOffLayers()
        let leftTop = cut.filter { !$0.edges.intersection([.left, .top]).isEmpty }
        if !leftTop.isEmpty {
            let edges = leftTop.reduce(CutOffEdges()) { $0.union($1.edges) }
            let edge = edges.contains(.left) && edges.contains(.top) ? "the left and top edges"
                : edges.contains(.left) ? "the left edge" : "the top edge"
            let who = leftTop.count == 1 ? "\(chipName(leftTop[0].name)) goes" : "\(leftTop.count) layers go"
            return ("\(who) past \(edge). That part won't show on the desktop.",
                    [ToastAction("Fit Widget to Content") { [weak self] in self?.fitWidgetToContent() }])
        }
        guard !cut.isEmpty else { return nil }
        let size = "\(EditorStyle.number(skin.width)) × \(EditorStyle.number(skin.height))"
        let who = cut.count == 1 ? "Part of \(chipName(cut[0].name)) is" : "Parts of \(cut.count) layers are"
        return ("\(who) outside the widget's fixed size (\(size)).", [
            ToastAction("Make Widget Bigger") { [weak self] in self?.makeWidgetBigger() },
            ToastAction("Fit to Content") { [weak self] in self?.fitFixedSizeToContent() },
        ])
    }

    /// What the chip is about (the layers and edges), to keep it closed after × until that changes.
    var widgetChipSubject: String {
        cutOffLayers().map { "\($0.name.lowercased()):\($0.edges.rawValue)" }.joined(separator: ",")
    }

    /// A layer's name in the chip: the one it had when the chip first named it (a live text's words change as it runs).
    func chipName(_ section: String) -> String {
        let key = section.lowercased()
        if let name = chipNames[key] { return name }
        let name = displayName(ofSection: section)
        chipNames[key] = name
        return name
    }

    /// Shows or hides the chip for the skin as it is (not during a gesture: the canvas's badge speaks then, and what
    /// the chip said may no longer be true; not in Code mode: it is about the canvas and would cover the code).
    func updateWidgetChip() {
        defer { placeClickTip() }
        guard isCanvasVisible, geometryBases.isEmpty else {
            widgetChip.isHidden = true
            return
        }
        guard let content = widgetChipContent(), dismissedChipSubject != widgetChipSubject else {
            widgetChip.isHidden = true
            chipNames = [:]
            return
        }
        let changed = widgetChip.text != content.text || widgetChip.buttons.map(\.title) != content.actions.map(\.title)
        if changed { widgetChip.configure(content.text, symbol: "exclamationmark.triangle.fill", actions: content.actions) }
        let appearing = widgetChip.isHidden
        widgetChip.isHidden = false
        if changed || appearing { widgetChip.settleLayout() }
    }

    /// T1 under the chip while the chip shows, else at the top of the canvas.
    func placeClickTip() {
        let below = !widgetChip.isHidden
        guard clickTipBelowChip?.isActive != below else { return }
        clickTipAtTop?.isActive = !below
        clickTipBelowChip?.isActive = below
    }

    /// T2 just under the identity strip (its buttons stay clickable), following the inspector as it scrolls; hidden
    /// while the strip is scrolled out of view.
    func positionGroupTip() {
        guard let tip = tipViews[.group], !tip.isHidden || isTipShown(.group), let content = window?.contentView,
              let strip = inspectorStack.findSubview(where: { $0.identifier?.rawValue == "identity-strip" }) else { return }
        let r = strip.convert(strip.bounds, to: content)
        let visible = inspectorScroll.convert(inspectorScroll.bounds, to: content)
        let bottom = content.isFlipped ? r.maxY : content.bounds.height - r.minY
        let top = content.isFlipped ? visible.minY : content.bounds.height - visible.maxY
        groupTipTop?.constant = max(bottom - content.safeAreaInsets.top + 6, top - content.safeAreaInsets.top + 6)
        tip.alphaValue = r.intersects(visible) ? 1 : 0
    }

    func dismissWidgetChip() {
        dismissedChipSubject = widgetChipSubject
        widgetChip.isHidden = true
    }

    // MARK: Silent data (§9.9, phase 1)

    /// What the sound the visible layers show is doing: playing, silent, or not heard at all (a missing permission).
    enum SoundState: Equatable { case playing, silent, cannotHear }

    /// The state of the sound data that visible bars, graphs and gauges show (nil: they show none).
    func soundState() -> SoundState? {
        guard let skin else { return nil }
        let sound = skin.meters.filter { !$0.hidden && !($0 is StringMeter) }.flatMap(\.measures)
            .filter { $0 is AudioLevelMeasure }
        guard !sound.isEmpty else { return nil }
        let notes = [AudioPermissions.microphoneNote, AudioPermissions.screenRecordingNote, AudioCaptureEngine.silenceNote]
        if skin.issues.contains(where: { notes.contains($0) }) { return .cannotHear }
        return sound.allSatisfy { $0.value == 0 } ? .silent : .playing
    }

    /// Follows the sound data (every tick): the capsule above the zoom control shows once it has been silent — or
    /// unheard — for 2 seconds (`settled`: as if it had, for snapshots), until closed. Never in Code mode (it explains
    /// the canvas and would cover the code); the silence is still timed there.
    func updateSilentData(settled: Bool = false) {
        let state = soundState()
        let now = overlayClock()
        if state == nil || state == .playing {
            silentSince = nil
            statusCapsule.isHidden = true
            return
        }
        if silentSince == nil || lastSoundState != state { silentSince = now }
        lastSoundState = state
        guard isCanvasVisible, settled || now.timeIntervalSince(silentSince ?? now) >= 2, dismissedSoundState != state
        else {
            statusCapsule.isHidden = true
            return
        }
        let text: String, actions: [ToastAction]
        if state == .cannotHear {
            text = "Deskset can't hear your Mac's sound yet."
            actions = [ToastAction("Allow…") { [weak self] in self?.openSoundPermission() }]
        } else {
            text = "No sound is playing, so the bars are still. Play something to see them move."
            actions = []
        }
        let changed = statusCapsule.text != text, appearing = statusCapsule.isHidden
        if changed { statusCapsule.configure(text, symbol: "speaker.slash", actions: actions) }
        statusCapsule.isHidden = false
        if changed || appearing { statusCapsule.settleLayout() }
    }

    func dismissSilentData() {
        dismissedSoundState = lastSoundState
        statusCapsule.isHidden = true
    }

    /// Allow…: the privacy settings that let Deskset hear the sound (the microphone for input, else screen and system
    /// audio recording).
    func openSoundPermission() {
        let microphone = skin?.issues.contains(AudioPermissions.microphoneNote) == true
        let pane = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        guard app.presentsWindows,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Tips (§12)

    /// Whether tips show by themselves: in the running app only (never in self-tests or snapshots).
    var showsTipsAutomatically: Bool { automaticTips ?? app.presentsWindows }

    /// The words of a tip.
    func tipText(_ tip: EditorTip) -> String {
        switch tip {
        case .click:
            return "Click anything in your widget to change it. Drag new things in from Add."
        case .group:
            let group = canvas.selectedGroup ?? canvas.groups.first ?? []
            let name = group.isEmpty ? "These layers" : "These \(canvas.groupName(group))"
            let one = group.first.flatMap { skin?.meter(named: $0) }.map { LayerNaming.kindNoun($0).lowercased() } ?? "layer"
            return "\(name) change together. Double-click one \(one) on the canvas to change just that one."
        case .add:
            return "Drag any of these onto your widget, or click one to add it below what's there."
        }
    }

    /// Shows a tip now and records it as seen (`--tip N` shows one whatever was seen).
    func showTip(_ tip: EditorTip) {
        guard let view = tipViews[tip] else { return }
        view.configure(tipText(tip), symbol: "lightbulb", actions: [])
        view.isHidden = false
        if tip == .group {
            window?.contentView?.layoutSubtreeIfNeeded()
            positionGroupTip()
        }
        if tip == .click { placeClickTip() }
        view.settleLayout()
        if !app.state.editor.seenTips.contains(tip.key) { app.state.updateEditor { $0.seenTips.insert(tip.key) } }
    }

    func dismissTip(_ tip: EditorTip) {
        tipViews[tip]?.isHidden = true
    }

    func isTipShown(_ tip: EditorTip) -> Bool { tipViews[tip]?.isHidden == false }

    /// Shows the tips whose moment has come and that were never shown (running app only), and hides those whose
    /// moment has passed: T1 on the first open until something is selected, T2 when a run of layers is selected, T3
    /// while the Add tab is open.
    func updateTips() {
        if isTipShown(.click), !canvas.selectedNames.isEmpty { dismissTip(.click) }
        // T1 points at the canvas: it waits while Code mode hides the canvas, and comes back with it.
        if isTipShown(.click), !isCanvasVisible {
            dismissTip(.click)
            clickTipWaitsForCanvas = true
        }
        if clickTipWaitsForCanvas, isCanvasVisible {
            clickTipWaitsForCanvas = false
            if canvas.selectedNames.isEmpty, selectedSection == nil { showTip(.click) }
        }
        if isTipShown(.add), sidebarTab != .library { dismissTip(.add) }
        if isTipShown(.group), canvas.selectedGroup == nil { dismissTip(.group) }
        if isTipShown(.group) { positionGroupTip() }
        guard showsTipsAutomatically, skin != nil else { return }
        let seen = app.state.editor.seenTips
        func due(_ tip: EditorTip) -> Bool { !seen.contains(tip.key) }
        if due(.click), isCanvasVisible, canvas.selectedNames.isEmpty, selectedSection == nil { showTip(.click) }
        if due(.group), canvas.selectedGroup != nil { showTip(.group) }
        if due(.add), sidebarTab == .library { showTip(.add) }
    }

    /// Help ▸ Show Tips Again: every tip shows again when its moment comes (the first one now).
    @objc func showTipsAgain(_ sender: Any?) {
        app.state.updateEditor { $0.seenTips = [] }
        updateTips()
    }

    // MARK: All overlays

    /// Brings every overlay up to date with the skin, the selection and the mode.
    func updateCanvasOverlays() {
        updateWidgetChip()
        updateSilentData()
        updateTips()
    }

    /// The canvas pane changed size: the capsules over it wrap their words again (wider as well as narrower — a
    /// capsule whose own size did not change is not laid out by itself).
    func relayoutCanvasOverlays() {
        for capsule in [widgetChip, statusCapsule] + [tipViews[.click]].compactMap({ $0 }) where !capsule.isHidden {
            capsule.needsLayout = true
        }
    }
}
