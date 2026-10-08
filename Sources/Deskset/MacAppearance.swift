import AppKit
import DesksetCore

/// The Mac's appearance as skins see it: `#MACAPPEARANCE#`, `#MACDARKMODE#`, the color variables and the clock, week
/// and temperature settings (`SkinAppearance`, Deskset extension). Worked out on the main thread from the app's
/// effective appearance (and `MacRegional`) and published for skins that update on threads of their own
/// (`MainPublished`, docs/skin-threading.md §4.6); the app publishes it at launch and again whenever the appearance, the
/// accent color or one of those settings changes (`AppController.appearanceChanged`).
enum MacAppearance {
    /// Published on every change (`AppController.appearanceChanged`); the age limit is only a safety net, long enough
    /// that skins on other threads rebuilding their environment at every update do not wake the main thread for it.
    static let current = MainPublished<SkinAppearance>(maxAge: 60, initial: .light) {
        values(for: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua))
    }

    /// The values for `appearance`, its semantic colors resolved in sRGB, with the Mac's clock, week and temperature
    /// settings (`MacRegional.current`). Any thread: the colors are resolved with `appearance` as the thread's drawing
    /// appearance.
    static func values(for appearance: NSAppearance?) -> SkinAppearance {
        var light = SkinAppearance.light
        light.regional = MacRegional.current
        guard let appearance else { return light }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var result = dark ? SkinAppearance.dark : SkinAppearance.light
        result.regional = light.regional
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

    struct ProgramValues {
        let appearance: SkinAppearance
        let colors: ProgramColorInput
    }

    enum ProgramFailure: Error { case unresolvableColor(ProgramPaletteColor) }

    /// The editor supplies its actual appearance. One capture feeds both semantic appearance and the complete
    /// program palette; a platform conversion failure is an error, never a fixed approximation of a system hue.
    static func programValues(for appearance: NSAppearance) throws -> ProgramValues {
        precondition(Thread.isMainThread)
        func native(_ key: ProgramPaletteColor) -> NSColor {
            switch key {
            case .accent: return .controlAccentColor
            case .text: return .labelColor
            case .dim: return .secondaryLabelColor
            case .faint: return .tertiaryLabelColor
            case .separator: return .separatorColor
            case .red: return .systemRed
            case .orange: return .systemOrange
            case .yellow: return .systemYellow
            case .green: return .systemGreen
            case .mint: return .systemMint
            case .teal: return .systemTeal
            case .cyan: return .systemCyan
            case .blue: return .systemBlue
            case .indigo: return .systemIndigo
            case .purple: return .systemPurple
            case .pink: return .systemPink
            case .brown: return .systemBrown
            case .gray: return .systemGray
            case .white: return .white
            case .black: return .black
            case .clear: return .clear
            }
        }
        var colors: [ProgramPaletteColor: RGBA] = [:]
        var failure: ProgramFailure?
        appearance.performAsCurrentDrawingAppearance {
            for key in ProgramPaletteColor.allCases {
                guard let value = native(key).usingColorSpace(.sRGB) else { failure = .unresolvableColor(key); return }
                let channels = [value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent]
                guard channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { failure = .unresolvableColor(key); return }
                colors[key] = RGBA(r: Double(value.redComponent) * 255, g: Double(value.greenComponent) * 255,
                                   b: Double(value.blueComponent) * 255, a: Double(value.alphaComponent) * 255)
            }
        }
        if let failure { throw failure }
        guard let accent = colors[.accent], let text = colors[.text], let dim = colors[.dim],
              let faint = colors[.faint], let separator = colors[.separator] else { throw ProgramRuntimeError.invalidColorInput }
        var value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? SkinAppearance.dark : SkinAppearance.light
        value.regional = MacRegional.current
        value.accentColor = accent; value.labelColor = text; value.secondaryLabelColor = dim
        value.tertiaryLabelColor = faint; value.separatorColor = separator
        return ProgramValues(appearance: value, colors: ProgramColorInput(colors: colors))
    }
}

/// The Mac's clock, week and temperature settings as skins see them (`#MACCLOCKHOURS#`, `#MACFIRSTWEEKDAY#`,
/// `#MACTEMPERATUREUNIT#`: `MacRegionalSettings`, Deskset extension), kept here: worked out on first use and again when
/// macOS says one of them may have changed (`AppController.regionalSettingsChanged`), not at every read — the locale's
/// hour pattern costs more to ask for than the colors, and every skin's environment reads these. The weather plugins'
/// defaults (their 12/24-hour times, the temperature unit of `Units=Auto`) read them too, so the two always agree.
/// `--render` fixes them (`fix`). Any thread.
enum MacRegional {
    private struct State {
        var value: MacRegionalSettings?
        var fixed: MacRegionalSettings?
        var source: () -> MacRegionalSettings = { .system() }
    }

    private static let state = Guarded(State())

    /// The settings skins see now.
    static var current: MacRegionalSettings {
        let (value, fixed) = state.access { ($0.value, $0.fixed) }
        return fixed ?? value ?? refresh()
    }

    /// Works the Mac's settings out again (after macOS said they may have changed) and returns what skins see.
    @discardableResult
    static func refresh() -> MacRegionalSettings {
        let source = state.access { $0.source }
        let value = source()
        return state.access { s -> MacRegionalSettings in
            s.value = value
            return s.fixed ?? value
        }
    }

    /// `--render`: these settings whatever the Mac's are (nil: the Mac's again).
    static func fix(_ settings: MacRegionalSettings?) {
        state.access { $0.fixed = settings }
    }

    /// What `fix` set (nil: the Mac's settings), for putting it back.
    static var fixed: MacRegionalSettings? { state.access { $0.fixed } }

    /// The self-tests: where "the Mac's settings" come from (nil: macOS). The next read works them out again.
    static func setSource(_ source: (() -> MacRegionalSettings)?) {
        state.access {
            $0.source = source ?? { .system() }
            $0.value = nil
        }
    }
}

/// Watches the preference keys behind the clock, week and temperature settings (System Settings writes them in the
/// global domain, which `UserDefaults.standard` reads): `changed` runs on the main thread after any of them changes.
final class RegionalDefaultsObserver: NSObject {
    static let keys = ["AppleICUForce24HourTime", "AppleICUForce12HourTime", "AppleFirstWeekday", "AppleTemperatureUnit",
                       "AppleLocale", "AppleMeasurementUnits", "AppleMetricUnits"]
    private let defaults: UserDefaults
    private let changed: () -> Void

    init(defaults: UserDefaults = .standard, changed: @escaping () -> Void) {
        self.defaults = defaults
        self.changed = changed
        super.init()
        for key in Self.keys { defaults.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    deinit {
        for key in Self.keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [changed] in changed() }
    }
}
