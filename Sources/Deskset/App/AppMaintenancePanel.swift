import AppKit

/// Shared, native content for update offers, downloads and installation. Strictly matches the 520pt specification.
final class MaintenancePanelContent: NSView {
    enum CardMode: Equatable {
        case none
        case twoRow
        case singleRow
        case progress
        case error
    }

    let eyebrow = NSTextField(labelWithString: "")
    let heading = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let progressText = NSTextField(labelWithString: "")
    let footnote = NSTextField(labelWithString: "")

    var badgeText: String = "" {
        didSet {
            badgeView.text = badgeText
            badgeView.isHidden = badgeText.isEmpty
            needsLayout = true
        }
    }

    var showsDisabledCancelPlaceholder = false {
        didSet {
            disabledCancelButton.isHidden = !showsDisabledCancelPlaceholder
            needsLayout = true
        }
    }

    var alertStyle: NSAlert.Style = .informational {
        didSet {
            iconView.showsWarningBadge = alertStyle == .warning || alertStyle == .critical
            cardView.isError = alertStyle == .warning || alertStyle == .critical
            applyAppearanceColors()
        }
    }

    private(set) var cardMode: CardMode = .none
    let iconView = MaintenanceIconView()
    let badgeView = MaintenanceBadgeView()
    private let detailScroll = NSScrollView()
    private let detailDocument = MaintenanceFlippedView()

    let cardView = MaintenanceCardView()
    let cardLeftLabel = NSTextField(labelWithString: "")
    let cardMainValue = NSTextField(wrappingLabelWithString: "")
    let cardRightMeta = NSTextField(labelWithString: "")
    let cardBottomNote = NSTextField(wrappingLabelWithString: "")
    let progressBar = MaintenanceProgressBarView()
    private let errorScroll = NSScrollView()
    private let errorDocument = MaintenanceFlippedView()
    let errorLabel = NSTextField(wrappingLabelWithString: "")

    private var oldVersionText: String?
    private var mainValueRawText: String = ""
    private var rightMetaUsesAccent = false

    private let dividerView = MaintenanceDividerView()
    private var leadingButtons: [NSButton] = []
    private var trailingButtons: [NSButton] = []
    private let disabledCancelButton = MaintenanceActionButton(title: L("Cancel"), target: nil, action: nil)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 244))
        autoresizingMask = [.width, .height]
        eyebrow.isHidden = true

        iconView.setAccessibilityLabel("Deskset")
        addSubview(iconView)

        configureLabel(heading, font: .systemFont(ofSize: 16, weight: .semibold), selectable: true, wraps: true)
        heading.maximumNumberOfLines = 0
        addSubview(heading)

        badgeView.isHidden = true
        addSubview(badgeView)

        configureLabel(detail, font: .systemFont(ofSize: 13, weight: .regular), selectable: true, wraps: true)
        detail.maximumNumberOfLines = 0
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.documentView = detailDocument
        detailDocument.addSubview(detail)
        addSubview(detailScroll)

        configureLabel(cardLeftLabel, font: .systemFont(ofSize: 12, weight: .medium), selectable: false, wraps: false)
        configureLabel(cardMainValue, font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), selectable: true, wraps: true)
        cardMainValue.maximumNumberOfLines = 0
        configureLabel(cardRightMeta, font: .systemFont(ofSize: 11.5, weight: .medium), selectable: true, wraps: false)
        cardRightMeta.alignment = .right
        configureLabel(cardBottomNote, font: .systemFont(ofSize: 12, weight: .regular), selectable: true, wraps: true)
        cardBottomNote.maximumNumberOfLines = 0

        configureLabel(progressText, font: .systemFont(ofSize: 12, weight: .medium), selectable: true, wraps: false)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true

        configureLabel(errorLabel, font: .systemFont(ofSize: 12.5, weight: .medium), selectable: true, wraps: true)
        errorLabel.maximumNumberOfLines = 0
        errorScroll.drawsBackground = false
        errorScroll.borderType = .noBorder
        errorScroll.hasVerticalScroller = true
        errorScroll.autohidesScrollers = true
        errorScroll.documentView = errorDocument
        errorDocument.addSubview(errorLabel)

        [cardLeftLabel, cardMainValue, cardRightMeta, cardBottomNote,
         progressText, progressBar, errorScroll].forEach(cardView.addSubview)
        cardView.isHidden = true
        addSubview(cardView)

        addSubview(dividerView)

        configureLabel(footnote, font: .systemFont(ofSize: 12, weight: .regular), selectable: true, wraps: false)
        footnote.lineBreakMode = .byTruncatingMiddle
        addSubview(footnote)

        disabledCancelButton.isEnabled = false
        disabledCancelButton.isHidden = true
        addSubview(disabledCancelButton)

        applyAppearanceColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureLabel(_ field: NSTextField, font: NSFont, selectable: Bool, wraps: Bool) {
        field.font = font
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = selectable
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        field.cell?.wraps = wraps
        field.cell?.isScrollable = false
    }

    static func makeWindow(title: String) -> NSPanel {
        let panel = MaintenanceWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 244),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.tabbingMode = .disallowed
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = MaintenancePalette.current(for: panel.effectiveAppearance).windowBackground
        return panel
    }

    // MARK: Card Configuration

    func configureTwoRowCard(leftLabel: String, oldVersion: String? = nil, mainValue: String,
                             rightMeta: String, rightMetaAccent: Bool = false, bottomNote: String) {
        cardMode = .twoRow
        cardView.isHidden = false
        cardView.isCompact = false
        cardView.showsInternalDivider = true
        cardView.isError = alertStyle == .warning || alertStyle == .critical
        cardLeftLabel.font = .systemFont(ofSize: 12, weight: .medium)
        cardLeftLabel.stringValue = leftLabel
        oldVersionText = oldVersion
        mainValueRawText = mainValue
        rightMetaUsesAccent = rightMetaAccent
        cardRightMeta.stringValue = rightMeta
        cardBottomNote.font = .systemFont(ofSize: 12, weight: .regular)
        cardBottomNote.stringValue = bottomNote
        updateCardVisibility()
        applyAppearanceColors()
    }

    func configureSingleRowCard(leftLabel: String, mainValue: String, rightMeta: String, rightMetaAccent: Bool = false) {
        cardMode = .singleRow
        cardView.isHidden = false
        cardView.isCompact = true
        cardView.showsInternalDivider = false
        cardView.isError = false
        cardLeftLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        cardLeftLabel.stringValue = leftLabel
        oldVersionText = nil
        mainValueRawText = mainValue
        rightMetaUsesAccent = rightMetaAccent
        cardRightMeta.stringValue = rightMeta
        cardBottomNote.stringValue = ""
        updateCardVisibility()
        applyAppearanceColors()
    }

    func configureProgressCard(status: String, rightMeta: String = "", fraction: Double?, bottomNote: String) {
        cardMode = .progress
        cardView.isHidden = false
        cardView.isCompact = false
        cardView.showsInternalDivider = false
        cardView.isError = false
        progressText.stringValue = status
        cardRightMeta.stringValue = rightMeta
        rightMetaUsesAccent = true
        cardBottomNote.font = .systemFont(ofSize: 11.5, weight: .regular)
        cardBottomNote.stringValue = bottomNote
        setProgress(visible: true, fraction: fraction, text: status, rightMeta: rightMeta)
        updateCardVisibility()
        applyAppearanceColors()
    }

    func configureErrorCard(message: String, bottomNote: String) {
        cardMode = .error
        cardView.isHidden = false
        cardView.isCompact = false
        cardView.showsInternalDivider = false
        cardView.isError = true
        errorLabel.stringValue = message
        cardBottomNote.font = .systemFont(ofSize: 12, weight: .regular)
        cardBottomNote.stringValue = bottomNote
        updateCardVisibility()
        applyAppearanceColors()
    }

    /// Backwards-compatible helper mapping to two-row card.
    func configureContext(title: String, value: String, detail: String, symbol: String) {
        configureTwoRowCard(leftLabel: title, mainValue: value, rightMeta: "", bottomNote: detail)
    }

    func hideContext() {
        cardMode = .none
        cardView.isHidden = true
        updateCardVisibility()
    }

    func setProgress(visible: Bool, fraction: Double?, text: String, rightMeta: String? = nil) {
        progressText.stringValue = text
        if let rightMeta {
            cardRightMeta.stringValue = rightMeta
        } else if let fraction {
            cardRightMeta.stringValue = "\(Int(max(0, min(1, fraction)) * 100))%"
        }
        progress.isIndeterminate = fraction == nil
        if let fraction { progress.doubleValue = max(0, min(1, fraction)) }
        progressBar.statusLabel = text
        progressBar.fraction = fraction
        progressBar.isHidden = !visible
        if visible && cardMode != .progress {
            cardMode = .progress
            cardView.isHidden = false
            cardView.showsInternalDivider = false
            updateCardVisibility()
        }
        applyAppearanceColors()
        needsLayout = true
    }

    private func updateCardVisibility() {
        let isInfo = cardMode == .twoRow || cardMode == .singleRow
        let isProg = cardMode == .progress
        let isErr = cardMode == .error
        cardLeftLabel.isHidden = !isInfo
        cardMainValue.isHidden = !isInfo
        cardRightMeta.isHidden = !(isInfo || isProg)
        progressText.isHidden = !isProg
        progressBar.isHidden = !isProg
        errorScroll.isHidden = !isErr
        cardBottomNote.isHidden = cardMode == .singleRow || cardMode == .none
    }

    func setActions(leading: [NSButton], trailing: [NSButton]) {
        (leadingButtons + trailingButtons).forEach { $0.removeFromSuperview() }
        leadingButtons = leading
        trailingButtons = trailing
        for button in leading + trailing {
            if !(button is MaintenanceActionButton) {
                button.bezelStyle = .rounded
                button.controlSize = .regular
            }
            addSubview(button)
        }
        needsLayout = true
    }

    // MARK: Layout & Sizing

    func fit(window: NSWindow) {
        _ = computeLayout(applyFrames: true, screenHeight: (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800)
        window.backgroundColor = MaintenancePalette.current(for: effectiveAppearance).windowBackground
        window.setContentSize(frame.size)
    }

    override func layout() {
        super.layout()
        _ = computeLayout(applyFrames: true, screenHeight: (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800)
    }

    @discardableResult
    private func computeLayout(applyFrames: Bool, screenHeight: CGFloat) -> NSSize {
        let width: CGFloat = 520
        let rightX: CGFloat = 104
        let rightWidth: CGFloat = 392

        // 1. Icon (64x64 tile at x=24, y=38; view has 6pt shadow bleed margin)
        if applyFrames {
            iconView.frame = NSRect(x: 18, y: 34, width: 76, height: 74)
        }

        // 2. Badge & Heading (y=36)
        let hasBadge = !badgeText.isEmpty && !badgeView.isHidden
        let badgeSize = hasBadge ? badgeView.preferredSize() : .zero
        if applyFrames && hasBadge {
            badgeView.frame = NSRect(x: rightX + rightWidth - badgeSize.width, y: 37,
                                     width: badgeSize.width, height: 20)
        }
        let headingAvailWidth = hasBadge ? (rightWidth - badgeSize.width - 8) : rightWidth
        heading.preferredMaxLayoutWidth = headingAvailWidth
        let measuredHeading = measureTextHeight(heading, width: headingAvailWidth)
        let headingHeight = measuredHeading <= 22 ? 20 : ceil(measuredHeading)
        if applyFrames {
            heading.frame = NSRect(x: rightX - 2, y: 36, width: headingAvailWidth + 4, height: headingHeight)
        }

        // 3. Subtitle / Detail Scroll (y=60 for single-line heading)
        let detailTop = 36 + headingHeight + 4
        let detailVisible = !detail.stringValue.isEmpty
        detailScroll.isHidden = !detailVisible
        var detailScrollHeight: CGFloat = 0
        if detailVisible {
            let isSingleSentence = !detail.stringValue.contains("\n") && detail.stringValue.count <= 80
            let singleLineWidth = min(width - rightX - 8, max(rightWidth, ceil(detail.attributedStringValue.size().width) + 4))
            let detailMaxWidth = isSingleSentence ? singleLineWidth : rightWidth
            let naturalDetail = isSingleSentence ? 18 : ceil(measureTextHeight(detail, width: detailMaxWidth))
            let needsDetailScroll = naturalDetail > 136
            let docWidth = needsDetailScroll ? (rightWidth - 14) : detailMaxWidth
            let finalNatural = needsDetailScroll ? ceil(measureTextHeight(detail, width: docWidth)) : naturalDetail
            detailScrollHeight = finalNatural <= 21 ? 18 : min(136, finalNatural)
            if applyFrames {
                detail.preferredMaxLayoutWidth = docWidth + 4
                detail.frame = NSRect(x: -2, y: 0, width: docWidth + 4, height: max(18, finalNatural))
                detailDocument.frame = NSRect(x: 0, y: 0, width: docWidth, height: max(18, finalNatural))
                detailScroll.frame = NSRect(x: rightX, y: detailTop, width: needsDetailScroll ? rightWidth : detailMaxWidth, height: detailScrollHeight)
            }
        }

        // 4. Structured Card (y=88 standard, width=392)
        var contentBottom = detailVisible ? (detailTop + detailScrollHeight) : (36 + headingHeight)
        if cardMode != .none && !cardView.isHidden {
            let cardTop = (headingHeight == 20 && detailScrollHeight <= 18) ? 88 : (contentBottom + 10)
            let cardHeight = layoutCardContents(width: rightWidth, applyFrames: applyFrames)
            if applyFrames {
                cardView.frame = NSRect(x: rightX, y: cardTop, width: rightWidth, height: cardHeight)
            }
            contentBottom = cardTop + cardHeight
        }

        // 5. Footer Divider & 56pt Grounded Action Bar
        let isStandardGeometry = headingHeight == 20 && detailScrollHeight <= 18
        let dividerY: CGFloat
        if isStandardGeometry && cardMode == .singleRow && contentBottom <= 136 {
            dividerY = 168 // 224pt total height (06-up-to-date.svg)
        } else if isStandardGeometry && cardMode != .none && contentBottom <= 174 {
            dividerY = 188 // 244pt total height (01..05, 07 SVGs)
        } else {
            dividerY = max(168, contentBottom + 20)
        }

        let footerHeight: CGFloat = 56
        let maxWindowHeight = max(260, screenHeight - 40)
        let totalHeight = min(maxWindowHeight, dividerY + footerHeight)
        let effectiveDividerY = totalHeight - footerHeight

        if applyFrames {
            dividerView.frame = NSRect(x: 0, y: effectiveDividerY, width: width, height: 1)
            layoutFooter(dividerY: effectiveDividerY, width: width)
            frame.size = NSSize(width: width, height: totalHeight)
        }
        return NSSize(width: width, height: totalHeight)
    }

    private func layoutCardContents(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let insetX: CGFloat = 14
        let innerWidth = width - insetX * 2 // 364pt

        switch cardMode {
        case .none:
            return 0

        case .singleRow:
            let leftW = ceil(cardLeftLabel.attributedStringValue.size().width)
            let rightW = cardRightMeta.stringValue.isEmpty ? 0 : ceil(cardRightMeta.attributedStringValue.size().width)
            let defaultValX: CGFloat = cardLeftLabel.stringValue == L("Installed version") ? 122 : (insetX + leftW + 10)
            let valX = max(defaultValX, insetX + leftW + 8)
            let valWidth = max(60, width - insetX - rightW - valX - (rightW > 0 ? 8 : 0))
            let measuredValH = ceil(measureTextHeight(cardMainValue, width: valWidth))
            let valHeight: CGFloat = measuredValH <= 20 ? 18 : measuredValH
            let cardHeight: CGFloat = valHeight <= 18 ? 48 : (16 + valHeight + 14)
            if applyFrames {
                cardLeftLabel.frame = NSRect(x: insetX - 2, y: 16, width: leftW + 6, height: 18)
                cardMainValue.preferredMaxLayoutWidth = valWidth + 4
                cardMainValue.frame = NSRect(x: valX - 2, y: 16, width: valWidth + 4, height: valHeight)
                cardRightMeta.frame = NSRect(x: width - insetX - rightW - 2, y: 17, width: rightW + 4, height: 17)
            }
            return cardHeight

        case .twoRow:
            let leftW = ceil(cardLeftLabel.attributedStringValue.size().width)
            let rightW = cardRightMeta.stringValue.isEmpty ? 0 : ceil(cardRightMeta.attributedStringValue.size().width)
            let svgAlignedX: CGFloat
            switch cardLeftLabel.stringValue {
            case "Version": svgAlignedX = 68
            case "Ready to install": svgAlignedX = 108
            case "Destination": svgAlignedX = 90
            case "Replacing": svgAlignedX = 82
            default: svgAlignedX = insetX + leftW + 10
            }
            let valX = max(svgAlignedX, insetX + leftW + 8)
            let valWidth = max(60, width - insetX - rightW - valX - (rightW > 0 ? 8 : 0))
            let measuredValH = ceil(measureTextHeight(cardMainValue, width: valWidth))
            let valHeight: CGFloat = measuredValH <= 20 ? 18 : measuredValH
            let divY: CGFloat = valHeight <= 18 ? 36 : (13.5 + valHeight + 6)
            let noteTop: CGFloat = valHeight <= 18 ? 42 : (divY + 6)
            let noteHeight = ceil(measureTextHeight(cardBottomNote, width: innerWidth))
            let row2Height: CGFloat = noteHeight <= 19 ? 16 : noteHeight
            let cardHeight: CGFloat = (valHeight <= 18 && row2Height <= 16) ? 68 : (noteTop + row2Height + 10)
            if applyFrames {
                cardLeftLabel.frame = NSRect(x: insetX - 2, y: 14, width: leftW + 6, height: 17)
                cardMainValue.preferredMaxLayoutWidth = valWidth + 4
                cardMainValue.frame = NSRect(x: valX - 2, y: 13.5, width: valWidth + 4, height: valHeight)
                cardRightMeta.frame = NSRect(x: width - insetX - rightW - 2, y: 14.5, width: rightW + 4, height: 17)
                cardView.dividerY = divY
                cardBottomNote.preferredMaxLayoutWidth = innerWidth + 4
                cardBottomNote.frame = NSRect(x: insetX - 2, y: noteTop, width: innerWidth + 4, height: row2Height)
            }
            return cardHeight

        case .progress:
            if applyFrames {
                let rightW = cardRightMeta.stringValue.isEmpty ? 0 : ceil(cardRightMeta.attributedStringValue.size().width)
                let statusWidth = rightW > 0 ? (innerWidth - rightW - 8) : innerWidth
                progressText.frame = NSRect(x: insetX - 2, y: 11, width: statusWidth + 4, height: 17)
                cardRightMeta.frame = NSRect(x: width - insetX - rightW - 2, y: 11, width: rightW + 4, height: 17)
                progressBar.frame = NSRect(x: insetX, y: 32, width: innerWidth, height: 6)
                cardBottomNote.preferredMaxLayoutWidth = innerWidth + 4
                cardBottomNote.frame = NSRect(x: insetX - 2, y: 43, width: innerWidth + 4, height: 17)
            }
            return 68

        case .error:
            let naturalErr = ceil(measureTextHeight(errorLabel, width: innerWidth))
            let needsErrScroll = naturalErr > 96
            let errDocW = needsErrScroll ? (innerWidth - 14) : innerWidth
            let finalErrH = needsErrScroll ? ceil(measureTextHeight(errorLabel, width: errDocW)) : naturalErr
            let errVisibleH = finalErrH <= 20 ? 18 : min(96, finalErrH)
            let errTop: CGFloat = errVisibleH <= 18 ? 13 : 10
            let noteY: CGFloat = errVisibleH <= 18 ? 35 : (errTop + errVisibleH + 4)
            let noteH = ceil(measureTextHeight(cardBottomNote, width: innerWidth))
            let noteVisibleH = noteH <= 19 ? 16 : noteH
            let cardHeight: CGFloat = (errVisibleH <= 18 && noteVisibleH <= 16) ? 68 : max(68, noteY + noteVisibleH + 10)
            if applyFrames {
                errorLabel.preferredMaxLayoutWidth = errDocW + 4
                errorLabel.frame = NSRect(x: -2, y: 0, width: errDocW + 4, height: max(18, finalErrH))
                errorDocument.frame = NSRect(x: 0, y: 0, width: innerWidth, height: max(18, finalErrH))
                errorScroll.frame = NSRect(x: insetX, y: errTop, width: innerWidth, height: errVisibleH)
                cardBottomNote.preferredMaxLayoutWidth = innerWidth + 4
                cardBottomNote.frame = NSRect(x: insetX - 2, y: noteY, width: innerWidth + 4, height: noteVisibleH)
            }
            return cardHeight
        }
    }

    private func layoutFooter(dividerY: CGFloat, width: CGFloat) {
        let buttonY = dividerY + 14
        var leftX: CGFloat = 24
        let visibleLeading = leadingButtons.filter { !$0.isHidden }
        for button in visibleLeading {
            let bw = MaintenanceActionButton.preferredWidth(for: button)
            button.frame = NSRect(x: leftX, y: buttonY, width: bw, height: 28)
            leftX += bw + 8
        }

        var rightX = width - 24
        let visibleTrailing = trailingButtons.filter { !$0.isHidden }
        for button in visibleTrailing.reversed() {
            let bw = MaintenanceActionButton.preferredWidth(for: button)
            rightX -= bw
            button.frame = NSRect(x: rightX, y: buttonY, width: bw, height: 28)
            rightX -= 8
        }
        var trailingLeftEdge = visibleTrailing.isEmpty ? (width - 24) : (rightX + 8)
        if showsDisabledCancelPlaceholder && visibleTrailing.isEmpty {
            let cancelX = width - 24 - 84
            disabledCancelButton.frame = NSRect(x: cancelX, y: buttonY, width: 84, height: 28)
            trailingLeftEdge = cancelX
        }

        footnote.isHidden = !visibleLeading.isEmpty || footnote.stringValue.isEmpty
        if !footnote.isHidden {
            let maxFootnoteWidth = max(40, trailingLeftEdge - 12 - 22)
            footnote.frame = NSRect(x: 22, y: dividerY + 20, width: maxFootnoteWidth, height: 17)
            footnote.toolTip = footnote.stringValue
        }
    }

    private func measureTextHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
        guard !field.stringValue.isEmpty, let cell = field.cell else { return 0 }
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(10, width + 4), height: .greatestFiniteMagnitude)).height
    }

    // MARK: Appearance & Colors

    private func applyAppearanceColors() {
        let p = MaintenancePalette.current(for: effectiveAppearance)
        heading.textColor = p.textPrimary
        detail.textColor = p.textSecondary
        footnote.textColor = p.textTertiary
        progressText.textColor = p.textPrimary
        cardLeftLabel.textColor = cardMode == .singleRow ? p.textPrimary : p.textMuted
        cardBottomNote.textColor = p.textSecondary
        errorLabel.textColor = p.errorText

        let rightIsAccent = rightMetaUsesAccent || (cardMode == .progress && progressBar.fraction != nil)
        cardRightMeta.textColor = rightIsAccent ? p.accentText : p.textMuted
        if cardMode == .progress && progressBar.fraction != nil {
            cardRightMeta.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        } else {
            cardRightMeta.font = .systemFont(ofSize: 11.5, weight: .medium)
        }

        if let oldVer = oldVersionText, !oldVer.isEmpty {
            let attr = NSMutableAttributedString(
                string: oldVer + " ",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: p.textMuted,
                ]
            )
            attr.append(NSAttributedString(
                string: mainValueRawText,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: p.accentText,
                ]
            ))
            cardMainValue.attributedStringValue = attr
        } else {
            cardMainValue.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
            cardMainValue.textColor = p.accentText
            cardMainValue.stringValue = mainValueRawText
        }

        window?.backgroundColor = p.windowBackground
        needsDisplay = true
        iconView.needsDisplay = true
        badgeView.needsDisplay = true
        cardView.needsDisplay = true
        progressBar.needsDisplay = true
        dividerView.needsDisplay = true
        (leadingButtons + trailingButtons + [disabledCancelButton]).forEach { $0.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = MaintenancePalette.current(for: effectiveAppearance)
        p.windowBackground.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }
}

/// Small modal adapter with NSAlert-compatible response indices; the content is also used by nonmodal downloads.
final class AppMaintenancePanel: NSObject, NSWindowDelegate {
    let window = MaintenancePanelContent.makeWindow(title: "Deskset")
    let content = MaintenancePanelContent()
    private(set) var buttons: [NSButton] = []
    private var modalRunning = false

    var messageText: String {
        get { content.heading.stringValue }
        set { content.heading.stringValue = newValue; window.title = newValue; content.needsLayout = true }
    }
    var informativeText: String {
        get { content.detail.stringValue }
        set { content.detail.stringValue = newValue; content.needsLayout = true }
    }
    var alertStyle: NSAlert.Style {
        get { content.alertStyle }
        set { content.alertStyle = newValue }
    }
    var allowsClosing = true {
        didSet { window.standardWindowButton(.closeButton)?.isEnabled = allowsClosing }
    }

    override init() {
        super.init()
        window.contentView = content
        window.delegate = self
        (window as? MaintenanceWindow)?.cancelAction = { [weak self] in self?.requestClose() }
    }

    @discardableResult
    func addButton(withTitle title: String) -> NSButton {
        let button = MaintenanceActionButton(title: title, target: self, action: #selector(choose(_:)))
        button.tag = buttons.count
        buttons.append(button)
        window.defaultButtonCell = nil
        for item in buttons {
            item.keyEquivalent = ""
            (item as? MaintenanceActionButton)?.isPrimaryAction = false
        }
        buttons.first?.keyEquivalent = "\r"
        (buttons.first as? MaintenanceActionButton)?.isPrimaryAction = true
        window.defaultButtonCell = buttons.first?.cell as? NSButtonCell
        if buttons.count > 1 { buttons.last?.keyEquivalent = "\u{1b}" }
        if buttons.count > 2 {
            content.setActions(leading: Array(buttons.dropFirst().dropLast()),
                               trailing: [buttons[buttons.count - 1], buttons[0]])
        } else {
            content.setActions(leading: [], trailing: Array(buttons.reversed()))
        }
        return button
    }

    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        content.fit(window: window)
        window.center()
        modalRunning = true
        defer { modalRunning = false; window.orderOut(nil) }
        return NSApp.runModal(for: window)
    }

    func dismiss(response: NSApplication.ModalResponse = .cancel) {
        if modalRunning { NSApp.stopModal(withCode: response) }
        window.orderOut(nil)
    }

    @objc private func choose(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        dismiss(response: NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }

    private func requestClose() {
        guard allowsClosing, buttons.last?.isEnabled != false else { return }
        let response = buttons.isEmpty ? NSApplication.ModalResponse.cancel
            : NSApplication.ModalResponse(
                rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttons.count - 1)
        dismiss(response: response)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
}

// MARK: - Supporting Views & Theme Palette

private struct MaintenancePalette {
    let isDark: Bool
    let windowBackground: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textMuted: NSColor
    let textTertiary: NSColor
    let accentText: NSColor
    let pillFill: NSColor
    let pillBorder: NSColor
    let cardFill: NSColor
    let cardCompactFill: NSColor
    let cardBorder: NSColor
    let cardCompactBorder: NSColor
    let cardDivider: NSColor
    let errorFill: NSColor
    let errorBorder: NSColor
    let errorText: NSColor
    let footerDivider: NSColor
    let buttonSecondaryFill: NSColor
    let buttonSecondaryHighlightedFill: NSColor
    let buttonSecondaryDisabledFill: NSColor
    let buttonSecondaryBorder: NSColor
    let buttonSecondaryText: NSColor
    let progressTrack: NSColor

    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static func current(for appearance: NSAppearance?) -> MaintenancePalette {
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            return MaintenancePalette(
                isDark: true,
                windowBackground: rgba(36, 39, 45),
                textPrimary: rgba(243, 245, 248),
                textSecondary: rgba(166, 176, 191),
                textMuted: rgba(166, 176, 191),
                textTertiary: rgba(125, 135, 150),
                accentText: rgba(103, 212, 252),
                pillFill: rgba(56, 189, 248, 0.14),
                pillBorder: rgba(56, 189, 248, 0.26),
                cardFill: rgba(56, 189, 248, 0.08),
                cardCompactFill: rgba(56, 189, 248, 0.07),
                cardBorder: rgba(56, 189, 248, 0.20),
                cardCompactBorder: rgba(56, 189, 248, 0.18),
                cardDivider: rgba(56, 189, 248, 0.12),
                errorFill: rgba(248, 113, 113, 0.09),
                errorBorder: rgba(248, 113, 113, 0.25),
                errorText: rgba(252, 165, 165),
                footerDivider: rgba(255, 255, 255, 0.09),
                buttonSecondaryFill: rgba(52, 56, 64),
                buttonSecondaryHighlightedFill: rgba(62, 67, 77),
                buttonSecondaryDisabledFill: rgba(44, 48, 55),
                buttonSecondaryBorder: rgba(255, 255, 255, 0.15),
                buttonSecondaryText: rgba(236, 239, 244),
                progressTrack: rgba(255, 255, 255, 0.14)
            )
        }
        return MaintenancePalette(
            isDark: false,
            windowBackground: rgba(246, 247, 249),
            textPrimary: rgba(20, 24, 31),
            textSecondary: rgba(82, 91, 105),
            textMuted: rgba(90, 101, 117),
            textTertiary: rgba(110, 119, 133),
            accentText: rgba(11, 92, 143),
            pillFill: rgba(14, 116, 178, 0.10),
            pillBorder: rgba(14, 116, 178, 0.20),
            cardFill: rgba(14, 116, 178, 0.055),
            cardCompactFill: rgba(14, 116, 178, 0.045),
            cardBorder: rgba(14, 116, 178, 0.16),
            cardCompactBorder: rgba(14, 116, 178, 0.14),
            cardDivider: rgba(14, 116, 178, 0.10),
            errorFill: rgba(217, 56, 41, 0.06),
            errorBorder: rgba(217, 56, 41, 0.22),
            errorText: rgba(140, 29, 19),
            footerDivider: rgba(225, 228, 234),
            buttonSecondaryFill: rgba(255, 255, 255),
            buttonSecondaryHighlightedFill: rgba(240, 242, 246),
            buttonSecondaryDisabledFill: rgba(242, 243, 245),
            buttonSecondaryBorder: rgba(199, 204, 212),
            buttonSecondaryText: rgba(42, 49, 60),
            progressTrack: rgba(213, 223, 235)
        )
    }
}

private final class MaintenanceWindow: NSPanel {
    var cancelAction: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let cancelAction { cancelAction() } else { super.cancelOperation(sender) }
    }
}

private final class MaintenanceFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Full-bleed 64x64pt Deskset rain-cloud icon matching 01-update-offer.svg, with 6pt outer bleed for drop shadow.
final class MaintenanceIconView: NSView {
    var showsWarningBadge = false {
        didSet {
            setAccessibilityLabel(showsWarningBadge ? L("Deskset warning") : "Deskset")
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { showsWarningBadge ? L("Deskset warning") : "Deskset" }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        // Offset by (6, 4) so the 64x64 icon tile sits at (24, 38) in the parent view.
        ctx.translateBy(x: 6, y: 4)

        let tileRect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let tilePath = CGPath(roundedRect: tileRect, cornerWidth: 14.5, cornerHeight: 14.5, transform: nil)

        // Drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5,
                      color: MaintenancePalette.rgba(10, 37, 64, 0.22).cgColor)
        ctx.addPath(tilePath)
        ctx.setFillColor(MaintenancePalette.rgba(53, 76, 153).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Gradient background (#354C99 -> #2668A7 -> #3A9BB2)
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let colors = [
            MaintenancePalette.rgba(53, 76, 153).cgColor,
            MaintenancePalette.rgba(38, 104, 167).cgColor,
            MaintenancePalette.rgba(58, 155, 178).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 32, y: 0), end: CGPoint(x: 32, y: 64), options: [])
        }

        // Cloud path from 01-update-offer.svg
        let cloud = CGMutablePath()
        cloud.move(to: CGPoint(x: 21, y: 31.5))
        cloud.addLine(to: CGPoint(x: 43.5, y: 31.5))
        cloud.addCurve(to: CGPoint(x: 50.8, y: 24.3),
                       control1: CGPoint(x: 47.6, y: 31.5), control2: CGPoint(x: 50.8, y: 28.3))
        cloud.addCurve(to: CGPoint(x: 44.4, y: 17.2),
                       control1: CGPoint(x: 50.8, y: 20.6), control2: CGPoint(x: 48.0, y: 17.6))
        cloud.addCurve(to: CGPoint(x: 32.0, y: 8.2),
                       control1: CGPoint(x: 42.8, y: 11.9), control2: CGPoint(x: 37.9, y: 8.2))
        cloud.addCurve(to: CGPoint(x: 19.3, y: 18.2),
                       control1: CGPoint(x: 25.7, y: 8.2), control2: CGPoint(x: 20.5, y: 12.4))
        cloud.addCurve(to: CGPoint(x: 13.4, y: 25.4),
                       control1: CGPoint(x: 15.9, y: 18.9), control2: CGPoint(x: 13.4, y: 21.8))
        cloud.addCurve(to: CGPoint(x: 21.0, y: 31.5),
                       control1: CGPoint(x: 13.4, y: 28.9), control2: CGPoint(x: 16.8, y: 31.5))
        cloud.closeSubpath()
        ctx.addPath(cloud)
        ctx.setFillColor(MaintenancePalette.rgba(245, 250, 255).cgColor)
        ctx.fillPath()

        // Three rain bars
        let bars: [(x: CGFloat, h: CGFloat, color: NSColor)] = [
            (21.0, 12.0, MaintenancePalette.rgba(140, 214, 234)),
            (29.4, 18.0, MaintenancePalette.rgba(169, 229, 245)),
            (37.8, 9.5, MaintenancePalette.rgba(140, 214, 234)),
        ]
        for bar in bars {
            let barPath = CGPath(roundedRect: CGRect(x: bar.x, y: 36, width: 5.2, height: bar.h),
                                 cornerWidth: 2.6, cornerHeight: 2.6, transform: nil)
            ctx.addPath(barPath)
            ctx.setFillColor(bar.color.cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()

        // Subtle inner rim
        let rimPath = CGPath(roundedRect: tileRect.insetBy(dx: 0.5, dy: 0.5),
                             cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(rimPath)
        ctx.setStrokeColor(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // Corner warning dot (05-update-failed.svg)
        if showsWarningBadge {
            let p = MaintenancePalette.current(for: effectiveAppearance)
            let badgeRect = CGRect(x: 44, y: 44, width: 20, height: 20)
            ctx.setFillColor(MaintenancePalette.rgba(217, 56, 41).cgColor)
            ctx.fillEllipse(in: badgeRect)
            ctx.setStrokeColor(p.windowBackground.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: badgeRect)

            let stem = CGPath(roundedRect: CGRect(x: 53, y: 48.5, width: 2, height: 6.5),
                              cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.addPath(stem)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.fillEllipse(in: CGRect(x: 52.9, y: 56.9, width: 2.2, height: 2.2))
        }

        ctx.restoreGState()
    }
}

/// Top-right 20pt high rounded pill badge ("Apple silicon", "Intel", "Verified", etc.).
final class MaintenanceBadgeView: NSView {
    var text: String = "" {
        didSet {
            setAccessibilityElement(!text.isEmpty && !isHidden)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(text)
            setAccessibilityValue(text)
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { !text.isEmpty && !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityValue() -> Any? { text }

    func preferredSize() -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        let w = ceil((text as NSString).size(withAttributes: attrs).width)
        return NSSize(width: max(86, w + 18), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let p = MaintenancePalette.current(for: effectiveAppearance)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        p.pillFill.setFill()
        path.fill()
        p.pillBorder.setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: p.accentText,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: round((bounds.width - size.width) / 2),
                            y: round((bounds.height - size.height) / 2) - 0.5)
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

/// Right-column 392pt structured status / version / progress / error card.
final class MaintenanceCardView: NSView {
    var isCompact = false { didSet { needsDisplay = true } }
    var isError = false { didSet { needsDisplay = true } }
    var showsInternalDivider = true { didSet { needsDisplay = true } }
    var dividerY: CGFloat = 36 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let p = MaintenancePalette.current(for: effectiveAppearance)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let fill = isError ? p.errorFill : (isCompact ? p.cardCompactFill : p.cardFill)
        let border = isError ? p.errorBorder : (isCompact ? p.cardCompactBorder : p.cardBorder)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        if showsInternalDivider && !isError && !isCompact {
            p.cardDivider.setFill()
            NSRect(x: 14, y: dividerY, width: max(0, bounds.width - 28), height: 1).fill()
        }
    }
}

/// Sleek 6pt rounded progress bar inside the card (02-downloading-verifying.svg & 04-installing.svg).
final class MaintenanceProgressBarView: NSView {
    private let reduceMotion: () -> Bool
    private var animationTimer: Timer?
    private var animationStartedAt: TimeInterval = 0
    private(set) var animationPhase: Double = 0
    var isAnimating: Bool { animationTimer != nil }

    init(frame: NSRect = .zero, reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.reduceMotion = reduceMotion
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        animationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var statusLabel: String = L("Progress") {
        didSet {
            setAccessibilityLabel(statusLabel.isEmpty ? L("Progress") : statusLabel)
            needsDisplay = true
        }
    }
    var fraction: Double? {
        didSet {
            if let fraction {
                let pct = Int((max(0, min(1, fraction)) * 100).rounded())
                setAccessibilityValue(NSNumber(value: pct))
            } else {
                setAccessibilityValue(L("Indeterminate") as NSString)
            }
            updateAnimation()
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopAnimation()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(animationEnvironmentChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(animationEnvironmentChanged(_:)),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    private var shouldAnimate: Bool {
        fraction == nil && !isHiddenOrHasHiddenAncestor && window?.isVisible == true && !reduceMotion()
    }

    @objc private func animationEnvironmentChanged(_ notification: Notification) { updateAnimation() }
    @objc private func windowWillClose(_ notification: Notification) { stopAnimation() }

    private func updateAnimation() {
        needsDisplay = true
        guard shouldAnimate else { stopAnimation(); return }
        guard animationTimer == nil else { return }
        animationStartedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.shouldAnimate else { self.stopAnimation(); return }
            self.animationPhase = (ProcessInfo.processInfo.systemUptime - self.animationStartedAt)
                .truncatingRemainder(dividingBy: 2) / 2
            self.needsDisplay = true
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? { statusLabel.isEmpty ? L("Progress") : statusLabel }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { 100 }
    override func accessibilityValue() -> Any? {
        if let fraction {
            return Int((max(0, min(1, fraction)) * 100).rounded())
        }
        return L("Indeterminate")
    }
    override func accessibilityValueDescription() -> String? {
        if let fraction {
            return "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
        }
        return statusLabel.isEmpty ? L("In progress") : statusLabel
    }

    override func draw(_ dirtyRect: NSRect) {
        // The first draw also covers presentation before AppKit's occlusion notification arrives.
        if shouldAnimate && !isAnimating { updateAnimation() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = MaintenancePalette.current(for: effectiveAppearance)
        let trackPath = CGPath(roundedRect: bounds, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.addPath(trackPath)
        ctx.clip()

        ctx.setFillColor(p.progressTrack.cgColor)
        ctx.fill(bounds)

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cStart = MaintenancePalette.rgba(0, 122, 255).cgColor
        let cEnd = MaintenancePalette.rgba(34, 164, 230).cgColor

        if let fraction {
            let clamped = CGFloat(max(0, min(1, fraction)))
            if clamped > 0 {
                let fillWidth = max(6, round(bounds.width * clamped))
                let fillRect = CGRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
                let fillPath = CGPath(roundedRect: fillRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.addPath(fillPath)
                ctx.clip()
                if let g = CGGradient(colorsSpace: space, colors: [cStart, cEnd] as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: fillWidth, y: 0), options: [])
                }
            }
        } else {
            let cTrack = p.progressTrack.cgColor
            // Keep a static full-width cue for Reduce Motion; otherwise move the existing highlight.
            let fillWidth = reduceMotion() ? bounds.width : bounds.width * 0.65
            let travel = (1 - cos(animationPhase * 2 * .pi)) / 2
            let startX = (bounds.width - fillWidth) * CGFloat(travel)
            if let g = CGGradient(colorsSpace: space,
                                  colors: [cTrack, cStart, cEnd, cTrack] as CFArray,
                                  locations: [0, 0.3, 0.7, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: startX, y: 0),
                                       end: CGPoint(x: startX + fillWidth, y: 0), options: [])
            }
        }
        ctx.restoreGState()
    }
}

/// Full-width 1pt footer separator at y=188 (or y=168).
private final class MaintenanceDividerView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = MaintenancePalette.current(for: effectiveAppearance)
        p.footerDivider.setFill()
        bounds.fill()
    }
}

/// Native NSButton subclass rendering the exact 28pt height, 6pt radius button style from Figure 2.
final class MaintenanceActionButton: NSButton {
    override class var cellClass: AnyClass? {
        get { MaintenanceActionButtonCell.self }
        set {}
    }

    var isPrimaryAction = false {
        didSet {
            (cell as? MaintenanceActionButtonCell)?.isPrimaryAction = isPrimaryAction
            needsDisplay = true
        }
    }

    override var keyEquivalent: String {
        didSet {
            if keyEquivalent == "\r" {
                isPrimaryAction = true
            } else if window?.defaultButtonCell !== cell {
                isPrimaryAction = false
            }
            needsDisplay = true
        }
    }

    var rendersAsPrimary: Bool {
        guard let actionCell = cell as? MaintenanceActionButtonCell else {
            return isEnabled && (isPrimaryAction || keyEquivalent == "\r" || window?.defaultButtonCell === cell)
        }
        return actionCell.isPrimary(in: self)
    }

    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }

    override var title: String {
        didSet {
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 84, height: 28))
        let buttonCell = MaintenanceActionButtonCell(textCell: title)
        buttonCell.focusRingType = .exterior
        self.cell = buttonCell
        self.title = title
        self.target = target
        self.action = action
        self.bezelStyle = .rounded
        self.isBordered = true
        self.focusRingType = .exterior
        self.setAccessibilityRole(.button)
        self.setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth(for: self), height: 28)
    }

    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 0.5, dy: 0.5)
    }

    override func drawFocusRingMask() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
    }

    /// The panel's designed widths for its buttons; a translated title wider than its design still gets 8 points on
    /// either side (every English title fits its design with that margin).
    static func preferredWidth(for button: NSButton) -> CGFloat {
        let isPrimary = (button as? MaintenanceActionButton)?.rendersAsPrimary ?? (button.keyEquivalent == "\r")
        let font = NSFont.systemFont(ofSize: 13, weight: isPrimary ? .medium : .regular)
        let w = ceil((button.title as NSString).size(withAttributes: [.font: font]).width)
        let designed: CGFloat
        switch button.title {
        case L("Close"), L("Later"), L("Cancel"), L("Retry"): designed = 84
        case L("Update"): designed = 88
        case L("Skip This Version"): designed = 128
        case L("Show in Finder"): designed = 126
        case L("Replace and Open"): designed = 136
        case L("Download Manually…"): designed = 148
        case L("Install and Relaunch"): designed = 156
        case L("Install to Applications"): designed = 166
        case L("Show Installer in Finder"): designed = 178
        default: return max(84, w + 28)
        }
        return max(designed, w + 16)
    }
}

final class MaintenanceActionButtonCell: NSButtonCell {
    var isPrimaryAction = false

    func isPrimary(in controlView: NSView) -> Bool {
        guard isEnabled else { return false }
        if isPrimaryAction || keyEquivalent == "\r" || controlView.window?.defaultButtonCell === self {
            return true
        }
        if let button = controlView as? MaintenanceActionButton, button.isPrimaryAction {
            return true
        }
        return false
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = MaintenancePalette.current(for: controlView.effectiveAppearance)
        let isPrimary = isPrimary(in: controlView)
        let alpha: CGFloat = isEnabled ? 1.0 : 0.45

        ctx.saveGState()
        ctx.setAlpha(alpha)

        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)

        if isPrimary {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let topColor = isHighlighted
                ? MaintenancePalette.rgba(20, 114, 235).cgColor
                : MaintenancePalette.rgba(34, 132, 255).cgColor
            let bottomColor = isHighlighted
                ? MaintenancePalette.rgba(0, 88, 210).cgColor
                : MaintenancePalette.rgba(0, 102, 238).cgColor
            if let g = CGGradient(colorsSpace: space, colors: [topColor, bottomColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: cellFrame.height), options: [])
            }
            ctx.restoreGState()

            ctx.addPath(path)
            ctx.setStrokeColor(MaintenancePalette.rgba(0, 85, 204).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokePath()
        } else {
            let fill = !isEnabled
                ? p.buttonSecondaryDisabledFill
                : (isHighlighted ? p.buttonSecondaryHighlightedFill : p.buttonSecondaryFill)
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()

            ctx.addPath(path)
            ctx.setStrokeColor(p.buttonSecondaryBorder.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        let font = NSFont.systemFont(ofSize: 13, weight: isPrimary ? .medium : .regular)
        let textColor = isPrimary ? NSColor.white : (!isEnabled ? p.textTertiary : p.buttonSecondaryText)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let textSize = (title as NSString).size(withAttributes: attrs)
        let textPoint = NSPoint(
            x: round((cellFrame.width - textSize.width) / 2),
            y: round((cellFrame.height - textSize.height) / 2) - 0.5
        )
        (title as NSString).draw(at: textPoint, withAttributes: attrs)

        ctx.restoreGState()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame.insetBy(dx: 0.5, dy: 0.5)
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
    }
}
