import AppKit
import DesksetCore

/// The inspector: "What do you want to change?" on top, then the page of what is selected — the widget page while
/// nothing is — in a scroll view whose scrollers only show while it scrolls.
final class StudioInspectorViewController: NSViewController {
    let scrollView = OverlayScrollView()
    let pageView = StudioPageView()

    override func loadView() {
        let v = StudioInspectorContainer()
        v.setAccessibilityLabel(StudioText[.inspector])
        v.setAccessibilityElement(false)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        // The inspector's pane reaches under the toolbar too: its content starts below it.
        scrollView.contentInsets = NSEdgeInsets(top: StudioCanvasViewController.toolbarHeight, left: 0, bottom: 0, right: 0)
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = pageView
        scrollView.autoresizingMask = [.width, .height]
        v.addSubview(scrollView)
        v.onLayout = { [weak self] in self?.layoutPage() }
        view = v
    }

    /// Shows `page` (rows kept by id are updated in place).
    func show(_ page: StudioPage) {
        _ = view
        pageView.apply(page)
        layoutPage()
    }

    func layoutPage() {
        scrollView.frame = view.bounds
        let width = scrollView.contentSize.width
        let height = max(pageView.fittingHeight(width: width), scrollView.contentSize.height
                         - StudioCanvasViewController.toolbarHeight)
        if pageView.frame.size != NSSize(width: width, height: height) {
            pageView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        pageView.needsLayout = true
        pageView.layoutSubtreeIfNeeded()
    }
}

final class StudioInspectorContainer: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// A clip view with its origin at the top, so a short page sits at the top of the pane.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
