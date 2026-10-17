import AppKit
import DesksetCore

/// What the preview bar and the zoom capsule set: how the Studio shows the widget, never the widget itself (nothing
/// here is written to its files or reaches the desktop copy).
struct StudioPreviewState: Equatable {
    /// The Mac's look the canvas and the Studio's instance see.
    enum Appearance: Int, CaseIterable {
        case followMac, light, dark
    }

    /// How glass is shown: as the widget has it, clearer, or tinted (the Mac-wide glass setting of later macOS).
    enum Glass: Int, CaseIterable {
        case standard, clear, tinted
    }

    var appearance = Appearance.followMac
    var glass = Glass.standard
    var backdrop = StudioBackdropKind.desktop
    /// Whether the other widgets on the desktop are drawn around this one (nil: at 100 % when it is on the desktop).
    var showsNeighbours: Bool?

    /// The glass regions as the preview shows them.
    func previewed(_ regions: [GlassRegion], dark: Bool) -> [GlassRegion] {
        switch glass {
        case .standard: return regions
        case .clear: return regions.map { var r = $0; r.style = .clear; return r }
        case .tinted:
            let tint = dark ? RGBA(r: 20, g: 20, b: 24, a: 150) : RGBA(r: 255, g: 255, b: 255, a: 170)
            return regions.map { var r = $0; r.tint = r.tint ?? tint; return r }
        }
    }
}

/// The Studio's settings that are remembered for the user (the backdrop). Headless — self-tests, snapshots — they are
/// kept in memory only, so no run changes the user's own.
final class StudioPreferences {
    static let backdropKey = "StudioBackdrop"
    private let defaults: UserDefaults?
    private var memory: [String: String] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    var backdrop: StudioBackdropKind {
        get {
            let raw = defaults?.string(forKey: Self.backdropKey) ?? memory[Self.backdropKey]
            return raw.flatMap(StudioBackdropKind.init(rawValue:)) ?? .desktop
        }
        set {
            if let defaults { defaults.set(newValue.rawValue, forKey: Self.backdropKey) }
            else { memory[Self.backdropKey] = newValue.rawValue }
        }
    }
}

/// The name the caption gives the widget's size on the desktop: its size variant's ("Medium"), else a percentage.
enum StudioSizeName {
    /// "Small", "Medium" or "Large" for a variant file of that name (`Medium.ini`), else "100%".
    static func name(forFile file: String) -> String {
        let base = (file as NSString).deletingPathExtension.lowercased()
        switch base {
        case "small": return StudioText[.sizeSmall]
        case "medium": return StudioText[.sizeMedium]
        case "large": return StudioText[.sizeLarge]
        default: return "100%"
        }
    }

    /// "165%".
    static func zoomText(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// The canvas caption: "Preview 165% · Medium on your desktop", or where it is at Actual Size.
    static func caption(zoom: CGFloat, file: String, onDesktop: Bool, actualSize: Bool) -> String {
        if actualSize && onDesktop { return StudioText[.captionActualSize] }
        let size = name(forFile: file)
        return onDesktop ? StudioText.format(.captionOnDesktop, zoomText(zoom), size)
                         : StudioText.format(.captionNotOnDesktop, zoomText(zoom), size)
    }
}
