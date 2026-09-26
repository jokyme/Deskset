import Foundation

/// A coordinate rounded to two decimals (about 1 km): the only precision Deskset ever sends or keeps. Stored in
/// hundredths of a degree, so equal coordinates are equal exactly (`Location=Oslo` and `Location=59.91,10.75` share a
/// feed). Latitude is clamped to −90…90, longitude wrapped into −180…<180.
public struct RoundedCoordinate: Hashable, CustomStringConvertible {
    public let latitudeHundredths: Int
    public let longitudeHundredths: Int

    public init(latitude: Double, longitude: Double) {
        let lat = latitude.isFinite ? min(max(latitude, -90), 90) : 0
        var lon = longitude.isFinite ? longitude.truncatingRemainder(dividingBy: 360) : 0
        if lon < -180 { lon += 360 }
        if lon >= 180 { lon -= 360 }
        latitudeHundredths = Int((lat * 100).rounded(.toNearestOrAwayFromZero))
        var l = Int((lon * 100).rounded(.toNearestOrAwayFromZero))
        if l >= 18_000 { l -= 36_000 }
        longitudeHundredths = l
    }

    public var latitude: Double { Double(latitudeHundredths) / 100 }
    public var longitude: Double { Double(longitudeHundredths) / 100 }

    /// Exactly two decimals with a `.`, never `-0.00` (not localized).
    public var latitudeText: String { RoundedCoordinate.text(latitudeHundredths) }
    public var longitudeText: String { RoundedCoordinate.text(longitudeHundredths) }

    static func text(_ hundredths: Int) -> String {
        let sign = hundredths < 0 ? "-" : ""
        let a = abs(hundredths)
        let frac = a % 100
        return "\(sign)\(a / 100).\(frac < 10 ? "0" : "")\(frac)"
    }

    /// `59.91, 10.75`.
    public var description: String { "\(latitudeText), \(longitudeText)" }

    /// Disk cache key: `59.91_10.75`.
    public var key: String { "\(latitudeText)_\(longitudeText)" }

    /// Great-circle distance in kilometres.
    public func distance(toLatitude lat: Double, longitude lon: Double) -> Double {
        RoundedCoordinate.distance(latitude, longitude, lat, lon)
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLat = (lat2 - lat1) * r, dLon = (lon2 - lon1) * r
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * r) * cos(lat2 * r) * sin(dLon / 2) * sin(dLon / 2)
        return 6371.0088 * 2 * atan2(a.squareRoot(), max(0, 1 - a).squareRoot())
    }
}

/// What a `Location=` option asks for.
public enum WeatherLocationSpec: Equatable {
    /// Empty: nothing is requested.
    case none
    /// `auto` / `current` / `here`: this Mac's location (Location Services).
    case device
    case coordinate(RoundedCoordinate)
    /// A place name: `Name`, `Name, Country`, `Name, Region`, `Name, Region, Country`.
    case place(String)
    /// Coordinates that cannot be used (out of range, comma decimals); the text says why.
    case invalid(String)

    /// Parses the option (trimmed, surrounding quotes removed).
    public static func parse(_ raw: String) -> WeatherLocationSpec {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.count >= 2, (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty { return .none }
        switch text.lowercased() {
        case "auto", "current", "here": return .device
        default: break
        }
        if let coordinate = coordinates(text) { return coordinate }
        return .place(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
    }

    /// `lat,lon` in its accepted forms, or nil when the text is not a coordinate pair (a place name).
    private static func coordinates(_ text: String) -> WeatherLocationSpec? {
        let allowed = Set("0123456789.,;+- \tNSEWnsew°")
        guard text.allSatisfy({ allowed.contains($0) }), text.contains(where: { $0.isNumber }) else { return nil }
        // Tokens: numbers with an optional hemisphere letter (attached or on its own).
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        for ch in text {
            switch ch {
            case ",", ";", " ", "\t": flush()
            case "°": continue
            default:
                if "NSEWnsew".contains(ch) {
                    if current.isEmpty, let last = tokens.popLast() { current = last }
                    current.append(ch)
                    flush()
                } else {
                    current.append(ch)
                }
            }
        }
        flush()
        // Comma decimals (`59,91, 10,75`): four whole numbers separated by commas.
        let commaParts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if commaParts.count == 4, commaParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "-" } }) {
            return .invalid("Use a point for decimals: latitude,longitude such as 59.91,10.75")
        }
        guard tokens.count == 2 else { return nil }
        var values: [(value: Double, axis: Character?)] = []
        for token in tokens {
            var t = token
            var axis: Character?
            var sign = 1.0
            if let last = t.last, "NSEWnsew".contains(last) {
                let upper = Character(last.uppercased())
                axis = upper == "N" || upper == "S" ? "A" : "O"
                if upper == "S" || upper == "W" { sign = -1 }
                t.removeLast()
            }
            guard let v = Double(t), v.isFinite else { return nil }
            values.append((v * sign, axis))
        }
        var lat = values[0].value, lon = values[1].value
        // Hemisphere letters may put longitude first (`10.75E 59.91N`).
        if values[0].axis == "O" || values[1].axis == "A" { swap(&lat, &lon) }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else {
            return .invalid("Latitude must be between -90 and 90 and longitude between -180 and 180")
        }
        return .coordinate(RoundedCoordinate(latitude: lat, longitude: lon))
    }
}
