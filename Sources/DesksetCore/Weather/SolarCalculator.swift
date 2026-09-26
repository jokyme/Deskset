import Foundation

// Sun and moon, computed on the Mac: no network, no location sent anywhere. The sun follows the NOAA Global Monitoring
// Laboratory's published solar calculation equations (after Meeus, Astronomical Algorithms), written from the
// equations alone; the moon uses the mean synodic month (approximate: within about a day).

/// A sun event of a local day.
public enum SolarEvent: String, CaseIterable, Equatable {
    case sunrise, sunset
    case civilDawn, civilDusk
    case nauticalDawn, nauticalDusk
    case astronomicalDawn, astronomicalDusk
    /// The sun 6° above the horizon: the morning golden hour ends, the evening one starts.
    case goldenHourMorningEnd, goldenHourEveningStart

    /// Zenith angle of the sun's centre at the event: 90.833° for sunrise and sunset (refraction and the sun's
    /// radius), 96° civil, 102° nautical, 108° astronomical, 84° golden hour.
    public var zenith: Double {
        switch self {
        case .sunrise, .sunset: return 90.833
        case .civilDawn, .civilDusk: return 96
        case .nauticalDawn, .nauticalDusk: return 102
        case .astronomicalDawn, .astronomicalDusk: return 108
        case .goldenHourMorningEnd, .goldenHourEveningStart: return 84
        }
    }

    public var isMorning: Bool {
        switch self {
        case .sunrise, .civilDawn, .nauticalDawn, .astronomicalDawn, .goldenHourMorningEnd: return true
        default: return false
        }
    }
}

public enum SolarEventResult: Equatable {
    case time(Date)
    /// The sun stays above that angle all day (polar day for sunrise / sunset).
    case alwaysAbove
    /// The sun never gets that high (polar night for sunrise / sunset).
    case alwaysBelow

    public var date: Date? {
        if case .time(let d) = self { return d }
        return nil
    }
}

public enum SolarCalculator {
    static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Declination (degrees) and equation of time (minutes) at a Julian day.
    static func sun(julianDay jd: Double) -> (declination: Double, equationOfTime: Double) {
        let t = (jd - 2_451_545) / 36_525
        var l0 = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        if l0 < 0 { l0 += 360 }
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(rad(2 * m)) * (0.019993 - 0.000101 * t)
            + sin(rad(3 * m)) * 0.000289
        let trueLongitude = l0 + c
        let omega = 125.04 - 1934.136 * t
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(rad(omega))
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(rad(omega))
        let declination = deg(asin(sin(rad(obliquity)) * sin(rad(apparentLongitude))))
        let y = pow(tan(rad(obliquity / 2)), 2)
        let eot = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m)) + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
                          - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        return (declination, eot)
    }

    /// The sun's elevation above the horizon (degrees, geometric: no refraction) and azimuth (degrees from north,
    /// clockwise) at an instant.
    public static func position(at date: Date, latitude: Double, longitude: Double) -> (elevation: Double, azimuth: Double) {
        let s = sun(julianDay: julianDay(date))
        let seconds = date.timeIntervalSince1970
        let minutesUTC = (seconds.truncatingRemainder(dividingBy: 86_400) + 86_400)
            .truncatingRemainder(dividingBy: 86_400) / 60
        var trueSolarTime = (minutesUTC + s.equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolarTime < 0 { trueSolarTime += 1440 }
        let hourAngle = trueSolarTime / 4 < 0 ? trueSolarTime / 4 + 180 : trueSolarTime / 4 - 180
        let lat = rad(latitude), dec = rad(s.declination)
        let cosZenith = min(max(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(rad(hourAngle)), -1), 1)
        let zenith = acos(cosZenith)
        var azimuth: Double
        let denominator = cos(lat) * sin(zenith)
        if abs(denominator) > 1e-9 {
            let a = min(max((sin(lat) * cos(zenith) - sin(dec)) / denominator, -1), 1)
            let angle = deg(acos(a))
            azimuth = hourAngle > 0 ? (angle + 180).truncatingRemainder(dividingBy: 360)
                : (540 - angle).truncatingRemainder(dividingBy: 360)
        } else {
            azimuth = latitude > 0 ? 180 : 0
        }
        if azimuth < 0 { azimuth += 360 }
        return (90 - deg(zenith), azimuth)
    }

    /// The instant of solar noon nearest to `around`.
    static func transit(near around: Date, longitude: Double, equationOfTime eot: Double) -> Date {
        let seconds = around.timeIntervalSince1970
        let midnight = (seconds / 86_400).rounded(.down) * 86_400
        var noon = midnight + (720 - 4 * longitude - eot) * 60
        while noon - seconds > 43_200 { noon -= 86_400 }
        while seconds - noon > 43_200 { noon += 86_400 }
        return Date(timeIntervalSince1970: noon)
    }

    /// Solar noon of the local day that starts at `dayStart` (local midnight in `zone`).
    public static func solarNoon(dayStart: Date, zone: TimeZone, longitude: Double) -> Date {
        let localNoon = localNoonInstant(dayStart: dayStart, zone: zone)
        var t = localNoon
        for _ in 0..<3 {
            t = transit(near: localNoon, longitude: longitude, equationOfTime: sun(julianDay: julianDay(t)).equationOfTime)
        }
        return t
    }

    static func localNoonInstant(dayStart: Date, zone: TimeZone) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart) ?? dayStart.addingTimeInterval(43_200)
    }

    /// An event of the local day that starts at `dayStart`: from local noon, the event is computed, then computed
    /// again with the sun's declination and the equation of time at that moment (twice more: sub-minute).
    public static func event(_ event: SolarEvent, dayStart: Date, zone: TimeZone, latitude: Double,
                             longitude: Double) -> SolarEventResult {
        let localNoon = localNoonInstant(dayStart: dayStart, zone: zone)
        let lat = rad(min(max(latitude, -89.999), 89.999))
        var t = localNoon
        for _ in 0..<3 {
            let s = sun(julianDay: julianDay(t))
            let dec = rad(s.declination)
            let cosH = (cos(rad(event.zenith)) - sin(lat) * sin(dec)) / (cos(lat) * cos(dec))
            if cosH > 1 { return .alwaysBelow }
            if cosH < -1 { return .alwaysAbove }
            let h = deg(acos(cosH))
            let noon = transit(near: localNoon, longitude: longitude, equationOfTime: s.equationOfTime)
            t = noon.addingTimeInterval((event.isMorning ? -h : h) * 4 * 60)
        }
        return .time(t)
    }

    /// Sunrise, sunset and what follows from them for one local day.
    public struct Day: Equatable {
        public var sunrise: SolarEventResult
        public var sunset: SolarEventResult
        public var solarNoon: Date
        public var dayStart: Date
        public var dayEnd: Date

        /// Seconds of daylight (86 400 in polar day, 0 in polar night).
        public var length: TimeInterval {
            switch (sunrise, sunset) {
            case (.time(let a), .time(let b)): return max(0, b.timeIntervalSince(a))
            case (.alwaysAbove, _), (_, .alwaysAbove): return dayEnd.timeIntervalSince(dayStart)
            default: return 0
            }
        }

        /// 0 before sunrise, 0…1 through the day, 1 after sunset; polar day: the share of the local day gone;
        /// polar night: 0.
        public func progress(at now: Date) -> Double {
            switch (sunrise, sunset) {
            case (.time(let a), .time(let b)):
                if now <= a { return 0 }
                if now >= b { return 1 }
                return now.timeIntervalSince(a) / b.timeIntervalSince(a)
            case (.alwaysAbove, _), (_, .alwaysAbove):
                let total = dayEnd.timeIntervalSince(dayStart)
                return total > 0 ? min(max(now.timeIntervalSince(dayStart) / total, 0), 1) : 0
            default:
                return 0
            }
        }

        /// 0 normal day, 1 polar day (the sun stays up), 2 polar night.
        public var state: Int {
            if case .alwaysAbove = sunrise { return 1 }
            if case .alwaysBelow = sunrise { return 2 }
            return 0
        }
    }

    /// A length of time as "h:mm" (day lengths: "11:54").
    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        let m = minutes % 60
        return "\(minutes / 60):\(m < 10 ? "0" : "")\(m)"
    }

    public static func day(containing date: Date, zone: TimeZone, latitude: Double, longitude: Double,
                           offset: Int = 0) -> Day {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        let today = c.startOfDay(for: date)
        let start = c.date(byAdding: .day, value: offset, to: today) ?? today
        let end = c.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return Day(sunrise: event(.sunrise, dayStart: start, zone: zone, latitude: latitude, longitude: longitude),
                   sunset: event(.sunset, dayStart: start, zone: zone, latitude: latitude, longitude: longitude),
                   solarNoon: solarNoon(dayStart: start, zone: zone, longitude: longitude), dayStart: start, dayEnd: end)
    }
}

/// The moon's phase from the mean synodic month (approximate: within about a day).
public enum MoonPhase {
    public static let synodicMonth = 29.530588853
    /// A new moon: 2000-01-06 18:14 UTC.
    public static let referenceNewMoon = Date(timeIntervalSince1970: 947_182_440)

    /// 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
    public static func phase(at date: Date) -> Double {
        let days = date.timeIntervalSince(referenceNewMoon) / 86_400
        var p = (days / synodicMonth).truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        return p
    }

    /// Lit fraction of the disc, 0…100.
    public static func illumination(phase: Double) -> Double { (1 - cos(2 * .pi * phase)) / 2 * 100 }

    public static let names = ["New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous", "Full Moon",
                               "Waning Gibbous", "Last Quarter", "Waning Crescent"]

    /// Eighth of the cycle (0 new … 7 waning crescent).
    public static func eighth(phase: Double) -> Int { Int((phase * 8).rounded()) % 8 }
}
