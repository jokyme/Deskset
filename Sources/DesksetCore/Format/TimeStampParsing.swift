import Foundation

// Time measure `TimeStamp=` / `TimeStampFormat=` / `TimeStampLocale=` (https://docs.rainmeter.net/manual/measures/time/).

extension TimeFormatting {
    /// Resolves a Time measure `TimeStamp=` option to a Windows timestamp (wall-clock seconds since 1601-01-01).
    /// Returns nil when the value cannot be resolved (the manual: "an error will be produced").
    ///
    /// Forms (manual):
    /// - A numeric Windows timestamp (formulas must be evaluated by the caller first): used as is.
    /// - `DSTNextStart`, `DSTNextEnd`, `DSTStart`, `DSTEnd`, `DSTStartYYYY`, `DSTEndYYYY` (case-insensitive):
    ///   "the local date and time" of that Daylight Saving Time transition, always from the local computer's zone
    ///   (`localTimeZone`), never TimeZone=. Judgment: the wall-clock time just before the transition
    ///   (e.g. 02:00 for both US transitions); nil when the zone has no such transition.
    /// - A formatted date/time string, which "MUST be used in conjunction with a matching TimeStampFormat";
    ///   see `parseTimeStamp(_:mask:locale:)`. When `format` (TimeStampFormat) is set, the mask decides: the
    ///   manual says "if the TimeStampFormat mask does not match the format of the TimeStamp option, an error will
    ///   be produced" → nil (a numeric TimeStamp is only read as a number when no TimeStampFormat is set).
    /// `now`, `localTimeZone` and `systemLocale` (a whole `locale-date` / `locale-time` mask) are the Mac's own
    /// unless the caller passes them (the engine passes the skin's clock, time zone and locale).
    public static func parseTimeStamp(_ timeStamp: String, format: String?, locale: Locale? = nil,
                                      now: Date, localTimeZone: TimeZone,
                                      systemLocale: Locale) -> Double? {
        let raw = timeStamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let dst = daylightSavingTimeStamp(raw, now: now, timeZone: localTimeZone) {
            return dst.value
        }
        if let mask = format, !mask.isEmpty {
            return parseTimeStamp(raw, mask: mask, locale: locale ?? defaultLocale, systemLocale: systemLocale,
                                  localTimeZone: localTimeZone)
        }
        if let v = Double(raw), v.isFinite { return v }
        return nil
    }

    /// Parses a formatted date/time string with a `TimeStampFormat=` mask into a Windows timestamp.
    ///
    /// The mask uses the Time Format codes and literal text (manual examples: `%Y-%m-%dT%H:%M:%SZ`,
    /// `%a, %#d %b %Y %H:%M:%S`, `%#m/%#d/%Y %H:%M:%S`, `%A, %B %#d, %Y at %H:%M:%S`, and with
    /// `TimeStampLocale=de-DE` `%A, %d. %b %Y %H:%M:%S`). "If the year is not defined … 1900 will be used";
    /// time zone information is not evaluated and the result is "independent of any time zone"; `%z` / `%Z`
    /// "cannot be used" (→ nil). `locale` supplies day/month/AM-PM names (TimeStampLocale).
    ///
    /// Judgment (strptime-like): numbers may have fewer digits than their field width and may be preceded by
    /// spaces; `%a`/`%A` and `%b`/`%B`/`%h` accept both abbreviated and full names (case-insensitive, English
    /// names are accepted as a fallback for other locales); whitespace in the mask (and `%n`, `%t`) matches any
    /// amount of whitespace; other literal text must match (case-insensitive); text left after the mask is
    /// ignored; `%D`, `%F`, `%r`, `%R`, `%T` expand to their fixed patterns; `%c`, `%#c`, `%x`, `%#x`, `%X` read the
    /// representation of `locale` (the manual: these codes return the representation "for the system locale or the
    /// locale defined by TimeStampLocale or FormatLocale" and are "particularly useful for easily changing between
    /// locale values from the input to the output"), i.e. exactly what `format` produces for that locale, with the
    /// English patterns as a fallback; digits may be any Unicode decimal digits (e.g. Arabic-Indic);
    /// `%y` 69–99 → 19xx, 00–68 → 20xx unless `%C` is given; `%j` sets the date when month and day are absent;
    /// `%I` uses `%p` (default AM); `%u %U %V %w %W %g %G` are read but ignored. Missing month / day → 1,
    /// missing time → 0. Out-of-range values (month 13, February 30, hour 24 …) → nil.
    public static func parseTimeStamp(_ string: String, mask: String, locale: Locale = Locale(identifier: "en_US_POSIX"),
                                      systemLocale: Locale,
                                      localTimeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Double? {
        guard string.count <= 4096, mask.count <= 1024 else { return nil }
        // `locale-date` / `locale-time` are listed among the codes "used in the Format and TimeStampFormat
        // options" and "cannot be modified by using TimeStampLocale": a whole mask of either reads the system
        // locale's default date / time — the same representation `format` produces for them.
        var info = LocaleTimeInfo.info(for: locale)
        var maskChars = Array(mask)
        if mask.utf8.count == 11 {
            switch mask.lowercased() {
            case "locale-date": info = LocaleTimeInfo.info(for: systemLocale); maskChars = ["%", "x"]
            case "locale-time": info = LocaleTimeInfo.info(for: systemLocale); maskChars = ["%", "X"]
            default: break
            }
        }
        var parser = MaskParser(input: string, info: info, localTimeZone: localTimeZone, systemLocale: systemLocale)
        guard parser.match(maskChars, depth: 0) else { return nil }
        return parser.fields.windowsTimestamp()
    }

    // MARK: - Daylight Saving Time codes

    struct DSTResult { var value: Double? }

    /// nil when `raw` is not a DST code; otherwise the (possibly missing) value.
    static func daylightSavingTimeStamp(_ raw: String, now: Date, timeZone: TimeZone) -> DSTResult? {
        let upper = raw.uppercased()
        guard upper.hasPrefix("DST") else { return nil }
        let nowWall = CivilTime.safeSeconds(now.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: now)))
        let currentYear = CivilTime(wallSeconds: nowWall).year
        func year(after prefix: String) -> Int?? {
            guard upper.hasPrefix(prefix) else { return nil }
            let rest = upper.dropFirst(prefix.count)
            if rest.isEmpty { return .some(currentYear) }
            guard rest.count <= 5, rest.allSatisfy({ $0.isASCII && $0.isNumber }), let y = Int(rest) else { return .some(nil) }
            return .some(y)
        }
        switch upper {
        case "DSTNEXTSTART": return DSTResult(value: nextTransition(start: true, after: now, timeZone: timeZone))
        case "DSTNEXTEND": return DSTResult(value: nextTransition(start: false, after: now, timeZone: timeZone))
        default: break
        }
        if let y = year(after: "DSTSTART") {
            return DSTResult(value: y.flatMap { transition(start: true, year: $0, timeZone: timeZone) })
        }
        if let y = year(after: "DSTEND") {
            return DSTResult(value: y.flatMap { transition(start: false, year: $0, timeZone: timeZone) })
        }
        return nil
    }

    /// Wall-clock Windows timestamp of a transition, expressed in the offset in effect just before it.
    private static func localTimestamp(ofTransition t: Date, timeZone: TimeZone) -> Double {
        let before = timeZone.secondsFromGMT(for: t.addingTimeInterval(-1))
        return Double(CivilTime.safeSeconds(t.timeIntervalSince1970 + Double(before))) + windowsEpochOffset
    }

    private static func isStart(_ t: Date, timeZone: TimeZone) -> Bool {
        timeZone.isDaylightSavingTime(for: t.addingTimeInterval(1)) && !timeZone.isDaylightSavingTime(for: t.addingTimeInterval(-1))
    }

    private static func isEnd(_ t: Date, timeZone: TimeZone) -> Bool {
        !timeZone.isDaylightSavingTime(for: t.addingTimeInterval(1)) && timeZone.isDaylightSavingTime(for: t.addingTimeInterval(-1))
    }

    private static func nextTransition(start: Bool, after now: Date, timeZone: TimeZone) -> Double? {
        var cursor = now
        for _ in 0..<8 {   // bounded: a zone has at most a few transitions a year
            guard let t = timeZone.nextDaylightSavingTimeTransition(after: cursor), t > cursor else { return nil }
            if start ? isStart(t, timeZone: timeZone) : isEnd(t, timeZone: timeZone) {
                return localTimestamp(ofTransition: t, timeZone: timeZone)
            }
            cursor = t
        }
        return nil
    }

    private static func transition(start: Bool, year: Int, timeZone: TimeZone) -> Double? {
        guard (1601...9999).contains(year) else { return nil }
        // Start a little before local midnight of January 1 (zones are within ±14 h of UTC).
        let jan1 = CivilTime.daysFromCivil(year, 1, 1) * CivilTime.secondsPerDay
        var cursor = Date(timeIntervalSince1970: TimeInterval(jan1 - 15 * 3600))
        for _ in 0..<12 {
            guard let t = timeZone.nextDaylightSavingTimeTransition(after: cursor), t > cursor else { return nil }
            let local = localTimestamp(ofTransition: t, timeZone: timeZone)
            let localYear = CivilTime(wallSeconds: CivilTime.safeSeconds(local - windowsEpochOffset)).year
            if localYear > year { return nil }
            if localYear == year, start ? isStart(t, timeZone: timeZone) : isEnd(t, timeZone: timeZone) {
                return local
            }
            cursor = t
        }
        return nil
    }
}

// MARK: - Mask parser

struct ParsedTimeFields {
    var year: Int?
    var yearInCentury: Int?
    var century: Int?
    var isoYear: Int?
    var isoYearInCentury: Int?
    var isoWeek: Int?
    var weekSunday: Int?
    var weekMonday: Int?
    var weekday: Int?
    var month: Int?
    var day: Int?
    var yearDay: Int?
    var hour24: Int?
    var hour12: Int?
    var isPM: Bool?
    var minute: Int?
    var second: Int?
    var tzOffsetSeconds: Int?
    var hasConflict = false

    mutating func set<T: Equatable>(_ keyPath: WritableKeyPath<ParsedTimeFields, T?>, _ value: T) {
        if let existing = self[keyPath: keyPath], existing != value {
            hasConflict = true
        }
        self[keyPath: keyPath] = value
    }

    func windowsTimestamp() -> Double? {
        guard !hasConflict else { return nil }
        let hasExplicitYear = year != nil || yearInCentury != nil || century != nil
        var y: Int
        if let year {
            if let yy = yearInCentury, ((year % 100) + 100) % 100 != yy { return nil }
            if let century, year / 100 != century { return nil }
            y = year
        } else if let yy = yearInCentury {
            if let century { y = century * 100 + yy } else { y = yy < 69 ? 2000 + yy : 1900 + yy }
        } else if let century {
            y = century * 100
        } else {
            y = 1900   // manual: "If the year is not defined in the TimeStamp option, then 1900 will be used"
        }

        var resolvedIsoYear: Int?
        if let isoYear {
            if let iyy = isoYearInCentury, ((isoYear % 100) + 100) % 100 != iyy { return nil }
            resolvedIsoYear = isoYear
        } else if let iyy = isoYearInCentury {
            if let century { resolvedIsoYear = century * 100 + iyy } else { resolvedIsoYear = iyy < 69 ? 2000 + iyy : 1900 + iyy }
        }

        if let wd = weekday {
            guard (0...6).contains(wd) else { return nil }
        }

        var m = month ?? 1
        var d = day ?? 1
        if month == nil, day == nil {
            if let yd = yearDay {
                guard yd >= 1, yd <= (CivilTime.isLeapYear(y) ? 366 : 365) else { return nil }
                let (_, mm, dd) = CivilTime.civilFromDays(CivilTime.daysFromCivil(y, 1, 1) + yd - 1)
                m = mm
                d = dd
            } else if let v = isoWeek {
                guard (1...53).contains(v) else { return nil }
                let wy = resolvedIsoYear ?? (hasExplicitYear ? y : 1900)
                let wd = weekday ?? 1 // Default to Monday (ISO day 1)
                let mondayBased = (wd + 6) % 7
                let jan4Days = CivilTime.daysFromCivil(wy, 1, 4)
                let jan4MondayBased = (CivilTime.weekday(ofDay: jan4Days) + 6) % 7
                let targetDays = (jan4Days - jan4MondayBased) + (v - 1) * 7 + mondayBased
                let check = CivilTime(wallSeconds: targetDays * CivilTime.secondsPerDay)
                guard check.isoWeek.year == wy, check.isoWeek.week == v else { return nil }
                if hasExplicitYear, check.year != y { return nil }
                y = check.year
                m = check.month
                d = check.day
            } else if let u = weekSunday {
                guard (0...53).contains(u) else { return nil }
                let wd = weekday ?? 0 // Default to Sunday
                let jan1Days = CivilTime.daysFromCivil(y, 1, 1)
                let jan1Wd = CivilTime.weekday(ofDay: jan1Days)
                let firstSundayYd = (7 - jan1Wd) % 7
                let yd0 = firstSundayYd + (u - 1) * 7 + wd
                guard yd0 >= 0, yd0 < (CivilTime.isLeapYear(y) ? 366 : 365) else { return nil }
                let (_, mm, dd) = CivilTime.civilFromDays(jan1Days + yd0)
                m = mm
                d = dd
            } else if let w = weekMonday {
                guard (0...53).contains(w) else { return nil }
                let wd = weekday ?? 1 // Default to Monday
                let mondayBasedWd = (wd + 6) % 7
                let jan1Days = CivilTime.daysFromCivil(y, 1, 1)
                let jan1MondayBased = (CivilTime.weekday(ofDay: jan1Days) + 6) % 7
                let firstMondayYd = (7 - jan1MondayBased) % 7
                let yd0 = firstMondayYd + (w - 1) * 7 + mondayBasedWd
                guard yd0 >= 0, yd0 < (CivilTime.isLeapYear(y) ? 366 : 365) else { return nil }
                let (_, mm, dd) = CivilTime.civilFromDays(jan1Days + yd0)
                m = mm
                d = dd
            } else if let wy = resolvedIsoYear, !hasExplicitYear {
                y = wy
            }
        }
        guard (1...12).contains(m), d >= 1, d <= CivilTime.daysInMonth(y, m) else { return nil }

        let resolvedDays = CivilTime.daysFromCivil(y, m, d)
        let resolvedCivil = CivilTime(wallSeconds: resolvedDays * CivilTime.secondsPerDay)
        if let yd = yearDay, resolvedCivil.yearDay + 1 != yd { return nil }
        if let v = isoWeek, resolvedCivil.isoWeek.week != v { return nil }
        if let wy = resolvedIsoYear, (month != nil || day != nil || yearDay != nil || isoWeek != nil), resolvedCivil.isoWeek.year != wy { return nil }
        if let u = weekSunday, resolvedCivil.weekOfYearSunday != u { return nil }
        if let w = weekMonday, resolvedCivil.weekOfYearMonday != w { return nil }
        if let wd = weekday, (hasExplicitYear || resolvedIsoYear != nil || yearDay != nil || isoWeek != nil || weekSunday != nil || weekMonday != nil) {
            if resolvedCivil.weekday != wd { return nil }
        }

        var h = 0
        if let hour24 {
            guard (0...23).contains(hour24) else { return nil }
            if let hour12 {
                guard (1...12).contains(hour12) else { return nil }
                let expected = isPM != nil ? (hour12 % 12 + (isPM == true ? 12 : 0)) : nil
                if let expected, expected != hour24 { return nil }
                if isPM == nil && (hour24 % 12) != (hour12 % 12) { return nil }
            }
            h = hour24
        } else if let hour12 {
            guard (1...12).contains(hour12) else { return nil }
            h = hour12 % 12 + (isPM == true ? 12 : 0)
        } else if isPM == true {
            h = 12
        }
        let mi = minute ?? 0
        let s = second ?? 0
        guard (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s) else { return nil }
        let wall = CivilTime.wallSeconds(year: y, month: m, day: d, hour: h, minute: mi, second: s) - (tzOffsetSeconds ?? 0)
        return Double(wall) + TimeFormatting.windowsEpochOffset
    }
}

struct MaskParser {
    /// Input characters, each lower-cased (for case-insensitive matching).
    let input: [String]
    let info: LocaleTimeInfo
    let localTimeZone: TimeZone
    let systemLocale: Locale
    var pos = 0
    var fields = ParsedTimeFields()

    init(input: String, info: LocaleTimeInfo,
         localTimeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
         systemLocale: Locale = Locale(identifier: "en_US_POSIX")) {
        self.input = LocaleTimeInfo.folded(input)
        self.info = info
        self.localTimeZone = localTimeZone
        self.systemLocale = systemLocale
    }

    private static let compositeC = Array("%a %b %e %H:%M:%S %Y")
    private static let compositeLongC = Array("%A, %B %d, %Y, %H:%M:%S")
    private static let compositeX = Array("%m/%d/%y")
    private static let compositeLongX = Array("%A, %B %d, %Y")
    private static let compositeTime = Array("%H:%M:%S")
    private static let compositeD = Array("%m/%d/%y")
    private static let compositeF = Array("%Y-%m-%d")
    private static let compositeR12 = Array("%I:%M:%S %p")
    private static let compositeR24 = Array("%H:%M")

    private static func isSpace(_ s: String) -> Bool {
        s.count == 1 && (s.first?.isWhitespace ?? false)
    }

    private mutating func skipSpaces() {
        while pos < input.count, MaskParser.isSpace(input[pos]) { pos += 1 }
    }

    private mutating func number(maxDigits: Int, allowSign: Bool = false) -> Int? {
        skipSpaces()
        var negative = false
        if allowSign, pos < input.count, input[pos] == "-" || input[pos] == "+" {
            negative = input[pos] == "-"
            pos += 1
        }
        var value = 0
        var count = 0
        while pos < input.count, count < maxDigits, let digit = MaskParser.decimalDigit(input[pos]) {
            value = value * 10 + digit
            count += 1
            pos += 1
        }
        guard count > 0 else { return nil }
        return negative ? -value : value
    }

    /// The value of a single decimal digit character (ASCII or any Unicode `Nd` digit such as "٣"), else nil.
    private static func decimalDigit(_ s: String) -> Int? {
        let scalars = s.unicodeScalars
        guard let sc = scalars.first, scalars.count == 1 else { return nil }
        if sc.isASCII {
            return (48...57).contains(sc.value) ? Int(sc.value - 48) : nil
        }
        guard sc.properties.numericType == .decimal, let v = sc.properties.numericValue, v >= 0, v <= 9 else { return nil }
        return Int(v)
    }

    private mutating func parseNumericOffset(requireSign: Bool = true) -> Int? {
        let saved = pos
        var sign = 1
        if pos < input.count, input[pos] == "+" || input[pos] == "-" {
            sign = input[pos] == "-" ? -1 : 1
            pos += 1
        } else if requireSign {
            return nil
        }
        var digits: [Int] = []
        while pos < input.count, digits.count < 2, let d = MaskParser.decimalDigit(input[pos]) {
            digits.append(d)
            pos += 1
        }
        guard !digits.isEmpty else { pos = saved; return nil }
        let hh: Int
        var mm = 0
        if digits.count == 2 {
            hh = digits[0] * 10 + digits[1]
            if pos < input.count, input[pos] == ":" {
                let colonPos = pos
                pos += 1
                if pos + 1 < input.count,
                   let m1 = MaskParser.decimalDigit(input[pos]),
                   let m2 = MaskParser.decimalDigit(input[pos + 1]) {
                    mm = m1 * 10 + m2
                    pos += 2
                } else {
                    pos = colonPos
                }
            } else if pos + 1 < input.count,
                      let m1 = MaskParser.decimalDigit(input[pos]),
                      let m2 = MaskParser.decimalDigit(input[pos + 1]) {
                mm = m1 * 10 + m2
                pos += 2
            }
        } else {
            hh = digits[0]
            if pos < input.count, input[pos] == ":",
               pos + 2 < input.count,
               let m1 = MaskParser.decimalDigit(input[pos + 1]),
               let m2 = MaskParser.decimalDigit(input[pos + 2]) {
                mm = m1 * 10 + m2
                pos += 3
            } else {
                pos = saved
                return nil
            }
        }
        guard (0...14).contains(hh), (0...59).contains(mm), !(hh == 14 && mm > 0) else {
            pos = saved
            return nil
        }
        return sign * (hh * 3600 + mm * 60)
    }

    private static let knownTimeZoneCandidates: [(name: [String], value: Int)] = {
        let pairs: [(String, Int)] = [
            ("coordinated universal time", 0),
            ("greenwich mean time", 0),
            ("gmt standard time", 0),
            ("utc standard time", 0),
            ("eastern standard time", -5 * 3600),
            ("eastern daylight time", -4 * 3600),
            ("central standard time", -6 * 3600),
            ("central daylight time", -5 * 3600),
            ("mountain standard time", -7 * 3600),
            ("mountain daylight time", -6 * 3600),
            ("pacific standard time", -8 * 3600),
            ("pacific daylight time", -7 * 3600),
            ("alaska standard time", -9 * 3600),
            ("alaska daylight time", -8 * 3600),
            ("hawaiian standard time", -10 * 3600),
            ("atlantic standard time", -4 * 3600),
            ("atlantic daylight time", -3 * 3600),
            ("british summer time", 1 * 3600),
            ("central european standard time", 1 * 3600),
            ("central european summer time", 2 * 3600),
            ("central european daylight time", 2 * 3600),
            ("central european time", 1 * 3600),
            ("w. europe standard time", 1 * 3600),
            ("w. europe daylight time", 2 * 3600),
            ("eastern european standard time", 2 * 3600),
            ("eastern european summer time", 3 * 3600),
            ("eastern european daylight time", 3 * 3600),
            ("eastern european time", 2 * 3600),
            ("russian standard time", 3 * 3600),
            ("india standard time", 5 * 3600 + 1800),
            ("china standard time", 8 * 3600),
            ("japan standard time", 9 * 3600),
            ("tokyo standard time", 9 * 3600),
            ("korea standard time", 9 * 3600),
            ("australian eastern standard time", 10 * 3600),
            ("australian eastern daylight time", 11 * 3600),
            ("aus eastern standard time", 10 * 3600),
            ("aus eastern daylight time", 11 * 3600),
            ("new zealand standard time", 12 * 3600),
            ("new zealand daylight time", 13 * 3600),
            ("aest", 10 * 3600), ("aedt", 11 * 3600),
            ("nzst", 12 * 3600), ("nzdt", 13 * 3600),
            ("akst", -9 * 3600), ("akdt", -8 * 3600),
            ("cest", 2 * 3600), ("eest", 3 * 3600),
            ("utc", 0), ("gmt", 0),
            ("est", -5 * 3600), ("edt", -4 * 3600),
            ("cst", -6 * 3600), ("cdt", -5 * 3600),
            ("mst", -7 * 3600), ("mdt", -6 * 3600),
            ("pst", -8 * 3600), ("pdt", -7 * 3600),
            ("hst", -10 * 3600), ("ast", -4 * 3600), ("adt", -3 * 3600),
            ("bst", 1 * 3600), ("cet", 1 * 3600), ("eet", 2 * 3600),
            ("msk", 3 * 3600), ("ist", 5 * 3600 + 1800),
            ("hkt", 8 * 3600), ("sgt", 8 * 3600),
            ("jst", 9 * 3600), ("kst", 9 * 3600),
            ("z", 0)
        ]
        return pairs
            .map { (LocaleTimeInfo.folded($0.0), $0.1) }
            .sorted { $0.name.count > $1.name.count }
    }()

    private mutating func parseTimeZoneOffsetCode() -> Int? {
        skipSpaces()
        guard pos < input.count else { return nil }
        if input[pos] == "z" {
            pos += 1
            return 0
        }
        return parseNumericOffset(requireSign: true)
    }

    private mutating func parseTimeZoneName() -> Int? {
        skipSpaces()
        guard pos < input.count else { return nil }
        // Check for UTC±HH:MM / GMT±HH:MM first.
        for prefix in [["u", "t", "c"], ["g", "m", "t"]] {
            if pos + prefix.count <= input.count, Array(input[pos..<(pos + prefix.count)]) == prefix {
                let afterPrefix = pos + prefix.count
                if afterPrefix < input.count, input[afterPrefix] == "+" || input[afterPrefix] == "-" {
                    pos = afterPrefix
                    if let off = parseNumericOffset(requireSign: true) {
                        return off
                    }
                    return nil
                }
            }
        }
        // Check current system TimeZone localized names (standard and daylight).
        let currentZone = localTimeZone
        for daylight in [false, true] {
            let sysName = TimeZoneNames.name(of: currentZone, daylight: daylight, locale: systemLocale)
            let foldedName = LocaleTimeInfo.folded(sysName)
            if !foldedName.isEmpty, pos + foldedName.count <= input.count,
               Array(input[pos..<(pos + foldedName.count)]) == foldedName {
                pos += foldedName.count
                return currentZone.secondsFromGMT()
            }
        }
        if let off = name(MaskParser.knownTimeZoneCandidates, asciiWordBoundary: true) {
            return off
        }
        return parseNumericOffset(requireSign: true)
    }

    /// Matches `primary` (a locale composite) and falls back to `fallback` (the English pattern) from the same
    /// position when it does not match.
    private mutating func matchComposite(_ primary: [Character]?, _ fallback: [Character], depth: Int) -> Bool {
        if let primary {
            let savedPos = pos
            let savedFields = fields
            if match(primary, depth: depth + 1) { return true }
            pos = savedPos
            fields = savedFields
        }
        return match(fallback, depth: depth + 1)
    }

    private mutating func name<T>(_ candidates: [(name: [String], value: T)], asciiWordBoundary: Bool = false) -> T? {
        skipSpaces()
        for candidate in candidates {
            let n = candidate.name.count
            guard n > 0, pos + n <= input.count else { continue }
            if Array(input[pos..<(pos + n)]) == candidate.name {
                if asciiWordBoundary,
                   let last = candidate.name.last?.first, last.isASCII && last.isLetter,
                   pos + n < input.count, let next = input[pos + n].first, next.isASCII && next.isLetter {
                    continue
                }
                pos += n
                return candidate.value
            }
        }
        return nil
    }

    private static func isValidModifier(modifier: Character?, hash: Bool, for code: Character) -> Bool {
        if let modifier {
            if hash { return false }
            switch modifier {
            case "E":
                return ["c", "C", "x", "X", "y", "Y"].contains(code)
            case "O":
                return ["d", "e", "H", "I", "m", "M", "S", "u", "U", "V", "w", "W", "y"].contains(code)
            default:
                return false
            }
        }
        if hash {
            return ["a", "A", "b", "B", "c", "C", "d", "D", "e", "F", "g", "G", "h", "H", "I", "j", "m", "M", "p", "r", "R", "S", "T", "u", "U", "V", "w", "W", "x", "X", "y", "Y", "z", "Z", "%"].contains(code)
        }
        return true
    }

    mutating func match(_ mask: [Character], depth: Int) -> Bool {
        guard depth < 3 else { return false }
        var i = 0
        while i < mask.count {
            let c = mask[i]
            if c != "%" {
                if c.isWhitespace {
                    skipSpaces()
                } else {
                    guard pos < input.count, input[pos] == c.lowercased() else { return false }
                    pos += 1
                }
                i += 1
                continue
            }
            i += 1
            var hash = false
            var modifier: Character?
            while i < mask.count, mask[i] == "#" || mask[i] == "E" || mask[i] == "O" {
                if mask[i] == "#" {
                    if hash { return false }
                    hash = true
                } else {
                    if modifier != nil { return false }
                    modifier = mask[i]
                }
                i += 1
            }
            guard i < mask.count else { return false }
            let code = mask[i]
            i += 1
            guard MaskParser.isValidModifier(modifier: modifier, hash: hash, for: code) else { return false }
            switch code {
            case "a", "A":
                guard let wd = name(info.weekdayCandidates) else { return false }
                fields.set(\.weekday, wd)
            case "b", "B", "h":
                guard let m = name(info.monthCandidates) else { return false }
                fields.set(\.month, m)
            case "c":
                var local: [Character]?
                if let d = hash ? info.fullDateMask : info.shortDateMask, let tm = info.mediumTimeMask {
                    local = d + [" "] + tm       // the same "date time" join `format` uses
                }
                guard matchComposite(local, hash ? MaskParser.compositeLongC : MaskParser.compositeC, depth: depth) else { return false }
            case "x":
                guard matchComposite(hash ? info.fullDateMask : info.shortDateMask,
                                     hash ? MaskParser.compositeLongX : MaskParser.compositeX, depth: depth) else { return false }
            case "X":
                guard matchComposite(info.mediumTimeMask, MaskParser.compositeTime, depth: depth) else { return false }
            case "T":
                guard match(MaskParser.compositeTime, depth: depth + 1) else { return false }
            case "D":
                guard match(MaskParser.compositeD, depth: depth + 1) else { return false }
            case "F":
                guard match(MaskParser.compositeF, depth: depth + 1) else { return false }
            case "r":
                guard match(MaskParser.compositeR12, depth: depth + 1) else { return false }
            case "R":
                guard match(MaskParser.compositeR24, depth: depth + 1) else { return false }
            case "C":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.century, v)
            case "d", "e":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.day, v)
            case "g":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.isoYearInCentury, v)
            case "G":
                guard let v = number(maxDigits: 4) else { return false }
                fields.set(\.isoYear, v)
            case "U":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.weekSunday, v)
            case "V":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.isoWeek, v)
            case "W":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.weekMonday, v)
            case "u":
                guard let v = number(maxDigits: 1), (1...7).contains(v) else { return false }
                fields.set(\.weekday, v % 7)
            case "w":
                guard let v = number(maxDigits: 1), (0...6).contains(v) else { return false }
                fields.set(\.weekday, v)
            case "H":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.hour24, v)
            case "I":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.hour12, v)
            case "j":
                guard let v = number(maxDigits: 3) else { return false }
                fields.set(\.yearDay, v)
            case "m":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.month, v)
            case "M":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.minute, v)
            case "S":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.second, v)
            case "y":
                guard let v = number(maxDigits: 2) else { return false }
                fields.set(\.yearInCentury, v)
            case "Y":
                guard let v = number(maxDigits: 4) else { return false }
                fields.set(\.year, v)
            case "p":
                guard let pm = name(info.ampmCandidates) else { return false }
                fields.set(\.isPM, pm)
            case "z":
                guard let off = parseTimeZoneOffsetCode() else { return false }
                fields.set(\.tzOffsetSeconds, off)
            case "Z":
                guard let off = parseTimeZoneName() else { return false }
                fields.set(\.tzOffsetSeconds, off)
            case "n", "t":
                skipSpaces()
            case "%":
                guard pos < input.count, input[pos] == "%" else { return false }
                pos += 1
            default:
                return false
            }
        }
        return true
    }
}

