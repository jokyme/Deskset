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
    /// Folded name → row indices (by population, largest first). Names in Traditional Chinese are also indexed in
    /// Simplified Chinese (`simplifiedChinese`), so either spelling finds a town the table lists in one of them.
    private var index: [String: [Int]] = [:]
    private var foldedCountries: [String: String] = [:]
    /// Time zone → the row of its largest town.
    private var zoneLeaders: [String: Int] = [:]

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
            for k in keys {
                if let simplified = PlaceDirectory.simplifiedChinese(k) { keys.insert(simplified) }
            }
            for k in keys where !k.isEmpty { index[k, default: []].append(i) }
            if zoneLeaders[p.timeZone] == nil, !p.timeZone.isEmpty { zoneLeaders[p.timeZone] = i }
        }
        for (code, name) in countries { foldedCountries[PlaceDirectory.fold(name)] = code }
    }

    public var count: Int { places.count }

    /// Case, diacritics and width folded, whitespace collapsed.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `s` in Simplified Chinese when it has Traditional characters (臺北 → 台北, 紐約 → 纽约), else nil. GeoNames lists
    /// many towns under only one of the two spellings.
    static func simplifiedChinese(_ s: String) -> String? {
        guard s.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }),
              let simplified = s.applyingTransform(StringTransform("Hant-Hans"), reverse: false), simplified != s
        else { return nil }
        return simplified
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
    /// matches (3 characters or more, 2 for CJK). CJK queries are tried again without a trailing 市 / 县 / 縣 / 區 / 区,
    /// and Traditional Chinese ones in Simplified Chinese.
    public func search(_ query: String) -> PlaceMatch? {
        let parts = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        let name = String(first)
        let qualifiers = Array(parts.dropFirst().suffix(2))
        var candidates = [name]
        if let simplified = PlaceDirectory.simplifiedChinese(name) { candidates.append(simplified) }
        for candidate in candidates where PlaceDirectory.isCJK(candidate) {
            if let last = candidate.last, "市县縣區区".contains(last), candidate.count > 1 {
                candidates.append(String(candidate.dropLast()))
            }
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

    // MARK: Time zones

    /// The town of a time zone (`Location=timezone`: the city of this Mac's time zone), from the zone's name and the
    /// table:
    /// 1. the town the zone is named after, in that zone (Asia/Shanghai → Shanghai, America/New_York → New York City,
    ///    America/Argentina/Buenos_Aires → Buenos Aires);
    /// 2. else the zone's largest town (zones named after a small town or an island: Europe/Isle_of_Man → Douglas);
    /// 3. else, for an older name of a zone that the table lists under its new name (Asia/Calcutta, Europe/Kiev,
    ///    Asia/Saigon), the town of that name whose own zone keeps the same time in January and July.
    /// nil for zones without a place (UTC, GMT, Etc/GMT-8, Factory) and zones whose towns are all smaller than the
    /// table's (a few in Antarctica, Alaska and the Pacific).
    public func place(forTimeZone identifier: String, near date: Date = Date()) -> PlaceMatch? {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count >= 2, let city = parts.last, parts[0].lowercased() != "etc" else { return nil }
        let named = index[PlaceDirectory.fold(city.replacingOccurrences(of: "_", with: " "))] ?? []
        if let row = named.first(where: { places[$0].timeZone == id }) ?? zoneLeaders[id] {
            return match(places[row], typed: nil)
        }
        guard let zone = TimeZone(identifier: id) else { return nil }
        let row = named.first { row in
            TimeZone(identifier: places[row].timeZone).map { PlaceDirectory.keepsSameTime(zone, $0, near: date) } ?? false
        }
        return row.map { match(places[$0], typed: nil) }
    }

    /// Whether two zones are the same distance from UTC in the middle of January and of July of `date`'s year.
    static func keepsSameTime(_ a: TimeZone, _ b: TimeZone, near date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? a
        let year = calendar.component(.year, from: date)
        return [1, 7].allSatisfy { month in
            guard let d = calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12)) else { return false }
            return a.secondsFromGMT(for: d) == b.secondsFromGMT(for: d)
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
