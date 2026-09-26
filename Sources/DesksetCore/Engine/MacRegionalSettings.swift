import Foundation

/// The Mac's clock, week and temperature settings as skins see them (Deskset extension, docs/compat/engine.md "Clock,
/// week and temperature variables"): `#MACCLOCKHOURS#`, `#MACFIRSTWEEKDAY#` and `#MACTEMPERATUREUNIT#`. They are part
/// of `SkinAppearance`, so they behave like the appearance variables: dynamic, fixed for `[Variables]` and `!SetVariable`,
/// and a change runs `MacOnAppearanceChangeAction`. The app works them out from macOS (`system()`); a host that does not
/// ask macOS (the engine alone, the core self-tests) reports `standard`.
public struct MacRegionalSettings: Equatable {
    /// 12 or 24: System Settings → General → Date & Time → "24-hour time", else the region's own clock.
    public var clockHours: Int
    /// The first day of the week, 0 (Sunday) … 6 (Saturday), counted as the Time measure's `%w` counts: System
    /// Settings → General → Language & Region → First day of week, else the region's.
    public var firstWeekday: Int
    /// System Settings → General → Language & Region → Temperature, else the region's unit for weather.
    public var temperatureUnit: TemperatureUnit

    /// Any number other than 12 is 24; the weekday is clamped to 0…6.
    public init(clockHours: Int = 24, firstWeekday: Int = 0, temperatureUnit: TemperatureUnit = .celsius) {
        self.clockHours = clockHours == 12 ? 12 : 24
        self.firstWeekday = min(max(firstWeekday, 0), 6)
        self.temperatureUnit = temperatureUnit
    }

    /// What a host that does not ask macOS reports: a 24-hour clock, weeks from Sunday, °C.
    public static let standard = MacRegionalSettings()

    /// The Mac's settings now. `Locale.current` and `Calendar.current` carry the user's choices (the 24-hour switch,
    /// the first day of the week, the temperature unit) as well as the region's own conventions; `temperatureSetting`
    /// is the Temperature setting as written (`AppleTemperatureUnit`: "Celsius" / "Fahrenheit"), which wins when set.
    public static func system(locale: Locale = .current, calendar: Calendar = .current,
                              temperatureSetting: String? = UserDefaults.standard.string(forKey: "AppleTemperatureUnit"))
        -> MacRegionalSettings {
        MacRegionalSettings(clockHours: clockHours(locale: locale), firstWeekday: firstWeekday(calendar: calendar),
                            temperatureUnit: temperatureUnit(setting: temperatureSetting, locale: locale))
    }

    /// 12 when the locale's preferred hour (the `j` skeleton, which follows the 24-hour switch) is a 12-hour one
    /// (`h` or `K` outside quoted text), else 24. For every locale macOS 26 knows this agrees with an AM/PM marker in
    /// the pattern, where `Locale.hourCycle` does not always (fr_CA writes "HH 'h'" but reports a 1–12 cycle).
    public static func clockHours(locale: Locale) -> Int {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "H"
        var quoted = false
        for ch in pattern {
            if ch == "'" {
                quoted.toggle()
                continue
            }
            guard !quoted else { continue }
            if ch == "h" || ch == "K" { return 12 }
            if ch == "H" || ch == "k" { return 24 }
        }
        return pattern.contains("a") ? 12 : 24
    }

    /// `calendar.firstWeekday` (1 = Sunday … 7 = Saturday) as 0 … 6.
    public static func firstWeekday(calendar: Calendar) -> Int {
        min(max(calendar.firstWeekday - 1, 0), 6)
    }

    /// The Temperature setting when it names a unit ("Celsius", "Fahrenheit", also "C" / "F"), else the unit the
    /// region uses for weather (°F in the United States, the Bahamas, Belize, the Cayman Islands, Palau and Puerto
    /// Rico; a locale's `mu` keyword wins).
    public static func temperatureUnit(setting: String?, locale: Locale) -> TemperatureUnit {
        switch setting?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "celsius"?, "c"?: return .celsius
        case "fahrenheit"?, "f"?: return .fahrenheit
        default: break
        }
        return UnitTemperature(forLocale: locale, usage: .weather).symbol == UnitTemperature.fahrenheit.symbol
            ? .fahrenheit : .celsius
    }

    // MARK: Variables

    /// The value of `key` (lower case, without `#`): `MACCLOCKHOURS` "12" or "24", `MACFIRSTWEEKDAY` "0"…"6",
    /// `MACTEMPERATUREUNIT` "C" or "F"; nil for any other name.
    public func variableValue(_ key: String) -> String? {
        switch key {
        case "macclockhours": return String(clockHours)
        case "macfirstweekday": return String(firstWeekday)
        case "mactemperatureunit": return temperatureUnit.rawValue
        default: return nil
        }
    }
}
