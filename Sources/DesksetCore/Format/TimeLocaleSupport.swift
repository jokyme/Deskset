import Foundation

/// Day / month names, AM/PM symbols and locale date/time patterns for one locale, plus the candidates used to
/// parse names back (TimeStampFormat). Built once per locale identifier and cached.
final class LocaleTimeInfo {
    let weekdays: [String]          // Sunday first
    let shortWeekdays: [String]
    let months: [String]            // January first
    let shortMonths: [String]
    let am: String
    let pm: String
    /// Name candidates for parsing, longest first; values are 0-based weekday / 1-based month / isPM.
    let weekdayCandidates: [(name: [String], value: Int)]
    let monthCandidates: [(name: [String], value: Int)]
    let ampmCandidates: [(name: [String], value: Bool)]
    /// TimeStampFormat masks equivalent to this locale's `%x`, `%#x` and `%X` output (built from the same
    /// DateFormatter patterns), so `%c` / `%#c` / `%x` / `%#x` / `%X` in a TimeStampFormat read the
    /// TimeStampLocale's own representation. nil for the English default (the parser then uses the fixed English
    /// patterns) or when a pattern holds a field the mask syntax cannot express.
    let shortDateMask: [Character]?
    let fullDateMask: [Character]?
    let mediumTimeMask: [Character]?
    /// nil for the fixed English default ("standard English format"), which uses the C-locale patterns.
    private let formatters: Formatters?
    private let lock = NSLock()

    private struct Formatters {
        let shortDate: DateFormatter
        let fullDate: DateFormatter
        let mediumTime: DateFormatter
    }

    enum Pattern {
        case shortDate, fullDate, mediumTime
    }

    static let englishWeekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let englishShortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let englishMonths = ["January", "February", "March", "April", "May", "June", "July", "August",
                                "September", "October", "November", "December"]
    static let englishShortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The default: fixed English names, C-locale patterns (see `TimeFormatting.format`).
    static let english = LocaleTimeInfo()

    private init() {
        weekdays = LocaleTimeInfo.englishWeekdays
        shortWeekdays = LocaleTimeInfo.englishShortWeekdays
        months = LocaleTimeInfo.englishMonths
        shortMonths = LocaleTimeInfo.englishShortMonths
        am = "AM"
        pm = "PM"
        formatters = nil
        shortDateMask = nil
        fullDateMask = nil
        mediumTimeMask = nil
        weekdayCandidates = LocaleTimeInfo.candidates([weekdays, shortWeekdays], offset: 0)
        monthCandidates = LocaleTimeInfo.candidates([months, shortMonths], offset: 1)
        ampmCandidates = LocaleTimeInfo.ampm(am: [am], pm: [pm])
    }

    private init(locale: Locale) {
        func make(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateStyle = date
            f.timeStyle = time
            return f
        }
        let base = make(.none, .none)
        func list(_ l: [String]?, _ fallback: [String]) -> [String] {
            guard let l, l.count == fallback.count else { return fallback }
            return l
        }
        // %a %A %b %B print the *stand-alone* names ("the month name", "day of week name" — manual): the
        // format-context forms are inflected for use inside a date (ru "февраля" vs "февраль", fi "keskiviikkona"
        // = "on Wednesday", ca "de febrer"), which is wrong for `Format=%B` alone. Full dates (%#x, %#c) keep
        // their correct inflection because they come from the locale's own date pattern.
        let formatWeekdays = list(base.weekdaySymbols, LocaleTimeInfo.englishWeekdays)
        let formatShortWeekdays = list(base.shortWeekdaySymbols, LocaleTimeInfo.englishShortWeekdays)
        let formatMonths = list(base.monthSymbols, LocaleTimeInfo.englishMonths)
        let formatShortMonths = list(base.shortMonthSymbols, LocaleTimeInfo.englishShortMonths)
        weekdays = list(base.standaloneWeekdaySymbols, formatWeekdays)
        shortWeekdays = list(base.shortStandaloneWeekdaySymbols, formatShortWeekdays)
        months = list(base.standaloneMonthSymbols, formatMonths)
        shortMonths = list(base.shortStandaloneMonthSymbols, formatShortMonths)
        am = base.amSymbol ?? "AM"
        pm = base.pmSymbol ?? "PM"
        let shortDate = make(.short, .none), fullDate = make(.full, .none), mediumTime = make(.none, .medium)
        formatters = Formatters(shortDate: shortDate, fullDate: fullDate, mediumTime: mediumTime)
        let eraShort = base.eraSymbols.last ?? "AD"          // the calendar is Gregorian; timestamps are AD
        let eraLong = base.longEraSymbols.last ?? eraShort
        shortDateMask = LocaleTimeInfo.mask(fromICUPattern: shortDate.dateFormat, eraShort: eraShort, eraLong: eraLong)
        fullDateMask = LocaleTimeInfo.mask(fromICUPattern: fullDate.dateFormat, eraShort: eraShort, eraLong: eraLong)
        mediumTimeMask = LocaleTimeInfo.mask(fromICUPattern: mediumTime.dateFormat, eraShort: eraShort, eraLong: eraLong)
        // Parsing accepts format and stand-alone forms, abbreviations with or without their trailing ".",
        // and the English names as a fallback.
        let wd = [weekdays, shortWeekdays, formatWeekdays, formatShortWeekdays,
                  LocaleTimeInfo.englishWeekdays, LocaleTimeInfo.englishShortWeekdays]
        let mo = [months, shortMonths, formatMonths, formatShortMonths,
                  LocaleTimeInfo.englishMonths, LocaleTimeInfo.englishShortMonths]
        weekdayCandidates = LocaleTimeInfo.candidates(wd, offset: 0)
        monthCandidates = LocaleTimeInfo.candidates(mo, offset: 1)
        ampmCandidates = LocaleTimeInfo.ampm(am: [am, "AM"], pm: [pm, "PM"])
    }

    var isEnglishDefault: Bool { formatters == nil }

    /// Locale pattern for a wall-clock time (seconds since 1970 as if UTC). nil for the English default.
    func string(_ pattern: Pattern, wallSeconds: Int) -> String? {
        guard let formatters else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(wallSeconds))
        lock.lock()
        defer { lock.unlock() }
        switch pattern {
        case .shortDate: return formatters.shortDate.string(from: date)
        case .fullDate: return formatters.fullDate.string(from: date)
        case .mediumTime: return formatters.mediumTime.string(from: date)
        }
    }

    // MARK: cache

    private static let cacheLock = NSLock()
    private static var cache: [String: LocaleTimeInfo] = [:]

    /// The info for `locale`; the fixed English default for `en_US_POSIX` / C / POSIX.
    static func info(for locale: Locale) -> LocaleTimeInfo {
        let id = locale.identifier
        if TimeFormatting.isDefaultLocaleIdentifier(id) { return english }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[id] { return hit }
        let info = LocaleTimeInfo(locale: locale)
        if cache.count > 64 { cache.removeAll() }   // bounded; only a handful of locales are ever used
        cache[id] = info
        return info
    }

    // MARK: helpers

    /// Converts a DateFormatter (ICU / UTS #35) pattern such as `EEEE, d. MMMM y` into the equivalent
    /// TimeStampFormat mask (`%A, %d. %B %Y`). Only the fields that appear in date / time *styles* are handled:
    /// year, month, day, day of year, weekday, AM/PM (and day periods), hours, minutes, seconds, era (matched as
    /// its AD text — the formatters use the Gregorian calendar). Quoted text is literal (`''` is a quote); `%` in
    /// literals is escaped. Anything else (time zones, fractional seconds, quarters, weeks …) → nil, and the parser
    /// falls back to the English pattern. Bounded: patterns longer than 256 characters are rejected.
    static func mask(fromICUPattern pattern: String, eraShort: String, eraLong: String) -> [Character]? {
        let p = Array(pattern)
        guard !p.isEmpty, p.count <= 256 else { return nil }
        var out: [Character] = []
        func literal<S: Sequence>(_ s: S) where S.Element == Character {
            for c in s {
                out.append(c)
                if c == "%" { out.append("%") }
            }
        }
        func code(_ c: Character) { out.append("%"); out.append(c) }
        var i = 0
        while i < p.count {
            let c = p[i]
            if c == "'" {
                if i + 1 < p.count, p[i + 1] == "'" { literal(["'"]); i += 2; continue }
                var j = i + 1
                while j < p.count {
                    if p[j] == "'" {
                        if j + 1 < p.count, p[j + 1] == "'" { literal(["'"]); j += 2; continue }
                        break
                    }
                    literal([p[j]])
                    j += 1
                }
                i = j + 1
                continue
            }
            guard c.isASCII, c.isLetter else {
                literal([c])
                i += 1
                continue
            }
            var j = i
            while j < p.count, p[j] == c { j += 1 }
            let n = j - i
            switch c {
            case "y", "u", "Y": code(n == 2 ? "y" : "Y")
            case "M", "L": code(n <= 2 ? "m" : (n == 4 ? "B" : "b"))
            case "d": code("d")
            case "D": code("j")
            case "E": code(n == 4 ? "A" : "a")
            case "e", "c": code(n <= 2 ? "u" : (n == 4 ? "A" : "a"))
            case "a", "b", "B": code("p")
            case "h", "K": code("I")
            case "H", "k": code("H")
            case "m": code("M")
            case "s": code("S")
            case "G": literal(n == 4 ? eraLong : eraShort)
            default: return nil
            }
            i = j
        }
        return out
    }

    static func folded(_ s: String) -> [String] {
        s.map { $0.lowercased() }
    }

    private static func candidates(_ lists: [[String]], offset: Int) -> [(name: [String], value: Int)] {
        var seen = Set<String>()
        var out: [(name: [String], value: Int)] = []
        for list in lists {
            for (i, raw) in list.enumerated() {
                var variants = [raw]
                if raw.hasSuffix("."), raw.count > 1 { variants.append(String(raw.dropLast())) }
                for v in variants {
                    let key = v.lowercased()
                    guard !key.isEmpty, !seen.contains(key) else { continue }
                    seen.insert(key)
                    out.append((folded(v), i + offset))
                }
            }
        }
        return out.sorted { $0.name.count > $1.name.count }
    }

    private static func ampm(am: [String], pm: [String]) -> [(name: [String], value: Bool)] {
        var out: [(name: [String], value: Bool)] = []
        var seen = Set<String>()
        for (list, isPM) in [(am, false), (pm, true)] {
            for s in list where !s.isEmpty && !seen.contains(s.lowercased()) {
                seen.insert(s.lowercased())
                out.append((folded(s), isPM))
            }
        }
        return out.sorted { $0.name.count > $1.name.count }
    }
}

/// Time zone names (`%Z`), cached per zone, DST state and locale.
///
/// The manual: "%Z: Time zone name. These are for the system locale, and cannot be modified using FormatLocale
/// (e.g. "Eastern Standard Time")" — so the name is in the system (user) locale, whatever FormatLocale says;
/// an English system gives the manual's "Eastern Standard Time".
enum TimeZoneNames {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    static func name(of zone: TimeZone, daylight: Bool, locale: Locale = .autoupdatingCurrent) -> String {
        let key = zone.identifier + (daylight ? "|d|" : "|s|") + locale.identifier
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let name = zone.localizedName(for: daylight ? .daylightSaving : .standard, locale: locale)
            ?? zone.abbreviation() ?? zone.identifier
        lock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = name
        lock.unlock()
        return name
    }
}

/// Windows locale names (`FormatLocale` / `TimeStampLocale`) → Foundation locales.
enum WindowsLocaleNames {
    /// "Language Name Abbreviation" column of the MS-LCID reference (common entries).
    static let abbreviations: [String: String] = [
        "ENU": "en_US", "ENG": "en_GB", "ENA": "en_AU", "ENC": "en_CA", "ENZ": "en_NZ", "ENI": "en_IE",
        "ENS": "en_ZA", "ENJ": "en_JM", "ENB": "en_029", "ENL": "en_BZ", "ENT": "en_TT", "ENW": "en_ZW",
        "ENP": "en_PH", "ENN": "en_IN", "ENM": "en_MY", "ENE": "en_SG",
        "DEU": "de_DE", "DES": "de_CH", "DEA": "de_AT", "DEL": "de_LU", "DEC": "de_LI",
        "FRA": "fr_FR", "FRB": "fr_BE", "FRC": "fr_CA", "FRS": "fr_CH", "FRL": "fr_LU", "FRM": "fr_MC",
        "ESP": "es_ES", "ESN": "es_ES", "ESM": "es_MX", "ESG": "es_GT", "ESC": "es_CR", "ESA": "es_PA",
        "ESD": "es_DO", "ESV": "es_VE", "ESO": "es_CO", "ESR": "es_PE", "ESS": "es_AR", "ESF": "es_EC",
        "ESL": "es_CL", "ESY": "es_UY", "ESZ": "es_PY", "ESB": "es_BO", "ESE": "es_SV", "ESH": "es_HN",
        "ESI": "es_NI", "ESU": "es_PR", "EST": "es_US",
        "ITA": "it_IT", "ITS": "it_CH", "PTB": "pt_BR", "PTG": "pt_PT", "NLD": "nl_NL", "NLB": "nl_BE",
        "JPN": "ja_JP", "KOR": "ko_KR", "CHS": "zh_CN", "CHT": "zh_TW", "ZHH": "zh_HK", "ZHI": "zh_SG",
        "ZHM": "zh_MO", "RUS": "ru_RU", "UKR": "uk_UA", "BEL": "be_BY", "PLK": "pl_PL", "CSY": "cs_CZ",
        "SKY": "sk_SK", "HUN": "hu_HU", "ROM": "ro_RO", "BGR": "bg_BG", "HRV": "hr_HR", "SLV": "sl_SI",
        "SRL": "sr_Latn_RS", "SRB": "sr_Cyrl_RS", "ETI": "et_EE", "LVI": "lv_LV", "LTH": "lt_LT",
        "SVE": "sv_SE", "SVF": "sv_FI", "NOR": "nb_NO", "NON": "nn_NO", "DAN": "da_DK", "FIN": "fi_FI",
        "ISL": "is_IS", "ELL": "el_GR", "TRK": "tr_TR", "HEB": "he_IL", "ARA": "ar_SA", "ARE": "ar_EG",
        "FAR": "fa_IR", "HIN": "hi_IN", "THA": "th_TH", "VIT": "vi_VN", "IND": "id_ID", "MSL": "ms_MY",
        "CAT": "ca_ES", "EUQ": "eu_ES", "GLC": "gl_ES", "AFK": "af_ZA", "SQI": "sq_AL", "HYE": "hy_AM",
        "KAT": "ka_GE", "KKZ": "kk_KZ", "MKI": "mk_MK", "URD": "ur_PK", "BEN": "bn_IN", "TAM": "ta_IN",
        "TEL": "te_IN", "MAR": "mr_IN", "GUJ": "gu_IN", "KAN": "kn_IN", "MAL": "ml_IN", "PAN": "pa_IN",
        "SWK": "sw_KE", "FOS": "fo_FO", "MON": "mn_MN", "LAO": "lo_LA", "KHM": "km_KH", "NEP": "ne_NP",
        "SIN": "si_LK", "AZE": "az_Latn_AZ", "UZB": "uz_Latn_UZ", "TTT": "tt_RU", "IRE": "ga_IE",
        "CYM": "cy_GB", "MLT": "mt_MT", "LBX": "lb_LU", "FYN": "fy_NL",
        // Legacy "Culture Name" values still listed in MS-LCID (Chinese Simplified / Traditional).
        "ZH-CHS": "zh_Hans", "ZH-CHT": "zh_Hant", "ZH_CHS": "zh_Hans", "ZH_CHT": "zh_Hant",
    ]

    private static let lock = NSLock()
    private static var languageByName: [String: String]?
    private static var regionByName: [String: String]?
    private static var knownLanguages: Set<String>?

    /// Lower-cased English language names → ISO code, English region names → region code, known codes.
    private static func tables() -> (languages: [String: String], regions: [String: String], codes: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        if let l = languageByName, let r = regionByName, let k = knownLanguages { return (l, r, k) }
        let en = Locale(identifier: "en_US")
        var languages: [String: String] = [:]
        var codes = Set<String>()
        for code in Locale.LanguageCode.isoLanguageCodes {
            let id = code.identifier
            codes.insert(id.lowercased())
            if let name = en.localizedString(forLanguageCode: id)?.lowercased(), languages[name] == nil {
                languages[name] = id
            }
        }
        var regions: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            let id = region.identifier
            if let name = en.localizedString(forRegionCode: id)?.lowercased(), regions[name] == nil {
                regions[name] = id
            }
        }
        // Windows spellings that differ from the CLDR English names.
        let extraRegions = ["usa": "US", "uk": "GB", "united states of america": "US", "korea": "KR",
                            "prc": "CN", "people's republic of china": "CN", "taiwan": "TW", "hong kong": "HK",
                            "russian federation": "RU", "czech republic": "CZ", "macedonia": "MK"]
        for (k, v) in extraRegions where regions[k] == nil { regions[k] = v }
        let extraLanguages = ["chinese (simplified)": "zh_Hans", "chinese (traditional)": "zh_Hant",
                              "chinese-simplified": "zh_Hans", "chinese-traditional": "zh_Hant",
                              "norwegian (bokmal)": "nb", "norwegian (nynorsk)": "nn", "farsi": "fa"]
        for (k, v) in extraLanguages where languages[k] == nil { languages[k] = v }
        languageByName = languages
        regionByName = regions
        knownLanguages = codes
        return (languages, regions, codes)
    }

    static func locale(from raw: String) -> Locale? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return nil }
        if trimmed.lowercased() == "local" { return Locale.autoupdatingCurrent }
        if let id = abbreviations[trimmed.uppercased()] { return Locale(identifier: id) }
        // Drop a trailing ".codepage" ("Russian_Russia.1251").
        var body = trimmed
        if let dot = body.firstIndex(of: ".") { body = String(body[..<dot]) }
        let t = tables()
        // Culture names / ISO identifiers: "de-DE", "de_DE", "de", "zh-Hans-CN", "sr-Latn-RS".
        let parts = body.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        if let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }),
           t.codes.contains(first.lowercased()) {
            let valid = parts.dropFirst().allSatisfy { p in
                (p.count == 2 && p.allSatisfy { $0.isASCII && $0.isLetter }) ||
                (p.count == 3 && p.allSatisfy { $0.isASCII && $0.isNumber }) ||
                (p.count == 4 && p.allSatisfy { $0.isASCII && $0.isLetter })
            }
            if valid {
                // Canonical case: language lower, Script title, REGION upper ("DE-de" → "de_DE").
                let normalized = [first.lowercased()] + parts.dropFirst().map { p in
                    p.count == 4 ? p.prefix(1).uppercased() + p.dropFirst().lowercased() : p.uppercased()
                }
                return Locale(identifier: normalized.joined(separator: "_"))
            }
        }
        // "Language_Country" in English words ("Russian_Russia", "German", "English_United States").
        let words = body.split(separator: "_", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let languageName = words.first, let language = t.languages[languageName] else { return nil }
        if words.count == 2, let region = t.regions[words[1]] {
            return Locale(identifier: language + "_" + region)
        }
        return Locale(identifier: language)
    }
}
