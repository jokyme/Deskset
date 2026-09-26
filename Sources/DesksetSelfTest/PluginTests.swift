import Darwin
import Foundation
@testable import DesksetCore

// Core plugin tests (suite prefix "Plugin"). Deterministic: temporary folders, fake data sources, localhost pings
// only; helper programs (open / osascript) are never launched (PluginProcess.launcher records them instead).
// Measures are taken from the skin when the engine creates them through MeasureRegistry, and constructed directly
// otherwise, so the tests run before and after the registry is wired into Skin.makeMeasure.

func runPluginTests(_ t: TestRunner) {
    CorePlugins.register()
    PluginProcess.launcher = { executable, arguments, completion in
        launchedPrograms.append((executable, arguments))
        if let completion { DispatchQueue.main.async { completion(0) } }
    }
    runPluginRegistrationTests(t)
    runPluginPathTests(t)
    runPluginActionTimerTests(t)
    runPluginSensorTests(t)
    runPluginPerfCounterTests(t)
    runPluginUsageTests(t)
    runPluginPingTests(t)
    runPluginRunCommandTests(t)
    runPluginQuoteTests(t)
    runPluginFolderInfoTests(t)
    runPluginFileViewTests(t)
    runPluginRecycleTests(t)
}

// MARK: - Helpers

private var launchedPrograms: [(String, [String])] = []

/// Spins the main run loop until `condition` holds (true) or `timeout` passes (false).
@discardableResult
private func spin(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

private func spin(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
}

/// The skin's measure when the engine made it through the registry, else a new one built from the section
/// (options not read yet when `read` is false).
private func measure<T: Measure>(_ skin: Skin, _ name: String, _ type: T.Type, read: Bool = true) -> T {
    if let m = skin.measure(named: name) as? T { return m }
    let section = skin.document.section(named: name) ?? IniSection(name: name)
    let pluginName = MeasureRegistry.normalizedPluginName(section.value(forKey: "Plugin") ?? name)
    let m = T(name: section.name, section: section, skin: skin, type: pluginName)
    if read { m.readOptionsIfNeeded() }
    return m
}

private func update(_ m: Measure) {
    m.readOptionsIfNeeded()
    m.performUpdate()
}

/// True when Skin.makeMeasure creates registered plugin measures.
private var registryWired: Bool = {
    guard let (skin, _) = try? makeSkin(TestRunner(arguments: []), "[M]\nMeasure=Plugin\nPlugin=ActionTimer\n[T]\nMeter=String\n")
    else { return false }
    return skin.measure(named: "M") is ActionTimerMeasure
}()

private final class FakeSensors: HardwareSensorSource {
    func cpuCoreTemperatures() -> [Double]? { [50, 62.5, 55] }
    func cpuTjMax() -> Double? { 100 }
    func cpuCoreFrequencies() -> [Double]? { [3200, 3500] }
    func cpuPower() -> Double? { 12.5 }
    func temperatures() -> [Double] { [40, 45] }
    func fanSpeeds() -> [Double] { [1200, 1800] }
    func voltages() -> [Double] { [1.1] }
    func gpuUtilization() -> Double? { 33 }
}

private func writeFile(_ url: URL, _ text: String) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Registration

private func runPluginRegistrationTests(_ t: TestRunner) {
    t.suite("Plugin: registration covers every name and alias") {
        t.check(MeasureRegistry.plugin(named: "ActionTimer") == ActionTimerMeasure.self)
        t.check(MeasureRegistry.plugin(named: "Plugins\\PingPlugin.dll") == PingMeasure.self)
        t.check(MeasureRegistry.plugin(named: "pingplugin.dll") == PingMeasure.self)
        t.check(MeasureRegistry.plugin(named: "QuotePlugin") == QuoteMeasure.self)
        t.check(MeasureRegistry.plugin(named: "AdvancedCPU.dll") == AdvancedCPUMeasure.self)
        t.check(MeasureRegistry.plugin(named: "PerfMon") == PerfMonMeasure.self)
        t.check(MeasureRegistry.plugin(named: "UsageMonitor") == UsageMonitorMeasure.self)
        t.check(MeasureRegistry.plugin(named: "RecycleManager.dll") == RecycleManagerMeasure.self)
        t.check(MeasureRegistry.measure(named: "RecycleManager") == RecycleManagerMeasure.self)
        t.check(MeasureRegistry.plugin(named: "SpeedFanPlugin") == SpeedFanMeasure.self)
        t.check(MeasureRegistry.plugin(named: "WindowMessagePlugin") == WindowMessageMeasure.self)
        t.check(MeasureRegistry.plugin(named: "ResMon") == ResMonMeasure.self)
        t.check(MeasureRegistry.plugin(named: "CoreTemp") == CoreTempMeasure.self)
        t.check(MeasureRegistry.plugin(named: "FileView") == FileViewMeasure.self)
        t.check(MeasureRegistry.plugin(named: "FolderInfo") == FolderInfoMeasure.self)
        t.check(MeasureRegistry.plugin(named: "RunCommand") == RunCommandMeasure.self)
        t.check(MeasureRegistry.plugin(named: "VirtualDesktops") == VirtualDesktopsMeasure.self)
        print(registryWired ? "    (engine creates plugin measures through MeasureRegistry)"
                            : "    (MeasureRegistry not wired into Skin.makeMeasure yet: measures built directly)")
    }
}

// MARK: - Paths and shared helpers

private func runPluginPathTests(_ t: TestRunner) {
    t.suite("Plugin: Windows paths map to Mac folders") {
        let home = NSHomeDirectory()
        t.equal(PluginPaths.resolve("%USERPROFILE%\\Pictures\\", relativeTo: "/skin"), home + "/Pictures/")
        t.equal(PluginPaths.resolve("%HOMEDRIVE%%HOMEPATH%\\Music", relativeTo: "/skin"), home + "/Music")
        t.equal(PluginPaths.resolve("C:\\Users\\Someone\\Videos\\clip.mp4", relativeTo: "/skin"), home + "/Movies/clip.mp4")
        t.equal(PluginPaths.resolve("C:\\Users\\X\\My Documents", relativeTo: "/s"), home + "/Documents")
        t.equal(PluginPaths.resolve("C:\\Users\\X\\AppData\\Roaming\\App", relativeTo: "/s"),
                home + "/Library/Application Support/App")
        t.equal(PluginPaths.resolve("\"C:\\Program Files\\Tool\"", relativeTo: "/s"), "/Applications/Tool")
        t.equal(PluginPaths.resolve("C:", relativeTo: "/s"), "/")
        t.equal(PluginPaths.resolve("D:\\Data\\x.txt", relativeTo: "/s"), "/Data/x.txt")
        t.equal(PluginPaths.resolve("quotes.txt", relativeTo: "/skin/dir"), "/skin/dir/quotes.txt")
        t.equal(PluginPaths.resolve("..\\up.txt", relativeTo: "/skin/dir"), "/skin/up.txt")
        t.equal(PluginPaths.resolve("~/x", relativeTo: "/s"), home + "/x")
        t.equal(PluginPaths.resolve("/abs/path/", relativeTo: "/s"), "/abs/path/")
        t.equal(PluginPaths.expandEnvironment("50%% and %NOTAVARIABLE_XYZ%"), "50%% and %NOTAVARIABLE_XYZ%")
        t.check(!PluginPaths.expandEnvironment("%TEMP%").contains("%"))
    }

    t.suite("Plugin: wildcard filters and system files") {
        let f = WildcardFilter("*.jpg; *.PNG;;")
        t.equal(f.patterns, ["*.jpg", "*.PNG"])
        t.check(f.matches("a.JPG"))
        t.check(f.matches("b.png"))
        t.check(!f.matches("c.gif"))
        t.check(WildcardFilter("").matches("anything"))
        t.check(WildcardFilter.match("*.*", "noextension"))
        t.check(WildcardFilter.match("img??.gif", "img01.gif"))
        t.check(!WildcardFilter.match("img??.gif", "img1.gif"))
        t.check(MacSystemFiles.isSystem(".DS_Store"))
        t.check(MacSystemFiles.isSystem("._resource"))
        t.check(!MacSystemFiles.isSystem(".bashrc"))
        t.equal(leadingNumber("  12.5 ms"), 12.5)
        t.equal(leadingNumber("-3x"), -3)
        t.equal(leadingNumber("abc"), 0)
    }
}

// MARK: - ActionTimer

private func runPluginActionTimerTests(_ t: TestRunner) {
    t.suite("Plugin: ActionTimer list parsing") {
        typealias S = ActionTimerMeasure.Step
        t.equal(ActionTimerMeasure.parse("A | Wait 5 | B"), [S.action("A"), .wait(5), .action("B")])
        t.equal(ActionTimerMeasure.parse("Repeat Grow, 5, 20|wait 10|Shrink"),
                [S.repeat(action: "Grow", wait: 5, count: 20), .wait(10), .action("Shrink")])
        t.equal(ActionTimerMeasure.parse("  | Waiter | Wait | RepeatAction "),
                [S.action("Waiter"), .action("Wait"), .action("RepeatAction")])
        t.equal(ActionTimerMeasure.parse("Repeat X"), [S.repeat(action: "X", wait: 0, count: 1)])
        t.equal(ActionTimerMeasure.parse("Wait -5|Repeat Y,1,99999999999"),
                [S.wait(0), .repeat(action: "Y", wait: 1, count: ActionTimerMeasure.maxRepeat)])
    }

    let ini = """
    [Variables]
    Step=1
    [MeasureTimer]
    Measure=Plugin
    Plugin=ActionTimer
    ActionList1=Move | Wait 30 | Move | Wait 30 | Move
    ActionList2=Repeat Move, 10, 5
    ActionList3=Move | Move | Move
    ActionList4=SetStep | Wait 20 | UseStep
    Move=[!SetOption MeterBox X "([MeterBox:X]+#Step#)"][!UpdateMeter MeterBox]
    SetStep=[!SetVariable Step 10]
    UseStep=[!SetVariable Seen "#Step#"]
    [MeterBox]
    Meter=Image
    W=10
    H=10
    """

    t.suite("Plugin: ActionTimer runs lists asynchronously with drift-free waits") {
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        let m = measure(skin, "MeasureTimer", ActionTimerMeasure.self)
        let box = skin.meter(named: "MeterBox")!
        let start = ProcessInfo.processInfo.systemUptime
        m.execute(command: "Execute 1")
        t.equal(box.frame.x, 0, "first step runs after the current action, not inside it")
        t.equal(m.runningLists, [1])
        t.check(spin(2) { m.runningLists.isEmpty })
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        t.equal(box.frame.x, 3)
        t.check(elapsed >= 0.058 && elapsed < 0.5, "two 30 ms waits took \(elapsed) s")
    }

    t.suite("Plugin: ActionTimer Repeat, Stop and re-execution") {
        let (skin, host) = try makeSkin(t, ini)
        skin.update()
        let m = measure(skin, "MeasureTimer", ActionTimerMeasure.self)
        let box = skin.meter(named: "MeterBox")!
        m.execute(command: "execute 2")
        t.check(spin(2) { m.runningLists.isEmpty })
        t.equal(box.frame.x, 5, "Repeat Move, 10, 5 runs Move five times")

        // A list that is running ignores Execute (with a warning), Stop ends it. The frozen clock makes each Repeat
        // wait 10, 20, 30, 40 ms of real time from when the previous step ran, so a late main thread cannot make the
        // remaining steps catch up in a burst before Stop.
        m.clock = { 0 }
        m.execute(command: "Execute 2")
        m.execute(command: "Execute 2")
        t.check(host.logs.contains { $0.contains("still running") })
        t.check(spin(2) { box.frame.x >= 6 }, "the list started")
        m.execute(command: "Stop 2")
        t.check(m.runningLists.isEmpty)
        let stoppedAt = box.frame.x
        spin(for: 0.08)
        t.equal(box.frame.x, stoppedAt, "a stopped list does nothing more")
        t.check(stoppedAt >= 6 && stoppedAt < 10, "stopped at \(stoppedAt)")
        m.clock = { ProcessInfo.processInfo.systemUptime }

        // Consecutive actions without Wait run back to back; several lists run in parallel.
        m.execute(command: "Execute 3")
        m.execute(command: "Execute 2")
        t.equal(m.runningLists, [2, 3])
        t.check(spin(2) { m.runningLists.isEmpty })
        t.equal(box.frame.x, stoppedAt + 8)

        m.execute(command: "Execute 9")
        t.check(host.logs.contains { $0.contains("ActionList9 is not defined") })
        m.execute(command: "Explode 1")
        t.check(host.logs.contains { $0.contains("not supported") })
    }

    t.suite("Plugin: ActionTimer IgnoreWarnings, variables and unload") {
        let (skin, host) = try makeSkin(t, ini.replacingOccurrences(of: "[MeterBox]", with: "IgnoreWarnings=1\n[MeterBox]"))
        skin.update()
        let m = measure(skin, "MeasureTimer", ActionTimerMeasure.self)
        m.execute(command: "Execute 2")
        m.execute(command: "Execute 2")
        t.check(!host.logs.contains { $0.contains("still running") })
        m.skinWillClose()
        t.check(m.runningLists.isEmpty)
        m.execute(command: "Execute 1")
        t.check(m.runningLists.isEmpty, "no new lists after the skin closed")

        // #Step# in an action is the value of the measure's last option read (manual: !UpdateMeasure between steps).
        let (skin2, _) = try makeSkin(t, ini)
        skin2.update()
        let m2 = measure(skin2, "MeasureTimer", ActionTimerMeasure.self)
        m2.execute(command: "Execute 4")
        t.check(spin(2) { m2.runningLists.isEmpty })
        t.equal(skin2.variable("Step"), "10")
        t.equal(skin2.variable("Seen"), "1", "without a re-read of the options the action keeps #Step# as read")
    }

    t.suite("Plugin: ActionTimer lists can restart themselves from their last action (review)") {
        // `ActionList1=Step | Wait 10 | Again` with `Again=[!CommandMeasure M "Execute 1"]` loops an animation: the
        // list has ended by the time its last action runs. The host stands in for !CommandMeasure here, so the test
        // does not depend on the registry being wired.
        final class LoopHost: FakeHost {
            var onExecute: ((String) -> Void)?
            override func skin(_ skin: Skin, execute target: String, arguments: [String]) {
                super.skin(skin, execute: target, arguments: arguments)
                onExecute?(target)
            }
        }
        let host = LoopHost()
        let (skin, _) = try makeSkin(t, """
        [Timer]
        Measure=Plugin
        Plugin=ActionTimer
        ActionList1=Tick | Wait 10 | Again | Wait 0
        ActionList2=Repeat Again2, 5, 2
        Tick=[!SetOption Box X "([Box:X]+1)"][!UpdateMeter Box]
        Again=["loop1"]
        Again2=["loop2"]
        [Box]
        Meter=Image
        W=1
        H=1
        """, host: host)
        skin.update()
        let m = measure(skin, "Timer", ActionTimerMeasure.self)
        var loops: [String: Int] = [:]
        host.onExecute = { target in
            let n = loops[target, default: 0] + 1
            loops[target] = n
            if target == "loop1" && n < 3 { m.execute(command: "Execute 1") }
            if target == "loop2" && n % 2 == 0 && n < 6 { m.execute(command: "Execute 2") }   // after the last repetition
        }
        m.execute(command: "Execute 1")
        m.execute(command: "Execute 2")
        t.check(spin(3) { loops["loop1"] == 3 && loops["loop2"] == 6 && m.runningLists.isEmpty })
        t.equal(loops["loop1"], 3)
        t.equal(loops["loop2"], 6, "a final Repeat restarts after its last repetition")
        t.equal(skin.meter(named: "Box")?.frame.x, 3)
        t.check(!host.logs.contains { $0.contains("still running") })
    }

    t.suite("Plugin: ActionTimer keeps its schedule when steps are late") {
        let (skin, _) = try makeSkin(t, ini)
        skin.update()
        let m = measure(skin, "MeasureTimer", ActionTimerMeasure.self)
        var fake = 100.0
        m.clock = { fake }
        m.execute(command: "Execute 1")
        spin { skin.meter(named: "MeterBox")!.frame.x == 1 }
        // The main thread was busy for 1 s: the next step restarts from "now" instead of bursting. It runs after the
        // 30 ms wait; a busy CI runner may take longer to get there.
        fake = 101
        t.check(spin(2) { skin.meter(named: "MeterBox")!.frame.x >= 2 }, "the next step runs")
        m.skinWillClose()
    }
}

// MARK: - Sensors, stubs

private func runPluginSensorTests(_ t: TestRunner) {
    t.suite("Plugin: CoreTemp maps loads, name and sensors") {
        let (skin, host) = try makeSkin(t, """
        [Load]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Load
        CoreTempIndex=2
        [Name]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=CpuName
        [Max]
        Measure=Plugin
        Plugin=CoreTemp
        [Core1]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Temperature
        CoreTempIndex=1
        [Speed]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=CoreSpeed
        CoreTempIndex=1
        [Bad]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Nonsense
        """)
        let load = measure(skin, "Load", CoreTempMeasure.self)
        update(load)
        t.equal(load.value, 3, "CoreTempIndex=2 is the third core (FakeSystem returns the core number)")
        let name = measure(skin, "Name", CoreTempMeasure.self)
        update(name)
        t.check(!name.stringValue.isEmpty && name.stringValue != "0")
        let max = measure(skin, "Max", CoreTempMeasure.self)
        update(max)
        t.equal(max.value, 0)
        t.check(host.logs.contains { $0.contains("needs hardware sensors") })
        _ = measure(skin, "Bad", CoreTempMeasure.self)
        t.check(host.logs.contains { $0.contains("unknown CoreTempType=Nonsense") })

        HardwareSensors.source = FakeSensors()
        defer { HardwareSensors.source = nil }
        update(max)
        t.equal(max.value, 62.5)
        let core1 = measure(skin, "Core1", CoreTempMeasure.self)
        update(core1)
        t.equal(core1.value, 62.5)
        let speed = measure(skin, "Speed", CoreTempMeasure.self)
        update(speed)
        t.equal(speed.value, 3500)
    }

    t.suite("Plugin: SpeedFan, ResMon, WindowMessage, VirtualDesktops") {
        let (skin, host) = try makeSkin(t, """
        [Temp]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanNumber=1
        SpeedFanScale=F
        [Fan]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanType=Fan
        SpeedFanNumber=1
        [Handles]
        Measure=Plugin
        Plugin=ResMon
        ResCountType=Handle
        [OwnHandles]
        Measure=Plugin
        Plugin=ResMon
        ResCountType=Handle
        ProcessName=\(ProcessInfo.processInfo.processName).exe
        [GDI]
        Measure=Plugin
        Plugin=ResMon
        [Winamp]
        Measure=Plugin
        Plugin=WindowMessagePlugin
        WindowClass=Winamp v1.x
        [Desk]
        Measure=Plugin
        Plugin=VirtualDesktops
        VDMeasureType=CurrentDesktop
        [DeskName]
        Measure=Plugin
        Plugin=VirtualDesktops
        VDMeasureType=DesktopName
        """)
        let temp = measure(skin, "Temp", SpeedFanMeasure.self)
        update(temp)
        t.equal(temp.value, 0)
        HardwareSensors.source = FakeSensors()
        update(temp)
        t.equal(temp.value, 45 * 9 / 5 + 32)
        let fan = measure(skin, "Fan", SpeedFanMeasure.self)
        update(fan)
        t.equal(fan.value, 1800)
        HardwareSensors.source = nil

        let handles = measure(skin, "Handles", ResMonMeasure.self)
        update(handles)
        t.check(handles.value > 10)
        let own = measure(skin, "OwnHandles", ResMonMeasure.self)
        update(own)
        t.check(own.value >= 3, "this process has stdin/out/err open")
        let gdi = measure(skin, "GDI", ResMonMeasure.self)
        update(gdi)
        t.equal(gdi.value, 0)

        let winamp = measure(skin, "Winamp", WindowMessageMeasure.self)
        update(winamp)
        t.equal(winamp.value, 0)
        t.equal(winamp.stringValue, "")
        winamp.execute(command: "SendMessage 1024 0 104")
        t.check(host.logs.contains { $0.contains("Winamp v1.x") })

        let desk = measure(skin, "Desk", VirtualDesktopsMeasure.self)
        update(desk)
        t.equal(desk.value, 1)
        let deskName = measure(skin, "DeskName", VirtualDesktopsMeasure.self)
        update(deskName)
        t.equal(deskName.stringValue, "Desktop 1")
    }

    t.suite("Plugin: ResMon finds processes off the main thread (review)") {
        // Finding a process by name reads every process's name (~10 ms): not at each update on the main thread.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { child.terminate() }
        let (skin, _) = try makeSkin(t, """
        [Sleep]
        Measure=Plugin
        Plugin=ResMon
        ResCountType=Handle
        ProcessName=sleep.exe
        """)
        let resmon = measure(skin, "Sleep", ResMonMeasure.self)
        update(resmon)
        t.equal(resmon.value, 0, "the first update does not wait for the lookup")
        t.check(spin(5) { update(resmon); return resmon.value >= 3 }, "then the process's descriptors are counted")
    }
}

// MARK: - Performance counters

private func snapshot(_ serial: Int, time: TimeInterval, processes: [ProcessRecord], idle: Double, busy: Double,
                      hidden: Double = 0) -> ProcessSnapshot {
    let core = CoreTicks(user: busy / 2, system: busy / 2, idle: idle / 2, nice: 0)
    return ProcessSnapshot(serial: serial, time: time, processes: processes, processCount: processes.count + 5,
                           cores: [core, core], hiddenCPU: hidden)
}

private func runPluginPerfCounterTests(_ t: TestRunner) {
    t.suite("Plugin: performance counter catalog") {
        t.equal(PerfCounters.spec(category: "Processor", counter: "% Processor Time")?.kind, .inverseTimer)
        t.equal(PerfCounters.spec(category: "process", counter: "working set - private")?.field, .processFootprint)
        t.equal(PerfCounters.spec(category: "Memory", counter: "Available MBytes")?.field,
                .memoryAvailable(divisor: 1_048_576))
        t.equal(PerfCounters.spec(category: "LogicalDisk", counter: "Disk Bytes/sec")?.kind, .rate)
        t.equal(PerfCounters.spec(category: "Network Adapter", counter: "Bytes Received/sec")?.field, .netIn)
        t.check(PerfCounters.spec(category: "Process", counter: "Nonexistent Counter") == nil)
        t.check(PerfCounters.spec(category: "Hyper-V", counter: "x") == nil)
        t.check(PerfCounters.spec(category: "Process", counter: "% Processor Time")!.needsProcesses)
        t.check(!PerfCounters.spec(category: "Memory", counter: "Committed Bytes")!.needsProcesses)
    }

    t.suite("Plugin: raw vs formatted counter values") {
        let rate = PerfCounterSpec(category: .networkInterface, counter: "bytes received/sec", kind: .rate, field: .netIn)
        let old = PerfCounters.RawReading(time: 10, instances: [("en0", 1000, 0)])
        let new = PerfCounters.RawReading(time: 12, instances: [("en0", 5000, 0), ("en1", 7, 0)])
        t.equal(PerfCounters.values(rate, old: old, new: new, mode: .formatted),
                [PerfValue(name: "en0", value: 2000), PerfValue(name: "en1", value: 0)])
        t.equal(PerfCounters.values(rate, old: old, new: new, mode: .rawDelta).first?.value, 4000)
        t.equal(PerfCounters.values(rate, old: old, new: new, mode: .raw).first?.value, 5000)
        t.equal(PerfCounters.values(rate, old: nil, new: new, mode: .formatted).first?.value, 0)

        // Processor % Processor Time: idle 100 ns ticks, 1 s apart, 25 % idle → 75 % busy.
        let cpu = PerfCounters.spec(category: "Processor", counter: "% Processor Time")!
        let a = PerfCounters.RawReading(time: 1, instances: [("0", 0, 0)])
        let b = PerfCounters.RawReading(time: 2, instances: [("0", 2_500_000, 0)])
        t.close(PerfCounters.values(cpu, old: a, new: b, mode: .formatted)[0].value, 75)
        t.close(PerfCounters.values(cpu, old: a, new: b, mode: .rawDelta)[0].value, 2_500_000, "raw delta = idle ticks")
        // A second with no idle time at all (every core busy): PerfMon's raw delta is 0.
        let c = PerfCounters.RawReading(time: 3, instances: [("0", 2_500_000, 0)])
        t.equal(PerfCounters.values(cpu, old: b, new: c, mode: .rawDelta)[0].value, 0)
        t.close(PerfCounters.values(cpu, old: b, new: c, mode: .formatted)[0].value, 100, "no idle time: 100 % busy")
        let idle = PerfCounters.spec(category: "Processor", counter: "% Idle Time")!
        t.close(PerfCounters.values(idle, old: a, new: b, mode: .formatted)[0].value, 25)
        let fraction = PerfCounters.spec(category: "Paging File", counter: "% Usage")!
        let f = PerfCounters.RawReading(time: 1, instances: [("_Total", 1, 4)])
        t.equal(PerfCounters.values(fraction, old: nil, new: f, mode: .formatted)[0].value, 25)
    }

    t.suite("Plugin: per-process values, Idle / System, rollup and #N names") {
        let cpu = PerfCounters.spec(category: "Process", counter: "% Processor Time")!
        let old = snapshot(1, time: 0, processes: [
            ProcessRecord(pid: 10, name: "Safari", start: 1, userTime: 0),
            ProcessRecord(pid: 11, name: "Helper", start: 1, userTime: 1_000_000),
            ProcessRecord(pid: 12, name: "Helper", start: 1, userTime: 0),
            ProcessRecord(pid: 13, name: "Gone", start: 1, userTime: 0),
        ], idle: 0, busy: 0, hidden: 0)
        let new = snapshot(2, time: 1, processes: [
            ProcessRecord(pid: 10, name: "Safari", start: 1, userTime: 5_000_000),
            ProcessRecord(pid: 11, name: "Helper", start: 1, userTime: 3_000_000),
            ProcessRecord(pid: 12, name: "Helper", start: 1, userTime: 1_000_000),
            ProcessRecord(pid: 14, name: "New", start: 9, userTime: 500_000),
        ], idle: 10_000_000, busy: 10_000_000, hidden: 1_500_000)
        let rolled = PerfCounters.processValues(cpu, old: old, new: new, mode: .formatted, rollup: true)
        func v(_ list: [PerfValue], _ name: String) -> Double? { list.first { $0.name == name }?.value }
        t.close(v(rolled, "Safari") ?? -1, 50)
        t.close(v(rolled, "Helper") ?? -1, 30)
        t.close(v(rolled, "New") ?? -1, 5, "a process started in the interval counts all of its time")
        t.close(v(rolled, "Idle") ?? -1, 100)
        t.close(v(rolled, "System") ?? -1, 15)
        t.close(v(rolled, "_Total") ?? -1, 200, "all instances add up to 100 % × cores")
        t.check(v(rolled, "Gone") == nil)
        let separate = PerfCounters.processValues(cpu, old: old, new: new, mode: .formatted, rollup: false)
        t.close(v(separate, "Helper") ?? -1, 20)
        t.close(v(separate, "Helper#1") ?? -1, 10)
        let raw = PerfCounters.processValues(cpu, old: old, new: new, mode: .rawDelta, rollup: false)
        t.close(v(raw, "Safari") ?? -1, 5_000_000)

        let memory = PerfCounters.spec(category: "Process", counter: "Working Set - Private")!
        var withMemory = new
        withMemory.processes[0].footprintBytes = 1234
        t.equal(v(PerfCounters.processValues(memory, old: old, new: withMemory, mode: .formatted, rollup: true), "Safari"),
                1234)

        // Pid reuse: a different start time is a new process.
        var reused = new
        reused.processes[0].start = 99
        t.close(v(PerfCounters.processValues(cpu, old: old, new: reused, mode: .formatted, rollup: true), "Safari") ?? -1,
                50)

        let own = ProcessInfo.processInfo.processName
        let list = [PerfValue(name: own, value: 7), PerfValue(name: "0,3", value: 9), PerfValue(name: "Firefox", value: 1)]
        t.equal(PerfCounters.find("Rainmeter", in: list, category: .process)?.value, 7)
        t.equal(PerfCounters.find("firefox.exe", in: list, category: .process)?.value, 1)
        t.equal(PerfCounters.find("3", in: list, category: .processorInformation)?.value, 9)
        t.check(PerfCounters.find("3", in: list, category: .processor) == nil)
    }

    t.suite("Plugin: AdvancedCPU include / exclude / top process") {
        let old = snapshot(1, time: 0, processes: [
            ProcessRecord(pid: 10, name: "chrome", start: 1),
            ProcessRecord(pid: 11, name: "chrome", start: 1),
            ProcessRecord(pid: 12, name: "Finder", start: 1),
        ], idle: 0, busy: 0)
        let new = snapshot(2, time: 1, processes: [
            ProcessRecord(pid: 10, name: "chrome", start: 1, userTime: 3_000_000),
            ProcessRecord(pid: 11, name: "chrome", start: 1, userTime: 1_000_000),
            ProcessRecord(pid: 12, name: "Finder", start: 1, userTime: 2_000_000),
        ], idle: 14_000_000, busy: 6_000_000)
        let interval = ProcessCPUInterval(from: old, to: new)
        let all = AdvancedCPUMeasure.evaluate(interval, include: nil, exclude: [], topProcess: 0)
        t.close(all.0, 20_000_000, "no include/exclude: the whole machine (2 cores × 1 s)")
        let noIdle = AdvancedCPUMeasure.evaluate(interval, include: nil, exclude: ["idle"], topProcess: 1)
        t.close(noIdle.0, 3_000_000)
        t.equal(noIdle.1, "chrome")
        let name = AdvancedCPUMeasure.evaluate(interval, include: nil, exclude: AdvancedCPUMeasure.nameSet("Idle;chrome.exe"),
                                               topProcess: 2)
        t.equal(name.1, "Finder")
        t.close(name.0, 2_000_000)
        let busyOnly = AdvancedCPUMeasure.evaluate(interval, include: nil, exclude: AdvancedCPUMeasure.nameSet("Idle"),
                                                   topProcess: 2)
        t.close(busyOnly.0, 6_000_000, "CPUExclude=Idle: the whole machine (20 M) minus its idle time (14 M)")
        t.equal(busyOnly.1, "chrome")
        // An interval without idle time (every core busy): excluding Idle leaves the whole machine.
        let saturated = ProcessCPUInterval(from: old, to: snapshot(3, time: 1, processes: new.processes, idle: 0,
                                                                   busy: 6_000_000))
        t.close(AdvancedCPUMeasure.evaluate(saturated, include: nil, exclude: ["idle"], topProcess: 2).0,
                AdvancedCPUMeasure.evaluate(saturated, include: nil, exclude: [], topProcess: 0).0,
                "no idle time: excluding Idle changes nothing")
        let only = AdvancedCPUMeasure.evaluate(interval, include: AdvancedCPUMeasure.nameSet("CHROME"), exclude: [],
                                               topProcess: 0)
        t.close(only.0, 4_000_000)
        t.equal(AdvancedCPUMeasure.nameSet(" a.exe ; ;B "), ["a", "b"])
    }
}

// MARK: - UsageMonitor / PerfMon / AdvancedCPU measures

private func runPluginUsageTests(_ t: TestRunner) {
    t.suite("Plugin: UsageMonitor Index, Name, lists and Percent") {
        let (skin, _) = try makeSkin(t, """
        [Total]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=CPU
        [Top]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=CPU
        Index=2
        Blacklist=_Total|Idle|System
        [Avg]
        Measure=Plugin
        Plugin=UsageMonitor
        Category=Process
        Counter=Working Set
        Index=-1
        [Named]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=RAM
        Name=safari
        [White]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=RAM
        Index=1
        Whitelist=Mail|Finder
        """)
        let values = [PerfValue(name: "Safari", value: 40), PerfValue(name: "Mail", value: 20),
                      PerfValue(name: "Finder", value: 0), PerfValue(name: "Idle", value: 120),
                      PerfValue(name: "System", value: 20), PerfValue(name: "_Total", value: 200)]
        let cpu = PerfCounters.spec(category: "Process", counter: "% Processor Time")!
        let total = measure(skin, "Total", UsageMonitorMeasure.self)
        let r0 = total.select(values, spec: cpu)
        t.close(r0.0, 40, "Percent (automatic for Alias=CPU): (40+20+0+20)/200 without _Total and Idle")
        t.equal(r0.1, "Total")
        let top = measure(skin, "Top", UsageMonitorMeasure.self)
        let r2 = top.select(values, spec: cpu)
        t.close(r2.0, 10)
        t.equal(r2.1, "Mail")
        let avg = measure(skin, "Avg", UsageMonitorMeasure.self)
        let ra = avg.select(values, spec: cpu)
        t.close(ra.0, 80 / 4.0, "Safari, Mail, Finder, System")
        t.equal(ra.1, "Average")
        let named = measure(skin, "Named", UsageMonitorMeasure.self)
        t.equal(named.select(values, spec: cpu).0, 40)
        let white = measure(skin, "White", UsageMonitorMeasure.self)
        t.equal(white.select(values, spec: cpu).1, "Mail")
        // An index whose value is 0 has an empty name.
        let emptyTop = white.select([PerfValue(name: "Mail", value: 0)], spec: cpu)
        t.equal(emptyTop.1, "")
    }

    t.suite("Plugin: UsageMonitor, PerfMon, AdvancedCPU read this Mac") {
        let (skin, host) = try makeSkin(t, """
        [TopCPU]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=CPU
        Index=1
        [Core0]
        Measure=Plugin
        Plugin=UsageMonitor
        Category=Processor
        Counter=% Processor Time
        Name=0
        [Available]
        Measure=Plugin
        Plugin=UsageMonitor
        Category=Memory
        Counter=Available MBytes
        [Missing]
        Measure=Plugin
        Plugin=UsageMonitor
        Category=Hyper-V Hypervisor
        Counter=Whatever
        [PerfCore]
        Measure=Plugin
        Plugin=PerfMon
        PerfMonObject="Processor"
        PerfMonInstance=_Total
        PerfMonCounter="% Processor Time"
        [PerfProcesses]
        Measure=Plugin
        Plugin=Plugins\\PerfMon.dll
        PerfMonObject=System
        PerfMonCounter=Processes
        PerfMonDifference=0
        [CPUMax]
        Measure=Plugin
        Plugin=AdvancedCPU
        [CPUTopName]
        Measure=Plugin
        Plugin=AdvancedCPU
        CPUExclude=Idle
        TopProcess=2
        """)
        let top = measure(skin, "TopCPU", UsageMonitorMeasure.self)
        let core0 = measure(skin, "Core0", UsageMonitorMeasure.self)
        let available = measure(skin, "Available", UsageMonitorMeasure.self)
        let missing = measure(skin, "Missing", UsageMonitorMeasure.self)
        let perfCore = measure(skin, "PerfCore", PerfMonMeasure.self)
        let processes = measure(skin, "PerfProcesses", PerfMonMeasure.self)
        let cpuMax = measure(skin, "CPUMax", AdvancedCPUMeasure.self)
        let topName = measure(skin, "CPUTopName", AdvancedCPUMeasure.self)
        t.check(ProcessSampler.shared.isRunning)
        // The two AdvancedCPU measures start from the same sample and share one clock, so their numbers cover the
        // same interval and differ by exactly its idle time.
        t.check(spin(10) { ProcessSampler.shared.samples().latest != nil }, "first sample")
        var now = ProcessInfo.processInfo.systemUptime
        cpuMax.clock = { now }
        topName.clock = { now }
        let firstUpdate = now
        for m in [top, core0, available, missing, perfCore, processes, cpuMax, topName] as [Measure] { update(m) }
        // Keep the CPU a little busy so that there is a top process, for 2.3 s and until the sampler has delivered
        // two new samples (its utility-QoS timer runs late on a busy machine).
        let firstSerial = ProcessSampler.shared.samples().latest?.serial ?? 0
        let started = Date()
        var sampled = false
        var x = 0.0
        while Date().timeIntervalSince(started) < 30 {
            sampled = (ProcessSampler.shared.samples().latest?.serial ?? 0) >= firstSerial + 2
            if sampled && Date().timeIntervalSince(started) >= 2.3 { break }
            x += sin(x)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        t.check(sampled, "the sampler delivered two new samples")
        now = ProcessInfo.processInfo.systemUptime
        let span = now - firstUpdate
        for m in [top, core0, available, missing, perfCore, processes, cpuMax, topName] as [Measure] { update(m) }
        t.check(top.value > 0 && !top.stringValue.isEmpty, "top process \(top.stringValue) \(top.value)")
        t.check(top.value <= 100.0001)
        t.check(core0.value >= 0 && core0.value <= 100)
        t.close(available.value, 8 * 1024, accuracy: 0.001, "FakeSystem: 16 GB total, 8 GB used")
        t.equal(missing.value, 0)
        t.check(host.logs.contains { $0.contains("not available on macOS") })
        t.check(skin.issues.contains { $0.contains("Hyper-V") })
        let cores = Double(ProcessorTicks.read().count)
        // Idle ticks can never exceed cores × seconds × 10^7; a CI VM whose cores were all busy has none.
        t.check(perfCore.value >= 0 && perfCore.value < 1.7 * cores * 1e7 * span,
                "idle 100 ns ticks since the last update (0 when the CPU had no idle time): \(perfCore.value)")
        t.check(processes.value > 20)
        t.check(cpuMax.value / span > 0.3 * cores * 1e7 && cpuMax.value / span < 1.7 * cores * 1e7,
                "whole machine ≈ cores × seconds × 10^7: \(cpuMax.value) in \(span) s")
        t.check(!topName.stringValue.isEmpty)
        // 2 %: a sample may arrive between the two measures' adjacent updates.
        t.check(topName.value > 0 && topName.value <= cpuMax.value * 1.02,
                "TopProcess=2 without Idle is at most the whole machine (equal when there was no idle time): "
                    + "\(topName.value) vs \(cpuMax.value)")
        _ = x
        for m in [top, core0, available, missing, perfCore, processes, cpuMax, topName] as [Measure] {
            (m as? PluginLifecycle)?.skinWillClose()
        }
        t.check(!ProcessSampler.shared.isRunning, "sampling stops when no measure needs it")
    }
}

// MARK: - Ping

private func runPluginPingTests(_ t: TestRunner) {
    t.suite("Plugin: ICMP helpers") {
        // RFC 1071 example words 0001 f203 f4f5 f6f7 → checksum 220d.
        t.equal(ICMPEcho.checksum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]), 0x220D)
        var reply: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19) + [0, 0, 0, 0, 0x12, 0x34, 0x00, 0x07]
        t.check(ICMPEcho.isReply(reply, v6: false, identifier: 0x1234, sequence: 7))
        t.check(!ICMPEcho.isReply(reply, v6: false, identifier: 0x1235, sequence: 7))
        reply[20] = 8
        t.check(!ICMPEcho.isReply(reply, v6: false, identifier: 0x1234, sequence: 7), "a request is not a reply")
        t.check(ICMPEcho.isReply([129, 0, 0, 0, 0, 5, 0, 9], v6: true, identifier: 5, sequence: 9))
    }

    t.suite("Plugin: Ping localhost, time-outs and UpdateRate") {
        let (skin, _) = try makeSkin(t, """
        [Local]
        Measure=Plugin
        Plugin=PingPlugin
        DestAddress=127.0.0.1
        UpdateRate=3
        FinishAction=[!SetVariable LocalDone "[Local]"]
        [Local6]
        Measure=Plugin
        Plugin=PingPlugin
        DestAddress=::1
        [Silent]
        Measure=Plugin
        Plugin=PingPlugin
        DestAddress=127.0.0.2
        Timeout=250
        TimeoutValue=999
        FinishAction=[!SetVariable SilentDone 1]
        """)
        let local = measure(skin, "Local", PingMeasure.self)
        update(local)
        t.check(spin(5) { !local.isPinging })
        // Localhost answers in well under a millisecond, but the measured time includes waking the ping's
        // low-priority thread, which takes many milliseconds on a busy machine: no latency bound here.
        t.equal(Double(skin.variable("LocalDone") ?? ""), local.value, "FinishAction ran with the measure's value")
        t.check(local.value >= 0 && local.value < 5000, "a reply, not TimeoutValue (default 30000): \(local.value)")
        t.equal(local.pingCount, 1)
        update(local); update(local)
        t.equal(local.pingCount, 1, "UpdateRate=3: no new ping on the next two updates")
        update(local)
        t.equal(local.pingCount, 2)
        spin(5) { !local.isPinging }

        let local6 = measure(skin, "Local6", PingMeasure.self)
        update(local6)
        t.check(spin(5) { !local6.isPinging })
        t.check(local6.value >= 0 && local6.value < 5000, "a reply, not TimeoutValue: \(local6.value)")

        let silent = measure(skin, "Silent", PingMeasure.self)
        let start = Date()
        update(silent)
        t.check(spin(20) { !silent.isPinging })
        let elapsed = Date().timeIntervalSince(start)
        t.equal(silent.value, 999)
        t.equal(skin.variable("SilentDone"), "1")
        // Far below the default Timeout of 30 s even when the ping's thread runs late: Timeout=250 was used.
        t.check(elapsed > 0.2 && elapsed < 10, "Timeout=250 ms took \(elapsed) s")

        update(silent)
        silent.skinWillClose()
        t.check(!silent.isPinging, "unloading cancels the ping")
    }
}

// MARK: - RunCommand

private func runPluginRunCommandTests(_ t: TestRunner) {
    t.suite("Plugin: RunCommand translation of Windows command lines") {
        func sh(_ program: String, _ parameter: String) -> String? {
            try? RunCommandTranslator.shellCommand(program: program, parameter: parameter).get()
        }
        t.equal(sh("", "echo hello"), "echo hello")
        t.equal(sh("%ComSpec% /U /C", "echo hi"), "echo hi")
        t.equal(sh("cmd.exe /C", "whoami"), "whoami")
        t.equal(sh("", "/C curl -s https://example.com"), "curl -s https://example.com")
        t.equal(sh("", "echo a & echo b"), "echo a ; echo b")
        t.equal(sh("", "echo a && echo b | sort2"), "echo a && echo b | sort2")
        t.equal(sh("", "start \"\" \"https://example.com/a b\""), "/usr/bin/open 'https://example.com/a b'")
        t.equal(sh("", "start https://example.com"), "/usr/bin/open 'https://example.com'")
        t.equal(sh("", "explorer ~/Pictures"), "/usr/bin/open '~/Pictures'")
        t.equal(sh("", "ping -n 1 -w 500 example.com"), "/sbin/ping -W 500 -c 1 'example.com'")
        t.equal(sh("", "ping example.com"), "/sbin/ping -c 4 'example.com'")
        t.equal(sh("/bin/zsh", "-c 'echo $0'"), "/bin/zsh -c 'echo $0'")
        t.equal(sh("python3", "script.py"), "python3 script.py")
        let toolFolder = t.temporaryDirectory("runcommand-tool").appendingPathComponent("My Tool")
        writeFile(toolFolder.appendingPathComponent("tool"), "#!/bin/sh\n")
        let tool = toolFolder.appendingPathComponent("tool").path
        t.equal(sh(tool, "--x"), "'\(tool)' --x", "an existing path with spaces is one word")
        t.equal(sh(tool + " -v", "--x"), "'\(tool)' -v --x", "…followed by Program's own arguments")
        t.equal(sh("\"\(tool)\" -v", ""), "'\(tool)' -v")
        t.check(sh("PowerShell", "(Get-CimInstance Win32_Processor).Name") == nil)
        t.check(sh("\"C:\\Program Files\\App\\app.exe\"", "") == nil)
        t.check(sh("", "dir /b") == nil)
        t.check(sh("", "rmdir /s /q \"x\"") == nil)
        t.check(sh("", "echo %DATE%") == nil)
        t.check(sh("", "type C:\\file.txt") == nil)
        t.check(sh("", "wmic os get lastbootuptime") == nil)
        t.check(sh("", "tool.bat") == nil)
        t.check(sh("", "ping -t example.com") == nil, "ping until stopped would never end")
        t.check(sh("", "echo hi & del x") == nil)
        t.equal(sh("", ""), "")
        t.equal(sh("", "curl -s https://example.com 2>nul"), "curl -s https://example.com 2>/dev/null")
        t.equal(sh("", "whoami > NUL & echo x >>nul"), "whoami >/dev/null ; echo x >>/dev/null")
        t.equal(sh("", "echo null"), "echo null")
    }

    t.suite("Plugin: RunCommand keeps POSIX command lines intact (review)") {
        func sh(_ program: String, _ parameter: String) -> String? {
            try? RunCommandTranslator.shellCommand(program: program, parameter: parameter).get()
        }
        // `&` of a redirection and separators inside single quotes are not cmd.exe separators.
        t.equal(sh("", "uptime 2>&1"), "uptime 2>&1")
        t.equal(sh("", "echo x >&2 & echo y &>/dev/null"), "echo x >&2 ; echo y &>/dev/null")
        t.equal(sh("", "grep -E 'a|b' f.txt"), "grep -E 'a|b' f.txt")
        t.equal(sh("", "curl -s 'https://example.com/?a=1&b=2' | head -1"), "curl -s 'https://example.com/?a=1&b=2' | head -1")
        t.equal(sh("", "awk -F'|' '{print $1}' f && echo \"x & y\""), "awk -F'|' '{print $1}' f && echo \"x & y\"")
        t.equal(sh("", "echo a\\&b"), "echo a\\&b")
        let pipeline = "printf 'b|2\\na|1\\n' 2>&1 | sort | tr '\\n' ' '"   // TestSkins/Plugins/RunCommand
        t.equal(sh("", pipeline), pipeline)
        // Names cmd.exe shares with POSIX commands run unless the line shows Windows syntax.
        t.equal(sh("", "ps -Ao pcpu,comm | sort -nr | head -5"), "ps -Ao pcpu,comm | sort -nr | head -5")
        t.equal(sh("", "date +%Y%m%d"), "date +%Y%m%d", "strftime formats are not %VARIABLES%")
        t.equal(sh("", "date \"+%Hh%Mm\""), "date \"+%Hh%Mm\"")
        t.equal(sh("", "find . -name '*.txt' | wc -l"), "find . -name '*.txt' | wc -l")
        t.equal(sh("", "for f in *.txt; do echo $f; done"), "for f in *.txt; do echo $f; done")
        t.equal(sh("", "if [ -d /tmp ]; then echo yes; fi"), "if [ -d /tmp ]; then echo yes; fi")
        t.equal(sh("", "ipconfig getifaddr en0"), "ipconfig getifaddr en0")
        t.equal(sh("", "rmdir empty"), "rmdir empty")
        t.equal(sh("", "type notes\\today.txt"), "cat notes/today.txt", "Windows `type file` prints the file")
        t.equal(sh("/usr/bin/find", "/tmp -name x"), "/usr/bin/find /tmp -name x", "a Mac path is never a Windows tool")
        t.equal(sh("sort", "-n data.txt"), "sort -n data.txt")
        t.equal(sh("python3 -u", "script.py"), "python3 -u script.py", "Program's own arguments are not quoted")
        t.equal(sh("", "ping -c 2 localhost"), "/sbin/ping -c 2 localhost", "a Mac ping line runs unchanged")
        t.equal(sh("ping", "-n 2 localhost"), "/sbin/ping -c 2 'localhost'")
        t.equal(sh("explorer", "https://example.com"), "/usr/bin/open 'https://example.com'")
        t.equal(sh("C:\\Windows\\System32\\cmd.exe /C", "echo x"), "echo x")
        // …and still fail with Windows syntax.
        for line in ["sort /r data.txt", "date /t", "time /T", "find /i \"x\" f.txt", "if exist x.txt echo y",
                     "for /f %%a in ('ver') do echo %%a", "for %i in (a b) do echo %i", "ipconfig", "ipconfig /all",
                     "echo %DATE%", "echo %date:~0,4%", "echo %UserProfile%", "rmdir /s /q x"] {
            t.check(sh("", line) == nil, line)
        }
        t.check(sh("powershell.exe -NoProfile", "Get-Date") == nil, "Program with arguments is still recognised")
        t.check(sh("date", "/t") == nil)
        t.check(RunCommandTranslator.isWindowsSwitch("/all"))
        t.check(RunCommandTranslator.isWindowsSwitch("/a:h") && RunCommandTranslator.isWindowsSwitch("/+3"))
        t.check(!RunCommandTranslator.isWindowsSwitch("/tmp") && !RunCommandTranslator.isWindowsSwitch("/Users/x"))
    }

    let ini = """
    [Variables]
    EchoDone=
    WindowsDone=
    [Echo]
    Measure=Plugin
    Plugin=RunCommand
    Parameter=printf 'hello %s\\n' "wörld"
    OutputFile=out/echo.txt
    FinishAction=[!SetVariable EchoDone "#EchoDone#x"]
    [Utf8]
    Measure=Plugin
    Plugin=RunCommand
    Parameter=printf 'ab'
    OutputType=UTF8
    OutputFile=utf8.txt
    [Where]
    Measure=Plugin
    Plugin=RunCommand
    Parameter=pwd -P
    StartInFolder=#@#
    [Sleepy]
    Measure=Plugin
    Plugin=RunCommand
    Parameter=echo started; sleep 20; echo never
    Timeout=3000
    FinishAction=[!SetVariable SleepyDone 1]
    [Long]
    Measure=Plugin
    Plugin=RunCommand
    Parameter=sleep 30
    [Windows]
    Measure=Plugin
    Plugin=RunCommand
    Program=PowerShell
    Parameter=Get-Date
    FinishAction=[!SetVariable WindowsDone "#WindowsDone#x"]
    """

    t.suite("Plugin: RunCommand captures output, writes OutputFile, runs FinishAction") {
        let (skin, _) = try makeSkin(t, ini)
        let echo = measure(skin, "Echo", RunCommandMeasure.self)
        update(echo)
        t.equal(echo.value, -1, "before the first run")
        echo.execute(command: "Run")
        t.equal(echo.value, 0, "while running")
        t.check(spin(5) { !echo.isRunning })
        t.equal(echo.stringValue, "hello wörld\n")
        t.equal(echo.value, 1)
        t.equal(skin.variable("EchoDone"), "x", "FinishAction ran once")
        let file = skin.directory.appendingPathComponent("out/echo.txt")
        let data = (try? Data(contentsOf: file)) ?? Data()
        t.equal(Array(data.prefix(2)), [0xFF, 0xFE], "OutputType=UTF16 (default): UTF-16 LE with BOM")
        t.equal(String(data: data.dropFirst(2), encoding: .utf16LittleEndian), "hello wörld\n")
        update(echo)
        t.equal(echo.stringValue, "hello wörld\n", "the value stays after an update")

        let utf8 = measure(skin, "Utf8", RunCommandMeasure.self)
        utf8.execute(command: "run")
        t.check(spin(5) { !utf8.isRunning })
        t.equal((try? Data(contentsOf: skin.directory.appendingPathComponent("utf8.txt"))).map { Array($0) } ?? [],
                [0x61, 0x62])

        let whereMeasure = measure(skin, "Where", RunCommandMeasure.self)
        whereMeasure.execute(command: "Run")
        t.check(spin(5) { !whereMeasure.isRunning })
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let expected = realpath(skin.resourcesDirectory.path, &resolved).map { String(cString: $0) } ?? ""
        t.equal(whereMeasure.stringValue.trimmingCharacters(in: .newlines), expected)
    }

    t.suite("Plugin: RunCommand timeout, kill, error codes") {
        let (skin, host) = try makeSkin(t, ini)
        let sleepy = measure(skin, "Sleepy", RunCommandMeasure.self)
        let start = Date()
        sleepy.execute(command: "Run")
        sleepy.execute(command: "Run")
        t.equal(sleepy.value, 101, "Run while running")
        // Timeout=3000 leaves a busy machine time to start the shell and read its first line; still far below the
        // program's 20 s.
        t.check(spin(15) { !sleepy.isRunning })
        t.check(Date().timeIntervalSince(start) < 15, "Timeout=3000 stopped it: \(Date().timeIntervalSince(start)) s")
        t.equal(sleepy.stringValue, "started\n")
        t.equal(skin.variable("SleepyDone"), "1")

        let long = measure(skin, "Long", RunCommandMeasure.self)
        long.execute(command: "Kill")
        t.equal(long.value, 102, "Kill when nothing runs")
        long.execute(command: "Run")
        spin(for: 0.05)
        long.execute(command: "Kill")
        t.check(spin(5) { !long.isRunning })
        t.equal(long.value, 1)
        long.execute(command: "Close")
        t.equal(long.value, 102)
        long.execute(command: "Jump")
        t.equal(long.value, 100)

        // State=Hide (default): unloading the skin kills the program.
        long.execute(command: "Run")
        spin(for: 0.05)
        t.check(long.isRunning)
        long.skinWillClose()
        t.check(!long.isRunning)

        let windows = measure(skin, "Windows", RunCommandMeasure.self)
        windows.execute(command: "Run")
        t.equal(windows.value, 103)
        t.check(host.logs.contains { $0.contains("PowerShell") && $0.contains("Windows program") })
        t.check(spin(2) { skin.variable("WindowsDone") == "x" })
        t.equal(skin.variable("WindowsDone"), "x", "FinishAction runs once after a failed start")
        windows.execute(command: "Run")
        spin(for: 0.05)
        t.equal(skin.variable("WindowsDone"), "x", "…but not again right away (no Run loop)")
    }

    t.suite("Plugin: RunCommand Close finishes even when the program stays (review)") {
        let (skin, _) = try makeSkin(t, """
        [Stubborn]
        Measure=Plugin
        Plugin=RunCommand
        Parameter=trap '' TERM; : > ready.flag; echo ready; while :; do sleep 0.1; done
        FinishAction=[!SetVariable StubbornDone 1]
        [Both]
        Measure=Plugin
        Plugin=RunCommand
        Parameter=echo out; echo err >&2; ls /nonexistent-folder-xyz 2>&1 | wc -l | tr -d ' '
        [Locale]
        Measure=Plugin
        Plugin=RunCommand
        Parameter=echo "$LANG$LC_ALL$LC_CTYPE"
        """)
        let savedGrace = RunCommandMeasure.closeGrace
        RunCommandMeasure.closeGrace = 0.2
        defer { RunCommandMeasure.closeGrace = savedGrace }
        let stubborn = measure(skin, "Stubborn", RunCommandMeasure.self)
        stubborn.execute(command: "Run")
        // Close only once the shell ignores TERM (it starts in the skin's folder); a loaded machine may take a while.
        let ready = skin.directory.appendingPathComponent("ready.flag").path
        t.check(spin(10) { FileManager.default.fileExists(atPath: ready) }, "the shell ignores TERM")
        stubborn.execute(command: "Close")
        t.check(spin(3) { !stubborn.isRunning }, "the run ends after the grace period")
        t.equal(stubborn.value, 1)
        t.equal(skin.variable("StubbornDone"), "1", "FinishAction runs \"even if the program does not terminate\"")
        t.equal(stubborn.runningJobCount, 1, "the program is still running, detached")
        stubborn.skinWillClose()
        t.equal(stubborn.runningJobCount, 0, "State=Hide: unloading kills detached programs too")

        let both = measure(skin, "Both", RunCommandMeasure.self)
        both.execute(command: "Run")
        t.check(spin(5) { !both.isRunning })
        t.equal(both.stringValue, "out\n1\n", "2>&1 reaches the shell intact; plain stderr is discarded")

        let locale = measure(skin, "Locale", RunCommandMeasure.self)
        locale.execute(command: "Run")
        t.check(spin(5) { !locale.isRunning })
        t.check(!locale.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "programs get a locale (UTF-8 output)")
        t.check(RunCommandJob.defaultLanguage.hasSuffix(".UTF-8"))
    }
}

// MARK: - Quote

private func runPluginQuoteTests(_ t: TestRunner) {
    t.suite("Plugin: QuotePlugin splits text files") {
        t.equal(QuoteMeasure.split("one\r\ntwo\n\n  \nthree", separator: "\n"), ["one", "two", "three"])
        t.equal(QuoteMeasure.split("a|b||c", separator: "|"), ["a", "b", "c"])
        t.equal(QuoteMeasure.split("", separator: "\n"), [])
    }

    t.suite("Plugin: QuotePlugin picks random lines and files") {
        let (skin, host) = try makeSkin(t, """
        [Line]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=quotes.txt
        [Custom]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=#CURRENTPATH#quotes2.txt
        Separator=%%
        [Images]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=#@#Images
        FileFilter=*.png;*.JPG
        [Flat]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=#@#Images\\
        Subfolders=0
        [Missing]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=nothing-here.txt
        """, files: [
            "Root/Sub/quotes.txt": "First quote\r\nSecond quote\r\n\r\nThird quote\r\n",
            "Root/Sub/quotes2.txt": "alpha%%beta",
            "Root/@Resources/Images/a.png": "x",
            "Root/@Resources/Images/b.txt": "x",
            "Root/@Resources/Images/.hidden.png": "x",
            "Root/@Resources/Images/Deep/c.jpg": "x",
        ])
        let line = measure(skin, "Line", QuoteMeasure.self)
        update(line)
        t.check(spin { !line.isLoading })
        t.equal(line.itemCount, 3)
        var seen: Set<String> = [line.stringValue]
        for _ in 0..<40 {
            update(line)
            seen.insert(line.stringValue)
        }
        t.equal(seen, ["First quote", "Second quote", "Third quote"])

        let custom = measure(skin, "Custom", QuoteMeasure.self)
        update(custom)
        t.check(spin { !custom.isLoading })
        t.check(["alpha", "beta"].contains(custom.stringValue))

        let images = measure(skin, "Images", QuoteMeasure.self)
        update(images)
        t.check(spin { !images.isLoading })
        t.equal(images.itemCount, 2, "a.png and Deep/c.jpg (hidden and filtered files skipped)")
        t.check(images.stringValue.hasSuffix("a.png") || images.stringValue.hasSuffix("c.jpg"))
        t.check(images.stringValue.hasPrefix("/"))

        let flat = measure(skin, "Flat", QuoteMeasure.self)
        update(flat)
        t.check(spin { !flat.isLoading })
        t.equal(flat.itemCount, 2, "a.png and b.txt, not the subfolder's file")

        let missing = measure(skin, "Missing", QuoteMeasure.self)
        update(missing)
        t.check(spin { !missing.isLoading })
        t.equal(missing.stringValue, "")
        t.check(host.logs.contains { $0.contains("does not exist") })
    }
}

// MARK: - FolderInfo

private func runPluginFolderInfoTests(_ t: TestRunner) {
    t.suite("Plugin: FolderInfo counts files, folders and size") {
        let (skin, _) = try makeSkin(t, """
        [Size]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=#@#Data
        InfoType=FolderSize
        [Files]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=[Size]
        InfoType=FileCount
        [Deep]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=#@#Data\\
        InfoType=FileCount
        IncludeSubFolders=1
        IncludeHiddenFiles=1
        [Folders]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=#@#Data
        InfoType=FolderCount
        IncludeSubFolders=1
        [Text]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=#@#Data
        InfoType=FileCount
        IncludeSubFolders=1
        RegExpFilter=(?i)\\.TXT$
        [System]
        Measure=Plugin
        Plugin=FolderInfo
        Folder=#@#Data
        InfoType=FileCount
        IncludeHiddenFiles=1
        IncludeSystemFiles=1
        """, files: [
            "Root/@Resources/Data/a.txt": "12345",
            "Root/@Resources/Data/b.jpg": "123",
            "Root/@Resources/Data/.hidden": "1",
            "Root/@Resources/Data/.DS_Store": "1",
            "Root/@Resources/Data/Sub/c.txt": "1234567",
            "Root/@Resources/Data/Sub/Inner/d.bin": "12",
        ])
        let size = measure(skin, "Size", FolderInfoMeasure.self, read: false)
        var byName: [String: FolderInfoMeasure] = ["size": size]
        func make(_ name: String) -> FolderInfoMeasure {
            let m = measure(skin, name, FolderInfoMeasure.self, read: false)
            byName[name.lowercased()] = m
            return m
        }
        let files = make("Files"), deep = make("Deep"), folders = make("Folders"), text = make("Text")
        let system = make("System")
        let all = [size, files, deep, folders, text, system]
        if !registryWired { for m in all { m.parentResolver = { byName[$0.lowercased()] } } }
        for m in all { update(m) }
        t.check(spin { !all.contains { $0.isScanning } })
        for m in all { update(m) }
        t.check(spin { !all.contains { $0.isScanning } })
        for m in all { update(m) }
        t.equal(size.value, 8, "a.txt + b.jpg (no hidden, no subfolders)")
        t.equal(files.value, 2, "Folder=[Size] reuses that measure's scan")
        t.equal(deep.value, 5, "a, b, .hidden, c, d")
        t.equal(folders.value, 2)
        t.equal(text.value, 2)
        t.equal(system.value, 4, ".hidden and .DS_Store too")
    }
}

// MARK: - FileView

private func runPluginFileViewTests(_ t: TestRunner) {
    let ini = """
    [Variables]
    ReadCount=
    [Parent]
    Measure=Plugin
    Plugin=FileView
    Path=#@#Folder
    Count=2
    ShowHidden=0
    FinishAction=[!SetVariable Read "[Parent]"][!SetVariable ReadCount "#ReadCount#x"]
    [Name1]
    Measure=Plugin
    Plugin=FileView
    Path=[Parent]
    Type=FileName
    Index=1
    [Name2]
    Measure=Plugin
    Plugin=FileView
    Path=[Parent]
    Type=FileName
    Index=2
    [Name3]
    Measure=Plugin
    Plugin=FileView
    Path=[Parent]
    Type=FileName
    Index=3
    [Size2]
    Measure=Plugin
    Plugin=FileView
    Path=[Parent]
    Type=FileSize
    Index=2
    [Count]
    Measure=Plugin
    Plugin=FileView
    Path=[Parent]
    Type=FileCount
    [Folder]
    Measure=Plugin
    Plugin=FileView
    Path=[Parent]
    [Dot]
    Measure=Plugin
    Plugin=FileView
    Path=[Parent]
    Type=FileName
    Index=1
    IgnoreCount=1
    [Tree]
    Measure=Plugin
    Plugin=FileView
    Path=#@#Folder
    Recursive=2
    Count=10
    Extensions=txt
    SortType=Size
    SortAscending=0
    HideExtensions=1
    [TreeName1]
    Measure=Plugin
    Plugin=FileView
    Path=[Tree]
    Type=FileName
    [TreeDate1]
    Measure=Plugin
    Plugin=FileView
    Path=[Tree]
    Type=FileDate
    [TreePath1]
    Measure=Plugin
    Plugin=FileView
    Path=[Tree]
    Type=PathToFile
    """
    let files = [
        "Root/@Resources/Folder/b.txt": "22",
        "Root/@Resources/Folder/a.txt": "1",
        "Root/@Resources/Folder/c.jpg": "333",
        "Root/@Resources/Folder/.secret": "x",
        "Root/@Resources/Folder/Zeta/deep.txt": "4444",
        "Root/@Resources/Folder/Alpha/x.txt": "55555",
    ]

    func load(_ t: TestRunner) throws -> (Skin, FakeHost, [String: FileViewMeasure]) {
        let (skin, host) = try makeSkin(t, ini, files: files)
        var byName: [String: FileViewMeasure] = [:]
        let names = ["Parent", "Name1", "Name2", "Name3", "Size2", "Count", "Folder", "Dot", "Tree", "TreeName1",
                     "TreeDate1", "TreePath1"]
        for n in names { byName[n.lowercased()] = measure(skin, n, FileViewMeasure.self, read: false) }
        if !registryWired { for m in byName.values { m.parentResolver = { byName[$0.lowercased()] } } }
        for n in names { byName[n.lowercased()]!.readOptionsIfNeeded() }
        return (skin, host, byName)
    }

    t.suite("Plugin: FileView parent lists a folder, children read entries") {
        let (skin, _, m) = try load(t)
        let parent = m["parent"]!
        update(parent)
        t.check(spin { !parent.isReading })
        t.check(m["name1"]!.isChild && !parent.isChild)
        for c in m.values where c.isChild { update(c) }
        t.check(parent.stringValue.hasSuffix("/@Resources/Folder/"))
        t.equal(parent.value, 6, "\"..\", 2 folders, 3 files")
        t.equal(skin.variable("ReadCount"), "x")
        if registryWired {
            t.equal(skin.variable("Read"), parent.stringValue, "FinishAction ran after the values were set")
        }
        t.equal(m["name1"]!.stringValue, "..")
        t.equal(m["name2"]!.stringValue, "Alpha")
        t.equal(m["name3"]!.stringValue, "..", "Index 3 with Count=2 wraps to 1")
        t.equal(m["size2"]!.stringValue, "", "folders have no size")
        t.equal(m["count"]!.value, 3)
        t.equal(m["folder"]!.stringValue, parent.stringValue)

        parent.execute(command: "PageDown")
        t.equal(m["name1"]!.stringValue, "Zeta", "children update at once")
        t.equal(m["name2"]!.stringValue, "a.txt")
        t.equal(m["dot"]!.stringValue, "..", "IgnoreCount=1 ignores the page")
        parent.execute(command: "IndexDown")
        t.equal(m["name1"]!.stringValue, "a.txt")
        t.equal(m["size2"]!.value, 2)
        t.equal(m["size2"]!.text(numberFormat: NumberFormatOptions()), "2")
        parent.execute(command: "IndexDown")
        parent.execute(command: "IndexDown")
        parent.execute(command: "IndexDown")
        t.equal(m["name1"]!.stringValue, "b.txt", "the last page keeps an item")
        parent.execute(command: "PageUp")
        parent.execute(command: "PageUp")
        parent.execute(command: "IndexUp")
        t.equal(m["name1"]!.stringValue, "..")
    }

    t.suite("Plugin: FileView navigation, recursion and commands") {
        let (skin, host, m) = try load(t)
        let parent = m["parent"]!
        update(parent)
        t.check(spin { !parent.isReading })
        parent.execute(command: "IndexDown")          // Alpha, Zeta
        m["name2"]!.execute(command: "FollowPath")   // into Zeta
        t.check(spin { !parent.isReading })
        t.check(parent.stringValue.hasSuffix("/Folder/Zeta/"))
        t.equal(m["name1"]!.stringValue, "..")
        t.equal(m["name2"]!.stringValue, "deep.txt")
        m["name2"]!.execute(command: "Open")
        t.check(host.executed.last?.hasSuffix("/Zeta/deep.txt") == true)
        m["name2"]!.execute(command: "ContextMenu")
        t.check(launchedPrograms.last?.0 == "/usr/bin/open" && launchedPrograms.last?.1.first == "-R")
        m["name2"]!.execute(command: "Properties")
        t.check(launchedPrograms.last?.0 == "/usr/bin/osascript")
        m["name1"]!.execute(command: "FollowPath")   // ".." → back up
        t.check(spin { !parent.isReading })
        t.check(parent.stringValue.hasSuffix("/@Resources/Folder/"))
        parent.execute(command: "PreviousFolder")
        t.check(spin { !parent.isReading })
        t.check(parent.stringValue.hasSuffix("/@Resources/"))

        // !SetOption Path + Update reads the new folder.
        if registryWired {
            skin.perform(Bang(name: "setoption", args: ["Parent", "Path", "#@#Folder\\Alpha"]))
        } else {
            parent.overrides["path"] = "#@#Folder\\Alpha"
            parent.needsOptionRead = true
        }
        parent.execute(command: "Update")
        t.check(spin { !parent.isReading })
        t.check(parent.stringValue.hasSuffix("/Folder/Alpha/"))
        t.equal(m["name2"]!.stringValue, "x.txt")

        // …and so does a #Variable# of Path changed with !SetVariable (no DynamicVariables). (review)
        if registryWired {
            skin.perform(Bang(name: "setoption", args: ["Parent", "Path", "#@#Folder\\#Sub#"]))
        } else {
            parent.overrides["path"] = "#@#Folder\\#Sub#"
            parent.needsOptionRead = true
        }
        skin.setVariable("Sub", "Alpha")
        parent.execute(command: "Update")
        t.check(spin { !parent.isReading })
        skin.setVariable("Sub", "Zeta")
        parent.execute(command: "Update")
        t.check(spin { !parent.isReading })
        t.check(parent.stringValue.hasSuffix("/Folder/Zeta/"), parent.stringValue)
        parent.overrides["path"] = "#@#Folder\\Alpha"
        parent.needsOptionRead = true
        parent.execute(command: "Update")
        t.check(spin { !parent.isReading })

        let tree = m["tree"]!
        update(tree)
        t.check(spin { !tree.isReading })
        update(m["treename1"]!); update(m["treedate1"]!); update(m["treepath1"]!)
        t.equal(tree.value, 4, "Recursive=2: every .txt file of the tree, no folders")
        t.equal(m["treename1"]!.stringValue, "x", "largest first, extension hidden")
        t.check(m["treepath1"]!.stringValue.hasSuffix("/Folder/Alpha/"))
        t.check(!m["treedate1"]!.stringValue.isEmpty)
        t.check(m["treedate1"]!.value > 13_000_000_000, "seconds since 1601")
        tree.execute(command: "PreviousFolder")
        t.check(!tree.isReading, "PreviousFolder is disabled with Recursive=2")
    }

    t.suite("Plugin: FileView icons through the app's writer") {
        let (skin, host) = try makeSkin(t, """
        [P]
        Measure=Plugin
        Plugin=FileView
        Path=#@#
        ShowDotDot=0
        [I]
        Measure=Plugin
        Plugin=FileView
        Path=[P]
        Type=Icon
        IconSize=Large
        """, files: ["Root/@Resources/file.txt": "x"])
        let p = measure(skin, "P", FileViewMeasure.self, read: false)
        let i = measure(skin, "I", FileViewMeasure.self, read: false)
        if !registryWired { i.parentResolver = { $0.lowercased() == "p" ? p : nil } }
        p.readOptionsIfNeeded(); i.readOptionsIfNeeded()
        update(p)
        t.check(spin { !p.isReading })
        update(i)
        t.equal(i.stringValue, "")
        t.check(host.logs.contains { $0.contains("icons are not available") })
        var requests: [(String, Int, String)] = []
        FileViewIcons.writer = { source, size, destination in
            requests.append((source, size, destination))
            return (try? "png".write(toFile: destination, atomically: true, encoding: .utf8)) != nil
        }
        defer { FileViewIcons.writer = nil }
        update(i)
        t.check(spin { !i.stringValue.isEmpty })
        t.equal(requests.count, 1)
        t.check(requests.first?.0.hasSuffix("/file.txt") == true)
        t.equal(requests.first?.1, 48)
        t.equal(i.stringValue, skin.directory.appendingPathComponent("icon1.ico").path)
        update(i)
        t.equal(requests.count, 1, "an icon is written once")
    }
}

// MARK: - RecycleManager

private func runPluginRecycleTests(_ t: TestRunner) {
    t.suite("Plugin: RecycleManager counts without listing the Trash") {
        t.check(TrashMonitor.entryCount(TrashMonitor.homeTrash) != nil, "the Trash's entry count needs no permission")
        let dir = t.temporaryDirectory("trash")
        writeFile(dir.appendingPathComponent("one.txt"), "12345")
        writeFile(dir.appendingPathComponent("Folder/two.txt"), "123")
        writeFile(dir.appendingPathComponent(".DS_Store"), "x")
        t.equal(TrashMonitor.entryCount(dir.path), 2, ".DS_Store is not an item")
        t.equal(TrashMonitor.size(of: dir.path), 9)
        t.check(TrashMonitor.size(of: dir.appendingPathComponent("missing").path) == nil)
    }

    t.suite("Plugin: RecycleManager measures and Finder commands") {
        let dir = t.temporaryDirectory("trash")
        writeFile(dir.appendingPathComponent("a"), "1234")
        writeFile(dir.appendingPathComponent("b"), "12")
        let saved = TrashMonitor.folders
        TrashMonitor.folders = { [dir.path] }
        defer { TrashMonitor.folders = saved }
        var done = false
        TrashMonitor.shared.refresh(includeSize: true, force: true, on: MainSkinExecutor.shared) { done = true }
        t.check(spin { done })
        let (skin, _) = try makeSkin(t, """
        [Count]
        Measure=RecycleManager
        [Size]
        Measure=Plugin
        Plugin=RecycleManager.dll
        RecycleType=SIZE
        Drives=C:
        """)
        let count = measure(skin, "Count", RecycleManagerMeasure.self)
        let size = measure(skin, "Size", RecycleManagerMeasure.self)
        update(count); update(size)
        t.equal(count.value, 2)
        t.equal(size.value, 6)
        t.check(!skin.issues.contains(RecycleManagerMeasure.sizeNote), "a readable Trash needs no note")

        // A Trash that can be counted but not listed (no Full Disk Access; here: a folder without read permission):
        // Size reads 0 with a compatibility note, which goes away once the size can be read.
        chmod(dir.path, 0o311)
        defer { chmod(dir.path, 0o755) }
        if TrashMonitor.size(of: dir.path) == nil {
            done = false
            TrashMonitor.shared.refresh(includeSize: true, force: true, on: MainSkinExecutor.shared) { done = true }
            t.check(spin { done })
            update(count); update(size)
            t.equal(count.value, 2, "the item count needs no permission")
            t.equal(size.value, 0)
            t.equal(skin.issues.filter { $0 == RecycleManagerMeasure.sizeNote }.count, 1, "\(skin.issues)")
            t.check(RecycleManagerMeasure.sizeNote.contains("Full Disk Access"))
            chmod(dir.path, 0o755)
            done = false
            TrashMonitor.shared.refresh(includeSize: true, force: true, on: MainSkinExecutor.shared) { done = true }
            t.check(spin { done })
            update(count); update(size)
            t.equal(size.value, 6)
            t.check(!skin.issues.contains(RecycleManagerMeasure.sizeNote), "granted later: the note goes away")
        } else {
            print("    (skipped the unreadable-Trash check: running with permission to read any folder)")
        }
        chmod(dir.path, 0o755)

        launchedPrograms = []
        count.execute(command: "OpenBin")
        t.equal(launchedPrograms.last?.0, "/usr/bin/open")
        t.equal(launchedPrograms.last?.1, [TrashMonitor.homeTrash])
        count.execute(command: "EmptyBin")
        t.equal(launchedPrograms.last?.0, "/usr/bin/osascript")
        let confirm = launchedPrograms.last?.1.joined(separator: "\n") ?? ""
        t.check(confirm.contains("display dialog") && confirm.contains("empty trash"))
        count.execute(command: "EmptyBinSilent")
        let silent = launchedPrograms.last?.1.joined(separator: "\n") ?? ""
        t.check(!silent.contains("display dialog") && silent.contains("empty trash"))
        t.equal(launchedPrograms.count, 3, "helper programs are recorded, never launched, in tests")
        spin(for: 0.05)

        // Finder's own warning (on by default) would add a second dialog to EmptyBin and one to EmptyBinSilent: both
        // scripts switch it off around `empty trash` only and restore it, also when emptying fails.
        for script in [confirm, silent] {
            let lines = script.components(separatedBy: "\n").filter { $0 != "-e" }
            let empty = lines.firstIndex(of: "empty trash") ?? -1
            t.check((lines.firstIndex(of: "set warns before emptying of trash to false") ?? Int.max) < empty)
            t.check((lines.lastIndex(of: "set warns before emptying of trash to previousWarning") ?? -1) > empty)
            t.equal(lines.filter { $0 == "set warns before emptying of trash to previousWarning" }.count, 2,
                    "restored after success and in the error handler")
        }
        // The scripts compile against Finder's dictionary (compiling runs nothing).
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/osacompile") {
            for arguments in [RecycleManagerMeasure.emptyScript(confirm: true),
                              RecycleManagerMeasure.emptyScript(confirm: false)] {
                let compiler = Process()
                compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
                compiler.arguments = ["-o", t.temporaryDirectory("osacompile").appendingPathComponent("x.scpt").path]
                    + arguments
                compiler.standardError = FileHandle.nullDevice
                try compiler.run()
                compiler.waitUntilExit()
                t.equal(compiler.terminationStatus, 0, "osacompile")
            }
        }
    }
}
