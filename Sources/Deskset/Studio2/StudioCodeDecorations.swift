import AppKit
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
