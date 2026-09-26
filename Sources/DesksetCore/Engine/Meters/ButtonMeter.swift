import Foundation

/// `Meter=Button` (manual: Meters → Button; Tips → Button Images).
///
/// - `ButtonImage` (+ ImagePath and the general image options except ImageCrop/ImageRotate) holds 3 equal
///   frames — normal, pressed ("clicked"), hover — side by side when the image is wider than tall, stacked
///   otherwise. W and H are ignored; the meter is one frame big.
/// - `ButtonCommand` runs when the left button is pressed and released on the button. Transparent pixels of the
///   image are never part of the button, for clicks and for hover ("ButtonCommand ignores transparent pixels in
///   the image at all times"; the version history adds the same for mouse over). A pixel counts when the normal
///   frame or the frame on screen is opaque there (see `hitTest`). Pixel alpha comes from the host through
///   `SkinImageQueries`; without it the whole frame counts as opaque.
/// - The meter's own mouse actions (LeftMouseDownAction, LeftMouseUpAction…) still run: an event is consumed
///   only when the meter has no action for it — none defined, or one removed with `!ClearMouseAction` (a disabled
///   action still counts: the skin then catches the event and runs nothing).
/// - ImageFlip flips every frame in place (judgment call; flipping the whole strip would reorder the states).
/// - Hover updates arrive only while no mouse button is held, so a hover update also ends a press whose release
///   was not delivered (e.g. the window was dragged).
public final class ButtonMeter: Meter {
    public enum State: Int { case normal = 0, pressed = 1, hover = 2 }

    public private(set) var buttonImagePath: String?
    public private(set) var imageOptions = ImageOptions()
    public private(set) var buttonCommand = ""
    public private(set) var state = State.normal
    private var pressed = false

    public override func readMeterOptions() {
        // "All general meter options are valid, except W and H."
        widthOption = nil
        heightOption = nil
        imageOptions = ImageOptions.read(from: self, crop: false, rotate: false)
        buttonImagePath = ImageOptions.filePath(string("ButtonImage"), imagePath: ImageOptions.imagePathOption(self),
                                                skin: skin)
        buttonCommand = actionOption("ButtonCommand")
    }

    // MARK: Geometry

    /// Frame size and strip orientation; nil without a loadable image.
    public var frameLayout: (width: Double, height: Double, horizontal: Bool)? {
        guard let size = imageDisplaySize(buttonImagePath, imageOptions) else { return nil }
        return ImageGeometry.stripFrames(imageWidth: size.width, imageHeight: size.height, count: 3)
    }

    public override func naturalSize() -> (width: Double, height: Double) {
        guard let f = frameLayout else { return (0, 0) }
        return (f.width, f.height)
    }

    /// Source rectangle (image pixels) of the frame for `state`; nil without a loadable image.
    public func sourceRect(for state: State) -> SkinRect? {
        guard let f = frameLayout, f.width > 0, f.height > 0 else { return nil }
        return ImageGeometry.stripFrameRect(index: state.rawValue, frameWidth: f.width, frameHeight: f.height,
                                            horizontal: f.horizontal)
    }

    /// Where the current frame is drawn (the content rect, one frame big).
    public var destinationRect: SkinRect {
        let c = contentFrame
        guard let f = frameLayout else { return SkinRect(x: c.x, y: c.y) }
        return SkinRect(x: c.x, y: c.y, width: f.width, height: f.height)
    }

    /// True when (x, y) is on a non-transparent pixel of the normal frame or of the frame currently shown.
    ///
    /// Judgment call: testing only the frame currently shown makes the state depend on itself — where the hover
    /// frame is transparent but the normal frame is not (a smaller or shifted hover image), every mouse move
    /// flipped normal ↔ hover, and a pressed frame drawn a few pixels lower (the Button Images tip suggests that
    /// for a button that "moves" when clicked) swallowed releases on its edge. The normal frame is the button's
    /// shape; the frame on screen adds the pixels the user sees. Transparent pixels of both are never the button.
    public override func hitTest(x: Double, y: Double) -> Bool {
        guard let path = buttonImagePath, let f = frameLayout, f.width > 0, f.height > 0 else { return false }
        let dest = destinationRect
        guard dest.contains(x: x, y: y) else { return false }
        var lx = (x - dest.x).rounded(.down), ly = (y - dest.y).rounded(.down)
        if imageOptions.flip.horizontal { lx = f.width - 1 - lx }
        if imageOptions.flip.vertical { ly = f.height - 1 - ly }
        func opaque(_ s: State) -> Bool {
            let source = ImageGeometry.stripFrameRect(index: s.rawValue, frameWidth: f.width, frameHeight: f.height,
                                                      horizontal: f.horizontal)
            let px = Int((source.x + lx).clamped(0, ImageOptions.maxSide))
            let py = Int((source.y + ly).clamped(0, ImageOptions.maxSide))
            guard let alpha = imagePixelAlpha(path, x: px, y: py, exifOriented: imageOptions.useExifOrientation)
            else { return true }
            return alpha > 0
        }
        return opaque(.normal) || (state != .normal && opaque(state))
    }

    // MARK: Mouse

    public override var handlesMouseItself: Bool { true }

    public override func handleMouse(_ kind: MouseEventKind, x: Double, y: Double) -> Bool {
        switch kind {
        case .leftDown:
            guard hitTest(x: x, y: y) else { return false }
            pressed = true
            setState(.pressed)
            return effectiveMouseAction(kind) == nil
        case .leftUp:
            guard pressed else { return false }
            pressed = false
            let inside = hitTest(x: x, y: y)
            setState(inside ? .hover : .normal)
            guard inside else { return false }
            if !buttonCommand.isEmpty { skin.execute(buttonCommand, from: self) }
            return effectiveMouseAction(kind) == nil
        default:
            return false
        }
    }

    public override func mouseHover(inside: Bool, x: Double, y: Double) {
        pressed = false
        setState(inside && hitTest(x: x, y: y) ? .hover : .normal)
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        skin.redraw()
    }
}
