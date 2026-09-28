import AppKit
import DesksetCore

/// The code's problems on the canvas: an amber dashed frame around each part that still draws with a default (a
/// misspelled key), a red dashed "ghost" where each part that cannot draw would be — its last working place — with a
/// red badge on the first. The widget on the desktop does not show them; the parts that can draw draw as usual.
final class StudioProblemMarks: NSView {
    weak var canvas: SkinCanvasView?
    var skinProvider: () -> Skin? = { nil }
    /// Parts that cannot draw, and where they were when they last could (skin points).
    private(set) var ghosts: [(name: String, frame: SkinRect)] = []
    /// Parts that draw with a default.
    private(set) var framed: [String] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(ghosts: [(name: String, frame: SkinRect)], framed: [String]) {
        self.ghosts = ghosts
        self.framed = framed
        needsDisplay = true
    }

    /// A part's frame in this view, `outset` skin points bigger on every side.
    func rect(_ frame: SkinRect, outset: Double) -> CGRect? {
        guard let canvas, frame.width > 0 || frame.height > 0 else { return nil }
        let grown = SkinRect(x: frame.x - outset, y: frame.y - outset, width: frame.width + outset * 2,
                             height: frame.height + outset * 2)
        return canvas.convert(canvas.viewRect(grown), to: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let skin = skinProvider() else { return }
        for name in framed {
            guard let m = skin.meter(named: name), !m.hidden, let r = rect(m.frame, outset: 2) else { continue }
            Self.dashed(r, color: StudioCodeColors.warning)
        }
        var badge: CGRect?
        for ghost in ghosts {
            guard let r = rect(ghost.frame, outset: 3) else { continue }
            StudioCodeColors.problem.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            Self.dashed(r, color: StudioCodeColors.problem)
            if badge == nil { badge = r }
        }
        if let b = badge {
            let circle = NSRect(x: b.maxX - 8, y: b.minY - 8, width: 16, height: 16)
            StudioCodeColors.problem.setFill()
            NSBezierPath(ovalIn: circle).fill()
            if let mark = StudioPageStyle.symbol("exclamationmark", size: 9, weight: .heavy, color: .white) {
                mark.draw(in: NSRect(x: circle.midX - mark.size.width / 2, y: circle.midY - mark.size.height / 2,
                                     width: mark.size.width, height: mark.size.height))
            }
        }
    }

    static func dashed(_ r: CGRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        path.setLineDash([3, 2.5], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }
}
