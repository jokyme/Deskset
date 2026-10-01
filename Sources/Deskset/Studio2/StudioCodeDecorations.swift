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


// MARK: - Read-only Desk diagnostics

/// A standalone Desk document's own TextKit decoration owner. It never changes the text or opens note locations.
/// The INI decoration owner above keeps its original input, drawing, one-card-per-line rule and fix callback.
final class DeskCodeDecorations: NSObject, NSLayoutManagerDelegate {
    private(set) weak var codeView: CodeEditorView?
    let overlay = DeskCodeOverlay()
    private(set) var items: [DeskServiceDiagnostic] = []
    private(set) var cards: [DeskDiagnosticCard] = []
    private var cardLines: [Int] = []
    private var spacing: [Int: CGFloat] = [:]
    private var observers: [NSObjectProtocol] = []
    private weak var previousLayoutDelegate: NSLayoutManagerDelegate?
    private var originalMinSize = NSSize.zero
    private var originalFrameNotifications = false
    private var originalBoundsNotifications = false
    private var shownRevision: Int?
    private var shownText: String?
    private var index = DeskTextIndex("")
    private var layingOut = false
    private var laidOutWidth: CGFloat = 0

    deinit { detach() }

    func attach(to codeView: CodeEditorView) {
        detach()
        self.codeView = codeView
        let tv = codeView.textView
        previousLayoutDelegate = tv.layoutManager?.delegate
        originalMinSize = tv.minSize
        originalFrameNotifications = tv.postsFrameChangedNotifications
        originalBoundsNotifications = codeView.scrollView.contentView.postsBoundsChangedNotifications
        tv.layoutManager?.delegate = self
        overlay.decorations = self
        overlay.frame = codeView.scrollView.bounds
        overlay.autoresizingMask = [.width, .height]
        codeView.scrollView.addSubview(overlay)
        tv.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main) {
            [weak self] _ in self?.layoutChanged()
        })
        let clip = codeView.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
            [weak self] _ in self?.overlay.needsDisplay = true
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
              language: DiagnosticLanguage) -> Bool {
        guard let codeView, text.utf8.elementsEqual(codeView.text.utf8) else { clear(); return false }
        let nextIndex = DeskTextIndex(text)
        let own = diagnostics.filter { $0.file == file }
        guard own.allSatisfy({ Self.valid($0.range, in: nextIndex) }) else { clear(); return false }
        cards.forEach { $0.removeFromSuperview() }
        items = own
        index = nextIndex
        shownRevision = codeView.textRevision
        shownText = text
        cards = own.map { DeskDiagnosticCard($0, language: language) }
        cardLines = own.map { nextIndex.position(utf16: $0.range.start.offset).line + 1 }
        cards.forEach { codeView.textView.addSubview($0) }
        layoutChanged()
        return true
    }

    private static func valid(_ range: DeskRange, in index: DeskTextIndex) -> Bool {
        let start = range.start.offset, end = range.end.offset
        return start >= 0 && end >= start && end <= index.utf16Count
            && index.clampedUTF16(start) == start && index.clampedUTF16(end) == end
    }

    func clear() {
        cards.forEach { $0.removeFromSuperview() }
        items = []
        cards = []
        cardLines = []
        shownRevision = nil
        shownText = nil
        layoutChanged()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        clear()
        if let editor = codeView {
            let tv = editor.textView
            if tv.layoutManager?.delegate === self { tv.layoutManager?.delegate = previousLayoutDelegate }
            tv.minSize = originalMinSize
            tv.postsFrameChangedNotifications = originalFrameNotifications
            editor.scrollView.contentView.postsBoundsChangedNotifications = originalBoundsNotifications
            tv.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: tv.string.utf16.count),
                                                actualCharacterRange: nil)
            tv.sizeToFit()
        }
        overlay.removeFromSuperview()
        overlay.decorations = nil
        previousLayoutDelegate = nil
        codeView = nil
    }

    /// TextKit reserves the whole stack on newline-terminated lines. The final visual line gets scrollable room
    /// below its actual last fragment; no character, paragraph attribute or undo record is inserted into the document.
    func layoutChanged() {
        guard !layingOut, let editor = codeView, let lm = editor.textView.layoutManager,
              let container = editor.textView.textContainer else { return }
        layingOut = true
        defer { layingOut = false }
        editor.layoutSubtreeIfNeeded()
        overlay.frame = editor.scrollView.bounds
        let tv = editor.textView
        var next: [Int: CGFloat] = [:]
        for (line, card) in zip(cardLines, cards) {
            next[line, default: 0] += DeskDiagnosticCard.height(for: card, width: tv.bounds.width)
        }
        let changedSpacing = next != spacing
        let changedWidth = tv.bounds.width != laidOutWidth
        laidOutWidth = tv.bounds.width
        if changedSpacing || changedWidth {
            spacing = next
            lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: tv.string.utf16.count),
                                actualCharacterRange: nil)
        }
        lm.ensureLayout(for: container)
        var minimum = originalMinSize.height
        if let room = spacing[editor.lineStarts.count],
           let anchor = lineFragment(editor.lineStarts.count, last: true) {
            minimum = max(minimum, tv.textContainerOrigin.y + anchor.maxY + room + tv.textContainerInset.height)
        }
        let nextMinimum = NSSize(width: originalMinSize.width, height: minimum)
        let changedMinimum = tv.minSize != nextMinimum
        tv.minSize = nextMinimum
        if changedSpacing || changedWidth || changedMinimum { tv.sizeToFit() }
        var placed: [Int: CGFloat] = [:]
        for (line, card) in zip(cardLines, cards) {
            guard let fragment = lineFragment(line, last: true) else { card.isHidden = true; continue }
            let room = line < editor.lineStarts.count ? (spacing[line] ?? 0) : 0
            let y = tv.textContainerOrigin.y + fragment.maxY - room + (placed[line] ?? 0)
            let height = DeskDiagnosticCard.height(for: card, width: tv.bounds.width)
            card.isHidden = false
            card.frame = NSRect(x: 0, y: y, width: tv.bounds.width, height: height)
            card.needsLayout = true
            placed[line, default: 0] += height
        }
        overlay.needsDisplay = true
    }

    private func lineFragment(_ line: Int, last: Bool) -> NSRect? {
        guard let editor = codeView, let lm = editor.textView.layoutManager,
              let storage = editor.textView.textStorage, line >= 1, line <= editor.lineStarts.count else { return nil }
        let start = editor.lineStarts[line - 1]
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

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard !spacing.isEmpty, let storage = layoutManager.textStorage, glyphIndex < layoutManager.numberOfGlyphs else { return 0 }
        let offset = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard offset < storage.length else { return 0 }
        let text = storage.string as NSString
        let characters = layoutManager.characterRange(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                      actualGlyphRange: nil)
        let end = NSMaxRange(characters)
        guard end > 0, end <= storage.length else { return 0 }
        let last = text.character(at: end - 1)
        let ends = last == 0x0A || last == 0x0D
        return ends ? (spacing[index.position(utf16: offset).line + 1] ?? 0) : 0
    }

    func draw(in view: NSView) {
        guard let editor = codeView, let lm = editor.textView.layoutManager else { return }
        let tv = editor.textView
        let origin = tv.textContainerOrigin
        func converted(_ rect: NSRect) -> NSRect { view.convert(rect.offsetBy(dx: origin.x, dy: origin.y), from: tv) }
        for diagnostic in items {
            let color = DeskDiagnosticCard.color(diagnostic.severity)
            let range = diagnostic.range.nsRange
            let line = index.position(utf16: range.location).line + 1
            if let fragment = lineFragment(line, last: false) {
                let dot = converted(fragment)
                color.setFill()
                let start = editor.lineStarts[line - 1]
                let used = start < tv.string.utf16.count
                    ? lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil).height
                    : lm.extraLineFragmentUsedRect.height
                NSBezierPath(ovalIn: NSRect(x: 5, y: dot.minY + min(used, fragment.height) / 2 - 3.5,
                                          width: 7, height: 7)).fill()
            }
            if range.length == 0 {
                guard let anchor = emptyAnchor(at: range.location) else { continue }
                StudioCodeDecorations.squiggle(in: converted(anchor), color: color)
                continue
            }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, fragmentGlyphs, _ in
                let part = NSIntersectionRange(glyphs, fragmentGlyphs)
                guard part.length > 0 else { return }
                let bounds = lm.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + lm.location(forGlyphAt: part.location).y
                StudioCodeDecorations.squiggle(in: converted(NSRect(x: bounds.minX, y: baseline + 2,
                                                                    width: max(6, bounds.width), height: 3)), color: color)
            }
        }
    }

    private func emptyAnchor(at offset: Int) -> NSRect? {
        guard let editor = codeView, let lm = editor.textView.layoutManager,
              let container = editor.textView.textContainer, let storage = editor.textView.textStorage else { return nil }
        lm.ensureLayout(for: container)
        if offset < storage.length {
            let glyph = lm.glyphIndexForCharacter(at: offset)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = lm.location(forGlyphAt: glyph)
            return NSRect(x: fragment.minX + position.x, y: fragment.minY + position.y + 2, width: 6, height: 3)
        }
        let extra = lm.extraLineFragmentRect
        if !extra.isEmpty { return NSRect(x: extra.minX, y: extra.maxY - 3, width: 6, height: 3) }
        guard lm.numberOfGlyphs > 0 else { return nil }
        let glyph = lm.numberOfGlyphs - 1
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let bounds = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSRect(x: bounds.maxX, y: fragment.minY + lm.location(forGlyphAt: glyph).y + 2, width: 6, height: 3)
    }
}

final class DeskCodeOverlay: NSView {
    weak var decorations: DeskCodeDecorations?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { decorations?.draw(in: self) }
}
