import AppKit

extension NSToolbarItem.Identifier {
    static let studioTitle = Self("studio.title")
    static let studioUndoRedo = Self("studio.undoRedo")
    static let studioUndo = Self("studio.undo")
    static let studioRedo = Self("studio.redo")
    static let studioAddCode = Self("studio.addCode")
    static let studioAdd = Self("studio.add")
    static let studioCode = Self("studio.code")
    static let studioShare = Self("studio.share")
    static let studioDone = Self("studio.done")
    /// The inspector button on macOS 13 (from 14 on the system's `toggleInspector` item).
    static let studioInspector = Self("studio.inspector")
}

/// How deep the Studio is: Customize (the sidebar closed: the widget page and the canvas) or Build (the sidebar open:
/// Add and Layers).
enum StudioDepth: Equatable {
    case customize
    case build
}

/// What the toolbar shows, from the window (`StudioWindowController.toolbarState`). The real items and the snapshot's
/// stand-ins are made from the same state, so they say the same.
struct StudioToolbarState: Equatable {
    var depth = StudioDepth.customize
    var name = ""
    var sentence = ""
    var canUndo = false
    var canRedo = false
    var undoName = ""
    var redoName = ""
    var addOn = false
    var codeOn = false
    var primary = StudioText[.done]
    var primaryEnabled = true

    /// The Undo button's words: "Undo", then "Undo Color" once there is a step to undo — while the Studio customizes
    /// (the sidebar closed; two mirrored arrows alone were hard to tell apart). nil: the icon alone (Build).
    var undoTitle: String? {
        guard depth == .customize else { return nil }
        guard canUndo, !undoName.isEmpty else { return StudioText[.undo] }
        return StudioText.format(.undoNamed, Self.shortName(undoName))
    }

    /// The Undo button's tooltip: the step it takes back.
    var undoTip: String { canUndo && !undoName.isEmpty ? StudioText.format(.undoNamed, undoName) : StudioText[.undo] }
    var redoTip: String { canRedo && !redoName.isEmpty ? StudioText.format(.redoNamed, redoName) : StudioText[.redo] }

    /// A step's name as the button says it: what it changed ("Change Bar Color" → "Bar Color").
    static func shortName(_ name: String) -> String {
        for verb in ["Change ", "Set "] where name.hasPrefix(verb) && name.count > verb.count {
            return String(name.dropFirst(verb.count))
        }
        return name
    }

    /// The items from the leading edge, as the toolbar holds them (from macOS 14 the inspector's tracking separator
    /// puts Share, Done and the inspector button over the inspector).
    static var itemIdentifiers: [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator, .studioTitle, .flexibleSpace,
                                               .studioUndoRedo, .studioAddCode, .flexibleSpace]
        if #available(macOS 14.0, *) {
            ids += [.inspectorTrackingSeparator, .flexibleSpace, .studioShare, .studioDone, .toggleInspector]
        } else {
            ids += [.studioShare, .studioDone, .studioInspector]
        }
        return ids
    }
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

/// The Studio window's toolbar (`NSToolbar`, merged with the canvas): the sidebar button, the widget's name and copy
/// sentence, Undo · Redo, Add · Code (with words: a `{ }` alone reads as a programmer's sign), Share, Done (the one
/// prominent button) and the inspector button. Undo carries words while the Studio customizes and is an icon while it
/// builds; in the Customize Toolbar palette the group is "Undo".
final class StudioToolbar: NSObject, NSToolbarDelegate {
    let toolbar: NSToolbar
    let titleView = StudioTitleView()
    let undoButton = StudioToolbar.button(symbol: "arrow.uturn.backward")
    let redoButton = StudioToolbar.button(symbol: "arrow.uturn.forward")
    let addButton = StudioToolbar.button(symbol: "plus")
    let codeButton = StudioToolbar.button(symbol: "chevron.left.forwardslash.chevron.right")
    private(set) var state = StudioToolbarState()
    /// Where the actions go (the window controller).
    weak var target: AnyObject?

    init(target: AnyObject?) {
        self.target = target
        // A unique identifier: two toolbars sharing one would share their items' configuration.
        toolbar = NSToolbar(identifier: "DesksetStudio2-\(UUID().uuidString)")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.studioUndoRedo, .studioAddCode]
        undoButton.action = #selector(StudioWindowController.undoAction(_:))
        redoButton.action = #selector(StudioWindowController.redoAction(_:))
        addButton.action = #selector(StudioWindowController.addAction(_:))
        codeButton.action = #selector(StudioWindowController.codeAction(_:))
        for b in [undoButton, redoButton, addButton, codeButton] { b.target = target }
        addButton.title = StudioText[.add]
        addButton.imagePosition = .imageLeading
        addButton.toolTip = StudioText[.addTip]
        codeButton.title = StudioText[.code]
        codeButton.imagePosition = .imageLeading
        codeButton.toolTip = StudioText[.codeTip]
        redoButton.setAccessibilityLabel(StudioText[.redo])
        apply(state)
    }

    static func button(symbol: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
        let b = NSButton(image: image, target: nil, action: nil)
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.setButtonType(.momentaryPushIn)
        return b
    }

    /// Shows `state`: the name and sentence, Undo's words and tooltips, what is on and what is enabled.
    func apply(_ state: StudioToolbarState) {
        self.state = state
        titleView.show(name: state.name, sentence: state.sentence)
        if let title = state.undoTitle {
            undoButton.title = title
            undoButton.imagePosition = .imageLeading
        } else {
            undoButton.title = ""
            undoButton.imagePosition = .imageOnly
        }
        undoButton.isEnabled = state.canUndo
        undoButton.toolTip = state.undoTip
        undoButton.setAccessibilityLabel(state.undoTip)
        redoButton.isEnabled = state.canRedo
        redoButton.toolTip = state.redoTip
        addButton.state = state.addOn ? .on : .off
        codeButton.state = state.codeOn ? .on : .off
        if let done = toolbar.items.first(where: { $0.itemIdentifier == .studioDone }) {
            done.label = state.primary
            done.title = state.primary
            done.isEnabled = state.primaryEnabled
            (done.view as? NSButton)?.title = state.primary
            (done.view as? NSButton)?.isEnabled = state.primaryEnabled
        }
        for b in [undoButton, redoButton, addButton, codeButton] { b.sizeToFit() }
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
        case .studioUndoRedo:
            let undo = NSToolbarItem(itemIdentifier: .studioUndo)
            undo.view = undoButton
            undo.label = StudioText[.undo]
            undo.paletteLabel = StudioText[.undo]
            let redo = NSToolbarItem(itemIdentifier: .studioRedo)
            redo.view = redoButton
            redo.label = StudioText[.redo]
            redo.paletteLabel = StudioText[.redo]
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [undo, redo]
            group.label = StudioText[.undoRedo]
            group.paletteLabel = StudioText[.undoRedo]
            return group
        case .studioAddCode:
            let add = NSToolbarItem(itemIdentifier: .studioAdd)
            add.view = addButton
            add.label = StudioText[.add]
            add.paletteLabel = StudioText[.add]
            let code = NSToolbarItem(itemIdentifier: .studioCode)
            code.view = codeButton
            code.label = StudioText[.code]
            code.paletteLabel = StudioText[.code]
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [add, code]
            group.label = StudioText[.addAndCode]
            group.paletteLabel = StudioText[.addAndCode]
            return group
        case .studioShare:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: StudioText[.share])
            item.label = StudioText[.share]
            item.paletteLabel = StudioText[.share]
            item.toolTip = StudioText[.shareLater]
            item.isBordered = true
            // Sharing comes later: the button is there, and off.
            item.autovalidates = false
            item.isEnabled = false
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
                let b = NSButton(title: state.primary, target: target, action: #selector(StudioWindowController.doneAction(_:)))
                b.bezelStyle = .texturedRounded
                b.bezelColor = .controlAccentColor
                b.keyEquivalent = "\r"
                b.keyEquivalentModifierMask = .command
                item.view = b
            }
            return item
        case .studioInspector:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: StudioText[.inspector])
            item.label = StudioText[.inspector]
            item.paletteLabel = StudioText[.inspector]
            item.isBordered = true
            item.target = target
            item.action = #selector(StudioWindowController.toggleInspectorPane(_:))
            return item
        default:
            return nil
        }
    }
}
