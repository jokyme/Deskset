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

    t.suite("Studio add: data shown as a number, a bar, a ring, a graph") {
        func ini(_ sections: [EditorComponents.Section], head: String = "") -> String {
            "[Rainmeter]\nUpdate=1000\n" + head + sections.map { s in
                "\n[\(s.name)]\n" + s.options.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
            }.joined()
        }
        let number = StudioAddCatalog.sections(data: "cpu", look: .number, x: 10, y: 20, existing: [], variables: [])
        t.equal(number.map(\.name), ["MeasureCPU", "MeterCPU"])
        t.equal(number[1].options.first { $0.key == "Text" }?.value, "%1%")
        t.equal(number[1].options.first { $0.key == "X" }?.value, "10")
        let (skin, _) = try makeSkin(t, ini(number))
        skin.update()
        t.check(text(skin, "MeterCPU").hasSuffix("%"), "the number reads the CPU: \(text(skin, "MeterCPU"))")
        let ring = StudioAddCatalog.sections(data: "memory", look: .ring, x: 0, y: 0, existing: ["measurememory"],
                                             variables: ["accentcolor"])
        t.equal(ring.map(\.name), ["MeasureMemory2", "MeterMemoryRingTrack", "MeterMemoryRing", "MeterMemoryRingValue"],
                "names the widget does not have yet")
        t.equal(ring[2].options.first { $0.key == "LineColor" }?.value, "#AccentColor#", "the widget's own accent")
        t.equal(ring[3].options.first { $0.key == "Text" }?.value, "%1B")
        let reused = StudioAddCatalog.sections(data: "cpu", look: .bar, x: 0, y: 0, existing: [], variables: [],
                                               reuse: "MeasureProcessor")
        t.equal(reused.map(\.name), ["MeterCPUBar"], "the widget's own measure: no new one")
        t.equal(reused[0].options.first { $0.key == "MeasureName" }?.value, "MeasureProcessor")
        let disk = StudioAddCatalog.sections(data: "disk", look: .number, x: 0, y: 0, existing: [], variables: [])
        t.check(disk[1].options.contains { $0.key == "Percentual" && $0.value == "1" }, "disk used in percent")
        for item in StudioAddCatalog.data {
            for look in item.looks {
                let s = StudioAddCatalog.sections(data: item.id, look: look, x: 0, y: 0, existing: [], variables: [])
                t.check(s.contains { $0.options.contains { $0.key == "Meter" } }, "\(item.id) as \(look): a part")
            }
        }
    }

    t.suite("Studio add: parts, symbols, the widget's own data, search") {
        for part in StudioAddCatalog.Part.allCases {
            let s = StudioAddCatalog.sections(part: part, x: 4, y: 8, existing: [], variables: [])
            t.check(s.contains { $0.options.contains { $0.key == "Meter" } }, "\(part): a part")
            t.check(EditorComponents.component(part.dragComponent) != nil, "\(part) drags a known ghost")
        }
        let symbol = StudioAddCatalog.symbolSections("umbrella.fill", x: 0, y: 0, existing: ["metersymbol"], variables: [])
        t.equal(symbol.first?.name, "MeterSymbol2")
        t.equal(symbol.first?.options.first { $0.key == "ImageName" }?.value, "sf:umbrella.fill")
        let ini = """
            [Rainmeter]
            Update=1000

            [MeasureProcessor]
            Measure=CPU

            [MeasureRAMTotal]
            Measure=PhysicalMemory
            Total=1

            [MeasureDown]
            Measure=NetIn
            """
        let (skin, _) = try makeSkin(t, ini)
        t.equal(StudioAddCatalog.existingMeasure(for: "cpu", in: skin), "MeasureProcessor", "Processor=0 is the default")
        t.equal(StudioAddCatalog.existingMeasure(for: "memory", in: skin), nil, "a total is not the memory used")
        t.equal(StudioAddCatalog.existingMeasure(for: "download", in: skin), "MeasureDown")
        t.equal(StudioAddCatalog.existingMeasure(for: "time", in: skin), nil, "only this Mac's data is shared")
        // Measures of the same data that read something else, or don't run, are not reused.
        let other = """
            [Rainmeter]
            Update=1000

            [MeasureIdle]
            Measure=CPU
            InvertMeasure=1

            [MeasureFree]
            Measure=PhysicalMemory
            Free=1

            [MeasureTotalDown]
            Measure=NetIn
            Cumulative=1

            [MeasureOff]
            Measure=NetOut
            Disabled=1

            [MeasureGPUPaused]
            Measure=Plugin
            Plugin=MacSensors
            Sensor=gpu.usage
            MinValue=0
            MaxValue=100
            Paused=1
            """
        let (others, _) = try makeSkin(t, other)
        for id in ["cpu", "memory", "download", "upload", "gpu"] {
            t.equal(StudioAddCatalog.existingMeasure(for: id, in: others), nil, "\(id): not a measure that reads otherwise")
        }
        t.equal(StudioAddCatalog.search("net").map(\.id), ["download", "upload"])
        t.equal(StudioAddCatalog.search("内存").map(\.id), ["memory"])
        t.equal(StudioAddCatalog.search("weather").map(\.id), ["temperature"])
        t.equal(StudioAddCatalog.search("").count, StudioAddCatalog.data.count)
    }
}
