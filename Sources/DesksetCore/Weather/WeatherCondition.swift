import Foundation

// MET Norway's weather symbol codes (`symbol_code`: `<base>[_day|_night|_polartwilight]`), with their legacy numbers,
// short English descriptions and the SF Symbols Deskset shows for them. MET picks day or night itself, so icons need
// no sunrise data. Every symbol name here exists on macOS 13 (`sun.horizon`, `sun.rain` and `sun.snow` are macOS 14
// and are not used). SF Symbols are drawn by macOS; Deskset ships no weather icons.

/// One of MET's 41 base conditions.
public struct WeatherCondition: Equatable {
    /// The base code (`partlycloudy`), official spelling.
    public let code: String
    /// MET's legacy numeric ID (stable; skins use it in IfCondition).
    public let number: Int
    public let description: String
    public let daySymbol: String
    public let nightSymbol: String
    /// Whether the code comes with `_day` / `_night` / `_polartwilight` (clear sky, fair, partly cloudy, showers).
    public let hasVariants: Bool

    /// Every base condition, in MET's legacy number order within its family.
    public static let all: [WeatherCondition] = {
        func c(_ number: Int, _ code: String, _ description: String, _ day: String, _ night: String? = nil,
               variants: Bool = false) -> WeatherCondition {
            WeatherCondition(code: code, number: number, description: description, daySymbol: day,
                             nightSymbol: night ?? day, hasVariants: variants)
        }
        return [
            c(1, "clearsky", "Clear", "sun.max.fill", "moon.stars.fill", variants: true),
            c(2, "fair", "Mostly clear", "sun.max.fill", "moon.stars.fill", variants: true),
            c(3, "partlycloudy", "Partly cloudy", "cloud.sun.fill", "cloud.moon.fill", variants: true),
            c(4, "cloudy", "Cloudy", "cloud.fill"),
            c(15, "fog", "Fog", "cloud.fog.fill"),
            c(40, "lightrainshowers", "Light rain showers", "cloud.sun.rain.fill", "cloud.moon.rain.fill", variants: true),
            c(5, "rainshowers", "Rain showers", "cloud.sun.rain.fill", "cloud.moon.rain.fill", variants: true),
            c(41, "heavyrainshowers", "Heavy rain showers", "cloud.heavyrain.fill", variants: true),
            c(24, "lightrainshowersandthunder", "Light showers, thunder", "cloud.sun.bolt.fill", "cloud.moon.bolt.fill",
              variants: true),
            c(6, "rainshowersandthunder", "Showers, thunder", "cloud.sun.bolt.fill", "cloud.moon.bolt.fill",
              variants: true),
            c(25, "heavyrainshowersandthunder", "Heavy showers, thunder", "cloud.bolt.rain.fill", variants: true),
            c(42, "lightsleetshowers", "Light sleet showers", "cloud.sleet.fill", variants: true),
            c(7, "sleetshowers", "Sleet showers", "cloud.sleet.fill", variants: true),
            c(43, "heavysleetshowers", "Heavy sleet showers", "cloud.sleet.fill", variants: true),
            c(26, "lightssleetshowersandthunder", "Light sleet showers, thunder", "cloud.bolt.fill", variants: true),
            c(20, "sleetshowersandthunder", "Sleet showers, thunder", "cloud.bolt.fill", variants: true),
            c(27, "heavysleetshowersandthunder", "Heavy sleet showers, thunder", "cloud.bolt.fill", variants: true),
            c(44, "lightsnowshowers", "Light snow showers", "cloud.snow.fill", variants: true),
            c(8, "snowshowers", "Snow showers", "cloud.snow.fill", variants: true),
            c(45, "heavysnowshowers", "Heavy snow showers", "cloud.snow.fill", variants: true),
            c(28, "lightssnowshowersandthunder", "Light snow showers, thunder", "cloud.bolt.fill", variants: true),
            c(21, "snowshowersandthunder", "Snow showers, thunder", "cloud.bolt.fill", variants: true),
            c(29, "heavysnowshowersandthunder", "Heavy snow showers, thunder", "cloud.bolt.fill", variants: true),
            c(46, "lightrain", "Light rain", "cloud.drizzle.fill"),
            c(9, "rain", "Rain", "cloud.rain.fill"),
            c(10, "heavyrain", "Heavy rain", "cloud.heavyrain.fill"),
            c(30, "lightrainandthunder", "Light rain, thunder", "cloud.bolt.rain.fill"),
            c(22, "rainandthunder", "Rain, thunder", "cloud.bolt.rain.fill"),
            c(11, "heavyrainandthunder", "Heavy rain, thunder", "cloud.bolt.rain.fill"),
            c(47, "lightsleet", "Light sleet", "cloud.sleet.fill"),
            c(12, "sleet", "Sleet", "cloud.sleet.fill"),
            c(48, "heavysleet", "Heavy sleet", "cloud.sleet.fill"),
            c(31, "lightsleetandthunder", "Light sleet, thunder", "cloud.bolt.fill"),
            c(23, "sleetandthunder", "Sleet, thunder", "cloud.bolt.fill"),
            c(32, "heavysleetandthunder", "Heavy sleet, thunder", "cloud.bolt.fill"),
            c(49, "lightsnow", "Light snow", "cloud.snow.fill"),
            c(13, "snow", "Snow", "cloud.snow.fill"),
            c(50, "heavysnow", "Heavy snow", "cloud.snow.fill"),
            c(33, "lightsnowandthunder", "Light snow, thunder", "cloud.bolt.fill"),
            c(14, "snowandthunder", "Snow, thunder", "cloud.bolt.fill"),
            c(34, "heavysnowandthunder", "Heavy snow, thunder", "cloud.bolt.fill"),
        ]
    }()

    /// MET's own misspellings are the official codes; the correct spellings are read as the same conditions.
    static let aliases = ["lightsleetshowersandthunder": "lightssleetshowersandthunder",
                          "lightsnowshowersandthunder": "lightssnowshowersandthunder"]

    private static let byCode: [String: WeatherCondition] = {
        var map: [String: WeatherCondition] = [:]
        for c in all { map[c.code] = c }
        for (alias, code) in aliases { map[alias] = map[code] }
        return map
    }()

    public static func named(_ code: String) -> WeatherCondition? { byCode[code.lowercased()] }

    /// Every code MET can send: the 21 bases with variants in their three forms, plus the 20 without (83 in all).
    public static var allSymbolCodes: [String] {
        all.flatMap { c in c.hasVariants ? ["\(c.code)_day", "\(c.code)_night", "\(c.code)_polartwilight"] : [c.code] }
    }
}

/// Day, night or polar twilight (MET decides; `_polartwilight` uses the day symbol).
public enum WeatherVariant: String, Equatable {
    case day, night, polarTwilight = "polartwilight", none
}

/// A parsed `symbol_code`.
public struct WeatherSymbol: Equatable {
    /// nil for a code Deskset does not know.
    public var condition: WeatherCondition?
    public var variant: WeatherVariant
    /// As sent.
    public var raw: String

    public init(condition: WeatherCondition?, variant: WeatherVariant, raw: String) {
        self.condition = condition
        self.variant = variant
        self.raw = raw
    }

    public static func parse(_ raw: String) -> WeatherSymbol {
        let code = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for variant in [WeatherVariant.day, .night, .polarTwilight] {
            let suffix = "_" + variant.rawValue
            if code.hasSuffix(suffix) {
                let base = String(code.dropLast(suffix.count))
                return WeatherSymbol(condition: WeatherCondition.named(base), variant: variant, raw: raw)
            }
        }
        return WeatherSymbol(condition: WeatherCondition.named(code), variant: .none, raw: raw)
    }

    /// The same condition shown as by day (daily summaries are always shown with the day symbol).
    public var asDay: WeatherSymbol {
        guard condition?.hasVariants == true else { return self }
        var s = self
        s.variant = .day
        if let c = condition { s.raw = c.code + "_day" }
        return s
    }

    /// MET's legacy number (0 = unknown).
    public var number: Int { condition?.number ?? 0 }

    public var description: String { condition?.description ?? "Unknown" }

    /// SF Symbol; `outline` drops `.fill`. Unknown codes show `cloud.fill`.
    public func sfSymbol(outline: Bool = false) -> String {
        let name: String
        if let c = condition {
            name = variant == .night ? c.nightSymbol : c.daySymbol
        } else {
            name = "cloud.fill"
        }
        return outline && name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
    }

    /// 1 day, 0 night, 2 polar twilight; nil for codes without a variant.
    public var daylightFlag: Int? {
        switch variant {
        case .day: return 1
        case .night: return 0
        case .polarTwilight: return 2
        case .none: return nil
        }
    }
}

/// What a layer of a weather symbol shows, for palette drawing (MacWeather `Type=SymbolPalette`).
public enum WeatherSymbolRole: Equatable {
    /// The cloud, and what macOS draws in its layer or plain white under Multicolor: moons, stars, fog, snow, bolts.
    case ink
    case sun
    /// Rain, drizzle and sleet drops.
    case rain
}

/// SF Symbols for states and the moon.
public enum WeatherSymbols {
    /// The role of each hierarchical layer (primary, secondary, tertiary) of a weather symbol MacWeather names, filled
    /// or outline: measured by drawing each symbol with a palette of three distinct colors. A name not in the table is
    /// one layer of ink.
    public static func paletteRoles(_ name: String) -> [WeatherSymbolRole] {
        let base = name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
        return paletteRoleTable[base] ?? [.ink]
    }

    private static let paletteRoleTable: [String: [WeatherSymbolRole]] = [
        "sun.max": [.sun],
        "moon.stars": [.ink, .ink],
        "cloud.sun": [.ink, .sun],
        "cloud.moon": [.ink, .ink],
        "cloud": [.ink],
        "cloud.fog": [.ink, .ink],
        "cloud.sun.rain": [.ink, .sun, .rain],
        "cloud.moon.rain": [.ink, .ink, .rain],
        "cloud.heavyrain": [.ink, .rain],
        // the bolt is in the cloud's layer
        "cloud.sun.bolt": [.ink, .sun],
        "cloud.moon.bolt": [.ink, .ink],
        "cloud.bolt.rain": [.ink, .rain],
        // flakes in the cloud's layer, drops in the second
        "cloud.sleet": [.ink, .rain],
        "cloud.bolt": [.ink, .ink],
        "cloud.snow": [.ink, .ink],
        "cloud.drizzle": [.ink, .rain],
        "cloud.rain": [.ink, .rain],
    ]

    /// `Type=StatusSymbol` (empty when ready).
    public static func status(_ status: WeatherStatus) -> String {
        switch status {
        case .ready: return ""
        case .loading: return "hourglass"
        case .stale, .offline: return "wifi.slash"
        case .noLocation: return "location"
        case .locationDenied, .locationUnavailable: return "location.slash"
        default: return "exclamationmark.triangle"
        }
    }

    /// Moon symbols by phase eighth (0 new … 7 waning crescent).
    public static let moon = ["moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter",
                              "moonphase.waxing.gibbous", "moonphase.full.moon", "moonphase.waning.gibbous",
                              "moonphase.last.quarter", "moonphase.waning.crescent"]
}

/// `Type=Status` of a MacWeather measure: the most important state wins; with data on screen, failures show as
/// Stale.
public enum WeatherStatus: Int, CaseIterable, Equatable {
    case ready = 0
    case loading = 1
    case stale = 2
    case noLocation = 3
    case placeNotFound = 4
    case locationDenied = 5
    case locationUnavailable = 6
    case notCovered = 7
    case refused = 8
    case rateLimited = 9
    case offline = 10
    case turnedOff = 11
    case preview = 12
    case tooManyPlaces = 13

    public var name: String {
        switch self {
        case .ready: return "Ready"
        case .loading: return "Loading"
        case .stale: return "Stale"
        case .noLocation: return "NoLocation"
        case .placeNotFound: return "PlaceNotFound"
        case .locationDenied: return "LocationDenied"
        case .locationUnavailable: return "LocationUnavailable"
        case .notCovered: return "NotCovered"
        case .refused: return "Refused"
        case .rateLimited: return "RateLimited"
        case .offline: return "Offline"
        case .turnedOff: return "TurnedOff"
        case .preview: return "Preview"
        case .tooManyPlaces: return "TooManyPlaces"
        }
    }

    /// Whether weather values are shown (Ready, Stale).
    public var showsData: Bool { self == .ready || self == .stale }

    /// A place is known, so sun values work (every state but no location, place not found, location refused or
    /// no fix).
    public var hasCoordinate: Bool {
        ![.noLocation, .placeNotFound, .locationDenied, .locationUnavailable].contains(self)
    }

    public var isLocationError: Bool { [.placeNotFound, .locationDenied, .locationUnavailable].contains(self) }
}
