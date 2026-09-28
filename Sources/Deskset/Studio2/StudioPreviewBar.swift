import AppKit
import DesksetCore

/// The colors of the Studio's quiet words (labels, captions): black at 58 % in light mode (about 5.3 : 1 on white),
/// white at 62 % in dark mode. `secondaryLabelColor` is only 3.95 : 1 in light mode.
enum StudioInk {
    static let quiet = NSColor(name: "StudioQuietInk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.62)
                                                                     : NSColor(white: 0, alpha: 0.58)
    }
    static let primary = NSColor(name: "StudioPrimaryInk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.88)
                                                                     : NSColor(white: 0, alpha: 0.85)
    }
    static let divider = NSColor(name: "StudioDivider") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.14)
                                                                     : NSColor(white: 0, alpha: 0.12)
    }
    static let live = NSColor(srgbRed: 0.20, green: 0.70, blue: 0.35, alpha: 1)
    /// The accent as words on the canvas's glass (an item in use): the accent itself is about 4 : 1 on white and less
    /// on glass over a dark picture, so it is taken darker in light (lighter in dark) until small words read at 4.5 : 1
    /// on the Bright, Busy and Dark samples.
    static let accentText = NSColor(name: "StudioAccentText") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var accent = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent }
        return (dark ? accent.blended(withFraction: 0.6, of: .white) : accent.blended(withFraction: 0.45, of: .black))
            ?? accent
    }
}

/// Whether the Studio's controls change at once (Reduce Motion) rather than animating.
enum StudioMotion {
    /// Set by the self-tests; nil: the system setting.
    static var reduceOverride: Bool?

    static var isReduced: Bool {
        reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs `changes` animated over `duration` (at once with Reduce Motion), then `done`.
    static func animate(_ duration: TimeInterval = 0.15, _ changes: @escaping (Bool) -> Void,
                        done: (() -> Void)? = nil) {
        guard !isReduced else {
            changes(false)
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            changes(true)
        }, completionHandler: done)
    }
}

// MARK: - Glass capsules

/// A capsule of glass floating over the canvas (the preview bar, the zoom capsule, the status capsules): Liquid Glass
/// on screen (macOS 26), the popover material before; drawn as a stand-in where no window server draws it
/// (`usesStandIn`: snapshots and self-tests).
class StudioCapsuleView: NSView {
    let usesStandIn: Bool
    private var glass: NSView?

    init(standIn: Bool) {
        usesStandIn = standIn
        super.init(frame: .zero)
        wantsLayer = true
        if !standIn {
            if #available(macOS 26.0, *), SkinGlassViews.usesSystemGlass {
                let g = NSGlassEffectView()
                glass = g
            } else {
                let effect = NSVisualEffectView()
                effect.material = .popover
                effect.blendingMode = .withinWindow
                effect.state = .active
                glass = effect
            }
            if let glass { addSubview(glass) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let glass else { return }
        glass.frame = bounds
        let radius = bounds.height / 2
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.cornerRadius = radius
        } else if let effect = glass as? NSVisualEffectView {
            effect.maskImage = radius > 0 ? SkinGlassViews.roundedMask(radius) : nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesStandIn else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        StudioSnapshot.drawGlass(bounds.insetBy(dx: 0.5, dy: 0.5), dark: dark)
    }

    /// Clicks between the items land on the capsule, not on the canvas under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// One item of a capsule: an icon, maybe a quiet prefix ("Preview:"), a title, maybe a quiet suffix ("Similar"), maybe
/// a chevron (it opens a menu or popover). In use (`isOn`) it is written in the accent color on a pale accent pill.
final class StudioBarItem: NSView {
    enum Icon: Equatable {
        case none
        case symbol(String)
        /// The green dot of live data.
        case liveDot
    }

    var icon = Icon.none { didSet { changed() } }
    var prefix: String? { didSet { changed() } }
    var title = "" { didSet { changed() } }
    var suffix: String? { didSet { changed() } }
    var showsChevron = false { didSet { changed() } }
    var isOn = false { didSet { changed() } }
    /// Written as a link (semibold, the link color): "Back to Live", "Open".
    var isLink = false { didSet { changed() } }
    /// The title is left out (a narrow canvas); the icon stays.
    var showsTitle = true { didSet { changed() } }
    var isEnabled = true { didSet { changed() } }
    /// The icon's color (nil: the accent color while on, else the text's).
    var iconColor: NSColor? { didSet { changed() } }
    var font = NSFont.systemFont(ofSize: 12, weight: .medium) { didSet { changed() } }
    var iconSize: CGFloat = 12 { didSet { changed() } }
    var horizontalPadding: CGFloat = 10 { didSet { changed() } }
    var monospacedDigits = false { didSet { changed() } }
    var action: (() -> Void)?
    private var pressed = false

    static let height: CGFloat = 30

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Self.height) }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        superview?.needsLayout = true
        updateAccessibility()
    }

    private var titleFont: NSFont {
        let base = isLink ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font
        guard monospacedDigits else { return base }
        return NSFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: isLink ? .semibold : .medium)
    }

    private var shownTitle: String { showsTitle ? title : "" }

    private var textColor: NSColor {
        if !isEnabled { return StudioInk.quiet.withAlphaComponent(0.35) }
        if isLink { return .linkColor }
        return isOn ? StudioInk.accentText : StudioInk.primary
    }

    private func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        // A filled symbol in a color of its own (the problem capsule's ✕ octagon) keeps its mark white.
        let colors: [NSColor] = name.hasSuffix(".fill") && iconColor != nil ? [.white, color] : [color]
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: colors))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        s.isEmpty ? 0 : ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    private var iconWidth: CGFloat {
        switch icon {
        case .none: return 0
        case .liveDot: return 11
        case .symbol(let name): return ceil(symbolImage(name, size: iconSize, weight: .medium, color: .black)?.size.width ?? 14)
        }
    }

    var width: CGFloat {
        var parts: [CGFloat] = []
        if icon != .none { parts.append(iconWidth) }
        if let prefix, showsTitle { parts.append(textWidth(prefix, NSFont.systemFont(ofSize: font.pointSize))) }
        if !shownTitle.isEmpty { parts.append(textWidth(shownTitle, titleFont)) }
        if let suffix, showsTitle { parts.append(textWidth(suffix, NSFont.systemFont(ofSize: font.pointSize - 1))) }
        if showsChevron { parts.append(8) }
        let gaps = CGFloat(max(parts.count - 1, 0)) * 5
        return ceil(parts.reduce(0, +) + gaps + 2 * horizontalPadding)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        if pressed {
            StudioInk.divider.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        var x = horizontalPadding
        let midY = bounds.midY
        let color = textColor
        switch icon {
        case .none: break
        case .liveDot:
            StudioInk.live.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - 5.5, width: 11, height: 11)).fill()
            StudioInk.live.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 2, y: midY - 3.5, width: 7, height: 7)).fill()
            x += 11 + 5
        case .symbol(let name):
            let tint = iconColor ?? (isOn ? StudioInk.accentText : (isEnabled ? StudioInk.primary : color))
            if let image = symbolImage(name, size: iconSize, weight: .medium, color: tint) {
                image.draw(in: NSRect(x: x, y: midY - image.size.height / 2, width: image.size.width,
                                      height: image.size.height))
                x += ceil(image.size.width) + 5
            }
        }
        func text(_ s: String, _ f: NSFont, _ c: NSColor) {
            let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
            let size = a.size()
            a.draw(at: NSPoint(x: x, y: midY - size.height / 2))
            x += ceil(size.width) + 5
        }
        if let prefix, showsTitle {
            text(prefix, NSFont.systemFont(ofSize: font.pointSize), isOn ? StudioInk.accentText : StudioInk.quiet)
        }
        if !shownTitle.isEmpty { text(shownTitle, titleFont, color) }
        if let suffix, showsTitle { text(suffix, NSFont.systemFont(ofSize: font.pointSize - 1), StudioInk.quiet) }
        if showsChevron,
           let image = symbolImage("chevron.down", size: 8, weight: .bold, color: isOn ? StudioInk.accentText : StudioInk.quiet) {
            image.draw(in: NSRect(x: x, y: midY - image.size.height / 2, width: image.size.width,
                                  height: image.size.height))
        }
    }

    // MARK: Pressing

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed {
            pressed = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if fire { perform() }
    }

    /// Runs the item's action (a click, VoiceOver's press, the self-tests).
    func perform() {
        guard isEnabled else { return }
        action?()
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let words = [prefix, title, suffix].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        setAccessibilityLabel(words.isEmpty ? toolTip : words)
        setAccessibilityEnabled(isEnabled)
    }

    override func accessibilityPerformPress() -> Bool {
        perform()
        return true
    }
}

/// Lays items out in a row with hairline dividers between them.
private func layoutRow(_ items: [NSView], dividers: [NSView], in bounds: NSRect, inset: CGFloat, gap: CGFloat) {
    var x = inset
    var dividerIndex = 0
    let visible = items.filter { !$0.isHidden }
    for (i, item) in visible.enumerated() {
        if i > 0, dividerIndex < dividers.count {
            let d = dividers[dividerIndex]
            d.isHidden = false
            d.frame = NSRect(x: x + gap / 2, y: bounds.midY - 8, width: 1, height: 16)
            x += gap + 1
            dividerIndex += 1
        }
        let w = item.intrinsicContentSize.width
        item.frame = NSRect(x: x, y: bounds.midY - StudioBarItem.height / 2, width: w, height: StudioBarItem.height)
        x += w
    }
    for d in dividers.dropFirst(dividerIndex) { d.isHidden = true }
}

private func rowWidth(_ items: [NSView], inset: CGFloat, gap: CGFloat) -> CGFloat {
    let visible = items.filter { !$0.isHidden }
    return visible.map { $0.intrinsicContentSize.width }.reduce(0, +) + CGFloat(max(visible.count - 1, 0)) * (gap + 1)
        + 2 * inset
}

/// A hairline between items.
final class StudioDivider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        StudioInk.divider.setFill()
        bounds.fill()
    }
}

// MARK: - The preview bar

/// The glass capsule at the bottom of the canvas: Preview: Light Mode ▾ · Backdrop ▾ · Data ▾ · Interact, and Back
/// to Live while a preset is in use. Everything on it changes only the Studio's view.
final class StudioPreviewBar: StudioCapsuleView {
    let appearanceItem = StudioBarItem()
    let backdropItem = StudioBarItem()
    let dataItem = StudioBarItem()
    let interactItem = StudioBarItem()
    let backToLiveItem = StudioBarItem()
    private var dividers: [StudioDivider] = []
    static let height: CGFloat = 40

    override init(standIn: Bool) {
        super.init(standIn: standIn)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StudioText[.previewBar])
        appearanceItem.icon = .symbol("eye")
        appearanceItem.prefix = StudioText[.previewPrefix]
        appearanceItem.showsChevron = true
        appearanceItem.toolTip = StudioText[.previewTip]
        backdropItem.icon = .symbol("photo")
        backdropItem.showsChevron = true
        backdropItem.toolTip = StudioText[.backdrop]
        dataItem.showsChevron = true
        dataItem.toolTip = StudioText[.dataTip]
        interactItem.icon = .symbol("hand.point.up.left")
        interactItem.title = StudioText[.interact]
        interactItem.toolTip = StudioText[.interactTip]
        backToLiveItem.title = StudioText[.backToLive]
        backToLiveItem.isLink = true
        for item in items { addSubview(item) }
        dividers = (0..<4).map { _ in StudioDivider() }
        for d in dividers { addSubview(d) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var items: [StudioBarItem] { [appearanceItem, backdropItem, dataItem, interactItem, backToLiveItem] }

    /// Shows `state` (`macIsDark`: the Mac's own look, for "Follow Mac"; `fidelity`: how close "Your Desktop" is).
    func show(_ state: StudioPreviewState, macIsDark: Bool, fidelity: WallpaperFidelity) {
        let dark: Bool
        switch state.appearance {
        case .followMac: dark = macIsDark
        case .light: dark = false
        case .dark: dark = true
        }
        appearanceItem.title = dark ? StudioText[.darkMode] : StudioText[.lightMode]
        appearanceItem.isOn = state.appearance != .followMac || state.glass != .standard
        backdropItem.title = state.backdrop.title
        // A sample picture is a preset of the preview (in the accent); the workbench and the others are where the user
        // likes to work, remembered, and read as plain choices.
        backdropItem.isOn = [.bright, .busy, .dark].contains(state.backdrop)
        backdropItem.suffix = state.backdrop == .desktop ? Self.fidelityWord(fidelity) : nil
        backdropItem.toolTip = state.backdrop == .desktop ? Self.fidelityTip(fidelity) : StudioText[.backdrop]
        dataItem.title = state.dataLabel
        dataItem.isOn = state.hasPreset
        dataItem.icon = state.hasPreset ? .symbol("chart.bar.fill") : .liveDot
        interactItem.isOn = state.interacting
        backToLiveItem.isHidden = !state.hasPreset
        needsLayout = true
    }

    static func fidelityWord(_ fidelity: WallpaperFidelity) -> String? {
        switch fidelity {
        case .exact: return nil
        case .similar: return StudioText[.backdropSimilar]
        case .close: return StudioText[.backdropClose]
        }
    }

    static func fidelityTip(_ fidelity: WallpaperFidelity) -> String? {
        switch fidelity {
        case .exact: return StudioText[.backdrop]
        case .similar: return StudioText[.backdropSimilarTip]
        case .close: return StudioText[.backdropCloseTip]
        }
    }

    /// The backdrop's words go first on a narrow canvas (its icon stays); "Preview:" and "Interact" keep theirs.
    var compact = false {
        didSet {
            backdropItem.showsTitle = !compact && !iconsOnly
            needsLayout = true
        }
    }

    /// Next to the code the bar is compact: the look and the backdrop keep only their icons; "Interact" keeps its word.
    var iconsOnly = false {
        didSet {
            appearanceItem.showsTitle = !iconsOnly
            backdropItem.showsTitle = !compact && !iconsOnly
            needsLayout = true
        }
    }

    var fittingWidth: CGFloat { rowWidth(items, inset: 5, gap: 2) }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: Self.height) }

    override func layout() {
        super.layout()
        layoutRow(items, dividers: dividers, in: bounds, inset: 5, gap: 2)
    }
}

// MARK: - The zoom capsule

/// − 165% + · Actual Size · Show on Desktop. On a narrow canvas "Actual Size" becomes "1:1" and "Show on Desktop"
/// "Desktop" (first of all the labels to go).
final class StudioZoomCapsule: StudioCapsuleView {
    let zoomOutItem = StudioBarItem()
    let percentItem = StudioBarItem()
    let zoomInItem = StudioBarItem()
    let actualSizeItem = StudioBarItem()
    let desktopItem = StudioBarItem()
    private var dividers: [StudioDivider] = []

    override init(standIn: Bool) {
        super.init(standIn: standIn)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StudioText[.zoomCapsule])
        zoomOutItem.icon = .symbol("minus")
        zoomOutItem.iconSize = 11
        zoomOutItem.horizontalPadding = 7
        zoomOutItem.setAccessibilityLabel(StudioText[.zoomOut])
        zoomOutItem.toolTip = StudioText[.zoomOut]
        percentItem.monospacedDigits = true
        percentItem.horizontalPadding = 3
        percentItem.toolTip = StudioText[.zoomToFit]
        zoomInItem.icon = .symbol("plus")
        zoomInItem.iconSize = 11
        zoomInItem.horizontalPadding = 7
        zoomInItem.toolTip = StudioText[.zoomIn]
        actualSizeItem.title = StudioText[.actualSize]
        actualSizeItem.horizontalPadding = 9
        actualSizeItem.toolTip = "\(StudioText[.actualSize]) (⌘0)"
        desktopItem.icon = .symbol("menubar.dock.rectangle")
        desktopItem.iconSize = 11.5
        desktopItem.title = StudioText[.showOnDesktop]
        desktopItem.horizontalPadding = 9
        desktopItem.toolTip = StudioText[.showOnDesktopTip]
        for item in [zoomOutItem, percentItem, zoomInItem, actualSizeItem, desktopItem] { addSubview(item) }
        dividers = (0..<2).map { _ in StudioDivider() }
        for d in dividers { addSubview(d) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var compact = false {
        didSet {
            actualSizeItem.title = compact ? StudioText[.actualSizeShort] : StudioText[.actualSize]
            desktopItem.title = compact ? StudioText[.showOnDesktopShort] : StudioText[.showOnDesktop]
            needsLayout = true
        }
    }

    func show(zoom: CGFloat, showingDesktop: Bool, canShowDesktop: Bool) {
        percentItem.title = StudioSizeName.zoomText(zoom)
        desktopItem.isOn = showingDesktop
        desktopItem.isEnabled = canShowDesktop
    }

    /// Next to the code the capsule leaves Actual Size out (⌘0 still does it).
    var hidesActualSize = false {
        didSet {
            actualSizeItem.isHidden = hidesActualSize
            needsLayout = true
        }
    }

    private var groups: [[StudioBarItem]] {
        [[zoomOutItem, percentItem, zoomInItem], [actualSizeItem], [desktopItem]].filter { $0.contains { !$0.isHidden } }
    }

    var fittingWidth: CGFloat {
        let items = groups.flatMap { $0 }.filter { !$0.isHidden }
        return items.map(\.width).reduce(0, +) + CGFloat(groups.count - 1) * 9 + 2 * 8
    }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: StudioPreviewBar.height) }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for (i, d) in dividers.enumerated() { d.isHidden = i >= groups.count - 1 }
        for (g, group) in groups.enumerated() {
            if g > 0 {
                dividers[g - 1].frame = NSRect(x: x + 4, y: bounds.midY - 8, width: 1, height: 16)
                x += 9
            }
            for item in group {
                let w = item.width
                item.frame = NSRect(x: x, y: bounds.midY - StudioBarItem.height / 2, width: w,
                                    height: StudioBarItem.height)
                x += w
            }
        }
    }
}

// MARK: - Capsules over the canvas

/// A capsule over the canvas that says something and may offer one thing to do: "Previewing sample data 100 % · your
/// desktop doesn't change", "Would open Activity Monitor · Open".
final class StudioStatusCapsule: StudioCapsuleView {
    let messageItem = StudioBarItem()
    let actionItem = StudioBarItem()
    private let divider = StudioDivider()
    static let height: CGFloat = 34

    override init(standIn: Bool) {
        super.init(standIn: standIn)
        messageItem.icon = .symbol("eye")
        messageItem.iconColor = .controlAccentColor
        messageItem.horizontalPadding = 12
        messageItem.isEnabled = true
        actionItem.isLink = true
        actionItem.horizontalPadding = 12
        addSubview(messageItem)
        addSubview(divider)
        addSubview(actionItem)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `message` (with `symbol` in the accent color) and, when given, an action.
    func show(_ message: String, symbol: String = "eye", action: String? = nil, perform: (() -> Void)? = nil) {
        messageItem.icon = .symbol(symbol)
        messageItem.isOn = false
        messageItem.title = message
        actionItem.title = action ?? ""
        actionItem.isHidden = action == nil
        actionItem.action = perform
        divider.isHidden = action == nil
        setAccessibilityLabel([message, action].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    var fittingWidth: CGFloat {
        messageItem.width + (actionItem.isHidden ? 0 : actionItem.width + 1) + 8
    }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: Self.height) }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        messageItem.frame = NSRect(x: x, y: bounds.midY - 15, width: messageItem.width, height: 30)
        x += messageItem.width
        divider.frame = NSRect(x: x, y: bounds.midY - 8, width: 1, height: 16)
        x += 1
        actionItem.frame = NSRect(x: x, y: bounds.midY - 15, width: actionItem.width, height: 30)
    }
}

/// The small tag above the widget on the canvas: "Preview 165% · Medium on your desktop". Says the zoom is the
/// preview's only, and what size the widget is on the desktop.
final class StudioCaptionTag: NSView {
    var text = "" {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
            setAccessibilityLabel(text)
        }
    }
    let usesStandIn: Bool

    init(standIn: Bool) {
        usesStandIn = standIn
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    private var symbol: NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            .applying(.init(paletteColors: [StudioInk.primary]))
        return NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    override var intrinsicContentSize: NSSize {
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: 7 + ceil(symbol?.size.width ?? 10) + 4 + w + 7, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 5, yRadius: 5)
        (dark ? NSColor(white: 0.18, alpha: 0.82) : NSColor(white: 0.97, alpha: 0.80)).setFill()
        path.fill()
        (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        var x: CGFloat = 7
        if let symbol {
            symbol.draw(in: NSRect(x: x, y: bounds.midY - symbol.size.height / 2, width: symbol.size.width,
                                   height: symbol.size.height))
            x += ceil(symbol.size.width) + 4
        }
        let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: StudioInk.primary])
        a.draw(at: NSPoint(x: x, y: bounds.midY - a.size().height / 2))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
