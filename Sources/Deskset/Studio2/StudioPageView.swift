import AppKit
import DesksetCore

/// What the person did on a page.
enum StudioPageEvent: Equatable {
    /// A popup's item (by index among its items).
    case choose(item: String, index: Int)
    case segment(item: String, index: Int)
    case toggle(item: String, on: Bool)
    /// A percentage moved (`done`: the gesture ended).
    case percent(item: String, value: Double, done: Bool)
    /// A swatch was clicked (the color popover opens on it).
    case swatch(item: String, swatch: String)
    /// The pointer is on a swatch (nil: it left).
    case hoverSwatch(item: String, swatch: String?)
    case thumbnail(item: String, index: Int)
    case link(String)
    /// A note's link.
    case noteLink(item: String)
    /// A− (-1) or A+ (+1).
    case textSize(Int)
    /// A confirmation's Undo, and its suggestion.
    case undo(item: String)
    case suggestion(item: String)
    /// A number field (`part`: which of a pair; 0 for one).
    case number(item: String, part: Int, change: StudioNumberChange)
    /// The way back: the crumb clicked (0: the widget).
    case crumb(Int)
    /// The scope sentence's link, and the pointer on it.
    case scopeLink
    case scopeHover(Bool)
    /// A data token's chip.
    case tokenData(item: String)
    case example(item: String, index: Int)
    /// The pointer on a row that stands for parts of the widget (a color row): the canvas outlines them.
    case hoverItem(item: String, inside: Bool)
    /// What is typed in Every Setting's filter.
    case filter(String)
    /// The Undo of the confirmation at the top of the page.
    case topUndo
}

/// A view of one item that can take a new version of its item in place.
protocol StudioPageItemView: NSView {
    func update(_ kind: StudioPage.Kind)
    func height(forWidth width: CGFloat) -> CGFloat
}

/// An inspector page (`StudioPage`) drawn in AppKit: the search field, the title and its sentence, sections divided by
/// hairlines, rows of a label in quiet ink and a control, the footer's links. A new version of the page updates the
/// views of the rows it keeps in place (by id); only new rows are made. Laid out by hand, top down, 16 pt from the
/// sides.
final class StudioPageView: NSView {
    var onEvent: ((StudioPageEvent) -> Void)?
    private(set) var page: StudioPage?
    let searchField = NSSearchField()
    /// Small element-only hosts can omit the global Studio search while keeping the same property rows.
    var showsSearch = true {
        didSet { searchField.isHidden = !showsSearch; needsLayout = true }
    }
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var headings: [String: NSTextField] = [:]
    private var trailing: [String: StudioTextSizeButtons] = [:]
    private var trailingNotes: [String: NSTextField] = [:]
    private var dividers: [String: NSBox] = [:]
    private var itemViews: [String: StudioPageItemView] = [:]
    private var footerViews: [String: StudioLinkRowView] = [:]
    private var footerDivider = NSBox()
    /// How many item views were made (the self-tests check that an update keeps them).
    private(set) var viewsMade = 0
    let crumbsView = StudioCrumbsView()
    let scopeView = StudioScopeView()
    private var topConfirmationView: StudioConfirmationView?
    private let headerDivider = NSBox()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        searchField.placeholderString = StudioText[.searchPlaceholder]
        searchField.font = StudioPageStyle.valueFont
        searchField.controlSize = .regular
        searchField.focusRingType = .default
        searchField.setAccessibilityLabel(StudioText[.searchPlaceholder])
        addSubview(searchField)
        titleLabel.font = StudioPageStyle.titleFont()
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.staticText)
        addSubview(titleLabel)
        subtitleLabel.font = StudioPageStyle.noteFont
        subtitleLabel.textColor = StudioPageStyle.quietInk
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.isSelectable = false
        addSubview(subtitleLabel)
        for box in [footerDivider, headerDivider] { configureHairline(box); addSubview(box) }
        crumbsView.onClick = { [weak self] i in self?.onEvent?(.crumb(i)) }
        scopeView.onLink = { [weak self] in self?.onEvent?(.scopeLink) }
        scopeView.onHover = { [weak self] inside in self?.onEvent?(.scopeHover(inside)) }
        addSubview(crumbsView)
        addSubview(scopeView)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
    }

    @objc private func searchChanged() {
        guard page?.filter != nil else { return }
        onEvent?(.filter(searchField.stringValue))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureHairline(_ box: NSBox) {
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = StudioPageStyle.hairline
        box.titlePosition = .noTitle
    }

    // MARK: Applying a page

    /// Shows `page`: views of items kept by id are updated in place, new ones made, gone ones removed.
    func apply(_ page: StudioPage) {
        let old = self.page
        self.page = page
        titleLabel.stringValue = page.title
        titleLabel.font = StudioPageStyle.titleFont()
        subtitleLabel.stringValue = page.subtitle
        subtitleLabel.isHidden = page.subtitle.isEmpty
        if let filter = page.filter {
            searchField.placeholderString = filter.placeholder
            if searchField.currentEditor() == nil, searchField.stringValue != filter.text {
                searchField.stringValue = filter.text
            }
        } else {
            searchField.placeholderString = StudioText[.searchPlaceholder]
            if old?.filter != nil { searchField.stringValue = "" }
        }
        crumbsView.show(page.crumbs)
        crumbsView.isHidden = page.crumbs.isEmpty
        if let scope = page.scope { scopeView.show(scope) }
        scopeView.isHidden = page.scope == nil
        headerDivider.isHidden = page.scope == nil || !page.sections.isEmpty
        if let c = page.topConfirmation {
            if let v = topConfirmationView {
                v.update(.confirmation(c))
            } else {
                let v = StudioConfirmationView(confirmation: c)
                v.onUndo = { [weak self] in self?.onEvent?(.topUndo) }
                topConfirmationView = v
                addSubview(v)
            }
        } else {
            topConfirmationView?.removeFromSuperview()
            topConfirmationView = nil
        }
        var keep: Set<String> = []
        for section in page.sections {
            let heading = headings[section.id] ?? {
                let l = StudioPageStyle.label(section.title, font: StudioPageStyle.headingFont, color: .labelColor)
                l.setAccessibilityRole(.staticText)
                headings[section.id] = l
                addSubview(l)
                return l
            }()
            heading.stringValue = section.title
            heading.font = section.dense ? .systemFont(ofSize: 12.5, weight: .semibold) : StudioPageStyle.headingFont
            if case .note(let text)? = section.trailing {
                let note = trailingNotes[section.id] ?? {
                    let l = StudioPageStyle.label("", font: StudioPageStyle.smallFont)
                    l.alignment = .right
                    trailingNotes[section.id] = l
                    addSubview(l)
                    return l
                }()
                note.stringValue = text
            } else if let note = trailingNotes.removeValue(forKey: section.id) {
                note.removeFromSuperview()
            }
            if dividers[section.id] == nil {
                let box = NSBox()
                configureHairline(box)
                dividers[section.id] = box
                addSubview(box)
            }
            if section.trailing == .textSize {
                if trailing[section.id] == nil {
                    let buttons = StudioTextSizeButtons()
                    buttons.onStep = { [weak self] step in self?.onEvent?(.textSize(step)) }
                    trailing[section.id] = buttons
                    addSubview(buttons)
                }
            } else if let t = trailing.removeValue(forKey: section.id) {
                t.removeFromSuperview()
            }
            for item in section.items {
                keep.insert(item.id)
                if let view = itemViews[item.id], Self.sameShape(view, item.kind) {
                    view.update(item.kind)
                } else {
                    itemViews[item.id]?.removeFromSuperview()
                    let view = makeView(item)
                    itemViews[item.id] = view
                    addSubview(view)
                    viewsMade += 1
                }
            }
        }
        for (id, view) in itemViews where !keep.contains(id) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }
        let sectionIDs = Set(page.sections.map(\.id))
        for (id, l) in headings where !sectionIDs.contains(id) { l.removeFromSuperview(); headings[id] = nil }
        for (id, b) in dividers where !sectionIDs.contains(id) { b.removeFromSuperview(); dividers[id] = nil }
        for (id, t) in trailing where !sectionIDs.contains(id) { t.removeFromSuperview(); trailing[id] = nil }
        for (id, t) in trailingNotes where !sectionIDs.contains(id) { t.removeFromSuperview(); trailingNotes[id] = nil }
        var footerKeep: Set<String> = []
        for link in page.footer {
            footerKeep.insert(link.id)
            if let v = footerViews[link.id] {
                v.link = link
            } else {
                let v = StudioLinkRowView(link: link)
                v.onClick = { [weak self] in self?.onEvent?(.link(link.id)) }
                footerViews[link.id] = v
                addSubview(v)
            }
        }
        for (id, v) in footerViews where !footerKeep.contains(id) { v.removeFromSuperview(); footerViews[id] = nil }
        footerDivider.isHidden = page.footer.isEmpty
        if old != page { needsLayout = true }
        layoutPage()
    }

    /// Whether the view made for an item can show `kind` (the same kind of item and control).
    static func sameShape(_ view: StudioPageItemView, _ kind: StudioPage.Kind) -> Bool {
        switch (view, kind) {
        case (let v as StudioRowView, .row(let row)): return v.accepts(row.control)
        case (let v as StudioDenseRowView, .dense(let d)): return v.accepts(d.control)
        case (is StudioSwatchBlockView, .swatches), (is StudioThumbnailsView, .thumbnails),
             (is StudioLinkItemView, .link), (is StudioNoteView, .note), (is StudioConfirmationView, .confirmation),
             (is StudioTokenView, .token), (is StudioExamplesView, .examples), (is StudioBoxDiagramView, .box):
            return true
        default: return false
        }
    }

    private func makeView(_ item: StudioPage.Item) -> StudioPageItemView {
        let id = item.id
        switch item.kind {
        case .row(let row):
            let v = StudioRowView(row: row)
            v.onEvent = { [weak self] event in self?.forward(event, item: id) }
            return v
        case .dense(let d):
            let v = StudioDenseRowView(dense: d)
            v.onEvent = { [weak self] event in self?.forward(event, item: id) }
            return v
        case .token(let token):
            let v = StudioTokenView(token: token)
            v.onData = { [weak self] in self?.onEvent?(.tokenData(item: id)) }
            return v
        case .examples(let e):
            let v = StudioExamplesView(examples: e)
            v.onClick = { [weak self] i in self?.onEvent?(.example(item: id, index: i)) }
            return v
        case .box(let b):
            return StudioBoxDiagramView(box: b)
        case .swatches(let s):
            let v = StudioSwatchBlockView(swatches: s)
            v.onClick = { [weak self] swatch in self?.onEvent?(.swatch(item: id, swatch: swatch)) }
            v.onHover = { [weak self] swatch in self?.onEvent?(.hoverSwatch(item: id, swatch: swatch)) }
            return v
        case .thumbnails(let t):
            let v = StudioThumbnailsView(thumbnails: t)
            v.onClick = { [weak self] i in self?.onEvent?(.thumbnail(item: id, index: i)) }
            return v
        case .link(let link):
            let v = StudioLinkItemView(link: link)
            v.row.onClick = { [weak self] in self?.onEvent?(.link(link.id)) }
            return v
        case .note(let note):
            let v = StudioNoteView(note: note)
            v.onLink = { [weak self] in self?.onEvent?(.noteLink(item: id)) }
            return v
        case .confirmation(let c):
            let v = StudioConfirmationView(confirmation: c)
            v.onUndo = { [weak self] in self?.onEvent?(.undo(item: id)) }
            v.onSuggestion = { [weak self] in self?.onEvent?(.suggestion(item: id)) }
            return v
        }
    }

    private func forward(_ event: StudioRowView.Event, item id: String) {
        switch event {
        case .choose(let i): onEvent?(.choose(item: id, index: i))
        case .segment(let i): onEvent?(.segment(item: id, index: i))
        case .toggle(let on): onEvent?(.toggle(item: id, on: on))
        case .percent(let v, let done): onEvent?(.percent(item: id, value: v, done: done))
        case .swatch: onEvent?(.swatch(item: id, swatch: id))
        case .number(let part, let change): onEvent?(.number(item: id, part: part, change: change))
        case .hover(let inside): onEvent?(.hoverItem(item: id, inside: inside))
        }
    }

    // MARK: Lookup

    func itemView(_ id: String) -> NSView? { itemViews[id] }

    var topConfirmation: StudioConfirmationView? { topConfirmationView }

    /// The view of a swatch (for the color popover's anchor).
    func swatchView(item: String, swatch: String) -> NSView? {
        if let block = itemViews[item] as? StudioSwatchBlockView { return block.swatchView(swatch) }
        if let row = itemViews[item] as? StudioRowView { return row.swatchAnchor }
        if let dense = itemViews[item] as? StudioDenseRowView { return dense.row.swatchAnchor }
        return nil
    }

    func footerView(_ id: String) -> StudioLinkRowView? { footerViews[id] }

    func textSizeButtons(section: String) -> StudioTextSizeButtons? { trailing[section] }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutPage()
    }

    /// The height the page takes at `width`.
    func fittingHeight(width: CGFloat) -> CGFloat { layoutPage(width: width, place: false) }

    @discardableResult
    private func layoutPage() -> CGFloat { layoutPage(width: bounds.width, place: true) }

    @discardableResult
    private func layoutPage(width: CGFloat, place: Bool) -> CGFloat {
        let m = StudioPageStyle.margin
        let inner = max(width - 2 * m, 40)
        var y: CGFloat = 10
        func put(_ v: NSView, _ r: NSRect) { if place { v.frame = r } }
        if showsSearch {
            put(searchField, NSRect(x: m, y: y, width: inner, height: 28))
            y += 28 + 16
        }
        guard let page else { return y }
        let tight = page.tight
        if !page.crumbs.isEmpty {
            y -= 2
            put(crumbsView, NSRect(x: m, y: y, width: inner, height: 16))
            y += 16 + 3
        }
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        put(titleLabel, NSRect(x: m, y: y, width: inner, height: titleHeight))
        y += titleHeight + 3
        if !page.subtitle.isEmpty {
            let h = min(StudioPageStyle.height(of: page.subtitle, font: StudioPageStyle.noteFont, width: inner - 4) + 4, 36)
            put(subtitleLabel, NSRect(x: m, y: y, width: inner, height: h))
            y += h
        }
        if page.scope != nil {
            y += 5
            put(scopeView, NSRect(x: m, y: y, width: inner, height: 18))
            y += 18
        }
        if let v = topConfirmationView {
            y += 10
            let h = v.height(forWidth: inner)
            put(v, NSRect(x: m, y: y, width: inner, height: h))
            y += h
        }
        y += 14
        if !headerDivider.isHidden {
            put(headerDivider, NSRect(x: m, y: y, width: inner, height: 1))
            y += 1
        }
        for section in page.sections {
            if section.dense {
                dividers[section.id]?.isHidden = true
                y += 9
            } else {
                dividers[section.id]?.isHidden = false
                put(dividers[section.id]!, NSRect(x: m, y: y, width: inner, height: 1))
                y += 1 + (tight ? 10 : 13)
            }
            let heading = headings[section.id]!
            let hh = ceil(heading.intrinsicContentSize.height)
            if let note = trailingNotes[section.id] {
                let w = min(ceil(note.fittingSize.width) + 1, inner / 2)
                put(note, NSRect(x: m + inner - w, y: y + (hh - 14) / 2 + 1, width: w, height: 14))
                put(heading, NSRect(x: m, y: y, width: inner - w - 8, height: hh))
            } else if let buttons = trailing[section.id] {
                let size = buttons.intrinsicContentSize
                put(buttons, NSRect(x: m + inner - size.width, y: y + (hh - size.height) / 2, width: size.width,
                                    height: size.height))
                put(heading, NSRect(x: m, y: y, width: inner - size.width - 8, height: hh))
            } else {
                put(heading, NSRect(x: m, y: y, width: inner, height: hh))
            }
            y += hh + (section.dense ? 2 : tight ? 8 : 10)
            for (i, item) in section.items.enumerated() {
                guard let v = itemViews[item.id] else { continue }
                let h = v.height(forWidth: inner)
                put(v, NSRect(x: m, y: y, width: inner, height: h))
                y += h
                if i < section.items.count - 1 { y += Self.spacing(after: item.kind, section: section.id) }
            }
            y += section.dense ? 0 : tight ? 11 : 15
        }
        if page.sections.last?.dense == true { y += 12 }
        if !page.footer.isEmpty {
            put(footerDivider, NSRect(x: m, y: y, width: inner, height: 1))
            y += 1 + 4
            for link in page.footer {
                guard let v = footerViews[link.id] else { continue }
                put(v, NSRect(x: m, y: y, width: inner, height: 28))
                y += 28
            }
        }
        return y + 12
    }

    /// A menu's heading line (`NSMenuItem.sectionHeader` from macOS 14).
    static func heading(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The space between two items of a section: rows 8–9 pt apart, a swatch block's caption closer.
    static func spacing(after kind: StudioPage.Kind, section: String) -> CGFloat {
        switch kind {
        case .row: return section == "shows" ? 8 : 9
        case .swatches, .thumbnails: return 10
        case .note: return 8
        case .dense: return 0
        case .token: return 9
        default: return 8
        }
    }
}

// MARK: - Rows

/// A row: a label in quiet ink in a fixed column, and a control that fills the rest. A number's label can be dragged
/// to change it (`StudioScrubArea`).
final class StudioRowView: NSView, StudioPageItemView {
    enum Event {
        case choose(Int), segment(Int), toggle(Bool), percent(Double, Bool), swatch
        case number(part: Int, StudioNumberChange)
        case hover(Bool)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var row: StudioPage.Row
    /// Every Setting's smaller rows.
    let dense: Bool
    let label: NSTextField
    private(set) var controlView: NSView
    private let invalidMark = NSImageView()
    private let detailLabel = StudioPageStyle.label("", font: StudioPageStyle.monospaced(10.5),
                                                    color: StudioPageStyle.quietInk)
    private let percentLabel = StudioPageStyle.label("", font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular))
    /// Where the value comes from: an icon and a word in a quiet capsule.
    let sourceChip = StudioSourceChip()
    /// A value the control cannot show, as written.
    private let invalidText = StudioPageStyle.label("", font: StudioPageStyle.monospaced(11), color: StudioPageStyle.attentionText)
    /// Over the label of a number: drag it to change the number, ⌥-click it for the default.
    let scrubArea = StudioScrubArea()
    /// ↔ beside the label while it is dragged.
    private let scrubMark = NSImageView()
    /// A− / A+ beside a text size.
    private(set) var steppers: StudioTextSizeButtons?
    /// Quiet words after a number ("after “23%”").
    private let meaningLabel = StudioPageStyle.label("", font: StudioPageStyle.noteFont)
    var scrubbing = false { didSet { if scrubbing != oldValue { refreshLabel() } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(row: StudioPage.Row, dense: Bool = false) {
        self.row = row
        self.dense = dense
        label = StudioPageStyle.label("", font: dense ? .systemFont(ofSize: 11.5) : StudioPageStyle.labelFont)
        controlView = NSView()
        super.init(frame: .zero)
        addSubview(label)
        invalidMark.image = StudioPageStyle.symbol("exclamationmark.triangle.fill", size: 11, color: StudioPageStyle.attention)
        addSubview(invalidMark)
        addSubview(detailLabel)
        addSubview(percentLabel)
        addSubview(sourceChip)
        addSubview(invalidText)
        addSubview(meaningLabel)
        scrubMark.image = StudioPageStyle.symbol("arrow.left.and.right", size: 9.5, weight: .bold, color: .controlAccentColor)
        addSubview(scrubMark)
        controlView = makeControl(row.control)
        addSubview(controlView)
        scrubArea.onChange = { [weak self] change in self?.onEvent?(.number(part: 0, change)) }
        scrubArea.onScrubbing = { [weak self] on in self?.scrubbing = on }
        addSubview(scrubArea)
        update(.row(row))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Whether this view's control can show `control`.
    func accepts(_ control: StudioPage.Control) -> Bool {
        switch (row.control, control) {
        case (.popup, .popup), (.segmented, .segmented), (.toggle, .toggle), (.percent, .percent), (.color, .color),
             (.text, .text), (.number, .number), (.colorLabel, .colorLabel):
            return true
        case (.pair(let a), .pair(let b)):
            guard a.count == b.count, let pair = controlView as? StudioPairView else { return false }
            return zip(pair.halves, b).allSatisfy { $0.accepts($1) }
        default: return false
        }
    }

    /// The view a popover points at for this row's color.
    var swatchAnchor: NSView {
        if let c = controlView as? StudioColorLabelView { return c.swatch }
        return controlView
    }

    /// The number box of a number row (the self-tests type into it).
    var numberBox: StudioNumberBox? { controlView as? StudioNumberBox }

    private func makeControl(_ control: StudioPage.Control) -> NSView {
        switch control {
        case .popup:
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.controlSize = dense ? .small : .regular
            p.font = dense ? .systemFont(ofSize: 12) : StudioPageStyle.valueFont
            p.onAction { [weak self] c in
                guard let p = c as? NSPopUpButton else { return }
                self?.onEvent?(.choose(p.indexOfSelectedItem))
            }
            return p
        case .segmented:
            let s = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
            s.segmentDistribution = .fillEqually
            s.font = .systemFont(ofSize: dense ? 11 : 12)
            if dense { s.controlSize = .small }
            // The chosen segment in the accent color (design: the neutral white knob is 1.6–1.8 : 1 on its track).
            s.selectedSegmentBezelColor = .controlAccentColor
            s.onAction { [weak self] c in
                guard let s = c as? NSSegmentedControl else { return }
                self?.onEvent?(.segment(s.selectedSegment))
            }
            return s
        case .toggle:
            let s = NSSwitch()
            s.controlSize = .small
            s.onAction { [weak self] c in self?.onEvent?(.toggle((c as? NSSwitch)?.state == .on)) }
            return s
        case .percent:
            let s = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
            s.controlSize = .small
            s.isContinuous = true
            s.onAction { [weak self] c in
                guard let s = c as? NSSlider else { return }
                let done = NSApp.currentEvent.map { $0.type == .leftMouseUp } ?? true
                self?.percentLabel.stringValue = "\(Int((s.doubleValue * 100).rounded())) %"
                self?.onEvent?(.percent(s.doubleValue, done))
            }
            return s
        case .color:
            let s = StudioSwatchView(swatch: StudioPage.Swatch(id: "", kind: .color, label: ""), showsLabel: false)
            s.onClick = { [weak self] in self?.onEvent?(.swatch) }
            return s
        case .text:
            return StudioPageStyle.label("", font: StudioPageStyle.valueFont, color: .labelColor)
        case .number:
            let box = StudioNumberBox()
            if dense { box.field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
            box.onChange = { [weak self] change in self?.onEvent?(.number(part: 0, change)) }
            return box
        case .colorLabel:
            let v = StudioColorLabelView()
            v.onClick = { [weak self] in self?.onEvent?(.swatch) }
            v.onHover = { [weak self] inside in self?.onEvent?(.hover(inside)) }
            return v
        case .pair(let items):
            let pair = StudioPairView(items.map { StudioRowView(row: StudioPage.Row(label: "", control: $0, labelWidth: 0),
                                                                dense: dense) })
            for (i, half) in pair.halves.enumerated() {
                half.onEvent = { [weak self] e in
                    switch e {
                    case .number(_, let change): self?.onEvent?(.number(part: i, change))
                    case .choose(let index): self?.onEvent?(.number(part: i, .typed("#choose:\(index)")))
                    default: self?.onEvent?(e)
                    }
                }
            }
            return pair
        }
    }

    private func refreshLabel() {
        label.textColor = scrubbing ? .labelColor : StudioPageStyle.quietInk
        scrubMark.isHidden = !scrubbing
        needsLayout = true
    }

    func update(_ kind: StudioPage.Kind) {
        guard case .row(let row) = kind else { return }
        self.row = row
        label.stringValue = row.label
        label.toolTip = row.tooltip
        refreshLabel()
        invalidMark.isHidden = row.invalid == nil
        invalidMark.toolTip = row.invalid.map { StudioText.format(.invalidValue, $0) }
        invalidText.stringValue = row.invalid.map { "“\($0)”" } ?? ""
        invalidText.isHidden = row.invalid == nil || { if case .text = row.control { return true }; return false }()
        sourceChip.source = row.source
        sourceChip.isHidden = row.source == nil
        detailLabel.stringValue = row.detail ?? ""
        detailLabel.isHidden = row.detail == nil
        percentLabel.isHidden = true
        meaningLabel.isHidden = true
        scrubArea.isHidden = true
        switch row.control {
        case .popup(let popup):
            guard let p = controlView as? NSPopUpButton else { break }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in popup.items {
                if item.isHeading {
                    menu.addItem(StudioPageView.heading(item.title))
                    continue
                }
                let m = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                m.isEnabled = item.enabled
                var attributes: [NSAttributedString.Key: Any] = [.font: StudioPageStyle.valueFont]
                if popup.fonts, let face = item.face { attributes[.font] = StudioFontMenu.font(face, size: 13) }
                let title = NSMutableAttributedString(string: item.title, attributes: attributes)
                if !item.detail.isEmpty {
                    title.append(NSAttributedString(string: "  " + item.detail, attributes: [
                        .font: StudioPageStyle.noteFont, .foregroundColor: NSColor.secondaryLabelColor]))
                }
                m.attributedTitle = title
                if let symbol = item.symbol { m.image = StudioPageStyle.symbol(symbol, size: 11, weight: .semibold) }
                menu.addItem(m)
            }
            p.menu = menu
            if let s = popup.selected, s < popup.items.count {
                // Headings are items too: the index counts them.
                p.selectItem(at: s)
            }
            // The chosen item in the button: its own face for the font menus, the data's symbol in its color.
            if let s = popup.selected, s < popup.items.count, let selected = p.selectedItem {
                let item = popup.items[s]
                let size: CGFloat = dense ? 12 : 12.5
                let font = popup.fonts && item.face != nil ? StudioFontMenu.font(item.face!, size: size, weight: .medium)
                    : NSFont.systemFont(ofSize: size)
                selected.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
                if let symbol = popup.symbol {
                    selected.image = StudioPageStyle.symbol(symbol, size: 10.5, weight: .semibold,
                                                            color: popup.symbolColor.map(StudioPageStyle.color))
                }
            }
            p.toolTip = row.tooltip
        case .segmented(let seg):
            guard let s = controlView as? NSSegmentedControl else { break }
            if s.segmentCount != seg.items.count { s.segmentCount = seg.items.count }
            for (i, title) in seg.items.enumerated() {
                if let symbols = seg.symbols, i < symbols.count,
                   let image = NSImage(systemSymbolName: symbols[i], accessibilityDescription: title) {
                    s.setImage(image, forSegment: i)
                    s.setLabel("", forSegment: i)
                    s.setToolTip(title, forSegment: i)
                } else {
                    s.setLabel(title, forSegment: i)
                }
            }
            s.selectedSegment = seg.selected
            s.isEnabled = seg.enabled
            s.toolTip = row.tooltip
            StudioPageStyle.markChosenSegment(s)
        case .toggle(let on):
            (controlView as? NSSwitch)?.state = on ? .on : .off
        case .percent(let value):
            (controlView as? NSSlider)?.doubleValue = value
            percentLabel.stringValue = "\(Int((value * 100).rounded())) %"
            percentLabel.isHidden = false
        case .color(let swatch):
            (controlView as? StudioSwatchView)?.swatch = swatch
        case .text(let text):
            (controlView as? NSTextField)?.stringValue = text
        case .number(let n):
            (controlView as? StudioNumberBox)?.show(n)
            scrubArea.isHidden = row.label.isEmpty
            scrubArea.toolTip = StudioText[.scrubTip]
            if n.steppers {
                if steppers == nil {
                    let b = StudioTextSizeButtons()
                    b.onStep = { [weak self] step in self?.onEvent?(.number(part: 0, .textStep(step))) }
                    steppers = b
                    addSubview(b)
                }
            } else {
                steppers?.removeFromSuperview()
                steppers = nil
            }
            meaningLabel.stringValue = n.meaning ?? ""
            meaningLabel.isHidden = n.meaning == nil
        case .colorLabel(let c):
            (controlView as? StudioColorLabelView)?.show(c)
        case .pair(let items):
            guard let pair = controlView as? StudioPairView else { break }
            for (half, control) in zip(pair.halves, items) {
                half.update(.row(StudioPage.Row(label: "", control: control, labelWidth: 0)))
            }
        }
        if let invalid = row.invalid, case .text = row.control {
            (controlView as? NSTextField)?.stringValue = invalid
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if detailUnderControl(width: width) { return 24 + Self.detailLine }
        return dense ? 23.5 : 24
    }

    static let detailLine: CGFloat = 14

    /// With Rainmeter names on, a menu the name beside it would squeeze (its choice cut to "GPU…"): the name goes
    /// on a line of its own under the menu, which keeps its width.
    func detailUnderControl(width: CGFloat) -> Bool {
        guard !detailLabel.isHidden, case .popup(let popup) = row.control, popup.width == nil else { return false }
        let detail = min(ceil(detailLabel.intrinsicContentSize.width) + 4, 116)
        let x = row.labelWidth + (row.labelWidth > 0 ? 8 : 0)
        return width - detail - 6 - x < Self.chosenWidth(controlView as? NSPopUpButton)
    }

    /// The width a menu needs to show its chosen item whole: its words, its symbol, the arrows.
    static func chosenWidth(_ popup: NSPopUpButton?) -> CGFloat {
        guard let popup, let item = popup.selectedItem else { return 0 }
        let font = popup.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let words = item.attributedTitle?.size().width ?? (item.title as NSString).size(withAttributes: [.font: font]).width
        return ceil(words) + (item.image.map { $0.size.width + 6 } ?? 0) + 40
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let s = controlView as? NSSegmentedControl { StudioPageStyle.markChosenSegment(s) }
    }

    /// Whether the label needs more room than its column: a dense row's label then goes onto two lines (the dense row
    /// grows), never cut.
    var labelWraps: Bool {
        guard dense, let font = label.font, row.labelWidth > 0 else { return false }
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4 > row.labelWidth
    }

    override func layout() {
        super.layout()
        let under = detailUnderControl(width: bounds.width)
        // The name under the menu: the row's first 24 points are laid out as usual.
        let h = under ? bounds.height - Self.detailLine : bounds.height
        let wraps = labelWraps
        label.maximumNumberOfLines = wraps ? 2 : 1
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.cell?.wraps = wraps
        let lh = wraps ? StudioPageStyle.height(of: label.stringValue, font: label.font ?? StudioPageStyle.labelFont,
                                               width: row.labelWidth) : ceil(label.intrinsicContentSize.height)
        let labelWidth = row.labelWidth
        label.frame = NSRect(x: 0, y: (h - lh) / 2, width: labelWidth, height: lh)
        if !scrubMark.isHidden {
            let natural = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
            let lw = min(ceil(natural) + 7, labelWidth - 14)
            label.frame.size.width = lw
            scrubMark.frame = NSRect(x: lw + 4, y: (h - 12) / 2, width: 12, height: 12)
        }
        scrubArea.frame = NSRect(x: 0, y: 0, width: labelWidth, height: h)
        var x = labelWidth + (labelWidth > 0 ? 8 : 0)
        var right = bounds.width
        if !detailLabel.isHidden {
            // A little slack: drawn at 2x, the monospaced names come out a hair wider than measured.
            let w = min(ceil(detailLabel.intrinsicContentSize.width) + 4, 116)
            if under {
                detailLabel.frame = NSRect(x: x, y: h, width: w, height: 14)
            } else {
                detailLabel.frame = NSRect(x: right - w, y: (h - 14) / 2, width: w, height: 14)
                right -= w + 6
            }
        }
        if !sourceChip.isHidden {
            let w = sourceChip.intrinsicContentSize.width
            sourceChip.frame = NSRect(x: right - w, y: (h - 18) / 2, width: w, height: 18)
            right -= w + 6
        }
        if !invalidMark.isHidden {
            invalidMark.frame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
            x += 18
            if !invalidText.isHidden {
                let w = min(ceil(invalidText.intrinsicContentSize.width) + 4, 70)
                invalidText.frame = NSRect(x: x, y: (h - 15) / 2, width: w, height: 15)
                x += w + 4
            }
        }
        let controlHeight: CGFloat = dense ? 22 : 24
        switch row.control {
        case .segmented(let seg):
            let w = min(seg.width ?? (right - x), right - x)
            // Icons and dense rows sit at the start; words fill to the end.
            let start = seg.symbols != nil || dense ? x : right - w
            controlView.frame = NSRect(x: start, y: (h - controlHeight) / 2, width: w, height: controlHeight)
        case .popup(let popup):
            let w = min(popup.width ?? (right - x), right - x)
            controlView.frame = NSRect(x: x, y: (h - controlHeight) / 2, width: w, height: controlHeight)
        case .toggle:
            controlView.frame = NSRect(x: dense ? x : right - 38, y: (h - 20) / 2, width: 38, height: 20)
        case .percent:
            let pw: CGFloat = 44
            percentLabel.frame = NSRect(x: right - pw, y: (h - 15) / 2, width: pw, height: 15)
            percentLabel.alignment = .right
            controlView.frame = NSRect(x: x, y: (h - 20) / 2, width: max(right - pw - 6 - x, 40), height: 20)
        case .color:
            controlView.frame = NSRect(x: x, y: (h - 24) / 2, width: 24, height: 24)
        case .text:
            controlView.frame = NSRect(x: x, y: (h - 16) / 2, width: right - x, height: 16)
        case .number(let n):
            let w = min(n.width ?? (right - x), right - x)
            controlView.frame = NSRect(x: x, y: (h - controlHeight) / 2, width: w, height: controlHeight)
            var after = x + w + 8
            if let steppers {
                let size = steppers.intrinsicContentSize
                steppers.frame = NSRect(x: after, y: (h - size.height) / 2, width: size.width, height: size.height)
                after += size.width + 8
            }
            if !meaningLabel.isHidden {
                meaningLabel.frame = NSRect(x: after, y: (h - 15) / 2, width: max(right - after, 0), height: 15)
            }
        case .colorLabel:
            controlView.frame = NSRect(x: x, y: 0, width: right - x, height: h)
        case .pair:
            controlView.frame = NSRect(x: x, y: 0, width: right - x, height: h)
        }
    }
}

/// Two controls side by side, each half of the room (Size: W · H).
final class StudioPairView: NSView {
    let halves: [StudioRowView]

    override var isFlipped: Bool { true }

    init(_ halves: [StudioRowView]) {
        self.halves = halves
        super.init(frame: .zero)
        halves.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        guard !halves.isEmpty else { return }
        let gap: CGFloat = 6
        let w = (bounds.width - gap * CGFloat(halves.count - 1)) / CGFloat(halves.count)
        for (i, v) in halves.enumerated() {
            v.frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
        }
    }
}

// MARK: - Swatches

/// Where a value comes from, always an icon and a word: an option (slider icon), live data (radio waves, in the
/// accent color), a rule (a branch), a shared style (a brush).
final class StudioSourceChip: NSView {
    var source: StudioValueSource? { didSet { refresh() } }
    private let icon = NSImageView()
    private let word = StudioPageStyle.label("", font: .systemFont(ofSize: 11, weight: .medium))

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        addSubview(icon)
        addSubview(word)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        guard let source else { return }
        let live = source == .live
        let tint: NSColor = live ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.78)
        icon.image = StudioPageStyle.symbol(source.symbol, size: 9.5, weight: .semibold, color: tint)
        word.stringValue = source.word
        word.textColor = tint
        setAccessibilityLabel(source.word)
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        let live = source == .live
        layer?.backgroundColor = (live ? NSColor.controlAccentColor.withAlphaComponent(0.12) : StudioPageStyle.fieldFill).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(live ? 0 : 0.08).cgColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 7 + 12 + 4 + ceil(word.intrinsicContentSize.width) + 7, height: 18)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 7, y: 3, width: 12, height: 12)
        word.frame = NSRect(x: 23, y: 1.5, width: bounds.width - 28, height: 15)
    }
}

/// One swatch: a circle of the color (a rounded square for the card), half light and half dark while Text and Card
/// follow the look, a dashed circle for More…; the name under it; a ring in the accent color while it is open.
final class StudioSwatchView: NSControl {
    var swatch: StudioPage.Swatch { didSet { needsDisplay = true; nameLabel.stringValue = swatch.label; updateName() } }
    let showsLabel: Bool
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private let nameLabel = NSTextField(labelWithString: "")
    static let dot: CGFloat = 24
    static let ring: CGFloat = 32

    override var isFlipped: Bool { true }

    init(swatch: StudioPage.Swatch, showsLabel: Bool = true) {
        self.swatch = swatch
        self.showsLabel = showsLabel
        super.init(frame: .zero)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        if showsLabel { addSubview(nameLabel) }
        nameLabel.stringValue = swatch.label
        updateName()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateName() {
        nameLabel.font = .systemFont(ofSize: 11, weight: swatch.active ? .semibold : .regular)
        nameLabel.textColor = swatch.active ? .labelColor : StudioPageStyle.quietInk
        toolTip = swatch.tooltip
        setAccessibilityLabel(swatch.label)
    }

    override func layout() {
        super.layout()
        nameLabel.frame = NSRect(x: -4, y: Self.ring + 5, width: bounds.width + 8, height: 14)
    }

    /// The circle's rectangle (the anchor of the color popover).
    var dotRect: NSRect {
        let size = showsLabel ? Self.ring : min(bounds.width, bounds.height)
        return NSRect(x: (bounds.width - size) / 2, y: 0, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ringRect = dotRect
        let d = min(Self.dot, ringRect.width)
        let dot = NSRect(x: ringRect.midX - d / 2, y: ringRect.midY - d / 2, width: d, height: d)
        let square = swatch.kind == .card
        func shape(_ r: NSRect) -> NSBezierPath {
            square ? NSBezierPath(roundedRect: r, xRadius: r.width * 0.28, yRadius: r.width * 0.28)
                : NSBezierPath(ovalIn: r)
        }
        if swatch.active {
            NSColor.controlAccentColor.setStroke()
            let ring = shape(ringRect.insetBy(dx: 1, dy: 1))
            if square {
                let r = ringRect.insetBy(dx: 1, dy: 1)
                let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
                p.lineWidth = 2
                p.stroke()
            } else {
                ring.lineWidth = 2
                ring.stroke()
            }
        }
        switch swatch.kind {
        case .more:
            let p = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.setLineDash([2.5, 2], count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            p.stroke()
            if let image = StudioPageStyle.symbol("ellipsis", size: d * 0.42, weight: .bold, color: StudioPageStyle.quietInk) {
                image.draw(in: NSRect(x: dot.midX - image.size.width / 2, y: dot.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height))
            }
        case .text, .card, .color:
            if swatch.follows, swatch.kind != .color {
                // Half light, half dark: it follows the look.
                let path = shape(dot)
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                NSColor.white.setFill()
                dot.fill()
                NSColor(white: swatch.kind == .card ? 0.16 : 0.12, alpha: 1).setFill()
                if swatch.kind == .card {
                    NSRect(x: dot.minX, y: dot.minY, width: dot.width / 2, height: dot.height).fill()
                } else {
                    NSRect(x: dot.minX, y: dot.minY, width: dot.width / 2, height: dot.height).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                NSColor.labelColor.withAlphaComponent(0.22).setStroke()
                let outline = shape(dot.insetBy(dx: 0.3, dy: 0.3))
                outline.lineWidth = 0.6
                outline.stroke()
            } else {
                let c = swatch.color.map(StudioPageStyle.color) ?? .clear
                if (swatch.color?.a ?? 255) < 250 { drawChecker(in: shape(dot), rect: dot) }
                c.setFill()
                shape(dot).fill()
                NSColor.labelColor.withAlphaComponent(0.15).setStroke()
                let outline = shape(dot.insetBy(dx: 0.25, dy: 0.25))
                outline.lineWidth = 0.5
                outline.stroke()
            }
        }
    }

    private func drawChecker(in path: NSBezierPath, rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        let s: CGFloat = 4
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : s)
            while x < rect.maxX { NSRect(x: x, y: y, width: s, height: s).fill(); x += 2 * s }
            y += s
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // The keyboard reaches it (Tab), and Space or Return opens it, as a click does; the focus ring follows the dot.
    override var acceptsFirstResponder: Bool { onClick != nil }
    override var canBecomeKeyView: Bool { onClick != nil && !isHiddenOrHasHiddenAncestor }
    override var focusRingMaskBounds: NSRect { dotRect }
    override func drawFocusRingMask() {
        let r = dotRect.insetBy(dx: 1, dy: 1)
        (swatch.kind == .card ? NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10) : NSBezierPath(ovalIn: r)).fill()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The Colors section's body, one rule on every widget page: the parts' colors (at most four, named for what they
/// paint), then Text and Card — half light, half dark with "follow the look" beside them until changed — and More…;
/// under them, what the pointed-at swatch paints.
final class StudioSwatchBlockView: NSView, StudioPageItemView {
    var onClick: ((String) -> Void)?
    var onHover: ((String?) -> Void)?
    private(set) var swatches: StudioPage.Swatches
    private var views: [String: StudioSwatchView] = [:]
    private let divider = NSBox()
    private let followNote = StudioPageStyle.label("", font: StudioPageStyle.smallFont)
    private let captionIcon = NSImageView()
    private let caption = StudioPageStyle.label("", font: StudioPageStyle.noteFont)
    static let cell: CGFloat = 66
    static let cellHeight: CGFloat = 32 + 5 + 14

    override var isFlipped: Bool { true }

    init(swatches: StudioPage.Swatches) {
        self.swatches = swatches
        super.init(frame: .zero)
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = StudioPageStyle.hairline
        addSubview(divider)
        addSubview(followNote)
        captionIcon.image = StudioPageStyle.symbol("scope", size: 10, color: StudioPageStyle.quietInk)
        addSubview(captionIcon)
        addSubview(caption)
        update(.swatches(swatches))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func swatchView(_ id: String) -> StudioSwatchView? { views[id] }

    func update(_ kind: StudioPage.Kind) {
        guard case .swatches(let s) = kind else { return }
        swatches = s
        let all = s.parts + s.pair
        let ids = Set(all.map(\.id))
        for (id, v) in views where !ids.contains(id) { v.removeFromSuperview(); views[id] = nil }
        for swatch in all {
            if let v = views[swatch.id] {
                v.swatch = swatch
            } else {
                let v = StudioSwatchView(swatch: swatch)
                let id = swatch.id
                v.onClick = { [weak self] in self?.onClick?(id) }
                v.onHover = { [weak self] inside in self?.onHover?(inside ? id : nil) }
                views[swatch.id] = v
                addSubview(v)
            }
        }
        followNote.stringValue = s.followNote ?? ""
        followNote.isHidden = s.followNote == nil
        caption.stringValue = s.caption ?? ""
        caption.isHidden = s.caption == nil
        captionIcon.isHidden = s.caption == nil
        needsLayout = true
    }

    /// Everything on one line when the parts and the pair fit four cells and the note fits beside them; else the
    /// parts, then the pair.
    func oneRow(width: CGFloat) -> Bool {
        let cells = swatches.parts.count + swatches.pair.count
        guard cells <= 4 else { return false }
        guard swatches.followNote != nil else { return true }
        let note = ceil(followNote.intrinsicContentSize.width) + 6
        return CGFloat(cells) * Self.cell + (swatches.parts.isEmpty ? 0 : 5) + note <= width
    }

    var oneRow: Bool { oneRow(width: bounds.width) }

    func height(forWidth width: CGFloat) -> CGFloat {
        let rows: CGFloat = oneRow(width: width) || swatches.parts.isEmpty ? 1 : 2
        var h = rows * Self.cellHeight + (rows - 1) * 8
        if swatches.caption != nil { h += 8 + 15 }
        return h
    }

    override func layout() {
        super.layout()
        let cell = Self.cell, ch = Self.cellHeight
        var x: CGFloat = 0, y: CGFloat = 0
        for s in swatches.parts {
            views[s.id]?.frame = NSRect(x: x, y: y, width: cell, height: ch)
            x += cell
        }
        divider.isHidden = !(oneRow && !swatches.parts.isEmpty)
        if oneRow {
            if !swatches.parts.isEmpty {
                divider.frame = NSRect(x: x + 2, y: y + 1, width: 1, height: 30)
                x += 5
            }
        } else if !swatches.parts.isEmpty {
            x = 0
            y += ch + 8
        }
        for s in swatches.pair {
            views[s.id]?.frame = NSRect(x: x, y: y, width: cell, height: ch)
            x += cell
        }
        if !followNote.isHidden {
            let w = ceil(followNote.intrinsicContentSize.width) + 4
            followNote.frame = NSRect(x: x + 2, y: y + 9, width: min(w, max(bounds.width - x - 2, 0)), height: 14)
        }
        if !caption.isHidden {
            let cy = y + ch + 8
            captionIcon.frame = NSRect(x: 4, y: cy + 1, width: 12, height: 12)
            caption.frame = NSRect(x: 21, y: cy, width: bounds.width - 21, height: 15)
        }
    }
}

// MARK: - Thumbnails

/// A row of thumbnails to choose by result (the looks): the picture, its name under it; the chosen one framed in the
/// accent color.
final class StudioThumbnailsView: NSView, StudioPageItemView {
    var onClick: ((Int) -> Void)?
    private(set) var thumbnails: StudioPage.Thumbnails
    private var tiles: [StudioTileView] = []

    override var isFlipped: Bool { true }

    init(thumbnails: StudioPage.Thumbnails) {
        self.thumbnails = thumbnails
        super.init(frame: .zero)
        update(.thumbnails(thumbnails))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var tileViews: [StudioTileView] { tiles }

    func update(_ kind: StudioPage.Kind) {
        guard case .thumbnails(let t) = kind else { return }
        thumbnails = t
        while tiles.count > t.tiles.count { tiles.removeLast().removeFromSuperview() }
        while tiles.count < t.tiles.count {
            let i = tiles.count
            let v = StudioTileView()
            v.onClick = { [weak self] in self?.onClick?(i) }
            tiles.append(v)
            addSubview(v)
        }
        for (i, tile) in t.tiles.enumerated() { tiles[i].tile = tile }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 42 + 5 + 14 }

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        let gap: CGFloat = 8
        let w = (bounds.width - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        for (i, v) in tiles.enumerated() {
            v.frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
        }
    }
}

final class StudioTileView: NSView {
    var tile = StudioPage.Thumbnails.Tile(title: "", image: nil, selected: false) {
        didSet {
            name.stringValue = tile.title
            name.font = .systemFont(ofSize: 11, weight: tile.selected ? .semibold : .regular)
            name.textColor = tile.selected ? .labelColor : StudioPageStyle.quietInk
            setAccessibilityLabel(tile.title)
            setAccessibilityValue(tile.selected ? StudioText[.selected] : nil)
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?
    private let name = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.alignment = .center
        addSubview(name)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var tileRect: NSRect {
        let w: CGFloat = min(64, bounds.width)
        return NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: 42)
    }

    override func layout() {
        super.layout()
        name.frame = NSRect(x: -4, y: 47, width: bounds.width + 8, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = tileRect
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        StudioPageStyle.fieldFill.setFill()
        r.fill()
        if let image = tile.image {
            // Fill the tile, the picture's middle.
            let s = image.size
            let scale = max(r.width / max(s.width, 1), r.height / max(s.height, 1))
            let size = NSSize(width: s.width * scale, height: s.height * scale)
            image.draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width,
                                  height: size.height), from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        if tile.selected {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            ring.lineWidth = 2
            ring.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.10).setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 8, yRadius: 8)
            ring.lineWidth = 0.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Links, notes, confirmations, A− / A+

/// A quiet link row: its title, a detail in quiet ink, a chevron.
final class StudioLinkRowView: NSControl {
    var link: StudioPage.Link { didSet { refresh() } }
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let title = StudioPageStyle.label("", font: StudioPageStyle.valueFont, color: .labelColor)
    private let detail = StudioPageStyle.label("", font: .systemFont(ofSize: 12))
    private let chevron = NSImageView()

    override var isFlipped: Bool { true }

    init(link: StudioPage.Link) {
        self.link = link
        super.init(frame: .zero)
        chevron.image = StudioPageStyle.symbol("chevron.right", size: 10, weight: .semibold, color: StudioPageStyle.faintInk)
        detail.alignment = .right
        for v in [icon, title, detail, chevron] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        title.stringValue = link.title
        title.textColor = link.enabled ? .labelColor : .tertiaryLabelColor
        detail.stringValue = link.detail
        icon.image = link.symbol.flatMap { StudioPageStyle.symbol($0, size: 11.5, color: StudioPageStyle.quietInk) }
        icon.isHidden = link.symbol == nil
        setAccessibilityLabel(link.detail.isEmpty ? link.title : "\(link.title), \(link.detail)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 0
        if !icon.isHidden {
            icon.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
            x = 23
        }
        let tw = ceil(title.intrinsicContentSize.width) + 4
        title.frame = NSRect(x: x, y: (h - 16) / 2, width: min(tw, bounds.width - x), height: 16)
        chevron.frame = NSRect(x: bounds.width - 10, y: (h - 12) / 2, width: 10, height: 12)
        let dx = x + tw + 12
        detail.frame = NSRect(x: dx, y: (h - 15) / 2, width: max(bounds.width - 18 - dx, 0), height: 15)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if link.enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        if link.enabled { onClick?() }
        return true
    }
}

/// A link row inside a section ("All Options…", "More…").
final class StudioLinkItemView: NSView, StudioPageItemView {
    let row: StudioLinkRowView

    override var isFlipped: Bool { true }

    init(link: StudioPage.Link) {
        row = StudioLinkRowView(link: link)
        super.init(frame: .zero)
        addSubview(row)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ kind: StudioPage.Kind) {
        if case .link(let l) = kind { row.link = l }
    }

    func height(forWidth width: CGFloat) -> CGFloat { 24 }

    override func layout() {
        super.layout()
        row.frame = bounds
    }
}

/// A quiet sentence with a symbol, and a link under it or at its end.
final class StudioNoteView: NSView, StudioPageItemView {
    var onLink: (() -> Void)?
    private(set) var note: StudioPage.Note
    private let icon = NSImageView()
    private let text = StudioPageStyle.wrapping("")
    let linkButton = NSButton(title: "", target: nil, action: nil)

    override var isFlipped: Bool { true }

    init(note: StudioPage.Note) {
        self.note = note
        super.init(frame: .zero)
        linkButton.isBordered = false
        linkButton.onAction { [weak self] _ in self?.onLink?() }
        for v in [icon, text, linkButton] as [NSView] { addSubview(v) }
        update(.note(note))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ kind: StudioPage.Kind) {
        guard case .note(let n) = kind else { return }
        note = n
        icon.image = StudioPageStyle.symbol(n.symbol, size: 10.5, color: StudioPageStyle.quietInk)
        text.stringValue = n.text
        linkButton.isHidden = n.link == nil
        linkButton.attributedTitle = NSAttributedString(string: n.link ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.linkColor])
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if linkBeside(width: width) != nil { return max(StudioPageStyle.height(of: note.text, font: StudioPageStyle.noteFont,
                                                                             width: width - 17), 16) }
        return StudioPageStyle.height(of: note.text, font: StudioPageStyle.noteFont, width: width - 17)
            + (note.link == nil ? 0 : 18)
    }

    /// Where the link goes on the text's own line, when both fit on one ("This widget only   All 23 Widgets"); nil:
    /// the link goes under the text.
    private func linkBeside(width: CGFloat) -> CGFloat? {
        guard note.link != nil else { return nil }
        let words = ceil((note.text as NSString).size(withAttributes: [.font: StudioPageStyle.noteFont]).width) + 2
        let link = ceil(linkButton.intrinsicContentSize.width)
        return 17 + words + 12 + link <= width ? 17 + words + 12 : nil
    }

    override func layout() {
        super.layout()
        let th = StudioPageStyle.height(of: note.text, font: StudioPageStyle.noteFont, width: bounds.width - 17)
        icon.frame = NSRect(x: 0, y: 1, width: 12, height: 13)
        text.frame = NSRect(x: 17, y: 0, width: bounds.width - 17, height: th)
        let lw = ceil(linkButton.intrinsicContentSize.width)
        if let x = linkBeside(width: bounds.width) {
            text.frame.size.width = x - 12 - 17
            linkButton.frame = NSRect(x: x, y: (th - 16) / 2, width: lw, height: 16)
        } else {
            linkButton.frame = NSRect(x: 17, y: th + 2, width: lw, height: 16)
        }
    }
}

/// The named confirmation under the control that made a change, with Undo; a second line offers to do the same to
/// others.
final class StudioConfirmationView: NSView, StudioPageItemView {
    var onUndo: (() -> Void)?
    var onSuggestion: (() -> Void)?
    private(set) var confirmation: StudioPage.Confirmation
    private let check = NSImageView()
    private let text = StudioPageStyle.wrapping("", font: .systemFont(ofSize: 12), color: .labelColor)
    let undoButton = NSButton(title: "", target: nil, action: nil)
    private let suggestion = StudioPageStyle.wrapping("")
    let suggestionButton = NSButton(title: "", target: nil, action: nil)

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(confirmation: StudioPage.Confirmation) {
        self.confirmation = confirmation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.6
        check.image = StudioPageStyle.symbol("checkmark.circle.fill", size: 12, color: StudioPageStyle.okGreen)
        for b in [undoButton, suggestionButton] { b.isBordered = false }
        undoButton.onAction { [weak self] _ in self?.onUndo?() }
        suggestionButton.onAction { [weak self] _ in self?.onSuggestion?() }
        for v in [check, text, undoButton, suggestion, suggestionButton] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        update(.confirmation(confirmation))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        let dark = StudioPageStyle.isDark(effectiveAppearance)
        layer?.backgroundColor = StudioPageStyle.okGreen.withAlphaComponent(dark ? 0.14 : 0.09).cgColor
        layer?.borderColor = StudioPageStyle.okGreen.withAlphaComponent(0.35).cgColor
    }

    func update(_ kind: StudioPage.Kind) {
        guard case .confirmation(let c) = kind else { return }
        confirmation = c
        text.stringValue = c.text
        undoButton.attributedTitle = NSAttributedString(string: c.undo, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.linkColor])
        suggestion.stringValue = c.suggestion ?? ""
        suggestion.isHidden = c.suggestion == nil
        suggestionButton.isHidden = c.suggestionAction == nil
        suggestionButton.attributedTitle = NSAttributedString(string: c.suggestionAction ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.linkColor])
        setAccessibilityLabel(c.text)
        needsLayout = true
    }

    private func textWidth(_ width: CGFloat) -> CGFloat {
        width - 18 - 9 - 9 - ceil(undoButton.intrinsicContentSize.width) - 6
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var h = 6 + max(StudioPageStyle.height(of: confirmation.text, font: .systemFont(ofSize: 12),
                                                 width: textWidth(width)), 16)
        if let s = confirmation.suggestion {
            h += 5 + StudioPageStyle.height(of: s, font: StudioPageStyle.noteFont, width: width - 18 - 18) + 16
        }
        return h + 6
    }

    override func layout() {
        super.layout()
        let uw = ceil(undoButton.intrinsicContentSize.width)
        let tw = textWidth(bounds.width)
        let th = max(StudioPageStyle.height(of: confirmation.text, font: .systemFont(ofSize: 12), width: tw), 16)
        check.frame = NSRect(x: 9, y: 8, width: 13, height: 13)
        text.frame = NSRect(x: 27, y: 6, width: tw, height: th)
        undoButton.frame = NSRect(x: bounds.width - 9 - uw, y: 5, width: uw, height: 17)
        if !suggestion.isHidden {
            let sw = bounds.width - 27 - 9
            let sh = StudioPageStyle.height(of: confirmation.suggestion ?? "", font: StudioPageStyle.noteFont, width: sw)
            suggestion.frame = NSRect(x: 27, y: 6 + th + 5, width: sw, height: sh)
            suggestionButton.frame = NSRect(x: 27, y: 6 + th + 5 + sh, width: ceil(suggestionButton.intrinsicContentSize.width),
                                            height: 16)
        }
    }
}

/// A− and A+ in one capsule, at the right of the Fonts heading: every text in the widget smaller or bigger.
final class StudioTextSizeButtons: NSView {
    var onStep: ((Int) -> Void)?
    let smaller = NSButton(title: "A−", target: nil, action: nil)
    let bigger = NSButton(title: "A+", target: nil, action: nil)
    private let divider = NSBox()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        for (b, size, step) in [(smaller, CGFloat(11), -1), (bigger, CGFloat(13), 1)] {
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8)])
            b.onAction { [weak self] _ in self?.onStep?(step) }
            addSubview(b)
        }
        smaller.setAccessibilityLabel(StudioText[.textSmaller])
        bigger.setAccessibilityLabel(StudioText[.textBigger])
        smaller.toolTip = StudioText[.textSmaller]
        bigger.toolTip = StudioText[.textBigger]
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = NSColor.labelColor.withAlphaComponent(0.12)
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() { layer?.backgroundColor = StudioPageStyle.fieldFill.cgColor }

    override var intrinsicContentSize: NSSize { NSSize(width: 61, height: 22) }

    override func layout() {
        super.layout()
        smaller.frame = NSRect(x: 0, y: 0, width: 30, height: 22)
        divider.frame = NSRect(x: 30, y: 5, width: 1, height: 12)
        bigger.frame = NSRect(x: 31, y: 0, width: 30, height: 22)
    }
}

/// Font faces as the font menus show them: the Mac's own faces by their names, each drawn in itself.
enum StudioFontMenu {
    /// A face's font, from its skin name (`System Rounded`, a family, a PostScript name), or the system font.
    static func font(_ face: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        switch face.lowercased() {
        case "system", "": return base
        case "system rounded":
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case "system mono": return .monospacedSystemFont(ofSize: size, weight: weight)
        case "system serif":
            return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        default:
            if let f = NSFont(name: face, size: size) { return f }
            if let f = NSFontManager.shared.font(withFamily: face, traits: [], weight: 5, size: size) { return f }
            return base
        }
    }

    /// How a face is called in the menus: the Mac's own names for its system faces.
    static func title(_ face: String) -> String {
        switch face.lowercased() {
        case "system", "": return StudioText.language == .chinese ? "苹方 · SF Pro" : "SF Pro"
        case "system rounded": return "SF Pro Rounded"
        case "system mono": return "SF Mono"
        case "system serif": return "New York"
        default:
            // A Windows font macOS does not have is called by the face drawn in its place ("Segoe UI" → SF Pro).
            if let sub = Fonts.substitution(for: face) { return sub == "System Font" ? title("System") : sub }
            return face
        }
    }

    /// The faces the menus offer after the widget's own: the Mac's system faces, then common families.
    static let common = ["System", "System Rounded", "System Mono", "System Serif", "Helvetica Neue", "Avenir Next",
                         "Futura", "Gill Sans", "Georgia", "Menlo", "PingFang SC"]
}
