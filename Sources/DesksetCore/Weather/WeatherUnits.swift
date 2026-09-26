import Foundation

// Units, conversions and small derived quantities of the weather plugins (docs/compat/weather.md).

public enum TemperatureUnit: String, CaseIterable, Equatable {
    case celsius = "C", fahrenheit = "F"

    public var symbol: String { self == .celsius ? "°C" : "°F" }

    public func convert(celsius c: Double) -> Double { self == .celsius ? c : c * 9 / 5 + 32 }
}

public enum WindUnit: String, CaseIterable, Equatable {
    case kmh, ms, mph, kn, bft

    public var symbol: String {
        switch self {
        case .kmh: return "km/h"
        case .ms: return "m/s"
        case .mph: return "mph"
        case .kn: return "kn"
        case .bft: return "Bft"
        }
    }

    public func convert(metersPerSecond v: Double) -> Double {
        switch self {
        case .kmh: return v * 3.6
        case .ms: return v
        case .mph: return v / 0.44704
        case .kn: return v * 3600 / 1852
        case .bft: return Double(WeatherUnits.beaufort(metersPerSecond: v))
        }
    }
}

public enum PrecipitationUnit: String, CaseIterable, Equatable {
    case mm, inch = "in"

    public var symbol: String { self == .mm ? "mm" : "in" }

    public func convert(millimeters v: Double) -> Double { self == .mm ? v : v / 25.4 }
}

public enum PressureUnit: String, CaseIterable, Equatable {
    case hPa, inHg, mmHg

    public var symbol: String { rawValue }

    public func convert(hectopascals v: Double) -> Double {
        switch self {
        case .hPa: return v
        case .inHg: return v / 33.8638866667
        case .mmHg: return v / 1.33322387415
        }
    }
}

/// The units a measure shows its values in.
public struct WeatherUnits: Equatable {
    public var temperature: TemperatureUnit
    public var wind: WindUnit
    public var precipitation: PrecipitationUnit
    public var pressure: PressureUnit

    public init(temperature: TemperatureUnit, wind: WindUnit, precipitation: PrecipitationUnit,
                pressure: PressureUnit) {
        self.temperature = temperature
        self.wind = wind
        self.precipitation = precipitation
        self.pressure = pressure
    }

    /// °C, km/h, mm, hPa.
    public static let metric = WeatherUnits(temperature: .celsius, wind: .kmh, precipitation: .mm, pressure: .hPa)
    /// °F, mph, in, inHg.
    public static let imperial = WeatherUnits(temperature: .fahrenheit, wind: .mph, precipitation: .inch, pressure: .inHg)

    /// `Units=Auto`: what macOS is set to. `temperatureSetting` is the Temperature setting ("Celsius" /
    /// "Fahrenheit", nil when not set); `measurementSystem` the region's system ("metric", "U.S.", "U.K.").
    /// Wind is mph for the U.S. and the U.K., else km/h; precipitation inches and pressure inHg for the U.S. only.
    public static func automatic(temperatureSetting: String?, measurementSystem: String) -> WeatherUnits {
        let system = measurementSystem.lowercased().replacingOccurrences(of: ".", with: "")
        let us = system == "us" || system == "ussystem"
        let uk = system == "uk" || system == "uksystem"
        var units = us ? WeatherUnits.imperial : WeatherUnits.metric
        if uk { units.wind = .mph }
        switch temperatureSetting?.lowercased() {
        case "celsius"?, "c"?: units.temperature = .celsius
        case "fahrenheit"?, "f"?: units.temperature = .fahrenheit
        default: break
        }
        return units
    }

    // MARK: Beaufort, compass points

    /// Upper bounds (m/s) of Beaufort 0…11; anything above is 12.
    public static let beaufortBounds: [Double] = [0.5, 1.6, 3.4, 5.5, 8.0, 10.8, 13.9, 17.2, 20.8, 24.5, 28.5, 32.7]
    public static let beaufortNames = ["Calm", "Light air", "Light breeze", "Gentle breeze", "Moderate breeze",
                                       "Fresh breeze", "Strong breeze", "Near gale", "Gale", "Strong gale", "Storm",
                                       "Violent storm", "Hurricane force"]

    public static func beaufort(metersPerSecond v: Double) -> Int {
        guard v.isFinite else { return 0 }
        for (force, bound) in beaufortBounds.enumerated() where v < bound { return force }
        return 12
    }

    public static let cardinalPoints = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW",
                                        "W", "WNW", "NW", "NNW"]

    /// The 16-point compass name of a direction the wind comes from.
    public static func cardinal(degrees: Double) -> String {
        guard degrees.isFinite else { return "" }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return cardinalPoints[Int((d / 22.5).rounded()) % 16]
    }

    // MARK: Feels like

    /// MET's apparent temperature when it sends one; otherwise the heat index (NWS Rothfusz regression) above 26 °C
    /// with more than 40 % humidity, the wind chill (2001 North American formula) below 10 °C with wind above
    /// 1.33 m/s, else the temperature itself. °C in, °C out.
    public static func feelsLike(temperature t: Double, humidity: Double?, windSpeed: Double?,
                                 apparent: Double? = nil) -> Double {
        if let apparent, apparent.isFinite { return apparent }
        if t > 26, let rh = humidity, rh > 40 { return heatIndex(celsius: t, humidity: rh) }
        if t < 10, let v = windSpeed, v > 1.33 { return windChill(celsius: t, metersPerSecond: v) }
        return t
    }

    /// NWS heat index (°C in and out).
    public static func heatIndex(celsius: Double, humidity rh: Double) -> Double {
        let t = celsius * 9 / 5 + 32
        var hi = 0.5 * (t + 61 + (t - 68) * 1.2 + rh * 0.094)
        if (hi + t) / 2 >= 80 {
            hi = -42.379 + 2.04901523 * t + 10.14333127 * rh - 0.22475541 * t * rh - 0.00683783 * t * t
                - 0.05481717 * rh * rh + 0.00122874 * t * t * rh + 0.00085282 * t * rh * rh
                - 0.00000199 * t * t * rh * rh
            if rh < 13, t > 80, t < 112 {
                hi -= (13 - rh) / 4 * ((17 - abs(t - 95)) / 17).squareRoot()
            } else if rh > 85, t > 80, t < 87 {
                hi += (rh - 85) / 10 * ((87 - t) / 5)
            }
        }
        return (hi - 32) * 5 / 9
    }

    /// Wind chill (°C, wind in m/s).
    public static func windChill(celsius t: Double, metersPerSecond v: Double) -> Double {
        let kmh = pow(v * 3.6, 0.16)
        return 13.12 + 0.6215 * t - 11.37 * kmh + 0.3965 * t * kmh
    }

    // MARK: Temperature colour

    /// Original palette: °C stops, interpolated linearly in sRGB, clamped at both ends.
    public static let colorStops: [(celsius: Double, r: Double, g: Double, b: Double)] = [
        (-20, 120, 110, 255), (-5, 90, 160, 255), (5, 90, 210, 230), (15, 120, 220, 140), (22, 250, 210, 90),
        (30, 255, 150, 70), (38, 240, 80, 80),
    ]

    public static func color(celsius: Double) -> (r: Int, g: Int, b: Int) {
        let stops = colorStops
        guard celsius.isFinite else { return (Int(stops[3].r), Int(stops[3].g), Int(stops[3].b)) }
        if celsius <= stops[0].celsius { return (Int(stops[0].r), Int(stops[0].g), Int(stops[0].b)) }
        for i in 1..<stops.count where celsius <= stops[i].celsius {
            let a = stops[i - 1], b = stops[i]
            let f = (celsius - a.celsius) / (b.celsius - a.celsius)
            func mix(_ x: Double, _ y: Double) -> Int { Int((x + (y - x) * f).rounded()) }
            return (mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
        }
        let last = stops[stops.count - 1]
        return (Int(last.r), Int(last.g), Int(last.b))
    }

    // MARK: Rounding

    /// `Decimals=N`: half away from zero, and never "-0".
    public static func round(_ v: Double, decimals: Int) -> Double {
        guard v.isFinite else { return 0 }
        let n = min(max(decimals, 0), 6)
        let f = pow(10, Double(n))
        let r = (abs(v) * f).rounded(.toNearestOrAwayFromZero) / f
        let signed = v < 0 ? -r : r
        return signed == 0 ? 0 : signed
    }
}
