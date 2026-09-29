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
