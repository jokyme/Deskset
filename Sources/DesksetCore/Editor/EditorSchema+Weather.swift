import Foundation

// The weather plugins in the editor (docs/compat/weather.md): `Plugin=MacWeather` (MET Norway's forecasts) and
// `Plugin=MacSun` (sun and moon, worked out on the Mac). Deskset extensions.

extension EditorSchema {
    // MARK: Types

    /// `Type=` of a MacWeather measure, in plain words, grouped as the menu shows them (now, forecast, sun, place, the
    /// data itself).
    public static let weatherTypes: [Choice] = [
        Choice("Temperature", "Temperature"), Choice("FeelsLike", "Feels like"), Choice("Condition", "Condition"),
        Choice("Symbol", "Weather icon (SF Symbol)"), Choice("SymbolPalette", "Weather icon colors (for Palette)"),
        Choice("SymbolCode", "Weather code (MET Norway)"),
        Choice("Humidity", "Humidity"), Choice("DewPoint", "Dew point"), Choice("Pressure", "Air pressure"),
        Choice("CloudCover", "Cloud cover"), Choice("Fog", "Fog"), Choice("UVIndex", "UV index"),
        Choice("WindSpeed", "Wind speed", aliases: ["Wind"]), Choice("WindGust", "Wind gusts"),
        Choice("WindDirection", "Wind direction (degrees)"), Choice("WindCardinal", "Wind direction (N, NE…)"),
        Choice("Beaufort", "Wind force (Beaufort)"), Choice("IsDaylight", "Day or night"),
        Choice("High", "High"), Choice("Low", "Low"), Choice("Precipitation", "Rain amount"),
        Choice("PrecipitationChance", "Chance of rain"), Choice("ThunderChance", "Chance of thunder"),
        Choice("TemperatureColor", "Temperature color"), Choice("TemperatureCurve", "Temperature curve (Shape path)"),
        Choice("Time", "Time of the hour or day"),
        Choice("Sunrise", "Sunrise"), Choice("Sunset", "Sunset"), Choice("SolarNoon", "Solar noon"),
        Choice("DayLength", "Length of the day"), Choice("DaylightProgress", "How far the day has gone"),
        Choice("Place", "Place"), Choice("PlaceDetail", "Place, region and country"), Choice("Country", "Country"),
        Choice("CountryCode", "Country code"), Choice("Latitude", "Latitude"), Choice("Longitude", "Longitude"),
        Choice("TimeZone", "Time zone"),
        Choice("UpdatedAt", "Updated at"), Choice("ForecastTime", "Forecast made at"), Choice("Status", "Status"),
        Choice("StatusSymbol", "Status icon (SF Symbol)"), Choice("Attribution", "Credit (Based on data from MET Norway)"),
        Choice("AttributionShort", "Short credit (Data: MET Norway)"), Choice("AttributionURL", "Source link"),
        Choice("LicenseURL", "License link"),
        Choice("TemperatureUnit", "Temperature unit"), Choice("WindUnit", "Wind unit"),
        Choice("PrecipitationUnit", "Rain unit"), Choice("PressureUnit", "Pressure unit"),
        Choice("LocationSource", "Where the place comes from"),
    ]

    /// Types that take `Hour=` / `Day=` (as the plugin reads them).
    static let weatherHourlyTypes = ["Temperature", "FeelsLike", "DewPoint", "Condition", "Symbol", "SymbolCode",
                                     "SymbolPalette", "IsDaylight", "Humidity", "Pressure", "CloudCover", "Fog", "UVIndex", "WindSpeed",
                                     "WindGust", "WindDirection", "WindCardinal", "Beaufort", "Precipitation",
                                     "PrecipitationChance", "ThunderChance", "TemperatureColor", "Time"]
    static let weatherDailyTypes = ["High", "Low", "Condition", "Symbol", "SymbolCode", "SymbolPalette", "UVIndex",
                                    "WindSpeed",
                                    "WindGust", "Beaufort", "Precipitation", "PrecipitationChance", "ThunderChance",
                                    "TemperatureColor", "Time", "Sunrise", "Sunset", "SolarNoon", "DayLength"]
    static let weatherTimeTypes = ["Time", "Sunrise", "Sunset", "SolarNoon", "UpdatedAt", "ForecastTime", "Status"]

    /// `Type=` of a MacSun measure.
    public static let sunTypes: [Choice] = [
        Choice("Sunrise", "Sunrise"), Choice("Sunset", "Sunset"), Choice("SolarNoon", "Solar noon"),
        Choice("CivilDawn", "Dawn (civil)"), Choice("CivilDusk", "Dusk (civil)"),
        Choice("NauticalDawn", "Dawn (nautical)"), Choice("NauticalDusk", "Dusk (nautical)"),
        Choice("AstronomicalDawn", "Dawn (astronomical)"), Choice("AstronomicalDusk", "Dusk (astronomical)"),
        Choice("GoldenHourMorningEnd", "Morning golden hour ends"),
        Choice("GoldenHourEveningStart", "Evening golden hour starts"),
        Choice("DayLength", "Length of the day"), Choice("DaylightProgress", "How far the day has gone"),
        Choice("SunElevation", "Sun height (degrees)"), Choice("SunAzimuth", "Sun direction (degrees)"),
        Choice("IsDaylight", "Day or night"), Choice("SunState", "Midnight sun or polar night"),
        Choice("MoonPhase", "Moon phase"), Choice("MoonIllumination", "Moon lit (%)"),
        Choice("MoonPhaseName", "Moon phase name"), Choice("MoonSymbol", "Moon icon (SF Symbol)"),
        Choice("Place", "Place"), Choice("TimeZone", "Time zone"),
        Choice("LocationSource", "Where the place comes from"),
    ]

    static let sunTimeTypes = ["Sunrise", "Sunset", "SolarNoon", "CivilDawn", "CivilDusk", "NauticalDawn", "NauticalDusk",
                               "AstronomicalDawn", "AstronomicalDusk", "GoldenHourMorningEnd", "GoldenHourEveningStart"]

    // MARK: Settings

    static let weatherLocationHelp = "A town (Oslo, or Springfield, IL), latitude,longitude, auto for this Mac's "
        + "approximate location, or timezone for the city of this Mac's time zone. Places are looked up on this Mac; "
        + "only the rounded coordinates go to MET Norway."

    static let weatherTimeZoneHelp = "Place (default), Local (this Mac's), a name such as Europe/Oslo, or hours from UTC"

    /// `DaylightSavingTime` of both plugins: off, so hours from UTC are just that.
    static let weatherDaylightSaving = Property("DaylightSavingTime", "Daylight saving",
                                                flag("Add this Mac's daylight saving time to the hours"), default: "0",
                                                help: "Only for hours from UTC, as the Time measure does it",
                                                visibleWhen: [.isSet("TimeZone"), .notEquals("TimeZone", "Place", "Local")])

    static let weatherSettings: [Property] = {
        let own: [Condition] = [.isNotSet("Parent")]
        return [
            Property("Location", "Place", .text, placeholder: "City, Country — or 59.91, 10.75 — or auto",
                     help: weatherLocationHelp, visibleWhen: own, level: .essential),
            Property("Parent", "Same place as", .sectionRef(.measure), placeholder: "none (this one has the place)",
                     help: "Another weather item whose place, units and settings this one uses"),
            Property("Type", "Shows", pick(weatherTypes, style: .popup), default: "Temperature",
                     invalidNote: "Temperature is shown", level: .essential),
            Property("Hour", "Hours from now", num(0, 47, step: 1, unit: "hours"), placeholder: "now",
                     help: "0–47: the forecast for that hour", visibleWhen: [Condition("Type", .equals(weatherHourlyTypes))],
                     level: .essential),
            Property("Day", "Days from today", num(0, 9, step: 1, unit: "days"), placeholder: "today",
                     help: "0 today, 1 tomorrow… up to 9", visibleWhen: [Condition("Type", .equals(weatherDailyTypes))],
                     level: .essential),
            Property("Units", "Units", pick([Choice("Auto", "As on this Mac"), Choice("Metric", "°C, km/h, mm"),
                                             Choice("Imperial", "°F, mph, in")]),
                     default: "Auto", visibleWhen: own, level: .essential),
            Property("TemperatureUnit", "Temperature in", pick([Choice("C", "°C"), Choice("F", "°F")]),
                     placeholder: "from Units"),
            Property("WindUnit", "Wind in", pick([Choice("kmh", "km/h"), Choice("ms", "m/s"), Choice("mph", "mph"),
                                                  Choice("kn", "knots"), Choice("bft", "Beaufort")], style: .popup),
                     placeholder: "from Units"),
            Property("PrecipitationUnit", "Rain in", pick([Choice("mm", "mm"), Choice("in", "inches")]),
                     placeholder: "from Units"),
            Property("PressureUnit", "Pressure in", pick([Choice("hPa", "hPa"), Choice("inHg", "inHg"),
                                                          Choice("mmHg", "mmHg")]), placeholder: "from Units"),
            Property("Format", "Time format", .format(presets: timeFormats, preview: .time),
                     help: "%H hours, %M minutes, %a weekday…; the default follows this Mac's 12- or 24-hour clock",
                     visibleWhen: [Condition("Type", .equals(weatherTimeTypes))]),
            Property("TimeZone", "Time zone", .text, placeholder: "the place's", help: weatherTimeZoneHelp),
            weatherDaylightSaving,
            Property("FormatLocale", "Language", .text, placeholder: "English",
                     help: "Local, en-US, de-DE, zh-CN…: language of day and month names"),
            Property("Decimals", "Round to", num(0, 3, step: 1, unit: "decimals"), placeholder: "not rounded",
                     help: "Rounds the number itself (no “-0”)"),
            Property("UnavailableText", "Text when there is no data", .text, placeholder: "empty",
                     help: "Shown before the first forecast arrives, e.g. --"),
            Property("NoEventText", "Text when the sun doesn't rise or set", .text, default: "--:--",
                     help: "Midnight sun and polar night", visibleWhen: [.equals("Type", "Sunrise", "Sunset")]),
            Property("SymbolStyle", "Icon style", pick([Choice("Fill", "Filled"), Choice("Outline", "Outline")]),
                     default: "Fill", visibleWhen: [.equals("Type", "Symbol", "SymbolPalette")]),
            Property("PaletteInk", "Icon cloud color", .color,
                     default: MacWeatherMeasure.colorText(MacWeatherMeasure.defaultPaletteInk),
                     help: "Clouds, moons, snow and lightning in the icon colors; measures that follow this one use it too"),
            Property("PaletteSun", "Icon sun color", .color,
                     default: MacWeatherMeasure.colorText(MacWeatherMeasure.defaultPaletteSun),
                     help: "The sun in the icon colors"),
            Property("PaletteRain", "Icon rain color", .color,
                     default: MacWeatherMeasure.colorText(MacWeatherMeasure.defaultPaletteRain),
                     help: "Rain, drizzle and sleet in the icon colors"),
            Property("ScaleColor", "Temperature color instead", .color, placeholder: "the scale",
                     help: "Temperature color gives this color for every temperature"),
            Property("Hours", "Hours in the curve", num(2, 48, step: 1, unit: "hours"), default: "24",
                     visibleWhen: [.equals("Type", "TemperatureCurve")]),
            Property("CurveWidth", "Curve width", num(1, nil, step: 1, unit: "pt"), default: "200",
                     visibleWhen: [.equals("Type", "TemperatureCurve")]),
            Property("CurveHeight", "Curve height", num(1, nil, step: 1, unit: "pt"), default: "40",
                     visibleWhen: [.equals("Type", "TemperatureCurve")]),
            Property("Smooth", "Smooth", flag("Smooth curve"), default: "1",
                     visibleWhen: [.equals("Type", "TemperatureCurve")]),
            Property("ColorOf", "Color of", pick([Choice("High", "The high"), Choice("Low", "The low")]),
                     default: "High", visibleWhen: [.equals("Type", "TemperatureColor"), .isSet("Day")]),
        ]
    }()

    static let weatherEvents: [Property] = [
        Property("FinishAction", "When new data arrives", .action),
        Property("OnConnectErrorAction", "When it can't connect", .action),
        Property("OnLocationErrorAction", "When the place can't be found", .action),
    ]

    static let sunSettings: [Property] = {
        let own: [Condition] = [.isNotSet("Parent")]
        return [
            Property("Location", "Place", .text, placeholder: "City, Country — or 59.91, 10.75 — or auto",
                     help: "A town, latitude,longitude, auto, or timezone (the city of this Mac's time zone). Sun and "
                         + "moon are worked out on this Mac: nothing is sent anywhere.", visibleWhen: own, level: .essential),
            Property("Parent", "Same place as", .sectionRef(.measure), placeholder: "none (this one has the place)"),
            Property("Type", "Shows", pick(sunTypes, style: .popup), default: "Sunrise", invalidNote: "Sunrise is shown",
                     level: .essential),
            Property("Day", "Days from today", num(-1, 30, step: 1, unit: "days"), default: "0",
                     help: "-1 yesterday, 0 today, 1 tomorrow…", level: .essential),
            Property("Format", "Time format", .format(presets: timeFormats, preview: .time),
                     help: "The default follows this Mac's 12- or 24-hour clock",
                     visibleWhen: [Condition("Type", .equals(sunTimeTypes))], level: .essential),
            Property("TimeZone", "Time zone", .text, placeholder: "the place's", help: weatherTimeZoneHelp),
            weatherDaylightSaving,
            Property("FormatLocale", "Language", .text, placeholder: "English"),
            Property("NoEventText", "Text when the sun doesn't rise or set", .text, default: "--:--",
                     help: "Midnight sun and polar night"),
            Property("UnavailableText", "Text without a place", .text, placeholder: "empty"),
        ]
    }()

    // MARK: Names

    /// A MacWeather or MacSun measure in plain words: "Temperature (weather)", "Tomorrow's high", "High, in 3 days",
    /// "Temperature in 3 hours", "Sunrise", "Moon phase".
    static func weatherDataName(plugin: String, type rawType: String, hour: Int?, day: Int?) -> (name: String, short: String) {
        let sun = plugin == "macsun"
        let list = sun ? sunTypes : weatherTypes
        let key = rawType.trimmingCharacters(in: .whitespaces).lowercased()
        let choice = list.first { $0.value.lowercased() == key || $0.aliases.contains { $0.lowercased() == key } }
            ?? list[0]
        var title = choice.title
        if let paren = title.range(of: " (SF Symbol)") { title.removeSubrange(paren) }
        let lower = title.prefix(1).lowercased() + title.dropFirst()
        let short = sun ? "Sun" : "Weather"
        let daily = sun ? true : weatherDailyTypes.contains(choice.value)
        let hourly = !sun && weatherHourlyTypes.contains(choice.value)
        if let day, daily {
            switch day {
            case 0: return (sun ? title : "Today's \(lower)", short)
            case 1: return ("Tomorrow's \(lower)", short)
            case -1: return ("Yesterday's \(lower)", short)
            default: return ("\(title), in \(day) days", short)
            }
        }
        if let hour, hourly, hour > 0 {
            return ("\(title) in \(hour) hour\(hour == 1 ? "" : "s")", short)
        }
        if !sun, ["High", "Low"].contains(choice.value) { return ("Today's \(lower)", short) }
        return (sun ? title : "\(title) (weather)", short)
    }
}
