import Foundation
@testable import DesksetCore

func runProgramBatteryDetailsTests(_ t: TestRunner) {
    let properties: Set<ProgramSystemProperty> = [.batteryHealth, .batteryCycles]
    let health = ProgramExpression.systemProperty(.batteryHealth)
    let cycles = ProgramExpression.systemProperty(.batteryCycles)
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0,
        appearance: AppearanceStamp(value: .light, name: "battery-details"), imageGeneration: 0)
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in
        SkinSize(width: Double(text.utf16.count) * 7, height: 14)
    }
    func number(_ expression: ProgramExpression) -> ProgramExpression {
        .formatNumber(expression, ProgramNumberFormat())
    }
    func percent(_ value: Double) -> ProgramExpression { .quantity(ProgramNumber(value, dimension: .percent)) }
    func caption(_ count: ProgramExpression = .systemProperty(.batteryCycles)) -> ProgramExpression {
        .concatenate([number(health), .string("%|"), number(count)])
    }
    func text(_ expression: ProgramExpression, index: Int = 0, hidden: Bool = false,
              actions: [ProgramAction]? = nil) -> ProgramElement {
        ProgramElement(id: ElementID(name: "details-\(index)", index: index), content: .text(ProgramText(value: expression)),
                       hidden: hidden, onClickActions: actions)
    }
    func strings(_ scene: WidgetScene) -> [String] {
        scene.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }
    }
    func failure(_ expected: ProgramRuntimeError, _ body: () throws -> Void) {
        do { try body(); t.check(false, "expected \(expected)") }
        catch { t.equal(error as? ProgramRuntimeError, expected) }
    }

    t.suite("Program: battery details: direct sampling shares one snapshot and sanitizes each field independently") {
        let system = ProgramBatteryDetailsFixture()
        let pending = ProgramSystemInput.sample(from: system, for: properties)
        t.equal(pending.batteryHealth, nil); t.equal(pending.batteryCycles, nil)
        t.equal(system.detailsCalls, 1); t.equal(system.batteryCalls, 0)
        system.details = .ready(BatteryDetails(health: 94, cycles: 231))
        let ready = ProgramSystemInput.sample(from: system, for: properties)
        t.equal(ready.batteryHealth, 94); t.equal(ready.batteryCycles, 231)
        t.equal(system.detailsCalls, 2); t.equal(system.batteryCalls, 0)
        let healthOnly = ProgramSystemInput.sample(from: system, for: [.batteryHealth])
        t.equal(healthOnly.batteryHealth, 94); t.equal(healthOnly.batteryCycles, nil)
        let cyclesOnly = ProgramSystemInput.sample(from: system, for: [.batteryCycles])
        t.equal(cyclesOnly.batteryHealth, nil); t.equal(cyclesOnly.batteryCycles, 231)
        _ = ProgramSystemInput.sample(from: system, for: [])
        _ = ProgramSystemInput.sample(from: system, for: [.batteryPresent])
        t.equal(system.detailsCalls, 4); t.equal(system.batteryCalls, 1)
        for bad in [-1.0, 101, .nan, .infinity, -.infinity] {
            system.details = .ready(BatteryDetails(health: bad, cycles: 231))
            let input = ProgramSystemInput.sample(from: system, for: properties)
            t.equal(input.batteryHealth, nil); t.equal(input.batteryCycles, 231)
            t.equal(ProgramSystemInput(batteryHealth: bad, batteryCycles: 231), input)
        }
        for bad in [-1.0, .nan, .infinity, -.infinity] {
            system.details = .ready(BatteryDetails(health: 94, cycles: bad))
            let input = ProgramSystemInput.sample(from: system, for: properties)
            t.equal(input.batteryHealth, 94); t.equal(input.batteryCycles, nil)
            t.equal(ProgramSystemInput(batteryHealth: 94, batteryCycles: bad), input)
        }
        for valid in [0.0, 0.5, Double.greatestFiniteMagnitude] {
            system.details = .ready(BatteryDetails(health: 0, cycles: valid))
            let input = ProgramSystemInput.sample(from: system, for: properties)
            t.equal(input.batteryHealth, 0); t.equal(input.batteryCycles, valid, "observed cycles have no added upper bound or integer restriction")
        }
        system.details = .ready(BatteryDetails())
        t.equal(ProgramSystemInput.sample(from: system, for: properties), ProgramSystemInput())
        let defaultSource: SystemDataSource = FakeSystem()
        t.equal(defaultSource.batteryDetails(), .ready(BatteryDetails()), "older providers remain completed but unavailable")
    }

    t.suite("Program: battery details: every demanded projection sees ready without a second hourly cache") {
        let system = ProgramBatteryDetailsFixture()
        system.status = BatteryStatus(percent: 50, isCharging: false, isPluggedIn: false, minutesRemaining: 120)
        var sampler = ProgramSystemSampler()
        let needed = properties.union([.batteryLevel, .batteryPresent, .batteryTimeRemaining])
        let pending = sampler.sample(from: system, for: needed, at: 0.25)
        t.equal(pending?.batteryHealth, nil); t.equal(pending?.batteryPresent, true)
        t.equal(pending?.batteryTimeRemaining, 7200); t.equal(system.detailsCalls, 1); t.equal(system.batteryCalls, 1)
        system.details = .ready(BatteryDetails(health: 94, cycles: 231))
        system.status = nil
        let ready = sampler.sample(from: system, for: needed, at: 0.25)
        t.equal(ready?.batteryHealth, 94); t.equal(ready?.batteryCycles, 231)
        t.equal(ready?.batteryLevel, 50); t.equal(system.detailsCalls, 2); t.equal(system.batteryCalls, 1)
        system.details = .ready(BatteryDetails(health: 0, cycles: 0))
        let zero = sampler.sample(from: system, for: properties, at: 0.5)
        t.equal(zero?.batteryHealth, 0); t.equal(zero?.batteryCycles, 0); t.equal(system.detailsCalls, 3)
        system.details = .ready(BatteryDetails())
        t.equal(sampler.sample(from: system, for: properties, at: 0.75), ProgramSystemInput())
        t.equal(system.detailsCalls, 4, "ready missing also comes from the provider, not a Core memo")
        sampler.invalidateBattery()
        _ = sampler.sample(from: system, for: properties.union([.batteryPresent]), at: 1)
        sampler.invalidateTimeBased()
        _ = sampler.sample(from: system, for: properties.union([.batteryPresent]), at: 2)
        let backwards = sampler.sample(from: system, for: properties.union([.batteryPresent]), at: -1)
        t.equal(backwards?.batteryPresent, true); t.equal(system.batteryCalls, 1); t.equal(system.detailsCalls, 7)
        sampler.reset()
        let reset = sampler.sample(from: system, for: properties.union([.batteryPresent]), at: 3_600)
        t.equal(reset?.batteryPresent, false); t.equal(system.batteryCalls, 2); t.equal(system.detailsCalls, 8)
        _ = sampler.sample(from: system, for: [.batteryPresent], at: 3_601)
        t.equal(sampler.sample(from: system, for: [], at: 3_601), nil)
        t.equal(sampler.sample(from: system, for: properties, at: .nan), nil)
        t.equal(system.detailsCalls, 8, "no details demand or invalid time never consults the provider")
    }

    t.suite("Program: battery details: typed missing and visible values keep exact hourly clock boundaries") {
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Battery details", root: text(caption())))
        for (input, expected) in [(ProgramSystemInput(batteryHealth: 94, batteryCycles: 231), "94%|231"),
                                  (ProgramSystemInput(batteryHealth: 0, batteryCycles: 0), "0%|0"),
                                  (ProgramSystemInput(), "–%|–")] {
            t.equal(strings(try runtime.project(environment: environment, systemInput: input, measure: measure)), [expected])
            t.equal(runtime.clockPrecision, .hour); t.equal(runtime.neededSystemProperties, properties)
        }
        let validTypes = ProgramExpression.conditional(.equal(health, percent(94)), then: number(.add(cycles, .number(1))),
                                                       otherwise: .string("other"))
        var typed = try ProgramRuntime(program: WidgetProgram(name: "Typed", root: text(validTypes)))
        t.equal(strings(try typed.project(environment: environment,
            systemInput: ProgramSystemInput(batteryHealth: 94, batteryCycles: 231), measure: measure)), ["232"])
        t.equal(strings(try typed.project(environment: environment, measure: measure)), ["other"], "missing condition is false only at consumption")
        failure(.invalidExpression) {
            _ = try ProgramRuntime(program: WidgetProgram(name: "Wrong dimension", root: text(number(.add(health, cycles)))))
        }
        for (instant, delay) in [(0.0, 3_600.0), (3_599.75, 0.25), (3_600.0, 3_600.0), (-0.25, 0.25), (-3_600.0, 3_600.0)] {
            t.equal(try ProgramClockPrecision.hour.delayToNextBoundary(after: Date(timeIntervalSince1970: instant)), delay)
        }
        t.equal(ProgramClockPrecision.combined(nil, .hour), .hour)
        t.equal(ProgramClockPrecision.combined(.hour, .hour), .hour)
        for precision in [ProgramClockPrecision.minute, .twoSeconds, .second] {
            t.equal(ProgramClockPrecision.combined(.hour, precision), precision)
            t.equal(ProgramClockPrecision.combined(precision, .hour), precision)
        }
        for (property, expected) in [(ProgramSystemProperty.batteryLevel, ProgramClockPrecision.minute),
                                     (.memoryUsed, .twoSeconds), (.cpuUsage, .second)] {
            var mixed = try ProgramRuntime(program: WidgetProgram(name: "Mixed", root: text(.concatenate([caption(), number(.systemProperty(property))]))))
            _ = try mixed.project(environment: environment, measure: measure)
            t.equal(mixed.clockPrecision, expected)
        }
    }

    t.suite("Program: battery details: hidden layout inactive branches and action transactions retain dependency rules") {
        var hidden = try ProgramRuntime(program: WidgetProgram(name: "Hidden", root: text(number(health), hidden: true)))
        var measured: [String] = []
        let hiddenScene = try hidden.project(environment: environment, systemInput: ProgramSystemInput(batteryHealth: 94)) { value, _, _ in
            measured.append(value); return SkinSize(width: 14, height: 14)
        }
        t.equal(measured, ["94"]); t.equal(hiddenScene.drawingItems, []); t.equal(hidden.clockPrecision, nil)
        t.equal(hidden.neededSystemProperties, [.batteryHealth])
        let gate = ProgramElement(id: ElementID(name: "gate", index: 1), content: .conditional(ProgramConditional(
            branches: [ProgramConditionalBranch(condition: .systemProperty(.batteryCharging), body: [text(caption(), index: 2)])],
            otherwise: [text(.string("idle"), index: 3)])))
        let root = ProgramElement(id: ElementID(name: "root", index: 0), content: .column(spacing: 0, align: .left, children: [gate]))
        var branch = try ProgramRuntime(program: WidgetProgram(name: "Branch", root: root))
        t.equal(strings(try branch.project(environment: environment, measure: measure)), ["idle"])
        t.equal(branch.clockPrecision, nil)
        t.equal(branch.neededSystemProperties, properties.union([.batteryCharging]), "sampling remains conservative across branches")
        t.equal(strings(try branch.project(environment: environment,
            systemInput: ProgramSystemInput(batteryCharging: true, batteryHealth: 94, batteryCycles: 231), measure: measure)), ["94%|231"])
        t.equal(branch.clockPrecision, .hour)

        let node = text(number(.declaration(0)), actions: [
            .assign(ProgramAssignment(declaration: 0, value: cycles)), .copy(caption(.declaration(0)))])
        var action = try ProgramRuntime(program: WidgetProgram(name: "Snapshot", root: node,
            declarations: [ProgramDeclaration(name: "captured", kind: .variable, initial: .number(0))]))
        let first = try action.project(environment: environment, measure: measure)
        t.equal(action.neededSystemProperties, []); t.equal(action.clockPrecision, nil)
        let point = SkinPoint(x: 2, y: 2)
        t.equal(action.neededSystemProperties(clickAt: point), properties)
        let system = ProgramBatteryDetailsFixture()
        system.details = .ready(BatteryDetails(health: 94, cycles: 231))
        let input = ProgramSystemInput.sample(from: system, for: action.neededSystemProperties(clickAt: point))
        system.details = .ready(BatteryDetails(health: 50, cycles: 999))
        let click = try action.clickWithEffects(at: point, expectedGeneration: first.generation,
            environment: environment, systemInput: input, measure: measure)
        t.equal(click?.effects, [.copy("94%|231")]); t.equal(click.map { strings($0.scene) }, ["231"])
        t.equal(system.detailsCalls, 1); t.equal(action.clockPrecision, nil)
        let generation = action.generation
        failure(.invalidMeasurement(node.id)) {
            _ = try action.clickWithEffects(at: point, expectedGeneration: generation, environment: environment,
                systemInput: ProgramSystemInput(batteryHealth: 99, batteryCycles: 333)) { _, _, _ in
                    throw ProgramRuntimeError.invalidMeasurement(node.id)
                }
        }
        t.equal(action.generation, generation)
        t.equal(strings(try action.project(environment: environment, measure: measure)), ["231"], "a failed candidate does not commit the new count")
        t.equal(action.clockPrecision, nil)
    }

    t.suite("Program: battery details: replay fields preserve old battery units and isolate invalid numeric values") {
        let directory = t.temporaryDirectory("battery-details-input")
        func read(_ source: String) throws -> SkinInputData { try SkinInputData.load(source, directory: directory) }
        let data = try read(#"{"battery":{"level":50,"charging":true,"timeRemaining":120,"timeUntilFull":45,"health":94,"cycles":231}}"#)
        t.equal(data.battery, .value(BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true,
            minutesRemaining: 120, minutesUntilFull: 45)))
        t.equal(data.batteryDetails, .value(BatteryDetails(health: 94, cycles: 231)))
        t.equal(data.givenKeys, ["battery"]); t.equal(data.unknownKeys, [])
        let replay = ScriptedSystemData(base: ProgramBatteryDetailsFixture(), data: data)
        let input = ProgramSystemInput.sample(from: replay, for: properties.union([.batteryTimeRemaining, .batteryLevel]))
        t.equal(input.batteryHealth, 94); t.equal(input.batteryCycles, 231)
        t.equal(input.batteryTimeRemaining, 2_700); t.equal(input.batteryLevel, 50)
        for (fields, expected) in [
            ("\"health\":-1,\"cycles\":231", BatteryDetails(cycles: 231)),
            ("\"health\":101,\"cycles\":231", BatteryDetails(cycles: 231)),
            ("\"health\":94,\"cycles\":-1", BatteryDetails(health: 94)),
            ("\"health\":0,\"cycles\":0", BatteryDetails(health: 0, cycles: 0)),
            ("\"health\":null,\"cycles\":0.5", BatteryDetails(cycles: 0.5)),
            ("\"health\":94,\"cycles\":null", BatteryDetails(health: 94))
        ] {
            let value = try read("{\"battery\":{\"level\":25,\"timeRemaining\":90,\(fields)}}")
            t.equal(value.batteryDetails, .value(expected))
            t.equal(value.battery?.value?.percent, 25); t.equal(value.battery?.value?.minutesRemaining, 90)
        }
        for field in ["health", "cycles"] {
            for bad in ["true", "\"94\"", "[]", "{}"] {
                do {
                    _ = try read("{\"battery\":{\"\(field)\":\(bad)}}")
                    t.check(false, "metadata follows the existing numeric JSON field contract")
                } catch { t.equal(error as? SkinInputDataError, SkinInputDataError("battery.\(field)", "is not a number")) }
            }
        }
    }

    t.suite("Program: battery details: replay replacement never borrows missing fields from the live machine") {
        let directory = t.temporaryDirectory("battery-details-replay")
        func read(_ source: String) throws -> SkinInputData { try SkinInputData.load(source, directory: directory) }
        let live = ProgramBatteryDetailsFixture()
        live.details = .ready(BatteryDetails(health: 88, cycles: 999))
        let passthrough = ScriptedSystemData(base: live, data: SkinInputData())
        t.equal(passthrough.batteryDetails(), live.details); t.equal(live.detailsCalls, 1)
        live.details = .pending
        t.equal(passthrough.batteryDetails(), .pending); t.equal(live.detailsCalls, 2)
        let old = try read(#"{"battery":{"level":75,"timeRemaining":90}}"#)
        t.equal(old.batteryDetails, .value(BatteryDetails()))
        let replay = ScriptedSystemData(base: live, data: old)
        t.equal(replay.batteryDetails(), .ready(BatteryDetails())); t.check(replay.gives(.battery))
        replay.apply(try read(#"{"battery":{"health":94,"cycles":231}}"#))
        t.equal(replay.batteryDetails(), .ready(BatteryDetails(health: 94, cycles: 231)))
        replay.apply(SkinInputData())
        t.equal(replay.batteryDetails(), .ready(BatteryDetails(health: 94, cycles: 231)), "an omitted battery leaves the previous replay frame")
        replay.apply(try read(#"{"battery":{"health":90}}"#))
        t.equal(replay.batteryDetails(), .ready(BatteryDetails(health: 90)), "replacing a battery clears an omitted cycle count")
        replay.apply(old)
        t.equal(replay.batteryDetails(), .ready(BatteryDetails())); t.equal(replay.battery()?.minutesRemaining, 90)
        let absent = try read(#"{"battery":null}"#)
        t.equal(absent.battery, .some(.none)); t.equal(absent.batteryDetails, .some(.none))
        replay.apply(absent)
        t.equal(replay.battery(), nil); t.equal(replay.batteryDetails(), .ready(BatteryDetails()))
        t.equal(live.detailsCalls, 2, "given old, new and null batteries stay isolated from the live provider")
        var programmatic = SkinInputData()
        programmatic.battery = .value(BatteryStatus(percent: 25, isCharging: false, isPluggedIn: false))
        replay.apply(programmatic)
        t.equal(replay.batteryDetails(), .ready(BatteryDetails()), "programmatic old-schema inputs have the same isolation")
        var detailsOnly = SkinInputData()
        detailsOnly.batteryDetails = .value(BatteryDetails(health: 0, cycles: 0))
        t.check(!detailsOnly.isEmpty); t.equal(detailsOnly.givenKeys, ["battery"])
        replay.apply(detailsOnly)
        t.equal(replay.batteryDetails(), .ready(BatteryDetails(health: 0, cycles: 0)))
        t.equal(replay.battery()?.percent, 25); t.equal(live.detailsCalls, 2)
    }
}

private final class ProgramBatteryDetailsFixture: SystemDataSource {
    var details: BatteryDetailsReading = .pending
    var status: BatteryStatus?
    var detailsCalls = 0
    var batteryCalls = 0
    var processorCount: Int { 8 }
    func cpuUsage(processor: Int) -> Double { 25 }
    func memoryStatus() -> MemoryStatus { MemoryStatus(physicalTotal: 1024, physicalUsed: 512) }
    func networkInterfaces() -> [String] { [] }
    func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
    func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
    func uptime() -> TimeInterval { 120 }
    func battery() -> BatteryStatus? { batteryCalls += 1; return status }
    func batteryDetails() -> BatteryDetailsReading { detailsCalls += 1; return details }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
}
