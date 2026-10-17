import AppKit

extension NSToolbarItem.Identifier {
    static let studioTitle = Self("studio.title")
    static let studioDone = Self("studio.done")
}

/// What the toolbar shows, from the window (`StudioWindowController.toolbarState`).
struct StudioToolbarState: Equatable {
    var name = ""
    var sentence = ""
    var primary = StudioText[.done]
    var primaryEnabled = true

    static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        .studioTitle, .flexibleSpace, .studioDone,
    ]
}

/// The name of the widget and the sentence under it, which says which copy the Studio changes ("Built-in widget · on
/// your desktop"). A click opens the popover that says which file runs on the desktop.
final class StudioTitleView: NSView {
    let nameLabel = NSTextField(labelWithString: "")
    let sentenceLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        sentenceLabel.font = .systemFont(ofSize: 11)
        sentenceLabel.textColor = .secondaryLabelColor
        for label in [nameLabel, sentenceLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            sentenceLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
            sentenceLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            sentenceLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            sentenceLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = StudioText[.widgetNameTip]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(name: String, sentence: String) {
        nameLabel.stringValue = name
        sentenceLabel.stringValue = sentence
        setAccessibilityLabel("\(name), \(sentence)")
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

/// The Studio window's toolbar (`NSToolbar`): the widget's name and copy sentence, and Done.
final class StudioToolbar: NSObject, NSToolbarDelegate {
    let toolbar: NSToolbar
    let titleView = StudioTitleView()
    private(set) var state = StudioToolbarState()
    /// Where the actions go (the window controller).
    weak var target: AnyObject?

    init(target: AnyObject?) {
        self.target = target
        toolbar = NSToolbar(identifier: "DesksetStudio2-\(UUID().uuidString)")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        apply(state)
    }

    /// Shows `state`: the name and sentence, and what is enabled.
    func apply(_ state: StudioToolbarState) {
        self.state = state
        titleView.show(name: state.name, sentence: state.sentence)
        if let done = toolbar.items.first(where: { $0.itemIdentifier == .studioDone }) {
            done.label = state.primary
            done.title = state.primary
            done.isEnabled = state.primaryEnabled
            (done.view as? NSButton)?.title = state.primary
            (done.view as? NSButton)?.isEnabled = state.primaryEnabled
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        StudioToolbarState.itemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        StudioToolbarState.itemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .studioTitle:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = titleView
            item.label = StudioText[.widgetName]
            item.paletteLabel = StudioText[.widgetName]
            item.toolTip = StudioText[.widgetNameTip]
            return item
        case .studioDone:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = state.primary
            item.paletteLabel = StudioText[.done]
            item.toolTip = StudioText[.doneTip]
            if #available(macOS 26.0, *) {
                item.title = state.primary
                item.isBordered = true
                item.style = .prominent
                item.target = target
                item.action = #selector(StudioWindowController.doneAction(_:))
            } else {
                let b = NSButton(title: state.primary, target: target,
                                 action: #selector(StudioWindowController.doneAction(_:)))
                b.bezelStyle = .texturedRounded
                b.bezelColor = .controlAccentColor
                b.keyEquivalent = "\r"
                b.keyEquivalentModifierMask = .command
                item.view = b
            }
            return item
        default:
            return nil
        }
    }
}
