import AppKit
import DesksetCore

/// The Add page of the sidebar.
final class StudioAddView: NSView {
    let searchField = NSSearchField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = StudioText[.addSearch]
        searchField.controlSize = .large
        addSubview(searchField)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var snapshotViews: [NSView] { [searchField] }

    override func layout() {
        super.layout()
        searchField.frame = NSRect(x: 10, y: 0, width: max(bounds.width - 20, 40), height: 28)
    }
}
