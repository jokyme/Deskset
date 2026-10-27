import AppKit
import DesksetCore

/// Skin tooltips (manual, Tooltips: ToolTipText, ToolTipTitle, ToolTipIcon, ToolTipType, ToolTipWidth). AppKit's own
/// tooltips show plain text only, so Deskset draws them: the system tooltip material, the title in bold on its own line
/// with the icon before it (`ToolTipIcon` "must be specified" with a title), the text wrapping at `ToolTipWidth`
/// (pixels on Windows, points here), and with `ToolTipType=1` a balloon whose stem points at the pointer.
///
/// One tooltip at a time for the whole app. It appears `SkinTooltips.initialDelay` after the pointer comes to rest over a
/// meter with a tooltip (sooner, `reshowDelay`, when moving straight from another tooltip), stays while the pointer
/// stays over the same tooltip, and goes on a press, a scroll, leaving the meter or the skin, or a change of the skin's
/// tooltip areas. Main thread only.
final class SkinToolTipPresenter {
    static let reshowDelay: TimeInterval = 0.1

    private unowned let app: AppController
    private(set) var shown: (view: SkinView, info: ToolTipInfo, layout: SkinToolTipLayout)?
    private(set) var pending: (view: SkinView, info: ToolTipInfo, point: NSPoint)?
    private var timer: Timer?
    private var panel: NSPanel?

    init(app: AppController) {
        self.app = app
    }

    /// The pointer is at `point` (screen coordinates) over `view`, where the tooltip is `info` (nil: none).
    func pointerMoved(in view: SkinView, info: ToolTipInfo?, at point: NSPoint) {
        if let shown, shown.view === view, shown.info == info { return }
        if let pending, pending.view === view, pending.info == info {
            self.pending?.point = point
            return
        }
        let wasShown = shown != nil
        hide()
        guard let info, !(info.text.isEmpty && info.title.isEmpty) else { return }
        pending = (view, info, point)
        let delay = wasShown ? SkinToolTipPresenter.reshowDelay : SkinTooltips.initialDelay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.showPending() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Hides the tooltip (and drops a pending one); with `view`, only one that belongs to that view.
    func hide(for view: SkinView? = nil) {
        if let view, shown?.view !== view && pending?.view !== view { return }
        timer?.invalidate()
        timer = nil
        pending = nil
        shown = nil
        panel?.orderOut(nil)
    }

    /// Shows the pending tooltip now (the timer's work; self-tests call it directly).
    func showPending() {
        timer?.invalidate()
        timer = nil
        guard let pending, let window = pending.view.window else { return }
        self.pending = nil
        let screen = NSScreen.screens.first { $0.frame.contains(pending.point) } ?? window.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
        let icon = SkinToolTipLayout.iconImage(pending.info, skinView: pending.view)
        let layout = SkinToolTipLayout(info: pending.info, hasIcon: icon != nil, pointer: pending.point, area: area)
        shown = (pending.view, pending.info, layout)
        guard app.presentsWindows else { return }
        let panel = self.panel ?? SkinToolTipPresenter.makePanel()
        self.panel = panel
        panel.contentView = SkinToolTipView(layout: layout, info: pending.info, icon: icon)
        panel.setFrame(layout.frame, display: true)
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, window.level.rawValue + 1))
        panel.orderFrontRegardless()
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

/// Where a tooltip's parts go, in points; `frame` is in screen coordinates, the rest in the tooltip's own (flipped)
/// coordinates.
struct SkinToolTipLayout: Equatable {
    static let textFont = NSFont.toolTipsFont(ofSize: 0)
    static var titleFont: NSFont { NSFont.boldSystemFont(ofSize: textFont.pointSize) }
    static let iconSize: CGFloat = 16
    static let stemWidth: CGFloat = 16
    static let stemHeight: CGFloat = 10
    /// Below the pointer, clear of the arrow cursor (Windows shows tooltips under the cursor).
    static let cursorClearance: CGFloat = 21

    var frame: NSRect
    /// The rounded body inside the frame (the frame minus the balloon's stem).
    var body: NSRect
    var cornerRadius: CGFloat
    /// Balloon: the stem's tip, on the body's top edge (`stemUp`) or bottom edge.
    var stemTip: NSPoint?
    var stemUp = true
    var iconFrame: NSRect?
    var titleFrame: NSRect?
    var textFrame: NSRect?

    init(info: ToolTipInfo, hasIcon: Bool, pointer: NSPoint, area: NSRect) {
        let balloon = info.balloon
        let padX: CGFloat = balloon ? 10 : 6, padY: CGFloat = balloon ? 8 : 4
        cornerRadius = balloon ? 8 : 4
        let showsTitle = !info.title.isEmpty
        let showsIcon = showsTitle && hasIcon
        // The title stays on one line ("Only one line of text can be used"); the text wraps at ToolTipWidth.
        let title = info.title.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let titleSize = showsTitle ? SkinToolTipLayout.measure(title, font: SkinToolTipLayout.titleFont, width: nil) : .zero
        let maxText = max(16, min(CGFloat(info.maxWidth), area.width - 16) - 2 * padX)
        let textSize = info.text.isEmpty ? .zero
            : SkinToolTipLayout.measure(info.text, font: SkinToolTipLayout.textFont, width: maxText)
        let iconSpace = showsIcon ? SkinToolTipLayout.iconSize + 6 : 0
        let titleRow = showsTitle ? max(titleSize.height, showsIcon ? SkinToolTipLayout.iconSize : 0) : 0
        let gap: CGFloat = showsTitle && textSize.height > 0 ? 3 : 0
        let contentWidth = max(iconSpace + titleSize.width, textSize.width)
        let bodySize = NSSize(width: ceil(contentWidth + 2 * padX), height: ceil(titleRow + gap + textSize.height + 2 * padY))
        let stem = balloon ? SkinToolTipLayout.stemHeight : 0
        let size = NSSize(width: bodySize.width, height: bodySize.height + stem)

        // Below the pointer when it fits, otherwise above (a balloon's stem flips with it).
        var origin = NSPoint(x: balloon ? pointer.x - 2 * cornerRadius - SkinToolTipLayout.stemWidth / 2 : pointer.x,
                             y: balloon ? pointer.y - size.height : pointer.y - SkinToolTipLayout.cursorClearance - size.height)
        var up = true
        if origin.y < area.minY {
            up = false
            origin.y = balloon ? pointer.y : pointer.y + 4
        }
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        stemUp = up
        body = NSRect(x: 0, y: balloon && up ? stem : 0, width: bodySize.width, height: bodySize.height)
        if balloon {
            let lowest = cornerRadius + SkinToolTipLayout.stemWidth / 2
            let tipX = min(max(pointer.x - frame.minX, lowest), max(lowest, size.width - lowest))
            stemTip = NSPoint(x: tipX, y: up ? 0 : size.height)
        }
        var y = body.minY + padY
        if showsTitle {
            if showsIcon {
                iconFrame = NSRect(x: padX, y: y + (titleRow - SkinToolTipLayout.iconSize) / 2,
                                   width: SkinToolTipLayout.iconSize, height: SkinToolTipLayout.iconSize)
            }
            titleFrame = NSRect(x: padX + iconSpace, y: y + (titleRow - titleSize.height) / 2,
                                width: ceil(titleSize.width), height: ceil(titleSize.height))
            y += titleRow + gap
        }
        if textSize.height > 0 {
            textFrame = NSRect(x: padX, y: y, width: ceil(textSize.width), height: ceil(textSize.height))
        }
    }

    static func measure(_ text: String, font: NSFont, width: CGFloat?) -> NSSize {
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: NSSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// `ToolTipIcon`: the preset icons as SF Symbols in their usual colors, or an icon file (an `.ico` or any image the
    /// system reads); nil without a title, for an unknown preset or an unreadable file.
    static func iconImage(_ info: ToolTipInfo, skinView: SkinView?) -> NSImage? {
        let raw = info.icon.trimmingCharacters(in: .whitespaces)
        guard !info.title.isEmpty, !raw.isEmpty else { return nil }
        let presets: [String: (String, NSColor)] = [
            "info": ("info.circle.fill", .systemBlue), "warning": ("exclamationmark.triangle.fill", .systemYellow),
            "error": ("xmark.octagon.fill", .systemRed), "question": ("questionmark.circle.fill", .systemBlue),
            "shield": ("checkmark.shield.fill", .systemBlue),
        ]
        if let (symbol, color) = presets[raw.lowercased()] {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: raw)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: iconSize - 2, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color])))
        }
        guard raw.hasPrefix("/"), let image = NSImage(contentsOfFile: raw), image.isValid else { return nil }
        image.size = NSSize(width: iconSize, height: iconSize)
        return image
    }
}

/// Draws a tooltip: the system tooltip material in the tooltip's shape, then a hairline border, the icon, the title
/// and the text on top of it.
final class SkinToolTipView: NSView {
    let layout: SkinToolTipLayout

    init(layout: SkinToolTipLayout, info: ToolTipInfo, icon: NSImage?) {
        self.layout = layout
        super.init(frame: NSRect(origin: .zero, size: layout.frame.size))
        let material = NSVisualEffectView(frame: bounds)
        material.material = .toolTip
        material.state = .active
        material.maskImage = NSImage(size: bounds.size, flipped: true) { [layout] _ in
            NSColor.black.setFill()
            SkinToolTipView.shape(layout).fill()
            return true
        }
        addSubview(material)
        let content = Content(frame: bounds, layout: layout)
        content.title = info.title.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        content.text = info.text
        content.icon = layout.iconFrame == nil ? nil : icon
        addSubview(content)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private final class Content: NSView {
        let layout: SkinToolTipLayout
        var title = "", text = ""
        var icon: NSImage?

        init(frame: NSRect, layout: SkinToolTipLayout) {
            self.layout = layout
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let path = SkinToolTipView.shape(layout)
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
            if let frame = layout.iconFrame, let icon {
                icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Drawn with the options they were measured with, so the text wraps where the layout expects.
            if let frame = layout.titleFrame { draw(title, font: SkinToolTipLayout.titleFont, in: frame) }
            if let frame = layout.textFrame { draw(text, font: SkinToolTipLayout.textFont, in: frame) }
        }

        private func draw(_ string: String, font: NSFont, in frame: NSRect) {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                .draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// One outline: the body with rounded corners and, for a balloon, the stem on its top or bottom edge.
    static func shape(_ layout: SkinToolTipLayout) -> NSBezierPath {
        let b = layout.body.insetBy(dx: 0.5, dy: 0.5)
        let r = min(layout.cornerRadius, b.width / 2, b.height / 2)
        guard let tip = layout.stemTip else { return NSBezierPath(roundedRect: b, xRadius: r, yRadius: r) }
        let half = SkinToolTipLayout.stemWidth / 2
        let tipY = layout.stemUp ? tip.y + 0.5 : tip.y - 0.5
        // Flipped coordinates: minY is the top edge. Clockwise from the top-left corner.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX + r, y: b.minY))
        if layout.stemUp {
            path.line(to: NSPoint(x: tip.x - half, y: b.minY))
            path.line(to: NSPoint(x: tip.x, y: tipY))
            path.line(to: NSPoint(x: tip.x + half, y: b.minY))
        }
        path.appendArc(from: NSPoint(x: b.maxX, y: b.minY), to: NSPoint(x: b.maxX, y: b.maxY), radius: r)
        path.appendArc(from: NSPoint(x: b.maxX, y: b.maxY), to: NSPoint(x: b.minX, y: b.maxY), radius: r)
        if !layout.stemUp {
            path.line(to: NSPoint(x: tip.x + half, y: b.maxY))
            path.line(to: NSPoint(x: tip.x, y: tipY))
            path.line(to: NSPoint(x: tip.x - half, y: b.maxY))
        }
        path.appendArc(from: NSPoint(x: b.minX, y: b.maxY), to: NSPoint(x: b.minX, y: b.minY), radius: r)
        path.appendArc(from: NSPoint(x: b.minX, y: b.minY), to: NSPoint(x: b.maxX, y: b.minY), radius: r)
        path.close()
        return path
    }
}
