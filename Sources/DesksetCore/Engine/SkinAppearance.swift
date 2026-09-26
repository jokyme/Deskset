import Foundation

/// The Mac's light or dark appearance and its semantic colors, as skins see them through the appearance variables
/// (Deskset extension, docs/compat/engine.md "Light and dark mode variables"): `#MACAPPEARANCE#`, `#MACDARKMODE#`,
/// `#MACACCENTCOLOR#`, `#MACLABELCOLOR#`, `#MACSECONDARYLABELCOLOR#`, `#MACTERTIARYLABELCOLOR#`,
/// `#MACSEPARATORCOLOR#`. The app fills it in from AppKit (`SkinEnvironment.appearance`); the colors are sRGB, resolved
/// for the appearance.
public struct SkinAppearance: Equatable {
    public var isDark: Bool
    /// System Settings → Appearance → Accent color.
    public var accentColor: RGBA
    /// Text colors: primary, secondary, tertiary (translucent black in light mode, translucent white in dark mode).
    public var labelColor: RGBA
    public var secondaryLabelColor: RGBA
    public var tertiaryLabelColor: RGBA
    /// Hairlines between items.
    public var separatorColor: RGBA

    public init(isDark: Bool, accentColor: RGBA, labelColor: RGBA, secondaryLabelColor: RGBA,
                tertiaryLabelColor: RGBA, separatorColor: RGBA) {
        self.isDark = isDark
        self.accentColor = accentColor
        self.labelColor = labelColor
        self.secondaryLabelColor = secondaryLabelColor
        self.tertiaryLabelColor = tertiaryLabelColor
        self.separatorColor = separatorColor
    }

    /// Close to macOS's light appearance with the blue accent (what a host without AppKit reports).
    public static let light = SkinAppearance(isDark: false, accentColor: RGBA(r: 0, g: 122, b: 255),
                                             labelColor: RGBA(r: 0, g: 0, b: 0, a: 217),
                                             secondaryLabelColor: RGBA(r: 0, g: 0, b: 0, a: 128),
                                             tertiaryLabelColor: RGBA(r: 0, g: 0, b: 0, a: 66),
                                             separatorColor: RGBA(r: 0, g: 0, b: 0, a: 26))
    /// Close to macOS's dark appearance with the blue accent.
    public static let dark = SkinAppearance(isDark: true, accentColor: RGBA(r: 10, g: 132, b: 255),
                                            labelColor: RGBA(r: 255, g: 255, b: 255, a: 217),
                                            secondaryLabelColor: RGBA(r: 255, g: 255, b: 255, a: 140),
                                            tertiaryLabelColor: RGBA(r: 255, g: 255, b: 255, a: 64),
                                            separatorColor: RGBA(r: 255, g: 255, b: 255, a: 26))

    // MARK: Variables

    /// The value of the appearance variable `key` (lower case, without `#`), nil for any other name.
    /// `MACAPPEARANCE` is `Dark` or `Light` (usable in `@Include=#@#Theme-#MACAPPEARANCE#.inc`), `MACDARKMODE` 1 or 0,
    /// the colors `R,G,B,A` (0–255).
    public func variableValue(_ key: String) -> String? {
        switch key {
        case "macappearance": return isDark ? "Dark" : "Light"
        case "macdarkmode": return isDark ? "1" : "0"
        case "macaccentcolor": return SkinAppearance.format(accentColor)
        case "maclabelcolor": return SkinAppearance.format(labelColor)
        case "macsecondarylabelcolor": return SkinAppearance.format(secondaryLabelColor)
        case "mactertiarylabelcolor": return SkinAppearance.format(tertiaryLabelColor)
        case "macseparatorcolor": return SkinAppearance.format(separatorColor)
        default: return nil
        }
    }

    /// Every appearance variable (lower-case name → value).
    public var variables: [String: String] {
        var result: [String: String] = [:]
        for name in BuiltInVariables.macAppearanceNames {
            let key = name.lowercased()
            result[key] = variableValue(key)
        }
        return result
    }

    /// `R,G,B,A` with whole numbers 0–255.
    public static func format(_ c: RGBA) -> String {
        func channel(_ v: Double) -> Int { v.isFinite ? Int(v.clamped(0, 255).rounded()) : 0 }
        return "\(channel(c.r)),\(channel(c.g)),\(channel(c.b)),\(channel(c.a))"
    }

    /// Whether `text` (a skin file's option value) names one of the appearance variables, in any form (`#MACDARKMODE#`,
    /// `[#MACDARKMODE]`, a Lua or bang argument): such a skin is refreshed when the appearance changes. A plain word
    /// that happens to be such a name counts too (the only cost is an extra refresh).
    public static func mentioned(in text: String) -> Bool {
        guard text.utf8.count >= 10 else { return false }
        let lower = text.lowercased()
        guard lower.contains("mac") else { return false }
        return BuiltInVariables.macAppearanceNames.contains { lower.contains($0.lowercased()) }
    }
}
