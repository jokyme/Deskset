import AppKit
import DesksetCore

/// The popover of the preview bar's first item, titled "Preview only": the Mac's look and the glass the canvas shows
/// (the language row comes with Desk widgets, which carry translations). Nothing in it is a setting of the widget —
/// the footer says so.
final class StudioPreviewPopoverController: NSViewController {
    let appearanceControl = NSSegmentedControl(labels: [StudioText[.followMac], StudioText[.appearanceLight],
                                                        StudioText[.appearanceDark]],
                                               trackingMode: .selectOne, target: nil, action: nil)
    let glassControl = NSSegmentedControl(labels: [StudioText[.glassDefault], StudioText[.glassClear],
                                                   StudioText[.glassTinted]],
                                          trackingMode: .selectOne, target: nil, action: nil)
    let titleLabel = NSTextField(labelWithString: StudioText[.previewOnly])
    let footerLabel = NSTextField(wrappingLabelWithString: StudioText[.previewFooter])
    /// Told of each change.
    var onChange: ((StudioPreviewState.Appearance, StudioPreviewState.Glass) -> Void)?
    private let initial: StudioPreviewState

    init(state: StudioPreviewState) {
        initial = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let width: CGFloat = 478

    override func loadView() {
        let eye = NSImageView()
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        eye.contentTintColor = .controlAccentColor
        titleLabel.font = StudioFonts.title(15)
        let title = NSStackView(views: [eye, titleLabel])
        title.spacing = 6
        for control in [appearanceControl, glassControl] {
            control.segmentStyle = .rounded
            control.font = .systemFont(ofSize: 11.5)
            control.selectedSegmentBezelColor = .controlAccentColor
            control.target = self
            control.action = #selector(changed)
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 340).isActive = true
            // Segments as wide as the row allows: each its label's width, the room left shared out equally (so
            // "Tinted (Mac setting)" is never cut).
            let font = control.font ?? .systemFont(ofSize: 11.5)
            let labels = (0..<control.segmentCount).map { ceil((control.label(forSegment: $0) ?? "")
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium)]).width) + 16 }
            let spare = max(0, 340 - 8 - labels.reduce(0, +)) / CGFloat(max(control.segmentCount, 1))
            for i in 0..<control.segmentCount { control.setWidth(labels[i] + spare, forSegment: i) }
        }
        appearanceControl.selectedSegment = initial.appearance.rawValue
        glassControl.selectedSegment = initial.glass.rawValue
        for control in [appearanceControl, glassControl] { StudioPageStyle.markChosenSegment(control) }
        appearanceControl.setAccessibilityLabel(StudioText[.macAppearance])
        glassControl.setAccessibilityLabel(StudioText[.glass])
        footerLabel.font = .systemFont(ofSize: 11.5)
        footerLabel.textColor = StudioInk.quiet
        let rows = [row(StudioText[.macAppearance], appearanceControl), row(StudioText[.glass], glassControl)]
        let stack = NSStackView(views: [title] + rows + [footerLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            v.widthAnchor.constraint(equalToConstant: Self.width),
            footerLabel.widthAnchor.constraint(equalToConstant: Self.width - 32),
        ])
        view = v
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 12)
        text.textColor = StudioInk.quiet
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let row = NSStackView(views: [text, control])
        row.spacing = 10
        return row
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        for control in [appearanceControl, glassControl] { StudioPageStyle.markChosenSegment(control) }
    }

    @objc func changed() {
        for control in [appearanceControl, glassControl] { StudioPageStyle.markChosenSegment(control) }
        let appearance = StudioPreviewState.Appearance(rawValue: appearanceControl.selectedSegment) ?? .followMac
        let glass = StudioPreviewState.Glass(rawValue: glassControl.selectedSegment) ?? .standard
        onChange?(appearance, glass)
    }
}

/// The Studio's fonts: New York for titles (the serif signature; Songti SC in Chinese), the system font elsewhere.
enum StudioFonts {
    static func title(_ size: CGFloat) -> NSFont { StudioPageStyle.titleFont(size) }
}

/// The menus of the preview bar: Backdrop ▾ and Data ▾. Their items call back with what was chosen.
final class StudioPreviewMenus: NSObject, NSMenuDelegate {
    var onBackdrop: ((StudioBackdropKind) -> Void)?
    var onNeighbours: ((Bool) -> Void)?
    var onData: ((MeasureValueOverride.Data) -> Void)?
    var onTime: ((StudioPreviewState.Time) -> Void)?
    var onPickTime: (() -> Void)?
    var onBackToLive: (() -> Void)?

    /// Backdrop ▾: Your Desktop (with how close it is), the samples, Workbench, Transparent, Solid (with Reduce
    /// Transparency); Show Other Widgets (while the widget is on the desktop).
    func backdropMenu(_ state: StudioPreviewState, fidelity: WallpaperFidelity, reduceTransparency: Bool,
                      canShowNeighbours: Bool, neighboursShown: Bool) -> NSMenu {
        let menu = NSMenu(title: StudioText[.backdrop])
        menu.autoenablesItems = false
        for kind in StudioBackdropKind.offered(reduceTransparency: reduceTransparency) {
            let item = NSMenuItem(title: kind.title, action: #selector(backdropChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = state.backdrop == kind ? .on : .off
            if kind == .desktop, let word = StudioPreviewBar.fidelityWord(fidelity) {
                if #available(macOS 14.4, *) { item.subtitle = word } else { item.title = "\(kind.title) (\(word))" }
                item.toolTip = StudioPreviewBar.fidelityTip(fidelity)
            }
            menu.addItem(item)
            if kind == .dark || kind == .desktop { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let neighbours = NSMenuItem(title: StudioText[.showOtherWidgets], action: #selector(neighboursToggled(_:)),
                                    keyEquivalent: "")
        neighbours.target = self
        neighbours.state = neighboursShown ? .on : .off
        neighbours.isEnabled = canShowNeighbours
        menu.addItem(neighbours)
        return menu
    }

    /// Data ▾: Live, Paused, 0 %, 50 %, 100 %, Long Text, No Data; the time: Live, Frozen at 10:09, Pick a Time…;
    /// Back to Live while anything is in use.
    func dataMenu(_ state: StudioPreviewState) -> NSMenu {
        let menu = NSMenu(title: StudioText[.dataHeader])
        menu.autoenablesItems = false
        menu.addItem(header(StudioText[.dataHeader]))
        let data: [(String, MeasureValueOverride.Data)] = [
            (StudioText[.live], .live), (StudioText[.dataPaused], .paused),
            (StudioPreviewState.percentText(0), .level(0)), (StudioPreviewState.percentText(0.5), .level(0.5)),
            (StudioPreviewState.percentText(1), .level(1)), (StudioText[.dataLongText], .longText),
            (StudioText[.dataNone], .noData),
        ]
        for (i, (title, value)) in data.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(dataChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = state.data == value ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(header(StudioText[.timeHeader]))
        let live = NSMenuItem(title: StudioText[.live], action: #selector(timeLive(_:)), keyEquivalent: "")
        live.target = self
        live.state = state.time == .live ? .on : .off
        menu.addItem(live)
        let ten = StudioPreviewState.tenPastTen()
        let frozen = NSMenuItem(title: StudioText.format(.timeFrozen, StudioPreviewState.timeText(ten)),
                                action: #selector(timeFrozen(_:)), keyEquivalent: "")
        frozen.target = self
        if case .frozen(let date) = state.time, StudioPreviewState.timeText(date) == StudioPreviewState.timeText(ten) {
            frozen.state = .on
        }
        menu.addItem(frozen)
        let pick = NSMenuItem(title: StudioText[.timePick], action: #selector(pickTime(_:)), keyEquivalent: "")
        pick.target = self
        if case .frozen(let date) = state.time, frozen.state != .on {
            pick.state = .on
            pick.title = StudioText.format(.timeFrozen, StudioPreviewState.timeText(date)) + " · " + StudioText[.timePick]
        }
        menu.addItem(pick)
        if state.hasPreset {
            menu.addItem(.separator())
            let back = NSMenuItem(title: StudioText[.backToLive], action: #selector(backToLive(_:)), keyEquivalent: "")
            back.target = self
            menu.addItem(back)
        }
        return menu
    }

    static let dataValues: [MeasureValueOverride.Data] = [.live, .paused, .level(0), .level(0.5), .level(1), .longText,
                                                          .noData]

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func backdropChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = StudioBackdropKind(rawValue: raw) else { return }
        onBackdrop?(kind)
    }

    @objc func neighboursToggled(_ sender: NSMenuItem) { onNeighbours?(sender.state != .on) }

    @objc func dataChosen(_ sender: NSMenuItem) {
        guard Self.dataValues.indices.contains(sender.tag) else { return }
        onData?(Self.dataValues[sender.tag])
    }

    @objc func timeLive(_ sender: NSMenuItem) { onTime?(.live) }
    @objc func timeFrozen(_ sender: NSMenuItem) { onTime?(.frozen(StudioPreviewState.tenPastTen())) }
    @objc func pickTime(_ sender: NSMenuItem) { onPickTime?() }
    @objc func backToLive(_ sender: NSMenuItem) { onBackToLive?() }
}

/// Pick a Time…: a date and time the widget's clocks show (in this window only).
final class StudioTimePickerController: NSViewController {
    let picker = NSDatePicker()
    var onPick: ((Date) -> Void)?
    private let initial: Date

    init(date: Date) {
        initial = date
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: StudioText[.timePickTitle])
        title.font = StudioFonts.title(15)
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = initial
        let use = NSButton(title: StudioText[.timePickUse], target: self, action: #selector(use(_:)))
        use.keyEquivalent = "\r"
        let stack = NSStackView(views: [title, picker, use])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view = stack
    }

    @objc func use(_ sender: Any?) {
        onPick?(picker.dateValue)
        view.window?.performClose(nil)
        presentingViewController?.dismiss(self)
    }
}
