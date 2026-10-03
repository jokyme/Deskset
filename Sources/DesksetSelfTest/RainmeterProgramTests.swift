import Foundation
@testable import DesksetCore

private enum RainmeterFixtureError: Error { case utc, missingNode }

private final class RainmeterFixtureText: RainmeterTextMeasuring {
    var cycles: [Int] = []
    func measure(_ text: String, style: TextStyle, wrapWidth: Double?, cycle: Int) -> SkinSize? {
        cycles.append(cycle)
        return SkinSize(width: Double(text.count) * 7, height: text.isEmpty ? 0 : 14)
    }
}
private final class RainmeterFixtureHost: FakeHost {
    let text: RainmeterFixtureText
    init(_ text: RainmeterFixtureText) { self.text = text }
    override func environment(for skin: Skin) -> SkinEnvironment { RecordingSkinHost.fixedEnvironment }
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

private final class RainmeterUnqualifiedTime: Measure {
    static var constructions = 0
    required init(name: String, section: IniSection, skin: Skin, type: String) {
        Self.constructions += 1
        super.init(name: name, section: section, skin: skin, type: type)
    }
}

func runRainmeterProgramTests(_ t: TestRunner) {
    func input(_ suffix: String) throws -> (URL, URL, Data) {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestSkins/Engine/Compat/Anchors.ini")
        let data = try Data(contentsOf: source)
        let skins = t.temporaryDirectory("rainmeter-program-" + suffix)
        let file = skins.appendingPathComponent("Engine/Compat/Anchors.ini")
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
    func convert(_ file: URL, _ skins: URL, _ time: VirtualTimeExecutor, _ effects: RecordingSideEffects) throws -> RainmeterProgram {
        try IniProgramConverter.convert(config: "Engine\\Compat", fileURL: file, skinsDirectory: skins,
                                        system: FakeSystem(), environment: RecordingSkinHost.fixedEnvironment,
                                        clock: time.clock, executor: time, effects: effects)
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

}
