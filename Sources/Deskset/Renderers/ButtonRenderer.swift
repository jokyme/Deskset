import AppKit
import DesksetCore

extension SkinRenderer {
    // MARK: Button

    /// Draws the ButtonImage frame of the current state (normal / pressed / hover). An SF Symbol is one frame for all
    /// three, drawn at half opacity while pressed.
    static func drawButton(_ meter: ButtonMeter, _ ctx: CGContext) {
        drawSprite(meter.lower(), ctx)
    }
}
