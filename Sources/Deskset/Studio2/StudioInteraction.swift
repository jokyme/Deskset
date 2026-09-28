import AppKit
import DesksetCore

/// Interact (⌥⌘P): the canvas becomes the widget in use. Hovers, presses, double-clicks and the wheel go to the
/// Studio's own instance of the widget, as they would on the desktop; what stays inside the widget happens (a page
/// turned, a panel opened), what would reach outside it — opening an app or a web page, a command, another widget — is
/// held back by the instance's action policy and offered in a capsule ("Would open Activity Monitor · Open").
///
/// A transparent view over the canvas that takes the pointer only while it is on (otherwise the canvas selects and
/// drags as usual).
final class StudioInteractionView: NSView {
    weak var canvas: SkinCanvasView?
    var skinProvider: () -> Skin? = { nil }
    /// After each event: the canvas redraws.
    var onEvent: (() -> Void)?
    /// Esc leaves Interact.
    var onEscape: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var inside = false

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive, inside {
                inside = false
                skinProvider()?.mouseExited()
                onEvent?()
            }
            window?.invalidateCursorRects(for: self)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isActive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, !isHidden else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// A point of this view in the widget's coordinates (nil: outside the widget).
    func skinPoint(_ p: NSPoint) -> (x: Double, y: Double)? {
        guard let canvas, skinProvider() != nil else { return nil }
        let c = canvas.convert(p, from: self)
        let card = canvas.skinRect
        guard card.contains(c) else { return nil }
        return (Double(c.x - card.minX), Double(c.y - card.minY))
    }

    private func point(_ event: NSEvent) -> (x: Double, y: Double)? {
        skinPoint(convert(event.locationInWindow, from: nil))
    }

    // MARK: Events (also called by the self-tests with widget coordinates)

    /// A press of the left button at (x, y) of the widget (`clicks`: 2 for a double-click).
    func press(x: Double, y: Double, clicks: Int = 1) {
        guard let skin = skinProvider() else { return }
        if clicks == 2, skin.hasAction(.leftDoubleClick, x: x, y: y) { skin.mouseEvent(.leftDoubleClick, x: x, y: y) }
        skin.mouseEvent(.leftDown, x: x, y: y)
        onEvent?()
    }

    func release(x: Double, y: Double) {
        skinProvider()?.mouseEvent(.leftUp, x: x, y: y)
        onEvent?()
    }

    /// A click (press and release) at (x, y).
    func click(x: Double, y: Double) {
        press(x: x, y: y)
        release(x: x, y: y)
    }

    func move(x: Double, y: Double) {
        inside = true
        skinProvider()?.mouseMoved(x: x, y: y)
        onEvent?()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = point(event) else { return }
        press(x: p.x, y: p.y, clicks: event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        let p = skinPoint(convert(event.locationInWindow, from: nil)) ?? (-1, -1)
        release(x: p.x, y: p.y)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let p = point(event), let skin = skinProvider() else { return }
        skin.mouseEvent(.rightDown, x: p.x, y: p.y)
        onEvent?()
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let p = point(event), let skin = skinProvider() else { return }
        skin.mouseEvent(.rightUp, x: p.x, y: p.y)
        onEvent?()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let p = point(event), let skin = skinProvider() else { return }
        skin.mouseEvent(.middleDown, x: p.x, y: p.y)
        onEvent?()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let p = point(event), let skin = skinProvider() else { return }
        skin.mouseEvent(.middleUp, x: p.x, y: p.y)
        onEvent?()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let p = point(event) else { return exited() }
        move(x: p.x, y: p.y)
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) { exited() }

    private func exited() {
        guard inside else { return }
        inside = false
        skinProvider()?.mouseExited()
        onEvent?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = point(event), let skin = skinProvider() else { return }
        let dy = event.scrollingDeltaY, dx = event.scrollingDeltaX
        if abs(dy) >= abs(dx), dy != 0 {
            skin.mouseEvent(dy > 0 ? .scrollUp : .scrollDown, x: p.x, y: p.y)
        } else if dx != 0 {
            skin.mouseEvent(dx > 0 ? .scrollLeft : .scrollRight, x: p.x, y: p.y)
        }
        onEvent?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                         .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isActive, let p = point(event), let skin = skinProvider() else { return super.cursorUpdate(with: event) }
        if skin.hasAction(.leftUp, x: p.x, y: p.y) || skin.hasAction(.leftDown, x: p.x, y: p.y) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// What the widget would have done outside itself while the canvas was interactive, as the capsule offers it.
struct StudioHeldAction: Equatable {
    var sentence: String
    /// The button ("Open", "Run"); nil: nothing to offer (a file the widget would write).
    var button: String?
    let recorded: StudioActionPolicy.Recorded

    init(_ recorded: StudioActionPolicy.Recorded) {
        self.recorded = recorded
        switch recorded.kind {
        case .execute:
            sentence = StudioText.format(.wouldOpen, Self.displayName(of: recorded.name))
            button = StudioText[.open]
        case .bang:
            sentence = StudioText.format(.wouldRun, recorded.text)
            button = StudioText[.run]
        case .file:
            sentence = StudioText.format(.wouldChange, recorded.text)
            button = nil
        }
    }

    /// "Activity Monitor" for an app, "example.com" for a web page, the file's name for a file, else as written.
    static func displayName(of target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let name = (t as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".app") { return String(name.dropLast(4)) }
        return name.isEmpty ? t : name
    }
}
