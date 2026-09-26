import Foundation

// The weather forecast as MET Norway's Locationforecast 2.0 (`complete`) describes it, with every field optional:
// what the service parsed from one response (`METNorway.parse`), before anything is derived from it
// (`WeatherTimeline`) or converted (`WeatherUnits`). Units as MET sends them: °C, hPa, %, degrees, m/s, mm.

/// Values at one moment (`data.instant.details`).
public struct WeatherInstant: Equatable {
    public var temperature: Double?
    public var apparentTemperature: Double?
    public var dewPoint: Double?
    public var humidity: Double?
    public var pressure: Double?
    public var cloudCover: Double?
    public var cloudLow: Double?
    public var cloudMedium: Double?
    public var cloudHigh: Double?
    public var fog: Double?
    public var uvIndex: Double?
    public var windSpeed: Double?
    public var windGust: Double?
    public var windDirection: Double?
    public var temperatureP10: Double?
    public var temperatureP90: Double?

    public init() {}
}

/// A forecast for the hours after a step (`next_1_hours`, `next_6_hours`, `next_12_hours`).
public struct WeatherPeriod: Equatable {
    /// 1, 6 or 12.
    public var hours: Int
    public var symbol: WeatherSymbol?
    /// `symbol_confidence` (next 12 hours only; undocumented, kept as sent).
    public var symbolConfidence: String?
    public var precipitation: Double?
    public var precipitationMin: Double?
    public var precipitationMax: Double?
    public var precipitationChance: Double?
    public var thunderChance: Double?
    public var temperatureMax: Double?
    public var temperatureMin: Double?

    public init(hours: Int) {
        self.hours = hours
    }

    /// Length in seconds.
    public var length: TimeInterval { TimeInterval(hours) * 3600 }
}

/// One entry of `properties.timeseries`.
public struct WeatherStep: Equatable {
    public var time: Date
    public var instant: WeatherInstant
    public var next1h: WeatherPeriod?
    public var next6h: WeatherPeriod?
    public var next12h: WeatherPeriod?

    public init(time: Date, instant: WeatherInstant = WeatherInstant(), next1h: WeatherPeriod? = nil,
                next6h: WeatherPeriod? = nil, next12h: WeatherPeriod? = nil) {
        self.time = time
        self.instant = instant
        self.next1h = next1h
        self.next6h = next6h
        self.next12h = next12h
    }

    /// The shortest period the step has (what "now" and hour N use): 1 hour, else 6, else 12.
    public var shortestPeriod: WeatherPeriod? { next1h ?? next6h ?? next12h }
}

/// A parsed forecast. Steps are sorted by time, without duplicates.
public struct WeatherForecast: Equatable {
    /// `properties.meta.updated_at`: when MET's model run was made.
    public var updatedAt: Date?
    /// `geometry.coordinates` (`[lon, lat, altitude]`): the point MET used.
    public var latitude: Double?
    public var longitude: Double?
    public var elevation: Double?
    public var steps: [WeatherStep]

    public init(updatedAt: Date? = nil, latitude: Double? = nil, longitude: Double? = nil, elevation: Double? = nil,
                steps: [WeatherStep]) {
        self.updatedAt = updatedAt
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.steps = steps
    }
}

// MARK: - Snapshot

/// What a feed publishes for skins to read: the forecast and the state of its fetches. Immutable; a new one replaces
/// it after every change. Values derived from the forecast (daily summaries) are computed once per time zone and local
/// day and kept inside it (any thread).
public final class WeatherSnapshot {
    /// Why the last attempt failed (nil after a success).
    public enum Failure: Equatable {
        /// Network error or time-out.
        case offline
        /// 429, 5xx, a body that could not be read, a refused redirect or a body that was too large.
        case busy
        /// 400 / 403: automatic requests stop until a Refresh, a relaunch or 24 hours.
        case refused
        /// 404 / 422: no forecast for this place.
        case notCovered
    }

    public let forecast: WeatherForecast?
    /// The last successful response with a body (200 / 203).
    public let fetchedAt: Date?
    /// The last successful response (200, 203 or 304).
    public let validatedAt: Date?
    /// When the data expires, in the Mac's clock (`Expires` corrected with the server's `Date`).
    public let expiresLocal: Date?
    public let lastFailure: Failure?
    /// Counts failure streaks: a new failure after a success (or after the first data) starts a new one.
    public let failureStreak: Int
    /// A request is under way.
    public let isFetching: Bool
    /// Increments whenever `forecast` changes (a new body, or data loaded from the disk cache).
    public let version: Int
    /// Instant temperatures of past steps seen in earlier responses (time → °C), so that today's high and low do not
    /// shrink as the hours pass and MET drops them from the series.
    public let pastTemperatures: [Date: Double]

    public init(forecast: WeatherForecast? = nil, fetchedAt: Date? = nil, validatedAt: Date? = nil,
                expiresLocal: Date? = nil, lastFailure: Failure? = nil, failureStreak: Int = 0, isFetching: Bool = false,
                version: Int = 0, pastTemperatures: [Date: Double] = [:]) {
        self.forecast = forecast
        self.fetchedAt = fetchedAt
        self.validatedAt = validatedAt
        self.expiresLocal = expiresLocal
        self.lastFailure = lastFailure
        self.failureStreak = failureStreak
        self.isFetching = isFetching
        self.version = version
        self.pastTemperatures = pastTemperatures
    }

    /// A copy with some fields changed (`nil` arguments keep the current value; use the `clear…` flags to remove).
    func with(forecast: WeatherForecast? = nil, fetchedAt: Date? = nil, validatedAt: Date? = nil,
              expiresLocal: Date? = nil, failure: Failure?? = nil, failureStreak: Int? = nil, isFetching: Bool? = nil,
              version: Int? = nil, pastTemperatures: [Date: Double]? = nil) -> WeatherSnapshot {
        WeatherSnapshot(forecast: forecast ?? self.forecast, fetchedAt: fetchedAt ?? self.fetchedAt,
                        validatedAt: validatedAt ?? self.validatedAt, expiresLocal: expiresLocal ?? self.expiresLocal,
                        lastFailure: failure ?? self.lastFailure, failureStreak: failureStreak ?? self.failureStreak,
                        isFetching: isFetching ?? self.isFetching, version: version ?? self.version,
                        pastTemperatures: pastTemperatures ?? self.pastTemperatures)
    }

    // MARK: Memoized derived values

    private let memoLock = NSLock()
    private var dailyMemo: [String: [WeatherDay]] = [:]

    /// Daily summaries (Day 0…9) for the local day of `now` in `zone` (memoized per zone and local date).
    public func days(zone: TimeZone, now: Date) -> [WeatherDay] {
        guard let forecast else { return [] }
        let start = WeatherTimeline.startOfDay(now, zone: zone)
        let key = "\(zone.identifier)|\(zone.secondsFromGMT(for: now))|\(Int(start.timeIntervalSince1970))"
        memoLock.lock()
        if let cached = dailyMemo[key] {
            memoLock.unlock()
            return cached
        }
        memoLock.unlock()
        let days = WeatherTimeline.days(forecast, zone: zone, now: now, past: pastTemperatures)
        memoLock.lock()
        if dailyMemo.count >= 8 { dailyMemo.removeAll() }
        dailyMemo[key] = days
        memoLock.unlock()
        return days
    }
}
