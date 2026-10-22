import Foundation
@testable import DesksetCore

// TimeStamp forms and option-update behavior, from the public Time measure and Variables manual pages.
func runTimeMeasureTests(_ t: TestRunner) {
    t.suite("Time measure: timestamp formulas and numeric values") {
        let (skin, host) = try makeSkin(t, """
        [Formatted]
        Measure=Time
        TimeStamp=(11644473600 + 3600)
        Format=%Y-%m-%d %H:%M:%S
        TimeZone=9
        DaylightSavingTime=0
        [Numeric]
        Measure=Time
        TimeStamp=(11644473600 + 3600)
        [Literal]
        Measure=Time
        TimeStamp=11644477200
        [Epoch]
        Measure=Time
        TimeStamp=(1 - 1)
        [Display]
        Meter=String
        MeasureName=Formatted
        """)
        defer { skin.close() }
        skin.update()
        t.equal(text(skin, "Display"), "1970-01-01 01:00:00", "TimeZone does not offset an explicit timestamp")
        t.equal(skin.measure(named: "Formatted")!.value, 1970, "Format determines the normal numeric value")
        t.equal(skin.resolve("[Formatted:Timestamp]", in: nil, sectionVariables: true), "11644477200")
        t.equal(skin.measure(named: "Numeric")!.value, 11_644_477_200)
        t.equal(skin.measure(named: "Numeric")!.stringValue, "01:00:00")
        t.equal(skin.measure(named: "Numeric")!.value, skin.measure(named: "Literal")!.value)
        t.equal(skin.measure(named: "Epoch")!.value, 0, "zero is a valid formula result, not the current time")
        t.check(host.logs.isEmpty, "valid timestamp formulas must not log parse errors")
    }

    t.suite("Time measure: timestamp formulas follow option reads") {
        let (skin, _) = try makeSkin(t, """
        [Variables]
        Seconds=3600
        [Static]
        Measure=Time
        TimeStamp=(11644473600 + #Seconds#)
        [Dynamic]
        Measure=Time
        TimeStamp=(11644473600 + #Seconds#)
        DynamicVariables=1
        [Source]
        Measure=Calc
        Formula=#Seconds#
        DynamicVariables=1
        [StaticSection]
        Measure=Time
        TimeStamp=(11644473600 + [Source:])
        [Section]
        Measure=Time
        TimeStamp=(11644473600 + [Source:])
        DynamicVariables=1
        [Identifier]
        Measure=Time
        TimeStamp=(11644473600 + Source)
        DynamicVariables=1
        """)
        defer { skin.close() }
        skin.update()
        for name in ["Static", "StaticSection", "Dynamic", "Section", "Identifier"] {
            t.equal(skin.measure(named: name)!.value, 11_644_477_200, name)
        }
        skin.execute("[!SetVariable Seconds 7200]", from: nil)
        skin.update()
        t.equal(skin.measure(named: "Static")!.value, 11_644_477_200, "a static formula stays frozen")
        t.equal(skin.measure(named: "StaticSection")!.value, 11_644_477_200, "a static section reference freezes after its initial read")
        for name in ["Dynamic", "Section", "Identifier"] {
            t.equal(skin.measure(named: name)!.value, 11_644_480_800, name)
        }
        skin.execute("[!SetOption Static TimeStamp \"(11644473600 + 10800)\"][!UpdateMeasure Static]", from: nil)
        t.equal(skin.measure(named: "Static")!.value, 11_644_484_400, "SetOption rereads a static formula")
        skin.execute("[!SetOption Static TimeStamp 11644473600][!UpdateMeasure Static]", from: nil)
        t.equal(skin.measure(named: "Static")!.value, 11_644_473_600, "a literal clears the cached formula")
    }

    t.suite("Time measure: timestamp masks retain control of their input") {
        let (skin, host) = try makeSkin(t, """
        [Date]
        Measure=Time
        TimeStamp=(1970-01-02)
        TimeStampFormat=(%Y-%m-%d)
        Format=%Y-%m-%d
        [Year]
        Measure=Time
        TimeStamp=1971
        TimeStampFormat=%Y
        Format=%Y-%m-%d
        [DST]
        Measure=Time
        TimeStamp=DSTStart2027
        Format=%Y-%m-%d %H:%M:%S
        [Changing]
        Measure=Time
        TimeStamp=(11644473600 + 3600)
        Format=%Y-%m-%d
        """)
        defer { skin.close() }
        skin.skinClock = .fixed(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "America/New_York")!)
        skin.update()
        t.equal(skin.measure(named: "Date")!.stringValue, "1970-01-02", "parentheses can be literal mask text")
        t.equal(skin.measure(named: "Year")!.stringValue, "1971-01-01", "a masked number is not a Windows timestamp")
        t.equal(skin.measure(named: "DST")!.stringValue, "2027-03-14 02:00:00")
        skin.execute("[!SetOption Changing TimeStamp \"(1970-01-03)\"][!SetOption Changing TimeStampFormat \"(%Y-%m-%d)\"][!UpdateMeasure Changing]", from: nil)
        t.equal(skin.measure(named: "Changing")!.stringValue, "1970-01-03", "adding a mask clears the formula result")
        skin.execute("[!SetOption Changing TimeStampFormat \"\"][!SetOption Changing TimeStamp \"(11644473600 + 259200)\"][!UpdateMeasure Changing]", from: nil)
        t.equal(skin.measure(named: "Changing")!.stringValue, "1970-01-04", "removing the mask enables formulas again")
        t.check(host.logs.isEmpty, "valid masked timestamps and DST codes remain valid")
    }

    t.suite("Time measure: invalid timestamps log once and recover") {
        let (skin, host) = try makeSkin(t, """
        [Invalid]
        Measure=Time
        TimeStamp=(11644473600 + )
        DynamicVariables=1
        TimeZone=0
        DaylightSavingTime=0
        [Missing]
        Measure=Time
        TimeStampFormat=%Y-%m-%d
        [MaskedFormula]
        Measure=Time
        TimeStamp=(11644473600 + 3600)
        TimeStampFormat=%Y-%m-%d
        [Current]
        Measure=Time
        TimeZone=0
        DaylightSavingTime=0
        """)
        defer { skin.close() }
        skin.skinClock = .fixed(Date(timeIntervalSince1970: 3600), timeZone: TimeZone(secondsFromGMT: 0)!)
        for _ in 0..<3 { skin.update() }
        for name in ["Invalid", "Missing", "MaskedFormula"] {
            t.equal((skin.measure(named: name) as! TimeMeasure).timestamp, 0, name)
            t.equal(host.logs.filter { $0.contains("[\(name)] TimeStamp") }.count, 1, "one diagnostic for \(name)")
        }
        t.equal(skin.measure(named: "Current")!.value, 11_644_477_200, "no timestamp and no mask still uses the clock")
        skin.execute("[!SetOption Invalid TimeStamp \"(11644473600 + 7200)\"][!UpdateMeasure Invalid]", from: nil)
        t.equal(skin.measure(named: "Invalid")!.value, 11_644_480_800, "a corrected formula recovers")
        skin.execute("[!SetOption Invalid TimeStamp \"(UnknownTimestamp + 1)\"][!UpdateMeasure Invalid]", from: nil)
        t.equal(skin.measure(named: "Invalid")!.value, 0, "failed evaluation clears a previous result")
        t.equal(host.logs.filter { $0.contains("[Invalid] TimeStamp") }.count, 1, "dynamic errors do not spam the log")
        skin.execute("[!SetOption Invalid TimeStamp \"\"][!UpdateMeasure Invalid]", from: nil)
        t.equal(skin.measure(named: "Invalid")!.value, 11_644_477_200, "removing the timestamp returns to the clock")
    }
}
