import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Button

    /// Draws the ButtonImage frame of the current state (normal / pressed / hover). An SF Symbol is one frame for all
    /// three, drawn at half opacity while pressed.
    static func drawButton(_ meter: ButtonMeter, _ ctx: CGContext) {
        guard let path = meter.buttonImagePath, let source = meter.sourceRect(for: meter.state),
              let prepared = PreparedImage(path: path, options: meter.imageOptions, drawn: nil, in: ctx) else { return }
        let pressedSymbol = meter.isSymbol && meter.state == .pressed
        drawImageFrame(prepared, source: source, in: meter.destinationRect.cgRect, ctx, opacity: pressedSymbol ? 0.5 : 1)
    }
}
