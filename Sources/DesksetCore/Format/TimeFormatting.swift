import Foundation

// Time measure formatting. Clean-room implementation from the public manual only:
//   https://docs.rainmeter.net/manual/measures/time/   (Format codes, FormatLocale, TimeZone,
//       DaylightSavingTime, TimeStamp, TimeStampFormat, TimeStampLocale)
//   https://docs.rainmeter.net/manual/variables/section-variables/ ([Measure:Timestamp])
//   https://docs.rainmeter.net/history/ (Format is converted to the number value, e.g. %S → 0…59)
// Every place where the manual is silent is marked "Judgment:".
//
// Engine usage sketch for a Time measure:
//   zone   = TimeFormatting.timeZone(forOption: TimeZone=, daylightSavingTime: DaylightSavingTime= != 0)
//   locale = TimeFormatting.locale(fromOption: FormatLocale=) ?? TimeFormatting.defaultLocale
//   if TimeStamp= is set:
//       ts   = TimeFormatting.parseTimeStamp(TimeStamp=, format: TimeStampFormat=,
//                                            locale: TimeFormatting.locale(fromOption: TimeStampLocale=)) ?? 0
//       text = TimeFormatting.format(windowsTimestamp: ts, format: Format= ?? defaultFormat, locale: locale)
//   else:
//       ts   = TimeFormatting.measureValue(for: now, timeZone: zone)
//       text = TimeFormatting.format(now, format: Format= ?? defaultFormat, timeZone: zone, locale: locale)
//   number = Format= set ? TimeFormatting.numberValue(ofFormatted: text) : ts      ([M:Timestamp] = ts)
// TimeZone= does not apply to a TimeStamp= (manual: a formatted TimeStamp "cannot be modified with the TimeZone
// option"; Judgment: the same for a numeric TimeStamp, which is already a wall-clock value). Formulas in
// TimeZone= / TimeStamp= are evaluated by the caller; these helpers take plain numbers.

public enum TimeFormatting {
    /// Seconds between 1601-01-01 00:00 UTC (the Time measure's number epoch) and 1970-01-01 00:00 UTC.
    public static let windowsEpochOffset: TimeInterval = 11_644_473_600

    /// The manual: "Format Default: %H:%M:%S".
    public static let defaultFormat = "%H:%M:%S"

    /// The manual's "FormatLocale Default: A standard English format". Passing this locale (the default of
    /// every `locale:` parameter) selects fixed English names and the C-locale patterns shown in the manual.
    public static let defaultLocale = Locale(identifier: "en_US_POSIX")

    static func isDefaultLocaleIdentifier(_ id: String) -> Bool {
        id == "en_US_POSIX" || id == "C" || id == "POSIX" || id.isEmpty
    }

    // MARK: - Formatting

    /// Formats `date` with a Time measure `Format=` string: strftime-style codes (`%H %M %S %I %p %a %A %b %B
    /// %d %j %m %y %Y %Z %z %c %x %X %U %W %w %%` …) plus the `#` flag that removes leading zeros (`%#H`),
    /// and the Rainmeter-specific codes the manual lists. `locale` drives day/month names (FormatLocale).
    ///
    /// Codes (manual "Format codes" table): `%a %A %b %B %c %#c %C %d %D %e %F %g %G %h %H %I %j %m %M %n %p
    /// %r %R %S %t %T %u %U %V %w %W %x %#x %X %y %Y %z %Z %%`; `#` removes leading zeros from
    /// `d H I j m M S U w W y Y` (ignored on other codes); the `E` / `O` modifiers ("system locale alternative
    /// representation") are accepted and render the plain code. A whole `Format=locale-date` / `locale-time`
    /// gives the system locale's default date / time (not affected by FormatLocale).
    ///
    /// With the default locale the locale-dependent codes use the manual's examples ("standard English"):
    /// `%c` = `Sat Dec 26 22:55:03 2015` (`%a %b %e %H:%M:%S %Y`), `%#c` = `Saturday, December 26, 2015, 22:55:03`,
    /// `%x` = `12/26/15`, `%#x` = `Saturday, December 26, 2015`, `%X` = `22:55:03`, `%p` = `AM`/`PM`.
    /// With another locale they use its short date / full (long) date / medium time patterns
    /// (`%#c` for de-DE = `Mittwoch, 18. Februar 2015 01:07:40`, as in the manual).
    ///
    /// Judgment calls: `%r` = `%I:%M:%S %p` ("10:55:03 PM" — the manual's example shows "pm" but `%p` is
    /// documented as AM/PM); `%Z` is the name of the zone used for formatting in the *system* locale, as the
    /// manual says, never FormatLocale ("Eastern Standard Time" on an English system, "GMT-05:00" for a numeric
    /// TimeZone=); `%Y` / `%G` have at least 4 digits (`%#Y` removes the leading zeros); `%a %A %b %B` use the
    /// locale's stand-alone names (ru `%B` = "февраль", not the genitive "февраля"); unknown codes (e.g. `%Q`) and
    /// a lone trailing `%` are copied literally instead of failing the whole measure; an empty `format` means the
    /// default `%H:%M:%S`.
    public static func format(_ date: Date, format: String, timeZone: TimeZone = .current,
                              locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let t = date.timeIntervalSince1970
        guard t.isFinite else { return "" }
        let offset = timeZone.secondsFromGMT(for: date)
        let wall = CivilTime.safeSeconds(t + Double(offset))
        let zone = ZoneContext(offsetSeconds: offset, timeZone: timeZone,
                               isDaylight: timeZone.isDaylightSavingTime(for: date))
        return render(wallSeconds: wall, format: format, zone: zone, locale: locale)
    }

    /// Formats a Windows timestamp (seconds since 1601-01-01, a wall-clock value as produced by `TimeStamp=`
    /// or `measureValue`). No time zone conversion is applied (the manual: a timestamp is "independent of any
    /// time zone"); `nameTimeZone` only supplies `%z` / `%Z` (Judgment: the local zone, like the system would).
    public static func format(windowsTimestamp: Double, format: String,
                              locale: Locale = Locale(identifier: "en_US_POSIX"),
                              nameTimeZone: TimeZone = .current) -> String {
        guard windowsTimestamp.isFinite else { return "" }
        let wall = CivilTime.safeSeconds(windowsTimestamp - windowsEpochOffset)
        // The instant this wall-clock time corresponds to in `nameTimeZone` (approximate around transitions).
        let guess = Date(timeIntervalSince1970: TimeInterval(wall))
        let instant = Date(timeIntervalSince1970: TimeInterval(wall - nameTimeZone.secondsFromGMT(for: guess)))
        let zone = ZoneContext(offsetSeconds: nameTimeZone.secondsFromGMT(for: instant), timeZone: nameTimeZone,
                               isDaylight: nameTimeZone.isDaylightSavingTime(for: instant))
        return render(wallSeconds: wall, format: format, zone: zone, locale: locale)
    }

    // MARK: - Number values

    /// The Time measure number value for `date`: seconds since 1601-01-01 in the measure's time zone,
    /// as the manual specifies (local vs. UTC).
    ///
    /// The manual calls it a "Windows timestamp … in one-second increments since January 1, 1601"; with
    /// `TimeZone=` "GMT time is used, modified with the offset", otherwise local time — so the value counts
    /// wall-clock seconds of the measure's zone (local time by default). Judgment: whole seconds (floored).
    /// Only the number value when `Format=` is NOT set; see `numberValue(ofFormatted:)`.
    public static func measureValue(for date: Date, timeZone: TimeZone = .current) -> Double {
        let t = date.timeIntervalSince1970
        guard t.isFinite else { return 0 }
        let wall = CivilTime.safeSeconds(t + Double(timeZone.secondsFromGMT(for: date)))
        return Double(wall) + windowsEpochOffset
    }

    /// The instant whose wall-clock time in `timeZone` is the Windows timestamp `windowsTimestamp`
    /// (inverse of `measureValue`, approximate inside DST transitions).
    public static func date(fromWindowsTimestamp windowsTimestamp: Double, timeZone: TimeZone = .current) -> Date {
        guard windowsTimestamp.isFinite else { return Date(timeIntervalSince1970: 0) }
        let wall = Double(CivilTime.safeSeconds(windowsTimestamp - windowsEpochOffset))
        let guess = Date(timeIntervalSince1970: wall)
        let first = wall - Double(timeZone.secondsFromGMT(for: guess))
        let second = wall - Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: first)))
        return Date(timeIntervalSince1970: second)
    }

    /// The number value of a Time measure that has `Format=`: "the value defined by the format, or zero if the
    /// format does not define a numeric value" (release notes: `Format=%S` gives 0…59).
    /// Judgment: the leading number of the formatted text, like C `atof` (leading whitespace skipped, optional
    /// sign, digits, fraction, exponent): "07" → 7, "3:22" → 3, "20150127" → 20150127, "Tuesday" → 0.
    public static func numberValue(ofFormatted text: String) -> Double {
        // Collect the leading run of characters that can belong to a number (bounded to 64 characters).
        var s: [UInt8] = []
        s.reserveCapacity(24)
        var started = false
        for b in text.utf8 {
            if !started {
                if b == 0x20 || (0x09...0x0D).contains(b) { continue }
                started = true
            }
            let isNumberChar = (0x30...0x39).contains(b) || b == 0x2B || b == 0x2D || b == 0x2E || b == 0x65 || b == 0x45
            guard isNumberChar, s.count < 64 else { break }
            s.append(b)
        }
        // The longest prefix of that run that is a valid number with at least one digit ("3:22" → "3",
        // "12-05-2015" → "12", "1e5" → 100000).
        var end = s.count
        while end > 0 {
            let prefix = s[0..<end]
            if prefix.contains(where: { (0x30...0x39).contains($0) }),
               let v = Double(String(decoding: prefix, as: UTF8.self)), v.isFinite {
                return v
            }
            end -= 1
        }
        return 0
    }

    // MARK: - Options

    /// Resolves `TimeZone=` / `DaylightSavingTime=`.
    ///
    /// The manual: "If specified, GMT time is used, modified with the specified positive or negative offset
    /// number (TimeZone=-5 → GMT -5.0). If not specified, or set to local, local time for the computer is used."
    /// "If DaylightSavingTime is set to 0 and TimeZone is supplied, the current local offset for Daylight Saving
    /// Time is not applied" — so with the default `DaylightSavingTime=1` the local DST offset *currently* in
    /// effect (at `date`) is added to the numeric offset. Fractional hours are allowed (`5.5` → GMT+05:30).
    /// `option` must already be a number (evaluate formulas first); nil / empty / `local` / unparsable → local.
    /// Judgment: offsets are rounded to whole minutes and clamped to ±18 h (Foundation's limit).
    public static func timeZone(forOption option: String?, daylightSavingTime: Bool = true, at date: Date = Date(),
                                localTimeZone: TimeZone = .current) -> TimeZone {
        guard let raw = option?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.lowercased() != "local", let hours = Double(raw) else { return localTimeZone }
        return timeZone(offsetHours: hours, daylightSavingTime: daylightSavingTime, at: date, localTimeZone: localTimeZone)
    }

    /// Numeric form of `timeZone(forOption:)` (TimeZone= as an already evaluated formula).
    public static func timeZone(offsetHours hours: Double, daylightSavingTime: Bool = true, at date: Date = Date(),
                                localTimeZone: TimeZone = .current) -> TimeZone {
        guard hours.isFinite else { return localTimeZone }
        let limit = 18.0 * 3600
        var seconds = min(max(hours * 3600, -limit), limit)
        if daylightSavingTime {
            seconds += localTimeZone.daylightSavingTimeOffset(for: date)
        }
        let minutes = Int((min(max(seconds, -limit), limit) / 60).rounded())
        return TimeZone(secondsFromGMT: minutes * 60) ?? localTimeZone
    }

    /// Parses a `FormatLocale=` / `TimeStampLocale=` value: culture names (`de-DE`), language name
    /// abbreviations (`FRA`), `Language_Country.codepage` (`Russian_Russia.1251`), plain ISO codes, and `Local`
    /// (the system locale). nil when empty or not recognised — the caller then uses `defaultLocale`.
    public static func locale(fromOption option: String?) -> Locale? {
        guard let option else { return nil }
        return WindowsLocaleNames.locale(from: option)
    }

    // MARK: - Rendering

    struct ZoneContext {
        var offsetSeconds: Int
        var timeZone: TimeZone
        var isDaylight: Bool
    }

    static func render(wallSeconds: Int, format: String, zone: ZoneContext, locale: Locale) -> String {
        var fmt = format
        if fmt.isEmpty { fmt = defaultFormat }
        let t = CivilTime(wallSeconds: wallSeconds)
        // `locale-date` / `locale-time`: the system locale's default date / time (never FormatLocale).
        if fmt.utf8.count == 11 {
            switch fmt.lowercased() {
            case "locale-date":
                return LocaleTimeInfo.info(for: .current).string(.shortDate, wallSeconds: wallSeconds)
                    ?? render(t, wallSeconds: wallSeconds, format: "%x", zone: zone, info: .english)
            case "locale-time":
                return LocaleTimeInfo.info(for: .current).string(.mediumTime, wallSeconds: wallSeconds)
                    ?? render(t, wallSeconds: wallSeconds, format: "%X", zone: zone, info: .english)
            default: break
            }
        }
        return render(t, wallSeconds: wallSeconds, format: fmt, zone: zone, info: LocaleTimeInfo.info(for: locale))
    }

    private static func render(_ t: CivilTime, wallSeconds: Int, format: String, zone: ZoneContext,
                               info: LocaleTimeInfo) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(format.utf8.count + 16)
        let fmt = Array(format.utf8)
        renderBytes(t, wallSeconds: wallSeconds, fmt: fmt, zone: zone, info: info, depth: 0, out: &out)
        return String(decoding: out, as: UTF8.self)
    }

    // Composite English patterns (manual examples).
    private static let englishC: [UInt8] = Array("%a %b %e %H:%M:%S %Y".utf8)
    private static let englishLongC: [UInt8] = Array("%A, %B %#d, %Y, %H:%M:%S".utf8)
    private static let englishX: [UInt8] = Array("%m/%d/%y".utf8)
    private static let englishLongX: [UInt8] = Array("%A, %B %#d, %Y".utf8)
    private static let englishTime: [UInt8] = Array("%H:%M:%S".utf8)
    private static let patD: [UInt8] = Array("%m/%d/%y".utf8)
    private static let patF: [UInt8] = Array("%Y-%m-%d".utf8)
    private static let patR12: [UInt8] = Array("%I:%M:%S %p".utf8)
    private static let patR24: [UInt8] = Array("%H:%M".utf8)
    private static let patT: [UInt8] = Array("%H:%M:%S".utf8)

    private static let percent = UInt8(ascii: "%")

    private static func renderBytes(_ t: CivilTime, wallSeconds: Int, fmt: [UInt8], zone: ZoneContext,
                                    info: LocaleTimeInfo, depth: Int, out: inout [UInt8]) {
        guard depth < 3 else { return }
        let n = fmt.count
        var i = 0
        func sub(_ pattern: [UInt8]) {
            renderBytes(t, wallSeconds: wallSeconds, fmt: pattern, zone: zone, info: info, depth: depth + 1, out: &out)
        }
        func text(_ s: String) { out.append(contentsOf: s.utf8) }
        func num(_ v: Int, _ width: Int, _ strip: Bool, pad: UInt8 = UInt8(ascii: "0")) {
            appendNumber(v, width: strip ? 1 : width, pad: pad, into: &out)
        }
        func pattern(_ p: LocaleTimeInfo.Pattern) -> String? {
            info.string(p, wallSeconds: wallSeconds)
        }
        while i < n {
            let c = fmt[i]
            if c != percent {
                var j = i + 1
                while j < n && fmt[j] != percent { j += 1 }
                out.append(contentsOf: fmt[i..<j])
                i = j
                continue
            }
            let start = i
            i += 1
            var hash = false
            // Modifiers: '#' (remove leading zeros / long form) and 'E' / 'O' (alternative representation).
            while i < n, i - start <= 3,
                  fmt[i] == UInt8(ascii: "#") || fmt[i] == UInt8(ascii: "E") || fmt[i] == UInt8(ascii: "O") {
                if fmt[i] == UInt8(ascii: "#") { hash = true }
                i += 1
            }
            guard i < n else {
                out.append(contentsOf: fmt[start..<n])   // lone trailing '%' (or '%#') → literal
                break
            }
            let code = fmt[i]
            i += 1
            switch code {
            case UInt8(ascii: "a"): text(info.shortWeekdays[t.weekday])
            case UInt8(ascii: "A"): text(info.weekdays[t.weekday])
            case UInt8(ascii: "b"), UInt8(ascii: "h"): text(info.shortMonths[t.month - 1])
            case UInt8(ascii: "B"): text(info.months[t.month - 1])
            case UInt8(ascii: "c"):
                if info.isEnglishDefault {
                    sub(hash ? englishLongC : englishC)
                } else if let d = pattern(hash ? .fullDate : .shortDate), let tm = pattern(.mediumTime) {
                    text(d + " " + tm)
                }
            case UInt8(ascii: "C"): num(CivilTime.floorDiv(t.year, 100), 2, false)
            case UInt8(ascii: "d"): num(t.day, 2, hash)
            case UInt8(ascii: "D"): sub(patD)
            case UInt8(ascii: "e"): num(t.day, 2, false, pad: UInt8(ascii: " "))
            case UInt8(ascii: "F"): sub(patF)
            case UInt8(ascii: "g"): num(CivilTime.floorMod(t.isoWeek.year, 100), 2, false)
            // %Y / %G: at least 4 digits like C strftime (the manual lists %#Y among the codes whose leading
            // zeros `#` removes, so %Y itself is zero padded: year 915 → "0915", %#Y → "915").
            case UInt8(ascii: "G"): num(t.isoWeek.year, 4, false)
            case UInt8(ascii: "H"): num(t.hour, 2, hash)
            case UInt8(ascii: "I"): num(t.hour12, 2, hash)
            case UInt8(ascii: "j"): num(t.yearDay + 1, 3, hash)
            case UInt8(ascii: "m"): num(t.month, 2, hash)
            case UInt8(ascii: "M"): num(t.minute, 2, hash)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "p"): text(t.hour < 12 ? info.am : info.pm)
            case UInt8(ascii: "r"): sub(patR12)
            case UInt8(ascii: "R"): sub(patR24)
            case UInt8(ascii: "S"): num(t.second, 2, hash)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "T"): sub(patT)
            case UInt8(ascii: "u"): num(t.isoWeekday, 1, false)
            case UInt8(ascii: "U"): num(t.weekOfYearSunday, 2, hash)
            case UInt8(ascii: "V"): num(t.isoWeek.week, 2, false)
            case UInt8(ascii: "w"): num(t.weekday, 1, hash)
            case UInt8(ascii: "W"): num(t.weekOfYearMonday, 2, hash)
            case UInt8(ascii: "x"):
                if info.isEnglishDefault {
                    sub(hash ? englishLongX : englishX)
                } else if let d = pattern(hash ? .fullDate : .shortDate) {
                    text(d)
                }
            case UInt8(ascii: "X"):
                if info.isEnglishDefault {
                    sub(englishTime)
                } else if let tm = pattern(.mediumTime) {
                    text(tm)
                }
            case UInt8(ascii: "y"): num(CivilTime.floorMod(t.year, 100), 2, hash)
            case UInt8(ascii: "Y"): num(t.year, 4, hash)
            case UInt8(ascii: "z"):
                let off = zone.offsetSeconds
                out.append(off < 0 ? UInt8(ascii: "-") : UInt8(ascii: "+"))
                let a = abs(off) / 60
                num(a / 60, 2, false)
                num(a % 60, 2, false)
            case UInt8(ascii: "Z"): text(TimeZoneNames.name(of: zone.timeZone, daylight: zone.isDaylight))
            case percent: out.append(percent)
            default:
                out.append(contentsOf: fmt[start..<i])   // unknown code → literal
            }
        }
    }

    /// Appends `v` in decimal, left-padded with `pad` to `width` characters (sign counted after padding).
    static func appendNumber(_ v: Int, width: Int, pad: UInt8, into out: inout [UInt8]) {
        var digits: [UInt8] = []
        digits.reserveCapacity(20)
        var m = v.magnitude
        repeat {
            digits.append(UInt8(ascii: "0") + UInt8(m % 10))
            m /= 10
        } while m > 0
        if v < 0 { out.append(UInt8(ascii: "-")) }
        if digits.count < width {
            out.append(contentsOf: repeatElement(pad, count: width - digits.count))
        }
        out.append(contentsOf: digits.reversed())
    }
}
