import AppKit
import DesksetCore

/// Show on Desktop (⇧⌘D, the zoom capsule's button): "is this real?" answered by the real thing. The Studio window
/// fades almost away; the widget's own window on the desktop — which follows every change — comes to the front with a
/// ring around it, and a capsule under it says "Your desktop, as it is now · Back to Studio · Esc".
///
/// A press switches it on (again, Esc or Back to Studio switches it off); holding ⇧⌘D peeks — letting go comes back.
/// Coming back puts the widget's window at its own level again and the Studio window at full strength. With Reduce
/// Motion the Studio window disappears and returns at once.
final class StudioDesktopView {
    /// The Studio window.
    weak var studioWindow: NSWindow?
    /// The widget's window on the desktop now (nil: not on the desktop).
    var widgetWindow: () -> NSWindow? = { nil }
    /// Whether windows are put on screen (not headless).
    var presentsWindows = true
    /// Told when it switches on or off.
    var onChange: (() -> Void)?

    private(set) var isShowing = false
    /// What coming back restores.
    private var saved: (studioAlpha: CGFloat, window: NSWindow, level: NSWindow.Level)?
    private(set) var ringPanel: NSPanel?
    private(set) var capsulePanel: NSPanel?
    private var monitor: Any?
    /// When the key that switched it on went down (a hold longer than `peekHold` comes back on release).
    private var keyPressedAt: TimeInterval?
    static let peekHold: TimeInterval = 0.4
    /// How faint the Studio window gets.
    static let fadedAlpha: CGFloat = 0.06

    /// The level the widget's window is raised to.
    static let raisedLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    deinit { removeMonitor() }

    var canShow: Bool { widgetWindow() != nil }

    /// Switches it on or off (`fromKey`: ⇧⌘D pressed now; a hold then peeks).
    func toggle(fromKey: Bool = false) {
        if isShowing { back() } else { show(fromKey: fromKey) }
    }

    func show(fromKey: Bool = false) {
        guard !isShowing, let widget = widgetWindow() else { return }
        isShowing = true
        keyPressedAt = fromKey ? ProcessInfo.processInfo.systemUptime : nil
        let studioAlpha = studioWindow?.alphaValue ?? 1
        saved = (studioAlpha, widget, widget.level)
        if widget.level.rawValue < Self.raisedLevel.rawValue { widget.level = Self.raisedLevel }
        if presentsWindows {
            widget.orderFrontRegardless()
            showRing(around: widget)
            installMonitor()
            if let studioWindow {
                NSAccessibility.post(element: studioWindow, notification: .announcementRequested,
                                     userInfo: [.announcement: StudioText[.showingDesktop],
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        StudioMotion.animate(0.2, { animated in
            let target = self.studioWindow
            if animated { target?.animator().alphaValue = Self.fadedAlpha } else { target?.alphaValue = Self.fadedAlpha }
        })
        onChange?()
    }

    /// Comes back: the widget's window at its own level, the Studio window at full strength, the ring gone.
    func back() {
        guard isShowing else { return }
        isShowing = false
        keyPressedAt = nil
        removeMonitor()
        ringPanel?.orderOut(nil)
        capsulePanel?.orderOut(nil)
        ringPanel = nil
        capsulePanel = nil
        if let saved {
            saved.window.level = saved.level
            let alpha = saved.studioAlpha
            // Set at once (an animation still running would otherwise end at the faded value), then shown.
            studioWindow?.alphaValue = alpha
            if presentsWindows, !StudioMotion.isReduced {
                studioWindow?.alphaValue = Self.fadedAlpha
                StudioMotion.animate(0.2, { _ in self.studioWindow?.animator().alphaValue = alpha })
            }
        }
        saved = nil
        if presentsWindows { studioWindow?.makeKeyAndOrderFront(nil) }
        onChange?()
    }

    // MARK: Keys

    /// Esc comes back; ⇧⌘D again switches off; letting go of a held ⇧⌘D comes back. True when the event was used.
    func handle(_ event: NSEvent) -> Bool {
        guard isShowing else { return false }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                back()
                return true
            }
            if Self.isShortcut(event) {
                if !event.isARepeat { back() }
                return true
            }
        case .keyUp:
            if event.charactersIgnoringModifiers?.lowercased() == "d" { releasedKey() }
        case .flagsChanged:
            if !event.modifierFlags.contains(.command) || !event.modifierFlags.contains(.shift) { releasedKey() }
        default:
            break
        }
        return false
    }

    /// ⇧⌘D.
    static func isShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return flags == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "d"
    }

    /// The key that switched it on was let go: after a hold, that was a peek.
    func releasedKey(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let pressed = keyPressedAt else { return }
        keyPressedAt = nil
        if now - pressed >= Self.peekHold { back() }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: The ring and the capsule

    private func showRing(around widget: NSWindow) {
        let frame = widget.frame
        let ring = Self.panel(frame: frame.insetBy(dx: -8, dy: -8), level: Self.raisedLevel, clicks: false)
        ring.contentView = StudioRingView()
        ring.orderFrontRegardless()
        ringPanel = ring

        let capsule = StudioDesktopCapsule()
        capsule.onBack = { [weak self] in self?.back() }
        let size = capsule.fittingSize
        let screen = widget.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - 16 - size.height)
        if origin.y < screen.minY + 8 { origin.y = frame.maxY + 16 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        let panel = Self.panel(frame: NSRect(origin: origin, size: size), level: Self.raisedLevel, clicks: true)
        panel.contentView = capsule
        panel.orderFrontRegardless()
        capsulePanel = panel
    }

    private static func panel(frame: NSRect, level: NSWindow.Level, clicks: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.ignoresMouseEvents = !clicks
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }
}

/// The ring around the widget while its desktop is shown.
final class StudioRingView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
        glow.shadowBlurRadius = 6
        glow.set()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// "Your desktop, as it is now · Back to Studio · Esc", under the widget.
final class StudioDesktopCapsule: NSView {
    var onBack: (() -> Void)?
    private let glass: NSView
    private let label = NSTextField(labelWithString: StudioText[.desktopAsItIs])
    private let button = NSButton(title: StudioText[.backToStudio], target: nil, action: nil)
    private let esc = NSTextField(labelWithString: StudioText[.escapeKey])
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *), SkinGlassViews.usesSystemGlass {
            glass = NSGlassEffectView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            glass = effect
        }
        super.init(frame: frameRect)
        addSubview(glass)
        icon.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        esc.font = .systemFont(ofSize: 12)
        esc.textColor = StudioInk.quiet
        button.bezelStyle = .push
        button.controlSize = .regular
        button.keyEquivalent = ""
        button.contentTintColor = .white
        button.bezelColor = .controlAccentColor
        button.target = self
        button.action = #selector(backClicked)
        let stack = NSStackView(views: [icon, label, button, esc])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StudioText[.desktopAsItIs])
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let radius = bounds.height / 2
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.cornerRadius = radius
        } else if let effect = glass as? NSVisualEffectView {
            effect.maskImage = SkinGlassViews.roundedMask(radius)
        }
    }

    @objc private func backClicked() { onBack?() }
}
