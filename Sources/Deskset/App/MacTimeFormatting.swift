import Foundation
import DesksetCore

/// `TimeFormatting` for the app's own UI — the Skin Studio's previews, examples and menus — with the Mac's clock, time
/// zone and locale as defaults. Skins never go through these: the engine passes each skin's own clock, zone and locale
/// (`SkinClock`, `SkinEnvironment.locale`), and `DesksetCore` has no such defaults, so that a new engine call cannot
/// read the Mac's by accident (the seam check lists this file among the UI).
enum MacTimeFormatting {
    static func format(_ date: Date, format: String, timeZone: TimeZone = .current,
                       locale: Locale = TimeFormatting.defaultLocale) -> String {
        TimeFormatting.format(date, format: format, timeZone: timeZone, locale: locale,
                              systemLocale: .autoupdatingCurrent)
    }

    static func timeZone(forOption option: String?, daylightSavingTime: Bool = true) -> TimeZone {
        TimeFormatting.timeZone(forOption: option, daylightSavingTime: daylightSavingTime, at: Date(),
                                localTimeZone: .current)
    }

    static func locale(fromOption option: String?) -> Locale? {
        TimeFormatting.locale(fromOption: option, local: .autoupdatingCurrent)
    }
}
