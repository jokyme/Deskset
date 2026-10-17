import AppKit
import DesksetCore

/// The capsule over the canvas of a Rainmeter skin: "Rainmeter skin · compatibility mode" — the Studio edits the skin's
/// own .ini files. Glass on screen (macOS 26; the popover material before), a stand-in off screen.
final class StudioCompatCapsule: NSView {
    let usesStandIn: Bool
    private var glass: NSView?
    let icon = NSImageView()
    let titleLabel = NSTextField(labelWithString: StudioText[.copyRainmeter])

    static let radius: CGFloat = 16

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
        for v in [icon, titleLabel] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(StudioText[.copyRainmeter])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var fittingSize2: NSSize {
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width) + 20
        return NSSize(width: titleWidth + 28, height: 36)
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
        icon.frame = NSRect(x: 14, y: (bounds.height - 18) / 2, width: 16, height: 18)
        titleLabel.frame = NSRect(x: 14 + 20, y: (bounds.height - 18) / 2, width: max(bounds.width - 48, 10), height: 18)
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
