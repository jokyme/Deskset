import Foundation
@testable import DesksetCore

func runProgramBatteryTests(_ t: TestRunner) {
    let allBattery: Set<ProgramSystemProperty> = [.batteryLevel, .batteryCharging, .batteryPluggedIn, .batteryPresent, .batteryTimeRemaining]
    let present = ProgramExpression.systemProperty(.batteryPresent)
    let remaining = ProgramExpression.systemProperty(.batteryTimeRemaining)
    let environment = EnvironmentStamp(scale: 1, fontGeneration: 0, appearance: AppearanceStamp(value: .light, name: "battery"), imageGeneration: 0)
    let measure: (String, TextStyle, Double?) throws -> SkinSize = { text, _, _ in SkinSize(width: Double(text.utf16.count) * 7, height: 14) }
    func seconds(_ value: Double) -> ProgramExpression { .quantity(ProgramNumber(value, dimension: .duration)) }
    func text(_ expression: ProgramExpression, hidden: Bool = false, actions: [ProgramAction]? = nil) -> ProgramElement {
        ProgramElement(id: ElementID(name: "battery", index: 0), content: .text(ProgramText(value: expression)),
            hidden: hidden, onClickActions: actions)
    }
    func strings(_ scene: WidgetScene) -> [String] {
        scene.drawingItems.compactMap { if case .text(let value) = $0 { return value.text }; return nil }
    }
    func formattedMinutes(_ expression: ProgramExpression) -> ProgramExpression {
        .formatNumber(.divide(expression, seconds(60)), ProgramNumberFormat(decimals: 1))
    }

    t.suite("Program: battery data: direct sampling chooses charge or discharge once without changing legacy booleans") {
        let system = ProgramBatteryFixture(BatteryStatus(percent: 25, isCharging: true, isPluggedIn: true,
            minutesRemaining: 90, minutesUntilFull: 12.5))
        let charge = ProgramSystemInput.sample(from: system, for: allBattery)
        t.equal(system.batteryCalls, 1); t.equal(charge.batteryPresent, true); t.equal(charge.batteryTimeRemaining, 750)
        t.equal(charge.batteryLevel, 25); t.equal(charge.batteryCharging, true); t.equal(charge.batteryPluggedIn, true)
        system.status = BatteryStatus(percent: 75, isCharging: false, isPluggedIn: false, minutesRemaining: 12.5, minutesUntilFull: 90)
        let discharge = ProgramSystemInput.sample(from: system, for: allBattery)
        t.equal(system.batteryCalls, 2); t.equal(discharge.batteryTimeRemaining, 750); t.equal(discharge.batteryPresent, true)
        system.status = nil
        let absent = ProgramSystemInput.sample(from: system, for: allBattery)
        t.equal(system.batteryCalls, 3); t.equal(absent.batteryPresent, false); t.equal(absent.batteryTimeRemaining, nil)
        t.equal(absent.batteryCharging, nil); t.equal(absent.batteryPluggedIn, nil, "direct snapshot preserves its previous optional booleans")
        _ = ProgramSystemInput.sample(from: system, for: [])
        let cpu = ProgramSystemInput.sample(from: system, for: [.cpuUsage])
        t.equal(system.batteryCalls, 3); t.equal(system.cpuCalls, 1); t.equal(cpu.batteryPresent, nil); t.equal(cpu.batteryTimeRemaining, nil)
        t.equal(ProgramSystemInput().batteryPresent, nil); t.equal(ProgramSystemInput().batteryTimeRemaining, nil)
    }

    t.suite("Program: battery data: zero charging is valid while unknown power states and bad estimates stay missing") {
        let cases: [(BatteryStatus?, Double?)] = [
            (nil, nil),
            (BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true, minutesUntilFull: 0), 0),
            (BatteryStatus(percent: 100, isCharging: false, isPluggedIn: true, minutesRemaining: 30), nil),
            (BatteryStatus(percent: 100, isCharging: true, isPluggedIn: true), nil),
            (BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true, minutesRemaining: 30), nil),
            (BatteryStatus(percent: 50, isCharging: false, isPluggedIn: false, minutesRemaining: 0), nil),
            (BatteryStatus(percent: 50, isCharging: false, isPluggedIn: true, minutesRemaining: 30, minutesUntilFull: 10), nil),
            (BatteryStatus(percent: 50, isCharging: false, isPluggedIn: false, minutesRemaining: 0.5), 30),
        ]
        for (status, expected) in cases {
            let system = ProgramBatteryFixture(status)
            let direct = ProgramSystemInput.sample(from: system, for: [.batteryTimeRemaining])
            var sampler = ProgramSystemSampler()
            let cached = sampler.sample(from: system, for: [.batteryTimeRemaining], at: 0)
            t.equal(direct.batteryTimeRemaining, expected); t.equal(cached?.batteryTimeRemaining, expected)
            t.equal(system.batteryCalls, 2, "one read per independent sampling path")
        }
        for minutes in [-1.0, .nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int64.max) / 60] {
            for charging in [false, true] {
                let system = ProgramBatteryFixture(BatteryStatus(percent: 50, isCharging: charging, isPluggedIn: charging,
                    minutesRemaining: minutes, minutesUntilFull: minutes))
                t.equal(ProgramSystemInput.sample(from: system, for: allBattery).batteryTimeRemaining, nil)
                var sampler = ProgramSystemSampler()
                t.equal(sampler.sample(from: system, for: allBattery, at: 0)?.batteryTimeRemaining, nil)
            }
        }
        let nearLimit = (Double(Int64.max) / 60).nextDown
        let system = ProgramBatteryFixture(BatteryStatus(percent: .nan, isCharging: true, isPluggedIn: true, minutesUntilFull: nearLimit))
        let bounded = ProgramSystemInput.sample(from: system, for: allBattery)
        t.equal(bounded.batteryTimeRemaining, nearLimit * 60); t.equal(bounded.batteryLevel, nil)
        t.equal(bounded.batteryPresent, true, "device presence and time estimates do not depend on a valid percentage")
    }

    t.suite("Program: battery data: mixed once minute and event demand shares one hardware observation") {
        let system = ProgramBatteryFixture(BatteryStatus(percent: 50, isCharging: false, isPluggedIn: false, minutesRemaining: 120))
        var sampler = ProgramSystemSampler()
        let needed = allBattery.union([.cpuUsage])
        let first = sampler.sample(from: system, for: needed, at: 0.25)
        t.equal(system.batteryCalls, 1); t.equal(first?.batteryTimeRemaining, 7200); t.equal(first?.batteryPresent, true)
        system.status = BatteryStatus(percent: 60, isCharging: true, isPluggedIn: true, minutesUntilFull: 10)
        for instant in [1.0, 59.9] {
            let same = sampler.sample(from: system, for: needed, at: instant)
            t.equal(same?.batteryLevel, 50); t.equal(same?.batteryTimeRemaining, 7200); t.equal(same?.batteryCharging, false)
            t.equal(system.batteryCalls, 1)
        }
        let next = sampler.sample(from: system, for: needed, at: 60)
        t.equal(system.batteryCalls, 2); t.equal(next?.batteryLevel, 60); t.equal(next?.batteryTimeRemaining, 600)
        t.equal(next?.batteryCharging, true); t.equal(next?.batteryPresent, true)
        system.status = nil
        let absent = sampler.sample(from: system, for: needed, at: 120)
        t.equal(system.batteryCalls, 3); t.equal(absent?.batteryTimeRemaining, nil); t.equal(absent?.batteryLevel, nil)
        t.equal(absent?.batteryPresent, true, "minute updates do not overwrite the once observation")
        t.equal(absent?.batteryCharging, false); t.equal(absent?.batteryPluggedIn, false)
        let sameMissing = sampler.sample(from: system, for: needed, at: 121)
        t.equal(sameMissing?.batteryTimeRemaining, nil); t.equal(system.batteryCalls, 3, "observed nil is cached too")
    }

    t.suite("Program: battery data: presence survives power wake and backward time until reset") {
        let system = ProgramBatteryFixture(BatteryStatus(percent: 50, isCharging: false, isPluggedIn: false, minutesRemaining: 30))
        var sampler = ProgramSystemSampler()
        _ = sampler.sample(from: system, for: allBattery, at: 100)
        system.status = nil
        sampler.invalidateBattery()
        t.equal(sampler.sample(from: system, for: [.batteryPresent], at: 101)?.batteryPresent, true)
        t.equal(system.batteryCalls, 1, "power notification does not re-read a once property")
        t.equal(sampler.sample(from: system, for: [.batteryTimeRemaining], at: 101)?.batteryTimeRemaining, nil)
        t.equal(system.batteryCalls, 2)
        system.status = BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true, minutesUntilFull: 0)
        sampler.invalidateTimeBased()
        t.equal(sampler.sample(from: system, for: [.batteryPresent], at: 102)?.batteryPresent, true)
        t.equal(system.batteryCalls, 2, "wake invalidation leaves the once slot intact")
        t.equal(sampler.sample(from: system, for: [.batteryTimeRemaining], at: 102)?.batteryTimeRemaining, 0)
        t.equal(system.batteryCalls, 3)
        system.status = nil
        t.equal(sampler.sample(from: system, for: [.batteryPresent], at: 90)?.batteryPresent, true)
        t.equal(system.batteryCalls, 3, "a backward clock invalidates only dynamic battery state")
        _ = sampler.sample(from: system, for: [.batteryTimeRemaining], at: 90)
        t.equal(system.batteryCalls, 4)
        sampler.reset()
        let reset = sampler.sample(from: system, for: allBattery, at: 90)
        t.equal(reset?.batteryPresent, false); t.equal(reset?.batteryTimeRemaining, nil); t.equal(system.batteryCalls, 5)
        sampler.invalidateBattery(); sampler.invalidateTimeBased()
        system.status = BatteryStatus(percent: 70, isCharging: false, isPluggedIn: false, minutesRemaining: 60)
        t.equal(sampler.sample(from: system, for: [.batteryPresent], at: 91)?.batteryPresent, false)
        t.equal(system.batteryCalls, 5, "once false survives invalidations as well")
        t.equal(sampler.sample(from: system, for: [.batteryTimeRemaining], at: 91)?.batteryTimeRemaining, 3600)
        t.equal(system.batteryCalls, 6)
    }

    t.suite("Program: battery data: late demand reuses either observation order and event-only status stays unpolled") {
        for firstProperty in [ProgramSystemProperty.batteryPresent, .batteryTimeRemaining, .batteryCharging] {
            for hasBattery in [false, true] {
                let system = ProgramBatteryFixture(hasBattery ? BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true, minutesUntilFull: 2) : nil)
                var sampler = ProgramSystemSampler()
                _ = sampler.sample(from: system, for: [firstProperty], at: 0.25)
                let late = sampler.sample(from: system, for: allBattery, at: 1)
                t.equal(system.batteryCalls, 1); t.equal(late?.batteryPresent, hasBattery)
                t.equal(late?.batteryTimeRemaining, hasBattery ? 120 : nil)
                _ = sampler.sample(from: system, for: [.batteryPresent, .batteryCharging, .batteryPluggedIn], at: 600)
                t.equal(system.batteryCalls, 1, "event-only demand does not become periodic because time was once requested")
                _ = sampler.sample(from: system, for: [.batteryTimeRemaining], at: 600)
                t.equal(system.batteryCalls, 2, "the newly needed minute property refreshes on its own cadence")
            }
        }
        let system = ProgramBatteryFixture(nil)
        var sampler = ProgramSystemSampler()
        let eventOnly: Set<ProgramSystemProperty> = [.batteryCharging, .batteryPluggedIn]
        for instant in [0.25, 1, 60, 120] {
            let input = sampler.sample(from: system, for: eventOnly, at: instant)
            t.equal(input?.batteryCharging, false); t.equal(input?.batteryPluggedIn, false)
        }
        t.equal(system.batteryCalls, 1)
        sampler.invalidateBattery()
        _ = sampler.sample(from: system, for: eventOnly, at: 120.5)
        t.equal(system.batteryCalls, 2)
    }

    t.suite("Program: battery data: direct inputs defend Duration range and retain missing recovery cadence") {
        let expression = ProgramExpression.concatenate([
            .conditional(present, then: .string("present|"), otherwise: .string("absent|")),
            formattedMinutes(.ifMissing(remaining, seconds(90))), .string("|"),
            .formatNumber(remaining, ProgramNumberFormat(durationStyle: .short))])
        for input in [ProgramSystemInput(), ProgramSystemInput(batteryTimeRemaining: -.infinity),
                      ProgramSystemInput(batteryTimeRemaining: .infinity), ProgramSystemInput(batteryTimeRemaining: .nan),
                      ProgramSystemInput(batteryTimeRemaining: -1), ProgramSystemInput(batteryTimeRemaining: Double(Int64.max)),
                      ProgramSystemInput(batteryTimeRemaining: .greatestFiniteMagnitude)] {
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Missing battery", root: text(expression)))
            let result = try runtime.project(environment: environment, systemInput: input, measure: measure)
            t.equal(strings(result), ["absent|1.5|–"]); t.equal(runtime.generation, 1); t.equal(runtime.clockPrecision, .minute)
            t.equal(runtime.neededSystemProperties, [.batteryPresent, .batteryTimeRemaining])
        }
        for value in [0.0, 30.0, Double(Int64.max).nextDown] {
            let output = ProgramExpression.conditional(.isMissing(remaining), then: .string("missing"), otherwise:
                .conditional(.equal(remaining, seconds(0)), then: .string("zero"), otherwise: .string("value")))
            var runtime = try ProgramRuntime(program: WidgetProgram(name: "Valid duration", root: text(output)))
            let result = try runtime.project(environment: environment, systemInput: ProgramSystemInput(batteryTimeRemaining: value), measure: measure)
            t.equal(strings(result), [value == 0 ? "zero" : "value"]); t.equal(runtime.clockPrecision, .minute)
        }
        var once = try ProgramRuntime(program: WidgetProgram(name: "Presence only", root: text(.conditional(present, then: .string("Yes"), otherwise: .string("No")))))
        t.equal(strings(try once.project(environment: environment, systemInput: ProgramSystemInput(batteryPresent: true), measure: measure)), ["Yes"])
        t.equal(once.clockPrecision, nil); t.equal(once.neededSystemProperties, [.batteryPresent])
    }

    t.suite("Program: battery data: variables freeze while computed and hidden text keep their existing dependency rules") {
        let frozen = ProgramExpression.concatenate([.conditional(.declaration(0), then: .string("Yes|"), otherwise: .string("No|")), formattedMinutes(.declaration(1))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Frozen battery", root: text(frozen), declarations: [
            ProgramDeclaration(name: "hasBattery", kind: .variable, initial: present),
            ProgramDeclaration(name: "time", kind: .variable, initial: remaining)]))
        t.equal(runtime.neededSystemProperties, [.batteryPresent, .batteryTimeRemaining])
        let first = try runtime.project(environment: environment, systemInput: ProgramSystemInput(batteryPresent: true, batteryTimeRemaining: 120), measure: measure)
        t.equal(strings(first), ["Yes|2.0"]); t.equal(runtime.clockPrecision, nil); t.equal(runtime.neededSystemProperties, [])
        t.equal(strings(try runtime.project(environment: environment, systemInput: ProgramSystemInput(batteryPresent: false, batteryTimeRemaining: 0), measure: measure)), ["Yes|2.0"])
        let declarations = [ProgramDeclaration(name: "time", kind: .computed, initial: remaining)]
        var computed = try ProgramRuntime(program: WidgetProgram(name: "Computed battery", root: text(formattedMinutes(.declaration(0))), declarations: declarations))
        t.equal(computed.neededSystemProperties, [.batteryTimeRemaining])
        t.equal(strings(try computed.project(environment: environment, systemInput: ProgramSystemInput(batteryTimeRemaining: 180), measure: measure)), ["3.0"])
        t.equal(computed.clockPrecision, .minute)
        let unused = try ProgramRuntime(program: WidgetProgram(name: "Unused battery", root: text(.string("Static")), declarations: declarations))
        t.equal(unused.neededSystemProperties, [])
        var hiddenText = try ProgramRuntime(program: WidgetProgram(name: "Hidden text", root: text(formattedMinutes(remaining), hidden: true)))
        t.equal(hiddenText.neededSystemProperties, [.batteryTimeRemaining], "hidden text is still measured for layout")
        let hiddenScene = try hiddenText.project(environment: environment, systemInput: ProgramSystemInput(batteryTimeRemaining: 120), measure: measure)
        t.equal(hiddenScene.drawingItems, []); t.check(hiddenScene.size.width > 0); t.equal(hiddenText.clockPrecision, nil)
        let hiddenGauge = ProgramElement(id: ElementID(name: "hiddenGauge", index: 0), content: .gauge(ProgramGauge(value: remaining, total: seconds(3600))),
            width: .fixed(44), height: .fixed(44), hidden: true)
        var gauge = try ProgramRuntime(program: WidgetProgram(name: "Hidden gauge", root: hiddenGauge))
        t.equal(gauge.neededSystemProperties, [])
        t.equal(try gauge.project(environment: environment, measure: measure).drawingItems, []); t.equal(gauge.clockPrecision, nil)
    }

    t.suite("Program: battery data: action-only estimates become frozen values without starting a timer") {
        let node = text(formattedMinutes(.declaration(0)), actions: [
            .assign(ProgramAssignment(declaration: 0, value: remaining)), .copy(formattedMinutes(.declaration(0)))])
        var runtime = try ProgramRuntime(program: WidgetProgram(name: "Read battery on click", root: node,
            declarations: [ProgramDeclaration(name: "sample", kind: .variable, initial: seconds(0))]))
        let initial = try runtime.project(environment: environment, measure: measure)
        t.equal(strings(initial), ["0.0"]); t.equal(runtime.neededSystemProperties, [])
        let point = SkinPoint(x: 2, y: 2)
        t.equal(runtime.neededSystemProperties(clickAt: point), [.batteryTimeRemaining])
        let system = ProgramBatteryFixture(BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true, minutesUntilFull: 2.5))
        var sampler = ProgramSystemSampler()
        let input = sampler.sample(from: system, for: runtime.neededSystemProperties(clickAt: point), at: 1)
        let clicked = try runtime.clickWithEffects(at: point, expectedGeneration: initial.generation, environment: environment, systemInput: input, measure: measure)
        t.equal(system.batteryCalls, 1); t.equal(clicked?.effects, [.copy("2.5")]); t.equal(clicked.map { strings($0.scene) }, ["2.5"])
        t.equal(runtime.clockPrecision, nil); t.equal(runtime.neededSystemProperties, [])
        t.equal(strings(try runtime.project(environment: environment, systemInput: ProgramSystemInput(batteryTimeRemaining: 0), measure: measure)), ["2.5"])
    }
}

private final class ProgramBatteryFixture: SystemDataSource {
    var status: BatteryStatus?
    var batteryCalls = 0
    var cpuCalls = 0
    init(_ status: BatteryStatus?) { self.status = status }
    var processorCount: Int { 8 }
    func cpuUsage(processor: Int) -> Double { cpuCalls += 1; return 25 }
    func memoryStatus() -> MemoryStatus { MemoryStatus(physicalTotal: 1024, physicalUsed: 512) }
    func networkInterfaces() -> [String] { [] }
    func networkCounters(interface: String?) -> NetworkCounters { NetworkCounters() }
    func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
    func uptime() -> TimeInterval { 120 }
    func battery() -> BatteryStatus? { batteryCalls += 1; return status }
    func isProcessRunning(_ name: String) -> Bool { false }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
}
