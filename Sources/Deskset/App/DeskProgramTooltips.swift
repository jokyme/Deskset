import AppKit
import DesksetCore

/// Main-only presentation of an already evaluated tooltip. Adapters own accepted-scene qualification and
/// coordinate mapping; this object never reads a runtime, samples data or asks an owner thread for work.
final class DeskProgramTooltips {
    struct Revision: Equatable {
        let session: UUID
        let epoch: UInt64
        let generation: UInt64
    }
    struct Target: Equatable {
        let id: ElementID
        let info: ToolTipInfo
        let revision: Revision
    }

    /// Keep the first explicit tooltip, including an empty one that suppresses an ancestor. Desk's complete
    /// reverse-preorder hit map supplies box/rounding/preset geometry; the INI area registration limit does not apply.
    static func target(in map: SkinHitMap, at point: SkinPoint, revision: Revision) -> Target? {
        guard point.x.isFinite, point.y.isFinite, !map.toolTipHidden else { return nil }
        for entry in map.entries where entry.toolTip != nil && map.isHit(entry, x: point.x, y: point.y, images: nil) {
            guard let id = entry.elementID, let info = entry.toolTip else { return nil }
            return Target(id: id, info: info, revision: revision)
        }
        return nil
    }

    private weak var view: NSView?
    private let executor: SkinExecutor
    private let defaults: UserDefaults
    private let pointerLocation: () -> NSPoint
    private let screens: () -> [WindowGeometry.Screen]
    private let presentsWindows: Bool
    private let targetAt: (NSPoint) -> Target?
    private var scheduled: SkinScheduledWork?
    private var ticket = UUID()
    private var windowIdentity: ObjectIdentifier?
    private var windowObservers: [NSObjectProtocol] = []
    private var hovering = false
    private(set) var isClosed = false
    private(set) var selectedTarget: Target?
    private(set) var shownTarget: Target?
    private(set) var panel: NSPanel?
    var pending: Bool { scheduled?.isPending == true }
    var attributedText: NSAttributedString? {
        guard shownTarget != nil else { return nil }
        return (panel?.contentView?.subviews.first as? NSTextField)?.attributedStringValue
    }

    /// Inject a Main-owned virtual executor and screen pointer in native tests. `presentsWindows: false` still
    /// creates and lays out the real AppKit panel, but never attaches or orders it onto the user's desktop.
    /// The adapter's targetAt closure must capture its controller/view weakly.
    init(view: NSView, executor: SkinExecutor = MainSkinExecutor.shared, defaults: UserDefaults = .standard,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         screens: @escaping () -> [WindowGeometry.Screen] = { WindowGeometry.currentScreens() },
         presentsWindows: Bool = true, targetAt: @escaping (NSPoint) -> Target?) {
        precondition(Thread.isMainThread && executor.isCurrent)
        self.view = view; self.executor = executor; self.defaults = defaults
        self.pointerLocation = pointerLocation; self.screens = screens
        self.presentsWindows = presentsWindows; self.targetAt = targetAt
    }

    func mouseMoved(at point: NSPoint) {
        precondition(Thread.isMainThread && executor.isCurrent)
        guard !isClosed else { return }
        hovering = true
        update(at: point)
    }

    func mouseExited() { stopHovering() }
    func mouseDown() { stopHovering() }

    private func stopHovering() {
        precondition(Thread.isMainThread && executor.isCurrent)
        hovering = false
        cancel()
    }

    /// Accepted frames and scroll/zoom changes reselect at the real screen point. Ordinary clock generations
    /// retain elapsed dwell time; an epoch/session/window change starts a new hover. A press suppresses refresh
    /// until another mouse move, so a new frame cannot reopen the panel while dragging or opening a menu.
    func refresh() {
        precondition(Thread.isMainThread && executor.isCurrent)
        guard !isClosed, hovering else { return }
        guard let point = localPointer() else { cancel(); return }
        update(at: point)
    }

    func cancel() {
        precondition(Thread.isMainThread && executor.isCurrent)
        ticket = UUID()
        scheduled?.cancel(); scheduled = nil
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        selectedTarget = nil; windowIdentity = nil
        hide()
    }

    func close() {
        precondition(Thread.isMainThread && executor.isCurrent)
        guard !isClosed else { return }
        isClosed = true; hovering = false
        cancel()
        panel?.close(); panel = nil
    }

    private func localPointer() -> NSPoint? {
        guard let view, let window = view.window else { return nil }
        let screen = pointerLocation()
        guard screen.x.isFinite, screen.y.isFinite else { return nil }
        return view.convert(window.convertPoint(fromScreen: screen), from: nil)
    }

    private func eligibleWindow(at point: NSPoint) -> NSWindow? {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor,
              point.x.isFinite, point.y.isFinite, view.visibleRect.contains(point) else { return nil }
        if presentsWindows && (!window.isVisible || window.isMiniaturized || window.ignoresMouseEvents ||
            !window.occlusionState.contains(.visible)) { return nil }
        return window
    }

    private func update(at point: NSPoint) {
        guard let window = eligibleWindow(at: point), let target = targetAt(point) else { cancel(); return }
        let sameHover = selectedTarget.map {
            $0.id == target.id && $0.revision.session == target.revision.session &&
                $0.revision.epoch == target.revision.epoch && windowIdentity == ObjectIdentifier(window)
        } ?? false
        if !sameHover { cancel() }
        selectedTarget = target; windowIdentity = ObjectIdentifier(window)
        observe(window)
        guard !target.info.text.isEmpty || !target.info.title.isEmpty else {
            scheduled?.cancel(); scheduled = nil; ticket = UUID(); hide()
            return
        }
        if shownTarget != nil {
            show(target, in: window)
        } else if !pending {
            let currentTicket = UUID()
            ticket = currentTicket
            scheduled = executor.async(after: initialDelay) { [weak self] in self?.reveal(currentTicket) }
        }
    }

    var initialDelay: TimeInterval {
        let fallback = Double(SkinTooltips.initialDelayMilliseconds)
        let milliseconds = defaults.object(forKey: "NSInitialToolTipDelay") == nil ? fallback :
            defaults.double(forKey: "NSInitialToolTipDelay")
        // Malformed preferences cannot create NaN or an overflowing DispatchTime deadline.
        guard milliseconds.isFinite, milliseconds >= 0,
              milliseconds / 1000 < Double(Int.max) / 1_000_000_000 else { return fallback / 1000 }
        return milliseconds / 1000
    }

    private func reveal(_ currentTicket: UUID) {
        precondition(Thread.isMainThread && executor.isCurrent)
        guard !isClosed, hovering, ticket == currentTicket else { return }
        scheduled = nil
        guard let point = localPointer(), let window = eligibleWindow(at: point),
              windowIdentity == ObjectIdentifier(window), let selectedTarget,
              targetAt(point) == selectedTarget else { cancel(); return }
        show(selectedTarget, in: window)
    }

    private func observe(_ window: NSWindow) {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                guard let self, let window, self.windowIdentity == ObjectIdentifier(window) else { return }
                self.stopHovering()
            })
        }
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self, weak window] _ in
            guard let self, let window, self.windowIdentity == ObjectIdentifier(window) else { return }
            if !window.isVisible || window.isMiniaturized || !window.occlusionState.contains(.visible) {
                self.stopHovering()
            }
        })
    }

    private func show(_ target: Target, in parent: NSWindow) {
        guard let view, !target.info.text.isEmpty || !target.info.title.isEmpty else { hide(); return }
        let pointer = pointerLocation(), displays = screens()
        guard pointer.x.isFinite, pointer.y.isFinite,
              let index = WindowGeometry.screenIndex(for: CGRect(origin: pointer, size: NSSize(width: 1, height: 1)), screens: displays)
        else { hide(); return }
        let available = displays[index].visibleFrame.insetBy(dx: 4, dy: 4)
        let inset = NSSize(width: 8, height: 6)
        guard available.width > inset.width * 2, available.height > inset.height * 2 else { hide(); return }
        let maximum = target.info.maxWidth.isFinite && target.info.maxWidth > 0 ? target.info.maxWidth : 1000
        let width = min(CGFloat(maximum), available.width - inset.width * 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let normal = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let words = NSMutableAttributedString(string: "")
        if !target.info.title.isEmpty {
            words.append(NSAttributedString(string: target.info.title, attributes: [
                .font: NSFont.boldSystemFont(ofSize: normal.pointSize), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph]))
            if !target.info.text.isEmpty { words.append(NSAttributedString(string: "\n", attributes: [.font: normal])) }
        }
        if !target.info.text.isEmpty {
            words.append(NSAttributedString(string: target.info.text, attributes: [
                .font: normal, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        let measured = words.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = NSSize(width: min(width, max(1, ceil(measured.width) + 2)),
            height: min(available.height - inset.height * 2, max(ceil(normal.ascender - normal.descender), ceil(measured.height) + 2)))
        let size = NSSize(width: textSize.width + inset.width * 2, height: textSize.height + inset.height * 2)
        let frame = WindowGeometry.clamp(NSRect(x: pointer.x + 12, y: pointer.y - size.height - 16,
            width: size.width, height: size.height), into: available)
        let tip: NSPanel
        if let panel { tip = panel }
        else {
            tip = DeskProgramTooltipPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            tip.isReleasedWhenClosed = false; tip.isOpaque = false; tip.backgroundColor = .clear
            tip.hasShadow = true; tip.hidesOnDeactivate = false; tip.ignoresMouseEvents = true
            tip.animationBehavior = .none; tip.isExcludedFromWindowsMenu = true; tip.tabbingMode = .disallowed
            tip.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
            panel = tip
        }
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 5; content.layer?.borderWidth = 0.5
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = words; label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = textSize.width
        label.frame = NSRect(origin: NSPoint(x: inset.width, y: inset.height), size: textSize)
        content.addSubview(label)
        content.setAccessibilityRole(.helpTag)
        tip.appearance = view.effectiveAppearance
        tip.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            content.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        tip.contentView = content
        tip.setFrame(frame, display: false)
        shownTarget = target
        if presentsWindows {
            if tip.parent !== parent {
                tip.parent?.removeChildWindow(tip)
                parent.addChildWindow(tip, ordered: .above)
            }
            tip.orderFrontRegardless()
        }
    }

    private func hide() {
        shownTarget = nil
        panel?.orderOut(nil)
        if let panel { panel.parent?.removeChildWindow(panel) }
    }

    deinit {
        scheduled?.cancel()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        if let panel {
            precondition(Thread.isMainThread)
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
    }
}

private final class DeskProgramTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
