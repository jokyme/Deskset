#if DEBUG
// The frozen renderer's host for `--render --legacy` (see LegacySkinRenderer.swift). Debug builds only.

import AppKit
import DesksetCore

/// `RenderHost` with the frozen copy's measuring: the skin's text sizes (`LegacySkinRenderer.textSize`) and image sizes
/// and queries (`LegacyImages`), so a skin laid out and drawn through it depends on the frozen renderer alone.
/// Everything else goes to the `RenderHost` it wraps (its log lines are collected there).
final class LegacyRenderHost: SkinHost, SkinImageQueries {
    let base: RenderHost

    init(_ base: RenderHost = RenderHost()) {
        self.base = base
    }

    func skinNeedsDisplay(_ skin: Skin) { base.skinNeedsDisplay(skin) }
    func skin(_ skin: Skin, handle bang: Bang) -> Bool { base.skin(skin, handle: bang) }
    func skin(_ skin: Skin, forward bang: Bang, toConfig config: String) {
        base.skin(skin, forward: bang, toConfig: config)
    }
    func skin(_ skin: Skin, execute target: String, arguments: [String]) {
        base.skin(skin, execute: target, arguments: arguments)
    }
    func skin(_ skin: Skin, log message: String, level: SkinLogLevel) { base.skin(skin, log: message, level: level) }
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        LegacySkinRenderer.textSize(text, style: style, wrapWidth: wrapWidth, for: skin)
    }
    func imageSize(atPath path: String) -> (width: Double, height: Double)? { LegacyImages.size(atPath: path) }
    func environment(for skin: Skin) -> SkinEnvironment { base.environment(for: skin) }

    func imageExifOrientation(atPath path: String) -> Int { LegacyImages.exifOrientation(atPath: path) }
    func imagePixelAlpha(atPath path: String, x: Int, y: Int, exifOriented: Bool) -> Double? {
        LegacyImages.pixelAlpha(atPath: path, x: x, y: y, oriented: exifOriented)
    }
}
#endif
