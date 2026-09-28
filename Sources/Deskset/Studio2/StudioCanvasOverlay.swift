import AppKit
import DesksetCore

/// The plane over the canvas that says what things reach, without ever looking like part of the widget:
/// - "what it draws": while the pointer is on a swatch, a color row or a data item, a dashed frame 4 pt outside each
///   part it paints or feeds, and a name tag ("Memory ring", "Rain · 2 parts") — in the accent color, or graphite (near
///   white in dark mode) with an inverted halo when the widget has a color close to the accent (ΔE₀₀ < 20); it fades
///   out when the pointer leaves, and goes at once when a popover opens;
/// - the reach of a wider scope, while the pointer is on the scope sentence's link: the other parts it would change,
///   dashed in the accent color, and one sentence under the widget ("4 numbers share one style");
/// - with ⌥ held, the distances from the selected part to its neighbours and to the card's edges, in the accent color.
///
/// It takes no clicks: the canvas under it does.
final class StudioCanvasOverlay: NSView {
    weak var canvas: SkinCanvasView?
    var skinProvider: () -> Skin? = { nil }

    struct Frames: Equatable {
        var names: [String]
        var tag: String
        var ink: StudioOutlineInk
    }

    /// What the pointed-at thing draws (nil: nothing pointed at).
    private(set) var frames: Frames?
    /// Frames fading out.
    private var fading: Frames?
    private var fade: CGFloat = 1
    private var fadeTimer: Timer?
    /// The parts a wider scope would reach, and the sentence under the widget.
    private(set) var reach: (names: [String], sentence: String)?
    /// ⌥ is held: the selected part's distances.
    private(set) var showsDistances = false
    /// Fades animate (a window on screen); off screen they end at once.
    var animates = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: What it draws

    func showFrames(_ f: Frames?) {
        guard f != frames else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        if f == nil, let old = frames, animates, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fading = old
            fade = 1
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                self.fade -= 1.0 / 9
                if self.fade <= 0 {
                    t.invalidate()
                    self.fading = nil
                    self.fadeTimer = nil
                }
                self.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            fadeTimer = timer
        } else {
            fading = nil
        }
        frames = f
        needsDisplay = true
    }

    /// A popover opened: what it draws goes at once, without fading.
    func clearFramesNow() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fading = nil
        frames = nil
        needsDisplay = true
    }

    func showReach(_ names: [String], sentence: String) {
        reach = names.isEmpty ? nil : (names, sentence)
        needsDisplay = true
    }

    func clearReach() {
        guard reach != nil else { return }
        reach = nil
        needsDisplay = true
    }

    func setShowsDistances(_ on: Bool) {
        guard on != showsDistances else { return }
        showsDistances = on
        needsDisplay = true
    }

    /// The ink for a widget: the accent, or graphite when a color of the widget is close to it.
    static func ink(for skin: Skin, accent: NSColor = .controlAccentColor) -> StudioOutlineInk {
        let a = accent.usingColorSpace(.sRGB) ?? .systemBlue
        let rgba = RGBA(r: Double(a.redComponent * 255), g: Double(a.greenComponent * 255),
                        b: Double(a.blueComponent * 255))
        return StudioOutlineInk.choose(accent: rgba, colors: colors(of: skin))
    }

    /// The colors a widget shows: its parts' fills, strokes, texts, tints and backgrounds.
    static func colors(of skin: Skin) -> [RGBA] {
        var result: [RGBA] = []
        for m in skin.meters where !m.hidden {
            if m.solidColor.a > 0 { result.append(m.solidColor) }
            switch m {
            case let s as StringMeter: result.append(s.style.color)
            case let i as ImageMeter: if let t = i.imageTint { result.append(t) }
            case let shape as ShapeMeter:
                for item in shape.shapes {
                    if case .color(let c) = item.fill { result.append(c) }
                    if case .color(let c) = item.stroke, item.strokeStyle.width > 0 { result.append(c) }
                }
            default:
                for key in ["BarColor", "LineColor", "LineColor2", "PrimaryColor", "SecondaryColor"] {
                    if let c = m.option(key).flatMap({ OptionValue.color($0) }) {
                        result.append(c)
                    }
                }
            }
        }
        return result
    }

    // MARK: Geometry

    func rect(of name: String) -> CGRect? {
        guard let canvas, let m = skinProvider()?.meter(named: name), !m.hidden,
              m.frame.width > 0 || m.frame.height > 0 else { return nil }
        return canvas.convert(canvas.viewRect(m.frame), to: self)
    }

    var cardRect: CGRect {
        guard let canvas, skinProvider() != nil else { return .zero }
        return canvas.convert(canvas.skinRect, to: self)
    }

    /// The distances from the selected part to its nearest neighbour on each side (or the card's edge), in skin
    /// points: (edge, from, to) in this view's coordinates, and the number.
    func distances() -> [(from: CGPoint, to: CGPoint, value: Double)] {
        guard let canvas, let skin = skinProvider(), canvas.selectedNames.count == 1,
              let m = skin.meter(named: canvas.selectedNames[0]) else { return [] }
        let f = m.frame
        let others = skin.meters.filter { o in
            o !== m && !o.hidden && o.frame.width > 0 && o.frame.height > 0
                // A part the selection lies inside (a card, a background) is the edge, not a neighbour.
                && !(o.frame.x <= f.x && o.frame.y <= f.y && o.frame.x + o.frame.width >= f.x + f.width
                     && o.frame.y + o.frame.height >= f.y + f.height)
        }
        let width = skin.width, height = skin.height
        func overlapsY(_ o: Meter) -> Bool { o.frame.y < f.y + f.height && o.frame.y + o.frame.height > f.y }
        func overlapsX(_ o: Meter) -> Bool { o.frame.x < f.x + f.width && o.frame.x + o.frame.width > f.x }
        let left = others.filter { overlapsY($0) && $0.frame.x + $0.frame.width <= f.x }
            .map { $0.frame.x + $0.frame.width }.max() ?? 0
        let right = others.filter { overlapsY($0) && $0.frame.x >= f.x + f.width }.map(\.frame.x).min() ?? width
        let top = others.filter { overlapsX($0) && $0.frame.y + $0.frame.height <= f.y }
            .map { $0.frame.y + $0.frame.height }.max() ?? 0
        let bottom = others.filter { overlapsX($0) && $0.frame.y >= f.y + f.height }.map(\.frame.y).min() ?? height
        let midX = f.x + f.width / 2, midY = f.y + f.height / 2
        func point(_ x: Double, _ y: Double) -> CGPoint {
            canvas.convert(CGPoint(x: canvas.origin.x + x, y: canvas.origin.y + y), to: self)
        }
        var result: [(CGPoint, CGPoint, Double)] = []
        if f.x - left > 0.5 { result.append((point(left, midY), point(f.x, midY), f.x - left)) }
        if right - (f.x + f.width) > 0.5 { result.append((point(f.x + f.width, midY), point(right, midY), right - f.x - f.width)) }
        if f.y - top > 0.5 { result.append((point(midX, top), point(midX, f.y), f.y - top)) }
        if bottom - (f.y + f.height) > 0.5 {
            result.append((point(midX, f.y + f.height), point(midX, bottom), bottom - f.y - f.height))
        }
        return result.map { (from: $0.0, to: $0.1, value: $0.2) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = StudioPageStyle.isDark(effectiveAppearance)
        if let reach { drawReach(reach, dark: dark) }
        if let frames { drawFrames(frames, alpha: 1, dark: dark) } else if let fading {
            drawFrames(fading, alpha: max(fade, 0), dark: dark)
        }
        if showsDistances { drawDistances(dark: dark) }
    }

    private func ink(_ i: StudioOutlineInk, dark: Bool) -> (stroke: NSColor, halo: NSColor, tagText: NSColor) {
        switch i {
        case .accent:
            return (.controlAccentColor, NSColor(white: dark ? 0 : 1, alpha: 0.55), .white)
        case .graphite:
            return dark ? (NSColor(white: 0.93, alpha: 1), NSColor(white: 0, alpha: 0.7), .black)
                : (NSColor(white: 0.20, alpha: 1), NSColor(white: 1, alpha: 0.85), .white)
        }
    }

    private func drawFrames(_ f: Frames, alpha: CGFloat, dark: Bool) {
        let colors = ink(f.ink, dark: dark)
        var first: CGRect?
        for name in f.names {
            guard let r = rect(of: name) else { continue }
            let box = r.insetBy(dx: -4, dy: -4)
            if first == nil { first = box }
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            // The halo, then the dashes: seen on any color.
            path.lineWidth = 3.5
            colors.halo.withAlphaComponent(colors.halo.alphaComponent * alpha).setStroke()
            path.stroke()
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            colors.stroke.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        if let first, !f.tag.isEmpty {
            drawTag(f.tag, above: first, fill: colors.stroke.withAlphaComponent(alpha),
                    text: colors.tagText.withAlphaComponent(alpha))
        }
    }

    private func drawReach(_ reach: (names: [String], sentence: String), dark: Bool) {
        var union = CGRect.null
        for name in reach.names {
            guard let r = rect(of: name) else { continue }
            let box = r.insetBy(dx: -3, dy: -3)
            union = union.union(box)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        let card = cardRect
        guard !reach.sentence.isEmpty, !card.isEmpty else { return }
        drawQuietTag(reach.sentence, symbol: "paintbrush", centredAt: CGPoint(x: card.midX, y: card.maxY + 26), dark: dark)
    }

    private func drawDistances(dark: Bool) {
        let accent = NSColor.controlAccentColor
        for d in distances() {
            let path = NSBezierPath()
            path.move(to: d.from)
            path.line(to: d.to)
            path.lineWidth = 1.2
            accent.setStroke()
            path.stroke()
            let horizontal = abs(d.to.x - d.from.x) > abs(d.to.y - d.from.y)
            let mid = CGPoint(x: (d.from.x + d.to.x) / 2, y: (d.from.y + d.to.y) / 2)
            let centre = horizontal ? CGPoint(x: mid.x, y: mid.y - 11) : CGPoint(x: mid.x + 16, y: mid.y)
            drawBadge(SkinCanvasView.format(d.value.rounded()), centredAt: centre)
        }
        let card = cardRect
        if !card.isEmpty {
            drawQuietTag(StudioText[.optionDistances], symbol: nil, centredAt: CGPoint(x: card.midX, y: card.maxY + 30),
                         dark: dark)
        }
    }

    private func drawBadge(_ text: String, centredAt c: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                         .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attributes)
        let size = s.size()
        let r = CGRect(x: c.x - size.width / 2 - 6, y: c.y - 8.5, width: size.width + 12, height: 17)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 8.5, yRadius: 8.5).fill()
        s.draw(at: NSPoint(x: r.minX + 6, y: r.midY - size.height / 2))
    }

    /// A name tag above a frame's top-left corner (below it when there is no room).
    private func drawTag(_ text: String, above r: CGRect, fill: NSColor, text color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                         .foregroundColor: color]
        let s = NSAttributedString(string: text, attributes: attributes)
        let size = s.size()
        var tag = CGRect(x: r.minX, y: r.minY - 5 - 20, width: size.width + 14, height: 20)
        if tag.minY < 4 { tag.origin.y = r.maxY + 5 }
        tag.origin.x = min(max(tag.minX, 4), bounds.width - tag.width - 4)
        fill.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: tag.minX + 7, y: tag.midY - size.height / 2))
    }

    /// A quiet capsule under the widget ("4 numbers share one style", "⌥ shows distances").
    private func drawQuietTag(_ text: String, symbol: String?, centredAt c: CGPoint, dark: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)]
        let s = NSAttributedString(string: text, attributes: attributes)
        let size = s.size()
        let icon = symbol.flatMap { StudioPageStyle.symbol($0, size: 11, color: NSColor.labelColor.withAlphaComponent(0.8)) }
        let iconWidth: CGFloat = icon == nil ? 0 : 18
        let r = CGRect(x: c.x - (size.width + iconWidth) / 2 - 8, y: c.y - 12, width: size.width + iconWidth + 16,
                       height: 24)
        (dark ? NSColor(white: 0.18, alpha: 0.85) : NSColor(white: 1, alpha: 0.72)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        if let icon {
            icon.draw(in: NSRect(x: r.minX + 8, y: r.midY - icon.size.height / 2, width: icon.size.width,
                                 height: icon.size.height))
        }
        s.draw(at: NSPoint(x: r.minX + 8 + iconWidth, y: r.midY - size.height / 2))
    }
}
