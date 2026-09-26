import AppKit
import DesksetCore

/// Editing a text layer's words right on the canvas (docs/editor-friendly.md §9.4): a field placed exactly over the
/// text, in the layer's font and alignment (it is a subview of the canvas, so the zoom scales it like the text), while
/// the layer's own words are made invisible by a preview. Return writes `Text=` as one undo step "Edit Text", Esc
/// cancels, and clicking elsewhere commits.
final class InlineTextEditor: NSTextField, NSTextFieldDelegate {
    /// The text layer edited.
    let section: String
    /// Its words as written (what Esc keeps).
    let original: String
    /// Called once when editing ends: true to write the words.
    var onEnd: ((Bool) -> Void)?
    private var ended = false

    init(section: String, text: String) {
        self.section = section
        original = text
        super.init(frame: .zero)
        stringValue = text
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        placeholderString = SkinCanvasView.placeholderText
        delegate = self
        setAccessibilityLabel("Text")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Ends editing (once): writes the words when `commit`, else leaves them.
    func end(commit: Bool) {
        guard !ended else { return }
        ended = true
        onEnd?(commit)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            end(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            end(commit: false)
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere (the field loses the keyboard focus) commits.
    func controlTextDidEndEditing(_ obj: Notification) {
        end(commit: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A quiet accent rim shows where the words are being edited.
        let accent = NSColor.controlAccentColor.withAlphaComponent(0.8)
        accent.setStroke()
        let rim = NSBezierPath(rect: bounds.insetBy(dx: 0.25, dy: 0.25))
        rim.lineWidth = 0.5
        rim.stroke()
        super.draw(dirtyRect)
    }
}

extension InspectorWindowController {
    /// Whether a text layer's words can be edited on the canvas: its `Text` is plain words — no `%1`, `#Variable#`
    /// (`#CRLF#` included), `[Section]` or data shown — without text before or after (Prefix / Postfix) or styled
    /// parts (InlineSetting).
    func canEditTextInPlace(_ name: String) -> Bool {
        guard let skin, let m = skin.meter(named: name), m is StringMeter, m.measures.isEmpty,
              (m.rawOption("MeasureName") ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let text = m.rawOption("Text") ?? ""
        if text.contains("#") || text.range(of: "%[0-9]", options: .regularExpression) != nil
            || text.range(of: #"\[[^\]]+\]"#, options: .regularExpression) != nil { return false }
        for key in ["Prefix", "Postfix", "InlineSetting"] {
            if !(m.rawOption(key) ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    /// Starts editing a text layer's words on the canvas ([Edit Text] in the identity strip, a double-click). False
    /// when its words can't be edited there (`canEditTextInPlace`).
    @discardableResult
    func beginInlineTextEdit(_ name: String) -> Bool {
        commitPendingNudge()
        guard canEditTextInPlace(name), let skin, let m = skin.meter(named: name) as? StringMeter else { return false }
        endInlineTextEdit(commit: true)
        if canvas.selectedNames != [m.name] { canvasSelectionChanged([m.name]) }
        let editor = InlineTextEditor(section: m.name, text: m.rawOption("Text") ?? "")
        let style = m.style
        editor.font = Fonts.font(for: style)
        editor.textColor = style.color.a > 20 ? style.color.nsColor.withAlphaComponent(1) : .labelColor
        switch style.horizontalAlign {
        case .center: editor.alignment = .center
        case .right: editor.alignment = .right
        default: editor.alignment = .left
        }
        editor.onEnd = { [weak self, weak editor] commit in
            guard let self, let editor, self.inlineTextEditor === editor else { return }
            self.finishInlineTextEdit(editor, commit: commit)
        }
        inlineTextEditor = editor
        placeInlineTextEditor()
        canvas.addSubview(editor)
        canvas.editingText = m.name
        // The layer's own words step aside while the field shows them (a preview: nothing is written).
        skin.preview(section: m.name, ["FontColor": "0,0,0,0", "FontEffectColor": "0,0,0,0"])
        inlineTextPreview = true
        canvas.needsDisplay = true
        window?.makeFirstResponder(editor)
        // The selection in the accent color, its words in the layer's own: the system's pale selection under light
        // words (white on light blue) can't be read.
        if let field = editor.currentEditor() as? NSTextView, let color = editor.textColor {
            field.selectedTextAttributes = Self.inlineSelectionAttributes(textColor: color)
        }
        editor.currentEditor()?.selectAll(nil)
        return true
    }

    /// The selection of the words edited on the canvas: an accent background dark or light enough for the layer's
    /// text color to read on it.
    static func inlineSelectionAttributes(textColor: NSColor) -> [NSAttributedString.Key: Any] {
        let text = textColor.usingColorSpace(.sRGB) ?? .white
        let light = 0.2126 * text.redComponent + 0.7152 * text.greenComponent + 0.0722 * text.blueComponent > 0.5
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        // Light words: the accent darkened; dark words: the accent lightened.
        let background = light ? accent.blended(withFraction: 0.35, of: .black) ?? accent
                               : accent.blended(withFraction: 0.6, of: .white) ?? accent
        return [.backgroundColor: background, .foregroundColor: textColor]
    }

    /// Puts the field over its layer's words (after a zoom or a refresh): the layer's frame, a little wider on the
    /// side the words grow to, the text inset of the field taken off so the words stay where they were.
    func placeInlineTextEditor() {
        guard let editor = inlineTextEditor, let m = skin?.meter(named: editor.section) else { return }
        let r = canvas.viewRect(m.frame)
        let extra = max(24, 60 - r.width)
        let inset: CGFloat = 2
        var x = r.minX - inset
        switch editor.alignment {
        case .center: x -= extra / 2
        case .right: x -= extra
        default: break
        }
        let height = max(r.height, ceil((editor.font?.boundingRectForFont.height ?? r.height)))
        editor.frame = NSRect(x: x, y: r.midY - height / 2, width: r.width + extra + 2 * inset, height: height)
    }

    /// The skin was reloaded while its words are edited on the canvas: the field follows its layer (its words stay
    /// hidden under it), or goes away with it.
    func refreshInlineTextEditor() {
        guard let editor = inlineTextEditor else { return }
        guard let skin, skin.meter(named: editor.section) != nil else { return endInlineTextEdit(commit: false) }
        placeInlineTextEditor()
        skin.preview(section: editor.section, ["FontColor": "0,0,0,0", "FontEffectColor": "0,0,0,0"])
        inlineTextPreview = true
    }

    /// Ends editing on the canvas, writing the words (`commit`) when they changed.
    func endInlineTextEdit(commit: Bool) {
        inlineTextEditor?.end(commit: commit)
    }

    private func finishInlineTextEdit(_ editor: InlineTextEditor, commit: Bool) {
        let text = editor.stringValue
        inlineTextEditor = nil
        canvas.editingText = nil
        let hadFocus = (window?.firstResponder as? NSText)?.delegate === editor || window?.firstResponder === editor
        editor.removeFromSuperview()
        if inlineTextPreview, geometryBases.isEmpty, colorValue == nil, inspectorState.preview == nil { skin?.endPreview() }
        inlineTextPreview = false
        canvas.needsDisplay = true
        if hadFocus || window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(canvas) }
        guard commit, text != editor.original, skin?.meter(named: editor.section) != nil else { return }
        self.commit([Edit(section: editor.section, key: "Text", value: text, own: true)], name: "Edit Text")
    }

    /// A double-click on a layer of the canvas: plain words are edited in place; words showing live data put the
    /// keyboard in the inspector's Text field instead (the words around the data are changed there).
    func canvasDoubleClicked(_ name: String) {
        guard let skin, let m = skin.meter(named: name), m is StringMeter else { return }
        if beginInlineTextEdit(name) { return }
        focusInspectorTextField()
    }

    /// Puts the keyboard in the inspector's Text field (the selected text layer's words: the token field of text that
    /// shows live data, else the field identified `Text` or `<section>/Text`), if it shows one.
    @discardableResult
    func focusInspectorTextField() -> Bool {
        if let tokens = inspectorStack.findSubview(where: { $0.identifier?.rawValue == "text-tokens" }) as? DataTokenField,
           !tokens.isHiddenOrHasHiddenAncestor {
            tokens.scrollToVisible(tokens.bounds)
            return window?.makeFirstResponder(tokens.textView) ?? false
        }
        let names = ["text"] + (selectedSection.map { ["\($0)/text".lowercased()] } ?? [])
        guard let field = inspectorStack.findSubview(where: { v in
            guard let f = v as? NSTextField, f.isEditable, f.isEnabled, !f.isHiddenOrHasHiddenAncestor else { return false }
            return names.contains(f.identifier?.rawValue.lowercased() ?? "")
        }) else { return false }
        field.scrollToVisible(field.bounds)
        return window?.makeFirstResponder(field) ?? false
    }
}
