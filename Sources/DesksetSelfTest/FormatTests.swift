import Foundation
@testable import DesksetCore

// Tests for the "format" module: NumberFormatting / AutoScale, TimeFormatting (Format codes, locales, TimeZone,
// TimeStamp parsing, number values) and UptimeFormatting. Rules come from the public manual pages
// meters/string, measures/time, measures/uptime, measures/general-options, variables/section-variables.

private let gmt = TimeZone(secondsFromGMT: 0)!

/// A UTC instant built with Foundation's Calendar (an implementation independent from the one under test).
private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = gmt
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

/// Windows timestamp (seconds since 1601-01-01) of a wall-clock time.
private func winTS(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Double {
    utc(y, mo, d, h, mi, s).timeIntervalSince1970 + 11_644_473_600
}

private func fmt(_ date: Date, _ format: String, _ zone: TimeZone = gmt,
                 locale: Locale = TimeFormatting.defaultLocale) -> String {
    TimeFormatting.format(date, format: format, timeZone: zone, locale: locale)
}

private let english = Locale(identifier: "en_US")

/// %Z's expected text: the zone's name in the system locale (Foundation, independent of the code under test).
private func sysZoneName(_ zone: TimeZone, daylight: Bool) -> String {
    zone.localizedName(for: daylight ? .daylightSaving : .standard, locale: .autoupdatingCurrent) ?? zone.identifier
}

private func num(_ value: Double, _ options: NumberFormatOptions, min: Double = 0, max: Double = 1) -> String {
    NumberFormatting.format(value, minValue: min, maxValue: max, options: options)
}

/// Deterministic pseudo-random generator for the fuzz tests.
private struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
}

func runFormatTests(_ t: TestRunner) {
    runAutoScaleParseTests(t)
    runNumberFormatTests(t)
    runTimeCodeTests(t)
    runTimeLocaleTests(t)
    runTimeZoneTests(t)
    runTimeValueTests(t)
    runTimeStampTests(t)
    runUptimeTests(t)
    runFormatRobustnessTests(t)
    runFormatReviewTests(t)
}

// MARK: - AutoScale / NumberFormatting

private func runAutoScaleParseTests(_ t: TestRunner) {
    t.suite("Format: AutoScale parse") {
        // Values listed on the String meter page.
        t.equal(AutoScale.parse("0"), .off)
        t.equal(AutoScale.parse("1"), .binary(minimumPower: 0))
        t.equal(AutoScale.parse("1k"), .binary(minimumPower: 1))
        t.equal(AutoScale.parse("2"), .decimal(minimumPower: 0))
        t.equal(AutoScale.parse("2k"), .decimal(minimumPower: 1))
        // Extensions and spelling variants.
        t.equal(AutoScale.parse("1K"), .binary(minimumPower: 1))
        t.equal(AutoScale.parse(" 2k "), .decimal(minimumPower: 1))
        t.equal(AutoScale.parse("1 k"), .binary(minimumPower: 1))
        t.equal(AutoScale.parse("1m"), .binary(minimumPower: 2))
        t.equal(AutoScale.parse("2M"), .decimal(minimumPower: 2))
        t.equal(AutoScale.parse("1g"), .binary(minimumPower: 3))
        t.equal(AutoScale.parse("2g"), .decimal(minimumPower: 3))
        t.equal(AutoScale.parse("1t"), .binary(minimumPower: 4))
        t.equal(AutoScale.parse("2t"), .decimal(minimumPower: 4))
        t.equal(AutoScale.parse("1.0"), .binary(minimumPower: 0))
        t.equal(AutoScale.parse("01"), .binary(minimumPower: 0))
        // Unknown → off.
        for raw in ["", "   ", "3", "-1", "k", "abc", "1x", "1kk", "0k", "3k", "1.5", "1e0k", "\u{0}"] {
            t.equal(AutoScale.parse(raw), .off, "raw=\(raw.debugDescription)")
        }
    }

    t.suite("Format: NumberFormatOptions parse") {
        let o = NumberFormatOptions.parse(autoScale: "1k", scale: "1000.0", numOfDecimals: "2", percentual: "1")
        t.equal(o.autoScale, .binary(minimumPower: 1))
        t.equal(o.scale, 1000)
        t.check(o.scaleHasDecimalPoint)
        t.equal(o.numOfDecimals, 2)
        t.check(o.percentual)
        let d = NumberFormatOptions.parse(autoScale: nil, scale: nil, numOfDecimals: nil, percentual: nil)
        t.equal(d, NumberFormatOptions())
        t.equal(d.scale, 1)
        t.equal(d.numOfDecimals, nil)
        t.check(!d.percentual && !d.scaleHasDecimalPoint)
        let e = NumberFormatOptions.parse(autoScale: "0", scale: "1024", numOfDecimals: "-3", percentual: "0")
        t.equal(e.autoScale, .off)
        t.equal(e.scale, 1024)
        t.check(!e.scaleHasDecimalPoint)
        t.equal(e.numOfDecimals, 0)
        t.check(!e.percentual)
        let f = NumberFormatOptions.parse(autoScale: "", scale: "abc", numOfDecimals: "1.9", percentual: "x")
        t.equal(f.scale, 1)
        t.equal(f.numOfDecimals, 1)
        t.check(!f.percentual)
        t.check(NumberFormatOptions.scaleHasDecimalPoint("(1024*1.0)"))
        t.check(!NumberFormatOptions.scaleHasDecimalPoint("1024"))
    }
}

private func runNumberFormatTests(_ t: TestRunner) {
    t.suite("Format: NumOfDecimals and rounding") {
        // NumOfDecimals Default: 0.
        t.equal(num(12.7, .init()), "13")
        t.equal(num(12.3, .init()), "12")
        t.equal(num(0, .init()), "0")
        t.equal(num(3.14159, .init(numOfDecimals: 3)), "3.142")
        t.equal(num(2, .init(numOfDecimals: 2)), "2.00")
        t.equal(num(-1.6, .init()), "-2")
        // Values beyond 32 bits with NumOfDecimals=0 (release notes).
        t.equal(num(1_099_511_627_776, .init()), "1099511627776")
        t.equal(num(1e20, .init()), "100000000000000000000")
        // printf rounding: exact ties go to even, otherwise the binary value decides.
        t.equal(num(0.5, .init()), "0")
        t.equal(num(1.5, .init()), "2")
        t.equal(num(2.5, .init()), "2")
        t.equal(num(12.25, .init(numOfDecimals: 1)), "12.2")
        t.equal(num(0.126, .init(numOfDecimals: 2)), "0.13")
        // No "-0".
        t.equal(num(-0.4, .init()), "0")
        t.equal(num(-0.0001, .init(numOfDecimals: 2)), "0.00")
        t.equal(num(-0.0, .init()), "0")
        // Decimal count clamping.
        t.equal(num(1, .init(numOfDecimals: -2)), "1")
        t.equal(num(1, .init(numOfDecimals: 1000)), "1." + String(repeating: "0", count: NumberFormatting.maximumDecimals))
        // NaN / infinity never crash.
        t.equal(num(.nan, .init()), "0")
        t.equal(num(.infinity, .init()), "inf")
        t.equal(num(-.infinity, .init(numOfDecimals: 2)), "-inf")
        t.equal(num(.greatestFiniteMagnitude, .init()).count, 309)
        t.equal(num(.leastNonzeroMagnitude, .init(numOfDecimals: 3)), "0.000")
    }

    t.suite("Format: Scale") {
        // "The measure value is divided by the specified value."
        t.equal(num(2048, .init(scale: 1024)), "2")
        t.equal(num(3000, .init(scale: 1000)), "3")
        t.equal(num(1234, .init(scale: 1000)), "1")
        // "If the specified value has a decimal point (e.g. 1000.0), the result will also display decimals."
        var dotted = NumberFormatOptions(scale: 1000)
        dotted.scaleHasDecimalPoint = true
        t.equal(num(1234, dotted), "1.2")
        dotted.numOfDecimals = 3
        t.equal(num(1234, dotted), "1.234")
        dotted.numOfDecimals = 0
        t.equal(num(1234, dotted), "1")
        t.equal(num(1234, .parse(autoScale: nil, scale: "1000.0", numOfDecimals: nil, percentual: nil)), "1.2")
        t.equal(num(1234, .init(scale: 1000, numOfDecimals: 2)), "1.23")
        // Scale 0 / non-finite ignored; negative allowed.
        t.equal(num(5, .init(scale: 0)), "5")
        t.equal(num(5, .init(scale: .nan)), "5")
        t.equal(num(5, .init(scale: .infinity)), "5")
        t.equal(num(2048, .init(scale: -1024)), "-2")
        t.equal(num(1, .init(scale: 0.5)), "2")
        // "If AutoScale is enabled, this option is ignored."
        t.equal(num(2048, .init(autoScale: .binary(minimumPower: 0), scale: 1000)), "2.0 k")
    }

    t.suite("Format: AutoScale") {
        let b = NumberFormatOptions(autoScale: .binary(minimumPower: 0))
        let d = NumberFormatOptions(autoScale: .decimal(minimumPower: 0))
        // "By default the value will be displayed with one decimal point of precision."
        t.equal(num(1536, b), "1.5 k")
        t.equal(num(1024, b), "1.0 k")
        t.equal(num(1_572_864, b), "1.5 M")
        t.equal(num(2 * 1_073_741_824, b), "2.0 G")
        t.equal(num(3 * 1_099_511_627_776, b), "3.0 T")
        t.equal(num(1024 * 1_099_511_627_776, b), "1024.0 T")
        t.equal(num(1500, d), "1.5 k")
        t.equal(num(2_500_000, d), "2.5 M")
        t.equal(num(1e9, d), "1.0 G")
        t.equal(num(1e12, d), "1.0 T")
        t.equal(num(1e15, d), "1000.0 T")
        t.equal(num(1000, b), "1000.0 ")
        // The space before the unit is always there (also without a unit): Text=%1B → "512.0 B".
        t.equal(num(512, b), "512.0 ")
        t.equal(num(999, d), "999.0 ")
        t.equal(num(0, b), "0.0 ")
        t.equal(num(512, b) + "B", "512.0 B")
        t.equal(num(8_589_934_592, b) + "B", "8.0 GB")  // Memory page example: Text="RAM Total: %1B"
        // NumOfDecimals controls the precision.
        t.equal(num(1536, .init(autoScale: .binary(minimumPower: 0), numOfDecimals: 2)), "1.50 k")
        t.equal(num(1800, .init(autoScale: .binary(minimumPower: 0), numOfDecimals: 0)), "2 k")
        t.equal(num(1_234_567, .init(autoScale: .decimal(minimumPower: 0), numOfDecimals: 3)), "1.235 M")
        // 1k / 2k: kilo is the lowest unit.
        t.equal(num(512, .init(autoScale: .binary(minimumPower: 1))), "0.5 k")
        t.equal(num(0, .init(autoScale: .binary(minimumPower: 1))), "0.0 k")
        t.equal(num(300, .init(autoScale: .decimal(minimumPower: 1))), "0.3 k")
        t.equal(num(3_000_000, .init(autoScale: .decimal(minimumPower: 1))), "3.0 M")
        t.equal(num(1_048_576, .init(autoScale: .binary(minimumPower: 2))), "1.0 M")
        t.equal(num(1024, .init(autoScale: .binary(minimumPower: 2), numOfDecimals: 4)), "0.0010 M")
        t.equal(num(1_099_511_627_776, .init(autoScale: .binary(minimumPower: 4))), "1.0 T")
        t.equal(num(5e8, .init(autoScale: .decimal(minimumPower: 3))), "0.5 G")
        t.equal(num(1, .init(autoScale: .binary(minimumPower: 99))), "0.0 T")      // clamped power
        t.equal(num(2048, .init(autoScale: .binary(minimumPower: -3))), "2.0 k")   // clamped power
        // Negative values scale by magnitude.
        t.equal(num(-2048, b), "-2.0 k")
        t.equal(num(-0.01, b), "0.0 ")
        // Non-finite.
        t.equal(num(.infinity, b), "inf")
        t.equal(num(.nan, b), "0.0 ")
    }

    t.suite("Format: Percentual") {
        let p = NumberFormatOptions(percentual: true)
        t.equal(num(50, p, min: 0, max: 200), "25")
        t.equal(num(0.5, p), "50")                       // MinValue 0.0, MaxValue 1.0 defaults
        t.equal(num(1.0 / 3, NumberFormatOptions(numOfDecimals: 1, percentual: true)), "33.3")
        t.equal(num(150, p, min: 100, max: 200), "50")
        t.equal(num(300, p, min: 0, max: 200), "100")    // clamped
        t.equal(num(-5, p, min: 0, max: 200), "0")       // clamped
        t.equal(num(5, p, min: 3, max: 3), "0")          // empty range
        t.equal(num(25, p, min: 100, max: 0), "75")      // inverted range
        t.equal(num(5, p, min: .nan, max: 1), "0")
        t.equal(num(.nan, p, min: 0, max: 1), "0")
        t.equal(num(50, NumberFormatOptions(scale: 10, percentual: true), min: 0, max: 100), "5")
        t.equal(num(50, NumberFormatOptions(autoScale: .binary(minimumPower: 0), percentual: true), min: 0, max: 100), "50.0 ")
        t.close(NumberFormatting.percentage(75, minValue: 50, maxValue: 150), 25)
        t.close(NumberFormatting.percentage(1, minValue: -.infinity, maxValue: 1), 0)
        t.close(NumberFormatting.percentage(1, minValue: -1e308, maxValue: 1e308), 0)   // range overflows → 0
    }

    t.suite("Format: plain and fixed") {
        t.equal(NumberFormatting.plain(1), "1")
        t.equal(NumberFormatting.plain(0), "0")
        t.equal(NumberFormatting.plain(-0.0), "0")
        t.equal(NumberFormatting.plain(100), "100")
        t.equal(NumberFormatting.plain(0.5), "0.5")
        t.equal(NumberFormatting.plain(10.10), "10.1")
        t.equal(NumberFormatting.plain(-1.25), "-1.25")
        t.equal(NumberFormatting.plain(1.0 / 3), "0.33333")
        t.equal(NumberFormatting.plain(2.0 / 3), "0.66667")
        t.equal(NumberFormatting.plain(1e20), "100000000000000000000")
        t.equal(NumberFormatting.plain(1e-7), "0")
        t.equal(NumberFormatting.plain(-1e-7), "0")
        t.equal(NumberFormatting.plain(13_066_845_750), "13066845750")
        t.equal(NumberFormatting.plain(.nan), "0")
        t.equal(NumberFormatting.plain(.infinity), "inf")
        t.equal(NumberFormatting.plain(-.infinity), "-inf")
        // [Measure:] — up to ten decimals, trailing zeros trimmed.
        t.equal(NumberFormatting.plain(1.0 / 3, maxDecimals: 10), "0.3333333333")
        t.equal(NumberFormatting.plain(2.5, maxDecimals: 10), "2.5")
        t.equal(NumberFormatting.plain(7, maxDecimals: 0), "7")
        t.equal(NumberFormatting.plain(7.6, maxDecimals: -4), "8")
        // [Measure:4] — exactly the given number of decimals.
        t.equal(NumberFormatting.fixed(1.0 / 3, decimals: 4), "0.3333")
        t.equal(NumberFormatting.fixed(2, decimals: 4), "2.0000")
        t.equal(NumberFormatting.fixed(2.6, decimals: -1), "3")
        t.equal(NumberFormatting.fixed(-0.00001, decimals: 2), "0.00")
        t.equal(NumberFormatting.fixed(.nan, decimals: 2), "0.00")    // NaN counts as 0
        t.equal(NumberFormatting.fixed(1234.5, decimals: 1), "1234.5")   // never a locale separator
    }
}

// MARK: - Time Format codes

private func runTimeCodeTests(_ t: TestRunner) {
    // The manual's example date for the code table: Saturday, December 26, 2015 22:55:03.
    let sat = utc(2015, 12, 26, 22, 55, 3)

    t.suite("Format: Time codes (manual table)") {
        t.equal(fmt(sat, "%a"), "Sat")
        t.equal(fmt(sat, "%A"), "Saturday")
        t.equal(fmt(sat, "%b"), "Dec")
        t.equal(fmt(sat, "%B"), "December")
        t.equal(fmt(sat, "%c"), "Sat Dec 26 22:55:03 2015")
        t.equal(fmt(sat, "%#c"), "Saturday, December 26, 2015, 22:55:03")
        t.equal(fmt(sat, "%C"), "20")
        t.equal(fmt(sat, "%d"), "26")
        t.equal(fmt(sat, "%D"), "12/26/15")
        t.equal(fmt(sat, "%e"), "26")
        t.equal(fmt(sat, "%F"), "2015-12-26")
        t.equal(fmt(sat, "%g"), "15")
        t.equal(fmt(sat, "%G"), "2015")
        t.equal(fmt(sat, "%h"), "Dec")
        t.equal(fmt(sat, "%H"), "22")
        t.equal(fmt(sat, "%I"), "10")
        t.equal(fmt(sat, "%j"), "360")
        t.equal(fmt(sat, "%m"), "12")
        t.equal(fmt(sat, "%M"), "55")
        t.equal(fmt(sat, "%n"), "\n")
        t.equal(fmt(sat, "%p"), "PM")
        t.equal(fmt(sat, "%r"), "10:55:03 PM")
        t.equal(fmt(sat, "%R"), "22:55")
        t.equal(fmt(sat, "%S"), "03")
        t.equal(fmt(sat, "%t"), "\t")
        t.equal(fmt(sat, "%T"), "22:55:03")
        t.equal(fmt(sat, "%u"), "6")
        t.equal(fmt(sat, "%U"), "51")
        t.equal(fmt(sat, "%V"), "52")
        t.equal(fmt(sat, "%w"), "6")
        t.equal(fmt(sat, "%W"), "51")
        t.equal(fmt(sat, "%x"), "12/26/15")
        t.equal(fmt(sat, "%#x"), "Saturday, December 26, 2015")
        t.equal(fmt(sat, "%X"), "22:55:03")
        t.equal(fmt(sat, "%y"), "15")
        t.equal(fmt(sat, "%Y"), "2015")
        t.equal(fmt(sat, "%z"), "+0000")
        // %Z: "Time zone name. These are for the system locale" → the system locale's name; on an English
        // system that is the manual's style of name.
        t.equal(fmt(sat, "%Z"), sysZoneName(gmt, daylight: false))
        t.equal(TimeZoneNames.name(of: gmt, daylight: false, locale: english), "Greenwich Mean Time")
        t.equal(fmt(sat, "%%"), "%")
        t.equal(fmt(sat, "100%% at %H"), "100% at 22")
    }

    t.suite("Format: Time examples from the manual") {
        let tue = utc(2015, 1, 27, 15, 22, 30)
        t.equal(fmt(tue, "%A, %B %#d, %Y %#I:%M %p"), "Tuesday, January 27, 2015 3:22 PM")
        t.equal(fmt(tue, "%A, %B %#d, %Y"), "Tuesday, January 27, 2015")   // MeasureDate
        t.equal(fmt(tue, "%#I:%M %p"), "3:22 PM")                           // Measure12HrTime
        t.equal(fmt(tue, "%H:%M"), "15:22")                                 // Measure24HrTime
        t.equal(fmt(tue, "%A, %b %#d, %Y"), "Tuesday, Jan 27, 2015")        // String meter page example
        t.equal(fmt(tue, TimeFormatting.defaultFormat), "15:22:30")
        t.equal(TimeFormatting.defaultFormat, "%H:%M:%S")
        t.equal(fmt(tue, ""), "15:22:30")                                   // empty → default
        t.equal(fmt(tue, "Date: %Y年%#m月%#d日 — ok"), "Date: 2015年1月27日 — ok")
    }

    t.suite("Format: Time # modifier") {
        let d = utc(2005, 1, 5, 3, 4, 5)   // Wednesday
        let pairs: [(String, String, String)] = [
            ("d", "05", "5"), ("H", "03", "3"), ("I", "03", "3"), ("j", "005", "5"), ("m", "01", "1"),
            ("M", "04", "4"), ("S", "05", "5"), ("U", "01", "1"), ("w", "3", "3"), ("W", "01", "1"),
            ("y", "05", "5"), ("Y", "2005", "2005"),
        ]
        for (code, padded, stripped) in pairs {
            t.equal(fmt(d, "%" + code), padded, "%\(code)")
            t.equal(fmt(d, "%#" + code), stripped, "%#\(code)")
        }
        // Zero stays "0".
        let midnight = utc(2000, 3, 1, 0, 0, 0)
        t.equal(fmt(midnight, "%#H:%#M:%#S %#y"), "0:0:0 0")
        // '#' is ignored on codes it does not apply to.
        t.equal(fmt(d, "%#a %#A %#b %#B %#p %#e %#%"), "Wed Wednesday Jan January AM  5 %")
        t.equal(fmt(d, "%#C %#u %#V %#G %#g"), "20 3 01 2005 05")
    }

    t.suite("Format: Time E and O modifiers") {
        t.equal(fmt(sat, "%Ec|%EC|%Ex|%EX|%Ey|%EY"), fmt(sat, "%c|%C|%x|%X|%y|%Y"))
        t.equal(fmt(sat, "%Od|%Oe|%OH|%OI|%Om|%OM|%OS|%Ou|%OU|%OV|%Ow|%OW|%Oy"),
                fmt(sat, "%d|%e|%H|%I|%m|%M|%S|%u|%U|%V|%w|%W|%y"))
    }

    t.suite("Format: Time 12-hour clock and padding") {
        t.equal(fmt(utc(2020, 6, 1, 0, 5), "%I %p %#I"), "12 AM 12")
        t.equal(fmt(utc(2020, 6, 1, 12, 5), "%I %p"), "12 PM")
        t.equal(fmt(utc(2020, 6, 1, 13, 5), "%I %p %r"), "01 PM 01:05:00 PM")
        t.equal(fmt(utc(2020, 6, 1, 11, 59, 59), "%p"), "AM")
        t.equal(fmt(utc(2020, 6, 5), "%e|%d"), " 5|05")
        t.equal(fmt(utc(2020, 6, 5), "%c"), "Fri Jun  5 00:00:00 2020")
        t.equal(fmt(utc(1999, 6, 5), "%C %y"), "19 99")
        t.equal(fmt(utc(2000, 6, 5), "%C %y"), "20 00")
        t.equal(fmt(utc(1601, 1, 1), "%Y-%m-%d %A"), "1601-01-01 Monday")
        t.equal(fmt(utc(2016, 2, 29), "%j %A"), "060 Monday")
        t.equal(fmt(utc(2016, 12, 31), "%j"), "366")
    }

    t.suite("Format: Time week numbers") {
        // 2015-01-01 is a Thursday: %U/%W week 0 until the first Sunday/Monday.
        t.equal(fmt(utc(2015, 1, 1), "%U %W %V %G %g %u %w"), "00 00 01 2015 15 4 4")
        t.equal(fmt(utc(2015, 1, 4), "%U %W"), "01 00")   // Sunday
        t.equal(fmt(utc(2015, 1, 5), "%U %W"), "01 01")   // Monday
        // 2017-01-01 is a Sunday.
        t.equal(fmt(utc(2017, 1, 1), "%U %W %V %G %u %w"), "01 00 52 2016 7 0")
        // ISO week-based year boundaries.
        t.equal(fmt(utc(2016, 1, 1), "%G-W%V %g"), "2015-W53 15")
        t.equal(fmt(utc(2014, 12, 29), "%G-W%V"), "2015-W01")
        t.equal(fmt(utc(2020, 12, 31), "%G-W%V"), "2020-W53")
        t.equal(fmt(utc(2021, 1, 4), "%G-W%V"), "2021-W01")
        // Cross-check %V / %G / %j / %u against Foundation's ISO 8601 calendar for a whole year.
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = gmt
        var mismatches = 0
        for day in 0..<800 {
            let date = utc(2019, 12, 1).addingTimeInterval(Double(day) * 86_400)
            let c = iso.dateComponents([.weekOfYear, .yearForWeekOfYear, .weekday, .day, .month, .year], from: date)
            let expected = String(format: "%04d-%02d %d %04d-%02d-%02d", c.yearForWeekOfYear!, c.weekOfYear!,
                                  (c.weekday! + 5) % 7 + 1, c.year!, c.month!, c.day!)
            if fmt(date, "%G-%V %u %Y-%m-%d") != expected { mismatches += 1 }
        }
        t.equal(mismatches, 0)
    }

    t.suite("Format: Time literal handling") {
        t.equal(fmt(sat, "%Q"), "%Q")
        t.equal(fmt(sat, "abc%"), "abc%")
        t.equal(fmt(sat, "%#"), "%#")
        t.equal(fmt(sat, "%E"), "%E")
        t.equal(fmt(sat, "%#Q|%H"), "%#Q|22")
        t.equal(fmt(sat, "no codes"), "no codes")
        t.equal(fmt(sat, "%"), "%")
        t.equal(fmt(sat, "%%%H%%"), "%22%")
        t.equal(fmt(sat, "😀 %H 😀"), "😀 22 😀")
    }
}

// MARK: - Locales

private func runTimeLocaleTests(_ t: TestRunner) {
    t.suite("Format: FormatLocale parsing") {
        t.check(TimeFormatting.locale(fromOption: nil) == nil)
        t.check(TimeFormatting.locale(fromOption: "") == nil)
        t.check(TimeFormatting.locale(fromOption: "   ") == nil)
        t.equal(TimeFormatting.locale(fromOption: "Local")?.identifier, Locale.current.identifier)
        t.equal(TimeFormatting.locale(fromOption: "local")?.identifier, Locale.current.identifier)
        func parts(_ raw: String) -> String {
            TimeFormatting.locale(fromOption: raw)?.identifier ?? "nil"
        }
        // Manual examples.
        t.equal(parts("de-DE"), "de_DE")
        t.equal(parts("FRA"), "fr_FR")
        t.equal(parts("Russian_Russia.1251"), "ru_RU")
        // Other forms.
        t.equal(parts("de_DE"), "de_DE")
        t.equal(parts("de"), "de")
        t.equal(parts("en-US"), "en_US")
        t.equal(parts("ENU"), "en_US")
        t.equal(parts("fra"), "fr_FR")
        t.equal(parts("CHS"), "zh_CN")
        t.equal(parts("German"), "de")
        t.equal(parts("english_united states"), "en_US")
        t.equal(parts("French_France.1252"), "fr_FR")
        for (raw, lang, script, region) in [("zh-Hans-CN", "zh", "Hans", "CN"), ("sr-Latn-RS", "sr", "Latn", "RS"),
                                            ("CHT", "zh", "Hant", "TW")] {
            let l = TimeFormatting.locale(fromOption: raw)
            t.equal(l?.language.languageCode?.identifier, lang, raw)
            t.equal(l?.language.script?.identifier, script, raw)
            t.equal(l?.region?.identifier, region, raw)
        }
        t.equal(parts("es-419"), "es_419")
        t.equal(parts("DE-de"), "de_DE")
        t.equal(parts("DE"), "de")
        // Unknown.
        t.equal(parts("xx-YY"), "nil")
        t.equal(parts("NotALanguage"), "nil")
        t.equal(parts("NotALanguage_Germany"), "nil")
        t.equal(parts("German_Atlantis"), "de")
        t.equal(parts("de-DE-!!"), "nil")
        t.equal(parts(String(repeating: "a", count: 500)), "nil")
    }

    t.suite("Format: FormatLocale output") {
        // Manual: TimeStamp=Wednesday, February 18, 2015 at 01:07:40 / TimeStampFormat=%A, %B %#d, %Y at %H:%M:%S /
        // TimeStampLocale=en-US / FormatLocale=de-DE / Format=%#c → "Mittwoch, 18. Februar 2015 01:07:40".
        let ts = TimeFormatting.parseTimeStamp("Wednesday, February 18, 2015 at 01:07:40",
                                               format: "%A, %B %#d, %Y at %H:%M:%S",
                                               locale: TimeFormatting.locale(fromOption: "en-US"))
        t.equal(ts, winTS(2015, 2, 18, 1, 7, 40))
        let de = TimeFormatting.locale(fromOption: "de-DE")!
        t.equal(TimeFormatting.format(windowsTimestamp: ts ?? 0, format: "%#c", locale: de),
                "Mittwoch, 18. Februar 2015 01:07:40")
        let date = utc(2015, 2, 18, 1, 7, 40)
        t.equal(fmt(date, "%A|%B|%#x|%x|%X", locale: de), "Mittwoch|Februar|Mittwoch, 18. Februar 2015|18.02.15|01:07:40")
        t.equal(fmt(date, "%c", locale: de), "18.02.15 01:07:40")
        // Numeric codes are unaffected by the locale.
        t.equal(fmt(date, "%d.%m.%Y %H:%M:%S", locale: de), "18.02.2015 01:07:40")
        let fr = TimeFormatting.locale(fromOption: "FRA")!
        t.equal(fmt(date, "%A %#d %B %Y", locale: fr), "mercredi 18 février 2015")
        let ru = TimeFormatting.locale(fromOption: "Russian_Russia.1251")!
        t.equal(fmt(date, "%A", locale: ru), "среда")
        // An explicit English locale uses that locale's patterns (not the fixed default ones).
        let enUS = TimeFormatting.locale(fromOption: "en-US")!
        t.equal(fmt(date, "%A, %B %#d, %Y", locale: enUS), "Wednesday, February 18, 2015")
        t.equal(fmt(date, "%x", locale: enUS), "2/18/15")
        t.check(fmt(date, "%X", locale: enUS).hasSuffix("AM"))
        // The default locale is the fixed "standard English format".
        t.equal(fmt(date, "%c"), "Wed Feb 18 01:07:40 2015")
        t.equal(fmt(date, "%c", locale: Locale(identifier: "en_US_POSIX")), "Wed Feb 18 01:07:40 2015")
        // locale-date / locale-time: system locale; never FormatLocale.
        let ld = fmt(date, "locale-date", locale: de)
        let lt = fmt(date, "locale-time")
        t.check(!ld.isEmpty && ld != "locale-date", ld)
        t.check(!lt.isEmpty && lt != "locale-time", lt)
        t.equal(fmt(date, "LOCALE-DATE"), fmt(date, "locale-date", locale: fr))
        t.equal(fmt(date, "locale-date %H"), "locale-date 01")   // only a whole Format is special
    }
}

// MARK: - TimeZone / DaylightSavingTime

private func runTimeZoneTests(_ t: TestRunner) {
    let ny = TimeZone(identifier: "America/New_York")!
    let summer = utc(2016, 7, 1, 12)
    let winter = utc(2016, 1, 15, 12)

    t.suite("Format: TimeZone option") {
        // "If not specified, or set to local, local time for the computer is used."
        for raw: String? in [nil, "", "local", "Local", "LOCAL", " local ", "abc", "(5+1)"] {
            t.equal(TimeFormatting.timeZone(forOption: raw, at: summer, localTimeZone: ny).identifier, ny.identifier,
                    "raw=\(String(describing: raw))")
        }
        // "TimeZone=-5 would measure the time as GMT -5.0" (DaylightSavingTime=0: no local DST offset).
        t.equal(TimeFormatting.timeZone(forOption: "-5", daylightSavingTime: false, at: summer, localTimeZone: ny)
            .secondsFromGMT(for: summer), -18_000)
        t.equal(TimeFormatting.timeZone(forOption: "5.5", daylightSavingTime: false, at: summer, localTimeZone: ny)
            .secondsFromGMT(for: summer), 19_800)
        t.equal(TimeFormatting.timeZone(forOption: "5.75", daylightSavingTime: false, at: summer, localTimeZone: ny)
            .secondsFromGMT(for: summer), 20_700)
        t.equal(TimeFormatting.timeZone(forOption: "-3.5", daylightSavingTime: false, at: summer, localTimeZone: ny)
            .secondsFromGMT(for: summer), -12_600)
        t.equal(TimeFormatting.timeZone(forOption: "0", daylightSavingTime: false, at: summer, localTimeZone: ny)
            .secondsFromGMT(for: summer), 0)
        // DaylightSavingTime=1 (default): the current local DST offset is added.
        t.equal(TimeFormatting.timeZone(forOption: "-5", at: summer, localTimeZone: ny).secondsFromGMT(for: summer), -14_400)
        t.equal(TimeFormatting.timeZone(forOption: "-5", at: winter, localTimeZone: ny).secondsFromGMT(for: winter), -18_000)
        t.equal(TimeFormatting.timeZone(forOption: "9", at: summer, localTimeZone: gmt).secondsFromGMT(for: summer), 32_400)
        // Numeric form, clamping, rounding, non-finite.
        t.equal(TimeFormatting.timeZone(offsetHours: 100, daylightSavingTime: false, localTimeZone: ny)
            .secondsFromGMT(for: summer), 64_800)
        t.equal(TimeFormatting.timeZone(offsetHours: -100, daylightSavingTime: false, localTimeZone: ny)
            .secondsFromGMT(for: summer), -64_800)
        t.equal(TimeFormatting.timeZone(offsetHours: 1.0001, daylightSavingTime: false, localTimeZone: ny)
            .secondsFromGMT(for: summer), 3_600)
        t.equal(TimeFormatting.timeZone(offsetHours: .nan, localTimeZone: ny).identifier, ny.identifier)
        t.equal(TimeFormatting.timeZone(offsetHours: .infinity, localTimeZone: ny).identifier, ny.identifier)
    }

    t.suite("Format: Time with time zones") {
        let noon = utc(2016, 7, 1, 12, 0, 0)
        let minus5 = TimeFormatting.timeZone(forOption: "-5", daylightSavingTime: false)
        t.equal(fmt(noon, "%H:%M %z", minus5), "07:00 -0500")
        t.equal(fmt(noon, "%Z", minus5), sysZoneName(minus5, daylight: false))
        t.equal(TimeZoneNames.name(of: minus5, daylight: false, locale: english), "GMT-05:00")
        let india = TimeFormatting.timeZone(forOption: "5.5", daylightSavingTime: false)
        t.equal(fmt(noon, "%H:%M %z", india), "17:30 +0530")
        t.equal(fmt(utc(2016, 7, 1, 20), "%Y-%m-%d %H", india), "2016-07-02 01")   // date rolls over
        t.equal(fmt(summer, "%H %z %Z", ny), "08 -0400 " + sysZoneName(ny, daylight: true))
        t.equal(fmt(winter, "%H %z %Z", ny), "07 -0500 " + sysZoneName(ny, daylight: false))
        // The manual's example name ("Eastern Standard Time") on an English system.
        t.equal(TimeZoneNames.name(of: ny, daylight: true, locale: english), "Eastern Daylight Time")
        t.equal(TimeZoneNames.name(of: ny, daylight: false, locale: english), "Eastern Standard Time")
        let nepal = TimeZone(identifier: "Asia/Kathmandu")!
        t.equal(fmt(noon, "%H:%M %z", nepal), "17:45 +0545")
    }
}

// MARK: - Number values

private func runTimeValueTests(_ t: TestRunner) {
    t.suite("Format: Time measure value") {
        // Windows timestamp: seconds since 1601-01-01 of the measure's wall-clock time.
        t.equal(TimeFormatting.measureValue(for: Date(timeIntervalSince1970: 0), timeZone: gmt), 11_644_473_600)
        t.equal(TimeFormatting.measureValue(for: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 3600)!),
                11_644_477_200)
        t.equal(TimeFormatting.measureValue(for: Date(timeIntervalSince1970: 0.7), timeZone: gmt), 11_644_473_600)
        t.equal(TimeFormatting.measureValue(for: Date(timeIntervalSince1970: -0.5), timeZone: gmt), 11_644_473_599)
        t.equal(TimeFormatting.measureValue(for: utc(1601, 1, 1), timeZone: gmt), 0)
        t.equal(TimeFormatting.measureValue(for: utc(2015, 1, 27, 15, 22, 30), timeZone: gmt), 13_066_845_750)
        t.equal(TimeFormatting.windowsEpochOffset, 11_644_473_600)
        let ny = TimeZone(identifier: "America/New_York")!
        let d = utc(2016, 7, 1, 12)
        t.equal(TimeFormatting.measureValue(for: d, timeZone: ny), winTS(2016, 7, 1, 8))
        t.equal(TimeFormatting.date(fromWindowsTimestamp: winTS(2016, 7, 1, 8), timeZone: ny), d)
        t.equal(TimeFormatting.date(fromWindowsTimestamp: 13_066_845_750, timeZone: gmt), utc(2015, 1, 27, 15, 22, 30))
        t.equal(TimeFormatting.measureValue(for: Date(timeIntervalSince1970: .nan), timeZone: gmt), 0)
        t.equal(TimeFormatting.date(fromWindowsTimestamp: .infinity), Date(timeIntervalSince1970: 0))
        // Formatting a timestamp shows its wall clock unchanged.
        t.equal(TimeFormatting.format(windowsTimestamp: 13_066_845_750, format: "%Y-%m-%d %H:%M:%S", nameTimeZone: ny),
                "2015-01-27 15:22:30")
        t.equal(TimeFormatting.format(windowsTimestamp: 13_066_845_750, format: "%z %Z", nameTimeZone: ny),
                "-0500 " + sysZoneName(ny, daylight: false))
        t.equal(TimeFormatting.format(windowsTimestamp: 0, format: "%F %T %A"), "1601-01-01 00:00:00 Monday")
        t.equal(TimeFormatting.format(windowsTimestamp: .nan, format: "%F"), "")
        t.equal(fmt(Date(timeIntervalSince1970: .infinity), "%F"), "")
    }

    t.suite("Format: Time value from Format") {
        // "If Format is defined, the number value will be the value defined by the format, or zero".
        t.equal(TimeFormatting.numberValue(ofFormatted: "07"), 7)
        t.equal(TimeFormatting.numberValue(ofFormatted: " 5"), 5)
        t.equal(TimeFormatting.numberValue(ofFormatted: "3:22"), 3)
        t.equal(TimeFormatting.numberValue(ofFormatted: "20150127"), 20_150_127)
        t.equal(TimeFormatting.numberValue(ofFormatted: "12-05-2015"), 12)
        t.equal(TimeFormatting.numberValue(ofFormatted: "-5 days"), -5)
        t.equal(TimeFormatting.numberValue(ofFormatted: "1.5x"), 1.5)
        t.equal(TimeFormatting.numberValue(ofFormatted: "1e3"), 1000)
        t.equal(TimeFormatting.numberValue(ofFormatted: "15e"), 15)
        t.equal(TimeFormatting.numberValue(ofFormatted: "Tuesday"), 0)
        t.equal(TimeFormatting.numberValue(ofFormatted: "PM"), 0)
        t.equal(TimeFormatting.numberValue(ofFormatted: "Week 04"), 0)
        t.equal(TimeFormatting.numberValue(ofFormatted: ""), 0)
        t.equal(TimeFormatting.numberValue(ofFormatted: "."), 0)
        t.equal(TimeFormatting.numberValue(ofFormatted: "+-3"), 0)
        t.equal(TimeFormatting.numberValue(ofFormatted: "e5"), 0)
        t.equal(TimeFormatting.numberValue(ofFormatted: "\n\t 42"), 42)
        t.equal(TimeFormatting.numberValue(ofFormatted: String(repeating: "9", count: 500)), 1e64 - 1, "bounded")
        // Release notes: Format=%S gives values 0…59.
        let v = TimeFormatting.numberValue(ofFormatted: fmt(utc(2015, 1, 27, 15, 22, 7), "%S"))
        t.equal(v, 7)
        t.equal(TimeFormatting.numberValue(ofFormatted: fmt(utc(2015, 1, 27, 15, 22, 7), "%H%M")), 1522)
    }
}

// MARK: - TimeStamp

private func runTimeStampTests(_ t: TestRunner) {
    let tue = winTS(2015, 1, 27, 15, 22, 30)

    t.suite("Format: TimeStamp manual examples") {
        t.equal(TimeFormatting.parseTimeStamp("2015-01-27T15:22:30Z", mask: "%Y-%m-%dT%H:%M:%SZ"), tue)
        t.equal(TimeFormatting.parseTimeStamp("Tue, 27 Jan 2015 15:22:30", mask: "%a, %#d %b %Y %H:%M:%S"), tue)
        t.equal(TimeFormatting.parseTimeStamp("1/27/2015 15:22:30", mask: "%#m/%#d/%Y %H:%M:%S"), tue)
        t.equal(TimeFormatting.parseTimeStamp("1/27/2105 15:22:30", mask: "%#m/%#d/%Y %H:%M:%S"), winTS(2105, 1, 27, 15, 22, 30))
        t.equal(TimeFormatting.parseTimeStamp("Tuesday, January 27, 2015 at 15:22:30", mask: "%A, %B %#d, %Y at %H:%M:%S"), tue)
        let de = TimeFormatting.locale(fromOption: "de-DE")!
        t.equal(TimeFormatting.parseTimeStamp("Montag, 16. Februar 2015 13:10:45", mask: "%A, %d. %b %Y %H:%M:%S", locale: de),
                winTS(2015, 2, 16, 13, 10, 45))
        // Through the option-level API.
        t.equal(TimeFormatting.parseTimeStamp("2015-01-27T15:22:30Z", format: "%Y-%m-%dT%H:%M:%SZ"), tue)
        t.equal(TimeFormatting.parseTimeStamp("Montag, 16. Februar 2015 13:10:45", format: "%A, %d. %b %Y %H:%M:%S",
                                              locale: de), winTS(2015, 2, 16, 13, 10, 45))
        // "If the year is not defined in the TimeStamp option, then 1900 will be used as the default year."
        t.equal(TimeFormatting.parseTimeStamp("15:22:30", mask: "%H:%M:%S"), winTS(1900, 1, 1, 15, 22, 30))
        t.equal(TimeFormatting.parseTimeStamp("27 Jan", mask: "%d %b"), winTS(1900, 1, 27))
        // "%z and %Z cannot be used in the TimeStampFormat option."
        t.equal(TimeFormatting.parseTimeStamp("2015-01-27 +0000", mask: "%Y-%m-%d %z"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015-01-27 UTC", mask: "%Y-%m-%d %Z"), nil)
        // A mask that does not match → error (nil).
        t.equal(TimeFormatting.parseTimeStamp("2015/01/27", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015/01/27", format: "%Y-%m-%d"), nil)
    }

    t.suite("Format: TimeStamp numeric") {
        // "A numeric Windows timestamp … in one-second increments since January 1, 1601".
        t.equal(TimeFormatting.parseTimeStamp("13066845750", format: nil), tue)
        t.equal(TimeFormatting.parseTimeStamp(" 13066845750.5 ", format: ""), 13_066_845_750.5)
        t.equal(TimeFormatting.parseTimeStamp("0", format: nil), 0)
        // "if the TimeStampFormat mask does not match the format of the TimeStamp option, an error will be produced":
        // with a TimeStampFormat the mask decides, a number is not a fallback.
        t.equal(TimeFormatting.parseTimeStamp("13066845750", format: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015", format: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("", format: nil), nil)
        t.equal(TimeFormatting.parseTimeStamp("abc", format: nil), nil)
        t.equal(TimeFormatting.parseTimeStamp("inf", format: nil), nil)
        t.equal(TimeFormatting.parseTimeStamp("nan", format: nil), nil)
    }

    t.suite("Format: TimeStamp mask details") {
        // 12-hour clock.
        t.equal(TimeFormatting.parseTimeStamp("3:22:30 PM", mask: "%I:%M:%S %p"), winTS(1900, 1, 1, 15, 22, 30))
        t.equal(TimeFormatting.parseTimeStamp("3:22:30 pm", mask: "%#I:%M:%S %p"), winTS(1900, 1, 1, 15, 22, 30))
        t.equal(TimeFormatting.parseTimeStamp("12:05 AM", mask: "%I:%M %p"), winTS(1900, 1, 1, 0, 5))
        t.equal(TimeFormatting.parseTimeStamp("12:05 PM", mask: "%I:%M %p"), winTS(1900, 1, 1, 12, 5))
        t.equal(TimeFormatting.parseTimeStamp("9:05", mask: "%I:%M"), winTS(1900, 1, 1, 9, 5))
        t.equal(TimeFormatting.parseTimeStamp("13:05 PM", mask: "%I:%M %p"), nil)
        // Two-digit years (POSIX pivot) and %C.
        t.equal(TimeFormatting.parseTimeStamp("01/27/15", mask: "%m/%d/%y"), winTS(2015, 1, 27))
        t.equal(TimeFormatting.parseTimeStamp("99", mask: "%y"), winTS(1999, 1, 1))
        t.equal(TimeFormatting.parseTimeStamp("68", mask: "%y"), winTS(2068, 1, 1))
        t.equal(TimeFormatting.parseTimeStamp("69", mask: "%y"), winTS(1969, 1, 1))
        t.equal(TimeFormatting.parseTimeStamp("19 05", mask: "%C %y"), winTS(1905, 1, 1))
        t.equal(TimeFormatting.parseTimeStamp("21", mask: "%C"), winTS(2100, 1, 1))
        // Day of year.
        t.equal(TimeFormatting.parseTimeStamp("2015 032", mask: "%Y %j"), winTS(2015, 2, 1))
        t.equal(TimeFormatting.parseTimeStamp("2016 366", mask: "%Y %j"), winTS(2016, 12, 31))
        t.equal(TimeFormatting.parseTimeStamp("2015 366", mask: "%Y %j"), nil)
        // Names: case-insensitive, abbreviated or full for either code.
        t.equal(TimeFormatting.parseTimeStamp("tuesday, JANUARY 27, 2015", mask: "%a, %b %d, %Y"), winTS(2015, 1, 27))
        t.equal(TimeFormatting.parseTimeStamp("Sept 3 2015", mask: "%b %d %Y"), nil)
        t.equal(TimeFormatting.parseTimeStamp("June 3 2015", mask: "%b %d %Y"), winTS(2015, 6, 3))
        t.equal(TimeFormatting.parseTimeStamp("Jun 3 2015", mask: "%B %d %Y"), winTS(2015, 6, 3))
        let de = TimeFormatting.locale(fromOption: "de-DE")!
        t.equal(TimeFormatting.parseTimeStamp("3. März 2015", mask: "%d. %B %Y", locale: de), winTS(2015, 3, 3))
        t.equal(TimeFormatting.parseTimeStamp("3. Mär 2015", mask: "%d. %b %Y", locale: de), winTS(2015, 3, 3))
        t.equal(TimeFormatting.parseTimeStamp("3. Okt. 2015", mask: "%d. %b %Y", locale: de), winTS(2015, 10, 3))
        t.equal(TimeFormatting.parseTimeStamp("3. October 2015", mask: "%d. %B %Y", locale: de), winTS(2015, 10, 3))
        // Composite codes.
        t.equal(TimeFormatting.parseTimeStamp("12/26/15 22:55:03", mask: "%D %T"), winTS(2015, 12, 26, 22, 55, 3))
        t.equal(TimeFormatting.parseTimeStamp("2015-12-26 22:55", mask: "%F %R"), winTS(2015, 12, 26, 22, 55))
        t.equal(TimeFormatting.parseTimeStamp("Sat Dec 26 22:55:03 2015", mask: "%c"), winTS(2015, 12, 26, 22, 55, 3))
        t.equal(TimeFormatting.parseTimeStamp("Saturday, December 26, 2015, 22:55:03", mask: "%#c"), winTS(2015, 12, 26, 22, 55, 3))
        t.equal(TimeFormatting.parseTimeStamp("12/26/15", mask: "%x"), winTS(2015, 12, 26))
        t.equal(TimeFormatting.parseTimeStamp("Saturday, December 26, 2015", mask: "%#x"), winTS(2015, 12, 26))
        t.equal(TimeFormatting.parseTimeStamp("10:55:03 PM", mask: "%r"), winTS(1900, 1, 1, 22, 55, 3))
        t.equal(TimeFormatting.parseTimeStamp("22:55:03", mask: "%X"), winTS(1900, 1, 1, 22, 55, 3))
        // Round trip: format then parse with the same mask.
        let d = utc(2031, 8, 9, 7, 6, 5)
        for mask in ["%c", "%#c", "%A, %B %#d, %Y %#I:%M:%S %p", "%Y%m%d%H%M%S", "%d.%m.%Y %T", "%a %e %b %Y %R:%S"] {
            let text = fmt(d, mask)
            t.equal(TimeFormatting.parseTimeStamp(text, mask: mask), winTS(2031, 8, 9, 7, 6, 5), "mask=\(mask) text=\(text)")
        }
        // Whitespace, %n / %t, literal %.
        t.equal(TimeFormatting.parseTimeStamp("2015-01-27   15:22", mask: "%Y-%m-%d %H:%M"), winTS(2015, 1, 27, 15, 22))
        t.equal(TimeFormatting.parseTimeStamp("2015-01-2715:22", mask: "%Y-%m-%d %H:%M"), winTS(2015, 1, 27, 15, 22))
        t.equal(TimeFormatting.parseTimeStamp("2015\t01", mask: "%Y%t%m"), winTS(2015, 1, 1))
        t.equal(TimeFormatting.parseTimeStamp("2015\n01", mask: "%Y%n%m"), winTS(2015, 1, 1))
        t.equal(TimeFormatting.parseTimeStamp("7% 10", mask: "%d%% %H"), winTS(1900, 1, 7, 10))
        t.equal(TimeFormatting.parseTimeStamp("7 10", mask: "%d%% %H"), nil)
        // Ignored fields.
        t.equal(TimeFormatting.parseTimeStamp("2015 W05 2", mask: "%Y W%V %u"), winTS(2015, 1, 1))
        // Trailing text is ignored; a missing part fails.
        t.equal(TimeFormatting.parseTimeStamp("2015-01-27 and more", mask: "%Y-%m-%d"), winTS(2015, 1, 27))
        t.equal(TimeFormatting.parseTimeStamp("2015-01", mask: "%Y-%m-%d"), nil)
        // Validation.
        t.equal(TimeFormatting.parseTimeStamp("2015-02-30", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2016-02-29", mask: "%Y-%m-%d"), winTS(2016, 2, 29))
        t.equal(TimeFormatting.parseTimeStamp("2015-02-29", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015-13-01", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015-00-01", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("24:00", mask: "%H:%M"), nil)
        t.equal(TimeFormatting.parseTimeStamp("23:60", mask: "%H:%M"), nil)
        t.equal(TimeFormatting.parseTimeStamp("23:59:60", mask: "%H:%M:%S"), winTS(1900, 1, 1, 23, 59, 59) + 1)
        t.equal(TimeFormatting.parseTimeStamp("x", mask: "%Q"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015", mask: "%Y%"), nil)
        t.equal(TimeFormatting.parseTimeStamp("", mask: "%Y"), nil)
        t.equal(TimeFormatting.parseTimeStamp("anything", mask: ""), winTS(1900, 1, 1))
        // Proleptic Gregorian (Foundation's Calendar switches to Julian before 1582, so use the known constant).
        t.equal(TimeFormatting.parseTimeStamp("0001-01-01", mask: "%Y-%m-%d"), -62_135_596_800 + 11_644_473_600)
    }

    t.suite("Format: TimeStamp DST codes") {
        let ny = TimeZone(identifier: "America/New_York")!
        let now = utc(2016, 1, 15, 12)
        func dst(_ code: String, _ zone: TimeZone = ny, now: Date = now) -> Double? {
            TimeFormatting.parseTimeStamp(code, format: nil, now: now, localTimeZone: zone)
        }
        // "the local date and time of the start / end of Daylight Saving Time".
        t.equal(dst("DSTStart2016"), winTS(2016, 3, 13, 2))
        t.equal(dst("DSTEnd2016"), winTS(2016, 11, 6, 2))
        t.equal(dst("DSTNextStart"), winTS(2016, 3, 13, 2))
        t.equal(dst("DSTNextEnd"), winTS(2016, 11, 6, 2))
        t.equal(dst("DSTStart"), winTS(2016, 3, 13, 2))                   // current year
        t.equal(dst("DSTEnd"), winTS(2016, 11, 6, 2))
        t.equal(dst("dststart2017"), winTS(2017, 3, 12, 2))
        t.equal(dst("DSTNextStart", now: utc(2016, 6, 1)), winTS(2017, 3, 12, 2))
        t.equal(dst("DSTNextEnd", now: utc(2016, 12, 1)), winTS(2017, 11, 5, 2))
        // TimeStampFormat is irrelevant for the codes.
        t.equal(TimeFormatting.parseTimeStamp("DSTStart2016", format: "%Y", now: now, localTimeZone: ny), winTS(2016, 3, 13, 2))
        // Southern hemisphere: start in October, end in April.
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        t.equal(dst("DSTStart2016", sydney), winTS(2016, 10, 2, 2))
        t.equal(dst("DSTEnd2016", sydney), winTS(2016, 4, 3, 3))
        // No DST in the zone → nil (error); invalid codes → nil.
        t.equal(dst("DSTStart2016", gmt), nil)
        t.equal(dst("DSTNextEnd", TimeZone(identifier: "Asia/Tokyo")!), nil)
        t.equal(dst("DSTStartXYZ"), nil)
        t.equal(dst("DSTStart123456"), nil)
        t.equal(dst("DSTStart1500"), nil)
        t.equal(dst("DSTBogus"), nil)
    }
}

// MARK: - Uptime

private func runUptimeTests(_ t: TestRunner) {
    let s = 93_784.0   // 1 day, 2 hours, 3 minutes, 4 seconds

    t.suite("Format: Uptime manual rules") {
        t.equal(UptimeFormatting.defaultFormat, "%4!i!d %3!i!:%2!02i!")
        t.equal(UptimeFormatting.format(seconds: s), "1d 2:03")
        t.equal(UptimeFormatting.format(seconds: s, format: UptimeFormatting.defaultFormat), "1d 2:03")
        // Page examples.
        t.equal(UptimeFormatting.format(seconds: s, format: "%4!i! days, %3!i! hours, %2!i! minutes %1!i! seconds"),
                "1 days, 2 hours, 3 minutes 4 seconds")
        t.equal(UptimeFormatting.format(seconds: s, format: "%4!i!d %3!i!h %2!i!m %1!i!s"), "1d 2h 3m 4s")
        t.equal(UptimeFormatting.format(seconds: s, format: "%4!i!d %3!i!h %2!i!m"), "1d 2h 3m")
        // !i! no leading zeros; !0Ni! pads to the total length N.
        t.equal(UptimeFormatting.format(seconds: 5, format: "%1!i!|%1!02i!|%1!03i!|%1!1i!"), "5|05|005|5")
        t.equal(UptimeFormatting.format(seconds: 0, format: "%4!i! %3!02i! %2!02i! %1!02i!"), "0 00 00 00")
        // AddDaysToHours (default 1): hours include days*24 when %4 is not used.
        t.equal(UptimeFormatting.format(seconds: s, format: "%3!i!:%2!02i!"), "26:03")
        t.equal(UptimeFormatting.format(seconds: s, format: "%3!i!:%2!02i!", addDaysToHours: true), "26:03")
        t.equal(UptimeFormatting.format(seconds: s, format: "%3!i!:%2!02i!", addDaysToHours: false), "2:03")
        t.equal(UptimeFormatting.format(seconds: s, format: "%4!i! %3!i!", addDaysToHours: true), "1 2")
        t.equal(UptimeFormatting.format(seconds: 10 * 86_400 + 7_200, format: "%3!i!h"), "242h")
        // Minutes and seconds stay within 0…59.
        t.equal(UptimeFormatting.format(seconds: s, format: "%2!i! %1!i!"), "3 4")
    }

    t.suite("Format: Uptime printf specs and literals") {
        let days255 = 255.0 * 86_400
        t.equal(UptimeFormatting.format(seconds: days255, format: "%4!d!|%4!u!|%4!x!|%4!X!|%4!o!"), "255|255|ff|FF|377")
        t.equal(UptimeFormatting.format(seconds: days255, format: "[%4!5d!][%4!-5d!][%4!+d!][%4!#x!][%4!.4d!]"),
                "[  255][255  ][+255][0xff][0255]")
        t.equal(UptimeFormatting.format(seconds: days255, format: "%4!ld!|%4!lu!|%4!I64d!|%4!hd!|%4!lld!"), "255|255|255|255|255")
        t.equal(UptimeFormatting.format(seconds: days255, format: "%4!s!|%4!5s!|%4!-5s!|"), "255|  255|255  |")
        t.equal(UptimeFormatting.format(seconds: 65 * 86_400, format: "%4!c!"), "A")
        t.equal(UptimeFormatting.format(seconds: days255, format: "%4!.1f!"), "255.0")
        // No spec → like !i!.
        t.equal(UptimeFormatting.format(seconds: s, format: "%4 %3 %2 %1"), "1 2 3 4")
        // Literal percent signs and unknown inserts.
        t.equal(UptimeFormatting.format(seconds: s, format: "100%"), "100%")
        t.equal(UptimeFormatting.format(seconds: s, format: "%%1 = %1"), "%1 = 4")
        t.equal(UptimeFormatting.format(seconds: s, format: "%5 %0 %a %"), "%5 %0 %a %")
        t.equal(UptimeFormatting.format(seconds: s, format: "%10"), "40")
        // Malformed specs are left as text.
        t.equal(UptimeFormatting.format(seconds: s, format: "%1!abc"), "4!abc")
        t.equal(UptimeFormatting.format(seconds: s, format: "%1!q!"), "4!q!")
        t.equal(UptimeFormatting.format(seconds: s, format: "%1!!"), "4!!")
        t.equal(UptimeFormatting.format(seconds: s, format: "%1!02i"), "4!02i")
        t.equal(UptimeFormatting.format(seconds: s, format: "%1!" + String(repeating: "0", count: 40) + "i!"),
                "4!" + String(repeating: "0", count: 40) + "i!")
        // Width is capped.
        t.equal(UptimeFormatting.format(seconds: s, format: "%1!999d!").count, 64)
        t.equal(UptimeFormatting.format(seconds: s, format: ""), "")
        t.equal(UptimeFormatting.format(seconds: s, format: "Up: ⏱ %4!i!d"), "Up: ⏱ 1d")
    }

    t.suite("Format: Uptime edge values") {
        t.equal(UptimeFormatting.format(seconds: 59.9, format: "%1!i!"), "59")
        t.equal(UptimeFormatting.format(seconds: -5), "0d 0:00")
        t.equal(UptimeFormatting.format(seconds: .nan), "0d 0:00")
        t.equal(UptimeFormatting.format(seconds: .infinity), "0d 0:00")
        t.equal(UptimeFormatting.format(seconds: 1e20, format: "%4!i!"), "11574074074")
        t.equal(UptimeFormatting.format(seconds: 1e20, format: "%3!i!"), "277777777777")
    }
}

// MARK: - Robustness

private func runFormatRobustnessTests(_ t: TestRunner) {
    t.suite("Format: fuzz") {
        var rng = LCG(state: 42)
        let pieces = ["%", "#", "E", "O", "a", "c", "x", "X", "Y", "j", "z", "Z", "p", "%%", "!", "1", "4", "02i",
                      " ", "年", "😀", "\u{0}", "\\", "i", "-", ".", "9"]
        let zones: [TimeZone] = [gmt, TimeZone(identifier: "America/New_York")!, TimeZone(secondsFromGMT: 19_800)!]
        let locales: [Locale] = [TimeFormatting.defaultLocale, Locale(identifier: "de_DE"), Locale(identifier: "ja_JP")]
        var ran = 0
        for _ in 0..<1_500 {
            var f = ""
            for _ in 0..<Int(rng.next() % 12) { f += rng.pick(pieces) }
            let seconds = Double(Int64(rng.next() % 20_000_000_000)) - 5_000_000_000
            let date = Date(timeIntervalSince1970: seconds)
            _ = TimeFormatting.format(date, format: f, timeZone: rng.pick(zones), locale: rng.pick(locales))
            _ = TimeFormatting.format(windowsTimestamp: seconds * 7, format: f)
            _ = TimeFormatting.parseTimeStamp(f, mask: rng.pick(["%Y-%m-%d", "%c", "%A %B", f, "%p%I"]))
            _ = TimeFormatting.parseTimeStamp(TimeFormatting.format(date, format: f), mask: f)
            _ = UptimeFormatting.format(seconds: seconds, format: f)
            _ = NumberFormatting.format(seconds / 3, minValue: -1, maxValue: 1,
                                        options: .init(autoScale: rng.pick([.off, .binary(minimumPower: 1), .decimal(minimumPower: 2)]),
                                                       scale: rng.pick([1, 0, 7.5]), numOfDecimals: rng.pick([nil, 0, 3]),
                                                       percentual: rng.pick([true, false])))
            _ = AutoScale.parse(f)
            _ = TimeFormatting.locale(fromOption: f)
            ran += 1
        }
        t.equal(ran, 1_500)
        // Extreme instants are clamped, never crash.
        for v in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 1e300, -1e300] {
            _ = TimeFormatting.format(Date(timeIntervalSince1970: v), format: "%c %j %U %V %G", timeZone: gmt)
            _ = TimeFormatting.format(windowsTimestamp: v, format: "%#c")
            _ = TimeFormatting.measureValue(for: Date(timeIntervalSince1970: v), timeZone: gmt)
        }
        t.check(true)
    }

    t.suite("Format: concurrency") {
        let de = Locale(identifier: "de_DE")
        let date = utc(2015, 2, 18, 1, 7, 40)
        let expectedDE = fmt(date, "%#c %A", locale: de)
        let expectedEN = fmt(date, "%#c %A")
        let lock = NSLock()
        var bad = 0
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let fr = Locale(identifier: i % 2 == 0 ? "fr_FR" : "it_IT")
            for _ in 0..<50 {
                let a = TimeFormatting.format(date, format: "%#c %A", timeZone: gmt, locale: de)
                let b = TimeFormatting.format(date, format: "%#c %A", timeZone: gmt)
                _ = TimeFormatting.format(date, format: "%x %Z", timeZone: gmt, locale: fr)
                _ = TimeFormatting.parseTimeStamp("Mittwoch, 18. Februar 2015", mask: "%A, %d. %B %Y", locale: de)
                if a != expectedDE || b != expectedEN {
                    lock.lock(); bad += 1; lock.unlock()
                }
            }
        }
        t.equal(bad, 0)
    }

    t.suite("Format: performance") {
        // These run on every update of every skin; keep them cheap (generous bounds for debug builds).
        let date = utc(2015, 12, 26, 22, 55, 3)
        let ny = TimeZone(identifier: "America/New_York")!
        let start = Date()
        var total = 0
        for i in 0..<20_000 {
            total += TimeFormatting.format(date.addingTimeInterval(Double(i)), format: "%A, %B %#d, %Y %#I:%M:%S %p",
                                           timeZone: ny).utf8.count
            total += NumberFormatting.format(Double(i) * 1234.5, minValue: 0, maxValue: 1,
                                             options: .init(autoScale: .binary(minimumPower: 0))).utf8.count
            total += UptimeFormatting.format(seconds: Double(i) * 17).utf8.count
        }
        let elapsed = Date().timeIntervalSince(start)
        t.check(total > 0)
        t.check(elapsed < 10, "20k iterations took \(elapsed)s")
    }
}


// MARK: - Review regressions (adversarial review of the format module)

private func runFormatReviewTests(_ t: TestRunner) {
    t.suite("Format: review strftime differential") {
        // Every numeric / English code against the C library's strftime (C locale, proleptic Gregorian UTC),
        // for instants spread over years 1…9999 (Windows timestamps start in 1601; TimeStamp masks can give less).
        func cstrftime(_ secs: Int, _ f: String) -> String {
            var tt = time_t(secs)
            var tmv = tm()
            gmtime_r(&tt, &tmv)
            var buf = [Int8](repeating: 0, count: 256)
            let n = strftime(&buf, 256, f, &tmv)
            return String(cString: Array(buf[0..<n]) + [0])
        }
        // Only meaningful when the process is in the C locale for LC_TIME (Swift never calls setlocale).
        guard cstrftime(0, "%A %B %p") == "Thursday January AM" else {
            t.check(true, "skipped: process LC_TIME is not C")
            return
        }
        let codes = ["a", "A", "b", "B", "C", "d", "D", "e", "F", "g", "G", "h", "H", "I", "j", "m", "M", "n", "p",
                     "r", "R", "S", "t", "T", "u", "U", "V", "w", "W", "y", "Y", "%", "c", "x", "X"]
        var rng = LCG(state: 2024)
        var mismatches: [String] = []
        for k in 0..<3_000 {
            // Year 1 (-62_135_596_800) … year 9999 (253_402_300_799), plus the edges.
            let span: UInt64 = 315_537_897_600
            var secs = Int(rng.next() % span) - 62_135_596_800
            if k == 0 { secs = -62_135_596_800 }
            if k == 1 { secs = 253_402_300_799 }
            if k == 2 { secs = -11_644_473_600 }   // 1601-01-01, Windows timestamp 0
            let date = Date(timeIntervalSince1970: TimeInterval(secs))
            for c in codes {
                let ours = TimeFormatting.format(date, format: "%" + c, timeZone: gmt)
                let theirs = cstrftime(secs, "%" + c)
                if ours != theirs, mismatches.count < 5 { mismatches.append("%\(c) @\(secs): \(ours) vs \(theirs)") }
            }
        }
        t.equal(mismatches, [])
    }

    t.suite("Format: review %Y zero padding") {
        // "# modifier: Removes leading zeros in … %#Y" → %Y has leading zeros for years below 1000 (as in C).
        let y915 = TimeFormatting.parseTimeStamp("0915-03-01", mask: "%Y-%m-%d")
        t.check(y915 != nil)
        let ts = y915 ?? 0
        t.equal(TimeFormatting.format(windowsTimestamp: ts, format: "%Y|%#Y|%F|%G|%C|%y|%#y"), "0915|915|0915-03-01|0915|09|15|15")
        let y5 = TimeFormatting.parseTimeStamp("5", mask: "%Y") ?? 0
        t.equal(TimeFormatting.format(windowsTimestamp: y5, format: "%Y %#Y %c"), "0005 5 Sat Jan  1 00:00:00 0005")   // proleptic Gregorian: a Saturday
        t.equal(TimeFormatting.format(windowsTimestamp: 0, format: "%Y %#Y"), "1601 1601")
    }

    t.suite("Format: review TimeStampLocale composites") {
        // Manual (FormatLocale / TimeStampLocale): %#c and friends return the representation "for the system locale
        // or the locale defined by TimeStampLocale or FormatLocale" and are "particularly useful for easily changing
        // between locale values from the input to the output" → what Format produces for a locale must parse back
        // with the same code in TimeStampFormat and the same TimeStampLocale.
        let de = TimeFormatting.locale(fromOption: "de-DE")!
        t.equal(TimeFormatting.parseTimeStamp("Mittwoch, 18. Februar 2015 01:07:40", format: "%#c", locale: de),
                winTS(2015, 2, 18, 1, 7, 40))
        t.equal(TimeFormatting.parseTimeStamp("Mittwoch, 18. Februar 2015", format: "%#x", locale: de), winTS(2015, 2, 18))
        // en-US %X is 12-hour: "1:07:40 PM" is 13:07:40 (it used to be misread as 01:07:40 through "%H:%M:%S").
        let enUS = TimeFormatting.locale(fromOption: "en-US")!
        t.equal(TimeFormatting.parseTimeStamp("1:07:40 PM", format: "%X", locale: enUS), winTS(1900, 1, 1, 13, 7, 40))
        t.equal(TimeFormatting.parseTimeStamp("2/18/15 1:07:40 PM", format: "%c", locale: enUS), winTS(2015, 2, 18, 13, 7, 40))
        // Round trip for many locales and all five locale codes.
        let d = utc(2015, 2, 18, 13, 7, 40)
        let expected: [String: Double] = ["%#c": winTS(2015, 2, 18, 13, 7, 40), "%c": winTS(2015, 2, 18, 13, 7, 40),
                                          "%x": winTS(2015, 2, 18), "%#x": winTS(2015, 2, 18),
                                          "%X": winTS(1900, 1, 1, 13, 7, 40)]
        var names = ["de-DE", "fr-FR", "ru-RU", "zh-CN", "ja-JP", "ko-KR", "en-US", "en-GB", "pt-BR", "es-ES", "it-IT",
                     "pl-PL", "tr-TR", "ar-SA", "he-IL", "th-TH", "hi-IN", "FRA", "CHT", "Russian_Russia.1251"]
        if let local = TimeFormatting.locale(fromOption: "Local"), let info = Optional(LocaleTimeInfo.info(for: local)),
           info.isEnglishDefault || (info.shortDateMask != nil && info.fullDateMask != nil && info.mediumTimeMask != nil) {
            names.append("Local")
        }
        var failures: [String] = []
        for name in names {
            guard let loc = TimeFormatting.locale(fromOption: name) else { failures.append("no locale \(name)"); continue }
            for (code, value) in expected {
                let text = fmt(d, code, locale: loc)
                let back = TimeFormatting.parseTimeStamp(text, format: code, locale: loc)
                if back != value { failures.append("\(name) \(code) \(text.debugDescription) → \(String(describing: back))") }
            }
        }
        t.equal(failures, [])
        // The English patterns stay accepted as a fallback for a locale mask.
        t.equal(TimeFormatting.parseTimeStamp("Wed Feb 18 01:07:40 2015", format: "%c", locale: de), winTS(2015, 2, 18, 1, 7, 40))
        // %T is ISO (never locale), %X is the locale's time.
        t.equal(TimeFormatting.parseTimeStamp("13:07:40", format: "%T", locale: enUS), winTS(1900, 1, 1, 13, 7, 40))
        // Composite codes inside a larger mask, and a mismatch.
        t.equal(TimeFormatting.parseTimeStamp("Datum: 18.02.15 um 13:07:40 Uhr", format: "Datum: %x um %X Uhr", locale: de),
                winTS(2015, 2, 18, 13, 7, 40))
        t.equal(TimeFormatting.parseTimeStamp("18-02-15", format: "%x", locale: de), nil)
        // locale-date / locale-time in TimeStampFormat: the system locale, whatever TimeStampLocale says.
        let ldText = fmt(d, "locale-date", locale: de)
        let ltText = fmt(d, "locale-time", locale: de)
        t.equal(TimeFormatting.parseTimeStamp(ldText, format: "locale-date", locale: de), winTS(2015, 2, 18), ldText)
        t.equal(TimeFormatting.parseTimeStamp(ltText, format: "LOCALE-TIME"), winTS(1900, 1, 1, 13, 7, 40), ltText)
        t.equal(TimeFormatting.parseTimeStamp("locale-date", mask: "locale-date x"), nil)   // only a whole mask is special
    }

    t.suite("Format: review ICU pattern to mask") {
        func m(_ p: String) -> String? {
            LocaleTimeInfo.mask(fromICUPattern: p, eraShort: "AD", eraLong: "Anno Domini").map { String($0) }
        }
        t.equal(m("EEEE, d. MMMM y"), "%A, %d. %B %Y")
        t.equal(m("dd.MM.yy"), "%d.%m.%y")
        t.equal(m("M/d/yy"), "%m/%d/%y")
        t.equal(m("h:mm:ss a"), "%I:%M:%S %p")
        t.equal(m("HH:mm:ss"), "%H:%M:%S")
        t.equal(m("Bh:mm:ss"), "%p%I:%M:%S")
        t.equal(m("EEEE, d MMMM y 'г'."), "%A, %d %B %Y г.")
        t.equal(m("y年M月d日 EEEE"), "%Y年%m月%d日 %A")
        t.equal(m("EEEE, d בMMMM y"), "%A, %d ב%B %Y")
        t.equal(m("EEE d MMM"), "%a %d %b")
        t.equal(m("cccc LLLL D"), "%A %B %j")
        t.equal(m("G y"), "AD %Y")
        t.equal(m("GGGG y"), "Anno Domini %Y")
        t.equal(m("'o''clock' h"), "o'clock %I")
        t.equal(m("''h"), "'%I")
        t.equal(m("h 'at 100%'"), "%I at 100%%")
        t.equal(m("h%"), "%I%%")
        t.equal(m("'unterminated"), "unterminated")
        t.equal(m("HH:mm:ss zzzz"), nil)     // time zones cannot be expressed (and %Z is not allowed)
        t.equal(m("HH:mm:ss.SSS"), nil)
        t.equal(m("QQQ y"), nil)
        t.equal(m(""), nil)
        t.equal(m(String(repeating: "y", count: 300)), nil)
    }

    t.suite("Format: review stand-alone names") {
        // %A / %B are "the day of week name" / "month name": the dictionary (stand-alone) form, not the form
        // inflected for use inside a date.
        let d = utc(2015, 2, 18, 13, 7, 40)
        func f(_ l: String, _ code: String) -> String { fmt(d, code, locale: TimeFormatting.locale(fromOption: l)!) }
        t.equal(f("ru-RU", "%B"), "февраль")
        t.equal(f("pl-PL", "%B"), "luty")
        t.equal(f("ca-ES", "%B"), "febrer")
        t.equal(f("fi-FI", "%A|%B"), "keskiviikko|helmikuu")
        t.equal(f("de-DE", "%a %b"), "Mi Feb")
        t.equal(f("de-DE", "%A %B"), "Mittwoch Februar")
        // Full dates keep the locale's inflection.
        t.check(f("ru-RU", "%#x").hasPrefix("среда, 18 февраля 2015"), f("ru-RU", "%#x"))
        // Parsing accepts both forms.
        let ru = TimeFormatting.locale(fromOption: "ru-RU")!
        t.equal(TimeFormatting.parseTimeStamp("18 февраля 2015", mask: "%d %B %Y", locale: ru), winTS(2015, 2, 18))
        t.equal(TimeFormatting.parseTimeStamp("Февраль 2015", mask: "%B %Y", locale: ru), winTS(2015, 2, 1))
        let ca = TimeFormatting.locale(fromOption: "ca-ES")!
        t.equal(TimeFormatting.parseTimeStamp("18 de febrer 2015", mask: "%d %B %Y", locale: ca), winTS(2015, 2, 18))
        t.equal(TimeFormatting.parseTimeStamp("18 febrer 2015", mask: "%d %B %Y", locale: ca), winTS(2015, 2, 18))
        let de = TimeFormatting.locale(fromOption: "de-DE")!
        t.equal(TimeFormatting.parseTimeStamp("Mi., 18. Feb. 2015", mask: "%a, %d. %b %Y", locale: de), winTS(2015, 2, 18))
        t.equal(TimeFormatting.parseTimeStamp("Mi, 18. Feb 2015", mask: "%a, %d. %b %Y", locale: de), winTS(2015, 2, 18))
        // Legacy MS-LCID culture names.
        t.equal(TimeFormatting.locale(fromOption: "zh-CHS")?.language.script?.identifier, "Hans")
        t.equal(TimeFormatting.locale(fromOption: "zh-CHT")?.language.script?.identifier, "Hant")
        t.equal(fmt(d, "%A", locale: TimeFormatting.locale(fromOption: "zh-CHS")!), "星期三")
    }

    t.suite("Format: review locale parse fuzz") {
        // Hostile TimeStamp strings against locale composite masks: never crash, never hang.
        var rng = LCG(state: 77)
        let locales = ["ar-SA", "ko-KR", "de-DE", "th-TH", "zh-TW", "fi-FI", "Local"].compactMap { TimeFormatting.locale(fromOption: $0) }
        let masks = ["%c", "%#c", "%x", "%#x", "%X", "%X %x", "%#c%#c%#c", "%a%A%b%B%p", "%Ec %Ox"]
        let pieces = ["١", "٢", "0", "9", "12", "/", ".", ":", " ", "\u{200F}", "م", "오후", "下午", "Mi.", "Februar",
                      "г.", "ค.ศ.", "'", "%", "\u{0}", "😀", "年", "\t", "PM"]
        let start = Date()
        var ran = 0
        for _ in 0..<3_000 {
            var text = ""
            for _ in 0..<Int(rng.next() % 16) { text += rng.pick(pieces) }
            _ = TimeFormatting.parseTimeStamp(text, format: rng.pick(masks), locale: rng.pick(locales))
            ran += 1
        }
        let long = String(repeating: "١٢/", count: 2_000)
        _ = TimeFormatting.parseTimeStamp(long, format: String(repeating: "%x", count: 400), locale: locales[0])
        t.equal(ran, 3_000)
        t.check(Date().timeIntervalSince(start) < 10)
    }

    t.suite("Format: review TimeStamp digits") {
        // Locale digits (Arabic-Indic, Devanagari, full-width) are read as numbers; other numeric characters are not.
        t.equal(TimeFormatting.parseTimeStamp("٢٠١٥-٠٢-١٨", mask: "%Y-%m-%d"), winTS(2015, 2, 18))
        t.equal(TimeFormatting.parseTimeStamp("२०१५-०२-१८", mask: "%Y-%m-%d"), winTS(2015, 2, 18))
        t.equal(TimeFormatting.parseTimeStamp("２０１５-０２-１８", mask: "%Y-%m-%d"), winTS(2015, 2, 18))
        t.equal(TimeFormatting.parseTimeStamp("2015-Ⅻ-01", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015-万-01", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015-½-01", mask: "%Y-%m-%d"), nil)
        t.equal(TimeFormatting.parseTimeStamp("2015-1\u{301}2-01", mask: "%Y-%m-%d"), nil)   // digit + combining mark
    }
}
