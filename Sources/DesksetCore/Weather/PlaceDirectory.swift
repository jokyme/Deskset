import Foundation

/// One row of the place table.
public struct WeatherPlace: Equatable {
    public var name: String
    public var asciiName: String
    public var alternates: [String]
    public var latitude: Double
    public var longitude: Double
    /// ISO 3166 code (`NO`).
    public var country: String
    /// GeoNames admin1 code (`12`; US states are their abbreviations: `IL`).
    public var admin1: String
    public var population: Int
    /// IANA time zone.
    public var timeZone: String

    public init(name: String, asciiName: String, alternates: [String] = [], latitude: Double, longitude: Double,
                country: String, admin1: String, population: Int, timeZone: String) {
        self.name = name
        self.asciiName = asciiName
        self.alternates = alternates
        self.latitude = latitude
        self.longitude = longitude
        self.country = country
        self.admin1 = admin1
        self.population = population
        self.timeZone = timeZone
    }

    public var coordinate: RoundedCoordinate { RoundedCoordinate(latitude: latitude, longitude: longitude) }
}

/// A place a query found, with the name to show.
public struct PlaceMatch: Equatable {
    public var place: WeatherPlace
    /// What the user typed when an alternate name matched ("北京"), else the table's name.
    public var displayName: String
    /// "Springfield, Illinois, United States".
    public var detail: String
    public var countryName: String
}

/// The offline place table (GeoNames `cities15000`, trimmed; CC BY 4.0), bundled as `places.tsv`:
/// `name⇥asciiname⇥alternates(,)⇥lat⇥lon⇥country⇥admin1⇥population⇥timezone` rows sorted by population, plus
/// `#country⇥CC⇥English name`, `#admin1⇥CC.code⇥name` and `#meta⇥key⇥value` rows. No online geocoder is used.
public final class PlaceDirectory {
    public private(set) var places: [WeatherPlace] = []
    public private(set) var countries: [String: String] = [:]
    public private(set) var regions: [String: String] = [:]
    public private(set) var meta: [String: String] = [:]
    /// Folded name → row indices (by population, largest first).
    private var index: [String: [Int]] = [:]
    private var foldedCountries: [String: String] = [:]

    /// Loads a table; nil when the file is missing or has no place rows.
    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        self.init(text: text)
        if places.isEmpty { return nil }
    }

    public init(text: String) {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if let first = fields.first, first.hasPrefix("#") {
                guard fields.count >= 3 else { continue }
                switch first {
                case "#country": countries[fields[1].uppercased()] = fields[2]
                case "#admin1": regions[fields[1].uppercased()] = fields[2]
                case "#meta": meta[fields[1]] = fields[2]
                default: break
                }
                continue
            }
            guard fields.count >= 9, let lat = Double(fields[3]), let lon = Double(fields[4]) else { continue }
            let alternates = fields[2].isEmpty ? [] : fields[2].split(separator: ",").map(String.init)
            places.append(WeatherPlace(name: fields[0], asciiName: fields[1], alternates: alternates, latitude: lat,
                                       longitude: lon, country: fields[5].uppercased(), admin1: fields[6],
                                       population: Int(fields[7]) ?? 0, timeZone: fields[8]))
        }
        // Largest first, whatever the file's order.
        places.sort { $0.population > $1.population }
        for (i, p) in places.enumerated() {
            var keys = Set([PlaceDirectory.fold(p.name), PlaceDirectory.fold(p.asciiName)])
            for a in p.alternates { keys.insert(PlaceDirectory.fold(a)) }
            for k in keys where !k.isEmpty { index[k, default: []].append(i) }
        }
        for (code, name) in countries { foldedCountries[PlaceDirectory.fold(name)] = code }
    }

    public var count: Int { places.count }

    /// Case, diacritics and width folded, whitespace collapsed.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func isCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
            || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    public func countryName(_ code: String) -> String { countries[code.uppercased()] ?? code.uppercased() }

    public func regionName(country: String, admin1: String) -> String? {
        regions["\(country.uppercased()).\(admin1.uppercased())"]
    }

    /// "Springfield, Illinois, United States" (name, region, country; "Oslo, Oslo, Norway").
    public func detail(for place: WeatherPlace, name: String? = nil) -> String {
        let shown = name ?? place.name
        var parts = [shown]
        if let region = regionName(country: place.country, admin1: place.admin1), !region.isEmpty {
            parts.append(region)
        }
        parts.append(countryName(place.country))
        return parts.joined(separator: ", ")
    }

    // MARK: Search

    /// Finds a place: exact name matches first (name, ASCII name or an alternate), filtered by up to two qualifiers
    /// after commas (a country code or English name, a region code or name), the largest place winning; then prefix
    /// matches (3 characters or more, 2 for CJK). CJK queries are tried again without a trailing 市 / 县 / 縣 / 區 / 区.
    public func search(_ query: String) -> PlaceMatch? {
        let parts = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        let name = String(first)
        let qualifiers = Array(parts.dropFirst().suffix(2))
        var candidates = [name]
        if PlaceDirectory.isCJK(name), let last = name.last, "市县縣區区".contains(last), name.count > 1 {
            candidates.append(String(name.dropLast()))
        }
        for candidate in candidates {
            let key = PlaceDirectory.fold(candidate)
            if let rows = index[key], let row = rows.first(where: { matches(places[$0], qualifiers) }) {
                return match(places[row], typed: candidate)
            }
        }
        for candidate in candidates {
            let key = PlaceDirectory.fold(candidate)
            let minimum = PlaceDirectory.isCJK(candidate) ? 2 : 3
            guard key.count >= minimum else { continue }
            var best: Int?
            for (k, rows) in index where k.hasPrefix(key) {
                for row in rows where matches(places[row], qualifiers) {
                    if best.map({ row < $0 }) ?? true { best = row }
                    break
                }
            }
            if let best { return match(places[best], typed: nil) }
        }
        return nil
    }

    private func match(_ place: WeatherPlace, typed: String?) -> PlaceMatch {
        var shown = place.name
        if let typed {
            let folded = PlaceDirectory.fold(typed)
            if folded != PlaceDirectory.fold(place.name) && folded != PlaceDirectory.fold(place.asciiName) {
                // An alternate matched: show the user's own spelling ("北京", "Pekin").
                shown = typed
            }
        }
        return PlaceMatch(place: place, displayName: shown, detail: detail(for: place, name: shown),
                          countryName: countryName(place.country))
    }

    private func matches(_ place: WeatherPlace, _ qualifiers: [String]) -> Bool {
        qualifiers.allSatisfy { q in
            let folded = PlaceDirectory.fold(q)
            if folded == PlaceDirectory.fold(place.country) { return true }
            if let code = foldedCountries[folded], code == place.country { return true }
            if folded == PlaceDirectory.fold(place.admin1) { return true }
            if let region = regionName(country: place.country, admin1: place.admin1),
               PlaceDirectory.fold(region) == folded { return true }
            return false
        }
    }

    /// The nearest place within `limit` kilometres (for coordinates and this Mac's location: offline, so nothing but
    /// MET ever sees them).
    public func nearest(to coordinate: RoundedCoordinate, within limit: Double) -> WeatherPlace? {
        var best: (distance: Double, place: WeatherPlace)?
        let lat = coordinate.latitude
        // A cheap box test before the great-circle distance (1° of latitude ≈ 111 km).
        let latBox = limit / 111 + 0.01
        for p in places where abs(p.latitude - lat) <= latBox {
            let d = coordinate.distance(toLatitude: p.latitude, longitude: p.longitude)
            if d <= limit, best.map({ d < $0.distance }) ?? true { best = (d, p) }
        }
        return best?.place
    }
}
