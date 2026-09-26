import Foundation

// Values derived from a forecast: "now", hour N and day N (docs/compat/weather.md). Pure functions of the forecast,
// the clock and the display time zone.

/// A daily summary in the display time zone (local midnight to local midnight).
public struct WeatherDay: Equatable {
    public var start: Date
    public var end: Date
    public var high: Double?
    public var low: Double?
    /// Sum over the day (mm).
    public var precipitation: Double?
    public var precipitationChance: Double?
    public var thunderChance: Double?
    public var windMax: Double?
    public var gustMax: Double?
    public var uvMax: Double?
    /// Always the day variant.
    public var symbol: WeatherSymbol?
    /// Seconds of the day the forecast covers.
    public var covered: TimeInterval
    public var available: Bool

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
        covered = 0
        available = false
    }
}

public enum WeatherTimeline {
    /// Local midnight of `date` in `zone`.
    public static func startOfDay(_ date: Date, zone: TimeZone) -> Date {
        calendar(zone).startOfDay(for: date)
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    // MARK: Now and hour N

    /// The step "now" is: the latest step at or before `now`; before the first step, the first one when it starts
    /// within an hour.
    public static func nowIndex(_ forecast: WeatherForecast, now: Date) -> Int? {
        let steps = forecast.steps
        guard let first = steps.first else { return nil }
        if now < first.time { return first.time.timeIntervalSince(now) <= 3600 ? 0 : nil }
        var lo = 0, hi = steps.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if steps[mid].time <= now { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Hour N (`Hour=0…47`): the step exactly N hours after the now step, when it has a one-hour forecast.
    public static func hourIndex(_ forecast: WeatherForecast, now: Date, hour: Int) -> Int? {
        guard hour >= 0, let n = nowIndex(forecast, now: now) else { return nil }
        let target = forecast.steps[n].time.addingTimeInterval(TimeInterval(hour) * 3600)
        var i = n
        while i < forecast.steps.count, forecast.steps[i].time < target { i += 1 }
        guard i < forecast.steps.count, forecast.steps[i].time == target, forecast.steps[i].next1h != nil else { return nil }
        return i
    }

    // MARK: Days

    /// A period of the forecast: every one-hour period, then the six-hour periods of the steps without a one-hour
    /// forecast that start at or after the end of the last one-hour period (no overlap).
    struct Span {
        var start: Date
        var end: Date
        var period: WeatherPeriod
        var length: TimeInterval { end.timeIntervalSince(start) }

        func overlap(_ from: Date, _ to: Date) -> TimeInterval {
            max(0, min(end, to).timeIntervalSince(max(start, from)))
        }
    }

    static func spans(_ forecast: WeatherForecast) -> [Span] {
        var result: [Span] = []
        var lastHourlyEnd: Date?
        for s in forecast.steps {
            guard let p = s.next1h else { continue }
            let end = s.time.addingTimeInterval(3600)
            result.append(Span(start: s.time, end: end, period: p))
            lastHourlyEnd = max(lastHourlyEnd ?? end, end)
        }
        for s in forecast.steps where s.next1h == nil {
            guard let p = s.next6h else { continue }
            if let lastHourlyEnd, s.time < lastHourlyEnd { continue }
            result.append(Span(start: s.time, end: s.time.addingTimeInterval(6 * 3600), period: p))
        }
        return result
    }

    /// Day 0…9 in `zone` for the local day of `now`. `past`: instant temperatures of earlier steps (today's high and
    /// low include the hours already gone).
    public static func days(_ forecast: WeatherForecast, zone: TimeZone, now: Date,
                            past: [Date: Double] = [:], count: Int = 10) -> [WeatherDay] {
        let cal = calendar(zone)
        let today = cal.startOfDay(for: now)
        let spans = spans(forecast)
        var result: [WeatherDay] = []
        for n in 0..<count {
            guard let start = cal.date(byAdding: .day, value: n, to: today),
                  let end = cal.date(byAdding: .day, value: n + 1, to: today) else { break }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start.addingTimeInterval(43_200)
            result.append(day(forecast, spans: spans, start: start, end: end, noon: noon, index: n,
                              past: n == 0 ? past : [:]))
        }
        return result
    }

    static func day(_ forecast: WeatherForecast, spans: [Span], start: Date, end: Date, noon: Date, index: Int,
                    past: [Date: Double]) -> WeatherDay {
        var d = WeatherDay(start: start, end: end)
        func inWindow(_ t: Date) -> Bool { t >= start && t < end }
        func maxOf(_ a: Double?, _ b: Double?) -> Double? {
            guard let b else { return a }
            return a.map { max($0, b) } ?? b
        }
        func minOf(_ a: Double?, _ b: Double?) -> Double? {
            guard let b else { return a }
            return a.map { min($0, b) } ?? b
        }
        for s in forecast.steps where inWindow(s.time) {
            d.high = maxOf(d.high, s.instant.temperature)
            d.low = minOf(d.low, s.instant.temperature)
            d.windMax = maxOf(d.windMax, s.instant.windSpeed)
            d.gustMax = maxOf(d.gustMax, s.instant.windGust)
            d.uvMax = maxOf(d.uvMax, s.instant.uvIndex)
        }
        for (t, temperature) in past where inWindow(t) {
            d.high = maxOf(d.high, temperature)
            d.low = minOf(d.low, temperature)
        }
        // The extremes of the six-hourly part.
        for s in forecast.steps where s.next1h == nil {
            guard let p = s.next6h else { continue }
            let span = Span(start: s.time, end: s.time.addingTimeInterval(6 * 3600), period: p)
            guard span.overlap(start, end) >= 3 * 3600 else { continue }
            d.high = maxOf(d.high, p.temperatureMax)
            d.low = minOf(d.low, p.temperatureMin)
        }
        var precipitation: Double?
        for span in spans {
            let o = span.overlap(start, end)
            guard o > 0 else { continue }
            d.covered += o
            if let amount = span.period.precipitation {
                precipitation = (precipitation ?? 0) + amount * o / span.length
            }
            if o >= span.length / 2 {
                d.precipitationChance = maxOf(d.precipitationChance, span.period.precipitationChance)
                d.thunderChance = maxOf(d.thunderChance, span.period.thunderChance)
            }
        }
        d.precipitation = precipitation
        // Symbol: the six-hour period whose middle is nearest to local noon (ties: the earlier one), shown by day.
        var best: (distance: TimeInterval, time: Date, symbol: WeatherSymbol)?
        for s in forecast.steps {
            guard let p = s.next6h, let symbol = p.symbol else { continue }
            let span = Span(start: s.time, end: s.time.addingTimeInterval(6 * 3600), period: p)
            guard span.overlap(start, end) >= 3 * 3600 else { continue }
            let distance = abs(s.time.addingTimeInterval(3 * 3600).timeIntervalSince(noon))
            if best.map({ distance < $0.distance || (distance == $0.distance && s.time < $0.time) }) ?? true {
                best = (distance, s.time, symbol)
            }
        }
        d.symbol = best?.symbol.asDay
        d.available = d.covered >= 12 * 3600 || (index == 0 && d.covered > 0)
        return d
    }

    // MARK: Ranges

    /// Lowest and highest value of `value` over the now step and the next 23 hours.
    public static func range(_ forecast: WeatherForecast, now: Date,
                             _ value: (WeatherStep) -> Double?) -> (min: Double, max: Double)? {
        guard let n = nowIndex(forecast, now: now) else { return nil }
        let limit = forecast.steps[n].time.addingTimeInterval(23 * 3600)
        var lo: Double?, hi: Double?
        for s in forecast.steps[n...] {
            if s.time > limit { break }
            guard let v = value(s) else { continue }
            lo = min(lo ?? v, v)
            hi = max(hi ?? v, v)
        }
        guard let lo, let hi else { return nil }
        return (lo, hi)
    }
}
