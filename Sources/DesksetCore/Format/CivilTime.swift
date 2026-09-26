import Foundation

/// Broken-down wall-clock time in the proleptic Gregorian calendar, computed with integer arithmetic only
/// (no `Calendar`, no locale), so Time measure formatting is deterministic and cheap.
struct CivilTime: Equatable {
    var year: Int
    var month: Int      // 1…12
    var day: Int        // 1…31
    var hour: Int       // 0…23
    var minute: Int     // 0…59
    var second: Int     // 0…59
    var weekday: Int    // 0 = Sunday … 6 = Saturday
    var yearDay: Int    // 0-based day of the year (0…365)
    /// Days since 1970-01-01.
    var dayNumber: Int

    static let secondsPerDay = 86_400
    /// Wall-clock seconds are clamped to ±1e13 (about ±317,000 years) so the integer math can never overflow.
    static let maxAbsSeconds: Double = 1e13

    /// Clamps and floors a (possibly non-finite) seconds count to a safe integer.
    static func safeSeconds(_ raw: Double) -> Int {
        guard !raw.isNaN else { return 0 }
        let clamped = min(max(raw, -maxAbsSeconds), maxAbsSeconds)
        return Int(clamped.rounded(.down))
    }

    /// Fields of the wall-clock time `wallSeconds` seconds after 1970-01-01 00:00 (no time zone applied).
    init(wallSeconds: Int) {
        let s = min(max(wallSeconds, -Int(CivilTime.maxAbsSeconds)), Int(CivilTime.maxAbsSeconds))
        let days = CivilTime.floorDiv(s, CivilTime.secondsPerDay)
        let secOfDay = s - days * CivilTime.secondsPerDay
        let (y, m, d) = CivilTime.civilFromDays(days)
        year = y
        month = m
        day = d
        hour = secOfDay / 3600
        minute = (secOfDay % 3600) / 60
        second = secOfDay % 60
        weekday = CivilTime.weekday(ofDay: days)
        yearDay = days - CivilTime.daysFromCivil(y, 1, 1)
        dayNumber = days
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }

    static func floorMod(_ a: Int, _ b: Int) -> Int {
        a - floorDiv(a, b) * b
    }

    /// 0 = Sunday. 1970-01-01 was a Thursday.
    static func weekday(ofDay days: Int) -> Int {
        floorMod(days + 4, 7)
    }

    /// Days since 1970-01-01 of the given proleptic Gregorian date (month 1…12; day may be out of range —
    /// it is then simply added).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    static func isLeapYear(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func wallSeconds(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int {
        daysFromCivil(year, month, day) * secondsPerDay + hour * 3600 + minute * 60 + second
    }

    /// Hour on a 12-hour clock (1…12).
    var hour12: Int { hour % 12 == 0 ? 12 : hour % 12 }

    /// ISO 8601 weekday, Monday = 1 … Sunday = 7.
    var isoWeekday: Int { weekday == 0 ? 7 : weekday }

    /// Week of the year, first Sunday = first day of week 1 (`%U`, 00…53).
    var weekOfYearSunday: Int { (yearDay + 7 - weekday) / 7 }

    /// Week of the year, first Monday = first day of week 1 (`%W`, 00…53).
    var weekOfYearMonday: Int { (yearDay + 7 - (weekday + 6) % 7) / 7 }

    /// ISO 8601 week-based year and week number (`%G`, `%V`).
    var isoWeek: (year: Int, week: Int) {
        let mondayBased = (weekday + 6) % 7                 // 0 = Monday
        let thursday = dayNumber - mondayBased + 3           // Thursday of this ISO week
        let isoYear = CivilTime.civilFromDays(thursday).year
        let week = (thursday - CivilTime.daysFromCivil(isoYear, 1, 1)) / 7 + 1
        return (isoYear, week)
    }
}
