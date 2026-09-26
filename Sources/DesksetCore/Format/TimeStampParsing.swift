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
    public static func parseTimeStamp(_ timeStamp: String, format: String?, locale: Locale? = nil,
                                      now: Date = Date(), localTimeZone: TimeZone = .current) -> Double? {
        let raw = timeStamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let dst = daylightSavingTimeStamp(raw, now: now, timeZone: localTimeZone) {
            return dst.value
        }
        if let mask = format, !mask.isEmpty {
            return parseTimeStamp(raw, mask: mask, locale: locale ?? defaultLocale)
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
    public static func parseTimeStamp(_ string: String, mask: String, locale: Locale = Locale(identifier: "en_US_POSIX")) -> Double? {
        guard string.count <= 4096, mask.count <= 1024 else { return nil }
        // `locale-date` / `locale-time` are listed among the codes "used in the Format and TimeStampFormat
        // options" and "cannot be modified by using TimeStampLocale": a whole mask of either reads the system
        // locale's default date / time — the same representation `format` produces for them.
        var info = LocaleTimeInfo.info(for: locale)
        var maskChars = Array(mask)
        if mask.utf8.count == 11 {
            switch mask.lowercased() {
            case "locale-date": info = LocaleTimeInfo.info(for: .current); maskChars = ["%", "x"]
            case "locale-time": info = LocaleTimeInfo.info(for: .current); maskChars = ["%", "X"]
            default: break
            }
        }
        var parser = MaskParser(input: string, info: info)
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
    var month: Int?
    var day: Int?
    var yearDay: Int?
    var hour24: Int?
    var hour12: Int?
    var isPM: Bool?
    var minute: Int?
    var second: Int?

    func windowsTimestamp() -> Double? {
        let y: Int
        if let year {
            y = year
        } else if let yy = yearInCentury {
            if let century { y = century * 100 + yy } else { y = yy < 69 ? 2000 + yy : 1900 + yy }
        } else if let century {
            y = century * 100
        } else {
            y = 1900   // manual: "If the year is not defined in the TimeStamp option, then 1900 will be used"
        }
        var m = month ?? 1
        var d = day ?? 1
        if month == nil, day == nil, let yd = yearDay {
            guard yd >= 1, yd <= (CivilTime.isLeapYear(y) ? 366 : 365) else { return nil }
            let (_, mm, dd) = CivilTime.civilFromDays(CivilTime.daysFromCivil(y, 1, 1) + yd - 1)
            m = mm
            d = dd
        }
        guard (1...12).contains(m), d >= 1, d <= CivilTime.daysInMonth(y, m) else { return nil }
        var h = 0
        if let hour24 {
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
        let wall = CivilTime.wallSeconds(year: y, month: m, day: d, hour: h, minute: mi, second: s)
        return Double(wall) + TimeFormatting.windowsEpochOffset
    }
}

struct MaskParser {
    /// Input characters, each lower-cased (for case-insensitive matching).
    let input: [String]
    let info: LocaleTimeInfo
    var pos = 0
    var fields = ParsedTimeFields()

    init(input: String, info: LocaleTimeInfo) {
        self.input = LocaleTimeInfo.folded(input)
        self.info = info
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

    private mutating func name<T>(_ candidates: [(name: [String], value: T)]) -> T? {
        skipSpaces()
        for candidate in candidates {
            let n = candidate.name.count
            guard n > 0, pos + n <= input.count else { continue }
            if Array(input[pos..<(pos + n)]) == candidate.name {
                pos += n
                return candidate.value
            }
        }
        return nil
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
            while i < mask.count, mask[i] == "#" || mask[i] == "E" || mask[i] == "O" {
                if mask[i] == "#" { hash = true }
                i += 1
            }
            guard i < mask.count else { return false }
            let code = mask[i]
            i += 1
            switch code {
            case "a", "A":
                guard name(info.weekdayCandidates) != nil else { return false }
            case "b", "B", "h":
                guard let m = name(info.monthCandidates) else { return false }
                fields.month = m
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
                fields.century = v
            case "d", "e":
                guard let v = number(maxDigits: 2) else { return false }
                fields.day = v
            case "g", "U", "V", "W":
                guard number(maxDigits: 2) != nil else { return false }
            case "G":
                guard number(maxDigits: 4) != nil else { return false }
            case "u", "w":
                guard number(maxDigits: 1) != nil else { return false }
            case "H":
                guard let v = number(maxDigits: 2) else { return false }
                fields.hour24 = v
            case "I":
                guard let v = number(maxDigits: 2) else { return false }
                fields.hour12 = v
            case "j":
                guard let v = number(maxDigits: 3) else { return false }
                fields.yearDay = v
            case "m":
                guard let v = number(maxDigits: 2) else { return false }
                fields.month = v
            case "M":
                guard let v = number(maxDigits: 2) else { return false }
                fields.minute = v
            case "S":
                guard let v = number(maxDigits: 2) else { return false }
                fields.second = v
            case "y":
                guard let v = number(maxDigits: 2) else { return false }
                fields.yearInCentury = v
            case "Y":
                guard let v = number(maxDigits: 4) else { return false }
                fields.year = v
            case "p":
                guard let pm = name(info.ampmCandidates) else { return false }
                fields.isPM = pm
            case "n", "t":
                skipSpaces()
            case "%":
                guard pos < input.count, input[pos] == "%" else { return false }
                pos += 1
            default:
                return false   // %z / %Z ("cannot be used in the TimeStampFormat option") and unknown codes
            }
        }
        return true
    }
}
