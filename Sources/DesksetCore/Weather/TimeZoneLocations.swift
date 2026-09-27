import Foundation

/// The place the time zone database gives each of its zones: `zone.tab`, one `country⇥coordinates⇥zone[⇥comment]` line
/// per zone, the coordinates in ISO 6709 (`+4742+00841`, `+375711-0864541`). macOS keeps it in `/usr/share/zoneinfo`.
/// `Location=timezone` uses it for zones whose name is no town in the place table (`PlaceDirectory.place(forTimeZone:)`):
/// America/Indiana/Knox is at 41.30, −86.63.
public struct TimeZoneLocations {
    public struct Entry: Equatable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// Zone name → its place.
    public private(set) var entries: [String: Entry] = [:]

    /// Reads `zone.tab` text; lines that are comments or cannot be read are skipped.
    public init(text: String) {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let spot = TimeZoneLocations.coordinate(String(fields[1])) else { continue }
            let zone = fields[2].trimmingCharacters(in: .whitespaces)
            guard !zone.isEmpty else { continue }
            entries[zone] = Entry(latitude: spot.latitude, longitude: spot.longitude)
        }
    }

    /// nil when the file is missing or lists no zone.
    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        self.init(text: text)
        if entries.isEmpty { return nil }
    }

    /// macOS's own table.
    public static let systemURL = URL(fileURLWithPath: "/usr/share/zoneinfo/zone.tab")

    /// macOS's table, read the first time a zone needs it (empty when the file is missing).
    public static let system = TimeZoneLocations(url: systemURL) ?? TimeZoneLocations(text: "")

    /// An ISO 6709 point as `zone.tab` writes it: `±DDMM±DDDMM` or `±DDMMSS±DDDMMSS`; nil for anything else.
    static func coordinate(_ text: String) -> (latitude: Double, longitude: Double)? {
        let chars = Array(text.trimmingCharacters(in: .whitespaces))
        guard let split = chars.indices.dropFirst().first(where: { chars[$0] == "+" || chars[$0] == "-" }) else {
            return nil
        }
        func angle(_ part: ArraySlice<Character>, degreeDigits: Int, limit: Double) -> Double? {
            guard let sign = part.first, sign == "+" || sign == "-" else { return nil }
            let digits = part.dropFirst()
            guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let text = String(digits)
            let secondsText = digits.count == degreeDigits + 4 ? String(text.suffix(2)) : "0"
            guard let degrees = Double(text.prefix(degreeDigits)),
                  let minutes = Double(text.dropFirst(degreeDigits).prefix(2)),
                  let seconds = Double(secondsText),
                  minutes < 60, seconds < 60 else { return nil }
            let value = degrees + minutes / 60 + seconds / 3600
            guard value <= limit else { return nil }
            return sign == "-" ? -value : value
        }
        guard let latitude = angle(chars[..<split], degreeDigits: 2, limit: 90),
              let longitude = angle(chars[split...], degreeDigits: 3, limit: 180) else { return nil }
        return (latitude, longitude)
    }

    /// The zone's place under its own name; for another name of a listed zone (America/Godthab is America/Nuuk,
    /// Europe/Kiev is Europe/Kyiv, US/Pacific is America/Los_Angeles), the one listed zone with the same rules — the
    /// same time zone data — and its place. nil when the zone is unknown, has no place (Etc/…, UTC) or shares its rules
    /// with several listed zones.
    public func location(of identifier: String) -> (zone: String, entry: Entry)? {
        if let entry = entries[identifier] { return (identifier, entry) }
        guard let data = TimeZoneLocations.rules(identifier) else { return nil }
        var found: (zone: String, entry: Entry)?
        for (zone, entry) in entries where TimeZoneLocations.rules(zone) == data {
            if found != nil { return nil }
            found = (zone, entry)
        }
        return found
    }

    /// A zone's rules as macOS stores them (its TZif data); nil when macOS does not know the zone.
    static func rules(_ identifier: String) -> Data? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        let data = (zone as NSTimeZone).data
        return data.isEmpty ? nil : data
    }
}
