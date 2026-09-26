import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Button

    /// Draws the ButtonImage frame of the current state (normal / pressed / hover).
    static func drawButton(_ meter: ButtonMeter, _ ctx: CGContext) {
        guard let path = meter.buttonImagePath, let source = meter.sourceRect(for: meter.state),
              let prepared = PreparedImage(path: path, options: meter.imageOptions) else { return }
        drawImageFrame(prepared, source: source, in: meter.destinationRect.cgRect, ctx)
    }
}
