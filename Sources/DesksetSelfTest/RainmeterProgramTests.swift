import Foundation
@testable import DesksetCore

private enum RainmeterFixtureError: Error { case utc, missingNode }

private final class RainmeterFixtureText: RainmeterTextMeasuring {
    struct Call: Equatable {
        let text: String
        let style: TextStyle
        let wrapWidth: Double?
        let cycle: Int
    }
    var cycles: [Int] = []
    var calls: [Call] = []
    func measure(_ text: String, style: TextStyle, wrapWidth: Double?, cycle: Int) -> SkinSize? {
        cycles.append(cycle)
        calls.append(Call(text: text, style: style, wrapWidth: wrapWidth, cycle: cycle))
        return SkinSize(width: Double(text.count) * 7, height: text.isEmpty ? 0 : 14)
    }
}
private final class RainmeterFixtureHost: FakeHost {
    let text: RainmeterFixtureText
    init(_ text: RainmeterFixtureText) { self.text = text }
    var fixtureEnvironment = RecordingSkinHost.fixedEnvironment
    override func environment(for skin: Skin) -> SkinEnvironment { fixtureEnvironment }
    override func textSize(_ value: String, style: TextStyle, wrapWidth: Double?, for skin: Skin) -> (width: Double, height: Double) {
        let size = text.measure(value, style: style, wrapWidth: wrapWidth, cycle: skin.updateCount)
        return (size?.width ?? 0, size?.height ?? 0)
    }
}
private final class RainmeterFixtureEnvironment: SceneEnvironment {
    let stamp = EnvironmentStamp(scale: 1, fontGeneration: 0,
                                appearance: AppearanceStamp(value: .light, name: "fixed"), imageGeneration: 0)
    func imageStamp(_ path: String) -> ImageStamp? { preconditionFailure("No resource is admitted") }
}
private final class RainmeterSkinTick: TickTarget {
    weak var skin: Skin?
    let executor: SkinExecutor
    init(_ skin: Skin) { self.skin = skin; executor = skin.executor }
    var isClosed: Bool { skin?.isClosed ?? true }
    var updateMilliseconds: Int { skin?.settings.update ?? -1 }
    func updateForTick() { skin?.update() }
    func notifySystemWake() {}
}

private final class RainmeterSystemProbe: SystemDataSource {
    private let fallback = FakeSystem()
    var cpu: Double { get { fallback.cpu } set { fallback.cpu = newValue } }
    var memory: MemoryStatus { get { fallback.memory } set { fallback.memory = newValue } }
    var net: NetworkCounters { get { fallback.net } set { fallback.net = newValue } }
    var processorCount: Int { fallback.processorCount }
    func battery() -> BatteryStatus? { fallback.battery() }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
        reads.append("sysInfo:\(type):\(data)")
        return sysInfoAnswers[type + ":" + data] ?? sysInfoAnswers[type]
    }
    var sysInfoAnswers: [String: (number: Double, string: String?)] = [:]
    var reads: [String] = []
    var up = 90061.0
    var disk: (total: Double, free: Double)? = (1000, 250)
    var volume: VolumeInfo? = VolumeInfo(label: "Fixture", kind: .fixed)
    var available: Double?
    var runningProcess = true
    func diskSpace(path: String) -> (total: Double, free: Double)? { reads.append("disk:" + path); return disk }
    func volumeInfo(path: String) -> VolumeInfo? { reads.append("volume:" + path); return volume }
    func availableDiskSpace(path: String) -> Double? { reads.append("available:" + path); return available }
    func isProcessRunning(_ name: String) -> Bool { reads.append("process:" + name); return runningProcess }
    func uptime() -> TimeInterval { reads.append("uptime"); return up }
    func networkInterfaces() -> [String] { reads.append("interfaces"); return ["en0", "en1"] }
    func networkCounters(interface: String?) -> NetworkCounters {
        reads.append("network:" + (interface ?? "all")); return net
    }
    func cpuUsage(processor: Int) -> Double {
        reads.append("cpu:" + String(processor))
        return fallback.cpuUsage(processor: processor)
    }
    func memoryStatus() -> MemoryStatus {
        reads.append("memory")
        return fallback.memoryStatus()
    }
}

private final class RainmeterUnqualifiedTime: Measure {
    static var constructions = 0
    required init(name: String, section: IniSection, skin: Skin, type: String) {
        Self.constructions += 1
        super.init(name: name, section: section, skin: skin, type: type)
    }
}

private final class RainmeterUnqualifiedCalc: Measure {
    static var constructions = 0
    required init(name: String, section: IniSection, skin: Skin, type: String) {
        Self.constructions += 1
        super.init(name: name, section: section, skin: skin, type: type)
    }
}

func runRainmeterProgramTests(_ t: TestRunner) {
    func input(_ suffix: String, relative: String = "Engine/Compat/Anchors.ini") throws -> (URL, URL, Data) {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins").appendingPathComponent(relative)
        let data = try Data(contentsOf: source)
        let skins = t.temporaryDirectory("rainmeter-program-" + suffix)
        let file = skins.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return (skins, file, data)
    }
    func clock() throws -> VirtualTimeExecutor {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw RainmeterFixtureError.utc }
        let result = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_790_467_199), timeZone: utc)
        result.background.allowsUnfakedWork = false
        return result
    }
    func convert(_ file: URL, _ skins: URL, _ time: VirtualTimeExecutor, _ effects: RecordingSideEffects,
                 config: String = "Engine\\Compat") throws -> RainmeterProgram {
        try IniProgramConverter.convert(config: config, fileURL: file, skinsDirectory: skins,
                                        system: FakeSystem(), environment: RecordingSkinHost.fixedEnvironment,
                                        clock: time.clock, executor: time, effects: effects)
    }

    t.suite("Engine: Rainmeter system services: sampling and lifecycle match Skin") {
        let (skins, file, _) = try input("system-services")
        let source = """
        [Rainmeter]
        Update=250
        [CPU]
        Measure=CPU
        UpdateDivider=2
        AverageSize=2
        [Core]
        Measure=CPU
        Processor=3
        [Disabled]
        Measure=CPU
        Disabled=1
        [Paused]
        Measure=CPU
        Paused=1
        [RAM]
        Measure=PhysicalMemory
        UpdateDivider=3
        [Swap]
        Measure=SwapMemory
        Free=1
        [Memory]
        Measure=Memory
        Total=1
        [Display]
        Meter=String
        MeasureName=CPU
        Text=%1
        W=120
        H=20
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let conversionTime = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        let program = try convert(file, skins, conversionTime, effects)
        t.equal(program.sections.compactMap(\.kernel).filter { $0 == .cpu }.count, 4)
        t.equal(conversionTime.pendingCount, 0)
        t.equal(conversionTime.background.unverifiable.map(\.kind), [.system], "initial memory range reads are reported")
        let oldTime = try clock(), time = try clock()
        oldTime.background.setFake(.service, for: .system)
        time.background.setFake(.service, for: .system)
        let oldSystem = RainmeterSystemProbe(), system = RainmeterSystemProbe()
        let host = RainmeterFixtureHost(RainmeterFixtureText())
        let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: oldSystem, host: host)
        skin.runInVirtualTime(oldTime); skin.sideEffects = effects
        try skin.load()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: RainmeterFixtureText())
        defer { runtime.close(); skin.close() }
        // Range initialization can read memory at load: preserve that sequence rather than promise zero reads.
        t.equal(system.reads, oldSystem.reads)
        t.check(!system.reads.contains { $0.hasPrefix("cpu:") })
        let oldScheduler = TickScheduler(), target = RainmeterSkinTick(skin)
        defer { oldScheduler.cancel() }
        func compare() {
            t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
            t.equal(runtime.orderedMeasures.map(\.minValue), skin.measures.map(\.minValue))
            t.equal(runtime.orderedMeasures.map(\.maxValue), skin.measures.map(\.maxValue))
            t.equal(system.reads, oldSystem.reads)
            t.equal(time.background.reports, oldTime.background.reports)
            t.equal(runtime.updateCount, skin.updateCount)
        }
        skin.update(); try runtime.update(); compare()
        t.equal(runtime.measure(named: "Core")?.value, 3)
        t.equal(runtime.measure(named: "CPU")?.value, 42)
        t.equal(runtime.measure(named: "CPU")?.minValue, 0)
        t.equal(runtime.measure(named: "CPU")?.maxValue, 100)
        t.equal(runtime.measure(named: "Disabled")?.value, 0)
        t.equal(runtime.measure(named: "Paused")?.updateCount, 0)
        oldScheduler.startTimer(for: target); try runtime.startTimer()
        for index in 1...12 {
            oldSystem.cpu = Double(index * 7); system.cpu = oldSystem.cpu
            oldSystem.memory.physicalTotal = Double(index) * 4096
            oldSystem.memory.swapTotal = Double(index) * 2048
            oldSystem.memory.swapUsed = Double(index) * 512
            oldSystem.memory.physicalUsed = Double(index) * 1024
            system.memory = oldSystem.memory
            oldTime.advance(by: 0.25); time.advance(by: 0.25); compare()
        }
        let beforePause = system.reads
        oldScheduler.pause(); runtime.pause()
        oldTime.advance(by: 2); time.advance(by: 2); compare()
        t.equal(system.reads, beforePause)
        oldScheduler.resume(updateNow: true, target: target); try runtime.resume(updateNow: true); compare()
        oldSystem.cpu = .infinity; system.cpu = .infinity
        oldTime.advance(by: 1); time.advance(by: 1); compare()
        t.check(runtime.orderedMeasures.allSatisfy { $0.value.isFinite })
        oldSystem.cpu = 0; system.cpu = 0
        oldTime.advance(by: 1); time.advance(by: 1); compare()
        t.equal(runtime.measure(named: "CPU")?.value, 0)
        let beforeClose = system.reads
        runtime.close(); runtime.close(); oldScheduler.cancel(); skin.close()
        time.advance(by: 10)
        t.equal(system.reads, beforeClose)
        t.equal(time.pendingCount, 0)
        do { try runtime.update(); t.check(false, "closed owner must reject updates") }
        catch RainmeterProgramError.closed {}
        t.equal(effects.records, [])
        withExtendedLifetime(host) {}
    }

    t.suite("Engine: Rainmeter system services: virtual coverage and admission stay explicit") {
        let (skins, file, _) = try input("system-coverage")
        let effects = RecordingSideEffects(skinsDirectory: skins)
        for faked in [false, true] {
            try "[CPU]\nMeasure=CPU\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock()
            if faked { time.background.setFake(.service, for: .system) }
            let program = try convert(file, skins, time, effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
            try runtime.update(); try runtime.update()
            t.equal(time.background.reports.count, 1)
            t.equal(time.background.reports.first?.kind, .system)
            t.equal(time.background.reports.first?.faked, faked)
            t.equal(time.background.unverifiable.count, faked ? 0 : 1)
            runtime.close()
        }
        for (source, key) in [
            ("[CPU]\nMeasure=CPU\nProcessor=(Other+1)\n", "Processor"),
            ("[RAM]\nMeasure=PhysicalMemory\nFree=[Other]\n", "Free"),
            ("[CPU]\nMeasure=CPU\nOnUpdateAction=[!Log nope]\n", "OnUpdateAction"),
            ("[Music]\nMeasure=NowPlaying\n", "Measure")
        ] {
            try source.write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            do {
                _ = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                    system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock,
                    executor: time, effects: effects)
                t.check(false, "unqualified capability must fail before service access")
            } catch RainmeterProgramError.outsideInitialProfile(_, let actual, let location, _) {
                t.equal(actual, key); t.check(location != nil)
            }
            t.equal(system.reads, [])
            t.equal(time.pendingCount, 0)
        }
    }

    t.suite("Engine: Rainmeter system services: initialization and scripted ranges are covered") {
        let (skins, file, _) = try input("system-scripted")
        try "[CPU]\nMeasure=CPU\n[RAM]\nMeasure=PhysicalMemory\nMaxValue=999\nInvertMeasure=1\n".write(
            to: file, atomically: true, encoding: .utf8)
        for given in [false, true] {
            let time = try clock(), base = RainmeterSystemProbe()
            var first = SkinInputData.SystemFrame(), second = SkinInputData.SystemFrame()
            first.cpu = [25]; first.memory = MemoryStatus(physicalTotal: 100, physicalUsed: 40)
            second.cpu = [75]; second.memory = MemoryStatus(physicalTotal: 200, physicalUsed: 70)
            var zero = SkinInputData.SystemFrame()
            zero.cpu = [0]; zero.memory = MemoryStatus()
            var data = SkinInputData()
            if given { data.system = [first, second, zero] }
            let system = ScriptedSystemData(base: base, data: data)
            let effects = RecordingSideEffects(skinsDirectory: skins)
            let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
            t.equal(time.background.reports.count, 1, "conversion alone reads memory's initial range")
            t.equal(time.background.reports.first?.faked, given)
            let runtimeTime = try clock()
            let runtime = try RainmeterProgramRuntime(program: program, executor: runtimeTime, clock: runtimeTime.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            t.equal(runtimeTime.background.reports.count, 1, "initialization is covered before update")
            t.equal(runtimeTime.background.reports.first?.faked, given)
            if given {
                t.equal(base.reads, [])
                t.equal(runtime.measure(named: "RAM")?.maxValue, 100, "MaxValue option remains ignored")
                try runtime.update()
                t.equal(runtime.measure(named: "CPU")?.value, 25)
                t.equal(runtime.measure(named: "RAM")?.value, 60)
                system.advance(); try runtime.update()
                t.equal(runtime.measure(named: "CPU")?.value, 75)
                t.equal(runtime.measure(named: "RAM")?.maxValue, 200)
                t.equal(runtime.measure(named: "RAM")?.value, 130)
                system.advance(); try runtime.update()
                t.equal(runtime.measure(named: "RAM")?.maxValue, 1, "legacy minimum automatic maximum")
                t.equal(runtime.measure(named: "RAM")?.value, 1, "legacy inversion uses the guarded range")
                t.equal(base.reads, [])
            } else {
                t.equal(base.reads, ["memory", "memory"])
                try runtime.update()
                t.equal(runtime.measure(named: "CPU")?.value, 42)
                t.equal(runtimeTime.background.unverifiable.map(\.kind), [.system])
            }
            t.equal(runtimeTime.background.reports.count, 1, "first update does not duplicate the initial report")
        }
    }

    t.suite("Engine: Rainmeter system services: memory rechecks withdrawn frames at first update") {
        let (skins, file, _) = try input("memory-withdrawn")
        try "[RAM]\nMeasure=PhysicalMemory\n".write(to: file, atomically: true, encoding: .utf8)
        let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        var frame = SkinInputData.SystemFrame()
        frame.memory = MemoryStatus(physicalTotal: 100, physicalUsed: 40)
        var data = SkinInputData(); data.system = [frame]
        let base = RainmeterSystemProbe(), system = ScriptedSystemData(base: base, data: data)
        let program = try convert(file, skins, try clock(), effects)
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
        defer { runtime.close() }
        t.equal(time.background.reports.map(\.faked), [true])
        t.equal(base.reads, [])
        var withdrawn = SkinInputData(); withdrawn.system = []
        system.apply(withdrawn)
        try runtime.update()
        t.equal(base.reads, ["memory"])
        t.equal(runtime.measure(named: "RAM")?.value, base.memory.physicalUsed)
        t.equal(time.background.reports.map(\.faked), [true, false])
        t.equal(time.background.unverifiable.map(\.kind), [.system])
    }

    t.suite("Engine: Rainmeter system services: inactive memory does not sample until enabled") {
        for option in ["Disabled", "Paused"] {
            let (skins, file, _) = try input("memory-inactive-" + option)
            try "[RAM]\nMeasure=PhysicalMemory\n\(option)=1\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins), system = RainmeterSystemProbe()
            let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            try runtime.update()
            t.equal(system.reads, [])
            t.equal(time.background.reports, [])
            guard let memory = runtime.measure(named: "RAM") else { throw RainmeterFixtureError.missingNode }
            if option == "Disabled" { memory.setDisabled(false) } else { memory.setPaused(false) }
            try runtime.update()
            t.equal(system.reads, ["memory", "memory"], "range read then sample, with no hidden extra read")
            t.equal(memory.value, system.memory.physicalUsed)
            t.equal(time.background.unverifiable.map(\.kind), [.system])
        }
    }

    t.suite("Engine: Rainmeter system services: uptime and network keep independent cadence and history") {
        let (skins, file, _) = try input("network-uptime")
        try """
        [Rainmeter]
        Update=500
        [Up]
        Measure=Uptime
        UpdateDivider=2
        [Fixed]
        Measure=Uptime
        SecondsValue=90061
        AddDaysToHours=0
        [Fast]
        Measure=NetIn
        Interface=en0
        [Slow]
        Measure=NetIn
        Interface=en0
        UpdateDivider=2
        [Out]
        Measure=NetOut
        Interface=2
        NetOutSpeed=500
        [Total]
        Measure=NetTotal
        Interface=0
        Cumulative=1
        UseBits=1
        [Inactive]
        Measure=NetIn
        Disabled=1
        """.write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins), conversion = try clock()
        let program = try convert(file, skins, conversion, effects)
        t.equal(conversion.background.unverifiable.map(\.kind), [.system], "interface reads at conversion are covered")
        let oldTime = try clock(), time = try clock()
        let oldSystem = RainmeterSystemProbe(), system = RainmeterSystemProbe(), host = RainmeterFixtureHost(RainmeterFixtureText())
        let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: oldSystem, host: host)
        skin.runInVirtualTime(oldTime); skin.sideEffects = effects
        try skin.load()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
        let scheduler = TickScheduler(), target = RainmeterSkinTick(skin)
        defer { scheduler.cancel(); skin.close(); runtime.close() }
        t.equal(system.reads, oldSystem.reads)
        t.check(!system.reads.contains { $0.hasPrefix("network:") || $0 == "uptime" })
        func compare() {
            t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
            t.equal(runtime.orderedMeasures.map(\.maxValue), skin.measures.map(\.maxValue))
            t.equal(system.reads, oldSystem.reads)
            t.equal(time.background.reports, oldTime.background.reports)
        }
        skin.update(); try runtime.update(); compare()
        t.equal(runtime.measure(named: "Fast")?.value, 0)
        t.equal(runtime.measure(named: "Total")?.value, 12000)
        t.equal(runtime.measure(named: "Out")?.maxValue, 500)
        scheduler.startTimer(for: target); try runtime.startTimer()
        for n in 1...6 {
            system.net = NetworkCounters(received: UInt64(n == 6 ? 2600 : 1000 + n * 300), sent: UInt64(500 + n * 100))
            oldSystem.net = system.net; system.up += 0.5; oldSystem.up = system.up
            oldTime.advance(by: 0.5); time.advance(by: 0.5); compare()
        }
        t.equal(runtime.measure(named: "Fast")?.value, 200, "the fast node uses only the last half-second")
        t.equal(runtime.measure(named: "Slow")?.value, 400, "the slow node retains its independent one-second history")
        system.net = NetworkCounters(received: 5, sent: 3); oldSystem.net = system.net
        oldTime.advance(by: 1); time.advance(by: 1); compare()
        t.equal(runtime.measure(named: "Fast")?.value, 0, "counter reversal is not a negative rate")
        for node in [runtime.measure(named: "Fast"), skin.measure(named: "Fast")] {
            node?.overrides["interface"] = "en1"; node?.needsOptionRead = true
        }
        oldTime.advance(by: 0.5); time.advance(by: 0.5); compare()
        t.equal(runtime.measure(named: "Fast")?.value, 0, "interface change resets only the node's history")
        scheduler.pause(); runtime.pause()
        let pausedReads = system.reads
        oldTime.advance(by: 3); time.advance(by: 3); compare()
        t.equal(system.reads, pausedReads)
        scheduler.wake(target: target); try runtime.wake(); compare()
        scheduler.cancel(); skin.close(); runtime.close()
        let closedReads = system.reads
        time.advance(by: 10)
        t.equal(system.reads, closedReads); t.equal(time.pendingCount, 0)
        withExtendedLifetime(host) {}
    }

    t.suite("Engine: Rainmeter system services: fixed uptime does not read a service") {
        let (skins, file, _) = try input("fixed-uptime")
        try "[Up]\nMeasure=Uptime\nSecondsValue=90061\nAddDaysToHours=0\n".write(to: file, atomically: true, encoding: .utf8)
        let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins), system = RainmeterSystemProbe()
        let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
            system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
        defer { runtime.close() }
        try runtime.update()
        t.equal(runtime.measure(named: "Up")?.value, 90061)
        t.equal(system.reads, []); t.equal(time.background.reports, [])
    }

    t.suite("Engine: Rainmeter system services: empty options inactive network and admission edges") {
        let (skins, file, _) = try input("network-edges")
        let effects = RecordingSideEffects(skinsDirectory: skins)
        for source in ["[N]\nMeasure=Uptime\nSecondsValue=\nFormat=\n", "[N]\nMeasure=NetIn\nInterface=\n"] {
            try source.write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            let program = try convert(file, skins, try clock(), effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            try runtime.update()
            if source.contains("Uptime") {
                t.equal(system.reads, ["uptime"])
                t.equal(runtime.measure(named: "N")?.value, 90061)
                t.equal(runtime.measure(named: "N")?.stringValue, "")
            } else {
                t.check(system.reads.contains("network:en0"), "empty Interface retains Best semantics")
                t.equal(runtime.measure(named: "N")?.value, 0)
            }
            t.equal(time.background.unverifiable.map(\.kind), [.system])
        }
        for option in ["Disabled", "Paused"] {
            try "[N]\nMeasure=NetIn\nInterface=en0\n\(option)=1\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            try runtime.update(); t.equal(system.reads, []); t.equal(time.background.reports, [])
            guard let node = runtime.measure(named: "N") else { throw RainmeterFixtureError.missingNode }
            if option == "Disabled" { node.setDisabled(false) } else { node.setPaused(false) }
            try runtime.update()
            t.equal(system.reads, ["interfaces", "network:en0"])
            t.equal(node.value, 0)
        }
        for (source, key) in [
            ("[N]\nMeasure=Uptime\nSecondsValue=(Other+1)\n", "SecondsValue"),
            ("[N]\nMeasure=NetIn\nNetInSpeed=(Other+1)\n", "NetInSpeed"),
            ("[N]\nMeasure=NetTotal\nOnUpdateAction=[!Log no]\n", "OnUpdateAction"),
            ("[N]\nMeasure=Uptime\nOnUpdateAction=[!Log no]\n", "OnUpdateAction")
        ] {
            try source.write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            do {
                _ = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                    system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
                t.check(false, "unqualified option must be declined")
            } catch RainmeterProgramError.outsideInitialProfile(_, let actual, let location, _) {
                t.equal(actual, key); t.check(location != nil)
            }
            t.equal(system.reads, []); t.equal(time.pendingCount, 0)
        }
    }

    t.suite("Engine: Rainmeter system services: disk loading missing and process recovery match Skin") {
        let (skins, file, _) = try input("disk-process")
        try """
        [Rainmeter]
        Update=500
        [Available]
        Measure=FreeDiskSpace
        Drive=Fixture
        MacAvailable=1
        AverageSize=3
        InvertMeasure=1
        MaxValue=9
        [Total]
        Measure=FreeDiskSpace
        Drive=Fixture
        Total=1
        [Type]
        Measure=FreeDiskSpace
        Drive=Fixture
        Type=1
        [Label]
        Measure=FreeDiskSpace
        Drive=Fixture
        Label=1
        IgnoreRemovable=0
        [Process]
        Measure=Process
        ProcessName=Finder.exe
        [EmptyProcess]
        Measure=Process
        ProcessName=
        """.write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins), conversion = try clock()
        let program = try convert(file, skins, conversion, effects)
        t.equal(conversion.background.unverifiable.map(\.kind), [.system])
        let time = try clock(), oldTime = try clock(), system = RainmeterSystemProbe(), oldSystem = RainmeterSystemProbe()
        let host = RainmeterFixtureHost(RainmeterFixtureText())
        let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: oldSystem, host: host)
        skin.runInVirtualTime(oldTime); skin.sideEffects = effects; try skin.load()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
        defer { skin.close(); runtime.close() }
        t.equal(system.reads, oldSystem.reads)
        t.equal(system.reads, Array(repeating: "disk:/Volumes/Fixture", count: 4))
        func update() throws {
            skin.update(); try runtime.update()
            t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
            t.equal(runtime.orderedMeasures.map(\.valueUnavailable), skin.measures.map(\.valueUnavailable))
            t.equal(runtime.orderedMeasures.map(\.maxValue), skin.measures.map(\.maxValue))
            t.equal(system.reads, oldSystem.reads)
            t.equal(time.background.reports, oldTime.background.reports)
        }
        try update()
        t.equal(runtime.measure(named: "Available")?.value, -1)
        t.equal(runtime.measure(named: "Available")?.valueUnavailable, true)
        t.equal(runtime.measure(named: "Available")?.runtimeSnapshot.average, nil)
        t.equal(runtime.measure(named: "Available")?.maxValue, 1000)
        t.equal(runtime.measure(named: "Type")?.stringValue, "Fixed")
        t.equal(runtime.measure(named: "Label")?.stringValue, "Fixture")
        t.equal(runtime.measure(named: "Process")?.value, 1)
        t.equal(runtime.measure(named: "EmptyProcess")?.value, -1)
        t.check(!system.reads.contains("process:"))
        t.check(system.reads.contains("process:Finder"), "the provider receives the normalized process name")
        t.check(!system.reads.contains("process:Finder.exe"))
        system.available = 600; oldSystem.available = 600
        try update()
        t.equal(runtime.measure(named: "Available")?.value, 400, "loading does not enter inversion or averaging")
        t.equal(runtime.measure(named: "Available")?.valueUnavailable, false)
        system.available = 500; oldSystem.available = 500
        system.runningProcess = false; oldSystem.runningProcess = false
        try update()
        t.equal(runtime.measure(named: "Available")?.value, 450)
        t.equal(runtime.measure(named: "Process")?.value, -1)
        system.disk = nil; oldSystem.disk = nil; system.volume = nil; oldSystem.volume = nil
        try update()
        t.equal(runtime.measure(named: "Available")?.valueUnavailable, false, "missing volume differs from pending capacity")
        t.equal(runtime.measure(named: "Type")?.value, 1)
        t.equal(runtime.measure(named: "Type")?.stringValue, "Removed")
        t.equal(runtime.measure(named: "Label")?.value, 0, "missing volume returns zero before any numeric transform")
        system.disk = (1000, 250); oldSystem.disk = system.disk
        system.volume = VolumeInfo(label: "USB", kind: .removable); oldSystem.volume = system.volume
        system.runningProcess = true; oldSystem.runningProcess = true
        try update()
        t.equal(runtime.measure(named: "Type")?.value, 3)
        t.equal(runtime.measure(named: "Total")?.value, 0, "removable volumes remain ignored by default")
        t.equal(runtime.measure(named: "Label")?.value, 250)
        t.equal(runtime.measure(named: "Label")?.stringValue, "USB")
        t.equal(runtime.measure(named: "Process")?.value, 1)
        try runtime.startTimer()
        t.check(time.pendingCount > 0, "an active timer exists before close")
        runtime.close(); let count = system.reads.count
        time.advance(by: 10)
        t.equal(time.pendingCount, 0)
        do { try runtime.update(); t.check(false) } catch RainmeterProgramError.closed {}
        t.equal(system.reads.count, count)
        withExtendedLifetime(host) {}
    }

    t.suite("Engine: Rainmeter system services: inactive disk and invalid options stay inert") {
        let (skins, file, _) = try input("disk-inactive")
        let effects = RecordingSideEffects(skinsDirectory: skins)
        for option in ["Disabled", "Paused"] {
            try "[N]\nMeasure=FreeDiskSpace\n\(option)=1\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            try runtime.update(); t.equal(system.reads, []); t.equal(time.background.reports, [])
            guard let node = runtime.measure(named: "N") else { throw RainmeterFixtureError.missingNode }
            if option == "Disabled" { node.setDisabled(false) } else { node.setPaused(false) }
            try runtime.update()
            t.equal(system.reads, ["disk:/", "volume:/", "disk:/"])
            t.equal(node.value, 250)
        }
        for (source, key) in [
            ("[N]\nMeasure=FreeDiskSpace\nMacAvailable=(Other+1)\n", "MacAvailable"),
            ("[N]\nMeasure=FreeDiskSpace\nOnUpdateAction=[!Log no]\n", "OnUpdateAction"),
            ("[N]\nMeasure=Process\nProcessName=[Other]\n", "ProcessName")
        ] {
            try source.write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            do {
                _ = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                    system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
                t.check(false)
            } catch RainmeterProgramError.outsideInitialProfile(_, let actual, let location, _) {
                t.equal(actual, key); t.check(location != nil)
            }
            t.equal(system.reads, [])
        }
    }

    t.suite("Engine: Rainmeter system services: scripted disks and processes never fall through while frames exist") {
        let (skins, file, _) = try input("disk-scripted")
        try "[Disk]\nMeasure=FreeDiskSpace\n[Process]\nMeasure=Process\nProcessName=Finder.exe\n".write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins)
        for withdraw in [false, true] {
            var frame = SkinInputData.SystemFrame(), empty = SkinInputData.SystemFrame()
            frame.disks = ["/": SkinInputData.Disk(total: 100, free: 30)]
            frame.processes = [SkinInputData.Process(name: "Finder", pid: 1, cpu: 0)]
            empty.disks = [:]; empty.processes = []
            var data = SkinInputData(); data.system = [frame, empty]
            let base = RainmeterSystemProbe(), system = ScriptedSystemData(base: base, data: data), time = try clock()
            let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            t.equal(time.background.reports.map(\.faked), [true])
            t.equal(base.reads, [])
            if withdraw {
                var replacement = SkinInputData(); replacement.system = []; system.apply(replacement)
                try runtime.update()
                t.equal(runtime.measure(named: "Disk")?.value, 250)
                t.equal(base.reads, ["volume:/", "disk:/", "process:Finder"])
                t.equal(time.background.reports.map(\.faked), [true, false])
                t.equal(time.background.unverifiable.map(\.kind), [.system])
            } else {
                try runtime.update()
                t.equal(runtime.measure(named: "Disk")?.value, 30)
                t.equal(runtime.measure(named: "Process")?.value, 1)
                system.advance(); try runtime.update()
                t.equal(runtime.measure(named: "Disk")?.value, 0)
                t.equal(runtime.measure(named: "Disk")?.valueUnavailable, false)
                t.equal(runtime.measure(named: "Process")?.value, -1)
                t.equal(base.reads, [], "empty disk/process tables are missing data, never live fallback")
                t.equal(time.background.unverifiable, [])
            }
        }
    }

    t.suite("Engine: Rainmeter system services: disabled and paused process sources stay unread") {
        let (skins, file, _) = try input("process-inactive")
        for option in ["Disabled", "Paused"] {
            try "[N]\nMeasure=Process\nProcessName=Finder.exe\n\(option)=1\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe(), effects = RecordingSideEffects(skinsDirectory: skins)
            let program = try convert(file, skins, try clock(), effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            try runtime.update(); t.equal(system.reads, []); t.equal(time.background.reports, [])
            guard let node = runtime.measure(named: "N") else { throw RainmeterFixtureError.missingNode }
            if option == "Disabled" { node.setDisabled(false) } else { node.setPaused(false) }
            try runtime.update()
            t.equal(system.reads, ["process:Finder"]); t.equal(node.value, 1)
        }
    }

    t.suite("Engine: Rainmeter SysInfo: source answers recovery and cadence match Skin") {
        let (skins, file, _) = try input("sysinfo-values")
        let cases: [(String, String, String)] = [
            ("User", " user_name ", " en0 "), ("Number", "IDLE_TIME", ""),
            ("Empty", "", ""), ("Unknown", "NOT_A_TYPE", ""), ("Unsupported", "USER_SID", ""),
            ("Nonfinite", "NONFINITE", ""), ("Slow", "IDLE_TIME", ""), ("Once", "IDLE_TIME", "")
        ]
        let sections = cases.map { name, type, data in
            "[\(name)]\nMeasure=SysInfo\nSysInfoType=\(type)\nSysInfoData=\(data)\n" +
                (name == "Slow" ? "UpdateDivider=2\n" : name == "Once" ? "UpdateDivider=-1\n" : "")
        }.joined()
        try ("[Rainmeter]\nUpdate=500\n" + sections).write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins), conversion = try clock()
        let program = try convert(file, skins, conversion, effects)
        t.equal(conversion.background.reports, [], "static SysInfo options do not sample")
        let time = try clock(), oldTime = try clock(), system = RainmeterSystemProbe(), oldSystem = RainmeterSystemProbe()
        system.sysInfoAnswers = ["USER_NAME:en0": (0, "fixture-user"), "IDLE_TIME": (12, nil), "NONFINITE": (.nan, nil)]
        oldSystem.sysInfoAnswers = system.sysInfoAnswers
        let host = RainmeterFixtureHost(RainmeterFixtureText())
        let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: oldSystem, host: host)
        skin.runInVirtualTime(oldTime); skin.sideEffects = effects; try skin.load()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: host.fixtureEnvironment, system: system, effects: effects, text: nil)
        defer { skin.close(); runtime.close() }
        t.equal(system.reads, []); t.equal(oldSystem.reads, [])
        func update() throws {
            skin.update(); try runtime.update()
            t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
            t.equal(runtime.orderedMeasures.map(\.valueUnavailable), skin.measures.map(\.valueUnavailable))
            t.equal(system.reads, oldSystem.reads)
            t.equal(time.background.reports, oldTime.background.reports)
        }
        try update()
        t.equal(system.reads.count, 7)
        t.equal(runtime.measure(named: "User")?.stringValue, "fixture-user")
        t.equal(runtime.measure(named: "Number")?.value, 12)
        t.equal(runtime.measure(named: "Empty")?.rawString, "")
        t.equal(runtime.measure(named: "Unknown")?.valueUnavailable, false)
        t.equal(runtime.measure(named: "Unsupported")?.valueUnavailable, true)
        t.equal(runtime.measure(named: "Nonfinite")?.value, 0)
        t.check(!system.reads.contains("sysInfo::"))
        t.equal(runtime.logs.filter { $0.contains("NOT_A_TYPE") }.count, 1)
        system.sysInfoAnswers["IDLE_TIME"] = (24, nil)
        system.sysInfoAnswers["USER_SID"] = (7, "recovered")
        system.sysInfoAnswers["NONFINITE"] = (.infinity, "finite-text")
        oldSystem.sysInfoAnswers = system.sysInfoAnswers
        try update()
        t.equal(system.reads.count, 12)
        t.equal(runtime.measure(named: "Slow")?.value, 12)
        t.equal(runtime.measure(named: "Number")?.value, 24)
        t.equal(runtime.measure(named: "Unsupported")?.valueUnavailable, false)
        t.equal(runtime.measure(named: "Unsupported")?.rawString, "recovered")
        t.equal(runtime.measure(named: "Nonfinite")?.value, 0)
        t.equal(runtime.measure(named: "Nonfinite")?.rawString, "finite-text")
        try update()
        t.equal(system.reads.count, 18)
        t.equal(runtime.measure(named: "Slow")?.value, 24)
        t.equal(runtime.measure(named: "Once")?.value, 12)
        t.equal(runtime.logs.filter { $0.contains("NOT_A_TYPE") }.count, 1)
        try runtime.startTimer(); runtime.pause()
        let reads = system.reads
        time.advance(by: 3); t.equal(system.reads, reads)
        try runtime.resume(updateNow: false)
        t.equal(system.reads, reads)
        time.advance(by: 0.5); t.check(system.reads.count > reads.count)
        runtime.close(); let closedReads = system.reads
        time.advance(by: 3); t.equal(system.reads, closedReads); t.equal(time.pendingCount, 0)
        do { try runtime.update(); t.check(false) } catch RainmeterProgramError.closed {}
        withExtendedLifetime(host) {}
    }

    t.suite("Engine: Rainmeter SysInfo: screens timezone and environment are consumed next tick") {
        let (skins, file, _) = try input("sysinfo-environment")
        let cases: [(String, String, String)] = [
            ("Count", "NUM_MONITORS", ""), ("Width", "SCREEN_WIDTH", "2"),
            ("OutOfRange", "SCREEN_WIDTH", "999"), ("Negative", "SCREEN_HEIGHT", "-1"),
            ("TextData", "SCREEN_WIDTH", "en0"), ("Size", "SCREEN_SIZE", "2"),
            ("Work", "WORK_AREA", "2"), ("Left", "VIRTUAL_SCREEN_LEFT", ""),
            ("VirtualWidth", "VIRTUAL_SCREEN_WIDTH", ""), ("WorkLeft", "WORK_AREA_LEFT", "2"),
            ("Bias", "TIMEZONE_BIAS", ""), ("DST", "TIMEZONE_ISDST", ""),
            ("Standard", "TIMEZONE_STANDARD_NAME", ""), ("Daylight", "TIMEZONE_DAYLIGHT_NAME", ""),
            ("StandardBias", "TIMEZONE_STANDARD_BIAS", ""), ("DaylightBias", "TIMEZONE_DAYLIGHT_BIAS", ""),
            ("Bits", "OS_BITS", ""), ("Page", "PAGESIZE", "")
        ]
        try cases.map { "[\($0.0)]\nMeasure=SysInfo\nSysInfoType=\($0.1)\nSysInfoData=\($0.2)\n" }.joined()
            .write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins), program = try convert(file, skins, try clock(), effects)
        guard let zone = TimeZone(identifier: "America/New_York") else { throw RainmeterFixtureError.utc }
        let date = Date(timeIntervalSince1970: 1_798_761_598)
        let time = VirtualTimeExecutor(start: date, timeZone: zone), oldTime = VirtualTimeExecutor(start: date, timeZone: zone)
        let system = RainmeterSystemProbe(), oldSystem = RainmeterSystemProbe()
        system.sysInfoAnswers["SCREEN_WIDTH"] = (9999, nil); oldSystem.sysInfoAnswers = system.sysInfoAnswers
        let host = RainmeterFixtureHost(RainmeterFixtureText())
        host.fixtureEnvironment.screens = [
            SkinScreen(area: SkinRect(width: 1920, height: 1080), workArea: SkinRect(width: 1920, height: 1055)),
            SkinScreen(area: SkinRect(x: -1280, y: 100, width: 1280, height: 720),
                       workArea: SkinRect(x: -1280, y: 120, width: 1280, height: 700))
        ]
        let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: oldSystem, host: host)
        skin.runInVirtualTime(oldTime); skin.sideEffects = effects; try skin.load()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: host.fixtureEnvironment, system: system, effects: effects, text: nil)
        defer { skin.close(); runtime.close() }
        func update() throws {
            skin.update(); try runtime.update()
            t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
            t.equal(system.reads, []); t.equal(oldSystem.reads, [], "engine answers precede the source")
        }
        try update()
        for (name, value) in [("Count", 2.0), ("Width", 1280), ("OutOfRange", 1920), ("Negative", 1080),
                              ("TextData", 1920), ("Left", -1280), ("VirtualWidth", 3200), ("WorkLeft", -1280),
                              ("Bias", 300), ("DST", 0), ("StandardBias", 0), ("DaylightBias", -60), ("Bits", 64)] {
            t.equal(runtime.measure(named: name)?.value, value)
        }
        t.equal(runtime.measure(named: "Size")?.rawString, "1920 x 1080")
        t.equal(runtime.measure(named: "Work")?.rawString, "1920 x 1055")
        t.equal(runtime.measure(named: "Standard")?.rawString, zone.localizedName(for: .standard, locale: host.fixtureEnvironment.locale) ?? zone.identifier)
        t.equal(runtime.measure(named: "Daylight")?.rawString, zone.localizedName(for: .daylightSaving, locale: host.fixtureEnvironment.locale) ?? zone.identifier)
        let before = runtime.orderedMeasures.map(\.runtimeSnapshot), count = runtime.updateCount
        host.fixtureEnvironment.screens = []; runtime.takeEnvironment(host.fixtureEnvironment)
        t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), before); t.equal(runtime.updateCount, count)
        try update()
        for name in ["Count", "Width", "OutOfRange", "Negative", "TextData", "Left", "VirtualWidth", "WorkLeft"] {
            t.equal(runtime.measure(named: name)?.value, 0)
        }
        t.equal(runtime.measure(named: "Size")?.rawString, "0 x 0")
        t.equal(runtime.measure(named: "Work")?.rawString, "0 x 0")
        withExtendedLifetime(host) {}
    }

    t.suite("Engine: Rainmeter SysInfo: scripted lookup and withdrawn frames preserve coverage") {
        let (skins, file, _) = try input("sysinfo-scripted")
        try "[Specific]\nMeasure=SysInfo\nSysInfoType=IP_ADDRESS\nSysInfoData=en0\n[Fallback]\nMeasure=SysInfo\nSysInfoType=IP_ADDRESS\nSysInfoData=en9\n[Missing]\nMeasure=SysInfo\nSysInfoType=USER_SID\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let effects = RecordingSideEffects(skinsDirectory: skins)
        for withdraw in [false, true] {
            var frame = SkinInputData.SystemFrame(), empty = SkinInputData.SystemFrame()
            frame.sysInfo = ["IP_ADDRESS:en0": .init(number: 1, string: "specific"), "IP_ADDRESS": .init(number: 2, string: "type")]
            empty.sysInfo = [:]
            var data = SkinInputData(); data.system = [frame, empty, SkinInputData.SystemFrame()]
            let base = RainmeterSystemProbe(), system = ScriptedSystemData(base: base, data: data), time = try clock()
            base.sysInfoAnswers = ["IP_ADDRESS": (9, "base")]
            let program = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            t.equal(base.reads, []); t.equal(time.background.reports, [])
            if withdraw {
                var replacement = SkinInputData(); replacement.system = []; system.apply(replacement)
                try runtime.update()
                t.equal(runtime.measure(named: "Specific")?.rawString, "base")
                t.equal(base.reads, ["sysInfo:IP_ADDRESS:en0", "sysInfo:IP_ADDRESS:en9", "sysInfo:USER_SID:"])
                t.equal(time.background.reports.map(\.faked), [false])
                t.equal(time.background.unverifiable.map(\.kind), [.system])
            } else {
                try runtime.update()
                t.equal(runtime.measure(named: "Specific")?.rawString, "specific")
                t.equal(runtime.measure(named: "Specific")?.value, 1)
                t.equal(runtime.measure(named: "Fallback")?.rawString, "type")
                t.equal(runtime.measure(named: "Fallback")?.value, 2)
                t.equal(runtime.measure(named: "Missing")?.valueUnavailable, true)
                system.advance(); try runtime.update()
                t.equal(runtime.measure(named: "Specific")?.rawString, "")
                t.equal(runtime.measure(named: "Specific")?.valueUnavailable, true)
                t.equal(base.reads, [], "empty tables must not consult base")
                system.advance(); try runtime.update()
                t.equal(runtime.measure(named: "Missing")?.valueUnavailable, true)
                t.equal(runtime.measure(named: "Specific")?.valueUnavailable, true)
                t.equal(base.reads, [], "a frame with no sysInfo field must not consult base")
                t.equal(time.background.reports.map(\.faked), [true]); t.equal(time.background.unverifiable, [])
            }
        }
    }

    t.suite("Engine: Rainmeter SysInfo: inactive sources and admission remain bounded") {
        let (skins, file, _) = try input("sysinfo-admission")
        let effects = RecordingSideEffects(skinsDirectory: skins)
        for option in ["Disabled", "Paused"] {
            try "[N]\nMeasure=SysInfo\nSysInfoType=IDLE_TIME\n\(option)=1\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            system.sysInfoAnswers["IDLE_TIME"] = (42, nil)
            let program = try convert(file, skins, try clock(), effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: system, effects: effects, text: nil)
            defer { runtime.close() }
            try runtime.update(); t.equal(system.reads, []); t.equal(time.background.reports, [])
            guard let node = runtime.measure(named: "N") else { throw RainmeterFixtureError.missingNode }
            if option == "Disabled" { node.setDisabled(false) } else { node.setPaused(false) }
            try runtime.update(); t.equal(system.reads, ["sysInfo:IDLE_TIME:"]); t.equal(node.value, 42)
        }
        for (source, key, line) in [
            ("[N]\nMeasure=Plugin\nPlugin=SysInfo\n", "Measure", 2),
            ("[N]\nMeasure=SysInfo\nOnUpdateAction=[!Log no]\n", "OnUpdateAction", 3),
            ("[N]\nMeasure=SysInfo\nSysInfoType=[Other]\n", "SysInfoType", 3),
            ("[N]\nMeasure=SysInfo\nSysInfoData=[Other]\n", "SysInfoData", 3),
            ("[N]\nMeasure=SysInfo\nSysInfoData=#SCREENAREAWIDTH#\n", "SysInfoData", 3),
            ("[N]\nMeasure=SysInfo\nAverageSize=(Other+1)\n", "AverageSize", 3)
        ] {
            try source.write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), system = RainmeterSystemProbe()
            do {
                _ = try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                    system: system, environment: RecordingSkinHost.fixedEnvironment, clock: time.clock, executor: time, effects: effects)
                t.check(false)
            } catch RainmeterProgramError.outsideInitialProfile(let section, let actual, let location, _) {
                t.equal(section, "N"); t.equal(actual, key); t.equal(location?.line, line); t.equal(location?.file, file)
            }
            t.equal(system.reads, []); t.equal(time.pendingCount, 0)
        }
    }

    t.suite("Engine: Rainmeter SysInfo: portable fallback remains legacy behavior not a snapshot") {
        let (skins, file, _) = try input("sysinfo-portable")
        let types = ["USER_NAME", "COMPUTER_NAME", "HOST_NAME", "OS_VERSION", "OS_PRODUCT_NAME"]
        try types.map { "[\($0)]\nMeasure=SysInfo\nSysInfoType=\($0)\n" }.joined()
            .write(to: file, atomically: true, encoding: .utf8)
        var frame = SkinInputData.SystemFrame(); frame.sysInfo = [:]
        var data = SkinInputData(); data.system = [frame]
        let base = RainmeterSystemProbe(), oldBase = RainmeterSystemProbe()
        let system = ScriptedSystemData(base: base, data: data), oldSystem = ScriptedSystemData(base: oldBase, data: data)
        let time = try clock(), oldTime = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        let program = try convert(file, skins, try clock(), effects)
        let host = RainmeterFixtureHost(RainmeterFixtureText())
        let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: oldSystem, host: host)
        skin.runInVirtualTime(oldTime); skin.sideEffects = effects; try skin.load()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: host.fixtureEnvironment, system: system, effects: effects, text: nil)
        defer { skin.close(); runtime.close() }
        skin.update(); try runtime.update()
        t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
        t.equal(base.reads, []); t.equal(oldBase.reads, [])
        // The source table is isolated, but the original measure still has process/host fallbacks.
        // Do not claim these answers are supplied by the frame or remove them in this admission slice.
        t.equal(runtime.measure(named: "USER_NAME")?.rawString, NSUserName())
        t.equal(runtime.measure(named: "COMPUTER_NAME")?.rawString, runtime.measure(named: "HOST_NAME")?.rawString)
        t.equal(runtime.measure(named: "OS_VERSION")?.rawString, runtime.measure(named: "OS_PRODUCT_NAME")?.rawString)
        t.check(runtime.orderedMeasures.allSatisfy { !$0.valueUnavailable && $0.rawString != nil })
        withExtendedLifetime(host) {}
    }

    func quoteInput(_ suffix: String, divider: Int = 1, inactive: String = "") throws -> (URL, URL, URL, RainmeterProgram, RecordingSideEffects) {
        let (skins, file, _) = try input("quote-" + suffix)
        let asset = skins.appendingPathComponent("Engine/@Resources/quotes.txt")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Alpha\n".write(to: asset, atomically: true, encoding: .utf8)
        try """
        [Rainmeter]
        Update=1000
        [Q]
        Measure=Plugin
        Plugin=QuotePlugin
        PathName=#@#quotes.txt
        \(inactive)
        UpdateDivider=\(divider)
        [Text]
        Meter=String
        MeasureName=Q
        Text=%1
        W=120
        H=20
        """.write(to: file, atomically: true, encoding: .utf8)
        let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        let program = try convert(file, skins, time, effects)
        t.equal(time.pendingCount, 0, "conversion never starts a read or drains queued work")
        t.equal(time.background.reports, []); t.equal(effects.records, [])
        return (skins, file, asset, program, effects)
    }

    t.suite("Engine: Rainmeter Quote: results preserve Skin tick and meter boundaries") {
        for divider in [1, -1] {
            let (skins, file, asset, program, effects) = try quoteInput("timeline-" + String(divider), divider: divider)
            let time = try clock(), oldTime = try clock(), host = RainmeterFixtureHost(RainmeterFixtureText())
            let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: host)
            skin.runInVirtualTime(oldTime); skin.sideEffects = effects; skin.random = SkinRandom(seed: 1)
            try skin.load()
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
            defer { skin.close(); runtime.close() }
            t.equal(time.pendingCount, 0)
            var updates = 0
            runtime.didUpdate = { updates += 1 }
            func compare() {
                t.equal(runtime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
                t.equal((runtime.meter(named: "Text") as? StringMeter)?.text, text(skin, "Text"))
                t.equal(time.background.reports, oldTime.background.reports)
            }
            skin.update(); try runtime.update(); compare()
            t.equal(runtime.measure(named: "Q")?.stringValue, "")
            t.equal((runtime.measure(named: "Q") as? QuoteMeasure)?.isLoading, true)
            oldTime.runUntilIdle(); time.runUntilIdle(); compare()
            t.equal(runtime.measure(named: "Q")?.stringValue, "Alpha")
            t.equal((runtime.meter(named: "Text") as? StringMeter)?.text, "")
            t.equal(runtime.updateCount, 1); t.equal(updates, 1, "completion is not an extra update")
            skin.update(); try runtime.update(); compare()
            t.equal((runtime.meter(named: "Text") as? StringMeter)?.text, "Alpha")
            if divider == 1 {
                try "Beta\n".write(to: asset, atomically: true, encoding: .utf8)
                oldTime.advance(by: 61); time.advance(by: 61)
                skin.update(); try runtime.update(); compare()
                t.equal(runtime.measure(named: "Q")?.stringValue, "Alpha")
                oldTime.runUntilIdle(); time.runUntilIdle(); compare()
                t.equal(runtime.measure(named: "Q")?.stringValue, "Beta")
                t.equal((runtime.meter(named: "Text") as? StringMeter)?.text, "Alpha")
                skin.update(); try runtime.update(); compare()
                t.equal((runtime.meter(named: "Text") as? StringMeter)?.text, "Beta")
            } else {
                t.equal(runtime.measure(named: "Q")?.updateCount, 1)
            }
            t.equal(time.background.unverifiable, []); t.equal(effects.records, [])
            withExtendedLifetime(host) {}
        }
    }

    t.suite("Engine: Rainmeter Quote: missing empty and sandboxed files retain original meaning") {
        let (_, _, asset, program, effects) = try quoteInput("files")
        let time = try clock()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
        defer { runtime.close() }
        try FileManager.default.removeItem(at: asset)
        try runtime.update(); time.runUntilIdle()
        t.equal(runtime.measure(named: "Q")?.stringValue, ""); t.equal(runtime.logs.count, 1)
        try runtime.update(); time.runUntilIdle(); t.equal(runtime.logs.count, 1)
        try "\n \n".write(to: asset, atomically: true, encoding: .utf8)
        time.advance(by: 61); try runtime.update(); time.runUntilIdle()
        t.equal((runtime.measure(named: "Q") as? QuoteMeasure)?.itemCount, 0)
        t.equal(runtime.logs.count, 1, "an empty successful read is not another error")
        try effects.writeFile(Data("Sandbox\n".utf8), to: asset, makingFolder: true)
        time.advance(by: 61); try runtime.update(); time.runUntilIdle()
        t.equal(runtime.measure(named: "Q")?.stringValue, "Sandbox")
        t.equal(try String(contentsOf: asset, encoding: .utf8), "\n \n")
    }

    t.suite("Engine: Rainmeter Quote: queued reads cannot follow replaced files or ancestor chains") {
        for replacement in ["file", "resources", "root", "root-parent", "sandbox-file", "sandbox-parent", "sandbox-root"] {
            let (skins, _, asset, program, effects) = try quoteInput("queued-link-" + replacement)
            let time = try clock()
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
            defer { runtime.close() }
            if replacement.hasPrefix("sandbox") {
                try effects.writeFile(Data("Sandbox\n".utf8), to: asset, makingFolder: true)
            }
            let mapped = URL(fileURLWithPath: effects.readablePath(asset.path))
            let replaced: URL
            switch replacement {
            case "resources": replaced = asset.deletingLastPathComponent()
            case "root": replaced = asset.deletingLastPathComponent().deletingLastPathComponent()
            case "root-parent": replaced = skins
            case "sandbox-root": replaced = effects.fileSandbox!.directory
            case "sandbox-parent": replaced = mapped.deletingLastPathComponent()
            default: replaced = mapped
            }
            let outside = t.temporaryDirectory("quote-outside-" + replacement).appendingPathComponent("replacement")
            let relative = String(mapped.path.dropFirst(replaced.path.count))
            let outsideFile = relative.isEmpty ? outside : URL(fileURLWithPath: outside.path + relative)
            try FileManager.default.createDirectory(at: outsideFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "OUTSIDE-SECRET\n".write(to: outsideFile, atomically: true, encoding: .utf8)
            t.equal(time.pendingCount, 0)
            try runtime.update()
            t.check(time.pendingCount > 0, "the attack happens after authorization, before production")
            t.equal(runtime.measure(named: "Q")?.stringValue, "")
            let saved = replaced.deletingLastPathComponent().appendingPathComponent(replaced.lastPathComponent + "-saved")
            try FileManager.default.moveItem(at: replaced, to: saved)
            try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: outside)
            defer {
                try? FileManager.default.removeItem(at: replaced)
                try? FileManager.default.moveItem(at: saved, to: replaced)
            }
            time.runUntilIdle()
            t.equal(runtime.measure(named: "Q")?.stringValue, "")
            t.equal((runtime.measure(named: "Q") as? QuoteMeasure)?.itemCount, 0)
            t.equal((runtime.measure(named: "Q") as? QuoteMeasure)?.isLoading, false)
            t.check(runtime.logs.contains { $0.contains("cannot read") })
            t.equal(runtime.failure, nil)
            t.equal(runtime.updateCount, 1)
            t.equal(time.pendingCount, 0)
        }
    }

    t.suite("Engine: Rainmeter Quote: root files and in-tree links keep shared text parsing") {
        for location in ["root", "resources", "internal-link"] {
            let (skins, file, asset, _, effects) = try quoteInput("regular-" + location)
            let rootFile = asset.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("root.txt")
            try "\r\nFirst\r\n\r\nSecond\r\n".write(to: rootFile, atomically: true, encoding: .utf8)
            var source = rootFile
            if location == "resources" {
                try FileManager.default.removeItem(at: asset)
                try FileManager.default.copyItem(at: rootFile, to: asset)
                source = asset
            } else if location == "internal-link" {
                try FileManager.default.removeItem(at: asset)
                try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: rootFile)
                source = asset
            }
            try "[Q]\nMeasure=Plugin\nPlugin=QuotePlugin\nPathName=\(source.path)\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock(), program = try convert(file, skins, time, effects)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
            defer { runtime.close() }
            t.equal(time.pendingCount, 0)
            try runtime.update(); time.runUntilIdle()
            t.equal((runtime.measure(named: "Q") as? QuoteMeasure)?.itemCount, 2)
            t.check(["First", "Second"].contains(runtime.measure(named: "Q")?.stringValue ?? ""))
            t.equal(runtime.logs, [])
        }
    }

    t.suite("Engine: Rainmeter Quote: Program directories are explicitly unsupported") {
        let (skins, file, asset, _, effects) = try quoteInput("directory")
        try "[Q]\nMeasure=Plugin\nPlugin=QuotePlugin\nPathName=\(asset.deletingLastPathComponent().path)\n".write(to: file, atomically: true, encoding: .utf8)
        let time = try clock(), program = try convert(file, skins, time, effects)
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
        defer { runtime.close() }
        try runtime.update(); time.runUntilIdle()
        t.equal(runtime.measure(named: "Q")?.stringValue, "")
        t.check(runtime.logs.contains { $0.contains("directory Quote reads are not admitted") })
    }

    t.suite("Engine: Rainmeter Quote: queued production and completed results respect owner retirement") {
        let (_, _, asset, program, effects) = try quoteInput("retirement")
        let time = try clock()
        var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
        weak var weakOwner = runtime
        var produced = 0, delivered: [Int] = [], dropped: [Int] = []
        let fixture = BackgroundJob<Int>(.quote, subject: asset.path, start: { _ in produced += 100 },
                                        inline: { produced += 1; return 9 }, reads: asset.path)
        runtime?.startBackground(fixture, then: { delivered.append($0) }, orElse: { dropped.append($0) })
        runtime?.close(); time.runUntilIdle()
        t.equal(produced, 0, "a closed owner must not perform deferred IO just to discard it")
        t.equal(delivered, []); t.equal(dropped, [])
        runtime = nil; t.check(weakOwner == nil)
        for release in [false, true] {
            time.background.setFake(.service, for: .quote)
            var owner: RainmeterProgramRuntime? = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
            weak var weak = owner
            var finish: ((Int) -> Void)?
            let real = BackgroundJob<Int>(.quote, subject: asset.path, start: { finish = $0 }, reads: asset.path)
            owner?.startBackground(real, then: { delivered.append($0) }, orElse: { dropped.append($0) })
            t.equal(time.background.outstanding, 1)
            if release { owner = nil; t.check(weak == nil) } else { owner?.close() }
            finish?(release ? 8 : 7); finish = nil
            t.equal(delivered, [], "callback is never inline")
            time.runUntilIdle(); t.equal(time.background.outstanding, 0)
            owner = nil
        }
        t.equal(dropped, [7, 8]); t.equal(delivered, []); t.equal(time.pendingCount, 0)
    }

    t.suite("Engine: Rainmeter Quote: delayed fixture releases owner and executor without advancing") {
        let (_, _, asset, program, effects) = try quoteInput("delayed-retirement")
        weak var weakOwner: RainmeterProgramRuntime?
        weak var weakExecutor: VirtualTimeExecutor?
        var produced = 0, delivered = 0, dropped = 0
        do {
            let time = try clock()
            time.background.setFake(BackgroundFake(.fixture, delay: 60), for: .quote)
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
            weakOwner = runtime; weakExecutor = time
            let job = BackgroundJob<Int>(.quote, subject: asset.path, start: { _ in produced += 100 },
                inline: { produced += 1; return 7 }, reads: asset.path)
            runtime.startBackground(job, then: { delivered += $0 }, orElse: { dropped += $0 })
            t.check(time.pendingCount > 0)
            t.equal(produced, 0)
        }
        t.check(weakOwner == nil)
        t.check(weakExecutor == nil)
        t.equal(produced, 0); t.equal(delivered, 0); t.equal(dropped, 0)
    }

    t.suite("Engine: Rainmeter Quote: strict coverage and closed plugin prevent new work") {
        let (_, _, asset, program, effects) = try quoteInput("coverage")
        let time = try clock()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
        defer { runtime.close() }
        try runtime.update(); time.runUntilIdle()
        t.equal(time.background.reports.map(\.faked), [true])
        time.background.setFake(nil, for: .quote)
        time.advance(by: 61); try runtime.update(); time.runUntilIdle()
        t.equal(time.background.reports.map(\.faked), [true, false])
        t.equal(runtime.measure(named: "Q")?.stringValue, "Alpha")
        runtime.close()
        var starts = 0
        let job = BackgroundJob<Int>(.quote, subject: asset.path, start: { _ in starts += 1 }, reads: asset.path)
        runtime.startBackground(job, then: { _ in starts += 10 }, orElse: nil)
        t.equal(starts, 0)
        let after = time.pendingCount
        _ = runtime.measure(named: "Q")?.computeValue()
        t.equal(time.pendingCount, after)
    }

    t.suite("Engine: Rainmeter Quote: static path and plugin boundaries reject before IO") {
        let (skins, file, asset, _, effects) = try quoteInput("boundaries")
        let outside = skins.appendingPathComponent("outside.txt")
        try "Outside".write(to: outside, atomically: true, encoding: .utf8)
        let link = asset.deletingLastPathComponent().appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for (extra, key) in [("PathName=../../outside.txt", "PathName"), ("PathName=#@#escape.txt", "PathName"),
                             ("PathName=%HOME%/private", "PathName"), ("FinishAction=[!Log no]", "FinishAction")] {
            try "[Q]\nMeasure=Plugin\nPlugin=QuotePlugin\n\(extra)\n".write(to: file, atomically: true, encoding: .utf8)
            let time = try clock()
            do { _ = try convert(file, skins, time, effects); t.check(false) }
            catch RainmeterProgramError.outsideInitialProfile(_, let actual, let location, _) {
                t.equal(actual, key); t.check(location != nil)
            }
            t.equal(time.pendingCount, 0); t.equal(time.background.reports, [])
        }
        try "[Q]\nMeasure=Plugin\nPlugin=QuotePlugin\nPathName=#@#quotes.txt\n".write(to: file, atomically: true, encoding: .utf8)
        let time = try clock(), program = try convert(file, skins, time, effects)
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: outside)
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
        defer { runtime.close() }
        do { try runtime.update(); t.check(false) }
        catch RainmeterProgramError.unexpectedService(let reason) { t.equal(reason, "Quote read outside root config") }
        t.equal(time.pendingCount, 0); t.equal(time.background.reports, [])
    }

    t.suite("Engine: Rainmeter Quote: inactive and unreadable sources do not manufacture values") {
        for option in ["Disabled", "Paused"] {
            let (_, _, _, program, effects) = try quoteInput("inactive-" + option, inactive: option + "=1")
            let time = try clock()
            let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
                environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
            defer { runtime.close() }
            try runtime.update()
            t.equal(time.pendingCount, 0); t.equal(time.background.reports, [])
            guard let q = runtime.measure(named: "Q") else { throw RainmeterFixtureError.missingNode }
            if option == "Disabled" { q.setDisabled(false) } else { q.setPaused(false) }
            try runtime.update(); t.check(time.pendingCount > 0)
            time.runUntilIdle(); t.equal(q.stringValue, "Alpha")
        }
        let (_, _, asset, program, effects) = try quoteInput("unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: asset.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asset.path) }
        t.check(FileManager.default.contents(atPath: asset.path) == nil, "permission fixture must actually deny a read")
        let time = try clock()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
        defer { runtime.close() }
        try runtime.update(); time.runUntilIdle()
        t.equal(runtime.measure(named: "Q")?.stringValue, "")
        t.check(runtime.logs.contains { $0.contains("cannot read") })
        t.equal((runtime.measure(named: "Q") as? QuoteMeasure)?.itemCount, 0)
    }

    t.suite("Engine: Rainmeter Quote: changed options discard a superseded queued read") {
        let (_, _, asset, program, effects) = try quoteInput("superseded")
        let other = asset.deletingLastPathComponent().appendingPathComponent("other.txt")
        try "Beta".write(to: other, atomically: true, encoding: .utf8)
        let time = try clock()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: nil)
        defer { runtime.close() }
        try runtime.update()
        guard let q = runtime.measure(named: "Q") else { throw RainmeterFixtureError.missingNode }
        q.overrides["pathname"] = other.path; q.needsOptionRead = true
        try runtime.update(); time.runUntilIdle()
        t.equal(q.stringValue, "Beta"); t.equal(runtime.updateCount, 2)
    }

    let quoteRegistrySuite = "Engine: Rainmeter registry: substituted Quote plugin is declined before construction"
    if CommandLine.arguments.dropFirst().first == quoteRegistrySuite {
        t.suite(quoteRegistrySuite) {
            let (skins, file, _, _, effects) = try quoteInput("registry")
            defer { MeasureRegistry.registerPlugin("QuotePlugin", QuoteMeasure.self) }
            RainmeterUnqualifiedTime.constructions = 0
            MeasureRegistry.registerPlugin("QuotePlugin.dll", RainmeterUnqualifiedTime.self)
            do { _ = try convert(file, skins, try clock(), effects); t.check(false) }
            catch RainmeterProgramError.outsideInitialProfile(_, let key, let location, let reason) {
                t.equal(key, "Plugin"); t.check(location != nil); t.equal(reason, "registered plugin implementation")
            }
            t.equal(RainmeterUnqualifiedTime.constructions, 0)
        }
    }

    let systemRegistrySuite = "Engine: Rainmeter registry: substituted system kernels are declined before construction"
    if CommandLine.arguments.dropFirst().first == systemRegistrySuite {
        t.suite(systemRegistrySuite) {
            let (skins, file, _) = try input("system-registry")
            let types: [(String, Measure.Type)] = [("CPU", CPUMeasure.self), ("Memory", MemoryMeasure.self),
                ("PhysicalMemory", MemoryMeasure.self), ("SwapMemory", MemoryMeasure.self), ("Uptime", UptimeMeasure.self),
                ("NetIn", NetMeasure.self), ("NetOut", NetMeasure.self), ("NetTotal", NetMeasure.self),
                ("Process", ProcessMeasure.self), ("FreeDiskSpace", FreeDiskSpaceMeasure.self), ("SysInfo", SysInfoMeasure.self)]
            for (type, original) in types {
                MeasureRegistry.registerMeasure(type, original)
                defer { MeasureRegistry.registerMeasure(type, original) }
                try "[N]\nMeasure=\(type)\n".write(to: file, atomically: true, encoding: .utf8)
                let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
                _ = try convert(file, skins, time, effects)
                RainmeterUnqualifiedTime.constructions = 0
                MeasureRegistry.registerMeasure(type, RainmeterUnqualifiedTime.self)
                do { _ = try convert(file, skins, time, effects); t.check(false) }
                catch RainmeterProgramError.outsideInitialProfile(let section, let key, let location, let reason) {
                    t.equal(section, "N"); t.equal(key, "Measure"); t.equal(location?.line, 2); t.equal(location?.file, file)
                    t.equal(reason, "registered measure implementation")
                }
                t.equal(RainmeterUnqualifiedTime.constructions, 0)
                t.equal(effects.records, []); t.equal(time.pendingCount, 0)
            }
        }
    }

    t.suite("Engine: Rainmeter live owner: injected services use the real main executor") {
        let (skins, file, _) = try input("main-services", relative: "App/Counter/Counter.ini")
        let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        let program = try convert(file, skins, time, effects, config: "App\\Counter")
        let random = SkinRandom(seed: 974), text = RainmeterFixtureText()
        var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(program: program,
            executor: MainSkinExecutor.shared, clock: time.clock, environment: RecordingSkinHost.fixedEnvironment,
            system: FakeSystem(), effects: LiveSideEffects.shared, random: random, text: text)
        weak var owner = runtime
        weak var meter = runtime?.meters.first
        weak var measure = runtime?.orderedMeasures.first
        t.check(runtime?.executor === MainSkinExecutor.shared)
        t.check(runtime?.sideEffects === LiveSideEffects.shared)
        t.check(runtime?.random === random, "uses the explicitly supplied random stream")
        t.equal(runtime?.runsInVirtualTime, false)
        t.equal(runtime?.clock(), time.clock.uptime())
        var environment = RecordingSkinHost.fixedEnvironment
        environment.locale = Locale(identifier: "fr_FR")
        runtime?.takeEnvironment(environment)
        t.equal(runtime?.locale.identifier, "fr_FR")
        try runtime?.update()
        t.equal(runtime?.orderedMeasures.first?.value, 0)
        try runtime?.update()
        t.equal(runtime?.orderedMeasures.first?.value, 1)
        t.equal(text.cycles, [0, 1])
        runtime?.close(); runtime = nil
        t.check(owner == nil && meter == nil && measure == nil, "kernels borrow the independent owner")
        t.equal(effects.records, [])
    }

    t.suite("Engine: Rainmeter live owner: pause wake and synchronous completion retain the original tick order") {
        for name in ["Counter", "Observer"] {
            let (skins, file, _) = try input("lifecycle-" + name, relative: "App/\(name)/\(name).ini")
            let conversion = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
            let program = try convert(file, skins, conversion, effects, config: "App\\" + name)
            let oldTime = try clock(), time = try clock()
            let oldHost = RainmeterFixtureHost(RainmeterFixtureText())
            let skin = Skin(config: program.config, fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: oldHost)
            skin.runInVirtualTime(oldTime); skin.sideEffects = effects
            try skin.load()
            let oldClock = TickScheduler(), target = RainmeterSkinTick(skin)
            var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(program: program, executor: time,
                clock: time.clock, environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(),
                effects: effects, random: SkinRandom(seed: 1), text: RainmeterFixtureText())
            weak var weakOwner = runtime
            var completions: [Int] = []
            runtime?.didUpdate = { [weak runtime] in
                guard let runtime else { return }
                completions.append(runtime.updateCount)
                t.check(runtime.width > 0 && runtime.height > 0, "completion follows layout")
            }
            func compare() {
                t.equal(runtime?.updateCount, skin.updateCount)
                t.equal(runtime?.orderedMeasures.map(\.value), skin.measures.map(\.value))
                t.equal(runtime?.isPaused, oldClock.isPaused)
                t.equal(time.pendingCount, oldTime.pendingCount)
            }
            oldClock.pause(); runtime?.pause()
            skin.update(); try runtime?.update()
            oldClock.startTimer(for: target); try runtime?.startTimer(); compare()
            oldTime.advance(by: 2); time.advance(by: 2); compare()
            oldClock.resume(updateNow: false, target: target); try runtime?.resume(updateNow: false)
            oldTime.advance(by: 0.5); time.advance(by: 0.5)
            oldClock.resume(updateNow: true, target: target); try runtime?.resume(updateNow: true); compare()
            oldTime.advance(by: 0.5); time.advance(by: 0.5); compare()
            oldClock.pause(); runtime?.pause()
            oldTime.advance(by: 3); time.advance(by: 3); compare()
            oldClock.wake(target: target); try runtime?.wake(); compare()
            oldClock.wake(target: target); try runtime?.wake(); compare()
            t.equal(completions, Array(1...skin.updateCount), "one post-layout notification per actual update")
            // The callback can stop a just-resuming clock, at its original synchronous reentry point.
            runtime?.pause()
            runtime?.didUpdate = { [weak runtime] in runtime?.pause() }
            try runtime?.resume(updateNow: true)
            if name == "Counter" { t.equal(runtime?.isPaused, true); t.equal(time.pendingCount, 0) }
            runtime?.pause()
            runtime?.didUpdate = { [weak runtime] in runtime?.close() }
            try runtime?.resume(updateNow: true)
            if name == "Counter" { t.equal(runtime?.isClosed, true) }
            runtime?.close(); runtime = nil
            oldClock.cancel(); skin.close()
            t.check(weakOwner == nil)
            t.equal(time.pendingCount, 0)
            t.equal(effects.records, [])
            withExtendedLifetime(oldHost) {}
        }
    }

    t.suite("Engine: Rainmeter program: original Anchors survives conversion and runs without either Skin owner") {
        let (skins, file, bytes) = try input("timeline")
        let conversionTime = try clock()
        let effects = RecordingSideEffects(skinsDirectory: skins)
        let program = try convert(file, skins, conversionTime, effects)
        func sendable<T: Sendable>(_ value: T) -> T { value }
        t.equal(sendable(program), program)
        t.equal(program.sourceBytes, bytes)
        t.equal(program.sections.compactMap(\.kernel).filter { $0 == .time }.count, 2)
        t.equal(program.sections.compactMap(\.kernel).filter { $0 == .string }.count, 15)
        t.equal(program.sections.compactMap(\.kernel).filter { $0 == .image }.count, 3)
        t.equal(conversionTime.pendingCount, 0, "conversion is a static load, without a scheduled tick")
        t.equal(effects.records, [])
        t.equal(conversionTime.background.reports, [])
        let originalText = RainmeterFixtureText(), host = RainmeterFixtureHost(originalText)
        let originalTime = try clock()
        let environment = RainmeterFixtureEnvironment()
        var scenes: [WidgetScene] = []
        var states: [[SkinRuntimeState.MeasureState]] = []
        weak var oldOwner: Skin?
        do {
            var skin: Skin? = Skin(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: host)
            oldOwner = skin
            skin?.runInVirtualTime(originalTime)
            skin?.sideEffects = effects
            try skin?.load()
            t.equal(skin?.updateCount, 0)
            t.equal(skin?.counter, 0)
            t.check(originalText.cycles.isEmpty, "static load has not measured a laid-out string")
            guard let tickSkin = skin else { throw RainmeterFixtureError.missingNode }
            // The adapter's reference is weak; the local strong reference ends before the lifetime assertion below.
            let target = RainmeterSkinTick(tickSkin), scheduler = TickScheduler(), projector = SceneProjector()
            func capture() {
                guard let value = skin else { return }
                scenes.append(projector.project(value, environment: environment))
                states.append(value.measures.map(\.runtimeSnapshot))
            }
            skin?.update(); capture()
            t.equal(text(tickSkin, "Word"), "SATURDAY")
            t.equal(text(tickSkin, "LedFront"), "23:59")
            scheduler.startTimer(for: target)
            for _ in 1...60 { originalTime.advance(by: 1); capture() }
            t.equal(skin?.updateCount, 61)
            t.equal(text(tickSkin, "Word"), "SUNDAY")
            let before = originalTime.now
            originalTime.setWallClock(Date(timeIntervalSince1970: 1_790_553_600))
            t.equal(originalTime.now, before)
            t.equal(skin?.updateCount, 61)
            originalTime.advance(by: 1); capture()
            t.equal(text(tickSkin, "Word"), "MONDAY")
            scheduler.cancel()
            skin?.close(); skin = nil
        }
        t.check(oldOwner == nil, "the original oracle has released before independent execution begins")
        let independentTime = try clock()
        var service: RainmeterFixtureText? = RainmeterFixtureText()
        weak var weakService = service
        var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(
            program: program, executor: independentTime, clock: independentTime.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: service)
        weak var weakOwner = runtime
        weak var weakMeasure = runtime?.orderedMeasures.first
        weak var weakMeter = runtime?.meters.first
        t.equal(runtime?.updateCount, 0)
        t.check(service?.cycles.isEmpty == true)
        try runtime?.update()
        try runtime?.startTimer()
        for index in 0...60 {
            if index > 0 { independentTime.advance(by: 1) }
            t.equal(try runtime?.project(environment: environment), scenes[index], "complete scene at tick \(index)")
            t.equal(runtime?.orderedMeasures.map(\.runtimeSnapshot), states[index], "real kernel state at tick \(index)")
        }
        independentTime.setWallClock(Date(timeIntervalSince1970: 1_790_553_600))
        t.equal(runtime?.updateCount, 61)
        independentTime.advance(by: 1)
        t.equal(try runtime?.project(environment: environment), scenes[61])
        t.equal(runtime?.orderedMeasures.map(\.runtimeSnapshot), states[61])
        t.equal(service?.cycles, originalText.cycles, "measurement calls use the original cache cycle")
        t.equal(runtime?.failure, nil)
        t.equal(runtime?.logs, host.logs)
        t.equal(effects.records, [])
        t.equal(independentTime.background.reports, [])
        runtime?.close()
        let stopped = runtime?.updateCount
        independentTime.advance(by: 20)
        t.equal(runtime?.updateCount, stopped)
        t.equal(independentTime.pendingCount, 0)
        t.throwsError { _ = try runtime?.project(environment: environment) }
        runtime = nil; service = nil
        t.check(weakOwner == nil && weakMeasure == nil && weakMeter == nil && weakService == nil)
        t.check(!scenes[0].drawingItems.isEmpty, "old values survive both runtime and kernel release")
    }

    for (name, width, height, strings, images) in [("Align", 460.0, 330.0, 14, 9), ("Clip", 520.0, 360.0, 13, 0)] {
        t.suite("Engine: Rainmeter program: original \(name) preserves static text layout without a Skin owner") {
            let config = "String\\" + name
            let (skins, file, bytes) = try input(name, relative: "String/\(name)/\(name).ini")
            let conversionTime = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
            let program = try convert(file, skins, conversionTime, effects, config: config)
            t.equal(program.sourceBytes, bytes)
            t.equal(program.sections.compactMap(\.kernel).filter { $0 == .string }.count, strings)
            t.equal(program.sections.compactMap(\.kernel).filter { $0 == .image }.count, images)
            t.equal(program.sections.compactMap(\.kernel).filter { $0 == .time }.count, 0)
            t.equal(conversionTime.pendingCount, 0)
            let environment = RainmeterFixtureEnvironment(), originalText = RainmeterFixtureText()
            let host = RainmeterFixtureHost(originalText)
            var scenes: [WidgetScene] = []
            weak var original: Skin?
            do {
                let time = try clock(), projector = SceneProjector()
                let skin = Skin(config: config, fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: host)
                original = skin
                skin.runInVirtualTime(time); skin.sideEffects = effects
                try skin.load()
                t.equal(skin.updateCount, 0)
                t.check(originalText.calls.isEmpty)
                let scheduler = TickScheduler(), target = RainmeterSkinTick(skin)
                skin.update(); scheduler.startTimer(for: target)
                t.equal(skin.updateCount, 1)
                t.equal(time.now, 0)
                for index in 0...60 {
                    if index > 0 { time.advance(by: 1) }
                    scenes.append(projector.project(skin, environment: environment))
                }
                t.equal(skin.updateCount, 61)
                t.equal(time.now, 60)
                t.equal(skin.width, width); t.equal(skin.height, height)
                t.equal(skin.issues, [])
                scheduler.cancel(); skin.close()
                t.equal(time.pendingCount, 0)
            }
            t.check(original == nil, "the live oracle is released before independent execution")
            let time = try clock()
            var service: RainmeterFixtureText? = RainmeterFixtureText()
            weak var weakService = service
            var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(
                program: program, executor: time, clock: time.clock, environment: RecordingSkinHost.fixedEnvironment,
                system: FakeSystem(), effects: effects, text: service)
            weak var owner = runtime
            weak var meter = runtime?.meters.first
            t.equal(runtime?.updateCount, 0)
            t.check(service?.calls.isEmpty == true)
            try runtime?.update(); try runtime?.startTimer()
            for index in 0...60 {
                if index > 0 { time.advance(by: 1) }
                t.equal(runtime?.updateCount, index + 1)
                t.equal(try runtime?.project(environment: environment), scenes[index], "full scene at \(index)s")
            }
            t.equal(time.now, 60)
            t.equal(runtime?.width, width); t.equal(runtime?.height, height)
            t.equal(service?.calls, originalText.calls, "same text, style, wrapping, order and cycle")
            t.equal(runtime?.failure, nil)
            t.equal(runtime?.logs, host.logs)
            t.equal(effects.records, [])
            t.equal(time.background.reports, [])
            runtime?.close(); runtime = nil; service = nil
            t.check(owner == nil && meter == nil && weakService == nil)
            t.equal(time.pendingCount, 0)
            t.check(!scenes[0].drawingItems.isEmpty)
            t.equal(try Data(contentsOf: file), bytes)
        }
    }

    t.suite("Engine: Rainmeter program: static text options preserve empty and inherited boundaries") {
        let (skins, file, _) = try input("static-boundaries")
        let source = """
        [Rainmeter]
        AccurateText=1
        SkinWidth=0
        SkinHeight=-3
        [Style]
        Padding=2,,4,
        ClipString=2
        ClipStringW=80
        ClipStringH=0
        TrailingSpaces=1
        Text="  ab  "
        [Inherited]
        Meter=String
        MeterStyle=Style
        W=20
        H=10
        [Empty]
        Meter=String
        MeterStyle=Style
        Padding=
        ClipStringW=-4
        ClipStringH=
        [UnstyledEmpty]
        Meter=String
        Padding=
        ClipString=2
        ClipStringW=
        ClipStringH=
        Text=ab
        [Signed]
        Meter=String
        MeterStyle=Style
        Padding=-2,3,(1+3),0
        ClipString=1
        W=40
        H=10
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        let program = try convert(file, skins, time, effects)
        let text = RainmeterFixtureText(), host = RainmeterFixtureHost(text)
        let skin = Skin(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: host)
        skin.runInVirtualTime(time); skin.sideEffects = effects
        defer { skin.close() }
        try skin.load(); skin.update()
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: RainmeterFixtureText())
        defer { runtime.close() }
        try runtime.update()
        let environment = RainmeterFixtureEnvironment()
        t.equal(try runtime.project(environment: environment), SceneProjector().project(skin, environment: environment))
        t.equal(runtime.settings.skinWidth, nil); t.equal(runtime.settings.skinHeight, nil)
        let inherited = runtime.meter(named: "Inherited") as? StringMeter
        t.equal(inherited?.padding, SkinInsets(left: 2, top: 0, right: 4, bottom: 0))
        t.equal(inherited?.frame.width, 26); t.equal(inherited?.frame.height, 10)
        t.equal(inherited?.text, "  ab  ")
        t.equal(inherited?.style.accurateText, true)
        let empty = runtime.meter(named: "Empty") as? StringMeter
        t.equal(empty?.padding, SkinInsets(left: 2, top: 0, right: 4, bottom: 0), "empty own Padding inherits the style")
        t.equal(empty?.style.wrap, false, "negative W is unset; empty H inherits style zero, which is also unset")
        t.equal(empty?.frame.width, 48); t.equal(empty?.frame.height, 14)
        let unstyled = runtime.meter(named: "UnstyledEmpty") as? StringMeter
        t.equal(unstyled?.padding, .zero, "without a style, empty Padding supplies no insets")
        t.equal(unstyled?.style.wrap, false)
        t.equal(unstyled?.frame.width, 14); t.equal(unstyled?.frame.height, 14)
        t.equal(runtime.meter(named: "Signed")?.frame.width, 42)
        t.equal(runtime.meter(named: "Signed")?.frame.height, 13)
        t.equal(effects.records, [])
        for (section, key, value) in [("Rainmeter", "SkinWidth", "(Counter+1)"),
                                      ("Rainmeter", "AccurateText", "[Other]"),
                                      ("Style", "Padding", "1,(Counter+1),3,4"),
                                      ("Style", "ClipStringW", "(Other+1)"),
                                      ("Style", "TrailingSpaces", "#MACAPPEARANCE#")] {
            let invalid = "[\(section)]\n\(key)=\(value)\n[N]\nMeter=String\nMeterStyle=Style\nText=visible\n"
            try invalid.write(to: file, atomically: true, encoding: .utf8)
            do { _ = try convert(file, skins, time, effects); t.check(false, "must decline \(key)") }
            catch RainmeterProgramError.outsideInitialProfile(_, let actual, let location, _) {
                t.equal(actual, key); t.check(location != nil)
            }
            t.equal(time.pendingCount, 0)
            t.equal(time.background.reports, [])
            t.equal(effects.records, [])
        }
    }

    t.suite("Engine: Rainmeter program: preflight rejects capability and input gaps before constructing kernels") {
        let (skins, file, bytes) = try input("declines")
        let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
        let original = TextDecoding.decode(bytes)
        let cases: [(String, String)] = [
            ("[Rainmeter]\n@Include=missing.inc\n", "@Include"),
            ("[N]\nMeasure=Plugin\nPlugin=RunCommand\n", "Measure"),
            ("[N]\nMeter=String\nOnUpdateAction=[!Log wrong]\n", "OnUpdateAction"),
            ("[N]\nMeter=String\nText=[Other]\n", "Text"),
            ("[N]\nMeter=String\nText=#MACAPPEARANCE#\n", "Text"),
            ("[N]\nMeter=Image\nImageName=missing.png\n", "ImageName"),
            ("[N]\nMeter=String\nMeasureName=Missing\n", "MeasureName"),
            ("[N]\nMeter=String\nMeterStyle=Missing\n", "MeterStyle"),
            ("[N]\nMeter=String\nUnexpectedOption=1\n", "UnexpectedOption"),
            ("[N]\nMeter=String\nX=(Counter + 1)\n", "X"),
        ]
        for (source, key) in cases {
            try source.write(to: file, atomically: true, encoding: .utf8)
            do { _ = try convert(file, skins, time, effects); t.check(false, "must decline \(key)") }
            catch RainmeterProgramError.outsideInitialProfile(_, let actual, let source, _) {
                t.equal(actual, key)
                t.check(source != nil, "the original source location accompanies the decline")
            }
            t.equal(time.pendingCount, 0)
            t.equal(time.background.reports, [])
            t.equal(effects.records, [])
        }
        try original.write(to: file, atomically: true, encoding: .utf8)
        let program = try convert(file, skins, time, effects)
        // Altering disk after conversion cannot change the frozen program or supply the missing independent data.
        try "[N]\nMeter=String\nText=WRONG\n".write(to: file, atomically: true, encoding: .utf8)
        let runtime = try RainmeterProgramRuntime(program: program, executor: time, clock: time.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: RainmeterFixtureText())
        try runtime.update()
        t.equal((runtime.meter(named: "Word") as? StringMeter)?.text, "SATURDAY")
        t.equal(program.sourceBytes, bytes)
        runtime.close()
    }

    for name in ["Counter", "Observer"] {
        t.suite("Engine: Rainmeter program: original \(name) preserves its numeric timeline without a Skin owner") {
            let config = "App\\" + name
            let (skins, file, bytes) = try input(name, relative: "App/\(name)/\(name).ini")
            let conversionTime = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
            let program = try convert(file, skins, conversionTime, effects, config: config)
            t.equal(program.sourceBytes, bytes)
            t.equal(program.sections.compactMap(\.kernel).filter { $0 == .calc }.count, name == "Counter" ? 1 : 2)
            t.equal(conversionTime.pendingCount, 0)
            t.equal(conversionTime.background.reports, [])
            let environment = RainmeterFixtureEnvironment(), originalText = RainmeterFixtureText()
            let host = RainmeterFixtureHost(originalText)
            let manual = name == "Observer", last = manual ? 62 : 60
            var scenes: [WidgetScene] = [], states: [[SkinRuntimeState.MeasureState]] = []
            var logs: [[String]] = []
            weak var oldOwner: Skin?
            do {
                let time = try clock(), projector = SceneProjector()
                let skin = Skin(config: config, fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: host)
                oldOwner = skin
                skin.runInVirtualTime(time); skin.sideEffects = effects; skin.random = SkinRandom(seed: 1)
                try skin.load()
                t.equal(skin.updateCount, 0); t.equal(skin.counter, 0)
                t.check(originalText.calls.isEmpty)
                let scheduler = TickScheduler(), target = RainmeterSkinTick(skin)
                skin.update(); scheduler.startTimer(for: target)
                for index in 0...last {
                    if index > 0 && index <= 60 { time.advance(by: 1) }
                    if index > 60 { skin.update() } // Observer has no timer; these are explicit updates after 60s.
                    scenes.append(projector.project(skin, environment: environment))
                    states.append(skin.measures.map(\.runtimeSnapshot)); logs.append(host.logs)
                    let count = manual ? max(1, index - 59) : index + 1
                    t.equal(skin.updateCount, count)
                    t.equal(skin.measures.map(\.value), manual ? [Double(count), Double(count)] : [Double(index)])
                }
                t.equal(time.now, 60)
                scheduler.cancel(); skin.close()
                t.equal(time.pendingCount, 0)
            }
            t.check(oldOwner == nil, "the complete live oracle has released before the independent timeline")
            let time = try clock()
            var service: RainmeterFixtureText? = RainmeterFixtureText()
            weak var weakService = service
            var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(
                program: program, executor: time, clock: time.clock, environment: RecordingSkinHost.fixedEnvironment,
                system: FakeSystem(), effects: effects, text: service)
            weak var owner = runtime
            weak var measure = runtime?.orderedMeasures.first
            weak var meter = runtime?.meters.first
            t.equal(runtime?.updateCount, 0)
            try runtime?.update(); try runtime?.startTimer()
            for index in 0...last {
                if index > 0 && index <= 60 { time.advance(by: 1) }
                if index > 60 { try runtime?.update() }
                t.equal(try runtime?.project(environment: environment), scenes[index])
                t.equal(runtime?.orderedMeasures.map(\.runtimeSnapshot), states[index])
                t.equal(runtime?.logs, logs[index])
                t.equal(runtime?.updateCount, manual ? max(1, index - 59) : index + 1)
            }
            t.equal(time.now, 60)
            t.equal(service?.calls, originalText.calls)
            t.equal(runtime?.failure, nil)
            t.equal(effects.records, [])
            t.equal(time.background.reports, [])
            runtime?.close()
            time.advance(by: 20)
            t.equal(runtime?.updateCount, manual ? 3 : 61)
            t.equal(time.pendingCount, 0)
            runtime = nil; service = nil
            t.check(owner == nil && measure == nil && meter == nil && weakService == nil)
            t.equal(try Data(contentsOf: file), bytes)
        }
    }

    t.suite("Engine: Rainmeter program: numeric graph retains order cadence history and original errors") {
        let (skins, file, _) = try input("numeric-graph")
        let source = """
        [Rainmeter]
        Update=1000
        [A]
        Measure=Calc
        Formula=B+1
        [B]
        Measure=Calc
        Formula=A+1
        [Slow]
        Measure=Calc
        Formula=Slow+1
        UpdateDivider=2
        [Once]
        Measure=Calc
        Formula=Counter+7
        UpdateDivider=-1
        [Disabled]
        Measure=Calc
        Formula=Missing
        Disabled=1
        [Paused]
        Measure=Calc
        Formula=9
        Paused=1
        [Mean]
        Measure=Calc
        Formula=Counter*2
        AverageSize=2
        MinValue=0
        MaxValue=10
        InvertMeasure=1
        [Tracked]
        Measure=Calc
        Formula=Counter*2
        AverageSize=2
        [Failure]
        Measure=Calc
        Formula=Counter=0 ? 6 : Missing
        AverageSize=2
        MinValue=0
        MaxValue=10
        InvertMeasure=1
        [Bad]
        Measure=Calc
        Formula=(
        [Random]
        Measure=Calc
        Formula=Random
        LowBound=1
        HighBound=3
        UpdateRandom=1
        UniqueRandom=1
        [Sub]
        Measure=Calc
        Formula=0
        Substitute="^0":"zero"
        RegExpSubstitute=1
        [Binding]
        MeasureName2= B
        [Output]
        Meter=String
        MeterStyle=Binding
        MeasureName2=
        MeasureName4=Missing
        Text=%2
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let keys = ["A", "B", "Slow", "Once", "Disabled", "Paused", "Mean", "Tracked", "Failure", "Bad", "Random", "Sub"]
        let effects = RecordingSideEffects(skinsDirectory: skins), environment = RainmeterFixtureEnvironment()
        let host = RainmeterFixtureHost(RainmeterFixtureText()), time = try clock()
        var states: [[SkinRuntimeState.MeasureState]] = [], logs: [[String]] = [], scenes: [WidgetScene] = []
        var ranges: [[Double]] = [], strings: [[String]] = [], updateCounts: [[Int]] = []
        weak var oldOwner: Skin?
        do {
            let skin = Skin(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: host)
            oldOwner = skin
            skin.runInVirtualTime(time); skin.sideEffects = effects; skin.random = SkinRandom(seed: 1)
            try skin.load()
            let projector = SceneProjector()
            var randoms: [Double] = []
            for index in 0..<4 {
                skin.update()
                let values = keys.map { skin.measure(named: $0)?.value ?? .nan }
                t.equal(Array(values.prefix(10)), [Double(index * 2 + 1), Double(index * 2 + 2),
                    Double(index / 2 + 1), 7, 0, 0, [10.0, 9, 7, 5][index], [0.0, 1, 3, 5][index], 4, 0])
                randoms.append(values[10])
                t.equal(skin.measure(named: "Sub")?.stringValue, "zero")
                t.equal(text(skin, "Output"), String(index * 2 + 2), "empty own slot inherits style slot 2; the gap stops slot 4")
                states.append(skin.measures.map(\.runtimeSnapshot)); logs.append(host.logs)
                scenes.append(projector.project(skin, environment: environment))
                ranges.append(skin.measures.flatMap { [$0.minValue, $0.maxValue] })
                strings.append(skin.measures.map(\.stringValue)); updateCounts.append(skin.measures.map(\.updateCount))
            }
            t.equal(Set(randoms.prefix(3)), Set([1.0, 2, 3]), "UniqueRandom actually consumes a complete pool")
            t.equal(host.logs.filter { $0.contains("invalid Formula") }.count, 1)
            t.equal(host.logs.filter { $0.contains("cannot evaluate Formula") }.count, 1)
            t.check(!host.logs.contains { $0.contains("not found") }, "ignored slot 4 never queries Missing")
            skin.close()
        }
        t.check(oldOwner == nil)
        let conversionTime = try clock()
        let program = try convert(file, skins, conversionTime, effects)
        t.equal(program.sourceBytes, Data(source.utf8))
        t.equal(conversionTime.pendingCount, 0)
        let independentTime = try clock()
        var runtime: RainmeterProgramRuntime? = try RainmeterProgramRuntime(
            program: program, executor: independentTime, clock: independentTime.clock,
            environment: RecordingSkinHost.fixedEnvironment, system: FakeSystem(), effects: effects, text: RainmeterFixtureText())
        weak var owner = runtime
        weak var measure = runtime?.orderedMeasures.first
        for index in 0..<4 {
            try runtime?.update()
            t.equal(runtime?.orderedMeasures.map(\.runtimeSnapshot), states[index])
            t.equal(runtime?.orderedMeasures.flatMap { [$0.minValue, $0.maxValue] }, ranges[index])
            t.equal(runtime?.orderedMeasures.map(\.stringValue), strings[index])
            t.equal(runtime?.orderedMeasures.map(\.updateCount), updateCounts[index])
            t.equal(runtime?.logs, logs[index], "including load-time compile error, then one runtime evaluation error")
            t.equal(try runtime?.project(environment: environment), scenes[index])
        }
        t.equal(runtime?.failure, nil)
        t.equal(effects.records, [])
        t.equal(independentTime.background.reports, [])
        runtime?.close(); runtime = nil
        t.check(owner == nil && measure == nil)

        // Reverse the declarations while keeping their formulas: a topological/simultaneous evaluator would miss this.
        let reversed = source.replacingOccurrences(of: "[A]\nMeasure=Calc\nFormula=B+1\n[B]\nMeasure=Calc\nFormula=A+1",
            with: "[B]\nMeasure=Calc\nFormula=A+1\n[A]\nMeasure=Calc\nFormula=B+1")
        t.check(reversed != source)
        try reversed.write(to: file, atomically: true, encoding: .utf8)
        let reversedTime = try clock(), reversedHost = RainmeterFixtureHost(RainmeterFixtureText())
        let skin = Skin(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins, system: FakeSystem(), host: reversedHost)
        skin.runInVirtualTime(reversedTime); skin.random = SkinRandom(seed: 1); skin.sideEffects = effects
        try skin.load(); skin.update()
        t.equal([skin.measure(named: "A")?.value, skin.measure(named: "B")?.value], [2, 1])
        let reversedProgram = try convert(file, skins, conversionTime, effects)
        let reversedRuntime = try RainmeterProgramRuntime(program: reversedProgram, executor: independentTime,
            clock: independentTime.clock, environment: RecordingSkinHost.fixedEnvironment,
            system: FakeSystem(), effects: effects, text: RainmeterFixtureText())
        try reversedRuntime.update()
        t.equal(reversedRuntime.orderedMeasures.map(\.runtimeSnapshot), skin.measures.map(\.runtimeSnapshot))
        reversedRuntime.close(); skin.close()
    }

    t.suite("Engine: Rainmeter program: numeric admission keeps action resource and binding gaps explicit") {
        let time = try clock()
        for relative in ["Engine/Compat/EarlyGeometry.ini", "Plugins/RunCommand/RunCommand.ini"] {
            let (skins, file, bytes) = try input("numeric-decline-" + URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent, relative: relative)
            let effects = RecordingSideEffects(skinsDirectory: skins)
            do { _ = try convert(file, skins, time, effects); t.check(false, "unqualified original input must be declined") }
            catch RainmeterProgramError.outsideInitialProfile(_, _, let source, _) { t.check(source != nil) }
            t.equal(try Data(contentsOf: file), bytes)
            t.equal(effects.records, []); t.equal(time.background.reports, []); t.equal(time.pendingCount, 0)
        }
        let (skins, file, _) = try input("numeric-decline")
        let effects = RecordingSideEffects(skinsDirectory: skins)
        for (suffix, key) in [("OnUpdateAction=[!Log wrong]", "OnUpdateAction"),
                              ("IfCondition=Counter>1", "IfCondition"),
                              ("Formula=[Other:]", "Formula"),
                              ("[Text]\nMeter=String\nMeasureName2=Missing", "MeasureName2")] {
            let source = "[Value]\nMeasure=Calc\n" + suffix + "\n"
            try source.write(to: file, atomically: true, encoding: .utf8)
            do { _ = try convert(file, skins, time, effects); t.check(false, "must decline \(key)") }
            catch RainmeterProgramError.outsideInitialProfile(_, let actual, let location, _) {
                t.equal(actual, key); t.check(location != nil)
            }
            t.equal(effects.records, []); t.equal(time.background.reports, []); t.equal(time.pendingCount, 0)
        }
    }

    // This mutates the process registry. Run only as its exact standalone filter; never as part of the profile
    // prefix or an unfiltered corpus. The API has no unregister operation: a nil starting entry is reported,
    // then the suite's explicit TimeMeasure baseline is restored, rather than claiming to restore that nil slot.
    let registrySuite = "Engine: Rainmeter registry: substituted Time is declined before its constructor"
    if CommandLine.arguments.dropFirst().first == registrySuite {
        t.suite(registrySuite) {
            print("    Registry entry before isolated suite: \(MeasureRegistry.measure(named: "time").map { String(describing: $0) } ?? "nil (built-in switch)")")
            MeasureRegistry.registerMeasure("Time", TimeMeasure.self)
            defer { MeasureRegistry.registerMeasure("Time", TimeMeasure.self) }
            let (skins, file, _) = try input("registry")
            let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
            _ = try convert(file, skins, time, effects)
            RainmeterUnqualifiedTime.constructions = 0
            MeasureRegistry.registerMeasure("Time", RainmeterUnqualifiedTime.self)
            do {
                _ = try convert(file, skins, time, effects)
                t.check(false, "registered replacement must be rejected")
            } catch RainmeterProgramError.outsideInitialProfile(let section, let key, let source, let reason) {
                t.equal(section, "MeasureWord")
                t.equal(key, "Measure")
                t.check(source != nil)
                t.equal(reason, "registered measure implementation")
            }
            t.equal(RainmeterUnqualifiedTime.constructions, 0, "preflight runs before temporary Skin.load constructs anything")
            t.equal(effects.records, [])
            t.equal(time.pendingCount, 0)
            t.equal(time.background.reports, [])
            MeasureRegistry.registerMeasure("Time", TimeMeasure.self)
            t.equal(MeasureRegistry.measure(named: "time").map(ObjectIdentifier.init), ObjectIdentifier(TimeMeasure.self))
            let restored = try convert(file, skins, time, effects)
            t.equal(restored.sections.compactMap(\.kernel).filter { $0 == .time }.count, 2)
            t.equal(RainmeterUnqualifiedTime.constructions, 0)
        }
    }

    let calcRegistrySuite = "Engine: Rainmeter registry: substituted Calc is declined before its constructor"
    if CommandLine.arguments.dropFirst().first == calcRegistrySuite {
        t.suite(calcRegistrySuite) {
            print("    Registry entry before isolated suite: \(MeasureRegistry.measure(named: "calc").map { String(describing: $0) } ?? "nil (built-in switch)")")
            MeasureRegistry.registerMeasure("Calc", CalcMeasure.self)
            defer { MeasureRegistry.registerMeasure("Calc", CalcMeasure.self) }
            let (skins, file, _) = try input("calc-registry", relative: "App/Counter/Counter.ini")
            let time = try clock(), effects = RecordingSideEffects(skinsDirectory: skins)
            _ = try convert(file, skins, time, effects, config: "App\\Counter")
            RainmeterUnqualifiedCalc.constructions = 0
            MeasureRegistry.registerMeasure("Calc", RainmeterUnqualifiedCalc.self)
            do { _ = try convert(file, skins, time, effects, config: "App\\Counter"); t.check(false) }
            catch RainmeterProgramError.outsideInitialProfile(let section, let key, let source, let reason) {
                t.equal(section, "MeasureCounter"); t.equal(key, "Measure"); t.check(source != nil)
                t.equal(reason, "registered measure implementation")
            }
            t.equal(RainmeterUnqualifiedCalc.constructions, 0)
            t.equal(effects.records, []); t.equal(time.pendingCount, 0); t.equal(time.background.reports, [])
            MeasureRegistry.registerMeasure("Calc", CalcMeasure.self)
            let restored = try convert(file, skins, time, effects, config: "App\\Counter")
            t.equal(restored.sections.compactMap(\.kernel).filter { $0 == .calc }.count, 1)
            t.equal(MeasureRegistry.measure(named: "calc").map(ObjectIdentifier.init), ObjectIdentifier(CalcMeasure.self))
            t.equal(RainmeterUnqualifiedCalc.constructions, 0)
        }
    }

}
