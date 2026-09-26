import Foundation
@testable import DesksetCore

// Weather plugins (Plugin=MacWeather, Plugin=MacSun) and the weather service. No internet: MET Norway's responses come
// from fixtures (TestSkins/Plugins/@Resources/Weather), a fake transport or the loopback test server; the clock is
// virtual; reference values were computed independently (daily summaries by hand from the rules in
// docs/compat/weather.md, sun times with an ephemeris library).

func runWeatherTests(_ t: TestRunner) {
    runWeatherParseTests(t)
    runWeatherDerivedTests(t)
    runWeatherUnitTests(t)
    runWeatherLocationTests(t)
    runWeatherSunTests(t)
    runWeatherFetchTests(t)
    runWeatherTransportTests(t)
    runWeatherMeasureTests(t)
    runWeatherSymbolImageTests(t)
    runWeatherEditorTests(t)
}

// MARK: - Fixtures and helpers

enum WeatherFixtures {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let folder = repository.appendingPathComponent("TestSkins/Plugins/@Resources/Weather")
    static var complete: Data { (try? Data(contentsOf: folder.appendingPathComponent("metno-complete-oslo.json"))) ?? Data() }
    static var compact: Data { (try? Data(contentsOf: folder.appendingPathComponent("metno-compact-oslo.json"))) ?? Data() }
    static let placesFixture = folder.appendingPathComponent("places-fixture.tsv")
    static let bundledPlaces = repository.appendingPathComponent("Data/Places/places.tsv")
    /// When the complete fixture was fetched (its `Date` header).
    static let clock = date("2026-09-26T11:59:31Z")
    static let headers = ["Date": "Sat, 26 Sep 2026 11:59:31 GMT", "Last-Modified": "Sat, 26 Sep 2026 11:49:25 GMT",
                          "Expires": "Sat, 26 Sep 2026 12:20:14 GMT", "Content-Type": "application/json"]
    static let oslo = RoundedCoordinate(latitude: 59.91, longitude: 10.75)

    static func date(_ iso: String) -> Date { METNorway.parseISO8601(iso) ?? Date(timeIntervalSince1970: 0) }

    static func forecast() -> WeatherForecast? { try? METNorway.parse(complete) }

    static func zone(_ id: String) -> TimeZone { TimeZone(identifier: id) ?? TimeZone(secondsFromGMT: 0)! }
}

// MARK: - Parse and conditions

private func runWeatherParseTests(_ t: TestRunner) {
    t.suite("Weather: parse") {
        guard let f = WeatherFixtures.forecast() else {
            t.check(false, "the complete fixture parses")
            return
        }
        t.equal(f.steps.count, 86)
        t.equal(f.steps.first?.time, WeatherFixtures.date("2026-09-26T11:00:00Z"))
        t.equal(f.steps.filter { $0.next1h != nil }.count, 55)
        t.equal(f.updatedAt, WeatherFixtures.date("2026-09-26T11:32:00Z"))
        t.equal(f.latitude, 59.91)
        t.equal(f.longitude, 10.75)
        t.equal(f.elevation, 3)
        let first = f.steps[0]
        t.equal(first.instant.temperature, 16.3)
        t.equal(first.instant.apparentTemperature, 16.3)
        t.equal(first.instant.humidity, 54.2)
        t.equal(first.instant.windSpeed, 2.2)
        t.equal(first.instant.windGust, 5.0)
        t.equal(first.instant.windDirection, 276)
        t.equal(first.instant.uvIndex, 1.8)
        t.equal(first.instant.pressure, 1012.6)
        t.equal(first.next1h?.symbol?.raw, "fair_day")
        t.equal(first.next1h?.thunderChance, 0.1)
        t.equal(first.next6h?.temperatureMax, 17.9)
        t.equal(first.next12h?.symbolConfidence, "certain")
        t.check(zip(f.steps, f.steps.dropFirst()).allSatisfy { $0.time < $1.time }, "sorted")
        // compact: the same shape with fewer fields.
        let compact = try METNorway.parse(WeatherFixtures.compact)
        t.equal(compact.steps.count, 86)
        t.equal(compact.steps[0].instant.apparentTemperature, nil, "compact has no feels-like")
        t.equal(compact.steps[0].instant.uvIndex, nil)
        t.check(compact.steps[0].instant.temperature != nil)
        // Errors and robustness.
        t.throwsError { _ = try METNorway.parse(Data()) }
        t.throwsError { _ = try METNorway.parse(Data("[1,2]".utf8)) }
        t.throwsError { _ = try METNorway.parse(Data(#"{"properties":{}}"#.utf8)) }
        t.throwsError { _ = try METNorway.parse(Data(#"{"properties":{"timeseries":[{"time":"soon"}]}}"#.utf8)) }
        let odd = """
        {"extra":1,"properties":{"timeseries":[
          {"time":"2026-09-26T13:00:00Z","data":{"instant":{"details":{"air_temperature":"warm","wind_speed":true}}}},
          {"time":"2026-09-26T12:00:00Z","data":{"instant":{"details":{"air_temperature":12.5}},"next_1_hours":{"summary":{"symbol_code":"rain"}}}},
          {"time":"2026-09-26T12:00:00Z","data":{"instant":{"details":{"air_temperature":99}}}}
        ]}}
        """
        let o = try METNorway.parse(Data(odd.utf8))
        t.equal(o.steps.count, 2, "a repeated time keeps its first entry")
        t.equal(o.steps[0].instant.temperature, 12.5, "sorted by time")
        t.equal(o.steps[1].instant.temperature, nil, "a string is not a number")
        t.equal(o.steps[1].instant.windSpeed, nil, "nor is a boolean")
        // Dates.
        t.equal(METNorway.parseHTTPDate("Sat, 26 Sep 2026 11:59:31 GMT"), WeatherFixtures.clock)
        t.equal(METNorway.parseHTTPDate("Saturday, 26-Sep-26 11:59:31 GMT"), WeatherFixtures.clock)
        t.equal(METNorway.parseHTTPDate("Sat Sep 26 11:59:31 2026"), WeatherFixtures.clock)
        t.equal(METNorway.parseHTTPDate("yesterday"), nil)
        t.equal(METNorway.parseISO8601("2026-09-26T13:59:31+02:00"), WeatherFixtures.clock)
        t.equal(METNorway.parseISO8601("2026-09-26T11:59:31.250Z").map { Int($0.timeIntervalSince1970) },
                Int(WeatherFixtures.clock.timeIntervalSince1970))
        t.equal(METNorway.parseISO8601("2026-13-26T11:59:31Z"), nil)
    }

    t.suite("Weather: conditions") {
        let codes = WeatherCondition.allSymbolCodes
        t.equal(codes.count, 83)
        t.equal(WeatherCondition.all.count, 41)
        t.equal(Set(WeatherCondition.all.map(\.number)).count, 41, "legacy numbers are unique")
        t.equal(WeatherCondition.all.filter(\.hasVariants).count, 21)
        let macOS13 = macOS13WeatherSymbols
        for code in codes + ["lightsleetshowersandthunder_day", "lightsnowshowersandthunder_night"] {
            let s = WeatherSymbol.parse(code)
            t.check(s.condition != nil, "\(code) is known")
            t.check(s.number > 0 && s.number <= 50, "\(code) number")
            t.check(s.description != "Unknown", "\(code) description")
            t.check(macOS13.contains(s.sfSymbol()), "\(code): \(s.sfSymbol()) exists on macOS 13")
            t.check(macOS13.contains(s.sfSymbol(outline: true)), "\(code): outline \(s.sfSymbol(outline: true))")
        }
        t.equal(WeatherSymbol.parse("lightssleetshowersandthunder_day").number, 26)
        t.equal(WeatherSymbol.parse("lightsleetshowersandthunder_day").number, 26, "the correct spelling too")
        t.equal(WeatherSymbol.parse("partlycloudy_night").sfSymbol(), "cloud.moon.fill")
        t.equal(WeatherSymbol.parse("partlycloudy_night").sfSymbol(outline: true), "cloud.moon")
        t.equal(WeatherSymbol.parse("partlycloudy_polartwilight").sfSymbol(), "cloud.sun.fill", "polar twilight: day")
        t.equal(WeatherSymbol.parse("partlycloudy_polartwilight").daylightFlag, 2)
        t.equal(WeatherSymbol.parse("clearsky_night").daylightFlag, 0)
        t.equal(WeatherSymbol.parse("rain").daylightFlag, nil)
        t.equal(WeatherSymbol.parse("fair_day").description, "Mostly clear")
        t.equal(WeatherSymbol.parse("fair_day").number, 2)
        let unknown = WeatherSymbol.parse("volcanicash_day")
        t.equal(unknown.number, 0)
        t.equal(unknown.description, "Unknown")
        t.equal(unknown.sfSymbol(), "cloud.fill")
        t.equal(WeatherSymbol.parse("clearsky_night").asDay.raw, "clearsky_day")
        for status in WeatherStatus.allCases where status != .ready {
            t.check(macOS13.contains(WeatherSymbols.status(status)), "\(status) symbol")
        }
        for m in WeatherSymbols.moon { t.check(macOS13.contains(m), m) }
    }
}

/// SF Symbols the plugins use, all available on macOS 13 (checked against the system's symbol availability list).
let macOS13WeatherSymbols: Set<String> = [
    "sun.max.fill", "moon.stars.fill", "cloud.sun.fill", "cloud.moon.fill", "cloud.fill", "cloud.fog.fill",
    "cloud.sun.rain.fill", "cloud.moon.rain.fill", "cloud.heavyrain.fill", "cloud.sun.bolt.fill", "cloud.moon.bolt.fill",
    "cloud.bolt.rain.fill", "cloud.sleet.fill", "cloud.bolt.fill", "cloud.snow.fill", "cloud.drizzle.fill",
    "cloud.rain.fill", "sun.max", "moon.stars", "cloud.sun", "cloud.moon", "cloud", "cloud.fog", "cloud.sun.rain",
    "cloud.moon.rain", "cloud.heavyrain", "cloud.sun.bolt", "cloud.moon.bolt", "cloud.bolt.rain", "cloud.sleet",
    "cloud.bolt", "cloud.snow", "cloud.drizzle", "cloud.rain", "hourglass", "wifi.slash", "location", "location.slash",
    "exclamationmark.triangle", "moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter",
    "moonphase.waxing.gibbous", "moonphase.full.moon", "moonphase.waning.gibbous", "moonphase.last.quarter",
    "moonphase.waning.crescent",
]

// MARK: - Timeline and days

private func runWeatherDerivedTests(_ t: TestRunner) {
    t.suite("Weather: timeline") {
        guard let f = WeatherFixtures.forecast() else { return t.check(false, "fixture") }
        let now = WeatherFixtures.clock
        guard let n = WeatherTimeline.nowIndex(f, now: now) else { return t.check(false, "now") }
        let step = f.steps[n]
        t.equal(step.time, WeatherFixtures.date("2026-09-26T11:00:00Z"))
        t.equal(step.instant.temperature, 16.3)
        t.equal(step.next1h?.symbol?.raw, "fair_day")
        t.equal(step.next1h?.precipitation, 0)
        t.equal(step.next1h?.precipitationChance, 0)
        func hour(_ h: Int) -> WeatherStep? { WeatherTimeline.hourIndex(f, now: now, hour: h).map { f.steps[$0] } }
        t.equal(hour(0)?.time, step.time)
        t.equal(hour(1)?.instant.temperature, 16.8)
        t.equal(hour(1)?.next1h?.symbol?.raw, "fair_day")
        t.equal(hour(3)?.instant.temperature, 17.8)
        t.equal(hour(3)?.next1h?.symbol?.raw, "clearsky_day")
        t.equal(hour(6)?.instant.temperature, 17.0)
        t.equal(hour(6)?.next1h?.symbol?.raw, "clearsky_night")
        t.check(hour(47) != nil, "hour 47 is inside the hourly part")
        t.equal(hour(60)?.time, nil, "beyond the hourly part")
        t.equal(WeatherTimeline.hourIndex(f, now: now, hour: -1), nil)
        // Before the first step: within an hour → the first step; earlier → nothing.
        t.equal(WeatherTimeline.nowIndex(f, now: WeatherFixtures.date("2026-09-26T10:30:00Z")), 0)
        t.equal(WeatherTimeline.nowIndex(f, now: WeatherFixtures.date("2026-09-26T09:00:00Z")), nil)
        // In the six-hourly part: the latest step before now.
        let late = WeatherFixtures.date("2026-10-01T08:00:00Z")
        t.equal(WeatherTimeline.nowIndex(f, now: late).map { f.steps[$0].time },
                WeatherFixtures.date("2026-10-01T06:00:00Z"))
        t.equal(WeatherTimeline.nowIndex(f, now: late).map { f.steps[$0].next1h == nil }, true)
        // Past the last step: the last one (instant only).
        let last = WeatherTimeline.nowIndex(f, now: WeatherFixtures.date("2026-10-09T00:00:00Z"))
        t.equal(last, f.steps.count - 1)
        t.equal(f.steps.last?.shortestPeriod == nil, true)
        // Range for the automatic MaxValue: the now step and the next 23 hours.
        let r = WeatherTimeline.range(f, now: now) { $0.instant.temperature }
        t.check(r != nil && r!.min <= 16.3 && r!.max >= 17.8, "\(String(describing: r))")
    }

    t.suite("Weather: daily") {
        guard let f = WeatherFixtures.forecast() else { return t.check(false, "fixture") }
        let now = WeatherFixtures.clock
        func check(_ zone: String, _ day: Int, high: Double, low: Double, precipitation: Double, chance: Double,
                   symbol: String, covered: Double, line: UInt = #line) {
            let days = WeatherTimeline.days(f, zone: WeatherFixtures.zone(zone), now: now)
            guard day < days.count else { return t.check(false, "\(zone) day \(day)", line: line) }
            let d = days[day]
            t.close(d.high ?? .nan, high, accuracy: 0.001, "\(zone) \(day) high", line: line)
            t.close(d.low ?? .nan, low, accuracy: 0.001, "\(zone) \(day) low", line: line)
            t.close(d.precipitation ?? .nan, precipitation, accuracy: 0.051, "\(zone) \(day) precipitation", line: line)
            t.close(d.precipitationChance ?? .nan, chance, accuracy: 0.001, "\(zone) \(day) chance", line: line)
            t.equal(d.symbol?.raw, symbol, "\(zone) \(day) symbol", line: line)
            t.close(d.covered / 3600, covered, accuracy: 0.001, "\(zone) \(day) covered", line: line)
            t.check(d.available, "\(zone) \(day) available", line: line)
        }
        check("Europe/Oslo", 0, high: 17.9, low: 12.5, precipitation: 0, chance: 0, symbol: "clearsky_day", covered: 11)
        check("Europe/Oslo", 1, high: 16.5, low: 10.2, precipitation: 0, chance: 0.6, symbol: "partlycloudy_day", covered: 24)
        check("Europe/Oslo", 2, high: 16.2, low: 13.3, precipitation: 1.5, chance: 63.3, symbol: "lightrain", covered: 24)
        check("Europe/Oslo", 6, high: 16.6, low: 13.4, precipitation: 3.1, chance: 40, symbol: "cloudy", covered: 24)
        check("Asia/Kolkata", 2, high: 15.1, low: 13.0, precipitation: 1.5, chance: 63.3, symbol: "rain", covered: 24)
        check("Asia/Shanghai", 1, high: 17.8, low: 10.2, precipitation: 0, chance: 0.6, symbol: "partlycloudy_day",
              covered: 24)
        // Odd offsets and the date line: every day is summarized, none twice.
        for zone in ["America/St_Johns", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let days = WeatherTimeline.days(f, zone: WeatherFixtures.zone(zone), now: now)
            t.equal(days.count, 10, zone)
            t.check(days[1].available && days[1].covered == 24 * 3600, "\(zone): tomorrow is complete")
            t.check(zip(days, days.dropFirst()).allSatisfy { $0.end == $1.start }, "\(zone): consecutive")
        }
        // Late in the evening fresh data starts at the current hour, so less than 3 hours of today are left: today's
        // icon is then the period of what is left nearest to noon (22:10 in Oslo; the data from 20:00 UTC).
        let evening = WeatherForecast(steps: f.steps.filter { $0.time >= WeatherFixtures.date("2026-09-26T20:00:00Z") })
        let tonight = WeatherTimeline.days(evening, zone: WeatherFixtures.zone("Europe/Oslo"),
                                           now: WeatherFixtures.date("2026-09-26T20:10:00Z"))
        t.check(tonight[0].available, "today is still shown")
        t.equal(tonight[0].symbol?.raw, "clearsky_day", "with an icon (as by day)")
        t.equal(tonight[1].symbol?.raw, "partlycloudy_day", "tomorrow as before")
        let auckland = WeatherTimeline.days(f, zone: WeatherFixtures.zone("Pacific/Auckland"), now: now)
        t.check(auckland[0].symbol != nil, "the last hour of the day in Auckland")
        func period(_ hours: Int, _ code: String) -> WeatherPeriod {
            var p = WeatherPeriod(hours: hours)
            p.symbol = WeatherSymbol.parse(code)
            return p
        }
        let lateSteps = [WeatherStep(time: WeatherFixtures.date("2026-09-26T20:00:00Z"), next1h: period(1, "rain"),
                                     next6h: period(6, "cloudy")),
                         WeatherStep(time: WeatherFixtures.date("2026-09-26T21:00:00Z"), next1h: period(1, "fog"),
                                     next6h: period(6, "snow"))]
        let lateDays = WeatherTimeline.days(WeatherForecast(steps: lateSteps), zone: WeatherFixtures.zone("Europe/Oslo"),
                                            now: WeatherFixtures.date("2026-09-26T20:10:00Z"))
        t.equal(lateDays[0].symbol?.raw, "rain", "the hour nearest to noon of the two left")

        // Daily symbols are shown by day; days past the data are not available.
        let oslo = WeatherTimeline.days(f, zone: WeatherFixtures.zone("Europe/Oslo"), now: now)
        t.check(oslo.compactMap(\.symbol).allSatisfy { $0.variant != .night }, "no night symbols")
        t.equal(oslo[9].available, true, "the fixture reaches 6 October")
        t.equal(WeatherTimeline.days(f, zone: WeatherFixtures.zone("Europe/Oslo"), now: now, count: 12)[11].available, false)

        // A daylight saving change: a 25-hour and a 23-hour day (Europe/Oslo, 2026-10-25 and 2026-03-29).
        func hourly(from start: String, hours: Int, temperature: (Int) -> Double) -> WeatherForecast {
            let s = WeatherFixtures.date(start)
            return WeatherForecast(steps: (0..<hours).map { i in
                var instant = WeatherInstant()
                instant.temperature = temperature(i)
                var p = WeatherPeriod(hours: 1)
                p.precipitation = 1
                p.precipitationChance = Double(i % 50)
                return WeatherStep(time: s.addingTimeInterval(Double(i) * 3600), instant: instant, next1h: p)
            })
        }
        let autumn = hourly(from: "2026-10-24T00:00:00Z", hours: 72) { Double($0) }
        let autumnDays = WeatherTimeline.days(autumn, zone: WeatherFixtures.zone("Europe/Oslo"),
                                              now: WeatherFixtures.date("2026-10-24T10:00:00Z"))
        t.close(autumnDays[1].covered / 3600, 25, "the day the clocks go back has 25 hours")
        t.close(autumnDays[1].precipitation ?? 0, 25, accuracy: 1e-9)
        let spring = hourly(from: "2026-03-28T00:00:00Z", hours: 72) { Double($0) }
        let springDays = WeatherTimeline.days(spring, zone: WeatherFixtures.zone("Europe/Oslo"),
                                              now: WeatherFixtures.date("2026-03-28T10:00:00Z"))
        t.close(springDays[1].covered / 3600, 23, "the day the clocks go forward has 23 hours")

        // A gap between the hourly and six-hourly parts is simply not covered; half a day covered is not a day.
        var gap = hourly(from: "2026-09-27T00:00:00Z", hours: 6) { _ in 10 }
        var six = WeatherPeriod(hours: 6)
        six.precipitation = 6
        six.temperatureMax = 20
        six.temperatureMin = 5
        six.symbol = WeatherSymbol.parse("rain")
        gap.steps.append(WeatherStep(time: WeatherFixtures.date("2026-09-27T12:00:00Z"), next6h: six))
        let gapDays = WeatherTimeline.days(gap, zone: WeatherFixtures.zone("UTC"), now: WeatherFixtures.date("2026-09-26T12:00:00Z"))
        t.close(gapDays[1].covered / 3600, 12)
        t.check(gapDays[1].available, "12 hours covered is a day")
        t.equal(gapDays[1].high, 20, "six-hour extremes count")
        t.equal(gapDays[1].low, 5)
        t.close(gapDays[1].precipitation ?? 0, 12)
        let short = WeatherForecast(steps: Array(gap.steps.prefix(6)))
        t.equal(WeatherTimeline.days(short, zone: WeatherFixtures.zone("UTC"),
                                     now: WeatherFixtures.date("2026-09-26T12:00:00Z"))[1].available, false)
        // Today's range keeps the hours already gone (from earlier responses).
        let past = [WeatherFixtures.date("2026-09-26T03:00:00Z"): 9.5, WeatherFixtures.date("2026-09-25T20:00:00Z"): 30.0]
        let merged = WeatherTimeline.days(f, zone: WeatherFixtures.zone("Europe/Oslo"), now: now, past: past)
        t.equal(merged[0].low, 9.5, "an earlier, colder hour of today")
        t.equal(merged[0].high, 17.9, "yesterday's hour does not count")
        // Memoized per zone and local day.
        let snapshot = WeatherSnapshot(forecast: f)
        t.equal(snapshot.days(zone: WeatherFixtures.zone("Europe/Oslo"), now: now), oslo)
        t.equal(snapshot.days(zone: WeatherFixtures.zone("Europe/Oslo"), now: now.addingTimeInterval(60)), oslo)
    }
}

// MARK: - Units

private func runWeatherUnitTests(_ t: TestRunner) {
    t.suite("Weather: units") {
        t.close(TemperatureUnit.fahrenheit.convert(celsius: 100), 212)
        t.close(TemperatureUnit.fahrenheit.convert(celsius: -40), -40)
        t.close(WindUnit.kmh.convert(metersPerSecond: 10), 36)
        t.close(WindUnit.mph.convert(metersPerSecond: 10), 22.369, accuracy: 0.001)
        t.close(WindUnit.kn.convert(metersPerSecond: 10), 19.438, accuracy: 0.001)
        t.close(WindUnit.bft.convert(metersPerSecond: 10), 5)
        t.close(PrecipitationUnit.inch.convert(millimeters: 25.4), 1)
        t.close(PressureUnit.inHg.convert(hectopascals: 1013.25), 29.92, accuracy: 0.01)
        t.close(PressureUnit.mmHg.convert(hectopascals: 1013.25), 760, accuracy: 0.1)
        // Units=Auto from the macOS settings.
        t.equal(WeatherUnits.automatic(temperatureSetting: nil, measurementSystem: "metric"), .metric)
        t.equal(WeatherUnits.automatic(temperatureSetting: nil, measurementSystem: "U.S."), .imperial)
        var uk = WeatherUnits.metric
        uk.wind = .mph
        t.equal(WeatherUnits.automatic(temperatureSetting: nil, measurementSystem: "U.K."), uk)
        var celsiusUS = WeatherUnits.imperial
        celsiusUS.temperature = .celsius
        t.equal(WeatherUnits.automatic(temperatureSetting: "Celsius", measurementSystem: "U.S."), celsiusUS)
        t.equal(WeatherUnits.automatic(temperatureSetting: "Fahrenheit", measurementSystem: "metric").temperature, .fahrenheit)
        // Decimals: half away from zero, never -0.
        t.equal(WeatherUnits.round(2.5, decimals: 0), 3)
        t.equal(WeatherUnits.round(-2.5, decimals: 0), -3)
        t.equal(WeatherUnits.round(-0.4, decimals: 0).sign, .plus, "no -0")
        t.equal(WeatherUnits.round(16.34, decimals: 1), 16.3)
        // Beaufort boundaries and compass points.
        t.equal(WeatherUnits.beaufort(metersPerSecond: 0.49), 0)
        t.equal(WeatherUnits.beaufort(metersPerSecond: 0.5), 1)
        t.equal(WeatherUnits.beaufort(metersPerSecond: 5.49), 3)
        t.equal(WeatherUnits.beaufort(metersPerSecond: 5.5), 4)
        t.equal(WeatherUnits.beaufort(metersPerSecond: 32.69), 11)
        t.equal(WeatherUnits.beaufort(metersPerSecond: 32.7), 12)
        t.equal(WeatherUnits.beaufortNames.count, 13)
        t.equal(WeatherUnits.cardinal(degrees: 0), "N")
        t.equal(WeatherUnits.cardinal(degrees: 11.24), "N")
        t.equal(WeatherUnits.cardinal(degrees: 11.26), "NNE")
        t.equal(WeatherUnits.cardinal(degrees: 276), "W")
        t.equal(WeatherUnits.cardinal(degrees: 348.76), "N")
        t.equal(WeatherUnits.cardinal(degrees: -90), "W")
        // Feels like: MET's value first; heat index and wind chill against published table values.
        t.equal(WeatherUnits.feelsLike(temperature: 20, humidity: 50, windSpeed: 5, apparent: 18.5), 18.5)
        t.close(WeatherUnits.feelsLike(temperature: (90 - 32) * 5 / 9, humidity: 60, windSpeed: 1),
                (100 - 32) * 5 / 9, accuracy: 0.6, "NWS table: 90 °F at 60 % feels like 100 °F")
        t.close(WeatherUnits.feelsLike(temperature: (100 - 32) * 5 / 9, humidity: 50, windSpeed: 1),
                (118 - 32) * 5 / 9, accuracy: 0.6, "100 °F at 50 % feels like 118 °F")
        t.close(WeatherUnits.feelsLike(temperature: -10, humidity: 50, windSpeed: 30 / 3.6), -19.5, accuracy: 0.1,
                "wind chill table: −10 °C, 30 km/h")
        t.close(WeatherUnits.feelsLike(temperature: 0, humidity: 50, windSpeed: 20 / 3.6), -5.2, accuracy: 0.1)
        t.equal(WeatherUnits.feelsLike(temperature: 15, humidity: 90, windSpeed: 10), 15, "mild: the temperature")
        t.equal(WeatherUnits.feelsLike(temperature: 5, humidity: 90, windSpeed: 1), 5, "calm")
        // Temperature colours: the stops, clamped at both ends.
        t.equal(WeatherUnits.color(celsius: -40).r, 120)
        t.equal(WeatherUnits.color(celsius: 15).g, 220)
        t.equal(WeatherUnits.color(celsius: 22).r, 250)
        t.equal(WeatherUnits.color(celsius: 50).r, 240)
        let mid = WeatherUnits.color(celsius: 18.5)
        t.equal(mid.r, 185)
    }
}

// MARK: - Location and places

private func runWeatherLocationTests(_ t: TestRunner) {
    t.suite("Weather: location") {
        func c(_ lat: Double, _ lon: Double) -> WeatherLocationSpec { .coordinate(RoundedCoordinate(latitude: lat, longitude: lon)) }
        t.equal(WeatherLocationSpec.parse(""), .none)
        t.equal(WeatherLocationSpec.parse("  \"\"  "), .none)
        for s in ["auto", "AUTO", "Current", "here", "\"auto\""] { t.equal(WeatherLocationSpec.parse(s), .device, s) }
        t.equal(WeatherLocationSpec.parse("59.91,10.75"), c(59.91, 10.75))
        t.equal(WeatherLocationSpec.parse("59.9139, 10.7522"), c(59.91, 10.75))
        t.equal(WeatherLocationSpec.parse("59.91 10.75"), c(59.91, 10.75))
        t.equal(WeatherLocationSpec.parse("59.91;10.75"), c(59.91, 10.75))
        t.equal(WeatherLocationSpec.parse("59.91N 10.75E"), c(59.91, 10.75))
        t.equal(WeatherLocationSpec.parse("33.87 S, 151.21 E"), c(-33.87, 151.21))
        t.equal(WeatherLocationSpec.parse("10.75E 59.91N"), c(59.91, 10.75), "longitude first, by its letter")
        t.equal(WeatherLocationSpec.parse("21.31N 157.86W"), c(21.31, -157.86))
        t.equal(WeatherLocationSpec.parse("-33.87,151.21"), c(-33.87, 151.21))
        if case .invalid = WeatherLocationSpec.parse("91,10") {} else { t.check(false, "latitude out of range") }
        if case .invalid = WeatherLocationSpec.parse("59.91,190") {} else { t.check(false, "longitude out of range") }
        if case .invalid = WeatherLocationSpec.parse("59,91, 10,75") {} else { t.check(false, "comma decimals refused") }
        t.equal(WeatherLocationSpec.parse("Oslo"), .place("Oslo"))
        t.equal(WeatherLocationSpec.parse("  Springfield ,  IL "), .place("Springfield , IL"))
        t.equal(WeatherLocationSpec.parse("北京"), .place("北京"))
        // Rounding and formatting: two decimals, a point, no -0.00 — whatever the current locale.
        let r = RoundedCoordinate(latitude: 59.9139, longitude: 10.7522)
        t.equal(r.latitudeText, "59.91")
        t.equal(r.longitudeText, "10.75")
        t.equal(RoundedCoordinate(latitude: -0.001, longitude: -0.004).latitudeText, "0.00")
        t.equal(RoundedCoordinate(latitude: -0.001, longitude: -0.004).longitudeText, "0.00")
        t.equal(RoundedCoordinate(latitude: 1.005, longitude: 180).longitudeText, "-180.00", "180 wraps")
        t.equal(RoundedCoordinate(latitude: -33.8688, longitude: 151.2093).description, "-33.87, 151.21")
        t.equal(RoundedCoordinate(latitude: 95, longitude: 370).latitudeText, "90.00")
        t.equal(RoundedCoordinate(latitude: 0, longitude: 370).longitudeText, "10.00")
        t.equal(RoundedCoordinate(latitude: 0.05, longitude: 0).latitudeText, "0.05")
        t.equal(RoundedCoordinate(latitude: 59.91, longitude: 10.75).key, "59.91_10.75")
        let url = METNorway.url(for: r)
        t.equal(url.absoluteString, "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=59.91&lon=10.75")
        t.check(!url.absoluteString.contains("altitude"))
        // TimeZone= in hours is hours from UTC, even on a Mac whose own zone is on summer time; DaylightSavingTime=1
        // adds that offset, as the Time measure does.
        let berlin = WeatherFixtures.zone("Europe/Berlin")
        let summer = WeatherFixtures.date("2026-07-01T12:00:00Z"), winter = WeatherFixtures.date("2026-01-15T12:00:00Z")
        func offset(_ option: String, dst: Bool, at date: Date = summer) -> Int {
            WeatherLocationResolver.zone(option: option, place: nil, daylightSavingTime: dst, at: date,
                                         localTimeZone: berlin).secondsFromGMT(for: date) / 3600
        }
        t.equal(offset("9", dst: WeatherLocationResolver.daylightSavingTime(nil)), 9, "Tokyo is UTC+9")
        t.equal(offset("0", dst: false), 0)
        t.equal(offset("9", dst: true), 10, "DaylightSavingTime=1 in a Berlin summer")
        t.equal(offset("9", dst: true, at: winter), 9)
        t.equal(WeatherLocationResolver.daylightSavingTime("1"), true)
        t.equal(WeatherLocationResolver.daylightSavingTime("0"), false)
        t.equal(offset("Local", dst: false), 2, "Local is this Mac's zone")
        t.equal(WeatherLocationResolver.zone(option: "Asia/Tokyo", place: nil, daylightSavingTime: true,
                                             localTimeZone: berlin).identifier, "Asia/Tokyo")
    }

    t.suite("Weather: places") {
        guard let d = PlaceDirectory(url: WeatherFixtures.placesFixture) else { return t.check(false, "fixture table") }
        t.equal(d.search("Oslo")?.place.country, "NO")
        t.equal(d.search("Oslo")?.detail, "Oslo, Oslo, Norway")
        t.equal(d.search("oslo")?.displayName, "Oslo")
        t.equal(d.search("zurich")?.place.name, "Zürich", "diacritics folded")
        t.equal(d.search("ZÜRICH")?.place.name, "Zürich")
        t.equal(d.search("sao paulo")?.place.country, "BR")
        t.equal(d.search("北京")?.place.name, "Beijing")
        t.equal(d.search("北京")?.displayName, "北京", "the user's spelling is shown")
        t.equal(d.search("北京市")?.place.name, "Beijing")
        t.equal(d.search("奥斯陆")?.place.name, "Oslo")
        t.equal(d.search("苏州市")?.place.name, "Suzhou")
        t.equal(d.search("广州市")?.displayName, "广州市")
        t.equal(d.search("Kristiania")?.place.name, "Oslo")
        // Springfield: the largest by default, qualifiers pick another.
        t.equal(d.search("Springfield")?.place.admin1, "MO", "largest first")
        t.equal(d.search("Springfield, IL")?.place.admin1, "IL", "a region code")
        t.equal(d.search("Springfield, Illinois")?.place.admin1, "IL", "a region name")
        t.equal(d.search("Springfield, Oregon, US")?.place.admin1, "OR", "two qualifiers")
        t.equal(d.search("Springfield, Illinois, United States")?.detail, "Springfield, Illinois, United States")
        t.equal(d.search("Springfield, NO"), nil, "no Springfield in Norway")
        t.equal(d.search("Sydney")?.place.country, "AU")
        t.equal(d.search("Sydney, CA")?.place.country, "CA", "a country code")
        t.equal(d.search("Sydney, Canada")?.place.country, "CA", "a country name")
        t.equal(d.search("London, ca")?.place.timeZone, "America/Toronto")
        // Prefix matches (3 characters, 2 for CJK); not found.
        t.equal(d.search("Reykj")?.place.name, "Reykjavík")
        t.equal(d.search("Os"), nil, "too short for a prefix")
        t.equal(d.search("苏州")?.place.name, "Suzhou")
        t.equal(d.search("Atlantis"), nil)
        t.equal(d.search(""), nil)
        // Nearest places.
        t.equal(d.nearest(to: RoundedCoordinate(latitude: 59.95, longitude: 10.80), within: 50)?.name, "Oslo")
        t.equal(d.nearest(to: RoundedCoordinate(latitude: 60.39, longitude: 5.32), within: 50)?.name, "Bergen")
        t.equal(d.nearest(to: RoundedCoordinate(latitude: 0, longitude: -30), within: 200)?.name, nil, "mid-ocean")
        t.equal(d.nearest(to: RoundedCoordinate(latitude: 1.9, longitude: -157.3), within: 50)?.timeZone,
                "Pacific/Kiritimati")

        // The bundled table.
        let data = try Data(contentsOf: WeatherFixtures.bundledPlaces)
        t.check(data.count <= 4 * 1024 * 1024, "the table is at most 4 MB: \(data.count)")
        guard let full = PlaceDirectory(url: WeatherFixtures.bundledPlaces) else { return t.check(false, "bundled table") }
        t.check(full.count >= 20_000, "\(full.count) places")
        t.equal(full.search("Oslo")?.place.country, "NO")
        t.equal(full.search("北京")?.place.name, "Beijing")
        t.equal(full.search("Springfield, IL")?.place.admin1, "IL")
        t.equal(full.search("東京")?.place.country, "JP")
        t.equal(full.search("Москва")?.place.country, "RU")
        t.equal(full.countryName("NO"), "Norway")
        t.equal(full.meta["license"]?.hasPrefix("CC BY 4.0"), true)
        t.check(full.places.allSatisfy { TimeZone(identifier: $0.timeZone) != nil || $0.timeZone.isEmpty },
                "every time zone is known to macOS")
    }
}

// MARK: - Sun and moon

private func date(_ iso: String) -> Date { WeatherFixtures.date(iso) }

private func runWeatherSunTests(_ t: TestRunner) {
    t.suite("Weather: sun") {
        func event(_ e: SolarEvent, _ lat: Double, _ lon: Double, _ day: String, _ zone: String) -> SolarEventResult {
            let z = WeatherFixtures.zone(zone)
            var c = Calendar(identifier: .gregorian)
            c.timeZone = z
            let parts = day.split(separator: "-").compactMap { Int($0) }
            let start = c.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
            return SolarCalculator.event(e, dayStart: start, zone: z, latitude: lat, longitude: lon)
        }
        func near(_ r: SolarEventResult, _ iso: String, minutes: Double, _ what: String, line: UInt = #line) {
            guard let d = r.date else { return t.check(false, "\(what): \(r)", line: line) }
            let diff = abs(d.timeIntervalSince(WeatherFixtures.date(iso))) / 60
            t.check(diff <= minutes, "\(what): off by \(String(format: "%.2f", diff)) min", line: line)
        }
        // Reference times from an independent ephemeris (VSOP87): sun's centre at 0.833° below the horizon, no
        // refraction model; civil 6°, nautical 12°, astronomical 18° below; golden hour 6° above.
        typealias SunCase = (name: String, lat: Double, lon: Double, day: String, zone: String, rise: String, set: String)
        let cases: [SunCase] = [
            ("Oslo", 59.91, 10.75, "2026-09-26", "Europe/Oslo", "2026-09-26T05:10:25Z", "2026-09-26T17:04:55Z"),
            ("Singapore", 1.29, 103.85, "2026-03-20", "Asia/Singapore", "2026-03-19T23:08:53Z", "2026-03-20T11:15:21Z"),
            ("Beijing", 39.91, 116.40, "2026-06-21", "Asia/Shanghai", "2026-06-20T20:45:56Z", "2026-06-21T11:46:20Z"),
            ("Sydney", -33.87, 151.21, "2026-12-21", "Australia/Sydney", "2026-12-20T18:40:38Z", "2026-12-21T09:05:24Z"),
            ("Honolulu", 21.31, -157.86, "2026-01-15", "Pacific/Honolulu", "2026-01-15T17:11:32Z", "2026-01-16T04:10:35Z"),
            ("Tromsø (March)", 69.65, 18.96, "2026-03-20", "Europe/Oslo", "2026-03-20T04:43:54Z", "2026-03-20T17:01:29Z"),
        ]
        for (name, lat, lon, day, zone, rise, set) in cases {
            let tolerance = abs(lat) <= 65 ? 1.0 : 3.0
            near(event(.sunrise, lat, lon, day, zone), rise, minutes: tolerance, "\(name) sunrise")
            near(event(.sunset, lat, lon, day, zone), set, minutes: tolerance, "\(name) sunset")
        }
        near(event(.sunrise, 64.14, -21.90, "2026-06-21", "Atlantic/Reykjavik"), "2026-06-21T02:55:12Z", minutes: 3,
             "Reykjavík sunrise")
        near(event(.sunset, 64.14, -21.90, "2026-06-21", "Atlantic/Reykjavik"), "2026-06-22T00:03:37Z", minutes: 3,
             "Reykjavík sunset after midnight")
        near(event(.civilDawn, 59.91, 10.75, "2026-09-26", "Europe/Oslo"), "2026-09-26T04:29:01Z", minutes: 1, "civil dawn")
        near(event(.civilDusk, 59.91, 10.75, "2026-09-26", "Europe/Oslo"), "2026-09-26T17:46:09Z", minutes: 1, "civil dusk")
        near(event(.nauticalDusk, 59.91, 10.75, "2026-09-26", "Europe/Oslo"), "2026-09-26T18:35:13Z", minutes: 1.5, "nautical")
        near(event(.astronomicalDawn, 59.91, 10.75, "2026-09-26", "Europe/Oslo"), "2026-09-26T02:46:40Z", minutes: 2,
             "astronomical")
        near(event(.goldenHourMorningEnd, 59.91, 10.75, "2026-09-26", "Europe/Oslo"), "2026-09-26T06:05:33Z", minutes: 1,
             "golden hour ends")
        near(event(.goldenHourEveningStart, 59.91, 10.75, "2026-09-26", "Europe/Oslo"), "2026-09-26T16:09:57Z", minutes: 1,
             "golden hour starts")
        // Polar day and night.
        t.equal(event(.sunrise, 69.65, 18.96, "2026-06-21", "Europe/Oslo"), .alwaysAbove, "Tromsø midnight sun")
        t.equal(event(.sunrise, 69.65, 18.96, "2026-12-21", "Europe/Oslo"), .alwaysBelow, "Tromsø polar night")
        near(event(.civilDawn, 69.65, 18.96, "2026-12-21", "Europe/Oslo"), "2026-12-21T08:31:15Z", minutes: 3,
             "Tromsø civil dawn in the polar night")
        t.equal(event(.sunset, 78.22, 15.65, "2026-04-30", "Arctic/Longyearbyen"), .alwaysAbove)
        t.equal(event(.goldenHourMorningEnd, 78.22, 15.65, "2026-02-20", "Arctic/Longyearbyen"), .alwaysBelow)
        near(event(.sunrise, 78.22, 15.65, "2026-02-20", "Arctic/Longyearbyen"), "2026-02-20T09:02:50Z", minutes: 5,
             "Longyearbyen sunrise")
        // Solar noon, position, day length and progress.
        let osloDay = SolarCalculator.day(containing: WeatherFixtures.clock, zone: WeatherFixtures.zone("Europe/Oslo"),
                                          latitude: 59.91, longitude: 10.75)
        t.check(abs(osloDay.solarNoon.timeIntervalSince(WeatherFixtures.date("2026-09-26T11:08:20Z"))) < 30, "solar noon")
        let referenceLength: Double = date("2026-09-26T17:04:55Z").timeIntervalSince(date("2026-09-26T05:10:25Z"))
        t.close(osloDay.length, referenceLength, accuracy: 120)
        let sinceSunrise: Double = WeatherFixtures.clock.timeIntervalSince(date("2026-09-26T05:10:25Z"))
        t.close(osloDay.progress(at: WeatherFixtures.clock), sinceSunrise / referenceLength, accuracy: 0.01)
        t.equal(osloDay.progress(at: WeatherFixtures.date("2026-09-26T03:00:00Z")), 0)
        t.equal(osloDay.progress(at: WeatherFixtures.date("2026-09-26T20:00:00Z")), 1)
        t.equal(osloDay.state, 0)
        let polar = SolarCalculator.day(containing: WeatherFixtures.date("2026-06-21T12:00:00Z"),
                                        zone: WeatherFixtures.zone("Europe/Oslo"), latitude: 69.65, longitude: 18.96)
        t.equal(polar.state, 1)
        t.close(polar.length, 86_400)
        t.close(polar.progress(at: WeatherFixtures.date("2026-06-21T10:00:00Z")), 0.5, accuracy: 0.001)
        let night = SolarCalculator.day(containing: WeatherFixtures.date("2026-12-21T12:00:00Z"),
                                        zone: WeatherFixtures.zone("Europe/Oslo"), latitude: 69.65, longitude: 18.96)
        t.equal(night.state, 2)
        t.equal(night.length, 0)
        t.equal(night.progress(at: WeatherFixtures.date("2026-12-21T12:00:00Z")), 0)
        // Day, night and polar twilight from the sun alone.
        func daylight(_ iso: String, _ lat: Double, _ lon: Double, _ zone: String) -> Int {
            SolarCalculator.daylight(at: date(iso), latitude: lat, longitude: lon, zone: WeatherFixtures.zone(zone))
        }
        t.equal(daylight("2026-09-26T11:59:31Z", 59.91, 10.75, "Europe/Oslo"), 1, "Oslo at noon")
        t.equal(daylight("2026-09-26T20:00:00Z", 59.91, 10.75, "Europe/Oslo"), 0, "Oslo at night")
        t.equal(daylight("2026-09-26T04:40:00Z", 59.91, 10.75, "Europe/Oslo"), 0, "dawn on a day the sun rises: night")
        t.equal(daylight("2026-12-21T11:00:00Z", 69.65, 18.96, "Europe/Oslo"), 2, "Tromsø in the polar night at noon")
        t.equal(daylight("2026-12-21T12:30:00Z", 69.65, 18.96, "Europe/Oslo"), 2, "5° below the horizon")
        t.equal(daylight("2026-12-21T13:00:00Z", 69.65, 18.96, "Europe/Oslo"), 0, "6.3° below")
        t.equal(daylight("2026-12-21T06:00:00Z", 69.65, 18.96, "Europe/Oslo"), 0, "darker than civil twilight")
        t.equal(daylight("2026-06-21T23:00:00Z", 69.65, 18.96, "Europe/Oslo"), 1, "the midnight sun")
        let p = SolarCalculator.position(at: WeatherFixtures.clock, latitude: 59.91, longitude: 10.75)
        t.close(p.elevation, 27.917, accuracy: 0.1, "elevation")
        t.close(p.azimuth, 194.513, accuracy: 0.2, "azimuth")
        let b = SolarCalculator.position(at: WeatherFixtures.date("2026-06-21T04:00:00Z"), latitude: 39.91, longitude: 116.40)
        t.close(b.elevation, 73.178, accuracy: 0.1)
        t.close(b.azimuth, 167.106, accuracy: 0.3)
    }

    t.suite("Weather: moon") {
        // Published phases (UTC): the mean month is within about a day of them.
        let cases: [(String, Double)] = [("2024-01-25T17:54:00Z", 0.5), ("2024-04-08T18:21:00Z", 0),
                                         ("2024-09-18T02:34:00Z", 0.5), ("2025-03-14T06:55:00Z", 0.5),
                                         ("2025-03-29T10:58:00Z", 0), ("2026-02-17T12:01:00Z", 0)]
        for (iso, expected) in cases {
            let phase = MoonPhase.phase(at: WeatherFixtures.date(iso))
            var diff = abs(phase - expected)
            diff = min(diff, 1 - diff)
            t.check(diff * MoonPhase.synodicMonth <= 1, "\(iso): \(phase)")
        }
        t.close(MoonPhase.phase(at: MoonPhase.referenceNewMoon), 0)
        t.close(MoonPhase.illumination(phase: 0.5), 100)
        t.close(MoonPhase.illumination(phase: 0), 0)
        t.close(MoonPhase.illumination(phase: 0.25), 50, accuracy: 1e-9)
        t.equal(MoonPhase.eighth(phase: 0.97), 0)
        t.equal(MoonPhase.eighth(phase: 0.5), 4)
        t.equal(MoonPhase.names[MoonPhase.eighth(phase: 0.26)], "First Quarter")
    }
}

// MARK: - Editor and reports

private func runWeatherEditorTests(_ t: TestRunner) {
    typealias S = EditorSchema
    t.suite("Weather: editor schema and names") {
        t.equal(S.describeMeasure(type: "Plugin", plugin: "MacWeather").title, "Weather")
        t.equal(S.describeMeasure(type: "plugin", plugin: "macsun").symbol, "sunrise")
        let weather = S.measureGroups("Plugin", plugin: "MacWeather")
        let keys = S.keys(weather)
        for key in ["location", "parent", "type", "hour", "day", "units", "temperatureunit", "windunit",
                    "precipitationunit", "pressureunit", "format", "timezone", "formatlocale", "decimals",
                    "unavailabletext", "symbolstyle", "hours", "curvewidth", "curveheight", "smooth", "colorof",
                    "finishaction", "onconnecterroraction", "onlocationerroraction", "noeventtext",
                    "daylightsavingtime"] {
            t.check(keys.contains(key), "MacWeather \(key)")
        }
        t.equal(S.property("Type", in: weather)?.kind.choices?.count, MacWeatherMeasure.ValueType.allCases.count,
                "every Type is in the menu")
        for type in MacWeatherMeasure.ValueType.allCases {
            t.check(S.weatherTypes.contains { $0.value == type.optionName }, "\(type.optionName) listed")
        }
        for type in MacSunMeasure.ValueType.allCases {
            t.check(S.sunTypes.contains { $0.value == type.optionName }, "MacSun \(type.optionName) listed")
        }
        t.check(weather.allSatisfy { $0.essentialRows.count <= 5 }, "at most five essentials")
        func visible(_ key: String, _ values: [String: String], _ groups: [S.Group] = weather) -> Bool {
            guard let p = S.property(key, in: groups) else { return false }
            return S.isVisible(p, in: groups, values: { values[$0.lowercased()] })
        }
        t.check(visible("Hour", ["type": "Temperature"]))
        t.check(!visible("Hour", ["type": "High"]), "no hours for the high")
        t.check(visible("Day", ["type": "high"]))
        t.check(visible("Day", ["type": "Wind"]), "Wind is WindSpeed")
        t.check(!visible("Day", ["type": "Humidity"]))
        t.check(!visible("Location", ["parent": "MeasureWeather"]), "a child has no place of its own")
        t.check(visible("FinishAction", ["parent": "MeasureWeather"]), "but its own actions (they run with the parent's)")
        t.check(visible("SymbolStyle", ["type": "Symbol"]) && !visible("SymbolStyle", ["type": "Temperature"]))
        t.check(visible("Format", ["type": "Sunrise"]) && !visible("Format", ["type": "Humidity"]))
        t.check(visible("NoEventText", ["type": "Sunset"]) && !visible("NoEventText", ["type": "Temperature"]))
        t.check(visible("DaylightSavingTime", ["timezone": "9"]), "hours from UTC")
        t.check(!visible("DaylightSavingTime", [:]) && !visible("DaylightSavingTime", ["timezone": "Place"]))
        let sun = S.measureGroups("Plugin", plugin: "MacSun")
        t.check(S.keys(sun).isSuperset(of: ["location", "parent", "type", "day", "format", "timezone", "noeventtext",
                                            "daylightsavingtime"]))
        t.check(!visible("Format", ["type": "MoonPhase"], sun))
        t.check(S.liveDataCatalogue.last?.items.flatMap(\.children).allSatisfy { $0.measureType != nil } == true)

        // Names in the layer list and the data page.
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Type=Temperature
        [H3]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Hour=3
        [Tomorrow]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=High
        Day=1
        [High3]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=High
        Day=3
        [Rise]
        Measure=Plugin
        Plugin=MacSun
        Type=Sunrise
        [Moon]
        Measure=Plugin
        Plugin=MacSun
        Type=MoonPhase
        [Far]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Type=High
        Day=1e20
        [Late]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Hour=1e20
        [Before]
        Measure=Plugin
        Plugin=MacSun
        Type=Sunset
        Day=-1e20
        """)
        func name(_ m: String) -> String { skin.measure(named: m).map { LayerNaming.data($0, in: skin).name } ?? "?" }
        t.equal(name("W"), "Temperature (weather)")
        t.equal(name("H3"), "Temperature in 3 hours")
        t.equal(name("Tomorrow"), "Tomorrow's high")
        t.equal(name("High3"), "High, in 3 days")
        t.equal(name("Rise"), "Sunrise")
        t.equal(name("Moon"), "Moon phase")
        // Numbers too large for an Int are clamped as the plugins clamp them.
        t.equal(name("Far"), "High, in 9 days")
        t.equal(name("Late"), "Temperature in 47 hours")
        t.equal(name("Before"), "Yesterday's sunset")
        skin.close()
    }

    t.suite("Weather: reports") {
        // The places written in a skin, found without loading it (variables and @Include resolved).
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        @Include=#@#Place.inc
        [Variables]
        Where=Oslo, NO
        [W]
        Measure=Plugin
        Plugin=MacWeather
        Location=#Where#
        [Child]
        Measure=Plugin
        Plugin=MacWeather
        Parent=W
        Location=ignored
        [S]
        Measure=Plugin
        Plugin=Plugins\\MacSun.dll
        Location=#Home#
        [Empty]
        Measure=Plugin
        Plugin=MacSun
        [Other]
        Measure=Calc
        Location=Paris
        """, files: ["Root/@Resources/Place.inc": "[Variables]\nHome=59.91,10.75\n"])
        let found = WeatherReport.locations(inSkin: skin.fileURL, config: "Root\\Sub", skinsDirectory: skin.skinsDirectory)
        t.equal(found.map(\.section), ["W", "S"])
        t.equal(found.map(\.location), ["Oslo, NO", "59.91,10.75"])
        t.equal(found.map(\.plugin), ["MacWeather", "MacSun"])
        skin.close()
        let d = PlaceDirectory(url: WeatherFixtures.placesFixture)
        t.equal(WeatherReport.describe("Oslo, NO", directory: d), "Oslo, Oslo, Norway · 59.91, 10.75 · Europe/Oslo")
        t.equal(WeatherReport.describe("auto", directory: d), "this Mac's location (not read by this report)")
        t.check(WeatherReport.describe("59.95,10.8", directory: d).hasPrefix("near Oslo, Oslo, Norway · 59.95, 10.80"))
        t.equal(WeatherReport.describe("Atlantis", directory: d), "not found in the place table")
        t.equal(WeatherReport.describe("Oslo", directory: nil), "place search unavailable (no place table)")
        guard let f = WeatherFixtures.forecast() else { return t.check(false, "fixture") }
        let lines = WeatherReport.forecastLines(f, place: "Oslo", coordinate: WeatherFixtures.oslo,
                                                zone: WeatherFixtures.zone("Europe/Oslo"), units: .metric,
                                                now: WeatherFixtures.clock)
        t.equal(lines.first, "Place:      Oslo (59.91, 10.75), Europe/Oslo")
        t.check(lines.contains { $0.hasPrefix("Now (13:00): 16.3 °C, feels like 16.3 °C, Mostly clear") }, "\(lines)")
        t.check(lines.contains("  Today       17.9 / 12.5 °C  Clear  0.0 mm  0 %"), "\(lines)")
        t.check(lines.contains { $0.hasPrefix("Sun today:  sunrise 07:10, sunset 19:04") }, "\(lines)")
        t.equal(lines.last?.hasPrefix("Source:     Based on data from MET Norway"), true)
        let imperial = WeatherReport.forecastLines(f, place: "Oslo", coordinate: WeatherFixtures.oslo,
                                                   zone: WeatherFixtures.zone("Europe/Oslo"), units: .imperial,
                                                   now: WeatherFixtures.clock, hours: 0, days: 0)
        t.check(imperial.contains { $0.contains("61.3 °F") && $0.contains("mph") }, "\(imperial)")
        t.equal(WeatherReport.sunLine(latitude: 69.65, longitude: 18.96, zone: WeatherFixtures.zone("Europe/Oslo"),
                                      now: WeatherFixtures.date("2026-06-21T12:00:00Z")),
                "sunrise none (the sun stays up), sunset none (the sun stays up), daylight 24:00")
    }
}
