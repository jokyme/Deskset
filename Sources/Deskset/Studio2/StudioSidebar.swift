import AppKit
import DesksetCore

/// The sidebar — open at the Build depth (⌃⌘S; Add ⇧⌘L, Layers ⌥⌘L): two pages under a segmented control whose
/// chosen page is filled with the accent color, "Add" (named after the toolbar's Add, which opens it) and "Layers";
/// at its foot, a quiet hint when there is one ("Rainmeter names on · ⌥⌘R to hide").
final class StudioSidebarViewController: NSViewController {
    enum Page: Int { case add, layers }

    let tabs = NSSegmentedControl(labels: [StudioText[.tabAdd], StudioText[.tabLayers]], trackingMode: .selectOne,
                                  target: nil, action: nil)
    let layersView = StudioLayersView()
    let addView = StudioAddView()
    let hint = StudioHintPill()
    private(set) var page = Page.layers
    var onPageChange: ((Page) -> Void)?

    override func loadView() {
        let v = StudioSidebarContainer()
        v.setAccessibilityLabel(StudioText[.sidebar])
        v.setAccessibilityElement(false)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentStyle = .rounded
        tabs.controlSize = .regular
        tabs.selectedSegment = page.rawValue
        tabs.selectedSegmentBezelColor = .controlAccentColor
        tabs.setAccessibilityLabel(StudioText[.sidebar])
        for i in 0..<2 { tabs.setAlignment(.center, forSegment: i) }
        v.addSubview(tabs)
        v.addSubview(addView)
        v.addSubview(layersView)
        hint.isHidden = true
        v.addSubview(hint)
        v.onLayout = { [weak self] in self?.layout() }
        view = v
        show(page)
    }

    /// Shows a page.
    func show(_ page: Page) {
        _ = view
        self.page = page
        tabs.selectedSegment = page.rawValue
        StudioPageStyle.markChosenSegment(tabs)
        addView.isHidden = page != .add
        layersView.isHidden = page != .layers
        layout()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        StudioPageStyle.markChosenSegment(tabs)
    }

    @objc func tabChanged() {
        let p = Page(rawValue: tabs.selectedSegment) ?? .layers
        show(p)
        onPageChange?(p)
    }

    /// The hint at the foot (nil: none).
    func setHint(_ text: String?) {
        _ = view
        hint.text = text ?? ""
        hint.isHidden = text == nil
        layout()
    }

    func layout() {
        guard isViewLoaded else { return }
        let w = view.bounds.width, h = view.bounds.height
        // The tabs sit level with the design's (their middle 70 pt from the window's top).
        let top = StudioCanvasViewController.toolbarHeight - 2
        tabs.frame = NSRect(x: 10, y: top, width: max(w - 20, 60), height: 24)
        let segment = (tabs.frame.width - 6) / 2
        for i in 0..<2 { tabs.setWidth(segment, forSegment: i) }
        var bottom = h - 12
        if !hint.isHidden {
            let size = hint.fittingSize(width: w - 20)
            hint.frame = NSRect(x: 10, y: bottom - size.height, width: size.width, height: size.height)
            bottom = hint.frame.minY - 8
        }
        let pageTop = tabs.frame.maxY + 10
        let pageFrame = NSRect(x: 0, y: pageTop, width: w, height: max(bottom - pageTop, 0))
        layersView.frame = pageFrame
        addView.frame = pageFrame
        layersView.needsLayout = true
        addView.needsLayout = true
    }

    /// The views an off-screen snapshot draws, in order (their scroll views' own drawing is left out).
    var snapshotViews: [NSView] {
        var views: [NSView] = [tabs]
        if page == .layers {
            views += [layersView.searchField, layersView.partsOutline, layersView.emptyLabel, layersView.dataHeader,
                      layersView.dataOutline]
        } else {
            views += addView.snapshotViews
        }
        views.append(hint)
        return views
    }
}

final class StudioSidebarContainer: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// A quiet hint in a rounded fill, with a light bulb: "Rainmeter names on · ⌥⌘R to hide".
final class StudioHintPill: NSView {
    var text = "" {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(text)
        }
    }
    static let font = NSFont.systemFont(ofSize: 11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func fittingSize(width: CGFloat) -> NSSize {
        let words = (text as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: min(ceil(words.width) + 8 + 14 + 8, width), height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        StudioPageStyle.fieldFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        if let bulb = StudioPageStyle.symbol("lightbulb", size: 11, color: StudioPageStyle.quietInk) {
            bulb.draw(in: NSRect(x: 8, y: (bounds.height - bulb.size.height) / 2, width: bulb.size.width,
                                 height: bulb.size.height), from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let a = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: StudioPageStyle.quietInk,
                                                               .paragraphStyle: para])
        let h = ceil(a.size().height)
        a.draw(with: NSRect(x: 8 + 14, y: (bounds.height - h) / 2, width: bounds.width - 30, height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
