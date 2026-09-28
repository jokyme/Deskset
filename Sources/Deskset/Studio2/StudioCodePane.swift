import AppKit
import DesksetCore

/// The code pane of the new Studio: a header (the file as a menu of the widget's files, the section the caret is in,
/// the red and amber counts, the log's count, ⋯, and — when the code took the inspector's place — a labelled way back),
/// the code editor (`CodeEditorView`, as the old Studio uses it, its own jump bar hidden) with the diagnostics under
/// their lines, and a status line that says whether the last change reached the desktop.
final class StudioCodeViewController: NSViewController {
    let header = StudioCodeHeader()
    let codeView = CodeEditorView()
    let statusLine = StudioCodeStatusLine()
    let decorations = StudioCodeDecorations()

    static let headerHeight: CGFloat = 38
    static let statusHeight: CGFloat = 26

    override func loadView() {
        let v = StudioCodeContainer()
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.group)
        v.setAccessibilityLabel(StudioText[.codePane])
        codeView.showsJumpBar = false
        v.addSubview(codeView)
        v.addSubview(header)
        v.addSubview(statusLine)
        v.onLayout = { [weak self] in self?.layOut() }
        view = v
        decorations.attach(to: codeView)
    }

    /// The header under the toolbar (the pane reaches under it, as the canvas and inspector do), the code, the status
    /// line at the foot.
    func layOut() {
        let b = view.bounds
        let top = StudioCanvasViewController.toolbarHeight
        header.frame = NSRect(x: 0, y: top, width: b.width, height: Self.headerHeight)
        statusLine.frame = NSRect(x: 0, y: b.height - Self.statusHeight, width: b.width, height: Self.statusHeight)
        codeView.frame = NSRect(x: 0, y: header.frame.maxY, width: b.width,
                                height: max(0, statusLine.frame.minY - header.frame.maxY))
        codeView.layoutSubtreeIfNeeded()
        decorations.layoutChanged()
    }
}

final class StudioCodeContainer: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        // The strip under the toolbar is the header's color, so the pane reads as one column from the top.
        StudioCodeHeader.fill.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: StudioCanvasViewController.toolbarHeight).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
}

// MARK: - Header

/// The code pane's header: `[doc] Styles.inc ⌄ › [StyleValue]` · `✕ 1` `⚠ 1` · `Log 3` · `⋯` · `Inspector`.
final class StudioCodeHeader: NSView {
    let fileButton = StudioCodeChip(symbol: "doc.text", chevron: true, plain: true)
    let crumb = NSTextField(labelWithString: "")
    private let crumbChevron = NSImageView()
    let problemsChip = StudioCodeChip(symbol: "xmark.octagon.fill", tint: StudioCodeColors.problem)
    let warningsChip = StudioCodeChip(symbol: "exclamationmark.triangle.fill", tint: StudioCodeColors.warning)
    let logChip = StudioCodeChip(symbol: "list.bullet.rectangle", tint: nil)
    let moreButton = StudioCodeChip(symbol: "ellipsis.circle", tint: nil, plain: true)
    let inspectorButton = StudioCodeChip(symbol: "sidebar.trailing", tint: nil)

    static let fill = NSColor(name: "StudioCodeHeader") { appearance in
        StudioPageStyle.isDark(appearance) ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1)
            : NSColor(white: 0.97, alpha: 1)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        crumb.font = .systemFont(ofSize: 12)
        crumb.textColor = .secondaryLabelColor
        crumb.lineBreakMode = .byTruncatingTail
        crumbChevron.image = StudioPageStyle.symbol("chevron.right", size: 8, weight: .bold, color: .tertiaryLabelColor)
        fileButton.font = .systemFont(ofSize: 12, weight: .medium)
        fileButton.toolTip = StudioText[.codeFileTip]
        problemsChip.toolTip = StudioText[.codeProblemsTip]
        warningsChip.toolTip = StudioText[.codeWarningsTip]
        logChip.toolTip = StudioText[.codeLogTip]
        moreButton.toolTip = StudioText[.codeMore]
        moreButton.setAccessibilityLabel(StudioText[.codeMore])
        inspectorButton.title = StudioText[.inspector]
        inspectorButton.toolTip = StudioText[.codeInspectorTip]
        for v in [fileButton, crumbChevron, crumb, problemsChip, warningsChip, logChip, moreButton, inspectorButton]
            as [NSView] {
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.fill.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Counts, the file's name and the crumb as the pane has them now.
    func show(file: String, section: String?, problems: Int, warnings: Int, log: Int, showsInspector: Bool) {
        fileButton.title = file
        crumb.stringValue = section.map { "[\($0)]" } ?? ""
        crumbChevron.isHidden = section == nil
        let both = problems > 0 && warnings > 0
        problemsChip.title = both ? "\(problems)"
            : StudioText.format(problems == 1 ? .codeProblems : .codeProblemsMany, problems)
        problemsChip.isHidden = problems == 0
        warningsChip.title = both ? "\(warnings)"
            : StudioText.format(warnings == 1 ? .codeWarnings : .codeWarningsMany, warnings)
        warningsChip.isHidden = warnings == 0
        problemsChip.setAccessibilityLabel(StudioText.format(problems == 1 ? .codeProblems : .codeProblemsMany, problems))
        warningsChip.setAccessibilityLabel(StudioText.format(warnings == 1 ? .codeWarnings : .codeWarningsMany, warnings))
        logChip.title = StudioText.format(.codeLog, log)
        logChip.isHidden = log == 0
        inspectorButton.isHidden = !showsInspector
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        var right = bounds.width - 12
        for chip in [inspectorButton, moreButton, logChip, warningsChip, problemsChip] where !chip.isHidden {
            let w = chip.fittingWidth
            chip.frame = NSRect(x: right - w, y: midY - 11, width: w, height: 22)
            right -= w + 6
        }
        let fileWidth = min(fileButton.fittingWidth, max(right - 12 - 60, 40))
        fileButton.frame = NSRect(x: 8, y: midY - 11, width: fileWidth, height: 22)
        crumbChevron.frame = NSRect(x: fileButton.frame.maxX + 4, y: midY - 5, width: 8, height: 10)
        let crumbX = crumbChevron.frame.maxX + 6
        crumb.sizeToFit()
        crumb.frame = NSRect(x: crumbX, y: midY - crumb.frame.height / 2,
                             width: max(0, min(crumb.frame.width, right - crumbX - 6)), height: crumb.frame.height)
    }
}

/// A small capsule of the code header: an icon, words, a tint (red problems, amber warnings) or a quiet grey; `plain`
/// draws no capsule (the file's name, ⋯). Clicks run `action`.
final class StudioCodeChip: NSView {
    var title = "" {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(title)
        }
    }
    var font = NSFont.systemFont(ofSize: 11.5, weight: .medium) { didSet { needsDisplay = true } }
    let symbol: String
    let tint: NSColor?
    let chevron: Bool
    let plain: Bool
    var action: (() -> Void)?

    init(symbol: String, tint: NSColor? = nil, chevron: Bool = false, plain: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.chevron = chevron
        self.plain = plain
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var iconSize: CGFloat { symbol == "ellipsis.circle" ? 13 : 11 }

    var fittingWidth: CGFloat {
        let text = title.isEmpty ? 0 : (title as NSString).size(withAttributes: [.font: font]).width
        let icon = iconSize + 2
        return ceil((plain ? 2 : 16) + icon + (title.isEmpty ? 0 : 4 + text) + (chevron ? 12 : 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        if !plain {
            let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            (tint?.withAlphaComponent(0.14) ?? NSColor.labelColor.withAlphaComponent(0.08)).setFill()
            capsule.fill()
        }
        var x: CGFloat = plain ? 1 : 8
        let iconColor = tint ?? (plain && title.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor)
        let weight: NSFont.Weight = symbol == "doc.text" ? .regular : .medium
        let filled = symbol.hasSuffix(".fill") && tint != nil
        if let image = filled ? StudioCodeColors.badge(symbol, size: iconSize, color: iconColor)
            : StudioPageStyle.symbol(symbol, size: iconSize, weight: weight,
                                     color: symbol == "doc.text" ? .secondaryLabelColor : iconColor) {
            let s = image.size
            image.draw(in: NSRect(x: x + (iconSize + 2 - s.width) / 2, y: r.midY - s.height / 2, width: s.width,
                                  height: s.height))
        }
        x += iconSize + 2
        if !title.isEmpty {
            let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let size = text.size()
            text.draw(at: NSPoint(x: x + 4, y: r.midY - size.height / 2))
            x += 4 + size.width
        }
        if chevron, let image = StudioPageStyle.symbol("chevron.down", size: 8.5, weight: .bold,
                                                         color: .secondaryLabelColor) {
            let s = image.size
            image.draw(in: NSRect(x: x + 5, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

// MARK: - Status line

/// The code pane's foot: whether the last change was saved and reached the desktop (or why not), and the caret's line.
final class StudioCodeStatusLine: NSView {
    enum State: Equatable {
        case saved
        /// Saved, and the desktop keeps the last working version (a red problem).
        case held
        case editing
        case notSaved(String)
    }

    private(set) var state = State.saved
    private(set) var text = ""
    private(set) var line = 1

    override var isFlipped: Bool { true }

    func show(_ state: State, line: Int) {
        self.state = state
        self.line = line
        switch state {
        case .saved: text = StudioText[.statusSaved]
        case .held: text = StudioText[.statusHeld]
        case .editing: text = StudioText[.statusEditing]
        case .notSaved(let reason): text = StudioText.format(.statusNotSaved, reason)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(text), \(StudioText.format(.statusLine, line))")
        needsDisplay = true
    }

    var lineText: String { StudioText.format(.statusLine, line) }

    override func draw(_ dirtyRect: NSRect) {
        StudioCodeHeader.fill.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let symbol: String, color: NSColor
        switch state {
        case .saved: (symbol, color) = ("checkmark.circle", StudioPageStyle.okGreen)
        case .held: (symbol, color) = ("clock.arrow.circlepath", StudioCodeColors.warning)
        case .editing: (symbol, color) = ("pencil", NSColor.secondaryLabelColor)
        case .notSaved: (symbol, color) = ("xmark.circle", StudioCodeColors.problem)
        }
        if let image = StudioPageStyle.symbol(symbol, size: 11, color: color) {
            image.draw(in: NSRect(x: 12, y: bounds.midY - image.size.height / 2, width: image.size.width,
                                  height: image.size.height))
        }
        let lineString = NSAttributedString(string: lineText, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        let ls = lineString.size()
        lineString.draw(at: NSPoint(x: bounds.width - 12 - ls.width, y: bounds.midY - ls.height / 2))
        let status = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor])
        status.draw(with: NSRect(x: 30, y: bounds.midY - 8, width: max(0, bounds.width - 30 - ls.width - 24), height: 16),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The red of problems and the amber of warnings, in the code pane and on the canvas.
enum StudioCodeColors {
    /// A filled symbol in `color` with its mark white (the red ✕ octagon, the amber ! triangle).
    static func badge(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [.white, color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static let problem = NSColor(srgbRed: 0.90, green: 0.24, blue: 0.21, alpha: 1)
    static let warning = StudioPageStyle.attention

    static func color(_ severity: IniDiagnostic.Severity) -> NSColor {
        severity == .problem ? problem : warning
    }
}

// MARK: - A diagnostic under its line

/// One problem under the line that causes it: the icon of its kind, the sentence, and "Fix" when the change is certain
/// (in the accent color: fixing is not a dangerous act). The view spans the text's width and hides the line's bands
/// behind it; the card sits inside.
final class StudioDiagnosticCard: NSView {
    let diagnostic: IniDiagnostic
    let message: String
    let label: NSTextField
    let fixButton: StudioFixButton?
    static let leading: CGFloat = 34
    static let trailing: CGFloat = 14
    static let font = NSFont.systemFont(ofSize: 12)

    init(_ diagnostic: IniDiagnostic, message: String, onFix: ((IniDiagnostic) -> Void)?) {
        self.diagnostic = diagnostic
        self.message = message
        label = NSTextField(wrappingLabelWithString: message)
        label.font = Self.font
        label.textColor = .labelColor
        label.isSelectable = false
        if diagnostic.fix != nil, let onFix {
            let b = StudioFixButton(title: StudioText[.fix])
            b.action = { onFix(diagnostic) }
            fixButton = b
        } else {
            fixButton = nil
        }
        super.init(frame: .zero)
        addSubview(label)
        if let fixButton { addSubview(fixButton) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The card's room inside a view `width` wide: the text's width.
    static func textWidth(_ width: CGFloat, fix: Bool) -> CGFloat {
        max(80, width - leading - trailing - 20 - 19 - (fix ? 52 : 0))
    }

    /// The height the view takes under its line (the card and 4 points above and below).
    static func height(for message: String, width: CGFloat, fix: Bool) -> CGFloat {
        let text = StudioPageStyle.height(of: message, font: font, width: textWidth(width, fix: fix))
        return max(28, ceil(text) + 12) + 8
    }

    var cardRect: NSRect {
        NSRect(x: Self.leading, y: 4, width: max(0, bounds.width - Self.leading - Self.trailing),
               height: max(0, bounds.height - 8))
    }

    override func layout() {
        super.layout()
        let card = cardRect
        let textWidth = Self.textWidth(bounds.width, fix: fixButton != nil)
        let h = StudioPageStyle.height(of: message, font: Self.font, width: textWidth)
        label.frame = NSRect(x: card.minX + 29, y: card.midY - h / 2, width: textWidth, height: ceil(h))
        if let fixButton {
            let w = fixButton.fittingWidth
            fixButton.frame = NSRect(x: card.maxX - 10 - w, y: card.midY - 10, width: w, height: 20)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let tint = StudioCodeColors.color(diagnostic.severity)
        let card = cardRect
        let path = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8)
        tint.withAlphaComponent(0.14).setFill()
        path.fill()
        tint.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let symbol = diagnostic.severity == .problem ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        if let image = StudioCodeColors.badge(symbol, size: 11, color: tint) {
            image.draw(in: NSRect(x: card.minX + 10 + (13 - image.size.width) / 2, y: card.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }
}

/// "Fix": a small accent capsule with white words.
final class StudioFixButton: NSView {
    let title: String
    var action: (() -> Void)?
    private let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font]).width + 18) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white])
        let s = text.size()
        text.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}
