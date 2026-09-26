import Foundation

/// A synthetic forecast for skins that are not live when `DESKSET_WEATHER_DEMO=1` (screenshots, demo videos) and for
/// the editor's thumbnails. Deterministic for a given clock; never from the network.
public enum WeatherDemo {
    /// Sample place of the demo (Oslo).
    public static let coordinate = RoundedCoordinate(latitude: 59.91, longitude: 10.75)
    public static let placeName = "Oslo"
    public static let placeDetail = "Oslo, Oslo, Norway"
    public static let timeZone = TimeZone(identifier: "Europe/Oslo") ?? .current

    /// Conditions of the demo days (6-hour periods cycle through the day's list).
    private static let dayConditions: [[String]] = [
        ["partlycloudy", "fair", "partlycloudy", "cloudy"],
        ["lightrainshowers", "rain", "lightrain", "cloudy"],
        ["cloudy", "partlycloudy", "fair", "clearsky"],
        ["clearsky", "clearsky", "fair", "partlycloudy"],
        ["rainshowersandthunder", "heavyrainshowers", "rainshowers", "cloudy"],
        ["fair", "partlycloudy", "partlycloudy", "fair"],
        ["cloudy", "lightrain", "rain", "lightrain"],
        ["partlycloudy", "fair", "clearsky", "clearsky"],
        ["fair", "cloudy", "lightsnow", "cloudy"],
        ["clearsky", "fair", "partlycloudy", "partlycloudy"],
    ]
    private static let dayOffsets: [Double] = [0, -1.5, 0.5, 2.5, -3, 1, -2, 3, -6, 0]
    private static let dayRain: [Double] = [5, 70, 20, 0, 85, 10, 60, 5, 40, 0]

    public static func forecast(now: Date) -> WeatherForecast {
        let hourStart = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        var steps: [WeatherStep] = []
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        let today = c.startOfDay(for: now)
        func dayIndex(_ t: Date) -> Int {
            min(max(c.dateComponents([.day], from: today, to: c.startOfDay(for: t)).day ?? 0, 0), 9)
        }
        func temperature(_ t: Date) -> Double {
            let hour = Double(c.component(.hour, from: t)) + Double(c.component(.minute, from: t)) / 60
            let base = 12 + dayOffsets[dayIndex(t)]
            return ((base + 5 * sin(2 * .pi * (hour - 9) / 24)) * 10).rounded() / 10
        }
        func symbol(_ t: Date, hours: Int) -> WeatherSymbol {
            let day = dayIndex(t)
            let hour = c.component(.hour, from: t)
            let code = dayConditions[day][min(hour / 6, 3)]
            let base = WeatherCondition.named(code)
            let sun = SolarCalculator.position(at: t.addingTimeInterval(TimeInterval(hours) * 1800),
                                               latitude: coordinate.latitude, longitude: coordinate.longitude)
            let variant: WeatherVariant = base?.hasVariants == true ? (sun.elevation > -0.833 ? .day : .night) : .none
            let raw = variant == .none ? code : "\(code)_\(variant.rawValue)"
            return WeatherSymbol(condition: base, variant: variant, raw: raw)
        }
        func period(_ t: Date, hours: Int) -> WeatherPeriod {
            var p = WeatherPeriod(hours: hours)
            p.symbol = symbol(t, hours: hours)
            let chance = dayRain[dayIndex(t)]
            p.precipitationChance = chance
            p.precipitation = chance >= 50 ? Double(hours) * chance / 200 : 0
            p.thunderChance = hours == 1 ? (p.symbol?.raw.contains("thunder") == true ? 30 : 0.5) : nil
            if hours == 6 {
                let temps = (0..<6).map { temperature(t.addingTimeInterval(TimeInterval($0) * 3600)) }
                p.temperatureMax = temps.max()
                p.temperatureMin = temps.min()
            }
            return p
        }
        for i in 0..<56 {
            let t = hourStart.addingTimeInterval(TimeInterval(i) * 3600)
            var instant = WeatherInstant()
            instant.temperature = temperature(t)
            instant.apparentTemperature = (instant.temperature ?? 0) - 1
            instant.humidity = 62 + 10 * cos(Double(i) / 4)
            instant.dewPoint = (instant.temperature ?? 0) - 6
            instant.pressure = 1014 + Double(i % 7) / 2
            instant.cloudCover = 35 + 25 * sin(Double(i) / 5)
            instant.windSpeed = 3.4 + 1.5 * sin(Double(i) / 3)
            instant.windGust = (instant.windSpeed ?? 0) * 1.9
            instant.windDirection = Double((230 + i * 7) % 360)
            instant.uvIndex = max(0, 3 * sin(2 * .pi * (Double(c.component(.hour, from: t)) - 7) / 24))
            instant.fog = 0
            steps.append(WeatherStep(time: t, instant: instant, next1h: i < 55 ? period(t, hours: 1) : nil,
                                     next6h: period(t, hours: 6), next12h: nil))
        }
        var t = hourStart.addingTimeInterval(56 * 3600)
        while Int(t.timeIntervalSince1970) % (6 * 3600) != 0 { t.addTimeInterval(3600) }
        while t < now.addingTimeInterval(9.5 * 86_400) {
            var instant = WeatherInstant()
            instant.temperature = temperature(t)
            instant.humidity = 70
            instant.windSpeed = 3
            instant.windDirection = 250
            instant.pressure = 1012
            steps.append(WeatherStep(time: t, instant: instant, next6h: period(t, hours: 6)))
            t.addTimeInterval(6 * 3600)
        }
        return WeatherForecast(updatedAt: hourStart.addingTimeInterval(-1800), latitude: coordinate.latitude,
                               longitude: coordinate.longitude, elevation: 12, steps: steps)
    }

    public static func snapshot(now: Date) -> WeatherSnapshot {
        WeatherSnapshot(forecast: forecast(now: now), fetchedAt: now.addingTimeInterval(-12 * 60),
                        validatedAt: now.addingTimeInterval(-12 * 60), expiresLocal: now.addingTimeInterval(20 * 60),
                        version: 1)
    }
}
