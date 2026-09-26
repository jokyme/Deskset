import Foundation

// MET Norway's Locationforecast 2.0, `complete` JSON (api.met.no, terms of service and data licence: CC BY 4.0 and
// NLOD 2.0). Only this endpoint is used — never `compact` (a different forecast run could be mixed in), never
// Sunrise 3.0 (sun and moon are computed on the Mac) and no geocoding service. See docs/compat/weather.md.

/// A GET request for the weather transport.
public struct WeatherHTTPRequest: Equatable {
    public var url: URL
    /// Header name → value, sent as given.
    public var headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

/// What the transport got back. Header names are lowercased.
public struct WeatherHTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum METNorway {
    /// The only endpoint used.
    public static let endpoint = URL(string: "https://api.met.no/weatherapi/locationforecast/2.0/complete")!

    /// How Deskset identifies itself (MET's terms require an application name and a way to contact the developer).
    /// Forks that redistribute the app must change both (CONTRIBUTING.md).
    public static let userAgentProduct = "Deskset"
    public static let userAgentContact = "https://github.com/jokyme/Deskset"

    /// `Deskset/<version> (+https://github.com/jokyme/Deskset)`; `dev` for builds without a bundle version.
    public static func userAgent(version: String?) -> String {
        let v = version?.trimmingCharacters(in: .whitespaces).filter { !$0.isWhitespace && $0 != "(" && $0 != ")" } ?? ""
        return "\(userAgentProduct)/\(v.isEmpty ? "dev" : v) (+\(userAgentContact))"
    }

    // MARK: Attribution (CC BY 4.0)

    public static let attribution = "Based on data from MET Norway"
    public static let attributionShort = "Data: MET Norway"
    public static let attributionURL = "https://api.met.no/"
    public static let licenseURL = "https://creativecommons.org/licenses/by/4.0/"

    // MARK: Requests

    /// `…/complete?lat=59.91&lon=10.75`: latitude first, exactly two decimals, no altitude.
    public static func url(endpoint: URL = endpoint, for coordinate: RoundedCoordinate) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "lat", value: coordinate.latitudeText),
                                  URLQueryItem(name: "lon", value: coordinate.longitudeText)]
        return components?.url ?? endpoint
    }

    /// The request for one feed: the User-Agent, `Accept: application/json`, and `If-Modified-Since` with the stored
    /// `Last-Modified` exactly as it was received.
    public static func request(endpoint: URL = endpoint, for coordinate: RoundedCoordinate, userAgent: String,
                               lastModified: String?) -> WeatherHTTPRequest {
        var headers = ["User-Agent": userAgent, "Accept": "application/json"]
        if let lastModified, !lastModified.isEmpty { headers["If-Modified-Since"] = lastModified }
        return WeatherHTTPRequest(url: url(endpoint: endpoint, for: coordinate), headers: headers)
    }

    // MARK: Parsing

    public enum ParseError: Error, Equatable {
        case notJSON
        case noTimeseries
    }

    /// Parses a `complete` (or `compact`) body. Unknown keys are ignored and every value is optional; a body without
    /// `properties.timeseries`, or without a single valid step, is an error.
    public static func parse(_ data: Data) throws -> WeatherForecast {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        let properties = root["properties"] as? [String: Any]
        guard let series = properties?["timeseries"] as? [Any] else { throw ParseError.noTimeseries }
        var steps: [WeatherStep] = []
        steps.reserveCapacity(series.count)
        for entry in series {
            guard let e = entry as? [String: Any], let timeText = e["time"] as? String,
                  let time = parseISO8601(timeText) else { continue }
            let data = e["data"] as? [String: Any] ?? [:]
            var step = WeatherStep(time: time)
            if let d = (data["instant"] as? [String: Any])?["details"] as? [String: Any] {
                var i = WeatherInstant()
                i.temperature = number(d["air_temperature"])
                i.apparentTemperature = number(d["apparent_air_temperature"])
                i.dewPoint = number(d["dew_point_temperature"])
                i.humidity = number(d["relative_humidity"])
                i.pressure = number(d["air_pressure_at_sea_level"])
                i.cloudCover = number(d["cloud_area_fraction"])
                i.cloudLow = number(d["cloud_area_fraction_low"])
                i.cloudMedium = number(d["cloud_area_fraction_medium"])
                i.cloudHigh = number(d["cloud_area_fraction_high"])
                i.fog = number(d["fog_area_fraction"])
                i.uvIndex = number(d["ultraviolet_index_clear_sky"])
                i.windSpeed = number(d["wind_speed"])
                i.windGust = number(d["wind_speed_of_gust"])
                i.windDirection = number(d["wind_from_direction"])
                i.temperatureP10 = number(d["air_temperature_percentile_10"])
                i.temperatureP90 = number(d["air_temperature_percentile_90"])
                step.instant = i
            }
            step.next1h = period(data["next_1_hours"], hours: 1)
            step.next6h = period(data["next_6_hours"], hours: 6)
            step.next12h = period(data["next_12_hours"], hours: 12)
            steps.append(step)
        }
        // Sorted by time; a repeated time keeps its first entry.
        steps = steps.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map(\.element)
        var unique: [WeatherStep] = []
        unique.reserveCapacity(steps.count)
        for s in steps where unique.last?.time != s.time { unique.append(s) }
        guard !unique.isEmpty else { throw ParseError.noTimeseries }

        var forecast = WeatherForecast(steps: unique)
        if let meta = properties?["meta"] as? [String: Any], let updated = meta["updated_at"] as? String {
            forecast.updatedAt = parseISO8601(updated)
        }
        if let geometry = root["geometry"] as? [String: Any], let c = geometry["coordinates"] as? [Any] {
            if c.count >= 2 {
                forecast.longitude = number(c[0])
                forecast.latitude = number(c[1])
            }
            if c.count >= 3 { forecast.elevation = number(c[2]) }
        }
        return forecast
    }

    private static func period(_ any: Any?, hours: Int) -> WeatherPeriod? {
        guard let p = any as? [String: Any] else { return nil }
        var period = WeatherPeriod(hours: hours)
        if let summary = p["summary"] as? [String: Any] {
            if let code = summary["symbol_code"] as? String { period.symbol = WeatherSymbol.parse(code) }
            period.symbolConfidence = summary["symbol_confidence"] as? String
        }
        if let d = p["details"] as? [String: Any] {
            period.precipitation = number(d["precipitation_amount"])
            period.precipitationMin = number(d["precipitation_amount_min"])
            period.precipitationMax = number(d["precipitation_amount_max"])
            period.precipitationChance = number(d["probability_of_precipitation"])
            period.thunderChance = number(d["probability_of_thunder"])
            period.temperatureMax = number(d["air_temperature_max"])
            period.temperatureMin = number(d["air_temperature_min"])
        }
        return period
    }

    /// A JSON number (never a string, a boolean or NaN).
    private static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    // MARK: Dates

    /// `2026-09-26T11:00:00Z` (also with fractional seconds or a `+hh:mm` offset).
    public static func parseISO8601(_ text: String) -> Date? {
        let u = Array(text.utf8)
        guard u.count >= 19, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54 || u[10] == 0x20, u[13] == 0x3A, u[16] == 0x3A
        else { return nil }
        func num(_ from: Int, _ count: Int) -> Int? {
            var v = 0
            for i in from..<(from + count) {
                guard u[i] >= 0x30, u[i] <= 0x39 else { return nil }
                v = v * 10 + Int(u[i] - 0x30)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
              let s = num(17, 2), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        var i = 19
        if i < u.count, u[i] == 0x2E {
            i += 1
            while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
        }
        var offset = 0
        if i < u.count {
            switch u[i] {
            case 0x5A, 0x7A: i += 1
            case 0x2B, 0x2D:
                guard u.count >= i + 6, u[i + 3] == 0x3A, let oh = num(i + 1, 2), let om = num(i + 4, 2) else { return nil }
                offset = (oh * 3600 + om * 60) * (u[i] == 0x2D ? -1 : 1)
                i += 6
            default: return nil
            }
        }
        guard i == u.count else { return nil }
        let days = CivilTime.daysFromCivil(y, mo, d)
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + h * 3600 + mi * 60 + s - offset))
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// An HTTP date (`Sat, 26 Sep 2026 11:59:31 GMT`; the obsolete RFC 850 and asctime forms too).
    public static func parseHTTPDate(_ text: String) -> Date? {
        var parts = text.replacingOccurrences(of: ",", with: " ").split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard parts.count >= 4 else { return nil }
        if parts[0].count >= 3, Int(parts[0]) == nil { parts.removeFirst() }   // weekday
        var day: Int?, month: Int?, year: Int?, clock: String?
        if parts.count >= 3, parts[0].contains("-") {
            // RFC 850: 26-Sep-26 11:59:31 GMT
            let d = parts[0].split(separator: "-").map(String.init)
            guard d.count == 3 else { return nil }
            day = Int(d[0])
            month = months.firstIndex(of: d[1].lowercased()).map { $0 + 1 }
            year = Int(d[2]).map { $0 < 100 ? ($0 < 70 ? 2000 + $0 : 1900 + $0) : $0 }
            clock = parts[1]
        } else if let d = Int(parts[0]) {
            // IMF-fixdate: 26 Sep 2026 11:59:31 GMT
            day = d
            month = months.firstIndex(of: parts[1].lowercased()).map { $0 + 1 }
            year = Int(parts[2])
            clock = parts.count > 3 ? parts[3] : nil
        } else {
            // asctime: Sep 26 11:59:31 2026
            month = months.firstIndex(of: parts[0].lowercased()).map { $0 + 1 }
            day = Int(parts[1])
            clock = parts[2]
            year = parts.count > 3 ? Int(parts[3]) : nil
        }
        guard let day, let month, let year, let clock, (1...31).contains(day) else { return nil }
        let t = clock.split(separator: ":").compactMap { Int($0) }
        guard t.count == 3, t[0] < 24, t[1] < 60, t[2] < 61 else { return nil }
        let days = CivilTime.daysFromCivil(year, month, day)
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + t[0] * 3600 + t[1] * 60 + t[2]))
    }
}
