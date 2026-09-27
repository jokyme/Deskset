import AppKit
import CoreLocation
import DesksetCore

/// `Deskset --weather-report [--location PLACE|LAT,LON|timezone] [--units auto|metric|imperial] [--offline FILE [--now ISO]]`:
/// one forecast from MET Norway, as the weather skins would get it, printed with the request and the response headers
/// (docs/compat/app.md, "Command-line flags"). One real request with the real User-Agent; nothing read from or
/// written to the weather cache. The default place is the sample "Oslo, NO"; this Mac's location is never used
/// (`timezone`, the city of this Mac's time zone, comes from the place table).
/// `--offline FILE` reads a saved `complete` response instead (no network), at `--now` (default: the real time).
enum WeatherReportCommand {
    static let defaultLocation = "Oslo, NO"

    static func run(_ arguments: [String]) -> Int32 {
        Log.fileLoggingEnabled = false
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count,
                  !arguments[i + 1].hasPrefix("--") else { return nil }
            return arguments[i + 1]
        }
        func fail(_ message: String, status: Int32 = 2) -> Int32 {
            fputs("Deskset --weather-report: \(message)\n", stderr)
            return status
        }
        let location = value("--location") ?? defaultLocation
        var units = WeatherWiring.systemUnits()
        switch value("--units")?.lowercased() {
        case nil, "auto"?: break
        case "metric"?: units = .metric
        case "imperial"?: units = .imperial
        case let other?: return fail("--units \(other): use auto, metric or imperial")
        }
        var now = Date()
        if let text = value("--now") {
            guard let date = METNorway.parseISO8601(text) else { return fail("--now \(text): use 2026-09-26T12:00:00Z") }
            now = date
        }

        let directory = Paths.placesTable.flatMap { PlaceDirectory(url: $0) }
        let place: (coordinate: RoundedCoordinate, name: String, zone: TimeZone)
        switch WeatherLocationSpec.parse(location) {
        case .none:
            return fail("--location needs a place or latitude,longitude")
        case .device:
            return fail("--weather-report never reads this Mac's location; give a place or latitude,longitude")
        case .invalid(let why):
            return fail(why)
        case .coordinate(let c):
            let near = directory?.nearest(to: c, within: 50)
            let zone = (near ?? directory?.nearest(to: c, within: 200)).flatMap { TimeZone(identifier: $0.timeZone) }
            place = (c, near.map { directory?.detail(for: $0) ?? $0.name } ?? c.description, zone ?? .current)
        case .place(let query):
            guard let directory else { return fail("the place table is missing; use latitude,longitude", status: 1) }
            guard let m = directory.search(query) else { return fail("can't find “\(query)” in the place table", status: 1) }
            place = (m.place.coordinate, m.detail, TimeZone(identifier: m.place.timeZone) ?? .current)
        case .timeZone:
            // The city of this Mac's time zone, from the place table (never Location Services).
            guard let directory else { return fail("the place table is missing; use latitude,longitude", status: 1) }
            let zone = TimeZone.current
            guard let m = directory.place(forTimeZone: zone.identifier) else {
                return fail("no city is known for this Mac's time zone (\(zone.identifier))", status: 1)
            }
            place = (m.place.coordinate, m.detail, zone)
        }

        if let path = value("--offline") {
            guard let data = FileManager.default.contents(atPath: path) else { return fail("cannot read \(path)", status: 1) }
            do {
                let forecast = try METNorway.parse(data)
                print("Offline: \(path) (no request)")
                print(WeatherReport.forecastLines(forecast, place: place.name, coordinate: place.coordinate,
                                                  zone: place.zone, units: units, now: now).joined(separator: "\n"))
                return 0
            } catch {
                return fail("\(path) is not a MET Norway forecast", status: 1)
            }
        }

        let request = METNorway.request(for: place.coordinate, userAgent: WeatherWiring.userAgent, lastModified: nil)
        print("Request:    GET \(request.url.absoluteString)")
        print("User-Agent: \(request.headers["User-Agent"] ?? "")")
        let transport = URLSessionWeatherTransport()
        let box = Guarded<Result<WeatherHTTPResponse, WeatherTransportError>?>(nil)
        transport.get(request) { result in box.access { $0 = result } }
        let deadline = Date().addingTimeInterval(75)
        while box.current == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        switch box.current {
        case nil:
            print("No answer within 75 s")
            return 1
        case .failure(let error)?:
            print("Failed:     \(error)")
            return 1
        case .success(let r)?:
            print("Status:     \(r.status)")
            for header in ["Date", "Expires", "Last-Modified", "Content-Type"] {
                if let v = r.header(header) { print("\(header + ":")\(String(repeating: " ", count: max(1, 12 - header.count - 1)))\(v)") }
            }
            guard r.status == 200 || r.status == 203, let forecast = try? METNorway.parse(r.body) else { return 1 }
            if r.status == 203 { print("Note:       MET Norway reports this product as deprecated or beta (203)") }
            print(WeatherReport.forecastLines(forecast, place: place.name, coordinate: place.coordinate,
                                              zone: place.zone, units: units, now: now).joined(separator: "\n"))
            return 0
        }
    }
}

extension SystemReport {
    /// The Weather section: shown when weather is set up here — an active skin writes a place in a MacWeather or
    /// MacSun measure, or Location Services are already allowed for Deskset. Offline: no request, no location read,
    /// and nothing that could make macOS ask for permission (only the permission's status is looked at).
    static func weatherLines(stateFile: URL = Paths.state, skinsDirectory: URL = Paths.skins,
                             authorization: CLAuthorizationStatus = CLLocationManager().authorizationStatus,
                             placesTable: URL? = Paths.placesTable, now: Date = Date()) -> [String] {
        var places: [WeatherReport.SkinLocation] = []
        if let raw = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(AppStateData.self, from: raw) {
            for (config, s) in state.skins.sorted(by: { $0.key < $1.key }) where s.active && !s.file.isEmpty {
                let folder = config.replacingOccurrences(of: "\\", with: "/")
                let file = skinsDirectory.appendingPathComponent(folder).appendingPathComponent(s.file)
                places += WeatherReport.locations(inSkin: file, config: config, skinsDirectory: skinsDirectory)
            }
        }
        let permission: String
        switch authorization {
        case .notDetermined: permission = "not asked yet"
        case .denied: permission = "denied"
        case .restricted: permission = "restricted"
        default: permission = "allowed"
        }
        let allowed = authorization != .notDetermined && authorization != .denied && authorization != .restricted
        guard !places.isEmpty || allowed else {
            return ["Weather: not set up (no active skin sets a weather location; Location Services: \(permission))"]
        }
        let directory = placesTable.flatMap { PlaceDirectory(url: $0) }
        let units = WeatherWiring.systemUnits()
        var lines = ["Weather"]
        lines.append("  Enabled:            \(WeatherWiring.isEnabled ? "yes" : "no")   (defaults \(WeatherWiring.enabledKey))")
        lines.append("  Provider:           MET Norway locationforecast/2.0/complete, HTTPS")
        lines.append("  User-Agent:         \(WeatherWiring.userAgent)")
        lines.append("  Units (Auto):       \(units.temperature.symbol), \(units.wind.symbol), "
                     + "\(units.precipitation.symbol), \(units.pressure.symbol)")
        if let directory {
            let downloaded = directory.meta["downloaded"].map { ", GeoNames \($0)" } ?? ""
            lines.append("  Places table:       \(directory.count) places\(downloaded)")
        } else {
            lines.append("  Places table:       missing (place names cannot be looked up)")
        }
        var cacheEnvironment = WeatherEnvironment()
        cacheEnvironment.cacheDirectory = MediaUICache.folder("Weather")
        let cache = WeatherService(environment: cacheEnvironment).diskCacheSummary()
        let age = cache.newest.map { ", newest \(max(0, Int(now.timeIntervalSince($0) / 60))) min old" } ?? ""
        lines.append("  Disk cache:         \(cache.places) place\(cache.places == 1 ? "" : "s")\(age)")
        lines.append("  Location Services:  \(permission)   (status only; this report never reads the location)")
        for p in places {
            lines.append("  \(p.skin) [\(p.section)] \(p.plugin): Location=\(p.location)")
            lines.append("    → " + WeatherReport.describe(p.location, directory: directory))
            if case .place(let query) = WeatherLocationSpec.parse(p.location), let m = directory?.search(query),
               let zone = TimeZone(identifier: m.place.timeZone) {
                lines.append("    → " + WeatherReport.sunLine(latitude: m.place.coordinate.latitude,
                                                              longitude: m.place.coordinate.longitude, zone: zone, now: now))
            } else if case .timeZone = WeatherLocationSpec.parse(p.location),
                      let m = directory?.place(forTimeZone: TimeZone.current.identifier) {
                lines.append("    → " + WeatherReport.sunLine(latitude: m.place.coordinate.latitude,
                                                              longitude: m.place.coordinate.longitude, zone: .current,
                                                              now: now))
            } else if case .coordinate(let c) = WeatherLocationSpec.parse(p.location) {
                let zone = directory?.nearest(to: c, within: 200).flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
                lines.append("    → " + WeatherReport.sunLine(latitude: c.latitude, longitude: c.longitude, zone: zone,
                                                              now: now))
            }
        }
        return lines
    }
}
