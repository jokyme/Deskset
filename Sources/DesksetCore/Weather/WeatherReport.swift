import Foundation

// Text for `Deskset --weather-report` and the Weather section of `Deskset --system-report` (docs/compat/app.md,
// "Command-line flags"). Pure functions of their inputs: no network, no device location.

public enum WeatherReport {
    /// A place written in a skin: where the MacWeather or MacSun measure with that `Location=` is.
    public struct SkinLocation: Equatable {
        public var skin: String
        public var section: String
        /// `MacWeather` or `MacSun`.
        public var plugin: String
        /// As resolved from the skin's variables (`#Location#` → `Oslo, NO`).
        public var location: String
    }

    /// The `Location=` of every MacWeather / MacSun measure without a `Parent` in a skin file (its @Include files and
    /// variables resolved as when the skin loads), without loading the skin: no measure is made and no script runs.
    public static func locations(inSkin fileURL: URL, config: String, skinsDirectory: URL) -> [SkinLocation] {
        let skin = Skin(config: config, fileURL: fileURL, skinsDirectory: skinsDirectory, system: NullSystemData(),
                        host: nil)
        let builtins = skin.builtInVariables()
        guard let loaded = try? SkinFileLoader.load(url: fileURL, expandVariables: { raw, readSoFar in
            let table = builtins.merging(readSoFar) { _, new in new }
            return VariableResolver(variableLookup: { table[$0.lowercased()] }).resolve(raw)
        }) else { return [] }
        let document = loaded.document
        let variables = VariableResolver.resolveDefinitions(document.section(named: "Variables")?.entries ?? [],
                                                            builtins: builtins)
        let resolver = VariableResolver(variableLookup: { variables[$0.lowercased()] ?? builtins[$0.lowercased()] })
        var result: [SkinLocation] = []
        for section in document.sections {
            guard section.value(forKey: "Measure")?.trimmingCharacters(in: .whitespaces).lowercased() == "plugin",
                  let raw = section.value(forKey: "Plugin") else { continue }
            let plugin: String
            switch MeasureRegistry.normalizedPluginName(resolver.resolve(raw)) {
            case "macweather": plugin = "MacWeather"
            case "macsun": plugin = "MacSun"
            default: continue
            }
            let parent = resolver.resolve(section.value(forKey: "Parent") ?? "").trimmingCharacters(in: .whitespaces)
            guard parent.isEmpty else { continue }
            let location = resolver.resolve(section.value(forKey: "Location") ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !location.isEmpty else { continue }
            result.append(SkinLocation(skin: config, section: section.name, plugin: plugin, location: location))
        }
        return result
    }

    /// How a `Location=` resolves offline, in one line: "Oslo, Oslo, Norway · 59.91, 10.75 · Europe/Oslo".
    /// `auto` is never read here: "this Mac's location (not read by this report)".
    public static func describe(_ location: String, directory: PlaceDirectory?) -> String {
        switch WeatherLocationSpec.parse(location) {
        case .none: return "no location"
        case .device: return "this Mac's location (not read by this report)"
        case .invalid(let why): return "not usable: \(why)"
        case .coordinate(let c):
            let near = directory?.nearest(to: c, within: 50)
            let zone = near?.timeZone ?? directory?.nearest(to: c, within: 200)?.timeZone
            return [near.map { "near \(directory?.detail(for: $0) ?? $0.name)" }, c.description, zone]
                .compactMap { $0 }.joined(separator: " · ")
        case .place(let query):
            guard let directory else { return "place search unavailable (no place table)" }
            guard let m = directory.search(query) else { return "not found in the place table" }
            return "\(m.detail) · \(m.place.coordinate.description) · \(m.place.timeZone)"
        }
    }

    /// Sunrise and sunset of the local day of `now` ("sunrise 07:10, sunset 19:04"; polar day and night in words).
    public static func sunLine(latitude: Double, longitude: Double, zone: TimeZone, now: Date) -> String {
        let day = SolarCalculator.day(containing: now, zone: zone, latitude: latitude, longitude: longitude)
        func t(_ r: SolarEventResult) -> String {
            switch r {
            case .time(let d): return TimeFormatting.format(d, format: "%H:%M", timeZone: zone)
            case .alwaysAbove: return "none (the sun stays up)"
            case .alwaysBelow: return "none (the sun stays down)"
            }
        }
        return "sunrise \(t(day.sunrise)), sunset \(t(day.sunset)), daylight "
            + SolarCalculator.durationText(day.length)
    }

    /// The forecast in plain text: now, the next `hours` hours, `days` days, the sun, the credit.
    public static func forecastLines(_ forecast: WeatherForecast, place: String, coordinate: RoundedCoordinate,
                                     zone: TimeZone, units u: WeatherUnits, now: Date, hours: Int = 6,
                                     days: Int = 7) -> [String] {
        func f(_ v: Double?, _ decimals: Int = 1) -> String {
            guard let v, v.isFinite else { return "–" }
            return String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), v)
        }
        func temp(_ c: Double?) -> String { "\(f(c.map { u.temperature.convert(celsius: $0) })) \(u.temperature.symbol)" }
        func wind(_ v: Double?) -> String { "\(f(v.map { u.wind.convert(metersPerSecond: $0) }, 0)) \(u.wind.symbol)" }
        func rain(_ mm: Double?) -> String {
            "\(f(mm.map { u.precipitation.convert(millimeters: $0) }, u.precipitation == .mm ? 1 : 2)) "
                + u.precipitation.symbol
        }
        func clock(_ d: Date, _ format: String = "%H:%M") -> String {
            TimeFormatting.format(d, format: format, timeZone: zone)
        }
        var lines: [String] = []
        lines.append("Place:      \(place) (\(coordinate.description)), \(zone.identifier)")
        if let updated = forecast.updatedAt {
            lines.append("Model run:  " + TimeFormatting.format(updated, format: "%Y-%m-%d %H:%M UTC",
                                                                timeZone: TimeZone(identifier: "UTC") ?? zone))
        }
        if let n = WeatherTimeline.nowIndex(forecast, now: now) {
            let s = forecast.steps[n]
            let i = s.instant
            let symbol = s.shortestPeriod?.symbol
            let feels = i.temperature.map {
                WeatherUnits.feelsLike(temperature: $0, humidity: i.humidity, windSpeed: i.windSpeed,
                                       apparent: i.apparentTemperature)
            }
            let from = i.windDirection.map { " from \(WeatherUnits.cardinal(degrees: $0))" } ?? ""
            lines.append("Now (\(clock(s.time))): \(temp(i.temperature)), feels like \(temp(feels)), "
                         + "\(symbol?.description ?? "–"), humidity \(f(i.humidity, 0)) %, wind \(wind(i.windSpeed))\(from), "
                         + "rain \(rain(s.shortestPeriod?.precipitation)) (\(f(s.shortestPeriod?.precipitationChance, 0)) %)")
        } else {
            lines.append("Now:        no data for this time")
        }
        if hours > 0 {
            lines.append("Next hours:")
            for h in 1...hours {
                guard let index = WeatherTimeline.hourIndex(forecast, now: now, hour: h) else { continue }
                let s = forecast.steps[index]
                lines.append("  \(clock(s.time))  \(temp(s.instant.temperature))  "
                             + "\(s.next1h?.symbol?.description ?? "–")  \(rain(s.next1h?.precipitation))")
            }
        }
        if days > 0 {
            lines.append("Days:")
            for (n, d) in WeatherTimeline.days(forecast, zone: zone, now: now).prefix(days).enumerated() where d.available {
                let chance = d.precipitationChance.map { "  \(f($0, 0)) %" } ?? ""
                lines.append("  \(n == 0 ? "Today     " : clock(d.start, "%a %d %b"))  "
                             + "\(f(d.high.map { u.temperature.convert(celsius: $0) })) / \(temp(d.low))  "
                             + "\(d.symbol?.description ?? "–")  \(rain(d.precipitation))\(chance)")
            }
        }
        lines.append("Sun today:  " + sunLine(latitude: coordinate.latitude, longitude: coordinate.longitude, zone: zone,
                                              now: now))
        lines.append("Source:     \(METNorway.attribution) (\(METNorway.attributionURL), CC BY 4.0 "
                     + "\(METNorway.licenseURL))")
        return lines
    }
}

/// System data for skins that are only read, never updated (`WeatherReport.locations`).
private final class NullSystemData: SystemDataSource {
    var processorCount: Int { 1 }
    func cpuUsage(processor: Int) -> Double { 0 }
    func memoryStatus() -> MemoryStatus { MemoryStatus() }
    func networkInterfaces() -> [String] { [] }
    func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
    func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
    func uptime() -> TimeInterval { 0 }
    func battery() -> BatteryStatus? { nil }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
    func cpuFrequency() -> Double? { nil }
    func desktopPicturePath() -> String? { nil }
}
