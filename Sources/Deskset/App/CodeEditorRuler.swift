import AppKit
import DesksetCore

/// Line numbers for the code editor (an NSRulerView on the text view's scroll view). Numbers are 1-based file lines —
/// CR, LF and CRLF each end a line, exactly as in `IniSyntax` and the inspector's source locations — drawn for the
/// visible line fragments only; a soft-wrapped line gets one number. The caret's line number is darker, the tinted
/// section shows as a band, and clicking a number selects that line.
final class CodeEditorRuler: NSRulerView {
    weak var editor: CodeEditorView?
    var font = CodeEditorTheme.lineNumberFont(size: CodeEditorView.defaultFontSize) {
        didSet { needsDisplay = true }
    }
    private var digits = 0

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        // macOS 14 changed NSView's clipsToBounds default; without it a custom ruler draws over the text.
        clipsToBounds = true
        ruleThickness = 36
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var textView: NSTextView? { clientView as? NSTextView }

    /// Flipped like the text view: numbers are drawn from the top of their line fragment.
    override var isFlipped: Bool { true }

    override var requiredThickness: CGFloat { ruleThickness }

    /// Grows (or shrinks) the ruler with the number of digits of the last line number.
    func updateThickness(lineCount: Int, force: Bool = false) {
        let count = max(3, String(max(lineCount, 1)).count)
        guard force || count != digits else { return }
        digits = count
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(count) * digitWidth + 18)
        if thickness != ruleThickness { ruleThickness = thickness }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, let editor else { return }
        let text = storage.mutableString as NSString
        let length = text.length

        if let tint = editor.textView.tintRange, let band = editor.textView.lineRect(forCharacterRange: tint) {
            let y = convert(NSPoint(x: 0, y: band.minY), from: textView).y
            let bandRect = NSRect(x: 0, y: y, width: bounds.width, height: band.height)
            if bandRect.intersects(rect) {
                CodeEditorTheme.sectionTint.setFill()
                bandRect.fill(using: .sourceOver)
            }
        }

        let lineStarts = editor.lineStarts
        let caretLine = editor.caretLine
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let lastCharacter = NSMaxRange(characters)
        // The first line that starts at or before the first visible character.
        var index = 0, high = lineStarts.count - 1
        while index < high {
            let mid = (index + high + 1) / 2
            if lineStarts[mid] <= characters.location { index = mid } else { high = mid - 1 }
        }
        let inset = textView.textContainerOrigin.y
        let right = bounds.width - 8
        // Empty lines have no glyph to measure (a line break's location is not on the baseline): use the font's.
        let emptyLineBaseline = layoutManager.defaultBaselineOffset(for: textView.font ?? font)
        while index < lineStarts.count {
            let start = lineStarts[index]
            if start > lastCharacter { break }
            let fragment: NSRect
            var baseline = emptyLineBaseline
            if start < length {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let c = text.character(at: start)
                if c != 0x0A && c != 0x0D { baseline = layoutManager.location(forGlyphAt: glyph).y }
            } else {
                // The empty line after a final line break (or of an empty file).
                fragment = layoutManager.extraLineFragmentRect
                guard !fragment.isEmpty else { break }
            }
            let top = convert(NSPoint(x: 0, y: fragment.minY + inset), from: textView).y
            if top > rect.maxY + fragment.height { break }
            let number = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: index + 1 == caretLine ? CodeEditorTheme.rulerCurrentText : CodeEditorTheme.rulerText,
            ]
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: right - size.width, y: top + baseline - font.ascender), withAttributes: attributes)
            index += 1
        }
    }

    // MARK: Clicks

    /// Clicking a number selects its line (a user action: the caret is reported like any other move).
    override func mouseDown(with event: NSEvent) {
        guard let textView, let editor else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let index = textView.characterIndexForInsertion(at: NSPoint(x: textView.textContainerOrigin.x + 1, y: point.y))
        editor.selectLine(containingOffset: index)
        window?.makeFirstResponder(textView)
    }
}
