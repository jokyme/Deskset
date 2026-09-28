import AppKit
import DesksetCore

/// The capsule over the canvas of a Rainmeter skin: "Rainmeter skin · compatibility mode" — the Studio edits the skin's
/// own .ini files — and, until the first change, the offer worded as a choice: "Also available as a Deskset widget:
/// more Mac features, but you’d edit Desk instead of INI · Switch · Stay with INI". Switch is drawn but does nothing
/// yet (the converter comes later: its tooltip says so); Stay with INI puts the offer away for this skin, remembered.
/// Glass on screen (macOS 26; the popover material before), a stand-in off screen.
final class StudioCompatCapsule: NSView {
    let usesStandIn: Bool
    private var glass: NSView?
    let icon = NSImageView()
    let titleLabel = NSTextField(labelWithString: StudioText[.copyRainmeter])
    let offerLabel = NSTextField(wrappingLabelWithString: StudioText[.compatOffer])
    let switchButton = NSButton(title: StudioText[.compatSwitch], target: nil, action: nil)
    let stayButton = NSButton(title: StudioText[.compatStay], target: nil, action: nil)
    /// The offer shows (before the first change, until Stay with INI).
    var showsOffer = true {
        didSet {
            offerLabel.isHidden = !showsOffer
            switchButton.isHidden = !showsOffer
            stayButton.isHidden = !showsOffer
            needsLayout = true
        }
    }
    var onStay: (() -> Void)?

    static let radius: CGFloat = 16
    static let offerWidth: CGFloat = 360

    init(standIn: Bool) {
        usesStandIn = standIn
        super.init(frame: .zero)
        wantsLayer = true
        if !standIn {
            if #available(macOS 26.0, *), SkinGlassViews.usesSystemGlass {
                glass = NSGlassEffectView()
            } else {
                let effect = NSVisualEffectView()
                effect.material = .popover
                effect.blendingMode = .withinWindow
                effect.state = .active
                glass = effect
            }
            if let glass { addSubview(glass) }
        }
        icon.image = StudioPageStyle.symbol("doc.plaintext", size: 12.5, color: StudioPageStyle.quietInk)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        offerLabel.font = .systemFont(ofSize: 12)
        offerLabel.textColor = StudioPageStyle.quietInk
        offerLabel.isSelectable = false
        for b in [switchButton, stayButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 12)
            b.target = self
        }
        switchButton.action = #selector(switchClicked)
        switchButton.toolTip = StudioText[.compatSwitchLater]
        stayButton.action = #selector(stayClicked)
        for v in [icon, titleLabel, offerLabel, switchButton, stayButton] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StudioText[.copyRainmeter])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Switching to a Deskset widget comes with the converter: until then the button only says so.
    @objc func switchClicked() {
        NSSound.beep()
    }

    @objc func stayClicked() {
        onStay?()
    }

    var fittingSize2: NSSize {
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width) + 20
        guard showsOffer else { return NSSize(width: titleWidth + 28, height: 36) }
        let offerHeight = StudioPageStyle.height(of: offerLabel.stringValue, font: offerLabel.font!,
                                                 width: Self.offerWidth)
        let buttons = ceil(switchButton.intrinsicContentSize.width) + ceil(stayButton.intrinsicContentSize.width) + 8
        let width = max(titleWidth, Self.offerWidth + 10 + buttons) + 28
        return NSSize(width: width, height: 10 + 18 + 5 + max(offerHeight, 22) + 10)
    }

    override func layout() {
        super.layout()
        if let glass {
            glass.frame = bounds
            if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
                g.cornerRadius = Self.radius
            } else if let effect = glass as? NSVisualEffectView {
                effect.maskImage = SkinGlassViews.roundedMask(Self.radius)
            }
        }
        icon.frame = NSRect(x: 14, y: 10, width: 16, height: 18)
        titleLabel.frame = NSRect(x: 14 + 20, y: 10, width: max(bounds.width - 48, 10), height: 18)
        guard showsOffer else {
            icon.frame.origin.y = (bounds.height - 18) / 2
            titleLabel.frame.origin.y = (bounds.height - 18) / 2
            return
        }
        let offerHeight = StudioPageStyle.height(of: offerLabel.stringValue, font: offerLabel.font!,
                                                 width: Self.offerWidth)
        let rowTop: CGFloat = 10 + 18 + 5
        let rowHeight = max(offerHeight, 22)
        offerLabel.frame = NSRect(x: 14, y: rowTop + (rowHeight - offerHeight) / 2, width: Self.offerWidth,
                                  height: offerHeight)
        var x = 14 + Self.offerWidth + 10
        for b in [switchButton, stayButton] {
            let w = ceil(b.intrinsicContentSize.width)
            b.frame = NSRect(x: x, y: rowTop + (rowHeight - 22) / 2, width: w, height: 22)
            x += w + 8
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard usesStandIn else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.35 : 0.10)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        (dark ? NSColor(white: 0.24, alpha: 0.92) : NSColor(white: 1, alpha: 0.78)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.07)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// Which Rainmeter skins keep the offer away ("Stay with INI"), by config, in the Studio's settings.
enum StudioCompatChoice {
    static func tip(_ config: String) -> String { "studio2.stayWithINI:" + config.lowercased() }
}
