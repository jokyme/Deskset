import Foundation

/// An SF Symbol used as an image (Deskset extension, docs/compat/engine.md "SF Symbols as images"):
/// `ImageName=sf:cpu.fill` in an Image meter (and `MaskImageName`), `ButtonImage`, `BarImage` and the skin's
/// `Background`.
///
/// The engine only recognises the `sf:` prefix and the options that shape the symbol; the app draws it. A symbol image
/// is named by a canonical path (`sf:cpu.fill?size=16&weight=regular&rendering=monochrome`) that goes wherever an
/// image file's path goes (`SkinHost.imageSize(atPath:)`, the app's image caches), so every general image option works
/// on it as on a file. Its size in points is the symbol's own at `MacSymbolSize`; the app renders it for drawing at
/// the pixels it covers (`density`), so it stays sharp at any W / H and backing scale.
///
/// Options (read with the image options, `ImageOptions.symbol`):
/// - `MacSymbolSize` — point size of the symbol's natural size (default 16), used when the meter has no W / H.
/// - `MacSymbolWeight` — Ultralight, Thin, Light, Regular (default), Medium, Semibold, Bold, Heavy, Black.
/// - `MacSymbolRendering` — Monochrome (default: every layer white, so ImageTint colors it), Hierarchical (white, the
///   secondary layers more transparent: ImageTint gives one color in several strengths) or Multicolor (the symbol's own
///   colors as in Dark Mode; layers without a color of their own are white, and ImageTint multiplies every color).
public struct MacSymbol: Hashable {
    public enum Weight: String, CaseIterable, Hashable {
        case ultralight, thin, light, regular, medium, semibold, bold, heavy, black

        /// `MacSymbolWeight` as written (any case); anything else is Regular.
        public init(parsing text: String) {
            self = Weight(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) ?? .regular
        }

        /// The option value as documented (`Semibold`).
        public var optionValue: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    public enum Rendering: String, CaseIterable, Hashable {
        case monochrome, hierarchical, multicolor

        /// `MacSymbolRendering` as written (any case); anything else is Monochrome.
        public init(parsing text: String) {
            self = Rendering(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) ?? .monochrome
        }

        public var optionValue: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// How a meter asks for its symbols (`MacSymbolSize`, `MacSymbolWeight`, `MacSymbolRendering`).
    public struct Style: Hashable {
        public var pointSize = MacSymbol.defaultPointSize
        public var weight = Weight.regular
        public var rendering = Rendering.monochrome

        public init(pointSize: Double = MacSymbol.defaultPointSize, weight: Weight = .regular,
                    rendering: Rendering = .monochrome) {
            self.pointSize = MacSymbol.clampedPointSize(pointSize)
            self.weight = weight
            self.rendering = rendering
        }

        /// Reads the symbol options of `section` (`prefix` as for the other image options).
        public static func read(from section: SkinSection, prefix: String = "") -> Style {
            Style(pointSize: section.double(prefix + "MacSymbolSize", MacSymbol.defaultPointSize),
                  weight: Weight(parsing: section.string(prefix + "MacSymbolWeight")),
                  rendering: Rendering(parsing: section.string(prefix + "MacSymbolRendering")))
        }
    }

    /// Written before the symbol name: `sf:cpu.fill` (any case).
    public static let prefix = "sf:"
    /// `MacSymbolSize` when it is not set (the size of body text on a Mac).
    public static let defaultPointSize = 16.0
    /// Largest `MacSymbolSize` (points).
    public static let maxPointSize = 1024.0
    /// Pixels per point a symbol is rendered at, at most (and at least `minDensity`).
    public static let maxDensity = 16.0
    public static let minDensity = 0.25

    /// The symbol's name as written after `sf:` (`cpu.fill`).
    public var name: String
    public var style: Style
    /// Pixels per point of the rendered image: 1 for the engine's measurements, the drawn scale for drawing.
    public var density: Double

    public init(name: String, style: Style = Style(), density: Double = 1) {
        self.name = name
        self.style = style
        self.density = MacSymbol.clampedDensity(density)
    }

    /// The symbol name of an image option value written `sf:<name>` (surrounding spaces and quotes allowed), nil for
    /// anything else. `sf:` alone gives the empty name, which the image options treat as no image.
    public static func symbolName(in written: String) -> String? {
        var text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") { text = String(text.dropFirst().dropLast()) }
        guard text.utf8.count >= prefix.utf8.count,
              text.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
        return text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// Whether an image option value names a symbol (`sf:…`).
    public static func isSymbolName(_ written: String) -> Bool { symbolName(in: written) != nil }

    /// The image path for an option value naming a symbol, nil when it names a file.
    public static func path(for written: String, style: Style) -> String? {
        symbolName(in: written).map { MacSymbol(name: $0, style: style).path }
    }

    /// Whether `path` (as the engine resolved it) is a symbol image's path rather than a file's.
    public static func isSymbolPath(_ path: String) -> Bool { path.hasPrefix(prefix) }

    // MARK: Paths

    /// `sf:<name>?size=16&weight=regular&rendering=monochrome` (plus `&density=2` when it is not 1): what the engine and
    /// the app's image caches key the image by. The name is percent-encoded, so no name can reach into the options.
    public var path: String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: MacSymbol.nameCharacters) ?? ""
        var p = "\(MacSymbol.prefix)\(encoded)?size=\(MacSymbol.format(style.pointSize))"
            + "&weight=\(style.weight.rawValue)&rendering=\(style.rendering.rawValue)"
        if density != 1 { p += "&density=\(MacSymbol.format(density))" }
        return p
    }

    /// Parses `path`; nil for a file path.
    public init?(path: String) {
        guard MacSymbol.isSymbolPath(path) else { return nil }
        let rest = path.dropFirst(MacSymbol.prefix.count)
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts.first ?? "").removingPercentEncoding ?? ""
        var style = Style()
        var density = 1.0
        if parts.count > 1 {
            for item in parts[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let value = String(pair[1])
                switch pair[0] {
                case "size": style.pointSize = MacSymbol.clampedPointSize(Double(value) ?? MacSymbol.defaultPointSize)
                case "weight": style.weight = Weight(parsing: value)
                case "rendering": style.rendering = Rendering(parsing: value)
                case "density": density = Double(value) ?? 1
                default: break
                }
            }
        }
        self.init(name: name, style: style, density: density)
    }

    /// The same symbol rendered at `density` pixels per point.
    public func withDensity(_ density: Double) -> MacSymbol {
        MacSymbol(name: name, style: style, density: density)
    }

    /// The same symbol at the engine's density (1): the path its size is measured by.
    public var measuringPath: String { withDensity(1).path }

    // MARK: Limits

    static func clampedPointSize(_ size: Double) -> Double {
        size.isFinite && size > 0 ? min(size, maxPointSize) : defaultPointSize
    }

    static func clampedDensity(_ density: Double) -> Double {
        density.isFinite ? min(max(density, minDensity), maxDensity) : 1
    }

    private static let nameCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: ".-_")
        return set
    }()

    private static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v)
    }
}

extension Meter {
    /// A symbol image the host cannot draw (`SkinHost.imageSize(atPath:)` is nil for it) is a name macOS does not
    /// have: noted once as a compatibility issue and logged once, and the meter draws nothing.
    func noteMissingSymbol(_ path: String?) {
        guard let path, let symbol = MacSymbol(path: path) else { return }
        skin.noteMissingSymbol(symbol, section: name)
    }

    /// Takes back the note of a missing symbol the meter no longer shows (a measure's value named it, and now names
    /// another picture). Nothing for a file, or a symbol the host has.
    func withdrawMissingSymbol(_ path: String?) {
        guard let path, let symbol = MacSymbol(path: path) else { return }
        skin.removeIssue(Skin.missingSymbolNote(symbol, section: name))
    }

    /// Meters that cannot draw symbols (Bitmap, Rotator, Histogram) note an `sf:` image option once and draw nothing.
    /// True when `written` names a symbol.
    func rejectSymbol(_ written: String, option: String) -> Bool {
        guard MacSymbol.isSymbolName(written) else { return false }
        let value = written.trimmingCharacters(in: .whitespaces)
        skin.addIssue("[\(name)] \(option)=\(value): SF Symbols (sf:) are drawn by Image, Button and Bar meters and the "
                      + "skin background only")
        return true
    }
}

extension Skin {
    /// `Background=sf:…` naming a symbol macOS does not have (see `Meter.noteMissingSymbol`).
    func noteMissingBackgroundSymbol() {
        guard let path = settings.backgroundImage, let symbol = MacSymbol(path: path), let host,
              host.imageSize(atPath: path) == nil else { return }
        noteMissingSymbol(symbol, section: "Rainmeter")
    }

    /// See `Meter.noteMissingSymbol`.
    func noteMissingSymbol(_ symbol: MacSymbol, section: String) {
        let message = Skin.missingSymbolNote(symbol, section: section)
        addIssue(message)
        logOnce(message, level: .warning)
    }

    static func missingSymbolNote(_ symbol: MacSymbol, section: String) -> String {
        "[\(section)] sf:\(symbol.name): there is no SF Symbol called “\(symbol.name)” on this Mac"
    }
}
