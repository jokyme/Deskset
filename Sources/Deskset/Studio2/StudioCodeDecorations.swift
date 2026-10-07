import AppKit
import DeskLanguage
import DesksetCore

/// What the code pane draws around the text of `CodeEditorView` without changing it: each diagnostic's card under its
/// line (the text makes room through the layout manager's paragraph spacing — the text itself is untouched), a dot in
/// the line-number column and a wavy line under what it is about, and the accent bar beside the selected part's block.
final class StudioCodeDecorations: NSObject, NSLayoutManagerDelegate {
    private(set) weak var codeView: CodeEditorView?
    let overlay = StudioCodeOverlay()
    /// The diagnostics of the file shown, with their sentences.
    private(set) var items: [(diagnostic: IniDiagnostic, message: String)] = []
    /// The card under each line that has one (the most severe diagnostic of the line).
    private(set) var cards: [Int: StudioDiagnosticCard] = [:]
    /// The room each card takes under its line.
    private var spacing: [Int: CGFloat] = [:]
    private var laidOutWidth: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    var onFix: ((IniDiagnostic) -> Void)?

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func attach(to codeView: CodeEditorView) {
        self.codeView = codeView
        codeView.textView.layoutManager?.delegate = self
        overlay.decorations = self
        overlay.frame = codeView.scrollView.bounds
        overlay.autoresizingMask = [.width, .height]
        codeView.scrollView.addSubview(overlay)
        let clip = codeView.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.overlay.needsDisplay = true
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: codeView.textView, queue: .main) { [weak self] _ in
                self?.placeCards()
                self?.overlay.needsDisplay = true
            })
    }

    /// Shows `items` (the diagnostics of the file shown, with their sentences).
    func show(_ items: [(diagnostic: IniDiagnostic, message: String)]) {
        guard let codeView else { return }
        let lineCount = codeView.lineStarts.count
        let kept = items.filter { $0.diagnostic.line >= 1 && $0.diagnostic.line <= lineCount }
        let same = kept.map(\.diagnostic) == self.items.map(\.diagnostic) && kept.map(\.message) == self.items.map(\.message)
        self.items = kept
        if !same {
            cards.values.forEach { $0.removeFromSuperview() }
            cards = [:]
            for item in kept.sorted(by: { $0.diagnostic.severity > $1.diagnostic.severity })
                where cards[item.diagnostic.line] == nil {
                let card = StudioDiagnosticCard(item.diagnostic, message: item.message, onFix: onFix)
                cards[item.diagnostic.line] = card
                codeView.textView.addSubview(card)
            }
            laidOutWidth = 0
        }
        layoutChanged()
    }

    /// The text's width may have changed: the cards' heights follow, and the text makes room again.
    func layoutChanged() {
        guard let codeView, let lm = codeView.textView.layoutManager else { return }
        let width = codeView.textView.bounds.width
        if width != laidOutWidth {
            laidOutWidth = width
            var next: [Int: CGFloat] = [:]
            for (line, card) in cards {
                next[line] = StudioDiagnosticCard.height(for: card.message, width: width, fix: card.fixButton != nil)
            }
            spacing = next
            let length = codeView.textView.textStorage?.length ?? 0
            lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
        }
        placeCards()
        overlay.needsDisplay = true
    }

    /// Puts each card in the room under its line.
    func placeCards() {
        guard let codeView, let lm = codeView.textView.layoutManager, !cards.isEmpty else { return }
        let tv = codeView.textView
        let origin = tv.textContainerOrigin
        for (line, card) in cards {
            guard let fragment = lastFragment(ofLine: line, lm) else {
                card.isHidden = true
                continue
            }
            let room = spacing[line] ?? 0
            card.isHidden = false
            card.frame = NSRect(x: 0, y: origin.y + fragment.maxY - room, width: tv.bounds.width, height: room)
            card.needsLayout = true
        }
    }

    // MARK: Lines

    private func lineStart(_ line: Int) -> Int? {
        guard let codeView else { return nil }
        let starts = codeView.lineStarts
        guard line >= 1, line <= starts.count else { return nil }
        return starts[line - 1]
    }

    /// The characters of `line` without its line ending.
    func range(ofLine line: Int) -> NSRange? {
        guard let codeView, let start = lineStart(line), let storage = codeView.textView.textStorage else { return nil }
        let starts = codeView.lineStarts
        var end = line < starts.count ? starts[line] : storage.length
        let text = storage.string as NSString
        while end > start, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The line fragment holding the end of `line` (its line ending when it has one).
    private func lastFragment(ofLine line: Int, _ lm: NSLayoutManager) -> NSRect? {
        guard let codeView, let start = lineStart(line), let storage = codeView.textView.textStorage else { return nil }
        let starts = codeView.lineStarts
        let end = line < starts.count ? starts[line] : storage.length
        guard storage.length > 0 else { return nil }
        let last = max(start, min(end, storage.length) - 1)
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(last + 1, storage.length)))
        let glyph = lm.glyphIndexForCharacter(at: last)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func firstFragment(ofLine line: Int, _ lm: NSLayoutManager) -> NSRect? {
        guard let codeView, let start = lineStart(line), let storage = codeView.textView.textStorage else { return nil }
        if start >= storage.length {
            let extra = lm.extraLineFragmentRect
            return extra.isEmpty ? nil : extra
        }
        let glyph = lm.glyphIndexForCharacter(at: start)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func line(ofCharacter index: Int) -> Int {
        guard let codeView else { return 0 }
        let starts = codeView.lineStarts
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard !spacing.isEmpty, let storage = layoutManager.textStorage, storage.length > 0 else { return 0 }
        let index = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard index < storage.length else { return 0 }
        let text = storage.string as NSString
        let c = text.character(at: index)
        let ends = c == 0x0A || (c == 0x0D && !(index + 1 < text.length && text.character(at: index + 1) == 0x0A))
            || index == text.length - 1
        guard ends else { return 0 }
        return spacing[line(ofCharacter: index)] ?? 0
    }

    // MARK: Drawing

    /// The accent bar, the dots and the wavy lines, in `view` (over the scroll view).
    func draw(in view: NSView) {
        guard let codeView, let lm = codeView.textView.layoutManager else { return }
        let tv = codeView.textView
        let origin = tv.textContainerOrigin
        func toView(_ r: NSRect) -> NSRect {
            view.convert(r.offsetBy(dx: origin.x, dy: origin.y), from: tv)
        }
        // The selected part's block: an accent bar at the column's edge, beside its lines only (not their cards).
        if let tint = tv.tintRange, tint.length > 0 {
            let first = line(ofCharacter: tint.location)
            let last = line(ofCharacter: max(tint.location, NSMaxRange(tint) - 1))
            NSColor.controlAccentColor.setFill()
            for l in first...max(first, last) {
                guard let top = firstFragment(ofLine: l, lm), let bottom = lastFragment(ofLine: l, lm) else { continue }
                let r = toView(NSRect(x: 0, y: top.minY, width: 1, height: bottom.maxY - (spacing[l] ?? 0) - top.minY))
                NSRect(x: 0, y: r.minY, width: 2, height: r.height).fill()
            }
        }
        for (diagnostic, _) in items {
            let color = StudioCodeColors.color(diagnostic.severity)
            guard let lineRange = range(ofLine: diagnostic.line), let top = firstFragment(ofLine: diagnostic.line, lm)
            else { continue }
            // The dot in the line numbers' column.
            let r = toView(top)
            color.setFill()
            let usedHeight = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(lineRange.location,
                max((tv.textStorage?.length ?? 1) - 1, 0))), effectiveRange: nil).height
            let midY = r.minY + min(usedHeight, r.height) / 2
            NSBezierPath(ovalIn: NSRect(x: 5, y: midY - 3.5, width: 7, height: 7)).fill()
            // The wavy line under what it is about.
            let start = lineRange.location + min(diagnostic.column, lineRange.length)
            let length = min(diagnostic.length, NSMaxRange(lineRange) - start)
            guard length > 0 else { continue }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: start, length: length), actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, fragmentGlyphs, _ in
                let part = NSIntersectionRange(glyphs, fragmentGlyphs)
                guard part.length > 0 else { return }
                let bounds = lm.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + lm.location(forGlyphAt: part.location).y
                let line = toView(NSRect(x: bounds.minX, y: baseline + 2, width: bounds.width, height: 3))
                Self.squiggle(in: line, color: color)
            }
        }
    }

    static func squiggle(in r: NSRect, color: NSColor) {
        let path = NSBezierPath()
        var x = r.minX
        var up = true
        path.move(to: NSPoint(x: x, y: r.midY))
        while x < r.maxX {
            let next = min(x + 3, r.maxX)
            path.line(to: NSPoint(x: next, y: up ? r.minY : r.maxY))
            up.toggle()
            x = next
        }
        path.lineWidth = 1.2
        color.setStroke()
        path.stroke()
    }
}

/// The code pane's plane over the text and the line numbers (it takes no clicks).
final class StudioCodeOverlay: NSView {
    weak var decorations: StudioCodeDecorations?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        decorations?.draw(in: self)
    }
}


// MARK: - Desk diagnostics

/// A standalone Desk document's gutter and squiggles. Details never change text layout or open note locations.
/// The INI decoration owner above keeps its original input, drawing, one-card-per-line rule and fix callback.
final class DeskCodeDecorations: NSObject {
    private(set) weak var codeView: CodeEditorView?
    let overlay = DeskCodeOverlay()
    private(set) var items: [DeskServiceDiagnostic] = []
    private(set) var cards: [DeskDiagnosticCard] = []
    private(set) var markers: [Int: DeskDiagnosticMarker] = [:]
    private(set) var detailsPanel: NSPanel?
    private(set) var detailsLine: Int?
    /// The hovered glyph width and native fragment height, or a gutter's full fragment, in overlay coordinates.
    private(set) var detailsAnchor: NSRect?
    private(set) var diagnosticRegions: [DeskDiagnosticRegion] = []
    private var cardLines: [Int] = []
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var originalAccessoryWidth: CGFloat = 0
    private var originalFrameNotifications = false
    private var originalBoundsNotifications = false
    private var shownRevision: Int?
    private var shownText: String?
    private var layingOut = false
    private var receipt: UUID?
    private var hoveredLine: Int?
    private var pendingHoverLine: Int?
    private var pendingHoverAnchor: NSRect?
    private var hoverTimer: Timer?
    private var closeTimer: Timer?
    private var insideDetails = false
    private var menuTracking = false
    private var pinnedDetails = false
    private var keyMonitor: Any?

    deinit { detach() }

    func attach(to codeView: CodeEditorView) {
        detach()
        self.codeView = codeView
        let tv = codeView.textView
        originalAccessoryWidth = codeView.ruler.leadingAccessoryWidth
        originalFrameNotifications = tv.postsFrameChangedNotifications
        originalBoundsNotifications = codeView.scrollView.contentView.postsBoundsChangedNotifications
        codeView.ruler.leadingAccessoryWidth = originalAccessoryWidth + 20
        overlay.decorations = self
        overlay.frame = codeView.scrollView.bounds
        overlay.autoresizingMask = [.width, .height]
        codeView.scrollView.addSubview(overlay)
        observeWindow(codeView.window)
        tv.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main) {
            [weak self] _ in self?.layoutChanged()
        })
        let clip = codeView.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
            [weak self] _ in self?.layoutChanged()
        })
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                            object: tv.textStorage, queue: .main) { [weak self] _ in
            guard let self, let editor = self.codeView else { return }
            if !(self.shownText?.utf8.elementsEqual(editor.text.utf8) ?? true) { self.clear() }
            else { self.layoutChanged() }
        })
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: tv, queue: .main) {
            [weak self] _ in
            guard let self, let editor = self.codeView else { return }
            if self.shownRevision != editor.textRevision
                || !(self.shownText?.utf8.elementsEqual(editor.text.utf8) ?? false) { self.clear() }
            else { self.layoutChanged() }
        })
    }

    /// The caller supplies the current check. A stale text or malformed range is refused as a whole, never clamped.
    @discardableResult
    func show(_ diagnostics: [DeskServiceDiagnostic], file: DeskFileID, text: String,
              language: DiagnosticLanguage, actions: ((DeskServiceDiagnostic) -> [DeskCodeAction])? = nil,
              onAction: ((DeskCodeAction) -> Void)? = nil) -> Bool {
        guard let codeView, text.utf8.elementsEqual(codeView.text.utf8) else { clear(); return false }
        let nextIndex = DeskTextIndex(text)
        let own = diagnostics.filter { $0.file == file }
        guard own.allSatisfy({ Self.valid($0.range, in: nextIndex) }) else { clear(); return false }
        clear()
        items = own
        shownRevision = codeView.textRevision
        shownText = text
        let nextReceipt = UUID()
        receipt = nextReceipt
        cards = own.map { diagnostic in
            let card = DeskDiagnosticCard(diagnostic, language: language, actions: actions?(diagnostic) ?? [],
                onAction: onAction.map { callback in
                    { [weak self] action in
                        guard let self, self.receipt == nextReceipt, self.isCurrent else { return }
                        callback(action)
                    }
                })
            card.onMenuTracking = { [weak self] tracking in
                guard let self, self.receipt == nextReceipt else { return }
                self.menuTracking = tracking
                if tracking { self.cancelPendingClose() } else { self.scheduleClose() }
            }
            return card
        }
        cardLines = own.map { nextIndex.position(utf16: $0.range.start.offset).line + 1 }
        let byLine = Dictionary(grouping: own.indices, by: { cardLines[$0] })
        for line in byLine.keys.sorted() {
            guard let best = byLine[line]?.max(by: { Self.rank(own[$0].severity) < Self.rank(own[$1].severity) }) else { continue }
            let highest = own[best]
            let marker = DeskDiagnosticMarker(line: line, severity: highest.severity)
            marker.decorations = self
            marker.setAccessibilityLabel(StudioText.format(.statusLine, line) + "\n"
                + cards[best].titleLabel.stringValue + "\n" + highest.message)
            markers[line] = marker
            overlay.addSubview(marker)
        }
        layoutChanged()
        return true
    }

    private static func valid(_ range: DeskRange, in index: DeskTextIndex) -> Bool {
        let start = range.start.offset, end = range.end.offset
        return start >= 0 && end >= start && end <= index.utf16Count
            && index.clampedUTF16(start) == start && index.clampedUTF16(end) == end
    }

    func clear() {
        receipt = nil
        closeDetails()
        cards.forEach { $0.removeFromSuperview() }
        markers.values.forEach { $0.removeFromSuperview() }
        markers = [:]
        items = []
        cards = []
        cardLines = []
        diagnosticRegions = []
        shownRevision = nil
        shownText = nil
        layoutChanged()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        observeWindow(nil)
        clear()
        if let editor = codeView {
            let tv = editor.textView
            editor.ruler.leadingAccessoryWidth = originalAccessoryWidth
            tv.postsFrameChangedNotifications = originalFrameNotifications
            editor.scrollView.contentView.postsBoundsChangedNotifications = originalBoundsNotifications
        }
        overlay.removeFromSuperview()
        overlay.decorations = nil
        codeView = nil
    }

    /// Markers follow native line fragments. Diagnostics reserve no paragraph spacing or document height.
    func layoutChanged() {
        guard !layingOut, let editor = codeView, let lm = editor.textView.layoutManager,
              let container = editor.textView.textContainer else { return }
        layingOut = true
        defer { layingOut = false }
        closeDetails()
        editor.layoutSubtreeIfNeeded()
        overlay.frame = editor.scrollView.bounds
        let tv = editor.textView
        lm.ensureLayout(for: container)
        diagnosticRegions = nativeRegions()
        let gutterX = overlay.convert(NSPoint(x: 2, y: 0), from: editor.ruler).x
        let visible = overlay.convert(editor.scrollView.contentView.bounds, from: editor.scrollView.contentView)
        for (line, marker) in markers {
            guard let fragment = lineFragment(line, last: false) else { marker.isHidden = true; continue }
            let rect = overlay.convert(fragment.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y), from: tv)
            let height = max(10, min(20, fragment.height))
            marker.frame = NSRect(x: gutterX, y: rect.minY + (fragment.height - height) / 2, width: 16, height: height)
            marker.isHidden = marker.frame.maxY <= visible.minY || marker.frame.minY >= visible.maxY
        }
        overlay.needsDisplay = true
    }

    /// The overlay may be attached before its document receives a window.
    func observeWindow(_ window: NSWindow?) {
        guard observedWindow !== window || (window == nil && !windowObservers.isEmpty) else { return }
        closeDetails()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        observedWindow = window
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.willCloseNotification, NSWindow.didMoveNotification,
            NSWindow.didResizeNotification, NSWindow.willMiniaturizeNotification, NSWindow.didResignKeyNotification]
        for name in names {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                guard let self, name != NSWindow.didResignKeyNotification || !self.menuTracking else { return }
                self.closeDetails()
            })
        }
        windowObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.closeDetails() })
    }

    private func lineFragment(_ line: Int, last: Bool) -> NSRect? {
        guard let editor = codeView, let lm = editor.textView.layoutManager,
              let storage = editor.textView.textStorage, line >= 1, line <= editor.lineStarts.count else { return nil }
        let start = editor.lineStarts[line - 1]
        guard start <= storage.length else { return nil }
        if start == storage.length {
            guard let container = editor.textView.textContainer else { return nil }
            lm.ensureLayout(for: container)
            let extra = lm.extraLineFragmentRect
            return extra.isEmpty ? nil : extra
        }
        let end = line < editor.lineStarts.count ? editor.lineStarts[line] : storage.length
        let character = last ? max(start, end - 1) : start
        lm.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: character), effectiveRange: nil)
    }

    private var isCurrent: Bool {
        guard let editor = codeView, shownRevision == editor.textRevision, let shownText else { return false }
        return shownText.utf8.elementsEqual(editor.text.utf8)
    }

    private static func rank(_ severity: Severity) -> Int {
        switch severity { case .error: return 2; case .warning: return 1; case .info: return 0 }
    }

    /// Headless editors construct the same content without showing a native window.
    @discardableResult
    func showDetails(forLine line: Int, hover: Bool = false) -> Bool {
        guard isCurrent, let editor = codeView, let marker = markers[line], !marker.isHidden else { return false }
        guard let fragment = lineFragment(line, last: false) else { return false }
        let origin = editor.textView.textContainerOrigin
        let anchor = overlay.convert(fragment.offsetBy(dx: origin.x, dy: origin.y), from: editor.textView)
        return showDetails(forLine: line, anchor: anchor, hover: hover)
    }

    private func showDetails(forLine line: Int, anchor: NSRect, hover: Bool) -> Bool {
        guard isCurrent, let editor = codeView else { return false }
        let selected = zip(cardLines, cards).filter { $0.0 == line }.map { $0.1 }
        guard !selected.isEmpty else { return false }
        closeDetails()
        hoveredLine = hover ? line : nil
        pinnedDetails = !hover
        let parent = editor.window
        let available = parent.map { window -> NSRect in
            let content = window.contentView
            let rect = content.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? window.frame
            let screen = window.screen?.visibleFrame ?? rect
            let visible = rect.intersection(screen)
            return (visible.isEmpty ? rect : visible).insetBy(dx: 4, dy: 4)
        }
        let width = min(440, max(1, available?.width ?? (editor.bounds.width - 32)))
        let content = StudioPopoverContentView()
        let document = StudioPopoverContentView()
        var y: CGFloat = 4
        for card in selected {
            card.actionMenu?.refusesFirstResponder = true
            let height = DeskDiagnosticCard.height(for: card, width: width)
            card.frame = NSRect(x: 0, y: y, width: width, height: height)
            card.needsLayout = true
            document.addSubview(card)
            y += height
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y + 4)
        let screenAnchor = parent.map { $0.convertToScreen(overlay.convert(anchor, to: nil)) }
        let naturalSize = NSSize(width: width, height: min(420, y + 4))
        let frame: NSRect
        if let screenAnchor, let available {
            frame = Self.placementFrame(anchor: screenAnchor, size: naturalSize, within: available)
        } else {
            frame = NSRect(origin: .zero, size: naturalSize)
        }
        let height = frame.height
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = y + 4 > height
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.autoresizingMask = [.width, .height]
        content.frame = scroll.frame
        content.wantsLayer = true
        content.layer?.borderWidth = 0.5
        content.addSubview(scroll)
        content.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
            userInfo: ["deskDetails": true]))
        let next = DeskDiagnosticPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        next.isReleasedWhenClosed = false
        next.isOpaque = true
        next.backgroundColor = .textBackgroundColor
        next.hasShadow = true
        next.becomesKeyOnlyIfNeeded = true
        next.animationBehavior = .none
        next.isExcludedFromWindowsMenu = true
        next.tabbingMode = .disallowed
        next.appearance = editor.effectiveAppearance
        next.contentView = content
        next.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            content.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        detailsPanel = next
        detailsLine = line
        detailsAnchor = anchor
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self, let panel = self.detailsPanel else { return event }
            // Native menus own their tracking events, including the first Escape and the action click.
            guard !self.menuTracking else { return event }
            if event.type == .keyDown {
                guard event.window === self.codeView?.window || event.window === panel else { return event }
                if event.keyCode == 53 { self.closeDetails(); return nil }
                if event.keyCode == 125, let marker = self.codeView?.window?.firstResponder as? DeskDiagnosticMarker,
                   self.detailsLine == marker.line, self.openActionMenu(forLine: marker.line) { return nil }
            } else if event.window !== panel {
                self.closeDetails()
            }
            return event
        }
        if let parent, parent.isVisible {
            next.level = parent.level
            next.collectionBehavior = parent.collectionBehavior
            parent.addChildWindow(next, ordered: .above)
            next.orderFront(nil)
        }
        return true
    }

    /// Screen coordinates grow upward. Prefer below, then above; narrow windows and long details remain scrollable.
    static func placementFrame(anchor: NSRect, size: NSSize, within area: NSRect) -> NSRect {
        let gap: CGFloat = 4
        let below = max(0, anchor.minY - gap - area.minY)
        let above = max(0, area.maxY - anchor.maxY - gap)
        let useBelow = size.height <= below || (size.height > above && below >= above)
        let height = min(size.height, max(1, useBelow ? below : above))
        let width = min(size.width, max(1, area.width))
        let y = useBelow ? anchor.minY - gap - height : anchor.maxY + gap
        return WindowGeometry.clamp(NSRect(x: anchor.minX, y: y, width: width, height: height), into: area)
    }

    /// The focused gutter marker keeps keyboard ownership; Down opens the same native quick-fix menu.
    @discardableResult
    func openActionMenu(forLine line: Int) -> Bool {
        guard isCurrent, detailsLine == line, detailsPanel?.isVisible == true,
              let card = zip(cardLines, cards).first(where: { $0.0 == line && $0.1.actionMenu != nil })?.1,
              let button = card.actionMenu, let menu = button.menu else { return false }
        menu.popUp(positioning: menu.items.dropFirst().first,
                   at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY + 4), in: button)
        return true
    }

    func closeDetails() {
        let trackingMenus = menuTracking ? cards.compactMap { $0.actionMenu?.menu } : []
        hoverTimer?.invalidate(); hoverTimer = nil
        pendingHoverLine = nil
        pendingHoverAnchor = nil
        hoveredLine = nil
        cancelPendingClose()
        insideDetails = false
        menuTracking = false
        pinnedDetails = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        let previous = detailsPanel
        detailsPanel = nil
        detailsLine = nil
        detailsAnchor = nil
        trackingMenus.forEach { $0.cancelTracking() }
        if let previous {
            previous.parent?.removeChildWindow(previous)
            previous.orderOut(nil)
            previous.close()
        }
        cards.forEach { $0.removeFromSuperview() }
    }

    func beginHover(atLine line: Int) {
        guard isCurrent, markers[line]?.isHidden == false, let editor = codeView,
              let fragment = lineFragment(line, last: false) else { return }
        let origin = editor.textView.textContainerOrigin
        beginHover(atLine: line, anchor: overlay.convert(fragment.offsetBy(dx: origin.x, dy: origin.y), from: editor.textView))
    }

    private func beginHover(atLine line: Int, anchor: NSRect) {
        guard isCurrent else { return }
        hoveredLine = line
        cancelPendingClose()
        if pendingHoverLine == line && pendingHoverAnchor == anchor { return }
        hoverTimer?.invalidate()
        hoverTimer = nil
        pendingHoverLine = nil
        pendingHoverAnchor = nil
        guard detailsLine != line || detailsAnchor != anchor else { return }
        pendingHoverLine = line
        pendingHoverAnchor = anchor
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in _ = self?.openPendingHover() }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func endHover(atLine line: Int) {
        guard hoveredLine == line else { return }
        hoveredLine = nil
        hoverTimer?.invalidate(); hoverTimer = nil
        pendingHoverLine = nil
        pendingHoverAnchor = nil
        scheduleClose()
    }

    /// Shared by the native tracking area and controlled event tests.
    func detailsHovered(_ inside: Bool) {
        insideDetails = inside
        if inside { cancelPendingClose() } else { scheduleClose() }
    }

    @objc func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["deskDetails"] as? Bool == true { detailsHovered(true) }
    }

    @objc func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["deskDetails"] as? Bool == true { detailsHovered(false) }
    }

    private func openPendingHover() -> Bool {
        guard let line = pendingHoverLine, let anchor = pendingHoverAnchor else { return false }
        hoverTimer?.invalidate(); hoverTimer = nil
        pendingHoverLine = nil
        pendingHoverAnchor = nil
        guard NSEvent.pressedMouseButtons == 0 else { return false }
        return showDetails(forLine: line, anchor: anchor, hover: true)
    }

    private func cancelPendingClose() {
        closeTimer?.invalidate(); closeTimer = nil
    }

    private func scheduleClose() {
        cancelPendingClose()
        guard detailsPanel != nil, !pinnedDetails, hoveredLine == nil, !insideDetails, !menuTracking else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in _ = self?.closePendingHover() }
        closeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func closePendingHover() -> Bool {
        guard closeTimer != nil else { return false }
        cancelPendingClose()
        guard !pinnedDetails, hoveredLine == nil, !insideDetails, !menuTracking else { return false }
        closeDetails()
        return true
    }

    @discardableResult
    func firePendingHoverForTesting() -> Bool { openPendingHover() }
    @discardableResult
    func firePendingHoverCloseForTesting() -> Bool { closePendingHover() }

    /// Tracking observes the overlay without making it the hit-test target for code clicks or selection.
    func hover(at point: NSPoint) {
        guard isCurrent, NSEvent.pressedMouseButtons == 0, let editor = codeView else { return endCodeHover() }
        if markers.values.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return }
        let visible = overlay.convert(editor.scrollView.contentView.bounds, from: editor.scrollView.contentView)
        guard visible.contains(point), let region = diagnosticRegions.first(where: { $0.hitRect.contains(point) }) else {
            return endCodeHover()
        }
        let anchor = NSRect(x: region.squiggleRect.minX, y: region.fragmentRect.minY,
                            width: region.squiggleRect.width, height: region.fragmentRect.height)
        beginHover(atLine: region.line, anchor: anchor)
    }

    func endCodeHover() {
        if let line = hoveredLine { endHover(atLine: line) }
    }

    func draw(in view: NSView) {
        guard isCurrent else { return }
        for region in diagnosticRegions {
            StudioCodeDecorations.squiggle(in: view.convert(region.squiggleRect, from: overlay),
                                          color: DeskDiagnosticCard.color(items[region.diagnosticIndex].severity))
        }
    }

    /// Both paint and hover use the same native fragments; UTF-16 ranges were validated before reaching TextKit.
    private func nativeRegions() -> [DeskDiagnosticRegion] {
        guard isCurrent, let editor = codeView, let lm = editor.textView.layoutManager else { return [] }
        let tv = editor.textView
        let origin = tv.textContainerOrigin
        func converted(_ rect: NSRect) -> NSRect { overlay.convert(rect.offsetBy(dx: origin.x, dy: origin.y), from: tv) }
        var regions: [DeskDiagnosticRegion] = []
        func append(_ index: Int, squiggle: NSRect, fragment: NSRect) {
            let wave = converted(squiggle), line = converted(fragment)
            // A tooltip is reachable over the affected glyphs, not only a three-pixel underline.
            let hit = NSRect(x: wave.minX - 2, y: line.minY, width: wave.width + 4,
                             height: max(line.maxY, wave.maxY + 2) - line.minY)
            regions.append(DeskDiagnosticRegion(diagnosticIndex: index, line: cardLines[index],
                squiggleRect: wave, hitRect: hit, fragmentRect: line))
        }
        for (index, diagnostic) in items.enumerated() {
            let range = diagnostic.range.nsRange
            if range.length == 0 {
                guard let anchor = emptyAnchor(at: range.location) else { continue }
                append(index, squiggle: anchor.squiggle, fragment: anchor.fragment)
                continue
            }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, fragmentGlyphs, _ in
                let part = NSIntersectionRange(glyphs, fragmentGlyphs)
                guard part.length > 0 else { return }
                let bounds = lm.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + lm.location(forGlyphAt: part.location).y
                append(index, squiggle: NSRect(x: bounds.minX, y: baseline + 2,
                                              width: max(6, bounds.width), height: 3), fragment: fragment)
            }
        }
        return regions
    }

    private func emptyAnchor(at offset: Int) -> (squiggle: NSRect, fragment: NSRect)? {
        guard let editor = codeView, let lm = editor.textView.layoutManager,
              let container = editor.textView.textContainer, let storage = editor.textView.textStorage else { return nil }
        lm.ensureLayout(for: container)
        if offset < storage.length {
            let glyph = lm.glyphIndexForCharacter(at: offset)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = lm.location(forGlyphAt: glyph)
            return (NSRect(x: fragment.minX + position.x, y: fragment.minY + position.y + 2, width: 6, height: 3), fragment)
        }
        let extra = lm.extraLineFragmentRect
        if !extra.isEmpty { return (NSRect(x: extra.minX, y: extra.maxY - 3, width: 6, height: 3), extra) }
        guard lm.numberOfGlyphs > 0 else { return nil }
        let glyph = lm.numberOfGlyphs - 1
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let bounds = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return (NSRect(x: bounds.maxX, y: fragment.minY + lm.location(forGlyphAt: glyph).y + 2, width: 6, height: 3), fragment)
    }
}

/// Native text-container rectangles converted once to the pass-through overlay.
struct DeskDiagnosticRegion {
    let diagnosticIndex: Int
    let line: Int
    let squiggleRect: NSRect
    let hitRect: NSRect
    let fragmentRect: NSRect
}

private final class DeskDiagnosticPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DeskCodeOverlay: NSView {
    weak var decorations: DeskCodeDecorations?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { decorations?.layoutChanged() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        decorations?.observeWindow(newWindow)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        decorations?.hover(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { decorations?.endCodeHover() }
    override func draw(_ dirtyRect: NSRect) { decorations?.draw(in: self) }
}

/// One native button per physical line. The number remains selectable beside its reserved gutter.
final class DeskDiagnosticMarker: NSControl {
    let line: Int
    let severity: Severity
    weak var decorations: DeskCodeDecorations?
    private var tracking: NSTrackingArea?

    init(line: Int, severity: Severity) {
        self.line = line; self.severity = severity
        super.init(frame: .zero)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var current: Bool { decorations?.markers[line] === self }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if current { decorations?.beginHover(atLine: line) }
    }
    override func mouseExited(with event: NSEvent) {
        if current { decorations?.endHover(atLine: line) }
    }
    override func mouseDown(with event: NSEvent) {
        // Reading a diagnostic keeps the text responder; leaving it would implicitly save a dirty buffer.
    }
    override func mouseUp(with event: NSEvent) {
        if current, bounds.contains(convert(event.locationInWindow, from: nil)) { _ = decorations?.showDetails(forLine: line) }
    }
    override func accessibilityPerformPress() -> Bool {
        current && (decorations?.showDetails(forLine: line) ?? false)
    }
    override func keyDown(with event: NSEvent) {
        guard current else { return }
        if event.keyCode == 53 { decorations?.closeDetails() }
        else if [36, 49, 76].contains(event.keyCode) { _ = decorations?.showDetails(forLine: line) }
        else if event.keyCode == 125, decorations?.openActionMenu(forLine: line) == true { return }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let symbol: String
        switch severity {
        case .error: symbol = "xmark.octagon.fill"
        case .warning: symbol = "exclamationmark.triangle.fill"
        case .info: symbol = "info.circle.fill"
        }
        let size = min(11, bounds.height - 2)
        if let image = StudioCodeColors.badge(symbol, size: size, color: DeskDiagnosticCard.color(severity)) {
            image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                                 width: image.size.width, height: image.size.height))
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        }
    }
}
