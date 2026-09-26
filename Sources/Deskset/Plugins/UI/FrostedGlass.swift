import AppKit
import DesksetCore

// FrostedGlass (third-party plugin; usage documentation of v1.2.0 on the Rainmeter forums, "[v1.2.0] FrostedGlass -
// Now more customizable", and the project README): blur / acrylic / mica behind the whole skin window, optional
// rounded corners and borders.
//
// On the Mac the effect is an NSVisualEffectView in a borderless child window placed exactly behind the skin window
// (same frame, same level, ordered just below it, ignoring the mouse). A child window moves with its parent; its
// size, level, visibility and alpha are synced on every update of the measure and whenever the skin window moves,
// resizes, is ordered in or closes. Rounded corners also clip the skin's own content (Windows 11 rounds the whole
// window), through the skin view's layer.

/// The plugin's options, parsed (pure, tested).
struct FrostedGlassStyle: Equatable {
    enum Kind: Equatable {
        case none, backdrop, translucentBackdrop, blur, acrylic, mica, micaAcrylic, micaAlt
    }

    struct Sides: OptionSet, Equatable {
        let rawValue: Int
        static let top = Sides(rawValue: 1)
        static let left = Sides(rawValue: 2)
        static let right = Sides(rawValue: 4)
        static let bottom = Sides(rawValue: 8)
        static let all: Sides = [.top, .left, .right, .bottom]
    }

    var kind = Kind.blur
    var borders: Sides = []
    /// Corner radius in points (Round/RoundWs 8, RoundSmall 4, None 0).
    var cornerRadius: CGFloat = 0
    var borderVisible = true
    /// nil = the default subtle border.
    var borderColor: RGBA?
    /// `Backdrop` color (alpha defaults to 0).
    var backdrop = RGBA(r: 0, g: 0, b: 0, a: 0)
    var darkMode = false
    var micaOnFocus = false
    /// `Disabled=1` / `BlurEnabled=0` / `!CommandMeasure … DisableBlur`.
    var enabled = true
    var cornersEnabled = true
    var bordersEnabled = true

    /// Reads the options through `lookup` (resolved option text, nil when missing).
    static func read(_ lookup: (String) -> String?) -> FrostedGlassStyle {
        var s = FrostedGlassStyle()
        func value(_ key: String) -> String? {
            guard let v = lookup(key)?.muiTrimmed, !v.isEmpty else { return nil }
            return v
        }
        switch value("Type")?.lowercased() {
        case "none": s.kind = .none
        case "backdrop": s.kind = .backdrop
        case "traslucentbackdrop", "translucentbackdrop": s.kind = .translucentBackdrop
        case "acrylic": s.kind = .acrylic
        case "mica": s.kind = .mica
        case "micaacrylic": s.kind = .micaAcrylic
        case "micaalt": s.kind = .micaAlt
        default: s.kind = .blur
        }
        s.borders = sides(value("Border") ?? "None")
        switch value("Corner")?.lowercased() {
        case "round", "roundws": s.cornerRadius = 8
        case "roundsmall": s.cornerRadius = 4
        default: s.cornerRadius = 0
        }
        s.borderVisible = value("BorderVisible").flatMap(OptionValue.bool) ?? true
        if let border = value("BorderColor") {
            if border.lowercased() == "backdrop" {
                s.borderColor = color(value("Backdrop"), defaultAlpha: 255).map { var c = $0; c.a = 255; return c }
            } else {
                s.borderColor = color(border, defaultAlpha: 255).map { var c = $0; c.a = 255; return c }
            }
        }
        s.backdrop = color(value("Backdrop"), defaultAlpha: 0) ?? RGBA(r: 0, g: 0, b: 0, a: 0)
        s.darkMode = value("DarkMode").flatMap(OptionValue.bool) ?? false
        s.micaOnFocus = value("MicaOnFocus").flatMap(OptionValue.bool) ?? false
        if value("BlurEnabled").flatMap(OptionValue.bool) == false { s.enabled = false }
        return s
    }

    /// `Top | Left`, `All`, `None` (case-insensitive).
    static func sides(_ text: String) -> Sides {
        var result: Sides = []
        for part in text.split(separator: "|") {
            switch part.muiTrimmed.lowercased() {
            case "all": result.formUnion(.all)
            case "top": result.insert(.top)
            case "left": result.insert(.left)
            case "right": result.insert(.right)
            case "bottom": result.insert(.bottom)
            default: break
            }
        }
        return result
    }

    /// `R,G,B[,A]` or hex `RRGGBB[AA]` (a leading `#` is ignored). When the alpha is not given it is `defaultAlpha`
    /// ("The default value for the alpha value is 0"). The deprecated named backdrops (Dark, Light1…) map to greys.
    static func color(_ text: String?, defaultAlpha: Double) -> RGBA? {
        guard var t = text?.muiTrimmed, !t.isEmpty else { return nil }
        if t.hasPrefix("#") { t.removeFirst() }
        var lower = t.lowercased().replacingOccurrences(of: "[bwc]", with: "")
        if lower.hasPrefix("bwc") { lower.removeFirst(3) }
        if lower.hasPrefix("dark") || lower.hasPrefix("light") {
            let dark = lower.hasPrefix("dark")
            let level = Double(lower.last?.wholeNumberValue ?? 0)
            let grey = dark ? 32 + level * 8 : 243 - level * 8
            return RGBA(r: grey, g: grey, b: grey, a: 128)
        }
        let commaCount = t.filter { $0 == "," }.count
        let hasAlpha = commaCount >= 3 || (commaCount == 0 && t.count == 8)
        guard var c = OptionValue.color(t) else { return nil }
        if !hasAlpha { c.a = defaultAlpha }
        return c
    }

    /// Whether any blur / color is drawn behind the skin.
    var drawsBackground: Bool { enabled && kind != .none }
    var effectiveRadius: CGFloat { enabled && cornersEnabled ? cornerRadius : 0 }

    /// The macOS material standing in for each Windows effect (Judgment; see docs/compat/media-ui.md).
    var material: NSVisualEffectView.Material? {
        switch kind {
        case .none, .backdrop, .translucentBackdrop: return nil
        case .blur: return .hudWindow
        case .acrylic: return .popover
        case .mica: return .underWindowBackground
        case .micaAcrylic: return .sidebar
        case .micaAlt: return .windowBackground
        }
    }

    /// Color drawn over the blur (Acrylic's tint) or instead of it (Backdrop types); nil for none.
    var tint: RGBA? {
        switch kind {
        case .backdrop:
            var c = backdrop
            c.a = 255
            return c
        case .translucentBackdrop, .acrylic, .micaAcrylic:
            return backdrop.a > 0 ? backdrop : nil
        default:
            return nil
        }
    }
}

/// `Plugin=FrostedGlass`.
final class FrostedGlassMeasure: MediaUIMeasure {
    private(set) var style = FrostedGlassStyle()
    /// Command state (survives option re-reads): nil = as the options say.
    private var commandEnabled: Bool?
    private var commandCorners: Bool?
    private var commandBorders: Bool?
    private var commandFocus: Bool?
    private var commandDark: Bool?
    private weak var backdrop: FrostedGlassBackdrop?

    deinit {
        // The skin is being refreshed or unloaded: the next skin's measure (if any) attaches again on its first
        // update; the backdrop removes itself unless it is claimed before the next run-loop turn.
        backdrop?.release(after: 0)
    }

    override func readMeasureOptions() {
        var s = FrostedGlassStyle.read { option($0) }
        if let e = commandEnabled { s.enabled = e }
        if let c = commandCorners { s.cornersEnabled = c }
        if let b = commandBorders { s.bordersEnabled = b }
        if let f = commandFocus { s.micaOnFocus = f }
        if let d = commandDark { s.darkMode = d }
        style = s
    }

    override func computeValue() -> Double {
        apply()
        return style.drawsBackground ? 1 : 0
    }

    private func apply() {
        guard let controller, !controller.isStopped else { return }
        let b = FrostedGlassBackdrop.attach(to: controller)
        backdrop = b
        b.update(style)
    }

    override func execute(command: String) {
        switch command.muiTrimmed.lowercased() {
        case "toggleblur": commandEnabled = !style.enabled
        case "enableblur": commandEnabled = true
        case "disableblur": commandEnabled = false
        case "togglecorner": commandCorners = !style.cornersEnabled
        case "enablecorner": commandCorners = true
        case "disablecorner": commandCorners = false
        case "toggleborders": commandBorders = !style.bordersEnabled
        case "enableborders": commandBorders = true
        case "disableborders": commandBorders = false
        case "togglefocus": commandFocus = !style.micaOnFocus
        case "enablefocus": commandFocus = true
        case "disablefocus": commandFocus = false
        case "togglemode": commandDark = !style.darkMode
        case "lightmode": commandDark = false
        case "darkmode": commandDark = true
        default:
            skin.log("FrostedGlass [\(name)]: unknown command \"\(command)\"", level: .warning)
            return
        }
        readMeasureOptions()
        apply()
    }
}

/// The effect window behind one skin window.
final class FrostedGlassBackdrop: NSObject {
    private static var byController: [ObjectIdentifier: FrostedGlassBackdrop] = [:]

    private weak var controller: SkinController?
    private weak var parent: NSWindow?
    private let window: NSPanel
    private let effect = NSVisualEffectView()
    private let tintView = NSView()
    private let borderView = FrostedGlassBorderView()
    private var style = FrostedGlassStyle()
    private var observers: [NSObjectProtocol] = []
    private var releaseGeneration = 0
    private var roundedView: NSView?

    /// The window and the skin window it follows (for tests).
    var effectWindow: NSWindow { window }
    var followedWindow: NSWindow? { parent }
    var effectView: NSVisualEffectView { effect }

    private init(controller: SkinController) {
        self.controller = controller
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.canHide = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        for v in [effect, tintView, borderView] as [NSView] {
            v.frame = content.bounds
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
        }
        effect.blendingMode = .behindWindow
        effect.state = .active
        tintView.wantsLayer = true
        window.contentView = content
    }

    /// The backdrop of a skin controller (created on first use).
    static func attach(to controller: SkinController) -> FrostedGlassBackdrop {
        let key = ObjectIdentifier(controller)
        if let existing = byController[key] {
            if existing.controller === controller {
                existing.releaseGeneration += 1   // claimed again: cancel a pending release
                return existing
            }
            existing.remove()   // a stale entry whose controller is gone (its address was reused)
        }
        let b = FrostedGlassBackdrop(controller: controller)
        byController[key] = b
        return b
    }

    /// Removes the backdrop unless `attach` claims it again first.
    func release(after delay: TimeInterval) {
        releaseGeneration += 1
        let generation = releaseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.releaseGeneration == generation else { return }
            self.remove()
        }
    }

    /// Called on every update of the measure: the views are only touched when the style changed (a skin with
    /// `Update=16` would otherwise redraw a window-sized border 60 times a second).
    func update(_ style: FrostedGlassStyle) {
        if !styleApplied || style != self.style {
            styleApplied = true
            self.style = style
            effect.material = style.material ?? .hudWindow
            effect.isHidden = style.material == nil || !style.enabled
            effect.appearance = style.darkMode ? NSAppearance(named: .darkAqua) : nil
            if let tint = style.tint, style.enabled {
                tintView.isHidden = false
                tintView.layer?.backgroundColor = tint.cgColor
            } else {
                tintView.isHidden = true
            }
            borderView.style = style
            borderView.needsDisplay = true
        }
        sync()
    }

    private var styleApplied = false

    /// Frame, level, order, alpha and corner radius follow the skin window.
    func sync() {
        guard let controller, !controller.isStopped else {
            remove()
            return
        }
        let parent = controller.window
        if self.parent !== parent {
            detachFromParent()
            self.parent = parent
            observe(parent)
        }
        let radius = style.effectiveRadius
        if let layer = window.contentView?.layer, layer.cornerRadius != radius { layer.cornerRadius = radius }
        roundSkinView(controller.view, radius: radius)
        let visible = parent.isVisible && controller.app.presentsWindows
        let wanted = visible && (style.drawsBackground || (style.borderVisible && radius > 0)
                                 || (style.bordersEnabled && !style.borders.isEmpty))
        guard wanted else {
            if window.parent != nil { parent.removeChildWindow(window) }
            window.orderOut(nil)
            return
        }
        if window.frame != parent.frame { window.setFrame(parent.frame, display: true) }
        if window.level != parent.level { window.level = parent.level }
        if window.collectionBehavior != parent.collectionBehavior { window.collectionBehavior = parent.collectionBehavior }
        if window.alphaValue != parent.alphaValue { window.alphaValue = parent.alphaValue }
        let state: NSVisualEffectView.State = style.micaOnFocus && !parent.isKeyWindow ? .inactive : .active
        if effect.state != state { effect.state = state }
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .below)
        }
        if !window.isVisible { window.order(.below, relativeTo: parent.windowNumber) }
    }

    /// Rounds (and clips) the skin's own drawing like Windows 11 rounds the whole window.
    private func roundSkinView(_ view: NSView, radius: CGFloat) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        if layer.cornerRadius != radius { layer.cornerRadius = radius }
        let clip = radius > 0
        if layer.masksToBounds != clip { layer.masksToBounds = clip }
        roundedView = view
    }

    private func observe(_ parent: NSWindow) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                          NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                self?.sync()
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) {
            [weak self] _ in
            // The skin window is replaced (click-through change: the controller already holds the new panel) or the
            // skin stops: detach, then re-attach to the controller's current window on the next turn of the run
            // loop (a stopped skin removes the backdrop instead). Measures with UpdateDivider=-1 never update again,
            // so this cannot wait for the measure.
            self?.detachFromParent()
            self?.window.orderOut(nil)
            DispatchQueue.main.async { self?.sync() }
        })
    }

    private func detachFromParent() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if let parent, window.parent === parent { parent.removeChildWindow(window) }
        parent = nil
    }

    private func remove() {
        detachFromParent()
        window.orderOut(nil)
        window.close()
        if let view = roundedView {
            view.layer?.cornerRadius = 0
            view.layer?.masksToBounds = false
        }
        roundedView = nil
        if let controller {
            FrostedGlassBackdrop.byController[ObjectIdentifier(controller)] = nil
        } else {
            FrostedGlassBackdrop.byController = FrostedGlassBackdrop.byController.filter { $0.value !== self }
        }
    }

    /// Backdrops currently alive (tests).
    static var count: Int { byController.count }
    static func backdrop(for controller: SkinController) -> FrostedGlassBackdrop? {
        byController[ObjectIdentifier(controller)]
    }
}

/// Square borders (`Border=`) or the rounded border (`Corner` + `BorderVisible` / `BorderColor`).
final class FrostedGlassBorderView: NSView {
    var style = FrostedGlassStyle()

    override var isFlipped: Bool { true }

    /// The default border color follows light / dark mode.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard style.enabled, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = style.darkMode || effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fallback = dark ? RGBA(r: 255, g: 255, b: 255, a: 40) : RGBA(r: 0, g: 0, b: 0, a: 40)
        let color = (style.borderColor ?? fallback).cgColor
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        let radius = style.effectiveRadius
        if radius > 0 {
            guard style.borderVisible else { return }
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
            return
        }
        // "Border option is used only for squared borders which is incompatible while using any corner."
        guard style.bordersEnabled, !style.borders.isEmpty else { return }
        let b = bounds
        func line(_ a: CGPoint, _ c: CGPoint) {
            ctx.move(to: a)
            ctx.addLine(to: c)
        }
        if style.borders.contains(.top) { line(CGPoint(x: b.minX, y: b.minY + 0.5), CGPoint(x: b.maxX, y: b.minY + 0.5)) }
        if style.borders.contains(.bottom) { line(CGPoint(x: b.minX, y: b.maxY - 0.5), CGPoint(x: b.maxX, y: b.maxY - 0.5)) }
        if style.borders.contains(.left) { line(CGPoint(x: b.minX + 0.5, y: b.minY), CGPoint(x: b.minX + 0.5, y: b.maxY)) }
        if style.borders.contains(.right) { line(CGPoint(x: b.maxX - 0.5, y: b.minY), CGPoint(x: b.maxX - 0.5, y: b.maxY)) }
        ctx.strokePath()
    }
}
