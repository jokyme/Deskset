import Foundation
@testable import DesksetCore

// Sample data for the Studio's own instance of a widget (`MeasureValueOverride`, `Skin.measureValues`).

func runSampleDataTests(_ t: TestRunner) {
    let ini = """
        [Rainmeter]
        Update=1000

        [Variables]
        Hot=0

        [MeasureCPU]
        Measure=CPU
        IfCondition=MeasureCPU > 80
        IfTrueAction=[!SetOption MeterValue FontColor 224,76,62][!SetVariable Hot 1]
        IfFalseAction=[!SetOption MeterValue FontColor 34,34,38][!SetVariable Hot 0]

        [MeasureDouble]
        Measure=Calc
        Formula=MeasureCPU * 2

        [MeasureUser]
        Measure=SysInfo
        SysInfoType=USER_NAME

        [MeasureTime]
        Measure=Time
        Format=%H:%M

        [MeasureFixed]
        Measure=Time
        TimeStamp=13000000000
        Format=%Y

        [MeasureLoop]
        Measure=Loop
        StartValue=1
        EndValue=100

        [MeterValue]
        Meter=String
        MeasureName=MeasureCPU
        Text=%1%
        FontColor=34,34,38

        [MeterUser]
        Meter=String
        MeasureName=MeasureUser
        Y=20

        """

    t.suite("Session: sample data") {
        let system = FakeSystem()
        system.cpu = 42
        let (studio, _) = try makeSkin(t, ini, system: system)
        let (desktop, _) = try makeSkin(t, ini, system: system)
        studio.update()
        desktop.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 42, "live at first")
        t.equal(studio.meter(named: "MeterValue")?.string("FontColor"), "34,34,38")

        let sample = MeasureValueOverride()
        studio.measureValues = sample
        t.check(!sample.isActive, "live: nothing replaced")
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 42)

        // 100 %: the rule fires in the Studio's instance only.
        sample.data = .level(1)
        studio.update()
        desktop.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 100, "100 % of the processor's range")
        t.equal(text(studio, "MeterValue"), "100%")
        t.equal(studio.meter(named: "MeterValue")?.string("FontColor"), "224,76,62", "the rule turned it red")
        t.equal(studio.variable("Hot"), "1")
        t.equal(studio.measure(named: "MeasureDouble")?.value, 200, "a Calc works from the sample value")
        t.equal(desktop.measure(named: "MeasureCPU")?.value, 42, "the desktop copy stays live")
        t.equal(desktop.meter(named: "MeterValue")?.string("FontColor"), "34,34,38", "and its rule did not fire")
        let loop = studio.measure(named: "MeasureLoop")?.value ?? 0
        studio.update()
        t.equal(studio.measure(named: "MeasureLoop")?.value, loop + 1, "a Loop is the widget's own: it goes on")

        sample.data = .level(0.5)
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 50)
        t.equal(studio.meter(named: "MeterValue")?.string("FontColor"), "34,34,38", "below 80: the other action")
        sample.data = .level(0)
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 0)
        sample.data = .level(7)
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 100, "a share is kept within the range")

        // Paused: nothing is read.
        sample.data = .live
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 42)
        sample.data = .paused
        system.cpu = 90
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 42, "paused keeps the last value")
        sample.data = .live
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 90, "live again")
        system.cpu = 42

        // Long text and no data.
        sample.data = .longText
        studio.update()
        t.equal(text(studio, "MeterUser"), MeasureValueOverride.longSample, "a text becomes the long one")
        t.equal(studio.measure(named: "MeasureCPU")?.value, 42, "numbers stay live")
        sample.data = .noData
        studio.update()
        t.equal(studio.measure(named: "MeasureCPU")?.value, 0)
        t.equal(text(studio, "MeterUser"), "", "no data: an empty text")
        t.equal(text(studio, "MeterValue"), "0%")

        // Frozen time.
        sample.data = .live
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 27; parts.hour = 10; parts.minute = 9
        let frozen = Calendar.current.date(from: parts)!
        sample.frozenTime = frozen
        t.check(sample.isActive)
        studio.update()
        t.equal(studio.measure(named: "MeasureTime")?.stringValue, "10:09", "time measures show the frozen instant")
        t.equal(studio.measure(named: "MeasureTime")?.value, TimeFormatting.numberValue(ofFormatted: "10:09"),
                "its number, from the formatted text as a Time measure reads it")
        t.equal(studio.measure(named: "MeasureFixed")?.stringValue, desktop.measure(named: "MeasureFixed")?.stringValue,
                "one with a TimeStamp keeps it")
        t.check(desktop.measure(named: "MeasureTime")?.stringValue != nil)
        sample.frozenTime = nil
        func sameTime() -> Bool {
            studio.update()
            desktop.update()
            return studio.measure(named: "MeasureTime")?.stringValue == desktop.measure(named: "MeasureTime")?.stringValue
        }
        // A minute may turn between the two updates: then once more.
        t.check(sameTime() || sameTime(), "live time again (both read the clock)")
    }

    t.suite("Session: sample data: which measures read data") {
        let (skin, _) = try makeSkin(t, ini)
        let reads = skin.measures.filter(MeasureValueOverride.readsData).map(\.name)
        t.equal(reads, ["MeasureCPU", "MeasureUser"], "the processor and the user name; not Calc, Time or Loop")
    }
}
