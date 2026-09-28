import Foundation
@testable import DesksetCore

// What needs attention in a part of an INI widget on a Mac (the Studio's amber dots): Windows-only data, through the
// formulas built from it, and clicks that open Windows programs.

func runStudioPartIssuesTests(_ t: TestRunner) {
    t.suite("Studio parts: Windows paths") {
        for path in ["C:\\Program Files (x86)\\Steam\\steam.exe", "D:/Games/run.exe", "\\\\server\\share",
                     "notepad.exe", "C:\\Users\\Public\\Documents", "shortcut.lnk", "Folder\\Sub"] {
            t.check(StudioPartIssues.isWindowsPath(path), "\(path) is a Windows path")
        }
        for path in ["https://example.com/a\\b", "mailto:me@example.com", "/Applications/Music.app", "~/Documents",
                     "#@#Styles.inc", "", "Notes.txt"] {
            t.check(!StudioPartIssues.isWindowsPath(path), "\(path) is not")
        }
        t.equal(StudioPartIssues.programName("C:\\Program Files (x86)\\Steam\\steam.exe"), "steam")
        t.equal(StudioPartIssues.programName("C:\\Users\\Public\\Documents"), "Documents")
        t.equal(StudioPartIssues.pluginName("Plugins\\HWiNFO.dll"), "HWiNFO")
    }

    t.suite("Studio parts: what needs attention") {
        let ini = """
            [Rainmeter]
            Update=1000

            [Variables]
            SteamPath=C:\\Program Files (x86)\\Steam\\steam.exe

            [MeasureCPU]
            Measure=CPU

            [MeasureTemp]
            Measure=Plugin
            Plugin=HWiNFO
            HWiNFOSensorId=0x1

            [MeasureTempC]
            Measure=Calc
            Formula=MeasureTemp

            [MeasureTempText]
            Measure=String
            String=[MeasureTempC]°
            DynamicVariables=1

            [MeterCPU]
            Meter=String
            MeasureName=MeasureCPU
            LeftMouseUpAction=["/System/Applications/Utilities/Activity Monitor.app"]

            [MeterTemp]
            Meter=String
            MeasureName=MeasureTempC
            Postfix=°C

            [MeterTempText]
            Meter=String
            MeasureName=MeasureTempText

            [MeterSteam]
            Meter=String
            Text=STEAM
            LeftMouseUpAction=[!SetOption MeterSteam FontColor 255,255,255]["#SteamPath#"]
            """
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        func issues(_ name: String) -> [StudioPartIssue] {
            StudioPartIssues.issues(of: skin.meter(named: name)!, in: skin)
        }
        t.equal(issues("MeterCPU"), [], "CPU and a Mac app: nothing")
        t.check(StudioPartIssues.isWindowsOnly(skin.measure(named: "MeasureTemp")!), "a HWiNFO sensor is Windows-only")
        t.equal(issues("MeterTemp"), [.windowsData(measure: "MeasureTemp", plugin: "HWiNFO")],
                "a formula built from it: the sensor")
        t.equal(issues("MeterTempText"), [.windowsData(measure: "MeasureTemp", plugin: "HWiNFO")],
                "a text built from the formula: the sensor")
        t.equal(issues("MeterSteam"), [.windowsProgram(key: "LeftMouseUpAction",
                                                        target: "C:\\Program Files (x86)\\Steam\\steam.exe")],
                "a click that opens a Windows program (a variable's value)")
        t.equal(issues("MeterSteam").first?.programName, "steam")
        t.equal(StudioPartIssues.issue(of: skin.measure(named: "MeasureTempC")!, in: skin),
                .windowsData(measure: "MeasureTemp", plugin: "HWiNFO"))
        t.equal(StudioPartIssues.issue(of: skin.measure(named: "MeasureCPU")!, in: skin), nil)
    }

    t.suite("Studio symbols: everyday names and search") {
        t.equal(StudioSymbolIndex.name(of: "laptopcomputer", chinese: false), "Laptop")
        t.equal(StudioSymbolIndex.name(of: "laptopcomputer", chinese: true), "笔记本电脑")
        t.equal(StudioSymbolIndex.name(of: "cpu.fill", chinese: false), "Chip", "a drawing variant: its base")
        t.equal(StudioSymbolIndex.name(of: "battery.25", chinese: false), "Battery")
        t.equal(StudioSymbolIndex.name(of: "arrow.triangle.2.circlepath", chinese: false), "Arrow triangle 2 circlepath",
                "not in the index: its words")
        t.equal(StudioSymbolIndex.search("umbrella").first?.symbol, "umbrella.fill")
        t.equal(StudioSymbolIndex.search("雨伞").first?.symbol, "umbrella.fill", "Chinese")
        t.equal(StudioSymbolIndex.search("rain").first?.symbol, "cloud.rain.fill", "a name before a keyword")
        t.check(StudioSymbolIndex.search("rain").contains { $0.symbol == "umbrella.fill" }, "a keyword finds it too")
        t.check(StudioSymbolIndex.search("gamecontroller").contains { $0.symbol == "gamecontroller.fill" }, "the code name")
        t.equal(StudioSymbolIndex.search("").count, StudioSymbolIndex.all.count)
        t.equal(StudioSymbolIndex.search("zzzz"), [])
        let symbols = StudioSymbolIndex.all.map(\.symbol)
        t.equal(Set(symbols).count, symbols.count, "no symbol twice")
    }
}
