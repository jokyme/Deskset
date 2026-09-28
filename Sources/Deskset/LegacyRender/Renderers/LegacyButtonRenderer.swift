#if DEBUG
// A frozen copy of ButtonRenderer.swift: see LegacySkinRenderer.swift. Debug builds only.

import AppKit
import DesksetCore

extension LegacySkinRenderer {
    // MARK: Button

    /// Draws the ButtonImage frame of the current state (normal / pressed / hover). An SF Symbol is one frame for all
    /// three, drawn at half opacity while pressed.
    static func drawButton(_ meter: ButtonMeter, _ ctx: CGContext) {
        guard let path = meter.buttonImagePath, let source = meter.sourceRect(for: meter.state),
              let prepared = LegacyPreparedImage(path: path, options: meter.imageOptions, drawn: nil, in: ctx) else { return }
        let pressedSymbol = meter.isSymbol && meter.state == .pressed
        drawImageFrame(prepared, source: source, in: meter.destinationRect.legacyCGRect, ctx, opacity: pressedSymbol ? 0.5 : 1)
    }
}
#endif
