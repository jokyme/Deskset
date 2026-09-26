import AppKit
import DesksetCore

/// The Mac's appearance as skins see it: `#MACAPPEARANCE#`, `#MACDARKMODE#` and the color variables (`SkinAppearance`,
/// Deskset extension). Worked out on the main thread from the app's effective appearance and published for skins that
/// update on threads of their own (`MainPublished`, docs/skin-threading.md §4.6); the app publishes it at launch and
/// again whenever the appearance or the accent color changes (`AppController.appearanceChanged`).
enum MacAppearance {
    static let current = MainPublished<SkinAppearance>(maxAge: 1, initial: .light) {
        values(for: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua))
    }

    /// The values for `appearance`, its semantic colors resolved in sRGB. Any thread: the colors are resolved with
    /// `appearance` as the thread's drawing appearance.
    static func values(for appearance: NSAppearance?) -> SkinAppearance {
        guard let appearance else { return .light }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var result = dark ? SkinAppearance.dark : SkinAppearance.light
        appearance.performAsCurrentDrawingAppearance {
            func rgba(_ color: NSColor) -> RGBA? {
                guard let c = color.usingColorSpace(.sRGB) else { return nil }
                return RGBA(r: Double(c.redComponent) * 255, g: Double(c.greenComponent) * 255,
                            b: Double(c.blueComponent) * 255, a: Double(c.alphaComponent) * 255)
            }
            if let c = rgba(.controlAccentColor) { result.accentColor = c }
            if let c = rgba(.labelColor) { result.labelColor = c }
            if let c = rgba(.secondaryLabelColor) { result.secondaryLabelColor = c }
            if let c = rgba(.tertiaryLabelColor) { result.tertiaryLabelColor = c }
            if let c = rgba(.separatorColor) { result.separatorColor = c }
        }
        return result
    }
}
